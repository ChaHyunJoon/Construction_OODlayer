function restore_blocked_goal_reachability!(env;)
    zone_keys = [p.first for p in active_restriction_zones()]
    isempty(zone_keys) && error("no active exclusion zone was found")

    report = zone_blockage(env; zone_keys = zone_keys)
    blocked_ids = Set(b.id for b in report.blocked)
    isempty(blocked_ids) && error("no blocked navigation goals were found")

    edits = Any[]
    for blocked in report.blocked
        sched_node = env.sched.nodes[blocked.vtx]
        goal = goal_config(sched_node)
        any(edit -> edit[1] === goal, edits) && continue
        push!(edits, (goal, global_transform(goal)))
    end
    isempty(edits) && error("blocked goals did not expose relocatable transform nodes")

    restore_originals! = function ()
        for (goal, original) in edits
            restored = set_desired_global_transform!(goal, original)
            restored === nothing && error("failed to restore a goal transform after rejected relocation")
        end
        resync_scene_to_schedule!(env)
        nothing
    end

    trial! = function (assignments)
        try
            for (goal, replacement) in assignments
                moved = set_desired_global_transform!(goal, replacement)
                moved === nothing && error("a blocked goal transform was not relocated")
            end

            resync_scene_to_schedule!(env)
            validate_schedule_transform_tree(env.sched) || error("relocation violated schedule/scene transform consistency")

            post = zone_blockage(env; zone_keys = zone_keys)
            still_blocked = any(b -> b.id in blocked_ids, post.blocked)
            if !still_blocked && !post.project_blocked
                return true
            end
        catch
        end

        restore_originals!()
        return false
    end

    solved = false

    entity_assignments = Any[]
    for blocked in report.blocked
        sched_node = env.sched.nodes[blocked.vtx]
        goal = goal_config(sched_node)
        any(a -> a[1] === goal, entity_assignments) && continue
        push!(entity_assignments, (goal, global_transform(entity(sched_node))))
    end
    solved = !isempty(entity_assignments) && trial!(entity_assignments)

    candidates = Any[]
    if !solved
        for blocked in report.blocked
            push!(candidates, global_transform(start_config(env.sched.nodes[blocked.vtx])))
        end
        for scene_node in env.scene_tree.nodes
            push!(candidates, global_transform(scene_node))
        end

        for candidate in candidates
            assignments = [(goal, candidate) for (goal, _) in edits]
            if trial!(assignments)
                solved = true
                break
            end
        end
    end

    solved || error("one or more affected navigation goals remain blocked")

    return (; status = :success)
end