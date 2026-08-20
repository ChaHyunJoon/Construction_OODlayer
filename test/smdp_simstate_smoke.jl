# test/smdp_simstate_smoke.jl
# spec §3 — s 는 콘텐츠 해시가 가능해야 한다. 그 성질이 깨지는 방식은 둘뿐이다:
#   (1) 불투명 객체(MersenneTwister·RVO 핸들)가 s 안에 있다 → ξ 로 빼서 막는다
#   (2) Set/Dict 순회 순서가 직렬화에 새어든다 → 정렬 직렬화로 막는다
#
# 컨트롤러 부칙 B5: canonical 은 블록별로 합성 가능해야 한다 — 태스크 13 의 strip_age/G-M 이
# clock(과 age) 을 뺀 해시를 나중에 필요로 한다. 그래서 clock 을 문자열 안에 하드코딩하지
# 않는다는 것도 여기서 같이 검증한다.
#
# 부칙: `state_hash(_state(no_progress=119)) != state_hash(_state(no_progress=120))` 류는
# `_c` 가 정수를 그대로 찍으므로 **항진명제**다 — 두되 해시 민감도의 근거로 인용하지 않는다.
# 대신 아래에 "실패할 수 있는" 실질 필드 테스트를 따로 둔다(soc 값 변경).
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
                 couriers = CB.CourierRec[])
    CB.SimState(
        g = CB.GraphBlock(n_nodes = 5, edges = Set([(1, 2), (2, 3), (3, 4), (4, 5)]),
                          closed = Set([1, 2]), active = Set([3]),
                          binding = Dict(3 => 1), edge_bias = Dict((1, 2) => 1.5),
                          wedge_edges = Set([(1, 3)]), dissolved_gates = Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = Set(zones),
                          build_delta = (0.0, 0.0)),
        fleet = Dict(r => _rec(r; soc = get(socs, r, 1.0)) for r in robots),
        hazard = CB.HazardBlock(lambda0 = Dict(r => 1.0e-4 for r in robots),
                                mode = :nominal, broken = Set{Int}(),
                                expired_break = Set{Int}(), expired_cell = Set{Int}()),
        courier = couriers, clock = CB.ClockBlock(t = clock_t, step = clock_step),
        age = CB.AgeBlock(no_progress = no_progress, snap_count = snap),
        event = CB.EventBlock(kind = :battery, robot = 1, severity = 0.3))
end

@testset "정준 직렬화는 삽입 순서에 무관하다" begin
    a = _state(robots = [1, 2, 3], zones = [:z1, :z2])
    b = _state(robots = [3, 1, 2], zones = [:z2, :z1])
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

@testset "해시는 한 작업 트리 안에서 프로세스에 걸쳐 안정적이다" begin
    # 재컴파일 효과(CLAUDE.md Gotchas)는 여러 워크트리에 걸친 이야기다. 이 검사는 같은
    # 작업 트리 안에서 별도 julia 프로세스를 띄워 같은 canonical 문자열에 대해 같은 해시가
    # 나오는지만 본다 — 결정론적 해시 함수 자체의 안정성 확인.
    txt = CB.canonical(_state(no_progress = 7, snap = 1))
    h_here = CB.state_hash(_state(no_progress = 7, snap = 1))
    proj = joinpath(@__DIR__, "..")
    code = """
    import SHA
    txt = raw"$txt"
    println(bytes2hex(SHA.sha256(txt))[1:32])
    """
    out = read(`julia +lts --project=$proj -e $code`, String)
    @test strip(out) == h_here
end
