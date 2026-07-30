# export : 아래 이름들을 `using ConstructionBots` 한 외부 코드에서 모듈명 없이 바로 쓰게 공개.
# 이 파일은 "조립 스케줄"의 노드 종류(술어=predicate)들과 그 선후관계 규칙을 정의한다.
export
    start_config,           # 노드의 시작 배치(위치/자세) 반환 함수
    goal_config,            # 노드의 목표 배치 반환 함수
    cargo_start_config,     # 화물(cargo)의 시작 배치 반환 함수
    cargo_goal_config,      # 화물의 목표 배치 반환 함수
    cargo_deployed_config,  # 화물이 내려놓인(배치된) 상태의 배치
    cargo_loaded_config,    # 화물이 실린(적재된) 상태의 배치
    entity,                 # 노드가 다루는 실체(로봇/부품/조립체 등) 반환
    ConstructionPredicate,  # 모든 스케줄 노드의 최상위 추상 타입
    EntityConfigPredicate,  # "어떤 실체가 한 배치에 정지해 있음"을 뜻하는 노드들의 추상 타입
    RobotStart,             # 로봇 시작 상태 노드
    ObjectStart,            # 부품(object) 시작 상태 노드
    AssemblyComplete,       # 조립체 완성 상태 노드
    AssemblyStart,          # 조립체 조립 시작 노드
    EntityGo,               # "실체가 한 배치에서 다른 배치로 이동"을 뜻하는 노드들의 추상 타입
    RobotGo,                # 로봇 이동 노드
    TransportUnitGo,        # 운반팀(여러 로봇이 화물을 든 단위) 이동 노드
    LiftIntoPlace,          # 부품/조립체를 제자리에 들어올려 놓는 노드
    FormTransportUnit,      # 운반팀 구성(로봇들이 화물 아래 모여 결합) 노드
    DepositCargo,           # 화물을 내려놓는 노드
    BuildPhasePredicate,    # "조립 단계(build phase)"를 가리키는 노드들의 추상 타입
    OpenBuildStep,          # 조립 단계 시작 표시 노드
    CloseBuildStep,         # 조립 단계 종료 표시 노드
    ProjectComplete         # 프로젝트 전체 완료 노드


"""
    abstract type ConstructionPredicate

Abstract type for ConstructionSchedule nodes.
"""
# abstract type : "직접 객체를 만들 순 없지만 여러 구체 타입의 공통 부모" 역할을 하는 타입(파이썬 추상기반클래스 비슷).
# 아래 모든 스케줄 노드 타입은 결국 이 ConstructionPredicate 의 하위 타입이 된다. `end` 로 정의 끝.
abstract type ConstructionPredicate end
start_config(n) = n.start_config   # 기본 동작: 노드 n 의 start_config 필드를 그대로 반환 (파이썬 n.start_config)
goal_config(n) = n.goal_config     # 기본 동작: 노드 n 의 goal_config 필드 반환
entity(n) = n.entity               # 기본 동작: 노드 n 의 entity 필드(다루는 실체) 반환
# add_node! : ConstructionPredicate 노드를 그래프에 넣을 때 node_id(n) 으로 ID 를 자동 계산해 추가하는 메서드.
add_node!(g::AbstractCustomNGraph, n::ConstructionPredicate) = add_node!(g, n, node_id(n))
get_vtx(g::AbstractCustomNGraph, n::ConstructionPredicate) = get_vtx(g, node_id(n))  # 노드 ID 로 정점번호 조회

# for op in (:심볼,...) + @eval : 메타프로그래밍(코드로 코드를 생성). 함수 이름들을 한꺼번에 정의하는 반복문.
# :start_config 처럼 콜론 붙인 건 "심볼"(함수 이름을 데이터처럼 다룸). @eval 이 그 이름으로 실제 메서드를 만들어 컴파일.
# 효과: 7개 함수 각각에 대해, "CustomNode/ScheduleNode 로 감싼 경우 안쪽 노드로 위임"하는 메서드 2개씩 자동 생성.
for op in (:start_config, :goal_config, :entity,
    :cargo_start_config, :cargo_goal_config,
    :cargo_deployed_config, :cargo_loaded_config)
    @eval begin
        $op(n::CustomNode) = $op(node_val(n))      # CustomNode 면 그 안의 값(node_val)에 같은 함수를 다시 적용
        $op(n::ScheduleNode) = $op(n.node)         # ScheduleNode 면 그 안의 .node 에 같은 함수를 다시 적용
    end
end

# {E} 는 타입 매개변수(제네릭 빈칸) — "어떤 실체 타입 E 에 대한" 정지 상태 술어임을 나타냄(예: E=RobotNode).
# <: ConstructionPredicate : 이 추상 타입도 최상위 술어의 하위 타입.
abstract type EntityConfigPredicate{E} <: ConstructionPredicate end
# 이 부류 노드는 start 와 goal 이 같다(정지 상태) → 둘 다 같은 config 필드를 반환.
start_config(n::EntityConfigPredicate) = n.config   # 시작 배치 = config (n::타입 으로 이 부류에만 적용)
goal_config(n::EntityConfigPredicate) = n.config    # 목표 배치 = config (동일)

# struct : 값을 담는 틀(파이썬 class 와 비슷하나 메서드는 밖에 따로). RobotStart 는 EntityConfigPredicate{RobotNode} 의 하위 타입.
struct RobotStart <: EntityConfigPredicate{RobotNode}
    entity::RobotNode       # 이 노드가 다루는 로봇 (::RobotNode = 필드 타입 표기)
    config::TransformNode   # 로봇의 배치(위치/자세) 정보
end
struct ObjectStart <: EntityConfigPredicate{ObjectNode}  # 부품의 시작 상태 노드
    entity::ObjectNode      # 다루는 부품
    config::TransformNode   # 부품의 배치
end
struct AssemblyComplete <: EntityConfigPredicate{AssemblyNode}  # 조립체 완성 상태 노드
    entity::AssemblyNode    # 완성된 조립체
    config::TransformNode   # 조립체의 배치
    inner_staging_circle::GeomNode # inner staging circle  # 내부 적치(staging) 원 — 주변 작업공간 경계
    outer_staging_circle::GeomNode # outer staging circle  # 외부 적치 원
end
# struct 와 이름이 같은 function = "외부 생성자"(추가 생성 방법). 인자 2개만 받아 나머지 필드를 기본값으로 채워 만든다.
function AssemblyComplete(n::SceneNode, t::TransformNode)
    inner_staging_circle = GeomNode(LazySets.Ball2(zeros(SVector{3,Float64}), 0.0))  # 반지름 0 인 빈 공(나중에 크기 채움)으로 내부 원 초기화. zeros(SVector{3,...}) = 3D 영벡터
    outer_staging_circle = GeomNode(LazySets.Ball2(zeros(SVector{3,Float64}), 0.0))  # 외부 원도 동일하게 초기화
    node = AssemblyComplete(n, t, inner_staging_circle, outer_staging_circle)         # 위 4개 필드로 실제 객체 생성
    set_parent!(inner_staging_circle, t)   # 내부 원의 부모를 배치 t 로 설정(원이 조립체 위치를 따라다니게)
    set_parent!(outer_staging_circle, t)   # 외부 원도 부모를 t 로 설정
    node                                   # 마지막 줄 값이 반환값(return 생략)
end
struct AssemblyStart <: EntityConfigPredicate{AssemblyNode}  # 조립 시작 노드
    entity::AssemblyNode    # 조립할 조립체
    config::TransformNode   # 그 배치
end
# for T in (:타입이름,...) + @eval : 위 4개 타입 각각에 공통 생성자 2개를 자동 정의(메타프로그래밍 반복).
for T in (:RobotStart, :ObjectStart, :AssemblyComplete, :AssemblyStart)
    @eval begin
        $T(n::SceneNode) = $T(n, TransformNode())                       # 장면노드만 주면 빈 TransformNode 로 배치를 채워 생성
        $T(n::ConstructionPredicate) = $T(entity(n), goal_config(n)) # shared config  # 다른 술어로부터 그 실체·목표배치를 공유해 생성
    end
end

"""
    abstract type EntityGo{E}

Encodes going from state start_config(n) to state goal_config(n).
"""
# EntityGo{E} : "실체 E 가 start_config 에서 goal_config 로 이동"을 뜻하는 노드들의 추상 부모 타입.
abstract type EntityGo{E} <: ConstructionPredicate end

# {R} 타입 매개변수 : 로봇 실체의 구체 타입을 R 로 남겨둠. 한 로봇에 RobotGo 노드가 여러 개 생길 수 있어 id 로 구분.
struct RobotGo{R} <: EntityGo{RobotNode}
    entity::R                # 이동하는 로봇 (타입은 R 로 일반화)
    start_config::TransformNode  # 출발 배치
    goal_config::TransformNode   # 도착 배치
    id::ActionID # required because there may be multiple RobotGo nodes for one robot  # 같은 로봇의 여러 이동을 구분하는 고유 행동 ID
end

struct TransportUnitGo <: EntityGo{TransportUnitNode}  # 운반팀(화물 든 로봇 무리)의 이동 노드
    entity::TransportUnitNode    # 이동하는 운반팀
    start_config::TransformNode  # 출발 배치
    goal_config::TransformNode   # 도착 배치
end

# {C} : 들어올릴 대상의 타입(조립체 또는 부품). <: EntityGo{C} 로 그 타입에 맞춘 이동 술어가 됨.
struct LiftIntoPlace{C} <: EntityGo{C}
    entity::C # AssemblyNode or ObjectNode  # 제자리에 올려놓을 대상(조립체나 부품)
    start_config::TransformNode  # 들어올리기 시작 배치
    # path plan?                  # (원작자 메모: 경로 계획을 여기 둘지?)
    goal_config::TransformNode   # 최종(놓일) 배치
end

"""
    abstract type BuildPhasePredicate <: ConstructionPredicate

References a building phase. Interface:
- `get_assembly(::BuildPhasePredicate)` => ::AssemblyNode - the assembly to be
modified by this build phase
- `assembly_components(::BuildPhasePredicate)` => TransformDict{Union{ObjectID,AssemblyID}}
- the components to be added to the assembly during this phase
"""
# BuildPhasePredicate : "조립 단계(어떤 조립체에 어떤 부품들을 추가하는 한 묶음)"를 가리키는 노드들의 추상 부모.
abstract type BuildPhasePredicate <: ConstructionPredicate end

get_assembly(n::BuildPhasePredicate) = n.assembly         # 이 단계가 수정하는 조립체 반환
assembly_components(n::BuildPhasePredicate) = n.components # 이 단계에서 추가되는 구성부품들 반환
assembly_components(n::ConstructionPredicate) = assembly_components(entity(n))  # 일반 술어면 그 실체의 구성부품으로 위임
get_assembly(n::CustomNode) = get_assembly(node_val(n))            # CustomNode 로 감싼 경우 안쪽 값으로 위임
assembly_components(n::CustomNode) = assembly_components(node_val(n))  # 동일하게 안쪽 값으로 위임

"""
    extract_building_phase(n::BuildingStep,tree::SceneTree,model_spec,id_map)

extract the assembly and set of subcomponents from a BuildingStep.
"""
# 한 BuildingStep 으로부터 "수정될 조립체"와 "추가될 부품들의 배치 모음"을 뽑아낸다.
function extract_building_phase(n, tree::SceneTree, model_spec, id_map)
    @assert matches_template(BuildingStep, n)        # n 이 조립단계 노드가 맞는지 점검(@assert: 거짓이면 중단)
    assembly_id = id_map[node_val(n).parent]         # 이 단계의 부모(소속 조립체) 이름을 대응표로 조립체 ID 로 변환
    @assert isa(assembly_id, AssemblyID)             # 그 ID 가 정말 조립체 ID 인지 확인(isa = 타입 검사)
    assembly = get_node(tree, assembly_id)           # 장면트리에서 해당 조립체 노드를 가져옴
    parts = typeof(assembly_components(assembly))()  # 조립체의 구성부품 딕셔너리와 "같은 타입"의 빈 딕셔너리 생성
    for child_id in get_build_step_components(model_spec, id_map, n)  # 이 단계에서 추가되는 각 구성요소 ID 에 대해
        @assert has_component(assembly, child_id) "$child_id is not a child of assembly $assembly"  # 그 부품이 조립체의 자식인지 점검
        parts[child_id] = child_transform(assembly, child_id)  # 부품 ID → 조립체 기준 상대 배치 를 저장
    end
    # for vp in inneighbors(model_spec,n)
    #     child_id = get_referenced_component(model_spec,id_map,get_vtx_id(model_spec,vp))
    #     # child_id = get(id_map,get_vtx_id(model_spec,vp),nothing)
    #     if !(child_id === nothing)
    #         @assert has_component(assembly, child_id) "$child_id is not a child of assembly $assembly"
    #         parts[child_id] = child_transform(assembly,child_id)
    #     end
    # end
    return assembly, parts
end

# struct BuildPhase
#     components::TransformDict{Union{AssemblyID,ObjectID}}
#     staging_circle::GeomNode # staging circle - surrounds the staging area--requires tf relative to assembly
#     bounding_circle::GeomNode # bounding circle - surrounds the current assembly--requires tf relative to assembly
# end

"""
    OpenBuildStep <: ConstructionPredicate

Marks the beginning of a new building phase.
Fields:
- assembly::AssemblyNode - the assembly to be modified by this build phase
- components::Dict{Union{AssemblyID,ObjectID}} - the components to be added to
the assembly during this phase
"""
# OpenBuildStep : 한 조립 단계의 "시작"을 표시하는 노드(BuildPhasePredicate 의 구체 타입).
struct OpenBuildStep <: BuildPhasePredicate
    assembly::AssemblyNode   # 이 단계에서 수정될 조립체
    components::TransformDict{Union{AssemblyID,ObjectID}}  # 추가될 구성요소들 → 각자의 배치(부품ID/조립체ID 모두 가능)
    staging_circle::GeomNode # staging circle - surrounds the staging area--requires tf relative to assembly  # 적치구역을 둘러싸는 원
    bounding_circle::GeomNode # bounding circle - surrounds the current assembly--requires tf relative to assembly  # 현재 조립체를 둘러싸는 원
    id::Int # id of this build step  # 이 조립 단계의 식별번호
end
struct CloseBuildStep <: BuildPhasePredicate  # 조립 단계의 "종료"를 표시하는 노드(필드는 OpenBuildStep 과 동일)
    assembly::AssemblyNode
    components::TransformDict{Union{AssemblyID,ObjectID}}
    staging_circle::GeomNode
    bounding_circle::GeomNode
    id::Int # id of this build step
end
# 위 두 타입에 공통 생성자들을 자동 정의(메타프로그래밍). $T 는 반복 중인 타입 이름으로 치환됨.
for T in (:OpenBuildStep, :CloseBuildStep)
    @eval begin
        # 5번째 인자(id)를 안 주면 새 고유 ID 를 발급해 채워 생성. get_id(get_unique_id(...)) = 새 ID 의 정수값.
        $T(a::AssemblyNode, c::Dict, g1::GeomNode, g2::GeomNode) = $T(a, c, g1, g2, get_id(get_unique_id(TemplatedID{$T})))
        # 원 두 개도 안 주면 반지름 0 인 빈 공으로 채워 생성
        $T(a::AssemblyNode, c::Dict) = $T(a, c,
            GeomNode(LazySets.Ball2(zeros(SVector{3,Float64}), 0.0)),
            GeomNode(LazySets.Ball2(zeros(SVector{3,Float64}), 0.0))
        )
        # args... : 가변 인자(파이썬 *args). extract_building_phase 결과(조립체, 부품들)를 ...(splat)으로 펼쳐 생성자에 전달.
        $T(n::CustomNode, args...) = $T(extract_building_phase(n, args...)...)
        # 다른 build-phase 노드로부터 모든 필드를 복사해 같은 타입으로 다시 생성
        $T(n::BuildPhasePredicate) = $T(n.assembly, n.components,
            n.staging_circle, n.bounding_circle, n.id)
    end
end
# node_id : build-phase 노드의 ID 는 "타입+id" 를 묶은 TemplatedID. where {T<:...} = T 는 BuildPhasePredicate 의 하위 타입.
node_id(n::T) where {T<:BuildPhasePredicate} = TemplatedID{T}(n.id)
# add_node!(g::AbstractCustomNGraph, n::P) where {P<:BuildPhasePredicate} = add_node!(g,n,get_unique_id(TemplatedID{P}))

"""
    FormTransportUnit <: ConstructionPredicate

TransportUnit must remain motionless as the cargo moves from its start
configuration to its `FormTransportUnit.cargo_goal_config` configuration.
"""
# FormTransportUnit : 로봇들이 화물 아래 모여 운반팀을 "구성"하는 단계. 팀은 정지한 채 화물만 결합 위치로 옮긴다.
struct FormTransportUnit <: ConstructionPredicate
    entity::TransportUnitNode    # 구성되는 운반팀
    config::TransformNode        # 팀(엔티티)의 배치 — 이 단계 동안 고정
    cargo_start_config::TransformNode  # 화물의 시작 배치
    cargo_goal_config::TransformNode # offset from config by child_transform(entity,cargo_id(entity))  # 화물의 결합 후 배치(팀 기준 자식 변환만큼 떨어짐)
end

"""
    DepositCargo <: ConstructionPredicate

TransportUnit must remain motionless as the cargo moves from its transport
configuration to its `LiftIntoPlace.start_config` configuration.
"""
# DepositCargo : 운반팀이 화물을 "내려놓는" 단계. 팀은 정지한 채 화물만 운반 위치 → 놓일 위치로 옮긴다.
struct DepositCargo <: ConstructionPredicate
    entity::TransportUnitNode    # 화물을 내려놓는 운반팀
    config::TransformNode        # 팀의 배치 — 이 단계 동안 고정
    cargo_start_config::TransformNode # offset from config by child_transform(entity,cargo_id(entity))  # 화물의 시작(운반 중) 배치
    cargo_goal_config::TransformNode  # 화물이 내려놓일 배치
end
# Union{A,B} : "둘 중 아무 타입이나" — 아래 메서드들은 DepositCargo 와 FormTransportUnit 둘 다에 똑같이 적용.
start_config(n::Union{DepositCargo,FormTransportUnit}) = n.config       # 시작 배치 = 팀 배치(둘 다 정지 상태)
goal_config(n::Union{DepositCargo,FormTransportUnit}) = n.config        # 목표 배치 = 팀 배치(동일)
cargo_start_config(n::Union{DepositCargo,FormTransportUnit}) = n.cargo_start_config  # 화물 시작 배치 필드 반환
cargo_goal_config(n::Union{DepositCargo,FormTransportUnit}) = n.cargo_goal_config    # 화물 목표 배치 필드 반환
# "적재(loaded)/배치(deployed)" 개념을 두 단계에서 정반대로 매핑한다(내려놓기 vs 싣기).
cargo_loaded_config(n::DepositCargo) = cargo_start_config(n)        # 내려놓기 단계에선 화물이 시작에 실려 있음
cargo_loaded_config(n::FormTransportUnit) = cargo_goal_config(n)    # 구성 단계에선 화물이 목표에 실리게 됨
cargo_deployed_config(n::DepositCargo) = cargo_goal_config(n)       # 내려놓기 단계에선 화물이 목표에 배치됨
cargo_deployed_config(n::FormTransportUnit) = cargo_start_config(n) # 구성 단계에선 화물이 시작에 (배치돼) 있음

# 두 타입에 "운반팀 노드만 받아 자동 생성"하는 생성자를 정의(메타프로그래밍).
for T in (:DepositCargo, :FormTransportUnit)
    @eval begin
        function $T(n::TransportUnitNode)
            t = $T(n, TransformNode(), TransformNode(), TransformNode())  # 배치 3개를 빈 TransformNode 로 채워 생성
            # cargo_goal -> cargo_start -> entity_config  # 변환 노드들을 부모-자식 사슬로 연결(아래 두 줄)
            set_parent!(cargo_loaded_config(t), cargo_deployed_config(t))  # 적재 배치의 부모를 배치(deployed) 배치로
            set_parent!(start_config(t), cargo_loaded_config(t))           # 팀 배치의 부모를 적재 배치로
            # set child transform cargo_start -> entity_config  # 팀 배치의 상대 변환을 화물 자식변환의 역으로 설정
            set_local_transform!(start_config(t), inv(child_transform(n, cargo_id(n))))  # inv = 역변환(거꾸로 매기기)
            return t
        end
    end
end

# RobotGo/TransportUnitGo 에 "장면노드만 받아 자동 생성"하는 생성자 정의. (LiftIntoPlace 는 주석처리돼 제외)
for T in (:RobotGo, :TransportUnitGo) #,:LiftIntoPlace)
    @eval begin
        function $T(n::SceneNode)
            t = $T(n, TransformNode(), TransformNode())       # 시작/목표 배치를 빈 TransformNode 로 채워 생성
            set_parent!(goal_config(t), start_config(t))      # 목표 배치의 부모를 시작 배치로 연결(상대 이동으로 표현)
            return t
        end
    end
end
# RobotGo 의 3-인자 생성자: id 를 안 주면 새 고유 ActionID 를 발급해 채움.
RobotGo(n::RobotNode, start, goal) = RobotGo(n, start, goal, get_unique_id(ActionID))
# LiftIntoPlace 의 생성자: 부품/조립체만 받아 빈 배치로 생성.
function LiftIntoPlace(n::Union{ObjectNode,AssemblyNode})
    l = LiftIntoPlace(n, TransformNode(), TransformNode())    # 시작/목표 배치를 빈 노드로 채워 생성
    set_parent!(start_config(l), goal_config(l)) # point to parent  # 시작 배치의 부모를 목표 배치로(목표 기준 상대 표현)
    return l
end

robot_team(n::ConstructionPredicate) = robot_team(entity(n))  # 술어의 "로봇 팀"은 그 실체의 로봇 팀으로 위임
# cargo_node_type : 화물 종류에 따라 어떤 상태 노드 타입을 쓸지 결정. 삼항 `조건 ? A : B`(A if 조건 else B).
cargo_node_type(n::TransportUnitNode) = cargo_type(n) == AssemblyNode ? AssemblyComplete : ObjectStart  # 화물이 조립체면 AssemblyComplete, 아니면 ObjectStart
cargo_node_type(n::ConstructionPredicate) = cargo_node_type(entity(n))  # 술어면 그 실체로 위임

# ProjectComplete : 프로젝트(최상위 모델) 전체가 완성됐음을 표시하는 노드.
struct ProjectComplete <: ConstructionPredicate
    project_id::Int          # 프로젝트 식별번호
    config::TransformNode    # 그 배치
end
ProjectComplete(id) = ProjectComplete(id, TransformNode())  # id 만 주면 빈 배치로 생성
ProjectComplete() = ProjectComplete(get_id(get_unique_id(TemplatedID{ProjectComplete})))  # 인자 없이 부르면 새 고유 ID 발급해 생성
node_id(n::ProjectComplete) = TemplatedID{ProjectComplete}(n.project_id)  # 이 노드의 ID 는 타입+project_id 로 만든 TemplatedID

# 아래 함수들은 스케줄 그래프의 "선후관계 규칙"을 노드 타입별로 정의(다중 디스패치).
# required_*  : 반드시 앞(predecessor)/뒤(successor)에 와야 하는 노드 종류 => 개수.
# eligible_*  : 와도 되는(허용) 노드 종류 => 최대 개수. 기본은 required 와 같게 둠.
# `::타입` 만 쓴 건 값 무시·타입만으로 어느 규칙을 쓸지 고른다는 뜻. Dict() 는 빈 딕셔너리(=제약 없음).
required_predecessors(::ConstructionPredicate) = Dict()   # 기본: 필수 선행 없음
required_successors(::ConstructionPredicate) = Dict()      # 기본: 필수 후행 없음
eligible_predecessors(n::ConstructionPredicate) = required_predecessors(n)  # 기본: 허용 선행 = 필수 선행
eligible_successors(n::ConstructionPredicate) = required_successors(n)      # 기본: 허용 후행 = 필수 후행

required_predecessors(::RobotStart) = Dict()              # 로봇 시작: 앞에 필요한 것 없음
required_successors(::RobotStart) = Dict(RobotGo => 1)    # 로봇 시작 뒤엔 반드시 RobotGo 1개

required_predecessors(::RobotGo) = Dict(Union{RobotStart,DepositCargo,RobotGo} => 1)  # RobotGo 앞엔 (시작/하역완료/직전이동) 중 1개
required_successors(::RobotGo) = Dict()                   # RobotGo 뒤엔 필수 없음
eligible_successors(::RobotGo) = Dict(Union{RobotGo,FormTransportUnit} => 1)  # 뒤에 올 수 있는 건 또 다른 RobotGo 나 팀 구성 1개

required_predecessors(n::FormTransportUnit) = Dict(RobotGo => length(robot_team(n)), cargo_node_type(n) => 1)  # 팀 구성 앞엔: 팀 로봇 수만큼의 RobotGo + 화물 상태노드 1
required_successors(::FormTransportUnit) = Dict(TransportUnitGo => 1)  # 팀 구성 뒤엔 팀 이동 1

required_predecessors(::TransportUnitGo) = Dict(FormTransportUnit => 1)  # 팀 이동 앞엔 팀 구성 1
required_successors(::TransportUnitGo) = Dict(DepositCargo => 1)         # 팀 이동 뒤엔 화물 하역 1

required_predecessors(::DepositCargo) = Dict(TransportUnitGo => 1, OpenBuildStep => 1)  # 하역 앞엔 팀 이동 1 + 단계 시작 1
required_successors(n::DepositCargo) = Dict(LiftIntoPlace => 1, RobotGo => length(robot_team(n)))  # 하역 뒤엔 제자리 안착 1 + 팀 로봇 수만큼 RobotGo(해산)

required_predecessors(::LiftIntoPlace) = Dict(DepositCargo => 1)   # 안착 앞엔 하역 1
required_successors(::LiftIntoPlace) = Dict(CloseBuildStep => 1)   # 안착 뒤엔 단계 종료 1

required_predecessors(n::CloseBuildStep) = Dict(LiftIntoPlace => num_components(n))  # 단계 종료 앞엔 부품 수만큼의 안착(모든 부품이 놓여야 종료)
required_successors(::CloseBuildStep) = Dict(Union{OpenBuildStep,AssemblyComplete} => 1)  # 단계 종료 뒤엔 다음 단계 시작 또는 조립체 완성 1

required_predecessors(::OpenBuildStep) = Dict(Union{AssemblyStart,CloseBuildStep} => 1)  # 단계 시작 앞엔 조립 시작 또는 이전 단계 종료 1
required_successors(n::OpenBuildStep) = Dict(DepositCargo => num_components(n))  # 단계 시작 뒤엔 부품 수만큼의 하역

required_predecessors(::ObjectStart) = Dict()                            # 물체 시작 앞엔 필수 선행 없음(맨 처음 상태)
required_successors(::ObjectStart) = Dict(FormTransportUnit => 1)        # 물체 시작 뒤엔 팀 구성 1(운반 시작)

# required_predecessors(  n::AssemblyComplete) = Dict(Union{ObjectStart,CloseBuildStep}=>1)  # (옛 버전 — 주석처리됨)
required_predecessors(::AssemblyComplete) = Dict(CloseBuildStep => 1)    # 조립체 완성 앞엔 마지막 단계 종료 1
required_successors(::AssemblyComplete) = Dict(Union{FormTransportUnit,ProjectComplete} => 1)  # 조립체 완성 뒤엔 운반 시작 또는 프로젝트 완료 1

required_predecessors(::AssemblyStart) = Dict()                         # 조립 시작 앞엔 필수 선행 없음
required_successors(::AssemblyStart) = Dict(OpenBuildStep => 1)         # 조립 시작 뒤엔 첫 단계 시작 1

required_predecessors(::ProjectComplete) = Dict(AssemblyComplete => 1)  # 프로젝트 완료 앞엔 최상위 조립체 완성 1
required_successors(::ProjectComplete) = Dict()                        # 프로젝트 완료 뒤엔 아무것도 없음(최종 노드)


# for T in (:타입들) + @eval : 아래 상태/이동 노드 타입들 각각에 node_id 메서드를 자동 정의(메타프로그래밍).
# 각 노드의 ID = "노드타입 T + 그 실체(entity)의 node_id 타입" 을 묶은 TemplatedID 로, 실체 id 의 정수값으로 생성.
# (:RobotGo 는 주석처리돼 제외 — RobotGo 는 아래에서 .id 필드를 그대로 쓰는 별도 메서드를 갖기 때문)
for T in (
    :ObjectStart,
    :RobotStart,
    # :RobotGo,
    :AssemblyStart,
    :AssemblyComplete,
    :FormTransportUnit,
    :TransportUnitGo,
    :DepositCargo,
    :LiftIntoPlace,
)
    @eval begin
        function node_id(n::$T)
            TemplatedID{Tuple{$T,typeof(node_id(entity(n)))}}(get_id(node_id(entity(n))))
        end
    end
end
# node_id(n::RobotGo) = n.id : RobotGo 노드에 대해서는 위 메타프로그래밍 루프와 달리 entity 기반으로
# id 를 새로 합성하지 않고, 객체에 미리 저장돼 있는 .id 필드를 그대로 반환하는 별도 메서드(다중 디스패치).
node_id(n::RobotGo) = n.id   # RobotGo 의 node_id 는 객체에 저장된 n.id 를 그대로 반환

# 아래는 예전 버전 코드를 주석처리해 보존해 둔 것(실행되지 않음). 참고용 히스토리.
# for T in (
#     :ObjectStart,
#     :RobotStart,
#     :RobotGo,
#     :AssemblyStart,
#     :AssemblyComplete,
# )
#     @eval begin
#         node_id(n::$T) = TemplatedID{$T}(get_id(node_id(entity(n))))
#     end
# end

"""
    get_previous_build_step(model_spec,v)

Return the node representing the previous build step in the model spec.
"""
# 함수 정의: model_spec 그래프에서 노드 v 의 "이전 조립 단계(build step)" 노드를 찾아 반환.
# 세미콜론(;) 뒤는 "키워드 인자" — 파이썬의 def f(model_spec, v, *, skip_first=...) 처럼 이름으로 넘기는 인자.
# skip_first 의 기본값은 그 자리에서 계산됨: v 가 SubModelPlan 템플릿에 해당하면 첫 노드는 건너뛰라는 뜻.
function get_previous_build_step(model_spec, v;
    skip_first=matches_template(SubModelPlan, get_node(model_spec, v)),   # v 가 SubModelPlan 이면 true(첫 노드 스킵)
)
    # depth_first_search: 깊이우선탐색. 인자로 "함수들"을 그대로 넘김(파이썬에서 함수를 값으로 넘기는 것과 동일).
    # u -> ... 는 "익명함수(람다)" — 파이썬의 lambda u: ... 와 같음.
    vp = depth_first_search(model_spec, get_vtx(model_spec, v),                                   # v 의 정점 인덱스에서 탐색 시작
        u -> matches_template(BuildingStep, get_node(model_spec, u)),                             # 목표조건: 노드 u 가 BuildingStep 이면 멈춤
        u -> (get_vtx(model_spec, v) == u || !matches_template(SubModelPlan, get_node(model_spec, u))),  # 확장조건: 자기 자신이거나 SubModelPlan 이 아니면 계속 탐색(|| 는 논리 OR, ! 는 부정)
        inneighbors;                                                                             # 들어오는 이웃(부모 방향)으로 거슬러 탐색
        skip_first=skip_first,                                                                    # 위에서 정한 첫 노드 스킵 여부 전달
    )
    if has_vertex(model_spec, vp)        # 탐색 결과 정점 vp 가 실제로 그래프에 존재하면
        return get_node(model_spec, vp)  # 그 정점에 해당하는 노드 객체를 반환
    end
    return nothing                       # 찾지 못하면 nothing(파이썬의 None) 반환
end

export construct_partial_construction_schedule   # 이 함수를 외부(using ConstructionBots)에서 바로 쓸 수 있게 공개

"""
    populate_schedule_build_step!(sched,cb,step_node,model_spec,scene_tree,id_map)

Creates an OpenBuildStep ... CloseBuildStep structure and adds an edge
CloseBuildStep => parent.
Args:
- sched - the schedule
- cb::CustomNode{CloseBuildStep,AbstractID}
- model_spec
- scene_tree
- id_map
"""
# 함수 정의: 하나의 조립 단계에 대해 OpenBuildStep…CloseBuildStep 구조를 스케줄(sched)에 채워 넣음.
# 이름 끝 `!` = sched 를 직접 수정(in-place)한다는 관례. parent::AssemblyComplete = 이 인자가 AssemblyComplete
# 타입일 때만 이 메서드가 선택됨(다중 디스패치). ;뒤 connect_to_sub_assemblies 는 키워드 인자(기본값 true).
function populate_schedule_build_step!(sched, parent::AssemblyComplete, cb, step_node, model_spec, scene_tree, id_map;
    connect_to_sub_assemblies=true,   # 하위 조립체와 연결할지 여부(키워드 인자)
)
    # OpenBuildStep
    ob = add_node!(sched, OpenBuildStep(node_val(cb)))   # cb(CloseBuildStep)의 값으로 OpenBuildStep 노드를 만들어 스케줄에 추가
    for child_id in get_build_step_components(model_spec, id_map, step_node)   # 이 빌드 스텝에 들어오는 각 부품 id 에 대해 반복
        cargo = get_node(scene_tree, child_id)                                 # 그 id 에 해당하는 부품(화물) 노드를 씬트리에서 가져옴
        transport_unit = get_node(scene_tree, node_id(TransportUnitNode(cargo)))   # 그 화물을 운반할 운반유닛 노드를 가져옴
        @assert isa(cargo, Union{AssemblyNode,ObjectNode})   # @assert: 조건이 거짓이면 에러. cargo 가 조립체/객체 노드 중 하나인지 확인(Union 은 "둘 중 하나" 타입)
        # LiftIntoPlace
        l = add_node!(sched, LiftIntoPlace(cargo))                              # 부품을 제자리로 들어올리는 LiftIntoPlace 노드 추가
        set_parent!(goal_config(l), start_config(parent))                       # l 의 목표자세를 부모(parent)의 시작자세에 변환트리상 종속시킴
        set_local_transform!(goal_config(l), child_transform(entity(parent), node_id(cargo)))   # l 의 목표 지역변환을, 조립체 내 그 부품의 상대위치로 설정
        # ensure that LiftIntoPlace starts in the carry configuration
        set_desired_global_transform!(start_config(l),                          # l 의 시작자세(전역)를 아래 값으로 지정
            CoordinateTransformations.Translation(global_transform(start_config(l)).translation)   # 현재 전역위치의 평행이동 성분만 취함(회전 제거) → 운반 자세에서 시작
        )
        @info "Staging config: setting GOAL config of $(node_id(l)) to $(goal_config(l))"   # @info: 로그 출력. $(...) 는 문자열 안에 값 삽입(파이썬 f-string 의 {})
        add_edge!(sched, l, cb) # LiftIntoPlace => CloseBuildStep                # 엣지 추가: l 다음에 cb 가 오도록 연결
        # DepositCargo
        d = add_node!(sched, DepositCargo(transport_unit))                      # 화물을 내려놓는 DepositCargo 노드 추가
        set_parent!(cargo_deployed_config(d), start_config(l))                  # d 의 화물전개자세를 l 의 시작자세에 종속
        add_edge!(sched, d, l) # DepositCargo => LiftIntoPlace                   # 엣지: d → l
        add_edge!(sched, ob, d) # OpenBuildStep => DepositCargo                  # 엣지: ob → d
        # TransportUnitGo
        tgo = add_node!(sched, TransportUnitGo(transport_unit))                 # 운반유닛이 목적지로 이동하는 TransportUnitGo 노드 추가
        set_parent!(goal_config(tgo), start_config(d))                          # tgo 의 목표자세를 d 의 시작자세에 종속
        add_edge!(sched, tgo, d) # TransportUnitGo => DepositCargo               # 엣지: tgo → d
        # FormTransportUnit
        f = add_node!(sched, FormTransportUnit(transport_unit))                 # 로봇들이 모여 운반유닛을 구성하는 FormTransportUnit 노드 추가
        set_parent!(start_config(tgo), goal_config(f))                          # tgo 의 시작자세를 f 의 목표자세에 종속
        add_edge!(sched, f, tgo) # FormTransportUnit => TransportUnitGo          # 엣지: f → tgo
        # ObjectStart/AssemblyComplete
        if isa(cargo, AssemblyNode) # && connect_to_sub_assemblies              # 화물이 하위 조립체이면
            cargo_node = get_node(sched, AssemblyComplete(cargo))               # 이미 만들어진 그 조립체의 AssemblyComplete 노드를 가져옴
        else                                                                    # 그 외(개별 객체)이면
            cargo_node = add_node!(sched, ObjectStart(cargo, TransformNode()))  # 새 ObjectStart 노드를 만들어 추가
        end
        if connect_to_sub_assemblies                                            # 하위조립체 연결 옵션이 켜져 있으면
            set_parent!(goal_config(node_val(cargo_node)), start_config(parent))   # 화물노드의 목표자세를 부모의 시작자세에 종속
        end
        add_edge!(sched, cargo_node, f) # ObjectStart/AssemblyComplete => FormTransportUnit   # 엣지: cargo_node → f
        set_parent!(cargo_deployed_config(f), start_config(cargo_node))         # f 의 화물전개자세를 cargo_node 의 시작자세에 종속
    end
    return ob   # 이 빌드 스텝의 OpenBuildStep 노드를 반환(상위에서 다음 연결에 사용)
end

"""
    populate_schedule_sub_graph!(
        sched,
        parent::AssemblyComplete,
        model_spec,
        scene_tree,
        id_map)

Add all building steps to parent, working backward from parents
"""
# 함수 정의: 한 조립체(parent)의 모든 빌드 스텝을, 부모에서 거꾸로(역방향) 거슬러 올라가며 스케줄에 추가.
# parent::AssemblyComplete = AssemblyComplete 타입일 때만 선택되는 메서드(다중 디스패치). `!` = sched 직접 수정.
function populate_schedule_sub_graph!(sched, parent::AssemblyComplete, model_spec, scene_tree, id_map)
    parent_assembly = entity(parent)                 # parent 노드가 감싸고 있는 실제 조립체 객체를 꺼냄
    # sa = add_node!(sched,AssemblyStart(parent_assembly))
    sa = add_node!(sched, AssemblyStart(parent)) # shares config with AssemblyComplete (AssemblyComplete.config === AssemblyStart.config)   # AssemblyStart 노드 추가. `===` 는 "완전히 같은 객체(동일성)" 비교 — 둘이 같은 config 를 공유함
    spec_node = get_node(model_spec, id_map[node_id(parent_assembly)])   # id_map[...] 으로 이 조립체에 대응하는 model_spec 노드 id 를 찾아 그 노드를 가져옴
    step_node = get_previous_build_step(model_spec, spec_node; skip_first=true)   # 가장 마지막(직전) 빌드 스텝을 찾음(skip_first=true: 자기 자신은 건너뜀)
    immediate_parent = parent                        # 새로 추가할 노드를 매달 "바로 위 부모"의 초기값은 parent
    _diag_bs = 0                                      # 무한루프 진단용 카운터(0부터 시작)
    while !(step_node === nothing)                    # step_node 가 nothing(없음)이 아닌 동안 반복. `!(... === nothing)` = "아직 빌드 스텝이 남아있음"
        _diag_bs += 1                                 # 반복 횟수 1 증가
        if _diag_bs > 10_000                          # 1만 번을 넘으면(비정상적으로 많으면)
            error("[RUNAWAY] populate_schedule_sub_graph! build-step loop exceeded 10000 iterations for parent $(summary(node_id(parent_assembly))) — likely a cycle in get_previous_build_step / model_spec build steps. step_node=$(summary(node_id(step_node)))")   # error(): 예외를 던져 중단(사이클 의심)
        end
        # CloseBuildStep
        cb = add_node!(sched, CloseBuildStep(step_node, scene_tree, model_spec, id_map))   # 이 빌드 스텝의 CloseBuildStep 노드를 만들어 추가
        add_edge!(sched, cb, immediate_parent) # CloseBuildStep => AssemblyComplete / OpenBuildStep   # 엣지: cb → 바로 위 부모
        set_parent!(node_val(cb).staging_circle, start_config(parent))   # cb 의 staging_circle(적치원)을 parent 시작자세에 종속. `.staging_circle` = 필드 접근(파이썬과 동일)
        set_parent!(node_val(cb).bounding_circle, start_config(parent))  # cb 의 bounding_circle(경계원)을 parent 시작자세에 종속
        ob = populate_schedule_build_step!(sched, parent, cb, step_node, model_spec, scene_tree, id_map)   # 위에서 본 함수로 이 스텝의 세부 노드들을 채우고 OpenBuildStep 을 받음
        immediate_parent = ob                            # 다음 스텝은 이번 OpenBuildStep 에 매달리도록 부모 갱신
        step_node = get_previous_build_step(model_spec, step_node; skip_first=true)   # 그 이전 빌드 스텝으로 한 칸 더 거슬러 올라감
    end
    add_edge!(sched, sa, immediate_parent) # AssemblyStart => OpenBuildStep   # 마지막으로 AssemblyStart 를 맨 처음 빌드스텝에 연결
    sched   # 마지막 표현식 값이 곧 반환값(Julia 는 return 생략 시 마지막 식을 반환). 수정된 sched 반환
end

"""
    construct_partial_construction_schedule(sched,args...)

Constructs a schedule that does not yet reflect the "staging plan" and does not
yet contain any RobotStart or RobotGo nodes.
"""
# 함수 정의: 최상위 진입점. 부분 조립 스케줄(아직 staging plan·로봇 노드 없음)을 구성.
# 마지막 인자 id_map 은 "기본값이 있는 위치 인자" — 호출 시 생략하면 build_id_map(...) 으로 자동 계산됨(파이썬의 def f(..., id_map=...) 와 동일).
function construct_partial_construction_schedule(
    mpd_model,
    model_spec,
    scene_tree,
    id_map=build_id_map(mpd_model, model_spec)   # 생략 시 mpd_model·model_spec 로 id 대응표 자동 생성
)
    sched = NGraph{DiGraph,ConstructionPredicate,AbstractID}()   # 빈 스케줄 그래프 생성. {DiGraph,...} 는 타입 매개변수(방향그래프·노드값타입·id타입을 채워 넣음)
    parent_map = backup_descendants(model_spec, n -> matches_template(SubModelPlan, n))   # 각 노드의 "가장 가까운 SubModelPlan 조상"을 미리 계산(n -> ... 는 람다)
    # Add assemblies first
    for node in node_iterator(model_spec, topological_sort_by_dfs(model_spec))   # model_spec 을 위상정렬 순서로 순회(의존성 먼저 오도록)
        if matches_template(SubModelPlan, node)              # 노드가 SubModelPlan(하위 모델 설계) 템플릿에 해당하면
            assembly = get_node(scene_tree, id_map[node_id(node)])   # 대응하는 씬트리 조립체 노드를 가져옴
            # AssemblyComplete
            a = add_node!(sched, AssemblyComplete(assembly, TransformNode())) ###############   # 그 조립체의 AssemblyComplete 노드를 스케줄에 추가
            if is_root_node(scene_tree, assembly)            # 그 조립체가 트리의 최상위(루트)이면 = 전체 프로젝트의 최종 조립체
                # ProjectComplete
                p = add_node!(sched, ProjectComplete())      # ProjectComplete(프로젝트 완료) 노드 추가
                add_edge!(sched, a, p)                       # 엣지: a(AssemblyComplete) → p(ProjectComplete)
            end
            # add build steps
            populate_schedule_sub_graph!(sched, node_val(a), model_spec, scene_tree, id_map)   # 이 조립체의 모든 빌드 스텝을 채워 넣음
        end
    end
    # Add robots
    set_robot_start_configs!(sched, scene_tree)   # 로봇들의 시작 위치 설정(RobotStart 노드 등 추가)
    return sched                                  # 완성된 부분 스케줄 반환
end

export validate_schedule_transform_tree   # 이 함수를 외부에서 바로 쓸 수 있게 공개

# 함수 정의: a 의 조상이 b 인지 단언(검사). 첫 인자를 수정하진 않음.
function assert_transform_tree_ancestor(a, b)
    @assert has_ancestor(a, b) "a should have ancestor b, for a = $(a), b = $(b)"   # @assert 조건 "메시지": 거짓이면 메시지와 함께 에러
end

# 함수 정의: 두 변환(t1, t2)이 근사적으로 같은지(부동소수 오차 허용) 판정해 true/false 반환.
function transformations_approx_equiv(t1, t2)
    a = all(isapprox.(t1.translation, t2.translation))   # isapprox.(...) 의 점(.)은 "원소별 브로드캐스트" — 두 벡터의 각 성분끼리 근사비교(파이썬 numpy 의 벡터연산과 유사). all(): 모두 참인지
    b = all(isapprox.(t1.linear, t2.linear))             # 회전(선형) 부분도 원소별로 근사비교 후 모두 참인지
    a && b   # 평행이동·회전 둘 다 일치하면 true (마지막 식이 반환값)
end

"""
    validate_schedule_transform_tree(sched)

Checks if sched and its embedded transform tree are valid.
- The graph itself should be valid
- All chains AssemblyComplete ... LiftIntoPlace -> DepositCargo should be
    connected in the embedded transform tree

"""
# 함수 정의: 스케줄과 그 안에 박혀 있는 변환트리(transform tree)가 유효한지 검사해 true/false 반환.
# ;뒤 post_staging 은 키워드 인자(기본 false) — staging 계획까지 끝난 뒤의 추가 검사를 켤지 여부.
function validate_schedule_transform_tree(sched; post_staging=false)
    try   # try/catch: 파이썬의 try/except 와 동일. 아래 검사 중 AssertionError 가 나면 잡아서 false 반환
        @assert validate_graph(sched)   # 그래프 자체가 유효한지 단언
        for n in get_nodes(sched)                       # 스케줄의 모든 노드를 순회
            if matches_template(AssemblyComplete, n)    # 노드가 AssemblyComplete 이면
                @assert validate_tree(goal_config(n)) "Subtree invalid for $(n)"   # 그 목표자세의 하위 변환트리가 유효한지 단언
            end
        end
        for n in get_nodes(sched)                       # 모든 노드를 다시 순회(이번엔 종류별 정합성 검사)
            if matches_template(OpenBuildStep, n)        # 노드가 OpenBuildStep 이면
                open_build_step = node_val(n)            # 노드가 감싼 값(OpenBuildStep 객체)을 꺼냄
                assembly = open_build_step.assembly      # 그 빌드스텝이 속한 조립체 (.assembly 필드 접근)
                assembly_complete = get_node(sched, AssemblyComplete(assembly))   # 해당 조립체의 AssemblyComplete 노드를 가져옴
                for v in outneighbors(sched, n)          # n 의 나가는 이웃들(다음 노드 정점들)을 순회
                    deposit_node = get_node(sched, v)    # 그 정점에 해당하는 노드를 가져옴
                    @assert matches_template(DepositCargo, deposit_node)   # 그 노드가 DepositCargo 여야 함을 단언
                    assert_transform_tree_ancestor(goal_config(deposit_node), start_config(assembly_complete))   # deposit 목표자세의 조상이 조립체 시작자세인지 확인
                    for vp in outneighbors(sched, v)     # deposit 노드의 나가는 이웃들을 순회
                        lift_node = get_node(sched, vp)  # 그 정점의 노드를 가져옴
                        if matches_template(LiftIntoPlace, lift_node)   # 그 노드가 LiftIntoPlace 이면
                            @assert has_child(
                                goal_config(assembly_complete), goal_config(lift_node))   # 조립체 목표자세가 lift 목표자세를 자식으로 가져야 함을 단언
                            if post_staging                                  # staging 완료 후 추가 검사가 켜져 있으면
                                # Show that goal_config(LiftIntoPlace) matches the
                                # goal config of cargo relative to assembly
                                @assert transformations_approx_equiv(        # lift 목표의 지역변환이
                                    local_transform(goal_config(lift_node)),
                                    child_transform(assembly, node_id(entity(lift_node)))   # 조립체 내 그 화물의 상대위치와 근사 일치하는지
                                )
                                # Show that start_config(LiftIntoPlace) matches
                                # cargo_deployed_config(DepositCargo)
                                @assert transformations_approx_equiv(        # lift 시작자세(전역)가
                                    global_transform(start_config(lift_node)),
                                    global_transform(cargo_deployed_config(deposit_node)),   # deposit 의 화물전개자세(전역)와 근사 일치하는지
                                )
                            end
                        end
                    end
                end
            elseif matches_template(Union{DepositCargo,FormTransportUnit}, n)   # elseif: 파이썬의 elif. 노드가 DepositCargo 또는 FormTransportUnit 이면(Union = 둘 중 하나)
                transport_unit = entity(n)                   # 노드가 가리키는 운반유닛 객체
                @assert has_child(cargo_loaded_config(n), start_config(n))   # 화물적재자세가 시작자세를 자식으로 갖는지 단언
                @assert transformations_approx_equiv(        # 시작자세의 지역변환이
                    local_transform(start_config(n)),
                    inv(child_transform(transport_unit, cargo_id(transport_unit)))   # 운반유닛-화물 상대변환의 역변환(inv)과 근사 일치하는지
                )
                if post_staging                              # staging 완료 후라면
                    @assert isapprox(global_transform(goal_config(n)).translation[3], 0.0; rtol=1e-6, atol=1e-6) "$n, $(global_transform(goal_config(n)).translation)"   # 목표자세 z좌표([3])가 0에 근사한지(바닥에 붙는지). 인덱스는 1부터 시작 → [3]=z
                end
            elseif matches_template(ObjectStart, n)          # 노드가 ObjectStart 이면(별도 검사 없음 — 빈 분기)
            elseif matches_template(LiftIntoPlace, n)        # 노드가 LiftIntoPlace 이면
                @assert has_child(goal_config(n), start_config(n))   # 목표자세가 시작자세를 자식으로 갖는지 단언
                if post_staging                              # staging 완료 후라면
                    l = n                                    # 현재 노드를 l(LiftIntoPlace)로 둠
                    cargo = entity(n)                        # 이 lift 가 다루는 화물 객체
                    f = get_node(sched, FormTransportUnit(TransportUnitNode(cargo)))   # 그 화물의 운반유닛 구성(FormTransportUnit) 노드를 가져옴
                    tu = entity(f)                           # 그 운반유닛 객체
                    o = cargo                                # o 는 화물(별칭)
                    d = get_node(sched, DepositCargo(tu))    # 그 운반유닛의 DepositCargo 노드를 가져옴
                    l = get_node(sched, LiftIntoPlace(o))    # 그 화물의 LiftIntoPlace 노드를 가져옴(다시 명시적으로)
                    @assert isapprox(global_transform(start_config(f)).translation[3], 0.0; rtol=1e-6, atol=1e-6) "Z translation should be 0 for $(summary(node_id(f)))"   # f 시작자세 z 가 0 근사인지(상대·절대 허용오차 키워드 rtol/atol)
                    @assert isapprox(global_transform(start_config(d)).translation[3], 0.0; rtol=1e-6, atol=1e-6) "Z translation should be 0 for $(summary(node_id(d)))"   # d 시작자세 z 가 0 근사인지
                    transformations_approx_equiv(            # (아래 4개는 단언 없이 호출만 — 비교 결과를 따로 쓰진 않음)
                        global_transform(start_config(n)),
                        global_transform(cargo_deployed_config(f))   # n 시작자세 vs f 화물전개자세
                    )
                    transformations_approx_equiv(
                        global_transform(cargo_loaded_config(f)),
                        global_transform(goal_config(f)) ∘ child_transform(tu, node_id(o))   # `∘` = 함수/변환 "합성"(수학의 f∘g). 여기선 두 좌표변환을 이어 붙임
                    )
                    transformations_approx_equiv(
                        global_transform(cargo_loaded_config(d)),
                        global_transform(goal_config(d)) ∘ child_transform(tu, node_id(o))   # d 목표자세에 운반유닛-화물 변환을 합성
                    )
                    transformations_approx_equiv(
                        global_transform(cargo_deployed_config(d)),
                        global_transform(start_config(l))   # d 화물전개자세 vs l 시작자세
                    )
                end
            end
        end
    catch e   # 위 try 블록에서 예외 e 가 발생하면 여기로
        if isa(e, AssertionError)        # 그 예외가 @assert 실패(AssertionError)면
            bt = catch_backtrace()       # 백트레이스(에러 발생 위치 추적정보)를 얻음
            showerror(stderr, e, bt)     # 에러와 백트레이스를 표준오류(stderr)로 출력
            return false                 # 검증 실패로 false 반환
        else                             # 그 외 종류의 예외라면
            rethrow(e)                   # 잡지 않고 다시 던짐(상위로 전파)
        end
    end
    return true   # 모든 검사를 통과하면 true 반환
end


"""
    generate_staging_plan(scene_tree,params)

Given a `SceneTree` representing the final configuration of an assembly,
construct a plan for the start config, staging config, and final config of
each subassembly and individual object. The idea is to ensure that no node of
the "plan" graph overlaps with any other. Requires circular bounding geometry
for each component of the assembly.
    Start at terminal assembly
    work downward through building steps
    For each building step, arrange the incoming parts to balance these
    objectives:
    - minimize "LiftIntoPlace" distance
    - maximize distance between components to be placed.
    It may be necessary to not completely isolate build steps (i.e., two
    consecutive build steps may overlap in the arrival times of subcomponents).
"""
# 함수 정의: staging(적치) 계획을 생성해 스케줄/씬트리에 반영. `!` = 인자를 직접 수정.
# ;뒤 buffer_radius, build_step_buffer_radius 는 키워드 인자(둘 다 기본값 0.0).
function generate_staging_plan!(scene_tree, sched;
    buffer_radius=0.0,                  # 적치영역 사이 여유 반경(키워드 인자)
    build_step_buffer_radius=0.0,       # 빌드스텝 사이 여유 반경(키워드 인자)
)
    # map(f, coll) 은 파이썬 map 과 같음(각 원소에 함수 적용). all(...) 은 모두 참인지. `!all(...)` = 하나라도 거짓이면
    if !all(map(n -> has_vertex(n.geom_hierarchy, HypersphereKey()), get_nodes(scene_tree)))   # 모든 노드가 구(hypersphere) 근사 기하를 갖고 있지 않다면
        compute_approximate_geometries!(scene_tree,
            HypersphereKey(); ϵ=0.0)    # 구 형태의 근사 경계 기하를 계산해 채워 넣음(ϵ 은 오차 허용치, 키워드 인자)
    end
    # For each build step, determine the radius of the largest transform unit
    # that may be active before the build step closes. This radius will be used
    # to inform the size of the buffer zones between staging areas

    # store growing bounding circle of each assembly
    bounding_circles = Dict{AbstractID,LazySets.Ball2}()  # 각 조립체의 (점점 커지는) 경계원 저장 사전
    staging_circles = Dict{AbstractID,LazySets.Ball2}()   # 각 조립체의 적치원 저장 사전
    _diag_step = 0                          # 진단용 빌드스텝 카운터
    for node in node_iterator(sched, topological_sort_by_dfs(sched))  # 위상정렬 순서로 스케줄 노드 순회
        if matches_template(AssemblyStart, node)  # 조립 시작 노드는 (할 일 없음 — 그냥 통과)
        elseif matches_template(OpenBuildStep, node)  # 진행 중 빌드스텝 노드라면
            _diag_step += 1                 # 카운터 +1
            println("[DIAG] staging_plan: build step #$(_diag_step) ($(summary(node_id(node))))"); flush(stdout)  # 진단 출력
            # work updward through build steps
            # Set staging config of part as start_config(LiftIntoPlace(part))
            process_schedule_build_step!(
                node,
                sched,
                scene_tree,
                bounding_circles,
                staging_circles,
                ;
                build_step_buffer_radius=build_step_buffer_radius,  # `;` 뒤는 키워드 인자(이름 붙여 전달) — 조립단계마다 부풀릴 여유 반경
            )
        end
    end
    println("[DIAG] staging_plan: finished $(_diag_step) build steps; selecting assembly start configs..."); flush(stdout)  # 진단 출력 후 flush 로 버퍼 즉시 내보냄(;로 두 문장 한 줄에)
    # Update assembly start points so that none of the staging regions overlap
    select_assembly_start_configs_layered!(sched, scene_tree, staging_circles;  # 각 조립체의 시작(건설) 위치를 정해 적치영역이 겹치지 않게 함
        buffer_radius=buffer_radius,)                # buffer_radius 키워드로 여유 반경 전달
    println("[DIAG] staging_plan: select_assembly_start_configs done"); flush(stdout)  # 완료 진단 출력
    # TODO store a TransformNode in ProjectComplete() (or in the schedule itself,
    # once there is a dedicated ConstructionSchedule type) so that an entire
    # schedule can be moved anywhere. All would-be root TransormNodes will have
    # this root node as their parent, regardless of the edge structure of the
    # schedule graph
    return staging_circles, bounding_circles      # (적치원 사전, 경계원 사전) 두 값을 튜플로 반환
end


"""
    select_assembly_start_configs!(sched, scene_tree, staging_radii;
        buffer_radius=0.0)

Select the start configs (i.e., the build location) for each assembly. The
location is selected by minimizing distance to the assembly's staging location
while ensuring that no child's staging area overlaps with its parent's staging
area. Uses the same ring optimization approach as for selectig staging
locations.
"""
# 함수 인자에서 `;` 뒤는 키워드 인자 — buffer_radius=0.0 처럼 이름 붙여 호출(기본값 0.0).
# 각 조립체의 자식 "조립체"들을 부모 둘레의 "고리(ring)" 위에 겹치지 않게 배치(층층이 쌓는 layered 버전).
function select_assembly_start_configs_layered!(sched, scene_tree, staging_circles;
    buffer_radius=0.0,                               # 키워드 인자: 각 적치원에 더해줄 여유 반경
)
    # Update assembly start points so that none of the staging regions overlap
    # node_iterator + topological_sort_by_dfs : 위상정렬 순서대로 스케줄 노드를 하나씩 순회
    for start_node in node_iterator(sched, topological_sort_by_dfs(sched))
        if !matches_template(AssemblyComplete, start_node)  # "조립완료(AssemblyComplete)" 노드가 아니면
            continue                                 # 건너뜀
        end
        assembly_complete = node_val(start_node)     # 노드가 담은 AssemblyComplete 값
        node = entity(start_node)                    # 그 노드가 가리키는 실제 개체(부품/조립체)
        if matches_template(AssemblyNode, node)      # 그 개체가 조립체 노드라면
            # Apply ring solver with child assemblies (not objects)
            assembly = node                          # 보기 좋게 이름만 바꿔 둠
            # filter(조건, 모음) : 조건 통과 원소만 남김(파이썬 filter). k -> isa(k, AssemblyID) 는 익명함수(lambda).
            part_ids = sort(filter(k -> isa(k, AssemblyID),  # 자식들 중 ID 가 조립체(AssemblyID)인 것만 골라
                collect(keys(assembly_components(node)))))   # 정렬해 part_ids 로
            if isempty(part_ids)                     # 자식 조립체가 없으면
                continue                             # 이 조립체는 건너뜀
            end

            orig_ball = staging_circles[node_id(assembly)]  # 이 조립체의 원래 적치원(공) 보관
            new_ball = nothing                       # 갱신된 적치원(아래 루프에서 채움), 일단 nothing

            @info "Selecting staging location for $(summary(node_id(assembly)))"  # @info : 정보 로그 출력

            @assert haskey(staging_circles, node_id(assembly))  # 이 조립체의 적치원이 사전에 있는지 점검(없으면 에러)


            # 각 자식 부품이 어느 "조립 단계 번호"에 배치되는지 찾음(층 순서 결정용)
            steps_for_parts = find_step_numbers(start_node, part_ids, sched, scene_tree)
            # zip(a, b) : 두 배열을 짝지어 (id, step) 쌍으로 묶음(파이썬 zip) → Dict 로 변환
            steps_dict = Dict(zip(part_ids, steps_for_parts))  # 부품ID → 단계번호 사전
            @assert length(steps_for_parts) == length(part_ids)  # 개수가 맞는지 점검

            part_ids_left = part_ids                 # 아직 배치 안 된 부품들(처음엔 전부)

            _diag_outer = 0                          # 바깥 루프 횟수(폭주 감지용 카운터)
            while !isempty(part_ids_left)            # 배치할 부품이 남아있는 동안 반복
                _diag_outer += 1                     # 반복 횟수 +1
                println("[DIAG] assembly_start: $(summary(node_id(assembly))) outer iter=$(_diag_outer), parts_left=$(length(part_ids_left))"); flush(stdout)  # 진단 출력
                if _diag_outer > 10_000              # 1만 회 넘으면(부품이 안 줄어드는 폭주 상태)
                    error("[RUNAWAY] select_assembly_start_configs_layered! outer loop exceeded 10000 iterations for $(summary(node_id(assembly))) — part_ids_left not shrinking ($(length(part_ids_left)) left). No part fits per iteration.")  # 에러로 중단
                end
                # We continue this process until we don't have any more parts to place. At each
                # iteration, we determine the maximum number of components that can fit around
                # the current staging radius. If there are parts that remain, we increase the
                # staging radius from the previous "layer" and keep going.

                staging_circle = staging_circles[node_id(assembly)]   # 현재 조립체의 적치원
                staging_radius = staging_circle.radius + buffer_radius # 적치 반경 = 원 반경 + 여유

                # [식 for id in 모음] : 컴프리헨션(파이썬 [...] 과 동일). 남은 부품들의 반경 배열을 만듦.
                radii_left = [staging_circles[id].radius + buffer_radius for id in part_ids_left]  # 남은 부품들의 반경
                steps_left = [steps_dict[id] for id in part_ids_left]  # 남은 부품들의 단계 번호
                # unique : 중복 제거(set 비슷), sort! 로 오름차순 정렬(! = 제자리 정렬)
                unique_step_lengths = sort!(unique(steps_left))       # 남은 단계 번호들의 정렬된 고유 목록

                cnt = 1                              # 고려 중인 단계 인덱스(줄리아는 1부터 시작)
                can_fit_steps = 0                    # 현재 반경 둘레에 다 들어가는 "마지막 단계 번호"
                while cnt <= length(unique_step_lengths)  # 단계들을 작은 것부터 차례로 검토
                    current_step_consideration = unique_step_lengths[cnt]  # 지금 고려하는 단계 번호
                    # `.<=` : 원소별(브로드캐스트) 비교 → 각 원소가 기준 이하인지 참/거짓 배열(불리언 마스크)
                    bool_mask = steps_left .<= current_step_consideration  # 이 단계 이하인 부품들만 True
                    radii_k = radii_left[bool_mask]  # 마스크가 True 인 부품 반경만 추림(불리언 인덱싱)

                    # Determine if the staging radius can fit all components
                    # asin. : 각 원소에 arcsin 적용(브로드캐스트 `.`). 부품이 고리에서 차지하는 "반각"=asin(r/(r+적치반경)).
                    half_widths = asin.(radii_k ./ (radii_k .+ staging_radius))  # 각 부품의 반각(`./`,`.+`도 원소별)
                    can_fit = sum(half_widths) * 2 <= 2.0 * Float64(π)  # 전체 각(반각합×2)이 한 바퀴(2π) 이하면 다 들어감

                    if can_fit                       # 다 들어가면
                        can_fit_steps = current_step_consideration  # 이 단계까지 수용 가능으로 기록
                        cnt += 1                     # 다음 단계도 시도
                    else
                        break                        # 안 들어가면 멈춤
                    end
                end

                part_ids_for_opt = []                # 이번 층에서 실제 최적화에 넣을 부품 ID 들
                radii_for_opt = []                   # 그 부품들의 반경
                if can_fit_steps == 0
                    # Current staging radius cannot fit all of the components of the first step
                    # Let's select the maximum number of components in the first step that can
                    # fit. Selecting from the smallest radii
                    current_step_consideration = minimum(unique_step_lengths)  # 가장 이른(첫) 단계
                    bool_mask = steps_left .<= current_step_consideration       # 그 단계 이하 부품 마스크
                    part_ids_at_or_before_step = part_ids_left[bool_mask]       # 해당 부품 ID 들
                    radii = radii_left[bool_mask]                               # 해당 부품 반경들
                    sorted_idxs = sortperm(radii)    # sortperm : 정렬했을 때의 인덱스 순서(작은 반경부터) 반환
                    sorted_radii = radii[sorted_idxs]  # 반경을 오름차순으로 재배열
                    half_widths = asin.(sorted_radii ./ (sorted_radii .+ staging_radius))  # 각 부품 반각
                    # cumsum : 누적합. 누적반각×2 가 2π 이하인 마지막 위치를 findlast 로 찾음.
                    last_idx = findlast(cumsum(half_widths) * 2 .<= 2.0 * Float64(π))  # 들어갈 수 있는 마지막 부품 위치

                    idxs_for_opt = sorted_idxs[1:last_idx] # With step mask  # 작은 것부터 들어가는 만큼만 선택

                    part_ids_for_opt = part_ids_at_or_before_step[idxs_for_opt]  # 그 부품 ID 들
                    radii_for_opt = radii[idxs_for_opt]                          # 그 부품 반경들

                elseif can_fit_steps == maximum(unique_step_lengths)  # 모든 단계가 한 층에 다 들어가면
                    # Current staging radius can fit all of the assemblies
                    part_ids_for_opt = part_ids_left  # 남은 부품 전부 최적화 대상
                    radii_for_opt = radii_left        # 그 반경들 전부

                else
                    # We can fit all components upto can_fit_step, but not all of the remaining components
                    # We will select the maximum number of components in the next step that can fit in
                    # addition to all of the components from the can_fit_step
                    bool_mask = steps_left .<= can_fit_steps  # can_fit_steps 까지의 단계 부품들(이미 다 들어감)
                    part_ids_for_opt = part_ids_left[bool_mask]  # 그 부품 ID 들을 우선 확정
                    radii_for_opt = radii_left[bool_mask]        # 그 반경들

                    # 이미 차지한 둘레 각도(arc) — 다음 단계 부품을 추가로 끼울 여유를 계산하기 위함
                    arc_dist_used = sum(asin.(radii_for_opt ./ (radii_for_opt .+ staging_radius)))  # 사용된 반각의 합

                    # setdiff : 차집합(파이썬 set 의 -). 확정한 부품을 남은 목록에서 제거.
                    part_ids_left = setdiff(part_ids_left, part_ids_for_opt)  # 남은 부품 갱신
                    steps_left = [steps_dict[id] for id in part_ids_left]     # 남은 단계 갱신
                    radii_left = [staging_circles[id].radius + buffer_radius for id in part_ids_left]  # 남은 반경 갱신

                    bool_mask = steps_left .<= unique_step_lengths[cnt]  # 그 "다음 단계"까지의 부품 마스크

                    part_ids_at_or_before_step = part_ids_left[bool_mask]  # 다음 단계 후보 부품 ID 들
                    radii = radii_left[bool_mask]                          # 그 반경들
                    sorted_idxs = sortperm(radii)    # 작은 반경부터의 인덱스 순서
                    sorted_radii = radii[sorted_idxs]  # 오름차순 반경
                    half_widths = asin.(sorted_radii ./ (sorted_radii .+ staging_radius))  # 각 후보의 반각
                    # 이미 쓴 각(arc_dist_used)에 누적반각을 더한 값이 2π 이하인 마지막 위치 → 추가로 끼울 수 있는 만큼
                    last_idx = findlast((arc_dist_used .+ cumsum(half_widths)) * 2 .<= 2.0 * Float64(π))

                    # 삼항 `조건 ? A : B`(파이썬 A if 조건 else B). 들어갈 게 없으면(nothing) 0 으로.
                    last_idx = isnothing(last_idx) ? 0 : last_idx  # isnothing : 값이 nothing 인지 검사
                    idxs_for_opt = sorted_idxs[1:last_idx] # With step mask  # 추가로 넣을 부품 인덱스들

                    append!(part_ids_for_opt, part_ids_at_or_before_step[idxs_for_opt])  # 확정 목록에 이어붙임
                    append!(radii_for_opt, radii[idxs_for_opt])                          # 반경도 이어붙임
                end

                part_ids_left = setdiff(part_ids_left, part_ids_for_opt)  # 이번에 확정한 부품을 남은 목록에서 제거
                steps_left = [steps_dict[id] for id in part_ids_left]     # 남은 단계 갱신
                radii_left = [staging_circles[id].radius + buffer_radius for id in part_ids_left]  # 남은 반경 갱신

                # (...) 형태 컴프리헨션은 "제너레이터"(파이썬 () 제너레이터식). 필요할 때 하나씩 노드를 꺼냄(지연 평가).
                parts_for_opt = (get_node(scene_tree, part_id) for part_id in part_ids_for_opt)  # 이번 층 부품 노드들(제너레이터)
                radii_for_opt = [staging_circles[id].radius + buffer_radius for id in part_ids_for_opt]  # 이번 층 반경들

                ring_radius = -1                     # 고리 반경 초기값(-1 로 두어 첫 while 진입 보장)
                θ_star = nothing                     # 최적화로 구할 각도 배열(아직 없음). θ 는 그리스문자 theta — 변수 이름.
                # repeat to ensure correct alignment
                _diag_ring = 0                       # 고리정렬 루프 횟수 카운터
                # staging_radius(솔버가 키울 수 있음)와 ring_radius 가 수렴할 때까지 반복(차이 < 1e-6)
                while staging_radius - ring_radius > 1e-6
                    _diag_ring += 1                  # 반복 횟수 +1
                    if _diag_ring % 50 == 0          # % 는 나머지 연산 — 50회마다
                        println("[DIAG] assembly_start: ring-align loop iter=$(_diag_ring), staging_radius=$staging_radius, ring_radius=$ring_radius"); flush(stdout)  # 진단 출력
                    end
                    if _diag_ring > 1_000            # 1000회 넘으면(수렴 실패 폭주)
                        error("[RUNAWAY] select_assembly_start_configs_layered! ring-align loop exceeded 1000 iterations (each calls the solver) — staging_radius not converging. staging_radius=$staging_radius, ring_radius=$ring_radius")  # 에러 중단
                    end
                    θ_des = Vector{Float64}()        # 각 부품이 "있었으면 하는" 목표 각도들(빈 배열로 시작)
                    ring_radius = staging_radius      # 이번 회차의 고리 반경을 현재 적치반경으로 맞춤
                    for (part_id, part) in zip(part_ids_for_opt, parts_for_opt)  # (id, 노드) 쌍으로 순회
                        # retrieve staging config from LiftIntoPlace node
                        lift_node = get_node(sched, LiftIntoPlace(part))  # 이 부품의 "들어 제자리에" 노드 가져옴
                        # give coords of the dropoff point (we want `part` to be built as close as possible to here.)
                        # crucial: must be relative to the assembly origin
                        tr = relative_transform(                      # 부모(조립체) 기준 상대 변환의 평행이동 성분
                            global_transform(goal_config(start_node)),
                            global_transform(start_config(lift_node))).translation
                        tform = CoordinateTransformations.Translation(tr...)  # 그 평행이동으로 변환 객체 생성(... 는 펼치기)
                        geom = staging_circles[part_id]               # 이 부품의 적치원
                        # the vector from the circle center to the goal location
                        d_ = project_to_2d(tform.translation) - staging_circle.center  # 중심에서 목표지점으로 향하는 2D 벡터
                        # scale d_ to the appropriate radius, then shift tip vector from part center to geom.center
                        d = (d_ / norm(d_)) * ring_radius + geom.center  # 단위벡터로 정규화 후 고리반경만큼 늘리고 원 중심만큼 이동
                        push!(θ_des, atan(d[2], d[1]))  # atan(y, x) : 그 방향의 각도 → 목표각으로 추가
                    end
                    # optimize placement and increase staging_radius if necessary
                    θ_star, staging_radius = solve_ring_placement_problem(θ_des, radii_for_opt, ring_radius)  # 고리 배치 최적화(필요 시 반경 키움), 두 값 반환
                end

                # Compute staging config transforms (relative to parent assembly)
                tformed_geoms = Vector{LazySets.Ball2}()  # 배치 후 각 부품 적치원을 변환해 담을 배열
                # enumerate + zip : (번호 i, (θ, r, id, part) 묶음) 형태로 동시에 순회
                for (i, (θ, r, part_id, part)) in enumerate(zip(θ_star, radii_for_opt, part_ids_for_opt, parts_for_opt))
                    part_start_node = get_node(sched, AssemblyComplete(part))  # 이 부품(조립체)의 조립완료 노드
                    geom = staging_circles[part_id]  # 이 부품의 적치원
                    R = staging_radius + r           # 부품 중심이 놓일 고리 반경(적치반경 + 부품반경)
                    # shift by vector from geom.center to part origin
                    t = CoordinateTransformations.Translation(  # 극좌표(θ,R)를 직교좌표로 바꿔 평행이동 생성
                        R * cos(θ) + staging_circle.center[1] - geom.center[1],  # x = R·cosθ + 중심 - 원중심오프셋
                        R * sin(θ) + staging_circle.center[2] - geom.center[2],  # y = R·sinθ + 중심 - 원중심오프셋
                        0.0)                         # z = 0 (평면 배치)
                    # Get global orientation parent frame ʷRₚ
                    # ∘ : 함수/변환 "합성"(수학의 f∘g). 여기선 평행이동 t 에 항등 회전을 합쳐 아핀변환을 만듦.
                    tform = t ∘ identity_linear_map() # AffineMap transform
                    # set transform of start node
                    set_local_transform_in_global_frame!(start_config(part_start_node), tform)  # 시작 위치 변환을 설정
                    tform2D = CoordinateTransformations.Translation(t.translation[1:2]...)  # 2D 평행이동(x,y 만)
                    push!(tformed_geoms, tform2D(geom))  # 변환된 적치원을 모음에 추가
                end
                old_ball = staging_circles[node_id(assembly)]  # 갱신 전 적치원(공) 보관
                # overapproximate : 여러 원을 모두 감싸는 하나의 큰 원(바운딩 볼)로 "과대근사"
                new_ball = overapproximate(
                    vcat(tformed_geoms, staging_circles[node_id(assembly)]),  # vcat : 배열 세로 이어붙이기(기존 원 포함)
                    LazySets.Ball2{Float64,SVector{2,Float64}}  # 결과 타입: 2D 실수 공(원)
                )
                # 새 원이 옛 원을 완전히 포함하는지 점검(반경 ≥ 옛반경 + 중심이동거리). norm(.- ) 의 `.-` 은 원소별 뺄셈.
                @assert new_ball.radius + 1e-5 > old_ball.radius + norm(new_ball.center .- old_ball.center) "$(summary(node_id(assembly))) old ball $(old_ball), new_ball $(new_ball)"
                staging_circles[node_id(assembly)] = new_ball  # 적치원을 새 원으로 갱신(다음 층은 이걸 기준으로)
            end

            # add directly as staging circle of AssemblyComplete node
            assembly_complete.inner_staging_circle.base_geom = project_to_3d(orig_ball)  # 안쪽 적치원 = 원래(가장 처음) 원을 3D 로
            assembly_complete.outer_staging_circle.base_geom = project_to_3d(new_ball)   # 바깥 적치원 = 최종(가장 큰) 원을 3D 로
            @info "Updating staging_circle for $(summary(node_id(assembly))) to $(staging_circles[node_id(assembly)])"  # 갱신 로그
        end
    end
    sched                                            # 수정된 스케줄 반환
end


"""
    select_assembly_start_configs!(sched, scene_tree, staging_radii;
        buffer_radius=0.0)

Select the start configs (i.e., the build location) for each assembly. The
location is selected by minimizing distance to the assembly's staging location
while ensuring that no child's staging area overlaps with its parent's staging
area. Uses the same ring optimization approach as for selectig staging
locations.
"""
# 위 layered 버전의 단순(비층) 버전 — 자식 조립체들을 부모 둘레 고리에 한 번에 배치.
function select_assembly_start_configs!(sched, scene_tree, staging_circles;
    buffer_radius=0.0,                               # 키워드 인자: 적치원에 더할 여유 반경
)
    # Update assembly start points so that none of the staging regions overlap
    for start_node in node_iterator(sched, topological_sort_by_dfs(sched))  # 위상정렬 순서로 노드 순회
        if !matches_template(AssemblyComplete, start_node)  # 조립완료 노드가 아니면
            continue                                 # 건너뜀
        end
        assembly_complete = node_val(start_node)     # 노드의 AssemblyComplete 값
        node = entity(start_node)                    # 그 노드가 가리키는 개체
        if matches_template(AssemblyNode, node)      # 조립체 노드라면
            # Apply ring solver with child assemblies (not objects)
            assembly = node                          # 이름만 바꿔 둠
            part_ids = sort(filter(k -> isa(k, AssemblyID),  # 자식 중 조립체 ID 만 골라 정렬
                collect(keys(assembly_components(node)))))
            if isempty(part_ids)                     # 자식 조립체가 없으면
                continue                             # 건너뜀
            end
            @info "Selecting staging location for $(summary(node_id(assembly)))"  # 정보 로그
            # start_node = get_node(sched,AssemblyComplete(assembly))  # (옛 코드)
            # staging_radii
            @assert haskey(staging_circles, node_id(assembly))  # 적치원 존재 점검
            staging_circle = staging_circles[node_id(assembly)]  # 이 조립체의 적치원
            staging_radius = staging_circle.radius + buffer_radius  # 적치 반경 = 원 반경 + 여유
            ring_radius = -1                         # 고리 반경 초기값(-1 로 첫 while 진입 보장)
            parts = (get_node(scene_tree, part_id) for part_id in part_ids)  # 부품 노드들(제너레이터)
            # radii = [staging_circles[id].radius for id in part_ids]  # (옛 코드)
            radii = [staging_circles[id].radius + buffer_radius / 2 for id in part_ids]  # 각 부품 반경(여유 절반 추가)
            # θ_des = Vector{Float64}()  # (옛 코드)
            θ_star = nothing                         # 최적화로 구할 각도들(아직 없음)
            # repeat to ensure correct alignment
            while staging_radius - ring_radius > 1e-6  # 적치반경과 고리반경이 수렴할 때까지 반복
                θ_des = Vector{Float64}()            # 목표 각도들(빈 배열로 시작)
                ring_radius = staging_radius          # 이번 회차 고리반경을 현재 적치반경으로
                for (part_id, part) in zip(part_ids, parts)  # (id, 노드) 쌍으로 순회
                    # retrieve staging config from LiftIntoPlace node
                    lift_node = get_node(sched, LiftIntoPlace(part))  # 부품의 "들어 제자리에" 노드
                    # give coords of the dropoff point (we want `part` to be built as close as possible to here.)
                    # crucial: must be relative to the assembly origin
                    tr = relative_transform(          # 부모 기준 상대 변환의 평행이동 성분
                        global_transform(goal_config(start_node)),
                        global_transform(start_config(lift_node))).translation
                    tform = CoordinateTransformations.Translation(tr...)  # 평행이동 변환 생성(... 펼치기)
                    geom = staging_circles[part_id]   # 이 부품의 적치원
                    # the vector from the circle center to the goal location
                    d_ = project_to_2d(tform.translation) - staging_circle.center  # 중심→목표 2D 벡터
                    # scale d_ to the appropriate radius, then shift tip vector from part center to geom.center
                    d = (d_ / norm(d_)) * ring_radius + geom.center  # 정규화 후 고리반경만큼 늘리고 원중심 이동
                    push!(θ_des, atan(d[2], d[1]))    # atan(y,x) 로 방향 각도 → 목표각 추가
                end
                # optimize placement and increase staging_radius if necessary
                θ_star, staging_radius = solve_ring_placement_problem(  # 고리 배치 최적화(반경 키울 수 있음)
                    θ_des, radii, ring_radius)
            end
            # Compute staging config transforms (relative to parent assembly)
            tformed_geoms = Vector{LazySets.Ball2}()  # 변환된 적치원들을 담을 배열
            # enumerate + zip : (번호 i, (θ, r, id, part)) 형태로 동시 순회
            for (i, (θ, r, part_id, part)) in enumerate(zip(θ_star, radii, part_ids, parts))
                part_start_node = get_node(sched, AssemblyComplete(part))  # 이 부품의 조립완료 노드
                geom = staging_circles[part_id]      # 이 부품의 적치원
                R = staging_radius + r               # 부품 중심이 놓일 고리 반경
                # shift by vector from geom.center to part origin
                t = CoordinateTransformations.Translation(  # 극좌표(θ,R) → 직교좌표 평행이동
                    R * cos(θ) + staging_circle.center[1] - geom.center[1],  # x = R·cosθ + 중심 - 원중심오프셋
                    R * sin(θ) + staging_circle.center[2] - geom.center[2],  # y = R·sinθ + 중심 - 원중심오프셋
                    0.0)                             # z = 0 (평면)
                # Get global orientation parent frame ʷRₚ
                tform = t ∘ identity_linear_map() # AffineMap transform  # ∘ 합성: 평행이동 + 항등회전 = 아핀변환
                # set transform of start node
                # @info "Starting config: setting START config of $(node_id(start_node)) to $(tform)"  # (옛 로그)
                set_local_transform_in_global_frame!(start_config(part_start_node), tform)  # 시작 위치 변환 설정
                tform2D = CoordinateTransformations.Translation(t.translation[1:2]...)  # 2D 평행이동(x,y만)
                push!(tformed_geoms, tform2D(geom))  # 변환된 적치원 추가
            end
            old_ball = staging_circles[node_id(assembly)]  # 갱신 전 적치원
            new_ball = overapproximate(              # 모든 원을 감싸는 하나의 큰 원으로 과대근사
                vcat(tformed_geoms, staging_circles[node_id(assembly)]),  # 기존 원 포함해 세로로 합침
                LazySets.Ball2{Float64,SVector{2,Float64}}  # 결과 타입: 2D 원
            )
            # @assert new_ball.radius > old_ball.radius+norm(new_ball.center .- old_ball.center)  # (옛 점검)
            @assert new_ball.radius + 1e-5 > old_ball.radius + norm(new_ball.center .- old_ball.center) "$(summary(node_id(assembly))) old ball $(old_ball), new_ball $(new_ball)"  # 새 원이 옛 원 포함하는지 점검
            staging_circles[node_id(assembly)] = new_ball  # 적치원 갱신
            # add directly as staging circle of AssemblyComplete node
            assembly_complete.inner_staging_circle.base_geom = project_to_3d(old_ball)  # 안쪽 적치원 = 옛 원(3D)
            assembly_complete.outer_staging_circle.base_geom = project_to_3d(new_ball)  # 바깥 적치원 = 새 원(3D)
            @info "Updating staging_circle for $(summary(node_id(assembly))) to $(staging_circles[node_id(assembly)])"  # 갱신 로그
        end
    end
    sched                                            # 수정된 스케줄 반환
end

"""
    process_schedule_build_step!(node,sched,scene_tree,bounding_circles,staging_circles)

Select the staging configuration for all subcomponents to be added to `assembly`
during `build_step`, where `build_step::OpenBuildStep = node_val(node)`, and
`assembly = build_step.assembly.`
Also updates `bounding_radii[node_id(assembly)]` to reflect the increasing size
of assembly as more parts are added to it.
Updates:
- `staging_circles`
- the relevant `LiftIntoPlace` nodes (start_config and goal_config transforms)
Keyword Args:
- build_step_buffer_radius = 0.0 - amount by which to inflate each transport unit
when layout out the build step.
"""
# 한 조립단계(build step)에서 추가되는 부품들의 적치 위치를 정하고, 조립체의 경계원/적치원을 키운다.
# `;` 뒤 build_step_buffer_radius 는 키워드 인자(각 운반유닛을 부풀릴 여유 반경).
function process_schedule_build_step!(node, sched, scene_tree, bounding_circles,
    staging_circles; build_step_buffer_radius=0.0)

    open_build_step = node_val(node)                 # 노드가 담은 "진행 중 단계(OpenBuildStep)" 값
    assembly = open_build_step.assembly              # 이 단계가 속한 조립체
    start_node = get_node(sched, AssemblyComplete(assembly))  # 그 조립체의 조립완료 노드

    # optimize staging locations
    part_ids = sort(collect(keys(assembly_components(open_build_step))))  # 이 단계에서 더할 부품 ID 들(정렬)
    parts = (get_node(scene_tree, part_id) for part_id in part_ids)  # 부품 노드들(제너레이터)
    tforms = (child_transform(assembly, id) for id in part_ids) # working in assembly frame  # 각 부품의 조립체 기준 변환(제너레이터)
    θ_des = Vector{Float64}()                         # 목표 각도들(빈 배열)
    radii = Vector{Float64}()                         # 각 부품(운반유닛) 반경들
    geoms = Vector{LazySets.Ball2}()                  # 각 부품의 2D 원 형상들

    # bounding circle at current stage
    # get!(사전, 키, 기본값) : 키가 없으면 기본값을 넣고 그 값을 돌려줌(파이썬 dict.setdefault). 없으면 반경0 빈 원.
    bounding_circle = get!(bounding_circles, node_id(assembly), LazySets.Ball2(zeros(SVector{2,Float64}), 0.0))  # 현재까지 조립체 경계원
    for (part_id, part, tform) in zip(part_ids, parts, tforms)  # (id, 노드, 변환) 셋을 동시 순회
        tu = get_node(scene_tree, TransportUnitNode(part))  # 이 부품의 운반유닛(운반 로봇+부품) 노드
        tu_tform = tform ∘ inv(child_transform(tu, part_id))  # ∘ 합성, inv 역변환 — 운반유닛을 조립체 좌표로 옮기는 변환
        tu_geom = project_to_2d(tu_tform(get_base_geom(tu, HypersphereKey())))  # 운반유닛의 구 형상을 변환 후 2D 원으로 투영
        d = tu_geom.center - bounding_circle.center  # 경계원 중심에서 이 부품 중심으로의 벡터
        r = tu_geom.radius                            # 이 부품(운반유닛) 반경
        push!(geoms, tu_geom)                         # 형상 모음에 추가
        # Store transformed geometry for staging placement optimization
        push!(θ_des, wrap_to_pi(atan(d[2], d[1])))   # atan 으로 방향각 구하고 wrap_to_pi 로 (-π,π] 범위로 감싸 목표각 추가
        push!(radii, r + build_step_buffer_radius)   # 반경 + 여유를 추가
    end

    if !isempty(geoms)                                # 더할 부품이 하나라도 있으면
        # Compute new bounding circle which contains the assembly at the end of this build step
        new_bounding_circle = overapproximate(        # 부품들 + 기존 경계원을 모두 감싸는 새 경계원
            vcat(geoms, bounding_circle),             # 세로로 합침
            LazySets.Ball2{Float64,SVector{2,Float64}}  # 결과 타입: 2D 원
        )
        bounding_circles[node_id(assembly)] = new_bounding_circle # for assembly  # 조립체의 경계원 갱신
        bounding_circles[node_id(node)] = new_bounding_circle # for build step  # 이 단계의 경계원으로도 기록
        # incorporate new bounding circle into OpenBuildStep
        open_build_step.bounding_circle.base_geom = project_to_3d(new_bounding_circle)  # 단계 객체에 3D 경계원 저장
    end
    if length(geoms) == 1 && bounding_circle.radius < 1e-6  # 첫 단계에 부품이 딱 하나뿐이면(경계원도 비었으면)
        @info "Only 1 component to place at first build step--no need for ring optimization - $(summary(part_ids[1]))"  # 고리 최적화 불필요 로그
        θ_star, assembly_radius = θ_des, bounding_circle.radius  # 그냥 목표각 그대로, 반경 0 사용
    else
        # optimize placement and increase assembly_radius if necessary
        θ_star, assembly_radius = solve_ring_placement_problem(  # 고리 배치 최적화(필요 시 반경 키움), 두 값 반환
            θ_des,
            radii,
            bounding_circle.radius,
        )
        Δθ = θ_star .- θ_des                          # 최적해와 목표각의 차이(`.-` 원소별 뺄셈). Δ 는 그리스문자 delta.
        if maximum(abs.(Δθ)) > 0.1                    # abs. 는 원소별 절댓값 — 가장 큰 각도 변화가 0.1 보다 크면
            @info "ring placement solution $(node_id(node))" assembly_radius radii θ_des θ_star Δθ  # 상세 진단 로그(변수들 같이 출력)
        end
    end

    # Compute staging config transforms (relative to parent assembly)
    tformed_geoms = Vector{LazySets.Ball2}()         # 배치 후 변환된 원들을 담을 배열
    # enumerate + zip : (번호 i, (θ, r, id, part, tform)) 형태로 동시에 순회
    for (i, (θ, r, part_id, part, tform)) in enumerate(zip(θ_star, radii, part_ids, parts, tforms))
        tu = get_node(scene_tree, TransportUnitNode(part))  # 이 부품의 운반유닛 노드
        _child_tform = child_transform(tu, part_id).translation  # 운반유닛 안에서 부품 위치 오프셋
        lift_node = get_node(sched, LiftIntoPlace(get_node(scene_tree, part_id)))  # 이 부품의 "들어 제자리에" 노드
        # Compute the offset transform (relative to the assembly center)
        t = identity_linear_map()                    # 변환 초깃값 = 항등(아무 이동 없음)
        if length(geoms) == 1 && assembly_radius < 1e-6  # 첫 단계에 부품 하나뿐이면(반경 0)
            @info "Only 1 component to place at first build step--R = 0"  # 로그
            R = 0.0                                  # 고리 반경 0
            set_local_transform_in_global_frame!(start_config(lift_node), t)  # 시작 위치를 항등(중심)으로
        else
            R = assembly_radius + r                  # 부품 중심이 놓일 고리 반경(조립반경 + 부품반경)
            ### Use set_local_transform_in_global_frame!
            t = CoordinateTransformations.Translation(  # 극좌표(θ,R) → 직교좌표 평행이동
                R * cos(θ) + bounding_circle.center[1] + _child_tform[1],  # x = R·cosθ + 경계중심 + 부품오프셋
                R * sin(θ) + bounding_circle.center[2] + _child_tform[2],  # y = R·sinθ + 경계중심 + 부품오프셋
                0.0)                                 # z = 0 (평면)
            # @show t  # (디버그 출력 — 주석 처리됨)
            # set start config of lift node - have to add the ∘ inv(tform) because lift_node's goal_config() is already at tform
            tr = CoordinateTransformations.Translation(tform.translation[1:2]..., 0.0)  # 부품의 조립체내 위치(x,y만)
            set_local_transform_in_global_frame!(start_config(lift_node), t ∘ inv(tr))  # ∘ 합성, inv 역변환 — 목표가 이미 tform 이라 상쇄
        end
        # Store transformed geometry
        geom = project_to_2d(t(get_base_geom(tu, HypersphereKey())))  # 운반유닛 구를 t 로 변환 후 2D 원으로
        push!(tformed_geoms, geom)                   # 변환된 원 추가
    end

    # Compute next staging circle by overapproximating current bounding circle and new geometry
    if haskey(staging_circles, node_id(assembly))    # 기존 적치원이 있으면
        # carry over existing staging circle geometry
        push!(tformed_geoms, staging_circles[node_id(assembly)])  # 그것도 포함해 함께 감싸도록 추가
    end
    # get(사전, 키, 기본값) : get! 과 달리 없어도 사전에 안 넣고 기본값만 돌려줌. 없으면 반경0 빈 원.
    old_ball = get(staging_circles, node_id(assembly), LazySets.Ball2(zeros(SVector{2,Float64}), 0.0))  # 갱신 전 적치원
    new_ball = overapproximate(                      # 변환된 원들 + 조립체 경계원을 모두 감싸는 새 적치원
        vcat(tformed_geoms, bounding_circles[node_id(assembly)]),  # 세로로 합침
        LazySets.Ball2{Float64,SVector{2,Float64}}   # 결과 타입: 2D 원
    )
    @assert new_ball.radius + 1e-5 > old_ball.radius + norm(new_ball.center .- old_ball.center) "$(summary(node_id(assembly))) old ball $(old_ball), new_ball $(new_ball)"  # 새 원이 옛 원 포함하는지 점검
    staging_circles[node_id(assembly)] = new_ball    # 적치원 갱신
    # incorporate new bounding circle into OpenBuildStep
    @info "Updating staging_circle for $(summary(node_id(assembly))) to $(staging_circles[node_id(assembly)]) based on $(summary(node_id(node)))"  # 갱신 로그
    open_build_step.bounding_circle.base_geom = project_to_3d(bounding_circles[node_id(node)])  # 단계 객체에 3D 경계원 저장
    open_build_step.staging_circle.base_geom = project_to_3d(staging_circles[node_id(assembly)])  # 단계 객체에 3D 적치원 저장

    sched
end

"""
    solve_ring_placement_problem(θ_des,R,r,rmin)

Formulate and solve a JuMP Model that encodes a ring optimization problem:
    Min_θ sum((θ .- θ_des).^2)
    s.t.  no overlapping of circles placed along ring
If there are too many circles, the problem will be infeasible. Either allow R
to increase as a variable, or use a search to optimize R while repeating the
optimization.
return θ_star
"""
# 이 함수는 "원형 링 위에 여러 원(부품)을 서로 겹치지 않게 배치"하는 최적화 문제를 풉니다.
# θ_des=원하는 각도들, r=각 원의 반지름들, R=링 반지름, rmin=최소 반지름(기본값 0.0).
# `;` 뒤의 ϵ, weights 는 "키워드 인자"(파이썬 def f(*, eps=..., weights=...) 처럼 이름으로만 넘김).
# weights 의 기본값 ones(length(θ_des)) 는 "길이만큼 전부 1인 벡터"(파이썬 np.ones).
function solve_ring_placement_problem(θ_des, r, R, rmin=0.0;
    ϵ=1e-1, # buffer for increasing R when necessary
    weights=ones(length(θ_des))
)
    model = Model(default_geom_optimizer())                             # JuMP 최적화 모델 객체 생성(쓸 솔버를 지정)
    set_optimizer_attributes(model, default_geom_optimizer_attributes()...)  # 솔버 옵션 설정. `...`=튜플/배열을 펼쳐 여러 인자로 전달(파이썬 *args)

    θ_des = map(wrap_to_pi, θ_des)                                      # 각 각도를 -π~π 로 정규화. map(f,xs)=파이썬 [f(x) for x in xs]

    n = length(θ_des)                                                   # 배치할 원의 개수
    # @assert 조건 "메시지" : 조건이 거짓이면 에러내며 멈춤(파이썬 assert). $n,$r 은 문자열 보간(파이썬 f-string)
    @assert length(r) == n "length(r) != n for n=$n, r = $r"           # 반지름 개수가 각도 개수와 같은지 검사
    # sort θ (the unsorted vector will be returned at the end)
    idxs = sortperm(θ_des)                                             # 정렬했을 때의 "원래 인덱스 순서"(np.argsort)
    reverse_idxs = sortperm(idxs)                                      # 정렬 순서를 다시 원래대로 되돌리는 인덱스(끝에서 결과 복원용)
    θ_des = θ_des[idxs]                                                # 각도를 오름차순으로 재배열
    r = r[idxs]                                                        # 반지름도 같은 순서로 재배열
    # compute half widths in radians (required radial spacing between parts)
    # `.`이 붙은 연산(asin., ./, .+)은 "원소별(broadcast) 계산"(파이썬 np 벡터연산). 각 원이 차지하는 각도폭의 절반
    half_widths = asin.(r ./ (r .+ R))                                # 각 원의 반각 = asin(r/(r+R))
    # increase R and recompute half widths if ring is too small
    _diag_R_iter = 0                                                   # 무한루프 감지용 반복 카운터
    while sum(half_widths) * 2 >= 2.0 * Float64(π)                     # 모든 원의 폭 합이 한 바퀴(2π) 이상이면 링이 너무 작은 것
        _diag_R_iter += 1                                             # 반복 횟수 증가
        if _diag_R_iter % 50 == 0                                     # 50번마다(% = 나머지) 진단 메시지 출력
            println("[DIAG] solve_ring_placement: R-grow loop iter=$(_diag_R_iter), R=$R, sum(half_widths)*2=$(sum(half_widths)*2)"); flush(stdout)  # flush=출력 버퍼 즉시 비우기
        end
        if _diag_R_iter > 100_000                                     # 10만번 넘으면 수렴 실패로 간주(100_000 의 _ 는 자릿수 구분, 값은 100000)
            error("[RUNAWAY] solve_ring_placement_problem R-grow loop exceeded 100000 iterations — R not converging. R=$R, r=$r, sum(half_widths)*2=$(sum(half_widths)*2)")  # 에러 발생시켜 중단
        end
        @info "R = $R is too small----sum(half_widths)*2 = $(sum(half_widths)*2)"  # @info=정보 로그 출력(파이썬 logging.info)
        R = R * sum(half_widths) / (Float64(π)) + ϵ                   # R 을 키움(폭 합 비율만큼 + 여유 ϵ)
        half_widths = asin.(r ./ (r .+ R))                           # 커진 R 로 반각 다시 계산
        @info "Increased R to $R. sum(half_widths)*2 = $(sum(half_widths)*2)"  # 커진 R 로그 출력
    end
    # @variable : JuMP 매크로. 최적화 "결정변수" 선언. θ[1:n]=길이 n 짜리 변수 배열
    @variable(model, θ[1:n])
    # Constrain order and spacing of elements of θ
    for i in 1:n-1                                                    # 인접한 원 쌍마다(1:n-1 = 1부터 n-1까지, 끝 포함)
        # @constraint : JuMP 매크로. 최적화 "제약식" 추가. 앞 원의 오른쪽 끝 <= 뒤 원의 왼쪽 끝(겹치지 않게)
        @constraint(model, θ[i] + half_widths[i] <= θ[i+1] - half_widths[i+1])
    end
    # wrap-around constraint
    # 마지막 원과 첫 원 사이도 겹치지 않게(2π 를 더해 "원형"으로 이어줌)
    @constraint(model, θ[n] + half_widths[n] <= θ[1] - half_widths[1] + 2.0 * Float64(π))
    # @objective : JuMP 매크로. 목적함수 지정. Min=최소화. (θ-원하는각도)^2 의 가중합을 최소화(.* .- .^ 는 원소별 연산)
    @objective(model, Min, sum(weights .* (θ .- θ_des) .^ 2))

    optimize!(model)                                                  # 솔버 실행(!=model 을 직접 수정해 해를 채워넣음)
    if !(primal_status(model) == MOI.FEASIBLE_POINT)                  # 해가 "실행가능한 점"이 아니면(=풀이 실패)
        @warn "Ring optimization failed!"                            # @warn=경고 로그 출력
    end

    # value.(θ)=각 변수의 최적값을 원소별로 추출(.은 broadcast). reverse_idxs 로 원래 순서로 되돌려 반환
    return value.(θ)[reverse_idxs], R                                # (최적 각도들, 사용한 링 반지름 R) 튜플 반환
end

"""
    calibrate_transport_tasks!(sched)

Set the appropriate transforms for all transport tasks such that
- FormTransportUnit moves the object from its initial condition to its
    transport-unit-relative transform: `start_config(n::FormTransportUnit)` will
    be directly below the object's start config.
- DepositTransportUnit
"""
# 모든 운반 작업에 대해 적절한 좌표변환을 설정(보정)하는 함수.
function calibrate_transport_tasks!(sched)
    for node in get_nodes(sched)                            # 스케줄의 모든 노드 순회
        if matches_template(AssemblyComplete, node)         # "조립 완료" 노드이면
            assembly = entity(node)                         # 그 노드가 다루는 조립체
            for (id, tf) in assembly_components(assembly)   # 조립체 구성요소의 (id, 목표변환) 쌍 순회
                if matches_template(ObjectID, id)           # id 가 물체 id 이면
                    cargo = ObjectNode(id, GeomNode(nothing))     # 형상 없는(빈) 물체 노드 생성(여기선 식별용)
                else
                    cargo = AssemblyNode(id, GeomNode(nothing))   # 아니면 빈 조립체 노드 생성
                end
                start_node, form_transport, go_node, deposit_node, lift_node = get_transport_node_sequence(sched, cargo)  # 운반 노드 5종 받기(튜플 언패킹)
                cargo = entity(lift_node)                   # 실제 화물 객체를 배치 노드에서 다시 꺼냄
                # line up lift_node to target assembly
                set_local_transform!(goal_config(lift_node), tf)  # 배치 노드의 목표 위치를 조립체 내 목표변환 tf 로 설정
                # line up deposit and collect nodes with floor
                align_construction_predicates!(sched, start_node, form_transport)  # 집기 자세 정렬(시작↔유닛구성)
                align_construction_predicates!(sched, lift_node, deposit_node)     # 내려놓기 자세 정렬(배치↔하역)
            end
        end
    end
    return sched
end

"""
    align_construction_predicates!(sched,start::Union{ObjectStart,AssemblyComplete,LiftIntoPlace},t::Union{DepositCargo,FormTransportUnit})

Line up pick up and drop off so that the carrying config of the cargo is directly
under its deployed config.
"""
# 화물을 집는(pick up) 자세와 내려놓는(drop off) 자세를 정렬해, 실린 화물이 놓일 자리 바로 위에 오게 하는 함수.
# 인자 타입에 Union{...} 을 써서 start, t 가 각각 "여러 타입 중 하나"일 때만 이 메서드가 호출됨(다중 디스패치).
function align_construction_predicates!(sched, start::Union{ObjectStart,AssemblyComplete,LiftIntoPlace}, t::Union{DepositCargo,FormTransportUnit})
    transport_unit = entity(t)                              # t 노드가 다루는 운반유닛 객체
    cargo = entity(start)                                   # 시작 노드가 다루는 화물 객체
    @assert node_id(cargo) == cargo_id(transport_unit)      # 화물 id 와 운반유닛이 나르는 화물 id 가 같은지 검증
    @assert has_parent(cargo_deployed_config(t), start_config(start))  # 좌표계 종속관계가 기대대로인지 검증
    @assert has_parent(cargo_loaded_config(t), cargo_deployed_config(t))  # 실린 좌표가 놓인 좌표에 종속돼 있는지 검증

    # Park Transport Unit so that cargo can drop straight down
    tform = child_transform(transport_unit, node_id(cargo))  # 운반유닛 기준 화물의 상대 변환
    # .translation[3] = 변환의 z(높이) 성분. 두 z 의 차이를 구함(화물을 수직으로 내릴 거리)
    delta_z = tform.translation[3] - global_transform(cargo_deployed_config(t)).translation[3]
    # TODO would be nice to have constrained transforms (e.g., fix to X-Y plane)
    set_local_transform!(
        cargo_loaded_config(t),                             # 대상: 실린 화물 좌표계
        CoordinateTransformations.Translation(0.0, 0.0, delta_z) ∘ identity_linear_map()  # z 만큼 평행이동(∘=합성)
    ) # relative to cargo_deployed_config(t)
end
# 다중 디스패치: 인자가 CustomNode 두 개일 때 → 내부 값(node_val)을 꺼내 위 메서드로 위임(한 줄 정의)
align_construction_predicates!(sched, a::CustomNode, b::CustomNode) = align_construction_predicates!(sched, node_val(a), node_val(b))

"""
    get_transport_node_sequence(sched,cargo::Union{AsemblyNode,ObjectNode})

Retrieves the following node sequence from sched for transporting `cargo`.
    ObjectStart / AssemblyComplete
    FormTransportUnit
    TransportUnitGo
    DepositCargo
    LiftIntoPlace
example
```julia
start, form_transport, go, deposit, lift = get_transport_node_sequence(sched,cargo)
```
"""
# 화물 cargo 를 옮기는 데 필요한 노드 5종(시작/유닛구성/이동/하역/배치)을 순서대로 찾아 반환.
# cargo::Union{AssemblyNode,ObjectNode} = cargo 가 조립체 또는 물체 타입일 때만 이 메서드 사용(다중 디스패치).
function get_transport_node_sequence(sched, cargo::Union{AssemblyNode,ObjectNode})
    if matches_template(ObjectNode, cargo)                   # 화물이 물체이면
        start_node = get_node(sched, ObjectStart(cargo))    # 시작 노드는 ObjectStart
    else
        start_node = get_node(sched, AssemblyComplete(cargo))  # 조립체이면 AssemblyComplete
    end
    form_transport = get_node(sched, FormTransportUnit(TransportUnitNode(cargo)))  # 운반유닛 구성 노드
    transport_unit = entity(form_transport)                 # 그 노드가 다루는 운반유닛 객체
    go_node = get_node(sched, TransportUnitGo(transport_unit))   # 운반유닛 이동 노드
    deposit_node = get_node(sched, DepositCargo(transport_unit)) # 화물 하역 노드
    lift_node = get_node(sched, LiftIntoPlace(cargo))       # 제자리에 들어올리는 배치 노드
    return start_node, form_transport, go_node, deposit_node, lift_node  # 5개를 튜플로 반환
end

"""
    transport_sequence_sanity_check(sched,cargo)

Print out the sequence of "stops" for the transport of `cargo`.
"""
# 화물 운반 과정의 각 "정차 지점" 변환을 출력해 눈으로 확인하는 디버그용 함수.
function transport_sequence_sanity_check(sched, cargo)
    # 좌변에 여러 변수 = "튜플 언패킹"(파이썬 a,b,c = ...). 운반 노드 5개를 한 번에 받음
    start_node, form_transport, go_node, deposit_node, lift_node = get_transport_node_sequence(sched, cargo)
    # @show : 표현식과 그 결과값을 함께 출력하는 매크로(파이썬 print(f"{expr=}") 와 비슷한 디버그용)
    @show global_transform(start_config(start_node))         # 시작 노드의 전역 위치
    @show global_transform(cargo_deployed_config(form_transport))  # (적재 전) 화물 놓인 위치
    @show global_transform(cargo_loaded_config(form_transport))    # (적재 후) 화물이 실린 위치
    @show global_transform(start_config(form_transport))     # 운반유닛 구성 시작 위치
    @show global_transform(start_config(go_node))            # 이동 시작 위치
    @show global_transform(goal_config(go_node))             # 이동 목표 위치
    @show global_transform(start_config(deposit_node))       # 하역 시작 위치
    @show global_transform(cargo_loaded_config(deposit_node))   # 하역 직전(실린 상태) 위치
    @show global_transform(cargo_deployed_config(deposit_node)) # 하역 후(내려놓은) 위치
    @show global_transform(start_config(lift_node))          # 들어올리기 시작 위치
    @show global_transform(goal_config(lift_node))           # 최종 목표(제자리) 위치
    return                                                   # 반환값 없음(출력만 함)
end

"""
    get_max_object_transport_unit_radius(scene_tree,key=HypersphereKey())
"""
# 물체를 나르는 운반유닛들 중 "가장 큰 경계구의 반지름"을 찾는 함수. key=어떤 형상 표현을 쓸지(기본 구).
function get_max_object_transport_unit_radius(scene_tree, key=HypersphereKey())
    r = 0.0                                                   # 지금까지 본 최대 반지름
    for n in get_nodes(scene_tree)                           # 씬트리의 모든 노드 순회
        if matches_template(TransportUnitNode, n)            # 운반유닛 노드이고
            if matches_template(ObjectNode, cargo_type(n))   # 그 화물이 물체(부품) 타입이면
                r = max(r, get_base_geom(n, key).radius)     # 그 경계구 반지름과 비교해 더 큰 값으로 갱신
            end
        end
    end
    return r                                                 # 최댓값 반환
end

export set_scene_tree_to_initial_condition!   # 이 함수를 외부(using ConstructionBots)에서 바로 쓸 수 있게 공개

# 아래는 "다중 디스패치" 예시 모음 — 같은 이름 함수를 인자 "타입"별로 여러 개 정의하면,
# 호출할 때 줄리아가 인자 타입을 보고 맞는 메서드를 자동으로 고름(파이썬엔 없는 기능).
# `f(x) = ...` 형태는 한 줄짜리 함수 정의(축약형).
get_start_node(n::SceneNode, sched) = get_node(sched, get_start_node(n))  # (SceneNode, sched) 2인자: 먼저 시작노드 종류를 정하고 스케줄에서 꺼냄
get_start_node(n::RobotNode) = RobotStart(n)                   # 로봇이면 시작노드는 RobotStart
get_start_node(n::ObjectNode) = ObjectStart(n)                 # 물체면 ObjectStart
get_start_node(n::AssemblyNode) = AssemblyComplete(n)          # 조립체면 AssemblyComplete
get_start_node(n::TransportUnitNode) = FormTransportUnit(n)    # 운반유닛이면 FormTransportUnit

# n 이 DepositCargo 타입일 때의 메서드: 들어오는 이웃 중 OpenBuildStep(부모 조립단계)을 찾아 반환.
function get_parent_build_step(sched, n::DepositCargo)
    for v in inneighbors(sched, n)                            # n 으로 들어오는 이웃 노드 인덱스들 순회
        np = get_node(sched, v)                               # 그 인덱스의 노드 객체
        if matches_template(OpenBuildStep, np)                # 그게 "열린 조립단계"이면
            return np                                        # 즉시 반환
        end
    end
    return nothing                                           # 못 찾으면 nothing(파이썬 None) 반환
end
# Union{A,B} = "A 또는 B 타입"일 때 이 메서드 사용. 해당 운반의 DepositCargo 로 위임해 부모 단계를 찾음
get_parent_build_step(sched, n::Union{FormTransportUnit,TransportUnitGo}) = get_parent_build_step(sched, get_node(sched, DepositCargo(entity(n))))
# n 이 로봇의 Go/Start 일 때: 나가는 엣지가 있으면 그 다음 노드로 재귀(거슬러 따라가며 부모 단계 탐색)
function get_parent_build_step(sched, n::Union{RobotGo,RobotStart})
    if outdegree(sched, n) > 0                               # 나가는 엣지(out-degree)가 1개 이상이면
        return get_parent_build_step(sched, first(outneighbors(sched, n)))  # 첫 후속 노드로 재귀 호출
    end
    return nothing                                          # 없으면 nothing
end
get_parent_build_step(sched, n::ScheduleNode) = get_parent_build_step(sched, n.node)  # ScheduleNode 면 내부 .node 로 위임
get_parent_build_step(sched, v::Int) = get_parent_build_step(sched, get_node(sched, v))  # 정수 인덱스면 노드로 바꿔 위임
get_first_build_step(sched, n::AssemblyStart) = get_node(sched, first(outneighbors(sched, n)))  # 조립 시작노드의 첫 후속 = 첫 조립단계
get_first_build_step(sched, n::ScheduleNode) = get_first_build_step(sched, n.node)    # ScheduleNode 면 내부 .node 로 위임
get_first_build_step(sched, n::CustomNode) = get_first_build_step(sched, node_val(n))  # CustomNode 면 그 값으로 위임


"""
    set_scene_tree_to_initial_condition!(scene_tree,sched)

Once the staging plan has been computed, this function moves all entities to
their starting locations.
"""
# 적치(staging) 계획이 정해진 뒤, 모든 개체를 각자의 시작 위치로 옮기는 함수.
# `;` 뒤 remove_all_edges 는 키워드 인자(먼저 씬트리의 모든 엣지를 끊을지 여부).
function set_scene_tree_to_initial_condition!(scene_tree, sched;
    remove_all_edges=false,
)
    if remove_all_edges                                          # 옵션이 켜져 있으면
        for e in collect(edges(scene_tree))                     # collect=이터레이터를 배열로 모음(순회 중 수정 안전하게)
            force_remove_edge!(scene_tree, edge_source(e), edge_target(e))  # 각 엣지(출발→도착)를 강제로 제거
        end
    end
    # topological_sort_by_dfs : DFS 기반 위상정렬(부모를 자식보다 먼저). node_iterator 로 그 순서대로 노드 순회
    for scene_node in node_iterator(scene_tree, topological_sort_by_dfs(scene_tree))
        if has_vertex(sched, get_start_node(scene_node))        # 이 개체의 시작 노드가 스케줄에 있으면
            n = get_start_node(scene_node, sched)               # 스케줄에서 그 시작 노드를 가져옴
            goal = global_transform(start_config(n))            # 목표 위치 = 그 시작 노드의 전역 시작 위치
        else
            goal = identity_linear_map()                        # 없으면 항등변환(=원점, 변환 없음)
        end
        set_desired_global_transform!(scene_node, goal)         # 개체를 목표 위치로 이동
    end
    # for n in get_nodes(sched)
    #     if matches_template(Union{RobotStart,ObjectStart,AssemblyStart,FormTransportUnit},n)
    #         scene_node = get_node(scene_tree,node_id(entity(n)))
    #         # @assert has_parent(scene_node,scene_node)
    #         # set_local_transform!(scene_node,global_transform(start_config(n)))
    #         set_desired_global_transform!(scene_node,global_transform(start_config(n)))
    #     end
    # end
    scene_tree
end

"""
    select_initial_object_grid_locations!(sched,scene_tree,vtxs)

Cycle through `vtxs`, placing an object at each vertex until all objects have
been placed.
"""
# 격자 좌표 vtxs 를 차례로 돌며 각 물체의 "초기 위치"를 지정하는 함수.
function select_initial_object_grid_locations!(sched, vtxs)
    nodes = Vector{ObjectNode}()                                   # 물체 노드들을 담을 빈 벡터
    # collect nodes by walking through the schedule, so that the objects will be
    # sorted by precedence
    for node in filtered_topological_sort(sched, LiftIntoPlace)    # 스케줄을 위상정렬 순서로(선후관계대로) 순회
        cargo = entity(node)                                      # 그 노드가 다루는 화물 꺼내기
        if matches_template(ObjectNode, cargo)                    # 화물이 "물체(부품)"이면
            push!(nodes, cargo)                                   # 목록에 추가
        end
    end
    # map(익명함수, vtxs) : 각 좌표 v 를 평행이동 변환으로 변환(파이썬 [f(v) for v in vtxs]). ∘ = 함수 합성
    tforms = map(
        v -> CoordinateTransformations.Translation(v[1], v[2], v[3]) ∘ identity_linear_map(),
        vtxs
    )                                                            # 좌표들 → 변환들의 벡터
    # cycle(tforms) : 변환 목록을 무한 반복(물체가 좌표보다 많으면 처음 좌표부터 다시 사용)
    for (node, tform) in zip(nodes, Base.Iterators.cycle(tforms))  # (물체, 변환) 쌍 순회
        start_node = get_node(sched, ObjectStart(node))          # 그 물체의 시작 노드 가져오기
        set_desired_global_transform!(start_config(start_node), tform)  # 시작 위치를 해당 격자점으로 설정
    end
    sched
end

"""
    add_robots_to_scene!(scene_tree,vtxs,geoms=(default_robot_geom() for v in vtxs))

For each vtx in `vtxs`, place a robot at that location and add it to `scene_tree`
"""
# 각 좌표 vtxs 에 로봇을 한 대씩 놓아 씬트리에 추가하는 함수.
# geoms 기본값 (default_robot_geom() for v in vtxs) = "제너레이터"(파이썬 generator). vtxs 개수만큼 형상을 게으르게 생성.
function add_robots_to_scene!(scene_tree, vtxs, geoms=(default_robot_geom() for v in vtxs))
    # zip = 두 컬렉션을 짝지어 순회(파이썬 zip). Base.Iterators.cycle(geoms) = geoms 를 무한 반복(부족하면 처음부터 다시)
    for (vtx, geom) in zip(vtxs, Base.Iterators.cycle(geoms))      # (위치, 형상) 쌍 순회
        tform = CoordinateTransformations.Translation(vtx[1], vtx[2], 0.0) ∘ identity_linear_map()  # (x,y,0) 평행이동 변환
        robot_node = add_node!(scene_tree,
            RobotNode(get_unique_id(RobotID), GeomNode(geom)))    # 고유 id 와 형상으로 로봇 노드 생성·추가
        set_local_transform!(robot_node, tform)                  # 로봇을 그 위치로 이동
    end
    scene_tree
end

"""
    set_robot_start_configs!(sched,scene_tree)

For each `n::RobotNode` in `SceneTree`, add a corresponding `RobotStart` and
`RobotGo` node and set the start transform to `local_transform(n)`.
"""
# 씬트리의 각 로봇 노드마다 스케줄에 RobotStart(시작)와 RobotGo(이동) 노드를 만들고 연결하는 함수.
function set_robot_start_configs!(sched, scene_tree)
    for node in get_nodes(scene_tree)                              # 씬트리의 모든 노드 순회
        if matches_template(RobotNode, node)                      # 로봇 노드이면
            if !has_vertex(sched, RobotStart(node))               # 스케줄에 이 로봇의 시작 노드가 없으면
                start_node = add_node!(sched, RobotStart(node))   # 새로 추가
            else
                start_node = get_node(sched, RobotStart(node))    # 있으면 기존 것 가져오기
            end
            set_local_transform!(start_config(start_node), global_transform(node))  # 시작 위치를 로봇의 현재 전역 위치로 설정
            if !has_vertex(sched, RobotGo(node))                  # 이동(Go) 노드가 없으면
                go_node = add_node!(sched, RobotGo(node))         # 새로 추가
            else
                go_node = get_node(sched, RobotGo(node))          # 있으면 가져오기
            end
            add_edge!(sched, start_node, go_node)                # 시작 → 이동 순서 엣지 연결
            set_parent!(start_config(go_node), goal_config(start_node))  # 이동의 시작점을 시작노드의 목표점에 종속시킴(연결)
        end
    end
    sched
end

"""
    construct_vtx_array(;
        origin=SVector(0.0,0.0),
        spacing=(1.0,1.0),
        ranges=(-10:10,-10:10),
        obstacles=nothing,
        bounds=nothing,
        )

Construct a regular array of vertices over `ranges`, beginning at `origin` and
spaced by `spacing`, removing all vertices that fall within `obstacles` or
outside of `bounds`.
"""
# 격자 형태의 점들을 만드는 함수. 인자 목록이 `(;` 로 시작 → 모두 키워드 인자(이름으로만 넘김).
# origin=시작점, spacing=간격, ranges=각 축의 인덱스 범위, obstacles=장애물(이 안의 점 제외), bounds=경계(밖의 점 제외).
function construct_vtx_array(;
    origin=SVector(0.0, 0.0, 0.0),
    spacing=(1.0, 1.0, 0.0),
    ranges=(-10:10, -10:10, 0:0),
    obstacles=nothing,
    bounds=nothing
)
    pts = Vector{SVector{3,Float64}}()                            # 결과 점들을 담을 빈 벡터(3D 점 SVector)
    # Base.Iterators.product(ranges...) : 여러 범위의 데카르트 곱(파이썬 itertools.product). 모든 격자칸 조합 생성
    for idxs in Base.Iterators.product(ranges...)                # 각 격자 인덱스 조합 (ix, iy, iz) 순회
        # map(i -> spacing[i]*idxs[i], 1:length(spacing)) : 축마다 간격×인덱스 계산. ...로 펼쳐 SVector 생성
        pt = origin + SVector(map(i -> spacing[i] * idxs[i], 1:length(spacing))...)  # 실제 3D 좌표 = 원점 + 오프셋
        pt2d = project_to_2d(pt)                                  # 평면(2D)으로 투영(경계/장애물 판정은 2D 로)
        legal = true                                             # 이 점이 유효한지 플래그(기본 true)
        if !(bounds === nothing)                                 # bounds 가 주어졌으면(=== 는 동일성 비교, nothing 은 파이썬 None)
            for ob in bounds                                     # 각 경계 영역에 대해
                if !(pt2d in ob)                                # 점이 경계 안에 없으면(in = 포함 검사)
                    legal = false                              # 무효 처리
                    break                                      # 더 볼 필요 없으니 탈출
                end
            end
        end
        if !(obstacles === nothing)                             # obstacles 가 주어졌으면
            for ob in obstacles                                # 각 장애물에 대해
                if pt2d in ob                                  # 점이 장애물 안에 있으면
                    legal = false                              # 무효 처리
                    break                                      # 탈출
                end
            end
        end
        if legal                                               # 유효한 점만
            push!(pts, pt)                                      # 결과에 추가
        end
    end
    return pts                                                  # 격자 점들의 벡터 반환
end


"""
    init_transport_units(scene_tree, robot_shape)
"""
# 씬트리의 모든 화물에 대해 운반유닛을 만들어 추가하는 함수. kwargs...=받은 키워드 인자를 그대로 전달.
function init_transport_units!(scene_tree; kwargs...)
    cvx_hulls = compute_hierarchical_2d_convex_hulls(scene_tree)   # 각 화물의 2D 볼록껍질(외곽선) 계산 → id=>점들 매핑
    for (id, pts) in cvx_hulls                                     # (화물 id, 외곽 점들) 쌍 순회
        # 삼항연산자 `조건 ? A : B` (파이썬 A if 조건 else B). 점이 없으면 continue, 있으면 nothing(아무것도 안 함)
        isempty(pts) ? continue : nothing                        # 빈 껍질이면 이 화물은 건너뜀
        cargo = get_node(scene_tree, id)                         # id 로 화물 노드 가져오기
        transport_unit = configure_transport_unit(cargo, pts; kwargs...)  # 그 화물의 운반유닛 구성(키워드 그대로 넘김)
        if has_vertex(scene_tree, node_id(transport_unit))      # 같은 운반유닛이 이미 트리에 있으면
            @warn "scene tree already has node $(node_id(transport_unit))"  # 경고만 출력(중복 추가 방지)
        else
            add_node!(scene_tree, transport_unit)               # 없으면 새로 추가
        end
    end
    scene_tree, cvx_hulls                                       # (씬트리, 볼록껍질들) 튜플 반환
end

"""
    configure_transport_unit(cargo, pts;

Define the transport unit for cargo. `pts` are the eligible support points
"""
# 화물(cargo)을 옮길 "운반유닛"을 구성하는 함수. pts=화물을 받칠 수 있는 후보 점들.
# `;` 뒤 robot_radius, robot_height 는 키워드 인자(로봇 반지름/높이 기본값).
function configure_transport_unit(cargo, pts;
    robot_radius=default_robot_radius(),
    robot_height=default_robot_height()
)
    # initialize transport node with cargo id
    base_rect = get_base_geom(cargo, HyperrectangleKey())          # 화물의 직육면체 경계상자(중심+반치수) 가져오기
    zmin = base_rect.center[3] .- base_rect.radius[3]             # 화물 바닥 z 좌표 = 중심z - 반높이(.−은 원소별 빼기). [3]=3번째(z, 1부터)
    # Translation(...) ∘ identity_linear_map() : 평행이동 변환. ∘ = 함수 합성(이동 다음 항등 선형변환 적용)
    cargo_tform = CoordinateTransformations.Translation(0.0, 0.0, robot_height - zmin) ∘ identity_linear_map()  # 로봇 위에 화물을 얹는 z 오프셋
    # node_id(cargo) => cargo_tform : Pair(키=>값) 생성(파이썬 dict 의 key:value 와 비슷)
    transport_unit = TransportUnitNode(node_id(cargo) => cargo_tform)  # 화물 id 와 그 상대변환으로 운반유닛 노드 생성
    support_pts = select_support_locations(VPolygon(pts), robot_radius)  # 후보 점들로 볼록다각형 만들고, 로봇이 설 지지점 선택
    for pt in support_pts                                         # 각 지지점에 대해
        tform = CoordinateTransformations.Translation(pt[1], pt[2], 0.0,) ∘ identity_linear_map()  # 그 (x,y) 위치로 평행이동 변환
        add_robot!(transport_unit, tform)                        # 그 위치에 로봇 한 대를 운반유닛에 추가
    end
    transport_unit                                              # 완성된 운반유닛 반환(함수 마지막 값이 곧 반환값)
end

"""
    add_temporary_invalid_robots!(scene_tree,transport_unit;
        geom=default_robot_geom(), with_edges=false)

Add invalid robots corresponding to the robots that would be part of
`transport_unit`.
"""
# transport_unit 가 필요로 하는 로봇들을 "임시(무효 id)" 노드로 씬트리에 추가하는 함수.
# `;` 뒤 geom, with_edges 는 키워드 인자(geom=로봇 형상 기본값, with_edges=부모-자식 엣지도 연결할지).
function add_temporary_invalid_robots!(scene_tree, transport_unit;
    geom=default_robot_geom(),
    with_edges=false,
)
    for (id, tform) in robot_team(transport_unit)                   # 팀의 (로봇 id, 변환) 쌍 순회
        if !has_vertex(scene_tree, id)                            # 그 id 노드가 아직 씬트리에 없으면
            robot_node = add_node!(scene_tree, RobotNode(id, GeomNode(geom)))  # 새 로봇 노드를 추가
        else
            robot_node = get_node(scene_tree, id)                # 이미 있으면 그 노드를 가져옴
        end
        if with_edges                                           # 엣지 연결 옵션이 켜져 있으면
            set_child!(scene_tree, transport_unit, robot_node)  # transport_unit 의 자식으로 로봇을 연결
        end
    end
    return scene_tree
end

"""
    add_temporary_invalid_robots!(scene_tree;kwargs...)

Call `add_temporary_invalid_robots!(scene_tree, n;kwargs...)` for all
`n::TransportUnitNode`.
"""
# 두 번째 메서드(다중 디스패치): 인자가 scene_tree 하나일 때 → 모든 TransportUnitNode 에 대해 위 메서드를 호출.
# kwargs... : 받은 키워드 인자들을 통째로 모아 다음 호출에 그대로 전달(파이썬 **kwargs).
function add_temporary_invalid_robots!(scene_tree; kwargs...)
    for n in get_nodes(scene_tree)                                 # 씬트리의 모든 노드 순회
        if matches_template(TransportUnitNode, n)                 # 운반유닛 노드이면
            add_temporary_invalid_robots!(scene_tree, n; kwargs...)  # 그 유닛에 대해 임시 로봇 추가(키워드 그대로 넘김)
        end
    end
end

"""
    remove_temporary_invalid_robots!(scene_tree)
    remove_temporary_invalid_robots!(scene_tree,transport_unit)

Remove all invalid robots (limited optionally to those associated with
`transport_unit::TransportUnitNode`) from scene_tree.
"""
# 첫 메서드(다중 디스패치): 특정 transport_unit 에 속한 임시 로봇만 제거.
function remove_temporary_invalid_robots!(scene_tree, transport_unit)
    for (id, _) in robot_team(transport_unit)                       # 팀의 (id, 변환) 쌍 순회. _ = 변환값은 안 쓰므로 버림
        if !valid_id(id)                                          # id 가 "유효하지 않은(임시)" 것이면
            rem_node!(scene_tree, id)                             # 그 노드를 씬트리에서 제거
        end
    end
    return scene_tree
end
# 두 번째 메서드: 인자가 scene_tree 하나일 때 → 씬트리 전체에서 임시 로봇을 모두 제거.
function remove_temporary_invalid_robots!(scene_tree)
    # filter(조건함수, 컬렉션) : 조건이 참인 것만 남김(파이썬 filter). id -> ... 는 익명함수(파이썬 lambda)
    # isa(id, BotID) : id 가 BotID 타입인지 검사(파이썬 isinstance). && = 논리곱 AND
    ids = filter(id -> isa(id, BotID) && !valid_id(id), get_vtx_ids(scene_tree))  # 로봇이면서 무효(임시)인 id 들만 추림
    for id in ids                                                # 추린 id 들에 대해
        rem_node!(scene_tree, id)                                # 노드 제거
    end
    scene_tree
end

"""
    select_optimal_carrying_configuration(pts::AbstractVector)

Return an AffineMap representing a rotation that minimizes the z-dimension of
the transformed points.
"""
# 여러 점(pts)을 가장 납작하게(z 방향 두께 최소) 눕히는 회전을 SVD 로 찾는 함수.
# 같은 이름의 함수가 아래에도 또 정의됨 → "다중 디스패치": 인자 타입에 따라 다른 메서드가 호출됨.
function select_optimal_carrying_configuration(pts::AbstractVector)
    # convert.(Vector, pts) : 각 점을 Vector 로 변환(.은 원소별). hcat(...; ...)=열로 가로 결합해 행렬 mat 생성
    mat = hcat(convert.(Vector, pts)...)                            # 점들을 열벡터로 쌓은 행렬(... 로 펼쳐 hcat 인자로)
    # svd : 특이값분해. U,S,V 를 반환하지만 여기선 첫 값 U 만 받음(U, = ... 의 쉼표는 "나머지는 버림")
    U, = svd(mat)                                                  # 좌특이벡터 행렬 U(주축 방향들). 회전행렬로 사용
    if !isapprox(det(U), 1.0)                                      # det(U)≈1 이 아니면(=반사가 섞여 순수 회전이 아님)
        @warn "det(U) = $(det(U)). Flipping last column"          # 경고 출력
        U = diagm([1.0, 1.0, -1.0]) * U                           # diagm=대각행렬 생성. 마지막 축을 뒤집어 반사를 회전으로 바꿈
        @assert isapprox(det(U), 1.0)                             # 이제 det≈1(순수 회전)인지 확인
    end
    # LinearMap(U) : 회전행렬 U 를 좌표변환으로 감쌈. ∘ = 함수 합성(파이썬엔 없음; f∘g 는 "f 다음 g 적용")
    return CoordinateTransformations.LinearMap(U) ∘ identity_linear_map()  # 회전 변환을 반환
end
# 두 번째 메서드: 인자가 ObjectNode 타입일 때 호출됨(다중 디스패치). 점 좌표를 꺼내 위 메서드로 위임
function select_optimal_carrying_configuration(n::ObjectNode)
    select_optimal_carrying_configuration(coordinates(get_base_geom(n)))  # 노드의 기본 형상 좌표로 최적 회전 계산
end

"""
    find_step_numbers(start_node, part_ids, sched, scene_tree; max_depth=100)

Finds the number of steps down the tree the corresponding lift nodes are from the
start node. Returns a vector of Int where the i-th element is the steps from the start node
that the life node corresponding to the i-th part_id is.
"""
# start_node 에서 트리를 거슬러 올라가며, 각 part_id 의 LiftIntoPlace 노드까지 "몇 단계" 떨어졌는지 세는 함수.
# `;` 뒤 max_depth 는 키워드 인자(탐색 최대 깊이, 기본 1000).
function find_step_numbers(start_node, part_ids, sched, scene_tree; max_depth=1000)
    steps_found = Vector{Int}(undef, length(part_ids))               # 결과 저장용 정수 벡터(undef=값 미초기화로 길이만 확보)
    found = []                                                       # 이미 찾은 part 의 인덱스 목록(빈 배열)
    lift_nodes_to_find = []                                          # 찾아야 할 lift 노드 id 목록(빈 배열)
    for part_id in part_ids                                          # 각 부품 id 에 대해
        lift_node = get_node(sched, LiftIntoPlace(get_node(scene_tree, part_id)))  # 그 부품의 LiftIntoPlace 노드를 스케줄에서 가져옴
        push!(lift_nodes_to_find, lift_node.id)                      # push!=배열 끝에 추가(파이썬 list.append). 찾을 id 목록에 등록
    end
    ns = [start_node]                                               # 현재 탐색 중인 노드 목록(시작 노드 하나로 시작)
    cnt = 0                                                         # 거슬러 올라간 단계(깊이) 카운터
    continue_looking = true                                         # 탐색 계속 여부 플래그
    while continue_looking                                          # 멈춤 조건이 될 때까지 반복(BFS 형태)
        cnt += 1                                                    # 한 단계 더 거슬러 올라감
        new_ns = []                                                 # 다음 단계에 탐색할 노드들을 모을 배열
        for n in ns                                                # 현재 단계의 각 노드에 대해
            ons = inneighbors(sched, n)                            # n 으로 들어오는(=한 단계 위) 이웃 노드들의 인덱스
            for ni in sched.nodes[ons]                            # 그 이웃 노드 객체들을 순회
                # enumerate : (인덱스, 값) 쌍으로 반복(파이썬 enumerate). 단 줄리아 인덱스는 1부터 시작
                for (ii, lift_node_id) in enumerate(lift_nodes_to_find)  # 찾을 lift id 들을 인덱스와 함께 순회
                    if ii in found                                # 이미 찾은 것이면
                        continue                                  # 건너뜀(다음 반복으로)
                    end
                    if ni.id == lift_node_id                      # 현재 노드가 찾던 lift 노드면
                        push!(found, ii)                          # 찾음 표시
                        steps_found[ii] = cnt                     # 그 부품까지의 단계 수를 기록
                    end
                end
                if length(found) == length(lift_nodes_to_find)   # 모두 다 찾았으면
                    continue_looking = false                     # 탐색 종료 플래그
                    break                                        # 안쪽 루프 즉시 탈출
                end
            end
            append!(new_ns, sched.nodes[ons])                    # append!=배열에 여러 원소 한꺼번에 이어붙임(다음 단계 후보로)
        end
        ns = unique(new_ns)                                      # 중복 제거(unique=파이썬 set 으로 묶어 유일화). 다음 단계 노드 목록
        if length(ns) < 1 || cnt > max_depth                    # 더 올라갈 노드가 없거나 깊이 초과면(|| = 논리합 OR)
            continue_looking = false                            # 탐색 종료
            idxs = setdiff(1:length(lift_nodes_to_find), found) # setdiff=차집합. 아직 못 찾은 인덱스들
            error("Could not find node $(lift_nodes_to_find[idxs]) in $(start_node.id). Searched to depth $(cnt)")
        end
    end
    return steps_found
end
