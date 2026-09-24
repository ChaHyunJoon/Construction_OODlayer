function relocate_blocked_navigation_goal!(env;)
    initial_report = zone_blockage(env; check_paths = true)
    engulfed = [b for b in initial_report.blocked if b.status == :engulfed]
    length(engulfed) == 1 || error("expected exactly one engulfed unfinished navigation goal")

    blocked = only(engulfed)
    blocked_node = env.sched.nodes[blocked.vtx]
    predicate = blocked_node.node
    (predicate isa RobotGo || predicate isa TransportUnitGo) ||
        error("the uniquely engulfed node is not a navigating operation")

    target = goal_config(blocked_node)
    old_target_tf = global_transform(target)
    cmd = get_cmd(predicate, env)
    origin = zero(cmd.vel)
    old_position = Vector{Float64}(old_target_tf(origin))
    zones = restriction_zones()

    nav_entity = entity(blocked_node)
    agent_radius = try
        Float64(agent_disc_radius(nav_entity))
    catch
        radii = Float64[]
        for agent in keys(env.agent_policies)
            try
                push!(radii, Float64(agent_disc_radius(agent)))
            catch
            end
        end
        isempty(radii) ? 1.0 : maximum(radii)
    end
    search_scale = max(agent_radius, 1.0)

    away = zeros(Float64, 2)
    for zone in values(zones)
        center = get_center(zone)
        dx = old_position[1] - Float64(center[1])
        dy = old_position[2] - Float64(center[2])
        d = sqrt(dx * dx + dy * dy)
        if d > eps(Float64)
            away[1] += dx / d
            away[2] += dy / d
        end
    end
    base_angle = (abs(away[1]) + abs(away[2]) > eps(Float64)) ?
                 atan(away[2], away[1]) : 0.0

    chosen_delta = nothing
    for ring in 0:12
        distance = search_scale * (2.0 ^ ring)
        for spoke in 0:31
            angle = base_angle + 2.0 * pi * spoke / 32.0
            dx = distance * cos(angle)
            dy = distance * sin(angle)
            displacement = typeof(cmd.vel)(dx, dy, 0.0)
            trial_twist = typeof(cmd)(displacement, zero(cmd.ω))
            trial_tf = integrate_twist(trial_twist, 1.0) ∘ old_target_tf

            set_desired_global_transform!(target, trial_tf)
            trial_report = try
                zone_blockage(env; check_paths = true)
            finally
                set_desired_global_transform!(target, old_target_tf)
            end

            still_blocked = any(b -> b.id == blocked.id, trial_report.blocked)
            if !still_blocked && isempty(trial_report.blocked)
                chosen_delta = displacement
                break
            end
        end
        chosen_delta === nothing || break
    end
    chosen_delta === nothing &&
        error("no reachable geometrically valid alternative placement was found")

    targets = Base.IdSet{Any}()
    push!(targets, target)

    cargo_id = nav_entity isa TransportUnitNode ? first(nav_entity.cargo) : nothing
    for (vtx, schedule_node) in enumerate(env.sched.nodes)
        vtx in env.cache.closed_set && continue
        op = schedule_node.node

        if op isa DepositCargo && op.entity === nav_entity
            push!(targets, op.config)
            push!(targets, cargo_goal_config(op))
        elseif op isa FormTransportUnit && op.entity === nav_entity
            push!(targets, op.config)
            push!(targets, cargo_goal_config(op))
        elseif op isa LiftIntoPlace && cargo_id !== nothing
            lift_entity_id = hasproperty(op.entity, :id) ? getproperty(op.entity, :id) : op.entity
            if lift_entity_id == cargo_id
                push!(targets, op.start_config)
                push!(targets, op.goal_config)
            end
        end
    end

    saved = Tuple{Any,Any}[]
    relocation_twist = typeof(cmd)(chosen_delta, zero(cmd.ω))
    relocation = integrate_twist(relocation_twist, 1.0)
    for transform_node in targets
        old_tf = global_transform(transform_node)
        push!(saved, (transform_node, old_tf))
        set_desired_global_transform!(transform_node, relocation ∘ old_tf)
    end

    valid_tree = validate_schedule_transform_tree(env.sched)
    final_report = zone_blockage(env; check_paths = true)
    blocked_after = any(b -> b.id == blocked.id, final_report.blocked)
    if !valid_tree || blocked_after
        for (transform_node, old_tf) in reverse(saved)
            set_desired_global_transform!(transform_node, old_tf)
        end
        error("relocated transforms failed scene-tree or reachability validation")
    end

    return (; status = :success)
end