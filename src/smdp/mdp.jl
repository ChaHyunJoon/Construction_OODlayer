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
                        # 🔴 **세 번째 의존이 있다: navigator/navigator.jl** —
                        # `_responsible_robots`·`is_spare`·`is_battery_courier`·
                        # `BATTERY_DELIVERIES`·`SPARE_POOLS` 를 쓴다. Julia 의 늦은 바인딩이
                        # 그것을 가려 왔다(모든 시험이 navigator.jl 을 먼저 include 한다) —
                        # 안 하면 `include` 는 통과하고 **`simstate_of` 를 부르는 순간**
                        # `UndefVarError` 로 죽는다. 위 사용법 블록의 "먼저(의존)" 는 hazard 만이
                        # 아니라 이 파일 전체에 걸린다.

include("derive.jl")   # s 의 파생 접근자(active_of·modes_of·mode_of·rate_params).
                       # simstate.jl(타입)·hazard.jl(_hz_modes 와 같은 순위)·
                       # navigator/battery.jl(_node_mode·_responsible_robots) 에 의존한다.
include("rates.jl")    # spec §2 의 닫힌 형태. **순수 수학** — 씬을 참조하지 않는다.
                       # hazard.jl(hazard_rate_from)·navigator/battery.jl(BatteryParams·k_move)
                       # 에 의존. derive.jl 의 rate_params 가 rate_params_one 을 부른다(늦은 바인딩).
include("tplan.jl")    # D-6 rate boundary. λ 가 구간상수인 구간의 경계(T_plan_next)와
                       # 남은 스케줄의 longest path(T_done). derive.jl(active_of)·
                       # essential_tg_coponents.jl(get_min_duration·get_graph) 에 의존하므로
                       # 반드시 derive.jl / rates.jl **다음**에 온다.

# 호출자가 "MDP 계층이 로드됐다"고 확인할 수 있게 해주는 표식 함수.
mdp_loaded() = true
