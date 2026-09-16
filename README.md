# Multi-LLM Serving Architecture with Agentrouter

> **Languages:** [English](README.md) | [한국어](README.kr.md)

An enterprise multi-LLM serving platform combining [Agentrouter(formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router) (v1.1.0), Kubernetes Gateway API Inference Extension (GIE v1.6.0), llm-d-router (EPP v0.10.0), vLLM, and Vertex AI on Google Kubernetes Engine (GKE).

---

## 1. Architectural Overview

This platform provides a unified entry point bridging public cloud managed models (Vertex AI Gemini, Claude) and self-hosted models (vLLM Gemma 2B).

- **Infrastructure Layer**: GKE Standard cluster, 2x NVIDIA L4 GPU Spot node pools (`g2-standard-8`), Cloud SQL PostgreSQL 16 instance, and Cloud Storage bucket.
- **Model Serving Layer**: Cloud Storage FUSE mounts model weights directly to the container. Powered by vLLM v0.29.0 with PagedAttention V1 Prefix Caching enabled.
- **Intelligent Routing Layer**: [Agentrouter(formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router) buffers the JSON request body and parses the `model` field to route requests. Integrated with Kubernetes GIE `InferencePool` and `llm-d-router` (EPP) prefix scorers to route traffic to cache-friendly GPU pods.
- **Multi-Tier Security & Auth**: Gateway-level unified authentication supporting employee GCIP JWT, internal service Google SA ID tokens, and external partner API keys.
- **Traffic Policy Layer**: Dual rate limiting and quota management backed by distributed Redis counters (`BackendTrafficPolicy` and `QuotaPolicy`).
- **Observability Layer**: [Arize Phoenix](https://github.com/Arize-ai/phoenix) persisting OTLP traces into Cloud SQL PostgreSQL, complemented by Google Cloud Monitoring collecting GPU and prefix cache metrics.

For detailed architecture diagrams and workflows:
- [Resource Hierarchy & Architecture Diagram](design/gateway-architecture-diagram.md)
- [End-to-End Request Flow Sequence Diagram](design/architecture-request-flow.md)

---

## 2. Routing Paths & Supported Models

Incoming requests to `http://<GATEWAY_IP>:8080/v1/chat/completions` are routed according to the `model` parameter:

| Model ID | Serving Backend | Schema | Description |
|---|---|---|---|
| `gemini-2.5-flash` | Google Cloud Vertex AI | `GCPVertexAI` | Gateway delegates call via GCP credentials |
| `claude-sonnet-5` | Google Cloud Vertex AI | `GCPAnthropic` | Supports both OpenAI format and Anthropic Messages API |
| `gemma-rr` | GKE Self-Hosted GPU | `OpenAI` | Pure L4 round-robin via standard K8s Service |
| `gemma-epp` | GKE Self-Hosted GPU | `OpenAI` | GIE EPP prefix-cache scorer routes to cached pod |
| `gemma-epp-noprefix` | GKE Self-Hosted GPU | `OpenAI` | GIE EPP queue scorer distributes based on load |

---

## 3. 3-Tier Multi-Authentication Architecture

To address varied client environments across enterprise boundaries, three authentication gates are provided:

### 3.1 Corporate Employees & Cloud Workstation (GCIP JWT)
- Validates JWT tokens against Google JWKS endpoints.
- Extracts the `department` claim and injects it into `x-tenant-id` header.
- Overwrites any client-supplied tenant headers to prevent identity spoofing.
- Seamlessly integrates with Claude Code CLI running on Cloud Workstations.

### 3.2 Internal Microservices (Google SA ID Token)
- Authenticates in-cluster workloads using Workload Identity tokens obtained from the GKE metadata server without static keys.
- Injects the `email` claim as `x-tenant-id`.

### 3.3 External Partners (API Key & Quota Isolation)
- Dedicated listener host `partner.agent-router.internal` applies a route-level `SecurityPolicy` overriding the gateway JWT default.
- Maps API keys to client IDs, injects `x-tenant-id`, and strips the `X-API-Key` header before forwarding.
- Restricts model access to `gemma-rr`, blocking expensive models like `claude-sonnet-5` with `HTTP 404 Route Not Found`.
- A built-in Key Issuer service dynamically provisions new partner keys and syncs them to K8s Secrets.

Anti-spoofing header injection can be tested via the `/authtest` echo endpoint.

---

## 4. Traffic Control & Quota Policies

Enforces tenant cost control and fair resource allocation in enterprise settings:

- **Token Rate Limiting (`BackendTrafficPolicy`)**:
  - Limits `claude-sonnet-5` calls to 500,000 tokens per minute.
  - Ingests `llm_total_token` metadata from response headers into Redis.
- **Tenant Quota Isolation (`QuotaPolicy`)**:
  - Allocates distinct token budgets for partner organizations.
  - `acme-corp` receives 60 tokens/min; `globex` receives 500 tokens/min.
  - When `acme-corp` is throttled with `HTTP 429`, `globex` requests continue to succeed with `HTTP 200`.

---

## 5. 3-Way Comparative Benchmark Results

Measured in GKE Standard on 2x NVIDIA L4 GPUs using vLLM v0.29.0 (`google/gemma-2-2b-it`) and 16 independent persona prompts (~2,000 tokens each). Caches were flushed before evaluating each routing configuration by restarting vLLM pods.

### 5.1 Latency & Prefix Cache Hit Statistics

| Routing Configuration | Routing Setup | Cold TTFT P50 | Eval TTFT P50 | Eval P95 | Eval P99 | Prefix Cache Hits (Tokens) |
|---|---|---|---|---|---|---|
| **`gemma-epp`** | InferencePool + EPP Prefix Scorer ON | 0.773s | **0.139s** | **0.178s** | **0.191s** | **25,184** |
| **`gemma-rr`** | K8s Service Pure L4 Round-Robin | 1.351s | 0.613s | 1.829s | 1.877s | 10,560 |
| **`gemma-epp-noprefix`** | InferencePool + EPP Queue Scorer | 0.807s | 0.251s | 0.590s | 0.644s | 15,520 |

### 5.2 Key Findings
- **Cache Acceleration**: `gemma-epp` achieved a **5.55x TTFT speedup** (Eval 0.139s vs Cold 0.773s).
- **Prefix Scorer Net Gain**: 44.6% latency reduction (+0.112s faster) compared to queue-based EPP (`gemma-epp-noprefix`).
- **Balanced Cache Affinity**: Pure round-robin suffered from cache imbalance (one pod received all hits, the other 0), causing tail latency (Eval P99: 1.877s) to spike. `gemma-epp` distributed hits evenly (49.8% hit rate per pod) and delivered 25,184 cached tokens (**2.38x higher** than round-robin).
- **Zero Auth Overhead**: Gateway JWT authentication added under 1ms overhead, with Eval P50 holding steady at 0.139s.

Raw verification artifacts are available in `.agents/reports/benchmark-summary-postauth.md` and `tests/e2e/benchmark/job.yaml`.

---

## 6. Enterprise Observability

- **[Arize Phoenix](https://github.com/Arize-ai/phoenix)**: Connected to Cloud SQL PostgreSQL 16 via Auth Proxy, persisting OpenInference traces with input/output tokens and latency stages visible on `:6006`.
- **Google Cloud Monitoring**: Scrapes vLLM Prometheus metrics (`:8000/metrics`) via `PodMonitoring`, providing real-time dashboards for prefix cache hit rates and TTFT curves.

---

## 7. Quickstart

### 7.1 Prerequisites
- Google Cloud SDK (`gcloud`)
- Terraform 1.5+
- Kubernetes CLI (`kubectl`)
- `jq`, `curl`
- **Hugging Face Access Token**: Must have accepted license terms for `google/gemma-2-2b-it` with Read permission

### 7.2 One-Command Deployment
```bash
# 1. Export Hugging Face token
export HF_TOKEN="hf_your_token_here"

# 2. Provision infrastructure and apply manifests
make deploy

# 3. Execute 3-way comparative benchmark suite
make benchmark

# 4. Clean teardown and stop billing
make clean
```

### 7.3 Step-by-Step Manifest Application
Manifests are organized into numbered directories following execution dependencies:
```bash
kubectl apply -k manifests/01-gateway
kubectl apply -k manifests/02-security
kubectl apply -k manifests/03-vllm
kubectl apply -k manifests/04-inference-pool
kubectl apply -k manifests/05-routing
kubectl apply -k manifests/06-traffic-policy
kubectl apply -k manifests/07-observability
```

For step-by-step verification commands, see the [Manual Testing Guide](tests/manual-test-guide.md).
For a comprehensive workshop walkthrough including IAM, GPU quota checks, and HF Token setup, see the [Customer Workshop Guide](docs/workshop-guide.md).
For root-cause analysis and gateway-side architectural solutions regarding Claude Code experimental beta headers (advisor-tool-2026-03-01) on Vertex AI, see the [Claude Code & Vertex AI Compatibility Guide](docs/claude-code-vertex-compatibility.md).
