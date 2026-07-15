# =============================================================================
# demo_surrogate_anim.jl -- VISUAL (MeshCat) demo of the LEARNED SURROGATE WORLD MODEL
# deciding the OOD response, i.e. the visual counterpart of E1/E2.
#
# This is the third producer for the SAME shared seam (`set_respec_producer!`):
#   * demo_respec_replace_anim.jl : producer = LLM (mock /propose or real Claude)
#   * demo_rl_replace_anim.jl     : producer = trained RL policy (LinearPolicy)
#   * demo_surrogate_anim.jl      : producer = **learned SURROGATE world model**  <-- this file
#
# What it shows (the amortization claim, made visible):
#   At each OOD event the surrogate SCORES EVERY candidate DSL macro *in imagination* — it predicts
#   the re-plan outcome (`closed` schedule nodes) for {NOOP, Replace, Deprioritize, ForbidZone,
#   ReformTeam} WITHOUT running the true planner even once — ranks them, and enacts the argmax.
#   The overlay panel prints the imagined scores next to the chosen macro, so you can watch the
#   world model "think" and then see the build survive the disruption.
#
# The surrogate is the one exported from the E1 dataset (`wm4spacecraft_manufacturing/
# surrogate_linear.json`, written by export_surrogate.py). It is a StandardScaler+Ridge whose
# leave-one-instance-out DECISION quality is identical (regret 0.000) to the HistGradientBoosting
# model E1-E4 were run with — the value-equivalence property (EVALUATION.md §1): less accurate
# values, same ranking, same decisions. Evaluated natively in Julia so the demo needs NO Python
# (PyCall's env carries rvo2 only).
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_surrogate_anim.jl
# Env knobs:
#   DEMO_OOD=fault (default) | zone    -- which OOD the surrogate must respond to
#   NSPARE=3  GRID_SCALE=4.0  OPEN_ANIM=1  SAVE_ANIM=1  SEED=1
# =============================================================================
using ConstructionBots
import JSON3, Graphs, Logging, HiGHS, LinearAlgebra, Random
using Printf
const CB = ConstructionBots

const _EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
include(joinpath(_EXAMPLES, "ood_env.jl"))
include(joinpath(_EXAMPLES, "ood_env_mdp.jl"))   # event_context, valid_actions, action_to_proposal, canonical_action
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # fault_action / zone truth (world-age)

const DEMO_OOD   = Symbol(get(ENV, "DEMO_OOD", "fault"))    # :fault | :zone
const NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
const SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
const SEED       = parse(Int, get(ENV, "SEED", "1"))
const SEVERITY   = parse(Float64, get(ENV, "SEVERITY", "1.0"))   # zone: overlap frac; fault: 1.0
const SURRO_PATH = get(ENV, "SURROGATE",
    joinpath(dirname(pkgdir(CB)), "wm4spacecraft_manufacturing", "surrogate_linear.json"))
const MACROS = [0, 1, 2, 3, 4]
const MACRO_NAME = Dict(0=>"NOOP", 1=>"Replace", 2=>"Deprioritize", 3=>"ForbidZone", 4=>"ReformTeam")

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

# ---- the learned surrogate: y_hat = coef . ((x - mean)/scale) + intercept ----------------
const SURRO = JSON3.read(read(SURRO_PATH, String))
# This (superseded) demo only knows the LINEAR export with the original 19 columns. The current
# surrogate is a cost-aware RandomForest with interaction features, which this file cannot evaluate:
# without this check the producer just throws inside the respec loop, the exception is swallowed, every
# OOD silently becomes a NOOP, and the run looks like a legitimate (bad) result. Fail loudly instead.
if get(SURRO, "kind", "linear") == "forest" || any(occursin("__x__", String(f)) for f in SURRO["feature_names"])
    error("""demo_surrogate_anim.jl is SUPERSEDED and cannot read this surrogate ($(SURRO["meta"]["model"])).
             Use tools/demo_surrogate_stream_anim.jl, or export a linear one:
               python export_surrogate.py <dataset>.jsonl --cost-aware --linear""")
end
const FEATNAMES = String.(SURRO["feature_names"])
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
# NOTE the dataset's zone instances are all the CONSEQUENTIAL blocking-zone (`zoneblk`), so a :zone
# event maps to kind_zoneblk (kind_zone stayed 0 in training — plain harmless zones were inadmissible).
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

const _PIPE = String[]
_say(s) = (push!(_PIPE, s); @info s)

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
# Background `:reform` alarms get the canonical response (identical to the E1-E4 harness's
# "hold the background policy fixed" fairness rule); the surrogate decides the STUDIED OOD.
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
# (blocking-zone placer mirrors wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl)
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

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
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
