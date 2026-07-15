# =============================================================================
# demo_rl_replace_anim.jl -- VISUAL (MeshCat) demo of the FULL OOD 1-1 ReplaceAgent
# pipeline driven by the TRAINED REINFORCE (MARL) POLICY instead of the LLM.
#
# This is the RL counterpart of tools/demo_respec_replace_anim.jl. The scenario is
# IDENTICAL (same solo-transport fault target, same spare pools, same OOD trigger), and
# the ONLY difference is the DECISION FUNCTION plugged into the shared producer seam:
#   * demo_respec_replace_anim.jl : producer = LLM (mock /propose or real Claude)
#   * demo_rl_replace_anim.jl     : producer = greedy_action(trained LinearPolicy)
# Both flow through the SAME verify -> replace_robot! enactment, so watching the two
# HTMLs side-by-side is a fair LLM-vs-RL visual comparison on one build.
#
# The RL producer reads the compact ~13-d state (extract_state) at each OOD event and
# emits the masked greedy DSL action; on a robot breakdown the trained policy chooses
# ReplaceAgent, so a spare drives in and takes over (same recovery story, RL-driven).
#
# Run (PowerShell):
#   cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
#   julia +lts --project=. tools/demo_rl_replace_anim.jl
# Output (SEPARATE folder so it does NOT overwrite the LLM demo's HTML):
#   results\tractor_rl\greedy_RVO_Dispersion_TangentBug\visualization.html  (auto-opens)
# Env knobs: OOD_POLICY (policy path), TARGET_ROBOT, OOD_STEP, FAULT_CLOSED, NSPARE,
#            GRID_SCALE, OPEN_ANIM, SAVE_ANIM (mirror the LLM demo's knobs).
# =============================================================================
import ConstructionBots as CB
import HiGHS, JSON3, Graphs, Logging, LinearAlgebra, Random

# The RL policy + state/action layer live in the decpomdp project's examples/. They only need
# `import ConstructionBots as CB` (NO DecPOMDP), so we include them directly here. Order matters:
# ood_env.jl defines OODEnv (used in ood_env_mdp.jl method signatures) and _n_closed.
const _EXAMPLES = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
include(joinpath(_EXAMPLES, "ood_env.jl"))        # OODEnv, _n_closed (skeleton; we only reuse types/helpers)
include(joinpath(_EXAMPLES, "ood_env_mdp.jl"))    # event_context, extract_state, valid_actions, action_to_proposal, OOD_ACTIONS
include(joinpath(_EXAMPLES, "ood_reinforce.jl"))  # LinearPolicy, greedy_action, load_policy

const PROJECT      = parse(Int, get(ENV, "NAVON_PROJECT", "4"))
const OOD_STEP     = parse(Int, get(ENV, "OOD_STEP", "20"))     # fault at sim-step (used if FAULT_CLOSED=0)
const FAULT_CLOSED = parse(Int, get(ENV, "FAULT_CLOSED", "0"))  # >0: fault when this many nodes CLOSED (reproducible)
const NSPARE       = parse(Int, get(ENV, "NSPARE", "2"))
const GRID_SCALE   = parse(Float64, get(ENV, "GRID_SCALE", "4.0"))
const OPEN_ANIM    = get(ENV, "OPEN_ANIM", "1") == "1"
const TARGET_ROBOT = parse(Int, get(ENV, "TARGET_ROBOT", "0"))
const SAVE_ANIM    = get(ENV, "SAVE_ANIM", "1") == "1"
const POLICY_PATH  = get(ENV, "OOD_POLICY",
    joinpath(dirname(pkgdir(CB)), "decpomdp", "checkpoints", "ood_policy.txt"))

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

# ---- load the trained policy ----------------------------------------------------------
const POLICY = if isfile(POLICY_PATH)
    println(">>> loaded trained RL policy: $POLICY_PATH")
    load_policy(POLICY_PATH)
else
    @warn "no trained policy at $POLICY_PATH -- using a RANDOM-INIT policy (train first: decpomdp> julia +lts --project=. examples/ood_train.jl)"
    LinearPolicy(Random.MersenneTwister(1))
end

# ---- captured RESPEC/RL pipeline log lines -> embedded into the HTML -------------------
const _PIPE = String[]

# ---- RL producer: read state at the OOD event, emit the masked greedy DSL action -------
# A light shim carries the few OODEnv fields extract_state reads. n_events is exact; step_count
# is proxied from build progress (the render sim loop does not expose its iter to the producer,
# and this only feeds the small "makespan pressure" feature s[11]).
mutable struct _RLShim
    env
    step_count::Int
    no_progress::Int
    n_events::Int
    max_steps::Int
end
const _SHIM = _RLShim(nothing, 0, 0, 0, 4000)

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
# obstacle=false (no spurious zone) + clear=false (keep the dead robot RED on-scene), matching the LLM demo.
#
# ROBUSTNESS (vs the first cut, which crashed): we NEVER fall back to _pick_active_robot. Faulting a
# robot that is mid-team-transport (or has 0 pending frontier) trips `has_edge(scene_tree, agent,
# robot_id)` in FormTransportUnit.apply_cmd! after the replace splices an empty frontier. So we fault
# ONLY a clean solo transporter with a pending assignment; if none is available at this progress point,
# we DEFER (return nothing) and a later scheduled trigger retries. `_FAULTED_ONCE` keeps it to one fault.
const _FAULTED_ONCE = Ref(false)
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

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# ---- wire the seam: RL producer instead of the LLM, same OOD schedule ------------------
CB.RESPEC_ENABLED[] = true
CB.set_respec_producer!(rl_producer)               # <-- the ONLY substantive difference vs the LLM demo
CB.clear_ood_schedule!(); CB.clear_restriction_zones!(); CB.clear_spare_pools!(); CB.clear_faulted_robots!()
CB.clear_recovery_spares!(); CB.clear_wedge_edges!()
# MATCH the LLM demo's recovery cadence for a FAIR comparison: recover a transient team deadlock every
# 400 no-progress steps (default is 2000, which makes the robots wander ~5x longer before ReformTeam
# repositions the stragglers). Without this the RL run APPEARS slower purely from the slower recovery
# trigger, not from any decision difference.
try; CB.set_reform_interval!(parse(Int, get(ENV, "REFORM_INTERVAL", "120"))); catch; end
# Fire the fault at a build-PROGRESS point (reproducible) where a clean solo transporter exists. We arm
# SEVERAL closed-count triggers; ood_action! faults at the FIRST one that has a safe target and no-ops
# the rest (_FAULTED_ONCE). FAULT_CLOSED overrides with a single explicit point.
if FAULT_CLOSED > 0
    CB.schedule_ood_at_closed!(FAULT_CLOSED, ood_action!)
else
    for c in (10, 18, 28, 42, 60)
        CB.schedule_ood_at_closed!(c, ood_action!)
    end
end

pp = CB.get_project_params(PROJECT)
const PROJ_RL = "$(pp[:project_name])_rl"           # separate results folder so the LLM HTML is preserved
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
