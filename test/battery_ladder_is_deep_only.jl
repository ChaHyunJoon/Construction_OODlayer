# =============================================================================
# **DS_BSOC 기본 사다리의 모든 칸이 채점 가능한 deep 구간에 있는가** — 계약을 못박는다.
#
# 왜 (2026-08-25 사용자 결정)
# ---------------------------
# mild(`soc > REPLACE_SOC_THRESHOLD`)는 이제 닫힌 어휘에 수복이 없다고 선언했고
# (`ActionRegistry.battery_arms` -> `[NOOP]`), 그 자리는 zone 과 같은 **L2 제약 신설 레인**의
# 대상이다. 그러면 라벨 격자에 mild 칸을 남길 이유가 없다:
#   · 후보가 NOOP 하나뿐인 에피소드 = **대조가 0인 행**. 팔을 비교할 수 없으니 정보가 없다.
#   · `reference_policy` 가 그 구간을 이미 `None`(unscored) 로 뺀다.
# 2026-08-24 에 같은 이유로 `zoneblk` 를 `DS_EP_KINDS` 기본값에서 뺐다 — 이 게이트는 battery
# 축에서 그 결정을 지킨다.
#
# 🔴 그렇다고 칸을 하나로 줄이면 **2026-08-05 에 고친 결함이 재현된다**("심각도 축이 사실상
# 점 하나"). 그래서 두 번째 어서션이 있다: 사다리는 deep 안에서 **거동이 실제로 갈리는**
# 두 구간을 걸쳐야 한다. 실측(2026-08-25 당시, DS_STALL=0.15 / deep=0.2 / DS_DERATE_HI=0.5):
#     soc <= 0.15        -> 속도배율 0.0    즉시 정지
#     0.15 < soc <= 0.2  -> 속도배율 ~0.41  감속하며 계속 일함
# 🔴 2026-08-31 (S1/T3): 사다리 이동 뒤 값은 DS_STALL=0.05 / deep=0.1 이고, 기본 DS_BSOC 도
#    "0.02,0.09" 로 옮겨져 같은 두 구간(즉시 정지 / 감속하며 계속 일함)을 새 경계에서 다시
#    걸친다 — 숫자만 바뀌었고 이 testset 이 지키는 명제는 그대로다.
#
# 기본값을 소스에서 **정규식으로 직접 읽는다** — `gen_oracle_dataset.jl` 은 스크립트라
# include 할 수 없다. `tools/test_policy_oracle.jl` 0절이 `reference_policy.py` 를 같은 방식으로
# 읽어 두 언어의 상수를 묶는다(이 레포의 기존 규약).
#
# 실행: julia +lts --project=. test/battery_ladder_is_deep_only.jl
# =============================================================================
module BatteryLadderIsDeepOnly

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryFleet) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

const GEN = joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "gen_oracle_dataset.jl")
const THR = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.1 end

"소스에서 `DS_BSOC` 기본 사다리를 읽는다."
function default_ladder()
    m = match(r"get\(ENV,\s*\"DS_BSOC\",\s*\"([^\"]*)\"\)", read(GEN, String))
    m === nothing && error("gen_oracle_dataset.jl 에서 DS_BSOC 기본값을 못 찾았다 — 정규식을 고칠 것")
    return [parse(Float64, strip(x)) for x in split(m.captures[1], ",")]
end

@testset "DS_BSOC 기본 사다리" begin
    local ladder = default_ladder()
    println("    기본 사다리 = ", ladder, "  (임계값 thr=", THR, ")")

    @testset "모든 칸이 deep = 팔을 비교할 수 있다" begin
        for s in ladder
            local arms = ActionRegistry.battery_arms(s, THR, true)
            # 대조가 0인 행(후보 하나)을 라벨 격자에 넣지 않는다.
            @test length(arms) > 1
            @test s <= THR
        end
    end

    @testset "심각도 축이 점 하나가 아니다 (2026-08-05 회귀 방지)" begin
        # DS_STALL 기본값(2026-08-31 이후 0.05, 옛 값 0.15)을 소스에서 읽는다 — 여기 숫자를
        # 박으면 두 번째 진실원이 된다.
        local ms = match(r"get\(ENV,\s*\"DS_STALL\",\s*\"([^\"]*)\"\)", read(GEN, String))
        @test ms !== nothing
        local stall = parse(Float64, ms.captures[1])
        # 정지하는 칸과, 정지하지 않고 감속만 하는 칸이 **둘 다** 있어야 한다.
        @test any(s -> s <= stall, ladder)
        @test any(s -> s > stall, ladder)
    end
end

end # module
