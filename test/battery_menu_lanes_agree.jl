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
# 🔴 **정정 (2026-09-01, S1 final wave / F-1c).** 이 파일 제목이 "라벨 레인과 실행 레인이
# 같은가" 라고 주장하지만, 오늘까지 이 파일은 **라벨 레인 함수(`ood_mdp_shim.valid_actions`)를
# 단 한 번도 호출하지 않았다** — `실행 레인 == 어휘 단일 진실원` 만 재고, "라벨 레인도 그
# 단일 진실원을 실제로 부른다"는 별개의 사실을 **가정**했다. final-review I-1 이 실측으로
# 증명했다: `valid_actions` 의 battery 분기에 `thr = max(0.2, Float64(CB.REPLACE_SOC_THRESHOLD[]))`
# 를 심어도(라벨 레인이 조용히 옛 0.2 경계로 돌아가는 자리) 이 파일은 물론 **전체 Julia
# 스위트가 2192/0/1 로 byte-identical** 이었다 — 라벨 레인 쪽엔 아무 방어가 없었다. 아래
# "battery 메뉴: 라벨 레인(valid_actions) == 어휘 단일 진실원 (F-1c)" testset이 그 빈 자리를
# 메운다 — `label_menu` 가 `ood_mdp_shim.valid_actions((type=:battery, soc=s))` 를 직접 부른다.
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
# 🔴 2026-09-01 (S1 final wave / F-1c). 라벨 레인 자체(`ood_mdp_shim.valid_actions`)도 로드한다
# -- 이 파일의 옛 이름("라벨 레인과 실행 레인의 battery 메뉴가 같은가")은 실행 레인
# (`policy.jl valid_macros`)과 **어휘 단일 진실원**(`ActionRegistry.battery_arms`)만 비교하고
# 라벨 레인 함수는 한 번도 부르지 않았다 -- final-review I-1 이 실측으로 증명했다: `thr =
# max(0.2, Float64(CB.REPLACE_SOC_THRESHOLD[]))` 를 `valid_actions` 의 battery 분기에 심어도
# 전체 스위트가 byte-identical 로 남았다(라벨 레인이 조용히 옛 0.2 경계로 돌아가도 아무것도
# 안 빨개졌다). `action_registry.jl` 은 위 `include` 가 이미 로드했으므로(`policy.jl` 이
# 자신의 위에서 로드) 이 include 는 그 위에 `event_context`/`valid_actions`/`canonical_action`/
# `action_to_proposal` 만 얹는다 -- `test/smdp_stamp_smoke.jl` 이 이미 쓰는 것과 같은 순서.
include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "ood_mdp_shim.jl"))

# navigator.jl 은 위에서 이미 로드를 보장했다(:27) — 심볼이 없으면 이제 UndefVarError 로
# 죽는다(2026-08-31 폴백 제거).
const THR = Float64(CB.REPLACE_SOC_THRESHOLD[])

"실행 레인의 메뉴(이름)."
live_menu(soc) = begin
    local truth = CB.BatteryTruth(CB.RobotID(3), soc)
    valid_macros(nothing, truth)
end

"어휘 단일 진실원이 말하는 메뉴(이름). 라벨 레인은 이것을 그대로 쓴다."
registry_menu(soc) =
    [ActionRegistry.NAME[i] for i in ActionRegistry.battery_arms(soc, THR, true)]

"라벨 레인 자신의 메뉴(이름) — `ood_mdp_shim.valid_actions` 를 직접 부른다(F-1c). `gen_oracle_dataset.jl`
이 라벨을 만들 때 실제로 부르는 그 함수다(`gen_oracle_dataset.jl:1928` 과 같은 NamedTuple 모양)."
label_menu(soc) =
    [ActionRegistry.NAME[i] for i in valid_actions((type = :battery, soc = soc))]

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

@testset "battery 메뉴: 라벨 레인(valid_actions) == 어휘 단일 진실원 (F-1c)" begin
    # 🔴 이 testset 이 없으면 이 파일의 제목("라벨 레인과 실행 레인이 같은가")이 거짓 광고다 —
    # 위 testset 은 라벨 레인을 한 번도 안 부른다. `DS_ARMS_LEGACY`/`DS_BATTERY_SOC_SPLIT`
    # 환경변수를 건드리지 않는 한 `valid_actions` 의 battery 분기는 `soc_split_enabled()==true`
    # 기본값으로 위 `registry_menu` 와 같은 조건(`split=true`)을 쓴다.
    for soc in (0.02, 0.10, THR, THR + 0.05, 0.45, 0.90)
        @test label_menu(soc) == registry_menu(soc)
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

# =============================================================================
# (4) soc 가 미기록이면 좁히지 않는다 — 2026-08-31 파일 정리로 `test/mild_menu_is_noop_only.jl`
# 에서 이 파일로 옮겨왔다.
#
# 원래 그 파일은 명제 넷을 재고 있었다: (1)(2) mild 구간의 메뉴가 정확히 `["NOOP"]` 이라는 것과
# 그 경계, (3) `DS_BATTERY_SOC_SPLIT` 손잡이 기본값. 사용자가 mild 를 "SwapBattery 하나만
# NOOP" 으로 두던 설계를 의도적으로 뒤집을 예정이라 — 배터리가 mild 하게 닳은 로봇이 가벼운
# 화물 조립으로 라우팅될 수 있어야 한다 — (1)(2)(3) 은 그 방향과 정면으로 충돌해서 파일째
# 지웠다. (4) 는 **무관하다**: 이것은 이 레포의 삼상 규약("못 쟀다 ≠ 0")이 배터리 메뉴에
# 적용된 자리다 — 잰 적 없는 SoC 를 근거로 로봇의 선택지를 조용히 좁히면 안 된다는 계약이고,
# mild 가 무엇이든(NOOP-only 로 남든 나중에 넓어지든) 계속 참이어야 한다.
#
# 변이시험(원본 파일 수정 라운드 2, 리뷰 Important 2-a 에서 실측): `battery_arms` 의
# `(soc isa Real && isfinite(soc)) || return up` 가드를 지우면 이 testset 이 빨개진다 — NaN 은
# `Float64(NaN) <= Float64(thr)` 에서 `false` 로 새서 mild 분기로 떨어지고, `nothing` 은
# `Float64(nothing)` 에서 아예 죽는다(`battery_arms` 의 docstring).
# =============================================================================
@testset "(4) soc 가 미기록이면 좁히지 않는다" begin
    @test length(ActionRegistry.battery_arms(NaN, THR, true)) > 1
    @test length(ActionRegistry.battery_arms(nothing, THR, true)) > 1
end

end # module
