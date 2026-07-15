# =============================================================================
# tools/e2e.jl -- consolidated ConstructionBots e2e / mock-LLM pipeline drivers.
#
# Every standalone tools/*_e2e.jl / full-loop / self-heal / spare-replace script is
# now a FUNCTION in module `E2E`, sharing common boilerplate (MILP setup +
# run_with_stack) defined ONCE. A CLI/ENV dispatcher at the bottom runs any one.
#
# Scenario keys:
#   mock_respec   -- LLM-free e2e of the FULL ForbidZone respec seam (mock /propose over HTTP)
#   mock_replace  -- LLM-free e2e of the OOD 1-1 ReplaceAgent respec seam (mock /propose over HTTP)
#   full_loop     -- enabled-seam full-loop RESUME driver (LLM seam or LLM-free reassign)
#   selfheal      -- headless autonomous self-healing verification harness (REAL LLM on :8000)
#   spare_replace -- OOD 1-1 spare 1:1 hand-off done-gate (LLM-free replace_robot!)
#   live_respec   -- LIVE e2e of the respec seam: real Claude (running Python service) NL->DSL->re-solve
#
# Run:
#   julia +lts --project=. tools/e2e.jl <key>        (or  ENV E2E=<key>)
# e.g.
#   julia +lts --project=. tools/e2e.jl mock_respec
#   E2E=spare_replace julia +lts --project=. tools/e2e.jl
# Each scenario reads its own ENV knobs at call time (see the comment above each function).
# These scenarios stand up local mock servers and/or run full sims -- run ONE at a time.
# =============================================================================
module E2E
using ConstructionBots
import HTTP, JSON3, Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer is NOT compiled into the ConstructionBots package -- the self-heal
# script historically `CB.include`d its battery/metrics/ood_truth/ood_stream files at SCRIPT
# TOP LEVEL. Now that each script is a FUNCTION, doing those includes *inside* the function and
# then calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading navigator.jl here at MODULE
# load puts those methods in an OLDER world than any scenario call, reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so this ONE call
# covers the self-heal scenario's battery layer.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically -- 300s/5.0 gap/MOI.Silent)
# in all 5 e2e scripts.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper (throws on error, returns the result). Used by
# mock_respec / mock_replace / full_loop / spare_replace. (selfheal keeps its OWN
# tuple-returning variant nested inside it -- different error-handling contract.)
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# mock_respec -- LLM-FREE end-to-end test of the FULL respec seam for ForbidZone
#   (Stage 2). Stands up a local mock /propose server that returns a fixed ForbidZone
#   (grounded from the request's own zones/nodes context, mimicking the LLM), enables the
#   RESPEC seam, injects a CENTRAL zone via schedule_ood! (returning an NL string), and runs
#   the real sim loop (ood_inject_step! -> step -> respec_step!). This drives the production
#   path: NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
#   -> ForbidZone -> verify_zone -> restage_all -> translate_whole_build! -> completion.
#   ENV: NAVON_ZONE_R, OOD_STEP.
# =============================================================================
function scenario_mock_respec()
MOCK_PORT = 8731
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # CB reads the URL at call time

ZONE_R = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))
OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))

_setup_milp!()

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
ENV0 = run_with_stack(2_000_000_000) do
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
SRV = start_mock(MOCK_PORT)
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
end

# =============================================================================
# mock_replace -- LLM-FREE end-to-end test of the FULL respec seam for OOD 1-1
#   ReplaceAgent (robot breakdown -> spare hand-off). Stands up a local mock /propose
#   that returns a ReplaceAgent grounded from the request's own `agents` context
#   (mimicking the LLM classifier), enables the RESPEC seam, injects a physical robot
#   fault via schedule_ood! (fault_robot! returns the NL), and runs the real sim loop
#   (ood_inject_step! -> step -> respec_step!). This drives the production path:
#     NL -> push_ood! -> maybe_respecify! -> llm_to_proposal(HTTP mock) -> _parse_proposal
#     -> ReplaceAgent -> verify_replace -> nearest_pool/pop_spare -> replace_robot!.
#   SCOPE: asserts the enabled-loop WIRING fires (respec admitted, spare hand-off enacted,
#   progress monotone). Full COMPLETION is gated on the known R1 frontier-graft stall.
#   ENV: OOD_STEP, NSPARE, FAULT_AT.
# =============================================================================
function scenario_mock_replace()
MOCK_PORT = 8733
ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # CB reads the URL at call time

OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "3"))   # by step ~3 the frontier has opened (closed-count jumps early)
NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))
FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))

_setup_milp!()

# ---- mock /propose: deterministic, grounds ReplaceAgent from request `agents` --------
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body   = JSON3.read(String(req.body))
            event  = haskey(body, "event") ? String(body["event"]) : ""
            agents = haskey(body, "agents") ? body["agents"] : []
            # ground the faulted robot: parse "Robot R<id>" from the NL, else first agent.
            m = match(r"R(\d+)", event)
            aid = ""
            if m !== nothing
                want = "($(m.captures[1]))"
                for a in agents
                    occursin(want, String(a["id"])) && (aid = String(a["id"]); break)
                end
            end
            aid == "" && !isempty(agents) && (aid = String(agents[1]["id"]))
            resp = Dict("constraints" => [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)],
                        "rationale" => "mock: robot breakdown -> replace with nearest spare")
            return HTTP.Response(200, JSON3.write(resp))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# OOD action: fault an active robot once the build is underway, emit the NL. Fired
# once by the one-shot scheduler at OOD_STEP (by which point the frontier has opened).
function ood_action!(env)
    nl = CB.fault_robot!(env)
    nl === nothing && return nothing
    @info "[E2E-1-1] OOD action @closed=$(length(env.cache.closed_set)): faulted a robot; emitting NL"
    return nl
end

println(">>> building nav-ON env (tractor) WITH $(4*NSPARE) spares...")
pp = CB.get_project_params(4)
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!(); CB.clear_ood_schedule!()
ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spares=$(length(CB.active_spares()))")

SRV = start_mock(MOCK_PORT)
CB.RESPEC_ENABLED[] = true
CB.schedule_ood!(OOD_STEP, ood_action!)   # one-shot fault injection once the frontier has opened
println(">>> mock /propose up; ready=$(CB.respec_service_ready()); RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

# seam loop: ood_inject_step! -> step -> respec_step!; capture the respec verdict.
function run_seam_loop(env; cap=120_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    respec_status = Ref{Symbol}(:none); n0 = prev; peak = prev
    for it in 1:cap
        CB.ood_inject_step!(env, it)
        CB.step_environment!(env)
        st = CB.respec_step!(env)
        if st in (:admitted, :fallback, :rejected)
            respec_status[] = st; @info "[E2E-1-1] respec_step! @it=$it -> $st"
        end
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, respec=respec_status[], peak=peak)
        end
        c = length(env.cache.closed_set); peak = max(peak, c)
        stall = c > prev ? 0 : stall + 1; prev = c
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it, respec=respec_status[], peak=peak)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it, respec=respec_status[], peak=peak)
    end
    return (status=:capped, closed=prev, iters=cap, respec=respec_status[], peak=peak)
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched); n0 = length(env.cache.closed_set)
r = run_seam_loop(env)
try close(SRV) catch end

println("\n==== RESULT (mock e2e ReplaceAgent seam) ====")
println("closed $n0 -> $(r.closed) (peak $(r.peak))/$total  status=$(r.status)  respec_verdict=$(r.respec)")
# Assert the WIRING (not full completion, which is gated on the R1 stall):
check("respec seam fired with :admitted (NL->ReplaceAgent->dispatch->replace_robot!)", r.respec == :admitted)
check("no RVO/identity assert (faulted robot didn't crash the sim)", r.status != :asserted)
check("hand-off made progress past the fault point", r.peak > FAULT_AT)
check("a spare was consumed from a pool", length(CB.active_spares()) == 4*NSPARE - 1)

CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_spare_pools!(); CB.clear_faulted_robots!()
println("\n==== mock e2e ReplaceAgent: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ?
    "SEAM GREEN (NL -> mock LLM -> ReplaceAgent -> verify_replace -> spare hand-off enacted). " *
    "Full completion gated on the known R1 frontier-graft stall." :
    "SOME FAILED")
nfail[] == 0 || error("mock_replace_e2e had $(nfail[]) failure(s)")
end

# =============================================================================
# full_loop -- Enabled-seam end-to-end driver for the RESUME full-loop.
#   Build a real env, run the sim to a mid-build state, inject an OOD (robot fault), and
#   confirm the build RESUMES through the verified reassignment and reaches project_complete
#   WITHOUT restarting finished work (closed_set never regresses). Drives the PRODUCTION seam
#   exactly as simulate! does: step_environment! -> respec_step! -> update_planning_cache!.
#   Two modes, auto-selected: LLM seam (respec_service_ready) or LLM-free direct reassign.
#   Force LLM-free with RESPEC_FULLLOOP_NOLLM=1.
# =============================================================================
function scenario_full_loop()
_setup_milp!()

INJECT_AT_CLOSED = 24      # step to this many closed nodes, then inject the fault
STEP_CAP         = 100_000 # hard cap on sim steps (build completes well before)

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

# Pick a still-valid robot on a PENDING transport team so the fault forces a real reassign.
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
end

# =============================================================================
# selfheal -- AUTONOMOUS SELF-HEALING VERIFICATION HARNESS (headless).
#   Run the REAL energy-adaptive build with the live LLM re-spec layer; whenever the LLM's
#   replan loops on the SAME warning/verdict while the sim makes NO progress, STOP that run,
#   record a structured diagnostic verdict, and move on. Drives run_lego_demo's FULL simulate!
#   loop HEADLESS (save_animation=false). Scenario: N_BATTERY soft battery OODs
#   (DeprioritizeAgent) + one central NO-GO zone (whole-build relocation) over a real physics
#   run. REAL LLM service must be UP on :8000 (health checked; aborts if down).
#   ENV: SEEDS (csv), MAXNP, MODE, N_BATTERY, N_OOD, CLOSED_HI, ZONE_CLOSED, ZONE_R, ENERGY_W,
#     PROJECT, VERDICT (jsonl out path), RESPEC_SERVICE_URL.
# =============================================================================
function scenario_selfheal()
ENV["RESPEC_SERVICE_URL"] = get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000")

# ---- knobs ------------------------------------------------------------------
_seeds_env = get(ENV, "SEEDS", "7,11,13,17,23")
SEEDS       = parse.(Int, split(_seeds_env, ","))
MAXNP       = parse(Int,     get(ENV, "MAXNP", "4500"))    # no-progress steps -> terminate (allows reform @2000,4000)
MODE        = get(ENV, "MODE", "soft")                    # soft = battery+central zone; hard = fault+battery+zone stream
N_BATTERY   = parse(Int,     get(ENV, "N_BATTERY", "2"))
N_OOD       = parse(Int,     get(ENV, "N_OOD", "6"))       # hard-mode: # of random mixed OOD events
CLOSED_HI   = parse(Int,     get(ENV, "CLOSED_HI", "200")) # hard-mode: spread OOD up to this closed-count
ZONE_CLOSED = parse(Int,     get(ENV, "ZONE_CLOSED", "60"))
ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))
ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
PROJECT     = parse(Int,     get(ENV, "PROJECT", "4"))
VERDICT     = get(ENV, "VERDICT",
    joinpath(pkgdir(CB), "..", "verify_selfheal_verdicts.jsonl"))

_setup_milp!()

CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# This scenario's run_with_stack RETURNS (:error, e)/(:ok, res) instead of throwing (its
# per-seed loop switches on the status), so it keeps its own variant nested here.
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
# diagnose the problem at that point" the harness exists for.
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
end

# =============================================================================
# spare_replace -- OOD 1-1 Part A4 done-gate (LLM-free).
#   Builds a nav-ON env WITH 4 directional spare pools, steps to mid-build, faults an active
#   robot, hands its remaining chain to the nearest spare via replace_robot! (no MILP), and
#   resumes to completion. The core hypothesis test: does the spare 1:1 hand-off let the build
#   COMPLETE where reassignment double-books? Asserts: spares idle pre-fault; replace_robot!
#   -> :replaced; closed_set monotone; project_complete; faulted robot never crashes RVO.
#   ENV: FAULT_AT, NSPARE, FAULT_OBSTACLE, FAULT (0=control), PROJECT, TARGET, CLEAR_FAULTED,
#     PARK_RESTS, PARK_FAULTED, DYN_SERIAL, REFORM_TEAMS, REFORM_AT.
# =============================================================================
function scenario_spare_replace()
FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))
NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))
FAULT_OBSTACLE = get(ENV, "FAULT_OBSTACLE", "1") == "1"   # diag: drop a static obstacle on the dead robot?
DO_FAULT = get(ENV, "FAULT", "1") == "1"                  # diag: FAULT=0 => control (spares present, no fault/replace)

_setup_milp!()

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

PROJECT = parse(Int, get(ENV, "PROJECT", "4"))   # 4=tractor(team carries), 1=colored_8x8(flat, solo)
pp = CB.get_project_params(PROJECT)
println(">>> building nav-ON env ($(pp[:project_name])) WITH $(4*NSPARE) spares ($(NSPARE)/pool)...")
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spare pools = $(collect(keys(CB.spare_pools())))")

# PRE-FAULT scan: does the BASE env already have any FTU fed by the SAME robot twice?
# (tells us if the duplicate-feeder is pre-existing build structure vs replace-induced)
let sched = ENV0.sched
    dup = 0
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        ids = Int[]
        for vp in Graphs.inneighbors(sched, v)
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo || continue
            r = try CB.entity(pn).id catch; nothing end
            r isa CB.RobotID && push!(ids, r.id)
        end
        if length(ids) != length(unique(ids))
            dup += 1
            dup <= 5 && println("[PRE-FAULT] FTU v=$v fed by robot ids $ids (DUPLICATE same-robot feeder)")
        end
    end
    println("[PRE-FAULT] FTUs with a same-robot duplicate feeder in BASE env: $dup")
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched)

# --- [1] spares present and IDLE (have an idle free node) pre-fault -------------
println("\n[1] spare pools idle pre-fault")
spares = CB.active_spares()
check("4*NSPARE spares registered", length(spares) == 4*NSPARE)
idle = count(s -> CB._idle_free_node(env.sched, s) !== nothing, spares)
println("    -> $(idle)/$(length(spares)) spares have an idle free node")
check("all spares are idle (unassigned)", idle == length(spares))

# --- step helper: returns status NamedTuple --------------------------------------
function step_to(env; until_closed=nothing, cap=250_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    dyn = get(ENV, "DYN_SERIAL", "0") == "1"            # E1: dynamic serialization of spare frontiers
    reform = get(ENV, "REFORM_TEAMS", "0") == "1"       # ReformTeam: snap wedged teams on stall
    reform_at = parse(Int, get(ENV, "REFORM_AT", "1500"))   # no-progress steps before a re-formation
    for it in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, err=typeof(e))
        end
        dyn && CB._enforce_serial_frontiers!(env)
        c = length(env.cache.closed_set)
        stall = c > prev ? 0 : stall + 1; prev = c
        # CLOSED-LOOP: a sustained wedge -> re-form the stuck team(s), then keep going.
        if reform && stall >= reform_at
            nmv = CB.reform_stuck_teams!(env)
            println("    [REFORM] stall=$stall -> repositioned $nmv straggler(s) into formation")
            stall = 0                                   # gave the team a chance; reset the wedge clock
        end
        until_closed !== nothing && c >= until_closed && return (status=:reached, closed=c, iters=it)
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it)
    end
    return (status=:capped, closed=prev, iters=cap)
end

# --- [2] step to mid-build -------------------------------------------------------
println("\n[2] step to mid-build (target closed=$FAULT_AT)")
r1 = step_to(env; until_closed=FAULT_AT)
println("    -> $(r1.status) closed=$(r1.closed) iters=$(r1.iters)")
check("reached mid-build without assert/stall", r1.status == :reached)

# --- CONTROL: spares present, NO fault -> does the base build still complete? -----
if !DO_FAULT
    println("\n[CONTROL] spares present, NO fault -- run base build to completion")
    rc = step_to(env; cap=400_000)
    println("    -> $(rc.status) closed=$(rc.closed)/$total iters=$(rc.iters)")
    check("CONTROL base-with-spares completes", rc.status == :complete)
    CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
    println("\n==== A4 CONTROL: $(npass[]) passed, $(nfail[]) failed ====")
    println(nfail[] == 0 ? "CONTROL GREEN (spares idle don't block; stall is the hand-off)" :
            "CONTROL FAILED (the idle spares themselves break the build)")
    exit(nfail[] == 0 ? 0 : 1)
end

# A CLEANLY-replaceable target: a robot at a free frontier (heading to its NEXT
# pickup, NOT mid-carry), so its hand-off doesn't strand an in-progress transport
# team. = an active RobotGo that is a `_first_pending_assignment` frontier whose
# robot is not also sitting in an active transport-unit team.
function pick_clean_target(env)
    sched = env.sched
    in_active_team(rid) = any(env.cache.active_set) do v
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo) || return false
        team = try CB.robot_team(CB.entity(n)) catch; nothing end
        team !== nothing && haskey(team, rid)
    end
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        pend = CB._first_pending_assignment(env, rid)        # has a clean frontier + pending work
        pend === nothing && continue
        in_active_team(rid) && continue                       # skip mid-carry robots (MVP scope)
        return rid
    end
    return nothing
end

# A SOLO-transport target: a robot whose remaining (non-closed) transport tasks are
# ALL solo (team size 1). Faulting such a robot is the MVP-clean case: no OTHER robot
# is waiting for it as a co-carrier, so the single-spare hand-off has no multi-robot
# timing coordination to satisfy. (Multi-robot-carry faults are future work.)
function pick_solo_target(env)
    sched = env.sched
    # map robot id -> set of team sizes of its non-closed FTU memberships
    function robot_team_sizes(rid)
        sizes = Int[]
        for v in Graphs.vertices(sched)
            v in env.cache.closed_set && continue
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            n isa CB.FormTransportUnit || continue
            team = try CB.robot_team(CB.entity(n)) catch; nothing end
            team !== nothing && haskey(team, rid) && push!(sizes, length(team))
        end
        sizes
    end
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # has pending work
        sizes = robot_team_sizes(rid)
        (!isempty(sizes) && all(==(1), sizes)) || continue               # ALL solo
        push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                                # DETERMINISTIC: lowest id
end

# --- [3] fault a SOLO-transport robot (MVP-clean), hand off to nearest spare ------
println("\n[3] fault a solo-transport robot + replace_robot! with nearest spare")
mode = get(ENV, "TARGET", "solo")
faulted = mode == "solo" ? pick_solo_target(env) :
          mode == "clean" ? pick_clean_target(env) : CB._pick_active_robot(env)
faulted === nothing && (println("    (no solo target; falling back to clean)"); faulted = pick_clean_target(env))
faulted === nothing && (faulted = CB._pick_active_robot(env))   # fallback if none clean
println("    -> faulting robot R$(faulted === nothing ? "?" : faulted.id)")
check("found an active robot to fault", faulted !== nothing)
clear_faulted = get(ENV, "CLEAR_FAULTED", "0") == "1"     # tow dead robot off-grid (demo config)
nl = CB.fault_robot!(env; target=faulted, obstacle=FAULT_OBSTACLE, clear=clear_faulted)
println("    -> clear_faulted = $clear_faulted")
println("    -> fault obstacle registered: $FAULT_OBSTACLE")
println("    -> NL: $nl")
fpos = CB._robot_position_2d(env, faulted)
pool = CB.nearest_pool(fpos)
println("    -> nearest pool = $(pool)")
check("a nearest spare pool exists", pool !== nothing)
spare = CB.pop_spare!(pool)
println("    -> donating spare R$(spare === nothing ? "?" : spare.id) from :$(pool)")
check("popped a spare from the pool", spare !== nothing)
park_rests = get(ENV, "PARK_RESTS", "1") == "1"
println("    -> park_rests = $park_rests")
res = CB.replace_robot!(env, faulted, spare; resume=true, park_rests=park_rests)
println("    -> replace_robot! status=$(res.status) slots=$(get(res,:slots,-1)) serialized=$(get(res,:serialized,-1)) fg=$(get(res,:fg,-1)) slot1=$(get(res,:slot1,-1))")
# DIAG R3: optionally PARK the faulted robot's dead frontier (force-close fg) so the
# faulted robot leaves the active frontier entirely, then rebuild the resume cache.
if get(ENV,"PARK_FAULTED","0") == "1" && haskey(res,:fg)
    fg = res.fg
    fg in env.cache.active_set && delete!(env.cache.active_set, fg)
    push!(env.cache.closed_set, fg)
    CB.reset_cache_resume!(env.cache, env.sched)
    println("    -> PARK_FAULTED: force-closed faulted dead frontier fg=$fg; rebuilt cache")
end
check("replace_robot! -> :replaced", res.status == :replaced)
check("hand-off moved >=1 downstream task", get(res,:slots,0) >= 1)

# --- [4] resume to completion (the done-gate) ------------------------------------
println("\n[4] resume to completion")
closed_after_replace = length(env.cache.closed_set)
r2 = step_to(env; cap=400_000)
println("    -> $(r2.status) closed=$(closed_after_replace) -> $(r2.closed)/$total iters=$(r2.iters)$(haskey(r2,:err) ? "  err=$(r2.err)" : "")")
check("closed_set monotone across replace (no regress)", r2.closed >= closed_after_replace)
check("no RVO/identity assert on the faulted robot", r2.status != :asserted)
check("PROJECT COMPLETE (core done-gate)", r2.status == :complete)

# --- [5] stall diagnosis: dump the active frontier + faulted/spare involvement ----
_rid(n) = (try entity(n).id catch; nothing end)
function diagnose_stall(env, fid, sid)
    sched = env.sched
    println("    faulted=R$(fid===nothing ? "?" : fid.id)  spare=R$(sid===nothing ? "?" : sid.id)")
    nactive = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        rid = _rid(n)
        tag = rid === nothing ? "" : (rid == fid ? "  <== FAULTED" : (rid == sid ? "  <== SPARE" : "  (R$(rid.id))"))
        nactive += 1
        nactive <= 40 && println("      active: $(typeof(n).name.name)$(tag)")
    end
    println("    total active frontier nodes: $nactive")
    isbound(n, who) = (n isa CB.RobotGo) && (_rid(n) == who)
    fleft = fid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), fid)
    end
    sleft = sid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), sid)
    end
    println("    faulted robot still bound to $fleft non-closed RobotGo(s) (dead frontier fg expected = 1)")
    println("    spare   robot still bound to $sleft non-closed RobotGo(s) (its remaining adopted work)")
    # classify the stuck frontier by node type
    types = Dict{Symbol,Int}()
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        t = typeof(n).name.name
        types[t] = get(types, t, 0) + 1
    end
    println("    active frontier by type: $types")
    # did the spare actually move out of its pool toward its work?
    if sid !== nothing
        spos = CB._robot_position_2d(env, sid)
        pc = get(CB.spare_pool_centers(), :east, nothing)
        for (k, c) in CB.spare_pool_centers()   # find the pool the spare came from (nearest center)
            pc === nothing && (pc = c)
        end
        # nearest goal among the spare's active RobotGo nodes
        sgoal_d = Inf
        for v in env.cache.active_set
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == sid) || continue
            g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)) catch; continue end
            sgoal_d = min(sgoal_d, norm(spos .- g))
        end
        println("    spare pos=$(round.(spos;digits=2)); dist to its nearest active goal=$(round(sgoal_d;digits=2)) (robot_r=$(round(CB.default_robot_radius();digits=3)))")
    end
end
# FTU formation diagnosis: for every active RobotGo whose next node is a
# FormTransportUnit, dump the team's per-member capture status (route_planning.jl:480
# requires ALL members in position simultaneously). Pinpoints who is blocking.
function diagnose_ftu(env)
    sched = env.sched; st = env.scene_tree
    fr = CB.faulted_robots()
    shown = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        nxt isa CB.FormTransportUnit || continue
        feeder = _rid(n)
        atgoal = CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                               CB.global_transform(CB.goal_config(n)))
        # inneighbor readiness (route_planning.jl:474-478)
        inn = Graphs.inneighbors(sched, outs[1])
        inn_ready = all(vp -> (vp in env.cache.active_set) || (vp in env.cache.closed_set), inn)
        tu = CB.entity(nxt); team = CB.robot_team(tu)
        shown += 1
        shown > 6 && (println("    ... (more FTUs)"); break)
        ftuv = outs[1]
        dep = CB._adopted_task_deposit(env, v)
        # --- STEP 0: slot goal_config(SCHEDULE) vs tu's expected capture slot(SCENE) drift ---
        # feeder_at_goal targets global_transform(goal_config(slot)); in_capture targets
        # global_transform(tu) ∘ child_transform(tu, rid) (hierarchical_geom_essentials.jl:1032-33).
        # If these disagree the spare can satisfy in_capture but never feeder_at_goal -> FTU never fires.
        drift = NaN
        if feeder !== nothing
            try
                slot_goal = CB.global_transform(CB.goal_config(n))
                ct        = CB.child_transform(tu, feeder)
                expected  = CB.global_transform(tu) ∘ ct
                drift = norm(Vector{Float64}(slot_goal.translation[1:2]) .-
                             Vector{Float64}(expected.translation[1:2]))
            catch e
                drift = -1.0
            end
        end
        println("    [slot v=$v -> FTU v=$ftuv -> deposit v=$(dep)] fed by R$(feeder===nothing ? "?" : feeder.id) (feeder_at_goal=$atgoal, inneighbors_ready=$inn_ready, GOAL_DRIFT=$(round(drift;digits=3))), team=$(length(team)):")
        for (mid, _) in team
            rn = try CB.get_node(st, mid) catch; nothing end
            rn === nothing && (println("      member R$(mid.id): <no scene node>"); continue)
            incap = CB.is_within_capture_distance(tu, rn)
            ftag = haskey(fr, mid) ? " [FAULTED]" : (mid == spare ? " [SPARE]" : "")
            # for a member NOT in position, locate it: pos, whether it's a ROOT (drivable) or
            # captured elsewhere, its active node type, and dist to its nearest active goal.
            extra = ""
            if !incap
                pos = try Vector{Float64}(CB.project_to_2d(CB.global_transform(rn).translation)) catch; [NaN,NaN] end
                isroot = try CB.has_parent(rn, rn) catch; "?" end
                # find this member's active node(s)
                mact = Int[]; mgoal_d = Inf
                for vv in env.cache.active_set
                    nn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vv))
                    (_rid(nn) == mid) || continue
                    push!(mact, vv)
                    g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation)) catch; continue end
                    mgoal_d = min(mgoal_d, norm(pos .- g))
                end
                acttypes = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vv))).name.name) for vv in mact], ",")
                extra = "  pos=$(round.(pos;digits=2)) root=$isroot active=[$acttypes] dist2goal=$(round(mgoal_d;digits=2))"
            end
            println("      member R$(mid.id): in_capture=$incap$ftag$extra")
        end
    end
    shown == 0 && println("    (no active RobotGo feeding a FormTransportUnit found)")
    # find any FTU with >1 spare feeder (the duplicate-feeder bug) and dump ALL its inneighbors
    println("    --- FTUs with duplicate spare feeders (the bug) ---")
    seen_ftu = Set{Int}()
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        v in seen_ftu && continue
        ins = Graphs.inneighbors(sched, v)
        sp_feeders = filter(vp -> begin
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo && _rid(pn) == spare
        end, ins)
        length(sp_feeders) >= 2 || continue
        push!(seen_ftu, v)
        println("    FTU v=$v has $(length(sp_feeders)) spare feeders; ALL inneighbors:")
        for vp in ins
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            rid = _rid(pn)
            cl = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
            ppreds = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vpp))).name.name) for vpp in Graphs.inneighbors(sched,vp)], ",")
            println("      in v=$vp $(typeof(pn).name.name) R$(rid===nothing ? "?" : rid.id) [$cl] <-preds[$ppreds]")
        end
    end
end
if r2.status != :complete
    println("\n[5] STALL DIAGNOSIS (active frontier at stall)")
    diagnose_stall(env, faulted, spare)
    println("\n[6] FTU FORMATION DIAGNOSIS (who blocks each pending transport team)")
    diagnose_ftu(env)
    println("\n[7] SPARE THREAD STRUCTURE (is the adopted work a single sequential chain?)")
    let sched = env.sched
        nactive_spare = 0
        for v in Graphs.vertices(sched)
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == spare) || continue
            v in env.cache.closed_set && continue
            preds = Graphs.inneighbors(sched, v)
            predinfo = join([begin
                pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
                pc = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
                "$(typeof(pn).name.name)[$pc]"
            end for vp in preds], ",")
            isact = v in env.cache.active_set
            isact && (nactive_spare += 1)
            outs = Graphs.outneighbors(sched, v)
            sucinfo = join([begin
                sn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vs))
                "$(typeof(sn).name.name)"
            end for vs in outs], ",")
            isterm = isempty(outs)
            t0 = try round(Float64(CB.get_t0(sched, v)); digits=2) catch; "?" end
            atg = try CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                                    CB.global_transform(CB.goal_config(n))) catch; "?" end
            println("    spare RobotGo v=$v active=$isact t0=$t0 at_goal=$atg terminal=$isterm  preds=[$predinfo]  succs=[$sucinfo]")
        end
        println("    => spare has $nactive_spare CONCURRENTLY ACTIVE RobotGo(s) (should be 1 for a sequential thread)")
    end
end

CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
println("\n==== A4 spare_replace_test: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ? "ALL GREEN (spare 1:1 hand-off completes the build)" :
        "SOME FAILED (see above; likely R1 frontier-graft / R3 faulted-driving -- diagnose)")
end

# =============================================================================
# live_respec -- LIVE end-to-end: OOD -> Claude -> DSL -> verify -> admit -> re-solve,
#   through the RUNNING Python LLM service. This is the LIVE sibling of mock_respec/
#   mock_replace: real Claude does the NL->DSL translation. Builds the tractor env,
#   steps to some completed work, then runs 2 live OOD rounds. Bad refs route to the
#   safe fallback; valid re-specs are verified (completed work frozen) and re-solved.
#   REQUIRES: the Python service UP (RESPEC_SERVICE_URL, default :8000) with a valid
#   ANTHROPIC_API_KEY. If the service is down it reports and exits(0) (no LLM call).
# =============================================================================
function scenario_live_respec()
# A robot-fault re-spec triggers a real MILP re-solve (reassignment). Greedy
# assembly never set a default optimizer, so set one with a feasibility-first gap
# (return the first feasible integer solution rather than proving optimality) so
# the re-solve is fast & reliable, and silence the per-solve HiGHS log spam.
_setup_milp!()

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
        CB.commit_respec!(env, milp, verdict.proposal)
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
end

# ---- dispatcher -------------------------------------------------------------
const SCENARIOS = Dict(
    "mock_respec"   => scenario_mock_respec,
    "mock_replace"  => scenario_mock_replace,
    "full_loop"     => scenario_full_loop,
    "selfheal"      => scenario_selfheal,
    "spare_replace" => scenario_spare_replace,
    "live_respec"   => scenario_live_respec,
)
end # module E2E

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "E2E", isempty(ARGS) ? "mock_respec" : ARGS[1])
    haskey(E2E.SCENARIOS, key) || error("unknown scenario '$key'. Available: $(join(sort(collect(keys(E2E.SCENARIOS))), ", "))")
    println(">>> running e2e scenario: $key")
    E2E.SCENARIOS[key]()
end
