
# ============================================================================
#  이 파일은 "프로젝트(레고 모델별) 파라미터 정의" — 어떤 모델을 몇 대의 로봇으로,
#  어떤 도면 파일과 축척으로 조립할지에 대한 설정표(카탈로그)를 담음.
#  프로젝트에서의 위치: 데모/실험을 돌릴 때 여기서 시나리오를 골라 값들을 꺼내 씀
#  (run_lego_demo 등이 get_project_params 로 이 표를 조회). ConstructionBots.jl 에서 include 됨.
#  담긴 것: projects(번호→이름표), project_parameters(이름표→설정묶음),
#           list_projects(목록 출력), get_project_params(설정 조회).
#  Julia 문법 참고:
#   · Dict(키 => 값)   : 딕셔너리. `=>` 는 "키 => 값" 한 쌍(Pair)을 만드는 연산자.
#   · `:이름`          : Symbol — 따옴표 없는 가벼운 이름표 상수(문자열 대신 식별자로 씀).
#   · (a = 1, b = 2)   : NamedTuple — 이름표가 붙은 튜플. `.필드이름` 으로 값을 꺼냄.
#   · function f(x::Int) / f(x::Symbol) : 같은 이름을 인자 타입별로 정의 = 다중 디스패치.
# ============================================================================

# Dict(키 => 값, ...) : 딕셔너리 생성(파이썬 {키: 값} 과 같음). `=>` 는 한 쌍의 "키 => 값" 을 만드는 연산자(Pair).
# `:이름` : Symbol — 따옴표 없는 가벼운 "이름표" 상수(파이썬엔 정확한 대응이 없음; 문자열 대신 식별자로 자주 씀).
# 여기서는 "번호 → 프로젝트 이름표" 표. 주석의 "33 x 1, 4 sec" 등은 (부품수 x 조립체수, 대략 실행시간) 메모.
projects = Dict(
    1 => :colored_8x8,                  # 33 x 1, 4 sec
    2 => :quad_nested,                  # 85 x 21, 26 sec
    3 => :heavily_nested,               # 1757 x 508, 62 min
    4 => :tractor,                      # 20 x 8, 2 sec
    5 => :tie_fighter,                  # 44 x 4, 7 sec
    6 => :x_wing_mini,                  # 61 x 12, 9 sec
    7 => :imperial_shuttle,             # 84 x 5, 13 sec
    8 => :x_wing_tie_mini,              # 105 x 17, 26 sec
    9 => :at_te_walker,                 # 100 x 22, 23 sec
    10 => :x_wing,                      # 309 x 28, 3 min
    11 => :passenger_plane,             # 326 x 28, 4 min
    12 => :imperial_star_destroyer,     # 418 x 11, 5 min
    13 => :kings_castle,                # 761 x 70, 21 min
    14 => :at_at,                       # 1105 x 2, ??
    15 => :saturn_v,                    # 1845 x 306, 163 min
    16 => :destroyer_droid              # large MPD; conservative large-model defaults
)

# "프로젝트 이름표 => 파라미터묶음" 표. 각 값은 (이름=값, ...) 형태의 NamedTuple(이름붙은 튜플 — 필드 이름으로 접근).
# 필드: project_name(이름), file_name(LDraw 도면 파일), model_scale(모형 축척), num_robots(투입 로봇 수).
project_parameters = Dict(
    :colored_8x8 => (
        project_name = "colored_8x8",       # 프로젝트 이름(문자열)
        file_name = "colored_8x8.ldr",      # 입력 도면 파일명
        model_scale = 0.008,                # 모형 축척(클수록 큼)
        num_robots = 24                     # 기본 로봇 대수
    ),
    :quad_nested => (
        project_name = "quad_nested",       # 프로젝트 이름
        file_name = "quad_nested.mpd",      # 입력 도면 파일명(.mpd = 여러 모델 묶음 포맷)
        model_scale = 0.0015,               # 모형 축척
        num_robots = 50                     # 기본 로봇 대수
    ),
    :heavily_nested => (
        project_name = "heavily_nested",    # 프로젝트 이름
        file_name = "heavily_nested.mpd",   # 입력 도면 파일명
        model_scale = 0.0015,               # 모형 축척
        num_robots = 50                     # 기본 로봇 대수
    ),
    :tractor => (
        project_name = "tractor",           # 프로젝트 이름
        file_name = "tractor.mpd",          # 입력 도면 파일명
        model_scale = 0.008,                # 모형 축척
        num_robots = 10                     # 기본 로봇 대수
    ),
    :tie_fighter => (
        project_name = "tie_fighter",                   # 프로젝트 이름
        file_name = "8028-1 - TIE Fighter - Mini.mpd",  # 입력 도면 파일명
        model_scale = 0.008,                            # 모형 축척
        num_robots = 15                                 # 기본 로봇 대수
    ),
    :x_wing_mini => (
        project_name = "x_wing_mini",                        # 프로젝트 이름
        file_name = "30051-1 - X-wing Fighter - Mini.mpd",   # 입력 도면 파일명
        model_scale = 0.008,                                 # 모형 축척
        num_robots = 20                                      # 기본 로봇 대수
    ),
    :imperial_shuttle => (
        project_name = "imperial_shuttle",                     # 프로젝트 이름
        file_name = "4494-1 - Imperial Shuttle - Mini.mpd",    # 입력 도면 파일명
        model_scale = 0.008,                                   # 모형 축척
        num_robots = 20                                        # 기본 로봇 대수
    ),
    :x_wing_tie_mini => (
        project_name = "x_wing_tie_mini",       # 프로젝트 이름
        file_name = "X-wing--Tie Mini.mpd",     # 입력 도면 파일명
        model_scale = 0.008,                    # 모형 축척
        num_robots = 20                         # 기본 로봇 대수
    ),
    :at_te_walker => (
        project_name = "at_te_walker",                      # 프로젝트 이름
        file_name = "20009-1 - AT-TE Walker - Mini.mpd",    # 입력 도면 파일명
        model_scale = 0.008,                                # 모형 축척
        num_robots = 35                                     # 기본 로봇 대수
    ),
    :x_wing => (
        project_name = "x_wing",                        # 프로젝트 이름
        file_name = "7140-1 - X-wing Fighter.mpd",      # 입력 도면 파일명
        model_scale = 0.004,                            # 모형 축척
        num_robots = 50                                 # 기본 로봇 대수
    ),
    :passenger_plane => (
        project_name = "passenger_plane",               # 프로젝트 이름
        file_name = "3181 - Passenger Plane.mpd",       # 입력 도면 파일명
        model_scale = 0.004,                            # 모형 축척
        num_robots = 50                                 # 기본 로봇 대수
    ),
    :imperial_star_destroyer => (
        project_name = "imperial_star_destroyer",                           # 프로젝트 이름
        file_name = "8099-1 - Midi-Scale Imperial Star Destroyer.mpd",      # 입력 도면 파일명
        model_scale = 0.004,                                                # 모형 축척
        num_robots = 75                                                     # 기본 로봇 대수
    ),
    :kings_castle => (
        project_name = "kings_castle",          # 프로젝트 이름
        file_name = "6080 - Kings Castle.mpd",  # 입력 도면 파일명
        model_scale = 0.004,                    # 모형 축척
        num_robots = 125                        # 기본 로봇 대수
    ),
    :at_at => (
        project_name = "at_at",                 # 프로젝트 이름
        file_name = "75054-1 - AT-AT.mpd",      # 입력 도면 파일명
        model_scale = 0.004,                    # 모형 축척
        num_robots = 150                        # 기본 로봇 대수
    ),
    :saturn_v => (
        project_name = "saturn_v",                          # 프로젝트 이름
        file_name = "21309-1 - NASA Apollo Saturn V.mpd",   # 입력 도면 파일명
        model_scale = 0.0015,                               # 모형 축척
        num_robots = 200                                    # 기본 로봇 대수
    ),
    :destroyer_droid => (
        project_name = "destroyer_droid",
        file_name = "8002 - Destroyer Droid.mpd",
        model_scale = 0.0015,
        num_robots = 200
    )
)

"""
    list_projects()

Prints a list of available projects.
"""
# 사용 가능한 프로젝트 목록을 화면에 출력하는 함수.
function list_projects()
    println("Available projects:")                       # 제목 한 줄 출력
    # sort(collect(keys(projects))) : 딕셔너리 키들을 배열로 모아(collect) 오름차순 정렬. 번호 순으로 보여주기 위함.
    for ii in sort(collect(keys(projects)))
        println("  $ii: $(projects[ii])")                 # "번호: 프로젝트이름" 출력($(...) 은 값 보간)
    end
end

"""
    get_project_params(project::Int)
    get_project_params(project::Symbol)

Returns the parameters for the project with the given number or symbol.
Returns a Dict with the following fields:
- `project_name` (String): The name of the project.
- `file_name` (String): The name of the LDraw file.
- `model_scale` (Float64): The default scale of the model.
- `num_robots` (Int): The default number of robots to use.
"""
# 같은 이름의 함수를 인자 타입별로 두 번 정의 → "다중 디스패치". 호출 시 인자 타입에 맞는 메서드가 자동 선택됨.
# 이 메서드는 인자가 정수(Int, 프로젝트 번호)일 때 사용.
function get_project_params(project::Int)
    # `!` 는 부정(not), `in` 은 포함 검사. 번호가 표에 없으면:
    if !(project in keys(projects))
        list_projects()                            # 사용 가능한 목록을 보여주고
        error("Project $project not found.")       # 오류를 던짐(파이썬 raise 와 비슷)
    end
    # projects[project] 로 번호→이름표(Symbol)를 얻은 뒤, 아래의 Symbol 버전 메서드를 다시 호출(디스패치).
    return get_project_params(projects[project])
end
# 이 메서드는 인자가 Symbol(:x_wing 같은 이름표)일 때 사용.
function get_project_params(project::Symbol)
    if !(project in keys(project_parameters))      # 이름표가 파라미터 표에 없으면
        list_projects()                            # 목록 안내 후
        error("Project $project not found.")       # 오류
    end
    return project_parameters[project]             # 해당 프로젝트의 파라미터 NamedTuple 반환
end

"""Return project parameters by LDraw filename (basename, case-insensitive)."""
function get_project_params(file_name::AbstractString)
    wanted = lowercase(basename(String(file_name)))
    for params in values(project_parameters)
        lowercase(basename(String(params.file_name))) == wanted && return params
    end
    available = join(sort(String(p.file_name) for p in values(project_parameters)), ", ")
    error("No project parameters for LDraw file '$file_name'. Available: $available")
end

"""All configured projects, sorted by their public numeric project id."""
all_project_params() = [get_project_params(i) for i in sort!(collect(keys(projects)))]
