# =============================================================================
# test_respec_e2e.jl  --  LIVE end-to-end: OOD -> Claude -> DSL -> verify ->
#                         admit -> re-solve, through the running Python service.
#
# Prereq: the Python LLM service must be running with a valid ANTHROPIC_API_KEY:
#   (PowerShell, terminal #1)
#     $env:ANTHROPIC_API_KEY = "sk-ant-...new key..."
#     & "C:\Users\chahj\PythonCodes\venv\hjcnlp\Scripts\python.exe" -m uvicorn server:app `
#         --host 127.0.0.1 --port 8000 `
#         --app-dir "C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl\src\respec\llm_service"
#
# Then (terminal #2):  julia --project=. test_respec_e2e.jl
#
# If the service is down, this script builds the env, reports that, and exits
# cleanly (demonstrating the no-crash path) without making any LLM call.
# =============================================================================
using ConstructionBots
import Graphs
import Logging
import HiGHS
const CB = ConstructionBots

# A robot-fault re-spec triggers a real MILP re-solve (reassignment). Greedy
# assembly never set a default optimizer, so set one with a feasibility-first gap
# (return the first feasible integer solution rather than proving optimality) so
# the re-solve is fast & reliable, and silence the per-solve HiGHS log spam.
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

project_params = get_project_params(4)   # tractor

println(">>> building env (assignment only, no simulation)...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(;
        ldraw_file=project_params[:file_name],
        project_name=project_params[:project_name],
        model_scale=project_params[:model_scale],
        num_robots=project_params[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error,   # silence the benign greedy-assignment @warn spam
        rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true,
    )
end
println(">>> env built: $(Graphs.nv(env.sched)) nodes")

# Step a little so the freeze path is exercised live too (some completed work).
for _ in 1:1500
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 20 && break
end
println(">>> stepped: closed=$(length(env.cache.closed_set)) active=$(length(env.cache.active_set))")

# --- Service gate ------------------------------------------------------------
if !CB.respec_service_ready()
    println("""

    !!! Python LLM service is NOT reachable at $(CB._RESPEC_SERVICE_URL).
        Start it in another terminal (see header of this file), then re-run.
        (The simulation itself never crashes on a down service — a missing
         service just routes to the safe fallback.)
    """)
    exit(0)
end
println(">>> LLM service is UP. Running live OOD rounds...\n")

# One live round: generate -> verify -> (admit:re-solve | reject:fallback).
# Crash-safe: an unresolvable / ungrammatical LLM proposal is caught and treated
# exactly as the production maybe_respecify! does — a Reject that routes to the
# safe fallback, never reaching the solver.
function live_round(env, title, event)
    println("\n┌──────────────  $title")
    println("│ OOD event: ", event)
    inv = CB.build_invariant(env)
    println("│ freeze: $(length(inv.frozen_t0)) t0 bounds, $(length(inv.frozen_tF)) tF bounds (completed work pinned)")

    local proposal
    try
        proposal = CB.llm_to_proposal(event, env; id_resolver = ref -> CB._default_id_resolver(env, ref))
    catch err
        msg = first(split(sprint(showerror, err), "\n"))
        println("│ Claude's proposal could NOT be resolved to the DSL: ", msg)
        println("└ RESULT: SAFELY REJECTED → fallback (nothing reached the solver).")
        return (title, "REJECT (unresolvable) → fallback", "—")
    end

    println("│ Claude proposed $(length(proposal.constraints)) constraint(s):")
    for c in proposal.constraints; println("│     ", c); end
    isempty(proposal.rationale) || println("│ rationale: ", first(split(proposal.rationale, "\n")))

    # A robot-fault (single ForbidAgent) cannot go through the generic compile path
    # (it would silently compile to zero constraints -> hollow admit). Dispatch to
    # the reassign machinery, exactly as the production maybe_respecify! now does.
    if CB._is_robot_fault(proposal)
        agent  = proposal.constraints[1].agent
        teams0 = length(CB.transport_teams_with_agent(env, agent; pending_only = true))
        ms0    = CB.makespan(env.sched)
        res    = CB.fault_robot_and_reassign!(env, agent; verbose = false)
        if res.status == :admitted
            ms1 = CB.makespan(env.sched)
            println("│ ForbidAgent → reassign: $(agent) was on $(teams0) pending team(s), now on $(res.teams_after).")
            println("└ RESULT: ADMIT (reassigned) → makespan $(round(ms0, digits=2)) → $(round(ms1, digits=2))")
            return (title, "ADMIT (reassigned)",
                    "teams $(teams0)→$(res.teams_after), makespan $(round(ms0,digits=2))→$(round(ms1,digits=2))")
        else
            println("└ RESULT: $(res.status) → fallback (reassignment infeasible; safe-stop, schedule uncorrupted).")
            return (title, "$(res.status) → fallback", string(get(res, :reason, "—")))
        end
    end

    verdict = CB.verify(proposal, env, inv)
    if verdict isa CB.Admit
        ms0 = CB.makespan(env.sched)
        milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
            optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
            extra_constraints=verdict.proposal)
        CB.optimize!(milp)
        CB.update_project_schedule!(nothing, milp, env.sched, env.scene_tree)
        ms1 = CB.makespan(env.sched)
        println("└ RESULT: ADMIT ($(verdict.n_constraints) constr) → re-solved; makespan $(round(ms0,digits=2)) → $(round(ms1,digits=2))")
        return (title, "ADMIT → re-solved", "makespan $(round(ms0,digits=2)) → $(round(ms1,digits=2))")
    else
        println("└ RESULT: REJECT(:$(verdict.reason)) → fallback. $(verdict.detail)")
        return (title, "REJECT(:$(verdict.reason)) → fallback", verdict.detail)
    end
end

summary = Vector{Any}()

# ROUND 1: a natural-language robot fault. The model tends to name the robot
# ("R3") rather than a schedule id — a real translation error the gate catches.
push!(summary, live_round(env, "ROUND 1: natural robot-fault event",
    "Robot R3 reports a motor fault and is immobile and cannot perform any task."))

# ROUND 2: a re-spec the model CAN express against real ids — we embed an actual
# open node id and a generous deadline so it resolves, verifies, and admits.
open_ids = [CB.get_vtx_id(env.sched, v) for v in Graphs.vertices(env.sched)
            if !(CB.get_vtx_id(env.sched, v) in CB.build_invariant(env).closed_nodes)]
tgt = string(open_ids[end])
push!(summary, live_round(env, "ROUND 2: explicit deadline on a real node id",
    "Operations note: node $tgt must be completed no later than time 100000."))

println("\n╔══════════════  LIVE END-TO-END SUMMARY  ══════════════")
for (title, outcome, detail) in summary
    println("║ ", rpad(split(title, ":")[1], 8), " → ", outcome, detail == "—" ? "" : "   [$detail]")
end
println("╠═══════════════════════════════════════════════════════")
println("║ Real OOD text → Claude → formal DSL → verified (completed work frozen).")
println("║ Bad refs are rejected to the safe fallback; valid re-specs admitted & re-solved.")
println("║ PROOF the LLM was really called: see 'POST /propose 200 OK' in the uvicorn")
println("║ terminal — one line per round above.")
println("╚═══════════════════════════════════════════════════════")
