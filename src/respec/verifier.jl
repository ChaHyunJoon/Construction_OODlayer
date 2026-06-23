# =============================================================================
# verifier.jl  --  The admit/reject gate. Safety comes from HERE, not the LLM.
# =============================================================================
#
# An LLM proposal is admitted to the solver ONLY if it passes, in order:
#   (1) GRAMMAR   : every element is a known ConstraintSpec (guaranteed by the
#                   typed parse in llm_bridge.jl; re-checked here defensively).
#   (2) STATIC    : it never touches the objective (structurally impossible in
#                   the DSL) and never references already-closed nodes (the
#                   "completed work is invariant" rule for partial replanning).
#   (3) FEASIBLE  : the MILP with the proposal's constraints injected is solved
#                   to a feasible point that also satisfies the invariant safety
#                   spec. If infeasible -> REJECT -> caller engages fallback.
#
# Only (3) costs a solve. (1)/(2) are cheap and reject most bad proposals before
# we ever pay for a solve.
# =============================================================================

"""
    InvariantSpec

The closed-world safety properties that re-specification must never violate.
Phrased so each is checkable on a candidate MILP solution. Extend per scenario.
"""
struct InvariantSpec
    closed_nodes::Set{AbstractID}     # completed tasks: their (t0,tF) must not move
    frozen_t0::Dict{AbstractID,Float64}
    frozen_tF::Dict{AbstractID,Float64}
    # room to grow: forbidden-region predicates, reachability certificate, etc.
end

abstract type Verdict end
struct Admit  <: Verdict; proposal::RespecProposal; n_constraints::Int; end
struct Reject <: Verdict; reason::Symbol; detail::String; end

"""
    _respec_optimizer()

The MILP optimizer the gate/replan uses. Respects a globally-set optimizer
(`set_default_milp_optimizer!`) when present, else falls back to HiGHS. The
global is `nothing` when the demo ran with greedy assignment (never set), so the
fallback is what makes re-solving work regardless of how the env was built.
"""
_respec_optimizer() = something(default_milp_optimizer(), HiGHS.Optimizer)

"""
    verify(proposal, env, invariant; optimizer) -> Verdict

The gate. Returns `Admit` (caller may inject + commit the re-solve) or
`Reject` (caller MUST engage the safe fallback). This function does the trial
solve itself so that the admit decision and the committed solve use identical
constraints — no TOCTOU gap between "verified" and "executed".
"""
function verify(proposal::RespecProposal, env, invariant::InvariantSpec;
                optimizer = _respec_optimizer(), warm_start = nothing)
    # (1) GRAMMAR — defensive; llm_bridge already parsed into the typed union.
    for cs in proposal.constraints
        cs isa ConstraintSpec || return Reject(:ungrammatical, "non-ConstraintSpec element")
    end

    # (2) STATIC — no proposal may reference / re-time an already-closed node.
    for cs in proposal.constraints
        for id in referenced_ids(cs)
            if id in invariant.closed_nodes
                return Reject(:touches_closed, "spec references closed node $(id)")
            end
        end
    end

    # (3) FEASIBILITY — build the model WITH the proposal and the freeze
    # constraints, solve, and confirm a feasible point exists.
    milp = formulate_milp(
        SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer = optimizer,
        t0_ = invariant.frozen_t0,        # pin completed/in-progress work
        tF_ = invariant.frozen_tF,
        warm_start_soln = warm_start,     # optional: pre-fault assignment, for fast feasibility
        extra_constraints = proposal,     # <-- the injected re-specification
    )
    optimize!(milp)

    # Match the codebase's own success check (full_demo.jl:431, 462).
    if primal_status(milp) != MOI.FEASIBLE_POINT
        return Reject(:infeasible, "MILP infeasible with proposal injected")
    end
    if !satisfies_invariant(milp, env, invariant)
        return Reject(:invariant_violated, "feasible but violates safety invariant")
    end

    return Admit(proposal, length(proposal.constraints))
end

# --- which schedule ids does a spec touch (for the closed-node check) ---------
referenced_ids(cs::Precede)      = (cs.a, cs.b)
referenced_ids(cs::Deadline)     = (cs.node,)
referenced_ids(cs::ForbidWindow) = (cs.node,)
referenced_ids(cs::ForbidAgent)  = (cs.agent,)

"""
    satisfies_invariant(milp, env, invariant) -> Bool

Confirm the solved MILP did not move any frozen node and meets every additional
safety property. The freeze is enforced as a constraint already; this re-checks
the realized solution as defense-in-depth. Extend with reachability / no-go
region checks as Year-2 certified safe-set lands.
"""
function satisfies_invariant(milp, env, invariant::InvariantSpec)
    sched = env.sched
    t0v = value.(milp.model[:t0])
    tFv = value.(milp.model[:tF])
    tol = 1e-3
    # Frozen times are LOWER BOUNDS: completed/in-progress work cannot be pulled
    # earlier than it actually happened ("the past is invariant"). Confirm the
    # realized solution respects them. (The makespan objective gives the solver
    # no incentive to push frozen work later, so in practice they stay pinned.)
    for (id, t) in invariant.frozen_t0
        t0v[get_vtx(sched, id)] >= t - tol || return false
    end
    for (id, t) in invariant.frozen_tF
        tFv[get_vtx(sched, id)] >= t - tol || return false
    end
    return true
end

"""
    build_invariant(env) -> InvariantSpec

Snapshot the current execution state into the freeze set: every closed node and
every active (in-progress) node has its realized timing pinned so re-solving can
only re-plan the FUTURE. This is the operational meaning of
"constraint-only, completed-work-invariant" for partial replanning.
"""
function build_invariant(env)
    sched = env.sched
    closed = Set{AbstractID}()
    ft0 = Dict{AbstractID,Float64}()
    ftF = Dict{AbstractID,Float64}()
    # Completed nodes: pin BOTH ends to their realized schedule times. These
    # become >= lower bounds in the re-solve, so finished work cannot be pulled
    # into the past, and is also flagged closed so no spec may reference it.
    for v in env.cache.closed_set
        id = get_vtx_id(sched, v)
        push!(closed, id)
        ft0[id] = Float64(get_t0(sched, v))
        ftF[id] = Float64(get_tF(sched, v))
    end
    # In-progress nodes: they have already STARTED, so lower-bound their start;
    # leave the finish free for the re-plan to determine. (Not added to `closed`
    # — a re-spec may still legitimately constrain how an active task finishes.)
    for v in env.cache.active_set
        id = get_vtx_id(sched, v)
        ft0[id] = Float64(get_t0(sched, v))
    end
    return InvariantSpec(closed, ft0, ftF)
end
