function prune_isolated_unreachable_goal!(env;)
    blockage = zone_blockage(env; check_paths = true)

    candidates = Int[]
    for blocked in blockage.blocked
        v = blocked.vtx
        if 1 <= v <= length(env.sched.nodes) &&
           !(v in env.cache.closed_set) &&
           (blocked.status === :engulfed || blocked.status === :disconnected)
            predicate = env.sched.nodes[v].node
            if predicate isa Union{ConstructionBots.RobotGo, ConstructionBots.TransportUnitGo}
                push!(candidates, v)
            end
        end
    end
    unique!(candidates)

    eligible = Int[]
    for v in candidates
        stack = collect(Graphs.outneighbors(env.sched.graph, v))
        seen = Set{Int}()
        valid = true
        while !isempty(stack)
            u = pop!(stack)
            u in seen && continue
            push!(seen, u)

            if env.sched.nodes[u].node isa ConstructionBots.ProjectComplete ||
               !(u in env.cache.closed_set)
                valid = false
                break
            end
            append!(stack, Graphs.outneighbors(env.sched.graph, u))
        end
        valid && push!(eligible, v)
    end

    length(eligible) == 1 ||
        error("expected exactly one isolated unreachable navigating node")

    v = only(eligible)
    n = Graphs.nv(env.sched.graph)
    cancelled_id = env.sched.vtx_ids[v]
    old_closed = copy(env.cache.closed_set)

    removed = Graphs.rem_vertex!(env.sched.graph, v)
    removed || error("schedule graph refused to remove the cancelled node")

    # No listed schedule-cancellation primitive exists, so the schedule's
    # vertex-aligned storage must follow Graphs.rem_vertex!'s swap-with-last.
    if v != n
        env.sched.nodes[v] = env.sched.nodes[n]
        env.sched.vtx_ids[v] = env.sched.vtx_ids[n]
    end
    pop!(env.sched.nodes)
    pop!(env.sched.vtx_ids)

    moved_weight = v != n && haskey(env.sched.weights, n) ?
                   env.sched.weights[n] : nothing
    delete!(env.sched.weights, v)
    delete!(env.sched.weights, n)
    moved_weight === nothing || (env.sched.weights[v] = moved_weight)

    empty!(env.sched.vtx_map)
    for (i, id) in enumerate(env.sched.vtx_ids)
        env.sched.vtx_map[id] = i
    end

    empty!(env.sched.terminal_vtxs)
    for i in 1:Graphs.nv(env.sched.graph)
        Graphs.outdegree(env.sched.graph, i) == 0 &&
            push!(env.sched.terminal_vtxs, i)
    end

    empty!(env.cache.closed_set)
    for u in old_closed
        u == v && continue
        push!(env.cache.closed_set, v != n && u == n ? v : u)
    end

    delete!(env.active_build_steps, cancelled_id)
    reset_cache_resume!(env.cache, env.sched)

    return (; status = :success)
end