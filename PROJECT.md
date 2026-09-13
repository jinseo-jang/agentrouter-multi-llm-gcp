# Project Specification: Multi-LLM Serving Architecture with Agentrouter

> **Languages:** [English](PROJECT.md) | [한국어](PROJECT.kr.md)

## 1. Architecture Overview
- **Infrastructure Layer:** GCP Project `<YOUR_PROJECT_ID>` (`asia-southeast1`), GKE Standard cluster with Gateway API and GCS FUSE CSI driver enabled. L4 GPU NodePool (2x `g2-standard-8`, spot=true). Cloud SQL PostgreSQL 16. GCS Bucket for model weights.
- **Model Storage & Serving Layer:** Model weights loaded from Hugging Face into GCS. vLLM `0.29.0` pods with GCS FUSE mounts (`gke-gcsfuse/volumes: "true"`). Memory contention simulated via VRAM limits, Prefix Caching V1 enabled.
- **Routing & Networking Layer:** Envoy AI Gateway ([Agentrouter](https://github.com/theagentrouter/agent-router) `1.1.0`) intercepting external traffic, buffering JSON request bodies to apply L7 routing against the `model` key. Forwarding internal routes to `InferencePool` via `inference.networking.k8s.io/v1`. `llm-d-router` (`0.10.0`) acts as an Envoy ext-proc EPP to rank InferencePool pods dynamically using Prefix Cache scoring. Egress to Vertex AI using GCP credentials for Gemini models and Anthropic Claude models.
- **Security & Multi-Tenancy Layer:** 3-tier unified authentication via Envoy Gateway `SecurityPolicy`: GCIP JWT for corporate employees / Cloud Workstation, Google SA ID Tokens for internal microservices, and API Key authentication for external partners with strict model routing isolation.
- **Traffic Policy & Quotas:** Redis-backed token rate limiting (`BackendTrafficPolicy`) for LLM inference calls and multi-tenant token quota isolation (`QuotaPolicy`) preventing noisy neighbor resource exhaustion.
- **Observability Layer:** [Arize Phoenix](https://github.com/Arize-ai/phoenix) backing to Cloud SQL via Auth Proxy sidecar. OTLP trace gathering from API paths. PodMonitoring targeting vLLM `/metrics` for prefix caches.
- **Validation & Docs:** In-cluster load generator pod resetting vLLM caches dynamically across 3 randomized arms. Output feeds into empirical tutorial assets compliant with `AGENTS.md`.

---

## 2. Feature Inventory
| # | Feature | Description | Milestone |
|---|---------|-------------|-----------|
| 1 | GCP Terraform VPC/GKE | Deploy GKE with Gateway API, Workload Identity, GCS FUSE | M1 (Completed) |
| 2 | GCP Terraform DB/Storage | Deploy Cloud SQL PG 16, GCS Bucket | M1 (Completed) |
| 3 | GCP Terraform NodePool | Deploy 2x L4 Spot NodePool (`g2-standard-8`) | M1 (Completed) |
| 4 | GCP Terraform IAM | Service Accounts + KSA/GSA Workload Identity bindings | M1 (Completed) |
| 5 | Model Weight Loader | Job to pull google/gemma-2-2b-it from HF to GCS bucket | M2 (Completed) |
| 6 | vLLM Workload | Deploy vLLM `0.29.0` pods referencing GCS FUSE mount. Enable Prefix Caching, configure KV bounds | M2 (Completed) |
| 7 | Phoenix Tracing Server | Deploy Arize Phoenix tracing UI with Cloud SQL Auth Proxy Sidecar | M3 (Completed) |
| 8 | K8s GIE & InferencePools | Define InferencePools representing baseline RR vs EPP Ext-proc targets | M3 (Completed) |
| 9 | llm-d EPP Router | Deploy `llm-d-router` v0.10.0 configured for `prefix-cache` & `queue` scorer | M3 (Completed) |
| 10 | Agent Router Hybrid Mesh | Deploy Envoy AI Gateway (Agent Router `1.1.0`), AIGatewayRoute buffering body and routing to backend arms | M3 (Completed) |
| 11 | 3-Tier Multi-Authentication | GCIP JWT, Google SA ID Token, and Partner API Key authentication with header spoofing defense | M3 (Completed) |
| 12 | Redis Traffic & Quota Policy | Rate limiting (`BackendTrafficPolicy`) and per-tenant quota isolation (`QuotaPolicy`) backed by Redis | M3 (Completed) |
| 13 | E2E Benchmark Suite | Load generator script, randomized 3 arms, TTFT/cache stat metrics, vLLM cache reset logic | E2E (Completed) |
| 14 | Teardown Automation | Makefile scripts to create and delete the entire environment predictably | M4 (Completed) |
| 15 | Bilingual Documentation | Primary English (`*.md`) & Korean (`*.kr.md`) with cross-document navigation | Final (Completed) |

---

## 3. Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Infrastructure (Terraform) | GCP resources (GKE, NodePools, Cloud SQL, GCS, IAM) | none | DONE |
| M2 | Models & Serving (vLLM) | HF weight preloader, GCS FUSE mounting, vLLM pod definitions | M1 | DONE |
| M3 | Routing & Security | GIE, llm-d EPP, Agent Router, Phoenix, 3-tier auth, Redis quotas | M2 | DONE |
| M4 | Automation & Packaging | Numbered Kustomize manifests, Makefile automation, teardown verification | M3 | DONE |
| E2E | Empirical Benchmark | In-cluster 3-way comparative load tests with cache isolation and metrics collection | M3 | DONE |
| Final | Bilingual Docs & Publication | Primary English & Korean documentation, cross-linking, zero-leak verification | M4, E2E | DONE |

---

## 4. Interface Contracts
### 4.1 Terraform ↔ K8s
- KSA Name, GSA Email mapped for Workload Identity
- GCS Bucket Name exported for Manifest mounts
- Cloud SQL Instance Connection Name exported for Auth Proxy

### 4.2 Agent Router ↔ Backend Routes
- Envoy intercepts HTTP requests to `/v1/chat/completions`.
- `model: "gemini-2.5-flash"` routes to Google Cloud Vertex AI Gemini.
- `model: "claude-sonnet-5"` routes to Google Cloud Vertex AI Claude.
- `model: "gemma-rr"` routes to basic K8s Service (L4 round-robin).
- `model: "gemma-epp"` routes to InferencePool via Ext-Proc EPP with prefix scorer.
- `model: "gemma-epp-noprefix"` routes to InferencePool via EPP ignoring prefix scores.

### 4.3 Multi-Tenancy & Security Contracts
- Default Host (`*`): Enforces GCIP JWT or Google SA ID Token signature verification via `agent-router-jwt`. Injects `x-tenant-id`.
- Partner Host (`partner.agent-router.internal`): Enforces API Key verification via `partner-apikey`. Injects `x-tenant-id` and strips `X-API-Key` header.
- Redis Rate Limit / Quota: Ingests `llm_total_token` metadata and evaluates tenant token buckets.
