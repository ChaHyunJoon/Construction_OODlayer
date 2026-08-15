# 1-step deviation 표집 — 결과와 판정

> **계획서**: `docs/superpowers/plans/2026-08-17-dp-one-step-deviation.md`
> **코드 세대**: `c5c4fb63`(deviation 훅) + `28158a49`(표집기) + `aff13715`(표본·표) + `3e492c21`(dp 재스윕)
> **목적함수 세대**: `2026-08-13-global-kappa-precedence` — `objective.json` 무변경.
> **실행일**: 시스템 시각 기준 2026-08-15. 파일명의 날짜는 계획서가 지정한 것을 그대로 쓴다
> (이 레포의 결과 세대 번호는 시스템 시계보다 앞서 있다 — `RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`
> 가 이미 직전 세대다).
> **직전 세대**: `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`. 그 문서 §4-B 가 이 작업의 동기다.

---

## 1. 한 줄 요약

**1차 판정(#1·#3)은 목표 수치에 미달했다. 2차 판정(#5)도 미달했다.**
그러나 이 사이클이 겨냥한 **메커니즘은 작동했고 그것이 실측으로 보인다** — 표집 판 완주율이
16.9% → 86.0% 로 올랐고, dp 레인의 `single_arm`(비교할 팔이 하나뿐이라 argmin 이 성립하지
않는 결정)이 **56.0% → 8.3%** 로 무너졌다. 목표에 미달한 이유는 구현 오류가 아니라
**1-step deviation 의 구성상 한계**이고, 아래 §4 에 그 논증을 적는다.

**DP 열의 부제는 "ceiling" 으로 되돌리지 않는다.** §8.7 gap 이 83.5% 로 0 이 아니다.

---

## 2. 비교표 — DP 열만 바뀌었다

7 case × 30 seed × 4 policy. 출처 `artifacts_4pol/COMPARE.md`.
표는 원자료(`results_4pol/*.jsonl`)에서 재집계해 **28칸 + 4합계 전부 일치**를 확인했다.

| FAILURE CASE | **DP** | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 30/30 · 21.8 s · 311 J | 30/30 · 22.8 s · 338 J |
| Robot breakdown | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 28/30 · 26.1 s · 490 J |
| Keep-out zone | 30/30 · 56.4 s · 492 J | 30/30 · 56.4 s · 492 J | 30/30 · 39.0 s · 456 J | 30/30 · 30.9 s · 362 J |
| Breakdown + battery | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 29/30 · 23.3 s · 402 J | 28/30 · 24.5 s · 447 J |
| Breakdown + zone | 30/30 · 59.8 s · 656 J | 30/30 · 59.8 s · 656 J | 26/30 · 31.3 s · 624 J | 29/30 · 45.6 s · 577 J |
| Battery + zone | 30/30 · 59.8 s · 656 J | 30/30 · 59.8 s · 656 J | 28/30 · 35.1 s · 494 J | 30/30 · 36.8 s · 440 J |
| All three at once | 30/30 · 62.7 s · 733 J | 30/30 · 62.7 s · 733 J | 26/30 · 32.3 s · 595 J | 28/30 · 37.1 s · 537 J |
| **합계** | **207/210** | **207/210** | **198/210** | **203/210** |

> **각주 — 세 실행 레인이 안 바뀐 것이 이번 판의 통제다.** `canonical`·`surrogate`·`dspy` 는
> `value.json` 을 **읽지 않는다**: 그 파일의 유일한 독자가 `tools/monitor/dp_lane.jl:31` 이고,
> 그것을 부르는 `dp_macro` 는 `tools/monitor/policy.jl:841` 의 `if POLICY == "dp"` **안에서만**
> 호출된다(이번 세션에서 재확인). 그래서 dp 샤드 210개만 다시 굴렸고, 세 열의 수치가
> 2026-08-16 과 동일하게 나온 것이 "세계가 안 바뀌었다" 는 기계적 증거다.

⚠️ **DP 열은 전 case 에서 canonical 과 자릿수까지 같다.** 이유는 §3-D 다 — dp 레인 결정의
80.7% 가 canonical 폴백이라 실현 궤적이 canonical 과 같아진다. 이 표에서 DP 열이 좋아 보이는
것은 DP 가 잘해서가 아니다.

---

## 3. 판정표 (계획 §3)

| # | 지표 | 2026-08-16 | 이번 | 목표 | 판정 |
|---|---|---|---|---|---|
| 1 | 표집 판 완주율 | 16.9% | **86.0%** (505/587) | ≥ 90% | **미달** |
| 2 | `V` 중앙값 | 4743.6 | **2483.7** | 20 ~ 200 | **미달** |
| 3 | 단일팔 칸 | 27 / 49 | **23 / 48** | ≤ 5 | **미달** |
| 4 | dp 레인 표 조회 성공률 | 7.7% | **19.3%** | ≥ 50% | **미달** |
| 5 | §8.7 gap | 89.3% | **83.5%** | ≤ 20% | **미달** |
| 6 | 분해 충실성 위반 판 | 0 | **0** | 0 (유지) | **PASS** |

### 3-A. #1 표집 판 완주율 — 16.9% → 86.0%

판 587개(588 중 1판이 엔진 크래시) 중 505개 완주. 팔별:

| 팔 | 완주 | 팔 | 완주 |
|---|---|---|---|
| Replace | 84/84 = **100%** | RelocateBuild | 69/84 = 82.1% |
| SwapBattery | 84/84 = **100%** | ForbidZone | 69/84 = 82.1% |
| NOOP | 71/84 = 84.5% | **ReformTeam** | **57/83 = 68.7%** |
| Deprioritize | 71/84 = 84.5% | | |

**목표 90% 를 못 채운 것은 사실상 ReformTeam 한 축이다.** 그 축을 빼면 448/504 = 88.9% 이고,
ReformTeam 축이 90% 였다면 전체가 89.9% 다 — 즉 이 지표는 "ReformTeam 판이 완주하지 못한다"
라는 **별개의 엔진 문제**를 재고 있다. 구세대(16.9%)와 비교하면 목표 미달이라는 사실보다
**5.1배 상승**이 이번 변경의 실제 효과다.

### 3-B. #2 `V` 중앙값 — 4743.6 → 2483.7

| | 값 |
|---|---|
| 최소 | 7.5 |
| Q1 | 1499.6 |
| **중앙** | **2483.7** |
| Q3 | 3357.1 |
| 최대 | 20735.6 |
| `V ≤ 200` 인 칸 | **9 / 66 (14%)** |

절반 가까이 내렸지만 여전히 실패 벌점 규모다. 원인은 잔여 미완주 14% 다 — 미완주 판의
`J ≈ 10000 + 100·(total − closed)` 가 그 판이 지나간 칸의 `V` 를 backward 로 끌어올린다.
**#1 이 90% 를 못 넘긴 것과 #2 가 200 을 못 내려간 것은 같은 원인의 두 얼굴이다.**

### 3-C. #3 단일팔 칸 — 27/49 → 23/48 (수치는 안 움직였다. **분포가 갈렸다**)

| 칸당 팔 수 | 2026-08-16 | 이번 |
|---|---|---|
| 1팔 | 27칸 | **23칸** |
| 2팔 | 4칸 | 0칸 |
| 5팔 | 2칸 | 0칸 |
| 6팔 | 1칸 | 0칸 |
| **7팔** | **15칸** | **25칸** |

**분포가 완전히 이봉이 됐다.** 중간 등급(2·5·6팔)이 전부 사라지고 `1팔 23 / 7팔 25` 만 남았다.
즉 **deviation 이 일어난 칸은 예외 없이 일곱 팔을 전부 본다.** 계획 §1-B 가 원한 것
("일곱 팔이 같은 칸에 착지해서 그 칸에 argmin 이 생긴다")은 **적용되는 곳에서 100% 달성됐다.**

남은 단일팔 23칸은 **전부 꼬리로만 도달하는 칸**이다 — 어떤 판도 그 칸에서 다른 행동을 하지
않았으므로 비교 대상이 존재하지 않는다. 그 한 팔의 정체가 그 증거다:
`Replace 18칸 · ReformTeam 3칸 · NOOP 2칸` — 전부 canonical 이 그 상황에서 고르는 매크로다.

전이 가중으로 보면 단일팔 칸은 **355 / 2258 = 15.7%** 에 불과하다.

deviation 행 447개는 일곱 팔에 **정확히 고르게** 흩어져 있다(64·64·64·64·64·64·63) — 표집
설계가 의도대로 작동했다는 직접 증거다.

### 3-D. #4 dp 레인 표 조회 — 7.7% → 19.3% (**실패의 종류가 바뀌었다**)

| dp 레인 결정 | 2026-08-16 (1502건) | 이번 (1511건) |
|---|---|---|
| `single_arm` | 841 (**56.0%**) | 126 (**8.3%**) |
| `tie_unresolved` | 545 (36.3%) | **1094 (72.4%)** |
| 표 조회 성공 | 116 (7.7%) | **291 (19.3%)** |

**§1-B 가 겨냥한 `single_arm` 은 56.0% → 8.3% 로 무너졌다.** 목표 지표(#4)가 50% 를 못 넘긴
것은 그 실패가 **`tie_unresolved` 로 옮겨갔기** 때문이다.

**그 tie 는 제조된 것이 아니라 참이다.** deviation 칸이 일곱 팔을 전부 보는데, 그중 다수가
그 사건에서 **실제로 아무 일도 하지 않는다**(예: fault 결정에 `ForbidZone` — `run_demo.jl` 의
집행 사슬이 `truth isa CB.ZoneTruth` 가드에 막혀 통과한다). 그러면 `Q` 가 진짜로 같고
`dp_solve._decide` 의 `|q − q_best| ≤ Z·se` 가 동점으로 판정하는 것이 **옳다.**
동점을 가르려면 tie-break 규칙(예: `MACRO_COST` 최소)이 필요하고 그것은 이 계획 밖이다.

### 3-E. #5 §8.7 gap — 89.3% → 83.5%

실행 정책의 실현 cost-to-go 가 DP 의 `V` 보다 **좋은** (칸,정책) 쌍 101 / 121.

| 축 | 2026-08-15 | 2026-08-16 | 이번 |
|---|---|---|---|
| Reform | 100% | 92.3% | **69.2%** |
| Zone | 100% | 100% | **65.2%** |
| Battery | 82.7% | 92.3% | 94.2% |
| Fault | 81.8% | 75.8% | 84.8% |

**Reform 과 Zone 이 크게 내렸고 Battery·Fault 는 올랐다.** 레벨별로는 L0 81.4% · L1 90.0% ·
L2 88.0% 로, 2026-08-16 의 `L0 97.9% · L1 42.1% · L2 100%` 와 견주면 **L0(가장 정밀한 칸)가
97.9% → 81.4% 로 내렸다** — 정밀 칸의 표본이 두꺼워졌다는 뜻이고 이번 변경의 방향과 맞는다.

`V` 가 실제로 천장이었던 칸(넘긴 쌍이 하나도 없는 칸)이 **6칸** 있다.

---

## 4. 왜 목표 수치에 미달했는가 — 하나의 구조적 이유

**1-step deviation 은 구성상 deviation 지점에서만 다팔 관측을 만든다.**

한 판은 결정 `k` 에서만 팔을 갈아쓰고 `k+1` 부터는 canonical 로 굴러간다. 그래서:

- 결정 `k` 가 떨어진 칸 → 일곱 팔이 전부 관측된다 (**25칸, 전부 7팔**)
- 결정 `k` 이후에만 도달하는 칸 → canonical 이 고른 한 팔만 관측된다 (**23칸, 전부 1팔**)

`k` 는 `pick_k(case, seed)` 가 `n_hint = 8`(결정 수 중앙값) 안에서 흩뿌린다. 84개 (case,seed)
조합이 있으므로 deviation 지점도 최대 84곳뿐이고, 그보다 깊은 칸은 원리적으로 꼬리로만 닿는다.

**#3 을 목표(≤5)까지 내리려면 `pick_k` 분포를 바꿔야 하고 그것은 재시뮬레이션이다** — 즉
다음 사이클 거리다. 후보 두 가지:
1. 판당 deviation 을 하나 더 넣는다(판 수는 그대로, 비용 2배 아님 — 다만 "1-step" 의 정의가 바뀐다).
2. `--n-hint` 를 키워 깊은 지점을 더 자주 고른다(이번 사이클에서 CLI 인자로 노출해 뒀다).

#2·#5 는 잔여 미완주 14%(특히 ReformTeam 68.7%)에 묶여 있고, 그건 표집 방식이 아니라
**엔진 쪽 문제**다(§5 참조).

---

## 5. 알려진 구멍 — 이름과 수로 적는다

### 5-A. 계획 Task 1 Step 6 의 결정성 게이트 — **PASS. 축소판으로 가지 않았다**

`DS_DEVIATE_AT=999`(결정 수보다 뒤) 판이 순수 canonical 판과 같은지 직접 쟀다:

```
종단 지표 차이: 없음
energy_J: 144498.09840210786 vs 144498.09840210786
결정 열 동일: True (5 vs 5 결정)
PASS
```

리셋 지점을 옮긴 뒤 **재실행해서도 PASS**. 따라서 `pick_k` 를 `k=1` 로 고정하는 축소판은
쓰지 않았고, 깊이 커버리지를 잃지 않았다.

### 5-B. 엔진 크래시 — 팔별 수

**표집 588판 중 실패 1판, 전부 `ReformTeam`.** 2026-08-16 의 91판(15.5%)에서 급감했다.
deviation 모드에서는 그 팔이 판당 한 번만 집행되므로 `AssertionError: has_edge(...)` 에
도달할 확률이 떨어진다 — 계획 Task 2 Step 6 의 예상이 맞았다.

⚠️ **그러나 `ReformTeam` 축의 완주율은 68.7% 로 여전히 최저다.** 크래시는 줄었지만 그 팔의
판이 완주하지 못하는 현상은 남았고, 이것이 #1·#2 미달의 실질적 원인이다.
**엔진 결함으로 별도 작업에 올려야 한다**(`apply_cmd!(::FormTransportUnit)` / `has_edge` 어서션).

### 5-C. φ̃ 추상화 손실 — 레벨별 gap 이 여전히 갈린다

L0 81.4% · L1 90.0% · L2 88.0%. 2026-08-16(L0 97.9% · L1 42.1% · L2 100%)과 방향이 바뀌었다 —
가장 정밀한 L0 가 크게 내렸다. **격자 재설계는 다음 사이클 거리다.**

### 5-D. 라벨 레인 재현성 결함(4/365) — **이 사이클과 무관하다**

라벨을 건드리지 않았다. `:8090` 서비스도 그대로 뒀다.

### 5-E. `deviate_valid` 와 `enact_applied` 는 서로 다른 것을 잰다 — 혼동 금지

- `deviate_valid` = 그 팔이 `valid_macros(env, truth)` 메뉴 안인가.
  **빈 메뉴 = 제한 없음**이 이 레포의 규약이다(`policy.jl:413`·`:460`). `valid_macros` 는
  `BatteryTruth`·`ZoneTruth` 에만 리스트를 주므로 **fault·reform 결정에서는 언제나 `true`** 다.
  이 값만으로 거르면 아무것도 안 걸러진다.
- `enact_applied` = 집행 사슬이 **실제로 분기를 탔는가**. 이것이 진실원이다.
  `run_demo.jl` 의 사슬에는 최종 `else` 가 없고 두 분기가 `truth isa CB.ZoneTruth` 가드다.

실측(fault 판): `Deprioritize` → `valid=True, applied=True` · `ForbidZone` → `valid=True, applied=False`.
표본에서 `deviate_valid=False` 인 판은 118개였고 **배제 사유로 쓰지 않았다**(정보성으로만 기록).

⚠️ **`enact_applied = true` 는 "효과 지점에 도달했다" 이지 "세계가 바뀌었다" 가 아니다.**
가드 없이 집행하는 네 분기(NOOP·ForbidZone·RelocateBuild·ReformTeam) 중 셋은 본문 안쪽 조건으로
아무것도 안 바꿀 수 있다 — `ForbidZone`/`RelocateBuild` 의 `wb.status == :already_clear`(변위 Δ0),
`ReformTeam` 의 `rec.status == :error` + `wedge.status == :no_wedge`. **선행 결함이고 이번
변경이 만든 것이 아니다.** 귀결: `ReformTeam` 을 문 비-reform 판이 arm 4 로 라벨된 채 NOOP
동작으로 주저앉을 수 있다.

### 5-F. `enact_applied` 에 회귀 가드가 없다

`run_demo.jl` 은 전체 시뮬레이터가 필요한 최상위 스크립트라 단위 테스트가 없다. 이번에는
양방향 실판 증거(fault+`Deprioritize` → true, reform+`Replace` → false)로 확인했지만,
**그 사슬을 리팩터하면 조용히 깨질 수 있다.**

### 5-G. 배제는 꼬리에만 적용된다 — 그 논거

발화한 판은 **전부** 자기 결정 `k` 행을 낸다. 모든 판이 `k` 에서 자기 팔을 강제하므로
그 행은 그 팔로 라벨된 **고유 관측**이고 그 행을 내는 판은 세상에 하나뿐이다.
중복 제거는 꼬리(`decision_index > k`)에만 적용한다 — 무집행 후에는 세계가 안 바뀌어
NOOP 팔 판의 궤적을 되밟기 때문이다.

**이 구분을 처음엔 놓쳤다.** 판을 통째로 배제했더니 전이 2045 · (칸,팔) 130 이었고,
꼬리만 배제하도록 고치니 **2258 · 198** 이 됐다(+213 행, +68 쌍). 재시뮬레이션은 필요 없었다 —
`--keep-work` 로 587판이 보존돼 있어 행→표본 변환만 1.8분 다시 돌렸다.
그 이전 세대 표본은 `dp_oracle/samples_predeviationrow_2026-08-15.jsonl` 로 보존했다.

### 5-H. `objective.json` 이 커밋되지 않은 채 작업 트리에만 있다 — **재현성 구멍**

작업 트리 = `generation: 2026-08-13-global-kappa-precedence`(= CLAUDE.md 가 현행으로 선언한 값).
커밋된 HEAD = `2026-08-13-energy-activation`. `audit_objective.py` 가 `WARN(9-b) 머지 핸드셰이크
필요` 로 잡는다(항목 자체는 9/9 통과, rc=0). 마지막 커밋은 `02c7fd86`(2026-08-13).

**모든 프로세스가 작업 트리를 읽으므로 이번 표집·스윕은 올바른 세대로 도장됐다.** 그러나
**이 커밋들을 깨끗이 체크아웃하면 `objective.json` 이 옛 세대로 돌아가므로 이 결과를 git 만으로
재현할 수 없다.** `run_shard.sh` 의 provenance 도장이 HEAD SHA 라 그 SHA 가 실제 사용된
목적함수를 식별하지 못한다. **이 세션의 작업이 아니라 이전부터 있던 미커밋 변경이라 임의로
커밋하지 않았다 — 별도로 커밋해야 한다.**

### 5-I. 표집 작업 디렉토리는 gitignore 했다

`--keep-work` 산출이 **2.4GB** 라 `.gitignore` 에 `dp_oracle/_sample_work/` 를 넣었다.
표본 자체는 `samples.jsonl` 에 있고 그 디렉토리는 사후 진단용 원자료다.
계획 Task 3 Step 9 의 `git add dp_oracle/` 를 그대로 하면 2.4GB 가 커밋된다.

### 5-J. `.venv` 에 pytest 가 없다 — 계획서와 현실의 불일치

계획 Task 3 Step 9 의 `../.venv/bin/python -m pytest ...` 는 현 환경에서 `ModuleNotFoundError`
로 실패한다. 이번에는 `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest`
로 돌렸다 — 인터프리터는 `.venv/bin/python`(Global Constraint 2 만족)이고 러너만 빌린 것이다.
두 인터프리터 모두 3.12.3 이고 대상 모듈은 stdlib + 레포 모듈만 import 한다.
**비가역 표집 직전에 `pip install` 로 환경을 바꾸지 않았다** — 그 변경 자체가 세대의 교란
변수가 되기 때문이다.

---

## 6. 재현 절차

```bash
cd /home/chahj578/Construction_OODlayer

# 1) 계측 게이트
julia +lts --project=. tools/monitor/test_deviation.jl          # 5+4+7 pass
julia +lts --project=. tools/test_policy_escalation.jl
cd wm4spacecraft_manufacturing
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
    dp_oracle/test_deviation_plan.py dp_oracle/test_cost_decomposition.py -q   # 28 passed
../.venv/bin/python dp_oracle/test_dp_solve.py                  # rc=0
../.venv/bin/python dp_oracle/test_cellkey_parity.py            # rc=0, 13720 상태 칸키 동치

# 2) 표집 (51.6분 / 40워커 / 588판)
export DSPY_URL=http://127.0.0.1:8090
../.venv/bin/python dp_oracle/sample_grid.py --jobs 40 --keep-work \
    --seeds 1,2,3,4,5,6,7,8,9,10,11,12

# 3) 풀이
../.venv/bin/python dp_oracle/dp_solve.py --out dp_oracle/value_L0_nobackoff.json
../.venv/bin/python dp_oracle/dp_solve.py --backoff

# 4) dp 레인만 재스윕 (19분 / K=50 / 샤드 210)
nohup bash run_4pol_parallel.sh --jobs 50 --policies dp \
    --shards-dir results_4pol/shards_dp > /tmp/sweep_dp.log 2>&1 &
bash finish_tables.sh

# 5) gap
../.venv/bin/python dp_oracle/gap_breakdown.py
```

⚠️ `--shards-dir` 를 반드시 준다. `run_shard.sh` 의 provenance 도장이 `(commit, policies)` 쌍이라
같은 OUTDIR 에 다른 정책 목록으로 넣으면 끝나 있는 세 정책 결과를 지우고 다시 돈다.

---

## 7. 보존한 세대

| 파일 | 무엇 |
|---|---|
| `dp_oracle/samples_gen_backward_2026-08-15.jsonl` | backward induction 도입 세대 |
| `dp_oracle/samples_gen_constantarm_2026-08-16.jsonl` | **상수-팔** 표집(이번 변경의 대조군) |
| `dp_oracle/value_gen_constantarm_2026-08-16.json` | 그 세대의 표 |
| `dp_oracle/samples_predeviationrow_2026-08-15.jsonl` | 이번 세대 중 **꼬리-배제 정정 전** 표본 |
| `dp_oracle/value_L0_nobackoff.json` | 계층 백오프 OFF 표(§1 대조용) |

지우지 않는다 — 두 세대를 나란히 놔야 이번 변경이 무엇을 바꿨는지 말할 수 있다.
