function relocate_unreachable_work_goal!(env;)
    zones_with_keys = collect(active_restriction_zones())
    isempty(zones_with_keys) && error("no active restriction zone")

    zone_keys = [first(p) for p in zones_with_keys]
    zones = [last(p) for p in zones_with_keys]
    blockage = zone_blockage(env; zone_keys = zone_keys)

    blocked_entry = nothing
    blocked_schedule_node = nothing
    for b in blockage.blocked
        v = b.vtx
        if !(v in env.cache.closed_set)
            sn = env.sched.nodes[v]
            if sn.node isa ConstructionBots.TransportUnitGo
                blocked_entry = b
                blocked_schedule_node = sn
                break
            end
        end
    end
    blocked_schedule_node === nothing && error("no unfinished blocked transport navigation goal found")

    nav = blocked_schedule_node.node
    transport = nav.entity
    cargo_id = transport.cargo.first
    old_goal_tf = global_transform(nav.goal_config)

    point_of = t -> begin
        try
            Vector{Float64}(t([0.0, 0.0, 0.0]))
        catch
            Vector{Float64}(t([0.0, 0.0]))
        end
    end

    old_goal = point_of(old_goal_tf)
    start_goal = point_of(global_transform(nav.start_config))

    agent_radius = try
        Float64(agent_disc_radius(transport))
    catch
        isempty(transport.robots) && error("transport unit has no robots from which to obtain a clearance radius")
        maximum(Float64(agent_disc_radius(r)) for r in keys(transport.robots))
    end
    agent_radius > 0 || error("invalid transport-unit clearance radius")

    responsible = nothing
    for key in zone_keys
        facts = zone_facts(env, key)
        if blocked_entry.id in facts.blocked
            responsible = facts
            break
        end
    end
    if responsible === nothing
        for key in zone_keys
            facts = zone_facts(env, key)
            if facts.n_nav_blocked > 0
                responsible = facts
                break
            end
        end
    end
    responsible === nothing && error("could not associate the blocked goal with an active restriction zone")

    center = Vector{Float64}(responsible.center)
    zone_radius = Float64(responsible.radius)
    candidate = nothing

    for shell in 1:8
        search_radius = zone_radius + (2.0 + 2.0 * shell) * agent_radius
        for j in 0:95
            θ = 2.0 * pi * j / 96.0
            p = copy(old_goal)
            p[1] = center[1] + search_radius * cos(θ)
            p[2] = center[2] + search_radius * sin(θ)

            goal_engulfed(p, agent_radius, zones) && continue
            path_status = free_space_status(start_goal, p, zones, agent_radius)
            (path_status == :disconnected || path_status == :engulfed) && continue

            candidate = p
            break
        end
        candidate === nothing || break
    end
    candidate === nothing && error("no legal reachable relocation was found")

    displacement = candidate - old_goal
    relocation = CoordinateTransformations.Translation(displacement)

    configs = Any[]
    add_config = cfg -> begin
        any(existing -> existing === cfg, configs) || push!(configs, cfg)
        nothing
    end

    add_config(nav.goal_config)
    for sn in env.sched.nodes
        p = sn.node
        if p isa ConstructionBots.TransportUnitGo && p.entity === transport
            add_config(p.goal_config)
        elseif p isa ConstructionBots.DepositCargo && p.entity === transport
            add_config(p.config)
            add_config(p.cargo_goal_config)
        elseif p isa ConstructionBots.LiftIntoPlace
            lifted_id = hasproperty(p.entity, :id) ? getproperty(p.entity, :id) : nothing
            if lifted_id == cargo_id
                add_config(p.start_config)
                add_config(p.goal_config)
            end
        elseif p isa ConstructionBots.AssemblyStart ||
               p isa ConstructionBots.AssemblyComplete ||
               p isa ConstructionBots.ObjectStart
            placed_id = hasproperty(p.entity, :id) ? getproperty(p.entity, :id) : nothing
            placed_id == cargo_id && add_config(p.config)
        end
    end

    old_transforms = [global_transform(cfg) for cfg in configs]
    new_transforms = [relocation ∘ t for t in old_transforms]
    valid_tree_before = validate_schedule_transform_tree(env.sched)

    for i in eachindex(configs)
        set_desired_global_transform!(configs[i], new_transforms[i])
    end

    valid_tree_after = validate_schedule_transform_tree(env.sched)
    after = zone_blockage(env; zone_keys = zone_keys)
    still_blocked = any(b -> b.id == blocked_entry.id, after.blocked)

    if (valid_tree_before && !valid_tree_after) || still_blocked
        for i in eachindex(configs)
            set_desired_global_transform!(configs[i], old_transforms[i])
        end
        error(valid_tree_before && !valid_tree_after ?
              "relocation violated schedule-transform consistency" :
              "relocated navigation goal remains blocked")
    end

    return (; status = :success)
end