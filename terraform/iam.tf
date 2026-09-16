resource "google_service_account" "workload_sa" {
  account_id   = "envoy-ai-workload-sa"
  display_name = "Envoy AI Gateway Workload SA"
}

resource "google_storage_bucket_iam_member" "gcs_admin" {
  bucket = google_storage_bucket.model_weights.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.workload_sa.email}"
}

resource "google_project_iam_member" "sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.workload_sa.email}"
}

# Bind GSA to KSA for Workload Identity
resource "google_service_account_iam_binding" "workload_identity_binding" {
  service_account_id = google_service_account.workload_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[default/e2e-benchmark-sa]",
    "serviceAccount:${var.project_id}.svc.id.goog[default/envoy-ai-ksa]",
    "serviceAccount:${var.project_id}.svc.id.goog[envoy-gateway-system/envoy-ai-ksa]",
    "serviceAccount:${var.project_id}.svc.id.goog[vllm/envoy-ai-ksa]",
    "serviceAccount:${var.project_id}.svc.id.goog[phoenix/phoenix-ksa]",
    "serviceAccount:${var.project_id}.svc.id.goog[routing/envoy-ai-ksa]",
  ]
}

resource "google_project_iam_member" "vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.workload_sa.email}"
}
