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
verify  →  MILP 재풀이 (`replan.jl:942`)  →  commit
   ↓
실현 결과 (complete, makespan, energy_J)
```

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

해법은 **양쪽 모두 자기 스케일로 정규화하고 무차원 κ 하나만 공유**하는 것이다.

| 자리 | 가중치 |
|---|---|
| MILP | `w_eff = κ · speed_scale / eff_scale` (`essential_tg_coponents.jl:1435`, 이미 구현됨) |
| J | `w_E = κ · M_ref / E_ref` |

`M_ref` / `E_ref` 는 **완주한 런들의 makespan / energy_J 중앙값**이며, §8 의 파일럿에서 측정해
`objective.json` 에 박는다. 둘 다 "에너지 항은 makespan 크기의 약 κ 배만큼 가치가 있다"를 뜻한다.

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
| MILP 전역 κ (`AUTO_EFFICIENCY_KAPPA` 기본값) | `kappa` |
| `gen_oracle_mc.jl` `scalar_cost` | 전부 |
| `gen_oracle_dataset.jl` (surrogate 라벨러) | 전부 |
| `dp_solve.py` | 전부 |
| `e1_analyze.py` (`cost_lex_key` 대체) | 전부 |

`audit_action_vocab.py` 와 같은 형식의 감사 스크립트를 붙여, 이 다섯 곳이 같은 파일을 읽는지
기계적으로 검사한다. 리터럴 복붙은 에러 없이 성능으로만 새는 종류의 결함이다.

## 6. 각 자리가 J 를 쓰는 방법

- **MILP** — κ 를 `DeprioritizeAgent` 국소 스코프에서 **전역 기본값으로 승격**한다. 이 한 변경이
  모든 매크로의 재풀이에 에너지 항과 배터리 SoC 가격책정을 되살린다(§2.2). `replan.jl:901-908` 의
  국소 스코프는 제거하고 전역 κ 로 대체한다.
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
| 0 | **MILP 실행가능성 파일럿** — 몇 판을 `:milp` 와 `:milp_w_greedy_warm_start` 로 돌려 판당 시간·메모리를 실측 | 630판 환산이 비현실적이면 warm-start 로, 그것도 아니면 **멈추고 보고**한다. CLAUDE.md 함정 30: MILP 병렬은 OOM + 비교 무효 |
| 1 | 런 레벨에 `total_energy_J` 와 `makespan` 기록 추가 | 지금 둘 다 없다(§2.3) |
| 2 | `objective.json` + 다섯 소비처 + 감사 스크립트 | 감사 통과 |
| 3 | 파일럿에서 `M_ref`/`E_ref` 측정, κ 확정 | `null` 인 채로 J 계산 시 에러 |
| 4 | 630판 스윕 재실행 (`:milp` + 전역 κ) — **신세대** | |
| 5 | surrogate 재라벨 + 재학습 | `test_surrogate_support.py` 재검증 |
| 6 | prefix 결정성 재측정 — **주입점 4개 전부**(`closed ≈ 55/141/204/274`) | 깨지면 DP 표집이 `measured` 경로(K 2배). fork 는 구조적으로 불가(§11-2) |
| 7 | DP 계획(`2026-08-13-dp-oracle.md` Task 2~12) 재개 | |

**단계 0 은 차단성이다.** `:milp` 의 비용은 지금 미측정이며, 이 저장소는 MILP 병렬 실행에서
OOM 과 비교 무효를 겪은 실측 기록이 있다. 며칠~주 단위 잡을 눈감고 던지지 않는다.

## 9. 검증

| 검사 | 무엇을 막나 |
|---|---|
| **순서동치** — `argmin J` 가 `better_ssp` 순위를 재현하는가 | 스칼라화가 사전식 순위를 뒤집는 것. `check_order_equivalence` 재사용 |
| **무력 검사** — 에너지 항이 a\* 를 한 번이라도 바꾸는가 | κ 가 노이즈에 묻혀 "energy 도 최소화"가 명목상 주장이 되는 것. **0 이면 0 이라고 보고한다** |
| **실패 보상 검사** — 미완주 런의 J 가 완주 런보다 낮은 경우가 있는가 | §3.1 위반. 있으면 즉시 실패 |
| **배터리 훅 활성 검사** — 모든 재풀이에서 `LAST_AUTO_EFFICIENCY_W[] > 0` 인가 | §2.2 의 결함이 남아 있는 것. 지금은 Deprioritize 에서만 참 |
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
3. **`M_ref`/`E_ref` 는 파일럿 표본에 의존한다.** 표본이 작으면 κ 의 실효 크기가 흔들린다. 파일럿
   판수와 그때의 분산을 `objective.json` 의 `calibrated_from` 에 기록한다.
4. **`:milp` 재실행 비용이 미측정이다.** 단계 0 이 이를 재며, 비현실적이면 설계가 아니라 **일정**을
   다시 논의한다.
5. **에너지가 지금까지 한 번도 기록된 적이 없다.** 따라서 `E_ref` 의 크기에 대한 사전 지식이 전혀
   없고, κ 초기값 0.01 은 근거 있는 값이 아니라 **자리표시자**다. 단계 3 이 이를 대체한다.
