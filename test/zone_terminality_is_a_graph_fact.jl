# =============================================================================
# **종단성은 비율이 아니다** — 구역이 완주 자체를 막는가를 그래프 사실로 잰다. (2026-09-05)
#
# 왜 이 파일이 필요한가 (실측)
# ----------------------------
# 2026-09-05 의 두 라이브 zone 판에서 모델은 NOOP 을 고르며
#   *"the exclusion zone minimally impacts the build"*
# 라고 적었다. 그 판의 정답은 **완주 실패**다 — tool-off 대조가 `PROJECT INCOMPLETE!`,
# `n_closed=270/305`, `t=5776` 로 끝났고, 광고된 동사만 쓴 손오라클은 같은 세계를
# `PROJECT COMPLETE!` (287/305, t=1022) 로 끝냈다.
#
# 그때 프롬프트가 준 가장 강한 막힘 신호는 `work frozen by those = 32` 와
# `the build has 251 unfinished nodes in total` 이었다. 비율로는 13% 다 — 그리고 **비율로서는
# 그 독해가 틀리지 않았다.** 세계가 결정 시점에 이미 알고 있었지만 한 번도 보고하지 않은 것은
# 비율이 아니라 술어였다:
#
#   `project_complete(env)` 는 "모든 ProjectComplete 정점이 closed_set 안에 있는가" 하나만 본다.
#   그 정점이 막힌 노드의 **후방 폐포** 안에 있으면, 구역이 사는 한 완주는 원리적으로 불가능하다.
#
# 재는 명제
#   (1) 전제 — 이 픽스처에서 막힘이 실제로 관측된다(없으면 아래는 0→0 항진명제다).
#   (2) 삼킨 구역: `project_blocked === true`, `n_completion_blocked >= 1`.
#   (3) 🔴 음성 대조 — 구역이 없으면 `project_blocked === false` 이고
#       `n_completion_open` 은 그대로 셋다(= "안 쟀다"가 아니라 "쟀는데 안 막혔다").
#   (4) 🔴 삼상 규약 — `check_blockage=false` 면 세 칸이 전부 `nothing` 이다. **0/false 가 아니다.**
#       (구역이 없는 진단(`:no_such_zone`)도 `nothing` 이다 — 진단할 구역이 없으니 안 쟀다.)
#   (5) `_downstream_unfinished` 의 값은 리팩터 전후로 안 변한다(폐포를 공유해도 같은 수).
#
# 변이시험(이 파일 상단 주석의 주장은 실제로 돌려 본 것만 적는다 — 결과는 태스크 보고서에).
#
# 실행: julia +lts --project=. test/zone_terminality_is_a_graph_fact.jl
# 비용: env 하나(colored_8x8, 4 robots). 시뮬레이션은 한 스텝도 안 돈다 —
#       `zone_blockage` 가 읽는 것은 배정이 끝난 스케줄 그래프와 `RESTRICTION_ZONES` 뿐이다.
# =============================================================================
module ZoneTerminalityIsAGraphFact

using Test
using ConstructionBots
const CB = ConstructionBots
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "zone_terminality_is_a_graph_fact",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

const _PREV_ZONES = copy(CB.RESTRICTION_ZONES[])

# `test/efficacy_measures_the_edit.jl` 과 같은 레시피: 가장 작은 반지름의 nav 목표 위에
# 1e-3 짜리 구역을 놓으면 포획볼이 배제원 안에 통째로 들어가 `goal_engulfed` 가 참이 된다.
function _engulfing_zone!(key::Symbol)
    local navs = CB._nav_goal_targets(TENV)
    isempty(navs) && error("nav 목표가 0개다 — 이 픽스처에서 막힘을 만들 수 없다")
    local t0 = navs[argmin([t.radius for t in navs])]
    CB.remove_restriction_zone!(key)
    CB.add_restriction_zone!(key, t0.goal, 1e-3)
    return key
end

try
    CB.clear_restriction_zones!()

    @testset "종단성은 완주 정점의 도달가능성이다 (2026-09-05, task B2)" begin

    @testset "(1) 전제 — 막힘이 실제로 관측된다" begin
        _engulfing_zone!(:term_pre)
        local b = CB.zone_blockage(TENV; zone_keys = [:term_pre], check_paths = false)
        @test b.n_nav_goals > 0
        @test b.n_blocked > 0
        @test b.n_downstream > 0
        CB.remove_restriction_zone!(:term_pre)
    end

    @testset "(2) 삼킨 구역은 완주 정점을 후방 폐포에 넣는다" begin
        _engulfing_zone!(:term_blk)
        local b = CB.zone_blockage(TENV; zone_keys = [:term_blk], check_paths = false)
        @test b.n_completion_open !== nothing
        @test b.n_completion_open >= 1            # 아직 안 닫힌 완주 정점이 실재한다(분모)
        @test b.n_completion_blocked >= 1
        @test b.project_blocked === true
        # 진단기도 같은 값을 그대로 통과시킨다(정책이 읽는 자리).
        local d = CB.zone_diagnosis(TENV, :term_blk; check_restage = false, check_paths = false)
        @test d.project_blocked === true
        @test d.n_completion_blocked === b.n_completion_blocked
        @test d.n_completion_open === b.n_completion_open
        CB.remove_restriction_zone!(:term_blk)
    end

    @testset "(3) 음성 대조 — 구역이 없으면 false 이지 nothing 이 아니다" begin
        CB.clear_restriction_zones!()
        local b = CB.zone_blockage(TENV; zone_keys = Symbol[], check_paths = false)
        @test b.n_blocked == 0
        @test b.project_blocked === false         # 쟀다. "안 쟀다"(nothing)와 다르다.
        @test b.n_completion_blocked === 0
        @test b.n_completion_open !== nothing && b.n_completion_open >= 1
    end

    @testset "(4) 삼상 — 안 쟀으면 nothing 이다 (0 도 false 도 아니다)" begin
        _engulfing_zone!(:term_three)
        local d = CB.zone_diagnosis(TENV, :term_three;
                                    check_restage = false, check_blockage = false)
        @test d.project_blocked === nothing
        @test d.n_completion_blocked === nothing
        @test d.n_completion_open === nothing
        @test d.n_nav_blocked == -1               # 같은 규약의 옛 칸(센티넬)
        CB.remove_restriction_zone!(:term_three)
        # 등록조차 안 된 키: 진단할 구역이 없으니 안 쟀다.
        local dz = CB.zone_diagnosis(TENV, :term_never_registered)
        @test dz.exists === false
        @test dz.project_blocked === nothing
    end

    @testset "(5) 폐포 리팩터는 downstream 카운트를 안 바꾼다" begin
        _engulfing_zone!(:term_ds)
        local b = CB.zone_blockage(TENV; zone_keys = [:term_ds], check_paths = false)
        local vtxs = [x.vtx for x in b.blocked]
        @test CB._downstream_unfinished(TENV, vtxs) === b.n_downstream
        @test CB._downstream_closure(TENV, vtxs).n_unfinished === b.n_downstream
        CB.remove_restriction_zone!(:term_ds)
    end

    end # outer testset
finally
    empty!(CB.RESTRICTION_ZONES[]); merge!(CB.RESTRICTION_ZONES[], _PREV_ZONES)
end

end # module
