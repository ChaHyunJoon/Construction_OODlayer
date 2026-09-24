function restore_blocked_goal_reachability!(env)
    error("No scene-layout replanning and collision-validation capability is available in the world interface")
    return (; status = :success)
end