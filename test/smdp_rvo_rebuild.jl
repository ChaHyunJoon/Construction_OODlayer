# =============================================================================
# test/smdp_rvo_rebuild.jl  —  게이트 N-G4 (독립 실행. runtests.jl 에 넣지 않는다)
#
#   julia +lts --project=. test/smdp_rvo_rebuild.jl
#
# RVO 는 씬트리의 **파생물**이다(spec §5-2). 그 명제가 참이면 재구축만으로 갈래 오염이
# 지워진다. 거짓이면 그건 롤아웃 문제가 아니라 **기존 실행 레인의 버그**다.
#
# 🔴 씬 생성은 SCENE-INCANTATION.md 의 정본을 따른다(브리프의 스니펫은 두 겹으로 틀렸다:
# return_env_before_sim 없이는 판을 끝까지 굴려 88초가 걸리고, 반환값도 PlannerEnv 가 아니라
# Tuple{PlannerEnv,Dict} 라 다음 줄에서 죽는다). 호출 순서도 브리프 원문(step→set_sim_step→
# update_planning_cache)이 아니라 SCENE-INCANTATION 정본(step→update_planning_cache→
# set_sim_step)을 쓴다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng4",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

for k in 1:50
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
end

# ⚠️ `rvo_get_agent_position` 의 실제 시그니처를 구현 시 확인한다:
#    grep -n "function rvo_get_agent_position" -A4 src/rvo_interface.jl
positions() = Dict(id => CB.rvo_get_agent_position(CB.get_node(env.scene_tree, id))
                   for id in sort!(collect(CB.get_vtx_ids(CB.rvo_global_id_map())); by = string))

@testset "재구축 후 위치 == 씬트리" begin
    CB.rvo_rebuild!(env)
    for (id, p) in positions()
        tr = CB.project_to_2d(CB.global_transform(CB.get_node(env.scene_tree, id)).translation)
        @test p[1] ≈ tr[1] atol = 1e-9
        @test p[2] ≈ tr[2] atol = 1e-9
    end
end

@testset "🔴 update_rvo_sim! 은 오염을 못 지운다 (음성 대조)" begin
    before = positions()
    victim = first(sort!(collect(keys(before)); by = string))
    CB.rvo_set_agent_position!(CB.get_node(env.scene_tree, victim), (99.0, 99.0))
    CB.update_rvo_sim!(env)                       # 가드가 false → 아무 일도 안 한다
    @test CB.rvo_get_agent_position(CB.get_node(env.scene_tree, victim))[1] ≈ 99.0
    CB.rvo_rebuild!(env)                          # 무조건 재구축은 지운다
    @test CB.rvo_get_agent_position(CB.get_node(env.scene_tree, victim))[1] ≈
          before[victim][1] atol = 1e-9
end

@testset "재구축이 멱등이다" begin
    CB.rvo_rebuild!(env); a = positions()
    CB.rvo_rebuild!(env); b = positions()
    @test a == b
end

# =============================================================================
# 컨트롤러 리뷰 1라운드 발견 1 — active_nodes 컴프리헨션이 가드를 넘어가며 죽는 자리가
# 바뀌면 안 된다. 원본 update_rvo_sim! 은 `active_nodes = [get_node(sched, v) for v in
# cache.active_set]` 을 가드보다 **먼저, 무조건** 계산했다. `cache.active_set` 에 `sched`
# 에 없는 정점 id 가 남아 있으면(가정 위반) 이 줄이 **가드와 무관하게** BoundsError 로
# 즉시 죽는 게 원래 동작이다. 그 줄을 rvo_rebuild! 안으로만 옮기면, 가드가 false 인
# (흔한) 경우엔 이 계산 자체가 안 일어나 죽어야 할 자리에서 조용히 넘어간다 — 조용한
# 폴백 금지 위반. 이 시험은 가드가 false 인 채로도 여전히 죽는지를 잰다.
# =============================================================================
@testset "🔴 update_rvo_sim! 은 sched 에 없는 정점을 조용히 넘기지 않는다 (가드가 false 여도 죽는다)" begin
    @test !CB.rvo_sim_needs_update(env.scene_tree)  # 가드가 여전히 false 임을 먼저 확인 — 아니면 이 시험이 무의미하다
    bogus_env = deepcopy(env)
    push!(bogus_env.cache.active_set, typemax(Int))  # sched 에 없는 정점 id (가정 위반)
    @test_throws BoundsError CB.update_rvo_sim!(bogus_env)
end
