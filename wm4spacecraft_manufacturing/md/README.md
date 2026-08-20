# wm4spacecraft_manufacturing — 단일 문서

*통합 2026-08-18: `md/` 30개를 **이 파일 하나**로 압축했다. 내린 29개는 전부 커밋돼 있고
§10 의 SHA 색인이 파일마다 꺼내는 명령을 갖고 있다 — **잃은 것은 없다.**
이전 통합(2026-08-02 · 2026-08-06 · 2026-08-17)이 흡수한 문서들도 §10 에 같이 있다.*

**절 번호는 고정이다.** `.claude/CLAUDE.md` 와 여러 코드 주석이 이 파일을 **절 번호로** 인용한다
(§1 용어 · §5 데이터 스키마 · §6 완주 · §7 철회된 결론 · §8 함정). 절을 재번호하지 말 것.
새로 붙은 것은 앞의 **§0(현행 세대 결과)** 과 뒤의 **§9(상태·계약·재현) · §10(아카이브 SHA 색인)** 이다.

**읽는 순서**: §0 현행 결과 → §1 용어 → §8 함정목록. 그 다음 필요할 때만 §3·§4·§7.

---

## 0. 현행 세대 결과 — SwapBattery 배송 (2026-08-16)

> **현행 세대 = SwapBattery-courier.** 원문 결과 문서는
> `md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md`(내림 — §10 에서 꺼낸다), 생성 표는
> **`artifacts_4pol/COMPARE.md`**(레포에 살아 있다).
> **코드 세대**: `2b5637c3`(배송 + 고장 피커) + `49cf841f`·`ec8cf495`(사전 게이트).
> 샤드 도장은 210/210 전부 `commit=ec8cf495`.
> **목적함수 세대**: `2026-08-13-global-kappa-precedence` · `objective_hash` **`19819377a7f8ebb2`**
> — `objective.json` 무변경. **갈린 것은 동역학이지 목적함수가 아니다.**
> **스윕**: 7 case × 30 seed × 3 policy = **630판**, 샤드 210/210 ok · fail 0 · deadline 0, 1h47m.

### 0-A. 3레인 × 7 case — **현행 수치**

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

**baseline 은 `canonical` 이다. 검증된 천장(ceiling)은 현재 없다** — 근거는 §0-F.
표준 7 case 정의는 함정 43 을 볼 것(`zonecore` 는 `zone` 과 같은 case 다).

### 0-B. 무엇이 세대를 갈랐나

- **① 배송**(`src/respec/battery_courier.jl` 신규 + `replace_robot.jl`): `swap_battery!` 가 같은
  스텝 안에서 `fleet.soc[role] = 1.0` 을 찍던 **장부 조작**에서, 가장 가까운 창고의 예비 로봇이
  배터리를 들고 현장까지 **주행**하고 **도착 스텝에서만** 교체가 적용되는 물리 배송으로 바뀌었다.
  그래서 **방전 구간이 실재하고, 그동안 그 로봇의 작업 라인이 선다.** 자원 회계는 어휘의 뜻을
  지킨다 — 예비를 `pop_spare!` 로 소비하지 않으므로 창고 재고는 안 줄고, 드는 비용은 **시간과
  라인 정지**다. 상태 문자열이 갈렸다: `:battery_swapped` → `:battery_courier_dispatched`.
- **② 고장 피커**(`src/respec/ood_injection.jl` 의 `_faultable` 신규 술어, `_pick_active_robot`
  세 단 전부에 적용): 주차된 창고 예비가 고장 대상에서 빠진다. 예전엔 `failed=R16, spare=R16`
  처럼 **자기 자신으로 교체**하는 무의미(vacuous) 사건이 났다 — `safe=true` 경로는 이미 제외를
  갖고 있었고 데모 기본값인 `safe=false` 경로만 뚫려 있었다.
- **구세대 재현: `DEMO_BATTERY_COURIER=0`**(`tools/monitor/run_demo.jl:613-616` 의
  `set_battery_courier!`). ⚠️ **배송만 끈다 — `_faultable` 수정은 되돌아가지 않는다.**
  ⚠️ **되돌아가지 않는 것이 하나 더 있다: `src/monitor/monitor.jl:159-162` 의
  `REPLACE_SOC_THRESHOLD` 회복 조건.** 세대 커밋 `2b5637c3` 에 배송과 같이 실렸는데 이 플래그의
  조건문 밖이라 켜진 채 남는다. 즉 이 손잡이가 만드는 "통제" 에는 **배송 · `_faultable` ·
  이 회복 조건 셋이 섞여 있다**(둘이 아니다). 다만 blast radius 는 다르다 — 셋째 변경은
  `_mon_robots`(`monitor_emit!` 의 `robots` 블록, `:488`)만 타므로 **모니터 스트림/보드의
  SoC·mode 표시**에만 영향을 주고 `rows.jsonl` 의 채점 지표에는 안 닿는다. 그래도 보드를 세대
  간에 눈으로 대조할 때는 교란 변수다.

### 0-C. 헤드라인 — 귀속 논증은 레인 간 대비가 아니라 **레인 내부 · case 간 용량-반응**이다

레인 · 커밋 · 세대 · 목적함수를 전부 고정하고 **배송이 발화할 수 있는 횟수만** 바꾼다
(makespan 중앙 구→신):

| policy | case | SwapBattery 집행 | makespan 중앙 구→신 | Δ |
|---|---|---:|---|---:|
| surrogate | `fault` | **0** | 22.98 → 22.79 | **−0.8%** |
| surrogate | `fault_battery` | 33 | 21.62 → 27.31 | **+26.3%** |
| surrogate | `battery` | 74 | 19.60 → 30.36 | **+54.9%** |
| dspy | `fault` | **0** | 22.99 → 22.48 | **−2.2%** |
| dspy | `fault_battery` | 23 | 21.73 → 24.99 | **+15.0%** |
| dspy | `battery` | 50 | 20.76 → 27.52 | **+32.6%** |

같은 레인 · 같은 커밋 · 같은 세대인데 **발화 횟수에 따라 단조로 커진다.** 에너지도 같은 방향으로
단조다(`epc` Δ: surrogate `fault` +0.28% → `fault_battery` +7.03% → `battery` +13.78%).

🔴 **쓰면 안 되는 논증 둘 — 각각 직접 반례가 있다.**

1. **"canonical 은 평평한데 추론 레인이 올랐다" 를 근거로 쓰면 안 된다.** 순수 `zone` case 는
   세 레인 모두 `SwapBattery` 집행이 0회이고 `BatteryTruth` 사건이 **아예 0건**인데도
   surrogate **+33.9%** · dspy **+46.0%** 가 그대로 나온다. **그 패턴은 배송 없이도 난다.**
2. **`battery_zone`(+48.6%/+53.1%) · `all`(+50.8%/+42.6%) 은 zone 축과 겹쳐 교란돼 있다 —
   배송 크기로 인용 금지.** 배송 없는 대조항 `fault_zone` 이 이미 surrogate +27.1% 다.

### 0-D. 🔴 귀속되지 않은 축 — zone

**zone 축 이동은 귀속되지 않았다.** 보존된 구세대는 `commit=5dd29dae` 도장이고 **스윕 도장
(`5dd29dae..ec8cf495`) 기준 14 커밋** 차이라 **배송 단독 대조군이 아니다.**
⚠️ **분모는 앵커에 딸린다** — `5dd29dae..HEAD` 는 **21** 이다(HEAD=`41cf9a26`, 2026-08-16 실측).
예전에 적던 19 는 HEAD 가 `2b5a9457` 이던 시점의 값이라 이제 틀리다. **이 수를 옮겨 적을 때는
앵커를 같이 적을 것.**

`_faultable` 로도 설명되지 않는다 — 그건 고장 **대상 선정**을 바꾸는데 순수 zone 에는 고장
사건이 없다(`_faultable` 이 설명으로 정당한 자리는 고장 축 미완주 **감소**다). 옳은 통제는
**같은 커밋에서 `DEMO_BATTERY_COURIER=0` 으로 630판을 다시 굴리는 것**이고 **이번 사이클은
돌리지 않았다.**

### 0-E. 정지 지표가 둘이다 — 섞으면 틀린다

- **`battery_physics.n_stalled > 0` = 신 7판 / 구 0판** (전부 배터리가 낀 case, 전부 미완주;
  `battery_physics` **설정은 두 세대에서 동일**하므로 설정 아티팩트가 아니다). 이것이 "배송이
  오는 동안 로봇이 진짜로 방전된 채 서 있다" 의 가장 깨끗한 양(陽)의 증거다.
- **판 미완주 `status=="stall"` = 신 26 / 구 22.** 그 7판은 26판의 **진부분집합**이다 —
  19판은 판으로 멈췄지만 기계적으로 멈춰 선 로봇은 없다.
- `n_stalled` 말고는 정지의 증거가 없다(함정 9 계열: `run_demo.jl:472` 가 `global_logger` 를
  `Logging.Warn` 으로 심어 `battery.jl:297` 의 `[STALL]`(`@info`)이 통째로 버려진다).

### 0-F. 배송은 실제로 발화했다 — 그러나 그 수만으로는 아무것도 증명하지 못한다

**dispatched 277 · 즉시교체 폴백 0**(구세대는 같은 210 샤드에서 dispatched 0 · 폴백 267).
레인은 `surrogate 165 / dspy 112 / canonical 0`.

🔴 **277 은 "파견 요청" 수이지 "적용된 교체" 수가 아니다.** 이 수는 `swap_battery!` 가
`:battery_courier_dispatched` 를 돌려준 횟수를 셀 뿐이고, 실제 교체는 배송 로봇이 도착한
순간에만 `battery_courier_step!`(`battery_courier.jl:234-237`)에서 적용된다. **이 수를 인용할
때는 반드시 "파견 요청 277" 으로 적을 것.**
⚠️ **277 이라는 수 자체는 세대를 나르지 않는다** — 구세대 집행도 267 로 거의 같다. 세대를
가르는 것은 `dispatched/fallback` 의 **반전**이다(같은 `println`, `run_demo.jl:379`).

**★ canonical 이 `SwapBattery` 를 한 번도 안 고르는 것은 구조적이다** — 210판에서 낸 결정
**1533개**의 매크로 전체가 `Replace 561 / ReformTeam 693 / NOOP 279` 이고 `SwapBattery` 는
**0회**다(세 레인 합은 4027). 그 귀결이 위험하다: **배송을 태우는 레인은 surrogate·dspy
둘뿐인데, 그 둘이 바로 DSPy 서비스가 죽으면 조용히 canonical 로 내려앉는 레인**이다
(함정 42). 게이트의 `/health` 는 **시작 시점만** 본다 → 스윕마다 `decisions[].enacted` 레인
히스토그램으로 사후 확인할 것(이번 실측: 교차 레인 폴백 0).

**검증된 천장이 없는 이유** — 두 후보가 다 못 쓴다:
- **DP 값표**(`dp_oracle/value.json`)는 구세대 동역학에서 표집됐다(§0-G).
- **Oracle 라벨 격자**는 조합 case 를 다루지 못한다. 격자의 kind 는 `fault 405 · battery 240 ·
  zoneblk 160 · reform 67` 로 **전부 단일 사건**이고 `results_matrix.py:44` 의 `ORACLE_KIND` 에
  조합 키가 없다 → **7 case 중 4개(#4·#5·#6·#7)에 oracle 칸이 아예 없다.** 남은 3개도 천장 행이
  전부 **미측정**이다(`energy_J` 없어 J 채점 불가: battery 18 · fault 22 · zone 2 instance).

**그러므로 §0-A 표는 "천장 대비 몇 %" 가 아니라 "canonical 대비 어떻게 다른가" 로 읽어야 한다.**

### 0-G. dp 열이 이 표에 없는 이유

`dp_oracle/value.json` 이 **구세대 동역학**(1-step deviation 세대, `SwapBattery` 가 공짜이던
세계)에서 표집됐기 때문이다 — 그 표로 dp 레인을 굴려 4열에 실으면 한 표에 두 세대가 섞인다.
**어떻게 뺐나**: `results_4pol/shards_dp` 를 구세대 트리와 함께 옮겼고 `finish_tables.sh:32` 가
그 부재를 보고 열을 `이 레인은 스윕에 없음` 으로 **자동으로 낮춘다**(표를 손으로 고치지 않았다).
**되살리는 법**: 배송 동역학에서 `dp_oracle/sample_grid.py` 재표집 → `dp_solve.py --backoff` →
dp 레인만 재스윕(**4~5시간**, 표집이 대부분).

**★ 발행된 표에서 세대 누수를 둘 잡아 닫았다**(`1bfbcaf8`, `7eddb629`). dp **열**은 올바르게
비어 있었는데 ① §8.7 gap 각주가 **빌드 시점에 새 행을 구세대 `value.json` 에 대고 다시 계산**해
숫자를 하나 찍고 있었고, ② 1차 수정 뒤에도 "이 표의 DP 는 진짜 Bellman backward induction 이다
…" 라는 **주장 블록**이 살아남았다. **살아남은 이유는 그 문장에 숫자가 없어서** 1차 수정의
grep 을 전부 통과했기 때문이다.
**★ 교훈: 세대 누수는 숫자가 없어도 누수다.** 기준은 "숫자가 나갔는가" 가 아니라 **"구세대
파일이 이번 세대 산출물의 참·거짓을 정하는가"** 다.
🔴 **잔존 위험**: 그 `value.json` 의 `objective_hash` 는 **현행값과 같다**(목적함수는 안 갈렸고
갈린 것은 코드 세대다). **해시만 보고 게이팅하는 다른 소비처는 이 맹점을 그대로 공유한다** —
쓸 수 있었던 신호는 `shards_dp` 디렉토리 존재 여부뿐이었다.

### 0-H. ★ surrogate 라벨은 낡았다(stale) — 판정 유지, 근거는 갈아 끼웠다

🔴 **초판의 `−8.3pp`(완주)·`+13.8%`(makespan)를 인용하지 말 것 — 결정 가중 아티팩트다**(§7 에
철회로 올려 뒀다). 판 하나의 결과를 그 판이 그 팔을 고른 **횟수만큼 반복해서** 센 값이고,
판 단위로는 **1.8pp** 다(surrogate 120판 중 **52판이 두 팔을 다 집행한다** —
"≥1 SwapBattery ⇒ SwapBattery 판" 규칙이 그 52판을 통째로 한쪽으로 몰아 Replace 쪽 n 이
18판밖에 안 남는다).

**살아남은 근거는 case 층화 makespan 용량-반응이다** — `SwapBattery` 를 한 번도 집행하지 않는
**같은 시드의 canonical** 과 짝지어 뺀 Δmakespan 중앙:

| 판당 SwapBattery 집행 | Δms 중앙 (surrogate − canonical) | n | dspy | n |
|---|---:|---:|---:|---:|
| **0 회** | **+0.00 s** | 7 | **+0.00 s** | 14 |
| 1 회 | **+3.90 s** | 20 | +3.70 s | 26 |
| 2 회 | **+6.45 s** | 15 | +2.55 s | 15 |
| 3 회 이상 | **+9.13 s** | 12 | +11.95 s | 3 |

**집행 0회 판의 Δ 가 정확히 0.00 인 것이 내부 통제다** — 같은 팔만 고른 판은 궤적이 바이트
동일하다. 그러므로 0 이 아닌 Δ 는 갈린 선택에 귀속된다.

⚠️ **그 사다리는 zone 이 안 낀 두 case(`battery`·`fault_battery`)를 풀링해서 잰 값이다** —
`measure_swap_staleness.py` 는 그 층화까지만 하고 그 아래로는 쪼개지 않는다. **case 별로 또는
판당 총 배터리 결정 수로 더 쪼개면 칸이 n=1~4 로 얇아지고 단조성이 깨진다**(실측: surrogate
`fault_battery` 3회+ **−0.50**(n=1), dspy `fault_battery` 2회 **+2.06**; 결정 수 고정 시
surrogate n_bat=4 → **+3.92/+3.36/+9.13**, dspy n_bat=2 → **−2.54/+6.52**).
🔴 **"쪼개도 유지된다" 를 이 사다리의 강건성 근거로 쓰지 말 것 — 그 분석은 측정된 적이 없고
실제로 재현되지 않는다.** 이 판정은 이미 한 번(−8.3pp) 과대주장으로 재작성됐다.

⚠️ **dspy 의 "복제" 는 makespan 에서만 성립한다** — 판 단위 완주 격차는 **0.0pp** 다.
그런데도 surrogate 는 배터리 결정의 **60.7%(165/272)** 를 그 팔에 준다.
**선택 편향도 판정을 약화시키지 않는다**: surrogate 가 `SwapBattery` 를 부르는 시점의 `soc`
중앙은 **0.10**, `Replace` 는 **0.00** 이다 — **덜** 위태로운 상태에서 불려 나오고도 결과가 나쁘다.

**다음 사이클 1순위 = 배송 동역학 아래에서 라벨 격자를 다시 만들고 surrogate 를 재학습하는 것.**

### 0-I. 알려진 한계 — 고치지 않고 기록한 것

1. **zone 축 이동이 귀속되지 않았다**(§0-D). 옳은 통제를 이번 사이클에 돌리지 않았다.
2. 🔴 **런 간 재현성 결함이 살아 있다** — `_pick_active_robot`(`src/respec/ood_injection.jl:856`)
   이 `env.cache.active_set` 을 순회하는데 그것은 **`Set` 이라 순회 순서가 정의돼 있지 않다.**
   같은 시드·같은 커밋을 다시 굴려도 고장 대상 로봇이 갈릴 수 있다. **범위에서 뺐다**(고치면
   그 자체가 세대를 갈라 이번 비교의 교란 변수가 된다). 이 스윕은 반복 측정이 없어 위 Δ 중
   그 잡음의 몫을 **분리하지 못한다.**
3. **발행된 `decision_acc` 는 아직 구세대 기준으로 채점된다** — `reference_policy.py` 의
   `BASIS["battery"]` 문자열에 `🔴 STALE PREMISE` 표식만 붙였고 **규칙 자체
   (`BATTERY_DEEP_SOC` · `reference_action()`)는 재유도하지 않았다.** 즉 채점 기준이 여전히
   "깊은 SoC 에서는 `SwapBattery` 가 옳다" 이고 그것은 이 세대의 측정과 어긋난다.
4. `measure_swap_staleness.py:177-178` 에 **잠재 `ZeroDivisionError`** — 어떤 레인이 두 팔 중
   하나를 한 번도 안 집행하면 `n=0` 으로 나눈다(surrogate 는 앞의 조기 `sys.exit` 로 막히지만
   **dspy 레인은 안 막힌다**). 현재 데이터로는 발화 안 함.
5. 🔴 **중복 파견이 "성공" 으로 보고되고 교체는 일어나지 않는다**
   (`src/respec/battery_courier.jl:169-171`). 중복 제거 스캔이 `d.target == target` 을
   **phase 무관**하게 맞춘다. 그 로봇의 배송이 이미 `:returning` 이면 두 번째 `SwapBattery` 가
   **그 낡은 배송을 그대로 돌려주고**, `swap_battery!` 는 `:battery_courier_dispatched` 를,
   `tools/monitor/run_demo.jl:379` 는 성공 문자열을 찍는다. 그런데 `battery_courier_step!` 은
   `:outbound` 가지에서만 `_apply_battery_swap!` 을 부르므로(`:234-237`) **교체가 아예 안
   일어난다** — 팔은 성공을 보고하고 로봇은 방전인 채로 남는다.
   🔴 **이 세대의 교차검증은 이것을 원리적으로 못 잡는다**: 발행된 검사("210 샤드 전부
   `rows.jsonl` 집행 수 == 런로그 `[battery] swap=` 줄 수, 불일치 0")는 **파견 요청을 두 번
   세어 맞춰본 것**이라 이 결함에 대해 항진적이다. 적용된 교체를 세는 신호가 산출물에 없다
   (`_apply_battery_swap!` 의 도착 로그는 `@info` 라 `Logging.Warn` 로거가 버린다).
   **도달 가능성은 가정이 아니라 실측이다**(2026-08-16 재계산; 2026-08-17 재검산으로 앵커를
   정정했다 — 원안은 무해한 쪽 값에 걸려 있었다). 연속 `SwapBattery` 결정쌍 **106개**의 간격
   중앙 **8.50 s**(min 2.95, 5 s 미만 **7쌍**). 결함에 더 직접적인 **같은 대상 로봇** 쌍은
   **60개**. 배송의 `:outbound`/`:returning` 각 구간은 D=20 · `v=4.0 m/s`
   (`rvo_interface.jl:119`)에서 **≈5 s** — 처음 ~5 s 가 `:outbound`(재사용돼도 도착 시 정상
   적용돼 무해), 다음 ~5~10 s 가 `:returning`(결함이 실제로 발화하는 대). 60개를 그 밴드로
   나누면 `<5 s 2 · [5,10) 50 · [10,15) 7 · ≥15 s 1` — **50/60 이 발화 창 안에 든다**
   (원안이 앵커로 쓴 "min 4.32 s" 는 무해한 <5 s 쪽 값이었다 — §7 에 철회로 올려 뒀다).
   ⚠️ **50 은 발화 횟수의 상한이지 실측 발화 횟수가 아니다.**
6. 🔴 **다른 창고의 놀고 있는 예비가 Replace 경로에서 안 보인다**
   (`src/respec/ood_injection.jl:425-435`). `pop_spare!`(`:386-396`)는 배송 중인 예비를
   건너뛰도록 courier-aware 로 고쳤는데(`findlast(r -> !is_battery_courier(r), v)`),
   `nearest_pool` 은 여전히 `isempty(SPARE_POOLS[][key])` 만 본다. 그래서 그 독스트링의 약속
   ("반환된 키는 `pop_spare!` 로 바로 꺼낼 수 있다")이 **거짓**이 됐다. 풀당 기본 예비가
   2대뿐이라 가장 가까운 창고의 둘이 배송을 나가면 `nearest_pool` 은 그 창고를 계속 고르고
   `pop_spare!` 가 `nothing` 을 돌려줘 `replan.jl:763-766` 이 `"empty_pool"` 로,
   `replace_robot.jl:1516-1520` 이 `:no_spare` 로 강등된다 — **아직 자유 예비가 남은 다른
   창고를 한 번도 안 보고**. 비대칭이 핵심이다: 배송 쪽 `_nearest_courier_depot`
   (`battery_courier.jl:146-158`)은 **모든 창고를 훑는데** Replace 쪽은 최근접 하나만 본다.
   ⚠️ **커밋된 산출물로는 측정 불가**: 신호가 전부 `@info`/`@warn` 인데 이 레인은
   `verbose=false` + `Logging.Warn` 로거라 210 샤드 로그 전수 그렙에서 `empty_pool`/`no_spare`
   가 **두 세대 모두 0건**이다. **"안 났다" 가 아니라 "못 본다" 다.**

⚠️ **5·6 은 코드를 안 고치고 기록만 했다** — 고치면 코드 세대가 갈려 방금 발행한 630판이
통째로 무효가 된다. **다음 사이클에 재스윕과 묶어서** 고칠 것.

---

## 0-Z. 직전 세대 (2026-08-17) — **발표에 쓰인 표는 이것이다**

> 🔴 **아래 표는 현행이 아니다.** 2026-08-17 의 owner 발표에 쓰인 표이고 그 세대는
> **1-step deviation 표집 세대**(코드 세대 `3e492c21`, 결과 문서
> `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` — 내림, §10)다.
> **현행 수치는 §0-A(210 / 189 / 205)** 다. 이 표를 현재 성능으로 인용하지 말 것.
> 원자료는 `results_4pol_gen_swapfree_2026-08-15/*.jsonl` 에 보존돼 있다.
> **목적함수 세대는 두 세대가 같다**(`objective_hash 19819377a7f8ebb2`) — 갈린 것은 동역학이다.
> 이 절을 지우지 않는 이유: 그 수치가 실제로 **발표됐으므로**, 어느 세대의 것인지 알 수
> 있어야 한다.

각 칸 — 완주/30 · 완주판 평균 build time(sim 초) · 에너지(J/closed)

| # | FAILURE CASE | CANONICAL | SURROGATE | LLM (DSPy) |
|---|---|---|---|---|
| 1 | Battery depletion | 29/30 · 26.0 s · 451 J | **30/30 · 21.8 s · 311 J** | 30/30 · 22.8 s · 338 J |
| 2 | Robot breakdown | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 28/30 · 26.1 s · 490 J |
| 3 | Keep-out zone | 30/30 · 56.4 s · 492 J | 30/30 · 39.0 s · 456 J | **30/30 · 30.9 s · 362 J** |
| 4 | Breakdown + battery | 29/30 · 26.0 s · 451 J | 29/30 · 23.3 s · 402 J | 28/30 · 24.5 s · 447 J |
| 5 | Breakdown + zone | **30/30** · 59.8 s · 656 J | 26/30 · 31.3 s · 624 J | 29/30 · 45.6 s · 577 J |
| 6 | Battery + zone | **30/30** · 59.8 s · 656 J | 28/30 · 35.1 s · 494 J | **30/30 · 36.8 s · 440 J** |
| 7 | All three at once | **30/30** · 62.7 s · 733 J | 26/30 · 32.3 s · 595 J | 28/30 · 37.1 s · 537 J |
| | **합계 (직전 세대)** | **207/210** | **198/210** | **203/210** |

**그 세대의 dp 열은 207/210 이었고, dp 판 210개가 canonical 210개와 완전히 동일했다**
(makespan·closed·complete·매크로 열까지). 표가 확정한 19칸이 **전부 `Replace`** 하나로
붕괴했기 때문이다 — 조회율(7.7% → 19.3%)을 **행동 다양성으로 샀다**
(`artifacts_4pol/FINAL.md` 의 dp battery 매크로 정확도 9%(11/120) → **0%(0/120)**).
**"DP 는 천장이다" 로 되돌리지 말 것**(§8.7 gap 83.5%).

**구세대 → 현행 요약**: 합계 완주 canonical **207 → 210** · surrogate **198 → 189** ·
llm **203 → 205**. 배터리가 낀 case 의 makespan 이 오르고(surrogate `battery` 중앙 19.60 →
30.36), `n_stalled > 0` 판이 **0 → 7** 로 처음 나타났다. zone 축도 세 레인 전부에서 움직였는데
**그 이동은 아직 귀속되지 않았다**(§0-D).

### 0-Z-a. 그 세대가 남긴 살아 있는 진단 (지우지 않는다)

- **★ 결정성 게이트의 강한 판은 n=1 이 아니라 n=84 다.** 보존된 587판을 `(case,seed)` 로 묶으면
  **84그룹 전부에서 일곱 개의 독립 프로세스가 pre-`k` 결정 열을 바이트 동일하게 냈다(갈린 그룹 0).**
- **★ dp 의 `tie_unresolved` 대다수는 `n=1` 자동 동점이다.** tie 칸 24개의 비-최선 동점 슬롯
  122개를 분류하면 **정확히 같은 `Q` 10 · 유한 `se` 안에서 가까움 58 · `n<2` 라 `se=inf` 로
  무조건 동점 54**(최대 격차 **11259**). `dp_solve.py:88-93` 의 `_se()` 가 `n<2` 에서 `inf` 를
  돌려주고 `:246` 이 `not isfinite(se_d)` 로 단락한다 — **표본 하나뿐인 팔은 Q 와 무관하게
  무조건 동점**이다. **그래서 다음 지렛대는 tie-break 규칙이 아니라 (칸,팔)당 표본 깊이**
  (같은 `(case,seed)` 를 여러 `k` 로) 또는 `n=1` 에 유한 `se` 를 주는 정책이다.
- **★ `deviate_valid` 와 `enact_applied` 는 다른 것을 잰다.** `deviate_valid` 는 메뉴 소속인데
  `valid_macros` 가 `BatteryTruth`·`ZoneTruth` 에만 리스트를 주고 **빈 배열 = 제한 없음**이
  규약이라(`policy.jl:413`·`:460`) **fault·reform 에서는 언제나 true** 다. 진실원은
  `enact_applied` 이고, **플래그를 각 분기의 내부 실행 가드 안에서** 세워야 한다.
  ⚠️ `enact_applied=true` 는 "효과 지점에 도달했다" 이지 "세계가 바뀌었다" 가 아니다.
- **★ 충실성 게이트는 출력 앞에서 친다.** 예전에는 `samples.jsonl` 쓰기와 `rmtree(work)`
  **뒤에** `sys.exit` 해서, 위반한 런이 **직전의 정상 표본을 덮어쓰고 진단용 판까지 지운 뒤**
  죽었다. 이제 위반이면 아무것도 쓰지 않고 아무것도 지우지 않는다.
- **★ §8.7 gap 의 원인 문장을 하드코딩하지 않는다.** `sample_grid.gap_cause_note()` 가
  `samples.jsonl` 의 `sampling_mode` 에서 유도하고 `build_compare_table.py`·`fill_results_doc.py`
  가 그것을 쓴다. 리터럴이었을 때 **헤드라인 아티팩트가 자기가 없앤 전제를 계속 주장했다.**
  지금 살아 있는 원인은 ② φ̃ 추상화 손실 · ④ deviation 칸 밖 단일팔.
- ⚠️ **`ReformTeam` 축 완주율 68.7%** 가 표집 판정 미달의 실질적 원인이다(Replace·SwapBattery
  는 100%). 엔진이 `AssertionError: has_edge(...)` 로 죽는다 — **별도 작업으로 올릴 것.**

---
## 1. 용어 — 이 구분이 없으면 아래 전부가 오해된다

| 용어 | 정의 | 구성 | surrogate 훈련 |
|---|---|---|---|
| 교란(disturbance) | 엔진의 사건 채널 | `push_ood!` 봉합선 | — |
| **알려진 고장모드 F** | 사전 열거된 닫힌 어휘 | battery, zoneblk, fault | **포함** |
| **OOD 사건 N** | F 밖 = 훈련분포 외부 | **미정의** | **구성상 배제** |

**battery/zoneblk/fault 는 OOD 가 아니다.** surrogate 훈련에 쓰이므로 정의상 in-distribution 이다.
지금까지 이 셋을 "OOD" 라 불러왔으므로 **엄밀한 의미의 OOD 실험은 아직 한 적이 없다.**
LOKO(한 종류 빼고 학습)는 OOD 의 **대리 실험**이지 OOD 자체가 아니다.

**연구 목표**: 미지의 OOD 가 왔을 때 LLM 이 대응을 만들고, 그 대응이 surrogate 의 **행동집합에 편입**되어
다음부터는 surrogate 가 처리한다 → `PLAN_ACTION_GROWTH.md`(내림 — §10-A)

---

## 2. 아키텍처 — TAMP 안쪽 / MDP 바깥쪽

```
  바깥 루프 = SMDP  (확률적, 정책을 학습)
     상태 φ(s) ─→ [Router] ─→ surrogate | LLM | oracle
                      ↓
                   행동 a = ConstraintSpec 조합
                      ↓
  ────────────────────────────────────────────────
  안쪽 루프 = TAMP  (결정론적, plan 을 만듦)
     respec → MILP 재배정 → RVO2 항법 → 실행
```

**핵심**: MDP 가 TAMP 를 **대체**하는 게 아니라 **위에 얹혀** 있다.
행동은 로봇 제어가 아니라 **TAMP 문제에 제약을 추가하는 것**이고, 전이 1회 = 플래너 1회다.
그래서 라벨 하나에 20~300초가 들고, 그것이 surrogate 가 존재하는 이유 전부다.

**봉합선**: `src/respec/replan.jl:91` `RESPEC_PRODUCER` — 오라클/규칙/surrogate/LLM 이 전부 여기 꽂힌다.

### 상태가 정의된 곳 (3층)

| 층 | 정체 | 위치 |
|---|---|---|
| 물리 | 시뮬레이터 실제 상태 | `PlannerEnv` (`route_planning.jl:108`) |
| TAMP | 하이브리드(심볼릭+연속) | `scene_tree` + `sched`/`cache` |
| **MDP φ** | 위의 **고정폭 요약 40개** | `capture_raw` → `derive_state_descriptors` |

φ 는 상태의 **정의가 아니라 인코더**다. 그래서 T1(충분성 검정)이 필요하다.

### 행동

`spec_dsl.jl` 의 primitive: `ReplaceAgent`(1) `DeprioritizeAgent`(2) `ForbidAgent` `ForbidZone`(3)
`ReformTeam` + `RelocateBuild`(7, 2026-08-03 신설) + `SwapBattery`(8, 2026-08-05 신설).
`RespecProposal.constraints` 는 벡터이므로 **조합 행동은 오늘 당장 실행 가능하며 한 번도 쓰인 적이 없다**
— 남은 확장 축이다(파라미터 축은 §3 STEP 6 에서 사망).

> ⚠ 새 매크로 id 를 추가하면 `ACTION_NAME` / `MACRO_COST` / `features_agnostic.MACRO_COST`
> **세 곳을 같이** 늘려야 한다. 안 그러면 시뮬은 통과하고 **행을 쓰는 순간** `KeyError` 로 죽는다.

---

## 3. 확정된 측정 결과

### E1~E4 (원본은 옛 `RESULTS.md` — 아카이브, §10-C)

> ⚠️ **`RESULTS.md` 는 2026-08-17 에 현행 3레인 × 7 case 결과의 단일 진입점으로 새로 쓰였다가
> 2026-08-18 통합으로 내려갔다** — 그 판의 표는 §0-Z 에 **직전 세대**로 보존돼 있다.
> 아래 E1~E4 는 그보다 더 이전 판의 내용이고, 이 절이 그 요약이다. 원문은 §10-C 의 SHA 로 꺼낸다.

| | |
|---|---|
| E1 결정 subopt_norm | **0 @ 플래너 호출 0회** (100% compute 절감, ~348 s/결정) |
| E1 완주노드 예측 | MAE 13.4 (범위 143~291), **R² = 0.829** |
| E1 상태무관 baseline | subopt_norm 0.281, 95% CI [+0.125, +0.438] |
| E2 | LLM-over-surrogate 가 67% 적은 검증으로 동품질 |
| E3 | frozen 모델은 drift 에서 붕괴, active 재학습은 1스텝 복구 (호출 54%↓) |
| E4 | FULL 이 Pareto front, LLM→solver 대비 45% 적은 호출 |
| 비용 평가 v2 | surrogate 0.10 ms · subopt_norm 0.100 · 완주 100% = LLM+solver(64 s) 대비 **1.9M×** |

**E1 의 정직한 한계**: 그 데이터에서는 OOD 종류가 매크로를 거의 결정해버려 top-1 이 항상 맞고
frontier 가 곡선이 아니라 **계단**이었다. compute 절감은 진짜지만 랭킹 문제는 쉬웠다.
→ 이 한계는 아래 사다리 실험이 뒤집는다.

### 이 과제는 kind-trivial 이 **아니다** (2026-08-04 사다리, `oracle/out/lad_*`, seed 401~404)

같은 kind 안에서 정답이 정반대로 갈리는 데이터를 처음으로 만들었다. 32 instance **전부 결정적(동점 0)**.

```
kind=zoneblk   n=16   {NOOP: 8, RelocateBuild: 8}   H(best|kind) = 1.00 bits  ← 이론상 최대
kind=battery   n=12   {Replace: 8, NOOP: 4}         H(best|kind) = 0.92 bits
kind=fault     n= 4   {Replace: 4}                  H(best|kind) = 0.00 bits  ← fault 는 여전히 kind 로 결정됨
```

`zoneblk`(적치 차단) → RelocateBuild, `zonecore`(root 목표 덮음) → NOOP 인데 **둘 다 컨트롤러에게는
`kind="zoneblk"` 로 보인다**. 즉 종류 이름만 보는 규칙표는 zoneblk 에서 원리적으로 동전던지기보다
나을 수 없다. **상태를 읽는 정책이 필요한 이유가 데이터로 성립했다.**

뜻밖의 것: **harm 은 root 목표를 덮는 데서 오는 게 아니라 적치 공간을 막는 데서 온다.**
core zone 은 완주하고(4/8, 6/8) 정답이 NOOP, staging zone 은 한 번도 완주 못 하고(0/8) RelocateBuild 다.

### STEP 6 — 옵션 제한의 대가는 관측되지 않음

| seed | V^macro | V*(ext) | 최선 확장 arm | 노이즈 바닥 |
|---|---|---|---|---|
| 1 | 3573.57 | 3568.99 | 10 (**≡ macro 1**) | 4.57 |
| 2 | 22.12 | 22.12 | 1 | 0.00 |
| 3 | 3841.41 | 3841.41 | 1 | 1.58 |

평균 gap 0.00 · 노이즈 바닥 2.05 · 유의 seed 0/3. `Replace@{0,5,15}` 구별 불가,
`Deprio×{10,50,200}` 셋 다 NOOP 값으로 붕괴. → **파라미터 축을 열어도 얻을 것이 없다.**
(원시 배정공간은 안 열었으므로 이 gap 은 **하한**.)

### Assimilation C1~C4 (원본 `DESIGN_ASSIMILATION.md` — 내림, §10-A)

| | 명제 | 상태 |
|---|---|---|
| C1 | 처음 보는 종류에서 LLM > surrogate | **조건부 성립** (fault 폴드만) |
| C2 | 아는 종류에서 surrogate 동등품질·10⁴배 저렴 | **성립** |
| C3 | 시스템이 스스로 "처음 보는 것"을 판별 | **미확립** |
| C4 | LLM 처리분을 학습해 다음부터 싸게 | **성립** |

C1 이 조건부라는 게 가장 큰 위험 — 깨지면 라우터는 "더 나쁜 쪽으로 보내는 장치"가 된다.
관련해서 종류 홀드아웃(2026-08-03, n=127)에서는 **가설과 반대 방향**이 나왔다: battery/fault 를
훈련에서 빼도 그 종류에서 오히려 더 잘한다(subopt_norm 0.226/0.215 vs 그 외 0.323). kind-agnostic 설계가
잘 작동한다는 뜻이면서 동시에 **"LLM 을 불러야 하는 구간"의 존재를 이 데이터로는 못 보인다**는 뜻이다.

### 정책 비교의 벽 (2026-08-03, 결정적 n=127)

| 판정 | 근거 |
|---|---|
| **상태는 정보를 담고 있다** | surrogate vs random 39승 17패, 부호검정 **p=0.005** |
| **규칙표는 아직 못 넘었다** | 25승 18패, **p=0.360** (평균 subopt_norm 은 +0.055 우세하나 미확립) |

이 벽은 위 사다리 데이터(H(best|zoneblk)=1.00)가 뚫을 대상이다 — 규칙표가 원리적으로 못 푸는
instance 를 모으는 것이 그 방법이었다.

---

## 4. 확정된 설계 결정

**비용 = 유한벌점 SSP** (`gen_oracle_mc.jl:146` 와 `overnight_mdp.py:35` — **두 곳이 반드시 같아야 함**)

```
complete → makespan
else     → 10000 + 100×unclosed + 1e-3×makespan
```

사전식 순서(완주 ≫ 닫힌 노드 수 ≫ makespan)를 스칼라로 옮긴 것. 완주끼리는 **closed 를 보지 않는다**
(`better_ssp`).

**라벨 = K-rollout MC + CRN.** 같은 rollout k = 같은 hazard seed → 짝지은 비교가 유효.
1-shot 라벨은 NOOP 비용을 **375배 과소평가**한다(실측).

### 지표 용어 — `regret` 을 헤드라인에서 내린다 (2026-08-06 결정)

**옛 문서·아티팩트의 `regret` 은 전부 아래의 `subopt_norm` 이다.** 값은 바뀌지 않았고 이름만 정확해졌다.
구현은 `verify.py` (`subopt_norm` / `excess_cost` / `optimal_action` / `decision_report`).

| 이름 | 정의 | 단위 | 지위 |
|---|---|---|---|
| `subopt_norm` (구 `regret`) | `(V* − V^π) / (V* − V_worst)` | 0~1 | **진단용**. 집계·짝지은 검정에만 |
| `excess_cost` | `V* − V^π` 를 사전식 층별로 분해 | 아래 4줄 | — |
| ┣ `d_feasibility` | 완주 가능했는데 못 고른 결정 | 건 · % | **헤드라인** |
| ┣ `d_closed` | 잃은 노드 | 노드 | **헤드라인** |
| ┣ `d_makespan` | 잃은 시간(둘 다 완주일 때만) | 초 | **헤드라인** |
| ┗ `d_cost` | 최선 대비 더 쓴 개입비용(≈소모 자원) | — | **헤드라인** |
| `optimal_action_rate` | `P(a = a*)`, **동점 제외 분모** | % | **헤드라인** |
| `infeasible_pick_rate` | 구 catastrophic-choice rate | % | **헤드라인** |

**왜 강등인가**: (a) `subopt_norm` 은 단위가 없고 분모 `span` 이 사건마다 달라 같은 0.100 이 사건마다
다른 물리량을 뜻한다. (b) **λ 에 오염돼 있다**(함정 21 이 이미 "λ 를 가로질러 비교 금지" 라고 적고 있다)
— 튜닝 파라미터에 의존하는 값은 헤드라인이 될 수 없다. (c) 논문의 regret 은 보통 bandit 의 **누적
regret** 이고, 여기서 재는 1회 결정의 손해는 **simple regret / suboptimality gap** 이다.

**측정으로 확인된 강등 근거** (CANONICAL `openworld_merged.jsonl` 60 instance, λ=3):

| 정책 | 구 subopt_norm | 적중률 | 틀렸을 때 노드/시간 | 완주 놓침 | 과잉개입 |
|---|---|---|---|---|---|
| always-NOOP | 0.490 | 50.0% | **97.3 노드** / 0.0 s | **40.0%** | −0.50 |
| always-Replace | 0.500 | 50.0% | 0.0 노드 / **0.3 s** | **0.0%** | **+0.50** |

옛 지표로는 두 정책이 사실상 같은 숫자다. 실제로는 **완전히 다른 실패 모드**다 —
하나는 빌드를 못 끝내고, 하나는 스페어를 낭비한다. 정규화가 그 차이를 지우고 있었다.

> `d_cost` 를 따로 세는 이유: SSP 물리비용은 **소모한 스페어를 보지 않는다**. λ 는 그 축을 결정규칙에
> 섞어 넣어 감췄다. 섞지 말고 따로 센다.

**마이그레이션**: `regret` 은 20개 py 파일·JSON 키에 박혀 있으므로 **일괄 개명하지 않는다.**
JSON 은 새 키를 추가하고 `regret` 키를 별칭으로 남기며, `verify.norm_regret` 함수명도 그대로 둔다
(옛 아티팩트를 읽는 코드가 조용히 깨진다). 전문 = `PLAN_LLM_INFERENCE_7H_2026-08-06.md` §0-a (내림 — §10-A).

**개입비용 항은 유지하되, λ 는 학습 목표에서 뺀다** (2026-08-05 결정, 근거
`BATTERY_FAULT_REDESIGN_2026-08-05.md` — 내림, §10-A):

- λ 는 데이터로 **식별 불가**(0.5→30 에서 답이 2.4~3.2% 만 변화). "λ=15 로 튜닝했다"는 **철회**.
- 그러나 λ=0 이면 126 중 **58건(46%)이 완전 동점** → 비용 항 제거도 기각.
- λ≥13 은 측정된 12노드 이득을 지우고, **λ>0 은 makespan 계층을 원천 무효화**한다.
- → `y = closed`(물리)로 학습하고 랭킹에서 비용을 해석적으로 적용(LOO 에서 한 번도 나쁘지 않고 λ=15 에서 우세).
- → 목표 키를 μ-키 `(complete, closed, −(makespan + μ·cost))` 로, **μ=4** (측정된 섭동 바닥 0.775 s 에서 유도).
  단 **선행조건**: 배포 surrogate 가 단일 출력이라 makespan 예측 헤드가 하나 더 필요하다. 그때까지는 λ-키(λ=3).

**battery 사건의 기본 행동 = `SwapBattery`**, `Replace` 는 본체가 못 쓰게 됐을 때만.
두 팔의 완주·closed 는 항상 동일(291)인데 SwapBattery 는 창고 본체를 안 먹고 **후반일수록 더 빠르다**
(f222 에서 24.88 → 19.62 s = 대조군과 동일).

**배포 게이트 G1/G2/G3** — 모델을 바꿀 때마다: G1 기존 F 에서 subopt_norm 이 유의하게 나빠지지 않았는가 /
G2 새 클러스터에서 좋아졌는가 / G3 novelty 교정이 여전히 유효한가. 하나라도 실패면 **롤백**.

**LLM 은 새 DSL kind 를 발명하지 않는다** — 미지 사건에서는 서술자 6개
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]` 를 **추정**하고 하류는 그대로 돈다
(`src/safety/novelty.jl`). 입력 쪽 개방성은 확보돼 있고 **출력 쪽(행동 확장)만 없다**.

**프롬프트에 결정표를 넣지 않는다** (2026-08-05). 규칙을 산문으로 주면 측정되는 것은 추론이 아니라
**프롬프트 준수**다(실측: 서술자가 `harm=0.02` 인데도 지시문을 따라 ForbidZone 을 골랐다).
지금은 원리 한 줄 + 각 행동이 무엇을 해소하는가(어휘 설명)만 준다.

**world 축과 확률성 축은 다르다** (2026-08-05 축 재정의):

| 축 | 값 | 어디서 |
|---|---|---|
| world (공장 도면) | **seed 1 고정** | `DS_SEEDS` / `DEMO_SEED` |
| 확률성 (언제·무엇·얼마나) | 스위프 | 라벨=`DS_FIRE_GRID` 격자 / 평가=`DEMO_OOD_SEED` 무작위 |

`DS_SEEDS` 는 확률적 사건 축이 **아니다** — 시뮬레이터가 rng 를 쓰는 곳은 `full_demo.jl:420` 의
로봇 초기배치 하나뿐이고 그 뒤는 결정론이다. **라벨에서 시점이 격자인 것은 버그가 아니라 요구조건**이다
(반사실 비교이므로 두 팔에서 같은 사건이 같은 시점에 터져야 한다). 무작위 시점의 성능은 라벨이 아니라
**평가**에서 잰다.

---

## 5. 데이터 스키마

`gen_oracle_dataset.jl` 이 `(instance, macro)` 당 한 줄. **원자료만 덤프, 서술자는 파이썬에서 계산**
— 정의를 바꿔도 재시뮬이 아니라 재계산이면 된다.

| 묶음 | 열 |
|---|---|
| 로봇 원자료 | `raw_robot_x/y`, `raw_robot_mode`(IDLE/TRANSIT/CARRY/MANIPULATE), `raw_robot_goal_x/y`, `raw_n_carry\|transit\|manip` |
| 화물 | `raw_cargo_id/x/y/placed`, `target_id`(raw 벡터 조인 키) |
| 에피소드 | `hist_*` 8개 (T2 용) |
| **zone 원시값** (2026-08-05, opt-in) | `zone_blocked · zone_restage_feasible · zone_work_overlap · zone_teams_forming · zone_teams_covered · zone_relocatable · zone_relocate_norm` |
| 파이썬 파생 | `xc_*`(커밋먼트) `xt_*`(사건 당사자) `xg_*`(SoC 분포) `xa_*`(부품 배치) — 총 φ 40개 |

**판정(verdict)은 절대 싣지 않는다.** 그건 정답이므로 오라클·게이트의 것이고, 행에 실으면 정책이
추론이 아니라 답을 베끼게 된다(`test_policy_zone.jl` 이 누출을 검사한다).

zone 원시값이 **기본 꺼짐**인 이유: 열을 넣으면 특징 차원이 바뀌어 이미 export 된 서로게이트·novelty
교정과 호환되지 않는다. 옛 덤프에는 열이 없어 `-1`(=모름) 센티넬로 채워진다.

**요약 행(런 JSONL 한 줄)에서 틀리기 쉬운 이름 셋** — 닫힌 노드 수는 `n_closed` 가 아니라
**`closed`**, 시드는 `seed` 가 아니라 **`ood_seed`**, `geometry`(`depot_mode`·`depot_distance`·
`station_keeping`)는 **2026-08-12 이후 생성 행에만** 있다. 없는 이름으로 뽑으면 에러가 아니라
빈 집계가 나온다.

---

## 6. 완주(completion)에 대해 반드시 알아야 할 것

- **완주 ≠ `closed == total`.** 오라클 완주 시 291/313, 데모 설정에서는 287. 모든 closed 수치는
  **달성 가능치 대비**로 읽어야 한다(예: 데모 NOOP 234 = 82%).
- **무OOD 도 100% 가 아니다** — 30 seed 에서 seed 23 실패, **97% ± 3**. 교착은 OOD 가 만드는 게 아니라
  원래 있다. (n=22 까지는 100% 였다 — 작은 표본의 100% 를 믿지 말 것.)
- **실패는 언제나 루트에서만.** 하위 조립체 7/7 은 어떤 실패 판에서도 done 이고, zone 없는 battery·fault
  판도 똑같이 루트에서 죽는다.
- **복구 장치가 있느냐가 결론을 바꾼다.** 같은 core zone 이 복구 사다리 OFF 하니스에서는 정체하고
  ON 에서는 NOOP 으로 완주했다. **두 하니스의 수치를 섞어 쓰면 안 된다.**
- 완주를 되살린 처방은 `DEMO_REFORM`(무진전 N스텝마다 팀 교착을 **결정 레이어로** 올림) +
  `DEMO_REFORM_MAX`(상한; 없으면 `handle_ood!` 뒤 `stall=0` 리셋 때문에 무한 반복).

---

## 7. 철회된 결론 — 이 목록을 먼저 읽어야 옛 문서를 안 믿는다

| 철회된 주장 | 어디에 있었나 | 진짜 사실 |
|---|---|---|
| mid-build Replace 완주는 **구조적 한계** | 2026-07-14 이전 | 정체성보존 hot-swap enact 로 완주(6/6). |
| "깊은 방전도 후반(≥0.58)엔 함대가 흡수 → NOOP" | `FIRE_TIME_RELABEL` §3-a | **틀림.** `_pick_battery_target` 이 진행도 0.51 부터 100% **주차된 예비**를 쐈다. 새 피커로 재라벨하면 NOOP 은 **6개 발화점 전부에서 미완주**. |
| "λ=15 로 튜닝했다" | `surrogate_hotswap.json` 메타 | λ 는 데이터로 식별 불가. 감도만 보고할 것. |
| `root_covered > 0 → 개입` (커버리지 규칙) | zone STEP 2 | **기하는 맞고 인과가 틀렸다.** 덮였다(coverage) ≠ 막혔다(blockage). |
| `battery_zone` 미완주는 중반 Replace 탓 | zone 부록 B-7/B-9 | **병렬 실행 아티팩트.** 단독 실행하면 3/3 완주. |
| "빈 도메인 → RelocateBuild 로 자동 격상" | zone 초기 설계 | 도메인이 비면 격상이 **도달 불가**(`:none` 조기 반환) → 전역을 직접 골라야 한다. |
| "seed 를 30까지 채운다" / "seed 확장은 불필요(LOSO)" | 양쪽 다 | **축 자체가 틀렸다** — §4 의 world/확률성 축 분리. |
| 옛 오라클 완주율 전반 | 2026-08-04 이전 전부 | **shim 버그로 자가복구가 꺼진 채 생성됐다**(아래). |

**2026-08-04 shim 버그** — `maybe_emit_reform_ood!` 는 `push_ood!` 만 하고 `record_ood_truth!` 를
하지 않는데, `event_context` 가 NL 매칭 실패 시 `last(log)` 를 집어 팀 교착 알람을 직전 사건의 종류로
덮어썼다 → CASCADE 로 NOOP → **자가복구가 한 번도 안 돌았다**(알람 499 → ReformTeam 0).
수정 후 같은 seed 에서 NOOP 팔이 245 미완주 → **291 완주**. `hz_*`·`rb_*`·`openworld` 의 완주율과
그에 의존한 결론은 전부 재생성 대상이다.


**2026-08-16~18 에 추가로 철회된 것** (전부 이 레포에서 실제로 인용됐던 수다):

| 철회된 주장 | 어디에 있었나 | 진짜 사실 |
|---|---|---|
| surrogate 라벨 staleness = **`−8.3pp` 완주 / `+13.8%` makespan** | `RESULTS_SWAPBATTERY_COURIER` 초판 §8 | **결정 가중 아티팩트.** 판 하나의 결과를 그 판이 그 팔을 고른 횟수만큼 반복해서 셌다. 판 단위로는 **−1.8pp**(≥1 규칙) ~ **−3.5pp**(한 팔만 쓴 판). 살아남은 근거는 §0-H 의 **case 층화 시드 짝 makespan 사다리**(0회 +0.00 → 3회 이상 +9.13 s). **판정(라벨 stale)은 유지, 효과 크기만 작아졌다.** |
| "교란이 오히려 그 판정을 **강화**한다" | 〃 초판 §8-C | **재계산하면 중립이다.** case 분포로 가중한 기대 baseline 이 Replace 87.2% vs SwapBattery 86.9% — 차이 0.3pp. |
| "사다리는 더 쪼개도 유지된다" | 구두 · 리뷰 코멘트 | **측정된 적이 없고 재현되지 않는다.** case 별/결정 수별로 쪼개면 칸이 n=1~4 로 얇아지고 단조성이 깨진다(§0-H). |
| dspy 가 완주에서도 surrogate 를 "복제" 한다 | 〃 초판 §8 | **makespan 에서만 성립.** 판 단위 완주 격차는 **0.0pp**. |
| 중복 파견 결함의 도달 가능성 앵커 = **"min 4.32 s"** | 〃 초판 §10-G | **무해한 쪽 값이었다.** 같은 대상 로봇 쌍 60개를 배송 밴드로 나누면 `<5s 2 · [5,10) 50 · [10,15) 7 · ≥15s 1` — **50/60 이 발화 창 안**(§0-I 5). 단 50 은 **상한**이지 실측 발화 횟수가 아니다. |
| zone 축을 가른 커밋 수 = **"19 커밋"** | 〃 초판 §5 | HEAD 가 `2b5a9457` 이던 시점의 값. 스윕 도장 기준은 **14**(`5dd29dae..ec8cf495`), HEAD(`41cf9a26`) 기준은 **21**. **이 수는 앵커를 같이 적어야 한다.** |
| "이 표의 DP 는 진짜 Bellman backward induction 이다" | 발행된 `artifacts_4pol` 주장 블록 | **세대 누수.** dp 열은 구세대 `value.json` 에 근거했다. 숫자가 없어서 1차 수정의 grep 을 통과해 살아남았다 — **세대 누수는 숫자가 없어도 누수다**(§0-G). |
| "DP 열은 천장(ceiling)이다" | 초기 4정책 표 부제 | §8.7 gap 이 **83.5%** 다. 천장이 아닌 것은 **V** 이고, dp **레인**의 실현 결과 자체는 유효한 실행 결과다. |
| "deviation 행 447개가 64×7 로 고르게 흩어졌다 = 설계가 작동했다" | 1-step deviation 세대 §3 | **항진명제.** `pick_k` 가 `arm_id` 를 안 쓰므로 발화는 `(case,seed)` 마다 전부/전무이고 `64 = 84 − 20` 으로 셈이 이미 정해져 있다. 정보를 나르는 숫자는 `63` 하나뿐이다. |
| "`--n-hint` 를 키우면 단일팔 칸이 준다" | 〃 | **방향이 반대다**(실측). 판의 결정 수 중앙이 9 인데 `n_hint=8` 에서 평균 `k` 가 이미 4.7 이고 84그룹 중 20그룹이 미발화다. 옳은 방향은 **같은 `(case,seed)` 를 서로 다른 `k` 로 여러 번** 굴리는 것. |
| 꼬리 dedup 이 되니 "`se` 팽창이 없다" | 〃 §5-G | **그 dedup 은 샌다.** 술어가 `enact_applied` 인데 그건 "세계가 바뀌었다" 가 아니라 "효과 지점에 도달했다" 라, `"real"` 170판 중 **107판**이 다른 발화 판과 바이트 동일한 꼬리를 낸다(1521행 중 **601행**이 여분 사본). **현행 표에 대한 영향은 0칸**이라 재표집은 불필요하고, 잔여는 `n`·`se` 의 과신이다. |
| **아카이브 SHA `4d723935`** 로 2026-08-06 흡수 문서를 꺼낼 수 있다 | 옛 `ARCHIVE.md` §2 | **꺼내지지 않는다.** `4d723935` 는 그 7개를 **지운** 커밋이라 그 트리에 파일이 없다. 올바른 SHA 는 부모 **`7b9ff26e`** 다(§10-C 에서 정정했다). **아카이브 SHA 는 적을 때 반드시 `git show` 로 확인할 것.** |

---

## 8. 함정 목록 — **재현하기 전에 반드시 읽을 것**

과거에 실제로 밟았고, 밟으면 결과가 조용히 틀리는 것들.

### 오라클 / 라벨
1. **RVO 를 끄면 정답이 뒤집힌다.** 싼 world 로 라벨을 만들 수 없다.
2. **control(무사건) 판이 없으면** 그 instance 가 유익한지 알 수 없다.
3. **후보는 연구 대상 사건에 대한 대응만 바꿔야 한다.**
4. **후보 집합은 엔진이 실제로 할 수 있는 것과 일치해야 한다.** 실행 불가능한 팔을 끼우는 것은
   결정을 재는 게 아니라 **동점을 제조**하는 것이다(`zoneblk 36/36 동점`의 원인).
5. **손으로 만든 하니스는 프로덕션 sim 과 갈라진다.** `run_one` 을 재사용할 것.
6. **속도 지표는 "실현된 makespan"** 이어야 한다.
7. **`_first_pending_assignment` 는 "일감 유무"가 아니라 "작업 경계"다.** 빌드가 굴러가면 로봇은 운반
   사슬 안에 있어 이 술어가 중반 이후 거의 전부 실패한다. 이 함정을 저장소에서 **세 번** 밟았다
   (fault 피커 · `_pick_idle_victim` · `_pick_battery_target`). 올바른 판정은
   **"안 닫힌 `FormTransportUnit` 팀의 멤버인가"**.
8. **에피소드 모드에는 대조군이 없다.** `gen_oracle_dataset.jl:1554` 가 `ctrl_*` 를 상수 sentinel 로
   박는다 → 그 덤프의 `admissible` 열은 **구조적으로 무의미**하다. 유해성 판정은 단일사건 모드로.
9. **`@info` 가 안 찍힌 0 은 "안 일어났다"가 아니다.** `DS_LOG` 기본값(warn)에서 오염 카운터가 전부
   0 으로 보인다. 확인하려면 `DS_LOG=info` 로 따로 돌릴 것.
36. **★ 라벨 레인과 평가 레인은 사건뿐 아니라 *복구 손잡이*까지 같아야 한다.** 라벨러는
    `DS_HOTSWAP`·`CARRIER_RESCUE` 가 기본 **꺼짐**인데 평가(`run_demo.jl`)는 **켜짐**이라, 같은 seed ·
    같은 매크로가 반대 결과를 냈다(격자 `Replace` = 미완주 243, 평가 = 완주 291/22.75 s). 규칙이
    "로봇을 대열에서 빼는 팔은 전부 미완주"로 붕괴해 **이기는 팔이 존재할 수 없는 격자**가 된다.
    같은 세션 A/B 로 확인됨. 라벨 레인은 `DS_HOTSWAP=1 CARRIER_RESCUE=1`.
    (`DS_HOTSWAP` 을 빼면 fault 대상 피커가 죽어 발화율이 100% → 23% 로 조용히 샌다.)
37. **`random_restriction_zone!`(`:zone_ds`)은 오라클에 쓰면 안 된다.** 설계상 반지름을 상한
    (2 × robot radius = 0.28)으로 깎아 **아무것도 안 막는** 국소 우회로다 — 실측 `zone_blocked 0`,
    NOOP 과 RelocateBuild 가 바이트 동일. `gen_oracle_dataset.jl:325` 가 스스로 *"inadmissible for
    the oracle"* 이라 적어 뒀는데도 격자가 그걸 쓰고 있었다. 게다가 시드를 안 받아 재현도 안 된다.
    평가와 맞추려면 `place_eval_matched_zone!`(= `run_demo.jl` 의 `inject_blocking_zone!` 절차).
38. **fault 의 `severity` 는 강도 축이 아니라 *표적 선정* 축이다.** 학습셋에서 값이 `{0.0, 1.0}`
    두 점뿐이고, 그 `1.0` 은 "얼마나 심하게 고장났나"가 아니라 **"일을 쥔 로봇을 때렸나(1.0) /
    노는 로봇을 때렸나(0.0)"** 라는 실험자 라벨이다(`fault` vs `faultidle`). featurizer 가 이 값을
    **일부러 안 읽고** `harm = 1.0` 상수를 쓴다 — 배포 경로에는 그 값이 없기 때문이고, 읽게 하면
    평가에서만 좋아 보인다(실측 LOIO regret 0.067 → 0.167). **fault 의 OOD 를 severity 로 정의하려는
    시도는 여기서 먼저 막힌다.** 덧붙여 고장 로봇이 만드는 정적 장애물의 공간 피해는 어느 열에도
    안 들어간다(fault 행의 `zone_overlap = -1.0`).

### φ / 학습
10. **`decision_idx` 를 φ 에 넣지 말 것** — 이력 요약이다. 이거 하나로 "surrogate 가 baseline 을 이긴다"는 결론이 뒤집혔다.
11. **feature 목록을 첫 행에서 뽑지 말 것** — 첫 instance 가 zoneblk 이면 SoC 블록 **전체가 사라진다**(실측 38/66행 상실). 합집합을 쓸 것.
12. **결측을 0.0 으로 채우지 말 것** — `soc=0.0` 은 "방전"이라는 유효한 값이다. `-1.0`(N/A 규약)을 쓸 것.
13. **글롭 오염** — `ep*.jsonl` 은 구 데이터까지 빨아들이고, 없는 열이 0 으로 채워져 **가짜 신호**가 된다.
14. **value-residual 은 drift 신호가 아니다**(CUSUM spurious 남발). **covariate-novelty** 가 맞는 신호.
15. **`len(g)==5` 로 instance 를 거르지 말 것.** `DS_VALID_ONLY` 라벨은 유효 팔이 2~3개뿐이라 5를 영영
    못 채운다 → 새 라벨이 통째로 폐기된다(실측 126 중 60 통과, 그 60 은 전부 옛 덤프).
    `instance_arms_complete(g)` 를 쓸 것. 같은 버그가 `e1_analyze.py`·`dspy_service.py`·
    `export_surrogate.py`·`ladder.py` 네 곳에 있었다.
16. **instance ID 는 심각도를 인코딩하지 않는다.** 여러 rung 폴더를 합쳐 `instance` 로만 그룹핑하면
    세 칸이 한 instance 로 병합돼 사다리가 사라진다(실측: battery 12 → 4, 교차 판정이 뒤집힘).
    출처 폴더를 그룹 키에 포함시킬 것.

### 평가
17. **동점을 빼고 재라.** `argmin` 이 동점을 첫 원소(=NOOP)로 깨서 정답분포가 왜곡된다.
18. **표본이 작으면 판정하지 말 것.** 결정적 instance 5개에서 순위적중 1.00 이 나와 "φ 충분"이 찍힌 적이 있다.
19. **베이스라인 없이 subopt_norm 을 해석하지 말 것.**
20. **MC 노이즈에는 대조군을 둘 것.** 중복 arm(정의상 같은 정책)이 노이즈 바닥을 준다.
21. **subopt_norm 은 λ 를 가로질러 비교하면 안 된다** — `span` 정규화 때문에 λ 가 크면 작아 보인다.
    → 이 함정이 §4 "지표 용어" 교체의 직접적 이유다. 헤드라인은 λ 에 오염되지 않는
    `excess_cost`·`optimal_action_rate` 로 낸다.
22. **피해가 `closed` 가 아니라 `makespan` 에만 있는 사건이 있다.** 구역이 시간을 2.1배로 늘리는데
    closed 는 291 로 동일했다. 채널을 하나만 보면 통째로 안 보인다.
    실측 재확인(2026-08-06): `always-Replace` 의 오답은 **노드 손해 0.0 · 시간 손해 0.1 s** 이고
    실제 대가는 전부 `d_cost`(스페어) 쪽에 있었다. **네 축을 다 찍어야 한다.**
39. **평가 런과 오라클 격자는 사건 *개수* 가 다르다.** `llm_ood_eval.py:494` 의 `--events` 기본값이
    **4** 라 zone case 는 구역을 4개 뿌리는데(closed 58/100/150/184, 매번 새 좌표) 격자는 **1개**다.
    첫 결정의 상태는 같아도 그 뒤 셋이 더 온다 — 즉 **오라클이 더 쉬운 문제를 풀고 있다.**
    ORACLE 의 makespan 을 같은 행의 컨트롤러 열과 나란히 놓으면 안 된다. 맞추려면 `--events 1`.

### 시뮬 설정
23. **배치 경계 58** — 이 빌드는 첫 배치에서 closed 0→58 로 점프한다. `closed∈[10,16]` 을 예약해도
    실제로는 58 에서 발화한다 → early/late 두 축이 같은 시점으로 **붕괴**한다.
24. **너무 늦추면 fault 가 안 터지고 동점률이 95% 로 치솟는다.** 실측 권장구간 **[55,130]**.
25. **동점률은 완주율의 함수다**(완주 26%→동점 53% / 완주 5%→동점 85%, 실측).
26. **MTBF 는 빌드 길이에 맞출 것** (이 하니스 빌드 ≈ 20 시뮬초). 60/45 는 함대 전멸, 500/500 이 적정.
27. **`DS_EP_LO/HI` 는 에피소드 모드에서만 동작한다.** 단일사건 유닛 모드는 이 창을 무시한다.
28. **`DS_NOPROG` 를 유닛 모드 값(30000)에서 에피소드 모드로 복사하지 말 것.** 에피소드 모드는 8000.
    (단, 완주율 0% 자체는 이 캡 탓이 **아니다** — 8000/30000 결과가 바이트 단위로 동일했다.)
29. **`ep_[abg]`(창[8,60])는 τ=0 이 99% 라 순차 데이터가 아니다.** T2/커플링 논의에 쓰지 말 것.

### 운영
30. **★ 이 트윈의 런을 동시에 돌려 비교하지 말 것.** `run_lego_demo` 는 **HiGHS MILP**(멀티스레드 +
    시간제한 탐색)로 스케줄을 푼다 → CPU 경합이 다르면 **다른 스케줄**이 나온다. 실측: 같은 케이스가
    동시 실행에서 INCOMPLETE 255, 단독 실행에서 COMPLETE 277(3/3 재현). "정책 비교"가 "다른 두 세계
    비교"가 된다. 순차 하니스는 안전하다.
31. **병렬 2개 상한** (프로세스당 ~2.5 GB, `DS_STACK=1000000000`). lane 병렬은 16GB 머신에서도 OOM 난다.
32. **스크립트명으로 프로세스를 죽이는 감시기 금지** — 나중에 띄운 같은 스크립트까지 죽인다.
33. **인라인 python 은 `PYTHONIOENCODING=utf-8`**, 분석 진입점은 `encoding="utf-8"` 명시
    (Windows 기본 cp949 로 열려 `UnicodeDecodeError`).
34. **PowerShell `Tee-Object` 로그는 UTF-16LE** — bash `tail`/`grep` 이 안 걸린다.
35. **패치는 heredoc `assert` 말고 Edit 도구로** — 백그라운드에서 assert 실패가 묻힌다.
40. **긴 런의 로그를 `| head` 나 `| grep -m` 으로 파이프하지 말 것.** 파이프가 닫히면 SIGPIPE 로
    Julia 가 죽는다 — 2026-08-12 에 이걸로 오라클 격자를 통째로 날렸다. `> file 2>&1` 로 받고
    나중에 읽는다.
41. **`git stash -u` 를 쓰지 말 것.** `.venv/` 와 `results_4pol/` 이 `.gitignore` 에 없어
    **16,833개 파일이 함께 쓸려 간다**(2026-08-12 실측). 커밋은 경로를 명시해 `git add` 한다.
42. **★ DSPy 서비스가 꺼져 있으면 `dspy` 라는 이름으로 canonical 이 기록된다.** `policy.jl` 이
    **에러 없이** canonical 로 폴백하는데 요약 행의 `policy` 필드는 그대로 `"dspy"` 로 남는다 →
    surrogate/LLM 열이 조용히 canonical 복제본이 되고, 몇 시간 뒤 "LLM 이 canonical 과 성능이
    같다"는 표를 받는다(사실은 **같은 정책을 두 번 잰 것**). 방어: 매 런에 `--dspy-url` 을 명시,
    시작 전 `curl -s 127.0.0.1:8090/health` 와 `echo $OPENAI_API_KEY`, 사후에
    `decisions[].producer` 에 `llm` 이 1개 이상 있는지 확인. **`dspy` 와 `canonical` 의 매크로
    시퀀스가 완전히 같으면 폴백을 의심할 것.**
43. **`zonecore` 는 `zone` 과 다른 case 가 아니다.** `run_demo.jl:433` 이 `DEMO_OOD_STREAM3=1`
    에서 `:zonecore` 를 `:zone` 으로 바꾼다. 둘 다 돌리면 같은 실험을 두 번 한 것이고, case 를
    8개 잰 줄 알지만 7개다. 표준 7 case = `battery, fault, all, fault_battery, fault_zone,
    battery_zone, zone`.

---

## 9. 문서 지도 · 살아 있는 계약 · 재현 · 재개 지점

### 9-A. 문서 지도 — **이제 이 파일 하나다**

2026-08-18 통합으로 `md/` 는 **이 `README.md` 하나**만 남는다. 내린 29개는 §10 의 SHA 로 꺼낸다.

`md/` 밖에서 **살아 있는** 것:

| 경로 | 무엇 |
|---|---|
| `.claude/CLAUDE.md` §★ 결과 세대 | **세대 판정의 진실원.** 현행은 언제나 **맨 위 절 하나뿐**이다 |
| `wm4spacecraft_manufacturing/artifacts_4pol/COMPARE.md` | **현행 세대 비교표 생성본**(§0-A 의 출처) |
| `wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md` | MDP 정식화 |
| `wm4spacecraft_manufacturing/LABELING_MANUAL.md` | 라벨링 절차 |
| `docs/superpowers/specs/` (7개) | 설계 문서 — **안 내렸다**(결정이 아직 유효하다) |
| `docs/superpowers/plans/README.md` | 실행 완료 계획서 14개의 아카이브 색인(같은 형식·SHA) |
| `tools/README.md` · `src/SIMULATION_FLOW.md` · `RUN_GUIDE_KR.md` · `PYTHON_SETUP.md` | 그대로 |

⚠️ **코드 주석·독스트링이 내린 문서를 이름으로 인용한다.** 아래 소비처들이 가리키는 이름은
이제 `md/` 에 없다 — **§10 의 SHA 로 꺼내 읽을 것**(파일명은 바뀌지 않았으므로 grep 은 그대로
맞는다): `e1_analyze.py`·`verify.py`·`ladder.py`·`firegrid_report.py`·`export_surrogate.py`
(→ `EVALUATION.md`) · `policy.jl`·`nl_events.py`(→ `DESIGN_ASSIMILATION.md`) ·
`safety_filter.py`·`features_agnostic.py`·`assimilation_gate.py`·`ood_mdp_shim.jl`
(→ `PLAN_ACTION_GROWTH.md`) · `action_registry.py`·`audit_action_vocab.py`
(→ `PLAN_LLM_INFERENCE_7H_2026-08-06.md`) · `verifier.jl`(→ `RELOCATEBUILD_2026-08-03.md`) ·
`render_demo.jl`·`tools/monitor/README.md`(→ `ZONE_REDESIGN_STEP1_7_2026-08-05.md`) ·
`wm_datasets.py`·`surrogate_data.py`·`test_surrogate_support.py`·`zone_inject.jl`
(→ `RESULTS_LLM7H.md`) · `dp_oracle/sample_grid.py`(→ `RESULTS_DP_BACKWARD_2026-08-15.md`) ·
`fill_results_doc.py`(→ `RESULTS_ROUTER3WAY_2026-08-14.md`) · `dspy_service.py`·`tools/demos.jl`
(→ `RESULTS_SURROGATE_REBUILD_2026-08-14.md`) · `run_step_d_firegrid.sh`
(→ `ORACLE_REBUILD_2026-08-09.md`) · `verify_night.py`(→ `NIGHT_PLAN_2026-08-10.md`) ·
`tools/monitor/README_RENDER_3D.md`(→ `RESULTS_30SEED_D20_2026-08-13.md`).

### 9-B. 세대 판정 계약

- **세대 키는 `objective_hash` 하나가 아니라 쌍이다**: `(objective_hash, energy_objective)`.
  `ENERGY_OBJECTIVE` 는 플래너 손잡이라 `objective.json` 의 스칼라를 하나도 안 바꿔 해시로는
  껐는지 알 수 없는데, 끈 런은 다른 플래너 목적함수가 만든 것이라 세대가 실제로 갈린다.
  세대 딱지를 찍는 산출 레인 3곳: `tools/monitor/run_demo.jl`(`DEMO_SUMMARY`) ·
  `oracle/gen_oracle_mc.jl`(유닛 CSV 17·18열) · `oracle/gen_oracle_dataset.jl`(JSONL 라벨 행).
- **현행 `objective_hash` = `19819377a7f8ebb2`**, `generation` = `2026-08-13-global-kappa-precedence`.
  🔴 **여기서 해시를 올리면 배포 라벨셋 전부와 surrogate 가 한꺼번에 구세대로 재분류된다.**
  규칙: 스칼라가 하나도 안 바뀌어도 **목적함수의 유효 의미**가 바뀌면(플래너 재배선 포함) 올린다.
  **동역학만 바뀌었을 때는 올리지 않는다** — 배송 세대가 그 사례다.
- 🔴 **해시로는 코드 세대를 못 가린다.** 구세대 `dp_oracle/value.json` 의 `objective_hash` 는
  현행과 **같다**. 쓸 수 있었던 유일한 신호는 `results_4pol/shards_dp` 디렉토리 존재 여부였다
  (`build_compare_table.py:197` 과 그 형제 `fill_results_doc.py` 의 `holes_section()` 세 블록 —
  **둘 중 하나만 고치면 안 된다**).
- ⚠️ **커밋된 SHA 만으로는 그 런이 실제로 쓴 목적함수를 식별할 수 없다.** `objective.json` 이
  2026-08-13 이후 한동안 커밋 없이 작업 트리에만 있었다(✅ `cf63d760` 이 `objective.json` +
  `essential_tg_coponents.jl` + 해시 1줄을 함께 이력에 넣어 해소). 그 diff 는 구세대 스윕
  당시 **이미 작업 트리에서 살아 있었으므로**, 그 커밋을 "세대를 가른 14 커밋" 후보에서 뺄 것.

### 9-C. 살아 있는 기계적 계약

| 계약 | 기대값 | 무엇을 지키나 |
|---|---|---|
| `python test_objective.py` | 29/29 | 목적함수 J 의 정의 |
| `python test_surrogate_support.py` | 7/7 (§B 는 12/12) | 배포 surrogate 의 매크로 지원집합 |
| `python audit_action_vocab.py` | exit 0 = 6/6 | 행동 어휘 단일 진실원(`action_registry.json`) |
| `test/greedy_cost_dispatch_equivalence.jl` | PASS | greedy 비용 디스패치 동치(**실제 게이트**) |
| `dp_oracle/test_cost_decomposition.py` | PASS(차단) | `c_prefix + Σc_k + terminal == J_row` |
| `dp_oracle/test_dp_solve.py` · `test_cellkey_parity.py` | PASS | Bellman · Julia↔Python 칸키(13,720 경계 상태) |
| `dp_oracle/test_deviation_plan.py` | 30 | 1-step deviation 표집 · 충실성 게이트 순서 |
| `tools/monitor/test_deviation.jl` | 5+4+7 | deviation 결정성 |
| `tools/monitor/test_narrate.jl` · `test_lane_select.jl` | PASS | 서술 · 레인 선택 |
| `wm4spacecraft_manufacturing/gate_courier_sweep.sh` | **4/4** | 배송 집행 · 고장 피커 · DSPy · `objective_hash` |
| `wm4spacecraft_manufacturing/measure_swap_staleness.py` | — | §0-H 의 측정 스크립트 |
| `python test_ceilings_degrade.py` | PASS | J 를 못 재는 행에서 죽지 않고 **미측정으로 낮춘다** |
| `julia +lts --project=. -e 'using Pkg; Pkg.test()'` | 11 pass / **1 error** | 기대 baseline(Gurobi 라이선스 없음 — 실패 아님) |

**★ 게이트가 닫은 함정**: `gate_courier_sweep.sh` 원안 G2 는 **영원히 실패할 수 없는 검사**였다 —
그렙 대상 `Robot R<n> has broken down` 이 **stdout 에 한 번도 안 나온다**(`monitor.jl:354` 가
메모리 Dict 에만 쌓고 `MONITOR_STREAM` JSONL 로만 나간다). 실측 **stdout 0/90 · 스트림 90/90**.
→ 스트림 파일을 직접 그렙하고 "고장 0건이면 실패" 가드를 넣었다.
**게이트를 짤 때는 음성 대조를 먼저 실측할 것** — 그 문자열이 실제로 쓰인 적이 있는가.

⚠️ **`.venv` 에 pytest 가 없다.** `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest`
로 돌린다(인터프리터는 `.venv` 유지). **pytest 로는 `test_deviation_plan.py` 만 잡힌다(30건).**
`test_cost_decomposition.py` · `test_dp_solve.py` · `test_cellkey_parity.py` 는 `def test_*` 가
없고 모듈 수준 `check()` + `sys.exit(1)` 로 게이팅하므로 pytest 에서 **0건**(`no tests ran`, rc 5)
이다 — **인터프리터로 직접 실행할 것.** 두 파일을 pytest 한 줄에 묶어 `# 28 passed` 를 달면
충실성 게이트가 돈 것처럼 보이지만 안 돈다.

⚠️ **`verify.py` 는 어느 덤프로 돌리는지에 따라 결과가 갈린다** — `graded_hs_n44.jsonl` ·
`n44_plus78.jsonl` 둘 다 **exit 1**(`ObjectiveError: 완주 런인데 energy_J 가 없다`).
**"8/8 PASS" 는 더 이상 어떤 기존 덤프로도 유효하지 않다.** 신세대 덤프에서 기대값은 **6/8**
(S1·S4 FAIL — surrogate 가 아직 `closed − λ·MACRO_COST` 로 학습돼 있는데 채점 기준은 `−J` 다).

### 9-D. 재현

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090          # :8090 이 떠 있어야 한다

# 1) 사전 게이트 4종 (배송 집행 · 고장 피커 · DSPy · objective_hash)
bash gate_courier_sweep.sh                     # rc=0 = GATES PASS

# 2) 스윕 (210 샤드 / K=16 / 약 1h47m)
nohup bash sweep/run_4pol_parallel.sh --jobs 16 --policies canonical,surrogate,dspy \
      --deadline-seconds 28800 > _night/resweep_courier.log 2>&1 &

# 3) 병합 + 표
bash reporting/finish_tables.sh                # -> artifacts_4pol/{FINAL,COMPARE}.md
                                               #    4단계가 세대 단일성을 검사한다

# 4) 배송이 실제로 발화했는지
../.venv/bin/python ../.superpowers/sdd/2026-08-15-swapbattery-courier-resweep/count_courier.py \
      results_4pol                             # dispatched 277 / fallback 0
                                               # (파견 요청 수다 — 적용된 교체 수가 아니다. §0-I 5)

# 5) 라벨 staleness (§0-H)
../.venv/bin/python measure_swap_staleness.py

# 6) 구세대 재현 (배송만 끈다 — _faultable 도, monitor.jl 의 REPLACE_SOC_THRESHOLD 회복
#    조건도 되돌아가지 않는다: 섞인 변경은 셋이다. §0-B)
DEMO_BATTERY_COURIER=0 bash sweep/run_4pol_parallel.sh …
```

⚠️ **3)의 4단계가 "세대가 섞였다" 를 찍으면 멈출 것.** 구세대 샤드가 `results_4pol/shards*`
아래에 남아 있다는 뜻이다. 통과 시 출력은 `세대 쌍: {('19819377a7f8ebb2', 1): 630}` +
`정책: {'canonical': 210, 'surrogate': 210, 'dspy': 210}` 다.

**비교 런은 순차 실행**(함정 30). 병렬이면 HiGHS 가 다른 스케줄을 내 비교가 무효 +
프로세스당 ~2.5GB 라 OOM.

**보존한 세대 트리 (지우지 않는다)**

| 경로 | 무엇 |
|---|---|
| `results_4pol_gen_swapfree_2026-08-15/` | §0-Z 가 대면시키는 구세대 630판(+dp 210판). `GENERATION.md` 가 그 세대의 정의를 적는다 |
| `artifacts_4pol_gen_swapfree_2026-08-15/` | 그 세대의 표·아티팩트. markdown 18개는 `SNAPSHOT.md` 하나로 접었고(실험 실행일 2026-08-15 을 머리에 적는다), case 별 `*.json` 과 `compare.html` 은 그대로 둔다. `REPORT.md` 는 **이 트리에만** 남으며 이제 그 `SNAPSHOT.md` 안에 있다 |
| `results_4pol_gen_energyactivation/` · `results_4pol_oldgen_2026-08-13/` | 목적함수 통일 1차·그 이전 세대 샤드 |

⚠️ **`artifacts_4pol/REPORT.md` 는 현행 세대에 재생성되지 않았다**(유일한 생성자
`build_md_report.py:836` 이 `finish_tables.sh` 파이프라인에 없다). 구세대 사본이 보존돼 있으므로
**현행 트리에서는 삭제한다** — 남겨 두면 신세대 표 옆에 구세대 리포트가 붙어 세대가 섞인다.

### 9-E. 재개 지점 — 열려 있는 큰 항목

1. **다음 사이클 1순위 = 배송 동역학 아래에서 라벨 격자를 다시 만들고 surrogate 를 재학습**(§0-H).
   그 작업이 §0-I 3(기준 정책 재유도)과 dp 표 재표집을 같이 닫는다.
2. **`ReformTeam` 축 완주율 68.7%** — 엔진이 `AssertionError: has_edge(...)` 로 죽는다.
   **별도 작업으로 올릴 것.**
3. **§0-I 의 코드 결함 5·6**(중복 파견 / 다른 창고 예비 미탐색) — **재스윕과 묶어서** 고칠 것.
4. **단계 7(surrogate 를 J 로 재라벨·재학습)은 보류** — 조사 결과는 내린
   `STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md`(§10) 에 있다: 선택지 C 가 유일하게 교락 없다.
   근거는 `battery.jl:486` 의 energy-only 모드가 `enable_battery!` 만 켜고 stall/derate 는
   끄므로 **동역학을 바꾸지 않는다** 는 것이다.
5. **`makespan` 의 `-1.0` 센티넬** (명명된 부채) — `gen_oracle_mc.jl` 의 `append_unit!` 이 한
   `@printf` 안에서 두 규약을 쓴다(`energy_J` 는 빈 필드 → NaN, `makespan` 은 `-1.0` → 유한값).
   오늘 착취 경로는 닫혀 있지만 **CSV 재채점이 들어오는 순간 버그가 되살아난다.**
6. **네 번째 κ 가 `objective.json` 밖에 산다 — 활성화 지점 5곳**: `tools/e2e.jl:685` ·
   `tools/demos.jl:1123`·`:1288`·`:1586`·`:2759` (전부 `ENERGY_W`). `get_objective_expr` 의 auto
   경로는 `w_eff == 0.0` 일 때만 도므로 **그 다섯 레인은 전역 κ 를 영원히 못 본다.** 범위 밖.
7. **스케일 재교정은 측정만 하고 적용하지 않았다**(신세대 `M_ref`=25.8625 · `E_ref`=111127.7).
   **순환이기 때문이다** — 그 둘은 `objective_hash` 의 입력이라 쓰는 순간 방금 만든 630행이
   구세대로 재분류된다. 적용하려면 **재교정 + 재스윕**을 한 묶음으로 결정할 것.

**설계 흐름별 미결** (근거는 §10 의 원문 SHA):

| 흐름 | 상태 | 다음 한 수 |
|---|---|---|
| 구역(zone) 결정 | STEP 1~11 구현·검증 완료 | **인과 규칙이 1/2** — 개입의 파괴력을 규칙에 넣어야 한다(막힘 > 0 은 필요조건이지 충분조건이 아니다). 그래서 `ZONE_CAUSAL_RULE` 은 **계속 opt-in(기본 OFF)** 이다 |
| battery / fault 라벨 | 피커·심각도 사다리 재설계 완료 | 조밀한 발화점 격자 라벨링, μ-키용 makespan 헤드 |
| λ → μ 전환 | 결정 완료 · opt-in 구현 완료 | 배포 선행조건 = **makespan 예측 헤드**(현재 배포 surrogate 는 단일 출력). μ 스칼라를 회귀 목표로 그대로 쓰면 안 된다(LOO 0.148 → 0.350) |
| 라우터 / novelty | battery FAMILIAR PASS(p 0.0116 → 0.321), Julia↔Python 파리티 33/33 | **라우터 에스컬레이션 경로의 사후 효과는 여전히 미측정** |
| 진짜 OOD 실험 | **한 번도 한 적 없다**(§1) | B1 능력상실 — 엔진에 "로봇이 특정 능력만 잃는다" 는 개념 자체가 없다 |
| A0 다중 spec 디스패처 | 막혀 있다 | 서로 다른 종류의 제약을 묶어 내면 지금은 하나만 실행되고 나머지는 조용히 버려진다 |

**데이터 자산 — 무엇을 믿을 수 있나**

| 폴더 | 상태 |
|---|---|
| `oracle/out/lad_*` (seed 401~404) | **수정된 shim.** 1사건 사다리 8칸, 32 instance 전부 결정적. 핵심 주장의 근거 |
| `oracle/out/nom30/` | 무OOD 30 seed (완주 **97%±3**, makespan 21.1±0.3) |
| `oracle/out/battgrid_0805_s1.jsonl` | 새 심각도 사다리 18 instance / 54 row |
| `oracle/out/firegrid_merged.jsonl` | 발화점 재라벨 병합(414행 / 108 instance) |
| `openworld_merged.jsonl` (CANONICAL) | 발표 숫자의 근거 — **건드리지 않는다.** 매크로 7·8 이전 라벨이므로 **성능 근거 아님**, novelty 교정 입력으로만 |
| `oracle/out/n44_plus78.jsonl` | 현행 배포 학습셋(행동 어휘 기준). ⚠️ **목적함수 기준으로는 구세대**(`energy_J` 없어 `verify.py` 하드 스톱) |
| `dp_oracle/boards.jsonl` | 판 단위 완주 기록(판당 한 줄, 168KB, 커밋됨). `_sample_work/` 는 gitignore |
| `oracle/out/hz_k1`, `hz_fb`, `rb_*` | **shim 버그 시기** — 완주율 신뢰 불가, 재생성 대상(급하지 않다) |
| `oracle/out/zgrid_0805/` | zone STEP 6 격자. `admissible` 열은 에피소드 모드라 **구조적으로 무의미**(함정 8) |

---

### 9-F. SMDP 재정식화 태스크 0 — G-S/G2 하드 게이트 (2026-08-19)

**계획**: `.superpowers/sdd/2026-08-19-smdp-l1-state/task-0-brief.md`(재시뮬 없이 기존
588-board 1-step-deviation 표집만으로 semi-Markov 성·순차성을 잰다). **코드**:
`wm4spacecraft_manufacturing/smdp/{boards,gate_gs,gate_g2}.py`. **원자료**:
`dp_oracle/_sample_work/`(588 폴더, gitignore) + `dp_oracle/boards.jsonl`.

🔴 **1차 구현(커밋 `9aa57677`)의 두 통계량이 자신이 잰다고 주장하는 것을 재지 못했다** —
독립 리뷰(`.superpowers/sdd/2026-08-19-smdp-l1-state/task-0-review.md`)가 실측
음성·양성 대조로 반증했고, 컨트롤러가 통계량 교체를 지시했다(수정 커밋은 §9-F 끝 참조).

- **G-S (semi-Markov 검사)**: 브리프의 `block_permutation_p`(그룹 내 순열 + 팔 주효과
  SS)는 그룹 안에서 팔 라벨만 섞어 그룹의 τ 다중집합 자체를 바꾸지 않는다 — 그래서 "팔
  순위가 그룹을 가로질러 일관된 가법 주효과인가"만 볼 수 있고 그룹 **내부**의 τ 산포에는
  원리적으로 눈이 멀어 있다. τ 가 100% 팔로 결정돼도 어느 팔이 느린지 그룹마다 회전하면
  이 통계량은 "외생"이라고 잘못 선언한다(단위검사
  `test_spread_test_detects_rotating_arm_effect_that_old_stat_misses` 가 회귀 락).
  **대체 통계량**: 그룹 내 τ 스프레드 직접 검정(`gate_gs.spread_test`) + 편차 이전
  결정(k-1, k-2)을 경험적 귀무로 삼은 Fisher exact(`gate_gs.fisher_exact_greater`,
  `math.comb` 로 직접 구현·scipy/numpy 의존 없음). 실측: **k-1 스프레드 0/58, k-2 스프레드
  0/48(음성 대조 통과, 하네스 결정성 재확인) · k 에서 스프레드 49/64 · Fisher one-sided
  p = 4.39e-21 · 효과크기 중앙 34.8%(그룹 평균 대비)·최대 14.4s. 판정: PASS — τ 는
  팔에 의존한다(SMDP).**
  ⚠️ 브리프의 `분산비(팔 간/그룹 간) > 1` PASS 조건은 **유효성 기준이 아니다** — 이 블록
  설계(7 case × 서로 다른 seed, 그룹 간 이질성이 큼)에서는 팔 효과가 100% 지배적이어도
  이 비가 구조적으로 1 미만이 난다. `variance_ratio` 는 계속 계산·출력하되 서술 통계량일
  뿐 게이팅에 쓰지 않는다.
  ⚠️ 브리프가 "절단(censored)"이라 부른 17개 관측은 **전부 `complete=True`** —
  절단이 아니라 완전관측 종단(terminal) sojourn 이다. 이 17건이 걸린 9개 그룹을 두 처리
  (포함/제외) 양쪽에서 빼면 **n=55, SS_arm=83.313, p=0.0005 로 완전히 일치**한다(직접
  재확인함) — 원래 두 처리 간 p-value 불일치는 447개 관측 중 이 17개(3.8%)가 만든 것이었다.
- **G2 (coupling 검사)**: 브리프의 자격 필터(`len(valid) < 2` 면 제외)는 `valid == []`
  ('제한 없음'=전체 메뉴, `policy.jl:413`)를 '메뉴 없음'으로 오독해 제외했다. 실측으로
  그렇게 지워지는 308 board(ReformTruth 272 + FaultTruth 36) 안에 **결합이 관측되는 그룹
  13개 전부**가 들어 있었다 — 원안 필터는 결합이 있는 관측 100% 를 분모에서 지운다.
  `coupling_rate`(브리프 원안, 레거시 비교용)와 `coupling_rate_corrected`(수정 필터,
  `valid==[]` 도 자격에 포함) 를 둘 다 계산해 나란히 보고한다. 실측: **브리프 필터
  자격 19·결합 0·비율 0.000 vs 수정 필터 자격 64·결합 13·비율 0.203**. 추가로
  macro@k+1 라벨 동일성보다 강한 개념인 "편차 이후 전체 궤적(suffix)이 팔에 따라
  갈리는가"를 `suffix_divergence_rate` 로 따로 쟀다: **63/64 = 0.984**. 판정(수정 필터
  기준): PASS — 순차 결정 문제 성립. (브리프의 "rate≈0 ⇒ contextual bandit" 결론은
  철회한다 — 0 은 결합의 부재가 아니라 필터가 만든 인공물이었다.)
- **종합**: **G-S PASS, G2 PASS(수정 필터 기준)** — 계획 취소 근거 없음, 태스크 1로
  진행한다. 상세 재현·전체 수치는
  `wm4spacecraft_manufacturing/measurements/gate_{gs,g2}_2026-08-19.txt`(수정판, 2번째
  실측으로 덮어씀) 와 `.superpowers/sdd/2026-08-19-smdp-l1-state/task-0-report.md`
  (1차 구현 + 리뷰 라운드 1 수정 전 과정 기록).
- **아직 안 한 것**: 1차 구현의 브리프 축자 코드(`block_permutation_p`·브리프 필터
  `coupling_rate`)는 레거시 비교용으로 파일에 남아 있다 — 지우지 않았다(§10 스타일:
  "무엇이 왜 틀렸는지"를 코드 밖으로 빼면 다음 사람이 같은 실수를 반복한다).

---

## 10. 아카이브 — 내린 문서와 꺼내는 법

**전부 커밋돼 있으므로 잃은 것은 없다.**

```bash
git show <SHA>:wm4spacecraft_manufacturing/md/<파일명>            # 통째로 보기
git show <SHA>:wm4spacecraft_manufacturing/md/<파일명> > /tmp/x.md
```

⚠️ **SHA 규약: "그 파일이 마지막으로 살아 있던 커밋" 이다** — 지운 커밋이 아니다. 아래 SHA 는
전부 `git log -1 --format=%H -- <path>` 로 조회하고 `git show` 로 실제 해석되는지 확인했다.
(옛 `ARCHIVE.md` 가 지운 커밋을 적어 꺼내지지 않던 건이 하나 있었다 — §10-C 에서 정정했다.)

### 10-A. 2026-08-18 통합에서 내린 것 (29개)

**결과 문서 — 현행 · 직전 세대**

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` | **현행 세대 결과 전문** — 3레인×7case 표, 귀속 논증, 정지 지표 둘, 배송 발화 수, surrogate staleness, 코드 결함 5·6, 재현 절차 | **§0 이 전부 흡수했다.** 원문은 §4-D·§6-B·§8-C 등 세부 유도가 더 길다 | `b9725a30` |
| `RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` | **직전 세대** — 1-step deviation 표집, 판정 6지표, dp 표 행동 다양성 붕괴, 결정성 게이트 n=84 | §0-Z 가 표와 살아 있는 진단을 흡수. 상세 유도(§3-D·§5-A·§5-G)는 원문에만 | `8d3f1180` |
| `RESULTS.md` | 옛 **결과 진입점** — 직전 세대 3레인 표(207/198/203) + case 별 매크로 집행 표 + 조합 4 case 집계 | 진입점 역할이 이 파일로 옮겨왔다. **그 표는 §0-Z 에 직전 세대로 명시해 보존했다** | `8d3f1180` |
| `RESULTS_ACTION_SET_CLOSURE_2026-08-16.md` | 행동집합 폐쇄 세대 — `RELABEL_20260816`(872행/260 instance), support `{0,1,2,7,8}` → `{0,1,2,4,5,6,7,8}`, §4-B 표집 완주율 미개선 | 그 세대는 두 세대 전이다. 살아 있는 함정(`DS_HOTSWAP` · `valid_actions` 문지기 · reform dedup 부재)은 §8·§9 로 옮겼다 | `5960a25b` |
| `COMPARE_ACTIONSET_DELTA_2026-08-16.md` | 그 세대 표의 **독립 재계산 검증** + 전/후 델타 | 새 측정이 아니라 검증 기록이고, 그 표 자체가 두 세대 전이다 | `a25fa95b` |
| `RESULTS_DP_BACKWARD_2026-08-15.md` | DP 를 진짜 backward induction 으로 — 분해 충실성 게이트, `_bucket()` 이름 규약, 계층 백오프 | 방법론은 §9-C 의 계약으로 살아 있다. 수치는 두 세대 전 | `5960a25b` |
| `RESULTS_ROUTER3WAY_2026-08-14.md` | 4정책 비교표 첫 판(840판) — 라우터 3-way · DP 레인 신설 · 화면의 목적함수 | 표가 네 세대 뒤로 대체됐다. `fill_results_doc.py` 의 기본 대상 문서였다(§9-A 경고) | `5960a25b` |
| `RESULTS_SURROGATE_REBUILD_2026-08-14.md` | surrogate 재구축 — `SurrogateV2`(2-헤드 Ĵ), `relabel_2026-08-14.jsonl`(365행/155 instance), **국소화된 음의 결과** | 그 모델이 이후 세대로 대체됐다. 매크로 지원 `{0,1,2,7,8}` 회귀 기록이 핵심이었고 그것은 폐쇄 세대가 닫았다 | `390bbdf7` |

**목적함수 통일(2026-08-13) 세대의 측정 기록**

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `RESULTS_STAGE6_ENERGY_2026-08-13.md` | 단계 6 **1차** 스윕(630판, 60분). §5.1 "battery case 가 물리적으로 무해했다" | 그 §5.1 이 2차의 **동기**였고 그 동기는 이미 반영됐다(배터리 물리 복구). 수치는 구세대 | `a25fa95b` |
| `RESULTS_STAGE6_BATTERY_PHYSICS_2026-08-13.md` | 단계 6 **2차** — 배터리 물리 복구(stall/derate 활성, 용량 축소 제거) + 전역 κ 우선순위. 정지 105행/126회 | 그 세대의 판정("battery case 가 드디어 정책을 가른다", noop 30/30 → 0/30)은 이후 세대의 전제로 흡수됐다 | `a25fa95b` |
| `STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` | 단계 7 준비 노트 — `energy_J = NaN` 이 막다른 길이 아니라는 조사(선택지 C 가 유일하게 교락 없다) | **아직 안 한 일**의 조사 노트다. 결론 한 줄은 §9-E 4 에 옮겼고, 재개할 때 이 SHA 로 꺼낼 것 | `a25fa95b` |
| `RESULTS_30SEED_D20_2026-08-13.md` | 30시드 630판 첫 병렬 스윕(D=20) — noop 바닥선이 7 case 중 6개에서 미완주 | 목적함수 통일 **이전** 수치다. 바닥선 논증은 §3 에 남아 있다 | `20380855` |

**🔴 구세대 결과 (수치를 현재 성능으로 인용하지 말 것 — 설계 근거로는 유효)**

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `RESULTS_D20_2026-08-12.md` | 근거리 창고 기하(D=20) 4지표 결과 행렬 | 목적함수 통일로 구세대. ⚠️ `audit_objective.py` 항목 9 가 **이 파일의 존재를 요구**했으나 그 감사는 2026-08-18 정리에서 함께 내려갔다 | `cf63d760` |
| `RESULTS_FARDEPOT_2026-08-12.md` | 원거리 창고 기하(D=40) 4지표 행렬, 셀당 n=2 | D=40 은 더 이상 배포 기하가 아니다 | `64503835` |
| `DEPOT_DISTANCE_SWEEP_2026-08-12.md` | 창고 거리 D 스윕 → 그 시점 기본값 40.0 확정 | 현재 배포 기하는 **D=20.0**(성능 근거가 아니라 UI 판단)이다 | `6144cdb4` |
| `RESULTS_LLM7H.md` | 확률적 OOD 스트림 위의 LLM 재명세 — 구현과 측정(4정책×5시드=20판). 어휘 한 줄이 battery 적중 0/6 → 6/6 을 갈랐다 | 🔴 구세대. **재현 절차와 §5-f·§6 진단은 유효**하고 여러 py 파일이 절 번호로 인용한다(§9-A) | `6144cdb4` |

**정의·설계 — 코드가 이름으로 인용한다(§9-A 의 목록을 같이 볼 것)**

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `EVALUATION.md` | 채점 방식 정의 — 두 원칙(결정을 재라 / 품질과 compute 를 같이 재라), 지표 사다리 Level 0~ | 정의는 §4 "지표 용어" 표로 요약돼 있다. 전문이 필요하면 이 SHA | `042714ff` |
| `DESIGN_ASSIMILATION.md` | C1~C4 정의 + LLM 실측 원본 | 판정 표는 §3 에 있다 | `042714ff` |
| `PLAN_ACTION_GROWTH.md` | 행동공간이 자라는 폐루프 설계(LLM 이 새 대응을 발명 → surrogate 가 흡수) | §1 "연구 목표" 가 가리키던 문서다. **A0 다중 spec 디스패처 정정(§2)** 은 §9-E 로 옮겼다 | `042714ff` |
| `PLAN_LLM_INFERENCE_7H_2026-08-06.md` | 초과비용 지표 설계(§0-a) · Ch-A 행동 어휘 단일화 · 7시간 무인 파이프라인 | 지표 전환의 전문이다. 결론은 §4 "지표 용어" 에 있다 | `042714ff` |
| `RELOCATEBUILD_2026-08-03.md` | 매크로 7 구현·검증 기록 | 🔴 구세대 수치. 구현 계약은 `verifier.jl`·`verify.py` 에 코드로 있다 | `c91b2a55` |
| `ZONE_REDESIGN_STEP1_7_2026-08-05.md` | 구역 결정 재설계 **STEP 1~11 전문**(가장 큰 문서, 80KB). 커버리지 ≠ 막힘, STEP 10 의 두 가족 표, STEP 11 팀 슬롯 인과 | 🔴 구세대 수치. **결론(인과 규칙이 1/2, `ZONE_CAUSAL_RULE` opt-in)은 §9-E 에 있다** | `c91b2a55` |
| `BATTERY_FAULT_REDESIGN_2026-08-05.md` | 배터리 사건 재설계 + λ 와 Replace vs SwapBattery 두 결정(70KB) | 🔴 구세대 수치. **두 결정은 §4 에 그대로 있다** | `c91b2a55` |
| `FIRE_TIME_RELABEL_2026-08-05.md` | 발화 시점 재라벨링 — fault 를 여러 진행도에서 | §3-a 의 "후반엔 흡수" 결론은 **철회됐다**(§7 표 2행) | `c91b2a55` |
| `ORACLE_REBUILD_2026-08-09.md` | **한 파일에 두 문서** — §I 평가 보강 계획(baseline 사다리 B0~B9 · case별 격자 · STEP A~F 와 비용), §II 오라클 라벨 재빌드(= §I 의 STEP D) | 계획이 실행됐다. `run_step_d_firegrid.sh` 가 이름으로 인용한다 | `aaa230b4` |
| `NIGHT_PLAN_2026-08-10.md` | 야간 자동 실행 계획 E→D→A→B→C + **Global Constraints**(스윕 중 코드 수정 금지 · `xargs` 가 pkill 에서 살아남음 등) | 실행이 끝났다. 그 Global Constraints 는 §8 운영 함정(30~35·40~42)으로 이미 승격돼 있다 | `651a4dfd` |

**나머지**

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `SUMMARY_FORBIDZONE_RETRAIN_2026-08-07.md` | **비전문가용 요약** — ForbidZone 발화 + surrogate 매크로 7·8 재학습의 배경·원인·결과를 용어 설명부터 | 이 트리에서 **배경 없이 읽히는 유일한 문서**였다. 다루는 작업이 옛것이라 내렸다 — 새로 온 사람에게 줄 문서가 필요하면 **이 SHA 로 꺼낼 것** | `5960a25b` |
| `STATUS.md` | 현재 상태 · 재개 지점 · 압축된 이력 · 데이터 자산 표 | **§9-E 가 흡수했다.** 2026-08-06 시점의 흐름별 기록(§1~§5 상세)은 원문에만 | `5960a25b` |
| `ARCHIVE.md` | 내린 문서 색인(이 절의 이전 판) | **§10-B·§10-C 로 흡수했다** | `5960a25b` |

### 10-B. 2026-08-17 정리에서 내린 것 (3개)

| 파일명 | 무엇이 들어 있었나 | 왜 내렸나 | SHA |
|---|---|---|---|
| `SESSION_2026-08-12_ORACLE_FIX.md` | 오라클 격자가 평가 런과 **다른 시뮬 설정**에서 돌던 것을 규명·수정한 세션 기록. 격자 v2(13행) 표, 라이브 런 토큰 구현 기록, 런당 비용 모델 | 세션 로그이고 아무도 참조하지 않았다. **측정된 함정 넷은 §8 함정 36·37·39 로 옮겼다** | `fd225836` |
| `OOD_FAULT_SEVERITY_DESIGN_2026-08-12.md` | robot breakdown 의 OOD 를 무엇으로 정의할지 조사 + 잔존능력 ρ 축 설계 제안 | **제안서이고 실행되지 않았다**(코드 변경 0, 측정 0). 진단부(§1)의 함정은 §8 함정 38 로 옮겼다. **ρ 축을 다시 하려면 이 SHA 에서 꺼내 읽을 것** | `a25fa95b` |
| `PLAN_4POLICY_5H_2026-08-10.md` | 4정책 비교표 5시간 무인 실행 계획(티어 구성·선행조건 P1~P6·판당 비용 실측) | 실행이 끝났고 그 표는 여러 세대 뒤로 대체됐다. **선행조건 P1/P2 의 함정은 §8 함정 42 로 옮겼다** | `97a0b979` |

### 10-C. 그 이전 정리에서 내린 것

**2026-08-06 통합에서 흡수·삭제한 7개** — 🔴 **SHA 정정**: 옛 `ARCHIVE.md` 는 `4d723935` 를
적었는데 그것은 이 7개를 **지운** 커밋이라 그 트리에는 파일이 없다(`git show` 가 실패한다).
올바른 SHA 는 그 부모 **`7b9ff26e`** 다:

```bash
git show 7b9ff26e:wm4spacecraft_manufacturing/md/<파일명>
```

| 파일명 | 흡수된 곳 |
|---|---|
| `NIGHT_2026-08-02.md` · `MORNING_2026-08-03.md` · `NIGHT_2026-08-04.md` · `PLAN_0804.md` | 확정 결과 → §3 / 정정 → §7 / 함정 → §8 |
| `PLAN_COMPLETION.md` | 완주 조사 S0~S4 → §6 |
| `DUMP_SCHEMA.md` | §5 (2026-08-02 이후 스키마가 바뀌어 원문은 이미 틀렸다) |
| `ZONE_BLOCKAGE_STEP8_11_2026-08-05.md` | `ZONE_REDESIGN_STEP1_7_2026-08-05.md` 의 STEP 8~11 절(원래 연속된 문서) → 이제 §10-A |

**옛 `RESULTS.md`(E1~E4 측정 원본)** — 요약은 §3 에 그대로 있다. 원문:
`git show 2bde2dd1:wm4spacecraft_manufacturing/md/RESULTS.md`.

**레포 밖으로 나간 상위 문서 2개** — `artifacts_mdp/OVERNIGHT_REPORT.md` 와
`artifacts_openworld/README.md` 는 2026-08-09 의 "매크로 7·8 이전 세대 산출물 일괄 삭제"
(`c91b2a55`)에서 디렉터리째 사라졌다. **복원하지 말 것** — 행동 어휘가 잘린 세대의 산출물이다.

### 10-D. 계획서 아카이브

`docs/superpowers/plans/` 의 실행 완료 계획서 14개는 **`docs/superpowers/plans/README.md`** 가
같은 형식으로 목록·SHA 를 갖고 있다. `docs/superpowers/specs/` 의 설계 문서 7개는 **안 내렸다**
— 그 결정들이 아직 유효하기 때문이다.

---

## 11. 폴더 구조 — 파일이 어디 있고 왜 거기 있나 (2026-08-18 분류)

2026-08-18 이전에는 `wm4spacecraft_manufacturing/` 바로 아래에 py 23 · sh 6 · json/txt 10 ·
md 3 이 **평평하게** 깔려 있었다. 어떤 코드가 결과를 만들고 어떤 코드가 표를 만드는지 이름만
보고는 알 수 없었다. 역할별로 나눴다. **결과 데이터 폴더(`results_*` · `artifacts_*` ·
`oracle/out` · `_night` · `sweep_lab` · `baseline_n5`)는 건드리지 않았다.**

| 폴더 | 역할 | 들어 있는 것 |
|---|---|---|
| `core/` | **단일 진실원 라이브러리.** 목적함수 · 행동 어휘 · 기준 정책 · 데이터셋 이름 · 덤프 로더/featurizer. 다른 레인 전부가 여기를 import 한다 | `objective.py`·`objective.jl`·`objective.json` · `action_registry.py`·`.json` · `reference_policy.py` · `wm_datasets.py` · `e1_analyze.py` · `features_agnostic.py` · `wmpath.py` |
| `surrogate/` | surrogate 모델의 정의 · 학습 · 게이트 · 평가 · 배포 export | `surrogate_model.py` · `surrogate_v2.py` · `surrogate_features.py` · `surrogate_gates.py` · `eval_surrogate_v2.py` · `export_surrogate.py` · `surrogate_linear.json` |
| `novelty/` | drift/novelty 감지기와 그 교정 | `drift_detectors.py` · `export_novelty_calibration.py` · `novelty_calibration.json` · `novelty_calibration_no_zoneblk.json` |
| `sweep/` | **결과를 만드는 실행 레인.** 스윕 드라이버 · 샤드 러너 · 병합 | `run_4pol_parallel.sh` · `run_shard.sh` · `llm_ood_eval.py` · `merge_shards.py` |
| `reporting/` | **표·md 를 만드는 레인.** 채점 · 통계 · 표 조립 | `finish_tables.sh` · `build_final_table.py` · `build_compare_table.py` · `build_md_report.py` · `fill_results_doc.py` · `shadow_score.py` · `stats_paired.py` · `ood_sweep_report.py` |
| `render/` | 보드/스트림 렌더와 대시보드 발행 | `render_all.sh` · `publish_streams.sh` |
| `md/` | 문서 전부 | 이 파일 · `LABELING_MANUAL.md` · `MDP_DESIGN_FROM_SCRATCH.md` · `PREREG_SEED20.md` |
| `measurements/` | **읽는 코드가 없는 측정 기록.** 인용은 되지만 파이프라인이 로드하지 않는다 | `cost_eval_metrics.json`·`_v2.json` · `llm_probe.json` · `sweep_results_graded_hs_all.txt` |
| `oracle/` · `dp_oracle/` | 라벨 레인(julia) · DP 오라클 — **분류 전과 같다** | 그대로 |

### 11-A. import 가 어떻게 계속 도는가 — `core/wmpath.py`

분류 전에는 모든 py 가 한 폴더라 `import objective` 같은 **맨이름 import** 가 그냥 됐다
(스크립트 자기 폴더 = `sys.path[0]`). 폴더를 나눈 뒤에도 그 관례를 **그대로 유지**한다 —
자기 폴더 밖 모듈을 쓰는 파일은 머리에 이 세 줄을 갖는다:

```python
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import wmpath                       # 코드 폴더 전부를 sys.path 에 올린다
```

패키지(`__init__.py` + 상대 import)로 가지 **않은** 이유: `python llm_ood_eval.py run` 처럼
스크립트로 직접 실행하는 진입점이 여럿이고(`sweep/run_shard.sh` · `reporting/finish_tables.sh` ·
`build_final_table.py` 의 서브프로세스 호출), 레포 밖 소비처
(`src/respec/llm_service/dspy_service.py`)도 경로로 붙는다. 자세한 근거는 `core/wmpath.py` 머리말.

### 11-B. 🔴 기준점이 둘이다 — `HERE` 와 `WM`

분류 전에는 `HERE`(= 이 파일 폴더) 와 "wm4 폴더" 가 같은 값이었다. 이제 다르다.

- `HERE` = **그 파일이 사는 하위 폴더**(`reporting/` 등)
- `WM` = `wm4spacecraft_manufacturing/` — `results_4pol/` · `artifacts_4pol/` · `dp_oracle/` ·
  `md/` · `results/` 같은 **데이터 폴더의 기준점은 전부 이쪽**이다
- `REPO` = 레포 루트 — `.venv/` 와 `git` 이 있고, julia 를 `--project=.` 로 띄울 때의 cwd다

새 코드에서 데이터 경로를 `HERE` 로 잡으면 `reporting/results_4pol/…` 을 찾다 조용히 빈 표를
낸다. `wmpath.WM` 을 쓸 것.

### 11-C. 레포 밖에서 이 폴더를 보는 곳 (이동 때 같이 고친 것)

| 밖 | 무엇을 보나 |
|---|---|
| `src/respec/llm_service/dspy_service.py` | `core/`·`surrogate/` 를 `sys.path` 에 **append**(insert 아님 — dspy/litellm 과 동명 모듈 충돌 회피) |
| `src/essential_tg_coponents.jl` · `tools/monitor/server.jl` | `core/objective.json` |
| `tools/monitor/run_demo.jl` · `render_demo.jl` · `oracle/gen_oracle_dataset.jl` | `core/objective.jl` include |
| `tools/monitor/dp_lane.jl` | `core/action_registry.json` |
| `tools/test_policy_oracle.jl` | `core/reference_policy.py`(리터럴을 정규식으로 읽는다) |
| `tools/demos.jl` | `surrogate/surrogate_linear.json` |
| `tools/test_novelty.jl` · `test_router.jl` · `tools/monitor/regen_router_cases.sh` | `novelty/novelty_calibration*.json` |
| `tools/regen_d20.sh` | `sweep/llm_ood_eval.py` |
