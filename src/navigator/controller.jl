# controller.jl
# ============================================================================
#  이 파일은 비교 실험을 하나로 묶는 핵심 추상화 "Controller".
#  연구 대상인 두 방식(제로샷 LLM 안전층, 학습된 MARL 정책)과 모든 baseline 은
#  결국 "상황을 보고 대응안을 내는 결정 함수" 하나로 통일됨:
#      decide(ctrl, ctx) : (이벤트 상황) -> RespecProposal 또는 Nothing
#  decide 이후의 뒤처리(검증→반영→재계획→측정)는 전부 공유(run_pipeline로 주입)되므로,
#  Controller 만 바꾸면 "결정 함수"라는 단 하나의 변수만 달라짐 → 공정한 비교.
#  ctx 는 컨트롤러가 필요로 할 만한 것을 담은 NamedTuple: 최소한 (nl, truth),
#  학습/무작위 컨트롤러라면 (env, obs, rng, seed) 도 선택적으로 포함.
#
#  Julia 문법 참고:
#   · abstract type Controller end : 직접 인스턴스는 못 만들지만 여러 구체 타입의 공통 부모.
#   · struct X <: Controller end : X 가 Controller 의 하위 타입임을 선언(<: 는 "~의 하위타입").
#   · name(::NoAdaptController) = "..." : 인자의 "타입"만 보고 고르는 메서드(다중 디스패치).
#     인자 이름 없이 `::타입` 만 쓰면 값은 안 쓰고 타입만 따진다는 뜻.
#   · Base.@kwdef struct : 필드에 기본값을 주는 매크로.
#   · a || push!(...) : a 가 참이면 끝, 거짓일 때만 뒤(push!)를 실행하는 짧은 관용구.
# ============================================================================
# The UNIFYING abstraction of the comparison. Both paradigms under study — the
# zero-shot LLM safety layer and the learned MARL policy — plus every baseline are
# just different `Controller`s: a decision function
#
#     decide(ctrl, ctx) :: (event context) -> RespecProposal | Nothing
#
# Everything downstream of `decide` (verify -> dispatch -> re-solve -> RunMetrics) is
# SHARED and injected as `run_pipeline` (see compare_controllers.jl), so swapping the
# Controller isolates the decision function as the SINGLE variable. `ctx` is a
# NamedTuple carrying whatever a controller might need — at least `(nl, truth)`, plus
# optionally `(env, obs, rng, seed)` for learned / random controllers.
# ============================================================================

# 모든 컨트롤러의 공통 부모 타입(추상 타입). 실제 컨트롤러들은 이걸 상속함.
abstract type Controller end

# 아래 4개는 모든 Controller 의 "기본 동작"(각 컨트롤러가 필요하면 자기 타입용으로 덮어씀).
"Human-readable method name (column label in the comparison table)."
name(c::Controller) = string(nameof(typeof(c)))          # 기본 이름 = 타입 이름 문자열
"Does this controller receive the STRUCTURED ground-truth (an oracle detector)? Such a
controller's grounding is trivially perfect and is reported as n/a, not scored."
needs_truth(::Controller) = false                         # 정답 구조를 직접 받는 오라클 탐지기인가?(기본 아니오)
"Is this a LEARNED policy (train/held-out split applies; report train vs held-out)?"
is_learned(::Controller) = false                          # 학습된 정책인가?(기본 아니오)
"A nominal per-decision wall-clock hint [s] for the cost axis (measured at run time overrides)."
decision_latency_hint(::Controller) = NaN                 # 결정 1회의 대략 소요시간[초] 힌트(실측이 있으면 그게 우선)

# ---- B0: no-adapt (floor) --------------------------------------------------------
# B0 = 아무 대응도 안 하는 바닥선. decide 가 항상 nothing → 원래 계획 그대로.
struct NoAdaptController <: Controller end
name(::NoAdaptController) = "B0_noadapt"
decide(::NoAdaptController, ctx) = nothing

# ---- B1: canonical rule map from structured truth (oracle detector) --------------
# B1 = 정답 구조를 받아 규칙 표대로 표준 대응안을 냄(정답 탐지기 가정).
struct CanonicalController <: Controller end
name(::CanonicalController) = "B1_canonical"
needs_truth(::CanonicalController) = true                  # 정답 구조(ctx.truth)가 필요함
decide(::CanonicalController, ctx) = canonical_respec(ctx.truth)

# ---- B3: oracle re-solve enactment from structured truth (oracle detector) -------
# B3 = 정답 구조로부터 재계산해 얻는 이상적 대응안(도달 가능한 최선의 참조).
struct OracleController <: Controller end
name(::OracleController) = "B3_oracle"
needs_truth(::OracleController) = true
decide(::OracleController, ctx) = oracle_respec(ctx.truth)

# ---- B2: brittle regex NL parser (realistic non-LLM symbolic competitor) ---------
# B2 = LLM 없이 정규식으로 자연어를 파싱하는 현실적 비-LLM 경쟁자.
# mkrobot: 파싱된 정수 id 를 도메인 id 타입으로 바꾸는 함수. 패키지 안에서는 반드시
# RobotID 여야 함(ReplaceAgent 의 필드는 AbstractID 타입이라 Int 로는 못 만듦).
Base.@kwdef struct RegexController <: Controller
    mkrobot = RobotID
end
name(::RegexController) = "B2_regex"
decide(c::RegexController, ctx) = b2_respec(ctx.nl; mkrobot = c.mkrobot)  # 자연어(ctx.nl)를 파싱해 대응안 생성

# ---- B5: random macro over the repertoire (sanity floor for the learned head) ----
# B5 = 매크로 목록 중 무작위로 하나 고름 → 학습된 정책이 최소 이것보다는 나아야 한다는 하한선.
Base.@kwdef struct RandomMacroController <: Controller
    seed::Int = 1                                          # 재현 가능한 난수를 위한 시드
end
name(::RandomMacroController) = "B5_random"
needs_truth(::RandomMacroController) = true
function decide(c::RandomMacroController, ctx)
    # ctx 에 난수원(rng)이 있으면 그걸 쓰고, 없으면 seed 로 새 난수기를 만듦.
    rng = ctx isa NamedTuple && hasproperty(ctx, :rng) ? ctx.rng : Random.MersenneTwister(c.seed)
    return random_macro_respec(ctx.truth; rng = rng)       # 정답에 맞는 후보들 중 무작위 매크로 선택
end

# ---- B4: reactive-only (no DSL; motion stack only) -------------------------------
# B4 = DSL 대응 없이 모션 스택(회피)만 씀. 이벤트 단위 제안은 B0 과 같아(nothing) 보이지만,
# 전체 롤아웃에서는 throttle 휴리스틱으로 다르게 동작 → 결과 표에 따로 표시하려고 별도 타입 유지.
struct ReactiveOnlyController <: Controller end
name(::ReactiveOnlyController) = "B4_reactive"
decide(::ReactiveOnlyController, ctx) = nothing

# ---- LLM: the zero-shot safety layer (wraps llm_bridge or any nl->proposal fn) ---
# LLM = 이 연구의 제로샷 안전층. 자연어→대응안 함수 하나(respec)를 감싸는 얇은 껍데기.
Base.@kwdef struct LLMController <: Controller
    respec::Function                 # nl -> RespecProposal | Nothing (자연어를 받아 대응안 또는 nothing 반환)
    latency_hint::Float64 = 2.0      # LLM 왕복은 대략 수 초 단위(비용 축에 반영)
end
name(::LLMController) = "LLM"
decision_latency_hint(c::LLMController) = c.latency_hint
decide(c::LLMController, ctx) = c.respec(ctx.nl)          # 자연어(ctx.nl)를 LLM 함수에 넘김

# ---- MARL: the learned decentralized policy (wraps any ctx->proposal fn) ---------
# MARL = 학습된 분산 정책. 실제 정책 신경망은 DecPOMDP/Python 쪽에 있고, 여기선 policy(ctx)
# 함수로 "주입"만 받음(매크로 헤드의 출력=대응안 또는 nothing). 이렇게 하면 navigator 층이
# torch 와 얽히지 않으면서도 MARL 을 비교 표의 정식 한 열로 넣을 수 있음.
Base.@kwdef struct MARLController <: Controller
    policy::Function                 # ctx -> RespecProposal | Nothing (상황 전체를 받아 대응안 반환)
    label::String = "MARL"           # 결과 표에 쓸 이름(다른 학습 변형과 구분 가능)
    latency_hint::Float64 = 0.005    # 순전파(forward pass)는 대략 밀리초 단위
    learned::Bool = true             # 학습된 정책 표시(train/held-out 분리 채점 대상)
end
name(c::MARLController) = c.label
is_learned(c::MARLController) = c.learned
decision_latency_hint(c::MARLController) = c.latency_hint
decide(c::MARLController, ctx) = c.policy(ctx)            # LLM 과 달리 상황 전체(ctx)를 정책에 넘김

"""
    default_controllers(; llm=nothing, marl=nothing, mkrobot=identity) -> Vector{Controller}

The standard comparison ladder: B0, B1, B3, B2, B5, B4, plus the LLM and/or MARL columns
when their decision functions are supplied. B1/B3 are the oracle-detector references; B0
is the floor; B2/B5/B4 are the honest non-learned/degraded competitors.
"""
# 표준 비교 사다리(baseline 묶음)를 만들어 반환. llm/marl 결정 함수가 주어지면 해당 열도 추가.
function default_controllers(; llm = nothing, marl = nothing, mkrobot = RobotID, random_seed::Int = 1)
    # 항상 포함되는 6개 baseline (B0, B1, B3, B2, B5, B4).
    cs = Controller[NoAdaptController(), CanonicalController(), OracleController(),
                    RegexController(mkrobot = mkrobot), RandomMacroController(seed = random_seed),
                    ReactiveOnlyController()]
    llm  === nothing || push!(cs, LLMController(respec = llm))   # llm 함수가 있으면 LLM 열 추가
    # marl 이 이미 Controller 면 그대로, 함수면 MARLController 로 감싸서 추가.
    marl === nothing || push!(cs, marl isa Controller ? marl : MARLController(policy = marl))
    return cs
end
