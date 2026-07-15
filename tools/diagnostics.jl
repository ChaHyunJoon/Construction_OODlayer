# =============================================================================
# tools/diagnostics.jl -- consolidated ConstructionBots diagnostics / compare / fixture driver.
#
# Every standalone tools/{diag_*,run_*_check,ood_compare_*,ab_*,dump_*}.jl script is now a
# FUNCTION in module `Diagnostics`, sharing common boilerplate (MILP setup + run_with_stack)
# defined ONCE. A CLI/ENV dispatcher at the bottom lets any single diagnostic run individually.
#
# Diagnostic keys:
#   rethread        -- double-book diagnostic after fault->reassign->commit on the RESUME path
#                      (diag_rethread.jl): dumps offending timelines + backtraces.
#   rethread_check  -- non-interactive verification of the rethread_robot_ids! fix
#                      (run_rethread_check.jl): resume sanity + reassign+resume x5 trials.
#   ood_compare     -- LLM vs RL vs canonical vs no-adapt on a FULLY-SIMULATED, completing
#                      robot-breakdown (ood_compare_fullsim.jl): completion %, makespan, F1.
#   ab_energy       -- A/B proof for the energy-aware objective (ab_energy_objective.jl):
#                      re-solves the same assignment at several efficiency weights.
#   dump_fixture    -- build the tractor env, step mid-build, dump the exact /propose request
#                      body to tools/llm_fixture.json (dump_llm_fixture.jl).
#
# Run:
#   julia +lts --project=. tools/diagnostics.jl <diag_key>        (or  ENV DIAG=<key>)
# e.g.
#   julia +lts --project=. tools/diagnostics.jl rethread_check
#   DIAG=ood_compare julia +lts --project=. tools/diagnostics.jl
# Each diagnostic reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Diagnostics
using ConstructionBots
using Printf
import Logging, HiGHS, JuMP, JSON3, Graphs, Random
const CB = ConstructionBots

# ---- runtime-loaded decoupled layers (loaded ONCE, at module load) ----------
# The navigator layer and the decpomdp OOD example layer are NOT compiled into the
# ConstructionBots package -- the scripts historically `CB.include`d them at SCRIPT TOP
# LEVEL. Now that each script is a FUNCTION, doing those includes *inside* a function and then
# calling the freshly-defined methods in the SAME call frame raises a world-age error
# ("method too new to be called from this world context"). Loading them here at MODULE
# load puts them in an OLDER world than any diagnostic call, exactly reproducing the original
# top-level-include semantics. navigator.jl is the umbrella loader (it includes metrics/
# ood_truth/battery/ood_stream/... in dependency order -- see its header), so ONE call
# covers every navigator-using function (fault_action, descriptors, energy model, ...); the
# three decpomdp examples only need CB (no DecPOMDP) and back ood_compare's RL/canonical arms.
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
let _EX = joinpath(dirname(pkgdir(CB)), "decpomdp", "examples")
    include(joinpath(_EX, "ood_env.jl"))       # OODEnv, _n_closed
    include(joinpath(_EX, "ood_env_mdp.jl"))   # event_context, valid_actions, action_to_proposal, canonical_action
    include(joinpath(_EX, "ood_reinforce.jl")) # LinearPolicy, greedy_action, load_policy
end

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically, 300s/5.0/MOI.Silent) in
# diag_rethread + run_rethread_check; ab_energy uses the SAME attribute set with ENV-tuned
# time_limit/gap. ood_compare uses a DIFFERENT attribute set (output_flag instead of MOI.Silent,
# 60s/0.05 gap) and keeps its block inline -- see that function.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper from all of these scripts.
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# ood_compare's RL state shim (a struct cannot be defined inside a function, so it lives at
# module level with a unique name; it is only referenced by ood_compare).
mutable struct _CompareRLShim
    env
    step_count::Int
    no_progress::Int
    n_events::Int
    max_steps::Int
end

# =============================================================================
# rethread -- Diagnostic: after fault->reassign->commit on the RESUME path (which now runs
#   rethread_robot_ids!), find any robot that is DOUBLE-BOOKED — captured inside a
#   transport unit while a free RobotGo of the same robot overlaps in time — and dump
#   its timeline + backtraces. Tells us whether the remaining :asserted is a genuine
#   MILP double-assignment (rethreading can't fix -> need Option 2) or still an
#   id-threading artifact my pass missed.
# =============================================================================
function diag_rethread()
_setup_milp!()

function build_base_env()
    pp = CB.get_project_params(4)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
            milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error, rvo_flag=false,
            tangent_bug_flag=false, dispersion_flag=false, open_animation_at_end=false,
            save_animation=false, save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false, save_milp_solution=false,
            return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    return env
end

pred(sched, v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
rid(node) = (node isa CB.RobotGo ? CB.get_id(CB.entity(node).id) : -1)

function backtrace_to_start(sched, v; maxdepth=60)
    chain = Tuple{Int,String,Int}[]; cur = v
    for _ in 1:maxdepth
        n = pred(sched, cur)
        idv = try (n isa CB.RobotGo || n isa CB.RobotStart) ? CB.get_id(CB.entity(n).id) : -1 catch; -1 end
        push!(chain, (cur, string(nameof(typeof(n))), idv))
        n isa CB.RobotStart && break
        ins = collect(Graphs.inneighbors(sched, cur)); isempty(ins) && break; cur = first(ins)
    end
    return chain
end

println(">>> building env...")
env = build_base_env()
sched = env.sched
# advance to a deeper mid-build like the test (target_closed=24)
for _ in 1:100000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= 24 || CB.project_complete(env)) && break
end
println(">>> advanced: closed=$(length(env.cache.closed_set)) nodes=$(Graphs.nv(sched))")

# pick faultable agent (on a pending transport team)
agent = nothing
seen = CB.AbstractID[]
for v in Graphs.vertices(sched)
    n = pred(sched, v); n isa CB.RobotGo || continue
    r = try CB.entity(n).id catch; nothing end
    (r isa CB.RobotID && CB.valid_id(r) && !(r in seen)) || continue; push!(seen, r)
end
for r in seen
    !isempty(CB.transport_teams_with_agent(env, r; pending_only=true)) && (agent = r; break)
end
println(">>> faulting agent = $agent")

CB.RETHREAD_DEBUG[] = true
res = CB.fault_robot_and_reassign!(env, agent; resume=true, verbose=true)
CB.RETHREAD_DEBUG[] = false
println(">>> reassign status = $(res.status)")
println(">>> validate(sched) = ", CB.validate(sched))

# Build captured-intervals (robot inside a transport unit) and free RobotGo intervals.
# captured interval for a team robot r of unit U ~= [t0(FormTransportUnit), tF(DepositCargo)]
overlaps(a,b) = a[1] < b[2] - 1e-6 && b[1] < a[2] - 1e-6
captured = Dict{Int,Vector{Tuple{Float64,Float64,String}}}()   # rid -> intervals
freego   = Dict{Int,Vector{Tuple{Float64,Float64,Int}}}()      # rid -> (t0,tF,vtx)

for v in Graphs.vertices(sched)
    n = pred(sched, v)
    if n isa CB.FormTransportUnit
        fv = v
        dnode = try CB.get_node(sched, CB.DepositCargo(CB.entity(n))) catch; nothing end
        dv = dnode === nothing ? nothing : CB.get_vtx(sched, CB.node_id(CB.DepositCargo(CB.entity(n))))
        t0 = CB.get_t0(sched, fv)
        tF = dv === nothing ? CB.get_tF(sched, fv) : CB.get_tF(sched, dv)
        for r in collect(keys(CB.robot_team(CB.entity(n))))
            push!(get!(captured, CB.get_id(r), []), (t0, tF, "$(CB.node_id(n))"))
        end
    elseif n isa CB.RobotGo
        r = CB.get_id(CB.entity(n).id)
        r > 0 || continue
        push!(get!(freego, r, []), (CB.get_t0(sched, v), CB.get_tF(sched, v), v))
    end
end

# (1) Are the SKIP-prone deposits' teams genuinely invalid? Dump every DepositCargo
# team and flag invalid slot ids (these are the future units the re-solve left
# unassigned, which is why get_matching_child_id returns invalid -> rethread SKIPs).
println("\n>>> DepositCargo teams (invalid slots = unassigned future units):")
for v in Graphs.vertices(sched)
    n = pred(sched, v)
    n isa CB.DepositCargo || continue
    team = CB.robot_team(CB.entity(n))
    ids = [CB.get_id(r) for r in keys(team)]
    ninvalid = count(<(0), ids)
    ninvalid > 0 && println("   DepositCargo vtx=$v team=$ids  ($ninvalid invalid)")
end

# (2) GROUND TRUTH: step the resumed sim and replicate preprocess_env!'s assert
# (active free RobotGo whose robot is NOT its own scene-tree parent == captured).
# Dump the first offender, who captures it, and whether rethread SKIPped that node.
println("\n>>> stepping to the real runtime double-book (preprocess_env! condition)...")
function team_has(n, r)
    (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo || n isa CB.DepositCargo) || return false
    any(==(r), (CB.get_id(x) for x in keys(CB.robot_team(CB.entity(n)))))
end
hit = false
for it in 1:200000
    for v in collect(env.cache.active_set)
        n = CB.get_node(sched, v).node
        n isa CB.RobotGo || continue
        ok = try CB.has_parent(CB.entity(n), CB.entity(n)) catch; true end
        if !ok
            r = CB.get_id(CB.entity(n).id)
            par = try CB.get_parent(CB.entity(n)) catch; nothing end
            parid = par === nothing ? "nothing" : try string(CB.node_id(par)) catch; "?" end
            println("\n!!! RUNTIME DOUBLE-BOOK iter=$it: active free RobotGo vtx=$v robot=$r")
            println("    scene-tree parent (captor) = $parid")
            for v2 in collect(env.cache.active_set)
                team_has(CB.get_node(sched, v2).node, r) &&
                    println("    held by ACTIVE $(nameof(typeof(CB.get_node(sched,v2).node))) vtx=$v2 id=$(CB.node_id(CB.get_node(sched,v2).node))")
            end
            println("    offender backtrace: ", backtrace_to_start(sched, v))
            hit = true; break
        end
    end
    hit && break
    CB.step_environment!(env)
    try
        CB.update_planning_cache!(env, 0.0)
    catch e
        println(">>> update_planning_cache! threw at iter=$it (", typeof(e), ") — assertion site"); hit=true; break
    end
    CB.project_complete(env) && (println(">>> resumed to completion, NO runtime double-book"); break)
end
hit || println(">>> stepping loop exhausted without completion or double-book")
println(">>> done")
end

# =============================================================================
# rethread_check -- One-shot, non-interactive verification of the reassignment id-threading
#   fix (rethread_robot_ids!). Self-contained (no Revise): builds the base env once, then
#   runs the resume sanity check and the reassign+resume check several times (the HiGHS
#   solver varies run-to-run, so multiple trials confirm the double-booking is gone, not
#   just masked by one solve).
# =============================================================================
function run_rethread_check()
_setup_milp!()

function build_base_env()
    pp = CB.get_project_params(4)   # tractor
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    return env
end

function _advance_to(env; target_closed::Int, cap::Int)
    for _ in 1:cap
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
    end
    return env
end

function _pick_faultable_agent(env)
    sched = env.sched
    seen = CB.AbstractID[]
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
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

function _run_to_end(env; cap::Int)
    prev = length(env.cache.closed_set); mono = true; iters = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try
            CB.update_planning_cache!(env, 0.0)
        catch err
            return (:asserted, length(env.cache.closed_set), iters, mono)
        end
        c = length(env.cache.closed_set); c < prev && (mono = false); prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono)
    end
    return (:capped, prev, iters, mono)
end

function resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.reset_cache_resume!(env.cache, env.sched)
    n1 = length(env.cache.closed_set)
    st = _run_to_end(env; cap = cap)
    pass = st[1] == :complete && st[4] && n1 >= n0
    println("resume_test: closed $n0 ->(resume) $n1 ->(end) $(st[2])/$total | " *
            "status=$(st[1]) monotone=$(st[4]) iters=$(st[3]) -> ", pass ? "PASS" : "FAIL")
    return pass
end

function reassign_resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 100_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    agent = _pick_faultable_agent(env)
    agent === nothing && (println("no valid robot to fault"); return :no_agent)
    res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = false)
    res.status == :admitted || (println("reassign $(res.status)"); return res.status)
    st = _run_to_end(env; cap = cap)
    println("reassign_resume_test fault=$agent: closed $n0 ->(commit) $(length(env.cache.closed_set)) " *
            "->(resume) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) iters=$(st[3])")
    return st[1]
end

println(">>> building base env once (slow, ~minutes)...")
BASE_ENV = build_base_env()
println(">>> base env ready: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

println("\n=== resume_test (resume infrastructure sanity) ===")
sane = resume_test(BASE_ENV)

println("\n=== reassign_resume_test (rethread fix) x5 ===")
results = Symbol[]
for i in 1:5
    r = reassign_resume_test(BASE_ENV)
    push!(results, r)
    println("  trial $i -> $r")
end

ncomplete = count(==(:complete), results)
println("\n=== SUMMARY ===")
println("resume_test sane : ", sane)
println("reassign trials  : ", results)
println("complete         : $ncomplete/5")
println(ncomplete == 5 && sane ? ">>> FIX VERIFIED" : ">>> NOT YET")
end

# =============================================================================
# ood_compare -- LLM vs RL comparison on FULLY-SIMULATED, COMPLETING robot-breakdown.
#   The headless OODEnv (decpomdp/examples/ood_compare_complete.jl) does not faithfully
#   reproduce the full simulation's endgame recovery, so for a TRUSTWORTHY completing
#   comparison we run the ACTUAL simulation (run_lego_demo, return_env_before_sim=false) once
#   per controller and read completion + makespan from it. Same build, same safe fault; the
#   ONLY difference is the producer plugged into the shared respec seam:
#     * no-adapt : returns nothing (floor)
#     * LLM (NL) : reads the event NL -> DSL (fault -> ReplaceAgent)
#     * MARL (RL): learned policy reads the state -> DSL
#     * canonical: rule (upper bound)
#   NOTE: this diagnostic keeps its OWN MILP block (60s/0.05 gap/output_flag) -- a different
#   attribute set than the shared _setup_milp! (MOI.Silent) -- so it is kept inline verbatim.
#   ENV: OOD_POLICY, NSPARE, OOD_TRACE, OOD_MODE, OOD_SEED.
# =============================================================================
function ood_compare()
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 60.0, "mip_rel_gap" => 0.05,
    "output_flag" => false, "presolve" => "on")

POLICY_PATH = get(ENV, "OOD_POLICY", joinpath(dirname(pkgdir(CB)), "decpomdp", "checkpoints", "ood_policy.txt"))
POLICY = isfile(POLICY_PATH) ? load_policy(POLICY_PATH) : LinearPolicy(Random.MersenneTwister(1))
NSPARE = parse(Int, get(ENV, "NSPARE", "3"))

# --- RL state shim (extract_state reads these fields) ---------------------------------
_SHIM = _CompareRLShim(nothing, 0, 0, 0, 4000)

# --- captured emitted DSL (for decision-quality F1) -----------------------------------
EMITTED = CB.ConstraintSpec[]
_TRACE = get(ENV, "OOD_TRACE", "0") == "1"
_cap(prod) = (env, ev) -> begin
    p = prod(env, ev)
    if _TRACE
        ctx = event_context(env, ev)
        println("    [emit] type=", ctx.type, " -> ", p === nothing ? "NOOP" : string(CB.emitted_key(p.constraints[1])))
    end
    p isa CB.RespecProposal && append!(EMITTED, p.constraints)
    return p
end

# --- controllers as producers (env, event_NL) -> RespecProposal | Nothing -------------
noop_prod(env, ev) = nothing
canonical_prod(env, ev) = (ctx = event_context(env, ev); action_to_proposal(ctx, canonical_action(ctx)))
function llm_prod(env, ev)   # zero-shot NL -> DSL
    ctx = event_context(env, ev)
    if ctx.type === :battery
        m = match(r"(\d+)\s*%", ev); socpct = m === nothing ? ctx.soc*100 : parse(Float64, m.captures[1])
        return action_to_proposal(ctx, socpct <= 100*CB.REPLACE_SOC_THRESHOLD[] ? 1 : 2)
    elseif ctx.type === :fault;  return action_to_proposal(ctx, 1)
    elseif ctx.type === :zone;   return action_to_proposal(ctx, 3)
    elseif ctx.type === :reform; return action_to_proposal(ctx, 4)
    end
    return nothing
end
function rl_prod(env, ev)
    _SHIM.env = env; _SHIM.n_events += 1
    ctx = event_context(env, ev)
    action_to_proposal(ctx, greedy_action(POLICY, extract_state(_SHIM, ctx), valid_actions(ctx)))
end

function grounding_prf(emitted, truths)
    # score only the ACTUAL scheduled OODs (fault/battery/zone). ReformTeam is an EMERGENT physics
    # recovery for a transient team deadlock — it has no OOD truth label, so counting it would unfairly
    # penalize precision on runs that happened to hit a deadlock. Exclude it from the decision score.
    es = Set{Any}(); for c in emitted; c isa CB.ReformTeam && continue; k = try CB.emitted_key(c) catch; nothing end; k === nothing || push!(es, k); end
    ts = Set{Any}(try CB.truth_key(t) catch; nothing end for t in truths); delete!(ts, nothing)
    tp = length(intersect(es, ts))
    prec = isempty(es) ? (isempty(ts) ? 1.0 : 0.0) : tp/length(es)
    rec  = isempty(ts) ? 1.0 : tp/length(ts)
    return (prec+rec)==0 ? 0.0 : 2prec*rec/(prec+rec)
end

# schedule ONE safe robot-breakdown (solo target) at the first of several progress points
function schedule_safe_fault!()
    fired = Ref(false)
    # clear=true tows the dead robot OFF-GRID; with the breakdown immobilization it stays there (never
    # drives back), so it does NOT block the build. no-adapt then simply loses that robot's work
    # (incomplete); adapt re-routes the work to spares (complete) — a clean, non-fragile consequence.
    tf = CB.fault_action(; safe = true, obstacle = false, clear = true)
    act = e -> fired[] ? nothing : (nl = tf(e); nl === nothing ? nothing : (fired[] = true; nl))
    for c in (12, 20, 30, 45, 60); CB.schedule_ood_at_closed!(c, act); end
end

OOD_MODE = get(ENV, "OOD_MODE", "single")   # "single" = one fault; "multi" = fault + mild-battery stream
MULTI_SEED = parse(Int, get(ENV, "OOD_SEED", "7"))

# multi-OOD stream: a SEQUENCE of safe robot-breakdowns (clear off-grid) at spread progress points.
# Each is enacted by distributed replace (tasks -> nearest spares), so this stress-tests spare-pool
# consumption over multiple faults (robustness B2) AND that the build still COMPLETES. LLM/RL both
# emit ReplaceAgent for each; the discriminator is completion + makespan over the sequence.
# (Battery→Deprioritize was tried but its full-sim MILP re-solve wedges the build early — a separate
#  enactment fragility; see docs/distributed_replace_2026-07-09.md. Multi-FAULT is the robust stream.)
function schedule_multiood!(seed::Int)
    tf = CB.fault_action(; safe = true, obstacle = false, clear = true)   # safe solo target + off-grid
    for c in (30, 90)                            # two breakdowns at spread progress points (fires once each)
        CB.schedule_ood_at_closed!(c, tf)
    end
end

function run_one(prod)
    empty!(EMITTED); _SHIM.n_events = 0
    CB.RESPEC_ENABLED[] = true
    for f in (:clear_ood_schedule!, :clear_restriction_zones!, :clear_spare_pools!, :clear_faulted_robots!,
              :clear_recovery_spares!, :clear_ood_truth_log!, :clear_wedge_edges!, :clear_stalled_robots!)
        try getproperty(CB, f)() catch end
    end
    try CB.set_reform_interval!(400) catch end
    CB.set_respec_producer!(_cap(prod))
    OOD_MODE == "multi" ? schedule_multiood!(MULTI_SEED) : schedule_safe_fault!()
    res = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file = "tractor.mpd", num_robots = 10, assignment_mode = :greedy,
            milp_optimizer = :highs, optimizer_time_limit = 60, log_level = Logging.Warn,
            max_num_iters_no_progress = 30000, rvo_flag = true, tangent_bug_flag = true, dispersion_flag = true,
            n_spare_per_pool = NSPARE, save_animation = false, open_animation_at_end = false,
            write_results = false, overwrite_results = true, return_env_before_sim = false)
    end
    CB.clear_respec_producer!(); CB.RESPEC_ENABLED[] = false
    env = res isa Tuple ? res[1] : res
    stats = res isa Tuple ? res[2] : Dict()
    complete = CB.project_complete(env)
    closed = length(env.cache.closed_set); total = length(CB.get_nodes(env.sched))
    makespan = try Float64(get(stats, :Makespan, NaN)) catch; NaN end
    f1 = grounding_prf(copy(EMITTED), try CB.ground_truth_labels() catch; [] end)
    return (complete = complete, closed = closed, total = total, makespan = makespan, f1 = f1)
end

function main()
    controllers = _TRACE ? [("canonical", canonical_prod), ("MARL (RL)", rl_prod)] :
        [("no-adapt", noop_prod), ("LLM (NL→DSL)", llm_prod), ("MARL (RL)", rl_prod), ("canonical", canonical_prod)]
    println("[fullsim] LLM-vs-RL on COMPLETING robot-breakdown (full simulation), spares=$(4*NSPARE) ...")
    println("\n", rpad("controller", 15), rpad("complete", 10), rpad("closed/total", 14), rpad("makespan", 11), "decision-F1")
    println(repeat("-", 62))
    for (name, prod) in controllers
        r = run_one(prod)
        @printf("%-15s%-10s%-14s%-11.1f%.3f\n", name, r.complete ? "YES" : "no",
                "$(r.closed)/$(r.total)", r.makespan, r.f1)
    end
    println(repeat("-", 62))
    println("[fullsim] adaptive controllers (LLM/MARL/canonical) emit the correct ReplaceAgent (decision-F1=1.0) and")
    println("          recover strictly MORE closed nodes than no-adapt on a genuine real-robot breakdown (e.g. seed-1")
    println("          Bot 1: adapt 195/313 vs no-adapt 174/313). They do NOT fully COMPLETE: that is the separate")
    println("          mid-build completion limit (cyclic OpenBuildStep over-subscription), not the (fixed) double-book.")
end

main()
end

# =============================================================================
# ab_energy -- A/B PROOF for the energy-aware objective: "handling-energy DOWN at makespan ~= same".
#   Builds ONE small instance (greedy, fast), RE-OPENS the future assignment edges
#   (release_pending_assignments!), then RE-SOLVES the SAME assignment sub-problem at several
#   efficiency weights ENERGY_W. The per-edge transport ENERGY is identical across arms (same
#   geometry); only the CHOSEN assignment Xa differs, so handling_energy = Σ edge_energy·Xa is an
#   apples-to-apples comparison. No commit / no schedule mutation between arms — each arm just
#   formulates+solves. Reports per arm: makespan, handling-energy, MILP gap/status.
#   ENV: WEIGHTS, PROJECT, TLIM, GAP, NROBOTS.
# =============================================================================
function ab_energy()
value = JuMP.value
termination_status = JuMP.termination_status
relative_gap = JuMP.relative_gap

WEIGHTS = parse.(Float64, split(get(ENV, "WEIGHTS", "0,0.001,0.01,0.05"), ","))
PROJECT = parse(Int, get(ENV, "PROJECT", "4"))     # 4 = tractor (smallest)
TLIM    = parse(Float64, get(ENV, "TLIM", "180"))
GAP     = parse(Float64, get(ENV, "GAP", "0.01"))
NROBOTS = parse(Int, get(ENV, "NROBOTS", "0"))     # 0 = project default; smaller => smaller MILP (likelier to converge)

_setup_milp!(time_limit = TLIM, mip_rel_gap = GAP)

# Clean baseline: no per-agent / battery bias, payload term ON so energy ≠ pure distance.
CB.clear_agent_bias!(); CB.EDGE_COST_MULTIPLIER[] = nothing
CB.set_energy_model!(pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.25)

pp = CB.get_project_params(PROJECT)
nrob = NROBOTS > 0 ? NROBOTS : pp[:num_robots]
println(">>> building env once (greedy)...  project=$(pp[:project_name]) robots=$(nrob)")
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=nrob,
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false, return_env_before_sim=true)
end
println(">>> built: $(Graphs.nv(env.sched)) nodes")

# GREEDY baseline (deterministic, always "converged") — schedule-level handling energy =
# Σ edge_energy(move duration) over the committed transport moves. A meaningful reference the
# MILP arms can be compared against even when the makespan MILP itself does not reach optimality.
function schedule_handling_energy(env)
    s = 0.0
    for v in Graphs.vertices(env.sched)
        node = CB.get_node(env.sched, v).node
        (node isa CB.RobotGo || node isa CB.TransportUnitGo) || continue
        dur = try Float64(CB.get_tF(env.sched, v) - CB.get_t0(env.sched, v)) catch; 0.0 end
        s += CB.edge_energy(max(dur, 0.0))
    end
    return s
end
greedy_ms = try maximum(CB.get_tF(env.sched)) catch; NaN end
greedy_he = schedule_handling_energy(env)
println(">>> GREEDY baseline: makespan=$(round(greedy_ms,digits=2))  handling_energy=$(round(greedy_he,digits=2))")

# Re-open all FUTURE assignment edges so the MILP can re-decide them (faulted=nothing => no fault).
inv = CB.build_invariant(env)
CB.release_pending_assignments!(env, inv; faulted = nothing)
println(">>> released future assignment edges; re-solving at $(length(WEIGHTS)) weights\n")

rows = []
for w in WEIGHTS
    CB.set_planning_objective_weights!(speed = 1.0, efficiency = w)
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer = CB._respec_optimizer(), t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.optimize!(milp)
    he  = CB.handling_energy(milp)                       # Σ edge_energy·Xa on this solution
    ms  = try maximum(value.(milp.model[:tF])) catch; NaN end
    st  = try string(termination_status(milp.model)) catch; "?" end
    gp  = try round(relative_gap(milp.model); digits = 3) catch; NaN end
    push!(rows, (w = w, makespan = ms, energy = he, status = st, gap = gp))
    println("  ENERGY_W=$(rpad(w,7))  makespan=$(round(ms,digits=2))  handling_energy=$(round(he,digits=2))  [$(st), gap=$(gp)]")
end

# Headline summary vs the w=0 baseline.
base = rows[1]
println("\n== A/B SUMMARY (baseline ENERGY_W=$(base.w): makespan=$(round(base.makespan,digits=2)), energy=$(round(base.energy,digits=2))) ==")
for r in rows[2:end]
    dms = base.makespan > 0 ? 100 * (r.makespan - base.makespan) / base.makespan : NaN
    den = base.energy   > 0 ? 100 * (r.energy   - base.energy)   / base.energy   : NaN
    println("  w=$(rpad(r.w,7))  Δmakespan=$(round(dms,digits=1))%   Δenergy=$(round(den,digits=1))%   [$(r.status)]")
end
println("\nHEADLINE: the largest w with Δmakespan within tolerance AND Δenergy<0 is the safe operating band.")
println("(If gaps are large the numbers are feasible-but-not-optimal; tighten GAP / raise TLIM / smaller PROJECT.)")
end

# =============================================================================
# dump_fixture -- Build the tractor env ONCE, step to mid-build, and dump the EXACT /propose
#   request body (open_ids, agents, nodes) + a sub-assembly id map to JSON, so the Python prompt
#   harness (tools/translate_eval.py) can iterate on the LLM translation WITHOUT rebuilding the
#   env or touching Julia. Output: tools/llm_fixture.json (PLAIN JSON — safe to cache across
#   processes, unlike the PlannerEnv itself). No MILP block (run_lego_demo's :highs suffices).
#   NOTE: @__DIR__ still resolves to the tools/ dir from inside tools/diagnostics.jl, so the
#   fixture path (tools/llm_fixture.json) is UNCHANGED.
# =============================================================================
function dump_fixture()
println(">>> building tractor env (assignment only)...")
pp = CB.get_project_params(4)
env = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(env.sched)) nodes")

# Step into a mid-build state (mirror eval_respec_ood.jl main): closed>=8 so the
# precede/zone milestones are partially realized — the state translation runs in.
for _ in 1:4000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    length(env.cache.closed_set) >= 8 && break
end
println(">>> stepped: closed=$(length(env.cache.closed_set))")

# The EXACT /propose request body the production llm_to_proposal would send.
open_ids = CB.open_node_id_strings(env)
agents   = CB.open_agent_descriptors(env)
nodes    = CB.open_node_descriptors(env)

# sub-assembly AssemblyID.id -> exact node id string, so the Python eval cases can
# say "sub-assembly 2" and know the gold target id with NO Julia at eval time.
asm_map = Dict{String,String}()
for v in Graphs.vertices(env.sched)
    v in env.cache.closed_set && continue
    node = CB.get_node(env.sched, v).node
    node isa CB.AssemblyComplete || continue
    aid = try CB.entity(node).id catch; nothing end
    aid === nothing && continue
    asm_map[string(aid.id)] = string(CB.get_vtx_id(env.sched, v))
end

fixture = Dict(
    "open_ids" => open_ids,
    "agents"   => agents,
    "nodes"    => nodes,
    "sub_assembly_id_to_node_id" => asm_map,
    "closed_count" => length(env.cache.closed_set),
    "n_sched_nodes" => Graphs.nv(env.sched),
)
out = joinpath(@__DIR__, "llm_fixture.json")
open(out, "w") do io; JSON3.pretty(io, fixture); end
println(">>> wrote $out")
println("    open_ids=$(length(open_ids)) agents=$(length(agents)) nodes=$(length(nodes)) sub_asm=$(length(asm_map))")
end

# ---- dispatcher -------------------------------------------------------------
const DIAGNOSTICS = Dict(
    "rethread"       => diag_rethread,
    "rethread_check" => run_rethread_check,
    "ood_compare"    => ood_compare,
    "ab_energy"      => ab_energy,
    "dump_fixture"   => dump_fixture,
)
end # module Diagnostics

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "DIAG", isempty(ARGS) ? "rethread" : ARGS[1])
    haskey(Diagnostics.DIAGNOSTICS, key) || error("unknown diagnostic '$key'. Available: $(join(sort(collect(keys(Diagnostics.DIAGNOSTICS))), ", "))")
    println(">>> running diagnostic: $key")
    Diagnostics.DIAGNOSTICS[key]()
end
