# =============================================================================
# tools/monitor/gen_ng1_pairs.jl — 게이트 N-G1 의 짝 데이터 생성기
#
#   julia +lts --project=. tools/monitor/gen_ng1_pairs.jl
#
# 무엇을 비교하는가: **같은 세계 위에서** 두 레인이 내는 "첫 사건까지의 시간" 분포.
#   (가) 경량 레인 = `sample_sojourn` (닫힌 형태 + D-6 rate boundary, dt 루프 없음)
#   (나) 무거운 레인 = 엔진의 `hazard_step!` **그 자체**가 dt 루프로 쌓은 Λ(t)
#
# 🔴 **무거운 레인을 어떻게 200번이 아니라 한 번만 굴리는가 — 그리고 왜 그게 더 정확한가.**
#   엔진의 위험 모형은 "Exp(1) 문턱 vs 누적 Λ(t)" 다(hazard.jl 헤더). 첫 사건 **전까지는**
#   세계가 사건에 영향받지 않으므로, Λ(t) 궤적 하나를 얻어 두면 문턱만 새로 뽑아 얼마든지
#   많은 τ 를 낼 수 있다. 그래서:
#     · `enable_hazard!` 뒤에 **문턱을 전부 `Inf` 로 덮는다** → 아무것도 발화하지 않는다
#       (= 명목 판 그대로 = `sample_sojourn` 이 가정하는 바로 그 세계).
#     · `hazard_step!` 은 **수정 없이** 돌면서 자기 `_hz_modes`·`_hz_excluded`·실제 soc·
#       실제 usage 로 `cum_break`/`cum_cell`/`cum_zone` 을 쌓는다. 그게 곧 Λ(t) 다.
#     · 그 궤적 위에서 문턱을 N 번 뽑아 첫 교차시각을 읽는다.
#   ⚠️ 이 방식이 재는 것은 **교차(crossing)** 이지 **발화(enactment)** 가 아니다.
#      `_hz_fire_break!` 의 `_hz_safe_target` 유예는 이 비교에 들어가지 않는다 —
#      `sample_sojourn` 에 유예 모형이 없기 때문이다(브리프의 진단 후보 (d)).
#
# 🔴 **`dt_sim` 양자화를 게이트에 들이지 않는다.** 교차시각을 스텝 격자로 반올림하면 두 분포에
#   `dt_sim` 눈금이 생기고, 게이트가 재는 것이 λ 가 아니라 **시계**가 된다(T8 의 D-6 표에서
#   중앙값 1.000 이 측정값이 아니라 눈금이었던 것과 같은 사고). 그래서 스텝 안에서
#   **선형 보간**해서 읽는다 — 엔진의 Euler 누적이 스텝 안에서 선형이라는 그 정의 그대로.
#
# 🔴 **표본 수 n 은 유도된 값이다**(측정값이 아니다). 아래 `_derive_n` 참조.
# =============================================================================
using ConstructionBots
import Random
import JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

# --- 유도: 게이트가 반드시 분해해야 하는 최소 격차 c*, 그리고 그것이 요구하는 n ----------
#
# 두 레인의 차이는 결국 **누적 위험의 배수** c = Λ_light/Λ_heavy 로 요약된다(τ 의 생존함수가
# 정확히 exp(−Λ) 이므로). 배수 c 가 만드는 두 생존함수의 최대 간격은 닫힌 형태다:
#
#     g(c) = sup_u |e^{−cu} − e^{−u}| = c^{−1/(c−1)} − c^{−c/(c−1)}
#
# KS 2표본 검정의 α 임계값은 D_crit = K_α·√(1/n₁+1/n₂). 그러므로 게이트가 c 를 분해하려면
#
#     K_α·√(2/n) ≤ g(c)      ⟺      n ≥ 2·(K_α/g(c))²
#
# 🔴 **c\* 를 무엇으로 잡는가 — 여기가 이 게이트의 유일한 설계 자유도이고, 측정이 아니라
#    유도로 정한다.** D-6 이 만드는 오차는 "모드가 바뀌는 시점을 틀리는 것"이고, 그것이 λ 에
#    남기는 흔적은 `_mode_mult` 의 **인접 모드 배수비**다. 잴 수 있어야 하는 가장 작은 사고는
#    **함대 N 대 중 한 대가 인접 모드 하나만큼 구간 내내 오분류되는 것**이므로
#
#     c* = (N − 1 + r_min) / N,      r_min = min(인접 배수비)
#
#    두 인자(N, r_min) 모두 **실행 시점의 살아 있는 값**에서 읽는다 — 리터럴을 박지 않는다.
#    ⚠️ zone 위험은 로봇 모드에 안 붙으므로 분모에 넣지 않았다. 넣으면 c* 가 1 에 더 가까워져
#       n 이 더 커진다 — 즉 이 c* 는 **덜 엄격한 쪽**이고, 게이트의 분해능 주장은 "로봇
#       부분계에 대해" 라고 읽어야 한다.
#
# 🔴 이 숫자들 중 어느 것도 다른 디렉토리에서 잰 잔차가 아니다. `K_α` 는 KS 분포의 상수,
#    `g` 는 지수분포의 항등식, `N`·`r_min` 은 이 프로세스가 지금 들고 있는 값이다.
const ALPHA = 0.01

# 🔴 KS 점근 임계계수를 **손으로 옮기지 않는다**(수정 1라운드, minor 3). 두 곳(여기와
#    `gate_ng1.py`)에 같은 리터럴을 박아 두는 것은 이 레포의 단일 출처 규칙 위반이다.
#    한쪽이 다른 쪽을 베끼게 만들 수도 없다 — 생성기가 먼저 돌면서 이 값으로 n 을 정해야
#    하므로 Python 이 쓴 값을 읽을 수가 없다. 그래서 **각자 독립으로 유도**하고 게이트가
#    둘을 대조한다(그게 베끼는 단일 출처보다 강하다).
#
#    Kolmogorov 분포: `P(√n·D ≤ λ) = 1 − Q(λ)`,  `Q(λ) = 2 Σ_{k≥1} (−1)^{k−1} e^{−2k²λ²}`.
#    `Q(λ) = α` 를 이분법으로 푼다(Q 는 λ 에 대해 단조감소).
_ks_Q(λ::Float64) = 2.0 * sum((-1.0)^(k - 1) * exp(-2.0 * k^2 * λ^2) for k in 1:200)
function _ks_critical(α::Float64)
    0.0 < α < 1.0 || error("_ks_critical: α = $(α)")
    lo, hi = 0.1, 10.0
    _ks_Q(lo) > α > _ks_Q(hi) || error("_ks_critical: 이분 구간이 α 를 감싸지 않는다")
    for _ in 1:200
        mid = 0.5 * (lo + hi)
        _ks_Q(mid) > α ? (lo = mid) : (hi = mid)
    end
    return 0.5 * (lo + hi)
end
const K_ALPHA = _ks_critical(ALPHA)

ks_sup_gap(c::Float64) = c == 1.0 ? 0.0 :
    (c^(-1.0 / (c - 1.0)) - c^(-c / (c - 1.0)))

function derive_c_star(p::CB.HazardParams, n_fleet::Int)
    mults = sort!(Float64[p.mult_idle, 1.0, p.mult_manip, p.mult_carry])   # :transit = 1.0 기준
    length(unique(mults)) == length(mults) ||
        error("derive_c_star: 모드 배수에 중복이 있다 $(mults) — 인접비가 1 이 되어 c* 가 " *
              "1 로 무너진다(게이트가 어떤 n 으로도 분해 못 한다)")
    r_min = minimum(mults[i + 1] / mults[i] for i in 1:(length(mults) - 1))
    r_min > 1.0 || error("derive_c_star: r_min = $(r_min) ≤ 1")
    n_fleet >= 1 || error("derive_c_star: 함대가 비어 있다")
    return ((n_fleet - 1) + r_min) / n_fleet, r_min
end

derive_n(c_star::Float64) = ceil(Int, 2.0 * (K_ALPHA / ks_sup_gap(c_star))^2)

# --- 씬 (SCENE-INCANTATION.md 정본) ------------------------------------------
const HZ_SEED = 7
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng1",
                         num_robots = 6, assignment_mode = :greedy,
                         n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = HZ_SEED)

# 🔴 문턱을 `Inf` 로 덮는다 — **프로브 스텝을 찾는 동안에도** 아무것도 발화하지 않게.
#    `hazard_step!` 자체는 손대지 않는다: 자기 `_hz_modes`·`_hz_excluded`·실제 soc·실제 usage
#    로 `cum_*` 를 그대로 쌓는다. 그게 곧 우리가 재려는 Λ(t) 다.
function _freeze_thresholds!(st)
    for id in keys(st.thr_break); st.thr_break[id] = Inf; end
    for id in keys(st.thr_cell);  st.thr_cell[id]  = Inf; end
    st.thr_zone = Inf
    return nothing
end
const HST = CB.HAZARD_STATE[]
_freeze_thresholds!(HST)

const BP     = CB.BATTERY_FLEET[].params
const DT_SIM = env.dt * BP.seconds_per_step
const NSTEP_H = parse(Int, get(ENV, "NG1_STEPS", "800"))   # 무거운 레인의 관측창 (스텝)
const H       = NSTEP_H * DT_SIM          # [s]

# 🔴 프로브 스텝을 **발견**한다(스텝 번호를 인용하지 않는다 — SCENE-INCANTATION §2).
function discover_probe(env, maxstep::Int)
    for k in 1:maxstep
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); CB.set_sim_step!(k)
        s  = CB.simstate_of(env)
        ms = CB.modes_of(s, env)
        Δ  = CB.T_plan_next(s, env)
        if length(s.fleet) >= 2 && !isempty(CB.active_of(s)) &&
           length(unique(values(ms))) >= 2 && isfinite(Δ) && Δ > 0.0
            return (k, s)
        end
    end
    return (0, nothing)
end
const PROBE, S0 = discover_probe(env, 320)
PROBE > 0 || error("gen_ng1_pairs: 320 스텝 안에 비퇴화 스텝이 없다")
const KS_FLEET = sort!(collect(keys(S0.fleet)))
@info "N-G1 프로브 스텝(발견)" step=PROBE n_fleet=length(KS_FLEET) dt_sim=DT_SIM horizon_s=H nstep_h=NSTEP_H

const C_STAR, R_MIN = derive_c_star(CB.HazardParams(), length(KS_FLEET))
# ⚠️ `NG1_N` 은 **연기(smoke) 전용 손잡이**다. 이걸로 n 을 줄이면 게이트의 RESOLUTION 검사가
#    스스로 빨개진다(`D_crit > g(c*)`) — 즉 이 손잡이로는 초록을 만들 수 없다. 조용한 폴백이
#    아닌 이유가 그것이다.
const N_SAMP        = parse(Int, get(ENV, "NG1_N", string(derive_n(C_STAR))))
const NG1_SMOKE     = haskey(ENV, "NG1_N")
@info "N-G1 유도된 분해능" c_star=C_STAR r_min=R_MIN sup_gap=ks_sup_gap(C_STAR) alpha=ALPHA n_required=derive_n(C_STAR) n_used=N_SAMP smoke=NG1_SMOKE

const N_MAX = 40_000
N_SAMP <= N_MAX ||
    error("gen_ng1_pairs: 유도된 n = $(N_SAMP) 가 상한 $(N_MAX) 을 넘는다 — 게이트가 c* 를 " *
          "분해할 수 없다. 초록으로 넘기지 않는다")

# --- 경량 레인 ---------------------------------------------------------------
"`p` 로 n 개 표집. **env 를 앞으로 밀기 전에** 돌아야 한다(modes_of 가 살아 있는 env 를 읽는다)."
function light_lane(S0, env, p, bp, n::Int, H::Float64; seed0::Int = 0)
    τs   = Vector{Float64}(undef, n)
    kds  = Vector{String}(undef, n)
    nb   = 0
    for j in 1:n
        τ, ev, b = CB.sample_sojourn_traced(S0, env, p, bp, Random.MersenneTwister(seed0 + j);
                                            delta_max = H)
        τs[j] = τ; kds[j] = String(CB.event_kind(ev)); nb += b
    end
    return τs, kds, nb
end

# 🔴 전역 mode 배수 M 도 **발견**한다: 중앙값 τ 가 관측창의 `MED_LO`~`MED_HI` 안에 들어와야 한다.
#    너무 작으면(= M 이 크면) 창 안에서 다 터져 D-6 이 흔적을 남길 시간이 없고, 너무 크면
#    대부분 검열된다.
#    ⚠️ 이 주석은 한때 "20~50%" 라고 적어 두고 아래 상수는 0.10/0.30 이었다(수정 2라운드에
#       발견). 띠는 **상수 하나에서만** 읽는다 — 주석에 숫자를 두 번 적지 않는다.
const MED_LO, MED_HI = 0.10, 0.30      # 중앙값이 관측창의 이 비율 안에 들어와야 한다
# 🔴 왜 이 띠인가(유도): 지수 근사에서 관측창 끝의 검열률은 `2^(-H/median)` 이다.
#    median = 0.30H → 10% 검열, median = 0.10H → 0.1% 검열. 위쪽은 **검열이 분포를 잡아먹지
#    않게**, 아래쪽은 **D-6 의 편향이 흔적을 남길 시간이 있게** 정한 것이고 둘 다 관측값이
#    아니라 이 항등식에서 온다.
function discover_mode(S0, env, bp, H::Float64)
    M = 1.0
    for _ in 1:24
        p = CB.HazardParams(mode = M)
        τs, _, _ = light_lane(S0, env, p, bp, 200, H)
        med = sort(τs)[100]
        cens = count(>=(H - 1e-12), τs) / length(τs)
        @info "N-G1 mode 후보" M=M median_tau=med censored=cens target_lo=MED_LO*H target_hi=MED_HI*H
        (MED_LO * H <= med <= MED_HI * H) && return M
        M *= 1.6
    end
    return 0.0
end
const MODE_M = discover_mode(S0, env, BP, H)
MODE_M > 0.0 || error("gen_ng1_pairs: 관측창 $(H) s 안에서 중앙값이 띠 안에 드는 전역 " *
                      "mode 배수를 못 찾았다 — 픽스처가 이 게이트를 지탱하지 못한다")
@info "N-G1 발견한 전역 mode 배수" M=MODE_M

const P_BASE = CB.HazardParams(mode = MODE_M)
light_tau, light_kinds, light_nb = light_lane(S0, env, P_BASE, BP, N_SAMP, H; seed0 = 0)

# --- 🔴 게이트 자신의 대조군 두 개 (엔진과 무관하게 **분해능만** 재는 순수한 짝) ---------
#
#   self-null : 같은 법칙 · 다른 시드    → 게이트가 **초록이어야** 한다(위양성 없음)
#   self-c*   : Λ 를 정확히 c* 배        → 게이트가 **빨개져야** 한다(유도한 분해능이 진짜인가)
#
# 🔴 왜 light-vs-heavy 섭동이 아니라 light-vs-light 인가: baseline 이 이미 어떤 방향으로
#    치우쳐 있으면(실측: c_hat ≈ 0.89) 한쪽 방향의 섭동은 오히려 **일치를 개선한다** — 실제로
#    n=400 예비실행에서 `×c*` 섭동이 c_hat 을 0.889 → 1.017 로 **좋게** 만들었다. 그러면 그
#    음성 대조는 분해능이 아니라 baseline 편향의 부호를 잰 것이 된다. light-vs-light 짝은
#    두 레인의 차이가 **정확히 c\*** 하나뿐이라 그 혼동이 원리적으로 없다.
selfnull_tau, selfnull_kinds, _ = light_lane(S0, env, P_BASE, BP, N_SAMP, H; seed0 = 5_000_000)
selfneg_tau,  selfneg_kinds,  _ = light_lane(S0, env, CB.HazardParams(mode = MODE_M * C_STAR),
                                             BP, N_SAMP, H; seed0 = 5_000_000)

# 🔴 진단 (c) 전용 레인 — 브리프가 시킨 대로 **ρ 를 바꿔 가며** KS 가 단조로 움직이는지 본다.
#    움직이면 두 레인을 가르는 것은 D-6 의 rate boundary 다.
rho_lanes = Dict{String,Any}()
for r in (0.5, 1.5, 2.0)
    old_rho = CB.RHO[]
    try
        CB.RHO[] = r
        τs, kds, _ = light_lane(S0, env, P_BASE, BP, N_SAMP, H)
        rho_lanes[string(r)] = (rho = r, tau = τs, kinds = kds)
    finally
        CB.RHO[] = old_rho
    end
end
CB.RHO[] == 1.0 || error("gen_ng1_pairs: RHO 복원 실패 — $(CB.RHO[])")

# --- 무거운 레인 -------------------------------------------------------------
const RIDS = [CB.robot_id_of(k) for k in KS_FLEET]     # 이슈 C 의 역지도를 실제로 쓴다
const st   = HST

# 🔴 **두 레인이 같은 파라미터를 써야 한다.** `enable_hazard!` 는 기본 `HazardParams()`(mode=1)
#    로 상태를 만들었는데 경량 레인은 발견된 `MODE_M` 을 쓴다 — 그대로 두면 게이트가 **λ 가
#    $(MODE_M) 배 다른 두 세계**를 비교한다(첫 연기 실행에서 실제로 그렇게 새서 heavy 의 87%가
#    검열됐다). 발화는 문턱 동결로 이미 꺼져 있으므로 파라미터를 바꿔도 **세계 궤적은 그대로**
#    이고 Λ 만 옳은 배수를 갖는다.
st.params = P_BASE
st.params === P_BASE || error("gen_ng1_pairs: HazardState.params 갱신 실패")

# 🔴 **Λ 의 원점을 프로브 스텝으로 옮긴다.** `st.cum_*` 는 스텝 0 부터의 절대 누적이라
#    그대로 쓰면 프로브 이전 $(PROBE) 스텝(= $(PROBE*DT_SIM) s)의 위험이 τ 에 섞여 들어간다
#    (첫 연기 실행에서 `cum_zone` 이 정확히 그만큼 부풀어 있었다). 발화가 꺼져 있으므로
#    0 으로 되돌리는 것이 세계에 아무 영향이 없다.
for id in keys(st.cum_break); st.cum_break[id] = 0.0; end
for id in keys(st.cum_cell);  st.cum_cell[id]  = 0.0; end
st.cum_zone = 0.0

cum_b = Dict(k => Float64[0.0] for k in KS_FLEET)
cum_c = Dict(k => Float64[0.0] for k in KS_FLEET)
cum_z = Float64[0.0]
n_exposed = Int[]
for j in 1:NSTEP_H
    CB.step_environment!(env)
    CB.update_planning_cache!(env, 0.0)
    CB.set_sim_step!(PROBE + j)
    _freeze_thresholds!(st)                # 새로 등록된 로봇도 발화하지 않게
    excl = CB._hz_excluded()
    push!(n_exposed, count(r -> !(r in excl), RIDS))
    for (i, k) in enumerate(KS_FLEET)
        rid = RIDS[i]
        push!(cum_b[k], Float64(get(st.cum_break, rid, last(cum_b[k]))))
        push!(cum_c[k], Float64(get(st.cum_cell,  rid, last(cum_c[k]))))
    end
    push!(cum_z, Float64(st.cum_zone))
end
length(st.events) == 0 ||
    error("gen_ng1_pairs: 무거운 레인에서 사건이 $(length(st.events)) 개 발화했다 — 문턱 " *
          "동결이 새고 있다. 궤적이 더는 '사건 이전의 세계' 가 아니다")

"단조 비감소 배열에서 `E` 를 처음 넘는 시각. 스텝 **안에서 선형 보간**한다(양자화 금지)."
function first_cross(cum::Vector{Float64}, E::Float64, dt::Float64)
    @inbounds for j in 2:length(cum)
        if cum[j] >= E
            d = cum[j] - cum[j - 1]
            frac = d > 0.0 ? (E - cum[j - 1]) / d : 0.0
            return (j - 2 + clamp(frac, 0.0, 1.0)) * dt
        end
    end
    return Inf
end

function heavy_lane(n::Int, H::Float64, dt::Float64)
    τs  = Vector{Float64}(undef, n)
    kds = Vector{String}(undef, n)
    for j in 1:n
        # 🔴 **경량 레인과 시드를 겹치지 않게 한다.** CRN 으로 짝을 지으면 두 ECDF 가 양의
        #    상관을 갖는데, KS 2표본 검정의 귀무분포는 **독립**을 전제한다 — 짝지으면 통계량이
        #    작아져 검정이 보수적이 되고, 그건 곧 **표본 때문에 나오는 초록**이다(이 게이트가
        #    막으려는 바로 그것). 그래서 독립 스트림을 쓴다.
        rng = Random.MersenneTwister(1_000_000 + j)
        Eb = Dict(k => CB._exp1(rng) for k in KS_FLEET)
        Ec = Dict(k => CB._exp1(rng) for k in KS_FLEET)
        Ez = CB._exp1(rng)
        best, kind = Inf, "horizon"
        for k in KS_FLEET
            d = first_cross(cum_b[k], Eb[k], dt); d < best && (best = d; kind = "break")
            d = first_cross(cum_c[k], Ec[k], dt); d < best && (best = d; kind = "cell")
        end
        d = first_cross(cum_z, Ez, dt); d < best && (best = d; kind = "zone")
        if !isfinite(best) || best > H
            τs[j] = H; kds[j] = "horizon"
        else
            τs[j] = best; kds[j] = kind
        end
    end
    return τs, kds
end
heavy_tau, heavy_kinds = heavy_lane(N_SAMP, H, DT_SIM)

_med(v) = sort(v)[max(1, div(length(v), 2))]
@info "N-G1 레인 요약" n=N_SAMP median_light=_med(light_tau) median_heavy=_med(heavy_tau) censored_light=count(==("horizon"), light_kinds) censored_heavy=count(==("horizon"), heavy_kinds) terminal_light=count(==("terminal"), light_kinds) boundaries_per_sample=(light_nb / N_SAMP) dt_loop_steps_per_sample=(_med(light_tau) / DT_SIM) exposed_min=minimum(n_exposed) exposed_max=maximum(n_exposed) lambda_zone_end=last(cum_z)

# --- 출력 -------------------------------------------------------------------
meta = Dict(
    "alpha" => ALPHA, "k_alpha" => K_ALPHA,
    "c_star" => C_STAR, "r_min" => R_MIN, "sup_gap_at_c_star" => ks_sup_gap(C_STAR),
    "n_derived" => derive_n(C_STAR), "n_used" => N_SAMP, "smoke" => NG1_SMOKE,
    "n_fleet" => length(KS_FLEET),
    "probe_step" => PROBE, "dt_sim" => DT_SIM, "horizon_s" => H, "nstep_h" => NSTEP_H,
    "global_mode" => MODE_M, "hazard_seed" => HZ_SEED,
    "heavy_events_fired" => length(st.events),
    "exposed_min" => minimum(n_exposed), "exposed_max" => maximum(n_exposed),
    "boundaries_per_sample" => light_nb / N_SAMP,
)
outdir = joinpath(pkgdir(CB), "results", "smdp")
mkpath(outdir)
open(joinpath(outdir, "ng1_pairs.json"), "w") do io
    JSON3.write(io, Dict("light_tau" => light_tau, "heavy_tau" => heavy_tau,
                        "light_kinds" => light_kinds, "heavy_kinds" => heavy_kinds,
                        "meta" => merge(meta, Dict("lane" => "baseline", "perturb_c" => 1.0))))
end
open(joinpath(outdir, "ng1_selfnull.json"), "w") do io
    JSON3.write(io, Dict("light_tau" => light_tau, "heavy_tau" => selfnull_tau,
                        "light_kinds" => light_kinds, "heavy_kinds" => selfnull_kinds,
                        "meta" => merge(meta, Dict("lane" => "self-null (must PASS)",
                                                   "perturb_c" => 1.0))))
end
open(joinpath(outdir, "ng1_selfneg_cstar.json"), "w") do io
    JSON3.write(io, Dict("light_tau" => light_tau, "heavy_tau" => selfneg_tau,
                        "light_kinds" => light_kinds, "heavy_kinds" => selfneg_kinds,
                        "meta" => merge(meta, Dict("lane" => "self-negative c* (must FAIL)",
                                                   "perturb_c" => C_STAR))))
end
for (tag, v) in sort!(collect(rho_lanes); by = first)
    open(joinpath(outdir, "ng1_pairs_rho_$(tag).json"), "w") do io
        JSON3.write(io, Dict("light_tau" => v.tau, "heavy_tau" => heavy_tau,
                            "light_kinds" => v.kinds, "heavy_kinds" => heavy_kinds,
                            "meta" => merge(meta, Dict("lane" => "rho-probe-$(tag)",
                                                       "perturb_c" => 1.0, "rho" => v.rho))))
    end
end
@info "N-G1 짝 데이터 기록" dir=outdir files=string(vcat(["ng1_pairs.json"],
      ["ng1_selfnull.json", "ng1_selfneg_cstar.json"],
      ["ng1_pairs_rho_$(t).json" for t in sort!(collect(keys(rho_lanes)))]))
