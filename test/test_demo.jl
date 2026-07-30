# ============================================================================
#  이 파일이 하는 일: 실제 레고(LEGO) 조립 데모를 처음부터 끝까지 돌려 보는 통합(integration) 테스트.
#  프로젝트 속 역할: 전체 파이프라인(모델 파싱 → 스케줄 → 작업배정 → 시뮬레이션)이 세 가지
#  작업배정 방식으로 각각 끝까지 돌아가는지 확인. run_lego_demo(...) 한 번이 시뮬레이션 전체를 실행.
#  세 개의 let 블록 = 같은 프로젝트(tractor)를 assignment_mode 만 바꿔 3번 실행:
#    (1) :greedy (그리디), (2) :milp (정수계획 최적화), (3) :milp_w_greedy_warm_start(그리디로 초기해 준 MILP).
#  Julia 문법 참고:
#   · let ... end : 각 실행을 독립 스코프로 격리(같은 변수 이름을 블록마다 재사용).
#   · run_lego_demo(; key=val, ...) : 세미콜론(;) 뒤는 전부 "키워드 인자"(이름을 붙여 전달).
#   · :greedy, :milp 같은 :이름 = Symbol(가벼운 상수 라벨). 모드 선택 스위치로 씀.
#   · project_params[:file_name] : Dict 에서 :file_name 키의 값을 꺼냄.
#   · a, b = f(...) : 함수가 돌려준 튜플을 두 변수로 한 번에 분해 대입.
#  도메인 용어: RVO=충돌회피 속도장애물, tangent_bug=벽 따라가기 회피, dispersion=분산 배치, makespan=총 완료시간.
# ============================================================================

# (1) 그리디(greedy) 작업배정으로 tractor 데모를 끝까지 실행 + 애니메이션 저장. RVO 등 회피 정책 모두 ON.
let
    project_params = get_project_params(4)  # 4번 프로젝트 = tractor(부품 20, 조립체 8)의 파일/스케일/로봇수 설정
    open_animation_at_end        = false    # 끝나고 브라우저로 애니메이션 열기 안 함
    save_animation_along_the_way = false    # 중간중간 애니메이션 저장 안 함
    save_animation_at_end        = true     # 끝에서 애니메이션 저장함
    anim_active_agents           = true     # 활동 중 로봇/운반유닛 초록 원 표시
    anim_active_areas            = true     # 활동 중 조립 구역 보라 원 표시

    rvo_flag                     = true     # RVO 충돌회피 켬
    tangent_bug_flag             = true     # tangent bug 회피 켬
    dispersion_flag              = true     # dispersion(분산) 켬
    assignment_mode              = :greedy # :milp :greedy :milp_w_greedy_warm_start  # 이번 실행은 그리디

    write_results                = false    # 결과 파일 기록 안 함
    overwrite_results            = false    # 기존 결과 덮어쓰기 안 함


    env, stats = run_lego_demo(;  # 데모 전체 실행 → env(최종 환경)과 stats(통계) 반환
        ldraw_file                   = project_params[:file_name],     # 조립도(.ldr/.mpd) 파일명
        project_name                 = project_params[:project_name],  # 결과 저장 폴더명이 되는 프로젝트 이름
        model_scale                  = project_params[:model_scale],   # 모델 크기 배율
        num_robots                   = project_params[:num_robots],    # 투입 로봇 수

        assignment_mode              = assignment_mode,   # 작업배정 방식(여기선 :greedy)

        rvo_flag                     = rvo_flag,          # 아래 세 개는 회피/분산 정책 on/off 전달
        tangent_bug_flag             = tangent_bug_flag,
        dispersion_flag              = dispersion_flag,

        open_animation_at_end        = open_animation_at_end,
        save_animation               = save_animation_at_end,
        save_animation_along_the_way = save_animation_along_the_way,
        anim_active_agents           = anim_active_agents,
        anim_active_areas            = anim_active_areas,

        write_results                = write_results,
        overwrite_results            = overwrite_results,

        stop_after_task_assignment = false  # false = 배정 후 멈추지 말고 시뮬레이션까지 끝까지 진행
    )

end

# (2) MILP(정수계획) 최적 배정으로 실행 — 회피/애니메이션은 모두 끄고 배정 품질만 봄. gurobi 로 30초 제한.
let
    project_params = get_project_params(4)
    open_animation_at_end        = false
    save_animation_along_the_way = false
    save_animation_at_end        = false
    anim_active_agents           = false
    anim_active_areas            = false

    rvo_flag                     = false   # 회피 정책 전부 끔(순수 배정/스케줄만 검증)
    tangent_bug_flag             = false
    dispersion_flag              = false
    assignment_mode              = :milp  # :greedy :milp_w_greedy_warm_start  # 이번 실행은 MILP 최적화

    write_results                = true    # 이번엔 결과 파일 기록
    overwrite_results            = true


    env, stats = run_lego_demo(;
        ldraw_file                   = project_params[:file_name],
        project_name                 = project_params[:project_name],
        model_scale                  = project_params[:model_scale],
        num_robots                   = project_params[:num_robots] + 5,  # 로봇 5대 추가 투입

        assignment_mode              = assignment_mode,
        milp_optimizer               = :gurobi, # :gurobi :highs  # 사용할 MILP 솔버(gurobi)
        optimizer_time_limit         = 30,      # 최적화 제한시간 30초(넘으면 그때까지 최선해 사용)


        rvo_flag                     = rvo_flag,
        tangent_bug_flag             = tangent_bug_flag,
        dispersion_flag              = dispersion_flag,

        open_animation_at_end        = open_animation_at_end,
        save_animation               = save_animation_at_end,
        save_animation_along_the_way = save_animation_along_the_way,
        anim_active_agents           = anim_active_agents,
        anim_active_areas            = anim_active_areas,

        write_results                = write_results,
        overwrite_results            = overwrite_results,

        look_for_previous_milp_solution = false,  # 저장된 이전 MILP 해를 재사용하지 않음
        save_milp_solution              = false,  # 이번 MILP 해도 저장하지 않음

        stop_after_task_assignment = false
    )

end

# (3) MILP + greedy warm start: 그리디 해를 초기값으로 준 MILP. 나머지 조건은 (2)와 동일.
let
    project_params = get_project_params(4)
    open_animation_at_end        = false
    save_animation_along_the_way = false
    save_animation_at_end        = false
    anim_active_agents           = false
    anim_active_areas            = false

    rvo_flag                     = false
    tangent_bug_flag             = false
    dispersion_flag              = false
    assignment_mode              = :milp_w_greedy_warm_start  # 그리디로 몸풀기(warm start) 후 MILP 최적화

    write_results                = true
    overwrite_results            = true


    env, stats = run_lego_demo(;
        ldraw_file                   = project_params[:file_name],
        project_name                 = project_params[:project_name],
        model_scale                  = project_params[:model_scale],
        num_robots                   = project_params[:num_robots] + 5,

        assignment_mode              = assignment_mode,
        milp_optimizer               = :gurobi, # :gurobi :highs
        optimizer_time_limit         = 30,


        rvo_flag                     = rvo_flag,
        tangent_bug_flag             = tangent_bug_flag,
        dispersion_flag              = dispersion_flag,

        open_animation_at_end        = open_animation_at_end,
        save_animation               = save_animation_at_end,
        save_animation_along_the_way = save_animation_along_the_way,
        anim_active_agents           = anim_active_agents,
        anim_active_areas            = anim_active_areas,

        write_results                = write_results,
        overwrite_results            = overwrite_results,

        look_for_previous_milp_solution = false,
        save_milp_solution              = false,

        stop_after_task_assignment = false
    )

end

# (선택) 스케줄/스테이징 그림 그리기 스크립트를 붙여 돌릴 자리 — 지금은 주석 처리로 비활성.
let
    # include("stage_graph_plots.jl")
end
