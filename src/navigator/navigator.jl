# =============================================================================
#  [한국어 요약] 이 파일은 navigator 폴더의 여러 조각들을 "올바른 순서로 한 번에
#  불러오는" 로더(loader). navigator 파일들은 ConstructionBots 모듈에 컴파일되어
#  들어가지 않고(일부러 분리해 실행 시점에 include 함), 데모마다 손으로 CB.include(...)
#  를 여러 번 부르면 순서를 틀리기 쉬웠음. 그래서 이 파일 하나를 include 하면
#  전부 의존성 순서대로 안전하게 로드됨.
#
#  Julia 문법 참고:
#   · include("파일.jl") : 그 파일의 코드를 지금 위치에 그대로 붙여넣어 실행(로드).
#   · 아래 순서가 중요 — 뒤 파일이 앞 파일에서 정의한 것을 쓰기 때문(위→아래 의존).
#   · navigator_loaded() = true : 한 줄짜리 함수. "로드됐는지" 확인용 표식(marker).
# =============================================================================
# navigator.jl  --  Aggregator/loader for the LLM Design-Space Navigator +
# controller-comparison layer. The navigator files are NOT compiled into the
# ConstructionBots module (they stay decoupled, runtime-`include`d); this file loads
# them ALL in dependency order with one call, replacing the ad-hoc per-demo
# `CB.include(...)` sequences (which were easy to get wrong). Load once:
#
#     import ConstructionBots as CB
#     CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
#
# after which CB.RunMetrics, CB.compare_controllers, CB.default_controllers, the
# baselines B0–B5, the OOD-truth types, and the OOD stream are all available.
#
# Dependency order matters (later files use earlier definitions):
#   config_schema      ObjectiveWeights / NavigatorConfig       (no deps)
#   metrics            RunMetrics / axis_costs / is_better       (no deps)
#   llm_eval           grounding_prf / optimality_gap / lift     (deps: metrics)
#   ood_truth          OODTruth kinds / keys / grounding         (deps: llm_eval)
#   baselines          B0–B5 proposal producers                  (deps: spec_dsl, ood_truth, llm_eval)
#   adaptation_metrics adaptation/decision/lift-norm/aggregation (deps: metrics, llm_eval, ood_truth)
#   controller         Controller abstraction + all columns      (deps: baselines, adaptation_metrics)
#   compare            fixed B0–B3+LLM per-instance table         (deps: baselines, metrics, llm_eval)
#   compare_controllers generalized ladder + lift + sweep        (deps: controller, adaptation_metrics, compare)
#   battery            SoC accounting + battery OOD               (deps: CB internals)
#   ood_stream         multi-event random OOD stream             (deps: ood_injection, ood_truth, battery)
# =============================================================================

# 아래 순서 = 위 헤더의 의존성 표 그대로. 앞의 것을 뒤의 것이 사용하므로 순서를 바꾸면 안 됨.
include("config_schema.jl")       # 설정/목적가중치 자료형(의존 없음)
include("metrics.jl")             # RunMetrics / 축비용 / is_better(의존 없음)
include("llm_eval.jl")            # grounding / optimality_gap / lift(의존: metrics)
include("ood_truth.jl")           # OOD 정답 종류/키/grounding(의존: llm_eval)
include("baselines.jl")           # B0~B5 대응안 생성기(의존: spec_dsl, ood_truth, llm_eval)
include("adaptation_metrics.jl")  # 적응/결정/lift 정규화·집계(의존: metrics, llm_eval, ood_truth)
include("controller.jl")          # Controller 추상화 + 모든 열(의존: baselines, adaptation_metrics)
include("compare.jl")             # 고정 B0~B3+LLM 사례별 표(의존: baselines, metrics, llm_eval)
include("compare_controllers.jl") # 일반화된 사다리 + lift + sweep(의존: controller, adaptation_metrics, compare)
include("battery.jl")             # SoC(배터리) 회계 + battery OOD(의존: CB 내부)
include("ood_stream.jl")          # 다중 이벤트 무작위 OOD 스트림(의존: ood_injection, ood_truth, battery)

# 호출자가 "navigator 가 로드됐다"고 확인할 수 있게 해주는 표식 함수.
# A marker so callers can assert the navigator is loaded (and get its file list).
navigator_loaded() = true
