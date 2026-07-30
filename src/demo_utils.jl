
# ============================================================================
#  이 파일은 데모용 "공용 헬퍼" 모음 — full_demo.jl(run_lego_demo)이 불러다 쓰는 도구들.
#  크게 두 종류: (1) 시뮬레이션 루프 자체(run_simulation!/simulate!) — 매 스텝 환경을 전진시키고,
#  OOD·RESPEC hook 을 발동하고, MeshCat 애니메이션 프레임을 기록하고 진행률을 갱신함;
#  (2) 배치·기하 유틸(적치 원 계산·정리, 부품 시작 위치 격자 탐색, 애니메이션 HTML 저장).
#  Julia 문법 참고:
#   · struct = 불변 데이터 틀, mutable struct = 값 변경 가능(파이썬 class 에 더 가까움).
#   · `이름::타입` 필드/인자 타입 표기, `<: Exception` = 그 타입의 하위 타입(상속) 표시.
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
#   · `@unpack`, `@warn` = 매크로(코드 변형/로그 출력), `do ... end` = 마지막 인자로 넘기는 익명함수.
#   · `:이름` = Symbol(가벼운 이름표), `.연산` = 브로드캐스트(배열 각 원소에 적용).
#   · 같은 이름 함수를 인자 타입만 바꿔 여러 번 정의 = 다중 디스패치.
# ============================================================================

# struct : 새 데이터 타입(구조체) 정의 — 파이썬의 class 와 비슷하지만 "값을 담는 틀".
#          기본 struct 는 "불변(immutable)" — 한번 만들면 필드 값을 바꿀 수 없음.
# 이 타입은 시뮬레이션 실행에 필요한 설정값(파라미터)들을 한데 모아둔 묶음.
struct SimParameters
    sim_batch_size::Int               # 한 번에 돌릴 시뮬 스텝 묶음 크기. `::Int` = 이 필드 타입은 정수
    max_time_steps::Int               # 최대 시간 스텝 수(이만큼 지나면 강제 종료)
    process_animation_tasks::Bool     # 애니메이션 작업을 처리할지 여부(`::Bool` = 참/거짓)
    save_anim_interval::Int           # 애니메이션을 저장하는 주기(스텝 간격)
    process_updates_interval::Int     # 시각화 업데이트를 모아서 처리하는 주기
    block_save_anim::Bool             # 애니메이션을 통째로(블록 단위) 저장할지 여부
    update_anim_at_every_step::Bool   # 매 스텝마다 애니메이션을 갱신할지 여부
    anim_active_agents::Bool          # 활성 로봇(에이전트)을 애니메이션에 표시할지 여부
    anim_active_areas::Bool           # 활성 조립 영역을 애니메이션에 표시할지 여부
    save_anim_prog_path::String       # 진행중 애니메이션을 저장할 경로(`::String` = 문자열)
    save_animation_along_the_way::Bool  # 진행 도중에도 중간 애니메이션을 저장할지 여부
    max_num_iters_no_progress::Int    # 진전이 없는 상태를 몇 번까지 참을지(이 횟수 넘으면 종료)
end

# mutable struct : "변경 가능한" 구조체. 기본 struct 와 달리 만든 뒤에도 필드 값을 바꿀 수 있음.
#                  (파이썬 class 는 기본적으로 변경 가능 → 이쪽이 파이썬 class 에 더 가까움)
# 이 타입은 시뮬레이션이 "돌아가는 동안" 계속 갱신되는 진행 상태값들을 담음.
mutable struct SimProcessingData
    stop_simulating::Bool             # 시뮬레이션을 멈춰야 하는지(완료/교착 시 true)
    iter::Int                         # 현재까지 진행한 반복(스텝) 횟수
    starting_frame::Int               # 애니메이션 시작 프레임 번호
    prog::ProgressMeter.Progress      # 진행률 막대 객체(`Pkg.Type` = 그 패키지 안의 타입)
    num_closed_step_1::Int            # 첫 스텝에서 이미 끝난(closed) 작업 수
    last_iter_num_closed::Int         # 직전 반복에서 끝난 작업 수(진전 여부 비교용)
    num_iters_no_progress::Int        # 연속으로 진전이 없었던 반복 횟수
    num_iters_since_anim_save::Int    # 마지막 애니메이션 저장 이후 지난 반복 횟수
    progress_update_fcn::Function     # 진행률 표시에 쓸 함수(`::Function` — 함수도 값처럼 저장 가능)
end

# 필드가 없는 빈 struct. <: Exception = "이 타입은 예외(Exception) 종류 중 하나"라는 상속 표시.
# 파이썬의 `class NoSolutionError(Exception): pass` 와 같은 개념(해를 못 찾았을 때 던지는 예외).
struct NoSolutionError <: Exception end
# Base.showerror : 줄리아 표준(Base)에 이미 있는 함수에 "이 예외 타입일 때의 동작"을 추가 정의(다중 디스패치).
#   `f(...) = ...` 한 줄짜리 함수 정의. e::NoSolutionError = 이 메서드는 그 예외 타입에만 적용.
#   예외가 출력될 때 io(출력 대상)에 정해진 메시지를 찍어줌.
Base.showerror(io::IO, e::NoSolutionError) = print(io, "No solution found!")

"""
    run_simulation!(env, factory_vis, anim, sim_params)

Run a simulation of the environment. Currently, this wraps another simulation function to
help with memory issues. The goal is to refactor the code to not require this "hack".
"""
# function ... end : 함수 정의(여러 줄 형태). 이름 끝의 `!` 는 관례 — "인자(env 등)를 직접 수정함" 표시.
# 인자마다 `이름::타입` 으로 타입을 못박음(다중 디스패치 — 인자 타입에 따라 알맞은 메서드가 선택됨).
# Union{A,Nothing} : "A 타입 이거나, 값 없음(Nothing) 둘 중 하나"라는 뜻(파이썬의 Optional[A] 과 비슷).
function run_simulation!(
    env::PlannerEnv,                                            # 시뮬레이션 환경(스케줄·캐시 등 전체 상태)
    factory_vis::ConstructionBots.FactoryVisualizer,           # 3D 시각화 담당 객체
    anim::Union{ConstructionBots.AnimationWrapper,Nothing},    # 애니메이션 기록기(없으면 Nothing)
    sim_params::SimParameters                                  # 위에서 정의한 시뮬 설정값 묶음
)

    it = 1                                                     # 스텝 번호 카운터(초기값 1)
    ConstructionBots.step_environment!(env)                    # 환경을 한 스텝 전진시킴(! → env 직접 수정)
    ConstructionBots.update_planning_cache!(env, 0.0)          # 계획 캐시 갱신(끝난 작업 목록 등 갱신)

    step_1_closed = length(env.cache.closed_set)               # 첫 스텝에서 이미 끝난 작업 수(env.필드 = 필드 접근)
    total_nodes = nv(env.sched)                                # 스케줄 그래프의 전체 노드 수(nv = number of vertices)
    # 한 줄 함수 정의 + `->` 익명함수 반환. () -> [...] 는 "인자 없는 람다"(파이썬 lambda: [...]).
    # `:이름` 은 심볼(Symbol) — 변하지 않는 이름표(파이썬 문자열 키처럼 라벨로 씀).
    generate_showvalues(it, nc) = () -> [(:step_num, it), (:n_closed, nc), (:n_total, total_nodes)]
    prog = ProgressMeter.Progress(                             # 진행률 막대 객체 생성
        nv(env.sched) - step_1_closed;                         # 전체 노드 - 이미 끝난 수 = 남은 작업 수(`;` 뒤는 키워드 인자)
        desc="Simulating...",                                  # 막대 앞에 붙는 설명 문구
        barlen=50,                                             # 막대 길이(문자 50칸)
        showspeed=true,                                        # 처리 속도 표시 여부
        dt=1.0                                                 # 화면 갱신 최소 간격(초)
    )

    starting_frame = 0                                         # 시작 프레임 기본값 0
    # `!isnothing(x)` : x 가 Nothing 이 아니면 참. `!` 는 논리 부정(NOT). isnothing = 값이 없는지 검사.
    if !isnothing(anim)                                        # 애니메이션 객체가 있다면
        starting_frame = ConstructionBots.current_frame(anim) # 현재 프레임 번호를 시작점으로 가져옴
    end

    sim_process_data = SimProcessingData(                      # 진행상태 객체 생성(필드 순서대로 값을 넣음)
        false, 1, starting_frame, prog, step_1_closed, step_1_closed, 0, 0, generate_showvalues
    )

    up_steps = []                                              # 빈 배열(파이썬 리스트). 업데이트 단계들을 모을 그릇
    # while 조건 : 멈춤 신호가 없고(`!`) AND(`&&`) 최대 스텝에 도달하지 않은 동안 반복
    while !sim_process_data.stop_simulating && sim_process_data.iter < sim_params.max_time_steps
        up_steps = simulate!(env, factory_vis, anim, sim_params, sim_process_data, up_steps)  # 실제 시뮬 한 묶음 실행
        # MONITOR seam: 배치마다 env 상태를 JSONL 한 줄로 방출. monitor_enable! 를 안 했으면 즉시 반환(no-op).
        monitor_emit!(env, sim_process_data.iter)
    end

    # return : 두 값을 동시에 반환(튜플). (프로젝트 완료 여부, 총 반복 횟수)
    return ConstructionBots.project_complete(env), sim_process_data.iter
end

# 실제 시뮬레이션 한 묶음(batch)을 도는 함수. update_steps::Vector = 인자 타입이 배열(Vector)임을 명시.
function simulate!(
    env::PlannerEnv,                                            # 시뮬레이션 환경
    factory_vis::ConstructionBots.FactoryVisualizer,           # 3D 시각화 객체
    anim::Union{ConstructionBots.AnimationWrapper,Nothing},    # 애니메이션 기록기(없으면 Nothing)
    sim_params::SimParameters,                                 # 시뮬 설정값
    sim_process_data::SimProcessingData,                       # 진행상태(매 스텝 갱신됨)
    update_steps::Vector                                       # 모아둔 시각화 업데이트 단계 배열
)

    # @unpack : Parameters 패키지 매크로. 구조체의 필드들을 같은 이름의 지역변수로 한꺼번에 꺼냄.
    #           (파이썬의 `sched, cache = env.sched, env.cache` 를 자동으로 해주는 셈)
    @unpack sched, cache = env                                              # env 에서 sched, cache 필드를 꺼냄
    @unpack sim_batch_size, max_time_steps = sim_params                     # sim_params 에서 두 설정값 꺼냄
    @unpack process_animation_tasks, save_anim_interval = sim_params        # 애니메이션 처리 여부·저장 주기
    @unpack process_updates_interval, block_save_anim, anim_active_agents = sim_params  # 업데이트 주기·블록저장·에이전트표시
    @unpack anim_active_areas, max_num_iters_no_progress = sim_params       # 영역표시·무진전 한계
    @unpack save_animation_along_the_way, save_anim_prog_path = sim_params  # 도중저장 여부·저장경로

    # for _ in 1:N : N번 반복. `_` 는 "쓰지 않는 변수"라는 관례 이름. `1:N` 은 1부터 N까지의 범위.
    for _ in 1:sim_batch_size
        sim_process_data.iter += 1                                          # 반복 횟수 1 증가(필드 직접 수정)

        # Interactive commands must enter at simulation-step granularity. Reading
        # them only after a 50-step batch let the build advance substantially
        # before a newly injected safety zone became active.
        ConstructionBots.monitor_control_step!(env, factory_vis, anim, sim_process_data.iter)

        # OOD injection seam: drive a scheduled physical OOD generator (e.g. a
        # restriction-district / robot-fault) into the world. No-op (free) unless
        # a trigger was scheduled via schedule_ood!, so existing runs are unchanged.
        # (예약된 OOD=이상상황 이벤트를 이번 스텝에 주입. 예약 안 했으면 아무 일도 안 함)
        ConstructionBots.ood_inject_step!(env, sim_process_data.iter)       # OOD 이벤트 주입(통행금지·로봇고장 등)
        # RESPEC seam: verified LLM re-specification on OOD events. No-op unless
        # ConstructionBots.RESPEC_ENABLED[] is set, so existing runs are unchanged.
        # ORDER: process the OOD (hand-off) BEFORE driving this step, so the re-spec takes effect
        # on the same step the fault is observed -- matching the direct test path (replace, THEN
        # resume). Driving first would advance one step with the faulted robot still bound, which
        # near a multi-robot-team threshold can flip a marginal completion into a stall.
        ConstructionBots.respec_step!(env)                                  # LLM 재명세 단계 실행(구동 전)
        ConstructionBots.step_environment!(env)                             # 환경을 한 스텝 전진
        newly_updated = ConstructionBots.update_planning_cache!(env, 0.0)   # 캐시 갱신 → 이번에 새로 끝난 노드 목록 반환
        # Capture short FORM / DEPOSIT / LIFT nodes before the next 50-step UI
        # frame.  Sampling only in monitor_emit! made these actions disappear
        # from the realized schedule whenever they completed between frames.
        ConstructionBots.monitor_track_schedule_step!(env, sim_process_data.iter; dt=env.dt)
        # E1 (proposal V3): after a spare hand-off, re-impose "one active transport task per
        # robot" each step so a single spare is never double-booked across teams. No-op (cheap
        # scan) unless RESPEC is active AND a robot has >1 active transport frontier (only the
        # post-hand-off spare), so baseline/nominal runs are unchanged. (verified: 235->246)
        ConstructionBots.RESPEC_ENABLED[] && ConstructionBots._enforce_serial_frontiers!(env)

        # `factory_vis.vis` 가 Nothing 이 아닐 때(즉 시각화기가 실제로 켜져 있을 때)만 안쪽 실행
        if !isnothing(factory_vis.vis)
            # `||` 는 논리 OR. isempty = 비었는지 검사. "새로 갱신된 게 있거나 OR 매스텝갱신 옵션이 켜졌으면"
            if !isempty(newly_updated) || sim_params.update_anim_at_every_step
                # 함수가 튜플로 반환한 여러 값을 한 줄에서 각 변수로 동시에 풀어 받음(다중 대입)
                scene_nodes, closed_steps_nodes, active_build_nodes, fac_active_flags_nodes, fac_faulted_flags_nodes, fac_dispatched_flags_nodes, fac_battery_tint_nodes = ConstructionBots.visualizer_update_function!(factory_vis, env, newly_updated)
                sim_process_data.num_iters_since_anim_save += 1             # 마지막 저장 이후 카운터 +1
                if process_animation_tasks                                  # 애니메이션 작업 처리 옵션이 켜져 있으면
                    # NOTE: do NOT deepcopy vis_nodes. A deepcopied MeshCat node carries a
                    # throwaway `core`/connection, so settransform! on it inside `atframe`
                    # targets a visualizer that is not `anim`'s and is silently NOT recorded
                    # (see the warning in render_tools.jl AnimationWrapper). That made robot
                    # MOTION never animate while visibility toggles (live nodes) still did.
                    # We only need to freeze the transform VALUES, which deepcopy(scene_nodes)
                    # already does (global_transform is cached on each node); the live
                    # factory_vis.vis_nodes are reused at playback time below.
                    # 이번 스텝의 상태를 튜플로 묶음. 2번째 원소는 카메라-follow 타겟(꺼져 있으면 nothing).
                    #   CAMERA_FOLLOW[] 이 켜져 있을 때만 현재 "제조 중심점"(활성 에이전트 중심)을 계산해 넣음.
                    cam_tgt = ConstructionBots.CAMERA_FOLLOW[] ? ConstructionBots._camera_follow_target(env) : nothing
                    update_tuple = (sim_process_data.iter, cam_tgt,
                        deepcopy(scene_nodes), closed_steps_nodes, active_build_nodes,
                        fac_active_flags_nodes, fac_faulted_flags_nodes, fac_dispatched_flags_nodes,
                        fac_battery_tint_nodes)
                    push!(update_steps, update_tuple)                      # push! : 배열 끝에 추가(파이썬 list.append)
                end
            end
        end

        # `==` 는 값이 같은지 비교. "이번에 끝난 작업 수가 직전과 똑같으면(= 진전 없음)"
        if length(cache.closed_set) == sim_process_data.last_iter_num_closed
            sim_process_data.num_iters_no_progress += 1                    # 무진전 카운터 +1
        else
            sim_process_data.num_iters_no_progress = 0                     # 진전이 있었으면 0으로 리셋
        end
        sim_process_data.last_iter_num_closed = length(cache.closed_set)   # 이번 끝난 작업 수를 다음 비교용으로 저장

        # CLOSED-LOOP self-healing (OOD 1-1): a SUSTAINED wedge (no progress) after a spare
        # hand-off is the second-order failure -- a multi-robot transport team can't finish
        # forming. Emit a "team deadlocked" OOD so the respec layer re-establishes the stuck
        # team(s) via ReformTeam BEFORE we give up. Now factored into the SHARED
        # `maybe_emit_reform_ood!` (ood_injection.jl) so the RL event-triggered env emits the SAME
        # team-deadlock OOD identically (LLM-vs-RL symmetry; EVENT_MDP_DESIGN.md §4). RESPEC-gated
        # and verify_reform-guarded, so nominal/baseline runs never emit it.
        ConstructionBots.maybe_emit_reform_ood!(sim_process_data.num_iters_no_progress)

        project_stop_bool = ConstructionBots.project_complete(env)         # 프로젝트가 완성됐는지(참/거짓)
        # `>=` 크거나 같음. 무진전이 한계치 이상이면 더 못 나아가는 것으로 보고 종료 플래그를 켬
        if sim_process_data.num_iters_no_progress >= max_num_iters_no_progress
            # `@warn` 경고 로그 매크로. "$(...)" 는 문자열 보간(파이썬 f-string 의 {} 와 같은 역할)
            @warn "No progress for $(sim_process_data.num_iters_no_progress) iterations. Terminating."
            project_stop_bool = true                                       # 강제 종료로 표시
        end

        # 애니메이션 처리 옵션 ON 이고 AND (모인 단계가 주기 이상이거나 OR 종료 시점이면) 아래 실행
        if process_animation_tasks &&
           (length(update_steps) >= process_updates_interval || project_stop_bool)

            if block_save_anim                                            # 블록 저장 모드면(처음부터 다시 기록)
                anim = ConstructionBots.AnimationWrapper(0, factory_vis.vis)   # 새 애니메이션 기록기 생성(0프레임부터)
                update_visualizer!(factory_vis)                          # 시각화기를 현재 상태로 한번 갱신
                settransform!(factory_vis.vis["/Cameras/default"], CoordinateTransformations.Translation(0, 0, 0))  # 카메라 위치를 원점으로(["경로"]로 하위 객체 접근)
                setprop!(factory_vis.vis["/Cameras/default/rotated/<object>"], "position", CoordinateTransformations.Translation(0, 10, 0).translation)  # 카메라 위치 속성 설정(.translation = 이동 벡터 필드)
            end

            k_i = 0                                                       # 블록 저장 시 프레임 번호 카운터
            for step_k in update_steps                                   # 모아둔 각 업데이트 단계에 대해 반복
                k_k = step_k[1]                                          # 튜플의 1번째 원소(반복 번호). 줄리아 인덱스는 1부터 시작!
                scene_nodes_k = step_k[3]                                # 3번째 원소(장면 노드들의 고정된 변환값)
                closed_steps_nodes_k = step_k[4]                         # 4번째(끝난 단계 노드들)
                active_build_nodes_k = step_k[5]                         # 5번째(현재 조립중 노드들)
                fac_active_flags_nodes_k = step_k[6]                     # 6번째(활성 표시 깃발 노드들)

                current_frame = k_k + sim_process_data.starting_frame   # 실제 프레임 = 스텝번호 + 시작프레임
                if block_save_anim                                      # 블록 저장 모드면 프레임을 1,2,3... 으로 다시 매김
                    k_i += 1
                    current_frame = k_i
                end
                ConstructionBots.set_current_frame!(anim, current_frame)  # 기록기의 현재 프레임을 지정

                # atframe(anim, 프레임) do ... end : "이 프레임 시점에 일어날 일"을 do 블록(익명함수)으로 기록.
                #   do ... end 는 마지막 인자로 함수를 넘기는 줄리아 문법(파이썬에는 없음 — with 비슷한 느낌).
                atframe(anim, ConstructionBots.current_frame(anim)) do
                    # CAMERA-FOLLOW: re-centre the camera on this frame's manufacturing point so a
                    # relocated build stays in view (step_k[2] is nothing unless CAMERA_FOLLOW[]).
                    if step_k[2] !== nothing
                        settransform!(factory_vis.vis["/Cameras/default"],
                            CoordinateTransformations.Translation(step_k[2]...))
                    end
                    if anim_active_areas                                # 활성 영역 표시 옵션이 켜져 있으면
                        for node_i in closed_steps_nodes_k             # 끝난 단계 노드들은
                            setvisible!(node_i, false)                 # 안 보이게 처리
                        end
                        for node_i in active_build_nodes_k             # 조립중 노드들은
                            setvisible!(node_i, true)                  # 보이게 처리
                        end
                    end
                    if anim_active_agents                              # 활성 에이전트 표시 옵션이 켜져 있으면
                        setvisible!(factory_vis.active_flags, false)   # 모든 활성 깃발을 일단 숨기고
                        for node_key in fac_active_flags_nodes_k       # 이번 스텝에 활성인 깃발들만
                            setvisible!(factory_vis.active_flags[node_key], true)  # 다시 보이게(["키"]로 항목 접근)
                        end
                    end
                    # OOD 1-1: RED disc under faulted robots (from the breakdown step onward).
                    fac_faulted_flags_nodes_k = length(step_k) >= 7 ? step_k[7] : []   # 7번째(고장 로봇 ID들)
                    setvisible!(factory_vis.faulted_flags, false)      # 모든 고장표시 숨기고
                    for node_key in fac_faulted_flags_nodes_k          # 이번 프레임에 고장난 로봇만
                        haskey(factory_vis.faulted_flags, node_key) &&
                            setvisible!(factory_vis.faulted_flags[node_key], true)  # 빨간 원판 켜기
                    end
                    # OOD 1-1: CYAN ring under depot-dispatched replacement robots (from the swap step on).
                    fac_dispatched_flags_nodes_k = length(step_k) >= 8 ? step_k[8] : []   # 8번째(디스패치 로봇 ID들)
                    setvisible!(factory_vis.dispatched_flags, false)
                    for node_key in fac_dispatched_flags_nodes_k
                        haskey(factory_vis.dispatched_flags, node_key) &&
                            setvisible!(factory_vis.dispatched_flags[node_key], true)  # 시안 링 켜기
                    end
                    # Battery depletion is a body tint, distinct from the cyan
                    # replacement marker. The ID list is frozen per keyframe.
                    fac_battery_tint_nodes_k = length(step_k) >= 9 ? step_k[9] : []
                    setvisible!(factory_vis.battery_tints, false)
                    for node_key in fac_battery_tint_nodes_k
                        haskey(factory_vis.battery_tints, node_key) &&
                            setvisible!(factory_vis.battery_tints[node_key], true)
                    end
                    # Use the LIVE vis_nodes (same core as `anim`) so these transforms are
                    # actually recorded into the animation. scene_nodes_k holds the frozen
                    # per-step transform values from the deepcopy above.
                    # 살아있는(live) vis_nodes 에 이번 스텝의 변환값을 적용 → 실제로 애니메이션에 기록됨
                    ConstructionBots.update_visualizer!(factory_vis.vis_nodes, scene_nodes_k)
                end
            end
            setanimation!(factory_vis.vis, anim.anim, play=false)        # 기록한 애니메이션을 시각화기에 등록(자동재생은 끔)
            update_steps = []                                           # 처리 끝났으니 모음 배열 비움

            # 도중저장 ON 이고 AND 경로 있음 AND 아직 종료 아님 AND 저장 주기 도달 → 중간 저장
            if (save_animation_along_the_way &&
                !isnothing(save_anim_prog_path) &&
                !project_stop_bool &&
                sim_process_data.num_iters_since_anim_save >= save_anim_interval)

                # 경로+반복번호+".html" 을 문자열 보간으로 합쳐 파일명을 만들어 저장
                save_animation!(factory_vis.vis, "$(save_anim_prog_path)$(sim_process_data.iter).html")
                sim_process_data.num_iters_since_anim_save = 0          # 저장했으니 카운터 리셋
            end
        end

        nc = length(cache.closed_set)                                  # 현재까지 끝난 작업 수
        ProgressMeter.update!(                                         # 진행률 막대 갱신
            sim_process_data.prog, nc - sim_process_data.num_closed_step_1;  # 진행량 = 지금까지 끝난 수 - 첫 스텝에 끝난 수
            showvalues=sim_process_data.progress_update_fcn(sim_process_data.iter, nc)  # 막대 옆에 표시할 값들
        )

        if project_stop_bool                                           # 종료 시점이면
            ProgressMeter.finish!(sim_process_data.prog)               # 진행률 막대를 완료 상태로 마무리
            if ConstructionBots.project_complete(env)                  # 실제로 완성됐으면
                println("PROJECT COMPLETE!")                           # 완료 메시지 출력
            else                                                       # 완성 못 했으면(교착 등으로 중단)
                println("PROJECT INCOMPLETE!")                         # 미완료 메시지 출력
                # 사후분석용 전체상태 덤프는 기본 OFF (덤프 하나가 env+시각화+애니 통째 직렬화라 최대 ~230MB).
                # 미완성 빌드가 흔한 OOD/replan 실험에선 매번 쌓여 디스크를 잠식하므로 opt-in으로 전환.
                # 켜려면: ENV["CB_VAR_DUMP"]="1" (또는 셸에서 CB_VAR_DUMP=1). scripts/debug_helper.jl 로 로드/재개.
                if get(ENV, "CB_VAR_DUMP", "0") == "1"
                    # joinpath : OS에 맞게 경로 조각을 합침. ".." = 상위 폴더. pathof = 패키지 설치 위치
                    var_dump_path = joinpath(dirname(pathof(ConstructionBots)), "..", "variable_dump")
                    mkpath(var_dump_path)                              # 그 폴더가 없으면 만듦(중간 폴더 포함)
                    var_dump_path = joinpath(var_dump_path, "var_dump_$(sim_process_data.iter).jld2")  # 덤프 파일 경로 완성
                    println("Dumping variables to $(var_dump_path)")   # 어디에 저장하는지 알림
                    # Dict(...) : 사전(딕셔너리). `"키" => 값` 형태의 쌍들로 구성(`=>` 는 키-값 연결 기호, 파이썬 : 역할)
                    var_dict = Dict(
                        "env" => env,
                        "factory_vis" => factory_vis,
                        "anim" => anim,
                        "sim_params" => sim_params,
                        "sim_process_data" => sim_process_data
                    )
                    print("\tSaving...")                               # "\t"=탭 문자. print 는 줄바꿈 없이 출력
                    JLD2.save(var_dump_path, var_dict)                 # 디버깅용으로 모든 상태를 파일에 저장
                    print("done!\n")                                   # "\n"=줄바꿈 문자
                else
                    println("\t(변수 덤프 생략됨 — 사후분석 .jld2를 저장하려면 ENV[\"CB_VAR_DUMP\"]=\"1\")")
                end
            end
        end

        sim_process_data.stop_simulating = project_stop_bool           # 종료 여부를 진행상태에 반영
        if sim_process_data.stop_simulating                            # 멈춰야 하면
            break                                                      # 반복문 즉시 탈출
        end
    end

    return update_steps                                                # 아직 처리 못한 업데이트 단계들을 돌려줌
end

# 애니메이션을 HTML 파일로 저장하는 함수. 인자에 타입을 안 적으면 "아무 타입이나 받음"(파이썬 기본과 같음).
function save_animation!(visualizer, path)
    println("Saving animation to $(path)")                # 어디에 저장하는지 출력
    # open(경로, "w") do io ... end : 파일을 쓰기("w")로 열고, do 블록이 끝나면 자동으로 닫음(파이썬 with open).
    open(path, "w") do io
        write(io, static_html(visualizer))                # 시각화기를 정적 HTML 문자열로 만들어 파일에 씀
    end
end

# 각 "조립 단계(build step)"의 적치 원(staging circle)을 모아 사전으로 돌려주는 함수.
function get_buildstep_circles(sched)
    # Dict{키타입,값타입}() : 빈 사전을 만들되 키·값 타입을 못박음. 여기선 키=AbstractID, 값=Ball2(공/원).
    circles = Dict{AbstractID,LazySets.Ball2}()
    # topological_sort_by_dfs : 의존성 순서(위상정렬)대로 노드 나열. node_iterator 로 그 노드들을 하나씩 순회.
    for n in node_iterator(sched, topological_sort_by_dfs(sched))
        if matches_template(OpenBuildStep, n)             # 이 노드가 "열린 조립 단계" 유형과 맞으면
            id = node_id(n)                               # 그 노드의 ID
            sphere = get_cached_geom(node_val(n).staging_circle)  # 노드 값에서 적치원의 캐시된 기하(구) 가져옴
            ctr = project_to_2d(sphere.center)            # 구의 중심(3D)을 2D 평면으로 투영
            circles[id] = LazySets.Ball2(ctr, sphere.radius)  # id 키에 (중심, 반지름)으로 만든 원을 저장
        end
    end
    return circles                                        # id → 원 사전을 반환
end

# 적치원들을 각 화물(cargo)의 실제 현재 위치로 옮겨주는 함수.
function shift_staging_circles(staging_circles::Dict{AbstractID,LazySets.Ball2}, sched, scene_tree)
    shifted_circles = Dict{AbstractID,LazySets.Ball2}()   # 옮긴 결과를 담을 빈 사전
    # for (a, b) in 사전 : 사전을 (키, 값) 쌍으로 분해하며 순회(파이썬 dict.items() 와 같음)
    for (id, geom) in staging_circles
        node = get_node(scene_tree, id)                   # 장면트리에서 id에 해당하는 노드(아래에서 안 쓰이는 변수)
        cargo = get_node(scene_tree, id)                  # 같은 노드를 화물로 가져옴
        # isa(값, 타입) : 그 값이 해당 타입인지 검사(파이썬의 isinstance 와 같음)
        if isa(cargo, AssemblyNode)                       # 화물이 "조립체" 노드라면
            cargo_node = get_node(sched, AssemblyComplete(cargo))   # 스케줄에서 "조립완료" 노드를 찾음
        else                                              # 아니면(단일 부품이라면)
            # get_node! : 없으면 새로 만들어서라도 가져옴(! → sched 를 수정할 수 있음). ObjectStart = 부품 시작 노드
            cargo_node = get_node!(sched, ObjectStart(cargo, TransformNode()))
        end

        # 화물의 전역 변환에서 위치(translation)를 꺼내 2D로 투영 → 옮길 목표 위치
        translate = project_to_2d(global_transform(start_config(cargo_node)).translation)
        tform = CoordinateTransformations.Translation(translate)  # 그 위치만큼 평행이동하는 변환 객체
        new_center = tform(geom.center)                   # 원래 원 중심에 평행이동 적용 → 새 중심
        shifted_circles[id] = LazySets.Ball2(new_center, geom.radius)  # 새 중심·같은 반지름으로 원 저장

    end
    return shifted_circles                                # 옮겨진 원들의 사전 반환
end

# 다른 원에 완전히 포함되는 "불필요한" 원들을 걸러내는 함수.
# `;` 뒤의 ϵ=1e-4 : 키워드 인자(기본값 0.0001). ϵ(엡실론)은 수치 오차 허용치. 1e-4 = 0.0001.
function remove_redundant(balls::Vector{LazySets.Ball2}; ϵ=1e-4)
    redundant = falses(length(balls))                     # 원 개수만큼 false 로 채운 불리언 배열(중복 표시용)
    for ii in 1:length(balls)                             # 모든 원 쌍을 이중 반복으로 비교
        for jj in 1:length(balls)
            # `!=` 다름. `&&` AND. ii≠jj 이고, jj가 아직 중복 아니고, ii가 jj 안에 포함되면
            if ii != jj && !redundant[jj] && contained_in(balls[ii], balls[jj]; ϵ=ϵ)
                redundant[ii] = true                      # ii번째 원을 "불필요"로 표시
            end
        end
    end
    # `.!` : 점(.)은 "브로드캐스트"(배열 각 원소에 연산 적용). `.!redundant` = 각 원소를 NOT 한 새 배열.
    #        balls[그 불리언배열] = true(즉 중복 아님)인 원들만 골라 반환.
    return balls[.!redundant]
end

# 한 원(test_ball)이 다른 원(outer_ball) 안에 완전히 들어가는지 검사하는 함수.
function contained_in(test_ball::LazySets.Ball2, outer_ball::LazySets.Ball2; ϵ=1e-4)
    # 두 중심 사이 거리 + 안쪽원 반지름 <= 바깥원 반지름(+오차) 이면 완전히 포함됨. norm = 벡터 길이(거리).
    return norm(test_ball.center - outer_ball.center) + test_ball.radius <= outer_ball.radius + ϵ
end

# 부품(object)들을 놓을 격자 위치(vertices)들을 계산해 돌려주는 함수.
# 장애물을 피하고, 필요하면 여러 층(layer)으로 쌓을 수 있도록 위치를 정함.
function get_object_vtx(scene_tree, obstacles, max_cargo_height, num_layers, robot_d)
    # Use object height to stack objects on top of each other as needed
    # map(f, 모음) : 모음의 각 원소에 함수 f 적용(파이썬 map). filter(f, 모음) : 조건 맞는 것만 남김.
    # `n -> ...` 는 익명함수(파이썬 lambda n: ...). HyperrectangleKey() 로 각 부품의 경계상자(직육면체)를 얻음.
    objects_hyperrects = map(n -> get_base_geom(n, HyperrectangleKey()),
        filter(n -> matches_template(ObjectNode, n), get_nodes(scene_tree)))   # 부품 노드들만 골라 그 경계상자 목록

    # [식 for x in 모음] : 배열 컴프리헨션(파이썬 리스트 컴프리헨션과 동일). radius[1]=x반지름, *2=전체 폭.
    max_object_x = maximum([ob.radius[1] * 2 for ob in objects_hyperrects])    # 부품 x폭의 최댓값
    max_object_y = maximum([ob.radius[2] * 2 for ob in objects_hyperrects])    # 부품 y폭의 최댓값
    max_object_h = maximum([ob.radius[3] * 2 for ob in objects_hyperrects])    # 부품 높이(z)의 최댓값

    mean_object_x = sum([ob.radius[1] * 2 for ob in objects_hyperrects]) / length(objects_hyperrects)  # x폭 평균
    mean_object_y = sum([ob.radius[2] * 2 for ob in objects_hyperrects]) / length(objects_hyperrects)  # y폭 평균

    std_object_x = std([ob.radius[1] * 2 for ob in objects_hyperrects])        # x폭의 표준편차(std)
    std_object_y = std([ob.radius[2] * 2 for ob in objects_hyperrects])        # y폭의 표준편차

    num_objects = length(filter(n -> matches_template(ObjectNode, n), get_nodes(scene_tree)))  # 전체 부품 개수

    # 격자 한 칸 x간격 = min(최댓값, 평균+3σ) + 로봇지름*2. 극단값에 휘둘리지 않게 평균+3σ로 상한을 둠.
    object_x_delta = min(max_object_x, mean_object_x + 3 * std_object_x) + robot_d * 2
    object_y_delta = min(max_object_y, mean_object_y + 3 * std_object_y) + robot_d * 2  # 격자 한 칸 y간격

    inflate_delta = max(max_object_x, max_object_y)       # 장애물을 부풀릴 여유 거리(가장 큰 부품 폭만큼)

    inflated_obstacles = []                               # 부풀린 장애물들을 담을 빈 배열
    for ob in obstacles                                   # 각 장애물에 대해
        push!(inflated_obstacles, LazySets.Ball2(ob.center, ob.radius + inflate_delta))  # 반지름을 키운 원으로 추가
    end

    num_objs_per_layer = ceil(num_objects / num_layers)   # 한 층당 부품 수(ceil = 올림)

    init_width = sqrt(num_objs_per_layer * object_x_delta * object_y_delta) / 2   # 초기 격자 반폭(필요 면적의 제곱근 절반)

    # a:step:b : a부터 b까지 step 간격의 범위(파이썬 range 와 비슷하나 끝값 b 포함). 격자 좌표 후보들.
    x_range = -init_width:object_x_delta:init_width       # x 좌표 범위
    y_range = -init_width:object_y_delta:init_width       # y 좌표 범위
    sweep_ranges = (x_range, y_range, 0:0)                # (x, y, z) 범위 튜플. z는 0:0 = 0 한 점뿐(한 층)

    found_size = false                                    # 충분한 위치를 찾았는지 플래그
    cnt = 0                                               # 격자 확장 시도 횟수 카운터
    # `$변수` 또는 `$(식)` : 문자열 보간. flush(stdout) : 출력 버퍼를 즉시 화면에 내보냄(로그가 밀리지 않게).
    println("[DIAG] get_object_vtx: grid search start. num_objects=$num_objects, num_layers=$num_layers, ",
        "init_width=$init_width, dx=$object_x_delta, dy=$object_y_delta, n_obstacles=$(length(inflated_obstacles))"); flush(stdout)
    while !found_size                                     # 충분한 위치를 찾을 때까지 격자를 넓혀가며 반복
        # construct_vtx_array(; 키워드들) : 맨 앞 `;` 는 "이후는 모두 키워드 인자"라는 표시.
        pts = ConstructionBots.construct_vtx_array(;
            origin=SVector{3,Float64}(0.0, 0.0, 0.0),     # SVector{3,Float64}(...) : 고정크기 3차원 실수 벡터(원점)
            obstacles=inflated_obstacles,                 # 피해야 할(부풀린) 장애물들
            ranges=sweep_ranges                           # 훑을 격자 범위
        )
        if length(pts) * num_layers >= num_objects        # (찾은 위치 수 × 층수)가 부품 수 이상이면 충분
            found_size = true                             # 성공 → 반복 종료
        else
            cnt += 1                                       # 부족하면 확장 횟수 +1
            if cnt % 25 == 0                               # `%` 나머지. 25번마다 한 번씩 진행상황 로그
                # ceil(Int, x) : x를 올림한 뒤 정수(Int)로 변환
                println("[DIAG] get_object_vtx: cnt=$cnt, legal_pts=$(length(pts)) (need $(ceil(Int, num_objects / num_layers))/layer), ",
                    "grid=$(length(x_range))x$(length(y_range))"); flush(stdout)
            end
            if cnt > 2_000                                 # 숫자 안 `_` 는 자릿수 구분용(2000). 너무 오래 헤매면
                error("[RUNAWAY] get_object_vtx grid-search loop exceeded 2000 expansions — never found enough legal points. legal_pts=$(length(pts)), need=$num_objects, n_obstacles=$(length(inflated_obstacles))")  # error : 예외를 던지며 중단
            end
            x_range = (-init_width-cnt*object_x_delta):object_x_delta:(init_width+cnt*object_x_delta)  # x 범위를 양쪽으로 넓힘
            y_range = (-init_width-cnt*object_y_delta):object_y_delta:(init_width+cnt*object_y_delta)  # y 범위를 양쪽으로 넓힘
            sweep_ranges = (x_range, y_range, 0:0)        # 넓힌 범위로 다시 묶음
        end
    end
    println("[DIAG] get_object_vtx: grid search done after cnt=$cnt expansions"); flush(stdout)  # 탐색 완료 로그

    object_vtx_range = (                                  # 최종 격자 범위(층 방향 포함)
        x_range,
        y_range,
        0:num_layers-1                                    # z 방향: 0층부터 (층수-1)층까지
    )

    vtxs = ConstructionBots.construct_vtx_array(;         # 최종 위치 배열 생성
        origin=SVector{3,Float64}(0.0, 0.0, max_cargo_height),  # 원점 높이를 화물 최대높이에 맞춤(쌓을 때 충돌 방지)
        obstacles=inflated_obstacles,                     # 장애물
        ranges=object_vtx_range,                          # 격자 범위(x,y,층)
        spacing=(1.0, 1.0, max_object_h)                  # 칸 간격(x,y는 1배수, z는 부품 최대높이만큼)
    )

    return vtxs                                           # 계산된 부품 배치 위치들을 반환
end
