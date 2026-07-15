# =============================================================================
# dev_session.jl  --  Persistent Revise REPL for FAST Julia-side iteration.
#
# The 85s precompile + minutes-long env build is a PER-PROCESS cost. Pay it ONCE
# by keeping a REPL open with Revise, then hot-reload code edits (replan.jl,
# verifier.jl, llm_bridge.jl, ...) with NO re-precompile and NO rebuild, and
# re-run the LLM-FREE timing test on a fresh deepcopy of the cached base env.
#
# Start it once:
#     julia +lts --project=. -i tools/dev_session.jl
#
# Then, after editing Julia source, at the REPL just call:
#     t()        # re-run the timing-persistence check on a fresh env copy
#     rebuild()  # only if you changed the env build / stepping itself
#
# Revise reloads the edited functions automatically before t() runs.
# =============================================================================
using Revise
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

# Cached once; deepcopy per test (deepcopy is FAITHFUL — never use Serialization,
# which corrupts cached transforms; see the timing-persistence gap doc).
println(">>> building base env once (this is the slow part, ~minutes)...")
const BASE_ENV = build_base_env()
println(">>> base env ready: $(Graphs.nv(BASE_ENV.sched)) nodes, closed=$(length(BASE_ENV.cache.closed_set))")

rebuild() = (global BASE_ENV; Core.eval(@__MODULE__, :(const BASE_ENV = $(build_base_env()))); nothing)

# Re-run the LLM-FREE timing-persistence check on a FRESH copy. Edit replan.jl etc.,
# then call t() — Revise reloads first. Returns true iff a binding ForbidWindow
# (the timing-only re-spec, which adds NO edge) persists past commit via the
# written MILP times alone.
function t()
    env = deepcopy(BASE_ENV)
    asm = CB.AbstractID[]
    for v in Graphs.vertices(env.sched)
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        get_node(env.sched, v).node isa CB.AssemblyComplete && push!(asm, CB.get_vtx_id(env.sched, v))
    end
    chosen = nothing
    for tgt in asm
        vt  = CB.get_vtx(env.sched, tgt)
        t0n = Float64(CB.get_t0(env.sched, vt))
        prop = CB.RespecProposal([CB.ForbidWindow(tgt, 0.0, t0n + 10.0)])
        inv = CB.build_invariant(env)
        CB.verify(prop, env, inv) isa CB.Admit || continue
        chosen = (tgt, vt, t0n + 10.0, prop, inv); break
    end
    chosen === nothing && (println("no admittable binding ForbidWindow"); return false)
    tgt, vt, t_hi, prop, inv = chosen
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer=CB._respec_optimizer(), t0_=inv.frozen_t0, tF_=inv.frozen_tF,
        extra_constraints=prop)
    CB.optimize!(milp)
    CB.commit_respec!(env, milp, prop)
    t0a = CB.get_t0(env.sched, vt)
    ok = t0a >= t_hi - 1e-6
    println("ForbidWindow($tgt, 0, $(round(t_hi,digits=2))): t0[node]=$(round(t0a,digits=2)) >= t_hi ? ", ok ? "✅ PASS" : "❌ FAIL")
    return ok
end

# -----------------------------------------------------------------------------
# RESUME full-loop fast check (LLM-free). Mirrors the user's actual scenario:
# a robot faults mid-build -> verified reassignment -> the sim RESUMES and drives
# the build to completion WITHOUT restarting already-finished work. Asserts the
# resume invariants the autonomy workflow's done-gate requires:
#   (1) closed_set never regresses at the commit (resume keeps progress), and
#   (2) the sim reaches project_complete with closed_set monotone throughout.
# Edit reset_cache_resume!/commit_respec!/fault_robot_and_reassign! -> Revise
# reloads -> call resume_test() again. No rebuild, no LLM.
# -----------------------------------------------------------------------------

"Advance a fresh sim copy to a deeper mid-build state (>= `target_closed` closed)."
function _advance_to(env; target_closed::Int, cap::Int)
    for _ in 1:cap
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0)
        (length(env.cache.closed_set) >= target_closed || CB.project_complete(env)) && break
    end
    return env
end

"Pick a still-valid robot that is on a PENDING transport team (so faulting it forces a real reassign)."
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

# step a copy to completion-or-assertion; returns (status, closed, iters, monotone)
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

"""
    resume_test(; target_closed=24, cap=60_000) -> Bool

VERIFIED green check for the resume INFRASTRUCTURE (`reset_cache_resume!`): take a
mid-build env, rebuild the planning frontier WITHOUT a schedule change, and confirm
the sim resumes to a complete, valid build with `closed_set` monotone. This is the
isolation that proved the frontier recompute is sound (no reassignment involved).
"""
function resume_test(; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    n0 = length(env.cache.closed_set); total = Graphs.nv(env.sched)
    CB.reset_cache_resume!(env.cache, env.sched)     # frontier recompute, no schedule change
    n1 = length(env.cache.closed_set)
    st = _run_to_end(env; cap = cap)
    pass = st[1] == :complete && st[4] && n1 >= n0
    println("resume_test: closed $n0 ->(resume) $n1 ->(end) $(st[2])/$total | " *
            "status=$(st[1]) monotone=$(st[4]) iters=$(st[3]) -> ", pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

"""
    reassign_resume_test(; target_closed=24, cap=100_000) -> Symbol

KNOWN-OPEN check: robot-fault -> reassign -> resume to completion. Currently returns
`:asserted` because the reassignment double-books a healthy robot (see
docs/resume_fulloop_status_2026-06-23.md). Use this to iterate on the reassignment
id-threading fix; it should return `:complete` once that bug is closed.
"""
function reassign_resume_test(; target_closed::Int = 24, cap::Int = 100_000)
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

# -----------------------------------------------------------------------------
# OOD 1-2 :: restriction-district (navigation no-go zone) GENERATION check.
# LLM-free, no full motion stack needed: validates the injection plumbing and the
# REAL avoidance consumer (get_closest_interfering_circle, the live TangentBug
# path) — NOT the buggy/dead circle_avoidance_policy. Confirms:
#   control       — with no zone, nothing interferes;
#   plumbing      — a registered zone enters active_staging_circles(env) (the
#                   obstacle set get_twist_cmd feeds TangentBug) with right geom;
#   detour        — a zone ON the pos->goal segment is flagged as interfering;
#   no-false-pos  — a zone OFF the path is NOT flagged.
# Edit ood_injection.jl / active_staging_circles -> Revise reloads -> zone_test().
# -----------------------------------------------------------------------------
function zone_test()
    env = deepcopy(BASE_ENV)
    CB.clear_restriction_zones!()
    pol = CB.TangentBugPolicy(; agent_radius = 0.5)
    L = 20.0
    pos = [0.0, 0.0]; goal = [L, 0.0]

    # (control) no zones registered -> nothing interferes on the path
    id0, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)
    ctrl_ok = id0 === nothing

    # inject a zone squarely on the pos->goal segment
    CB.add_restriction_zone!(:t, [L / 2, 0.0], 1.0)

    # (plumbing) the zone is in the obstacle set TangentBug actually reads
    obs = Dict{Any,Any}(collect(CB.active_staging_circles(env)))
    plumb_ok = haskey(obs, :t) &&
               isapprox(CB.get_center(obs[:t]), [L / 2, 0.0]; atol = 1e-9) &&
               isapprox(CB.get_radius(obs[:t]), 1.0; atol = 1e-9)

    # (avoidance) the on-path zone is flagged as the closest interfering circle
    id1, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)
    detour_ok = id1 == :t

    # (no false positive) a zone far OFF the path is NOT flagged
    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:off, [L / 2, 100.0], 1.0)
    id2, _, _ = CB.get_closest_interfering_circle(pol, CB.active_restriction_zones(), pos, goal)
    fp_ok = id2 === nothing

    CB.clear_restriction_zones!()
    pass = ctrl_ok && plumb_ok && detour_ok && fp_ok
    println("zone_test: control=$ctrl_ok plumbing=$plumb_ok detour=$detour_ok no-false-pos=$fp_ok -> ",
            pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

# -----------------------------------------------------------------------------
# OOD 1-2 :: ForbidZone RE-STAGING check (LLM-free geometric recovery).
# A no-go zone is dropped ON a not-yet-built assembly's staging area (which would
# deadlock the build), restage_assembly! relocates that assembly clear of the
# zone, and the sim must RESUME to a complete build. Asserts:
#   (1) status :restaged and the new center clears the zone,
#   (2) closed_set monotone + reaches project_complete (the rigid move kept the
#       staging subtree coherent -> the done-gate for §7.3).
# Edit restage_zone.jl -> Revise reloads -> restage_test().
# -----------------------------------------------------------------------------
function restage_test(; target_closed::Int = 24, cap::Int = 60_000)
    env = deepcopy(BASE_ENV)
    _advance_to(env; target_closed = target_closed, cap = cap)
    # root = the assembly whose staging circle is largest (encompasses the whole
    # build); never relocate it. Pick the DEEPEST-future SUB-assembly (max t0) that
    # is neither closed nor active.
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), collect(keys(env.staging_circles)))
    aid = nothing; bestt0 = -Inf
    for k in keys(env.staging_circles)
        k == root && continue
        ac = CB._assembly_complete_node(env, k)
        ac === nothing && continue
        v = CB.get_vtx(env.sched, CB.node_id(ac))
        (v in env.cache.closed_set || v in env.cache.active_set) && continue
        t0 = Float64(CB.get_t0(env.sched, v))
        t0 > bestt0 && (bestt0 = t0; aid = k)
    end
    aid === nothing && (println("restage_test: no future sub-assembly to restage"); return :no_assembly)

    ball = env.staging_circles[aid]
    c0 = Vector{Float64}(CB.get_center(ball)[1:2]); R = Float64(CB.get_radius(ball))
    n0 = length(env.cache.closed_set); total = CB.Graphs.nv(env.sched)

    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:block, c0, R)            # zone smack on its staging area
    res = CB.restage_assembly!(env, aid)
    if res.status != :restaged
        CB.clear_restriction_zones!()
        println("restage_test: status=$(res.status) ($(get(res, :detail, "")))"); return res.status
    end
    c1 = Vector{Float64}(res.to)
    clear = CB.norm(c1 .- c0) >= 2R                    # zone r=R, circle r=R -> centers >= 2R apart
    st = _run_to_end(env; cap = cap)
    CB.clear_restriction_zones!()

    pass = st[1] == :complete && st[4] && clear
    println("restage_test: asm=$(CB.summary(aid)) $(round.(c0; digits=2))->$(round.(c1; digits=2)) " *
            "closed $n0 ->(end) $(st[2])/$total | status=$(st[1]) monotone=$(st[4]) zone_clear=$clear -> ",
            pass ? "✅ PASS" : "❌ FAIL")
    return pass
end

println("""
>>> dev session ready.
    t()                    timing-persistence check on a fresh env copy
    resume_test()          VERIFIED: resume infrastructure -> build completes
    reassign_resume_test() KNOWN-OPEN: reassign+resume (asserts on double-booking)
    zone_test()            OOD 1-2: restriction-zone injection + TangentBug avoidance
    restage_test()         OOD 1-2: ForbidZone re-staging recovery -> build completes
    rebuild()              rebuild BASE_ENV (only if you changed the build/stepping)
""")
