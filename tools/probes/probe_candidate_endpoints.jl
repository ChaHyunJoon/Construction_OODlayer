# ============================================================================
# 후보 간선의 **양끝 노드 종류와 화물 질량 도달성**.
#
# 묻는 것: 2026-08-30 계획서의 `payload_edge_multiplier`(= `_payload_mass(env, node_v, …)`)가
# 후보 간선에서 1.0 이 아닌 값을 낼 수 있는가. `_payload_mass_measured` 는
# `TransportUnitGo|DepositCargo|FormTransportUnit` 이 아니면 던진다.
#
# 🔴 모든 집계는 **함수 안**에서 한다. Julia 스크립트의 top-level `for` 안에서 `n += 1` 은
#    soft scope 때문에 전역이 아니라 지역에 쌓여 **조용한 0** 을 만든다(이 파일의 1판이
#    실제로 그 함정에 빠졌다 — Dict 변형은 멀쩡했고 카운터만 0 이었다).
# ============================================================================
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # BatteryParams / _payload_mass_measured

function main()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2endpoints",
                             num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))

    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    CB.LAST_EDGE_COSTS[] === sent && (println("🔴 formulate 가 안 돌았다"); return)
    ec = CB.LAST_EDGE_COSTS[]
    println("n_candidate_edges = ", length(ec))

    p = CB.BatteryParams()
    node(v) = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
    mass(n) = try CB._payload_mass_measured(shim, n, p) catch; nothing end

    src_t = Dict{Symbol,Int}(); dst_t = Dict{Symbol,Int}(); hop_t = Dict{Symbol,Int}()
    n_src = 0; n_dst = 0; n_hop = 0; n_hop_exists = 0
    hop_ms = Float64[]
    for (v, v2) in keys(ec)
        nv, nv2 = node(v), node(v2)
        src_t[typeof(nv).name.name]  = get(src_t, typeof(nv).name.name, 0) + 1
        dst_t[typeof(nv2).name.name] = get(dst_t, typeof(nv2).name.name, 0) + 1
        mass(nv)  === nothing || (n_src += 1)
        mass(nv2) === nothing || (n_dst += 1)
        outs = Graphs.outneighbors(sched, v2)
        isempty(outs) && continue
        n_hop_exists += 1
        sn = node(outs[1])
        hop_t[typeof(sn).name.name] = get(hop_t, typeof(sn).name.name, 0) + 1
        m = mass(sn)
        m === nothing || (n_hop += 1; push!(hop_ms, m))
    end

    println("\nSOURCE(v)  노드 종류 = ", src_t)
    println("TARGET(v2) 노드 종류 = ", dst_t)
    println("v2 의 후속 노드 종류  = ", hop_t, "   (후속이 있는 간선 ", n_hop_exists, ")")
    println("\n화물 질량을 잴 수 있는 간선 수")
    println("  v  쪽  = ", n_src, " / ", length(ec), "   ◀ 계획서가 쓰는 쪽")
    println("  v2 쪽  = ", n_dst, " / ", length(ec))
    println("  v2 한 홉 아래 = ", n_hop, " / ", length(ec))
    if !isempty(hop_ms)
        println("  그 질량 = ", minimum(hop_ms), " … ", maximum(hop_ms),
                "  평균 ", sum(hop_ms)/length(hop_ms),
                "  서로 다른 값 ", length(unique(round.(hop_ms, digits=6))), "종")
    end
    # ---- 후보 간선의 v 에서 로봇 신원을 읽을 수 있는가 ------------------------------------
    # "이 로봇만 비싸게" 가 성립하려면 `_edge_owner_id(sched, v)` 가 **유효한** 로봇 id 여야 한다.
    # release 가 슬롯을 무효 id 로 되돌리므로(reset_slot_to_invalid!), 어느 쪽이 유효한지 잰다.
    owners_v = Dict{Any,Int}(); owners_v2 = Dict{Any,Int}()
    for (v, v2) in keys(ec)
        idv  = CB._edge_owner_id(sched, v)
        idv2 = CB._edge_owner_id(sched, v2)
        owners_v[idv]   = get(owners_v, idv, 0) + 1
        owners_v2[idv2] = get(owners_v2, idv2, 0) + 1
    end
    valid(d) = count(kv -> kv[1] !== nothing && CB.valid_id(kv[1]), collect(d))
    println("\nv  의 서로 다른 owner id = ", length(owners_v),
            "  (그중 유효 id ", valid(owners_v), ")")
    println("v2 의 서로 다른 owner id = ", length(owners_v2),
            "  (그중 유효 id ", valid(owners_v2), ")")
    println("v  owner 샘플 = ", collect(Iterators.take(sort(collect(owners_v), by = x -> -x[2]), 4)))
    println("v2 owner 샘플 = ", collect(Iterators.take(sort(collect(owners_v2), by = x -> -x[2]), 4)))

    println("\n==== 판정 ====")
    println(n_src == 0 ? "🔴 v 쪽 질량은 어느 후보 간선에서도 못 잰다 ⟹ 계획서의 재가격은 후보 간선에서 항상 1.0 = 무동작."
                       : "v 쪽 질량이 잡히는 간선이 있다 — 계획서 설계가 후보 간선에 닿는다.")
    println(n_hop > 0 ? "✅ v2 한 홉 아래에서는 화물을 잰다 ⟹ 재가격은 그 한 홉을 봐야 한다."
                      : "🔴 한 홉 아래에서도 화물이 없다 ⟹ 후보 간선에 payload 축이 없다.")
end

main()
