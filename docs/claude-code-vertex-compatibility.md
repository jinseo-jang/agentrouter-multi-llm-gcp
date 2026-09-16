# Claude Code Compatibility Guide for Vertex AI & Envoy AI Gateway

> **Language**: **English** | [한국어](claude-code-vertex-compatibility.kr.md)

This document analyzes the root cause of the `advisor-tool-2026-03-01` beta header error (`HTTP 400 Bad Request`) that occurs when invoking Google Cloud Vertex AI or Envoy AI Gateway from Claude Code (v2.1+). It provides immediate client-side remediation steps as well as long-term gateway-level architectural solutions.

---

## 1. Symptom & Error Log

When running recent versions of Claude Code (e.g., `v2.1.272`) on Google Cloud Workstations or local development environments, submitting any prompt triggers an immediate `HTTP 400 Bad Request` error:

```text
 ▐▛███▛█   Claude Code v2.1.272
▝▜██████▀  Sonnet 5 with medium effort · API Usage Billing
  ▝▝ ▝▝    /tmp/test

❯ hi

● API Error: 400 Unexpected value(s) `advisor-tool-2026-03-01` for the `anthropic-beta` header. Please consult our documentation at platform.claude.com/docs or try again without the header.
```

This failure occurs both when routing through Envoy AI Gateway and when invoking Google Cloud Vertex AI directly (`CLAUDE_CODE_USE_VERTEX=1`).

---

## 2. What is the Advisor Tool (`advisor-tool-2026-03-01`)?

The `advisor-tool-2026-03-01` identifier activates Anthropic's **Advisor Tool** beta feature.

### 2.1 Official Documentation Citations
- **Official Documentation**: [Claude Platform Docs — Advisor tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool)
- **Korean Documentation**: [Claude Platform Docs — Advisor 도구](https://platform.claude.com/docs/ko/agents-and-tools/tool-use/advisor-tool)
- **Official Specification Excerpt**:
  > *"Pair a faster executor model with a higher-intelligence advisor model that provides strategic guidance mid-generation."*  
  > *"The advisor tool is in beta. Include the beta header `advisor-tool-2026-03-01` in your requests."*

### 2.2 Mechanism (Executor + Advisor Hybrid Reasoning Pattern)
The Advisor Tool is a server-side orchestration capability designed to balance cost efficiency and frontier intelligence in long-horizon agentic workflows:

1. **Executor Model Execution**:
   - A fast, cost-effective executor model (e.g., `claude-sonnet-5` or `claude-haiku-4-5`) handles the vast majority of routine, mechanical operations such as file exploration, code scaffolding, and simple tool calls.
2. **Mid-Generation Consultation**:
   - When the executor encounters a complex architectural decision or requires deep reasoning, it emits a `server_tool_use` call to invoke the `advisor` tool mid-generation.
3. **Server-Side Advisor Routing**:
   - Without closing the client stream, Anthropic's API server internally forwards the full conversation context to a higher-intelligence **Advisor Model** (e.g., `claude-opus-4-6`).
   - The advisor produces a concise strategic plan or course correction (typically 400–700 tokens as an `advisor_tool_result`), and the executor immediately resumes generation informed by that guidance.

### 2.3 Automatic Injection by Claude Code
Because Claude Code operates as a long-horizon coding agent, running an Opus model for every single turn incurs high latency and token costs. To optimize performance when Sonnet is selected, Claude Code automatically injects two elements into outgoing `/v1/messages` requests:

1. **HTTP Request Header**:
   ```http
   anthropic-beta: advisor-tool-2026-03-01
   ```
2. **JSON Request Body (`tools` Array Definition)**:
   ```json
   {
     "model": "claude-sonnet-5",
     "tools": [
       {
         "type": "advisor_20260301",
         "name": "advisor",
         "model": "claude-opus-4-6",
         "max_uses": 3
       }
     ]
   }
   ```

---

## 3. Root Cause: Anthropic 1st-Party API vs. Google Cloud Vertex AI Architecture

This error is not a bug in Envoy AI Gateway. Rather, the upstream backend (**Google Cloud Vertex AI**) does not support this beta feature and strictly rejects unrecognized headers and schema tags.

### 3.1 Why is it Unsupported on Vertex AI?
- **Cross-Model Routing vs. Endpoint Isolation**:
  - Anthropic's 1st-party platform (`api.anthropic.com`) manages all Claude model pools under a unified orchestrator. It can pause a Sonnet stream mid-request, internally invoke Opus, and meter tokens across both models within a single HTTP request.
  - Conversely, Google Cloud Vertex AI (`aiplatform.googleapis.com`) exposes each model as a strictly isolated GCP Publisher Model endpoint (`/projects/.../models/claude-sonnet-5:streamRawPredict` vs. `.../models/claude-opus-4-6:streamRawPredict`).
  - Because GCP IAM authorization, regional quotas, and billing pipelines are scoped per endpoint, a prediction request targeting the Sonnet endpoint cannot dynamically jump to the Opus endpoint inside Vertex AI's serving infrastructure (`harpoon`).

### 3.2 Empirical Verification: Vertex AI's Double Validation Mechanism
Direct `curl` tests through Envoy AI Gateway to Vertex AI demonstrate that Vertex AI enforces strict allowlist validation at **two distinct layers**:

#### Layer 1: HTTP Header Validation (`anthropic-beta`)
When sending the request with `-H "anthropic-beta: advisor-tool-2026-03-01"`:
```bash
curl -i -X POST http://<GATEWAY_IP>:8080/anthropic/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: advisor-tool-2026-03-01" \
  -d '{"model":"claude-sonnet-5","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```
- **Live Response (`HTTP 400 Bad Request`)**:
  ```http
  HTTP/1.1 400 Bad Request
  x-vertex-ai-internal-prediction-backend: harpoon
  request-id: req_vrtx_011Cf69ffRgRk2w8QxkdR5ZA

  {
    "type": "error",
    "error": {
      "type": "invalid_request_error",
      "message": "Unexpected value(s) `advisor-tool-2026-03-01` for the `anthropic-beta` header. Please consult our documentation at platform.claude.com/docs or try again without the header."
    }
  }
  ```

#### Layer 2: JSON Body Schema Validation (`tools` Array)
If the gateway strips the `anthropic-beta` header but leaves the `advisor_20260301` tool definition in the JSON body:
```bash
curl -i -X POST http://<GATEWAY_IP>:8080/anthropic/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-5","max_tokens":10,"tools":[{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-6"}],"messages":[{"role":"user","content":"hi"}]}'
```
- **Live Response (`HTTP 400 Bad Request`)**:
  ```http
  HTTP/1.1 400 Bad Request
  x-vertex-ai-internal-prediction-backend: harpoon
  request-id: req_vrtx_011Cf69mJL5zmnNWDZji9DuH

  {
    "type": "error",
    "error": {
      "type": "invalid_request_error",
      "message": "tools.0: Input tag 'advisor_20260301' found using 'type' does not match any of the expected tags: 'bash_20250124', 'browser_toolset_20260801', 'computer_toolset_20260801', 'custom', 'memory_20250818', 'text_editor_20250124', 'text_editor_20250429', 'text_editor_20250728', 'tool_search_tool_bm25', 'tool_search_tool_bm25_20251119', 'tool_search_tool_regex', 'tool_search_tool_regex_20251119', 'web_search_20250305'"
    }
  }
  ```

Consequently, simply removing the HTTP header via a basic proxy rule is insufficient because the request will still fail at Layer 2 during body schema validation.

---

## 4. Standard Remediation: Disabling Client Experimental Betas (Recommended)

The cleanest and most reliable solution when targeting Vertex AI or Envoy AI Gateway is instructing the Claude Code client to disable experimental beta injections.

### 4.1 Environment Variable Configuration (`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`)
Export the variable in your shell session or add it to `~/.bashrc`:

```bash
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

### 4.2 Persistent Configuration via `~/.claude/settings.json`
Add the flag to the `env` block in `~/.claude/settings.json` so it applies across all invocations. The helper script [`scripts/prepare_ws_settings.py`](../scripts/prepare_ws_settings.py) in this repository automatically injects this key:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://<GATEWAY_IP>:8080/anthropic",
    "ANTHROPIC_MODEL": "claude-sonnet-5",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  },
  "model": "claude-sonnet-5"
}
```

With this setting enabled, Claude Code omits both the `anthropic-beta: advisor-tool-2026-03-01` header and the `advisor_20260301` tool entry, ensuring seamless operation across both direct Vertex AI and Envoy AI Gateway modes.

---

## 5. Gateway-Level Long-Term Architecture Reference

In enterprise environments where enforcing environment variables across hundreds of developer workstations is impractical, **Envoy AI Gateway can act as a centralized Compatibility Layer** that automatically sanitizes incompatible headers and payload fields before forwarding requests to Vertex AI.

### 5.1 Architectural Options Comparison

| Evaluation Criteria | Option A: EnvoyExtensionPolicy (Lua Filter) | Option B: HTTPRouteFilter (HeaderModifier) | Option C: Custom ExtProc (gRPC Service) |
|---|:---:|:---:|:---:|
| **Selective Header Filtering (`anthropic-beta`)** | Supported (granular token filtering) | Unsupported (drops entire header only) | Supported |
| **Body Tool Removal (`advisor_20260301`)** | Supported | Unsupported (**Fails with Layer 2 HTTP 400**) | Supported (full JSON AST parsing) |
| **Extra Pod / Infrastructure Deployment** | None (single CRD YAML manifest) | None | Required (separate Deployment/Service) |
| **Added Network Latency** | Negligible (< 0.1ms in-memory LuaJIT) | None | Low (~1–3ms gRPC hop) |

### 5.2 Reference Implementation: `EnvoyExtensionPolicy` (Lua HTTP Filter)
Using Envoy Gateway's native `EnvoyExtensionPolicy` CRD, both the HTTP header and JSON request body can be sanitized in-flight without deploying additional containers.

*(Prerequisite: The target `AIGatewayRoute` or `HTTPRoute` must have `aigateway.envoyproxy.io/processing-body-mode: buffered` enabled to allow body inspection and mutation.)*

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: anthropic-vertex-compat-sanitizer
  namespace: routing
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: envoy-ai-gateway
  lua:
    - type: Inline
      inline: |
        function envoy_on_request(request_handle)
          local path = request_handle:headers():get(":path")
          if not path or not string.find(path, "^/anthropic") then
            return
          end

          -- 1. Strip unsupported flags from anthropic-beta header
          local beta_hdr = request_handle:headers():get("anthropic-beta")
          if beta_hdr then
            local valid_betas = {}
            for token in string.gmatch(beta_hdr, "([^,]+)") do
              local trimmed = token:match("^%s*(.-)%s*$")
              if not string.find(trimmed, "^advisor%-tool") and
                 not string.find(trimmed, "^prompt%-caching") then
                table.insert(valid_betas, trimmed)
              end
            end
            if #valid_betas == 0 then
              request_handle:headers():remove("anthropic-beta")
            else
              request_handle:headers():replace("anthropic-beta", table.concat(valid_betas, ","))
            end
          end

          -- 2. Remove advisor_20260301 tool definition from JSON body
          local body = request_handle:body()
          if body then
            local raw = body:getBytes(0, body:length())
            if raw and string.find(raw, "advisor_20260301", 1, true) then
              local sanitized = raw
              sanitized = string.gsub(sanitized, '%s*{[^{}]*"type"%s*:%s*"advisor_20260301"[^{}]*}%s*,?', '')
              sanitized = string.gsub(sanitized, ',%s*%]', ']')
              sanitized = string.gsub(sanitized, '"tools"%s*:%s*%[%s*%]%s*,?', '')
              sanitized = string.gsub(sanitized, ',%s*}', '}')

              body:setBytes(sanitized)
              request_handle:headers():replace("content-length", tostring(#sanitized))
            end
          end
        end
```

### 5.3 Recommended Defense-in-Depth Strategy
1. **Primary Defense (Client-Side)**: Set `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1"` in workstation provisioning scripts ([`scripts/prepare_ws_settings.py`](../scripts/prepare_ws_settings.py)) and default user profiles (`~/.claude/settings.json`) to prevent clients from generating unsupported payloads.
2. **Secondary Defense (Gateway-Side)**: Deploy the `EnvoyExtensionPolicy` sanitizer on the gateway so that unconfigured or newly updated clients continue to function without interruption.
