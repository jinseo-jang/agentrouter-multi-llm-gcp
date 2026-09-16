# Agentrouter Multi-LLM Serving Customer Workshop Guide

> **Languages:** [English](workshop-guide.md) | [한국어](workshop-guide.kr.md)

This guide walks through deploying and verifying an enterprise AI serving platform on Google Kubernetes Engine (GKE) using [Agentrouter (formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router), Kubernetes Gateway API Inference Extension (GIE), llm-d-router (EPP), vLLM, Vertex AI, and [Arize Phoenix](https://github.com/Arize-ai/phoenix).

Participants will experience enterprise AI gateway capabilities firsthand, including multi-tier authentication, partner token budget isolation, KV cache prefix acceleration, header spoofing defense, and full-stack distributed tracing.

---

## 1. Workshop Overview & Architecture

Participants build an enterprise AI serving infrastructure from a single gateway endpoint supporting internal developer workstations, internal microservices, and external partner integrations.

- **Infrastructure Layer**: Provisions a GKE Standard cluster with 2x NVIDIA L4 GPU Spot node pools (`g2-standard-8`), a Cloud SQL PostgreSQL 16 instance, and a Cloud Storage bucket.
- **Inference Backend Layer**: Integrates Google Cloud Vertex AI (Gemini 2.5 Flash and Claude Sonnet 5) alongside self-hosted vLLM (Gemma 2B).
- **Intelligent Routing & Cache Acceleration**: Applies Kubernetes GIE `InferencePool` and `llm-d-router` (EPP) prefix cache scoring to reduce GPU prefill latency.
- **Multi-Tier Security & Authorization**: Enforces GCIP JWTs, Google SA ID tokens, and partner API keys with isolated token rate limits per tenant.
- **Full-Stack Observability**: Collects OpenInference traces in Arize Phoenix and vLLM Prometheus metrics in Google Cloud Monitoring.

For detailed architecture and request sequence diagrams, see:
- [Resource Structure & Layer Diagram](../design/gateway-architecture-diagram.md)
- [End-to-End Request Sequence Flow](../design/architecture-request-flow.md)

---

## 2. Prerequisites & Environment Preparation

### 2.1 Required Local Tools
Ensure the following CLI tools are installed in your local shell or Cloud Shell:
- Google Cloud SDK (`gcloud` CLI)
- Terraform (v1.5 or higher recommended)
- Kubernetes CLI (`kubectl`)
- `jq`, `curl`

### 2.2 Hugging Face Access Token (Required)
Downloading `google/gemma-2-2b-it` weights to Cloud Storage requires a Hugging Face account with accepted model license terms:
1. Visit the [Hugging Face Gemma-2-2b-it page](https://huggingface.co/google/gemma-2-2b-it) and accept the license agreement.
2. Generate a token with `Read` permissions under `Settings > Access Tokens`.

### 2.3 GCP IAM Roles
Your GCP account must hold the following IAM roles in the target project:
- Kubernetes Engine Admin (`roles/container.admin`)
- Compute Admin (`roles/compute.admin`)
- Cloud SQL Admin (`roles/cloudsql.admin`)
- Storage Admin (`roles/storage.admin`)
- Service Account Admin & User (`roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`)
- Service Account Token Creator (`roles/iam.serviceAccountTokenCreator` - required for SA impersonation & JWT signing)
- Vertex AI User (`roles/aiplatform.user`)

### 2.4 Enable Required GCP APIs & Identity Platform (GCIP) Setup
Enable all required Google Cloud APIs in your target project:
```bash
export GCP_PROJECT="<YOUR_PROJECT_ID>"
export GCP_REGION="asia-southeast1"

gcloud services enable compute.googleapis.com container.googleapis.com \
  sqladmin.googleapis.com storage.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com aiplatform.googleapis.com \
  identitytoolkit.googleapis.com firebase.googleapis.com --project=$GCP_PROJECT
```
In addition, to run the employee JWT token script (`scripts/gcip-token.sh`), enable **Identity Platform (or Firebase Authentication)** in the Google Cloud Console for your project and register one Web App.

### 2.5 Check NVIDIA L4 GPU Quota
Provisioning 2 NVIDIA L4 GPUs requires at least 2 regional `NVIDIA_L4_GPUS` quota in your target region:
```bash
gcloud compute regions describe $GCP_REGION \
  --project=$GCP_PROJECT \
  --format="json" | jq -r '.quotas[] | select(.metric | contains("NVIDIA_L4_GPUS"))'
```
Verify that `limit` is at least `2`. Request a quota increase under `IAM & Admin > Quotas` if needed.

---

## 3. Step 1: Terraform Infrastructure Provisioning

Provision the VPC network, GKE cluster, L4 GPU Spot node pools, Cloud SQL PostgreSQL 16 instance, Cloud Storage bucket, and Workload Identity service accounts.

```bash
cd terraform

# 1. Initialize Terraform
terraform init

# 2. Provision infrastructure (takes ~12-15 minutes)
terraform apply -var="project_id=$GCP_PROJECT" -var="region=$GCP_REGION" -auto-approve

# 3. Fetch GKE cluster credentials
gcloud container clusters get-credentials envoy-ai-gw-cluster \
  --region=$GCP_REGION \
  --project=$GCP_PROJECT

cd ..
```

---

## 4. Step 2: Sequential Kubernetes Deployment

Manifests are organized into numbered directories by dependency order.

### 4.1 Substitute Manifest Placeholders & Hugging Face Token
Export your Hugging Face token and substitute all Terraform output placeholders across the manifests:
```bash
export HF_TOKEN="hf_your_token_here"

# Automatically substitute Terraform outputs and HF_TOKEN
make update-manifests
```

### 4.2 Create Secret for Vertex AI Backend Delegation
Create the `vertex-ai-sa-key` secret referenced by `BackendSecurityPolicy` so the gateway can authenticate to Google Cloud Vertex AI on behalf of clients:
```bash
make setup-secrets
```
*(This creates the `routing` namespace, generates a JSON key for `envoy-ai-workload-sa`, and stores it in K8s Secret `vertex-ai-sa-key`.)*

### 4.3 Install Base CRDs & Core Controllers
Because the Envoy Gateway and AI Gateway CRDs are large, apply them with `--server-side`. Then deploy the Envoy Gateway controller, GIE controller, and Agent Router controller, restart Envoy Gateway to reload its custom config, and wait for them to become ready:
```bash
kubectl apply --server-side -f manifests/00-setup/envoy-gateway-crds.yaml
kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml
kubectl apply -f manifests/00-setup/envoy-gateway-controller.yaml
kubectl apply -f manifests/00-setup/gie-install.yaml
kubectl apply -f manifests/00-setup/agent-router.yaml
kubectl apply -f manifests/00-setup/envoy-gateway-config.yaml
kubectl apply -f manifests/00-setup/envoy-ai-gateway-ratelimit-svc.yaml

# Restart controller to load custom config and wait for readiness
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=180s
kubectl rollout status deployment/ai-gateway-controller -n default --timeout=180s
```

### 4.4 Deploy Manifests 01 through 07
```bash
# 1. Gateway and Envoy proxy configuration
kubectl apply -k manifests/01-gateway

# 2. Global security policy and partner key issuer
kubectl apply -k manifests/02-security

# 3. vLLM GPU serving engine (includes model weight loader job)
kubectl apply -k manifests/03-vllm
kubectl wait --for=condition=complete job/hf-weight-loader -n vllm --timeout=600s
kubectl rollout restart deployment/vllm-server -n vllm

# 4. GIE InferencePool and llm-d-router EPP (includes cross-namespace ReferenceGrant)
kubectl apply -k manifests/04-inference-pool

# 5. Intelligent model routing and echo test server
kubectl apply -k manifests/05-routing

# 6. Redis and token quota/rate-limit policies
kubectl apply -k manifests/06-traffic-policy

# 7. Arize Phoenix and PodMonitoring
kubectl apply -k manifests/07-observability
```

### 4.5 Verify Deployment Status
Wait until all pods reach `Running` and `Ready` status (`hf-weight-loader` downloads model weights to GCS before `vllm-server` initializes, which takes ~5-8 minutes):
```bash
kubectl get pods -A
```
Confirm that `envoy-routing-*`, `vllm-server-*`, `llm-d-router-*`, and `phoenix-*` pods are `Running` and `Ready`.

---

## 5. Step 3: Hands-On Verification Scenarios

Export the Gateway external IP address:
```bash
export GW="http://$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}'):8080"
export PARTNER_HOST="partner.agent-router.internal"
echo "Gateway Endpoint: $GW"
```

---

### 5.1 Pre-Flight Healthcheck
Verify that the gateway listener is responding:
```bash
curl -s -o /dev/null -w "%{http_code}\n" "$GW"
```
An HTTP `404` response confirms the Envoy listener is active (no root path route is configured).

---

### 5.2 Scenario 1: Employee REST API (GCIP JWT) & Vertex AI Models

Issue a signed GCIP JWT token and invoke Google Cloud Vertex AI models (Gemini and Claude) through the gateway.

```bash
# 1. Issue employee JWT token (department: platform)
export GT=$(./scripts/gcip-token.sh alice platform)

# 2. Invoke Vertex AI Gemini 2.5 Flash
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Summarize the benefits of Kubernetes Gateway API in one sentence."}],
    "max_tokens": 1500
  }' | jq .
```
- **Expected Result**: HTTP `200 OK`. Even though the client has no direct GCP IAM permissions or Vertex API key, the gateway authenticates upstream using its `BackendSecurityPolicy`.

```bash
# 3. Invoke Vertex AI Claude Sonnet 5 (Anthropic Messages API)
curl -sS -X POST "$GW/anthropic/v1/messages" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Say hello in Korean"}],
    "max_tokens": 30
  }' | jq .
```
- **Expected Result**: HTTP `200 OK` returning a standard `type: "message"` payload from Claude.

#### 5.2.1 Employee AI Coding Agent (Claude Code CLI) Integration
Configure Claude Code (`claude` CLI) on a Cloud Workstation or local machine to route through Envoy AI Gateway using `apiKeyHelper` for dynamic token injection:

```bash
# 1. Generate Claude Code gateway settings
python3 scripts/prepare_ws_settings.py

# 2. Apply generated settings to Claude Code configuration
mkdir -p ~/.claude
cp /tmp/new_settings.json ~/.claude/settings.json
```
- **Key Configuration Settings**:
  - `"ANTHROPIC_BASE_URL": "$GW/anthropic"`: Routes all requests through the gateway's Anthropic-compatible endpoint.
  - `"apiKeyHelper"`: Dynamically invokes `gcip-token.sh` to inject fresh corporate JWT tokens.
  - `"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"`: Prevents experimental beta headers (`advisor-tool-2026-03-01`) from conflicting with Vertex AI's schema validation. See the [Claude Code & Vertex AI Compatibility Guide](claude-code-vertex-compatibility.md) for architectural details.

```bash
# 3. Run a one-shot prompt via Claude Code CLI
claude -p "Say hello in 3 words"
```
- **Expected Result**: Exits with code `0` and outputs a 3-word greeting routed through Envoy AI Gateway.

---

### 5.3 Scenario 2: Security Verification — Header Spoofing Defense (`/authtest`)

Verify that if a malicious client attempts to spoof their department header (`x-tenant-id: finance-vip`), the gateway overwrites it using the verified JWT claim (`department: platform`).

> [!NOTE]
> `/authtest` routes to an echo server (`mendhak/http-https-echo`) behind the same Gateway `SecurityPolicy` to inspect the exact headers delivered upstream.

```bash
curl -sS -X POST "$GW/authtest" \
  -H "Authorization: Bearer $GT" \
  -H "x-tenant-id: finance-vip" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .headers
```
- **Expected Result**: The echoed `"x-tenant-id"` header is `"platform"` (from the signed JWT claim), neutralizing the client's `"finance-vip"` spoofing attempt.

---

### 5.4 Scenario 3: Internal Microservice (Google SA ID Token)

Verify keyless authentication for internal microservices or batch jobs using Google Service Account OpenID Connect (OIDC) ID tokens. In a local terminal, use `--impersonate-service-account` to mint an OIDC token with a custom audience:

```bash
# 1. Mint Google SA ID token (impersonation and audience required)
export SA_EMAIL="envoy-ai-workload-sa@${GCP_PROJECT}.iam.gserviceaccount.com"
export SA_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="$SA_EMAIL" \
  --audiences=https://agent-router.internal \
  --include-email)

# 2. Invoke self-hosted Gemma 2B model
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Healthcheck from microservice"}],
    "max_tokens": 15
  }' | jq .
```
- **Expected Result**: HTTP `200 OK` with `system_fingerprint` showing `vllm-0.29.0`. The gateway extracts the `email` claim and injects it into `x-tenant-id`.

---

### 5.5 Scenario 4: External Partner Integration & Quota Isolation (API Key)

Verify model allowlisting and independent per-partner token rate limiting using API keys.

```bash
# 1. Retrieve pre-deployed partner API keys
export AK=$(kubectl get secret partner-api-keys -n routing -o jsonpath='{.data.acme-corp}' | base64 -d)
export GK=$(kubectl get secret partner-api-keys -n routing -o jsonpath='{.data.globex}' | base64 -d)

# 2. Dynamically issue a new partner key via Key Issuer
kubectl exec -n routing deploy/keyissuer -- python3 /app/client.py | jq .

# 3. Invoke authorized model (gemma-rr)
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $AK" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Partner API test"}],"max_tokens":16}' | jq .
```

```bash
# 4. Verify unauthorized high-cost model (claude-sonnet-5) is blocked
curl -sS -i -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $AK" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Blocked"}]}' | head -n 1
```
- **Expected Result**: `HTTP/1.1 404 Not Found`. High-cost models are excluded from the partner route.

```bash
# 5. Verify tenant quota isolation (exhaust acme-corp 60 tokens/min budget)
for i in {1..6}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GW/v1/chat/completions" \
    -H "Host: $PARTNER_HOST" \
    -H "X-API-Key: $AK" \
    -H "Content-Type: application/json" \
    -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Quota test"}],"max_tokens":20}')
  echo "Acme Request $i: HTTP $CODE"
done

# 6. Immediately invoke using globex key (verify independent token bucket)
curl -s -o /dev/null -w "Globex Concurrent Request: HTTP %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $GK" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Globex check"}],"max_tokens":10}'
```
- **Expected Result**: `acme-corp` is throttled with `HTTP 429 Too Many Requests` once its 60 token/min budget is exhausted, while `globex` immediately succeeds with `HTTP 200`.

---

### 5.6 Scenario 5: Gemma-EPP Prefix Cache Acceleration

Send a ~2,000-token shared system prompt to measure TTFT (Time to First Token) acceleration between the 1st Cold request and 2nd Warm request, and inspect per-pod Prometheus cache hit counters.

```bash
# 1. Generate test payloads with shared long context
cat << 'EOF' > /tmp/make_prefix_payload.py
import json
ctx = "Google Kubernetes Engine and Gateway API enterprise prompt context. " * 150
with open('/tmp/p1.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\nQuestion 1: Summarize the infrastructure setup.'}],'stream':True,'max_tokens':30}, f)
with open('/tmp/p2.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\nQuestion 2: Explain prefix caching benefits.'}],'stream':True,'max_tokens':30}, f)
EOF
python3 /tmp/make_prefix_payload.py

# 2. 1st Cold Request (populates KV cache)
curl -N -s -o /dev/null -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p1.json \
  -w "[1st Cold TTFT]: %{time_starttransfer}s\n"

# 3. 2nd Warm Request (routed to cached pod by EPP prefix-cache-scorer)
curl -N -s -o /dev/null -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p2.json \
  -w "[2nd Warm TTFT]: %{time_starttransfer}s\n"
```
- **Expected Result**: 2nd Warm TTFT is significantly faster than 1st Cold TTFT because EPP's `prefix-cache-scorer` routes the request directly to the GPU pod holding the KV cache.

```bash
# 4. Verify vLLM per-pod Prefix Cache hit counters
for POD in $(kubectl get pods -n vllm -l app=vllm-server -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== GPU Pod: $POD ==="
  kubectl exec -n vllm $POD -c vllm -- curl -s http://localhost:8000/metrics \
    | grep -E "vllm:prefix_cache_hits_total"
done
```
- **Expected Result**: Only the specific vLLM pod that processed the 1st request shows an increase of ~1,500+ tokens in `vllm:prefix_cache_hits_total`.

---

### 5.7 Scenario 6: Full-Stack Enterprise Observability

Inspect distributed traces in Arize Phoenix:
```bash
kubectl port-forward -n phoenix svc/phoenix-service 6006:6006
```
1. Open `http://localhost:6006` in your browser.
2. Navigate to `Traces` to inspect the OpenInference spans captured from your requests.
3. Verify `gen_ai.request.model`, `llm_total_token`, `tenant_id`, and latency breakdown.

---

## 6. Troubleshooting FAQ

| Symptom | Root Cause | Remediation |
|---|---|---|
| `Too long: may not be more than 262144 bytes` during CRD install | Client-side `apply` annotation limit exceeded | Use server-side apply: `kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml`. |
| vLLM pod in `CrashLoopBackOff` | Missing `HF_TOKEN` or unaccepted model license | Accept the `google/gemma-2-2b-it` license on Hugging Face and re-apply `hf-token`. |
| HTTP 500 when calling Vertex AI models | Missing `vertex-ai-sa-key` Secret | Run `make setup-secrets` to generate and mount the service account key in `routing`. |
| `Invalid account type for --audiences` during token minting | Missing `--impersonate-service-account` flag on user credentials | Include `--impersonate-service-account="envoy-ai-workload-sa@${GCP_PROJECT}.iam.gserviceaccount.com"`. |
| `400 Unexpected value(s) advisor-tool-2026-03-01` in Claude Code | Experimental beta header rejected by Vertex AI | Add `"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"` to `env` in `~/.claude/settings.json`. |
| `429 Too Many Requests` on partner route | Partner token per-minute quota exhausted | Wait 60 seconds for window reset or issue a fresh key via `keyissuer`. |
| `500 Unexpected end of JSON` on `/authtest` | Missing request body for echo JSON parser | Include `-d '{}'` in your `curl` command. |

---

## 7. Step 4: Clean Teardown & Cost Prevention

To avoid ongoing charges after completing the workshop, delete all Kubernetes workloads first so the GCP LoadBalancer is released from the VPC before destroying Terraform resources (or simply run `make clean`):

```bash
# 1. Delete K8s workloads and wait for LoadBalancer release
kubectl delete -k manifests/07-observability --ignore-not-found
kubectl delete -k manifests/06-traffic-policy --ignore-not-found
kubectl delete -k manifests/05-routing --ignore-not-found
kubectl delete -k manifests/04-inference-pool --ignore-not-found
kubectl delete -k manifests/03-vllm --ignore-not-found
kubectl delete -k manifests/02-security --ignore-not-found
kubectl delete -k manifests/01-gateway --ignore-not-found
sleep 20

# 2. Destroy all Terraform infrastructure (~10-15 minutes)
cd terraform
terraform destroy -var="project_id=$GCP_PROJECT" -var="region=$GCP_REGION" -auto-approve
cd ..
```
