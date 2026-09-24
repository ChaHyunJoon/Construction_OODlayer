function relocate_zone_blocked_goal!(env;)
    zone_entries = collect(active_restriction_zones())
    isempty(zone_entries) && error("no active restriction zone is available")

    zone_keys = [entry.first for entry in zone_entries]
    zones = [entry.second for entry in zone_entries]
    baseline = zone_blockage(env; zone_keys = zone_keys, check_paths = true, margin = 0.0)

    blocked_entry = nothing
    for entry in baseline.blocked
        if !(entry.vtx in env.cache.closed_set)
            blocked_entry = entry
            break
        end
    end
    blocked_entry === nothing && error("no unfinished zone-blocked schedule node was measured")

    schedule_node = env.sched.nodes[blocked_entry.vtx]
    goal = goal_config(schedule_node)
    goal === nothing && error("the blocked schedule node has no relocatable goal transform")

    original_transform = global_transform(goal)
    original_position = original_transform([0.0, 0.0, 0.0])
    target_id = blocked_entry.id
    previously_blocked = Set(entry.id for entry in baseline.blocked if entry.id != target_id)

    agent_radius = 0.0
    for agent in keys(env.agent_policies)
        radius = agent_disc_radius(agent)
        radius isa Real && (agent_radius = max(agent_radius, Float64(radius)))
    end

    zone_facts_list = Any[]
    for key in zone_keys
        facts = zone_facts(
            env,
            key;
            margin = 0.0,
            check_teams = false,
            check_blockage = false,
            check_paths = false,
        )
        facts.exists && push!(zone_facts_list, facts)
    end
    isempty(zone_facts_list) && error("active restriction-zone geometry could not be measured")

    anchors = Vector{Vector{Float64}}()
    push!(anchors, [Float64(original_position[1]), Float64(original_position[2])])
    maximum_zone_radius = 0.0
    for facts in zone_facts_list
        center = Vector{Float64}(facts.center)
        push!(anchors, center[1:2])
        maximum_zone_radius = max(maximum_zone_radius, Float64(facts.radius))
    end

    clearance = max(0.1, 0.25 * max(agent_radius, maximum_zone_radius))
    radial_step = max(clearance, maximum_zone_radius + agent_radius + clearance)
    accepted = false

    for ring in 1:16
        accepted && break
        distance = ring * radial_step
        for anchor in anchors
            accepted && break
            for direction in 0:23
                angle = 2π * direction / 24
                candidate = [
                    anchor[1] + distance * cos(angle),
                    anchor[2] + distance * sin(angle),
                ]

                goal_engulfed(
                    candidate,
                    agent_radius,
                    zones;
                    ttol = 0.0,
                    margin = clearance,
                ) && continue

                displacement = StaticArraysCore.SVector{3, Float64}(
                    candidate[1] - Float64(original_position[1]),
                    candidate[2] - Float64(original_position[2]),
                    0.0,
                )
                zero_rotation = StaticArraysCore.SVector{3, Float64}(0.0, 0.0, 0.0)
                shift = integrate_twist(Twist(displacement, zero_rotation), 1.0)

                # The scene-tree setter preserves the tree's transform invariants and
                # causes dependent child geometry to follow the relocated goal.
                set_desired_global_transform!(goal, shift ∘ original_transform)

                probe = zone_blockage(
                    env;
                    zone_keys = zone_keys,
                    check_paths = true,
                    margin = 0.0,
                )
                target_clear = all(entry.id != target_id for entry in probe.blocked)
                no_new_blockage = all(entry.id in previously_blocked for entry in probe.blocked)

                if target_clear && no_new_blockage && !probe.project_blocked
                    accepted = true
                    break
                end

                set_desired_global_transform!(goal, original_transform)
            end
        end
    end

    if !accepted
        set_desired_global_transform!(goal, original_transform)
        error("no reachable collision-free relocation preserving completion was found")
    end

    return (; status = :success)
end