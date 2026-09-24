function relocate_unreachable_unfinished_goals!(env;)
    zone_keys = Symbol[p.first for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone is available for relocation analysis")

    margin = 0.25
    initial = zone_blockage(env; zone_keys = zone_keys, check_paths = true, margin = margin)

    affected_ids = Set{Any}()
    targets = Tuple{Any, Int64, Any}[]
    seen_configs = Base.IdSet{Any}()

    for blocked in initial.blocked
        v = blocked.vtx
        v in env.cache.closed_set && continue
        id = blocked.id
        push!(affected_ids, id)
        sched_node = env.sched.nodes[v]
        config = goal_config(sched_node)
        if !(config in seen_configs)
            push!(seen_configs, config)
            push!(targets, (id, v, config))
        end
    end

    isempty(targets) && error("no unfinished zone-blocked navigation goals were found")

    agent_radius = 0.0
    for agent in keys(env.agent_policies)
        agent_radius = max(agent_radius, Float64(agent_disc_radius(agent)))
    end

    zone_data = NamedTuple[]
    for key in zone_keys
        facts = zone_facts(env, key; margin = margin, check_teams = false,
                           check_blockage = false, check_paths = false)
        facts.exists || continue
        center = Vector{Float64}(facts.center)
        push!(zone_data, (; center = center, radius = Float64(facts.radius)))
    end
    isempty(zone_data) && error("active exclusion-zone geometry could not be inspected")

    for (target_id, target_vtx, config) in targets
        old_transform = global_transform(config)
        old_position = old_transform([0.0, 0.0, 0.0])
        relocated = false
        placement_attempts = 0

        for zone in zone_data
            base_step = max(0.5 * zone.radius, agent_radius + margin)
            for ring in 1:16
                candidate_radius = zone.radius + agent_radius + margin + ring * base_step
                for sector in 0:31
                    placement_attempts += 1
                    angle = 2.0 * pi * sector / 32.0
                    candidate_x = zone.center[1] + candidate_radius * cos(angle)
                    candidate_y = zone.center[2] + candidate_radius * sin(angle)
                    dx = candidate_x - Float64(old_position[1])
                    dy = candidate_y - Float64(old_position[2])

                    velocity = StaticArraysCore.SVector{3, Float64}(dx, dy, 0.0)
                    omega = StaticArraysCore.SVector{3, Float64}(0.0, 0.0, 0.0)
                    displacement = integrate_twist(Twist(velocity, omega), 1.0)
                    candidate_transform = displacement ∘ old_transform

                    set_desired_global_transform!(config, candidate_transform)
                    verdict = zone_blockage(env; zone_keys = zone_keys,
                                             check_paths = true, margin = margin)

                    still_blocked = any(entry -> entry.id == target_id, verdict.blocked)
                    if !still_blocked
                        relocated = true
                        break
                    end

                    set_desired_global_transform!(config, old_transform)
                end
                relocated && break
            end
            relocated && break
        end

        if !relocated
            set_desired_global_transform!(config, old_transform)
            error("no legal reachable relocation was found for an affected unfinished goal")
        end

        # No listed verb records planning/restaging time, so update its schedule weight directly.
        planning_time = placement_attempts * max(Float64(env.dt), eps(Float64))
        env.sched.weights[target_vtx] = get(env.sched.weights, target_vtx, 0.0) + planning_time
    end

    final_verdict = zone_blockage(env; zone_keys = zone_keys,
                                   check_paths = true, margin = margin)
    unresolved = any(entry -> entry.id in affected_ids, final_verdict.blocked)
    unresolved && error("one or more originally unreachable unfinished goals remain blocked")

    return (; status = :success)
end