# =============================================================================
# smdp_common_resolve.jl — Task T13. 공통 MILP 재풀이가 **파이프라인의 성질**인가.
#
# 확정 설계(`.claude/CLAUDE.md` §⏳ 2026-08-20): 모든 팔 뒤에 **같은** 재풀이가 돌아야
# `Ĵ(a)` 비교가 팔의 성질이 된다. 한 팔만 다른 파이프라인을 타면 그 차이가 팔의 성질로
# 오독된다.
#
# 🔴 **계획서 Step 1 의 시험 스니펫을 그대로 못 쓴다** (2026-08-21 실측):
#   · `include("smdp_fixtures.jl")` — 그 파일은 **없다**(T12 보고서가 이미 지적했다).
#     T12 처럼 자립형으로 픽스처를 짓는다.
#   · `CB.validate(env.sched)` — **맨이름 `validate` 는 존재하지 않는다**
#     (`validate_tree`/`validate_embedded_tree`/`validate_sub_tree` 뿐, 셋 다 씬트리용).
#     그래서 "스케줄이 유효하다" 를 **진짜 불변식**으로 바꿨다: 비순환 + 진행도 보존.
#
#   julia +lts --project=. -e 'using ConstructionBots, Test; include("test/smdp_common_resolve.jl")'
# =============================================================================

using ConstructionBots, Test
import Random
import Graphs

const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# --- 씬 (SCENE-INCANTATION.md 정본, T12 와 동일) -------------------------------
const BASE = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t13resolve",
                                num_robots = 6, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))
CB.enable_battery!(BASE)
CB.enable_hazard!(BASE; seed = 7)

_fork(env) = (e = deepcopy(env); CB.rvo_rebuild!(e); e)

# 🔴 **비퇴화 스텝까지 전진시킨다** (T12 와 같은 규약). t = 0 에서 재면 `prog.closed` 가
#    비어 있어서 아래 [4] 의 "진행도 보존" 단언이 **공허**해진다(첫 판이 실제로 그랬다:
#    `!isempty(Set{Int64}())` 로 빨개졌고, 그게 이 전진을 넣은 이유다).
function _advance_to_nondegenerate!(env, maxstep::Int)
    for k in 1:maxstep
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        s = CB.simstate_of(env)
        if length(s.fleet) >= 2 && !isempty(CB.active_of(s)) && !isempty(s.prog.closed)
            return k
        end
    end
    return 0
end

const PROBE = _advance_to_nondegenerate!(BASE, 320)
PROBE > 0 || error("smdp_common_resolve: 320 스텝 안에 비퇴화 스텝이 없다 — 픽스처가 죽었다")

# 사건 하나를 만들어 ctx 를 얻는다 (T12 와 같은 경로).
const NL0 = CB.fault_action(; target = nothing, obstacle = false, clear = true)(BASE)
NL0 === nothing && error("smdp_common_resolve: fault 주입이 nothing 을 냈다")
const CTX0 = CB.event_context(BASE, NL0)
_fault_fixture() = (_fork(BASE), CTX0)

# 🔴 **진짜로 집행되는** 픽스처 (T12 의 구분을 그대로 승계한다). `_fault_fixture()` 는 모듈
#    상단의 사건 하나를 재사용하므로 `Replace` 가 실제로 집행되지 않을 수 있고, 그러면
#    "두 팔이 같은 상태를 낸다" 가 **팔의 성질이 아니라 픽스처의 성질**이 된다.
#    ⚠️ 남발 금지: `_faultable` 이 이미 고장난 로봇을 빼므로 6 대 함대에서 호출 상한이 있다.
function _fresh_fault_fixture()
    e  = _fork(BASE)
    nl = CB.fault_action()(e)
    nl === nothing && error("_fresh_fault_fixture: 후보 로봇이 남지 않았다")
    return (e, CB.event_context(e, nl))
end

@info "T13 픽스처" probe_step = PROBE n_closed = length(CB.simstate_of(BASE).prog.closed) ctx_agent = string(CTX0.agent)

@testset "🔴 T13 — 공통 MILP 재풀이" begin

    # --- [1] 모든 팔이 재풀이를 **정확히 한 번** 부른다 -------------------------
    #     0 이면 안 도는 것이고, 2 면 이중 재풀이다(CLAUDE.md 가 경고한 '중복 호출').
    @testset "[1] 모든 팔이 재풀이를 정확히 한 번 부른다" begin
        for a in (0, 1)
            env, ctx = _fault_fixture()
            CB.RESOLVE_CALLS[] = 0
            CB.apply_action!(env, ctx, a)
            @test CB.RESOLVE_CALLS[] == 1
        end
    end

    # --- [2] 재풀이 자체가 살아 있는가 (스텁 탐지) -----------------------------
    @testset "[2] 스텁이 아니다 — MILP 가 실제로 돈다" begin
        env, _ = _fault_fixture()
        r = CB.resolve_assignments!(env)
        @info "T13 resolve_assignments!" status = r.status ran_milp = r.ran_milp n_reassigned = r.n_reassigned
        @test r.status === :resolved                 # infeasible/commit_failed 가 아니다
        @test r.ran_milp == true
        @test !haskey(r, :stub)                      # 🔴 옛 스텁의 필드가 남아 있으면 죽는다
        @test r.n_reassigned >= 0

        # ⚠️ 항진성 경고 — CLAUDE.md: 후보 간선이 0 이면 재풀이가 아무것도 안 바꾼다.
        #    `ran_milp` 은 증거가 아니다(설계상 모든 팔에서 true). 증거는 n_reassigned 다.
        if r.n_reassigned == 0
            @info "🔴 n_reassigned == 0 — 이 픽스처에서 재풀이는 **항진적**이다. " *
                  "'재풀이를 켰다' 를 '계획이 바뀌었다' 로 읽지 말 것 (CLAUDE.md §⏳ 2026-08-20)."
        end
    end

    # --- [3] 결정론 -------------------------------------------------------------
    @testset "[3] 재풀이는 결정론적이다" begin
        env1, ctx1 = _fault_fixture(); CB.apply_action!(env1, ctx1, 1)
        env2, ctx2 = _fault_fixture(); CB.apply_action!(env2, ctx2, 1)
        h1 = CB.state_hash(CB.simstate_of(env1))
        h2 = CB.state_hash(CB.simstate_of(env2))
        @test h1 == h2
    end

    # --- [3b] 🔴 두 팔이 실제로 구별되는가 — **집행 여부와 함께** 잰다 ----------
    #     CLAUDE.md 살아 있는 결함 4: "조합 팔은 정보량이 0이었다 — 65/65 instance 에서
    #     5≡4, 6≡2". 같은 모양이 재발했는지 보려면 **팔이 실제로 집행됐는지**를 같이 봐야
    #     한다. 집행이 안 된 팔이 NOOP 과 같은 것은 팔의 성질이 아니라 픽스처의 성질이다.
    @testset "[3b] 팔의 구별 가능성 (판정이 아니라 계측)" begin
        eR, cR = _fresh_fault_fixture()
        rR = CB.apply_action!(eR, cR, 1)
        hR = CB.state_hash(CB.simstate_of(eR))

        eN, cN = _fresh_fault_fixture()
        rN = CB.apply_action!(eN, cN, 0)
        hN = CB.state_hash(CB.simstate_of(eN))

        @info "T13 팔 구별 (fresh 픽스처)" replace = (outcome = rR.outcome, enacted = rR.enacted, n_reassigned = rR.resolve.n_reassigned) noop = (outcome = rN.outcome, enacted = rN.enacted, n_reassigned = rN.resolve.n_reassigned) differ = (hR != hN)

        # 계측이 성립하는 조건만 단언한다(= 두 팔 다 파이프라인을 끝까지 탔다).
        @test rR.resolve.status === :resolved
        @test rN.resolve.status === :resolved

        if rR.enacted && hR == hN
            @info "🔴 Replace 가 **집행됐는데도** NOOP 과 같은 상태다 — CLAUDE.md 살아 있는 " *
                  "결함 4(조합 팔 정보량 0)와 같은 모양이다. 게이트 N-G7 이 그 재발을 막는 자리."
        elseif !rR.enacted
            @info "ℹ️ Replace 가 집행되지 않았다(outcome=$(rR.outcome)) — 두 팔이 같은 것은 " *
                  "**팔의 성질이 아니라 이 픽스처의 성질**이다. 구별 가능성 주장에 쓰지 말 것."
        end
    end

    # --- [4] 스케줄 불변식 — 계획서의 `validate` 를 대체한다 --------------------
    @testset "[4] 재풀이가 스케줄을 유효하게 남긴다" begin
        env, ctx = _fault_fixture()
        closed_before = copy(CB.simstate_of(env).prog.closed)
        CB.apply_action!(env, ctx, 1)
        s_after = CB.simstate_of(env)

        # (a) 비순환 — 순환이면 스케줄이 실행 불가다
        @test !Graphs.is_cyclic(env.sched)
        # (b) 🔴 진행도 보존 — `commit_respec!(...; resume = true)` 의 계약이다.
        #     resume=false 로 새면 닫힌 집합이 날아가고 롤아웃이 처음부터 다시 짓는다.
        @test closed_before ⊆ s_after.prog.closed
        # 음성 대조: 위 포함관계가 공허하지 않은가(닫힌 것이 실제로 있다)
        @test !isempty(closed_before)
    end

    # --- [5] 🔴 실패를 조용히 넘기지 않는다 -------------------------------------
    @testset "[5] 재풀이 실패는 조용히 지나가지 않는다" begin
        # `resolve_assignments!` 가 :infeasible 을 내면 `apply_action!` 이 죽어야 한다.
        # 실제 infeasible 을 만들기 어려우므로 **반환 계약**을 직접 건다:
        # 세 판정 중 하나여야 하고, 성공이 아닌 값은 호출자가 반드시 보게 되어 있다.
        env, _ = _fault_fixture()
        r = CB.resolve_assignments!(env)
        @test r.status in (:resolved, :infeasible, :commit_failed)
        # 그리고 apply_action! 의 소스가 그 판정을 실제로 검사하는가(항진 방지).
        src = read(joinpath(@__DIR__, "..", "src", "smdp", "generative.jl"), String)
        @test occursin("res.status === :resolved || error(", src)
    end
end
