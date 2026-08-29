# =============================================================================
# 🔴 이 계획(Plan B)에서 가장 중요한 검사 하나.
#
# **핵심 명제: `tool_args` 의 agent 가 `truth.robot` 과 다를 때, 세계는 `truth.robot` 이
# 아니라 LLM 이 고른 agent 에서 바뀐다.**
#
# T2 이전까지 집행 사슬은 `CB.hot_swap_robot!(env, truth.robot; ...)` 를 불렀다 — 즉
# **주입기가 이미 아는 값**이다. 그래서 LLM 의 tool 호출은 세계에 대해 인과가 없었고,
# 그 앞의 Plan B 태스크는 전부 계측이었다. 이 파일이 그 인과를 잰다.
#
# ⚠️ 두 값이 **같은** 시험은 배선 전후로 똑같이 통과한다 — 아무것도 재지 않는다. 그래서
# 아래 (3) 은 A ≠ B 를 잡고, 두 로봇의 SoC 를 **서로 다른 값**으로 벌려 둔 뒤 어느 쪽이
# 바뀌었는지를 모호함 없이 읽는다(A 도 B 도 1.0 이면 관측이 성립하지 않는다).
#
# 이 파일은 서비스를 **아예 안 부른다** — 집행 함수를 직접 부른다. 🔴 `127.0.0.1:8077` 로는
# 한 요청도 안 나간다(`/decide` 는 사용자 계정의 유료 OpenAI 호출이다).
#
# 비싼 것은 env 하나뿐이다(`test/service_decide_ships_agents.jl` 의 SCENE-INCANTATION 정본과
# 같은 인자). 시뮬레이션은 한 스텝도 안 돌린다 — `_open_agent_pairs` 가 읽는 것은 배정이 끝난
# 스케줄 그래프뿐이고, 그것은 `return_env_before_sim=true` 시점에 이미 완성돼 있다.
#
# 변이시험(스크래치패드 오버레이 사본, 레포 파일은 안 부순다)으로 실제 RED 를 확인한 것:
#   * 집행 대상을 `truth.robot` 으로 되돌린다        → (3) 이 빨개진다  ← 이 태스크의 유일한 진짜 증거
#   * `enact_agent_source` 기록을 지운다             → (4) 가 빨개진다
#   * `resolve_agent_id` 를 "정수 파싱 → RobotID(n)" 로 바꾼다 → (4) 가 빨개진다(9999 가 통과한다)
#   * R16 강제-팔 거절을 지운다                      → (6) 이 빨개진다
# 출력은 T2 보고서에 그대로 붙였다.
# =============================================================================
module EnactUsesLLMAgent

using Test
using ConstructionBots
const CB = ConstructionBots
import Random
# policy.jl 은 include 하지 않는다(이 게이트는 정책 레이어를 안 탄다). Graphs 는
# `_open_agent_pairs` 가 CB 모듈 **안에서** 쓰므로 여기서 import 할 필요가 없다.

const REPO = normpath(joinpath(@__DIR__, ".."))

# BatteryTruth / BATTERY_FLEET / init_battery_fleet! 는 런타임 include 계층에 산다.
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 🔴 생산 코드를 **실제로** 태운다. `enact.jl` 은 최상위 부작용이 없으므로(그게 커밋 1 의
# 요구조건이었다) 여기서 그냥 include 된다 — 이 게이트가 재는 것은 `run_demo.jl` 이 부르는
# 바로 그 두 함수다(`enact_target` · `enact_macro!`). 사슬이 `run_demo.jl` 안에 남아 있었다면
# 이 줄이 불가능했고, 이 파일은 순수 함수 복제본만 재는 "실패할 수 없는 게이트" 가 됐을 것이다.
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "enact_uses_llm_agent",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

# 이 파일이 건드리는 전역 둘을 되돌린다 — 같은 프로세스에서 뒤따르는 게이트가 물들지 않게.
const _PREV_FLEET = CB.BATTERY_FLEET[]
const _PREV_ACCT  = CB.BATTERY_ACCOUNTING[]

# `tool_lane` 을 `decide_all` 이 만드는 것과 **같은 모양**으로 짓는다(8키, 값만 다름).
# 🔴 키 여덟은 항상 존재한다 — `haskey` 는 값이 실려 왔다는 증거가 아니다(T1 소비자 규칙 1).
_lane(args) = Dict{String,Any}("tool_called" => (args === nothing ? nothing : "replace_agent"),
                               "tool_args" => args, "tool_calls_n" => (args === nothing ? nothing : 1),
                               "tools_offered" => nothing, "expressible" => nothing,
                               "native_fc" => nothing, "tool_lane_error" => nothing,
                               "macro_tool_agree" => nothing)

try
    CB.init_battery_fleet!(TENV)
    local fleet = CB.BATTERY_FLEET[]

    local descs = CB.open_agent_descriptors(TENV)
    local A = CB.resolve_agent_id(TENV, descs[1]["id"])
    local B = CB.resolve_agent_id(TENV, descs[2]["id"])
    # 이 판의 truth 는 **A** 에 대한 배터리 사건이다. LLM 은 아래에서 **B** 를 낸다.
    local truth = CB.BatteryTruth(A, 0.1)

    @testset "집행이 LLM 의 agent 를 읽는다 (Plan B / T2)" begin

    @testset "(1) 전제 — A ≠ B 이고 둘 다 실재 로봇이다" begin
        @test length(descs) >= 2
        @test A !== nothing && B !== nothing
        @test A != B
        @test truth.robot == A
        @test haskey(fleet.soc, A) && haskey(fleet.soc, B)
    end

    @testset "(2) resolve_agent_id — 열거와 정확 일치, 파싱 없음" begin
        # 보여 준 집합 전체가 왕복한다(같은 열거에서 나오므로 갈라질 수 없다).
        for d in descs
            @test string(CB.resolve_agent_id(TENV, d["id"])) == d["id"]
        end
        # 🔴 접지 실패는 **측정된 결과**다. 정수를 파싱해 `RobotID(n)` 을 만들면 이 셋이 통과해
        # 버리고 그 순간 접지가 사라진다.
        @test CB.resolve_agent_id(TENV, "RobotID(9999)") === nothing
        @test CB.resolve_agent_id(TENV, "9999") === nothing
        @test CB.resolve_agent_id(TENV, string(A) * " ") === nothing
    end

    @testset "(3) 🔴 핵심 — 세계는 truth.robot(A) 이 아니라 LLM 이 고른 B 에서 바뀐다" begin
        local tl = _lane(Dict{String,Any}("agent" => string(B)))
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}())
        @test tgt.source == "tool"
        @test tgt.agent == B
        @test tgt.agent != truth.robot
        @test tgt.tool_agent == string(B)

        # 두 로봇의 SoC 를 **서로 다른 값**으로 벌려 둔다. 같은 값이면 "어느 쪽이 바뀌었나" 를
        # 못 읽는다(브리프의 경고: 두 값이 같은 시험은 배선 전후로 똑같이 통과한다).
        fleet.soc[A] = 0.42
        fleet.soc[B] = 0.11
        local genA0 = CB.asset_generation(A)

        local res = enact_macro!(TENV, truth, "Replace", tgt.agent)
        @test res.enact_applied === true

        # 관측: B 가 회복됐고, A 는 한 비트도 안 변했다.
        @test fleet.soc[B] == 1.0                      # ← 집행이 B 에 갔다
        @test fleet.soc[A] == 0.42                     # ← A 는 안 건드렸다 (음성 대조)
        @test CB.asset_generation(A) == genA0          # ← A 의 본체도 안 갈렸다 (음성 대조)
    end

    @testset "(4) 접지 실패 → truth 로 떨어지고 그 사실이 **기록된다**" begin
        # 🔴 조용한 폴백은 이 태스크를 무의미하게 만든다(R2/R6): 기록이 없으면 "LLM 이 골랐다"
        # 와 "주입기가 알려줬다" 가 같은 관측이 된다.
        local tl = _lane(Dict{String,Any}("agent" => "RobotID(9999)"))
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}())
        @test tgt.agent == truth.robot                 # = A
        @test tgt.source == "truth"
        @test tgt.tool_agent == "RobotID(9999)"        # 원문은 버리지 않는다
    end

    @testset "(5) tool 레인 부재 → A 로 떨어지고 source == truth" begin
        # 8키가 전부 nothing 인 레인(= `policy_entry` 의 폴백 분기가 내는 그 모양).
        local tgt = enact_target(TENV, truth, _lane(nothing), Dict{String,Any}())
        @test tgt.agent == truth.robot
        @test tgt.source == "truth"
        @test tgt.tool_agent === nothing
        # `tool_lane` 자체가 없는 호출자도 같은 답을 얻는다.
        local tgt2 = enact_target(TENV, truth, nothing, nothing)
        @test tgt2.source == "truth"
        # 문자열이 아닌 값(중첩 인자가 생기는 날의 JSON3.Object 자리)은 레인 부재와 같게 다룬다.
        local tgt3 = enact_target(TENV, truth,
                                  _lane(Dict{String,Any}("agent" => 5)), Dict{String,Any}())
        @test tgt3.source == "truth"
        @test tgt3.tool_agent === nothing
    end

    @testset "(6) 🔴 R16 — 팔이 강제/이탈된 판에서는 tool 의 agent 를 쓰지 않는다" begin
        # T1 리뷰 F8: `decide_all` 은 `tool_lane` 을 FORCE_MACRO/DEVIATE 가 `chosen` 을 덮기
        # **전에** 뽑는다. 그래서 통제·이탈 판에서 `macro_name` 과 `tool_called` 은 서로 다른
        # 팔을 서술한다 — 그 agent 를 집행에 먹이면 한 팔을 위해 고른 값이 다른 팔에 적용되고
        # 결정 행은 그것을 `"tool"` 로 주장한다. 해법은 추측이 아니라 거절이다.
        local tl = _lane(Dict{String,Any}("agent" => string(B)))
        for rt in (Dict{String,Any}("deviated" => true),
                   Dict{String,Any}("deviate_from" => "NOOP"),
                   Dict{String,Any}("forced_from" => "NOOP"))
            local tgt = enact_target(TENV, truth, tl, rt)
            @test tgt.agent == truth.robot             # = A, 강제된 팔의 주인
            @test tgt.source == "truth"
            @test tgt.tool_agent == string(B)          # LLM 이 B 를 냈다는 사실은 남는다
        end
        # `forced` 는 `FORCE_MACRO != chosen` 일 때만 라우터에 실린다 — 강제 팔이 우연히
        # 정책의 선택과 같으면 라우터에 아무 표식이 없다. 그래도 그 판은 통제 판이다.
        withenv("DEMO_FORCE_MACRO" => "Replace") do
            local tgt = enact_target(TENV, truth, tl, Dict{String,Any}())
            @test tgt.source == "truth"
            @test tgt.agent == truth.robot
        end

        # 그리고 **세계도** 그렇게 바뀐다: 강제 판에서는 A 가 바뀌고 B 는 안 바뀐다.
        fleet.soc[A] = 0.33
        fleet.soc[B] = 0.77
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}("deviated" => true))
        enact_macro!(TENV, truth, "Replace", tgt.agent)
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.77
    end

    @testset "(7) truth 에 robot 이 없으면 source == none" begin
        local zt = CB.ZoneTruth(:enact_gate_zone, [0.0, 0.0], 1.0)
        @test !hasproperty(zt, :robot)
        local tgt = enact_target(TENV, zt, _lane(nothing), Dict{String,Any}())
        @test tgt.agent === nothing
        @test tgt.source == "none"
        @test tgt.tool_agent === nothing
    end

    @testset "(8) 순수 이동 확인 — 사슬의 나머지 분기는 옮기기 전과 같다" begin
        # NOOP: 가드 없는 분기, `enact_applied=true` · 솔버 안 부름.
        local noop = enact_macro!(TENV, truth, "NOOP", A)
        @test noop.enact_applied === true
        @test noop.ran_milp === false

        # zone 두 분기는 `truth isa CB.ZoneTruth` 가드가 걸려 있다 — battery 사건에 그 팔로
        # deviate 하면 사슬을 **무동작으로** 통과한다. 그 사실이 `enact_applied=false` 로
        # 정직하게 남는 것이 2026-08-17 재리뷰 F2 가 고친 것이고, 이동이 그것을 안 깼다.
        @test enact_macro!(TENV, truth, "ForbidZone", A).enact_applied === false
        @test enact_macro!(TENV, truth, "RelocateBuild", A).enact_applied === false
        # 사슬에 없는 이름도 조용히 통과한다(최종 `else` 가 없다) — 같은 계약이다.
        @test enact_macro!(TENV, truth, "NoSuchMacro", A).enact_applied === false

        # `enact_applied` 는 **가드 안쪽**이다(재리뷰 C1(B)): robot 필드가 없는 truth 에
        # Replace 로 deviate 하면 분기는 매치되지만 아무 일도 안 일어난다.
        local zt = CB.ZoneTruth(:enact_gate_zone2, [0.0, 0.0], 1.0)
        @test enact_macro!(TENV, zt, "Replace", A).enact_applied === false
    end

    end
finally
    CB.BATTERY_FLEET[] = _PREV_FLEET
    CB.BATTERY_ACCOUNTING[] = _PREV_ACCT
end

end # module
