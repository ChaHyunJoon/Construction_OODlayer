# =============================================================================
# test/translate_is_rigid.jl — `_apply_uniform_translation!(env, Δ)` 는 **강체 이동**이어야 한다.
#
#   julia +lts --project=. test/translate_is_rigid.jl
#
# 🔴 왜 이 시험이 있나 (2026-09-21 정지 탐침, results/2026-09-21-stall-probe/):
#    옛 구현은 조립체마다 `T ∘ global_transform(start_config)` 를 **루프 도중에** 읽었다. 하위
#    조립체의 start_config 는 상위 조립체의 자식이라, 부모가 먼저 옮겨지면 자식에 Δ 가 한 번 더
#    곱해졌다. 실측: tractor z3 에서 미완 목표 158개가 1Δ·2Δ·3Δ 로 갈라졌고(수직 잔차 < 1e-3),
#    X-wing z6 에서는 2Δ 로 밀린 목표 둘이 zone 안으로 들어가 빌드가 멈췄다.
#    `_minimum_clear_translation` 은 "전부 1Δ" 를 가정하므로 계산이 옳아도 적용이 틀리면 진다.
#
# 🔴 도메인이 퇴화하면 항진명제다 — 그래서 **중첩된 start_config 가 있다** 는 것부터 단언한다.
#    `test/respec_translate_build.jl` 은 colored_8x8.ldr 로 돌아 이 결함을 못 봤을 수 있다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
using LinearAlgebra: norm
const CB = ConstructionBots

pp  = CB.get_project_params("tractor.mpd")
env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "translate_rigid",
                         num_robots = pp[:num_robots], model_scale = pp[:model_scale],
                         assignment_mode = :greedy, n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

p2(t) = (v = Vector{Float64}(CB.project_to_2d(t.translation)); v[1:2])
function goals(env)
    out = Dict{Int,Vector{Float64}}()
    for v in Graphs.vertices(CB.get_graph(env.sched))
        v in env.cache.closed_set && continue
        n = CB.get_node(env.sched, v).node
        CB.matches_template(CB.EntityGo, n) || continue
        out[v] = p2(CB.global_transform(CB.goal_config(n)))
    end
    return out
end
function n_nested(env)
    tops = [CB.start_config(CB._assembly_complete_node(env, a)) for a in keys(env.staging_circles)
            if CB._assembly_complete_node(env, a) !== nothing]
    ids = IdDict{Any,Bool}(t => true for t in tops)
    return count(tops) do t
        cur = t
        while !CB.has_parent(cur, cur)
            cur = CB.get_parent(cur)
            haskey(ids, cur) && return true
        end
        false
    end
end
terminal_robotgo(env) = Set(v for v in Graphs.vertices(CB.get_graph(env.sched))
    if !(v in env.cache.closed_set) &&
       CB.matches_template(CB.RobotGo, CB.get_node(env.sched, v).node) &&
       CB.is_terminal_node(env.sched, CB.get_node(env.sched, v).node))

@testset "whole-build translation is rigid" begin
    nn = n_nested(env)
    println("[rigid] staging_circles=", length(env.staging_circles), " nested start_configs=", nn)
    @test nn > 0                                   # 도메인: 중첩이 없으면 아래는 누적을 못 잰다

    for Δ in ([0.37, -0.21], [-1.195, 1.212])
        g0 = goals(env)
        CB._apply_uniform_translation!(env, Δ)
        g1 = goals(env)
        term = terminal_robotgo(env)
        shift = Dict(v => g1[v] .- g0[v] for v in keys(g0) if haskey(g1, v))
        moved_ok = count(v -> norm(shift[v] .- Δ) < 1e-6, keys(shift))
        still    = [v for v in keys(shift) if norm(shift[v]) < 1e-6]
        bad      = [v for v in keys(shift) if norm(shift[v] .- Δ) >= 1e-6 && norm(shift[v]) >= 1e-6]
        println("[rigid] Δ=", Δ, " moved_by_Δ=", moved_ok, " unmoved=", length(still), " other=", length(bad))
        @test isempty(bad)                         # 1Δ 도 0 도 아닌 이동(= k·Δ 누적)이 하나도 없다
        @test moved_ok > 0
        @test all(v -> v in term, still)           # 안 움직이는 것은 빌드 밖의 말단 주차 목표뿐
    end
end

# =============================================================================
# 수리 여유 = 주행 계획기 여유 (2026-09-21, 사용자 결정 1번).
# `translate_whole_build!` 이 zone 을 비킨 뒤 **주행 띠**(채점은 안 막힘인데 TangentBug 는 부푼 원 안)
# 에 남은 이동 목표가 0 이어야 한다. 음성 대조: 여유 없이 푼 Δ(옛 동작)는 그 띠에 목표를 남긴다 —
# 그래야 위의 0 이 항진이 아니다. 채점 판정(`zone_blockage`)은 이 수정으로 안 바뀐다.
# =============================================================================
@testset "repair margin matches the navigation planner" begin
    buf = Float64(CB.staging_buffer_radius())
    @test buf > 0                                  # 도메인: 버퍼가 0 이면 두 기준이 같아 아무것도 안 잰다
    R = Float64(CB.default_robot_radius())
    placed = 0; n_band_old = 0; n_band_new = 0; n_bad_status = 0
    for i in 1:6                                   # 여러 자리에서 잰다 — 한 자리의 우연이 아니게
        CB.clear_restriction_zones!()
        # 매번 새로 읽는다 — 앞 반복의 수리가 빌드를 옮겼으므로 옛 좌표는 더는 목표가 아니다.
        # 말단 주차 목표는 빌드와 함께 안 움직인다(위 testset 의 `unmoved`) — 평행이동으로는 원리상
        # 못 치우고, 그때 `:residual_blocked` 가 정직한 답이다(실측 vtx=215). 여기서는 고칠 수 있는 자리만 잰다.
        navs = [t for t in CB._nav_goal_targets(env) if !(t.vtx in env.cache.active_set) &&
                !CB.is_terminal_node(env.sched, CB.get_node(env.sched, t.vtx).node)]
        t = navs[1 + (i - 1) * max(1, length(navs) ÷ 6)]
        CB.add_restriction_zone!(:rig_zone, t.goal, 0.5 * R)
        CB.zone_blockage(env; zone_keys = [:rig_zone], check_paths = false).n_engulfed >= 1 || continue
        placed += 1
        # 음성 대조: 옛 여유(1e-4)로 푼 Δ 를 적용하면 띠에 목표가 남는가 — 적용 뒤 되돌린다.
        Δold = CB._find_min_translation(env; zone_keys = [:rig_zone])
        if Δold !== nothing && norm(Δold) > 1e-9
            CB._apply_uniform_translation!(env, Δold)
            n_band_old += CB._count_goals_in_nav_band(env; zone_keys = [:rig_zone], buffer = buf)
            CB._apply_uniform_translation!(env, -Δold)
        end
        r = CB.translate_whole_build!(env; zone_keys = [:rig_zone], resume = false, verbose = false)
        println("[margin] i=", i, " vtx=", t.vtx, " kind=", t.kind, " status=", r.status,
                " |Δ|=", get(r, :delta, nothing) === nothing ? "-" : round(norm(r.delta); digits = 3),
                " |Δold|=", Δold === nothing ? "none" : round(norm(Δold); digits = 3),
                " residual=", get(r, :residual, "-"),
                " terminal=", CB.is_terminal_node(env.sched, CB.get_node(env.sched, t.vtx).node),
                " blocked_now=", [(b.vtx, CB.is_terminal_node(env.sched, CB.get_node(env.sched, b.vtx).node))
                                  for b in CB.zone_blockage(env; zone_keys = [:rig_zone], check_paths = false).blocked])
        r.status in (:translated, :already_clear) || (n_bad_status += 1)
        n_band_new += CB._count_goals_in_nav_band(env; zone_keys = [:rig_zone], buffer = buf)
        @test CB.zone_blockage(env; zone_keys = [:rig_zone], check_paths = false).n_engulfed == 0
    end
    CB.clear_restriction_zones!()
    println("[margin] buffer=", buf, " zones_placed=", placed, " band_old=", n_band_old,
            " band_new=", n_band_new, " bad_status=", n_bad_status)
    @test placed >= 3
    @test n_band_old > 0                           # 음성 대조가 살아 있다(옛 동작은 띠에 목표를 남겼다)
    @test n_band_new == 0                          # 새 동작은 하나도 안 남긴다
    @test n_bad_status == 0
end
