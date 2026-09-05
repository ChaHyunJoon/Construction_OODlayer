# 사전등록 — 넷째 유료 런 (2026-09-04)

🔴 **이 문서는 결과를 보기 전에 쓴다. 결과를 보고 술어를 고치지 않는다.**
BASE `b62133b4`. 이전 판: `2026-09-04-ladder-run2-preregistration.md`.

## 0. 이 런이 이전 셋과 다른 점

| # | 무엇 | 커밋 |
|---|---|---|
| 1 | **재배정 동사가 광고된다** — `release_pending_assignments!` 가 `FUNCTIONS YOU CAN CALL NOW` 에 실린다 | `b3a62982` |
| 2 | `/rewrite` 실패가 **사유를 나른다**(첫 줄만 찍던 절단 제거) | `bca635f1` |
| 3 | 프레임에 **에너지 축**이 실린다(`total_energy_J`·`soc_spread`·로봇별 `energy_J`) | `c0cff8f3`+`b62133b4` |
| 4 | 🔴 **사건 강도가 바뀐다: `DEMO_BSOC` 0.45 → 0.85** | 아래 §1 |

## 1. 🔴 사건 설정 변경의 근거 (Ruling P6)

`tools/monitor/streams/tractor__none.jsonl`(사건 없음) vs `tractor__battery_mild.jsonl`(mild 주입)이
**18프레임 전부 동일**하다 — `t`·`n_closed` 같고 **로봇 위치 324/324 일치, 차이 0건** [측정].
음성 대조: `none` vs deep `tractor__battery.jsonl` 은 프레임 13부터 갈라진다.

⟹ **`DEMO_BSOC=0.45` 의 mild 사건은 세계에 아무 영향이 없었다.**
원인: `set_battery_derate!(hi=0.5, min_factor=0.35)`. `DEMO_BSOC` 는 **뺄셈**이라
0.999855 → **0.549786**, 즉 derate 문턱 0.5 **바로 위**라 속도 계수가 **정확히 1.0** 이다 [측정].
🔴 그런데 프롬프트의 mild 자연어는 모델에게 "정상보다 느리게 움직인다" 고 말해 왔다.

**실측 속도 계수**(`_soc_speed_of`): soc 0.4 → 0.856 · 0.15 → 0.494 · 0.1 → 0.422.
`DEMO_BSOC=0.85` ⟹ soc ≈ **0.150** ⟹ 계수 ≈ **0.494(반속)**, 그리고 여전히
`> REPLACE_SOC_THRESHOLD = 0.1` 이라 mild 다. 지속 드레인은 ~1.1e-6/step × ~900 ≈ 0.001 이라
deep 으로 안 넘어간다.

🔴 **런 무효 조건**: 로그의 `routing_kind` 가 `"unknown:battery_mild"` 가 **아니면** 이 런은
무효다. `"battery"` 면 surrogate 로 샌 것이고 아무것도 안 잰 것이다. **결과를 채점하지 않는다.**

## 2. 사다리 술어 — 결과를 보기 전에 고정

채점은 `tools/monitor/ladder_report.py` **로만** 한다. 손인용 금지.
삼상 규약: `nothing` = 못 쟀다 · `false` = 쟀는데 거짓 · `[]`/`0` = 쟀는데 비었다.

| 칸 | 술어 | 비고 |
|---|---|---|
| L0 | `wrote == true` | |
| L1 | `registered == true` | |
| L2a | `args_from == :calls` | |
| L2b | `steps[1].status === :success` | 🔴 `!== nothing` 으로 되돌리지 말 것 — 옛 술어는 `:threw` 로도 충족돼 거짓 명제가 초록으로 읽혔다 |
| L3 | `interface_calls ≠ []` | |
| L4 | `world_delta_body` 의 다섯 축 중 **하나라도** ≠ 0 | 축: `closed`·`active`·`n_edges`·`n_binding_changed`·`n_weights_changed` |

## 3. 이 런에서 새로 고정하는 술어

**R-A (조합)**: `interface_calls` 에 `"release_pending_assignments!"` 가 **있는가**.
- 있으면: 모델이 새로 광고된 동사를 **골랐다**.
- 없으면: 광고했는데 **안 골랐다** — 이것은 실패가 아니라 **측정된 사실**이고 그대로 보고한다.

**R-B (조합 부담)**: body 가 `build_invariant(env)` 를 **스스로** 불렀는가.
`release_pending_assignments!` 의 둘째 위치인자는 `InvariantSpec` 인데 주조 규약 1 은 위치인자를
`env` 하나로 제한한다 ⟹ body 가 invariant 를 **직접 만들어야** 한다.
🔴 산출물이 그 인자에 `missing: InvariantSpec` 을 달고 `argpaths` 가 **비어 있다**(일부러 안 메웠다).
이것을 모델이 잇는지가 이 런의 조합 시험이다.

**R-C (재풀이)**: 결정 행의 `surface` 값이 `"sched"` 또는 `"milp"` 인가.
🔴 `_resolve_if_needed!` 는 그 둘일 때만 `resolve_assignments!` 를 부른다. 다른 값이면
**재풀이가 안 돌고** `binding`/`n_edges` 축이 안 움직인다 — 그러면 L4=0 은 모델의 실패가 아니라
**surface 선택**의 귀결이다. `PHYSICAL_PRINCIPLES` 가 "AFTER EVERY TOOL BODY" 라고 **거짓말**을
하고 있으므로(컨트롤러 판정: 이번 런에서는 안 고친다) 이 축을 반드시 따로 읽는다.

**R-D (접지)**: `steps[1].status` 가 `:unknown_agent` 인가.
그렇다면 body 는 돌았지만 **아무 로봇도 못 짚었다** = 조용한 무동작이다.
🔴 이것을 L2b 초록과 혼동하지 말 것 — `:unknown_agent` 는 예외가 아니다.

## 4. 결과 지표 (P6) — 사용자 결정: 완주가 아니라 "가장 낮은 SoC 를 얼마나 높게 지켰나"

**사용자 정식화(2026-09-05)**: *"mild 로는 build 가 안 깨지는 게 맞다. 대신 최종 시점에 가장 낮은
battery SoC 가 얼마나 높게 유지되는지를 비교하면, build 가 안 깨져도 SoC 가 낮아진 로봇을 얼마나
아꼈는지로 평가가 된다. 그게 낮은 SoC 로봇을 최대한 가벼운 payload 에 배정한 결과일 테니까."*

### HEADLINE: `min_soc` (최종 프레임) — 그리고 그것은 `energy_J[대상]` 의 충실한 변환이다

🔴 **실측으로 확인했다** (대조 런 `results/ctrl-bsoc085.log`, 사건 후 18개 구간 전부):
SoC 낙차가 에너지 부담에 **거의 정확히 비례**한다.

| 구간 | ΔenergyJ[R1] | Δsoc[R1] | Δsoc/ΔE |
|---|---|---|---|
| t 351→401 | +381.2 | −4.6e-5 | 1.21e-7 |
| t 701→751 | +311.4 | −3.7e-5 | 1.19e-7 |
| 사건 후 전체 (t 151→1024) | +6396.7 | −7.73e-4 | **1.208e-7** |

⟹ `min_soc` 과 `energy_J[대상]` 은 **같은 물리량의 다른 단위**다(오차 ~1%).
`energy_J` 쪽이 해상도가 4자릿수 높고, `min_soc` 쪽이 해석이 쉽다. **둘 다 보고한다.**

### 🔴 효과 크기를 미리 못박는다 (결과를 보고 놀라지 않기 위해)

대조 실측: 주입 직후 `soc = 0.149803`(t=151), 최종 `min_soc = 0.14903`(t=1024).
⟹ **사건 후 대상 로봇이 실제로 쓴 것은 `0.000773 soc` 뿐이다.**

| tool 이 대상의 사건 후 부담을 | 최종 `min_soc` |
|---|---|
| 0% 줄임 (= 대조) | 0.149030 |
| 30% 줄임 | ≈ 0.149262 |
| 50% 줄임 | ≈ 0.149417 |
| 100% 줄임 (유휴 상한) | ≈ 0.149803 |

숫자가 **소수 넷째 자리**에서 움직인다. 잡음 바닥이 **정확히 0** 이므로 이것은 깨끗한 신호지만,
🔴 **발표에서는 절대값이 아니라 척도 무관한 양으로 말한다**:
> **"사건 후 대상 로봇의 에너지 부담을 N% 줄였다"**, `N = 1 − ΔE_처치 / ΔE_대조`
> (ΔE = 사건 프레임 이후의 `energy_J[대상]` 증분. 런 전체 누적이 아니다 — 사건 **전** 구간은
> 두 런이 정의상 같으므로 포함하면 N 이 희석된다.)

### 판정 (삼상)
- **못 쟀다** = 최종 프레임에 `energy_J`/`min_soc` 키가 없다, 또는 body 가 던져 세계를 안 건드렸다.
- **쟀는데 0** = 처치와 대조의 `min_soc` 이 같다(잡음 0 이므로 완전 일치여야 한다).
- **쟀는데 개선** = 처치의 `min_soc` 이 **엄격히 크다**. N% 와 원 delta 를 함께 적는다.
🔴 처치의 `min_soc` 이 대조보다 **작으면** 그것도 보고한다 — tool 이 상황을 악화시킨 것이다.

### SECONDARY
- `energy_J[대상]` 사건 후 증분 (위 N 의 분자·분모)
- `soc_spread` (wear-leveling) · 함대 `total_energy_J`
- **가드레일 전용**: `t` / `n_closed`. 🔴 헤드라인으로 쓰지 않는다.

### ⚠️ 이 지표가 못 보는 것
`min_soc` 은 **대상 로봇 하나**에 고정돼 있다(다른 로봇은 ~0.95 이상). 그래서 이것은
"함대가 고르게 마모됐나" 가 아니라 **"가장 약한 로봇을 아꼈나"** 를 잰다 — 사용자가 물은 것이
정확히 후자다. 함대 축은 `soc_spread` 와 `total_energy_J` 가 본다.

## 5. 🔴 완주 판정식 — `closed == total` 이 아니다

[측정] **완주한 런이 `n_closed=287` 인데 계기는 `n_total: 305` 라고 적는다.**
그리고 `max_time_steps` 로 끝나는 경로에서는 `PROJECT INCOMPLETE!` 도 `error` 도 **안 찍힌다**
(그 프린트가 `if project_stop_bool` 안에 있다).
⟹ 완주 판정은 로그의 `PROJECT COMPLETE!` **문자열 존재**로 하고, `closed/total` 비율로 하지 않는다.
`No progress for 3000 iterations` 는 미완주 신호다.

## 6. 과금

사용자 결정: **상한 없음**. 그래도 처치 런은 **한 판**만 돌리고 결과를 적은 뒤 다음을 판정한다.
⚠️ `/health` 의 `calls` 는 과금 계수기가 **아니다**(캐시 히트도 센다). 서비스는 `DSPY_CACHE=0` 으로 띄웠다.

## 7. 레시피

```bash
# 대조 (무료, 8078 = TOOL_SYNTHESIS 없음) — 이미 돌렸다: results/ctrl-bsoc085.log
# 처치 (유료, 8077)
env REQUIRE_TOOL_SYNTHESIS=1 \
    DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.85 DEMO_CASE_TAG=battery_mild \
    DEMO_BATTERY_STEPS=40,120 DEMO_POLICY=dspy DEMO_ANIM=0 DSPY_URL=http://127.0.0.1:8077 \
    julia +lts --project=. tools/monitor/render_demo.jl > results/run4-treatment.log 2>&1
```
- 🔴 `REQUIRE_SYNTH_MULTI_AGENT` 는 켜지 않는다 — 어떤 레인도 안 읽어서 옳은 런이 FAIL 로 죽는다.
- 🔴 처치·대조는 **같은 디렉토리에서 순차로**. 병렬이면 HiGHS 가 다른 스케줄을 낸다(+프로세스당 ~2.5GB).
