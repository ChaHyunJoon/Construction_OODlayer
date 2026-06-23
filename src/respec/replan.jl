# =============================================================================
# replan.jl  --  Orchestration at the execution seam (demo_utils.jl:96)
# =============================================================================
#
#   generate-as-formal-spec  ->  verify  ->  admit  ->  re-solve  ->  resume
#
# This is the single function the simulation loop calls each step (cheaply: it
# returns immediately unless an OOD event is pending). It NEVER lets an
# unverified proposal reach the solver-of-record, and on ANY failure path it
# engages the safe fallback, so the solver's guarantees are preserved end to end.
# =============================================================================

"""
    OODQueue

Year-1 stub for the detection layer. For the MVP, scenario scripts push
structured event strings here; later this is replaced by the conformal-prediction
"abstain" trigger. `poll_ood!` pops at most one event per step.
"""
mutable struct OODQueue
    pending::Vector{String}
end
OODQueue() = OODQueue(String[])
poll_ood!(q::OODQueue) = isempty(q.pending) ? nothing : popfirst!(q.pending)

# -----------------------------------------------------------------------------
# Control layer wiring the respec hook into the simulation loop WITHOUT touching
# the SimParameters struct. The seam in simulate! (demo_utils.jl) calls
# `respec_step!(env)` every step; it is a true no-op unless RESPEC_ENABLED[] is
# set, so existing demos are completely unaffected by the hook's presence.
# -----------------------------------------------------------------------------

"Master on/off switch for the re-specification hook (default off)."
const RESPEC_ENABLED = Ref(false)

"Process-global OOD event queue the simulation seam drains each step."
const RESPEC_QUEUE = OODQueue()

"""
    push_ood!(event::AbstractString)

Enqueue an open-world event to be handled at the next simulation step. For the
MVP, scenario scripts call this to inject a fault/new-requirement; later the
Year-1 detection layer calls it. Returns the event for convenience.
"""
function push_ood!(event::AbstractString)
    push!(RESPEC_QUEUE.pending, String(event))
    return event
end

"""
    respec_step!(env) -> Symbol

The single call the simulation loop makes each step. No-op (`:disabled`) unless
the hook is enabled; otherwise drives generate→verify→admit→re-solve via
`maybe_respecify!`. Kept tiny so the per-step cost is ~zero when idle.
"""
function respec_step!(env)
    RESPEC_ENABLED[] || return :disabled
    return maybe_respecify!(env, RESPEC_QUEUE)
end

"""
    _is_robot_fault(proposal) -> Bool

True iff the proposal is exactly one `ForbidAgent` — i.e. "a robot became
unavailable". Such a re-spec MUST NOT take the generic compile+verify path:
`ForbidAgent`'s compiler needs the frozen/pinned frontier context AND the pending
assignment edges released first (both set up by `fault_robot_and_reassign!`).
Through the generic path it silently compiles to ZERO constraints (the frontier
is never located because RESPEC_FROZEN/PINNED are empty) — a *hollow admit* that
removes the robot from nothing. So we dispatch these to the reassign machinery.
"""
_is_robot_fault(p::RespecProposal) =
    length(p.constraints) == 1 && p.constraints[1] isa ForbidAgent

"""
    maybe_respecify!(env, ood_queue; id_resolver, optimizer) -> Symbol

Called once per sim step from `simulate!` right after `step_environment!`.
Returns one of: `:noop`, `:admitted`, `:rejected`, `:fallback`. The return value
is purely for logging; the world state is mutated in place on `:admitted`.
"""
function maybe_respecify!(env, ood_queue;
                          id_resolver = ref -> _default_id_resolver(env, ref),
                          optimizer   = _respec_optimizer())
    event = poll_ood!(ood_queue)
    event === nothing && return :noop

    @info "[RESPEC] OOD event: $event"
    invariant = build_invariant(env)              # freeze completed/active work

    # --- generate (LLM -> typed DSL). Any failure == reject == fallback. ------
    proposal = try
        llm_to_proposal(event, env; id_resolver = id_resolver)
    catch err
        @warn "[RESPEC] LLM/parse failure -> fallback" exception = err
        engage_fallback!(env)
        return :fallback
    end

    # --- robot fault: dispatch to the reassign machinery ----------------------
    # A ForbidAgent re-spec needs schedule surgery (release pending edges) + the
    # frozen/pinned context that the generic verify path does not establish.
    # fault_robot_and_reassign! does freeze -> release -> ForbidAgent -> verify ->
    # commit, and rejects to the safe fallback if the future is not re-solvable.
    if _is_robot_fault(proposal)
        agent = proposal.constraints[1].agent
        @info "[RESPEC] robot-fault re-spec -> reassign $(agent)"
        res = fault_robot_and_reassign!(env, agent; optimizer = optimizer)
        if res.status != :admitted
            @warn "[RESPEC] reassign $(res.status) -> fallback" detail = get(res, :detail, "")
            engage_fallback!(env)
        end
        return res.status
    end

    # --- verify (the gate; does the trial solve itself) -----------------------
    verdict = verify(proposal, env, invariant; optimizer = optimizer)
    if verdict isa Reject
        @warn "[RESPEC] proposal REJECTED ($(verdict.reason)): $(verdict.detail) -> fallback"
        engage_fallback!(env)
        return :rejected
    end

    # --- admit: commit the verified re-solve to the schedule of record --------
    milp = formulate_milp(
        SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer   = optimizer,
        t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF,
        extra_constraints = verdict.proposal,
    )
    optimize!(milp)
    if primal_status(milp) != MOI.FEASIBLE_POINT
        # Should not happen (verify already solved identical model) but never trust it.
        @warn "[RESPEC] committed solve disagreed with verifier -> fallback"
        engage_fallback!(env)
        return :fallback
    end

    update_project_schedule!(nothing, milp, env.sched, env.scene_tree)
    reset_cache!(env.cache, env.sched)
    @info "[RESPEC] ADMITTED $(verdict.n_constraints) constraint(s); schedule re-solved."
    return :admitted
end

"""
    engage_fallback!(env)

Year-2 stub for the certified safe-set / containment layer. For the MVP this is
the trivial recoverable action: hold all agents (line stop). When CBF/HJ
reachability lands, replace the body with "drive to the nearest point in the
forward-invariant safe set"; the call site does not change.
"""
function engage_fallback!(env)
    @warn "[RESPEC] FALLBACK engaged: holding all agents (line stop)."
    # TODO(week 5): set every active agent's preferred velocity to zero for this
    # and subsequent steps until cleared. Hook into the RVO pref-velocity reset
    # in step_environment! (route_planning.jl). For now a module flag the loop
    # reads — avoids touching the PlannerEnv struct definition / its constructor.
    RESPEC_HOLD[] = true
    return nothing
end

"Module-level fallback flag (stub for the Year-2 containment layer)."
const RESPEC_HOLD = Ref(false)

# Map a string node ref from the LLM back to a real schedule id. Built to MIRROR
# exactly how ids were stringified into the prompt (_build_prompt). Throwing here
# (unknown ref) is intentional -> treated as a reject.
function _default_id_resolver(env, ref::AbstractString)
    sched = env.sched
    for v in Graphs.vertices(sched)
        if string(get_vtx_id(sched, v)) == ref
            return get_vtx_id(sched, v)
        end
    end
    # Agent (robot) ids are NOT schedule vertex ids: a ForbidAgent needs a RobotID,
    # which lives on the entity of each RobotGo node, not in the vertex-id space.
    # Resolve those too, matching the exact string form open_agent_descriptors
    # exposed to the model (string(rid)), so a correctly-grounded ForbidAgent parses.
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue
        rid = try entity(node).id catch; nothing end
        rid isa RobotID || continue
        string(rid) == ref && return rid
    end
    error("LLM referenced unknown node/agent id: $ref")
end
