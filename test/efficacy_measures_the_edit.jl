# =============================================================================
# test/efficacy_measures_the_edit.jl — Plan B / T5 게이트: spec §8 의 ④ 실효성 층.
#
# **재는 명제 하나: 이 층은 세계의 *상태* 가 아니라 편집이 만든 *차이* 를 잰다.**
#
# 왜 그 구분이 전부인가
# ---------------------
# `after.n_blocked == 0` 을 보는 규칙(=상태)은 아무것도 안 막고 있던 사건의 **아무 편집이나**
# `resolves` 로 만든다 — "고쳤다"와 "고칠 것이 없었다"가 같은 관측이 된다. 반대로 전 측정을
# 사후 시점으로 옮기면 두 값이 항상 같아져 `resolves` 가 **도달 불가**가 된다. 그래서 아래
# (1)·(2)·(2b) 는 그 두 변이를 각각 빨갛게 만들도록 짜여 있다(실측 출력은 T5 보고서).
#
# 🔴 세 값이 **전부 도달 가능**해야 한다. 도달 불가능한 값이 하나라도 있으면 그 값은 산출물에
#    영영 안 나타나면서 스키마에는 있는 거짓말이 된다. 아래가 각각을 내는 실제 입력이다:
#      (1) resolves                     — 구역이 nav 목표를 삼킨 상태 + RelocateBuild
#      (2) inert                        — 같은 상태 + 아무것도 안 푸는 편집(NOOP)
#      (2b) inert (막힘 0)              — spec §8: "막힘이 관측되지 않은 사건에서는 어떤 편집도 inert"
#      (3) deferred:no_efficacy_measure — battery/fault 사건 (컨트롤러 판정 R10)
#      (4) deferred:not_enacted         — 집행 사슬이 아무 분기도 안 탄 판
#
# 🔴 서비스를 **아예 안 부른다** — 집행 함수를 직접 부른다. `127.0.0.1:8077` 로는 한 요청도
#    안 나간다(`/decide` 는 사용자 계정의 유료 OpenAI 호출이다).
#
# 비싼 것은 env 하나뿐이다(`test/enact_uses_llm_agent.jl` 과 같은 SCENE-INCANTATION 인자).
# 시뮬레이션은 한 스텝도 안 돌린다 — `zone_blockage` 가 읽는 것은 배정이 끝난 스케줄 그래프와
# `RESTRICTION_ZONES` 뿐이고, 둘 다 `return_env_before_sim=true` 시점에 완성돼 있다.
# =============================================================================
module EfficacyMeasuresTheEdit

using Test
using ConstructionBots
const CB = ConstructionBots
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))

# ZoneTruth / BatteryTruth / emitted_key 는 런타임 include 계층에 산다.
isdefined(CB, :ZoneTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 🔴 생산 코드를 **실제로** 태운다. `enact.jl` 은 최상위 부작용이 없다(T2 커밋 1 의 요구조건).
# 여기서 부르는 `enact_with_efficacy!` 는 `run_demo.jl:handle_ood!` 이 부르는 바로 그 함수다.
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "efficacy_measures_the_edit",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

# 이 파일이 건드리는 전역(제한구역 표)을 되돌린다 — 뒤따르는 게이트가 물들지 않게.
const _PREV_ZONES = copy(CB.RESTRICTION_ZONES[])

# 구역이 **삼키는** nav 목표 하나를 고른다. `tools/tests.jl:test_zone_corridor` 가 쓰는 것과
# 같은 레시피다: 가장 작은 반지름의 nav 목표 위에 1e-3 짜리 구역을 놓으면 그 목표의 포획볼이
# 배제원 안에 통째로 들어가 `goal_engulfed` 가 참이 된다(= `check_paths=false` 로도 세진다).
function _nav_goal(env)
    local navs = CB._nav_goal_targets(env)
    isempty(navs) && error("nav 목표가 0개다 — 이 픽스처에서 막힘을 만들 수 없다")
    return navs[argmin([t.radius for t in navs])]
end

function _engulfing_zone!(key::Symbol)
    local t0 = _nav_goal(TENV)
    CB.remove_restriction_zone!(key)
    CB.add_restriction_zone!(key, t0.goal, 1e-3)
    return CB.ZoneTruth(key, Vector{Float64}(t0.goal), 1e-3)
end

try
    CB.clear_restriction_zones!()

    @testset "④ 실효성 층은 편집의 *차이* 를 잰다 (Plan B / T5)" begin

    @testset "(0) 전제 — 이 픽스처에서 막힘이 실제로 관측된다" begin
        # 이 단언이 없으면 아래 (1)(2) 는 0 → 0 을 비교하는 항진명제가 된다.
        local truth = _engulfing_zone!(:eff_pre)
        local b = CB.zone_blockage(TENV; zone_keys = [:eff_pre],
                                   check_paths = EFFICACY_CHECK_PATHS)
        @test b.n_nav_goals > 0
        @test b.n_blocked > 0
        @test b.n_downstream > 0          # 막힌 노드 뒤에 얼어붙는 일이 실제로 있다
        # 🔴 R12 — 결정 경로는 경로를 안 본다. 그 사실이 측정 결과에 실려 온다.
        @test EFFICACY_CHECK_PATHS === false
        @test b.checked_paths === false
        @test b.n_disconnected == 0       # 안 쟀으니 0 이다 — "없다"가 아니다
        CB.remove_restriction_zone!(:eff_pre)
    end

    @testset "(1) 🔴 resolves — zone 개입이 막힘에 실제로 닿는다" begin
        local truth = _engulfing_zone!(:eff_resolve)
        local before = CB.zone_blockage(TENV; zone_keys = [:eff_resolve],
                                        check_paths = EFFICACY_CHECK_PATHS)
        @test before.n_blocked > 0

        local r = enact_with_efficacy!(TENV, truth, "RelocateBuild", nothing)
        @test r.enact_applied === true
        @test r.efficacy == "resolves"
        @test r.efficacy_checked_paths === false      # R12: 잰 모드가 산출물에 실린다

        # 독립 계측: 판정이 주장하는 그 사실이 세계에도 있다(판정기를 판정기로 확인하지 않는다).
        local after = CB.zone_blockage(TENV; zone_keys = [:eff_resolve],
                                       check_paths = EFFICACY_CHECK_PATHS)
        @test after.n_blocked < before.n_blocked
        CB.remove_restriction_zone!(:eff_resolve)
    end

    @testset "(2) 🔴 inert — zone 사건인데 편집이 아무것도 안 푼다" begin
        # ⚠️ 배터리 교체로 재면 R10 에 따라 `deferred` 로 가서 `inert` 를 **한 번도 안 태운다**.
        # 그래서 사건은 zone 이고 편집만 막힘을 안 건드리는 판을 만든다: NOOP 은 가드가 없어
        # `enact_applied=true` 로 집행되지만 구역도 스케줄도 안 건드린다.
        local truth = _engulfing_zone!(:eff_inert)
        local before = CB.zone_blockage(TENV; zone_keys = [:eff_inert],
                                        check_paths = EFFICACY_CHECK_PATHS)
        @test before.n_blocked > 0

        local r = enact_with_efficacy!(TENV, truth, "NOOP", nothing)
        @test r.enact_applied === true                # 집행은 **됐다** — not_enacted 가 아니다
        @test r.efficacy == "inert"
        @test r.efficacy_checked_paths === false

        local after = CB.zone_blockage(TENV; zone_keys = [:eff_inert],
                                       check_paths = EFFICACY_CHECK_PATHS)
        @test after.n_blocked == before.n_blocked
        CB.remove_restriction_zone!(:eff_inert)
    end

    @testset "(2b) 🔴 inert — 막힘이 0 인 사건의 편집도 inert 다 (상태가 아니라 차이)" begin
        # spec §8: *"막힘이 관측되지 않은 사건에서는 어떤 편집도 `:inert` 다."*
        # 🔴 이 검사가 "사후 상태만 본다"는 변이를 잡는 자리다: `after.n_blocked == 0` 을
        #    resolves 로 읽는 규칙은 여기서 `resolves` 를 내놓는다(아무것도 안 고쳤는데).
        # 빌드에서 충분히 떨어진, 그러나 **터무니없지 않은** 자리(50 m). 좌표를 1e6 같은 값으로
        # 두면 `check_paths=true` 로 재는 순간 격자 상자가 폭발한다 — 픽스처가 술어의 비용
        # 특성을 왜곡하면 R12 를 재는 변이시험 자체가 못 돈다(실측: 10분 초과).
        local far = Vector{Float64}(_nav_goal(TENV).goal) .+ [50.0, 50.0]
        CB.remove_restriction_zone!(:eff_empty)
        CB.add_restriction_zone!(:eff_empty, far, 1.0e-3)   # 아무 목표도 안 건드리는 자리
        local truth = CB.ZoneTruth(:eff_empty, far, 1.0e-3)
        local before = CB.zone_blockage(TENV; zone_keys = [:eff_empty],
                                        check_paths = EFFICACY_CHECK_PATHS)
        @test before.n_blocked == 0

        local r = enact_with_efficacy!(TENV, truth, "NOOP", nothing)
        @test r.enact_applied === true
        @test r.efficacy == "inert"                   # ← 상태 규칙이면 "resolves" 가 된다
        CB.remove_restriction_zone!(:eff_empty)
    end

    @testset "(3) 🔴 deferred:no_efficacy_measure — zone 축이 아닌 사건 (R10)" begin
        # zone 술어를 battery/fault 에 들이대면 `n_blocked` 가 전후 모두 0 이라 **옳게 고친
        # 배터리 교체가 `inert` 로 오분류된다.** 틀린 측정은 정직한 `deferred` 보다 나쁘다.
        local descs = CB.open_agent_descriptors(TENV)
        @test length(descs) >= 1
        local A = CB.resolve_agent_id(TENV, descs[1]["id"])
        @test A !== nothing

        # 구역이 살아서 실제로 막고 있는 동안에 잰다 — 이 검사가 "zone 이 없어서 deferred" 를
        # 재는 것이 아니라 **사건 종류로** 유보한다는 것을 보이기 위해서다.
        _engulfing_zone!(:eff_kind)
        @test CB.zone_blockage(TENV; zone_keys = [:eff_kind],
                               check_paths = EFFICACY_CHECK_PATHS).n_blocked > 0

        for truth in (CB.BatteryTruth(A, 0.1), CB.FaultTruth(A, [0.0, 0.0]))
            local r = enact_with_efficacy!(TENV, truth, "NOOP", A)
            @test r.efficacy == "deferred:no_efficacy_measure"
            # 🔴 안 쟀으면 `nothing` 이다 — `false`("경로를 안 봤다")로 접지 않는다.
            @test r.efficacy_checked_paths === nothing
        end
        CB.remove_restriction_zone!(:eff_kind)
    end

    @testset "(4) 🔴 deferred:not_enacted — 집행 사슬이 아무 분기도 안 탔다" begin
        # "안 했다"와 "했는데 안 통했다"는 다른 사건이다. `ZoneTruth` 에는 `robot` 필드가 없어서
        # Replace 분기의 가드가 안 걸리고, 사슬에 없는 이름은 최종 `else` 가 없어 그냥 통과한다.
        local truth = _engulfing_zone!(:eff_noact)
        for mac in ("Replace", "SwapBattery", "NoSuchMacro")
            local r = enact_with_efficacy!(TENV, truth, mac, nothing)
            @test r.enact_applied === false
            @test r.efficacy == "deferred:not_enacted"     # ← `inert` 가 **아니다**
            @test r.efficacy_checked_paths === false       # 재기는 쟀다
        end
        # 세계가 여전히 막혀 있다 = 위 판정이 "풀렸는데 not_enacted 로 적었다"가 아니다.
        @test CB.zone_blockage(TENV; zone_keys = [:eff_noact],
                               check_paths = EFFICACY_CHECK_PATHS).n_blocked > 0
        CB.remove_restriction_zone!(:eff_noact)
    end

    @testset "(5) 🔴 반환 셋은 `enact_macro!` 의 것을 그대로 통과시킨다" begin
        # ④층은 **감싸는** 계측이다. 사슬의 반환(`enact_applied`·`ran_milp`)을 다시 계산하거나
        # 덮어쓰면 T2·T3 게이트가 지키던 계약이 이 층에서 조용히 갈린다.
        local truth = _engulfing_zone!(:eff_passthru)
        local r = enact_with_efficacy!(TENV, truth, "NOOP", nothing)
        @test r.enact_applied === true
        @test r.ran_milp === false            # NOOP 분기는 formulate_milp 을 아예 안 부른다
        @test Set(keys(r)) == Set((:enact_applied, :ran_milp, :efficacy, :efficacy_checked_paths))
        CB.remove_restriction_zone!(:eff_passthru)
    end

    @testset "(6) 🔴 emitted_keys 는 `CB.emitted_key` 와 일치한다 (리터럴이 아니라)" begin
        # spec §9-2: **Julia 가** 계산한다. 하드코딩된 목록으로 되돌아가면 여기서 빨개진다 —
        # 대조는 손으로 쓴 기대값이 아니라 **그 함수를 실제로 불러서** 만든다.
        local descs = CB.open_agent_descriptors(TENV)
        @test length(descs) >= 2
        local A = CB.resolve_agent_id(TENV, descs[1]["id"])
        local B = CB.resolve_agent_id(TENV, descs[2]["id"])
        local cs = CB.ConstraintSpec[CB.ReplaceAgent(A, 0.0), CB.SwapBattery(B)]
        local prop = CB.RespecProposal(cs, "rationale", "BatteryTruth")

        local want = Any[Any[string(first(CB.emitted_key(c))), string(last(CB.emitted_key(c)))]
                         for c in cs]
        @test emitted_keys_of(prop) == want
        # 값 자체도 못박는다(대조가 두 곳에서 같은 실수를 하는 경우 대비).
        @test emitted_keys_of(prop) == Any[Any["fault", string(A)], Any["battery", string(B)]]
        # 🔴 왕복: 실린 문자열은 `resolve_agent_id` 가 받아들이는 바로 그 표기다.
        @test CB.resolve_agent_id(TENV, emitted_keys_of(prop)[1][2]) == A

        # 채점 대상 엔티티가 없는 지시는 채점기와 **같은 규칙으로** 건너뛴다(baselines.jl).
        local zprop = CB.RespecProposal(
            CB.ConstraintSpec[CB.ForbidZone(CB.AssemblyID(1), :eff_z)], "r", "ZoneTruth")
        @test CB.emitted_key(first(zprop.constraints)) === nothing
        @test emitted_keys_of(zprop) == Any[]

        # 🔴 빈 배열("계산했더니 없었다")과 `nothing`("계산을 못 했다")은 다른 사건이다.
        @test emitted_keys_of(CB.RespecProposal(CB.ConstraintSpec[], "r", "x")) == Any[]
        @test emitted_keys_of(nothing) === nothing
    end

    @testset "(7) 🔴 reasoning 은 글자 그대로 실린다 — 파싱도 절단도 없다" begin
        # spec §9-2: *"해석성 로그 — 파싱하지 않는다, 지우지도 않는다"*.
        # 결정 행의 `reasoning` 은 `decision_reasoning(decision)` 이 낸다. 서비스가 실제로 낼
        # 법한 **긴** 문장(줄바꿈·유니코드·따옴표)을 넣고 **동일성(`===`)** 까지 단언한다 —
        # 어딘가에 `first(split(s, "\n"))` · `strip` · `String(...)` 사본이 생기면 그 순간
        # 빨개진다. 값 동등만 재면 절단은 잡아도 조용한 재가공은 못 잡는다.
        local long = "The zone at (−3.2, 1.4) engulfs the staging goal of assembly 3; " *
                     "relocating the build by ≈0.14 m clears it.\n" *
                     "Second line — must survive verbatim. \"quoted\" · 한글 · 12345"
        # `decide_all` 의 반환은 NamedTuple 이고 `detail` 은 그 필드다(policy.jl 반환문).
        @test decision_reasoning((detail = long, enacted = "dspy")) === long
        @test occursin("\n", decision_reasoning((detail = long, enacted = "dspy")))
        # 🔴 빈 문자열도 그대로 나른다("서비스가 빈 문장을 냈다"는 측정 결과다).
        @test decision_reasoning((detail = "", enacted = "canonical")) === ""
        # 🔴 필드가 아예 없으면 `nothing`("기록 없음") — `""` 로 덮지 않는다.
        @test decision_reasoning((enacted = "canonical",)) === nothing
        @test decision_reasoning(nothing) === nothing
    end

    end
finally
    CB.RESTRICTION_ZONES[] = _PREV_ZONES
end

end # module
