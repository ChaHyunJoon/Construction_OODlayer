# tools/probes/probe_kappa_alive.jl
# 🔴 모든 집계는 함수 안에서 한다(top-level for 의 카운터는 soft scope 로 조용한 0 이 된다).
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots

function main()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2kappa",
                             num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    println("kappa BEFORE init = ", CB.AUTO_EFFICIENCY_KAPPA[])
    CB.init_objective_weights!()
    println("kappa AFTER  init = ", CB.AUTO_EFFICIENCY_KAPPA[])

    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))

    CB.LAST_AUTO_EFFICIENCY_W[] = 0.0
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sent)
    println("ran_formulate       = ", ran)
    println("n_candidate_edges   = ", ran ? length(CB.LAST_EDGE_COSTS[]) : -1)
    println("LAST_AUTO_EFFICIENCY_W = ", CB.LAST_AUTO_EFFICIENCY_W[])
    println("\n==== 판정 ====")
    println(CB.LAST_AUTO_EFFICIENCY_W[] > 0.0 ?
        "✅ κ 가 살아 있다 — 에너지 항이 목적식에 들어간다. Task 1 로 간다." :
        "🔴 κ 가 죽었다 — 목적식이 순수 makespan 이다. **여기서 멈추고 보고한다.**")
end

main()
