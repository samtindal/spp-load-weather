terraform {
  # 1.11+ for write-only arguments (the EIA key never touches state).
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.4"
    }
  }

  # Partial configuration: the bucket comes from bootstrap/, passed at init time
  # (make init does this), so no project-specific name is committed.
  backend "gcs" {
    prefix = "spp-load-weather"
  }
}

locals {
  labels = {
    app        = "spp-load-weather"
    managed-by = "terraform"
  }
}

provider "google" {
  project        = var.project_id
  region         = var.region
  default_labels = local.labels

  # The Billing Budgets API rejects user credentials unless a quota project is set.
  user_project_override = true
  billing_project       = var.project_id
}

# Only for the two resources that exist only in beta: the BigQuery quota
# override and the Data Transfer service identity.
provider "google-beta" {
  project        = var.project_id
  region         = var.region
  default_labels = local.labels

  user_project_override = true
  billing_project       = var.project_id
}
