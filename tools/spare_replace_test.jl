# =============================================================================
# spare_replace_test.jl -- OOD 1-1 Part A4 done-gate (LLM-free).
# Builds a nav-ON env WITH 4 directional spare pools, steps to mid-build, faults an
# active robot, hands its remaining chain to the nearest spare via replace_robot!
# (no MILP), and resumes to completion. This is the core hypothesis test: does the
# spare 1:1 hand-off let the build COMPLETE where reassignment double-books?
#
# Asserts: spares are idle pre-fault; replace_robot! -> :replaced; closed_set
# monotone (never regress); project_complete; faulted robot never crashes RVO.
#
# Run:  julia +lts --project=. tools/spare_replace_test.jl
#   env: FAULT_AT (closed-count to fault at, default 24), NSPARE (per pool, default 2)
# =============================================================================
using ConstructionBots
import Graphs, Logging, HiGHS, LinearAlgebra
const CB = ConstructionBots
const norm = LinearAlgebra.norm

const FAULT_AT = parse(Int, get(ENV, "FAULT_AT", "24"))
const NSPARE   = parse(Int, get(ENV, "NSPARE", "2"))
const FAULT_OBSTACLE = get(ENV, "FAULT_OBSTACLE", "1") == "1"   # diag: drop a static obstacle on the dead robot?
const DO_FAULT = get(ENV, "FAULT", "1") == "1"                  # diag: FAULT=0 => control (spares present, no fault/replace)

CB.set_default_milp_optimizer!(() -> HiGHS.Optimizer())
CB.clear_default_milp_optimizer_attributes!()
CB.set_default_milp_optimizer_attributes!("time_limit" => 300.0, "presolve" => "on",
    "mip_rel_gap" => 5.0, CB.MOI.Silent() => true)

function run_with_stack(f, stacksize::Int)
    res = Ref{Any}(nothing); err = Ref{Any}(nothing); done = Threads.Atomic{Bool}(false)
    t = ccall(:jl_new_task, Ref{Task}, (Any, Any, Int),
        () -> (try res[] = f() catch e; err[] = (e, catch_backtrace()) finally done[] = true end), nothing, stacksize)
    t.sticky = false; schedule(t); while !done[]; sleep(0.05); end
    err[] !== nothing && (showerror(stderr, err[][1], err[][2]); println(stderr); throw(err[][1]))
    return res[]
end

npass = Ref(0); nfail = Ref(0)
check(name, cond) = (cond ? (npass[] += 1; println("  PASS: $name")) :
                            (nfail[] += 1; println("  FAIL: $name")))

const PROJECT = parse(Int, get(ENV, "PROJECT", "4"))   # 4=tractor(team carries), 1=colored_8x8(flat, solo)
pp = CB.get_project_params(PROJECT)
println(">>> building nav-ON env ($(pp[:project_name])) WITH $(4*NSPARE) spares ($(NSPARE)/pool)...")
CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
const ENV0 = run_with_stack(2_000_000_000) do
    CB.run_lego_demo(; ldraw_file=pp[:file_name], project_name=pp[:project_name],
        model_scale=pp[:model_scale], num_robots=pp[:num_robots], assignment_mode=:greedy,
        milp_optimizer=:highs, optimizer_time_limit=60, log_level=Logging.Error,
        rvo_flag=true, tangent_bug_flag=true, dispersion_flag=true,
        n_spare_per_pool=NSPARE,
        open_animation_at_end=false, save_animation=false, write_results=false,
        overwrite_results=false, look_for_previous_milp_solution=false,
        save_milp_solution=false, return_env_before_sim=true)
end
println(">>> env: $(Graphs.nv(ENV0.sched)) nodes; spare pools = $(collect(keys(CB.spare_pools())))")

# PRE-FAULT scan: does the BASE env already have any FTU fed by the SAME robot twice?
# (tells us if the duplicate-feeder is pre-existing build structure vs replace-induced)
let sched = ENV0.sched
    dup = 0
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        ids = Int[]
        for vp in Graphs.inneighbors(sched, v)
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo || continue
            r = try CB.entity(pn).id catch; nothing end
            r isa CB.RobotID && push!(ids, r.id)
        end
        if length(ids) != length(unique(ids))
            dup += 1
            dup <= 5 && println("[PRE-FAULT] FTU v=$v fed by robot ids $ids (DUPLICATE same-robot feeder)")
        end
    end
    println("[PRE-FAULT] FTUs with a same-robot duplicate feeder in BASE env: $dup")
end

env = deepcopy(ENV0)
total = Graphs.nv(env.sched)

# --- [1] spares present and IDLE (have an idle free node) pre-fault -------------
println("\n[1] spare pools idle pre-fault")
spares = CB.active_spares()
check("4*NSPARE spares registered", length(spares) == 4*NSPARE)
idle = count(s -> CB._idle_free_node(env.sched, s) !== nothing, spares)
println("    -> $(idle)/$(length(spares)) spares have an idle free node")
check("all spares are idle (unassigned)", idle == length(spares))

# --- step helper: returns status NamedTuple --------------------------------------
function step_to(env; until_closed=nothing, cap=250_000, stall_limit=8000)
    prev = length(env.cache.closed_set); stall = 0
    dyn = get(ENV, "DYN_SERIAL", "0") == "1"            # E1: dynamic serialization of spare frontiers
    reform = get(ENV, "REFORM_TEAMS", "0") == "1"       # ReformTeam: snap wedged teams on stall
    reform_at = parse(Int, get(ENV, "REFORM_AT", "1500"))   # no-progress steps before a re-formation
    for it in 1:cap
        CB.step_environment!(env)
        try CB.update_planning_cache!(env, 0.0) catch e
            return (status=:asserted, closed=length(env.cache.closed_set), iters=it, err=typeof(e))
        end
        dyn && CB._enforce_serial_frontiers!(env)
        c = length(env.cache.closed_set)
        stall = c > prev ? 0 : stall + 1; prev = c
        # CLOSED-LOOP: a sustained wedge -> re-form the stuck team(s), then keep going.
        if reform && stall >= reform_at
            nmv = CB.reform_stuck_teams!(env)
            println("    [REFORM] stall=$stall -> repositioned $nmv straggler(s) into formation")
            stall = 0                                   # gave the team a chance; reset the wedge clock
        end
        until_closed !== nothing && c >= until_closed && return (status=:reached, closed=c, iters=it)
        CB.project_complete(env) && return (status=:complete, closed=c, iters=it)
        stall >= stall_limit && return (status=:stalled, closed=c, iters=it)
    end
    return (status=:capped, closed=prev, iters=cap)
end

# --- [2] step to mid-build -------------------------------------------------------
println("\n[2] step to mid-build (target closed=$FAULT_AT)")
r1 = step_to(env; until_closed=FAULT_AT)
println("    -> $(r1.status) closed=$(r1.closed) iters=$(r1.iters)")
check("reached mid-build without assert/stall", r1.status == :reached)

# --- CONTROL: spares present, NO fault -> does the base build still complete? -----
if !DO_FAULT
    println("\n[CONTROL] spares present, NO fault -- run base build to completion")
    rc = step_to(env; cap=400_000)
    println("    -> $(rc.status) closed=$(rc.closed)/$total iters=$(rc.iters)")
    check("CONTROL base-with-spares completes", rc.status == :complete)
    CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
    println("\n==== A4 CONTROL: $(npass[]) passed, $(nfail[]) failed ====")
    println(nfail[] == 0 ? "CONTROL GREEN (spares idle don't block; stall is the hand-off)" :
            "CONTROL FAILED (the idle spares themselves break the build)")
    exit(nfail[] == 0 ? 0 : 1)
end

# A CLEANLY-replaceable target: a robot at a free frontier (heading to its NEXT
# pickup, NOT mid-carry), so its hand-off doesn't strand an in-progress transport
# team. = an active RobotGo that is a `_first_pending_assignment` frontier whose
# robot is not also sitting in an active transport-unit team.
function pick_clean_target(env)
    sched = env.sched
    in_active_team(rid) = any(env.cache.active_set) do v
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        (n isa CB.FormTransportUnit || n isa CB.TransportUnitGo) || return false
        team = try CB.robot_team(CB.entity(n)) catch; nothing end
        team !== nothing && haskey(team, rid)
    end
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        pend = CB._first_pending_assignment(env, rid)        # has a clean frontier + pending work
        pend === nothing && continue
        in_active_team(rid) && continue                       # skip mid-carry robots (MVP scope)
        return rid
    end
    return nothing
end

# A SOLO-transport target: a robot whose remaining (non-closed) transport tasks are
# ALL solo (team size 1). Faulting such a robot is the MVP-clean case: no OTHER robot
# is waiting for it as a co-carrier, so the single-spare hand-off has no multi-robot
# timing coordination to satisfy. (Multi-robot-carry faults are future work.)
function pick_solo_target(env)
    sched = env.sched
    # map robot id -> set of team sizes of its non-closed FTU memberships
    function robot_team_sizes(rid)
        sizes = Int[]
        for v in Graphs.vertices(sched)
            v in env.cache.closed_set && continue
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            n isa CB.FormTransportUnit || continue
            team = try CB.robot_team(CB.entity(n)) catch; nothing end
            team !== nothing && haskey(team, rid) && push!(sizes, length(team))
        end
        sizes
    end
    cands = CB.RobotID[]
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        rid = try CB.entity(n).id catch; nothing end
        rid isa CB.RobotID || continue
        CB._first_pending_assignment(env, rid) === nothing && continue   # has pending work
        sizes = robot_team_sizes(rid)
        (!isempty(sizes) && all(==(1), sizes)) || continue               # ALL solo
        push!(cands, rid)
    end
    isempty(cands) && return nothing
    return sort(cands, by = r -> r.id)[1]                                # DETERMINISTIC: lowest id
end

# --- [3] fault a SOLO-transport robot (MVP-clean), hand off to nearest spare ------
println("\n[3] fault a solo-transport robot + replace_robot! with nearest spare")
mode = get(ENV, "TARGET", "solo")
faulted = mode == "solo" ? pick_solo_target(env) :
          mode == "clean" ? pick_clean_target(env) : CB._pick_active_robot(env)
faulted === nothing && (println("    (no solo target; falling back to clean)"); faulted = pick_clean_target(env))
faulted === nothing && (faulted = CB._pick_active_robot(env))   # fallback if none clean
println("    -> faulting robot R$(faulted === nothing ? "?" : faulted.id)")
check("found an active robot to fault", faulted !== nothing)
clear_faulted = get(ENV, "CLEAR_FAULTED", "0") == "1"     # tow dead robot off-grid (demo config)
nl = CB.fault_robot!(env; target=faulted, obstacle=FAULT_OBSTACLE, clear=clear_faulted)
println("    -> clear_faulted = $clear_faulted")
println("    -> fault obstacle registered: $FAULT_OBSTACLE")
println("    -> NL: $nl")
fpos = CB._robot_position_2d(env, faulted)
pool = CB.nearest_pool(fpos)
println("    -> nearest pool = $(pool)")
check("a nearest spare pool exists", pool !== nothing)
spare = CB.pop_spare!(pool)
println("    -> donating spare R$(spare === nothing ? "?" : spare.id) from :$(pool)")
check("popped a spare from the pool", spare !== nothing)
park_rests = get(ENV, "PARK_RESTS", "1") == "1"
println("    -> park_rests = $park_rests")
res = CB.replace_robot!(env, faulted, spare; resume=true, park_rests=park_rests)
println("    -> replace_robot! status=$(res.status) slots=$(get(res,:slots,-1)) serialized=$(get(res,:serialized,-1)) fg=$(get(res,:fg,-1)) slot1=$(get(res,:slot1,-1))")
# DIAG R3: optionally PARK the faulted robot's dead frontier (force-close fg) so the
# faulted robot leaves the active frontier entirely, then rebuild the resume cache.
if get(ENV,"PARK_FAULTED","0") == "1" && haskey(res,:fg)
    fg = res.fg
    fg in env.cache.active_set && delete!(env.cache.active_set, fg)
    push!(env.cache.closed_set, fg)
    CB.reset_cache_resume!(env.cache, env.sched)
    println("    -> PARK_FAULTED: force-closed faulted dead frontier fg=$fg; rebuilt cache")
end
check("replace_robot! -> :replaced", res.status == :replaced)
check("hand-off moved >=1 downstream task", get(res,:slots,0) >= 1)

# --- [4] resume to completion (the done-gate) ------------------------------------
println("\n[4] resume to completion")
closed_after_replace = length(env.cache.closed_set)
r2 = step_to(env; cap=400_000)
println("    -> $(r2.status) closed=$(closed_after_replace) -> $(r2.closed)/$total iters=$(r2.iters)$(haskey(r2,:err) ? "  err=$(r2.err)" : "")")
check("closed_set monotone across replace (no regress)", r2.closed >= closed_after_replace)
check("no RVO/identity assert on the faulted robot", r2.status != :asserted)
check("PROJECT COMPLETE (core done-gate)", r2.status == :complete)

# --- [5] stall diagnosis: dump the active frontier + faulted/spare involvement ----
_rid(n) = (try entity(n).id catch; nothing end)
function diagnose_stall(env, fid, sid)
    sched = env.sched
    println("    faulted=R$(fid===nothing ? "?" : fid.id)  spare=R$(sid===nothing ? "?" : sid.id)")
    nactive = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        rid = _rid(n)
        tag = rid === nothing ? "" : (rid == fid ? "  <== FAULTED" : (rid == sid ? "  <== SPARE" : "  (R$(rid.id))"))
        nactive += 1
        nactive <= 40 && println("      active: $(typeof(n).name.name)$(tag)")
    end
    println("    total active frontier nodes: $nactive")
    isbound(n, who) = (n isa CB.RobotGo) && (_rid(n) == who)
    fleft = fid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), fid)
    end
    sleft = sid === nothing ? 0 : count(Graphs.vertices(sched)) do v
        !(v in env.cache.closed_set) && isbound(CB.get_node_from_id(sched, CB.get_vtx_id(sched, v)), sid)
    end
    println("    faulted robot still bound to $fleft non-closed RobotGo(s) (dead frontier fg expected = 1)")
    println("    spare   robot still bound to $sleft non-closed RobotGo(s) (its remaining adopted work)")
    # classify the stuck frontier by node type
    types = Dict{Symbol,Int}()
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        t = typeof(n).name.name
        types[t] = get(types, t, 0) + 1
    end
    println("    active frontier by type: $types")
    # did the spare actually move out of its pool toward its work?
    if sid !== nothing
        spos = CB._robot_position_2d(env, sid)
        pc = get(CB.spare_pool_centers(), :east, nothing)
        for (k, c) in CB.spare_pool_centers()   # find the pool the spare came from (nearest center)
            pc === nothing && (pc = c)
        end
        # nearest goal among the spare's active RobotGo nodes
        sgoal_d = Inf
        for v in env.cache.active_set
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == sid) || continue
            g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(n)).translation)) catch; continue end
            sgoal_d = min(sgoal_d, norm(spos .- g))
        end
        println("    spare pos=$(round.(spos;digits=2)); dist to its nearest active goal=$(round(sgoal_d;digits=2)) (robot_r=$(round(CB.default_robot_radius();digits=3)))")
    end
end
# FTU formation diagnosis: for every active RobotGo whose next node is a
# FormTransportUnit, dump the team's per-member capture status (route_planning.jl:480
# requires ALL members in position simultaneously). Pinpoints who is blocking.
function diagnose_ftu(env)
    sched = env.sched; st = env.scene_tree
    fr = CB.faulted_robots()
    shown = 0
    for v in env.cache.active_set
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.RobotGo || continue
        outs = Graphs.outneighbors(sched, v); isempty(outs) && continue
        nxt = CB.get_node_from_id(sched, CB.get_vtx_id(sched, outs[1]))
        nxt isa CB.FormTransportUnit || continue
        feeder = _rid(n)
        atgoal = CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                               CB.global_transform(CB.goal_config(n)))
        # inneighbor readiness (route_planning.jl:474-478)
        inn = Graphs.inneighbors(sched, outs[1])
        inn_ready = all(vp -> (vp in env.cache.active_set) || (vp in env.cache.closed_set), inn)
        tu = CB.entity(nxt); team = CB.robot_team(tu)
        shown += 1
        shown > 6 && (println("    ... (more FTUs)"); break)
        ftuv = outs[1]
        dep = CB._adopted_task_deposit(env, v)
        # --- STEP 0: slot goal_config(SCHEDULE) vs tu's expected capture slot(SCENE) drift ---
        # feeder_at_goal targets global_transform(goal_config(slot)); in_capture targets
        # global_transform(tu) ∘ child_transform(tu, rid) (hierarchical_geom_essentials.jl:1032-33).
        # If these disagree the spare can satisfy in_capture but never feeder_at_goal -> FTU never fires.
        drift = NaN
        if feeder !== nothing
            try
                slot_goal = CB.global_transform(CB.goal_config(n))
                ct        = CB.child_transform(tu, feeder)
                expected  = CB.global_transform(tu) ∘ ct
                drift = norm(Vector{Float64}(slot_goal.translation[1:2]) .-
                             Vector{Float64}(expected.translation[1:2]))
            catch e
                drift = -1.0
            end
        end
        println("    [slot v=$v -> FTU v=$ftuv -> deposit v=$(dep)] fed by R$(feeder===nothing ? "?" : feeder.id) (feeder_at_goal=$atgoal, inneighbors_ready=$inn_ready, GOAL_DRIFT=$(round(drift;digits=3))), team=$(length(team)):")
        for (mid, _) in team
            rn = try CB.get_node(st, mid) catch; nothing end
            rn === nothing && (println("      member R$(mid.id): <no scene node>"); continue)
            incap = CB.is_within_capture_distance(tu, rn)
            ftag = haskey(fr, mid) ? " [FAULTED]" : (mid == spare ? " [SPARE]" : "")
            # for a member NOT in position, locate it: pos, whether it's a ROOT (drivable) or
            # captured elsewhere, its active node type, and dist to its nearest active goal.
            extra = ""
            if !incap
                pos = try Vector{Float64}(CB.project_to_2d(CB.global_transform(rn).translation)) catch; [NaN,NaN] end
                isroot = try CB.has_parent(rn, rn) catch; "?" end
                # find this member's active node(s)
                mact = Int[]; mgoal_d = Inf
                for vv in env.cache.active_set
                    nn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vv))
                    (_rid(nn) == mid) || continue
                    push!(mact, vv)
                    g = try Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation)) catch; continue end
                    mgoal_d = min(mgoal_d, norm(pos .- g))
                end
                acttypes = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vv))).name.name) for vv in mact], ",")
                extra = "  pos=$(round.(pos;digits=2)) root=$isroot active=[$acttypes] dist2goal=$(round(mgoal_d;digits=2))"
            end
            println("      member R$(mid.id): in_capture=$incap$ftag$extra")
        end
    end
    shown == 0 && println("    (no active RobotGo feeding a FormTransportUnit found)")
    # find any FTU with >1 spare feeder (the duplicate-feeder bug) and dump ALL its inneighbors
    println("    --- FTUs with duplicate spare feeders (the bug) ---")
    seen_ftu = Set{Int}()
    for v in Graphs.vertices(sched)
        n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        n isa CB.FormTransportUnit || continue
        v in seen_ftu && continue
        ins = Graphs.inneighbors(sched, v)
        sp_feeders = filter(vp -> begin
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            pn isa CB.RobotGo && _rid(pn) == spare
        end, ins)
        length(sp_feeders) >= 2 || continue
        push!(seen_ftu, v)
        println("    FTU v=$v has $(length(sp_feeders)) spare feeders; ALL inneighbors:")
        for vp in ins
            pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
            rid = _rid(pn)
            cl = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
            ppreds = join([string(typeof(CB.get_node_from_id(sched,CB.get_vtx_id(sched,vpp))).name.name) for vpp in Graphs.inneighbors(sched,vp)], ",")
            println("      in v=$vp $(typeof(pn).name.name) R$(rid===nothing ? "?" : rid.id) [$cl] <-preds[$ppreds]")
        end
    end
end
if r2.status != :complete
    println("\n[5] STALL DIAGNOSIS (active frontier at stall)")
    diagnose_stall(env, faulted, spare)
    println("\n[6] FTU FORMATION DIAGNOSIS (who blocks each pending transport team)")
    diagnose_ftu(env)
    println("\n[7] SPARE THREAD STRUCTURE (is the adopted work a single sequential chain?)")
    let sched = env.sched
        nactive_spare = 0
        for v in Graphs.vertices(sched)
            n = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
            (n isa CB.RobotGo && _rid(n) == spare) || continue
            v in env.cache.closed_set && continue
            preds = Graphs.inneighbors(sched, v)
            predinfo = join([begin
                pn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vp))
                pc = vp in env.cache.closed_set ? "closed" : (vp in env.cache.active_set ? "active" : "future")
                "$(typeof(pn).name.name)[$pc]"
            end for vp in preds], ",")
            isact = v in env.cache.active_set
            isact && (nactive_spare += 1)
            outs = Graphs.outneighbors(sched, v)
            sucinfo = join([begin
                sn = CB.get_node_from_id(sched, CB.get_vtx_id(sched, vs))
                "$(typeof(sn).name.name)"
            end for vs in outs], ",")
            isterm = isempty(outs)
            t0 = try round(Float64(CB.get_t0(sched, v)); digits=2) catch; "?" end
            atg = try CB.is_within_capture_distance(CB.global_transform(CB.entity(n)),
                                                    CB.global_transform(CB.goal_config(n))) catch; "?" end
            println("    spare RobotGo v=$v active=$isact t0=$t0 at_goal=$atg terminal=$isterm  preds=[$predinfo]  succs=[$sucinfo]")
        end
        println("    => spare has $nactive_spare CONCURRENTLY ACTIVE RobotGo(s) (should be 1 for a sequential thread)")
    end
end

CB.clear_spare_pools!(); CB.clear_faulted_robots!(); CB.clear_restriction_zones!()
println("\n==== A4 spare_replace_test: $(npass[]) passed, $(nfail[]) failed ====")
println(nfail[] == 0 ? "ALL GREEN (spare 1:1 hand-off completes the build)" :
        "SOME FAILED (see above; likely R1 frontier-graft / R3 faulted-driving -- diagnose)")
