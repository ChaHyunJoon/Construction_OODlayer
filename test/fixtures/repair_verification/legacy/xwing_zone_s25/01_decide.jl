function relocate_exclusion_blocked_work_goals!(env;)
    blockage = zone_blockage(env; check_paths=true)
    zones = Dict(active_restriction_zones())
    isempty(zones) && error("no active exclusion zone is available")

    targets = Any[]
    for rec in blockage.blocked
        v = rec.vtx
        v in env.cache.closed_set && continue
        sn = env.sched.nodes[v]
        pred = sn.node
        if pred isa RobotGo || pred isa TransportUnitGo
            push!(targets, (rec=rec, schedule_node=sn, predicate=pred))
        end
    end
    length(targets) == 2 || error("expected exactly two unfinished exclusion-blocked navigation goals")

    moved = IdDict{Any,Bool}()
    for target in targets
        pred = target.predicate
        nav_goal = goal_config(target.schedule_node)
        nav_start = start_config(target.schedule_node)
        radius = Float64(agent_disc_radius(entity(target.schedule_node)))

        old_goal_tf = global_transform(nav_goal)
        old_start_tf = global_transform(nav_start)
        goal_pos = Vector{Float64}(old_goal_tf(zeros(3)))
        start_pos = Vector{Float64}(old_start_tf(zeros(3)))
        goal_xy = goal_pos[1:2]
        start_xy = start_pos[1:2]

        baseline_status = free_space_status(start_xy, start_xy, zones, radius)
        candidate = copy(goal_xy)

        for _ in 1:32
            changed = false
            for (_, zone) in zones
                center = Vector{Float64}(get_center(zone))[1:2]
                zone_radius = Float64(zone.radius)
                clearance = zone_radius + radius
                pad = max(sqrt(eps(Float64)) * max(1.0, clearance),
                          0.05 * max(radius, zone_radius))
                offset = candidate - center
                distance = sqrt(sum(abs2, offset))
                if distance <= clearance + pad
                    direction = start_xy - center
                    direction_norm = sqrt(sum(abs2, direction))
                    if direction_norm <= sqrt(eps(Float64))
                        direction = goal_xy - center
                        direction_norm = sqrt(sum(abs2, direction))
                    end
                    if direction_norm <= sqrt(eps(Float64))
                        angle = 2π * target.rec.vtx / max(1, length(env.sched.nodes))
                        direction = [cos(angle), sin(angle)]
                        direction_norm = 1.0
                    end
                    candidate = center + direction * ((clearance + pad) / direction_norm)
                    changed = true
                end
            end
            changed || break
        end

        candidate_status = free_space_status(start_xy, candidate, zones, radius)
        if goal_engulfed(candidate, radius, zones) || candidate_status != baseline_status
            best = nothing
            best_distance = Inf
            for (_, zone) in zones
                center = Vector{Float64}(get_center(zone))[1:2]
                zone_radius = Float64(zone.radius)
                clearance = zone_radius + radius
                pad = max(sqrt(eps(Float64)) * max(1.0, clearance),
                          0.05 * max(radius, zone_radius))
                start_direction = start_xy - center
                base_angle = atan(start_direction[2], start_direction[1])
                for j in 0:71
                    angle = base_angle + 2π * j / 72
                    trial = center + (clearance + pad) * [cos(angle), sin(angle)]
                    goal_engulfed(trial, radius, zones) && continue
                    trial_status = free_space_status(start_xy, trial, zones, radius)
                    trial_status == baseline_status || continue
                    displacement_cost = sum(abs2, trial - goal_xy)
                    if displacement_cost < best_distance
                        best = trial
                        best_distance = displacement_cost
                    end
                end
            end
            if best === nothing
                goal_engulfed(start_xy, radius, zones) &&
                    error("the mover start pose is also exclusion-blocked")
                best = copy(start_xy)
            end
            candidate = best
        end

        dx = candidate[1] - goal_xy[1]
        dy = candidate[2] - goal_xy[2]
        dt = env.dt > 0 ? env.dt : 1.0
        cmd = get_cmd(pred, env)
        translation_twist = typeof(cmd)(
            typeof(cmd.vel)(dx / dt, dy / dt, 0.0),
            typeof(cmd.ω)(0.0, 0.0, 0.0)
        )
        displacement = integrate_twist(translation_twist, dt)

        transforms = Any[nav_goal]
        if pred isa TransportUnitGo
            cargo_id = pred.entity.cargo.first
            for (v, dep_sn) in enumerate(env.sched.nodes)
                v in env.cache.closed_set && continue
                dep = dep_sn.node
                if dep isa DepositCargo && dep.entity === pred.entity
                    push!(transforms, goal_config(dep_sn))
                    push!(transforms, cargo_goal_config(dep_sn))
                elseif dep isa LiftIntoPlace &&
                       hasproperty(dep.entity, :id) &&
                       dep.entity.id == cargo_id
                    push!(transforms, goal_config(dep_sn))
                end
            end
        end

        local_seen = IdDict{Any,Bool}()
        for tf_node in transforms
            haskey(local_seen, tf_node) && continue
            local_seen[tf_node] = true
            haskey(moved, tf_node) && continue
            desired = displacement ∘ global_transform(tf_node)
            set_desired_global_transform!(tf_node, desired)
            moved[tf_node] = true
        end
    end

    return (; status = :success)
end