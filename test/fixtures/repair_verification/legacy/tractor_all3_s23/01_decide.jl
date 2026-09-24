function restore_navigation_goal_reachability!(env;)
    zones = collect(active_restriction_zones())
    isempty(zones) && error("no active restriction zone")

    report = zone_blockage(env; check_paths = true)
    blocked_vtxs = Int[]
    for b in report.blocked
        v = b.vtx
        if !(v in env.cache.closed_set)
            predicate = env.sched.nodes[v].node
            if predicate isa RobotGo || predicate isa TransportUnitGo
                v in blocked_vtxs || push!(blocked_vtxs, v)
            end
        end
    end
    length(blocked_vtxs) < 2 && error("fewer than two unfinished navigation goals are blocked")
    blocked_vtxs = blocked_vtxs[1:2]

    original_globals = Vector{Tuple{Any,Any}}()
    recorded = IdDict{Any,Bool}()

    record_transform! = function (cfg)
        cfg === nothing && return
        if !haskey(recorded, cfg)
            recorded[cfg] = true
            push!(original_globals, (cfg, global_transform(cfg)))
        end
    end

    descendants = function (root_v)
        found = Int[]
        queue = collect(Graphs.outneighbors(env.sched.graph, root_v))
        seen = Set{Int}()
        while !isempty(queue)
            v = popfirst!(queue)
            v in seen && continue
            push!(seen, v)
            push!(found, v)
            append!(queue, Graphs.outneighbors(env.sched.graph, v))
        end
        found
    end

    try
        for nav_v in blocked_vtxs
            sched_node = env.sched.nodes[nav_v]
            nav = sched_node.node
            goal_cfg = goal_config(sched_node)
            start_cfg = start_config(sched_node)
            goal_tf = global_transform(goal_cfg)
            start_tf = global_transform(start_cfg)
            goal_pos = Vector{Float64}(goal_tf([0.0, 0.0, 0.0]))
            start_pos = Vector{Float64}(start_tf([0.0, 0.0, 0.0]))

            radius = try
                Float64(agent_disc_radius(entity(sched_node)))
            catch
                maximum(Float64(agent_disc_radius(a)) for a in keys(env.agent_policies))
            end

            baseline = free_space_status(start_pos, goal_pos, zones, radius)
            candidate = nothing

            for (_, zone) in zones
                center = Vector{Float64}(get_center(zone))
                # No radius accessor is exposed by the interface for Ball2.
                zone_radius = Float64(zone.radius)
                shell = zone_radius + 2.0 * radius

                for scale in (1.0, 1.5, 2.0, 3.0)
                    for j in 0:31
                        θ = 2.0 * π * j / 32.0
                        cand = [center[1] + scale * shell * cos(θ),
                                center[2] + scale * shell * sin(θ)]
                        goal_engulfed(cand, radius, zones) && continue
                        candidate_status = free_space_status(start_pos, cand, zones, radius)
                        if candidate_status != baseline
                            candidate = cand
                            break
                        end
                    end
                    candidate === nothing || break
                end
                candidate === nothing || break
            end
            candidate === nothing && error("no reachable zone-compliant alternative goal geometry found")

            delta = [candidate[1] - goal_pos[1],
                     candidate[2] - goal_pos[2],
                     0.0]

            related = Any[goal_cfg]
            downstream = descendants(nav_v)

            if nav isa TransportUnitGo
                transport = entity(sched_node)
                cargo_id = transport.cargo.first

                for v in downstream
                    v in env.cache.closed_set && continue
                    n = env.sched.nodes[v]
                    p = n.node
                    if p isa DepositCargo && entity(n) === transport
                        push!(related, goal_config(n))
                        push!(related, cargo_goal_config(n))
                    elseif p isa LiftIntoPlace
                        lifted = entity(n)
                        if hasproperty(lifted, :id) && lifted.id == cargo_id
                            push!(related, start_config(n))
                            push!(related, goal_config(n))
                        end
                    end
                end
            end

            local_seen = IdDict{Any,Bool}()
            snapshots = Vector{Tuple{Any,Any}}()
            for cfg in related
                cfg === nothing && continue
                haskey(local_seen, cfg) && continue
                local_seen[cfg] = true
                old_tf = global_transform(cfg)
                push!(snapshots, (cfg, old_tf))
                record_transform!(cfg)
            end

            shift = CoordinateTransformations.Translation(delta)
            for (cfg, old_tf) in snapshots
                set_desired_global_transform!(cfg, shift ∘ old_tf)
            end
        end

        validate_schedule_transform_tree(env.sched) ||
            error("revised scene geometry violates the schedule transform tree")

        revised = zone_blockage(env; check_paths = true)
        still_blocked = Set(b.vtx for b in revised.blocked)
        any(v -> v in still_blocked, blocked_vtxs) &&
            error("one or more revised navigation goals remain blocked")
    catch err
        for (cfg, old_tf) in Iterators.reverse(original_globals)
            set_desired_global_transform!(cfg, old_tf)
        end
        rethrow(err)
    end

    return (; status = :success)
end