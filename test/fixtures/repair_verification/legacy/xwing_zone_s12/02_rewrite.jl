function prune_blocked_noncompletion_branch!(env;)
    sched = env.sched
    old_graph = sched.graph
    old_nodes = sched.nodes
    old_ids = sched.vtx_ids
    n_old = length(old_nodes)

    blockage = zone_blockage(env; check_paths = false)
    candidates = Int64[]
    for item in blockage.blocked
        v = Int64(item.vtx)
        if 1 <= v <= n_old &&
           item.status == :engulfed &&
           !(v in env.cache.closed_set) &&
           (old_nodes[v].node isa RobotGo || old_nodes[v].node isa TransportUnitGo)
            push!(candidates, v)
        end
    end
    unique!(candidates)
    length(candidates) == 1 ||
        throw(ArgumentError("expected exactly one confirmed unfinished engulfed navigation node"))

    root = only(candidates)
    descendants = Set{Int64}()
    stack = Int64[root]
    while !isempty(stack)
        v = pop!(stack)
        for w in Graphs.outneighbors(old_graph, v)
            wi = Int64(w)
            if !(wi in descendants)
                push!(descendants, wi)
                push!(stack, wi)
            end
        end
    end

    for v in descendants
        old_nodes[v].node isa ProjectComplete &&
            throw(ArgumentError("blocked navigation node has a ProjectComplete descendant"))
        v in env.cache.closed_set &&
            throw(ArgumentError("cannot safely prune a branch containing an already closed descendant"))
    end

    remove_vtxs = copy(descendants)
    push!(remove_vtxs, root)
    keep = Int64[v for v in 1:n_old if !(v in remove_vtxs)]

    old_to_new = zeros(Int64, n_old)
    for (new_v, old_v) in enumerate(keep)
        old_to_new[old_v] = Int64(new_v)
    end

    new_graph = Graphs.SimpleDiGraph(length(keep))
    for edge in Graphs.edges(old_graph)
        s = Int64(Graphs.src(edge))
        d = Int64(Graphs.dst(edge))
        ns = old_to_new[s]
        nd = old_to_new[d]
        if ns != 0 && nd != 0
            Graphs.add_edge!(new_graph, ns, nd)
        end
    end

    new_ids = old_ids[keep]
    new_nodes = old_nodes[keep]
    new_map = empty(sched.vtx_map)
    for (v, id) in enumerate(new_ids)
        new_map[id] = Int64(v)
    end

    new_weights = empty(sched.weights)
    for old_v in keep
        if haskey(sched.weights, old_v)
            new_weights[old_to_new[old_v]] = sched.weights[old_v]
        end
    end

    new_terminal_vtxs = Int64[
        v for v in 1:length(keep) if Graphs.outdegree(new_graph, v) == 0
    ]

    old_closed = copy(env.cache.closed_set)
    old_active = copy(env.cache.active_set)

    # OperatingSchedule is immutable, so replace it as one consistent value.
    new_sched = typeof(sched)(
        new_graph,
        new_nodes,
        new_map,
        new_ids,
        new_terminal_vtxs,
        new_weights,
    )
    env.sched = new_sched

    empty!(env.cache.closed_set)
    empty!(env.cache.active_set)
    for old_v in old_closed
        if 1 <= old_v <= n_old && old_to_new[old_v] != 0
            push!(env.cache.closed_set, old_to_new[old_v])
        end
    end
    for old_v in old_active
        if 1 <= old_v <= n_old && old_to_new[old_v] != 0
            push!(env.cache.active_set, old_to_new[old_v])
        end
    end

    rebuilt_cache = reset_cache_resume!(env.cache, new_sched)
    rebuilt_cache === env.cache || (env.cache = rebuilt_cache)

    return (; status = :success)
end