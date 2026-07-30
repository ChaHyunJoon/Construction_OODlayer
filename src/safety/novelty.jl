# =============================================================================
#  novelty.jl -- "is this event outside the surrogate's training distribution?"
#                the RUNTIME (Julia) half of the covariate-novelty detector.
# =============================================================================
#
# THE GAP THIS CLOSES
# -------------------
# `wm4spacecraft_manufacturing/drift_detectors.py` already contains a validated covariate-shift
# novelty detector, and `compare_detectors.py` already established the non-obvious result that
# the SIGNAL matters more than the detector (value-residual is NOT a drift signal; covariate
# novelty is). But every bit of that runs in an offline replay of a finished .jsonl.
#
# The live decision path is Julia -- `navigator/controller.jl :: decide` -- and it contains no
# novelty check whatsoever. At runtime the surrogate is therefore trusted UNCONDITIONALLY,
# including on disturbance classes it has never seen. The leave-one-kind-out benchmark
# (`openworld_experiments.py loko`) measures what that costs: on a held-out kind the learned layer lands
# around regret 0.18-0.31 against an oracle fallback that is 0.
#
# This file puts the detector where the decision actually happens.
#
# THE GATE
# --------
#     p = conformal p-value of this event's novelty score against the calibration set
#
#     p <  eps   ->  :escalate    the surrogate has no support here. Verify candidates with the
#                                 TRUE planner (expensive, ~60 s, but regret 0).
#     p >= eps   ->  :trust       in-distribution; take the surrogate's ranking (~0.1 ms).
#
# This is the piece that makes the architecture's honest claim -- "a novel class is paid for
# ONCE at oracle price, and is free ever after" -- actually true at runtime, rather than an
# aspiration. Without it, a novel class is silently answered by an unsupported extrapolation.
#
# CALIBRATED ON PHYSICAL DESCRIPTORS, NOT CLASS NAMES
# ---------------------------------------------------
# The calibration ships from `export_novelty_calibration.py` and is fitted on the KIND-AGNOSTIC
# state descriptors. Calibrating on the legacy feature vector would make every new class novel
# for a purely clerical reason (its `kind_*` one-hot is all zeros, its sentinels unprecedented)
# -- a detector reacting to a naming convention rather than to physics. On descriptors, a new
# class that is physically LIKE a known one correctly reads in-distribution, and only genuinely
# unfamiliar physics escalates. That distinction is the entire value of the gate.
#
# NUMERICAL PARITY IS VERIFIED, NOT ASSUMED
# -----------------------------------------
# The exporter writes probe vectors with their Python-computed score and p-value;
# `tools/test_novelty.jl` replays them through this file and requires agreement to 1e-9. A
# re-implementation that silently drifts from the Python one would invalidate every offline
# result used to justify it.
#
# -----------------------------------------------------------------------------
# [한국어 설명]
# 이 파일이 하는 일: "지금 들어온 사건이 surrogate 가 학습한 분포 밖인가?"를 실행 중에 판정한다.
#
# 왜 필요한가: 이 감지기는 파이썬 쪽(drift_detectors.py)에 이미 만들어져 검증까지 끝났지만
#   오프라인 재생에서만 돈다. 실제 결정 경로(Julia controller.jl 의 decide)에는 novelty 검사가
#   전혀 없어서 처음 보는 종류에도 surrogate 를 무조건 믿는다. LOKO 실험이 그 손해를 보여준다.
#
# 판정 방식: 사건의 novelty 점수를 교정집합과 비교해 conformal p-value 를 낸다.
#   p < eps  → :escalate (믿지 말고 진짜 플래너로 검증. 비싸지만 regret 0)
#   p >= eps → :trust    (분포 안이므로 surrogate 랭킹 사용. 0.1 ms)
#   이 게이트가 있어야 "새로운 건 한 번만 비싸게 치르고 그 다음부터 공짜"라는 주장이 실제로 참이 된다.
#
# 무엇으로 교정하나: **물리 서술자**(kind-agnostic). 기존 특징으로 교정하면 새 종류는 "one-hot 이
#   전부 0"이라는 사무적 이유로 항상 novel 이 된다 = 물리가 아니라 이름표에 반응하는 감지기.
#
# 파이썬과 숫자가 같은지는 가정하지 않고 검증한다: exporter 가 (입력, 파이썬 결과) 쌍을 같이 실어
#   보내고 tools/test_novelty.jl 이 1e-9 이내 일치를 요구한다.
#
# [Julia 문법 참고]
#   · Base.@kwdef struct : 필드 기본값을 주는 구조체.
#   · JSON3.read(str)    : JSON 문자열 -> 객체(딕셔너리처럼 접근).
#   · clamp(x, lo, hi)   : 값을 범위 안으로 자름.
#   · sum(f, xs)         : xs 의 각 원소에 f 를 적용해 합.
# =============================================================================

"""
    NoveltyDetector

Fitted covariate-novelty detector: per-feature standardisation plus the in-distribution score
set used as the conformal calibration.
"""
struct NoveltyDetector
    feature_names::Vector{String}
    mu::Vector{Float64}
    sd::Vector{Float64}
    cap::Float64
    cal_scores::Vector{Float64}    # 정상(in-distribution) 점수들 = conformal 교정집합
    alpha::Float64                 # 기본 유의수준(게이트 eps 기본값으로 쓰임)
    p_floor::Float64
    meta::Dict{String,Any}
end

"현재 런타임에 설치된 감지기(없으면 nothing = 게이트 비활성)."
const NOVELTY_DETECTOR = Ref{Union{Nothing,NoveltyDetector}}(nothing)

novelty_detector() = NOVELTY_DETECTOR[]
set_novelty_detector!(d) = (NOVELTY_DETECTOR[] = d; nothing)
clear_novelty_detector!() = (NOVELTY_DETECTOR[] = nothing; nothing)

"""
Calibration blob format this loader understands (`export_novelty_calibration.FORMAT_VERSION`).
Bump on both sides together when the key layout changes.
"""
const NOVELTY_FORMAT_VERSION = 2

"""
The descriptor contract: the exact feature names, **in order**, that `event_descriptors`
produces. A calibration fitted to a different list (or the same list in a different order)
puts mu/sd on the wrong axes, so the loader refuses it rather than scoring nonsense.
"""
const NOVELTY_FEATURES = String[
    "harm", "work_at_risk", "resource_loss", "recovery_capacity", "progress", "slack",
]

"""
    CalibrationError

Thrown when a calibration file exists but does not match this build. Deliberately a distinct
type so callers can tell "no calibration installed" (fine, gate stays off) from "calibration
present but WRONG" (must not be silently ignored).
"""
struct CalibrationError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CalibrationError) = print(io, "CalibrationError: ", e.msg)

"""
    load_novelty_detector(path) -> NoveltyDetector

Load the calibration JSON produced by `export_novelty_calibration.py`. Installing it is a
separate step (`set_novelty_detector!`) so loading never has a side effect on a running sim.

VALIDATION (added 2026-07-30) -- the loader used to accept any JSON with the right keys. A
calibration file freezes "what counts as normal" for one descriptor definition and one
dataset; change either and the file is not wrong-but-close, it is **meaningless**, yet it
still loads and still returns confident p-values. Nothing errors, and the router quietly
routes on a band fitted to a distribution that no longer exists. So three things are checked
and any mismatch throws `CalibrationError`:

  1. `format_version` -- the blob layout this code knows how to read
  2. `feature_names`  -- must equal `NOVELTY_FEATURES` exactly (names AND order)
  3. shape            -- mu/sd lengths agree with the feature list, cal_scores non-empty

`descriptor_fingerprint` and `dataset_fingerprint` are carried for provenance and surfaced by
`novelty_report()`; the name comparison in (2) already subsumes the descriptor fingerprint.

(요약: 교정파일이 지금 빌드와 안 맞으면 조용히 쓰지 말고 즉시 에러를 던진다. 서술자 정의나
 데이터셋이 바뀐 교정은 "조금 틀린" 게 아니라 무의미한데, 예전 로더는 그냥 로드했다.)
"""
function load_novelty_detector(path::AbstractString)
    blob = JSON3.read(read(path, String))

    # ---- 1. format version -----------------------------------------------------------------
    if !haskey(blob, :format_version)
        throw(CalibrationError(
            "'$path' has no `format_version` (pre-2026-07-30 file). Regenerate it:\n" *
            "    python export_novelty_calibration.py            # uses the canonical dataset\n" *
            "  (wm_datasets.py defines which dataset that is.)"))
    end
    fv = Int(blob.format_version)
    if fv != NOVELTY_FORMAT_VERSION
        throw(CalibrationError(
            "'$path' is format_version=$fv but this build reads " *
            "v$NOVELTY_FORMAT_VERSION. Regenerate with export_novelty_calibration.py."))
    end

    # ---- 2. descriptor contract -------------------------------------------------------------
    # NOTE: the blob also carries `descriptor_fingerprint` (a hash of the same name list), but
    # comparing the names directly is strictly stronger than comparing their hash, and it needs
    # no SHA dependency -- ConstructionBots does not depend on SHA and adding a dep would force
    # a Pkg resolve on a manifest that is pinned to Julia 1.10.  So the fingerprint is recorded
    # for provenance only; THIS equality check is the enforcement.
    feat_names = String[String(s) for s in blob.feature_names]
    if feat_names != NOVELTY_FEATURES
        throw(CalibrationError(
            "'$path' was fitted on features\n    $(feat_names)\nbut this build computes\n" *
            "    $(NOVELTY_FEATURES)\nmu/sd would land on the wrong axes. Regenerate the " *
            "calibration, or revert the descriptor change in features_agnostic.py."))
    end

    # ---- shape sanity: mu/sd must match the declared feature count ---------------------------
    nf = length(feat_names)
    if length(blob.mu) != nf || length(blob.sd) != nf
        throw(CalibrationError(
            "'$path' declares $nf features but carries $(length(blob.mu)) mu / " *
            "$(length(blob.sd)) sd entries -- file is corrupt."))
    end
    if isempty(blob.cal_scores)
        throw(CalibrationError("'$path' has an empty `cal_scores` set; every p-value would " *
                               "be degenerate. Regenerate the calibration."))
    end

    meta = Dict{String,Any}()
    if haskey(blob, :meta)
        for (k, v) in pairs(blob.meta)
            meta[String(k)] = v
        end
    end
    meta["format_version"] = fv
    if haskey(blob, :dataset_fingerprint) && haskey(blob.dataset_fingerprint, :sha16)
        meta["dataset_fp"] = String(blob.dataset_fingerprint.sha16)
    end
    return NoveltyDetector(
        String[String(s) for s in blob.feature_names],
        Float64[Float64(x) for x in blob.mu],
        Float64[Float64(x) for x in blob.sd],
        Float64(blob.cap),
        Float64[Float64(x) for x in blob.cal_scores],
        haskey(blob, :alpha) ? Float64(blob.alpha) : 0.05,
        haskey(blob, :p_floor) ? Float64(blob.p_floor) : 1e-4,
        meta,
    )
end

"""
    novelty_score(det, x) -> Float64

RMS z-distance of `x` from the calibration mean, each z clipped to +/-cap.

Must match `drift_detectors.make_novelty` EXACTLY:
    z = clip((x - mu)/sd, -cap, cap);  score = sqrt(mean(z .^ 2))
The clip is what keeps a zero-variance feature from producing an infinite z.
(cap 은 분산이 0 인 특징에서 z 가 무한대로 튀는 것을 막는다 -- 파이썬 쪽과 같은 이유·같은 값.)
"""
function novelty_score(det::NoveltyDetector, x::AbstractVector{<:Real})
    length(x) == length(det.mu) ||
        error("novelty_score: expected $(length(det.mu)) features $(det.feature_names), got $(length(x))")
    s = 0.0
    @inbounds for i in eachindex(det.mu)
        z = clamp((Float64(x[i]) - det.mu[i]) / det.sd[i], -det.cap, det.cap)
        s += z * z
    end
    return sqrt(s / length(det.mu))
end

"""
    conformal_pvalue(det, score) -> Float64

Smoothed conformal p-value of `score` against the calibration set. A MORE novel point scores
higher, so fewer calibration points exceed it, so p is SMALL. Matches
`ConformalMartingaleDetector._pvalue`:  p = (gt + 0.5*(eq+1)) / (n+1), floored at `p_floor`.
"""
function conformal_pvalue(det::NoveltyDetector, score::Real)
    n = length(det.cal_scores)
    gt = 0; eq = 0
    @inbounds for r in det.cal_scores
        if r > score
            gt += 1
        elseif r == score
            eq += 1
        end
    end
    p = (gt + 0.5 * (eq + 1)) / (n + 1)
    return clamp(p, det.p_floor, 1.0)
end

"""
    novelty_verdict(x; eps) -> NamedTuple

The gate. Returns `(decision, p, score, novel)` where `decision` is

  `:trust`    -- in-distribution: the surrogate's ranking may be used (cheap path)
  `:escalate` -- novel: do NOT trust the surrogate; verify with the true planner
  `:no_gate`  -- no detector installed, so the gate expresses no opinion (fail-OPEN by design:
                 an un-calibrated deployment must not silently start refusing to decide)

Note the deliberate asymmetry: with no detector we fall back to the PREVIOUS behaviour (trust),
not to escalation, so installing this file changes nothing until a calibration is loaded.
(감지기가 없으면 예전 동작 그대로 = 이 파일을 넣는 것만으로는 아무것도 안 바뀐다.)
"""
function novelty_verdict(x::AbstractVector{<:Real}; eps::Union{Nothing,Real} = nothing)
    det = NOVELTY_DETECTOR[]
    det === nothing && return (decision = :no_gate, p = NaN, score = NaN, novel = false)
    e = eps === nothing ? det.alpha : Float64(eps)
    s = novelty_score(det, x)
    p = conformal_pvalue(det, s)
    novel = p < e
    return (decision = novel ? :escalate : :trust, p = p, score = s, novel = novel)
end

# =============================================================================
#  Live physical descriptors -- the Julia twin of features_agnostic.descriptors_from_row
# =============================================================================
# The descriptors MUST be computed the same way here as in the Python featurizer, otherwise the
# calibration is meaningless. Kept as a small, explicit function (rather than reaching into the
# planner) so it can also be fed by an LLM's estimate for a genuinely novel event -- which is
# precisely the open-world path: for an unknown class the LLM does not invent a DSL kind, it
# estimates these six numbers, and everything downstream keeps working unchanged.
#
# (파이썬 featurize 와 계산이 반드시 같아야 교정이 의미를 갖는다. 또한 이 함수는 "새 종류가 왔을 때
#  LLM 이 관찰을 읽고 채워 넣는 자리"이기도 하다 -- 새 DSL 종류를 발명하는 대신 숫자 6개를 추정한다.)

"참조 함대 크기: slack 정규화 상수. features_agnostic.FLEET_REF 와 반드시 같아야 함."
const NOVELTY_FLEET_REF = Ref(30.0)

"""
    event_descriptors(; soc, agent_pending, zone_overlap, severity, n_active, spare_count,
                        closed_at_fire, total_nodes, progress) -> Vector{Float64}

Build the 6 kind-agnostic descriptors, in the order
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]`.

(2026-07-28: the FORMULAS changed, the count did not. `work_at_risk` now divides by the PER-ROBOT
share of the remaining work rather than by all of it, so losing one robot no longer reads as "1.6%
at risk". `resource_loss` lost its fleet-size denominator. `harm` no longer reads `severity` on a
fault -- that field is the experimenter's answer key in the dumps and a constant 1.0 in deployment.)

Pass `NaN` for `soc` and a negative value for `zone_overlap` / `agent_pending` when the quantity
does not apply -- exactly the convention the dumps use, so the same numbers come out.
"""
function event_descriptors(; soc::Real = NaN, agent_pending::Real = -1.0,
                             zone_overlap::Real = -1.0, severity::Real = 0.0,
                             n_active::Real = 1.0, spare_count::Real = 0.0,
                             closed_at_fire::Real = 0.0, total_nodes::Real = 0.0,
                             progress::Real = 0.0)
    soc_f = Float64(soc)
    zov = Float64(zone_overlap)
    apend = Float64(agent_pending)
    nact = max(1.0, Float64(n_active))
    spare = max(0.0, Float64(spare_count))

    has_soc = isfinite(soc_f)
    is_spatial = isfinite(zov) && zov >= 0.0
    is_agent = isfinite(apend) && apend >= 0.0

    pending_total = Float64(total_nodes) - Float64(closed_at_fire)
    (isfinite(pending_total) && pending_total > 0) || (pending_total = 1.0)

    # ---- harm : 항상 "클수록 나쁨" ------------------------------------------------------
    # 배터리류는 부호를 뒤집어(1-soc) 다른 종류와 방향을 맞춘다.
    # 고장류는 **1.0(능력 100% 상실)** 로 고정한다. 예전에는 severity 를 그대로 읽었는데, 그
    # severity 는 학습 덤프에서 실험자가 붙인 정답표(fault=1.0 / faultidle=0.0)이고 실제 배포에서는
    # 모든 고장에 1.0 인 상수다(policy.jl). 즉 harm 으로 유해/무해 고장을 가르는 것은 학습 때만
    # 통하는 지름길이었다 -- 실측으로 확인(descriptor_ablation.py: 배포 조건에서 0.067→0.167 붕괴).
    # 유해/무해 판별은 아래 work_at_risk 가 측정값으로 맡는다.
    harm = has_soc ? (1.0 - soc_f) :
           (is_spatial ? zov : (is_agent ? 1.0 : Float64(severity)))
    harm = clamp(harm, 0.0, 1.0)

    # ---- work_at_risk : 이 사건이 위협하는 일의 크기 --------------------------------------
    # 분모가 "남은 일 전체"에서 "로봇 한 대 평균 몫(pending_total/n_active)"으로 바뀌었다.
    #   예전: 4 / 255            = 0.016   -> 죽은 로봇이 '별일 아님'으로 보였다
    #   지금: 4 / (255/22)        = 0.345   -> 심각도가 살아난다
    # 1.0 이면 평균 몫 이상을 혼자 쥐고 있다는 뜻. 함대가 커져도 의미가 희석되지 않는다.
    war = if is_agent
        per_robot_share = max(1e-9, pending_total / nact)
        apend / per_robot_share
    elseif is_spatial
        zov
    else
        0.0
    end
    war = clamp(war, 0.0, 1.0)

    # ---- resource_loss : "그 로봇이 잃은 능력" --------------------------------------------
    # 분모(/함대크기)를 없앴다. 예전 (1-soc)/nact 는 죽은 로봇을 4% 로 보이게 했다.
    # 공간 사건은 로봇에 붙은 사건이 아니므로 0 -> 이 값이 "로봇 사건 vs 공간 사건"을 담는 축이다.
    # 결정 품질만 보면 harm 과 중복이라 한 번 뺐었지만, 빼자 새 종류 탐지율이 반토막 나서 되살렸다
    # (zoneblk 0.67->0.33, 되살리니 1.00). 결정에 불필요해도 판별에는 필수인 특징이다.
    rloss = if is_agent
        cap_left = has_soc ? clamp(soc_f, 0.0, 1.0) : 0.0
        1.0 - cap_left
    else
        0.0
    end
    rloss = clamp(rloss, 0.0, 1.0)

    rcap = spare / max(1.0, spare + nact)
    slack = clamp(nact / NOVELTY_FLEET_REF[], 0.0, 1.0)

    # 순서는 파이썬 STATE_DESCRIPTORS 와 반드시 동일해야 한다(교정값이 이 순서로 만들어진다).
    return Float64[harm, war, rloss, rcap, clamp(Float64(progress), 0.0, 1.0), slack]
end

# =============================================================================
#  Escalation gate -- WHICH SIGNAL, and why it is not (only) covariate novelty
# =============================================================================
#
# MEASURED RESULT (`python openworld_experiments.py gate oracle/out/openworld_merged.jsonl`,
# 60 instances, leave-one-kind-out). Mean regret when escalating a MATCHED fraction of decisions
# to the true planner. The budget MUST be matched: a signal that simply escalates more looks
# better for free, so "beats always-surrogate" proves nothing. The random control is the test.
#
#     budget    random   novelty   margin   disagree
#       10%      0.091    0.083     0.100    0.000
#       20%      0.082    0.000     0.100    0.000
#       30%      0.071    0.000     0.100    0.000
#       40%      0.059    0.000     0.017    0.000
#       50%      0.050    0.000     0.000    0.000
#
#     disagree beats random at EVERY budget and reaches regret 0 with only 10% of decisions
#     verified; novelty also beats random at every budget (regret 0 from 20% on); margin 2/5.
#
# So the gate should be driven PRIMARILY by DECISION UNCERTAINTY (how split the ensemble is
# about which macro wins), with covariate novelty as the complementary second signal.
#
# HISTORICAL NOTE -- a retracted finding, kept so it is not re-derived
# -------------------------------------------------------------------
# On an earlier 20-30 instance sample this file claimed covariate novelty carried NO information
# (correlation with regret -0.04; the more-novel half even had LOWER regret) and offered a theory
# for it ("the kind-agnostic redesign made classes look similar, so there is nothing left to
# detect"). BOTH ARE WITHDRAWN. At n=60 the correlation is -0.316 and the separation is +0.200 in
# the correct direction. The earlier negative was UNDERPOWERED, not a real effect -- "cannot
# tell", not "no effect". The control was well designed; the sample was simply too small for the
# control to conclude anything either.
#
# The failure mode that SURVIVES a good representation is the one where the input is perfectly
# familiar but the decision is genuinely close -- and covariate novelty cannot see that by
# construction. Ensemble disagreement can: it asks "is the MODEL unsure?", which is the question
# that actually predicts regret.
#
# The two are complementary, not rivals: novelty guards against inputs outside the model's
# support, disagreement against decisions the model cannot resolve inside its support. Hence
# `escalation_verdict` below takes both and escalates if EITHER fires.
#
# WHAT IS AND IS NOT WIRED HERE
# -----------------------------
# `decision_margin` and `vote_disagreement` work off predicted values that the caller already
# has, so they are usable with any surrogate. `vote_disagreement` needs PER-MEMBER predictions,
# i.e. an ENSEMBLE export -- the currently deployed Julia surrogate is the LINEAR export
# (tools/demos.jl:726), which has no members and therefore cannot produce this signal. Wiring
# the empirically best gate end-to-end requires exporting the forest. That is recorded as the
# next step rather than silently pretended.
#
# [한국어] 측정 결과 요약 (60 instances, 한 종류씩 통째로 빼고 학습):
#   "플래너를 몇 번 부르는가"를 **똑같이 맞춰** 비교해야 한다. 많이 부르면 손해가 주는 건 당연하므로
#   "게이트가 그냥 surrogate 보다 낫다"는 아무 증거도 아니다. 무작위 대조군을 이겨야 진짜 신호다.
#     · 모델 내부 이견(disagreement) : 5/5 예산에서 무작위보다 좋음. **10% 만 불러도 손해 0**.
#     · 입력 낯섦도(covariate novelty): 5/5 예산에서 좋음. 20% 이상이면 손해 0.
#     · 결정 마진(margin)            : 2/5. 별로 쓸모없음.
#   -> 1순위 신호는 "모델이 얼마나 갈리는가", 보조는 "입력이 얼마나 낯선가". 둘은 경쟁이 아니라
#      상보(하나는 모델이 아는 범위 '밖'을, 하나는 범위 '안'의 미해결을 잡는다)라서 아래 게이트는
#      **둘 중 하나라도 걸리면** 승격한다.
#
#   [철회된 옛 결론 — 다시 유도하지 말 것] 표본이 20~30 이던 시절 이 파일은 "입력 낯섦도는 정보가
#   없다"(상관 -0.04, 방향까지 반대)고 적었고, 그 이유로 "표현이 좋아져 종류들이 닮아졌으니 낯섦도가
#   반응할 게 없다"는 이론을 붙였다. **둘 다 철회한다.** n=60 에서 상관은 -0.316, 분리도 +0.200 으로
#   정상 작동한다. 그때 결과는 "효과 없음"이 아니라 **"표본이 작아 판정 불가"** 였다.
#
#   주의: vote_disagreement 는 앙상블 export 가 있어야 쓸 수 있다. 현재 Julia 에 배포된 것은 선형
#   export 라 이 신호를 못 만든다 -> 포레스트 export 가 다음 단계(숨기지 않고 명시).

"""
    decision_margin(values) -> Float64

Normalised gap between the best and second-best candidate value, in [0,1]. Small = the top two
are nearly tied, so the choice is fragile and worth verifying. `values` are the surrogate's
predicted values for the APPLICABLE macros only (gate by `valid_mask` first).
"""
function decision_margin(values::AbstractVector{<:Real})
    n = length(values)
    n < 2 && return 1.0
    v = sort(Float64.(values); rev = true)
    spread = v[1] - v[end]
    spread <= 1e-9 && return 0.0          # 전부 같은 값 = 구분 불가 = 최대 불확실
    return (v[1] - v[2]) / spread
end

"""
    vote_disagreement(member_values) -> Float64

Fraction of ensemble members that do NOT vote for the majority macro, in [0,1]. High = the model
is internally split. `member_values` is a vector (one per ensemble member) of vectors of
predicted values over the applicable macros, in a consistent macro order.

This is the signal that beat the random control at every budget.
"""
function vote_disagreement(member_values::AbstractVector)
    isempty(member_values) && return 0.0
    votes = Dict{Int,Int}()
    for vals in member_values
        isempty(vals) && continue
        best = argmax(Float64.(vals))
        votes[best] = get(votes, best, 0) + 1
    end
    total = sum(values(votes); init = 0)
    total == 0 && return 0.0
    return 1.0 - maximum(values(votes)) / total
end

"""
    escalation_verdict(; descriptors, values, member_values, eps, margin_thresh, disagree_thresh)

The runtime gate. Escalate to the true planner if EITHER
  * the input is outside the model's support (covariate novelty p < eps), or
  * the model cannot resolve the decision inside its support (margin too small / votes split).

Returns `(escalate::Bool, reason::Symbol, p, margin, disagreement)`, where `reason` is one of
`:novel_input`, `:uncertain_decision`, `:confident`, or `:no_signal`.

Every argument is optional: pass whatever the deployed surrogate can actually produce. With
nothing available the verdict is `:no_signal` and `escalate=false` -- fail-open, so installing
this file cannot by itself start refusing to decide.
(가진 신호만 넘기면 된다. 아무것도 없으면 예전 동작 그대로 = 이 파일만으로는 아무것도 안 바뀜.)
"""
function escalation_verdict(; descriptors::Union{Nothing,AbstractVector{<:Real}} = nothing,
                              values::Union{Nothing,AbstractVector{<:Real}} = nothing,
                              member_values::Union{Nothing,AbstractVector} = nothing,
                              eps::Union{Nothing,Real} = nothing,
                              margin_thresh::Real = 0.15,
                              disagree_thresh::Real = 0.35)
    p = NaN; margin = NaN; dis = NaN
    novel = false

    if descriptors !== nothing && NOVELTY_DETECTOR[] !== nothing
        v = novelty_verdict(descriptors; eps = eps)
        p = v.p; novel = v.novel
    end
    values !== nothing && (margin = decision_margin(values))
    member_values !== nothing && (dis = vote_disagreement(member_values))

    # 불확실성 신호가 1순위(측정상 가장 강함), covariate novelty 는 보조.
    uncertain = (isfinite(dis) && dis > disagree_thresh) ||
                (isfinite(margin) && margin < margin_thresh)

    if uncertain
        return (escalate = true, reason = :uncertain_decision, p = p, margin = margin, disagreement = dis)
    elseif novel
        return (escalate = true, reason = :novel_input, p = p, margin = margin, disagreement = dis)
    elseif !isfinite(p) && !isfinite(margin) && !isfinite(dis)
        return (escalate = false, reason = :no_signal, p = p, margin = margin, disagreement = dis)
    else
        return (escalate = false, reason = :confident, p = p, margin = margin, disagreement = dis)
    end
end

"""
    novelty_report() -> String

One-line summary of the installed detector, for run logs.
"""
function novelty_report()
    det = NOVELTY_DETECTOR[]
    det === nothing && return "[NOVELTY] no detector installed (gate inactive, fail-open)"
    return string("[NOVELTY] v", get(det.meta, "format_version", "?"),
                  " features=", join(det.feature_names, ","),
                  " n_cal=", length(det.cal_scores),
                  " alpha=", det.alpha,
                  " data_fp=", get(det.meta, "dataset_fp", "?"),
                  " src=", get(det.meta, "source", "?"))
end
