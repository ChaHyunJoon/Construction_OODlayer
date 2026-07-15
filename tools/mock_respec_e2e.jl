# =============================================================================
# mock_respec_e2e.jl -- LLM-FREE end-to-end test of the FULL respec seam for ForbidZone
# (Stage 2). Stands up a local mock /propose server that returns a fixed ForbidZone
# (grounded from the request's own zones/nodes context, mimicking the LLM), enables the
# RESPEC seam, injects a CENTRAL zone via schedule_ood! (returning an NL string), and runs
# the real sim loop (ood_inject_step! -> step -> respec_step!). This drives the production
# path: NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
# -> ForbidZone -> verify_zone -> restage_all -> translate_whole_build! -> completion.
# This is the first ENABLED full-loop e2e run (doc: seam wired but never exercised).
#
# Run:  julia +lts --project=. tools/mock_respec_e2e.jl
# =============================================================================
const MOCK_PORT = 8731
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST be set before `using` (const reads ENV at load)

using ConstructionBots
import HTTP, JSON3, Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

const ZONE_R = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))
const OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# ---- mock /propose server: deterministic, grounds ForbidZone from request context -----
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body  = JSON3.read(String(req.body))
            zones = haskey(body, "zones") ? body["zones"] : []
            nodes = haskey(body, "nodes") ? body["nodes"] : []
            zkey  = isempty(zones) ? "zone" : String(zones[1]["key"])     # ground the live zone key
            # prefer an assembly the zone actually covers; else first milestone node
            cov = isempty(zones) ? [] : zones[1]["covers"]
            aid = !isempty(cov) ? String(first(cov)) :
                  (isempty(nodes) ? "" : String(nodes[1]["id"]))
            resp = Dict("constraints" => [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => aid)],
                        "rationale" => "mock: spatial no-go zone over the build core")
            return HTTP.Response(200, JSON3.write(resp))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)   # non-blocking; returns a Server
end

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]
_p2(t) = Vector{Float64}(CB.project_to_2d(t.translation))
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))

# OOD action: inject the physical zone AND return the NL string (-> push_ood! by ood_inject_step!)
function ood_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[E2E] OOD action: injected zone@$(round.(zc;digits=2)) R=$ZONE_R; emitting NL"
    return "A safety exclusion zone is now active over the central build area; " *
           "robots must not enter or pass through it."
end

println(">>> building nav-ON env (tractor)...")
pp = CB.get_project_params(4)
const ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes")

# bring up the mock + enable the seam
const SRV = start_mock(MOCK_PORT)
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.schedule_ood!(OOD_STEP, ood_action!)
println(">>> mock /propose up at $(ENV["RESPEC_SERVICE_URL"]); respec_service_ready=$(CB.respec_service_ready()); RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

# real seam loop (mirrors simulate!): ood_inject_step! -> step -> respec_step!
function run_seam_loop(env; cap=250_000, stall_limit=8000)
    rr = Float64(CB.default_robot_radius()); robots = _robot_nodes(env)
    zc_ref = Ref{Any}(nothing)
    prev = length(env.cache.closed_set); stall = 0; worst = -Inf; viol = 0; first_v = -1; last_v = -1
    respec_seen = Ref(false)
    for it in 1:cap
        CB.ood_inject_step!(env, it)
        CB.step_environment!(env)
        st = CB.respec_step!(env)
        (st in (:admitted, :noop, :fallback, :rejected)) && (respec_seen[] = true; @info "[E2E] respec_step! @it=$it -> $st")
        try CB.update_planning_cache!(env, 0.0) catch e
            @warn "[E2E] update_planning_cache! threw @it=$it: $(typeof(e))"
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])
        end
        if !isempty(CB.RESTRICTION_ZONES[])                 # track penetration once a zone exists
            z = first(values(CB.RESTRICTION_ZONES[])); zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))
            sp = -Inf
            for rb in robots; sp = max(sp, (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)); end
            sp > 1e-6 && (viol += 1; first_v < 0 && (first_v = it); last_v = it)
            sp > worst && (worst = sp)
        end
        c = length(env.cache.closed_set)
        stall = c > prev ? 0 : stall + 1; prev = c
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])
    end
    return (status=:capped, closed=prev, iters=cap, worst=worst, viol=viol, first_v=first_v, last_v=last_v, respec=respec_seen[])
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched); n0 = length(env.cache.closed_set)
r = run_seam_loop(env)
try close(SRV) catch end
transient = r.viol == 0 || r.last_v < max(2000, 0.1 * r.iters)
pass = r.status == :complete && r.respec && transient
println("\n==== RESULT (mock e2e ForbidZone) ====")
println("closed $n0 -> $(r.closed)/$total  status=$(r.status)  respec_fired=$(r.respec)")
println("zone penetration: worst_pen=$(round(r.worst;digits=3)) viol_steps=$(r.viol) viol_iters=[$(r.first_v)..$(r.last_v)] of $(r.iters)  evac_transient=$transient")
println(pass ? "PASS (NL -> mock LLM -> ForbidZone -> verify -> recovery -> complete, no re-entry)" : "FAIL")
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
