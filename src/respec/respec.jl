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
include("identity.jl")       # 로봇 정체성 4-레지스트리 정합성 불변식(읽기 전용 검사기) — 다른 파일이 호출만 하므로 가장 먼저
include("asset_ledger.jl")   # 2단 정체성: 역할(RobotID) vs 물리 자산 — append-only 교체/정비 이력
include("spec_dsl.jl")       # 재명세 DSL(문법) 정의 — LLM 이 내놓을 수 있는 제약 타입들
include("compiler.jl")       # DSL 제약을 실제 JuMP @constraint 로 변환(컴파일)
include("verifier.jl")       # 제안된 제약을 받아들일지/거부할지 검증
include("llm_bridge.jl")     # 별도 파이썬 LLM 서비스와 통신(LLM 이 위 DSL 문법만 내놓도록 강제)
include("replan.jl")         # 동결된 상태에서 다시 풀고(re-solve) 이어서 진행(replan)
include("reassign.jl")       # 로봇 고장 시 작업을 다른 로봇에게 재배정
include("ood_injection.jl")  # physical OOD event GENERATION (front-end; uses push_ood!)  # 물리 OOD 이벤트 "생성"(앞단; push_ood! 사용)
include("repair_ablation.jl") # 존 복구 base ablation: 레벨·차단 목록·실행 가드(명세 2026-09-23). restage_zone.jl 이 첫 줄에서 부른다
include("restage_zone.jl")   # ForbidZone enactment: relocate a staging-blocked assembly  # ForbidZone 실행: 적치공간이 막힌 조립체를 옮김
include("cargo_ban_primitive.jl") # 알파벳 원시 forbid_heavy_cargo!: 지속 화물 금지 보관소에 항목 하나를 쓴다(세계는 안 바꾼다)
include("common_resolve.jl") # 공통 MILP 재풀이 한 벌 (판정 1) — SMDP 의 apply_action! 과 주조 body 집행이 **같은 함수**를 부른다
include("minted_registration.jl")   # 생성 원시의 런-스코프 표 (minted_tool.jl 이 읽는다)
include("minted_tool.jl")    # 합성된 tool 의 해석·집행 (T2·T3)
include("replace_robot.jl")  # ReplaceAgent enactment: spare 1:1 chain hand-off  # ReplaceAgent 실행: 예비 로봇으로 잔여 작업 인계(고장 대체)
include("battery_courier.jl") # SwapBattery enactment: 창고 예비가 배터리를 들고 왕복 배송(시간이 드는 물리적 사건)
include("zone_diagnosis.jl") # zone VIOLATION PREDICATES (thin composition over restage_zone.jl) — 구역이 씬트리의 무엇을 무효화하는지 계산(오라클 라벨·게이트 근거)
include("zone_corridor.jl")  # zone BLOCKAGE predicates: 덮였다(coverage)가 아니라 **막혔다**를 잰다(RVO 구동 목표 + 통로 연결성)
include("zone_facts.jl")     # zone 센서 전용(해법기 없음) — 세 ablation 팔 전부에 광고(명세 §4)
