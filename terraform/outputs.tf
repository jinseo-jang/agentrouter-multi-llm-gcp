output "ksa_name" {
  value = "envoy-ai-ksa"
  description = "Kubernetes Service Account Name"
}

output "gsa_email" {
  value = google_service_account.workload_sa.email
  description = "Google Service Account Email"
}

output "gcs_bucket_name" {
  value = google_storage_bucket.model_weights.name
  description = "GCS Bucket Name for Model Weights"
}

output "sql_connection_name" {
  value = google_sql_database_instance.main.connection_name
  description = "Cloud SQL Instance Connection Name"
}

output "project_id" {
  value       = var.project_id
  description = "GCP Project ID"
}

output "region" {
  value       = var.region
  description = "GCP Region"
}

