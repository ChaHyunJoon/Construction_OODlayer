# ============================================================================
#  이 파일은 "여러 방법(baseline)들을 같은 조건에서 나란히 비교"하는 실험 하네스.
#  하나의 OOD(예상 밖 상황) 사례를 놓고 B0~B3 규칙 기반 baseline들과 LLM을 각각
#  돌려서, 각 방법이 만든 대응안(RespecProposal)이 얼마나 좋은지 표로 뽑아줌.
#  핵심 아이디어: 방법마다 다른 것은 "대응안을 만드는 부분(producer)" 하나뿐이고,
#  그 뒤 처리(검증→반영→재계획→측정)는 전부 똑같이(run_pipeline 로 주입) 공유함.
#  → 그래야 "결과 차이 = 방법 차이"라고 공정하게 말할 수 있음.
#
#  Julia 문법 참고:
#   · struct Name ... end : 여러 값을 묶는 자료형 정의(파이썬 클래스의 데이터 부분).
#   · 필드 뒤 `::String` = 그 필드의 타입 지정. 타입 없는 필드는 아무거나 담을 수 있음.
#   · push!(배열, 값) : 배열 끝에 값 추가(`!`=배열을 직접 수정).
#   · `x === nothing` : x 가 값이 없는(nothing) 상태인지 정확히 비교.
#   · map(res) do r ... end : res 의 각 원소 r 에 do 블록을 적용해 새 배열을 만듦.
#   · (name = ..., feasible = ...) : 이름표 붙은 값 묶음(NamedTuple).
#   · """ ... """ 함수 위 블록 = docstring(함수 사용법 설명 문서).
# ============================================================================
# compare.jl
# Run B0–B3 + LLM through the SAME downstream on one OOD instance and tabulate
# RunMetrics, grounding, gap-to-oracle, lift-over-B2, success. See
# docs/llm_navigator_plan.md.
#
# The ONLY thing that differs across methods is the RespecProposal producer; the
# downstream (verify -> enact -> solve -> measure) is injected as `run_pipeline` so
# this file is standalone-testable and wires to the real pipeline in the package.

using Printf   # @printf(형식화 출력) 매크로를 쓰기 위한 표준 라이브러리

# 한 방법(method)을 한 번 돌린 결과를 담는 자료형.
struct MethodResult
    name::String    # 방법 이름(예: "B0_noadapt", "LLM") — 표의 행 이름으로 쓰임
    proposal        # 그 방법이 만든 대응안(RespecProposal). 대응 안 함이면 nothing
    metrics::RunMetrics  # 그 대응안을 반영해 돌린 뒤의 성능 측정치(완주율/makespan 등)
    grounding       # NL→구조 번역이 정답과 얼마나 맞았는지(NamedTuple). oracle/floor 방법은 채점 안 하므로 nothing
end

"""
    compare_baselines(truth, nl; run_pipeline, llm_respec, weights, mkrobot, crit)

Evaluate one OOD instance across methods.

- `truth`        : the structured ground-truth OOD (FaultTruth / ZoneTruth).
- `nl`           : the NL observation the parser/LLM must translate.
- `run_pipeline` : `proposal_or_nothing -> RunMetrics` — the shared downstream;
                   `nothing` runs the unmodified plan (B0 / parse-failure).
- `llm_respec`   : `nl -> RespecProposal?` (omit to skip the LLM column).

B1/B3 are GIVEN the structured truth (oracle detector → grounding trivially perfect,
reported as n/a). B2/LLM must translate `nl`. Oracle outcome = the better of {B1,B3}
under `weights`; B2 is the lift reference. Returns `(rows, oracle, b2_ref)`.
"""
# 하나의 OOD 사례를 여러 방법으로 평가하는 핵심 함수.
# 인자: truth=정답 구조(고장/구역 등), nl=방법이 번역해야 하는 자연어 관찰문.
# 키워드 인자: run_pipeline=공유되는 뒤처리(대응안→성능측정), llm_respec=LLM 번역기(없으면 LLM 열 생략),
#             weights=목적축 가중치, mkrobot=id를 도메인 타입으로 바꾸는 함수, crit=성공 판정 기준.
function compare_baselines(truth, nl; run_pipeline,
        llm_respec = nothing, weights = ObjectiveWeights(),
        mkrobot = identity, crit = SuccessCriteria())
    truths = [truth]        # grounding 채점 함수가 배열을 받으므로 정답을 배열로 감쌈
    res = MethodResult[]     # 각 방법의 결과를 담을 빈 배열(MethodResult 타입 원소)

    # B0 = 아무 대응도 안 하는 바닥(floor) — nothing 을 넘겨 원래 계획 그대로 돌림.
    push!(res, MethodResult("B0_noadapt", nothing, run_pipeline(nothing), nothing))

    # B1 = 정답 구조로부터 규칙 표에 따라 만든 표준(canonical) 대응안(정답 탐지기 가정).
    p1 = canonical_respec(truth)
    push!(res, MethodResult("B1_rule", p1, run_pipeline(p1), nothing))   # oracle detector

    # B3 = 정답 구조로부터 재계산해 얻은 이상적 대응안(정답 탐지기 가정).
    p3 = oracle_respec(truth)
    push!(res, MethodResult("B3_resolve", p3, run_pipeline(p3), nothing))  # oracle detector

    # B2 = LLM 없이 정규식으로 자연어를 파싱하는 현실적 비-LLM 경쟁자. 파싱 실패 시 p2=nothing.
    p2 = b2_respec(nl; mkrobot = mkrobot)
    push!(res, MethodResult("B2_parser", p2,
        run_pipeline(p2 === nothing ? nothing : p2),                       # 파싱 실패면 무대응으로 돌림
        grounding_vs_canonical(p2 === nothing ? [] : p2.constraints, truths)))  # 번역 정확도 채점

    # LLM 열: llm_respec 가 주어졌을 때만 추가(자연어→대응안 번역을 LLM에게 맡김).
    if llm_respec !== nothing
        pL = llm_respec(nl)
        push!(res, MethodResult("LLM", pL,
            run_pipeline(pL === nothing ? nothing : pL),
            grounding_vs_canonical(pL === nothing ? [] : pL.constraints, truths)))
    end

    b1m = res[2].metrics    # B1 의 측정치(res 는 1부터 시작; 2=B1, 3=B3)
    b3m = res[3].metrics    # B3 의 측정치
    oracle = is_better(b1m, b3m, weights) ? b1m : b3m   # B1/B3 중 더 나은 쪽 = 도달 가능한 최선(오라클)
    b2ref = res[4].metrics  # B2 = "리프트(향상폭)"를 잴 때의 기준점

    # 각 방법 결과 r 을 표의 한 행(NamedTuple)으로 변환.
    rows = map(res) do r
        g = r.grounding
        (name = r.name,
         feasible = r.metrics.feasible,                 # 실행 가능(feasible) 여부
         completion = r.metrics.completion_rate,        # 완주율
         makespan = r.metrics.makespan,                 # 총 소요시간
         grounding_f1 = g === nothing ? NaN : g.f1,     # 번역 정확도 F1(채점 안 하는 방법은 NaN)
         # oracle 대비 완주율 격차(작을수록 최선에 가까움).
         gap_completion = getfield(optimality_gap(r.metrics, oracle; order = [:completion]), :completion),
         # B2 대비 완주율 향상폭(양수면 B2보다 나음).
         lift_vs_b2_completion = getfield(lift(r.metrics, b2ref; order = [:completion]), :completion),
         # 성공 판정: oracle 에 충분히 근접 + (채점 대상이면) 번역이 정답에 grounded 되었는지.
         success = is_success(r.metrics, oracle, crit; grounded = g === nothing ? true : g.grounded))
    end
    return (rows = rows, oracle = oracle, b2_ref = b2ref)  # 표 + 오라클 + B2기준을 묶어 반환
end

# compare_baselines 의 결과를 보기 좋은 표 형태로 콘솔에 출력.
"Pretty-print a `compare_baselines` result."
function print_comparison(cmp)
    # 표 머리글 출력. %-12s=왼쪽정렬 12칸 문자열, %6.2f=소수 2자리 등 형식 지정.
    @printf("%-12s %5s %6s %9s %9s %8s %8s %6s\n",
        "method", "feas", "compl", "makespan", "groundF1", "gapCpl", "liftB2", "succ")
    for r in cmp.rows     # 각 방법 행을 한 줄씩 출력
        @printf("%-12s %5s %6.2f %9.2f %9s %8.3f %8.3f %6s\n",
            r.name, string(r.feasible), r.completion, r.makespan,
            isnan(r.grounding_f1) ? "n/a" : string(round(r.grounding_f1, digits = 2)),  # 채점 안 한 방법은 "n/a"
            r.gap_completion, r.lift_vs_b2_completion, string(r.success))
    end
    return nothing        # 출력이 목적이므로 반환값은 없음(nothing)
end
