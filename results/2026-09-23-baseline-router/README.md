# 유료 router 기준선 — 2026-09-23 (Task 9)

Plan: `docs/superpowers/plans/2026-09-22-tractor-xwing-full-recovery.md` Task 9.
Campaigns: `brouter-tractor-20260923b` · `brouter-xwing-20260923b` (grids `results/2026-09-23-baseline-router-{tractor,xwing}/`).

## 고정 버전 (Task 6c)
- code_rev `e326b43d` · code_dirty_digest `39fd20a7caa02c9c` (다른 세션의 미커밋 src 편집 포함 — 아래) ·
  config_digest `762802ea078fe87c` (무료 campaign 과는 `DSPY_URL` 하나만 다르다) · `config_env` 평문은 `campaign.json`.
- 복원 가능한 스냅샷: 각 grid 의 `snapshot/`(tree.patch · untracked_sources.tar · sha256 · HEAD). 임시 clone 복원 → 같은 digest 확인(`restore_verified=true`).
- dirty 에 섞인 다른 세션 편집 중 **all3 세계를 바꾸는 것**: `render_demo.jl` 종류 비복원 추첨(kind_pool), `battery.jl`/`ood_truth.jl` 의 `ood_targeted_robots` 대상 제외. 나머지는 렌더 전용·관측 전용(in-place 고장 표식, stall probe).
- 서비스: uvicorn :8096 (`TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1`), policy `dspy:gpt-4o`, code_fingerprint `72b8b5af417e6b2c`, 세대 게이트 OK, campaign 전용 원장 `ledger.jsonl`(초기 0행). 판마다 `/health` 신원을 대조했다(표류 0). 끝난 뒤 정지.
- Julia 1.10.11 · Python 3.12.3 · W=8/모델(무료 격자와 동시 실행).

## 🔴 LLM 은 `gpt-4o` 다 — 9/6 router 스윕(`gpt-5.6-sol`, 캐시 off)과 비교하면 안 된다
서비스를 `DSPY_MODEL` 없이 띄워 기본값 `gpt-4o`(원시 응답 `gpt-4o-2024-08-06`)로 돌았다. 9/6 SMDP 120판
(`sweep360.json`·`sweep_30051…json` 의 router zone/all3 = 25·24 / 20·20)은 `gpt-5.6-sol`·캐시 off 였다
(`docs/superpowers/reports/2026-09-06-smdp-state-120run.md` 5행). 계획서 Task 6 Step 7 은 "직전 유료 스윕과
같은 모델" 을 요구했는데 확인하지 않았다(집행 결함).
같은 시드 120쌍 대조(존 배치 120/120 동일): 옛 body 97/120 이 `translate_whole_build!` 를 불렀고 새 body 는
6/120 이다(새 판은 `restage_all_blocked!` 만 110/120, 나머지는 항법 우회 함수를 지어낸다). 새 판에서 첫 시도나
재시도 중에 translate 를 부른 판은 28/30 완주, 부르지 않은 판은 21/90 완주. 무료 레인은 5/30(9/6) → 6/30 으로
안 떨어졌다 — 엔진이 나빠진 것이 아니라 모델이 빌드 전체 평행이동까지 올라가지 않는다.
남은 교란(측정으로 분리 안 함): 9/7 관측에서 `k` 축 삭제, 9/22 인터페이스 status 설명 추가, 캐시 on,
all3 로봇 OOD 시드(옛 판은 30판 모두 seed=1). 모델 단독 효과를 확정하려면 현 엔진에서 `gpt-5.6-sol` 로 같은 격자를 다시 재야 한다.

✅ **확인(같은 날)**: 같은 격자·시드·엔진을 `gpt-5.6-sol`(캐시 off)로 다시 잰 결과 **117/120 완주**(30·29·29·29), translate 114/120 — `../2026-09-23-router-sol/README.md`.

## 🔴 버린 첫 campaign
`*-carrier0-discarded/`: 드라이버가 `CARRIER_RESCUE=0` 을 고정해(render 엔진의 실효 기본값은 "1") 정지 사다리 마지막 단이 꺼진 채 돌았다. 최종 리뷰가 잡았고 격자를 멈췄다. 그 판들의 원장은 `ledger.carrier0-discarded.jsonl`(raw_lm 추정 ≈ $3.63).

## 비용 (추정 — 과금 총량이 아니다)
- 이 campaign 원장 raw_lm: 820,751 입력 / 30,687 출력 토큰 → gpt-4o 공시가 기준 ≈ **$2.36**. 라이브 항목 98, 캐시 재생 384.
- 🔴 캐시 재생이 많은 이유: 버린 carrier0 판들(같은 시드·같은 첫 결정 상황)이 ~/.dspy_cache 를 먼저 채웠다. 재생 응답은 같은 모델(gpt-4o)·같은 프롬프트의 **한 시간 전** 응답이다. `~/.dspy_cache` 5348 → 5470 (+122).
- macro(SelectTool)·adapter/provider 재시도는 raw_lm 에 없다. provider 대시보드는 이 세션에서 못 봤다. 두 campaign 합계 추정 ≈ $6.0(버린 것 포함), 상한 $40.
- `/health`: calls 160, billed 0 — 과금 카운터가 아니다(memory `dspy-cache-replays-look-like-live-calls`).

## 재시도 사슬 전수 검증 (Step 4)
manifest(jobs.jsonl) 계획 판 240개 전부를 `verify_retry_chain.py` 로 판정: **240/240 exit 0**, 판별 JSON `verify/<run_key>.json` 보존.
원장 사본 `ledger.final.jsonl`(sha256 `ledger.final.sha256`), `--health-json health.post.json`(ledger_append_failures 0), `--expect-ctx` model·seed·zone_seed·event·campaign_id·config_digest.
- zone·all3 의 `not_applicable`: 0 (battery·fault 120판은 결정이 없어 not_applicable — LLM 0건, 원장에 battery/fault 행 0)
- orphans 0 · duplicates 0 · cache_hits>0 판 99
- 원장 238행 = decide 120(전부 `synthesis_ran`) + rewrite 118

## 셀 표 (분모 = 계획 판 전부)
### brouter-tractor-20260923b — tractor.mpd

| cell | planned | scored | complete | complete/planned | timeout | error | missing | fail_mode | stop_sig |
|---|---|---|---|---|---|---|---|---|---|
| router|all3 | 30 | 30 | 10 | 0.33 | 0 | 0 | 0 | {'unresolved': 20} | {'stall': 20} |
| router|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} |
| router|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} |
| router|zone | 30 | 30 | 10 | 0.33 | 0 | 0 | 0 | {'unresolved': 20} | {'stall': 20} |

all3 OOD 실제 도달: {'True': 30} · 게이트 후보: {'G-B1': 0, 'G-A': 0, 'G-B2': 0, 'G-R': 0} · unknown: {'G-R_unknown': 0, 'restage_observed': {'warn': 120}, 'unscored_runs_not_gated': 0}

### brouter-xwing-20260923b — 30051-1 - X-wing Fighter - Mini.mpd

| cell | planned | scored | complete | complete/planned | timeout | error | missing | fail_mode | stop_sig |
|---|---|---|---|---|---|---|---|---|---|
| router|all3 | 30 | 30 | 15 | 0.50 | 0 | 0 | 0 | {'unresolved': 15} | {'stall': 15} |
| router|battery | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} |
| router|fault | 30 | 30 | 30 | 1.00 | 0 | 0 | 0 | {} | {} |
| router|zone | 30 | 30 | 14 | 0.47 | 0 | 0 | 0 | {'unresolved': 16} | {'stall': 16} |

all3 OOD 실제 도달: {'True': 30} · 게이트 후보: {'G-B1': 0, 'G-A': 0, 'G-B2': 0, 'G-R': 0} · unknown: {'G-R_unknown': 0, 'restage_observed': {'warn': 120}, 'unscored_runs_not_gated': 0}

## 귀속 (Step 5) — `attribution.md`
- 미완주 71판(tractor 40 · xwing 31) **전부** `project_blocked=true`·`n_blocked≥1` — 존이 아직 항법 목표를 막은 채 `stall` 로 끝났다. 71판 모두 도구를 주조했고(`minted`), 던진 판은 8.
- 미완주 판의 attempts: noop·ok 25 · register_reject·ok 24 · threw·ok 22 · noop·not_requested 14 · threw·not_requested 8 · prerun·not_requested 2.
- ⚠️ 이 표는 관측을 나란히 적은 것이다. 모델 원인/엔진 원인은 같은 세계의 통제 재생 없이 확정하지 않는다(memory `unresolved-can-be-a-world-bug-not-the-model`).
- Phase 3 게이트 후보(G-B1 restage infeasible/partial · G-A line_stop · G-B2 world_deadlock∧stall · G-R reform 소진) = **전부 0**. router 레인은 주조 body 를 집행하므로 ForbidZone restage 경로 자체가 불리지 않는다 — 게이트 0 은 결함 부재 증명이 아니다.
- 🔴 관측: 720판(무료 480 + router 240) 로그 전부에서 `[reform] attempt`·`zone-rescue`·`budget exhausted` 0회 — reform 사다리가 한 번도 발동하지 않았다(원인 미측정, 무료 README 참조).
