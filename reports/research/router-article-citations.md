# 「Router 본격 진입의 시대」 데이터포인트 출처 매핑

- 대상 글: [Dongsoo Lee, LinkedIn Pulse](https://www.linkedin.com/pulse/router-%EB%B3%B8%EA%B2%A9-%EC%A7%84%EC%9E%85%EC%9D%98-%EC%8B%9C%EB%8C%80-dongsoo-lee-obncf/) (비로그인 상태로 본문 전체 추출 확인)
- 조사일: 2026-10-01 (UTC)
- 방법: 웹 검색으로 후보를 찾고 리다이렉트를 풀어 원문 URL을 확보한 뒤 원문 텍스트에서 해당 문장을 직접 확인함

## 판정 기준

| 판정 | 의미 |
|---|---|
| 확인(1차) | 원문 페이지를 직접 받아 해당 문장을 찾음 |
| 확인(2차) | 유료 원문은 열지 못했고 그 기사를 인용한 보도에서 찾음 |
| 부분 | 핵심은 맞지만 세부 내용이 다르거나 일부만 확인됨 |
| 미확인 | 근거를 찾지 못함 |

## 1. 전문 라우터 스타트업

| # | 글의 주장 | 판정 | 출처와 원문 표현 |
|---|---|---|---|
| 1 | Not Diamond 코딩 에이전트용 라우터, early access에서 20% 이상 절감 | 확인(1차) | [Not Diamond Code 블로그](https://www.notdiamond.ai/blog/not-diamond-code-intelligent-model-routing-for-coding-agents): "in our enterprise early access program we achieve savings of 20%+" |
| 2 | Not Diamond 일반적으로 20~40% 절감 | 미확인 | [홈페이지](https://www.notdiamond.ai/)에는 "Cost savings 20%+"만 있음. 40% 상한은 찾지 못함 |
| 3 | Martian 2024년 Accenture 투자, Switchboard 통합 | 확인(1차) | [Accenture 보도자료 2024-09-17](https://newsroom.accenture.com/news/2024/accenture-invests-in-martian-to-bring-dynamic-routing-of-large-language-queries-and-more-effective-ai-systems-to-clients) |
| 4 | Amazon부터 Zapier까지 300개 이상 기업 | 확인(1차) | 위 보도자료: "Engineers at 300+ companies, from Amazon to Zapier, have used Martian" |
| 5 | Martian이 스스로를 "LLM을 위한 Google"에 비유 | 미확인 | Martian 1차 자료에서 이 표현을 찾지 못함 |
| 6 | 고객지원 챗봇 오류율 52.4% 감소·비용 92% 감소, RAG 품질 20% 향상·비용 1/80 | 미확인 | 현재 [withmartian.com](https://withmartian.com/)은 interpretability 쪽으로 방향을 바꿈. 2024년 Wayback 아카이브에는 "beat GPT-4 on performance, reduce costs by 20%-97%"만 있음. 검색 요약이 근거로 든 augmentcode 페이지에도 수치가 없음. 인용하지 않는 편이 안전함 |

## 2. 빅테크와 기업 내부 라우터

| # | 글의 주장 | 판정 | 출처와 비고 |
|---|---|---|---|
| 7 | The Information 「The Five Kinds of Model Routers That Cut AI Costs」(2026년 7월) | 확인(2차) | [AI Weekly 요약 (2026-07-06)](https://aiweekly.co/alerts/coinbase-snowflake-turn-to-model-routers-to-cut-ai-bills)이 원 제목을 명시. 유료 원문은 열지 못함 |
| 8 | Snowflake·Palo Alto Networks가 일부 작업을 싼 모델로 옮겨 비용 절감 | 확인(2차) | 위 요약: "Snowflake and Palo Alto Networks told The Information that swapping in cheaper models … produced considerable savings" |
| 9 | 두 회사 모두 내부 라우터를 직접 구축, Snowflake CoCo에도 적용 | 미확인 | 내부 라우터 구축과 CoCo 적용 근거를 찾지 못함 |
| 10 | Snowflake CEO Ramaswamy의 6월 inference 비용 우려 발언 | 미확인 | 해당 기사를 찾지 못함. 글 안에서도 같은 조사를 "6월"과 "7월"로 다르게 적음 |
| 11 | Snowflake Cortex AI Gateway Dynamic Model Routing, PR 처리량 유지·token 약 25% 절감 | 확인(1차) | [Snowflake 블로그 2026-08-18](https://www.snowflake.com/en/blog/dynamic-model-routing-open-models-cortex-ai/): "same pull-request throughput while using approximately 25% fewer tokens". 원문 표기상 "PrPr soon"이라 아직 GA 제품이 아님 |
| 12 | Cursor Router early access 30~50%, A/B 60% 절감, 주당 수억 건 요청 | 확인(1차) | [cursor.com/blog/router](https://cursor.com/blog/router): "approximately 30–50% lower cost", "60% savings", "hundreds of millions of coding requests each week". 비교 기준은 Opus 4.8 단독 사용. 출시일 7/22는 검색 요약에서만 확인 |
| 13 | The Information이 Cursor Router 출시를 별도 보도 | 미확인 | 유사 보도: [The New Stack](https://thenewstack.io/cursor-ramp-meta-model-router/) |
| 14 | Cognition sidekick 구조, Fable 5 수준 유지하며 약 35% 절감 | 확인(1차), 수치 갱신됨 | [Cognition 블로그 2026-06-29](https://cognition.com/blog/devin-fusion): "We initially reported a 35% cost reduction". 8/7 갱신 기준 최대 60%, Fable 5와 결합 시 41% |
| 15 | Meta AAI Labs 라우터 'Switchboard' | 확인(2차) | [DigitalToday 2026-07-22](https://www.digitaltoday.co.kr/en/view/84183/meta-develops-switchboard-ai-router-targeting-openrouter)가 The Information 7/21 보도를 인용. 사내 코딩 비용 절감 목적은 보조 매체에서만 확인 |
| 16 | Bedrock Intelligent Prompt Routing 최대 30% 절감 | 확인(1차) | [AWS 제품 페이지](https://aws.amazon.com/bedrock/intelligent-prompt-routing/): "reduce costs by up to 30% without compromising on accuracy" |
| 17 | AWS 실험 Anthropic 모델군 56% 절감 | 확인(1차) | [AWS ML 블로그](https://aws.amazon.com/blogs/machine-learning/use-amazon-bedrock-intelligent-prompt-routing-for-cost-and-latency-benefits/) 표: "Anthropic 0.86 / 56%". 같은 글에 60%(내부 테스트)와 63.6%(RAG)도 있음 |

## 3. 시장 데이터 (Vercel, 언론 보도)

| # | 글의 주장 | 판정 | 출처와 비고 |
|---|---|---|---|
| 18 | 월 1천만 건 이상 workload는 평균 35개 모델 사용 | 확인(1차) | [Vercel 아키텍처 레퍼런스](https://vercel.com/i/ai-gateway-architecture-reference-patterns): "10,000,000+ → 35" |
| 19 | 전체 token의 59%가 Agentic workload | 확인(1차) | [Vercel AI Gateway 소개](https://vercel.com/i/what-is-an-ai-gateway): tool-call token 비중 "31.6% to 58.9% between October 2025 and April 2026" |
| 20 | 매달 수십조 token, 20만 개 이상 팀 | 부분 | "tens of trillions of tokens"는 1차 출처에서 확인. 20만 개 팀은 Medium 글에서만 확인 |
| 21 | tool 사용 request는 약 22%인데 token은 59% | 부분(2차) | [air-lock.ai](https://www.air-lock.ai/blog/skills-agents-infrastructure/)가 Vercel 자료를 인용: "22% of all AI Gateway traffic ended in a tool call in April 2026". 22%와 59%는 별개 지표인데 글이 한 문장으로 묶음 |
| 22 | Vercel 결론: 다음 optimization은 routing layer | 부분 | Vercel 문서가 routing layer를 반복 강조하지만 이 결론 문장은 찾지 못함 |
| 23 | open-weight 2025년 12월 7% → 2026년 8월 56%, 비용 비중 14%, 평균 token 가격 5개월 전의 절반 이하, median 7.6% 감소 | 확인(1차) | [Vercel 9월 리포트](https://vercel.com/blog/ai-gateway-production-index-september-2026). median은 "teams running more than ten million tokens in both months" 기준. 각주상 open-weight 분류가 이전 리포트보다 넓어져 7%와 56%는 기준이 다를 수 있음 |
| 24 | Ensemble Health Partners 올해 최대 1억 달러 지출 계획, OpenAI 고급 모델 대비 1/20 모델로 이전 | 부분 | [Sedaily 2026-06-25](https://en.sedaily.com/international/2026/06/25/companies-seek-cheaper-ai-models-build-their-own-as-costs)가 The Information을 인용. 1/20과 연 70만 달러 절감은 확인. 1억 달러 지출 계획은 미확인(Ensemble 자료의 "EIQ 10년간 1억 달러 이상 투자"와 혼동 가능성). 비교 대상도 원문은 "premium models" |
| 25 | FT 9/27: AT&T 40%→70%·하루 450억 token, Tinder 연환산 100만→1,000만 달러, Digital Realty private open-weight | 확인(2차) | [파이낸셜뉴스(연합) FT 인용](https://en.fnnews.com/news/202609280957348349), [Seeking Alpha 요약](https://fr.tradingview.com/news/seekingalpha:f381d0c60094b:0-companies-are-turning-to-cheaper-open-weight-ai-models/). 발언자 Andy Markus(AT&T), Vinay Kuruvila(Tinder), Scott Wallace(Digital Realty). FT 원문 URL은 유료라 미확보 |

## 활용 가이드

- 인용 가능: Cursor(30~50%, 60%), AWS(30%, 56%), Snowflake(25%), Vercel(35개 모델, 59%, 56% 대 14%), Accenture–Martian 300+
- 조건부 인용: Cognition 35%(최신 최대 60%), Snowflake 기능(Private Preview 예정), Vercel 7%→56%(분류 기준 변경)
- 제외 권장: Martian 52.4%/92%/1/80, Ensemble 1억 달러 계획, Snowflake·Palo Alto 내부 라우터와 CoCo 언급
- 추가 데이터: Not Diamond는 라우팅 후보에 open-weight 모델을 넣었을 때 절감률이 39%에서 66%로 올랐다고 밝힘(Poly-SWE-Bench)
- 벤더 수치는 모두 해당 회사 자체 발표이며 독립 벤치마크가 아님
