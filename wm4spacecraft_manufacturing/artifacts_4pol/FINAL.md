# 4정책 x OOD case 비교표 -- FINAL (자동 생성)

생성 시각: 2026-08-16T00:44:12-07:00
생성기: `build_final_table.py --results-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/results_4pol --out-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/artifacts_4pol`

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

실행 가능한 lane 은 `noop` / `surrogate` / `dspy`(=`llm`) 셋뿐이다(이번 스윕이 실제로 돌린 정책 집합과 같다). `oracle` 행은 매 블록에서 별도 계산되는 상한선으로만 들어간다.

기준 행동 a* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):
- `battery`: oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 5 instances / 13 rows in this grid (battery kind = 3 of those instances, one per severity rung; arms tested per rung: 0.02 -> {NOOP, Replace, SwapBattery}, 0.30/0.50 -> {NOOP, Deprioritize, SwapBattery}). SoC 0.02: NOOP (closed 184/313) and Replace (closed 243/313) both FAIL to complete; only SwapBattery completes (291/313, 22.425s) -> decided by COMPLETION. SoC 0.30: all three tested arms complete (291/313 each); NOOP and Deprioritize tie at 22.725s/261.5 J/closed, SwapBattery is FASTER at 22.425s/279.7 J/closed -> decided by makespan (COST), and SwapBattery wins it. SoC 0.50: all three complete (291/313); NOOP/Deprioritize tie at 22.875s/273.7 J/closed, SwapBattery again faster at 22.425s/279.7 J/closed -> decided by cost, SwapBattery wins again. SwapBattery is therefore correct at every rung tested (0.02, 0.30, 0.50), so BATTERY_DEEP_SOC is raised to 0.5, the highest rung in this ladder -- above 0.5 is untested by this grid. The basis is COST (makespan), not completion, at 0.30 and 0.50 -- this flips the old D=40 mild-side answer from NOOP to SwapBattery: at D=20 the depot round trip is cheap enough that swapping now beats tolerating a slower, degraded robot for the rest of the build. Replace was NOT observed to complete at this geometry (the completion flip this task's brief anticipated for Replace did not happen): it was only tested at SoC 0.02, where it still fails (243/313); what actually flipped is the cost race among the arms that already completed. This supersedes the D=40 threshold of 0.3 and its 'mild side is free, NOOP wins' story -- see the SUPERSEDED block in the module docstring for the full D=40/near-depot provenance chain this replaces. FRAGILITY (disclosed, not corrected -- the derivation rule was applied correctly, its margin is simply thin): the 0.02 rung is decided by COMPLETION and is robust, but the two upper rungs are decided by makespan margins of 0.300s (22.425 vs 22.725 at SoC 0.30) and 0.450s (22.425 vs 22.875 at SoC 0.50), at n=1 per instance x arm -- this grid holds exactly one row per cell, so there is no repeat to average. A same-session control re-run of an identical configuration (results/control_d40_samesession.jsonl, canonical, D=40, ood_seed 2) measured 68.175s in one session and 71.300s in another: a run-to-run spread of 3.125s (+4.6%), an order of magnitude LARGER than the 0.300/0.450s margins that decide rungs 0.30 and 0.50. Those two rungs should therefore be read as 'SwapBattery was not worse', not as an established win; only the 0.02 rung (completion) carries the threshold on its own. Above SoC 0.5 nothing is tested at all, and reference_action() returns None (unscored) there rather than inventing NOOP.
- `fault`: oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 1 fault instance only (severity 1.0, arms NOOP and Replace) -- NEITHER arm completes (NOOP closed 184/313, Replace closed 243/313, both makespan Inf), so this grid CANNOT re-derive the rule below either (same outcome as the D=40 pass); the rule is left unchanged and treated as unverified-here. closed is directionally consistent with 'agent_pending > 0 -> Replace' (Replace closes more than NOOP, agent_pending=3 on this row) but does not establish it. Historical provenance (not re-verified in this pass): firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect separation (agent_pending > 0 -> Replace [24/24], == 0 -> NOOP [18/18]).
- `zone`: oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 1 zone instance only (severity 1.0) -- NOOP and RelocateBuild TIE exactly (both complete, closed 291/313, identical makespan 22.425s): this grid does not test the rule below, the same outcome as the D=40 grid before it, so the rule is left unchanged. Independent evaluation-run support: results/matrix_d20.jsonl, case=='zone', ood_seed 1 (seed 1 rows only, n=3, one per policy -- seed 2 was still appending when this was written; full 42-row confirmation happens in Task 5). All three policies COMPLETE the build. canonical enacts NOOP on every ZoneTruth decision (4x) and then needs 5 ReformTeam recovery decisions later in the run (a team got stuck), finishing in 58.55s. surrogate and dspy both enact RelocateBuild on every ZoneTruth decision (4x each) and need ZERO ReformTeam recoveries, finishing in 30.875s each -- about 53% of the NOOP arm's SIMULATED build time (sim_seconds 30.875 vs 58.55; these are sim seconds, NOT wall clock -- the runs' wall_seconds are a different field entirely). This D=20 evaluation run reproduces the same pattern the D=40 evaluation run showed (NOOP finishes but drags in stall/recovery alarms; RelocateBuild finishes faster and clean), so it independently supports keeping the rule even though the oracle grid itself ties. Historical (D=40, now superseded by the D=20 evaluation-run numbers above): results/matrix_fardepot.jsonl showed canonical(NOOP) 58.0s / 500 J/closed with 5 ReformTeam alarms, vs RelocateBuild 39.0s / 492 J/closed with 1 alarm. Grid provenance: zcausal_reform/ STEP 10, 2 arm-crossed events (n=2 -- weakest axis).

전체 pooled shadow 채점(모든 case 합산, 새 시뮬 0회): `artifacts_4pol/shadow.md`

---

## Case 블록

### case = battery   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) — J 채점 불가 18 instance (energy_J 없음) | 100% (정의상) | — | — |
| `surrogate` | 26/30 | 62% (74/119) | 30.4 ± 4.6 s | 437.8 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 28/30 | 42% (50/120) | 27.8 ± 5.4 s | 404.6 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 25.0 ± 5.7 | 400 | 0.999 | 8.0 |
| `surrogate` | 30 | 87% (26/30) [0.70, 0.95] | 62% (74/119) | 30.4 ± 4.6 | 438 | 0.909 | 10.5 |
| `dspy` | 30 | 93% (28/30) [0.79, 0.98] | 42% (50/120) | 27.8 ± 5.4 | 405 | 0.969 | 9.7 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×7 | Battery 0/120 |
| `surrogate` | SwapBattery×74, Replace×45, ReformTeam×42 | Battery 74/119 |
| `dspy` | Replace×70, SwapBattery×50, ReformTeam×19 | Battery 50/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/127) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/119) | 0% (0/161) | 62% (74/119) | 64% (57/89) | 80% (48/60) | 97% (29/30) |
| `dspy` | 0% (0/120) | 0% (0/139) | 42% (50/120) | 40% (36/90) | 57% (34/60) | 50% (15/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 4승 0패 26무, 부호검정 p=0.125
- 짝지은 비교 `canonical` vs `dspy` — 2승 0패 28무, 부호검정 p=0.500
- 짝지은 비교 `surrogate` vs `dspy` — 0승 2패 28무, 부호검정 p=0.500

</details>

---

### case = fault   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) — J 채점 불가 22 instance (energy_J 없음) | 100% (정의상) | — | — |
| `surrogate` | 30/30 | 99% (119/120) | 25.0 ± 5.7 s | 399.6 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 29/30 | 98% (118/120) | 24.9 ± 5.7 s | 437.6 |

> **3-A** -- 위 `oracle` 행의 완주율은 22개 **현재-세대** fault instance 만 반영한다(`firegrid_s{fault,faultidle}.jsonl`, NOOP/Replace 2-arm 메뉴). 구세대 18개 instance(5-arm 메뉴, macro 7/8 이전 라벨 -- CLAUDE.md "성능 근거 아님")는 헤드라인에서 제외했다 -- 참고용 완주율 0% (0/3). **이 둘을 풀링한 n=40 천장은 이 문서에 없다** (`artifacts_4pol/REPORT.md` §3-A 상세).

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 99% (119/120) | 25.0 ± 5.7 | 400 | 0.999 | 8.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 99% (119/120) | 25.0 ± 5.7 | 400 | 0.999 | 8.0 |
| `dspy` | 30 | 97% (29/30) [0.83, 0.99] | 98% (118/120) | 24.9 ± 5.7 | 438 | 0.999 | 8.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×7 | Fault 119/120 |
| `surrogate` | Replace×120, ReformTeam×7 | Fault 119/120 |
| `dspy` | Replace×119, ReformTeam×17 | Fault 118/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/127) | 99% (119/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `surrogate` | 0% (0/120) | 0% (0/127) | 99% (119/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/120) | 0% (0/136) | 98% (118/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 1승 0패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 1승 0패 29무, 부호검정 p=1.000

</details>

---

### case = zonecore   (데이터 없음)

**데이터 없음.** status_4pol.jsonl 에 이 case 기록 없음 (스윕이 아직 이 case 에 도달하지 않음).

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

---

### case = all   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | N/A (혼합종류 case -- 단일축 오라클 격자 없음) | 100% (정의상) | — | — |
| `surrogate` | 25/30 | 84% (98/116) | 45.0 ± 20.4 s | 708.2 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 65% (78/120) | 43.4 ± 18.2 s | 542.0 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_all.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 34% (41/120) | 63.3 ± 10.6 | 748 | 0.997 | 9.3 |
| `surrogate` | 30 | 83% (25/30) [0.66, 0.93] | 84% (98/116) | 45.0 ± 20.4 | 708 | 0.997 | 10.3 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 65% (78/120) | 43.4 ± 18.2 | 542 | 0.998 | 9.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×166, Replace×81, NOOP×39 | Battery 0/39, Fault 41/42, Zone 0/39 |
| `surrogate` | ReformTeam×114, Replace×52, RelocateBuild×31, SwapBattery×26, NOOP×7 | Battery 26/37, Fault 41/41, Zone 31/38 |
| `dspy` | ReformTeam×75, Replace×66, RelocateBuild×21, NOOP×18, SwapBattery×15 | Battery 15/39, Fault 42/42, Zone 21/39 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/286) | 34% (41/120) | 46% (41/90) | 48% (29/60) | 27% (8/30) |
| `surrogate` | 0% (0/116) | 0% (0/230) | 84% (98/116) | 87% (76/87) | 84% (49/58) | 86% (25/29) |
| `dspy` | 0% (0/120) | 0% (0/195) | 65% (78/120) | 67% (60/90) | 70% (42/60) | 63% (19/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 5승 0패 25무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 5패 25무, 부호검정 p=0.062

</details>

---

### case = fault_battery   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | N/A (혼합종류 case -- 단일축 오라클 격자 없음) | 100% (정의상) | — | — |
| `surrogate` | 28/30 | 77% (92/119) | 28.3 ± 6.1 s | 446.7 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 68% (82/120) | 27.4 ± 6.6 s | 384.8 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 49% (59/120) | 25.0 ± 5.7 | 400 | 0.999 | 8.0 |
| `surrogate` | 30 | 93% (28/30) [0.79, 0.98] | 77% (92/119) | 28.3 ± 6.1 | 447 | 0.939 | 9.1 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 68% (82/120) | 27.4 ± 6.6 | 385 | 0.999 | 8.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×7 | Battery 0/60, Fault 59/60 |
| `surrogate` | Replace×86, SwapBattery×33, ReformTeam×26 | Battery 33/60, Fault 59/59 |
| `dspy` | Replace×97, SwapBattery×23, ReformTeam×8 | Battery 23/60, Fault 59/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/127) | 49% (59/120) | 51% (46/90) | 43% (26/60) | 30% (9/30) |
| `surrogate` | 0% (0/119) | 0% (0/145) | 77% (92/119) | 80% (71/89) | 77% (46/60) | 77% (23/30) |
| `dspy` | 0% (0/120) | 0% (0/128) | 68% (82/120) | 68% (61/90) | 67% (40/60) | 60% (18/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 2승 0패 28무, 부호검정 p=0.500
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 2패 28무, 부호검정 p=0.500

</details>

---

### case = fault_zone   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | N/A (혼합종류 case -- 단일축 오라클 격자 없음) | 100% (정의상) | — | — |
| `surrogate` | 25/30 | 97% (111/115) | 40.1 ± 17.5 s | 716.1 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 29/30 | 72% (87/120) | 46.1 ± 19.5 s | 599.6 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 49% (59/120) | 62.4 ± 9.7 | 679 | 0.997 | 10.0 |
| `surrogate` | 30 | 83% (25/30) [0.66, 0.93] | 97% (111/115) | 40.1 ± 17.5 | 716 | 0.997 | 10.1 |
| `dspy` | 30 | 97% (29/30) [0.83, 0.99] | 72% (87/120) | 46.1 ± 19.5 | 600 | 0.998 | 10.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×163, Replace×60, NOOP×60 | Fault 59/60, Zone 0/60 |
| `surrogate` | ReformTeam×96, Replace×56, RelocateBuild×55, NOOP×4 | Fault 56/56, Zone 55/59 |
| `dspy` | ReformTeam×104, Replace×59, NOOP×31, RelocateBuild×29 | Fault 58/60, Zone 29/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/283) | 49% (59/120) | 66% (59/90) | 98% (59/60) | 100% (30/30) |
| `surrogate` | 0% (0/115) | 0% (0/211) | 97% (111/115) | 100% (86/86) | 100% (58/58) | 100% (29/29) |
| `dspy` | 0% (0/120) | 0% (0/223) | 72% (87/120) | 77% (69/90) | 97% (58/60) | 97% (29/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 5승 0패 25무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `dspy` — 1승 0패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 5패 25무, 부호검정 p=0.062

</details>

---

### case = battery_zone   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | N/A (혼합종류 case -- 단일축 오라클 격자 없음) | 100% (정의상) | — | — |
| `surrogate` | 25/30 | 76% (87/115) | 45.0 ± 18.9 s | 622.6 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 29/30 | 47% (56/119) | 47.3 ± 20.3 s | 537.8 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 62.4 ± 9.7 | 679 | 0.997 | 10.0 |
| `surrogate` | 30 | 83% (25/30) [0.66, 0.93] | 76% (87/115) | 45.0 ± 18.9 | 623 | 0.967 | 11.2 |
| `dspy` | 30 | 97% (29/30) [0.83, 0.99] | 47% (56/119) | 47.3 ± 20.3 | 538 | 0.998 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×163, Replace×60, NOOP×60 | Battery 0/60, Zone 0/60 |
| `surrogate` | ReformTeam×96, RelocateBuild×55, SwapBattery×32, Replace×24, NOOP×4 | Battery 32/56, Zone 55/59 |
| `dspy` | ReformTeam×90, Replace×35, RelocateBuild×32, NOOP×28, SwapBattery×24 | Battery 24/59, Zone 32/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/283) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/115) | 0% (0/211) | 76% (87/115) | 72% (62/86) | 59% (34/58) | 66% (19/29) |
| `dspy` | 0% (0/119) | 0% (0/209) | 47% (56/119) | 40% (36/89) | 42% (25/60) | 43% (13/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 5승 0패 25무, 부호검정 p=0.062
- 짝지은 비교 `canonical` vs `dspy` — 1승 0패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 4패 26무, 부호검정 p=0.125

</details>

---

### case = zone   (n=30 seeds, world_seed=1, router=0)

> **`oracle` 행은 이 스윕이 실행한 판이 아니다 -- 오프라인 라벨 격자에서 유도한 천장/원점(ceiling)이다.**
> 
> - `oracle` 은 이제 `tools/monitor/policy.jl` 의 **실제로 실행되는 레인**이다(`oracle_macro()` 가 결정시점에 기준 행동 a* 를 계산하고 `pol["oracle"]` 로 집행한다; 2026-08-13 커밋 `d318d1d` 에서 신설). "policy.jl 에 oracle 분기가 없다"는 과거 서술은 그 커밋 이후로 사실이 아니다.
> - **그러나 이 630판 스윕에는 그 레인이 들어 있지 않다.** 이 스윕이 돌린 정책 집합은 `noop,surrogate,dspy` 셋뿐이다. 따라서 아래 표에 보이는 `oracle` 행의 값은 실행된 판에서 나온 것이 아니라 **오프라인 라벨 격자**(`reference_policy.py` 의 기준 행동 a*)에서 나온 것이다. "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.
> - 조합 case(`fault_battery`/`fault_zone`/`battery_zone`/`all`)의 `oracle` 칸이 `0,0` 으로 읽힌다면 그것은 "모든 판이 실패했다"가 **아니라 "해당 격자가 아예 없다"** 는 뜻이다 -- `results_matrix.py:44` 의 `ORACLE_KIND` 에는 조합 키가 없다(사건이 섞여서 나오므로 단일-종류 격자가 성립하지 않는다).
> - 실행 레인의 ZoneTruth 가지는 `reference_policy.py` 와 **의도적으로 갈린다**: Julia 쪽은 Python 채점기가 관측할 수 없는 `RECOVERY_SPARES` 상태로 게이트를 건다(요약의 `zone_primitives` 에 그런 칸이 없다). 그래서 `score()` 기준 결정 적중률은 84/84 가 아니라 **80/84** 다. 완주(completion)는 Julia 쪽이 authoritative 이고, 발행되는 `decision_acc` 열은 Python 쪽 값을 그대로 유지한다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) — J 채점 불가 2 instance (energy_J 없음) | 100% (정의상) | — | — |
| `surrogate` | 30/30 | 86% (103/120) | 50.7 ± 23.4 s | 528.9 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 53% (64/120) | 34.9 ± 15.1 s | 406.4 |

> **3-B 참고** -- `reference_policy.py` 의 zone 규칙은 root-covered 영역(`cov` 계열)에서 오라클과 어긋난다는 결함이 STEP D 로 드러났다. 이 case 를 포함한 8-case 스윕 전체에는 그 영역의 결정이 0건이라(전부 root_covered==0) 위 표의 zone 관련 숫자는 영향받지 않는다 -- 결함 상세는 `artifacts_4pol/REPORT.md` §3-B.

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 64.5 ± 0.0 | 535 | 0.997 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 86% (103/120) | 50.7 ± 23.4 | 529 | 0.998 | 12.0 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 53% (64/120) | 34.9 ± 15.1 | 406 | 0.998 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×180, NOOP×120 | Zone 0/120 |
| `surrogate` | RelocateBuild×103, ReformTeam×91, NOOP×17 | Zone 103/120 |
| `dspy` | RelocateBuild×64, NOOP×56, ReformTeam×48 | Zone 64/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/300) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/120) | 0% (0/211) | 86% (103/120) | 93% (84/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/120) | 0% (0/168) | 53% (64/120) | 44% (40/90) | 35% (21/60) | 40% (12/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000

</details>

---

## Post-hoc validation (V1-V4)

V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 · V3 빈 board 가 없는지 · V4 판 수가 (시드 수 x 정책 수) 인지. 아래 각 case 마다 네 줄씩 반드시 찍는다(조용한 생략 금지).

### case = battery
- V1 [PASS] dspy(n=139)/canonical(n=127) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 139/139, macro==llm(자기 shadow 선택과 일치) 139/139.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault
- V1 [PASS] dspy(n=136)/canonical(n=127) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 136/136, macro==llm(자기 shadow 선택과 일치) 136/136.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = zonecore
- 데이터 없음 -- V1-V4 해당 없음.

### case = all
- V1 [PASS] dspy(n=195)/canonical(n=286) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 195/195, macro==llm(자기 shadow 선택과 일치) 195/195.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault_battery
- V1 [PASS] dspy(n=128)/canonical(n=127) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 128/128, macro==llm(자기 shadow 선택과 일치) 128/128.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault_zone
- V1 [PASS] dspy(n=223)/canonical(n=283) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 223/223, macro==llm(자기 shadow 선택과 일치) 223/223.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = battery_zone
- V1 [PASS] dspy(n=209)/canonical(n=283) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 209/209, macro==llm(자기 shadow 선택과 일치) 209/209.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = zone
- V1 [PASS] dspy(n=168)/canonical(n=300) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 168/168, macro==llm(자기 shadow 선택과 일치) 168/168.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

---

## 누락 및 한계

### 이번 실행에서 빠지거나 실패한 case (조용한 절삭 금지 -- 이름으로 남긴다)
- `zonecore`: 데이터 없음 (status 기록 없음).

### 구조적 한계 (항상 참, plan §11)
- 시드 30개 -- 부호검정 최소 양측 p=1.9e-09. 무승부는 검정에서 제외되므로 천장효과(모든 정책이 항상 완주)인 case 에서는 시드를 늘려도 유의해지지 않는다.
- `world_seed` 고정(=1) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다.
- 빌드 시간(E4)은 **완주판만** 재므로 선택편향이 있다 -- 완주한 판끼리만 비교하는 것이라, 완주율이 낮은 정책일수록 살아남은 판만 뽑혀 유리하게 보인다.
- shadow 채점은 **상태조건부 결정 충실도**다("이 상태에서 이 정책이 a\* 를 골랐겠는가"). 결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.

