# ============================================================================
#  이 파일은 패키지의 최상위 MODULE 파일 — 즉 "목차/조립도" 역할.
#  하는 일: (1) 필요한 외부 패키지들을 using 으로 불러오고,
#           (2) 기능별로 쪼갠 소스파일들을 include 로 정해진 순서대로 이어붙이고,
#           (3) 외부(스크립트/테스트)에서 바로 쓸 이름들을 export 로 공개한 뒤,
#           (4) 레고 모델을 "부품→조립단계→스케줄 그래프"로 바꾸는 핵심 구성 함수들을 정의함.
#  프로젝트에서의 위치: 멀티로봇 건설 TAMP 시뮬레이터의 진입 관문 — OOD(예상 밖 상황) 복구용
#           LLM/surrogate "re-spec" 레이어(respec/)도 여기서 마지막에 include 되어 전체가 하나로 묶임.
# ----------------------------------------------------------------------------
#  Julia 문법 빠른 안내 (이 파일을 읽기 전에 알아두면 좋은 것들)
# ----------------------------------------------------------------------------
#  · `module ... end`        : 파이썬의 "패키지/네임스페이스"에 해당. 이 안의 이름들이 한 묶음.
#  · `using X`               : 파이썬 `import X` 와 비슷. X 패키지의 기능을 불러옴.
#  · `struct Name ... end`   : 새 "데이터 타입(구조체)"을 정의. 파이썬의 class 와 비슷하지만
#                              기본적으로 "값을 담는 틀"에 가까움(메서드는 밖에 따로 정의).
#  · `{N,ID}`                : 타입 "매개변수(제네릭)". 파이썬 typing 의 List[T] 의 T 처럼,
#                              "아직 안 정해진 타입을 나중에 채워 넣는 빈칸". N, ID 는 그냥 이름일 뿐.
#  · `<: SuperType`          : "이 타입은 SuperType 의 하위 타입이다"(상속 관계). `<:` = "subtype of".
#  · `x::Int`                : "x 의 타입은 Int 다"라는 타입 표기(파이썬의 x: int 와 동일한 의미).
#  · `function f(a) ... end`  : 함수 정의. `f(a) = ...` 한 줄짜리 축약형도 자주 씀.
#  · `f!(...)`               : 이름 끝의 `!` 는 관례 — "인자(보통 첫 번째)를 직접 수정(in-place)함"을 표시.
#  · `@매크로이름`            : `@` 로 시작하면 "매크로". 함수 호출이 아니라, 코드를 컴파일 전에
#                              자동으로 변형/확장해주는 도구. (예: @with_kw 는 struct 에 키워드 생성자를 자동 추가)
#  · `::Type` 만 적은 인자    : 값 이름 없이 타입만 적으면 "이 타입일 때만 이 메서드를 쓴다"는 뜻(다중 디스패치).
# ============================================================================

module ConstructionBots   # 이 패키지 전체를 담는 모듈(네임스페이스) 시작. 맨 끝의 end 와 짝.

using Printf               # C 스타일 형식 출력(@printf, @sprintf) 제공
using Parameters           # @with_kw 등 "키워드 인자 생성자 자동생성" 매크로 제공
using StaticArrays         # 크기가 고정된 빠른 배열(SVector 등) — 3D 좌표 같은 데 사용
using JuMP                 # 수리최적화 모델링 언어(변수/제약/목적함수 정의) — 작업 배정·기하 계산에 사용
using MathOptInterface     # JuMP 가 솔버와 통신할 때 쓰는 저수준 인터페이스(보통 MOI 로 줄여 부름)
using LinearAlgebra        # 선형대수(dot 내적, normalize 정규화, 행렬 연산 등)
using ForwardDiff          # 자동미분(미분값을 수치적으로가 아니라 정확히 계산)
using SpatialIndexing      # 공간 인덱스(R-Tree) — 3D 공간에서 이웃 부품 빠르게 찾기
using Logging              # @info, @warn 같은 로그 출력 기능
using MeshCat              # 웹브라우저 기반 3D 시각화 도구
using SparseArrays         # 희소행렬(대부분 0인 큰 행렬을 효율적으로 저장)
using DataStructures       # 큐/스택/우선순위큐 등 추가 자료구조
using Rotations            # 3D 회전 표현(회전행렬, 쿼터니언 등)
using CoordinateTransformations  # 좌표 변환(평행이동·회전 합성 등)
using LazySets             # 집합 연산/볼록집합 표현(폴리토프 등)
using GeometryBasics       # 점/삼각형/다각형(Ngon) 등 기본 기하 타입
using Graphs               # 그래프(노드·엣지) 기본 자료구조 및 알고리즘
using MetaGraphs           # 그래프의 노드/엣지에 부가 데이터를 붙일 수 있게 해줌

using Random               # 난수 생성
using Dates                # 날짜/시간 처리
using StatsBase            # 기초 통계(샘플링, 가중치 등)
using JLD2                 # 줄리아 객체를 파일로 저장/불러오기(파이썬 pickle 비슷)
using ProgressMeter        # 진행률 막대(loop 진행 상황 표시)
using TOML                 # TOML 설정파일 읽기/쓰기
using PyCall               # 줄리아 안에서 파이썬 코드/라이브러리 호출
using LDrawParser          # LDraw(레고 도면 포맷) 파일 파싱 — 이 프로젝트의 입력 데이터
using Colors               # 색상 표현/변환

using HiGHS                # 오픈소스 선형/정수계획 솔버
using Gurobi               # 상용 고성능 솔버(라이선스 필요)
using ECOS                 # 원뿔(conic) 최적화 솔버
using GLPK                 # 오픈소스 선형/정수계획 솔버

# RESPEC: verified LLM re-specification layer (thin HTTP client to the separate
# Python LLM service; the verifier/compiler stay here on the solver side).
using HTTP                  # HTTP 통신 — 별도의 파이썬 LLM 서비스에 요청을 보내는 데 사용
using JSON3                 # JSON 직렬화/역직렬화(LLM 서비스와 데이터 주고받기)


# only needed for plotting stuff
using Measures              # 그림 그릴 때 여백/길이 단위(cm, mm 등) 지정
using Compose              # 벡터 그래픽 그리기(그래프 다이어그램 등)


# include("파일.jl") : 그 파일의 코드를 "여기에 그대로 붙여넣는다". 모듈을 여러 파일로 쪼개 관리하는 방법.
# 순서가 중요 — 아래 파일이 위 파일에서 정의한 타입/함수를 사용하므로 정의된 순서대로 불러옴.
include("graph_utils_essentials.jl")        # 그래프 유틸리티(노드/엣지 다루는 기본 함수들)
include("essential_tg_coponents.jl")        # 핵심 그래프 구성요소(커스텀 노드/그래프 타입 정의)
include("hierarchical_geom_essentials.jl")  # 계층적 기하(부품·조립체의 위치/형상/변환)
include("construction_schedule.jl")         # 조립 스케줄(작업 순서 그래프)
include("rvo_interface.jl")                 # RVO(로봇 충돌회피) 인터페이스
include("task_assignment.jl")               # 작업 배정(어느 로봇이 어느 작업을)
include("route_planning.jl")                # 경로 계획(로봇 이동 경로)
include("safety/cbf.jl")                    # SAFETY L1/L0: 속도 CBF 필터 + 진짜 라인스톱. 기본 비활성(no-op)
include("safety/novelty.jl")                # NOVELTY: "학습분포 밖인가" 런타임 게이트. 교정 로드 전엔 무효(fail-open)
include("graph_plotting.jl")                # 그래프 시각화
include("render_tools.jl")                  # 3D 렌더링 도구
include("demo_utils.jl")                    # 데모 실행용 보조 함수
include("project_params.jl")                # 프로젝트(레고 모델별) 파라미터
include("full_demo.jl")                     # 전체 데모 실행 진입점
include("monitor/monitor.jl")               # MONITOR: 런타임 상태를 JSONL 로 방출(대시보드용). 비활성 시 no-op
include("respec/respec.jl")  # RESPEC: 반드시 마지막 — 위에서 정의한 타입들을 사용하기 때문

# export : 이 모듈을 `using ConstructionBots` 한 외부 코드에서 "이름만으로" 바로 쓸 수 있게 공개하는 목록.
#          (공개 안 하면 ConstructionBots.이름 처럼 모듈명을 붙여야 씀)
# RESPEC: public surface for scripts/tests (Patch 3, step 3 in respec/PATCHES.md).
export maybe_respecify!, push_ood!, OODQueue, maybe_emit_reform_ood!,  # 재명세(respec) 관련 공개 함수/타입 (+team-deadlock OOD 공유 emit)
       RespecProposal, ForbidWindow, ForbidAgent, ForbidZone, ReplaceAgent, ReformTeam,  # 재명세 제안·금지조건 타입들
       verify, build_invariant, commit_respec!, reset_cache_resume!,  # 검증·불변식·커밋·재개
       respec_service_ready, fault_robot_and_reassign!,           # LLM 서비스 준비확인·로봇 고장 후 재배정
       replace_robot!, reform_stuck_teams!, hot_swap_robot!,      # OOD 1-1: 예비 로봇 1:1 인계 + 막힌 운반팀 재정립 + 정체성보존 hot-swap
       restage_assembly!, find_clear_staging_center,              # 조립체 재배치·빈 적치 중심 찾기
       restage_all_blocked!, zone_blocked_assemblies,             # zone이 덮은 모든 assembly 일괄 재배치·검출
       root_deposit_goals, zone_clears_root_goals,                # root 근방 금지(생성 가드: zone이 root deposit goal을 안 덮게)
       translate_whole_build!                                     # Phase B: root까지 덮였을 때 빌드 전체 평행이동

# OOD generation front-end (physical OOD events; src/respec/ood_injection.jl).
export enable_cbf!, disable_cbf!, cbf_hold!, cbf_filter_velocity, cbf_certificate,  # SAFETY L1/L0: CBF 속도필터·라인스톱·감사
       cbf_stats, reset_cbf_stats!, cbf_report, solve_qp2d, set_failclosed_stop!, release_fallback!
export NoveltyDetector, load_novelty_detector, set_novelty_detector!, clear_novelty_detector!,  # NOVELTY 게이트
       novelty_score, conformal_pvalue, novelty_verdict, event_descriptors, novelty_report,
       decision_margin, vote_disagreement, escalation_verdict
export add_restriction_zone!, random_restriction_zone!, restriction_zones,        # 제한구역(통행금지) 추가/생성/조회
       clear_restriction_zones!, remove_restriction_zone!, active_restriction_zones,  # 제한구역 비우기/삭제/활성목록
       schedule_ood!, clear_ood_schedule!, ood_inject_step!,      # OOD(이상상황) 이벤트 예약/초기화/매 스텝 주입
       draw_restriction_zones!, clear_zone_markers!,              # 제한구역 시각화 마커 그리기/지우기
       SPARE_POOLS, SPARE_POOL_CENTERS, spare_pools, spare_pool_centers,  # OOD 1-1: 방위별 예비 로봇 풀(저장소/접근자)
       clear_spare_pools!, register_spare!, pop_spare!, active_spares,    # 풀 비우기/등록/꺼내기/전체목록
       pool_centers, nearest_pool, add_directional_spare_pools!,         # 풀 중심계산/최근접풀/4방위 배치
       fault_robot!, faulted_robots, clear_faulted_robots!,              # OOD 1-1: 로봇 고장 주입/조회/초기화
       set_hot_swap!, hot_swap_enabled, set_spare_pool_margin!, set_reform_interval!,  # OOD 1-1: hot-swap 토글 + 창고 거리 + reform 반응주기(무진전 self-heal 간격)
       depot_available, depot_info,                                      # 창고(repository) 재고/메타
       decommissioned_bodies, checked_out_spares,                        # 은퇴(고장) 본체·반출 예비 조회
       draw_spare_depots!, draw_decommissioned_robots!,                  # 창고 스테이션·은퇴 로봇 시각화
       clear_depot_markers!, clear_decommissioned_markers!              # 시각화 마커 초기화


################################################################################
############################ Constructing Model Tree ###########################
################################################################################
# 이 절: 원본 레고 도면(model)을 단계별 자료구조로 변환하는 함수들 모음.
#   model(원자재 형상) → model_spec(작업 그래프) → assembly_tree(상대위치 포함 조립트리)
#   → SceneTree(시뮬레이션/렌더용) 로 이어지는 파이프라인의 앞단.

# model::MPDModel - model.parts contains raw geometry of all parts
#   (MPDModel: 모든 부품의 원본 3D 형상을 담은 입력 모델)
# assembly_tree::AssemblyTree - stored transforms of all parts and submodels
#   (assembly_tree: 모든 부품·하위모델의 저장된 위치/변환 정보를 담은 트리)
# model_schedule - encodes the partial ordering of assembly operations.
#   (model_schedule: 조립 작업들의 부분 순서(무엇을 먼저 해야 하는지)를 인코딩한 그래프)

export                  # 데모 실행에 쓰는 주요 함수 3개를 외부에 공개
    run_lego_demo,      # 레고 조립 데모 전체 실행
    list_projects,      # 사용 가능한 프로젝트(레고 모델) 목록
    get_project_params  # 특정 프로젝트의 파라미터 가져오기

# """ ... """ 로 코드 바로 위에 적는 문자열은 "docstring"(문서화 주석). 파이썬의 함수 첫 줄 docstring 과 같은 역할.
"""
    BuildStepID <: AbstractID
"""
# @with_kw : Parameters 패키지의 매크로. 이 struct 에 "키워드 인자 생성자"를 자동으로 만들어줌
#            → BuildStepID(id=3) 처럼 필드 이름을 지정해 생성 가능하게 됨.
# 이 struct 는 "조립 단계(build step)를 가리키는 ID"라는 하나의 정수를 감싼 타입. <: AbstractID = ID 종류 중 하나.
@with_kw struct BuildStepID <: AbstractID
    id::Int             # 실제 식별번호(정수)
end
"""
    SubModelPlanID <: AbstractID
"""
@with_kw struct SubModelPlanID <: AbstractID   # "하위 모델 계획"을 가리키는 ID 타입
    id::Int
end
"""
    SubFileRedID <: AbstractID
"""
@with_kw struct SubFileRefID <: AbstractID     # "하위 파일 참조"를 가리키는 ID 타입
    id::Int
end

"""
    DuplicateIDGenerator{K}

Generates duplicate IDs.
"""
# {K} 는 타입 매개변수 — "키(key)의 타입은 K 라는 빈칸으로 두고, 만들 때 정한다"는 뜻(예: K=String).
# 이 구조체의 의미: 같은 이름이 여러 번 나올 때 "이름-1", "이름-2" 처럼 고유 ID 를 찍어내는 발급기.
struct DuplicateIDGenerator{K}
    id_counts::Dict{K,Int}    # 각 원래 ID 가 지금까지 몇 번 나왔는지 세는 카운터(딕셔너리)
    id_map::Dict{K,K}         # 새로 만든 ID ↔ 원래 ID 의 대응 관계 저장
    # 아래는 "내부 생성자" — 이 타입을 만들 때 두 딕셔너리를 빈 상태로 초기화.
    # where {K} : "K 는 타입 매개변수"임을 알려주는 구문. new{K}(...) 는 실제 객체를 만드는 내부 호출.
    DuplicateIDGenerator{K}() where {K} = new{K}(
        Dict{K,Int}(),        # 빈 카운터
        Dict{K,K}(),          # 빈 대응표
    )
end
# 객체에서 K(키 타입)가 무엇인지 되돌려주는 헬퍼. `::DuplicateIDGenerator{K}` 는 값 이름 없이 타입만 받아 K 만 뽑음.
_id_type(::DuplicateIDGenerator{K}) where {K} = K
# (g::DuplicateIDGenerator)(id) : "객체를 함수처럼 호출"하는 정의(callable object). g("door") 처럼 부르면 이 코드 실행.
function (g::DuplicateIDGenerator)(id)
    k = get!(g.id_map, id, id)                       # id 가 대응표에 없으면 자기 자신을 넣고, 그 값을 k 로 가져옴
    g.id_counts[k] = get(g.id_counts, k, 0) + 1      # k 의 등장 횟수 +1 (없었으면 0에서 시작)
    new_id = string(k, "-", string(g.id_counts[k]))  # "k-횟수" 형태의 새 고유 문자열 ID 생성 (예: "door-2")
    g.id_map[new_id] = id                            # 새 ID 가 원래 어떤 id 에서 나왔는지 기록
    new_id                                           # 마지막 줄의 값이 곧 반환값(Julia 는 return 생략 가능)
end
# 그래프 g 에서 old_root 아래(또는 위) 서브트리 전체를 통째로 복제하는 함수.
# d=:out 은 기본값 — `:out` 은 "심볼"(고정 라벨, 파이썬의 문자열 상수 비슷). 방향(자식쪽/부모쪽)을 지정.
function duplicate_subtree!(g, old_root, d=:out)
    vtxs = [get_vtx(g, old_root)]                        # 복제 대상 정점 목록을 루트의 정점번호로 시작
    # bfs_tree 로 너비우선 탐색한 트리의 모든 엣지에서 도착점(e.dst)만 모아 vtxs 에 이어붙임 → 서브트리 전체 정점 수집
    append!(vtxs, collect(map(e -> e.dst, edges(bfs_tree(g, old_root; dir=d)))))
    new_ids = Dict{Int,_id_type(g)}()                   # 원래 정점번호 → 새로 만든 노드ID 매핑 저장용 딕셔너리
    for v in vtxs                                       # 수집한 각 정점에 대해
        old_node = get_node(g, v)                       # 원래 노드 객체를 가져와서
        new_node = add_node!(g, node_val(old_node))     # 그 값(내용)을 복사해 새 노드를 그래프에 추가
        new_ids[v] = node_id(new_node)                  # 원래 정점 v 가 어떤 새 ID 로 복제됐는지 기록
    end
    # 삼항 연산자 `조건 ? A : B` (파이썬의 A if 조건 else B). 방향에 따라 이웃 찾는 함수를 선택.
    f = d == :out ? outneighbors : inneighbors
    for v in vtxs                                       # 원래 정점들의 연결관계(엣지)를 새 노드들 사이에 그대로 재현
        for vp in f(g, v)                               # v 의 (방향에 맞는) 이웃 vp 들에 대해
            if d == :out
                add_edge!(g, new_ids[v], new_ids[vp])   # 자식쪽 복제: 새 v → 새 vp 엣지 추가
            else
                add_edge!(g, new_ids[vp], new_ids[v])   # 부모쪽 복제: 새 vp → 새 v 엣지 추가
            end
        end
    end
    return get_node(g, new_ids[get_vtx(g, old_root)])   # 복제된 서브트리의 새 루트 노드를 반환
end

"""
    MPDModelGraph{N,ID} <: AbstractCustomNDiGraph{CustomNode{N,ID},ID}

Graph to represent the modeling operations required to build a LDraw model.
Currently used both as an assembly tree and a "model schedule".
In the model schedule, the final model is the root of the graph, and its
ancestors are the operations building up thereto.
"""
# @with_kw_noshow : @with_kw 와 같지만(키워드 생성자 자동생성) 출력(show) 메서드는 안 만드는 버전.
# struct MPDModelGraph{N,ID} : 타입 매개변수 2개 — N(노드에 담는 값의 타입), ID(노드 식별자 타입).
# <: AbstractCustomNDiGraph{...} : "커스텀 방향그래프"의 하위 타입. 즉 이건 노드/엣지를 가진 그래프 자료구조.
# 의미: 레고 모델을 만드는 "작업들의 그래프"(조립 트리 겸 스케줄). `= 기본값` 은 생성 시 비워두면 들어갈 초기값.
@with_kw_noshow struct MPDModelGraph{N,ID} <: AbstractCustomNDiGraph{CustomNode{N,ID},ID}
    graph::DiGraph = DiGraph()                              # 실제 연결구조(방향그래프). 기본은 빈 그래프.
    nodes::Vector{CustomNode{N,ID}} = Vector{CustomNode{N,ID}}()  # 노드 객체들의 배열(각 노드는 값 N + ID 보유)
    vtx_map::Dict{ID,Int} = Dict{ID,Int}()                 # ID → 내부 정점번호(Int) 변환표
    vtx_ids::Vector{ID} = Vector{ID}() # maps vertex uid to actual graph node  # 정점번호 → 실제 ID (vtx_map 의 반대방향)
    id_generator::DuplicateIDGenerator{ID} = DuplicateIDGenerator{ID}()  # 중복 이름에 고유 ID 찍어주는 발급기
end
# create_node_id : 노드 값의 "타입에 따라 다른 동작"을 하는 함수(다중 디스패치). `v::타입` 으로 어떤 메서드를 쓸지 구분.
create_node_id(g, v::BuildingStep) = g.id_generator("BuildingStep")  # 조립단계: "BuildingStep-n" 식 고유 ID 발급
# 하위모델: 같은 이름 정점이 이미 있으면 고유 ID 새로 발급, 처음이면 모델 이름 자체를 ID 로 사용
create_node_id(g, v::SubModelPlan) = has_vertex(g, model_name(v)) ? g.id_generator(model_name(v)) : model_name(v)
create_node_id(g, v::SubFileRef) = g.id_generator(model_name(v))     # 파일참조: 모델 이름 기반 고유 ID 발급
# add_node!(g, val) : val 의 ID 를 먼저 만들고, ID 와 함께 그래프에 노드를 추가하는 2-인자 버전.
# where {N,ID} 와 val::N : "val 은 이 그래프의 노드 값 타입 N 과 같아야 한다"는 제약.
function add_node!(g::MPDModelGraph{N,ID}, val::N) where {N,ID}
    id = create_node_id(g, val)     # 값의 종류에 맞는 ID 생성
    add_node!(g, val, id)           # (값, ID) 를 받는 3-인자 버전 add_node! 호출해 실제로 추가
end

# function add_subfile_reference!(model_graph,ref::SubFileRef)
# end

"""
    add_build_step!(model_graph,build_step,parent=-1)

add a build step to the model_graph, and add edges from all children of the
parent step to the child.
        [   parent_step   ]
           |           |
        [input] ... [input]
           |           |
        [    build_step   ]
"""
# 조립 단계 하나를 그래프에 추가하고, 그 단계에 들어가는 입력 부품들과의 엣지를 연결.
# preceding_step=-1 : 이전 단계 ID(없으면 -1 = "없음" 표시).
function add_build_step!(model_graph, build_step::BuildingStep, preceding_step=-1)
    node = add_node!(model_graph, build_step)       # 이 조립단계 노드를 추가
    for line in build_step.lines                    # 이 단계에 포함된 각 부품 줄(line)에 대해
        input = add_node!(model_graph, line)        # 입력 부품 노드 추가
        add_edge!(model_graph, input, node)         # 입력 부품 → 이 조립단계 로 엣지(이 부품이 단계의 재료)
        add_edge!(model_graph, preceding_step, input)  # 이전 단계 → 입력 부품 으로 엣지(시간 순서 연결)
    end
    # if is_root_node(model_graph,node)             # (원작자가 주석처리해 둔 옛 코드 — 무시해도 됨)
    # 이전 단계가 실제로 존재하고 + 그게 말단 노드라면(뒤에 아무것도 없으면)
    if has_vertex(model_graph, preceding_step) && is_terminal_node(model_graph, preceding_step)
        add_edge!(model_graph, preceding_step, node) # 이전 단계 → 이번 단계 직접 연결 # Do I want this or not?(원작자 메모: 이게 맞나?)
    end
    node                                            # 추가한 단계 노드 반환(다음 호출에서 preceding_step 으로 쓰임)
end
# 하나의 하위모델(SubModelPlan)에 대한 부분그래프를 채우는 함수.
function populate_model_subgraph!(model_graph, model::SubModelPlan)
    n = add_node!(model_graph, model)               # 이 하위모델 자체를 노드로 추가
    preceding_step = -1                             # 첫 단계는 이전 단계가 없으므로 -1 로 시작
    for build_step in model.steps                   # 이 모델의 조립 단계들을 순서대로
        if !isempty(build_step.lines)               # 부품이 있는 단계만(빈 단계는 건너뜀)
            preceding_step = add_build_step!(model_graph, build_step, preceding_step)  # 단계 추가하고, 그 노드를 다음 단계의 "이전 단계"로 갱신(사슬처럼 연결)
        end
    end
    add_edge!(model_graph, preceding_step, n)       # 마지막 단계 → 모델 노드 로 엣지(모든 단계가 끝나면 모델 완성)
end

# 하위모델들 사이의 "의존 관계 그래프"를 만든다(어떤 모델이 다른 모델을 부품으로 쓰는지).
function construct_submodel_dependency_graph(model)
    g = NGraph{DiGraph,SubModelPlan,String}()       # 노드값=SubModelPlan, ID=String 인 방향그래프 생성
    for (k, m) in model.models                      # model.models 딕셔너리 순회 — k=모델이름, m=모델내용
        n = add_node!(g, m, k)                       # 각 모델을 노드로 추가(ID 는 이름 k)
    end
    for (k, m) in model.models                      # 다시 각 모델을 돌면서
        for s in m.steps                            # 모델의 각 조립단계 s
            for line in s.lines                     # 단계 안의 각 부품 줄 line
                if has_vertex(g, model_name(line))  # 그 줄이 가리키는 게 (부품이 아니라) 다른 하위모델이면
                    add_edge!(g, model_name(line), k)  # "그 하위모델 → 현재모델 k" 의존 엣지 추가
                end
            end
        end
    end
    return g                                        # 완성된 의존 그래프 반환
end

"""
Copy all submodel trees into the trees of their parent models.
"""
# 각 하위모델의 트리를, 그것을 참조하는 상위모델 트리 안으로 복사해 넣는다(공유 모델을 펼쳐 독립 사본으로).
function copy_submodel_trees!(sched, model)
    sub_model_dependencies = construct_submodel_dependency_graph(model)  # 의존 그래프 먼저 구성
    # topological_sort_by_dfs : 의존순서대로 정렬(먼저 만들어져야 할 것부터). 그 순서로 정점 vp 순회.
    for vp in topological_sort_by_dfs(sub_model_dependencies)
        k = get_vtx_id(sub_model_dependencies, vp)  # 정점번호 vp 에 해당하는 모델 이름 k
        # @assert 조건 "메시지" : 조건이 거짓이면 메시지와 함께 에러로 중단(개발 중 가정 점검용). $k 는 문자열 안에 변수 끼워넣기.
        @assert has_vertex(sched, k) "SubModelPlan $k isn't in sched, but should be"
        for v in Graphs.vertices(sched)             # 스케줄의 모든 정점을 검사
            node = get_node(sched, v)               # 정점의 노드 객체
            val = node_val(node)                    # 노드가 담은 값
            if isa(val, SubFileRef)                 # 그 값이 "파일 참조"이고 (isa = 타입 검사, 파이썬 isinstance)
                if model_name(val) == k             # 그 참조가 가리키는 모델이 현재 k 와 같으면
                    sub_model_plan = duplicate_subtree!(sched, k, :in)  # k 의 서브트리(부모쪽 :in)를 복제
                    add_edge!(sched, sub_model_plan, v) # 복제본 → 참조노드 로 연결(교체 대신 앞에 끼워넣음) # add before instead of replacing
                end
            end
        end
    end
    sched                                           # 수정된 스케줄 반환
end

"""
    update_build_step_parents!(model_spec)

Ensure that all `BuildingStep` nodes have the correct parent (submodel) name.
"""
# 모든 조립단계(BuildingStep) 노드가 자신이 속한 올바른 부모(하위모델) 이름을 갖도록 바로잡는다.
function update_build_step_parents!(model_spec)
    # backup_descendants : 각 노드에서 "조건을 만족하는 가장 가까운 후손"을 찾아 매핑. 여기선 SubModelPlan 을 찾음.
    # n -> matches_template(...) : 익명함수(파이썬 lambda n: ...). n 이 SubModelPlan 형태인지 검사하는 조건.
    descendant_map = backup_descendants(model_spec,
        n -> matches_template(SubModelPlan, n))
    for v in Graphs.vertices(model_spec)            # 모든 정점 순회
        node = get_node(model_spec, v)
        if matches_template(BuildingStep, node)     # 이 노드가 조립단계라면
            node = replace_node!(model_spec,        # 그 노드를 새 BuildingStep 으로 교체
                BuildingStep(node_val(node), descendant_map[node_id(node)]),  # 기존 값 + 올바른 부모이름 으로 재생성
                node_id(node)                       # 교체 대상 노드의 ID
            )
            @assert node_val(node).parent == descendant_map[node_id(node)]  # 부모가 제대로 설정됐는지 점검
        end
    end
    model_spec                                      # 수정된 명세 반환
end

"""
    construct_model_spec(model)

Edges go forward in time.
"""
# 위 단계들을 모두 묶어, 원본 model 로부터 완전한 "모델 명세 그래프"를 만든다(이 절의 최종 진입 함수).
function construct_model_spec(model)
    # Union{A,B,C} : "셋 중 아무 타입이나 가능"하다는 합집합 타입. 노드 값이 세 종류 중 하나일 수 있음을 명시.
    NODE_VAL_TYPE = Union{SubModelPlan,BuildingStep,SubFileRef}
    spec = MPDModelGraph{NODE_VAL_TYPE,String}()    # 빈 명세 그래프 생성(노드값 타입 위 Union, ID=String)
    for (k, m) in model.models                      # 각 하위모델을
        populate_model_subgraph!(spec, m)           # 그래프에 부분그래프로 채워넣음
    end
    copy_submodel_trees!(spec, model)               # 공유 하위모델을 독립 사본으로 펼침
    update_build_step_parents!(spec)                # 각 단계의 부모 이름 보정
    return spec                                     # 완성된 명세 반환
end


"""
    extract_single_model(sched::S,model_key) where {S<:MPDModelGraph}

From a model schedule with (potentially) multiple distinct models, extract just
the model graph with root id `model_key`.
"""
# 여러 모델이 섞인 명세에서 model_key 를 루트로 하는 "한 개의 모델"만 떼어낸다.
# where {S<:MPDModelGraph} : 입력 spec 의 타입을 S 라 부르고(MPDModelGraph 의 하위타입), 같은 타입으로 결과를 만들기 위함.
# model_key 기본값 = 가장 큰 트리의 루트 ID (안 주면 제일 큰 모델을 자동 선택).
function extract_single_model(spec::S,
    model_key=get_vtx_id(spec, get_biggest_tree(spec))) where {S<:MPDModelGraph}
    @assert has_vertex(spec, model_key)             # 그 키가 그래프에 실제 있는지 점검
    new_spec = S(id_generator=spec.id_generator)    # 같은 타입의 빈 그래프 생성(ID 발급기는 공유)
    root = get_vtx(spec, model_key)                 # 루트의 정점번호
    add_node!(new_spec, get_node(spec, root), get_vtx_id(spec, root))  # 루트 노드를 새 그래프에 먼저 복사
    # reverse(topological_sort_by_dfs(...)) : 위상정렬을 뒤집어 루트→하위 방향으로 순회
    for v in reverse(topological_sort_by_dfs(spec))
        dst_id = get_vtx_id(spec, v)                # 현재 정점의 ID
        if !has_vertex(new_spec, dst_id)            # 새 그래프에 아직 없는 노드면 (이 모델에 속하지 않음)
            continue                                # 건너뜀
        end
        if !has_vertex(new_spec, dst_id)            # (중복 체크 — 위와 같아 사실상 항상 거짓, 안전장치)
            transplant!(new_spec, spec, dst_id)     # 원본에서 노드를 그대로 옮겨 심기
        end
        for v2 in inneighbors(spec, dst_id)         # 현재 노드로 들어오는(부모) 이웃들에 대해
            src_id = get_vtx_id(spec, v2)
            if !has_vertex(new_spec, src_id)        # 그 부모가 새 그래프에 없으면
                transplant!(new_spec, spec, src_id) # 옮겨 심고
            end
            add_edge!(new_spec, src_id, dst_id)     # 부모→자식 엣지 복원
        end
    end
    new_spec                                        # 떼어낸 단일 모델 그래프 반환
end

# 아래 함수들은 "어떤 종류의 노드 뒤/앞에 어떤 종류가 올 수 있는가"의 규칙을 타입별로 정의(다중 디스패치).
# 인자를 `::타입` 으로만 써서 값은 무시하고 타입만으로 어느 규칙을 적용할지 고름.
# Edges for Project Spec. TODO dispatch on graph type
validate_edge(::SubModelPlan, ::SubFileRef) = true    # 하위모델 → 파일참조 엣지: 허용
validate_edge(::BuildingStep, ::SubModelPlan) = true  # 조립단계 → 하위모델: 허용
validate_edge(::BuildingStep, ::BuildingStep) = true  # 조립단계 → 조립단계: 허용
validate_edge(::BuildingStep, ::SubFileRef) = true    # 조립단계 → 파일참조: 허용
validate_edge(::SubFileRef, ::BuildingStep) = true    # 파일참조 → 조립단계: 허용

# eligible_successors : "뒤에 올 수 있는(허용) 노드 종류 => 최대 개수" 딕셔너리. predecessors 는 "앞에".
eligible_successors(::SubFileRef) = Dict(BuildingStep => 1)                     # 파일참조 뒤엔 조립단계 1개까지
eligible_predecessors(::SubFileRef) = Dict(BuildingStep => 1, SubModelPlan => 1) # 파일참조 앞엔 조립단계/하위모델 각 1
required_successors(::SubFileRef) = Dict(BuildingStep => 1)                     # 반드시 뒤따라야 하는: 조립단계 1
required_predecessors(::SubFileRef) = Dict()                                    # 반드시 앞서야 하는 것: 없음

eligible_successors(::SubModelPlan) = Dict(SubFileRef => 1)      # 하위모델 뒤엔 파일참조 1
eligible_predecessors(::SubModelPlan) = Dict(BuildingStep => 1)  # 하위모델 앞엔 조립단계 1
required_successors(::SubModelPlan) = Dict()                     # 필수 후행: 없음
required_predecessors(::SubModelPlan) = Dict(BuildingStep => 1)  # 필수 선행: 조립단계 1

# typemax(Int) : Int 가 가질 수 있는 최대값 → "개수 제한 없음"이라는 뜻으로 사용.
eligible_successors(::BuildingStep) = Dict(SubFileRef => typemax(Int), SubModelPlan => 1, BuildingStep => 1)  # 단계 뒤: 파일참조 무제한, 하위모델/단계 각 1
# LDrawParser.n_lines(n) : 이 조립단계에 들어있는 부품 줄 수 → 그만큼의 파일참조가 앞에 올 수 있음
eligible_predecessors(n::BuildingStep) = Dict(SubFileRef => LDrawParser.n_lines(n), BuildingStep => 1)
required_successors(::BuildingStep) = Dict(Union{SubModelPlan,BuildingStep} => 1)  # 필수 후행: 하위모델 또는 단계 중 1
required_predecessors(n::BuildingStep) = Dict(SubFileRef => LDrawParser.n_lines(n))  # 필수 선행: 부품 줄 수만큼의 파일참조



"""
    construct_assembly_graph(model)

Construct an assembly graph, where each `SubModelPlan` has an outgoing edge to
each `SubFileRef` pointing to one of its components.
"""
# 조립 그래프 생성: 각 하위모델이 자신의 구성부품(파일참조)들로 향하는 엣지를 갖는 단순한 트리.
function construct_assembly_graph(model)
    NODE_VAL_TYPE = Union{SubModelPlan,SubFileRef}  # 노드 값은 하위모델 또는 파일참조 둘 중 하나
    model_graph = MPDModelGraph{NODE_VAL_TYPE,String}()  # 빈 그래프 생성
    for (k, m) in model.models                      # 각 모델 (이름 k, 내용 m)
        n = add_node!(model_graph, m, k)            # 모델을 노드로 추가
        for s in m.steps                            # 모델의 각 단계
            for line in s.lines                     # 단계의 각 부품 줄
                np = add_node!(model_graph, line) #,id_generator(line.file))  # 부품을 노드로 추가
                add_edge!(model_graph, n, np)       # 모델 → 부품 엣지(이 부품은 이 모델 소속)
            end
        end
    end
    # copy_submodel_trees!(model_graph,model)        # (주석처리됨 — 여기선 사용 안 함)
    return model_graph
end

# geom_node : 입력 타입에 따라 적절한 기하(geometry) 노드를 만든다.
geom_node(m::DATModel) = GeomNode(LDrawParser.extract_geometry(m))  # 부품(.dat): 실제 3D 형상을 추출해 담음
geom_node(m::SubModelPlan) = GeomNode(nothing)                     # 하위모델: 자체 형상 없음(자식들로 구성) → nothing
# 모델과 파일참조를 받아, 참조가 모델이면 모델의, 부품이면 부품의 기하 노드를 돌려줌.
function geom_node(model::MPDModel, ref::SubFileRef)
    if has_model(model, ref.file)                   # 참조 대상이 하위모델이면
        return geom_node(get_model(model, ref.file))
    elseif has_part(model, ref.file)               # 부품이면
        return geom_node(get_part(model, ref.file))
    end
    throw(ErrorException("Referenced file $(ref.file) is not in model"))  # 둘 다 아니면 에러 발생(throw = 예외 던지기)
    # @warn "Referenced file $(ref.file) is not in model"   # (옛 코드 — 에러 대신 경고만 하던 버전)
    GeomNode(nothing)                               # (위에서 throw 하므로 도달하지 않는 줄)
end

"""
    build_id_map(model::MPDModel,spec::MPDModelGraph)

Constructs a `Dict` mapping from `AbstractID <=> String` to keep track of the
correspondence between ids in different graphs. Only the following id types are
mapped:
- ObjectID <=> SubFileRef (if the ref points to a model, not a part)
- AssemblyID <=> SubModelPlan
"""
# 서로 다른 그래프의 ID 들을 양방향으로 연결하는 대응표(id_map)를 만든다.
# (조립체 SubModelPlan ↔ AssemblyID, 부품 SubFileRef ↔ ObjectID)
function build_id_map(model::MPDModel, spec::MPDModelGraph)
    id_map = Dict{Union{String,AbstractID},Union{String,AbstractID}}()  # 키/값 모두 문자열 또는 ID 가능한 딕셔너리
    # enumerate : (번호 v, 원소 node) 쌍으로 순회 (파이썬 enumerate 와 동일)
    for (v, node) in enumerate(get_nodes(spec))
        val = node_val(node)                        # 노드 값
        new_id = nothing                            # 새로 부여할 ID (없으면 nothing)
        if isa(val, SubFileRef)                     # 값이 파일참조면
            if LDrawParser.has_model(model, val.file)
                # new_id = get_unique_id(AssemblyID)  # (모델 참조는 여기서 ID 안 부여 — 부모가 처리)
            elseif LDrawParser.has_part(model, val.file)  # 부품 참조면
                new_id = get_unique_id(ObjectID)    # 새 ObjectID(물체 ID) 발급
            else
                continue                            # 둘 다 아니면 건너뜀
            end
        elseif isa(val, SubModelPlan)               # 값이 하위모델이면
            new_id = get_unique_id(AssemblyID)      # 새 AssemblyID(조립체 ID) 발급
        end
        if !(new_id === nothing)                    # ID 가 부여됐으면 (=== 는 "정확히 같은지" 비교)
            id_map[new_id] = node_id(node)          # 새ID → 원래 노드ID
            id_map[node_id(node)] = new_id          # 원래 노드ID → 새ID (양방향 등록)
        end
    end
    id_map                                          # 완성된 대응표 반환
end

"""
    get_referenced_component(model_spec,scene_tree,id_map,node)

A hacky utility for retrieving the component added to an assembly by
node::CustomNode{SubFileRef,...}. Currently necessary because some
SubFileRef nodes reference an object (id_map[object_id] <=> id_map[ref_id]),
whereas other SubFileRef nodes reference the assembly encoded by their direct parent.
"""
# 파일참조 노드가 실제로 가리키는 "구성요소(부품 또는 조립체)의 ID"를 찾아 돌려준다.
function get_referenced_component(model_spec, id_map, node)
    @assert matches_template(SubFileRef, node)      # 입력이 파일참조 노드인지 확인
    # node = get_node(model_spec,id)                 # (옛 코드)
    for v in inneighbors(model_spec, node)          # 이 노드로 들어오는 부모들을 살펴서
        input = get_node(model_spec, v)
        if matches_template(SubModelPlan, input)    # 부모가 하위모델이면 (그 모델이 가리키는 대상)
            return id_map[get_vtx_id(model_spec, v)]  # 그 하위모델의 대응 ID 반환
        end
    end
    return get(id_map, node_id(node), nothing)      # 아니면 이 노드 자신의 대응 ID(없으면 nothing) 반환
end

"""
    get_build_step_components(model_spec,id_map,step)

Given step::CustomNode{BuildingStep,...}, return the set of AbstractIDs pointing
to all of the components to be added to the parent assembly at that building
step.
"""
# 한 조립단계에서 부모 조립체에 추가되는 모든 구성요소의 ID 집합을 반환한다.
function get_build_step_components(model_spec, id_map, step)
    @assert matches_template(BuildingStep, step)    # 입력이 조립단계인지 확인
    part_ids = Set{Union{AssemblyID,ObjectID}}()    # 결과 ID 들을 담을 집합(Set = 중복 없는 모음)
    for v in inneighbors(model_spec, step)          # 이 단계로 들어오는 노드(입력 부품)들에 대해
        child = get_node(model_spec, v)
        if matches_template(SubFileRef, child)      # 그게 파일참조면
            push!(part_ids,                         # 그것이 가리키는 구성요소 ID 를 집합에 추가
                get_referenced_component(model_spec, id_map, child))
        end
    end
    return part_ids
end

"""
    construct_assembly_tree(model::MPDModel,spec::MPDModelGraph,

Construct an assembly_tree::NTree{SceneNode,AbstractID}, a precursor to
SceneTree.
"""
# 명세 그래프로부터 "조립 트리(assembly_tree)"를 만든다 — 각 부품/조립체가 부모에 대해 갖는 상대 위치까지 담음.
# id_map 인자는 기본값으로 build_id_map(...) 을 자동 계산(안 넘기면 알아서 만듦).
function construct_assembly_tree(model::MPDModel, spec::MPDModelGraph,
    id_map=build_id_map(model, spec),
)
    assembly_tree = NTree{SceneNode,AbstractID}()   # 노드값=SceneNode, ID=AbstractID 인 트리 생성
    parent_map = backup_descendants(spec, n -> matches_template(SubModelPlan, n))  # 각 노드의 소속 하위모델(부모) 찾기
    for v in reverse(topological_sort_by_dfs(spec))  # 루트→잎 방향으로 순회(부모가 먼저 생기도록)
        node = get_node(spec, v)
        id = node_id(node)
        haskey(id_map, id) ? nothing : continue     # 대응표에 없는 노드는 건너뜀(삼항식을 if-continue 처럼 사용)
        new_id = id_map[id]                          # 이 노드의 새(조립트리용) ID
        val = node_val(node)
        ref = nothing                                # 부모에 붙일 때 쓸 변환정보 출처(나중에 채움)
        parent_id = id_map[parent_map[id]]           # 부모의 새 ID
        if isa(val, SubModelPlan)                    # 노드가 하위모델(=조립체)이면
            g = geom_node(val)                       # 형상 노드(조립체는 비어있음)
            add_node!(assembly_tree, AssemblyNode(new_id, g), new_id)  # 조립체 노드로 트리에 추가
            is_terminal_node(spec, v) ? continue : nothing  # 최상위(부모 없는) 모델이면 여기서 끝(부모에 안 붙임)
            # retrieve parent SubFileRef               # 이 조립체를 가리키는 부모 파일참조를 찾아옴
            ref_node = get_node(spec, outneighbors(spec, v)[1])  # 나가는 첫 이웃 = 자신을 참조하는 노드
            ref = node_val(ref_node)
            @assert isa(ref, SubFileRef) "ref is $(ref)"  # 그게 파일참조가 맞는지 확인
            parent_id = id_map[parent_map[node_id(ref_node)]]  # 진짜 부모 ID 는 그 참조노드의 부모
        elseif isa(val, SubFileRef)                  # 노드가 파일참조면
            if has_model(model, val.file)
                continue # Don't add assembly here    # 모델 참조는 위 가지에서 처리하므로 여기선 건너뜀
            else
                has_part(model, val.file)            # (부품인지 확인 호출 — 반환값은 사용 안 함)
                # Adding an object only               # 개별 물체(부품)만 추가
                @info "SUB FILE PART: $(node_id(node))"  # @info : 정보 로그 출력
                p = get_part(model, val.file)        # 실제 부품 데이터
                g = geom_node(p)                     # 부품의 3D 형상 노드
                add_node!(assembly_tree, ObjectNode(new_id, g), new_id)  # 물체 노드로 트리에 추가
                ref = val                            # 변환정보는 이 참조에서 가져옴
            end
        elseif isa(val, BuildingStep)                # 조립단계 노드는
            continue                                 # 조립트리에 직접 안 넣음(건너뜀)
        end
        @info "Attaching $(id_map[parent_id]) => $(id_map[new_id])"  # 부모에 붙인다는 로그
        parent = node_val(get_node(assembly_tree, parent_id))       # 부모 조립체 객체
        t = LDrawParser.build_transform(ref)         # 참조로부터 부모 기준 상대 변환(위치/회전) 계산
        add_component!(parent, new_id => t)          # 부모에 "이 자식 => 변환" 을 구성요소로 등록 (=> 는 키=>값 쌍)
        set_child!(assembly_tree, parent_id, new_id) # 트리에서 부모-자식 관계 설정
        @info "$(id_map[parent_id]) => $(id_map[new_id]) is $(has_edge(assembly_tree,parent_id,new_id))"  # 연결 결과 로그
    end
    assembly_tree                                    # 완성된 조립 트리 반환
end

"""
    convert_to_scene_tree(assembly_tree,set_children=true)

Convert an assembly tree to a `SceneTree`.
"""
# 조립 트리를 실제 시뮬레이션/렌더링에 쓰는 SceneTree(장면 트리)로 변환한다.
# 함수 인자에서 `;` 뒤는 키워드 인자 — set_children=false 처럼 이름 붙여 호출. ::Bool 은 참/거짓 타입.
function convert_to_scene_tree(assembly_tree; set_children::Bool=true)
    scene_tree = SceneTree()                        # 빈 장면 트리 생성
    for n in get_nodes(assembly_tree)               # 조립 트리의 모든 노드를
        add_node!(scene_tree, node_val(n))          # 장면 트리에 복사
    end
    if set_children                                 # 부모-자식 관계도 옮길지 여부
        for e in edges(assembly_tree)               # 조립 트리의 각 엣지에 대해
            src_id = get_vtx_id(assembly_tree, edge_source(e))  # 엣지 시작(부모) ID
            dst_id = get_vtx_id(assembly_tree, edge_target(e))  # 엣지 끝(자식) ID
            # set_child! will ensure that the full tree is correctly set up.
            set_child!(scene_tree, src_id, dst_id)  # 장면 트리에 부모-자식 관계 설정
        end
    end
    return scene_tree
end

"""
    construct_spatial_index(scene_tree)

Construct a `SpatialIndexing.RTree` for efficiently finding neighbors of an
    object in the assembly.
"""
# 공간 인덱스(R-Tree)를 만든다 — 3D 공간에서 어떤 물체의 이웃을 빠르게 찾기 위함.
# frontier 기본값 = 모든 루트 노드(탐색 시작점들).
function construct_spatial_index(scene_tree, frontier=get_all_root_nodes(scene_tree))
    # RTree{Float64,3} : 좌표는 실수, 3차원. (Int, AbstractID) 는 저장하는 부가데이터 타입. capacity 는 트리 용량 설정.
    rtree = RTree{Float64,3}(Int, AbstractID, leaf_capacity=10, branch_capacity=10)
    jump_to_final_configuration!(scene_tree)        # 모든 부품을 "완성된 최종 위치"로 즉시 이동(경계상자 계산 위해)
    bounding_rects = Dict{AbstractID,SpatialIndexing.Rect}()  # 각 노드의 경계상자(bounding box) 저장용
    for v in BFSIterator(scene_tree, frontier)      # frontier 부터 너비우선으로 모든 노드 순회
        node = get_node(scene_tree, v)
        geom = get_cached_geom(node, BaseGeomKey())  # 노드의 (캐시된) 기본 형상 가져오기
        if geom === nothing                          # 형상이 없으면(조립체 등)
            continue                                 # 건너뜀
        end
        pt_min = [1.0, 1.0, 1.0]                     # 경계상자 최소점 초기값(곧 실제 좌표로 갱신됨)
        pt_max = -1 * pt_min                          # 최대점 초기값 [-1,-1,-1]
        for pt in coordinates(geom)                  # 형상의 모든 꼭짓점 좌표에 대해
            for i in 1:3                             # x,y,z 각 축에 대해 (1:3 = 1,2,3 범위)
                pt_min[i] = min(pt[i], pt_min[i])    # 최소값 갱신
                pt_max[i] = max(pt[i], pt_max[i])    # 최대값 갱신
            end
        end
        rect = SpatialIndexing.Rect(                 # 위에서 구한 min/max 로 3D 경계상자 생성
            (pt_min[1], pt_min[2], pt_min[3]),
            (pt_max[1], pt_max[2], pt_max[3]),
        )
        bounding_rects[node_id(node)] = rect         # 노드 ID → 경계상자 저장
        insert!(rtree, rect, v, node_id(node))       # R-Tree 에 경계상자와 노드정보 삽입
    end
    rtree, bounding_rects                            # (R-Tree, 경계상자표) 두 값을 함께 반환(튜플)
end

"""
    get_candidate_mating_parts(rtree,id)

Return the set of ids whose bounding rectangles overlap with
"""
# 주어진 물체(id)의 경계상자와 겹치는 다른 물체들의 ID 집합을 반환(맞닿을 후보 부품 찾기).
function get_candidate_mating_parts(rtree, bounding_rects, id)
    rect = bounding_rects[id]                        # 이 물체의 경계상자
    neighbor_ids = Set{AbstractID}()                 # 결과 이웃 ID 집합
    for el in iterate(intersects_with(rtree, rect))  # R-Tree 에서 이 상자와 교차하는 항목들 순회
        push!(neighbor_ids, el.val)                  # 각 항목의 값(노드 ID)을 집합에 추가
    end
    return neighbor_ids
end

"""
    identify_closest_surfaces(geom,neighbor_geom,ϵ=1e-4)

Find the geometry elements (line, triangle, quadrilateral) of `geom` and
`neighbor_geom` that are within a distance `ϵ` of each other.
It is assumed that `geom` and `neighbor_geom` are both `Vector{GeometryBasics.Ngon}`
"""
# 두 형상에서 서로 거리 ϵ(아주 작은 값) 이내로 가까운 면(line/삼각형/사각형) 쌍들을 찾는다.
function identify_closest_surfaces(geom, neighbor_geom)
    pairs = Vector{Tuple{Int,Int}}()                 # 가까운 (i,j) 인덱스 쌍을 담을 배열
    for (i, a) in enumerate(geom)                    # 첫 형상의 각 면 a (번호 i)
        for (j, b) in enumerate(neighbor_geom)       # 이웃 형상의 각 면 b (번호 j)
            d = distance(a, b)                       # 두 면 사이 거리
            if d < ϵ                                 # ϵ 보다 가까우면 (ϵ 은 그리스문자 epsilon — 변수 이름)
                push!(pairs, a, b)                   # 쌍 목록에 추가 (주: 코드상 a,b 를 직접 넣는 미완성 부분)
            end
        end
    end
end

"""
    compute_separating_hyperplane(ptsA,ptsB)

Find the optimal separating hyperplane between two point sets
"""
# 두 점집합(ptsA, ptsB)을 가장 잘 나누는 "분리 초평면"의 법선벡터를 최적화로 구한다.
function compute_separating_hyperplane(ptsA, ptsB, dim=3)
    model = JuMP.Model(default_geom_optimizer())     # 최적화 문제 모델 생성(기본 기하 솔버 사용)
    set_optimizer_attributes(model, default_geom_optimizer_attributes()...)  # 솔버 옵션 설정 (... 는 인자 펼치기/splat)
    @variable(model, x[1:dim])                       # 결정변수 x: 길이 dim 의 벡터(초평면 법선) — @variable 은 JuMP 매크로
    @constraint(model, [1.0; x] in SecondOrderCone())  # 제약: x 의 크기를 1 이하로(2차 원뿔 제약, 정규화 역할)
    @variable(model, a >= 0)                         # 보조변수 a (≥0)
    for pt in ptsA                                   # A 의 모든 점에 대해
        @constraint(model, a >= dot(x, pt))          # a 는 A 점들의 x 방향 투영의 최댓값 이상
    end
    @variable(model, b >= 0)                         # 보조변수 b (≥0)
    for pt in ptsB                                   # B 의 모든 점에 대해
        @constraint(model, b <= dot(x, pt))          # b 는 B 점들의 투영의 최솟값 이하
    end
    @constraint(model, a >= b)                       # A 쪽이 B 쪽보다 (투영상) 앞에 오도록
    @objective(model, Min, a - b)                    # 목적: a-b 최소화(두 집합 간 간격을 팽팽하게)
    optimize!(model)                                 # 최적화 실행
    if !(primal_status(model) == MOI.FEASIBLE_POINT)  # 해를 제대로 못 찾았으면
        @warn "Failed to compute optimal separating hyperplane"  # 경고 출력
    end
    return normalize(value.(x))                      # 구한 x 값을 정규화해 반환. value.(x) 의 `.` 은 원소별 적용(브로드캐스트)
end

# 아래는 GeometryBasics 패키지의 함수들에 "이 프로젝트 전용 동작"을 추가(확장)하는 부분.
# `GeometryBasics.함수이름` 처럼 다른 패키지 함수에 우리 타입용 메서드를 덧붙이는 것을 "메서드 확장"이라 함.
# decompose : 다각형(Ngon)을 삼각형 면들로 쪼갠다. ::Type{...} 은 "값이 아니라 타입 자체"를 인자로 받는 표기.
function GeometryBasics.decompose(
    ::Type{TriangleFace{Int}},                       # 무엇으로 쪼갤지: 삼각형 면(정수 인덱스)
    n::GeometryBasics.Ngon{3,Float64,N}) where {N}   # 입력: 3D, 실수, 꼭짓점 N개인 다각형
    return SVector{N - 1,TriangleFace{Int}}(         # N개 꼭짓점이면 N-1개의 삼각형이 나옴(부채꼴 분할)
        TriangleFace{Int}(1, i, i + 1) for i in 1:N-1  # 첫 점(1)을 기준으로 (1,i,i+1) 삼각형 생성
    )
end
# 다각형을 점들로 분해 — 그냥 내부 점 목록을 그대로 반환.
function GeometryBasics.decompose(
    ::Type{Point{3,Float64}},
    n::GeometryBasics.Ngon)
    return n.points
end
# faces : 사각형(꼭짓점 4개)을 삼각형 2개로 나눈 면 인덱스 반환.
GeometryBasics.faces(n::GeometryBasics.Ngon{3,Float64,4}) = [
    TriangleFace{Int}(1, 2, 3), TriangleFace{Int}(1, 3, 4)
]
# 삼각형(꼭짓점 3개)은 면이 그대로 하나.
GeometryBasics.faces(n::GeometryBasics.Ngon{3,Float64,3}) = [
    TriangleFace{Int}(1, 2, 3)
]

# 여러 형상이 든 배열의 좌표를 한 줄로 펼쳐 모음(flatten). map(coordinates, v) 는 각 원소에 coordinates 적용.
GeometryBasics.coordinates(v::AbstractVector) = collect(Base.Iterators.flatten(map(coordinates, v)))

# 위와 비슷하나 "Ngon 배열" 전용 버전 — 각 형상의 좌표를 세로로 이어붙임(vcat). `...` 는 결과들을 인자로 펼침.
function GeometryBasics.coordinates(v::AbstractVector{G}) where {N,G<:GeometryBasics.Ngon{3,Float64,N}}
    vcat(map(coordinates, v)...)
end
# Ngon 배열의 면 인덱스를 모음 — i번째 형상의 면 인덱스에 (i-1)*N 만큼 더해 전체 통합 인덱스로 맞춤(.+ 는 원소별 덧셈).
function GeometryBasics.faces(v::AbstractVector{G}) where {N,G<:GeometryBasics.Ngon{3,Float64,N}}
    vcat(map(i -> map(f -> f .+ ((i - 1) * N), faces(v[i])), 1:length(v))...)
end
# 위와 같은 일을 하되 형상마다 꼭짓점 수가 다를 수 있는 일반 버전 — 누적 오프셋 i 를 직접 추적.
function GeometryBasics.faces(v::AbstractVector{G}) where {G<:GeometryBasics.Ngon}
    face_vec = Vector{TriangleFace{Int}}()           # 결과 면 배열
    i = 0                                            # 현재까지의 인덱스 오프셋
    for element in v                                 # 각 형상에 대해
        append!(face_vec, map(f -> f .+ i, faces(element)))  # 그 형상의 면 인덱스에 오프셋 더해 누적
        i = face_vec[end].data[3]                    # 마지막 면의 세 번째 꼭짓점 번호로 오프셋 갱신
    end
    return face_vec
end

end   # module ConstructionBots 끝 (맨 위 `module ConstructionBots` 와 짝)
