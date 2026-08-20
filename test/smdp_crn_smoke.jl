# CRN(공통난수) 무결성. spec §5.7 이 지목한 누수: _hz_fire_cell! 이 안전 가드보다 **먼저**
# drop 을 뽑아서, 유예되면 그 뽑기가 소비된 채 버려진다. 팔마다 유예 여부가 다르면 그
# 로봇 스트림의 뽑기 횟수가 갈리고, 이후 모든 난수가 어긋나 짝지은 비교가 무너진다.
#
#   julia +lts --project=. test/smdp_crn_smoke.jl
using ConstructionBots
using Test
using Random
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_mk(; seed = 0, kw...) = CB._new_hazard_state(CB.HazardParams(; kw...), seed)

@testset "유예는 로봇 스트림을 소비하지 않는다" begin
    # 같은 시드로 상태 둘을 만들고, 한쪽에서만 셀 사건이 한 번 유예되게 한다.
    # 유예 뒤 두 스트림에서 각각 뽑은 수열이 같아야 CRN 이 살아 있는 것이다.
    st_a = _mk(seed = 7)
    st_b = _mk(seed = 7)
    rid = 101

    # 유예 경로를 직접 태운다: BATTERY_FLEET 가 nothing 이면 조기 반환이라 뽑기 전에 나간다.
    # 그래서 낙폭 캐시 자체를 검사한다 — 두 번 부르면 캐시가 재사용돼 뽑기가 한 번만 일어난다.
    d1 = CB._hz_draw_cell_drop!(st_a, rid)
    d2 = CB._hz_draw_cell_drop!(st_a, rid)      # 유예 후 재시도 — 같은 낙폭이어야 한다
    @test d1 == d2

    # 한 번만 뽑은 st_b 와 스트림 위치가 같아야 한다(= 재시도가 스트림을 안 먹었다).
    _ = CB._hz_draw_cell_drop!(st_b, rid)
    @test rand(CB._robot_rng(st_a, rid)) == rand(CB._robot_rng(st_b, rid))
end

@testset "발화가 성사되면 캐시가 비워진다" begin
    st = _mk(seed = 11)
    rid = 202
    d1 = CB._hz_draw_cell_drop!(st, rid)
    @test haskey(st.pending_drop, rid)
    CB._hz_commit_cell_drop!(st, rid)
    @test !haskey(st.pending_drop, rid)
    d2 = CB._hz_draw_cell_drop!(st, rid)        # 다음 사건은 새로 뽑는다
    @test d2 isa Float64
end

println("\nsmdp_crn_smoke: ALL PASS")
