# =============================================================================
#  mdp.jl -- loader for the MDP layer (설계: wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md)
#
#  이 폴더는 "문제를 제대로 된 stochastic MDP 로 세우는" 조각들을 담는다. navigator/ 와
#  같은 방식으로 ConstructionBots 모듈에 컴파일되지 않고 실행 시점에 include 된다.
#
#      import ConstructionBots as CB
#      CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))   # 먼저(의존)
#      CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))
#
#  로드 순서 / 의존:
#    hazard   §5 확률적 고장 프로세스(경쟁 위험 점과정 + 무작위 방전)
#             deps: navigator/battery.jl(BATTERY_FLEET/_node_mode/_responsible_robots,
#                   DRAIN_FACTOR_HOOK), navigator/ood_truth.jl(fault_action/zone_action),
#                   navigator/ood_stream.jl(battery_action), respec/ood_injection.jl
#
#  (다음 단계 예정: labeler = §7 K-rollout Monte-Carlo Q 라벨러, router = §9 VoI 게이트)
# =============================================================================

include("state_globals.jl")   # spec §3.6 전역 인벤토리 (hazard 보다 먼저 — 의존 없음)
include("hazard.jl")   # §5 stochastic failure process (competing-risks point process)

# 호출자가 "MDP 계층이 로드됐다"고 확인할 수 있게 해주는 표식 함수.
mdp_loaded() = true
