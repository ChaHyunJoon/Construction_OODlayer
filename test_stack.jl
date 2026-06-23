# Measure how deep we can recurse on (a) the main task and (b) a spawned task.
@noinline function deep(n::Int)
    n == 0 && return 0
    return 1 + deep(n - 1)
end

function max_depth()
    lo, hi = 0, 0
    # exponential probe
    d = 1000
    while true
        ok = try
            deep(d); true
        catch e
            false
        end
        if ok
            lo = d; d *= 2
            d > 20_000_000 && return lo
        else
            hi = d; break
        end
    end
    # binary search
    while hi - lo > 1000
        mid = (lo + hi) ÷ 2
        ok = try; deep(mid); true catch; false end
        ok ? (lo = mid) : (hi = mid)
    end
    return lo
end

println("MAIN task max depth ~ ", max_depth())

# Spawned task on a thread
t = Threads.@spawn max_depth()
println("SPAWNED task max depth ~ ", fetch(t))

# Low-level: create a task with an explicit large stack via jl_new_task
function bigstack_run(f, stacksize::Int)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), f, nothing, stacksize)
    t.sticky = false
    schedule(t)
    return fetch(t)
end
println("BIGSTACK(512MB) max depth ~ ", bigstack_run(max_depth, 512*1024*1024))
println("STACK_TEST_DONE")
