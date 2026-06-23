# =============================================================================
# spec_dsl.jl  --  The formal-specification DSL that is the LLM/solver interface
# =============================================================================
#
# DESIGN INVARIANT (the whole safety story lives here):
#   The LLM may ONLY emit values of the closed `ConstraintSpec` union below.
#   Every member compiles to JuMP `@constraint` calls over the EXISTING MILP
#   variables (t0, tF, Xa) and NEVER touches the objective. Because each member
#   only ADDS constraints, admitting one can only SHRINK the feasible set, which
#   is monotonically safe for any safety property expressed as feasibility.
#
#   This file defines the grammar. compiler.jl turns it into @constraints.
#   verifier.jl decides which specs are admitted. llm_bridge.jl forces the LLM
#   to produce ONLY this grammar (JSON schema / structured output).
# =============================================================================

"""
    ConstraintSpec

Abstract supertype of every re-specification the LLM is allowed to propose.
Closed union: if it is not one of the concrete subtypes below, it is rejected
before it can reach the solver. Add a new subtype ONLY together with (a) a
`compile_constraint!` method, (b) a `semantic_predicate` entry in verifier.jl,
and (c) a JSON-schema branch in llm_bridge.jl. No exceptions.
"""
abstract type ConstraintSpec end

"""
    ForbidAgent(agent, after)

"Robot/agent `agent` is unavailable for any task starting at or after `after`."
Models a robot fault / removal from service. Compiles to forcing every
not-yet-started node bound to `agent` to be reassigned (Xa edges into that
agent's start node are disallowed) — i.e. the assignment must route around it.
"""
struct ForbidAgent <: ConstraintSpec
    agent::AbstractID
    after::Float64
end

"""
    Precede(a, b)

"Node `a` must complete before node `b` starts": tF[a] <= t0[b].
Models a newly discovered ordering requirement (e.g. an off-spec part must be
re-inspected before assembly). Pure precedence — monotone, never relaxes.
"""
struct Precede <: ConstraintSpec
    a::AbstractID
    b::AbstractID
end

"""
    Deadline(node, tF_max)

"Node `node` must finish no later than `tF_max`": tF[node] <= tF_max.
Models a new hard time requirement. Note: this is the one member that can make
the problem INFEASIBLE, which is exactly why the verifier's feasibility gate
exists and why an infeasible verdict routes to the safe fallback.
"""
struct Deadline <: ConstraintSpec
    node::AbstractID
    tF_max::Float64
end

"""
    ForbidWindow(node, t_lo, t_hi)

"Node `node` may not be ACTIVE during [t_lo, t_hi]" — encoded as the node either
finishing before t_lo or starting after t_hi (disjunction via an auxiliary
binary; see compiler.jl). Models a temporary no-go window (a zone closed for
maintenance, a shift boundary). Still constraint-only.
"""
struct ForbidWindow <: ConstraintSpec
    node::AbstractID
    t_lo::Float64
    t_hi::Float64
end

# -----------------------------------------------------------------------------
# A re-specification proposal is an ordered bundle of ConstraintSpecs plus the
# provenance needed for auditing/verification. The LLM returns exactly this.
# -----------------------------------------------------------------------------
"""
    RespecProposal

What the LLM produces and what the verifier consumes. `rationale` is for the
audit log only — it has NO effect on the solver. `source_event` ties the
proposal back to the OOD observation that triggered it.
"""
struct RespecProposal
    constraints::Vector{ConstraintSpec}
    rationale::String
    source_event::String
end

RespecProposal(cs::Vector{<:ConstraintSpec}) = RespecProposal(collect(ConstraintSpec, cs), "", "")
