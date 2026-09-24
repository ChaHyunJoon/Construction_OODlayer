function relocate_unreachable_navigation_goal!(env;)
    zone_pairs = collect(active_restriction_zones())
    isempty(zone_pairs) && error("no active restriction zone")

    zone_keys = first.(zone_pairs)
    initial = zone_blockage(env; zone_keys = zone_keys, check_paths = true, margin = 0.0)
    blocked_index = findfirst(initial.blocked) do item
        !(item.vtx in env.cache.closed_set) &&
            (item.status === :engulfed || item.status === :disconnected)
    end
    blocked_index === nothing && error("no unfinished blocked navigation goal")
    blocked = initial.blocked[blocked_index]

    responsible_zone = nothing
    for key in zone_keys
        single = zone_blockage(env; zone_keys = [key], check_paths = true, margin = 0.0)
        if any(item -> item.id == blocked.id, single.blocked)
            responsible_zone = key
            break
        end
    end
    responsible_zone === nothing && error("could not identify the responsible restriction zone")

    facts = zone_facts(
        env,
        responsible_zone;
        margin = 0.0,
        check_teams = false,
        check_blockage = true,
        check_paths = true,
    )
    center = Vector{Float64}(facts.center)
    radius = Float64(facts.radius)

    schedule_node = env.sched.nodes[blocked.vtx]
    goal_node = goal_config(schedule_node)
    original_transform = global_transform(goal_node)

    origin = zeros(Float64, 3)
    goal_position = Vector{Float64}(original_transform(origin))
    start_node = start_config(schedule_node)
    start_position = Vector{Float64}(global_transform(start_node)(origin))

    moving_entity = entity(schedule_node)
    mover_id = hasproperty(moving_entity, :robots) ?
        first(keys(moving_entity.robots)) : moving_entity.id
    mover_radius = Float64(agent_disc_radius(mover_id))

    dx = goal_position[1] - center[1]
    dy = goal_position[2] - center[2]
    if hypot(dx, dy) <= sqrt(eps(Float64))
        dx = start_position[1] - center[1]
        dy = start_position[2] - center[2]
    end
    base_angle = hypot(dx, dy) <= sqrt(eps(Float64)) ? 0.0 : atan(dy, dx)
    clearance = max(mover_radius, sqrt(eps(Float64)) * max(abs(radius), 1.0))

    placed = false
    for ring in 0:3
        candidate_radius = radius + (ring + 2) * clearance
        for offset_index in 0:31
            angle = base_angle + offset_index * (2π / 32)
            candidate_x = center[1] + candidate_radius * cos(angle)
            candidate_y = center[2] + candidate_radius * sin(angle)
            delta_x = candidate_x - goal_position[1]
            delta_y = candidate_y - goal_position[2]

            velocity = StaticArraysCore.SVector{3, Float64}(
                delta_x / env.dt,
                delta_y / env.dt,
                0.0,
            )
            angular_velocity = StaticArraysCore.SVector{3, Float64}(0.0, 0.0, 0.0)
            displacement = integrate_twist(
                ConstructionBots.Twist(velocity, angular_velocity),
                env.dt,
            )
            candidate_transform = displacement ∘ original_transform
            set_desired_global_transform!(goal_node, candidate_transform)

            revised = zone_blockage(
                env;
                zone_keys = zone_keys,
                check_paths = true,
                margin = 0.0,
            )
            if !any(item -> item.id == blocked.id, revised.blocked)
                placed = true
                break
            end
        end
        placed && break
    end

    if !placed
        set_desired_global_transform!(goal_node, original_transform)
        error("no reachable task-equivalent goal placement was found")
    end

    # No listed function records intervention time in schedule weights.
    env.sched.weights[blocked.vtx] = get(env.sched.weights, blocked.vtx, 0.0) + env.dt

    return (; status = :success)
end