# Manual Testing Guide for Envoy AI Gateway (Scenario-by-Scenario Verification)

> **Languages:** [English](manual-test-guide.md) | [한국어](manual-test-guide.kr.md)

This document provides step-by-step verification procedures for operators to validate Envoy AI Gateway ([Agentrouter](https://github.com/theagentrouter/agent-router)), vLLM, GIE/EPP (llm-d-router), 3-tier multi-authentication (GCIP, Workload Identity, API keys), partner quota isolation, and Arize Phoenix observability pipelines deployed on GKE.

---

## 0. Test Architecture & Routing Overview

Envoy AI Gateway routes traffic and enforces authorization from a single entry point according to client persona and request attributes:

```mermaid
flowchart TD
    subgraph Client["Test Clients"]
        C1["Employee Workstation\n(Claude Code CLI)"]
        C2["Employee API Client\n(curl / REST)"]
        C3["Internal Microservice\n(GKE Pod / Batch Job)"]
        C4["External Partner Service\n(X-API-Key)"]
    end

    subgraph Ingress["Envoy AI Gateway (Port 8080)"]
        GW_JWT["Default Listener / Host: *\n(SecurityPolicy: JWT)"]
        GW_KEY["Partner Listener / Host: partner.agent-router.internal\n(SecurityPolicy: API Key Auth)"]
    end

    subgraph Backend["Inference Backends"]
        V_CLAUDE["Vertex AI Anthropic\n(claude-sonnet-5)"]
        V_GEMINI["Vertex AI Gemini\n(gemini-2.5-flash)"]
        K_RR["vLLM Pure Round-Robin\n(gemma-rr)"]
        K_EPP["GIE EPP Prefix Scorer Pool\n(gemma-epp)"]
        K_NOPREF["GIE EPP Generic Pool\n(gemma-epp-noprefix)"]
    end

    C1 -->|"ANTHROPIC_BASE_URL\nBearer <GCIP_JWT>"| GW_JWT
    C2 -->|"Bearer <GCIP_JWT>"| GW_JWT
    C3 -->|"Bearer <Google_SA_ID_Token>"| GW_JWT
    C4 -->|"Host: partner.agent-router.internal\nX-API-Key: <Key>"| GW_KEY

    GW_JWT -->|model: claude-sonnet-5| V_CLAUDE
    GW_JWT -->|model: gemini-2.5-flash| V_GEMINI
    GW_JWT -->|model: gemma-rr| K_RR
    GW_JWT -->|model: gemma-epp| K_EPP
    GW_JWT -->|model: gemma-epp-noprefix| K_NOPREF

    GW_KEY -->|model: gemma-rr| K_RR
    GW_KEY -.->|model: claude-sonnet-5 attempt| ERR_404["HTTP 404 Route Not Found\n(Blocks Unauthorized Models)"]
```

---

## 1. Environment Variables Setup

Export test environment variables in your local shell:

```bash
# Gateway external address
export GW="http://$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo <GATEWAY_IP>):8080"
export PARTNER_HOST="partner.agent-router.internal"
export GCP_PROJECT="${GCP_PROJECT:-<YOUR_PROJECT_ID>}"

echo "Target Gateway: $GW"
```

---

## 2. Scenario 1: Corporate Employee Authentication (GCIP JWT)

### 1-1. Generate Employee JWT (Department: platform)
```bash
export GT=$(python3 scripts/gcip-token.sh generate --dept platform)
python3 scripts/decode_jwt.py "$GT"
```

### 1-2. Vertex AI Gemini Call
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Respond in 5 words: Hello Gemini!"}],
    "max_tokens": 30
  }' | jq '{model: .model, content: .choices[0].message.content, finish_reason: .choices[0].finish_reason}'
```
**Expected**: Returns HTTP 200 with model response.

### 1-3. Vertex AI Claude Call
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Respond in 5 words: Hello Claude!"}],
    "max_tokens": 30
  }' | jq '{model: .model, content: .choices[0].message.content}'
```
**Expected**: Returns HTTP 200 with model response.

### 1-4. In-Cluster GPU vLLM Call (Gemma 2B)
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Respond in 5 words: Hello Gemma!"}],
    "max_tokens": 30
  }' | jq '{model: .model, content: .choices[0].message.content}'
```
**Expected**: Returns HTTP 200 from vLLM.

---

## 3. Scenario 2: Anti-Spoofing Security Verification (`/authtest`)

Verify that Envoy Gateway strips or overwrites forged tenant headers using the token's authenticated claim:

```bash
# Attacker attempts to forge x-tenant-id: finance-vip
curl -s -X POST "$GW/authtest" \
  -H "Authorization: Bearer $GT" \
  -H "x-tenant-id: finance-vip" \
  -H "Content-Type: application/json" \
  -d '{"test": "spoofing-probe"}' | jq '{
    received_tenant: .headers["x-tenant-id"],
    probe_result: (if .headers["x-tenant-id"] == "platform" then "PASS: Spoofing Prevented" else "FAIL: Spoofed" end)
  }'
```
**Expected**: `received_tenant` is `"platform"`, returning `"PASS: Spoofing Prevented"`.

---

## 4. Scenario 3: Internal Microservice Authentication (Google SA ID Token)

Verify authentication using standard Google Service Account tokens from GKE metadata or local credentials:

```bash
export GSA_TOKEN=$(gcloud auth print-identity-token --audiences="https://gateway.example.com" 2>/dev/null || gcloud auth print-identity-token)

curl -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GSA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Microservice test."}],
    "max_tokens": 15
  }' | jq '{model: .model, content: .choices[0].message.content}'
```
**Expected**: Returns HTTP 200 without requiring static credentials.

---

## 5. Scenario 4: External Partner API Key Authentication

### 4-1. Issue Partner API Key via Key Issuer
```bash
export KEYISSUER_POD=$(kubectl get pod -n routing -l app=keyissuer -o jsonpath='{.items[0].metadata.name}')

export PARTNER_KEY=$(kubectl exec -n routing $KEYISSUER_POD -- \
  python3 -c "
import urllib.request, json
req = urllib.request.Request(
    'http://localhost:8080/issue',
    data=json.dumps({'client_id': 'partner-manual-test', 'department': 'partner-eval'}).encode(),
    headers={'Content-Type': 'application/json'}
)
print(json.loads(urllib.request.urlopen(req).read())['api_key'])
")
echo "Issued Key: ${PARTNER_KEY:0:25}..."
```

### 4-2. Verify Partner Route Access
```bash
curl -s -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $PARTNER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Partner call test."}],
    "max_tokens": 20
  }' | jq '{model: .model, content: .choices[0].message.content}'
```
**Expected**: Returns HTTP 200.

---

## 6. Scenario 5: Unauthorized Access & Block Verification

### 5-1. Request Without Authentication (Expect HTTP 401)
```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "unauth"}]}'
```
**Expected**: `HTTP Status: 401`.

### 5-2. Expired or Invalid Token (Expect HTTP 401)
```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.invalid.signature" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "tampered"}]}'
```
**Expected**: `HTTP Status: 401`.

### 5-3. Partner Domain Invalid Key (Expect HTTP 401)
```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: pk-partner-invalid-key-99999" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "bad key"}]}'
```
**Expected**: `HTTP Status: 401`.

### 5-4. Partner Domain Requesting Unauthorized Model (Expect HTTP 404)
```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $PARTNER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-5", "messages": [{"role": "user", "content": "cost leak probe"}]}'
```
**Expected**: `HTTP Status: 404` (Model is not exposed in `partner-router`).

---

## 7. Scenario 6: Multi-Tenant Quota & Rate Limit Verification (Redis)

### 6-1. Issue Separate Keys for Low and High Quota Tenants
```bash
# Low quota: acme-corp (60 tokens/min limit)
export ACME_KEY=$(kubectl exec -n routing $KEYISSUER_POD -- \
  python3 -c "import urllib.request, json; req = urllib.request.Request('http://localhost:8080/issue', data=json.dumps({'client_id':'acme-corp','department':'partner'}).encode(), headers={'Content-Type':'application/json'}); print(json.loads(urllib.request.urlopen(req).read())['api_key'])")

# High quota: globex (500 tokens/min limit)
export GLOBEX_KEY=$(kubectl exec -n routing $KEYISSUER_POD -- \
  python3 -c "import urllib.request, json; req = urllib.request.Request('http://localhost:8080/issue', data=json.dumps({'client_id':'globex','department':'partner'}).encode(), headers={'Content-Type':'application/json'}); print(json.loads(urllib.request.urlopen(req).read())['api_key'])")
```

### 6-2. Trigger Quota Exhaustion for acme-corp
```bash
for i in 1 2 3; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GW/v1/chat/completions" \
    -H "Host: $PARTNER_HOST" \
    -H "X-API-Key: $ACME_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "Generate a detailed 30-word response."}], "max_tokens": 40}')
  echo "acme-corp call #$i: HTTP $CODE"
done
```
**Expected**: Call #1 and #2 return HTTP 200; subsequent calls return `HTTP 429`.

### 6-3. Verify Resource Isolation for globex
```bash
curl -s -o /dev/null -w "globex HTTP Status: %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $GLOBEX_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemma-rr", "messages": [{"role": "user", "content": "Quick test."}], "max_tokens": 15}'
```
**Expected**: Returns `HTTP 200`, proving `acme-corp`'s throttling does not affect `globex`.

---

## 8. Scenario 7: Prefix Caching & EPP Routing Verification

### 8-1. Warm Up Long System Prompt (~2,000 Tokens)
```bash
LONG_PROMPT="You are a principal cloud enterprise architect. Analyze the distributed systems architecture, resilience mechanisms, and high-availability design for the following specifications in comprehensive detail: $(python3 -c 'print("System requirement block: " + "alpha beta gamma delta epsilon " * 350)')"

# Request 1 (Cold Cache)
curl -s -w "\nCold TTFT/Total: %{time_starttransfer}s / %{time_total}s\n" -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma-epp\",
    \"messages\": [{\"role\": \"system\", \"content\": \"$LONG_PROMPT\"}, {\"role\": \"user\", \"content\": \"Summarize phase 1.\"}],
    \"max_tokens\": 20
  }" | jq -r '.choices[0].message.content // empty'
```

### 8-2. Request 2 (Warm Cache Hit)
```bash
curl -s -w "\nWarm TTFT/Total: %{time_starttransfer}s / %{time_total}s\n" -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma-epp\",
    \"messages\": [{\"role\": \"system\", \"content\": \"$LONG_PROMPT\"}, {\"role\": \"user\", \"content\": \"Summarize phase 2.\"}],
    \"max_tokens\": 20
  }" | jq -r '.choices[0].message.content // empty'
```
**Expected**: Request 2 exhibits a **4x to 6x latency reduction** compared to Request 1.

---

## 9. Scenario 8: Arize Phoenix Observability Verification

1. Start port-forwarding to the Arize Phoenix service:
   ```bash
   kubectl port-forward -n phoenix svc/phoenix-service 6006:6006
   ```
2. Open `http://localhost:6006` in your browser.
3. Verify traces in the **Traces** view:
   - Status 200 OK spans for Gemini, Claude, and Gemma.
   - Span attributes: `gen_ai.request.model`, `gen_ai.usage.prompt_tokens`, `gen_ai.usage.completion_tokens`.
   - Latency metrics across ext-proc and backend execution phases.

---

## 10. Scenario 9: Google Cloud Monitoring & Prometheus Metrics Verification

Check real-time prefix cache metrics scraped from vLLM pods:

```bash
POD1=$(kubectl get pods -n vllm -l app=vllm-server -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n vllm $POD1 -c vllm -- curl -s http://localhost:8000/metrics | grep -E 'vllm:prefix_cache_hit|vllm:num_requests_running|vllm:gpu_cache_usage_factor'
```

---

## 11. Scenario 10: Claude Code CLI Direct Integration

Configure Claude Code on your local machine or Cloud Workstation to route through Envoy AI Gateway:

```bash
# 1. Obtain GCIP token
export GT=$(python3 scripts/gcip-token.sh generate --dept platform)

# 2. Set Claude Code environment variables
export ANTHROPIC_BASE_URL="$GW"
export ANTHROPIC_AUTH_TOKEN="$GT"
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_USE_VERTEX

# 3. Test non-interactive prompt
claude -p "Respond in 5 words: Hello Claude Code via Envoy AI Gateway!"
```
**Expected**: Returns model response routed through Envoy AI Gateway with JWT validation and header injection applied transparently.

---

## 12. Verification Summary Checklist

| # | Check Item | Expected Result | Verified |
|---|---|---|---|
| 1 | Gemini 2.5 Flash routing | HTTP 200, valid text generation | [ ] |
| 2 | Claude Sonnet 5 routing | HTTP 200, valid text generation | [ ] |
| 3 | Gemma 2B (gemma-rr) routing | HTTP 200 from in-cluster vLLM | [ ] |
| 4 | Anti-spoofing (`/authtest`) | Forced overwrite of forged tenant header | [ ] |
| 5 | Google SA ID Token auth | HTTP 200 via Workload Identity | [ ] |
| 6 | Partner API Key auth | HTTP 200 via `partner.agent-router.internal` | [ ] |
| 7 | Unauthenticated request rejection | HTTP 401 Unauthorized | [ ] |
| 8 | Unauthorized model access rejection | HTTP 404 Route Not Found | [ ] |
| 9 | Multi-tenant quota isolation | Target tenant throttled (429), other tenant normal (200) | [ ] |
| 10 | EPP prefix cache acceleration | 4x to 6x latency reduction on warm prompt | [ ] |
| 11 | Arize Phoenix trace persistence | Traces visible on `:6006` backed by Cloud SQL | [ ] |
| 12 | Claude Code CLI integration | Direct prompt execution via gateway endpoint | [ ] |
