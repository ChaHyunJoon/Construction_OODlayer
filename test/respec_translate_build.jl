# =============================================================================
# test/respec_translate_build.jl — Task C3 게이트: `TranslateBuild` 원시연산 (L2-b)
#
#   julia +lts --project=. test/respec_translate_build.jl
#   🔴 runtests.jl 에 싣지 않는다 (Global Constraint: SMDP 계열은 독립 프로세스).
#
# 🔴 이 시험이 증명해야 하는 것 하나: **`TranslateBuild(dx, dy)` 가 빌드를 실제로 옮긴다.**
#    "제약이 파싱된다" 는 아무것도 증명하지 않는다 — 이 레포는 정확히 그 실패 모양
#    (조용한 no-op 을 초록으로 읽기)에 이미 여러 번 데였다. 그래서 측정 대상은 반환 Symbol 이
#    아니라 **조립체 기하**(`simstate_of(env).geo.poses`)와 그 위의 `state_hash` 다.
#
# 🔴 왜 `geo.poses` 인가 (Task R2 실측, src/smdp/observe.jl:100-116):
#    `poses` 의 출처는 `AssemblyComplete.start_config` 이고, 그것이 `_apply_uniform_translation!`
#    (restage_zone.jl:610-624) 이 **무조건** 옮기는 값이다. 씬트리 출처는 드리프트가
#    `default_robot_radius()` 미만이면 `_resync_scene_drift!` 가 아예 안 건드려서 **작은 Δ 가
#    조용히 사라진다.** 그래서 아래 [5] 가 **로봇 반지름보다 작은 Δ** 를 따로 잰다 — 그 축이
#    죽으면 작은 TranslateBuild 가 `s` 에서 NOOP 과 구분 불가능해진다.
#
# 🔴 씬 생성은 SCENE-INCANTATION.md 가 정본이다(계획서 스니펫이 아니라):
#    `return_env_before_sim = true` 없이 부르면 판을 끝까지 굴리고 `Tuple` 을 돌려준다.
#    `write_results = false` · `rng = MersenneTwister(1)` · `n_spare_per_pool = 2`.
#    호출 순서는 step_environment! → update_planning_cache! → set_sim_step!.
#    ⚠️ **스텝 수를 남의 표에서 베끼지 않는다** — SCENE-INCANTATION §2 의 이력이 그 실수를 두 번
#    기록했다. 아래 `_probe_step!` 이 **이 픽스처에서** 이 시험의 도메인 넷이 전부 비퇴화가 되는
#    스텝을 직접 찾고, 그 값을 찍고, 단언 자리에서 다시 확인한다.
#
# ⚠️ 브리프와 다른 것(전부 보고서에 기록):
#    · `test/smdp_fixtures.jl` / `_zone_fixture()` / `_assembly_poses()` 는 이 브랜치에 **없다**.
#      헬퍼를 이 파일 안에 자족적으로 둔다(test/respec_grammar.jl 과 같은 규율).
#    · `translate_clears_zones` · `verify_translate` 는 **Task C4 가 만든다**(브리프 addendum 3).
#      그 둘을 요구하는 단언은 C4 로 넘기고, 여기서는 이미 있는 `_count_future_goals_in_zone`
#      으로 같은 사실을 잰다.
#    · 브리프는 Δ=0 에서 `:fallback` 을 기대하지만, 같은 브리프의 구현 스니펫은 `:rejected` 를
#      돌려준다(자가당착). C1 의 `_aggregate_enact` 는 N=1 에서 항등이므로 실제 값은 `:rejected` 다.
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
import JSON3
using LinearAlgebra: norm
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "respec_translate",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 3)          # simstate_of 는 HAZARD_STATE 없이는 error 로 죽는다

# --- 이 시험의 도메인. 넷 다 비퇴화여야 아래 단언들이 항진명제가 아니다 ----------------
#   n_poses      geo.poses 가 실제로 조립체를 담는가        (0 이면 [4][5] 가 공집합 순회 = 항진)
#   n_staging    _apply_uniform_translation! 이 옮길 대상    (0 이면 이동이 조용한 no-op)
#   n_discs      _future_work_discs (구역 baseline 의 정의역) (0 이면 _find_min_translation 이 [0,0])
#   frontier     active_set > 0 ∧ **0 < closed_set < nv**    (퇴화한 세계를 재지 않는다)
# 🔴 `n_closed > 0` 을 **요구한다** — 편의가 아니라 이 시험의 정의역이다. 집행 분기가
#    `reset_cache_resume!(env.cache, env.sched)` 를 부르는데, closed_set 이 비어 있으면 그
#    "재개"가 항등이라 **아무것도 검증하지 않는다**(빈 과거를 다시 세우는 것과 같다).
#    실측: 이 조건이 없으면 `_probe_step!` 이 **0** 을 돌려준다(한 번도 안 굴린 판) — 그래서
#    조건을 적어 두지 않으면 이 시험은 조용히 시작 상태만 잰다.
function _domain(env)
    n_poses = count(v -> CB.matches_template(CB.AssemblyComplete, CB.get_node(env.sched, v).node),
                    Graphs.vertices(env.sched))
    return (n_poses    = n_poses,
            n_staging  = length(env.staging_circles),
            n_discs    = length(CB._future_work_discs(env)),
            n_active   = length(env.cache.active_set),
            n_closed   = length(env.cache.closed_set),
            nv         = Graphs.nv(env.sched))
end
_nondegenerate(d) = d.n_poses > 0 && d.n_staging > 0 && d.n_discs > 0 &&
                    d.n_active > 0 && 0 < d.n_closed < d.nv

"이 픽스처에서 도메인 넷이 전부 비퇴화가 되는 스텝을 **직접 찾는다**(남의 표를 안 베낀다)."
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
@info "[C3] 실측한 probe step = $(PROBE_STEP)  도메인 = $(DOM)"

const RR = Float64(CB.default_robot_radius())

_poses(env) = CB.simstate_of(env).geo.poses
_hash(env)  = CB.state_hash(CB.simstate_of(env))

# maybe_respecify! 의 두 번째 위치인자는 **OOD 큐**다(제안이 아니다 — 브리프의 오류, C1 이 이미 기록).
# 타입 있는 제안을 직접 집행시키려면 `producer` 이음새를 쓴다.
enact!(prop) = CB.maybe_respecify!(
    env, CB.OODQueue(String["synthetic TranslateBuild proposal"]);
    producer = (_env, _ev) -> prop)
_prop(cs...) = CB.RespecProposal(CB.ConstraintSpec[cs...])

# 스텁 id_resolver — 파서 시험용(씬 없이 돈다).
const _RID = CB.RobotID(1)
_resolver(s::AbstractString) = s == "GHOST" ? error("unknown id $s") : _RID
_parse(d) = CB._parse_proposal(JSON3.read(JSON3.write(Dict("constraints" => [d]))), "stub";
                               id_resolver = _resolver)

# =============================================================================
@testset "[0] 픽스처가 비퇴화다 (아래 모든 단언의 전제조건)" begin
    @test _nondegenerate(DOM)
    @test DOM.n_poses > 0
    @test DOM.n_staging > 0
    @test DOM.n_discs > 0
    @test DOM.n_active > 0
    @test 0 < DOM.n_closed < DOM.nv   # 빌드가 실제로 진행됐다(재개가 항등이 아니다)
    @test PROBE_STEP > 0
    @test !CB.RESPEC_HOLD[]          # 라인이 안 멈춰 있다 — 멈춘 라인 위에서는 아무것도 집행 안 된다
    @test RR > 0
end

@testset "[1] 타입 — TranslateBuild(dx, dy) <: ConstraintSpec, 비유한 Δ 는 죽는다" begin
    c = CB.TranslateBuild(3.0, -1.5)
    @test c isa CB.ConstraintSpec
    @test c.dx == 3.0 && c.dy == -1.5
    @test CB.TranslateBuild(1, 2) isa CB.TranslateBuild        # Real 승격
    # 🔴 조용한 폴백 금지: 비유한 Δ 는 **가장 싼 표면**(생성자)에서 죽는다. 클램프 없음, 기본값 없음.
    @test_throws ErrorException CB.TranslateBuild(NaN, 0.0)
    @test_throws ErrorException CB.TranslateBuild(0.0, NaN)
    @test_throws ErrorException CB.TranslateBuild(Inf, 0.0)
    @test_throws ErrorException CB.TranslateBuild(0.0, -Inf)
end

@testset "[2] 컴파일러 — SPATIAL 이라 MILP 행을 0 개 더한다 (닫힌 합집합 계약)" begin
    @test hasmethod(CB.compile_constraint!, Tuple{Any,Any,Any,Any,Any,CB.TranslateBuild})
    @test CB.compile_constraint!(nothing, nothing, nothing, nothing, nothing,
                                 CB.TranslateBuild(1.0, 1.0)) == 0
    @test CB.referenced_ids(CB.TranslateBuild(1.0, 1.0)) == ()   # 특정 노드를 안 지목
end

@testset "[3] 파서 — emit 표면에서 왕복하고, 망가진 입력은 죽는다" begin
    p = _parse(Dict("kind" => "TranslateBuild", "dx" => 1.5, "dy" => -2.25))
    @test p isa CB.RespecProposal
    @test length(p.constraints) == 1
    @test p.constraints[1] === CB.TranslateBuild(1.5, -2.25)
    @test "TranslateBuild" in CB.EMITTABLE_KINDS
    # 필드 누락·비유한 값은 조용히 기본값으로 안 채운다
    @test_throws Exception _parse(Dict("kind" => "TranslateBuild", "dx" => 1.0))
    @test_throws Exception _parse(Dict("kind" => "TranslateBuild", "dy" => 1.0))
    @test_throws Exception _parse(Dict("kind" => "TranslateBuild", "dx" => "NaN", "dy" => 1.0))
end

@testset "🔴 [4] TranslateBuild 가 빌드를 **정확히 그 Δ 만큼** 옮긴다 (측정)" begin
    @test !CB.RESPEC_HOLD[]
    before = _poses(env)
    h0 = _hash(env)
    @test length(before) == DOM.n_poses && !isempty(before)   # 공집합 순회 = 항진명제 방지

    st = enact!(_prop(CB.TranslateBuild(3.0, -1.5)))
    @test st === :admitted

    after = _poses(env)
    @test keys(after) == keys(before)
    for k in sort!(collect(keys(before)))
        @test after[k][1] ≈ before[k][1] + 3.0 atol = 1e-9
        @test after[k][2] ≈ before[k][2] - 1.5 atol = 1e-9
        @test after[k][3] ≈ before[k][3]       atol = 1e-9     # z 는 안 건드린다(평면 이동)
    end
    # 🔴 s 에 흔적이 남는가 — 남지 않으면 MCTS 트리에서 NOOP 과 병합된다
    @test _hash(env) != h0
    # 집행 회계: 단위 하나, 조용히 버려진 제약 없음
    @test [(r.kind, r.status) for r in CB.LAST_ENACT_REPORT[]] == [(:translate, :admitted)]
    @test sum(r.n for r in CB.LAST_ENACT_REPORT[]) == 1
    @test CB.ENACT_ORDER_LOG[] == [:translate]
end

@testset "🔴 [5] 로봇 반지름보다 **작은** Δ 도 보인다 (씬트리 출처였다면 사라진다)" begin
    @test !CB.RESPEC_HOLD[]
    δ = 0.2 * RR
    @test 0.0 < δ < RR                       # 이 시험이 주장하는 바로 그 구간인지 먼저 확인
    before = _poses(env)
    h0 = _hash(env)
    # 음성 대조: 같은 Δ 를 **씬트리에서** 재면 사라진다(R2 실측). 씬 본체 위치를 같이 잰다.
    scene_before = Dict(CB.node_id(n) => Vector{Float64}(CB.project_to_2d(
                            CB.global_transform(n).translation))
                        for n in CB.get_nodes(env.scene_tree)
                        if CB.matches_template(CB.RobotNode, n))
    @test !isempty(scene_before)

    st = enact!(_prop(CB.TranslateBuild(δ, 0.0)))
    @test st === :admitted

    after = _poses(env)
    for k in sort!(collect(keys(before)))
        @test after[k][1] ≈ before[k][1] + δ atol = 1e-12
        @test after[k][2] ≈ before[k][2]     atol = 1e-12
    end
    @test _hash(env) != h0                   # 🔴 sub-robot-radius Δ 가 state_hash 에 보인다
    scene_after = Dict(CB.node_id(n) => Vector{Float64}(CB.project_to_2d(
                           CB.global_transform(n).translation))
                       for n in CB.get_nodes(env.scene_tree)
                       if CB.matches_template(CB.RobotNode, n))
    n_moved = count(k -> norm(scene_after[k] .- scene_before[k]) > 1e-9, sort!(collect(keys(scene_before)); by = string))
    @info "[C3] sub-radius Δ=$(round(δ; digits = 4)) (RR=$(round(RR; digits = 4))): " *
          "poses 전부 이동, 씬 로봇 중 이동한 것 = $(n_moved)/$(length(scene_before))"
end

@testset "🔴 [6] Δ = 0 은 **거부**된다 (조용한 no-op 방지) — :noop 과 구분된다" begin
    @test !CB.RESPEC_HOLD[]
    before = _poses(env)
    h0 = _hash(env)
    st = enact!(_prop(CB.TranslateBuild(0.0, 0.0)))
    @test st === :rejected
    @test [(r.kind, r.status) for r in CB.LAST_ENACT_REPORT[]] == [(:translate, :rejected)]
    @test _poses(env) == before
    @test _hash(env) == h0
    @test !CB.RESPEC_HOLD[]                  # 문법 결함은 라인을 영구정지시키지 않는다
    # 🔴 음성 대조: "절제"(빈 제약) 는 :noop 이다. 둘이 같은 값이면 이 시험은 아무것도 안 잰다.
    @test enact!(CB.RespecProposal(CB.ConstraintSpec[])) === :noop
end

@testset "🔴 [7] 여러 TranslateBuild 가 **전부** 집행된다 (C1 계약 · 이동은 합성된다)" begin
    @test !CB.RESPEC_HOLD[]
    before = _poses(env)
    st = enact!(_prop(CB.TranslateBuild(1.0, 0.0), CB.TranslateBuild(0.0, 2.0)))
    @test st === :admitted
    after = _poses(env)
    for k in sort!(collect(keys(before)))
        @test after[k][1] ≈ before[k][1] + 1.0 atol = 1e-9
        @test after[k][2] ≈ before[k][2] + 2.0 atol = 1e-9
    end
    @test length(CB.LAST_ENACT_REPORT[]) == 2                     # 낱개 단위 둘 (배치 아님)
    @test sum(r.n for r in CB.LAST_ENACT_REPORT[]) == 2
    @test CB.ENACT_ORDER_LOG[] == [:translate, :translate]
end

@testset "🔴 [8] 옮길 대상이 없으면 거부한다 (missing target — 조용한 no-op 방지)" begin
    saved = copy(env.staging_circles)
    try
        empty!(env.staging_circles)
        before = _poses(env)
        st = enact!(_prop(CB.TranslateBuild(1.0, 1.0)))
        @test st === :rejected
        @test _poses(env) == before          # 아무것도 안 옮겼다
    finally
        merge!(env.staging_circles, saved)
    end
    @test length(env.staging_circles) == length(saved)
end

@testset "🔴 [9] baseline(_find_min_translation) 의 Δ 와 잴 수 있다" begin
    # `translate_clears_zones` · `verify_translate` 는 Task C4 가 만든다(브리프 addendum 3).
    # 그때까지 같은 사실을 이미 있는 `_count_future_goals_in_zone` 으로 잰다.
    @test !CB.RESPEC_HOLD[]
    gs = sort(CB.root_deposit_goals(env); by = g -> (Float64(g[1]), Float64(g[2])))
    @test !isempty(gs)                        # 정렬해서 더한다(부동소수 결합법칙 — 시드 고정 재현)
    zc = sum(gs) ./ length(gs)
    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:c3zone, zc, 2.5)
    try
        n_before = CB._count_future_goals_in_zone(env; zone_keys = [:c3zone])
        @test n_before > 0                    # 🔴 음성 대조: 안 움직이면 구역이 안 비켜진다
        Δ0 = CB._find_min_translation(env; zone_keys = [:c3zone])
        @test Δ0 !== nothing
        @test norm(Δ0) > 0.0
        st = enact!(_prop(CB.TranslateBuild(Δ0[1], Δ0[2])))
        @test st === :admitted
        @test CB._count_future_goals_in_zone(env; zone_keys = [:c3zone]) == 0
        @info "[C3] baseline Δ0 = $(round.(Δ0; digits = 3))  |Δ0| = $(round(norm(Δ0); digits = 3)); " *
              "구역 안 목표 $(n_before) -> 0"
    finally
        CB.clear_restriction_zones!()
    end
end
