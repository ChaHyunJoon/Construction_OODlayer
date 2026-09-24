function relocate_exclusion_blocked_goal_geometry!(env;)
    zone_keys = Symbol[]
    for (key, _) in active_restriction_zones()
        push!(zone_keys, key)
    end
    isempty(zone_keys) && error("no active exclusion zone was found")

    before = zone_blockage(env; zone_keys = zone_keys)
    targets = Any[]
    for blocked in before.blocked
        v = blocked.vtx
        if !(v in env.cache.closed_set)
            predicate = env.sched.nodes[v].node
            if blocked.status === :engulfed &&
               (predicate isa TransportUnitGo || predicate isa RobotGo)
                push!(targets, (; id = blocked.id, vtx = v))
            end
        end
    end
    isempty(targets) && error("no unfinished engulfed navigating goal was found")

    for target in targets
        schedule_node = env.sched.nodes[target.vtx]
        source_config = start_config(schedule_node)
        destination_config = goal_config(schedule_node)
        desired_transform = global_transform(source_config)

        set_desired_global_transform!(destination_config, desired_transform)
        reached = is_within_capture_distance(
            global_transform(destination_config),
            desired_transform,
        )
        reached === true ||
            error("scene-tree destination relocation did not take effect")
    end

    tree_valid = validate_schedule_transform_tree(env.sched)
    tree_valid === true ||
        error("relocation produced an inconsistent schedule transform tree")

    after = zone_blockage(env; zone_keys = zone_keys)
    for blocked in after.blocked
        if any(target -> target.id == blocked.id, targets)
            error("a relocated navigating goal remains blocked")
        end
    end
    after.project_blocked === false ||
        error("project completion remains blocked after relocation")

    return (; status = :success)
end