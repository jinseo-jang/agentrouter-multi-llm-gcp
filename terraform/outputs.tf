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

output "model_armor_location" {
  value       = var.model_armor_location
  description = "Google Cloud Model Armor Regional Endpoint Location"
}

output "model_armor_template_id" {
  value       = local.model_armor_template_id
  description = "Google Cloud Model Armor Guardrail Template ID"
}

output "sdp_inspect_template_name" {
  value       = google_data_loss_prevention_inspect_template.ai_guardrail_inspect.id
  description = "Cloud DLP (Sensitive Data Protection) Inspect Template Resource Name"
}

output "sdp_deidentify_template_name" {
  value       = google_data_loss_prevention_deidentify_template.ai_guardrail_deid.id
  description = "Cloud DLP (Sensitive Data Protection) De-identify Template Resource Name"
}
