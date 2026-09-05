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

## 4. 결과 지표 (P6) — 사용자 결정: 완주가 아니라 에너지·마모

**PRIMARY: `energy_J[대상로봇]`** — 최종 프레임의 로봇별 누적 에너지.
- 왜: `_debit!` 이 적분하는 것이 `k_move·(m_robot + m_payload/|team|)·speed·dt` 라
  **payload 를 팀 크기로 나눈 몫이 이미 그 안에 있다**. `_battery_load_features` 의
  나누지 않은 proxy(120쌍 중 9쌍 역전)를 재유도할 위험이 없다.
- **잡음 바닥 = 0** [측정]: 이 디렉토리의 다섯 런이 `t=884, n_closed=287` 로 끝나면서
  로봇별 최종 SoC 가 **16자리까지 동일**했다. ⟹ **최소효과크기 문턱을 두지 않는다.**
  🔴 단 그 다섯 런은 **`DEMO_BSOC=0.45`** 다. 0.85 에서 잡음이 0 인지는 **이 런이 처음 잰다** —
  대조를 두 번 돌려 확인하고, 두 대조가 다르면 PRIMARY 판정을 보류한다(삼상의 `nothing`).
- **판정**: 처치의 `energy_J[대상]` 이 대조보다 **엄격히 작으면** 신호. 원 delta 와,
  idle 바닥(≈100W × dt × steps)을 뺀 가동 여지 대비 비율을 함께 보고한다.

**SECONDARY**: `soc_spread`(wear-leveling) · 함대 `total_energy_J`.
**가드레일 전용**: `t` / `n_closed`. 🔴 **헤드라인으로 쓰지 않는다.**

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
