# =============================================================================
# respec.jl  --  Aggregator for the verified LLM re-specification layer.
# Include this ONCE from ConstructionBots.jl (see PATCHES.md, patch 3).
#
# Pipeline:  OOD event --(llm_bridge)--> typed DSL proposal
#                       --(verifier)----> Admit / Reject  (Reject -> fallback)
#                       --(compiler)----> @constraints injected into the MILP
#                       --(replan)------> re-solve from frozen state, resume
#
# Hard dependencies to add to Project.toml: HTTP, JSON3.
# -----------------------------------------------------------------------------
# [한국어 설명]
# 이 파일은 검증된 LLM 재명세(re-specification) 계층 전체를 한데 모으는 "취합기(aggregator)".
# 프로젝트 역할: OOD 사건 → (llm_bridge) 타입 있는 DSL 제안 → (verifier) 수용/거부 →
#   (compiler) MILP 에 @constraint 주입 → (replan) 동결 상태에서 재풀이·재개. 이 파이프라인의
#   구성 파일들을 정해진 순서로 include 한다. ConstructionBots.jl 에서 딱 한 번만 include 할 것.
# [문법 참고] include("파일.jl") = 그 파일 코드를 여기에 그대로 펼침(모듈을 여러 파일로 분할).
#   순서가 중요 — 아래 파일이 위 파일의 타입/함수를 쓰므로 정의된 순서대로 불러온다.
# =============================================================================

# include("파일.jl") : 그 파일의 코드를 "여기에 그대로 붙여넣는다"(모듈을 여러 파일로 쪼개 관리).
# 여기 경로는 "이 파일 기준 상대경로" — 이 respec.jl 이 이미 src/respec/ 폴더 안에 있으므로 같은 폴더의 파일을 가리킴.
# 순서가 중요 — 아래 파일이 위 파일에서 정의한 타입/함수를 쓰므로 정의된 순서대로 불러옴.
include("spec_dsl.jl")       # 재명세 DSL(문법) 정의 — LLM 이 내놓을 수 있는 제약 타입들 (이 파일이 가장 먼저)
include("compiler.jl")       # DSL 제약을 실제 JuMP @constraint 로 변환(컴파일)
include("verifier.jl")       # 제안된 제약을 받아들일지/거부할지 검증
include("llm_bridge.jl")     # 별도 파이썬 LLM 서비스와 통신(LLM 이 위 DSL 문법만 내놓도록 강제)
include("replan.jl")         # 동결된 상태에서 다시 풀고(re-solve) 이어서 진행(replan)
include("reassign.jl")       # 로봇 고장 시 작업을 다른 로봇에게 재배정
include("ood_injection.jl")  # physical OOD event GENERATION (front-end; uses push_ood!)  # 물리 OOD 이벤트 "생성"(앞단; push_ood! 사용)
include("restage_zone.jl")   # ForbidZone enactment: relocate a staging-blocked assembly  # ForbidZone 실행: 적치공간이 막힌 조립체를 옮김
include("replace_robot.jl")  # ReplaceAgent enactment: spare 1:1 chain hand-off  # ReplaceAgent 실행: 예비 로봇으로 잔여 작업 인계(고장 대체)
