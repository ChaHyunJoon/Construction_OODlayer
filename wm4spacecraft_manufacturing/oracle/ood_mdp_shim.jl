# =============================================================================
# ood_mdp_shim.jl — REPLACES the deleted decpomdp/examples/ood_env_mdp.jl.
#
# The decpomdp/ folder was removed from the checkout, so the generator's original
#   include(".../ood_env.jl"); include(".../ood_env_mdp.jl")
# both died at load. The scan established that the ONLY thing the generator body
# actually references from those files is FOUR functions — everything else it needs
# is CB.* (still present) or defined locally. `ood_env.jl` supplied no symbol the
# generator names directly. So this single shim is a complete replacement.
#
# The four functions are rebuilt on SURVIVING CB code so labels stay byte-compatible
# with the pre-deletion graded dumps:
#   • event_context(env, ev)  — recovers the fired OOD from CB.ood_truth_log()
#                               (ood_truth.jl); ev itself is only the NL string.
#   • valid_actions(ctx)      — legal macro ids per type; mirrors random_macro_respec
#                               repertoires (baselines.jl:193-217).
#   • canonical_action(ctx)   — default macro id; mirrors canonical_respec branching
#                               (baselines.jl:68-102), incl. battery soc split.
#   • action_to_proposal(ctx,a) — macro id -> RespecProposal, via the surviving DSL
#                               constructors (spec_dsl.jl): ReplaceAgent/Deprioritize
#                               Agent/ForbidZone/ReformTeam. NOOP and any invalid
#                               cross-type macro -> nothing (== the NOOP arm).
#
# macro ids (gen_oracle_dataset.jl:73-74): 0 NOOP · 1 Replace · 2 Deprioritize
#                                          3 ForbidZone · 4 ReformTeam
# Replace == ReplaceAgent (gen:474-481; hot-swap is a separate ENACTMENT toggle).
# =============================================================================

# ---- event_context: (type, agent, zone, assembly, soc, after) from the fired OOD --------
# ev is only the natural-language string (replan.jl seam). The structured event lives in the
# OOD truth log, which every injector auto-records at fire time. Match the LAST entry whose
# recorded NL == ev (each fired event appends its own entry; last-match = the just-fired one).
function event_context(env, ev::AbstractString)
    log = try CB.ood_truth_log() catch; Any[] end
    entry = nothing
    for e in Iterators.reverse(log)
        nl = _entry_nl(e)
        if nl == ev
            entry = e; break
        end
    end
    if entry === nothing && !isempty(log)
        entry = last(log)                      # fallback: newest truth even if NL differs
    end
    local ctx
    if entry !== nothing
        t = _entry_truth(entry)
        ctx = t === nothing ? _ctx_from_keywords(ev) : _ctx_from_truth(t, ev)
    else
        ctx = _ctx_from_keywords(ev)          # last resort: classify from the string
    end
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] event_context: matched=$(entry!==nothing) type=$(ctx.type) ",
                     "agent=$(ctx.agent) zone=$(ctx.zone) assembly=$(ctx.assembly) soc=$(ctx.soc) log_n=$(length(log))")
    end
    return ctx
end

# truth-log entries are NamedTuples ~ (at, nl, truth); read defensively by field then position.
_entry_nl(e)    = try e.nl    catch; try e[2] catch; "" end end
_entry_truth(e) = try e.truth catch; try e[3] catch; nothing end end

# Dispatch on the truth TYPE NAME (robust to whatever module path CB exposes it under),
# and pull fields with getfield so we never depend on positional constructors.
function _ctx_from_truth(t, ev)
    tn = string(nameof(typeof(t)))
    gf(f, d) = try getfield(t, f) catch; d end
    if tn == "FaultTruth"
        return (type=:fault,   agent=gf(:robot, nothing), zone=nothing, assembly=nothing,
                soc=NaN,               after=Float64(gf(:after, 0.0)), source=String(ev))
    elseif tn == "ZoneTruth"
        return (type=:zone,    agent=nothing, zone=gf(:zone, :zone), assembly=gf(:assembly, nothing),
                soc=NaN,               after=0.0,                     source=String(ev))
    elseif tn == "BatteryTruth"
        return (type=:battery, agent=gf(:robot, nothing), zone=nothing, assembly=nothing,
                soc=Float64(gf(:soc_after, NaN)), after=Float64(gf(:after, 0.0)), source=String(ev))
    elseif tn == "ReformTruth"
        return (type=:reform,  agent=nothing, zone=nothing, assembly=nothing,
                soc=NaN,               after=0.0,                     source=String(ev))
    end
    return _ctx_from_keywords(ev)
end

# Keyword fallback for events with no matching truth entry (e.g. background :reform / wedge alarms).
function _ctx_from_keywords(ev::AbstractString)
    s = lowercase(String(ev))
    ty = (occursin("broken", s) || occursin("faulted", s) || occursin("cannot move", s)) ? :fault :
         (occursin("zone", s)   || occursin("exclusion", s) || occursin("no-go", s))      ? :zone :
         (occursin("battery", s)|| occursin("charge", s)   || occursin("degraded", s))    ? :battery : :reform
    return (type=ty, agent=nothing, zone=nothing, assembly=nothing, soc=NaN, after=0.0, source=String(ev))
end

# ---- valid_actions: legal macro ids per event type (Python reads this as a list) --------
# Derived from the PRE-DELETION dumps (oracle/out/graded/*.jsonl), which are ground truth:
#   fault -> [0,1] ; battery deep(soc<=thr) -> [0,1] ; battery mild(soc>thr) -> [0,2] ;
#   zone -> [0,3] ; reform -> [0,4].
# (Note: this is TIGHTER than random_macro_respec's {0,1,2} — the generator used a soc-split,
# single-intervention mask, and invalid macros collapse to the NOOP arm. See action_to_proposal.)
function valid_actions(ctx)
    if ctx.type === :fault
        return [0, 1]
    elseif ctx.type === :battery
        thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
        return (isfinite(ctx.soc) && ctx.soc <= thr) ? [0, 1] : [0, 2]
    elseif ctx.type === :zone
        return [0, 3]
    elseif ctx.type === :reform
        return [0, 4]
    end
    return [0]
end

# ---- canonical_action: default macro id (mirror of canonical_respec branching) ---------
function canonical_action(ctx)
    if ctx.type === :fault
        return 1                                           # ReplaceAgent
    elseif ctx.type === :zone
        return ctx.assembly === nothing ? 0 : 3            # ForbidZone only if it blocks an assembly
    elseif ctx.type === :battery
        thr = try Float64(CB.REPLACE_SOC_THRESHOLD[]) catch; 0.2 end
        return (isfinite(ctx.soc) && ctx.soc <= thr) ? 1 : 2   # deep -> Replace, mild -> Deprioritize
    elseif ctx.type === :reform
        return 4
    end
    return 0
end

# ---- action_to_proposal: macro id -> RespecProposal | nothing --------------------------
# Uses the surviving DSL constructors. A macro that is invalid for this event type (needs a
# target/zone the ctx does not carry) collapses to `nothing` == the NOOP arm — matching the
# generator's full-5-macro sweep, where invalid rows realize the same run as NOOP.
function action_to_proposal(ctx, a::Int)
    a == 0 && return nothing
    a in valid_actions(ctx) || return nothing   # macro invalid for this event type -> NOOP arm
                                                 # (reproduces the dumps: invalid macros == NOOP label)
    cs = nothing
    if a == 1 && ctx.agent !== nothing
        cs = CB.ConstraintSpec[CB.ReplaceAgent(ctx.agent, Float64(ctx.after))]
    elseif a == 2 && ctx.agent !== nothing
        cs = CB.ConstraintSpec[CB.DeprioritizeAgent(ctx.agent, 50.0)]
    elseif a == 3 && ctx.assembly !== nothing
        cs = CB.ConstraintSpec[CB.ForbidZone(ctx.assembly, ctx.zone)]
    elseif a == 4
        cs = CB.ConstraintSpec[CB.ReformTeam()]
    end
    if get(ENV, "DS_SHIM_DEBUG", "0") == "1"
        Base.println(Base.stderr, "[shim] action_to_proposal: a=$a type=$(ctx.type) assembly=$(ctx.assembly) ",
                     "-> $(cs === nothing ? "nothing (NOOP arm)" : string(cs))")
    end
    cs === nothing && return nothing
    return CB.RespecProposal(cs, "oracle macro $a", String(ctx.source))
end
