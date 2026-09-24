function restore_required_goal_reachability!(env;)
    zone_keys = [first(p) for p in active_restriction_zones()]
    isempty(zone_keys) && return (; status = :failure)

    before_a = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
    before_b = zone_blockage(env; zone_keys = zone_keys, check_paths = true)

    direct_a = Set((r.id, r.vtx, r.status) for r in before_a.blocked if r.status == :engulfed || r.status == :disconnected)
    direct_b = Set((r.id, r.vtx, r.status) for r in before_b.blocked if r.status == :engulfed || r.status == :disconnected)
    (isempty(direct_a) || direct_a != direct_b) && return (; status = :failure)

    changed = Any[]
    seen_vtx = Set{Int64}()
    try
        for r in before_b.blocked
            (r.status == :engulfed || r.status == :disconnected) || continue
            v = r.vtx
            (v in seen_vtx || v < 1 || v > length(env.sched.nodes)) && continue
            push!(seen_vtx, v)

            node = env.sched.nodes[v]
            target = goal_config(node)
            source = start_config(node)
            old_transform = global_transform(target)
            new_transform = global_transform(source)
            old_transform == new_transform && continue

            push!(changed, (target, old_transform))
            set_desired_global_transform!(target, new_transform)
        end

        isempty(changed) && return (; status = :failure)

        valid_tree = validate_schedule_transform_tree(env.sched)
        after = zone_blockage(env; zone_keys = zone_keys, check_paths = true)
        remaining = Set((r.id, r.vtx, r.status) for r in after.blocked)

        acceptable = valid_tree &&
                     isempty(intersect(Set((x[1], x[2], x[3]) for x in direct_b), remaining)) &&
                     after.n_nav_blocked == 0 &&
                     after.n_disconnected == 0 &&
                     after.n_engulfed == 0 &&
                     after.n_agent_trapped == 0 &&
                     after.n_downstream == 0 &&
                     after.n_completion_blocked == 0 &&
                     !after.project_blocked

        if !acceptable
            for (target, old_transform) in Iterators.reverse(changed)
                set_desired_global_transform!(target, old_transform)
            end
            return (; status = :failure)
        end
    catch
        for (target, old_transform) in Iterators.reverse(changed)
            try
                set_desired_global_transform!(target, old_transform)
            catch
            end
        end
        return (; status = :failure)
    end

    return (; status = :success)
end