@noinline function deep(n::Int)
    n == 0 && return 0
    return 1 + deep(n - 1)
end

# Run f() on a freshly created task that has an explicit (large) C stack.
function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing)
    err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try
            result[] = f()
        catch e
            err[] = e
        finally
            done[] = true
        end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false
    schedule(t)
    while !done[]
        sleep(0.02)
    end
    err[] === nothing || throw(err[])
    return result[]
end

# Probe max depth with the big stack.
function probe(maxtry)
    d = 1000
    last = 0
    while d <= maxtry
        ok = try; deep(d); true catch; false end
        ok || break
        last = d
        d *= 2
    end
    return last
end

println("1GB stack max depth ~ ", run_with_stack(() -> probe(200_000_000), 1024*1024*1024))
println("STACK2_DONE")
