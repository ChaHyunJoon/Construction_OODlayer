# =============================================================================
# eval_respec_ood.jl  --  Per-OOD-class reliability eval of the LLM respec layer.
#
# Scores, for each OOD case, TWO axes (see src/respec/ood_eval_design_2026-06-19.md):
#   (a) TRANSLATION  -- did the LLM emit the expected DSL kind + the expected id?
#   (b) BEHAVIOR     -- does executing the emitted spec satisfy the gold predicates?
# Gold predicates come from an LLM-FREE oracle (the hand-driven reference path), so
# we never grade the model against itself. Correctness is binary; quality (makespan)
# is reported separately. The LLM is stochastic, so each event is sampled N times.
#
# Prereq: the Python LLM service must be running (ANTHROPIC_API_KEY) -- see the
# header of test_respec_e2e.jl.
# Run:  julia +lts --project=. eval_respec_ood.jl
# =============================================================================
using ConstructionBots
import Graphs
import HiGHS
import Logging
import LazySets
const CB = ConstructionBots

# Feasibility-first re-solve (return first feasible integer soln; reliable & fast),
# silent solver. Identical to the reassign / e2e tests.
CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0,
    CB.MOI.Silent() => true)

# ---------------------------------------------------------------------------
# Case spec
# ---------------------------------------------------------------------------
Base.@kwdef struct OODEvalCase
    id::String
    klass::Symbol
    events::Vector{String}                       # NL paraphrases of the SAME event
    pick_target::Function                         # env -> AbstractID (ground-truth ref)
    expected_kind::Type                           # ForbidAgent / Deadline / ...
    gold_runner::Function                         # (env, target) -> outcome  (LLM-FREE)
    predicates::Vector{Pair{String,Function}}     # name => (env_after, target) -> Bool
end

# ---------------------------------------------------------------------------
# Build the base env ONCE; each trial runs on a deepcopy (rebuilding is minutes).
# ---------------------------------------------------------------------------
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

function build_eval_env()
    pp = CB.get_project_params(4)   # tractor
    run_with_stack(2_000_000_000) do
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

# ---------------------------------------------------------------------------
# LLM-driven candidate: translate the NL event, then APPLY it exactly as the
# production maybe_respecify! dispatch does. Returns (proposal, status).
# ---------------------------------------------------------------------------
function llm_candidate!(env, event)
    proposal = CB.llm_to_proposal(event, env;
        id_resolver = ref -> CB._default_id_resolver(env, ref))
    inv = CB.build_invariant(env)
    if CB._is_robot_fault(proposal)
        res = CB.fault_robot_and_reassign!(env, proposal.constraints[1].agent; verbose=false)
        return (proposal, res.status)
    end
    return (proposal, commit_proposal!(env, proposal, inv))
end

# Generic verify + commit (NO robot-fault dispatch). Shared by the LLM-driven
# generic path above and the LLM-FREE gold runners (Deadline/Precede/ForbidWindow).
function commit_proposal!(env, proposal, inv = CB.build_invariant(env))
    verdict = CB.verify(proposal, env, inv)
    verdict isa CB.Admit || return :rejected
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
        extra_constraints=verdict.proposal)
    CB.optimize!(milp)
    CB.update_project_schedule!(nothing, milp, env.sched, env.scene_tree)
    CB.reset_cache!(env.cache, env.sched)
    return :admitted
end

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
# A constraint can reference more than one id (Precede has two), so the target is a
# TUPLE. Single-target cases let pick_target return a bare id; _astuple normalises.
_spec_targets(c::CB.ForbidAgent)  = (c.agent,)
_spec_targets(c::CB.Deadline)     = (c.node,)
_spec_targets(c::CB.ForbidWindow) = (c.node,)
_spec_targets(c::CB.Precede)      = (c.a, c.b)
_astuple(x) = x isa Tuple ? x : (x,)

function score_translation(proposal, case, target)
    cs = proposal.constraints
    if target isa Set                      # multi-node case (e.g. zone closure)
        kind_ok = !isempty(cs) && all(c -> c isa case.expected_kind, cs)
        got = Set(_spec_targets(c)[1] for c in cs if c isa case.expected_kind)
        return (kind_ok = kind_ok, target_ok = kind_ok && got == target)
    end
    kind_ok = length(cs) == 1 && cs[1] isa case.expected_kind
    target_ok = kind_ok && _spec_targets(cs[1]) == _astuple(target)
    return (kind_ok = kind_ok, target_ok = target_ok)
end

score_behavior(env_after, case, target) =
    [name => f(env_after, target) for (name, f) in case.predicates]

# ---------------------------------------------------------------------------
# Run one case: first sanity-check the LLM-FREE gold achieves its own predicates,
# then grade each NL paraphrase x sample against them.
# ---------------------------------------------------------------------------
function run_case(case::OODEvalCase, base_env; n_samples::Int = 2)
    println("\n================  CASE $(case.id)  [$(case.klass)]  ================")

    # --- gold sanity: the LLM-free oracle must satisfy its own predicates --------
    gold_env = deepcopy(base_env)
    gtarget  = case.pick_target(gold_env)
    case.gold_runner(gold_env, gtarget)
    gold_preds = score_behavior(gold_env, case, gtarget)
    gold_ok = all(p -> p.second, gold_preds)
    println("GOLD (LLM-free) predicates: ", gold_ok ? "ALL PASS ✓" : "FAIL ✗")
    for (n, ok) in gold_preds; println("   [$(ok ? "✓" : "✗")] $n"); end
    gold_ok || @warn "gold oracle does not satisfy its predicates — case is ill-formed!"

    # --- LLM candidates ----------------------------------------------------------
    rows = NamedTuple[]
    for event in case.events, s in 1:n_samples
        env = deepcopy(base_env)
        target = case.pick_target(env)
        kind_ok = false; target_ok = false; beh_ok = false; status = :error; preds = Pair[]
        try
            proposal, status = llm_candidate!(env, event)
            tr = score_translation(proposal, case, target)
            kind_ok, target_ok = tr.kind_ok, tr.target_ok
            preds = score_behavior(env, case, target)
            beh_ok = !isempty(preds) && all(p -> p.second, preds)
        catch err
            status = :error
            println("   trial errored: ", first(split(sprint(showerror, err), "\n")))
        end
        push!(rows, (event=event, kind=kind_ok, target=target_ok, behavior=beh_ok, status=status))
        println("  [kind $(kind_ok ? "✓" : "✗") | target $(target_ok ? "✓" : "✗") | behavior $(beh_ok ? "✓" : "✗") | $status]  \"$(first(event, 60))...\"")
    end

    n = length(rows)
    pct(f) = "$(count(f, rows))/$n"   # count needs the collection, not just the predicate
    println("---- $(case.id) summary over $n trials ----")
    println("  translation kind   : ", pct(r -> r.kind))
    println("  translation target : ", pct(r -> r.target))
    println("  behavior (gold pred): ", pct(r -> r.behavior))
    return rows
end

# ---------------------------------------------------------------------------
# CASE 1 — robot fault -> ForbidAgent -> reassign
# ---------------------------------------------------------------------------
function robot_fault_case()
    # Behavioral gold predicates (mirror test_respec_reassign.jl asserts).
    freed = (env, rid) -> isempty(CB.transport_teams_with_agent(env, rid; pending_only=true))
    valid = (env, _)   -> CB.validate(env.sched)
    finite = (env, _)  -> isfinite(CB.makespan(env.sched))
    staffed = function (env, _)
        for v in Graphs.vertices(env.sched)
            CB.matches_template(CB.FormTransportUnit, CB.get_node(env.sched, v)) || continue
            node = CB.get_node(env.sched, v).node
            need = length(CB.robot_team(CB.entity(node)))
            have = count(vp -> CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, vp)) isa CB.RobotGo,
                         Graphs.inneighbors(env.sched, v))
            have >= need || return false
        end
        return true
    end
    OODEvalCase(
        id = "robot_fault_basic",
        klass = :ForbidAgent,
        events = [
            "Robot R3 reports a motor fault and is immobile and cannot perform any task.",
            "We just lost robot 3 — it's stuck and won't move, so take it out of the plan.",
            "R3 has broken down and is unavailable for the rest of the build.",
        ],
        pick_target = env -> CB.RobotID(3),
        expected_kind = CB.ForbidAgent,
        gold_runner = (env, target) -> CB.fault_robot_and_reassign!(env, target; verbose=false),
        predicates = [
            "faulted robot on 0 pending transport teams" => freed,
            "schedule valid"                              => valid,
            "makespan finite"                             => finite,
            "all transport tasks fully staffed"           => staffed,
        ],
    )
end

# ---------------------------------------------------------------------------
# CASE 2 — rush / expedite order -> Deadline on a named assembly milestone
# NOTE: with a generous (non-binding) deadline the BEHAVIOR predicates can't tell
# right-node from wrong-node grounding (the whole build finishes < T regardless),
# so for Deadline the GROUNDING signal is the translation-target score; behavior
# just confirms the spec executed feasibly. (See ood_eval_design doc.)
# ---------------------------------------------------------------------------
function deadline_case()
    DEADLINE_T = 100.0
    find_root = function (env)
        for v in Graphs.vertices(env.sched)
            node = CB.get_node(env.sched, v).node
            node isa CB.AssemblyComplete || continue
            any(vp -> CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, vp)) isa CB.ProjectComplete,
                Graphs.outneighbors(env.sched, v)) && return CB.get_vtx_id(env.sched, v)
        end
        error("no root AssemblyComplete found")
    end
    OODEvalCase(
        id = "deadline_final_assembly",
        klass = :Deadline,
        events = [
            "The final tractor assembly must be completed no later than time 100.",
            "Operations note: we need the whole build (the root assembly) finished by t=100 at the latest.",
            "Customer escalation — the final assembly is due by time 100, please prioritize it.",
        ],
        pick_target = find_root,
        expected_kind = CB.Deadline,
        gold_runner = (env, target) ->
            commit_proposal!(env, CB.RespecProposal([CB.Deadline(target, DEADLINE_T)])),
        predicates = [
            "deadline node finishes by T" =>
                (env, tgt) -> CB.get_tF(env.sched, CB.get_vtx(env.sched, tgt)) <= DEADLINE_T + 1e-3,
            "schedule valid"  => (env, _) -> CB.validate(env.sched),
            "makespan finite" => (env, _) -> isfinite(CB.makespan(env.sched)),
        ],
    )
end

# ---------------------------------------------------------------------------
# CASE 3 — defect / rework -> Precede (a finishes before b starts). TWO targets.
# ---------------------------------------------------------------------------
function precede_case()
    find_asm = function (env, n)            # sub-assembly whose AssemblyID.id == n
        for v in Graphs.vertices(env.sched)
            node = CB.get_node(env.sched, v).node
            node isa CB.AssemblyComplete || continue
            (try CB.entity(node).id.id catch; nothing end) == n && return CB.get_vtx_id(env.sched, v)
        end
        error("no sub-assembly $n")
    end
    A, B = 2, 4                              # rework A before starting B
    OODEvalCase(
        id = "precede_rework",
        klass = :Precede,
        events = [
            "Sub-assembly 2 failed quality inspection and must be reworked and completed before sub-assembly 4 is started.",
            "QC flagged a defect in sub-assembly 2 — finish redoing it before any work begins on sub-assembly 4.",
            "Hold sub-assembly 4 until sub-assembly 2 (which needs rework) is fully complete.",
        ],
        pick_target = env -> (find_asm(env, A), find_asm(env, B)),
        expected_kind = CB.Precede,
        gold_runner = (env, target) ->
            commit_proposal!(env, CB.RespecProposal([CB.Precede(target[1], target[2])])),
        predicates = [
            "A finishes before B starts" =>
                (env, t) -> CB.get_tF(env.sched, CB.get_vtx(env.sched, t[1])) <=
                            CB.get_t0(env.sched, CB.get_vtx(env.sched, t[2])) + 1e-3,
            "schedule valid"  => (env, _) -> CB.validate(env.sched),
            "makespan finite" => (env, _) -> isfinite(CB.makespan(env.sched)),
        ],
    )
end

# ---------------------------------------------------------------------------
# CASE 4 — zone closure -> ForbidWindow on EVERY node in a spatial zone. The
# grounding test is SPATIAL: the model must map "the southern area" to the set of
# south-located assemblies (labelled with their staging direction). SET-valued
# target. NOTE: AssemblyComplete is an instantaneous milestone, so a window the
# nodes already avoid is non-binding → behavior can't tell right-set from wrong-set;
# the grounding signal is the translation-TARGET set-match. (See design doc.)
# ---------------------------------------------------------------------------
function zone_closure_case()
    T_LO, T_HI = 20.0, 50.0
    southset = function (env)
        s = Set{CB.AbstractID}()
        for v in Graphs.vertices(env.sched)
            node = CB.get_node(env.sched, v).node
            node isa CB.AssemblyComplete || continue
            aid = CB.entity(node).id
            haskey(env.staging_circles, aid) || continue
            Float64(LazySets.center(env.staging_circles[aid])[2]) < -0.2 &&
                push!(s, CB.get_vtx_id(env.sched, v))
        end
        return s
    end
    OODEvalCase(
        id = "zone_closure_south",
        klass = :ForbidWindow,
        events = [
            "A worker has entered the southern staging area. No assembly work may take place in the south between time 20 and time 50.",
            "Safety lockout: the south staging zone is closed from t=20 to t=50 — keep every southern assembly out of that window.",
            "There is a spill in the south area; nothing located in the south can be active between t=20 and t=50.",
        ],
        pick_target = southset,
        expected_kind = CB.ForbidWindow,
        gold_runner = (env, zone) ->
            commit_proposal!(env, CB.RespecProposal([CB.ForbidWindow(id, T_LO, T_HI) for id in zone])),
        predicates = [
            "all south nodes avoid [t_lo,t_hi]" =>
                (env, zone) -> all(zone) do id
                    v = CB.get_vtx(env.sched, id)
                    CB.get_tF(env.sched, v) <= T_LO + 1e-3 || CB.get_t0(env.sched, v) >= T_HI - 1e-3
                end,
            "schedule valid"  => (env, _) -> CB.validate(env.sched),
            "makespan finite" => (env, _) -> isfinite(CB.makespan(env.sched)),
        ],
    )
end

function main()
    if !CB.respec_service_ready()
        println("!!! Python LLM service not reachable at $(CB._RESPEC_SERVICE_URL). " *
                "Start it (see test_respec_e2e.jl header) and re-run.")
        return
    end
    println(">>> building base env (assignment only)...")
    base_env = build_eval_env()
    println(">>> base env: $(Graphs.nv(base_env.sched)) nodes")
    # Step into a mid-build state so the reassign exercises the freeze path too.
    for _ in 1:4000
        CB.step_environment!(base_env); CB.update_planning_cache!(base_env, 0.0)
        length(base_env.cache.closed_set) >= 8 && break
    end
    println(">>> stepped: closed=$(length(base_env.cache.closed_set))")

    cases = [robot_fault_case(), deadline_case(), precede_case(), zone_closure_case()]
    for c in cases
        run_case(c, base_env; n_samples = 2)
    end
    println("\n>>>>>>>>>>>>>>  OOD EVAL COMPLETE  <<<<<<<<<<<<<<")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
