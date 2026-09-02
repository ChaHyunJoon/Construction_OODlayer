# tools/probes/probe_scoped_release.jl
#   julia +lts --project=. tools/probes/probe_scoped_release.jl
#
# 🔴 원시를 만들기 **전에** 가설을 잰다. 가설(사용자, 2026-09-01):
#   "release 를 대상 에이전트의 간선으로 좁히면 후보가 ~1/6 로 줄어 수렴 가능성이 생긴다."
#
# `probe_release_in_harness.jl` 이 잰 것: 전체 release 는 **모든 구간에서 60s 상한을 다 쓴다**
# (closed=250, 후보 364 에서도). 즉 어느 시점에도 최적성을 증명 못 한다. 이 프로브는 좁힌
# release 가 그 벽을 넘는지만 본다 — 못 넘으면 이 방향은 여기서 끝난다.
#
# 세 팔, **같은 상한**(대칭이 아니면 비교 불가):
#   [B] 전체 release  (오늘 `release_pending_assignments!` 가 하는 것)
#   [C] 좁힌 release  (대상 에이전트가 소유한 미래 배정 간선만)
#   [C0] 음성 대조: 좁힌 release 를 하고 **재가격은 안 한다** — 후보가 열렸는데도 계획이
#        안 바뀌면 그건 release 가 아니라 목적식 문제라는 뜻이다.
#
# 🔴 삼상 규약: 못 쟀으면 `nothing`. 🔴 집계는 전부 함수 안(soft scope).
# 🔴 한 프로세스·한 디렉터리(결정론 단위는 디렉터리다).
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

const TL = 60.0

"""
`release_pending_assignments!`(reassign.jl:121) 의 keep 규칙을 **그대로** 옮기되, `agent`
가 주어지면 그 에이전트가 소유한 간선만 뗀다. 프로덕션 원시가 아니라 **가설 측정용**이다 —
여기서 수렴이 안 나오면 원시를 안 만든다.
"""
function release_scoped!(env, invariant; agent::Union{Nothing,AbstractString} = nothing)
    sched = env.sched
    G = CB.get_graph(sched)
    closed = invariant.closed_nodes
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    removed = Tuple{Int,Int}[]
    for e in collect(Graphs.edges(G))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        id1 = CB.get_vtx_id(sched, v); id2 = CB.get_vtx_id(sched, v2)
        # keep 규칙(정상 로봇): 완료/진행중이면 유지 — 얼린 과거는 절대 안 건드린다.
        (id1 in closed || id2 in closed || id1 in active_ids || id2 in active_ids) && continue
        if agent !== nothing
            own = CB._edge_owner_id(sched, v)
            (own !== nothing && string(own) == agent) || continue
        end
        Graphs.rem_edge!(G, v, v2)
        push!(removed, (v, v2))
    end
    for (_, v2) in removed
        CB.reset_slot_to_invalid!(env, v2)
    end
    return removed
end

"떼어질 수 있는 간선들 중 가장 많이 소유한 에이전트(모듈 한정 문자열)."
function busiest_pending_owner(env)
    sched = env.sched; G = CB.get_graph(sched)
    inv = CB.build_invariant(env)
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    tally = Dict{String,Int}()
    for e in Graphs.edges(G)
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        id1 = CB.get_vtx_id(sched, v); id2 = CB.get_vtx_id(sched, v2)
        (id1 in inv.closed_nodes || id2 in inv.closed_nodes ||
         id1 in active_ids || id2 in active_ids) && continue
        own = CB._edge_owner_id(sched, v); own === nothing && continue
        tally[string(own)] = get(tally, string(own), 0) + 1
    end
    isempty(tally) && return nothing
    return sort(collect(tally), by = kv -> -kv[2])[1]
end

nreass(b, a) = count(v -> get(b, v, -1) != get(a, v, -1), union(keys(b), keys(a)))

"한 팔: (좁힌|전체) release → (재가격?) → formulate → 상한 걸고 optimize → commit."
function arm!(env; agent, scoped::Bool, reprice::Bool, bias = 0.5)
    before = CB.simstate_of(env).g.binding
    inv = CB.build_invariant(env)
    rel = length(release_scoped!(env, inv; agent = scoped ? agent : nothing))
    CB.clear_payload_bias!()
    rp = nothing
    if reprice
        rp = CB.reprice_agent_by_payload!(env; agent = agent, light_bias = bias).status
    end
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    cand = CB.LAST_EDGE_COSTS[] === sent ? nothing : length(CB.LAST_EDGE_COSTS[])
    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    tstat = CB.termination_status(milp)
    CB.primal_status(milp) != CB.MOI.FEASIBLE_POINT &&
        return (status = :no_incumbent, rel = rel, cand = cand, n = nothing,
                lost = nothing, wall = wall, tstat = tstat, gap = nothing, rp = rp)
    gap = try JuMP.relative_gap(milp.model) catch; nothing end
    ok = CB.commit_respec!(env, milp,
            CB.RespecProposal(CB.ConstraintSpec[], "probe scoped release", "probe"); resume = true)
    ok === false && return (status = :commit_failed, rel = rel, cand = cand, n = nothing,
                            lost = nothing, wall = wall, tstat = tstat, gap = gap, rp = rp)
    after = CB.simstate_of(env).g.binding
    # 🔴 이 팔이 노린 것: **대상 에이전트가 일을 잃었는가.** n_reassigned 는 "뭔가 바뀌었다"만
    #    말하고, 그것이 A 의 짐이 남에게 갔다는 뜻은 아니다.
    lost = count(v -> string(get(before, v, -1)) == agent && string(get(after, v, -1)) != agent,
                 collect(keys(before)))
    return (status = :resolved, rel = rel, cand = cand, n = nreass(before, after),
            lost = lost, wall = wall, tstat = tstat, gap = gap, rp = rp)
end

fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)
_s(x) = x === nothing ? "nothing" : string(x)
show_arm(tag, r) = println("  [", tag, "] status=", r.status, " released=", r.rel,
    " 후보=", _s(r.cand), " n_reass=", _s(r.n), " A가 잃은 일=", _s(r.lost),
    " wall=", round(r.wall, digits=2), "s term=", r.tstat,
    " gap=", r.gap === nothing ? "nothing" : round(r.gap, digits=4))

function main()
    base = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "scopedrel",
                              num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7); CB.init_objective_weights!()
    println("board=colored_8x8 nv=", Graphs.nv(base.sched), " robots=6 TL=", TL, "s (세 팔 동일)")
    rows = []
    for target in (0, 62, 120, 170, 220, 250)
        k = 0
        while length(CB.simstate_of(base).prog.closed) < target && k < 4000
            CB.step_environment!(base); CB.update_planning_cache!(base, 0.0); k += 1; CB.set_sim_step!(k)
        end
        closed = length(CB.simstate_of(base).prog.closed)
        closed < target && break
        own = busiest_pending_owner(base)
        println("\n", "-"^76); println("closed = ", closed, " / ", Graphs.nv(base.sched))
        if own === nothing
            println("  대상 에이전트 없음 — 뗄 수 있는 간선이 0. 재분배 창이 닫혔다."); continue
        end
        agent, nown = own
        println("  대상 = ", agent, "  (그가 소유한 해제가능 간선 ", nown, "개)")
        saved = copy(CB.INVALID_ID_COUNTERS)
        b  = arm!(fork(base); agent = agent, scoped = false, reprice = true);  show_arm("B 전체", b)
        c  = arm!(fork(base); agent = agent, scoped = true,  reprice = true);  show_arm("C 좁힘", c)
        c0 = arm!(fork(base); agent = agent, scoped = true,  reprice = false); show_arm("C0 대조", c0)
        merge!(CB.INVALID_ID_COUNTERS, saved)   # 프로브가 실제 런의 id 발급을 밀지 않게 복원
        push!(rows, (closed = closed, nown = nown, b = b, c = c, c0 = c0))
    end
    println("\n\n", "="^88); println("요약 — 후보 축소비와 수렴"); println("="^88)
    println(rpad("closed",8), rpad("B후보",8), rpad("C후보",8), rpad("축소",8),
            rpad("C wall",9), rpad("C gap",9), rpad("C n_reass",11), rpad("C A잃음",9), "C0 n_reass")
    for r in rows
        ratio = (r.b.cand === nothing || r.c.cand === nothing || r.b.cand == 0) ? "n/a" :
                string(round(r.c.cand / r.b.cand, digits=3))
        println(rpad(string(r.closed),8), rpad(_s(r.b.cand),8), rpad(_s(r.c.cand),8), rpad(ratio,8),
                rpad(string(round(r.c.wall, digits=1), "s"),9),
                rpad(r.c.gap === nothing ? "nothing" : string(round(r.c.gap, digits=3)),9),
                rpad(_s(r.c.n),11), rpad(_s(r.c.lost),9), _s(r.c0.n))
    end
    println("\n🔴 수렴 판정은 wall < TL 이다. wall == TL 이면 그 값은 incumbent 이지 최적해가 아니다.")
end

main()
