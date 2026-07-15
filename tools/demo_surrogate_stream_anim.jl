# =============================================================================
# demo_surrogate_stream_anim.jl -- the LEARNED SURROGATE WORLD MODEL adapting to a STREAM of
# DIFFERENT OOD events, with a live battery-SoC HUD, in a docked (non-overlapping) sidebar.
#
# This supersedes demo_surrogate_anim.jl (single OOD, overlay panel). Three changes:
#   1. OOD STREAM   -- several events of DIFFERENT kinds arrive at random build-progress points
#                      (robot breakdown / battery discharge / no-go zone). The surrogate re-plans
#                      at EACH one, so you watch the construction plan adapt repeatedly.
#   2. BATTERY HUD  -- the battery layer is ON from step 1: per-robot SoC bars drain in real time,
#                      synced to the MeshCat playhead (same widget as demo_energy_stall_replace_anim).
#   3. DOCKED UI    -- the panels live in a left sidebar and the MeshCat pane is SHRUNK beside them
#                      (margin-left + width:calc), so nothing overlaps the 3D scene or its controls.
#
# The decision function is unchanged: at every OOD event the surrogate predicts the re-plan outcome
# (`closed` schedule nodes) for ALL FIVE DSL macros {NOOP, Replace, Deprioritize, ForbidZone,
# ReformTeam} *in imagination* -- zero true-planner calls -- ranks them, and enacts the argmax.
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_surrogate_stream_anim.jl
# Env knobs:
#   OOD_N=4        how many OOD events in the stream
#   OOD_KINDS="fault,battery,zone"   which kinds may be drawn
#   OOD_SEED=3     stream RNG (event kinds, timings, battery severities)
#   NSPARE=3  SEED=1  GRID_SCALE=4.0  SHRINK=200  STALL_SOC=0.05
#   SAVE_ANIM=1 (0 = fast check, no animation)   OPEN_ANIM=1   SIDEBAR_W=380
# =============================================================================
using ConstructionBots
import JSON3, Graphs, Logging, HiGHS, LinearAlgebra, Random
using Printf
const CB = ConstructionBots

const _EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
include(joinpath(_EXAMPLES, "ood_env.jl"))
include(joinpath(_EXAMPLES, "ood_env_mdp.jl"))     # event_context, valid_actions, action_to_proposal
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))  # battery, ood_truth, ood_stream

const OOD_N      = parse(Int, get(ENV, "OOD_N", "4"))
const OOD_KINDS  = [Symbol(strip(s)) for s in split(get(ENV, "OOD_KINDS", "fault,battery,zone"), ",")]
const OOD_SEED   = parse(Int, get(ENV, "OOD_SEED", "3"))
const NSPARE     = parse(Int, get(ENV, "NSPARE", "3"))
const SEED       = parse(Int, get(ENV, "SEED", "1"))
const GRID_SCALE = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
# MUST match the oracle data-gen's battery physics (DS_SHRINK / DS_STALL), or the surrogate is
# predicting outcomes for a different world than the one being simulated here.
const SHRINK     = parse(Float64, get(ENV, "SHRINK", "200.0"))    # == DS_SHRINK
const STALL_SOC  = parse(Float64, get(ENV, "STALL_SOC", "0.15"))  # == DS_STALL
const OPEN_ANIM  = get(ENV, "OPEN_ANIM", "1") == "1"
const SAVE_ANIM  = get(ENV, "SAVE_ANIM", "1") == "1"
const SIDEBAR_W  = parse(Int, get(ENV, "SIDEBAR_W", "380"))
const NOPROG     = parse(Int, get(ENV, "NOPROG", "6000"))   # no-progress cap: keeps a wedged run from
                                                            # grinding for hours at animation speed
const RESCUE     = get(ENV, "CARRIER_RESCUE", "0") == "1"   # see force_advance_stuck_carrier!

# run_lego_demo defaults `project_name` to the LDRAW FILE NAME, so without this the animation is written
# to results/tractor.mpd/... while the panels were being injected into results/tractor/... — a stale file
# left behind by an older demo. The result: an old single-OOD animation, with this run's sidebar pasted
# on top of ten previously-injected overlays. Pin the name so both land in the same place.
const PROJECT    = "tractor"
const HTMLPATH   = joinpath("results", PROJECT, "greedy_RVO_Dispersion_TangentBug", "visualization.html")
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
const FEATNAMES = String.(SURRO["feature_names"])
const IS_FOREST = get(SURRO, "kind", "linear") == "forest"
println(">>> surrogate: $(IS_FOREST ? "RandomForest ($(length(SURRO["trees"])) trees)" : "Ridge"), " *
        "$(length(FEATNAMES)) features, $(SURRO["meta"]["n_instances"]) instances, " *
        "LOO decision-regret=$(round(Float64(SURRO["meta"]["loo_decision_regret"]); digits=3))")
haskey(SURRO["meta"], "kinds") && println(">>> trained on OOD kinds: $(SURRO["meta"]["kinds"])")

# A FOREST, not a line. The graded task flips the correct macro at a THRESHOLD (SoC ~0.15,
# zone_overlap ~0.4) — a linear model cannot represent that even with interaction columns (it scored
# 0.500 decision-regret on the zone instances). Trees can, and trees are the model class E1-E4 use.
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

# severity of the event currently being handled (set by the injector; matches the dataset's
# per-kind definition: fault=1.0, zone=overlap frac, battery=post-drop SoC)
const CUR_SEV = Ref(1.0)

# The SAME feature row the surrogate was trained on (e1_analyze.featurize column order).
# Training zones are all the CONSEQUENTIAL blocking zone (kind_zoneblk); plain harmless zones were
# inadmissible, so a :zone event maps to kind_zoneblk.
# Fraction of a PENDING staging circle the zone actually covers — the physical severity of a zone
# event (identical formula to oracle/gen_oracle_dataset.jl::zone_overlap_frac). 0 = blocks nothing.
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
    # interaction terms `<state>__x__macro_<m>` (export_surrogate.py::add_interactions). They are what
    # let the model FLIP its answer within one OOD kind: on a battery event the value of NOOP rises
    # with SoC while Replace stays flat, so their curves cross — an additive model cannot express that.
    return [get_feature(d, f) for f in FEATNAMES]
end

function get_feature(d::Dict{String,Float64}, name::AbstractString)
    haskey(d, name) && return d[name]
    parts = split(name, "__x__")
    length(parts) == 2 && haskey(d, parts[1]) && haskey(d, parts[2]) &&
        return d[parts[1]] * d[parts[2]]
    error("surrogate wants feature '$name' but the demo cannot build it")
end

const _PIPE = String[]                 # engine + surrogate log (sidebar card 2)
const _TIMELINE = String[]             # one row per OOD event (sidebar card 1)
# (robot, post-drop SoC, HUD frame index) for each battery OOD, so the HUD can HOLD the critical bar
# visible before a hot-swap resets it to 100% (else a deep discharge -> Replace is invisible in the bars).
const BATT_CRIT = Vector{Tuple{Any,Float64,Int}}()
_say(s) = (push!(_PIPE, s); @info s)

# ---- THE PRODUCER: score every macro in imagination, enact the argmax --------------------
const _EVENT_NO = Ref(0)
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
# Zone events use the CONSEQUENTIAL blocking-zone placer (mirrors the oracle data-gen), not the
# small harmless zone, so ForbidZone/restage is genuinely the right call.
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

# n kinds drawn WITHOUT replacement (cycling the list if n > #kinds), then shuffled: guarantees the
# stream shows every disruption type at least once instead of, say, three breakdowns in a row.
function shuffle_kinds(rng, kinds, n)
    bag = Symbol[]
    while length(bag) < n
        append!(bag, Random.shuffle(rng, collect(kinds)))
    end
    return bag[1:n]
end

function schedule_stream!()
    rng  = Random.MersenneTwister(OOD_SEED)
    # Spread the events across the WHOLE build (it closes ~291 nodes). The first version drew points in
    # [10,55] and every event landed within 5 nodes of the others: the build closes nodes in bursts, so
    # several thresholds are crossed in the same step and the "stream" degenerates into one pile-up.
    pts  = stream_points(OOD_N, 20, 190, rng)
    # Draw kinds WITHOUT replacement so a 4-event stream really is 4 DIFFERENT disruptions (the earlier
    # i.i.d. draw produced fault,fault,fault,zone — three Replaces, which wedges the endgame).
    bag  = shuffle_kinds(rng, OOD_KINDS, OOD_N)
    zct  = Ref(0)
    plan = String[]
    for (i, p) in enumerate(pts)
        kind = bag[i]
        act = if kind === :fault
            # clear=false: keep the faulted robot's scene node so the ReplaceAgent enactment can
            # IDENTITY-PRESERVING hot-swap it (needs has_vertex(faulted); see hot_swap_robot!). With
            # clear=true the body is towed off-grid and hot-swap degrades to a re-stamp that wedges.
            tf = CB.fault_action(; safe = true, obstacle = false, clear = false)
            e -> (CUR_SEV[] = 1.0; tf(e))
        elseif kind === :battery
            # the SEVERITY LADDER measured by the oracle (GRADED_OOD_DESIGN.md §2.1):
            #   SoC 0.05  deep      -> stalls NOW, mid-haul, holding a chain  => Replace wins (172 vs 151)
            #   SoC 0.20  marginal  -> stalls LATER; replacing it is WORSE    => NOOP wins    (213 vs 172)
            #   SoC 0.55  mild      -> finishes on the remaining charge       => NOOP wins    (291 vs 172)
            # A model that reads only the OOD *kind* cannot separate these. The surrogate must read SoC.
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

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# ---- wire the seam + the battery layer ----------------------------------------------------
CB.RESPEC_ENABLED[] = true
for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
          :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!,
          :clear_agent_bias!)
    try getproperty(CB, f)() catch end
end
# 120, not 400: the background team/nav recovery has to react fast enough to clear a post-Replace
# endgame wedge (the LLM demo has completed with 120 since 2026-07-09). MUST equal the oracle's
# DS_REFORM, or the surrogate is predicting outcomes for a differently-recovering world.
try CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))) catch end
# HOT_SWAP=1: enact a fault-event Replace as an identity-preserving depot hot-swap (no schedule
# re-stamp) so a fault OOD in the stream COMPLETES the build instead of wedging. Must match the oracle
# label world (gen_oracle_dataset.jl DS_HOTSWAP). Default ON here because the headline V4 stream mixes
# fault with battery/zone and must reach PROJECT COMPLETE.
if get(ENV, "HOT_SWAP", "1") == "1"
    CB.set_hot_swap!(enabled = true, mode = Symbol(get(ENV, "HOT_SWAP_MODE", "via_depot")))
    println(">>> HOT_SWAP ON: fault Replace -> identity-preserving depot swap (no re-stamp, completes).")
else
    CB.set_hot_swap!(enabled = false)
end
CB.set_respec_producer!(surrogate_producer)

# per-step SoC snapshots -> the live, playhead-synced battery HUD
const SOC_HISTORY = Vector{Dict{Any,Float64}}()
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

# Remove any previous render. If the run fails, we then have NO html rather than a stale one that looks
# like a fresh result — the failure mode that produced an old single-OOD animation wearing this demo's
# sidebar.
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
    # Order: any robot that hits a CRITICAL low (<=0.25) anywhere in the run is listed FIRST, so the
    # robot a deep-battery OOD targets is visible without scrolling the 22-robot panel; the rest by id.
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
      // MeshCat's Animator keeps the playhead on ITSELF (`this.time`, `this.duration`) — the GUI's
      // time slider is bound to exactly these. The previous version walked `animator.actions[i].time`,
      // which is not where MeshCat stores it: it always read 0, so `frac` stayed 0 and every bar was
      // pinned at the first frame (100%). That is why the SoC bars never moved.
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
    # Make each DEEP battery drop VISIBLE: a hot-swap resets the robot's SoC to 100% within the same
    # step, so the critical value never lands in a frame snapshot and the bar looks like it never dropped.
    # Re-inject the post-drop SoC as a short HOLD so the bar visibly slams to red before the replacement
    # refills it — matching the OOD log's "SoC=0.02 -> Replace". Mild degradations (>0.30) are NOT
    # replaced, so they are already visible and left untouched.
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
    # IDEMPOTENT: strip any panel this demo (or an older one) already injected, so re-running can never
    # stack overlays on top of each other. Ten of them had accumulated in the stale file.
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
