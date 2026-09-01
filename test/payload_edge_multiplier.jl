# test/payload_edge_multiplier.jl
#   julia +lts --project=. test/payload_edge_multiplier.jl
# 🔴 이 파일이 지키는 것은 두 가지다: (a) 훅이 없으면 3인자가 2인자와 **바이트 동일**,
#    (b) 훅이 꽂히면 v2 를 받아 곱해진다. (a) 가 깨지면 이 변경은 전역 회귀다.
module PayloadEdgeMultiplierTest
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "훅이 없으면 3인자 == 2인자 (바이트 동일)" begin
    CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    @test CB.edge_cost_multiplier(nothing, 1) == 1.0
    @test CB.edge_cost_multiplier(nothing, 1, 2) == CB.edge_cost_multiplier(nothing, 1)
end

@testset "훅이 꽂히면 곱해지고, 2인자는 안 변한다" begin
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> 2.5
    try
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 2.5
        @test CB.edge_cost_multiplier(nothing, 1) == 1.0
    finally
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    end
end

@testset "훅은 v2 를 실제로 받는다" begin
    seen = Tuple{Int,Int}[]
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> (push!(seen, (v, v2)); 1.0)
    try
        CB.edge_cost_multiplier(nothing, 7, 9)
        @test seen == [(7, 9)]
    finally
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    end
end
end # module
