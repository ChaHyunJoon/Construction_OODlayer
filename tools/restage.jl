# =============================================================================
# tools/restage.jl -- consolidated ConstructionBots restage/relocation validators.
#
# Every standalone tools/restage_*.jl script is now a FUNCTION in module `Restage`,
# sharing common boilerplate (MILP setup + run_with_stack) defined ONCE. A CLI/ENV
# dispatcher at the bottom lets any single validator run individually.
#
# Restage keys:
#   wholebuild -- Phase B whole-build translation under FULL nav: a CENTRAL zone that
#                 covers the root's own deposit goals -> restage_all_blocked! is
#                 :residual_blocked -> translate_whole_build! shifts the ENTIRE build.
#   fullnav    -- restage_assembly! with NAVIGATION ON (TangentBug): forbid zone over a
#                 sub-assembly's staging, relocate, run to completion tracking zone entry.
#   navon      -- restage UNDER full motion stack with a root-clear zone that BLOCKS a
#                 target assembly's build; CONTROL(no restage)/single/all scenarios.
#   validate   -- nav-OFF standalone validation of restage_assembly! + control resume
#                 (+ multi-assembly restage_all), with a cached BASE_ENV for fast reruns.
#
# Run:
#   julia +lts --project=. tools/restage.jl <restage_key>        (or  ENV RESTAGE=<key>)
# e.g.
#   julia +lts --project=. tools/restage.jl navon
#   RESTAGE=validate julia +lts --project=. tools/restage.jl
# Each validator reads its own ENV knobs at call time (see the comment above each function).
# =============================================================================
module Restage
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra, Serialization
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# ---- shared helpers (defined ONCE) ------------------------------------------
# The set_default_milp_optimizer! block that appears (identically) in all 4 scripts
# (time_limit=300.0, presolve=on, mip_rel_gap=5.0, MOI.Silent). Copied verbatim from
# tools/demos.jl so the two consolidations stay in lock-step.
function _setup_milp!(; time_limit = 300.0, mip_rel_gap = 5.0)
    CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
    CB.clear_default_milp_optimizer_attributes!()
    CB.set_default_milp_optimizer_attributes!(
        "time_limit" => time_limit, "presolve" => "on", "mip_rel_gap" => mip_rel_gap,
        CB.MOI.Silent() => true)
end

# The identical stack-growing task helper from all 4 scripts (copied verbatim from demos.jl).
function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

# =============================================================================
# wholebuild -- validate Phase B (whole-build translation) under the FULL motion
#   stack (rvo + tangent_bug + dispersion ON). A CENTRAL zone covers the root's own
#   (un-relocatable) deposit goals -> restage_all_blocked! returns :residual_blocked;
#   then translate_whole_build! shifts the ENTIRE build clear of the zone.
#   ENV: NAVON_PROJECT, NAVON_ZONE_R, NAVON_MODE (whole|none).
# =============================================================================
function restage_wholebuild()
PROJECT  = parse(Int, get(ENV, "NAVON_PROJECT", "4"))     # 4 = tractor
ZONE_R   = parse(Float64, get(ENV, "NAVON_ZONE_R", "2.5")) # central zone radius (covers root core)
MODE     = get(ENV, "NAVON_MODE", "whole")

_setup_milp!()

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
BASE_ENV = build_base_env()
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
end

# =============================================================================
# fullnav -- restage_assembly! relocation with NAVIGATION ON (TangentBug): a forbid
#   zone over a future sub-assembly's staging area, relocate, run to completion while
#   TRACKING whether any robot ever enters the zone. TangentBug makes the injected
#   zone a real no-go region (active_staging_circles). No ENV knobs (project 4 fixed).
# =============================================================================
function restage_fullnav()
_setup_milp!()

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
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

function restage_fullnav_scenario(; target_closed=24, cap=60_000)
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

println("=== RESTAGE + NAV ==="); restage_fullnav_scenario()
end

# =============================================================================
# navon -- restage UNDER the full motion stack (rvo + tangent_bug + dispersion ON),
#   with a forbid zone that actually blocks an assembly's build. The zone is centered
#   on a target assembly's staging center but SHRUNK below the nearest sibling goal so
#   it blocks the target's build origin yet spares siblings (restage-RECOVERABLE).
#   ENV: NAVON_ZONE_R, NAVON_TARGET (central|peripheral|bestclear), NAVON_PROJECT,
#        NAVON_MODE (none|single|all).
# =============================================================================
function restage_navon()
# zone radius: NAVON_ZONE_R if set, else the chosen target's own staging radius (covers
# exactly that assembly's staging). NAVON_TARGET=central|peripheral picks the assembly.
ZONE_R_ENV = haskey(ENV, "NAVON_ZONE_R") ? parse(Float64, ENV["NAVON_ZONE_R"]) : nothing
TARGET = get(ENV, "NAVON_TARGET", "central")

_setup_milp!()

# FULL motion stack ON (rvo + tangent_bug + dispersion) — matches run_zone_demo.
PROJECT = parse(Int, get(ENV, "NAVON_PROJECT", "4"))   # 4=tractor; try roomier models (6=x_wing_mini, etc.)
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
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

# NOTE: RVO sim/map is PROCESS-GLOBAL, so a 2nd scenario on a fresh deepcopy crashes
# (rvo_get_agent_idx BoundsError) — run ONE scenario per process. CONTROL (zone, no
# restage) was confirmed to STALL @152 in a prior run; here we run the RESTAGE case.
# NAVON_MODE: none | single | all (default "all" = Phase a multi-assembly relocation)
MODE = get(ENV, "NAVON_MODE", "all")
println("=== NAV-ON scenario mode=$MODE target=$TARGET zone_R=$(ZONE_R_ENV===nothing ? "auto" : ZONE_R_ENV) ===")
scenario(uppercase(MODE); mode=MODE)
end

# =============================================================================
# validate -- standalone (no Revise) validation of restage_assembly! + control resume,
#   run with NAV OFF (rvo/tangent_bug/dispersion=false: robots beeline to goals) so it
#   proves the SCHEDULE/geometry of restage. Caches the freshly-built BASE_ENV to a temp
#   file (stdlib Serialization) for fast edit-rerun. CONTROL / RESTAGE(single) /
#   RESTAGE-ALL(multi) scenarios. No ENV knobs.
# =============================================================================
function restage_validate()
# --- BASE_ENV cache -----------------------------------------------------------
# build_base_env() runs run_lego_demo + 4000 steps (~minutes). That cost is paid
# EVERY process invocation, which makes edit-rerun debugging painful. PlannerEnv is
# pure Julia (no PyObject RVO state here: rvo_flag=false), so stdlib Serialization
# round-trips it safely — unlike JLD2, which warns on anonymous functions. We cache
# the freshly-built env to a temp file (keyed by project + a version tag) and reuse
# it on later runs. Bump CACHE_VERSION (or delete the file) when build params change.
CACHE_VERSION = "v1"
BASE_ENV_CACHE = joinpath(tempdir(), "cb_base_env_p4_$(CACHE_VERSION).jls")

_setup_milp!()

function build_base_env()
    if isfile(BASE_ENV_CACHE)
        println(">>> loading cached BASE_ENV from $BASE_ENV_CACHE (delete to force rebuild)")
        try
            return Serialization.deserialize(BASE_ENV_CACHE)
        catch e
            @warn "cached BASE_ENV failed to load; rebuilding" exception=e
        end
    end
    pp = CB.get_project_params(4)
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
    try
        Serialization.serialize(BASE_ENV_CACHE, env)
        println(">>> cached BASE_ENV to $BASE_ENV_CACHE")
    catch e
        @warn "could not cache BASE_ENV (will rebuild next run)" exception=e
    end
    return env
end

# Explain WHY an active EntityGo node refuses to close, mirroring is_goal()'s gate
# exactly (route_planning.jl). Distance d=0.0 is NOT the close condition — the gate
# is successor-readiness + (for FormTransportUnit) whole-team capture.
function explain_block(env)
    sched = env.sched; cache = env.cache
    for v in cache.active_set
        wrap = CB.get_node(sched, v); node = wrap.node
        tname = string(typeof(node).name.name)
        if !CB.matches_template(CB.EntityGo, node)
            println("    [$tname $(CB.summary(CB.node_id(node)))] non-EntityGo (is_goal=>$(CB.is_goal(wrap, env)))")
            continue
        end
        state = CB.global_transform(CB.entity(node))
        goal  = CB.global_transform(CB.goal_config(node))
        if !CB.is_within_capture_distance(state, goal)
            println("    [$tname $(CB.summary(CB.node_id(node)))] NOT at goal yet"); continue
        end
        if CB.is_terminal_node(sched, node)
            println("    [$tname $(CB.summary(CB.node_id(node)))] TERMINAL node -> is_goal false by design (never closes)"); continue
        end
        outs = CB.outneighbors(sched, node)
        if isempty(outs); println("    [$tname $(CB.summary(CB.node_id(node)))] no successor"); continue; end
        nxt = CB.get_node(sched, outs[1]); nx = nxt.node
        nxname = string(typeof(nx).name.name)
        blockers = String[]
        for vp in CB.inneighbors(sched, nxt)
            if !((vp in cache.active_set) || (vp in cache.closed_set))
                np = CB.get_node(sched, vp).node
                push!(blockers, "$(string(typeof(np).name.name)) $(CB.summary(CB.node_id(np)))")
            end
        end
        if !isempty(blockers)
            bstr = join(blockers, ", ")
            println("    [$tname $(CB.summary(CB.node_id(node)))] succ=$nxname $(CB.summary(CB.node_id(nx))) NOT ready; missing preds: $bstr"); continue
        end
        if CB.matches_template(CB.FormTransportUnit, nxt)
            tu = CB.entity(nxt); notinplace = String[]
            tuc = Vector{Float64}(CB.project_to_2d(CB.global_transform(tu).translation))
            # where is the CARGO (object being picked up) right now? resolves A vs B:
            #   cargo ≈ tu  -> formation anchored at fixed pickup (B)
            #   cargo moved with assembly -> formation should follow assembly (A)
            cargo = CB.get_node(env.scene_tree, CB.cargo_id(tu))
            cpos = Vector{Float64}(CB.project_to_2d(CB.global_transform(cargo).translation))
            println("        cargo $(CB.summary(CB.cargo_id(tu))) pos=$(round.(cpos;digits=2))  tu@$(round.(tuc;digits=2))  d(cargo,tu)=$(round(norm(cpos.-tuc);digits=2))")
            for (id, _) in CB.robot_team(tu)
                robot = CB.get_node(env.scene_tree, id)
                if !CB.is_within_capture_distance(tu, robot)
                    rp = Vector{Float64}(CB.project_to_2d(CB.global_transform(robot).translation))
                    # where is this robot actually parked? find its own active EntityGo
                    own = ""
                    for vv in cache.active_set
                        nn = CB.get_node(sched, vv).node
                        if CB.matches_template(CB.EntityGo, nn) && CB.entity(nn) === robot
                            gg = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation))
                            own = " | own-node $(string(typeof(nn).name.name)) $(CB.summary(CB.node_id(nn))) goal=$(round.(gg;digits=2)) dgoal=$(round(norm(gg.-rp);digits=2))"
                            break
                        end
                    end
                    push!(notinplace, "$(string(id)) robotpos=$(round.(rp;digits=2)) d2tu=$(round(norm(rp.-tuc);digits=2))$own")
                end
            end
            if !isempty(notinplace)
                println("    [$tname $(CB.summary(CB.node_id(node)))] succ=FormTransportUnit tu@$(round.(tuc;digits=2)) waiting OFF-position robots:")
                for s in notinplace; println("        - $s"); end
                continue
            end
        end
        println("    [$tname $(CB.summary(CB.node_id(node)))] is_goal SHOULD be true -> $(CB.is_goal(wrap, env)) (unexpected)")
    end
end

_advance_to(env; target_closed, cap) = (for _ in 1:cap
    CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
    (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
end; env)

function _run_to_end(env; cap, stall_limit=20000)
    prev = length(env.cache.closed_set); mono = true; iters = 0; stall = 0
    for _ in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e
            println("--- ASSERTED @ closed=$(length(env.cache.closed_set)) ---")
            showerror(stdout, e, catch_backtrace()); println()
            # probe: for the part that failed capture, dump the carry chain globals
            for v in env.cache.active_set ∪ env.cache.closed_set
                n = CB.get_node(env.sched, v).node
                CB.matches_template(CB.LiftIntoPlace, n) || continue
                cargo = CB.entity(n)
                CB.matches_template(CB.ObjectNode, cargo) || continue
                oid = CB.node_id(cargo)
                op  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.get_node(env.scene_tree, oid)).translation)); digits=2)
                lg  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)); digits=2)
                ls  = round.(Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.start_config(n)).translation)); digits=2)
                println("    LiftIntoPlace $(CB.summary(oid)): obj@$op  lift_start@$ls  lift_goal@$lg")
            end
            return (:asserted, length(env.cache.closed_set), iters, mono)
        end
        c = length(env.cache.closed_set); c < prev && (mono = false)
        stall = c > prev ? 0 : stall + 1
        prev = c; iters += 1
        CB.project_complete(env) && return (:complete, c, iters, mono)
        stall >= stall_limit && return (:stalled, c, iters, mono)
    end
    return (:capped, prev, iters, mono)
end

println(">>> building base env (slow)...")
BASE_ENV = build_base_env()
println(">>> base env: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

# control: resume infra (no schedule change) completes
function control_resume(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    n0 = length(env.cache.closed_set)
    CB.reset_cache_resume!(env.cache, env.sched)
    st = _run_to_end(env; cap)
    println("control_resume: closed $n0 ->(end) $(st[2]) | status=$(st[1]) monotone=$(st[4])")
    return st[1] == :complete && st[4]
end

function restage_check(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    # root = the assembly whose staging circle is largest (encompasses the build); never relocate it
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_check: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    res = CB.restage_assembly!(env, aid)
    if res.status != :restaged
        CB.clear_restriction_zones!()
        d = get(res, :detail, "")
        println("restage_check: status=$(res.status) ($d)")
        return res.status
    end
    c1 = Vector{Float64}(res.to); clear = norm(c1 .- c0) >= 2R
    st = _run_to_end(env; cap=250_000, stall_limit=8000)
    if st[1] == :stalled
        println("--- STALL @ closed=$(st[2]): active frontier ---")
        for v in env.cache.active_set
            n = CB.get_node(env.sched, v).node
            tname = string(typeof(n).name.name)
            extra = ""
            if CB.matches_template(CB.EntityGo, n)
                p = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.entity(n)).translation))
                g = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation))
                extra = " pos=$(round.(p;digits=2)) goal=$(round.(g;digits=2)) d=$(round(norm(g.-p);digits=2))"
            end
            println("  $tname $(CB.summary(CB.node_id(n)))$extra")
        end
        println("--- WHY each frontier node won't close (is_goal gate) ---")
        explain_block(env)
    end
    CB.clear_restriction_zones!()
    pass = st[1] == :complete && st[4] && clear
    println("restage_check: asm=$(CB.summary(aid)) $(round.(c0;digits=2))->$(round.(c1;digits=2)) closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) zone_clear=$clear -> ", pass ? "PASS" : "FAIL")
    return pass
end

# Phase 5.1: multi-assembly recovery. Inject ONE zone big enough to overlap SEVERAL
# assemblies' staging circles (zone = a sub-assembly's full staging circle already
# engulfs its dense-center siblings), then restage_all_blocked! must relocate ALL of
# them and the build must still complete (vs restage_check which moves only one).
function restage_all_check(; target_closed=24, cap=60_000)
    env = deepcopy(BASE_ENV); _advance_to(env; target_closed, cap)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k); ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v)); t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_all_check: no future sub-assembly"); return :no_assembly)
    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.clear_restriction_zones!(); CB.add_restriction_zone!(:block, c0, R)
    blocked = CB.zone_blocked_assemblies(env)
    println("restage_all_check: zone@$(round.(c0;digits=2)) R=$(round(R;digits=2)) blocks $(length(blocked)) assemblies: $([CB.summary(b) for b in blocked])")
    res = CB.restage_all_blocked!(env)
    println("restage_all_check: restage_all status=$(res.status) moved=$(length(res.moved)) failed=$(length(res.failed))")
    if res.status in (:none, :infeasible)
        CB.clear_restriction_zones!(); println("restage_all_check: nothing relocated -> SKIP"); return res.status
    end
    st = _run_to_end(env; cap=250_000, stall_limit=8000)
    if st[1] != :complete
        println("--- restage_all STALL/abort @ closed=$(st[2]) ---"); explain_block(env)
    end
    CB.clear_restriction_zones!()
    pass = st[1] == :complete && st[4]
    println("restage_all_check: blocked=$(length(blocked)) moved=$(length(res.moved)) closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) -> ", pass ? "PASS" : "FAIL")
    return pass
end

println("=== CONTROL ==="); control_resume()
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))  # surface capture @warn during restage
println("=== RESTAGE (single) ==="); restage_check()
println("=== RESTAGE-ALL (multi, Phase a) ==="); restage_all_check()
end

# ---- dispatcher -------------------------------------------------------------
const RESTAGES = Dict(
    "wholebuild" => restage_wholebuild,
    "fullnav"    => restage_fullnav,
    "navon"      => restage_navon,
    "validate"   => restage_validate,
)
end # module Restage

if abspath(PROGRAM_FILE) == @__FILE__
    key = get(ENV, "RESTAGE", isempty(ARGS) ? "wholebuild" : ARGS[1])
    haskey(Restage.RESTAGES, key) || error("unknown restage '$key'. Available: $(join(sort(collect(keys(Restage.RESTAGES))), ", "))")
    println(">>> running restage: $key")
    Restage.RESTAGES[key]()
end
