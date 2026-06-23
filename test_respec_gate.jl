# =============================================================================
# test_respec_gate.jl  --  Prove the verify GATE on a real schedule, no LLM.
#
# Builds a real env (assignment done, simulation NOT started) and checks that
# verify():
#   * ADMITS a non-binding constraint (feasible), and
#   * REJECTS an impossible constraint as :infeasible.
# This demonstrates "even if the LLM is wrong, the gate blocks unsafe specs"
# before any API key / network is involved.
#
# Run:  julia --project=. test_respec_gate.jl
# =============================================================================
using ConstructionBots
import Graphs
const CB = ConstructionBots

# Big C stack: the geometry/transform recursion overflows the default stack.
# (Copied verbatim from run_demo_fast.jl.)
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

project_params = get_project_params(4)   # tractor — the project the user has run successfully
                                          # (project 1 / colored_8x8 segfaults in ECOS geometry overapprox)

println(">>> building env (assignment only, no simulation)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=:greedy,
        milp_optimizer=:highs,
        optimizer_time_limit=60,
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true,          # the new RESPEC option
    )
end

@assert env !== nothing "run_lego_demo returned nothing — did return_env_before_sim fire?"
nnodes = Graphs.nv(env.sched)
println(">>> env built. schedule nodes = $nnodes, closed = $(length(env.cache.closed_set))")

# A real, still-open node id, and a freeze snapshot (empty: nothing executed yet).
nid = CB.get_vtx_id(env.sched, 1)
inv = CB.build_invariant(env)
println(">>> target node id = $nid")

# --- ADMIT: a huge, non-binding deadline is feasible -------------------------
good = CB.RespecProposal([CB.Deadline(nid, 1e9)])
vg = CB.verify(good, env, inv)
println(">>> Deadline(nid, 1e9)  => ", vg isa CB.Admit ? "ADMIT ($(vg.n_constraints) constr)" : "Reject($(vg.reason))")

# --- REJECT: tF[v] >= 0 always, so tF <= -1 is always infeasible --------------
bad = CB.RespecProposal([CB.Deadline(nid, -1.0)])
vb = CB.verify(bad, env, inv)
println(">>> Deadline(nid, -1.0) => ", vb isa CB.Reject ? "REJECT(:$(vb.reason))" : "Admit (UNEXPECTED)")

@assert vg isa CB.Admit  "expected ADMIT for non-binding deadline, got $(typeof(vg))"
@assert vb isa CB.Reject "expected REJECT for impossible deadline, got $(typeof(vb))"
@assert vb.reason == :infeasible "expected :infeasible, got :$(vb.reason)"

println("\n==================  GATE TEST PASSED  ==================")
println("The verify gate ADMITS feasible re-specs and REJECTS infeasible ones")
println("on a real schedule, with zero LLM involvement. Safety is in the gate.")

# =============================================================================
# FREEZE TEST: step the sim until some nodes complete, then confirm
# build_invariant pins their realized times and the gate still respects them.
# =============================================================================
println("\n>>> stepping simulation to close some nodes (rvo off, straight-line)...")
nclosed0 = length(env.cache.closed_set)
for i in 1:5000
    ConstructionBots.step_environment!(env)
    ConstructionBots.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= nclosed0 + 5 && break
end
nclosed = length(env.cache.closed_set)
println(">>> closed nodes: $nclosed0 -> $nclosed ; active = $(length(env.cache.active_set))")
@assert nclosed > nclosed0 "stepping closed no nodes — cache may not be seeded"

inv2 = CB.build_invariant(env)
println(">>> frozen_t0 entries = $(length(inv2.frozen_t0)), frozen_tF entries = $(length(inv2.frozen_tF))")
@assert !isempty(inv2.frozen_t0) "freeze produced no t0 lower bounds"
@assert !isempty(inv2.frozen_tF) "freeze produced no tF lower bounds (no closed nodes pinned)"

# A closed node's pinned tF must be a real (finite, >= 0) realized time.
some_closed = first(inv2.frozen_tF)
println(">>> sample pinned closed node: id=$(some_closed[1]) tF>=$(round(some_closed[2], digits=3))")
@assert isfinite(some_closed[2]) && some_closed[2] >= 0.0

# The gate must still ADMIT a feasible re-spec while honoring the freeze, i.e.
# the re-solved schedule does not pull frozen work earlier (satisfies_invariant).
open_v = first(v for v in Graphs.vertices(env.sched) if !(CB.get_vtx_id(env.sched, v) in inv2.closed_nodes))
nid2 = CB.get_vtx_id(env.sched, open_v)
good2 = CB.RespecProposal([CB.Deadline(nid2, 1e9)])
vg2 = CB.verify(good2, env, inv2)
println(">>> verify with non-empty freeze => ", vg2 isa CB.Admit ? "ADMIT (freeze respected)" : "Reject(:$(vg2.reason))")
@assert vg2 isa CB.Admit "expected ADMIT honoring freeze, got $(typeof(vg2))"

println("\n==================  FREEZE TEST PASSED  ==================")
println("Completed nodes are pinned to their realized times; the re-solve plans")
println("only the future and never pulls finished work into the past.")
println("\n>>>>>>>>>>>>>>  ALL TESTS PASSED  <<<<<<<<<<<<<<")
