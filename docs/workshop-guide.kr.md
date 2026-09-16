# Agentrouter 기반 멀티 LLM 서빙 고객 워크숍 실습 가이드

> **Languages:** [English](workshop-guide.md) | [한국어](workshop-guide.kr.md)

본 가이드는 Google Kubernetes Engine(GKE) 상에서 [Agentrouter(formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router), Kubernetes Gateway API Inference Extension(GIE), llm-d-router(EPP), vLLM, Vertex AI 및 [Arize Phoenix](https://github.com/Arize-ai/phoenix) 관측성 플랫폼을 처음부터 끝까지 구축하고 검증하는 고객 실습 워크숍 교재입니다.

단순한 배포 확인을 넘어 사내 보안 인증, 파트너 쿼터 격리, 프롬프트 캐시 가속, 헤더 위조 방어, 풀스택 분산 트레이싱까지 엔터프라이즈 AI 게이트웨이의 핵심 가치를 직접 체험할 수 있도록 구성했습니다.

---

## 1. 워크숍 개요 및 아키텍처

실습 참가자는 단일 게이트웨이 엔드포인트에서 사내 업무 환경, 내부 마이크로서비스, 외부 파트너 서비스를 수용하는 엔터프라이즈 AI 서빙 인프라를 직접 구축합니다.

- **인프라 계층**: GKE Standard 클러스터와 2대의 NVIDIA L4 GPU Spot 노드풀(`g2-standard-8`), Cloud SQL PostgreSQL 16 인스턴스 및 Cloud Storage 버킷을 프로비저닝합니다.
- **추론 백엔드 계층**: Google Cloud Vertex AI(Gemini 2.5 Flash 및 Claude Sonnet 5)와 사내 호스팅 vLLM(Gemma 2B) 모델을 연동합니다.
- **지능형 라우팅 및 캐시 가속**: Kubernetes GIE 규격의 `InferencePool`과 `llm-d-router`(EPP) 접두사 캐시 스코어러를 적용해 GPU 연산 지연시간을 줄입니다.
- **다계층 보안 및 인가**: GCIP JWT, Google SA ID 토큰, 파트너 API Key 인증을 적용하고 테넌트별 토큰 예산 격리를 실습합니다.
- **풀스택 관측성**: Arize Phoenix와 Google Cloud Monitoring으로 추론 트레이스와 접두사 캐시 지표를 수집합니다.

상세 아키텍처 다이어그램 및 시퀀스 흐름은 다음 문서를 참고하십시오.
- [리소스 구조 및 계층 다이어그램](../design/gateway-architecture-diagram.kr.md)
- [시나리오별 엔드투엔드 요청 처리 시퀀스](../design/architecture-request-flow.kr.md)

---

## 2. 사전 요구사항 및 환경 준비

### 2.1 필수 로컬 도구
실습을 진행할 로컬 환경이나 Cloud Shell에 다음 도구가 설치되어 있어야 합니다.
- Google Cloud SDK (`gcloud` CLI)
- Terraform (v1.5 이상 권장)
- Kubernetes CLI (`kubectl`)
- `jq`, `curl`

### 2.2 Hugging Face Access Token 준비 (필수)
사내 호스팅 모델인 `google/gemma-2-2b-it` 가중치를 Cloud Storage로 내려받으려면 Hugging Face 계정 및 라이선스 승인이 필요합니다.
1. [Hugging Face Gemma-2-2b-it 페이지](https://huggingface.co/google/gemma-2-2b-it)에 접속하여 모델 이용 약관에 동의합니다.
2. Hugging Face 계정 `Settings > Access Tokens` 메뉴에서 `Read` 권한의 토큰을 생성하여 보관합니다.

### 2.3 GCP IAM 권한 점검
실습에 사용하는 계정은 대상 프로젝트에서 다음 IAM 역할을 보유해야 합니다.
- Kubernetes Engine 관리자 (`roles/container.admin`)
- Compute 관리자 (`roles/compute.admin`)
- Cloud SQL 관리자 (`roles/cloudsql.admin`)
- Storage 관리자 (`roles/storage.admin`)
- 서비스 계정 관리자 및 사용자 (`roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`)
- 서비스 계정 토큰 생성자 (`roles/iam.serviceAccountTokenCreator` - SA 가장 및 JWT 서명 필수)
- Vertex AI 사용자 (`roles/aiplatform.user`)

### 2.4 필수 GCP API 활성화 및 Identity Platform(GCIP) 준비
신규 GCP 프로젝트에서 실습할 경우 아래 명령어로 필수 API를 먼저 활성화합니다.
```bash
export GCP_PROJECT="<YOUR_PROJECT_ID>"
export GCP_REGION="asia-southeast1"

gcloud services enable compute.googleapis.com container.googleapis.com \
  sqladmin.googleapis.com storage.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com aiplatform.googleapis.com \
  identitytoolkit.googleapis.com firebase.googleapis.com --project=$GCP_PROJECT
```
아울러 사내 임직원 JWT 발급 스크립트(`scripts/gcip-token.sh`)를 실행하려면 GCP 콘솔의 **Identity Platform(또는 Firebase Authentication)** 메뉴에서 해당 프로젝트를 활성화하고 기본 Web App을 1개 등록해 두어야 합니다.

### 2.5 NVIDIA L4 GPU 할당량(Quota) 확인
GKE 클러스터 노드풀에서 NVIDIA L4 GPU 2대를 프로비저닝하려면 리전별 GPU 할당량이 최소 2 이상 확보되어 있어야 합니다.

다음 명령어로 대상 리전의 L4 GPU 할당량을 점검하십시오.
```bash
gcloud compute regions describe $GCP_REGION \
  --project=$GCP_PROJECT \
  --format="json" | jq -r '.quotas[] | select(.metric | contains("NVIDIA_L4_GPUS"))'
```
출력 결과의 `limit` 수치가 2 이상인지 확인하십시오. 부족한 경우 GCP 콘솔의 `IAM & Admin > Quotas` 메뉴에서 할당량 상향을 요청해야 합니다.

---

## 3. 1단계: Terraform 인프라 프로비저닝

Terraform 코드를 실행하여 VPC 네트워크, GKE 클러스터, L4 GPU 노드풀, Cloud SQL PostgreSQL 16 인스턴스, Cloud Storage 버킷 및 Workload Identity 서비스 계정을 프로비저닝합니다.

```bash
cd terraform

# 1. Terraform 초기화
terraform init

# 2. 프로비저닝 실행 (소요 시간 약 12분~15분)
terraform apply -var="project_id=$GCP_PROJECT" -var="region=$GCP_REGION" -auto-approve

# 3. GKE 클러스터 접속 자격증명 획득
gcloud container clusters get-credentials envoy-ai-gw-cluster \
  --region=$GCP_REGION \
  --project=$GCP_PROJECT

cd ..
```

---

## 4. 2단계: K8s 컴포넌트 순차 배포

매니페스트는 의존성 순서에 따라 번호별 폴더로 정렬되어 있습니다.

### 4.1 매니페스트 환경 변수 치환 및 Hugging Face 토큰 등록
사전 준비한 Hugging Face 토큰을 환경 변수로 선언한 뒤 Terraform 출력값을 기반으로 매니페스트 내 플레이스홀더를 일괄 치환합니다.
```bash
export HF_TOKEN="hf_your_token_here"

# Terraform 출력값 및 HF_TOKEN 자동 치환
make update-manifests
```

### 4.2 Vertex AI 백엔드 대리 인증용 Secret 생성
게이트웨이가 클라이언트를 대신하여 Google Cloud Vertex AI(Gemini 및 Claude)를 안전하게 호출할 수 있도록 `BackendSecurityPolicy`가 참조하는 서비스 계정 키 시크릿(`vertex-ai-sa-key`)을 생성합니다.
```bash
make setup-secrets
```
*(내부적으로 `routing` 네임스페이스를 생성한 뒤 Terraform이 만든 `envoy-ai-workload-sa` 계정의 JSON 키를 발급받아 `vertex-ai-sa-key` Secret으로 등록합니다.)*

### 4.3 기본 CRD 및 컨트롤러 설치
Envoy Gateway 및 AI Gateway CRD는 용량이 크므로 반드시 `--server-side` 옵션을 붙여 적용해야 합니다. 이어서 Envoy Gateway 컨트롤러, GIE 컨트롤러, Agent Router 컨트롤러를 설치하고 설정 반영을 위해 컨트롤러를 재시작한 뒤 파드가 준비될 때까지 대기합니다.
```bash
kubectl apply --server-side -f manifests/00-setup/envoy-gateway-crds.yaml
kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml
kubectl apply -f manifests/00-setup/envoy-gateway-controller.yaml
kubectl apply -f manifests/00-setup/gie-install.yaml
kubectl apply -f manifests/00-setup/agent-router.yaml
kubectl apply -f manifests/00-setup/envoy-gateway-config.yaml
kubectl apply -f manifests/00-setup/envoy-ai-gateway-ratelimit-svc.yaml

# 컨트롤러 설정 반영 재시작 및 준비 상태 대기
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=180s
kubectl rollout status deployment/ai-gateway-controller -n default --timeout=180s
```

### 4.4 01번부터 07번까지 순차 배포
```bash
# 1. Gateway 및 프록시 설정
kubectl apply -k manifests/01-gateway

# 2. 전역 보안 정책 및 파트너 키 관리
kubectl apply -k manifests/02-security

# 3. vLLM GPU 서빙 엔진 (모델 가중치 로더 잡 포함)
kubectl apply -k manifests/03-vllm
kubectl wait --for=condition=complete job/hf-weight-loader -n vllm --timeout=600s
kubectl rollout restart deployment/vllm-server -n vllm

# 4. GIE 추론 풀 및 llm-d-router EPP (네임스페이스 간 ReferenceGrant 포함)
kubectl apply -k manifests/04-inference-pool

# 5. 지능형 모델 라우팅 및 테스트 에코
kubectl apply -k manifests/05-routing

# 6. Redis 및 트래픽/쿼터 정책
kubectl apply -k manifests/06-traffic-policy

# 7. Arize Phoenix 및 Cloud Monitoring 대시보드 배포
kubectl apply -k manifests/07-observability

# Cloud Monitoring vLLM 커스텀 대시보드 생성 (최초 1회)
if ! gcloud monitoring dashboards list --project="$GCP_PROJECT" --filter="displayName:'vLLM Model Server Monitoring'" --format="value(name)" | grep -q .; then
  gcloud monitoring dashboards create --project="$GCP_PROJECT" \
    --config-from-file=manifests/07-observability/dashboards/vllm-dashboard.json
fi
```

### 4.5 배포 상태 점검
모든 파드가 정상 상태에 도달할 때까지 상태를 점검합니다. (`hf-weight-loader` 잡이 GCS 버킷으로 모델 가중치를 적재한 뒤 `vllm-server` 파드가 초기화되므로 약 5분~8분 소요됩니다.)
```bash
kubectl get pods -A
```
`envoy-routing-*`, `vllm-server-*`, `llm-d-router-*`, `phoenix-*` 파드가 모두 `Running` 및 `Ready` 상태인지 확인하십시오.

---

## 5. 3단계: 시나리오별 실습 및 검증

게이트웨이 외부 IP를 확인하고 환경 변수를 등록합니다.
```bash
export GW="http://$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}'):8080"
export PARTNER_HOST="partner.agent-router.internal"
echo "게이트웨이 진입점: $GW"
```

---

### 5.1 사전 점검: 게이트웨이 및 모델 라우트 헬스체크

게이트웨이가 정상 구동 중인지 기본 헬스 엔드포인트를 점검합니다.
```bash
curl -s -o /dev/null -w "%{http_code}\n" "$GW"
```
응답 코드가 `404`로 반환되면 게이트웨이가 정상 수신 대기 중인 상태입니다. (루트 경로 규칙이 없으므로 정상 응답입니다.)

---

### 5.2 시나리오 1: 사내 임직원 REST API (GCIP JWT) & Vertex AI 모델 호출

사내 IdP(GCIP)에서 발급한 JWT 서명 토큰을 게이트웨이 관문에 제출한 뒤 백엔드의 Google Cloud Vertex AI 모델(Gemini 및 Claude)을 호출합니다.

```bash
# 1. 사내 토큰 발급 (부서: platform)
export GT=$(./scripts/gcip-token.sh alice platform)

# 2. Vertex AI Gemini 2.5 Flash 호출
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.5-flash",
    "messages": [{"role": "user", "content": "Kubernetes Gateway API 장점을 한 줄로 요약해줘."}],
    "max_tokens": 1500
  }' | jq .
```
- **기대 결과**: HTTP `200 OK`, 클라이언트가 별도 GCP IAM 권한이나 API 키를 갖지 않아도 게이트웨이가 백엔드 자격증명(`BackendSecurityPolicy`)으로 Vertex AI를 대리 호출하여 한국어 응답을 반환합니다.

```bash
# 3. Vertex AI Claude Sonnet 5 호출 (Messages 규격)
curl -sS -X POST "$GW/anthropic/v1/messages" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Say hello in Korean"}],
    "max_tokens": 30
  }' | jq .
```
- **기대 결과**: HTTP `200 OK`, `type: "message"` 규격으로 Claude 응답 반환.

#### 5.2.1 사내 임직원 AI 코딩 에이전트 (Claude Code CLI) 연동 실습
개발자가 Cloud Workstation이나 로컬 터미널에서 Claude Code(`claude` CLI)를 사용할 때, 개별 GCP 권한 없이도 게이트웨이와 `apiKeyHelper`를 거쳐 안전하게 모델을 사용하는 구성입니다.

```bash
# 1. Claude Code 게이트웨이 연동 설정 생성 스크립트 실행
python3 scripts/prepare_ws_settings.py

# 2. 생성된 설정(/tmp/new_settings.json)을 Claude Code 설정 경로에 반영
mkdir -p ~/.claude
cp /tmp/new_settings.json ~/.claude/settings.json
```
- **핵심 설정 포인트**:
  - `"ANTHROPIC_BASE_URL": "$GW/anthropic"`: 모든 추론 요청을 Envoy AI Gateway의 Anthropic 호환 경로로 라우팅합니다.
  - `"apiKeyHelper"`: 호출 시마다 `gcip-token.sh`를 실행해 신선한 사내 JWT 토큰을 동적으로 주입합니다.
  - `"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"`: 최신 Claude Code가 자동 주입하는 실험적 베타 헤더(`advisor-tool-2026-03-01`)와 Vertex AI 간 호환성 충돌을 방지합니다. 상세 원리는 [Claude Code 및 Vertex AI 호환성 가이드](claude-code-vertex-compatibility.kr.md)를 참고하십시오.

```bash
# 3. Claude Code 단발성 프롬프트 실행 검증
claude -p "안녕! 3단어로 답해줘"
```
- **기대 결과**: 종료 코드 `0`과 함께 한국어 3단어 응답이 정상 출력되며, 게이트웨이 액세스 로그에 `200 OK`가 기록됩니다.

---

### 5.3 시나리오 2: 보안 검증: 클라이언트 헤더 위조 방어 (`/authtest`)

악의적인 클라이언트가 요청 헤더에 임의로 부서명(`x-tenant-id: finance-vip`)을 실어 보내더라도 게이트웨이가 JWT 클레임(`department: platform`)으로 강제 덮어쓰는지 점검합니다.

> [!NOTE]
> `/authtest` 엔드포인트는 게이트웨이가 보안 정책을 거쳐 백엔드로 전달하는 최종 HTTP 헤더를 눈으로 확인하기 위해 배포한 테스트 전용 에코 서버(`mendhak/http-https-echo`)입니다.

```bash
curl -sS -X POST "$GW/authtest" \
  -H "Authorization: Bearer $GT" \
  -H "x-tenant-id: finance-vip" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .headers
```
- **기대 결과**: 에코 서버 수신 헤더의 `"x-tenant-id"`가 클라이언트가 위조한 `"finance-vip"`가 아닌 JWT 서명 클레임인 `"platform"`으로 기록되어 헤더 위조 공격이 원천 차단됩니다.

---

### 5.4 시나리오 3: 내부 마이크로서비스 (Google SA ID 토큰)

GKE 내부에서 동작하는 배치 잡이나 마이크로서비스가 정적 키 없이 Workload Identity SA ID 토큰을 활용해 사내 호스팅 모델(`gemma-rr`)을 호출하는 절차입니다. 로컬 셸에서는 `--impersonate-service-account` 옵션으로 서비스 계정 자격증명을 가장하여 동일한 토큰을 발급받습니다.

```bash
# 1. Google SA ID 토큰 발급 (SA 가장 및 Audience 지정 필수)
export SA_EMAIL="envoy-ai-workload-sa@${GCP_PROJECT}.iam.gserviceaccount.com"
export SA_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="$SA_EMAIL" \
  --audiences=https://agent-router.internal \
  --include-email)

# 2. 사내 호스팅 Gemma 2B 모델 호출
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-rr",
    "messages": [{"role": "user", "content": "Healthcheck from microservice"}],
    "max_tokens": 15
  }' | jq .
```
- **기대 결과**: HTTP `200 OK`, `system_fingerprint`에 `vllm-0.29.0` 표기.
- 게이트웨이가 토큰의 `email` 클레임을 읽어 백엔드 `x-tenant-id` 헤더에 서비스 계정 주소를 자동 주입합니다. (동일하게 `$GW/authtest`로 확인 가능)

---

### 5.5 시나리오 4: 외부 파트너 연동 및 쿼터 격리 (API Key)

외부 파트너사가 사전에 발급받은 API 키로 게이트웨이에 접근할 때 인가된 모델만 호출할 수 있고 파트너별 분당 토큰 예산이 엄격히 격리되는지 검증합니다.

```bash
# 1. 사전 배포된 파트너 API 키 확인
export AK=$(kubectl get secret partner-api-keys -n routing -o jsonpath='{.data.acme-corp}' | base64 -d)
export GK=$(kubectl get secret partner-api-keys -n routing -o jsonpath='{.data.globex}' | base64 -d)

# 2. 데모 키 발급 서비스(Key Issuer)로 신규 파트너 키 실시간 발급
kubectl exec -n routing deploy/keyissuer -- python3 /app/client.py | jq .

# 3. 인가된 모델(gemma-rr) 호출
curl -sS -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $AK" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Partner API test"}],"max_tokens":16}' | jq .
```

```bash
# 4. 비인가 고비용 모델(claude-sonnet-5) 호출 차단 확인
curl -sS -i -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $AK" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Blocked"}]}' | head -n 1
```
- **기대 결과**: `HTTP/1.1 404 Not Found` 반환. 파트너 라우트에는 고비용 모델 규칙이 등록되어 있지 않아 비용 사고를 원천 방지합니다.

```bash
# 5. 테넌트 쿼터 독립 격리 검증 (acme-corp 분당 60토큰 초과 유도)
for i in {1..6}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GW/v1/chat/completions" \
    -H "Host: $PARTNER_HOST" \
    -H "X-API-Key: $AK" \
    -H "Content-Type: application/json" \
    -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Quota test"}],"max_tokens":20}')
  echo "Acme 요청 $i 응답: HTTP $CODE"
done

# 6. acme-corp 차단 직후 globex 호출 (독립 버킷 유지 확인)
curl -s -o /dev/null -w "Globex 동시 요청 응답: HTTP %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Host: $PARTNER_HOST" \
  -H "X-API-Key: $GK" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-rr","messages":[{"role":"user","content":"Globex check"}],"max_tokens":10}'
```
- **기대 결과**: `acme-corp`는 분당 예산 소진으로 `HTTP 429 Too Many Requests`로 차단되지만 `globex`는 독립된 예산 버킷을 적용받아 즉시 `HTTP 200`을 반환받습니다.

---

### 5.6 시나리오 5: Gemma-EPP 프롬프트 캐시 가속 실측 (핵심 체감 실습)

긴 시스템 프롬프트(약 2,000 토큰)를 연속 전송하여 1차 Cold 요청 대비 2차 Warm 요청의 TTFT(Time to First Token) 가속 효과와 GPU 파드별 캐시 적중 메트릭을 실측합니다.

```bash
# 1. 공통 긴 문맥을 포함한 테스트 프롬프트 파일 생성
cat << 'EOF' > /tmp/make_prefix_payload.py
import json
ctx = "Google Kubernetes Engine and Gateway API enterprise prompt context. " * 150
with open('/tmp/p1.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\n질문 1: 인프라 설정을 요약해줘.'}],'stream':True,'max_tokens':30}, f)
with open('/tmp/p2.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\n질문 2: 캐시 이점을 설명해줘.'}],'stream':True,'max_tokens':30}, f)
EOF
python3 /tmp/make_prefix_payload.py

# 2. 1차 Cold 요청 (캐시 적재 전)
curl -N -s -o /dev/null -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p1.json \
  -w "[1차 Cold TTFT]: %{time_starttransfer}초\n"

# 3. 2차 Warm 요청 (동일한 접두사 프롬프트로 캐시 적중 유도)
curl -N -s -o /dev/null -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p2.json \
  -w "[2차 Warm TTFT]: %{time_starttransfer}초\n"
```
- **기대 결과**: 1차 Cold TTFT 대비 2차 Warm TTFT가 단축되는 가속 효과를 관측할 수 있습니다. EPP의 `prefix-cache-scorer`가 해당 캐시를 가진 GPU 파드로 요청을 정확히 유도하기 때문입니다.

```bash
# 4. vLLM GPU 파드별 실제 Prefix Cache 적중 카운터 비교
for POD in $(kubectl get pods -n vllm -l app=vllm-server -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== GPU Pod: $POD ==="
  kubectl exec -n vllm $POD -c vllm -- curl -s http://localhost:8000/metrics \
    | grep -E "vllm:prefix_cache_hits_total"
done
```
- **기대 결과**: 2대의 vLLM 파드 중 1차 요청을 처리했던 특정 파드에서만 `vllm:prefix_cache_hits_total` 수치가 약 1,500 토큰 이상 증가한 것을 눈으로 확인할 수 있습니다.

---

### 5.7 시나리오 6: 엔터프라이즈 풀스택 관측성 실습 (Cloud Monitoring & Arize Phoenix)

인프라 계층의 GPU 메트릭(`Google Cloud Monitoring`)과 애플리케이션 계층의 LLM 입출력 분산 트레이스(`Arize Phoenix`)를 연계하여 엔드투엔드 관측성을 검증합니다.

#### Part 1: Google Cloud Monitoring vLLM 대시보드 관측

GKE Managed Service for Prometheus(GMP)가 15초 주기로 수집한 vLLM GPU 서빙 메트릭을 Cloud Monitoring 커스텀 대시보드에서 실시간으로 분석합니다.

```bash
# 1. PodMonitoring 수집 상태 확인 (Status: True 확인)
kubectl get podmonitoring -n vllm vllm-server \
  -o jsonpath='{.status.conditions[0].type}: {.status.conditions[0].status}{"\n"}'

# 2. 생성된 vLLM 커스텀 대시보드 리소스 ID 및 접속 URL 확인
DASH_ID=$(gcloud monitoring dashboards list --project="$GCP_PROJECT" \
  --filter="displayName:'vLLM Model Server Monitoring'" --format="value(name)" | awk -F/ '{print $NF}')
echo "대시보드 접속 URL: https://console.cloud.google.com/monitoring/dashboards/builder/${DASH_ID}?project=${GCP_PROJECT}"
```

1. 출력된 **대시보드 접속 URL**을 클릭하여 Google Cloud Console의 `vLLM Model Server Monitoring` 화면으로 이동합니다.
2. 상단 필터 바의 드롭다운 4종(`cluster`, `namespace`, `pod`, `model_name`)을 조합해 관측 범위를 조절합니다.
   - `pod` 필터에서 특정 파드(`vllm-server-*`)를 선택하면 해당 GPU 인스턴스 단독 지표를 분리 관측할 수 있습니다.
   - `pod`와 `model_name`을 `All`로 두면 모든 GPU 파드의 시계열이 한 차트에 겹쳐 표시되어 파드 간 부하 분산과 캐시 적중 편차를 한눈에 비교할 수 있습니다.
3. 대시보드 내 6대 핵심 위젯을 확인합니다.
   - **KV Cache Usage %**: L4 GPU VRAM 내 KV 캐시 블록 점유율
   - **Prefix Cache Hit Rate %**: EPP가 유도한 프롬프트 접두사 캐시 적중률 (5.6절 실습 직후 특정 파드 적중률 상승 확인)
   - **Running & Waiting Requests**: 현재 GPU에서 동시 처리 중인 추론 요청 수와 큐 대기열(Waiting) 발생 여부
   - **TTFT (Time to First Token) Latency**: P50 및 P95 첫 토큰 응답 지연시간 추이
   - **Generation Token & Request Throughput**: 초당 생성 토큰 수(Tokens/s) 및 초당 처리 완료 요청 수(Req/s)

---

#### Part 2: Arize Phoenix 분산 트레이스(OpenInference Spans) 감사

게이트웨이(`ai-gateway-extproc`)가 OpenInference 표준으로 전송한 LLM 입출력 프롬프트 원문과 토큰 사용량, 구간별 소요 시간을 Arize Phoenix UI 및 API로 감사(Audit)합니다.

```bash
# 1. Arize Phoenix 웹 UI 포트포워딩 실행
kubectl port-forward -n phoenix svc/phoenix-service 6006:6006
```
- **로컬 PC 환경**: 웹 브라우저에서 `http://localhost:6006`에 접속합니다.
- **Cloud Shell / Cloud Workstation 환경**: 상단 **웹 미리보기(Web Preview)** 아이콘을 클릭하고 포트를 `6006`으로 변경하여 접속합니다.

1. Phoenix 첫 화면의 Projects 목록에서 **`default` 프로젝트**를 클릭해 진입합니다.
2. 상단 탭에서 **`Traces`**를 선택하면 앞서 시나리오 1 ~ 5에서 호출한 모든 모델(`gemini-2.5-flash`, `claude-sonnet-5`, `gemma-rr`, `gemma-epp`)의 `ChatCompletion` 트레이스 목록이 시간순으로 표시됩니다.
3. 개별 `ChatCompletion` Span 행을 클릭해 우측 상세 패널에서 다음 4가지 엔터프라이즈 감사 항목을 확인합니다.
   - **모델 및 시스템 식별 (`Attributes` 탭)**: `llm.model_name`(`gemini-2.5-flash`, `claude-sonnet-5`, `gemma-epp` 등) 및 `llm.system`(`openai`, `anthropic`) 기록 확인
   - **입출력 프롬프트 원문 감사 (`Input / Output` 탭)**: `llm.input_messages`(사용자가 전송한 실제 프롬프트)와 `llm.output_messages`(모델이 생성한 응답 원문)가 누락 없이 기록되어 보안 감사 및 품질 평가에 활용 가능함을 확인
   - **토큰 과금 원장 대조 (`Attributes` 탭)**: `llm.token_count.prompt`(입력 토큰), `llm.token_count.completion`(출력 토큰), `llm.token_count.total`(총 소비 토큰) 수치 확인
   - **엔드투엔드 레이턴시 비교 (`Latency` 컬럼)**: 게이트웨이 진입부터 백엔드 응답 완료까지 걸린 총 소요 시간(`Duration`)을 비교해 1차 Cold 요청 대비 2차 Warm 캐시 적중 요청의 지연시간 단축 효과 확인

```bash
# [선택] 웹 브라우저 없이 터미널에서 즉시 최근 적재된 Span 5건 검증 (CLI 원라이너)
kubectl exec -n routing deploy/echo-server -- wget -qO- \
  "http://phoenix-service.phoenix.svc.cluster.local:6006/v1/projects/default/spans?limit=5" \
  | jq '{total_fetched: (.data | length), spans: [.data[] | {name: .name, model: .attributes."llm.model_name", prompt_tokens: .attributes."llm.token_count.prompt", completion_tokens: .attributes."llm.token_count.completion", total_tokens: .attributes."llm.token_count.total", trace_id: .context.trace_id}]}'
```
- **기대 결과**: 최근 호출한 모델들의 `trace_id`, `model`, `prompt_tokens`, `completion_tokens`, `total_tokens`가 JSON 배열로 즉시 출력됩니다.


## 6. 트러블슈팅 FAQ

| 문제 현상 | 원인 | 조치 방법 |
|---|---|---|
| CRD 설치 시 `Too long: may not be more than 262144 bytes` 발생 | 클라이언트 사이드 `apply` 시 어노테이션 한도 초과 | 반드시 `--server-side` 플래그를 붙여 `kubectl apply --server-side -f manifests/00-setup/agent-router-crds.yaml`을 실행하십시오. |
| vLLM 파드가 CrashLoopBackOff 상태임 | Hugging Face 토큰 미주입 또는 라이선스 미승인 | Hugging Face 웹에서 `google/gemma-2-2b-it` 약관 동의를 완료했는지 확인한 뒤 `hf-token` 시크릿을 재적용하십시오. |
| Vertex AI(Gemini/Claude) 호출 시 500 에러 발생 | `vertex-ai-sa-key` Secret 누락 | `make setup-secrets`를 실행해 `routing` 네임스페이스에 서비스 계정 키 시크릿이 생성되었는지 확인하십시오. |
| `gcloud auth print-identity-token` 실행 시 `Invalid account type for --audiences` 발생 | 사용자 계정에서 `--impersonate-service-account` 옵션 누락 | 5.4절 명령어와 같이 `--impersonate-service-account="envoy-ai-workload-sa@${GCP_PROJECT}.iam.gserviceaccount.com"`을 반드시 포함하십시오. |
| Claude Code 호출 시 `400 Unexpected value(s) advisor-tool-2026-03-01` 발생 | 최신 Claude Code 실험적 베타 헤더와 Vertex AI 스키마 충돌 | `~/.claude/settings.json`의 `env` 블록에 `"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"`을 추가하십시오. |
| 파트너 호출 시 `429 Too Many Requests` 발생 | 해당 파트너의 분당 토큰 예산 소진 | 1분 대기 후 재시도하거나 `keyissuer`를 사용해 신규 파트너 키를 즉석 발급받으십시오. |
| `/authtest` 호출 시 `500 Unexpected end of JSON` 발생 | 에코 서버에 빈 본문 전송 누락 | curl 호출 시 `-d '{}'` 파라미터를 반드시 추가하여 전달하십시오. |

---

## 7. 4단계: 클린 테어다운 및 비용 차단

실습 종료 후 불필요한 과금을 차단하기 위해 생성된 모든 클라우드 자원을 삭제해야 합니다. K8s `Gateway`가 생성한 GCP LoadBalancer가 VPC 네트워크를 점유하고 있으므로 반드시 K8s 리소스를 먼저 삭제한 뒤 Terraform 삭제를 실행해야 합니다. (`make clean` 명령어로 한 번에 실행할 수도 있습니다.)

```bash
# 1. K8s 워크로드 리소스 순차 삭제 및 LoadBalancer 회수 대기
kubectl delete -k manifests/07-observability --ignore-not-found
kubectl delete -k manifests/06-traffic-policy --ignore-not-found
kubectl delete -k manifests/05-routing --ignore-not-found
kubectl delete -k manifests/04-inference-pool --ignore-not-found
kubectl delete -k manifests/03-vllm --ignore-not-found
kubectl delete -k manifests/02-security --ignore-not-found
kubectl delete -k manifests/01-gateway --ignore-not-found
sleep 20

# 2. Terraform 자원 전체 삭제 (소요 시간 약 10분~15분)
cd terraform
terraform destroy -var="project_id=$GCP_PROJECT" -var="region=$GCP_REGION" -auto-approve
cd ..
```
모든 리소스 삭제가 완료되면 GCP 콘솔의 `Billing` 페이지에서 잔여 과금이 발생하지 않는지 확인하십시오.
