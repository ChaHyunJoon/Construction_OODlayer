# ============================================================================
#  이 파일이 하는 일: 시뮬레이션이 멈춰버린(진척 없는) 상황을 "덤프 파일"에서 되살려 이어서 돌리는 디버깅 스크립트.
#  프로젝트 속 역할: 본 시뮬레이터는 일정 반복 동안 진척이 없으면 핵심 상태(env/시각화/애니메이션/파라미터)를
#  .jld2 파일로 저장함. 이 스크립트는 그 저장본을 불러와 RVO 시뮬레이터를 재구성하고 이어서 실행 →
#  한 스텝씩 따라가며(step-through) 버그를 조사할 수 있게 함.
#  Julia 문법 참고:
#   · JLD2 : Julia 객체를 파일로 저장/로드하는 라이브러리(파이썬 pickle 비슷).
#   · JLD2.load(파일, "키") : 파일에서 그 키로 저장된 객체를 꺼냄.
#   · joinpath(a, b) : OS 에 맞게 경로를 이어붙임.
#   · """ ... """ : 여러 줄 문자열(여기선 스크립트 설명용 docstring 처럼 쓰임).
#   · ! 접미사 함수(reset_...!, rvo_add_agents! 등) = 상태를 직접 바꾸는 함수 관례.
# ============================================================================

using ConstructionBots
using JLD2  # 덤프 파일(.jld2) 로드용

"""
This script exists to helping debug scenarios. If a simulation doesn't progress after a
certain number of iterations, it saves the critical components of the simulation to a file.
This script can be used to load those "dumped" variables and continue the simulation,
enabling you to step through the simuation or other debugging techniques.
"""

dump_path = "variable_dump"                          # 덤프 파일이 있는 폴더
dump_name = "var_dump_8850.jld2"                     # 되살릴 덤프 파일 이름(8850 스텝 근처에서 저장된 것)
file_dump_location = joinpath(dump_path, dump_name)  # 전체 경로 조합

# Load variables from file
# 덤프 파일에서 시뮬레이션 핵심 상태들을 각각 복원.
env = JLD2.load(file_dump_location, "env")                  # 시뮬레이션 환경(씬 트리·스케줄 등 전부)
factory_vis = JLD2.load(file_dump_location, "factory_vis")  # 공장 시각화 상태
anim = JLD2.load(file_dump_location, "anim")                # 애니메이션 상태
sim_params = JLD2.load(file_dump_location, "sim_params")    # 시뮬레이션 파라미터 묶음

# Recreate rvo_sim
# RVO(충돌회피) 시뮬레이터는 파이썬 객체라 저장이 안 됨 → 여기서 새로 만들어 에이전트를 다시 등록.
ConstructionBots.reset_rvo_python_module!()                        # RVO 파이썬 모듈 초기화
ConstructionBots.rvo_set_new_sim!(ConstructionBots.rvo_new_sim())  # 새 RVO 시뮬레이터 인스턴스 장착
scene_tree = env.scene_tree                                        # 복원된 env 에서 씬 트리 꺼냄
ConstructionBots.rvo_add_agents!(scene_tree)                       # 씬 트리의 로봇/유닛들을 RVO 에 에이전트로 추가

# Moddify the sim paramters as desired here
# 복원된 파라미터를 개별 변수로 풀어 둠 — 아래에서 값을 바꿔 실험하기 쉽게 하려는 목적.
sim_batch_size = sim_params.sim_batch_size                        # 한 번에 처리할 스텝 묶음 크기
max_time_steps = sim_params.max_time_steps                       # 최대 시뮬레이션 스텝 수
process_animation_tasks = sim_params.process_animation_tasks     # 애니메이션 작업 처리 여부
save_anim_interval = sim_params.save_anim_interval               # 애니메이션 저장 주기
process_updates_interval = sim_params.process_updates_interval   # 상태 업데이트 처리 주기
update_anim_at_every_step = sim_params.update_anim_at_every_step # 매 스텝 애니메이션 갱신 여부
anim_active_agents = sim_params.anim_active_agents               # 활동 로봇 강조 표시 여부
anim_active_areas = sim_params.anim_active_areas                 # 활동 구역 강조 표시 여부
save_anim_prog_path = sim_params.save_anim_prog_path             # 진행 애니메이션 저장 경로
save_animation_along_the_way = sim_params.save_animation_along_the_way  # 중간 저장 여부
max_num_iters_no_progress = sim_params.max_num_iters_no_progress # 진척 없을 때 중단 기준 반복 수

# 위에서 (필요시 수정한) 값들로 SimParameters 를 다시 조립.
sim_params = ConstructionBots.SimParameters(
    sim_batch_size,
    max_time_steps,
    process_animation_tasks,
    save_anim_interval,
    process_updates_interval,
    update_anim_at_every_step,
    anim_active_agents,
    anim_active_areas,
    save_anim_prog_path,
    save_animation_along_the_way,
    max_num_iters_no_progress
)

# Add debug options as desired. E.g. @run
# 복원된 상태로 시뮬레이션을 이어서 실행. 여기에 @enter/@run 같은 디버거 매크로를 붙여 한 스텝씩 조사할 수 있음.
ConstructionBots.run_simulation!(env, factory_vis, anim, sim_params)
