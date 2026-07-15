# =============================================================================
# tools/test_deprioritize_integration.jl
#   Integration verification of the TIER-2 DeprioritizeAgent on a REAL env (no LLM):
#     (1) verify_deprioritize ADMITS a real robot, REJECTS a non-existent / closed one.
#     (2) feasibility-PRESERVING: a re-solve with the agent biased stays FEASIBLE.
#     (3) it actually REROUTES: the biased robot does <= as much assignment work as baseline.
#   Builds ONE small env (greedy) and re-solves; mirrors the maybe_respecify! soft-dispatch
#   path without the LLM round-trip.
#   Run:  julia +lts --project=. tools/test_deprioritize_integration.jl
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP
const CB = ConstructionBots
const value = JuMP.value
const PASS = Ref(0); const FAILN = Ref(0)
chk(c, m) = (c ? (PASS[] += 1) : (FAILN[] += 1; println("  FAIL: ", m)))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 120.0, "presolve" => "on", "mip_rel_gap" => 0.02, CB.MOI.Silent() => true)
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.01)
CB.set_energy_model!(load_power = 0.25)

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e2, bt = err[]; showerror(stderr, e2, bt); println(stderr); rethrow(e2)
    end
    return res[]
end

pp = CB.get_project_params(4)   # tractor
println(">>> building env (greedy)...")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
inv = CB.build_invariant(env)
CB.release_pending_assignments!(env, inv; faulted = nothing)
robots = sort([CB.node_id(n) for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]; by = r -> r.id)
R = robots[1]
println(">>> env built; $(length(robots)) robots; deprioritizing $(R)\n")

# count selected assignment edges OWNED by robot `rid` in a solved milp
function owned_edge_usage(milp, sched, rid)
    u = 0.0
    for ((v, v2), _) in CB.LAST_EDGE_COSTS[]
        CB._edge_owner_id(sched, v) == rid || continue
        try; u += value(milp.Xa[v, v2]); catch; end
    end
    return u
end

# (1) verify_deprioritize gate
println("== (1) verify_deprioritize: admit real robot, reject non-existent ==")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(R, 100.0)]), env) isa CB.Admit, "real robot admitted")
chk(CB.verify_deprioritize(CB.RespecProposal([CB.DeprioritizeAgent(CB.RobotID(999999), 100.0)]), env) isa CB.Reject, "fake robot rejected")

# (2) baseline solve (no bias)
println("== (2) baseline re-solve (no bias) ==")
CB.clear_agent_bias!()
milp0 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp0)
feas0 = JuMP.primal_status(milp0.model) == CB.MOI.FEASIBLE_POINT
usage0 = owned_edge_usage(milp0, env.sched, R)
ms0 = try maximum(value.(milp0.model[:tF])) catch; NaN end
chk(feas0, "baseline feasible")
println("   baseline: feasible=$feas0  R-edge-usage=$(round(usage0,digits=2))  makespan=$(round(ms0,digits=2))")

# (3) biased solve: feasibility preserved + R does <= work
println("== (3) deprioritize R (factor 1000, clamped) -> re-solve ==")
f = CB.deprioritize_agent!(R, 1000.0)
chk(f == CB.MAX_AGENT_COST_BIAS, "factor clamped to MAX")
milp1 = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
CB.optimize!(milp1)
feas1 = JuMP.primal_status(milp1.model) == CB.MOI.FEASIBLE_POINT
usage1 = owned_edge_usage(milp1, env.sched, R)
ms1 = try maximum(value.(milp1.model[:tF])) catch; NaN end
chk(feas1, "feasibility PRESERVED after deprioritize (soft spec never stalls)")
chk(usage1 <= usage0 + 1e-6, "deprioritized robot does <= baseline assignment work ($(round(usage1,digits=2)) <= $(round(usage0,digits=2)))")
println("   biased:   feasible=$feas1  R-edge-usage=$(round(usage1,digits=2))  makespan=$(round(ms1,digits=2))")
CB.clear_agent_bias!()

println("\n== RESULT: $(PASS[]) passed, $(FAILN[]) failed ==")
exit(FAILN[] == 0 ? 0 : 1)
