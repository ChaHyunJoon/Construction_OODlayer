# =============================================================================
# demo_energy_stall_replace_anim.jl -- VISUAL (MeshCat) demo of the CLOSED battery loop:
#   motion drains SoC (faster/longer -> faster drain) -> a robot hits 0% and STALLS ->
#   that raises a breakdown OOD -> LLM (mock) re-specs ReplaceAgent -> the NEAREST spare
#   depot (N/S/E/W, visible at the middle of each grid side) dispatches a fresh robot that
#   drives out, adopts the dead robot's remaining chain and re-forms its transport team.
#
# What is NEW here vs demo_energy_adaptive_anim.jl:
#   * n_spare_per_pool=2  -> 8 physical spare robots parked at the 4 cardinal depots (VISIBLE).
#   * set_battery_stall!  -> SoC<=STALL_SOC immobilizes the robot (motion gate) AND fires the
#                            breakdown OOD (navigator/battery.jl). No scheduled OOD: stalls
#                            EMERGE from the energy dynamics.
#   * mock /propose maps "broken/cannot move" -> ReplaceAgent (the spare hand-off path).
#
# Run (PowerShell), mock LLM (no key needed):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_energy_stall_replace_anim.jl
# Env knobs: PROJECT, N_SPARE, SHRINK (battery capacity /SHRINK; larger -> flatter/faster
#   stalls), STALL_SOC, ENERGY_W, SEED, OPEN_ANIM, GRID_SCALE.
# =============================================================================
const USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
const MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8744"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST precede `using`
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

using ConstructionBots
import HTTP, JSON3, Logging, HiGHS
const CB = ConstructionBots

# navigator layer (manual-include pattern) — battery accounting + stall coupling
for f in ("metrics.jl", "ood_truth.jl", "battery.jl", "ood_stream.jl")
    CB.include(joinpath(pkgdir(CB), "src", "navigator", f))
end

const PROJECT    = parse(Int, get(ENV, "PROJECT", "4"))          # 4 = tractor
const N_SPARE    = parse(Int, get(ENV, "N_SPARE", "2"))          # spares per depot (x4 dirs)
const SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))   # battery capacity /SHRINK (gentle:
                                                                 #   bars deplete visibly but NEVER
                                                                 #   naturally hit 0 -> only the
                                                                 #   deep-discharge events stall)
const STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.02")) # SoC at/below which a robot dies
const ENERGY_W   = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
const SEED       = parse(Int, get(ENV, "SEED", "7"))
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
const FAST       = get(ENV, "FAST", "0") == "1"   # tuning: skip per-step anim frames (much faster, coarse video)
const SPARE_MARGIN = parse(Float64, get(ENV, "SPARE_MARGIN", "18.0"))  # depot distance outside build (x robot_radius; 3x the old 6)
CB.set_spare_pool_margin!(SPARE_MARGIN)           # park the depots FAR from the build (visible re-emergence)
# ADAPTIVITY: react to a post-swap team wedge in ~a second, not the old ~50 s. Lower = snappier
# (near-instant resolution, less visible drive); higher = more visible drive before reform snaps.
const REFORM_INTERVAL = parse(Int, get(ENV, "REFORM_INTERVAL", "300"))
CB.set_reform_interval!(REFORM_INTERVAL)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

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

# --- OOD schedule: NONE. Stalls emerge from motion drain. We only turn the battery+stall
#     layer ON at step 1 (needs env). Spare depots are injected by run_lego_demo (n_spare>0). --
const SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()
CB.clear_faulted_robots!(); CB.clear_recovery_spares!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI (one entry per sim step ==
# one animation frame, since update_anim_at_every_step=true), so the saved HTML replays each
# robot's real-time degradation against the MeshCat playhead.
const SOC_HISTORY = Vector{Dict{Any,Float64}}()

CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params(shrink = SHRINK))
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # clear=true tows the dead robot off-grid so the spare takes over cleanly and the build
    # completes; STALL_CLEAR=0 leaves it in place as an obstacle (may wedge tight staging).
    # HOT_SWAP=1: identity-preserving scene-tree replacement from the repository (keep the
    # faulted RobotID, swap its physical asset). With it on, DON'T tow the dead body off-grid
    # (clear=false) — hot_swap_robot! re-homes the same-id robot out of the depot itself and
    # leaves a greyed decommission marker at the break spot.
    hot = get(ENV, "HOT_SWAP", "0") == "1"
    CB.set_battery_stall!(enabled = true, threshold = STALL_SOC,
        clear = hot ? false : (get(ENV, "STALL_CLEAR", "1") == "1"),
        obstacle = get(ENV, "STALL_OBSTACLE", "0") == "1")   # <-- the new coupling
    if hot
        CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
        @info "[DEMO] identity-preserving HOT-SWAP repository replacement ON (mode=$(CB.HOT_SWAP_MODE[]))"
    end
    # Wrap the accounting hook (which also runs the stall trigger) so every step records a
    # SoC snapshot for the live battery HUD.
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

# Deterministic "run flat mid-haul": at chosen build-progress points, drain an ACTIVE transport
# robot to empty. Its SoC hits 0 while it still has a pending work chain -> the stall trigger
# raises the breakdown OOD next step -> ReplaceAgent -> the NEAREST depot spare drives out and
# adopts the dead robot's remaining tasks. This GUARANTEES the loop fires (natural drain stays
# on too, so the per-robot SoC bars still deplete faster for busier robots). Early progress
# points mirror the proven 1-1 hand-off window (a robot with tasks left to give away).
# Pick a real WORKING robot (never a parked spare R11+). PREFER a non-spare worker IN TRANSIT
# (active free RobotGo, not yet captured) that still has pending work: hot_swap_robot! then uses
# :via_depot and the robot visibly re-emerges from the far depot and drives back to that task.
# Only if every worker is mid-carry (captured) do we fall back to a carrier (heals in place).
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
const DISCHARGE_AT = [parse(Int, strip(x)) for x in split(get(ENV, "DISCHARGE_AT", "60"), ",") if strip(x) != ""]
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

const _PIPE = String[]
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
# Layout: a fixed LEFT SIDEBAR holds the panels and the MeshCat pane is shrunk to its right
# (margin-left + width:calc) so the panels DON'T OVERLAP the 3D scene. A resize event is
# dispatched after load so MeshCat re-fits the reduced pane.
const SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
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

# LIVE per-robot battery bars aligned by robot number (R1..Rn), driven in REAL TIME from the
# SoC-per-frame history synced to the MeshCat playhead. Colors: red <=25%, orange <=50%, green.
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
