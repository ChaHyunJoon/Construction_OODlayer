# SwapBattery 배송 세대 — 결과와 판정

> **계획서**: `docs/superpowers/plans/2026-08-15-swapbattery-courier-resweep.md`
> **코드 세대**: `2b5637c3`(배송 + 고장 피커) + `49cf841f`·`ec8cf495`(사전 게이트) — 샤드 도장은
> 210/210 전부 `commit=ec8cf495`.
> **목적함수 세대**: `2026-08-13-global-kappa-precedence` · `objective_hash 19819377a7f8ebb2`
> — `objective.json` 무변경, 630행 전부 단일 세대 쌍 `{('19819377a7f8ebb2', 1): 630}`.
> **스윕**: 7 case × 30 seed × 3 policy = **630판**, 샤드 210/210 ok · fail 0 · deadline 0,
> 2026-08-15 22:26 → 2026-08-16 00:13.
> **직전 세대**: `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` + 그 세대의 `results_4pol/` 는
> `results_4pol_gen_swapfree_2026-08-15/` 에 보존돼 있다.
> **dp 열은 이 표에 없다** — §9 가 이유와 되살리는 법을 적는다.

---

## 1. 한 줄 요약

`SwapBattery` 가 **공짜가 아니게 됐다.** 예전에는 `swap_battery!` 가 같은 스텝 안에서
`fleet.soc[role] = 1.0` 을 찍고 끝났고, 그래서 그 팔은 시간도 자원도 쓰지 않았다. 이제 가장
가까운 창고의 예비 로봇이 배터리를 들고 현장까지 **주행**하고, 도착한 순간에 비로소 교체가
적용된다. 이 스윕에서 배송은 **277회 발화했고 즉시교체 폴백은 0회**다.

그 대가가 실측으로 보인다. **그러나 그것을 "추론 레인이 canonical 보다 더 움직였다" 로
읽으면 안 된다 — 그 논증에는 직접 반례가 있다(§4-B).** 이 문서가 세우는 논증은
**레인을 고정하고 배송이 발화할 수 있는 횟수만 바꾸는 것**이다:

| policy | case | SwapBattery 집행 | makespan 중앙 구→신 | Δ |
|---|---|---:|---|---:|
| surrogate | `fault` | **0** | 22.98 → 22.79 | **−0.8%** |
| surrogate | `fault_battery` | 33 | 21.62 → 27.31 | **+26.3%** |
| surrogate | `battery` | 74 | 19.60 → 30.36 | **+54.9%** |
| dspy | `fault` | **0** | 22.99 → 22.48 | **−2.2%** |
| dspy | `fault_battery` | 23 | 21.73 → 24.99 | **+15.0%** |
| dspy | `battery` | 50 | 20.76 → 27.52 | **+32.6%** |

같은 레인 · 같은 커밋 · 같은 세대인데 **발화 횟수에 따라 단조로 커진다.** 이것이 헤드라인이다.

🔴 **그리고 이 세대의 두 번째 결과는 음(陰)의 결과다 — surrogate 의 라벨이 낡았다.**
배터리가 낀 4 case 에서 surrogate 가 `SwapBattery` 를 고른 판은 `Replace` 를 고른 판보다
**완주율이 8.3 pp 낮고 makespan 중앙값이 13.8% 크다**(§8). 그런데도 surrogate 는 여전히
그 팔을 더 자주 고른다(165 대 107 = 60.7%). **다음 사이클 1순위 = 배송 동역학이 반영된
라벨 격자 재생성 + 재학습.**

⚠️ **zone 축이 세 레인 모두에서 크게 움직였는데 그 이동은 아직 귀속되지 않았다**(§5).
`_faultable` 로도 배송으로도 설명되지 않고, 이번 사이클은 그것을 가릴 통제를 **돌리지 않았다.**

---

## 2. 무엇이 세대를 갈랐나

### 2-A. 배송 — `SwapBattery` 가 시간과 라인 정지를 쓴다

`src/respec/battery_courier.jl`(신규) + `replace_robot.jl`. `swap_battery!` 는 예전에 **장부
조작만** 했다. 이제:

- 가장 가까운 창고의 예비 로봇이 배터리를 들고 현장까지 주행하고, **도착한 순간**에 교체가
  적용되며, 그 뒤 자기 슬롯으로 돌아가 자동 충전된다.
- 그동안 방전 로봇은 **진짜로 방전 상태**다(그래서 §6-A 의 `n_stalled` 가 처음으로 0 이 아니다).
- 자원 회계는 어휘의 뜻을 지킨다 — 배터리는 무한이고 배송 로봇은 `pop_spare!` 로 소비하지
  않으므로 **창고 재고가 줄지 않는다.** 드는 비용은 **시간과 라인 정지**이지 재고가 아니다.

집행 결과의 상태 문자열이 갈렸다: `:battery_swapped`(즉시 교체) → `:battery_courier_dispatched`
(배송 파견). `replan.jl:646` 이 둘 다 성공으로 세고, `:battery_courier_dispatched` 는 교체가
**나중에** 적용된다는 뜻이다.

### 2-B. 고장 피커 — 창고 예비가 고장 대상에서 빠진다

`src/respec/ood_injection.jl` 의 `_faultable(rid)`(신규 술어) + `_pick_active_robot` 의 세 단
전부에 적용. 예전에는 세 단 어디에도 제외가 없어서 **주차된 창고 예비도 합법적인 고장
대상**이었다(예비도 자기 `RobotGo` 노드를 갖고 `cache.active_set` 에 들어 있다). 실측:
`fault_battery` seed 10 에서 창고 예비 R16 이 고장 대상으로 뽑혀 `failed=R16, spare=R16`,
즉 **자기 자신으로 교체**됐다 — 어떤 정책을 써도 결과가 같은 무의미(vacuous) 사건이다.
`pick_solo_fault_target`/`pick_hotswap_fault_target`(= `safe=true` 경로)은 이미 제외를 갖고
있었고, 데모 기본값인 `safe=false` 경로만 뚫려 있었다.

### 2-C. 구세대 재현

```bash
DEMO_BATTERY_COURIER=0 …    # 배송만 끈다 → 예전의 즉시 교체 경로로 돌아간다
```

`tools/monitor/run_demo.jl:612` 가 그 손잡이를 그렇게 문서화한다(`set_battery_courier!` 의
`enabled` 인자). ⚠️ **이것은 배송만 끈다 — `_faultable` 수정은 되돌아가지 않는다.** 즉 이
플래그로 만든 판은 **구세대와 같지 않다**(§5 가 이것을 문제 삼는다).

---

## 3. 3레인 × 7 case

### 3-A. 현행 세대 (출처 `artifacts_4pol/COMPARE.md`)

각 칸 — 완주/30 · **완주판 평균** build time(sim 초) · 에너지(J/closed)

| # | FAILURE CASE | **CANONICAL** | **SURROGATE** | **LLM (DSPy)** |
|---|---|---|---|---|
| 1 | Battery depletion | **30/30** · 25.0 s · 400 J | 26/30 · 30.4 s · 438 J | 28/30 · 27.8 s · 405 J |
| 2 | Robot breakdown | **30/30** · 25.0 s · 400 J | **30/30** · 25.0 s · 400 J | 29/30 · 24.9 s · 438 J |
| 3 | Keep-out zone | 30/30 · 64.5 s · 535 J | 30/30 · 50.7 s · 529 J | **30/30 · 34.9 s · 406 J** |
| 4 | Breakdown + battery | **30/30** · 25.0 s · 400 J | 28/30 · 28.3 s · 447 J | 30/30 · 27.4 s · **385 J** |
| 5 | Breakdown + zone | **30/30** · 62.4 s · 679 J | 25/30 · 40.1 s · 716 J | 29/30 · 46.1 s · 600 J |
| 6 | Battery + zone | **30/30** · 62.4 s · 679 J | 25/30 · 45.0 s · 623 J | 29/30 · 47.3 s · **538 J** |
| 7 | All three at once | **30/30** · 63.3 s · 748 J | 25/30 · 45.0 s · 708 J | 30/30 · 43.4 s · **542 J** |
| | **합계** | **210/210** | **189/210** | **205/210** |

구세대 합계는 canonical 207 · surrogate 198 · llm 203 이었다. **canonical 이 210/210 으로
올라가고 surrogate 가 198 → 189 로 떨어진 것이 이 표의 큰 그림이다.**

### 3-B. 구세대 대비 Δ — 완주 · makespan 중앙값 · 에너지 중앙값

⚠️ **§3-A 는 평균이고 아래는 중앙값이다.** 두 표의 makespan 을 같은 열로 놓고 빼면 안 된다.
`ms` = `complete==True` 행의 makespan 중앙값, `epc` = `battery.energy_per_closed` 중앙값.

| case | policy | 완주 구→신 | ms 구 | ms 신 | ms Δ% | epc 구 | epc 신 | epc Δ% |
|---|---|---|---|---|---:|---|---|---:|
| battery | canonical | 29/30 → 30/30 | 22.98 | 22.79 | −0.82% | 375.06 | 376.12 | +0.28% |
| battery | surrogate | 30/30 → 26/30 | 19.60 | 30.36 | **+54.91%** | 302.33 | 343.99 | +13.78% |
| battery | dspy | 30/30 → 28/30 | 20.76 | 27.52 | **+32.57%** | 320.34 | 345.65 | +7.90% |
| fault | canonical | 29/30 → 30/30 | 22.98 | 22.79 | −0.82% | 375.06 | 376.12 | +0.28% |
| fault | surrogate | 29/30 → 30/30 | 22.98 | 22.79 | −0.82% | 375.06 | 376.12 | +0.28% |
| fault | dspy | 28/30 → 29/30 | 22.99 | 22.48 | −2.23% | 381.82 | 376.12 | −1.49% |
| fault_battery | canonical | 29/30 → 30/30 | 22.98 | 22.79 | −0.82% | 375.06 | 376.12 | +0.28% |
| fault_battery | surrogate | 29/30 → 28/30 | 21.62 | 27.31 | **+26.30%** | 338.12 | 361.89 | +7.03% |
| fault_battery | dspy | 28/30 → 30/30 | 21.73 | 24.99 | **+15.02%** | 348.42 | 360.92 | +3.59% |
| all | canonical | 30/30 → 30/30 | 59.80 | 65.74 | +9.93% | 733.24 | 780.67 | +6.47% |
| all | surrogate | 26/30 → 25/30 | 23.64 | 35.65 | +50.82% | 393.96 | 472.92 | +20.04% |
| all | dspy | 28/30 → 30/30 | 24.04 | 34.29 | +42.64% | 397.81 | 454.27 | +14.19% |
| zone | canonical | 30/30 → 30/30 | 56.40 | 64.45 | +14.27% | 491.97 | 535.30 | +8.81% |
| zone | surrogate | 30/30 → 30/30 | 27.25 | 36.50 | +33.94% | 417.69 | 481.87 | +15.36% |
| zone | dspy | 30/30 → 30/30 | 21.09 | 30.79 | +46.00% | 317.78 | 388.05 | +22.11% |
| fault_zone | canonical | 30/30 → 30/30 | 56.95 | 64.45 | +13.17% | 634.24 | 680.76 | +7.33% |
| fault_zone | surrogate | 26/30 → 25/30 | 26.20 | 33.30 | +27.10% | 417.29 | 480.25 | +15.09% |
| fault_zone | dspy | 29/30 → 29/30 | 36.27 | 32.95 | −9.17% | 487.13 | 480.81 | −1.30% |
| battery_zone | canonical | 30/30 → 30/30 | 56.95 | 64.45 | +13.17% | 634.24 | 680.76 | +7.33% |
| battery_zone | surrogate | 28/30 → 25/30 | 25.16 | 37.40 | +48.63% | 382.80 | 471.67 | +23.22% |
| battery_zone | dspy | 30/30 → 29/30 | 22.49 | 34.43 | +53.09% | 352.63 | 452.82 | +28.41% |

**굵게 표시한 여섯 칸이 §4 의 논증에 실제로 쓰이는 칸이다.** 나머지는 교란돼 있거나(§4-C)
아직 귀속되지 않았다(§5).

---

## 4. 헤드라인 — 귀속 논증

### 4-A. 레인을 고정하고, 배송이 발화할 수 있는 횟수만 바꾼다

이 스윕의 `SwapBattery` 집행 횟수는 `(policy, case)` 마다 다음과 같다(원자료
`results_4pol/*.jsonl` 의 `decisions[].macro`):

| policy \ case | `battery` | `fault_battery` | `battery_zone` | `all` | `fault` | `zone` | `fault_zone` |
|---|---:|---:|---:|---:|---:|---:|---:|
| surrogate | 74 | 33 | 32 | 26 | **0** | **0** | **0** |
| dspy | 50 | 23 | 24 | 15 | **0** | **0** | **0** |
| canonical | **0** | **0** | **0** | **0** | **0** | **0** | **0** |

배터리 사건이 없는 case 에서는 `SwapBattery` 가 **구성상** 0 이다. 그래서 같은 레인 안에서
`fault`(0회) · `fault_battery`(중간) · `battery`(최다) 를 나란히 놓으면 **레인 · 커밋 · 세대 ·
목적함수가 전부 고정된 채 배송 발화 횟수만 바뀐다.** §1 의 표가 그것이고, 두 레인 모두에서
**단조**다:

- surrogate: 0회 → **−0.8%** · 33회 → **+26.3%** · 74회 → **+54.9%**
- dspy: 0회 → **−2.2%** · 23회 → **+15.0%** · 50회 → **+32.6%**

에너지도 같은 방향으로 단조다(surrogate `+0.28% / +7.03% / +13.78%`,
dspy `−1.49% / +3.59% / +7.90%`).

**이 논증이 증명하지 않는 것:** 배송이 makespan 을 늘린 *양*이 아니다. 발화 횟수는 정책의
선택이라 무작위 배정이 아니고, 발화가 많은 case 는 배터리 사건 자체도 많다. 이 표가 세우는
것은 **"배송이 발화할 수 있는 case 에서만, 발화량과 같은 방향으로 시간이 늘었다"** 는
조건부 대비이지 처치효과의 크기가 아니다.

### 4-B. 🔴 쓰면 안 되는 논증 둘 — 각각 반례가 있다

**(i) "이것은 `_faultable` 수정의 효과다" — 아니다.** `_faultable` 은 고장 **대상 선정**을
바꾼다. zone 축에는 고장 사건 자체가 없다. 아래 (ii) 의 반례가 순수 `zone` case 에서
나온다는 것이 그 반증이다.

**(ii) "canonical 은 평평한데 surrogate/dspy 는 올랐다 = 배송이다" — 아니다. 직접 반례가 있다.**
순수 `zone` case 에서는 **어느 레인도 `SwapBattery` 를 한 번도 집행하지 않는다.** 그 case 의
결정 진실원 히스토그램은 `ZoneTruth 360 / ReformTruth 319` 로 **`BatteryTruth` 가 0건**이고,
집행된 매크로는 `NOOP 193 / ReformTeam 319 / RelocateBuild 167` 로 `SwapBattery` 가 0건이다.
그런데도:

| `zone` case | canonical | surrogate | dspy |
|---|---:|---:|---:|
| makespan 중앙 Δ | +14.27% | **+33.94%** | **+46.00%** |

**배송이 한 번도 발화하지 않은 case 에서 "추론 레인이 canonical 보다 더 움직인다" 가 그대로
재현된다.** 그러므로 그 패턴은 배송의 증거가 될 수 없다 — 레인마다 감수성이 다른 무언가가
zone 축에서 따로 움직이고 있다(§5).

### 4-C. 교란된 case — `battery_zone` 과 `all` 은 배송 크기로 인용하지 않는다

`battery_zone`(surrogate +48.63% / dspy +53.09%) 과 `all`(+50.82% / +42.64%) 은 배터리 축과
zone 축이 **겹쳐 있다.** surrogate 의 배송 없는 zone 대조군 `fault_zone` 이 이미 **+27.10%**
이므로, `battery_zone` 의 +48.63% 중 배송에 귀속 가능한 몫은 **최대 ~21.5 pp** 다.
dspy 쪽은 대조군 자체가 갈린다 — `fault_zone` **−9.17%** 인데 `zone` **+46.00%** 라 한 숫자로
빼낼 수 없다. **두 case 는 교란을 명시한 채로만 보고한다.**

### 4-D. "canonical 은 평평하다" 는 **중앙값만의** 진술이다

canonical 의 −0.82% 는 판이 안 바뀌었다는 뜻이 아니다. 배터리 축 30판 중 **27판이 바뀌었고**
중앙값에서 상쇄됐을 뿐이다:

| seed | 구세대 | 신세대 |
|---|---|---|
| 1 | 35.05 | 24.45 |
| 5 | 45.40 | 32.35 |
| 9 | 22.45 | **31.95** |

방향도 갈린다(s1·s5 는 내리고 s9 는 오른다). **"canonical 은 안 움직였다" 로 요약하면 안 된다.**

⚠️ **그리고 canonical 의 `battery` · `fault` · `fault_battery` 는 판 단위로 완전히 같다 —
30/30 전부**(makespan · closed · status 까지 동일. 구세대에서도 30/30 동일). canonical 은
이 세 주입을 **구분하지 못한다.** 따라서 §3-B 에서 그 세 행이 같은 숫자인 것은 "세 case 가
일치한다" 가 아니라 **같은 30판을 세 번 센 것**이다. 하나의 측정으로 읽어야 한다.

---

## 5. 🔴 귀속되지 않은 축 — zone

세 레인 전부에서 zone 축이 크게 움직였다(canonical +14.27% / +13.17% / +13.17%,
surrogate +33.94% / +27.10% / +48.63%, dspy +46.00% / −9.17% / +53.09%).
**이 이동은 이 문서에서 귀속되지 않는다.**

- **배송이 아니다** — 순수 `zone` case 는 `SwapBattery` 집행이 0건이고 canonical 은 전 case
  에서 0건이다(§4-A·§4-B).
- **`_faultable` 이 아니다** — 그 술어는 고장 **대상 선정**을 바꾸는데, 순수 `zone` case 에는
  고장 사건이 없다.
- **어디서 왔는지 모른다.** 보존된 구세대는 `commit=5dd29dae` 로 도장돼 있고
  `git rev-list --count 5dd29dae..ec8cf495` = **14** 다. 즉 구세대는 **배송만 다른 판이
  아니라 14 커밋 뒤처진 판**이고, 이번 비교는 그 14 커밋 전부를 한 덩어리로 대면시킨다.
- ⚠️ **후보 14개에서 `cf63d760` 은 빼야 한다.** 그 커밋은 작업 트리에만 있던 `objective.json`
  을 이력에 넣은 것이라, 그 **내용은 구세대 스윕 당시 이미 작업 트리에서 살아 있었다** —
  구세대 행이 이미 `objective_hash 19819377a7f8ebb2` 를 달고 있는 것이 그 증거다.
  이것 자체가 **"커밋된 SHA 만으로는 그 런이 실제로 쓴 목적함수를 식별할 수 없다"** 는
  provenance 한계의 한 사례다.

**옳은 통제는 같은 커밋에서 `DEMO_BATTERY_COURIER=0` 으로 630판을 다시 굴리는 것이다**
(`tools/monitor/run_demo.jl:612` 가 그 플래그를 "구세대 즉시 교체 경로로 바이트 동일하게
돌아간다" 로 문서화한다). **이번 사이클은 그것을 돌리지 않았다.** 다음 사이클 후보로
기록한다. ⚠️ 그 통제도 완전하지는 않다 — `DEMO_BATTERY_COURIER=0` 은 배송만 끄고
`_faultable` 은 되돌리지 않으므로, **배송을 가려낼 뿐 나머지 13 커밋은 여전히 섞여 있다.**

---

## 6. 정지(stall) — 서로 다른 두 지표다. 절대 섞지 말 것

### 6-A. `battery_physics.n_stalled > 0` — **7판 신 / 0판 구**

로봇이 기계적으로 멈춰 선 판. 전부 배터리가 낀 case 이고 전부 미완주다.

| case | policy | 판 |
|---|---|---:|
| `battery` | surrogate | 3 |
| `battery` | dspy | 1 |
| `fault_battery` | surrogate | 2 |
| `battery_zone` | surrogate | 1 |
| **합계** | surrogate 6 · dspy 1 | **7** |

- 구세대는 **0판 / 0회**다. `battery_physics` **설정은 두 세대에서 동일**하므로 이것은
  설정 아티팩트가 아니다.
- CLAUDE.md 가 `n_stalled` 를 **정지의 유일한 기계적 증거**라고 적는 이유: 이 레인은
  `run_demo.jl:472` 가 `global_logger` 를 `Logging.Warn` 으로 심어 `battery.jl:297` 의
  `[STALL]`(`@info`)을 통째로 버린다. **"로그에 STALL 이 없다" 를 "정지가 없었다" 로 읽으면
  안 된다.**
- **이것이 "배송이 오는 동안 로봇이 진짜로 방전된 채 서 있다" 는 가장 깨끗한 양(陽)의 증거다.**
  예전에는 방전 상태로 존재하는 프레임이 하나도 없었다.

### 6-B. `status == "stall"`(판 미완주) — **26판 신 / 22판 구**

| 축 | 구 | 신 | Δ |
|---|---:|---:|---:|
| 배터리가 낀 case (`battery`·`fault_battery`·`battery_zone`·`all`) | 13 | 19 | **+6** |
| 배터리가 없는 case (`fault`·`zone`·`fault_zone`) | 9 | 7 | **−2** |
| canonical | 3 | **0** | −3 |
| surrogate | 12 | **21** | +9 |
| dspy | 7 | 5 | −2 |

**★ §6-A 의 7판은 이 26판의 진부분집합이다**(실측 확인). 즉 **19판은 판으로서 정지했지만
기계적으로 멈춰 선 로봇은 없다.** 이것이 두 지표를 갈라 두는 가장 날카로운 문장이다 —
"stall" 이라는 같은 단어가 두 층위를 가리킨다.

미완주 증가는 평평한 잡음이 아니다. **배터리 축에서 늘고(+6) 고장 축에서 줄었다(−2).**
고장 축의 *감소*는 `_faultable` 수정으로 설명하는 것이 타당하다 — 창고 예비를 자기 자신으로
교체하던 무의미한 고장이 사라졌으므로 그 판들이 더 잘 끝난다. **`_faultable` 을 설명으로
쓰는 것이 정당한 자리는 여기이고, zone 축이 아니다.**

⚠️ 구세대 원자료 전체(dp 행 포함)의 status 분포는 `{complete 815, stall 25}` 다. 위의 22 는
**3 레인만** 센 값이고 나머지 3판은 dp 레인 것이다(§9 로 제외됐다).

---

## 7. 배송은 실제로 발화했다 — 그리고 그 횟수만으로는 아무것도 증명하지 못한다

```
SwapBattery 집행 (rows.jsonl decisions[].macro) = 277
  case 별: {'battery': 124, 'fault_battery': 56, 'battery_zone': 56, 'all': 41}
  레인 별 (decisions[].enacted): {'surrogate': 165, 'dspy': 112}
배송 dispatched = 277 | 즉시교체 폴백 = 0 | 로그 합계 = 277
교차검증 rows.jsonl == 로그: OK
courier=true 배너 없는 보드: 0
```

- **즉시교체 폴백 0회.** 창고에 예비가 없어서 옛 경로로 떨어진 적이 한 번도 없다 —
  277회 전부 창고 왕복을 거쳤다.
- 교차검증은 샤드 단위로 다시 확인했다: **210 샤드 전부에서 `rows.jsonl` 의 집행 수와 로그의
  `[battery] swap=…` 줄 수가 일치, 불일치 0**. 전체 630판 중 `SwapBattery` 가 한 번이라도
  집행된 판은 **171판**(95 샤드)이다.
- **canonical 의 0 은 구조적이다.** canonical 이 210판에서 집행한 매크로 전체가
  `Replace 561 / ReformTeam 693 / NOOP 279` 이고 `SwapBattery` 는 **0**이다. canonical 은
  그 팔을 고르는 규칙 자체가 없다.

⚠️ **그러나 277 이라는 수 자체는 세대를 가르는 정보를 나르지 않는다.** 구세대는 **같은
210 샤드에서 267회**를 집행했다(`battery 117 · fault_battery 55 · battery_zone 57 · all 38`,
레인 `surrogate 163 / dspy 104 / canonical 0`). 277 대 267 은 거의 같다. **두 세대를 가르는
것은 횟수가 아니라 상태 문자열이다** — 구세대는 같은 `println` 에서
`[battery] swap=battery_swapped` 를 **267번** 찍었고 `battery_courier_dispatched` 는 **0번**
찍었다. 신세대는 정확히 뒤집혀 있다(dispatched 277 / swapped 0). **"배송이 277번 돌았다" 를
세대 증거로 인용하지 말 것 — 증거는 `dispatched/fallback` 의 반전이다.**

---

## 8. surrogate 라벨이 낡았다 (Task 7)

배터리가 실제로 낀 4 case(`battery`·`all`·`fault_battery`·`battery_zone`)의 배터리 결정
(`decisions[].truth` 가 `BatteryTruth` 로 시작하는 것)만 모아, 집행된 매크로별로 그 판의
완주/makespan 을 집계한다.

| policy | 팔 | n | 완주율 | makespan 중앙 |
|---|---|---:|---:|---:|
| **surrogate** | **SwapBattery** | **165** | **84.2%** | **32.9** |
| **surrogate** | **Replace** | **107** | **92.5%** | **28.9** |
| dspy | SwapBattery | 112 | 93.8% | 30.5 |
| dspy | Replace | 166 | 98.2% | 28.4 |
| canonical | Replace | 279 | 100.0% | 29.3 |

**판정: 라벨이 낡았다(stale).** surrogate 에서 `SwapBattery` 는 `Replace` 보다 완주율이
**8.3 pp 낮고** makespan 중앙값이 **4.0(약 13.8%) 크다.** dspy 가 같은 방향의 2차 확증을
준다(−4.4 pp · +2.1 = +7.4%). canonical 은 이 팔을 아예 안 고르므로 비교 기준이 될 수 없다.

`SwapBattery` 는 더 이상 공짜 팔이 아닌데 surrogate 는 여전히 옛 라벨의 빈도로 그것을 고른다
(165 / 272 = **60.7%**, `Replace` 보다 많이). **다음 사이클 1순위 = 배송 동역학 아래에서
라벨 격자를 다시 만들고 surrogate 를 재학습하는 것.**

### 교란 — 이 숫자가 증명하지 않는 것

**판 하나의 완주/makespan 은 그 판의 배터리 결정 하나가 아니라 그 판의 모든 결정을 반영한다.**
이것은 **인과가 아니라 상관**이다. 완화한 것 둘:

1. 모집단을 배터리가 실제로 낀 4 case 로 제한했다.
2. 두 팔의 판당 결정 수가 체계적으로 다른지 확인했다 — **중앙값 5 대 5**(평균 6.19 대 6).
   "SwapBattery 판이 그냥 결정이 더 많아서" 라는 대안 설명이 약해진다.

남은 비대칭: `Replace` 판(n=18)은 **순수 `battery` case 에서 0건**이고 전부 다중 사건
case 에서 나온다. 이 방향의 교란은 오히려 `Replace` 를 **불리하게** 만들므로 판정을 약화시키지
않는다. 그래도 상관은 상관이다 — 이 측정의 목적은 **재학습 여부를 판정할 숫자**를 내는
것이지 메커니즘을 증명하는 것이 아니다.

측정 스크립트: `wm4spacecraft_manufacturing/measure_swap_staleness.py`(커밋 `46fd339e`).

---

## 9. dp 열이 없는 이유 — §범위에서 뺀 것 ①

**`dp_oracle/value.json` 은 구세대 동역학에서 표집됐다.** 그 표는 1-step deviation 세대
(`aff13715`)에서 만들어졌고, 그 표집은 `SwapBattery` 가 공짜이던 세계에서 굴린 판으로
`Q`·`V` 를 채웠다. **그 표로 이번 세대의 dp 레인을 굴려 4열 표에 실으면 두 세대가 한 표에
섞인다.** 그래서 dp 레인은 이번 스윕에서 **아예 돌리지 않았다.**

**어떻게 뺐나.** `results_4pol/shards_dp` 를 구세대 트리
(`results_4pol_gen_swapfree_2026-08-15/shards_dp`)로 함께 옮겼다. `finish_tables.sh:32` 가
그 디렉토리 존재로 dp 병합 여부를 정하므로 **열이 자동으로 `이 레인은 스윕에 없음` 으로
낮춰진다** — 표를 손으로 고치지 않았다. 확인: `results_4pol/*.jsonl` 에 `"policy": "dp"` 행 0줄,
COMPARE 의 7 case 행 전부가 그 문자열을 달고 있다.

🔴 **그런데 §8.7 gap 각주는 세대를 건너 새고 있었다.** dp **열**은 올바르게 비어 있었는데,
각주는 빌드 시점에 **현행 `results_4pol/*.jsonl` 을 `aff13715` 세대의 `value.json` 에 대고
다시 계산**해서 숫자를 하나 찍고 있었다(그 판에서는 `79.7%`). 열이 비어 있는 표에 세대가
섞인 gap 이 붙는 형태다. `build_compare_table.py` 를 고쳐 **dp 레인이 없으면 gap 블록과
DP 격자 커버리지 블록을 억제**한다(커밋 `1bfbcaf8`). 신호는 새로 만들지 않고
`finish_tables.sh` 가 이미 쓰는 `[ -d results_4pol/shards_dp ]` 를 그대로 재사용했다 —
칸 단위 저하와 각주 단위 억제가 다시 어긋나지 못하게.

**되살리는 법.** 배송 동역학 아래에서 표를 다시 만들면 된다:

```bash
cd wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090
../.venv/bin/python dp_oracle/sample_grid.py --jobs 40 --seeds 1,…,12   # 재표집
../.venv/bin/python dp_oracle/dp_solve.py --backoff                     # 재풀이
nohup bash run_4pol_parallel.sh --jobs 50 --policies dp \
      --shards-dir results_4pol/shards_dp > /tmp/sweep_dp.log 2>&1 &    # dp 레인만 재스윕
bash finish_tables.sh
```

계획서 추정 **4~5시간**(표집이 대부분). ⚠️ `--shards-dir` 를 반드시 준다 —
`run_shard.sh` 의 provenance 도장이 `(commit, policies)` 쌍이라 같은 OUTDIR 에 다른 정책
목록으로 넣으면 끝나 있는 세 정책 결과를 지우고 다시 돈다.

---

## 10. 알려진 한계

### 10-A. zone 축 이동이 귀속되지 않았다

§5. 세 레인 모두에서 움직였고 배송으로도 `_faultable` 로도 설명되지 않는다. 옳은 통제
(같은 커밋 · `DEMO_BATTERY_COURIER=0` · 630판)를 **이번 사이클은 돌리지 않았다.**

### 10-B. 구세대는 배송만 다른 통제가 아니다

보존된 구세대는 `5dd29dae` 도장이고 HEAD 와 **14 커밋** 차이다(`cf63d760` 제외 시 13개가
실질 후보). 이 문서의 모든 "구→신" Δ 는 **그 14 커밋 전부의 합**이다. `_faultable` 이
설명하는 자리(§6-B 의 고장 축 미완주 감소)와 배송이 설명하는 자리(§4-A)를 제외한 나머지는
**세대 차이**이지 배송 효과가 아니다.

### 10-C. 런 간 재현성 결함 — §범위에서 뺀 것 ③

`_pick_active_robot`(`ood_injection.jl:856`)이 `env.cache.active_set` 을 순회하는데 그것은
**`Set` 이라 순회 순서가 정의돼 있지 않다.** 같은 시드로 같은 커밋을 다시 돌려도 고장 대상
로봇이 달라질 수 있다. 이 계획은 그것을 **범위에서 뺐다** — 고치면 그 자체가 세대를 가르므로
이번 비교의 교란 변수가 된다. **그러나 이 문서의 Δ 중 일부는 그 잡음일 수 있고, 이 스윕은
반복 측정이 없어 그 몫을 분리하지 못한다.** MEMORY 에 적힌 원칙("시뮬레이션은 시드 고정으로
재현돼야 한다 — 런 간 차이는 잡음이 아니라 버그")이 아직 이 레인에서 지켜지지 않는다.

### 10-D. `n_stalled` 말고는 정지의 증거가 없다

§6-A. `[STALL]` 은 `@info` 라 이 레인의 `Logging.Warn` 로거가 통째로 버린다. 정지의 **시각**
이나 **지속 시간**은 이 스윕의 산출물에서 복원되지 않는다 — 판당 횟수뿐이다.

### 10-E. `objective.json` 의 커밋 이력이 세대를 식별하지 못한다

§5 의 `cf63d760` 사례. 스윕 provenance 도장은 HEAD SHA 인데, 목적함수는 **작업 트리**에서
읽힌다. 그래서 같은 SHA 가 서로 다른 목적함수를 가리킬 수 있다. 이 사이클은 그 사례를
사후에만 알아냈다.

---

## 11. 재현 절차

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090          # :8090 이 떠 있어야 한다

# 1) 사전 게이트 4종 (배송 집행 · 고장 피커 · DSPy · objective_hash)
bash gate_courier_sweep.sh                     # rc=0 = GATES PASS

# 2) 스윕 (210 샤드 / K=16 / 약 1h47m)
nohup bash run_4pol_parallel.sh --jobs 16 --policies canonical,surrogate,dspy \
      --deadline-seconds 28800 > _night/resweep_courier.log 2>&1 &

# 3) 병합 + 표
bash finish_tables.sh                          # -> artifacts_4pol/{FINAL,COMPARE}.md
                                               #    4단계가 세대 단일성을 검사한다

# 4) 배송이 실제로 발화했는지
../.venv/bin/python ../.superpowers/sdd/2026-08-15-swapbattery-courier-resweep/count_courier.py \
      results_4pol                             # dispatched 277 / fallback 0

# 5) 라벨 staleness (§8)
../.venv/bin/python measure_swap_staleness.py

# 6) 구세대 재현 (배송만 끈다 — _faultable 은 되돌아가지 않는다)
DEMO_BATTERY_COURIER=0 bash run_4pol_parallel.sh …
```

⚠️ **3)의 4단계가 "세대가 섞였다" 를 찍으면 멈출 것.** 구세대 샤드가 `results_4pol/shards*`
아래에 남아 있다는 뜻이다. 통과 시 출력은 `세대 쌍: {('19819377a7f8ebb2', 1): 630}` +
`정책: {'canonical': 210, 'surrogate': 210, 'dspy': 210}` 다.

---

## 12. 보존한 세대

| 경로 | 무엇 |
|---|---|
| `results_4pol_gen_swapfree_2026-08-15/` | 이 문서가 대면시키는 구세대 630판(+dp 210판). `GENERATION.md` 가 그 세대의 정의를 적는다 |
| `artifacts_4pol_gen_swapfree_2026-08-15/` | 그 세대의 표·아티팩트 26개. `REPORT.md` 는 **이 트리에만** 남는다(§아래) |

⚠️ **`artifacts_4pol/REPORT.md` 는 이 세대에 재생성되지 않았다.** 그 파일의 유일한 생성자
`build_md_report.py:836` 이 `finish_tables.sh` 파이프라인에 들어 있지 않다. 구세대 사본이
`artifacts_4pol_gen_swapfree_2026-08-15/REPORT.md` 에 보존돼 있으므로 **현행 트리에서는
삭제한다** — 남겨 두면 신세대 표 옆에 구세대 리포트가 붙어 세대가 섞인다.

두 트리 모두 지우지 않는다. 두 세대를 나란히 놔야 이번 변경이 무엇을 바꿨는지, 그리고
**무엇을 아직 못 갈라냈는지**(§5) 말할 수 있다.
