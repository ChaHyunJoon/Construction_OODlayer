# 4정책 x OOD case 비교표 -- FINAL (자동 생성)

생성 시각: 2026-08-13T02:40:04-07:00
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
| `oracle` (천장·비실행) | 100% (18/18) | 100% (정의상) | 19.8 (완주판 n=18) | — |
| `surrogate` | 30/30 | 0% (0/120) | 26.4 ± 4.3 s | 409.4 |
| `noop` (바닥선) | 30/30 | 0% (0/77) | 21.0 ± 0.0 s | 266.7 |
| `llm` (dspy) | 30/30 | 100% (120/120) | 21.0 ± 0.0 s | 266.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/77) | 21.0 ± 0.0 | 267 | 0.000 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 26.4 ± 4.3 | 409 | 0.968 | 8.0 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 100% (120/120) | 21.0 ± 0.0 | 267 | 0.972 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×77 | Battery 0/77 |
| `surrogate` | Replace×120, ReformTeam×3 | Battery 0/120 |
| `dspy` | SwapBattery×120 | Battery 120/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/77) | 0% (0/77) | 0% (0/77) | 0% (0/58) | 0% (0/38) | 0% (0/19) |
| `surrogate` | 0% (0/120) | 0% (0/123) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `dspy` | 0% (0/120) | 0% (0/120) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `noop` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000

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
| `oracle` (천장·비실행) | 100% (22/22) | 100% (정의상) | 21.8 (완주판 n=22) | — |
| `surrogate` | 30/30 | 100% (120/120) | 26.4 ± 4.3 s | 409.4 |
| `noop` (바닥선) | 0/30 | 0% (0/43) | — | 867.0 |
| `llm` (dspy) | 24/30 | 95% (109/115) | 25.9 ± 4.6 s | 570.0 |

> **3-A** -- 위 `oracle` 행의 완주율은 22개 **현재-세대** fault instance 만 반영한다(`firegrid_s{fault,faultidle}.jsonl`, NOOP/Replace 2-arm 메뉴). 구세대 18개 instance(5-arm 메뉴, macro 7/8 이전 라벨 -- CLAUDE.md "성능 근거 아님")는 헤드라인에서 제외했다 -- 참고용 완주율 83% (15/18). **이 둘을 풀링한 n=40 천장은 이 문서에 없다** (`artifacts_4pol/REPORT.md` §3-A 상세).

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 0% (0/30) [0.00, 0.11] | 0% (0/43) | — (완주 0) | 867 | 0.941 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 100% (120/120) | 26.4 ± 4.3 | 409 | 0.968 | 8.0 |
| `dspy` | 30 | 80% (24/30) [0.63, 0.90] | 95% (109/115) | 25.9 ± 4.6 | 570 | 0.945 | 8.4 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×223 | Fault 0/43 |
| `surrogate` | Replace×120, ReformTeam×3 | Fault 120/120 |
| `dspy` | Replace×109, ReformTeam×39, Deprioritize×6 | Fault 109/115 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/43) | 0% (0/223) | 0% (0/43) | 0% (0/32) | 0% (0/22) | 0% (0/11) |
| `surrogate` | 0% (0/120) | 0% (0/123) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/115) | 0% (0/154) | 95% (109/115) | 94% (81/86) | 93% (54/58) | 86% (25/29) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `noop` vs `dspy` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 6승 0패 24무, 부호검정 p=0.031

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
| `surrogate` | 23/30 | 67% (78/116) | 36.7 ± 8.3 s | 716.4 |
| `noop` (바닥선) | 0/30 | 0% (0/94) | — | 797.8 |
| `llm` (dspy) | 27/30 | 94% (111/118) | 38.1 ± 12.2 s | 526.6 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_all.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 0% (0/30) [0.00, 0.11] | 0% (0/94) | — (완주 0) | 798 | 0.327 | 12.0 |
| `surrogate` | 30 | 77% (23/30) [0.59, 0.88] | 67% (78/116) | 36.7 ± 8.3 | 716 | 0.930 | 9.4 |
| `dspy` | 30 | 90% (27/30) [0.74, 0.97] | 94% (111/118) | 38.1 ± 12.2 | 527 | 0.944 | 10.7 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×274 | Battery 0/29, Fault 0/33, Zone 0/32 |
| `surrogate` | Replace×78, ReformTeam×68, RelocateBuild×38 | Battery 0/38, Fault 40/40, Zone 38/38 |
| `dspy` | ReformTeam×62, Replace×40, SwapBattery×39, RelocateBuild×32, NOOP×6, Deprioritize×1 | Battery 39/39, Fault 40/41, Zone 32/38 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/94) | 0% (0/274) | 0% (0/94) | 0% (0/70) | 0% (0/47) | 0% (0/24) |
| `surrogate` | 0% (0/116) | 0% (0/184) | 67% (78/116) | 56% (49/87) | 52% (30/58) | 24% (7/29) |
| `dspy` | 0% (0/118) | 0% (0/180) | 94% (111/118) | 99% (87/88) | 98% (58/59) | 97% (29/30) |

- 짝지은 비교 `noop` vs `surrogate` — 4승 26패 0무, 부호검정 p=0.000
- 짝지은 비교 `noop` vs `dspy` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 1승 5패 24무, 부호검정 p=0.219

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
| `surrogate` | 30/30 | 50% (60/120) | 26.4 ± 4.3 s | 409.4 |
| `noop` (바닥선) | 2/30 | 0% (0/79) | 21.0 ± 0.0 s | 824.2 |
| `llm` (dspy) | 25/30 | 96% (113/118) | 24.0 ± 3.2 s | 448.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 7% (2/30) [0.02, 0.21] | 0% (0/79) | 21.0 ± 0.0 | 824 | 0.113 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 50% (60/120) | 26.4 ± 4.3 | 409 | 0.968 | 8.0 |
| `dspy` | 30 | 83% (25/30) [0.66, 0.93] | 96% (113/118) | 24.0 ± 3.2 | 449 | 0.954 | 10.2 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×247 | Battery 0/39, Fault 0/40 |
| `surrogate` | Replace×120, ReformTeam×3 | Battery 0/60, Fault 60/60 |
| `dspy` | SwapBattery×58, Replace×55, ReformTeam×30, Deprioritize×5 | Battery 58/58, Fault 55/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/79) | 0% (0/247) | 0% (0/79) | 0% (0/59) | 0% (0/40) | 0% (0/20) |
| `surrogate` | 0% (0/120) | 0% (0/123) | 50% (60/120) | 50% (45/90) | 47% (28/60) | 33% (10/30) |
| `dspy` | 0% (0/118) | 0% (0/148) | 96% (113/118) | 97% (85/88) | 95% (56/59) | 93% (28/30) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 28패 2무, 부호검정 p=0.000
- 짝지은 비교 `noop` vs `dspy` — 0승 28패 2무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 5승 0패 25무, 부호검정 p=0.062

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
| `surrogate` | 24/30 | 100% (117/117) | 36.5 ± 4.6 s | 668.7 |
| `noop` (바닥선) | 0/30 | 0% (0/85) | — | 793.0 |
| `llm` (dspy) | 25/30 | 83% (96/116) | 38.6 ± 11.4 s | 605.0 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 0% (0/30) [0.00, 0.11] | 0% (0/85) | — (완주 0) | 793 | 0.939 | 12.0 |
| `surrogate` | 30 | 80% (24/30) [0.63, 0.90] | 100% (117/117) | 36.5 ± 4.6 | 669 | 0.935 | 10.1 |
| `dspy` | 30 | 83% (25/30) [0.66, 0.93] | 83% (96/116) | 38.6 ± 11.4 | 605 | 0.939 | 10.2 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×265 | Fault 0/38, Zone 0/47 |
| `surrogate` | RelocateBuild×59, Replace×58, ReformTeam×58 | Fault 58/58, Zone 59/59 |
| `dspy` | ReformTeam×67, Replace×55, RelocateBuild×41, NOOP×18, Deprioritize×2 | Fault 55/57, Zone 41/59 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/85) | 0% (0/265) | 0% (0/85) | 0% (0/64) | 0% (0/42) | 0% (0/21) |
| `surrogate` | 0% (0/117) | 0% (0/175) | 100% (117/117) | 100% (88/88) | 100% (58/58) | 100% (29/29) |
| `dspy` | 0% (0/116) | 0% (0/183) | 83% (96/116) | 84% (73/87) | 95% (55/58) | 93% (27/29) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 29패 1무, 부호검정 p=0.000
- 짝지은 비교 `noop` vs `dspy` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 3승 5패 22무, 부호검정 p=0.727

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
| `surrogate` | 24/30 | 50% (59/117) | 36.5 ± 4.6 s | 668.7 |
| `noop` (바닥선) | 2/30 | 0% (0/108) | 21.0 ± 0.0 s | 626.2 |
| `llm` (dspy) | 29/30 | 85% (102/120) | 35.6 ± 10.7 s | 408.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 7% (2/30) [0.02, 0.21] | 0% (0/108) | 21.0 ± 0.0 | 626 | 0.011 | 12.0 |
| `surrogate` | 30 | 80% (24/30) [0.63, 0.90] | 50% (59/117) | 36.5 ± 4.6 | 669 | 0.935 | 10.1 |
| `dspy` | 30 | 97% (29/30) [0.83, 0.99] | 85% (102/120) | 35.6 ± 10.7 | 409 | 0.955 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×276 | Battery 0/48, Zone 0/60 |
| `surrogate` | RelocateBuild×59, Replace×58, ReformTeam×58 | Battery 0/58, Zone 59/59 |
| `dspy` | SwapBattery×60, ReformTeam×48, RelocateBuild×42, NOOP×18 | Battery 60/60, Zone 42/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/108) | 0% (0/276) | 0% (0/108) | 0% (0/81) | 0% (0/54) | 0% (0/27) |
| `surrogate` | 0% (0/117) | 0% (0/175) | 50% (59/117) | 34% (30/88) | 0% (0/58) | 0% (0/29) |
| `dspy` | 0% (0/120) | 0% (0/168) | 85% (102/120) | 87% (78/90) | 100% (60/60) | 100% (30/30) |

- 짝지은 비교 `noop` vs `surrogate` — 6승 22패 2무, 부호검정 p=0.004
- 짝지은 비교 `noop` vs `dspy` — 0승 28패 2무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 1승 6패 23무, 부호검정 p=0.125

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
| `oracle` (천장·비실행) | 100% (2/2) | 100% (정의상) | 30.3 (완주판 n=2) | — |
| `surrogate` | 30/30 | 100% (120/120) | 40.3 ± 1.5 s | 489.6 |
| `noop` (바닥선) | 0/30 | 0% (0/120) | — | 651.9 |
| `llm` (dspy) | 30/30 | 72% (87/120) | 36.3 ± 3.3 s | 436.6 |

> **3-B 참고** -- `reference_policy.py` 의 zone 규칙은 root-covered 영역(`cov` 계열)에서 오라클과 어긋난다는 결함이 STEP D 로 드러났다. 이 case 를 포함한 8-case 스윕 전체에는 그 영역의 결정이 0건이라(전부 root_covered==0) 위 표의 zone 관련 숫자는 영향받지 않는다 -- 결함 상세는 `artifacts_4pol/REPORT.md` §3-B.

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 30 | 0% (0/30) [0.00, 0.11] | 0% (0/120) | — (완주 0) | 652 | 0.944 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 100% (120/120) | 40.3 ± 1.5 | 490 | 0.950 | 12.0 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 72% (87/120) | 36.3 ± 3.3 | 437 | 0.955 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×300 | Zone 0/120 |
| `surrogate` | RelocateBuild×120, ReformTeam×30 | Zone 120/120 |
| `dspy` | RelocateBuild×87, NOOP×33, ReformTeam×30 | Zone 87/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/120) | 0% (0/300) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/120) | 0% (0/150) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/120) | 0% (0/150) | 72% (87/120) | 63% (57/90) | 53% (32/60) | 73% (22/30) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `noop` vs `dspy` — 0승 30패 0무, 부호검정 p=0.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000

</details>

---

## Post-hoc validation (V1-V4)

V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 · V3 빈 board 가 없는지 · V4 판 수가 (시드 수 x 정책 수) 인지. 아래 각 case 마다 네 줄씩 반드시 찍는다(조용한 생략 금지).

### case = battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 120/120 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 120/120 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 77건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 154/154 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 154/154 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 223건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = zonecore
- 데이터 없음 -- V1-V4 해당 없음.

### case = all
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 180/180 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 180/180 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 274건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault_battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 148/148 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 148/148 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 247건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = fault_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 183/183 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 183/183 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 265건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = battery_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 168/168 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 168/168 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 276건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 90개 전부 결정 >=1).
- V4 [PASS] 판 수 90 (30 seeds x 3 policies) 그대로.

### case = zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 150/150 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 150/150 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 300건 전부 NOOP.
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

