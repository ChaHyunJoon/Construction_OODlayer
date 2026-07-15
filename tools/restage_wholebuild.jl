# =============================================================================
# restage_wholebuild.jl -- validate Phase B (whole-build translation) under the FULL
# motion stack (rvo + tangent_bug + dispersion ON).
#
# Sets up the case per-assembly restage CANNOT handle: a CENTRAL zone that covers the
# root's own (un-relocatable) deposit goals -> restage_all_blocked! returns
# :residual_blocked. Then translate_whole_build! shifts the ENTIRE build clear of the
# zone. PASS = build completes + robots never enter the zone.
#
# Scenarios (NAVON_MODE): "none" (zone, no fix -> expected STALL),
#                         "whole" (zone -> translate_whole_build! -> expected COMPLETE).
#
# Run:  julia +lts --project=. tools/restage_wholebuild.jl
#   NAVON_MODE=whole|none   NAVON_ZONE_R=2.5 (central zone radius)
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

const PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))     # 4 = tractor
const ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)
const MODE     = get(ENV, "NAVON_MODE", "whole")

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

function build_base_env()
    pp = CB.get_project_params(PROJECT)
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
_p2(t) = Vector{Float64}(CB.project_to_2d(t.translation))
_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))

# zone center = centroid of root deposit goals (the un-relocatable central core).
function _central_zone_center(env)
    gs = CB.root_deposit_goals(env)
    isempty(gs) && return Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])
    return sum(gs) ./ length(gs)
end

function _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0; worst = -Inf; viol = 0
    first_viol = -1; last_viol = -1                  # 침범이 일어난 첫/마지막 iter (대피 transient 판별용)
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (status=:asserted, closed=length(env.cache.closed_set), iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol) end
        step_pen = -Inf
        for rb in robots
            pen = (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)
            pen > step_pen && (step_pen = pen)
        end
        if step_pen > 1e-6
            viol += 1; first_viol < 0 && (first_viol = iters); last_viol = iters
        end
        step_pen > worst && (worst = step_pen)
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (status=:complete, closed=c, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)
    end
    return (status=:capped, closed=prev, iters=iters, mono=mono, worst=worst, viol=viol, first_viol=first_viol, last_viol=last_viol)
end

println(">>> building base env (PROJECT=$PROJECT) with FULL NAV STACK ON (slow)...")
const BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Info))

function scenario(; target_closed=18, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    rr = Float64(CB.default_robot_radius())
    zc = _central_zone_center(env); zr = ZONE_R
    rootc = Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, zc, zr)
    println("MODE=$MODE: CENTRAL zone@$(round.(zc;digits=2)) R=$zr  root@$(round.(rootc;digits=2)) " *
            "clears_root=$(CB.zone_clears_root_goals(zc, zr, env))  closed0=$n0")
    moved = "(none)"
    if MODE == "whole"
        ra = CB.restage_all_blocked!(env; resume=true, verbose=true)
        println("  restage_all -> status=$(ra.status) residual=$(get(ra,:residual,-1))  (expect residual_blocked)")
        wb = CB.translate_whole_build!(env; resume=true, verbose=true)
        println("  translate_whole_build! -> status=$(wb.status) Δ=$(get(wb,:delta,nothing)) residual=$(get(wb,:residual,-1))")
        wb.status != :translated && (CB.clear_restriction_zones!(); println("RESULT: whole-build $(wb.status) -> FAIL (no clear translate)"); return)
        moved = "wholebuild Δ=$(round.(Vector{Float64}(wb.delta);digits=2))"
        # after translating the build away, robots must not enter the (fixed) zone; track vs new zone too
    end
    st = _run_to_end_tracked(env, zc, zr, rr)
    # 침범이 초반(주입 직후 대피)에만 몰리는지: last_viol 가 전체 iter 대비 매우 이른가?
    evac_window = st.last_viol < 0 ? 0 : st.last_viol
    transient = st.viol == 0 || st.last_viol < max(2000, 0.1 * st.iters)   # 침범이 첫 10%(또는 2000스텝) 안에서 끝나면 대피 transient
    avoided_strict = st.worst <= 1e-6
    pass_strict = MODE == "whole" ? (st.status == :complete && st.mono && avoided_strict) : (st.status == :stalled)
    pass_evac   = MODE == "whole" ? (st.status == :complete && st.mono && transient)       : (st.status == :stalled)
    println("RESULT MODE=$MODE moved=$moved | closed $n0->$(st.closed)/$total status=$(st.status) monotone=$(st.mono) | " *
            "worst_pen=$(round(st.worst;digits=3)) viol_steps=$(st.viol) viol_iters=[$(st.first_viol)..$(st.last_viol)] of $(st.iters) | " *
            "strict_avoided=$avoided_strict evac_transient=$transient")
    println("  -> PASS(strict no-entry)=$pass_strict   PASS(evac-aware: completes + no RE-entry)=$pass_evac")
    CB.clear_restriction_zones!()
end

scenario()
