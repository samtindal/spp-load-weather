# Phase 2 ingestion: Cloud Scheduler -> Cloud Run Job -> GCS -> BigQuery raw.
#
# Two service accounts, each with only what its workload touches:
#   eia-ingest            runs the job: reads the key, writes the bucket, appends to raw
#   eia-ingest-scheduler  triggers the job: run.invoker on this one job, nothing else

locals {
  job_name = "eia-ingest"
  # Google's public sample job image, so the first apply works before any
  # image has been pushed. `make image deploy` swaps in the real one.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/job:latest"
}

# --- Landing bucket -----------------------------------------------------------------

resource "google_storage_bucket" "landing" {
  name     = "${var.project_id}-eia-landing"
  location = var.region # regional us-central1 falls inside Cloud Storage's Always Free tier

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Nothing here is irreplaceable (it's a copy of a public API), so destroy
  # should succeed without a manual emptying step.
  force_destroy = true

  lifecycle_rule {
    condition {
      age = var.landing_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# --- Secret --------------------------------------------------------------------------

resource "google_secret_manager_secret" "eia_api_key" {
  secret_id = "eia-api-key"
  replication {
    auto {}
  }
}

# Write-only: the key goes to Secret Manager but is never stored in Terraform
# state or shown in a plan. It comes from TF_VAR_eia_api_key. Bump
# eia_api_key_version to push a rotated key.
resource "google_secret_manager_secret_version" "eia_api_key" {
  secret                 = google_secret_manager_secret.eia_api_key.id
  secret_data_wo         = var.eia_api_key
  secret_data_wo_version = var.eia_api_key_version

  lifecycle {
    precondition {
      condition     = var.eia_api_key != null
      error_message = "Ingestion is enabled but TF_VAR_eia_api_key is not set."
    }
  }
}

# --- Image registry ------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  repository_id = "spp-load-weather"
  location      = var.region
  format        = "DOCKER"
  description   = "Ingestion job images."

  # Artifact Registry's free tier is 0.5 GB of storage; keep only recent images.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "604800s" # 7 days; anything not in the newest 3
    }
  }
}

# --- Job identity + least-privilege grants -------------------------------------------

resource "google_service_account" "job" {
  account_id   = "eia-ingest"
  display_name = "EIA ingestion Cloud Run Job"
}

resource "google_secret_manager_secret_iam_member" "job_reads_key" {
  secret_id = google_secret_manager_secret.eia_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.job.member
}

# objectUser: create objects, and read them back for the BigQuery load job.
resource "google_storage_bucket_iam_member" "job_writes_landing" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectUser"
  member = google_service_account.job.member
}

resource "google_project_iam_member" "job_runs_bq_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.job.member
}

# Write access to the raw dataset only. It cannot touch staging or mart.
resource "google_bigquery_dataset_iam_member" "job_writes_raw" {
  dataset_id = var.raw_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.job.member
}

# --- The job ---------------------------------------------------------------------------

resource "google_cloud_run_v2_job" "ingest" {
  name                = local.job_name
  location            = var.region
  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.job.email
      timeout         = "900s"
      # One retry covers a transient EIA outage. The job fetches everything
      # before writing, so a retry never produces a partial load.
      max_retries = 1

      containers {
        image = coalesce(var.image, local.placeholder_image)
        args = [
          "ingest",
          "--dest", "gs://${google_storage_bucket.landing.name}",
          "--table", "${var.project_id}.${var.raw_dataset_id}.${var.raw_table_id}",
          "--lookback-days", tostring(var.lookback_days),
        ]

        env {
          name = "EIA_API_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.eia_api_key.secret_id
              version = "latest"
            }
          }
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.job_reads_key,
    google_storage_bucket_iam_member.job_writes_landing,
    google_project_iam_member.job_runs_bq_jobs,
    google_bigquery_dataset_iam_member.job_writes_raw,
  ]
}

# --- Scheduler -------------------------------------------------------------------------

resource "google_service_account" "scheduler" {
  account_id   = "eia-ingest-scheduler"
  display_name = "Triggers the EIA ingestion job"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_runs_job" {
  name     = google_cloud_run_v2_job.ingest.name
  location = google_cloud_run_v2_job.ingest.location
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

resource "google_cloud_scheduler_job" "daily" {
  name        = "${local.job_name}-daily"
  description = "Runs the EIA ingestion Cloud Run Job once a day."
  region      = var.region
  schedule    = var.schedule
  time_zone   = "Etc/UTC"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.ingest.id}:run"

    # OAuth, not OIDC: this calls a Google API (the Cloud Run Admin API's
    # jobs.run), which takes an OAuth access token. OIDC tokens are for
    # invoking a Cloud Run *service's* own URL.
    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_runs_job]
}
