# =============================================================================
# restage_navon.jl -- restage UNDER the full motion stack (rvo + tangent_bug +
# dispersion ON), with a forbid zone that actually blocks an assembly's build.
#
# Unlike restage_validate.jl (nav OFF: robots beeline to goals — proves the
# SCHEDULE/geometry of restage) this driver turns navigation ON, so the injected
# zone is a real TangentBug no-go disc (active_staging_circles). It answers the open
# question: with avoidance ON, after restage, do robots ROUTE to the new staging
# around the still-active zone and COMPLETE the build, without entering the zone?
#
# Design (learned from restage_fullnav's stall): the zone must NOT contain any
# robot's GOAL — TangentBug makes a robot wait forever at the rim if its goal is
# inside a circle (route_planning.jl:673). So the zone is centered on the target
# assembly's staging center but SHRUNK (ZONE_R) below the nearest sibling goal
# (~2.9), so it blocks the target's build origin yet spares siblings.
#
# Runs TWO scenarios on copies of one base env (one slow build serves both):
#   CONTROL : same zone, NO restage -> expected STALL (zone blocks the build)
#   RESTAGE : same zone, restage the assembly -> expected COMPLETE + zero zone entry
#
# Run:  julia --project=. tools/restage_navon.jl
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# zone radius: NAVON_ZONE_R if set, else the chosen target's own staging radius (covers
# exactly that assembly's staging). NAVON_TARGET=central|peripheral picks the assembly.
const ZONE_R_ENV = haskey(ENV, "NAVON_ZONE_R") ? parse(Float64, ENV["NAVON_ZONE_R"]) : nothing
const TARGET = get(ENV, "NAVON_TARGET", "central")

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

# FULL motion stack ON (rvo + tangent_bug + dispersion) — matches run_zone_demo.
const PROJECT = parse(Int, get(ENV, "NAVON_PROJECT", "4"))   # 4=tractor; try roomier models (6=x_wing_mini, etc.)
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

# run to end; track deepest robot penetration into the zone disc (center zc, radius zr).
function _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    robots = _robot_nodes(env)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    worst = -Inf; viol_steps = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch; return (:asserted, length(env.cache.closed_set), iters, mono, worst, viol_steps) end
        step_pen = -Inf
        for rb in robots
            pen = (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc)
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

_root_id(env) = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
_is_future(env, k) = (ac = CB._assembly_complete_node(env, k); ac === nothing && return false;
    v = CB.get_vtx(env.sched, CB.node_id(ac)); !(v in env.cache.closed_set || v in env.cache.active_set))

function _pick_target(env)  # central: largest-t0 future non-root sub-assembly (its staging ~ workspace center)
    root = _root_id(env); aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        (k == root || !_is_future(env, k)) && continue
        t0 = Float64(CB.get_t0(env.sched, CB.get_vtx(env.sched, CB.node_id(CB._assembly_complete_node(env, k)))))
        t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    return aid
end

# peripheral: the future non-root sub-assembly with the SMALLEST staging circle (a
# leaf / self-contained assembly). A zone sized to its small radius covers just that
# one assembly's staging — NOT the root's central build goals — so restage can fully
# clear it (residual 0). (Picking "farthest from root" instead grabbed the BIGGEST
# sub-assembly whose huge circle re-engulfed everything -> residual_blocked.)
function _pick_peripheral_target(env)
    root = _root_id(env)
    aid = nothing; bestR = Inf
    for k in keys(env.staging_circles)
        (k == root || !_is_future(env, k)) && continue
        R = Float64(CB.get_radius(env.staging_circles[k]))
        R < bestR && (bestR = R; aid = k)
    end
    return aid
end

# bestclear: the future sub-assembly whose staging center is FARTHEST from the nearest
# root deposit goal -> the largest restage-recoverable zone fits there. Also prints the
# root-clear cap of every candidate so we can see if the model has ANY roomy spot.
function _pick_bestclear_target(env)
    root = _root_id(env)
    rootgoals = CB.root_deposit_goals(env)
    isempty(rootgoals) && return _pick_peripheral_target(env)
    aid = nothing; best = -Inf
    println("  per-assembly root-clear cap (dist to nearest root deposit goal):")
    for k in sort(collect(keys(env.staging_circles)); by = x -> string(x))
        (k == root || !_is_future(env, k)) && continue
        c = Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2])
        d = minimum(norm(c .- g) for g in rootgoals)
        println("    $(CB.summary(k)): cap=$(round(d;digits=2))  stagingR=$(round(Float64(CB.get_radius(env.staging_circles[k]));digits=2))")
        d > best && (best = d; aid = k)
    end
    return aid
end

# mode: "none" (zone, no restage) | "single" (restage_assembly! on the one target) |
#       "all" (restage_all_blocked! — Phase a: relocate EVERY assembly the zone covers)
function scenario(label; mode, target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    rr = Float64(CB.default_robot_radius())
    aid = TARGET == "peripheral" ? _pick_peripheral_target(env) :
          TARGET == "bestclear"  ? _pick_bestclear_target(env)  : _pick_target(env)
    aid === nothing && (println("$label: no future sub-assembly"); return)
    ball = env.staging_circles[aid]
    zc = Vector{Float64}(CB.get_center(ball)[1:2])              # zone over the target's staging center
    zr_req = ZONE_R_ENV === nothing ? Float64(CB.get_radius(ball)) : ZONE_R_ENV  # requested = target's staging radius
    rootc = Vector{Float64}(CB.get_center(env.staging_circles[_root_id(env)])[1:2])
    # GENERATION CONSTRAINT: keep the zone clear of the root's (un-relocatable) deposit
    # goals — shrink its radius so it never reaches the nearest one. Guarantees the
    # injected zone is restage-RECOVERABLE (can only block relocatable sub-assemblies).
    rootgoals = CB.root_deposit_goals(env)
    maxclear = isempty(rootgoals) ? Inf : minimum(norm(zc .- g) for g in rootgoals) - rr
    zr = min(zr_req, maxclear)
    zr <= rr && (println("$label: no root-clear radius at $(CB.summary(aid)) (nearest root goal $(round(maxclear+rr;digits=2))) -> SKIP"); return)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, zc, zr)
    trapped0 = count(rb -> (zr + rr) - norm(_p2(CB.global_transform(rb)) .- zc) > 1e-6, _robot_nodes(env))
    println("$label: target=$(CB.summary(aid)) zone@$(round.(zc;digits=2)) R=$(round(zr;digits=2)) (req $(round(zr_req;digits=2)), root-clear cap $(round(maxclear;digits=2))) " *
            "root@$(round.(rootc;digits=2)) clears_root=$(CB.zone_clears_root_goals(zc, zr, env))")
    moved = "(none)"
    if mode == "single"
        res = CB.restage_assembly!(env, aid)
        res.status != :restaged && (CB.clear_restriction_zones!(); println("$label: restage status=$(res.status)"); return)
        moved = "1 asm -> $(round.(Vector{Float64}(res.to);digits=2))"
    elseif mode == "all"
        blocked = CB.zone_blocked_assemblies(env)
        println("$label: zone blocks $(length(blocked)) assemblies: $([CB.summary(b) for b in blocked])")
        res = CB.restage_all_blocked!(env)
        moved = "$(length(res.moved)) asm (status=$(res.status), failed=$(length(res.failed)), residual=$(get(res,:residual,-1)))"
        res.status in (:none, :infeasible, :residual_blocked) &&
            (CB.clear_restriction_zones!(); println("$label: restage_all $(moved) -> INFEASIBLE/SKIP (fallback)"); return res.status)
    end
    st = _run_to_end_tracked(env, zc, zr, rr; cap=250_000, stall_limit=8000)
    status, closed, iters, mono, worst, viol = st
    if status != :complete
        println("  [$label $(status) @ closed=$closed] frontier goals vs zone (dist<$(round(zr;digits=2))=goal trapped IN zone):")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            CB.matches_template(CB.EntityGo, n) || continue
            g = _p2(CB.global_transform(CB.goal_config(n)))
            println("    $(string(typeof(n).name.name)) $(CB.summary(CB.node_id(n))) goal=$(round.(g;digits=2)) dist_to_zone_ctr=$(round(norm(g.-zc);digits=2))")
        end
    end
    avoided = worst <= 1e-6
    pass = status == :complete && mono && avoided
    println("$label: mode=$mode moved=$moved | closed $n0->$closed/$total status=$status monotone=$mono | " *
            "trapped@inject=$trapped0 worst_pen=$(round(worst;digits=3)) viol_steps=$viol avoided=$avoided -> ", pass ? "PASS" : "FAIL")
    CB.clear_restriction_zones!()
    return status
end

println(">>> building base env with FULL NAV STACK ON (slow)...")
const BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

# NOTE: RVO sim/map is PROCESS-GLOBAL, so a 2nd scenario on a fresh deepcopy crashes
# (rvo_get_agent_idx BoundsError) — run ONE scenario per process. CONTROL (zone, no
# restage) was confirmed to STALL @152 in a prior run; here we run the RESTAGE case.
# NAVON_MODE: none | single | all (default "all" = Phase a multi-assembly relocation)
const MODE = get(ENV, "NAVON_MODE", "all")
println("=== NAV-ON scenario mode=$MODE target=$TARGET zone_R=$(ZONE_R_ENV===nothing ? "auto" : ZONE_R_ENV) ===")
scenario(uppercase(MODE); mode=MODE)
