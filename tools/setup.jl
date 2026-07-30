# =============================================================================
# tools/setup.jl -- consolidated environment bootstrap (was setup_instantiate.jl,
# setup_pycall.jl, setup_110.jl). Each former script is a function in module Setup
# with a CLI/ENV dispatcher.
#
# Setup keys:
#   instantiate  -- Pkg.instantiate() only
#   pycall       -- point PyCall at the conda python and Pkg.build("PyCall")
#   all          -- julia-1.10 full bootstrap: instantiate + build PyCall (was setup_110)
#
# Run:
#   julia +lts --project=. tools/setup.jl <key>        (or  ENV SETUP=<key>)
# e.g.
#   julia +lts --project=. tools/setup.jl all
#
# The PyCall python path defaults to the conda env below; override with
# ENV["CB_PYTHON"] (or CB_PYTHON=... in the shell) if your python lives elsewhere.
# =============================================================================

# =============================================================================
#  [한국어 설명] 이 파일 = ConstructionBots 실행 "환경 준비(setup)" 스크립트 모음.
#  - 프로젝트에서의 역할: 시뮬레이터를 돌리기 전에 (1) Julia 패키지 의존성 설치,
#    (2) PyCall이 conda의 python(rvo2 충돌회피 라이브러리가 깔린)을 쓰도록 연결.
#  - 옛날엔 setup_instantiate.jl / setup_pycall.jl / setup_110.jl 3개 파일이었는데,
#    지금은 하나의 `Setup` 모듈 안 함수 3개로 합쳤고, 맨 아래 dispatcher가 키로 골라 실행.
#  - 사용법: `julia +lts --project=. tools/setup.jl <키>` (키 = instantiate / pycall / all).
#
#  문법 참고(처음 보는 Julia 문법):
#   · module Setup ... end : 이름공간(namespace). 안의 함수는 Setup.함수명 으로 부름.
#   · using Pkg : Julia 패키지 관리자(Pkg) 기능을 가져옴(설치/빌드 담당).
#   · f() = get(ENV, "키", 기본값) : 한 줄짜리 함수 정의 축약형. ENV=환경변수 딕셔너리.
#   · raw"..." : 역슬래시(\)를 그대로 두는 문자열(윈도우 경로 C:\... 에 필수).
#   · "a" => b : Pair(짝) 리터럴. Dict 를 만들 때 키=>값 형태로 씀.
#   · `!` 로 끝나는 이름(예: instantiate!)은 없지만, ENV["PYTHON"]=... 처럼 대입은 부작용(side effect).
#   · @__FILE__ : 지금 이 소스파일의 경로를 주는 매크로(@ 로 시작 = 매크로).
# =============================================================================
module Setup
using Pkg

# machine-specific python for PyCall/rvo2; overridable via ENV["CB_PYTHON"].
# [KO] PyCall/rvo2 가 쓸 python.exe 경로를 돌려줌. 환경변수 CB_PYTHON 이 있으면 그걸,
#      없으면 이 컴퓨터의 conda 환경(lego_rvo2) 기본 경로를 사용.
_python() = get(ENV, "CB_PYTHON", raw"C:\Users\chahj\anaconda3\envs\lego_rvo2\python.exe")

# instantiate -- resolve + install the project's dependencies.
# [KO] 프로젝트의 의존 패키지들을 (Project.toml/Manifest.toml 기준으로) 해석·설치만 함.
function setup_instantiate()
    Pkg.instantiate()
    println("INSTANTIATE_DONE")
end

# pycall -- point PyCall at the conda python, then (re)build it so rvo2 imports.
# [KO] PyCall 이 위 _python() 을 쓰도록 ENV["PYTHON"] 을 지정한 뒤 다시 빌드 → rvo2 import 가능.
function setup_pycall()
    ENV["PYTHON"] = _python()   # PyCall 은 빌드 시점에 이 환경변수로 python 을 고정함
    Pkg.build("PyCall")         # 그 python 에 맞춰 PyCall 재빌드(rvo2 를 찾게 만듦)
    println("PYCALL_BUILD_DONE")
end

# all -- julia 1.10 full bootstrap: instantiate + build PyCall (was setup_110.jl).
# [KO] julia 1.10 에서 한 방에 다 준비: 의존성 설치 + PyCall 빌드까지. (권장 진입점)
function setup_all()
    ENV["PYTHON"] = _python()
    println("Julia version: ", VERSION)
    Pkg.instantiate()
    Pkg.build("PyCall")
    println("SETUP_110_DONE")
end

# ---- dispatcher -------------------------------------------------------------
# [KO] "키 문자열 -> 실행할 함수" 표. 아래 실행부에서 이 표를 보고 하나를 골라 부름.
const SETUPS = Dict(
    "instantiate" => setup_instantiate,
    "pycall"      => setup_pycall,
    "all"         => setup_all,
)
end # module Setup

# [KO] 이 파일을 `julia tools/setup.jl ...` 로 직접 실행했을 때만 아래가 돎(=엔트리포인트).
#      다른 파일에서 include 만 하면 실행 안 됨. (@__FILE__ = 이 파일, PROGRAM_FILE = 실행된 파일)
if abspath(PROGRAM_FILE) == @__FILE__
    # [KO] 키 선택 우선순위: 환경변수 SETUP > 명령줄 첫 인자 ARGS[1] > 기본값 "all".
    key = get(ENV, "SETUP", isempty(ARGS) ? "all" : ARGS[1])
    # [KO] 표에 없는 키면 사용 가능한 키 목록을 알려주며 에러. (|| = 앞이 false 일 때만 뒤 실행)
    haskey(Setup.SETUPS, key) || error("unknown setup '$key'. Available: $(join(sort(collect(keys(Setup.SETUPS))), ", "))")
    println(">>> running setup: $key")
    Setup.SETUPS[key]()   # [KO] 고른 함수를 실제로 호출
end
