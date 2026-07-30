# ============================================================================
#  이 파일이 하는 일: 레고 조립 데모를 "직접 눈으로" 돌려 보는 실행 스크립트(테스트 아님).
#  프로젝트 속 역할: 프로젝트 하나(기본 4번=tractor)를 골라 run_lego_demo 로 전체 파이프라인을
#  실행하고 MeshCat 애니메이션을 브라우저로 띄움. 여러 설정(로봇수·회피정책·배정방식)을 손으로 바꿔 실험하는 용도.
#  아래 주석표 = get_project_params(n) 의 n 번호별 프로젝트(부품/조립체 수) 목록.
#  Julia 문법 참고:
#   · run_lego_demo(; key=val, ...) : 세미콜론 뒤는 전부 키워드 인자. 끝의 ; 는 REPL 출력 억제.
#   · :greedy, :highs 등 :이름 = Symbol(모드 선택 라벨).
#   · project_params[:file_name] : Dict 에서 키로 값 꺼내기.
#   · env, stats = f(...) : 반환 튜플을 두 변수로 분해 대입.
#  도메인 용어: RVO=속도장애물 충돌회피, tangent_bug=벽 따라가기, dispersion=분산, MILP=정수계획, makespan=총 완료시간.
# ============================================================================

using ConstructionBots

#                                    # parts      # assemblies
#     1 => :colored_8x8                 33               1
#     2 => :quad_nested                 85              21
#     3 => :heavily_nested              1757           508
#     4 => :tractor                     20               8
#     5 => :tie_fighter                 44               4
#     6 => :x_wing_mini                 61              12
#     7 => :imperial_shuttle            84               5
#     8 => :x_wing_tie_mini             105             17
#     9 => :at_te_walker                100             22
#     10 => :x_wing                     309             28
#     11 => :passenger_plane            326             28
#     12 => :imperial_star_destroyer    418             11
#     13 => :kings_castle               761             70
#     14 => :at_at                      1105             2
#     15 => :saturn_v                   1845           306

project_params = get_project_params(4)  # 4번 = tractor. 여기 숫자만 바꾸면 다른 프로젝트로 실험 가능


open_animation_at_end = true            # 끝나면 브라우저로 애니메이션 자동 열기
save_animation_along_the_way = false    # 중간 저장 안 함
save_animation_at_end = false           # 끝에 파일 저장 안 함
anim_active_agents = true # green circles around active agents (robots and transport units)  # 활동 로봇/유닛에 초록 원
anim_active_areas = true # purple circles around active assembly areas                        # 활동 조립구역에 보라 원

update_anim_at_every_step = true        # 매 스텝 애니메이션 갱신(부드럽지만 느림)
save_anim_interval = 100                # (저장 시) 100스텝마다 저장
process_updates_interval = 100          # 100스텝마다 상태 업데이트 처리
block_save_anim = false                 # 저장 시 블로킹(동기) 여부

tangent_bug_flag = true                 # tangent bug 회피 켬
rvo_flag = true                         # RVO 충돌회피 켬
dispersion_flag = true                  # dispersion(분산 배치) 켬
assignment_mode = :greedy # :milp :milp_w_greedy_warm_start  # 작업배정: 그리디(다른 값으로 바꿔 비교 가능)
milp_optimizer = :highs # :gurobi :highs                     # MILP 쓸 때의 솔버 선택
optimizer_time_limit = 60               # MILP 제한시간(초)


env, stats = run_lego_demo(;  # 데모 전체 실행 → env(최종 환경), stats(통계)
    ldraw_file=project_params[:file_name],
    project_name=project_params[:project_name],
    model_scale=project_params[:model_scale],
    num_robots=project_params[:num_robots],
    assignment_mode=assignment_mode,
    milp_optimizer=milp_optimizer,
    optimizer_time_limit=optimizer_time_limit,
    rvo_flag=rvo_flag,
    tangent_bug_flag=tangent_bug_flag,
    dispersion_flag=dispersion_flag,
    open_animation_at_end=open_animation_at_end,
    save_animation=save_animation_at_end,
    save_animation_along_the_way=save_animation_along_the_way,
    anim_active_agents=anim_active_agents,
    anim_active_areas=anim_active_areas,
    update_anim_at_every_step=update_anim_at_every_step,
    save_anim_interval=save_anim_interval,
    process_updates_interval=process_updates_interval,
    block_save_anim=block_save_anim,
    write_results=false,                    # 결과 파일 기록 안 함
    overwrite_results=false,                 # 기존 결과 덮어쓰기 안 함
    look_for_previous_milp_solution=false,   # 저장된 MILP 해 재사용 안 함
    save_milp_solution=false,                # MILP 해 저장 안 함
    previous_found_optimizer_time=30,        # 이전 MILP 최적화에 걸린 시간(참고값)
    max_num_iters_no_progress=2500,          # 2500스텝 진척 없으면 멈춤(무한루프 방지)
    stop_after_task_assignment=false         # false = 배정 후에도 시뮬레이션 끝까지 진행
);  # 끝의 세미콜론 = 반환값을 REPL에 출력하지 않음
