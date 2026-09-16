resource "google_container_cluster" "main" {
  name           = "envoy-ai-gw-cluster"
  location       = var.region
  node_locations = ["${var.region}-a"]

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  # GKE Standard with small default pool
  initial_node_count       = 1
  remove_default_node_pool = true

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  deletion_protection = false
}
