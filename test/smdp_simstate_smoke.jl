# test/smdp_simstate_smoke.jl
# s 는 콘텐츠 해시가 가능해야 한다. 그 성질이 깨지는 방식은 둘뿐이다:
#   (1) 불투명 객체(MersenneTwister·RVO 핸들)가 s 안에 있다 → ξ 로 빼서 막는다
#   (2) Set/Dict 순회 순서가 직렬화에 새어든다 → 정렬 직렬화로 막는다
#
# 2026-08-20 엄격 축소로 s = (G, Geo, Fleet, Courier) **19 필드**가 됐다(구 42 → 40 → 19).
# 같은 날 후속으로 sojourn read-set(zones · usage_s/mode/eff · 신규 ProgBlock)이 돌아와
# s = (G, Geo, Fleet, Prog, Courier) **26 필드**가 됐다 — `CourierRec.step_out`/`step_swap`
# 도 `ProgBlock.t` 와 같은 시계인 `t_out`/`t_swap`(Float64, 절대 sim 초)으로 개명됐다.
# 이 파일은 그 축소에 맞춰 재작성됐지만, 앞선 리뷰들이 실제로 잡았던 결함의 **회귀 검사는
# 종류별로 전부 옮겨 왔다** — 그것들이 이 파일의 존재 이유이기 때문이다:
#   C-1 삽입 순서 누수 · C-2 구분자 위조 · I-1 부호 있는 0 · I-3 로봇 identity · I-4 프로세스 간
#
#   julia +lts --project=. test/smdp_simstate_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; soc = 1.0, pose = (1.0, 2.0, 0.5), role = :transport,
      health = :healthy, payload = nothing,
      usage_s = 0.0, mode = :transit, eff = 1.0) =
    CB.RobotRec(pose = pose, soc = soc, health = health, payload = payload, role = role,
                usage_s = usage_s, mode = mode, eff = eff)

_cr(; target = 7, courier = 8) = CB.CourierRec(
    target = target, courier = courier, depot = :north, home = (0.0, 0.0),
    goal = (1.0, 1.0), phase = :outbound, t_out = 10.0, t_swap = 20.0)

_default_geo_zones() = Dict{Symbol,NTuple{3,Float64}}()
_default_prog() = CB.ProgBlock(t = 0.0, closed = Set{Int}(), active = Dict{Int,Float64}())

function _state(; robots = [1, 2, 3], socs = Dict{Int,Float64}(),
                 couriers = CB.CourierRec[], fleet_override = nothing,
                 prog = _default_prog())
    fleet = fleet_override === nothing ?
        Dict(r => _rec(soc = get(socs, r, 1.0)) for r in robots) : fleet_override
    CB.SimState(
        g = CB.GraphBlock(edges = Set([(1, 2), (2, 3), (3, 4), (4, 5)]),
                          binding = Dict(3 => 1), wedge_edges = Set([(1, 3)]),
                          dissolved_gates = Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), build_delta = (0.0, 0.0),
                          zones = _default_geo_zones()),
        fleet = fleet,
        prog = prog,
        courier = couriers)
end

# --- C-1 헬퍼: 10원소 이상 컬렉션을 두 삽입 순서로 실제로 push!/insert 해서 만든다.
# 3원소 Set/Dict 는 삽입 순서와 무관하게 내부 반복 순서가 이미 같아서(측정됨), sort! 를 지워도
# 그 크기에서는 절대 안 걸린다 — 리뷰가 잡은 바로 그 결함. 12원소로 올린다.
# **콘텐츠는 고정하고 삽입 순서만 바꾼다.**
function _big_state(order::Symbol)
    # 순차 정수는 Julia 의 Int 해시가 버킷을 조밀하게 채워 삽입 순서와 무관해진다 — 흩어진 값.
    ids = [17, 4, 91, 33, 8, 250, 61, 12, 145, 77, 29, 103]
    ord = order === :fwd ? ids : reverse(ids)
    edges = Set{Tuple{Int,Int}}()
    binding = Dict{Int,Int}()
    poses = Dict{Int,NTuple{3,Float64}}()
    fleet = Dict{Int,CB.RobotRec}()
    for i in ord
        push!(edges, (i, i + 1))
        binding[i] = i * 2
        poses[i] = (Float64(i), 0.0, 0.0)
        fleet[i] = _rec(soc = 1.0 - i / 1000)
    end
    CB.SimState(
        g = CB.GraphBlock(edges = edges, binding = binding,
                          wedge_edges = Set{Tuple{Int,Int}}(),
                          dissolved_gates = Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses = poses, build_delta = (0.0, 0.0), zones = _default_geo_zones()),
        fleet = fleet,
        prog = _default_prog(),
        courier = CB.CourierRec[])
end

@testset "smdp_simstate_smoke.jl — 전체" begin

@testset "정렬 직렬화 — 삽입 순서가 해시에 안 샌다 (C-1)" begin
    a, b = _big_state(:fwd), _big_state(:rev)
    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)
end

@testset "courier 벡터는 삽입 순서에 무관하다 (I-2)" begin
    c1, c2 = _cr(target = 1, courier = 2), _cr(target = 3, courier = 4)
    @test CB.canonical(_state(couriers = [c1, c2])) == CB.canonical(_state(couriers = [c2, c1]))
end

@testset "s 가 다르면 해시가 다르다 (실질 필드 — 실패할 수 있는 테스트)" begin
    @test CB.state_hash(_state()) != CB.state_hash(_state(socs = Dict(2 => 0.42)))
    @test CB.state_hash(_state()) != CB.state_hash(_state(robots = [1, 2]))
    @test CB.state_hash(_state()) != CB.state_hash(_state(couriers = [_cr()]))
end

@testset "ξ 는 s 안에 없다 — 불투명 객체 금지" begin
    txt = CB.canonical(_state())
    @test !occursin("MersenneTwister", txt)
    @test !occursin("thr_", txt)
    @test !occursin("cum_", txt)
    # ReplayState 에는 canonical 메서드가 없다 — ξ 는 해시 대상이 아니다.
    @test isempty(methods(CB.canonical, (CB.ReplayState,)))
end

@testset "구분자 위조 — Symbol 은 길이-프리픽스로 감싸진다 (C-2)" begin
    # `role` 은 자유 텍스트 Symbol 을 담을 수 있는 필드다. 이스케이프 없이 꽂으면 그 payload 가
    # 임의의 구조를 위조한다(측정된 예: 1로봇 fleet 이 오염된 role 로 2로봇 fleet 과 해시가 같아짐).
    tail = "transport,usage=0.0,mode=transit,eff=1.0);R99(pose=(0.0,0.0,0.0)," *
           "soc=1.0,health=healthy,payload=nothing,role=transport"
    poisoned = Dict(1 => _rec(role = Symbol(tail)))
    r99 = _rec(pose = (0.0, 0.0, 0.0))
    clean = Dict(1 => _rec(), 99 => r99)
    @test CB.state_hash(_state(fleet_override = poisoned)) !=
          CB.state_hash(_state(fleet_override = clean))
    # 빈 Symbol 은 "0:" 로 렌더돼 빈 집합 "[]" 과 겹치지 않는다.
    @test CB._c(Symbol("")) == "0:"
    @test CB._c(Symbol("")) != CB._c(Set{Symbol}())
end

@testset "부호 있는 0 은 해시를 가르지 않는다 (I-1)" begin
    # round(-1e-12; digits=9) 이 관측 가능한 -0.0 을 만들어낸다(-0.0 == 0.0 인데 string 은 다르다).
    @test CB._c(-0.0) == CB._c(0.0)
    @test CB._c(round(-1.0e-12; digits = 12)) == CB._c(0.0)
    g_pos = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), build_delta = (0.0, 0.0),
                        zones = _default_geo_zones())
    g_neg = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), build_delta = (-0.0, 0.0),
                        zones = _default_geo_zones())
    @test CB.canonical(g_pos) == CB.canonical(g_neg)
    @test CB.canonical(_rec(pose = (0.0, 0.0, 0.0))) == CB.canonical(_rec(pose = (-0.0, 0.0, 0.0)))
end

@testset "로봇 identity 는 fleet Dict 키가 나른다 (I-3, 축소 이후)" begin
    # 2026-08-20 에 `RobotRec.id` 필드가 빠졌다. 그래서 키가 **유일한** identity 진실원이고,
    # 반드시 해시에 닿아야 한다 — 안 닿으면 Dict(1=>rec) 와 Dict(2=>rec) 가 같은 해시를 낸다.
    r = _rec()
    @test CB.state_hash(_state(fleet_override = Dict(1 => r))) !=
          CB.state_hash(_state(fleet_override = Dict(2 => r)))
    @test occursin("R1(", CB.canonical(_state(fleet_override = Dict(1 => r))))
    # production 의 Fleet 블록 조립 규칙(구분자 ";")을 손으로 복제하지 않고 그것과 묶는다 —
    # 구분자가 바뀌면 여기가 red 가 된다(박물관 전시물 방지).
    two = _state(fleet_override = Dict(1 => _rec(), 99 => _rec(pose = (0.0, 0.0, 0.0))))
    expected = "Fleet[R1" * CB.canonical(_rec()) * ";R99" * CB.canonical(_rec(pose = (0.0, 0.0, 0.0))) * "]"
    @test Dict(CB._canonical_blocks(two))[:fleet] == expected
end

@testset "omit — 블록 이름 검증과 접두 분리 (M-1, B5)" begin
    st = _state()
    @test CB.state_hash(st; omit = Set([:courier])) != CB.state_hash(st)
    @test CB.state_hash(st; omit = Set{Symbol}()) == CB.state_hash(st)
    # 오타를 조용히 무시하면 "아무것도 안 벗겨졌다"는 사실이 샌다 → 에러여야 한다.
    @test_throws ErrorException CB.canonical(st; omit = Set([:clok]))
    @test_throws ErrorException CB.canonical(st; omit = Set([:clock]))   # 축소로 사라진 블록
    # 각 블록 문자열은 서로 다른 접두를 가져 omit 조합끼리 혼동되지 않는다.
    @test CB.state_hash(st; omit = Set([:g])) != CB.state_hash(st; omit = Set([:geo]))
end

@testset "해시는 한 작업 트리 안에서 프로세스에 걸쳐 안정적이다 (I-4)" begin
    # ⚠️ 이 테스트가 검출하는 것은 환경 수준의 발산(SHA 버전 등)이다. 정렬 코드 자체의 버그는
    # C-1 이 잡지 이 테스트가 잡는 게 아니다 — "삽입 순서 안정성까지 검증됐다"고 인용하지 말 것.
    h_here = CB.state_hash(_state())
    proj = joinpath(@__DIR__, "..")
    code = """
    import ConstructionBots as CB
    CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
    CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
    rec() = CB.RobotRec(pose=(1.0,2.0,0.5), soc=1.0, health=:healthy,
                        payload=nothing, role=:transport,
                        usage_s=0.0, mode=:transit, eff=1.0)
    s = CB.SimState(
        g = CB.GraphBlock(edges=Set([(1,2),(2,3),(3,4),(4,5)]), binding=Dict(3=>1),
                           wedge_edges=Set([(1,3)]), dissolved_gates=Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses=Dict(10=>(0.0,0.0,0.0)), build_delta=(0.0,0.0),
                          zones=Dict{Symbol,NTuple{3,Float64}}()),
        fleet = Dict(r => rec() for r in [1,2,3]),
        prog = CB.ProgBlock(t=0.0, closed=Set{Int}(), active=Dict{Int,Float64}()),
        courier = CB.CourierRec[])
    println(CB.state_hash(s))
    """
    out = read(`julia +lts --project=$proj -e $code`, String)
    @test strip(out) == h_here
end

# --- 필드 민감도: base/alt 블록을 한 필드씩 섞어(hybrid) state_hash 가 바뀌는지 루프로 본다.
# 손으로 몇 개만 짚으면 나머지는 canonical 에서 지워도 고정 fixture 로 못 잡는다.
_hybrid(base::T, alt::T, field::Symbol) where {T} =
    T(; Dict{Symbol,Any}(f => (f === field ? getfield(alt, f) : getfield(base, f))
                          for f in fieldnames(T))...)

@testset "필드 민감도 — 4블록 23필드 전부가 해시를 바꾼다 (2026-08-20 축소: 42→19, 같은 날 확장: 19→26)" begin
    # `prog`(ProgBlock, 3필드)는 이 루프에 안 들어간다 — `test/smdp_simstate_fields.jl` 이
    # 전담한다. 여기 4블록은 `_embed` 에 고정 prog 를 얹어 26 중 23필드만 짚는다.
    g_base = CB.GraphBlock(edges = Set([(1, 2), (2, 3)]), binding = Dict(1 => 1),
                           wedge_edges = Set{Tuple{Int,Int}}(),
                           dissolved_gates = Set{Tuple{Int,Int}}())
    g_alt = CB.GraphBlock(edges = Set([(9, 9)]), binding = Dict(9 => 9),
                          wedge_edges = Set([(9, 9)]), dissolved_gates = Set([(9, 9)]))
    geo_base = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)), build_delta = (0.0, 0.0),
                           zones = Dict(:z1 => (0.0, 0.0, 1.0)))
    geo_alt = CB.GeoBlock(poses = Dict(9 => (9.0, 9.0, 9.0)), build_delta = (9.0, 9.0),
                          zones = Dict(:z1 => (9.0, 9.0, 9.0)))
    r_base = _rec()
    r_alt = CB.RobotRec(pose = (9.0, 9.0, 9.0), soc = 0.1, health = :dead,
                        payload = 9, role = :courier,
                        usage_s = 9.0, mode = :carry, eff = 9.0)
    cr_base = _cr()
    cr_alt = CB.CourierRec(target = 91, courier = 92, depot = :south, home = (9.0, 9.0),
                           goal = (8.0, 8.0), phase = :returning, t_out = 91.0, t_swap = 92.0)

    _embed(; g = g_base, geo = geo_base, fleet = Dict(1 => r_base), courier = [cr_base],
             prog = _default_prog()) =
        CB.SimState(g = g, geo = geo, fleet = fleet, prog = prog, courier = courier)

    cases = [
        (g_base,   g_alt,   b -> _embed(g = b)),
        (geo_base, geo_alt, b -> _embed(geo = b)),
        (r_base,   r_alt,   b -> _embed(fleet = Dict(1 => b))),
        (cr_base,  cr_alt,  b -> _embed(courier = [b])),
    ]
    n_fields = 0
    for (base_blk, alt_blk, embed) in cases
        h0 = CB.state_hash(embed(base_blk))
        for f in fieldnames(typeof(base_blk))
            hyb = _hybrid(base_blk, alt_blk, f)
            @test CB.state_hash(embed(hyb)) != h0
            n_fields += 1
        end
    end
    @test n_fields == 23
end

end # testset
