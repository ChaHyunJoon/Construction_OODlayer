# =============================================================================
# run_full_loop.jl  --  Enabled-seam end-to-end driver for the RESUME full-loop.
#
# This is Piece-1 step 4 of docs/autonomy_impl_workflow_2026-06-22.md: build a
# real env, run the sim to a mid-build state, inject an OOD (robot fault), and
# confirm the build RESUMES through the verified reassignment and reaches
# project_complete WITHOUT restarting finished work (closed_set never regresses).
#
# It drives the PRODUCTION seam exactly as simulate! does (demo_utils.jl:96-100):
#     step_environment!(env)  ->  respec_step!(env)  ->  update_planning_cache!(env, 0.0)
# so what passes here is what the live simulate! loop runs — minus the MeshCat
# visualizer (Piece 3), which is irrelevant to schedule resumption.
#
# Two modes, auto-selected:
#   * LLM seam  (respec_service_ready() == true): RESPEC_ENABLED[]=true + push_ood!
#     a natural-language fault; respec_step! runs generate->verify->admit->resume.
#   * LLM-free  (no service): calls fault_robot_and_reassign!(...; resume=true)
#     directly at the injection step — same commit/resume path, no translation.
# Force LLM-free with  RESPEC_FULLLOOP_NOLLM=1.
#
# Run:  julia +lts --project=. tools/run_full_loop.jl
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP
const CB = ConstructionBots

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0,
    CB.MOI.Silent() => true)

const INJECT_AT_CLOSED = 24      # step to this many closed nodes, then inject the fault
const STEP_CAP         = 100_000 # hard cap on sim steps (build completes well before)

run_with_stack(f, stacksize::Int) = begin
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = () -> (try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); rethrow(err[][1]))
    return result[]
end

function build_env()
    pp = CB.get_project_params(4)   # tractor
    return run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
end

"Pick a still-valid robot on a PENDING transport team so the fault forces a real reassign."
function pick_faultable_agent(env)
    seen = CB.AbstractID[]
    for v in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        node isa CB.RobotGo || continue
        rid = try CB.entity(node).id catch; nothing end
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue
        push!(seen, rid)
    end
    for rid in seen
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid
    end
    return isempty(seen) ? nothing : first(seen)
end

# one production-seam step; returns the new closed count
function seam_step!(env)
    CB.step_environment!(env)
    CB.respec_step!(env)                      # no-op unless RESPEC_ENABLED[]
    CB.update_planning_cache!(env, 0.0)
    return length(env.cache.closed_set)
end

function main()
    println(">>> building tractor env (slow, ~minutes)...")
    env = build_env()
    total = Graphs.nv(env.sched)
    println(">>> env ready: $total nodes, closed=$(length(env.cache.closed_set))")

    # --- phase 1: run to the injection point --------------------------------
    iters = 0
    while length(env.cache.closed_set) < INJECT_AT_CLOSED && iters < STEP_CAP
        seam_step!(env); iters += 1
        CB.project_complete(env) && break
    end
    n_inject = length(env.cache.closed_set)
    println(">>> reached injection point: closed=$n_inject after $iters steps")

    agent = pick_faultable_agent(env)
    agent === nothing && (println("!! no valid robot to fault — aborting"); return false)

    use_llm = !haskey(ENV, "RESPEC_FULLLOOP_NOLLM") && CB.respec_service_ready()
    if use_llm
        k = CB.get_id(agent)
        event = "Robot R$k has stopped responding and must be removed from service"
        println(">>> OOD inject (LLM seam): \"$event\"  [agent=$agent]")
        CB.RESPEC_ENABLED[] = true
        CB.push_ood!(event)
        # the seam translates+verifies+commits on the next respec_step!
    else
        println(">>> OOD inject (LLM-free): direct reassign of $agent")
        res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = true)
        res.status == :admitted || (println("!! reassign $(res.status) — cannot resume"); return false)
    end

    n_after = length(env.cache.closed_set)
    if n_after < n_inject
        println("❌ closed_set REGRESSED at commit: $n_inject -> $n_after"); return false
    end

    # --- phase 2: RESUME to completion --------------------------------------
    monotone = true; prev = n_after; resume_iters = 0
    while resume_iters < STEP_CAP
        c = seam_step!(env)
        c < prev && (monotone = false)
        prev = c; resume_iters += 1
        CB.project_complete(env) && break
    end
    CB.RESPEC_ENABLED[] = false   # leave the global switch off for any later use

    done = CB.project_complete(env)
    ms = round(CB.makespan(env.sched), digits = 2)
    pass = done && monotone && n_after >= n_inject
    println("="^70)
    println("RESULT  inject@closed=$n_inject  ->(commit) $n_after  ->(resume) $prev / $total")
    println("        complete=$done  monotone=$monotone  resume_steps=$resume_iters  makespan=$ms")
    println("        ", pass ? "✅ FULL LOOP PASS — reassigned and built to completion" :
                               "❌ FULL LOOP FAIL")
    println("="^70)
    return pass
end

ok = main()
exit(ok ? 0 : 1)
