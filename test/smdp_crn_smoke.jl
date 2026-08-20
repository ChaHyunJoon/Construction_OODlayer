# CRN(공통난수) 무결성 — spec §5.7 이 지목한 누수를 _hz_fire_cell! 자체를 통해 재현한다.
#
# 리뷰 라운드 1 교정: 이전 버전은 _hz_draw_cell_drop!/_hz_commit_cell_drop! 을 **직접** 불러
# 캐시 계약만 검사했고 _hz_fire_cell! 을 단 한 번도 호출하지 않았다. 뮤테이션으로 증명됨:
# HEAD 의 헬퍼는 그대로 두고 _hz_fire_cell! 만 커밋 8363b89d 의 축자 본문(캐시를 안 쓰는
# 수정 전 버전)으로 덮어써도 그 버전은 전부 PASS 했다 — 헬퍼가 "존재"하기만 하면 그것을
# _hz_fire_cell! 에 배선하는 것을 잊거나 나중에 되돌려도 이 시험은 영원히 침묵한다.
#
# 이번 버전은 안전 가드(_hz_safe_target)의 답을 카운터로 통제해 _hz_fire_cell! 을 실제로
# "0회 유예 후 즉시 발화"와 "3회 유예 후 발화" 두 팔로 굴리고, 그 뒤 로봇의 난수 스트림
# 위치가 같은지를 검사한다. 수정 전 코드는 유예마다 뽑기를 하나씩 더 태우므로 팔 B 의 스트림이
# 팔 A 보다 앞서 나가고, 그 결과 thr_cell 재장전값과 다음 난수열이 갈린다 — 그 갈림이 바로
# 이 시험의 핵심 단언이다.
#
#   julia +lts --project=. test/smdp_crn_smoke.jl
#
# ⚠️ 이 파일은 CB._hz_safe_target 과 CB.battery_action 을 전역으로 덮어쓴다(엔진/씬 없이
# _hz_fire_cell! 하나만 겨누기 위한 스텁 — 엔진 결합 자체의 실측은 run_demo.jl 통합 측정의
# 몫이다, 보고서 §4 참조). 그래서 이 스크립트는 반드시 **독립 프로세스**로 돈다 — Pkg.test()
# 의 runtests.jl 에는 안 실려 있고(그래서 이 전역 덮어쓰기가 다른 테스트를 오염시키지 않는다),
# 다른 test/*.jl 과 같은 프로세스에서 include 하지 말 것.
using ConstructionBots
using Test
using Random
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_mk(; seed = 0, kw...) = CB._new_hazard_state(CB.HazardParams(; kw...), seed)

# --- 스텁: 씬/스케줄 없이 _hz_fire_cell! 하나만 구동한다 ------------------------------------
# 안전 가드의 답을 호출 횟수로 정확히 통제한다: _CALLS[] 가 _DEFER_UNTIL[] 을 넘을 때만 통과.
const _CALLS       = Ref(0)
const _DEFER_UNTIL = Ref(0)
function CB._hz_safe_target(env, rid)
    _CALLS[] += 1
    return _CALLS[] > _DEFER_UNTIL[]
end
# 실제 battery_action/inject_battery_fault! 은 완성된 씬(스케줄·로봇 노드)을 요구한다. 이 시험이
# 겨누는 CRN 계약은 _hz_fire_cell! 자신의 뽑기/캐시 로직에 있지 그 아래 주입 계층에 있지 않으므로,
# "발화가 성사됐다"는 사실만 스텁으로 낸다.
CB.battery_action(; target = nothing, soc_drop::Float64 = 0.6,
                  soc_target::Union{Nothing,Float64} = nothing) =
    (env -> "synthetic cell event for robot $(target) (soc_drop=$(soc_drop))")
CB.BATTERY_FLEET[] = CB.BatteryFleet(CB.BatteryParams(), Dict{Any,Float64}(),
                                     Dict{Any,Float64}(), Dict{Any,Int}(), Set{Any}())

# severe_frac=1.0 -> drop 은 항상 cell_severe_drop(=1.0)이라 "깊은 방전" 가지(=안전 가드가 실제로
# 걸리는 가지)를 결정론적으로 태운다. fire_require_spare=false 로 nearest_pool 스텁은 생략한다.
_cell_params() = CB.HazardParams(cell_severe_frac = 1.0, cell_severe_drop = 1.0,
                                 fire_require_spare = false)

function run_crn_smoke_tests()
    @testset "헬퍼 단독: 유예는 캐시를 재사용한다" begin
        # 여전히 유효한 계약이지만, 이것만으로는 부족하다(_hz_fire_cell! 을 안 부른다) — 아래
        # "실제 경로" 테스트셋이 리뷰가 요구한 회귀 방지선이다.
        st_a = _mk(seed = 7)
        st_b = _mk(seed = 7)
        rid = 101
        d1 = CB._hz_draw_cell_drop!(st_a, rid)
        d2 = CB._hz_draw_cell_drop!(st_a, rid)      # 유예 후 재시도 — 같은 낙폭이어야 한다
        @test d1 == d2
        _ = CB._hz_draw_cell_drop!(st_b, rid)
        @test rand(CB._robot_rng(st_a, rid)) == rand(CB._robot_rng(st_b, rid))
    end

    @testset "헬퍼 단독: 발화가 성사되면 캐시가 비워진다" begin
        st = _mk(seed = 11)
        rid = 202
        d1 = CB._hz_draw_cell_drop!(st, rid)
        @test haskey(st.pending_drop, rid)
        CB._hz_commit_cell_drop!(st, rid)
        @test !haskey(st.pending_drop, rid)
        d2 = CB._hz_draw_cell_drop!(st, rid)        # 다음 사건은 새로 뽑는다
        @test d2 isa Float64
    end

    @testset "실제 경로: _hz_fire_cell! 을 유예 0회 vs 3회로 굴려도 로봇 스트림이 같다" begin
        rid = 303

        # 팔 A: 가드가 첫 시도에서 통과(유예 0회) — 같은 시드(7)
        st_a = _mk(seed = 7, cell_severe_frac = 1.0, cell_severe_drop = 1.0,
                  fire_require_spare = false)
        _CALLS[] = 0; _DEFER_UNTIL[] = 0
        nl_a = CB._hz_fire_cell!(nothing, st_a, rid, 1.0, :idle)
        @test nl_a !== nothing                        # 즉시 발화
        @test !haskey(st_a.pending_drop, rid)          # 커밋됐으니 캐시 없음

        # 팔 B: 가드가 3회 거부(유예)한 뒤 4번째에 통과 — 같은 시드(7)
        st_b = _mk(seed = 7, cell_severe_frac = 1.0, cell_severe_drop = 1.0,
                  fire_require_spare = false)
        _CALLS[] = 0; _DEFER_UNTIL[] = 3
        nl1 = CB._hz_fire_cell!(nothing, st_b, rid, 1.0, :idle)
        @test nl1 === nothing                          # 1회차: 유예
        @test haskey(st_b.pending_drop, rid)            # 유예 중엔 낙폭이 캐시에 남는다
        d_cached = st_b.pending_drop[rid]
        nl2 = CB._hz_fire_cell!(nothing, st_b, rid, 1.0, :idle)
        @test nl2 === nothing                          # 2회차: 유예
        @test st_b.pending_drop[rid] == d_cached        # 캐시 hit — 재뽑기 아님
        nl3 = CB._hz_fire_cell!(nothing, st_b, rid, 1.0, :idle)
        @test nl3 === nothing                          # 3회차: 유예
        nl_b = CB._hz_fire_cell!(nothing, st_b, rid, 1.0, :idle)
        @test nl_b !== nothing                          # 4회차: 발화
        @test !haskey(st_b.pending_drop, rid)

        # ★ 핵심 단언 — 유예 횟수가 갈렸어도(0 vs 3) 발화 직후 그 로봇 스트림의 위치는 같아야
        # CRN 이 산 것이다. 수정 전 코드는 유예마다 rand 를 하나씩 더 태워 여기서 갈린다
        # (검증: 보고서 §RED 의 뮤테이션 결과 — 이 단언이 정확히 그 자리에서 실패한다).
        @test st_a.thr_cell[rid] == st_b.thr_cell[rid]
        n1 = rand(CB._robot_rng(st_a, rid)); n2 = rand(CB._robot_rng(st_b, rid))
        @test n1 == n2
        m1 = rand(CB._robot_rng(st_a, rid)); m2 = rand(CB._robot_rng(st_b, rid))
        @test m1 == m2
    end
end

run_crn_smoke_tests()
println("\nsmdp_crn_smoke: ALL PASS")
