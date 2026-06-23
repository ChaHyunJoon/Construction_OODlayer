# =============================================================================
# llm_bridge.jl  --  thin HTTP client to the separated Python LLM service.
# =============================================================================
#
# The LLM layer is a standalone Python process (src/respec/llm_service/). Julia
# only POSTs {event, open_ids} and receives a validated DSL proposal as JSON.
# The anthropic call, prompt, and tool schema all live in Python; Julia keeps
# ONLY the typed parse below — that, plus verify(), is the safety boundary that
# must stay on the solver side. Python proposes; Julia validates and admits.
#
# Service URL (default http://127.0.0.1:8000) overridable via RESPEC_SERVICE_URL.
# Requires: HTTP, JSON3 (Julia side). No anthropic dependency in Julia anymore.
# =============================================================================

const _RESPEC_SERVICE_URL = get(ENV, "RESPEC_SERVICE_URL", "http://127.0.0.1:8000")

"""
    respec_service_ready() -> Bool

Ping the Python service's /health. Call this once before a simulation run so a
missing/down service is a clear startup error rather than a per-step fallback.
"""
function respec_service_ready()
    try
        resp = HTTP.get(_RESPEC_SERVICE_URL * "/health"; readtimeout = 3, retries = 0)
        return resp.status == 200
    catch
        return false
    end
end

"""
    llm_to_proposal(event, env; id_resolver) -> RespecProposal

POST the OOD event and the still-mutable node ids to the Python service and parse
the returned DSL JSON into a typed `RespecProposal`. Any failure (service down,
non-200, malformed body, unknown id, bad kind) THROWS — and the caller
(`maybe_respecify!`) treats a throw exactly like a Reject, engaging the safe
fallback. Failing loudly is correct: an unparseable proposal must never reach
the solver.
"""
function llm_to_proposal(event, env; id_resolver)
    body = Dict("event" => String(event),
                "open_ids" => open_node_id_strings(env),
                "agents"   => open_agent_descriptors(env),
                "nodes"    => open_node_descriptors(env))
    resp = HTTP.post(
        _RESPEC_SERVICE_URL * "/propose",
        ["content-type" => "application/json"],
        JSON3.write(body);
        readtimeout = 30, retries = 0,
    )
    resp.status == 200 || error("respec service returned HTTP $(resp.status): $(String(resp.body))")
    payload = JSON3.read(resp.body)
    return _parse_proposal(payload, event; id_resolver = id_resolver)
end

"""
    open_node_id_strings(env) -> Vector{String}

The schedulable, NOT-yet-closed node ids, stringified the same way the
id_resolver reverses them. Closed nodes are filtered out so the model cannot
even reference completed work — the "completed work is invariant" rule enforced
at the prompt boundary, before the verifier re-checks it.
"""
function open_node_id_strings(env)
    sched = env.sched
    ids = String[]
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue
        push!(ids, string(get_vtx_id(sched, v)))
    end
    return ids
end

"""
    open_agent_descriptors(env) -> Vector{Dict{String,String}}

The robots (agents) the model may forbid, one entry per distinct robot as
`{"id", "label"}`:
  * `id`    -- the EXACT `RobotID` string the `ForbidAgent.agent` field must echo,
               so `_default_id_resolver` can reverse it (built from `string(rid)`,
               never hand-written, so it stays in lockstep with the resolver).
  * `label` -- a human alias ("Robot R3 / robot 3") so the model can ground a
               natural-language fault report ("Robot R3 is immobile...") onto the
               opaque id. This is the missing link that made ROUND 1 fail: the
               flat node-id list never told the model which id is "R3".

Enumerated from `RobotGo` nodes (every robot has at least one), where
`entity(node).id` is known to be the agent's `RobotID` (same access the
ForbidAgent compiler's `bound_to_agent` uses).
"""
function open_agent_descriptors(env)
    sched = env.sched
    seen = Set{String}()
    out = Vector{Dict{String,String}}()
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        node isa RobotGo || continue
        rid = try entity(node).id catch; nothing end
        rid isa RobotID || continue
        idstr = string(rid)
        idstr in seen && continue
        push!(seen, idstr)
        push!(out, Dict("id" => idstr, "label" => "Robot R$(rid.id) / robot $(rid.id)"))
    end
    return out
end

"""
    open_node_descriptors(env) -> Vector{Dict{String,String}}

Schedulable MILESTONE nodes the model can put a Precede/Deadline/ForbidWindow on,
each as `{"id", "label"}` with a STRUCTURAL human label so the model can ground a
natural-language reference ("the final assembly", "sub-assembly 2") onto the exact
node id. Same flexible-but-safe pattern as `open_agent_descriptors`:
  * flexibility lives in the label (the model picks among real options);
  * safety lives in the binding — the model must echo the EXACT id, which the
    resolver matches verbatim, and CLOSED nodes are never exposed here (so a spec
    can never reference completed work).

MVP scope: `AssemblyComplete` nodes (the natural "deliverable" milestones). The
root assembly (whose successor is `ProjectComplete`) is labelled distinctly. Labels
are derived purely from schedule/scene-tree structure — no LDraw model needed (the
env does not carry it); richer LDraw part/sub-model names are a later upgrade.
"""
function open_node_descriptors(env)
    sched = env.sched
    tree  = env.scene_tree
    out = Vector{Dict{String,String}}()
    for v in Graphs.vertices(sched)
        v in env.cache.closed_set && continue          # never expose completed work
        node = get_node(sched, v).node
        node isa AssemblyComplete || continue
        idstr = string(get_vtx_id(sched, v))
        aid   = try entity(node).id catch; nothing end
        aid === nothing && continue
        ncomp = try num_components(get_node(tree, aid)) catch; -1 end
        is_root = any(Graphs.outneighbors(sched, v)) do vp
            get_node_from_id(sched, get_vtx_id(sched, vp)) isa ProjectComplete
        end
        # Spatial grounding: tag the staging-area location (north/central/south by
        # the staging circle's y) so the model can ground a zone reference ("the
        # southern area") onto these nodes. Same flexible-but-safe rule — the label
        # is advisory; the binding is still the exact node id.
        dir = if haskey(env.staging_circles, aid)
            y = Float64(LazySets.center(env.staging_circles[aid])[2])
            y > 0.2 ? "north" : y < -0.2 ? "south" : "central"
        else
            ""
        end
        label = is_root ?
            "the final assembly (root of the whole build; $(ncomp) components)" :
            "sub-assembly $(aid.id) ($(ncomp) components)"
        isempty(dir) || (label *= "; located in the $(dir) staging area")
        push!(out, Dict("id" => idstr, "label" => label))
    end
    return out
end

# Typed parse: the one place untrusted JSON becomes typed ConstraintSpec on the
# Julia side. Unknown kind / missing field / unknown id ref throws -> Reject.
function _parse_proposal(payload, event; id_resolver)
    cs = ConstraintSpec[]
    for c in payload["constraints"]
        kind = String(c["kind"])
        spec = if kind == "Precede"
            Precede(id_resolver(String(c["a"])), id_resolver(String(c["b"])))
        elseif kind == "Deadline"
            Deadline(id_resolver(String(c["node"])), Float64(c["tF_max"]))
        elseif kind == "ForbidWindow"
            ForbidWindow(id_resolver(String(c["node"])), Float64(c["t_lo"]), Float64(c["t_hi"]))
        elseif kind == "ForbidAgent"
            ForbidAgent(id_resolver(String(c["agent"])), Float64(get(c, "after", 0.0)))
        else
            error("unknown constraint kind from respec service: $kind")
        end
        push!(cs, spec)
    end
    rationale = haskey(payload, "rationale") ? String(payload["rationale"]) : ""
    return RespecProposal(cs, rationale, String(event))
end
