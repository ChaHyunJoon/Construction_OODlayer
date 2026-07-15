# =============================================================================
# demo_respec_forbidzone_anim.jl -- VISUAL (MeshCat) demo of the FULL ForbidZone respec
# pipeline, driven through the REAL seam with a deterministic mock LLM (no Anthropic key).
#
# Unlike demo_wholebuild_anim.jl (which calls the geometric recovery DIRECTLY), this runs
# the production path end-to-end: at OOD_STEP the scheduled action injects a central zone
# and emits an NL string -> push_ood! -> respec_step! -> maybe_respecify! ->
# llm_to_proposal(HTTP mock) -> _parse_proposal -> ForbidZone -> verify_zone ->
# restage_all_blocked! -> translate_whole_build!. The animation records the whole story:
# build proceeds -> red zone appears -> (NL routed through the mock LLM) -> build relocates
# -> robots finish at the new site. This is a watchable demo of Stages 1-3 (LLM mocked).
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_respec_forbidzone_anim.jl
# Browser opens at the end (set OPEN_ANIM=0 to only save the HTML).
# =============================================================================
# USE_MOCK=1 (default): stand up a local deterministic mock /propose (no API key needed).
# USE_MOCK=0: use the REAL Python LLM service at RESPEC_SERVICE_URL (default :8000) — run that
#   service first in a shell that HAS ANTHROPIC_API_KEY (uvicorn server:app --port 8000).
const USE_MOCK  = get(ENV, "USE_MOCK", "1") == "1"
const MOCK_PORT = parse(Int, get(ENV, "MOCK_PORT", "8732"))
if USE_MOCK
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:$MOCK_PORT"   # MUST precede `using` (const reads ENV at load)
elseif !haskey(ENV, "RESPEC_SERVICE_URL")
    ENV["RESPEC_SERVICE_URL"] = "http://127.0.0.1:8000"        # default real-service address
end

using ConstructionBots
import HTTP, JSON3, Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots

const PROJECT   = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
const OOD_STEP  = parse(Int, get(ENV, "OOD_STEP", "5"))
const ZONE_R    = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5"))
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM = get(ENV, "OPEN_ANIM", "1") == "1"

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

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

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
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
const _PIPE = String[]
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

const SRV = USE_MOCK ? start_mock(MOCK_PORT) : nothing
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
