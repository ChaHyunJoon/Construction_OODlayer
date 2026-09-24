function relocate_blocked_work_geometry!(env)
    blockage = zone_blockage(env)
    blocked_nav = nothing

    # No listed accessor maps a blockage record back to its schedule wrapper,
    # so the reported schedule vertex must be read from the schedule directly.
    for blocked in blockage.blocked
        v = blocked.vtx
        if !(v in env.cache.closed_set)
            predicate = env.sched.nodes[v].node
            if predicate isa TransportUnitGo || predicate isa RobotGo
                blocked_nav = (record = blocked, wrapper = env.sched.nodes[v])
                break
            end
        end
    end
    blocked_nav === nothing && error("no unfinished blocked navigation node was found")

    nav_wrapper = blocked_nav.wrapper
    nav_id = nav_wrapper.id
    blocked_goal = goal_config(nav_wrapper)
    blocked_start = start_config(nav_wrapper)
    original_goal_tf = global_transform(blocked_goal)

    affected_ids = zone_blocked_assemblies(env)
    affected_nodes = Any[]
    affected_original_tfs = Any[]
    for id in affected_ids
        if haskey(env.scene_tree.vtx_map, id)
            scene_node = env.scene_tree.nodes[env.scene_tree.vtx_map[id]]
            push!(affected_nodes, scene_node)
            push!(affected_original_tfs, global_transform(scene_node))
        end
    end

    # Existing navigation starts are already established, normally reachable
    # scene-tree configurations and therefore provide world-derived candidates.
    candidates = Any[global_transform(blocked_start)]
    for (v, wrapper) in enumerate(env.sched.nodes)
        if !(v in env.cache.closed_set)
            predicate = wrapper.node
            if predicate isa TransportUnitGo || predicate isa RobotGo
                push!(candidates, global_transform(start_config(wrapper)))
            end
        end
    end

    relocated = false
    for candidate_tf in candidates
        rigid_delta = candidate_tf ∘ inv(original_goal_tf)
        set_desired_global_transform!(blocked_goal, candidate_tf)

        for i in eachindex(affected_nodes)
            set_desired_global_transform!(
                affected_nodes[i],
                rigid_delta ∘ affected_original_tfs[i],
            )
        end

        remaining = zone_blockage(env)
        nav_still_blocked = any(item -> item.id == nav_id, remaining.blocked)
        remaining_assemblies = zone_blocked_assemblies(env)
        work_still_blocked = any(id -> id in remaining_assemblies, affected_ids)
        tree_valid = validate_schedule_transform_tree(env.sched)

        if !nav_still_blocked && !work_still_blocked && tree_valid
            relocated = true
            break
        end
    end

    if !relocated
        set_desired_global_transform!(blocked_goal, original_goal_tf)
        for i in eachindex(affected_nodes)
            set_desired_global_transform!(
                affected_nodes[i],
                affected_original_tfs[i],
            )
        end
        error("no reachable valid relocation candidate was found")
    end

    reset_cache_resume!(env.cache, env.sched)
    update_planning_cache!(env, nav_wrapper.spec.t0)

    return (; status = :success)
end