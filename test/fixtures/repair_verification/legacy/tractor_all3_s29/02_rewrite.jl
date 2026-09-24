function relocate_unreachable_unfinished_goals!(env;)
    zone_entries = collect(active_restriction_zones())
    zone_keys = [entry.first for entry in zone_entries]
    zones = [entry.second for entry in zone_entries]
    if !isempty(zone_keys)
        blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
        open_hits = [hit for hit in blockage.blocked if !(hit.vtx in env.cache.closed_set)]
        moved = Base.IdSet()
        clearance = maximum((agent_disc_radius(agent) for agent in keys(env.agent_policies)); init = 0.0) + 0.25

        for (ordinal, hit) in enumerate(open_hits)
            blocked_node = env.sched.nodes[hit.vtx]
            old_goal = goal_config(blocked_node)
            old_goal in moved && continue

            old_transform = global_transform(old_goal)
            old_position = old_transform(zeros(3))
            primary = first(zone_entries)
            for entry in zone_entries
                if goal_engulfed(old_position, clearance, (entry.second,))
                    primary = entry
                    break
                end
            end

            facts = zone_facts(env, primary.first; check_teams = false, check_blockage = false, check_paths = false)
            angle = 2pi * (ordinal - 1) / max(length(open_hits), 1)
            candidate = facts.center .+ (facts.radius + clearance + 1.0) .* [cos(angle), sin(angle)]

            attempt = 0
            while goal_engulfed(candidate, clearance, zones) && attempt < 64
                attempt += 1
                angle += pi / 8
                radius = facts.radius + clearance + 1.0 + attempt * (2clearance + 0.5)
                candidate = facts.center .+ radius .* [cos(angle), sin(angle)]
            end

            cmd = get_cmd(blocked_node.node, env)
            delta = typeof(cmd.vel)(
                candidate[1] - old_position[1],
                candidate[2] - old_position[2],
                zero(old_position[1])
            )
            relocated_transform = integrate_twist(Twist(delta, zero(cmd.ω)), 1.0) ∘ old_transform

            for (vtx, dependent) in enumerate(env.sched.nodes)
                vtx in env.cache.closed_set && continue
                if dependent.node isa LiftIntoPlace && start_config(dependent) === old_goal
                    set_desired_global_transform!(goal_config(dependent), relocated_transform)
                end
            end

            set_desired_global_transform!(old_goal, relocated_transform)
            push!(moved, old_goal)
        end
    end
    return (; status = :success)
end