# =============================================================================
# demo_respec_replace_anim.jl -- VISUAL (MeshCat) demo of the FULL OOD 1-1 ReplaceAgent
# respec pipeline (robot breakdown -> spare hand-off), driven through the REAL seam with
# a deterministic mock LLM (no Anthropic key).
#
# Production path end-to-end: 4 directional SPARE pools are parked at build start; at
# OOD_STEP the scheduled action FAULTS a robot (fault_robot!) and emits an NL string ->
# push_ood! -> respec_step! -> maybe_respecify! -> llm_to_proposal(HTTP mock) ->
# _parse_proposal -> ReplaceAgent -> verify_replace -> nearest_pool/pop_spare ->
# replace_robot!. The animation records the story: build proceeds -> a robot breaks down
# (greyed, static obstacle) -> (NL routed through the mock LLM) -> the nearest spare drives
# in and takes over the faulted robot's remaining work.
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_respec_replace_anim.jl
# Browser opens at the end (set OPEN_ANIM=0 to only save the HTML).
#   USE_MOCK=1 (default): local deterministic mock /propose (no API key).
#   USE_MOCK=0: real Python LLM service at RESPEC_SERVICE_URL (run uvicorn with ANTHROPIC_API_KEY).
# =============================================================================
const USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
const MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8734"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST precede `using` (const reads ENV at load)
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

using ConstructionBots
import HTTP, JSON3, Graphs, Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots

const PROJECT    = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
const OOD_STEP     = parse(Int, get(ENV, "OOD_STEP", "20"))     # fault at sim-step (used if FAULT_CLOSED=0)
const FAULT_CLOSED = parse(Int, get(ENV, "FAULT_CLOSED", "0"))  # >0: fault when this many nodes CLOSED (build-progress; reproducible)
const NSPARE     = parse(Int, get(ENV, "NSPARE", "2"))
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
const SOLO_TARGET = get(ENV, "SOLO_TARGET", "1") == "1"   # fault a solo-transport robot (MVP-clean completion)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

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

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
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

# A robot CURRENTLY carrying one part ALONE: an active FormTransportUnit whose team is size 1. Unlike
# _solo_fault_target this does NOT require a pending assignment -- a robot mid-solo-transport has no
# pending assignment (it is busy executing the carry), yet it is the cleanest possible fault target: its
# transport "team" is just itself, so replacing it hands the single part to a spare with NO orphaned
# co-carrier (the has_edge crash only arises when a TEAM member is faulted mid-team-transport). In the
# tractor build solo transports are rare and SHORT-LIVED (verified via FAULT_DIAG: soloFTU=1 for a single
# probe window around closed~67), so the trigger fires every step to catch the window. nothing if none.
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
# transport-feeding RobotGo slot, and that task is SOLO (team size 1). Then the spare inherits a
# SINGLE clean task -> `_serialize_spare_frontiers!` adds ZERO serialization edges (slots<=1) -> the
# documented multi-task "cyclic cargo-dependency" endgame wedge cannot arise -> the build completes,
# exactly like the no-fault control. nothing if none available yet (caller defers to a later trigger).
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

const TARGET_ROBOT = parse(Int, get(ENV, "TARGET_ROBOT", "0"))   # >0: fault this exact robot id (else solo-pick)
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
#
# ROBUSTNESS: NEVER fall back to _pick_active_robot. Faulting a robot that is mid-team-transport
# (or has 0 pending frontier) trips `has_edge(scene_tree, agent, robot_id)` in
# FormTransportUnit.apply_cmd! after the replace splices an empty frontier. So we fault ONLY a clean
# solo transporter with a pending assignment; if none is available at this progress point, we DEFER
# (return nothing) and a later scheduled trigger retries. `_FAULTED_ONCE` keeps it to one fault.
const _FAULTED_ONCE = Ref(false)
function ood_action!(env)
    _FAULTED_ONCE[] && return nothing                        # only one fault for the whole demo
    # Require a genuine SINGLE-solo-task target: the spare then inherits exactly ONE task, so the
    # single-spare over-subscription wedge (multiple concurrent TransportUnitGo units all needing the
    # one spare) cannot arise -> the build completes like the no-fault control. Fired LATE (see the
    # trigger schedule) where the schedule is fully materialized so the 1-task count is ACCURATE
    # (early in the build, future RobotGo nodes are not yet present and the count under-reads).
    # A solo transporter fires reliably EARLY (where active transport robots exist). The multi-task
    # over-subscription is now handled by the distributed replace (each task -> its own nearest spare),
    # so we no longer need the fragile single-task restriction — any solo transporter completes.
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
    #   1. _single_solo_fault_target: EXACTLY ONE remaining solo task -> spare inherits a single clean
    #      task, zero serialization gates, build completes like the no-fault control (handoff guarantee).
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
    # obstacle=false: no no-go zone on the dead robot (LLM emits ONLY ReplaceAgent, no red circle).
    # clear=false: KEEP the broken robot visible (RED disc) while the spare takes over its work.
    nl = CB.fault_robot!(env; target = tgt, obstacle = false, clear = false)
    nl === nothing && return nothing
    _FAULTED_ONCE[] = true
    @info "[DEMO] OOD: faulted R$(tgt.id) (solo transporter); marked it RED (faulted); emitting NL event"
    return nl
end

# captured RESPEC pipeline log lines -> embedded into the HTML
const _PIPE = String[]
_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
function _log_panel(lines)
    isempty(lines) && return ""
    # Collapse repeats while keeping first-occurrence order. The "team deadlocked -> ReformTeam
    # -> declined" cycle is auto-emitted every ~2000 no-progress steps, so without this the panel
    # floods with dozens of identical lines and buries the actual recovery narrative.
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
    # Compact (340px), collapsible, top-left, narrow so the build stays visible. Click the header
    # to hide/show the body.
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

const SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.clear_recovery_spares!(); CB.clear_wedge_edges!()
# HOT_SWAP=1: enact ReplaceAgent as an IDENTITY-PRESERVING scene-tree hot-swap (keep the faulted
# RobotID, swap only its physical body from the depot) instead of the schedule-restamping distributed
# replace. No re-stamp => the cyclic-OpenBuildStep endgame wedge that leaves distributed Replace
# INCOMPLETE is structurally impossible (replan.jl:370). This is the robust completion path for the
# mid-build robot-breakdown demo. A mid-carry victim is healed in place (never disbanded).
if get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
    println(">>> HOT_SWAP ON (mode=$(CB.HOT_SWAP_MODE[])): ReplaceAgent -> identity-preserving depot swap (no schedule re-stamp).")
else
    CB.set_hot_swap!(enabled = false)
end
# Fire the endgame-wedge recovery OFTEN (default 2000-step interval => only ~5 attempts before the
# 10000 no-progress abort). One serialization gate is dissolved per attempt, so shorten the interval
# and raise the no-progress budget (below) to guarantee enough recovery cycles to fully unwedge.
try; CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))); catch; end
# Fire the fault at a build-PROGRESS point (reproducible) where a clean solo transporter exists. We arm
# SEVERAL closed-count triggers; ood_action! faults at the FIRST one that has a safe target and no-ops
# the rest (_FAULTED_ONCE). This avoids the has_edge crash from faulting a robot mid-team-transport at a
# fixed raw sim-step. FAULT_CLOSED overrides with a single explicit point.
if FAULT_CLOSED > 0
    CB.schedule_ood_at_closed!(FAULT_CLOSED, ood_action!)
else
    # Fire at EARLY RAW SIM-STEPS, not closed-count. In the tractor build, SOLO transport (a single robot
    # carrying one small part) happens ONLY early: by the time the closed-count reaches ~54 the small
    # parts are done and every remaining transport is a multi-robot TEAM, so a closed-count ladder finds
    # `soloTarget=none` for the whole build and the fault never fires (verified via FAULT_DIAG). The
    # original working demo fired at raw sim-step ~20. ood_action! uses _solo_fault_target, which returns
    # ONLY a solo robot, so faulting at a raw step is safe here (the has_edge crash comes from faulting a
    # TEAM member, which we never do). Arm a dense early-step ladder; ood_action! faults at the FIRST step
    # that has a solo target and _FAULTED_ONCE no-ops the rest.
    for s in (parse(Int, get(ENV, "FAULT_STEP0", "8"))):(parse(Int, get(ENV, "FAULT_STEPD", "1"))):(parse(Int, get(ENV, "FAULT_STEP1", "150")))
        CB.schedule_ood!(s, ood_action!)
    end
end

pp = CB.get_project_params(PROJECT)
# HTTP.serve! (mock) / uvicorn (real) start ASYNC — poll /health briefly so `ready` isn't a false
# negative (and so the one-shot probe doesn't race the server's bind, which logs a spurious
# ECANCELED handler error). Mirrors tools/demo_energy_adaptive_anim.jl.
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

const SAVE_ANIM = get(ENV, "SAVE_ANIM", "1") == "1"   # 0 = fast verification run (no animation recording)
run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Info,
        max_num_iters_no_progress=parse(Int, get(ENV, "NOPROG", "30000")),  # slack for per-cycle endgame recovery; lower (e.g. 4000) for fast wedge diagnosis
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
