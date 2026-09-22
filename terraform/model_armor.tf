# ============================================================================
# 08. Google Cloud Model Armor & Sensitive Data Protection (Cloud DLP)
# ============================================================================

# 0. Random suffix for Model Armor & SDP templates (decoupled from gcs.tf)
resource "random_id" "model_armor_suffix" {
  byte_length = 4
}

# 1. Enable Required Google Cloud APIs (Model Armor & Cloud DLP)
resource "google_project_service" "model_armor_api" {
  project            = var.project_id
  service            = "modelarmor.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dlp_api" {
  project            = var.project_id
  service            = "dlp.googleapis.com"
  disable_on_destroy = false
}

# 2. Grant Model Armor & Cloud DLP IAM Roles to GKE Workload Identity SA
#    (Uses deterministic SA email so it works even when envoy-ai-workload-sa already exists)
locals {
  workload_sa_email = "envoy-ai-workload-sa@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "model_armor_user" {
  project = var.project_id
  role    = "roles/modelarmor.admin"
  member  = "serviceAccount:${local.workload_sa_email}"

  depends_on = [google_project_service.model_armor_api]
}

resource "google_project_iam_member" "dlp_user" {
  project = var.project_id
  role    = "roles/dlp.user"
  member  = "serviceAccount:${local.workload_sa_email}"

  depends_on = [google_project_service.dlp_api]
}

resource "google_project_iam_member" "dlp_templates_reader" {
  project = var.project_id
  role    = "roles/dlp.inspectTemplatesReader"
  member  = "serviceAccount:${local.workload_sa_email}"

  depends_on = [google_project_service.dlp_api]
}

# 3. Sensitive Data Protection (Cloud DLP) Inspect Template
#    Detects PII & Secrets (Credit Card, Email, Phone, Korea RRN, GCP Credentials)
resource "google_data_loss_prevention_inspect_template" "ai_guardrail_inspect" {
  parent       = "projects/${var.project_id}/locations/${var.model_armor_location}"
  template_id  = "agentrouter-sdp-inspect-${random_id.model_armor_suffix.hex}"
  display_name = "AgentRouter AI Guardrail SDP Inspect Template"
  description  = "Inspects user prompts and LLM responses for PII and credentials"

  inspect_config {
    min_likelihood = "POSSIBLE"

    info_types {
      name = "EMAIL_ADDRESS"
    }
    info_types {
      name = "PHONE_NUMBER"
    }
    info_types {
      name = "CREDIT_CARD_NUMBER"
    }
    info_types {
      name = "KOREA_RRN"
    }
    info_types {
      name = "GCP_CREDENTIALS"
    }
    info_types {
      name = "JSON_WEB_TOKEN"
    }

    include_quote = true
  }

  depends_on = [google_project_service.dlp_api]
}

# 4. Sensitive Data Protection (Cloud DLP) De-identification Template
#    Replaces detected PII with [REDACTED:<INFO_TYPE>] before sending to LLM
resource "google_data_loss_prevention_deidentify_template" "ai_guardrail_deid" {
  parent       = "projects/${var.project_id}/locations/${var.model_armor_location}"
  template_id  = "agentrouter-sdp-deid-${random_id.model_armor_suffix.hex}"
  display_name = "AgentRouter AI Guardrail SDP De-identify Template"
  description  = "Masks detected PII/Secrets in prompts and responses with infoType tags"

  deidentify_config {
    info_type_transformations {
      transformations {
        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }

  depends_on = [google_project_service.dlp_api]
}

# 5. Google Cloud Model Armor Template (REST API Provisioning for google ~> 5.0 compatibility)
#    Configures:
#    - Prompt Injection & Jailbreak Detection (LOW_AND_ABOVE)
#    - Responsible AI (Hate Speech, Harassment, Dangerous, Sexually Explicit)
#    - Malicious URI Detection
#    - Sensitive Data Protection (Advanced De-identification linked to DLP Templates)
locals {
  model_armor_template_id = "agentrouter-guardrail-${random_id.model_armor_suffix.hex}"
  model_armor_template_payload = jsonencode({
    filterConfig = {
      piAndJailbreakFilterSettings = {
        filterEnforcement = "ENABLED"
        confidenceLevel   = "LOW_AND_ABOVE"
      }
      maliciousUriFilterSettings = {
        filterEnforcement = "ENABLED"
      }
      raiSettings = {
        raiFilters = [
          {
            filterType      = "HATE_SPEECH"
            confidenceLevel = "MEDIUM_AND_ABOVE"
          },
          {
            filterType      = "HARASSMENT"
            confidenceLevel = "MEDIUM_AND_ABOVE"
          },
          {
            filterType      = "DANGEROUS"
            confidenceLevel = "MEDIUM_AND_ABOVE"
          },
          {
            filterType      = "SEXUALLY_EXPLICIT"
            confidenceLevel = "MEDIUM_AND_ABOVE"
          }
        ]
      }
      sdpSettings = {
        advancedConfig = {
          inspectTemplate    = google_data_loss_prevention_inspect_template.ai_guardrail_inspect.id
          deidentifyTemplate = google_data_loss_prevention_deidentify_template.ai_guardrail_deid.id
        }
      }
    }
  })
}

resource "null_resource" "model_armor_template" {
  triggers = {
    project_id  = var.project_id
    location    = var.model_armor_location
    template_id = local.model_armor_template_id
    payload     = local.model_armor_template_payload
  }

  provisioner "local-exec" {
    command = <<-EOT
      TOKEN=$(gcloud auth print-access-token)
      API_URL="https://modelarmor.${self.triggers.location}.rep.googleapis.com/v1/projects/${self.triggers.project_id}/locations/${self.triggers.location}/templates"

      # Check if template already exists; if so PATCH, otherwise POST create
      STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$API_URL/${self.triggers.template_id}")

      if [ "$STATUS" = "200" ]; then
        curl -sS -X PATCH \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '${self.triggers.payload}' \
          "$API_URL/${self.triggers.template_id}?updateMask=filterConfig"
      else
        curl -sS -X POST \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '${self.triggers.payload}' \
          "$API_URL?templateId=${self.triggers.template_id}"
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
      if [ -n "$TOKEN" ]; then
        curl -sS -X DELETE \
          -H "Authorization: Bearer $TOKEN" \
          "https://modelarmor.${self.triggers.location}.rep.googleapis.com/v1/projects/${self.triggers.project_id}/locations/${self.triggers.location}/templates/${self.triggers.template_id}" || true
      fi
    EOT
  }

  depends_on = [
    google_project_service.model_armor_api,
    google_data_loss_prevention_inspect_template.ai_guardrail_inspect,
    google_data_loss_prevention_deidentify_template.ai_guardrail_deid,
  ]
}
