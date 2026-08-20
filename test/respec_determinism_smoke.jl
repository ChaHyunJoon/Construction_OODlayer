# L5 — 런 간 재현성 결함. `Set` 순회 순서는 정의돼 있지 않아서, 같은 시드로도 고장 대상
# 로봇이 갈릴 수 있다. 여기서는 씬 전체를 만들지 않고 **순회 헬퍼 자체**를 검사한다 —
# 삽입 순서가 달라도 같은 순서를 내는가.
#
#   julia +lts --project=. test/respec_determinism_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

@testset "_ordered_active 는 삽입 순서에 무관하다" begin
    a = Set{Int}(); for v in [7, 3, 91, 12, 45]; push!(a, v); end
    b = Set{Int}(); for v in [45, 91, 12, 7, 3]; push!(b, v); end
    env_a = (cache = (active_set = a,),)
    env_b = (cache = (active_set = b,),)
    @test CB._ordered_active(env_a) == CB._ordered_active(env_b)
    @test CB._ordered_active(env_a) == [3, 7, 12, 45, 91]
end

@testset "빈 집합은 빈 벡터" begin
    @test CB._ordered_active((cache = (active_set = Set{Int}(),),)) == Int[]
end
