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
# 🔴 2026-08-29 수정 라운드가 이 파일에서 고친 것
# -----------------------------------------------
#  항목 1  양성 관측이 **`fleet.soc[B]` 한 칸**뿐이었다. 그 값을 쓰는 것은 `hot_swap_robot!`
#          이 아니라 그 두 줄 뒤의 **대입문**이고, `hot_swap_robot!` 의 `status` 는 아무도
#          안 읽었다 — `:no_spare`/`:no_robot` 은 **예외가 아니라 반환값**이다. 그래서 창고에
#          예비가 없어 씬트리 수술이 **아무것도 안 해도** 이 게이트가 초록이었다. 이제 (3) 이
#          **씬트리 수술 자체**(`HOT_SWAP_ASSETS`)와 `status === :swapped` 를 단언한다.
#  항목 4  `asset_generation(A)` 음성 대조가 **조용히 항진명제가 될 수 있었다** — A 의 SoC 가
#          `REPLACE_SOC_THRESHOLD` 이하면 원인이 `:battery` 로 분류돼 `:battery_swap` 행이 되고
#          `asset_generation` 이 세지 않는다(`asset_ledger.jl:141` 의 `_BODY_CHANGING_EVENTS`).
#          그 리터럴(0.42)을 무심코 낮추면 대조가 죽는다. 이제 SoC 를 문턱에서 **유도**하고
#          결합 자체를 단언한다.
#  항목 4b `_arm_overridden` 이 **과잉 거부**했다. (6) 이 그 좁힌 술어를 양쪽으로 잰다.
#  항목 0  🔴 **분수령의 생산 라인이 게이트 밖이었다.** (9)·(10) 이 그것을 닫는다.
#
# 이 파일은 서비스를 **아예 안 부른다** — 집행 함수를 직접 부른다. 🔴 `127.0.0.1:8077` 로는
# 한 요청도 안 나간다(`/decide` 는 사용자 계정의 유료 OpenAI 호출이다).
#
# 비싼 것은 env 하나뿐이다(`test/service_decide_ships_agents.jl` 의 SCENE-INCANTATION 정본과
# 같은 인자). 시뮬레이션은 한 스텝도 안 돌린다 — `_open_agent_pairs` 가 읽는 것은 배정이 끝난
# 스케줄 그래프뿐이고, 그것은 `return_env_before_sim=true` 시점에 이미 완성돼 있다.
#
# 변이시험(스크래치패드 오버레이 사본, 레포 파일은 안 부순다)으로 실제 RED 를 확인한 것:
#   * 집행 대상을 `truth.robot` 으로 되돌린다        → (3)·(9) 가 빨개진다 ← 이 태스크의 유일한 진짜 증거
#   * `enact_agent_source` 기록을 지운다             → (4) 가 빨개진다
#   * `resolve_agent_id` 를 "정수 파싱 → RobotID(n)" 로 바꾼다 → (4) 가 빨개진다(9999 가 통과한다)
#   * R16 강제-팔 거절을 지운다                      → (6) 이 빨개진다
#   * `_arm_overridden` 을 다시 `deviate_from` 존재로 넓힌다 → (6)(c) 가 빨개진다
#   * `hot_swap_robot!` 의 `status` 를 다시 버린다   → (3) 이 빨개진다
#   * `run_demo.jl` 의 호출부를 인라인 사슬로 되돌린다 → (10) 이 빨개진다
# 출력은 수정 라운드 보고서에 그대로 붙였다.
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
# 바로 그 세 함수다(`enact_target` · `enact_macro!` · `enact_decision!`). 사슬이
# `run_demo.jl` 안에 남아 있었다면 이 줄이 불가능했고, 이 파일은 순수 함수 복제본만 재는
# "실패할 수 없는 게이트" 가 됐을 것이다.
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

# 🔴 집행되는 팔과 그 팔에 대응하는 **tool 이름**. tool 이름을 리터럴로 적지 않는다 —
# `CB.MACRO_TO_TOOL` 에서 유도한다(그 표는 `test/tool_args_grounding.jl` (7) 의 교차언어
# 게이트가 `tool_registry.py` 와 집합 등식으로 묶는다). 출처 일치 검사(항목 8)가 들어온
# 뒤로는 **이 tool 이름이 맞아야만** tool 의 agent 가 쓰인다.
const _MAC  = "Replace"
const _TOOL = CB.MACRO_TO_TOOL[_MAC]

# `tool_lane` 을 `decide_all` 이 만드는 것과 **같은 모양**으로 짓는다(8키, 값만 다름).
# 🔴 키 여덟은 항상 존재한다 — `haskey` 는 값이 실려 왔다는 증거가 아니다(T1 소비자 규칙 1).
_lane(args; called = _TOOL) =
    Dict{String,Any}("tool_called" => (args === nothing ? nothing : called),
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

    # 🔴 항목 4 — 음성 대조의 SoC 를 **문턱에서 유도한다.** `asset_generation` 은 본체가
    # 바뀌는 사건만 센다(`:asset_replacement`/`:tow_replacement`). SoC 가
    # `REPLACE_SOC_THRESHOLD` 이하면 `hot_swap_robot!` 이 원인을 `:battery` 로 분류하고
    # 그 행은 `:battery_swap` 이 되어 **세대에 안 잡힌다** — 즉 A 의 SoC 를 문턱 아래로
    # 내리는 순간 `asset_generation(A) == genA0` 대조가 조용히 항진명제가 된다.
    # 리터럴 0.42 대신 문턱에서 유도하고, 그 결합을 (1) 에서 **단언**한다.
    local CTRL_SOC = CB.REPLACE_SOC_THRESHOLD[] + 0.22

    @testset "집행이 LLM 의 agent 를 읽는다 (Plan B / T2)" begin

    @testset "(1) 전제 — A ≠ B 이고 둘 다 실재 로봇이다" begin
        @test length(descs) >= 2
        @test A !== nothing && B !== nothing
        @test A != B
        @test truth.robot == A
        @test haskey(fleet.soc, A) && haskey(fleet.soc, B)
        # 🔴 항목 4: 이 결합이 깨지면 아래 `asset_generation` 음성 대조가 **조용히 죽는다.**
        @test CTRL_SOC > CB.REPLACE_SOC_THRESHOLD[]
        # 이 파일이 쓰는 tool 이름은 유도된 것이지 리터럴이 아니다.
        @test _TOOL isa String && !isempty(_TOOL)
        @test haskey(CB.TOOL_PARAM_SCHEMA, _TOOL)
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
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}(), _MAC)
        @test tgt.source == "tool"
        @test tgt.agent == B
        @test tgt.agent != truth.robot
        @test tgt.tool_agent == string(B)
        @test tgt.reject === nothing              # 쓴 판에서는 거절 사유가 없다

        # 두 로봇의 SoC 를 **서로 다른 값**으로 벌려 둔다. 같은 값이면 "어느 쪽이 바뀌었나" 를
        # 못 읽는다(브리프의 경고: 두 값이 같은 시험은 배선 전후로 똑같이 통과한다).
        fleet.soc[A] = CTRL_SOC
        fleet.soc[B] = 0.11
        local genA0 = CB.asset_generation(A)
        # 🔴 항목 1 — **씬트리 수술 자체**를 잰다. `fleet.soc[B]` 한 칸은 `hot_swap_robot!` 이
        # 아니라 그 두 줄 뒤의 대입문이 쓰는 값이라, 수술이 `:no_spare` 로 아무것도 안 해도
        # 예전에는 초록이었다. 수술의 흔적은 `HOT_SWAP_ASSETS` 에 남는다
        # (`replace_robot.jl:1527`, 수술이 성공한 뒤에만 실행되는 줄).
        local before_keys = Set(keys(CB.HOT_SWAP_ASSETS[]))
        @test !(B in before_keys)                 # 이 수술이 B 를 처음 넣는다

        local res = enact_macro!(TENV, truth, _MAC, tgt.agent)
        @test res.enact_applied === true
        # 🔴 항목 1 — `hot_swap_robot!` 의 **반환 상태를 읽는다.** `:no_spare`/`:no_robot` 은
        # 예외가 아니라 반환값이고, 예전에는 아무도 안 읽었다.
        @test res.status === :swapped
        # 🔴 씬트리 수술이 **B 에** 떨어졌다.
        @test haskey(CB.HOT_SWAP_ASSETS[], B)
        @test CB.HOT_SWAP_ASSETS[][B].spare != B  # 창고 예비 본체가 실제로 하나 나왔다
        # 음성 대조: A 는 이 수술의 대상이 아니었다(문턱과 무관한 대조 — 항목 4).
        @test haskey(CB.HOT_SWAP_ASSETS[], A) == (A in before_keys)

        # 관측: B 가 회복됐고, A 는 한 비트도 안 변했다.
        @test fleet.soc[B] == 1.0                      # ← 집행이 B 에 갔다
        @test fleet.soc[A] == CTRL_SOC                 # ← A 는 안 건드렸다 (음성 대조)
        @test CB.asset_generation(A) == genA0          # ← A 의 본체도 안 갈렸다 (음성 대조)
    end

    @testset "(4) 접지 실패 → truth 로 떨어지고 그 사실이 **기록된다**" begin
        # 🔴 조용한 폴백은 이 태스크를 무의미하게 만든다(R2/R6): 기록이 없으면 "LLM 이 골랐다"
        # 와 "주입기가 알려줬다" 가 같은 관측이 된다.
        local tl = _lane(Dict{String,Any}("agent" => "RobotID(9999)"))
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}(), _MAC)
        @test tgt.agent == truth.robot                 # = A
        @test tgt.source == "truth"
        @test tgt.tool_agent == "RobotID(9999)"        # 원문은 버리지 않는다
        # 🔴 항목 2 — **왜** 안 썼는지가 남는다. 열거에 없다(정상적인 접지 실패)와 해석기가
        # 던졌다(버그)를 하나의 조용한 폴백으로 접지 않는다.
        @test tgt.reject == "verify:reject:ungrounded_agent"
        @test tgt.verify == "reject:ungrounded_agent"
        @test occursin("9999", tgt.verify_detail)      # 사유 문자열이 살아 있다 (항목 11)
    end

    @testset "(5) tool 레인 부재 → A 로 떨어지고 source == truth" begin
        # 8키가 전부 nothing 인 레인(= `policy_entry` 의 폴백 분기가 내는 그 모양).
        local tgt = enact_target(TENV, truth, _lane(nothing), Dict{String,Any}(), _MAC)
        @test tgt.agent == truth.robot
        @test tgt.source == "truth"
        @test tgt.tool_agent === nothing
        @test tgt.reject == "no_tool_agent"
        # `tool_lane` 자체가 없는 호출자도 같은 답을 얻는다.
        local tgt2 = enact_target(TENV, truth, nothing, nothing, _MAC)
        @test tgt2.source == "truth"
        # 문자열이 아닌 값(중첩 인자가 생기는 날의 JSON3.Object 자리)은 레인 부재와 같게 다룬다.
        local tgt3 = enact_target(TENV, truth,
                                  _lane(Dict{String,Any}("agent" => 5)), Dict{String,Any}(), _MAC)
        @test tgt3.source == "truth"
        @test tgt3.tool_agent === nothing
    end

    @testset "(6) 🔴 R16 — 팔이 **실제로** 갈아 끼워진 판에서만 tool 의 agent 를 거절한다" begin
        # T1 리뷰 F8: `tool_lane` 은 `pol[enacted]` 에서 나오고 override 는 거기 한 번도 안
        # 쓴다. 그래서 통제·이탈 판에서 `macro_name` 과 `tool_called` 은 서로 다른 팔을
        # 서술한다 — 그 agent 를 집행에 먹이면 한 팔을 위해 고른 값이 다른 팔에 적용되고
        # 결정 행은 그것을 `"tool"` 로 주장한다. 해법은 추측이 아니라 거절이다.
        local tl = _lane(Dict{String,Any}("agent" => string(B)))
        # (a) 팔이 실제로 달라진 세 모양.
        for rt in (Dict{String,Any}("deviated" => true),
                   Dict{String,Any}("deviate_from" => "NOOP"),
                   Dict{String,Any}("forced_from" => "NOOP"))
            local tgt = enact_target(TENV, truth, tl, rt, _MAC)
            @test tgt.agent == truth.robot             # = A, 강제된 팔의 주인
            @test tgt.source == "truth"
            @test tgt.tool_agent == string(B)          # LLM 이 B 를 냈다는 사실은 남는다
            @test tgt.reject == "arm_overridden"
            # ⚠️ R16 은 **접지 판정을 안 덮는다** — 두 축은 따로다.
            @test tgt.verify == "admit"
        end
        # (b) `forced` 는 `FORCE_MACRO != chosen` 일 때만 라우터에 실린다 — 강제 팔이 집행 팔과
        # 다르면 라우터에 표식이 없어도 그 판은 통제 판이다(같은 술어를 env 에도 쓴다).
        withenv("DEMO_FORCE_MACRO" => "NOOP") do
            local tgt = enact_target(TENV, truth, tl, Dict{String,Any}(), _MAC)
            @test tgt.source == "truth"
            @test tgt.agent == truth.robot
            @test tgt.reject == "arm_overridden"
        end
        # (c) 🔴 항목 4b — **과잉 거부는 결함이다.** `policy.jl:1525` 는 이탈 게이트가 발화하면
        # 팔이 **안 바뀌어도** `deviate_from` 을 심는다(`deviated` 는 따로 `dev != chosen`).
        # 그래서 예전 판은 이탈 팔이 정책의 선택과 **같은** 런까지 거부했고, 그 런들이 전부
        # `enact_agent_source == "truth"` 로 기록되어 히스토그램이 체계적으로 깎였다.
        # 두 경로 모두 "팔이 실제로 달라졌는가" 하나만 본다.
        local same = enact_target(TENV, truth, tl,
                        Dict{String,Any}("deviate_from" => _MAC, "deviated" => false,
                                         "deviate_at" => 3, "deviate_arm" => _MAC), _MAC)
        @test same.source == "tool"                    # ← 과잉 거부였다면 "truth" 다
        @test same.agent == B
        @test same.reject === nothing
        withenv("DEMO_FORCE_MACRO" => _MAC) do
            local tgt = enact_target(TENV, truth, tl, Dict{String,Any}(), _MAC)
            @test tgt.source == "tool"                 # ← 강제 팔 == 집행 팔이면 통제가 아니다
            @test tgt.agent == B
        end
        # (d) 🔴 항목 6 — `force_macro` 는 **인자**다. 프로세스 ENV 를 흘리는 다른 테스트가
        # 하나 생겨도 이 판정이 안 흔들린다는 사실을 여기서 못박는다.
        @test _arm_overridden(Dict{String,Any}(), _MAC; force_macro = "NOOP") === true
        @test _arm_overridden(Dict{String,Any}(), _MAC; force_macro = _MAC) === false
        @test _arm_overridden(Dict{String,Any}(), _MAC; force_macro = "") === false

        # 그리고 **세계도** 그렇게 바뀐다: 강제 판에서는 A 가 바뀌고 B 는 안 바뀐다.
        fleet.soc[A] = 0.33
        fleet.soc[B] = 0.77
        local tgt = enact_target(TENV, truth, tl, Dict{String,Any}("deviated" => true), _MAC)
        local r = enact_macro!(TENV, truth, _MAC, tgt.agent)
        @test r.status === :swapped
        @test fleet.soc[A] == 1.0
        @test fleet.soc[B] == 0.77
    end

    @testset "(7) truth 에 robot 이 없으면 source == none" begin
        local zt = CB.ZoneTruth(:enact_gate_zone, [0.0, 0.0], 1.0)
        @test !hasproperty(zt, :robot)
        local tgt = enact_target(TENV, zt, _lane(nothing), Dict{String,Any}(), _MAC)
        @test tgt.agent === nothing
        @test tgt.source == "none"
        @test tgt.tool_agent === nothing
    end

    @testset "(8) 순수 이동 확인 — 사슬의 나머지 분기는 옮기기 전과 같다" begin
        # NOOP: 가드 없는 분기, `enact_applied=true` · 솔버 안 부름.
        local noop = enact_macro!(TENV, truth, "NOOP", A)
        @test noop.enact_applied === true
        @test noop.ran_milp === false
        @test noop.status === nothing              # 편집 연산을 아예 안 불렀다

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
        @test enact_macro!(TENV, zt, _MAC, A).enact_applied === false
    end

    @testset "(9) 🔴 분수령의 **호출부** — `enact_decision!` 을 직접 태운다 (항목 0)" begin
        # 🔴 리뷰어 실측: 예전에는 `run_demo.jl` 의 집행 호출부에서 마지막 인자를
        # `truth.robot` 으로 되돌리면 **T2 이전 세계가 정확히 복원되는데 스위트 전체가
        # 초록**이었다 — `runtests.jl` 의 어떤 테스트도 `run_demo.jl` 을 읽지 않기 때문이다.
        # 변이시험이 빨개졌던 것은 `enact.jl` **안의 함수**를 고쳤을 때이고, **그 함수를 부르는
        # 자리**는 아무도 안 지켰다. 이제 그 호출부가 `enact_decision!` 이고, 이 검사가
        # 그것을 **결정 하나를 통째로 먹여** 태운다.
        local C = CB.resolve_agent_id(TENV, descs[3]["id"])
        @test C !== nothing && C != A && C != B
        local tr = CB.BatteryTruth(A, 0.1)
        fleet.soc[A] = CTRL_SOC
        fleet.soc[C] = 0.09
        local decision = (macro_name = _MAC,
                          tool_lane = _lane(Dict{String,Any}("agent" => string(C))),
                          router = Dict{String,Any}())
        local e = enact_decision!(TENV, tr, decision)
        # 대상 선택
        @test e.target.source == "tool"
        @test e.target.agent == C
        # 결정 행 (spec §9-2). 🔴 호출부가 키를 골라 담으면 그 자리가 다시 게이트 밖의
        # 화이트리스트가 된다 — `row` 가 `enact_decision!` 의 산출물 전부여야 하는 이유다.
        @test e.row["enact_agent"] == string(C)
        @test e.row["enact_agent_source"] == "tool"
        @test e.row["tool_agent"] == string(C)
        @test e.row["enact_agent_reject"] === nothing
        @test e.row["verify"] == "admit"
        @test occursin(string(C), e.row["verify_detail"])
        @test e.row["enact_applied"] === true
        @test e.row["ran_milp"] === false
        # zone 축이 아니므로 ④층은 **유보**다(R10) — `inert` 로 접지 않는다.
        @test e.row["efficacy"] == "deferred:no_efficacy_measure"
        @test e.row["efficacy_checked_paths"] === nothing
        # 🔴 그리고 세계가 **C** 에서 바뀌었다. 호출부가 `truth.robot` 을 넘기면 A 가 바뀐다.
        @test haskey(CB.HOT_SWAP_ASSETS[], C)
        @test fleet.soc[C] == 1.0
        @test fleet.soc[A] == CTRL_SOC
    end

    @testset "(10) 🔴 `run_demo.jl` 의 호출부가 이 함수에 **위임한다** (항목 0)" begin
        # 🔴 왜 소스 텍스트인가: (9) 는 `enact_decision!` 의 본체를 지키지만, `run_demo.jl` 이
        # 그 함수를 **안 부르고** 다시 인라인 사슬을 들면 (9) 는 그대로 초록이다. 그 파일은
        # 최상위에서 데모를 통째로 돌리는 스크립트라 어떤 테스트도 include 할 수 없으므로,
        # 남은 두 줄을 지키는 방법은 소스를 문자열로 읽는 것뿐이다. 이 게이트는 **약하지만
        # 정확히 그 두 줄만** 지키고, 진짜 하중은 (9) 와 `tool_args_grounding.jl` (9) 가 진다.
        local src = read(joinpath(REPO, "tools", "monitor", "run_demo.jl"), String)
        @test occursin("enact_decision!(env, truth, decision)", src)
        @test occursin("merge!(this_decision, _e.row)", src)
        # 🔴 그리고 집행 함수를 **직접** 부르지 않는다 — 되돌림(인라인 사슬 복원)이 정확히
        # 여기서 빨개진다.
        @test !occursin("enact_target(", src)
        @test !occursin("enact_macro!(", src)
        @test !occursin("enact_with_efficacy!(", src)
        # 그리고 결정 행의 키들을 그 파일이 **직접 짓지 않는다** — 다시 손으로 고른
        # 화이트리스트가 되면 `enact_decision!` 이 키를 하나 더 내도 행에 안 실린다.
        for k in ("tool_agent", "enact_agent", "enact_agent_source", "enact_agent_reject",
                  "verify", "verify_detail", "enact_applied", "ran_milp",
                  "efficacy", "efficacy_checked_paths")
            @test !occursin("\"" * k * "\"", src)
        end
    end

    end
finally
    CB.BATTERY_FLEET[] = _PREV_FLEET
    CB.BATTERY_ACCOUNTING[] = _PREV_ACCT
end

end # module
