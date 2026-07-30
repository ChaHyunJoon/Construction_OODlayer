
# ============================================================================
#  이 파일은 데모의 "진입점(entry point)" — 레고 모델 하나를 끝까지 조립하는 전 과정을 한 함수로 실행.
#  파이프라인: LDraw 도면 파싱 → 모델 사양(spec) → SceneTree → 근사 형상 → 운반 유닛 →
#              적치(staging) 계획 → 작업 배정(greedy/MILP) → 시뮬레이션 루프 → MeshCat 3D 애니메이션.
#  RESPEC(LLM 재명세)·OOD(이상상황)·battery 등 확장은 여기에 hook 형태로 끼워 넣음.
#  Julia 문법 참고:
#   · function f(; a=1, b=2) : 맨 앞 세미콜론(;) 뒤는 전부 "키워드 인자"(이름 지정 호출).
#   · `name::Type=기본값` : 타입 표기 + 기본값(파이썬 name: Type = 기본값).
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
#   · `:이름` = Symbol(가벼운 상수 이름표), `@매크로` = 코드를 변형하는 매크로 호출.
#   · `do ... end` = 마지막 인자로 함수를 넘기는 문법(파이썬 with 와 비슷한 느낌).
#   · 같은 이름 함수를 인자 타입만 바꿔 여러 번 정의 = 다중 디스패치(파이썬엔 없는 개념).
# ============================================================================

# _CaptureLogger : 로그를 그대로 흘려보내면서(inner) 동시에 pat 에 맞는 메시지를 sink 에 담아두는 로거.
#   RESPEC(NL→DSL→복구) 로그를 저장된 데모 HTML 에 끼워넣기 위해 씀(run_lego_demo 가 전역 로거를 직접
#   바꾸므로, 외부에서 캡처하려면 이렇게 감싸는 로거를 거쳐야 함). <: = "AbstractLogger 의 하위 타입".
# A logger that forwards every message to `inner` AND captures messages matching `pat`
# into `sink`. Used to embed the RESPEC NL->DSL->recovery log into a saved demo HTML
# (run_lego_demo sets the global logger itself, so external capture must go through here).
# LDrawParser 0.1.x resolves every previously unseen part by recursively walking
# the complete part library. A real MPD references many distinct parts, so that
# behaviour turns one model load into many identical directory scans. Prime its
# path cache once per library root. Parsed models and geometry are unchanged.
const _LDRAW_INDEXED_LIBRARIES = Set{String}()
const _LDRAW_INDEX_LOCK = ReentrantLock()

function _prime_ldraw_part_index!(model_file=nothing)
    library = abspath(LDrawParser.get_part_library_dir())
    lock(_LDRAW_INDEX_LOCK) do
        cache = LDrawParser.get_file_path_cache()
        if !(library in _LDRAW_INDEXED_LIBRARIES) && isdir(library)
            for (root, _, files) in walkdir(library)
                for file in files
                    path = joinpath(root, file)
                    # Keep the first match, like find_part_file's traversal order.
                    get!(cache, file, path)
                    get!(cache, lowercase(file), path)
                    cache[path] = path
                end
            end
            push!(_LDRAW_INDEXED_LIBRARIES, library)
        end
        # `0 FILE`/`0 NAME` entries are MPD-local submodels, not library
        # parts. Seed them as self-resolving names so LDrawParser does not
        # scan the entire library merely to discover that they are local.
        if model_file !== nothing && isfile(model_file)
            path = abspath(String(model_file))
            cache[path] = path
            cache[basename(path)] = path
            for line in eachline(path)
                fields = split(strip(line))
                length(fields) >= 3 || continue
                fields[1] == "0" || continue
                uppercase(fields[2]) in ("FILE", "NAME") || continue
                local_name = join(fields[3:end], " ")
                cache[local_name] = local_name
                cache[lowercase(local_name)] = local_name
            end
        end
    end
    return library
end

struct _CaptureLogger <: Logging.AbstractLogger
    inner::Logging.AbstractLogger
    sink::Vector{String}
    pat::Regex
end
# 아래 세 줄은 로거가 갖춰야 하는 표준 인터페이스 메서드 — 판단을 그냥 안쪽 로거(inner)에 위임(전달).
#   Logging.함수(...) 로 표준 라이브러리 함수에 "이 타입일 때의 동작"을 추가 정의(다중 디스패치).
Logging.min_enabled_level(l::_CaptureLogger) = Logging.min_enabled_level(l.inner)  # 출력할 최소 로그 레벨
Logging.shouldlog(l::_CaptureLogger, args...) = Logging.shouldlog(l.inner, args...)  # 이 메시지를 남길지 여부
Logging.catch_exceptions(l::_CaptureLogger) = Logging.catch_exceptions(l.inner)  # 로깅 중 예외를 삼킬지 여부
# 실제 메시지를 처리하는 곳 — pat 에 맞으면 sink 에 담고(캡처), 원래대로 inner 로도 넘겨 콘솔에 찍음.
function Logging.handle_message(l::_CaptureLogger, level, message, _mod, group, id, file, line; kwargs...)
    s = string(message)
    occursin(l.pat, s) && push!(l.sink, s)
    Logging.handle_message(l.inner, level, message, _mod, group, id, file, line; kwargs...)
end

"""
    run_lego_demo(; kwargs...)

Run the lego demo.

Keyword arguments:

- `ldraw_file::String`: ldraw file
- `project_name::String`: project name (default: ldraw_file)
- `model_scale::Float64`: scale of the model (default: 0.008)
- `num_robots::Int`: number of robots to use (default: 12)
- `robot_scale::Float64`: scale of the robots (default: 0.7 * model_scale)
- `robot_height::Float64`: height of the robots (default: 10 * robot_scale)
- `robot_radius::Float64`: radius of the robots (default: 25 * robot_scale)
- `num_object_layers::Int`: number of layers to stack the legos (default: 1)
- `max_steps::Int`: maximum number of steps to run the simulation (default: 100000)
- `staging_buffer_factor::Float64`: factor to multiply the largest transport unit radius by to get the staging buffer (default: 1.2)
- `build_step_buffer_factor::Float64`: factor to multiply the robot radius by to get the build step buffer (default: 0.5)
- `base_results_path::String`: base path to save results to
- `results_path::String`: folder name to save the results to (inside base_results_path)
- `assignment_mode::Symbol`: assignment mode to use (default: :greedy, options: :greedy, :milp, :milp_w_greedy_warm_start)
- `open_animation_at_end::Bool`: open the animation in the browser at the end of the simulation (default: false)
- `save_animation::Bool`: save the animation at the end of the simulation (default: false)
- `save_animation_along_the_way::Bool`: save the animation at periodic intervals during the simulation (default: false)
- `anim_active_agents::Bool`: animate which agents are active (green circles) (default: false)
- `anim_active_areas::Bool`: animate which areas are active (purple circles) (default: false)
- `process_updates_interval::Int`: the interval to process animation updates (default: 25)
- `block_save_anim::Bool`: whether to save the animation in blocks instead of incrementally. false = incrementall, true = save in blocks (default: false)
- `update_anim_at_every_step::Bool`: whether to update the animation at every step (default: false)
- `save_anim_interval::Int`: the interval of number of updates to save the animation if `save_animation_along_the_way=true` (default: 500)
- `rvo_flag::Bool`: whether to use RVO (default: true)
- `tangent_bug_flag::Bool`: whether to use tangent bug (default: true)
- `dispersion_flag::Bool`: whether to use dispersion (default: true)
- `overwrite_results::Bool`: whether to overwrite the stats.toml file or create a new one with a date-time filename (default: true)
- `write_results::Bool`: whether to write the results to disk (default: true)
- `max_num_iters_no_progress::Int`: maximum number of iterations to run without progress (default: 10000)
- `sim_batch_size::Int`: number of steps to run in a simulation before clearing some memory (default: 50)
- `log_level::Logging.LogLevel`: log level to use (default: Logging.Warn)
- `milp_optimizer::Symbol`: optimizer to use for the MILP (default: :highs, options: :gurobi, :glpk)
- `milp_optimizer_attribute_dict::Dict`: dictionary of attributes to set on the optimizer (default: Dict())
- `optimizer_time_limit::Int`: time limit for the optimizer (default: 600)
- `look_for_previous_milp_solution::Bool`: whether to look for a previous MILP solution (default: false)
- `save_milp_solution::Bool`: whether to save the MILP solution (default: false)
- `previous_found_optimizer_time::Int`: time limit for the optimizer when looking for a previous solution (default: 30)
- `stop_after_task_assignment::Bool`: whether to stop after task assignment (default: false)
- `ignore_rot_matrix_warning::Bool`: whether to ignore the rotation matrix warning (default: true)
- `rng::Random.AbstractRNG`: random number generator to use (default: MersenneTwister(1))
"""
# 이 함수가 데모의 "진입점". 레고 모델을 불러와 → 스케줄을 만들고 → 로봇에 작업을 배정하고
# → 시뮬레이션 루프를 돌리고 → 3D 애니메이션으로 렌더링하는 전체 파이프라인을 한 번에 실행함.
#
# function f(; ...) 처럼 인자목록 맨 앞이 세미콜론(;)이면, 그 뒤는 전부 "키워드 인자"(이름을 적어 호출).
#   파이썬의 def f(*, a=1, b=2) 처럼 위치가 아니라 이름으로 넘기는 인자라는 뜻.
# 각 인자의 `name::Type=기본값` 은 "타입 표기 + 기본값"으로, 파이썬의 name: Type = 기본값 과 같음.
function run_lego_demo(;
    ldraw_file::String="tractor.mpd",                # 입력 LDraw(레고 도면) 파일 이름
    project_name::String=ldraw_file,                 # 프로젝트 이름(기본은 파일 이름과 동일)
    model_scale::Float64=0.008,                      # 모델 전체 크기 배율(작게 줄여서 시뮬레이션)
    num_robots::Int=12,                              # 사용할 로봇 대수
    robot_scale::Float64=model_scale * 0.7,          # 로봇 크기 배율(모델 배율에 비례)
    robot_height::Float64=10 * robot_scale,          # 로봇 높이
    robot_radius::Float64=25 * robot_scale,          # 로봇 반지름(충돌·간격 계산의 기준)
    num_object_layers::Int=1,                        # 부품을 바닥에 몇 층으로 쌓아 배치할지
    max_steps::Int=100000,                           # 시뮬레이션 최대 스텝 수(무한루프 방지)
    staging_buffer_factor::Float64=1.2,              # 적치(staging) 영역 여유 반경 배수
    build_step_buffer_factor::Float64=0.5,           # 조립 단계 영역 여유 반경 배수
    base_results_path::String=joinpath(dirname(pathof(ConstructionBots)), "..", "results"),  # 결과 저장 최상위 폴더
    results_path::String=joinpath(base_results_path, project_name),  # 이 프로젝트 결과 저장 폴더
    assignment_mode::Symbol=:greedy,                 # 작업 배정 방식(:greedy=탐욕, :milp=정수계획)  ※ :이름 은 Symbol(가벼운 상수 문자열)
    open_animation_at_end::Bool=false,               # 끝나면 브라우저로 애니메이션 열기
    save_animation::Bool=false,                      # 애니메이션 파일로 저장
    save_animation_along_the_way::Bool=false,        # 진행 중에 주기적으로 애니메이션 저장
    anim_active_agents::Bool=false,                  # 활성 로봇을 초록 원으로 표시
    anim_active_areas::Bool=false,                   # 활성 영역을 보라 원으로 표시
    process_updates_interval::Int=50,                # 애니메이션 갱신을 처리하는 간격(스텝)
    block_save_anim::Bool=false,                     # 애니메이션을 블록 단위로 저장할지(false=점진적)
    update_anim_at_every_step::Bool=false,           # 매 스텝마다 애니메이션 갱신할지
    grid_scale::Float64=1.0,                          # MeshCat 기본 바닥 격자(/Grid) 확대 배율(1.0=그대로; 시각용, 물리 의미 없음)
    anim_fps::Int=parse(Int, get(ENV, "ANIM_FPS", "30")),  # MeshCat 애니메이션 재생 프레임레이트. 프레임(=시뮬 스텝)당 벽시계 시간=1/anim_fps. 값이 클수록 record/재생이 빠름(같은 키프레임을 더 짧은 시간에 재생). 기본 30, 예: 240이면 8배 빠르게.
    log_sink::Union{Nothing,Vector{String}}=nothing,  # 주면 RESPEC/DEMO/WHOLE-BUILD 등 @info 라인을 여기로 캡처(HTML 임베드용)
    save_anim_interval::Int=500,                     # 진행 중 저장 시 저장 간격
    rvo_flag::Bool=true,                             # RVO(상호 충돌회피) 사용 여부
    tangent_bug_flag::Bool=true,                     # TangentBug(장애물 우회) 항법 사용 여부
    dispersion_flag::Bool=true,                      # dispersion(서로 흩어지기) 사용 여부
    overwrite_results::Bool=false,                   # 결과 파일을 덮어쓸지(false면 날짜시간 붙여 새 파일)
    write_results::Bool=true,                        # 결과를 디스크에 쓸지
    max_num_iters_no_progress::Int=10000,            # 진전 없이 돌 수 있는 최대 반복 횟수(교착 감지)
    sim_batch_size::Int=50,                          # 메모리 정리 전 한 번에 돌리는 스텝 수
    log_level::Logging.LogLevel=Logging.Warn,        # 로그 출력 수준(기본은 경고 이상만)
    milp_optimizer::Symbol=:highs,                   # MILP에 쓸 솔버(:highs/:gurobi/:glpk)
    milp_optimizer_attribute_dict::Dict=Dict(),      # 솔버에 추가로 설정할 속성들(빈 딕셔너리가 기본)
    optimizer_time_limit::Int=600,                   # 솔버 시간 제한(초)
    look_for_previous_milp_solution::Bool=false,     # 이전에 저장한 MILP 해를 찾아 재사용할지
    save_milp_solution::Bool=false,                  # MILP 해를 파일로 저장할지
    previous_found_optimizer_time::Int=30,           # 이전 해를 찾았을 때 줄 시간 제한(초)
    stop_after_task_assignment::Bool=false,          # 작업 배정까지만 하고 멈출지
    return_env_before_sim::Bool=false, # RESPEC: return the fully-built PlannerEnv just before simulation (for verify-gate tests)  # 시뮬레이션 직전 완성된 env를 반환(검증 테스트용)
    pre_sim_hook=nothing,             # RESPEC/WM: `pre_sim_hook(env)` fires once, AFTER the env is fully built and BEFORE the sim loop. Lets a caller enable_battery!/schedule OODs inside the production run_one path (default nothing = inert).
    n_spare_per_pool::Int=0,           # OOD 1-1: 4방위(N/E/S/W) 예비 로봇 풀에 둘 로봇 수(0이면 비활성). 잉여라 배정 안 받고 idle 대기.
    ignore_rot_matrix_warning::Bool=true,            # 회전행렬 관련 경고를 무시할지
    rng::Random.AbstractRNG=Random.MersenneTwister(1)  # 난수 생성기(시드 고정으로 재현 가능)
)

    # 셋 중 하나라도 true 면 애니메이션 관련 작업을 처리해야 함. ||=OR, &&=AND, !=NOT (파이썬 or/and/not)
    process_animation_tasks = save_animation || save_animation_along_the_way || open_animation_at_end

    if rvo_flag && !dispersion_flag                  # RVO는 켜고 dispersion은 끈 경우
        @warn "RVO is enabled but dispersion is disabled. This is not recommended."  # @warn: 경고 로그 출력 매크로
    end

    if block_save_anim                               # 블록 단위 저장 모드일 때 설정값 점검
        if process_updates_interval != save_anim_interval  # != 는 "같지 않다"
            @warn "When block_save_anim is true, it is recommended to set save_anim_interval to the same value as process_updates_interval."
        end
        if !save_animation_along_the_way             # 블록저장인데 진행중 저장이 꺼져 있으면
            @warn "block_save_anim is true but save_animation_along_the_way is false. Will save along the way anyway."
        end
    end

    # record statistics
    # Dict() : 빈 딕셔너리 생성(파이썬 {} 와 같음). 실행 통계를 모아둘 곳.
    stats = Dict()
    stats[:rng] = "$rng"                             # "$변수" 는 문자열 보간(파이썬 f"{변수}"와 동일)
    stats[:modelscale] = model_scale                 # 키로 Symbol(:rng 등)을 사용 — 가벼운 상수 키
    stats[:robotscale] = robot_scale
    stats[:assignment_mode] = string(assignment_mode)  # string(): 값을 문자열로 변환
    stats[:rvo_flag] = rvo_flag
    stats[:tangent_bug_flag] = tangent_bug_flag
    stats[:dispersion_flag] = dispersion_flag
    stats[:OptimizerTimeLimit] = optimizer_time_limit

    if assignment_mode == :milp                      # MILP 모드면 어떤 솔버 썼는지 기록
        stats[:Optimizer] = string(milp_optimizer)
    end

    if save_animation_along_the_way                  # 진행중 저장을 켜면 최종 저장도 자동으로 켬
        save_animation = true
    end

    visualizer = nothing                             # nothing: 값 없음(파이썬 None). 일단 비워둠
    if process_animation_tasks                       # 애니메이션이 필요할 때만 시각화 창 생성
        visualizer = MeshCat.Visualizer()            # MeshCat 3D 뷰어(웹브라우저 기반) 생성
    end

    mkpath(results_path)                             # 결과 폴더 생성(중간 경로까지 전부, 이미 있으면 무시)
    filename = joinpath(dirname(pathof(ConstructionBots)), "..", "LDraw_files", ldraw_file)  # 입력 파일 절대경로 조립
    @assert ispath(filename) "File $(filename) does not exist."  # @assert: 조건이 거짓이면 메시지와 함께 중단

    # 전역 로거 설정. log_sink 가 주어지면 콘솔 출력은 그대로 + RESPEC 파이프라인 라인을 sink 로 캡처.
    _prime_ldraw_part_index!(filename)
    _base_logger = ConsoleLogger(stderr, log_level)
    global_logger(log_sink === nothing ? _base_logger :
        _CaptureLogger(_base_logger, log_sink, r"\[(RESPEC|DEMO|MOCK-LLM|RESTAGE-ALL|WHOLE-BUILD)\]"))

    # Adding additional attributes for GLPK, HiGHS, and Gurobi
    # 솔버별로 시간제한 옵션의 "키 이름"이 달라서, 그 이름을 담아둘 변수(아직 미정이라 nothing)
    time_limit_key = nothing
    if assignment_mode == :milp || assignment_mode == :milp_w_greedy_warm_start  # MILP를 쓰는 두 모드일 때만
        milp_optimizer_attribute_dict[MOI.Silent()] = false  # 솔버 로그를 보이게(Silent=false)
        default_milp_optimizer = nothing                 # 어떤 솔버 생성자를 쓸지 담을 변수
        if milp_optimizer == :glpk                       # ── GLPK 선택 시 ──
            # () -> ... : 인자 없는 익명함수(파이썬 lambda: ...). 솔버를 "필요할 때 만드는" 공장 함수.
            default_milp_optimizer = () -> GLPK.Optimizer(; want_infeasibility_certificates=false)
            milp_optimizer_attribute_dict["tm_lim"] = optimizer_time_limit * 1000  # GLPK는 ms 단위라 ×1000
            milp_optimizer_attribute_dict["msg_lev"] = GLPK.GLP_MSG_ALL  # 메시지 수준: 모두 출력
            time_limit_key = "tm_lim"                    # GLPK의 시간제한 키 이름
        elseif milp_optimizer == :gurobi                 # ── Gurobi 선택 시 ──
            default_milp_optimizer = () -> Gurobi.Optimizer()
            # default_milp_optimizer = Gurobi.Optimizer
            milp_optimizer_attribute_dict["TimeLimit"] = optimizer_time_limit  # Gurobi는 초 단위
            # MIPFocus: 1 -- feasible solutions, 2 -- optimal solutions, 3 -- bound
            milp_optimizer_attribute_dict["MIPFocus"] = 1  # 1=가능한 해를 빨리 찾는 쪽에 집중
            time_limit_key = "TimeLimit"
        elseif milp_optimizer == :highs                  # ── HiGHS 선택 시 ──
            default_milp_optimizer = () -> HiGHS.Optimizer()
            milp_optimizer_attribute_dict["time_limit"] = Float64(optimizer_time_limit)  # Float64(): 실수로 변환
            milp_optimizer_attribute_dict["presolve"] = "on"  # 사전 정리(presolve) 켜기
            time_limit_key = "time_limit"
        else
            @warn "No additional parameters for $milp_optimizer were set."  # 알 수 없는 솔버면 경고만
        end
        set_default_milp_optimizer!(default_milp_optimizer)        # 기본 MILP 솔버 등록(!=상태를 바꾸는 함수)
        clear_default_milp_optimizer_attributes!()                 # 기존 솔버 속성 초기화
        set_default_milp_optimizer_attributes!(milp_optimizer_attribute_dict)  # 위에서 만든 속성들 적용
    end

    # 아래는 사용한 설정에 따라 결과 폴더 이름(prefix)을 짓는 부분. 옵션마다 문자열을 이어 붙임.
    if rvo_flag
        prefix = "RVO"
    else
        prefix = "no-RVO"
    end
    if dispersion_flag
        prefix = string(prefix, "_Dispersion")       # string(a, b, ...): 여러 값을 이어붙여 한 문자열로
    else
        prefix = string(prefix, "_no-Dispersion")
    end
    if tangent_bug_flag
        prefix = string(prefix, "_TangentBug")
    else
        prefix = string(prefix, "_no-TangentBug")
    end
    soln_str_pre = ""                                # 해(solution) 파일 이름 앞에 붙일 접두사
    if assignment_mode == :milp
        soln_str_pre = "milp_"
        prefix = string(soln_str_pre, prefix)
    elseif assignment_mode == :greedy
        soln_str_pre = "greedy_"
        prefix = string(soln_str_pre, prefix)
    elseif assignment_mode == :milp_w_greedy_warm_start
        soln_str_pre = "milp-ws_"
        prefix = string(soln_str_pre, prefix)
    else
        error("Unknown assignment mode: $(assignment_mode)")  # error(): 예외 발생시켜 중단(파이썬 raise)
    end
    mkpath(joinpath(results_path, prefix))           # prefix 하위 폴더까지 생성

    name_augment = ""                                # 파일 이름 앞에 붙일 추가 문자열(기본은 없음)
    if !overwrite_results                            # 덮어쓰지 않을 거면 타임스탬프를 붙여 고유 이름으로
        name_augment = string(Dates.format(Dates.now(), "yyyymmdd_HHMMSS"), "_")  # 현재 시각을 형식문자열로
    end

    stats_file_name = string(name_augment, "stats", ".toml")        # 통계 파일 이름
    anim_file_name = string(name_augment, "visualization.html")     # 애니메이션 파일 이름
    anim_prog_file_name = string(name_augment, "visualization_")    # 진행중 저장용 이름 접두사

    stats_path = joinpath(results_path, prefix, stats_file_name)    # 통계 파일 전체 경로
    anim_path = joinpath(results_path, prefix, anim_file_name)      # 애니메이션 파일 전체 경로
    anim_prog_path = joinpath(results_path, prefix, anim_prog_file_name)  # 진행중 저장 경로 접두사


    # SimParameters(...) : 시뮬레이션 설정값들을 하나의 구조체로 묶음(아래 인자는 "위치 순서대로" 채워짐)
    sim_params = SimParameters(
        sim_batch_size,                  # 한 배치당 스텝 수
        max_steps,                       # 최대 스텝
        process_animation_tasks,         # 애니메이션 처리 여부
        save_anim_interval,              # 진행중 저장 간격
        process_updates_interval,        # 갱신 처리 간격
        block_save_anim,                 # 블록 단위 저장 여부
        update_anim_at_every_step,       # 매 스텝 갱신 여부
        anim_active_agents,              # 활성 로봇 표시
        anim_active_areas,               # 활성 영역 표시
        anim_prog_path,                  # 진행중 저장 경로
        save_animation_along_the_way,    # 진행중 저장 여부
        max_num_iters_no_progress        # 무진전 허용 한계
    )

    reset_all_id_counters!()             # 노드 ID 카운터 초기화(이전 실행 잔재 제거)
    reset_all_invalid_id_counters!()     # 임시(invalid) ID 카운터 초기화

    # 로봇의 기본 형상을 원기둥(Cylinder)으로 설정. Point(x,y,z) 두 개로 아래·위 중심, 마지막이 반지름.
    set_default_robot_geom!(
        Cylinder(Point(0.0, 0.0, 0.0), Point(0.0, 0.0, robot_height), robot_radius)
    )

    # 아래는 RVO/이동 속도 등 전역 기본값 설정. ConstructionBots. 접두사는 모듈명 명시(이름 충돌 방지).
    ConstructionBots.set_rvo_default_time_step!(1 / 40.0)                          # RVO 시뮬레이션 시간 간격(1/40초)
    ConstructionBots.set_default_loading_speed!(50 * default_robot_radius())       # 부품 싣기/내리기 기본 속도
    ConstructionBots.set_default_rotational_loading_speed!(50 * default_robot_radius())  # 회전 적재 기본 속도
    ConstructionBots.set_staging_buffer_radius!(default_robot_radius()) # for tangent_bug policy  # 적치 여유 반경(TangentBug용)

    ConstructionBots.set_rvo_default_neighbor_distance!(16 * default_robot_radius())     # RVO에서 이웃으로 볼 최대 거리
    ConstructionBots.set_rvo_default_min_neighbor_distance!(10 * default_robot_radius()) # 이웃으로 볼 최소 거리

    # Setting default optimizer for staging layout
    ConstructionBots.set_default_geom_optimizer!(ECOS.Optimizer)          # 적치 배치 계산용 기본 솔버(ECOS)
    ConstructionBots.set_default_geom_optimizer_attributes!(MOI.Silent() => true)  # => 는 "키 => 값" 쌍(여기선 솔버 조용히)


    # ── 파이프라인 1단계: LDraw 파일 읽어서 부품 기하 채우기 ──
    pre_execution_start_time = time()                # time(): 현재 시각(초). 소요시간 측정 시작
    model = parse_ldraw_file(filename; ignore_rotation_determinant=ignore_rot_matrix_warning)  # 레고 도면 파싱
    populate_part_geometry!(model; ignore_rotation_determinant=ignore_rot_matrix_warning)      # 각 부품의 실제 3D 형상 채우기
    LDrawParser.change_coordinate_system!(model, ldraw_base_transform(), model_scale; ignore_rotation_determinant=ignore_rot_matrix_warning)  # 좌표계 변환 + 모델 배율 적용

    ## CONSTRUCT MODEL SPEC
    # ── 2단계: 모델 사양(어떤 부품이 어떻게 조립되는지의 명세) 구성 ──
    print("Constructing model spec...")
    spec = ConstructionBots.construct_model_spec(model)          # 모델로부터 사양 그래프 생성
    model_spec = ConstructionBots.extract_single_model(spec)     # 그중 단일 모델만 추출
    id_map = ConstructionBots.build_id_map(model, model_spec)    # 도면 ID ↔ 내부 노드 ID 매핑표
    color_map = ConstructionBots.construct_color_map(model_spec, id_map)  # 부품별 색상 매핑표
    @assert validate_graph(model_spec)               # 사양 그래프가 유효한지 검증(아니면 중단)
    print("done!\n")

    ## CONSTRUCT SceneTree
    # ── 3단계: SceneTree(부품·조립체의 위치/계층 관계를 담은 트리) 구성 ──
    print("Constructing scene tree...")
    assembly_tree = ConstructionBots.construct_assembly_tree(model, model_spec, id_map)  # 조립 트리 생성
    scene_tree = ConstructionBots.convert_to_scene_tree(assembly_tree)  # 시뮬레이션용 SceneTree로 변환
    print("done!\n")

    # Compute Approximate Geometry
    # ── 4단계: 근사 형상 계산(충돌검사를 빠르게 하기 위한 감싸는 도형) ──
    print("Computing approximate geometry...")
    start_geom_approx = time()
    compute_approximate_geometries!(scene_tree, HypersphereKey())     # 각 노드를 감싸는 구(sphere) 계산
    compute_approximate_geometries!(scene_tree, HyperrectangleKey())  # 각 노드를 감싸는 직육면체 계산
    GEOM_APPROX_TIME = time() - start_geom_approx    # 소요 시간 기록
    print("done!\n")

    # Define TransportUnit configurations
    # ── 5단계: 운반 유닛 구성(여러 로봇이 큰 부품을 함께 드는 대형 결정) ──
    print("Configuring transport units...")
    config_transport_units_time = time()
    ConstructionBots.init_transport_units!(scene_tree; robot_radius=robot_radius)  # 운반 유닛 초기화
    config_transport_units_time = time() - config_transport_units_time
    print("done!\n")

    # validate SceneTree
    # ── SceneTree 유효성 검증 ──
    print("Validating scene tree...")
    # collect(...): 이터러블을 배열로 변환(파이썬 list()). [1] 은 첫 요소(줄리아는 인덱스가 1부터!)
    root = get_node(scene_tree, collect(get_all_root_nodes(scene_tree))[1])  # 루트 노드 하나 가져오기
    validate_tree(get_transform_node(root))          # 변환 트리 검증
    # v -> ... : 인자 하나(v)를 받는 익명함수. 각 정점 v에 대한 변환 노드를 돌려줌.
    validate_embedded_tree(scene_tree, v -> get_transform_node(get_node(scene_tree, v)))  # 내장 트리 검증
    print("done!\n")

    ## Add robots to scene tree
    # ── 6단계: 로봇들을 격자 위치에 배치 ──
    robot_spacing = 5 * robot_radius                 # 로봇 사이 간격
    robot_start_box_side = ceil(sqrt(num_robots)) * robot_spacing  # 로봇을 담을 정사각 시작구역 한 변(ceil=올림, sqrt=제곱근)
    #To fit N robots into a square grid, we need sqrt(N) robots per side,
    # ceil is to defend the shortage of space, and multiply by the spacing to get the side length of the square.
    # a:b:c 는 "a부터 c까지 b 간격" 범위(파이썬 range와 비슷하나 끝 c 포함). 여기선 시작구역 x/y 좌표들.
    xy_range = (-robot_start_box_side/2:robot_spacing:robot_start_box_side/2)
    vtxs = ConstructionBots.construct_vtx_array(; spacing=(1.0, 1.0, 0.0), ranges=(xy_range, xy_range, 0:0))
    # Generate candidate vertices for robots  # 로봇 후보 격자 위치 생성

    robot_vtxs = StatsBase.sample(rng, vtxs, num_robots; replace=false)  # 후보 중 로봇 수만큼 무작위 추출(중복 없이)

    ConstructionBots.add_robots_to_scene!(scene_tree, robot_vtxs, [default_robot_geom()])  # 그 위치들에 로봇 추가

    # OOD 1-1: 4방위 예비(spare) 로봇 풀 주입(요청 시). 빌드영역 바깥 N/E/S/W 클러스터에 배치 →
    # set_robot_start_configs! 가 RobotStart/RobotGo(free) 를 자동 생성, rvo_add_agents! 가 RVO 에이전트로 등록.
    # 작업 수보다 로봇이 많아지므로(잉여) greedy 배정이 이들을 안 쓰고 idle 로 남김 → replace_robot! 의 인계 대상.
    if n_spare_per_pool > 0
        ConstructionBots.clear_spare_pools!()        # 이전 빌드의 풀 기록 초기화(전역 Ref)
        ConstructionBots.add_directional_spare_pools!(scene_tree;
            n_spare=n_spare_per_pool,
            margin=ConstructionBots.SPARE_POOL_MARGIN_FACTOR[]*robot_radius,   # env/demo-tunable depot distance
            spacing=3*robot_radius)
        @info "[OOD-1-1] injected $(4*n_spare_per_pool) spare robots ($(n_spare_per_pool)/pool x 4 dirs); pools=$(keys(ConstructionBots.spare_pools()))"
    end

    ## Recompute approximate geometry for when the robot is transporting it
    # Add temporary robots to the transport units and recalculate the bounding geometry
    # then remove them after the new geometries are calcualted
    # 로봇이 부품을 들었을 때의 크기를 반영하려고, 임시 로봇을 붙여 형상을 다시 계산한 뒤 떼어냄.
    ConstructionBots.add_temporary_invalid_robots!(scene_tree; with_edges=true)  # 임시 로봇을 운반유닛에 부착
    compute_approximate_geometries!(scene_tree, HypersphereKey())                # 구 형상 재계산
    # all(map(f, xs)): 모든 노드가 조건을 만족하는지. map=각 원소에 함수 적용(파이썬 map), all=전부 참인가.
    # node.geom_hierarchy : 점(.) 으로 구조체 필드 접근(파이썬과 동일).
    @assert all(map(node -> has_vertex(node.geom_hierarchy, HypersphereKey()), get_nodes(scene_tree)))  # 모두 구 형상 보유 확인
    compute_approximate_geometries!(scene_tree, HyperrectangleKey())             # 직육면체 형상 재계산
    @assert all(map(node -> has_vertex(node.geom_hierarchy, HyperrectangleKey()), get_nodes(scene_tree)))  # 모두 직육면체 보유 확인
    ConstructionBots.remove_temporary_invalid_robots!(scene_tree)                # 임시 로봇 제거

    ## Construct Partial Schedule (without robots assigned)
    # ── 7단계: 부분 스케줄 구성(아직 로봇 배정 전, 조립 작업의 순서만) ──
    print("Constructing partial schedule...")
    jump_to_final_configuration!(scene_tree; set_edges=true)  # 모든 부품을 완성 위치로 점프(기준 형태 확보)
    sched = construct_partial_construction_schedule(model, model_spec, scene_tree, id_map)  # 조립 작업 순서 그래프 생성
    @assert validate_schedule_transform_tree(sched)  # 스케줄의 변환 트리 검증
    print("done!\n")

    ## Generate staging plan
    # ── 8단계: 적치(staging) 계획 생성 — 각 조립 단계에서 부품을 어디에 모아둘지 ──
    print("Generating staging plan...")
    max_object_transport_unit_radius = ConstructionBots.get_max_object_transport_unit_radius(scene_tree)  # 가장 큰 운반유닛 반경
    staging_plan_time = time()
    # 함수가 값을 두 개 돌려주면 a, b = f(...) 로 한 번에 받음(파이썬 튜플 언패킹).
    staging_circles, bounding_circles = ConstructionBots.generate_staging_plan!(scene_tree, sched;
        buffer_radius=staging_buffer_factor * max_object_transport_unit_radius,   # 적치 영역 여유 반경
        build_step_buffer_radius=build_step_buffer_factor * default_robot_radius()  # 조립 단계 여유 반경
    )
    staging_plan_time = time() - staging_plan_time
    print("done!\n")

    # record statistics
    # [식 for x in xs if 조건] : 리스트 컴프리헨션(파이썬과 동일). length()=개수(파이썬 len).
    # matches_template(타입, n): 노드 n이 그 타입에 해당하는지 판별.
    stats[:numobjects] = length([node_id(n) for n in get_nodes(scene_tree) if matches_template(ObjectNode, n)])      # 단일 부품 수
    stats[:numassemblies] = length([node_id(n) for n in get_nodes(scene_tree) if matches_template(AssemblyNode, n)]) # 조립체 수
    stats[:numrobots] = length([node_id(n) for n in get_nodes(scene_tree) if matches_template(RobotNode, n)])        # 로봇 수
    stats[:ConfigTransportUnitsTime] = config_transport_units_time   # 운반유닛 구성 소요시간
    stats[:StagingPlanTime] = staging_plan_time      # 적치 계획 소요시간
    if write_results                                 # 결과를 쓰기로 했으면 TOML 파일로 저장
        # open(경로, "w") do io ... end : 파일을 열고 블록이 끝나면 자동으로 닫음(파이썬 with open as io 와 동일).
        open(stats_path, "w") do io
            TOML.print(io, stats)                    # 딕셔너리를 TOML 형식으로 기록
        end
    end

    # Move objects to the starting locations. Keep expanding a square from the origin until
    # all objects are placed while not putting objects in building locations.
    # ── 9단계: 부품들을 시작 위치(바닥 격자)에 배치. 조립 위치는 피하면서 원점에서 정사각형을 넓혀감. ──
    print("Placing objects at starting locations ...")
    # Max height of cargo (excluding the final assembly)
    # maximum(map(...)): 변환한 값들 중 최댓값. filter(조건, xs): 조건 통과한 것만 남김(파이썬 filter).
    # .radius[3] : z방향 반경. *2 로 지름(=높이). 최종 조립체(AssemblyID(1))는 제외.
    max_cargo_height = maximum(map(n -> get_base_geom(n, HyperrectangleKey()).radius[3] * 2,
        filter(n -> (matches_template(TransportUnitNode, n) && cargo_id(n) != AssemblyID(1)),
            get_nodes(scene_tree))))
    other_circles = get_buildstep_circles(sched)     # 조립 단계별 점유 원(빈 공간 판단용)
    # values(dict): 딕셔너리 값들. remove_redundant: 너무 가까운(ϵ 이내) 원들을 정리. ϵ은 그리스문자 epsilon(허용오차)
    build_circles = remove_redundant(collect(values(other_circles)); ϵ=robot_radius)
    object_vtxs = get_object_vtx(scene_tree, build_circles, max_cargo_height,
        num_object_layers, 2 * robot_radius)         # 부품을 놓을 빈 격자 위치들 계산
    # println: 출력 후 줄바꿈. [DIAG]는 디버그 진단 로그. flush(stdout): 출력 버퍼를 즉시 비워 바로 보이게 함.
    println("[DIAG] place_objects: get_object_vtx returned $(length(object_vtxs)) vtxs; calling select_initial_object_grid_locations!"); flush(stdout)
    ConstructionBots.select_initial_object_grid_locations!(sched, object_vtxs)  # 각 부품을 그 격자 위치에 배정
    println("[DIAG] place_objects: select_initial_object_grid_locations! done; raising assemblies"); flush(stdout)

    # Move assemblies up so they float above the robots
    # 조립체(중간 결과물)를 위로 띄워 로봇들 위에 떠 있게 함(서로 안 부딪히게).
    _diag_asm = 0                                    # 진단용 카운터(처리한 조립체 수)
    for node in get_nodes(scene_tree)                # 모든 노드를 순회(파이썬 for ... in ...)
        if matches_template(AssemblyNode, node)      # 조립체 노드만 처리
            _diag_asm += 1
            # summary(x): 객체를 짧게 요약한 문자열. $(...) 안에 식을 넣어 보간.
            println("[DIAG] place_objects: raising assembly #$(_diag_asm) ($(summary(node_id(node)))) - get_node"); flush(stdout)
            start_node = get_node(sched, AssemblyComplete(node))  # 이 조립체의 "완성" 스케줄 노드 찾기
            # raise start
            println("[DIAG] place_objects:   -> global_transform(start_config)"); flush(stdout)
            current = global_transform(start_config(start_node))  # 현재 전역 변환(위치+회전)
            println("[DIAG] place_objects:   -> get_base_geom / compute dh"); flush(stdout)
            rect = current(get_base_geom(node, HyperrectangleKey()))  # 현재 변환을 적용한 감싸는 직육면체
            dh = max_cargo_height - (rect.center.-rect.radius)[3]     # 띄울 높이차. .-는 원소별 뺄셈(브로드캐스트), [3]=z성분
            println("[DIAG] place_objects:   -> set_desired_global_transform_without_affecting_children!"); flush(stdout)
            # 자식(하위 부품)에는 영향 안 주고 이 조립체만 목표 위치로 옮김.
            # ∘ 는 변환 "합성"(파이썬 함수합성 같은 것). Translation(이동) ∘ LinearMap(회전) = 회전 후 이동.
            # ...는 "스플랫" — 배열/튜플을 풀어서 개별 인자로 전달(파이썬 *args).
            set_desired_global_transform_without_affecting_children!(
                start_config(start_node),
                CoordinateTransformations.Translation(current.translation[1:2]..., dh) ∘ CoordinateTransformations.LinearMap(current.linear)
            )
            println("[DIAG] place_objects:   -> assembly #$(_diag_asm) done"); flush(stdout)
        end
    end
    println("[DIAG] place_objects: raised $(_diag_asm) assemblies; calibrate_transport_tasks!"); flush(stdout)
    # Make sure all transforms line up
    ConstructionBots.calibrate_transport_tasks!(sched)  # 운반 작업들의 변환을 서로 일관되게 보정
    println("[DIAG] place_objects: calibrate_transport_tasks! done; validate_schedule_transform_tree"); flush(stdout)
    @assert validate_schedule_transform_tree(sched; post_staging=true)  # 적치 후 상태로 스케줄 검증
    println("[DIAG] place_objects: validate done"); flush(stdout)
    print("done!\n")

    # Task Assignments
    # ── 10단계: 작업 배정 — 어느 로봇이 어느 작업을 맡을지 결정 ──
    print("Assigning robots...")
    ConstructionBots.add_dummy_robot_go_nodes!(sched)  # 로봇 이동용 더미 노드 추가(배정 그래프 형태 맞춤)
    @assert validate_schedule_transform_tree(sched; post_staging=true)

    # Convert to OperatingSchedule
    ConstructionBots.set_default_loading_speed!(50 * default_robot_radius())              # 적재 속도 재설정
    ConstructionBots.set_default_rotational_loading_speed!(50 * default_robot_radius())   # 회전 적재 속도 재설정

    tg_sched = ConstructionBots.convert_to_operating_schedule(sched)  # 실행용 OperatingSchedule 로 변환

    assignment_time = time()                         # 배정 소요시간 측정 시작
    ## MILP solver

    # "$(식)" : 식을 평가해 문자열로 끼워넣음. .jld2는 줄리아 객체 저장 포맷(파이썬 pickle 비슷).
    solution_fname = joinpath(results_path, string(soln_str_pre, "$(num_robots).jld2"))            # 이전 해 저장 경로
    no_solution_fname = joinpath(results_path, string(soln_str_pre, "$(num_robots)_NO-SOLN.jld2")) # 해 없음 표시 파일 경로

    soln_matrix = nothing                            # 불러올 이전 해 행렬(없으면 nothing)
    if look_for_previous_milp_solution && (assignment_mode != :greedy)  # 이전 해 재사용 옵션 + greedy가 아닐 때
        if milp_optimizer == :glpk
            # """...""" : 여러 줄 문자열(파이썬 삼중따옴표와 동일).
            @warn """GLPK is not currently implemented through JuMP to support warm-starting.
                       Recommend using HiGHS (:highs) or Gurobi (:gurobi) when using previous solutions."""
        end
        if isfile(solution_fname)                    # 이전 해 파일이 있으면
            println("\n\tFound previous MILP solution at $solution_fname")  # \n=줄바꿈, \t=탭
            soln_matrix = JLD2.load(solution_fname, "soln_matrix")          # 파일에서 해 행렬 불러오기
            soln_matrix = SparseArrays.SparseMatrixCSC(soln_matrix)         # 희소행렬 형태로 변환
            milp_optimizer_attribute_dict[time_limit_key] = Float64(previous_found_optimizer_time)  # 이때는 짧은 시간제한
            clear_default_milp_optimizer_attributes!()                      # 속성 초기화 후
            set_default_milp_optimizer_attributes!(milp_optimizer_attribute_dict)  # 다시 적용
        elseif isfile(no_solution_fname)             # "해 없음" 파일이 있으면 바로 중단
            println("Aborting based on finding $no_solution_fname")
            throw(NoSolutionError())                 # throw: 예외 던지기(파이썬 raise)
        else
            println("\n\tNo previous MILP solution at $solution_fname")     # 둘 다 없으면 새로 풀어야 함
        end
    end

    valid_milp_solution = true                       # 유효한 해를 얻었는지 표시(기본 true)
    milp_model = SparseAdjacencyMILP()               # 작업배정 모델 객체 생성
    if assignment_mode == :milp                      # ── MILP(정수계획) 방식 ──
        if !isnothing(soln_matrix)                   # 이전 해가 있으면 그걸 출발점(warm start)으로
            milp_model = formulate_milp(milp_model, tg_sched, scene_tree; warm_start_soln=soln_matrix)
        else
            milp_model = formulate_milp(milp_model, tg_sched, scene_tree)  # 없으면 처음부터 정식화
        end
        optimize!(milp_model)                        # 최적화 실행(!=내부 상태 변경)

        if primal_status(milp_model) == MOI.NO_SOLUTION  # 해를 못 찾았으면
            valid_milp_solution = false
        end
    elseif assignment_mode == :greedy                # ── greedy(탐욕) 방식 — 빠르지만 최적은 아님 ──
        ## Greedy Assignment with enforced build-step ordering
        # 키워드 인자로 비용함수를 지정해 탐욕 배정기 생성(조립 단계 순서를 강제).
        milp_model = ConstructionBots.GreedyOrderedAssignment(
            greedy_cost=GreedyFinalTimeCost(),       # 최종 완료시간을 줄이는 방향의 비용
        )
        milp_model = formulate_milp(milp_model, tg_sched, scene_tree)  # 모델 정식화
        optimize!(milp_model)                        # 배정 실행
    elseif assignment_mode == :milp_w_greedy_warm_start  # ── greedy 해를 시작점으로 한 MILP ──
        if milp_optimizer == :glpk
            println()
            @warn """GLPK is not currently implemented through JuMP to support warm-starting.
                       Recommend using HiGHS (:highs) or Gurobi (:gurobi)."""
        end
        if !isnothing(soln_matrix)                   # 저장된 해가 있으면 그걸로 warm start
            milp_model = formulate_milp(milp_model, tg_sched, scene_tree; warm_start_soln=soln_matrix)
        else
            greedy_sched = deepcopy(tg_sched)        # deepcopy: 완전 복사(원본 보호, 파이썬 copy.deepcopy)
            greedy_model = ConstructionBots.GreedyOrderedAssignment(  # 먼저 greedy로 초기해 구하기
                greedy_cost=GreedyFinalTimeCost(),
            )
            greedy_model = formulate_milp(greedy_model, greedy_sched, scene_tree)
            optimize!(greedy_model)
            greedy_assignmnet_matrix = get_assignment_matrix(greedy_model)  # greedy 배정 결과 행렬

            milp_model = SparseAdjacencyMILP()       # 새 MILP 모델을
            milp_model = formulate_milp(milp_model, tg_sched, scene_tree; warm_start_soln=greedy_assignmnet_matrix)  # greedy 해를 시작점으로
        end
        optimize!(milp_model)
        if primal_status(milp_model) == MOI.NO_SOLUTION
            valid_milp_solution = false
        end
    else
        error("Unknown assignment mode: $assignment_mode")
    end

    post_assignment_makespan = Inf                   # Inf=무한대. 배정 후 예상 총 완료시간(makespan), 일단 무한대
    if valid_milp_solution                           # 유효한 배정 해를 얻었을 때만 후처리
        # typeof(x): x의 타입을 돌려줌. 실행용 스케줄을 원래 형태로 되돌려 검증.
        validate_schedule_transform_tree(
            ConstructionBots.convert_from_operating_schedule(typeof(sched), tg_sched)
            ; post_staging=true)
        update_project_schedule!(nothing, milp_model, tg_sched, scene_tree)  # 배정 결과를 스케줄에 반영
        @assert validate(tg_sched)                   # 스케줄 전체 유효성 검증

        # Assign robots to "home" locations so they don't sit around in each others' way
        # 작업을 다 마친 로봇이 길을 막지 않도록 "집(home)" 위치로 보냄.
        # 조건이 둘(RobotGo 이면서 종단 노드)일 때 && 로 결합.
        go_nodes = [n for n in get_nodes(tg_sched) if matches_template(RobotGo, n) && is_terminal_node(tg_sched, n)]
        # staging_circles[키]: 딕셔너리 인덱싱. AssemblyID(1)=최종 조립체. center.-radius=원의 최소 모서리. [1:2]=x,y만.
        min_assembly_1_xy = (staging_circles[AssemblyID(1)].center.-staging_circles[AssemblyID(1)].radius)[1:2]
        # enumerate(xs): (인덱스, 값) 쌍을 줌(파이썬과 동일하나 인덱스는 1부터). (ii, n) 으로 분해해 받음.
        for (ii, n) in enumerate(go_nodes)
            vtx_x = min_assembly_1_xy[1] - ii * 5 * robot_radius  # 로봇마다 x를 조금씩 옆으로 어긋나게(일렬 주차)
            vtx_y = min_assembly_1_xy[2]
            set_desired_global_transform!(goal_config(n),         # 이 로봇의 목표 위치 설정
                CoordinateTransformations.Translation(vtx_x, vtx_y, 0.0) ∘ identity_linear_map()  # 회전 없음(항등) + 평행이동
            )
        end
        post_assignment_makespan = makespan(tg_sched)  # 배정 후 예상 총 완료시간 계산
    end
    assignment_time = time() - assignment_time       # 배정 소요시간 확정
    print("done!\n")

    # If valid milp solution found, save if option was passed
    if valid_milp_solution && save_milp_solution && (assignment_mode != :greedy)  # 유효 해 + 저장옵션 + greedy 아님
        println("Saving MILP solution to $solution_fname")
        JLD2.save(solution_fname, "soln_matrix", get_assignment_matrix(milp_model))  # 배정 행렬을 파일로 저장
    elseif save_milp_solution && (assignment_mode != :greedy)  # 해는 없지만 저장옵션이면 "해 없음" 파일 남김
        println("Saving a no soltuion file to $no_solution_fname")
        JLD2.save(no_solution_fname, "soln_matrix", false)
    end

    # compile pre execution statistics
    pre_execution_time = time() - pre_execution_start_time  # 시뮬레이션 전까지의 전체 준비 시간

    stats[:AssigmentTime] = assignment_time          # 배정 시간 기록
    stats[:PreExecutionRuntime] = pre_execution_time # 준비 시간 기록
    stats[:OptimisticMakespan] = post_assignment_makespan  # 낙관적 예상 완료시간
    stats[:ValidMILPSolution] = valid_milp_solution  # 유효 해 여부
    if write_results
        open(stats_path, "w") do io
            TOML.print(io, stats)
        end
    end

    if !valid_milp_solution                          # 해가 없으면 예외 던지고 종료
        throw(NoSolutionError())
    elseif stop_after_task_assignment                # 배정까지만 하라는 옵션이면 여기서 반환
        return nothing, stats                        # 두 값을 동시에 반환(튜플)
    end

    # ── 11단계: 3D 시각화 준비(애니메이션을 만들 때만) ──
    factory_vis = ConstructionBots.FactoryVisualizer(vis=visualizer)  # 시각화 관리 객체 생성
    if !isnothing(visualizer)                        # 뷰어가 있을 때만
        delete!(visualizer)                          # 기존 장면 비우기

        # Visualize assembly
        factory_vis = ConstructionBots.populate_visualizer!(scene_tree, visualizer;  # 부품들을 뷰어에 채움
            color_map=color_map,                     # 부품별 색
            color=RGB(0.3, 0.3, 0.3),                # 기본 회색(RGB: 빨강·초록·파랑 0~1)
            material_type=MeshLambertMaterial        # 빛 반사 재질
        )
        ConstructionBots.add_indicator_nodes!(factory_vis)  # 상태 표시용 보조 마커 추가
        factory_vis.staging_nodes = ConstructionBots.render_staging_areas!(visualizer, scene_tree,  # 적치 영역 그리기
            sched, staging_circles;
            dz=0.00, color=RGBA(0.4, 0.0, 0.4, 0.5)) # RGBA: 마지막 A는 투명도(0.5=반투명 보라)
        # [(키 => 값), ...] 형태의 쌍 목록을 순회. 형상 레이어별 색을 지정.
        for (k, color) in [
            (HypersphereKey() => RGBA(0.0, 1.0, 0.0, 0.3)),    # 구 형상은 반투명 초록
            (HyperrectangleKey() => RGBA(1.0, 0.0, 0.0, 0.3))  # 직육면체는 반투명 빨강
        ]
            ConstructionBots.show_geometry_layer!(factory_vis, k; color=color)  # 해당 레이어 표시
        end
        for (k, nodes) in factory_vis.geom_nodes     # 모든 형상 노드를
            setvisible!(nodes, false)                # 일단 숨김
        end
        setvisible!(factory_vis.geom_nodes[BaseGeomKey()], true)  # 기본 형상만 보이게
        setvisible!(factory_vis.active_flags, false)             # 활성 표시 깃발은 숨김
        setvisible!(factory_vis.faulted_flags, false)            # 고장 표시(빨강)도 일단 숨김(고장 시 켜짐)
        setvisible!(factory_vis.dispatched_flags, false)         # 디스패치 표시(시안)도 숨김(교체 시 켜짐)
        set_scene_tree_to_initial_condition!(scene_tree, sched; remove_all_edges=true)  # 장면을 초기상태로
        ConstructionBots.update_visualizer!(factory_vis)         # 뷰어 갱신
        if grid_scale != 1.0                                     # MeshCat 기본 바닥 격자를 x,y 로 grid_scale 배 확대(셀 간격도 같이 커짐)
            settransform!(visualizer["/Grid"],
                CoordinateTransformations.LinearMap(
                    [grid_scale 0.0 0.0; 0.0 grid_scale 0.0; 0.0 0.0 1.0]))
        end
    end

    set_scene_tree_to_initial_condition!(scene_tree, sched; remove_all_edges=true)  # (뷰어 유무와 무관하게) 초기상태 설정


    # rvo
    if rvo_flag                                      # RVO를 쓰면 파이썬 RVO 모듈을 새로 초기화
        ConstructionBots.reset_rvo_python_module!()  # 파이썬 RVO 모듈 리셋(PyCall 통해 호출)
        ConstructionBots.rvo_set_new_sim!(ConstructionBots.rvo_new_sim())  # 새 RVO 시뮬레이터 인스턴스 설정
    end


    # n.id.id : 노드의 id 필드 안의 id 정수. maximum()=최댓값. 각종 ID의 최대값을 미리 구해둠.
    max_robot_go_id = maximum([n.id.id for n in get_nodes(tg_sched) if matches_template(RobotGo, n)])              # 로봇 이동 노드 최대 ID
    max_cargo_id = maximum([cargo_id(entity(n)).id for n in get_nodes(tg_sched) if matches_template(TransportUnitGo, n)])  # 화물 최대 ID

    # PlannerEnv: 시뮬레이션의 "환경" 객체. 스케줄·장면·적치원 등을 한데 묶음(키워드 인자로 생성).
    env = PlannerEnv(
        sched=tg_sched,                              # 실행할 스케줄
        scene_tree=scene_tree,                       # 장면 트리
        staging_circles=staging_circles,             # 적치 원들
        max_robot_go_id=max_robot_go_id,             # 로봇 이동 최대 ID
        max_cargo_id=max_cargo_id,                   # 화물 최대 ID
    )

    if rvo_flag                                      # RVO를 쓰면 각 로봇을 RVO 에이전트로 등록
        ConstructionBots.rvo_add_agents!(scene_tree)
    end

    # ── 12단계: 각 에이전트(로봇/운반유닛)에 이동 정책(충돌회피) 부여 ──
    static_potential_function = (x, r) -> 0.0        # 정적 장애물 퍼텐셜(여기선 항상 0 = 없음)
    pairwise_potential_function = ConstructionBots.repulsion_potential  # 에이전트끼리 밀어내는 퍼텐셜 함수
    for node in get_nodes(env.sched)                 # 스케줄의 모든 노드 순회
        # Union{A,B}: "A 또는 B 타입". 로봇 시작 노드이거나 운반유닛 구성 노드일 때만.
        if matches_template(Union{RobotStart,FormTransportUnit}, node)
            n = entity(node)                         # 노드가 가리키는 실제 개체(로봇/운반유닛)
            agent_radius = get_radius(get_base_geom(n, HypersphereKey()))  # 그 개체의 반경
            vmax = ConstructionBots.get_rvo_max_speed(n)  # 최대 속도

            tagent_bug_pol = nothing                 # TangentBug 정책(없으면 nothing)
            dispersion_pol = nothing                 # dispersion 정책(없으면 nothing)
            if tangent_bug_flag                      # TangentBug 켜졌으면 정책 생성
                tagent_bug_pol = TangentBugPolicy(
                    dt=env.dt, vmax=vmax, agent_radius=agent_radius  # 시간간격·최대속도·반경
                )
            end
            if dispersion_flag                       # dispersion 켜졌으면 퍼텐셜장 제어기 생성
                dispersion_pol = ConstructionBots.PotentialFieldController(
                    agent=n,                         # 대상 개체
                    node=node,                       # 해당 스케줄 노드
                    agent_radius=agent_radius,       # 반경
                    vmax=vmax,                        # 최대 속도
                    max_buffer_radius=2.5 * agent_radius,    # 최대 완충 반경
                    interaction_radius=(15 * agent_radius),  # 상호작용을 고려할 반경
                    static_potentials=static_potential_function,    # 정적 퍼텐셜 함수 연결
                    pairwise_potentials=pairwise_potential_function # 쌍별 퍼텐셜 함수 연결
                )
            end

            # 이 에이전트의 속도 제어기를 정책 딕셔너리에 등록(키=개체 ID).
            # 평상시엔 nominal(TangentBug), 혼잡 시엔 dispersion으로 분산.
            env.agent_policies[node_id(n)] = ConstructionBots.VelocityController(
                nominal_policy=tagent_bug_pol,       # 기본 항법 정책
                dispersion_policy=dispersion_pol     # 분산 정책
            )
        end
    end


    # ── 13단계: 전처리(부품을 시작 위치로 옮기는 과정) 애니메이션 생성 ──
    anim = nothing                                   # 애니메이션 객체(필요할 때만 생성)
    if process_animation_tasks
        print("Animating preprocessing step...")
        anim = ConstructionBots.AnimationWrapper(0, visualizer; fps=anim_fps)  # 애니메이션 래퍼(프레임 0부터 시작, 재생 프레임레이트=anim_fps)
        # atframe(anim, 프레임) do ... end : "특정 프레임의 장면 상태"를 기록하는 do-블록(do는 마지막 인자로 넘기는 익명함수).
        atframe(anim, ConstructionBots.current_frame(anim)) do
            jump_to_final_configuration!(scene_tree; set_edges=true)  # 완성 형태로 점프
            ConstructionBots.update_visualizer!(factory_vis)          # 뷰어 갱신
            setvisible!(factory_vis.geom_nodes[HyperrectangleKey()], false)  # 직육면체 형상 숨김
            setvisible!(factory_vis.staging_nodes, false)            # 적치 영역 숨김
        end
        ConstructionBots.step_animation!(anim)       # 다음 프레임으로 진행
        ConstructionBots.animate_preprocessing_steps!(  # 부품들이 시작위치로 흩어지는 과정을 애니메이션화
            factory_vis,
            sched;
            dt=0.0,
            anim=anim,
            interp_steps=40                          # 두 상태 사이를 40프레임으로 부드럽게 보간
        )
        setanimation!(visualizer, anim.anim, play=false)  # 만든 애니메이션을 뷰어에 등록(자동재생 안 함)
        print("done\n")

        if save_animation_along_the_way              # 진행중 저장 옵션이면 전처리 애니메이션 저장
            save_animation!(visualizer, "$(anim_prog_path)preprocessing.html")
        end

    end

    set_use_rvo!(rvo_flag)                           # 시뮬레이션에서 RVO 사용 여부 전역 설정
    set_avoid_staging_areas!(true)                   # 적치 영역을 피해 다니도록 설정

    # RESPEC: hand back the fully-built env (RVO agents + policies set, cache
    # empty since nothing has executed yet) so verify-gate / replan tests can run
    # against a real schedule without stepping the simulation.
    # RESPEC: 시뮬레이션을 돌리기 직전, 완성된 env를 그대로 돌려줌(검증/재계획 테스트용).
    if return_env_before_sim
        return env
    end

    # WM/RESPEC: fire the pre-sim hook (enable_battery! / schedule OODs / capture pre-sim state) on the
    # fully-built env, right before the sim loop — inside the production run_one path (default inert).
    if pre_sim_hook !== nothing
        pre_sim_hook(env)
    end

    # ── 14단계: 시뮬레이션 루프 실행(로봇들이 실제로 움직여 조립) ──
    execution_start_time = time()                    # 실행 시간 측정 시작

    # run_simulation!: 메인 루프. 성공여부(status)와 걸린 스텝수(time_steps)를 함께 반환.
    status, time_steps = run_simulation!(env, factory_vis, anim, sim_params)

    if status == true                               # 성공했으면 실제 소요시간 기록
        execution_time = time() - execution_start_time
    else                                            # 실패(교착 등)면 무한대로 표시
        execution_time = Inf
        time_steps = Inf
    end

    # Add results
    stats[:ExecutionRuntime] = execution_time        # 실행 소요시간
    stats[:Makespan] = time_steps * env.dt           # 총 작업시간 = 스텝수 × 한 스텝의 시간
    if write_results
        open(stats_path, "w") do io
            TOML.print(io, stats)
        end
    end

    # ── 15단계: 결과 애니메이션 저장/열기(마무리) ──
    if process_animation_tasks
        # Diagnostic: report how many animation keyframes were actually recorded.
        # 진단: 실제로 기록된 애니메이션 키프레임 수를 보고.
        if !isnothing(anim)
            # try ... catch e ... end : 예외 처리(파이썬 try/except). 안에서 오류 나면 catch로 넘어감.
            try
                _nclips = length(anim.anim.clips)    # 클립 개수
                _nframes = 0                         # 트랙당 최대 키프레임 수
                for (_p, _clip) in anim.anim.clips   # 각 클립을 순회
                    for _tr in values(_clip.tracks)  # 클립 안 트랙들을 순회
                        _nframes = max(_nframes, length(_tr.events))  # 가장 키프레임 많은 트랙 길이로 갱신
                    end
                end
                println("[DIAG] animation: $(_nclips) clips, max $(_nframes) keyframes per track"); flush(stdout)
            catch e                                  # 오류가 나면 e에 담아 메시지만 출력
                println("[DIAG] could not introspect animation object: $e"); flush(stdout)
            end
        end
        if save_animation                            # 저장 옵션이면 최종 애니메이션 파일로 저장
            save_animation!(visualizer, anim_path)
        end
        if open_animation_at_end                     # 끝에 브라우저로 열기 옵션이면
            open(visualizer)                         # 뷰어를 브라우저에서 염
            # The browser connects AFTER the simulation set the animation, so
            # late-joining clients may not receive it. Re-send the animation a
            # few times while the browser is connecting so it reliably shows up.
            # 브라우저가 늦게 접속하면 애니메이션을 못 받을 수 있어, 접속하는 동안 여러 번 다시 보냄.
            if !isnothing(anim)
                for _ in 1:10                        # 1부터 10까지 10번 반복(_=쓰지 않는 변수)
                    sleep(2)                         # 2초 대기
                    setanimation!(visualizer, anim.anim, play=false)  # 애니메이션 재전송
                end
                println("[DIAG] (re)sent animation to the connected browser"); flush(stdout)
            end
        end
    end
    return env, stats                                # 환경 객체와 통계를 함께 반환(파이프라인 종료)
end
