# 4정책 x OOD case 비교표 -- FINAL (자동 생성)

생성 시각: 2026-08-14T22:02:57-07:00
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
| `surrogate` | 29/30 | 0% (0/120) | 26.0 ± 6.9 s | 450.9 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 100% (120/120) | 19.6 ± 0.0 s | 260.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 97% (29/30) [0.83, 0.99] | 0% (0/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `surrogate` | 30 | 97% (29/30) [0.83, 0.99] | 0% (0/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 100% (120/120) | 19.6 ± 0.0 | 261 | 0.999 | 12.0 |
| `dp` | 30 | 97% (29/30) [0.83, 0.99] | 45% (54/120) | 21.8 ± 4.1 | 372 | 0.999 | 9.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×17 | Battery 0/120 |
| `surrogate` | Replace×120, ReformTeam×17 | Battery 0/120 |
| `dspy` | SwapBattery×120 | Battery 120/120 |
| `dp` | Replace×66, SwapBattery×54, ReformTeam×10 | Battery 54/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/137) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/120) | 0% (0/137) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `dspy` | 0% (0/120) | 0% (0/120) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/130) | 45% (54/120) | 52% (47/90) | 53% (32/60) | 77% (23/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `dspy` vs `dp` — 1승 0패 29무, 부호검정 p=1.000

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
| `surrogate` | 29/30 | 100% (120/120) | 26.0 ± 6.9 s | 450.9 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 26/30 | 93% (112/120) | 32.4 ± 19.9 s | 598.9 |

> **3-A** -- 위 `oracle` 행의 완주율은 22개 **현재-세대** fault instance 만 반영한다(`firegrid_s{fault,faultidle}.jsonl`, NOOP/Replace 2-arm 메뉴). 구세대 18개 instance(5-arm 메뉴, macro 7/8 이전 라벨 -- CLAUDE.md "성능 근거 아님")는 헤드라인에서 제외했다 -- 참고용 완주율 0% (0/3). **이 둘을 풀링한 n=40 천장은 이 문서에 없다** (`artifacts_4pol/REPORT.md` §3-A 상세).

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 97% (29/30) [0.83, 0.99] | 100% (120/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `surrogate` | 30 | 97% (29/30) [0.83, 0.99] | 100% (120/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `dspy` | 30 | 87% (26/30) [0.70, 0.95] | 93% (112/120) | 32.4 ± 19.9 | 599 | 0.998 | 8.3 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 41% (49/120) | 21.1 ± 4.1 | 300 | 0.999 | 10.4 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×17 | Fault 120/120 |
| `surrogate` | Replace×120, ReformTeam×17 | Fault 120/120 |
| `dspy` | Replace×112, ReformTeam×68, Deprioritize×8 | Fault 112/120 |
| `dp` | SwapBattery×71, Replace×49, ReformTeam×3 | Fault 49/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/137) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `surrogate` | 0% (0/120) | 0% (0/137) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/120) | 0% (0/188) | 93% (112/120) | 94% (85/90) | 100% (60/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/123) | 41% (49/120) | 28% (25/90) | 8% (5/60) | 13% (4/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 3승 0패 27무, 부호검정 p=0.250
- 짝지은 비교 `canonical` vs `dp` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 3승 0패 27무, 부호검정 p=0.250
- 짝지은 비교 `surrogate` vs `dp` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `dspy` vs `dp` — 0승 4패 26무, 부호검정 p=0.125

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
| `surrogate` | 21/30 | 68% (75/111) | 25.5 ± 4.7 s | 788.7 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 28/30 | 89% (106/119) | 32.3 ± 16.6 s | 468.3 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_all.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 35% (42/120) | 62.7 ± 14.1 | 733 | 0.997 | 9.3 |
| `surrogate` | 30 | 70% (21/30) [0.52, 0.83] | 68% (75/111) | 25.5 ± 4.7 | 789 | 0.997 | 9.5 |
| `dspy` | 30 | 93% (28/30) [0.79, 0.98] | 89% (106/119) | 32.3 ± 16.6 | 468 | 0.998 | 10.7 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 38% (46/120) | 47.4 ± 19.1 | 503 | 0.998 | 10.9 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×164, Replace×81, NOOP×39 | Battery 0/39, Fault 42/42, Zone 0/39 |
| `surrogate` | ReformTeam×92, Replace×74, RelocateBuild×37 | Battery 0/35, Fault 38/39, Zone 37/37 |
| `dspy` | ReformTeam×58, SwapBattery×39, Replace×39, RelocateBuild×29, NOOP×10, Deprioritize×2 | Battery 39/39, Fault 38/41, Zone 29/39 |
| `dp` | ReformTeam×110, SwapBattery×49, NOOP×32, Replace×32, RelocateBuild×7 | Battery 23/39, Fault 16/42, Zone 7/39 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/284) | 35% (42/120) | 47% (42/90) | 50% (30/60) | 27% (8/30) |
| `surrogate` | 0% (0/111) | 0% (0/203) | 68% (75/111) | 57% (47/83) | 50% (28/56) | 21% (6/28) |
| `dspy` | 0% (0/119) | 0% (0/177) | 89% (106/119) | 94% (84/89) | 98% (59/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/230) | 38% (46/120) | 43% (39/90) | 42% (25/60) | 57% (17/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 9승 0패 21무, 부호검정 p=0.004
- 짝지은 비교 `canonical` vs `dspy` — 2승 0패 28무, 부호검정 p=0.500
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 8패 22무, 부호검정 p=0.008
- 짝지은 비교 `surrogate` vs `dp` — 0승 9패 21무, 부호검정 p=0.004
- 짝지은 비교 `dspy` vs `dp` — 0승 2패 28무, 부호검정 p=0.500

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
| `surrogate` | 29/30 | 50% (60/120) | 26.0 ± 6.9 s | 450.9 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 28/30 | 97% (116/120) | 24.0 ± 12.2 s | 393.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 97% (29/30) [0.83, 0.99] | 50% (60/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `surrogate` | 30 | 97% (29/30) [0.83, 0.99] | 50% (60/120) | 26.0 ± 6.9 | 451 | 0.999 | 8.0 |
| `dspy` | 30 | 93% (28/30) [0.79, 0.98] | 97% (116/120) | 24.0 ± 12.2 | 394 | 0.998 | 10.1 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 45% (54/120) | 21.9 ± 4.7 | 315 | 0.999 | 10.1 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | Replace×120, ReformTeam×17 | Battery 0/60, Fault 60/60 |
| `surrogate` | Replace×120, ReformTeam×17 | Battery 0/60, Fault 60/60 |
| `dspy` | SwapBattery×60, Replace×56, ReformTeam×34, Deprioritize×4 | Battery 60/60, Fault 56/60 |
| `dp` | SwapBattery×64, Replace×56, ReformTeam×4 | Battery 29/60, Fault 25/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/137) | 50% (60/120) | 51% (46/90) | 45% (27/60) | 30% (9/30) |
| `surrogate` | 0% (0/120) | 0% (0/137) | 50% (60/120) | 51% (46/90) | 45% (27/60) | 30% (9/30) |
| `dspy` | 0% (0/120) | 0% (0/154) | 97% (116/120) | 99% (89/90) | 98% (59/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/124) | 45% (54/120) | 42% (38/90) | 43% (26/60) | 50% (15/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 2승 1패 27무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dp` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 2승 1패 27무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dp` — 0승 1패 29무, 부호검정 p=1.000
- 짝지은 비교 `dspy` vs `dp` — 0승 2패 28무, 부호검정 p=0.500

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
| `surrogate` | 26/30 | 100% (117/117) | 26.9 ± 4.8 s | 597.4 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 26/30 | 81% (95/118) | 37.9 ± 19.0 s | 638.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 50% (60/120) | 59.8 ± 9.7 | 656 | 0.997 | 10.0 |
| `surrogate` | 30 | 87% (26/30) [0.70, 0.95] | 100% (117/117) | 26.9 ± 4.8 | 597 | 0.998 | 10.1 |
| `dspy` | 30 | 87% (26/30) [0.70, 0.95] | 81% (95/118) | 37.9 ± 19.0 | 639 | 0.997 | 10.2 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 29% (35/120) | 41.7 ± 19.9 | 453 | 0.998 | 11.2 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×153, Replace×60, NOOP×60 | Fault 60/60, Zone 0/60 |
| `surrogate` | RelocateBuild×59, Replace×58, ReformTeam×45 | Fault 58/58, Zone 59/59 |
| `dspy` | ReformTeam×89, Replace×53, RelocateBuild×42, NOOP×18, Deprioritize×5 | Fault 53/58, Zone 42/60 |
| `dp` | ReformTeam×88, NOOP×49, SwapBattery×36, Replace×24, RelocateBuild×11 | Fault 24/60, Zone 11/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/273) | 50% (60/120) | 67% (60/90) | 100% (60/60) | 100% (30/30) |
| `surrogate` | 0% (0/117) | 0% (0/162) | 100% (117/117) | 100% (88/88) | 100% (58/58) | 100% (29/29) |
| `dspy` | 0% (0/118) | 0% (0/207) | 81% (95/118) | 83% (73/88) | 92% (54/59) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/208) | 29% (35/120) | 27% (24/90) | 40% (24/60) | 10% (3/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 4승 0패 26무, 부호검정 p=0.125
- 짝지은 비교 `canonical` vs `dspy` — 4승 0패 26무, 부호검정 p=0.125
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 1승 1패 28무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dp` — 0승 4패 26무, 부호검정 p=0.125
- 짝지은 비교 `dspy` vs `dp` — 0승 4패 26무, 부호검정 p=0.125

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
| `surrogate` | 26/30 | 50% (59/117) | 26.9 ± 4.8 s | 597.4 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 92% (110/120) | 25.1 ± 9.7 s | 333.6 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 59.8 ± 9.7 | 656 | 0.997 | 10.0 |
| `surrogate` | 30 | 87% (26/30) [0.70, 0.95] | 50% (59/117) | 26.9 ± 4.8 | 597 | 0.998 | 10.1 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 92% (110/120) | 25.1 ± 9.7 | 334 | 0.999 | 12.0 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 33% (40/120) | 43.2 ± 20.5 | 480 | 0.998 | 11.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×153, Replace×60, NOOP×60 | Battery 0/60, Zone 0/60 |
| `surrogate` | RelocateBuild×59, Replace×58, ReformTeam×45 | Battery 0/58, Zone 59/59 |
| `dspy` | SwapBattery×60, RelocateBuild×50, ReformTeam×11, NOOP×10 | Battery 60/60, Zone 50/60 |
| `dp` | ReformTeam×92, NOOP×49, Replace×31, SwapBattery×29, RelocateBuild×11 | Battery 29/60, Zone 11/60 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/273) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/117) | 0% (0/162) | 50% (59/117) | 34% (30/88) | 0% (0/58) | 0% (0/29) |
| `dspy` | 0% (0/120) | 0% (0/131) | 92% (110/120) | 91% (82/90) | 100% (60/60) | 100% (30/30) |
| `dp` | 0% (0/120) | 0% (0/212) | 33% (40/120) | 32% (29/90) | 48% (29/60) | 63% (19/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 4승 0패 26무, 부호검정 p=0.125
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 4패 26무, 부호검정 p=0.125
- 짝지은 비교 `surrogate` vs `dp` — 0승 4패 26무, 부호검정 p=0.125
- 짝지은 비교 `dspy` vs `dp` — 0승 0패 30무, 부호검정 p=1.000

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
| `surrogate` | 30/30 | 100% (120/120) | 28.8 ± 7.3 s | 417.9 |
| `noop` (바닥선) | 정책 없음 (case 데이터에 `noop` 미포함) | — | — | — |
| `llm` (dspy) | 30/30 | 82% (99/120) | 28.6 ± 11.4 s | 389.8 |

> **3-B 참고** -- `reference_policy.py` 의 zone 규칙은 root-covered 영역(`cov` 계열)에서 오라클과 어긋난다는 결함이 STEP D 로 드러났다. 이 case 를 포함한 8-case 스윕 전체에는 그 영역의 결정이 0건이라(전부 root_covered==0) 위 표의 zone 관련 숫자는 영향받지 않는다 -- 결함 상세는 `artifacts_4pol/REPORT.md` §3-B.

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `canonical` | 30 | 100% (30/30) [0.89, 1.00] | 0% (0/120) | 56.4 ± 0.0 | 492 | 0.997 | 12.0 |
| `surrogate` | 30 | 100% (30/30) [0.89, 1.00] | 100% (120/120) | 28.8 ± 7.3 | 418 | 0.998 | 12.0 |
| `dspy` | 30 | 100% (30/30) [0.89, 1.00] | 82% (99/120) | 28.6 ± 11.4 | 390 | 0.998 | 12.0 |
| `dp` | 30 | 100% (30/30) [0.89, 1.00] | 16% (19/120) | 33.3 ± 17.9 | 361 | 0.998 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `canonical` | ReformTeam×150, NOOP×120 | Zone 0/120 |
| `surrogate` | RelocateBuild×120, ReformTeam×6 | Zone 120/120 |
| `dspy` | RelocateBuild×99, NOOP×21, ReformTeam×12 | Zone 99/120 |
| `dp` | NOOP×101, ReformTeam×55, RelocateBuild×19 | Zone 19/120 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `canonical` | 0% (0/120) | 0% (0/270) | 0% (0/120) | 0% (0/90) | 0% (0/60) | 0% (0/30) |
| `surrogate` | 0% (0/120) | 0% (0/126) | 100% (120/120) | 100% (90/90) | 100% (60/60) | 100% (30/30) |
| `dspy` | 0% (0/120) | 0% (0/132) | 82% (99/120) | 79% (71/90) | 73% (44/60) | 70% (21/30) |
| `dp` | 0% (0/120) | 0% (0/175) | 16% (19/120) | 6% (5/90) | 0% (0/60) | 0% (0/30) |

- 짝지은 비교 `canonical` vs `surrogate` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `canonical` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dp` — 0승 0패 30무, 부호검정 p=1.000
- 짝지은 비교 `dspy` vs `dp` — 0승 0패 30무, 부호검정 p=1.000

</details>

---

## Post-hoc validation (V1-V4)

V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 · V3 빈 board 가 없는지 · V4 판 수가 (시드 수 x 정책 수) 인지. 아래 각 case 마다 네 줄씩 반드시 찍는다(조용한 생략 금지).

### case = battery
- V1 [PASS] dspy(n=120)/canonical(n=137) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 120/120, macro==llm(자기 shadow 선택과 일치) 120/120.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = fault
- V1 [PASS] dspy(n=188)/canonical(n=137) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 188/188, macro==llm(자기 shadow 선택과 일치) 188/188.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = zonecore
- 데이터 없음 -- V1-V4 해당 없음.

### case = all
- V1 [PASS] dspy(n=177)/canonical(n=284) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 177/177, macro==llm(자기 shadow 선택과 일치) 177/177.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = fault_battery
- V1 [PASS] dspy(n=154)/canonical(n=137) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 154/154, macro==llm(자기 shadow 선택과 일치) 154/154.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = fault_zone
- V1 [PASS] dspy(n=207)/canonical(n=273) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 207/207, macro==llm(자기 shadow 선택과 일치) 207/207.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = battery_zone
- V1 [PASS] dspy(n=131)/canonical(n=273) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 131/131, macro==llm(자기 shadow 선택과 일치) 131/131.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

### case = zone
- V1 [PASS] dspy(n=132)/canonical(n=270) enacted-macro 시퀀스가 다르다 -- 동일 정책 이중 계측 신호 없음. 참고: dspy 판 중 enacted=='dspy' 132/132, macro==llm(자기 shadow 선택과 일치) 132/132.
- V2 [WARN] noop 판이 이 case 에 없다 -- 검증 대상 없음.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 120개 전부 결정 >=1).
- V4 [PASS] 판 수 120 (30 seeds x 4 policies) 그대로.

---

## 누락 및 한계

### 이번 실행에서 빠지거나 실패한 case (조용한 절삭 금지 -- 이름으로 남긴다)
- `zonecore`: 데이터 없음 (status 기록 없음).

### 구조적 한계 (항상 참, plan §11)
- 시드 30개 -- 부호검정 최소 양측 p=1.9e-09. 무승부는 검정에서 제외되므로 천장효과(모든 정책이 항상 완주)인 case 에서는 시드를 늘려도 유의해지지 않는다.
- `world_seed` 고정(=1) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다.
- 빌드 시간(E4)은 **완주판만** 재므로 선택편향이 있다 -- 완주한 판끼리만 비교하는 것이라, 완주율이 낮은 정책일수록 살아남은 판만 뽑혀 유리하게 보인다.
- shadow 채점은 **상태조건부 결정 충실도**다("이 상태에서 이 정책이 a\* 를 골랐겠는가"). 결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.

