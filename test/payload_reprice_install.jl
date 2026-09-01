# test/payload_reprice_install.jl
#   julia +lts --project=. test/payload_reprice_install.jl
module PayloadRepriceInstallTest
using Test
using ConstructionBots
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

@testset "함대가 없으면 설치하지 않는다" begin
    CB.BATTERY_FLEET[] = nothing
    r = CB.reprice_agent_by_payload!(nothing; agent = "BotID{DeliveryBot}(2)")
    @test r.status === :no_fleet
    @test r.installed === false
    @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing   # 🔴 실패했으면 훅을 안 남긴다
end

@testset "훅이 없을 때 배수는 1.0 이다 (음성 대조)" begin
    CB.PAYLOAD_BIAS[] = nothing
    @test CB.payload_edge_multiplier(nothing, nothing, 1, 2) == 1.0
end

@testset "clear_payload_bias! 는 SoC 훅을 건드리지 않는다" begin
    CB.EDGE_COST_MULTIPLIER[] = (sched, v) -> 3.0      # SoC 축이 꽂혀 있다고 가정
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> 2.0
    try
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 6.0
        CB.clear_payload_bias!()
        @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 3.0   # 🔴 SoC 항은 살아 있다
    finally
        CB.EDGE_COST_MULTIPLIER[] = nothing
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
        CB.PAYLOAD_BIAS[] = nothing
    end
end
end # module
