export GOOGLE_OAUTH_ACCESS_TOKEN ?= $(shell gcloud auth print-access-token)
export GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
export GCP_REGION ?= asia-southeast1

.PHONY: deploy update-manifests apply-manifests setup-secrets benchmark placeholders clean destroy

deploy:
	cd terraform && terraform init && terraform apply -var="project_id=$(GCP_PROJECT)" -var="region=$(GCP_REGION)" -auto-approve
	@echo "Fetching GKE credentials..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || echo "$(GCP_PROJECT)") && \
	 REGION=$$(cd terraform && terraform output -raw region 2>/dev/null || echo "$(GCP_REGION)") && \
	 gcloud container clusters get-credentials envoy-ai-gw-cluster --region $$REGION --project $$PROJECT_ID
	$(MAKE) update-manifests
	$(MAKE) apply-manifests

update-manifests:
	@echo "Updating manifest placeholders from Terraform outputs..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || echo "$(GCP_PROJECT)") && \
	 BUCKET=$$(cd terraform && terraform output -raw gcs_bucket_name 2>/dev/null || echo "") && \
	 GSA=$$(cd terraform && terraform output -raw gsa_email 2>/dev/null || echo "") && \
	 SQL=$$(cd terraform && terraform output -raw sql_connection_name 2>/dev/null || echo "") && \
	 if [ -n "$$BUCKET" ]; then sed -i "s|GCS_BUCKET_NAME_PLACEHOLDER|$$BUCKET|g" manifests/03-vllm/*.yaml; fi && \
	 if [ -n "$$GSA" ]; then sed -i "s|GSA_EMAIL_PLACEHOLDER|$$GSA|g" manifests/01-gateway/*.yaml manifests/03-vllm/*.yaml manifests/07-observability/phoenix/*.yaml tests/e2e/benchmark/*.yaml; fi && \
	 if [ -n "$$SQL" ]; then sed -i "s|SQL_CONNECTION_NAME_PLACEHOLDER|$$SQL|g" manifests/07-observability/phoenix/*.yaml; fi && \
	 if [ -n "$$PROJECT_ID" ]; then sed -i "s|PROJECT_ID_PLACEHOLDER|$$PROJECT_ID|g" manifests/02-security/*.yaml manifests/05-routing/*.yaml; fi && \
	 if [ -n "$$HF_TOKEN" ]; then sed -i "s|<YOUR_HUGGINGFACE_TOKEN>|$$HF_TOKEN|g" manifests/03-vllm/hf-secret.yaml; fi

setup-secrets:
	kubectl create namespace routing --dry-run=client -o yaml | kubectl apply -f -
	@if ! kubectl get secret vertex-ai-sa-key -n routing >/dev/null 2>&1; then \
		echo "Creating vertex-ai-sa-key secret in routing namespace..."; \
		PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || echo "$(GCP_PROJECT)"); \
		GSA=$$(cd terraform && terraform output -raw gsa_email 2>/dev/null || echo "envoy-ai-workload-sa@$$PROJECT_ID.iam.gserviceaccount.com"); \
		gcloud iam service-accounts keys create /tmp/vertex-ai-sa-key.json --iam-account="$$GSA" --project="$$PROJECT_ID"; \
		kubectl create secret generic vertex-ai-sa-key -n routing --from-file=service_account.json=/tmp/vertex-ai-sa-key.json; \
		rm -f /tmp/vertex-ai-sa-key.json; \
	else \
		echo "Secret vertex-ai-sa-key already exists in routing namespace."; \
	fi

apply-manifests: setup-secrets
	kubectl apply --server-side -f manifests/00-setup/envoy-gateway-crds.yaml
	kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml
	kubectl apply -f manifests/00-setup/envoy-gateway-controller.yaml
	kubectl apply -f manifests/00-setup/gie-install.yaml
	kubectl apply -f manifests/00-setup/agent-router.yaml
	kubectl apply -f manifests/00-setup/envoy-gateway-config.yaml
	kubectl apply -f manifests/00-setup/envoy-ai-gateway-ratelimit-svc.yaml
	@echo "Waiting for core controllers to become ready..."
	kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
	kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=180s
	kubectl rollout status deployment/ai-gateway-controller -n default --timeout=180s
	kubectl apply -k manifests/01-gateway
	kubectl apply -k manifests/02-security
	kubectl apply -k manifests/03-vllm
	@echo "Waiting for HuggingFace model weights download to GCS..."
	kubectl wait --for=condition=complete job/hf-weight-loader -n vllm --timeout=600s
	kubectl rollout restart deployment/vllm-server -n vllm
	kubectl apply -k manifests/04-inference-pool
	kubectl apply -k manifests/05-routing
	kubectl apply -k manifests/06-traffic-policy
	kubectl apply -k manifests/07-observability
	@echo "Ensuring Cloud Monitoring vLLM Dashboard exists..."
	@if ! gcloud monitoring dashboards list --project="$(GCP_PROJECT)" --filter="displayName:'vLLM Model Server Monitoring'" --format="value(name)" 2>/dev/null | grep -q .; then \
		gcloud monitoring dashboards create --project="$(GCP_PROJECT)" --config-from-file=manifests/07-observability/dashboards/vllm-dashboard.json; \
	else \
		echo "vLLM Model Server Monitoring dashboard already exists."; \
	fi

benchmark:
	kubectl delete job e2e-benchmark-job -n default --ignore-not-found
	kubectl apply -k tests/e2e/benchmark
	@echo "Waiting for benchmark job to complete..."
	kubectl wait --for=condition=complete job/e2e-benchmark-job -n default --timeout=900s
	kubectl logs -l app=e2e-benchmark -n default

placeholders:
	@echo "Restoring manifest placeholders for git commit..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || echo "$(GCP_PROJECT)") && \
	 BUCKET=$$(cd terraform && terraform output -raw gcs_bucket_name 2>/dev/null || echo "") && \
	 GSA=$$(cd terraform && terraform output -raw gsa_email 2>/dev/null || echo "") && \
	 SQL=$$(cd terraform && terraform output -raw sql_connection_name 2>/dev/null || echo "") && \
	 if [ -n "$$BUCKET" ]; then sed -i "s|$$BUCKET|GCS_BUCKET_NAME_PLACEHOLDER|g" manifests/03-vllm/*.yaml; fi && \
	 if [ -n "$$GSA" ]; then sed -i "s|$$GSA|GSA_EMAIL_PLACEHOLDER|g" manifests/01-gateway/*.yaml manifests/03-vllm/*.yaml manifests/07-observability/phoenix/*.yaml tests/e2e/benchmark/*.yaml; fi && \
	 if [ -n "$$SQL" ]; then sed -i "s|$$SQL|SQL_CONNECTION_NAME_PLACEHOLDER|g" manifests/07-observability/phoenix/*.yaml; fi && \
	 if [ -n "$$PROJECT_ID" ]; then sed -i "s|$$PROJECT_ID|PROJECT_ID_PLACEHOLDER|g" manifests/02-security/*.yaml manifests/05-routing/*.yaml; fi
	@sed -i 's|token: ".*"|token: "<YOUR_HUGGINGFACE_TOKEN>"|g' manifests/03-vllm/hf-secret.yaml

clean: destroy

destroy:
	@if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then \
		echo "Deleting Kubernetes workloads and LoadBalancer before Terraform destroy..."; \
		kubectl delete -k manifests/07-observability --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/06-traffic-policy --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/05-routing --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/04-inference-pool --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/03-vllm --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/02-security --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete -k manifests/01-gateway --ignore-not-found --timeout=30s 2>/dev/null || true; \
		kubectl delete svc --all -n envoy-gateway-system --ignore-not-found --timeout=30s 2>/dev/null || true; \
		sleep 15; \
	else \
		echo "Cluster API not reachable or already deleted, skipping kubectl delete..."; \
	fi
	@echo "Cleaning up any orphaned GKE firewall rules in envoy-ai-gw-vpc..."
	-gcloud compute firewall-rules list --filter="network~envoy-ai-gw-vpc" --project="$(GCP_PROJECT)" --format="value(name)" | xargs -r gcloud compute firewall-rules delete --project="$(GCP_PROJECT)" --quiet 2>/dev/null || true
	-cd terraform && terraform state rm google_sql_user.phoenix_user google_sql_database.phoenix_db 2>/dev/null || true
	cd terraform && terraform destroy -var="project_id=$(GCP_PROJECT)" -var="region=$(GCP_REGION)" -auto-approve
