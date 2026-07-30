# adaptation_metrics.jl
# ============================================================================
#  [한국어 안내] 이 파일 = "적응(adaptation) 성능 측정" 지표 모음
#  ---------------------------------------------------------------------------
#  프로젝트 역할:
#   · 서로 다른 적응 컨트롤러(예: LLM vs MARL)가 OOD 에 얼마나 잘 대처했는지 "공정하게 비교"하려면
#     공통 잣대가 필요하다 — 이 파일이 그 잣대(지표 함수들)를 정의한다.
#   · 아래 (A)~(D) 네 묶음으로 구성:
#       (A) 적응 품질   : 반응 지연/회복 시간/회복률 (이벤트 로그에서 계산)
#       (B) 결정 품질   : 내놓은 DSL 이 정답 OOD 와 얼마나 맞나(grounding P/R/F1), 종류별로도.
#       (C) 정규화 lift : "아무것도 안 함(바닥) ~ 오라클(천장)" 사이 어디에 있나 = 비교용 단일 숫자.
#       (D) 집계        : 시드별 평균±부트스트랩 CI, 짝지은 차이, 견고성/붕괴점 곡선.
#   · 전부 "순수 함수"라 목(mock) 데이터만으로 단독 테스트 가능(시뮬레이터 없이도).
#
#  문법 참고:
#   · NamedTuple = (a=1, b=2) 처럼 "이름 붙은 튜플"(가벼운 결과 묶음). 반환값으로 자주 씀.
#   · getproperty(e, :recovered_step) / hasproperty(e, :x) : 필드를 이름(심볼)으로 동적 접근/유무 확인.
#   · [x for x in xs if cond] : 조건부 리스트 컴프리헨션(필터링).
#   · x::AbstractVector{<:Real} : "실수류 원소를 담은 벡터"라는 타입 제약(<: = 하위타입).
#   · `조건 ? A : B` 삼항연산자, `A && B` = A 참일 때만 B 실행, `A || B` = A 거짓일 때만 B.
#   · _m(xs) = ... 처럼 함수 안에서 정의한 지역 도우미 함수. 앞의 _ 는 "내부용" 관례.
#   · @inbounds : 배열 경계검사 생략(속도 최적화 매크로).
# ============================================================================
# The metrics that let us COMPARE two adaptive controllers (LLM vs MARL) fairly:
#   (A) ADAPTATION QUALITY  — reaction latency, time-to-recover, recovery rate,
#                             from the per-OOD-event log a rollout records.
#   (B) DECISION QUALITY     — grounding P/R/F1 of the emitted DSL vs the ground-truth
#                             OOD, across ALL kinds (fault/zone/battery/reform).
#   (C) NORMALIZED LIFT      — the single comparable number: where a controller sits on
#                             the [no-adapt floor -> oracle ceiling] scale, per axis.
#   (D) AGGREGATION          — mean ± bootstrap CI over seeds; paired deltas across
#                             controllers on identical seeds; robustness/degradation
#                             curves + breakdown point over an OOD-difficulty sweep.
#
# Depends on: metrics.jl (RunMetrics, axis_costs, _z), llm_eval.jl (grounding_prf,
# optimality_gap), ood_truth.jl (grounding_against_truth, truth_key). Pure functions —
# standalone-testable with a mock run_pipeline.
# ============================================================================

# ---------------------------------------------------------------------------------
# (A) ADAPTATION QUALITY — from a per-event log.
# Each event is a NamedTuple with at least (step, kind, recovered_step); optionally
# (admitted_step) marking when the adaptation was admitted. recovered_step < 0 == the
# build never resumed progress after that event (unrecovered). This matches the log the
# DecPOMDP model records in `m.ood_events` (step, kind, closed_at, recovered_step).
# ---------------------------------------------------------------------------------
"""
    adaptation_from_events(events) -> NamedTuple

Reduce a per-OOD-event log to adaptation metrics:
  * `reaction_latency` — mean (admitted_step − step) over events that were acted on
                         (NaN if no `admitted_step` recorded);
  * `time_to_recover`  — mean (recovered_step − step) over RECOVERED events;
  * `recovery_rate`    — fraction of events that recovered (higher = better);
  * `n_events`, `n_recovered`.
"""
# (A) 이벤트 로그를 적응 지표로 요약. events = OOD 사건별 기록(각 사건 최소 step/kind/recovered_step 보유).
function adaptation_from_events(events)
    n = length(events)
    n == 0 && return (reaction_latency=NaN, time_to_recover=NaN, recovery_rate=NaN,
                      n_events=0, n_recovered=0)             # 사건이 없으면 전부 NaN
    recov = Float64[]     # (회복시각 - 발생시각) 모음
    react = Float64[]     # (대응 채택시각 - 발생시각) 모음
    n_rec = 0             # 회복된 사건 수
    for e in events
        rs = getproperty(e, :recovered_step)                # 회복 시점(음수면 끝내 회복 못 함)
        if rs !== nothing && rs >= 0
            n_rec += 1
            push!(recov, float(rs - e.step))                # 회복까지 걸린 스텝
        end
        if hasproperty(e, :admitted_step)                   # 이 필드가 있을 때만(선택적)
            as = getproperty(e, :admitted_step)
            (as !== nothing && as >= 0) && push!(react, float(as - e.step))  # 반응 지연
        end
    end
    _m(xs) = isempty(xs) ? NaN : sum(xs) / length(xs)       # 빈 배열이면 NaN, 아니면 평균 내는 도우미
    return (reaction_latency=_m(react), time_to_recover=_m(recov),
            recovery_rate=n_rec / n, n_events=n, n_recovered=n_rec)
end

# 기존 RunMetrics 에 이벤트 기반 적응 지표를 끼워 넣어 "새 RunMetrics" 반환(원본 불변).
"Splice adaptation-from-events results into a RunMetrics (returns a NEW RunMetrics)."
function with_adaptation(m::RunMetrics, events)
    a = adaptation_from_events(events)
    over = (:reaction_latency, :time_to_recover, :recovery_rate)   # fields we replace  # 덮어쓸 필드들
    # over 에 없는 나머지 필드는 원본 m 에서 그대로 복사(f => 값 쌍들의 제너레이터). ; base... = 키워드로 펼침(splat).
    base = (f => getfield(m, f) for f in fieldnames(RunMetrics) if !(f in over))
    return RunMetrics(; base...,
        reaction_latency=a.reaction_latency, time_to_recover=a.time_to_recover,
        recovery_rate=a.recovery_rate)
end

# ---------------------------------------------------------------------------------
# (B) DECISION QUALITY — grounding of emitted DSL vs ground-truth OOD, all kinds.
# `grounding_against_truth` (ood_truth.jl) already builds keyed sets via the extended
# `emitted_key`/`truth_key` (now covering battery->Deprioritize, reform->Reform). Here
# we add a per-kind breakdown so results can be sliced by OOD kind.
# ---------------------------------------------------------------------------------
"""
    decision_quality(emitted, truths) -> NamedTuple

Overall grounding P/R/F1 (all kinds) plus a `by_kind` Dict of per-kind F1. `emitted` is
a vector of ConstraintSpecs (e.g. `proposal.constraints`); `truths` a vector of OODTruth.
"""
# (B) 결정 품질: 전체 grounding P/R/F1 + OOD 종류(fault/zone/battery/reform)별 세부 채점.
function decision_quality(emitted, truths)
    overall = grounding_against_truth(emitted, truths)      # 종류 안 가리고 전체 채점
    by_kind = Dict{Symbol,NamedTuple}()                     # 종류 심볼 -> 그 종류만의 채점 결과
    kinds = unique(first(truth_key(t)) for t in truths)     # 등장한 종류들(키 튜플의 첫 원소 = 종류)
    for k in kinds
        tk = [t for t in truths if first(truth_key(t)) == k]  # 이 종류의 정답만
        # 이 종류의 지시만: `(kk = emitted_key(c); ...)` = 괄호 안에서 kk 계산 후 마지막 식(불리언)이 필터 조건.
        ek = [c for c in emitted if (kk = emitted_key(c); kk !== nothing && first(kk) == k)]
        by_kind[k] = grounding_against_truth(ek, tk)
    end
    return (precision=overall.precision, recall=overall.recall, f1=overall.f1,
            hallucinated=overall.hallucinated, missed=overall.missed,
            grounded=overall.grounded, by_kind=by_kind)
end

# ---------------------------------------------------------------------------------
# (C) NORMALIZED LIFT — THE single comparable number.
#   lift_norm(axis) = (cost_floor − cost_ctrl) / (cost_floor − cost_oracle)
# where floor == B0 (no-adapt) and oracle == best achievable enactment. 0 == no better
# than no-adaptation; 1 == matched the oracle; <0 == WORSE than doing nothing; >1 ==
# beat the oracle (rare). Reported per axis and as an unweighted mean over `order`.
# ---------------------------------------------------------------------------------
# guarded ratio: if floor≈oracle (the OOD barely mattered on this axis) the scale is
# undefined -> return 1.0 when the controller matched the (shared) value, else 0.0.
# (C) 정규화 lift 한 축 계산: (바닥비용 - 내 비용)/(바닥비용 - 오라클비용). 0=바닥과 동급, 1=오라클과 동급.
# 바닥≈오라클(그 축에선 OOD 가 별 영향 없음)이면 분모가 0에 가까워 정의 불가 -> 값이 바닥과 같으면 1.0, 아니면 0.0.
function _norm_ratio(cost_ctrl, cost_floor, cost_oracle; tol=1e-9)
    denom = cost_floor - cost_oracle
    if abs(denom) < tol
        return abs(cost_ctrl - cost_floor) < tol ? 1.0 : 0.0
    end
    return (cost_floor - cost_ctrl) / denom
end

"""
    lift_normalized(ctrl, floor, oracle; order) -> NamedTuple

Per-axis normalized lift of `ctrl` on the [floor(B0) -> oracle] scale, plus `mean`
(the headline scalar). All three are `RunMetrics`. Infeasible `ctrl` is clamped to a
lift of 0 on the completion axis regardless (an infeasible plan is never "adapted").
"""
# ctrl 컨트롤러의 축별 정규화 lift + 전체 평균(mean, 헤드라인 숫자). 세 인자 모두 RunMetrics.
function lift_normalized(ctrl::RunMetrics, floor::RunMetrics, oracle::RunMetrics;
        order::Vector{Symbol}=[:completion, :speed, :efficiency, :adaptability])
    cc = axis_costs(ctrl); cf = axis_costs(floor); co = axis_costs(oracle)  # 각각 축별 비용으로 변환
    vals = Tuple(_norm_ratio(getfield(cc, k), getfield(cf, k), getfield(co, k)) for k in order)  # 축마다 lift
    nt = NamedTuple{Tuple(order)}(vals)                    # 축 이름을 키로 붙여 NamedTuple 로 묶음
    return merge(nt, (mean = sum(vals) / length(vals),))   # 축 lift + 평균을 합쳐 반환
end

# ---------------------------------------------------------------------------------
# (D) AGGREGATION — mean ± bootstrap CI over seeds; paired deltas; robustness curves.
# ---------------------------------------------------------------------------------
# (D) 평균의 백분위 부트스트랩 신뢰구간(CI). seed 고정이라 결과 재현 가능. n=재표본 횟수, alpha=0.05 -> 95% CI.
"Percentile bootstrap CI of the mean (deterministic given `seed`)."
function bootstrap_ci(xs::AbstractVector{<:Real}; n::Int=2000, alpha::Float64=0.05, seed::Int=1)
    ys = Float64[x for x in xs if isfinite(x)]              # NaN/Inf 제거(유한값만)
    isempty(ys) && return (mean=NaN, lo=NaN, hi=NaN, n=0)
    length(ys) == 1 && return (mean=ys[1], lo=ys[1], hi=ys[1], n=1)  # 표본 1개면 CI 폭 0
    rng = Random.MersenneTwister(seed)                     # seed 고정 난수기 = 재현성
    means = Vector{Float64}(undef, n)                      # 재표본 평균 n개 담을 배열(미초기화)
    m = length(ys)
    @inbounds for b in 1:n                                 # n번 반복: 원표본에서 복원추출로 m개 뽑아 평균
        s = 0.0
        for _ in 1:m
            s += ys[Int(floor(rand(rng) * m)) + 1]         # 무작위 인덱스(복원추출)
        end
        means[b] = s / m
    end
    sort!(means)                                           # 정렬 후 양 끝 백분위를 CI 경계로 사용
    lo = means[max(1, Int(floor(alpha/2 * n)))]
    hi = means[min(n, Int(ceil((1 - alpha/2) * n)))]
    return (mean=sum(ys)/length(ys), lo=lo, hi=hi, n=length(ys))
end

"""
    paired_delta(a, b; seed) -> NamedTuple

Mean paired difference `a[i] − b[i]` over identical-seed runs, with bootstrap CI and the
fraction of pairs where `a` wins. Use to test whether controller A beats B on a metric.
`significant` is true iff the CI excludes 0.
"""
# 같은 시드끼리 짝지어 a-b 차이의 평균+CI. 두 컨트롤러 A,B 를 지표 하나로 비교. significant = CI 가 0 을 제외하면 참.
function paired_delta(a::AbstractVector{<:Real}, b::AbstractVector{<:Real}; seed::Int=1)
    n = min(length(a), length(b))
    d = Float64[a[i] - b[i] for i in 1:n if isfinite(a[i]) && isfinite(b[i])]  # 짝별 차이(유한값만)
    ci = bootstrap_ci(d; seed=seed)                        # 차이들의 CI
    win = isempty(d) ? NaN : count(>(0), d) / length(d)    # a 가 이긴(차이>0) 비율. >(0) = "0보다 큰가" 함수
    return (delta=ci.mean, lo=ci.lo, hi=ci.hi, win_rate=win, n=length(d),
            significant = isfinite(ci.lo) && isfinite(ci.hi) && (ci.lo > 0 || ci.hi < 0))
end

"""
    breakdown_point(difficulty, completion; threshold=0.5) -> Float64

The OOD-difficulty (e.g. events-per-build, or severity) at which mean `completion`
first drops below `threshold` — the controller's robustness limit. Inputs are paired,
ascending-difficulty vectors. Linear-interpolated; `Inf` if it never breaks down, the
first point if it starts already broken.
"""
# 붕괴점: 난이도를 올릴 때 평균 완주율(completion)이 처음으로 threshold 아래로 떨어지는 난이도 = 견고성 한계.
# 두 벡터는 난이도 오름차순으로 짝지어 있어야 함. 교차점은 선형보간. 끝까지 안 떨어지면 Inf.
function breakdown_point(difficulty::AbstractVector{<:Real}, completion::AbstractVector{<:Real};
        threshold::Float64=0.5)
    n = min(length(difficulty), length(completion))
    n == 0 && return NaN
    completion[1] < threshold && return float(difficulty[1])  # 시작부터 이미 붕괴 상태면 첫 난이도
    for i in 2:n
        if completion[i] < threshold                          # 여기서 처음 threshold 아래로 내려감
            d0, d1 = difficulty[i-1], difficulty[i]           # 교차 구간의 양 끝 난이도
            c0, c1 = completion[i-1], completion[i]           # 양 끝 완주율
            c1 == c0 && return float(d1)                      # 기울기 0(분모 0)이면 오른쪽 끝 반환
            return d0 + (threshold - c0) * (d1 - d0) / (c1 - c0)   # interpolate the crossing  # 선형보간 교차점
        end
    end
    return Inf   # never fell below threshold across the swept range  # 범위 내내 안 무너짐
end
