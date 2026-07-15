# =============================================================================
# tools/demos.jl -- consolidated ConstructionBots demo driver.
#
# Every standalone tools/demo_*.jl script is now a FUNCTION in module `Demos`,
# sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A CLI/ENV
# dispatcher at the bottom lets any single demo run individually.
#
# Demo keys:
#   original_baseline   -- vanilla SISL build (no OOD / no respec)          [before]
#   run_zone            -- OOD 1-2 restriction no-go zone; robots detour (RESPEC off, physical)
#   wholebuild          -- central forbid zone -> whole-build translate (geom recovery direct)
#   respec_forbidzone   -- ForbidZone respec pipeline via mock LLM seam
#   respec_replace      -- OOD 1-1 ReplaceAgent (robot breakdown -> spare) via mock LLM seam
#   rl_replace          -- same ReplaceAgent scenario, TRAINED RL policy as producer
#   surrogate           -- learned SURROGATE world model ranks 5 macros in imagination (single OOD)
#   surrogate_stream    -- surrogate adapting to a STREAM of mixed OOD + live battery HUD
#   energy_adaptive     -- energy-aware adaptive replanning, multi-OOD, NO animation (metrics only)
#   energy_adaptive_anim-- energy-aware adaptive replanning, VISUAL (battery HUD sidebar)
#   energy_stall_replace-- closed battery loop: SoC=0 stall -> ReplaceAgent -> depot spare (VISUAL)
#
# Run:
#   julia +lts --project=. tools/demos.jl <demo_key>        (or  ENV DEMO=<key>)
# e.g.
#   julia +lts --project=. tools/demos.jl respec_replace
#   DEMO=surrogate_stream julia +lts --project=. tools/demos.jl
# Each demo reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Demos
using ConstructionBots
using Printf
import Logging, HiGHS, HTTP, JSON3, Graphs, LinearAlgebra, Random
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer and the decpomdp OOD example layer are NOT compiled into the
# ConstructionBots package -- the demos historically `CB.include`d them at SCRIPT TOP
# LEVEL. Now that each demo is a FUNCTION, doing those includes *inside* a demo and then
# calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading them here at MODULE
# load puts them in an OLDER world than any demo call, exactly reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so ONE call
# covers every navigator-using demo; the three decpomdp examples only need CB (no DecPOMDP).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
let _EX = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
    include(joinpath(_EX, "ood_env.jl"))       # OODEnv, _n_closed
    include(joinpath(_EX, "ood_env_mdp.jl"))   # event_context, valid_actions, action_to_proposal, canonical_action
    include(joinpath(_EX, "ood_reinforce.jl")) # LinearPolicy, greedy_action, load_policy
end

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically) in 8 of the 10
# demos. The two surrogate demos use a DIFFERENT attribute set (output_flag instead
# of MOI.Silent, 60s/0.05 gap) and keep their block inline -- see those functions.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper from 9 of the 10 demos.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# demo_rl_replace's state shim (a struct cannot be defined inside a function, so it
# lives at module level; it is only referenced by demo_rl_replace).
mutable struct _RLShim
    env
    step_count::Int
    no_progress::Int
    n_events::Int
    max_steps::Int
end

# =============================================================================
# original_baseline -- the ORIGINAL SISL ConstructionBots demo, unchanged. Plain
#   run_lego_demo tractor build with the full nav stack; no OOD/respec/fault/zone.
#   ENV: OPEN_ANIM (open browser at end).
# =============================================================================
function demo_original_baseline()
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"   # set OPEN_ANIM=0 to only save the HTML

_setup_milp!()

# hygiene: make sure no OOD/zone/respec state leaks in from a shared session (fresh process anyway)
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()

project_params = CB.get_project_params(4)   # 4 = tractor (same as scripts/demos.jl)

println(">>> ORIGINAL SISL ConstructionBots demo: project=$(project_params[:project_name]) " *
        "(plain build, NO OOD / NO respec)")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; HTML saved at end)...")

env, stats = CB.run_lego_demo(;
    ldraw_file=project_params[:file_name],
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=:greedy,
    milp_optimizer=:highs,
    optimizer_time_limit=60,
    rvo_flag=true,
    tangent_bug_flag=true,
    dispersion_flag=true,
    # --- animation ON (save; do not auto-open unless OPEN_ANIM=1) ---
    open_animation_at_end=OPEN_ANIM,
    save_animation=true,
    save_animation_along_the_way=false,
    anim_active_agents=true,
    anim_active_areas=true,
    update_anim_at_every_step=true,
    save_anim_interval=100,
    process_updates_interval=100,
    block_save_anim=false,
    # --- housekeeping ---
    write_results=false,
    overwrite_results=true,
    look_for_previous_milp_solution=false,
    save_milp_solution=false,
    previous_found_optimizer_time=30,
    max_num_iters_no_progress=2500,
    stop_after_task_assignment=false,
);

htmlpath = joinpath("results", project_params[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
println(">>> done. Animation saved: $htmlpath")
end

# =============================================================================
# wholebuild -- VISUAL demo of whole-build translation. At OOD_STEP drops a CENTRAL
#   forbid zone over the root core, tries per-assembly restage_all, then
#   translate_whole_build! to shift the ENTIRE build clear of the zone.
#   ENV: NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, OPEN_ANIM, GRID_SCALE.
# =============================================================================
function demo_wholebuild()
PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))      # 4 = tractor
# Inject EARLY (default 5): translate_whole_build! is an MVP that only relocates a build
# whose parts are not yet IN TRANSPORT. step_1_closed≈45 trivial nodes close at iter 1, so
# iter~5 ≈ the headless-validated closed=46 state (nothing carried yet). Larger OOD_STEP
# injects mid-transport and the moved deposit slots desync in-flight cargo -> capture assert.
OOD_STEP = parse(Int, get(ENV, "OOD_STEP", "5"))           # sim step to drop the zone + recover
ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"             # open browser at end (set OPEN_ANIM=0 to only save HTML)
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0")) # widen MeshCat default floor grid (cosmetic) so the relocated build stays on-grid

_setup_milp!()

# The OOD action: drop the central zone, then geometric recovery. Returns `nothing`
# (skip the LLM respec path -- we drive restage/whole-build directly).
function ood_recover!(env)
    gs = CB.root_deposit_goals(env)
    rootc = Vector{Float64}(CB.get_center(
        env.staging_circles[argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))])[1:2])
    zc = isempty(gs) ? rootc : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:block, zc, ZONE_R)
    @info "[DEMO] OOD @ step $OOD_STEP: central zone@$(round.(zc;digits=2)) R=$ZONE_R (root@$(round.(rootc;digits=2)))"
    ra = CB.restage_all_blocked!(env; resume=true, verbose=true)
    @info "[DEMO] restage_all -> $(ra.status) (residual $(get(ra,:residual,-1)))"
    if ra.status == :residual_blocked
        wb = CB.translate_whole_build!(env; resume=true, verbose=true)
        @info "[DEMO] translate_whole_build! -> $(wb.status) Δ=$(get(wb,:delta,nothing)) residual=$(get(wb,:residual,-1))"
    elseif ra.status in (:restaged_all, :none)
        @info "[DEMO] zone cleared by per-assembly restage alone ($(ra.status)) -- no whole-build needed"
    end
    return nothing
end

CB.clear_ood_schedule!(); CB.clear_restriction_zones!()   # hygiene (fresh process anyway)
CB.schedule_ood!(OOD_STEP, ood_recover!)

pp = CB.get_project_params(PROJECT)
println(">>> VISUAL whole-build demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP zone_R=$ZONE_R")
println(">>> building + simulating with FULL NAV + ANIMATION (slow; browser opens at end)...")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Info, rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        # --- animation ON ---
        save_animation=true, open_animation_at_end=OPEN_ANIM, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE,
        # --- housekeeping ---
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=false)
end
println(">>> done. The browser tab shows the animation (press the play arrow, bottom-right).")
end

# =============================================================================
# respec_forbidzone -- VISUAL demo of the FULL ForbidZone respec pipeline, driven
#   through the REAL seam with a deterministic mock LLM (no Anthropic key). At OOD_STEP
#   a central zone + NL string route through /propose -> ForbidZone -> restage/translate.
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, NAVON_ZONE_R, GRID_SCALE, OPEN_ANIM.
# =============================================================================
function demo_respec_forbidzone()
# USE_MOCK=1 (default): stand up a local deterministic mock /propose (no API key needed).
# USE_MOCK=0: use the REAL Python LLM service at RESPEC_SERVICE_URL (default :8000).
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8732"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"        # default real-service address
end

PROJECT   = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
OOD_STEP  = parse(Int, get(ENV, "OOD_STEP", "5"))
ZONE_R    = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"

_setup_milp!()

# deterministic mock /propose: grounds a ForbidZone from the request's own zones/nodes
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body  = JSON3.read(String(req.body))
            zones = haskey(body, "zones") ? body["zones"] : []
            nodes = haskey(body, "nodes") ? body["nodes"] : []
            zkey  = isempty(zones) ? "zone" : String(zones[1]["key"])
            cov   = isempty(zones) ? [] : zones[1]["covers"]
            aid   = !isempty(cov) ? String(first(cov)) : (isempty(nodes) ? "" : String(nodes[1]["id"]))
            @info "[MOCK-LLM] /propose -> ForbidZone(zone=$zkey, assembly=$aid)"
            return HTTP.Response(200, JSON3.write(Dict(
                "constraints" => [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => aid)],
                "rationale" => "mock: spatial no-go zone over the build core")))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))

# OOD action fired inside the sim: inject the physical zone + emit the NL string (-> push_ood!)
function ood_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[DEMO] OOD @ step $OOD_STEP: zone@$(round.(zc;digits=2)) R=$ZONE_R; emitting NL event"
    return "A safety exclusion zone is now active over the central build area; " *
           "robots must not enter or pass through it."
end

# captured RESPEC pipeline log lines (filled by run_lego_demo via log_sink) -> embedded into the HTML
_PIPE = String[]
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    rows = map(lines) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :                                  # NL input (amber)
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :  # DSL out (green)
            (occursin("WHOLE-BUILD", ln) || occursin("admitted", ln)) ? "#79c0ff" :   # recovery (blue)
            "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return "<div id=\"respec-log\" style=\"position:fixed;top:8px;left:8px;max-width:46vw;max-height:92vh;" *
        "overflow:auto;background:rgba(16,18,26,.86);font:12px/1.5 ui-monospace,Consolas,monospace;" *
        "padding:10px 13px;border-radius:9px;z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div style=\"color:#9bd1ff;font-weight:700;margin-bottom:5px\">RESPEC pipeline &nbsp;—&nbsp; " *
        "natural language → DSL → geometric recovery</div>" * join(rows, "") * "</div>"
end

SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.schedule_ood!(OOD_STEP, ood_action!)

pp = CB.get_project_params(PROJECT)
ready = CB.respec_service_ready()
println(">>> VISUAL ForbidZone respec demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> /propose at $(ENV["RESPEC_SERVICE_URL"])  ready=$ready  RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start `uvicorn server:app --port 8000` in a shell WITH ANTHROPIC_API_KEY first."
println(">>> building + simulating with FULL NAV + RESPEC SEAM + ANIMATION (slow)...")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        save_animation=true, open_animation_at_end=false, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()

# embed the captured NL->DSL->recovery log INTO the saved HTML (animation + log in ONE file)
htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) RESPEC pipeline log lines into the HTML.")
else
    println(">>> WARNING: no RESPEC log captured to embed (_PIPE empty).")
end
println(">>> done. Open (animation + RESPEC log in ONE file): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open it manually: $e" end)
end

# =============================================================================
# respec_replace -- VISUAL demo of the FULL OOD 1-1 ReplaceAgent respec pipeline
#   (robot breakdown -> spare hand-off) via the REAL seam with a mock LLM. 4 directional
#   spare pools; at OOD a clean solo transporter is faulted -> ReplaceAgent -> nearest spare.
#   ENV: USE_MOCK, MOCK_PORT, NAVON_PROJECT, OOD_STEP, FAULT_CLOSED, NSPARE, GRID_SCALE,
#        OPEN_ANIM, HOT_SWAP, TARGET_ROBOT, FAULT_TARGET, SAVE_ANIM, REFORM_INTERVAL, NOPROG.
# =============================================================================
function demo_respec_replace()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8734"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

PROJECT    = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
OOD_STEP     = parse(Int, get(ENV, "OOD_STEP", "20"))     # fault at sim-step (used if FAULT_CLOSED=0)
FAULT_CLOSED = parse(Int, get(ENV, "FAULT_CLOSED", "0"))  # >0: fault when this many nodes CLOSED (build-progress; reproducible)
NSPARE     = parse(Int, get(ENV, "NSPARE", "2"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SOLO_TARGET = get(ENV, "SOLO_TARGET", "1") == "1"   # fault a solo-transport robot (MVP-clean completion)

_setup_milp!()

# deterministic mock /propose: grounds a ReplaceAgent from the request's NL + agents.
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        if path == "/health"
            return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        elseif path == "/propose"
            body   = JSON3.read(String(req.body))
            event  = haskey(body, "event") ? String(body["event"]) : ""
            agents = haskey(body, "agents") ? body["agents"] : []
            # a "team is deadlocked / stuck forming" event -> ReformTeam (no fields).
            if occursin(r"(?i)deadlock|stuck|stall|cannot complete|re-establish|reform"a, event)
                @info "[MOCK-LLM] /propose -> ReformTeam()"
                return HTTP.Response(200, JSON3.write(Dict(
                    "constraints" => [Dict("kind" => "ReformTeam")],
                    "rationale" => "mock: transport team deadlocked -> re-establish the stuck team")))
            end
            m = match(r"R(\d+)", event); aid = ""
            if m !== nothing
                want = "($(m.captures[1]))"
                for a in agents; occursin(want, String(a["id"])) && (aid = String(a["id"]); break); end
            end
            aid == "" && !isempty(agents) && (aid = String(agents[1]["id"]))
            @info "[MOCK-LLM] /propose -> ReplaceAgent(agent=$aid)"
            return HTTP.Response(200, JSON3.write(Dict(
                "constraints" => [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)],
                "rationale" => "mock: robot breakdown -> replace with nearest spare")))
        end
        return HTTP.Response(404, "not found")
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# pick a robot whose remaining transport tasks are ALL solo (team size 1): the MVP-clean
# fault case (no other robot waits for it as a co-carrier). nothing if none.
function _solo_fault_target(env)
    sched = env.sched
    team_sizes(rid) = [length(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))))
        for v in Graphs.vertices(sched)
        if !(v in env.cache.closed_set) &&
           CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)) isa CB.FormTransportUnit &&
           (try haskey(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))), rid) catch; false end)]
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue
        s = team_sizes(rid)
        (!isempty(s) && all(==(1), s)) && push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]            # DETERMINISTIC (lowest id), matches the verified test
end

# A robot CURRENTLY carrying one part ALONE: an active FormTransportUnit whose team is size 1.
function _solo_ftu_fault_target(env)
    for v in env.cache.active_set
        m = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        m isa CB.FormTransportUnit || continue
        tm = try CB.robot_team(CB.entity(m)) catch; nothing end
        (tm === nothing || length(tm) != 1) && continue
        rid = try first(keys(tm)) catch; nothing end
        rid isa CB.RobotID && return rid
    end
    return nothing
end

# STRICTER target for GUARANTEED completion: a robot with EXACTLY ONE remaining (non-closed)
# transport-feeding RobotGo slot, and that task is SOLO (team size 1).
function _single_solo_fault_target(env)
    sched = env.sched
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue
        n_slots = 0; all_solo = true
        for w in Graphs.vertices(sched)
            w in env.cache.closed_set && continue
            m = CB.get_node_from_id(sched, CB.get_vtx_id(sched, w))
            m isa CB.RobotGo || continue
            (try CB.entity(m).id == rid catch; false end) || continue
            outs = Graphs.outneighbors(sched, w); isempty(outs) && continue
            fn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
            fn isa CB.FormTransportUnit || continue
            n_slots += 1
            (try length(CB.robot_team(CB.entity(fn))) == 1 catch; false end) || (all_solo = false)
        end
        (n_slots == 1 && all_solo) && push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]            # DETERMINISTIC (lowest id)
end

TARGET_ROBOT = parse(Int, get(ENV, "TARGET_ROBOT", "0"))   # >0: fault this exact robot id (else solo-pick)
# find the active robot with a specific id (to reproduce a verified scenario)
function _robot_by_id(env, rid::Int)
    for v in env.cache.active_set
        n = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        n isa CB.RobotGo || continue
        r = try CB.entity(n).id catch; nothing end
        (r isa CB.RobotID && r.id == rid) && return r
    end
    return nothing
end

# OOD action fired inside the sim: fault EXACTLY ONE robot + emit the NL string (-> push_ood!).
_FAULTED_ONCE = Ref(false)
function ood_action!(env)
    _FAULTED_ONCE[] && return nothing                        # only one fault for the whole demo
    if get(ENV, "FAULT_DIAG", "0") == "1"                    # TEMP diagnostic: why does the fault defer?
        nclosed = length(env.cache.closed_set)
        nrg = 0; npend = 0; nsolo = 0
        for v in env.cache.active_set
            n = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
            n isa CB.RobotGo || continue
            nrg += 1
            rid = try CB.entity(n).id catch; nothing end
            rid isa CB.RobotID || continue
            CB._first_pending_assignment(env, rid) === nothing && continue
            npend += 1
        end
        st = _solo_fault_target(env); nsolo = st === nothing ? 0 : 1
        # ALSO count solo FormTransportUnit teams (a robot carrying ONE part alone) regardless of pending
        soloftu = String[]
        for v in env.cache.active_set
            m = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
            m isa CB.FormTransportUnit || continue
            tm = try CB.robot_team(CB.entity(m)) catch; nothing end
            tm === nothing && continue
            if length(tm) == 1
                rid = try first(keys(tm)) catch; nothing end
                rid === nothing || push!(soloftu, string(rid))
            end
        end
        @info "[FAULT_DIAG] closed=$nclosed activeRobotGo=$nrg withPending=$npend soloTarget=$(st===nothing ? "none" : "R$(st.id)") soloFTU=$(length(soloftu))$(isempty(soloftu) ? "" : "["*join(soloftu,",")*"]")"
    end
    # Target preference (most completion-safe first):
    #   1. _single_solo_fault_target: EXACTLY ONE remaining solo task -> spare inherits a single clean task.
    #   2. _solo_fault_target: any solo-team RobotGo with a pending assignment (classic clean case).
    #   3. _solo_ftu_fault_target: a robot currently carrying a part ALONE (detected by execution state).
    # FAULT_TARGET=single|solo|ftu pins one picker (for A/B testing completion).
    pick = get(ENV, "FAULT_TARGET", "auto")
    tgt = if TARGET_ROBOT > 0
        _robot_by_id(env, TARGET_ROBOT)
    elseif pick == "single"
        _single_solo_fault_target(env)                       # STRICT: only the completion-guaranteed target
    elseif pick == "solo"
        _solo_fault_target(env)
    elseif pick == "ftu"
        _solo_ftu_fault_target(env)
    else                                                     # "auto": try strictest first, then fall back
        t = _single_solo_fault_target(env)
        t === nothing && (t = _solo_fault_target(env))
        t === nothing && (t = _solo_ftu_fault_target(env))
        t
    end
    tgt === nothing && return nothing                        # no safe solo target this step -> defer/retry
    # obstacle=false: no no-go zone on the dead robot. clear=false: KEEP the broken robot visible (RED).
    nl = CB.fault_robot!(env; target = tgt, obstacle = false, clear = false)
    nl === nothing && return nothing
    _FAULTED_ONCE[] = true
    @info "[DEMO] OOD: faulted R$(tgt.id) (solo transporter); marked it RED (faulted); emitting NL event"
    return nl
end

# captured RESPEC pipeline log lines -> embedded into the HTML
_PIPE = String[]
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    # Collapse repeats while keeping first-occurrence order.
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln)
        counts[ln] = get(counts, ln, 0) + 1
    end
    rows = map(order) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :                                  # NL input (amber)
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :  # DSL out (green)
            (occursin("ADMITTED", ln) || occursin("replace", ln) || occursin("spare", ln)) ? "#79c0ff" :  # recovery (blue)
            (occursin("declined", ln) || occursin("REJECTED", ln) || occursin("FALLBACK", ln)) ? "#ff9b9b" : # declined (red)
            "#d8e0ee"
        n = counts[ln]
        badge = n > 1 ? " <span style=\"opacity:.55\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end
    return "<div id=\"respec-log\" style=\"position:fixed;top:10px;left:10px;width:340px;max-height:42vh;" *
        "overflow:auto;background:rgba(16,18,26,.82);font:11px/1.45 ui-monospace,Consolas,monospace;" *
        "border-radius:9px;z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div onclick=\"var b=document.getElementById('respec-body');" *
        "b.style.display=(b.style.display=='none'?'block':'none');\" " *
        "style=\"color:#9bd1ff;font-weight:700;padding:8px 11px;cursor:pointer;position:sticky;top:0;" *
        "background:rgba(16,18,26,.96);border-radius:9px 9px 0 0;user-select:none\">" *
        "RESPEC pipeline (OOD 1-1) <span style=\"opacity:.55;font-weight:400\">— click to hide ▾</span></div>" *
        "<div id=\"respec-body\" style=\"padding:6px 11px 9px\">" * join(rows, "") * "</div></div>"
end

SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.clear_recovery_spares!(); CB.clear_wedge_edges!()
# HOT_SWAP=1: enact ReplaceAgent as an IDENTITY-PRESERVING scene-tree hot-swap (keep the faulted
# RobotID, swap only its physical body from the depot) instead of the schedule-restamping replace.
if get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
    println(">>> HOT_SWAP ON (mode=$(CB.HOT_SWAP_MODE[])): ReplaceAgent -> identity-preserving depot swap (no schedule re-stamp).")
else
    CB.set_hot_swap!(enabled = false)
end
try; CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))); catch; end
# Fire the fault at a build-PROGRESS point (reproducible) where a clean solo transporter exists.
if FAULT_CLOSED > 0
    CB.schedule_ood_at_closed!(FAULT_CLOSED, ood_action!)
else
    for s in (parse(Int, get(ENV, "FAULT_STEP0", "8"))):(parse(Int, get(ENV, "FAULT_STEPD", "1"))):(parse(Int, get(ENV, "FAULT_STEP1", "150")))
        CB.schedule_ood!(s, ood_action!)
    end
end

pp = CB.get_project_params(PROJECT)
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> VISUAL ReplaceAgent respec demo: project=$(pp[:project_name]) OOD_STEP=$OOD_STEP spares=$(4*NSPARE)  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> /propose at $(ENV["RESPEC_SERVICE_URL"])  ready=$ready  RESPEC_ENABLED=$(CB.RESPEC_ENABLED[])")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start `uvicorn server:app --port 8000` in a shell WITH ANTHROPIC_API_KEY first."
println(">>> building + simulating with FULL NAV + SPARE POOLS + RESPEC SEAM + ANIMATION (slow)...")

SAVE_ANIM = get(ENV, "SAVE_ANIM", "1") == "1"   # 0 = fast verification run (no animation recording)
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=parse(Int, get(ENV, "NOPROG", "30000")),
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,
        save_animation=SAVE_ANIM, open_animation_at_end=false, update_anim_at_every_step=SAVE_ANIM,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_spare_pools!(); CB.clear_faulted_robots!()

htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) RESPEC pipeline log lines into the HTML.")
else
    println(">>> WARNING: no RESPEC log captured to embed (_PIPE empty).")
end
println(">>> done. Open (animation + RESPEC log in ONE file): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open it manually: $e" end)
end

# =============================================================================
# rl_replace -- VISUAL demo of the OOD 1-1 ReplaceAgent pipeline driven by the TRAINED
#   REINFORCE (MARL) POLICY instead of the LLM. IDENTICAL scenario to respec_replace;
#   the only difference is the producer plugged into the seam (greedy_action(LinearPolicy)).
#   Output goes to results/tractor_rl/ so it does not overwrite the LLM demo's HTML.
#   ENV: OOD_POLICY, NAVON_PROJECT, OOD_STEP, FAULT_CLOSED, NSPARE, GRID_SCALE, OPEN_ANIM,
#        TARGET_ROBOT, SAVE_ANIM, REFORM_INTERVAL.
# =============================================================================
function demo_rl_replace()
# The RL policy + state/action layer live in the decpomdp project's examples/. They only need
# `import ConstructionBots as CB` (NO DecPOMDP), so we include them directly here.
_EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
# ood_env.jl / ood_env_mdp.jl / ood_reinforce.jl are now loaded ONCE at module top (world-age).

PROJECT      = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
OOD_STEP     = parse(Int, get(ENV, "OOD_STEP", "20"))     # fault at sim-step (used if FAULT_CLOSED=0)
FAULT_CLOSED = parse(Int, get(ENV, "FAULT_CLOSED", "0"))  # >0: fault when this many nodes CLOSED (reproducible)
NSPARE       = parse(Int, get(ENV, "NSPARE", "2"))
GRID_SCALE   = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM    = get(ENV, "OPEN_ANIM", "1") == "1"
TARGET_ROBOT = parse(Int, get(ENV, "TARGET_ROBOT", "0"))
SAVE_ANIM    = get(ENV, "SAVE_ANIM", "1") == "1"
POLICY_PATH  = get(ENV, "OOD_POLICY",
    joinpath(dirname(pkgdir(CB)), "decpomdp", "checkpoints", "ood_policy.txt"))

_setup_milp!()

# ---- load the trained policy ----------------------------------------------------------
POLICY = if isfile(POLICY_PATH)
    println(">>> loaded trained RL policy: $POLICY_PATH")
    load_policy(POLICY_PATH)
else
    @warn "no trained policy at $POLICY_PATH -- using a RANDOM-INIT policy (train first: decpomdp> julia +lts --project=. examples/ood_train.jl)"
    LinearPolicy(Random.MersenneTwister(1))
end

# ---- captured RESPEC/RL pipeline log lines -> embedded into the HTML -------------------
_PIPE = String[]

# ---- RL producer: read state at the OOD event, emit the masked greedy DSL action -------
_SHIM = _RLShim(nothing, 0, 0, 0, 4000)

function rl_producer(env, event)
    _SHIM.env = env
    _SHIM.n_events += 1
    _SHIM.step_count = round(Int, _progress(env) * _SHIM.max_steps)   # progress-proxied makespan pressure
    ctx  = event_context(env, event)
    s    = extract_state(_SHIM, ctx)
    a    = greedy_action(POLICY, s, valid_actions(ctx))
    prop = action_to_proposal(ctx, a)
    @info "[RL-POLICY] OOD=$(ctx.type) agent=$(ctx.agent===nothing ? "-" : "R$(ctx.agent.id)") -> $(OOD_ACTIONS[a+1])$(prop===nothing ? " (NOOP)" : "")"
    return prop
end

# ---- fault-target selection (VERBATIM from demo_respec_replace_anim.jl for an identical scenario) ----
function _solo_fault_target(env)
    sched = env.sched
    team_sizes(rid) = [length(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))))
        for v in Graphs.vertices(sched)
        if !(v in env.cache.closed_set) &&
           CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)) isa CB.FormTransportUnit &&
           (try haskey(CB.robot_team(CB.entity(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)))), rid) catch; false end)]
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue
        sz = team_sizes(rid)
        (!isempty(sz) && all(==(1), sz)) && push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]            # DETERMINISTIC (lowest id)
end
function _robot_by_id(env, rid::Int)
    for v in env.cache.active_set
        n = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        n isa CB.RobotGo || continue
        r = try CB.entity(n).id catch; nothing end
        (r isa CB.RobotID && r.id == rid) && return r
    end
    return nothing
end

# OOD action fired inside the sim: fault EXACTLY ONE robot + emit the NL string (-> push_ood!).
_FAULTED_ONCE = Ref(false)
function ood_action!(env)
    _FAULTED_ONCE[] && return nothing                        # only one fault for the whole demo
    tgt = TARGET_ROBOT > 0 ? _robot_by_id(env, TARGET_ROBOT) : _solo_fault_target(env)
    tgt === nothing && return nothing                        # no SAFE target yet -> defer to a later trigger
    nl = CB.fault_robot!(env; target = tgt, obstacle = false, clear = false)
    nl === nothing && return nothing
    _FAULTED_ONCE[] = true
    @info "[DEMO] OOD: faulted R$(tgt.id) (clean solo transporter); marked RED (faulted); emitting NL event"
    return nl
end

# ---- HTML log panel (colorized; RL decisions in green) --------------------------------
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln)
        counts[ln] = get(counts, ln, 0) + 1
    end
    rows = map(order) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :                                  # NL input (amber)
            (occursin("RL-POLICY", ln) || occursin("LLM proposal", ln)) ? "#7ee787" :  # DSL out (green)
            (occursin("ADMITTED", ln) || occursin("replace", ln) || occursin("spare", ln)) ? "#79c0ff" :  # recovery (blue)
            (occursin("declined", ln) || occursin("REJECTED", ln) || occursin("FALLBACK", ln)) ? "#ff9b9b" : # declined (red)
            "#d8e0ee"
        n = counts[ln]
        badge = n > 1 ? " <span style=\"opacity:.55\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end
    return "<div id=\"respec-log\" style=\"position:fixed;top:10px;left:10px;width:340px;max-height:42vh;" *
        "overflow:auto;background:rgba(16,18,26,.82);font:11px/1.45 ui-monospace,Consolas,monospace;" *
        "border-radius:9px;z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div onclick=\"var b=document.getElementById('respec-body');" *
        "b.style.display=(b.style.display=='none'?'block':'none');\" " *
        "style=\"color:#9bd1ff;font-weight:700;padding:8px 11px;cursor:pointer;position:sticky;top:0;" *
        "background:rgba(16,18,26,.96);border-radius:9px 9px 0 0;user-select:none\">" *
        "RL POLICY pipeline (OOD 1-1) <span style=\"opacity:.55;font-weight:400\">— click to hide ▾</span></div>" *
        "<div id=\"respec-body\" style=\"padding:6px 11px 9px\">" * join(rows, "") * "</div></div>"
end

# ---- wire the seam: RL producer instead of the LLM, same OOD schedule ------------------
CB.RESPEC_ENABLED[] = true
CB.set_respec_producer!(rl_producer)               # <-- the ONLY substantive difference vs the LLM demo
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.clear_recovery_spares!(); CB.clear_wedge_edges!()
try; CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))); catch; end
# Fire the fault at a build-PROGRESS point (reproducible) where a clean solo transporter exists.
if FAULT_CLOSED > 0
    CB.schedule_ood_at_closed!(FAULT_CLOSED, ood_action!)
else
    for c in (10, 18, 28, 42, 60)
        CB.schedule_ood_at_closed!(c, ood_action!)
    end
end

pp = CB.get_project_params(PROJECT)
PROJ_RL = "$(pp[:project_name])_rl"           # separate results folder so the LLM HTML is preserved
println(">>> VISUAL RL(ReplaceAgent) demo: project=$(pp[:project_name]) fault@closed=$(FAULT_CLOSED>0 ? string(FAULT_CLOSED) : "10/18/28/42/60(first safe)") spares=$(4*NSPARE)  producer=TRAINED-RL")
println(">>> building + simulating with FULL NAV + SPARE POOLS + RL PRODUCER + ANIMATION (slow)...")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=PROJ_RL,
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=30000,     # match the LLM demo (fair comparison)
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true, n_spare_per_pool=NSPARE,
        save_animation=SAVE_ANIM, open_animation_at_end=false, update_anim_at_every_step=SAVE_ANIM,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end

# reset globals so later runs are byte-for-byte normal
CB.RESPEC_ENABLED[] = false; CB.clear_respec_producer!()
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()

htmlpath = joinpath("results", PROJ_RL, "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html  = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) RL pipeline log lines into the HTML.")
else
    println(">>> WARNING: no RL log captured to embed (_PIPE empty) or HTML missing.")
end
println(">>> done. Open (animation + RL decision log): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open it manually: $e" end)
end

# =============================================================================
# surrogate -- VISUAL demo of the LEARNED SURROGATE WORLD MODEL deciding the OOD response
#   (visual counterpart of E1/E2). At each OOD event the surrogate SCORES every candidate DSL
#   macro in imagination (predicted `closed` nodes), ranks them, and enacts the argmax -- 0 true
#   planner calls. Uses the LINEAR export (surrogate_linear.json); errors on a forest export.
#   NOTE: this demo keeps its OWN MILP block (60s/0.05 gap/output_flag) -- different from the
#   shared _setup_milp!. ENV: DEMO_OOD (fault|zone), NSPARE, GRID_SCALE, OPEN_ANIM, SAVE_ANIM,
#   SEED, SEVERITY, SURROGATE.
# =============================================================================
function demo_surrogate()
_EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
# navigator.jl + decpomdp examples are now loaded ONCE at module top (world-age).

DEMO_OOD   = Symbol(get(ENV, "DEMO_OOD", "fault"))    # :fault | :zone
NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
SEED       = parse(Int, get(ENV, "SEED", "1"))
SEVERITY   = parse(Float64, get(ENV, "SEVERITY", "1.0"))   # zone: overlap frac; fault: 1.0
SURRO_PATH = get(ENV, "SURROGATE",
    joinpath(dirname(pkgdir(CB)), "wm4spacecraft_manufacturing", "surrogate_linear.json"))
MACROS = [0, 1, 2, 3, 4]
MACRO_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")

# NOTE: surrogate demos use a DIFFERENT MILP config than _setup_milp! (kept verbatim).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- the learned surrogate: y_hat = coef . ((x - mean)/scale) + intercept ----------------
SURRO = JSON3.read(read(SURRO_PATH, String))
# This (superseded) demo only knows the LINEAR export with the original 19 columns.
if get(SURRO, "kind", "linear") == "forest" || any(occursin("__x__", String(f)) for f in SURRO["feature_names"])
    error("""demo_surrogate is SUPERSEDED and cannot read this surrogate ($(SURRO["meta"]["model"])).
             Use the surrogate_stream demo, or export a linear one:
               python export_surrogate.py <dataset>.jsonl --cost-aware --linear""")
end
FEATNAMES = String.(SURRO["feature_names"])
println(">>> surrogate loaded: $(length(FEATNAMES)) features, trained on $(SURRO["meta"]["n_instances"]) " *
        "instances, LOO decision-regret=$(SURRO["meta"]["loo_decision_regret"])")

surrogate_predict(x::Vector{Float64}) = begin
    m = Float64.(SURRO["mean"]); s = Float64.(SURRO["scale"]); c = Float64.(SURRO["coef"])
    z = (x .- m) ./ ifelse.(s .== 0.0, 1.0, s)
    LinearAlgebra.dot(c, z) + Float64(SURRO["intercept"])
end

# count the agent's PENDING transport tasks (the consequence proxy the dataset used)
function agent_pending_tasks(env, agent)
    agent === nothing && return -1.0
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return Float64(n)
end

# Build the SAME 19-d feature row the surrogate was trained on (e1_analyze.featurize order).
function features(env, ctx, macro_id::Int)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    valid  = valid_actions(ctx)
    zrad = ctx.type === :zone ?
        (try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][ctx.zone])) catch; -1.0 end) : -1.0
    d = Dict{String,Float64}(
        "kind_fault"     => ctx.type === :fault   ? 1.0 : 0.0,
        "kind_battery"   => ctx.type === :battery ? 1.0 : 0.0,
        "kind_zone"      => 0.0,
        "kind_zoneblk"   => ctx.type === :zone    ? 1.0 : 0.0,
        "severity"       => SEVERITY,
        "n_spare_cfg"    => Float64(NSPARE),
        "spare_count"    => Float64(try length(CB.active_spares()) catch; 0 end),
        "progress"       => total > 0 ? closed / total : 0.0,
        "agent_pending"  => agent_pending_tasks(env, ctx.agent),
        "closed_at_fire" => Float64(closed),
        "n_active"       => Float64(length(env.cache.active_set)),
        "soc"            => ctx.type === :battery ? Float64(ctx.soc) : -1.0,
        "zone_radius"    => zrad,
        "macro_in_valid" => (macro_id in valid) ? 1.0 : 0.0,
    )
    for m in MACROS; d["macro_$(m)"] = (m == macro_id) ? 1.0 : 0.0; end
    return [d[f] for f in FEATNAMES]          # exact training column order
end

_PIPE = String[]
_say(s) = (push!(_PIPE, s); @info s)

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
function surrogate_producer(env, event)
    ctx = event_context(env, event)
    if !(ctx.type in (:fault, :battery, :zone))
        return action_to_proposal(ctx, canonical_action(ctx))     # reform etc: canonical background
    end
    scores = Dict(m => surrogate_predict(features(env, ctx, m)) for m in MACROS)
    best = argmax(m -> scores[m], MACROS)
    ranked = sort(MACROS, by = m -> -scores[m])
    _say("[SURROGATE] OOD=$(ctx.type) — imagined outcome (predicted closed nodes), NO planner call:")
    for m in ranked
        mark = m == best ? "  <= CHOSEN" : ""
        _say(@sprintf("           %-13s %7.1f%s", MACRO_NAME[m], scores[m], mark))
    end
    _say("[SURROGATE] enacting $(MACRO_NAME[best]) — decided in imagination (0 true-planner calls)")
    return action_to_proposal(ctx, best)
end

# ---- OOD injection: a robot breakdown, or a CONSEQUENTIAL blocking zone ------------------
function place_blocking_zone!(env; key::Symbol = :zoneblk, frac::Float64 = 0.9)
    isempty(env.staging_circles) && return nothing
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        z = CB.add_restriction_zone!(key, c, r * frac)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1];digits=2)), $(round(c[2];digits=2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

function schedule_ood!()
    fired = Ref(false)
    if DEMO_OOD === :zone
        act = e -> fired[] ? nothing :
            (nl = place_blocking_zone!(e; frac = SEVERITY); nl === nothing ? nothing : (fired[] = true; nl))
        for c in (8, 14, 20, 28); CB.schedule_ood_at_closed!(c, act); end
    else
        tf = CB.fault_action(; safe = true, obstacle = false, clear = true)
        act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))
        for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end
    end
end

_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln)
        counts[ln] = get(counts, ln, 0) + 1
    end
    rows = map(order) do ln
        c = occursin("SURROGATE] OOD", ln) ? "#ffd479" :
            occursin("CHOSEN", ln) || occursin("enacting", ln) ? "#7ee787" :
            occursin("[SURROGATE]", ln) ? "#c9d1d9" :
            (occursin("ADMITTED", ln) || occursin("replace", ln) || occursin("spare", ln) ||
             occursin("restage", ln)) ? "#79c0ff" :
            (occursin("declined", ln) || occursin("REJECTED", ln)) ? "#ff9b9b" : "#8b949e"
        n = counts[ln]; badge = n > 1 ? " <span style=\"opacity:.55\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end
    return "<div style=\"position:fixed;top:10px;left:10px;width:430px;max-height:52vh;overflow:auto;" *
        "background:rgba(16,18,26,.85);font:11px/1.45 ui-monospace,Consolas,monospace;border-radius:9px;" *
        "z-index:99999;white-space:pre-wrap;box-shadow:0 3px 16px rgba(0,0,0,.55)\">" *
        "<div onclick=\"var b=document.getElementById('surro-body');" *
        "b.style.display=(b.style.display=='none'?'block':'none');\" " *
        "style=\"color:#9bd1ff;font-weight:700;padding:8px 11px;cursor:pointer;position:sticky;top:0;" *
        "background:rgba(16,18,26,.96);border-radius:9px 9px 0 0;user-select:none\">" *
        "SURROGATE WORLD MODEL — decide in imagination, 0 planner calls " *
        "<span style=\"opacity:.55;font-weight:400\">— click to hide ▾</span></div>" *
        "<div id=\"surro-body\" style=\"padding:6px 11px 9px\">" * join(rows, "") * "</div></div>"
end

# ---- wire the seam: the SURROGATE is the producer ----------------------------------------
CB.RESPEC_ENABLED[] = true
for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
          :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
    try getproperty(CB, f)() catch end
end
try CB.set_reform_interval!(400) catch end
CB.set_respec_producer!(surrogate_producer)          # <-- the ONLY substantive difference vs the LLM/RL demos
schedule_ood!()

println(">>> VISUAL SURROGATE demo: OOD=$(DEMO_OOD) seed=$SEED spares=$(4*NSPARE) producer=LEARNED-SURROGATE")
println(">>> the surrogate ranks all 5 DSL macros in imagination and enacts the argmax — no planner call.")
println(">>> building + simulating with FULL NAV + SPARE POOLS + RESPEC SEAM + ANIMATION (slow)...")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "tractor", num_robots = 10, assignment_mode = :greedy,
        milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
        max_num_iters_no_progress = 30000, rvo_flag = true, tangent_bug_flag = true,
        dispersion_flag = true, n_spare_per_pool = NSPARE,
        save_animation = SAVE_ANIM, open_animation_at_end = false, update_anim_at_every_step = SAVE_ANIM,
        anim_active_agents = true, anim_active_areas = true, grid_scale = GRID_SCALE, log_sink = _PIPE,
        save_animation_along_the_way = false, write_results = false, overwrite_results = true,
        look_for_previous_milp_solution = false, save_milp_solution = false,
        return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
end

CB.RESPEC_ENABLED[] = false; CB.clear_respec_producer!()
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()

htmlpath = joinpath("results", "tractor", "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath) && !isempty(_PIPE)
    html = read(htmlpath, String)
    panel = _log_panel(_PIPE)
    html = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded $(length(_PIPE)) surrogate-decision log lines into the HTML.")
end
println(">>> done. Open (animation + surrogate reasoning in ONE file): $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed: $e" end)
end

# =============================================================================
# energy_adaptive -- ENERGY-AWARE ADAPTIVE REPLANNING (NO animation, metrics only). As
#   robots break down / batteries degrade / no-go zones appear at MULTIPLE random times, the
#   system re-plans at EACH event, minimizing battery-energy + handling-distance + makespan,
#   biased away from low-SoC robots. LLM mode if the service is up; else OFFLINE canonical
#   reassign. ENV: ENERGY_W, SEED, N_OOD, PROJECT.
# =============================================================================
function demo_energy_adaptive()
# ---- knobs (env-overridable) ------------------------------------------------
ENERGY_W = parse(Float64, get(ENV, "ENERGY_W", "1.0e-3"))   # efficiency weight (energy+distance) vs makespan
SEED     = parse(Int,     get(ENV, "SEED", "7"))
N_OOD    = parse(Int,     get(ENV, "N_OOD", "4"))           # number of random OOD events across the build
PROJECT  = parse(Int,     get(ENV, "PROJECT", "4"))         # 4 = tractor

# ---- load the navigator layer into the module scope (manual-include pattern) -
# navigator layer (metrics/ood_truth/battery/ood_stream) now loaded ONCE at module top (world-age).

# ---- solver for the re-solves (feasibility-first, quiet) ---------------------
_setup_milp!()

# ---- ENERGY-AWARE OBJECTIVE: every (re)solve minimizes makespan + w·(energy/dist) ----
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

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

    # Battery-health OOD: re-solve the remaining schedule with the SoC-biased objective.
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
end

# =============================================================================
# energy_adaptive_anim -- VISUAL (MeshCat) demo of the ENERGY-AWARE ADAPTIVE replanning
#   stack: per-robot SoC accounting + energy objective + multi-time OOD, with a live per-robot
#   battery HUD sidebar. Story: build starts -> a robot's BATTERY degrades -> DeprioritizeAgent
#   (soft) -> energy-aware re-solve -> central NO-GO ZONE -> ForbidZone -> whole-build translate.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_BATTERY, ZONE_CLOSED, ZONE_R, SEED, ENERGY_W, GRID_SCALE,
#        OPEN_ANIM, CAM_MAP, CAM_FOLLOW, SIDEBAR_W.
# =============================================================================
function demo_energy_adaptive_anim()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8733"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

# navigator layer (manual-include pattern) — battery + multi-OOD stream
# navigator layer now loaded ONCE at module top (world-age).

PROJECT     = parse(Int, get(ENV, "PROJECT", "4"))           # 4 = tractor
N_BATTERY   = parse(Int, get(ENV, "N_BATTERY", "2"))         # # of battery-degradation OOD
ZONE_CLOSED = parse(Int, get(ENV, "ZONE_CLOSED", "60"))      # closed-count to drop the central zone
ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))      # central zone radius (big -> whole-build move)
SEED        = parse(Int, get(ENV, "SEED", "7"))
ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
GRID_SCALE  = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM   = get(ENV, "OPEN_ANIM", "1") == "1"
CAM_MAP     = get(ENV, "CAM_MAP", "x0-y")                   # world (x,y)->cam target; DEFAULT x0-y

_setup_milp!()

# ENERGY-AWARE objective (every re-solve minimizes makespan + w·energy, biased off low-SoC robots).
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# camera-follow DISABLED by default. Set CAM_FOLLOW=1 to re-enable centre-on-active-agents.
CB.CAMERA_FOLLOW[] = get(ENV, "CAM_FOLLOW", "0") == "1"
CB.CAMERA_FOLLOW[] && CB.set_camera_follow_map!(
    CAM_MAP == "xy0"  ? ((x, y) -> (Float64(x), Float64(y), 0.0)) :
    CAM_MAP == "x0y"  ? ((x, y) -> (Float64(x), 0.0, Float64(y))) :
    CAM_MAP == "-x0y" ? ((x, y) -> (-Float64(x), 0.0, Float64(y))) :
    ((x, y) -> (Float64(x), 0.0, -Float64(y))))   # default "x0-y"

# --- deterministic mock /propose: battery->DeprioritizeAgent, zone->ForbidZone, fault->ReplaceAgent ---
_agent_for_rn(event, agents) = begin
    m = match(r"[Rr](\d+)", String(event))
    m === nothing && return (isempty(agents) ? "" : String(agents[1]["id"]))
    n = m.captures[1]
    for a in agents
        endswith(String(a["id"]), "($n)") && return String(a["id"])
    end
    isempty(agents) ? "" : String(agents[1]["id"])
end
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        path == "/health" && return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        path == "/propose" || return HTTP.Response(404, "not found")
        body   = JSON3.read(String(req.body))
        event  = String(get(body, "event", ""))
        ev     = lowercase(event)
        agents = get(body, "agents", []); zones = get(body, "zones", []); nodes = get(body, "nodes", [])
        cons =
            if occursin("battery", ev) || occursin("charge", ev) || occursin("degraded", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] battery -> DeprioritizeAgent(agent=$aid, factor=50)"
                [Dict("kind" => "DeprioritizeAgent", "agent" => aid, "factor" => 50.0)]
            elseif occursin("broken", ev) || occursin("immobile", ev) || occursin("cannot move", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] breakdown -> ReplaceAgent(agent=$aid)"
                [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)]
            elseif occursin("zone", ev) || occursin("exclusion", ev) || occursin("no-go", ev)
                zkey = isempty(zones) ? "zone" : String(zones[1]["key"])
                cov  = isempty(zones) ? [] : zones[1]["covers"]
                asm  = !isempty(cov) ? String(first(cov)) : (isempty(nodes) ? "" : String(nodes[1]["id"]))
                @info "[MOCK-LLM] zone -> ForbidZone(zone=$zkey, assembly=$asm)"
                [Dict("kind" => "ForbidZone", "zone" => zkey, "assembly" => asm)]
            else
                @info "[MOCK-LLM] no-op"
                []
            end
        return HTTP.Response(200, JSON3.write(Dict("constraints" => cons, "rationale" => "mock")))
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
# central no-go zone over the build core -> forces the WHOLE-build translate (the camera-follow case)
function central_zone_action!(env)
    gs = CB.root_deposit_goals(env)
    zc = isempty(gs) ? Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2]) : sum(gs) ./ length(gs)
    CB.add_restriction_zone!(:zone, zc, ZONE_R)
    @info "[DEMO] central no-go ZONE @ $(round.(zc; digits=2)) R=$ZONE_R -> expect whole-build relocation"
    return "A safety exclusion zone is now active over the central build area; robots must not enter or pass through it."
end

# --- OOD schedule -------------------------------------------------------------
SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI.
SOC_HISTORY = Vector{Dict{Any,Float64}}()

# step 1: turn the battery layer ON (needs env; the action receives it).
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params())
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # Wrap the accounting hook so every step also records a SoC snapshot for the live UI.
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)
        f = CB.BATTERY_FLEET[]
        f === nothing || push!(SOC_HISTORY, copy(f.soc))
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots), energy objective w=$ENERGY_W, camera-follow=$(CB.CAMERA_FOLLOW[])"
    return nothing   # no respec
end)
# a few BATTERY-degradation OODs (soft DeprioritizeAgent) spread over the early build
CB.schedule_random_ood!(; n = N_BATTERY, kinds = [:battery], closed_lo = 8,
    closed_hi = max(12, ZONE_CLOSED - 10), seed = SEED)
# one big CENTRAL ZONE mid-build -> whole-build translate -> camera follows
CB.schedule_ood_at_closed!(ZONE_CLOSED, central_zone_action!)

pp = CB.get_project_params(PROJECT)
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> ENERGY-ADAPTIVE visual demo: project=$(pp[:project_name])  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> battery OOD x$N_BATTERY (DeprioritizeAgent) + central zone @closed=$ZONE_CLOSED; /propose=$(ENV["RESPEC_SERVICE_URL"]) ready=$ready")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start uvicorn server:app --port 8000 in a shell WITH ANTHROPIC_API_KEY first."

_PIPE = String[]
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        save_animation=true, open_animation_at_end=false, update_anim_at_every_step=true,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end

# battery summary for the log panel
batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) spread=$(round(batt.soc_spread,digits=3)) total_energy_J=$(round(batt.total_energy_J,digits=1))")

# reset all globals so later runs are byte-for-byte normal
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.CAMERA_FOLLOW[] = false; CB.clear_agent_bias!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.0); CB.set_energy_model!()

# --- embed the NL->DSL->recovery + battery UI into the saved HTML -------------
SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# compact colored respec/recovery log rows (inner html only; the card wraps them)
function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(no respec events)</div>"
    rows = map(lines) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :
            (occursin("LLM proposal", ln) || occursin("MOCK-LLM", ln)) ? "#7ee787" :
            (occursin("BATTERY", ln) || occursin("deprioritize", ln)) ? "#f0a0ff" :
            (occursin("WHOLE-BUILD", ln) || occursin("admitted", ln) || occursin("relocation", ln)) ? "#79c0ff" :
            "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return join(rows, "")
end

# LIVE per-robot battery bars, ALIGNED BY ROBOT NUMBER (R1,R2,…,Rn).
function _battery_live(history; maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history)
    li === nothing && return ("", "")
    okeys = sort(collect(keys(history[li])); by = k -> (try Int(k.id) catch; 0 end))  # by robot number
    nums  = [ (try Int(k.id) catch; 0 end) for k in okeys ]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [ [ round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys ] for i in idxs ]
    bars = join(map(nums) do rn
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
            "<span style=\"width:30px;color:#cdd6e0\">R$rn</span>" *
            "<div style=\"flex:1;height:11px;background:#20242e;border-radius:5px;overflow:hidden\">" *
                "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
            "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length;
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      // Read the animation playhead: max action time (tracks PLAY and SCRUB), duration from the clip.
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var acts = an.actions||[], t=0, d=an.duration||0;
        for(var i=0;i<acts.length;i++){ t=Math.max(t, acts[i].time||0);
          if(acts[i]._clip){ d=Math.max(d, acts[i]._clip.duration||0); } }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s)));
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=col(s); }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=col(s); } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>
    """
    return (bars, script)
end

# left sidebar wrapper: shrinks #meshcat-pane and docks the two cards beside it (no overlap).
function _sidebar(log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 Battery SoC — per robot" *
        " <span style=\"color:#8891a5;font-weight:400\">(live · red ≤25% · orange ≤50%)</span></div>" *
        batt_html * "</div>"
    log_card =
        "<div class=\"cb-card\"><div class=\"cb-title\">ENERGY-ADAPTIVE respec" *
        " <span style=\"color:#8891a5;font-weight:400\">(OOD → DSL → re-solve)</span></div>" *
        "<div class=\"cb-log\">$log_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-log { max-height:56vh; overflow:auto; white-space:pre-wrap; }
    </style>
    <div id="cb-sidebar">$batt_card$log_card</div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script
    """
end

htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath)
    html  = read(htmlpath, String)
    bars, bscript = _battery_live(SOC_HISTORY)
    panel = _sidebar(_log_rows(_PIPE), bars, bscript)
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded sidebar (LIVE per-robot battery over $(length(SOC_HISTORY)) frames + $(length(_PIPE))-line respec log).")
end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open manually: $e" end)
end

# =============================================================================
# energy_stall_replace -- VISUAL demo of the CLOSED battery loop: motion drains SoC ->
#   a robot hits 0% and STALLS -> raises a breakdown OOD -> LLM (mock) re-specs ReplaceAgent ->
#   the NEAREST spare depot dispatches a fresh robot that adopts the dead robot's chain.
#   ENV: USE_MOCK, MOCK_PORT, PROJECT, N_SPARE, SHRINK, STALL_SOC, ENERGY_W, SEED, GRID_SCALE,
#        OPEN_ANIM, FAST, SPARE_MARGIN, REFORM_INTERVAL, HOT_SWAP, STALL_CLEAR, DISCHARGE_AT, SIDEBAR_W.
# =============================================================================
function demo_energy_stall_replace()
USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8744"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

# navigator layer (manual-include pattern) — battery accounting + stall coupling
# navigator layer now loaded ONCE at module top (world-age).

PROJECT    = parse(Int, get(ENV, "PROJECT", "4"))          # 4 = tractor
N_SPARE    = parse(Int, get(ENV, "N_SPARE", "2"))          # spares per depot (x4 dirs)
SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))   # battery capacity /SHRINK
STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.02")) # SoC at/below which a robot dies
ENERGY_W   = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
SEED       = parse(Int, get(ENV, "SEED", "7"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
FAST       = get(ENV, "FAST", "0") == "1"   # tuning: skip per-step anim frames (much faster, coarse video)
SPARE_MARGIN = parse(Float64, get(ENV, "SPARE_MARGIN", "18.0"))  # depot distance outside build
CB.set_spare_pool_margin!(SPARE_MARGIN)           # park the depots FAR from the build (visible re-emergence)
# ADAPTIVITY: react to a post-swap team wedge in ~a second, not the old ~50 s.
REFORM_INTERVAL = parse(Int, get(ENV, "REFORM_INTERVAL", "300"))
CB.set_reform_interval!(REFORM_INTERVAL)

_setup_milp!()

# ENERGY-AWARE objective so replans still prefer healthy robots (soft), on top of the hard stall.
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# --- deterministic mock /propose: breakdown/stall -> ReplaceAgent (nearest spare hand-off) ---
_agent_for_rn(event, agents) = begin
    m = match(r"[Rr](\d+)", String(event))
    m === nothing && return (isempty(agents) ? "" : String(agents[1]["id"]))
    n = m.captures[1]
    for a in agents
        endswith(String(a["id"]), "($n)") && return String(a["id"])
    end
    isempty(agents) ? "" : String(agents[1]["id"])
end
function start_mock(port)
    handler = function (req::HTTP.Request)
        path = HTTP.URIs.URI(req.target).path
        path == "/health" && return HTTP.Response(200, JSON3.write(Dict("status" => "ok")))
        path == "/propose" || return HTTP.Response(404, "not found")
        body   = JSON3.read(String(req.body))
        event  = String(get(body, "event", ""))
        ev     = lowercase(event)
        agents = get(body, "agents", [])
        cons =
            if occursin("broken", ev) || occursin("immobile", ev) || occursin("cannot move", ev)
                aid = _agent_for_rn(event, agents)                       # battery breakdown (checked FIRST)
                @info "[MOCK-LLM] battery-stall -> ReplaceAgent(agent=$aid)"
                [Dict("kind" => "ReplaceAgent", "agent" => aid, "after" => 0.0)]
            elseif occursin("deadlock", ev) || occursin("stuck", ev) || occursin("stall", ev) ||
                   occursin("cannot complete", ev) || occursin("re-establish", ev) || occursin("reform", ev)
                @info "[MOCK-LLM] team deadlock -> ReformTeam()"    # auto-emitted no-progress event
                [Dict("kind" => "ReformTeam")]                     # -> recover_stalled_teams! (un-wedges the build)
            elseif occursin("degraded", ev) || occursin("charge", ev)
                aid = _agent_for_rn(event, agents)
                @info "[MOCK-LLM] battery-degraded -> DeprioritizeAgent(agent=$aid, factor=50)"
                [Dict("kind" => "DeprioritizeAgent", "agent" => aid, "factor" => 50.0)]
            else
                @info "[MOCK-LLM] no-op"
                []
            end
        return HTTP.Response(200, JSON3.write(Dict("constraints" => cons, "rationale" => "mock")))
    end
    return HTTP.serve!(handler, "127.0.0.1", port)
end

# --- OOD schedule: NONE. Stalls emerge from motion drain. We only turn the battery+stall
#     layer ON at step 1 (needs env). Spare depots are injected by run_lego_demo (n_spare>0). --
SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()
CB.clear_faulted_robots!(); CB.clear_recovery_spares!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI.
SOC_HISTORY = Vector{Dict{Any,Float64}}()

CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # clear=true tows the dead robot off-grid so the spare takes over cleanly and the build completes.
    hot = get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_battery_stall!(enabled = true, threshold = STALL_SOC,
        clear = hot ? false : (get(ENV, "STALL_CLEAR", "1") == "1"),
        obstacle = get(ENV, "STALL_OBSTACLE", "0") == "1")   # <-- the new coupling
    if hot
        CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
        @info "[DEMO] identity-preserving HOT-SWAP repository replacement ON (mode=$(CB.HOT_SWAP_MODE[]))"
    end
    # Wrap the accounting hook (which also runs the stall trigger) so every step records a SoC snapshot.
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)
        f = CB.BATTERY_FLEET[]
        f === nothing || push!(SOC_HISTORY, copy(f.soc))
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots incl spares), " *
          "stall<=$(STALL_SOC), energy w=$ENERGY_W, spares=$(4*N_SPARE) at N/S/E/W depots"
    return nothing   # no respec here
end)

# Deterministic "run flat mid-haul": at chosen build-progress points, drain an ACTIVE transport robot to empty.
function _pick_active_worker(env)
    spares = Set(CB.active_spares())
    sched  = env.sched
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        (rid === nothing || rid in spares) && continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # has a task to return to
        return rid
    end
    for v in env.cache.active_set                                        # fallback: a non-spare carrier
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.TransportUnitGo || continue
        for rid in keys(CB.robot_team(n))
            rid in spares || return rid
        end
    end
    return nothing
end

function deep_discharge_active!(env)
    fleet = CB.BATTERY_FLEET[]; fleet === nothing && return nothing
    id = _pick_active_worker(env)            # a real working robot (never a parked spare)
    (id === nothing || !haskey(fleet.soc, id)) && return nothing
    fleet.soc[id] = 0.0                        # run flat mid-haul
    @info "[DEMO] deep-discharge R$(id.id) mid-haul (SoC->0) -> expect stall + spare replace"
    return nothing                             # the battery stall trigger raises the OOD itself
end
DISCHARGE_AT = [parse(Int, strip(x)) for x in split(get(ENV, "DISCHARGE_AT", "60"), ",") if strip(x) != ""]
for k in DISCHARGE_AT
    CB.schedule_ood_at_closed!(k, deep_discharge_active!)
end

pp = CB.get_project_params(PROJECT)
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> ENERGY-STALL-REPLACE demo: project=$(pp[:project_name])  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> spares=$(4*N_SPARE) (N/S/E/W depots), battery shrink=$SHRINK, stall<=$STALL_SOC; /propose=$(ENV["RESPEC_SERVICE_URL"]) ready=$ready")

_PIPE = String[]
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=parse(Int, get(ENV, "NOPROG", "10000")), # must exceed the 2000-step
                                                                           # reform interval so the auto-
                                                                           # emitted ReformTeam recovery
                                                                           # fires and un-wedges the build
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=N_SPARE,                        # <-- VISIBLE spare depots at grid sides
        save_animation=!FAST, open_animation_at_end=false, update_anim_at_every_step=!FAST,
        anim_active_agents=true, anim_active_areas=true, grid_scale=GRID_SCALE, log_sink=_PIPE,
        save_animation_along_the_way=false, write_results=false, overwrite_results=true,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=false)
end

# battery summary
batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) " *
    "n_depleted=$(batt.n_depleted) total_energy_J=$(round(batt.total_energy_J,digits=1))")
push!(_PIPE, "[STALL] robots stalled+replaced this run: $(length(CB.stalled_robots()))")

# reset all globals so later runs are byte-for-byte normal
try close(SRV) catch end
CB.RESPEC_ENABLED[] = false; CB.clear_ood_schedule!(); CB.clear_restriction_zones!()
CB.clear_agent_bias!(); CB.clear_faulted_robots!(); CB.clear_recovery_spares!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.SOC_SPEED_HOOK[] = nothing; CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()
CB.set_planning_objective_weights!(speed = 1.0, efficiency = 0.0); CB.set_energy_model!()

# --- embed the LIVE battery HUD + stall/replace log into the saved HTML -------
SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# compact colored stall/replace/respec log rows (inner html; the card wraps them)
function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(no respec events)</div>"
    rows = map(lines) do ln
        c = occursin("OOD event:", ln) ? "#ffd479" :
            (occursin("MOCK-LLM", ln) || occursin("LLM proposal", ln)) ? "#7ee787" :
            occursin("STALL", ln) ? "#ff7b72" :
            (occursin("REPLACE", ln) || occursin("spare", ln) || occursin("ADMITTED", ln) || occursin("took over", ln)) ? "#79c0ff" :
            occursin("BATTERY", ln) ? "#f0a0ff" : "#d8e0ee"
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))</div>"
    end
    return join(rows, "")
end

# LIVE per-robot battery bars aligned by robot number (R1..Rn), driven from the SoC-per-frame history.
function _battery_live(history, swapped = Set{Int}(); maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history); li === nothing && return ("", "")
    okeys = sort(collect(keys(history[li])); by = k -> (try Int(k.id) catch; 0 end))
    nums  = [ (try Int(k.id) catch; 0 end) for k in okeys ]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [ [ round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys ] for i in idxs ]
    bars = join(map(nums) do rn
        sw = rn in swapped                                   # this worker was hot-swapped from a depot
        tag = sw ? " <span style=\"color:#58a6ff\">&#8646;</span>" : ""   # ⇄ badge
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
            "<span style=\"width:44px;color:#cdd6e0\">R$rn$tag</span>" *
            "<div style=\"flex:1;height:11px;background:#20242e;border-radius:5px;overflow:hidden\">" *
                "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
            "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat, "swap" => collect(swapped)))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length, SW = D.swap||[];
      function isSwap(rn){ return SW.indexOf(rn) >= 0; }
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var acts = an.actions||[], t=0, d=an.duration||0;
        for(var i=0;i<acts.length;i++){ t=Math.max(t, acts[i].time||0);
          if(acts[i]._clip){ d=Math.max(d, acts[i]._clip.duration||0); } }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s)));
          var c = isSwap(R[k]) ? '#58a6ff' : col(s);      // hot-swapped worker -> blue (distinct from SoC colors)
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=c; }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=c; } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>
    """
    return (bars, script)
end

# left sidebar wrapper: shrinks #meshcat-pane and docks the two cards beside it (no overlap).
function _sidebar(log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 Battery SoC — per robot" *
        " <span style=\"color:#8891a5;font-weight:400\">(live · red ≤25% · orange ≤50% · <span style=\"color:#58a6ff\">blue &#8646; = hot-swapped</span> · spares stay full)</span></div>" *
        batt_html * "</div>"
    log_card =
        "<div class=\"cb-card\"><div class=\"cb-title\">BATTERY STALL → SPARE REPLACE" *
        " <span style=\"color:#8891a5;font-weight:400\">(SoC=0 → OOD → DSL ReplaceAgent → depot spare)</span></div>" *
        "<div class=\"cb-log\">$log_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-log { max-height:56vh; overflow:auto; white-space:pre-wrap; }
    </style>
    <div id="cb-sidebar">$batt_card$log_card</div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script
    """
end

htmlpath = joinpath("results", pp[:project_name], "greedy_RVO_Dispersion_TangentBug", "visualization.html")
if isfile(htmlpath)
    html  = read(htmlpath, String)
    swapped_ids = Set{Int}(try Int(k.id) catch; 0 end for k in keys(CB.decommissioned_bodies()))
    bars, bscript = _battery_live(SOC_HISTORY, swapped_ids)
    panel = _sidebar(_log_rows(_PIPE), bars, bscript)
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> embedded sidebar (LIVE per-robot battery over $(length(SOC_HISTORY)) frames + $(length(_PIPE))-line stall/replace log).")
end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed; open manually: $e" end)
end

# =============================================================================
# surrogate_stream -- the LEARNED SURROGATE WORLD MODEL adapting to a STREAM of DIFFERENT
#   OOD events (fault / battery / zone) at random build-progress points, with a live battery-SoC
#   HUD in a docked sidebar. At EVERY event the surrogate predicts the re-plan outcome for all 5
#   DSL macros in imagination (0 true-planner calls), ranks, and enacts the argmax.
#   NOTE: keeps its OWN MILP block (60s/0.05 gap/output_flag). ENV: OOD_N, OOD_KINDS, OOD_SEED,
#   NSPARE, SEED, GRID_SCALE, SHRINK, STALL_SOC, OPEN_ANIM, SAVE_ANIM, SIDEBAR_W, NOPROG,
#   CARRIER_RESCUE, HOT_SWAP, REFORM_INTERVAL, SURROGATE.
# =============================================================================
function demo_surrogate_stream()
_EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
# navigator.jl + decpomdp examples are now loaded ONCE at module top (world-age).

OOD_N      = parse(Int, get(ENV, "OOD_N", "4"))
OOD_KINDS  = [Symbol(strip(s)) for s in split(get(ENV, "OOD_KINDS", "fault,battery,zone"), ",")]
OOD_SEED   = parse(Int, get(ENV, "OOD_SEED", "3"))
NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
SEED       = parse(Int, get(ENV, "SEED", "1"))
GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
# MUST match the oracle data-gen's battery physics (DS_SHRINK / DS_STALL).
SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))    # == DS_SHRINK
STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.15"))  # == DS_STALL
OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
SIDEBAR_W  = parse(Int, get(ENV, "SIDEBAR_W", "380"))
NOPROG     = parse(Int, get(ENV, "NOPROG", "6000"))   # no-progress cap
RESCUE     = get(ENV, "CARRIER_RESCUE", "0") == "1"   # see force_advance_stuck_carrier!

# Pin the project name so the animation and the injected panels land in the same results/ folder.
PROJECT    = "tractor"
HTMLPATH   = joinpath("results", PROJECT, "greedy_RVO_Dispersion_TangentBug", "visualization.html")
SURRO_PATH = get(ENV, "SURROGATE",
    joinpath(dirname(pkgdir(CB)), "wm4spacecraft_manufacturing", "surrogate_linear.json"))
MACROS = [0, 1, 2, 3, 4]
MACRO_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")

# NOTE: surrogate demos use a DIFFERENT MILP config than _setup_milp! (kept verbatim).
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- the learned surrogate: y_hat = coef . ((x - mean)/scale) + intercept ----------------
SURRO = JSON3.read(read(SURRO_PATH, String))
FEATNAMES = String.(SURRO["feature_names"])
IS_FOREST = get(SURRO, "kind", "linear") == "forest"
println(">>> surrogate: $(IS_FOREST ? "RandomForest ($(length(SURRO["trees"])) trees)" : "Ridge"), " *
        "$(length(FEATNAMES)) features, $(SURRO["meta"]["n_instances"]) instances, " *
        "LOO decision-regret=$(round(Float64(SURRO["meta"]["loo_decision_regret"]); digits=3))")
haskey(SURRO["meta"], "kinds") && println(">>> trained on OOD kinds: $(SURRO["meta"]["kinds"])")

# A FOREST, not a line. The graded task flips the correct macro at a THRESHOLD.
function _tree_predict(t, x::Vector{Float64})
    left = t["left"]; right = t["right"]; feat = t["feature"]; thr = t["threshold"]; val = t["value"]
    i = 1                                              # Julia is 1-based; sklearn's arrays are 0-based
    while feat[i] >= 0
        i = x[feat[i] + 1] <= thr[i] ? left[i] + 1 : right[i] + 1
    end
    return Float64(val[i])
end

function surrogate_predict(x::Vector{Float64})
    if IS_FOREST
        trees = SURRO["trees"]
        return sum(_tree_predict(t, x) for t in trees) / length(trees)
    end
    m = Float64.(SURRO["mean"]); s = Float64.(SURRO["scale"]); c = Float64.(SURRO["coef"])
    return LinearAlgebra.dot(c, (x .- m) ./ ifelse.(s .== 0.0, 1.0, s)) + Float64(SURRO["intercept"])
end

function agent_pending_tasks(env, agent)                # consequence proxy used by the dataset
    agent === nothing && return -1.0
    sched = env.sched; n = 0
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (node isa CB.RobotGo && CB.bound_to_agent(node, agent)) || continue
        v in env.cache.closed_set && continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1])) isa CB.FormTransportUnit || continue
        n += 1
    end
    return Float64(n)
end

# severity of the event currently being handled (set by the injector)
CUR_SEV = Ref(1.0)

# Fraction of a PENDING staging circle the zone actually covers — the physical severity of a zone event.
function zone_overlap_frac(env, zkey)
    z = try CB.RESTRICTION_ZONES[][zkey] catch; nothing end
    z === nothing && return -1.0
    zc = Vector{Float64}(CB.get_center(z)[1:2]); zr = Float64(CB.get_radius(z))
    best = 0.0
    for (aid, ball) in env.staging_circles
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        (v === nothing || v in env.cache.closed_set) && continue
        bc = Vector{Float64}(CB.get_center(ball)[1:2]); br = Float64(CB.get_radius(ball))
        d = sqrt(sum((bc .- zc) .^ 2)); d >= br + zr && continue
        area = d <= abs(br - zr) ? π * min(br, zr)^2 : begin
            a1 = acos(clamp((d^2 + zr^2 - br^2) / (2d * zr), -1.0, 1.0))
            a2 = acos(clamp((d^2 + br^2 - zr^2) / (2d * br), -1.0, 1.0))
            zr^2 * (a1 - sin(2a1) / 2) + br^2 * (a2 - sin(2a2) / 2)
        end
        best = max(best, area / (π * br^2))
    end
    return best
end

function features(env, ctx, macro_id::Int)
    closed = length(env.cache.closed_set)
    total  = length(CB.get_nodes(env.sched))
    valid  = valid_actions(ctx)
    zrad = ctx.type === :zone ?
        (try Float64(CB.get_radius(CB.RESTRICTION_ZONES[][ctx.zone])) catch; -1.0 end) : -1.0
    zovl = ctx.type === :zone ? (try zone_overlap_frac(env, ctx.zone) catch; -1.0 end) : -1.0
    soc  = ctx.type === :battery ? Float64(ctx.soc) : -1.0
    d = Dict{String,Float64}(
        "kind_fault"     => ctx.type === :fault   ? 1.0 : 0.0,
        "kind_battery"   => ctx.type === :battery ? 1.0 : 0.0,
        "kind_zone"      => 0.0,
        "kind_zoneblk"   => ctx.type === :zone    ? 1.0 : 0.0,
        "severity"       => CUR_SEV[],      # nominal, exactly as the dataset records it per kind
        "n_spare_cfg"    => Float64(NSPARE),
        "spare_count"    => Float64(try length(CB.active_spares()) catch; 0 end),
        "progress"       => total > 0 ? closed / total : 0.0,
        "agent_pending"  => agent_pending_tasks(env, ctx.agent),
        "closed_at_fire" => Float64(closed),
        "n_active"       => Float64(length(env.cache.active_set)),
        "soc"            => soc,
        "zone_radius"    => zrad,
        "zone_overlap"   => zovl,
        "macro_in_valid" => (macro_id in valid) ? 1.0 : 0.0,
    )
    for m in MACROS; d["macro_$(m)"] = (m == macro_id) ? 1.0 : 0.0; end
    # interaction terms `<state>__x__macro_<m>` (export_surrogate.py::add_interactions).
    return [get_feature(d, f) for f in FEATNAMES]
end

function get_feature(d::Dict{String,Float64}, name::AbstractString)
    haskey(d, name) && return d[name]
    parts = split(name, "__x__")
    length(parts) == 2 && haskey(d, parts[1]) && haskey(d, parts[2]) &&
        return d[parts[1]] * d[parts[2]]
    error("surrogate wants feature '$name' but the demo cannot build it")
end

_PIPE = String[]                 # engine + surrogate log (sidebar card 2)
_TIMELINE = String[]             # one row per OOD event (sidebar card 1)
# (robot, post-drop SoC, HUD frame index) for each battery OOD, so the HUD can HOLD the critical bar.
BATT_CRIT = Vector{Tuple{Any,Float64,Int}}()
_say(s) = (push!(_PIPE, s); @info s)

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
_EVENT_NO = Ref(0)
function surrogate_producer(env, event)
    ctx = event_context(env, event)
    if !(ctx.type in (:fault, :battery, :zone))
        return action_to_proposal(ctx, canonical_action(ctx))     # background (:reform): canonical
    end
    _EVENT_NO[] += 1
    k = _EVENT_NO[]; closed = length(env.cache.closed_set)
    scores = Dict(m => surrogate_predict(features(env, ctx, m)) for m in MACROS)
    best   = argmax(m -> scores[m], MACROS)
    ranked = sort(MACROS, by = m -> -scores[m])
    detail = ctx.type === :battery ? @sprintf("SoC=%.2f", Float64(ctx.soc)) :
             ctx.type === :zone    ? "no-go zone" : "robot down"
    _say("[OOD #$k] @closed=$closed  kind=$(uppercase(String(ctx.type)))  ($detail)")
    _say("[SURROGATE] imagined outcome (predicted closed nodes) — NO planner call:")
    for m in ranked
        _say(@sprintf("           %-13s %7.1f%s", MACRO_NAME[m], scores[m], m == best ? "   <= CHOSEN" : ""))
    end
    _say("[SURROGATE] enacting $(MACRO_NAME[best])  (0 true-planner calls)")
    push!(_TIMELINE, @sprintf("#%d  closed=%-3d  %-8s %-12s  →  %s", k, closed,
          uppercase(String(ctx.type)), detail, MACRO_NAME[best]))
    return action_to_proposal(ctx, best)
end

# ---- OOD STREAM: several events of DIFFERENT kinds at random build-progress points --------
function place_blocking_zone!(env; key::Symbol, frac::Float64 = 0.9)
    isempty(env.staging_circles) && return nothing
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    for (aid, ball) in env.staging_circles
        aid == root && continue
        ac = try CB._assembly_complete_node(env, aid) catch; nothing end
        ac === nothing && continue
        v = try CB.get_vtx(env.sched, CB.node_id(ac)) catch; nothing end
        v === nothing && continue
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        c = Vector{Float64}(CB.get_center(ball)[1:2]); r = Float64(CB.get_radius(ball))
        z = CB.add_restriction_zone!(key, c, r * frac)
        nl = "A no-go exclusion zone has appeared at ($(round(c[1];digits=2)), $(round(c[2];digits=2))) " *
             "blocking a staging area; restage the affected assembly out of the restricted region."
        try CB.record_ood_truth!(nl, CB.ZoneTruth(key, Float64[c[1], c[2]], Float64(CB.get_radius(z)), aid)) catch end
        return nl
    end
    return nothing
end

# evenly spaced progress points with jitter (same idea as navigator/ood_stream.jl)
function stream_points(n, lo, hi, rng)
    n <= 0 && return Int[]
    span = max(hi - lo, 1)
    sort([clamp(lo + round(Int, span * (i - 0.5) / n) +
                round(Int, (2rand(rng) - 1) * span / (2n)), lo, hi) for i in 1:n])
end

# n kinds drawn WITHOUT replacement (cycling the list if n > #kinds), then shuffled.
function shuffle_kinds(rng, kinds, n)
    bag = Symbol[]
    while length(bag) < n
        append!(bag, Random.shuffle(rng, collect(kinds)))
    end
    return bag[1:n]
end

function schedule_stream!()
    rng  = Random.MersenneTwister(OOD_SEED)
    # Spread the events across the WHOLE build (it closes ~291 nodes).
    pts  = stream_points(OOD_N, 20, 190, rng)
    # Draw kinds WITHOUT replacement so a 4-event stream really is 4 DIFFERENT disruptions.
    bag  = shuffle_kinds(rng, OOD_KINDS, OOD_N)
    zct  = Ref(0)
    plan = String[]
    for (i, p) in enumerate(pts)
        kind = bag[i]
        act = if kind === :fault
            # clear=false: keep the faulted robot's scene node so ReplaceAgent can hot-swap it.
            tf = CB.fault_action(; safe = true, obstacle = false, clear = false)
            e -> (CUR_SEV[] = 1.0; tf(e))
        elseif kind === :battery
            # the SEVERITY LADDER measured by the oracle (GRADED_OOD_DESIGN.md §2.1).
            soc  = [0.05, 0.20, 0.55][rand(rng, 1:3)]
            drop = 1.0 - soc
            bf = CB.battery_action(soc_drop = drop)
            e -> begin
                CUR_SEV[] = soc
                f = CB.BATTERY_FLEET[]
                before = f === nothing ? Dict{Any,Float64}() : copy(f.soc)
                nl = bf(e)                                   # drops a robot's SoC (may then be hot-swapped -> reset to 1.0)
                f2 = CB.BATTERY_FLEET[]
                if f2 !== nothing
                    dropped = [id for (id, s) in f2.soc if get(before, id, s) - s > 0.05]
                    if !isempty(dropped)
                        rid = argmax(id -> get(before, id, 0.0) - f2.soc[id], dropped)
                        push!(BATT_CRIT, (rid, f2.soc[rid], length(SOC_HISTORY)))  # for the HUD critical-hold
                    end
                end
                nl
            end
        else
            zct[] += 1; key = Symbol("zone_stream_$(zct[])")
            e -> (CUR_SEV[] = 0.9; place_blocking_zone!(e; key = key, frac = 0.9))
        end
        fired = Ref(false)
        CB.schedule_ood_at_closed!(p, e -> begin                 # one-shot, retried at later checks
            fired[] && return nothing
            nl = act(e)
            (nl === nothing || isempty(nl)) && return nothing
            fired[] = true; return nl
        end)
        push!(plan, "$(kind)@$(p)")
    end
    println(">>> OOD STREAM (seed=$OOD_SEED): " * join(plan, "  "))
    return plan
end

# ---- wire the seam + the battery layer ----------------------------------------------------
CB.RESPEC_ENABLED[] = true
for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
          :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!,
          :clear_agent_bias!)
    try getproperty(CB, f)() catch end
end
try CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))) catch end
# HOT_SWAP=1 (default): enact a fault-event Replace as an identity-preserving depot hot-swap.
if get(ENV, "HOT_SWAP", "1") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
    println(">>> HOT_SWAP ON: fault Replace -> identity-preserving depot swap (no re-stamp, completes).")
else
    CB.set_hot_swap!(enabled = false)
end
CB.set_respec_producer!(surrogate_producer)

# per-step SoC snapshots -> the live, playhead-synced battery HUD
SOC_HISTORY = Vector{Dict{Any,Float64}}()
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
    CB.set_battery_stall!(enabled = true, threshold = STALL_SOC, clear = true, obstacle = false)
    CB.BATTERY_STEP_HOOK[] = function (e, prev)
        CB.account_battery_step!(e, prev)
        f = CB.BATTERY_FLEET[]; f === nothing || push!(SOC_HISTORY, copy(f.soc))
        return nothing
    end
    @info "[DEMO] battery ON ($(length(CB.BATTERY_FLEET[].soc)) robots incl spares), stall<=$STALL_SOC"
    return nothing
end)
schedule_stream!()

# Remove any previous render (so a failed run leaves NO stale html).
isfile(HTMLPATH) && (rm(HTMLPATH); println(">>> removed stale $(HTMLPATH)"))

println(">>> SURROGATE + OOD-STREAM demo: $(OOD_N) events from $(OOD_KINDS), spares=$(4*NSPARE)")
println(">>> the surrogate ranks all 5 DSL macros in imagination at EVERY event — no planner call.")

run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = PROJECT, num_robots = 10, assignment_mode = :greedy,
        milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Info,
        max_num_iters_no_progress = NOPROG, rvo_flag = true, tangent_bug_flag = true,
        dispersion_flag = true, n_spare_per_pool = NSPARE,
        save_animation = SAVE_ANIM, open_animation_at_end = false, update_anim_at_every_step = SAVE_ANIM,
        anim_active_agents = true, anim_active_areas = true, grid_scale = GRID_SCALE, log_sink = _PIPE,
        save_animation_along_the_way = false, write_results = false, overwrite_results = true,
        look_for_previous_milp_solution = false, save_milp_solution = false,
        return_env_before_sim = false, rng = Random.MersenneTwister(SEED))
end

batt = CB.BATTERY_FLEET[] === nothing ? nothing : CB.battery_report()
batt === nothing || push!(_PIPE, "[BATTERY] min_soc=$(round(batt.min_soc,digits=3)) n_depleted=$(batt.n_depleted)")
push!(_PIPE, "[STALL] robots stalled this run: $(length(CB.stalled_robots()))")

# Prove the SoC series actually MOVES before we ship bars that claim to show it.
if !isempty(SOC_HISTORY)
    lastf = SOC_HISTORY[findlast(!isempty, SOC_HISTORY)]
    firstf = SOC_HISTORY[findfirst(!isempty, SOC_HISTORY)]
    drops = [(k, get(firstf, k, 1.0) - v) for (k, v) in lastf]
    sort!(drops; by = x -> -x[2])
    println(">>> SoC over $(length(SOC_HISTORY)) frames: final min=$(round(minimum(values(lastf)); digits=3)) " *
            "max=$(round(maximum(values(lastf)); digits=3)); biggest drains: " *
            join(["R$(try Int(k.id) catch; 0 end) -$(round(d; digits=2))" for (k, d) in drops[1:min(4, end)]], ", "))
end

CB.RESPEC_ENABLED[] = false; CB.clear_respec_producer!()
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.BATTERY_ACCOUNTING[] = false; CB.BATTERY_STEP_HOOK[] = nothing; CB.EDGE_COST_MULTIPLIER[] = nothing
CB.SOC_SPEED_HOOK[] = nothing; CB.set_battery_stall!(enabled = false); CB.clear_stalled_robots!()

# ================= sidebar (docked, does NOT overlap the 3D scene) =========================
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

function _timeline_rows(rows)
    isempty(rows) && return "<div style=\"color:#8891a5\">(no OOD events fired)</div>"
    join(map(rows) do ln
        c = occursin("FAULT", ln) ? "#ff9b9b" : occursin("BATTERY", ln) ? "#f0a0ff" :
            occursin("ZONE", ln) ? "#ffd479" : "#d8e0ee"
        "<div style=\"color:$c;margin:3px 0\">$(_esc(ln))</div>"
    end, "")
end

function _log_rows(lines)
    isempty(lines) && return "<div style=\"color:#8891a5\">(empty)</div>"
    order = String[]; counts = Dict{String,Int}()
    for ln in lines
        haskey(counts, ln) || push!(order, ln); counts[ln] = get(counts, ln, 0) + 1
    end
    join(map(order) do ln
        c = occursin("[OOD #", ln) ? "#ffd479" :
            occursin("CHOSEN", ln) || occursin("enacting", ln) ? "#7ee787" :
            occursin("[SURROGATE]", ln) ? "#c9d1d9" :
            occursin("STALL", ln) ? "#ff7b72" :
            (occursin("ADMITTED", ln) || occursin("spare", ln) || occursin("restage", ln) ||
             occursin("replace", ln)) ? "#79c0ff" :
            occursin("BATTERY", ln) ? "#f0a0ff" :
            (occursin("declined", ln) || occursin("REJECTED", ln)) ? "#ff9b9b" : "#8b949e"
        n = counts[ln]; badge = n > 1 ? " <span style=\"opacity:.5\">×$n</span>" : ""
        "<div style=\"color:$c;margin:2px 0\">$(_esc(ln))$badge</div>"
    end, "")
end

# LIVE per-robot SoC bars, interpolated against the MeshCat playhead (one history entry per frame)
function _battery_live(history; maxpts::Int = 500)
    isempty(history) && return ("", "")
    li = findlast(!isempty, history); li === nothing && return ("", "")
    # Order: any robot that hits a CRITICAL low (<=0.25) anywhere in the run is listed FIRST.
    minsoc = Dict{Any,Float64}()
    for k in keys(history[li])
        minsoc[k] = minimum((get(h, k, 1.0) for h in history if !isempty(h)); init = 1.0)
    end
    okeys = sort(collect(keys(history[li]));
                 by = k -> ((get(minsoc, k, 1.0) <= 0.25 ? 0 : 1), (try Int(k.id) catch; 0 end)))
    nums  = [(try Int(k.id) catch; 0 end) for k in okeys]
    n = length(history)
    idxs = n <= maxpts ? collect(1:n) : unique(round.(Int, range(1, n; length = maxpts)))
    mat  = [[round(Float64(get(history[i], k, NaN)); digits = 3) for k in okeys] for i in idxs]
    bars = join(map(nums) do rn
        "<div style=\"display:flex;align-items:center;gap:6px;margin:3px 0\">" *
        "<span style=\"width:40px;color:#cdd6e0\">R$rn</span>" *
        "<div style=\"flex:1;height:10px;background:#20242e;border-radius:5px;overflow:hidden\">" *
        "<div id=\"bat-$rn\" style=\"height:100%;width:100%;background:#7ee787;transition:width .1s linear\"></div></div>" *
        "<span id=\"batp-$rn\" style=\"width:34px;text-align:right;color:#7ee787\">100%</span></div>"
    end, "")
    data = JSON3.write(Dict("r" => nums, "s" => mat))
    script = """
    <script>
    (function(){
      var D = $data, R = D.r, S = D.s, N = S.length;
      function col(s){ return s<=0.25?'#ff6b6b':(s<=0.5?'#ffb454':'#7ee787'); }
      // MeshCat's Animator keeps the playhead on ITSELF (`this.time`, `this.duration`).
      function playhead(){
        var an = window.viewer && window.viewer.animator; if(!an) return {t:0,d:0};
        var t = (typeof an.time === 'number') ? an.time : 0;
        var d = (typeof an.duration === 'number' && an.duration > 0) ? an.duration : 0;
        if(d === 0){                                   // fall back to the clips if duration is unset
          var acts = an.actions||[];
          for(var i=0;i<acts.length;i++){
            var c = acts[i]._clip || (acts[i].getClip && acts[i].getClip());
            if(c && c.duration) d = Math.max(d, c.duration);
          }
        }
        return {t:t, d:d};
      }
      function socAt(frac){
        if(N===0) return null;
        var x=frac*(N-1), i=Math.floor(x), g=x-i;
        var a=S[Math.max(0,Math.min(N-1,i))], b=S[Math.max(0,Math.min(N-1,i+1))], o=[];
        for(var k=0;k<R.length;k++){ o.push(a[k]+(b[k]-a[k])*g); } return o;
      }
      function tick(){
        var p=playhead(), frac=p.d>0?Math.max(0,Math.min(1,p.t/p.d)):0, soc=socAt(frac);
        if(soc){ for(var k=0;k<R.length;k++){ var s=soc[k]; if(s==null||isNaN(s)) continue;
          var pct=Math.round(100*Math.max(0,Math.min(1,s))), c=col(s);
          var bar=document.getElementById('bat-'+R[k]), lab=document.getElementById('batp-'+R[k]);
          if(bar){ bar.style.width=pct+'%'; bar.style.background=c; }
          if(lab){ lab.textContent=pct+'%'; lab.style.color=c; } } }
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    })();
    </script>"""
    return (bars, script)
end

function _sidebar(timeline_html, log_html, batt_html, batt_script)
    batt_card = isempty(batt_html) ? "" :
        "<div class=\"cb-card\"><div class=\"cb-title\">🔋 BATTERY SoC — per robot" *
        "<span class=\"cb-sub\"> live · red ≤25% · orange ≤50% · spares stay full</span></div>" *
        "<div class=\"cb-bars\">$batt_html</div></div>"
    return """
    <style>
      #meshcat-pane { width: calc(100vw - $(SIDEBAR_W)px) !important; margin-left: $(SIDEBAR_W)px !important; }
      #cb-sidebar { position:fixed; top:0; left:0; width:$(SIDEBAR_W)px; height:100vh; box-sizing:border-box;
        overflow-y:auto; background:#0b0e15; border-right:1px solid #2a3346; z-index:99999;
        font:11px/1.45 ui-monospace,Consolas,monospace; padding:9px; }
      #cb-sidebar .cb-card { background:rgba(16,18,26,.92); border-radius:8px; padding:8px 10px;
        margin-bottom:9px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
      #cb-sidebar .cb-title { color:#9bd1ff; font-weight:700; margin-bottom:6px; }
      #cb-sidebar .cb-sub { color:#8891a5; font-weight:400; }
      #cb-sidebar .cb-log  { max-height:40vh; overflow:auto; white-space:pre-wrap; }
      #cb-sidebar .cb-bars { max-height:26vh; overflow:auto; }
    </style>
    <div id="cb-sidebar">
      <div class="cb-card"><div class="cb-title">OOD STREAM — adaptive re-plan<span class="cb-sub"> each event → a DSL macro</span></div>
        $timeline_html
        $(RESCUE ? "<div style=\"color:#ffb454;margin-top:7px\">CARRIER_RESCUE is ON: a formed carrier that " *
                   "stalls en route is advanced to its deposit, so a mid-build Replace can finish. The " *
                   "surrogate's predicted values were learned WITHOUT it (see DEMO.md).</div>" : "")</div>
      $batt_card
      <div class="cb-card"><div class="cb-title">SURROGATE WORLD MODEL<span class="cb-sub"> decide in imagination · 0 planner calls</span></div>
        <div class="cb-log">$log_html</div></div>
    </div>
    <script>
      (function(){ function fit(){ try{ window.dispatchEvent(new Event('resize')); }catch(e){} }
        window.addEventListener('load', function(){ fit(); setTimeout(fit,80); setTimeout(fit,500); });
        setTimeout(fit,150); })();
    </script>
    $batt_script"""
end

htmlpath = HTMLPATH
if isfile(htmlpath)
    # Make each DEEP battery drop VISIBLE: re-inject the post-drop SoC as a short HOLD.
    if !isempty(BATT_CRIT) && !isempty(SOC_HISTORY)
        HOLD = max(1, round(Int, 0.05 * length(SOC_HISTORY)))
        for (rid, crit, f0) in BATT_CRIT
            crit > 0.30 && continue
            for fr in max(1, f0):min(length(SOC_HISTORY), f0 + HOLD)
                isempty(SOC_HISTORY[fr]) && continue
                haskey(SOC_HISTORY[fr], rid) && (SOC_HISTORY[fr][rid] = crit)
            end
        end
    end
    bars, bscript = _battery_live(SOC_HISTORY)
    panel = "<!--CB-PANEL-START-->" * _sidebar(_timeline_rows(_TIMELINE), _log_rows(_PIPE), bars, bscript) *
            "<!--CB-PANEL-END-->"
    html  = read(htmlpath, String)
    # IDEMPOTENT: strip any panel this demo (or an older one) already injected.
    while occursin("<!--CB-PANEL-START-->", html) && occursin("<!--CB-PANEL-END-->", html)
        i = findfirst("<!--CB-PANEL-START-->", html); j = findfirst("<!--CB-PANEL-END-->", html)
        html = html[1:(first(i) - 1)] * html[(last(j) + 1):end]
    end
    html  = occursin("</body>", html) ? replace(html, "</body>" => panel * "\n</body>"; count = 1) : html * panel
    write(htmlpath, html)
    println(">>> sidebar embedded: $(length(_TIMELINE)) OOD events, $(length(_PIPE)) log lines, " *
            "$(length(SOC_HISTORY)) SoC frames -> $(htmlpath)")
else
    @warn "no animation was written to $htmlpath — nothing to inject (did the run save_animation?)"
end
println("\n>>> OOD TIMELINE (what the surrogate decided, in order):")
for r in _TIMELINE; println("    ", r); end
println(">>> done. Open: $htmlpath")
OPEN_ANIM && isfile(htmlpath) && (try run(`cmd /c start "" $(abspath(htmlpath))`) catch e; @warn "auto-open failed: $e" end)
end

# =============================================================================
# run_zone -- full-render visual check of OOD 1-2 (restriction zone). Builds the
#   tractor with the full motion stack + render, injects a navigation no-go zone
#   mid-sim (RESPEC OFF), and opens a MeshCat animation so you can SEE robots
#   detour around the red-disc zone. Isolates the physical/navigation effect.
#   Tuning: INJECT_STEP (below) and the zone seed/placement.
# =============================================================================
function demo_run_zone()
INJECT_STEP = 150          # sim step at which the no-go zone appears

CB.clear_ood_schedule!()
CB.clear_restriction_zones!()
CB.clear_zone_markers!()

CB.schedule_ood!(INJECT_STEP, function (env)
    # Place a random no-go zone within the current activity area (seeded =
    # reproducible). Swap for an explicit placement if you want a fixed spot:
    #     z = CB.add_restriction_zone!(:demo, [x, y], r)
    z, nl = CB.random_restriction_zone!(env; key = :demo, seed = 7)
    @info "[OOD] restriction zone injected" center=CB.get_center(z) radius=CB.get_radius(z)
    return nl     # enqueued for respec (a no-op here: RESPEC disabled). Detour is physical.
end)

# ---- build + simulate with full motion stack and render --------------------
pp = CB.get_project_params(4)    # tractor

CB.run_lego_demo(;
    ldraw_file   = pp[:file_name],
    project_name = pp[:project_name],
    model_scale  = pp[:model_scale],
    num_robots   = pp[:num_robots],
    assignment_mode      = :greedy,
    rvo_flag             = true,
    tangent_bug_flag     = true,
    dispersion_flag      = true,
    open_animation_at_end = true,    # opens the MeshCat animation in the browser
    save_animation        = true,
    write_results         = false,
    overwrite_results     = false,
    log_level             = Logging.Warn,
)

println(">>> done. The red disc is the injected no-go zone; watch robots route around it.")
end

# ---- dispatcher -------------------------------------------------------------
const DEMOS = Dict(
    "original_baseline"    => demo_original_baseline,
    "run_zone"             => demo_run_zone,
    "wholebuild"           => demo_wholebuild,
    "respec_forbidzone"    => demo_respec_forbidzone,
    "respec_replace"       => demo_respec_replace,
    "rl_replace"           => demo_rl_replace,
    "surrogate"            => demo_surrogate,
    "surrogate_stream"     => demo_surrogate_stream,
    "energy_adaptive"      => demo_energy_adaptive,
    "energy_adaptive_anim" => demo_energy_adaptive_anim,
    "energy_stall_replace" => demo_energy_stall_replace,
)
end # module Demos

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "DEMO", isempty(ARGS) ? "original_baseline" : ARGS[1])
    haskey(Demos.DEMOS, key) || error("unknown demo '$key'. Available: $(join(sort(collect(keys(Demos.DEMOS))), ", "))")
    println(">>> running demo: $key")
    Demos.DEMOS[key]()
end
