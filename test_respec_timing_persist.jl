# =============================================================================
# test_respec_timing_persist.jl  --  LLM-FREE verification that the commit
# (persist_milp_times!) makes the timing-only re-spec (ForbidWindow) STICK past
# commit. ForbidWindow adds NO graph edge, so its effect lives PURELY in the
# written MILP times — making it the direct test of persist_milp_times!.
# Reproduces the diagnostic in docs/timing_respec_persistence_gap_2026-06-19.md
# and asserts it now passes.
#
#   julia +lts --project=. test_respec_timing_persist.jl
#
# No Python service / no API key needed: it uses hand-written proposals through
# the same verify -> commit_respec! path the LLM would drive.
# =============================================================================
using ConstructionBots
import Graphs
import Logging
import HiGHS
import JuMP
const CB = ConstructionBots

# NOTE: do NOT cache the env via Serialization — round-tripping a built env through
# serialize/deserialize subtly corrupts its cached transforms/schedule state, which
# made update_project_schedule! re-derive a 6x-inflated makespan and produced a
# FALSE "write mechanism broken" failure. Always build fresh for trustworthy timing
# numbers. (deepcopy, used per-test below, IS faithful — only serialize is not.)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0,
    CB.MOI.Silent() => true)

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

pp = get_project_params(4)   # tractor
println(">>> building env (assignment only)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env ready: $(Graphs.nv(env.sched)) nodes")

# Collect open AssemblyComplete milestone nodes (what a ForbidWindow targets).
# Skip active nodes too: persist_milp_times! keeps a started node's realized t0, so
# a binding start-shift can only be tested on a not-yet-started (future) node.
asm_nodes = CB.AbstractID[]
for v in Graphs.vertices(env.sched)
    (v in env.cache.closed_set || v in env.cache.active_set) && continue
    node = CB.get_node(env.sched, v).node
    node isa CB.AssemblyComplete || continue
    push!(asm_nodes, CB.get_vtx_id(env.sched, v))
end
println(">>> open AssemblyComplete milestones: $(length(asm_nodes))")
@assert !isempty(asm_nodes) "need >=1 future milestone node to test ForbidWindow"

# ---------------------------------------------------------------------------
# TEST: ForbidWindow is the only remaining timing-only re-spec, and it adds NO
# graph edge — so its effect lives PURELY in the written MILP times. If the write
# mechanism (persist_milp_times!) did nothing, the structural pass would snap the
# node back to its earliest start at commit and this FAILS.
#
# Make the window genuinely BINDING: pick a future milestone, read its natural
# start t0n, and forbid [0, t0n + Δ]. "Finish before 0" is impossible (tF>=0), so
# the node MUST "start after t_hi" => t0 is forced up to >= t0n + Δ. (t_hi stays
# well under the compiler's Big-M=1e5, so only the start-after branch is viable.)
# ---------------------------------------------------------------------------
local tgt, vt, t0n, t_lo, t_hi, prop, inv, verdict
admitted = false
for cand in asm_nodes
    global tgt, vt, t0n, t_lo, t_hi, prop, inv, verdict, admitted
    tgt = cand
    vt  = CB.get_vtx(env.sched, tgt)
    t0n = Float64(CB.get_t0(env.sched, vt))
    t_lo, t_hi = 0.0, t0n + 10.0
    prop = CB.RespecProposal([CB.ForbidWindow(tgt, t_lo, t_hi)])
    inv  = CB.build_invariant(env)
    verdict = CB.verify(prop, env, inv)
    if verdict isa CB.Admit; admitted = true; break; end
end
@assert admitted "no admittable binding ForbidWindow found to test"

println("\n── TEST: ForbidWindow($tgt, $(round(t_lo,digits=2)), $(round(t_hi,digits=2)))")
println("   BEFORE: t0[node]=$(round(t0n,digits=2))  (must be raised to >= $(round(t_hi,digits=2)))")
milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
    optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
    extra_constraints=verdict.proposal)
CB.optimize!(milp)
t0m = JuMP.value.(milp.model[:t0])
println("   [MILP soln] t0[node]=$(round(t0m[vt],digits=2))  (constraint forces t0 >= t_hi)")
@assert CB.commit_respec!(env, milp, verdict.proposal) "commit_respec! failed"

t0a = Float64(CB.get_t0(env.sched, vt))
println("   AFTER : t0[node]=$(round(t0a,digits=2))")
ok = t0a >= t_hi - 1e-6
println(ok ? "   ✅ PASS: ForbidWindow start-shift PERSISTED past commit (written MILP times alone, no edge)." :
            "   ❌ FAIL: t0 reverted below t_hi — write mechanism not working.")

println("\n", ok ? "════ TIMING-PERSISTENCE CHECK PASSED ════" :
                  "════ CHECK FAILED ════")
