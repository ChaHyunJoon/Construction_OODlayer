function abandon_unreachable_noncompletion_branch!(env;)
    sched = env.sched
    invariant = build_invariant(env)
    closed_ids = invariant.closed_nodes
    zone_keys = [first(p) for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone")

    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    candidate_ids = Set{eltype(sched.vtx_ids)}()
    for blocked in blockage.blocked
        id = blocked.id
        haskey(sched.vtx_map, id) || continue
        id in closed_ids && continue
        node = sched.nodes[sched.vtx_map[id]].node
        node isa Union{RobotGo, TransportUnitGo} || continue
        haskey(invariant.frozen_t0, id) || continue
        haskey(invariant.frozen_tF, id) || continue

        candidate_v = sched.vtx_map[id]
        has_completion_downstream = false
        candidate_seen = Set{Int64}([candidate_v])
        candidate_stack = Int64[candidate_v]
        while !isempty(candidate_stack)
            v = pop!(candidate_stack)
            for child_v in Graphs.outneighbors(sched.graph, v)
                child_v in candidate_seen && continue
                push!(candidate_seen, child_v)
                push!(candidate_stack, child_v)
                if sched.nodes[child_v].node isa ProjectComplete
                    has_completion_downstream = true
                    break
                end
            end
            has_completion_downstream && break
        end
        has_completion_downstream && continue
        push!(candidate_ids, id)
    end
    length(candidate_ids) == 1 ||
        error("expected exactly one frozen unfinished zone-blocked navigating node without downstream ProjectComplete")

    target_id = first(candidate_ids)
    haskey(invariant.frozen_t0, target_id) &&
        haskey(invariant.frozen_tF, target_id) ||
        error("the blocked navigating node is not frozen in total")

    target_v = sched.vtx_map[target_id]
    descendants = Set{eltype(sched.vtx_ids)}()
    seen = Set{Int64}([target_v])
    stack = Int64[target_v]
    while !isempty(stack)
        v = pop!(stack)
        for child_v in Graphs.outneighbors(sched.graph, v)
            child_v in seen && continue
            push!(seen, child_v)
            push!(stack, child_v)
            child_id = sched.vtx_ids[child_v]
            push!(descendants, child_id)
            sched.nodes[child_v].node isa ProjectComplete &&
                error("a ProjectComplete node is downstream of the blocked node")
        end
    end

    remove_ids = Set{eltype(sched.vtx_ids)}([target_id])
    changed = true
    while changed
        changed = false
        for parent_id in collect(remove_ids)
            haskey(sched.vtx_map, parent_id) || continue
            parent_v = sched.vtx_map[parent_id]
            for child_v in Graphs.outneighbors(sched.graph, parent_v)
                child_id = sched.vtx_ids[child_v]
                child_id in remove_ids && continue
                child_id in closed_ids && continue
                sched.nodes[child_v].node isa ProjectComplete && continue
                predecessors = Graphs.inneighbors(sched.graph, child_v)
                exclusively_dependent = all(pre_v -> begin
                    predecessor_id = sched.vtx_ids[pre_v]
                    predecessor_id in remove_ids || predecessor_id in closed_ids
                end, predecessors)
                if exclusively_dependent
                    push!(remove_ids, child_id)
                    changed = true
                end
            end
        end
    end

    # No callable schedule-node removal operation is exposed, so the graph and
    # its parallel index structures must be updated together.
    for id in collect(remove_ids)
        haskey(sched.vtx_map, id) || continue
        v = sched.vtx_map[id]
        last_v = Graphs.nv(sched.graph)
        moved_id = sched.vtx_ids[last_v]
        moved_node = sched.nodes[last_v]
        moved_has_weight = haskey(sched.weights, last_v)
        moved_weight = moved_has_weight ? sched.weights[last_v] : 0.0

        removed_ok = Graphs.rem_vertex!(sched.graph, v)
        removed_ok || error("failed to remove schedule vertex")

        delete!(sched.vtx_map, id)
        delete!(sched.weights, v)
        if v != last_v
            sched.vtx_ids[v] = moved_id
            sched.nodes[v] = moved_node
            sched.vtx_map[moved_id] = v
            if moved_has_weight
                sched.weights[v] = moved_weight
            else
                delete!(sched.weights, v)
            end
            delete!(sched.weights, last_v)
        end
        pop!(sched.vtx_ids)
        pop!(sched.nodes)
        delete!(env.active_build_steps, id)
    end

    empty!(sched.terminal_vtxs)
    for v in Graphs.vertices(sched.graph)
        Graphs.outdegree(sched.graph, v) == 0 && push!(sched.terminal_vtxs, v)
    end

    for id in closed_ids
        id in remove_ids && error("attempted to remove a closed schedule node")
    end

    cache_after = reset_cache_resume!(env.cache, sched)
    cache_after === env.cache || (env.cache = cache_after)
    return (; status = :success)
end