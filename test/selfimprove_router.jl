# selfimprove 라우터 (spec §5.3, U1): zone 은 접두사 없는 "zone" — 학습되면 surrogate 로 간다.
# 실행: julia +lts --project=. test/selfimprove_router.jl
module SelfimproveRouter
using Test
include(joinpath(@__DIR__, "..", "tools", "monitor", "lane_select.jl"))
@testset "selfimprove router" begin
    @test routing_kind("ZoneTruth") == "zone"                      # U1
    @test defer_axis("DEFER:low_confidence:0.4000") == "low_confidence"
    @test defer_axis("DEFER:no_arm") == "no_arm"
    @test defer_axis("UNSUPPORTED:Replace") === nothing            # 계속 죽는다
    @test select_lane(kind = "zone", known_kinds = ["battery", "fault"], policy = "router").lane == "dspy"
    @test select_lane(kind = "zone", known_kinds = ["battery", "fault", "zone"], policy = "router").lane == "surrogate"
end
end # module
