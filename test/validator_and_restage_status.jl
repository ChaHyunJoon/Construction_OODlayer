# =============================================================================
# test/validator_and_restage_status.jl — 실행 중 그래프의 두 보고가 사실을 말한다 (2026-09-22)
#
#   julia +lts --project=. test/validator_and_restage_status.jl
#   ⚠️ 수동 실행이다(runtests.jl 에 없다 — translate_is_rigid.jl 과 같다). 실측 18분 37초, 그중
#      (2) 가 16분 52초다: 후보 탐색과 사후 판정의 zone_blockage 가 빌드 전 env(미완 목표 131)에서 돈다.
#      시간이 어디서 드는지(탐색 vs flood fill)는 아직 안 쪼갰다.
#
# (1) `validate_schedule_transform_tree(env.sched)` — 실행 중 스케줄(OperatingSchedule)에서
#     예전에는 검사도 하기 전에 `MethodError(eligible_successors)` 로 던졌다. 지금은 빌드 때와
#     같은 그래프로 변환한 뒤 검사한다. 상수 `true` 가 아님을 변이 대조로 잰다: 리프트 목표
#     하나를 0.5 m 밀면 `false`, 원복하면 `true`.
#     ⚠️ 이 검증기는 장부 일관성만 본다 — 존과의 여유는 못 본다(results/2026-09-22-r3-parallel-probes).
#
# (2) `restage_all_blocked!` — 막힌 적치원이 없는데 존이 주행 목표를 막으면 `:residual_blocked`
#     (적치원은 안 옮긴다). 예전에는 잔여를 안 재고 `:none` 을 냈고 docstring 은 "zone clears all
#     goals already" 라고 적었다. 아무것도 안 막는 존은 여전히 `:none` 이다.
#     🔴 도메인이 퇴화하면 항진명제다 — 그래서 "적치원은 안 막고 목표만 막는 존" 을 실제로 찾아
#        심고, 찾았다는 것부터 단언한다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
const CB = ConstructionBots

pp  = CB.get_project_params("tractor.mpd")
env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "validator_restage",
                         num_robots = pp[:num_robots], model_scale = pp[:model_scale],
                         assignment_mode = :greedy, n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

@testset "(1) 검증기가 실행 중 그래프에서 돈다 — 그리고 상수 true 가 아니다" begin
    s = env.sched
    @test s isa CB.OperatingSchedule                     # 도메인: 실행 중 그래프여야 이 시험이 뜻이 있다
    @test CB.validate_schedule_transform_tree(s; post_staging = true) === true
    lifts = [n for n in CB.get_nodes(s) if CB.matches_template(CB.LiftIntoPlace, n)]
    @test !isempty(lifts)
    n  = first(sort(lifts; by = x -> string(CB.node_id(x))))
    tn = CB.goal_config(n); t0 = CB.local_transform(tn)
    CB.set_local_transform!(tn, CB.CoordinateTransformations.Translation(0.5, 0.0, 0.0) ∘ t0)
    mutated = redirect_stderr(devnull) do                # 실패 시 검증기가 stderr 에 백트레이스를 쓴다
        CB.validate_schedule_transform_tree(s; post_staging = true)
    end
    CB.set_local_transform!(tn, t0)
    @test mutated === false
    @test CB.validate_schedule_transform_tree(s; post_staging = true) === true
end

@testset "(2) restage_all_blocked! 는 막힌 적치원이 없어도 잔여 막힘을 보고한다" begin
    saved = copy(CB.RESTRICTION_ZONES[])
    try
        # 아무것도 안 막는 존 → :none
        CB.clear_restriction_zones!()
        CB.add_restriction_zone!(:far, [1.0e4, 1.0e4], 1.0)
        r_far = CB.restage_all_blocked!(env; zone_keys = [:far], resume = false, verbose = false)
        @test r_far.status === :none
        @test isempty(r_far.moved)
        @test get(r_far, :residual, 0) == 0

        # 적치원은 하나도 안 막는데 주행 목표는 막는 존을 찾는다
        G = CB.get_graph(env.sched)
        goals = Vector{Float64}[]
        for v in Graphs.vertices(G)
            v in env.cache.closed_set && continue
            nn = CB.get_node(env.sched, v).node
            CB.matches_template(Union{CB.RobotGo,CB.TransportUnitGo}, nn) || continue
            g = Vector{Float64}(CB.project_to_2d(CB.global_transform(CB.goal_config(nn)).translation))[1:2]
            push!(goals, g)
        end
        rr = 2 * CB.default_robot_radius()
        found = nothing
        for g in goals
            CB.clear_restriction_zones!()
            CB.add_restriction_zone!(:probe, g, rr)
            # 탐색은 싼 하한으로 한다(삼켜짐만, flood fill 없음 — `n_blocked` 의 정확한 하한).
            if isempty(CB.zone_blocked_assemblies(env; zone_keys = [:probe])) &&
               CB.zone_blockage(env; zone_keys = [:probe], check_paths = false).n_blocked > 0
                found = g
                break
            end
        end
        println("[vn] candidate goals=", length(goals), " found=", found)
        @test found !== nothing                          # 도메인: 이런 존이 없으면 아래는 아무것도 안 잰다
        if found !== nothing
            circles0 = Dict(k => Vector{Float64}(CB.get_center(b)[1:2]) for (k, b) in env.staging_circles)
            r = CB.restage_all_blocked!(env; zone_keys = [:probe], resume = false, verbose = false)
            @test r.status === :residual_blocked
            @test isempty(r.moved) && isempty(r.failed)
            @test r.residual > 0
            # 적치원은 안 옮긴다
            @test all(k -> Vector{Float64}(CB.get_center(env.staging_circles[k])[1:2]) == circles0[k],
                      keys(circles0))
        end
    finally
        CB.clear_restriction_zones!()
        for (k, z) in saved; CB.RESTRICTION_ZONES[][k] = z; end
    end
end
