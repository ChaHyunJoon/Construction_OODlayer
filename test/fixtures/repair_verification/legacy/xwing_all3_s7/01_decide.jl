function relocate_blocked_navigation_goals!(env;)
    zones_with_keys = collect(active_restriction_zones())
    isempty(zones_with_keys) && error("no active exclusion zone")
    zones = [last(z) for z in zones_with_keys]
    blockage = zone_blockage(env; check_paths = true)
    blocked_nav = Any[]
    for b in blockage.blocked
        sn = env.sched.nodes[b.vtx]
        if !(b.vtx in env.cache.closed_set) &&
           (sn.node isa RobotGo || sn.node isa TransportUnitGo) &&
           (b.status == :disconnected || b.status == :engulfed)
            push!(blocked_nav, b)
        end
    end
    isempty(blocked_nav) && error("no blocked unfinished navigation goals found")

    relocated = Set{Any}()
    for blocked in blocked_nav
        sn = env.sched.nodes[blocked.vtx]
        nav = sn.node
        anchor = goal_config(sn)
        anchor.id in relocated && continue

        ent = entity(sn)
        cargo_id = hasproperty(ent, :cargo) ? first(getproperty(ent, :cargo)) : nothing
        related = Dict{Any, Any}(anchor.id => anchor)

        for (v, candidate) in enumerate(env.sched.nodes)
            v in env.cache.closed_set && continue
            pred = candidate.node
            candidate_entity = try
                entity(candidate)
            catch
                nothing
            end
            same_transport = candidate_entity === ent
            same_cargo = cargo_id !== nothing &&
                         candidate_entity !== nothing &&
                         hasproperty(candidate_entity, :id) &&
                         getproperty(candidate_entity, :id) == cargo_id
            relevant = same_transport || same_cargo
            relevant || continue

            fields = if pred isa DepositCargo
                (:config, :cargo_start_config, :cargo_goal_config)
            elseif pred isa LiftIntoPlace
                (:start_config, :goal_config)
            elseif pred isa TransportUnitGo || pred isa RobotGo
                (:goal_config,)
            elseif pred isa EntityConfigPredicate
                (:config,)
            else
                ()
            end
            for field in fields
                if hasproperty(pred, field)
                    config = getproperty(pred, field)
                    config isa TransformNode && (related[config.id] = config)
                end
            end
        end

        zone_key = first(first(zones_with_keys))
        facts = zone_facts(env, zone_key;
                           margin = 0.0,
                           check_teams = false,
                           check_blockage = false,
                           check_paths = false)
        center = facts.center
        radius = Float64(facts.radius)
        agent_radius = Float64(agent_disc_radius(ent))
        margin = max(sqrt(eps(Float64)), 0.05 * max(radius, agent_radius))

        goal_tf = global_transform(anchor)
        goal_pos = goal_tf([0.0, 0.0, 0.0])
        start_tf = global_transform(start_config(sn))
        start_pos = start_tf([0.0, 0.0, 0.0])
        base_angle = atan(goal_pos[2] - center[2], goal_pos[1] - center[1])
        cmd = get_cmd(nav, env)
        originals = Dict(id => global_transform(config) for (id, config) in related)

        placed = false
        for layer in 0:7
            placed && break
            clearance = radius + agent_radius + margin + layer * max(radius, agent_radius, margin)
            for spoke in 0:15
                angle = base_angle + 2π * spoke / 16
                candidate = [center[1] + clearance * cos(angle),
                             center[2] + clearance * sin(angle)]
                engulfed = goal_engulfed(candidate, agent_radius, zones;
                                         ttol = env.dt, margin = margin)
                route_status = free_space_status(start_pos, candidate, zones, agent_radius;
                                                 cell = max(margin, agent_radius / 2),
                                                 margin = margin)
                if engulfed || route_status == :disconnected || route_status == :engulfed
                    continue
                end

                displacement = candidate .- goal_pos[1:2]
                velocity = typeof(cmd.vel)(displacement[1], displacement[2], 0.0)
                shift = integrate_twist(typeof(cmd)(velocity, zero(cmd.ω)), 1.0)

                for (id, config) in related
                    set_desired_global_transform!(config, shift ∘ originals[id])
                end

                structurally_valid = validate_schedule_transform_tree(env.sched;
                                                                      post_staging = true)
                after = zone_blockage(env; check_paths = true)
                still_blocked = any(x -> x.id == blocked.id &&
                                         (x.status == :disconnected ||
                                          x.status == :engulfed),
                                    after.blocked)
                if structurally_valid && !still_blocked
                    union!(relocated, keys(related))
                    placed = true
                    break
                end

                for (id, config) in related
                    set_desired_global_transform!(config, originals[id])
                end
            end
        end
        placed || error("no feasible assembly-preserving relocation found")
    end

    final_blockage = zone_blockage(env; check_paths = true)
    for blocked in blocked_nav
        any(x -> x.id == blocked.id &&
                 (x.status == :disconnected || x.status == :engulfed),
            final_blockage.blocked) &&
            error("a required navigation goal remains blocked")
    end
    return (; status = :success)
end