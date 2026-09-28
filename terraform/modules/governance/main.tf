# Cost governance. Two layers, because they fail differently:
#
#   1. A BigQuery daily query quota: a hard stop. Queries past it are refused,
#      so on-demand query spend is capped by the platform, not by attention.
#   2. A billing budget: a smoke alarm for everything else (Cloud Run, GCS,
#      Artifact Registry). Budgets alert; they never stop spend.

variable "project_id" {
  type = string
}

variable "billing_account_id" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "monthly_budget_usd" {
  type = number
}

variable "query_quota_mib_per_day" {
  type = number
}

data "google_project" "this" {
  project_id = var.project_id
}

# --- 1. Hard cap on BigQuery query bytes -----------------------------------------

# Metric and limit names come from the Service Usage API
# (consumerQuotaMetrics for bigquery.googleapis.com): "Query usage", unit MiBy,
# limit 1/d/{project}. The API addresses the limit by an already-encoded name
# (%2Fd%2Fproject), which is why both values are URL-encoded twice.
resource "google_service_usage_consumer_quota_override" "bq_query_bytes_per_day" {
  provider = google-beta

  project        = var.project_id
  service        = "bigquery.googleapis.com"
  metric         = urlencode(urlencode("bigquery.googleapis.com/quota/query/usage"))
  limit          = urlencode(urlencode("/d/project"))
  override_value = tostring(var.query_quota_mib_per_day)
  # Lowering a quota by more than 10% (from "unlimited") needs force.
  force = true
}

# --- 2. Budget alert --------------------------------------------------------------

resource "google_monitoring_notification_channel" "budget_email" {
  display_name = "spp-load-weather budget alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_billing_budget" "project" {
  billing_account = var.billing_account_id
  display_name    = "spp-load-weather (${var.project_id})"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  # Warn on the trajectory too, before the money is actually spent.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.budget_email.id]
    disable_default_iam_recipients   = false
  }
}

output "budget_name" {
  value = google_billing_budget.project.name
}
