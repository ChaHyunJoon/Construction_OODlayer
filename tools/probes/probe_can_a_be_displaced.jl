# tools/probes/probe_can_a_be_displaced.jl
#   julia +lts --project=. tools/probes/probe_can_a_be_displaced.jl [board] [nrobots] [cp1,cp2]
#
# 🔴 남은 대안 설명 하나를 죽인다. `probe_why_argmin_wont_move.jl` 의 ① 은 **후보 간선의 존재**만
#    쟀는데 그건 필요조건이지 충분조건이 아니다 — 다른 제약이 A 를 강제하고 있을 수 있다.
#
# 겨냥을 좁힌다: `ForbidAgent` 처럼 로봇을 **퇴역**시키지 않는다(그건 fault 팔이 쓰는 것이고
# "A 없이 빌드가 되나"라는 다른 질문이다). A 가 **방금 풀린 자기 슬롯**을 다시 가져가는 것만
# 막는다 — `Xa[v,v2] ≤ 0` for owner(v)==A ∧ v2 ∈ released slots. A 는 살아 있고 다른 일은 한다.
#
#   [기준] 좁힌 release 후 그대로 풀기.
#   [차단] 같은 모델에서 A 의 재탈환 간선만 0 으로 묶고 풀기.
#
# 판정:
#   · 차단이 **실행 가능** ⟹ 재배정은 가능한데 목적함수가 안 산다 = κ 상한 확정.
#     그리고 그때의 **makespan 차이**가 "에너지항이 이겨야 했던 액수"다 — κ·1% 와 직접 비교된다.
#   · 차단이 **실행 불가** ⟹ 애초에 A 를 그 슬롯에서 뺄 수 없다. 어떤 지렛대로도 안 된다.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
const TL = 60.0

function release_scoped!(env, inv; agent)
    sched = env.sched; G = CB.get_graph(sched)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    removed = Tuple{Int,Int}[]
    for e in collect(Graphs.edges(G))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v)
        (o !== nothing && string(o) == agent) || continue
        Graphs.rem_edge!(G, v, v2); push!(removed, (v, v2))
    end
    for (_, v2) in removed; CB.reset_slot_to_invalid!(env, v2); end
    return removed
end

function pending_tally(env)
    sched = env.sched; G = CB.get_graph(sched); inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{String,Int}()
    for e in Graphs.edges(G)
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
        t[string(o)] = get(t, string(o), 0) + 1
    end
    return t
end

fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)
_s(x) = x === nothing ? "nothing" : string(x)

"한 팔. `block=true` 면 A 의 재탈환 간선을 0 으로 묶는다."
function arm!(env; agent, block::Bool)
    inv = CB.build_invariant(env)
    rem = release_scoped!(env, inv; agent = agent)
    slots = Set(v2 for (_, v2) in rem)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && return (status = :no_formulate,)
    ec = copy(CB.LAST_EDGE_COSTS[]); Xa = milp.Xa
    nblocked = 0
    if block
        for (v, v2) in keys(ec)
            v2 in slots || continue
            o = CB._edge_owner_id(env.sched, v)
            (o !== nothing && string(o) == agent) || continue
            JuMP.set_upper_bound(Xa[v, v2], 0.0)   # 🔴 A 의 재탈환만 금지. 로봇은 살아 있다.
            nblocked += 1
        end
    end
    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    ts = CB.termination_status(milp)
    if CB.primal_status(milp) != CB.MOI.FEASIBLE_POINT
        return (status = :INFEASIBLE_or_no_incumbent, nblocked = nblocked, ncand = length(ec),
                nslots = length(slots), wall = wall, tstat = ts, obj = nothing, mk = nothing,
                taken_by_A = nothing)
    end
    obj = try JuMP.objective_value(milp.model) catch; nothing end
    # 풀린 슬롯을 실제로 누가 가져갔나
    takenA = 0
    for (v, v2) in keys(ec)
        v2 in slots || continue
        JuMP.value(Xa[v, v2]) > 0.5 || continue
        o = CB._edge_owner_id(env.sched, v)
        (o !== nothing && string(o) == agent) && (takenA += 1)
    end
    ok = CB.commit_respec!(env, milp,
            CB.RespecProposal(CB.ConstraintSpec[], "displace probe", "probe"); resume = true)
    mk = ok === false ? nothing : CB.makespan(env.sched)
    return (status = :feasible, nblocked = nblocked, ncand = length(ec), nslots = length(slots),
            wall = wall, tstat = ts, obj = obj, mk = mk, taken_by_A = takenA)
end

function main()
    bd = length(ARGS) >= 1 ? ARGS[1] : "tractor.mpd"
    nr = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
    cps = length(ARGS) >= 3 ? parse.(Int, split(ARGS[3], ",")) : [60, 151]
    println("BOARD=", bd, " robots=", nr, " checkpoints=", cps, " TL=", TL, "s")
    base = CB.run_lego_demo(; ldraw_file = bd, project_name = "displace", num_robots = nr,
                              assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7); CB.init_objective_weights!()
    saved = copy(CB.INVALID_ID_COUNTERS)
    for target in cps
        k = 0
        while length(CB.simstate_of(base).prog.closed) < target && k < 6000
            CB.step_environment!(base); CB.update_planning_cache!(base, 0.0); k += 1; CB.set_sim_step!(k)
        end
        closed = length(CB.simstate_of(base).prog.closed)
        t = pending_tally(base)
        println("\n", "="^76); println("closed = ", closed, " / ", Graphs.nv(base.sched))
        if isempty(t); println("  뗄 간선 0 — 창이 닫혔다"); continue; end
        agent = sort(collect(t), by = kv -> -kv[2])[1][1]
        println("  A = ", agent, "  (해제가능 간선 ", sort(collect(t), by = kv -> -kv[2])[1][2], "개)")
        b = arm!(fork(base); agent = agent, block = false)
        c = arm!(fork(base); agent = agent, block = true)
        for (tag, r) in (("기준", b), ("차단", c))
            r.status === :no_formulate && (println("  [", tag, "] formulate 안 돎"); continue)
            println("  [", tag, "] ", r.status, "  풀린슬롯=", r.nslots, " 후보=", r.ncand,
                    " 막은간선=", r.nblocked, "  term=", r.tstat,
                    "  obj=", r.obj === nothing ? "nothing" : round(r.obj, digits=4),
                    "  makespan=", r.mk === nothing ? "nothing" : round(r.mk, digits=4),
                    "  A가 다시 가져간 슬롯=", _s(r.taken_by_A), " wall=", round(r.wall, digits=2), "s")
        end
        if b.status === :feasible && c.status === :feasible &&
           b.mk !== nothing && c.mk !== nothing && b.obj !== nothing && c.obj !== nothing
            dmk = c.mk - b.mk; dobj = c.obj - b.obj
            println("  🔴 판정: 차단이 **실행 가능** ⟹ 재배정은 가능한데 목적함수가 안 산다.")
            println("     Δmakespan = ", round(dmk, digits=4),
                    " (", round(100*dmk/max(b.mk,eps()), digits=3), "%)   Δobjective = ", round(dobj, digits=6))
            println("     ⟹ 에너지항이 이겨야 했던 액수다. κ=", CB.AUTO_EFFICIENCY_KAPPA[],
                    " 는 에너지항 전체를 makespan 규모의 ~", 100*CB.AUTO_EFFICIENCY_KAPPA[], "% 로 묶는다.")
        elseif c.status !== :feasible
            println("  🔴 판정: 차단이 **실행 불가/incumbent 없음** ⟹ A 를 그 슬롯에서 뺄 수 없다.")
        end
        merge!(CB.INVALID_ID_COUNTERS, saved)
    end
end
main()
