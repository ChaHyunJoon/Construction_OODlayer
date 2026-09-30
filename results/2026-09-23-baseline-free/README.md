# 무료 기준선 — canonical·surrogate × tractor·X-wing mini × 네 사건 × 30시드 (Task 8, 2026-09-23)

Plan: `docs/superpowers/plans/2026-09-22-tractor-xwing-full-recovery.md` Task 8.
Campaigns: `bfree-tractor-20260923b` · `bfree-xwing-20260923b` (grids `results/2026-09-23-baseline-free-{tractor,xwing}/`, 각 240판).
짝 campaign(유료 router 240판): `results/2026-09-23-baseline-router/README.md`.

## 고정 버전 (Task 6c) — 네 campaign 공통
- code_rev `e326b43d` · code_dirty_digest `39fd20a7caa02c9c` · config_digest `d6a2c2df14e495a1`(router 와는 `DSPY_URL` 만 다르다) · `config_env` 평문은 각 `campaign.json`.
- 명시 export 한 복구 손잡이: CARRIER_RESCUE=1 · ZONE_RESCUE=1 · RESTAGE_ZONE_MARGIN_FRAC=0.5 · RESTAGE_RING_STEP_FRAC=0.34 · ZONE_CAUSAL_RULE/ZONE_DOMAIN_GATE/ZONE_CHECK_PATHS=0 · ENERGY_OBJECTIVE=1 · SPARE_PRIORITY=1 · TEAM_PRIORITY=1 · RESPEC_DEPRIO_KAPPA=0.25 · RESTAGE_NAV_BUFFER=0 · RESPEC_TRANSLATE_ON_INFEASIBLE=0 · DEMO_ANIM=0. RELOCATE_GATE 는 기본값이 두 곳에서 달라 설정 안 함(`<unset>`, render 는 "1" 로 돈다).
- 복원 가능한 스냅샷 `snapshot/`(patch · 미추적 소스 tar · sha256 · HEAD) — 임시 clone 복원 digest 일치 확인.
- 🔴 dirty 에 섞인 다른 세션 미커밋 편집 중 all3 세계를 바꾸는 것: 종류 비복원 추첨(render_demo kind_pool), `ood_targeted_robots` 대상 제외(battery.jl·ood_truth.jl). 나머지는 렌더·관측 전용. 이 기준선의 세계는 HEAD 가 아니라 **스냅샷**이다.
- 서비스 :8095 (surrogate 레인용), code_fingerprint `72b8b5af417e6b2c`, 세대 게이트 OK, 판마다 신원 대조. 전용 원장은 끝까지 0행, `/health` calls 0 — LLM 0건.
- 드라이버: `tools/monitor/grid/campaign.py` — 판마다 상속 변수를 지우고 manifest 값만 넣는다(zone 포함 모든 셀에 DEMO_SEED·DEMO_ZONE_SEED), `[run-ctx]` 를 manifest 와 대조, rc·timeout·elapsed·스트림·지문을 `runs.jsonl` 에.
- 파일럿 32판(2시드) → 전체. 🔴 첫 campaign(`*-carrier0-discarded`)은 CARRIER_RESCUE=0 고정 결함으로 버렸다(최종 리뷰 C1).

## 분모 표 (분모 = 계획 판 전부)
### bfree-tractor-20260923b — tractor.mpd

| cell | planned | scored | complete | complete/planned | timeout | error | missing | fail_mode | stop_sig | p50 s | p95 s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| canonical|all3 | 30 | 30 | 6 | 0.20 | 0 | 0 | 0 | {'unresolved': 24} | {'stall': 24} | 279.3 | 335.0 |
| canonical|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 163.1 | 172.1 |
| canonical|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 155.0 | 175.4 |
| canonical|zone | 30 | 30 | 6 | 0.20 | 0 | 0 | 0 | {'unresolved': 24} | {'stall': 24} | 251.9 | 282.6 |
| surrogate|all3 | 30 | 30 | 6 | 0.20 | 0 | 0 | 0 | {'unresolved': 24} | {'stall': 24} | 315.3 | 368.2 |
| surrogate|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 165.7 | 169.1 |
| surrogate|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 163.6 | 183.8 |
| surrogate|zone | 30 | 30 | 6 | 0.20 | 0 | 0 | 0 | {'unresolved': 24} | {'stall': 24} | 256.3 | 280.8 |

시드 축(주 검사): 셀마다 `>>> OOD armed` 시드 30/30 종, zone 배치 30/30 종(`[zone] blocking zone on …`), 결정 시각(`at`)이 시드마다 다르다. 같은 시드는 canonical·surrogate 가 초기 지문·OOD 지문 모두 같다({'init_same': 120, 'ood_same': 120}). 초기 지문(첫 프레임)은 존이 닿기 전 상태라 시드끼리 일부 겹친다 — 판별력은 배치·시각이 진다.

all3 OOD 실제 도달: canonical {'True': 30} · surrogate {'True': 30} · 게이트 후보 {'G-B1': 0, 'G-A': 0, 'G-B2': 0, 'G-R': 0} · unknown {'G-R_unknown': 0, 'restage_observed': {'warn': 240}, 'unscored_runs_not_gated': 0}

### bfree-xwing-20260923b — 30051-1 - X-wing Fighter - Mini.mpd

| cell | planned | scored | complete | complete/planned | timeout | error | missing | fail_mode | stop_sig | p50 s | p95 s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| canonical|all3 | 30 | 30 | 8 | 0.27 | 0 | 0 | 0 | {'unresolved': 22} | {'stall': 22} | 347.7 | 395.1 |
| canonical|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 192.1 | 198.6 |
| canonical|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 180.7 | 204.7 |
| canonical|zone | 30 | 30 | 7 | 0.23 | 0 | 0 | 0 | {'unresolved': 23} | {'stall': 23} | 313.8 | 354.2 |
| surrogate|all3 | 30 | 30 | 8 | 0.27 | 0 | 0 | 0 | {'unresolved': 22} | {'stall': 22} | 405.1 | 441.6 |
| surrogate|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 200.9 | 205.4 |
| surrogate|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} | 189.5 | 199.3 |
| surrogate|zone | 30 | 30 | 7 | 0.23 | 0 | 0 | 0 | {'unresolved': 23} | {'stall': 23} | 263.4 | 294.5 |

시드 축(주 검사): 셀마다 `>>> OOD armed` 시드 30/30 종, zone 배치 30/30 종(`[zone] blocking zone on …`), 결정 시각(`at`)이 시드마다 다르다. 같은 시드는 canonical·surrogate 가 초기 지문·OOD 지문 모두 같다({'init_same': 120, 'ood_same': 120}). 초기 지문(첫 프레임)은 존이 닿기 전 상태라 시드끼리 일부 겹친다 — 판별력은 배치·시각이 진다.

all3 OOD 실제 도달: canonical {'True': 30} · surrogate {'True': 30} · 게이트 후보 {'G-B1': 0, 'G-A': 0, 'G-B2': 0, 'G-R': 0} · unknown {'G-R_unknown': 0, 'restage_observed': {'warn': 240}, 'unscored_runs_not_gated': 0}

## 원인 표 (Step 4) — 엔진 원인 **후보** 수
| 게이트 | 정의 | tractor | xwing | router tractor | router xwing |
|---|---|---|---|---|---|
| G-B1 | 미완주 ∧ restage infeasible/partial 관측 | 0 | 0 | 0 | 0 |
| G-A | line_stop(`FALLBACK engaged`) 관측 | 0 | 0 | 0 | 0 |
| G-B2 | world_deadlock 후보 ∧ stall | 0 | 0 | 0 | 0 |
| G-R | reform 예산 실제 소진(`[reform] budget exhausted`) | 0 | 0 | 0 | 0 |

- 계측: restage 는 Warn 수준(infeasible·partial 은 `@warn` 이라 보이고 residual_blocked·ok·none 은 안 보인다) — G-B1 에는 유효. reform 소진 표지는 이 엔진부터 있다(unknown 0).
- 미완주는 전부 `unresolved` + `stall`: 존이 **아직** 항법 목표를 막은 채(`project_blocked=true`) 정지했다.
- canonical·surrogate 는 ZONE 결정에서 **NOOP 을 골랐다**(실측: 두 모델·두 레인 각 30/30). 그래서 restage 경로가 불리지 않고 G-B1 이 구조적으로 0 이다. 🔴 **게이트 0 은 결함 부재 증명이 아니다** — 이 격자에서 그 경로가 안 불렸다는 뜻이다.
- zone 완주 판(tractor 6·xwing 7, 두 레인 동일)은 전부 존 배치 시점에 `n_blocked=0`(존이 항법 목표만 일부 덮고 작업 목표는 안 막음)이었고 `[reform]` 표지가 0 이다 — **개입 없이** 끝났다. 
- 🔴 관측: 네 campaign 720판 로그 전부에서 `[reform] attempt` · `[reform] zone-rescue` · `[reform] budget exhausted` 가 **0회**다(계획서 F8 의 과거 183판 관측과 같다). render 의 reform 사다리(`enact_reform!`)가 이 격자에서 한 번도 발동하지 않았다 — 미완주 판은 reform 없이 `No progress` 정지로 끝났다. 왜 발동하지 않는지는 이 계획서 범위 밖이다(Phase 4 D3·D5 와 같은 자리, 원인 미측정).

## Phase 3
Task 10(B2 nav buffer, 게이트 G-B2) · Task 11(B1 translate-on-infeasible, 게이트 G-B1): **게이트 0 — 미집행.**
