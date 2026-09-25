# T4 fixture: spawn a process tree (one child escapes the group with setsid) and spin forever. The supervisor's
# wall timeout must kill the whole tree and report UNKNOWN wall_timeout. The marker proves the action ran.
function branch_action!(env)
    write(joinpath(ENV["ZRV_REPLAY_DIR"], "hang_started"), string(getpid()))
    run(`sh -c "sleep 100000 & setsid sleep 100001 & sleep 100002"`; wait = false)
    while true end
end
