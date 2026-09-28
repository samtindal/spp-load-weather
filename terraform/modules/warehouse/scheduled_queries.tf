# Scheduled queries. In Terraform these are google_bigquery_data_transfer_config
# with data_source_id = "scheduled_query"; the SQL is the same file the
# backfill runs, rendered with a rolling window instead of a fixed start.
#
# They exist in Phase 1 but are `disabled` until enable_schedules is set, so
# the resources are provisioned and reviewable before anything runs daily.

resource "google_service_account" "scheduled_queries" {
  account_id   = "bq-scheduled-queries"
  display_name = "BigQuery scheduled queries (raw -> staging)"
}

# The Data Transfer Service runs each query by minting a token for this
# account. Scoped to this one service account, not project-wide.
resource "google_service_account_iam_member" "dts_token_creator" {
  service_account_id = google_service_account.scheduled_queries.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.data_transfer_agent_email}"
}

resource "google_project_iam_member" "scheduled_queries_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.scheduled_queries.member
}

resource "google_bigquery_dataset_iam_member" "scheduled_queries_read_raw" {
  dataset_id = google_bigquery_dataset.layer["raw"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.scheduled_queries.member
}

resource "google_bigquery_dataset_iam_member" "scheduled_queries_write_staging" {
  dataset_id = google_bigquery_dataset.layer["staging"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.scheduled_queries.member
}

locals {
  scheduled_queries = {
    # 07:00 UTC, an hour after the ingestion job's 06:00 run.
    staging_load_hourly = {
      schedule = "every day 07:00"
      query = templatefile("${var.sql_dir}/staging_load_hourly.sql", {
        project = var.project_id
        since   = "DATE_SUB(CURRENT_DATE(), INTERVAL ${var.load_lookback_days} DAY)"
      })
    }
    staging_weather_daily = {
      schedule = "every day 07:15"
      query = templatefile("${var.sql_dir}/staging_weather_daily.sql", {
        project    = var.project_id
        start_date = "DATE_SUB(CURRENT_DATE(), INTERVAL ${var.weather_lookback_days} DAY)"
        end_date   = "CURRENT_DATE()"
      })
    }
  }
}

resource "google_bigquery_data_transfer_config" "staging" {
  for_each = local.scheduled_queries

  display_name   = each.key
  location       = var.location
  data_source_id = "scheduled_query"
  schedule       = each.value.schedule
  disabled       = !var.enable_schedules

  service_account_name = google_service_account.scheduled_queries.email

  # DML scripts write their own targets, so there is no destination table.
  params = {
    query = each.value.query
  }

  depends_on = [
    google_service_account_iam_member.dts_token_creator,
    google_project_iam_member.scheduled_queries_job_user,
    google_bigquery_dataset_iam_member.scheduled_queries_read_raw,
    google_bigquery_dataset_iam_member.scheduled_queries_write_staging,
    google_bigquery_table.load_hourly,
    google_bigquery_table.weather_daily,
    google_bigquery_table.weather_stations,
  ]
}
