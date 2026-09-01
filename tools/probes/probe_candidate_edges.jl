# ============================================================================
# S2 전제조건 ③ — 후보 배정 간선의 **정확한** 수.
#
# 정답원: `formulate_milp` 이 Big-M 후보 루프에서만 채우는 `edge_costs`.
#   `CB.LAST_EDGE_COSTS[]` 가 그 Dict 를 그대로 들고 있다 ⟹ `length()` 가 곧 정확 카운트.
#   조건 3개를 손으로 복제하지 않는다(policy.jl:226-232 의 경고 = 두 벌은 조용히 갈린다).
#
# 함께 찍는 것:
#   · S1 상계 프로브와 **같은 식** — 조건 ① 만 통과하는 정점 수. 18 이 재현되는지 대조.
#   · nnz(Xa) — 고정 구조 간선까지 포함한 이진변수 수(2026-08-30 이 329 로 적은 값).
#   · 센티넬 — formulate 가 실제로 돌았는지. 안 돌면 0 을 "후보 0" 으로 오독하게 된다.
# ============================================================================
using ConstructionBots, Test
import Random, Graphs
using JuMP, SparseArrays
const CB = ConstructionBots

function upper_bound(sched)
    pp  = CB.preprocess_project_schedule(sched)
    nes = pp[3]
    return count(v -> Graphs.outdegree(sched, v) < nes[v], Graphs.vertices(sched))
end

function probe(ldraw, nrobots, mode)
    println("\n=== board=", ldraw, " robots=", nrobots, " assignment_mode=", mode, " ===")
    env = CB.run_lego_demo(; ldraw_file = ldraw, project_name = "s2probe",
                             num_robots = nrobots, assignment_mode = mode,
                             n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    sched = env.sched
    println("nv(sched)            = ", Graphs.nv(sched))
    println("ne(sched)            = ", Graphs.ne(sched))
    println("slots_upper_bound    = ", upper_bound(sched), "   (S1 식 그대로: 조건① 통과 정점 수)")

    # 🔴 센티넬: formulate 가 안 돌았는데 0 을 읽는 사고를 막는다(enact.jl 의 같은 관용구).
    sentinel = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sentinel
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, env.scene_tree;
                             optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sentinel)
    println("ran_formulate        = ", ran)
    if !ran
        println("n_candidate_edges    = n/a(formulate 가 LAST_EDGE_COSTS 를 안 갈아끼움)")
        return
    end
    ec = CB.LAST_EDGE_COSTS[]
    println("n_candidate_edges    = ", length(ec), "   ◀ ③ 정확값 (edge_costs 항목 수)")
    try
        Xa = milp.Xa
        println("nnz(Xa)              = ", length(Xa.nzval))
    catch e
        println("nnz(Xa)              = n/a (", sprint(showerror, e), ")")
    end
    if !isempty(ec)
        vs = sort(unique([k[1] for k in keys(ec)]))
        println("distinct source vtx  = ", length(vs))
        println("edge_cost range      = ", minimum(values(ec)), " … ", maximum(values(ec)))
    end
end

probe("colored_8x8.ldr", 6, :greedy)      # respec_grammar.jl 픽스처와 동일 (423 이 적힌 판)
probe("tractor.mpd",    10, :greedy)      # 2026-08-30 이 0 을 적은 판 (생산 레인 설정)
# 🔴 음성 대조: 후보가 0 이라면 원인이 :greedy 인가? 배정 모드만 바꿔 대조한다.
probe("tractor.mpd",    10, :milp)
