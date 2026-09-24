function prune_blocked_noncritical_branch!(env;)
    iterate(active_restriction_zones()) === nothing &&
        error("no active exclusion zone")

    blockage = zone_blockage(env; check_paths = true)
    sched = env.sched
    old_n = length(sched.nodes)
    old_closed = copy(env.cache.closed_set)

    candidates = Int64[]
    for blocked in blockage.blocked
        v = Int64(blocked.vtx)
        if 1 <= v <= old_n && !(v in old_closed)
            predicate = sched.nodes[v].node
            if predicate isa RobotGo || predicate isa TransportUnitGo
                push!(candidates, v)
            end
        end
    end
    unique!(candidates)
    length(candidates) == 1 ||
        error("expected exactly one unfinished navigation node blocked by the active zone")

    root = candidates[1]
    removed = falses(old_n)
    stack = Int64[root]
    while !isempty(stack)
        v = pop!(stack)
        removed[v] && continue
        removed[v] = true
        for child in Graphs.outneighbors(sched.graph, v)
            !removed[child] && push!(stack, Int64(child))
        end
    end

    for v in 1:old_n
        if removed[v] && sched.nodes[v].node isa ProjectComplete
            error("blocked branch is completion-critical")
        end
    end

    keep = Int64[v for v in 1:old_n if !removed[v]]
    old_to_new = zeros(Int64, old_n)
    for (new_v, old_v) in enumerate(keep)
        old_to_new[old_v] = Int64(new_v)
    end

    new_graph = Graphs.SimpleDiGraph(length(keep))
    for edge in Graphs.edges(sched.graph)
        old_src = Int64(Graphs.src(edge))
        old_dst = Int64(Graphs.dst(edge))
        new_src = old_to_new[old_src]
        new_dst = old_to_new[old_dst]
        if new_src != 0 && new_dst != 0
            Graphs.add_edge!(new_graph, new_src, new_dst)
        end
    end

    new_nodes = copy(sched.nodes[keep])
    new_ids = copy(sched.vtx_ids[keep])
    new_map = empty(copy(sched.vtx_map))
    for (v, id) in enumerate(new_ids)
        new_map[id] = Int64(v)
    end

    new_weights = empty(copy(sched.weights))
    for old_v in keep
        if haskey(sched.weights, old_v)
            new_weights[old_to_new[old_v]] = sched.weights[old_v]
        end
    end

    new_terminals = Int64[]
    for v in 1:length(keep)
        Graphs.outdegree(new_graph, v) == 0 && push!(new_terminals, Int64(v))
    end

    new_closed = Set{Int64}()
    for old_v in old_closed
        if 1 <= old_v <= old_n && old_to_new[old_v] != 0
            push!(new_closed, old_to_new[old_v])
        end
    end

    removed_ids = copy(sched.vtx_ids[findall(removed)])

    # No callable schedule-removal primitive is exposed, so rebuild the
    # schedule's aligned graph records directly.
    sched.graph = new_graph
    sched.nodes = new_nodes
    sched.vtx_ids = new_ids
    sched.vtx_map = new_map
    sched.weights = new_weights
    sched.terminal_vtxs = new_terminals

    for id in removed_ids
        delete!(env.active_build_steps, id)
    end

    empty!(env.cache.closed_set)
    union!(env.cache.closed_set, new_closed)
    reset_cache_resume!(env.cache, sched)

    return (; status = :success)
end