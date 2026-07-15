# Standalone (no Revise) validation of restage_assembly! + control resume.
using ConstructionBots
import Graphs, Logging, HiGHS, JuMP, LinearAlgebra, Serialization
const CB = ConstructionBots
const norm = LinearAlgebra.norm

# --- BASE_ENV cache -----------------------------------------------------------
# build_base_env() runs run_lego_demo + 4000 steps (~minutes). That cost is paid
# EVERY process invocation, which makes edit-rerun debugging painful. PlannerEnv is
# pure Julia (no PyObject RVO state here: rvo_flag=false), so stdlib Serialization
# round-trips it safely — unlike JLD2, which warns on anonymous functions. We cache
# the freshly-built env to a temp file (keyed by project + a version tag) and reuse
# it on later runs. Bump CACHE_VERSION (or delete the file) when build params change.
const CACHE_VERSION = "v1"
const BASE_ENV_CACHE = joinpath(tempdir(), "cb_base_env_p4_$(CACHE_VERSION).jls")

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
const BASE_ENV = build_base_env()
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
