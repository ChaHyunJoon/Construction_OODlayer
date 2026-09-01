# 비개입 검증 (2판): release 는 sched 뿐 아니라 **scene_tree** 와 전역 INVALID_ID_COUNTERS
# 도 건드린다(`reset_slot_to_invalid!` → `replace_in_schedule!` · `get_unique_invalid_id`).
# 그래서 (a) sched·scene_tree 를 **한 번에** deepcopy 해 내부 참조를 보존하고,
#        (b) 무효 ID 카운터를 스냅샷·복원한다(시드 재현성에 닿는 자리).
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots

function candidates(sched, scene_tree)
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, scene_tree;
                      optimizer = CB._respec_optimizer())
    (CB.LAST_EDGE_COSTS[] === sent) ? -1 : length(CB.LAST_EDGE_COSTS[])
end

"세계를 안 건드리고 'release 하면 후보 간선이 몇 개 열리나'를 잰다. 실패하면 nothing."
function s2_candidate_probe(env)
    saved_ids = copy(CB.INVALID_ID_COUNTERS)          # 🔴 전역 카운터 스냅샷
    try
        before = candidates(env.sched, env.scene_tree)
        # 🔴 둘을 **함께** 뜬다 — 따로 뜨면 sched↔scene_tree 공유 참조가 끊긴다.
        sched_c, tree_c = deepcopy((env.sched, env.scene_tree))
        shim = (sched = sched_c, scene_tree = tree_c, cache = env.cache)
        removed = CB.release_pending_assignments!(shim, CB.build_invariant(env))
        after = candidates(sched_c, tree_c)
        return (before = before, after = after, released = length(removed))
    catch e
        @warn "s2_candidate_probe failed" exception = e
        return nothing                                 # 삼상 규약: 못 쟀다 ≠ 0
    finally
        empty!(CB.INVALID_ID_COUNTERS); merge!(CB.INVALID_ID_COUNTERS, saved_ids)
    end
end

env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2copysafe",
                         num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

ne0 = Graphs.ne(env.sched); ids0 = copy(CB.INVALID_ID_COUNTERS)
r1 = s2_candidate_probe(env); ne1 = Graphs.ne(env.sched)
r2 = s2_candidate_probe(env); ne2 = Graphs.ne(env.sched)   # 첫 호출이 세계를 바꿨으면 값이 달라진다
ids2 = copy(CB.INVALID_ID_COUNTERS)

println("\n==== 비개입 검증 ====")
println("원본 ne:  시작=", ne0, " 1회후=", ne1, " 2회후=", ne2)
println("무효ID 카운터: 시작=", ids0, "  2회후=", ids2)
println("호출 1: ", r1)
println("호출 2: ", r2)
println(ne0 == ne1 == ne2      ? "✅ 스케줄 원본 불변" : "🔴 원본이 변했다")
println(ids0 == ids2           ? "✅ 무효ID 카운터 불변" : "🔴 카운터가 샜다")
println(r1 == r2 && r1 !== nothing ? "✅ 멱등·재현" : "🔴 두 호출이 다르거나 실패")
