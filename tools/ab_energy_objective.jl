# =============================================================================
# tools/ab_energy_objective.jl
#   A/B PROOF for the energy-aware objective: "handling-energy DOWN at makespan ~= same".
#
#   Builds ONE small instance (greedy, fast), RE-OPENS the future assignment edges
#   (release_pending_assignments!), then RE-SOLVES the SAME assignment sub-problem at
#   several efficiency weights ENERGY_W. The per-edge transport ENERGY is identical
#   across arms (same geometry); only the CHOSEN assignment Xa differs, so
#   handling_energy = Σ edge_energy·Xa is an apples-to-apples comparison. No commit /
#   no schedule mutation between arms — each arm just formulates+solves.
#
#   Reports per arm: makespan, handling-energy, MILP gap/status. The headline is the
#   trade-off curve: as ENERGY_W rises, handling-energy falls; the safe operating band
#   is the largest w that keeps makespan within tolerance of the w=0 baseline.
#
#   Run:  julia +lts --project=. tools/ab_energy_objective.jl
#         (WEIGHTS="0,0.001,0.01,0.05" PROJECT=4 TLIM=180 GAP=0.01 julia +lts ...)
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP
const CB = ConstructionBots
const value = JuMP.value
const termination_status = JuMP.termination_status
const relative_gap = JuMP.relative_gap

WEIGHTS = parse.(Float64, split(get(ENV, "WEIGHTS", "0,0.001,0.01,0.05"), ","))
PROJECT = parse(Int, get(ENV, "PROJECT", "4"))     # 4 = tractor (smallest)
TLIM    = parse(Float64, get(ENV, "TLIM", "180"))
GAP     = parse(Float64, get(ENV, "GAP", "0.01"))
NROBOTS = parse(Int, get(ENV, "NROBOTS", "0"))     # 0 = project default; smaller => smaller MILP (likelier to converge)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => TLIM, "presolve" => "on", "mip_rel_gap" => GAP, CB.MOI.Silent() => true)

# Clean baseline: no per-agent / battery bias, payload term ON so energy ≠ pure distance.
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

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
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return res[]
end

pp = CB.get_project_params(PROJECT)
nrob = NROBOTS > 0 ? NROBOTS : pp[:num_robots]
println(">>> building env once (greedy)...  project=$(pp[:project_name]) robots=$(nrob)")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=nrob,
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
println(">>> built: $(Graphs.nv(env.sched)) nodes")

# GREEDY baseline (deterministic, always "converged") — schedule-level handling energy =
# Σ edge_energy(move duration) over the committed transport moves. A meaningful reference the
# MILP arms can be compared against even when the makespan MILP itself does not reach optimality.
function schedule_handling_energy(env)
    s = 0.0
    for v in Graphs.vertices(env.sched)
        node = CB.get_node(env.sched, v).node
        (node isa CB.RobotGo || node isa CB.TransportUnitGo) || continue
        dur = try Float64(CB.get_tF(env.sched, v) - CB.get_t0(env.sched, v)) catch; 0.0 end
        s += CB.edge_energy(max(dur, 0.0))
    end
    return s
end
greedy_ms = try maximum(CB.get_tF(env.sched)) catch; NaN end
greedy_he = schedule_handling_energy(env)
println(">>> GREEDY baseline: makespan=$(round(greedy_ms,digits=2))  handling_energy=$(round(greedy_he,digits=2))")

# Re-open all FUTURE assignment edges so the MILP can re-decide them (faulted=nothing => no fault).
inv = CB.build_invariant(env)
CB.release_pending_assignments!(env, inv; faulted = nothing)
println(">>> released future assignment edges; re-solving at $(length(WEIGHTS)) weights\n")

rows = []
for w in WEIGHTS
    CB.set_planning_objective_weights!(speed = 1.0, efficiency = w)
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.optimize!(milp)
    he  = CB.handling_energy(milp)                       # Σ edge_energy·Xa on this solution
    ms  = try maximum(value.(milp.model[:tF])) catch; NaN end
    st  = try string(termination_status(milp.model)) catch; "?" end
    gp  = try round(relative_gap(milp.model); digits = 3) catch; NaN end
    push!(rows, (w = w, makespan = ms, energy = he, status = st, gap = gp))
    println("  ENERGY_W=$(rpad(w,7))  makespan=$(round(ms,digits=2))  handling_energy=$(round(he,digits=2))  [$(st), gap=$(gp)]")
end

# Headline summary vs the w=0 baseline.
base = rows[1]
println("\n== A/B SUMMARY (baseline ENERGY_W=$(base.w): makespan=$(round(base.makespan,digits=2)), energy=$(round(base.energy,digits=2))) ==")
for r in rows[2:end]
    dms = base.makespan > 0 ? 100 * (r.makespan - base.makespan) / base.makespan : NaN
    den = base.energy   > 0 ? 100 * (r.energy   - base.energy)   / base.energy   : NaN
    println("  w=$(rpad(r.w,7))  Δmakespan=$(round(dms,digits=1))%   Δenergy=$(round(den,digits=1))%   [$(r.status)]")
end
println("\nHEADLINE: the largest w with Δmakespan within tolerance AND Δenergy<0 is the safe operating band.")
println("(If gaps are large the numbers are feasible-but-not-optimal; tighten GAP / raise TLIM / smaller PROJECT.)")
