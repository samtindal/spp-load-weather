# Bootstrap: the bucket that holds the main stack's Terraform state.
#
# The state bucket can't live in the state it holds, so it gets its own tiny
# configuration with local state. Run once per project:
#
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply -var project_id=YOUR_PROJECT
#
# The local terraform.tfstate here is gitignored. If it's lost, nothing
# breaks: `terraform import google_storage_bucket.state YOUR_PROJECT-tfstate`
# recovers it.

terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
  }
}

variable "project_id" {
  type        = string
  description = "GCP project that will hold the state bucket and the stack."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for the state bucket. us-central1 is in Cloud Storage's Always Free tier."
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# APIs the main stack needs before it can manage anything else, including
# the Service Usage API it uses to enable the rest.
resource "google_project_service" "core" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Every state write is a new object version, so a bad apply can be rolled back.
  versioning {
    enabled = true
  }

  # Keep the last 10 versions of each state file; state is a few KB.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.core]
}

output "state_bucket" {
  value       = google_storage_bucket.state.name
  description = "Pass to the main stack: terraform init -backend-config=bucket=<this>"
}
