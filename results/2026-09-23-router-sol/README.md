# router 재측정 — `gpt-5.6-sol` (세 agent 모두), 2026-09-23

목적: 9/6 SMDP 120판과 같은 모델 레짐(`gpt-5.6-sol`, 캐시 off)으로, **현 엔진**(e326b43d + 같은 dirty 39fd20a7)에서
router zone·all3 × tractor·X-wing × 30시드 = 120판. 같은 날 gpt-4o 기준선(`../2026-09-23-baseline-router*`)과 같은 격자·시드.

## 설정
- 서비스 :8097 `DSPY_MODEL=gpt-5.6-sol DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none DSPY_MAX_TOKENS=16000 DSPY_CACHE=0
  TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 SYNTH_RECORD_LOG=<이 폴더>/ledger.jsonl`. code_fingerprint `72b8b5af417e6b2c`(gpt-4o 기준선과 동일).
  LM 은 전역 하나 → observe·design·compose·rewrite 전부 sol. 끝난 뒤 정지.
- campaign `rsol-tractor-20260923` · `rsol-xwing-20260923`, config_digest `d5b96fa3188b4c53`(gpt-4o 기준선과 `DSPY_URL` 만 다름).
- 파일럿 tractor zone s1–4(W=4) → 전체(W=8/모델). 07:47–08:37.

## 결과 (분모 = 계획 판, 결측 0)
| 셀 | 9/6 (sol, 옛 엔진) | 오늘 gpt-4o | **오늘 sol** |
|---|---|---|---|
| tractor zone | 25 | 10 | **30** |
| tractor all3 | 24 | 10 | **29** |
| X-wing zone | 20 | 14 | **29** |
| X-wing all3 | 20 | 15 | **29** |
| 합 | 89 | 49 | **117** |

- 같은 시드 120쌍, 존 배치 120/120 동일. sol 만 완주 68판, gpt-4o 만 완주 **0판**.
- body(첫 시도·재시도 어느 쪽이든)가 `translate_whole_build!` 를 부른 판: sol **114/120**, gpt-4o 30/120.
  → gpt-4o 하락의 원인이 모델의 수리 기전 선택이라는 앞선 진단(`../2026-09-23-baseline-router/README.md`)과 일치.
- 재작성(`/rewrite`) 행 8(gpt-4o 118) — sol 은 대부분 첫 시도로 끝났다. 최종 throw 6판.
- 미완주 3판 전부 `world_deadlock`·`stall`·`n_blocked=0`(존은 치워졌는데 세계가 교착):
  tractor all3 s10, X-wing all3 s11, X-wing zone s11. → Phase 3 게이트 G-B2 후보 3(tractor 1, X-wing 2). gpt-4o 기준선에선 0 이었다
  (그땐 미완주가 전부 존 잔존이라 이 층까지 못 왔다).
- 9/6(89) 대비 +28: 9/22 엔진 수정(평행이동 누적·해찾기 여유)이 인과로 보이나 이 격자만으로는 분리 안 함(9/6 은 옛 엔진).

## 검증
- `verify_retry_chain.py` 전수(계획 판 전부, `--require-decisions 1`): tractor 60/60, X-wing 60/60 exit 0 (`../2026-09-23-router-sol-*/verify/`).
- 원장 `ledger.final.jsonl`(128행 = decide 120 + rewrite 8, sha256 `ledger.final.sha256`), `/health` 사후 `ledger_append_failures 0`.

## 비용 (raw_lm usage × $4/M 입력·$20/M 출력 추정 — 과금 총량 아님)
총 **$19.40**(판당 $0.16), 입력 2.52M · 출력 0.47M(추론 0.33M), 캐시 재생 0.
| 단계 | 호출 | 추정 $ | 비중 |
|---|---|---|---|
| observe | 123 | 2.16 | 11% |
| design | 122 | 4.30 | 22% |
| **compose** | 121 | **12.27** | **63%** |
| rewrite | 8 | 0.67 | 3% |
→ 작곡 agent(compose) 모델을 낮추는 것이 비용 절감의 대부분이다. 단, 현재 서비스는 `dspy.configure(lm=…)` 전역 LM 하나라
단계별 모델을 쓰려면 코드 수정이 필요하다(`dspy_service.py:646`).

파일: `compare.py`/`compare.json`(같은 시드 대조), `cost.py`, `router_report.json`, `cost_watchdog.*`(상한 $120, 발동 안 함), `svc8097.log`, `health.{pre,post}.json`.
