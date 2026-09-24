function retire_nonessential_blocked_navigation!(env;)
    zone_keys = Symbol[p.first for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone")

    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    length(blockage.blocked) == 1 ||
        error("expected exactly one blocked schedule node")

    blocked = only(blockage.blocked)
    sched = env.sched
    v = get(sched.vtx_map, blocked.id, 0)
    nverts = Graphs.nv(sched.graph)

    (1 <= v <= nverts) || error("blocked vertex is not in the schedule")
    sched.nodes[v].node isa Union{RobotGo, TransportUnitGo} ||
        error("blocked node is not a navigation node")
    !(v in env.cache.closed_set) ||
        error("blocked navigation node is already closed")

    stack = collect(Graphs.outneighbors(sched.graph, v))
    seen = Set{Int}()
    while !isempty(stack)
        u = pop!(stack)
        u in seen && continue
        push!(seen, u)

        sched.nodes[u].node isa ProjectComplete &&
            error("blocked navigation node is an ancestor of ProjectComplete")
        !(u in env.cache.closed_set) &&
            error("blocked navigation node has an unfinished dependent")

        append!(stack, Graphs.outneighbors(sched.graph, u))
    end

    removed_id = sched.vtx_ids[v]
    last_v = nverts
    moved_id = v == last_v ? removed_id : sched.vtx_ids[last_v]

    old_terminals = copy(sched.terminal_vtxs)
    old_weights = copy(sched.weights)

    # No schedule-retirement primitive is exposed, so all coupled schedule
    # containers are updated directly while respecting SimpleDiGraph compaction.
    Graphs.rem_vertex!(sched.graph, v)

    if v != last_v
        sched.nodes[v] = sched.nodes[last_v]
        sched.vtx_ids[v] = sched.vtx_ids[last_v]
        sched.vtx_map[moved_id] = v
    end
    pop!(sched.nodes)
    pop!(sched.vtx_ids)
    delete!(sched.vtx_map, removed_id)

    empty!(sched.terminal_vtxs)
    for t in old_terminals
        t == v && continue
        push!(sched.terminal_vtxs, t == last_v ? v : t)
    end
    unique!(sched.terminal_vtxs)

    empty!(sched.weights)
    for (u, weight) in old_weights
        u == v && continue
        sched.weights[u == last_v ? v : u] = weight
    end

    for vertex_set in (env.cache.closed_set, env.cache.active_set)
        old_vertices = collect(vertex_set)
        empty!(vertex_set)
        for u in old_vertices
            u == v && continue
            push!(vertex_set, u == last_v ? v : u)
        end
    end

    reset_cache_resume!(env.cache, sched)
    return (; status = :success)
end