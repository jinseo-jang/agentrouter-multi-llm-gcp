# 프로젝트 설계 명세: Agentrouter 기반 멀티 LLM 서빙 아키텍처

> **Languages:** [English](PROJECT.md) | [한국어](PROJECT.kr.md)

## 1. 아키텍처 개요
- **인프라 계층:** GCP 프로젝트 `<YOUR_PROJECT_ID>`(리전 `asia-southeast1`), Gateway API 및 Cloud Storage FUSE CSI 드라이버가 활성화된 GKE Standard 클러스터. 2대의 NVIDIA L4 GPU Spot 노드풀(`g2-standard-8`). Cloud SQL PostgreSQL 16 인스턴스. 모델 가중치 보관용 Cloud Storage 버킷.
- **모델 저장 및 서빙 계층:** Hugging Face에서 내려받은 가중치를 Cloud Storage에 저장한 뒤 Cloud Storage FUSE 마운트(`gke-gcsfuse/volumes: "true"`)로 vLLM `0.29.0` 파드에 전달합니다. VRAM 한계 설정을 거쳐 메모리 경합을 모사하고 PagedAttention V1 접두사 캐싱(Prefix Caching)을 활성화합니다.
- **지능형 라우팅 및 네트워크 계층:** Envoy AI Gateway([Agentrouter](https://github.com/theagentrouter/agent-router) `1.1.0`)가 외부 트래픽을 수신하여 JSON 요청 본문을 버퍼링한 뒤 `model` 키를 기준으로 L7 라우팅을 수행합니다. 내부 라우트는 `inference.networking.k8s.io/v1` 규격의 `InferencePool`로 전달합니다. `llm-d-router`(`0.10.0`)가 Envoy ext-proc EPP로 동작하여 접두사 캐시 점수를 바탕으로 파드를 동적 순위화합니다. Gemini 및 Claude 모델은 GCP 자격증명으로 Vertex AI를 호출합니다.
- **다계층 보안 및 멀티테넌시 계층:** Envoy Gateway `SecurityPolicy` 기반의 3대 다중 인증을 단일 처리합니다. 사내 임직원 및 Cloud Workstation은 GCIP JWT, 내부 마이크로서비스는 Google SA ID 토큰, 외부 파트너는 전용 API Key 인증을 적용하고 모델 라우팅을 엄격히 격리합니다.
- **트래픽 정책 및 쿼터 계층:** Redis 분산 카운터 기반의 토큰 속도 제한(`BackendTrafficPolicy`)과 테넌트별 토큰 예산 격리(`QuotaPolicy`)를 적용해 특정 테넌트의 자원 고갈을 방어합니다.
- **관측성 계층:** Auth Proxy 사이드카로 Cloud SQL에 연결된 [Arize Phoenix](https://github.com/Arize-ai/phoenix)가 API 경로의 OTLP 트레이스를 영구 적재합니다. PodMonitoring으로 vLLM `/metrics`의 접두사 캐시 지표를 실시간 수집합니다.
- **검증 및 문서화:** 클러스터 내부 벤치마크 파드가 3개 라우팅 대상을 무작위 순서로 부하 테스트하고 vLLM 캐시를 동적 초기화합니다. 수집된 결과는 `AGENTS.md` 지침을 준수하는 실증 튜토리얼 문서에 반영됩니다.

---

## 2. 기능 인벤토리 (Feature Inventory)
| # | 기능 | 설명 | 마일스톤 |
|---|------|------|----------|
| 1 | GCP Terraform VPC/GKE | Gateway API, Workload Identity, GCS FUSE가 포함된 GKE 배포 | M1 (완료) |
| 2 | GCP Terraform DB/Storage | Cloud SQL PostgreSQL 16 및 Cloud Storage 버킷 배포 | M1 (완료) |
| 3 | GCP Terraform NodePool | 2대의 L4 Spot 노드풀(`g2-standard-8`) 배포 | M1 (완료) |
| 4 | GCP Terraform IAM | 서비스 계정 생성 및 KSA/GSA Workload Identity 바인딩 | M1 (완료) |
| 5 | Model Weight Loader | Hugging Face에서 `google/gemma-2-2b-it`를 내려받아 GCS에 적재하는 Job | M2 (완료) |
| 6 | vLLM Workload | GCS FUSE 마운트를 참조하는 vLLM `0.29.0` 파드 배포, 접두사 캐싱 활성화 | M2 (완료) |
| 7 | Phoenix Tracing Server | Cloud SQL Auth Proxy 사이드카가 포함된 Arize Phoenix UI 배포 | M3 (완료) |
| 8 | K8s GIE & InferencePools | 순수 라운드로빈 및 EPP Ext-proc 대상을 표현하는 InferencePool 정의 | M3 (완료) |
| 9 | llm-d EPP Router | `prefix-cache` 및 `queue` 스코어러가 구성된 `llm-d-router` v0.10.0 배포 | M3 (완료) |
| 10 | Agent Router Hybrid Mesh | 요청 본문 버퍼링 및 백엔드 분기를 수행하는 Envoy AI Gateway 배포 | M3 (완료) |
| 11 | 3-Tier Multi-Authentication | GCIP JWT, Google SA ID 토큰, 파트너 API Key 인증 및 헤더 위조 방어 | M3 (완료) |
| 12 | Redis Traffic & Quota Policy | Redis 기반 속도 제한(`BackendTrafficPolicy`) 및 테넌트 쿼터 격리(`QuotaPolicy`) | M3 (완료) |
| 13 | E2E Benchmark Suite | 무작위 3대 라우팅 부하 스크립트, TTFT/캐시 지표 수집, 캐시 초기화 로직 | E2E (완료) |
| 14 | Teardown Automation | 전체 환경을 예측 가능하게 생성하고 삭제하는 Makefile 자동화 | M4 (완료) |
| 15 | Bilingual Documentation | 대표 영문 문서(`*.md`) 및 한국어 문서(`*.kr.md`) 상호 링크 구축 | Final (완료) |

---

## 3. 마일스톤 (Milestones)
| # | 명칭 | 범위 | 의존성 | 상태 |
|---|------|------|--------|------|
| M1 | 인프라 프로비저닝 (Terraform) | GCP 기본 자원(GKE, NodePool, Cloud SQL, GCS, IAM) | 없음 | 완료 |
| M2 | 모델 및 서빙 엔진 (vLLM) | HF 가중치 적재, GCS FUSE 마운트, vLLM 파드 구동 | M1 | 완료 |
| M3 | 라우팅 및 보안 체계 | GIE, llm-d EPP, Agent Router, Phoenix, 3대 인증, Redis 쿼터 | M2 | 완료 |
| M4 | 자동화 및 패키징 | 번호 체계 Kustomize 매니페스트, Makefile 자동화, 삭제 절차 검증 | M3 | 완료 |
| E2E | 실측 벤치마크 검증 | 클러스터 내부 3대 라우팅 비교 부하 테스트 및 지표 수집 | M3 | 완료 |
| Final | 이중 언어 문서화 및 배포 준비 | 영문 및 한국어 문서 정비, 상호 링크 연결, 민감정보 누출 방지 검증 | M4, E2E | 완료 |

---

## 4. 인터페이스 계약 (Interface Contracts)
### 4.1 Terraform ↔ K8s
- Workload Identity 연동용 KSA 이름 및 GSA 이메일 매핑
- 매니페스트 볼륨 마운트용 Cloud Storage 버킷 이름 전달
- Cloud SQL Auth Proxy 연결을 위한 인스턴스 연결 이름 전달

### 4.2 Agent Router ↔ 백엔드 라우트
- Envoy가 `/v1/chat/completions` 엔드포인트로 인입되는 HTTP 요청을 가로챕니다.
- `model: "gemini-2.5-flash"`는 Google Cloud Vertex AI Gemini로 분기합니다.
- `model: "claude-sonnet-5"`는 Google Cloud Vertex AI Claude로 분기합니다.
- `model: "gemma-rr"`는 일반 K8s Service(L4 라운드로빈)로 전달합니다.
- `model: "gemma-epp"`는 접두사 캐시 스코어러가 활성화된 EPP InferencePool로 전달합니다.
- `model: "gemma-epp-noprefix"`는 대기열 스코어러 기반 EPP InferencePool로 전달합니다.

### 4.3 멀티테넌시 및 보안 계약
- 기본 리스너(`*`): `agent-router-jwt` 정책으로 GCIP JWT 또는 Google SA ID 토큰 서명을 검증하고 `x-tenant-id` 헤더를 주입합니다.
- 파트너 리스너(`partner.agent-router.internal`): `partner-apikey` 정책으로 API Key를 검증하고 `x-tenant-id` 헤더를 주입한 뒤 `X-API-Key` 헤더를 제거합니다.
- Redis 속도 제한 및 쿼터: 응답 메타데이터의 `llm_total_token` 수치를 반영하여 테넌트별 토큰 버킷을 차감합니다.
