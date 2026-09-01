# tools/probes/probe_reprice_moves_assignment.jl
#   julia +lts --project=. tools/probes/probe_reprice_moves_assignment.jl
#
# S2 payload-reprice lane, Task 5b — one-shot MEASUREMENT probe, NOT a gate, NOT a test.
#
# Task 5 (concurrent, different file: test/payload_reprice_changes_plan.jl) proves repricing
# changes edge COST VALUES (`base != hot` in `CB.LAST_EDGE_COSTS[]`). That is necessary but not
# sufficient: a cost bump that never crosses another feasible assignment's cost changes the
# NUMBER on an edge without ever changing what the MILP actually picks. This probe answers the
# harder question directly: does repricing move the ARGMIN — does `formulate_milp` +
# `optimize!` actually hand agent A's work to a different robot?
#
# 🔴 CONTROLLER RULING (post-hoc, after a first unbounded run stalled at 28.8% gap for >28min on
#    the tractor board): `_respec_optimizer()` is bare `HiGHS.Optimizer` with NO time limit
#    (src/respec/verifier.jl:70). On a 2103-candidate-binary MILP, three unbounded solves will
#    not finish in any practical time. So EVERY solve below gets the SAME time limit — symmetry
#    is essential or the arms are incomparable — and results are reported as
#    termination_status/primal_status/wall-clock/gap/objective, not assumed to be optimal.
#    🔴 A feasible incumbent appears quickly; proven optimality does not. That gap is itself a
#    finding about the design: the "MILP 재풀이" this lane's L2 tool body performs is (at best)
#    an incumbent, not an optimum. Recorded below regardless of what else this probe measures.
#    🔴 `NO_SOLUTION` (limit expired, no incumbent) is NOT `INFEASIBLE` — never conflate them.
#
# 🔴 EVERYTHING IN ONE PROCESS, ONE DIRECTORY, inside one `main()`. This repo's determinism unit
#    is the compile-cache DIRECTORY, not the process — the same commit in two worktrees produced
#    makespan 19.875 vs 19.050 (see MEMORY.md, sim-runs-must-be-seed-reproducible). A cross-process
#    comparison here would be meaningless, so every solve on every board happens in this one run.
#    Also: this branch lacks `bb1b88c4`'s content-based `AbstractID` hash, so `deepcopy` of
#    ID-keyed Dicts/Sets can reorder iteration and change model-build order BETWEEN arms even
#    within one process — which is exactly what the negative control below is for.
#
# 🔴 JULIA SOFT SCOPE: every count/accumulation happens INSIDE a function. A counter incremented
#    in a top-level `for` reports a silent 0 (see tools/probes/probe_kappa_alive.jl header).
#
# 🔴 TWO PRECONDITIONS, both measured earlier in this lane, that make or break this probe:
#   - `CB.enable_battery!(env; params = CB.BatteryParams())` — `run_lego_demo` never initialises
#     the battery fleet. Without this, `reprice_agent_by_payload!` returns `:no_fleet` and installs
#     NOTHING (task-5-addendum.md Ruling 7 / test/payload_release_is_safe.jl). `:repriced` is
#     asserted below as a PRECONDITION ONLY — never cited as evidence the world changed.
#   - `CB.init_objective_weights!()` — without it `AUTO_EFFICIENCY_KAPPA[]` is `nothing` and the
#     objective DISCARDS `edge_costs` entirely (see tools/probes/probe_kappa_alive.jl), which
#     would make this whole probe vacuous regardless of what repricing does to the dict.
using ConstructionBots
import Random, Graphs
using JuMP, SparseArrays
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

const TIME_LIMIT_S = 300.0   # 🔴 SAME for every solve on every board — symmetry, per controller ruling.

"후보 간선 (v,v2) 목록에서 가장 많이 등장하는 유효 owner id. Task 5's busiest_agent(), same idiom.
🔴 MODULE-QUALIFIED form (`string(CB._edge_owner_id(...))` == \"ConstructionBots.BotID{...}(2)\") —
never a hand-written short form, which silently yields `:unknown_agent`."
function busiest_agent(env)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sentinel
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sentinel)
    ran || error("busiest_agent: formulate_milp did not run (LAST_EDGE_COSTS untouched)")
    tally = Dict{String,Int}()
    for (v, _) in keys(CB.LAST_EDGE_COSTS[])
        id = CB._edge_owner_id(sched, v)
        id === nothing && continue
        tally[string(id)] = get(tally, string(id), 0) + 1
    end
    isempty(tally) && error("busiest_agent: no valid owner ids among candidate edges")
    ranked = sort(collect(tally), by = kv -> -kv[2])
    return (agent = ranked[1][1], n_edges = ranked[1][2], n_candidates = length(CB.LAST_EDGE_COSTS[]))
end

"try f() and return nothing (instead of throwing) on any error — for post-solve queries that
are only meaningful in some termination states (e.g. objective_value with no incumbent)."
function safe(f)
    try
        return f()
    catch
        return nothing
    end
end

"""
    run_arm(env, target_agent, bias, time_limit) -> NamedTuple

One MILP arm, time-bounded: deepcopy (sched,scene_tree) together, release, (maybe) reprice
`target_agent` by `bias`, formulate, solve with a `time_limit` second cap. Returns
termination_status, primal_status, wall-clock seconds, relative gap, objective value, the
candidate-edge key set, and the SET of SELECTED assignment edges (candidate edges whose solved
Xa value is ~1 — only populated when primal_status is FEASIBLE_POINT, i.e. an incumbent exists).
"""
function run_arm(env, target_agent, bias::Float64, time_limit::Float64)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    CB.clear_payload_bias!()
    if bias > 0.0
        r = CB.reprice_agent_by_payload!(shim; agent = target_agent, light_bias = bias)
        # 🔴 PRECONDITION ONLY — :repriced proves the hook installed, not that the world changed.
        @assert r.status === :repriced "reprice did not install: $(r.status)"
    end
    sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sentinel
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sentinel)
    ran || error("run_arm(bias=$bias): formulate_milp did not run")
    ec = copy(CB.LAST_EDGE_COSTS[])
    CB.set_time_limit_sec(milp, time_limit)
    wall = @elapsed CB.optimize!(milp)
    tstat = CB.termination_status(milp)
    pstat = CB.primal_status(milp)
    gap = safe(() -> JuMP.relative_gap(milp.model))
    obj = safe(() -> JuMP.objective_value(milp.model))
    bound = safe(() -> CB.objective_bound(milp))
    Xa = milp.Xa
    selected = Set{Tuple{Int,Int}}()
    if pstat == CB.MOI.FEASIBLE_POINT
        for (v, v2) in keys(ec)
            value(Xa[v, v2]) > 0.5 && push!(selected, (v, v2))
        end
    end
    CB.clear_payload_bias!()
    return (bias = bias, termination_status = tstat, primal_status = pstat, wall_s = wall,
            gap = gap, objective = obj, bound = bound, candidates = Set(keys(ec)),
            selected = selected, sched = sched)
end

"differing (v,v2) 중 target_agent 소유(= _edge_owner_id(sched, v) 가 target 과 일치)인 간선 수."
function count_owned(diff_edges, sched, target_agent)
    n = 0
    for (v, _) in diff_edges
        id = CB._edge_owner_id(sched, v)
        id !== nothing && string(id) == target_agent && (n += 1)
    end
    return n
end

fmt(x) = x === nothing ? "n/a" : (x isa AbstractFloat ? round(x; digits = 6) : x)

function print_arm_row(label, a)
    println(rpad(label, 22), " termination=", rpad(string(a.termination_status), 16),
            " primal=", rpad(string(a.primal_status), 16),
            " wall_s=", rpad(string(round(a.wall_s; digits = 2)), 10),
            " gap=", rpad(string(fmt(a.gap)), 12),
            " obj=", rpad(string(fmt(a.objective)), 14),
            " bound=", fmt(a.bound))
end

"""
    run_board(ldraw, nrobots, project_name, time_limit) -> NamedTuple

Full probe on one board: build env, enable battery, init objective weights (idempotent — safe
to call again per board), pick the busiest agent, run arms A (bias=0, control), B (bias=0,
control, second solve — the negative control), T (bias=2.0, treatment), each capped at
`time_limit` seconds. Prints the per-solve table and the verdict. Returns whether the negative
control held (`control_ok = |AΔB| == 0` AND both A,B had an incumbent) plus the raw arms.
"""
function run_board(ldraw, nrobots, project_name, time_limit)
    println("\n" , "="^78)
    println("BOARD = ", ldraw, "  robots=", nrobots, "  time_limit=", time_limit, "s per solve")
    println("="^78)
    env = CB.run_lego_demo(; ldraw_file = ldraw, project_name = project_name,
                             num_robots = nrobots, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    println("closed (env.cache.closed_set) = ", length(env.cache.closed_set),
            " / ", Graphs.nv(env.sched), "   (expect 0: return_env_before_sim=true)")

    CB.enable_battery!(env; params = CB.BatteryParams())
    println("BATTERY_FLEET[] after enable_battery! = ", CB.BATTERY_FLEET[] === nothing ? "nothing" : "installed")

    kappa_before = CB.AUTO_EFFICIENCY_KAPPA[]
    CB.init_objective_weights!()
    println("AUTO_EFFICIENCY_KAPPA[] before/after init_objective_weights! = ",
            kappa_before, " / ", CB.AUTO_EFFICIENCY_KAPPA[])

    ba = busiest_agent(env)
    target = ba.agent
    println("target agent (busiest owner among candidate edges) = ", target,
            "   (", ba.n_edges, " / ", ba.n_candidates, " candidate edges)")

    println("\n--- solving arm A (bias=0.0, control) ---")
    A = run_arm(env, target, 0.0, time_limit)
    println("\n--- solving arm B (bias=0.0, control, second solve — the negative control) ---")
    B = run_arm(env, target, 0.0, time_limit)
    println("\n--- solving arm T (bias=2.0, treatment) ---")
    T = run_arm(env, target, 2.0, time_limit)

    println("\n==== per-solve table (board=", ldraw, ") ====")
    print_arm_row("A bias=0.0 (control)", A)
    print_arm_row("B bias=0.0 (control2)", B)
    print_arm_row("T bias=2.0 (treatment)", T)

    a_has_sol = A.primal_status == CB.MOI.FEASIBLE_POINT
    b_has_sol = B.primal_status == CB.MOI.FEASIBLE_POINT
    t_has_sol = T.primal_status == CB.MOI.FEASIBLE_POINT

    if !(a_has_sol && b_has_sol)
        println("\n🔴 NO_SOLUTION on A or B (limit expired with no incumbent) — negative control",
                " cannot even be formed. A.primal=", A.primal_status, " B.primal=", B.primal_status,
                ". Stopping this board's argmin comparison here.")
        return (board = ldraw, control_ok = false, A = A, B = B, T = T, target = target)
    end

    diff_AB = symdiff(A.selected, B.selected)
    control_ok = length(diff_AB) == 0
    println("\n|selected(A) Δ selected(B)| (negative control, both bias=0.0) = ", length(diff_AB))

    if !control_ok
        println("\n🔴 UNINTERPRETABLE on board=", ldraw, ": the negative control (two bias=0.0",
                " time-limited solves) selected DIFFERENT assignment edges (|AΔB|=", length(diff_AB),
                "). A time-limited B&B incumbent depends on the search path, and this branch lacks",
                " bb1b88c4's content-based AbstractID hash, so deepcopy can reorder ID-keyed",
                " iteration and change model build order between arms. No retry to chase a clean",
                " control — reporting as-is.")
        if t_has_sol
            diff_AT_unusable = symdiff(A.selected, T.selected)
            println("   (for the record, |AΔT| = ", length(diff_AT_unusable),
                    " — NOT interpretable given the control above.)")
        end
        return (board = ldraw, control_ok = false, A = A, B = B, T = T, target = target)
    end

    if !t_has_sol
        println("\n🔴 NO_SOLUTION on T (treatment; limit expired with no incumbent). Control held",
                " (|AΔB|=0) but the treatment arm has nothing to compare — cannot answer the",
                " argmin question on this board within ", time_limit, "s.")
        return (board = ldraw, control_ok = true, A = A, B = B, T = T, target = target)
    end

    diff_AT = symdiff(A.selected, T.selected)
    n_owned_AT = count_owned(diff_AT, A.sched, target)
    println("|selected(A) Δ selected(T)| (bias=0.0 vs bias=2.0)            = ", length(diff_AT))
    println("of the differing edges, owned by target agent (", target, ") = ", n_owned_AT,
            " / ", length(diff_AT))
    println("candidate-edge sets equal across arms (keys(A)==keys(B)==keys(T))? ",
            A.candidates == B.candidates == T.candidates)

    println("\n==== VERDICT (board=", ldraw, ") ====")
    if length(diff_AT) == 0
        println("Repricing (light_bias=2.0) did NOT move the argmin on this board: the MILP",
                " selected the IDENTICAL set of assignment edges as the bias=0.0 control (|AΔT|=0).",
                " The cost term moved (Task 5) but never crossed another feasible assignment's cost,",
                " so the decision itself did not change. This is a legitimate, reportable negative",
                " result — light_bias=2.0 was not re-tried at other values.")
    else
        println("Repricing (light_bias=2.0) DID move the argmin: ", length(diff_AT),
                " assignment edge(s) differ between control and treatment, ", n_owned_AT,
                " of them on the repriced agent ", target, ". The MILP assigned different work",
                " to a different robot as a direct result of the payload bias.")
    end
    return (board = ldraw, control_ok = true, A = A, B = B, T = T, target = target, diff_AT = diff_AT)
end

function main()
    println("\n==== light_bias values tried (every board) ====")
    println("bias=0.0 (control, twice — A and B)  and  bias=2.0 (treatment). No other value tried.")

    arm1 = run_board("tractor.mpd", 10, "s2reprice5b", TIME_LIMIT_S)

    if arm1.control_ok
        println("\n\nArm 1's negative control HELD on tractor.mpd — Arm 2 (colored_8x8.ldr) is",
                " SKIPPED per the controller's instruction (only run it if Arm 1's control fails).")
    else
        println("\n\nArm 1's negative control FAILED on tractor.mpd — running Arm 2 on",
                " colored_8x8.ldr (nv 342 / ne 423, far smaller, may solve to proven optimality).",
                " This answers the argmin question on a DIFFERENT board, not on tractor.")
        arm2 = run_board("colored_8x8.ldr", 6, "s2reprice5b-c8x8", TIME_LIMIT_S)
    end

    println("\n\n==== TRACTOR NON-CONVERGENCE FINDING (recorded regardless of the rest) ====")
    println("An earlier unbounded run of this same probe on tractor.mpd (same fixture, same",
            " optimizer, no time limit) ran 1705.5s on arm A alone and was still at BestBound=",
            "8.223884058 BestSol=11.55103861 Gap=28.80% with the gap flat for hundreds of seconds",
            " before being killed. `_respec_optimizer()` is bare HiGHS.Optimizer with no time",
            " limit (src/respec/verifier.jl:70). On the tractor board's ~2103 candidate binaries,",
            " a feasible incumbent appears quickly but proven optimality does not, in any",
            " practical time. The L2 tool body's post-action \"MILP 재풀이\" is, on boards like",
            " this one, an INCUMBENT, not a verified optimum — nobody in this lane had written",
            " that down before this probe.")
end

main()
