function relocate_unreachable_navigation_goals!(env;)
    zone_keys = [p.first for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone is available")

    initial = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    target_ids = unique([b.id for b in initial.blocked])
    isempty(target_ids) && error("no blocked unfinished navigation goal was found")

    zone_data = [zone_facts(env, key; check_blockage = true, check_paths = true) for key in zone_keys]
    accepted = Tuple{Any, Any}[]
    handled = Set{Any}()

    for target_id in target_ids
        target_id in handled && continue

        current = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
        records = [b for b in current.blocked if b.id == target_id]
        if isempty(records)
            push!(handled, target_id)
            continue
        end

        rec = first(records)
        sched_node = env.sched.nodes[rec.vtx]
        predicate = sched_node.node
        destination = goal_config(sched_node)
        destination isa TransformNode || error("blocked navigation goal has no editable scene-tree transform")

        old_transform = global_transform(destination)
        old_position = old_transform(zeros(3))
        radius = Float64(agent_disc_radius(entity(sched_node)))
        cmd = get_cmd(predicate, env)

        downstream = Int[]
        queue = [rec.vtx]
        seen = Set{Int}()
        while !isempty(queue)
            v = popfirst!(queue)
            v in seen && continue
            push!(seen, v)
            push!(downstream, v)
            append!(queue, env.sched.graph.fadjlist[v])
        end

        affected = Any[]
        add_affected! = t -> begin
            if t isa TransformNode &&
               !any(x -> x === t, affected) &&
               !any(x -> x[1] === t, accepted)
                push!(affected, t)
            end
            nothing
        end
        add_affected!(destination)

        for v in downstream
            node_value = env.sched.nodes[v].node
            for field in fieldnames(typeof(node_value))
                value = getfield(node_value, field)
                if value isa TransformNode
                    if v != rec.vtx || field in (:goal_config, :cargo_goal_config, :config)
                        add_affected!(value)
                    end
                elseif value isa GeomNode
                    add_affected!(value.parent)
                end
            end
        end

        snapshots = [(node, global_transform(node)) for node in affected]
        moved = false

        for z in zone_data
            center = z.center
            zone_radius = Float64(z.radius)
            radial_x = old_position[1] - center[1]
            radial_y = old_position[2] - center[2]
            radial_norm = hypot(radial_x, radial_y)
            base_angle = radial_norm > eps(Float64) ? atan(radial_y, radial_x) : 0.0

            for ring in 1:8
                clearance = zone_radius + radius + 0.25 * ring
                for spoke in 0:23
                    angle = spoke == 0 ? base_angle : base_angle + 2π * spoke / 24
                    candidate_x = center[1] + clearance * cos(angle)
                    candidate_y = center[2] + clearance * sin(angle)
                    velocity = typeof(cmd.vel)(
                        candidate_x - old_position[1],
                        candidate_y - old_position[2],
                        0.0,
                    )
                    translation = integrate_twist(typeof(cmd)(velocity, zero(cmd.ω)), 1.0)

                    for (node, transform) in snapshots
                        set_desired_global_transform!(node, translation ∘ transform)
                    end

                    trial = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
                    still_blocked = any(b -> b.id == target_id, trial.blocked)
                    tree_valid = validate_schedule_transform_tree(env.sched)

                    if !still_blocked && tree_valid
                        append!(accepted, snapshots)
                        push!(handled, target_id)
                        moved = true
                        break
                    end

                    for (node, transform) in reverse(snapshots)
                        set_desired_global_transform!(node, transform)
                    end
                end
                moved && break
            end
            moved && break
        end

        if !moved
            for (node, transform) in reverse(accepted)
                set_desired_global_transform!(node, transform)
            end
            error("no reachable collision-valid relocation was found for a blocked navigation goal")
        end
    end

    final_report = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    final_valid = validate_schedule_transform_tree(env.sched)
    if final_report.n_blocked != 0 || final_report.project_blocked || !final_valid
        for (node, transform) in reverse(accepted)
            set_desired_global_transform!(node, transform)
        end
        error("relocation did not restore a valid closable path to ProjectComplete")
    end

    return (; status = :success)
end