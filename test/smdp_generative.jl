# =============================================================================
# test/smdp_generative.jl — Task T12, `src/smdp/generative.jl` (= `G(s,a)`)
#
#   julia +lts --project=. test/smdp_generative.jl
#
# 이 시험이 지키는 것 하나: **`G(s,a)` 가 진짜 respec 을 집행하고, 집행할 수 없을 때
# 조용한 NOOP 이 아니라 큰 소리로 죽는다.**
#
# 🔴 씬 생성은 `SCENE-INCANTATION.md` 의 정본을 따른다(`return_env_before_sim = true`,
#    호출 순서 step → update_planning_cache! → set_sim_step!).
# 🔴 SCENE-INCANTATION §2 의 규칙: **스텝 번호를 인용하지 않는다 — 발견한다.**
# 🔴 브리프가 시킨 `test/smdp_fixtures.jl` 은 **존재하지 않는다**(선행 태스크 넷이 실측).
#    그래서 이 파일은 자기 완결적이다 — 픽스처가 아래에 있다.
#
# 🔴 이 파일이 배제하는 구현들(음성 대조를 **먼저** 실측했다 — 보고서 §TDD 참조):
#   · legal_actions 가 리터럴 팔 번호     → 레지스트리 파생 관계만 검사
#   · apply_action! 이 문지기에서 NOOP    → 같은 자리에서 shim 의 침묵을 먼저 실측하고,
#                                            apply_action! 이 그 침묵을 상속하지 않음을 요구
#   · D-7 가드가 항진               → 예비를 비우면 빨강 / 안 비우면 초록, 양방향 실측
#   · assert_paired 가 항진         → 합성 stale s 로 에러 경로를 실제로 태운다
#   · rvo_rebuild! 없는 포크        → 두 갈래가 **같은** RVO 전역을 읽는 것을 수치로 못박는다
#   · rng 를 흘리는 generate        → 같은 시드 두 포크가 비트 동일 + 다른 시드는 갈린다
# =============================================================================
using ConstructionBots, Test
import Random
import Graphs
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
const BASE = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "t12gen",
                                num_robots = 6, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))
CB.enable_battery!(BASE)
CB.enable_hazard!(BASE; seed = 7)

const BP = CB.BATTERY_FLEET[].params
const P  = CB.HazardParams()

# -----------------------------------------------------------------------------
# 🔴 프로브 스텝을 **발견**한다. 못 찾으면 초록이 아니라 빨강이다.
#   비퇴화 조건: 함대 ≥ 2 · 활성 ≠ ∅ · 모드 ≥ 2종 · rate boundary 가 유한 양수
#   **그리고** 그 시점에 fault 를 주입하면 실제로 로봇 하나가 지목된다(ctx.agent ≠ nothing).
#   마지막 조건이 없으면 `action_to_proposal(ctx, 1)` 이 nothing 을 내고 이 파일의 절반이
#   "행동을 집행할 수 없다" 를 재게 된다 — 그건 이 시험이 재려는 것이 아니다.
# -----------------------------------------------------------------------------
function discover_probe(env, maxstep::Int)
    for k in 1:maxstep
        CB.step_environment!(env)
        CB.update_planning_cache!(env, 0.0)
        CB.set_sim_step!(k)
        s  = CB.simstate_of(env)
        ms = CB.modes_of(s, env)
        Δ  = CB.T_plan_next(s, env)
        if length(s.fleet) >= 2 && !isempty(CB.active_of(s)) &&
           length(unique(values(ms))) >= 2 && isfinite(Δ) && Δ > 0.0
            return k
        end
    end
    return 0
end

const PROBE = discover_probe(BASE, 320)
@testset "🔴 비퇴화 프로브 스텝이 범위 안에 존재한다" begin
    @test PROBE > 0
end
PROBE > 0 || error("smdp_generative: 320 스텝 안에 비퇴화 스텝이 없다 — 픽스처가 죽었다")

# --- fault 사건 하나를 심는다 ------------------------------------------------
# ⚠️ 실측으로 확인한 주입 함수: `CB.fault_action(; target, after, kwargs...)` 은 **클로저를
#    돌려주는 팩토리**다(`src/navigator/ood_truth.jl:202`). `env` 를 그 클로저에 먹여야
#    실제로 주입되고, 그때 `record_ood_truth!` 가 truth 로그에 NL 을 남긴다 —
#    `event_context` 가 읽는 것이 바로 그 로그다.
const NL0 = CB.fault_action()(BASE)
NL0 === nothing && error("smdp_generative: fault 주입이 nothing 을 냈다 — 픽스처가 죽었다")

# 🔴 shim 은 CB **밖**이 아니라 CB **안**에 로드된다(generative.jl 이 그 배선을 만든다).
#    그래서 여기서 다시 include 하지 않는다 — 두 벌이 생기면 `ActionRegistry` 도 두 벌이 되고,
#    "어휘의 단일 진실원" 이 시험 안에서부터 깨진다.
const CTX0 = CB.event_context(BASE, NL0)

@info "T12 발견한 프로브" step=PROBE nl=NL0 ctx_type=CTX0.type ctx_agent=string(CTX0.agent) valid_actions=CB.valid_actions(CTX0) hot_swap=CB.hot_swap_enabled() spares=Dict(k => length(v) for (k, v) in CB.SPARE_POOLS[])

@testset "🔴 픽스처가 퇴화하지 않았다" begin
    @test CTX0.type === :fault
    @test CTX0.agent !== nothing            # 없으면 아래 Replace 시험이 전부 무의미해진다
end

# --- 포크 --------------------------------------------------------------------
# 🔴 **분기 하나 = deepcopy + rvo_rebuild!.** R4 가 잰 `deepcopy_ms.median ∈ [5,50)` 은
#    **하한**이다 — deepcopy 는 세 항법 계층 중 둘만 격리하고 RVO2 는 프로세스 전역이다.
#    그래서 진짜 분기 비용은 `deepcopy + rvo_rebuild!` 이고, 포크 직후 반드시 부른다.
_fork(env) = (e = deepcopy(env); CB.rvo_rebuild!(e); e)

# 🔴 픽스처가 **둘**인 이유 — 실측한 전역 누수 때문이다.
#    `Replace` 를 실제로 집행하면 `RESTRICTION_ZONES[]` 에서 그 fault 의 구역이 지워지고
#    `SPARE_POOLS[]` 에서 예비 하나가 빠진다. 그 둘은 **모듈 전역**이라 `deepcopy(env)` 가
#    격리하지 못한다(이 파일 아래 "전역 누수" testset 이 그 수치를 기록한다). 그래서:
#      · `_fault_fixture()`       — **소비하지 않는** 시험용. 모듈 상단의 사건 하나를 재사용한다.
#      · `_fresh_fault_fixture()` — 진짜로 집행하는 시험용. 새 fault = 새 구역 + 새 대상.
#    ⚠️ 후자를 남발하면 안 된다: `_faultable` 이 이미 고장난 로봇을 후보에서 빼므로 6대 함대에서
#    호출 횟수에 상한이 있다. 그래서 필요한 세 자리에만 쓴다.
_fault_fixture() = (_fork(BASE), CTX0)

function _fresh_fault_fixture()
    e  = _fork(BASE)
    nl = CB.fault_action()(e)
    nl === nothing && error("_fresh_fault_fixture: fault 주입이 nothing 을 냈다 — " *
                            "후보 로봇이 남지 않았다(이미 고장난 로봇은 _faultable 이 뺀다)")
    return (e, CB.event_context(e, nl))
end

# =============================================================================
@testset "legal_actions_kind 는 레지스트리 **파생**이다" begin
    # 🔴 여기에 팔 번호를 리터럴로 적지 않는다. 검사할 것은 **파생 관계**뿐이다.
    AR = CB.ActionRegistry
    env0, _ = _fault_fixture()
    s0 = CB.simstate_of(env0)
    for k in (:fault, :battery, :zone)
        @test Set(CB.legal_actions_kind(k)) == Set(AR.kind_valid(String(k)))
        @test Set(CB.legal_actions_kind(k)) ⊆ Set(AR.IDS)
        @test 0 in CB.legal_actions(s0, k)                # NOOP 은 언제나 있다
    end
    # 음성 대조: 세 kind 가 전부 같은 집합이면 위 등호는 상수 구현으로도 통과한다.
    @test length(unique([Set(CB.legal_actions_kind(k)) for k in (:fault, :battery, :zone)])) >= 2
    # 오늘의 어휘를 **기준선으로만** 못박는다 — 갈리면 이 줄을 갱신하고 그 사실을 보고한다
    @test AR.VOCAB == "v3-4arms"
end

@testset "🔴 D-7 — 예비 재고가 메뉴를 좁히지 않는다" begin
    env, ctx = _fault_fixture()
    s = CB.simstate_of(env)
    @test 1 in CB.legal_actions(s, :fault)
    @test CB.legal_actions(s, :fault) == CB.legal_actions_kind(:fault)
    # 예비를 실제로 비워도 **메뉴는 안 좁아진다**(가정 위반은 메뉴가 아니라 에러로 드러난다)
    saved = deepcopy(CB.SPARE_POOLS[])
    try
        empty!(CB.SPARE_POOLS[])
        @test 1 in CB.legal_actions(CB.simstate_of(env), :fault)
    finally
        CB.SPARE_POOLS[] = saved
    end
end

@testset "🔴 D-7 가드 — 예비가 실제로 마르면 죽는다" begin
    env, ctx = _fault_fixture()
    # ⚠️ 브리프는 `_assert_spares_available(env, a::Int)` 에 `a == 1` 리터럴을 시켰다. 실제
    #    구현은 **제약 타입**(ReplaceAgent)으로 판정한다 — 재번호가 한 번 더 와도 안 갈린다.
    p_replace = CB.action_to_proposal(ctx, 1)
    p_swap    = CB.RespecProposal(CB.ConstraintSpec[CB.SwapBattery(ctx.agent)], "t12", "t12")
    # 양성 대조 먼저: 예비가 있는 지금은 가드가 통과해야 한다(가드가 항진적으로 죽지 않는다).
    @test CB._assert_spares_available(env, p_replace) === nothing
    saved = deepcopy(CB.SPARE_POOLS[])
    try
        empty!(CB.SPARE_POOLS[])                     # 가정을 고의로 깬다
        @test_throws ErrorException CB.apply_action!(env, ctx, 1)
        @test_throws ErrorException CB._assert_spares_available(env, p_replace)
        # 음성 대조의 반대쪽: 가드는 **창고 본체를 먹는 제약에만** 걸린다. 예비가 0 이어도
        # NOOP 과 SwapBattery 는 이 가드로 죽지 않는다(뭉툭한 전역 차단기가 아니라는 증거).
        @test CB._assert_spares_available(env, nothing) === nothing
        @test CB._assert_spares_available(env, p_swap) === nothing
    finally
        CB.SPARE_POOLS[] = saved
    end
end

@testset "🔴 문지기의 침묵을 상속하지 않는다 (조용한 NOOP 금지)" begin
    env, ctx = _fault_fixture()
    # (1) 음성 대조 — shim 은 **정말로 조용하다**. 이 줄이 초록이어야 아래 줄이 항진이 아니다.
    #     fault 사건에 SwapBattery(3) 를 시키면 `a in valid_actions(ctx) || return nothing`
    #     에서 그냥 nothing 이 나온다 = NOOP 팔과 구분 불가.
    @test !(3 in CB.valid_actions(ctx))
    @test CB.action_to_proposal(ctx, 3) === nothing
    # (2) 계약 — apply_action! 은 그 침묵을 상속하지 않는다.
    @test_throws ErrorException CB.apply_action!(env, ctx, 3)
    # (3) 어휘 밖 id 도 조용히 안 지나간다.
    @test_throws ErrorException CB.apply_action!(env, ctx, 99)
    @test_throws ErrorException CB.apply_action!(env, ctx, -1)
    # (4) 양성 대조 — 진짜로 집행 가능한 팔은 에러가 아니라 명시적 결과를 낸다.
    out = CB.apply_action!(env, ctx, 0)
    @test out.outcome === :noop
    @test out.enacted === false
end

@testset "🔴 이슈 F — s 와 env 가 짝인지 검사한다" begin
    env, ctx = _fault_fixture()
    s = CB.simstate_of(env)
    @test CB.assert_paired(s, env) === nothing
    # 음성 대조 — **합성** stale s. 그래프 수술이 실제로 정점을 재부여하든 말든,
    # 에러 경로 자체가 살아 있는지를 이 줄이 무조건 태운다(항진 방지).
    e_one = first(sort!(collect(s.g.edges)))
    s_stale = CB.SimState(g = CB.GraphBlock(edges = setdiff(s.g.edges, Set([e_one])),
                                            binding = s.g.binding),
                          geo = s.geo, fleet = s.fleet, prog = s.prog)
    @test_throws ErrorException CB.assert_paired(s_stale, env)
    # 🔴 `prog.closed` 는 **일부러** 대조하지 않는다 — 경량 레인이 `s` 만 전진시키므로
    #    (`sample_sojourn` 은 env 를 안 민다) 정상 사용에서 `s.prog.closed` 는 env 보다 앞선다.
    #    닫힌 집합을 짝 판정에 넣으면 그 정상 사용이 전부 빨개진다. 이것을 못박는다:
    s_ahead = CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet,
                          prog = CB.ProgBlock(closed = union(s.prog.closed,
                                                             Set(CB.active_of(s)))))
    @test CB.assert_paired(s_ahead, env) === nothing
end

@testset "행동이 진짜로 그래프/세계를 고친다" begin
    env, ctx = _fresh_fault_fixture()
    s0 = CB.simstate_of(env)
    out = CB.apply_action!(env, ctx, 1)               # Replace
    s1 = CB.simstate_of(env)
    @info "T12 Replace 집행 결과" outcome=out.outcome enacted=out.enacted branch=out.branch edges_changed=(s1.g.edges != s0.g.edges) binding_changed=(s1.g.binding != s0.g.binding) hash_changed=(CB.state_hash(s1) != CB.state_hash(s0))
    @test out.enacted === true
    @test CB.state_hash(s1) != CB.state_hash(s0)
    # ⚠️ **브리프의 `s1.g.binding != s0.g.binding` 은 경로 의존이다.** 오늘 기본값
    #    `hot_swap_enabled() == true` 에서 교체는 **정체성 보존**이라 RobotID 가 안 바뀌고,
    #    따라서 binding 이 안 바뀌는 것이 정상이다(그게 hot-swap 의 정의다). 그래서 여기서는
    #    "세계가 바뀌었다" 를 `state_hash` 로 재고, 재스탬프 경로는 아래 testset 이 따로 잰다.
end

@testset "NOOP 은 그래프를 안 고친다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    CB.apply_action!(env, ctx, 0)
    s1 = CB.simstate_of(env)
    @test s1.g.edges == s0.g.edges
    @test s1.g.binding == s0.g.binding
end

@testset "🔴 assert_paired 는 **진짜 그래프 편집**을 잡는다 (env 쪽 음성 대조)" begin
    # 위 "이슈 F" 의 음성 대조는 `s` 를 합성해 만들었다. 실제로 위험한 방향은 반대다 —
    # **env 가 바뀌고 `s` 가 낡는 것.** 그래서 여기서는 `env.sched` 를 진짜로 편집한다.
    # (이 env 는 이 testset 전용 갈래라 다른 시험으로 새지 않는다.)
    env, _ = _fault_fixture()
    s0 = CB.simstate_of(env)
    @test CB.assert_paired(s0, env) === nothing        # 편집 전에는 통과한다(항진 방지)
    u, v = first(sort!(collect(s0.g.edges)))
    @test Graphs.rem_edge!(env.sched, u, v)            # 편집이 실제로 먹었는가 — 아니면 아래가 무의미
    @test_throws ErrorException CB.assert_paired(s0, env)
end

@testset "⚠️ 측정 — Replace 두 경로 중 어느 것도 이 픽스처에서 스케줄 간선을 재스탬프하지 않는다" begin
    # 브리프는 "`Replace` 의 그래프 수술로 정점 번호가 재부여된다" 를 **전제**하고
    # `@test_throws ErrorException assert_paired(s, env)` 를 시켰다. 이 픽스처에서 실측한 것:
    #   · hot-swap 경로(기본)      → 정체성 보존이라 간선도 binding 도 안 바뀐다(설계대로다)
    #   · 재스탬프 경로(HOT_SWAP_REPLACE[]=false) → 이 결정 시점에서는 `no_frontier` 로 강등돼
    #     `:noop` 이 나고, 역시 간선이 안 바뀐다
    # 그래서 그 전제 위에 시험을 세우면 **거짓 초록/거짓 빨강** 둘 다 가능하다. 여기서는
    # 주장하지 않고 **기록**한다(위 testset 이 계약을 대신 지킨다).
    env, ctx = _fresh_fault_fixture()
    s0 = CB.simstate_of(env)
    saved_hs = CB.HOT_SWAP_REPLACE[]
    local out
    try
        CB.HOT_SWAP_REPLACE[] = false
        out = CB.apply_action!(env, ctx, 1)
    finally
        CB.HOT_SWAP_REPLACE[] = saved_hs
    end
    s1 = CB.simstate_of(env)
    @info "T12 재스탬프 경로 (측정)" outcome=out.outcome branch=out.branch edges_changed=(s1.g.edges != s0.g.edges) binding_changed=(s1.g.binding != s0.g.binding) hash_changed=(CB.state_hash(s1) != CB.state_hash(s0)) nv_before=Graphs.nv(BASE.sched) nv_after=Graphs.nv(env.sched)
    @test out.outcome in CB.RESPEC_VERDICTS            # 어휘 밖 판정은 조용히 안 지나간다
    # 간선이 실제로 바뀌었다면 낡은 s 는 반드시 걸려야 한다(바뀌었을 때만 유효한 조건부 계약).
    if s1.g.edges != s0.g.edges
        @test_throws ErrorException CB.assert_paired(s0, env)
    else
        @test CB.assert_paired(s0, env) === nothing
    end
end

@testset "🔴 resolve_assignments! 는 T13 의 자리다 — 비어 있음이 보인다" begin
    env, ctx = _fault_fixture()
    n0 = CB.RESOLVE_CALLS[]
    CB.apply_action!(env, ctx, 0)
    @test CB.RESOLVE_CALLS[] == n0 + 1              # 모든 팔이 이 자리를 지난다
    r = CB.resolve_assignments!(env)
    @test r.ran_milp === false                      # 🔴 T13 이 이 줄을 빨갛게 만들 것이다
    @test r.stub === true                           # 스텁임을 반환값이 스스로 말한다
end

# =============================================================================
#  generate
# =============================================================================
@testset "generate 는 τ>0 과 유한 R 을 낸다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    g1 = CB.generate(s0, env, ctx, 0, P, BP, Random.MersenneTwister(3))
    s1, R, τ, ev, E = g1.s, g1.R, g1.τ, g1.event, g1.E
    @info "T12 generate(NOOP)" τ=τ R=R event=string(ev) kind=CB.event_kind(ev)
    @test τ > 0.0
    @test isfinite(R)
    @test R <= 0.0                                # 보상은 비용의 음수다 (spec §4)
    @test s1 isa CB.SimState
    @test CB.assert_paired(s1, env) === nothing   # s′ 는 여전히 env 와 같은 그래프 세대다

    # 🔴 N-G5a — **레인 안의 보상 항등식** (T12 리뷰 Important 2 · N-G5 재정의 Step 1).
    #    `R = -(τ + w_E·E)` 가 성립하는가. 이 단언이 의미를 가지려면 `E` 가 `generate` 에서
    #    **직접** 와야 한다 — `E = (−R − τ)/w_E` 로 역산하면 등식이 정의상 항진이 된다.
    wE = CB.objective_w_E()
    @info "N-G5a 보상 분해" τ=τ E=E w_E=wE R=R residual=(R + (τ + wE * E))
    @test isfinite(E) && E >= 0.0
    @test R + (τ + wE * E) ≈ 0.0 atol = 1e-9 * max(1.0, abs(R))
    # 음성 대조 둘: 등식이 공허하지 않은가 — 두 항이 **둘 다** 실제로 R 을 움직이는가.
    @test τ > 0.0
    @test wE * E > 0.0
    @test !isapprox(R, -τ; rtol = 1e-9)           # 에너지 항이 R 에 실제로 들어가 있다
    @test !isapprox(R, -(wE * E); rtol = 1e-9)    # 시간 항도 마찬가지
end

@testset "🔴 generate 는 rate boundary 를 넘는 τ 에서도 산다 (브리프의 advance_to 오류)" begin
    env, ctx = _fault_fixture()
    CB.apply_action!(env, ctx, 0)                    # generate 가 하는 것과 같은 전처리
    sp = CB.simstate_of(env)
    # 경계를 여러 번 넘는 시드를 **발견**한다(인용하지 않는다).
    found, τ_found, nb_found = 0, 0.0, 0
    for seed in 1:60
        τ, ev, nb = CB.sample_sojourn_traced(sp, env, P, BP, Random.MersenneTwister(seed))
        if nb >= 1
            found, τ_found, nb_found = seed, τ, nb; break
        end
    end
    @info "T12 경계를 넘는 시드" seed=found τ=τ_found n_boundary=nb_found b=CB.T_plan_next(sp, env)
    @test found > 0                                  # 못 찾으면 이 시험은 무의미하다 → 빨강
    # 🔴 음성 대조: 브리프가 시킨 `advance_to(s⁺, env, τ, bp)` 는 **바로 여기서 죽는다.**
    @test_throws ErrorException CB.advance_to(sp, env, τ_found, BP)
    # 계약: generate 는 같은 자리에서 살아야 한다(같은 env·같은 시드).
    g3 = CB.generate(sp, env, ctx, 0, P, BP, Random.MersenneTwister(found))
    s3, R, τ, ev = g3.s, g3.R, g3.τ, g3.event
    @test τ === τ_found
    @test isfinite(R)
    # s′ 는 시간이 흘렀다 — 닫힌 집합이 커졌거나 soc 가 줄었다.
    @test s3.prog.closed ⊇ sp.prog.closed
    @test length(s3.prog.closed) > length(sp.prog.closed) || any(
        s3.fleet[k].soc < sp.fleet[k].soc for k in keys(sp.fleet))
end

@testset "🔴 generate 는 재현된다 (같은 시드 = 비트 동일)" begin
    ctx = CTX0
    function once(seed)
        e = _fork(BASE)
        s = CB.simstate_of(e)
        g = CB.generate(s, e, ctx, 0, P, BP, Random.MersenneTwister(seed))
        return (g.τ, g.R, string(g.event), CB.state_hash(g.s), g.E)
    end
    a, b = once(11), once(11)
    @test a === b
    # 음성 대조 둘: (1) rng 를 안 쓰는 구현 배제 — 다른 시드는 갈려야 한다.
    v = [once(k)[1] for k in 1:12]
    @test length(unique(v)) >= 2
    # (2) 상수 R 구현 배제
    @test length(unique([once(k)[2] for k in 1:12])) >= 2
end

# =============================================================================
#  🔴 T11 이 못 닫은 구멍 — **진짜 두 갈래**로 RVO 전역을 잰다
#  T11 의 음성 대조는 deepcopy 된 env 를 태우지 않았다(RVO 전역 C 객체는 deepcopy 가 안 된다).
#  여기서 그 자리를 닫는다.
# =============================================================================
_rvo_pos(env, id) = CB.rvo_get_agent_position(CB.get_node(env.scene_tree, id))
_rvo_ids(env) = sort!(collect(CB.get_vtx_ids(CB.rvo_global_id_map())); by = string)

@testset "🔴 두 갈래 대조 — rvo_rebuild! 없이는 RVO 세계가 공유된다" begin
    A = deepcopy(BASE)
    B = deepcopy(BASE)
    CB.rvo_rebuild!(A)                       # A 를 기준으로 전역 RVO 를 세운다
    victim = first(_rvo_ids(A))
    a_before = _rvo_pos(A, victim)
    # A 갈래에서만 RVO 상태를 오염시킨다.
    CB.rvo_set_agent_position!(CB.get_node(A.scene_tree, victim), (99.0, 99.0))
    a_dirty = _rvo_pos(A, victim)
    b_seen  = _rvo_pos(B, victim)            # ← B 는 건드린 적이 없다
    @info "T12 rvo_rebuild! **없이**" victim=string(victim) a_before=a_before a_dirty=a_dirty b_seen=b_seen
    @test a_dirty[1] ≈ 99.0
    # 🔴 이것이 측정된 사실이다: 포크 B 가 포크 A 의 오염을 **그대로 읽는다.**
    @test b_seen[1] ≈ 99.0
    @test b_seen == a_dirty

    # rvo_rebuild!(B) 하나로 B 의 세계가 자기 씬트리에서 다시 유도된다.
    CB.rvo_rebuild!(B)
    b_clean = _rvo_pos(B, victim)
    tr = CB.project_to_2d(CB.global_transform(CB.get_node(B.scene_tree, victim)).translation)
    @info "T12 rvo_rebuild! **후**" b_clean=b_clean scene_tree=(tr[1], tr[2])
    @test b_clean[1] ≈ tr[1] atol = 1e-9
    @test b_clean[2] ≈ tr[2] atol = 1e-9
    @test !(b_clean[1] ≈ 99.0)
end

@testset "🔴 두 갈래 대조 — 갈래가 갈리면 rvo_rebuild! 가 그 갈래를 따라간다" begin
    A = deepcopy(BASE)
    B = deepcopy(BASE)
    victim = first(_rvo_ids(A))
    # B 의 **씬트리**만 굴린다(A 는 그대로). deepcopy 가 격리한 계층이 여기다.
    CB.rvo_rebuild!(B)
    for _ in 1:10
        CB.step_environment!(B)
        CB.update_planning_cache!(B, 0.0)
    end

    CB.rvo_rebuild!(A); pa = _rvo_pos(A, victim)
    CB.rvo_rebuild!(B); pb = _rvo_pos(B, victim)
    d = max(abs(pb[1] - pa[1]), abs(pb[2] - pa[2]))
    @info "T12 갈린 두 갈래" victim=string(victim) pa=pa pb=pb max_abs_delta=d
    @test d > 1e-6                            # 두 갈래가 서로 다른 RVO 배치를 낸다
    # 🔴 그러나 그 둘은 **동시에** 존재하지 않는다 — RVO 는 프로세스 전역 하나다.
    #    A 로 되돌아가려면 다시 rvo_rebuild!(A) 를 불러야 한다. 이것을 못박는다:
    @test _rvo_pos(A, victim) == pb           # A 의 노드로 읽어도 지금 전역은 B 의 세계다
    CB.rvo_rebuild!(A)
    @test _rvo_pos(A, victim) == pa
end

@testset "🔴 deepcopy 는 env 만 격리한다 — respec **전역**은 갈래 사이로 샌다" begin
    # MCTS/T13/T14 가 알아야 하는 사실이고, 이 파일의 픽스처가 둘로 갈라진 이유이기도 하다.
    # 양쪽을 **같은 시험 안에서** 잰다: 무엇이 격리되고 무엇이 안 되는가.
    A = _fork(BASE)
    _tot() = sum(length(v) for v in values(CB.SPARE_POOLS[]); init = 0)

    # (1) 양성 대조 — `env` 안의 상태는 실제로 격리된다(deepcopy 가 하는 일).
    n_base_active = length(BASE.cache.active_set)
    push!(A.cache.active_set, typemax(Int))
    @test length(BASE.cache.active_set) == n_base_active     # 부모는 안 바뀐다
    pop!(A.cache.active_set, typemax(Int))

    # (2) 🔴 음성 — 창고 예비는 **모듈 전역**이라 A 갈래의 소비가 부모 세계에서도 사라진다.
    n0   = _tot()
    pool = first(sort!(collect(keys(CB.SPARE_POOLS[]))))
    spare = CB.pop_spare!(pool)
    @test spare !== nothing                                   # 아니면 이 측정은 무의미하다
    n1 = _tot()
    @info "T12 전역 누수" pool=pool spare=string(spare) total_before=n0 total_after=n1 env_isolated=true globals_isolated=false
    @test n1 == n0 - 1                                        # 🔴 갈래 하나가 판 전체의 재고를 먹었다
    CB.register_spare!(pool, spare)                           # 되돌린다(다른 시험 오염 방지)
    @test _tot() == n0
end

# =============================================================================
@testset "🔴 트리 색인은 행동 경로다 (state_hash 가 아니다)" begin
    @test CB.action_path_key(Int[]) == CB.action_path_key(Int[])
    @test CB.action_path_key([0, 1, 3]) != CB.action_path_key([0, 3, 1])   # 순서가 산다
    @test CB.action_path_key([0]) != CB.action_path_key([3])
    # 🔴 트립와이어: `SwapBattery` 는 결정 직후 `s` 에 흔적을 안 남긴다.
    #    state_hash 로 색인하면 그 자식이 NOOP 자식과 합쳐진다 — 행동 경로로는 안 합쳐진다.
    @test CB.action_path_key([0]) != CB.action_path_key([0, 0])
end
