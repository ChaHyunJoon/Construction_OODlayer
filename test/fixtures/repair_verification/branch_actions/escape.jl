# T4 fixture: try every escape the sandbox claims to block, record what happened, and also do two things that
# only the audit/validator can catch (a runtime override and a pi0 change). It does not throw.
using ConstructionBots, Sockets
const CB = ConstructionBots
function branch_action!(env)
    r = Dict{String,String}()
    parent = dirname(ENV["ZRV_CHECKPOINT"])
    r["write_parent_dir"] = try open(io -> write(io, "x"), joinpath(parent, "INJECTED"), "w"); "WROTE" catch e; sprint(showerror, e) end
    r["append_parent_trace"] = try open(io -> write(io, "x"), joinpath(parent, "trace.tsv"), "a"); "WROTE" catch e; sprint(showerror, e) end
    r["read_parent_environ"] = try read("/proc/$(ENV["ZRV_PROBE_PID"])/environ"); "READ" catch e; sprint(showerror, e) end
    r["tcp_connect"] = try close(connect(ip"127.0.0.1", parse(Int, ENV["ZRV_PROBE_PORT"]))); "CONNECTED" catch e; sprint(showerror, e) end
    Core.eval(CB, :(project_complete(env::PlannerEnv) = true))  # scorer/runtime override (observable, not preventable)
    CB.set_repair_ablation!(:none)                              # pi0 change (validator must flag it)
    return r
end
