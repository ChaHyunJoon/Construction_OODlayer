# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

## ★ 결과 세대 — 먼저 읽을 것 (2026-08-09 정리)

### ✅ 2026-08-17 — 표집을 1-step deviation 으로 바꿨다 (현행 세대)

**현행 세대 결과 = `md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md` + `artifacts_4pol/COMPARE.md`.**
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
  (구세대 `{1팔 27, 2팔 4, 5팔 2, 6팔 1, 7팔 15}`). **deviation 이 일어난 칸은 예외 없이 일곱
  팔을 전부 본다.** 남은 단일팔 23칸은 **전부 꼬리로만 도달하는 칸**이라 비교 대상이 원리적으로
  없다(그 한 팔은 `Replace 18 · ReformTeam 3 · NOOP 2` = canonical 이 고르는 매크로). 전이
  가중으로는 단일팔이 15.7%. deviation 행 447개는 일곱 팔에 64·64·64·64·64·64·63 으로 고르게 섞였다.
- **★ dp 레인의 `single_arm` 이 56.0% → 8.3% 로 무너졌다.** #4 가 50% 를 못 넘긴 것은 실패가
  **`tie_unresolved` 로 옮겨갔기** 때문이다(36.3% → **72.4%**). **그 tie 는 참이다** — 한 칸이
  일곱 팔을 다 보는데 그중 다수가 그 사건에서 실제로 no-op 이라 Q 가 진짜로 같다.
  **다음 사이클 1순위 = tie-break 규칙**(예: 동점이면 `MACRO_COST` 최소).
- **1-step deviation 의 구성상 한계**: 결정 `k` 가 떨어진 칸만 다팔 관측을 얻고, `k` 이후에만
  도달하는 칸은 canonical 한 팔만 본다. `k` 는 `pick_k(case,seed)` 가 `n_hint=8` 안에서 흩뿌리고
  (case,seed) 조합이 84개라 deviation 지점도 최대 84곳이다. **#3 을 더 내리려면 `pick_k` 분포를
  바꿔야 하고 그건 재시뮬레이션이다**(`--n-hint` 를 CLI 인자로 노출해 뒀다).
- **★ 배제는 꼬리에만 적용한다.** 발화한 판은 **전부** 자기 결정 `k` 행을 낸다 — 모든 판이 `k` 에서
  자기 팔을 강제하므로 그 행은 그 팔로 라벨된 고유 관측이고 그 행을 내는 판은 하나뿐이다.
  판을 통째로 배제하면 칸이 여러 팔을 보게 만드는 바로 그 관측이 사라진다(실측: 통째 배제 시
  전이 2045·(칸,팔) 130 → 꼬리만 배제 시 **2258·198**). 중복은 꼬리뿐이다(무집행 후 세계가 안
  바뀌어 NOOP 판 궤적을 되밟는다). 서로 다른 팔 라벨은 서로 다른 `(cell,arm)` 버킷에 들어가므로
  `se = std/√n` 은 영향받지 않는다.
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
  ⚠️ **DP 열은 전 case 에서 canonical 과 자릿수까지 같다** — 결정의 80.7% 가 canonical 폴백이라
  실현 궤적이 같아진다. 그 열이 좋아 보이는 것은 DP 가 잘해서가 아니다.
  **DP 열 부제를 "ceiling" 으로 되돌리지 않는다**(gap 83.5%).
- ⚠️ **`objective.json` 이 2026-08-13 이후 커밋되지 않은 채 작업 트리에만 있다.** 작업 트리가
  현행 세대 값이라 이번 산출물은 올바르게 도장됐지만, **이 커밋들을 깨끗이 체크아웃하면 결과를
  git 만으로 재현할 수 없다.** `audit_objective.py` 의 `WARN(9-b)` 가 그것이다. 별도 커밋 필요.
- ⚠️ **`.venv` 에 pytest 가 없다.** `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest`
  로 돌린다(인터프리터는 `.venv` 유지). `dp_oracle/_sample_work/`(=`--keep-work` 산출, 2.4GB)는 gitignore.
- 신규 계약: `tools/monitor/test_deviation.jl`(5+4+7) · `dp_oracle/test_deviation_plan.py`(28).

### 2026-08-13 — 목적함수 통일로 또 한 번 세대가 갈렸다

`wm4spacecraft_manufacturing/objective.json` 이 목적함수 J 의 단일 진실원이고, `objective_hash()` =
**`19819377a7f8ebb2`**. 파일에 `generation` 필드(현재 `"2026-08-13-global-kappa-precedence"`)가 있고
해시에 들어간다 — **규칙: 스칼라가 하나도 안 바뀌어도 목적함수의 유효 의미가 바뀌면(플래너
재배선 포함) 반드시 올린다.** greedy(`GreedyEnergyAwareCost`) · MILP(전역 `AUTO_EFFICIENCY_KAPPA`) ·
오라클 라벨(`gen_oracle_mc.scalar_cost`) · Python 분석(`e1_analyze.cost_lex_key`) 이 전부 그 J 를
본다. 설계: `docs/superpowers/specs/2026-08-13-unified-objective-design.md`.

- **세대 판정 계약**: 산출물의 `objective_hash` 필드가 현재 `objective.json` 의 해시와 같은가.
  `.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py` (exit 0 = **감사가 보는 것들**이
  일치. "소비처 전부"가 아니다 — spec §5.1 이 이름으로 지목한 6곳 중 이 감사가 실제로 검사하는 것은
  **5곳**이다: greedy `GreedyEnergyAwareCost`·MILP 전역 κ(둘 다 `essential_tg_coponents.jl` 검사로
  커버) · `gen_oracle_mc.jl` · `gen_oracle_dataset.jl` · `e1_analyze.py`. 나머지 `dp_solve.py` 는
  아직 레포에 존재하지 않는다(spec §8 단계 9). 그 밖에 감사가 보는 것: 목적함수 상수 리터럴 복붙
  12파일 스캔 · Julia/Python 해시 일치 · 스케일 null 여부 · 학습타깃 유예 표식 · 문서에 박힌
  해시·계약개수.)
- **기계적 계약**: `test_objective.py`(29/29) · `audit_objective.py`(9/9) · `test_surrogate_support.py`(7/7)
  · `audit_action_vocab.py`(6/6) · `test/greedy_cost_dispatch_equivalence.jl`(실제 게이트 — 인프로세스
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
  `audit_objective.py` 항목 9 가 CLAUDE.md 안의 옛 해시 인용을 **스테일 문서로 판정**한다).
  같은 날 저녁 **배터리 물리 복구 + 전역 κ 우선순위**
  변경으로 세대가 또 갈렸다(아래). 1차 결과 문서
  `md/RESULTS_STAGE6_ENERGY_2026-08-13.md` 는 그 세대의 기록으로 남긴다 — 특히 §5.1
  ("battery case 가 물리적으로 무해했다")이 **이번 변경의 동기**이므로 지우지 않는다.
  1차 스윕은 210 샤드 ok 210/fail 0, 60분, 630행 전부 `energy_J > 0` 이었다.
  구세대 샤드는 `results_4pol_gen_energyactivation/`(1차) · `results_4pol_oldgen_2026-08-13/`(그 이전).

- **✅ 현행 세대 = 단계 6 2차 스윕 (2026-08-13 22:43).** 결과 문서는
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

**현행 세대 결과 = `md/RESULTS_ROUTER3WAY_2026-08-14.md` + `artifacts_4pol/COMPARE.md`.**
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

**다음 작업(인계됨): `docs/superpowers/plans/2026-08-15-dp-backward-induction.md`** — DP 를 진짜
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

- **현행 배포 학습셋** = `oracle/out/n44_plus78.jsonl`. 계약: `python test_surrogate_support.py`
  → `support=[0, 1, 2, 3, 4, 7, 8]` (7/7 PASS). 이게 "**행동 어휘** 세대인가"의 유일한 기계적
  판정이다 — **목적함수 세대**는 별개 축이다(위 `2026-08-13` 절의 `objective_hash` 계약을 볼 것).
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
python wm4spacecraft_manufacturing/audit_action_vocab.py   # 매크로 추가/수정 후 필수 (exit 0 = 6/6)
```
Key can also come from an env var (`DEMO=`, `TEST=`, ...), which takes precedence over `ARGS[1]`.

**기대 baseline(실패 아님):** `Pkg.test()` = 11 pass / **1 error**(Gurobi 라이선스 없음, 변경과 무관).

`verify.py` 는 **어느 덤프로 돌리는지에 따라 결과가 갈린다.** 인자를 반드시 같이 인용할 것
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
그 외 기계적 계약: `test_objective.py`(29/29) · `audit_objective.py`(9/9) · `test_surrogate_support.py`(7/7)
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
  에러 없이 후보에서 탈락해 **성능으로만** 샌다 — `python test_surrogate_support.py` 가 그 계약이다.
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
- **`wm4spacecraft_manufacturing/md/README.md` — 재현·실험 전 필수 선독.** §1 용어(F vs OOD) ·
  §6 완주 ≠ `closed==total` · §7 철회된 결론 · §8 함정 35개.
- `wm4spacecraft_manufacturing/md/SUMMARY_FORBIDZONE_RETRAIN_2026-08-07.md` — **비전문가용 요약.**
  ForbidZone 발화 + surrogate 매크로 7·8 재학습 작업의 배경·원인·결과를 용어 설명부터 적었다.
  세부 수치는 RESULTS_LLM7H.md 를 볼 것.
- `wm4spacecraft_manufacturing/md/RESULTS_LLM7H.md` — 최신 측정(5시드×4정책) + 재현 절차
- `wm4spacecraft_manufacturing/md/STATUS.md` — current state / resume point
- `wm4spacecraft_manufacturing/LABELING_MANUAL.md` — oracle labeling workflow
- **`md/ORACLE_REBUILD_2026-08-09.md` — 두 문서가 한 파일에 있다(같은 CPU 를 다투므로 순서가 중요).**
  §I **평가 보강 계획**(baseline 사다리 B0~B9 · case별 격자 · STEP A~F 와 비용) →
  §II **오라클 라벨 재빌드**(= 그 계획의 STEP D). 2026-08-09 정리로 fault 축
  (`firegrid_merged.jsonl`)은 하드 크래시, zone 축(`zcausal_reform/`)은 **조용히 n=0** 이므로
  결과표를 재측정하기 전에 §II 대로 두 라벨셋을 먼저 복구할 것.
- `tools/README.md` — fast iteration loops
- `src/SIMULATION_FLOW.md`, `RUN_GUIDE_KR.md`
