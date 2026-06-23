# =============================================================================
# reassign.jl  --  Robot-fault -> verified reassignment (the "automate the OOD
#                  action" capability the whole agentic-LLM layer exists for).
# =============================================================================
#
# A pure constraint-add (ForbidAgent alone) CANNOT reassign work: the patched
# formulate_milp forces every EXISTING edge to Xa==1, so each robot's chain is
# pinned and the faulted robot's orphaned slots can't be threaded into another
# robot's timeline without a cycle. Reassignment therefore needs exactly ONE
# schedule-surgery primitive beyond the DSL:
#
#   release_pending_assignments!  --  drop the *future* (non-frozen) assignment
#       edges so the solver is free to re-decide them, while every closed /
#       in-progress edge stays pinned (the past is invariant).
#
# After the release, the verified pipeline does the rest, untouched:
#   build_invariant -> ForbidAgent(faulted) -> verify (trial solve) -> admit
#   -> formulate_milp(SparseAdjacencyMILP; freeze + ForbidAgent) -> re-solve
#   -> update_project_schedule! (re-stamps robot ids via propagate_valid_ids!)
#   -> reset_cache!.
#
# The MILP/solver is never modified; it optimally re-solves the future with one
# fewer robot, honouring the freeze. If that future is not re-solvable (e.g. a
# collaborative team can no longer be staffed) the feasibility gate REJECTS and
# the caller engages the safe fallback. "Reassign when possible, safe-stop when
# not" — safety is in the gate, not in the LLM.
# =============================================================================

"""
    is_assignment_edge(sched, v, v2) -> Bool

An assignment edge is the only `RobotGo -> RobotGo` edge in the schedule: it
connects a robot's "free" node to a transport-task "slot" node. Every other
RobotGo edge is structural (`RobotStart -> RobotGo`, `RobotGo -> FormTransportUnit`,
`DepositCargo -> RobotGo`), so this single type test identifies assignments.
"""
function is_assignment_edge(sched, v::Int, v2::Int)
    n1 = get_node_from_id(sched, get_vtx_id(sched, v))
    n2 = get_node_from_id(sched, get_vtx_id(sched, v2))
    return (n1 isa RobotGo) && (n2 isa RobotGo)
end

"""
    reset_slot_to_invalid!(env, slot_v) -> Bool

Revert a transport-task "slot" RobotGo (the `dst` of a free->slot assignment
edge) to the *unassigned* state: stamp it with a fresh INVALID robot id and
re-key the successor FormTransportUnit team by that invalid id (geometry
preserved). This is required because `align_with_predecessor` for RobotGo uses
`first_valid`, which would otherwise keep the slot's STALE valid id instead of
adopting the new feeder's id during `propagate_valid_ids!`. After the reset,
the re-solve's id propagation flows the correct robot identity from the
RobotStart anchors forward through the new assignment. Returns false if the slot
already carries an invalid id (nothing to do).
"""
function reset_slot_to_invalid!(env, slot_v::Int)
    sched = env.sched
    slot = get_node_from_id(sched, get_vtx_id(sched, slot_v))
    slot isa RobotGo || return false
    old_id = entity(slot).id
    valid_id(old_id) || return false
    new_id = get_unique_invalid_id(RobotID)
    new_node = RobotGo(RobotNode(new_id, entity(slot)),
                       start_config(slot), goal_config(slot), node_id(slot))
    replace_in_schedule!(sched, env.scene_tree, new_node, node_id(slot))
    # Re-key every successor FormTransportUnit team from old_id back to new_id.
    for vf in Graphs.outneighbors(sched, slot_v)
        fnode = get_node_from_id(sched, get_vtx_id(sched, vf))
        if fnode isa FormTransportUnit && haskey(robot_team(entity(fnode)), old_id)
            swap_robot_id!(entity(fnode), old_id, new_id)
        end
    end
    return true
end

"""
    release_pending_assignments!(env, invariant; faulted) -> Vector{Tuple{Int,Int}}

Remove the assignment edges (free -> slot) the re-solve is allowed to re-decide,
AND reset each freed slot to the unassigned (invalid-id) state so id propagation
re-stamps it with the robot the solver actually assigns. Release policy:

  * a HEALTHY robot's edge is kept (pinned) if either endpoint is closed or
    active — finished and in-progress work is never disturbed;
  * the FAULTED robot's edge is kept only if an endpoint is CLOSED — a faulted
    robot also drops its current (active) target, so that work gets reassigned.

Returns the removed (src,dst) vertex pairs. Does not re-solve — the caller's
`formulate_milp` + `update_project_schedule!` do that.
"""
function release_pending_assignments!(env, invariant::InvariantSpec; faulted = nothing)
    sched = env.sched
    G = get_graph(sched)
    closed = invariant.closed_nodes
    active_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set)
    in_closed(id) = id in closed
    in_active(id) = id in active_ids
    removed = Tuple{Int,Int}[]
    for e in collect(Graphs.edges(G))
        v, v2 = e.src, e.dst
        is_assignment_edge(sched, v, v2) || continue
        id1 = get_vtx_id(sched, v); id2 = get_vtx_id(sched, v2)
        src_node = get_node_from_id(sched, id1)
        is_faulted = faulted !== nothing && bound_to_agent(src_node, faulted)
        keep = if is_faulted
            in_closed(id1) || in_closed(id2)               # faulted: keep only completed
        else
            in_closed(id1) || in_closed(id2) || in_active(id1) || in_active(id2)
        end
        keep && continue
        Graphs.rem_edge!(G, v, v2)
        push!(removed, (v, v2))
    end
    # Reset freed slots (the dst of each removed edge) to unassigned identities.
    for (_, v2) in removed
        reset_slot_to_invalid!(env, v2)
    end
    # Clear STALE ids on the FAULTED agent's downstream free nodes: post-DepositCargo
    # RobotGos that still carry the agent's id but are NOT its origin frontier and are
    # NOT slots of removed edges (so the loop above misses them). These live in build-
    # step subtrees, not in the agent's RobotStart chain, so they survive the release
    # carrying a stale id. Left un-reset, propagate_valid_ids' first_valid keeps that
    # stale id and the re-solve can thread a team member through such a node, making the
    # faulted agent RE-APPEAR on a transport team it was never re-assigned to. Resetting
    # them to invalid lets id propagation re-stamp them from the actual re-solve. The
    # true origin (predecessor is a RobotStart) is preserved so ForbidAgent still finds
    # the frontier; the frozen past (closed) is never touched.
    if faulted !== nothing
        for v in Graphs.vertices(G)
            id = get_vtx_id(sched, v)
            in_closed(id) && continue
            node = get_node_from_id(sched, id)
            (node isa RobotGo && bound_to_agent(node, faulted)) || continue
            any(vp -> get_node_from_id(sched, get_vtx_id(sched, vp)) isa RobotStart,
                Graphs.inneighbors(G, v)) && continue   # keep R's true origin frontier
            reset_slot_to_invalid!(env, v)
        end
    end
    return removed
end

"""
    robot_frontier_vtxs(sched, agent) -> Vector{Int}

The vertices where `agent` enters the re-solvable future (see
`is_agent_frontier`). Reads the current `RESPEC_FROZEN` boundary, so set that
first if calling outside `fault_robot_and_reassign!`.
"""
function robot_frontier_vtxs(sched, agent::AbstractID)
    out = Int[]
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        is_agent_frontier(sched, v, node, agent) && push!(out, v)
    end
    return out
end

"""
    transport_teams_with_agent(env, agent; pending_only=true) -> Vector{AbstractID}

The FormTransportUnit node ids whose team currently includes a RobotGo bound to
`agent`. Used to verify the agent was actually freed from transport work. With
`pending_only`, frozen (closed/active) tasks are excluded — the agent may still
legitimately appear in already-finished work (the immutable past).
"""
function transport_teams_with_agent(env, agent::AbstractID; pending_only=true)
    sched = env.sched
    frozen = build_invariant(env)
    pinned_ids = union(frozen.closed_nodes,
        Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set))
    out = AbstractID[]
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        matches_template(FormTransportUnit, get_node(sched, v)) || continue
        fid = get_vtx_id(sched, v)
        pending_only && (fid in pinned_ids) && continue
        for vp in Graphs.inneighbors(sched, v)
            pnode = get_node_from_id(sched, get_vtx_id(sched, vp))
            if pnode isa RobotGo && bound_to_agent(pnode, agent)
                push!(out, fid)
                break
            end
        end
    end
    return out
end

"""
    fault_robot_and_reassign!(env, agent; optimizer, verbose) -> NamedTuple

Top-level Stage-1 core logic, LLM-free. Models the OOD action that the agentic
layer will later drive from a natural-language fault report:

  1. freeze completed/in-progress work,
  2. release the pending assignment edges (schedule surgery),
  3. build the `ForbidAgent(agent)` formal spec,
  4. VERIFY it (trial solve against the freeze + the spec),
  5. on Admit: re-solve and commit (`update_project_schedule!` + `reset_cache!`),
     on Reject: leave the schedule released-but-unsolved and report (caller
     engages the safe fallback).

Returns a NamedTuple with `:status` in (:admitted, :rejected, :fallback) plus
diagnostics. NEVER lets an unverified schedule become the schedule-of-record.
"""
function fault_robot_and_reassign!(env, agent::AbstractID;
                                   optimizer = _respec_optimizer(), verbose::Bool = true)
    sched = env.sched
    teams_before = transport_teams_with_agent(env, agent; pending_only = true)
    ms0 = makespan(sched)

    invariant = build_invariant(env)
    # Tell the ForbidAgent compiler which nodes are the frozen past, so it can
    # locate the faulted agent's emergence frontier (== origin at t=0).
    closed_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.closed_set)
    active_ids = Set{AbstractID}(get_vtx_id(sched, v) for v in env.cache.active_set)
    RESPEC_FROZEN[] = closed_ids                 # completed: not a frontier
    RESPEC_PINNED[] = union(closed_ids, active_ids)  # pinned: a frontier's predecessor
    # Snapshot the (feasible) pre-fault assignment BEFORE surgery; it warm-starts
    # the re-solve so the solver only has to *repair* the faulted robot's share
    # instead of re-deriving the whole assignment from scratch (much faster and,
    # for the worst-case t=0 full re-solve, the difference between reliably
    # finding a feasible point and timing out).
    warm = SparseMatrixCSC{Float64,Int}(adjacency_matrix(sched))
    removed = release_pending_assignments!(env, invariant; faulted = agent)
    verbose && @info "[REASSIGN] released $(length(removed)) pending assignment edge(s); " *
                     "frozen: $(length(invariant.frozen_t0)) t0 / $(length(invariant.frozen_tF)) tF; " *
                     "agent $(agent) was on $(length(teams_before)) pending transport team(s)."

    proposal = RespecProposal(ConstraintSpec[ForbidAgent(agent, 0.0)],
                              "robot $(agent) reported a fault and is removed from service",
                              "robot_fault")

    verdict = verify(proposal, env, invariant; optimizer = optimizer, warm_start = warm)
    if verdict isa Reject
        verbose && @warn "[REASSIGN] REJECTED ($(verdict.reason)): $(verdict.detail) -> fallback"
        return (status = :rejected, reason = verdict.reason, detail = verdict.detail,
                removed = length(removed), teams_before = length(teams_before))
    end

    # --- commit the verified re-solve ----------------------------------------
    milp = formulate_milp(SparseAdjacencyMILP(), sched, env.scene_tree;
        optimizer = optimizer, t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF,
        warm_start_soln = warm, extra_constraints = verdict.proposal)
    optimize!(milp)
    if primal_status(milp) != MOI.FEASIBLE_POINT
        verbose && @warn "[REASSIGN] committed solve disagreed with verifier -> fallback"
        return (status = :fallback, reason = :committed_infeasible,
                removed = length(removed), teams_before = length(teams_before))
    end

    ok = update_project_schedule!(nothing, milp, sched, env.scene_tree)
    # Measure the agent's remaining pending teams BEFORE reset_cache! (which
    # empties closed_set and would make completed teams look "pending").
    teams_after = transport_teams_with_agent(env, agent; pending_only = true)
    ms1 = makespan(sched)
    # NOTE(Stage 3): reset_cache! re-seeds the cache from ROOT nodes and clears
    # closed_set. That is correct for a from-scratch plan but ERASES execution
    # progress; for true mid-sim resumption the viz demo must re-seed the cache
    # while preserving the already-closed nodes. Fine here (we don't resume).
    reset_cache!(env.cache, sched)
    verbose && @info "[REASSIGN] ADMITTED $(verdict.n_constraints) forbid-constraint(s); " *
                     "valid=$(ok); agent now on $(length(teams_after)) pending team(s); " *
                     "makespan $(round(ms0, digits=2)) -> $(round(ms1, digits=2))"
    return (status = :admitted, valid = ok, n_constraints = verdict.n_constraints,
            removed = length(removed), teams_before = length(teams_before),
            teams_after = length(teams_after), makespan_before = ms0, makespan_after = ms1)
end
