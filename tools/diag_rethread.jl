# Diagnostic: after fault->reassign->commit on the RESUME path (which now runs
# rethread_robot_ids!), find any robot that is DOUBLE-BOOKED — captured inside a
# transport unit while a free RobotGo of the same robot overlaps in time — and dump
# its timeline + backtraces. Tells us whether the remaining :asserted is a genuine
# MILP double-assignment (rethreading can't fix -> need Option 2) or still an
# id-threading artifact my pass missed.
#
#   julia +lts --project=. tools/diag_rethread.jl
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP
const CB = ConstructionBots

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    wrapper = function (); try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end; end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

function build_base_env()
    pp = CB.get_project_params(4)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
            milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error, rvo_flag=false,
            tangent_bug_flag=false, dispersion_flag=false, open_animation_at_end=false,
            save_animation=false, save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false, save_milp_solution=false,
            return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    return env
end

pred(sched, v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
rid(node) = (node isa CB.RobotGo ? CB.get_id(CB.entity(node).id) : -1)

function backtrace_to_start(sched, v; maxdepth=60)
    chain = Tuple{Int,String,Int}[]; cur = v
    for _ in 1:maxdepth
        n = pred(sched, cur)
        idv = try (n isa CB.RobotGo || n isa CB.RobotStart) ? CB.get_id(CB.entity(n).id) : -1 catch; -1 end
        push!(chain, (cur, string(nameof(typeof(n))), idv))
        n isa CB.RobotStart && break
        ins = collect(Graphs.inneighbors(sched, cur)); isempty(ins) && break; cur = first(ins)
    end
    return chain
end

println(">>> building env...")
env = build_base_env()
sched = env.sched
# advance to a deeper mid-build like the test (target_closed=24)
for _ in 1:100000
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= 24 || CB.project_complete(env)) && break
end
println(">>> advanced: closed=$(length(env.cache.closed_set)) nodes=$(Graphs.nv(sched))")

# pick faultable agent (on a pending transport team)
agent = nothing
seen = CB.AbstractID[]
for v in Graphs.vertices(sched)
    n = pred(sched, v); n isa CB.RobotGo || continue
    r = try CB.entity(n).id catch; nothing end
    (r isa CB.RobotID && CB.valid_id(r) && !(r in seen)) || continue; push!(seen, r)
end
for r in seen
    !isempty(CB.transport_teams_with_agent(env, r; pending_only=true)) && (global agent = r; break)
end
println(">>> faulting agent = $agent")

CB.RETHREAD_DEBUG[] = true
res = CB.fault_robot_and_reassign!(env, agent; resume=true, verbose=true)
CB.RETHREAD_DEBUG[] = false
println(">>> reassign status = $(res.status)")
println(">>> validate(sched) = ", CB.validate(sched))

# Build captured-intervals (robot inside a transport unit) and free RobotGo intervals.
# captured interval for a team robot r of unit U ~= [t0(FormTransportUnit), tF(DepositCargo)]
overlaps(a,b) = a[1] < b[2] - 1e-6 && b[1] < a[2] - 1e-6
captured = Dict{Int,Vector{Tuple{Float64,Float64,String}}}()   # rid -> intervals
freego   = Dict{Int,Vector{Tuple{Float64,Float64,Int}}}()      # rid -> (t0,tF,vtx)

for v in Graphs.vertices(sched)
    n = pred(sched, v)
    if n isa CB.FormTransportUnit
        fv = v
        dnode = try CB.get_node(sched, CB.DepositCargo(CB.entity(n))) catch; nothing end
        dv = dnode === nothing ? nothing : CB.get_vtx(sched, CB.node_id(CB.DepositCargo(CB.entity(n))))
        t0 = CB.get_t0(sched, fv)
        tF = dv === nothing ? CB.get_tF(sched, fv) : CB.get_tF(sched, dv)
        for r in collect(keys(CB.robot_team(CB.entity(n))))
            push!(get!(captured, CB.get_id(r), []), (t0, tF, "$(CB.node_id(n))"))
        end
    elseif n isa CB.RobotGo
        r = CB.get_id(CB.entity(n).id)
        r > 0 || continue
        push!(get!(freego, r, []), (CB.get_t0(sched, v), CB.get_tF(sched, v), v))
    end
end

# (1) Are the SKIP-prone deposits' teams genuinely invalid? Dump every DepositCargo
# team and flag invalid slot ids (these are the future units the re-solve left
# unassigned, which is why get_matching_child_id returns invalid -> rethread SKIPs).
println("\n>>> DepositCargo teams (invalid slots = unassigned future units):")
for v in Graphs.vertices(sched)
    n = pred(sched, v)
    n isa CB.DepositCargo || continue
    team = CB.robot_team(CB.entity(n))
    ids = [CB.get_id(r) for r in keys(team)]
    ninvalid = count(<(0), ids)
    ninvalid > 0 && println("   DepositCargo vtx=$v team=$ids  ($ninvalid invalid)")
end

# (2) GROUND TRUTH: step the resumed sim and replicate preprocess_env!'s assert
# (active free RobotGo whose robot is NOT its own scene-tree parent == captured).
# Dump the first offender, who captures it, and whether rethread SKIPped that node.
println("\n>>> stepping to the real runtime double-book (preprocess_env! condition)...")
function team_has(n, r)
    (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo || n isa CB.DepositCargo) || return false
    any(==(r), (CB.get_id(x) for x in keys(CB.robot_team(CB.entity(n)))))
end
hit = false
for it in 1:200000
    for v in collect(env.cache.active_set)
        n = CB.get_node(sched, v).node
        n isa CB.RobotGo || continue
        ok = try CB.has_parent(CB.entity(n), CB.entity(n)) catch; true end
        if !ok
            r = CB.get_id(CB.entity(n).id)
            par = try CB.get_parent(CB.entity(n)) catch; nothing end
            parid = par === nothing ? "nothing" : try string(CB.node_id(par)) catch; "?" end
            println("\n!!! RUNTIME DOUBLE-BOOK iter=$it: active free RobotGo vtx=$v robot=$r")
            println("    scene-tree parent (captor) = $parid")
            for v2 in collect(env.cache.active_set)
                team_has(CB.get_node(sched, v2).node, r) &&
                    println("    held by ACTIVE $(nameof(typeof(CB.get_node(sched,v2).node))) vtx=$v2 id=$(CB.node_id(CB.get_node(sched,v2).node))")
            end
            println("    offender backtrace: ", backtrace_to_start(sched, v))
            global hit = true; break
        end
    end
    hit && break
    CB.step_environment!(env)
    try
        CB.update_planning_cache!(env, 0.0)
    catch e
        println(">>> update_planning_cache! threw at iter=$it (", typeof(e), ") — assertion site"); global hit=true; break
    end
    CB.project_complete(env) && (println(">>> resumed to completion, NO runtime double-book"); break)
end
hit || println(">>> stepping loop exhausted without completion or double-book")
println(">>> done")
