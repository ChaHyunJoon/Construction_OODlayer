# =============================================================================
# test/respec_verify_translate.jl — Task C4 게이트: 일반 기하 검증기
#
#   julia +lts --project=. test/respec_verify_translate.jl
#   🔴 runtests.jl 에 싣지 않는다 (Global Constraint: SMDP 계열은 독립 프로세스).
#
# 🔴 이 검증기는 kind 를 안 본다. "결과 배치가 조건을 만족하는가" 만 본다 — 그것이 신설된
#    행동을 안전하게 만드는 방법이다(spec §5-2 의 기하 티어 대응물). `verify()` 가 MILP 티어를
#    kind 무관으로 검증하는 것과 같은 자리다.
#
# 🔴 이 태스크가 대체하는 것: C3 의 **잠정** 사후 경계(적용 후 잔여 검사 + `.-Δ` 되돌리기).
#    그 경계가 못 잡던 둘을 실측으로 못박는다:
#      (1) 활성 구역이 **없을 때**의 모든 Δ — C3 는 "기하적 기준점이 없다"며 전부 통과시켰다.
#          기준점을 준다: **고정 창고 링**(`spare_depot_distance()`; 창고는 (0,±D)·(±D,0) 에
#          절대좌표로 박혀 있고 빌드와 같이 안 움직인다). 빌드가 그 링을 나가면 ReplaceAgent ·
#          SwapBattery 의 배송 기점이 물류권 밖에 남는다.
#      (2) 구역을 **넘치게** 비우는 Δ(예: 1e6) — 구역을 비우는 것은 **필요조건이지 충분조건이
#          아니다.** 같은 링 경계가 그것을 거부한다.
#
# 🔴 검증기는 **읽기 전용**이다. C3 는 적용-후-검사-후-되돌리기였고, 되돌리기가 부정확하면
#    세계가 영구히 어긋난다(대체하려던 fail-open 보다 나쁘다). C4 는 아예 안 옮긴다 —
#    좌표에 Δ 를 더해 볼 뿐이다. 아래 [2] 가 그것을 poses·state_hash 로 실측한다.
#
# ⚠️ 브리프와 다른 것(전부 보고서에 기록):
#    · `test/smdp_fixtures.jl` / `_zone_fixture()` / `_assembly_poses()` 는 이 브랜치에 **없다**
#      (C1·C2·C3 가 이미 같은 것을 기록했다). 헬퍼를 이 파일 안에 자족적으로 둔다.
#    · `_within_workspace_bounds` 는 브리프가 예고한 대로 **없었다** — 이 태스크가 만든다.
#      `_future_work_discs` 는 있다(restage_zone.jl:650).
#
# 🔴 씬 생성은 SCENE-INCANTATION.md 가 정본이다. 스텝 수는 **남의 표에서 안 베낀다** —
#    `_probe_step!` 이 이 픽스처에서 도메인이 비퇴화가 되는 스텝을 직접 찾고 그 값을 찍는다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
using LinearAlgebra: norm
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "respec_verify_translate",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 3)          # simstate_of 는 HAZARD_STATE 없이는 error 로 죽는다

# --- 이 시험의 도메인. 전부 비퇴화여야 아래 단언이 항진명제가 아니다 -------------------
#   n_poses    geo.poses 가 실제로 조립체를 담는가
#   n_staging  `_build_footprint` 의 정의역 (0 이면 argmax 가 죽는다)
#   n_discs    `_future_work_discs` — `translate_clears_zones` 의 정의역 (0 이면 항상 true)
#   frontier   active_set > 0 ∧ **0 < closed_set < nv** (퇴화한 세계를 재지 않는다)
# 🔴 `0 < n_closed < nv` 를 요구한다: C3 가 실측한 대로 이 조건이 없으면 probe 가 **0**(한 번도
#    안 굴린 판)을 돌려주고, 그러면 이 시험은 조용히 시작 상태만 잰다.
function _domain(env)
    n_poses = count(v -> CB.matches_template(CB.AssemblyComplete, CB.get_node(env.sched, v).node),
                    Graphs.vertices(env.sched))
    return (n_poses   = n_poses,
            n_staging = length(env.staging_circles),
            n_discs   = length(CB._future_work_discs(env)),
            n_active  = length(env.cache.active_set),
            n_closed  = length(env.cache.closed_set),
            nv        = Graphs.nv(env.sched))
end
_nondegenerate(d) = d.n_poses > 0 && d.n_staging > 0 && d.n_discs > 0 &&
                    d.n_active > 0 && 0 < d.n_closed < d.nv

"이 픽스처에서 도메인이 비퇴화가 되는 스텝을 **직접 찾는다**(남의 표를 안 베낀다)."
function _probe_step!(env; cap = 300, every = 10)
    d = _domain(env)
    _nondegenerate(d) && return (0, d)
    for k in 1:cap
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        if k % every == 0
            d = _domain(env)
            _nondegenerate(d) && return (k, d)
        end
    end
    error("이 픽스처에서 $(cap) 스텝 안에 비퇴화 도메인을 못 찾았다: $(_domain(env))")
end

const PROBE_STEP, DOM = _probe_step!(env)
@info "[C4] 실측한 probe step = $(PROBE_STEP)  도메인 = $(DOM)"

# --- 픽스처의 구역: root 하역 목표의 무게중심에 심는다(C3 [9][10] 과 같은 자리) ----------
# 🔴 정렬해서 더한다 — 부동소수 덧셈은 결합법칙이 없다(시드 고정 = 완전 재현).
const ROOT_GOALS = sort(CB.root_deposit_goals(env); by = g -> (Float64(g[1]), Float64(g[2])))
const ZC = sum(ROOT_GOALS) ./ length(ROOT_GOALS)
const ZR = 2.5
CB.clear_restriction_zones!()
CB.add_restriction_zone!(:c4zone, ZC, ZR)

const ZKEYS   = sort!(collect(keys(CB.RESTRICTION_ZONES[])); by = string)
const N_GOALS = CB._count_future_goals_in_zone(env; zone_keys = ZKEYS)
const N_OVER  = CB._count_future_work_overlaps(env; zone_keys = ZKEYS)
const D0      = CB._find_min_translation(env; zone_keys = ZKEYS)
const FC, FR  = CB._build_footprint(env)
const DEPOT_D = CB.spare_depot_distance()
# 이 픽스처에서 링 경계까지 남은 변위 여유(빌드 중심에서 재는 반경 예산).
const MAX_SHIFT = DEPOT_D - norm(FC) - FR

@info "[C4] 구역 :c4zone @ $(round.(ZC; digits = 3)) R=$(ZR)  가둔 미래 목표=$(N_GOALS) " *
      "겹친 work disc=$(N_OVER)/$(DOM.n_discs)\n      |Δ0|=$(round(norm(D0); digits = 4)) " *
      "Δ0=$(round.(D0; digits = 4))\n      footprint c=$(round.(FC; digits = 3)) R=$(round(FR; digits = 3)); " *
      "창고링 D=$(DEPOT_D)  변위 예산=$(round(MAX_SHIFT; digits = 3))"

# --- 헬퍼(자족적) ------------------------------------------------------------
_p(dx, dy) = CB.RespecProposal(CB.ConstraintSpec[CB.TranslateBuild(dx, dy)])
_poses(env) = CB.simstate_of(env).geo.poses
_hash(env)  = CB.state_hash(CB.simstate_of(env))
_stage(env) = Dict(k => (Vector{Float64}(CB.get_center(b)[1:2]), Float64(CB.get_radius(b)))
                   for (k, b) in env.staging_circles)
_tup(v) = (Float64(v[1]), Float64(v[2]))
_reason(v) = v isa CB.Reject ? v.reason : :admitted
# Δ0 방향의 단위벡터 — 경계 근처를 재는 데 쓴다(같은 방향이라 구역은 확실히 비켜진다).
const U = D0 ./ norm(D0)

# =============================================================================
@testset "[0] 🔴 비퇴화 — 구역이 실제로 미래 작업을 가두고, 링 예산이 최소이동보다 넓다" begin
    @test _nondegenerate(DOM)
    @test PROBE_STEP > 0
    @test 0 < DOM.n_closed < DOM.nv       # 빌드가 실제로 진행됐다
    @test DOM.n_discs > 0                 # translate_clears_zones 의 정의역이 비어 있지 않다
    @test !isempty(ROOT_GOALS)
    # 🔴 구역이 **실제로** 가두고 있다. 안 그러면 잔여 검사가 의미를 갖지 않는다(항진명제).
    @test N_GOALS > 0
    @test N_OVER  > 0
    @test D0 !== nothing && norm(D0) > 0.0
    # 🔴 지금 이 배치는 구역을 **안** 비킨다 = Δ=0 이 통과할 수 없다(검증기와 무관한 사실).
    @test !CB.translate_clears_zones(env, (0.0, 0.0))
    # 🔴 링 경계가 **정지 상태에서는 만족된다** — 아니면 (3) 이 항상 거부라 능력이 죽는다.
    @test CB._within_workspace_bounds(env, (0.0, 0.0))
    @test DEPOT_D > 0
    # 🔴 두 조건이 서로 모순이 아니다: 구역을 비우는 최소 이동이 링 예산 **안**이다.
    @test MAX_SHIFT > norm(D0)
end

@testset "[1] 🔴 비키는 Δ 는 통과, 안 비키는 Δ 는 거부" begin
    @test CB.verify_translate(_p(D0[1], D0[2]), env) isa CB.Admit
    @test CB.translate_clears_zones(env, _tup(D0))
    # 0 은 NOOP 과 바이트 동일한 무성 no-op 이다
    v0 = CB.verify_translate(_p(0.0, 0.0), env)
    @test v0 isa CB.Reject
    @test v0.reason === :zero_displacement
    # 🔴 정확한 0 만 막으면 안 된다: `s` 의 관측 양자(`_c` digits=9) 아래는 hollow admit 이다
    vq = CB.verify_translate(_p(1e-18, 0.0), env)
    @test vq isa CB.Reject && vq.reason === :zero_displacement
    @test CB._TB_MIN_DELTA == 1e-9
    # 모자란 Δ(최소이동의 10%)는 구역을 못 비운다
    small = 0.1 .* D0
    @test 0.0 < norm(small) < norm(D0)
    vs = CB.verify_translate(_p(small[1], small[2]), env)
    @test vs isa CB.Reject && vs.reason === :residual_blocked
    @test !CB.translate_clears_zones(env, _tup(small))
    # kind 무관 검증기의 전제: TranslateBuild 가 없거나 둘이면 판정할 대상이 없다
    @test CB.verify_translate(CB.RespecProposal(CB.ConstraintSpec[]), env).reason === :not_translate
    @test CB.verify_translate(CB.RespecProposal(CB.ConstraintSpec[
              CB.TranslateBuild(1.0, 0.0), CB.TranslateBuild(0.0, 1.0)]), env).reason === :ambiguous
    # 옮길 대상이 없으면 거부한다(균일 이동이 조용한 no-op 이 되는 자리)
    saved = copy(env.staging_circles)
    try
        empty!(env.staging_circles)
        @test CB.verify_translate(_p(D0[1], D0[2]), env).reason === :no_staging
    finally
        merge!(env.staging_circles, saved)
    end
    @test length(env.staging_circles) == length(saved)
end

@testset "[2] 🔴 검증기가 env 를 바꾸지 않는다 (읽기 전용 — C3 의 적용-후-되돌리기를 대체한다)" begin
    before  = _poses(env)
    h0      = _hash(env)
    stage0  = _stage(env)
    goals0  = CB._count_future_goals_in_zone(env; zone_keys = ZKEYS)
    # 통과·거부·경계밖·터무니없음 — 네 갈래 전부에서 본다
    for prop in (_p(D0[1], D0[2]), _p(0.0, 0.0), _p(7.0, 7.0), _p(1e6, 1e6),
                 _p(0.1 * D0[1], 0.1 * D0[2]))
        CB.verify_translate(prop, env)
    end
    @test _poses(env) == before
    @test _hash(env) == h0
    @test _stage(env) == stage0
    @test CB._count_future_goals_in_zone(env; zone_keys = ZKEYS) == goals0
    @test !CB.RESPEC_HOLD[]                # 거부가 라인을 영구정지시키지 않는다
end

@testset "[3] 🔴 터무니없는 Δ 는 거부한다 — 구역을 비우는 것은 **충분조건이 아니다**" begin
    # 🔴 이것이 C3 의 잠정 경계가 통과시키던 바로 그 Δ 다: 잔여 0 이므로 잔여 검사는 만족한다.
    @test CB.translate_clears_zones(env, (1e6, 1e6))      # 구역은 확실히 비킨다
    v = CB.verify_translate(_p(1e6, 1e6), env)
    @test v isa CB.Reject
    @test v.reason === :out_of_bounds                     # 그런데도 거부된다
    @test !CB._within_workspace_bounds(env, (1e6, 1e6))
    # 경계가 **어디**인지 실측한다(항상 거부도, 항상 통과도 아니다).
    t_in  = 0.95 * MAX_SHIFT
    t_out = 1.05 * MAX_SHIFT
    @test t_in > norm(D0)                                  # 안쪽 후보도 구역은 비킨다
    Δin  = _tup(t_in  .* U)
    Δout = _tup(t_out .* U)
    @test CB.translate_clears_zones(env, Δin) && CB.translate_clears_zones(env, Δout)
    @test CB._within_workspace_bounds(env, Δin)
    @test !CB._within_workspace_bounds(env, Δout)
    @test CB.verify_translate(_p(Δin[1], Δin[2]), env) isa CB.Admit
    @test CB.verify_translate(_p(Δout[1], Δout[2]), env).reason === :out_of_bounds
    @info "[C4] 링 경계 실측: |Δ| ≤ $(round(MAX_SHIFT; digits = 3)) 통과 · " *
          "$(round(t_out; digits = 3)) 거부 (D=$(DEPOT_D), |fc|=$(round(norm(FC); digits = 3)), " *
          "R=$(round(FR; digits = 3)))"
end

@testset "[4] 🔴 활성 구역이 **없어도** Δ 에는 경계가 있다 (C3 의 미해결 (1))" begin
    saved_zc, saved_zr = Vector{Float64}(ZC), ZR
    CB.clear_restriction_zones!()
    try
        @test isempty(CB.RESTRICTION_ZONES[])
        # 구역이 없으면 잔여 검사는 **정보가 없다** — 무엇이든 통과시킨다
        @test CB.translate_clears_zones(env, (1e6, 1e6))
        @test CB.translate_clears_zones(env, (0.0, 0.0))
        # 🔴 그래도 링 경계가 남는다: C3 는 이 경우 모든 Δ 를 통과시켰다.
        v = CB.verify_translate(_p(1e6, 1e6), env)
        @test v isa CB.Reject && v.reason === :out_of_bounds
        # 🔴 음성 대조: 능력이 죽은 게 아니다 — 링 안의 Δ 는 구역이 없어도 통과한다.
        @test CB.verify_translate(_p(1.0, 0.0), env) isa CB.Admit
        # 0 은 여전히 무성 no-op 이다
        @test CB.verify_translate(_p(0.0, 0.0), env).reason === :zero_displacement
    finally
        CB.clear_restriction_zones!()
        CB.add_restriction_zone!(:c4zone, saved_zc, saved_zr)
    end
    @test CB._count_future_goals_in_zone(env; zone_keys = ZKEYS) == N_GOALS   # 픽스처 복원
end

@testset "[5] 🔴 verify() 는 읽기 전용이다 (spec §5-1b)" begin
    # verify() 가 상태를 안 바꾼다는 것은 **가정이지 실측이 아니었다.** 시행풀이가 전역
    # (HiGHS 상태·RNG)을 건드리면 "관측이 세계를 바꾸는" 사고가 된다 — simstate_of 에
    # 읽기 전용 게이트를 둔 것과 같은 이유다. 통과·거부 **양쪽**에서 본다.
    inv = CB.build_invariant(env)
    for prop in (_p(3.0, -1.5), _p(0.0, 0.0))          # 통과 후보 · 거부 확정
        h0 = _hash(env)
        CB.verify(prop, env, inv)
        @test _hash(env) == h0
    end
end

@testset "[6] 🔴 음성 대조 — 검증기가 상수 Admit 도 상수 Reject 도 아니다" begin
    verdicts = [CB.verify_translate(_p(d, 0.0), env) for d in 0.0:1.0:20.0]
    n_admit = count(v -> v isa CB.Admit, verdicts)
    @test 0 < n_admit < 21                       # 전부 통과도 전부 거부도 아니어야 한다
    reasons = sort!(unique(_reason.(verdicts)); by = string)
    # 세 거부 사유가 **전부 실제로 도달된다** — 하나라도 죽어 있으면 그 조건은 안 재진 것이다.
    @test :zero_displacement in reasons
    @test :residual_blocked  in reasons
    @test :out_of_bounds     in reasons
    @test :admitted          in reasons
    @info "[C4] +x 방향 0:1:20 판정 = $(join(string.(_reason.(verdicts)), " "))  (admit=$(n_admit))"
end

@testset "[7] 🔴 Admit 은 공허하지 않다 — Δ0 를 실제로 집행하면 구역이 비워진다" begin
    # 이 시험의 마지막 자리에 둔다(유일하게 세계를 만지는 testset). 정확히 되돌린다.
    before = _poses(env)
    h0 = _hash(env)
    @test CB.verify_translate(_p(D0[1], D0[2]), env) isa CB.Admit
    CB._apply_uniform_translation!(env, (D0[1], D0[2]))
    try
        @test CB._count_future_goals_in_zone(env; zone_keys = ZKEYS) == 0
        @test CB.translate_clears_zones(env, (0.0, 0.0))       # 이제 정지 상태가 깨끗하다
        @info "[C4] 비퇴화 실측: |Δ0|=$(round(norm(D0); digits = 3)) 가 구역 안 미래 목표 " *
              "$(N_GOALS) -> 0, 겹친 work disc $(N_OVER) -> " *
              "$(CB._count_future_work_overlaps(env; zone_keys = ZKEYS))"
    finally
        CB._apply_uniform_translation!(env, (-D0[1], -D0[2]))   # 정확한 되돌리기(이동은 합성된다)
    end
    after = _poses(env)
    for k in sort!(collect(keys(before)))
        @test after[k][1] ≈ before[k][1] atol = 1e-12
        @test after[k][2] ≈ before[k][2] atol = 1e-12
    end
    @test _hash(env) == h0
    @test CB._count_future_goals_in_zone(env; zone_keys = ZKEYS) == N_GOALS
    CB.clear_restriction_zones!()
end
