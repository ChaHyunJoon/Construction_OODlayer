function restore_blocked_navigation_goal_reachability!(env;)
    zone_keys = Symbol[p.first for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone")

    before = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    length(before.blocked) == 1 || error("expected exactly one blocked navigation goal")

    blocked = first(before.blocked)
    sched_node = env.sched.nodes[blocked.vtx]
    goal = goal_config(sched_node)
    mover = entity(sched_node)

    original_goal = global_transform(goal)
    reachable_goal = global_transform(mover)
    placed_goal = set_desired_global_transform!(goal, reachable_goal)

    tree_valid = validate_schedule_transform_tree(env.sched)
    after = zone_blockage(env; zone_keys = zone_keys, check_paths = true)

    closure_preserved =
        after.n_blocked == 0 &&
        after.n_disconnected == 0 &&
        after.n_engulfed == 0 &&
        after.n_downstream == 0 &&
        after.n_completion_blocked == 0 &&
        after.n_agent_trapped == 0 &&
        after.project_blocked !== true

    if !tree_valid || !closure_preserved
        restored_goal = set_desired_global_transform!(goal, original_goal)
        error("no exclusion-compliant semantically consistent relocation was admitted")
    end

    return (; status = :success)
end