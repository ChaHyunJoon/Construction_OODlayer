# ============================================================================
#  [한국어 설명 상자 — 처음 읽는 사람용]
#  이 파일이 하는 일: "LLM이 잘했는가"를 풀이기(solver)의 실력과 분리해서 채점한다.
#    RunMetrics(metrics.jl)는 풀이기가 만든 계획의 성능이라, LLM 실력과 풀이기 실력이 뒤섞여 있다.
#    그래서 여기서는 (a) LLM의 진짜 일 = 관측→DSL 번역의 정밀도/재현율(grounding)을 정답 대비 채점하고,
#    (b) 결과는 항상 기준틀(oracle 천장·baseline 바닥) 대비 상대값으로만 본다(raw 값 금지).
#  프로젝트에서의 역할: LLM 재명세 층이 실제로 기여했는지, 아니면 풀이기가 알아서 잘한 건지 구분해 주는 채점기.
#  3개 레벨:
#    Level 1 = grounding(번역 정확도, precision/recall/F1)  ← LLM의 본업
#    Level 2 = 기준틀 대비 결과(optimality gap = oracle와의 격차, lift = baseline 대비 개선)
#    Level 3 = 성공 판정 + 여러 무작위 실행에 걸친 신뢰성(LLM은 확률적이라 1회 실행은 의미 없음)
#
#  용어(원문 유지, 뜻만): precision(정밀도: 낸 것 중 맞은 비율), recall(재현율: 맞춰야 할 것 중 잡은 비율),
#    F1(둘의 조화평균), grounding(관측→DSL 접지/번역), regret/gap(정답과의 격차), lift(기준선 대비 개선),
#    oracle(정답을 아는 상한), baseline(대조군 하한), hallucinated(환각: 낸 것이 틀림 = false positive).
#
#  Julia 문법 참고(처음 보는 사람용):
#   · f(x::AbstractSet) : x가 집합(Set)일 때 적용. intersect/setdiff/union = 교집합/차집합/합집합.
#   · `2prec` 처럼 숫자와 변수를 붙여 쓰면 곱셈(2*prec). Julia만의 축약.
#   · NamedTuple{Tuple(order)}(...) : 필드 이름을 order(심볼들)로 동적으로 만든 이름표붙은 튜플.
#   · Base.@kwdef struct : 필드 기본값을 주는 매크로. `crit.max_gap` 처럼 점(.)으로 필드 접근.
#   · `xs::Vector{Bool}=trues(n)` : 기본값이 "전부 참인 길이 n 벡터". falses는 전부 거짓.
#   · 삼항 `조건 ? A : B`, 조기반환 `조건 && return 값`.
# ============================================================================

# llm_eval.jl
# Metrics that ISOLATE the LLM's contribution from the solver's. See
# docs/llm_navigator_plan.md ("evaluate whether the LLM did well").
#
# Key idea: RunMetrics (metrics.jl) measures the *plan* the solver produced, which
# conflates LLM quality with solver quality. To score the LLM you MUST view its
# outcome against a reference frame (oracle upper bound, baseline lower bound) and,
# more importantly, score its TRANSLATION (observation -> DSL) against ground-truth
# OOD labels. Depends on metrics.jl (RunMetrics, axis_costs).

# tiny stats helpers (avoid a Statistics dependency)
# 작은 통계 도우미들(Statistics 패키지 의존을 피하려고 직접 구현). _mean=평균, _std=표본표준편차.
_mean(xs) = isempty(xs) ? NaN : sum(xs) / length(xs)   # 비면 NaN, 아니면 평균
function _std(xs)
    n = length(xs); n < 2 && return 0.0                # 표본 2개 미만이면 표준편차 0(조기반환)
    m = _mean(xs); return sqrt(sum((x - m)^2 for x in xs) / (n - 1))  # 분모 n-1 = 불편(표본) 분산
end

# ============================================================================
# Level 1 — grounding / translation accuracy (the LLM's actual job)
# ============================================================================
# Schema-agnostic precision/recall over emitted-vs-true DSL edits. The caller maps
# each DSL edit to a comparable key, e.g. (:ReplaceAgent, robot_id) or
# (:ForbidZone, zone_id). For ForbidZone geometry, fold an IoU threshold into the
# key BEFORE building the sets (a zone counts as "matched" only if IoU >= τ).

"""
    grounding_prf(emitted::AbstractSet, truth::AbstractSet) -> NamedTuple

Precision/recall/F1 of the LLM's emitted DSL edits against the ground-truth OOD.
`hallucinated` = emitted-but-not-true (false positives, the dangerous ones);
`missed` = true-but-not-emitted (the LLM failed to react).
"""
# LLM이 낸 DSL 편집(emitted) 집합을 정답(truth) 집합과 비교해 precision/recall/F1을 낸다.
# hallucinated=냈지만 정답 아님(위험한 오탐), missed=정답인데 못 냄(반응 실패).
function grounding_prf(emitted::AbstractSet, truth::AbstractSet)
    tp = length(intersect(emitted, truth))    # true positive: 낸 것 ∩ 정답 = 맞게 낸 개수
    fp = length(setdiff(emitted, truth))      # hallucinated / over-specified  # 낸 것 - 정답 = 환각(오탐)
    fn = length(setdiff(truth, emitted))      # missed                         # 정답 - 낸 것 = 놓침(누락)
    prec = (tp + fp) == 0 ? 1.0 : tp / (tp + fp)   # 정밀도(낸 게 하나도 없으면 1로 약속)
    rec  = (tp + fn) == 0 ? 1.0 : tp / (tp + fn)   # 재현율(맞출 게 없었으면 1로 약속)
    f1   = (prec + rec) == 0 ? 0.0 : 2prec * rec / (prec + rec)   # F1 = 정밀도·재현율의 조화평균(2prec=2*prec)
    return (precision=prec, recall=rec, f1=f1, hallucinated=fp, missed=fn,
            grounded = (fp == 0 && fn == 0))       # grounded = 오탐도 누락도 0일 때만 참(완벽 번역)
end

# ============================================================================
# Level 2 — outcome relative to a reference frame (never raw)
# Level 2 — 결과는 항상 기준틀(oracle/baseline) 대비 상대값으로만 (raw 절대값은 쓰지 않음)
# ============================================================================
# 상대 격차: 기준 ref 대비 x가 얼마나 벗어났나 (x-ref)/|ref|. ref=0이면 나눗셈 회피(x도 0이면 0, 아니면 x 그대로).
_relgap(x, ref) = (ref == 0) ? (x == 0 ? 0.0 : float(x)) : (x - ref) / abs(ref)

"""
    optimality_gap(llm, oracle; order) -> NamedTuple

Per-axis gap of the LLM-driven plan vs an oracle (true-OOD optimal re-solve).
0 = matched the oracle; >0 = worse. The LLM essentially never beats the oracle on
outcome — that is expected; report the gap, not the raw value.
"""
# LLM 계획 vs oracle(정답 재풀이)의 축별 격차. 0=oracle과 동일, >0=더 나쁨. LLM이 oracle을 이기는 일은 거의 없음(정상).
function optimality_gap(llm::RunMetrics, oracle::RunMetrics;
        order::Vector{Symbol}=[:completion, :speed, :efficiency, :adaptability])
    cl = axis_costs(llm); co = axis_costs(oracle)   # 두 실행을 축별 비용으로 변환
    # order 순서대로 각 축의 상대격차를 계산해, 그 이름표를 붙인 NamedTuple로 반환.
    return NamedTuple{Tuple(order)}(Tuple(_relgap(getfield(cl, k), getfield(co, k)) for k in order))
end

"""
    lift(llm, baseline; order) -> NamedTuple

Per-axis improvement of the LLM over a no-LLM baseline (classical-respec or
no-adapt). >0 = LLM better on that axis. If lift ≈ 0 vs classical-respec, the LLM
added nothing on this instance (expected when the OOD is fully formalizable).
"""
# LLM이 무(無)-LLM baseline보다 축별로 얼마나 개선했나. >0=그 축에서 LLM이 더 나음. ≈0이면 이 사건에선 LLM 기여 없음.
function lift(llm::RunMetrics, baseline::RunMetrics;
        order::Vector{Symbol}=[:completion, :speed, :efficiency, :adaptability])
    cl = axis_costs(llm); cb = axis_costs(baseline)   # 둘 다 축별 비용으로
    # 비용은 낮을수록 좋으므로 (baseline비용 - llm비용) > 0 이면 LLM이 그만큼 비용을 줄인 것 = 개선.
    return NamedTuple{Tuple(order)}(Tuple(getfield(cb, k) - getfield(cl, k) for k in order))
end

# ============================================================================
# Level 3 — success predicate + reliability across stochastic runs
# ============================================================================

# 한 번의 LLM 실행을 '성공'이라 부르기 위한 관문들. 아래 조건을 전부 통과해야 성공.
"Gates for calling a single LLM run 'good'. A run must clear ALL of them."
Base.@kwdef struct SuccessCriteria
    require_feasible::Bool   = true        # 실현가능한 계획이어야 함
    require_grounded::Bool   = true       # correct observation -> DSL translation  # 관측→DSL 번역이 정확해야 함
    priority_axis::Symbol    = :completion # 우선으로 보는 축(기본: 완주)
    max_gap::Float64         = 0.10       # within 10% of oracle on the priority axis  # 우선 축에서 oracle 대비 10% 이내
    max_replan_latency::Float64 = Inf     # 재계획 지연 상한(기본 무한 = 제한 없음)
end

"""
    is_success(llm, oracle, crit; grounded) -> Bool

A single LLM run is a success iff it is feasible, correctly grounded, within
`max_gap` of the oracle on the priority axis, and under the latency budget.
"""
# LLM 실행 1건이 성공인가? 실현가능+올바른 접지+우선축 oracle격차 이내+지연예산 이내 모두 만족해야 참.
function is_success(llm::RunMetrics, oracle::RunMetrics, crit::SuccessCriteria; grounded::Bool=true)
    crit.require_feasible && !llm.feasible && return false          # 실현가능 요구인데 불가능 → 실패
    crit.require_grounded && !grounded && return false             # 접지 요구인데 접지 안 됨 → 실패
    g = getfield(optimality_gap(llm, oracle; order=[crit.priority_axis]), crit.priority_axis)  # 우선 축의 oracle 격차
    g > crit.max_gap && return false                              # 격차가 허용치 초과 → 실패
    isfinite(crit.max_replan_latency) && _z(llm.replan_latency) > crit.max_replan_latency && return false  # 지연 초과 → 실패
    return true                                                   # 모든 관문 통과 → 성공
end

# 같은 OOD 사건에 대해 N번의 확률적 LLM 실행을 모아 낸 신뢰성 보고 구조체.
"Aggregate report over N stochastic LLM runs on the same OOD instance."
Base.@kwdef struct ReliabilityReport
    n::Int                           # 실행 횟수
    success_rate::Float64            # 성공 비율(is_success가 참인 비율)
    gap_mean::Float64                # oracle 격차 평균
    gap_std::Float64                 # outcome variance — LLMs are stochastic  # 격차의 표준편차(LLM은 확률적이라 변동성 자체가 중요)
    latency_mean::Float64            # 평균 재계획 지연
    false_accept_rate::Float64       # verifier-escaped infeasible/unsafe configs (safety-critical)  # 검증기를 빠져나간 불가능/위험 계획 비율(안전에 치명적)
end

"""
    reliability(runs, oracle, crit; grounded, verifier_escaped, priority_axis)

Single LLM runs are not informative (the model is stochastic). Run N seeds /
temperatures and report success RATE + gap variance. `verifier_escaped[i]` marks
runs the verifier wrongly accepted (false-accepts) — weight these heavily; in a
no-human-repair setting a false-accept is far worse than a false-reject.
"""
# 여러 seed/temperature로 돌린 N개 실행을 모아 성공률과 격차 변동성을 보고. 1회 실행은 LLM의 확률성 탓에 무의미.
# verifier_escaped[i]=검증기가 잘못 통과시킨 실행 표시(사람이 못 고치는 환경에선 오통과가 오거부보다 훨씬 나쁨→무겁게 봄).
function reliability(runs::Vector{RunMetrics}, oracle::RunMetrics, crit::SuccessCriteria;
        grounded::Vector{Bool}=trues(length(runs)),        # 기본: 전부 접지됨으로 가정
        verifier_escaped::Vector{Bool}=falses(length(runs)),  # 기본: 오통과 없음으로 가정
        priority_axis::Symbol=:completion)
    n = length(runs)
    succ = [is_success(runs[i], oracle, crit; grounded=grounded[i]) for i in 1:n]  # 각 실행의 성공 여부(Bool 벡터)
    gaps = [getfield(optimality_gap(runs[i], oracle; order=[priority_axis]), priority_axis) for i in 1:n]  # 각 실행의 우선축 격차
    lat  = [_z(r.replan_latency) for r in runs]              # 각 실행의 재계획 지연(NaN은 0)
    return ReliabilityReport(n=n, success_rate=_mean(succ),  # Bool 벡터의 평균 = 성공 비율
        gap_mean=_mean(gaps), gap_std=_std(gaps),
        latency_mean=_mean(lat), false_accept_rate=_mean(verifier_escaped))  # 오통과 비율
end
