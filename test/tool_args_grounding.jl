# =============================================================================
# T3 (Plan B) — **tool 인자 접지 판정**의 게이트.
#
# 오늘 이 레인에서 `tool_args` 를 거르는 자리는 `CB.ground_tool_args` **하나뿐이다**
# (디코드 시점 차단이 없다: `dspy.Tool` 에 `strict` 필드 자체가 없고 `tool_choice` 도 안
# 보낸다. 두 번째 방어선 `grammar_ground_check` 는 `RespecProposal` 을 받아서 tool 레인을
# 못 본다). 그러니 **이 게이트가 약하면 방어선이 없는 것과 같다.**
#
# 🔴 이 파일이 지키는 명제 둘:
#   (a) 판정은 **삼상이고 셋 다 도달 가능하다.** 상태가 셋인데 둘만 닿을 수 있으면 그것은
#       거짓말이 하나 든 이상 상태다 — 그래서 각 값마다 그것을 내는 **실재 입력**을 만든다.
#   (b) 🔴 spec §4-1 — **tool 실패가 결정을 지우지 않는다.** `reject` 는 "tool 레인이
#       실패했다" 이지 "결정이 사라졌다" 가 아니다. 매크로 결정은 그대로 서고 그대로
#       집행된다(`truth.robot` 으로). 그래서 reject 판에서도 `enact_applied === true` 이고
#       세계가 실제로 바뀌는 것을 잰다.
#
# 변이시험(스크래치패드 오버레이 사본, 레포 파일은 안 부순다)으로 실제 RED 를 확인한 것:
#   * `deferred:*` 를 `"admit"` 으로 바꾼다            → (3)·(4) 가 빨개진다
#   * 집행 조건에서 `verdict == "admit"` 를 뺀다       → (5) 의 deferred 쪽이 빨개진다
#   * `reject` 일 때 예외를 던진다                     → (2) 가 빨개진다(결정이 지워진다)
# 출력은 T3 보고서에 그대로 붙였다.
#
# 이 파일은 서비스를 **아예 안 부른다** — 순수 판정 함수와 집행 함수를 직접 부른다.
# 🔴 `127.0.0.1:8077` 로는 한 요청도 안 나간다(`/decide` 는 유료 OpenAI 호출이다).
# 비싼 것은 env 하나뿐이다(`test/enact_uses_llm_agent.jl` 과 같은 SCENE-INCANTATION,
# `n_spare_per_pool` 만 넉넉히 잡는다 — 이 파일이 Replace 를 세 번 집행한다).
# =============================================================================

module ToolArgsGrounding

using Test
using ConstructionBots
const CB = ConstructionBots
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))

# BatteryTruth / BATTERY_FLEET / init_battery_fleet! 는 런타임 include 계층에 산다.
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 🔴 생산 코드를 실제로 태운다 — `run_demo.jl` 이 부르는 바로 그 `enact_target`/`enact_macro!`.
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "tool_args_grounding",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 4,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

const _PREV_FLEET = CB.BATTERY_FLEET[]
const _PREV_ACCT  = CB.BATTERY_ACCOUNTING[]

# `decide_all` 이 만드는 것과 **같은 모양**의 8키 레인. 🔴 키 여덟은 항상 존재하고 값만
# `nothing` 일 수 있다 — `haskey` 는 값이 실려 왔다는 증거가 아니다(T1 소비자 규칙 1).
# 그래서 `tool_called` 와 `tool_args` 를 **따로** 받는다: 둘은 서로 독립적으로 비어 있을 수 있고,
# 그 조합이 바로 아래 (5) 가 재는 자리다.
_lane(called, args) = Dict{String,Any}("tool_called" => called, "tool_args" => args,
                                       "tool_calls_n" => nothing, "tools_offered" => nothing,
                                       "expressible" => nothing, "native_fc" => nothing,
                                       "tool_lane_error" => nothing, "macro_tool_agree" => nothing)

try
    CB.init_battery_fleet!(TENV)
    local fleet = CB.BATTERY_FLEET[]

    local descs = CB.open_agent_descriptors(TENV)
    local A = CB.resolve_agent_id(TENV, descs[1]["id"])
    local B = CB.resolve_agent_id(TENV, descs[2]["id"])
    # 이 판의 truth 는 **A** 에 대한 배터리 사건이다. LLM 은 아래에서 **B** 를 낸다.
    local truth = CB.BatteryTruth(A, 0.1)

    @testset "tool 인자 접지 판정 — 삼상 (Plan B / T3)" begin

    @testset "(0) 전제 — A ≠ B 이고 둘 다 실재 로봇이다" begin
        @test length(descs) >= 2
        @test A !== nothing && B !== nothing && A != B
        @test truth.robot == A
        @test haskey(fleet.soc, A) && haskey(fleet.soc, B)
    end

    @testset "(1) admit — 열거에 실재하는 id" begin
        local v, d = CB.ground_tool_args(TENV, "swap_body",
                                         Dict{String,Any}("agent" => string(B)))
        @test v == "admit"                       # 🔴 정확히 "admit". 접미사 없음.
        @test occursin(string(B), d)
        # 보여 준 집합 전체가 admit 이다(같은 열거에서 나오므로 갈라질 수 없다).
        for dd in descs
            @test CB.ground_tool_args(TENV, "deliver_battery",
                                      Dict{String,Any}("agent" => dd["id"]))[1] == "admit"
        end
        # 집행도 그것을 쓴다.
        local tgt = enact_target(TENV, truth, _lane("swap_body",
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}())
        @test tgt.verify == "admit"
        @test tgt.source == "tool"
        @test tgt.agent == B
    end

    @testset "(2) 🔴 reject:ungrounded_agent — 열거 밖 문자열. 그래도 결정은 안 지워진다" begin
        local v, d = CB.ground_tool_args(TENV, "swap_body",
                                         Dict{String,Any}("agent" => "RobotID(9999)"))
        @test v == "reject:ungrounded_agent"
        @test startswith(v, "reject:")
        @test occursin("9999", d)
        # 파싱이 없다는 것(정수를 파싱해 RobotID(n) 을 지으면 이 셋이 통과하고 접지가 사라진다).
        for bad in ("9999", string(A) * " ", "")
            @test CB.ground_tool_args(TENV, "swap_body",
                                      Dict{String,Any}("agent" => bad))[1] == "reject:ungrounded_agent"
        end
        # 문자열이 아닌 값도 "재서 어긋났다" 다 — 인자는 실려 왔고 열거에 없다.
        @test CB.ground_tool_args(TENV, "swap_body",
                                  Dict{String,Any}("agent" => 5))[1] == "reject:ungrounded_agent"

        # 🔴 spec §4-1: tool 실패가 **결정을 지우지 않는다.** 집행은 그대로 일어난다.
        local tgt = enact_target(TENV, truth, _lane("swap_body",
                        Dict{String,Any}("agent" => "RobotID(9999)")), Dict{String,Any}())
        @test tgt.verify == "reject:ungrounded_agent"
        @test tgt.source == "truth"               # T2 의 세 값은 그대로다
        @test tgt.agent == truth.robot            # = A
        @test tgt.tool_agent == "RobotID(9999)"   # 원문은 버리지 않는다
        fleet.soc[A] = 0.42
        fleet.soc[B] = 0.11
        local res = enact_macro!(TENV, truth, "Replace", tgt.agent)
        @test res.enact_applied === true          # ← 결정이 그대로 집행됐다
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.11                # 음성 대조: LLM 이 지목한 B 는 안 바뀐다
    end

    @testset "(3) deferred:no_tool_call — tool 호출 자체가 없다" begin
        # 🔴 "못 쟀다" 는 "재서 통과했다" 가 아니다(spec §9-2).
        @test CB.ground_tool_args(TENV, nothing, nothing)[1] == "deferred:no_tool_call"
        # 인자가 **실재 id 로 실려 있어도** 호출 이름이 없으면 못 잰 것이다.
        @test CB.ground_tool_args(TENV, nothing,
                Dict{String,Any}("agent" => string(B)))[1] == "deferred:no_tool_call"
        @test CB.ground_tool_args(TENV, "", nothing)[1] == "deferred:no_tool_call"
        @test CB.ground_tool_args(TENV, 7, nothing)[1] == "deferred:no_tool_call"
        # 호출은 있는데 인자 dict 이 통째로 없다 — 이것도 못 잰 것이다.
        @test CB.ground_tool_args(TENV, "swap_body", nothing)[1] == "deferred:no_tool_args"
        # 🔴 admit 이 아니다.
        @test CB.ground_tool_args(TENV, nothing, nothing)[1] != "admit"
        # 8키가 전부 nothing 인 레인(= `policy_entry` 폴백 분기가 내는 그 모양)도 같다.
        local tgt = enact_target(TENV, truth, _lane(nothing, nothing), Dict{String,Any}())
        @test tgt.verify == "deferred:no_tool_call"
        @test tgt.source == "truth"
        # `tool_lane` 자체가 없는 호출자도 같은 답을 얻는다.
        @test enact_target(TENV, truth, nothing, nothing).verify == "deferred:no_tool_call"
    end

    @testset "(4) 🔴 deferred:no_groundable_param — 접지할 파라미터가 없는 tool" begin
        # `no_intervention` 의 인자는 `reason` 뿐이다(`tool_registry.py`). 접지할 것이 없다.
        # 🔴 이것을 `admit` 으로 기록하면 나중에 "접지 통과율" 을 세는 사람이 **NOOP 을
        #    통과로 센다.** 공허한 참은 통과가 아니다.
        local v, d = CB.ground_tool_args(TENV, "no_intervention",
                        Dict{String,Any}("reason" => "SoC 0.9 이고 진전이 있다"))
        @test v == "deferred:no_groundable_param"
        @test v != "admit"
        @test occursin("reason", d)
        # 인자가 아예 비어 있어도 같다.
        @test CB.ground_tool_args(TENV, "no_intervention",
                                  Dict{String,Any}())[1] == "deferred:no_groundable_param"
        local tgt = enact_target(TENV, truth,
                        _lane("no_intervention", Dict{String,Any}("reason" => "x")),
                        Dict{String,Any}())
        @test tgt.verify == "deferred:no_groundable_param"
        @test tgt.source == "truth"
        @test tgt.tool_agent === nothing
    end

    @testset "(5) 🔴 admit 일 때만 LLM 의 agent 가 세계를 바꾼다" begin
        # (a) admit → B 가 바뀌고 A 는 안 바뀐다.
        fleet.soc[A] = 0.31
        fleet.soc[B] = 0.22
        local ok = enact_target(TENV, truth, _lane("swap_body",
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}())
        @test ok.verify == "admit"
        enact_macro!(TENV, truth, "Replace", ok.agent)
        @test fleet.soc[B] == 1.0
        @test fleet.soc[A] == 0.31

        # (b) 🔴 **접지 판정이 admit 이 아니면 그 agent 는 세계를 못 바꾼다.**
        #     여기서 인자는 **실재하는 B** 다 — 그런데 `tool_called` 값이 없어서 판정이
        #     `deferred` 다. 집행 조건에서 `verdict == "admit"` 를 빼면 이 판이 B 로 가고
        #     이 검사가 빨개진다(그 검사가 하중을 받는 유일한 자리다: agent 가 열거 밖인
        #     reject 판은 `resolve_agent_id` 만으로도 이미 폴백하므로 변이를 못 잡는다).
        fleet.soc[A] = 0.55
        fleet.soc[B] = 0.66
        local def = enact_target(TENV, truth, _lane(nothing,
                        Dict{String,Any}("agent" => string(B))), Dict{String,Any}())
        @test def.verify == "deferred:no_tool_call"
        @test def.source == "truth"
        @test def.agent == truth.robot             # = A
        @test def.tool_agent == string(B)          # 원문은 남는다
        enact_macro!(TENV, truth, "Replace", def.agent)
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.66                 # ← B 는 한 비트도 안 바뀐다
    end

    @testset "(6) 삼상 그 자체 — 셋 다 도달했고 서로 안 겹친다" begin
        local seen = String[
            CB.ground_tool_args(TENV, "swap_body", Dict{String,Any}("agent" => string(A)))[1],
            CB.ground_tool_args(TENV, "swap_body", Dict{String,Any}("agent" => "RobotID(9999)"))[1],
            CB.ground_tool_args(TENV, nothing, nothing)[1],
            CB.ground_tool_args(TENV, "no_intervention", Dict{String,Any}("reason" => "x"))[1]]
        _state(v) = v == "admit" ? "admit" :
                    startswith(v, "reject:") ? "reject" :
                    startswith(v, "deferred:") ? "deferred" : "🔴 문법 밖: " * v
        @test _state.(seen) == ["admit", "reject", "deferred", "deferred"]
        @test length(Set(seen)) == 4               # 네 입력이 네 개의 서로 다른 판정을 낸다
        # R16(강제 팔)은 **접지 판정을 덮지 않는다** — 접지는 인자에 대한 사실이고, 강제 팔의
        # 거절은 `enact_agent_source` 가 나른다. 두 축을 한 필드에 섞지 않는다.
        local tgt = enact_target(TENV, truth, _lane("swap_body",
                        Dict{String,Any}("agent" => string(B))),
                        Dict{String,Any}("deviated" => true))
        @test tgt.verify == "admit"
        @test tgt.source == "truth"
    end

    end
finally
    CB.BATTERY_FLEET[] = _PREV_FLEET
    CB.BATTERY_ACCOUNTING[] = _PREV_ACCT
end

end # module
