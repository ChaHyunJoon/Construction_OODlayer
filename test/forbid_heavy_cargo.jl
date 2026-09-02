# test/forbid_heavy_cargo.jl
# ============================================================================
#  이 파일이 지키는 것: 제약 종류 `ForbidHeavyCargo` — "이 로봇은 자기가 맡을 예정인
#  화물 중 **1대당 부담 상위 n 개**를 맡지 않는다".
#
#  🔴 runtests.jl 이 모든 시험 파일을 같은 `Main` 스코프에 include 하므로 자기 module 로 감싼다.
# ============================================================================
module ForbidHeavyCargoTests

using Test
using ConstructionBots
using Graphs, Random, JuMP, SparseArrays
const CB = ConstructionBots

# 🔴 런타임 include 는 **module 최상위**에 있어야 한다(world-age). 순서도 load-bearing:
#    navigator 가 먼저, 그 다음 mdp(= simstate_of; observe.jl 이 navigator 것을 쓴다).
#    🔴 계획 README 의 픽스처는 이 두 줄이 빠져 있어 그대로 쓰면 죽는다.
const REPO = joinpath(@__DIR__, "..")
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(CB, :simstate_of)  || CB.include(joinpath(REPO, "src", "smdp", "mdp.jl"))

@testset "ForbidHeavyCargo 타입 계약" begin
    rid = CB.RobotID(3)
    c = CB.ForbidHeavyCargo(rid, 2)
    @test c.agent === rid
    @test c.n == 2
    # 🔴 n < 1 은 0개 제약 = hollow admit 이다. 생성자가 막아야 한다.
    @test_throws Exception CB.ForbidHeavyCargo(rid, 0)
    @test_throws Exception CB.ForbidHeavyCargo(rid, -1)
    # verify 가 "과거를 건드리는가" 를 보려면 이 제약이 어떤 노드를 참조하는지 알아야 한다.
    @test CB.referenced_ids(c) == (rid,)
    # 문법 단계가 이 타입을 받아들여야 한다(ConstraintSpec 하위여야 verify (1) 을 통과).
    @test c isa CB.ConstraintSpec
end

# ============================================================================
#  G-1 — 실제 판 위에서 **금지가 행을 실제로 추가하는가**.
#
#  🔴 이 조사에서 프로브가 실제로 `금지행=0` 으로 공허하게 초록을 냈다. 그 사고를 여기서 막는다.
#  🔴 `_edge_owner_id` 는 **release 후에만** 쌍을 낸다(release 전 후보 0). 그래서 release 를
#     먼저 부른다 — 안 부르면 0 행이 나오고 그 초록은 공허하다.
# ============================================================================

"배터리·hazard·에너지 가중치가 켜진 env 를 만들어 `target_closed` 작업이 끝난 시점까지 전진."
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60, maxstep = 6000)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargoban", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    # 🔴 셋 다 필요하다. run_lego_demo 는 배터리를 초기화하지 않고(→ :no_fleet),
    #    init_objective_weights! 없이는 목적함수가 edge_costs 를 통째로 버린다.
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    # 🔴 상한에 걸리면 씬은 요청한 시점이 **아니다** — 조용히 돌려주면 아래 숫자가 전부 다른
    #    세계에서 온 것이 된다(삼상 규약: 못 만들었으면 만들었다고 말하지 않는다).
    got = length(CB.simstate_of(env).prog.closed)
    got < target_closed && error("fixture: 스텝 상한 $maxstep — closed = $got < $target_closed")
    return env
end

"해제 가능한 미래 배정 간선을 가장 많이 가진 로봇의 **ID**. 문자열이 아니라 ID 를 돌려준다."
function busiest_pending_agent(env)
    sched = env.sched
    frozen = CB.build_invariant(env).closed_nodes
    running = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    untouchable(id) = id in frozen || id in running
    # 🔴 Dict 는 세는 데만 쓰고 **순회로 고르지 않는다** — 정렬 키가 순서를 지운다.
    t = Dict{String,Int}()
    owner_of = Dict{String,CB.AbstractID}()
    for e in Graphs.edges(CB.get_graph(sched))
        CB.is_assignment_edge(sched, e.src, e.dst) || continue
        untouchable(CB.get_vtx_id(sched, e.src)) && continue
        untouchable(CB.get_vtx_id(sched, e.dst)) && continue
        o = CB._edge_owner_id(sched, e.src); o === nothing && continue
        s = string(o)
        t[s] = get(t, s, 0) + 1
        owner_of[s] = o
    end
    isempty(t) && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    best = sort(collect(t), by = kv -> (-kv[2], kv[1]))[1][1]   # 동점은 이름순 — 결정적
    return owner_of[best]
end

_nconstr(m) = JuMP.num_constraints(m; count_variable_in_set_constraints = false)

# --- 판을 한 번만 짓는다 ------------------------------------------------------
const ENV0  = fixture()
const AGENT = busiest_pending_agent(ENV0)
# 🔴 release 없이는 후보 간선이 0 이라 어떤 금지도 0행이다 — 그 초록은 공허하다.
const RELEASED = CB.release_pending_assignments!(ENV0, CB.build_invariant(ENV0))
const SCHED = ENV0.sched

# 🔴 **솔버 전역 둘을 이 시험이 직접 소유한다** (CLAUDE.md: "전역을 읽는 시험은 try/finally 로
#    직접 소유·복원할 것 — 단독 실행은 초록, 스위트에서만 빨갛다"). 실제로 두 번 겪었다:
#    (1) `CB._respec_optimizer()` 는 `default_milp_optimizer()` 를 먼저 보는데, 앞서 도는 `Demo`
#        시험이 그 전역을 **Gurobi 로 덮어쓴다** → `Gurobi Error 10009: No Gurobi license found`.
#    (2) 솔버만 HiGHS 로 바꿔도 `formulate_milp` 이 `default_milp_optimizer_attributes()` 를
#        무조건 적용하는데 거기 **Gurobi 전용 `MIPFocus`** 가 남아 있다 → `UnsupportedAttribute`.
#    여기서는 **풀지 않고 모델을 세우기만** 하므로 솔버가 무엇이든 상관없다. 고정이 곧 격리다.
const _PREV_OPT   = CB.default_milp_optimizer()
const _PREV_ATTRS = copy(CB.default_milp_optimizer_attributes())
CB.set_default_milp_optimizer!(CB.HiGHS.Optimizer)
CB.clear_default_milp_optimizer_attributes!()

_build(extra) = CB.formulate_milp(CB.SparseAdjacencyMILP(), SCHED, ENV0.scene_tree;
                                  optimizer = CB.HiGHS.Optimizer, extra_constraints = extra)
_prop(cs) = CB.RespecProposal(CB.ConstraintSpec[cs])

const BASE    = _build(nothing)
const BASE_NC = _nconstr(BASE.model)
const XA      = BASE.Xa

"""
계약에서 **다시 유도한** 부담 표: `agent` 소유의 후보 간선이 닿는 도착점 v2 → 1대당 부담.
생산 코드의 선택자 헬퍼를 부르지 않고, `env` 를 직접 쥔 채(전역 우회) 다시 만든다.
"""
function oracle_burdens(env, sched, Xa, agent)
    p = CB.BATTERY_FLEET[].params
    rv = SparseArrays.rowvals(Xa)
    out = Tuple{Int,Float64}[]
    unmeasured = Int[]
    for v2 in 1:size(Xa, 2)
        owned = false
        for k in SparseArrays.nzrange(Xa, v2)
            u = rv[k]
            Graphs.has_edge(sched, u, v2) && continue
            o = CB._edge_owner_id(sched, u)
            (o !== nothing && o == agent) || continue
            owned = true; break
        end
        owned || continue
        b = CB.cargo_burden_after(env, sched, v2, p)
        b === nothing ? push!(unmeasured, v2) : push!(out, (v2, Float64(b)))
    end
    return out, unmeasured
end

"위 표에서 `agent` 소유 후보 간선을 v2 별로 센다 — 금지 행 수의 독립 기대값."
function oracle_rows(sched, Xa, agent, targets)
    rv = SparseArrays.rowvals(Xa); c = 0
    for v2 in targets, k in SparseArrays.nzrange(Xa, v2)
        u = rv[k]
        Graphs.has_edge(sched, u, v2) && continue
        o = CB._edge_owner_id(sched, u)
        (o !== nothing && o == agent) || continue
        c += 1
    end
    return c
end

@testset "🔴 픽스처가 비퇴화다 (이걸 먼저 단언한다)" begin
    @test length(RELEASED) > 0                       # release 가 실제로 간선을 뗐다
    @test SparseArrays.nnz(XA) > 0                   # 후보 결정변수가 존재한다
    @test BASE_NC > 1000
    @test CB.BATTERY_FLEET[] !== nothing             # 부담을 잴 파라미터가 있다
    meas, unmeas = oracle_burdens(ENV0, SCHED, XA, AGENT)
    @test !isempty(meas)                             # 🔴 잰 도착점이 0 이면 아래 전부 공허하다
    @test all(b -> b > 0.0, last.(meas))
    @info "픽스처: released=$(length(RELEASED)) nnz(Xa)=$(SparseArrays.nnz(XA)) " *
          "agent=$(string(AGENT)) 잰도착점=$(length(meas)) 못잰도착점=$(length(unmeas)) " *
          "부담범위=$(extrema(last.(meas)))"
end

@testset "🔴 G-1 컴파일러가 실제로 행을 추가한다 (0 이면 빨강)" begin
    cs = CB.ForbidHeavyCargo(AGENT, 1)
    # (a) **생산 배선 그대로** — formulate_milp 이 스스로 RESPEC_SCENE_TREE 를 채운다.
    n_rows = _nconstr(_build(_prop(cs)).model) - BASE_NC
    @test n_rows > 0                                  # 🔴 이 한 줄이 hollow admit 을 막는다
    # (b) 반환값이 거짓말을 하지 않는가 — 같은 모델에 직접 걸어 행 수와 대조한다.
    #     (전역은 이 경로에서 시험이 직접 채운다: formulate 밖이므로.)
    old = CB.RESPEC_SCENE_TREE[]
    CB.RESPEC_SCENE_TREE[] = ENV0.scene_tree
    try
        before = _nconstr(BASE.model)
        r = CB.compile_constraint!(BASE.model, BASE.model[:t0], BASE.model[:tF], XA, SCHED, cs)
        @test r == _nconstr(BASE.model) - before
        @test r == n_rows                             # 두 경로가 같은 수를 낸다
        @test r > 0
        # 독립 기대값(계약에서 다시 유도) 과도 일치해야 한다.
        meas, _ = oracle_burdens(ENV0, SCHED, XA, AGENT)
        srt = sort(meas, by = c -> (-c[2], string(CB.get_vtx_id(SCHED, c[1]))))
        @test r == oracle_rows(SCHED, XA, AGENT, [srt[1][1]])
        @info "G-1: 금지 행 수 = $(r) (대상 v2 = $(srt[1][1]), 부담 = $(srt[1][2]))"
    finally
        CB.RESPEC_SCENE_TREE[] = old
    end
end

@testset "🔴 formulate_milp 은 씬트리를 되돌린다 (전역 오염 금지)" begin
    @test CB.RESPEC_SCENE_TREE[] === nothing          # 위 formulate 들이 끝난 뒤 비어 있다
    _build(_prop(CB.ForbidHeavyCargo(AGENT, 1)))
    @test CB.RESPEC_SCENE_TREE[] === nothing
    # 음성 대조: 전역이 비어 있으면 **조용한 0행이 아니라 에러**다(배선 결함 ≠ 못 쟀다).
    # 🔴 `Exception` 만 잡으면 아무 오타나 잡고 초록이 된다 — **사유**까지 못 박는다.
    err = try
        CB.compile_constraint!(JuMP.Model(), nothing, nothing, XA, SCHED,
                               CB.ForbidHeavyCargo(AGENT, 1))
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("RESPEC_SCENE_TREE", sprint(showerror, err))
end

@testset "대상 선택: 결정적 · 상위 n · 못 잰 것은 건너뛴다" begin
    old = CB.RESPEC_SCENE_TREE[]
    CB.RESPEC_SCENE_TREE[] = ENV0.scene_tree
    try
        meas, unmeas = oracle_burdens(ENV0, SCHED, XA, AGENT)
        srt = sort(meas, by = c -> (-c[2], string(CB.get_vtx_id(SCHED, c[1]))))
        t1 = CB._heavy_cargo_targets(SCHED, XA, AGENT, 1)
        t3 = CB._heavy_cargo_targets(SCHED, XA, AGENT, 3)
        @test length(t1) == 1
        @test length(t3) == min(3, length(meas))
        @test t1 == [srt[1][1]]                        # 계약에서 유도한 순서와 같다
        @test t3 == [c[1] for c in srt[1:min(3, length(srt))]]
        @test t1 ⊆ t3
        # 🔴 동점이 실재하면 그때 순위를 정하는 것은 **2차 키뿐**이다(Task 1 실측: tractor 는
        #    최댓값에서 2-동점, `colored_8x8` 은 후보 전부가 한 값). 여기서 그 규칙을
        #    독립적으로 다시 유도한다 — 동점자 중 내용파생 문자열이 가장 작은 것.
        top = maximum(last.(meas))
        tied = sort([string(CB.get_vtx_id(SCHED, v)) for (v, b) in meas if b == top])
        @info "동점: 최댓값 $(top) 에 도착점 $(length(tied)) 개"
        length(tied) > 1 && @test string(CB.get_vtx_id(SCHED, t1[1])) == tied[1]
        # 🔴 결정론: 같은 입력에 같은 답 (Set/Dict 순회에 매달리면 여기서 갈린다)
        @test CB._heavy_cargo_targets(SCHED, XA, AGENT, 3) == t3
        # 🔴 못 잰 도착점은 대상이 아니다 (0 으로 접지 않는다)
        @test isempty(intersect(t3, unmeas))
        # 고른 것의 부담이 안 고른 것보다 작지 않다
        bmap = Dict(meas)
        chosen = minimum(bmap[v] for v in t3)
        rest = [b for (v, b) in meas if !(v in t3)]
        isempty(rest) || @test chosen >= maximum(rest) - 1e-12
    finally
        CB.RESPEC_SCENE_TREE[] = old
    end
end

@testset "n 을 키우면 금지 행이 줄지 않는다" begin
    cs1 = CB.ForbidHeavyCargo(AGENT, 1); cs3 = CB.ForbidHeavyCargo(AGENT, 3)
    r1 = _nconstr(_build(_prop(cs1)).model) - BASE_NC
    r3 = _nconstr(_build(_prop(cs3)).model) - BASE_NC
    @test r1 > 0
    @test r3 >= r1
    meas, _ = oracle_burdens(ENV0, SCHED, XA, AGENT)
    length(meas) >= 3 && @test r3 > r1                # 대상이 늘면 행도 는다(공허하지 않다)
end

@testset "cargo_burden_after 의 삼상 규약과 나눗셈" begin
    p = CB.BATTERY_FLEET[].params
    meas, unmeas = oracle_burdens(ENV0, SCHED, XA, AGENT)
    @test !isempty(meas)
    # 🔴 "못 쟀다" 가 실재해야 이 규약이 공허하지 않다. 후속이 없는 정점을 하나 찾는다.
    novtx = findfirst(v -> isempty(Graphs.outneighbors(SCHED, v)), 1:Graphs.nv(SCHED))
    @test novtx !== nothing
    @test CB.cargo_burden_after(ENV0, SCHED, novtx, p) === nothing   # 0 이 아니라 nothing
    # 부담 = 질량 / 팀크기 — 정의를 못 박는다(그냥 질량이면 여기서 갈린다).
    v2 = meas[1][1]
    m = CB.candidate_edge_payload_mass(ENV0, SCHED, v2, p)
    @test m !== nothing
    inner = CB.get_node_from_id(SCHED, CB.get_vtx_id(SCHED, Graphs.outneighbors(SCHED, v2)[1]))
    team = length(CB.robot_team(CB.entity(inner)))
    @test team >= 1
    @test meas[1][2] ≈ m / team
    team > 1 && @test meas[1][2] < m                  # 팀이 크면 1대당 부담이 실제로 작다
    # `env` 자리에 (scene_tree = …,) NamedTuple 만 줘도 같은 답이다(컴파일러가 그렇게 부른다).
    @test CB.cargo_burden_after((scene_tree = ENV0.scene_tree,), SCHED, v2, p) ≈ meas[1][2]
end

# 🔴 빌린 전역을 돌려준다. (이 파일이 runtests.jl 의 **마지막**이라 뒤가 없지만, 순서가 바뀌어도
#    남의 세계를 바꿔 놓지 않도록 명시적으로 복원한다.)
CB.set_default_milp_optimizer!(_PREV_OPT)
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(_PREV_ATTRS)

end # module
