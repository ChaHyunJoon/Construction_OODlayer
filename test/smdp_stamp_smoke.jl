# test/smdp_stamp_smoke.jl
# 도장 계약의 Julia 쪽. Python 과 **같은 문자열**을 읽는지, 그리고 도장 없는 입력에서
# 정말 죽는지(음성 대조)를 본다.
#   julia +lts --project=. test/smdp_stamp_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

@testset "어휘 도장" begin
    @test ActionRegistry.VOCAB == "v2-6arms"
    @test ActionRegistry.require_vocab(Dict("vocab" => "v2-6arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v1-9arms"), "구세대")
end

@testset "동역학 도장" begin
    CB.disable_hazard!()
    @test CB.dynamics_stamp() == "hazard-off"
end
