# tools/probes/probe_ban_vs_fault.jl
#   julia +lts --project=. tools/probes/probe_ban_vs_fault.jl [board] [nrobots] [checkpoint]
#
# 🔴 (b) 안이 여는 위험을 **재고 나서** 정한다.
#   금지를 모든 formulate 에 걸면 `fault_robot_and_reassign!` 에도 걸린다. 그 경로는 실패가
#   `engage_fallback!` = **라인 영구 정지**다(replan.jl:889-892, 푸는 production 호출자 0개).
#   ⟹ 선호(wear-leveling)가 빌드를 영구히 멈출 수 있는가?
#
# 팔 (전부 같은 픽스처·같은 체크포인트·같은 상한):
#   [C]  대조 — 로봇 R 고장, 금지 없음.  🔴 여기가 feasible 이 아니면 픽스처가 공허하다.
#   [B1] A 하나에 금지(상위 N) + R 고장
#   [B2] 두 로봇에 금지 + R 고장
#   [B3] 세 로봇에 금지 + R 고장      ← 누적. 금지는 각자의 SwapBattery 까지 사니 현실적 최악.
#
# 금지의 표현은 **L2-a 문법 그대로**다: LinearConstraint([(1.0, VarRef(:xa,u,v))], :eq, 0.0).
# 고장은 production 과 같은 모양: 먼저 release_pending_assignments!(faulted=R), 그다음
# ForbidAgent(R) 를 제안에 실어 formulate. (verify 의 실행가능성 단계와 같은 계산이다.)
#
# 🔴 삼상 규약 · soft scope · 한 프로세스 · INVALID_ID_COUNTERS 복원.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
const TL = 60.0

fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)

"미래 배정 간선을 가진 로봇들 (id => 개수), 많은 순."
function pending_tally(env)
    sched = env.sched; G = CB.get_graph(sched); inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{Any,Int}()
    for e in Graphs.edges(G)
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
        t[o] = get(t, o, 0) + 1
    end
    return sort(collect(t), by = kv -> -kv[2])
end

"슬롯 v2 한 홉 뒤 화물의 **1대당 부담** m_payload/팀크기. 못 재면 nothing."
function burden(env, v2, p)
    for v in Graphs.outneighbors(env.sched, v2)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        inner = try node.node catch; node end
        m = try CB._payload_mass_measured(env, inner, p) catch; continue end
        t = try length(CB.robot_team(inner)) catch; continue end
        t > 0 && return m / t
    end
    return nothing
end
"""
A 가 소유한 후보 간선 중, **1대당 부담 상위 N 슬롯**으로 가는 것들을 고른다.

🔴 2026-09-01 정정: 앞 판은 `is_agent_frontier` 로 골랐는데 **후보 간선의 출발점이 아니었다**
   (실측: frontier 정점 1개, 그중 후보 출발점 0개) → 금지가 0개 만들어져 측정이 공허했다.
   후보 간선의 소유자는 `_edge_owner_id` 로 나온다(실측: 전체 release 후에도 A=144개).

🔴 그리고 금지를 `LinearConstraint` 로 **얼려 두지 않는다**. `Xa` 는 formulate 안에서만
   존재하고 그래프는 formulate 사이에 바뀐다 — 얼린 목록은 나중에 문법 오류가 되고, 고장
   경로에서 그것은 `engage_fallback!`(라인 영구 정지)이다. 여기서는 formulate 뒤에 `Xa`
   상계를 0 으로 눌러 **컴파일러 없이 같은 효과**를 낸다(probe_can_a_be_displaced.jl 의 기법).
"""
function ban_edges(env, agent_str, n::Int, cand, p)
    sched = env.sched
    slots = Dict{Int,Float64}()
    owned = Tuple{Int,Int}[]
    for (u, v2) in cand
        o = CB._edge_owner_id(sched, u)
        (o !== nothing && string(o) == agent_str) || continue
        push!(owned, (u, v2))
        b = burden(env, v2, p); b === nothing && continue
        slots[v2] = max(get(slots, v2, -Inf), b)
    end
    isempty(slots) && return (Tuple{Int,Int}[], 0, length(owned))
    top = Set(k for (k, _) in first(sort(collect(slots), by = kv -> -kv[2]), n))
    return ([(u, v2) for (u, v2) in owned if v2 in top], length(top), length(owned))
end

"formulate 한 번 — 후보 간선 집합을 얻는다(센티넬로 실제로 돌았는지 확인)."
function candidates(env, inv; proposal = nothing)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF,
                             extra_constraints = proposal)
    CB.LAST_EDGE_COSTS[] === sent && return (nothing, milp)
    return (copy(CB.LAST_EDGE_COSTS[]), milp)
end

"한 팔: R 고장 + (선택) 금지들. production 순서를 그대로 따른다."
function arm(base, R, ban_agents, n, p)
    env = fork(base); inv = CB.build_invariant(env)
    CB.release_pending_assignments!(env, inv; faulted = R)      # production 이 먼저 하는 것
    prop = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidAgent(R, 0.0)],
                             "probe: fault", "probe")
    cand, milp = candidates(env, inv; proposal = prop)
    cand === nothing && return (status = :no_formulate,)
    Xa = milp.Xa; nban = 0; nslots = 0; nowned = 0
    for a in ban_agents
        edges, ns, no = ban_edges(env, string(a), n, keys(cand), p)
        nslots += ns; nowned += no
        for (u, v2) in edges
            JuMP.set_upper_bound(Xa[u, v2], 0.0); nban += 1
        end
    end
    CB.set_time_limit_sec(milp, TL)
    wall = @elapsed CB.optimize!(milp)
    ps = CB.primal_status(milp); ts = CB.termination_status(milp)
    obj = try JuMP.objective_value(milp.model) catch; nothing end
    return (status = ps == CB.MOI.FEASIBLE_POINT ? :feasible : :NOT_feasible,
            ncand = length(cand), nban = nban, nslots = nslots, nowned = nowned,
            tstat = ts, pstat = ps, obj = obj, wall = wall)
end

function main()
    bd = length(ARGS) >= 1 ? ARGS[1] : "tractor.mpd"
    nr = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
    cp = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60
    base = CB.run_lego_demo(; ldraw_file = bd, project_name = "banfault", num_robots = nr,
                              assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7); CB.init_objective_weights!()
    p = CB.BATTERY_FLEET[].params
    k = 0
    while length(CB.simstate_of(base).prog.closed) < cp && k < 6000
        CB.step_environment!(base); CB.update_planning_cache!(base, 0.0); k += 1; CB.set_sim_step!(k)
    end
    closed = length(CB.simstate_of(base).prog.closed)
    tally = pending_tally(base)
    length(tally) < 4 && error("미래 배정을 가진 로봇이 4대 미만 — 이 실험이 공허하다")
    R = tally[end][1]                       # 고장낼 로봇 = 미래 일이 가장 적은 쪽
    bans = [tally[i][1] for i in 1:3]       # 금지 대상 = 가장 바쁜 셋
    println("BOARD=", bd, " closed=", closed, " / ", Graphs.nv(base.sched))
    println("고장 R = ", repr(R), "\n금지 후보 = ", [repr(b) for b in bans])
    saved = copy(CB.INVALID_ID_COUNTERS)
    for n in (1, 3)
        println("\n", "="^74, "\nN = ", n, " (에이전트당 금지 슬롯 수)")
        for (tag, ags) in (("C  대조", Any[]), ("B1 1대", bans[1:1]),
                           ("B2 2대", bans[1:2]), ("B3 3대", bans[1:3]))
            r = arm(base, R, ags, n, p)
            if r.status === :no_formulate
                println("  [", tag, "] formulate 안 돎 — 못 쟀다"); continue
            elseif r.status === :compile_failed
                println("  [", tag, "] 🔴 컴파일 실패: ", r.detail); continue
            end
            println("  [", tag, "] ", r.status === :feasible ? "🟢 feasible" : "🔴 NOT feasible",
                    "  후보=", r.ncand, " 금지행=", r.nban, " 금지슬롯=", r.nslots, " (A소유간선=", r.nowned, ")",
                    "  term=", r.tstat, " primal=", r.pstat,
                    "  obj=", r.obj === nothing ? "nothing" : round(r.obj, digits=4),
                    " wall=", round(r.wall, digits=2), "s")
        end
    end
    merge!(CB.INVALID_ID_COUNTERS, saved)
    println("\n🔴 [C] 가 feasible 이 아니면 나머지 줄은 아무 뜻이 없다(픽스처가 공허).")
end
main()
