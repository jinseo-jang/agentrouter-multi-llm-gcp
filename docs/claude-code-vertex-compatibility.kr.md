# Claude Code 및 Vertex AI / Envoy AI Gateway 호환성 분석 가이드

> **Language**: [English](claude-code-vertex-compatibility.md) | **한국어**

본 문서는 Claude Code(v2.1+) 클라이언트로 Envoy AI Gateway 또는 Google Cloud Vertex AI 엔드포인트를 호출할 때 발생하는 `advisor-tool-2026-03-01` 베타 헤더 오류의 원인을 분석합니다. 아울러 즉시 적용 가능한 클라이언트 조치 방법과 게이트웨이 차원의 장기 아키텍처 해결 방안을 다룹니다.

---

## 1. 현상 및 에러 로그

Google Cloud Workstations 또는 로컬 개발 환경에서 최신 버전의 Claude Code(예: `v2.1.272`)를 실행하여 프롬프트를 입력하면 아래와 같은 `HTTP 400 Bad Request` 오류가 발생합니다.

```text
 ▐▛███▛█   Claude Code v2.1.272
▝▜██████▀  Sonnet 5 with medium effort · API Usage Billing
  ▝▝ ▝▝    /tmp/test

❯ hi

● API Error: 400 Unexpected value(s) `advisor-tool-2026-03-01` for the `anthropic-beta` header. Please consult our documentation at platform.claude.com/docs or try again without the header.
```

이 현상은 Envoy AI Gateway를 경유할 때뿐만 아니라 `CLAUDE_CODE_USE_VERTEX=1` 설정으로 Google Cloud Vertex AI 엔드포인트를 직접 호출할 때도 동일하게 나타납니다.

---

## 2. Advisor Tool(`advisor-tool-2026-03-01`) 기능 분석

문제의 원인이 된 `advisor-tool-2026-03-01`은 Anthropic이 도입한 **Advisor Tool(조언자 도구)** 베타 기능을 활성화하기 위한 식별자입니다.

### 2.1 공식 문서 출처 (Citations)
- **영문 공식 문서**: [Claude Platform Docs — Advisor tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool)
- **국문 공식 문서**: [Claude Platform Docs — Advisor 도구](https://platform.claude.com/docs/ko/agents-and-tools/tool-use/advisor-tool)
- **공식 명세 인용**:
  > *"Pair a faster executor model with a higher-intelligence advisor model that provides strategic guidance mid-generation."*  
  > *"The advisor tool is in beta. Include the beta header `advisor-tool-2026-03-01` in your requests."*

### 2.2 동작 원리 (Executor + Advisor 하이브리드 추론)
Advisor Tool은 단일 모델만으로 에이전트를 구동할 때 발생하는 비용과 지능 사이의 딜레마를 해결하기 위해 고안된 서버 사이드 오케스트레이션 기능입니다.

1. **Executor(실행자) 모델의 기본 수행**:
   - 속도가 빠르고 비용이 저렴한 실행자 모델(예: `claude-sonnet-5` 또는 `claude-haiku-4-5`)이 파일 탐색이나 단순 코드 수정 같은 일상적인 에이전트 작업의 대부분을 처리합니다.
2. **생성 도중(Mid-generation) 조언 요청**:
   - 실행자 모델이 작업을 진행하다가 복잡한 아키텍처 결정이나 고도의 추론이 필요한 분기점을 만나면 스스로 `advisor` 서버 도구(`server_tool_use`)를 호출합니다.
3. **서버 내부 Advisor 호출 및 스트림 재개**:
   - 클라이언트와의 연결을 끊지 않은 상태에서 Anthropic API 서버가 내부적으로 상위 모델인 **Advisor(조언자) 모델**(예: `claude-opus-4-6`)에게 현재까지의 전체 대화 맥락을 전달합니다.
   - Advisor 모델이 약 400~700 토큰 분량의 전략적 가이드나 수정 계획(`advisor_tool_result`)을 반환하면 실행자 모델이 이를 바탕으로 즉시 작업을 이어갑니다.

### 2.3 Claude Code의 자동 주입 동작
장시간 코드를 분석하고 수정하는 Claude Code 특성상 매 턴마다 무거운 Opus 모델을 호출하면 비용과 지연 시간이 크게 증가합니다. 이에 따라 최신 Claude Code는 기본 모델을 Sonnet으로 설정했을 때 비용 효율과 추론 품질을 동시에 확보하고자 요청마다 아래 두 가지 요소를 자동으로 주입합니다.

1. **HTTP 요청 헤더**:
   ```http
   anthropic-beta: advisor-tool-2026-03-01
   ```
2. **JSON 요청 바디 (`tools` 배열 내 도구 정의)**:
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

## 3. 근본 원인: Anthropic 1st-Party API vs Google Cloud Vertex AI 아키텍처 차이

이 에러는 Envoy AI Gateway의 결함이 아니라 업스트림 백엔드인 **Google Cloud Vertex AI가 해당 베타 기능과 스키마를 지원하지 않아 거부하는 현상**입니다.

### 3.1 왜 Vertex AI에서는 지원되지 않는가?
- **단일 요청 내 다중 모델(Cross-Model) 라우팅의 제약**:
  - Anthropic 자체 플랫폼(`api.anthropic.com`)은 모든 Claude 모델 풀을 단일 오케스트레이터 아래 통합 관리합니다. 하나의 `/v1/messages` 요청 안에서 Sonnet 스트림을 잠시 멈추고 내부적으로 Opus 모델을 호출한 뒤 두 모델의 토큰 사용량을 각각 합산해 과금하는 서버 사이드 라우팅이 즉시 가능합니다.
  - 반면 Google Cloud Vertex AI(`aiplatform.googleapis.com`)는 각 모델이 독립된 GCP Publisher Model 엔드포인트(`/projects/.../models/claude-sonnet-5:streamRawPredict` 및 `.../models/claude-opus-4-6:streamRawPredict`)로 격리되어 있습니다.
  - GCP의 IAM 권한 검증과 리전별 쿼터(Quota) 및 과금 미터링(Billing) 파이프라인이 호출된 단일 엔드포인트 기준으로 동작하기 때문에 Sonnet 엔드포인트로 유입된 요청이 GCP 내부에서 임의로 Opus 엔드포인트를 호출할 수 없습니다.

### 3.2 실측 검증: Vertex AI의 이중 차단(Double Validation) 메커니즘
실제 Envoy AI Gateway를 경유하여 Vertex AI 백엔드로 `curl` 요청을 전송해 보면 Vertex AI 서빙 엔진(`harpoon`)이 두 단계에 걸쳐 엄격한 허용 목록(Allowlist) 검증을 수행함을 확인할 수 있습니다.

#### ① 1차 차단: HTTP 헤더 검증 단계
`anthropic-beta: advisor-tool-2026-03-01` 헤더를 포함하여 호출한 경우:
```bash
curl -i -X POST http://<GATEWAY_IP>:8080/anthropic/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: advisor-tool-2026-03-01" \
  -d '{"model":"claude-sonnet-5","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```
- **실측 응답 (`HTTP 400 Bad Request`)**:
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

#### ② 2차 차단: JSON 바디 `tools` 스키마 검증 단계
게이트웨이에서 `anthropic-beta` 헤더만 단순 제거하고 바디의 `advisor_20260301` 도구 정의를 그대로 둔 채 호출한 경우:
```bash
curl -i -X POST http://<GATEWAY_IP>:8080/anthropic/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-5","max_tokens":10,"tools":[{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-6"}],"messages":[{"role":"user","content":"hi"}]}'
```
- **실측 응답 (`HTTP 400 Bad Request`)**:
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

즉 헤더만 지우는 단순 프록시 설정으로는 바디 검증 단계에서 다시 400 에러가 발생하므로 완전한 해결책이 될 수 없습니다.

---

## 4. 표준 해결 방안: 클라이언트 실험적 베타 비활성화 (권장)

Vertex AI 백엔드나 Envoy AI Gateway를 사용할 때 가장 확실하고 표준적인 해결 방법은 Claude Code 클라이언트가 실험적 베타 헤더와 도구를 주입하지 않도록 환경 변수를 지정하는 것입니다.

### 4.1 환경 변수 설정 (`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`)
터미널 세션 또는 `~/.bashrc` 파일에 아래 환경 변수를 선언합니다.

```bash
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

### 4.2 `~/.claude/settings.json` 영구 반영
Claude Code의 전역 설정 파일(`~/.claude/settings.json`) 내 `env` 블록에 해당 값을 추가하면 모든 세션에 영구 적용됩니다. 본 저장소의 [`scripts/prepare_ws_settings.py`](../scripts/prepare_ws_settings.py) 스크립트는 이 설정을 자동으로 주입하도록 구성되어 있습니다.

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

이 플래그를 활성화하면 Claude Code가 `anthropic-beta: advisor-tool-2026-03-01` 헤더와 바디의 `advisor_20260301` 도구 정의를 모두 생략하므로 Vertex AI 직결 모드와 Envoy AI Gateway 경유 모드 양쪽에서 에러 없이 즉시 정상 동작합니다.

---

## 5. 게이트웨이 수준 Long-Term 아키텍처 레퍼런스

다수의 개발자 워크스테이션 환경을 개별 통제하기 어려운 엔터프라이즈 환경에서는 클라이언트가 어떤 실험적 헤더나 필드를 보내더라도 **Envoy AI Gateway가 중간에서 이를 자동 정제(Sanitize)하여 Vertex AI로 전달**하는 완충 계층(Compatibility Layer) 아키텍처를 도입할 수 있습니다.

### 5.1 아키텍처 대안 비교

| 평가 항목 | 방안 A: EnvoyExtensionPolicy (Lua 필터) | 방안 B: HTTPRouteFilter (HeaderModifier) | 방안 C: Custom ExtProc (gRPC 서버) |
|---|:---:|:---:|:---:|
| **헤더(`anthropic-beta`) 선별 제거** | 가능 (특정 플래그만 정밀 제거) | 불가능 (헤더 전체 삭제만 가능) | 가능 |
| **바디(`tools` 내 `advisor`) 제거** | 가능 | 불가능 (**2차 400 에러 발생**) | 가능 (완전한 JSON AST 파싱) |
| **추가 파드/인프라 배포** | 불필요 (CRD YAML 1개만 추가) | 불필요 | 필요 (별도 Deployment 운영) |
| **네트워크 지연 (Latency)** | 없음 (< 0.1ms 인메모리 처리) | 없음 | 낮음 (1~3ms gRPC 홉 추가) |

### 5.2 `EnvoyExtensionPolicy` (Lua HTTP Filter) 구현 레퍼런스
Envoy Gateway가 기본 지원하는 `EnvoyExtensionPolicy` CRD를 활용하면 외부 컨테이너 추가 없이 게이트웨이 내부에서 헤더와 JSON 바디를 동시에 정규화할 수 있습니다.

*(전제 조건: 대상 `AIGatewayRoute` 또는 `HTTPRoute`에 `aigateway.envoyproxy.io/processing-body-mode: buffered` 어노테이션이 설정되어 있어야 바디 버퍼링 및 수정이 가능합니다.)*

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

          -- 1. anthropic-beta 헤더에서 Vertex AI 미지원 플래그 선별 제거
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

          -- 2. JSON 바디 내 advisor_20260301 도구 정의 제거
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

### 5.3 운영 권장 전략 요약
1. **기본 정책**: 워크스테이션 배포 스크립트([`scripts/prepare_ws_settings.py`](../scripts/prepare_ws_settings.py))와 사용자 설정(`~/.claude/settings.json`)에 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1"`을 기본 적용하여 클라이언트 단에서 불필요한 실험적 페이로드 생성을 원천 차단합니다.
2. **게이트웨이 방어선**: 클라이언트가 환경 변수를 누락하더라도 서비스 중단이 발생하지 않도록 필요시 5.2절의 `EnvoyExtensionPolicy`를 게이트웨이에 함께 배치하여 이중 방어 체계를 구축합니다.
