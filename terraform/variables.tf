variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The region to deploy resources to"
  type        = string
  default     = "asia-southeast1"
}

variable "model_armor_location" {
  description = "The location for Google Cloud Model Armor and SDP templates (co-located with GKE/LLM region)"
  type        = string
  default     = "asia-southeast1"
}
