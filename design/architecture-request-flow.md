# Inference Request Flow Architecture with Envoy AI Gateway

> **Languages:** [English](architecture-request-flow.md) | [한국어](architecture-request-flow.kr.md)

This document provides a comprehensive end-to-end request processing architecture for Envoy AI Gateway ([Agentrouter](https://github.com/theagentrouter/agent-router)), Kubernetes Gateway API Inference Extension (GIE), llm-d-router (EPP), vLLM serving engines, Google Cloud Vertex AI (Gemini & Claude), Arize Phoenix observability, 3-tier multi-authentication (GCIP JWT, Google SA ID Token, Partner API Key), and Redis-backed dual rate limiting and quota policies deployed on Google Kubernetes Engine (GKE).

---

## 1. Component & Namespace Topology Diagram

Mapping of pods, policies, and networking paths traversed by different client personas:

```mermaid
flowchart TD
    classDef client fill:#f1f3f4,stroke:#5f6368,stroke-width:2px;
    classDef lb fill:#fef7e0,stroke:#fbbc04,stroke-width:2px;
    classDef envoy fill:#e8f0fe,stroke:#4285f4,stroke-width:2px;
    classDef sec fill:#fce8e6,stroke:#ea4335,stroke-width:2px;
    classDef route fill:#e6f4ea,stroke:#34a853,stroke-width:2px;
    classDef rls fill:#f3e8fd,stroke:#a142f4,stroke-width:2px;
    classDef backend fill:#e8eaed,stroke:#202124,stroke-width:2px;
    classDef obs fill:#e0f2f1,stroke:#00897b,stroke-width:2px;

    subgraph ClientLayer["1. Client Layer"]
        C_Emp["Corporate Employee / Claude Code\n(Authorization: Bearer GCIP JWT)"]:::client
        C_Workload["Internal Microservice\n(Authorization: Bearer Google SA Token)"]:::client
        C_Partner["External Partner Service\n(X-API-Key: pk-...)"]:::client
    end

    subgraph IngressLB["2. Ingress Entry Point"]
        ExtLB["GCP External Passthrough NLB\n(<GATEWAY_IP>:8080)"]:::lb
    end

    subgraph EnvoyNS["3. Proxy Data Plane (envoy-gateway-system)"]
        subgraph EnvoyPod["Envoy AI Gateway Pod"]
            EnvoyEngine["envoy core\n(L7 data plane)"]:::envoy
            ExtProc["ai-gateway-extproc\n(Body buffering, model parsing, OTel export)"]:::envoy
        end
        SP_JWT["SecurityPolicy: agent-router-jwt\n(Global Default: GCIP / Google SA JWT auth\nclaimToHeaders -> x-tenant-id injection)"]:::sec
        SP_Key["SecurityPolicy: partner-apikey\n(Partner Route Override:\nAPI Key auth -> forwardClientIDHeader)"]:::sec
        RLS_EG["envoy-ratelimit\n(BackendTrafficPolicy engine)"]:::rls
        RLS_AI["envoy-ai-gateway-ratelimit\n(QuotaPolicy engine)"]:::rls
    end

    subgraph StorageNS["4. Distributed State Store (redis-system)"]
        Redis["redis pod\n(Rate limit counters and quota windows)"]:::rls
    end

    subgraph RoutingLayer["5. Intelligent Routing Layer (routing)"]
        AIRoute_Emp["AIGatewayRoute: envoy-ai-gw-router\n(Default Domain: All models allowed)"]:::route
        AIRoute_Partner["AIGatewayRoute: partner-router\n(partner.agent-router.internal\ngemma-rr model only)"]:::route
        EchoRoute["HTTPRoute: authtest\n(/authtest header echo)"]:::route
    end

    subgraph BackendLayer["6. Backend Serving Layer"]
        subgraph CloudAI["Google Cloud Vertex AI"]
            BSP["BackendSecurityPolicy\n(Secret/vertex-ai-sa-key credentials)"]:::sec
            Gemini["Gemini 2.5 Flash\n(asia-southeast1)"]:::backend
            Claude["Claude Sonnet 5\n(global / GCPAnthropic)"]:::backend
        end

        subgraph VLLMNS["Self-Hosted GPU Cluster (vllm)"]
            EPP_Pref["llm-d-router\n(prefix-cache-scorer weight 10)"]:::backend
            EPP_Gen["llm-d-router-noprefix\n(queue-scorer weight 1)"]:::backend
            V1["vLLM Pod 1 (NVIDIA L4 24GB)\nvllm-server-4q9r4 (10.1.0.10)"]:::backend
            V2["vLLM Pod 2 (NVIDIA L4 24GB)\nvllm-server-995q2 (10.1.1.10)"]:::backend
        end

        subgraph EchoNS["Test Echo (routing)"]
            EchoServer["echo-server pod\n(Reflects headers as JSON)"]:::backend
        end
    end

    subgraph ObservabilityLayer["7. Enterprise Observability Layer"]
        Phoenix["Arize Phoenix (Port 6006)\nPersisted to Cloud SQL Postgres 16"]:::obs
        GMP["GMP Collector\nExport to Cloud Monitoring"]:::obs
    end

    %% Connections
    C_Emp --> ExtLB
    C_Workload --> ExtLB
    C_Partner --> ExtLB
    ExtLB --> EnvoyEngine

    EnvoyEngine <--> SP_JWT
    EnvoyEngine <--> SP_Key
    EnvoyEngine <-->|gRPC| ExtProc

    EnvoyEngine <-->|gRPC| RLS_EG
    EnvoyEngine <-->|gRPC| RLS_AI
    RLS_EG <--> Redis
    RLS_AI <--> Redis

    EnvoyEngine --> AIRoute_Emp
    EnvoyEngine --> AIRoute_Partner
    EnvoyEngine --> EchoRoute

    AIRoute_Emp -->|"model: gemini-2.5-flash"| BSP
    AIRoute_Emp -->|"model: claude-sonnet-5"| BSP
    BSP --> Gemini
    BSP --> Claude

    AIRoute_Emp -->|"model: gemma-epp"| EPP_Pref
    AIRoute_Emp -->|"model: gemma-epp-noprefix"| EPP_Gen
    AIRoute_Emp -->|"model: gemma-rr"| V1 & V2
    AIRoute_Partner -->|"model: gemma-rr"| V1 & V2
    EchoRoute --> EchoServer

    EPP_Pref -.->|Returns optimal Pod IP| EnvoyEngine
    EPP_Gen -.->|Returns optimal Pod IP| EnvoyEngine

    ExtProc -.->|OTLP gRPC Traces| Phoenix
    V1 & V2 -.->|Prometheus Metrics| GMP
```

---

## 2. Detailed End-to-End Sequence Diagrams

### 2.1 Scenario A: Corporate Employee / Claude Code invoking Vertex AI Claude

7-step sequence when an authenticated client requests `model: claude-sonnet-5` with a corporate GCIP JWT:

```mermaid
sequenceDiagram
    autonumber
    actor Client as Employee Developer (Claude Code)
    participant Envoy as envoy proxy core
    participant JWT as JWT Authn Filter (agent-router-jwt)
    participant Q_RLS as envoy-ai-gateway-ratelimit
    participant ExtProc as ai-gateway-extproc sidecar
    participant BSP as BackendSecurityPolicy
    participant Vertex as Vertex AI Anthropic
    participant Phoenix as Arize Phoenix

    Note over Client,Envoy: [Step 1: Request Ingestion]
    Client->>Envoy: POST /v1/chat/completions<br/>Authorization: Bearer $GT (GCIP JWT)<br/>{"model": "claude-sonnet-5", "messages": [...]}

    Note over Envoy,JWT: [Step 2: Ingress Security & Header Injection]
    Envoy->>JWT: Verify JWT signature against Google public keys (remoteJWKS)
    Note over JWT: 1. Validate signature and expiration<br/>2. Extract department claim<br/>3. Automatically inject x-tenant-id: platform
    JWT-->>Envoy: Authentication Succeeded (Headers Updated)

    Note over Envoy,Q_RLS: [Step 3: Pre-Execution Tenant Quota Check]
    Envoy->>Q_RLS: gRPC ShouldRateLimit (x-tenant-id: platform)
    Q_RLS-->>Envoy: Quota Available (Return OK)

    Note over Envoy,ExtProc: [Step 4: Body Buffering & Protocol Translation]
    Envoy->>ExtProc: gRPC ProcessingRequest (Buffered request body)
    Note over ExtProc: Translates OpenAI JSON format to Vertex AI Anthropic rawPredict format
    ExtProc-->>Envoy: Transformed Request Delivered

    Note over Envoy,Vertex: [Step 5: Egress Delegation & Model Execution]
    Note over Envoy,BSP: Generates Google OAuth2 Access Token using Secret/vertex-ai-sa-key<br/>(Client's corporate JWT is never exposed externally)
    Envoy->>Vertex: POST .../models/claude-sonnet-5:rawPredict<br/>Authorization: Bearer ya29...
    Vertex-->>Envoy: HTTP 200 Streaming Chunks Response

    Note over Envoy,Client: [Step 6: Return Response to Client]
    Envoy-->>Client: HTTP 200 Stream Delivered

    Note over ExtProc,Phoenix: [Step 7: Async Observability Ingestion]
    ExtProc-)Phoenix: OTLP gRPC Trace Export (TTFT, token counts, prompt text)
```

---

### 2.2 Scenario B: Gemma 2B EPP Prefix-Cache-Aware Routing

Sequence when a client sends a request with `model: gemma-epp` containing a long system prompt (>2,000 tokens):

```mermaid
sequenceDiagram
    autonumber
    actor Client as Client
    participant Envoy as envoy proxy core
    participant ExtProc as ai-gateway-extproc sidecar
    participant EPP as llm-d-router (prefix-scorer-pool)
    participant vLLM as vLLM Pod 2 (10.1.1.10, L4 GPU)
    participant Phoenix as Arize Phoenix

    Note over Client,Envoy: [Step 1: Request Ingestion]
    Client->>Envoy: POST /v1/chat/completions<br/>{"model": "gemma-epp", "messages": [Long system prompt...]}

    Note over Envoy,ExtProc: [Step 2: Body Buffering & Model Extraction]
    Envoy->>ExtProc: gRPC ProcessingRequest (Buffered request body)
    Note over ExtProc: 1. Extracts model field (x-ai-eg-model: gemma-epp)<br/>2. Matches prefix-scorer-pool in AIGatewayRoute
    ExtProc-->>Envoy: Routing Header Updated

    Note over Envoy,EPP: [Step 3: EPP Intelligent Endpoint Selection]
    Envoy->>EPP: gRPC CheckRequest (Prompt text and candidate pod list)
    Note over EPP: 1. prefix-cache-scorer: Compares prompt hashes<br/>   Finds identical prefix cached on vllm-server Pod 2 (+10 score)<br/>2. queue-scorer: Evaluates queue load (+5 score)<br/>-> Target selected: 10.1.1.10
    EPP-->>Envoy: Destination Pod IP (10.1.1.10) Returned

    Note over Envoy,vLLM: [Step 4: vLLM PagedAttention Cache Reuse Execution]
    Envoy->>vLLM: HTTP POST http://10.1.1.10:8000/v1/chat/completions
    Note over vLLM: --enable-prefix-caching active:<br/>1. Maps existing KV blocks immediately (bypasses prefill calculation)<br/>2. Enters decoding with ~0.14s TTFT
    vLLM-->>Envoy: HTTP 200 Streaming Response
    Envoy-->>Client: HTTP 200 Final Response Stream

    Note over ExtProc,Phoenix: [Step 5: Observability Trace Export]
    ExtProc-)Phoenix: OTLP gRPC Trace Export (Records accelerated TTFT metrics)
```

---

### 2.3 Scenario C: External Partner API Key Authentication & Route Isolation

Sequence when an external partner accesses the gateway via dedicated credentials:

```mermaid
sequenceDiagram
    autonumber
    actor Partner as External Partner Service
    participant Envoy as envoy proxy core
    participant KeyAuth as API Key Filter (partner-apikey)
    participant Route as AIGatewayRoute (partner-router)
    participant vLLM as In-Cluster vLLM Pod (gemma-rr)

    Note over Partner,Envoy: [Step 1: Request to Dedicated Partner Domain]
    Partner->>Envoy: POST /v1/chat/completions<br/>Host: partner.agent-router.internal<br/>X-API-Key: pk-partner-htcsor-...<br/>{"model": "gemma-rr", "messages": [...]}

    Note over Envoy,KeyAuth: [Step 2: Partner Security Evaluation (Route Override)]
    Note over KeyAuth: Bypasses parent Gateway JWT filter and evaluates API key
    Envoy->>KeyAuth: Look up Secret/partner-api-keys mapping table
    alt Invalid or missing key
        KeyAuth-->>Partner: Blocked immediately with HTTP 401 Unauthorized
    else Valid key match
        Note over KeyAuth: 1. Identifies Client ID (partner-htcsor)<br/>2. Injects x-tenant-id: partner-htcsor header<br/>3. Strips X-API-Key header (sanitize: true prevents backend exposure)
        KeyAuth-->>Envoy: Authentication Passed
    end

    Note over Envoy,Route: [Step 3: Allowed Model Catalog Check]
    Note over Route: Evaluates partner-router rules:<br/>- gemma-rr: Forwarded normally<br/>- gemini/claude: Blocked with HTTP 404 Route Not Found (Cost protection)

    Note over Envoy,vLLM: [Step 4: Backend Serving]
    Envoy->>vLLM: HTTP POST (x-tenant-id: partner-htcsor)
    vLLM-->>Envoy: HTTP 200 Response
    Envoy-->>Partner: HTTP 200 Result Returned
```

---

### 2.4 Scenario D: Security Header Anti-Spoofing Verification (`/authtest`)

Sequence illustrating gateway defense against client header tampering:

```mermaid
sequenceDiagram
    autonumber
    actor Client as Client (Simulating Attacker)
    participant Envoy as envoy proxy core
    participant JWT as JWT Authn Filter
    participant Echo as echo-server Pod

    Note over Client,Envoy: [Step 1: Ingest Request with Spoofed Header]
    Client->>Envoy: POST /authtest<br/>Authorization: Bearer $GT (department: platform)<br/>x-tenant-id: finance-vip (Forged header)<br/>{}

    Note over Envoy,JWT: [Step 2: JWT Validation & Enforced Overwrite]
    Envoy->>JWT: Validate JWT integrity
    Note over JWT: claimToHeaders rule enforced:<br/>Disregards client-sent 'finance-vip'<br/>Overwrites x-tenant-id header with token claim 'platform' (Anti-spoofing)
    JWT-->>Envoy: Overwrite Applied

    Note over Envoy,Echo: [Step 3: Echo Server Reflection]
    Envoy->>Echo: POST /authtest (x-tenant-id: platform)
    Echo-->>Client: HTTP 200 {"headers": {"x-tenant-id": "platform", ...}}
```

---

## 3. Pod & Configuration Role Mapping Table

| Pod / Component | Namespace | Applied Manifest Path | Role & Runtime Behavior |
|---|---|---|---|
| **`envoy` (Core Proxy)** | `envoy-gateway-system` | [`manifests/01-gateway/gateway.yaml`](../manifests/01-gateway/gateway.yaml) | Receives external LB (`:8080`) traffic and executes L7 routing decisions |
| **`ai-gateway-extproc`** | `envoy-gateway-system` | [`manifests/01-gateway/gateway-config.yaml`](../manifests/01-gateway/gateway-config.yaml) | Buffers request body, parses JSON `model`, and publishes OTLP gRPC traces |
| **`envoy-ratelimit`** | `envoy-gateway-system` | [`manifests/06-traffic-policy/traffic-policy.yaml`](../manifests/06-traffic-policy/traffic-policy.yaml) | Handles token-per-minute rate limits via `BackendTrafficPolicy` (EG xDS 18001) |
| **`envoy-ai-gateway-ratelimit`** | `envoy-gateway-system` | [`manifests/06-traffic-policy/traffic-policy.yaml`](../manifests/06-traffic-policy/traffic-policy.yaml) | Manages cumulative token budgets per model via `QuotaPolicy` (AI GW xDS 18002) |
| **`redis`** | `redis-system` | [`manifests/06-traffic-policy/redis.yaml`](../manifests/06-traffic-policy/redis.yaml) | Distributed in-memory storage for rate-limit counters and quota keys |
| **`SecurityPolicy` (JWT)** | `routing` | [`manifests/02-security/security-policy.yaml`](../manifests/02-security/security-policy.yaml) | Global verification for GCIP and Google SA tokens; injects `x-tenant-id` |
| **`SecurityPolicy` (API Key)** | `routing` | [`manifests/05-routing/partner-route.yaml`](../manifests/05-routing/partner-route.yaml) | Route-level API key verification and tenant mapping (overrides gateway default) |
| **`keyissuer`** | `routing` | [`manifests/02-security/keyissuer.yaml`](../manifests/02-security/keyissuer.yaml) | Dynamically patches new partner API keys into K8s Secret `partner-api-keys` |
| **`echo-server`** | `routing` | [`manifests/05-routing/echo-route.yaml`](../manifests/05-routing/echo-route.yaml) | Reflects received request headers as JSON to verify anti-spoofing behavior |
| **`AIGatewayRoute` (Internal)** | `routing` | [`manifests/05-routing/ai-gateway-route.yaml`](../manifests/05-routing/ai-gateway-route.yaml) | Allows full routing across Gemini, Claude, Gemma-RR, and EPP cache pools |
| **`AIGatewayRoute` (Partner)** | `routing` | [`manifests/05-routing/partner-route.yaml`](../manifests/05-routing/partner-route.yaml) | Restricts access to `gemma-rr` only for domain `partner.agent-router.internal` |
| **`BackendSecurityPolicy`** | `routing` | [`manifests/05-routing/ai-gateway-route.yaml`](../manifests/05-routing/ai-gateway-route.yaml) | Fetches Google OAuth2 tokens from `Secret/vertex-ai-sa-key` to call Vertex AI |
| **`llm-d-router` (EPP)** | `vllm` | [`manifests/04-inference-pool/llm-d-router.yaml`](../manifests/04-inference-pool/llm-d-router.yaml) | Scores pods using prompt prefix hashes to maximize KV cache reuse (`prefix-cache-scorer`) |
| **`vllm-server` (2 Pods)** | `vllm` | [`manifests/03-vllm/vllm-deployment.yaml`](../manifests/03-vllm/vllm-deployment.yaml) | Hosts Gemma 2B on NVIDIA L4 GPUs with V1 PagedAttention prefix caching enabled |
| **`phoenix`** | `phoenix` | [`manifests/07-observability/phoenix/`](../manifests/07-observability/phoenix/) | Persists OTLP traces into Cloud SQL Postgres 16 and serves the web UI (`:6006`) |
| **`gmp-collector`** | `gmp-system` | [`manifests/07-observability/podmonitoring.yaml`](../manifests/07-observability/podmonitoring.yaml) | Periodically scrapes vLLM `:8000/metrics` and exports to Google Cloud Monitoring |
