function restore_zone_blocked_arrival!(env;)
    zone_pairs = collect(active_restriction_zones())
    isempty(zone_pairs) && error("no active restriction zone")

    zone_keys = [p.first for p in zone_pairs]
    blockage = zone_blockage(env; zone_keys = zone_keys, check_paths = true)

    target = nothing
    for blocked in blockage.blocked
        if !(blocked.vtx in env.cache.closed_set) &&
           (blocked.status === :engulfed || blocked.status === :disconnected)
            target === nothing || error("zone event does not identify a unique frozen navigation node")
            target = blocked
        end
    end
    target === nothing && error("no unfinished zone-blocked navigation node found")

    sched_node = env.sched.nodes[target.vtx]
    predicate = sched_node.node
    start_node = start_config(sched_node)
    goal_node = goal_config(sched_node)
    old_goal_tf = global_transform(goal_node)
    start_tf = global_transform(start_node)
    origin = [0.0, 0.0, 0.0]
    start_pos = Vector{Float64}(start_tf(origin))
    old_goal_pos = Vector{Float64}(old_goal_tf(origin))

    mover = entity(predicate)
    mover_radius = try
        Float64(agent_disc_radius(mover))
    catch
        event_robot = ood_event_target()
        event_robot === nothing && error("cannot determine the navigating agent radius")
        Float64(agent_disc_radius(event_robot))
    end

    owner_facts = nothing
    for key in zone_keys
        facts = zone_facts(env, key; check_teams = false, check_blockage = true, check_paths = true)
        if target.id in facts.blocked
            owner_facts = facts
            break
        end
    end
    owner_facts === nothing && error("could not associate the blocked node with an active zone")

    center = Vector{Float64}(owner_facts.center)[1:2]
    zone_radius = Float64(owner_facts.radius)
    active_zones = [p.second for p in zone_pairs]
    search_radius = zone_radius + mover_radius +
                    max(2.0 * mover_radius, 0.05 * zone_radius, sqrt(eps(Float64)))

    cmd = get_cmd(predicate, env)
    accepted = false
    n_directions = 64

    for j in 0:(n_directions - 1)
        θ = 2.0 * pi * j / n_directions
        candidate = [
            center[1] + search_radius * cos(θ),
            center[2] + search_radius * sin(θ),
        ]

        route_status = free_space_status(
            start_pos[1:2],
            candidate,
            active_zones,
            mover_radius,
        )
        (route_status === :engulfed || route_status === :disconnected) && continue

        displacement = typeof(cmd.vel)(
            candidate[1] - old_goal_pos[1],
            candidate[2] - old_goal_pos[2],
            0.0,
        )
        shift_twist = typeof(cmd)(displacement, zero(cmd.ω))
        shifted_goal_tf = integrate_twist(shift_twist, 1.0) ∘ old_goal_tf

        trial_accepted = false
        try
            set_desired_global_transform!(goal_node, shifted_goal_tf)
            transforms_valid = validate_schedule_transform_tree(env.sched)
            after = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
            open_blockage_remains = any(
                blocked -> !(blocked.vtx in env.cache.closed_set),
                after.blocked,
            )
            trial_accepted = transforms_valid &&
                             !open_blockage_remains &&
                             !after.project_blocked
        catch
            trial_accepted = false
        finally
            if !trial_accepted
                set_desired_global_transform!(goal_node, old_goal_tf)
            end
        end

        if trial_accepted
            accepted = true
            break
        end
    end

    accepted || error("no reachable zone-clear goal preserves closure of the remaining schedule")
    return (; status = :success)
end