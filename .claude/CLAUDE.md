# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

## 🧹 2026-08-18 — 기계 검사를 걷어냈다 (아래 절들을 읽기 전에)

`wm4spacecraft_manufacturing/` 의 코드 123개 중 **87개를 지웠다** — 검사기(`test_*.py`·
`audit_*.py`·`check_*.py`·`verify*.py`·`measure_*.py`·`probe_*.jl`) · 게이트(`gate_*`) ·
중복/구세대 러너 · 고아 · Windows 전용(`.ps1`/`.cmd`). 판정 기준은
**"결과를 만드는가, 보기만 하는가 — 검사기는 나가고 생산자는 남는다"** 였다.
목록과 근거: `.superpowers/sdd/2026-08-18-repo-file-reduction/CLASSIFY.md`.
전부 복구된다: `git show 8e005842:wm4spacecraft_manufacturing/<path>`.

🔴 **아래 세대 절들에 남아 있는 `audit_objective.py`(9/9) · `test_objective.py`(29/29) 같은
문장은 지우지 않았다 — 그 도구들이 그때 실제로 잰 사실의 기록이고 그 사실은 여전히 참이기
때문이다. 참이 아닌 것은 "지금 그 명령을 돌릴 수 있다" 뿐이다.**

**이제 기계로 감시되지 않는 것 (사람이 봐야 한다):**

1. **`objective_hash` 세대 계약** — 산출물의 해시가 현행 `objective.json` 의 해시와 같은가.
   리터럴 복붙 12파일 스캔 · Julia↔Python 해시 일치 · 스케일 null 여부 · 학습타깃 유예 표식도
   같이 나갔다 (`audit_objective.py`).
2. **행동 어휘 6-소비처 일치** (`audit_action_vocab.py`). 어휘 누락은 에러 없이 **성능으로만**
   샌다 — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을 갈랐던 그 실패 모양이다.
3. **dp 비용 분해 충실성**(`c_prefix + Σc_k + terminal == J_row`)과 Bellman·칸키 동치
   (`dp_oracle/test_cost_decomposition.py` · `test_dp_solve.py` · `test_cellkey_parity.py`).
   ※ `dp_oracle/sample_grid.py` 안의 **차단 게이트 자체는 살아 있다**(표집이 위반하면 exit 1).
   없어진 것은 그 게이트를 합성 판으로 검사하던 단위검사다.
4. **발행 문서의 표본수 문구 회귀**(`test_report_sample_size.py`). 표는 n=30 인데 산문은 n=20
   인 자가당착 문서가 다시 나올 수 있다.
5. **스윕 사전 조건 게이트**(`gate_prereq.sh`). `run_4pol_parallel.sh` 는 이제 게이트 없이 바로
   스윕을 시작한다 — 🔴 **DSPy `/health` 확인이 사라졌다.** 서비스가 죽어 있으면 dspy·surrogate
   레인이 조용히 canonical 로 내려앉은 채 630판이 다 돌아간다(위 §현행 세대의 "교차 레인 폴백"
   경고와 같은 실패 모양). 스윕 전에 `DSPY_URL` 을 손으로 확인하고, 스윕 후에는
   `decisions[].enacted` 레인 히스토그램으로 사후 확인할 것.

**남아 있는 실물 검증 둘**: `cd wm4spacecraft_manufacturing && bash finish_tables.sh` 가
`artifacts_4pol/COMPARE.md` 를 재현하는가(합계 **210/210 · 189/210 · 205/210**) ·
`julia +lts --project=. -e 'using Pkg; Pkg.test()'`(기대 11 pass / 1 error).

## ★ 결과 세대 — 먼저 읽을 것 (2026-08-09 정리)

### ✅ 2026-08-16 — SwapBattery 가 창고 예비의 물리 배송이 됐다 (현행 세대)

**이 세대의 결과 = `md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` + `artifacts_4pol/COMPARE.md`.**
목적함수 세대는 안 갈렸다(`objective.json` 무변경). 코드 세대는 `2b5637c3`(배송 + 고장 피커)
+ `49cf841f`·`ec8cf495`(사전 게이트) — 샤드 도장은 210/210 전부 `commit=ec8cf495`.
계획서: `docs/superpowers/plans/2026-08-15-swapbattery-courier-resweep.md`(§실행 중 확정된 사실이
계획 본문의 오류 8개를 뒤집는다 — 계획서 본문보다 그 절이 맞다).

- **무엇이 세대를 갈랐나 ① 배송**(`src/respec/battery_courier.jl` 신규 + `replace_robot.jl`):
  `swap_battery!` 가 같은 스텝 안에서 `fleet.soc[role] = 1.0` 을 찍던 **장부 조작**에서, 가장
  가까운 창고의 예비 로봇이 배터리를 들고 현장까지 **주행**하고 **도착 스텝에서만** 교체가
  적용되는 물리 배송으로 바뀌었다. 그래서 **방전 구간이 실재하고, 그동안 그 로봇의 작업 라인이
  선다.** 자원 회계는 어휘의 뜻을 지킨다 — 예비를 `pop_spare!` 로 소비하지 않으므로 창고 재고는
  안 줄고, 드는 비용은 **시간과 라인 정지**다. 상태 문자열이 갈렸다:
  `:battery_swapped` → `:battery_courier_dispatched`.
- **② 고장 피커**(`src/respec/ood_injection.jl` 의 `_faultable` 신규 술어, `_pick_active_robot`
  세 단 전부에 적용): 주차된 창고 예비가 고장 대상에서 빠진다. 예전엔 `failed=R16, spare=R16`
  처럼 **자기 자신으로 교체**하는 무의미(vacuous) 사건이 났다 — `safe=true` 경로는 이미 제외를
  갖고 있었고 데모 기본값인 `safe=false` 경로만 뚫려 있었다.
- **구세대 재현: `DEMO_BATTERY_COURIER=0`**(호출은 `tools/monitor/run_demo.jl:613-616` 의
  `set_battery_courier!`, `:610-612` 가 그 손잡이를 주석으로 문서화한다).
  ⚠️ **배송만 끈다 — `_faultable` 수정은 되돌아가지 않는다.** 그래서 이 플래그로 만든 판은
  구세대와 **같지 않다**.
  ⚠️ **되돌아가지 않는 것이 하나 더 있다(2026-08-16 확인): `src/monitor/monitor.jl:159-162` 의
  `REPLACE_SOC_THRESHOLD` 회복 조건.** 세대 커밋 `2b5637c3` 에 배송과 **같이** 실렸는데
  이 플래그의 조건문 밖이라 `DEMO_BATTERY_COURIER=0` 으로도 켜진 채 남는다. 즉 이 손잡이가
  만드는 "통제"에는 **배송 · `_faultable` · 이 회복 조건 셋이 섞여 있다**(둘이 아니다).
  다만 blast radius 는 다르다 — 이 셋째 변경은 `_mon_robots`(`monitor_emit!` 의 `robots` 블록,
  `:488`)만 타므로 **모니터 스트림/보드의 SoC·mode 표시**에만 영향을 주고 `rows.jsonl` 의
  채점 지표에는 안 닿는다. 그래도 보드를 세대 간에 눈으로 대조할 때는 교란 변수다.
- **★ `objective_hash` 는 안 바뀐다 — `19819377a7f8ebb2` 그대로다.** 갈린 것은 **동역학**이지
  목적함수가 아니다(`objective.json` 무변경, 630행 전부 세대 쌍 `('19819377a7f8ebb2', 1)`).
  🔴 **여기서 해시를 올리면 배포 라벨셋 전부와 surrogate 가 한꺼번에 구세대로 재분류된다** —
  갈리지도 않은 축으로 세대를 가르는 것이다. (옛 해시를 이 파일에 문자열로 다시 적지 말 것.
  예전에는 `audit_objective.py` 항목 9 가 CLAUDE.md 안의 해시 인용과 계약 개수를 기계로 봤지만
  그 감사는 2026-08-18 정리에서 삭제됐다 — 이제 아무것도 안 잡으므로 사람이 지킨다.)
- **스윕**: 7 case × 30 seed × 3 policy = **630판**, 샤드 **210/210 ok · fail 0 · deadline 0**,
  **1h47m**, 210 샤드 전부 `commit=ec8cf495` 단일 도장, 630행 전부 한 세대 쌍.
  비교표 3열 합계: canonical 207 → **210** · surrogate 198 → **189** · llm 203 → **205**.
- **배송은 실제로 발화했다: dispatched 277 · 즉시교체 폴백 0**(구세대는 같은 210 샤드에서
  dispatched 0 · 폴백 267). 레인은 `surrogate 165 / dspy 112 / canonical 0`.
  🔴 **277 은 "파견 요청" 수이지 "적용된 교체" 수가 아니다.** 이 수는 `swap_battery!` 가
  `:battery_courier_dispatched` 를 돌려준 횟수를 셀 뿐이고, 실제 교체는 배송 로봇이 도착한
  순간에만 `battery_courier_step!`(`battery_courier.jl:234-237`)에서 적용된다. 아래 한계 5
  (중복 파견이 조용히 성공으로 보고되는 결함)가 바로 그 둘이 갈리는 자리이고, **이 세대의
  교차검증은 그 격차를 못 본다** — 두 세는 대상이 모두 파견 요청이라 항진적이다.
  이 수를 인용할 때는 반드시 **"파견 요청 277"** 으로 적을 것.
  ⚠️ **277 이라는 수 자체는 세대를 나르지 않는다** — 구세대 집행도 267 로 거의 같다.
  세대를 가르는 것은 `dispatched/fallback` 의 **반전**이다(같은 `println`, `run_demo.jl:379`).
- **★ canonical 이 `SwapBattery` 를 한 번도 안 고르는 것은 구조적이다** — 210판에서 낸 결정
  **1533개**의 매크로 전체가 `Replace 561 / ReformTeam 693 / NOOP 279` 이고 `SwapBattery` 는
  **0회**다(세 레인 합은 4027). 그 귀결이 위험하다:
  **배송을 태우는 레인은 surrogate·dspy 둘뿐인데, 그 둘이 바로 DSPy 서비스가 죽으면 조용히
  canonical 로 내려앉는 레인**이다. 게이트의 `/health` 는 **시작 시점만** 본다 → 스윕마다
  `decisions[].enacted` 레인 히스토그램으로 사후 확인할 것(이번 실측: 교차 레인 폴백 0).
- **★ 헤드라인 논증은 레인 간 대비가 아니라 레인 내부 · case 간 용량-반응이다.** 레인 · 커밋 ·
  세대 · 목적함수를 전부 고정하고 **배송이 발화할 수 있는 횟수만** 바꾼다(makespan 중앙 구→신):
  surrogate `fault`(0회) **−0.8%** → `fault_battery`(33회) **+26.3%** → `battery`(74회) **+54.9%**,
  dspy **−2.2% → +15.0% → +32.6%**. 에너지도 같은 방향으로 단조다.
  🔴 **"canonical 은 평평한데 추론 레인이 올랐다" 를 근거로 쓰면 안 된다 — 직접 반례가 있다.**
  순수 `zone` case 는 세 레인 모두 `SwapBattery` 집행이 0회이고 `BatteryTruth` 사건이 **아예
  0건**인데도 surrogate **+33.9%** · dspy **+46.0%** 가 그대로 나온다. 그 패턴은 배송 없이도 난다.
  🔴 `battery_zone`(+48.6%/+53.1%) · `all`(+50.8%/+42.6%) 은 zone 축과 겹쳐 **교란**돼 있다 —
  **배송 크기로 인용 금지**(배송 없는 대조항 `fault_zone` 이 이미 surrogate +27.1%).
- **★ zone 축 이동은 귀속되지 않았다.** 보존된 구세대는 `commit=5dd29dae` 도장이고
  **스윕 도장(`5dd29dae..ec8cf495`) 기준 14 커밋** 차이라 **배송 단독 대조군이 아니다**
  (⚠️ 분모는 앵커에 딸린다 — `5dd29dae..HEAD` 는 **21** 이다, HEAD=`41cf9a26` 2026-08-16 실측.
  이 괄호가 예전에 적던 19 는 HEAD 가 `2b5a9457` 이던 시점의 값이라 이제 틀리다. 이 수를 옮겨
  적을 때는 **앵커를 같이** 적을 것). `_faultable` 로도 설명되지 않는다 — 그건
  고장 **대상 선정**을 바꾸는데 순수 zone 에는 고장 사건이 없다(`_faultable` 이 설명으로
  정당한 자리는 고장 축 미완주 **감소**다). 옳은 통제는 **같은 커밋에서
  `DEMO_BATTERY_COURIER=0` 으로 630판을 다시 굴리는 것**이고 **이번 사이클은 돌리지 않았다.**
- **★ 정지 지표가 둘이다 — 섞으면 틀린다.** `battery_physics.n_stalled > 0` = **신 7판 / 구 0판**
  (전부 배터리가 낀 case, 전부 미완주; `battery_physics` **설정은 두 세대에서 동일**하므로 설정
  아티팩트가 아니다). 이것이 "배송이 오는 동안 로봇이 진짜로 방전된 채 서 있다" 의 가장 깨끗한
  양(陽)의 증거다. 판 미완주 `status=="stall"` 은 **신 26 / 구 22** 이고, **그 7판은 26판의
  진부분집합**이다 — 19판은 판으로 멈췄지만 기계적으로 멈춰 선 로봇은 없다.
- **dp 열이 이 표에 없다.** `dp_oracle/value.json` 이 **구세대 동역학**(1-step deviation 세대,
  `SwapBattery` 가 공짜이던 세계)에서 표집됐기 때문이다 — 그 표로 dp 레인을 굴려 4열에 실으면
  한 표에 두 세대가 섞인다. **어떻게 뺐나**: `results_4pol/shards_dp` 를 구세대 트리와 함께
  옮겼고 `finish_tables.sh:32` 가 그 부재를 보고 열을 `이 레인은 스윕에 없음` 으로 **자동으로
  낮춘다**(표를 손으로 고치지 않았다). **되살리는 법**: 배송 동역학에서
  `dp_oracle/sample_grid.py` 재표집 → `dp_solve.py --backoff` → dp 레인만 재스윕
  (**4~5시간**, 표집이 대부분). 절차는 결과 문서 §9.
- **★ 발행된 표에서 세대 누수를 둘 잡아 닫았다**(`1bfbcaf8`, `7eddb629`). dp **열**은 올바르게
  비어 있었는데 ① §8.7 gap 각주가 **빌드 시점에 새 행을 구세대 `value.json` 에 대고 다시
  계산**해 숫자를 하나 찍고 있었고, ② 1차 수정 뒤에도 "이 표의 DP 는 진짜 Bellman backward
  induction 이다 …" 라는 **주장 블록**이 살아남았다. **살아남은 이유는 그 문장에 숫자가 없어서**
  1차 수정의 grep 을 전부 통과했기 때문이다.
  **★ 교훈: 세대 누수는 숫자가 없어도 누수다.** 기준은 "숫자가 나갔는가" 가 아니라
  **"구세대 파일이 이번 세대 산출물의 참·거짓을 정하는가"** 다.
  🔴 **잔존 위험**: 그 `value.json` 의 `objective_hash` 는 **현행값과 같다**(목적함수는 안 갈렸고
  갈린 것은 코드 세대다). **해시만 보고 게이팅하는 다른 소비처는 이 맹점을 그대로 공유한다** —
  이번엔 호출부 하나만 닫았고, 쓸 수 있었던 신호는 `shards_dp` 디렉토리 존재 여부뿐이었다.
- **★ surrogate 라벨은 낡았다(stale) — 판정 유지, 근거는 갈아 끼웠다.**
  🔴 **초판의 `−8.3pp`(완주)·`+13.8%`(makespan)를 인용하지 말 것 — 결정 가중 아티팩트다.**
  판 하나의 결과를 그 판이 그 팔을 고른 **횟수만큼 반복해서** 센 값이고, 판 단위로는 **1.8pp**
  다(surrogate 120판 중 **52판이 두 팔을 다 집행한다** — "≥1 SwapBattery ⇒ SwapBattery 판"
  규칙이 그 52판을 통째로 한쪽으로 몰아 Replace 쪽 n 이 18판밖에 안 남는다).
  **살아남은 근거는 case 층화 makespan 용량-반응**이다 — **같은 시드의 canonical** 과 짝지어 뺀
  Δmakespan 중앙이 판당 `SwapBattery` 집행 `0회 +0.00 → 1회 +3.90 → 2회 +6.45 → 3회 이상
  +9.13 s`(n 7/20/15/12). 집행 0회 판의 Δ 가 **정확히 0.00** 인 것이 내부 통제다.
  ⚠️ **그 사다리는 zone 이 안 낀 두 case(`battery`·`fault_battery`)를 풀링해서 잰 값이다** —
  `measure_swap_staleness.py` 는 그 층화까지만 하고 그 아래로는 쪼개지 않는다.
  **case 별로 또는 판당 총 배터리 결정 수로 더 쪼개면 칸이 n=1~4 로 얇아지고 단조성이 깨진다**
  (실측: surrogate `fault_battery` 3회+ **−0.50**(n=1), dspy `fault_battery` 2회 **+2.06**;
  결정 수 고정 시 surrogate n_bat=4 → **+3.92/+3.36/+9.13**, dspy n_bat=2 → **−2.54/+6.52**).
  🔴 **"쪼개도 유지된다" 를 이 사다리의 강건성 근거로 쓰지 말 것 — 그 분석은 측정된 적이 없고
  실제로 재현되지 않는다.** 이 판정은 이미 한 번(−8.3pp) 과대주장으로 재작성됐다.
  ⚠️ **dspy 의 "복제" 는 makespan 에서만 성립한다** — 판 단위 완주 격차는 **0.0pp** 다.
  그런데도 surrogate 는 배터리 결정의 60.7%(165/272)를 그 팔에 준다.
- 신규 계약: `wm4spacecraft_manufacturing/gate_courier_sweep.sh`(**4/4** — 배송 집행 · 고장
  피커 · DSPy · `objective_hash`) · `wm4spacecraft_manufacturing/measure_swap_staleness.py`.
  **★ 게이트가 닫은 함정**: 원안 G2 는 **영원히 실패할 수 없는 검사**였다 — 그렙 대상
  `Robot R<n> has broken down` 이 **stdout 에 한 번도 안 나온다**(`monitor.jl:354` 가 메모리
  Dict 에만 쌓고 `MONITOR_STREAM` JSONL 로만 나간다). 실측 **stdout 0/90 · 스트림 90/90**.
  → 스트림 파일을 직접 그렙하고 "고장 0건이면 실패" 가드를 넣었다. **게이트를 짤 때는 음성
  대조를 먼저 실측할 것** — 그 문자열이 실제로 쓰인 적이 있는가.
- **알려진 한계 — 고치지 않고 기록한 것:**
  1. **zone 축 이동이 귀속되지 않았다**(위). 옳은 통제를 이번 사이클에 돌리지 않았다.
  2. 🔴 **런 간 재현성 결함이 살아 있다** — `_pick_active_robot`(`src/respec/ood_injection.jl:856`)
     이 `env.cache.active_set` 을 순회하는데 그것은 **`Set` 이라 순회 순서가 정의돼 있지 않다.**
     같은 시드·같은 커밋을 다시 굴려도 고장 대상 로봇이 갈릴 수 있다. 이 계획은 **범위에서
     뺐다**(고치면 그 자체가 세대를 갈라 이번 비교의 교란 변수가 된다). 이 스윕은 반복 측정이
     없어 위 Δ 중 그 잡음의 몫을 **분리하지 못한다.**
  3. **발행된 `decision_acc` 는 아직 구세대 기준으로 채점된다** — `reference_policy.py` 의
     `BASIS["battery"]` 문자열에 `🔴 STALE PREMISE` 표식만 붙였고 **규칙 자체
     (`BATTERY_DEEP_SOC` · `reference_action()`)는 재유도하지 않았다.** 즉 채점 기준이 여전히
     "깊은 SoC 에서는 `SwapBattery` 가 옳다" 이고 그것은 이 세대의 측정과 어긋난다
     (결과 문서 §10-F).
  4. `measure_swap_staleness.py:177-178` 에 **잠재 `ZeroDivisionError`** — 어떤 레인이 두 팔 중
     하나를 한 번도 안 집행하면 `n=0` 으로 나눈다(surrogate 는 앞의 조기 `sys.exit` 로 막히지만
     **dspy 레인은 안 막힌다**). 현재 데이터로는 발화 안 함.
  5. 🔴 **중복 파견이 "성공" 으로 보고되고 교체는 일어나지 않는다**(`src/respec/battery_courier.jl:169-171`).
     중복 제거 스캔이 `d.target == target` 을 **phase 무관**하게 맞춘다. 그 로봇의 배송이 이미
     `:returning` 이면 두 번째 `SwapBattery` 가 **그 낡은 배송을 그대로 돌려주고**,
     `swap_battery!` 는 `:battery_courier_dispatched` 를, `tools/monitor/run_demo.jl:379` 는
     성공 문자열을 찍는다. 그런데 `battery_courier_step!` 은 `:outbound` 가지에서만
     `_apply_battery_swap!` 을 부르므로(`:234-237`) **교체가 아예 안 일어난다** — 팔은 성공을
     보고하고 로봇은 방전인 채로 남는다.
     🔴 **이 세대의 교차검증은 이것을 원리적으로 못 잡는다**: 발행된 검사("210 샤드 전부
     `rows.jsonl` 집행 수 == 런로그 `[battery] swap=` 줄 수, 불일치 0")는 **파견 요청을 두 번
     세어 맞춰본 것**이라 이 결함에 대해 항진적이다. 적용된 교체를 세는 신호가 산출물에 없다
     (`_apply_battery_swap!` 의 도착 로그는 `@info` 라 `Logging.Warn` 로거가 버린다).
     **도달 가능성은 가정이 아니라 실측이다**(2026-08-16, `results_4pol` 재계산; 2026-08-17
     재검산으로 앵커를 정정했다 — 원안은 무해한 쪽 값에 걸려 있었다). 연속 `SwapBattery`
     결정쌍 **106개**의 간격 중앙 **8.50 s**(min 2.95, 5 s 미만 **7쌍**). 결함에 더 직접적인
     **같은 대상 로봇** 쌍은 **60개**. 배송의 `:outbound`/`:returning` 각 구간은 D=20 ·
     `v=4.0 m/s`(`rvo_interface.jl:119`)에서 **≈5 s** — 처음 ~5 s 가 `:outbound`(재사용돼도
     도착 시 정상 적용돼 무해), 다음 ~5~10 s 가 `:returning`(결함이 실제로 발화하는 대). 60개를
     그 밴드로 나누면 `<5 s 2 · [5,10) 50 · [10,15) 7 · ≥15 s 1` — **50/60 이 발화 창 안에
     든다**(원안이 앵커로 쓴 "min 4.32 s" 는 무해한 <5 s 쪽 값이었다).
     ⚠️ **50 은 발화 횟수의 상한이지 실측 발화 횟수가 아니다** — 혼잡·volume speed factor 가
     창 경계를 흔들 수 있고 적용된 교체를 세는 신호가 산출물에 없어 실제 발화 횟수는 모른다.
     발행된 makespan/완주 수치가 "성공으로 보고됐지만 적용 안 된 교체"를 포함한 판으로부터
     자유롭다고 보일 수 없다는 점은 그대로다.
  6. 🔴 **다른 창고의 놀고 있는 예비가 Replace 경로에서 안 보인다**(`src/respec/ood_injection.jl:425-435`).
     `pop_spare!`(`:386-396`)는 배송 중인 예비를 건너뛰도록 courier-aware 로 고쳤는데
     (`findlast(r -> !is_battery_courier(r), v)`, 남은 게 전부 배송 중이면 `nothing`),
     `nearest_pool` 은 여전히 `isempty(SPARE_POOLS[][key])` 만 본다. 그래서 그 독스트링의
     약속("반환된 키는 `pop_spare!` 로 바로 꺼낼 수 있다")이 **거짓**이 됐다. 풀당 기본 예비가
     2대뿐이라 가장 가까운 창고의 둘이 배송을 나가면 `nearest_pool` 은 그 창고를 계속 고르고
     `pop_spare!` 가 `nothing` 을 돌려줘, `replan.jl:763-766` 이 `"empty_pool"` 로,
     `replace_robot.jl:1516-1520` 이 `:no_spare` 로 강등된다 — **아직 자유 예비가 남은 다른
     창고를 한 번도 안 보고**. 비대칭이 핵심이다: 배송 쪽 `_nearest_courier_depot`
     (`battery_courier.jl:146-158`)은 **모든 창고를 훑는데** Replace 쪽은 최근접 하나만 본다.
     ⚠️ **커밋된 산출물로는 측정 불가**: 신호가 전부 `@info`/`@warn` 인데 이 레인은
     `verbose=false` + `Logging.Warn` 로거라, 210 샤드 로그 전수 그렙에서
     `empty_pool`/`no_spare` 가 **두 세대 모두 0건**이다. "안 났다" 가 아니라 "못 본다" 다.
  ⚠️ **5·6 은 코드를 안 고치고 기록만 했다** — 고치면 코드 세대가 갈려 방금 발행한 630판이
     통째로 무효가 된다. **다음 사이클에 재스윕과 묶어서** 고칠 것.
- **다음 사이클 1순위 = 배송 동역학 아래에서 라벨 격자를 다시 만들고 surrogate 를 재학습하는 것.**
  그 작업이 위 3(기준 정책 재유도)과 dp 표 재표집을 같이 닫는다.

### ✅ 2026-08-17 — 표집을 1-step deviation 으로 바꿨다 (직전 세대)

**직전 세대 결과 = `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` + 그 세대의 `artifacts_4pol/`
(현행 트리는 위 배송 세대로 재생성됐고, 그 세대 사본은 `artifacts_4pol_gen_swapfree_2026-08-15/`
· 원자료는 `results_4pol_gen_swapfree_2026-08-15/` 에 보존).**
목적함수 세대는 안 갈렸다(`objective.json` 무변경). 코드 세대는 `c5c4fb63`+`28158a49`+`aff13715`+`3e492c21`.

- **무엇이 세대를 갈랐나**: 한 rollout 이 `DEMO_FORCE_MACRO` 로 **판 전체**를 한 팔로 굴린 것에서,
  `DS_DEVIATE_AT=k` + `DS_DEVIATE_ARM=<이름>` 으로 **k 번째 결정만** 갈아쓴 판으로 바뀌었다.
  prefix 재현은 replay 로 한다 — 결정성 게이트 실측 PASS(`DS_DEVIATE_AT=999` 판이 순수 canonical
  판과 종단 지표·`energy_J`·결정 열까지 동일). 그래서 `k=1` 고정 축소판은 쓰지 않았다.
- **판정(계획 §3): #6 만 PASS, 나머지 다섯은 미달.** 그러나 **메커니즘은 작동했다.**

  | # | 지표 | 08-16 | 이번 | 목표 |
  |---|---|---|---|---|
  | 1 | 표집 판 완주율 | 16.9% | **86.0%** | ≥90% |
  | 2 | V 중앙값 | 4743.6 | **2483.7** | 20~200 |
  | 3 | 단일팔 칸 | 27/49 | 23/48 | ≤5 |
  | 4 | dp 표 조회 | 7.7% | **19.3%** | ≥50% |
  | 5 | §8.7 gap | 89.3% | **83.5%** | ≤20% |
  | 6 | 충실성 위반 | 0 | **0** | 0 |

- **★ #3 은 수치가 아니라 분포를 봐야 한다: `1팔 23칸 / 7팔 25칸` 으로 완전 이봉이 됐다**
  (구세대 `{1팔 27, 2팔 4, 5팔 2, 6팔 1, 7팔 15}`). **그 이봉은 한 술어로 예외 없이 갈린다** —
  "그 칸에 `decision_index == board_deviate_at` 행이 있는가" 로 나누면 `{(7팔, deviation 칸): 25,
  (1팔, 비-deviation 칸): 23}` 이고, 7팔 칸 중 **일곱 팔이 deviation 행으로 안 덮인 칸은 0개**다.
  남은 단일팔 23칸은 **deviation 결정 밖(prefix 또는 꼬리)에서만 도달하는 칸**이다 —
  ~~전부 꼬리~~ 가 아니라 **꼬리만 11 · prefix+꼬리 8 · prefix만 4**(355행: `>` 297 · `<` 58 ·
  `==` 0). 결론(구조적 미달)은 그대로지만 근거 문장이 틀렸었다. 그 한 팔은
  `Replace 18 · ReformTeam 3 · NOOP 2` = canonical 이 고르는 매크로. 전이 가중으로는 15.7%.
  ⚠️ **"deviation 행 447개가 64·64·64·64·64·64·63 으로 고르게 흩어졌다 = 설계가 작동했다"는
  항진명제다** — `pick_k` 가 `arm_id` 를 안 쓰므로 발화는 `(case,seed)` 마다 전부/전무이고
  발화 판은 정확히 한 개의 `k` 행을 낸다. `64 = 84 − 20`(미발화 그룹)으로 셈이 이미 정해져
  있다. 정보를 나르는 숫자는 `63`(ReformTeam 크래시 1판) 하나뿐이다.
- **★ dp 레인의 `single_arm` 이 56.0% → 8.3% 로 무너졌다.** #4 가 50% 를 못 넘긴 것은 실패가
  **`tie_unresolved` 로 옮겨갔기** 때문이다(36.3% → **72.4%**).
  ⚠️ **~~그 tie 는 참이다~~ — 아니다. 대다수가 `n=1` 자동 동점이다.** tie 칸 24개의 비-최선 동점
  슬롯 122개를 분류하면 **정확히 같은 `Q` 10 · 유한 `se` 안에서 가까움 58 · `n<2` 라 `se=inf`
  로 무조건 동점 54**(최대 격차 **11259**: `q=13185.3` vs 최선 `1926.1`). 메커니즘은
  `dp_solve.py:88-93` 의 `_se()` 가 `n<2` 에서 `inf` 를 돌려주고 `dp_solve.py:246` 이
  `not isfinite(se_d)` 로 단락하는 것 — **표본 하나뿐인 팔은 Q 와 무관하게 무조건 동점**이다.
  1-step deviation 에서는 deviation 칸의 거의 모든 팔이 `n=1` 이라 **동점이 구성상 제조된다**.
  자동 동점을 빼면 24칸 중 **9칸이 확정**된다. 원자료로도 같다: deviation 그룹 64개 중 일곱 팔이
  `c`·`next_cell` 을 모두 공유하는 **진짜 동점 그룹은 9개(≈14%)** 뿐이다.
  **그래서 다음 사이클 1순위는 ~~tie-break 규칙~~ 이 아니다** — `MACRO_COST` 로 가르면 자릿수가
  넷 다른 `Q` 를 매크로 비용으로 중재하게 된다. 실제 지렛대는 **(칸,팔)당 표본 깊이**(같은
  `(case,seed)` 를 여러 `k` 로) 또는 **`n=1` 에 유한 `se` 를 주는 정책**이다.
  (이번 사이클에서 `dp_solve.py` 는 **고치지 않았다** — 메커니즘 명명이 산출물이다.)
- 🔴 **★ #4 의 7.7% → 19.3% 를 진전으로만 읽으면 안 된다 — 표의 행동 다양성이 매크로 하나로
  붕괴했다.** 새 표의 **확정 19칸이 전부 `Replace`**(구세대 17칸은 `SwapBattery 11 ·
  ReformTeam 3 · Replace 3`). 조회 성공 **291건도 전부 `Replace`** 이고 그 291건에서 canonical
  규칙의 선택도 전부 `Replace`(불일치 0). 귀결: **dp 판 210개가 canonical 210개와 완전히
  동일**하다(makespan·closed·complete·매크로 열). 대가는 이 브랜치 diff 안에 있다 —
  `artifacts_4pol/FINAL.md` 의 dp battery 매크로 정확도 **9% (11/120) → 0% (0/120)**,
  `SwapBattery×11 → 0`. 즉 **조회율을 행동 다양성으로 샀다.** 상세·재현: 결과 문서 §3-D.
- **1-step deviation 의 구성상 한계**: 결정 `k` 가 떨어진 칸만 다팔 관측을 얻고, `k` 밖(prefix ·
  꼬리)에만 도달하는 칸은 한 팔만 본다. `k` 는 `pick_k(case,seed)` 가 `n_hint=8` 안에서 흩뿌리고
  (case,seed) 조합이 84개라 deviation 지점도 최대 84곳이다. **#3 을 더 내리려면 `pick_k` 분포를
  바꿔야 하고 그건 재시뮬레이션이다.**
  ⚠️ **`--n-hint` 를 키우는 것은 방향이 반대다**(실측): 판의 결정 수 중앙값이 **9** 인데
  `n_hint=8` 에서 평균 `k` 가 이미 **4.7** 이고 84그룹 중 **20그룹이 미발화**다. 키우면 미발화가
  늘고 prefix-only 단일팔 영역이 커진다. 옳은 방향은 **같은 `(case,seed)` 를 서로 다른 `k` 로
  여러 번 굴려 표본 수를 늘리는 것** — 그게 `n=1` 자동 동점(위)도 같이 없앤다.
- **★ 배제는 꼬리에만 적용한다.** 발화한 판은 **전부** 자기 결정 `k` 행을 낸다 — 모든 판이 `k` 에서
  자기 팔을 강제하므로 그 행은 그 팔로 라벨된 고유 관측이고 그 행을 내는 판은 하나뿐이다.
  판을 통째로 배제하면 칸이 여러 팔을 보게 만드는 바로 그 관측이 사라진다(실측: 통째 배제 시
  전이 2045·(칸,팔) 130 → 꼬리만 배제 시 **2258·198**). 중복은 꼬리뿐이다(무집행 후 세계가 안
  바뀌어 NOOP 판 궤적을 되밟는다). 서로 다른 팔 라벨은 서로 다른 `(cell,arm)` 버킷에 들어가므로
  **팔이 갈린 행끼리는** `se = std/√n` 이 안 흔들린다.
  ⚠️ **그러나 "그러므로 `se` 팽창이 없다" 는 틀렸다 — 그 dedup 은 샌다.** 술어가 `enact_applied`
  인데 그건 "세계가 바뀌었다" 가 아니라 "효과 지점에 도달했다" 라, 분기를 타고 아무것도 안 바꾼
  판이 `"real"` 로 분류돼 꼬리를 전부 낸다. 실측: `"real"` 170판 중 **107판**이 다른 발화 판과
  바이트 동일한 꼬리를 내고, 꼬리 1521행 중 **601행**이 같은 `(case,seed)` 의 다른 판과
  `(cell,arm,c,next_cell,terminal_value)` 가 같은 여분 사본이다(중복군 370, 팔 조합
  `(0,2)·(0,2,4)·(0,4)·(3,7)`). **현행 표에 대한 영향은 0칸**(중복을 합쳐 다시 풀면 66칸 전부
  `a_star`·`unresolved_reason` 동일) 이라 재표집은 필요 없다 — 잔여는 `n`·`se` 의 과신이다.
  술어는 **넓히지 않았다**(표집 의미가 바뀐다). 상세: 결과 문서 §5-G · `sample_grid.py` 머리말.
- **★ `deviate_valid` 와 `enact_applied` 는 다른 것을 잰다 — 혼동하면 축이 통째로 샌다.**
  `deviate_valid` 는 메뉴 소속인데 `valid_macros` 가 `BatteryTruth`·`ZoneTruth` 에만 리스트를 주고
  **빈 배열 = 제한 없음**이 규약이라(`policy.jl:413`·`:460`) **fault·reform 에서는 언제나 true** 다.
  진실원은 `enact_applied`(집행 사슬이 실제로 분기를 탔는가)이고, **플래그를 각 분기의 내부 실행
  가드 안에서** 세워야 한다 — 분기 진입만으로 세우면 `ReformTruth`(필드 없는 struct)·`ZoneTruth`
  에서 `Replace`/`SwapBattery`/`Deprioritize` 가 아무 일도 안 하고 true 를 보고한다.
  ⚠️ `enact_applied=true` 는 "효과 지점에 도달했다" 이지 "세계가 바뀌었다" 가 아니다 —
  `ForbidZone`/`RelocateBuild` 의 `already_clear`, `ReformTeam` 의 `:error`+`:no_wedge` 는
  도달하고도 아무것도 안 바꾼다(**선행 결함**).
- **엔진 크래시 91판(15.5%) → 1판.** 판당 한 번만 집행되므로 `has_edge` 어서션 도달이 준다.
  ⚠️ **그러나 `ReformTeam` 축 완주율은 68.7% 로 최저**이고 이것이 #1·#2 미달의 실질적 원인이다
  (Replace·SwapBattery 는 100%). **엔진 결함으로 별도 작업에 올릴 것.**
- **비교표 4열**: dp 207 · canonical **207** · surrogate **198** · llm **203** — 세 실행 레인이
  2026-08-16 과 동일하다(= 세계가 안 바뀌었다는 통제). 표는 원자료에서 28칸+4합계 재검증했다.
  ⚠️ **DP 열은 canonical 과 "자릿수까지 같은" 정도가 아니라 판이 같다** — 210/210 조합에서
  makespan·closed·complete·매크로 열까지 동일. 흔히 적히는 "결정의 80.7% 가 canonical 폴백이라"
  는 **절반만 맞다**: 나머지 19.3%(조회 성공 291건)도 canonical 과 같은 매크로를 골랐다.
  **DP 열 부제를 "ceiling" 으로 되돌리지 않는다**(gap 83.5%).
- **★ 결정성 게이트의 강한 판은 n=1 이 아니라 n=84 다.** 발행된 게이트는 한 case/seed·결정
  5개짜리인데, 보존된 587판을 `(case,seed)` 로 묶으면 **84그룹 전부에서 일곱 개의 독립
  프로세스가 pre-`k` 결정 열을 바이트 동일하게 냈다(갈린 그룹 0).** 이 브랜치에서 가장 강한
  단일 결과다 — 재현 스크립트는 결과 문서 §5-A.
- ⚠️ **`objective.json` 이 2026-08-13 이후 커밋되지 않은 채 작업 트리에만 있었다.** 작업 트리가
  그 세대의 해시 값이라 이번 산출물은 올바르게 도장됐지만, 🔴 **깨끗이 체크아웃하면 결과가 "덜
  정확하게 재현" 되는 것이 아니라 재현 절차가 그냥 실패한다** — `dp_solve.py:499-504` 의
  `main()` 이 `sys.exit("표본의 objective_hash 가 현행과 다르다(구세대 표본)…")` 로 **하드
  스톱**(rc 1)해 결과 문서 §6 의 3단계에서 죽는다. `audit_objective.py` 의 `WARN(9-b)` 가 그
  전조다. ✅ **2026-08-16 해소: `cf63d760` 이 `objective.json` + `essential_tg_coponents.jl`
  (그 `generation` 이름이 가리키는 코드) + `RESULTS_D20` 해시 1줄을 함께 이력에 넣었고
  `WARN(9-b)` 가 닫혔다.** ⚠️ 그 커밋 자체가 남긴 교훈은
  `md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` **§5**(결과 문서의 절 번호이지 이 파일의
  절이 아니다)에 있다 — 그 diff 는 구세대 스윕 당시 **이미 작업 트리에서 살아 있었으므로**,
  그 커밋을 "세대를 가른 14 커밋" 후보에서 빼야 한다. **커밋된 SHA 만으로는 그 런이 실제로 쓴 목적함수를 식별할 수
  없다.**
- ⚠️ **`.venv` 에 pytest 가 없다.** `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest`
  로 돌린다(인터프리터는 `.venv` 유지). `dp_oracle/_sample_work/`(=`--keep-work` 산출, 2.4GB)는 gitignore.
  ⚠️ **pytest 로는 `test_deviation_plan.py` 만 잡힌다(30건).** `test_cost_decomposition.py` ·
  `test_dp_solve.py` · `test_cellkey_parity.py` 는 `def test_*` 가 없고 모듈 수준 `check()` +
  `sys.exit(1)` 로 게이팅하므로 pytest 에서 **0건**(`no tests ran`, rc 5)이다 —
  **인터프리터로 직접 실행할 것.** 두 파일을 pytest 한 줄에 묶어 `# 28 passed` 를 달면 충실성
  게이트가 돈 것처럼 보이지만 안 돈다.
- **★ 판 단위 완주 기록은 `dp_oracle/boards.jsonl`**(판당 한 줄, 168KB, 커밋됨). `_sample_work/`
  가 gitignore 라 판정 #1(86.0%)이 레포에서 검증 불가였고, `samples.jsonl` 로는 587판 중 467판만
  복원된다(82.4%, 팔별 분포도 다르다). 재시뮬레이션 없이 다시 내려면
  `sample_grid.py --manifest-only`.
- **★ 충실성 게이트는 출력 앞에서 친다.** 예전에는 `samples.jsonl` 쓰기와 `rmtree(work)` **뒤에**
  `sys.exit` 해서, 위반한 런이 **직전의 정상 표본을 덮어쓰고 진단용 판까지 지운 뒤** 죽었다.
  이제 위반이면 아무것도 쓰지 않고 아무것도 지우지 않는다(종료 코드·메시지 동일).
- **★ §8.7 gap 의 원인 문장을 하드코딩하지 않는다.** `sample_grid.gap_cause_note()` 가
  `samples.jsonl` 의 `sampling_mode`(`one_step_deviation` | `transition`)에서 유도하고
  `build_compare_table.py`·`fill_results_doc.py` 가 그것을 쓴다. 리터럴이었을 때 원인 ①(팔 메뉴)
  이 08-16 에 닫히고 ③(상수-팔 rollout)이 이 브랜치로 제거된 뒤에도 **헤드라인 아티팩트가 자기가
  없앤 전제를 계속 주장했다.** 지금 살아 있는 원인은 ② φ̃ 추상화 손실 · ④ deviation 칸 밖 단일팔.
- 신규 계약: `tools/monitor/test_deviation.jl`(5+4+7) · `dp_oracle/test_deviation_plan.py`(30 — 충실성 게이트 순서·판별 매니페스트 2건 추가).

### 2026-08-13 — 목적함수 통일로 또 한 번 세대가 갈렸다

`wm4spacecraft_manufacturing/objective.json` 이 목적함수 J 의 단일 진실원이고, `objective_hash()` =
**`19819377a7f8ebb2`**. 파일에 `generation` 필드(현재 `"2026-08-13-global-kappa-precedence"`)가 있고
해시에 들어간다 — **규칙: 스칼라가 하나도 안 바뀌어도 목적함수의 유효 의미가 바뀌면(플래너
재배선 포함) 반드시 올린다.** greedy(`GreedyEnergyAwareCost`) · MILP(전역 `AUTO_EFFICIENCY_KAPPA`) ·
오라클 라벨(`gen_oracle_mc.scalar_cost`) · Python 분석(`e1_analyze.cost_lex_key`) 이 전부 그 J 를
본다. 설계: `docs/superpowers/specs/2026-08-13-unified-objective-design.md`.

- **세대 판정 계약**: 산출물의 `objective_hash` 필드가 현재 `objective.json` 의 해시와 같은가.
  이 계약을 기계로 보던 `audit_objective.py` 는 2026-08-18 정리에서 삭제됐다
  (`git show 8e005842:wm4spacecraft_manufacturing/audit_objective.py`) — **계약은 그대로 유효하고
  검사만 없다.** 아래는 그 감사가 무엇을 봤는지의 기록이다 (exit 0 = **감사가 보는 것들**이
  일치. "소비처 전부"가 아니다 — spec §5.1 이 이름으로 지목한 6곳 중 이 감사가 실제로 검사하는 것은
  **5곳**이다: greedy `GreedyEnergyAwareCost`·MILP 전역 κ(둘 다 `essential_tg_coponents.jl` 검사로
  커버) · `gen_oracle_mc.jl` · `gen_oracle_dataset.jl` · `e1_analyze.py`. 나머지 `dp_solve.py` 는
  아직 레포에 존재하지 않는다(spec §8 단계 9). 그 밖에 감사가 보는 것: 목적함수 상수 리터럴 복붙
  12파일 스캔 · Julia/Python 해시 일치 · 스케일 null 여부 · 학습타깃 유예 표식 · 문서에 박힌
  해시·계약개수.)
- **기계적 계약**(앞의 넷은 2026-08-18 정리에서 삭제됐다 — 당시 측정치의 기록이다):
  `test_objective.py`(29/29) · `audit_objective.py`(9/9) · `test_surrogate_support.py`(7/7)
  · `audit_action_vocab.py`(6/6) · `test/greedy_cost_dispatch_equivalence.jl`(**살아 있는** 게이트 — 인프로세스
  포뮬러 동치 + 변경 전 함수의 축자 사본과의 인프로세스 A/B). `test/greedy_assignment_regression.jl`
  은 비게이팅 진단용으로 격하됐다 — 이유는 아래 Gotchas.
- **`verify.py` 는 이제 구세대 덤프(`graded_hs_n44.jsonl`·`n44_plus78.jsonl` 둘 다)에서 exit 1 로
  하드 스톱한다**(`ObjectiveError: 완주 런인데 energy_J 가 없다`) — 아래 Commands 절의 표를 이
  값으로 교체했다. **"8/8 PASS" 는 더 이상 어떤 기존 덤프로도 유효하지 않다.** 신세대 덤프(단계 6
  재실행 후)에서 기대값은 **6/8**(S1·S4 FAIL) — surrogate 가 아직 `closed − λ·MACRO_COST` 로
  학습돼 있는데 채점 기준은 `-J` 로 바뀌었기 때문이다. 둘이 닫히는 시점은 spec §8 단계 7(surrogate
  를 J 로 재라벨·재학습)이다.
- 같은 이유로 구세대 덤프에서 하드 스톱하는 것: `verify.py`(양쪽 덤프) · `firegrid_report.py` ·
  `build_md_report.py` · `test_llm7h.py` · `export_surrogate.py --cost-aware` · `cost_eval.py` ·
  MC 집계 · `tools/step6_gap.py`. 발행된 `md/RESULTS_*.md` 표 재생성은 그래서 세대 재구축(단계 6)
  에 게이트돼 있다. (`ladder.py` 는 이것과 무관한 기존 empty-glob `ValueError` 로 더 일찍 죽는다.)
- 이 날 이전의 모든 결과 문서(= `RESULTS_D20_2026-08-12.md` 포함)는 구세대다 — 🔴 배너 붙음.
- `ENERGY_OBJECTIVE=0` 으로 구세대 동작을 재현할 수 있다(끈 사실이 로그에 남는다).
- **세대 딱지를 찍는 산출 레인 3곳**: `tools/monitor/run_demo.jl`(`DEMO_SUMMARY` 레코드) ·
  `oracle/gen_oracle_mc.jl`(유닛 CSV 17·18열) · `oracle/gen_oracle_dataset.jl`(JSONL 라벨 행).
  전부 **`objective_hash` 와 `energy_objective`(0|1) 두 필드**를 낸다. 세대 키는 그 **쌍**이다:
  `ENERGY_OBJECTIVE` 는 플래너 손잡이라 `objective.json` 의 스칼라를 하나도 안 바꿔 해시로는
  껐는지 알 수 없는데, 끈 런은 다른 플래너 목적함수가 만든 것이라 세대가 실제로 갈린다.
  **해시에 접지 않은 이유**: 해시는 `verify.py`·`e1_analyze.py`·`step6_gap.py` 같은 **분석
  소비처**가 읽는 값이라, 생산자 손잡이를 거기 접으면 `ENERGY_OBJECTIVE=0 python verify.py`
  한 줄이 기존 덤프 전체를 조용히 구세대로 재분류한다.
  스케일 재교정(`measure_objective_scales.py`)이 그 쌍으로 **세대를 가른다** — 표본에 세대가
  둘 이상이면 exit 1 이고, `--generation current|none|<hash>|<hash>|eo=<0|1>` 로 하나를 고르거나
  `--allow-mixed` 로 명시적으로 섞어야 한다. 이 도구의 중앙값이 그대로 `objective.json` 의
  `M_ref`/`E_ref` 가 되므로, 여기서 섞이면 혼입이 상수에 각인된다.
  `read_units()`(MC 레인)도 같은 쌍으로 판정한다 — **`energy_objective` 열이 없는 옛 샤드는
  하드 스톱한다**(그 런이 ON 이었는지 OFF 였는지 기록이 없어 추정할 수 없다).
- **와이어링은 됐지만 아직 안 켜진 것**: `GreedyEnergyAwareCost` 는 존재하고 맞지만 **어느 레인도
  아직 고르지 않는다** — greedy 는 t=0 에만 도는데 그 시점엔 `AGENT_COST_BIAS[]` 가 비어 있고
  `EDGE_COST_MULTIPLIER[]` 가 `nothing` 이라, 항이 있어도 에너지·SoC·DeprioritizeAgent 정보 없이
  `dt` 를 0.075% 재스케일할 뿐이다. 그래서 **spec §6.2 는 아직 미이행**이고 **§6.3 은 절반만
  참**이다 — κ 는 전역으로 배선됐고, fault 재배정 경로(`fault_robot_and_reassign!` →
  `release_pending_assignments!`, `RESPEC_ENABLED=true` 오라클 레인에서 도달)에서 에너지 항이
  실제로 새로 살아 있지만, battery-SoC 가격 책정은 아직 부활하지 않았다(`rebalance_for_battery!`
  의 재풀이가 빌드 중간엔 후보 간선이 0개다).
- **알려진 한계 — 고치지 않고 기록한 것 (2026-08-13 최종 리뷰).** 아래 넷은 전부 "조용히 새는"
  종류라 반드시 알고 볼 것:
  1. **`n44_plus78.jsonl` 은 키를 고쳐도 대부분 채점 불가다.** `gen_oracle_dataset.jl` 이 이제
     행에 `energy_J` 를 낸다(예전엔 `total_energy_J` 라는 다른 이름만 내서 `J_row` 가 "구세대
     덤프다"라는 **틀린 진단**으로 멈췄다). 그러나 배터리 레이어(`_arm_battery!`)는
     `kind === :battery` instance 의 pre_sim 훅에서만 켜지므로 **fault/faultidle/zone/zoneharm/
     zoneblk/zonecore instance 의 `energy_J` 는 NaN** 이고, 그 행의 완주 J 는 여전히 정의되지
     않는다(= 라벨 격자의 대다수). 키를 고친 것이 데이터셋을 채점 가능하게 만들었다고 읽지 말 것.
     그 kind 들에 배터리 레이어를 켜는 것은 동작 변경이라 이 계획의 범위 밖이다.
  2. **네 번째 κ 가 `objective.json` 밖에 산다 — 활성화 지점 5곳.**
     `grep -n "set_planning_objective_weights!" tools/e2e.jl tools/demos.jl` 로 재확인한 목록:
     `tools/e2e.jl:685`(ENV `ENERGY_W`, 기본 0.01) · `tools/demos.jl:1123`·`:1288`·`:1586`
     (전부 `ENERGY_W`, 기본 1.0e-3, `demos.jl:1110` 에서 정의) · `tools/demos.jl:2759`
     (`ENERGY_W` 기본 0.01 을 그 자리에서 파싱). `get_objective_expr` 의 auto 경로는
     `w_eff == 0.0` 일 때만 도므로 **그 다섯 레인은 전역 κ 를 영원히 못 본다** — spec §4 의
     "κ 하나만 돌리면 세 곳이 같이 움직인다"가 거기서는 거짓이다. 범위 밖으로 남겼다.
     (`demos.jl:1420`·`:1748` 은 반대로 `efficiency = 0.0` 으로 **끄는** 자리다.)
  3. **surrogate 학습 목표는 아직 `closed − λ·MACRO_COST` 다**(채점은 `−J`). spec §8 단계 7 의
     재학습으로 닫힌다. `audit_objective.py` 항목 8 이 그 유예 표식을 기계로 지킨다.
  4. **`makespan` 의 `-1.0` 센티넬 (명명된 부채, CSV 재채점 전에 닫을 것).**
     `gen_oracle_mc.jl` 의 `append_unit!` 은 이제 한 `@printf` 안에서 **두 규약**을 쓴다 —
     `energy_J` 는 빈 필드(→ 되읽으면 NaN, `Objective.J` 가 설계대로 던진다), `makespan` 은
     아직 `-1.0`(→ 되읽으면 유한한 −1.0). 오늘 착취 경로는 **닫혀 있다**: `aggregate()` 는
     미리 계산된 `cost` 열만 평균하고, `read_units().makespan` 을 `Objective.J` 로 넘기는
     소비처가 없으며, `tools/step6_gap.py` 는 그 열을 읽지 않는다. 위험한 것은 **비대칭
     그 자체**다 — CSV 재채점(행에서 J 를 다시 계산하는 코드)이 들어오는 순간 이 버그가 되살아난다.
     `energy_J` 와 같은 2줄 스타일(`%s` + 빈 필드, `_parse_energy` 류 되읽기)로 닫을 것.
- **⚠️ 단계 6 1차 스윕(19:33 완료)은 이미 구세대다** — `generation=2026-08-13-energy-activation`
  (그 세대의 해시는 아래 결과 문서에 적혀 있다. 여기 옛 해시를 문자열로 다시 적지 않는다 —
  그 판정을 하던 `audit_objective.py` 항목 9 는 2026-08-18 정리에서 삭제됐지만 규약은 유지한다).
  같은 날 저녁 **배터리 물리 복구 + 전역 κ 우선순위**
  변경으로 세대가 또 갈렸다(아래). 1차 결과 문서
  `md/RESULTS_STAGE6_ENERGY_2026-08-13.md` 는 그 세대의 기록으로 남긴다 — 특히 §5.1
  ("battery case 가 물리적으로 무해했다")이 **이번 변경의 동기**이므로 지우지 않는다.
  1차 스윕은 210 샤드 ok 210/fail 0, 60분, 630행 전부 `energy_J > 0` 이었다.
  구세대 샤드는 `results_4pol_gen_energyactivation/`(1차) · `results_4pol_oldgen_2026-08-13/`(그 이전).

- **단계 6 2차 스윕 (2026-08-13 22:43) — 그 날의 현행이었다. 지금은 아니다.**
  (2026-08-17 정정 · 2026-08-16 갱신: 이 파일에 현행 표식이 **둘** 있었다. 현행은 언제나
  **맨 위 절 하나뿐**이고 지금은 2026-08-16 배송 절이다.
  이 절은 그 날짜 시점의 기록이다. 목적함수 세대는 여전히 같지만 코드 세대·결과 문서는 갈렸다 —
  아래 내용은 지우지 않는다. 배터리 물리·전역 κ 논증이 그 뒤 세대들의 전제이기 때문이다.)
  결과 문서는
  **`md/RESULTS_STAGE6_BATTERY_PHYSICS_2026-08-13.md`**. 210 샤드 **ok 210/fail 0**, 62분,
  630행 전부 해시 단일 + `battery_physics` 설정 단일. **정지 105행/126회.** 완주 388행 전부
  `energy_J > 0`.
  - **고친 것 (1차에서 드러난 결함):**
    (a) `run_demo.jl`·`render_demo.jl` 이 `enable_battery!` 만 부르고 `set_battery_stall!`/
    `set_battery_derate!` 를 안 불러 **방전이 로봇을 멈추지도 늦추지도 않았다** → 둘 다 켰다
    (threshold 0.15 · derate hi 0.5/min 0.35, **라벨러 `_arm_battery!` 와 같은 값**).
    (b) 용량이 `demo_battery_params(shrink=25)` 로 25배 축소돼 있었다(= 최대부하 5.5분짜리
    배터리) → **축소를 없앴다.** 스펙 2.3 kWh 는 최대부하 1000 W 에서 **2.30시간**이라 실제
    작업로봇과 맞다. 귀결: 자연 방전이 무시할 수준이 되어 **SoC 를 떨어뜨리는 것은 주입된
    OOD 뿐**이고, `battery_edge_multiplier` 도 평상시 정확히 1.0 이다.
    (c) `get_objective_expr` 의 auto 경로에서 `w_eff == 0.0 &&` 를 제거해 **전역 κ 가 레인별
    `ENERGY_W` 를 이긴다.** 단 그 5개 레인은 `init_objective_weights!` 를 안 불러 κ 가
    `nothing` 이므로 **당장 그 레인 숫자는 안 바뀐다**(미래 대비 + `demos.jl:1420·1748` 의
    의도적 OFF 가 κ 설정 시 덮인다는 점이 실효).
  - **battery case 가 드디어 정책을 가른다**: `noop` 30/30 완주 → **0/30**(정지 43회),
    `dspy` 는 30/30 유지(J 19.79). 예전엔 **"아무것도 안 하는 것"이 공동 1위**였다.
    정지는 배터리가 낀 case 에서만·`noop` 에서만 난다 — `surrogate`/`dspy` 는 전 case 정지 0회
    (방전 **전에** 개입해 예방한다).
  - **에너지 결정력 12/204 (5.88%)**, 오류 0 (1차에서는 15/204 = 7.35%).
  - **`n_stalled` 가 정지의 유일한 기계적 증거다.** 이 레인은 `run_demo.jl:472` 가
    `global_logger` 를 `Logging.Warn` 으로 심어 `battery.jl:297` 의 `[STALL]`(`@info`)이 통째로
    버려진다 — **"로그에 STALL 이 없다"를 "정지가 없었다"로 읽으면 안 된다.**
  - ⚠️ **surrogate 는 여전히 battery/fault/fault_battery 를 구분하지 못한다** — 세 case 에서
    완주 29/30 · 고유 makespan 23 · 중앙 J 23.26 이 **완전히 같다**(fault_zone·battery_zone 도
    서로 같다). 물리를 고친 뒤에도 남았으므로 **배터리 결함의 부산물이 아니라 surrogate 자체의
    결함**이다. 단계 7 이 겨냥할 지점.
  - ⚠️ **라벨러 레인은 아직 `DS_SHRINK=200`**(최대부하 41초짜리 배터리). 같은 물리 논증이
    그대로 적용되지만 고치면 `n44_plus78` 이 무효가 되므로 **단계 7 의 첫 항목**이다.
  - **스케일 재교정은 측정만 하고 적용하지 않았다**(신세대 `M_ref`=25.8625 · `E_ref`=111127.7,
    각각 −17.2% · −8.8%). **순환이기 때문이다**: 그 둘은 `objective_hash` 의 입력이라 쓰는 순간
    방금 만든 630행이 구세대로 재분류된다. 적용하려면 **재교정 + 재스윕**을 한 묶음으로 결정할 것.

### 2026-08-16 — 행동집합을 닫았다 — **직전 세대**

**직전 세대 결과 = `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`.** 이 절의 §4-B(표집 완주율이
안 올랐다)가 2026-08-17 작업의 동기다 — **지우지 않는다.**
목적함수 세대는 안 갈렸다(`objective.json` 무변경). 코드 세대는 `ff602d52`+`5dd29dae`.

- **무엇이 세대를 갈랐나**: 행동 어휘의 소비처 셋이 서로 다른 집합을 보고 있었다. 이제 전부
  `action_registry.json` 파생이다. 배포 라벨셋 = **`wm_datasets.RELABEL_20260816`**
  (872행/260 instance), support `{0,1,2,7,8}` → **`{0,1,2,4,5,6,7,8}`**.
  `test_surrogate_support.py` §B 가 그 계약이다(12/12).
- **★ `ood_mdp_shim.valid_actions` 는 팔 메뉴가 아니라 문지기다.** `action_to_proposal` 이
  `a in valid_actions(ctx) || return nothing` 으로 거른다 — fault 가 리터럴 `[0,1]` 인 한
  라벨 생성기에 매크로 4 를 시켜도 **조용히 NOOP 으로 무너진다.** 팔을 늘리려면 여기부터다.
  옛 고정 집합 재현은 `DS_ARMS_LEGACY=1`.
- **★ 라벨 레인은 `DS_HOTSWAP=1` 이어야 한다.** 실행 레인(`run_demo.jl:557`)이 hot-swap ON 이고,
  안 켜면 fault 대상 피커가 죽어 **발화율이 100% → 23%** 로 무너진다(실측). 발화율이 조용히
  떨어지는 형태라 로그만 보면 정상으로 보인다.
- **★ `maybe_emit_reform_ood!` 에는 dedup 이 없다.** 무진전이 이어지면 `REFORM_INTERVAL`(120)
  배수마다 재발화한다. 그래서 `gen_oracle_dataset.jl` 의 캐스케이드 예외
  `ctx.type === :reform && canonical` 이 조건 없이 걸려 있으면 **NOOP 팔 판에도 배경 정책이
  나중에 ReformTeam 을 집행해** 팔이 바이트 동일해진다. `kind !== :reform` 조건이 그 방어다
  (고친 뒤: 팔이 갈린 reform instance 1/7 → 17/27, completion flip 0 → 7).
- **§8.7 gap 은 87.6% → 89.3% 로 안 줄었다. 그러나 원인 구성이 바뀌었다.**
  Reform 축 **100% → 92.3%**(비교가 성립하는 축이 됐다) · Fault 81.8% → 75.8% ·
  Battery 82.7% → 92.3% · Zone 100% 유지. 원인 ①(행동집합 불일치) 해소, **③(상수-팔 표집)이
  혼자 남아 지배한다** — 표집 판 완주율 19.5% → 16.9%, V 중앙값 4418.6 → 4743.6.
  **다음 사이클 1순위 = 1-step deviation 표집.**
- **비교표 4열 (7 case x 30 seed)**: dp 207/210 · canonical **207**(2026-08-15 과 동일 = 세계가
  안 바뀌었다는 통제) · surrogate 190 → **198** · llm 198 → **203**.
- **조합 팔 5·6 은 정보량이 0이다** — 65/65 instance 에서 5≡4, 6≡2. 추가 primitive 가 엔진에서
  집행되지 않는다(`ForbidAgent` 는 집행 경로 없음, `ForbidWindow` 는 non-binding·commit 시 drop).
  `sample_grid.arm_menu()` 가 이 둘을 제외하고 **제외 사실을 이름으로 찍는다**. 다음 라벨
  생성에서는 `DS_COMBO_ARMS=0` 이 옳다.
- **`ForbidZone(3)` 은 라벨에 0행** — 이유가 바뀌었다. 메뉴가 아니라 **도메인이 비어 있다**
  (`n_restage_feasible == 0`, zone 160행 전부). `DS_FIRE_GRID` 에 20 을 넣어도 못 잡는다:
  트랙터가 첫 배치에서 ~58 노드를 닫고 재시도 사다리는 위쪽으로만 간다(실측 발화점 {46,58,250,…}).
- ⚠️ **`ReformTeam` 팔이 표집 판의 15.5% 에서 엔진을 죽인다**(`AssertionError: has_edge(...)`).
  표집 실패 13건이 전부 arm 4 였다 — Reform 축이 그만큼 얇게 표집됐다.
- ⚠️ **kind 상수정책이 NOOP→oracle 밴드의 97.7% 를 먹는다.** "모델이 상태를 보고 배웠다" 는
  주장은 이 라벨로 세울 수 없다. 상세는 결과 문서 §6-E.
- ⚠️ **라벨 레인의 재현성 결함은 살아 있다** — 08-14 와 겹치는 365행 중 4행이 다른 결과.
  표집 레인은 재현됐다(팔별 완주율이 다섯 팔 모두 소수점까지 일치).

### 2026-08-15 — DP 가 진짜 backward induction 이 됐다 — **직전 세대**

**직전 세대 결과 = `md/RESULTS_DP_BACKWARD_2026-08-15.md`.** §4-D 에 2026-08-16 의 결말이
한 줄로 이어져 있다.
아래 2026-08-14 절은 **직전 세대**다(지우지 않았다 — 두 세대를 나란히 놔야 §5-C 의 진단이
어디까지 맞았는지 보인다). 목적함수 세대는 안 갈렸다(`objective.json` 무변경).

- **무엇이 세대를 갈랐나**: `run_demo.jl` 이 결정마다 `sim_t_at`·`energy_at_J`·`closed_at` 을
  남긴다. 그것으로 구간 비용 `c_k` 와 다음 칸이 만들어져 `dp_solve.solve_backward()` 가
  Bellman 을 푼다. 구세대는 `solve_constant_arm()` 으로 **보존**돼 있다(비교용, 지우지 말 것).
- **분해 충실성 게이트가 이 작업 전체의 근거다**: 판마다
  `c_prefix + Σc_k + terminal == objective.J_row(row)`. 위반 시 `sample_grid.py` 가 exit 1.
  실측 420판 위반 0 · 최대잔차 3.6e-12. 합성 판 단위검사 = `dp_oracle/test_cost_decomposition.py`.
  ⚠️ **기준값을 `T + w_E·E_T` 로 직접 쓰면 게이트가 무력해진다** — 양변이 같은 `w_E` 를 써
  잔차가 항상 0 이 되고, 미완주 분기는 `terminal_value` 가 차액을 흡수해 통째로 무검사가 된다.
  `objective.J(complete=True, ...)` 를 **불러서** 기준을 받아야 한다(단위검사 T-06d 가 그 경계).
- **`c_prefix` 는 DP 가 쓰지 않는다**: `[0, t_1]`(첫 결정 이전)은 어떤 정책도 못 바꾸는 상수다.
  `c_1` 에 접으면 결정 이전 비용이 첫 팔에 귀속돼 Q 에 편향이 실린다. 분리하되 항등식에는 넣는다.
- **비교표 4열 (7 case x 30 seed)**: dp **209**/210 · canonical 207 · surrogate 190 · llm 198.
  실행 레인 세 열은 2026-08-14 와 **case 별 수치까지 완전히 동일** — 계측이 동역학을 안 건드렸다는
  기계적 증거다. dp 열만 바뀌었고 그건 `value.json` 이 바뀌었기 때문이다.
- **`dp` 열은 여전히 "천장" 이 아니다. 그런데 이유가 달라졌다.** §8.7 gap 89.3% → **87.6%**
  (106/121). 거의 안 줄었고, 원인이 셋으로 갈렸다(`dp_oracle/gap_breakdown.py`):
  ① **행동집합 불일치** — 표집 팔 메뉴는 배포 학습셋 지원집합 `{0,1,2,7,8}` 이라 `ForbidZone(3)`
  ·`ReformTeam(4)` 이 없는데, 실행 레인은 Reform 사건에서 `ReformTeam` 을 **1182회** 집행한다.
  Reform 축 gap 은 13/13 = 100% 이고 전부 여기서 나온다. 그 축은 **비교 자체가 성립하지 않는다.**
  ② φ̃ 추상화 손실(원 설계 §2.1 이 미리 인정한 대가). ③ **전이 표본이 여전히 상수-팔 rollout
  에서만 나온다** — 비용 분해는 결정 단위가 됐지만 표본을 만든 궤적은 판 전체가 한 팔이다.
  ③ 을 고치려면 1-step deviation 표집이 필요하고 그건 다음 사이클 거리다.
- **★ §8.7 gap 의 비교 단위가 솔버에 묶여 있다.** backward 의 `V` 는 **그 칸부터의 cost-to-go**
  라, 실행 정책도 같은 분해로 `J − c_prefix − Σ_{k<i} c_k` 를 뽑아 비교해야 한다. 판 전체 J 와
  대면 `V` 가 구조적으로 작아 gap 이 **100% 로 자동 발화**한다(측정이 아니라 단위 오류).
  `build_compare_table.py` 와 `fill_results_doc.py` 가 `value.json` 의 `solver` 필드를 읽어
  단위를 고른다 — 두 소비처의 규칙이 어긋나면 표와 문서가 갈린다.
  ⚠️ **그 "규칙" 에는 `dp_lane_swept` 가드도 포함된다**(`results_4pol/shards_dp` 존재 여부).
  `1bfbcaf8`·`7eddb629` 는 `build_compare_table.py:197` 에만 그 가드를 넣었고 형제인
  `fill_results_doc.py` 는 **빠뜨렸다** — 2026-08-16 에 같은 신호·같은 스타일로 맞췄다
  (`holes_section()` 의 세 블록: DP 커버리지 · §8.7 gap · 분해 충실성 주장).
  **둘 중 하나만 고치면 안 된다.** 그리고 이 판정은 **해시로는 못 한다** — 그 `value.json` 의
  `objective_hash` 는 현행과 같고 갈린 것은 코드 세대라, 쓸 수 있는 신호는 `shards_dp` 뿐이다.
- **`dp_solve._bucket()` 은 이름 규약이다**(2026-08-15 수정). 예전엔 "prog_b 는 cell key 의 첫
  성분" 이라는 **위치** 규약이었는데, 계층 백오프 L2 가 `prog_b` 를 덜어내면 첫 성분이 `soc_b`
  가 되어 솔버가 **SoC 를 진행도로 착각**한다. SoC 는 단조가 아니라 DAG 전제가 깨지고, 실측
  `backward_edge` 136 · `next_undefined` 580 이 나왔다. 이름으로 찾게 고치니 **dangling 716 → 0**,
  a\* 확정 11 → 18.
- **계층 백오프는 켜져 있다**(`value.json`). L0 만으로는 a\* 확정이 6칸(결정 가중 16.4%)뿐이라
  계획의 조건부 지시대로 켰다. 끈 표는 `dp_oracle/value_L0_nobackoff.json` 에 남겼다.
  역설적이지만 백오프가 gap 을 **줄인다**(L0 만 94.6% → 백오프 87.6%) — 정밀 칸에서 팔이
  하나뿐이라 비교가 없던 자리에 비교를 만들기 때문이다.
- **dp 레인이 표를 쓰는 비율은 낮다**: 결정 1202건 중 조회 성공 351(29.2%) ·
  `tie_unresolved` 469(39.0%) · `single_arm` 382(31.8%). tie 가 는 것은 단위가 바뀐 귀결이다 —
  판 전체 J 는 이봉분포(완주 ~20 / 미완주 ~15000)라 팔이 크게 갈렸지만 cost-to-go 는 종단
  벌점이 구간에 퍼져 격차가 SE 안에 든다. **옛 표의 a\* 39칸 중 29칸이 가장 거친 L2 였다.**
- 신규 계약: `dp_oracle/test_cost_decomposition.py`(차단 게이트) · `test_dp_solve.py` 에
  Bellman 검사 30건 추가 · `dp_oracle/gap_breakdown.py`(진단, 비게이팅).

### 2026-08-14 — 4정책 비교표가 나왔다 (라우터 3-way · DP 레인 · 화면의 목적함수) — **직전 세대**

**그 날의 결과 = `md/RESULTS_ROUTER3WAY_2026-08-14.md`.** (2026-08-17 정정 · 2026-08-16 갱신:
여기도 현행이라고 적혀 있었다 — 절 제목이 이미 **직전 세대**라 자기모순이었다. 현행은 맨 위
2026-08-16 배송 절이다.)
7 case x 30 seed x **4 policy = 840판**, 샤드 420/420 ok·fail 0, 세대 단일. 정책은
`canonical` · `surrogate` · `dspy` · **`dp`**(신규). 완주 합계 207 / 190 / 198 / 206 (/210).

- **여기서 읽어야 할 것은 완주율이 아니라 에너지다.** 세 사건이 겹친 case 에서 canonical 은
  30/30 완주하지만 62.7s·733 J/closed 를 쓰고, llm 은 28/30 을 32.3s·468 J 로 낸다.
  완주율만 보면 이 대비가 통째로 안 보인다.
- **`dp` 열은 "천장" 이 아니다.** 원 설계 §8.7 게이트가 실측에서 발화했다 — 실행 정책의 평균 J 가
  DP 의 V 보다 좋은 (칸,정책) 쌍이 **108/121 = 89.3%**. 원인은 V 가 **상수-팔** 표집에서 나오기
  때문이고(사건 셋이 섞인 판을 한 팔로 처리할 수 없다), 이 gap 은 `build_compare_table.py` 가
  표를 만들 때마다 다시 잰다. 단, dp **레인**은 칸마다 a* 를 갈아 쓰므로 **그 열의 실현 결과
  자체는 유효한 실행 결과**다. 천장이 아닌 것은 V 다.
- **surrogate 열이 약한 이유는 판단 오류가 아니다.** 배포 학습셋 `RELABEL_20260814` 의 macro
  support 가 `{0,1,2,7,8}` 이라 **ReformTeam(4)·ForbidZone(3) 행이 0줄**이고, reform 사건에서
  surrogate 는 NOOP 밖에 **고를 수가 없다**(`dspy_service.py:189`). 조합 case 붕괴(21/30)가 그것이다.
- **화면에서 목적함수를 볼 수 있다**: `server.jl` 의 `GET /objective` + 대시보드 OBJECTIVE 스트립이
  `objective.json` 을 **그대로 읽어** J 와 상수를 띄우고(복붙 금지), 결정마다 누적 에너지·κ·
  worst SoC 를 싣는다. **UI 는 `render_demo.jl` 을 쓴다**(`run_demo.jl` 이 아니다 — POST /run 도
  `regen_router_cases.sh` 도 그쪽이다).
- 신규 계약: `test_ceilings_degrade.py` · `dp_oracle/test_dp_solve.py` ·
  **`dp_oracle/test_cellkey_parity.py`**(Julia↔Python 칸키 동치, 13,720 경계 상태) ·
  `tools/monitor/test_narrate.jl` · `tools/monitor/test_lane_select.jl`.
- **라벨 재생성의 범위 정정**: surrogate 학습셋은 **이미 재라벨돼 있다**(365행 전부 `energy_J`,
  fault 110 · battery 135 · zoneblk 120). 남은 것은 **oracle 천장 격자**뿐이고 그것은
  `FINAL.md` 의 oracle 행에만 영향을 준다 — COMPARE 4열은 안 바뀐다.

**다음 작업(인계됨): `2026-08-15-dp-backward-induction`**(실행 완료·아카이브 —
`docs/superpowers/plans/README.md`) — DP 를 진짜
backward induction 으로 바꾼다. 계측(`sim_t`·누적 energy·closed 를 결정마다 기록)이 코드 세대를
가르므로 **네 열 전부 재스윕**이 필요하다(약 4~5시간). 그 계획서에 2026-08-14 에 실제로 데인
함정들(스윕 중 코드 수정 금지 · `xargs` 가 pkill 에서 살아남음 · dp 샤드는 별도 트리 · J 의 두
분기가 러닝 코스트가 다르다)이 Global Constraints 로 적혀 있다.

- **아직 안 한 것**: prefix 결정성 재측정(단계 8), oracle 천장 격자 재라벨,
  `reference_policy.py` 대체(원 설계 §8.6), surrogate 를 φ̃ 위에 재학습(원 설계 §9).
  - ~~단계 7 이 `build_final_table.py` 를 막고 있다~~ — **2026-08-14 해소.** 이제 J 를 계산할 수
    없는 행에서 죽지 않고 **미측정으로 낮춘다**(`compute_ceilings` + `test_ceilings_degrade.py`).
    다만 그 귀결로 **oracle 천장 행은 전 축이 미측정**이다: battery 18 · fault_current 22 ·
    zone 2 instance 가 **전부** J 채점 불가(`energy_J` 없음). 그 축들을 되살리려면 oracle 천장
    격자를 energy-only 모드로 재라벨해야 한다 — 배경은
    **`md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md`**(`battery.jl:486` 의 energy-only 모드는
    `enable_battery!` 만 켜고 stall/derate 는 끄므로 **동역학을 바꾸지 않는다**).
    ⚠️ 이것은 **COMPARE 4열을 바꾸지 않는다** — oracle 은 그 표에 없는 별도 행이다.

행동 어휘가 **2026-08-06** 에 바뀌었다: `action_registry.json` 이 매크로 **7(RelocateBuild)·8(SwapBattery)**
를 포함한다. 그 이전 측정치는 **행동집합이 잘린 상태**의 숫자다(zone 은 지원 팔이 `{NOOP}` 뿐이라
언제나 NOOP, battery 는 `SwapBattery` 미학습으로 적중 0/6). 두 세대가 섞여 있어 실제로 오판이
일어났기 때문에, 이전 세대 산출물을 **삭제**했다.

- **현행 배포 학습셋** = `oracle/out/n44_plus78.jsonl`. 계약: `support=[0, 1, 2, 3, 4, 7, 8]`
  (`test_surrogate_support.py` 가 7/7 로 지키던 것 — 그 검사는 2026-08-18 정리에서 삭제됐다).
  이게 "**행동 어휘** 세대인가"의 (이제 기계 검사가 없는) 판정이다 — **목적함수 세대**는 별개 축이다(위 `2026-08-13` 절의 `objective_hash` 계약을 볼 것).
  실제로 이 학습셋 자체가 목적함수 기준으로는 구세대다: `energy_J` 가 없어 `verify.py` 가
  하드 스톱한다(위 절 참조). 두 "세대"를 섞지 말 것 — 행동 어휘는 현행, 목적함수는 구세대다.
- **현행 측정 문서는 없다.** `md/RESULTS_D20_2026-08-12.md` 가 2026-08-12 시점(창고 거리
  기본값 `D=20.0`, 그 기하에서 재유도한 기준 정책 + 4지표 결과 행렬)엔 유일한 현행 문서였지만,
  **이 커밋(2026-08-13)에서 그 문서에도 🔴 구세대 배너가 붙었다** — 목적함수가 통일되며 플래너
  동역학이 바뀌었기 때문이다. `md/RESULTS_FARDEPOT_2026-08-12.md`(D=40) · `md/RESULTS_LLM7H.md`
  도 마찬가지로 🔴 배너가 붙어 있다. **결과 문서 전부가 구세대다** — 신세대 수치는 630판 스윕
  재실행(spec §8 단계 6) 뒤에야 나온다. 다른 md 의 수치를 현재 성능으로 인용하지 말 것.
- **삭제됨**: `oracle/out` 의 08-06 이전 런 전부(145MB→5MB), `artifacts_{mdp,assimilation,openworld,classifier}`,
  `figs/`, sweep_lab 리포트(LLM 프로그램 `.json` 만 잔존), 루트 `results/`, `docs/src/*_visualization.html`,
  `tools/monitor/{anim,streams,regen_case_logs}`, 구세대 모델 `surrogate_{linear,hotswap,v2}.json`.
  복원하지 말 것 — 필요하면 `gen_oracle_dataset.jl` 로 **현재 어휘에서** 새로 만든다.
- `openworld_merged.jsonl`(= `wm_datasets.CANONICAL`) 은 매크로 7·8 이전 라벨이지만 **novelty 교정용
  입력으로만** 남겼다(`tools/monitor/README.md` 2026-08-08 이 그 경로를 부른다). **성능 근거 아님.**
- **`audit_action_vocab.py` 의 "6/6 consistent" 는 검사 대상 6곳만 본다** — 그 밖의 복제본은 안 잡힌다.
  `tools/demos.jl` 의 두 surrogate 데모는 2026-08-09 에 리터럴을 없애고 `Demos.load_action_vocab()`
  으로 registry 를 직접 읽게 고쳤다(파생이라 감사할 복제본이 없다. 검증: `[0,1,2,3,4,7,8]`).
  아직 남은 리터럴은 `wm4spacecraft_manufacturing/assimilation_gate.py`(자체 검사 고정 입력, 동작 무영향).
- 알려진 실패(2026-08-09 정리 당시): `python verify.py oracle/out/n44_plus78.jsonl` → V0 PASS 후
  **S1 에서 `KeyError: 7`**. baseline 이 고른 팔이 그 instance 의 `vals` 에 없다. `norm_regret` 이
  baseline 의 선택 팔을 그 instance 의 `vals` 에서 찾지 못해 죽는다 — 7·8 을 포함한 덤프로
  harness 를 올리는 것이 남은 일이었다(이 문제 자체는 아직 안 고쳐졌다).
  **2026-08-13 목적함수 통일 이후로는 이 지점에 도달하지 못한다** — `verify.py` 가 그보다 먼저
  `ObjectiveError` 로 하드 스톱한다(구세대 덤프에 `energy_J` 가 없어서). 상세는 위 `2026-08-13` 절.

## Environment
- **`julia +lts` (1.10)** — `Manifest.toml` is pinned to 1.10.11; `Pkg.add` under a newer Julia silently breaks the build.
- Always pass `--project=.`.
- PyCall's interpreter must be the one `rvo2` is installed into (`ENV["PYTHON"]` / `CB_PYTHON`). See `PYTHON_SETUP.md`.
- Python stack = **`.venv/`(레포 루트)**, 즉 `/home/chahj578/Construction_OODlayer/.venv/bin/python`
  — **dspy 3.3.0**. (`venv/hjcrl` 은 존재하지 않는 경로다: 2026-08-13 정정.)
  데모/렌더 재현엔 `DSPY_URL` + `NOVELTY_CALIB`(repo 내 경로) 필요.
- **dspy 3.3.0 은 `import dspy` 시점에 `numpy` 를 lazy 프록시로 갈아 끼운다** — 그래서
  `src/respec/llm_service/dspy_service.py:44` 의 `import numpy, sklearn.ensemble` 는 `import dspy`
  **앞에** 있어야 한다(지우면 numpy 반쪽 초기화로 surrogate 로드가 죽고, 레인이 조용히 canonical
  로 폴백한다 — 커밋 `f43ad79` 가 고친 회귀다).

## Commands
```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'   # full test suite
julia +lts --project=. tools/demos.jl <key>         # also: tests|checks|restage|e2e|diagnostics|setup
julia +lts --project=. -i tools/dev_session.jl      # Revise REPL: t() re-checks, rebuild() re-builds env
# 매크로를 추가/수정한 뒤 어휘 6-소비처 일치를 보던 audit_action_vocab.py 는 2026-08-18 정리에서
# 삭제됐다 (git show 8e005842:wm4spacecraft_manufacturing/audit_action_vocab.py). 지금은 손으로
# action_registry.json 과 소비처를 대조할 것 — 누락은 에러 없이 성능으로만 샌다.
```
Key can also come from an env var (`DEMO=`, `TEST=`, ...), which takes precedence over `ARGS[1]`.

**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관).

`verify.py` 는 2026-08-18 정리에서 삭제됐다(`git show 8e005842:wm4spacecraft_manufacturing/verify.py`).
아래 표는 그 도구가 **삭제 전에 실제로 낸 결과의 기록**이다 — 인용할 때 인자를 반드시 같이 적을 것
(2026-08-13 재측정 — 목적함수 통일 이후 상태로 8/8 표는 더 이상 유효하지 않다):

| 명령 | 결과 |
|---|---|
| `python verify.py oracle/out/graded_hs_n44.jsonl` | **exit 1** — `ObjectiveError`(완주 런인데 `energy_J` 없음). 구세대 덤프라 하드 스톱 |
| `python verify.py oracle/out/n44_plus78.jsonl` | **exit 1** — 위와 동일 이유로 하드 스톱 |

**"8/8 PASS" 는 이제 어떤 기존 덤프로도 재현되지 않는다** — `graded_hs_n44.jsonl` 에서 예전엔
8/8 이 났지만, `verify.py` 가 이제 `objective.J`/`J_row` 를 거치므로 완주 런에 `energy_J` 가 없으면
(= 모든 구세대 덤프) 조용히 넘어가지 않고 죽는다(spec §5, §7). 신세대 덤프(spec §8 단계 6 재실행
후)에서 기대값은 **6/8**(S1·S4 FAIL) — surrogate 가 아직 `closed − λ·MACRO_COST` 로 학습돼 있는데
채점 기준은 `-J` 로 바뀌었기 때문이다. 둘이 닫히는 시점은 spec §8 단계 7(surrogate 재라벨·재학습).
그 외 기계적 계약(넷 다 2026-08-18 정리에서 삭제 — 당시 측정치의 기록):
`test_objective.py`(29/29) · `audit_objective.py`(9/9) · `test_surrogate_support.py`(7/7)
· `audit_action_vocab.py`(6/6, 커버리지 한계는 위 참조).

## Gotchas
- **`tools/*.jl` with no key runs a default silently** (`demos.jl` → `original_baseline`) instead of erroring. Read the `DEMOS` dict at the bottom of the file for valid keys.
- Behavior is driven by ~180 env-var knobs. Discover them, don't guess:
  `grep -rho 'get(ENV, *"[A-Z0-9_]*"' src tools | sort -u`
- Runtime `include` of navigator/battery modules must stay at module top level (world-age errors otherwise).
- **`tools/diagnostics.jl` does not load at all** — it top-level-`include`s the deleted `venv/decpomdp/examples/`, so every key fails before dispatch. Partial replacement: `wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl`.
- **비교 런은 순차 실행**(함정 30). 병렬이면 HiGHS가 다른 스케줄을 내 비교가 무효 + 프로세스당
  ~2.5GB라 OOM. 과거 "B-7 미완주"가 이 아티팩트였다(단독 실행 시 3/3 완주).
- 행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/action_registry.json`(리터럴 복붙 금지).
  누락은 에러 없이 성능으로만 샌다 — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을 갈랐다.
- LLM lane은 `DSPY_PROGRAM=__seed_only__`. 컴파일된 `dspy_real_program_gpt4o.json`은 battery 전용이라
  zone·RelocateBuild 어휘가 없다 — 그걸로 zone을 재면 어휘 밖 사건을 재는 것이 된다.
- `DSPY_URL` 포트는 레포에 6종이 흩어져 있다. 문서 숫자 말고 **띄운 uvicorn 포트**에 맞출 것.
- `_first_pending_assignment`는 "일감 유무"가 아니라 **"작업 경계"** — 중반 이후 조용히 틀림.
- 배포 surrogate 의 **매크로 지원 집합**은 학습셋이 정한다(`wm_datasets.N44_PLUS78`). 지원 밖 팔은
  에러 없이 후보에서 탈락해 **성능으로만** 샌다 — 그 계약을 지키던 `test_surrogate_support.py` 는
  2026-08-18 정리에서 삭제됐으므로 지금은 학습셋의 support 를 손으로 확인해야 한다.
- **컴파일을 다시 하면 배정이 재현되지 않는다.** 5회 반복 통제 실험에서, 바이트 동일한 소스가
  무관한 편집 후 재컴파일을 거치면 다른 배정 지문을 냈다(단, 한 번 컴파일된 상태 안에서는
  결정적이다). 따라서 **프로세스 간 golden-hash 비교는 코드 변경 검증 게이트가 될 수 없다** —
  차이가 코드 때문인지 재컴파일 때문인지 구분이 안 된다. 실제로 게이팅하는 것은
  `test/greedy_cost_dispatch_equivalence.jl`(인프로세스 포뮬러 항등성 + 변경 전 함수의 축자
  사본과의 인프로세스 A/B)이다. `test/greedy_assignment_regression.jl` 은 비게이팅 진단용으로
  남아 있다 — 실패해도 게이트가 아니다.
- **`@info` 가 프로세스 전역에서 조용히 사라진 적이 있었다.** `run_lego_demo` 가
  `global_logger(…, Logging.Warn)` 을 설치하고 복구를 안 해서, 첫 env 빌드 이후의 모든 `@info` 가
  안 찍혔다. 이 작업 도중 실제로 이걸로 오판을 냈다("폴백이 안 탔다" — 사실은 탔었다). `finally`
  블록에서 복구하도록 고쳤지만, 이 레포의 다른 진단 로직 중 "로그에 안 떴다"로 추론하는 것은
  아직 감사 안 됐다 — 의심하고 볼 것.

## Layout
- `src/respec/` — OOD → DSL re-spec layer (`spec_dsl.jl`, `compiler.jl`, `verifier.jl`, `llm_service/`)
- `src/safety/` — `cbf.jl`, `novelty.jl` · `src/mdp/` — `hazard.jl`, `mdp.jl` · `src/monitor/`, `src/navigator/`
- `wm4spacecraft_manufacturing/` — Python analysis stack (surrogate, drift, DSPy service)

## Docs

🔴 **2026-08-18 md 통합**: `wm4spacecraft_manufacturing/md/` 의 30개 문서가
**`md/README.md` 한 파일**로 들어갔다. **이 파일이 여러 곳에서 부르는
`md/RESULTS_*.md` · `md/STATUS.md` · `md/ARCHIVE.md` · `md/ORACLE_REBUILD_2026-08-09.md` 등은
이제 `md/` 에 없다** — 무엇이 어디로 갔고 어떤 SHA 로 꺼내는지는 `md/README.md` §9-A(코드가
이름으로 인용하는 문서 목록)와 §10(아카이브 색인)에 있다. 세대별 수치 자체는 §0(현행) ·
§0-Z(직전)로 흡수됐다.

- **`wm4spacecraft_manufacturing/md/README.md` — 현행 결과이자 재현·실험 전 필수 선독.**
  §0 현행 세대(3레인 × 7 case × 30 seed, 합계 210/189/205) · §0-Z 직전 세대 표 ·
  §1 용어(F vs OOD) · §5 데이터 스키마 · §6 완주 ≠ `closed==total` · §7 철회된 결론 ·
  §8 함정 43개 · §9 살아 있는 계약·재현 명령·재개 지점 · §10 아카이브 색인.
  세대 상세는 위 §★ 결과 세대.
- `wm4spacecraft_manufacturing/LABELING_MANUAL.md` — oracle labeling workflow
- 실행이 끝난 계획서는 `docs/superpowers/plans/README.md`(14개 아카이브),
  종료된 SDD 세션은 `docs/superpowers/SDD_SESSIONS_ARCHIVE.md`.
  설계 문서 `docs/superpowers/specs/` 7개는 안 내렸다 — 결정이 아직 유효하다.
- `tools/README.md` — fast iteration loops
- `src/SIMULATION_FLOW.md`, `RUN_GUIDE_KR.md`
