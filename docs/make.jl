# ============================================================================
#  이 파일이 하는 일: 패키지 문서(HTML)를 만드는 빌드 스크립트. Documenter.jl 을 써서
#  ConstructionBots 의 docstring 을 모아 웹 문서로 변환하고, GitHub Pages 로 배포함.
#  프로젝트 속 역할: `julia --project=docs docs/make.jl` 로 실행하면 문서가 생성/배포됨.
#  Julia 문법 참고:
#   · makedocs(; key=val, ...) : 문서 생성 함수. 전부 키워드 인자.
#   · modules = [ConstructionBots] : docstring 을 긁어올 대상 모듈 목록(배열).
#   · "stable" => "v^" : Pair(키 => 값). 버전 라벨과 매칭 규칙을 짝지음.
#   · :none : Symbol. checkdocs=:none = 누락된 docstring 검사를 하지 않음.
# ============================================================================

using Documenter        # 문서 생성 도구
using ConstructionBots  # 문서를 만들 대상 패키지

# 문서를 생성(build)하는 호출: 대상 모듈·출력 형식(HTML)·사이트 이름·검사 수준을 지정.
makedocs(
    modules = [ConstructionBots],       # 이 모듈들의 docstring 을 문서화
    format = Documenter.HTML(),         # 출력은 HTML 사이트
    sitename = "ConstructionBots.jl",   # 문서 사이트 제목
    checkdocs = :none                   # 빠진 docstring 이 있어도 에러 내지 않음
)

# 생성된 문서를 GitHub Pages 로 배포하는 호출: 저장소와 버전 규칙 지정.
deploydocs(
    repo = "github.com/sisl/ConstructionBots.jl",     # 문서를 올릴 GitHub 저장소
    versions = ["stable" => "v^", "v#.#"]             # 안정판/버전별 문서 경로 규칙
)
