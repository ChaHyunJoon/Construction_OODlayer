function relocate_zone_blocked_work_geometry!(env;)
    zone_keys = collect(keys(restriction_zones()))
    isempty(zone_keys) && return (; status = :success)

    report = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    max_passes = length(env.sched.nodes) + 1

    for _ in 1:max_passes
        isempty(report.blocked) && break
        progress = false

        for blocked_goal in collect(report.blocked)
            sched_node = env.sched.nodes[blocked_goal.vtx]
            destination = goal_config(sched_node)
            origin = start_config(sched_node)
            prior_transform = global_transform(destination)

            candidates = Any[global_transform(origin)]
            for role in keys(env.agent_policies)
                if haskey(env.scene_tree.vtx_map, role)
                    scene_node = env.scene_tree.nodes[env.scene_tree.vtx_map[role]]
                    push!(candidates, global_transform(scene_node))
                end
            end

            accepted = false
            for candidate in candidates
                # The supported setter preserves scene-tree transform invariants and
                # intentionally carries dependent child geometry with the destination.
                set_desired_global_transform!(destination, candidate)
                trial = zone_blockage(env; zone_keys = zone_keys, check_paths = true)

                if all(entry -> entry.id != blocked_goal.id, trial.blocked)
                    report = trial
                    progress = true
                    accepted = true
                    break
                end

                set_desired_global_transform!(destination, prior_transform)
            end

            if !accepted
                set_desired_global_transform!(destination, prior_transform)
            end
        end

        progress || break
        report = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    end

    isempty(report.blocked) || error("No valid reachable scene-tree placement was found for every zone-blocked navigation goal")
    return (; status = :success)
end