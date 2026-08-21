# test/smdp_simstate_fields.jl
# 26필드 s 의 필드 민감도. **모든** 필드가 해시에 닿아야 한다 — 안 닿는 필드는 그 자리에서
# 조용히 두 세계를 합친다.
#   julia +lts --project=. test/smdp_simstate_fields.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; kw...) = CB.RobotRec(; pose = (0.0, 0.0, 0.0), soc = 0.9, health = :healthy,
                              payload = nothing, role = :idle,
                              usage_s = 12.5, mode = :transit, eff = 1.03, kw...)

function _s(; kw...)
    base = (g   = CB.GraphBlock(edges = Set([(1, 2)]), binding = Dict(1 => 7),
                                wedge_edges = Set{Tuple{Int,Int}}(),
                                dissolved_gates = Set{Tuple{Int,Int}}()),
            geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)), build_delta = (0.0, 0.0),
                              zones = Dict(:z1 => (1.0, 2.0, 0.5))),
            fleet = Dict(7 => _rec()),
            prog  = CB.ProgBlock(t = 3.25, closed = Set([1]), active = Dict(2 => 3.0)),
            courier = CB.CourierRec[])
    return CB.SimState(; merge(base, NamedTuple(kw))...)
end

@testset "새 필드 넷이 해시에 닿는다" begin
    h0 = CB.state_hash(_s())
    # zones 는 **기하까지** 나른다 — 이름이 같고 반지름이 다르면 다른 상태다
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
              build_delta = (0.0, 0.0), zones = Dict(:z1 => (1.0, 2.0, 0.9))))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(usage_s = 99.0)))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(mode = :carry))))  != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(eff = 1.04))))     != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.26, closed = Set([1]),
                                               active = Dict(2 => 3.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.25, closed = Set([1, 2]),
                                               active = Dict(2 => 3.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.25, closed = Set([1]),
                                               active = Dict(2 => 3.5)))) != h0
end

@testset "omit 에 :prog 를 넣을 수 있다" begin
    a = _s(); b = _s(prog = CB.ProgBlock(t = 99.0, closed = Set([1]), active = Dict(2 => 3.0)))
    @test CB.state_hash(a) != CB.state_hash(b)
    @test CB.state_hash(a; omit = Set([:prog])) == CB.state_hash(b; omit = Set([:prog]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:porg]))
end

@testset "courier 는 절대 시각을 든다" begin
    c(t) = CB.CourierRec(target = 1, courier = 2, depot = :d, home = (0.0, 0.0),
                         goal = (1.0, 1.0), phase = :outbound, t_out = t, t_swap = 9.0)
    @test CB.state_hash(_s(courier = [c(1.0)])) != CB.state_hash(_s(courier = [c(2.0)]))
end
