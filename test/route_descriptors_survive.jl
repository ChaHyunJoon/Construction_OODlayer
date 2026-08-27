# =============================================================================
# 교정 파일이 없어도 **서술자는 산다** 를 못박는다.
#
# 왜 (2026-08-26 실측): `route()` 의 `!have_det` 조기 반환이 `descriptors` 키 없이 Dict 를
# 돌려주고, 서술자를 계산하는 `event_descriptors_of` 는 그 반환 **뒤에** 있었다. 교정 파일
# 디렉토리가 아예 없으므로 **모든 LLM 결정이 문장 한 줄로 내려졌다** — surrogate 는 피처를
# 받는데 LLM 은 못 받는 비대칭 비교였다.
#
# 실행: julia +lts --project=. test/route_descriptors_survive.jl
# =============================================================================
module RouteDescriptorsSurvive

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

const DESC = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60]

@testset "서술자는 라우팅 게이트와 독립이다" begin
    # (A) 교정 없음 = 라우터 비활성. 그래도 서술자는 실려야 한다.
    d = route_verdict(desc = DESC, have_det = false, drives = false, policy = "dspy")
    @test haskey(d, "descriptors")
    @test d["descriptors"] == DESC
    @test d["enabled"] == false
    @test d["target"] == "dspy"

    # (B) 서술자 계산 자체가 실패한 경우는 nothing 이 실린다 — 키를 지우지 않는다.
    #     "못 쟀다" 와 "안 실었다" 를 구분할 수 있어야 한다.
    d2 = route_verdict(desc = nothing, have_det = false, drives = false, policy = "dspy")
    @test haskey(d2, "descriptors")
    @test d2["descriptors"] === nothing

    # (C) 모든 반환 분기가 같은 키 집합을 갖는다 — 분기마다 키가 다르면 소비처가 깨진다.
    d3 = route_verdict(desc = DESC, have_det = true, drives = true, policy = "dspy",
                       v = (novel = true, p = 0.01, score = 2.0), eps = 0.05)
    @test haskey(d3, "descriptors")
    @test d3["descriptors"] == DESC
    @test d3["enabled"] == true
end

end # module
