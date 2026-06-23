# =============================================================================
# compiler.jl  --  DSL ConstraintSpec  ->  JuMP @constraint over (t0, tF, Xa)
# =============================================================================
#
# Each `compile_constraint!` method is handed the live JuMP objects from
# formulate_milp (model, t0, tF, Xa) plus `sched` so it can map an AbstractID
# to its vertex via `get_vtx(sched, id)`. These mirror the variables declared at
# essential_tg_coponents.jl:946-950. Nothing here references the objective.
#
# CONTRACT: a compile method may ONLY call @constraint / @variable(binary).
# It must never call @objective, set_objective, or delete existing constraints.
# Adding a binary aux var for a disjunction is fine — it does not relax the set.
# =============================================================================

"""
    compile_proposal!(model, t0, tF, Xa, sched, proposal::RespecProposal)

Apply every constraint in `proposal` to `model`. Called from formulate_milp's
`extra_constraints` hook (see the patch in PATCHES.md) AFTER all native
constraints and BEFORE @objective. Returns the number of constraints added.
"""
function compile_proposal!(model, t0, tF, Xa, sched, proposal::RespecProposal)
    n = 0
    for cs in proposal.constraints
        n += compile_constraint!(model, t0, tF, Xa, sched, cs)
    end
    return n
end

# --- Precede ------------------------------------------------------------------
function compile_constraint!(model, t0, tF, Xa, sched, cs::Precede)
    va = get_vtx(sched, cs.a)
    vb = get_vtx(sched, cs.b)
    @constraint(model, tF[va] <= t0[vb])
    return 1
end

# --- Deadline -----------------------------------------------------------------
function compile_constraint!(model, t0, tF, Xa, sched, cs::Deadline)
    v = get_vtx(sched, cs.node)
    @constraint(model, tF[v] <= cs.tF_max)
    return 1
end

# --- ForbidWindow: node finishes before t_lo OR starts after t_hi -------------
function compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidWindow)
    v = get_vtx(sched, cs.node)
    Mm = 1e5
    # b == 1  -> finish before t_lo ; b == 0 -> start after t_hi
    b = @variable(model, binary = true)
    @constraint(model, tF[v] <= cs.t_lo + Mm * (1 - b))
    @constraint(model, t0[v] >= cs.t_hi - Mm * b)
    return 2
end

# --- ForbidAgent: disallow the faulted agent from starting any FUTURE task -----
# A robot enters the re-solvable future through its "frontier" free node(s): a
# RobotGo bound to the agent whose predecessor is either its RobotStart (the
# t=0 case — nothing executed yet) or an already-frozen node (the mid-build
# case — the boundary where the robot emerges from its completed past). Blocking
# the frontier's outgoing assignment edges removes the agent from all future
# work, because every deeper free moment exists only *after* it does a frontier
# task. We deliberately do NOT touch the fluid, assignment-derived identities of
# post-frontier nodes (a re-solve re-stamps those).
#
# IMPORTANT: this only forbids CANDIDATE (Big-M) edges, never an existing forced
# edge (those are structural `slot -> FormTransportUnit` links). For the re-solve
# to actually be able to route around the agent, the caller must FIRST release
# the pending assignment edges (see reassign.jl `release_pending_assignments!`);
# otherwise every other robot's chain is force-fixed and the model is infeasible
# -> verifier feasibility gate fires -> safe fallback. That is the honest
# behaviour: "reassign when the future is re-solvable, safe-stop when it isn't".
function compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidAgent)
    n = 0
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        is_agent_frontier(sched, v, node, cs.agent) || continue
        for v2 in Graphs.vertices(sched)
            # Xa[v, v2] is a structural nonzero only where an edge is a decision
            # variable; skip the implicit zeros so we don't densify the matrix.
            isassigned_edge(Xa, v, v2) || continue
            Graphs.has_edge(sched, v, v2) && continue  # never forbid a forced edge
            @constraint(model, Xa[v, v2] == 0)
            n += 1
        end
    end
    return n
end

# --- helpers ------------------------------------------------------------------

"""
The past/future boundary the ForbidAgent compiler uses to locate the faulted
agent's emergence frontier, set by `fault_robot_and_reassign!` before each solve
(so the invariant need not thread through `formulate_milp`). Two sets:
`RESPEC_FROZEN` = completed (closed) nodes — a frontier node must not be one;
`RESPEC_PINNED` = closed ∪ active nodes — a frontier node's predecessor must be
one (or a RobotStart). Both empty at t=0, where origin == frontier.
"""
const RESPEC_FROZEN = Ref{Set{AbstractID}}(Set{AbstractID}())
const RESPEC_PINNED = Ref{Set{AbstractID}}(Set{AbstractID}())

"True if `Xa[v, v2]` holds a real VariableRef (a candidate assignment edge)."
function isassigned_edge(Xa::SparseMatrixCSC, v::Int, v2::Int)
    for k in nzrange(Xa, v2)
        rowvals(Xa)[k] == v && return true
    end
    return false
end

"""
    is_agent_frontier(sched, v, node, agent) -> Bool

True iff vertex `v` is an identity-stable point where `agent` enters the
re-solvable future: a non-frozen `RobotGo` bound to `agent` whose predecessor is
its `RobotStart` (t=0) or an already-frozen node (mid-build). Blocking the
out-edges of every such node removes the agent from all future assignments.
"""
function is_agent_frontier(sched, v::Int, node, agent::AbstractID)
    node isa RobotGo || return false
    bound_to_agent(node, agent) || return false
    (get_vtx_id(sched, v) in RESPEC_FROZEN[]) && return false   # already completed
    pinned = RESPEC_PINNED[]
    for vp in Graphs.inneighbors(sched, v)
        pnode = get_node_from_id(sched, get_vtx_id(sched, vp))
        pnode isa RobotStart && return true
        (get_vtx_id(sched, vp) in pinned) && return true
    end
    return false
end

"True if `node` is a robot action whose assigned robot id equals `agent`."
function bound_to_agent(node, agent::AbstractID)
    try
        return entity(node).id == agent
    catch
        return false
    end
end
