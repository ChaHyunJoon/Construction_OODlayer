# Full-scenario restage driver: NAVIGATION ON (TangentBug) + a forbid zone over an
# assembly's staging area + restage_assembly! relocation, run to completion while
# TRACKING whether any robot ever enters the zone. Unlike tools/restage_validate.jl
# (which runs with tangent_bug_flag=false, so the zone is NOT an active obstacle), this
# driver enables TangentBug so the injected zone is a real navigation no-go region
# (active_staging_circles, route_planning.jl). It answers: after restage, does the build
# COMPLETE *and* do robots AVOID the forbid zone in transit?
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!(
    "time_limit" => 300.0, "presolve" => "on", "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

function run_with_stack(f, stacksize::Int)
    result = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    wrapper = () -> (try result[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int), wrapper, nothing, stacksize)
    t.sticky = false; schedule(t)
    while !done[]; sleep(0.05); end
    if err[] !== nothing
        e, bt = err[]; showerror(stderr, e, bt); println(stderr); rethrow(e)
    end
    return result[]
end

# NOTE: tangent_bug_flag=true here (vs false in restage_validate) — navigation avoidance ON.
function build_base_env()
    pp = CB.get_project_params(4)
    env = run_with_stack(2_000_000_000) do
        CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
            model_scale=pp[:model_scale], num_robots=pp[:num_robots],
            assignment_mode=:greedy, milp_optimizer=:highs, optimizer_time_limit=60,
            log_level=Logging.Error, rvo_flag=true, tangent_bug_flag=true,
            dispersion_flag=true, open_animation_at_end=false, save_animation=false,
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

_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

_robot_nodes(env) = [n for n in CB.get_nodes(env.scene_tree) if CB.matches_template(CB.RobotNode, n)]

# run to completion; each step measure the deepest penetration of ANY robot into the
# zone disc (center c0, radius R). penetration = (R + robot_radius) - dist(robot, c0);
# >0 means the robot's body overlaps the no-go disc = a violation.
function _run_to_end_tracked(env, c0, R, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    worst = -Inf; viol_steps = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (:asserted, length(env.cache.closed_set), iters, mono, worst, viol_steps) end
        step_pen = -Inf
        for rb in robots
            p = Vector{Float64}(CB.project_to_2d(CB.global_transform(rb).translation))
            pen = (R + rr) - norm(p .- c0)
            pen > step_pen && (step_pen = pen)
        end
        step_pen > 1e-6 && (viol_steps += 1)
        step_pen > worst && (worst = step_pen)
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono, worst, viol_steps)
        stall >= stall_limit && return (:stalled, c, iters, mono, worst, viol_steps)
    end
    return (:capped, prev, iters, mono, worst, viol_steps)
end

println(">>> building base env with NAVIGATION ON (slow)...")
const BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

function restage_fullnav(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    rr = Float64(CB.default_robot_radius())
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_fullnav: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    # inject the forbid zone over this assembly's OLD staging, then relocate the assembly.
    # Zone stays active for the whole run below -> TangentBug treats it as a no-go disc.
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    res = CB.restage_assembly!(env, aid)
    if res.status != :restaged
        CB.clear_restriction_zones!(); println("restage_fullnav: status=$(res.status)"); return res.status
    end
    c1 = Vector{Float64}(res.to); clear = norm(c1 .- c0) >= 2R
    # how many robots are ALREADY inside the freshly-injected zone at restage time?
    trapped0 = 0
    for rb in _robot_nodes(env)
        p = Vector{Float64}(CB.project_to_2d(CB.global_transform(rb).translation))
        (R + rr) - norm(p .- c0) > 1e-6 && (trapped0 += 1)
    end
    println("restage_fullnav: robots INSIDE zone at injection time = $trapped0")
    st = _run_to_end_tracked(env, c0, R, rr; cap=250_000, stall_limit=8000)
    if st[1] == :stalled
        println("--- STALL @ closed=$(st[2]): active EntityGo frontier (pos/goal/d, zone_pen) ---")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            CB.matches_template(CB.EntityGo, n) || continue
            p = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.entity(n)).translation))
            g = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation))
            pen = (R + rr) - norm(p .- c0)
            println("  $(string(typeof(n).name.name)) $(CB.summary(CB.node_id(n))) pos=$(round.(p;digits=2)) " *
                    "goal=$(round.(g;digits=2)) d=$(round(norm(g.-p);digits=2)) zone_pen=$(round(pen;digits=2))")
        end
    end
    CB.clear_restriction_zones!()
    status, closed, iters, mono, worst, viol = st
    avoided = worst <= 1e-6
    pass = status == :complete && mono && clear && avoided
    println("restage_fullnav: asm=$(CB.summary(aid)) zone@$(round.(c0;digits=2)) R=$(round(R;digits=2)) " *
            "-> $(round.(c1;digits=2)) | closed $n0 ->(end) $closed/$total status=$status monotone=$mono " *
            "zone_clear=$clear | NAV: worst_penetration=$(round(worst;digits=3)) (>0=entered) " *
            "violation_steps=$viol -> ", pass ? "PASS" : "FAIL")
    return pass
end

println("=== RESTAGE + NAV ==="); restage_fullnav()
