function relocate_zone_blocked_goals!(env;)
    zone_pairs = collect(active_restriction_zones())
    zones = [last(p) for p in zone_pairs]
    isempty(zones) && return (; status = :success)

    initial = zone_blockage(env)
    isempty(initial.blocked) && return (; status = :success)

    seen_configs = Set{Any}()
    target_ids = Set{Any}()
    originals = Any[]

    for blocked in initial.blocked
        push!(target_ids, blocked.id)
        sched_node = env.sched.nodes[blocked.vtx]
        goal_node = goal_config(sched_node)

        goal_node isa ConstructionBots.TransformNode || continue
        goal_node.id in seen_configs && continue
        push!(seen_configs, goal_node.id)

        start_node = start_config(sched_node)
        start_node isa ConstructionBots.TransformNode || error("blocked navigation node has no transform start configuration")

        old_tf = global_transform(goal_node)
        start_tf = global_transform(start_node)
        old_pos = Vector{Float64}(old_tf(zeros(3)))
        start_pos = Vector{Float64}(start_tf(zeros(3)))
        agent_radius = Float64(agent_disc_radius(entity(sched_node)))

        linked_lift_goals = Any[]
        for other in env.sched.nodes
            predicate = other.node
            if predicate isa ConstructionBots.LiftIntoPlace &&
               predicate.start_config.id == goal_node.id
                push!(linked_lift_goals, global_transform(predicate.goal_config))
            end
        end

        project_outside = function(seed, fallback_angle)
            q = Vector{Float64}(seed)
            for _ in 1:(length(zones) + 2)
                changed = false
                for zone in zones
                    center = Vector{Float64}(get_center(zone))[1:2]
                    # No callable radius accessor is exposed for Ball2.
                    clearance = Float64(zone.radius) + agent_radius
                    d = q - center
                    distance = sqrt(sum(abs2, d))
                    if distance <= clearance
                        if distance <= sqrt(eps(Float64))
                            d = [cos(fallback_angle), sin(fallback_angle)]
                            distance = 1.0
                        end
                        pad = sqrt(eps(Float64)) * max(1.0, clearance)
                        q = center + d .* ((clearance + pad) / distance)
                        changed = true
                    end
                end
                changed || break
            end
            q
        end

        best_point = nothing
        best_tf = nothing
        best_distance = Inf
        seeds = Vector{Vector{Float64}}()
        push!(seeds, old_pos[1:2])

        for zone in zones
            center = Vector{Float64}(get_center(zone))[1:2]
            clearance = Float64(zone.radius) + agent_radius
            for ring in 0:15
                radial_distance = clearance * (1.0 + ring / 8.0) +
                                  sqrt(eps(Float64)) * max(1.0, clearance)
                for j in 0:63
                    angle = 2pi * j / 64
                    push!(seeds, center + radial_distance .* [cos(angle), sin(angle)])
                end
            end
        end

        for (candidate_index, seed) in enumerate(seeds)
            angle = 2pi * (candidate_index - 1) / max(1, length(seeds))
            candidate = project_outside(seed, angle)

            goal_engulfed(candidate, agent_radius, zones) && continue
            route_status = free_space_status(start_pos, candidate, zones, agent_radius)
            route_status === :engulfed && continue
            route_status === :disconnected && continue

            delta = zeros(length(old_pos))
            delta[1] = candidate[1] - old_pos[1]
            delta[2] = candidate[2] - old_pos[2]
            candidate_tf = CoordinateTransformations.Translation(delta) ∘ old_tf

            capture_ok = true
            for lift_goal_tf in linked_lift_goals
                capture_result = is_within_capture_distance(candidate_tf, lift_goal_tf)
                if capture_result !== true
                    capture_ok = false
                    break
                end
            end
            capture_ok || continue

            displacement = sqrt(sum(abs2, candidate - old_pos[1:2]))
            if displacement < best_distance
                best_point = candidate
                best_tf = candidate_tf
                best_distance = displacement
            end
        end

        best_point === nothing && error("no reachable zone-clear goal pose preserving assembly capture was found")
        push!(originals, (goal_node, old_tf))
        applied_tf = set_desired_global_transform!(goal_node, best_tf)
        applied_tf === nothing && error("scene-tree transform update did not produce a transform")
    end

    tree_valid = validate_schedule_transform_tree(env.sched)
    if tree_valid !== true
        for (node, old_tf) in reverse(originals)
            restored_tf = set_desired_global_transform!(node, old_tf)
            restored_tf === nothing && error("failed to restore an invalid scene-tree edit")
        end
        error("relocated transforms violate the schedule transform tree")
    end

    remaining = zone_blockage(env)
    still_blocked = any(b -> b.id in target_ids, remaining.blocked)
    if still_blocked
        for (node, old_tf) in reverse(originals)
            restored_tf = set_desired_global_transform!(node, old_tf)
            restored_tf === nothing && error("failed to restore an ineffective scene-tree edit")
        end
        error("one or more required navigation goals remain blocked by an active zone")
    end

    return (; status = :success)
end