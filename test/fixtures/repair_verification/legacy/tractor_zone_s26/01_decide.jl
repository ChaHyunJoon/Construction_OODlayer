function prune_blocked_nongating_branch!(env;)
    zone_keys = [first(zone) for zone in active_restriction_zones()]
    isempty(zone_keys) && throw(ArgumentError("no active exclusion constraint"))

    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    sched = env.sched
    graph = sched.graph
    closed = copy(env.cache.closed_set)

    target = nothing
    for blocked in blockage.blocked
        v = blocked.vtx
        if 1 <= v <= length(sched.nodes) && !(v in closed)
            payload = sched.nodes[v].node
            if payload isa ConstructionBots.RobotGo ||
               payload isa ConstructionBots.TransportUnitGo
                target = v
                break
            end
        end
    end
    target === nothing &&
        throw(ArgumentError("no unfinished blocked navigating schedule node found"))

    completion_vertices = Int[]
    for v in Graphs.vertices(graph)
        if sched.nodes[v].node isa ConstructionBots.ProjectComplete
            push!(completion_vertices, v)
        end
    end
    isempty(completion_vertices) &&
        throw(ArgumentError("schedule has no ProjectComplete node"))

    required = Set{Int}(completion_vertices)
    frontier = copy(completion_vertices)
    while !isempty(frontier)
        v = pop!(frontier)
        for predecessor in Graphs.inneighbors(graph, v)
            if !(predecessor in required)
                push!(required, predecessor)
                push!(frontier, predecessor)
            end
        end
    end

    target in required &&
        throw(ArgumentError("blocked node gates ProjectComplete"))

    remove_vertices = Set{Int}()
    frontier = [target]
    visited = Set{Int}()
    while !isempty(frontier)
        v = pop!(frontier)
        v in visited && continue
        push!(visited, v)

        if !(v in required) && !(v in closed)
            push!(remove_vertices, v)
        end
        append!(frontier, Graphs.outneighbors(graph, v))
    end

    isempty(remove_vertices) &&
        throw(ArgumentError("blocked non-gating branch was already absent"))

    keep_vertices = [v for v in Graphs.vertices(graph) if !(v in remove_vertices)]
    new_graph, new_to_old = Graphs.induced_subgraph(graph, keep_vertices)
    old_to_new = Dict(old => new for (new, old) in enumerate(new_to_old))

    old_nodes = sched.nodes
    old_ids = sched.vtx_ids
    old_terminals = copy(sched.terminal_vtxs)
    old_weights = copy(sched.weights)
    removed_ids = [old_ids[v] for v in remove_vertices]

    # No callable schedule-node removal operation is exposed, so the graph and
    # its index-aligned schedule tables must be rebuilt directly.
    sched.graph = new_graph
    sched.nodes = old_nodes[new_to_old]
    sched.vtx_ids = old_ids[new_to_old]

    empty!(sched.vtx_map)
    for (v, id) in enumerate(sched.vtx_ids)
        sched.vtx_map[id] = v
    end

    sched.terminal_vtxs = [
        old_to_new[v] for v in old_terminals if haskey(old_to_new, v)
    ]

    empty!(sched.weights)
    for (old_v, new_v) in old_to_new
        if haskey(old_weights, old_v)
            sched.weights[new_v] = old_weights[old_v]
        end
    end

    for id in removed_ids
        delete!(env.active_build_steps, id)
    end

    empty!(env.cache.closed_set)
    for old_v in closed
        if haskey(old_to_new, old_v)
            push!(env.cache.closed_set, old_to_new[old_v])
        end
    end
    empty!(env.cache.active_set)
    empty!(env.cache.node_queue)
    reset_cache_resume!(env.cache, sched)

    return (; status = :success)
end