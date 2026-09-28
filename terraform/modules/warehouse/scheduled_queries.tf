# Scheduled queries: google_bigquery_data_transfer_config with
# data_source_id = "scheduled_query". Each renders the same sql/ file the
# backfill runs and overwrites its staging table (WRITE_TRUNCATE), exactly
# what `make backfill` does by hand.
#
# Not created in sandbox mode (no Data Transfer Service there). With billing,
# they're created `disabled` until enable_schedules is set, so they can be
# reviewed before anything runs daily.

locals {
  schedules_enabled = !var.sandbox

  scheduled_queries = {
    # 07:00 UTC, an hour after the ingestion job's 06:00 run.
    load_hourly = {
      schedule = "every day 07:00"
      query    = templatefile("${var.sql_dir}/staging_load_hourly.sql", { project = var.project_id })
    }
    weather_daily = {
      schedule = "every day 07:15"
      query = templatefile("${var.sql_dir}/staging_weather_daily.sql", {
        project    = var.project_id
        start_year = tostring(var.study_start_year)
        # A constant upper bound far in the future: each new year's GSOD table
        # is picked up automatically, and the range is still a literal, so
        # BigQuery prunes every year before start_year.
        end_year = "9999"
      })
    }
  }
}

resource "google_service_account" "scheduled_queries" {
  count = local.schedules_enabled ? 1 : 0

  account_id   = "bq-scheduled-queries"
  display_name = "BigQuery scheduled queries (raw -> staging)"
}

# The Data Transfer Service runs each query by minting a token for this
# account. Scoped to this one service account, not project-wide.
resource "google_service_account_iam_member" "dts_token_creator" {
  count = local.schedules_enabled ? 1 : 0

  service_account_id = google_service_account.scheduled_queries[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.data_transfer_agent_email}"
}

resource "google_project_iam_member" "scheduled_queries_job_user" {
  count = local.schedules_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.scheduled_queries[0].member
}

resource "google_bigquery_dataset_iam_member" "scheduled_queries_read_raw" {
  count = local.schedules_enabled ? 1 : 0

  dataset_id = google_bigquery_dataset.layer["raw"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.scheduled_queries[0].member
}

resource "google_bigquery_dataset_iam_member" "scheduled_queries_write_staging" {
  count = local.schedules_enabled ? 1 : 0

  dataset_id = google_bigquery_dataset.layer["staging"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.scheduled_queries[0].member
}

resource "google_bigquery_data_transfer_config" "staging" {
  for_each = local.schedules_enabled ? local.scheduled_queries : {}

  display_name   = "staging_${each.key}"
  location       = var.location
  data_source_id = "scheduled_query"
  schedule       = each.value.schedule
  disabled       = !var.enable_schedules

  service_account_name   = google_service_account.scheduled_queries[0].email
  destination_dataset_id = google_bigquery_dataset.layer["staging"].dataset_id

  params = {
    query                           = each.value.query
    destination_table_name_template = each.key
    write_disposition               = "WRITE_TRUNCATE"
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
