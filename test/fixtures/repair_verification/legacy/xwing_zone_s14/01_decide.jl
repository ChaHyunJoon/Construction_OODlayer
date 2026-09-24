function prune_blocked_nonessential_work!(env;)
    zone_keys = Symbol[first(p) for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone")

    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    sched = env.sched
    project_vtxs = Int[
        v for v in eachindex(sched.nodes)
        if sched.nodes[v].node isa ProjectComplete
    ]
    isempty(project_vtxs) && error("schedule has no ProjectComplete node")

    candidates = Int[]
    for item in blockage.blocked
        v = item.vtx
        if 1 <= v <= length(sched.nodes) &&
           !(v in env.cache.closed_set) &&
           (item.status == :engulfed || item.status == :disconnected)
            predicate = sched.nodes[v].node
            if predicate isa RobotGo || predicate isa TransportUnitGo
                if all(!Graphs.has_path(sched.graph, v, p) for p in project_vtxs)
                    push!(candidates, v)
                end
            end
        end
    end
    unique!(candidates)
    length(candidates) == 1 ||
        error("expected exactly one unfinished, blocked, nonessential navigation node")

    blocked_vtx = only(candidates)

    remove_vtxs = Set{Int}([blocked_vtx])
    frontier = Int[blocked_vtx]
    while !isempty(frontier)
        v = pop!(frontier)
        for child in Graphs.outneighbors(sched.graph, v)
            if !(child in remove_vtxs)
                push!(remove_vtxs, child)
                push!(frontier, child)
            end
        end
    end

    any(v in remove_vtxs for v in project_vtxs) &&
        error("blocked branch reaches ProjectComplete")

    remove_ids = [sched.vtx_ids[v] for v in remove_vtxs]

    # No callable schedule-removal primitive is exposed, so maintain the
    # OperatingSchedule's parallel vertex-indexed storage around rem_vertex!.
    for removed_id in remove_ids
        haskey(sched.vtx_map, removed_id) || continue
        v = sched.vtx_map[removed_id]
        last_v = Graphs.nv(sched.graph)

        moved_id = sched.vtx_ids[last_v]
        moved_node = sched.nodes[last_v]
        moved_has_weight = haskey(sched.weights, last_v)
        moved_weight = moved_has_weight ? sched.weights[last_v] : 0.0

        Graphs.rem_vertex!(sched.graph, v) ||
            error("failed to remove abandoned schedule vertex")

        if v != last_v
            sched.vtx_ids[v] = moved_id
            sched.nodes[v] = moved_node
            sched.vtx_map[moved_id] = v
        end
        pop!(sched.vtx_ids)
        pop!(sched.nodes)
        delete!(sched.vtx_map, removed_id)

        delete!(sched.weights, v)
        if v != last_v
            delete!(sched.weights, last_v)
            moved_has_weight && (sched.weights[v] = moved_weight)
        end

        updated_terminals = Int[]
        for t in sched.terminal_vtxs
            t == v && continue
            push!(updated_terminals, t == last_v ? v : t)
        end
        empty!(sched.terminal_vtxs)
        append!(sched.terminal_vtxs, updated_terminals)

        delete!(env.active_build_steps, removed_id)
    end

    reset_cache_resume!(env.cache, sched)
    return (; status = :success)
end