# =============================================================================
# 두 번째 엔진(`tools/monitor/render_demo.jl`)에도 인과를 잇고, 결정 행 네 키에
# **소비자 게이트**를 건다. (2026-08-29, Plan B / T2b)
#
# 이 파일이 재는 명제 셋
# ----------------------
# (A) `macro_to_proposal` 이 `agent` 를 받는다 — 주면 그것을, 안 주면 예전 그대로 `truth.robot`.
#     기본값이 `nothing` 이므로 **기존 호출자의 동작은 한 줄도 안 바뀐다**(그것도 여기서 잰다).
#
# (B) 🔴 `render_demo.jl` 의 **실제 호출부**가 `enact_target` 을 거쳐 그 agent 를 제안에 싣는다.
#     복제본을 재지 않는다 — 이 레포는 이미 그 사고를 밟았다(`tools/test_policy_escalation.jl`
#     의 `unavail()` 이 `policy_entry` 의 손으로 쓴 복제본이었고, 생산 코드의 한 줄을 지워도
#     9개 검사가 전부 초록이었다). `render_demo.jl` 은 최상위에서 데모를 통째로 돌리는
#     **스크립트**라 include 가 불가능하다. 그래서 `policy_producer` 의 **원문 텍스트를 그대로
#     뽑아 eval 하고 실행한다** — 진짜 `enact_target` · 진짜 `macro_to_proposal` 을 태우고
#     나머지(decide_all·record_decision! 등)만 스텁으로 채운다.
#     ⇒ 호출부에서 `agent = _tgt.agent` 를 지우면 (B-1) 이 빨개진다.
#     ⇒ `enact_target` 의 R16(강제/이탈 팔 거절)을 지우면 (B-2) 가 빨개진다.
#
# (C) 🔴 **결정 행 네 키가 실제로 결정 행에 실리는지** — 실행으로 잰다.
#     `tool_agent` · `enact_agent` · `enact_agent_source` · `verify` 는 T2/T3 이 심은 뒤로
#     한동안 **쓰는 곳 하나, 읽는 곳 0** 이었다("도장만 찍고 소비처를 안 만든다" —
#     `router_axis` 사고와 같은 자리). 2026-08-29 T3 수정 라운드가 그 자리를 재배선했다:
#     이제 네 키는 `enact.jl` 의 `enact_decision!` 이 `row` 로 내고 `run_demo.jl` 이
#     `merge!(this_decision, _e.row)` 로 결정 행에 얹는다. `row` **본체**는
#     `test/enact_uses_llm_agent.jl` (9) 가 지키고, 그 호출부의 **존재**는 (10) 이
#     소스 텍스트로 지킨다.
#     🔴 **아무도 안 재는 것이 하나 남는다: 그 두 조각의 합류가 실제로 성립하는가.**
#     `this_decision` 이 `Dict{String,String}` 으로 좁혀지거나, `merge!` 가 `push!` 앞으로
#     가거나, 중간에 화이트리스트 필터가 끼면 (9)·(10) 은 둘 다 초록인데 결정 행에는 네
#     키가 없다. 그래서 이 파일은 `run_demo.jl` 의 그 구간 **원문을 그대로 실행한다**
#     (`enact_decision!` 만 센티넬 row 를 내는 스텁으로 갈아 끼운다). 네 키가 그 row 에서
#     결정 행까지 살아 도착하는지를 **값으로** 단언한다.
#
# 🔴 서비스는 **아예 안 부른다** — `127.0.0.1:8077` 로 나가는 요청 0건(`/decide` 는 사용자
# 계정의 유료 OpenAI 호출이다). `decide_all` 은 (B) 에서 스텁이고, (A)·(C) 는 안 부른다.
#
# ⚠️ `render_demo.jl` 에는 `run_demo.jl` 의 `this_decision` 같은 **결정 행 화이트리스트가
# 없다**(실측: `_DECISIONS` 0건, 기록 경로는 `record_decision!` → 모니터 respec 스트림 하나).
# 그래서 이 파일은 네 키를 `run_demo.jl` 쪽에서만 잰다 — 없는 구조를 있는 척 만들지 않는다.
#
# 🔴 **원문 추출은 못 찾으면 `error()` 다.** 조용히 빈 문자열을 돌려주면 "블록이 없다" 가
# "검사할 것이 없다" 로 읽혀 초록이 된다 — 이 파일이 막으려는 바로 그 실패 양식이다.
#
# 실행:  julia +lts --project=. test/render_lane_uses_llm_agent.jl
# =============================================================================
module RenderLaneUsesLLMAgent

using Test
using ConstructionBots
const CB = ConstructionBots
import Random
# policy.jl 은 스크립트라 자기 의존성을 안 들고 온다(CLAUDE.md Gotchas). `_agent_pending` 이
# `ood_features` 경유로 Graphs 를 쓰고, 파일 머리가 HTTP/JSON3 를 쓴다.
# ⚠️ stdlib 이라도 `Project.toml` 의 `[deps]` 에 있는 것만 `Pkg.test()` 샌드박스에서 풀린다 —
# Graphs · HTTP · JSON3 · Random 은 전부 들어 있다(실측). Logging 은 `Base.CoreLogging` 으로 닿는다.
import Graphs, HTTP, JSON3

const REPO = normpath(joinpath(@__DIR__, ".."))

# BatteryTruth / FaultTruth 는 런타임 include 계층에 산다.
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 생산 코드 둘. `enact.jl` 은 최상위 부작용이 없고(T2 커밋 1 의 요구조건), `policy.jl` 은
# `policy_macro_binding.jl` 이 이미 같은 방식으로 include 한다.
# 🔴 `policy.jl` 의 `const DSPY_URL` 은 include 시점에 한 번 ENV 에서 읽힌다. 이 파일은
# `decide_all` 을 **한 번도 안 부르므로** 그 값이 어디를 가리키든 요청이 나가지 않지만,
# 사고를 구조적으로 막기 위해 include 동안만 죽은 포트로 돌려놓는다.
const _PREV_DSPY_URL = get(ENV, "DSPY_URL", nothing)
ENV["DSPY_URL"] = "http://127.0.0.1:9/__t2b_never_called__"
try
    include(joinpath(REPO, "tools", "monitor", "policy.jl"))
finally
    _PREV_DSPY_URL === nothing ? delete!(ENV, "DSPY_URL") : (ENV["DSPY_URL"] = _PREV_DSPY_URL)
end
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

# -----------------------------------------------------------------------------------------
# 원문 추출기 — 스크립트라 include 할 수 없는 파일의 **한 블록**을 텍스트로 뽑는다.
# `stop` 줄을 포함할지(`inclusive`)는 호출부가 정한다: 함수 정의는 닫는 `end` 가 필요하고,
# Dict 리터럴은 뒤따르는 `push!` 줄을 빼야 한다.
# -----------------------------------------------------------------------------------------
function extract_block(path::AbstractString, start, stop; inclusive::Bool = false)
    lines = readlines(path)
    i = findfirst(l -> occursin(start, l), lines)
    i === nothing && error("extract_block: $(repr(start)) 를 $(path) 에서 못 찾았다")
    j = findnext(l -> occursin(stop, l), lines, i + 1)
    j === nothing && error("extract_block: $(repr(stop)) 를 $(path) 의 $(i) 줄 뒤에서 못 찾았다")
    return join(lines[i:(inclusive ? j : j - 1)], "\n")
end

const RUN_DEMO    = joinpath(REPO, "tools", "monitor", "run_demo.jl")
const RENDER_DEMO = joinpath(REPO, "tools", "monitor", "render_demo.jl")

# =========================================================================================
# 비싼 것은 env 하나뿐이다. `enact_target` 이 `resolve_agent_id`/`ground_tool_args` 를 부르고
# 그 둘은 `env.sched` 의 `RobotGo` 노드를 실제로 순회한다 — 가짜 env 로는 접지를 못 잰다.
# 시뮬레이션은 한 스텝도 안 돌린다(`return_env_before_sim = true` 시점에 스케줄은 완성돼 있다).
# 인자는 `test/enact_uses_llm_agent.jl` 의 SCENE-INCANTATION 정본과 같다.
# =========================================================================================
const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "render_lane_uses_llm_agent",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

const DESCS = CB.open_agent_descriptors(TENV)
const A = CB.resolve_agent_id(TENV, DESCS[1]["id"])     # truth 가 가리키는 로봇
const B = CB.resolve_agent_id(TENV, DESCS[2]["id"])     # LLM 이 tool 로 지목하는 로봇

# `decide_all` 이 만드는 것과 **같은 모양**의 tool 레인(8키, 값만 다름).
# 🔴 키 여덟은 항상 존재한다 — `haskey` 는 값이 실려 왔다는 증거가 아니다(T1 소비자 규칙 1).
# ⚠️ `tool_called` 는 **집행되는 팔에 대응하는 tool 이름**이어야 한다 — T3 의 출처 일치
# 검사(0b, `CB.MACRO_TO_TOOL`)가 그렇지 않은 호출의 인자를 수입하지 않는다. 이름을 손으로
# 적지 않고 그 표에서 유도한다(리터럴 복붙은 이 레포가 반복해 밟은 자리다).
_lane(agent, mac) = Dict{String,Any}("tool_called" => get(CB.MACRO_TO_TOOL, mac, nothing),
                                "tool_args" => Dict{String,Any}("agent" => agent),
                                "tool_calls_n" => 1, "tools_offered" => 1,
                                "expressible" => true, "native_fc" => true,
                                "tool_lane_error" => nothing, "macro_tool_agree" => nothing)

# -----------------------------------------------------------------------------------------
# (B) 준비 — render_demo.jl 의 원문 `policy_producer` 를 샌드박스에서 되살린다.
# -----------------------------------------------------------------------------------------
const PRODUCER_SRC = extract_block(RENDER_DEMO,
                                   "function policy_producer(env, event)", r"^end$";
                                   inclusive = true)

module _RenderSandbox
    using ConstructionBots
    const CB = ConstructionBots
    # 🔴 생산 함수 셋은 **진짜**를 쓴다. 나머지만 스텁이다.
    # (2026-08-29 T2c: `log_enact` 가 추가됐다 — 집행 대상 한 줄 기록을 두 producer 가
    #  **같은 함수**로 찍는다. 스텁으로 두면 이 샌드박스가 생산 코드와 다른 것을 태운다.)
    # (2026-08-30 T4: `enact_minted_decision!` 가 추가됐다 — `policy_producer` 가
    #  `macro_to_proposal` **앞**에서 합성 tool 을 집행한다. 이것도 **진짜**를 쓴다:
    #  스텁으로 두면 이 샌드박스가 생산 코드와 다른 것을 태우고, 특히 이 판의 결정 행에는
    #  `synth_lane` 필드가 아예 없으므로 그 조기 반환(=`handled=false`, 폴백이 조용하지
    #  않다)이 여기서 실제로 굴러야 (B) 가 옛 경로를 계속 잰다는 것이 참이 된다.)
    import ..enact_target, ..macro_to_proposal, ..log_enact, ..enact_minted_decision!
    # 🔴 (2026-09-04, Wave A W2 뒤처리) `record_world_delta!` 는 여기서 **스텁**이다.
    #    그 함수의 **내용**(직렬화 모양·삼상·안 던짐)은 `enact.jl::record_world_delta!` 의
    #    docstring 이 소유하고 `test/minted_end_to_end.jl` (14)(15) 와 W2 의 변이 M-C·M-C2
    #    가 잰다 — 여기 두 번째 판정을 적지 않는다. 이 파일이 재는 것은 오직
    #    **호출부가 그것을 부르는가** 하나이고, 그래서 스텁은 조용하지 않다: 받은 인자를
    #    그대로 쌓아 두고 (B-1) 이 그 자리를 값으로 단언한다. 호출이 사라지면 빨개진다.
    const WORLD_DELTA_CALLS = Any[]
    record_world_delta!(m) = (push!(WORLD_DELTA_CALLS, m); nothing)
    const NEXT = Ref{Any}(nothing)                 # 이 결정 하나를 흘려보낸다
    is_reform_alarm(::Any) = false
    truth_for_event(::Any) = (truth = NEXT[].truth, nl = NEXT[].nl)
    decide_all(env, truth; nl = "") = NEXT[].decision
    record_decision!(env, truth, decision, nl) = nothing
    const _REFORM_CT = Ref(0)
    const DEMO_REFORM_MAX = 3
    enact_reform!(env) = nothing
end

Core.eval(_RenderSandbox, Meta.parse(PRODUCER_SRC))

# -----------------------------------------------------------------------------------------
# 🔴 추출한 원문이 부르는 **평이한 이름 전부**가 이 샌드박스에서 풀리는가.
# 생산 코드에 이름이 하나 새로 들어오면 (B) 는 `UndefVarError` 로 **에러**가 나는데, 그
# 스택트레이스는 "이 시험이 생산 코드를 못 따라갔다" 인지 "생산 코드가 깨졌다" 인지 말해
# 주지 않는다 — 2026-09-04 에 W2 의 `record_world_delta!` 하나가 정확히 그렇게 났고
# (28 passed / 1 errored), 스위트 회귀 기준을 그 한 줄이 깨뜨렸다. 이 목록이 비어 있지
# 않으면 **어떤 이름인지**를 먼저 말한다. 스텁으로 덮을지 진짜를 import 할지는 그때의
# 결정이고, 여기서 자동으로 삼키지 않는다(그러면 이 파일의 요점이 사라진다).
# ⚠️ `:call` 의 평이한 심볼만 센다 — `CB.foo` 같은 한정 이름은 모듈이 이미 해결하고,
#    지역 이름은 이 블록에서 호출 위치에 안 나온다(실측: 아래 목록이 비었다).
# -----------------------------------------------------------------------------------------
function _called_names!(out::Set{Symbol}, ex)
    ex isa Expr || return out
    ex.head === :call && ex.args[1] isa Symbol && push!(out, ex.args[1])
    for a in ex.args; _called_names!(out, a); end
    return out
end
const UNRESOLVED_IN_SANDBOX =
    sort!(String[String(s) for s in _called_names!(Set{Symbol}(), Meta.parse(PRODUCER_SRC))
                 if !(isdefined(_RenderSandbox, s) || isdefined(Base, s) || isdefined(Core, s))])

"""
render_demo 의 **진짜** `policy_producer` 를 한 번 굴린다. `CB.battery_report()` 는 이 판에
함대가 없으면 던지고 생산 코드가 그것을 `@warn` 으로 잡는다(정상 경로) — 로그만 죽인다.
"""
function run_producer(truth, macro_name, lane, router)
    _RenderSandbox.NEXT[] = (truth = truth, nl = "obs",
        decision = (macro_name = macro_name, tool_lane = lane, router = router,
                    enacted = "dspy", rule_macro = macro_name,
                    policies = Dict("surrogate" => Dict("chosen" => macro_name),
                                    "dspy" => Dict("chosen" => macro_name)),
                    detail = "stub rationale"))
    return Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        _RenderSandbox.policy_producer(TENV, "stub event")
    end
end

# -----------------------------------------------------------------------------------------
# (C) 준비 — run_demo.jl 의 원문 결정 행 리터럴을 샌드박스에서 실행한다.
# -----------------------------------------------------------------------------------------
# 🔴 결정 행 조립 **전체**를 뽑는다 — 리터럴부터 `merge!` 까지. `merge!` 를 포함해야
# "row 가 결정 행까지 도착하는가" 를 잴 수 있다(리터럴만 뽑으면 T3 재배선 이후로는 네 키가
# 애초에 그 안에 없다).
# ⚠️ 중단 패턴은 **느슨하게** 잡는다(`merge!(this_decision`). 정확한 인자까지 못박으면 그
# 자리에 필터가 끼는 변이가 "블록을 못 찾았다" 에러로 죽어서, **어떤 단언이 잡았는지**를
# 못 보여준다. 느슨하게 잡으면 그 변이가 블록 **안에** 들어와 아래 값 단언이 잡는다.
const ROW_SRC = extract_block(RUN_DEMO, "local this_decision = Dict(",
                              "merge!(this_decision"; inclusive = true)

# 🔴 센티넬 — `enact_decision!` 이 낸 값이 그대로 도착해야 한다. 네 값이 전부 다르므로
# 키를 바꿔 실은 변이도 잡힌다.
const SENT_AGENT  = "RobotID(4242)"
const SENT_TOOLAG = "RobotID(31337)"
const SENT_SOURCE = "tool"
const SENT_VERIFY = "admit"

module _RowSandbox
    using ConstructionBots
    const CB = ConstructionBots
    import ..valid_macros, .._agent_pending
    import ..decision_reasoning, ..emitted_keys_of, ..macro_to_proposal
    import ..SENT_AGENT, ..SENT_TOOLAG, ..SENT_SOURCE, ..SENT_VERIFY
    # `_DECISIONS` 는 이 파일 밖(run_demo.jl 최상위)에 사는 전역이다. 스텁.
    const _DECISIONS = Any[]
    # 🔴 집행은 **안 한다** — 세계를 안 바꾼다(TENV 를 뒤의 검사가 계속 쓴다). 여기서 재는
    # 것은 "이 row 가 결정 행까지 도착하는가" 하나이고, row 의 **내용**은
    # `test/enact_uses_llm_agent.jl` (9) 가 진짜 `enact_decision!` 로 지킨다.
    enact_decision!(env, truth, decision) =
        (target = nothing, enacted = nothing,
         row = Dict{String,Any}("tool_agent" => SENT_TOOLAG,
                                "enact_agent" => SENT_AGENT,
                                "enact_agent_source" => SENT_SOURCE,
                                "verify" => SENT_VERIFY))
end

Core.eval(_RowSandbox, quote
    const env = (cache = (closed_set = Set{Int}(),), dt = 0.1)
    const truth = $(CB.FaultTruth(A, [0.0, 0.0, 0.0]))
    const tag = "FaultTruth"
    const mac = "Replace"
    const n_total = 10
    const nl = "obs"
    const decision = (enacted = "dspy", rule_macro = "Replace", llm_macro = "Replace",
                      agree = true, detail = "stub rationale", narrative = "n",
                      macro_name = "Replace", tool_lane = nothing,
                      router = Dict{String,Any}(), policies = Dict("dp" => Dict{String,Any}()))
end)

const ROW = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
    Core.eval(_RowSandbox, Meta.parse("let\n" * ROW_SRC * "\nthis_decision\nend"))
end

# =========================================================================================
@testset "render_demo 레인이 LLM 의 agent 를 집행한다 + 결정 행 소비자 게이트 (T2b)" begin

    @test A !== nothing && B !== nothing
    @test A != B          # 두 값이 같으면 (A-1)·(B-1) 이 아무것도 안 잰다

    @testset "(A) macro_to_proposal 이 agent 를 받는다" begin
        local truth = CB.FaultTruth(A, [0.0, 0.0, 0.0])

        # (A-1) agent 를 주면 그것이 대상이다. 🔴 `truth.robot` 은 A 인데 제안은 B 를 가리켜야
        # 한다 — 두 값이 같은 시험은 배선 전후로 똑같이 통과하므로 아무것도 재지 않는다.
        local p = macro_to_proposal(truth, "Replace"; agent = B)
        @test length(p.constraints) == 1
        @test p.constraints[1] isa CB.ReplaceAgent
        @test p.constraints[1].agent == B
        @test p.constraints[1].agent != truth.robot

        # (A-2) agent 를 안 주면 **기존 동작 그대로** — 기본값이 nothing 이라 기존 호출자 불변.
        local q = macro_to_proposal(truth, "Replace")
        @test q.constraints[1] isa CB.ReplaceAgent
        @test q.constraints[1].agent == truth.robot
        # 명시적 nothing 도 같다(호출부가 `agent = _tgt.agent` 로 nothing 을 넘기는 판).
        @test macro_to_proposal(truth, "Replace"; agent = nothing).constraints[1].agent == truth.robot

        # (A-3) SwapBattery 도 같다.
        local bt = CB.BatteryTruth(A, 0.1)
        local s = macro_to_proposal(bt, "SwapBattery"; agent = B)
        @test s.constraints[1] isa CB.SwapBattery
        @test s.constraints[1].agent == B
        @test macro_to_proposal(bt, "SwapBattery").constraints[1].agent == bt.robot

        # (A-4) 🔴 `hasproperty(truth, :robot)` 가드는 **대상 계산으로 옮겼을 뿐 사라지지
        # 않았다**. robot 필드가 없는 truth 에서 agent 없이 부르면 예전처럼 빈 제안이고
        # (던지지 않는다), agent 가 있으면 그 agent 로 집행 가능한 제안이 나온다.
        local noroot = (kind = :zone,)     # `robot` 필드 없음
        @test isempty(macro_to_proposal(noroot, "Replace").constraints)
        @test isempty(macro_to_proposal(noroot, "SwapBattery").constraints)
        local r = macro_to_proposal(noroot, "Replace"; agent = B)
        @test length(r.constraints) == 1 && r.constraints[1].agent == B
    end

    @testset "(B) render_demo.jl 의 원문 호출부가 그 agent 를 제안에 싣는다" begin
        @test occursin("macro_to_proposal", PRODUCER_SRC)   # 뽑은 블록이 진짜 그 호출부다
        @test occursin("enact_target", PRODUCER_SRC)

        # 🔴 (B-0) 샌드박스가 원문을 **전부** 태울 수 있다. 비어 있지 않으면 못 푼 이름을
        # 그대로 보여 준다 — 다음 세션이 스택트레이스를 역추적하지 않아도 된다.
        @test UNRESOLVED_IN_SANDBOX == String[]

        local truth = CB.FaultTruth(A, [0.0, 0.0, 0.0])

        # (B-1) 🔴 이 태스크의 핵심. tool 레인이 **B** 를 지목하고 `truth.robot` 은 **A** 다.
        # 호출부에서 `agent = _tgt.agent` 를 지우면 여기가 빨개진다(제안이 A 를 가리킨다).
        local n0 = length(_RenderSandbox.WORLD_DELTA_CALLS)
        local prop = run_producer(truth, "Replace", _lane(string(B), "Replace"), Dict{String,Any}())
        @test prop !== nothing
        # 🔴 W2 의 한 줄이 **실제로 불렸다**. `render_demo.jl` 에서 `record_world_delta!(_m)`
        # 를 지우면 여기가 빨개진다(스텁이 조용하지 않은 이유). 인자가 `enact_minted_decision!`
        # 이 낸 그 값인지도 함께 잰다 — 아무거나 넘기는 변이를 통과시키지 않는다.
        # ⚠️ **순서**(조기반환 앞/뒤)는 여기서 안 잰다 — 이 샌드박스는 항상 `handled=false`
        #    다. 그 축은 `test/minted_end_to_end.jl` (16) 이 잰다(W2 변이 M-C2).
        @test length(_RenderSandbox.WORLD_DELTA_CALLS) == n0 + 1
        @test hasproperty(_RenderSandbox.WORLD_DELTA_CALLS[end], :handled)
        @test _RenderSandbox.WORLD_DELTA_CALLS[end].handled === false
        @test length(prop.constraints) == 1
        @test prop.constraints[1] isa CB.ReplaceAgent
        @test prop.constraints[1].agent == B
        @test prop.constraints[1].agent != truth.robot
        # 🔴 `enact_recovery!`(같은 파일)가 집행하는 값이 정확히 이것이다 — 그 자리는
        # `first(c for c in prop.constraints if c isa CB.ReplaceAgent).agent` 로 hot_swap 한다.
        @test first(c for c in prop.constraints if c isa CB.ReplaceAgent).agent == B

        # (B-2) 🔴 R16 승계. 팔이 강제(`DEMO_FORCE_MACRO`)/이탈로 갈아 끼워진 판에서는 tool 의
        # agent 를 **안 쓴다**. 규칙을 복사하지 않고 `enact_target` 을 부르므로 두 엔진이 갈릴
        # 수 없다 — 그 승계가 실제로 성립하는지를 여기서 잰다.
        for router in (Dict{String,Any}("forced_from" => "NOOP"),
                       Dict{String,Any}("deviate_from" => "NOOP"),
                       Dict{String,Any}("deviated" => true))
            local forced = run_producer(truth, "Replace", _lane(string(B), "Replace"), router)
            @test forced.constraints[1].agent == A
            @test forced.constraints[1].agent != B
        end

        # (B-3) 접지 실패는 조용히 통과하지 않는다 — 열거 밖 문자열이면 `truth.robot` 으로.
        local bad = run_producer(truth, "Replace", _lane("RobotID(9999)", "Replace"), Dict{String,Any}())
        @test bad.constraints[1].agent == A

        # (B-4) tool 레인이 아예 없으면(오늘의 canonical 판) 예전 동작 그대로.
        local none = run_producer(truth, "Replace", nothing, Dict{String,Any}())
        @test none.constraints[1].agent == A

        # (B-5) SwapBattery 도 같은 seam 을 탄다(배터리 사건이 이 레인의 절반이다).
        local bt = CB.BatteryTruth(A, 0.1)
        local sp = run_producer(bt, "SwapBattery", _lane(string(B), "SwapBattery"), Dict{String,Any}())
        @test sp.constraints[1] isa CB.SwapBattery
        @test sp.constraints[1].agent == B
    end

    @testset "(C) `enact_decision!` 의 row 가 결정 행까지 살아 도착한다" begin
        # 뽑은 것이 진짜 결정 행 조립부다 — 구간이 사라지면 여기서 먼저 걸린다.
        @test ROW isa AbstractDict
        @test ROW["macro"] == "Replace"
        @test ROW["truth"] == "FaultTruth"
        # 🔴 뽑은 구간이 **합류 지점을 포함한다**. `merge!` 가 이 구간 밖으로 나가면
        # 위 `extract_block` 이 `error()` 를 던진다(조용히 안 넘어간다).
        @test occursin("enact_decision!", ROW_SRC)
        @test occursin("merge!(this_decision", ROW_SRC)
        # 결정 행은 `_DECISIONS` 안의 **같은 dict** 여야 한다 — 복사본이면 merge! 가
        # 산출물에 안 보인다(push! 를 merge! 뒤로 옮기거나 copy 를 끼우면 여기가 빨개진다).
        @test length(_RowSandbox._DECISIONS) == 1
        @test _RowSandbox._DECISIONS[1] === ROW

        # 🔴 네 키가 값까지 그대로 도착한다. 키 하나를 떨어뜨리는 필터가 끼면 `haskey` 가,
        # 다른 키의 값을 실으면 값 비교가 잡는다.
        @test haskey(ROW, "tool_agent")        && ROW["tool_agent"] == SENT_TOOLAG
        @test haskey(ROW, "enact_agent")       && ROW["enact_agent"] == SENT_AGENT
        @test haskey(ROW, "enact_agent_source") && ROW["enact_agent_source"] == SENT_SOURCE
        @test haskey(ROW, "verify")            && ROW["verify"] == SENT_VERIFY
    end

end # 바깥 testset

end # module
