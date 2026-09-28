output "datasets" {
  value       = module.warehouse.dataset_ids
  description = "raw / staging / mart dataset IDs."
}

output "raw_table" {
  value       = module.warehouse.raw_table_fqn
  description = "Fully qualified raw landing table, for the backfill's --table."
}

output "scheduled_queries" {
  value       = module.warehouse.scheduled_query_names
  description = "Data Transfer Service config names for the staging refreshes."
}

output "landing_bucket" {
  value       = var.enable_ingestion ? module.ingestion[0].landing_bucket : null
  description = "GCS landing bucket (Phase 2)."
}

output "image_repository" {
  value       = var.enable_ingestion ? module.ingestion[0].image_repository : null
  description = "Artifact Registry path to push the ingestion image to (Phase 2)."
}

output "ingestion_job" {
  value       = var.enable_ingestion ? module.ingestion[0].job_name : null
  description = "Cloud Run Job name (Phase 2)."
}
