variable "project_id" {
  type        = string
  description = "GCP project for the whole stack. A dedicated project keeps the bill and the IAM story simple."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for Cloud Run, Scheduler, Artifact Registry, and the landing bucket."
}

variable "bq_location" {
  type        = string
  default     = "US"
  description = "BigQuery location. Must be US: bigquery-public-data.noaa_gsod lives there, and a query can't join across locations."

  validation {
    condition     = var.bq_location == "US"
    error_message = "The NOAA GSOD public dataset is in the US multi-region; the warehouse has to be too."
  }
}

# --- Cost controls ------------------------------------------------------------

variable "billing_account_id" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) for the budget alert."
}

variable "alert_email" {
  type        = string
  description = "Where budget alerts go."
}

variable "monthly_budget_usd" {
  type        = number
  default     = 5
  description = "Budget amount. Expected spend is $0; this exists to page someone if that stops being true."
}

variable "query_quota_mib_per_day" {
  type        = number
  default     = 20480
  description = <<-EOT
    Hard cap on BigQuery bytes processed per day for the whole project, in MiB.
    20 GiB/day x 31 days = 620 GiB, under the 1 TiB/month free tier, so on-demand
    query spend cannot exceed $0 no matter what runs. Queries past the cap fail.
  EOT

  validation {
    condition     = var.query_quota_mib_per_day > 0 && var.query_quota_mib_per_day <= 33000
    error_message = "Keep the cap between 1 MiB and ~32 GiB/day (the free tier divided by 31 days)."
  }
}

# --- Warehouse ----------------------------------------------------------------

variable "enable_schedules" {
  type        = bool
  default     = false
  description = "Run the scheduled staging queries daily. Off in Phase 1 (the backfill runs the same SQL once); on in Phase 2."
}

# --- Ingestion (Phase 2) --------------------------------------------------------

variable "enable_ingestion" {
  type        = bool
  default     = false
  description = "Provision the Phase 2 stack: landing bucket, Cloud Run Job, Scheduler, Secret Manager, Artifact Registry."
}

variable "ingestion_image" {
  type        = string
  default     = null
  description = "Container image for the Cloud Run Job. Null deploys Google's placeholder job image so the first apply succeeds before any image is pushed."
}

variable "eia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
  description = "EIA API key, set from the environment (TF_VAR_eia_api_key). Ephemeral + write-only: never in plan output or state."
}

variable "eia_api_key_version" {
  type        = string
  default     = "1"
  description = "Bump to push a rotated eia_api_key into Secret Manager as a new version."
}
