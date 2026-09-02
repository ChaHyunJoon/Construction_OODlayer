# tools/probes/probe_why_argmin_wont_move.jl
#   julia +lts --project=. tools/probes/probe_why_argmin_wont_move.jl
#
# `probe_scoped_release.jl` 이 잰 것: 좁힌 release 는 0.2s 에 OPTIMAL 로 수렴한다(벽 해결).
# 그러나 **대상 에이전트가 잃은 일 = 0** 이고, 재가격 팔과 음성 대조가 `n_reassigned` 까지
# 완전히 같았다 ⟹ 재가격이 argmin 을 못 움직인다.
#
# 원인 후보 둘을 **가른다**(추론 금지, 이 레포의 규약):
#   (가) 편향이 약하다 — `_PAYLOAD_REF = 12.8` 은 tractor.mpd 의 천장이고 이 판은 더 가볍다.
#   (나) 구조적으로 불가능하다 — A 의 슬롯을 받을 후보 출발점이 A 뿐이다.
#
# 재는 것 넷:
#   ① 구조: A 의 풀린 슬롯마다 후보 간선 출발점의 **소유자 분포**. non-A 가 0 이면 (나)다.
#   ② 화물: 이 판의 실제 payload 질량 분포 vs `_PAYLOAD_REF`. (가) 의 크기를 준다.
#   ③ 도달: 같은 후보 집합에서 base vs hot 비용이 **다르기는 한가**(S2 의 `LAST_EDGE_COSTS` 관용구).
#   ④ 스윕: light_bias ∈ {0, 0.5, 2, 4, 32} 에서 A 가 일을 잃는가.
#
# 🔴 삼상 규약 · soft scope · 한 프로세스.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

function release_scoped!(env, inv; agent)
    sched = env.sched; G = CB.get_graph(sched)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    removed = Tuple{Int,Int}[]
    for e in collect(Graphs.edges(G))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        own = CB._edge_owner_id(sched, v)
        (own !== nothing && string(own) == agent) || continue
        Graphs.rem_edge!(G, v, v2); push!(removed, (v, v2))
    end
    for (_, v2) in removed; CB.reset_slot_to_invalid!(env, v2); end
    return removed
end

function pending_owner_tally(env)
    sched = env.sched; G = CB.get_graph(sched); inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{String,Int}()
    for e in Graphs.edges(G)
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
        t[string(o)] = get(t, string(o), 0) + 1
    end
    return t
end

"formulate 하고 (후보비용dict, 스케줄) 을 준다. 센티넬로 실제로 돌았는지 확인."
function formulate_on(env, inv)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && return (nothing, milp)
    return (copy(CB.LAST_EDGE_COSTS[]), milp)
end

fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)
nreass(b, a) = count(v -> get(b, v, -1) != get(a, v, -1), union(keys(b), keys(a)))

function analyse(base, agent, label)
    println("\n", "="^80); println(label, "   대상 = ", agent); println("="^80)

    # ---- ① 구조: 풀린 슬롯을 누가 받을 수 있나 -----------------------------------------
    e1 = fork(base); inv1 = CB.build_invariant(e1)
    rem = release_scoped!(e1, inv1; agent = agent)
    slots = Set(v2 for (_, v2) in rem)
    ec, _ = formulate_on(e1, inv1)
    if ec === nothing
        println("① 못 쟀다 — formulate 가 안 돌았다"); return nothing
    end
    per_slot = Dict{Int,Dict{String,Int}}()
    for (v, v2) in keys(ec)
        v2 in slots || continue
        o = CB._edge_owner_id(e1.sched, v)
        key = o === nothing ? "(invalid/unowned)" : string(o)
        d = get!(per_slot, v2, Dict{String,Int}())
        d[key] = get(d, key, 0) + 1
    end
    nonA_slots = 0
    for (v2, d) in per_slot
        any(k -> k != agent && k != "(invalid/unowned)", keys(d)) && (nonA_slots += 1)
    end
    println("① 구조 — 풀린 슬롯 ", length(slots), "개, 그중 후보가 잡힌 슬롯 ", length(per_slot), "개")
    println("   🔴 non-A 출발점을 가진 슬롯 = ", nonA_slots, " / ", length(per_slot))
    for (v2, d) in sort(collect(per_slot), by = kv -> kv[1])
        println("      slot ", v2, " ← ", sort(collect(d), by = kv -> -kv[2]))
    end

    # ---- ② 화물 질량 분포 ---------------------------------------------------------------
    # 🔴 2026-09-01 수정: 앞 판에서 `p` 에 `nothing` 을 넘겨 `p.payload_density` 에서 던졌고
    #    전부 "못 쟀다"로 떨어졌다 — 세계의 사실이 아니라 프로브의 버그였다.
    bp = CB.BATTERY_FLEET[] === nothing ? CB.BatteryParams() : CB.BATTERY_FLEET[].params
    ms = Float64[]
    for v2 in slots
        for v in Graphs.outneighbors(e1.sched, v2)
            node = CB.get_node_from_id(e1.sched, CB.get_vtx_id(e1.sched, v))
            inner = try node.node catch; node end
            m = try CB._payload_mass_measured(e1, inner, bp) catch; nothing end
            m === nothing || push!(ms, Float64(m))
        end
    end
    println("② 화물 — _PAYLOAD_REF = ", CB._PAYLOAD_REF[],
            "   측정된 payload 질량 ", isempty(ms) ? "없음(못 쟀다)" :
            string("n=", length(ms), " min=", round(minimum(ms), digits=3),
                   " max=", round(maximum(ms), digits=3),
                   "  ⟹ light_bias=1 일 때 최대 배율 = ",
                   round(1 + maximum(ms)/CB._PAYLOAD_REF[], digits=4)))

    # ---- ③ 도달: 비용이 다르기는 한가 ---------------------------------------------------
    e2 = fork(base); inv2 = CB.build_invariant(e2); release_scoped!(e2, inv2; agent = agent)
    CB.clear_payload_bias!()
    base_ec, _ = formulate_on(e2, inv2)
    e3 = fork(base); inv3 = CB.build_invariant(e3); release_scoped!(e3, inv3; agent = agent)
    CB.clear_payload_bias!()
    st = CB.reprice_agent_by_payload!(e3; agent = agent, light_bias = 1.0).status
    hot_ec, _ = formulate_on(e3, inv3)
    CB.clear_payload_bias!()
    if base_ec === nothing || hot_ec === nothing
        println("③ 못 쟀다")
    else
        common = intersect(keys(base_ec), keys(hot_ec))
        diff = [k for k in common if base_ec[k] != hot_ec[k]]
        ratios = [hot_ec[k]/base_ec[k] for k in diff if base_ec[k] != 0.0]
        println("③ 도달 — reprice=", st, "  공통 후보 ", length(common),
                "  값이 다른 간선 ", length(diff),
                isempty(ratios) ? "  (배율 못 쟀다)" :
                string("  배율 min=", round(minimum(ratios), digits=5),
                       " max=", round(maximum(ratios), digits=5)))
        nz = count(k -> base_ec[k] == 0.0, common)
        println("   ⚠️ 비용이 0.0 인 후보 간선 = ", nz, " / ", length(common),
                " (0 × 배율 = 0 — 재가격이 구조적으로 못 건드리는 간선)")
    end

    # ---- ④ 스윕 -------------------------------------------------------------------------
    println("④ 스윕 — light_bias 별 (A가 잃은 일 / n_reassigned / term)")
    for b in (0.0, 0.5, 2.0, 4.0, 32.0)
        e = fork(base); before = CB.simstate_of(e).g.binding
        inv = CB.build_invariant(e); release_scoped!(e, inv; agent = agent)
        CB.clear_payload_bias!()
        b > 0 && CB.reprice_agent_by_payload!(e; agent = agent, light_bias = b)
        _, milp = formulate_on(e, inv)
        CB.set_time_limit_sec(milp, 60.0); CB.optimize!(milp)
        ts = CB.termination_status(milp)
        if CB.primal_status(milp) != CB.MOI.FEASIBLE_POINT
            println("   bias=", b, "  incumbent 없음  term=", ts); continue
        end
        CB.commit_respec!(e, milp, CB.RespecProposal(CB.ConstraintSpec[], "sweep", "probe"); resume = true)
        after = CB.simstate_of(e).g.binding
        lost = count(v -> string(get(before, v, -1)) == agent && string(get(after, v, -1)) != agent,
                     collect(keys(before)))
        println("   bias=", rpad(string(b), 6), " A가 잃은 일=", rpad(string(lost), 4),
                " n_reass=", rpad(string(nreass(before, after)), 5), " term=", ts)
        CB.clear_payload_bias!()
    end
    return nothing
end

function main()
    boardf  = length(ARGS) >= 1 ? ARGS[1] : "colored_8x8.ldr"
    nrobots = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : (boardf == "tractor.mpd" ? 10 : 6)
    cps     = length(ARGS) >= 3 ? parse.(Int, split(ARGS[3], ",")) : [62, 220]
    println("BOARD=", boardf, " robots=", nrobots, " checkpoints=", cps)
    base = CB.run_lego_demo(; ldraw_file = boardf, project_name = "whyargmin",
                              num_robots = nrobots, assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7); CB.init_objective_weights!()
    println("AUTO_EFFICIENCY_KAPPA[] = ", CB.AUTO_EFFICIENCY_KAPPA[],
            "   (nothing 이면 목적식이 edge_costs 를 통째로 버린다)")
    saved = copy(CB.INVALID_ID_COUNTERS)
    for target in cps
        k = 0
        while length(CB.simstate_of(base).prog.closed) < target && k < 4000
            CB.step_environment!(base); CB.update_planning_cache!(base, 0.0); k += 1; CB.set_sim_step!(k)
        end
        t = pending_owner_tally(base)
        isempty(t) && (println("closed=", target, ": 뗄 간선 0 — 창이 닫혔다"); continue)
        agent = sort(collect(t), by = kv -> -kv[2])[1][1]
        println("\n\n### closed = ", length(CB.simstate_of(base).prog.closed),
                "   미래 배정 간선 소유자 분포 = ", sort(collect(t), by = kv -> -kv[2]))
        analyse(base, agent, "closed=$(length(CB.simstate_of(base).prog.closed))")
    end
    merge!(CB.INVALID_ID_COUNTERS, saved)
end

main()
