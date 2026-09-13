# Agentrouter 기반 멀티 LLM 서빙 고객 워크숍 실습 가이드

> **Languages:** [English](workshop-guide.md) | [한국어](workshop-guide.kr.md)

본 가이드는 Google Kubernetes Engine(GKE) 상에서 [Agentrouter(formerly Envoy AI Gateway)](https://github.com/theagentrouter/agent-router), Kubernetes Gateway API Inference Extension(GIE), llm-d-router(EPP), vLLM, Vertex AI 및 [Arize Phoenix](https://github.com/Arize-ai/phoenix) 관측성 플랫폼을 처음부터 끝까지 구축하고 검증하는 고객 실습 워크숍 교재입니다.

단순한 배포 확인을 넘어 사내 보안 인증, 파트너 쿼터 격리, 프롬프트 캐시 가속, 헤더 위조 방어, 풀스택 분산 트레이싱까지 엔터프라이즈 AI 게이트웨이의 핵심 가치를 직접 체험할 수 있도록 구성되었습니다.

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
- Vertex AI 사용자 (`roles/aiplatform.user`)

### 2.4 NVIDIA L4 GPU 할당량(Quota) 확인
GKE 클러스터 노드풀에서 NVIDIA L4 GPU 2대를 프로비저닝하려면 리전별 GPU 할당량이 최소 2 이상 확보되어 있어야 합니다.

다음 명령어로 대상 리전의 L4 GPU 할당량을 점검하십시오.
```bash
export GCP_PROJECT="<YOUR_PROJECT_ID>"
export GCP_REGION="asia-southeast1"

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

# 2. 프로비저닝 실행 (소요 시간 약 10분~15분)
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

### 4.1 매니페스트 환경 변수 치환
Terraform 출력값을 기반으로 매니페스트 내 플레이스홀더를 업데이트합니다.
```bash
make update-manifests
```

### 4.2 Hugging Face 토큰 Secret 생성
Gemma 2B 모델 가중치를 GCS 버킷으로 동기화하기 위해 사전 준비한 Hugging Face 토큰을 시크릿으로 등록합니다.
```bash
export HF_TOKEN="hf_your_token_here"

# 토큰 시크릿 주입
sed -i "s|<YOUR_HUGGINGFACE_TOKEN>|$HF_TOKEN|g" manifests/03-vllm/hf-secret.yaml
```

### 4.3 기본 CRD 및 컨트롤러 설치
Gateway API, Agent Router(Envoy AI Gateway), GIE 컨트롤러를 배포합니다.
```bash
kubectl apply -f manifests/00-setup/agent-router-crds.yaml
kubectl apply -f manifests/00-setup/gie-install.yaml
kubectl apply -f manifests/00-setup/agent-router.yaml
kubectl apply -f manifests/00-setup/envoy-gateway-config.yaml
kubectl apply -f manifests/00-setup/envoy-ai-gateway-ratelimit-svc.yaml
```

### 4.4 01번부터 07번까지 순차 배포
```bash
# 1. Gateway 및 프록시 설정
kubectl apply -k manifests/01-gateway

# 2. 전역 보안 정책 및 파트너 키 관리
kubectl apply -k manifests/02-security

# 3. vLLM GPU 서빙 엔진 (모델 가중치 로더 잡 포함)
kubectl apply -k manifests/03-vllm

# 4. GIE 추론 풀 및 llm-d-router EPP
kubectl apply -k manifests/04-inference-pool

# 5. 지능형 모델 라우팅 및 테스트 에코
kubectl apply -k manifests/05-routing

# 6. Redis 및 트래픽/쿼터 정책
kubectl apply -k manifests/06-traffic-policy

# 7. Arize Phoenix 및 모니터링
kubectl apply -k manifests/07-observability
```

### 4.5 배포 상태 점검
모든 파드가 정상 상태에 도달할 때까지 상태를 점검합니다. (vLLM 파드는 GCS 가중치를 마운트한 뒤 초기화되므로 수 분 소요될 수 있습니다.)
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

---

### 5.3 시나리오 2: 보안 검증: 클라이언트 헤더 위조 방어 (`/authtest`)

악의적인 클라이언트가 요청 헤더에 임의로 부서명(`x-tenant-id: finance-vip`)을 실어 보내더라도, 게이트웨이가 JWT 클레임(`department: platform`)으로 강제 덮어쓰는지 점검합니다.

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

GKE 내부에서 동작하는 배치 잡이나 마이크로서비스가 정적 키 없이 Workload Identity SA ID 토큰을 활용해 사내 호스팅 모델(`gemma-rr`)을 호출하는 절차입니다.

```bash
# 1. Google SA ID 토큰 발급 (Audience 지정)
export SA_TOKEN=$(gcloud auth print-identity-token \
  --audiences=https://agent-router.internal \
  --include-email 2>/dev/null)

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

외부 파트너사가 사전에 발급받은 API 키로 게이트웨이에 접근할 때 인가된 모델만 호출할 수 있고, 파트너별 분당 토큰 예산이 엄격히 격리되는지 검증합니다.

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
- **기대 결과**: `acme-corp`는 분당 예산 소진으로 `HTTP 429 Too Many Requests`로 차단되지만, `globex`는 독립된 예산 버킷을 적용받아 즉시 `HTTP 200`을 반환받습니다.

---

### 5.6 시나리오 5: Gemma-EPP 프롬프트 캐시 가속 실측 (핵심 체감 실습)

긴 시스템 프롬프트(2,000 토큰)를 연속 전송하여 1차 Cold 요청 대비 2차 Warm 요청의 TTFT(Time to First Token) 가속 효과를 실측합니다.

```bash
# 1. 2,000 토큰 분량의 프롬프트 파일 생성
python3 -c "
import json
ctx = 'Google Kubernetes Engine and Gateway API enterprise prompt context. ' * 150
with open('/tmp/p1.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\n질문 1: 인프라 설정을 요약해줘.'}],'stream':True,'max_tokens':30}, f)
with open('/tmp/p2.json', 'w') as f:
    json.dump({'model':'gemma-epp','messages':[{'role':'user','content':ctx+'\n질문 2: 캐시 이점을 설명해줘.'}],'stream':True,'max_tokens':30}, f)
"

# 2. 1차 Cold 요청 (캐시 적재 전)
curl -N -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p1.json \
  -w "\n[1차 Cold TTFT]: %{time_starttransfer}초\n"

# 3. 2차 Warm 요청 (동일한 접두사 프롬프트로 캐시 적중 유도)
curl -N -s -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $GT" \
  -H "Content-Type: application/json" \
  -d @/tmp/p2.json \
  -w "\n[2차 Warm TTFT]: %{time_starttransfer}초\n"
```
- **기대 결과**: 1차 Cold TTFT 대비 2차 Warm TTFT가 **5배 이상 단축**(예: 0.77초 -> 0.14초)되는 가속 효과를 직접 관측할 수 있습니다. EPP의 `prefix-cache-scorer`가 해당 캐시를 가진 GPU 파드로 요청을 정확히 유도하기 때문입니다.

---

### 5.7 시나리오 6: 엔터프라이즈 풀스택 관측성 실습

게이트웨이에서 발생한 분산 트레이스와 GPU 메트릭을 분석합니다.

```bash
# Arize Phoenix 포트포워딩 실행
kubectl port-forward -n phoenix svc/phoenix-service 6006:6006
```
1. 웹 브라우저에서 `http://localhost:6006`에 접속합니다.
2. 상단 네비게이션에서 `Traces` 메뉴를 클릭하고 방금 실행한 요청들을 확인합니다.
3. 개별 트레이스를 선택하여 세부 Span Attributes를 분석합니다.
   - `gen_ai.request.model`: 요청된 모델 식별자
   - `llm_total_token`: 소비된 총 토큰 수
   - `tenant_id`: 게이트웨이가 주입한 테넌트 식별자 (`platform`, `partner-htcsor` 등)
   - 세부 레이턴시 구간 (Gateway 처리 시간 vs 백엔드 추론 시간)

---

## 6. 트러블슈팅 FAQ

| 문제 현상 | 원인 | 조치 방법 |
|---|---|---|
| vLLM 파드가 CrashLoopBackOff 상태임 | Hugging Face 토큰 미주입 또는 라이선스 미승인 | Hugging Face 웹에서 `google/gemma-2-2b-it` 약관 동의를 완료했는지 확인한 뒤 `hf-secret` 시크릿을 재적용하십시오. |
| GPU 노드가 Ready 상태로 올라오지 않음 | 리전별 NVIDIA L4 GPU 할당량(Quota) 부족 | `gcloud compute regions describe`로 쿼터 한도를 확인하고 상향 요청하십시오. |
| 호출 시 `401 Jwt is missing` 에러 발생 | 게이트웨이 인증 헤더 누락 | curl 요청에 `-H "Authorization: Bearer $GT"` 또는 `$SA_TOKEN` 헤더를 반드시 포함하십시오. |
| 파트너 호출 시 `429 Too Many Requests` 발생 | 해당 파트너의 분당 토큰 예산 소진 | 1분 대기 후 재시도하거나 `keyissuer`를 사용해 신규 파트너 키를 즉석 발급받으십시오. |
| `/authtest` 호출 시 `500 Unexpected end of JSON` 발생 | 에코 서버에 빈 본문 전송 누락 | curl 호출 시 `-d '{}'` 파라미터를 반드시 추가하여 전달하십시오. |

---

## 7. 4단계: 클린 테어다운 및 비용 차단

실습 종료 후 불필요한 과금을 차단하기 위해 생성된 모든 클라우드 자원을 삭제해야 합니다.

```bash
# 1. K8s 워크로드 리소스 순차 삭제
kubectl delete -k manifests/07-observability --ignore-not-found
kubectl delete -k manifests/06-traffic-policy --ignore-not-found
kubectl delete -k manifests/05-routing --ignore-not-found
kubectl delete -k manifests/04-inference-pool --ignore-not-found
kubectl delete -k manifests/03-vllm --ignore-not-found
kubectl delete -k manifests/02-security --ignore-not-found
kubectl delete -k manifests/01-gateway --ignore-not-found

# 2. Terraform 자원 전체 삭제 (소요 시간 약 10분~15분)
cd terraform
terraform destroy -var="project_id=$GCP_PROJECT" -var="region=$GCP_REGION" -auto-approve
cd ..
```
모든 리소스 삭제가 완료되면 GCP 콘솔의 `Billing` 페이지에서 잔여 과금이 발생하지 않는지 확인하십시오.
