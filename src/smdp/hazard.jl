# =============================================================================
#  hazard.jl -- MDP STEP 1: the explicit STOCHASTIC failure process.
#  (설계 문서: wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md §5)
# -----------------------------------------------------------------------------
#  WHY THIS FILE EXISTS
#  --------------------
#  Up to now the "stochastic" part of the problem was a randomized SCRIPT:
#  `schedule_random_ood!` drew n progress points and n kinds ONCE, before the
#  simulation started, then fired them like cue cards. That is a random *scenario
#  generator*, not a stochastic process — the event times do not depend on the
#  state, so P(s'|s,a) is not actually defined by it and the MDP does not close.
#
#  This file replaces the cue cards with a genuine STATE-DEPENDENT point process:
#
#     λ_r(t) = (1/mtbf) · mode · f_mode(r) · exp(β_u·û_r + β_s·(1 − soc_r))
#
#  and samples the first event time EXACTLY (no per-step Bernoulli approximation)
#  by the standard "exponential clock" / inverse-transform construction:
#
#     draw  E_r ~ Exp(1)   once,
#     accumulate  Λ_r(t) = ∫₀ᵗ λ_r(u) du,
#     robot r fails at the first t with  Λ_r(t) ≥ E_r.
#
#  COMPETING RISKS fall out for free: every robot (and the global zone process)
#  runs its own clock, whoever crosses first fires first — which is exactly the
#  design's  T_first = min_r T_fail_r, and therefore
#
#     τ_{k+1} = min( T_plan_event , T_first )
#
#  the SMDP holding time. THAT is what makes the same (s,a) lead to different
#  successor states, i.e. what makes this a stochastic MDP rather than a
#  deterministic TAMP with noise sprinkled on top.
#
#  THREE COMPETING RISKS ARE MODELLED
#    :break  per-robot sudden breakdown        -> fault_action  (FaultTruth)
#    :cell   per-robot battery cell degradation-> battery_action(BatteryTruth, severity-split)
#    :zone   fleet-level no-go zone appearing  -> zone_action   (ZoneTruth)
#  Breakdown is TERMINAL for that robot; cell degradation RE-ARMS (a robot can
#  degrade more than once); zone is a global process that always re-arms.
#
#  PLUS: the DRAIN itself is randomized. Each robot draws a lognormal efficiency
#  deviation ε_r (mean 1), installed into battery.jl's single debit choke point
#  via DRAIN_FACTOR_HOOK. Without this, SoC depletion is a deterministic function
#  of the plan and the battery "event" is not a random variable at all.
#
#  MARKOV NOTE (design §3.1): the hazard depends only on OBSERVABLE state that
#  lives in the state vector — cumulative active seconds `usage_s` (= usage_r),
#  current SoC, current power mode, and the global exogenous `mode`. It does NOT
#  depend on anything hidden, so the process stays Markov in the declared state.
#  If you ever make λ depend on a latent health z_r, you MUST add a belief over
#  z_r to the state or you silently drop to a POMDP.
#
#  NON-INVASIVE: inert until `enable_hazard!`. It CHAINS onto BATTERY_STEP_HOOK
#  (calls whatever was installed first, then itself), so battery accounting still
#  runs and normal runs are unaffected.
#
#  문법 참고(처음 보는 사람용):
#   · Base.@kwdef struct : 필드 기본값을 주는 구조체(HazardParams(mtbf_break_s=300.0) 식 호출).
#   · Ref(x) / X[] : 전역 가변 "상자". X[] 로 읽고 X[] = v 로 쓴다.
#   · `-log(rand(rng))` : Exp(1) 난수(역변환법). `exp(μ + σ*randn(rng))` : 로그정규 난수.
#   · `A === nothing || B` : A 가 nothing 이 아닐 때만 B 실행(단축평가 관용구).
#   · get!(dict, k, default) : 키 없으면 default 를 넣고 돌려줌(lazy 초기화에 씀).
# =============================================================================

# -----------------------------------------------------------------------------
# Parameters — all rates given as MTBF (mean time between failures) in SIM SECONDS
# at REFERENCE conditions, because 1/λ is far easier to reason about than λ.
# Reference condition := a healthy robot (û=0, soc=1) in TRANSIT (moving, unloaded).
# -----------------------------------------------------------------------------
"""
    HazardParams

Stochastic-failure model parameters. Rates are MTBF in **sim seconds at reference
conditions** (healthy robot, unloaded, in transit); everything else is a multiplier
on top. `Inf` MTBF turns that risk off.
"""
# 확률적 고장 모델의 파라미터. 비율은 "기준 조건(건강·빈몸·이동 중)에서의 평균 무고장 시간(초)"으로 준다.
# Inf 를 넣으면 그 위험은 꺼짐. 나머지 계수는 전부 그 위에 곱해지는 배수/지수.
Base.@kwdef struct HazardParams
    # --- (A) 급작 고장(breakdown) 위험 ------------------------------------------
    mtbf_break_s::Float64   = 900.0    # 기준 조건에서 평균 15분마다 1회 고장
    beta_usage::Float64     = 1.0      # 누적 사용량 민감도(마모): exp(β_u·û)
    beta_soc::Float64       = 1.2      # 방전될수록 고장률 증가: exp(β_s·(1−soc))
    usage_scale_s::Float64  = 600.0    # û = 1 로 세는 "누적 활동 초". 이 값이 마모의 시간 단위
    mult_idle::Float64      = 0.10     # 대기 중 로봇은 기준의 10% 만
    mult_carry::Float64     = 2.0      # 짐 운반 중이면 2배
    mult_manip::Float64     = 1.4      # 정밀 조작 중이면 1.4배

    # --- (B) 배터리 셀 열화(cell degradation) 위험 -------------------------------
    mtbf_cell_s::Float64    = 1200.0   # 셀 고장/급락 사건의 평균 간격
    cell_severe_frac::Float64 = 0.5    # 이 확률로 "깊은 방전"(→ canonical Replace)
    cell_severe_drop::Float64 = 1.0    # 깊은 방전 시 SoC 낙폭(1.0 = 바닥까지)
    cell_mild_lo::Float64   = 0.35     # 가벼운 열화 낙폭 하한(→ canonical Deprioritize)
    cell_mild_hi::Float64   = 0.70     # 가벼운 열화 낙폭 상한

    # --- (C) 통행금지 구역 출현(fleet-level) 위험 --------------------------------
    mtbf_zone_s::Float64    = Inf      # 기본 꺼짐. 유한값을 주면 무작위 시점에 zone 이 생김

    # --- (D) 방전 무작위성 --------------------------------------------------------
    drain_sigma::Float64    = 0.15     # ε_r ~ LogNormal(−σ²/2, σ) (평균 1). 0 이면 결정론적
    drain_step_cv::Float64  = 0.0      # >0 이면 매 스텝 추가 iid 변동(변동계수). 기본 0

    # --- (E) 전역 외생 모드(drift 손잡이) ----------------------------------------
    mode::Float64           = 1.0      # 모든 위험률에 곱해지는 전역 배수(먼지↑/조도↓ 같은 환경 악화)

    # --- (F) 발화(enactment) 옵션 -------------------------------------------------
    fire_safe_target::Bool  = true     # 깔끔히 교체 가능한 로봇만 실제로 고장냄(아니면 다음 스텝으로 유예)
    fire_require_spare::Bool= true     # 쓸 수 있는 예비가 있을 때만 고장냄
    fire_obstacle::Bool     = false    # 고장 자리를 장애물로 남길지(ForbidZone 과분류 방지 위해 기본 false)
    fire_clear::Bool        = true     # 고장 본체를 즉시 견인해 치울지
    max_events::Int         = 64       # 안전 상한(런어웨이 방지)
end

# -----------------------------------------------------------------------------
# State — one exponential clock per (robot, risk) + the fleet-level zone clock.
# -----------------------------------------------------------------------------
"""
    HazardState

Live state of the failure process. `cum_*` are the accumulated integrated hazards
Λ(t); `thr_*` are the Exp(1) thresholds they race against. A risk FIRES the first
time `cum ≥ thr`.
"""
# 위험 프로세스의 실행 상태. cum_* = 누적 위험 적분 Λ(t), thr_* = 그와 경주하는 Exp(1) 문턱값.
# cum ≥ thr 이 되는 첫 순간에 그 위험이 발화한다(정확 표집; 스텝당 베르누이 근사 아님).
mutable struct HazardState
    params::HazardParams
    seed::Int                       # 이 실행의 기저 시드(모든 파생 스트림이 여기서 나옴)
    rng_zone::Random.MersenneTwister  # 전역 zone 위험 전용 스트림
    rng_robot::Dict{Any,Random.MersenneTwister}  # 로봇별 전용 스트림 (CRN 의 핵심, 아래 설명)
    t::Float64                      # 누적 시뮬 시간[s]
    step::Int                       # 누적 스텝 수
    eff::Dict{Any,Float64}          # 로봇별 방전 효율 편차 ε_r
    usage_s::Dict{Any,Float64}      # 로봇별 누적 "활동 초"(= 설계의 usage_r)
    cum_break::Dict{Any,Float64}    # 로봇별 Λ_break
    thr_break::Dict{Any,Float64}    # 로봇별 Exp(1) 문턱
    cum_cell::Dict{Any,Float64}     # 로봇별 Λ_cell
    thr_cell::Dict{Any,Float64}
    cum_zone::Float64               # 전역 Λ_zone
    thr_zone::Float64
    broken::Set{Any}                # 이미 고장 발화한 로봇(재발화 금지)
    lambda::Dict{Any,Float64}       # 직전 스텝의 λ_break (상태 특징으로 노출)
    mode_of::Dict{Any,Symbol}       # 직전 스텝의 전력 모드(:idle/:transit/:carry/:manip)
    events::Vector{NamedTuple}      # 발화 로그(라벨러/평가용)
    pending_drop::Dict{Any,Float64} # 유예된 셀 사건의 **이미 뽑힌** 낙폭 (spec §5.7 CRN 누수)
    # 리뷰 라운드 1 (소견): 가드가 끝내 안 열리는 로봇, 또는 셀 시계가 넘은 뒤 그 로봇이
    # st.broken 에 들어간 경우(hazard_step! 이 그 다음 스텝부터 cell 검사를 건너뛴다)는
    # 이 캐시 항목이 영영 회수되지 않는다. 로봇 수만큼만 자라므로 메모리상 무해하고, CRN
    # 상으로도 무해하다(어차피 그 로봇은 다시 안 도니 재사용될 일이 없다) — 고칠 것은 없다.
    # 태스크 9 의 canonical(s) 는 이 필드를 담지 않아야 한다(replay state ξ 소속, s 아님).
    zone_ct::Int                    # zone 키 일련번호
end

const HAZARD_STATE   = Ref{Union{Nothing,HazardState}}(nothing)   # 현재 위험 프로세스 상태(없으면 nothing)
const HAZARD_ENABLED = Ref(false)                                  # 마스터 on/off (기본 꺼짐 = 완전 무동작)

hazard_state()   = HAZARD_STATE[]
hazard_enabled() = HAZARD_ENABLED[] && HAZARD_STATE[] !== nothing

"""
    dynamics_stamp() -> String

동역학 세대 도장(spec §8). hazard 를 켜면 `objective.json` 은 안 바뀌므로 `objective_hash`
로는 이 축이 안 잡힌다 — dp `value.json` 누수와 정확히 같은 실패 모양이다. 그래서 별도 도장.
"""
dynamics_stamp() = hazard_enabled() ? "hazard-on" : "hazard-off"

"발화한 사건 로그(발생시각·종류·대상·그때의 물리 서술자). 라벨 생성/평가가 소비."
hazard_events()  = HAZARD_STATE[] === nothing ? NamedTuple[] : HAZARD_STATE[].events

# Exp(1) 난수 — 역변환법. rand 은 [0,1) 이므로 0 로그를 피하려 아주 작은 하한을 둔다.
_exp1(rng) = -log(max(rand(rng), 1e-12))
# 평균이 정확히 1 인 로그정규 난수(σ=0 이면 1.0 그대로). μ = −σ²/2 라야 E[X]=1.
_lognorm1(rng, σ) = σ <= 0 ? 1.0 : exp(-0.5 * σ * σ + σ * randn(rng))
# MTBF(초) -> 위험률 λ. Inf/0이하 면 0(그 위험 꺼짐).
_rate(mtbf) = (isfinite(mtbf) && mtbf > 0) ? 1.0 / mtbf : 0.0

# -----------------------------------------------------------------------------
# COMMON RANDOM NUMBERS (CRN) — 왜 스트림을 로봇별로 쪼개는가
# -----------------------------------------------------------------------------
# STEP 2 의 몬테카를로 라벨러는 같은 상태에서 여러 옵션(ω)을 비교한다. 옵션 간 makespan 차이가
# 미래 고장열의 무작위성에 파묻히면 K 를 아무리 키워도 순위가 안 잡힌다. 해법이 CRN:
# **같은 rollout 번호 k 에서는 모든 옵션이 "같은 운(luck)"을 겪게** 하고, 차이가 오직 옵션 때문에
# 생기도록 짝지어 비교한다.
#
# 지수 시계 구성이 이걸 거의 공짜로 준다: 문턱 E_r 은 실행 시작 전에 뽑히므로 팔마다 동일하고,
# 팔마다 달라지는 것은 Λ_r(t)=∫λ 의 적분 경로뿐 — 그게 바로 우리가 재려는 인과효과다.
#
# 단, 난수를 **하나의 공유 스트림에서 호출 순서대로** 뽑으면 이 성질이 깨진다. 팔 A 가 스페어를
# 하나 더 투입해 로봇을 늦게 등록하면 그 뒤 모든 뽑기가 밀려 팔 B 와 완전히 다른 난수를 쓰게 된다.
# 그래서 모든 난수를 **로봇별 전용 스트림**에서 뽑는다. 스트림 시드는 (기저시드, 로봇 id) 의
# 결정론적 함수라, 로봇이 언제 어떤 순서로 등록되든 그 로봇의 난수열은 항상 같다.
#   · 로봇 r 의 ε_r, 초기 thr_break/thr_cell, 그리고 r 의 n 번째 셀 사건 심각도 = 전부 이 스트림에서
#   · zone 은 로봇에 안 매이므로 전용 전역 스트림 + 발생 순번으로 시드
# 예외: `drain_step_cv > 0` (매 스텝 iid 흔들림)은 스텝 수 자체가 팔마다 달라 원리적으로 CRN 을
# 깬다. 기본값 0 이며, 켜면 짝지은 비교의 분산감소 효과가 사라진다는 점을 알고 쓸 것.

# (기저시드, 태그, 정수키) -> 파생 시드. splitmix 계열 상수로 섞어 스트림 간 상관을 없앤다.
function _mix_seed(base::Integer, tag::Integer, key::Integer)
    # 주의: Julia 에서 0x1 은 UInt8 이라, 인자 타입을 UInt64 로 못 박으면 호출부가 전부 깨진다.
    # Integer 로 받아 내부에서 UInt64 로 승격한다.
    tag = UInt64(tag); key = UInt64(key)
    h = (UInt64(mod(base, typemax(Int32))) + 0x9E3779B97F4A7C15) ⊻ (tag * 0xBF58476D1CE4E5B9)
    h = (h ⊻ (h >> 30)) * 0xBF58476D1CE4E5B9
    h = (h ⊻ (h >> 27)) * 0x94D049BB133111EB
    h = h ⊻ key * 0xD6E8FEB86659FD93
    return Int(h % typemax(Int32))
end

# 로봇 id 에서 안정적인 정수 키를 뽑는다. RobotID 는 .id 필드를 갖고, 그 외 타입은 hash 로 폴백.
_id_key(id) = UInt64(try abs(Int(id.id)) catch; abs(Int(hash(id) % typemax(Int32))) end)

# 로봇 r 전용 난수 스트림(없으면 결정론적 시드로 생성). 등록 순서와 무관하게 항상 같은 열.
_robot_rng(st::HazardState, id) =
    get!(st.rng_robot, id, Random.MersenneTwister(_mix_seed(st.seed, 0x1, _id_key(id))))

# 빈 HazardState 하나 만들기(enable_hazard! 와 테스트가 공유 — 필드가 늘어도 한 곳만 고치면 됨).
function _new_hazard_state(params::HazardParams, seed::Int)
    st = HazardState(params, seed,
                     Random.MersenneTwister(_mix_seed(seed, 0x2, 0x0)),
                     Dict{Any,Random.MersenneTwister}(), 0.0, 0,
                     Dict{Any,Float64}(), Dict{Any,Float64}(),
                     Dict{Any,Float64}(), Dict{Any,Float64}(),
                     Dict{Any,Float64}(), Dict{Any,Float64}(),
                     0.0, 0.0, Set{Any}(),
                     Dict{Any,Float64}(), Dict{Any,Symbol}(),
                     NamedTuple[], Dict{Any,Float64}(), 0)
    st.thr_zone = _exp1(st.rng_zone)
    return st
end

# -----------------------------------------------------------------------------
# Enable / disable
# -----------------------------------------------------------------------------
"""
    enable_hazard!(env; params=HazardParams(), seed=0, install=true) -> HazardState

Arm the stochastic failure process. Draws each robot's efficiency deviation ε_r and
its Exp(1) failure thresholds from a seeded RNG (so a run is exactly reproducible
given the seed), installs the drain-factor hook, and — when `install` — chains
`hazard_step!` onto `route_planning.BATTERY_STEP_HOOK` so it runs every sim step.

Call AFTER the scene/schedule are built (and after `enable_battery!` if you want
SoC-coupled hazard, which is the point). Robots that appear later (dispatched
spares) are picked up lazily on the step they first show up.
"""
# 확률적 고장 프로세스를 켠다. 시드 고정 난수로 ε_r 과 Exp(1) 문턱을 뽑고(시드가 같으면 완전 재현),
# 방전 훅을 설치하고, install=true 면 매 스텝 훅에 자기 자신을 체이닝한다.
# 씬/스케줄이 만들어진 뒤(그리고 SoC 연동을 원하면 enable_battery! 뒤에) 호출할 것.
function enable_hazard!(env; params::HazardParams = HazardParams(),
                        seed::Int = 0, install::Bool = true)
    st = _new_hazard_state(params, seed)
    for id in _hz_all_robots(env)          # 씬에 이미 있는 로봇들 등록(나머지는 나중에 lazy 등록)
        _hz_ensure!(st, id)                # 등록 순서는 무관 — 각 로봇의 난수열은 id 로 결정됨
    end
    HAZARD_STATE[]   = st
    HAZARD_ENABLED[] = true
    DRAIN_FACTOR_HOOK[] = hazard_drain_factor     # battery.jl 의 _debit! 이 매 스텝 이 배수를 곱함
    install && install_hazard_step_hook!()
    return st
end

"""
    disable_hazard!()

Turn the process off and REMOVE both hooks (restoring whatever step hook was
installed before). Leaves the event log readable via the returned state.
"""
# 프로세스를 끄고 훅 두 개를 되돌린다(이전에 설치돼 있던 스텝 훅을 복원). 로그는 반환된 상태에서 계속 읽을 수 있음.
function disable_hazard!()
    HAZARD_ENABLED[] = false
    DRAIN_FACTOR_HOOK[] = nothing
    if BATTERY_STEP_HOOK[] === _hazard_step_chain      # 우리가 꽂아둔 체인이면 이전 훅으로 원복
        BATTERY_STEP_HOOK[] = _HAZARD_PREV_STEP_HOOK[]
    end
    _HAZARD_PREV_STEP_HOOK[] = nothing
    st = HAZARD_STATE[]
    HAZARD_STATE[] = nothing
    return st
end

# 씬트리의 모든 물리 로봇 id. 배터리 함대가 있으면 그 장부를 그대로 쓰고(같은 집합), 없으면 씬을 훑는다.
function _hz_all_robots(env)
    fleet = BATTERY_FLEET[]
    fleet === nothing || return collect(keys(fleet.soc))
    return Any[node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n)]
end

# 로봇 하나를 위험 장부에 등록(이미 있으면 그대로). 나중에 창고에서 나온 예비도 여기서 lazy 등록된다.
# 모든 초기 난수는 그 로봇 전용 스트림에서 "항상 같은 순서로" 뽑는다 → 등록 시점/순서가 팔마다
# 달라도 같은 로봇은 같은 ε_r 과 같은 문턱을 받는다(= CRN 이 성립하는 이유).
function _hz_ensure!(st::HazardState, id)
    haskey(st.eff, id) && return
    rng = _robot_rng(st, id)
    st.eff[id]       = _lognorm1(rng, st.params.drain_sigma)
    st.usage_s[id]   = 0.0
    st.cum_break[id] = 0.0
    st.thr_break[id] = _exp1(rng)
    st.cum_cell[id]  = 0.0
    st.thr_cell[id]  = _exp1(rng)
    st.lambda[id]    = 0.0
    st.mode_of[id]   = :idle
    return
end

# -----------------------------------------------------------------------------
# Drain factor ε_r  (installed into battery.jl `_debit!` via DRAIN_FACTOR_HOOK)
# -----------------------------------------------------------------------------
"""
    hazard_drain_factor(id) -> Float64

Per-robot energy-drain multiplier: a fixed lognormal deviation ε_r (mean 1) drawn at
`enable_hazard!`, optionally times a per-step iid jitter when `drain_step_cv > 0`.
Returns 1.0 when the process is off, so the battery layer is unchanged by default.
"""
# 로봇별 방전 배수: enable 시점에 뽑은 고정 편차 ε_r(평균 1) × (옵션) 매 스텝 iid 흔들림.
# 프로세스가 꺼져 있으면 1.0 → 배터리 계층은 기존과 동일.
function hazard_drain_factor(id)
    hazard_enabled() || return 1.0
    st = HAZARD_STATE[]
    _hz_ensure!(st, id)
    f = st.eff[id]
    cv = st.params.drain_step_cv
    # 주의: 이 iid 흔들림은 스텝 수 자체가 팔마다 다르므로 원리적으로 CRN 을 깬다(기본값 0).
    cv > 0 && (f *= max(0.0, 1.0 + cv * randn(_robot_rng(st, id))))
    return f
end

# -----------------------------------------------------------------------------
# Hazard rate λ_r  —  the model, in one place.
# -----------------------------------------------------------------------------
# 전력 모드 -> 위험 배수. 대기는 낮고, 운반/조작은 높다(하중과 정밀동작이 고장을 부른다는 상식적 형태).
function _mode_mult(p::HazardParams, m::Symbol)
    m === :idle   && return p.mult_idle
    m === :carry  && return p.mult_carry
    m === :manip  && return p.mult_manip
    return 1.0                       # :transit = 기준 조건
end

"""
    hazard_rate(st, id; mode, soc) -> Float64

The breakdown hazard rate λ_r [1/s] for robot `id` right now:

    λ = (1/mtbf_break) · global_mode · mode_mult · exp(β_u·û + β_s·(1 − soc))

with û = usage_s / usage_scale_s. Every argument is OBSERVABLE state (design §3.1),
which is what keeps the process Markov in the declared state vector.
"""
# 지금 이 순간 로봇 id 의 급작 고장 위험률 λ[1/s]. 모든 인자가 "관측 가능한 상태"라서 Markov 가 유지된다.
function hazard_rate(st::HazardState, id; mode::Symbol = :idle, soc::Float64 = 1.0)
    p = st.params
    base = _rate(p.mtbf_break_s)
    base == 0 && return 0.0
    u_hat = p.usage_scale_s > 0 ? st.usage_s[id] / p.usage_scale_s : 0.0
    return base * p.mode * _mode_mult(p, mode) *
           exp(p.beta_usage * u_hat + p.beta_soc * (1.0 - clamp(soc, 0.0, 1.0)))
end

# 셀 열화 위험률. 급작 고장과 같은 형태지만 마모(누적 사용)에만 의존하게 둔다(SoC 는 결과지 원인이 아님).
function _cell_rate(st::HazardState, id; mode::Symbol = :idle)
    p = st.params
    base = _rate(p.mtbf_cell_s)
    base == 0 && return 0.0
    u_hat = p.usage_scale_s > 0 ? st.usage_s[id] / p.usage_scale_s : 0.0
    return base * p.mode * _mode_mult(p, mode) * exp(p.beta_usage * u_hat)
end

# -----------------------------------------------------------------------------
# Per-step advance: classify modes, accumulate Λ, fire whoever crossed.
# -----------------------------------------------------------------------------
# 이번 스텝에 각 로봇이 어떤 전력 모드였는지 (battery.jl 의 분류기를 그대로 재사용해) 표로 만든다.
# 활성 스케줄 노드를 훑어 담당 로봇들에게 모드를 부여하고, 아무 데도 안 걸린 로봇은 :idle.
function _hz_modes(env)
    out = Dict{Any,Symbol}()
    for v in env.cache.active_set
        node = try get_node(env.sched, v).node catch; nothing end
        node === nothing && continue
        m = _node_mode(node)                       # battery.jl: IDLE/TRANSIT/CARRY/MANIPULATE
        m == IDLE && continue
        sym = m == TRANSIT ? :transit : (m == CARRY ? :carry : :manip)
        for id in _responsible_robots(node)
            # 한 로봇이 여러 노드에 걸리면 더 무거운 모드를 채택(운반 > 조작 > 이동).
            prev = get(out, id, :idle)
            rank(s) = s === :carry ? 3 : s === :manip ? 2 : s === :transit ? 1 : 0
            rank(sym) > rank(prev) && (out[id] = sym)
        end
    end
    return out
end

# 지금 위험 계산에서 제외할 로봇들: 창고에 주차된 예비 + 반출되어 은퇴한 예비 + 이미 고장난 로봇.
# (주차 예비는 전원이 꺼진 채 충전대에 있으므로 마모도 고장도 없다 — battery.jl 의 idle 제외와 같은 근거.)
function _hz_excluded()
    ex = Set{Any}()
    try union!(ex, active_spares())       catch; end
    try union!(ex, checked_out_spares())  catch; end
    try union!(ex, keys(faulted_robots())) catch; end
    return ex
end

# hazard 의 스텝 카운터를 전역 시계(SIM_STEP)에 맞춘다. 자기 카운터를 따로 증가시키면
# restore! 뒤에 둘이 어긋나고, Courier 의 절대 스텝 인덱스가 그 차이만큼 밀린다.
# `SIM_STEP[] == 0`(= 아직 셋업 전)이면 자기 카운터를 유지한다 — 단위검사 경로가 그렇다.
function _hz_sync_clock!(st::HazardState)
    s = _current_sim_step()
    st.step = s > 0 ? s : st.step + 1
    return st.step
end

"""
    hazard_step!(env) -> Nothing

Advance every exponential clock by one sim step and fire any risk that crossed its
threshold. Called automatically once per step when the hook is installed. Inert when
the process is disabled.
"""
# 모든 지수 시계를 한 스텝 전진시키고, 문턱을 넘은 위험을 발화시킨다. 훅이 설치돼 있으면 매 스텝 자동 호출.
function hazard_step!(env)
    hazard_enabled() || return nothing
    st = HAZARD_STATE[]
    length(st.events) >= st.params.max_events && return nothing   # 안전 상한
    dt = Float64(env.dt)                                          # env.dt 는 이미 "초" 단위(battery.jl 검증)
    dt > 0 || return nothing
    st.t += dt
    _hz_sync_clock!(st)      # 스텝은 전역 시계에서 받는다 (spec §11-8 단일 진실원)

    fleet = BATTERY_FLEET[]
    modes = _hz_modes(env)
    excl  = _hz_excluded()

    for id in _hz_all_robots(env)
        _hz_ensure!(st, id)
        (id in excl) && continue
        (id in st.broken) && continue
        mode = get(modes, id, :idle)
        soc  = (fleet === nothing) ? 1.0 : get(fleet.soc, id, 1.0)
        st.mode_of[id] = mode
        mode === :idle || (st.usage_s[id] += dt)          # 누적 "활동 초"는 실제로 일한 시간만 센다

        λb = hazard_rate(st, id; mode = mode, soc = soc)
        λc = _cell_rate(st, id; mode = mode)
        st.lambda[id]     = λb
        st.cum_break[id] += λb * dt                        # Λ_break(t) 적분 누적
        st.cum_cell[id]  += λc * dt                        # Λ_cell(t) 적분 누적

        # --- 경쟁 위험 발화 ------------------------------------------------------
        # 두 위험을 반드시 "독립적으로" 검사한다. 예전에 elseif 로 묶어 두었더니, 발화가
        # 유예된(안전한 대상이 아직 없는) 고장 위험이 그 로봇의 셀 위험을 영구히 가려버려
        # 사건이 거의 안 나왔다 — 경쟁 위험 모형이 아니라 "우선순위 큐"가 되어 버린 것.
        st.cum_break[id] >= st.thr_break[id] && _hz_fire_break!(env, st, id, soc, mode)
        (id in st.broken) && continue                      # 방금 고장났으면 셀 사건은 무의미
        st.cum_cell[id] >= st.thr_cell[id] && _hz_fire_cell!(env, st, id, soc, mode)
    end

    # --- 전역(함대 수준) zone 위험 -------------------------------------------------
    λz = _rate(st.params.mtbf_zone_s) * st.params.mode
    if λz > 0
        st.cum_zone += λz * dt
        st.cum_zone >= st.thr_zone && _hz_fire_zone!(env, st)
    end
    return nothing
end

# 이 로봇을 지금 "깔끔하게" 고장낼 수 있는가?
#
# 두 갈래다. 스케줄 재각인(re-stamp) 경로로 교체할 때는 고장 로봇의 배정 엣지를 예비에게 넘겨야
# 하므로, 다인 운반팀 한가운데서 고장내면 FormTransportUnit 의 has_edge 단언에 걸려 엔진이 죽는다.
# 그래서 "활성이고, 복구 임무 중인 예비가 아니고, 다음(frontier) 운반이 단독(팀 크기 1)"이어야 한다
# (pick_solo_frontier_target 의 판정을 특정 로봇에 대해 적용).
#
# 반면 정체성 보존 HOT-SWAP 은 id 를 유지한 채 본체만 갈아끼우므로 넘길 엣지 자체가 필요 없고,
# 운반 도중에도 안전하다(battery.jl `_fire_battery_stall!` 이 같은 이유로 같은 예외를 둔다).
# 이 게이트가 없으면 위험 프로세스가 만든 고장의 대부분이 "발화 유예"로 사라져, 모형이 만든
# 사건과 엔진이 소화한 사건이 크게 어긋난다(첫 e2e: 6개 crossed / 0개 enacted).
function _hz_safe_target(env, rid)
    sched = env.sched
    (try is_recovery_spare(rid) catch; false end) && return false
    (try hot_swap_enabled() catch; false end) && return true   # 핫스왑이면 운반 중에도 안전
    fa = try _first_pending_assignment(env, rid) catch; nothing end
    fa === nothing && return false                    # 넘길 남은 일이 없으면 교체가 무의미
    slot1 = fa[2]
    for v2 in Graphs.outneighbors(sched, slot1)
        n2 = try get_node_from_id(sched, get_vtx_id(sched, v2)) catch; nothing end
        n2 isa FormTransportUnit && return length(robot_team(entity(n2))) == 1
    end
    return false
end

# 로그 한 줄 남기기(발화 시점의 물리 서술자까지 함께 — 이것이 나중에 surrogate 의 φ(s) 재료가 된다).
function _hz_log!(st::HazardState, kind::Symbol, id, soc, mode, nl)
    push!(st.events, (t = st.t, step = st.step, kind = kind, robot = id,
                      soc = soc, mode = mode,
                      usage_s = id === nothing ? NaN : get(st.usage_s, id, NaN),
                      lambda  = id === nothing ? NaN : get(st.lambda, id, NaN),
                      global_mode = st.params.mode, nl = nl))
    return nl
end

# --- 급작 고장 발화 -----------------------------------------------------------------
# 문턱을 넘었어도 "지금 안전하게 고장낼 수 없으면" 발화하지 않고 그냥 둔다. cum ≥ thr 은 계속 참이므로
# 다음 스텝에 자동으로 재시도된다 — 즉 위험은 사라지지 않고 "안전한 순간까지 대기"할 뿐이다.
function _hz_fire_break!(env, st::HazardState, id, soc, mode)
    p = st.params
    p.fire_safe_target && !_hz_safe_target(env, id) && return nothing
    if p.fire_require_spare
        (try nearest_pool(_ood_robot_pos2d(env, id)) catch; nothing end) === nothing && return nothing
    end
    # fault_action 은 물리 고장 주입 + FaultTruth 기록을 함께 해주는 기존 래퍼(정답 배선 재사용).
    nl = try
        fault_action(; target = id, obstacle = p.fire_obstacle, clear = p.fire_clear)(env)
    catch err
        @warn "[HAZARD] breakdown injection failed; deferring" robot = id err = err
        nothing
    end
    (nl === nothing || isempty(nl)) && return nothing
    push!(st.broken, id)                     # 급작 고장은 그 로봇에게 터미널 — 재발화 없음
    push_ood!(nl)                            # respec 큐로 → 컨트롤러가 이번 스텝에 대응
    @info "[HAZARD] t=$(round(st.t; digits=2))s BREAKDOWN R$(try id.id catch; id end) (λ=$(round(st.lambda[id]; sigdigits=3))/s, mode=$mode, soc=$(round(soc; digits=3)))"
    return _hz_log!(st, :break, id, soc, mode, nl)
end

# --- 배터리 셀 열화 발화 -------------------------------------------------------------
# 낙폭을 확률적으로 뽑아 심각도를 가른다: 깊은 방전(→ canonical Replace) / 가벼운 열화(→ Deprioritize).
# battery_action 이 SoC 를 실제로 떨어뜨리고 BatteryTruth(심각도 채점의 근거)를 기록한다.
#
# ENACTMENT 제약(모형 제약이 아님): 깊은 방전은 downstream 에서 사실상 breakdown 으로 취급되어
# 스페어 인계(Replace)를 부르므로, 급작 고장과 똑같은 안전 조건(단독 frontier + 예비 존재)을
# 요구한다. 다인 운반팀 한가운데의 로봇을 깊은 방전시키면 팀이 형성 중에 끼어(wedge) 빌드가
# 멈춘다 — 실제로 첫 e2e 에서 t=2.9s 에 그렇게 되어 270초를 교착으로 날렸다.
# 가벼운 열화는 soft Deprioritize 로 끝나므로 아무 로봇에게나 자유롭게 발화한다.
#
# --- CRN 누수 수정 (spec §5.7) -------------------------------------------------------------
# 원래 코드는 안전 가드보다 **먼저** rand 를 불렀고, 가드가 유예시키면 그 뽑기가 버려졌다.
# 가드가 낙폭에 의존하므로(깊은 방전인가?) 가드를 앞으로 옮길 수는 없다 — 그래서 **캐시**한다.
# 유예 중에는 같은 낙폭을 재사용하고, 사건이 실제로 성사된 순간에만 캐시를 비운다.
# 그 결과 로봇 r 의 "n 번째 셀 사건"은 어느 팔에서든 같은 낙폭을 갖는다(= CRN 이 산다).
function _hz_draw_cell_drop!(st::HazardState, id)
    haskey(st.pending_drop, id) && return st.pending_drop[id]
    p = st.params
    rng = _robot_rng(st, id)
    drop = rand(rng) < p.cell_severe_frac ? p.cell_severe_drop :
           (p.cell_mild_lo + (p.cell_mild_hi - p.cell_mild_lo) * rand(rng))
    st.pending_drop[id] = drop
    return drop
end

_hz_commit_cell_drop!(st::HazardState, id) = (delete!(st.pending_drop, id); nothing)

function _hz_fire_cell!(env, st::HazardState, id, soc, mode)
    p = st.params
    BATTERY_FLEET[] === nothing && return nothing        # 배터리 계층이 없으면 이 위험은 의미 없음
    drop = _hz_draw_cell_drop!(st, id)      # 유예되면 같은 값을 재사용한다(CRN, spec §5.7)
    # 이 낙폭이 "깊은 방전"인지 = 결과 SoC 가 canonical Replace 임계 이하로 떨어지는지.
    thr_replace = isdefined(@__MODULE__, :REPLACE_SOC_THRESHOLD) ? REPLACE_SOC_THRESHOLD[] : 0.2
    if max(0.0, soc - drop) <= thr_replace               # 깊은 방전 -> 고장과 동일한 안전 조건 요구
        p.fire_safe_target && !_hz_safe_target(env, id) && return nothing
        if p.fire_require_spare
            (try nearest_pool(_ood_robot_pos2d(env, id)) catch; nothing end) === nothing && return nothing
        end
    end
    nl = try
        battery_action(; target = id, soc_drop = drop)(env)
    catch err
        @warn "[HAZARD] cell-degradation injection failed; deferring" robot = id err = err
        nothing
    end
    (nl === nothing || isempty(nl)) && return nothing
    _hz_commit_cell_drop!(st, id)                         # 사건이 실제로 났다 → 다음 사건은 새로 뽑는다
    st.cum_cell[id] = 0.0                                 # 재장전: 같은 로봇이 다시 열화될 수 있다
    st.thr_cell[id] = _exp1(_robot_rng(st, id))           # 같은 로봇 스트림에서 이어 뽑음(순서 고정)
    push_ood!(nl)
    soc_after = get(BATTERY_FLEET[].soc, id, soc)
    @info "[HAZARD] t=$(round(st.t; digits=2))s CELL-DEGRADATION R$(try id.id catch; id end) drop=$(round(drop; digits=2)) -> soc=$(round(soc_after; digits=3))"
    return _hz_log!(st, :cell, id, soc_after, mode, nl)
end

# --- 통행금지 구역 출현 발화 ---------------------------------------------------------
function _hz_fire_zone!(env, st::HazardState)
    st.zone_ct += 1
    key = Symbol("zone_hz_$(st.zone_ct)")
    # 배치 난수도 발생 순번으로 결정론적 시드를 준다 → "n 번째 zone"은 어느 팔에서든 같은 자리.
    zseed = _mix_seed(st.seed, 0x3, UInt64(st.zone_ct))
    nl = try
        zone_action(; key = key, seed = zseed)(env)       # ZoneTruth 기록까지 해주는 기존 래퍼
    catch err
        @warn "[HAZARD] zone injection failed; deferring" err = err
        nothing
    end
    st.cum_zone = 0.0                                     # 전역 위험은 항상 재장전
    st.thr_zone = _exp1(st.rng_zone)
    (nl === nothing || isempty(nl)) && return nothing
    push_ood!(nl)
    @info "[HAZARD] t=$(round(st.t; digits=2))s NO-GO ZONE appeared ($key)"
    return _hz_log!(st, :zone, nothing, NaN, :global, nl)
end

# -----------------------------------------------------------------------------
# Step-hook chaining (battery accounting must run FIRST so SoC is current)
# -----------------------------------------------------------------------------
const _HAZARD_PREV_STEP_HOOK = Ref{Any}(nothing)     # 우리가 덮어쓰기 전에 설치돼 있던 스텝 훅

# 체인 함수: 이전 훅(보통 배터리 회계)을 먼저 부르고, 그 다음 위험 프로세스를 전진시킨다.
# 순서가 중요 — SoC 를 이번 스텝 값으로 갱신한 뒤에 λ(soc) 를 계산해야 한다.
function _hazard_step_chain(env, prev_pos)
    h = _HAZARD_PREV_STEP_HOOK[]
    h === nothing || h(env, prev_pos)
    hazard_step!(env)
    return nothing
end

"""
    install_hazard_step_hook!()

Chain `hazard_step!` onto `route_planning.BATTERY_STEP_HOOK`, preserving whatever
was installed before (normally `account_battery_step!`, which must run first so SoC
is current when λ(soc) is evaluated). Idempotent.
"""
# 기존 스텝 훅을 보존한 채 그 뒤에 hazard_step! 을 잇는다(여러 번 불러도 안전).
function install_hazard_step_hook!()
    BATTERY_STEP_HOOK[] === _hazard_step_chain && return nothing   # 이미 체이닝됨
    _HAZARD_PREV_STEP_HOOK[] = BATTERY_STEP_HOOK[]
    BATTERY_STEP_HOOK[] = _hazard_step_chain
    return nothing
end

# -----------------------------------------------------------------------------
# Reporting / features
# -----------------------------------------------------------------------------
"""
    hazard_features(env) -> Dict{Any,NamedTuple}

Per-robot PHYSICAL descriptors of the failure process right now: `(soc, usage_s,
u_hat, lambda, mode, p_fail_60s, broken)`. These are exactly the kind-agnostic
features design §8.1 wants the surrogate to read (no OOD-kind one-hot), so a
never-before-seen event still lands inside φ(s).
"""
# 지금 이 순간의 로봇별 "물리 서술자" — 설계 §8.1 이 요구하는 kind-비의존 특징 그대로.
# p_fail_60s = 현재 λ 가 유지된다고 볼 때 앞으로 60초 안에 고장 날 확률(1 − exp(−λ·60)).
function hazard_features(env)
    out = Dict{Any,NamedTuple}()
    hazard_enabled() || return out
    st = HAZARD_STATE[]
    fleet = BATTERY_FLEET[]
    modes = _hz_modes(env)
    for id in _hz_all_robots(env)
        _hz_ensure!(st, id)
        mode = get(modes, id, :idle)
        soc  = (fleet === nothing) ? 1.0 : get(fleet.soc, id, 1.0)
        λ    = hazard_rate(st, id; mode = mode, soc = soc)
        out[id] = (soc = soc, usage_s = st.usage_s[id],
                   u_hat = st.params.usage_scale_s > 0 ? st.usage_s[id] / st.params.usage_scale_s : 0.0,
                   lambda = λ, mode = mode,
                   p_fail_60s = 1.0 - exp(-λ * 60.0),
                   broken = id in st.broken)
    end
    return out
end

"""
    hazard_report() -> NamedTuple

Run summary: sim seconds elapsed, event counts by kind, the event log, and — crucially
for honest reporting — the number of clocks that CROSSED their threshold but could not
be ENACTED (`n_break_pending` / `n_cell_pending`).

That distinction matters: a run with 0 breakdowns because no clock crossed is a
statement about the MODEL, whereas a run with 0 breakdowns and 3 pending is a statement
about the ENGINE (`fire_safe_target` / `fire_require_spare` refused to break a robot
mid multi-robot carry). Silently reporting only "0 events" would conflate the two.
"""
# 실행 요약: 흘러간 시뮬 시간, 종류별 사건 수, 사건 로그, 그리고 "문턱은 넘었으나 안전하게
# 발화시키지 못해 유예된" 시계 수. 이 구분이 중요하다 — 사건 0건이 "모형상 안 일어났다"인지
# "엔진이 못 일으켰다"인지는 완전히 다른 이야기이고, 합쳐서 보고하면 거짓말이 된다.
function hazard_report()
    st = HAZARD_STATE[]
    st === nothing && return (t = 0.0, steps = 0, n_break = 0, n_cell = 0, n_zone = 0,
                              n_break_pending = 0, n_cell_pending = 0, capped = false,
                              events = NamedTuple[])
    n(k) = count(e -> e.kind === k, st.events)
    capped = length(st.events) >= st.params.max_events   # 상한에 걸려 더 못 만든 상태인가
    # 문턱을 넘었는데 아직 broken 이 아닌 로봇 = 발화가 유예된 고장 시계.
    pend_b = count(id -> !(id in st.broken) && st.cum_break[id] >= st.thr_break[id], keys(st.cum_break))
    pend_c = count(id -> !(id in st.broken) && st.cum_cell[id] >= st.thr_cell[id], keys(st.cum_cell))
    return (t = st.t, steps = st.step, n_break = n(:break), n_cell = n(:cell),
            n_zone = n(:zone), n_break_pending = pend_b, n_cell_pending = pend_c,
            capped = capped, events = st.events)
end

"""
    expected_hazard_events(st, horizon_s; n_robots, mode=:transit) -> NamedTuple

Back-of-envelope calibration aid: expected breakdown / cell events over `horizon_s`
sim seconds for `n_robots` robots held at reference conditions in `mode`, IGNORING
usage-wear and SoC growth (so it is a LOWER bound — the real process accelerates).
Use it to pick MTBFs that actually produce events inside your build length.
"""
# 보정 도우미: 기준 조건에서 horizon_s 초 동안 기대되는 사건 수(마모·방전 가속은 무시하므로 하한).
# 빌드 길이 안에 사건이 실제로 나오도록 MTBF 를 고를 때 쓴다.
function expected_hazard_events(st::HazardState, horizon_s::Real; n_robots::Int = 1,
                                mode::Symbol = :transit)
    p = st.params
    m = p.mode * _mode_mult(p, mode) * n_robots * Float64(horizon_s)
    return (breakdown = _rate(p.mtbf_break_s) * m,
            cell      = _rate(p.mtbf_cell_s) * m,
            zone      = _rate(p.mtbf_zone_s) * p.mode * Float64(horizon_s))
end
