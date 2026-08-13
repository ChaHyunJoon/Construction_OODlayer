# 공통 목적함수 — respec 제안자 셋과 그 아래 MILP 가 같은 J 를 최소화한다

- 날짜: 2026-08-13
- 대상 저장소: `Construction_OODlayer`, 브랜치 `oracle-rebuild-night-2026-08-10`
- 선행: 이 설계가 `2026-08-13-dp-oracle-design.md` 의 §6("목적함수 — 새로 만들지 않는다")과
  §9("surrogate 재학습은 범위 밖")을 **대체한다.** DP oracle 작업은 이 설계가 정한 J 위에서 재개한다.

## 1. 구조 — 하나의 자리, 세 가지 구현

```
failure / OOD 발생
   ↓
[ respec 제안자 ]  ←  DP (기준·최적)  |  surrogate (익숙한 case)  |  LLM (처음 보는 OOD)
   ↓  scene tree 수정안 (매크로)
verify  →  MILP 재풀이 (`replan.jl:942`)  →  commit          ← MILP = respec safety layer
   ↓
실현 결과 (complete, makespan, energy_J)
```

상시 배정은 greedy 가 맡고, MILP 는 respec 경로에서만 돈다(§6.1). 목적함수는 **양쪽 모두**에
들어가야 한다 — greedy 에 없으면 런 전체가 에너지를 못 보고, MILP 에 없으면 제안이 실행 단계에서
지워진다(§2.2).

셋은 **동급**이다. 같은 입력(failure 상황)을 받아 같은 출력(수정안)을 내며, 그 뒤 파이프라인은
동일하다. DP 는 그중 최적을 내는 기준선이고, surrogate·LLM 은 그 기준에 얼마나 근접하느냐로
평가된다. 층(layer)이 아니라 **서로 바꿔 끼울 수 있는 구현**이다.

목적함수가 하는 일은 하나다: **세 제안자가 "어느 수정안이 더 나은가"를 판단하는 기준을 하나로
통일하는 것.** 그리고 그 아래 MILP 도 같은 기준을 봐야 한다.

## 2. 문제 — 지금은 네 곳이 서로 다른 것을 최소화한다

| 자리 | 지금 최소화하는 것 | 근거 |
|---|---|---|
| MILP (수정 재풀이) | makespan 만 | `essential_tg_coponents.jl:1268` 기본값 `(speed=1.0, efficiency=0.0)`; `:1423` `w_eff == 0.0 && return speed_term` |
| DP / MC 오라클 | `better_ssp`: 완주 → (둘 다 완주면) makespan → closed → makespan | `gen_oracle_mc.jl:165`, 스칼라화는 `:146` |
| surrogate 라벨 | `lex(완주, closed − λ·MACRO_COST[macro], makespan)` | `e1_analyze.py:225` `cost_lex_key` |
| LLM | 목적함수를 받지 않음 | `llm_service/schema.py:217` 이 `"Never change the objective directly"` 로 금지 |

### 2.1 에너지 항은 삭제된 적이 없다 — 세 겹으로 꺼져 있었다

`essential_tg_coponents.jl:1398` 의 `get_objective_expr` 는 지금도 이 목적식을 만든다:

```
objective = w.speed · Σ tF[v]·weight  +  w_eff · Σ edge_energy(v,v2) · Xa[v,v2]
```

꺼져 있는 이유는 셋이다:

1. **모듈 기본값이 `efficiency = 0.0`** — 의도된 설계다. 주석: *"Default (speed=1, efficiency=0)
   reproduces the original SumOfMakeSpans objective EXACTLY"*, *"existing behavior is byte-for-byte
   preserved"*. 기존 스트림·오라클 라벨·surrogate 학습셋을 무효화하지 않으려는 opt-in 이었다.
2. **오라클/스윕 레인이 한 번도 켜지 않았다** — `git log -S "set_planning_objective_weights" --
   wm4spacecraft_manufacturing/` 가 **공백**이다(전 히스토리). 반면 `tools/e2e.jl:674`(`ENERGY_W`
   기본 0.01), `tools/demos.jl:1110`(1.0e-3), `:1279`(0.01) 는 켠다 — 데모 레인에서는 살아 있다.
3. **초기 계획이 MILP 를 건너뛴다** — `run_demo.jl:389` 가 `assignment_mode = :greedy`,
   `full_demo.jl:596` 이 greedy 분기. 초기 계획에서는 `get_objective_expr` 가 호출조차 안 된다.

**단, 수정 재풀이는 MILP 를 푼다** (`replan.jl:942`, 그리고 `verify()` 의 시험 풀이). 즉 목적함수는
이미 매 결정 지점에 도달하고 있으며, 거기서 에너지가 버려지고 있었다.

### 2.4 greedy 의 비용 확장점이 배선되지 않았다

`GreedyOrderedAssignment` 는 `greedy_cost` 필드를 갖고(`task_assignment.jl:275`),
`abstract type GreedyCost` 아래 구체 타입 3개가 정의돼 있으며(`essential_tg_coponents.jl:1459-1461`),
`full_demo.jl:600` 이 `GreedyFinalTimeCost()` 를 넘긴다. **그런데 그 값을 읽는 메서드가 하나도 없다.**

실제 배정 비용은 `assign_collaborative_tasks!` 안의 클로저에 하드코딩돼 있다
(`task_assignment.jl:46-51`):

```julia
cost_func = (v,v2) -> get_tF(sched,v) + distance_dict[(v,v2)]   # 끝나는 시각 + 이동시간
```

팀 비용은 슬롯 중 최댓값(가장 늦게 도착하는 로봇)이고, 그중 argmin 을 고른다. **순수 시간 지표이며
에너지가 들어갈 자리가 없다.** 세 `GreedyCost` 타입은 아무것도 디스패치하지 않는 죽은 마커이고,
어느 것을 넘겨도 동작이 같다. `update_greedy_cost_model!`(`essential_tg_coponents.jl:1543` 에서 호출)
은 저장소 어디에도 정의가 없다 — 그 경로는 죽은 코드이거나 도달하면 던진다.

따라서 greedy 에 에너지를 넣는 작업은 클로저를 해킹하는 것이 아니라 **설계돼 있었으나 배선되지
않은 확장점을 살리는 것**이다(§6.2).

### 2.2 이미 일어난 사고 — 제안이 실행 단계에서 지워졌다

`replan.jl:888` 의 주석이 이 설계의 존재 이유를 직접 적고 있다:

> The bias reaches the solver ONLY through the efficiency term, which the default weights
> (speed=1, efficiency=0) discard — registering it and re-solving without this changed
> **nothing at all** (the re-solve just re-optimized the SAME makespan objective).

제안자가 `DeprioritizeAgent`("이 로봇 일감을 줄여라")를 냈는데 아래 MILP 가 에너지를 안 보므로
그 제안이 **아무 효과 없이 사라졌다.** 저장소는 이것을 `DeprioritizeAgent` **한 매크로에만**
국소 패치했다(`replan.jl:901-908`: 그 정식화 한 번만 κ 를 켰다가 즉시 원복). **나머지 모든
매크로의 재풀이는 지금도 에너지가 버려진 채 돈다.**

같은 주석이 두 번째 결함을 알려준다:

> The battery SoC hook (`EDGE_COST_MULTIPLIER`, installed by `enable_battery!`) rides the **same term**

즉 `enable_battery!` 가 설치한 **SoC 기반 엣지 가격책정도 Deprioritize 외에는 전부 무력**이다.
배터리 잔량에 따라 일을 건강한 로봇으로 흘려보내는 기계가 만들어져 있으나 실제로는 작동하지 않는다.

### 2.3 지금 기록되지 않는 것

`results_4pol` 의 런 레벨 필드는 `complete, closed, total, progress, sim_seconds, wall_seconds` 뿐이다.
**energy 필드가 없고 makespan 도 없다**(`sim_seconds` 로 대신하고 있다). 에너지를 목적함수에 넣으려면
기록부터 만들어야 한다.

또한 기존 에너지 A/B 하니스 `tools/diagnostics.jl` 은 **로드조차 되지 않는다**(64번째 줄에서 실패,
실행으로 확인). 재사용할 수 없다.

## 3. 목적함수 J

실현된 런 하나에 대해 정의되는 **단일 스칼라**다:

```
J(run) =  complete ?  makespan + w_E · energy_J
                   :  C_fail + C_unclosed · (total − closed) + ε · makespan
```

- `complete` / `closed` / `total` / `makespan` 은 지금 `gen_oracle_mc.jl:338-341` 이 만드는 것과 같다.
- `energy_J` = **실현 구동에너지** `battery_report().total_energy_J` (`battery.jl:318`).
  `metrics.jl:57` 이 이미 `RunMetrics.energy` 를 이 값으로 정의하고 있다.
- 미완주 분기는 `gen_oracle_mc.jl:146` 의 `scalar_cost` 를 그대로 물려받는다. 유한벌점 SSP 이며
  `better_ssp`(`:165`) 와의 순서동치를 `check_order_equivalence` 로 계속 검사한다.

### 3.1 에너지는 완주 분기에만 들어간다

미완주 런은 일찍 멈추므로 에너지를 **덜** 쓴다. 실패 분기에 에너지 항을 넣으면 "일찍 죽는 것"이
이득이 된다. 이 규칙은 선택이 아니라 정합성 요구다. §9 의 검사가 이를 강제한다.

### 3.2 λ·MACRO_COST 는 넣지 않는다

`e1_analyze.py:225` 의 `cost_lex_key` 가 쓰는 개입 비용 항은 J 에 **들어가지 않는다.** MC 오라클이
개입에 비용을 매긴 적이 없고(`grep -c MACRO_COST oracle/gen_oracle_mc.jl` = 0), 발행된 오라클
숫자 전부가 그 기준으로 나왔다. 통일 방향은 오라클 쪽이다. `MACRO_COST` 표 자체는 특징량으로
계속 쓰이므로 삭제하지 않는다 — **비용함수에서만 빠진다.**

## 4. κ 와 단위 — 두 자리가 같은 무차원 수를 공유한다

MILP 의 에너지 항(`Σ edge_energy·Xa`, 계획 시점 운반에너지)과 J 의 `energy_J`(실현 구동에너지)는
**단위도 크기도 다르다.** 가중치를 그대로 복사할 수 없다. `essential_tg_coponents.jl:1276` 의
주석이 이 함정을 이미 적어 두었다:

> The two terms have different units... A fixed constant is either inert or it overturns makespan.

해법은 **각자 자기 스케일로 정규화하고 무차원 κ 하나만 공유**하는 것이다. κ 를 쓰는 자리는 셋이다:

| 자리 | 가중치 | 스케일 |
|---|---|---|
| greedy (상시 배정) | `w_g = κ · T_scale / Eg_scale` | 시간/에너지 스케일 — §8-0 에서 측정 |
| MILP (respec 재풀이) | `w_eff = κ · speed_scale / eff_scale` | 정식화마다 자동 산출 (`essential_tg_coponents.jl:1435`, 이미 구현됨) |
| J (제안자 셋의 판단 기준) | `w_E = κ · M_ref / E_ref` | 완주 런의 makespan/energy_J 중앙값 |

셋 다 "에너지 항은 시간 항 크기의 약 κ 배만큼 가치가 있다"를 뜻한다. **κ 하나만 돌리면 세 곳이
같이 움직인다** — 이것이 `objective.json` 을 진짜 단일 진실원으로 만드는 조건이다. 스케일 상수
(`T_scale`, `Eg_scale`, `M_ref`, `E_ref`)는 파일럿에서 측정해 `objective.json` 에 박는다.

### 4.1 κ 는 동점해소자다

κ 는 **진짜로 더 빠른 계획을 에너지가 뒤집지 못하는** 크기로 잡는다
(`essential_tg_coponents.jl` 의 κ 심 설계 의도: *"decisive among equal- and near-equal-makespan
assignments, unable to overturn a genuinely faster one"*). 초기값 κ = 0.01 로 두고 §8-3 에서 교정한다.

### 4.2 정직하게 밝혀야 할 한계

이 하니스의 **런간 makespan 노이즈는 약 4.6%** 다(동일 구성 재실행 68.175s vs 71.300s,
`results/control_d40_samesession.jsonl`). 동점해소자 크기의 에너지 항은 판당 수백 ms 규모라
**이 노이즈보다 작다.** 따라서 단일 런 비교에서 에너지가 결정을 바꾸는 일은 드물 것이다.

이것은 목적함수 정의의 결함이 아니라 **측정 정밀도의 한계**다. 두 가지가 이를 완화한다:

1. **MILP 안에는 표집 노이즈가 없다.** 같은 정식화 안에서 에너지는 즉시 결정력을 갖는다 —
   §2.2 의 사고가 고쳐지는 지점이 정확히 여기다.
2. **DP 는 K 회 평균과 paired 비교를 쓴다.** CRN 이 성립하면 팔 간 *차이*의 분산은 makespan
   자체의 분산보다 훨씬 작다.

그럼에도 **에너지가 a\* 를 한 번도 바꾸지 않는다면 그 사실을 지표로 보고한다**(§9). "energy 도
최소화한다"가 명목상 주장으로 남는 상황을 숨기지 않는다.

## 5. 단일 진실원 — `objective.json`

`action_registry.json` 과 같은 패턴으로 목적함수의 상수를 한 파일에 둔다:

```json
{
  "_doc": ["목적함수 J 의 단일 진실원. 이 값들이 코드에 리터럴로 복붙되면 조용히 갈린다.",
           "함정 29(MACRO_COST 가 3곳에 복붙됨)를 목적함수에서 미리 막는다."],
  "kappa": 0.01,
  "C_fail": 10000.0,
  "C_unclosed": 100.0,
  "tie_eps": 1.0e-3,
  "T_scale": null,
  "Eg_scale": null,
  "M_ref": null,
  "E_ref": null,
  "calibrated_from": null
}
```

`C_fail` / `C_unclosed` / `tie_eps` 의 값은 `gen_oracle_mc.jl:142-144` 의 현행 값을 그대로 옮긴다
(새로 정하지 않는다). 확인된 현행 값: `COST_FAIL = 10000.0`(ENV `MC_COST_FAIL` 로 덮어쓰기 가능),
`COST_UNCLOSED = 100.0`(ENV `MC_COST_UNCLOSED`), `COST_TIE_EPS = 1.0e-3`(ENV 없는 하드 상수).

**ENV 덮어쓰기 경로는 유지하되 우선순위를 명시한다**: ENV 가 설정돼 있으면 ENV 가 이기고, 그
사실이 산출물에 기록된다. 그렇지 않으면 `objective.json` 이 유일한 출처다. ENV 로 덮어쓴 런은
`objective.json` 해시 검사(§7)에서 **다른 세대로 취급**된다 — 조용히 섞이지 않게 하기 위함이다.

`M_ref` / `E_ref` 는 파일럿 전까지 `null` 이며, `null` 인 채로 J 를 계산하려 하면 **에러**를 낸다 —
조용히 0 이나 1 로 폴백하지 않는다.

### 5.1 읽는 곳

| 소비처 | 무엇을 읽나 |
|---|---|
| greedy `GreedyEnergyAwareCost` | `kappa`, `T_scale`, `Eg_scale` |
| MILP 전역 κ (`AUTO_EFFICIENCY_KAPPA` 기본값) | `kappa` |
| `gen_oracle_mc.jl` `scalar_cost` | 전부 |
| `gen_oracle_dataset.jl` (surrogate 라벨러) | 전부 |
| `dp_solve.py` | 전부 |
| `e1_analyze.py` (`cost_lex_key` 대체) | 전부 |

`audit_action_vocab.py` 와 같은 형식의 감사 스크립트를 붙여, 이 여섯 곳이 같은 파일을 읽는지
기계적으로 검사한다. 리터럴 복붙은 에러 없이 성능으로만 새는 종류의 결함이다.

## 6. 각 자리가 J 를 쓰는 방법

### 6.1 역할 분담 — MILP 는 상시 풀이가 아니라 safety layer 다

**초기 계획은 greedy 로 유지한다.** `assignment_mode = :milp` 로 전환하지 않는다. 이유:

- 에너지를 greedy 비용에 직접 넣으면 목적함수가 **런 전체**에 닿는다 — `:milp` 전환이 주는 것과
  같은 도달 범위를, HiGHS 없이 얻는다.
- `:milp` 상시 풀이는 비용이 미측정이고, 이 저장소는 MILP 병렬 실행에서 OOM 과 비교 무효를 겪은
  실측 기록이 있다(CLAUDE.md 함정 30). 630판 스윕의 병렬성이 greedy 라서 성립한다
  (`run_4pol_parallel.sh:8`).
- MILP 는 respec 경로에서 **verify(시험 풀이) + 재풀이**라는 안전 역할을 계속 맡는다. 제안이
  실행가능한지 판정하고 제약을 지킨 해를 내는 것이 MILP 가 잘하는 일이다.

### 6.2 greedy — 죽은 확장점을 살린다

`GreedyEnergyAwareCost <: GreedyCost` 를 추가하고, `assign_collaborative_tasks!` 의 하드코딩된
`cost_func` 을 `model.greedy_cost` 로 **디스패치**하게 바꾼다:

```
GreedyFinalTimeCost     →  get_tF(v) + dt                                   # 현행 동작을 정확히 보존
GreedyEnergyAwareCost   →  get_tF(v) + dt + w_g · edge_energy(dt) · edge_cost_multiplier(sched, v)
```

`edge_energy(dt_min)` 는 이미 있고(`essential_tg_coponents.jl:1337`), `edge_cost_multiplier` 도 이미
있으며 — **그것이 `agent_cost_bias × 배터리 SoC 배율` 을 나르는 바로 그 함수**다. 즉 이 변경 하나로
greedy 경로에서도 `DeprioritizeAgent` 와 배터리 SoC 조향이 살아난다. 지금은 둘 다 완전히 무력이다.

기존 동작 보존이 계약이다: `GreedyFinalTimeCost` 분기는 현행 클로저와 **바이트 단위로 같은 값**을
내야 하며, §9 의 회귀 검사가 이를 강제한다.

### 6.3 MILP (respec 재풀이)

κ 를 `DeprioritizeAgent` 국소 스코프에서 **전역 기본값으로 승격**한다. 이 한 변경이 모든 매크로의
재풀이에 에너지 항과 배터리 SoC 가격책정을 되살린다(§2.2). `replan.jl:901-908` 의 국소 스코프는
제거하고 전역 κ 로 대체한다.
- **DP** — `Q(s̃,a) = E[J]`, `a*(s̃) = argmin_a Q`. 동점 집합(paired SE 밴드)은 **J 의 일부가 아니라**
  표집 노이즈 하에서 a\* 를 보고하는 방법이며, dp-oracle spec §7 을 그대로 따른다.
- **surrogate** — J 를 회귀하고 지원 팔 중 argmin 을 고른다. 학습셋을 새 J 와 새 플래너 설정에서
  **재라벨·재학습**한다.
- **LLM** — 수정안을 제안한다. J 를 프롬프트로 받지 않으며(`schema.py:217` 의 금지를 유지),
  DP 의 a\* 와의 근접도로 평가된다.

## 7. 세대 교체

이 변경은 플래너 동역학을 바꾸므로 **현재의 발행 숫자·오라클 라벨·surrogate 학습셋이 전부
구세대가 된다.** CLAUDE.md 의 "★ 결과 세대" 관행을 그대로 따른다:

1. 구세대 결과 문서에 🔴 배너를 붙인다(삭제하지 않는다 — 되돌리기와 비교에 쓴다).
2. 신세대의 **기계적 판정 계약**을 하나 정의한다: 모든 산출물이 자기가 쓴 `objective.json` 의
   해시를 기록하고, 소비처가 현재 해시와 다르면 **에러로 멈춘다.** "두 세대가 섞여 실제로 오판이
   일어났다"는 것이 이 저장소의 실측 경험이다(CLAUDE.md).

## 8. 순서와 게이트

| # | 단계 | 게이트 / 중단 조건 |
|---|---|---|
| 1 | 런 레벨에 `total_energy_J` 와 `makespan` 기록 추가 | 지금 둘 다 없다(§2.3). 이 단계는 동작을 바꾸지 않으므로 기존 세대에서 먼저 돌려 스케일을 잰다 |
| 2 | greedy 비용을 `greedy_cost` 디스패치로 배선 (`GreedyFinalTimeCost` 는 현행 동작 보존) | **회귀 검사 통과 전에는 다음으로 안 간다** — 같은 시드에서 배정이 바이트 단위로 같아야 한다 |
| 3 | 스케일 측정 — 기존 세대 몇 판에서 `T_scale`/`Eg_scale`/`M_ref`/`E_ref` 수집 | 에너지가 한 번도 기록된 적 없으므로 이 측정이 κ 의 유일한 근거다 |
| 4 | `objective.json` + 여섯 소비처 + 감사 스크립트, κ 확정 | 감사 통과. 스케일이 `null` 인 채로 J 계산 시 에러 |
| 5 | `GreedyEnergyAwareCost` 활성화 + MILP 전역 κ 승격 | **배터리 훅 활성 검사**(§9): 모든 재풀이에서 `LAST_AUTO_EFFICIENCY_W[] > 0` |
| 6 | 630판 스윕 재실행 — **신세대** | greedy 라 병렬 유지, 비용은 현행과 동급 |
| 7 | surrogate 재라벨 + 재학습 | `test_surrogate_support.py` 재검증 |
| 8 | prefix 결정성 재측정 — **주입점 4개 전부**(`closed ≈ 55/141/204/274`) | 깨지면 DP 표집이 `measured` 경로(K 2배). fork 는 구조적으로 불가(§11-2) |
| 9 | DP 계획(`2026-08-13-dp-oracle.md` Task 2~12) 재개 | |

**단계 2 가 차단성이다.** `assign_collaborative_tasks!` 는 핵심 스케줄링 함수이고, 여기서 조용한
회귀가 나면 이후 모든 숫자가 오염된다. 에너지 항을 켜기 **전에**, 디스패치로 바꾸기만 한 상태에서
기존 동작이 정확히 보존되는지부터 확인한다. 두 변경을 한 커밋에 섞지 않는다.

**단계 3 이 단계 6 보다 앞서는 이유**: κ 를 정하려면 에너지 스케일을 알아야 하고, 에너지 스케일을
알려면 에너지를 먼저 기록해야 한다. 순서를 뒤집으면 자리표시자 κ 로 630판을 굴리게 된다.

## 9. 검증

| 검사 | 무엇을 막나 |
|---|---|
| **순서동치** — `argmin J` 가 `better_ssp` 순위를 재현하는가 | 스칼라화가 사전식 순위를 뒤집는 것. `check_order_equivalence` 재사용 |
| **무력 검사** — 에너지 항이 a\* 를 한 번이라도 바꾸는가 | κ 가 노이즈에 묻혀 "energy 도 최소화"가 명목상 주장이 되는 것. **0 이면 0 이라고 보고한다** |
| **실패 보상 검사** — 미완주 런의 J 가 완주 런보다 낮은 경우가 있는가 | §3.1 위반. 있으면 즉시 실패 |
| **배터리 훅 활성 검사** — 모든 재풀이에서 `LAST_AUTO_EFFICIENCY_W[] > 0` 인가 | §2.2 의 결함이 남아 있는 것. 지금은 Deprioritize 에서만 참 |
| **greedy 회귀 검사** — `GreedyFinalTimeCost` 디스패치가 현행 클로저와 같은 배정을 내는가 | 확장점 배선(§6.2)이 조용히 스케줄을 바꾸는 것. **단계 2 의 게이트** |
| **greedy 디스패치 생존 검사** — `greedy_cost` 를 바꾸면 배정이 실제로 달라지는가 | §2.4 의 결함(값이 저장만 되고 안 읽힘)이 되살아나는 것 |
| **objective.json 해시 일치** — 산출물의 해시가 현재와 같은가 | 세대 혼입(§7) |

## 10. 범위 밖 (의도)

- **비결정성의 원인 규명.** 단계 6 이 그것을 측정하되 규명하지는 않는다.
- **`adaptability` 축.** `metrics.jl:143` 의 4축 중 adaptability 는 J 에 넣지 않는다. 재계획 시점
  항이라 realized 런 하나에 대한 스칼라로 정의되지 않는다.
- **`handling_energy` 를 J 에 넣는 것.** 계획 산물이지 물리량이 아니고, 런 중 재계획이 여러 번
  일어나면 런 전체 값이 깨끗하게 정의되지 않는다. 진단으로만 기록한다.

## 11. 알려진 구멍

1. **κ 가 무력할 수 있다.** §4.2. 완화책 둘을 적었으나 보장은 아니다. 무력 검사가 이를 드러낸다.
2. **fork 표집 경로가 구조적으로 막혀 있다.** RVO2 C++ 인스턴스(`rvo_global_sim()`),
   `BATTERY_FLEET`(`battery.jl:111`), `HAZARD_STATE`, `OOD_SCHEDULE`, `SIM_STEP` 이 전부 프로세스
   전역 싱글턴이라 `deepcopy(env)` 로 두 계보를 갈라도 같은 물리를 공유한다. 단계 6 에서 결정성이
   깨지면 `measured` 경로밖에 없고 표집 비용이 2배가 된다.
3. **스케일 상수는 파일럿 표본에 의존한다.** 표본이 작으면 κ 의 실효 크기가 흔들린다. 파일럿
   판수와 그때의 분산을 `objective.json` 의 `calibrated_from` 에 기록한다.
4. **greedy 의 에너지 항은 근시안적(myopic)이다.** 매 배정 한 건을 국소적으로 고를 뿐 전역 최적이
   아니다. 다만 greedy 의 makespan 항도 이미 그러하므로 **새로 생기는 성질은 아니다** — greedy 를
   쓰는 대가일 뿐이고, 그 대가는 이미 치르고 있었다. 전역 최적이 필요한 자리(respec 재풀이)는
   MILP 가 맡는다(§6.1).
5. **에너지가 지금까지 한 번도 기록된 적이 없다.** 따라서 에너지 스케일에 대한 사전 지식이 전혀
   없고, κ 초기값 0.01 은 근거 있는 값이 아니라 **자리표시자**다. 단계 3 이 이를 대체한다.
6. **`assign_collaborative_tasks!` 수정은 회귀 위험이 있다.** 핵심 스케줄링 함수이며, 이 저장소의
   모든 숫자가 그 위에 있다. 단계 2 의 회귀 검사가 유일한 방어선이다.
7. **`update_greedy_cost_model!` 이 정의 없이 호출된다**(`essential_tg_coponents.jl:1543`). 그 경로가
   죽은 코드인지 도달 시 던지는지 확인하지 않았다. §6.2 작업 중에 확인하고, 죽은 코드면 지운다.
