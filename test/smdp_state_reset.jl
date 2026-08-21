# =============================================================================
# smdp_state_reset.jl — 롤아웃 경계 리셋 (사용자 결정 D-13 의 단서)
#
# 지키는 계약 넷:
#   [1] 커버리지     — `:state`/`:split` 전역 **전부**가 리셋 대상이거나, 모듈 밖이라고
#                      **명시적으로** 선언돼 있다. 손 목록이 뒤처지는 사고를 구조적으로 막는다.
#   [2] :setup 불가침 — 특히 `RHO`·`DRAIN_DT`. 리셋이 이걸 되돌리면 T10 의 적합값이 매
#                      롤아웃마다 버려지고 λ 가 **에러 없이** 틀린다.
#   [3] 실제로 되돌린다 — `RESPEC_HOLD` 래치를 포함해서.
#   [4] 조용한 폴백 금지 — 기준선 없이 리셋하면 **죽는다**.
#
# 🔴 이 파일이 존재하는 이유는 실측이다. 시험을 **파일당 별도 프로세스**로 돌리면 22/22 인데
#    **한 프로세스**에서 연달아 돌리면 5 개가 실패한다(`respec_grammar.jl` 이
#    `RESPEC_HOLD = true` 를 남긴다). MCTS 는 한 프로세스에서 굴리므로 그 우회를 못 쓴다.
# =============================================================================

using ConstructionBots, Test

const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# `run_demo.jl`/`policy.jl` 의 스크립트 지역 전역 — 이 모듈에서는 되돌릴 수 없다.
# 🔴 이 목록이 **커지면 이 시험이 죽는다**: 새 에피소드 상태가 모듈 밖에 생겼다는 뜻이고,
#    그러면 트리가 그것을 리셋하지 못한 채 돈다.
const KNOWN_OUT_OF_MODULE = Set([:ZONE_DECIDE_DEFERRED, :_DECISION_N, :_ZONE_CT])

@testset "🔴 D-13R — 롤아웃 경계 리셋" begin

    # --- [1] 커버리지: 표에서 유도되고, 빠짐이 없다 -----------------------------
    @testset "[1] :state/:split 전부가 리셋 대상이거나 명시적으로 모듈 밖이다" begin
        declared = Set(k for (k, v) in CB.STATE_GLOBALS if v === :state || v === :split)
        inside   = Set(CB.resettable_state_globals())
        outside  = Set(CB.unresettable_state_globals())

        @test isempty(intersect(inside, outside))          # 분할이다
        @test union(inside, outside) == declared           # 빠짐이 없다
        @test !isempty(inside)                             # 항진 방지

        # 모듈 밖 목록이 **정확히** 알려진 셋이어야 한다. 늘어나면 여기서 죽는다.
        if outside != KNOWN_OUT_OF_MODULE
            @info "모듈 밖 :state 전역이 바뀌었다 — 트리가 리셋 못 하는 상태가 생겼는지 볼 것" outside KNOWN_OUT_OF_MODULE
        end
        @test outside == KNOWN_OUT_OF_MODULE
    end

    # --- [2] :setup 불가침 -------------------------------------------------------
    @testset "[2] :setup 은 안 건드린다 (RHO·DRAIN_DT 의 적합값이 살아남는다)" begin
        @test CB.STATE_GLOBALS[:RHO] === :setup
        @test CB.STATE_GLOBALS[:DRAIN_DT] === :setup
        @test !(:RHO in CB.resettable_state_globals())
        @test !(:DRAIN_DT in CB.resettable_state_globals())

        # 🔴 기준선 자신이 리셋 대상이면 **순환**이다 — 리셋이 기준선을 기준선으로 되돌린다.
        #    오늘은 :setup 이라 안 걸리지만, 그 안전이 **분류 하나에 의존**한다. 못박는다.
        @test CB.STATE_GLOBALS[:_STATE_BASELINE] === :setup
        @test !(:_STATE_BASELINE in CB.resettable_state_globals())

        old_rho, old_drain = CB.RHO[], CB.DRAIN_DT[]
        try
            CB.RHO[] = 1.234                      # T10 이 적합한 값을 흉내
            CB.DRAIN_DT[] = 0.025
            CB.capture_state_baseline!()
            CB.reset_state_globals!()
            @test CB.RHO[] == 1.234               # 🔴 리셋이 이걸 되돌리면 λ 가 조용히 틀린다
            @test CB.DRAIN_DT[] == 0.025
        finally
            CB.RHO[], CB.DRAIN_DT[] = old_rho, old_drain
        end
    end

    # --- [3] 실제로 되돌린다 ------------------------------------------------------
    @testset "[3] RESPEC_HOLD 래치와 컨테이너가 기준선으로 돌아온다" begin
        was_hold = CB.RESPEC_HOLD[]
        try
            CB.RESPEC_HOLD[] = false
            CB.RESTRICTION_ZONES[] = Dict{Symbol,Any}()
            n = CB.capture_state_baseline!()
            @test n == length(CB.resettable_state_globals())

            # 롤아웃이 세계를 더럽힌다
            CB.RESPEC_HOLD[] = true                                   # ← D-13 의 영구 래치
            CB.SNAP_COUNT[] += 7
            push!(CB.WEDGE_EDGES[], (99, 100))
            snap_before = CB.SNAP_COUNT[]

            @test CB.RESPEC_HOLD[] == true                            # 정말 더러워졌다(항진 방지)
            @test (99, 100) in CB.WEDGE_EDGES[]

            CB.reset_state_globals!()

            @test CB.RESPEC_HOLD[] == false                           # 🔴 래치가 풀렸다
            @test !((99, 100) in CB.WEDGE_EDGES[])
            @test CB.SNAP_COUNT[] != snap_before
        finally
            CB.RESPEC_HOLD[] = was_hold
        end
    end

    # --- [3b] 기준선은 얕은 참조가 아니다 ----------------------------------------
    @testset "[3b] 기준선이 깊은 복사다 (얕으면 리셋이 무동작이 된다)" begin
        was_hold = CB.RESPEC_HOLD[]
        try
            CB.RESPEC_HOLD[] = false
            empty!(CB.WEDGE_EDGES[])
            CB.capture_state_baseline!()
            push!(CB.WEDGE_EDGES[], (1, 2))       # 기준선이 같은 객체를 참조하면 여기서 오염된다
            CB.reset_state_globals!()
            @test isempty(CB.WEDGE_EDGES[])       # 🔴 얕은 복사였다면 (1,2) 가 남는다
        finally
            CB.RESPEC_HOLD[] = was_hold
        end
    end

    # --- [4] 조용한 폴백 금지 -----------------------------------------------------
    @testset "[4] 기준선 없이 리셋하면 죽는다" begin
        saved = CB._STATE_BASELINE[]
        try
            CB._STATE_BASELINE[] = nothing
            @test CB.state_baseline_captured() == false
            @test_throws ErrorException CB.reset_state_globals!()
        finally
            CB._STATE_BASELINE[] = saved
        end
    end
end
