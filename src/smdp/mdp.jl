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
include("simstate.jl")   # §3 상태 정의. 리뷰 라운드 1 확인: hazard.jl 에 의존하지 않는다 —
                          # 이전 주석의 "HazardParams/HazardState 를 참조한다"는 틀린 진술이었다.
                          # hazard 뒤에 두는 건 계획서 파일 목록 순서를 따르는 관례일 뿐이다.
include("observe.jl")   # env → s 의 유일한 경로. simstate.jl(타입)·hazard.jl(_hz_modes) 둘 다에
                        # 의존하므로 반드시 이 둘 뒤에 온다.

# 호출자가 "MDP 계층이 로드됐다"고 확인할 수 있게 해주는 표식 함수.
mdp_loaded() = true
