function relocate_blocked_navigation_goal!(env;)
    zones = Dict(active_restriction_zones())
    isempty(zones) && error("no active restriction zone")

    zone_keys = collect(keys(zones))
    initial_report = zone_blockage(env; zone_keys=zone_keys, check_paths=true)
    initial_open = Set(
        b.vtx for b in initial_report.blocked
        if !(b.vtx in env.cache.closed_set)
    )

    target_vtx = nothing
    source_zone = nothing
    for key in zone_keys
        report = zone_blockage(env; zone_keys=[key], check_paths=true)
        for blocked in report.blocked
            v = blocked.vtx
            if !(v in env.cache.closed_set)
                sn = env.sched.nodes[v]
                if sn.node isa Union{ConstructionBots.TransportUnitGo, ConstructionBots.RobotGo}
                    target_vtx = v
                    source_zone = key
                    break
                end
            end
        end
        target_vtx === nothing || break
    end
    target_vtx === nothing && error("no unfinished blocked navigation goal was found")

    sched_node = env.sched.nodes[target_vtx]
    goal_node = goal_config(sched_node)
    start_node = start_config(sched_node)
    old_goal_tf = global_transform(goal_node)
    start_tf = global_transform(start_node)
    goal_position = old_goal_tf(zeros(3))
    start_position = start_tf(zeros(3))

    facts = zone_facts(
        env,
        source_zone;
        check_blockage=true,
        check_paths=true,
    )
    center = Vector{Float64}(facts.center)[1:2]
    zone_radius = Float64(facts.radius)
    agent_radius = Float64(agent_disc_radius(entity(sched_node)))
    radial = goal_position[1:2] .- center
    base_angle = norm(radial) > eps(Float64) ? atan(radial[2], radial[1]) : 0.0
    radial_step = max(agent_radius, zone_radius / 8, sqrt(eps(Float64)))
    placed = false

    for ring in 1:8
        distance = zone_radius + agent_radius + ring * radial_step
        for j in 0:31
            offset_index = j == 0 ? 0 : (isodd(j) ? (j + 1) ÷ 2 : -(j ÷ 2))
            angle = base_angle + offset_index * (2π / 32)
            candidate = center .+ distance .* [cos(angle), sin(angle)]

            goal_engulfed(candidate, agent_radius, zones) && continue
            path_state = free_space_status(
                start_position,
                candidate,
                zones,
                agent_radius,
            )
            path_state in (:engulfed, :disconnected) && continue

            delta = [
                candidate[1] - goal_position[1],
                candidate[2] - goal_position[2],
                0.0,
            ]
            candidate_tf = CoordinateTransformations.Translation(delta) ∘ old_goal_tf
            applied_tf = set_desired_global_transform!(goal_node, candidate_tf)
            tree_valid = validate_schedule_transform_tree(env.sched)

            if tree_valid
                after_report = zone_blockage(
                    env;
                    zone_keys=zone_keys,
                    check_paths=true,
                )
                after_open = Set(
                    b.vtx for b in after_report.blocked
                    if !(b.vtx in env.cache.closed_set)
                )
                if !(target_vtx in after_open) && issubset(after_open, initial_open)
                    placed = true
                    break
                end
            end

            restored_tf = set_desired_global_transform!(goal_node, old_goal_tf)
        end
        placed && break
    end

    if !placed
        restored_tf = set_desired_global_transform!(goal_node, old_goal_tf)
        error("no constraint-preserving reachable placement was found")
    end

    return (; status = :success)
end