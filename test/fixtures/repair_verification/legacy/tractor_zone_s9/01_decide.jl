function restore_blocked_goal_reachability!(env)
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
        start = start_config(sched_node)
        push!(edits, (goal, global_transform(start), global_transform(goal)))
    end
    isempty(edits) && error("blocked goals did not expose relocatable transform nodes")

    applied = 0
    try
        for (goal, replacement, _) in edits
            moved = set_desired_global_transform!(goal, replacement)
            moved === nothing && error("a blocked goal transform was not relocated")
            applied += 1
        end

        sync_result = resync_scene_to_schedule!(env)
        valid = validate_schedule_transform_tree(env.sched)
        valid || error("relocation violated schedule/scene transform consistency")

        post = zone_blockage(env; zone_keys = zone_keys)
        still_blocked = any(b -> b.id in blocked_ids, post.blocked)
        still_blocked && error("one or more affected navigation goals remain blocked")
        post.project_blocked && error("the exclusion zone still blocks ProjectComplete progression")
    catch
        for i in applied:-1:1
            goal, _, original = edits[i]
            restored = set_desired_global_transform!(goal, original)
            restored === nothing && error("failed to restore a goal transform after rejected relocation")
        end
        rollback_sync = resync_scene_to_schedule!(env)
        rethrow()
    end

    return (; status = :success)
end