# One-shot, non-interactive verification of the reassignment id-threading fix
# (rethread_robot_ids!). Self-contained (no Revise): builds the base env once, then
# runs the resume sanity check and the reassign+resume check several times (the
# HiGHS solver varies run-to-run, so multiple trials confirm the double-booking is
# gone, not just masked by one solve).
#
#   julia +lts --project=. tools/run_rethread_check.jl
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP
const CB = ConstructionBots

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0,
    CB.MOI.Silent() => true)

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

function build_base_env()
    pp = CB.get_project_params(4)   # tractor
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=false, tangent_bug_flag=false,
            dispersion_flag=false, open_animation_at_end=false, save_animation=false,
            save_animation_along_the_way=false, write_results=false,
            overwrite_results=false, look_for_previous_milp_solution=false,
            save_milp_solution=false, return_env_before_sim=true)
    end
    for _ in 1:4000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        length(env.cache.closed_set) >= 8 && break
    end
    return env
end

function _advance_to(env; target_closed::Int, cap::Int)
    for _ in 1:cap
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
    end
    return env
end

function _pick_faultable_agent(env)
    sched = env.sched
    seen = CB.AbstractID[]
    for v in Graphs.vertices(sched)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        node isa CB.RobotGo || continue
        rid = try CB.entity(node).id catch; nothing end
        (rid isa CB.RobotID && CB.valid_id(rid) && !(rid in seen)) || continue
        push!(seen, rid)
    end
    for rid in seen
        !isempty(CB.transport_teams_with_agent(env, rid; pending_only = true)) && return rid
    end
    return isempty(seen) ? nothing : first(seen)
end

function _run_to_end(env; cap::Int)
    prev = length(env.cache.closed_set); mono = true; iters = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try
            CB.update_planning_cache!(env, 0.0)
        catch err
            return (:asserted, length(env.cache.closed_set), iters, mono)
        end
        c = length(env.cache.closed_set); c < prev && (mono = false); prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono)
    end
    return (:capped, prev, iters, mono)
end

function resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.reset_cache_resume!(env.cache, env.sched)
    n1 = length(env.cache.closed_set)
    st = _run_to_end(env; cap = cap)
    pass = st[1] == :complete && st[4] && n1 >= n0
    println("resume_test: closed $n0 ->(resume) $n1 ->(end) $(st[2])/$total | " *
            "status=$(st[1]) monotone=$(st[4]) iters=$(st[3]) -> ", pass ? "PASS" : "FAIL")
    return pass
end

function reassign_resume_test(BASE_ENV; target_closed::Int = 24, cap::Int = 100_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    agent = _pick_faultable_agent(env)
    agent === nothing && (println("no valid robot to fault"); return :no_agent)
    res = CB.fault_robot_and_reassign!(env, agent; resume = true, verbose = false)
    res.status == :admitted || (println("reassign $(res.status)"); return res.status)
    st = _run_to_end(env; cap = cap)
    println("reassign_resume_test fault=$agent: closed $n0 ->(commit) $(length(env.cache.closed_set)) " *
            "->(resume) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) iters=$(st[3])")
    return st[1]
end

println(">>> building base env once (slow, ~minutes)...")
const BASE_ENV = build_base_env()
println(">>> base env ready: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

println("\n=== resume_test (resume infrastructure sanity) ===")
sane = resume_test(BASE_ENV)

println("\n=== reassign_resume_test (rethread fix) x5 ===")
results = Symbol[]
for i in 1:5
    r = reassign_resume_test(BASE_ENV)
    push!(results, r)
    println("  trial $i -> $r")
end

ncomplete = count(==(:complete), results)
println("\n=== SUMMARY ===")
println("resume_test sane : ", sane)
println("reassign trials  : ", results)
println("complete         : $ncomplete/5")
println(ncomplete == 5 && sane ? ">>> FIX VERIFIED" : ">>> NOT YET")
