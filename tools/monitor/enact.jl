# =============================================================================
# enact.jl -- 매크로 집행 사슬 하나. `run_demo.jl` 의 `handle_ood!` 안에 인라인으로 있던
# 블록을 **그대로** 옮긴 것이다(2026-08-29, Plan B / T2, 커밋 1 = 순수 이동).
#
# 왜 옮겼는가 (컨트롤러 판정 R5)
# ------------------------------
# `run_demo.jl` 은 최상위에서 데모를 통째로 돌리는 **스크립트**다(파일 끝이
# `println("[run_demo] DONE ...")` 이고 가드가 없다). 그래서 테스트가 include 할 수 없고,
# 사슬이 거기 있는 한 T2 의 게이트는 **생산 코드를 한 줄도 태울 수 없다** — 순수 함수만 재는
# 게이트가 되고, 그건 Plan A 가 이미 밟은 결함이다("실패할 수 없는 게이트").
#
# 🔴 **이 파일은 최상위 부작용이 없다.** 함수 정의뿐이다 — 테스트가 `using ConstructionBots`
# 뒤에 include 할 수 있어야 하기 때문이다. include 하는 쪽이 `const CB = ConstructionBots` 를
# 이미 정의하고 있어야 한다(`run_demo.jl:38` 과 게이트 파일이 둘 다 그렇게 한다).
#
# 🔴 **이동은 순수해야 한다**: 조건·순서·분기 본문·로그 문구·`enact_applied` 가 가드
# **안쪽**에 있는 것(2026-08-17 재리뷰 C1(B) 가 고친 것 — `ReformTruth` 는 필드가 없는 struct
# 이고 `ZoneTruth` 에는 `robot` 필드가 없어서, 가드 밖에 두면 거짓 보고가 난다) · MILP 센티넬
# 판정 · `_applied_note` 전부 그대로다. 검증 방법은 T2 보고서에 있다(HEAD 의
# `run_demo.jl:373-487` 를 그대로 뽑아 이 파일의 같은 구간과 `diff` — 0줄 차이).
# =============================================================================

"""
    _arm_overridden(router, mac; force_macro=…) -> Bool

이 결정의 **집행 팔이 정책 밖에서 실제로 갈아 끼워졌는가**(통제 실험 `DEMO_FORCE_MACRO`,
또는 1-step deviation `DS_DEVIATE_AT`).

🔴 왜 이것이 집행 대상 선택에 필요한가 (T1 리뷰 F8 · 컨트롤러 판정 R16)
------------------------------------------------------------------------
`decide_all` 의 `tool_lane` 은 `pol[enacted]` 에서 나오고(`policy.jl:1624`),
**`FORCE_MACRO`/`DEVIATE` 는 그 항목에 한 번도 안 쓴다** — 그 블록들(`:1507-1546`)이 고치는
것은 지역변수 `chosen` 과 라우터 dict `rt` 뿐이다(실측: `pol[enacted][…] = …` 대입이 파일
전체에 0건). 그래서 통제 판·이탈 판에서는 `decision.macro_name` 과 `tool_lane["tool_called"]`
이 **서로 다른 팔**을 서술한다: 집행되는 것은 강제된 팔이고, tool 호출은 정책이 원래 고른 팔의
것이다.

🔴 **줄 순서가 이유가 아니다.** 이 자리의 예전 주석은 근거를 *"`forced`/`deviate` 블록이
`tool_lane` 캡처보다 뒤다"* 라고 적었는데 **실제 순서는 반대이고**(override 는 `:1507`,
`tool_lane` 은 `:1624`) 그 근거는 틀렸다. 순서를 바꿔도 이 문제는 안 사라진다 — 사라지려면
override 가 `pol[enacted]` 를 다시 써야 하는데 그런 코드가 없다. 틀린 근거로 옳은 코드를
지키면 다음 사람이 그 근거를 믿고 코드를 바꾼다.

그 상태에서 `tool_args["agent"]` 를 그대로 집행에 먹이면, **한 팔을 위해 고른 agent 가 다른
팔의 집행에 적용**되고 결정 행은 그것을 `enact_agent_source == "tool"` 로 주장한다.

**해법은 추측이 아니라 거절이다(R16).** 팔이 갈아 끼워졌으면 `truth.robot` 으로 떨어지고
`"truth"` 로 기록한다(R16 은 그대로 선다). 강제된 팔이 "원했을" agent 를 재유도하지 않는다.

🔴 **판정은 "팔이 실제로 달라졌는가" 다** (2026-08-29 수정 라운드, 항목 4b). 이전 판은
`deviate_from` 이 **실려 있기만 하면** 거절했다. 그런데 `policy.jl:1525` 는 이탈 게이트가
발화하면 **팔이 안 바뀌어도** `deviate_from` 을 심는다(`rt["deviated"] = (dev != chosen)` 과
따로). 그래서 이탈 팔이 정책의 선택과 **같은** 런까지 tool 레인을 거부했고, 그 런들이 전부
`enact_agent_source == "truth"` 로 기록되어 **"LLM 의 tool 호출이 실제로 세계를 바꿨는가"를
재려고 읽을 바로 그 히스토그램이 체계적으로 깎였다.** R16 의 취지는 "팔이 외부에서 **바뀐**
런에서는 안 쓴다" 이지 "이탈 게이트가 켜졌으면 안 쓴다" 가 아니다.

그래서 세 경로가 **같은 술어**를 쓴다: *기록된 override-이전 팔이 집행되는 팔 `mac` 과
다른가.*
  * `router["forced_from"]`  -- `FORCE_MACRO` 가 덮기 전의 팔(`policy.jl:1511`)
  * `router["deviate_from"]` -- 이탈이 덮기 전의 팔(`:1525`)
  * `router["deviated"]`     -- `policy.jl` 이 이미 `dev != chosen` 으로 계산해 둔 값(`:1524`)
  * `force_macro`            -- 🔴 `forced` 는 `FORCE_MACRO != chosen` 일 때만 참이라
    (`:1508`), 강제 팔이 우연히 정책의 선택과 같으면 `forced_from` 이 **안 실린다.** 그 판은
    강제 팔 = 집행 팔 = 정책의 선택이므로 tool 호출도 **그 팔의 것**이다 — 거절할 이유가
    없다. 그래서 여기서도 `force_macro != mac` 일 때만 거절한다(위 4b 와 같은 술어).

⚠️ **`force_macro` 는 인자다 — 프로세스 `ENV` 를 함수 안에서 읽지 않는다**(항목 6).
예전에는 이 함수가 `ENV["DEMO_FORCE_MACRO"]` 를 직접 읽어서, 그 변수를 부모 env 로 흘리는
테스트가 **하나만** 생겨도 관계없는 게이트가 깨졌다. 기본값으로만 ENV 를 읽고(호출부가 아무
것도 안 넘겨도 생산 동작은 같다) 주입 지점을 하나 남긴다.
"""
function _arm_overridden(router, mac; force_macro = get(ENV, "DEMO_FORCE_MACRO", ""))
    local m = mac === nothing ? nothing : String(mac)
    local fm = strip(String(force_macro))
    (!isempty(fm) && m !== nothing && String(fm) != m) && return true
    router === nothing && return false
    # `policy.jl:1524` 가 이미 "팔이 바뀌었나" 로 계산해 둔 값. 그대로 믿는다.
    get(router, "deviated", false) === true && return true
    for k in ("forced_from", "deviate_from")
        local v = get(router, k, nothing)
        (v isa AbstractString && m !== nothing && String(v) != m) && return true
    end
    return false
end

"""
    enact_target(env, truth, tool_lane, router, mac)
        -> (; agent, source, tool_agent, verify, verify_detail, reject)

**누구에게 집행할 것인가**를 정한다. Plan B 의 분수령이 이 함수다 — 여기가 `truth.robot` 을
돌려주면 집행은 주입기가 이미 아는 값을 쓰는 것이고, LLM 의 tool 호출은 세계에 대해
인과가 없다.

규칙 (브리프 커밋 3 + 컨트롤러 판정 R16 + 2026-08-29 수정 라운드 항목 2·8·11·12):
 0. 이 결정의 팔이 강제/이탈로 **실제로 갈아 끼워졌으면**(`_arm_overridden`) tool 레인을
    **안 본다**.
 0b. 🔴 **출처 일치**: `tool_lane["tool_called"]` 이 **집행되는 매크로 `mac` 에 대응하는
    tool**(`CB.MACRO_TO_TOOL`)이 아니면 그 인자를 수입하지 않는다.
 1. **접지 판정이 `"admit"` 이고**(`CB.ground_tool_args`, 2026-08-29 T3) —
 2. `tool_lane["tool_args"]["agent"]` 가 **문자열**이고
 3. `CB.resolve_agent_id(env, 그 문자열)` 이 `nothing` 이 아니면 → 그것을 쓴다. source `"tool"`.
 4. 아니면 `truth.robot`(있으면). source `"truth"`.
 5. `truth` 에 `robot` 이 없으면 agent `nothing`, source `"none"`.

🔴 **0b — 교차축 구멍이 실측됐다 (2026-08-29 검증 항목 8).**

    macro = "Replace", tool_called = "no_intervention", tool_args = Dict("agent" => B)
      → verify == "admit" · enact_agent_source == "tool" · **Replace 가 B 에서 집행됐다**

두 측정축이 다 초록인데 세계가 **NOOP tool 의 인자로** 바뀌었다. 접지 판정은 인자에 대한
사실만 말하므로 이 구멍을 막을 수 없다 — 막는 것은 출처(provenance) 검사다.

🔴 **판정 R20 — 이것은 spec §4-1 위반이 아니다.** §4-1 이 금지하는 것은 **불일치를 이유로
결정을 바꾸는 것**이고, `macro_tool_agree` 는 지금처럼 계속 **기록만** 한다(이 함수는 그 키를
읽지도 않는다). 여기서 하는 것은 **다른 팔을 가리키는 호출에서 파라미터를 수입하지 않는
것** = 출처 문제다. 결정은 안 바뀐다. 대가는 "불일치 사건에서 tool agent 가 안 쓰이고
`truth.robot` 으로 떨어진다" 인데, 그건 오늘 동작이다.

🔴 **접지 판정(T3) — `verify` 를 같이 낸다.** spec §9-2 의 결정-행 키 `verify` 는 정확히
삼상이다(`"admit"` | `"reject:<reason>"` | `"deferred:<reason>"`, 소비자 규약은 접두사 비교).
오늘 이 레인에서 tool 호출을 거르는 자리는 `CB.ground_tool_args` 하나뿐이므로, 그 판정이
집행 조건에 **실제로 들어간다**: `admit` 이 아니면 tool 의 agent 를 쓰지 않는다.

🔴 **`verify_detail` 을 버리지 않는다 (항목 11).** 예전에는 `ground_tool_args(...)[1]` 로
판정만 받고 사유 문자열을 그 자리에서 버렸다. 그러면 `"agent": null` 과 `"agent"` 부재처럼
**같은 층에서 갈리는 두 사건**의 유일한 진단이 사라진다. 이제 원문 그대로 나르고
`run_demo.jl` 이 결정 행에 싣는다.

🔴 **`reject` 는 결정을 지우지 않는다 (spec §4-1).** `reject`/`deferred` 는 "tool 레인이
실패했다" 이지 "결정이 사라졌다" 가 아니다 — 매크로 결정은 그대로 서고 그대로 집행된다
(`truth.robot` 으로). 여기서 예외를 던지거나 결정을 비우면 그것이 결함이다.

⚠️ **R16·출처 일치와 `verify` 는 다른 축이다.** 강제/이탈 판에서도, 이름이 어긋난 판에서도
`verify` 는 **인자에 대한 사실**을 그대로 낸다. 그 판에서 tool 의 agent 를 안 쓴다는 사실은
`enact_agent_source == "truth"` 와 `reject`(아래)가 나른다. 두 축을 한 필드에 섞으면
"인자가 틀렸다" 와 "팔이 강제됐다" 가 같은 관측이 된다.

🔴 **폴백은 반드시 기록된다 (컨트롤러 판정 R2/R6).** 조용히 떨어지면 "LLM 이 골랐다" 와
"주입기가 알려줬다" 가 **같은 관측**이 되고, Plan B 가 재려는 것 자체가 측정 불가가 된다.
그래서 이 함수는 `source` · **원문 문자열** `tool_agent` · **거절 사유** `reject` 를 함께 낸다.

🔴 **`reject` 는 `resolve_agent_id` 의 두 실패를 가른다 (항목 2).** 예전 코드는

    try CB.resolve_agent_id(env, s) catch; nothing end

로 **"열거에 없다"**(정상적인 접지 실패)와 **"해석기가 던졌다"**(버그)를 하나의 조용한
`"truth"` 폴백으로 무너뜨렸다 — *조용한 폴백 금지* 가 논지인 바로 그 파일 안에서. 이제
전자는 `"ungrounded_agent"`, 후자는 `"resolver_error:<예외타입>"` 이다(T3 의
`deferred:ground_check_error` 와 같은 결).

`reject` 의 값들 — `source == "tool"` 이면 **항상 `nothing`** 이다:
    "no_tool_agent"          tool 레인에 문자열 agent 가 없었다
    "arm_overridden"         R16 — 팔이 실제로 갈아 끼워졌다
    "tool_arm_mismatch"      호출된 tool 이 집행되는 팔의 것이 아니다 (0b)
    "verify:<판정>"          접지 판정이 `admit` 이 아니었다
    "ungrounded_agent"       열거에 없는 문자열
    "resolver_error:<타입>"  해석기가 던졌다 (버그 — 조용히 넘기지 않는다)

⚠️ **읽기 규약 (항목 5)**: `enact_agent_source == "tool"` 인데 `enact_applied == false` 인
상태는 **도달 가능하다** — `ZoneTruth` + 유효한 tool agent 면 zone 분기가 agent 를 아예 안
쓰기 때문이다. 그 조합의 뜻은 하나다: **"tool 이 agent 를 골랐다" 와 "그 agent 로 세계가
바뀌었다" 는 다른 명제다.** 전자는 `enact_agent_source`, 후자는 `enact_applied` 가 나른다.
"LLM 의 호출이 세계를 바꾼 비율" 을 세려면 **둘 다** 봐야 한다.

🔴 **키 존재로 분기하지 않는다 (T1 이 남긴 소비자 규칙 1).** `decide_all` 은 8키를
`get(..., nothing)` 으로 순회하므로 **키는 항상 있고** 값만 `nothing` 일 수 있다.
⚠️ 단 `tool_args` **안**에서는 다르다 — 그것은 서비스가 받은 JSON 객체 그대로이므로 키 존재가
의미를 나른다. 그 구분은 `ground_tool_args` 가 진다.

⚠️ **`tool_args` 변환은 얕다 (T1 소비자 규칙 2).** 오늘 tool 알파벳의 인자는 전부 평평한
문자열 하나라(`tool_registry.py` 의 `_agent_arg()` — enum 의 키가 `"agent"` 다) 여기서 읽는
`tool_args["agent"]` 는 `String` 이다. 중첩 인자를 받는 tool 이 생기면 그 값은
`JSON3.Object` 로 남고, 그때 이 가정을 다시 읽어야 한다.
"""
function enact_target(env, truth, tool_lane, router, mac)
    # 값을 본다 — 키 존재가 아니라. `tool_lane` 자체가 없을 수도 있는 호출자를 위해 get 을 쓴다.
    local tc = tool_lane === nothing ? nothing : get(tool_lane, "tool_called", nothing)
    local ta = tool_lane === nothing ? nothing : get(tool_lane, "tool_args", nothing)
    local raw = ta isa AbstractDict ? get(ta, "agent", nothing) : nothing
    local tool_agent = raw isa AbstractString ? String(raw) : nothing
    # 🔴 접지 판정(T3). 순수 함수이고 삼상이다. 판정 자체는 R16·출처 일치와 무관하게 **항상**
    # 잰다 — 그것이 인자에 대한 사실이기 때문이다(위 docstring 의 축 분리).
    # 판정기가 죽으면 그것도 "못 쟀다" 이지 "통과" 가 아니다(`admit` 으로 접지 않는다).
    # 🔴 항목 12: 예외를 통째로 삼키지 않는다 — 사유 문자열에 **예외 타입**을 싣고 `@warn` 으로
    # 남긴다(`@info` 를 버리는 로거를 쓰는 레포다: `run_demo.jl` 이 `Logging.Warn` 을 심는다).
    local verify, verify_detail
    try
        verify, verify_detail = CB.ground_tool_args(env, tc, ta)
    catch e
        verify = "deferred:ground_check_error"
        verify_detail = "exception=" * string(typeof(e)) * " tool=" * repr(tc)
        @warn "[enact] ground_tool_args threw — 판정을 못 쟀다(admit 이 아니다)" exception = e
    end
    # 이 판에서 tool 의 agent 를 **왜** 못 썼는가. `source == "tool"` 이면 nothing.
    local reject::Union{Nothing,String} = nothing
    local hit = nothing
    # 집행되는 팔에 대응하는 tool 이름. 대응이 없는 팔(예: zone 팔)은 `nothing` 이고,
    # 그러면 어떤 호출도 그 팔의 것이 아니다.
    local want_tool = mac === nothing ? nothing : get(CB.MACRO_TO_TOOL, String(mac), nothing)
    if tool_agent === nothing
        reject = "no_tool_agent"
    elseif _arm_overridden(router, mac)
        reject = "arm_overridden"
    elseif !(want_tool !== nothing && tc isa AbstractString && String(tc) == want_tool)
        reject = "tool_arm_mismatch"
    elseif verify != "admit"
        reject = "verify:" * verify
    else
        # 접지: 열거에 **정확히 있는** 문자열일 때만 통과(파싱 없음). 🔴 두 실패를 가른다.
        try
            hit = CB.resolve_agent_id(env, tool_agent)
            hit === nothing && (reject = "ungrounded_agent")
        catch e
            hit = nothing
            reject = "resolver_error:" * string(typeof(e))
            @warn "[enact] resolve_agent_id threw — 열거 밖과 다른 사건이다" exception = e
        end
    end
    hit !== nothing &&
        return (agent = hit, source = "tool", tool_agent = tool_agent,
                verify = verify, verify_detail = verify_detail, reject = nothing)
    hasproperty(truth, :robot) &&
        return (agent = truth.robot, source = "truth", tool_agent = tool_agent,
                verify = verify, verify_detail = verify_detail, reject = reject)
    return (agent = nothing, source = "none", tool_agent = tool_agent,
            verify = verify, verify_detail = verify_detail, reject = reject)
end

"""
    log_enact(tgt) -> nothing

집행 대상 선택의 **한 줄 기록**. `render_demo.jl` 의 두 producer 가 **같은 함수**를 부른다.

🔴 왜 함수인가: 이 엔진에는 `run_demo.jl` 의 `this_decision` 같은 결정 행이 없어서
(`_DECISIONS` 가 그 파일에 0건) `source`·`tool_agent`·`reject` 를 실을 자리가 stdout 한 줄
뿐이다. 그 한 줄을 producer 마다 손으로 복사하면 한쪽이 `reject` 를 빠뜨리는 순간
"LLM 이 골랐다" 와 "주입기가 알려줬다" 가 같은 관측이 된다(컨트롤러 판정 R2/R6).
문구는 `policy_producer` 가 쓰던 것 **그대로**다 — 기존 스트림 소비자가 안 깨진다.
"""
log_enact(tgt) =
    println("[enact] target=", tgt.agent === nothing ? "-" : string(tgt.agent),
            " source=", tgt.source,
            " tool_agent=", tgt.tool_agent === nothing ? "-" : tgt.tool_agent,
            " verify=", tgt.verify,
            " reject=", tgt.reject === nothing ? "-" : tgt.reject)

"""
    proposal_agent(prop) -> agent | nothing

LLM 제안이 **누구를 가리키는가**. 첫 제약의 `agent` 필드(없으면 `nothing`).
`_proposal_macro` 가 표시용 이름을 뽑는 것과 같은 자리(`prop.constraints[1]`)를 본다 —
집행이 실제로 읽는 것이 그 제약이기 때문이다(`enact_recovery!` 는 `.agent` 를 존중한다).
"""
proposal_agent(prop) =
    (prop === nothing || isempty(prop.constraints)) ? nothing :
    (hasproperty(prop.constraints[1], :agent) ? prop.constraints[1].agent : nothing)

"""
    llm_enact_target(env, truth, prop, mac; router = nothing) -> enact_target 의 NamedTuple

**LLM 제안이 고른 agent 를 `enact_target` 과 똑같은 문을 통과시킨다.**

⚠️ **2026-08-29(같은 날, 나중): 이 함수는 지금 호출자가 0개다.** 아래가 설명하는 우회로의
주인공인 `render_demo.jl` 의 `llm_producer` 레인이 Anthropic 레인과 함께 삭제됐기 때문이다
(그 레인은 `llm_to_proposal` 로 :8000 의 파이썬 `/propose` 서비스를 불렀고, 그 서비스의 유일한
구현이 `anthropic.Anthropic()` 이었다). 함수를 지우지 않고 남긴 이유는 아래 실측 기록이
"제안이 고른 agent 를 `enact_target` 과 같은 문으로 보낸다"는 **규칙**을 담고 있어서다 —
LLM 제안을 집행하는 레인이 다시 생기면 규칙을 다시 유도하지 말고 이 함수를 부를 것.

🔴 왜 이 함수가 있어야 했는가 (2026-08-29, Plan B / T2c — 실측된 우회로)
------------------------------------------------------------------------
`render_demo.jl` 의 `llm_producer`(`DEMO_LLM=1`)는 `llm_to_proposal` 이 돌려준 제안을
**그대로** 집행 dispatcher 에 넘겼다. 그래서 그 레인에서 LLM 이 고른 agent 는

  · 접지 없이            — `_open_agent_pairs`(모델에게 **보여준** 집합)와 대조된 적이 없다
  · 출처 검사 없이       — 집행되는 팔과 인자의 팔이 같은지 안 물었다
  · 강제/이탈 거절 없이  — `DEMO_FORCE_MACRO` 판에서도 LLM 의 agent 가 그대로 실렸다

세계에 닿았다. `policy_producer` 는 T2b 에서 `enact_target` 뒤로 들어갔지만 이 레인은 안
들어갔다 — 한 레포에 두 엔진이 있고 한쪽만 문을 지나면 그 문은 없는 것과 같다.

⚠️ **접지가 `_default_id_resolver` 로 이미 되어 있다는 반론은 실측으로 틀렸다.**
`_default_id_resolver`(`replan.jl:1687`)는 로봇 열거 **앞에** 스케줄 정점 id 공간 전체를
먼저 훑어 `get_vtx_id` 를 그대로 돌려준다. 즉 **노드 id 문자열이 agent 자리를 통과한다** —
`_open_agent_pairs` 가 받아들이지 않는 값이다. 그것이 리뷰어가 "세 번째 손복사 열거"라고
지적한 결함의 실체다.

동작
----
제안의 agent 를 `tool_lane` **모양 그대로**(`decide_all` 이 만드는 것과 같은 두 키) 감싸
`enact_target` 에 넘긴다. tool 이름은 `CB.MACRO_TO_TOOL` 에서 **유도한다** — 리터럴로 적으면
그 표와 갈릴 수 있고, 이 레인에서는 "인자를 낸 팔" 과 "집행되는 팔" 이 같은 제약 하나이므로
출처 검사(규칙 0b)는 **구조적으로 참**이다. 하중을 지는 것은 접지(규칙 1~3)와
`_arm_overridden`(규칙 0)이다.

`mac` 이 `MACRO_TO_TOOL` 밖이면 `tool_called` 가 `nothing` 이고 `enact_target` 은
`tool_arm_mismatch` 로 거절한다 — 즉 **모르는 팔에서는 LLM 의 agent 를 안 쓴다**(안전한 쪽).

⚠️ `router` 는 인자다. 이 레인은 `decide_all` 을 안 타서 오늘은 라우터가 없고(따라서
`DS_DEVIATE_AT` 이 이 레인의 팔을 바꾸는 경로도 없다) `nothing` 이 넘어온다. `DEMO_FORCE_MACRO`
거절은 `_arm_overridden` 의 ENV 기본값으로 **라우터 없이도 산다**. 이 레인에 라우터가 생기면
그대로 넘기면 된다 — 규칙은 여기 없고 `_arm_overridden` 에 하나뿐이다.
"""
function llm_enact_target(env, truth, prop, mac; router = nothing)
    local a = proposal_agent(prop)
    local lane = a === nothing ? nothing :
        Dict{String,Any}("tool_called" =>
                             (mac === nothing ? nothing :
                              get(CB.MACRO_TO_TOOL, String(mac), nothing)),
                         "tool_args" => Dict{String,Any}("agent" => string(a)))
    return enact_target(env, truth, lane, router, mac)
end

"""
    enact_macro!(env, truth, mac, agent) -> (; enact_applied, ran_milp)

고른 매크로 `mac` 을 세계에 집행한다. `agent` 는 **집행 대상 로봇**(`RobotID` 또는
`nothing`) — 누가 그 값을 고르는지는 `enact_target` 이 정한다(아래).

반환 둘은 `handle_ood!` 이 결정 행에 그대로 싣는 것이다:
  * `enact_applied` -- 사슬의 어느 분기가 **실제로** 탔는가. 이 사슬은 최종 `else` 가 없고
    두 zone 분기는 `truth isa CB.ZoneTruth` 가드가 걸려 있어서, 지원 안 하는 매크로로
    deviate 하면 아무 일 없이 통과하는데도 verdict 는 "집행했다"고 말할 수 있다.
  * `ran_milp`     -- G6(spec §5.5): 이 결정에서 f 가 솔버를 불렀는가(센티넬 판정).
  * `status`       -- 🔴 그 분기가 부른 **편집 연산의 반환 상태**(`:swapped` 등), 안 불렀으면
    `nothing`. 2026-08-29 수정 라운드 항목 1: `hot_swap_robot!` 의 `:no_spare`/`:no_robot` 은
    **예외가 아니라 반환값**인데 아무도 안 읽어서, 창고에 예비가 없어 수술이 아무것도 안 해도
    `enact_applied` 가 `true` 였다. 이제 Replace 의 `enact_applied` 는 `status === :swapped` 다.

`tag` 는 로그 문구용으로 여기서 다시 만든다 — `handle_ood!` 의 `tag` 와 **같은 식**이다
(`string(typeof(truth).name.name)`).
"""
function enact_macro!(env, truth, mac, agent)
    local tag = string(typeof(truth).name.name)
    # spec §9(a) 배터리/에너지 훅 활성 검사. 이 데모는 RESPEC_ENABLED=false 로 두고 복구를 직접
    # 몰기 때문에, replan.jl 의 `[RESPEC] ... energy term` 로그가 있는 maybe_respecify! 경로를
    # 타지 않는다. 그래서 여기서 직접 본다: 매크로 집행이 MILP 를 다시 정식화했다면
    # (rebalance_for_battery! 등) LAST_AUTO_EFFICIENCY_W[] > 0 이어야 한다 = 전역 κ 가 그 재풀이에도
    # 실렸다는 뜻. (0 으로 먼저 지워야 이전 결정의 값이 새 나가지 않는다 — Ref 는 sticky 하다.)
    #
    # ⚠️ 세 상태를 구분해야 한다(리뷰 I-3). n_candidate_edges=0 은 "재풀이는 했는데 후보가 없었다"
    #   와 "재풀이 자체가 없었다"를 구별하지 못한다 — Replace/ReformTeam/RelocateBuild 는
    #   formulate_milp 을 아예 안 부르므로 항상 후자다. 그래서 센티넬 Dict 를 심어 둔다:
    #   formulate_milp 이 돌면 LAST_EDGE_COSTS[] 를 **새 Dict 로 교체**하므로 `===` 가 깨진다.
    local _milp_sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_AUTO_EFFICIENCY_W[] = 0.0
    CB.LAST_EDGE_COSTS[] = _milp_sentinel
    # 이 사슬은 최종 `else` 가 없고 두 분기는 `truth isa CB.ZoneTruth` 가드가 걸려 있다 — 그래서
    # 지원 안 하는 매크로(예: fault 사건에 ForbidZone)로 deviate 하면 사슬을 아무 일 없이 통과해
    # 세계가 안 바뀌는데도 verdict 는 "집행했다"고 말할 수 있다(2026-08-17 재리뷰 F2). 각 분기가
    # 실제로 탔는지를 여기 플래그로 남긴다 — 조건·순서·본문은 그대로, 계측만 얹는다.
    local enact_applied = false
    local ran_milp = false      # G6(spec §5.5): 이 결정에서 f 가 솔버를 불렀는가
    # 분기가 부른 편집 연산의 **상태 심볼**(`:swapped` · `:no_spare` · `:no_robot` · 배터리
    # 교체의 상태…). 안 부른 분기에서는 `nothing` — "부르고 실패했다" 와 "안 불렀다" 를 같은
    # 값으로 접지 않는다. ⚠️ 이 값은 `enact_with_efficacy!` 를 **안 넘는다**(그 층의 반환 키
    # 집합을 `test/efficacy_measures_the_edit.jl` (5) 가 못박는다) — 그래서 결정 행에는
    # 안 실린다. 항목 1 의 실질은 `enact_applied` 가 이제 `status === :swapped` 라는 것이다.
    local status = nothing
    try
        if mac == "NOOP"
            enact_applied = true
            println("[recover] $tag → NOOP (정책이 개입하지 않기로 결정)")
        elseif mac == "Replace"
            # ⚠️ 2026-08-17 재리뷰 C1(B): `enact_applied` 는 **가드 안쪽**이어야 한다. `ReformTruth`
            # 는 필드가 없는 struct 이고(`src/navigator/ood_truth.jl:97-98`) `ZoneTruth` 에는
            # `robot` 필드가 없다(`:67-72`) — 가드 밖에 두면 reform/zone 사건에 Replace 로
            # deviate 했을 때 이 분기가 매치는 됐지만 `hasproperty` 가 false 라 아무 일도 안
            # 일어났는데 `enact_applied=true` 로 거짓 보고한다.
            #
            # 🔴 2026-08-29 (T2 커밋 3): 본체는 이제 `agent` 를 쓰지만 **가드는 그대로**
            # `hasproperty(truth, :robot)` 다(브리프·R5 가 조건 변경을 금한다). 귀결을 적어
            # 둔다: 가드가 참이면 `enact_target` 규칙상 `agent !== nothing` 이 보장되므로
            # nothing 역참조는 불가능하다. 반대 방향은 열려 있다 — `robot` 필드가 없는 truth
            # (ZoneTruth/ReformTruth)에 tool 이 유효 agent 를 실어 보내면 집행이 안 되고
            # `enact_applied=false` 로 **정직하게** 기록된다(조용한 거짓 보고가 아니다).
            #
            # 🔴 2026-08-29 수정 라운드 (항목 1): `hot_swap_robot!` 의 **반환값을 읽는다.**
            # `:no_spare` / `:no_robot` 은 **예외가 아니라 반환값**이고(`replace_robot.jl:1508·
            # 1516·1520`) 예전에는 아무도 안 읽었다. 그래서 창고에 예비가 없어 씬트리 수술이
            # **아무것도 안 해도** `enact_applied = true` 였고, 그 두 줄 뒤의 SoC 대입이 회복을
            # 흉내 내 게이트까지 초록이었다. `:no_spare` 는 문서화된 실재 실패 모드다
            # (CLAUDE.md ★-2: 다른 창고의 놀고 있는 예비가 `nearest_pool` 에 안 보인다).
            # 반환값을 버리는 호출은 이 파일의 논지(조용한 거짓 보고 금지)와 정면으로 어긋난다.
            if hasproperty(truth, :robot)
                local hs = CB.hot_swap_robot!(env, agent; mode = :via_depot, verbose = false)
                status = hs.status
                enact_applied = (status === :swapped)
                enact_applied || @warn(
                    "[recover] Replace 가 세계를 안 바꿨다 — 씬트리 수술이 실패했다",
                    status, detail = get(hs, :detail, nothing), agent)
                # 🔴 SoC 회복은 **수술이 실제로 났을 때만** 쓴다. 예전에는 무조건 대입이라
                # `:no_spare` 판에서도 `fleet.soc[agent] == 1.0` 이 됐다 — 그 한 칸이 이 레인의
                # 유일한 양성 관측이었으므로, 그 대입이 곧 "세계가 바뀌었다"는 거짓 증거였다.
                if enact_applied && truth isa CB.BatteryTruth
                    local f = CB.BATTERY_FLEET[]                   # 스왑된 본체=새 배터리 → SoC 회복
                    (f !== nothing && haskey(f.soc, agent)) && (f.soc[agent] = 1.0)
                end
            end
        elseif mac == "SwapBattery"
            # 2026-08-06 (Ch-A): 현장 배터리 교체. Replace 와 달리 **창고 예비 본체를 안 먹는다** —
            # 그게 두 팔을 따로 두는 이유이고(spec_dsl.jl), 방전 사건에서 싼 정답이 되는 근거다.
            # 씬트리·스케줄을 안 건드리므로 정체성 위반이 원리적으로 불가능하다.
            # `enact_applied` 는 Replace 와 같은 이유로 가드 안쪽(2026-08-17 재리뷰 C1(B)).
            if hasproperty(truth, :robot)
                enact_applied = true
                local sw = CB.swap_battery!(env, agent; verbose = false)
                status = sw.status
                println("[battery] swap=$(sw.status) soc_before=$(get(sw, :soc_before, nothing))")
            end
        elseif mac == "ForbidZone" && truth isa CB.ZoneTruth
            enact_applied = true
            # A zone can cover several staging workspaces. Relocate every
            # blocked subassembly, then minimally translate the whole build
            # only if fixed/root goals remain covered. Keep the zone active so
            # routing and the post-RVO clearance gate enforce it continuously.
            local keys = Symbol[truth.zone]
            local staged = CB.restage_all_blocked!(env;
                zone_keys = keys, resume = true, verbose = false)
            local recovery = staged
            local overlaps = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            local corrections = 0
            while overlaps > 0 && corrections < 4
                recovery = CB.translate_whole_build!(env;
                    zone_keys = keys, resume = true, verbose = false)
                corrections += 1
                recovery.status in (:translated, :already_clear, :residual_blocked) || break
                overlaps = CB._count_future_work_overlaps(env;
                    zone_keys = keys)
            end
            local residual = CB._count_future_work_overlaps(env;
                zone_keys = keys)
            residual == 0 || error(
                "zone recovery left $residual future work discs inside $(truth.zone)")
            println("[zone] staging=$(staged.status) final=$(recovery.status) " *
                    "corrections=$corrections active_zone=$(truth.zone) residual=$residual")
            # 좁은 공장에선 지속 존이 로봇 경로를 막아 nav 교착 → 조립체를 안전지대로 옮긴 뒤
            # 일시 장애를 해제(transient obstruction)해 완주시킨다. respec(ForbidZone)은 이미 기록됨.
        elseif mac == "RelocateBuild" && truth isa CB.ZoneTruth
            enact_applied = true
            # 2026-08-04: zone 사건의 기본 개입 팔. ForbidZone 분기와 달리 **조립체별 재적치를
            # 아예 건너뛰고** 빌드 전체를 한 번에 옮긴다(그 전제조건이 빌드 중반에 사라지므로).
            # 이 분기가 없으면 LLM 이 RelocateBuild 를 골라도 아무 일도 안 일어나고, UI 에는
            # "LLM 이 개입했다"고 찍히는 최악의 조용한 거짓말이 된다.
            local zkeys = Symbol[truth.zone]
            local wb = CB.translate_whole_build!(env; zone_keys = zkeys, resume = true, verbose = true)
            local left = CB._count_future_work_overlaps(env; zone_keys = zkeys)
            println("[zone] whole-build=$(wb.status) Δ=$(get(wb, :delta, nothing)) " *
                    "active_zone=$(truth.zone) residual_work_discs=$left")
            # :already_clear = Δ0. 구역이 미완 목표를 하나도 안 덮어 옮길 필요가 없었던 경우이며
            # 실패가 아니다(예전에는 :translated 로 뭉뚱그려져 "0 m 이동"이 성공으로 찍혔다).
            wb.status in (:translated, :already_clear) ||
                @warn "RelocateBuild 가 구역을 못 벗어남" status=wb.status residual=left
        end
        # enact_applied 가 false 면 위 "→ $mac" 은 거짓말이다 — 어느 분기도 안 탔다는 뜻이므로
        # 그 사실을 로그 문구 자체에 남긴다(2026-08-17 재리뷰 F2). 사슬의 조건·순서·본문은
        # 그대로다 — 이 줄만 계측이다.
        local _applied_note = enact_applied ? "" :
            " [집행 사슬 무동작: 이 사건 타입엔 $(mac) 분기가 없거나 가드에 안 걸렸다]"
        println("[recover] $tag → $mac$(_applied_note)  (closed=", length(env.cache.closed_set), ")")
        ran_milp = !(CB.LAST_EDGE_COSTS[] === _milp_sentinel)   # 센티넬이 그대로면 재풀이 없음
        if CB.LAST_AUTO_EFFICIENCY_W[] > 0.0
            println("[recover] energy term ON for this re-solve (auto w_eff=",
                    round(CB.LAST_AUTO_EFFICIENCY_W[]; sigdigits = 3),
                    ", κ=", CB.AUTO_EFFICIENCY_KAPPA[], ")")
        elseif !ran_milp
            println("[recover] energy term N/A for $mac — 이 분기는 formulate_milp 을 아예 부르지 ",
                    "않는다(재풀이 없음). κ 와 무관한 상태다")
        else
            println("[recover] energy term NOT active for $mac — 재풀이는 했다(κ=",
                    CB.AUTO_EFFICIENCY_KAPPA[], ", n_candidate_edges=",
                    length(CB.LAST_EDGE_COSTS[]),
                    "). 후보 엣지가 0 이면 재배정할 자유도가 없어 에너지 항이 실릴 데가 없다는 뜻이다")
        end
    catch e
        println("[recover] $tag ($mac) FAILED: ", first(split(sprint(showerror, e), "\n")))
    end
    return (enact_applied = enact_applied, ran_milp = ran_milp, status = status)
end

# =============================================================================
# ④ 실효성 층 (2026-08-29, Plan B / T5) — spec §8 의 네 번째 층.
#
# 여기서부터는 T2 의 집행 사슬을 **감싸는** 계측이다. 사슬 본체(`enact_macro!`)는 한 줄도
# 안 바뀐다 — 그 함수의 계약을 이미 두 게이트가 지고 있고(`enact_uses_llm_agent.jl` ·
# `tool_args_grounding.jl`), 전후 측정을 사슬 **안에** 넣으면 그 게이트들이 재는 반환 모양이
# 바뀐다.
# =============================================================================

"""
    EFFICACY_CHECK_PATHS

④층이 `zone_blockage` 를 부를 때 쓰는 `check_paths` 값. **`false` 다** (컨트롤러 판정 R12).

🔴 왜 `false` 이고, 왜 그 사실이 산출물에 실려야 하는가
------------------------------------------------------
`check_paths=true` 는 목표마다 평면 격자를 flood-fill 한다(`zone_corridor.jl` 의
`free_space_status`). 이 픽스처만 해도 미완 nav 목표가 **181개**라(실측) 결정 경로에서 매번
그 비용을 내는 것은 곤란하고, **그것이 이 값이 `false` 인 이유다.** 대가는 정확하다:
`n_disconnected` 가 **언제나 0** 이 되어 corridor(통로 봉쇄) 막힘이 `n_blocked` 에 안 실린다.
그러니 `n_blocked` 는 **엄밀한 하한**이고, 그 하한으로 낸 판정은 "안 줄었다"(`inert`)를
과다 보고할 수 있다 — 통로만 막고 있던 사건은 처음부터 `n_blocked=0` 으로 보인다.

`zone_corridor.jl` 자신이 "재지 않은 것을 0 으로 보고하지 않는다"는 규율을 적고 있으므로,
④층의 산출물은 그 사실을 **함께** 나른다: 결정 행의 `efficacy_checked_paths`.
⚠️ 그 값은 리터럴이 아니라 **측정 결과에서 읽는다**(`blockage.checked_paths`) — 여기 상수를
`true` 로 바꾸면 결정 행의 값도 따라 바뀐다. 손으로 쓴 짝은 갈라진다.
"""
const EFFICACY_CHECK_PATHS = false

"""
    _zone_blockage_now(env, truth) -> NamedTuple | nothing

이 zone 사건이 지목한 구역 하나에 대해 **지금** 막혀 있는 것을 잰다. 순수 술어이고
(`zone_corridor.jl` 은 편집 연산이 0개다) 세계를 안 건드린다. 못 재면 `nothing` —
0 으로 접지 않는다.
"""
function _zone_blockage_now(env, truth)
    return try
        CB.zone_blockage(env; zone_keys = Symbol[truth.zone],
                         check_paths = EFFICACY_CHECK_PATHS)
    catch e
        @warn "[efficacy] zone_blockage failed" exception = e
        nothing
    end
end

"""
    enact_with_efficacy!(env, truth, mac, agent)
        -> (; enact_applied, ran_milp, efficacy, efficacy_checked_paths)

`enact_macro!` 을 **그대로** 부르되 그 앞뒤에서 막힘을 재고, spec §8 ④층의 판정을 낸다.
`enact_applied`·`ran_milp` 는 `enact_macro!` 이 낸 것을 손대지 않고 그대로 통과시킨다.

🔴 **반환 키는 정확히 넷이다 — 늘리지 마라.** `test/efficacy_measures_the_edit.jl` (5) 가
`Set(keys(r))` 로 이 집합을 **못박고** 있다(T5 의 계약: ④층은 감싸는 계측이지 사슬의 반환을
다시 짓는 자리가 아니다). 2026-08-29 수정 라운드에서 `enact_macro!` 이 새로 내는 `status`
(항목 1)를 여기로 통과시켰다가 그 게이트가 빨개졌다 — 그래서 `status` 는 `enact_macro!` 의
반환에만 있고 이 층을 안 넘는다. 그 귀결은 수정 보고서에 적혀 있다(결정 행에 `enact_status`
키가 없는 이유).

판정 (spec §9-2 의 값 집합)
--------------------------
    "resolves"                     편집 후 `n_blocked` 가 **줄었다** — 관측된 막힘에 닿았다
    "inert"                        쟀는데 안 줄었다
    "deferred:no_efficacy_measure" 잴 방법이 없다(zone 축이 아닌 사건) — R10
    "deferred:not_enacted"         집행 사슬의 어느 분기도 안 탔다
    "deferred:measure_error"       술어가 죽었다

🔴 **이것은 상태가 아니라 차이다.** `after.n_blocked == 0` 을 보는 규칙(=상태)으로 바꾸면
막힘이 애초에 0 이던 사건의 아무 편집이나 `resolves` 가 된다 — 즉 "고쳤다"가 "고칠 것이
없었다"와 같은 관측이 된다. 그리고 전 측정을 사후 시점으로 옮기면 두 값이 항상 같아져
`resolves` 가 **도달 불가**가 된다. 게이트 `test/efficacy_measures_the_edit.jl` 의 (1)(2)(2b)
가 그 두 변이를 각각 잡는다(변이 실측은 T5 보고서).

🔴 **R10 — zone 축만 잰다.** `zone_corridor.jl` 의 술어가 세는 것은 *구역이 막는 것*이다.
battery/fault 사건에 들이대면 `n_blocked` 가 전후 모두 0 이라 **옳게 고친 배터리 교체가
`inert` 로 오분류된다.** 다른 축의 실효성 측정을 지금 발명하는 것은 B3/C 의 설계 작업이고,
**틀린 측정은 정직한 `deferred` 보다 나쁘다.** 그래서 분기는 블랙리스트가 아니라
`truth isa CB.ZoneTruth` 라는 **양성 검사**다 — 사건 종류가 하나 늘어도 조용히 zone 술어에
빨려 들어가지 않는다.

⚠️ **`verify`(②접지)와 다른 축이다.** `verify == "admit"` 인데 `efficacy == "inert"` 인 결정은
정상이고 흔하다 — "인자가 실재하는 것을 가리켰다"와 "그 편집이 막힘을 풀었다"는 다른 명제다.

⚠️ **`not_enacted` 는 `inert` 가 아니다.** "안 했다"와 "했는데 안 통했다"는 다른 사건이고,
④층 신호를 세는 사람에게는 정확히 그 구분이 값어치다(spec §8-1 의 "③④ 거절 사유 분포").
그래서 이 판정은 `n_blocked` 비교보다 **먼저** 온다: 사슬이 무동작이었는데 우연히 다른 무엇이
막힘을 줄였다면 그것을 이 편집의 공으로 돌리지 않는다.

⚠️ `efficacy_checked_paths` 는 **측정이 실제로 일어났을 때만** `Bool` 이다. 안 쟀으면
`nothing` — "경로를 안 봤다"(`false`)와 "아무것도 안 봤다"를 같은 값으로 접으면 R12 가 막으려던
바로 그 혼동이 한 칸 옆에서 재현된다.
"""
function enact_with_efficacy!(env, truth, mac, agent)
    # R10: zone 축이 아니면 **재지 않는다.** 사슬은 그대로 돌린다(판정만 유보한다).
    if !(truth isa CB.ZoneTruth)
        local r0 = enact_macro!(env, truth, mac, agent)
        return (enact_applied = r0.enact_applied, ran_milp = r0.ran_milp,
                efficacy = "deferred:no_efficacy_measure", efficacy_checked_paths = nothing)
    end
    local before = _zone_blockage_now(env, truth)
    # 🔴 이 줄의 **위**가 전 측정, **아래**가 사후 측정이다. 둘을 같은 쪽으로 모으면 차이가
    #    항상 0 이 되어 이 층이 아무것도 못 잰다(변이시험 1).
    local r = enact_macro!(env, truth, mac, agent)
    local after = _zone_blockage_now(env, truth)
    local eff, checked
    if before === nothing || after === nothing
        eff, checked = "deferred:measure_error", nothing
    elseif !r.enact_applied
        eff = "deferred:not_enacted"
        checked = before.checked_paths && after.checked_paths
    else
        eff = after.n_blocked < before.n_blocked ? "resolves" : "inert"
        checked = before.checked_paths && after.checked_paths
    end
    return (enact_applied = r.enact_applied, ran_milp = r.ran_milp,
            efficacy = eff, efficacy_checked_paths = checked)
end

"""
    emitted_keys_of(prop) -> Vector | nothing

이 결정에 대응하는 제안(`RespecProposal`)이 실제로 내놓은 DSL 지시들의 **채점 키**
(spec §9-2 의 `emitted_keys`). 🔴 **Julia 가 `CB.emitted_key` 로 계산한다** — 서비스에게
묻지 않는다(`src/navigator/ood_truth.jl` 의 그 함수가 채점기와 **같은** 키 형식을 낸다).

키 하나는 `(:fault, RobotID(3))` 같은 2-튜플이라 그대로는 JSON 이 못 나른다. 두 칸을 문자열로
편 `["fault", "RobotID(3)"]` 로 싣는다 — `string(...)` 은 `resolve_agent_id` 가 받아들이는
바로 그 표기이므로 왕복이 성립한다.

🔴 **실패는 `nothing` 이고 빈 배열이 아니다.** 빈 배열은 "계산했더니 낼 키가 없었다"(NOOP 이
정확히 그 경우다)이고 `nothing` 은 "계산을 못 했다"이다. 이 레포는 그 둘을 섞어 여러 번 데였다.
`emitted_key` 가 `nothing` 을 내는 지시(채점 대상 엔티티가 없는 것 — 오늘의 `ForbidZone` 이
그렇다)는 채점기와 **같은 규칙으로** 건너뛴다(`baselines.jl` 의 `_emitted_keyset`).
"""
function emitted_keys_of(prop)
    prop === nothing && return nothing
    return try
        local out = Any[]
        for c in prop.constraints
            local k = CB.emitted_key(c)
            k === nothing && continue
            push!(out, Any[string(first(k)), string(last(k))])
        end
        out
    catch e
        @warn "[emitted_keys] emitted_key failed" exception = e
        nothing
    end
end

"""
    decision_reasoning(decision) -> String | nothing

spec §9-2 의 `reasoning`: *"해석성 로그 — 파싱하지 않는다, 지우지도 않는다"*.
`decide_all` 이 낸 `detail`(= `pol[enacted]["rationale"]`, `policy.jl` 의 반환문)을 **손대지
않고** 돌려준다. 자르지 않는다 · 파싱하지 않는다 · 빈 문자열로 덮지 않는다.

🔴 **출처는 `pol[enacted]` 이지 `pol["dspy"]` 가 아니다.** T1 이 `tool_lane_view` 에서 정한
규칙과 **같은** 규칙이다: canonical 이 낸 결정의 행에 LLM 의 문장을 실으면 그 행은 자기가 안
한 추론을 서술하게 된다. dspy 레인이 집행된 판 — 즉 spec §9-2 가 말하는 그 판 — 에서는 이
값이 곧 서비스가 준 `reasoning` 문자열이다(`policy_entry` 가 `rationale` 로 나른다). 어느
레인이었는지는 같은 행의 `enacted` 가 나른다.

⚠️ 한 줄짜리 함수인 이유는 **게이트가 잡을 자리를 만들기 위해서다.** 이 값이 호출부에
인라인이면 `run_demo.jl` 은 스크립트라 어떤 테스트도 그 줄을 못 태운다(T2 가 사슬을 이 파일로
옮긴 것과 같은 이유). 여기 있으면 절단·파싱 변이가 `test/efficacy_measures_the_edit.jl` (7)
에서 빨개진다.
"""
function decision_reasoning(decision)
    return try
        decision.detail
    catch e
        nothing
    end
end

# =============================================================================
# 🔴 분수령의 **호출부** (2026-08-29 수정 라운드, 항목 0 — 이 라운드의 최우선)
# =============================================================================

"""
    enact_decision!(env, truth, decision)
        -> (; target, enacted, row::Dict{String,Any})

이 결정 하나를 **세계에 집행하고**, 그 집행에 대한 결정-행 키들을 만든다.
`run_demo.jl` 의 `handle_ood!` 은 이 함수를 부르고 `row` 를 결정 행에 합칠 뿐이다.

🔴 **왜 이 함수가 존재하는가 — 게이트 밖의 생산 라인을 없애기 위해서다.**
리뷰어 실측(2026-08-29): `run_demo.jl` 의 집행 호출부에서 마지막 인자를 `_tgt.agent` 에서
`truth.robot` 으로 되돌리면 **T2 이전 세계가 정확히 복원되는데 스위트 전체가 초록이었다.**
이유는 `test/runtests.jl` 의 어떤 테스트도 `run_demo.jl` 을 읽지 않기 때문이다 — 변이시험이
빨개졌던 것은 `enact.jl` **안의 함수**를 고쳤을 때이고, **그 함수를 부르는 자리**는 아무도
안 지켰다. 그것이 Plan A 가 이미 밟은 결함("시그니처는 재는데 진짜 줄은 한 번도 안 탄다")
그대로이고, 이번엔 그 줄이 계획 전체의 분수령였다.

그래서 **호출부 자체를 여기로 옮겼다.** 이제 `enact_target` 에 무엇을 넘기는지, 그 결과를
어느 키로 싣는지가 전부 이 함수 안에 있고, `test/enact_uses_llm_agent.jl` (9)·
`test/tool_args_grounding.jl` (9) 가 **이 함수를 직접 태운다**(후자는 루프백 대역 서버로
`decide_all` 을 실제로 돌린 **진짜 레인 dict** 으로 태운다 — 손으로 지은 dict 이 아니다).
`run_demo.jl` 에 남은 것은 이 호출 한 줄과 `merge!` 한 줄이고, 그 두 줄은
`test/enact_uses_llm_agent.jl` (10) 의 소스 텍스트 단언이 지킨다.

⚠️ **`row` 는 화이트리스트가 아니라 이 함수의 산출물 전부다.** 호출부가 키를 골라 담으면
그 자리가 다시 게이트 밖의 화이트리스트가 된다(`run_demo.jl` 자신의 주석이 경고하는 함정).

`row` 의 키 (spec §9-2):
    tool_agent · enact_agent · enact_agent_source      T2, 컨트롤러 판정 R2/R6
    verify · verify_detail                             T3 + 항목 11
    enact_agent_reject                                 항목 2·8 — tool 의 agent 를 **왜** 안 썼나
    enact_applied · ran_milp                           T2 · G6(spec §5.5)
    efficacy · efficacy_checked_paths                  T5 ④층 (컨트롤러 판정 R12)

⚠️ **`enact_status` 는 여기 없다.** `enact_macro!` 은 편집 연산의 반환 상태(`:swapped` ·
`:no_spare` …)를 이제 내지만(항목 1), 그것을 여기까지 나르려면 `enact_with_efficacy!` 의 반환
키를 하나 늘려야 하고 그 집합은 `test/efficacy_measures_the_edit.jl` (5) 가 못박고 있다 —
그 파일은 이 라운드의 파일 집합 밖이다. 항목 1 의 실질(수술이 실패하면 `enact_applied` 가
`false` 이고 SoC 회복도 안 일어난다)은 그대로 결정 행에 실린다.
"""
function enact_decision!(env, truth, decision)
    local mac = decision.macro_name
    # 🔴 이 두 줄이 이 계획의 분수령이다. 여기까지 LLM 의 tool 호출은 세계에 대해 인과가
    # 없었다 — 집행 사슬이 `truth.robot`(주입기가 이미 아는 값)을 썼기 때문이다.
    local tgt = enact_target(env, truth, (try decision.tool_lane catch; nothing end),
                             (try decision.router catch; nothing end), mac)
    # 🔴 사슬을 **감싸서** 부른다(T5). `enact_with_efficacy!` 는 `enact_macro!` 을 그대로
    # 호출하고(사슬 본체는 한 줄도 안 바뀐다) 그 **앞뒤**에서 `zone_blockage` 순수 술어를
    # 잰다. 전후 **차이**를 재는 것이 핵심이다: 사후 상태만 보면 "막힐 것이 없었다"와
    # "막힘을 풀었다"가 같은 관측이 된다.
    local res = enact_with_efficacy!(env, truth, mac, tgt.agent)
    return (target = tgt, enacted = res, row = Dict{String,Any}(
        # ---- 집행 대상 agent (T2, 컨트롤러 판정 R2/R6) --------------------------------
        # 🔴 조용한 폴백은 이 태스크를 무의미하게 만든다: 폴백이 기록되지 않으면 "LLM 이
        # 골랐다" 와 "주입기가 알려줬다" 가 **같은 관측**이 된다.
        # ⚠️ 넷은 **항상 존재**한다. 키 부재와 값 `nothing` 을 섞지 않는다.
        "tool_agent"         => tgt.tool_agent,   # LLM 이 낸 원문(거절된 판에서도 그대로)
        "enact_agent"        => (tgt.agent === nothing ? nothing : string(tgt.agent)),
        "enact_agent_source" => tgt.source,       # "tool" | "truth" | "none"
        "enact_agent_reject" => tgt.reject,       # source=="tool" 이면 nothing
        # ---- 접지 판정 (T3, 컨트롤러 판정 R9) ------------------------------------------
        # 🔴 값은 **삼상**이고 소비자 규약은 **접두사 비교**다(spec §9-2, 커밋 afe38dd9):
        #   "admit" | "reject:<reason>" | "deferred:<reason>"
        # `deferred` 를 `admit` 으로 접지 않는다 — "잴 것이 없었다" 를 통과로 세면 접지
        # 통과율을 세는 사람이 NOOP 을 통과로 센다.
        "verify"             => tgt.verify,
        "verify_detail"      => tgt.verify_detail,
        # ---- 집행 사슬이 실제로 뭔가 했는가 --------------------------------------------
        # `deviate_valid`(메뉴 질문)와 다른 질문이다(2026-08-17 재리뷰 F2).
        "enact_applied"      => res.enact_applied,
        # G6 — `f` 무솔버 불변식(spec §5.5).
        "ran_milp"           => res.ran_milp,
        # ---- ④ 실효성 층 (spec §9-2) ---------------------------------------------------
        # 🔴 `efficacy_checked_paths` 를 같이 싣는 이유(컨트롤러 판정 R12): 결정 경로의
        # `zone_blockage` 는 `check_paths=false` 로 불리므로 `n_disconnected` 가 언제나 0 이다.
        # ⚠️ zone 이 아닌 사건에서는 `nothing`(아예 안 쟀다) — `false`(경로를 안 봤다)가 아니다.
        "efficacy"               => res.efficacy,
        "efficacy_checked_paths" => res.efficacy_checked_paths))
end

# =============================================================================
# ⑤ 합성 tool 집행 진입점 (2026-08-30, T4) — 여기서 합성 tool 이 세계에 대한 인과를 얻는다.
# =============================================================================

"""
    _synth_lane_field(sl, key) -> Any

합성 레인 dict 에서 필드 하나를 읽는다. 없으면 `nothing`.

🔴 왜 자체 헬퍼인가. 이 dict 은 두 모양으로 도착한다 — 생산 경로는
`policy.jl::_synth_view` 가 만든 **String 키** `Dict{String,Any}` 이고, 게이트와 루프백은
`JSON3.Object`/NamedTuple 이라 **Symbol 키**다. 한쪽만 보면 다른 쪽에서 조용히 `nothing`
이 나오고, 그 `nothing` 은 "서비스가 안 실었다"와 **글자 그대로 같은 관측**이 된다(spec §9-2).
`policy.jl::_synth_view` 가 같은 이유로 같은 왕복을 한다.
"""
function _synth_lane_field(sl, key::AbstractString)
    sl === nothing && return nothing
    v = try get(sl, key, nothing) catch; nothing end
    v === nothing && (v = try get(sl, Symbol(key), nothing) catch; nothing end)
    return v
end

"""
    minted_handled(r) -> Bool

🔴 **`handled` 4-연언지의 정본은 이 함수다.** `CB.enact_minted!` 의 결과 네임드튜플 하나를
받아 "이 사건은 합성 tool 이 처리했으니 기본 복구 사슬을 타지 말라" 를 판정한다.
`CB.minted_handled_verdict_ok` 의 이웃이다 — 그 함수가 **첫** 연언지를 답하고, 이 함수가
그것을 부르며 나머지 셋을 더한다.

| 연언지 | 왜 |
|---|---|
| `CB.minted_handled_verdict_ok(verdict)` | 집행된 verdict 로 등재된 것만 통과(정본은 `CB.ENACTED_VERDICTS` — 크기를 여기 다시 안 적는다. 2026-09-03 최종 리뷰 F6: 2026-09-02 결정 2·3 이 둘로 넓혔던 것을 Task 9(R1)가 다시 하나로 좁혔다) |
| `world_maybe_dirty` | 🔴 `applied` 가 **아니다** — 조용한 성공은 폴백해야 하고, 던져서 세계가 절반인 판은 폴백하면 안 된다 |
| `resume !== :failed` | 세계는 고쳤는데 프론티어가 낡았다 = 성공과 구별되지 않는 미복구 |
| `!resolve_failed` | 재풀이가 `:infeasible`/`:commit_failed`/`:threw` = 간선을 뗐는데 아무도 재배정 못 했다 |

🔴 **이 식을 어디에도 베끼지 마라 — 이름으로 불러라.** 손으로 베낀 3-연언지 복사본이
프로덕션 4-연언지와 이미 갈렸던 것이 실측됐다(2026-09-02 T0). 소비자가 둘이다:
아래 `enact_minted_decision!` 과 `tools/probes/probe_minted_body_enacts.jl`.
"""
function minted_handled(r)
    local resolve_failed = r.resolve === :infeasible || r.resolve === :commit_failed ||
                           r.resolve === :threw
    return CB.minted_handled_verdict_ok(r.verdict) && r.world_maybe_dirty &&
           (r.resume !== :failed) && !resolve_failed
end

"""
    _interface_calls_of(name) -> Union{Nothing,Vector{String}}

주조된 원시 하나의 **L3 증거**(spec §0). 삼상이다: `nothing`("못 쟀다") · `String[]`
("재서 없다") · 비지 않은 정렬된 목록(L3 참, 증거는 목록 자체).

🔴 **판정을 여기서 다시 하지 않는다.** 값을 만드는 것은 `impl_interface_calls(code)`
(`src/respec/minted_registration.jl`)이고 `register_minted_primitive!` 이 `Core.eval`
**전에** 등록 행에 싣는다. 이 함수는 그 행을 `CB.resolve_primitive` 를 통해 **읽기만**
한다 — 인터페이스 술어가 두 곳에 살면 기록에 실린 값의 뜻이 나중 필터에 달린다.

🔴 **절대 안 던진다.** `resolve_primitive` 는 설계상 `error(...)` 를 낼 수 있고
(표의 행이 이름 짓는 impl 이 CB 에 없는 손씨앗 행), 이 호출은 집행 **전** 자리라 그
예외가 새면 세계를 안 건드린 판이 "던졌다" 로 기록된다. 못 읽으면 `nothing` 이다.
"""
_interface_calls_of(name) =
    try
        local p = CB.resolve_primitive(String(name))
        p === nothing ? nothing : p.interface_calls
    catch
        nothing
    end

"""
    _rec_line(parts...) -> Nothing

`[minted]` **기록 줄** 하나를 찍는다. 조각을 이어 붙인 뒤 **공백을 한 번 접어** 정확히 한
줄로 만든다.

🔴 **왜 (D8, Wave D).** 이 파일의 기록 줄은 유료 런의 채점 채널이다 — `world_delta`
   와 `interface_calls` 를 `[minted]` 줄을 grep 해서 읽는다(사전등록 결정). 그런데 줄에
   실리는 값 여럿이 **모델이 준 문자열**이고(`tool_name` · 등록 거절 사유에 보간된
   `impl_name` · `steps` 의 detail · 예외 메시지), 그중 하나에 개행이 있으면 **기록이 두
   줄로 쪼개진다.** 실측(검증자): `impl_name` 에 개행이 든 판(`"bad" * 개행 * "name!"`)으로 `enact_minted_decision!`
   을 끝까지 몰면 `[minted]` 줄이 실제로 쪼개졌다.
🔴 **접는 자리가 하나여야 한다.** 값마다 손으로 접으면 새 값을 더하는 사람이 그것을
   빠뜨리고, 그 누락은 라이브에서 파서가 한 줄을 잃는 것으로만 드러난다(에러가 아니다).
   그래서 **줄 전체**를 여기서 한 번 접는다 — 이 함수를 지나는 한 어떤 값도 못 새어 나간다.
   `enact_minted!` 쪽의 짝은 `_r` 의 `_one_line`(`src/respec/minted_tool.jl`)이고, 그것은
   **사유 문자열**을 접는다. 두 자리는 서로 다른 것을 접는다(줄 vs 사유) — 겹치지 않는다.
⚠️ 잘 만들어진 줄에는 **무동작**이다: 조각 사이 구분자가 전부 단일 공백이라
   `r"\\s+" => " "` 가 아무 바이트도 안 바꾼다(Task 7 fix2 가 `_r` 에서 같은 논거로 확인).
   그래서 로그 문구를 못박는 시험((17))은 바이트 동일로 초록이다.
"""
_rec_line(parts...) = println(_one_line_rec(string(parts...)))

"기록 줄 하나를 한 줄로 접는다. D8 의 술어이고 진실원은 여기 하나다."
_one_line_rec(x::AbstractString) = String(strip(replace(x, r"\s+" => " ")))

"""
    _STEP_DETAIL_CAP

기록 줄·결정 행에 실리는 스텝 `detail` 하나의 **문자 수 상한**. 진실원은 여기 하나다.

🔴 왜 상한이 필요한가 (2026-09-04, Task 1). `detail` 은 **모델과 예외에서 오는 임의
   문자열**이다. 던진 스텝의 것은 `first(split(sprint(showerror, e), "\n"))`
   (`src/respec/minted_tool.jl` 의 catch 절)이라 한 줄이긴 한데, `MethodError` 의 **첫
   줄**은 후보 메서드를 이어 붙여 수 KB 가 될 수 있다. 기록 줄은 grep 대상이므로
   (`[minted] lane=` 한 줄 = 한 판) 한 판이 로그를 통째로 삼키면 안 된다.
⚠️ 200 은 "충분히 크다" 가 아니라 **판독 가능한 상한**이다. 잘린 것은 말미의 `…` 가
   말한다 — 자르지 않은 것과 구별이 된다.
"""
const _STEP_DETAIL_CAP = 200

"""
    _step_detail_render(d) -> String

스텝 `detail` 하나를 **한 줄로 접고 `_STEP_DETAIL_CAP` 자로 자른** 문자열. 자르면 말미에
`…` 를 붙인다(자른 것과 원래 짧은 것을 구별하기 위해서다).

🔴 **기록 줄과 결정 행이 이 함수 하나를 쓴다.** 두 자리에 따로 적으면 상한이 갈리고,
   그 갈림은 "행의 detail 과 줄의 detail 이 다르다" 로만 드러난다(에러가 아니다) —
   이 파일이 `_world_delta_str`(m3/m4)에서 이미 한 번 밟은 실패 모드다.
⚠️ 줄 접기는 `_rec_line` 이 줄 **전체**에 대해 한 번 더 한다(D8). 여기서 또 접는 이유는
   **결정 행**은 그 자리를 안 지나가기 때문이다 — 행의 값은 `_rec_line` 을 안 탄다.
"""
function _step_detail_render(d)
    d === nothing && return ""
    return _cap_detail(_one_line_rec(string(d)))
end

"단 하나의 자르는 자리. 자르면 말미에 `…` 를 붙인다 — 자른 것과 원래 짧은 것을 구별한다."
_cap_detail(t::AbstractString) =
    length(t) > _STEP_DETAIL_CAP ? first(t, _STEP_DETAIL_CAP) * "…" : t

"""
    _neutralize_brackets(t) -> String

`(` `[` → `<` · `)` `]` → `>`. **기록 줄의 괄호 중화의 진실원은 여기 하나다.**

🔴 왜 하나여야 하나 (2026-09-04 fix round 2, N2). 초판은 이 치환을 `_step_detail_line` 안에
   인라인으로 적었고, 그래서 **detail 만** 안전해졌다. 그런데 `steps=[...]` 항목은
   `name:status(detail)` 이고 `status` 도 **모델이 쓴 텍스트**다
   (`_step_status` 가 `Symbol(getproperty(out, :status))` 로 만든다 —
   `src/respec/minted_tool.jl`). `status = "moved 3 robots [east"` 를 내는 body 하나가
   F2 가 닫은 그 실패를 그대로 재현한다: 채점기가 `']' never balances` 로 죽는다.
   치환이 두 자리에 있으면 세 번째 자리를 더하는 사람이 또 빠뜨린다.

⚠️ ASCII 만 쓴다. 넷을 두 글자로 접는 것은 의도이고(남는 괄호 가족이 없어야 어떤 깊이
   추적도 못 속인다), **1:1 문자 대응**이라는 성질이 `_step_detail_line` 의 상한 계산을
   `_step_detail_render` 와 바이트 동일하게 유지한다 — 폭이 다른 글자로 바꾸면 그것이 깨진다.
"""
_neutralize_brackets(t::AbstractString) =
    replace(t, '(' => '<', ')' => '>', '[' => '<', ']' => '>')

"""
    _step_detail_line(d) -> String

**기록 줄**에 실릴 detail. `_step_detail_render` 와 같은 접기·같은 상한이되, 그 사이에
**괄호류를 중화**한다: `(` `[` → `<`, `)` `]` → `>`.

🔴 왜 (2026-09-04 fix round 1, F2). 기록 줄의 `steps=[...]` 는 **구조**다. 채점기
(`tools/monitor/ladder_report.py`)가 `steps=[` 에서 깊이를 세어 닫는 `]` 를 찾고, 각 항목의
`name:status(detail)` 도 괄호 깊이로 detail 을 되찾는다. 그런데 `detail` 은 예외 메시지라
`BoundsError: … at index [4]` · `no method matching f(::Vector{Int64}, ::Int64)` 처럼
괄호류를 **일상적으로** 담는다. 그 자체는 균형이 맞아 괜찮은데 — 🔴 **200자에서 자르는 순간
균형이 깨진다.** `steps=[f!:threw(… at index [4…)]` 는 원리적으로 파싱 불가이고
(`ValueError: ']' never balances`), 그러면 L2b 가 **UNMEASURED** 로 떨어진다. 짝 없는 `]`
하나는 더 나쁘다 — 채점기가 거기서 `steps=` 를 **조용히 일찍 닫는다**(에러가 아니다).
이 결함은 옛 `name:status` 포맷에서는 **구조적으로 불가능**했다. Task 1 의 포맷 변경이
들여온 것이고, 하필 L2b 는 이번 유료 런이 움직이려는 바로 그 칸이다.

🔴 **파서로는 못 고친다.** 균형이 깨진 채 잘린 문자열은 원리적으로 파싱 불가다. 그래서
고치는 자리가 **여기**, 렌더러다.

🔴 **중화를 자르기 앞에 한다.** 그래야 자르는 자리가 어디든 — 원문에서 괄호 한복판이었든 —
**이 함수가 낸 문자열**에 추적되는 괄호가 하나도 없다. 순서가 뒤바뀌면 이 함수는 다시 깨진다.
⚠️ 🔴 **그 보장은 `detail` 에 한정된다 — 항목 전체가 아니다**(2026-09-04 fix round 2, N2 가
잡았다: 이 문단의 초판이 자기 보장을 과장해 적고 있었다). 항목은 `name:status(detail)` 이고
`status` 도 모델이 쓴 텍스트다. 항목 수준의 보장은 `_step_render` 가 소유한다.
⚠️ 치환은 1:1 문자 대응이라 상한 자리가 `_step_detail_render` 와 **바이트 단위로 같다**.

⚠️ ASCII 만 쓴다. 넷을 두 글자(`<` `>`)로 접는 것은 의도다: 남는 괄호 가족이 하나도 없어야
어떤 소비자의 깊이 추적도 못 속인다. 판독성은 산다 —
`no method matching length<::Symbol>` 은 여전히 읽힌다. 🔴 **깨진 L2b 는 아무것도 안 살린다.**

🔴 **결정 행(`_steps_row`)은 중화하지 않는다.** 그쪽은 JSON 문자열이라 괄호가 어떤 구조도
못 닫는다 — 원문 그대로가 더 높은 충실도다. 접기·상한이라는 **위험한 부분은 여전히 한 자리**
(`_cap_detail`·`_one_line_rec`)이고, 갈리는 것은 이 네 글자뿐이다.
"""
_step_detail_line(d) =
    d === nothing ? "" : _cap_detail(_neutralize_brackets(_one_line_rec(string(d))))

"""
    _step_render(s) -> String

기록 줄의 `steps=[...]` 조각 하나. `detail` 이 있고 비어 있지 않으면
`name:status(detail)`, 아니면 **오늘과 바이트 동일한** `name:status`.

🔴 왜 (2026-09-04, Task 1). 유료 런 1 이 `:threw` 로 죽었는데 **어떤 예외인지 어디에도
   없었다** — 실행자가 격리 프로브로 사후에 재유도해야 했다. 그런데 메시지는 이미
   `steps` 에 실려 있었다(`minted_tool.jl` 의 catch 절이 `showerror` 의 첫 줄을 담는다).
   버려지던 자리가 여기 하나였다. **새 채널을 만드는 것이 아니라 있는 값을 안 버린다.**
⚠️ `detail` 이 없는 스텝 모양(`hasproperty` 거짓)은 구세대 집행부의 것이다 — 그 판은
   오늘과 바이트 동일하게 찍힌다. 그래서 로그 문구를 못박는 기존 게이트가 안 움직인다.

🔴 **항목 전체의 괄호 안전은 이 함수가 소유한다**(2026-09-04, F2 + fix round 2 N2).
   이 줄의 `steps=[...]` 는 채점기(`tools/monitor/ladder_report.py`)가 깊이로 읽는
   **구조**이고, 짝 없는 괄호 하나가 그것을 원리적으로 파싱 불가로 만든다. 항목의 세 조각 중
   **둘이 모델의 텍스트**다: `detail`(잘리기까지 한다)과 `status`
   (`_step_status` 가 `Symbol(getproperty(out, :status))` 로 만든다). 그래서
   `_neutralize_brackets` 가 `name:status` 에 한 번, `_step_detail_line` 안에서 detail 에
   한 번 걸린다 — 이 함수를 지나는 한 항목이 바깥 `[` 를 못 닫는다.
   ⚠️ F2 하나만 했을 때 이 보장은 **detail 에만** 있었고, `status = "moved 3 robots [east"`
   를 내는 body 하나가 L2b 를 UNMEASURED 로 되돌렸다(N2 실측).
"""
function _step_render(s)
    # 🔴 `status` 도 중화한다 (2026-09-04 fix round 2, N2). 그것은 상수 어휘가 아니라
    #    **모델이 쓴 텍스트**다 — `_step_status` 가 `Symbol(getproperty(out, :status))` 로
    #    만든다. `name` 은 식별자 규약을 통과한 것이라 오늘은 괄호를 못 담지만, 같은 함수를
    #    통과시켜 "어느 조각이 안전한가" 를 여기서 따지지 않게 한다.
    # ⚠️ `name`·`status` 는 **안 자른다** — 그래서 F2 가 세운 상한·바이트 동일성 논증은
    #    이 변경에 영향받지 않는다.
    local base = _neutralize_brackets(string(s.name, ":", s.status))
    local t = _step_detail_line(hasproperty(s, :detail) ? s.detail : nothing)
    return isempty(t) ? base : string(base, "(", t, ")")
end

"""
    _is_countable_world_set(x) -> Bool

`length(x)` 가 **세계의 크기**를 뜻하는 모양인가. D7 의 술어이고 진실원은 여기 하나다
(`_world_digest` 의 두 축이 이것을 부른다 — 같은 판정을 두 곳에 적지 않는다).

🔴 생산 타입은 둘 다 `Set` 이다: `closed_set::Set{Int}`(`essential_tg_coponents.jl`) ·
`active_build_steps::Set{AbstractID}`(`route_planning.jl`). 그래서 술어가 `AbstractSet` 이다.
넓히면(예: "문자열이 아니다") `length` 가 성공하는 다른 모양들이 다시 수를 지어낸다.
"""
_is_countable_world_set(x) = x isa AbstractSet

"""
    _staging_snapshot(x) -> Union{Nothing,Dict{Any,NTuple{3,Float64}}}

`env.staging_circles` 를 **스칼라로** 뜬 기하 지문. 못 읽으면 `nothing`(= 그 **축 하나만**
"못 쟀다"). 진실원은 `PlannerEnv.staging_circles::Dict{AbstractID,LazySets.Ball2}`
(`src/route_planning.jl`)이다.

🔴 **왜 객체가 아니라 스칼라 세 개인가**(2026-09-05, B1). `weights` 가 `copy` 로 산 그 위험의
   한 겹 아래다: `Dict` 만 얕게 뜨면 값은 `Ball2` **객체**이고, 누군가 `b.center .+= Δ` 로
   제자리 편집하는 순간(그 필드는 `Vector{Float64}` 다 — 가변이다) 사전 지문이 사후와 같은
   객체를 가리켜 차분이 **언제나 0** 이 된다. `(cx, cy, r)` 를 그 자리에서 읽어 두면 오늘의
   두 mutator(둘 다 새 `Ball2` 를 **대입**한다)에도, 제자리 편집하는 미래의 셋째에도 산다.

🔴 **`r` 까지 담는 이유**: 적치원의 반지름도 기하다. 오늘의 두 mutator 는 `R` 을 보존하지만
   (`restage_assembly!` 의 `Ball2(c1, R)`), 반지름이 변하는 편집을 "안 움직였다" 로 읽을
   이유가 없다.

⚠️ 2차원만 본다(`c[1:2]`). `translate_whole_build!` 의 Δ 가 `(dx, dy, 0)` 이고
   `env.staging_circles` 의 원이 평면 원이기 때문이다(`_apply_uniform_translation!`).
   좌표가 둘 미만이면 **모양을 모르는 것**이라 `nothing` 이다.
"""
function _staging_snapshot(x)
    x isa AbstractDict || return nothing
    try
        local out = Dict{Any,NTuple{3,Float64}}()
        for (k, b) in x
            local c = CB.get_center(b)
            length(c) >= 2 || return nothing
            out[k] = (Float64(c[1]), Float64(c[2]), Float64(CB.get_radius(b)))
        end
        return out
    catch
        return nothing
    end
end

"""
    _world_digest(env) -> Union{Nothing,NamedTuple}

값싼 세계 지문. 집행 **전후**로 찍어 차분을 낸다. 못 찍으면 `nothing`("못 쟀다").

🔴 **왜 필요한가**(사전등록 결정 1 = R11). 오늘의 관측 넷 중 어느 것도 "세계가 바뀌었다" 를
   못 잰다: `handled` 는 생성 body 면 구성상 ~100%(`minted_handled` 의 네 연언지가 전부
   참이 되는 것이 무동작 body 의 **정상**이다 — `test/minted_end_to_end.jl` (6) 이 그것을
   실측한다), `applied` 는 생성 원시의 status 어휘가 없어 항상 `nothing`,
   `world_maybe_dirty` 는 가능성 술어라 무조건 `true`, `steps.status` 는 모델의 자기신고다.
   이 함수는 그 넷과 달리 **세계를 직접 읽는다**.

🔴 **예외가 아니라 `nothing` 이다.** 여기서 예외가 새면 `enact_minted_decision!` 이 기록
   대신 예외로 끝나고 호출자는 세계 상태를 통째로 잃는다. `env` 는 이 함수의 계약을 모르는
   임의의 모양으로 온다(시험 픽스처 · 부분 env) — 필드가 없으면 그냥 못 잰 것이다.

🔴 **다섯을 전부 읽어야 지문이다**(2026-09-04 Task 2 가 `weights` 를 더해 넷 → 다섯이
   됐다). 하나라도 못 읽으면 `nothing` 을 낸다 — 반쯤 잰 지문의 차분은 무엇을 뜻하는지
   아무도 적을 수 없고, 그 모호함이 정확히 이 필드가 없애려는 것이다.

🔴 **여섯째 축 `staging` 은 그 전부-아니면-무 밖에 있다 — 일부러다**(2026-09-05, B1).
   앞 다섯은 전부 배정/스케줄 그래프 위에 있어서, **기하 수리**(`translate_whole_build!` ·
   `restage_all_blocked!` 가 `start_config` 변환과 `env.staging_circles` 를 옮긴다)를 한
   축도 못 본다. 2026-09-05 실측: 손으로 쓴 zone 오라클이 빌드를
   `n_closed=270/305`(INCOMPLETE) → `287/305`(COMPLETE) 로 끌어올렸는데
   `world_delta_body` 의 다섯 축이 **전부 0** 이었다 — 계측기가 측정된 양성을 측정된 0 으로
   읽었다(이 레포가 기록한 최악의 실패 모드).
   🔴 **그런데 여섯째를 앞 다섯과 같은 전부-아니면-무로 두면 계측기가 넓어지는 게 아니라
   좁아진다.** 오늘 그 다섯을 못박는 픽스처들(`live_cache_env()` · `aliased_active_env()`
   — `test/minted_end_to_end.jl` (10)(11)(15)(26e)(28))에는 `staging_circles` 가 **없다**.
   전부-아니면-무였다면 그 판들의 지문이 통째로 `nothing` 이 되어 **기하 축을 더한 대가로
   기존 다섯이 눈을 감는다.** 그래서 이 축은 **축 자신이 삼상**이다:
   `nothing`(이 env 에서 기하를 못 읽었다) ≠ `Dict`(읽었다 — 비었어도 읽은 것이다).
   ⚠️ 규약은 안 깨진다. "못 쟀다 ≠ 쟀는데 0" 이 지문 **전체**가 아니라 **축마다** 살아
   있을 뿐이고, `_world_delta` 가 그것을 `n_staging_moved::Union{Nothing,Int}` 로 그대로
   내보내며 로그·결정 행·채점기가 셋을 셋으로 나른다.
   🔴 `hasproperty` 로 읽는다 — `env.staging_circles` 를 맨 필드 접근으로 읽으면 그 필드가
   없는 env 에서 **던지고**, 아래 `catch` 가 그것을 통째 `nothing` 으로 삼켜 정확히 위에서
   피하려던 그 실명이 된다.

🔴 **`weights` 는 스냅샷이다(`copy`).** 접근자가 살아 있는 `Dict` 를 참조로 돌려주므로,
   안 뜨면 사전 지문이 body 가 편집하는 그 dict 을 가리켜 차분이 **언제나 0** 이 된다.
   `binding` 에는 같은 위험이 없다(`assignment_binding` 이 호출마다 새 Dict 을 짓는다).

⚠️ `binding` 은 **하한**이다(정본 근거는 `assignment_binding`(`src/respec/common_resolve.jl`)
   의 docstring — 팀이 맡은 정점은 정렬 첫째만 담는다). 그래서 아래 `n_binding_changed` 가
   0 이 아니면 배정이 확실히 바뀐 것이고, **0 이라고 안 바뀐 것은 아니다.**

⚠️ `CB.Graphs` 로 부른다(맨 `Graphs` 가 아니라). 이 파일은 `using Graphs` 를 안 하는 모듈로도
   include 된다 — 맨 이름을 쓰면 `UndefVarError` 가 나고 위 `catch` 가 그것을 `nothing` 으로
   삼켜 **다이제스트가 조용히 영영 꺼진다**(`ConstructionBots` 는 `Graphs` 를 export 하지
   않는다).
   🔴 **여기 있던 예(`test/minted_end_to_end.jl` 이 그렇다)는 틀렸었다**(2026-09-03 리뷰 m1):
   그 파일은 `policy.jl` 을 먼저 include 하고 `policy.jl` 이 `using Graphs` 다 — 그래서 그
   파일에서는 맨 이름도 잘 돈다. 진짜로 `Graphs` 가 없는 includer 는 넷이다(실측):
   `tools/probes/probe_minted_body_enacts.jl` · `tools/monitor/test_minted_wiring.jl` ·
   `test/enact_uses_llm_agent.jl` · `test/efficacy_measures_the_edit.jl`.
   🔴 그리고 그 위험은 2026-09-04 까지 **미게이트**였다(검증자의 변이 M3: 맨 이름으로
   되돌려도 두 게이트가 전부 초록). 지금은 `test/minted_end_to_end.jl` (18) 이 예를
   인용하는 대신 **`Graphs` 없는 모듈을 실제로 만들어** 지문이 나오는지 보고, 같은 자리에서
   맨 이름 사본이 `nothing` 을 내는 것을 음성 대조로 확인한다.
"""
function _world_digest(env)
    try
        # 🔴 **D7 (Wave D). 모양을 먼저 본다 — `try` 로는 못 막는 자리다.**
        #    Wave A 자체 발견 1 과 **같은 부류**이고(그 근거는 `_world_delta` 의 같은 가드가
        #    소유한다), 검증자가 이 위쪽 짝이 아직 열려 있는 것을 실측했다:
        #      `closed_set = "abcdefghij"` → `closed = 10` · `active_build_steps = "xyz"` →
        #      `active = 3`. **둘 다 안 던진다.** 예외라면 아래 `catch` 가 `nothing`
        #      ("못 쟀다")으로 바꿔 주는데, 이 수들은 **"쟀다" 를 참칭한다**.
        # 🔴 여기가 `_world_delta` 보다 한 겹 더 나쁘다: 이 함수의 docstring 이 임의의
        #    env 모양을 **의도된 입력**이라고 적으므로(시험 픽스처·부분 env), 읽는 사람에게
        #    그 수가 허구라는 신호가 하나도 없다.
        # ⚠️ "진짜 `PlannerEnv` 로는 도달 불가" 는 근거가 못 된다 — Wave A 가 `_world_delta`
        #    에서 바로 그 논거를 불충분하다고 판정하고 가드를 넣었다. 같은 기준이다.
        # 🔴 술어가 "문자열이 아니다" 가 **아니라** "집합이다" 인 이유: `length` 를 갖는
        #    모양은 문자열 말고도 많고(`Vector`·`Dict`·`Tuple`), 그 어느 것도 이 두 축의
        #    생산 타입이 아니다 — `closed_set::Set{Int}`(`essential_tg_coponents.jl`) ·
        #    `active_build_steps::Set{AbstractID}`(`route_planning.jl`)가 진실원이다.
        #    좁은 술어라야 "센 수가 무엇의 크기인가" 가 한 가지 뜻만 갖는다.
        # 🔴 `n_edges`·`binding` 축은 이미 **던지는** 쪽이다(`Graphs.ne` 와
        #    `assignment_binding` 은 엉뚱한 모양에서 `MethodError` 를 낸다) — 그래서 아래
        #    `catch` 가 그 둘을 정직하게 `nothing` 으로 바꾼다. 여기 가드가 필요한 것은
        #    **`length` 가 조용히 성공하는 두 축**뿐이다.
        _is_countable_world_set(env.cache.closed_set) || return nothing
        _is_countable_world_set(env.active_build_steps) || return nothing
        # 🔴 **다섯째 축 (2026-09-04, Task 2). `sched.weights`.** 유료 런 1 의 body 는 정확히
        #    이것을 편집했는데 네 축이 전부 0 이었다 — 그러면 로그가 "안 바뀌었다" 와 "그
        #    축을 안 잰다" 를 같은 관측으로 만든다. 진실원은 `OperatingSchedule.weights`
        #    (`src/essential_tg_coponents.jl`)이고 읽는 자리는 접근자 하나다.
        #    ⚠️ **동명이인 주의**: `MultiDeadlineCost.weights::Vector{Float64}` 는 무관하다.
        # 🔴 **스냅샷을 뜬다 — `copy` 가 하중을 진다.** `get_root_node_weights` 는 살아 있는
        #    `Dict` 를 **참조로** 돌려준다(`sched.weights` 그 자체). 안 뜨면 `_pre` 의
        #    weights 가 body 가 편집하는 바로 그 dict 을 가리켜 차분이 **언제나 0** 이 된다 —
        #    "안 바꿨다" 를 참칭하는, 이 파일이 도처에서 막는 그 사고다.
        #    ⚠️ `binding` 에는 같은 위험이 **없다**: `assignment_binding`
        #    (`src/respec/common_resolve.jl`)이 호출마다 새 `Dict{Int,Int}` 를 짓는다(실측).
        # 🔴 모양 가드는 전부-아니면-무 규약이다(위 두 축과 같은 이유): `AbstractDict` 가
        #    아니면 지문 자체가 `nothing` 이다. `env.sched` 가 아예 없거나 접근자가 던지면
        #    아래 `catch` 가 이미 `nothing` 을 낸다.
        local w = CB.get_root_node_weights(env.sched)
        w isa AbstractDict || return nothing
        # 🔴 **여섯째 축 (2026-09-05, B1). 기하.** 위 문단이 근거를 소유한다. 두 mutator 가
        #    쓰는 자리가 이 필드다(`src/respec/restage_zone.jl`):
        #      · `_apply_uniform_translation!` — `env.staging_circles[aid] = LazySets.Ball2(...)`
        #      · `restage_assembly!`           — `env.staging_circles[assembly_id] = LazySets.Ball2(c1, R)`
        #    ⚠️ 이 축은 **가드 자리에 안 온다** — 위 셋과 달리 못 읽어도 지문은 산다.
        local staging = _staging_snapshot(hasproperty(env, :staging_circles) ?
                                          env.staging_circles : nothing)
        return (closed   = length(env.cache.closed_set),
                active   = length(env.active_build_steps),
                n_edges  = CB.Graphs.ne(env.sched.graph),
                binding  = CB.assignment_binding(env.sched),
                weights  = copy(w),
                staging  = staging)
    catch
        return nothing
    end
end

"""
    _world_delta(a, b) -> Union{Nothing,NamedTuple}

두 지문의 차분. 한쪽이라도 `nothing` 이면 `nothing`("못 쟀다").

🔴 **`n_staging_moved` 은 축 자신이 삼상이다**(2026-09-05, B1) — 나머지 다섯이 수인 채로
   이 축만 `nothing` 일 수 있다. 근거는 `_world_digest` 의 docstring 이 소유한다.

🔴 **삼상**: `nothing`(못 쟀다) ≠ 0 의 튜플(쟀는데 안 바뀌었다). 무동작 body 가 오늘의
   지배적인 판이므로(위 R11 문단) 그 둘을 뭉개면 이 필드는 **모든** 판에서 `nothing` 으로
   보이고 아무것도 안 재게 된다. `test/minted_end_to_end.jl` (11) 이 그 구별을 못 박는다.

🔴 **`_world_digest` 와 같은 이유로 던지지 않는다**(2026-09-03 리뷰 m5). 초판에는 이
   `try`/`catch` 가 없었다. `binding` 이 `Dict` 가 아니면 여기서 던지는데(실측:
   `binding = "not a dict"` → `BoundsError`) 이 호출은 `CB.enact_minted!` 가 **이미 돌아온
   뒤**라서, 그 예외를 바깥 `catch` 가 삼키면 **body 가 이미 세계를 편집한 판**이
   `verdict=:reject reason="… threw"` 로 기록된다 — `_world_digest` 가 막겠다고 적은 사고의
   나머지 반쪽이다. 오늘은 `assignment_binding` 이 `Dict{Int,Int}` 를 무조건 내므로 도달
   불가지만, 도달 불가에 기대는 것과 못 던지게 막는 것은 다르다.
"""
function _world_delta(a, b)
    (a === nothing || b === nothing) && return nothing
    # 🔴 `try`/`catch` 로는 **못 막는 자리**가 하나 있다(2026-09-04 실측). `binding` 이
    #    `String` 이면 이 함수는 던지지 않는다 — `String` 이 `get`·`keys` 를 둘 다 갖고 있어서
    #    아래 두 루프가 조용히 돌고 `n_binding_changed = 10`(= 문자열의 길이)이라는 **거짓
    #    측정값**이 나온다(`_world_delta((…, binding="not a dict"), (…, binding=Dict(1=>1)))`
    #    실측). 예외라면 아래 `catch` 가 `nothing`("못 쟀다")으로 바꿔 주는데, 이 모양은
    #    "쟀다" 를 참칭한다 — 삼상 규약이 막으려는 것 그 자체다. 그래서 모양을 먼저 본다.
    (a.binding isa AbstractDict && b.binding isa AbstractDict) || return nothing
    # 🔴 다섯째 축(2026-09-04, Task 2)의 가드. **`binding` 가드와 같은 이유·같은 모양**이다:
    #    문자열이 오면 `get`·`keys` 가 둘 다 성공해 아래 루프가 조용히 돌고 길이가 측정값을
    #    참칭한다(그 결함이 `binding` 에서 실제로 났다).
    # ⚠️ `hasproperty` 를 **먼저** 본다. 다섯째 축 이전 세대의 네-필드 지문이 오면
    #    `a.weights` 가 **던지고** 그 예외는 `try` 밖이라 아무도 안 삼킨다 — 그러면 계측이
    #    집행을 죽인다. 그 판은 `nothing`("못 쟀다")이다.
    (hasproperty(a, :weights) && hasproperty(b, :weights)) || return nothing
    (a.weights isa AbstractDict && b.weights isa AbstractDict) || return nothing
    try
        changed = 0
        for (v, r) in b.binding
            get(a.binding, v, nothing) === r || (changed += 1)
        end
        for v in keys(a.binding); haskey(b.binding, v) || (changed += 1); end
        # 🔴 `!=` 가 아니라 `!isequal` 이다. 값이 `Float64` 라 `NaN != NaN` 이 참이고,
        #    그러면 **아무도 안 건드린** NaN 가중치가 매 판 "바뀌었다" 로 센다.
        w_changed = 0
        for (k, v) in b.weights
            isequal(get(a.weights, k, nothing), v) || (w_changed += 1)
        end
        for k in keys(a.weights); haskey(b.weights, k) || (w_changed += 1); end
        # 🔴 **여섯째 축 (2026-09-05, B1). `n_staging_moved` — 이 축만 삼상이다.**
        #    `nothing` = 이 판에서 기하를 못 읽었다(둘 중 하나라도 `staging` 이 없거나
        #    `nothing`) · `0` = 읽었는데 안 움직였다 · `> 0` = 움직인 적치원의 개수.
        #    앞 다섯처럼 통째 `nothing` 으로 접지 **않는** 이유는 `_world_digest` 의
        #    docstring 이 소유한다(그렇게 접으면 기하 축을 더한 대가로 기존 다섯이 눈을 감는다).
        # ⚠️ `hasproperty` 를 먼저 본다 — 여섯째 축 이전 세대의 다섯-필드 지문이 오면
        #    `a.staging` 이 **던지고** 그 예외는 이 `try` 안이라 차분 **전체**가 `nothing` 이
        #    된다(= 계측이 다섯 축까지 끈다). 그 판은 이 축만 "못 쟀다" 다.
        # 🔴 `!=` 가 아니라 `!isequal` 인 이유는 `weights` 와 같다: 좌표가 `Float64` 라
        #    `NaN != NaN` 이 참이고, 그러면 아무도 안 건드린 NaN 좌표가 매 판 "움직였다" 다.
        local n_staging = nothing
        if hasproperty(a, :staging) && hasproperty(b, :staging) &&
           a.staging isa AbstractDict && b.staging isa AbstractDict
            local s_changed = 0
            for (k, v) in b.staging
                isequal(get(a.staging, k, nothing), v) || (s_changed += 1)
            end
            for k in keys(a.staging); haskey(b.staging, k) || (s_changed += 1); end
            n_staging = s_changed
        end
        return (closed = b.closed - a.closed,
                active = b.active - a.active,
                n_edges = b.n_edges - a.n_edges,
                n_binding_changed = changed,
                n_weights_changed = w_changed,
                n_staging_moved = n_staging)
    catch
        return nothing
    end
end

"""
    _world_delta_str(wd) -> String

`world_delta` 를 로그 한 조각으로. **네 로그 자리가 이 함수 하나를 쓴다**(조기 `:deferred` ·
`_reject_malformed` · 성공 · 바깥 `catch`).

🔴 왜 함수인가 (2026-09-03 리뷰 m3·m4). 초판은 자리마다 문자열을 손으로 적었고 그래서 둘이
   갈렸다:
   · m3 — 조기 두 자리는 값을 **안 읽고** `n/a(not measured)` 를 리터럴로 적었다. 오늘은
     참이지만(그 자리들은 지문 앞이다) 거절 자리가 지문 **뒤**로 옮겨지는 순간 그 리터럴이
     조용히 거짓말한다. 이제는 값을 읽으므로 거짓말이 **불가능**하다.
   · m4 — 성공 줄에만 하한 각주가 붙고 catch 줄에는 없었다. 로그를 정규식으로 읽는 소비자가
     같은 사실의 두 모양을 따로 다뤄야 했다.
   `test/minted_end_to_end.jl` (17) 이 리터럴이 한 벌인 것을 어휘적으로 지킨다.

⚠️ 각주가 나르는 사실: `n_binding_changed` 가 나르는 것은 **하한**이다(정본 근거는
   `_world_digest` 의 docstring — `> 0` 은 바뀐 것을 증명하고 `== 0` 은 안 바뀐 것을 증명하지
   못한다).
"""
# 🔴 **`NOT_MEASURED_STR` 이 그 리터럴의 진실원이다** (2026-09-05, B1). 여섯째 축이 삼상이라
#    이 문구를 쓰는 자리가 **둘**이 됐다(지문 전체를 못 쟀다 / 이 축만 못 쟀다) — 손으로 두 번
#    적으면 m3 이 고친 그 사고가 그대로 돌아온다. `test/minted_end_to_end.jl` (17) 이 소스에서
#    이 리터럴을 **한 벌**로 세는 것이 그 못박음이고, 그 게이트를 무르게 하지 않는 유일한 길이
#    이름을 하나 두는 것이다.
# 🔴 여섯째 축은 **다섯 뒤**에 붙인다 (2026-09-05, B1). 앞 다섯의 순서·문구를 한 글자도 안
#    건드리므로 이 줄을 부분문자열로 못박는 기존 게이트들이 그대로 산다(실측: (26e)(28b)).
#    ⚠️ 이 축만 삼상이라 `n/a(not measured)` 를 **축 값 자리에** 찍는다 — 0 과 다른 글자다.
const NOT_MEASURED_STR = "n/a(not measured)"

# 🔴 **D17c (2026-09-05).** 여섯 축의 `key=value` 렌더가 **한 벌**로 떨어져 나왔다 —
#    되먹임 메시지(`_noop_feedback_reason`)가 모델에게 "이 축들이 안 움직였다" 를 말할 때
#    기록 줄과 **같은 글자**를 써야 하기 때문이다. 두 벌을 두면 로그가 말하는 축 이름과
#    전선이 말하는 축 이름이 갈릴 수 있고, 이 파일은 그 종류의 갈림을 m3·m4 에서 이미 겪었다.
#    ⚠️ 출력은 **바이트 동일**하다: 각주는 `_world_delta_str` 이 그대로 붙인다. 전선 메시지는
#    각주를 한국어로 나르지 않고 같은 사실을 영어로 자기 문장에 적는다(그 함수가 소유한다).
_wd_axes_str(wd) =
    string("closed=", wd.closed, " active=", wd.active,
           " n_edges=", wd.n_edges, " n_binding_changed=", wd.n_binding_changed,
           " n_weights_changed=", wd.n_weights_changed,
           " n_staging_moved=", (hasproperty(wd, :n_staging_moved) &&
                                 wd.n_staging_moved !== nothing) ?
                                string(wd.n_staging_moved) : NOT_MEASURED_STR)

_world_delta_str(wd) = wd === nothing ? NOT_MEASURED_STR :
    string(_wd_axes_str(wd), " (n_binding_changed 는 하한이다)")

"""
    _delta_scope(resolve) -> String

`world_delta` 가 **누구의 편집**을 잰 것인가. F4(2026-09-03 리뷰).

🔴 `_issue_resume!` 와 `_resolve_if_needed!` 는 `CB.enact_minted!` **안**에서 불린다
   (`src/respec/minted_tool.jl`). 그래서 `surface ∈ RESOLVE_SURFACES`(= `sched`·`milp`)인
   판에서는 사후 지문에 **하네스의 공통 MILP 재풀이가 한 편집**까지 들어온다. 게다가
   `resolve_assignments!` 의 `n_reassigned` 과 `world_delta.n_binding_changed` 는 **같은
   `assignment_binding`** 에서 나오는, 같은 것을 세는 두 수다 — 그 판의
   `n_binding_changed > 0` 은 "모델이 바꿨다" 가 아니라 "모델이 부른 뒤 하네스가 다시
   풀었다" 일 수 있다.

🔴 **집행을 바꾸지 않는다.** 판독 규칙은 코드 변경 0으로 이미 손에 있었다 — `r.resolve` 가
   같은 반환 튜플과 같은 로그 줄에 있다. 이 함수는 그 판독을 라이브 로그에 **명시**할 뿐이다.
   (`test/minted_end_to_end.jl` (10)(11)(15) 는 전부 `env_param` 이라 `:not_needed_surface`
   다 — 즉 유료 런이 들어갈 수 있는 `sched`/`milp` 체제를 시험이 안 덮는다. 그 사실이
   이 판독을 로그에 적어야 하는 이유다.)

⚠️ 실패 셋과 `:none`(재풀이 자리에 도달 못 한 판정/거절 행)은 **모른다**로 남긴다 —
   "body 단독" 으로 넓히면 못 쟀다가 측정처럼 보인다.
"""
_delta_scope(resolve) = resolve === :not_needed_surface ? "body_only" :
                        resolve === :resolved           ? "body+harness_resolve" : "unknown"

"""
    BODY_ONLY_PROBED

`world_delta_body` 의 범위 이름. **상수다 — 리터럴로 베끼지 말 것.**

🔴 왜 `_delta_scope` 의 값이 아닌가 (2026-09-04, Task 2). `_delta_scope` 는 `r.resolve` 에서
   **유도**하는 판독이고, 그 판독의 `body_only` 는 "하네스가 재풀이할 이유가 없었다" 는
   뜻이다 — 재풀이가 **돈 판**에서는 영영 안 나온다. `world_delta_body` 는 그것과 다른
   근거로 body 단독이다: 재풀이가 돌았든 말든 **재풀이 앞에서 직접 찍은 지문**이다.
   두 사실에 같은 이름을 붙이면 로그를 읽는 사람이 그 둘을 못 가른다.
"""
const BODY_ONLY_PROBED = "body_only(probed)"

"""
    _steps_row(m) -> Union{Nothing,Vector{Dict{String,Any}}}

집행 결과 `m` 의 `steps` 를 결정 행에 실을 모양으로. 키 셋(`"name"`·`"status"`·`"detail"`,
전부 `String`)은 여기가 진실원이다. `detail` 의 접기·상한은 `_step_detail_render` 가
소유한다(기록 줄과 **같은 함수** — 두 자리가 갈리지 않는다).

🔴 **안 던진다.** `m` 에 `steps` 가 없을 수도(구세대 집행부), 스텝 모양이 다를 수도 있다 —
그 판은 `nothing`("못 쟀다")이다. 읽었는데 비었으면 `[]`("쟀는데 없다")이고, 그 둘은
**다른 관측**이다.
"""
function _steps_row(m)
    try
        return Dict{String,Any}[
            Dict{String,Any}("name"   => string(s.name),
                             "status" => string(s.status),
                             "detail" => _step_detail_render(
                                 hasproperty(s, :detail) ? s.detail : nothing))
            for s in m.steps]
    catch
        return nothing
    end
end

"""
    _wd_row(wd) -> Dict{String,Any}

`world_delta`/`world_delta_body` 를 **결정 행의 dict 으로**. 두 자리가 같은 모양이어야 하므로
직렬화 모양의 진실원을 여기 하나로 둔다(2026-09-05, B1 — 그 전에는 같은 리터럴이 두 벌이었고,
여섯째 축을 더할 때 그 둘이 갈릴 자리였다. 이 파일의 `_world_delta_str` 이 m3/m4 에서 이미
밟은 실패 모드다).

🔴 **여섯 키다.** `n_staging_moved` 은 **`null` 일 수 있다** — 그 축만 삼상이기 때문이고
(`_world_digest` 의 docstring 이 근거를 소유한다), `null`("이 판에서 기하를 못 읽었다")과
`0`("읽었는데 안 움직였다")은 다른 사건이다. 채점기(`tools/monitor/ladder_report.py`)가 그
구별을 읽는다: 나머지가 전부 0 인데 이 축이 `null` 이면 **MEASURED_ZERO 가 아니라
UNMEASURED** 다("안 바뀌었다" 를 주장할 수 없다).

⚠️ `hasproperty` 로 읽는다 — 여섯째 축 이전 세대의 다섯-필드 튜플이 오면 맨 접근이 던지고,
   `record_world_delta!` 의 `catch` 가 그것을 삼켜 **행에서 `world_delta` 가 통째로
   사라진다**(계측이 기록을 죽인다). 그 판의 정직한 값은 이 축만 `nothing` 이다.
"""
_wd_row(wd) = Dict{String,Any}(
    "closed" => wd.closed, "active" => wd.active, "n_edges" => wd.n_edges,
    "n_binding_changed" => wd.n_binding_changed,
    "n_weights_changed" => wd.n_weights_changed,
    "n_staging_moved" => hasproperty(wd, :n_staging_moved) ? wd.n_staging_moved : nothing)

"""
    record_world_delta!(m) -> Nothing

집행 결과 `m` 의 `world_delta` 를 **살아 있는 결정 행**에 제자리로 싣는다. F1(2026-09-03 리뷰).

🔴 왜 필요한가. `record_decision!`(`tools/monitor/render_demo.jl`)은 결정 행을 집행 **앞**에서
   닫고, 집행 뒤에는 `_m.handled` 하나만 읽혔다 — `world_delta` 는 stdout 으로만 나갔다.
   (stdout 채점은 실제로 가능하다: `println` 이라 `global_logger(…, Logging.Warn)` 를 통과하는
   것을 검증자가 짝지은 대조로 확인했다. 즉 독자 0개의 write-only 도장은 **아니었다**.
   그래도 스윕 규모의 집계는 구조화된 행이 있어야 한다.)

🔴 **패턴은 하나다.** `monitor_record_verification!`(`src/monitor/monitor.jl`)이 이미 쓰는
   제자리 변이 그대로다 — `MONITOR_RESPEC[]` 은 `monitor_emit!` 때 직렬화되는 살아 있는
   Dict 다. 두 번째 기록 경로를 만들지 않는다.

🔴 **삼상이 행에서도 산다.** 행이 있으면 키는 **언제나** 쓰인다: `nothing`(못 쟀다)은
   `null` 로 직렬화되고 `0` 도 `{}` 도 되지 않으며, "쟀는데 0" 은 여섯 키를 가진 dict 이다
   (2026-09-04 Task 2 가 `n_weights_changed` 를 더해 넷 → 다섯이, 2026-09-05 B1 이
   `n_staging_moved` 를 더해 다섯 → 여섯이 됐다). 🔴 그 여섯째 **값**은 `null` 일 수 있다 —
   축 자신이 삼상이라서다(`_wd_row` 의 docstring). 그것은 "이 코드 이전 세대" 가 **아니다**.
   키의 **부재**는 셋째 사건("이 코드 이전 세대의 산출물")을 뜻한다.

🔴 **네 칸을 싣는다** — `world_delta` · `interface_calls`(L3) · `steps`(2026-09-04 Task 1) ·
   `world_delta_body`(Task 2). 이름은 `record_world_delta!` 그대로다: 호출자가
   `tools/monitor/render_demo.jl` 한 곳뿐이고 이름 변경은 그 파일까지 건드리므로 이
   태스크의 범위 밖이다.

🔴 **절대 안 던진다.** 이 호출은 `enact_minted_decision!` 의 `try` **밖**이다(호출부는
   `policy_producer` 안이고, 거기서 새는 예외는 `engage_fallback!` = 라인 정지로 간다).
   `m` 에 필드가 없을 수도(구세대 집행부), 행이 dict 이 아닐 수도 있다.
"""
function record_world_delta!(m)
    try
        local rs = CB.MONITOR_RESPEC[]
        rs isa AbstractDict || return nothing
        local wd = m.world_delta
        rs["world_delta"] = wd === nothing ? nothing : _wd_row(wd)
        # 🔴 **D5 (Wave D). 같은 호출이 L3 도 싣는다.** 사다리(spec §0)의 두 칸이
        #    같은 결정 행에서 같은 방식으로 읽혀야 유료 런이 둘을 짝지어 채점할 수 있다.
        #    호출 자리를 하나 더 만들지 않는 이유: 이 함수의 유일한 호출자는
        #    `tools/monitor/render_demo.jl` 인데 그 파일은 이 파동의 경로 밖이다 —
        #    두 번째 기록 경로를 만들면 그 둘이 갈릴 자리가 생긴다(이 함수 docstring 의
        #    "패턴은 하나다" 와 같은 논거).
        #    ⚠️ 그래서 **이름이 `record_world_delta!` 인 채로 세 칸을 싣는다**(2026-09-04
        #    Task 1 이 `steps` 를 더해 둘 → 셋이 됐다). 이름이 좁은 것은 사실이고, 여기
        #    적어 둔다. **이름을 안 바꾸는 이유**: 호출자가 `tools/monitor/render_demo.jl`
        #    한 곳뿐이고 그 파일은 이 태스크의 경로 밖이다 — 이름 변경은 범위 밖이다.
        # 🔴 삼상이 행에서도 산다: `nothing` 은 `null` 로 직렬화되고 `[]` 가 되지 않는다.
        #    키의 **부재**만이 셋째 사건("이 코드 이전 세대의 산출물")을 뜻한다.
        rs["interface_calls"] = m.interface_calls
        # ---- 셋째 칸: `steps` (2026-09-04, Task 1) --------------------------------------
        # 🔴 왜 행에도 싣는가. `:threw` 판의 예외 메시지는 오늘 **stdout 한 줄로만** 나간다.
        #    스윕 규모로 "무엇이 죽였나" 를 세려면 구조화된 행이 있어야 한다(이 함수
        #    docstring 의 "패턴은 하나다" 와 같은 논거 — 두 번째 기록 경로를 안 만든다).
        # 🔴 삼상: `m.steps` 를 못 읽으면 `nothing`("못 쟀다"), 읽었는데 비었으면 `[]`
        #    ("쟀는데 없다"). 그 둘을 뭉개면 body 가 한 걸음도 안 돈 판과 필드가 아예 없는
        #    구세대 산출물이 같은 값이 된다.
        rs["steps"] = _steps_row(m)
        # ---- 넷째 칸: `world_delta_body` (2026-09-04, Task 2) ---------------------------
        # 🔴 같은 모양·같은 삼상이다. `nothing` 은 "probe 를 못 찍었다"(= 집행이 그 자리에
        #    도달 못 했거나 지문이 안 나왔다)이고, 0 의 dict 은 "찍었는데 body 가 세계를 안
        #    바꿨다" 다. 그 둘을 뭉개면 이 칸이 재려는 귀속이 통째로 사라진다.
        local wdb = try m.world_delta_body catch; nothing end
        rs["world_delta_body"] = wdb === nothing ? nothing : _wd_row(wdb)
        # ---- 다섯째 칸: `enact_retry` (2026-09-05, D17b) --------------------------------
        # 🔴 왜 행에도 싣는가. 위 `steps` 와 **같은 논거**다(이 함수 docstring 의 "패턴은
        #    하나다"): 이 값은 오늘 `[minted]` 줄 하나로만 나가는데, 스윕 규모로 "되먹임이
        #    몇 번 갔고 · 몇 번 세계가 더러워 거절됐고 · 몇 번 왕복이 실패했나" 를 세려면
        #    구조화된 행이 있어야 한다. 두 번째 기록 경로는 안 만든다.
        # 🔴 삼상+이 행에서도 산다. 키의 **부재** = 이 코드 이전 세대의 산출물 ·
        #    `null` = 시도 안 했다 · 문자열 = `_retry_str` 의 나머지 다섯 상태.
        #    그래서 `hasproperty` 로 가른다 — `catch; nothing` 으로 접으면 구세대와
        #    "시도 안 했다" 가 같은 값이 된다.
        if (try hasproperty(m, :enact_retry) catch; false end)
            rs["enact_retry"] = m.enact_retry === nothing ? nothing : String(m.enact_retry)
        end
    catch e
        # 🔴 `@info` 가 아니라 `println` 이다(이 파일의 다른 `[minted]` 줄과 같은 이유).
        println("[minted] world_delta 행 기록 실패 (렌더는 계속한다): ",
                first(split(sprint(showerror, e), "\n")))
    end
    return nothing
end

"""
    _sl_is_rewritable(sl) -> Bool

`sl` 에 **String 키를 새로 써 넣어도 안전한가**. 되먹임이 성공했을 때 이 dict 을 갱신해야
하는데(아래 `_rewrite_once` 호출부의 근거), 그 대입이 던지는 모양이 실재한다.

🔴 브리프는 `sl isa AbstractDict && !(sl isa JSON3.Object)` 를 요구했다. 실측하면 그 술어는
**필요조건이지 충분조건이 아니다**(2026-09-04, `julia +lts` 직접 확인):
  · `JSON3.Object <: AbstractDict` 이고 그 `keytype` 은 `Symbol` 이다 — 그래서 브리프의
    두 번째 절이 필요했다.
  · 그런데 `keytype` 이 `Symbol` 인 **보통** `Dict{Symbol,Any}` 도 같은 이유로 던지는데
    (`convert(Symbol, "impl_name")` 이 없다) 브리프의 술어는 그것을 통과시킨다.
    `_synth_lane_field` 의 docstring 이 적듯 이 dict 은 **Symbol 키로도 도착한다**.
그러므로 판정은 타입 이름이 아니라 **키·값 타입**으로 한다 — 이쪽이 브리프의 술어를
포함하면서(`JSON3.Object` 는 `keytype === Symbol` 이라 여기서 이미 걸린다) 실제로 위험한
모양을 하나 더 막는다. 생산 모양은 `policy.jl::_synth_view` 의 `Dict{String,Any}` 다.

🔴 **던지지 않는다.** `keytype` 은 dict 이 아닌 것에 대해 던질 수 있고, 이 술어가 던지면
집행부가 기록 대신 예외로 끝난다 — 이 파일 전체가 지키는 규약이다.
"""
_sl_is_rewritable(sl) =
    try sl isa AbstractDict && keytype(sl) === String && valtype(sl) === Any
    catch; false end

"""
    _UNDERLYING_MARK

`HTTP.RequestError` 의 `showerror` 가 **진짜 원인 앞에** 찍는 리터럴 표식. 진실원은 여기
하나다(`HTTP/src/Exceptions.jl` 의 `Base.showerror(io, e::RequestError)`).
"""
const _UNDERLYING_MARK = "Underlying error:"

"""
    _showerror_cause(e) -> String

예외 하나의 `showerror` 전문에서 **원인만** 남긴 문자열. `_UNDERLYING_MARK` 가 있으면
`첫 줄 * " " * 표식 뒤 전부`, 없으면 전문 그대로.

🔴 왜 (2026-09-05, P2 Task 1의 남은 구멍). `HTTP.RequestError` 의 `showerror` 는
   **요청 덤프를 먼저** 찍고 원인을 **맨 뒤**에 찍는다:

       HTTP.RequestError:\\nHTTP.Request:\\n<헤더·바디 덤프>\\nUnderlying error:\\n<원인>

   1821바이트짜리 `impl_code` 를 실은 유료 런 9 에서 이 덤프가 1200자를 넘었고,
   `_cap_detail` 의 200자 상한이 원인보다 **1000자 앞에서** 잘렸다. 로그에 남은 것은
   요청 헤더뿐이고 사유는 통째로 죽었다(실측 재현: 원인이 1301자 중 1261번째 자리).
   `bca635f1` 이 옛 `first(split(…, "\\n"))` 을 고쳐 원인이 **문자열 안에는** 살아남게
   했지만, 상한 침식은 그 커밋이 명시적으로 범위 밖으로 남긴 구멍이다.

🔴 **왜 상한(`_STEP_DETAIL_CAP`)을 안 건드리는가.** 그 상수는 `steps[i].detail` 과
   **공유**되고, 그 값은 기록 줄(`[minted] lane=…`)에 실려 `ladder_report.py` 가 읽는
   구조의 일부다. 상한을 키우면 이 파일이 찍는 **모든** 기록 줄의 폭이 바뀐다 — 고쳐야
   할 것이 상한이 아니라 **내용**인데(1000자는 우리가 이미 아는 우리 요청의 사본이다)
   공유 상수를 흔드는 것은 대가가 크고 표적이 아니다. 그래서 **표적 경로**를 더한다:
   덤프를 버리고 원인을 상한 안으로 끌어온다. `_cap_detail` 은 그대로 지난다 — 원인
   자체가 길 수도 있으므로 상한은 여전히 필요하다.

🔴 **첫 줄을 남기는 이유.** 원인만 찍으면 로그에서 `HTTP.RequestError` 라는 사실 자체가
   사라진다(그것이 연결 **이후** 단계의 실패라는 판정 근거다 — `ConnectError` 와 다르다).
   `HTTP.RequestError: EOFError: read end of file` 처럼 둘 다 남는다.

⚠️ ASCII 만 쓴다. 표식은 리터럴 ASCII 이고, 이어붙이는 것은 공백 하나뿐이다 — 치환이
   없으므로 `_cap_detail` 의 상한 자리가 바이트 단위로 계산 가능한 성질이 유지된다
   (`_neutralize_brackets` 문단이 지키는 것과 같은 성질).
⚠️ `findlast` 다. 표식이 여럿이면 **가장 깊은** 원인을 고른다. 원인 메시지 자체가 이
   표식을 담으면 그 뒤만 남지만, 그 판은 여전히 사유의 끝부분이라 오늘(사유 0자)보다
   엄격히 낫다.
🔴 **표식이 없으면 전문을 그대로 돌려준다** — `ConnectError`·`ArgumentError` 처럼 원인이
   1번째 줄에 있는 가족은 오늘과 **바이트 동일하게** 찍힌다. 그 가족을 재는 게이트가
   안 움직인다.
"""
function _showerror_cause(e)::String
    s = sprint(showerror, e)
    i = findlast(_UNDERLYING_MARK, s)
    i === nothing && return s
    return string(first(split(s, '\n')), " ", lstrip(SubString(s, nextind(s, last(i)))))
end

"""
    _rewrite_once(sl, nm, cd, why) -> Union{Nothing,NamedTuple}

거절 사유를 agent-3 에게 **한 번** 되먹여 고친 body 를 받는다. 못 받으면 `nothing`.

🔴 **절대 안 던진다.** 여기서 새면 집행부가 기록 대신 예외로 끝나고 호출자는 세계 상태를
   잃는다 — 이 파일 전체가 지키는 규약이다. 서비스가 안 떠 있는 것도 정상 경로다.
🔴 세계를 안 건드린다. 이 시점에 등록은 실패했고 `Core.eval` 은 안 돌았다.

⚠️ `DSPY_URL`·`HTTP`·`JSON3` 의 진실원은 `tools/monitor/policy.jl` 이다(여기서 두 번째
   벌을 만들지 않는다). 그 파일을 include 하지 않은 채 이 파일만 태우는 자리가 실재하고
   (`tools/monitor/test_minted_wiring.jl`), 거기서는 이 이름들이 `UndefVarError` 를 낸다 —
   그것도 `catch` 로 떨어져 **원래 거절이 그대로 남는다**. 되먹임은 있으면 좋은 것이지
   반드시 도는 것이 아니므로 그 자리에 로드 순서를 강제하지 않는다.
"""
function _rewrite_once(sl, nm::AbstractString, cd::AbstractString, why::AbstractString)
    # 🔴 왕복 **전에** 판정한다. 고친 body 를 받아 놓고 `sl` 을 못 갱신하면, 새 body 를
    #    등록해 놓고 **낡은 인자**로 부르게 된다(아래 호출부의 근거) — 그 판이 제일 나쁘다.
    if !_sl_is_rewritable(sl)
        println("[minted] rewrite: 건너뜀 — synth_lane 이 갱신 가능한 모양이 아니다 ",
                "(", typeof(sl), "). 원래 거절이 그대로 남는다.")
        return nothing
    end
    try
        # ✅ 2026-09-04 (Wave A, W5) — **배선됐다.** Task 9 가 실측했던 "`spec` 은 언제나
        #    빈 문자열이다" 는 이제 거짓이다: 원인이던 `SYNTH_LANE_KEYS` 의 `mechanism`
        #    누락이 메워졌고(`policy.jl` 의 그 튜플 docstring 이 근거를 소유한다), 파이썬
        #    쪽에는 그 키가 처음부터 있었다(`synthesize.py` 의 `_SPEC_FIELDS`).
        # 🔴 그래도 빈 값은 여전히 **날 수 있다** — 그리고 이제 그것은 배선이 아니라 사건에
        #    대한 사실이다: 합성이 design 단계 전에 빠져나온 판(이른 탈출 일곱)에서는
        #    `mechanism` 이 `nothing` 이고, agent-2 가 산문을 안 낸 판에서는 `""` 다.
        #    조용히 보내지 않는다 — 부재를 로그로 시끄럽게 만든다(이 레포가 반복해 밟은
        #    "빈 값이 정상처럼 보이는" 실패 모드). 🔴 이 줄이 유료 런에서 **한 번이라도**
        #    뜨면 그 판의 되먹임 실패는 모델의 수치로 세면 안 된다.
        local spec = something(_synth_lane_field(sl, "mechanism"), "")
        isempty(spec) && println("[minted] rewrite: ⚠️ spec 이 비었다 — agent-3 이 명세 ",
                                 "없이 고쳐야 한다 (배선은 됐다: 이 판의 synth_lane 에 ",
                                 "mechanism 이 없거나 빈 문자열이다)")
        body = JSON3.write(Dict(
            "tool_name" => something(_synth_lane_field(sl, "tool_name"), ""),
            "spec"      => spec,
            "impl_name" => nm, "impl_code" => cd, "impl_rejected_why" => why))
        # 🔴 2026-09-05 (P2 의 진짜 원인). 초판은 `retries = 0` 이었고, **그 한 글자가
        #    이 채널이 한 번도 성공하지 못한 이유다.** 근거 셋:
        #    (1) 던진 것은 `HTTP.RequestError` 다. HTTP.jl 은 그 예외를 `newconnection` 이
        #        **성공한 뒤**에만 낸다(`ConnectionRequest.jl`: 연결 실패는 `ConnectError`).
        #        즉 주소·DNS·`DSPY_URL` 모양은 용의자가 아니다 — 소켓은 잡혔고 그 위의
        #        쓰기/읽기가 깨졌다. 그리고 서비스 로그에 줄이 없다 = 서버가 요청줄을
        #        한 번도 파싱하지 않았다 = **그 소켓은 이미 죽어 있었다**(keep-alive 만료).
        #    (2) `policy.jl` 의 `/decide` 는 **같은 프로세스에서 성공한다**. 그쪽이 다른
        #        점은 하나뿐이고, 그 파일의 주석이 이유를 이미 적어 뒀다:
        #        "이벤트 간격이 길어 keep-alive 연결이 죽어 있으면 첫 시도가
        #         'stream is closed or unusable' 로 실패한다(실제로 두 번째 OOD 에서
        #         그렇게 폴백됐다)". 이 레포는 이 대가를 이미 한 번 치렀다.
        #    (3) 실측(루프백 스텁, 유료 0건 — testset (32)): 클라이언트가 **쓴 뒤** 피어가
        #        연결을 끊는 판에서
        #          `retries = 0`                      → RequestError (서버 처리 0건)
        #          `retries = 2`                      → RequestError (서버 처리 0건)
        #          `retries = 2, rni = true`          → 200 (서버 처리 1건)
        #        가운데 줄이 중요하다: 바이트가 나간 뒤라 `nothing_written` 이 거짓이고
        #        POST 는 멱등이 아니라, **`retry_non_idempotent` 없이는 재시도가 안 걸린다**
        #        (`HTTP/src/Messages.jl` 의 `retryable(::Request)`).
        # ⚠️ 대가는 명시한다: `retry_non_idempotent = true` 는 바이트가 서버에 닿은 요청도
        #    다시 보낼 수 있어 **유료 호출이 한 번 더** 나갈 수 있다. 그래서 `/decide` 의
        #    3 이 아니라 2 다 — 죽은 keep-alive 는 반복되는 조건이 아니라 한 번 뚫으면
        #    끝난다(위 실측에서 재시도 1회로 200 이 났다). 그리고 500 은 재시도되지 않는다:
        #    `retryable(status)` 가 참이어도 `retryable(::Request)` 가 이 판을 막는다.
        resp = HTTP.post(DSPY_URL * "/rewrite",
                         ["Content-Type" => "application/json"], body;
                         readtimeout = 120, retries = 2, retry_non_idempotent = true)
        f = JSON3.read(String(resp.body))
        (get(f, :wrote, nothing) === true) || return nothing
        (get(f, :impl_code, nothing) isa AbstractString) || return nothing
        (get(f, :impl_name, nothing) isa AbstractString) || return nothing
        return (impl_name = String(f.impl_name), impl_code = String(f.impl_code),
                params = get(f, :params, nothing), calls = get(f, :calls, nothing),
                surface = get(f, :surface, nothing), reversible = get(f, :reversible, nothing))
    catch e
        # 🔴 2026-09-04 Task 1 (P2). 옛 `first(split(sprint(showerror, e), "\n"))` 는
        #    `HTTP.RequestError` 에서 정확히 `"HTTP.RequestError:"` 한 줄만 남긴다 — 진짜
        #    원인은 `showerror` 출력의 **마지막** 줄("Underlying error:" 다음)에 있다
        #    (`HTTP/src/Exceptions.jl` 의 `Base.showerror(io, e::RequestError)` 가
        #    `"HTTP.RequestError:\n"` 로 시작해 `e.error` 를 맨 끝에 찍는다). 라이브 유료
        #    런에서 실제로 이 한 줄만 남아 사유가 통째로 죽었다. 이 파일이 `steps[i].detail`
        #    에 이미 쓰는 경로(`_cap_detail`/`_one_line_rec`, 위 `_step_detail_render`)와
        #    같은 것을 써서 전문을 한 줄로 접어 상한 안에서 찍는다 — 잘라도 마지막 줄이
        #    통째로 사라지는 옛 결함은 재현되지 않는다(자르는 지점이 문자 수 상한이지 개행
        #    이 아니다).
        # 🔴 `_neutralize_brackets` 는 **안 쓴다.** 이 줄의 접두는 `"[minted] rewrite: "`
        #    이고 `ladder_report.py` 의 `MINTED_RE`(`r'\[minted\] lane=present[^\n\r]*'`)는
        #    리터럴 `"[minted] lane=present"` 로 시작하는 줄만 골라 그 줄 안의 `steps=[...]`
        #    를 괄호 깊이로 판독한다 — 이 줄은 그 접두가 아니므로 그 정규식에 애초에
        #    안 걸린다(실측). 기록 줄이 아니라 진단용 println 이라 중화 대상이 아니다.
        # 🔴 `"Stacktrace:"` 이후를 미리 버리지 **않는다.** 이 호출은 `sprint(showerror, e)`
        #    (2-인자)라 Base 가 자동으로 붙이는 백트레이스 절이 없다 — 리터럴
        #    `"Stacktrace:"` 문구는 `e.error` 자체가 `CapturedException` 일 때만 그 값의
        #    `showerror` 가 스스로 적는다. `HTTP.ConnectionRequest` 는 그 필드를
        #    `ExceptionUnwrapping.unwrap_exception_to_root` 로 이미 벗겨서 넣으므로 실전에서
        #    거의 안 나온다. 실측(둘 다 CapturedException 을 인위로 주입):
        #    `ConnectError` 는 원인이 **1줄째**(스택 앞)라 200자 상한에 항상 든다(측정
        #    LEN=284, 원인 위치 ~55). `RequestError` 는 원인이 **요청 덤프 뒤**라 상한을
        #    갉아먹는 것은 스택이 아니라 **헤더·바디 덤프**다(측정: 53바이트짜리 JSON
        #    바디 하나만으로도 원인이 200자 밖으로 밀려났다 — 스택트레이스는 아직 시작도
        #    안 한 자리다). 즉 `"Stacktrace:"` 를 잘라내도 이 상한-침식의 실제 원인(요청
        #    덤프)은 그대로 남는다 — 죽은 코드를 더할 근거가 없다.
        # ✅ 2026-09-05: 그 상한 침식이 **여기서 막혔다.** `_showerror_cause` 가 요청 덤프를
        #    버리고 `"Underlying error:"` 뒤만 남긴다(그 docstring 이 근거의 진실원이다).
        #    유료 런 9 의 실측 재현: 원인이 전문 1301자 중 **1261번째** 자리에 있어 200자
        #    상한이 1000자 앞에서 잘렸다. 표식이 없는 예외(`ConnectError` 등)는 전문을
        #    그대로 지나가므로 그 가족의 줄은 오늘과 바이트 동일하다.
        println("[minted] rewrite: 왕복 실패 (원래 거절이 그대로 남는다): ",
                _cap_detail(_one_line_rec(_showerror_cause(e))))
        return nothing
    end
end

"""
    _install_rewrite!(sl, fx; allow_redefine = false) -> Union{Nothing,String}

`_rewrite_once` 가 돌려준 고친 body 를 **검사·설치·등록**한다. 성공이면 `nothing`,
아니면 거절 사유 문자열.

🔴 **한 벌이다.** 되먹임 자리가 둘이 됐다(D17 = 등록 거절, D17b = 집행 예외). 이 열두 줄을
   두 번 적으면 두 자리가 갈리고, 이 레포는 그 갈림을 이미 여러 번 겪었다(`_world_delta_str`
   의 m3/m4 문단이 같은 사고를 적는다). 그러므로 **검사 순서·사유 이름·대입 순서가 여기
   한 곳에서만 정의된다.**

🔴 검사가 **대입보다 먼저다**(D4, Task 9 리뷰 I3·I4). 못 쓸 값을 `sl` 에 남기면 이 판을
   나중에 읽는 소비자에게 거짓말을 한다. 그리고 같은 결함이 시도 1 과 시도 2 에서 **같은
   사유 이름**을 가져야 한다 — 되먹임이 재는 것이 "무엇을 고쳤나" 의 사유 히스토그램이므로.

🔴 `sl["body_names"]` 는 **반드시** 갱신한다(D1, Task 9 리뷰 C1). `enact_minted!` 이 실행할
   원시를 고르는 자리는 다섯 키가 아니라 `body_names` 다 — 안 맞추면 고친 body 가 등록되고
   `Core.eval` 까지 된 뒤 **영영 안 불리고**, 기록에는 "모델이 어휘 밖 이름을 냈다" 로 남는다.

🔴 `params` 는 **갱신된 `sl` 에서 다시 읽는다**(`fx.params` 를 직접 안 쓴다). 등록에 먹이는
   값과 집행부가 읽는 값이 같은 자리에서 나와야 둘이 갈릴 수 없다.

⚠️ `allow_redefine` 은 **집행-예외 되먹임 전용**이다. 근거와 좁힘의 술어는 호출자가 소유한다
   (`minted_registration.jl` 의 D17b 갈래 주석이 그 대가를 적는다).
"""
function _install_rewrite!(sl, fx; allow_redefine::Bool = false)
    local surf2 = fx.surface
    (surf2 === nothing || surf2 isa AbstractString) ||
        return "reject:surface_not_a_string:$(typeof(surf2))"
    local praw2 = fx.params
    (praw2 === nothing || praw2 isa AbstractDict) ||
        return "reject:params_not_an_object:$(typeof(praw2))"
    sl["impl_name"]  = fx.impl_name
    sl["body_names"] = [fx.impl_name]
    sl["impl_code"]  = fx.impl_code
    fx.params  !== nothing && (sl["params"]  = fx.params)
    fx.calls   !== nothing && (sl["calls"]   = fx.calls)
    fx.surface !== nothing && (sl["surface"] = fx.surface)
    return CB.register_minted_primitive!(
        name = fx.impl_name, code = fx.impl_code,
        params = something(_synth_lane_field(sl, "params"), Dict{String,Any}()),
        # 🔴 위에서 이미 타입을 확정한 `surf2` 를 쓴다 — `fx.surface` 를 다시 읽으면
        #    검사한 값과 먹이는 값이 두 자리에서 나온다(진실원 하나).
        surface = String(something(surf2, "unknown")),
        reversible = fx.reversible === true,
        allow_redefine = allow_redefine)
end

"""
    _enact_throw_reason(r) -> Union{Nothing,String}

`CB.enact_minted!` 의 반환이 **집행 중 예외**로 끝난 판이면 그 사유 한 줄, 아니면 `nothing`.

🔴 이것이 D17b 가 여는 문이다. D17 은 **등록 거절**에서만 발화하는데, 유료 런 2·4·5·7 은
   등록을 통과한 body 가 **집행에서 던져** 죽었다 — 그 판에는 되먹임이 한 번도 안 갔다.
   예외 메시지(`KeyError: key "goal1" not found`)는 무엇이 틀렸는지를 **정확히** 이름으로
   말하고, 모델이 달리 얻을 길이 없는 정보이며, 지어낸 값이 **어떤 모양이었든**(dict 키 ·
   위치 인자 · 좌표 튜플 · body 안의 리터럴 벡터) 같은 자리에서 나온다.

🔴 판정은 `r.partial` **하나로 안 한다.** `partial=true` 는 던진 판의 필요조건이지만
   `verdict` 만으로는 어떤 단계가 던졌는지가 안 나온다 — 마지막 단계의 `status === :threw`
   가 그 판의 유일한 정본이다(`minted_tool.jl` 의 집행 루프는 던진 자리에서 **곧바로**
   돌아오므로 `:threw` 는 언제나 마지막이고 많아야 하나다).

🔴 안 던진다. 이 함수가 던지면 집행부가 기록 대신 예외로 끝난다 — 이 파일의 규약이다.

⚠️ 접두 `enact_threw:` 는 **전선에 실린다**. `/rewrite` 의 `impl_rejected_why` 는 자유
   문자열이므로 파이썬을 안 고친다(그래서 서비스 재기동이 필요 없다) — 대신 agent-3 이
   "등록 거절" 과 "집행 예외" 를 접두로 가를 수 있어야 한다.
"""
_enact_throw_reason(r) =
    try
        (r.partial === true && !isempty(r.steps) && r.steps[end].status === :threw) ?
            string("enact_threw:", r.steps[end].name, ": ",
                   _cap_detail(_one_line_rec(string(r.steps[end].detail)))) : nothing
    catch; nothing end

"""
    _wd_is_zero(wd) -> Bool

`_world_delta` 의 여섯 축이 **전부 잰 0** 인가. `nothing`(못 쟀다)은 `false` 다.

🔴 이 술어는 **한 방향으로만 쓴다.** `_world_digest` 의 docstring 이 소유하는 사실:
   `n_binding_changed > 0` 은 바뀐 것을 **증명**하지만 `== 0` 은 안 바뀐 것을 증명하지
   **못한다**(하한이다). 그러므로 아래 `_retry_gate` 는 이것을 "세계가 깨끗하다는 증거"로
   쓰지 않고 **"더러움의 반증이 없다"** 로만 쓴다 — 비-0 이면 확실히 거절, 0 이면 남은 세
   조건과 함께여야 통과.
🔴 `n_staging_moved` 은 축 자신이 삼상이라(`_world_delta` 의 B1 문단) `nothing` 이면
   **못 쟀다**이고, 여기서는 0 으로 안 친다.
"""
_wd_is_zero(wd) =
    try
        wd !== nothing && wd.closed == 0 && wd.active == 0 && wd.n_edges == 0 &&
        wd.n_binding_changed == 0 && wd.n_weights_changed == 0 &&
        wd.n_staging_moved isa Integer && wd.n_staging_moved == 0
    catch; false end

"""
    _retry_gate(r, world_delta_body) -> Symbol

집행이 던진 판에서 **되먹임을 시도해도 되는가**. `:ok` 아니면 거절 사유 심볼.

🔴 **판정(2026-09-05, D17b).** body 가 던지면 `partial=true`·`undo=:none` 이고 되돌릴
   방법이 없다 — 반쯤 편집된 세계 위에 두 번째 body 를 굴리는 것은 **안 굴리는 것보다 나쁠
   수 있다**(두 번째 body 는 첫 번째가 무엇을 했는지 모른 채 같은 편집을 다시 하거나, 이미
   사라진 것을 지운다). 그러므로 게이트는 **좁게** 연다. 세 연언지 전부여야 `:ok` 다:

   1. `length(r.steps) == 1` — 던진 단계가 **첫 단계**다. 두 번째 이후에서 던졌다면 앞선
      원시들이 status 를 내고 **끝까지 돌았다**는 것을 우리가 안다(`applied`/`touched` 가
      그 status 에서 병합됐다) — 즉 세계는 확실히 편집됐다. `:refused_not_first_step`.
   2. `world_delta_body !== nothing` — probe 를 **실제로 찍었다**. `nothing` 은 "못 쟀다"
      이고, 못 잰 것을 깨끗하다고 읽는 것이 이 레포가 반복해 밟은 실패 모드다.
      `:refused_world_unmeasured`.
   3. `_wd_is_zero(world_delta_body)` — 그 probe 가 **아무 변화도 못 봤다**. 비-0 은 편집을
      **증명**하므로 확실한 거절이다. `:refused_world_changed`.

🔴 **이 게이트는 "세계가 깨끗하다" 를 주장하지 않는다.** 남는 구멍은 정확히 하나이고 여기
   적어 둔다: **첫(=던진) 단계가 지문의 여섯 축에 안 보이는 편집을 하고 던진 판.** 지문은
   `closed`·`active`·`n_edges`·`assignment_binding`·`root_node_weights`·`staging_circles`
   만 본다. 그 구멍은 이 게이트로 못 닫으며, 닫으려면 undo 나 스냅샷이 있어야 한다(이
   태스크의 범위 밖이다). 이 게이트가 주장하는 것은 **"더러움의 반증이 하나도 없는 가장 좁은
   창"** 뿐이다.

🔴 `world_delta`(집행 봉투 전체)가 아니라 `world_delta_body` 를 본다. 봉투에는
   `_issue_resume!`/`_resolve_if_needed!` 가 던진 판에서도 **반드시** 돌린 편집이 섞여
   있으므로(`minted_tool.jl` 의 catch 절), 그것으로 판정하면 게이트가 **영영 안 열린다** —
   그리고 그 편집은 body 가 한 것이 아니다.
"""
_retry_gate(r, wdb) =
    (try length(r.steps) catch; -1 end) != 1 ? :refused_not_first_step :
    wdb === nothing                          ? :refused_world_unmeasured :
    # 🔴 축 하나만 못 잰 판도 **못 잰 판**이다. `n_staging_moved` 은 축 자신이 삼상이라
    #    (`_world_delta` 의 B1 문단) 나머지 다섯이 0 인 채 이것만 `nothing` 일 수 있는데,
    #    그것을 `:refused_world_changed` 로 적으면 **거짓 진술**이다 — 세계가 바뀌었다는
    #    관측은 없었고, 우리가 기하 축을 못 읽었을 뿐이다. 사유가 갈려야 유료 런의
    #    "왜 되먹임이 안 갔나" 히스토그램이 참이 된다.
    !(try wdb.n_staging_moved isa Integer catch; false end) ? :refused_world_unmeasured :
    !_wd_is_zero(wdb)                        ? :refused_world_changed :
    :ok

"""
    _noop_gate(r, world_delta_body) -> Symbol

집행이 **안 던진** 판에서 그 body 가 **잰 무동작**인가. `:ok` · `:noop_refused_unmeasured` ·
`:none`(트리거 자체가 없다) 셋 중 하나.

🔴 **왜 이 게이트가 따로 있나 (2026-09-05, D17c).** D17b 는 body 가 **던진** 판만 되먹였다.
   유료 런 8 은 정확히 그 채널이 못 보는 자리에서 죽었다: body 가 zone 키를 좌표에서 **지어
   만들어** 놓고 원시의 반환 status 를 **올바르게** 검사한 뒤 `:failure` 를 돌려줬다 —
   예외가 없으므로 `_enact_throw_reason` 은 `nothing` 이고 되먹임이 한 번도 안 갔다.
   그 판의 기록은 `verdict=admit partial=false enact_retry=n/a` 에 여섯 축 전부 0 이었다.
   그러므로 필요한 것은 **예외에 대한 되먹임이 아니라 잰 0 에 대한 되먹임**이다.

**연언지 넷. 전부여야 `:ok` 다.**

  1. `!isempty(r.steps)` — body 가 **실제로 한 발이라도 굴렀다**. 걸음이 없으면(거절·조기
     반환) "아무것도 안 움직였다" 는 body 에 대한 사실이 아니라 **body 를 안 불렀다**는
     사실이다. 그 판은 `:none`(= 로그의 `n/a`)이다.
  2. 어느 걸음도 `:threw` 가 아니다 — 던진 판의 정본은 `_retry_gate` 이고, 두 트리거가 한
     판에서 겹치면 왕복이 둘이 된다. `:none` 으로 비켜선다(상한 1은 구조로 지킨다).
  3. `world_delta_body` 가 **잰 값**이다 — `nothing` 도, 여섯째 축만 `nothing` 인 것도
     **못 쟀다**이다. 🔴 못 잰 판에서 "너는 아무것도 안 바꿨다" 고 말하는 것은 **거짓말**이다:
     우리는 보지 않았다. 그 판은 `:noop_refused_unmeasured` 로 **세어지고 되먹임은 안 간다**.
  4. `_wd_is_zero(world_delta_body)` — 그 지문의 여섯 축이 전부 잰 0 이다. 하나라도 비-0 이면
     body 는 세계를 **움직였다**(증명이다) — 그 판은 이 채널의 사건이 아니다: `:none`.

🔴 **`applied` 로 게이트하지 않는다** — 그것이 이 판정의 가장 위험한 유혹이고, 두 근거로
   거절한다. (a) **정보가 없다**: 생성 원시의 status 는 선언된 어휘에 없으므로
   `_step_applied` 가 `nothing` 을 낸다(testset (32) 가 그것을 잰다) — 즉 주조 body 에서
   `applied` 는 거의 언제나 "못 쟀다"이고, 그것으로 게이트하면 이 채널이 **구조적으로 죽는다**.
   (b) **판정이 아니라 자기신고다**: 유료 런 6 은 `applied` 가 성공을 말하는데 세계가 안
   움직인 **거짓 성공**이었다. 자기신고를 문지기로 쓰면 정확히 그 판이 빠져나간다.

🔴 **이 게이트는 "세계가 안 바뀌었다" 를 주장하지 않는다.** 여섯 축은 배터리 교체 ·
   `SPARE_POOLS` · fault 플래그 · 배송을 **안 본다**(정본은 `_world_digest` 의 docstring).
   주장하는 것은 **"우리가 본 여섯 축이 안 움직였다"** 뿐이고, 그래서 전선에 실리는 문장도
   정확히 그것만 말한다(`_noop_feedback_reason` 이 그 문장을 소유한다).

⚠️ **대가를 정직하게 적는다:** 설계상 무동작인 body(예: 이미 치워진 존을 다시 치우는 판)도
   되먹임 왕복을 **한 번** 탄다. 그것을 막으려면 "어떤 status 가 정당한 무동작인가" 를 여기서
   판정해야 하는데, 그 어휘는 주조 원시에 대해 **존재하지 않는다**(위 (a)). 관측만 보내므로
   그 판에서 모델이 "고칠 것이 없다" 고 답하는 것은 **허용된 답**이다.
"""
_noop_gate(r, wdb) =
    (try isempty(r.steps) catch; true end)                          ? :none :
    (try any(s -> s.status === :threw, r.steps) catch; true end)    ? :none :
    wdb === nothing                                                 ? :noop_refused_unmeasured :
    !(try wdb.n_staging_moved isa Integer catch; false end)          ? :noop_refused_unmeasured :
    _wd_is_zero(wdb)                                                ? :ok :
    :none

"""
    _noop_feedback_reason(r, world_delta_body) -> String

**잰 무동작**을 agent-3 에게 되먹일 자유 문자열. 전선 필드는 `impl_rejected_why` 그대로다
(두 번째 철자를 만들지 않는다 = `src/respec/llm_service/` 를 안 건드린다 = 지문이 안 뒤집힌다).

🔴 **이 문장은 관측만 말한다. 처방을 말하지 않는다** — 그것이 이 실험을 유효하게 만드는
   선이다. 모델이 **무엇을 해야 하는지 스스로 알아내야** 측정이 뜻을 갖는다. 그러므로 금지:
   동사 이름 · 광고된 접근자 이름 · "열거하라" 류의 지시 · 두 갈래 상승 힌트 · `expressible`.
   `test/minted_end_to_end.jl` (38) 이 그것을 **어휘적으로** 못박는다(내보낸 이름 183개 중
   하나라도 이 문자열에 나오면 빨개진다).

**문장을 한 조각씩 변호한다 — 전부 잰 것이다:**

 · `the body ran to completion and raised no error`
   — 잰 것이다: 게이트 연언지 1·2(걸음이 있고 `:threw` 가 없다).
 · `its own returned status was <name>=<status>…`
   — 잰 것이다. **모델 자신의 반환값**을 그대로 되돌려준다. 이것이 없으면 이 문장이
     **부정직해진다**: 유료 런 8 의 body 는 `:failure` 를 돌려줬고, 그 판에 "오류 없이
     끝났다" 만 보내는 것은 사실의 절반을 감춘다. 그리고 유료 런 6 처럼 status 가 성공을
     말하는 판에서는 그 병치 자체가 **모델이 달리 얻을 수 없는 사실**이다("네 자기신고와
     측정이 어긋난다"). 🔴 진단이 아니다 — 우리는 그 불일치를 **해석하지 않고** 두 값을
     나란히 놓을 뿐이다.
 · `The world was measured immediately before the body ran and again immediately after`
   — 잰 것이다: `_pre` 는 `CB.enact_minted!` 직전(등록·타입검사는 세계를 안 건드린다),
     `r.body_probe` 는 body 루프 직후·하네스의 재개/재풀이 **앞**이다(Task 2).
 · `every measured axis was identical: <여섯 축>`
   — 잰 것이다: 게이트 연언지 3·4. 글자는 기록 줄과 **같은 렌더러**(`_wd_axes_str`)가 낸다.
 · `n_binding_changed is a lower bound.`
   — `_world_digest` 의 docstring 이 소유하는 사실. 기록 줄의 한국어 각주와 같은 사실이다.
 · `These six axes are the only part of the world that was measured, so this is an
   observation about them and not a claim that nothing at all happened.`
   — 🔴 **필수 헤지.** 여섯 축은 배터리 교체·`SPARE_POOLS`·fault 플래그·배송을 안 본다.
     이 문장이 없으면 우리가 재지 않은 것을 잰 것처럼 말하게 된다.
     ⚠️ **무엇이 안 재졌는지는 이름 붙이지 않는다** — "배터리" 나 "배송" 을 적는 순간
     그것은 관측이 아니라 어디를 보라는 **처방**이 된다.

⚠️ `status` 는 **모델이 쓴 텍스트**다(`_step_status` 가 `Symbol(getproperty(out, :status))`
   로 만든다). 그래서 `_one_line_rec`/`_cap_detail` 을 지난다 — 개행 하나가 이 사유를 나르는
   진단 `println` 을 두 줄로 쪼개면 로그를 읽는 사람이 사유를 잃는다.
"""
function _noop_feedback_reason(r, wdb)
    local sts = try
        _cap_detail(_one_line_rec(join([string(s.name, "=", s.status) for s in r.steps], ", ")))
    catch; "unavailable" end
    return string(
        "enact_noop: the body ran to completion and raised no error; ",
        "its own returned status was ", sts, ". ",
        "The world was measured immediately before the body ran and again immediately ",
        "after, and every measured axis was identical: ", _wd_axes_str(wdb), ". ",
        "n_binding_changed is a lower bound. ",
        "These six axes are the only part of the world that was measured, so this is an ",
        "observation about them and not a claim that nothing at all happened.")
end

"""
    _RETRY_SYMS_THREW · _RETRY_SYMS_NOOP

`_rewrite_retry!` 가 낼 세 상태의 이름표. **두 트리거를 한 심볼로 뭉개지 않는다** — 로그를
읽는 사람은 "던져서 되먹였다" 와 "안 움직여서 되먹였다" 를 반드시 갈라야 한다(처방이 다르다).

⚠️ 던진 쪽의 세 이름은 **D17b 와 바이트 동일**하다. 접두를 붙여 통일하고 싶은 유혹이 있지만
   그러면 `tools/monitor/test_ladder_report.py` 의 실측 리터럴과 결정 행의 옛 값이 한꺼번에
   갈린다 — 이 파일의 규약대로 **넓히기만** 한다.
"""
const _RETRY_SYMS_THREW = (roundtrip = :roundtrip_failed,
                           rejected  = :rejected,
                           retried   = :retried)
const _RETRY_SYMS_NOOP  = (roundtrip = :noop_roundtrip_failed,
                           rejected  = :noop_rejected,
                           retried   = :noop_retried)

"""
    _rewrite_retry!(env, truth, sl, r, _pre, why, nm, syms) -> NamedTuple

되먹임 **한 벌**: 사유를 `/rewrite` 로 보내고 · 고친 body 를 검사·설치·재등록하고 ·
성공이면 **두 번째로 집행**한다. 반환은 일곱 필드로 고정이다
(`retry`·`reenacted`·`r`·`world_delta`·`world_delta_body`·`interface_calls`·`impl_rejected_why`).

🔴 **두 트리거가 이 한 벌을 공유한다**(D17b = 집행 예외, D17c = 잰 무동작). 두 벌을 두면
   검사 순서·사유 이름·`allow_redefine` 의 좁힘이 갈리고, 이 파일은 그 갈림을 이미
   `_install_rewrite!` 를 만들며 한 번 겪었다. **다른 것은 게이트와 사유 문자열과 상태
   이름 셋뿐이고, 그 셋은 전부 인자로 들어온다.**

🔴 **상한은 1 이고 루프가 아니라 구조다.** 이 함수에는 반복이 없고, 호출자는 두 트리거를
   `if`/`elseif` 로 배타로 묶는다 — 그래서 한 판에서 왕복은 많아야 **하나**다. 두 번째
   집행 결과는 그대로 기록되고 **다시 되먹이지 않는다**(무동작이어도 그렇다).

🔴 `reenacted == false` 인 두 자리(`roundtrip`·`rejected`)에서는 `world_delta*` 와
   `interface_calls` 가 `nothing` 이다 — **그 값들을 호출자가 덮으면 안 된다**는 뜻이다.
   호출자가 `reenacted` 로 그것을 지킨다. 여기서 첫 시도의 값을 되돌려주는 모양은 일부러
   피한다: 반환에 "첫 시도 값" 과 "두 번째 시도 값" 이 같은 이름으로 섞이면 호출자가 어느
   쪽을 기록하는지 읽는 사람이 못 가른다.

🔴 이름·코드는 **`sl` 에서 다시 읽는다** — D17 의 되먹임이 이미 성공한 판에서는 인자 `nm`
   이 **등록된 적 없는 옛 값**이다(D5 문단과 같은 근거).

🔴 `allow_redefine` 은 "agent-3 이 **방금 우리가 주조한 그 이름**을 그대로 돌려줬는가" 일
   때만 참이다. 두 트리거 다 첫 등록이 **성공한** 뒤의 판이므로 그 이름은 이미
   `_MINTED_EVER` 에 있고, 안 풀면 고친 body 가 **언제나** `already_minted` 로 거절돼
   채널이 구조적으로 죽는다(D17b §6 실측). 다른 이름이면 `false` 이고 충돌 셋의 판정
   (D6 신호 포함)은 그대로 산다.
"""
function _rewrite_retry!(env, truth, sl, r, _pre, why::AbstractString, nm, syms)
    local _prev_nm = String(something(_synth_lane_field(sl, "impl_name"), nm))
    local _prev_cd = String(something(_synth_lane_field(sl, "impl_code"), ""))
    local fx = _rewrite_once(sl, _prev_nm, _prev_cd, why)
    if fx === nothing
        return (retry = syms.roundtrip, reenacted = false, r = r,
                world_delta = nothing, world_delta_body = nothing,
                interface_calls = nothing, impl_rejected_why = nothing)
    end
    local why2 = _install_rewrite!(sl, fx; allow_redefine = (fx.impl_name == _prev_nm))
    if why2 !== nothing
        # ⚠️ 사유는 **두 번째 시도의 것**이다(D17 과 같은 규약).
        return (retry = syms.rejected, reenacted = false, r = r,
                world_delta = nothing, world_delta_body = nothing,
                interface_calls = nothing, impl_rejected_why = why2)
    end
    # 🔴 첫 시도의 걸음은 아래 기록 줄에서 **사라진다**(그 줄은 두 번째 시도를 적는다).
    #    그래서 여기서 따로 찍는다 — 접두가 `[minted] enact_retry:` 라
    #    `ladder_report.py` 의 `MINTED_RE`(`\\[minted\\] lane=present…`)에 안 걸린다.
    println("[minted] enact_retry: 되먹임 1회 — 첫 시도 steps=[",
            join([_step_render(st) for st in r.steps], " "), "]",
            " 사유=", why)
    # 🔴 `_pre` 는 **안 다시 찍는다.** `world_delta` 는 이 판에서도 "집행 봉투 전체" 의 뜻을
    #    유지해야 한다 — 두 시도를 합친 누적 차분이다. (두 게이트 다 첫 시도의 body 차분이
    #    잰 0 인 판에서만 열리므로, 이 누적값은 실질적으로 두 번째 body 의 것이다.)
    local r2 = CB.enact_minted!(env, truth, sl; probe = () -> _world_digest(env))
    return (retry = syms.retried, reenacted = true, r = r2,
            world_delta = _world_delta(_pre, _world_digest(env)),
            world_delta_body = _world_delta(_pre, r2.body_probe),
            # 🔴 L3 은 **등록된 이름**에서 다시 읽는다(D5 와 같은 근거).
            interface_calls = _interface_calls_of(
                something(_synth_lane_field(sl, "impl_name"), nm)),
            impl_rejected_why = nothing)
end

"""
    _retry_str(x) -> String

`enact_retry` 삼상+를 로그 한 조각으로. **공백이 없다** — `[minted]` 줄은 공백으로 갈리는
`key=value` 로 읽힌다(`ladder_report.py` 의 `MINTED_FIELD_RES` 는 `(\\S+)` 다).

🔴 상태가 나르는 구별(`dropped_args` 가 이 파일의 선례다):
  · `n/a`                        — **한 번도 시도 안 했다**(트리거가 아예 없었다: 집행이 안
                                   던졌고 body 가 잰 무동작도 아니었거나, 그 자리에 못 닿았다)

  **던져서 되먹인 갈래** (D17b, 판정은 `_retry_gate`):
  · `refused_not_first_step` 외 둘 — 던졌는데 **세계가 더러워서 거절했다**
  · `roundtrip_failed`           — 시도했고 **왕복이 실패했다**(서비스가 없거나 `wrote != true`)
  · `rejected`                   — 고친 body 가 **왔는데 재등록이 거절했다**(사유는 `impl_rejected_why`)
  · `retried`                    — 고친 body 가 왔고 **두 번째로 집행했다**

  **잰 무동작으로 되먹인 갈래** (D17c, 판정은 `_noop_gate`):
  · `noop_refused_unmeasured`    — 안 던졌는데 **body 차분을 못 쟀다** — 못 잰 것을 두고
                                   "너는 아무것도 안 바꿨다" 고 말하지 않는다
  · `noop_roundtrip_failed` · `noop_rejected` · `noop_retried` — 위 셋과 같은 뜻, 다른 트리거

🔴 `retried` 가 이 줄에 없으면 사다리는 **두 번째 시도를 첫 시도의 깨끗한 성공으로 채점한다.**
   그 구별이 이 필드의 존재 이유다.
🔴 **두 트리거를 한 이름으로 뭉개지 않는다**(2026-09-05, D17c). `retried` 와 `noop_retried`
   는 **다른 사건**이다 — 앞은 "예외 메시지를 되먹였다", 뒤는 "잰 0 을 되먹였다" 이고
   유료 런의 사후 판독에서 그 둘은 서로 다른 처방을 부른다. 접두 `noop_` 하나가 그 구별을
   `(\\S+)` 한 번의 판독으로 나른다. 이름표의 정본은 `_RETRY_SYMS_THREW`/`_RETRY_SYMS_NOOP` 다.
"""
_retry_str(x) = x === nothing ? "n/a" : String(x)

"""
    enact_minted_decision!(env, truth, decision) -> NamedTuple

결정 행이 나른 합성 tool 을 등록·집행한다. `CB.register_minted_primitive!` 를 `CB.enact_minted!`
**보다 먼저** 부르고(Task 9 — 생성 원시는 그 순간까지 존재하지 않는다), 등록·집행 여부를
로그와 반환값 양쪽에 남긴다. 반환은 `enact_minted!` 의 일곱 필드에 `handled::Bool`·
`registered::Union{Nothing,Bool}`·`impl_rejected_why::Union{Nothing,String}`·
`world_delta::Union{Nothing,NamedTuple}`·`world_delta_body::Union{Nothing,NamedTuple}`
를 더한 것이다.

🔴 **`world_delta` 는 D18 이 더한 유일한 "세계가 실제로 바뀌었나" 관측이다** — 정의도 근거도
위 `_world_digest`/`_world_delta` 가 소유한다(여기 다시 적지 않는다). 삼상이다: `nothing` =
지문을 못 찍었다, 0 의 튜플 = 찍었는데 안 바뀌었다.

🔴 **`world_delta_body` 는 그것과 다른 것을 잰다**(2026-09-04, Task 2). `world_delta` 는
**집행 봉투 전체**다 — `_issue_resume!`/`_resolve_if_needed!` 가 `CB.enact_minted!` 안에서
돌기 때문이다(F4). `world_delta_body` 는 그 하네스 걸음들 **앞**에서 `probe` 로 직접 찍은
지문과의 차분이라 **body 단독**이다. 유료 런 1 이 `delta_scope=body+harness_resolve` 라
0 이든 아니든 귀속이 불가능했던 자리가 정확히 이것이다. 삼상은 같다: `nothing` = probe 를
못 찍었다, 0 의 튜플 = 찍었는데 body 가 세계를 안 바꿨다.

🔴 **`enact_retry` 는 열이다**(2026-09-05, D17b + D17c). 상태 목록의 정본은 `_retry_str`
의 표이고 이름표의 정본은 `_RETRY_SYMS_THREW`/`_RETRY_SYMS_NOOP` 다 — 여기 다시 세지 않는다.
🔴 **트리거가 둘이고 로그가 그 둘을 가른다**: 접두 없는 넷은 **집행이 던진** 판(D17b),
접두 `noop_` 인 넷은 **body 가 잰 무동작**인 판(D17c — 유료 런 8 이 죽은 자리: 예외가
없었으므로 D17b 의 채널이 한 번도 안 발화했다). 한 판에서 왕복은 **많아야 하나**다
(집행부의 `if`/`elseif` 가 그 배타를 구조로 지킨다).

🔴 **`noop_refused_unmeasured` 를 `n/a` 로 뭉개지 말 것.** `n/a` 는 "트리거가 없었다"
(= 안 던졌고, 잰 여섯 축 중 하나라도 움직였다)이고, 이 값은 "안 던졌는데 **차분을 못 쟀다**"
이다. 못 잰 판에서 모델에게 "너는 아무것도 안 바꿨다" 고 말하는 것은 거짓말이므로 되먹임은
안 가지만, 그 사실은 **세어져야** 한다.

D17 의 되먹임은 **등록 거절**에서만
발화했다 — 등록을 통과한 body 가 **집행에서 던져** 죽은 판(유료 런 2·4·5·7)에는 되먹임이
한 번도 안 갔다. 이 필드가 그 판의 기록이다: `nothing`(= 로그의 `n/a`, 시도 안 했다) ·
`:refused_not_first_step`/`:refused_world_changed`/`:refused_world_unmeasured`(던졌는데
세계가 더러울 수 있어 **거절**했다 — 판정의 정본은 `_retry_gate` 다) · `:roundtrip_failed`
(시도했고 왕복이 실패했다) · `:rejected`(고친 body 가 왔는데 재등록이 거절했다 — 사유는
`impl_rejected_why`) · `:retried`(고친 body 가 왔고 **두 번째로 집행했다**).
🔴 **`:retried` 판에서는 이 반환의 나머지가 두 번째 시도를 말한다** — `verdict`·`applied`·
`partial`·`steps`·`world_delta*` 전부. 첫 시도의 걸음은 `[minted] enact_retry:` 진단 줄
하나에만 남는다. 이 필드가 없으면 사다리가 두 번째 시도를 **첫 시도의 깨끗한 성공**으로
채점한다 — 그 구별이 이 필드의 존재 이유다.
🔴 상한은 **1** 이고 루프가 아니라 **구조**다(D17 과 같은 규약): 두 번째 집행 결과는 그대로
기록되고 다시 되먹이지 않는다.

🔴 **`registered` 는 셋이다**(2026-09-03 최종 리뷰 F2, 컨트롤러 판정 R7 — R2 를 대체한다).
`nothing` = 등록이 실제로 됐는지 이 함수가 판정하지 못했다(catch 로 떨어졌는데 그 지점까지
`registered` 를 확정할 자리에 한 번도 안 닿았다) · `false` = 봤는데 등록이 안 됐다(시도 안
했거나, 시도했는데 거절됐다) · `true` = 등록이 실제로 됐다. `Bool` 하나로는 "몰라서 못
쟀다"와 "봤는데 안 됐다"가 같은 값으로 뭉개진다 — 이 파일이 도처에서 지키는 삼상 규약을
이 필드에만 안 지킬 이유가 없다.

🔴 **`Union{Nothing,Bool}` 을 그대로 둘 것 — `Bool` 로 되돌리지 말 것**(2026-09-03 최종
리뷰 F7/F9, 컨트롤러 판정 R8/R9). 방어적 타입이다.

🔴 **F7 직후에 적힌 "오늘 도달 가능한 생산자가 없다" 는 그 시점에 거짓이었다**(F9 최종
리뷰가 잡았다). F7 은 `register_minted_primitive!` 자신의 `params` 키-타입 위반만
고쳤는데, 그 함수가 **먼저** 부르는 `check_impl_conventions`(`minted_registration.jl`)
안에 **던지는 자리가 하나 더** 있었다 — 파싱된 함수 시그니처의 콜리(`sig.args[1]`)가
`Symbol` 이 아닌 세 모양(한정 이름 `Base.foo!` · 보간 `\$(...)` · callable 객체
`(o::T)(...)`)에서 `String(sig.args[1])` 이 던졌다. 그중 한정 이름은 **모델이 실제로
쓸 법한** 모양이고, 가장 위험한 예가 정확히 D6 이 재려는 사건
(`ConstructionBots.release_pending_assignments!` 처럼 가려진 능력을 다시 이름 붙이는
시도)이다 — 그 사건이 이 자리에서 던지면 `impl_rejected_why=nothing` 인 raw
`MethodError` 로 새어 나가 D6 신호가 **기록되지 않는다.** F9 가 `check_impl_conventions`
에 그 세 모양의 거절 사유를 각각 더해 이 던지기를 없앴다(실측: 셋 다 이제
`reject:impl_name_is_qualified:...`/`_is_interpolated:...`/
`impl_signature_is_callable_object:...` 를 던지지 않고 반환한다).

**재도출(다시 가정하지 않는다) — 세 번째 갱신, F14.** F9 직후 이 문단은 "`name`/
`code`/`surface` 가 `AbstractString` 으로 좁혀져 들어오니 무가드 변환이 없다" 고
적었는데 **틀렸다** — `AbstractString` 이라는 **타입**은 유효한 UTF-8 이라는 **내용**을
보장하지 않는다. `Base.isidentifier(chop(name))` 는 `name` 을 문자 단위로 훑는데,
`name` 에 유효하지 않은 UTF-8(외톨이 연속 바이트 등)이 섞여 있으면 `Base.InvalidCharError`
로 던졌다(실측) — F9 가 막은 것은 **AST 모양** 축이고, 이것은 **`name` 인자의 바이트
내용** 축이라 F9 의 헤지가 아예 안 짚은 자리였다(같은 실수를 라운드 2·3 에 걸쳐 두
번 반복한 것과 같은 결의 실수 — "타입이 맞으니 안전하다" 를 검증 없이 가정했다).
F14 가 `check_impl_conventions` 맨 앞에 `isvalid(name) || return "reject:impl_name_not_utf8:…"`
를 넣어 이 축을 닫았다(실측: `Symbol(name)` 도 같은 입력에서 던진다 — 이 가드 하나가
막는 던지는 자리는 둘이다). 그래도 **함수 자체의 계약**(예외가 아니라 거절)은 입력의
출처와 무관하게 지켜야 하므로 고쳤다 — 도달가능성과 무관하게.

그래도 `registered` 의 타입을 `Bool` 로 좁히지 않는다 — 이 함수(`enact_minted_decision!`)
자신의 나머지 코드(`decision.synth_lane` 이후, `CB.enact_minted!` 호출 등)에 미래에
새 예외 경로가 생기면 그 지점 이전의 `registered` 는 다시 `nothing` 이 정직한 값이기
때문이다. **이 자리를 다시 재려고 아래 두 함수에 또 버그를 기대는 시험을 짓지 말 것**
— `test/minted_end_to_end.jl` (3)이 그 함정에 한 번 빠졌었고 F7 이 그것을 고쳤다.

`handled == true` 는 "이 사건은 합성 tool 이 처리했으니 기본 복구 사슬을 타지 말라"는 뜻이다.
`false` 면 호출자는 예전 경로를 그대로 탄다 — 그 폴백이 **조용하지 않도록** 여기서 찍는다.

🔴 **`registered`·`impl_rejected_why` 는 이 함수의 반환 자리 넷 전부에 있고 필드 집합이
바이트 동일하다**(설계 §8, Task 9 컨트롤러 판정 R2, 2026-09-03 최종 리뷰 F2 로 `registered`
의 타입이 R7 로 갱신됐다). 한 자리라도 빠뜨리면 Julia 소비자는 NamedTuple 을 이름으로
읽으므로 "모델이 코드를 안 냈다"(`impl_name` 이 없어 조기 반환)와 "냈는데 규약 위반으로
거절됐다"(`register_minted_primitive!` 가 문자열을 돌려줬다)가 **같은 관측**이 된다 —
이 레포가 `train_kinds`·`require_vocab`·`handled` 에서 이미 세 번 데인 실패 모양이다.
`impl_rejected_why` 는 등록을 시도했는데 거절된 경우에만 그 사유 문자열이다 — 나머지는
전부 `nothing`("등록을 시도하지 않았다" 또는 "몰라서 못 쟀다").

🔴 **`handled` 의 정의는 바로 위 `minted_handled(r)` 하나가 소유한다 — `applied` 가 아니다.**
이 문단은 그 함수를 **인용**할 뿐 식을 다시 적지 않는다(손베낀 복사본이 이미 한 번 갈렸다).
🔴 첫 연언지는 `CB.ENACTED_VERDICTS`(정본은 `minted_tool.jl`)가 정한다 — 2026-09-02 결정
2·3 은 그 집합을 `:admit`·`:admit_unsanctioned` 둘로 넓혔었는데, 2026-09-03 (Task 9, 컨트롤러
판정 R1) 이 `:admit_unsanctioned` 를 다시 지웠다(조합 단계 자체가 없어져 그 구분이 무의미해
졌다) — 오늘은 다시 `:admit` 하나다. `CB.minted_handled_verdict_ok` 가 그 판정을 대신하므로
이 파일은 집합의 크기를 손으로 세지 않는다. 나머지 셋(`world_maybe_dirty` · `resume !== :failed`
· `!resolve_failed`)은 그대로.
`applied` 는 status 전용이라, 1단계가 세계를 바꾸고 2단계가 **던지면** `applied == false` 인데
세계는 이미 편집돼 있다(`partial == true`, `undo === :none`). 그 반쯤 고쳐진 세계 위에 기본
복구 사슬을 얹는 것은 안 얹는 것보다 나쁘다. 그래서 판정은 파생 필드 `world_maybe_dirty` 로
한다. 브리핑의 `(:admit) && applied` 는 바로 그 경우를 놓친다.

🔴 **그 파생 필드는 `touched || partial` 이지 `applied || partial` 이 아니다**(룰링 R48).
`translate_whole_build!` 의 `:residual_blocked`·`:already_clear` 는 `applied == false` 인데
빌드를 **이미 옮긴 뒤**의 status 다. 여기에 옛 등식을 적으면 그 판이 "세계가 깨끗하다"로
읽히고, zone 매크로가 어휘로 돌아오는 순간 그 거짓말이 **제어 흐름**이 된다. 정의는
`enact_minted!` 의 `_r` 하나가 소유한다 — 이 문단은 그것을 **인용**할 뿐 다시 적지 않는다.

🔴 **`resume === :failed` 면 `handled` 는 거짓이다**(2026-08-30 최종 리뷰, CRITICAL — 다섯
번째 조용한 미복구). 세계는 고쳐졌는데 `_issue_resume!` 이 던져 프론티어가 낡은 채로 남은
판이다. 그때 `handled=true` 를 내면 `policy_producer` 가 `nothing` 을 반환해 기본 복구
사슬이 통째로 건너뛰어지고, 그 OOD 사건은 **이미 소비돼 다시 오지 않는다** = 성공과
구별되지 않는 미복구. 그것이 정확히 `PRIMITIVE_RESUMES_CACHE` 가 막으려고 존재하는 사건이다.
⚠️ 나머지 넷(`:issued` · `:not_needed_self` · `:not_needed_untouched` · `:none`)은 전부
"프론티어가 낡지 않았다"이므로 `handled` 를 막지 않는다 — 다섯 상태의 정본 목록은
`enact_minted!` 의 표에 있다.

🔴 **삼상을 이상으로 뭉개지 않는다**(spec §9-2). 로그는 `applied` · `partial` ·
`world_maybe_dirty` 를 **따로** 찍는다 — 하나로 접으면 "불렀는데 아무 일도 없었다"(조용한
성공)와 "던져서 세계가 절반이다"가 읽는 사람에게 같은 관측이 된다.

🔴 **`resume` 를 그대로 나른다**(2026-08-30 T4 리뷰, CRITICAL). 집행 가능한 여덟 중 다섯은(2026-09-01 실측 — 이 문장은 예전에 "여섯 중 셋"이었고 두 번 낡았다)
스케줄 캐시를 스스로 재개하지 않아 `enact_minted!` 이 대신 부른다 — 안 부르면 세계는 고쳐졌는데
프론티어가 낡은 채 남고, `handled=true` 가 기본 복구 사슬을 건너뛰며, 그 OOD 사건은 이미
소비돼 다시 오지 않는다 = **성공과 구별되지 않는 미복구**. 그 판정을 로그가 찍는다.

🔴 **`[minted]` 줄은 모든 경로에서 찍힌다** — `synth_lane` 이 아예 없는 조기 반환에서도, 집행부가
던진 경로에서도. 이유: `policy_producer` 는 OOD 마다 도달하지 않는다(`is_reform_alarm` 조기
반환 · `truth_for_event` 의 NL 정확일치 조회 실패). 조건부로 찍으면 "`[minted]` 줄이 없다"가
**"레인이 조용했다"와 "producer 에 도달조차 못 했다"** 두 원인을 갖게 되어 다음 태스크가
그 둘을 못 가른다. 무조건 찍으면 부재는 후자 하나만 뜻한다.

🔴 **본체 전체가 `try` 안이다.** `resolve_primitive` 와 `PRIMITIVE_TABLE` 은 설계상 `error(...)`
를 낸다(레지스트리 부재 · impl 이름이 CB 에 없음 …). 그 예외가 여기서 새면 `maybe_respecify!`
의 producer `try` 로 올라가고, `:soft` 가 아닌 사건에서는 `engage_fallback!` = **라인 정지**가
걸린다(`release_fallback!` 는 생산 경로에서 그것을 되돌리지 않는다). 즉 JSON 오타 하나가 렌더를
세우고 로그는 OOD 를 탓하게 된다. 잡아서 크게 찍고 정상 반환한다.

⚠️ 잡은 예외의 반환을 `verdict = :reject`(= 아무것도 부르기 전에 돌아섰다)로 적는 근거: 이
경로에서 던질 수 있는 것은 **호출 이전** 단계뿐이다(`enact_minted!` 는 원시 호출과 반환값 읽기를
자기 `try` 로 감싸고 그 예외를 `:threw` **기록**으로 바꿔 정상 반환한다).

⚠️ **MILP 프로브는 센티넬이다**(`enact_macro!` 의 같은 관용구). `LAST_EDGE_COSTS[]` 는 재풀이가
없으면 **미정의**이지 0 이 아니다 — 맨 `length(...)` 를 찍으면 "후보 간선이 0" 과 "MILP 가 아예
안 돌았다" 가 같은 관측이 된다. 그래서 `ran_milp` 없이 `length` 를 찍지 않는다.
"""
function enact_minted_decision!(env, truth, decision)
    # 🔴 F2(2026-09-03 최종 리뷰, 컨트롤러 판정 R7). `registered`·`impl_rejected_why` 를
    #    `try` **안에서** `local` 선언하면 Julia 의 try/catch 는 그 결속을 catch 에 안
    #    보인다(실측: `UndefVarError` — try 와 catch 는 서로 다른 지역이다). 그래서 옛
    #    catch 경로는 그 값을 "손으로 다시" 리터럴 `false` 로 적을 수밖에 없었고, 그 자리가
    #    바로 R2 시절의 결함이었다: 등록이 실제로 성공한 **뒤에** `CB.enact_minted!` 가
    #    던지면 `minted_table()` 에는 원시가 실제로 있는데 기록은 "등록 안 됐다" 고
    #    거짓말했다. `try` **밖**에서 선언하면 두 블록이 **같은 결속**을 보므로, catch 는
    #    "예외 직전까지 실제로 관측된 값"을 그대로 돌려준다 — 등록이 이미 끝난 뒤 던지면
    #    `true` 를 정확히 안다. 그 값에 **한 번도 도달하지 못하고** 던지면(결정 지점 이전)
    #    `nothing`("몰라서 못 쟀다")으로 남는다.
    local registered::Union{Nothing,Bool} = nothing
    local impl_rejected_why::Union{Nothing,String} = nothing
    # 🔴 D17c (2026-09-05). **한 런의 왕복 예산은 1이다** — 되먹임 자리가 이제 셋이라
    #    (D17 등록 거절 · D17b 집행 예외 · D17c 잰 무동작) 예산을 안 세면 한 판이
    #    유료 왕복을 **둘** 낼 수 있다: 등록이 거절돼 고쳐진 body 가 집행에서 죽거나
    #    무동작이면 두 번째 왕복이 나간다. 그 판이 실재하고(D17 은 `live_cache_env`
    #    에서 실제로 발화한다) 아무 게이트도 그것을 안 막고 있었다.
    # 🔴 `registered` 와 **같은 이유로** `try` 밖이다(F2/R7 문단): try 의 결속은 catch
    #    에 안 보이므로, 안에서 선언하면 catch 가 값을 손으로 다시 적어야 하고 그
    #    사본이 거짓말을 한다.
    local rewrote::Bool = false
    # 🔴 D18. `registered` 와 **같은 이유로** `try` 밖이다(F2/R7 문단): try 의 결속은 catch 에
    #    안 보이므로, 안에서 선언하면 catch 는 값을 손으로 다시 적을 수밖에 없고 그 복사본이
    #    거짓말을 한다. 밖에서 선언하면 catch 는 "예외 직전까지 실제로 관측된 값"을 그대로
    #    나른다 — 차분을 이미 계산한 뒤에 던졌으면 그 차분을, 그 전에 던졌으면 `nothing`
    #    ("못 쟀다")을. 지문을 아예 안 찍는 반환 자리(조기 deferred · `_reject_malformed`)는
    #    초기값 그대로 `nothing` 이다: **0 의 튜플이 아니다** — 그 자리들은 세계를 안 읽었다.
    local world_delta::Union{Nothing,NamedTuple} = nothing
    # 🔴 Task 2 (2026-09-04). **body 단독**의 차분. `world_delta` 와 **같은 이유로** `try`
    #    밖이다(위 문단): try 의 결속은 catch 에 안 보인다. 삼상은 그대로 — `nothing` 은
    #    "probe 를 못 찍었다"(집행이 거기 도달 못 했거나 지문이 안 나왔다)이고 0 의 튜플은
    #    "찍었는데 body 가 세계를 안 바꿨다" 다.
    local world_delta_body::Union{Nothing,NamedTuple} = nothing
    # 🔴 D5 (Wave D). **L3 이 L4 와 같은 자리에서 읽힌다.** `world_delta` 와 **같은
    #    이유로** `try` 밖이다(위 F2/R7 문단): try 의 결속은 catch 에 안 보이므로, 안에서
    #    선언하면 catch 가 값을 손으로 다시 적을 수밖에 없고 그 복사본이 거짓말을 한다.
    #    삼상: `nothing`(못 쟀다 — 등록 자체가 없었거나 행을 못 읽었다) · `String[]`(재서
    #    없다) · 비지 않은 정렬된 목록(L3 참). 정의는 `_interface_calls_of` 가 소유한다.
    local interface_calls::Union{Nothing,Vector{String}} = nothing
    # 🔴 D17b (2026-09-05). **집행-예외 되먹임의 삼상+.** `world_delta` 와 **같은 이유로**
    #    `try` 밖이다(위 F2/R7 문단): try 의 결속은 catch 에 안 보이므로, 안에서 선언하면
    #    catch 가 값을 손으로 다시 적을 수밖에 없고 그 복사본이 거짓말을 한다 — 여기서는
    #    특히 나쁘다: 되먹임이 **성공해 두 번째 body 를 집행한 뒤** 던진 판이 `n/a`("시도
    #    안 했다")로 기록되면, 사다리가 두 번째 시도를 첫 시도로 채점한다.
    #    상태의 뜻은 `_retry_str` 의 docstring 이 소유한다(리터럴을 두 벌 안 적는다).
    local enact_retry::Union{Nothing,Symbol} = nothing
    try
        local sl = try decision.synth_lane catch; nothing end
        # 🔴 2026-09-03 (Task 9, R1). 예전엔 `reach` 가 "이 판이 상세를 실었는가" 의 미끼였다.
        #    `reach` 는 경계 키에서 빠졌으므로(agent-3 이 이제 조합이 아니라 코드를 쓴다, D8)
        #    같은 자리를 `impl_name` 이 대신한다 — `minted_tool.jl` 의 step (1) 게이트와
        #    **같은 미끼**를 써야 한다. 안 맞추면 여기서 먼저 deferred 로 떨어져 그 게이트에
        #    영영 안 닿는다.
        local nm = sl === nothing ? nothing : _synth_lane_field(sl, "impl_name")
        # ---- 조기 반환도 조용하지 않다 (C5) ------------------------------------------------
        if sl === nothing || nm === nothing
            registered = false   # 확정이다 — 등록할 코드 자체가 없어 시도조차 안 했다.
            # 🔴 **두 갈래는 다른 사건이고 사유도 달라야 한다**(2026-08-30 최종 리뷰, spec §9-2).
            #    `sl !== nothing && nm === nothing` 에서는 합성 레인이 **있다** — 그런데도
            #    `reason=no synth lane on this decision` 을 찍는 것은 거짓 진술이었다.
            # 🔴 그리고 그 갈래는 판별에 필요한 값 넷을 **이미 손에 들고 있다**:
            #    `synthesis_event`(발화할 사건이었나) · `synthesis_ran`(발화해서 돌았나) ·
            #    `synthesis_error`(돌다 터졌나) · `tool_minted`(뭘 주조했나). 이 넷이
            #    "레인이 안 돌았다" · "돌다 터졌다" · "돌았고 expressible 이라 안 쐈다" 를 가른다.
            #    안 찍으면 그 판별에 **유료 호출을 한 번 더 써야 한다** — T5 가 실제로 그랬다.
            local lane = sl === nothing ? "absent" : "impl_name_nothing"
            local why  = sl === nothing ?
                "no synth lane on this decision" :
                "synth lane present but impl_name is nothing — 아래 여섯 필드가 원인을 가른다"
            _rec_line("[minted] lane=", lane,
                    " tool=", something(_synth_lane_field(sl, "tool_name"), "n/a"),
                    " verdict=deferred applied=n/a partial=false",
                    " world_maybe_dirty=false handled=false undo=none resume=none",
                    " args_from=n/a n_calls=n/a dropped_args=n/a",
                    " enact_retry=", _retry_str(enact_retry),
                    " steps=[]",
                    " ran_milp=n/a(not armed)",
                    " synthesis_event=", _synth_lane_field(sl, "synthesis_event"),
                    " synthesis_ran=", _synth_lane_field(sl, "synthesis_ran"),
                    " synthesis_error=", _synth_lane_field(sl, "synthesis_error"),
                    " tool_minted=", _synth_lane_field(sl, "tool_minted"),
                    # 🔴 2026-09-03 최종 리뷰. `wrote` 와 `refused` 는 **여기가 유일한 줄리아
                    #    독자**다(정본 근거는 `SYNTH_LANE_KEYS` 의 docstring). 이 갈래는
                    #    "이름이 안 왔다" 하나로 뭉쳐 있는데 그 원인이 넷이다 —
                    #      · `refused` 가 문자열: 돈을 쓰기 전에 G1 가드가 돌아섰다
                    #      · `wrote === false`: agent-3 이 못 쓰겠다고 자기신고했다
                    #      · `wrote === nothing` + `synthesis_ran===true`: 썼다는데 이름이 없다
                    #      · `synthesis_event === false`: 발화할 사건이 아니었다
                    #    앞의 둘을 안 찍으면 그 판별이 로그로 불가능해지고, 이 레포는 그 판별에
                    #    유료 호출을 한 번 더 쓴 전례가 있다(T5).
                    " wrote=", _synth_lane_field(sl, "wrote"),
                    " refused=", _synth_lane_field(sl, "refused"),
                    " registered=", registered, " impl_rejected_why=n/a",
                    # 🔴 D18. 여기까지 온 판은 세계를 읽은 적이 없다 — `closed=0` 이 아니라
                    #    **못 쟀다**. 이 줄이 없으면 라이브 로그에서 `world_delta` 의 부재가
                    #    "조기 반환" 과 "이 코드 이전 세대" 두 가지를 뜻하게 된다.
                    # 🔴 m3(2026-09-03 리뷰): 값을 **읽는다**. 예전엔 여기에 문자열을 손으로
                    #    적었고, 그러면 이 자리가 지문 뒤로 옮겨지는 날 조용히 거짓말한다.
                    " world_delta=", _world_delta_str(world_delta),
                    " reason=", why)
            println("[minted] NOT handled → 기본 복구 사슬로 폴백한다 ",
                    "(이 폴백은 조용하지 않다 — 위 verdict 가 이유다)")
            # 🔴 F8(2026-09-03 최종 리뷰). `applied = nothing` 이지 `false` 가 아니다 —
            #    아무 원시도 부르지 않았으니 "불렀는데 적응이 없었다"(측정된 `false`)가
            #    아니라 "그 판정 자리에 도달 못 했다"(`nothing`)다. `minted_tool.jl` 의
            #    `_r` 기본값을 F6(4) 가 이미 이렇게 고쳤다 — 이 파일의 조기 반환 넷도
            #    같은 규약을 따른다(F8, 소비자 전수조사로 영향 없음을 확인).
            return (handled = false, verdict = :deferred, reason = why,
                    applied = nothing, partial = false, world_maybe_dirty = false,
                    steps = NamedTuple[], undo = :none, resume = :none,
                    resolve = :none, args_from = nothing, n_calls = nothing, dropped_args = nothing,
                    registered = registered, impl_rejected_why = impl_rejected_why,
                    enact_retry = enact_retry,
                    world_delta = world_delta,
                    world_delta_body = world_delta_body,
                    interface_calls = interface_calls)
        end

        # ---- 등록이 먼저다 (Task 9) ---------------------------------------------------------
        # 🔴 등록이 먼저다. 생성 원시는 이 순간까지 존재하지 않는다 — 등록에 실패하면
        #    집행을 시도하지 않고 그 사유를 그대로 나른다(예외가 아니라 거절). `nm` 은 바로
        #    위에서 이미 읽었다 — 두 번 읽지 않는다(진실원 하나).
        # 🔴 F3(2026-09-03 최종 리뷰). 여기서 타입을 지키지 않으면 규약 위반 payload 넷
        #    (`impl_name` 이 숫자·`surface` 가 숫자·`params` 가 리스트·문자열)이 전부
        #    `String(...)`/`register_minted_primitive!` 안에서 **던지고**, 바깥 `try` 의
        #    catch 가 그것을 삼켜 `registered=nothing, impl_rejected_why=nothing` 으로
        #    적는다 — ⚠️ (2026-09-03 최종 리뷰 정정) `registered` 필드만 보면 "모델이
        #    코드를 안 냈다"(조기 deferred, `registered=false`)와 **다르게** 남는다(하나는
        #    `false` 하나는 `nothing`) — 그러니 그 둘을 정말로 구별 불가능하게 만드는 것은
        #    `impl_rejected_why` 다: 둘 다 `nothing` 이라 "코드가 없었다" 와 "코드는 있었는데
        #    타입이 틀려 등록 도중 던졌다" 를 그 필드 하나로는 못 가른다. R2 가 그 구별을
        #    위해 만든 필드인데 타입 검사가 없으면 목적이 무너진다. 그래서 여기서 **거절로**
        #    잡는다(예외가 아니라) — 클래스마다 자기 사유를 낸다.
        # 🔴 F6(2)(2026-09-03 최종 리뷰). `reason` 과 `impl_rejected_why` 가 이 클로저에서
        #    바이트 동일한 것은 **의도적**이다 — 이 지점(등록 전 타입 검사, 또는 등록 자체의
        #    거절)엔 실행이 아직 시작되지도 않아서(`enact_minted!` 를 부르기 전) `reason` 에
        #    얹을 추가 맥락(steps·resume·resolve 노트)이 하나도 없다. 아래 `:admit`/`:threw`
        #    경로의 `reason` 은 이 문자열 위에 그 맥락을 이어붙이므로 거기서는 갈린다 —
        #    `impl_rejected_why` 는 그 이어붙임과 무관하게 **등록 거절 사유만** 남기는
        #    자리이고, 지금은 이어붙일 것이 없어 우연히 같다.
        _reject_malformed(why) = begin
            registered = false
            impl_rejected_why = why
            _rec_line("[minted] lane=present tool=", something(_synth_lane_field(sl, "tool_name"), "?"),
                    " verdict=reject registered=false impl_rejected_why=", why,
                    # 🔴 D17b. 값을 **읽는다**(리터럴 `n/a` 를 손으로 안 적는다, m3 와
                    #    같은 근거). 이 클로저는 등록 자리에서만 불리므로 오늘은 언제나
                    #    `n/a` 지만, 그것은 이 자리의 사실이지 손으로 적을 상수가 아니다.
                    " enact_retry=", _retry_str(enact_retry),
                    # 🔴 D18: 집행 전에 돌아섰다 — 세계를 안 읽었다. 🔴 m3: 그래도 값을
                    #    **읽는다**(리터럴을 손으로 적지 않는다) — Task 9 가 이 클로저
                    #    주변을 실제로 건드렸고, 거절 자리가 지문 뒤로 옮겨지는 날 손으로
                    #    적은 `n/a` 는 아무 소리 없이 거짓이 된다.
                    " world_delta=", _world_delta_str(world_delta),
                    " reason=", why)
            # 🔴 2026-09-03 최종 리뷰(deferred item). 이 줄이 빠져 있으면 등록 거절 —
            #    **실제 라이브 런에서 가장 자주 밟힐 reject 경로**(자기신고 규약 위반)만
            #    비대칭 로그를 낸다: 다른 모든 handled=false 반환은 이 줄을 찍는데 여기만
            #    안 찍어서, 라이브 로그를 읽는 사람이 "이 판은 폴백이 조용했다" 로 오독한다.
            println("[minted] NOT handled → 기본 복구 사슬로 폴백한다 ",
                    "(이 폴백은 조용하지 않다 — 위 verdict 가 이유다)")
            # 🔴 F8(2026-09-03 최종 리뷰). `applied = nothing` 이지 `false` 가 아니다 — 이
            #    클로저의 모든 호출자는 원시를 하나도 안 불러 본 채 돌아선다(F6(4) 와
            #    같은 규약, `minted_tool.jl` 의 `_r` 기본값이 이미 이렇게 고쳐져 있다).
            return (handled = false, verdict = :reject, reason = why,
                    applied = nothing, partial = false, world_maybe_dirty = false,
                    steps = NamedTuple[], undo = :none, resume = :none, resolve = :none,
                    args_from = nothing, n_calls = nothing, dropped_args = nothing,
                    registered = registered, impl_rejected_why = impl_rejected_why,
                    enact_retry = enact_retry,
                    world_delta = world_delta,
                    world_delta_body = world_delta_body,
                    interface_calls = interface_calls)
        end
        nm isa AbstractString ||
            return _reject_malformed("reject:impl_name_not_a_string:$(typeof(nm))")
        # 🔴 F6(3)(2026-09-03 최종 리뷰). `impl_name` 이 **빈 문자열**(`nothing` 이 아니다)로
        #    도착하는 것은 실재하는 판이다 — agent-3 이 compose 단계까지는 갔는데 이름을
        #    못 냈을 때 파이썬 쪽 `_copy_body_fields` 의 `getattr(pred, f, "") or ""` 관용구가
        #    정확히 이 값을 만든다(`synthesize.py`). 이걸 조용히 등록만 건너뛰면(옛 코드)
        #    `body_names` 가 이름이 다른 무언가를 들고 있는 판에서 `enact_minted!` 이
        #    "unknown primitive: … 알파벳 밖이다" 를 내는데, 그 알파벳은 애초에 이 이름을
        #    맡아 달라는 요청을 받은 적이 없다 — **오귀인**이다. 그래서 여기서 먼저 자기
        #    사유로 거절한다.
        isempty(nm) && return _reject_malformed("reject:impl_name_is_empty")
        local cd = _synth_lane_field(sl, "impl_code")
        if cd !== nothing
            cd isa AbstractString ||
                return _reject_malformed("reject:impl_code_not_a_string:$(typeof(cd))")
            local surf_raw = _synth_lane_field(sl, "surface")
            (surf_raw === nothing || surf_raw isa AbstractString) ||
                return _reject_malformed("reject:surface_not_a_string:$(typeof(surf_raw))")
            local praw = _synth_lane_field(sl, "params")
            (praw === nothing || praw isa AbstractDict) ||
                return _reject_malformed("reject:params_not_an_object:$(typeof(praw))")
            local why = CB.register_minted_primitive!(
                name = String(nm), code = String(cd),
                params = something(praw, Dict{String,Any}()),
                surface = String(something(surf_raw, "unknown")),
                reversible = something(_synth_lane_field(sl, "reversible"), false) === true)
            # 🔴 2026-09-03 최종 리뷰(deferred item). `_reject_malformed` 를 그대로 쓴다 —
            #    손으로 다시 적은 복사본이 "NOT handled" 줄 하나를 빠뜨려 이 자리(가장
            #    자주 밟힐 등록-거절 경로)만 비대칭 로그를 냈던 것이 실제 결함이었다.
            #    하나의 함수로 합치면 그 종류의 갈림이 구조적으로 불가능해진다.
            # 🔴 D17. 거절 사유를 agent-3 에게 **한 번** 되먹인다. 재시도가 한 번인 것은
            #    루프가 아니라 **구조**다 — 두 번째 거절은 곧장 `_reject_malformed` 로 간다.
            #    (`@goto` 는 여기서 못 쓴다: Julia 의 `@goto` 는 `try` 블록 안팎으로 못 뛴다.)
            if why !== nothing
                local fx = _rewrite_once(sl, String(nm), String(cd), why)
                # 🔴 D17c. **왕복이 나간 순간** 예산이 소진된다 — 성공했든 실패했든.
                #    "실패했으니 한 번 더" 는 상한을 2로 만드는 것과 같다.
                rewrote = true
                fx === nothing && return _reject_malformed(why)
                println("[minted] rewrite: 되먹임 1회 — 원래 사유=", why)
                # 🔴 `sl` 을 갱신한다: 아래 집행부가 `calls`/`params` 를 여기서 읽는다.
                #    안 갱신하면 새 body 를 등록해 놓고 **낡은 인자**로 부른다.
                #    이 대입이 안전한 것은 `_rewrite_once` 가 왕복 **전에**
                #    `_sl_is_rewritable` 로 판정했기 때문이다(그 술어가 근거를 소유한다) —
                #    `nothing` 이 아닌 값을 돌려줬다는 것 자체가 그 판정을 통과했다는 뜻이다.
                # 🔴 **D4 (Wave D, Task 9 리뷰 I3·I4).** 되먹임 payload 도 **본 경로와 같은
                #    순서·같은 사유 이름**으로 검사한다. 두 가지가 걸려 있다:
                #    (a) `surface` — 아래 `String(something(fx.surface, "unknown"))` 은 가드가
                #        없으면 비-문자열에서 **던진다**(실측: `surface: 7` →
                #        `MethodError: no method matching String(::Int64)`). 바깥 `catch` 가
                #        받으므로 예외가 탈출하지는 않지만 대가가 셋이다: 헌장의 "예외가 아니라
                #        거절" 이 깨지고 · `registered`/`impl_rejected_why` 가 둘 다 `nothing`
                #        ("못 쟀다")으로 붕괴하는데 **첫 등록 거절 사유는 이미 측정돼 있었고** ·
                #        세계를 확실히 안 건드렸는데 `world_maybe_dirty=true` 가 된다.
                #    (b) `params` — 사전 가드가 없으면 `register_minted_primitive!` 안쪽의
                #        `pairs("…")` 가 `reject:params_keys_not_strings:Int64` 를 내서, **같은
                #        결함이 시도 1 과 시도 2 에서 다른 사유 이름을 갖는다**(본 경로는
                #        `reject:params_not_an_object:String`). D17 이 재려는 것이 "되먹임이
                #        무엇을 고쳤나" 의 **사유 히스토그램**이므로 어휘가 갈리면 그 표가 거짓이 된다.
                # 🔴 **갱신보다 먼저다.** 아래 다섯 대입 뒤에 두면 못 쓸 값이 `sl` 에 남아,
                #    이 판을 나중에 읽는 소비자에게 거짓말을 한다(리뷰 우려 (2)-4 와 같은 결).
                # ⚠️ 사유는 **두 번째 시도의 것**이다 — 첫 사유로 덮으면 되먹임이 무엇을 못
                #    고쳤는지가 기록에서 사라진다(아래 `why2` 와 같은 규약).
                # ⚠️ 오늘 이 둘이 도달 불가한 이유는 파이썬 한 겹뿐이다
                #    (`RewriteToolImpl.surface: str` · `params_object` 정규화). 본 경로가 같은
                #    자리를 굳이 막고 있는데 이쪽만 안 막는 것은 비대칭이다.
                # 🔴 D17b (2026-09-05). 검사·설치·등록 열두 줄은 `_install_rewrite!` **한
                #    벌**로 옮겼다 — 되먹임 자리가 둘이 됐고(등록 거절 · 집행 예외), 두 벌을
                #    두면 검사 순서와 사유 이름이 갈린다. 근거·D1·D4 의 정본은 그 함수의
                #    docstring 이 소유한다. 동작은 바이트 동일하다: 같은 순서로 검사하고,
                #    같은 사유 문자열을 내며, 두 번째 거절은 **그 사유**를 나른다(첫 사유로
                #    덮으면 되먹임이 무엇을 못 고쳤는지가 기록에서 사라진다).
                # ⚠️ `allow_redefine` 은 **여기서 안 넘긴다.** 이 갈래는 첫 등록이 **실패한**
                #    판이라 이름이 `_MINTED_EVER` 에 아예 안 들어갔다 — 재정의를 허용할
                #    이유가 없고, 허용하면 그만큼 D6 신호를 덮을 여지가 생긴다.
                local why2 = _install_rewrite!(sl, fx)
                why2 !== nothing && return _reject_malformed(why2)
            end
            registered = true
            # 🔴 **D5 (Wave D). L3 을 여기서 읽는다 — 등록이 실제로 성공한 직후.**
            #    이름은 `_synth_lane_field(sl, "impl_name")` 에서 읽는다: 되먹임이 성공한
            #    판에서는 바로 위에서 `fx.impl_name` 으로 **갱신돼 있고**, 그 이름이 실제로
            #    등록된 이름이다(D1 이 `body_names` 를 같은 값으로 맞춘 자리와 같은 근거).
            #    `nm` 을 쓰면 되먹임 판에서 **등록된 적 없는 옛 이름**의 L3 을 읽는다.
            interface_calls = _interface_calls_of(
                something(_synth_lane_field(sl, "impl_name"), nm))
        else
            registered = false   # 코드가 없다 — 등록을 시도하지 않았다(확정, 못 잰 게 아니다)
        end

        # ---- 재풀이 센티넬을 먼저 심는다 (C6) ----------------------------------------------
        local _sent = Dict{Tuple{Int,Int},Float64}()   # 키 타입은 LAST_EDGE_COSTS 의 실제 타입
        CB.LAST_EDGE_COSTS[] = _sent

        # ---- D18: 세계 지문을 **전후**로 찍는다 --------------------------------------------
        # 🔴 `_pre` 는 `CB.enact_minted!` **직전**이어야 한다 — 등록·타입검사는 세계를 안
        #    건드리지만 body 는 건드린다. 사후 지문은 호출이 돌아온 **직후**다.
        # ⚠️ m6(2026-09-03 리뷰 정정): 여기 있던 "아래 println 들은 세계를 **안 읽고** 안
        #    바꾼다" 는 틀렸다 — 아래 `ran_milp` 줄은 `env.cache.closed_set` 을 읽는다.
        #    참인 것은 "안 **바꾼다**" 이고, 읽기가 무해한 이유는 사후 지문이 그보다
        #    **먼저**이기 때문이다.
        # 🔴 F4 — 이 차분이 재는 것은 body 가 아니라 **집행 봉투**다. `_issue_resume!` 와
        #    `_resolve_if_needed!` 는 `CB.enact_minted!` **안**에서 돌므로
        #    (`src/respec/minted_tool.jl`), `surface ∈ RESOLVE_SURFACES`(`sched`·`milp`)인
        #    판에서는 하네스의 공통 MILP 재풀이가 한 편집이 사후 지문에 들어온다. 그리고
        #    `resolve_assignments!` 의 `n_reassigned` 과 아래 `n_binding_changed` 는 **같은
        #    `assignment_binding`** 에서 나오는 두 수다. 그 둘을 가르는 값은 이미 같은 튜플
        #    안에 있다 — `r.resolve` — 그래서 아래 로그가 `_delta_scope` 로 그 판독을 명시한다.
        #    집행은 **안 바꾼다**(재구조화는 이 판독을 얻는 데 필요하지 않다).
        local _pre = _world_digest(env)
        # 🔴 Task 2 (2026-09-04). `probe` 는 **계측 하나**다 — 집행 경로는 안 바뀐다.
        #    `CB.enact_minted!` 가 body 루프 직후(캐시 재개 **앞**)와 던진 경로(재개·재풀이
        #    **앞**)에서 이것을 한 번 부르고, 그 값이 `r.body_probe` 로 돌아온다. 그래서
        #    아래 두 차분이 **다른 것**을 잰다: `world_delta` 는 집행 봉투 전체(F4 가 적은
        #    그대로), `world_delta_body` 는 하네스가 손대기 전의 body 단독이다.
        local r = CB.enact_minted!(env, truth, sl; probe = () -> _world_digest(env))
        world_delta = _world_delta(_pre, _world_digest(env))
        # 🔴 **기존 `world_delta` 는 그대로 둔다 — 지우지 않는다.** 두 값은 서로의 대조군이다:
        #    봉투가 0 이 아닌데 body 가 0 이면 그 편집은 하네스의 재풀이가 한 것이다.
        world_delta_body = _world_delta(_pre, r.body_probe)

        # ---- D17b: 집행이 **던진** 판도 되먹인다 (2026-09-05) -----------------------------
        # 🔴 **자리의 근거.** 재시도는 `enact_minted!`(`src/respec/minted_tool.jl`)의 단계
        #    루프가 아니라 **여기**, 하네스 봉투에 있다. 넷:
        #    (1) 고친 body 는 집행 전에 **재등록**돼야 하는데(`Core.eval` 로 정의가 생긴다)
        #        등록은 하네스의 일이다 — `enact_minted!` 은 이름으로 표를 조회할 뿐 등록을
        #        모른다. 루프 안에서 재시도하려면 그 함수가 등록을 배워야 한다.
        #    (2) `_rewrite_once` 의 재료(`DSPY_URL`·`HTTP`·`JSON3`)는 `tools/monitor/policy.jl`
        #        의 것이다. 패키지 라이브러리가 하네스의 HTTP 계층에 의존하게 만드는 것은
        #        의존 방향을 뒤집는 일이다.
        #    (3) 더러운-세계 판정의 재료(`world_delta_body`·`r.steps`)는 `enact_minted!` 이
        #        **돌아온 뒤에만** 손에 들어온다.
        #    (4) 루프 안에서 재시도하면 두 body 의 걸음이 **한 `steps` 목록으로 융합돼**,
        #        사다리가 재시도판과 첫-시도 성공판을 구별할 수 없게 된다 — 이 태스크의 요점이
        #        정확히 그 구별이다.
        # 🔴 **상한은 1 이고, 루프가 아니라 구조다**(D17 과 같은 규약). 이 블록에는 반복이
        #    없다: 두 번째 집행 결과는 그대로 기록되고 다시 되먹이지 않는다. 유료 호출이
        #    무한히 새는 자리를 만들지 않는다.
        # 🔴 **트리거는 둘이고 배타다** (2026-09-05, D17c). `if`/`elseif` 인 것이 상한 1 을
        #    지키는 **구조**다: 한 판에서 왕복은 많아야 하나이고, 두 번째 집행의 결과는
        #    (그것이 또 무동작이어도) 그대로 기록되고 다시 되먹여지지 않는다.
        #    · 던졌다 → `_retry_gate` (D17b). 사유는 예외 메시지 자신.
        #    · 안 던졌는데 **잰 무동작**이다 → `_noop_gate` (D17c). 사유는 관측 문장.
        #      유료 런 8 이 정확히 여기서 죽었다: 지어낸 zone 키를 좌표로 **만들어** 놓고
        #      원시의 반환 status 를 올바르게 검사한 뒤 `:failure` 를 돌려줬다 — 예외가
        #      없으니 D17b 의 채널은 한 번도 안 발화했다.
        local _throw_why = _enact_throw_reason(r)
        local _noop_why::Union{Nothing,String} = nothing
        if _throw_why !== nothing
            enact_retry = _retry_gate(r, world_delta_body)
            if enact_retry === :ok && rewrote
                # 🔴 게이트는 열렸는데 **예산이 없다**. `n/a`(사건이 없었다)로도,
                #    `refused_world_*`(세계가 더러울 수 있다)로도 적으면 거짓이다.
                enact_retry = :refused_budget_spent
                println("[minted] enact_retry: 거부 — refused_budget_spent ",
                        "(이 런의 되먹임 왕복은 등록 거절에서 이미 썼다) 사유=", _throw_why)
            elseif enact_retry === :ok
                local rr = _rewrite_retry!(env, truth, sl, r, _pre, _throw_why, nm,
                                           _RETRY_SYMS_THREW)
                enact_retry = rr.retry
                rr.impl_rejected_why !== nothing && (impl_rejected_why = rr.impl_rejected_why)
                if rr.reenacted
                    r = rr.r; world_delta = rr.world_delta
                    world_delta_body = rr.world_delta_body
                    interface_calls  = rr.interface_calls
                end
            else
                println("[minted] enact_retry: 거부 — ", enact_retry,
                        " (세계가 더러울 수 있다: 되돌릴 방법이 없다) 사유=", _throw_why)
            end
        else
            local _ng = _noop_gate(r, world_delta_body)
            if _ng === :ok && rewrote
                # 🔴 위와 **같은 예산**이다 — 두 트리거가 각각 하나씩 쓰는 것이 아니다.
                enact_retry = :refused_budget_spent
                println("[minted] enact_retry: 거부 — refused_budget_spent ",
                        "(이 런의 되먹임 왕복은 등록 거절에서 이미 썼다)")
            elseif _ng === :ok
                # 🔴 사유 문자열은 **여기서 짓지 않는다** — `_noop_feedback_reason` 이 그
                #    문장과 그 문장이 무엇을 주장하는지를 통째로 소유한다(관측만, 처방 없음).
                _noop_why = _noop_feedback_reason(r, world_delta_body)
                local rn = _rewrite_retry!(env, truth, sl, r, _pre, _noop_why, nm,
                                           _RETRY_SYMS_NOOP)
                enact_retry = rn.retry
                rn.impl_rejected_why !== nothing && (impl_rejected_why = rn.impl_rejected_why)
                if rn.reenacted
                    r = rn.r; world_delta = rn.world_delta
                    world_delta_body = rn.world_delta_body
                    interface_calls  = rn.interface_calls
                end
            elseif _ng === :noop_refused_unmeasured
                # 🔴 **못 잰 것을 안 움직였다고 말하지 않는다.** 이 판은 세어지기만 한다.
                #    `n/a`(트리거가 없었다)와 **다른 값**이어야 유료 런의 "왜 되먹임이 안
                #    갔나" 히스토그램이 참이 된다.
                enact_retry = _ng
                println("[minted] enact_retry: 거부 — ", _ng,
                        " (body 차분을 못 쟀다: 안 움직였다고 말할 근거가 없다)")
            end
            # `:none` 은 트리거 자체가 없다 = `enact_retry` 를 안 건드린다(= `n/a`).
            # 🔴 세계를 **움직인** body 가 정확히 여기로 온다 — 음성 대조의 자리다.
        end
        # 🔴 **네** 연언지다. `resume === :failed` 를 빼면 "세계는 고쳤는데 프론티어가 낡았다" 가
        #    `handled=true` 로 폴백을 삼켜, 이 파일의 docstring 이 막겠다고 적은 바로 그
        #    조용한 미복구가 된다(2026-08-30 최종 리뷰).
        # 🔴 2026-09-02 (판정 1) 넷째: 재풀이가 **실패**한 판도 같은 사고다. body 가 배정
        #    간선을 떼고 재풀이가 `:infeasible`/`:commit_failed`/`:threw` 로 끝나면 아무도
        #    재배정하지 않은 세계가 남는데, `handled=true` 면 그 위에서 기본 복구 사슬까지
        #    건너뛰고 그 OOD 사건은 **이미 소비돼** 다시 오지 않는다.
        #    `resume` 과 **같은 모양**으로 막는다: 다섯 상태 중 실패 셋만 막고 `:resolved` 와
        #    `:none`(재풀이를 부를 자리에 도달 못 한 판정/거절 행)은 통과시킨다 — 게이트는
        #    넓어지기만 해야 한다.
        #    🔴 식 자체는 여기 없다 — 정본은 위 `minted_handled` 하나다(손베낀 복사본이 이미
        #    한 번 갈렸다, 2026-09-02 T0).
        local handled = minted_handled(r)

        # 🔴 F20(2026-09-03 최종 리뷰). `get(sl, ...)` 을 직접 안 부른다 — `_synth_lane_field`
        #    를 통해서만 읽는다. 생산 경로의 `sl` 은 오늘 `Dict{String,Any}` 뿐이라
        #    무해했지만, `_synth_lane_field` 자신의 docstring 이 적듯 게이트·루프백에서는
        #    `sl` 이 Symbol-키(`JSON3.Object`/`NamedTuple`)로도 온다 — 그 모양에서
        #    `get(::NamedTuple, ::String, d)` 는 메서드가 없어 **던진다**. 이 지점은
        #    `CB.enact_minted!` 가 **이미 돌아온 뒤**라서, 그 던지기가 바깥 catch 로
        #    올라가면 세계가 이미 편집됐을 수 있는데 그 catch 는 `world_maybe_dirty=false`
        #    를 하드코딩한다 — 안 지킬 수 있는 주장. `_synth_lane_field` 로 돌려서 이
        #    던지는 자리 자체를 없앤다(그 함수는 두 키 모양을 다 시도하고 실패해도 예외
        #    대신 `nothing` 을 낸다).
        _rec_line("[minted] lane=present tool=", something(_synth_lane_field(sl, "tool_name"), "?"),
                " verdict=", r.verdict, " applied=", r.applied, " partial=", r.partial,
                " world_maybe_dirty=", r.world_maybe_dirty, " handled=", handled,
                " undo=", r.undo, " resume=", r.resume, " resolve=", r.resolve,
                # 🔴 Step 5 (B1, 2026-09-03). 인자를 **어디서** 묶었는지. 이것이 없으면 유료
                #    런의 로그로 "calls 로 값이 도착해 굴렀다" 와 "calls 가 없어 옛 params
                #    경로로 떨어져 인자 없이 굴렀다" 가 같은 관측이 된다.
                #    🔴 `nothing` 은 `n/a` 로 찍는다 — "0" 도 "params" 도 아니고 **도달 못 했다**.
                " args_from=", something(r.args_from, "n/a"),
                " n_calls=", something(r.n_calls, "n/a"),
                # 🔴 S5(2026-09-04). 인자 채널이 **지어낸 로봇 정체**를 막았는가. 다섯째 유료
                #    런은 `affected_robot="R1"` 이 body 의 세계 유도 폴백을 눌러 죽였다.
                #    막았다는 사실이 이 줄에 없으면 다음 런의 채점은 "모델이 인자를 안 줬다"
                #    와 "모델이 지어냈고 채널이 막았다" 를 **같은 관측**으로 본다.
                #    🔴 삼상 그대로 찍는다: `n/a`(바인더 미도달) · `none`(묶었는데 버릴 것
                #    없음) · 이름 목록. 값 자체는 `[minted] ⚠️ dropped fabricated identifier`
                #    줄이 따로 낸다(이 줄은 공백 없는 key=value 로 파싱되므로).
                " dropped_args=", r.dropped_args === nothing ? "n/a" :
                    isempty(r.dropped_args) ? "none" :
                    join([string(d.primitive, ".", d.arg) for d in r.dropped_args], ","),
                # 🔴 2026-09-03 라이브 실측이 계기. 합성이 **발화했는데** `empty body` 로
                #    거절된 판에서 agent-3 이 무엇을 없다고 했는지가 **어디에도 안 남았다** —
                #    스트림 jsonl 에 합성 필드가 없고 서비스도 기록을 파일로 안 쓴다. 값은
                #    이미 `SYNTH_LANE_KEYS` 로 도착해 있었고 관측면만 없었다.
                # 🔴 D17b (2026-09-05). **재시도판을 첫-시도 성공판과 가른다.** 이 줄의
                #    나머지 필드(`verdict`·`applied`·`steps`…)는 되먹임이 성공한 판에서
                #    **두 번째 시도**를 적는다 — 이 한 칸이 없으면 사다리는 그것을 깨끗한
                #    첫 시도로 채점한다. 상태의 뜻은 `_retry_str` 이 소유한다.
                " enact_retry=", _retry_str(enact_retry),
                " n_body_names=", length(something(_synth_lane_field(sl, "body_names"), [])),
                # 🔴 Task 9(설계 §8). 등록 결과 — "모델이 코드를 안 냈다" 와 "냈는데 규약
                #    위반으로 거절됐다" 를 가른다. 여기까지 왔다는 것은 등록을 시도했다면
                #    통과했다는 뜻이므로 `impl_rejected_why` 는 언제나 nothing 이다.
                " registered=", registered, " impl_rejected_why=", something(impl_rejected_why, "n/a"),
                # 🔴 2026-09-04 (Task 1). `detail` 을 **안 버린다** — `:threw` 판의 예외
                #    메시지가 여기 말고는 어디에도 안 남는다. 접기·자르기의 진실원은
                #    `_step_render` 하나다.
                " steps=[", join([_step_render(s) for s in r.steps], " "), "]",
                " reason=", r.reason)

        local ran_milp = !(CB.LAST_EDGE_COSTS[] === _sent)   # 센티넬이 그대로면 재풀이 없음
        println("[minted] ran_milp=", ran_milp, " n_candidate_edges=",
                ran_milp ? string(length(CB.LAST_EDGE_COSTS[])) : "n/a(no re-solve)",
                # 🔴 task-oracle3(2026-09-05). `forbid_heavy_cargo!` 의 `:banned` 는 **집행
                #    증거가 아니다** — 실제로 눌린 행 수는 formulate 안에서만 알 수 있고, 그
                #    값이 없으면 "금지가 0 행이었다" 와 "금지가 걸렸는데 argmin 이 안 움직였다"
                #    가 같은 관측이 된다(task-oracle2 는 그것을 간접 추론해야 했다).
                #    재풀이가 없었으면 이 숫자는 이 결정의 것이 아니므로 안 찍는다.
                " cargo_ban_rows=",
                ran_milp ? string(CB.LAST_CARGO_BAN_ROWS[]) : "n/a(no re-solve)",
                " closed=", (try string(length(env.cache.closed_set)) catch; "n/a" end))
        # 🔴 `@info` 가 아니라 `println` 이다 — `run_demo.jl` 이 `global_logger(…, Logging.Warn)`
        #    를 심어 `@info` 는 프로세스 전역에서 버려진다(이 파일의 다른 `[minted]` 줄과 같은
        #    이유). 🔴 `n/a(not measured)` 와 `closed=0` 은 **다른 관측**이다.
        # 🔴 `delta_scope` 는 F4 의 판독이다: `body_only` 인 판의 차분만 **body 단독**이고,
        #    `body+harness_resolve` 인 판은 하네스의 공통 MILP 재풀이까지 포함한 봉투 전체의
        #    차분이다. 이 값을 안 적으면 유료 런의 로그를 읽는 사람이 그 둘을 못 가른다.
        # 🔴 Task 2: 줄이 **두 쌍**을 찍는다. `delta_scope` 는 `r.resolve` 에서 유도한
        #    봉투의 판독이고, `body_scope` 는 probe 자리에서 온 **다른 근거**의 이름이다
        #    (`BODY_ONLY_PROBED` 가 그 구별을 소유한다). `r.body_probe` 가 없으면
        #    `_world_delta_str` 이 "못 쟀다" 를 찍는다 — 리터럴을 손으로 안 적는다(m3).
        println("[minted] world_delta=", _world_delta_str(world_delta),
                " delta_scope=", _delta_scope(r.resolve),
                " world_delta_body=", _world_delta_str(world_delta_body),
                # 🔴 못 잰 판에 범위 이름을 붙이지 않는다 — `n/a` 옆의 `body_only(probed)` 는
                #    "재지도 않은 것의 범위" 라는 형용모순이고, m3 이 고친 것과 같은 거짓말이다.
                #    `unknown` 은 `_delta_scope` 가 이미 쓰는 "모른다" 다.
                " body_scope=", world_delta_body === nothing ? "unknown" : BODY_ONLY_PROBED)

        handled || println("[minted] NOT handled → 기본 복구 사슬로 폴백한다 ",
                           "(이 폴백은 조용하지 않다 — verdict=", r.verdict,
                           " applied=", r.applied, " partial=", r.partial,
                           " world_maybe_dirty=", r.world_maybe_dirty,
                           " resume=", r.resume, " 가 이유다)")

        return (handled = handled, verdict = r.verdict, reason = r.reason,
                applied = r.applied, partial = r.partial,
                world_maybe_dirty = r.world_maybe_dirty, steps = r.steps, undo = r.undo,
                resume = r.resume, resolve = r.resolve,
                args_from = r.args_from, n_calls = r.n_calls,
                dropped_args = r.dropped_args,
                registered = registered, impl_rejected_why = impl_rejected_why,
                enact_retry = enact_retry,
                world_delta = world_delta,
                world_delta_body = world_delta_body,
                interface_calls = interface_calls)
    catch e
        # 🔴 여기서 새면 렌더가 선다(위 docstring). 크게 찍고 정상 반환한다.
        # 🔴 F2(2026-09-03 최종 리뷰, R7). `registered`·`impl_rejected_why` 는 **손으로
        #    다시 안 적는다** — 함수 맨 위에서 `try` 밖에 선언한 그 결속을 그대로 읽는다.
        #    예외가 등록 이전에 났으면 둘 다 초기값 `nothing`("몰라서 못 쟀다")이고,
        #    등록이 이미 끝난 뒤(성공/거절 불문) 다른 곳에서 던졌으면 그 결정된 값을
        #    그대로 정직하게 나른다 — 리터럴 `false` 를 적으면 "등록이 성공한 뒤
        #    `CB.enact_minted!` 가 던졌다" 는 판을 "등록이 안 됐다" 는 거짓으로 덮는다.
        local msg = first(split(sprint(showerror, e), "\n"))
        println("[minted] FAILED (집행부가 던졌다 — 렌더는 계속한다): ", msg)
        _rec_line("[minted] lane=unknown tool=n/a verdict=reject applied=n/a",
                # 🔴 B4: `n/a` 가 아니다. 이 경로의 `world_maybe_dirty` 는 확정된 `true` 이고
                #    (아래 반환 참조), 로그가 반환과 다른 말을 하면 라이브 판독이 갈린다.
                " partial=false world_maybe_dirty=true handled=false undo=none resume=none",
                " args_from=n/a n_calls=n/a dropped_args=n/a",
                # 🔴 D17b: 예외가 **두 번째 집행 도중**에 났으면 이 값이 `retried` 다.
                #    리터럴 `n/a` 를 적으면 그 판이 "시도 안 했다" 로 기록된다.
                " enact_retry=", _retry_str(enact_retry),
                " steps=[]",
                " registered=", something(registered, "n/a"),
                " impl_rejected_why=", something(impl_rejected_why, "n/a"),
                # 🔴 D18(B4 와 같은 이유 — 로그와 반환이 다른 말을 하면 라이브 판독이
                #    갈린다). 이 경로의 `world_delta` 는 `n/a` 로 **고정이 아니다**: 예외가
                #    차분 계산 뒤에 났으면 실제로 잰 값이 여기 실린다.
                # 🔴 m4(2026-09-03 리뷰): 성공 줄과 **같은 포맷터**를 쓴다. 예전엔 이
                #    줄에만 하한 각주가 없어서, 로그를 정규식으로 읽는 소비자가 같은 사실의
                #    두 모양을 따로 다뤄야 했다.
                " world_delta=", _world_delta_str(world_delta),
                # 🔴 이 경로에는 `r` 이 없다 — 재풀이가 돌았는지조차 모른다. `unknown` 이다.
                " delta_scope=", _delta_scope(nothing),
                " ran_milp=n/a(threw) reason=enact_minted_decision! threw: ", msg)
        println("[minted] NOT handled → 기본 복구 사슬로 폴백한다 ",
                "(이 폴백은 조용하지 않다 — 위 FAILED 가 이유다)")
        # 🔴 F8(2026-09-03 최종 리뷰). `applied = nothing` 이지 `false` 가 아니다 — 이
        #    자리는 등록 이전에 던졌을 수도, `CB.enact_minted!` 안에서 던졌을 수도 있어
        #    "원시를 하나도 안 불렀다" 조차 확신할 수 없다(F2 문단과 같은 이유로
        #    `registered`/`impl_rejected_why` 는 정직하게 나르지만, `applied` 는 이 함수가
        #    직접 계산한 적이 없으므로 언제나 못 쟀다).
        # 🔴 **`world_maybe_dirty = true`** (2026-09-03 최종 리뷰 B4 — F20 의 `nothing` 을
        #    되돌린다). 이 필드만은 `applied`/`registered` 와 **다른 종류의 질문**이다:
        #    가능성 술어(`touched || partial`, "세계가 더러울 **수** 있는가")이지 관측이
        #    아니다. 그러므로 "세계가 더러울 수 있는지를 못 쟀다" 는 **"더러울 수 있다"로
        #    무너진다** — `nothing` 이 나르는 구별이 없고 타입만 하나 넓어진다.
        #    F20 이 고친 진짜 결함은 리터럴 `false` 였다: 이 catch 는 `CB.enact_minted!` 가
        #    돌아온 **뒤**에도 도달할 수 있어서(그때는 세계가 이미 편집돼 있다) `false` 는
        #    이 함수가 증명 못 하는 주장이었다. 보수적으로 옳은 값은 `true` 다.
        #    🔴 그리고 소비자가 `Bool` 을 요구한다 — `minted_handled` 가 이 값을 `&&` 의
        #    항으로 읽으므로 `nothing` 이 가면 `TypeError` 로 죽는다(실측:
        #    `minted_handled((verdict=:admit, world_maybe_dirty=nothing, …))` 가 던진다).
        #    오늘 안전한 것은 이 경로가 `verdict=:reject` 를 하드코딩하고
        #    `ENACTED_VERDICTS === (:admit,)` 라 첫 연언지가 단락 평가로 먼저 죽기 때문뿐이고,
        #    그 튜플은 이번 달에만 두 번 바뀌었다. `src/respec/minted_tool.jl` 의
        #    `_step_touched_world` 와 `test/minted_registration.jl` 이 **이미 같은 근거로**
        #    이 필드의 `nothing` 을 문서에서 거절한다 — 이 자리만 예외로 둘 이유가 없었다.
        return (handled = false, verdict = :reject,
                reason = "enact_minted_decision! threw: " * msg,
                applied = nothing, partial = false, world_maybe_dirty = true,
                steps = NamedTuple[], undo = :none, resume = :none, resolve = :none,
                args_from = nothing, n_calls = nothing, dropped_args = nothing,
                registered = registered, impl_rejected_why = impl_rejected_why,
                enact_retry = enact_retry,
                world_delta = world_delta,
                world_delta_body = world_delta_body,
                interface_calls = interface_calls)
    end
end
