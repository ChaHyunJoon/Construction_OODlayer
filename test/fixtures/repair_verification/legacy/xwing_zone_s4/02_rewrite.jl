function restore_zone_blocked_goal_reachability!(env;)
    zones = collect(active_restriction_zones())
    zone_keys = [first(zone) for zone in zones]
    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    moved = Set{Any}()

    for blocked_goal in blockage.blocked
        blocked_goal.status === :engulfed || continue
        vtx = blocked_goal.vtx
        (1 <= vtx <= length(env.sched.nodes)) || continue
        sched_node = env.sched.nodes[vtx]
        predicate = sched_node.node
        (hasproperty(predicate, :start_config) && hasproperty(predicate, :goal_config)) || continue

        start_node = start_config(sched_node)
        goal_node = goal_config(sched_node)
        (start_node === nothing || goal_node === nothing || goal_node.id in moved) && continue

        target_transform = global_transform(start_node)
        applied_transform = set_desired_global_transform!(goal_node, target_transform)
        applied_transform === nothing && continue
        push!(moved, goal_node.id)
    end

    resynced = resync_scene_to_schedule!(env)
    reset_result = reset_cache_resume!(env.cache, env.sched)
    preprocessed = preprocess_env!(env)
    advanced = step_environment!(env)
    return (; status = :success)
end