# tools/probes/probe_release_in_harness.jl
#   julia +lts --project=. tools/probes/probe_release_in_harness.jl
#
# 결정 프로브: release 를 **harness**(`resolve_assignments!`) 안으로 넣을 것인가.
#
# 기록에 이미 있는 것 (memory/s2-payload-channel-is-closed-four-ways, 표 6):
#   release 를 **한 뒤** 후보 간선이 closed 에 따라 1320 → 890 → ... → 80 → 0 으로 닫힌다.
# 🔴 기록에 **없는** 것 = 이 프로브가 재는 것:
#   (a) release 를 **안 한** 상태의 후보 간선이 결정 시점에도 0 인가 (t=0 에서만 쟀다),
#   (b) 그러므로 오늘의 `resolve_assignments!`(T13) 의 `n_reassigned` 가 실제로 0 인가
#       — 기존 시험의 단언은 `n_reassigned >= 0` 이라는 **항진**이라 아무도 안 쟀다,
#   (c) release 를 넣으면 `n_reassigned` 가 0 이 아니게 되는가, 그리고 **얼마나 걸리는가**
#       (S2 는 tractor 에서 300s 에 gap 35% = 미수렴을 쟀다. 매 스텝 그 값을 낼 수는 없다).
#
# 🔴 삼상 규약: 못 쟀으면 `nothing` 이지 0 이 아니다. 후보 간선은 센티넬로 formulate 가
#    실제로 돌았는지 확인한 뒤에만 읽는다.
# 🔴 JULIA SOFT SCOPE: 모든 집계는 함수 안에서.
# 🔴 결정론 단위는 디렉터리다 — 전부 한 프로세스, 한 `main()` 안에서 돈다.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

const TL = 60.0   # 🔴 두 팔에 **같은** 상한. 대칭이 아니면 팔이 비교 불가다.

"formulate 를 돌려 후보 배정 간선 수를 정답원(`LAST_EDGE_COSTS`)에서 읽는다.
`nothing` = formulate 가 안 돌았다(= 못 쟀다), 0 과 절대 섞지 않는다."
function candidates(sched, tree)
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    CB.LAST_EDGE_COSTS[] === sent && return nothing
    return length(CB.LAST_EDGE_COSTS[])
end

"두 binding dict 사이에서 배정이 바뀐 정점 수 (`resolve_assignments!` 와 **같은** 정의)."
function nreassigned(before, after)
    n = 0
    for v in union(keys(before), keys(after))
        get(before, v, -1) == get(after, v, -1) || (n += 1)
    end
    return n
end

"""
팔 B: `resolve_assignments!` 를 **한 줄 한 줄 그대로** 재현하되 (1) 앞에 release 를 넣고
(2) 시간 상한을 건다. 상한이 필요한 이유는 `_respec_optimizer()` 가 무제한이기 때문이다
(`src/respec/verifier.jl:70`) — S2 가 tractor 에서 28분 미수렴을 쟀다.
"""
function resolve_with_release!(env; time_limit = TL)
    before = CB.simstate_of(env).g.binding
    inv    = CB.build_invariant(env)
    released = length(CB.release_pending_assignments!(env, inv))
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    cand = CB.LAST_EDGE_COSTS[] === sent ? nothing : length(CB.LAST_EDGE_COSTS[])
    CB.set_time_limit_sec(milp, time_limit)
    wall = @elapsed CB.optimize!(milp)
    tstat = CB.termination_status(milp)
    if CB.primal_status(milp) != CB.MOI.FEASIBLE_POINT
        return (status = :infeasible_or_no_incumbent, released = released, cand = cand,
                n = nothing, wall = wall, tstat = tstat, gap = nothing)
    end
    gap = try JuMP.relative_gap(milp.model) catch; nothing end
    ok = CB.commit_respec!(env, milp,
            CB.RespecProposal(CB.ConstraintSpec[], "probe: release+resolve", "probe");
            resume = true)
    ok === false && return (status = :commit_failed, released = released, cand = cand,
                            n = nothing, wall = wall, tstat = tstat, gap = gap)
    return (status = :resolved, released = released, cand = cand,
            n = nreassigned(before, CB.simstate_of(env).g.binding),
            wall = wall, tstat = tstat, gap = gap)
end

function checkpoint(base, label)
    closed = length(CB.simstate_of(base).prog.closed)
    nv = Graphs.nv(base.sched)
    println("\n", "-"^76)
    println("closed = ", closed, " / ", nv, "   (", label, ")")

    # (a) release 를 **안 한** 후보 간선 — 결정 시점에서.
    sc, tr = deepcopy((base.sched, base.scene_tree))
    c_norel = candidates(sc, tr)
    println("  후보 간선  release 없이 = ", c_norel === nothing ? "nothing(못 쟀다)" : c_norel)

    # (b) 오늘의 T13 — 그대로.
    fa = (e = deepcopy(base); CB.rvo_rebuild!(e); e)
    wa = @elapsed ra = CB.resolve_assignments!(fa)
    println("  [A] 오늘의 resolve_assignments!  status=", ra.status,
            "  n_reassigned=", ra.n_reassigned, "  wall=", round(wa, digits=2), "s")

    # (c) release 를 harness 에 넣은 팔.
    saved = copy(CB.INVALID_ID_COUNTERS)
    fb = (e = deepcopy(base); CB.rvo_rebuild!(e); e)
    rb = resolve_with_release!(fb)
    drift = [k => (CB.INVALID_ID_COUNTERS[k] - get(saved, k, 0))
             for k in keys(CB.INVALID_ID_COUNTERS) if CB.INVALID_ID_COUNTERS[k] != get(saved, k, 0)]
    println("  [B] release + resolve            status=", rb.status,
            "  released=", rb.released, "  후보=", rb.cand === nothing ? "nothing" : rb.cand,
            "\n      n_reassigned=", rb.n === nothing ? "nothing" : rb.n,
            "  wall=", round(rb.wall, digits=2), "s  term=", rb.tstat,
            "  gap=", rb.gap === nothing ? "nothing" : round(rb.gap, digits=4))
    println("      🔴 INVALID_ID_COUNTERS 드리프트 = ", isempty(drift) ? "없음" : drift)
    return (closed = closed, c_norel = c_norel, a = ra, b = rb)
end

function main()
    base = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t13fork",
                              num_robots = 6, assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7)
    CB.init_objective_weights!()   # 🔴 없으면 목적식이 edge_costs 를 통째로 버린다
    nv = Graphs.nv(base.sched)
    println("board=colored_8x8  nv=", nv, "  robots=6  TIME_LIMIT=", TL, "s (두 팔 동일)")

    rows = []
    push!(rows, checkpoint(base, "t=0"))
    for target in (60, 120, 170, 220, 250)
        k = 0
        while length(CB.simstate_of(base).prog.closed) < target && k < 4000
            CB.step_environment!(base); CB.update_planning_cache!(base, 0.0)
            k += 1; CB.set_sim_step!(k)
        end
        length(CB.simstate_of(base).prog.closed) < target && break
        push!(rows, checkpoint(base, "closed>=$(target)"))
    end

    println("\n\n", "="^76); println("요약"); println("="^76)
    println(rpad("closed",9), rpad("후보(release없이)",20), rpad("[A] n_reass",13),
            rpad("[B] released",13), rpad("[B] 후보",10), rpad("[B] n_reass",12), "[B] wall")
    for r in rows
        println(rpad(string(r.closed),9),
                rpad(r.c_norel === nothing ? "nothing" : string(r.c_norel), 20),
                rpad(string(r.a.n_reassigned), 13),
                rpad(string(r.b.released), 13),
                rpad(r.b.cand === nothing ? "nothing" : string(r.b.cand), 10),
                rpad(r.b.n === nothing ? "nothing" : string(r.b.n), 12),
                string(round(r.b.wall, digits=2), "s"))
    end
end

main()
