output "dataset_ids" {
  value = { for k, d in google_bigquery_dataset.layer : k => d.dataset_id }
}

output "raw_dataset_id" {
  value = google_bigquery_dataset.layer["raw"].dataset_id
}

output "raw_table_id" {
  value = google_bigquery_table.raw_eia_region_data.table_id
}

output "raw_table_fqn" {
  value = "${var.project_id}.${google_bigquery_dataset.layer["raw"].dataset_id}.${google_bigquery_table.raw_eia_region_data.table_id}"
}

output "scheduled_query_names" {
  value = { for k, c in google_bigquery_data_transfer_config.staging : k => c.name }
}
