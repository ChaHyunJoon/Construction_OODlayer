# tools/probes/probe_kappa_renormalization.jl
#   julia +lts --project=. tools/probes/probe_kappa_renormalization.jl [board] [nrobots] [cp]
#
# 🔴 미확정 가설을 확정한다(`probe_can_a_be_displaced.jl` 이 남긴 것).
#   "재가격이 argmin 을 못 움직이는 이유는 `w_eff = κ·speed_scale/eff_scale` 재정규화가
#    편향을 자기상쇄하기 때문이다."
#
# 산술로 가른다. 두 배정을 손에 넣는다(둘 다 같은 그래프 위, 같은 후보 집합):
#   S_A = 그냥 풀었을 때 (A 가 자기 슬롯을 회수)
#   S_B = A 의 재탈환을 `Xa ≤ 0` 으로 막았을 때
# `probe_can_a_be_displaced.jl` 이 S_B 가 실행 가능하고 목적값 대가가 +0.06% 임을 이미 쟀다.
#
# bias b 마다:
#   Δspeed        = S_B 를 고르는 **makespan 쪽 대가** (b 와 무관 — 배정의 성질이다)
#   Δenergy(b)    = w_eff(b) · (eff_b(S_A) − eff_b(S_B))  = S_B 를 고를 **에너지 쪽 보상**
#   budget(b)     = κ · speed_scale  = 에너지항 전체가 쓸 수 있는 최대 액수
# 판정:
#   · Δenergy(b) 가 b 와 함께 **안 큰다** ⟹ 재정규화 자기상쇄 확정.
#   · 크는데도 Δspeed 에 못 미친다 ⟹ 상쇄가 아니라 순수 규모 부족.
#
# 🔴 두 배정을 **같은** 비용 dict 으로 평가한다 — 이것이 이 프로브의 전부다.
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
const TL = 60.0

function release_scoped!(env, inv; agent)
    sched = env.sched; G = CB.get_graph(sched)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    removed = Tuple{Int,Int}[]
    for e in collect(Graphs.edges(G))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v)
        (o !== nothing && string(o) == agent) || continue
        Graphs.rem_edge!(G, v, v2); push!(removed, (v, v2))
    end
    for (_, v2) in removed; CB.reset_slot_to_invalid!(env, v2); end
    return removed
end

function pending_tally(env)
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
fork(e) = (x = deepcopy(e); CB.rvo_rebuild!(x); x)

"좁힌 release 후 formulate. (env, 비용dict, milp, 풀린슬롯, w_eff) 반환. bias>0 이면 재가격 설치."
function setup(base; agent, bias)
    env = fork(base); inv = CB.build_invariant(env)
    rem = release_scoped!(env, inv; agent = agent)
    CB.clear_payload_bias!()
    bias > 0 && CB.reprice_agent_by_payload!(env; agent = agent, light_bias = bias)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && error("formulate 안 돎")
    ec = copy(CB.LAST_EDGE_COSTS[])
    weff = CB.LAST_AUTO_EFFICIENCY_W[]      # 🔴 정식화가 실제로 쓴 값. 재계산하지 않는다.
    CB.clear_payload_bias!()
    return (env = env, ec = ec, milp = milp, slots = Set(v2 for (_, v2) in rem), weff = weff)
end

"선택된 후보 간선 집합. `block=true` 면 A 의 재탈환을 막고 푼다."
function solve_edges(s; agent, block)
    Xa = s.milp.Xa
    if block
        for (v, v2) in keys(s.ec)
            v2 in s.slots || continue
            o = CB._edge_owner_id(s.env.sched, v)
            (o !== nothing && string(o) == agent) || continue
            JuMP.set_upper_bound(Xa[v, v2], 0.0)
        end
    end
    CB.set_time_limit_sec(s.milp, TL); CB.optimize!(s.milp)
    CB.primal_status(s.milp) != CB.MOI.FEASIBLE_POINT && return (nothing, nothing, CB.termination_status(s.milp))
    sel = Set(e for e in keys(s.ec) if JuMP.value(Xa[e[1], e[2]]) > 0.5)
    obj = JuMP.objective_value(s.milp.model)
    return (sel, obj, CB.termination_status(s.milp))
end

evalcost(ec, sel) = sum(get(ec, e, 0.0) for e in sel; init = 0.0)

function main()
    bd = length(ARGS) >= 1 ? ARGS[1] : "tractor.mpd"
    nr = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
    cp = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60
    base = CB.run_lego_demo(; ldraw_file = bd, project_name = "kapparen", num_robots = nr,
                              assignment_mode = :greedy, n_spare_per_pool = 2,
                              open_animation_at_end = false, save_animation = false,
                              write_results = false, return_env_before_sim = true,
                              rng = Random.MersenneTwister(1))
    CB.enable_battery!(base); CB.enable_hazard!(base; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(base).prog.closed) < cp && k < 6000
        CB.step_environment!(base); CB.update_planning_cache!(base, 0.0); k += 1; CB.set_sim_step!(k)
    end
    closed = length(CB.simstate_of(base).prog.closed)
    agent = sort(collect(pending_tally(base)), by = kv -> -kv[2])[1][1]
    println("BOARD=", bd, " closed=", closed, " A=", agent, " κ=", CB.AUTO_EFFICIENCY_KAPPA[])

    # ---- 두 배정을 **편향 없는** 모델에서 얻는다(배정은 이 둘로 고정) --------------------
    sa = setup(base; agent = agent, bias = 0.0)
    selA, objA, tA = solve_edges(sa; agent = agent, block = false)
    sb = setup(base; agent = agent, bias = 0.0)
    selB, objB, tB = solve_edges(sb; agent = agent, block = true)
    (selA === nothing || selB === nothing) && error("두 배정 중 하나를 못 얻었다: $tA / $tB")
    println("S_A(A 회수) obj=", round(objA, digits=6), " term=", tA,
            "   S_B(차단)  obj=", round(objB, digits=6), " term=", tB)
    println("선택 간선 |S_A|=", length(selA), " |S_B|=", length(selB),
            " 대칭차=", length(symdiff(selA, selB)))

    # bias=0 에서 에너지 몫을 빼서 makespan 쪽 대가를 얻는다.
    e0A = evalcost(sa.ec, selA); e0B = evalcost(sa.ec, selB)
    dspeed = (objB - sb.weff * e0B) - (objA - sa.weff * e0A)
    println("\nbias=0 에서:  w_eff=", round(sa.weff, digits=8),
            "  eff(S_A)=", round(e0A, digits=4), "  eff(S_B)=", round(e0B, digits=4))
    println("🔴 Δspeed (S_B 를 고르는 makespan 쪽 대가) = ", round(dspeed, digits=8),
            "   — b 와 무관한 배정의 성질이다")

    println("\n", rpad("bias",7), rpad("w_eff",14), rpad("eff_b(S_A)",13), rpad("eff_b(S_B)",13),
            rpad("Δenergy(b)",14), rpad("예산 κ·speed_scale",18), "차단이 이기나")
    for b in (0.0, 0.5, 1.0, 2.0, 4.0, 8.0, 32.0)
        s = setup(base; agent = agent, bias = b)
        eA = evalcost(s.ec, selA); eB = evalcost(s.ec, selB)
        den = s.weff * (eA - eB)                       # S_B 를 고를 에너지 쪽 보상
        budget = s.weff * sum(abs, values(s.ec))       # = κ·speed_scale (정의상)
        println(rpad(string(b), 7), rpad(string(round(s.weff, digits=8)), 14),
                rpad(string(round(eA, digits=4)), 13), rpad(string(round(eB, digits=4)), 13),
                rpad(string(round(den, digits=8)), 14), rpad(string(round(budget, digits=6)), 18),
                den > dspeed ? "🟢 YES" : "🔴 no")
    end
    println("\n판정 읽는 법: Δenergy(b) 가 b 와 함께 **안 크면** 재정규화 자기상쇄 확정.")
    println("             크는데도 Δspeed 에 못 미치면 상쇄가 아니라 순수 규모 부족이다.")
end
main()
