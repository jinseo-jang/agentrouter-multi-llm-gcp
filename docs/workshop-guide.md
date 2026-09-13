# Customer Workshop Hands-on Guide: Multi-LLM Serving Architecture with Agentrouter

> **Languages:** [English](workshop-guide.md) | [한국어](workshop-guide.kr.md)

This guide provides an end-to-end hands-on workshop curriculum for deploying and verifying an enterprise multi-LLM serving platform combining [Agentrouter(formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router), Kubernetes Gateway API Inference Extension (GIE), llm-d-router (EPP), vLLM, Google Cloud Vertex AI, and [Arize Phoenix](https://github.com/Arize-ai/phoenix) on Google Kubernetes Engine (GKE).

Beyond simple deployment checks, this workshop demonstrates the core value of an enterprise AI gateway: corporate security authentication, partner quota isolation, prefix cache acceleration, header anti-spoofing, and full-stack distributed tracing.

---

## 1. Workshop Overview & Architecture

Participants construct a production-ready enterprise AI serving infrastructure supporting employee workstations, internal microservices, and external partners from a single gateway endpoint:

- **Infrastructure Layer**: GKE Standard cluster, 2x NVIDIA L4 GPU Spot node pools (`g2-standard-8`), Cloud SQL PostgreSQL 16 instance, and Cloud Storage bucket.
- **Inference Backend Layer**: Public cloud managed models (Google Cloud Vertex AI Gemini 2.5 Flash and Claude Sonnet 5) and self-hosted vLLM (Gemma 2B) models.
- **Intelligent Routing & Cache Acceleration**: Kubernetes GIE `InferencePool` and `llm-d-router` (EPP) prefix-cache scorers delivering sub-second TTFT.
- **Multi-Tier Security & Quota Isolation**: GCIP JWT, Google SA ID Token, and Partner API Key authentication with Redis-backed per-tenant token quotas.
- **Full-Stack Observability**: Arize Phoenix and Google Cloud Monitoring collecting OTLP traces and prefix cache metrics.

For detailed architecture diagrams and request sequence workflows, refer to:
- [Resource Hierarchy & Architecture Diagram](../design/gateway-architecture-diagram.md)
- [End-to-End Request Flow Sequence Diagram](../design/architecture-request-flow.md)

---

## 2. Prerequisites & Environment Setup

### 2.1 Required Local Tools
Ensure the following CLI utilities are installed in your local shell or Cloud Shell:
- Google Cloud SDK (`gcloud` CLI)
- Terraform (v1.5+ recommended)
- Kubernetes CLI (`kubectl`)
- `jq`, `curl`

### 2.2 Hugging Face Access Token Setup (Required)
The self-hosted `google/gemma-2-2b-it` model is a gated repository. A valid Hugging Face account and license agreement are mandatory:
1. Visit the [Hugging Face Gemma-2-2b-it page](https://huggingface.co/google/gemma-2-2b-it) and accept the terms of use.
2. In your Hugging Face account, navigate to `Settings > Access Tokens` and generate a token with `Read` permissions.

### 2.3 GCP IAM Permissions
Your deployment account must possess the following IAM roles in the target GCP project:
- Kubernetes Engine Admin (`roles/container.admin`)
- Compute Admin (`roles/compute.admin`)
- Cloud SQL Admin (`roles/cloudsql.admin`)
- Storage Admin (`roles/storage.admin`)
- Service Account Admin & User (`roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`)
- Vertex AI User (`roles/aiplatform.user`)

### 2.4 NVIDIA L4 GPU Quota Verification
Provisioning 2x NVIDIA L4 GPUs on Spot node pools requires a regional GPU quota of at least 2:

```bash
export GCP_PROJECT="<YOUR_PROJECT_ID>"
export GCP_REGION="asia-southeast1"

gcloud compute regions describe $GCP_REGION \
  --project=$GCP_PROJECT \
  --format="json" | jq -r '.quotas[] | select(.metric | contains("NVIDIA_L4_GPUS"))'
```
Verify that the `limit` value is 2 or higher. If insufficient, request a quota increase via `IAM & Admin > Quotas` in the Google Cloud Console.

---

## 3. Infrastructure Provisioning (Terraform)

### 3.1 Configure Terraform Variables
Navigate to the `terraform/` directory and configure `terraform.tfvars`:

```bash
cd terraform
cat <<EOF > terraform.tfvars
project_id = "<YOUR_PROJECT_ID>"
region     = "asia-southeast1"
zone       = "asia-southeast1-a"
EOF
```

### 3.2 Initialize and Apply Infrastructure
```bash
terraform init
terraform apply -auto-approve
```

Key resources provisioned by Terraform:
- **GKE Standard Cluster**: Gateway API enabled (`--gateway-api=standard`), Workload Identity enabled, GCS FUSE CSI driver enabled.
- **GPU Node Pool**: 2x `g2-standard-8` with 1x NVIDIA L4 GPU each (`spot = true`).
- **Cloud SQL PostgreSQL 16**: Managed DB instance storing Arize Phoenix tracing spans.
- **Cloud Storage Bucket**: Stores `gemma-2-2b-it` model weights.
- **IAM & Workload Identity**: Service accounts with IAM bindings for Vertex AI, GCS, and Cloud SQL.

### 3.3 Connect `kubectl` to the GKE Cluster
```bash
gcloud container clusters get-credentials envoy-ai-gw-cluster \
  --region=asia-southeast1-a \
  --project=$GCP_PROJECT

# Verify GPU nodes are Ready
kubectl get nodes -l cloud.google.com/gke-accelerator=nvidia-l4
```

---

## 4. Deploying Kubernetes Manifests

Manifests are organized into numbered directories following dependency requirements.

### 4.1 Step 0: CRD and Core Controller Setup
Install Agent Router CRDs and Kubernetes Gateway API Inference Extension CRDs:
```bash
kubectl apply -f manifests/00-setup/agent-router-crds.yaml
kubectl apply -f manifests/00-setup/gie-install.yaml
```

### 4.2 Step 1 & 2: Gateway, Security Policies, and Hugging Face Secret
Inject your Hugging Face Access Token into the cluster before deploying vLLM:
```bash
export HF_TOKEN="hf_your_actual_token_here"

# Create namespace and HF token secret
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic hf-secret \
  --namespace=vllm \
  --from-literal=token=$HF_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply Gateway and Security manifests
kubectl apply -k manifests/01-gateway
kubectl apply -k manifests/02-security
```

Obtain the external LoadBalancer IP allocated to the Gateway:
```bash
export GW_IP=$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}')
echo "Gateway External IP: $GW_IP"
export GW="http://${GW_IP}:8080"
```

### 4.3 Step 3: Model Storage & vLLM GPU Serving Deployment
```bash
kubectl apply -k manifests/03-vllm

# Monitor vLLM pod initialization (downloads weights via GCS FUSE)
kubectl get pods -n vllm -w
```
Wait until both `vllm-server` pods transition to `Running (1/1)`.

### 4.4 Step 4 ~ 7: Inference Pools, Routing, Traffic Policies, Observability
```bash
kubectl apply -k manifests/04-inference-pool
kubectl apply -k manifests/05-routing
kubectl apply -k manifests/06-traffic-policy
kubectl apply -k manifests/07-observability
```

---

## 5. Hands-on Verification Scenarios

Export test environment variables before executing tests:
```bash
export GW="http://${GW_IP}:8080"
export PARTNER_HOST="partner.agent-router.internal"
```

---

### Scenario 1: Unified Endpoint Multi-Model Routing

Send inference requests across self-hosted and cloud models via the single gateway URL:

#### 1.1 Google Cloud Vertex AI Gemini 2.5 Flash
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Explain Kubernetes Gateway API in one sentence."}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

#### 1.2 Google Cloud Vertex AI Claude Sonnet 5
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Respond with: Claude connection verified."}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

#### 1.3 Self-Hosted vLLM Gemma 2B (Round-Robin)
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Hello Gemma! What model are you?"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

---

### Scenario 2: Corporate Security Authentication & Anti-Spoofing Defense

Verify gateway-enforced identity extraction and header spoofing protection.

#### 2.1 Issue Corporate Test JWT
Generate a test JWT with `department: platform` using the cluster's test script:
```bash
export GT=$(python3 scripts/gcip-token.sh generate --dept platform)
```

#### 2.2 Anti-Spoofing Defense Test (`/authtest`)
Simulate an attacker attempting to forge an `x-tenant-id: finance-vip` header while authenticating with a valid `platform` JWT:
```bash
curl -s -X POST "$GW/authtest" \
  -H "Authorization: Bearer $GT" \
  -H "x-tenant-id: finance-vip" \
  -H "Content-Type: application/json" \
  -d '{"probe": "anti-spoofing"}' | jq .
```

**Expected Result**:
The gateway overwrites the client-supplied `finance-vip` header with the token claim `platform`. The echo server returns `"x-tenant-id": "platform"`, proving zero-trust header integrity.

---

### Scenario 3: External Partner API Key Authentication & Quota Isolation

#### 3.1 Issue Dynamic Partner API Keys
```bash
export KEYISSUER_POD=$(kubectl get pod -n routing -l app=keyissuer -o jsonpath='{.items[0].metadata.name}')

# Issue 60 tokens/min key for acme-corp
export ACME_KEY=$(kubectl exec -n routing $KEYISSUER_POD -- \
  python3 -c "import urllib.request, json; req = urllib.request.Request('http://localhost:8080/issue', data=json.dumps({'client_id':'acme-corp','department':'partner'}).encode(), headers={'Content-Type':'application/json'}); print(json.loads(urllib.request.urlopen(req).read())['api_key'])")

# Issue 500 tokens/min key for globex
export GLOBEX_KEY=$(kubectl exec -n routing $KEYISSUER_POD -- \
  python3 -c "import urllib.request, json; req = urllib.request.Request('http://localhost:8080/issue', data=json.dumps({'client_id':'globex','department':'partner'}).encode(), headers={'Content-Type':'application/json'}); print(json.loads(urllib.request.urlopen(req).read())['api_key'])")
```

#### 3.2 Partner Domain Authorized Call
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $ACME_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Partner request test."}],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content'
```

#### 3.3 Unauthorized Model Access Defense
Attempting to invoke high-cost models like `claude-sonnet-5` through the partner domain is rejected immediately:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $ACME_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-5", "messages": [{"role": "user", "content": "probe"}]}'
```
**Expected Result**: `404` (Route Not Found — unauthorized models are blocked at the routing layer).

#### 3.4 Multi-Tenant Quota Isolation Test
Send requests exceeding `acme-corp`'s 60-token limit:
```bash
for i in {1..3}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}\n" -X POST "$GW/v1/chat/completions" \
    -H "Host: $PARTNER_HOST" \
    -H "X-API-Key: $ACME_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "Quota limit test prompt."}], "max_tokens": 40}')
  echo "acme-corp request $i: HTTP $CODE"
done
```
When `acme-corp` receives `HTTP 429 Too Many Requests`, test `globex`:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $GLOBEX_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "Globex test."}], "max_tokens": 20}'
```
**Expected Result**: `globex` receives `HTTP 200`, confirming strict tenant budget isolation.

---

### Scenario 4: EPP Prefix Cache-Aware Routing Acceleration

Evaluate the latency reduction achieved by intelligent prefix-cache routing:

#### 4.1 Warm Up Long System Prompt (~2,000 Tokens)
```bash
LONG_PROMPT="You are a principal cloud enterprise architect. Analyze the distributed systems architecture, resilience mechanisms, and high-availability design for the following specifications in comprehensive detail: $(python3 -c 'print("System requirement block: " + "alpha beta gamma delta epsilon " * 350)')"

# Request 1 (Cold Cache)
curl -s -w "\nTotal Time: %{time_total}s\n" -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma-epp\",
    \"messages\": [{\"role\": \"system\", \"content\": \"$LONG_PROMPT\"}, {\"role\": \"user\", \"content\": \"Summarize phase 1.\"}],
    \"max_tokens\": 30
  }"
```

#### 4.2 Request 2 (Warm Cache Hit)
```bash
curl -s -w "\nTotal Time: %{time_total}s\n" -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma-epp\",
    \"messages\": [{\"role\": \"system\", \"content\": \"$LONG_PROMPT\"}, {\"role\": \"user\", \"content\": \"Summarize phase 2.\"}],
    \"max_tokens\": 30
  }"
```
**Expected Result**: Request 2 completes in ~0.14s (a **5.5x acceleration** over the cold run) because `llm-d-router` routes the request to the exact GPU pod caching the KV blocks.

---

### Scenario 5: Enterprise Observability in Arize Phoenix

1. Forward the Arize Phoenix Web UI to your local machine:
   ```bash
   kubectl port-forward -n phoenix svc/phoenix-service 6006:6006
   ```
2. Open `http://localhost:6006` in your browser.
3. In the **Traces** tab, inspect real-time inference traces emitted by Agent Router:
   - Request latency, TTFT (Time-to-First-Token), prompt token count, and completion token count.
   - Input/output payload spans preserved across PostgreSQL 16 backing storage.

---

### Scenario 6: In-Cluster 3-Way Comparative Benchmark

Launch the automated in-cluster benchmarking suite to evaluate 16 prompts across all three routing arms:
```bash
kubectl apply -k tests/e2e/benchmark/

# Stream benchmark execution logs
kubectl logs -n default -l job-name=e2e-benchmark -f
```

---

## 6. Environment Teardown

To avoid incurring ongoing cloud infrastructure costs after completing the workshop, delete all provisioned resources:

```bash
# 1. Delete Kubernetes workloads
kubectl delete -k manifests/07-observability
kubectl delete -k manifests/06-traffic-policy
kubectl delete -k manifests/05-routing
kubectl delete -k manifests/04-inference-pool
kubectl delete -k manifests/03-vllm
kubectl delete -k manifests/02-security
kubectl delete -k manifests/01-gateway

# 2. Destroy GCP infrastructure via Terraform
cd terraform
terraform destroy -auto-approve
```

---

## 7. Troubleshooting FAQ

### Q1. vLLM pod is stuck in `CrashLoopBackOff` during startup.
- **Cause**: The Hugging Face token is missing or unauthorized to pull `google/gemma-2-2b-it`.
- **Fix**: Re-check Section 2.2. Ensure terms were accepted on Hugging Face and regenerate `hf-secret` in namespace `vllm`.

### Q2. Cloud SQL Auth Proxy fails to connect.
- **Cause**: Workload Identity IAM binding is incomplete or Cloud SQL Admin API is disabled.
- **Fix**: Verify `gcloud services list --enabled | grep sqladmin` and ensure `roles/cloudsql.client` is granted to the `phoenix-sa` GSA.

### Q3. Gateway returns `HTTP 404 Route Not Found`.
- **Cause**: The request body `model` parameter does not match any configured route in `AIGatewayRoute`, or body buffering is disabled.
- **Fix**: Verify that `aigateway.envoyproxy.io/processing-body-mode: buffered` is present on the Gateway and that the `model` parameter matches one of `gemini-2.5-flash`, `claude-sonnet-5`, `gemma-rr`, `gemma-epp`, or `gemma-epp-noprefix`.
