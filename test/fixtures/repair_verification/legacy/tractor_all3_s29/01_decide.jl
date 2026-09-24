function relocate_unreachable_unfinished_goals!(env;)
    zone_keys = [entry.first for entry in active_restriction_zones()]
    if !isempty(zone_keys)
        blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
        for hit in blockage.blocked
            hit.vtx in env.cache.closed_set && continue
            blocked_node = env.sched.nodes[hit.vtx]
            old_goal = goal_config(blocked_node)
            new_transform = global_transform(start_config(blocked_node))

            for (vtx, candidate) in enumerate(env.sched.nodes)
                vtx in env.cache.closed_set && continue
                if candidate.node isa LiftIntoPlace && start_config(candidate) === old_goal
                    set_desired_global_transform!(goal_config(candidate), new_transform)
                end
            end

            set_desired_global_transform!(old_goal, new_transform)
        end
    end
    return (; status = :success)
end