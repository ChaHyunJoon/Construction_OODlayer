# =============================================================================
# demo_energy_adaptive_anim.jl -- VISUAL (MeshCat) demo of the ENERGY-AWARE ADAPTIVE
# replanning stack: per-robot battery SoC accounting + energy objective + multi-time OOD,
# with the CAMERA FOLLOWING the manufacturing point so a whole-build relocation stays in frame.
#
# Story recorded in the animation:
#   build starts -> a robot's BATTERY degrades (NL) -> LLM/mock -> DeprioritizeAgent (SOFT:
#   never stalls) -> energy-aware re-solve routes work off it -> a central NO-GO ZONE appears
#   -> ForbidZone -> whole-build translate -> CAMERA FOLLOWS to the new site -> build finishes.
#
# Run (PowerShell), mock LLM (no key needed):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_energy_adaptive_anim.jl
# Real LLM (shows the actual DeprioritizeAgent translation): start the service in a shell WITH
#   $env:ANTHROPIC_API_KEY, then:  $env:USE_MOCK="0"; julia +lts --project=. tools/demo_energy_adaptive_anim.jl
# Env knobs: N_BATTERY, ZONE_CLOSED, SEED, ENERGY_W, OPEN_ANIM, GRID_SCALE, CAM_MAP (see below).
# =============================================================================
const USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
const MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8733"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST precede `using` (const reads ENV at load)
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"
end

using ConstructionBots
import HTTP, JSON3, Logging, HiGHS
const CB = ConstructionBots

# navigator layer (manual-include pattern) — battery + multi-OOD stream
for f in ("metrics.jl", "ood_truth.jl", "battery.jl", "ood_stream.jl")
    CB.include(joinpath(pkgdir(CB), "src", "navigator", f))
end

const PROJECT     = parse(Int, get(ENV, "PROJECT", "4"))           # 4 = tractor
const N_BATTERY   = parse(Int, get(ENV, "N_BATTERY", "2"))         # # of battery-degradation OOD
const ZONE_CLOSED = parse(Int, get(ENV, "ZONE_CLOSED", "60"))      # closed-count to drop the central zone
const ZONE_R      = parse(Float64, get(ENV, "ZONE_R", "2.5"))      # central zone radius (big -> whole-build move)
const SEED        = parse(Int, get(ENV, "SEED", "7"))
const ENERGY_W    = parse(Float64, get(ENV, "ENERGY_W", "0.01"))
const GRID_SCALE  = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM   = get(ENV, "OPEN_ANIM", "1") == "1"
const CAM_MAP     = get(ENV, "CAM_MAP", "x0-y")                   # world (x,y)->cam target; DEFAULT x0-y = z-up world -> y-up camera (view follows the build's move direction)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# ENERGY-AWARE objective (every re-solve minimizes makespan + w·energy, biased off low-SoC robots).
CB.set_planning_objective_weights!(speed = 1.0, efficiency = ENERGY_W)
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

# camera-follow DISABLED by default — the adaptive move made the view hard to control.
# Set CAM_FOLLOW=1 to re-enable the old centre-on-active-agents behaviour.
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
const SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
CB.RESPEC_ENABLED[] = true
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_agent_bias!()

# Per-step SoC snapshots for the LIVE (time-synced) battery UI. One entry is appended per
# simulation step (== one animation frame, since update_anim_at_every_step=true), so the
# saved HTML can replay each robot's REAL-TIME degradation against the MeshCat playhead.
const SOC_HISTORY = Vector{Dict{Any,Float64}}()

# step 1: turn the battery layer ON (needs env; the action receives it). Visible depletion via demo params.
CB.schedule_ood!(1, function (env)
    CB.enable_battery!(env; params = CB.demo_battery_params())
    CB.set_battery_penalty!(gain = 6.0, soc_target = 0.5, hard_mult = 1.0e3)
    # Wrap the accounting hook so every step also records a SoC snapshot for the live UI.
    # (enable_battery! just set BATTERY_STEP_HOOK to account_battery_step!; wrap that.)
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
# HTTP.serve! (mock) / uvicorn (real) start ASYNC — poll /health briefly so `ready` isn't a
# false-negative from checking before the server finished binding.
_rdy = Ref(false)
for _ in 1:30
    if CB.respec_service_ready(); _rdy[] = true; break; end
    sleep(0.1)
end
ready = _rdy[]
println(">>> ENERGY-ADAPTIVE visual demo: project=$(pp[:project_name])  mode=$(USE_MOCK ? "MOCK" : "REAL-LLM")")
println(">>> battery OOD x$N_BATTERY (DeprioritizeAgent) + central zone @closed=$ZONE_CLOSED; /propose=$(ENV["RESPEC_SERVICE_URL"]) ready=$ready")
(!USE_MOCK && !ready) && @warn "REAL-LLM mode but service not reachable — start uvicorn server:app --port 8000 in a shell WITH ANTHROPIC_API_KEY first."

const _PIPE = String[]
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
# Layout: a fixed LEFT SIDEBAR holds the panels and the MeshCat pane is shrunk to the
# right of it (margin-left + width:calc), so the panels no longer OVERLAP the 3D scene.
# MeshCat sizes #meshcat-pane from its offsetWidth and re-fits on window "resize", so a
# resize event is dispatched after load to make the scene re-fit the reduced pane.
const SIDEBAR_W = parse(Int, get(ENV, "SIDEBAR_W", "360"))   # sidebar width in px (env-tunable)
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

# LIVE per-robot battery bars, ALIGNED BY ROBOT NUMBER (R1,R2,…,Rn). Returns
# (bars_html, script_html): the bars carry stable ids (#bat-N / #batp-N) and the script
# drives them in REAL TIME from the SoC-per-frame history, synced to the MeshCat playhead
# (viewer.animator) so each robot's degradation animates with the build. Colors: red ≤25%,
# orange ≤50%, green above. Frames are downsampled to <= maxpts to keep the HTML small.
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
