resource "google_sql_database_instance" "main" {
  name             = "envoy-ai-gw-db-${random_id.bucket_prefix.hex}"
  database_version = "POSTGRES_16"
  region           = var.region
  
  settings {
    tier = "db-custom-2-7680"
  }

  deletion_protection = false
}

resource "google_sql_database" "phoenix_db" {
  name            = "phoenix"
  instance        = google_sql_database_instance.main.name
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "phoenix_user" {
  name            = "phoenix"
  instance        = google_sql_database_instance.main.name
  password        = "phoenix_password"
  deletion_policy = "ABANDON"
}
