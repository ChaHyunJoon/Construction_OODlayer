# ============================================================================
#  [한국어 설명 상자 — 처음 읽는 사람용]
#  이 파일이 하는 일: 여러 "controller(OOD 대응 정책)"들을 똑같은 조건에서 나란히 겨루게 하고,
#    누가 더 잘 대응했는지 표로 뽑아준다. controller 사다리(ladder): B0(대응 안 함)~B5, LLM, MARL.
#  프로젝트에서의 역할: 이 프로젝트의 존재 이유 자체가 "LLM 재명세(re-spec) 층이 무대응/고전 방식보다
#    얼마나 나은가"를 재는 것. 이 파일이 바로 그 비교표를 만드는 핵심 도구다.
#  핵심 아이디어:
#    · 모든 controller는 "downstream(run_pipeline: 제안을 실제로 실행→풀이→측정)"을 공유한다.
#      controller끼리 다른 건 오직 `decide`(무슨 대응을 낼지) 하나뿐 → 공정한 비교가 됨.
#    · lift(리프트) = 정규화 점수: B0(floor, 바닥)~oracle(정답, 천장) 사이 어디쯤인지 0~1로 환산.
#    · 여러 seed/instance에 대해 평균 + bootstrap CI(신뢰구간)로 집계하고, OOD 난이도 sweep(쓸어보기)로
#      점점 어려워질 때의 완주율 저하곡선(degradation curve)도 그린다.
#
#  Julia 문법 참고(처음 보는 사람용):
#   · f(x::AbstractVector{<:Controller}) : x가 "Controller의 하위타입을 담은 벡터"일 때만 적용(다중 디스패치+타입파라미터).
#   · `do ... end` 블록 : map(xs) do x ... end = 각 원소 x에 대해 블록을 실행(익명함수를 뒤에 붙이는 축약형).
#   · `!` 로 끝나는 이름 : 인자를 직접 수정하는 함수라는 관례(예: push!는 배열에 원소를 밀어넣음).
#   · NamedTuple `(a = 1, b = 2)` : 이름표가 붙은 값묶음(파이썬 dict 비슷하지만 가볍고 불변).
#   · `x === nothing` : "값이 없음(nothing)"인지 정체(identity) 비교. `nothing`은 값 없음 표시자.
#   · `@printf`, `@sprintf` : C 스타일 서식 출력 매크로(@로 시작 = 매크로).
#   · `getproperty(o, :x)` / `hasproperty` : 필드 이름을 :심볼로 동적 접근/존재확인. :x 는 심볼(이름표) 리터럴.
#   · `[f(x) for x in xs]` : comprehension(컴프리헨션) — 리스트를 한 줄로 만들어내는 문법.
# ============================================================================

# compare_controllers.jl
# ============================================================================
# Run the full controller ladder (B0..B5 + LLM + MARL) over a set of OOD instances /
# seeds through ONE shared, injected downstream, and produce the comparison the whole
# project exists to make: per-controller NORMALIZED LIFT (floor B0 -> oracle), decision
# quality, task outcome, and cost — aggregated with bootstrap CIs, plus robustness /
# degradation curves over an OOD-difficulty sweep.
#
# Generalizes compare.jl (which is fixed to B0-B3 + one LLM) to arbitrary `Controller`s
# and adds normalized lift + cross-seed aggregation + a difficulty sweep. The ONLY thing
# that differs across controllers is `decide`; the downstream is `run_pipeline`, injected
# so this file is standalone-testable with a mock and wires to the real pipeline in-package.
#
# Depends on: controller.jl, metrics.jl, llm_eval.jl, adaptation_metrics.jl, compare.jl,
# config_schema.jl (ObjectiveWeights).
# ============================================================================

using Printf   # @printf/@sprintf 서식 출력 매크로를 쓰기 위해 불러옴

# 한 controller가 하나의 OOD instance(사건)에서 낸 결과 한 줄을 담는 구조체.
# 담는 것: 이름, 낸 제안(proposal), 실행 측정치(metrics), grounding(관측→DSL 변환 채점), lift(정규화 점수).
"One controller's result on one OOD instance."
struct ControllerRun
    name::String
    proposal        # RespecProposal or nothing  # 낸 대응 제안(없으면 nothing = 무대응)
    metrics::RunMetrics                            # 이 제안을 실행해 얻은 다축 성능치
    grounding       # decision_quality NamedTuple, or nothing for oracle-detector controllers  # 정답을 이미 아는 oracle류는 채점 대상 아님→nothing
    lift            # lift_normalized NamedTuple (vs floor B0 / oracle)  # B0~oracle 사이 정규화 점수
end

# 모든 controller의 `decide`가 읽어들일 "사건 맥락(context)"을 만들어 준다.
# instance는 최소한 (truth 정답, nl 자연어설명)을 담고, 선택적으로 (env 환경, obs 관측)도 담을 수 있다.
# instance마다 새 난수생성기(RNG)를 주어, 같은 seed면 무작위 controller도 재현 가능하게 만든다.
# Build the per-event context every controller's `decide` reads. `instance` carries at
# least (truth, nl); optionally (env, obs). A fresh RNG per instance keeps random
# controllers reproducible for a given `seed`.
function _ctx(instance, seed::Int)
    return (nl    = getproperty(instance, :nl),                                  # 사건의 자연어 설명(LLM 입력)
            truth = getproperty(instance, :truth),                              # 채점용 정답 라벨(true OOD)
            env   = hasproperty(instance, :env) ? instance.env : nothing,        # 환경이 있으면 넣고, 없으면 nothing
            obs   = hasproperty(instance, :obs) ? instance.obs : nothing,        # 관측이 있으면 넣고, 없으면 nothing
            rng   = Random.MersenneTwister(seed))                                # seed로 고정된 난수생성기(재현성)
end

"""
    evaluate_instance(controllers, instance; run_pipeline, weights, seed) -> NamedTuple

Score every controller on ONE OOD instance. `run_pipeline(instance, proposal_or_nothing)
-> RunMetrics` is the shared downstream (enact + solve + measure on this instance's env).
Returns `(runs, oracle, floor)`. Oracle = better of {B1,B3}; floor = B0.
"""
# 하나의 OOD instance에서 모든 controller를 채점한다. run_pipeline은 공유 downstream
# (제안을 실제로 실행→풀이→측정해 RunMetrics를 돌려줌). floor=B0(무대응, 바닥), oracle=정답(천장).
# 인자: controllers(겨룰 정책들), instance(사건), run_pipeline(실행기), weights(목적함수 가중치), seed(재현용).
function evaluate_instance(controllers::AbstractVector{<:Controller}, instance;
        run_pipeline, weights = ObjectiveWeights(), seed::Int = 1)
    ctx = _ctx(instance, seed)      # 위에서 만든 사건 맥락(모든 controller가 공유해서 읽음)
    truths = [instance.truth]       # 채점용 정답을 리스트로 감쌈(decision_quality가 리스트를 받음)

    # first pass: proposals + metrics + grounding (need floor/oracle before lift)
    # 1차 통과: 각 controller의 제안·측정·grounding을 먼저 모두 구한다(lift 계산엔 floor/oracle이 먼저 필요하므로).
    raw = map(controllers) do c
        # decide가 예외를 던져도 전체 비교가 죽지 않게 try로 감싸고, 실패하면 nothing(무대응) 취급.
        prop = try; decide(c, ctx); catch err; @warn "decide($(name(c))) threw" exception=err; nothing; end
        m = run_pipeline(instance, prop)                    # 그 제안을 실제로 실행해 성능 측정
        # 정답을 이미 아는 controller(needs_truth=true, 예: oracle)는 grounding 채점 제외→nothing.
        g = needs_truth(c) ? nothing :
            decision_quality(prop === nothing ? Any[] : prop.constraints, truths)  # 제안 없으면 빈 리스트로 채점
        (c = c, prop = prop, m = m, g = g)                  # 이름표 붙은 묶음으로 모아둠
    end

    _find(nm) = findfirst(r -> name(r.c) == nm, raw)        # 이름으로 raw 안의 위치(index)를 찾는 도우미
    i0 = _find("B0_noadapt"); i1 = _find("B1_canonical"); i3 = _find("B3_oracle")  # 바닥/후보 정답들의 위치
    floor  = i0 === nothing ? raw[1].m : raw[i0].m          # floor = B0 측정치(없으면 첫 번째로 대체)
    oracle = if i1 !== nothing && i3 !== nothing            # oracle = {B1, B3} 중 더 나은 쪽(정답 천장)
        is_better(raw[i1].m, raw[i3].m, weights) ? raw[i1].m : raw[i3].m
    elseif i1 !== nothing
        raw[i1].m
    elseif i3 !== nothing
        raw[i3].m
    else
        floor                                              # 둘 다 없으면 floor를 천장으로(=lift가 0에 갇힘)
    end

    runs = ControllerRun[]
    for r in raw
        ln = lift_normalized(r.m, floor, oracle; order = weights.order)  # 각 controller를 floor~oracle 사이 0~1로 정규화
        push!(runs, ControllerRun(name(r.c), r.prop, r.m, r.g, ln))       # 결과 한 줄씩 쌓기
    end
    return (runs = runs, oracle = oracle, floor = floor)
end

# ---- cross-instance / cross-seed aggregation ------------------------------------
# ---- 여러 instance / 여러 seed에 걸친 집계 ----
# 한 controller의 여러 사건 결과를 하나로 요약한 통계 구조체(비교표의 한 행).
"Aggregate stats for ONE controller over many instances."
struct ControllerSummary
    name::String
    n::Int                        # 집계에 쓴 instance 개수
    lift_mean::Float64            # headline: mean normalized lift over axes & instances  # 대표 지표: 정규화 lift 평균
    lift_lo::Float64              # lift 신뢰구간(CI) 아래끝
    lift_hi::Float64              # lift 신뢰구간(CI) 위끝
    completion_mean::Float64      # 평균 완주율(placed/total)
    grounding_f1_mean::Float64    # NaN for oracle-detector controllers  # 관측→DSL 변환 F1 평균(oracle류는 NaN)
    recovery_rate_mean::Float64   # 평균 회복률(OOD를 영구 정지 없이 넘긴 비율)
    decision_latency::Float64     # nominal per-decision wall-clock [s]  # 결정 1건당 벽시계 시간(초): LLM은 ~초, MARL은 ~밀리초
    feasible_rate::Float64        # 풀이 가능한(쓸 만한) 계획을 낸 비율
end

"""
    compare_controllers(controllers, instances; run_pipeline, weights, seed) -> NamedTuple

Full comparison over `instances` (each a NamedTuple with `truth`,`nl`,…). Returns
`(summaries, per_instance)`: `summaries` is a `ControllerSummary` per controller with
mean normalized lift + bootstrap CI; `per_instance` keeps the raw `evaluate_instance`
outputs for drill-down. This is the table that answers "how much better is each
controller than no-adaptation, relative to the oracle?".
"""
# 여러 instance 전체에 대해 전체 비교를 수행하는 최상위 함수. 반환: (summaries 요약표, per_instance 원자료).
# "각 controller가 무대응 대비, oracle 기준으로 얼마나 더 나은가?"라는 이 프로젝트의 핵심 질문에 답하는 표.
function compare_controllers(controllers::AbstractVector{<:Controller}, instances;
        run_pipeline, weights = ObjectiveWeights(), seed::Int = 1)
    # instance마다 evaluate_instance를 돌림. seed+i로 사건마다 다른(그러나 재현되는) 난수를 씀.
    per = [evaluate_instance(controllers, inst; run_pipeline = run_pipeline,
                             weights = weights, seed = seed + i) for (i, inst) in enumerate(instances)]

    summaries = ControllerSummary[]
    for c in controllers
        nm = name(c)
        # 이 controller의 지표들을 instance들에 걸쳐 모을 빈 벡터들(lift/완주/F1/회복/실현가능).
        lifts = Float64[]; comps = Float64[]; f1s = Float64[]; recs = Float64[]; feas = Float64[]
        for p in per
            r = p.runs[findfirst(x -> x.name == nm, p.runs)]    # 이 사건 결과에서 이름이 nm인 줄을 찾음
            push!(lifts, r.lift.mean)
            push!(comps, _z(r.metrics.completion_rate))          # _z = NaN을 0으로 바꿔 안전하게 평균
            r.grounding === nothing || push!(f1s, r.grounding.f1) # grounding이 있을 때만 F1 수집(oracle류는 건너뜀)
            push!(recs, _z(r.metrics.recovery_rate))
            push!(feas, r.metrics.feasible ? 1.0 : 0.0)          # 실현가능이면 1, 아니면 0(→평균=비율)
        end
        ci = bootstrap_ci(lifts; seed = seed)                    # lift들의 평균 + bootstrap 신뢰구간
        _m(xs) = isempty(xs) ? NaN : sum(xs)/length(xs)          # 빈 벡터면 NaN, 아니면 평균(지역 도우미)
        push!(summaries, ControllerSummary(nm, length(per), ci.mean, ci.lo, ci.hi,
            _m(comps), _m(f1s), _m(recs), decision_latency_hint(c), _m(feas)))
    end
    return (summaries = summaries, per_instance = per)
end

# 비교표를 사람이 보기 좋게 출력한다(lift 평균 내림차순, 잘한 controller가 맨 위).
"Pretty-print the controller comparison (sorted by mean lift, best first)."
function print_controller_comparison(cmp)
    @printf("%-14s %4s %18s %7s %8s %8s %9s\n",
        "controller", "n", "lift[floor->oracle]", "compl", "groundF1", "recov", "dec_lat[s]")
    for s in sort(collect(cmp.summaries), by = x -> -x.lift_mean)   # -lift_mean 기준 정렬 = lift 큰 순(내림차순)
        ci = (isfinite(s.lift_lo) && isfinite(s.lift_hi)) ?         # CI가 유한하면 "평균 [아래,위]" 형태로
             @sprintf("%.2f [%.2f,%.2f]", s.lift_mean, s.lift_lo, s.lift_hi) :
             @sprintf("%.2f", s.lift_mean)                          # 아니면 평균만
        @printf("%-14s %4d %18s %7.2f %8s %8.2f %9s\n",
            s.name, s.n, ci, s.completion_mean,
            isnan(s.grounding_f1_mean) ? "n/a" : @sprintf("%.2f", s.grounding_f1_mean),
            s.recovery_rate_mean,
            isnan(s.decision_latency) ? "n/a" : @sprintf("%.3f", s.decision_latency))
    end
    return nothing
end

# ---- robustness / degradation curves over an OOD-difficulty sweep ----------------
# ---- OOD 난이도를 점점 올리며 그리는 견고성/성능저하 곡선 ----
"""
    robustness_sweep(controllers, make_instances, difficulties; run_pipeline, weights, seed)

For each difficulty level `d` (e.g. events-per-build or severity), `make_instances(d)`
returns the OOD instances at that level; every controller is scored and its MEAN
completion recorded. Returns `(difficulties, curves, breakdown)` where `curves[name]` is
the completion-vs-difficulty vector and `breakdown[name]` is its `breakdown_point`
(difficulty at which completion crosses 0.5) — the controller's robustness limit.
"""
# 난이도를 difficulties의 각 값 d로 올려가며 완주율이 어떻게 떨어지는지 곡선을 뽑는다.
# make_instances(d) = 난이도 d에서의 OOD instance들을 만들어 주는 함수(호출자가 넘김).
# 반환: curves[name]=완주율-대-난이도 벡터, breakdown[name]=완주율이 0.5를 지나는 난이도(그 controller의 견고성 한계).
function robustness_sweep(controllers::AbstractVector{<:Controller}, make_instances,
        difficulties::AbstractVector{<:Real};
        run_pipeline, weights = ObjectiveWeights(), seed::Int = 1)
    # controller 이름마다 빈 곡선(벡터)을 하나씩 준비하는 Dict 컴프리헨션.
    curves = Dict{String,Vector{Float64}}(name(c) => Float64[] for c in controllers)
    for (di, d) in enumerate(difficulties)
        insts = make_instances(d)                                  # 이 난이도의 사건들 생성
        cmp = compare_controllers(controllers, insts; run_pipeline = run_pipeline,
                                  weights = weights, seed = seed + 1000*di)  # 난이도마다 seed를 크게 벌려 겹침 방지
        for s in cmp.summaries
            push!(curves[s.name], s.completion_mean)               # 각 controller의 평균 완주율을 곡선에 이어붙임
        end
    end
    diff = collect(float.(difficulties))                            # 난이도들을 실수 벡터로(float. = 원소별 float 변환)
    # 각 곡선이 0.5를 가로지르는 지점(breakdown_point)을 계산 → 무너지기 시작하는 난이도.
    breakdown = Dict{String,Float64}(nm => breakdown_point(diff, cv) for (nm, cv) in curves)
    return (difficulties = diff, curves = curves, breakdown = breakdown)
end
