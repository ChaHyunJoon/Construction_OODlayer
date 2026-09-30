# tools/monitor/lane_select.jl
# =============================================================================
# 라우터의 **레인 선택 분기표**. 순수 함수 하나뿐이고 의존성이 없다 — policy.jl 은 67KB 에
# ENV·ConstructionBots 의존이라 통째로는 단위검사가 안 되기 때문에, 판단 규칙만 여기로 뺀다.
#
# 🔴 [역사, 더 이상 현행이 아니다] 3-way 인 이유 (2026-08-14):
#   예전에는 타깃이 {surrogate, dspy} 뿐이었다. surrogate 가 그 팔을 지원하지 않으면 dspy 로만
#   에스컬레이션하고, dspy 가 죽어 있으면 조용히 canonical 로 떨어졌다 — canonical 이 사실상
#   세 번째 주자인데 판정에 안 적혀 있었다. 그래서 3-way 를 명시했다.
#   **2026-08-29 (T11) 에 그 3-way 는 사라졌다.** 조용한 canonical 폴백을 없앤 것이 §0-C 사용자
#   결정 3 이고(고른 레인이 실패하면 `error()` 로 시끄럽게 죽는다), 그 결정과 함께 `available`
#   인자가 통째로 빠졌다 — 가용성으로 레인을 바꾸는 것이 곧 조용한 폴백이기 때문이다.
#   `novel`(축 2)과 `supported`(축 1)도 같은 커밋에서 사라졌다: 판정 입력이 **kind 하나**다.
#   이 문단은 다음 사람이 낡은 모델을 들고 오지 않도록 남긴 역사이지 현행 서술이 아니다.
#
# DP 는 여기 없다(Global Constraint 10): DP 의 a* 는 오프라인 표집 + backward induction 의
# 산물이라 "결정 시점에 이미 표가 있다" = 그 사건을 미리 다 굴려봤다는 뜻이다. 실행 정책과
# 같은 줄에 세우면 비교가 무의미해진다.
# =============================================================================

# ---- 배터리 심각도 경계 (2026-08-30, 사용자 결정) --------------------------------------------
# `routing_kind` 가 battery 를 **아는 kind** 로 인정하는 경계다. `BatteryTruth.soc_after` 가 이
# 값 이하일 때만 `"battery"` 이고, 그보다 높으면 `"unknown:battery_mild"` 로 LLM 레인에 간다.
#
# 🔴 값의 근거는 **"SoC 가 90% 깎였는가"** 다. 그 정의는 그대로이고, 2026-08-31 부터 데모의
#    severe 프리셋은 `DEMO_BSOC=0.96` 으로 그 경계보다 **더 깊다**(soc_after ≈ 0.04).
#    옛 프리셋(0.9)은 soc_after 가 0.0994 라 경계 여유가 6e-4 였고, 정지 임계가 0.05 로
#    내려가면서 "확실히 정지한다"는 논증이 깨졌다 — 그래서 프리셋을 같이 옮겼다.
#    이 셋의 정합성은 `test/soc_ladder_is_coherent.jl` 이 지킨다.
#
# ⚠️ **대가 — 사용자가 알고 고른 것이다 (2026-08-30).** 오라클 학습셋(`oracle_dataset.jsonl`)의
#    battery 27행은 SoC 사다리 `{0.02: 9행, 0.30: 9행, 0.50: 9행}` 이다(실측). 이 경계에서
#    **18행(0.30·0.50 칸)이 `unknown:battery_mild` 쪽으로 간다** — surrogate 가 그 구간에서
#    매크로 3종 라벨을 전부 갖고 있는데 라우터는 "처음 보는 사건" 으로 취급한다.
#    🔴 그러므로 이 상수는 **"surrogate 가 학습한 범위"가 아니다.** 그것은 별개의 정의,
#    **"무엇을 심각하다고 부를 것인가"** 다. 둘을 일치시키려면 라벨셋을 severe 구간으로 다시
#    생성해야 하고(그러면 사다리가 이 경계 아래로 내려온다), 그 작업은 이 변경의 범위 밖이다.
#    ⟹ **`unknown:battery_mild` 비율을 "surrogate 가 못 배운 사건의 비율" 로 읽지 말 것.**
#    오늘 그것이 뜻하는 것은 "SoC 가 90% 미만으로 깎인 배터리 사건의 비율" 이다.
const ROUTING_SEVERE_SOC = 0.1

"""
    routing_kind(type_name, severity=nothing) -> String

`OODTruth` 구상 타입의 **이름**(과 battery 의 경우 심각도)에서 라우팅용 kind 를 낸다.
**전총이다** — 무엇을 넣어도 던지지 않고, 모르는 이름은 `"unknown:<이름>"` 이 되며 절대
알려진 kind 로 접히지 않는다.

🔴 **`"unknown:"` 접두사가 "이 사건은 LLM 레인" 의 단일 표식이다** (2026-08-30, 사용자 결정).
그 전에는 `zone` 이 접두사 없이 `"zone"` 을 내고 `zone ∉ known_kinds` 라는 **간접 경로**로만
LLM 에 갔다. 두 결과가 같아 보였지만 같지 않았다: `dspy_service._unfamiliar_block` 이 접두사
하나만 보므로 **zone 사건은 UNFAMILIAR EVENT 블록을 한 번도 못 받았다.** 이제 LLM 으로 가는
모든 kind 가 접두사를 진다 — 라우팅과 프롬프트가 같은 표식을 읽는다.

🔴 **battery 는 심각도로 갈린다** (2026-08-30). `soc_after ≤ ROUTING_SEVERE_SOC` 만 `"battery"`
이고 나머지는 `"unknown:battery_mild"` 다. 그 경계의 근거와 **대가**는 위 상수의 주석에 있다 —
인용하기 전에 읽을 것.
  · `severity` 가 유한한 실수가 아니면 `"unknown:battery_unmeasured"` 다. 🔴 `"battery_mild"`
    와 **일부러 다른 값**이다: "재 봤더니 완만했다" 와 "못 쟀다" 는 다른 사건이고, 후자를
    전자에 섞으면 계측 실패가 완만함으로 집계된다. 어느 쪽이든 LLM 으로 가는 것(안전한 방향)은
    같지만, 둘을 한 값으로 뭉개면 그 사실을 사후에 되찾을 수 없다.
  · 🔴 **`nothing` 에서 `"battery"` 로 떨어지지 않는다.** 못 쟀는데 아는 kind 라고 주장하면
    그 사건은 근거 없이 surrogate 로 간다.

🔴 왜 `ood_features` 의 `"kind"` 를 안 쓰나. 🔴 2026-09-07 정정: 여기 있던 근거 *"그 함수의
`else` 분기는 모르는 타입에 `"fault"` 를 주는데 그 값은 surrogate 행의 열로는 옳다 — 라우팅에
쓰면 처음 보는 사건이 `fault ∈ train_kinds` 를 타고 surrogate 로 간다"* 는 **두 번 낡았다.**
① 그 분기는 이제 `("unknown", nothing)` 이다(사용자 결정). ② surrogate 는 애초에 `kind` 를
안 읽는다 — `dspy_service._surro_row` 가 일부러 안 싣고 `descriptors_from_row` 는 계약상
`row['kind']` 를 절대 안 읽는다. 즉 "피처로는 옳다" 는 전제가 거짓이었다.

살아 있는 이유는 이것이다: `ood_features` 는 사건을 **자기 이름**으로 부르고(`zone` 은
`zone` 이다), 이 함수는 **레인 표식**을 단다. 두 유도는 다른 것을 주장하므로 따로 둔다.
⚠️ 갈리는 것은 결함이 아니라 **설계**이고 이미 배선돼 있다 —
`test/service_decide_ships_routing_kind.jl` (2)절이 같은 요청 본문 안에서
`kind="unknown"` · `routing_kind="unknown:MeteorTruth"` 가 함께 실리는 것을 못박는다.
2026-08-30 이후 battery_mild 와 zone 이 **그 이미 지원되는 사건의 두 번째·세 번째 사례**다:
`kind` 는 `"battery"`/`"zone"` 그대로이고 `routing_kind` 만 갈린다.

🔴 그리고 접두사를 판정의 원인으로 읽지 말 것. `select_lane`(아래)의 판정은
`kind in known_kinds` **집합 소속 하나뿐**이고 `"unknown:"` 을 보는 분기가 없다. 접두사는
표식의 통일이지 판정 기전이 아니다 — 실측 2026-09-07: 라벨셋(`oracle/out/oracle_dataset.jsonl`)
33행의 kind 는 `battery` 27 · `fault` 6 뿐이라 `"zone"` 은 접두사가 없어도 집합 밖이다.

🔴 왜 타입 객체가 아니라 이름 문자열인가. 이 파일은 **의존성 0** 계약 위에 있다(그래서 전수
단위검사가 된다). `CB.FaultTruth` 를 import 하면 그 계약이 깨진다. 대신 호출부가
`String(nameof(typeof(truth)))` 를 넘기고, 이름 기반 유도가 `ood_features` 의 `isa` 기반 유도와
알려진 셋에서 같은 값임을 `test/tool_choice_gate.jl` 의 교차 게이트가 못박는다 — 그것이 없으면
`FaultTruth` 개명 한 번에 라우터가 조용히 전 사건을 dspy 로 보낸다.
"""
routing_kind(type_name::AbstractString, severity = nothing) =
    type_name == "BatteryTruth" ? _battery_kind(severity) :
    type_name == "FaultTruth"   ? "fault"                 :
    type_name == "ZoneTruth"    ? "zone"                  : "unknown:" * String(type_name)
# 🔴 2026-09-29 (selfimprove U1, 사용자 결정): zone 은 다시 접두사 없는 `"zone"` 이다 — 위
#    docstring 의 "LLM 으로 가는 모든 kind 가 접두사를 진다" 를 **zone 에 한해** 뒤집는다.
#    `"unknown:zone"` 은 `known_kinds` 에 원리상 없으므로 zone 을 학습해도 surrogate 로 못 간다.
#    학습 전에는 `"zone" ∉ known_kinds` 로 여전히 dspy 다(v0 레인 불변). 프롬프트의 낯섦 문단은
#    같은 날 `dspy_service._unfamiliar_block` 이 접두사 대신 `surro_kinds` 소속으로 판정하도록
#    바꿨다 — 그래서 v0 zone 프롬프트는 바이트 동일하다.

"""`DEFER:<axis>[:…]` → axis, 그 밖은 `nothing` (selfimprove spec §5.3).
`UNSUPPORTED:` 는 격상 대상이 아니다 — 도장·어휘 불일치라 §0-C 결정 3 대로 계속 죽는다."""
defer_axis(raw::AbstractString) = startswith(raw, "DEFER:") ? String(split(raw, ":")[2]) : nothing

# battery 한 종류만의 심각도 분할. 위 삼항식 안에 인라인하면 세 갈래가 한 줄에 겹쳐 읽히지
# 않으므로 뺐다. 🔴 `isfinite` 를 먼저 본다 — `NaN <= x` 는 조용히 `false` 라서, 이 검사가
# 없으면 NaN 이 "완만함" 으로 집계된다(`reference_policy.py:191` 이 같은 함정을 적는다).
_battery_kind(severity) =
    (severity isa Real && isfinite(severity)) ?
        (severity <= ROUTING_SEVERE_SOC ? "battery" : "unknown:battery_mild") :
        "unknown:battery_unmeasured"

"""
    select_lane(; kind, known_kinds, policy) -> (lane, axis, reason)

**kind 색인 라우터** (2026-08-29, §0-C 사용자 결정 1). 판정 입력이 하나다:
아는 kind → surrogate · 처음 보는 kind → LLM.

- `kind`        : `routing_kind(...)` 이 낸 값. 🔴 **`"unknown:"` 으로 시작하는 값이 곧 LLM
                  레인이다** (2026-08-30) — 미지 타입뿐 아니라 `unknown:zone` ·
                  `unknown:battery_mild` · `unknown:battery_unmeasured` 가 전부 그렇다.
                  이 함수는 그 접두사를 **특별 취급하지 않는다**: 집합 멤버십 하나로 갈리고,
                  접두사가 붙은 값은 `known_kinds`(피처 kind 이름들)에 원리상 없기 때문에
                  자동으로 dspy 로 간다. 모르는 타입은 `"unknown:<타입이름>"` 이고
                  **절대 알려진 kind 로 접히지 않는다**(§0-C 충돌 ①).
- `known_kinds` : surrogate 가 **학습셋에서** 본 kind 집합. `/health` 의 `surro_kinds` 에서
                  온다. 🔴 `nothing` = **못 쟀다** → 고르지 않고 **에러로 죽는다**.
                  `Set(String[])` = 쟀는데 비었다 → 전부 dspy(다른 사건이다, 삼상 규약).
- `policy`      : DEMO_POLICY. `"noop"` 이면 라우팅하지 않는다(통제 바닥선).

`axis ∈ {"control", "known_kind", "ood_kind"}` — 어느 조건이 판정을 냈는가를 데이터로 남긴다.
🔴 옛 enum(`vocabulary_gap`/`novelty`/`none`)은 **소멸했다**(§0-C 충돌 ⑤): 축 1 은 kind 축으로
대체됐고 축 2(novelty)는 삭제됐다. 두 축의 겹침을 재던 R5 도 잴 대상이 없어져 소멸한다.

🔴 왜 `available` 이 없나. 가용성으로 레인을 바꾸는 것이 곧 **조용한 canonical 폴백**이고,
§0-C 사용자 결정 3 이 그것을 없앴다. 고른 레인이 그 사건에서 실패하면 호출부(`decide_all`)가
`error()` 로 죽는다 — 산출물이 "라우팅했다" 고 주장하면서 규칙표가 돈 행을 섞어 담지 않도록.

🔴 왜 못 쟀을 때 죽나. `nothing` 에서 한쪽으로 떨어지면 그 런의 모든 행이 근거 없이
"라우팅했다" 로 기록된다. 서비스가 죽었는지 도장이 갈렸는지(`/health` 의 `surro_kinds: null`)
를 여기서 구별할 수 없으므로, 구별할 수 있는 사람에게 되돌린다.

🔴 반환 순서는 `(lane, axis, reason)` 다 — 아래 모든 `return` 이 그 순서로 조립한다.
NamedTuple 이라 이름으로 읽는 호출부는 무사하지만, **위치 분해**(`lane, reason, axis = …`)를
쓰면 축과 산문이 조용히 뒤바뀐다.

`reason` 은 화면 ROUTER 줄에 그대로 나가므로 영어로 쓴다(이 저장소의 화면 문구 규약).
"""
function select_lane(; kind::AbstractString, known_kinds, policy::AbstractString)
    # noop 은 후보가 아니라 통제 실험의 바닥선이다. 개입이 실제로 이득인지 재려면 아무도
    # 이 레인을 대신 판단해 주면 안 된다. 🔴 `known_kinds` 검사 **앞**이다 — 통제 런은
    # 판정 자체를 안 하므로 서비스가 죽어 있어도 죽으면 안 된다.
    policy == "noop" && return (lane = "noop", axis = "control",
        reason = "no-adapt floor — routing disabled for this control lane")

    known_kinds === nothing && error(
        "[router] surrogate kind support is unknown — refusing to route. " *
        "Is the DSPy service up, and does /health carry surro_kinds?")

    kind in known_kinds && return (lane = "surrogate", axis = "known_kind",
        reason = "the surrogate was trained on '$(kind)' events → surrogate")

    return (lane = "dspy", axis = "ood_kind",
        reason = "'$(kind)' is outside the surrogate's training kinds → escalate to LLM")
end
