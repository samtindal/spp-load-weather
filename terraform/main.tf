locals {
  warehouse_apis = [
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com", # scheduled queries
    "billingbudgets.googleapis.com",
    "monitoring.googleapis.com", # budget alert email channel
    "iam.googleapis.com",
  ]
  ingestion_apis = [
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
  ]
  sql_dir = "${path.root}/../sql"
}

resource "google_project_service" "apis" {
  for_each = toset(concat(local.warehouse_apis, var.enable_ingestion ? local.ingestion_apis : []))

  service = each.key
  # Turning an API off on destroy can break other things in the project and
  # buys nothing: an enabled API with no resources costs $0.
  disable_on_destroy = false
}

# The Data Transfer Service agent only exists after something asks for it.
# Creating it explicitly lets the warehouse grant it a role on first apply.
resource "google_project_service_identity" "bq_data_transfer" {
  provider   = google-beta
  service    = "bigquerydatatransfer.googleapis.com"
  depends_on = [google_project_service.apis]
}

module "warehouse" {
  source = "./modules/warehouse"

  project_id                = var.project_id
  location                  = var.bq_location
  sql_dir                   = local.sql_dir
  enable_schedules          = var.enable_schedules
  data_transfer_agent_email = google_project_service_identity.bq_data_transfer.email

  depends_on = [google_project_service.apis]
}

module "governance" {
  source = "./modules/governance"

  project_id              = var.project_id
  billing_account_id      = var.billing_account_id
  alert_email             = var.alert_email
  monthly_budget_usd      = var.monthly_budget_usd
  query_quota_mib_per_day = var.query_quota_mib_per_day

  depends_on = [google_project_service.apis]
}

module "ingestion" {
  source = "./modules/ingestion"
  count  = var.enable_ingestion ? 1 : 0

  project_id          = var.project_id
  region              = var.region
  image               = var.ingestion_image
  raw_dataset_id      = module.warehouse.raw_dataset_id
  raw_table_id        = module.warehouse.raw_table_id
  eia_api_key         = var.eia_api_key
  eia_api_key_version = var.eia_api_key_version

  depends_on = [google_project_service.apis]
}
