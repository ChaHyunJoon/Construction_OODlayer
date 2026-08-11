# 4정책 x OOD case 비교표 -- FINAL (자동 생성)

생성 시각: 2026-08-10T23:14:06-07:00
생성기: `build_final_table.py --results-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/results_4pol --out-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/artifacts_4pol`

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

실행 가능한 lane 은 `noop` / `surrogate` / `dspy`(=`llm`) 셋뿐이다(이번 스윕이 실제로 돌린 정책 집합과 같다). `oracle` 행은 매 블록에서 별도 계산되는 상한선으로만 들어간다.

기준 행동 a* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):
- `battery`: battgrid_0805_s1.jsonl, 18 instances (6 fire points x 3 severities), all 3 arms
- `fault`: firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect separation
- `zone`: zcausal_reform/ STEP 10, 2 arm-crossed events (n=2 -- weakest axis)

전체 pooled shadow 채점(모든 case 합산, 새 시뮬 0회): `artifacts_4pol/shadow.md`

---

## Case 블록

### case = battery   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 실측 n=18 | 100% (정의상) | — | — |
| `surrogate` | 5/5 | 0% (0/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 5/5 | 0% (0/11) | 21.6 ± 0.0 s | 343.0 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 21.6 ± 0.0 s | 343.0 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 100% (5/5) [0.57, 1.00] | 0% (0/11) | 21.6 ± 0.0 | 343 | 0.000 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 0% (0/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 21.6 ± 0.0 | 343 | 0.972 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×11 | Battery 0/11 |
| `surrogate` | Replace×20, ReformTeam×2 | Battery 0/20 |
| `dspy` | SwapBattery×20 | Battery 20/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/11) | 0% (0/11) | 0% (0/11) | 0% (0/8) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 0패 5무, 부호검정 p=1.000
- 짝지은 비교 `noop` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

---

### case = fault   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 0/5 | 0% (0/6) | — | 947.4 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/6) | — (완주 0) | 947 | 0.949 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×36 | Fault 0/6 |
| `surrogate` | Replace×20, ReformTeam×2 | Fault 20/20 |
| `dspy` | Replace×20, ReformTeam×2 | Fault 20/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/6) | 0% (0/36) | 0% (0/6) | 0% (0/4) | 0% (0/3) | 0% (0/2) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

---

### case = zonecore   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 100% (19/19) | 31.2 ± 1.9 s | 639.0 |
| `noop` (바닥선) | 0/5 | 0% (0/20) | — | 722.0 |
| `llm` (dspy) | 5/5 | 65% (13/20) | 26.1 ± 1.6 s | 439.3 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_zonecore.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/20) | — (완주 0) | 722 | 0.945 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (19/19) | 31.2 ± 1.9 | 639 | 0.952 | 12.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 65% (13/20) | 26.1 ± 1.6 | 439 | 0.965 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×50 | Zone 0/20 |
| `surrogate` | RelocateBuild×19, ReformTeam×6 | Zone 19/19 |
| `dspy` | RelocateBuild×13, NOOP×7 | Zone 13/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/20) | 0% (0/50) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `surrogate` | 0% (0/19) | 0% (0/25) | 100% (19/19) | 100% (14/14) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 65% (13/20) | 53% (8/15) | 40% (4/10) | 60% (3/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

---

### case = all   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 70% (14/20) | 31.1 ± 8.5 s | 651.6 |
| `noop` (바닥선) | 0/5 | 0% (0/17) | — | 837.4 |
| `llm` (dspy) | 5/5 | 85% (17/20) | 42.2 ± 20.9 s | 547.2 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_all.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/17) | — (완주 0) | 837 | 0.191 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 70% (14/20) | 31.1 ± 8.5 | 652 | 0.939 | 9.6 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 85% (17/20) | 42.2 ± 20.9 | 547 | 0.949 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×47 | Battery 0/6, Fault 0/5, Zone 0/6 |
| `surrogate` | Replace×12, RelocateBuild×8, ReformTeam×8 | Battery 0/6, Fault 6/6, Zone 8/8 |
| `dspy` | ReformTeam×12, SwapBattery×6, Replace×6, RelocateBuild×5, NOOP×3 | Battery 6/6, Fault 6/6, Zone 5/8 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/17) | 0% (0/47) | 0% (0/17) | 0% (0/13) | 0% (0/8) | 0% (0/4) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 70% (14/20) | 60% (9/15) | 50% (5/10) | 40% (2/5) |
| `dspy` | 0% (0/20) | 0% (0/32) | 85% (17/20) | 87% (13/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

---

### case = fault_battery   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 5/5 | 45% (9/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 1/5 | 0% (0/13) | 21.6 ± 0.0 s | 787.8 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 25.3 ± 4.9 s | 408.5 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_battery.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 20% (1/5) [0.04, 0.62] | 0% (0/13) | 21.6 ± 0.0 | 788 | 0.213 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 45% (9/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 25.3 ± 4.9 | 409 | 0.968 | 10.2 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×37 | Battery 0/7, Fault 0/6 |
| `surrogate` | Replace×20, ReformTeam×2 | Battery 0/11, Fault 9/9 |
| `dspy` | SwapBattery×11, Replace×9, ReformTeam×2 | Battery 11/11, Fault 9/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/13) | 0% (0/37) | 0% (0/13) | 0% (0/10) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 45% (9/20) | 53% (8/15) | 60% (6/10) | 40% (2/5) |
| `dspy` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `noop` vs `dspy` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

---

### case = fault_zone   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 100% (20/20) | 32.9 ± 4.5 s | 720.1 |
| `noop` (바닥선) | 0/5 | 0% (0/13) | — | 874.0 |
| `llm` (dspy) | 4/5 | 80% (16/20) | 29.5 ± 2.8 s | 647.2 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_fault_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/13) | — (완주 0) | 874 | 0.947 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (20/20) | 32.9 ± 4.5 | 720 | 0.937 | 9.8 |
| `dspy` | 5 | 80% (4/5) [0.38, 0.96] | 80% (16/20) | 29.5 ± 2.8 | 647 | 0.939 | 10.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×43 | Fault 0/5, Zone 0/8 |
| `surrogate` | Replace×11, RelocateBuild×9, ReformTeam×8 | Fault 11/11, Zone 9/9 |
| `dspy` | Replace×10, ReformTeam×8, RelocateBuild×6, NOOP×3, Deprioritize×1 | Fault 10/11, Zone 6/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/13) | 0% (0/43) | 0% (0/13) | 0% (0/10) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/28) | 80% (16/20) | 93% (14/15) | 90% (9/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

---

### case = battery_zone   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 45% (9/20) | 32.9 ± 4.5 s | 720.1 |
| `noop` (바닥선) | 1/5 | 0% (0/17) | 21.6 ± 0.0 s | 646.2 |
| `llm` (dspy) | 5/5 | 90% (18/20) | 23.7 ± 1.7 s | 398.7 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_battery_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 20% (1/5) [0.04, 0.62] | 0% (0/17) | 21.6 ± 0.0 | 646 | 0.009 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 45% (9/20) | 32.9 ± 4.5 | 720 | 0.937 | 9.8 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 90% (18/20) | 23.7 ± 1.7 | 399 | 0.967 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×41 | Battery 0/8, Zone 0/9 |
| `surrogate` | Replace×11, RelocateBuild×9, ReformTeam×8 | Battery 0/11, Zone 9/9 |
| `dspy` | SwapBattery×11, RelocateBuild×7, NOOP×2 | Battery 11/11, Zone 7/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/17) | 0% (0/41) | 0% (0/17) | 0% (0/13) | 0% (0/8) | 0% (0/4) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 45% (9/20) | 27% (4/15) | 0% (0/10) | 0% (0/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 90% (18/20) | 93% (14/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 3패 1무, 부호검정 p=0.625
- 짝지은 비교 `noop` vs `dspy` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

---

### case = zone   (n=5 seeds, world_seed=1, router=0)

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 100% (19/19) | 31.2 ± 1.9 s | 639.0 |
| `noop` (바닥선) | 0/5 | 0% (0/20) | — | 722.0 |
| `llm` (dspy) | 5/5 | 65% (13/20) | 26.1 ± 1.6 s | 439.3 |

shadow 채점(상태조건부 결정충실도, 새 시뮬 0회): `artifacts_4pol/shadow_zone.md` -- 완주/시간/에너지 주장에는 쓰지 말 것.

<details><summary>`llm_ood_eval.py report --md` 원본 (macro 선택 분포 · per-kind · escalation/novelty · 짝비교 부호검정)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/20) | — (완주 0) | 722 | 0.945 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (19/19) | 31.2 ± 1.9 | 639 | 0.952 | 12.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 65% (13/20) | 26.1 ± 1.6 | 439 | 0.965 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×50 | Zone 0/20 |
| `surrogate` | RelocateBuild×19, ReformTeam×6 | Zone 19/19 |
| `dspy` | RelocateBuild×13, NOOP×7 | Zone 13/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/20) | 0% (0/50) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `surrogate` | 0% (0/19) | 0% (0/25) | 100% (19/19) | 100% (14/14) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 65% (13/20) | 53% (8/15) | 40% (4/10) | 60% (3/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

---

## Post-hoc validation (V1-V4)

V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 · V3 빈 board 가 없는지 · V4 판 수가 5 seeds x 3 policies = 15 인지. 아래 각 case 마다 네 줄씩 반드시 찍는다(조용한 생략 금지).

### case = battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 11건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = fault
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 22/22 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 22/22 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 36건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = zonecore
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 50건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = all
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 32/32 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 32/32 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 47건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = fault_battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 22/22 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 22/22 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 37건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = fault_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 28/28 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 28/28 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 43건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = battery_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 41건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

### case = zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 50건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

---

## 누락 및 한계

### 이번 실행에서 빠지거나 실패한 case (조용한 절삭 금지 -- 이름으로 남긴다)
- 없음 -- 8개 case 전부 데이터 있고 report/shadow 정상 생성됨.

### 구조적 한계 (항상 참, plan §11)
- 통계적 유의성 없음 -- 시드 5개, 부호검정(sign test) 최소 p=0.062 (RESULTS_LLM7H.md 와 같은 한계).
- `world_seed` 고정(=1) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다.
- fault·zone 축의 오라클 결과-천장(B: a* 실행 결과)은 아직 없다 -- STEP D 선행 필요(`ORACLE_REBUILD_2026-08-09.md` §II, 추정 2~3시간). 결정-기준(A: a* 적중률)은 세 축 모두 있다.
- shadow 채점은 **상태조건부 결정 충실도**다("이 상태에서 이 정책이 a* 를 골랐겠는가"). 결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.

