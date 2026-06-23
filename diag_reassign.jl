# Diagnostic: figure out whether ForbidAgent blocked robot 1 and whether slots
# kept stale ids. Builds env ONCE. Run: julia --project=. diag_reassign.jl
using ConstructionBots
import Graphs, HiGHS, Logging
const CB = ConstructionBots

function run_with_stack(f, s::Int)
    r=Ref{Any}(nothing); er=Ref{Any}(nothing); d=Threads.Atomic{Bool}(false)
    w=function(); try r[]=f() catch e; er[]=(e,catch_backtrace()) finally d[]=true end; end
    t=ccall(:jl_new_task,Ref{Task},(Any,Any,Int),w,nothing,s); t.sticky=false; schedule(t)
    while !d[]; sleep(0.05); end
    er[]!==nothing && (showerror(stderr,er[][1],er[][2]); rethrow(er[][1])); r[]
end

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit"=>120.0,"presolve"=>"on",CB.MOI.Silent()=>true)

pp = get_project_params(4)
env = run_with_stack(2_000_000_000) do
    run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots],
        assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
        log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false, dispersion_flag=false,
        open_animation_at_end=false, save_animation=false, save_animation_along_the_way=false,
        write_results=false, overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
sched = env.sched
println(">>> env: ", Graphs.nv(sched), " nodes")

R = nothing
for v in Graphs.vertices(sched)
    n = CB.get_node(sched,v).node
    CB.matches_template(CB.RobotStart, CB.get_node(sched,v)) || continue
    id = CB.entity(n).id
    if !isempty(CB.transport_teams_with_agent(env, id; pending_only=true)); global R=id; break; end
end
println(">>> faulting robot id = ", R)

# origin vtx (RobotStart node bound to R)
ov = first(v for v in Graphs.vertices(sched)
           if CB.matches_template(CB.RobotStart, CB.get_node(sched,v)) && CB.entity(CB.get_node(sched,v).node).id == R)
println(">>> origin vtx = ", ov, "  out-edges BEFORE release = ", collect(Graphs.outneighbors(sched, ov)))

pred(v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))   # raw predicate at vtx
rid(v)  = (p=pred(v); p isa CB.RobotGo ? string(CB.get_id(CB.entity(p).id)) : "-")
isgo(v) = pred(v) isa CB.RobotGo

# record robot R's FTUs and their slot feeders BEFORE
function ftu_feeders(env, R)
    sched=env.sched; out=[]
    for v in Graphs.vertices(sched)
        CB.matches_template(CB.FormTransportUnit, CB.get_node(sched,v)) || continue
        for vp in Graphs.inneighbors(sched,v)
            isgo(vp) || continue
            if CB.entity(pred(vp)).id == R
                feeders = [f for f in Graphs.inneighbors(sched, vp) if isgo(f)]
                push!(out, (ftu=v, slot=vp, feeders=feeders, fids=[rid(f) for f in feeders]))
            end
        end
    end
    out
end
println("\n>>> FTUs robot R is on, BEFORE reassign (slot fed by free node):")
for t in ftu_feeders(env, R); println("   FTU v$(t.ftu) <- slot v$(t.slot)(id=$(rid(t.slot))) <- feeders $(t.feeders) ids=$(t.fids)"); end

# release
inv = CB.build_invariant(env)
removed = CB.release_pending_assignments!(env, inv; faulted = R)
println("\n>>> released ", length(removed), " edges. origin out-edges AFTER release = ", collect(Graphs.outneighbors(sched, ov)))

# Faithfully reproduce the real path: set the frozen/pinned frontier globals that
# the ForbidAgent compiler reads (fault_robot_and_reassign! sets these).
let closed_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.closed_set),
    active_ids = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    CB.RESPEC_FROZEN[] = closed_ids
    CB.RESPEC_PINNED[] = union(closed_ids, active_ids)
    println(">>> closed=$(length(closed_ids)) active=$(length(active_ids)) at fault time")
end

# PRE-SOLVE: list every node the ForbidAgent compiler considers a frontier for R,
# and (separately) every RobotGo currently still bound to R. If R can reach a slot
# through a free node that is bound-to-R but NOT a frontier, ForbidAgent misses it.
let
    frontier = Int[]; rgo = Int[]
    for v in Graphs.vertices(sched)
        n = pred(v)
        n isa CB.RobotGo || continue
        CB.bound_to_agent(n, R) || continue
        push!(rgo, v)
        CB.is_agent_frontier(sched, v, n, R) && push!(frontier, v)
    end
    println(">>> PRE-SOLVE: RobotGo nodes still bound to R = $rgo")
    println(">>> PRE-SOLVE: ForbidAgent frontier nodes for R = $frontier")
    for v in rgo
        outs = [v2 for v2 in Graphs.outneighbors(sched, v)]
        println("      R-node v$v preds=$(collect(Graphs.inneighbors(sched,v))) outs=$outs frontier=$(v in frontier)")
    end
end

# Build milp WITH forbid, inspect compiled count by instrumenting compile_proposal!
proposal = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidAgent(R, 0.0)], "diag", "diag")
milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, env.scene_tree;
    optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF, extra_constraints=proposal)
CB.optimize!(milp)
println(">>> primal_status = ", CB.primal_status(milp))

CB.update_project_schedule!(nothing, milp, sched, env.scene_tree)
CB.reset_cache!(env.cache, sched)

println("\n>>> AFTER reassign: each FTU slot, its id, and the free node feeding it (id):")
for v in Graphs.vertices(sched)
    CB.matches_template(CB.FormTransportUnit, CB.get_node(sched,v)) || continue
    for vp in Graphs.inneighbors(sched,v)
        isgo(vp) || continue
        feeders = [f for f in Graphs.inneighbors(sched, vp) if isgo(f)]
        fids = [rid(f) for f in feeders]
        if rid(vp) == string(CB.get_id(R)) || any(==(string(CB.get_id(R))), fids)
            println("   FTU v$v slot v$vp slot_id=$(rid(vp))  feeders=$feeders feeder_ids=$fids")
        end
    end
end

# BACKTRACE: for every node still bound to R after reassign, walk predecessors to
# the root RobotStart. If it reaches RobotStart(R) the solver genuinely routed R
# there (ForbidAgent gap). If it reaches a DIFFERENT robot's start, or no start,
# the id=1 is a stale-propagation artifact (reset/first_valid bug).
function backtrace_to_start(sched, v; maxdepth=50)
    chain = Tuple{Int,String,String}[]
    cur = v
    for _ in 1:maxdepth
        n = pred(cur)
        tname = string(nameof(typeof(n)))
        idstr = try string(CB.get_id(CB.entity(n).id)) catch; "-" end
        push!(chain, (cur, tname, idstr))
        n isa CB.RobotStart && break
        ins = collect(Graphs.inneighbors(sched, cur))
        isempty(ins) && break
        cur = first(ins)
    end
    return chain
end
println("\n>>> BACKTRACE of R-bound nodes after reassign (vtx, type, id) -> root:")
for v in Graphs.vertices(sched)
    n = pred(v)
    (n isa CB.RobotGo && CB.bound_to_agent(n, R)) || continue
    println("   from v$v: ", backtrace_to_start(sched, v))
end

println("\n>>> origin (robot R) out-edges AFTER reassign = ", collect(Graphs.outneighbors(sched, ov)))
println(">>> teams_after (entity.id based) = ", length(CB.transport_teams_with_agent(env, R; pending_only=true)))
println(">>> validate = ", CB.validate(sched))
println(">>> done")
