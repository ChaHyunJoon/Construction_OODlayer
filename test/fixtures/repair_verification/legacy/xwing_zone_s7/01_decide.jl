function relocate_unreachable_required_goals!(env;)
    zones = restriction_zones()
    isempty(zones) && error("no active restriction zone is available")

    blockage = zone_blockage(env; check_paths = true)
    blocked_vtxs = Int[]
    seen_vtxs = Set{Int}()

    for b in blockage.blocked
        v = b.vtx
        if !(v in env.cache.closed_set) && !(v in seen_vtxs)
            pred = env.sched.nodes[v].node
            if pred isa ConstructionBots.TransportUnitGo || pred isa ConstructionBots.RobotGo
                push!(blocked_vtxs, v)
                push!(seen_vtxs, v)
            end
        end
    end

    isempty(blocked_vtxs) && error("no unfinished blocked navigation goal was found")

    agent_radius = 0.0
    for agent in keys(env.agent_policies)
        r = agent_disc_radius(agent)
        r isa Real && (agent_radius = max(agent_radius, Float64(r)))
    end
    clearance = max(agent_radius, sqrt(eps(Float64)))

    plans = NamedTuple[]
    for (ordinal, v) in enumerate(blocked_vtxs)
        sched_node = env.sched.nodes[v]
        pred = sched_node.node
        destination = goal_config(sched_node)
        origin = start_config(sched_node)

        old_transform = global_transform(destination)
        old_position = collect(old_transform(zeros(3)))
        start_position = collect(global_transform(origin)(zeros(3)))

        chosen_position = nothing
        for ring in 1:16
            chosen_position === nothing || break
            for (_, zone) in zones
                center = collect(get_center(zone))
                radius = Float64(zone.radius)
                search_radius = radius + ring * clearance

                for angular_index in 0:31
                    angle = 2π * (angular_index + ordinal / (length(blocked_vtxs) + 1)) / 32
                    candidate = copy(old_position)
                    candidate[1] = center[1] + search_radius * cos(angle)
                    candidate[2] = center[2] + search_radius * sin(angle)

                    goal_engulfed(candidate, agent_radius, zones) && continue
                    path_status = free_space_status(start_position, candidate, zones, agent_radius)
                    (path_status === :engulfed || path_status === :disconnected) && continue

                    chosen_position = candidate
                    break
                end
                chosen_position === nothing || break
            end
        end

        chosen_position === nothing && error("no reachable legal relocation pose was found")
        delta = chosen_position .- old_position

        transport = pred isa ConstructionBots.TransportUnitGo ? pred.entity : nothing
        cargo_id = transport === nothing ? nothing : transport.cargo.first
        push!(plans, (; destination, delta, transport, cargo_id))
    end

    moved_transforms = Set{ConstructionBots.TransformNodeID}()
    moved_geometries = Set{ConstructionBots.GeomID}()

    for plan in plans
        delta_transform = CoordinateTransformations.Translation(plan.delta)

        transform_targets = ConstructionBots.TransformNode[]
        push!(transform_targets, plan.destination)

        for sched_node in env.sched.nodes
            pred = sched_node.node

            if plan.transport !== nothing
                if pred isa ConstructionBots.TransportUnitGo && pred.entity === plan.transport
                    push!(transform_targets, pred.goal_config)
                elseif pred isa ConstructionBots.DepositCargo && pred.entity === plan.transport
                    push!(transform_targets, pred.config)
                    push!(transform_targets, pred.cargo_goal_config)
                elseif pred isa ConstructionBots.FormTransportUnit && pred.entity === plan.transport
                    push!(transform_targets, pred.cargo_goal_config)
                elseif pred isa ConstructionBots.LiftIntoPlace
                    lifted = pred.entity
                    if hasproperty(lifted, :id) && getproperty(lifted, :id) == plan.cargo_id
                        push!(transform_targets, pred.goal_config)
                    end
                elseif pred isa ConstructionBots.EntityConfigPredicate
                    configured = pred.entity
                    if hasproperty(configured, :id) && getproperty(configured, :id) == plan.cargo_id
                        push!(transform_targets, pred.config)
                    end
                elseif pred isa ConstructionBots.OpenBuildStep || pred isa ConstructionBots.CloseBuildStep
                    if haskey(pred.components, plan.cargo_id)
                        for geom in (pred.staging_circle, pred.bounding_circle)
                            if !(geom.id in moved_geometries)
                                geom_transform = global_transform(geom)
                                set_desired_global_transform!(geom, delta_transform ∘ geom_transform)
                                push!(moved_geometries, geom.id)
                            end
                        end
                    end
                end
            end
        end

        for target in transform_targets
            if !(target.id in moved_transforms)
                target_transform = global_transform(target)
                set_desired_global_transform!(target, delta_transform ∘ target_transform)
                push!(moved_transforms, target.id)
            end
        end
    end

    return (; status = :success)
end