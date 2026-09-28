output "landing_bucket" {
  value = google_storage_bucket.landing.name
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "job_name" {
  value = google_cloud_run_v2_job.ingest.name
}

output "secret_id" {
  value = google_secret_manager_secret.eia_api_key.secret_id
}
