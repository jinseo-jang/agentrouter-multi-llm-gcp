export GOOGLE_OAUTH_ACCESS_TOKEN ?= $(shell gcloud auth print-access-token)

.PHONY: deploy update-manifests apply-manifests benchmark clean destroy

deploy:
	cd terraform && terraform init && terraform apply -auto-approve
	@echo "Fetching GKE credentials..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id) && \
	 REGION=$$(cd terraform && terraform output -raw region) && \
	 gcloud container clusters get-credentials envoy-ai-gw-cluster --region $$REGION --project $$PROJECT_ID
	$(MAKE) update-manifests
	$(MAKE) apply-manifests

update-manifests:
	@echo "Updating manifest placeholders from Terraform outputs..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || gcloud config get-value project) && \
	 BUCKET=$$(cd terraform && terraform output -raw gcs_bucket_name 2>/dev/null || echo "") && \
	 GSA=$$(cd terraform && terraform output -raw gsa_email 2>/dev/null || echo "") && \
	 SQL=$$(cd terraform && terraform output -raw sql_connection_name 2>/dev/null || echo "") && \
	 if [ -n "$$BUCKET" ]; then sed -i "s|GCS_BUCKET_NAME_PLACEHOLDER|$$BUCKET|g" manifests/03-vllm/*.yaml; fi && \
	 if [ -n "$$GSA" ]; then sed -i "s|GSA_EMAIL_PLACEHOLDER|$$GSA|g" manifests/01-gateway/*.yaml manifests/03-vllm/*.yaml manifests/07-observability/phoenix/*.yaml tests/e2e/benchmark/*.yaml; fi && \
	 if [ -n "$$SQL" ]; then sed -i "s|SQL_CONNECTION_NAME_PLACEHOLDER|$$SQL|g" manifests/07-observability/phoenix/*.yaml; fi && \
	 if [ -n "$$PROJECT_ID" ]; then sed -i "s|PROJECT_ID_PLACEHOLDER|$$PROJECT_ID|g" manifests/02-security/*.yaml manifests/05-routing/*.yaml; fi

apply-manifests:
	kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml
	kubectl apply -f manifests/00-setup/gie-install.yaml
	kubectl apply -f manifests/00-setup/agent-router.yaml
	kubectl apply -f manifests/00-setup/envoy-gateway-config.yaml
	kubectl apply -f manifests/00-setup/envoy-ai-gateway-ratelimit-svc.yaml
	kubectl apply -k manifests/01-gateway
	kubectl apply -k manifests/02-security
	kubectl apply -k manifests/03-vllm
	kubectl apply -k manifests/04-inference-pool
	kubectl apply -k manifests/05-routing
	kubectl apply -k manifests/06-traffic-policy
	kubectl apply -k manifests/07-observability

benchmark:
	kubectl apply -k tests/e2e/benchmark
	@echo "Waiting for benchmark job to complete..."
	kubectl wait --for=condition=complete job/e2e-benchmark-job -n default --timeout=900s
	kubectl logs -l app=e2e-benchmark -n default

placeholders:
	@echo "Restoring manifest placeholders for git commit..."
	@PROJECT_ID=$$(cd terraform && terraform output -raw project_id 2>/dev/null || gcloud config get-value project) && \
	 BUCKET=$$(cd terraform && terraform output -raw gcs_bucket_name 2>/dev/null || echo "") && \
	 GSA=$$(cd terraform && terraform output -raw gsa_email 2>/dev/null || echo "") && \
	 SQL=$$(cd terraform && terraform output -raw sql_connection_name 2>/dev/null || echo "") && \
	 if [ -n "$$BUCKET" ]; then sed -i "s|$$BUCKET|GCS_BUCKET_NAME_PLACEHOLDER|g" manifests/03-vllm/*.yaml; fi && \
	 if [ -n "$$GSA" ]; then sed -i "s|$$GSA|GSA_EMAIL_PLACEHOLDER|g" manifests/01-gateway/*.yaml manifests/03-vllm/*.yaml manifests/07-observability/phoenix/*.yaml tests/e2e/benchmark/*.yaml; fi && \
	 if [ -n "$$SQL" ]; then sed -i "s|$$SQL|SQL_CONNECTION_NAME_PLACEHOLDER|g" manifests/07-observability/phoenix/*.yaml; fi && \
	 if [ -n "$$PROJECT_ID" ]; then sed -i "s|$$PROJECT_ID|PROJECT_ID_PLACEHOLDER|g" manifests/02-security/*.yaml manifests/05-routing/*.yaml; fi

clean: destroy

destroy:
	cd terraform && terraform destroy -auto-approve
