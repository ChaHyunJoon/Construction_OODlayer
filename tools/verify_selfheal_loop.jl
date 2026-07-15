# =============================================================================
# tools/verify_selfheal_loop.jl
#   AUTONOMOUS SELF-HEALING VERIFICATION HARNESS (headless).
#
#   Purpose (user request, 2026-07-01): run the REAL energy-adaptive build with the
#   live LLM re-spec layer, and whenever the LLM's replan loops on the SAME
#   warning/verdict while the sim makes NO progress, STOP that run immediately,
#   record a structured diagnostic verdict, and move on — so the outer loop (Claude)
#   can diagnose the system's problem at that point, fix it, and re-run.
#
#   This drives run_lego_demo's FULL simulate! loop (the one that emits the
#   "team deadlocked" reform OOD + calls respec_step! every step) but HEADLESS
#   (save_animation=false => no MeshCat), so the reform/respec/recovery path runs
#   with no browser overhead. A sustained no-progress wedge trips the built-in
#   max_num_iters_no_progress termination => the run ends INCOMPLETE and the
#   [RESPEC][DIAG] + recovery-status logs pinpoint WHY.
#
#   Scenario mirrors demo_energy_adaptive_anim.jl: N_BATTERY soft battery OODs
#   (DeprioritizeAgent) + one central NO-GO zone (whole-build relocation), over a
#   real physics run (rvo + tangent_bug + dispersion ON) so real transport-team
#   wedges occur.
#
#   Real LLM service must be UP on :8000 (health checked; aborts if down).
#
#   Run (PowerShell, service already up on 8000):
#     cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#     $env:SEEDS="7,11,13"; julia +lts --project=. tools/verify_selfheal_loop.jl
#   Env knobs: SEEDS (csv), MAXNP (max_num_iters_no_progress), N_BATTERY,
#     ZONE_CLOSED, ZONE_R, ENERGY_W, PROJECT, VERDICT (jsonl out path).
# =============================================================================
ENV["RESPEC_SERVICE_URL"] = get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000")

using ConstructionBots
import Graphs, Logging, HiGHS
const CB = ConstructionBots

for f in ("metrics.jl", "ood_truth.jl", "battery.jl", "ood_stream.jl")
    CB.include(joinpath(pkgdir(CB), "src", "navigator", f))
end

# ---- knobs ------------------------------------------------------------------
_seeds_env = get(ENV, "SEEDS", "7,11,13,17,23")
const SEEDS       = parse.(Int, split(_seeds_env, ","))
const MAXNP       = parse(Int,     get(ENV, "MAXNP", "4500"))    # no-progress steps -> terminate (allows reform @2000,4000)
const MODE        = get(ENV, "MODE", "soft")                    # soft = battery+central zone; hard = fault+battery+zone stream
const N_BATTERY   = parse(Int,     get(ENV, "N_BATTERY", "2"))
const N_OOD       = parse(Int,     get(ENV, "N_OOD", "6"))       # hard-mode: # of random mixed OOD events
const CLOSED_HI   = parse(Int,     get(ENV, "CLOSED_HI", "200")) # hard-mode: spread OOD up to this closed-count
const ZONE_CLOSED = parse(Int,     get(ENV, "ZONE_CLOSED", "60"))
const ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))
const ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
const PROJECT     = parse(Int,     get(ENV, "PROJECT", "4"))
const VERDICT     = get(ENV, "VERDICT",
    joinpath(pkgdir(CB), "..", "verify_selfheal_verdicts.jsonl"))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
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
        e, bt = err[]; showerror(stderr, e, bt); println(stderr)
        return (:error, e)
    end
    return (:ok, res[])
end

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
function central_zone_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[VERIFY] central no-go ZONE @ $(round.(zc; digits=2)) R=$ZONE_R"
    return "A safety exclusion zone is now active over the central build area; robots must not enter or pass through it."
end

# machine-readable verdict line (one JSON obj per seed)
function write_verdict(seed, complete, closed, total, term, extra)
    rate = total == 0 ? 0.0 : round(closed / total, digits = 4)
    esc(s) = replace(string(s), "\"" => "'", "\\" => "/")
    line = string("{\"seed\":", seed,
        ",\"complete\":", complete,
        ",\"closed\":", closed, ",\"total\":", total, ",\"rate\":", rate,
        ",\"term\":\"", esc(term), "\"",
        ",\"note\":\"", esc(extra), "\"}")
    open(VERDICT, "a") do io; println(io, line); end
    println("VERDICT ", line); flush(stdout)
end

# Full dump of the TERMINAL stuck state when a run ends INCOMPLETE — the "stop and
# diagnose the problem at that point" the harness exists for. Reveals: whether a line
# stop is stuck on (RESPEC_HOLD), what the active frontier is, and — for every active
# Go-node — how far each robot/unit is from its goal (AT-goal/waiting = a scheduling
# deadlock; EN-ROUTE = navigation/congestion), plus which robots are over-subscribed
# across multiple pending transport teams (the cascading-fault reassign bottleneck).
function terminal_report(env)
    try CB.diagnose_transport_stall(env) catch e; println("  [TERMINAL] diag failed: $e") end
    sched = env.sched
    types = Dict{String,Int}(); atg = 0; enr = 0; ds = Float64[]
    team_load = Dict{Any,Int}()   # robot -> # of FormTransportUnit it feeds (over-subscription)
    ttol = CB.capture_distance_tolerance()
    for v in collect(env.cache.active_set)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        nm = string(nameof(typeof(node)))
        types[nm] = get(types, nm, 0) + 1
        if node isa CB.RobotGo || node isa CB.TransportUnitGo
            d = try
                s = CB.global_transform(CB.entity(node)); g = CB.global_transform(CB.goal_config(node))
                sqrt(sum(abs2, (Vector{Float64}(s.translation) .- Vector{Float64}(g.translation))[1:2]))
            catch; NaN end
            isnan(d) || (push!(ds, d); d <= ttol ? (atg += 1) : (enr += 1))
        end
        if node isa CB.RobotGo
            outs = CB.Graphs.outneighbors(sched, v)
            if !isempty(outs)
                nx = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
                nx isa CB.FormTransportUnit && (team_load[string(CB.node_id(CB.entity(node)))] = get(team_load, string(CB.node_id(CB.entity(node))), 0) + 1)
            end
        end
    end
    dsum = isempty(ds) ? "n/a" : "min=$(round(minimum(ds),digits=2)) max=$(round(maximum(ds),digits=2)) mean=$(round(sum(ds)/length(ds),digits=2))"
    over = sort([(k, c) for (k, c) in team_load if c > 1]; by = x -> -x[2])
    println("  [TERMINAL] RESPEC_HOLD=$(CB.RESPEC_HOLD[])  active_types=$types")
    println("  [TERMINAL] Go-nodes: AT-goal/waiting=$atg EN-ROUTE=$enr dist[$dsum] zones=$(length(CB.RESTRICTION_ZONES[]))")
    println("  [TERMINAL] over-subscribed robots (feeding >1 forming team): $(isempty(over) ? "none" : over)")
    flush(stdout)
end

function reset_globals!()
    CB.RESPEC_ENABLED[] = false
    CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()
    try CB.BATTERY_FLEET[] = nothing catch end
    CB.CAMERA_FOLLOW[] = false
end

# assert the real LLM service is reachable BEFORE burning a build
if !CB.respec_service_ready()
    println("FATAL: LLM service not reachable at $(ENV["RESPEC_SERVICE_URL"]) — start uvicorn on :8000 first.")
    exit(1)
end
println(">>> LLM service UP at $(ENV["RESPEC_SERVICE_URL"]); verdicts -> $VERDICT")
println(">>> seeds=$(SEEDS)  MAXNP=$MAXNP  N_BATTERY=$N_BATTERY  ZONE_CLOSED=$ZONE_CLOSED  ZONE_R=$ZONE_R  ENERGY_W=$ENERGY_W")

pp = CB.get_project_params(PROJECT)

for seed in SEEDS
    println("\n", "="^78)
    println("===== SEED $seed =====")
    println("="^78); flush(stdout)
    reset_globals!()

    # --- schedule the OOD story (battery x N_BATTERY + one central zone) --------
    CB.RESPEC_ENABLED[] = true
    CB.schedule_ood!(1, function (env)
        CB.enable_battery!(env; params = CB.demo_battery_params())
        CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
        @info "[VERIFY] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots)"
        return nothing
    end)
    if MODE == "hard"
        # full multi-OOD stream: robot FAULTS (-> ReplaceAgent -> spare hand-off -> the
        # team-wedge/reform/recovery chain), battery degradations, and no-go zones, at
        # random build-progress points. This is the path the self-heal recovery exists for.
        trg = CB.schedule_random_ood!(; n = N_OOD, kinds = [:fault, :battery, :zone],
            closed_lo = 8, closed_hi = CLOSED_HI, seed = seed)
        println("  [hard] scheduled $(length(trg)) mixed OOD at closed=",
            join(sort([t.closed_at for t in trg]), ","))
    else
        CB.schedule_random_ood!(; n = N_BATTERY, kinds = [:battery], closed_lo = 8,
            closed_hi = max(12, ZONE_CLOSED - 10), seed = seed)
        CB.schedule_ood_at_closed!(ZONE_CLOSED, central_zone_action!)
    end

    # --- run the FULL sim loop, headless --------------------------------------
    status, payload = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file = pp[:file_name], project_name = pp[:project_name],
            model_scale = pp[:model_scale], num_robots = pp[:num_robots], assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
            rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
            save_animation = false, open_animation_at_end = false,
            save_animation_along_the_way = false, write_results = false, overwrite_results = false,
            look_for_previous_milp_solution = false, save_milp_solution = false,
            max_num_iters_no_progress = MAXNP, return_env_before_sim = false)
    end

    if status == :error
        write_verdict(seed, false, -1, -1, "exception",
            first(split(sprint(showerror, payload), "\n")))
        reset_globals!(); continue
    end

    env, _stats = payload
    total  = Graphs.nv(env.sched)
    closed = length(env.cache.closed_set)
    complete = CB.project_complete(env)
    term = complete ? "complete" : "no_progress_terminate"
    complete || terminal_report(env)          # dump the exact terminal stuck state for diagnosis
    batt = CB.BATTERY_FLEET[] === nothing ? "" :
        (r = CB.battery_report(); "min_soc=$(round(r.min_soc,digits=3)) spread=$(round(r.soc_spread,digits=3))")
    write_verdict(seed, complete, closed, total, term, batt)
    reset_globals!()
end

println("\n>>> DONE. verdicts written to $VERDICT")
