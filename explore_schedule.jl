# =============================================================================
# explore_schedule.jl  --  ONE-OFF: dump the real schedule structure so the
# reassignment surgery is written against reality, not a guess. No LLM, no sim.
# Run:  julia --project=. explore_schedule.jl
# =============================================================================
using ConstructionBots
import Graphs
const CB = ConstructionBots

function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing)
    done = Threads.Atomic{Bool}(false)
    wrapper = function ()
        try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end
    end
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

pp = get_project_params(4)
println(">>> building env...")
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Base.CoreLogging.Error, rvo_flag=false, tangent_bug_flag=false,
        dispersion_flag=false, open_animation_at_end=false, save_animation=false,
        save_animation_along_the_way=false, write_results=false, overwrite_results=false,
        look_for_previous_milp_solution=false, save_milp_solution=false,
        return_env_before_sim=true)
end
sched = env.sched
println(">>> nodes = ", Graphs.nv(sched))

nodetype(n) = string(typeof(CB.get_node(sched, n).node).name.name)
function describe(v)
    node = CB.get_node(sched, v).node
    t = string(typeof(node).name.name)
    rid = ""
    try
        if CB.has_robot_id(node)
            rid = " robot=" * string(CB.get_robot_id(node))
        end
    catch; end
    eid = ""
    try; eid = " entity.id=" * string(CB.entity(node).id); catch; end
    return "v$v[$t]$rid$eid in=$(Graphs.indegree(sched,v)) out=$(Graphs.outdegree(sched,v))"
end

# --- all robots (RobotStart) and the free go-node they spawn ------------------
println("\n========== ROBOTS (RobotStart -> first RobotGo) ==========")
robot_starts = [v for v in Graphs.vertices(sched) if CB.matches_template(CB.RobotStart, CB.get_node(sched, v))]
println("num RobotStart = ", length(robot_starts))
for v in robot_starts[1:min(end,3)]
    println(describe(v))
    for v2 in Graphs.outneighbors(sched, v)
        println("   -> ", describe(v2))
    end
end

# --- trace ONE robot's full assignment chain ---------------------------------
println("\n========== TRACE robot #1 chain (follow out-edges) ==========")
function trace(v, depth, seen)
    depth > 14 && return
    (v in seen) && return
    push!(seen, v)
    println("  "^depth, describe(v))
    for v2 in Graphs.outneighbors(sched, v)
        trace(v2, depth+1, seen)
    end
end
trace(robot_starts[1], 0, Set{Int}())

# --- one FormTransportUnit: its team slots (inneighbors) ----------------------
println("\n========== FormTransportUnit nodes: team-slot structure ==========")
ftus = [v for v in Graphs.vertices(sched) if CB.matches_template(CB.FormTransportUnit, CB.get_node(sched, v))]
println("num FormTransportUnit = ", length(ftus))
for v in ftus[1:min(end,3)]
    node = CB.get_node(sched, v).node
    team = CB.robot_team(CB.entity(node))
    println(describe(v), "  team_size=", length(team))
    for v2 in Graphs.inneighbors(sched, v)
        println("    in:  ", describe(v2))
    end
    for v2 in Graphs.outneighbors(sched, v)
        println("    out: ", describe(v2))
    end
end

# --- terminal RobotGo nodes (free moments = reassignment candidates) ----------
println("\n========== terminal RobotGo nodes (outdeg 0) ==========")
term = [v for v in Graphs.vertices(sched) if CB.matches_template(CB.RobotGo, CB.get_node(sched,v)) && Graphs.outdegree(sched,v)==0]
println("count = ", length(term))
for v in term[1:min(end,6)]
    println(describe(v))
end

# --- pick a robot, find every RobotGo bound to it -----------------------------
println("\n========== all RobotGo nodes bound to robot of RobotStart#1 ==========")
r1 = CB.entity(CB.get_node(sched, robot_starts[1]).node).id
println("target BotID = ", r1)
for v in Graphs.vertices(sched)
    n = CB.get_node(sched, v).node
    CB.matches_template(CB.RobotGo, CB.get_node(sched, v)) || continue
    try
        if CB.entity(n).id == r1
            println(describe(v))
        end
    catch; end
end
println("\n>>> done.")
