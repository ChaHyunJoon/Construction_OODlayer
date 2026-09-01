# ============================================================================
# ③ 후속 — 후보 쌍이 **어느 조건에서** 0 이 되는가.
# formulate_milp 의 Big-M 루프와 같은 순서로 단계별 생존 수를 센다. 순수(solve 없음).
#   A: 조건① outdegree(v) < n_eligible_successors[v]                  (= S1 상계)
#   B: A 를 통과한 v 에 대해 non_upstream_vertices[v] 의 쌍 수(원시 쌍)
#   C: + 조건② indegree(v2) < n_eligible_predecessors[v2]
#   D: + v 의 missing_successors 템플릿이 typeof(node2) 와 매치
#   E: + v2 의 missing_predecessors 템플릿이 typeof(node) 와 매치
#   F: + val > 0 && val2 > 0                                          (= n_candidate_edges)
# ============================================================================
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots

function dissect(ldraw, nrobots)
    println("\n=== board=", ldraw, " robots=", nrobots, " ===")
    env = CB.run_lego_demo(; ldraw_file = ldraw, project_name = "s2dissect",
                             num_robots = nrobots, assignment_mode = :greedy,
                             n_spare_per_pool = 2, open_animation_at_end = false,
                             save_animation = false, write_results = false,
                             return_env_before_sim = true, rng = Random.MersenneTwister(1))
    sched = env.sched
    ms, mp, nes, nep, nrs, nrp, uv, nuv = CB.preprocess_project_schedule(sched)
    A = B = C = D = E = F = 0
    a_vtxs = Int[]
    for v in Graphs.vertices(sched)
        Graphs.outdegree(sched, v) < nes[v] || continue
        A += 1; push!(a_vtxs, v)
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        for v2 in nuv[v]
            B += 1
            Graphs.indegree(sched, v2) < nep[v2] || continue
            C += 1
            node2 = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v2))
            hitD = false; hitE = false; hitF = false
            for (template, val) in ms[v]
                CB.matches_template(template, typeof(node2)) || continue
                hitD = true
                for (template2, val2) in mp[v2]
                    CB.matches_template(template2, typeof(node)) || continue
                    hitE = true
                    if val > 0 && val2 > 0
                        hitF = true; break
                    end
                end
                hitF && break
            end
            D += hitD; E += hitE; F += hitF
        end
    end
    println("A 조건①  통과 정점        = ", A, "   (S1 상계)")
    println("B 원시 쌍 (v, non_upstream) = ", B)
    println("C + 조건② 선행 여유        = ", C)
    println("D + 후속 템플릿 매치       = ", D)
    println("E + 선행 템플릿 매치       = ", E)
    println("F + val>0 && val2>0        = ", F, "   ◀ n_candidate_edges")
    println("--- 조건① 통과 정점 ", A, "개의 내역 ---")
    for v in a_vtxs
        node = CB.get_node_from_id(sched, CB.get_vtx_id(sched, v))
        println("  v=", v, " ", typeof(node).name.name,
                " outdeg=", Graphs.outdegree(sched, v), " n_elig_succ=", nes[v],
                " n_req_succ=", nrs[v],
                " |non_upstream|=", length(nuv[v]),
                " missing_succ=", [(string(t), val) for (t, val) in ms[v]])
    end
end

dissect("tractor.mpd", 10)
