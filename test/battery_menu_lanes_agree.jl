# =============================================================================
# **라벨 레인과 실행 레인의 battery 메뉴가 같은가** — 계약을 못박는다.
#
# 무엇이 갈려 있었나 (2026-08-25 실측)
# ------------------------------------
#   라벨 레인 `ood_mdp_shim.valid_actions(:battery)` : SoC 로 메뉴를 가른다
#                                                     deep -> [0,1,2] · mild -> [0,2]
#   실행 레인 `policy.jl valid_macros(::BatteryTruth)`: **안 가른다** — 언제나 [0,1,2]
# 즉 같은 사건에서 라벨을 만든 세계와 실제로 굴린 세계의 **행동공간이 달랐다.** 이 레포가
# 반복해서 데인 모양 그대로다(어휘 누락은 에러 없이 성능으로만 샌다).
# 증상은 특히 조용하다: mild 에서 실행 레인은 `Replace` 를 고를 수 있는데 라벨 격자에는 그 행이
# 없으므로, 그 결정은 surrogate 가 **한 번도 본 적 없는 팔**로 남는다.
#
# 그래서 분할 규칙 자체를 어휘 단일 진실원(`ActionRegistry.battery_arms`)으로 올리고, 두 레인이
# **그 함수를 부르게** 한다. 이 게이트는 두 레인의 출력이 실제로 같은지를 잰다.
#
# 실행: julia +lts --project=. test/battery_menu_lanes_agree.jl
# =============================================================================
module BatteryMenuLanesAgree

using Test
using ConstructionBots
const CB = ConstructionBots
import HTTP, JSON3

const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))          # 실행 레인 + ActionRegistry

const THR = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end

"실행 레인의 메뉴(이름)."
live_menu(soc) = begin
    local truth = CB.BatteryTruth(CB.RobotID(3), soc)
    valid_macros(nothing, truth)
end

"어휘 단일 진실원이 말하는 메뉴(이름). 라벨 레인은 이것을 그대로 쓴다."
registry_menu(soc) =
    [ActionRegistry.NAME[i] for i in ActionRegistry.battery_arms(soc, THR, true)]

@testset "battery 메뉴: 실행 레인 == 어휘 단일 진실원" begin
    local saved = CB.BATTERY_FLEET[]
    try
        CB.BATTERY_FLEET[] = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(),
                                             Dict{Any,Float64}(), Dict{Any,Int}(), Set{Any}())
        for soc in (0.02, 0.10, THR, THR + 0.05, 0.45, 0.90)
            @test live_menu(soc) == registry_menu(soc)
        end
    finally
        CB.BATTERY_FLEET[] = saved
    end
end

@testset "분할이 실제로 무언가를 가른다" begin
    # 이 어서션이 없으면 위 등식은 "둘 다 언제나 전체 메뉴" 여도 초록이다 = 항진명제.
    local deep = ActionRegistry.battery_arms(0.02, THR, true)
    local mild = ActionRegistry.battery_arms(THR + 0.05, THR, true)
    @test deep != mild
    @test length(mild) < length(deep)
    # 분할을 끄면 상한이 그대로 나온다(`DS_BATTERY_SOC_SPLIT=0` 경로).
    @test ActionRegistry.battery_arms(THR + 0.05, THR, false) == ActionRegistry.kind_valid(:battery)
end

@testset "mild 는 닫힌 어휘에 수복이 없다 (zone 과 같은 취급)" begin
    # 설계 결정 2026-08-25(사용자). `soc > thr` 구간은 `reference_policy` 가 이미 **unscored** 로
    # 빼는 구간이다 = 이 어휘에 채점 근거가 있는 정답이 없다. 그런데 메뉴에는 `SwapBattery` 가
    # 남아 있어서, 정답이 없는 자리에서 정책이 계속 개입 팔을 골랐고 그 결정이 라벨로 남았다.
    # zone 과 같은 모양으로 맞춘다: 닫힌 어휘가 답할 수 없으면 메뉴는 **NOOP 하나**이고, 그것이
    # L2 제약 신설 레인이 인계받아야 한다는 표식이다.
    local mild = ActionRegistry.battery_arms(THR + 0.05, THR, true)
    local zone = sort(unique(vcat(0, ActionRegistry.kind_valid(:zone))))
    @test mild == zone                                  # 둘 다 NOOP-only
    @test !any(i -> ActionRegistry.COST[i] > 0.0, mild)  # 개입 팔이 하나도 없다
    # deep 은 그대로 개입 팔을 가진다 — 이 어서션이 없으면 위가 "전부 NOOP" 이어도 초록이다.
    @test any(i -> ActionRegistry.COST[i] > 0.0, ActionRegistry.battery_arms(0.02, THR, true))
end

end # module
