# test/smdp_simstate_smoke.jl
# spec §3 — s 는 콘텐츠 해시가 가능해야 한다. 그 성질이 깨지는 방식은 둘뿐이다:
#   (1) 불투명 객체(MersenneTwister·RVO 핸들)가 s 안에 있다 → ξ 로 빼서 막는다
#   (2) Set/Dict 순회 순서가 직렬화에 새어든다 → 정렬 직렬화로 막는다
#
# 리뷰 라운드 1 (task-9-review.md) 이 이 파일의 첫 버전에서 2 Critical + 4 Important 를 잡았다.
# 각 수정마다 그 항목 번호를 testset 이름에 남긴다.
#
#   julia +lts --project=. test/smdp_simstate_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(id; soc = 1.0, usage = 0.0) = CB.RobotRec(
    id = id, pose = (1.0, 2.0, 0.5), vel = (0.0, 0.0), soc = soc,
    energy_J = 10.0, usage_s = usage, eff = 1.0, health = :healthy,
    stalled = false, payload = nothing, role = :transport)

function _state(; robots = [1, 2, 3], no_progress = 0, snap = 0, zones = [:z1],
                 socs = Dict{Int,Float64}(), clock_t = 1.0, clock_step = 40,
                 couriers = CB.CourierRec[], fleet_override = nothing)
    fleet = fleet_override === nothing ? Dict(r => _rec(r; soc = get(socs, r, 1.0)) for r in robots) :
                                          fleet_override
    CB.SimState(
        g = CB.GraphBlock(n_nodes = 5, edges = Set([(1, 2), (2, 3), (3, 4), (4, 5)]),
                          closed = Set([1, 2]), active = Set([3]),
                          binding = Dict(3 => 1), edge_bias = Dict((1, 2) => 1.5),
                          wedge_edges = Set([(1, 3)]), dissolved_gates = Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = Set(zones),
                          build_delta = (0.0, 0.0)),
        fleet = fleet,
        hazard = CB.HazardBlock(lambda0 = Dict(r => 1.0e-4 for r in keys(fleet)),
                                mode = :nominal, broken = Set{Int}(),
                                expired_break = Set{Int}(), expired_cell = Set{Int}()),
        courier = couriers, clock = CB.ClockBlock(t = clock_t, step = clock_step),
        age = CB.AgeBlock(no_progress = no_progress, snap_count = snap),
        event = CB.EventBlock(kind = :battery, robot = 1, severity = 0.3))
end

# --- C-1 헬퍼: 10원소 컬렉션을 두 삽입 순서로 실제로 push!/dict-insert 해서 만든다.
# 3원소 Set/Dict 는 삽입 순서와 무관하게 내부 반복 순서가 이미 같아서(측정됨), sort! 를
# 지워도 그 크기에서는 절대 안 걸린다 — 리뷰가 잡은 바로 그 결함. 10원소로 올린다
# (측정: 10+ 에서 순서가 실제로 갈린다).
# **콘텐츠는 고정하고 삽입 순서만 바꾼다** — 두 상태가 "같은 원소를 다른 순서로 넣은 것"이어야
# 순서-무관성 테스트가 된다.
function _big_state(order::Symbol)
    # 순차 정수(1..12)는 Julia 의 Int 해시가 버킷을 조밀하게 채워, 삽입 순서와 무관하게
    # 반복 순서가 이미 같다(실측 — sequential Set{Int}/Dict{Int,_} 는 정렬을 지워도 안 갈린다).
    # 흩어진 정수(리뷰의 실측 예)라야 삽입 순서가 실제로 버킷 배치에 남는다 — 다만 **단순
    # `reverse()` 조차 우연히 같은 최종 버킷 배치로 귀결될 수 있다**(실측: 흩어진 12원소
    # 리스트로 시험 삼아 만든 forward/reverse 쌍이 같은 반복 순서를 냈다 — 삽입 이력 전체가
    # 최종 레이아웃을 정하지, "반대 순서" 라는 사실 자체가 발산을 보장하지 않는다). 그래서
    # order_a/order_b 는 reverse() 파생이 아니라, Set{Int}·Dict{Int,_} 양쪽에서 **실제로
    # 반복 순서가 다르다고 개별 실측한** 두 순열을 그대로 쓴다.
    order_a = [5, 101, 7, 11, 2, 44, 63, 8, 3, 19]
    order_b = [5, 19, 63, 2, 44, 11, 7, 8, 3, 101]   # order_a 와 같은 원소, 다른 삽입 순서
    ids = order == :fwd ? order_a : order_b
    sorted_ids = sort(order_a)
    content_edges = [(sorted_ids[i], sorted_ids[i + 1]) for i in 1:(length(sorted_ids) - 1)]
    edg = order == :fwd ? content_edges : reverse(content_edges)   # 튜플 Set 은 단순 reverse()
                                                                     # 로도 실제 발산이 실측됐다

    edges = Set{Tuple{Int,Int}}()
    for e in edg
        push!(edges, e)
    end
    closed = Set{Int}()
    active = Set{Int}()
    for i in ids
        push!(closed, i)
        push!(active, i + 100)
    end
    binding = Dict{Int,Int}()
    for i in ids
        binding[i] = i + 1000
    end
    edge_bias = Dict{Tuple{Int,Int},Float64}()
    for (u, v) in edg
        edge_bias[(u, v)] = 1.0 + 0.01 * u
    end
    g = CB.GraphBlock(n_nodes = length(ids) + 1, edges = edges, closed = closed, active = active,
                       binding = binding, edge_bias = edge_bias,
                       wedge_edges = Set([(1, 3)]), dissolved_gates = Set{Tuple{Int,Int}}())

    poses = Dict{Int,NTuple{3,Float64}}()
    zones = Set{Symbol}()
    for i in ids
        poses[i] = (Float64(i), Float64(i), Float64(i))
        push!(zones, Symbol("z$i"))
    end
    geo = CB.GeoBlock(poses = poses, zones = zones, build_delta = (0.0, 0.0))

    fleet = Dict{Int,CB.RobotRec}()
    lambda0 = Dict{Int,Float64}()
    broken = Set{Int}()
    for i in ids
        fleet[i] = _rec(i)
        lambda0[i] = 1.0e-4 * i
        push!(broken, i)
    end
    hazard = CB.HazardBlock(lambda0 = lambda0, mode = :nominal, broken = broken,
                            expired_break = Set{Int}(), expired_cell = Set{Int}())

    CB.SimState(g = g, geo = geo, fleet = fleet, hazard = hazard, courier = CB.CourierRec[],
                clock = CB.ClockBlock(t = 1.0, step = 40), age = CB.AgeBlock(no_progress = 0, snap_count = 0),
                event = CB.EventBlock(kind = :battery, robot = 1, severity = 0.3))
end

@testset "정준 직렬화는 삽입 순서에 무관하다 — 10원소 (C-1 수정)" begin
    a = _big_state(:fwd)
    b = _big_state(:rev)
    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)
end

@testset "courier 벡터도 삽입 순서에 무관하다" begin
    c1 = CB.CourierRec(target = 1, courier = 10, depot = :north, home = (0.0, 0.0),
                        goal = (1.0, 1.0), phase = :outbound, step_out = 5, step_swap = 0)
    c2 = CB.CourierRec(target = 2, courier = 11, depot = :south, home = (2.0, 2.0),
                        goal = (3.0, 3.0), phase = :returning, step_out = 8, step_swap = 12)
    a = _state(couriers = [c1, c2])
    b = _state(couriers = [c2, c1])
    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)
end

@testset "courier 정렬 키는 total order 다 — (target,courier) 가 같아도 순서 무관 (I-2 수정)" begin
    # 두 레코드가 정렬 키로 쓰이던 (target, courier) 를 공유한다. 옛 `by = c -> (c.target,
    # c.courier)` 는 total order 가 아니라서 이 경우 Julia 의 안정 정렬이 삽입 순서를 그대로
    # 내보냈다(측정됨). `by = canonical` 은 레코드 전체가 키라 total order 다.
    c1 = CB.CourierRec(target = 1, courier = 10, depot = :north, home = (0.0, 0.0),
                        goal = (1.0, 1.0), phase = :outbound, step_out = 5, step_swap = 0)
    c2 = CB.CourierRec(target = 1, courier = 10, depot = :south, home = (2.0, 2.0),
                        goal = (3.0, 3.0), phase = :returning, step_out = 8, step_swap = 12)
    a = _state(couriers = [c1, c2])
    b = _state(couriers = [c2, c1])
    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)
end

@testset "s 가 다르면 해시가 다르다 (항진명제 — 해롭지 않으나 민감도 근거로 쓰지 않는다)" begin
    @test CB.state_hash(_state(no_progress = 119)) != CB.state_hash(_state(no_progress = 120))
    @test CB.state_hash(_state(snap = 2)) != CB.state_hash(_state(snap = 3))
end

@testset "s 가 다르면 해시가 다르다 (실질 필드 — 실패할 수 있는 테스트)" begin
    a = _state(robots = [1, 2, 3])
    b = _state(robots = [1, 2, 3], socs = Dict(2 => 0.42))
    @test CB.canonical(a) != CB.canonical(b)
    @test CB.state_hash(a) != CB.state_hash(b)
end

@testset "Age 블록이 s 안에 있다 — C1 위반을 잡는 그 변수다" begin
    txt = CB.canonical(_state(no_progress = 120, snap = 3))
    @test occursin("no_progress=120", txt)
    @test occursin("snap_count=3", txt)
end

@testset "ξ 는 s 안에 없다 — 불투명 객체 금지" begin
    txt = CB.canonical(_state())
    @test !occursin("MersenneTwister", txt)
    @test !occursin("cum_", txt)      # 무기억성: cum 은 미래에 정보를 안 나른다 (spec §3.4)
    @test !occursin("thr_", txt)      # thr 을 넣으면 발화 시각이 결정론이 된다
end

@testset "expired 는 값이 아니라 불리언이다 (spec §3.4 예외)" begin
    h0 = CB.HazardBlock(lambda0 = Dict(1 => 1.0e-4), mode = :nominal, broken = Set{Int}(),
                        expired_break = Set([1]), expired_cell = Set{Int}())
    h1 = CB.HazardBlock(lambda0 = Dict(1 => 1.0e-4), mode = :nominal, broken = Set{Int}(),
                        expired_break = Set{Int}(), expired_cell = Set{Int}())
    @test CB.canonical(h0) != CB.canonical(h1)
    @test occursin("expired_break=[1]", CB.canonical(h0))
end

@testset "해시는 32자 hex" begin
    h = CB.state_hash(_state())
    @test length(h) == 32 && all(c -> c in "0123456789abcdef", h)
end

@testset "canonical 은 블록별로 합성 가능하다 — clock 을 빼고 해시할 수 있다 (부칙 B5)" begin
    a = _state(clock_t = 1.0, clock_step = 40)
    b = _state(clock_t = 99.0, clock_step = 4000)   # clock 만 다르고 나머지는 동일
    @test CB.canonical(a) != CB.canonical(b)                              # 전체는 다르다
    @test CB.state_hash(a) != CB.state_hash(b)
    @test CB.canonical(a; omit = Set([:clock])) == CB.canonical(b; omit = Set([:clock]))
    @test CB.state_hash(a; omit = Set([:clock])) == CB.state_hash(b; omit = Set([:clock]))
end

@testset "omit 은 알 수 없는 블록 이름을 조용히 무시하지 않는다 (M-1 수정)" begin
    s = _state()
    @test_throws Exception CB.canonical(s; omit = Set([:clok]))
    @test_throws Exception CB.state_hash(s; omit = Set([:clok]))
end

@testset "delimiter injection — 오염된 role 이 1로봇 fleet 을 2로봇 fleet 으로 위조하지 못한다 (C-2 수정)" begin
    # 리뷰가 찾은 가장 강한 사례: role::Symbol 에 두 번째 로봇 레코드 텍스트 전체(세미콜론 포함)를
    # 심으면, 이스케이프 없는 직렬화에서는 진짜 2로봇 fleet 과 문자열이 같아졌다.
    tail = "transport);R99(pose=(0.0,0.0,0.0),vel=(0.0,0.0),soc=1.0,E=10.0,usage=0.0,eff=1.0," *
           "health=healthy,stalled=false,payload=nothing,role=transport"
    poisoned = Dict(1 => CB.RobotRec(id = 1, pose = (1.0, 2.0, 0.5), vel = (0.0, 0.0), soc = 1.0,
                                      energy_J = 10.0, usage_s = 0.0, eff = 1.0, health = :healthy,
                                      stalled = false, payload = nothing, role = Symbol(tail)))
    clean = Dict(1 => _rec(1), 99 => _rec(99))
    a = _state(fleet_override = poisoned)
    b = _state(fleet_override = clean)
    @test CB.canonical(a) != CB.canonical(b)
    @test CB.state_hash(a) != CB.state_hash(b)
end

@testset "delimiter injection — 쉼표를 담은 Symbol 이 두 zone 을 위조하지 못한다 (C-2 수정)" begin
    a = _state(zones = [Symbol("z1,z2")])
    b = _state(zones = [:z1, :z2])
    @test CB.canonical(a) != CB.canonical(b)
    @test CB.state_hash(a) != CB.state_hash(b)
end

@testset "delimiter injection — 빈 문자열 Symbol 이 빈 집합을 위조하지 못한다 (C-2 수정)" begin
    a = _state(zones = [Symbol("")])
    b = _state(zones = Symbol[])
    @test CB.canonical(a) != CB.canonical(b)
    @test CB.state_hash(a) != CB.state_hash(b)
end

@testset "부호 있는 0 은 해시를 가르지 않는다 (I-1 수정)" begin
    # round(-1e-12; digits=9) 가 관측 가능한 -0.0 을 만들어낸다 — -0.0 == 0.0 인데 string 은
    # 다르게 찍어서, vel/pose/build_delta 처럼 float 연산에서 나온 값이 노이즈 이하 부호 차이로
    # 해시를 가른다(리뷰 측정).
    @test CB._c(-0.0) == CB._c(0.0)
    @test CB._c(-1.0e-12) == CB._c(1.0e-12)

    r_pos = _rec(1)
    r_neg = CB.RobotRec(id = 1, pose = (1.0, 2.0, 0.5), vel = (-0.0, 0.0), soc = 1.0,
                         energy_J = 10.0, usage_s = 0.0, eff = 1.0, health = :healthy,
                         stalled = false, payload = nothing, role = :transport)
    @test CB.canonical(r_pos) == CB.canonical(r_neg)

    g_pos = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = Set([:z1]), build_delta = (0.0, 0.0))
    g_neg = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = Set([:z1]), build_delta = (-0.0, 0.0))
    @test CB.canonical(g_pos) == CB.canonical(g_neg)
end

@testset "fleet dict 키는 rec.id 와 반드시 같아야 한다 — 깨지면 죽는다 (I-3 수정)" begin
    bad_fleet = Dict(1 => _rec(2))   # key=1 인데 rec.id=2
    bad_state = _state(fleet_override = bad_fleet)
    @test_throws Exception CB.canonical(bad_state)
    @test_throws Exception CB.state_hash(bad_state)
end

# --- I-4 수정: 자식 프로세스가 canonical 문자열을 건네받아 sha256 만 다시 도는 것은 sha256 이
# 프로세스 불변이라는 사실만 재확인할 뿐 canonical(s) 자체의 안정성은 묻지 않는다(리뷰가 잡은
# 항진명제). 이제 자식이 **직접** SimState 를 재구성하고 state_hash 를 스스로 계산한다.
@testset "해시는 한 작업 트리 안에서 프로세스에 걸쳐 안정적이다 (I-4 수정 — 자식이 직접 재구성)" begin
    h_here = CB.state_hash(_state(no_progress = 7, snap = 1))
    proj = joinpath(@__DIR__, "..")
    code = """
    import ConstructionBots as CB
    CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
    CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
    rec(id) = CB.RobotRec(id=id, pose=(1.0,2.0,0.5), vel=(0.0,0.0), soc=1.0, energy_J=10.0,
                           usage_s=0.0, eff=1.0, health=:healthy, stalled=false, payload=nothing,
                           role=:transport)
    s = CB.SimState(
        g = CB.GraphBlock(n_nodes=5, edges=Set([(1,2),(2,3),(3,4),(4,5)]), closed=Set([1,2]),
                           active=Set([3]), binding=Dict(3=>1), edge_bias=Dict((1,2)=>1.5),
                           wedge_edges=Set([(1,3)]), dissolved_gates=Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses=Dict(10=>(0.0,0.0,0.0)), zones=Set([:z1]), build_delta=(0.0,0.0)),
        fleet = Dict(r => rec(r) for r in [1,2,3]),
        hazard = CB.HazardBlock(lambda0=Dict(r=>1.0e-4 for r in [1,2,3]), mode=:nominal,
                                 broken=Set{Int}(), expired_break=Set{Int}(), expired_cell=Set{Int}()),
        courier = CB.CourierRec[], clock = CB.ClockBlock(t=1.0, step=40),
        age = CB.AgeBlock(no_progress=7, snap_count=1),
        event = CB.EventBlock(kind=:battery, robot=1, severity=0.3))
    println(CB.state_hash(s))
    """
    out = read(`julia +lts --project=$proj -e $code`, String)
    @test strip(out) == h_here
end

# --- I-1/coverage: base/alt 블록 인스턴스를 한 필드씩 섞어서(hybrid) state_hash 가 바뀌는지
# 본다. 이전 버전은 손으로 4/42 만 짚었다(soc, expired_break, no_progress, snap_count) — 나머지
# 38개는 canonical 에서 지워도 그 4개짜리 고정 fixture 로는 못 잡았다. 루프로 42/42 를 덮는다.
_hybrid(base::T, alt::T, field::Symbol) where {T} =
    T(; Dict{Symbol,Any}(f => (f === field ? getfield(alt, f) : getfield(base, f))
                          for f in fieldnames(T))...)

@testset "필드 민감도 — 8블록 42필드 전부가 해시를 바꾼다 (커버리지 4/42 → 42/42)" begin
    g_base = CB.GraphBlock(n_nodes = 5, edges = Set([(1, 2), (2, 3)]), closed = Set([1]),
                            active = Set([2]), binding = Dict(1 => 1), edge_bias = Dict((1, 2) => 1.0),
                            wedge_edges = Set{Tuple{Int,Int}}(), dissolved_gates = Set{Tuple{Int,Int}}())
    g_alt = CB.GraphBlock(n_nodes = 9, edges = Set([(9, 9)]), closed = Set([9]),
                           active = Set([9]), binding = Dict(9 => 9), edge_bias = Dict((9, 9) => 9.9),
                           wedge_edges = Set([(9, 9)]), dissolved_gates = Set([(9, 9)]))

    geo_base = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)), zones = Set([:z1]), build_delta = (0.0, 0.0))
    geo_alt = CB.GeoBlock(poses = Dict(9 => (9.0, 9.0, 9.0)), zones = Set([:zalt]), build_delta = (9.0, 9.0))

    r_base = _rec(1)
    r_alt = CB.RobotRec(id = 99, pose = (9.0, 9.0, 9.0), vel = (9.0, 9.0), soc = 0.1,
                         energy_J = 99.0, usage_s = 9.0, eff = 0.1, health = :dead,
                         stalled = true, payload = 5, role = :courier)

    hz_base = CB.HazardBlock(lambda0 = Dict(1 => 1.0e-4), mode = :nominal, broken = Set{Int}(),
                             expired_break = Set{Int}(), expired_cell = Set{Int}())
    hz_alt = CB.HazardBlock(lambda0 = Dict(9 => 9.0e-4), mode = :degraded, broken = Set([9]),
                            expired_break = Set([9]), expired_cell = Set([9]))

    cr_base = CB.CourierRec(target = 1, courier = 10, depot = :north, home = (0.0, 0.0),
                             goal = (1.0, 1.0), phase = :outbound, step_out = 5, step_swap = 0)
    cr_alt = CB.CourierRec(target = 9, courier = 90, depot = :south, home = (9.0, 9.0),
                            goal = (9.0, 9.0), phase = :returning, step_out = 99, step_swap = 99)

    clk_base = CB.ClockBlock(t = 1.0, step = 40)
    clk_alt = CB.ClockBlock(t = 99.0, step = 4000)

    age_base = CB.AgeBlock(no_progress = 0, snap_count = 0)
    age_alt = CB.AgeBlock(no_progress = 99, snap_count = 9)

    ev_base = CB.EventBlock(kind = :battery, robot = 1, severity = 0.3)
    ev_alt = CB.EventBlock(kind = :zone, robot = 9, severity = 0.9)

    _embed(; g = g_base, geo = geo_base, fleet = Dict(1 => r_base), hazard = hz_base,
           courier = [cr_base], clock = clk_base, age = age_base, event = ev_base) =
        CB.SimState(; g, geo, fleet, hazard, courier, clock, age, event)

    base_hash = CB.state_hash(_embed())

    specs = Any[
        (g_base, g_alt, b -> _embed(g = b)),
        (geo_base, geo_alt, b -> _embed(geo = b)),
        (r_base, r_alt, b -> _embed(fleet = Dict(b.id => b))),   # key = rec.id (I-3 invariant)
        (hz_base, hz_alt, b -> _embed(hazard = b)),
        (cr_base, cr_alt, b -> _embed(courier = [b])),
        (clk_base, clk_alt, b -> _embed(clock = b)),
        (age_base, age_alt, b -> _embed(age = b)),
        (ev_base, ev_alt, b -> _embed(event = b)),
    ]

    n_fields = 0
    for (base_blk, alt_blk, embed) in specs
        for f in fieldnames(typeof(base_blk))
            hybrid = _hybrid(base_blk, alt_blk, f)
            @test CB.state_hash(embed(hybrid)) != base_hash
            n_fields += 1
        end
    end
    @test n_fields == 42
end
