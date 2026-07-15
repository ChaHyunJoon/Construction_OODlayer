# =============================================================================
# tools/demo_energy_adaptive.jl
#   ENERGY-AWARE ADAPTIVE REPLANNING demo.
#
#   Shows: as robots break down / batteries degrade / no-go zones appear at
#   MULTIPLE RANDOM times during one build, the system re-plans at EACH event,
#   minimizing battery-energy + handling-distance + makespan, biased AWAY from
#   low-State-of-Charge robots (per-robot SoC accounting).
#
#   Pieces wired together (all non-invasive, inert until enabled):
#     · navigator/battery.jl     — per-robot SoC accounting + SoC->cost objective bias
#     · navigator/ood_stream.jl  — multi-time random OOD (fault / battery / zone)
#     · energy objective         — set_planning_objective_weights! + set_energy_model!
#     · smaller forbid zones      — random_restriction_zone! max_radius shrunk 3->2 rr
#
#   LLM mode (headline): start the Python service (see test_respec_e2e.jl header) so
#   each OOD's natural-language event is translated->verified->re-solved by Claude.
#   OFFLINE mode (no service): faults are routed straight through the canonical
#   reassign machinery so the energy-aware re-solve + battery accounting still run.
#
#   Run:  julia +lts --project=. tools/demo_energy_adaptive.jl
#         (optional: ENERGY_W=0.001 SEED=7 N_OOD=4 julia +lts ... )
# =============================================================================
using ConstructionBots
import Graphs
import Logging
import HiGHS
const CB = ConstructionBots

# ---- knobs (env-overridable) ------------------------------------------------
ENERGY_W = parse(Float64, get(ENV, "ENERGY_W", "1.0e-3"))   # efficiency weight (energy+distance) vs makespan
SEED     = parse(Int,     get(ENV, "SEED", "7"))
N_OOD    = parse(Int,     get(ENV, "N_OOD", "4"))           # number of random OOD events across the build
PROJECT  = parse(Int,     get(ENV, "PROJECT", "4"))         # 4 = tractor

# ---- load the navigator layer into the module scope (manual-include pattern) -
_nav(f) = joinpath(pkgdir(CB), "src", "navigator", f)
for f in ("metrics.jl", "ood_truth.jl", "battery.jl", "ood_stream.jl")
    CB.include(_nav(f))
end

# ---- solver for the re-solves (feasibility-first, quiet) ---------------------
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# ---- ENERGY-AWARE OBJECTIVE: every (re)solve minimizes makespan + w·(energy/dist) ----
# load_power>0 turns on the payload term so heavier hauls cost more energy (the
# differential the per-robot battery bias and wear-leveling act on).
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

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

pp = get_project_params(PROJECT)
println(">>> building env (assignment only)...  project=$(pp[:project_name]) robots=$(pp[:num_robots])")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true)
end
n_total = Graphs.nv(env.sched)
println(">>> env built: $n_total schedule nodes")

# ---- enable the battery layer + SoC bias ------------------------------------
# demo_battery_params() shrinks capacity so SoC visibly drains across this short build.
fleet = CB.enable_battery!(env; params = CB.demo_battery_params())
CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
println(">>> battery ON: $(length(fleet.soc)) robots @ SoC 1.0, energy objective w=$ENERGY_W")

# ---- schedule MULTI-TIME random OOD across the build ------------------------
CB.clear_ood_schedule!()
triggers = CB.schedule_random_ood!(; n = N_OOD, kinds = [:fault, :battery, :zone],
    closed_lo = max(4, n_total ÷ 12), closed_hi = max(8, n_total ÷ 2), seed = SEED)
println(">>> scheduled $(length(triggers)) random OOD events at closed-counts: ",
        join(sort([t.closed_at for t in triggers]), ", "))

service_up = CB.respec_service_ready()
CB.RESPEC_ENABLED[] = service_up
println(service_up ? ">>> LLM service UP — full translate->verify->re-solve per OOD\n"
                   : ">>> LLM service DOWN — OFFLINE canonical-reassign fallback per fault\n")

# ---- adaptive run loop (manual stepping; no visualizer) ---------------------
report(tag) = begin
    r = CB.battery_report(fleet)
    println("    [$tag] closed=$(length(env.cache.closed_set))/$n_total  makespan=",
        round(CB.makespan(env.sched), digits=2),
        "  energy=", round(r.total_energy_J, digits=1),
        "  min_soc=", round(r.min_soc, digits=3),
        "  spread=", round(r.soc_spread, digits=3))
end

# initial step so the freeze path has some completed work
CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
report("start")

seen_faults = Set{Any}()
n_fired = Ref(0)
prev_ms = Ref(CB.makespan(env.sched))
MAX_STEPS = 60_000
for k in 2:MAX_STEPS
    n_before = count(t -> t.fired, triggers)
    CB.ood_inject_step!(env, k)                 # fire any due OOD (pushes NL to respec queue)
    n_after = count(t -> t.fired, triggers)
    battery_event = false
    if n_after > n_before                       # an OOD just fired this step
        n_fired[] = n_after
        last_nl = isempty(CB.RESPEC_QUEUE.pending) ? "" : last(CB.RESPEC_QUEUE.pending)
        battery_event = occursin("battery", lowercase(last_nl))
        println("\n>>> OOD #$(n_after) fired at step $k (closed=$(length(env.cache.closed_set))): ",
                first(split(last_nl, "\n")))
        report("at-OOD")
    end

    # Battery-health OOD: re-solve the remaining schedule with the SoC-biased objective so work is
    # re-routed off the degraded robot — no LLM / DSL needed (the EDGE_COST_MULTIPLIER does it).
    if battery_event
        try
            st = CB.rebalance_for_battery!(env)
            println("    [battery] SoC-biased rebalance -> :$(st)")
        catch e
            println("    [battery] rebalance failed: ", first(split(sprint(showerror, e), "\n")))
        end
    end

    if service_up
        outcome = CB.respec_step!(env)          # LLM translate->verify->re-solve; returns the verdict
        outcome in (:noop, :disabled) || println("    [respec] verdict = :$(outcome)")
    else
        # OFFLINE: route any freshly-faulted robot through canonical reassign (energy-aware re-solve).
        for (rid, _) in CB.faulted_robots()
            rid in seen_faults && continue
            push!(seen_faults, rid)
            try
                res = CB.fault_robot_and_reassign!(env, rid; verbose = false)
                println("    [OOD fault $(rid)] canonical reassign -> $(res.status)")
            catch e
                println("    [OOD fault $(rid)] reassign failed: ", first(split(sprint(showerror, e), "\n")))
            end
        end
    end
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)

    ms = CB.makespan(env.sched)                 # a re-solve changes the makespan -> a replan happened
    if abs(ms - prev_ms[]) > 1e-6
        println("    [replan] makespan $(round(prev_ms[], digits=2)) -> $(round(ms, digits=2))")
        report("post-replan")
        prev_ms[] = ms
    end
    k % 5000 == 0 && report("step $k")
    CB.project_complete(env) && (println(">>> build complete at step $k"); break)
end

# ---- final metrics ----------------------------------------------------------
println("\n== FINAL METRICS ==")
bm = CB.battery_metrics_kwargs(fleet)
placed = length(env.cache.closed_set)
m = CB.metrics_from_schedule(env.sched;
    n_parts = n_total, placed_parts = placed,
    robot_busy_time = [Float64(get(fleet.active_steps, id, 0)) * env.dt for id in keys(fleet.soc)],
    transport_distance = NaN, bm...)
println("  feasible=$(m.feasible)  completion=$(round(m.completion_rate, digits=3))  makespan=$(round(m.makespan, digits=2))")
println("  energy(J)=$(round(m.energy, digits=1))  min_soc=$(round(m.min_soc, digits=3))  soc_spread=$(round(m.soc_spread, digits=3))")
println("  per-robot SoC: ", join([string("R", id.id, "=", round(s, digits=3)) for (id, s) in sort(collect(fleet.soc); by = p -> p.first.id)], "  "))
println("\nDONE. (energy↓ at makespan≈same is the headline; compare ENERGY_W=0 vs >0 runs.)")
