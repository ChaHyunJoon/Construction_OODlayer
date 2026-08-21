# test/smdp_simstate_smoke.jl
# s 는 콘텐츠 해시가 가능해야 한다. 그 성질이 깨지는 방식은 둘뿐이다:
#   (1) 불투명 객체(MersenneTwister·RVO 핸들)가 s 안에 있다 → ξ 로 빼서 막는다
#   (2) Set/Dict 순회 순서가 직렬화에 새어든다 → 정렬 직렬화로 막는다
#
# 2026-08-21 축소로 s = (G, Geo, Fleet, Prog) **7 필드**가 됐다(구 26 → 7, 로봇당 8 → 2).
# `CourierRec` 블록은 통째로 삭제됐다(spec §2-5) — 배송은 `env.BATTERY_DELIVERIES[]` 로
# 옮겨갔고 s 안에 흔적이 없다.
#
# 이 파일은 그 축소에 맞춰 재작성됐지만, 앞선 리뷰들이 실제로 잡았던 결함의 **회귀 검사는
# 종류별로 전부 옮겨 왔다** — 그것들이 이 파일의 존재 이유이기 때문이다:
#   C-1 삽입 순서 누수 · C-2 구분자 위조 · I-1 부호 있는 0 · I-3 로봇 identity · I-4 프로세스 간
# 🔴 **C-2 는 자리를 옮겼다.** `RobotRec` 에서 Symbol 필드(`role`)가 통째로 빠졌으므로(spec §2-2:
# soc·usage_s 뿐), 원래 표적이 사라졌다. `GeoBlock.zones` 가 이제 **s 안에서 유일하게 남은
# Symbol 키 자리**라 그 회귀를 거기로 옮겼다 — 지운 게 아니라 이사했다.
# 🔴 **I-2(`courier` 벡터 삽입순서 무관)는 표적 블록 자체가 삭제되어 이 파일에서 빠졌다** —
# 옮겨갈 새 Vector-of-struct 필드가 s 안에 없다(남은 컬렉션은 전부 Set/Dict 이고 그건 C-1 이
# 이미 커버한다). `!isdefined(CB, :CourierRec)` 음성 대조는 `test/smdp_simstate_fields.jl` 이
# 못박는다.
#
#   julia +lts --project=. test/smdp_simstate_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; soc = 1.0, usage_s = 0.0) = CB.RobotRec(soc = soc, usage_s = usage_s)

_default_geo_zones() = Dict{Symbol,NTuple{3,Float64}}()
_default_prog() = CB.ProgBlock(closed = Set{Int}())

function _state(; robots = [1, 2, 3], socs = Dict{Int,Float64}(),
                 fleet_override = nothing, geo = nothing, prog = _default_prog())
    fleet = fleet_override === nothing ?
        Dict(r => _rec(soc = get(socs, r, 1.0)) for r in robots) : fleet_override
    geo_blk = geo === nothing ?
        CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = _default_geo_zones()) : geo
    CB.SimState(
        g = CB.GraphBlock(edges = Set([(1, 2), (2, 3), (3, 4), (4, 5)]),
                          binding = Dict(3 => 1)),
        geo = geo_blk,
        fleet = fleet,
        prog = prog)
end

# --- C-1 헬퍼: 10원소 이상 컬렉션을 두 삽입 순서로 실제로 push!/insert 해서 만든다.
# 3원소 Set/Dict 는 삽입 순서와 무관하게 내부 반복 순서가 이미 같아서(측정됨), sort! 를 지워도
# 그 크기에서는 절대 안 걸린다 — 리뷰가 잡은 바로 그 결함. 12원소로 올린다.
# **콘텐츠는 고정하고 삽입 순서만 바꾼다.**
#
# 🔴 2026-08-21 축소: `prog.active` 는 필드째 삭제됐다(`ProgBlock` 은 `closed` 하나뿐).
# `geo.zones`·`prog.closed`·`fleet`·`g.edges`·`g.binding` 다섯은 여전히 s 안에 있으므로 채운다 —
# `geo.zones` 가 가장 중요하다(`s` 안에서 유일한 Symbol 키 Dict).
function _big_state(order::Symbol)
    # 순차 정수는 Julia 의 Int 해시가 버킷을 조밀하게 채워 삽입 순서와 무관해진다 — 흩어진 값.
    ids = [17, 4, 91, 33, 8, 250, 61, 12, 145, 77, 29, 103]
    ord = order === :fwd ? ids : reverse(ids)
    edges = Set{Tuple{Int,Int}}()
    binding = Dict{Int,Int}()
    poses = Dict{Int,NTuple{3,Float64}}()
    fleet = Dict{Int,CB.RobotRec}()
    zones = Dict{Symbol,NTuple{3,Float64}}()
    closed = Set{Int}()
    for i in ord
        push!(edges, (i, i + 1))
        binding[i] = i * 2
        poses[i] = (Float64(i), 0.0, 0.0)
        fleet[i] = _rec(soc = 1.0 - i / 1000)
        # Symbol 키: 문자열 해시라 Int 와 버킷 분포가 **다르다** — 이 축을 따로 흔들어야 하는 이유.
        # ⚠️ 접두어가 `"z"` 였을 때는 이 12개 Symbol 의 Dict 순회 순서가 삽입 순서와 무관했다
        # (실측). 즉 zones 축의 C-1 검사가 항진명제였다 — 아래 전제 단언이 그것을 잡았다.
        # `"zone_"` 접두어에서는 실제로 갈린다. Julia 를 올렸다가 전제 단언이 빨개지면
        # **단언을 지우지 말고 키를 다시 고를 것**(그 단언이 존재하는 이유가 바로 이 상황이다).
        zones[Symbol("zone_", i)] = (Float64(i), Float64(2i), 0.5)
        push!(closed, i + 1000)
    end
    CB.SimState(
        g = CB.GraphBlock(edges = edges, binding = binding),
        geo = CB.GeoBlock(poses = poses, zones = zones),
        fleet = fleet,
        prog = CB.ProgBlock(closed = closed))
end

@testset "smdp_simstate_smoke.jl — 전체" begin

@testset "정렬 직렬화 — 삽입 순서가 해시에 안 샌다 (C-1)" begin
    a, b = _big_state(:fwd), _big_state(:rev)

    # 🔴 **전제 단언 먼저.** 두 픽스처의 내부 순회 순서가 실제로 갈리지 않으면 아래 등호는
    # 아무것도 증명하지 않는다(정렬을 통째로 지워도 초록이다). 리뷰가 이 파일에서 이미 한 번
    # 잡았던 실패 모양이라, 나중에 픽스처가 조용히 수렴하면 **여기가 먼저 빨개지게** 둔다.
    @test collect(keys(a.fleet))      != collect(keys(b.fleet))
    @test collect(keys(a.geo.zones))  != collect(keys(b.geo.zones))
    @test collect(a.prog.closed)      != collect(b.prog.closed)
    # 그리고 도메인이 비어 있지 않다.
    @test length(a.geo.zones) == 12 && length(a.prog.closed) == 12

    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)

    # 블록별로도 못 박는다 — 전체 canonical 만 보면 어느 블록이 실제로 정렬됐는지 안 보인다.
    ab, bb = Dict(CB._canonical_blocks(a)), Dict(CB._canonical_blocks(b))
    for blk in (:g, :geo, :fleet, :prog)
        @test (blk, ab[blk]) == (blk, bb[blk])
    end
    # Symbol 키 Dict 가 실제로 렌더에 들어갔다(빈 Dict 였다면 이 검사가 항진명제였다).
    @test occursin("8:zone_250", ab[:geo])   # `_c(Symbol)` = "<바이트수>:<본문>"
end

@testset "s 가 다르면 해시가 다르다 (실질 필드 — 실패할 수 있는 테스트)" begin
    @test CB.state_hash(_state()) != CB.state_hash(_state(socs = Dict(2 => 0.42)))
    @test CB.state_hash(_state()) != CB.state_hash(_state(robots = [1, 2]))
    @test CB.state_hash(_state()) != CB.state_hash(_state(prog = CB.ProgBlock(closed = Set([1]))))
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
    # `RobotRec` 에는 이제 Symbol 필드가 없다(soc·usage_s 뿐, spec §2-2) — 원래 표적(`role`)이
    # 사라졌다. `GeoBlock.zones` 가 s 안에서 유일하게 남은 자유 텍스트(Symbol 키) 자리이므로
    # 회귀를 여기로 옮긴다.
    #   naive(비-prefix) 렌더라면 zone **하나짜리** { "za:(1.0,2.0,3.0),zb" => (4.0,5.0,6.0) } 가
    #   zone **둘짜리** { :za=>(1.0,2.0,3.0), :zb=>(4.0,5.0,6.0) } 와 똑같은 문자열을 낸다
    #   (":"·","·"("·")" 가 그대로 새면 원소 경계가 위조된다). 길이-프리픽스가 그 경계를 지킨다.
    poison_key = Symbol("za:(1.0,2.0,3.0),zb")
    poisoned = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)),
                           zones = Dict(poison_key => (4.0, 5.0, 6.0)))
    clean = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)),
                        zones = Dict(:za => (1.0, 2.0, 3.0), :zb => (4.0, 5.0, 6.0)))
    @test CB.state_hash(_state(geo = poisoned)) != CB.state_hash(_state(geo = clean))
    # 빈 Symbol 은 "0:" 로 렌더돼 빈 집합 "[]" 과 겹치지 않는다.
    @test CB._c(Symbol("")) == "0:"
    @test CB._c(Symbol("")) != CB._c(Set{Symbol}())
end

@testset "부호 있는 0 은 해시를 가르지 않는다 (I-1)" begin
    # round(-1e-12; digits=9) 이 관측 가능한 -0.0 을 만들어낸다(-0.0 == 0.0 인데 string 은 다르다).
    @test CB._c(-0.0) == CB._c(0.0)
    @test CB._c(round(-1.0e-12; digits = 12)) == CB._c(0.0)
    # `build_delta`·`pose` 는 2026-08-21 축소에서 빠졌다 — I-1 회귀는 여전히 float 필드를 가진
    # `GeoBlock.poses`·`RobotRec.soc` 로 옮긴다.
    g_pos = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = _default_geo_zones())
    g_neg = CB.GeoBlock(poses = Dict(10 => (-0.0, 0.0, 0.0)), zones = _default_geo_zones())
    @test CB.canonical(g_pos) == CB.canonical(g_neg)
    @test CB.canonical(_rec(soc = 0.0)) == CB.canonical(_rec(soc = -0.0))
end

@testset "로봇 identity 는 fleet Dict 키가 나른다 (I-3, 축소 이후)" begin
    # 2026-08-20 에 `RobotRec.id` 필드가 빠졌다. 그래서 키가 **유일한** identity 진실원이고,
    # 반드시 해시에 닿아야 한다 — 안 닿으면 Dict(1=>rec) 와 Dict(2=>rec) 가 같은 해시를 낸다.
    r = _rec()
    @test CB.state_hash(_state(fleet_override = Dict(1 => r))) !=
          CB.state_hash(_state(fleet_override = Dict(2 => r)))
    # 2026-08-21: fleet 블록은 이제 `"Fleet=" * _c(s.fleet)` 로 조립된다(옛 `Fleet[R<key>...]`
    # join 이 아니다) — production 의 Fleet 블록 조립 규칙을 손으로 복제하지 않고 그것과 묶는다.
    # 구분자("{"·":"·","·"}")가 바뀌면 여기가 red 가 된다(박물관 전시물 방지).
    two = _state(fleet_override = Dict(1 => _rec(), 99 => _rec(soc = 0.5)))
    expected = "Fleet={1:" * CB.canonical(_rec()) * ",99:" * CB.canonical(_rec(soc = 0.5)) * "}"
    @test Dict(CB._canonical_blocks(two))[:fleet] == expected
end

@testset "omit — 블록 이름 검증과 접두 분리 (M-1, B5)" begin
    st = _state()
    @test CB.state_hash(st; omit = Set([:prog])) != CB.state_hash(st)
    @test CB.state_hash(st; omit = Set{Symbol}()) == CB.state_hash(st)
    # 오타를 조용히 무시하면 "아무것도 안 벗겨졌다"는 사실이 샌다 → 에러여야 한다.
    @test_throws ErrorException CB.canonical(st; omit = Set([:clok]))
    @test_throws ErrorException CB.canonical(st; omit = Set([:clock]))   # 이미 사라진 블록(구세대)
    @test_throws ErrorException CB.canonical(st; omit = Set([:courier])) # 2026-08-21 축소로 사라진 블록
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
    rec() = CB.RobotRec(soc=1.0, usage_s=0.0)
    s = CB.SimState(
        g = CB.GraphBlock(edges=Set([(1,2),(2,3),(3,4),(4,5)]), binding=Dict(3=>1)),
        geo = CB.GeoBlock(poses=Dict(10=>(0.0,0.0,0.0)),
                          zones=Dict{Symbol,NTuple{3,Float64}}()),
        fleet = Dict(r => rec() for r in [1,2,3]),
        prog = CB.ProgBlock(closed=Set{Int}()))
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

@testset "필드 민감도 — 3블록 6필드 전부가 해시를 바꾼다 (2026-08-21 축소: 26→7)" begin
    # `prog`(ProgBlock, 1필드)는 이 루프에 안 들어간다 — `test/smdp_simstate_fields.jl` 이
    # 전담한다. `courier` 블록은 통째로 삭제됐다. 여기 3블록은 `_embed` 에 고정 prog 를 얹어
    # 7 중 6필드만 짚는다.
    g_base = CB.GraphBlock(edges = Set([(1, 2), (2, 3)]), binding = Dict(1 => 1))
    g_alt = CB.GraphBlock(edges = Set([(9, 9)]), binding = Dict(9 => 9))
    geo_base = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)), zones = Dict(:z1 => (0.0, 0.0, 1.0)))
    geo_alt = CB.GeoBlock(poses = Dict(9 => (9.0, 9.0, 9.0)), zones = Dict(:z1 => (9.0, 9.0, 9.0)))
    r_base = _rec()
    r_alt = CB.RobotRec(soc = 0.1, usage_s = 9.0)

    _embed(; g = g_base, geo = geo_base, fleet = Dict(1 => r_base), prog = _default_prog()) =
        CB.SimState(g = g, geo = geo, fleet = fleet, prog = prog)

    cases = [
        (g_base,   g_alt,   b -> _embed(g = b)),
        (geo_base, geo_alt, b -> _embed(geo = b)),
        (r_base,   r_alt,   b -> _embed(fleet = Dict(1 => b))),
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
    @test n_fields == 6
end

end # testset
