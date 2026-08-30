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

"""
    routing_kind(type_name) -> String

`OODTruth` 구상 타입의 **이름**에서 라우팅용 kind 를 낸다. **전총이다** — 모르는 이름은
`"unknown:<이름>"` 이 되고 절대 알려진 kind 로 접히지 않는다.

🔴 왜 `ood_features` 의 `"kind"` 를 안 쓰나. 그 함수의 `else` 분기는 모르는 타입에 `"fault"` 를
준다(`policy.jl:199-200`). 그 값은 surrogate **피처**로는 옳다(모델이 그 열을 그렇게 배웠다).
그러나 **라우팅에 쓰면 정반대로 틀린다**: 처음 보는 사건이 `fault ∈ train_kinds` 를 타고
surrogate 로 간다. 피처용 유도와 라우팅용 유도는 **다른 것을 주장하므로 따로 둔다.**

🔴 왜 타입 객체가 아니라 이름 문자열인가. 이 파일은 **의존성 0** 계약 위에 있다(그래서 전수
단위검사가 된다). `CB.FaultTruth` 를 import 하면 그 계약이 깨진다. 대신 호출부가
`String(nameof(typeof(truth)))` 를 넘기고, 이름 기반 유도가 `ood_features` 의 `isa` 기반 유도와
알려진 셋에서 같은 값임을 `test/tool_choice_gate.jl` 의 교차 게이트가 못박는다 — 그것이 없으면
`FaultTruth` 개명 한 번에 라우터가 조용히 전 사건을 dspy 로 보낸다.
"""
routing_kind(type_name::AbstractString) =
    type_name == "BatteryTruth" ? "battery" :
    type_name == "FaultTruth"   ? "fault"   :
    type_name == "ZoneTruth"    ? "zone"    : "unknown:" * String(type_name)

"""
    select_lane(; kind, known_kinds, policy) -> (lane, axis, reason)

**kind 색인 라우터** (2026-08-29, §0-C 사용자 결정 1). 판정 입력이 하나다:
아는 kind → surrogate · 처음 보는 kind → LLM.

- `kind`        : `routing_kind(...)` 이 낸 값. 모르는 타입은 `"unknown:<타입이름>"` 이고
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
