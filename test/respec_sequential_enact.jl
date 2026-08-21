# =============================================================================
# test/respec_sequential_enact.jl  —  Task C1 게이트 (독립 실행. runtests.jl 에 넣지 않는다)
#
#   julia +lts --project=. test/respec_sequential_enact.jl
#
# 🔴 무엇을 재는가: `maybe_respecify!` 가 **제약 벡터의 모든 원소를 집행**하는가.
#    고치기 전의 구현은 first-match-wins 였다 — 일곱 개의 `if _is_*(proposal)` 분기가
#    각각 `return` 해서, `[RelocateBuild(:zone), SwapBattery(r)]` 는 첫 분기만 먹고
#    나머지를 **조용히** 버렸다(replan.jl:426·452·529·635·679·798·898).
#
# 🔴 음성 대조(Global Constraint: "게이트를 짤 때는 음성 대조를 먼저 실측한다"):
#    testset [1] 은 **집행 전 코드에서 실제로 빨간불이 났다** — 반환 Symbol 이 아니라
#    `env`(그리고 프로세스 전역 배터리 함대) 위의 **관측 가능한 효과 둘**을 단언하기 때문이다.
#    실측한 RED 는 task-C1-report.md 에 그대로 붙여 뒀다. 새 전역
#    (`ENACT_ORDER_LOG`/`LAST_ENACT_REPORT`)을 쓰는 단언은 [2] 이후로 미뤄 뒀다 —
#    [1] 이 UndefVarError 가 아니라 **효과 부재**로 실패해야 증거가 되기 때문이다.
#
# 씬 생성은 SCENE-INCANTATION.md 의 정본을 따른다(계획서 스니펫이 아니라).
#   · `return_env_before_sim = true` 없이 부르면 판을 끝까지 굴리고 Tuple 을 돌려준다.
#   · `write_results = false` · `rng = MersenneTwister(1)` · `n_spare_per_pool = 2`.
#   · 호출 순서는 step_environment! → update_planning_cache! → set_sim_step!.
#
# ⚠️ `enable_hazard!` 는 **일부러 안 켠다.** 이 시험은 확률적 고장이 필요 없고,
#    `_pick_active_robot` 이 `Set` 을 순회하는 알려진 재현성 결함(.claude/CLAUDE.md ★1)을
#    끌어들이면 시드 고정 재현이 깨진다. 방전은 SoC 를 직접 찍어서 만든다(결정적).
# =============================================================================
using ConstructionBots, Test
import Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "respec_seq_enact",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)

for k in 1:120                      # SCENE-INCANTATION §2: 120 스텝이 비퇴화 구간
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(k)
end

# --- 결정적 픽스처 --------------------------------------------------------------
# zone: root 자신의 하역 목표들 위에 심는다(조립체별 재적치로는 못 비키는 배치 = whole-build
# 평행이동이 존재하는 이유). tools/tests.jl:test_relocatebuild_parse 의 검증된 레시피 그대로.
place_zone!() = begin
    # 🔴 `root_deposit_goals` 는 `assembly_components(...)` 를 **정렬 없이** 순회한다
    #    (restage_zone.jl:346). 부동소수 덧셈은 결합법칙이 성립하지 않으므로 순회 순서가 달라지면
    #    평균의 마지막 비트가 갈리고, 그러면 구역 중심이 런마다 미세하게 달라진다. 정렬해서 더한다
    #    (Global Constraint: 모든 Set/Dict 는 정렬해서 쓴다 / 시드 고정 = 완전 재현).
    gs = sort(CB.root_deposit_goals(env); by = g -> (Float64(g[1]), Float64(g[2])))
    zc = isempty(gs) ? [1.5, 0.96] : sum(gs) ./ length(gs)
    CB.clear_restriction_zones!()
    CB.add_restriction_zone!(:zone, zc, 2.5)
end
in_zone() = CB._count_future_goals_in_zone(env; zone_keys = [:zone])
soc_of(r) = CB.BATTERY_FLEET[].soc[r]

# 로봇 id 는 **정렬해서** 고른다 — Set/Dict 순회 순서에 기대면 런마다 갈린다(Global Constraint).
const RID = first(sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string))

# maybe_respecify! 의 두 번째 위치인자는 **OOD 큐**다(제안이 아니다 — 브리프의 오류).
# 타입 있는 제안을 직접 집행시키려면 `producer` 이음새를 쓴다(tools/tests.jl:379 와 동일).
enact!(prop) = CB.maybe_respecify!(
    env, CB.OODQueue(String["synthetic multi-constraint proposal"]);
    producer = (_env, _ev) -> prop)

# =============================================================================
@testset "🔴 [1] 두 제약이 둘 다 집행된다 (음성 대조: 여기가 RED 였다)" begin
    place_zone!()
    CB.BATTERY_FLEET[].soc[RID] = 0.2

    before_in_zone = in_zone()
    before_soc     = soc_of(RID)
    # 사전조건: 두 팔 모두 **비퇴화 도메인**을 갖는다. 이게 깨지면 아래 단언이 항진명제가 된다.
    @test before_in_zone > 0
    @test before_soc < 1.0

    st = enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.RelocateBuild(:zone), CB.SwapBattery(RID)]))
    @info "[C1] status = $st"

    # 반환 Symbol 이 아니라 **엔진 위의 효과**를 잰다.
    @test in_zone() == 0             # RelocateBuild 가 먹었다(기하가 움직였다)
    @test soc_of(RID) == 1.0         # SwapBattery 도 먹었다  ← 고치기 전엔 0.2 로 남았다
    @test st === :admitted
end

# =============================================================================
@testset "[2] 집행 순서는 제안 순서가 아니라 _enact_rank 다" begin
    place_zone!()
    CB.BATTERY_FLEET[].soc[RID] = 0.3
    @test in_zone() > 0              # 도메인 비퇴화 재확인

    # 제안에는 배터리를 **먼저** 적었는데, 집행은 기하(rank 1) → 배터리(rank 5) 순이어야 한다.
    enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.SwapBattery(RID), CB.RelocateBuild(:zone)]))
    @test CB.ENACT_ORDER_LOG[] == [:relocate, :battery]
    @test in_zone() == 0
    @test soc_of(RID) == 1.0
end

# =============================================================================
@testset "[3] 제약마다 결과가 기록된다 — 조용한 건너뜀이 없다" begin
    place_zone!()
    CB.BATTERY_FLEET[].soc[RID] = 0.4
    enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.SwapBattery(RID), CB.RelocateBuild(:zone)]))
    rep = CB.LAST_ENACT_REPORT[]
    @test length(rep) == 2                                   # 제약 둘 → 집행 단위 둘
    @test [r.kind for r in rep] == [:relocate, :battery]      # 순서까지 기록된다
    @test all(r -> r.status isa Symbol, rep)
    @test sum(r.n for r in rep) == 2                          # 버려진 제약이 하나도 없다
end

# =============================================================================
@testset "[4] line-stop 이 걸리면 남은 제약을 집행하지 않는다 (Ruling 1)" begin
    # 🔴 `engage_fallback!` 은 **영구 전역 line-stop**(RESPEC_HOLD)이다. 그 뒤에 집행되는 제약은
    #    "영영 실행되지 않을 세계"를 편집한다 — 그렇게 만들어진 s 는 일어나지 않는 상태를 가리킨다.
    #    그래서 line-stop 이 **이 호출에서** 걸린 순간 남은 단위를 집행하지 않고 멈춘다.
    #    이 testset 은 short-circuit 이 없는 판(= 직전 커밋)에서 실제로 빨간불이 났다.
    place_zone!()
    CB.BATTERY_FLEET[].soc[RID] = 0.5
    @test CB.RESPEC_HOLD[] === false           # 사전조건: 아직 라인이 안 섰다
    before_soc = soc_of(RID)

    # 첫 단위(:ghost = 없는 구역)가 거부되며 engage_fallback! 을 부른다. 둘째 단위(배터리)는
    # 그 자체로는 **완벽히 집행 가능**하다 — 그래서 이 시험이 short-circuit 만을 잰다.
    st = enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.RelocateBuild(:ghost), CB.SwapBattery(RID)]))

    @test CB.RESPEC_HOLD[] === true            # 라인이 섰다
    @test st === :fallback                     # 집계가 아니라 short-circuit 이 정한다
    @test soc_of(RID) == before_soc            # 🔴 둘째 제약은 집행되지 **않았다**
    @test CB.ENACT_ORDER_LOG[] == [:relocate]  # 둘째 분기에 **진입조차** 안 했다

    # 그래도 조용히 사라지지는 않는다 — 건너뛴 단위도 명시적 status 로 보고된다.
    rep = CB.LAST_ENACT_REPORT[]
    @test length(rep) == 2
    @test rep[1].kind === :relocate && rep[1].status !== :admitted
    @test rep[2].kind === :battery  && rep[2].status === :skipped_line_stop
    @test sum(r.n for r in rep) == 2           # 제약 개수 불변식은 그대로

    CB.release_fallback!()
    @test CB.RESPEC_HOLD[] === false
end

# =============================================================================
@testset "[4b] 판정 어휘는 단일 진실원이고, 모르는 값은 조용히 안 넘어간다 (Ruling 2)" begin
    # 호출부의 화이트리스트가 새 Symbol 을 말없이 버리는 것을 막는 관문.
    @test :partial in CB.RESPEC_VERDICTS
    @test all(v -> v in CB.RESPEC_VERDICTS, (:disabled, :noop, :admitted, :rejected, :fallback))
    @test CB.assert_respec_verdict(:partial, "test") === :partial
    @test_throws ErrorException CB.assert_respec_verdict(:definitely_not_a_verdict, "test")
end

# =============================================================================
@testset "[5] 단일 제약의 반환값 계약은 안 바뀐다 (회귀)" begin
    CB.BATTERY_FLEET[].soc[RID] = 0.6
    st = enact!(CB.RespecProposal(CB.ConstraintSpec[CB.SwapBattery(RID)]))
    @test st === :admitted            # 옛 계약 그대로 — 집계 규칙은 N=1 에서 항등이다
    @test soc_of(RID) == 1.0
    @test length(CB.LAST_ENACT_REPORT[]) == 1

    # 빈 제안 = 절제. 옛 계약대로 :noop.
    @test enact!(CB.RespecProposal(CB.ConstraintSpec[])) === :noop

    # 🔴 Ruling 1(short-circuit)이 가장 깨뜨리기 쉬운 자리: **거부하며 line-stop 을 거는
    #    제약이 하나뿐일 때**. 이 경우 건너뛸 단위가 없으므로 short-circuit 은 발동하지 않고,
    #    반환은 집계 규칙의 N=1 항등에 따라 그 분기가 원래 내던 `:rejected` 여야 한다.
    #    (`:fallback` 으로 바뀌면 tools/e2e.jl · tools/tests.jl 의 기존 계약이 깨진다.)
    @test CB.RESPEC_HOLD[] === false
    st1 = enact!(CB.RespecProposal(CB.ConstraintSpec[CB.RelocateBuild(:ghost)]))
    @test st1 === :rejected                    # ← :fallback 이 아니다. N=1 항등 유지
    @test CB.RESPEC_HOLD[] === true            # 그래도 라인은 섰다(반환값과 별개의 사실)
    @test length(CB.LAST_ENACT_REPORT[]) == 1
    @test CB.LAST_ENACT_REPORT[][1].status === :rejected   # :skipped_line_stop 행이 없다
    CB.release_fallback!()
end

# =============================================================================
@testset "[6] 이미 멈춘 라인으로 들어오면 아무것도 집행하지 않는다 (Ruling 1 정정)" begin
    # 🔴 `RESPEC_HOLD[]` 는 **영구 latch** 다. `release_fallback!`(replan.jl:1459)만 풀 수 있는데
    #    production 에서 아무도 안 부른다. 그래서 런 중 fallback 이 한 번이라도 걸리면 그 뒤의
    #    **모든** `maybe_respecify!` 호출이 "이미 멈춘 라인" 위로 들어온다. 전이(latch 순간)만
    #    보던 초판은 그 구간에서 short-circuit 이 **영영 발동하지 않아** N 개 제약을 전부
    #    죽은 세계에 집행했다 — first-match-wins 보다 N 배 나쁘다. 지금은 **상태**를 본다.
    place_zone!()
    CB.BATTERY_FLEET[].soc[RID] = 0.7
    before_soc     = soc_of(RID)
    before_in_zone = in_zone()
    @test before_in_zone > 0                   # 도메인 비퇴화(항진명제 방지)
    @test before_soc < 1.0

    CB.engage_fallback!(env)                   # 앞 스텝이 라인을 세워 둔 상태를 재현
    @test CB.RESPEC_HOLD[] === true

    st = enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.RelocateBuild(:zone), CB.SwapBattery(RID)]))

    @test st === :fallback
    @test soc_of(RID)  == before_soc           # 🔴 엔진 효과 0
    @test in_zone()    == before_in_zone       # 🔴 엔진 효과 0
    @test CB.ENACT_ORDER_LOG[] == Symbol[]     # 어떤 분기에도 진입하지 않았다
    rep = CB.LAST_ENACT_REPORT[]
    @test length(rep) == 2
    @test all(r -> r.status === :skipped_line_stop, rep)
    @test sum(r.n for r in rep) == 2           # 그래도 전부 보고된다
    CB.release_fallback!()
    @test CB.RESPEC_HOLD[] === false
end

# =============================================================================
@testset "[7] 같은 zone 의 ForbidZone 은 RelocateBuild 에 흡수된다 (Ruling 2)" begin
    # 🔴 `_is_relocate_build` 의 **실측 도메인 규칙**(2026-08-03): 둘 다 실린 제안은 강한 지렛대
    #    하나만 쓴다. 순차 집행 초판은 우선순위만 지키고 **배타성**을 없애서, 이미 비워진 구역에
    #    `restage_all_blocked!` 를 한 번 더 돌렸다. 그게 :partial/:infeasible/:residual_blocked 를
    #    내면 engage_fallback! 로 가므로 — **성공적으로 옮긴 빌드가 잉여 둘째 단위 때문에 영구
    #    line-stop 될 수 있었다.** 흡수는 조용한 드롭이 아니다: 명시 status 로 기록된다.
    place_zone!()
    @test in_zone() > 0
    @test CB.RESPEC_HOLD[] === false
    st = enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.RelocateBuild(:zone), CB.ForbidZone(CB.AssemblyID(1), :zone)]))

    @test st === :admitted                     # 옛 동작 그대로(:partial 로 새지 않는다)
    @test in_zone() == 0
    @test CB.ENACT_ORDER_LOG[] == [:relocate]  # zone 분기에 **진입하지 않았다**
    @test CB.RESPEC_HOLD[] === false           # 잉여 단위가 라인을 세우지 못한다
    rep = CB.LAST_ENACT_REPORT[]
    @test length(rep) == 2
    @test rep[2].kind === :zone && rep[2].status === :subsumed_by_relocate
    @test sum(r.n for r in rep) == 2           # 불변식 유지 = 조용한 드롭이 아니다
end

# =============================================================================
@testset "[8] 하드 스펙과 섞인 DeprioritizeAgent 는 흡수된다 (Ruling 2)" begin
    # `_is_deprioritize` docstring 의 실측 규칙: 하드 스펙과 섞인 DeprioritizeAgent 는 옛 코드에서
    # "무해한 no-op" 이었다. 순차 집행이 그걸 **전면 MILP 재풀이 + commit** 으로 바꿔 버렸다.
    CB.BATTERY_FLEET[].soc[RID] = 0.8
    st = enact!(CB.RespecProposal(CB.ConstraintSpec[
        CB.SwapBattery(RID), CB.DeprioritizeAgent(RID, 2.0)]))
    @test st === :admitted
    @test soc_of(RID) == 1.0                   # 하드 스펙은 집행됐다
    @test CB.ENACT_ORDER_LOG[] == [:battery]   # deprioritize 분기(재풀이)에 진입하지 않았다
    rep = CB.LAST_ENACT_REPORT[]
    @test rep[2].kind === :deprioritize && rep[2].status === :subsumed_by_hard_spec
    @test sum(r.n for r in rep) == 2

    # 순수 soft 제안은 흡수되지 **않는다**(분류기 직접 검사 — MILP 재풀이 비용을 안 낸다).
    pure = CB.ConstraintSpec[CB.DeprioritizeAgent(RID, 2.0)]
    @test CB._subsumption(pure, pure) === nothing
    # 다른 zone 의 ForbidZone 은 흡수되지 않는다.
    other = CB.ConstraintSpec[CB.RelocateBuild(:zone), CB.ForbidZone(CB.AssemblyID(1), :other)]
    @test CB._subsumption(CB.ConstraintSpec[other[2]], other) === nothing
end

CB.clear_restriction_zones!()
