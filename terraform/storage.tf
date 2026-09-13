resource "random_id" "bucket_prefix" {
  byte_length = 4
}

resource "google_storage_bucket" "model_weights" {
  name          = "envoy-ai-weights-${random_id.bucket_prefix.hex}"
  location      = var.region
  force_destroy = true
  
  uniform_bucket_level_access = true
}
