# test/smdp_simstate_fields.jl
# 7필드 s 의 필드 민감도. **모든** 필드가 해시에 닿아야 한다 — 안 닿는 필드는 그 자리에서
# 조용히 두 세계를 합친다. 그리고 **지운 필드가 정말 지워졌는지**를 음성 대조로 못박는다:
# 옛 이름으로 생성자를 부르면 죽어야 한다. 안 죽으면 축소가 안 된 것이다.
#   julia +lts --project=. test/smdp_simstate_fields.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; soc = 0.9, usage_s = 12.5) = CB.RobotRec(; soc = soc, usage_s = usage_s)

function _s(; kw...)
    base = (g   = CB.GraphBlock(edges = Set([(1, 2)]), binding = Dict(1 => 7)),
            geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                              zones = Dict(:z1 => (1.0, 2.0, 0.5))),
            fleet = Dict(7 => _rec()),
            prog  = CB.ProgBlock(closed = Set([1])))
    return CB.SimState(; merge(base, NamedTuple(kw))...)
end

@testset "일곱 필드가 전부 해시에 닿는다" begin
    h0 = CB.state_hash(_s())
    @test CB.state_hash(_s(g = CB.GraphBlock(edges = Set([(1, 3)]),
                                             binding = Dict(1 => 7)))) != h0
    @test CB.state_hash(_s(g = CB.GraphBlock(edges = Set([(1, 2)]),
                                             binding = Dict(1 => 8)))) != h0
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 1.0)),
                                             zones = Dict(:z1 => (1.0, 2.0, 0.5))))) != h0
    # zones 는 **기하까지** 나른다 — 이름이 같고 반지름이 다르면 다른 상태다
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                             zones = Dict(:z1 => (1.0, 2.0, 0.9))))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(soc = 0.8))))      != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(usage_s = 99.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(closed = Set([1, 2])))) != h0
end

@testset "🔴 음성 대조 — 지운 필드는 정말 지워졌다" begin
    # 옛 필드 이름으로 생성자를 부르면 죽어야 한다. 살아 있으면 축소가 안 된 것이다.
    @test_throws MethodError CB.RobotRec(soc = 0.9, usage_s = 1.0, eff = 1.0)
    @test_throws MethodError CB.RobotRec(soc = 0.9, usage_s = 1.0, mode = :transit)
    @test_throws MethodError CB.GeoBlock(poses = Dict{Int,NTuple{3,Float64}}(),
                                         zones = Dict{Symbol,NTuple{3,Float64}}(),
                                         build_delta = (0.0, 0.0))
    @test_throws MethodError CB.GraphBlock(edges = Set{Tuple{Int,Int}}(),
                                           binding = Dict{Int,Int}(),
                                           wedge_edges = Set{Tuple{Int,Int}}())
    @test_throws MethodError CB.ProgBlock(closed = Set{Int}(), t = 0.0)
    # CourierRec 타입 자체가 없다
    @test !isdefined(CB, :CourierRec)
end

@testset "omit 은 네 블록만 받는다" begin
    a = _s(); b = _s(prog = CB.ProgBlock(closed = Set([1, 2])))
    @test CB.state_hash(a) != CB.state_hash(b)
    @test CB.state_hash(a; omit = Set([:prog])) == CB.state_hash(b; omit = Set([:prog]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:courier]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:porg]))
end

@testset "정준 직렬화가 순서에 무관하다" begin
    a = CB.SimState(g = CB.GraphBlock(edges = Set([(1, 2), (3, 4)]),
                                      binding = Dict(1 => 7, 2 => 8)),
                    geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                      zones = Dict(:z1 => (1.0, 2.0, 0.5))),
                    fleet = Dict(7 => _rec(), 8 => _rec(soc = 0.5)),
                    prog = CB.ProgBlock(closed = Set([1])))
    b = CB.SimState(g = CB.GraphBlock(edges = Set([(3, 4), (1, 2)]),
                                      binding = Dict(2 => 8, 1 => 7)),
                    geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                      zones = Dict(:z1 => (1.0, 2.0, 0.5))),
                    fleet = Dict(8 => _rec(soc = 0.5), 7 => _rec()),
                    prog = CB.ProgBlock(closed = Set([1])))
    @test CB.state_hash(a) == CB.state_hash(b)
end
