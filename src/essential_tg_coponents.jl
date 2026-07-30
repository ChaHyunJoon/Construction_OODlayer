# ============================================================================
#  이 파일 = TaskGraphs 라이브러리의 핵심 구성요소들을 이 프로젝트 안으로 "인라인(직접 포함)"한 모음.
#  담고 있는 것: PathSpec(경로 명세), ScheduleNode / OperatingSchedule(작업 스케줄 그래프),
#    비용모델(makespan / 에너지), 작업배정 MILP(AssignmentMILP·SparseAdjacencyMILP·GreedyAssignment),
#    그리고 계획 캐시(PlanningCache)·경로노드(PathNode)·충돌(Conflict) 등.
#  프로젝트에서의 역할: "어느 로봇이 어느 작업을 언제 하는가"(스케줄+배정)를 표현하고 최적화하는 밑바탕.
#  Julia 문법 참고(처음 읽는 사람용):
#   · 다중 디스패치: 같은 함수 이름을 인자 "타입"별로 여러 번 정의 → 타입마다 다른 동작(파이썬엔 없는 개념).
#   · `::Type` / `x::PathSpec` : 인자의 타입을 명시해 어떤 메서드를 쓸지 고름.
#   · `:symbol` (콜론) : "이름 그 자체"를 값으로 다루는 심볼. 아래에서 함수들을 자동 생성하는 데 쓰임.
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
#   · @eval / @macro (@with_kw, @variable, @constraint 등) : 메타프로그래밍 — "코드를 만들어내는 코드".
#   · `[f(x) for x in xs]` / `Dict(k=>v for ...)` : 컴프리헨션(파이썬과 동일).
# ============================================================================
# Used components in TaskGraphs   # TaskGraphs(작업그래프 라이브러리)에서 쓰이는 구성요소들

# const 는 "상수"(값이 바뀌지 않는 이름)를 정의. 파이썬의 대문자 전역변수 관례와 비슷하지만 강제됨.
# `:get_t0` 처럼 콜론으로 시작하는 것은 "Symbol"(심볼) — "함수 이름 그 자체"를 값으로 다루는 것.
#   파이썬에 정확한 짝은 없지만, 문자열 "get_t0" 와 비슷하되 "식별자(이름)"로서 다룬다고 보면 됨.
#   아래에서 이 이름 목록을 돌며 같은 모양의 함수들을 자동 생성(@eval)하는 데 쓰임.
# 이 목록 = "PathSpec(경로 명세)에서 값을 읽어오는(accessor) 함수들"의 이름 모음.
const path_spec_accessor_interface = [
    :get_t0,            # 시작 시각(t0)을 읽는 함수 이름
    :get_tF,            # 종료 시각(tF)을 읽는 함수 이름
    :get_slack,         # 여유시간(slack)을 읽는 함수 이름
    :get_local_slack,   # 지역 여유시간을 읽는 함수 이름
    :get_min_duration,  # 최소 소요시간을 읽는 함수 이름
    :get_duration,      # (실제) 소요시간을 읽는 함수 이름
]
# 이 목록 = "PathSpec 의 값을 바꾸는(mutator) 함수들"의 이름 모음. 끝의 `!` 는 "값을 직접 수정함" 표시.
const path_spec_mutator_interface = [
    :set_min_duration!, # 최소 소요시간을 설정하는 함수 이름
    :set_t0!,           # 시작 시각을 설정하는 함수 이름
    :set_slack!,        # 여유시간을 설정하는 함수 이름
    :set_local_slack!,  # 지역 여유시간을 설정하는 함수 이름
    :set_tF!,           # 종료 시각을 설정하는 함수 이름
]

# `...` (스플랫) : 목록을 "풀어서 펼침". 파이썬의 *list 와 동일.
#   즉 path_spec_accessor_interface... 는 그 목록의 원소들을 여기에 그대로 펼쳐 넣음.
# 이 목록 = "스케줄 노드"에서 읽어오는 함수 이름들 = (위 accessor 목록) + get_path_spec.
const schedule_node_accessor_interface = [
    path_spec_accessor_interface...,  # 위에서 정의한 읽기 함수 이름들을 모두 펼쳐 넣음
    :get_path_spec                    # 추가로 PathSpec 자체를 가져오는 함수 이름
]
# 이 목록 = "스케줄 노드"의 값을 바꾸는 함수 이름들 = (위 mutator 목록) + set_path_spec!.
const schedule_node_mutator_interface = [
    path_spec_mutator_interface...,   # 위에서 정의한 쓰기 함수 이름들을 모두 펼쳐 넣음
    :set_path_spec!                   # 추가로 PathSpec 자체를 설정하는 함수 이름
]

"""
    ProblemSpec{G}

Encodes the the relaxed PC-TAPF problem that ignores collision-avoidance
constraints.

Elements:
- D::T - a distance matrix (or environment) that implements get_distance(D,x1,x2,args...)
- cost_function::F - the optimization objective (default is SumOfMakeSpans)
- Δt_collect::Dict{ObjectID,Int} # duration of COLLECT operations
- Δt_deposit::Dict{ObjectID,Int} # duration of DEPOSIT operations
"""
# @with_kw struct ... {T,F} : 키워드 생성자 자동 생성 + 타입 매개변수 2개(T, F)를 가진 구조체.
#   {T,F} 는 "아직 안 정해진 타입 빈칸 두 개"(파이썬 Generic[T, F] 느낌). D 의 타입이 T, cost_function 의 타입이 F.
#   각 필드의 `= ...` 는 기본값. @with_kw 덕분에 ProblemSpec(D=..., cost_function=...) 처럼 키워드로 생성 가능.
# 이 구조체 = "충돌회피를 무시한 단순화된 작업배정 문제"의 명세(거리행렬 + 비용함수 + 작업 소요시간들).
@with_kw struct ProblemSpec{T,F}
    D::T = zeros(0, 0) # environment or distance matrix   # 거리행렬(또는 환경). 기본값은 0×0 빈 행렬
    cost_function::F = SumOfMakeSpans()   # 최적화 목적함수. 기본값은 "각 프로젝트 완료시간의 합"
    # Dict{ObjectID,Int} : 키가 ObjectID, 값이 Int 인 딕셔너리 타입(파이썬 dict[ObjectID, int]).
    Δt_collect::Dict{ObjectID,Int} = Dict{ObjectID,Int}() # duration of COLLECT operations  # 부품별 COLLECT(집기) 소요시간
    Δt_deposit::Dict{ObjectID,Int} = Dict{ObjectID,Int}() # duration of DELIVER operations  # 부품별 DEPOSIT(내려놓기) 소요시간
end

"""
    PathSpec

Encodes information about the path that must be planned for a particular
schedule node.

Fields:
* `node_type::Symbol = :EMPTY`
* `start_vtx::Int = -1`
* `final_vtx::Int = -1`
* `min_duration::Int = 0`
* `agent_id::Int = -1`
* `object_id::Int = -1`
* `plan_path::Bool = true` - flag indicating whether a path must be planned.
    For example, `Operation` nodes do not require any path planning.
* `tight::Bool = false` - if true, the path may not terminate prior to the
    beginning of successors. If `tight == true`, local slack == 0. For example,
    `GO` must not end before `COLLECT` can begin, because this would produce
    empty time between planning phases.
* `static::Bool = false` - if true, the robot must remain in place for this
    planning phase (e.g., COLLECT, DEPOSIT).
* `free::Bool = false` - if true, and if the node is a terminal node, the
    planning must go on until all non-free nodes are completed.
* `fixed::Bool = false` - if true, do not plan path because it is already fixed.
    Instead, retrieve the portion of the path directly from the pre-existing
    solution.
"""
# `mutable struct` : "값을 나중에 바꿀 수 있는" 구조체. (그냥 struct 는 만든 뒤 필드값 변경 불가 — 불변)
#   파이썬 class 는 기본이 가변이지만, 줄리아 struct 는 기본 불변이라 바꾸려면 mutable 을 붙임.
# 이 구조체 = "특정 스케줄 노드에 대해 계획해야 할 경로(path)의 정보"(시간 정보 + 계획 지시 플래그들).
@with_kw mutable struct PathSpec
    # temporal              # 시간 관련 필드들
    t0::Float64 = 0                       # 시작 시각(부동소수). 기본 0
    min_duration::Float64 = 0             # 최소 소요시간. 기본 0
    tF::Float64 = t0 + min_duration       # 종료 시각. 기본값으로 위의 t0 + min_duration 사용(필드끼리 참조 가능)
    # Vector{Float64} : Float64(실수) 들의 1차원 배열(파이썬 list[float]). Float64[] 는 빈 배열 리터럴.
    slack::Vector{Float64} = Float64[]       # 여유시간 벡터(프로젝트 머리마다 하나). 기본 빈 배열
    local_slack::Vector{Float64} = Float64[] # 지역(인접 노드 간) 여유시간 벡터. 기본 빈 배열
    # instructions          # 경로 계획 방법을 지시하는 불리언(참/거짓) 플래그들
    plan_path::Bool = true   # 이 노드에 대해 경로를 계획해야 하는가(Operation 노드는 false)
    tight::Bool = false      # true 면 이 노드 경로는 후속 노드 시작 전에 끝나면 안 됨(지역 여유=0)
    static::Bool = false     # true 면 로봇이 이 단계 동안 제자리에 머물러야 함(COLLECT, DEPOSIT 등)
    free::Bool = false       # true 면 종단 노드일 때 다른 노드가 다 끝날 때까지 계획을 계속함
    fixed::Bool = false      # true 면 경로가 이미 고정 — 새로 계획하지 않고 기존 해에서 그대로 가져옴
end
# `f(x::PathSpec) = ...` : 한 줄짜리 함수 정의. `x::PathSpec` 은 "인자 x 의 타입이 PathSpec 일 때 이 메서드를 씀"(다중 디스패치).
get_t0(spec::PathSpec) = spec.t0            # PathSpec 의 t0 필드를 그대로 돌려줌(getter). 파이썬의 spec.t0 접근과 동일
# `begin ... end` : 여러 줄을 하나의 식(블록)으로 묶음. 한 줄 함수 본문을 여러 줄로 쓰고 싶을 때 사용.
set_t0!(spec::PathSpec, val) = begin       # t0 값을 val 로 설정(setter). `!` = 인자(spec)를 직접 수정함
    spec.t0 = val                           # spec 의 t0 필드에 val 대입
end
get_tF(spec::PathSpec) = spec.tF            # tF(종료 시각) 읽기
set_tF!(spec::PathSpec, val) = begin       # tF 설정
    spec.tF = val                           # tF 필드에 val 대입
end
get_min_duration(spec::PathSpec) = spec.min_duration   # 최소 소요시간 읽기
set_min_duration!(spec::PathSpec, val) = begin         # 최소 소요시간 설정
    spec.min_duration = val                 # min_duration 필드에 val 대입
end
get_duration(spec::PathSpec) = get_tF(spec) - get_t0(spec)  # 실제 소요시간 = 종료 - 시작 (계산해서 돌려줌)
get_slack(spec::PathSpec) = spec.slack      # 여유시간 벡터 읽기
set_slack!(spec::PathSpec, val) = begin    # 여유시간 벡터 설정
    spec.slack = val                        # slack 필드에 val 대입
end
get_local_slack(spec::PathSpec) = spec.local_slack   # 지역 여유시간 벡터 읽기
set_local_slack!(spec::PathSpec, val) = begin        # 지역 여유시간 벡터 설정
    spec.local_slack = val                  # local_slack 필드에 val 대입
end
# Base.summary : 줄리아 표준 라이브러리(Base)의 summary 함수에 "PathSpec 일 때의 동작"을 추가 정의(메서드 확장).
#   string(...) 은 인자들을 이어붙여 한 문자열로 만듦(파이썬 f-string/str.join 느낌). 객체 요약 문자열을 만든다.
Base.summary(s::PathSpec) = string("t0=", s.t0, ", tF=", s.tF, ", fixed=", s.fixed)  # "t0=.., tF=.., fixed=.." 요약문자열

"""
    ScheduleNode{I<:AbstractID,V<:AbstractPlanningPredicate}

The node type of the `OperatingSchedule` graph.
"""
# {I<:AbstractID,V} : 타입 매개변수 2개. I 는 "AbstractID 의 하위 타입"으로 제한(<:), V 는 아무 타입이나 가능.
#   파이썬 typing 으로는 I 가 TypeVar('I', bound=AbstractID), V 가 자유로운 TypeVar 인 셈.
# 이 구조체 = OperatingSchedule 그래프의 "노드 한 개"(식별자 id + 실제 내용 node + 경로명세 spec 묶음).
mutable struct ScheduleNode{I<:AbstractID,V}
    id::I            # 이 노드의 식별자(타입 I)
    node::V          # 노드가 담는 실제 내용/술어(타입 V)
    spec::PathSpec   # 이 노드의 경로 명세(시간·계획 정보)
end
# 인자 2개짜리 생성자: spec 을 안 주면 기본 PathSpec() 으로 채워 3-인자 생성자를 호출(파이썬의 기본인자/오버로드 느낌).
ScheduleNode(id, node) = ScheduleNode(id, node, PathSpec())

get_path_spec(node::ScheduleNode) = node.spec   # 노드의 PathSpec 을 읽음
# Base.copy : 표준 copy 함수에 ScheduleNode 용 동작 추가. node 는 copy(얕은복사), spec 은 deepcopy(깊은복사)로 새 노드 생성.
Base.copy(n::ScheduleNode) = ScheduleNode(n.id, copy(n.node), deepcopy(n.spec))

# `function ... end` : 여러 줄 함수 정의 방식(한 줄 `=` 축약형의 풀어쓴 형태).
function set_path_spec!(node::ScheduleNode, spec)  # 노드의 spec 을 통째로 교체(`!`=수정)
    node.spec = spec                                # spec 필드에 새 값 대입
end

# `for op in 목록 ... end` : 컴파일 시점에 목록의 각 이름(op)에 대해 코드를 반복 생성하는 패턴.
# @eval : "코드를 만들어서 실행"하는 매크로. $op 는 현재 op 이름을 그 자리에 끼워넣음(문자열 보간 비슷).
# 결과: get_t0, get_tF ... 등을 ScheduleNode 에 대해 "내부 spec 의 같은 함수를 호출"하도록 자동 정의(보일러플레이트 제거).
for op in path_spec_accessor_interface
    @eval $op(node::ScheduleNode) = $op(get_path_spec(node))  # 예: get_t0(node) = get_t0(get_path_spec(node))
end
# 위와 같지만 값을 바꾸는(mutator) 함수들을 자동 정의(인자 val 추가).
for op in path_spec_mutator_interface
    @eval $op(node::ScheduleNode, val) = $op(get_path_spec(node), val)  # 예: set_t0!(node, val) = set_t0!(spec, val)
end
# for op in predicate_accessor_interface      # (주석 처리됨 — 사용 안 함)
#     @eval $op(node::ScheduleNode) = $op(node.node)
# end
# `:(matches_template)` : 식(expression)을 값으로 감싼 것. 여기선 함수 이름 하나만 든 목록을 도는 데 사용.
# Type{T} : "타입 그 자체"를 인자로 받음(값이 아니라 '클래스'를 인자로 받는 느낌). where {T} 는 T 가 자유 타입임을 선언.
# matches_template(template, node) → 노드 내부 node.node 에 대해 검사하도록 위임.
for op in [:(matches_template)]
    @eval $op(template::Type{T}, node::ScheduleNode) where {T} = $op(template, node.node)  # 템플릿 매칭을 내부 node 로 위임
end
# ScheduleNode 의 요약 문자열 = "<노드내용> [<spec요약>]" 형태로 만듦.
Base.summary(n::ScheduleNode) = string(string(n.node), " [", summary(n.spec), "]")



"""
    OperatingSchedule

Encodes discrete events/activities that need to take place, and the precedence
constraints between them. Each `ScheduleNode` has a corresponding vertex index
and an `AbstractID`. An edge from node1 to node2 indicates a precedence
constraint between them.
"""
# `<: AbstractCustomNDiGraph{ScheduleNode,AbstractID}` : 이 구조체는 "커스텀 방향그래프"의 하위 타입.
#   {ScheduleNode,AbstractID} = 노드 타입은 ScheduleNode, 노드ID 타입은 AbstractID 라는 뜻(그래프 부모에 채워넣는 빈칸).
# 이 구조체 = 전체 "작업 스케줄"(이산 작업들과 그 선후관계). 그래프 + 노드목록 + 인덱스 매핑들을 한 묶음으로 가짐.
@with_kw struct OperatingSchedule <: AbstractCustomNDiGraph{ScheduleNode,AbstractID}
    graph::DiGraph = DiGraph()   # 실제 방향그래프(노드 간 선후관계 엣지). 기본 빈 그래프
    nodes::Vector{ScheduleNode} = Vector{ScheduleNode}()   # 모든 ScheduleNode 들의 배열(정점 번호 순)
    # vtx_map: ID → 정점번호 매핑. vtx_ids: 정점번호 → ID 매핑(서로 역방향). 그래프 정점과 ID를 오가게 해줌.
    vtx_map::Dict{AbstractID,Int} = Dict{AbstractID,Int}()  # ID 로 정점 번호 찾기
    vtx_ids::Vector{AbstractID} = Vector{AbstractID}() # maps vertex uid to actual graph node  # 정점 번호로 ID 찾기
    terminal_vtxs::Vector{Int} = Vector{Int}() # list of "project heads"  # 종단 정점(각 프로젝트의 최종 노드) 목록
    weights::Dict{Int,Float64} = Dict{Int,Float64}() # weights corresponding to project heads  # 프로젝트 머리별 가중치
end
# where {P<:OperatingSchedule} : "P 는 OperatingSchedule 의 하위 타입"이라는 제약을 둔 제네릭 함수.
get_terminal_vtxs(sched::P) where {P<:OperatingSchedule} = sched.terminal_vtxs   # 종단 정점 목록 읽기
get_root_node_weights(sched::P) where {P<:OperatingSchedule} = sched.weights      # 루트 노드 가중치 딕셔너리 읽기

# 스케줄 전체를 복사하는 함수. 모든 내부 필드를 deepcopy(깊은복사)하여 원본과 완전히 분리된 새 스케줄 생성.
function Base.copy(sched::OperatingSchedule)
    OperatingSchedule(
        graph=deepcopy(get_graph(sched)),   # 그래프 깊은복사
        nodes=map(copy, get_nodes(sched)),  # 각 노드에 copy 적용(map = 파이썬 map). 노드 배열 복사
        vtx_map=deepcopy(sched.vtx_map),    # ID→정점 매핑 깊은복사
        vtx_ids=deepcopy(sched.vtx_ids),    # 정점→ID 매핑 깊은복사
        terminal_vtxs=deepcopy(sched.terminal_vtxs),  # 종단정점 목록 깊은복사
        weights=deepcopy(sched.weights),    # 가중치 깊은복사
    )
end

get_vtx(sched::OperatingSchedule, node::ScheduleNode) = get_vtx(sched, node.id)  # 노드 → 그 노드의 정점 번호(노드의 id로 위임)
get_node_from_id(sched::OperatingSchedule, id) = get_node(sched, id).node        # ID 로 ScheduleNode 를 찾고 그 안의 .node 반환
get_node_from_vtx(sched::OperatingSchedule, v) = get_node(sched, v).node         # 정점 번호로 ScheduleNode 를 찾고 .node 반환


# 스케줄 단위의 읽기 함수들 자동 생성: (1) 정점 v 하나 / (2) 인자 없으면 모든 정점에 대해 map 으로 한꺼번에.
for op in schedule_node_accessor_interface
    @eval $op(sched::OperatingSchedule, v) = $op(get_node(sched, v))   # 예: get_t0(sched, v) = get_t0(노드)
    # `v -> ...` : 익명함수(람다). 파이썬 lambda v: ... 와 동일. 모든 정점에 적용해 결과 배열을 만듦.
    @eval $op(sched::OperatingSchedule) = map(v -> $op(get_node(sched, v)), Graphs.vertices(sched))  # 모든 정점 값 배열
end
# 스케줄 단위의 쓰기 함수들 자동 생성: (1) 특정 정점 v 에 val 설정 / (2) 정점 지정 없으면 전체 정점에 val 설정.
for op in schedule_node_mutator_interface
    @eval $op(sched::OperatingSchedule, v, val) = $op(get_node(sched, v), val)   # 특정 정점 v 노드에 값 설정
    @eval $op(sched::OperatingSchedule, val) = begin   # 정점 미지정 시: 모든 정점에 같은 값 설정
        for v in Graphs.vertices(sched)   # 모든 정점을 돌며
            $op(get_node(sched, v), val)  # 각 노드에 값 설정
        end
    end
end

# Defining default node parameters   # 노드별 기본 속성(특정 노드 타입에서 덮어쓰기 전의 기본값) 정의
# `f(p) = false` 처럼 타입 제약 없는 인자 p : "어떤 타입이든" 받는 가장 일반적인(fallback) 메서드. 다중 디스패치의 기본값 역할.
is_tight(p) = false      # 기본: "tight 아님"(후속과 딱 맞물릴 필요 없음). 특정 노드만 아래 주석처럼 true 로 덮어씀
# is_tight(::BOT_GO) = true   # (예시 주석) BOT_GO 노드면 tight=true 로 만드는 식
is_free(p) = false       # 기본: "free 아님"
# is_free(p::BOT_AT) = true   # (예시 주석) BOT_AT 노드는 free=true

# is_free(p::BOT_GO) = is_valid(get_destination_location_id(p))   # (예시 주석) 목적지가 유효하면 free

is_static(p) = false     # 기본: "정적(제자리) 아님"
# is_static(p::Union{BOT_COLLECT,BOT_DEPOSIT}) = true   # (예시) COLLECT 나 DEPOSIT 이면 static=true (Union=둘 중 하나)
# for op in [:is_free, :is_static, :is_tight]   # (주석) 팀 액션은 첫 하위 노드의 속성을 따르게 하는 코드
#     @eval $op(p::TEAM_ACTION) = $op(sub_nodes(p)[1])
# end
needs_path(p) = false    # 기본: "경로 계획 필요 없음"
# needs_path(p::Union{BOT_AT,AbstractRobotAction}) = true   # (예시) 로봇 위치/행동 노드는 경로 필요
# `args...` : 인자를 몇 개든 받아 하나로 묶음(파이썬 *args). 어떤 인자가 와도 0 을 돌려주는 기본 메서드.
duration_lower_bound(args...) = 0   # 기본: 소요시간 하한 = 0 (특정 노드 타입에서 아래 주석처럼 실제 계산으로 덮어씀)
# duration_lower_bound(op::Operation, spec) = duration(op)
# duration_lower_bound(p::BOT_COLLECT, spec) = get(spec.Δt_collect, get_object_id(p), 0)
# duration_lower_bound(p::BOT_DEPOSIT, spec) = get(spec.Δt_deposit, get_object_id(p), 0)
# function duration_lower_bound(p::Union{BOT_AT,AbstractRobotAction}, spec)
#     x1 = get_initial_location_id(p)
#     x2 = get_destination_location_id(p)
#     return get_distance(spec, x1, x2)
# end
# function duration_lower_bound(p::TEAM_ACTION, spec)
#     x1 = get_initial_location_id(p.instructions[1])
#     x2 = get_destination_location_id(p.instructions[1])
#     return get_distance(spec, x1, x2, team_configuration(p))
# end


"""
    replace_in_schedule!(schedule::OperatingSchedule,path_spec::T,pred,id::ID) where {T<:PathSpec,ID<:AbstractID}

Replace the `ScheduleNode` associated with `id` with the new node `pred`, and
the accompanying `PathSpec` `path_spec`.
"""
# 아래 4개는 같은 이름 replace_in_schedule! 의 "다른 인자 조합" 버전들(다중 디스패치 = 인자 모양에 따라 적절한 것이 골라짐).
# `id::AbstractID=node.id` : id 인자에 기본값 node.id 를 줌(안 넘기면 노드 자신의 id 사용).
replace_in_schedule!(sched::OperatingSchedule, node::ScheduleNode, id::AbstractID=node.id) = replace_node!(sched, node, id)  # 기존 노드를 새 ScheduleNode 로 교체
# where {P<:OperatingSchedule,T<:PathSpec,ID<:AbstractID} : 세 타입 매개변수에 각각 상한 제약을 건 제네릭.
function replace_in_schedule!(sched::P, path_spec::T, pred, id::ID) where {P<:OperatingSchedule,T<:PathSpec,ID<:AbstractID}
    replace_in_schedule!(sched, ScheduleNode(id, pred, path_spec))  # id+내용(pred)+경로명세로 새 노드를 만들어 위 버전 호출
end
# path_spec 없이 spec(문제명세)만 줄 때: spec 으로부터 path_spec 을 생성한 뒤 교체.
function replace_in_schedule!(sched::P, spec, pred, id::ID) where {P<:OperatingSchedule,ID<:AbstractID}
    replace_in_schedule!(sched, generate_path_spec(sched, spec, pred), pred, id)  # path_spec 을 만들어 위 버전으로 위임
end
# spec 도 없이 내용(pred)과 id 만 줄 때: 기본 ProblemSpec() 을 채워 위 버전 호출.
function replace_in_schedule!(sched::P, pred, id::ID) where {P<:OperatingSchedule,ID<:AbstractID}
    replace_in_schedule!(sched, ProblemSpec(), pred, id)  # 기본 문제명세로 위임
end

add_node!(sched::OperatingSchedule, node::ScheduleNode) = add_node!(sched, node, node.id)  # 노드를 스케줄에 추가(노드 자신의 id 사용)


# 스케줄이 유효한지(사이클 없음, 엣지/차수 제약 만족, 로봇ID 일관성) 검사. 문제 있으면 false 반환.
function validate(sched::OperatingSchedule)
    # try ... catch e ... : 파이썬 try/except 와 동일. 본문에서 예외가 나면 catch 블록으로 감.
    try
        # @assert 조건 "메시지" : 조건이 거짓이면 메시지와 함께 AssertionError 발생(파이썬 assert 와 동일).
        @assert !is_cyclic(sched) "is_cyclic(G)"   # 그래프에 사이클(순환)이 없어야 함. !는 부정(not)
        for e in edges(sched)   # 모든 엣지를 돌며
            node1 = get_node_from_id(sched, get_vtx_id(sched, e.src))  # 엣지 출발(src) 정점의 노드
            node2 = get_node_from_id(sched, get_vtx_id(sched, e.dst))  # 엣지 도착(dst) 정점의 노드
            @assert(validate_edge(node1, node2), string(" INVALID EDGE: ", string(node1), " --> ", string(node2)))  # 이 엣지가 허용되는 연결인지 검사
        end
        for v in Graphs.vertices(sched)   # 모든 정점을 돌며
            id = get_vtx_id(sched, v)              # 정점 v 의 ID
            node = get_node_from_id(sched, id)     # 그 ID 의 노드
            # outdegree(나가는 엣지 수)가 "필요한 후속 수의 합" 이상인지 검사. values(...) 는 딕셔너리 값들, [0, ...] 로 빈 경우 합=0 보장.
            @assert(outdegree(sched, v) >= sum([0, values(required_successors(node))...]), string("outdegree = ", outdegree(sched, v), " for node = ", string(node)))  # 나가는 차수 충분?
            @assert(indegree(sched, v) >= sum([0, values(required_predecessors(node))...]), string("indegree = ", indegree(sched, v), " for node = ", string(node)))      # 들어오는 차수 충분?
            if matches_node_type(node, AbstractSingleRobotAction)   # 이 노드가 "단일 로봇 행동" 타입이면
                for v2 in outneighbors(sched, v)   # 후속(나가는 이웃) 정점들을 돌며
                    node2 = get_node_from_vtx(sched, v2)   # 후속 노드
                    if matches_node_type(node2, AbstractSingleRobotAction)   # 후속도 단일 로봇 행동이면
                        # intersect = 교집합. 두 노드가 공유 자원이 없을 때(=같은 station job-shop 제약이 아닐 때)는 같은 로봇이어야 함
                        if length(intersect(resources_reserved(node), resources_reserved(node2))) == 0 # job shop constraint
                            @assert(get_robot_id(node) == get_robot_id(node2), string("robot IDs do not match: ", string(node), " => ", string(node2)))  # 로봇 ID 일치 확인
                        end
                    end
                end
            end
        end
    catch e   # 위에서 예외 e 가 발생하면
        # typeof(e) <: AssertionError : e 의 타입이 AssertionError 의 하위 타입인지(즉 assert 실패인지) 확인
        if typeof(e) <: AssertionError
            bt = catch_backtrace()   # 예외 발생 위치 추적정보(스택 백트레이스) 가져오기
            @info "Schedule is invalid"   # @info : 정보 로그 출력 매크로
            log_schedule_edges(sched)     # 스케줄 엣지들을 로그로 남김(디버깅용)
            showerror(stdout, e, bt)      # 표준출력에 에러와 백트레이스 표시
            print(e.msg)                  # 에러 메시지 출력
        else
            rethrow(e)   # assert 실패가 아닌 예상 못 한 예외면 그대로 다시 던짐
        end
        return false   # 유효성 검사 실패
    end
    return true   # 모든 검사 통과 → 유효
end

"""
    update_schedule_times!(sched::OperatingSchedule)

Compute start and end times for all nodes based on the end times of their
inneighbors and their own durations.
"""
# 모든 노드의 시작/종료 시각을 계산해 갱신. 위상정렬 순서로 돌며 선행 노드들의 종료시각에 맞춰 시작시각을 정함.
function update_schedule_times!(sched::OperatingSchedule)
    G = get_graph(sched)   # 내부 그래프 꺼내기
    # topological_sort_by_dfs : 위상정렬(선행이 항상 앞에 오도록 정렬한 정점 순서)
    for v in topological_sort_by_dfs(G)
        t0 = get_t0(sched, v)   # 현재 정점의 시작시각(초기값)
        for v2 in inneighbors(G, v)   # 선행(들어오는 이웃) 정점들을 돌며
            t0 = max(t0, get_tF(sched, v2))   # 선행이 모두 끝난 뒤 시작해야 하므로 가장 늦은 선행 종료시각으로 t0 갱신
        end
        set_t0!(sched, v, t0)   # 계산된 시작시각 저장
        set_tF!(sched, v, max(get_tF(sched, v), t0 + get_min_duration(sched, v)))   # 종료시각 = 시작 + 최소소요시간(기존 값과 비교해 더 큰 쪽)
    end
    return sched   # 갱신된 스케줄 반환
end

# 각 노드의 "여유시간(slack)"을 계산해 갱신. 위상정렬을 거꾸로(뒤에서 앞으로) 돌며 후속과의 시간차를 전파.
function update_slack!(sched::OperatingSchedule)
    G = get_graph(sched)
    n_roots = max(length(sched.terminal_vtxs), 1)   # 프로젝트 머리(종단정점) 개수(없으면 최소 1)
    # 각 정점마다 길이 n_roots 인 무한대 벡터로 slack 초기화. ones(n) 은 1로 채운 길이 n 배열, Inf * → 무한대 배열.
    slack = map(i -> Inf * ones(n_roots), Graphs.vertices(G))         # 전역 여유시간(머리별)
    local_slack = map(i -> Inf * ones(n_roots), Graphs.vertices(G))  # 지역(인접 노드 간) 여유시간
    # enumerate : (인덱스 i, 값 v) 쌍으로 순회(파이썬 enumerate 와 동일).
    for (i, v) in enumerate(sched.terminal_vtxs)
        slack[v][i] = 0 # only slack for corresponding head is set to 0   # 각 종단정점은 자기 머리에 대한 여유=0
    end
    for v in reverse(topological_sort_by_dfs(G))   # 위상정렬을 뒤집어(종단→시작 방향으로) 순회
        for v2 in outneighbors(G, v)   # 후속(나가는 이웃)들을 돌며
            # `.min`/`.+`/`.-` 의 점(.) 은 "원소별(broadcast) 연산". 배열의 각 원소에 함수를 적용(파이썬 numpy 의 벡터 연산처럼).
            local_slack[v] = min.(local_slack[v], (get_t0(sched, v2) - get_tF(sched, v)))   # 후속 시작 - 내 종료 의 최소값(원소별)
            slack[v] = min.(slack[v], slack[v2] .+ (get_t0(sched, v2) - get_tF(sched, v)))   # 후속의 slack + 시간차 를 전파(원소별 최소)
        end
    end
    for v in Graphs.vertices(sched)   # 계산 결과를 각 노드에 저장
        set_slack!(sched, v, slack[v])             # 전역 여유시간 저장
        set_local_slack!(sched, v, local_slack[v]) # 지역 여유시간 저장
    end
    return sched
end

# 스케줄 처리 = 시각 갱신 후 여유시간 갱신을 차례로 수행하는 묶음 함수.
function process_schedule!(sched)
    update_schedule_times!(sched)   # 1) 시작/종료 시각 계산
    update_slack!(sched)            # 2) 여유시간 계산
end

makespan(sched::OperatingSchedule) = maximum(get_tF(sched))   # 전체 완료시간(makespan) = 모든 노드 종료시각 중 최대값


#################################################

# `abstract type ... end` : "추상 타입" — 직접 인스턴스를 만들 수 없고, 하위 타입들의 공통 부모 역할만 함.
#   파이썬의 추상 베이스 클래스(ABC)와 비슷. 다중 디스패치에서 "이런 부류"를 한꺼번에 가리키는 데 씀.
abstract type AbstractPlanningPredicate end   # 모든 계획 술어(스케줄 노드 내용)의 최상위 부모
# {R<:AbstractRobotType} : 로봇 타입 R 을 매개변수로 받는 추상 타입. <: ...Predicate 로 위 부모를 상속.
abstract type AbstractRobotAction{R<:AbstractRobotType} <: AbstractPlanningPredicate end       # 로봇 행동(부모)
abstract type AbstractSingleRobotAction{R<:AbstractRobotType} <: AbstractRobotAction{R} end    # 단일 로봇 행동
abstract type AbstractTeamRobotAction{R<:AbstractRobotType} <: AbstractRobotAction{R} end      # 팀(여러 로봇) 행동

Base.copy(p::AbstractPlanningPredicate) = deepcopy(p)   # 술어 복사 기본동작 = 깊은복사

# robot_type : 행동에서 "로봇 타입"을 꺼냄. 타입 매개변수 R 을 그대로 반환(첫 줄), 매칭 안 되면 Nothing(둘째 줄, fallback).
robot_type(a::AbstractRobotAction{R}) where {R} = R   # 로봇 행동이면 그 로봇 타입 R 반환
robot_type(a) = Nothing                                # 그 외에는 Nothing(로봇 타입 없음) 반환

#! Do we need this here? Better someplace else? Probably...   # (원작자 메모: 이 코드 위치가 적절한지 의문)
graph_key() = Symbol(DefaultRobotType)   # 인자 없을 때: 기본 로봇 타입 이름을 Symbol(심볼)로 만들어 그래프 키로 사용
function graph_key(a)
    if robot_type(a) == Nothing   # 행동 a 에 로봇 타입이 없으면
        return graph_key()        # 기본 키 사용
    else
        return Symbol(robot_type(a))   # 있으면 그 로봇 타입 이름을 키로
    end
end

# `조건 ? A : B` : 삼항연산자(파이썬의 A if 조건 else B). 여기선 로봇타입이 Nothing 이면 false, 아니면 true.
has_robot_id(a) = robot_type(a) == Nothing ? false : true   # 이 행동이 로봇 ID 를 가지는지 여부

"""
	robot_ids_match(node,node2)

Checks if robot_ids match between the nodes
"""
# 두 노드의 로봇 ID 가 서로 맞는지(또는 비교가 무의미한 경우) 검사. && 는 "그리고"(파이썬 and).
function robot_ids_match(node, node2)
    if has_robot_id(node) && has_robot_id(node2)   # 둘 다 로봇 ID 를 가질 때만 비교 의미 있음
        if get_id(get_robot_id(node)) != -1 && get_id(get_robot_id(node2)) != -1   # 둘 다 유효한 ID(-1=미정 아님)일 때
            status = (get_robot_id(node) == get_robot_id(node2)) ? true : false   # 같으면 true, 다르면 false
            return status   # 비교 결과 반환
        end
    end
    return true   # 비교 불가능/불필요한 경우는 "맞다(true)"로 간주
end

"""
	align_with_predecessor(node,succ)

Modifies a node to match the information encoded by its predecessor. This is
how e.g., robot ids are propagated through an existing operating schedule
after assignments (or re-assignments) have been made.
"""
align_with_predecessor(node, pred) = node   # 기본동작: 선행 노드 정보로 맞추되, 특별 처리 없으면 노드 그대로 반환

"""
	align_with_successor(node,succ)

Modifies a node to match the information encoded by its successor. This is
how e.g., robot ids are propagated through an existing operating schedule
after assignments (or re-assignments) have been made.
"""
align_with_successor(node, succ) = node   # 기본동작: 후속 노드 정보로 맞추되, 특별 처리 없으면 노드 그대로 반환


is_valid(id::A) where {A<:AbstractID} = valid_id(id) #get_id(id) != -1   # ID 가 유효한지(미정값 -1 이 아닌지) 검사
first_valid(a, b) = is_valid(a) ? a : b   # a 가 유효하면 a, 아니면 b 반환(둘 중 먼저 유효한 것)

# 위 2-인자 함수의 3-인자(그래프 추가) 버전: graph 인자는 무시하고 2-인자 버전으로 위임. 호출부 통일을 위함.
align_with_predecessor(graph, node, pred) = align_with_predecessor(node, pred)   # 그래프 인자 무시, 노드/선행만으로 위임
align_with_successor(graph, node, pred) = align_with_successor(node, pred)        # 그래프 인자 무시, 노드/후속만으로 위임

"""
    matches_node_type(::A,::Type{B}) where {A<:AbstractPlanningPredicate,B}

Returns true if {A <: B}
"""
# `::A` (이름 없이 타입만) : 값은 안 쓰고 "타입만 보고 디스패치"할 때. ::Type{B} 는 "타입 B 그 자체"를 인자로 받음.
# A <: B 는 "A 가 B 의 하위 타입이면 true" — 즉 노드 타입 A 가 주어진 부류 B 에 속하는지 검사.
matches_node_type(::A, ::Type{B}) where {A,B} = A <: B   # 노드(타입 A)가 타입 B 의 하위 타입인지 true/false


#####################

"""
    AbstractCostModel{T}
"""
abstract type AbstractCostModel{T} end   # 모든 비용 모델의 추상 부모. {T} 는 비용 값의 타입(예: Float64)
# where {T,M<:AbstractCostModel{T}} : 모델 M 이 AbstractCostModel{T} 의 하위일 때 그 T 를 꺼내 반환.
cost_type(model::M) where {T,M<:AbstractCostModel{T}} = T   # 비용 모델이 다루는 비용의 타입 T 를 돌려줌

"""
    aggregate_costs(model, costs::Vector{T}) where {T}

Defines how costs from multiple distinct paths are combined into a single cost
for the whole solution. For example, the aggregation function for a
`SumOfTravelTime` objective is the `sum` of individual cost.
"""
# `function 이름 end` (본문 없음) : 함수 이름만 선언해두는 것. 구체 메서드는 다른 곳에서 타입별로 추가됨(인터페이스 선언).
function aggregate_costs end   # 여러 경로 비용을 하나로 합치는 함수(메서드는 모델별로 따로 정의)

"""
    a special version of aggregate_costs for the meta_env
"""
aggregate_costs_meta(m::AbstractCostModel, args...) = aggregate_costs(m, args...)   # 메타환경용 변형 — 기본은 일반 버전에 위임

abstract type AggregationFunction end   # "비용 집계 함수"들의 추상 부모
# `struct 이름 end` : 필드 없는 빈 구조체(싱글톤 태그처럼 사용). 타입 자체가 "어떤 동작 종류"를 나타냄.
struct MaxCost <: AggregationFunction end   # "최대값으로 집계" 표시 타입
# `(f::MaxCost)(costs...) = ...` : "함수처럼 호출 가능한 객체"(callable). 파이썬의 __call__ 과 동일.
#   MaxCost() 인스턴스를 f 라 하면 f(a, b, c) 처럼 호출 가능. costs... 로 인자들을 받아 최대값 반환.
(f::MaxCost)(costs...) = maximum(costs...)   # MaxCost 객체를 호출하면 최대값 계산
struct SumCost <: AggregationFunction end   # "합으로 집계" 표시 타입
(f::SumCost)(costs...) = sum(costs...)        # SumCost 객체를 호출하면 합 계산

# """
#     FullCostModel{F,T,M<:AbstractCostModel{T}} <: AbstractCostModel{T}

# The `FullCostModel` defines all the behavior required for running CBS-based
# algorithms.

# Elements:
# - f::F must be callable, and defines how a vector of path costs (e.g., the
#     paths of a solution) should be combined into a single cost that reflects
#     the cost of the entire path group together
# - model::M<:AbstractCostModel{T} defines how the cost is computed during low
# level search (when individual paths are being compared against each other).
# """
# struct FullCostModel{F,T,M<:AbstractCostModel{T}} <: AbstractCostModel{T}
#     f::F        # the aggregation function
#     model::M    # the low level cost model
# end
# get_aggregation_function(m::FullCostModel)  = m.f
# aggregate_costs(m::FullCostModel, costs)    = m.f(costs)
# get_cost_model(m::FullCostModel)            = m.model
# for op in [:accumulate_cost,:get_initial_cost,:compute_path_cost,
#     :get_infeasible_cost,:add_heuristic_cost,:get_transition_cost]
#     @eval $op(model::FullCostModel,args...) = $op(model.model,args...)
# end
# for T in [:FullCostModel]
#     @eval begin
#         add_heuristic_cost(m::$T, h::H, env::E, args...) where {H<:AbstractCostModel,E<:AbstractLowLevelEnv} = add_heuristic_cost(m.model, h, env, args...)
#     end
# end

"""
    LowLevelCostModel{C}

The low level cost model defines the objective to be optimized by the
solver at the low level. An optimal low level solver will return a path if a
feasible path exists) of minimal cost under the objective specified by the
associated LowLevelCostModel.
The parameter `C` defines the `cost_type` of the objective. The following
functions must be implemented for a `LowLevelCostModel` to be used:
* `get_initial_cost(model::LowLevelCostModel,env)` - returns
the initial_cost for a path
* `get_transition_cost(model::LowLevelCostModel{C},path::Path,s::S,a::A,
    sp::S) where {S,A,C}` - defines the cost associated with taking action
    `a` from state `s` to arrive in state `sp` according to the objective
    defined by `model` given that `s` is the "tip" of `path`.
* `accumulate_cost(model::LowLevelCostModel{C}, current_cost::C,
    transition_cost::C)` - defines how cost accumulates as new `PathNode`s
    are added to a Path.
"""
abstract type LowLevelCostModel{T} <: AbstractCostModel{T} end   # 저수준(개별 경로 탐색) 비용 모델의 추상 부모

"""
    TravelTime <: LowLevelCostModel{Float64}

Cost model that assigns cost equal to the duration of a path.
"""
struct TravelTime <: LowLevelCostModel{Float64} end   # "경로 소요시간 = 비용" 모델(빈 구조체, 비용타입은 Float64로 고정)


abstract type AbstractDeadlineCost <: LowLevelCostModel{Float64} end   # 마감시간 기반 비용 모델들의 추상 부모
"""
    DeadlineCost

Identical to `TravelTime`, except for the behavior of
`add_heuristic_cost`.

add_heuristic_cost: `c = max(0.0, t + Δt - deadline)`
"""
# 가변 구조체 — deadline 을 나중에 바꿀 수 있어야 하므로 mutable.
mutable struct DeadlineCost <: AbstractDeadlineCost
    deadline::Float64 # deadline   # 마감 시각
    m::TravelTime                  # 내부적으로 사용하는 TravelTime 비용 모델
end
# 생성자: deadline 만 주면 내부 m 은 기본 TravelTime() 으로 채움. {R<:Real} 은 실수면 어떤 종류든(Int, Float 등) 허용.
DeadlineCost(deadline::R) where {R<:Real} = DeadlineCost(deadline, TravelTime())
function set_deadline!(m::DeadlineCost, t_max)   # 마감시각 설정
    m.deadline = minimum(t_max)   # t_max(여러 값일 수 있음)의 최소값을 마감으로
    return m
end
# 다른 종류의 비용모델에 대해서는 set_deadline! 이 아무것도 안 함(no-op). 호출부에서 타입 구분 없이 부를 수 있게 함.
set_deadline!(m::C, args...) where {C<:AbstractCostModel} = nothing   # 일반 비용모델: 마감 설정 무시
# set_deadline!(m::C,args...) where {C<:FullCostModel} = set_deadline!(m.model,args...)    # (주석) 합성모델용 변형들
# set_deadline!(m::C,args...) where {C<:MetaCostModel} = set_deadline!(m.model,args...)
# function set_deadline!(m::C,args...) where {C<:CompositeCostModel}
#     for model in m.cost_models
#         set_deadline!(model,args...)
#     end
# end
# 휴리스틱 비용 추가: max(0, 현재비용 + 추정비용 - 마감). 마감을 넘긴 만큼만 페널티로 더함.
add_heuristic_cost(m::C, cost, h_cost) where {C<:DeadlineCost} = max(0.0, cost + h_cost - m.deadline) # assumes heuristic is PerfectHeuristic
# 비용 관련 함수 4개를 AbstractDeadlineCost 에 대해 "내부 m(TravelTime)으로 위임"하도록 자동 생성.
for op in [:accumulate_cost, :get_initial_cost, :get_transition_cost, :compute_path_cost]
    @eval $op(model::AbstractDeadlineCost, args...) = $op(model.m, args...)   # 예: accumulate_cost(model, ...) = accumulate_cost(model.m, ...)
end
# FullDeadlineCost(model::DeadlineCost) = FullCostModel(costs->max(0.0, maximum(costs)),model)

"""
    MultiDeadlineCost

Combines multiple deadlines according to some specified aggregation function.
"""
# {F} : 집계함수 타입을 매개변수로 받음(SumCost 면 합, MaxCost 면 최대). 여러 마감을 한 함수로 결합하는 비용 모델.
struct MultiDeadlineCost{F} <: AbstractDeadlineCost
    f::F # aggregation function   # 집계함수(SumCost 또는 MaxCost)
    tF::Vector{Float64}           # 각 노드의 종료시각 벡터
    root_nodes::Vector{Int} # weights and deadlines correspond to root_nodes only   # 가중치/마감이 적용되는 루트 노드 인덱스들
    weights::Vector{Float64}      # 루트 노드별 가중치
    deadlines::Vector{Float64}    # 루트 노드별 마감시각
    m::TravelTime                 # 내부 TravelTime 모델
end
# const 별칭(typedef 처럼): SumOfMakeSpans = "합으로 집계하는 MultiDeadlineCost", MakeSpan = "최대로 집계".
const SumOfMakeSpans = MultiDeadlineCost{SumCost}   # 각 프로젝트 완료시간의 "합"을 최소화하는 목적
const MakeSpan = MultiDeadlineCost{MaxCost}          # 전체 완료시간(가장 늦은 것)을 최소화하는 목적
# 아래는 위 별칭들을 인자 유무에 따라 만드는 생성자들. `Float64.(tF)` 의 점(.) 은 tF 의 각 원소를 Float64 로 변환(broadcast).
SumOfMakeSpans(tF, root_nodes, weights, deadlines) = MultiDeadlineCost(SumCost(), Float64.(tF), root_nodes, Float64.(weights), Float64.(deadlines), TravelTime())  # 인자 채운 합 버전
SumOfMakeSpans() = MultiDeadlineCost(SumCost(), Float64[], Int[], Float64[], Float64[], TravelTime())   # 빈(기본) 합 버전
MakeSpan(tF, root_nodes, weights, deadlines) = MultiDeadlineCost(MaxCost(), Float64.(tF), root_nodes, Float64.(weights), Float64.(deadlines), TravelTime())  # 인자 채운 최대 버전
MakeSpan() = MultiDeadlineCost(MaxCost(), Float64[], Int[], Float64[], Float64[], TravelTime())   # 빈(기본) 최대 버전
function set_deadline!(m::M, t_max) where {M<:MultiDeadlineCost}   # 마감 벡터 설정
    m.deadlines .= t_max   # `.=` 는 원소별 대입(broadcast assignment). deadlines 의 각 칸에 t_max 값을 채움
    return m
end
# 휴리스틱 비용: 각 마감 초과분(max(0, ...))에 가중치를 곱한 뒤 집계함수 f 로 묶음. 모든 연산이 점(.)=원소별.
add_heuristic_cost(m::C, cost, h_cost) where {C<:MultiDeadlineCost} = m.f(m.weights .* max.(0.0, cost .+ h_cost .- m.deadlines)) # assumes heuristic is PerfectHeuristic
# 전체 비용 집계: 루트 노드들의 종료시각 tF[root_nodes] 에 가중치를 곱한 뒤 f 로 결합. `tF[m.root_nodes]` 는 인덱스 배열로 골라내기.
aggregate_costs(m::C, costs::Vector{T}) where {T,C<:MultiDeadlineCost} = m.f(m.tF[m.root_nodes] .* m.weights)   # 가중 완료시간 집계
aggregate_costs_meta(m::C, costs::Vector{T}) where {T,C<:MultiDeadlineCost} = maximum(costs)   # 메타환경: 그냥 비용들의 최대값


#################################################

"""
    TaskGraphsMILP

Concrete subtypes of `TaskGraphsMILP` define different ways to formulate the
sequential assignment portion of a PC-TAPF problem.
"""
abstract type TaskGraphsMILP end   # 작업배정을 정수계획(MILP)으로 푸는 방식들의 추상 부모

# JuMP(최적화 모델링 라이브러리)의 함수들을 우리 MILP 래퍼에 위임. `:(JuMP.optimize!)` 처럼 모듈경로 포함 식을 심볼로 보관.
# 결과: optimize!(milp) 를 부르면 내부 milp.model 에 대해 JuMP.optimize! 가 호출됨(인자 없는 함수들).
for op in [
    :(JuMP.optimize!),          # 최적화 실행
    :(JuMP.termination_status), # 종료 상태(최적/실패 등)
    :(JuMP.objective_function), # 목적함수
    :(JuMP.objective_bound),    # 목적값 경계
    :(JuMP.primal_status),      # 원문제(primal) 해 상태
    :(JuMP.dual_status),        # 쌍대문제(dual) 해 상태
    :(JuMP.set_silent),         # 솔버 출력 끄기
]
    @eval $op(milp::TaskGraphsMILP) = $op(milp.model)   # milp 래퍼 호출을 내부 .model 로 위임
end
# 위와 같지만 추가 인자(args...)를 받는 함수들(설정값 등).
for op in [
    :(JuMP.set_optimizer_attribute),   # 솔버 속성 하나 설정
    :(JuMP.set_optimizer_attributes),  # 솔버 속성 여러 개 설정
    :(JuMP.set_time_limit_sec),        # 시간 제한(초) 설정
]
    @eval $op(milp::TaskGraphsMILP, args...) = $op(milp.model, args...)   # 인자까지 내부 .model 로 위임
end

"""
    AssignmentMILP <: TaskGraphsMILP

Used to formulate a MILP where the decision variable is a matrix `X`, where
`X[i,j] = 1` means that robot `i` is assigned to delivery task `j`. The
dimensionality of `X` is (N+M) × M, where N is the number of robots and M is the
number of delivery tasks. the last M rows of `X` correspond to "dummy robots",
i.e. the N+jth row corresponds to "the robot that already completed task j". The
use of these dummy robot variables allows the sequential assignment problem to
be posed as a one-off assignment problem with inter-task constraints.
"""
# 이 구조체 = 행렬 X 를 결정변수로 쓰는 배정 MILP. X[i,j]=1 이면 로봇 i 가 작업 j 를 맡음.
@with_kw struct AssignmentMILP <: TaskGraphsMILP
    model::JuMP.Model = Model()                  # JuMP 최적화 모델(변수/제약/목적이 담김)
    sched::OperatingSchedule = OperatingSchedule()   # 대상 작업 스케줄
    # Pair{A,B} : (a => b) 쌍 타입(파이썬 튜플 (a, b) 비슷, key=>value). p.first 가 앞, p.second 가 뒤.
    # collect(...) : 이터러블을 배열로 모음. sort(...; by=p->p.first) : p.first(ID) 기준 정렬. by 키워드는 정렬 키 함수.
    robot_ics::Vector{Pair{RobotID,ScheduleNode}} = sort(collect(get_nodes_of_type(sched, BotID)); by=p -> p.first)        # 로봇 초기조건들(ID=>노드), ID순 정렬
    object_ics::Vector{Pair{ObjectID,ScheduleNode}} = sort(collect(get_nodes_of_type(sched, ObjectID)); by=p -> p.first)   # 부품 초기조건들
    operations::Vector{Pair{OperationID,ScheduleNode}} = sort(collect(get_nodes_of_type(sched, OperationID)); by=p -> p.first)  # 조립 연산들
    # Dict{...}(p.first => k for (k,p) in enumerate(...)) : 딕셔너리 컴프리헨션. ID → (1부터의) 순번 매핑 생성.
    robot_map::Dict{BotID,Int} = Dict{BotID,Int}(p.first => k for (k, p) in enumerate(robot_ics))          # 로봇ID → 행렬 인덱스
    object_map::Dict{ObjectID,Int} = Dict{ObjectID,Int}(p.first => k for (k, p) in enumerate(object_ics))   # 부품ID → 인덱스
    operation_map::Dict{OperationID,Int} = Dict{OperationID,Int}(p.first => k for (k, p) in enumerate(operations))  # 연산ID → 인덱스
end
AssignmentMILP(model::JuMP.Model) = AssignmentMILP(model=model)   # model 만 받아 나머지는 기본값으로 만드는 생성자

"""
    SparseAdjacencyMILP <: TaskGraphsMILP

Formulates a MILP where the decision variable is a sparse adjacency matrix `X`
    for the operating schedule graph. If `X[i,j] = 1`, there is an edge from
    node `i` to node `j`.
Experiments have shown that the sparse matrix approach leads to much faster
solve times than the dense matrix approach.
"""
# 이 구조체 = 결정변수가 "희소 인접행렬"인 MILP. X[i,j]=1 이면 노드 i→j 엣지 존재. 밀집행렬보다 빠름.
@with_kw struct SparseAdjacencyMILP <: TaskGraphsMILP
    model::JuMP.Model = Model()   # JuMP 모델
    # SparseMatrixCSC{VariableRef,Int} : 원소가 JuMP 변수(VariableRef)인 희소행렬. 인자들은 (행,열,colptr,rowval,nzval) 빈 행렬 초기화.
    Xa::SparseMatrixCSC{VariableRef,Int} = SparseMatrixCSC{VariableRef,Int}(0, 0, ones(Int, 1), Int[], VariableRef[]) # assignment adjacency matrix  # 배정 인접행렬
    Xj::SparseMatrixCSC{VariableRef,Int} = SparseMatrixCSC{VariableRef,Int}(0, 0, ones(Int, 1), Int[], VariableRef[]) # job shop adjacency matrix  # job-shop 인접행렬
    job_shop::Bool = false   # job-shop(같은 station 동시사용 금지) 제약을 켤지 여부
end

# 최적화 결과에서 배정행렬(0/1)을 추출. value.(...) = 각 변수의 최적값(broadcast), round. = 반올림, min.(1,..) = 1 이하로 클램프.
function get_assignment_matrix(model::M) where {M<:JuMP.Model}
    Matrix{Int}(min.(1, round.(value.(model[:X])))) # guarantees binary matrix  # 0/1 정수행렬 보장
end
get_assignment_matrix(model::TaskGraphsMILP) = get_assignment_matrix(model.model)   # 래퍼면 내부 .model 로 위임


"""
    preprocess_project_schedule(sched)

Returns information about the eligible and required successors and predecessors
of nodes in `sched`

Arguments:
- `sched::OperatingSchedule`

Outputs:
- missing_successors
- missing_predecessors
- n_eligible_successors
- n_eligible_predecessors
- n_required_successors
- n_required_predecessors
- upstream_vertices
- non_upstream_vertices

TODO: OBJECT_AT nodes should always have the properties that
`indegree(G,v) == n_required_predecessors(v) == n_eligible_predecessors(v)`
`outdegree(G,v) == n_required_successors(v) == n_eligible_successors(v)`
Not sure if this is currently the case. UPDATE: I believe this has already been
    addressed by making each object come from an initial operation.
"""
# 스케줄 각 노드의 "필요/허용 가능한 선후속 수"와 "아직 빠진 선후속"을 미리 계산. MILP 제약 만들 때 사용.
function preprocess_project_schedule(sched)
    G = get_graph(sched)   # 내부 그래프
    # Identify required and eligible edges   # 필수/허용 엣지 식별
    missing_successors = Dict{Int,Dict}()    # 정점 → (아직 안 채워진 후속 템플릿들)
    missing_predecessors = Dict{Int,Dict}()  # 정점 → (아직 안 채워진 선행 템플릿들)
    n_eligible_successors = zeros(Int, nv(G))     # 정점별 "허용 가능한 후속 수". nv(G)=정점 수, zeros 로 0 배열 생성
    n_eligible_predecessors = zeros(Int, nv(G))   # 정점별 허용 선행 수
    n_required_successors = zeros(Int, nv(G))     # 정점별 필수 후속 수
    n_required_predecessors = zeros(Int, nv(G))   # 정점별 필수 선행 수
    for v in Graphs.vertices(G)   # 모든 정점을 돌며
        node = get_node_from_id(sched, get_vtx_id(sched, v))   # 정점 v 의 노드
        for (key, val) in required_successors(node)   # 필수 후속 (템플릿=>개수) 들을 합산
            n_required_successors[v] += val
        end
        for (key, val) in required_predecessors(node)   # 필수 선행 합산
            n_required_predecessors[v] += val
        end
        for (key, val) in eligible_successors(node)   # 허용 후속 합산
            n_eligible_successors[v] += val
        end
        for (key, val) in eligible_predecessors(node)   # 허용 선행 합산
            n_eligible_predecessors[v] += val
        end
        missing_successors[v] = eligible_successors(node)   # 처음엔 "허용 후속 전부"가 빠진 상태로 시작
        for v2 in outneighbors(G, v)   # 이미 연결된 후속들을 보고
            id2 = get_vtx_id(sched, v2)
            node2 = get_node_from_id(sched, id2)
            for key in collect(keys(missing_successors[v]))   # 빠진 템플릿들 중에서
                if matches_template(key, typeof(node2))   # 이 후속이 그 템플릿과 맞으면
                    missing_successors[v][key] -= 1   # 해당 템플릿의 "빠진 개수"를 1 줄임
                    break   # 하나만 차감하고 빠져나감
                end
            end
        end
        missing_predecessors[v] = eligible_predecessors(node)   # 선행도 동일하게 "전부 빠짐"으로 시작
        for v2 in inneighbors(G, v)   # 이미 연결된 선행들을 보고
            id2 = get_vtx_id(sched, v2)
            node2 = get_node_from_id(sched, id2)
            for key in collect(keys(missing_predecessors[v]))
                if matches_template(key, typeof(node2))   # 매칭되는 템플릿이면
                    missing_predecessors[v][key] -= 1   # 빠진 개수 차감
                    break
                end
            end
        end
    end
    # any(...) : 하나라도 참이면 true. `.<` 는 원소별 비교. "허용 < 필수" 인 정점이 있으면 모순 → 검증.
    @assert(!any(n_eligible_predecessors .< n_required_predecessors))   # 허용 선행이 필수보다 적으면 안 됨
    @assert(!any(n_eligible_successors .< n_required_successors))       # 허용 후속이 필수보다 적으면 안 됨

    # upstream_vertices[v] = v 자신 + v 의 모든 상류(선행 방향) 정점들. bfs_tree(..; dir=:in) 은 들어오는 방향 BFS 트리.
    upstream_vertices = map(v -> [v, map(e -> e.dst, collect(edges(bfs_tree(G, v; dir=:in))))...], Graphs.vertices(G))
    # non_upstream_vertices[v] = 전체 정점에서 상류 정점들을 뺀 나머지. setdiff = 차집합.
    non_upstream_vertices = map(v -> collect(setdiff(collect(Graphs.vertices(G)), upstream_vertices[v])), Graphs.vertices(G))

    # 계산한 8가지 결과를 한꺼번에 반환(튜플). 줄리아 함수는 여러 값을 쉼표로 반환 가능(파이썬과 동일).
    return missing_successors, missing_predecessors, n_eligible_successors, n_eligible_predecessors, n_required_successors, n_required_predecessors, upstream_vertices, non_upstream_vertices
end


"""
    formulate_milp(milp_model::AssignmentMILP,sched,problem_spec;kwargs...)

Express the TaskGraphs assignment problem as an `AssignmentMILP` using the JuMP
optimization framework.

Inputs:
    milp_model::T <: TaskGraphsMILP : a milp model that determines how the
        sequential task assignment problem is modeled. Current options are
        `AssignmentMILP`, `SparseAdjacencyMILP` and `GreedyAssignment`.
    sched::OperatingSchedule : a partial operating schedule, where
        some or all assignment edges may be missing.
    problem_spec::ProblemSpec : encodes the distance matrix and other
        information about the problem.

Keyword Args:
    `optimizer` - a JuMP optimizer (e.g., Gurobi.optimizer)
    `cost_model=MakeSpan` - optimization objective, currently either `MakeSpan`
        or `SumOfMakeSpans`. Defaults to the cost_model associated with
        `problem_spec`
Outputs:
    `model::AssignmentMILP` - an instantiated optimization problem
"""
# 작업배정 문제를 AssignmentMILP(JuMP 모델)로 정식화하는 함수.
# 함수 시그니처에서 `;` 이후는 "키워드 인자". 파이썬의 keyword-only 인자와 비슷. `이름=기본값` 으로 기본값 지정.
function formulate_milp(milp_model::AssignmentMILP,
    sched::OperatingSchedule,
    problem_spec::ProblemSpec;
    optimizer=default_milp_optimizer(),        # 사용할 솔버(기본은 전역 기본 솔버)
    cost_model=problem_spec.cost_function,     # 목적함수(기본은 문제명세의 것)
    Mm=10000,                                  # Big-M 제약에 쓰는 큰 상수
    kwargs...)                                 # 나머지 키워드 인자들을 묶어 받음(파이썬 **kwargs)

    # SETUP
    # Define optimization model   # 최적화 모델 정의
    model = Model(optimizer_with_attributes(optimizer))   # 지정한 솔버로 JuMP 모델 생성
    set_optimizer_attributes(model, default_milp_optimizer_attributes()...)   # 기본 솔버 속성들을 펼쳐(...) 적용
    milp = AssignmentMILP(model=model, sched=sched)   # 래퍼 구조체 생성

    # @unpack : Parameters 패키지 매크로. 구조체 필드들을 같은 이름의 지역변수로 한꺼번에 꺼냄(파이썬 구조분해 비슷).
    @unpack robot_ics, object_ics, operations, robot_map, object_map, operation_map = milp

    N = length(robot_ics) # number of robots          # 로봇 수
    M = length(object_ics) # number of delivery tasks  # 배달(작업) 수
    Δt_collect = zeros(Int, M)   # 작업별 COLLECT 소요시간 배열(0 으로 초기화)
    Δt_deposit = zeros(Int, M)   # 작업별 DEPOSIT 소요시간 배열
    # map + 람다로 각 로봇/부품의 초기 위치 ID 추출. p.second.node 는 (ID=>노드)쌍의 노드, 거기서 초기위치 ID 꺼냄.
    r0 = map(p -> get_id(get_initial_location_id(p.second.node)), robot_ics) # initial robot locations  # 로봇 초기 위치들
    s0 = map(p -> get_id(get_initial_location_id(p.second.node)), object_ics) # initial object locations # 부품 초기 위치들
    sF = zeros(Int, M)   # 작업별 최종(배달) 위치 배열
    for (v, n) in enumerate(get_nodes(sched))   # 모든 스케줄 노드를 (인덱스 v, 노드 n) 으로 순회
        if matches_node_type(n, BOT_COLLECT)   # COLLECT(집기) 노드면
            Δt_collect[object_map[get_object_id(n)]] = get_min_duration(n)   # 해당 부품의 집기 소요시간 기록
        elseif matches_node_type(n, BOT_DEPOSIT)   # DEPOSIT(내려놓기) 노드면
            Δt_deposit[object_map[get_object_id(n)]] = get_min_duration(n)   # 내려놓기 소요시간 기록
            sF[object_map[get_object_id(n)]] = get_id(get_destination_location_id(n))   # 최종 위치 기록
        end
    end
    # from ProblemSpec
    # 거리 함수 D(x,y) 를 람다로 정의 — 문제명세의 거리행렬을 조회. 아래 제약식에서 두 위치 간 이동시간으로 사용.
    D = (x, y) -> get_distance(problem_spec, x, y)

    # @variable : JuMP 매크로 — 모델에 결정변수를 추가. `to0[1:M]` 은 길이 M 인 변수 벡터, `>= 0.0` 은 하한 제약.
    @variable(model, to0[1:M] >= 0.0) # object availability time      # 부품 가용(준비) 시각
    @variable(model, tor[1:M] >= 0.0) # object robot arrival time     # 로봇이 부품에 도착하는 시각
    @variable(model, toc[1:M] >= 0.0) # object collection complete time  # 부품 집기 완료 시각
    @variable(model, tod[1:M] >= 0.0) # object deliver begin time     # 부품 배달 시작 시각
    @variable(model, tof[1:M] >= 0.0) # object termination time       # 부품 작업 종료 시각
    @variable(model, tr0[1:N+M] >= 0.0) # robot availability time     # 로봇 가용 시각(실로봇 N + 더미로봇 M)

    # Assignment matrix x
    @variable(model, X[1:N+M, 1:M], binary = true) # X[i,j] ∈ {0,1}   # 배정행렬 X(0/1 이진변수). 행=로봇, 열=작업
    # @constraint : 모델에 제약 추가. `.<=`/`.==` 는 원소별 비교. ones(M)=길이 M 의 1 벡터. X * ones(M) = 각 행의 합.
    @constraint(model, X * ones(M) .<= 1)         # each robot may have no more than 1 task   # 로봇 한 대는 최대 1작업
    @constraint(model, X' * ones(N + M) .== 1)     # each task must have exactly 1 assignment  # X'=전치, 각 작업은 정확히 1배정
    for (id, node) in robot_ics # robot start times   # 로봇 시작시각 고정
        # @constraint(model, tr0[robot_map[id]] == get_t0(node))
        @constraint(model, tr0[robot_map[id]] == get_tF(node))   # 로봇 가용시각 = 그 로봇 노드의 종료시각
    end
    for (id, node) in object_ics # task start times   # 작업 시작시각
        if is_root_node(sched, id) # only applies to root tasks (with no prereqs)   # 선행 없는 루트 작업만
            # @constraint(model, to0[object_map[id]] == get_t0(node))
            @constraint(model, to0[object_map[id]] == get_tF(node))   # 부품 가용시각 = 그 부품 노드 종료시각
        end
    end
    # 선후관계 그래프 생성. {Nothing,ObjectID} = 노드 데이터는 없음(Nothing), 노드ID 타입은 ObjectID.
    precedence_graph = CustomNDiGraph{Nothing,ObjectID}()
    for (id, _) in object_ics   # `_` 는 "안 쓰는 값" 자리표시(파이썬과 동일). 모든 부품을 노드로 추가
        add_node!(precedence_graph, nothing, id)
    end
    for (op_id, node) in operations #get_operations(sched) # precedence constraints on task start time  # 연산 기반 선후 제약
        op = node.node   # 노드 안의 실제 연산 객체
        for (_, input) in preconditions(op)   # 이 연산의 입력(선행 조건) 부품들
            i = object_map[get_object_id(input)]   # 입력 부품의 인덱스
            for (_, output) in postconditions(op)   # 이 연산의 출력(결과) 부품들
                j = object_map[get_object_id(output)]   # 출력 부품의 인덱스
                @constraint(model, to0[j] >= tof[i] + duration(op))   # 출력은 입력 종료 + 연산시간 이후에야 시작 가능
                add_edge!(precedence_graph, get_object_id(input), get_object_id(output))   # 선후관계 엣지 추가
            end
        end
    end
    # propagate upstream edges through precedence graph   # 선후관계의 추이적(transitive) 폐쇄: 간접 선후관계도 직접 엣지로
    for v in topological_sort_by_dfs(precedence_graph)
        for v1 in inneighbors(precedence_graph, v)   # v 의 선행 v1 과
            for v2 in outneighbors(precedence_graph, v)   # v 의 후속 v2 사이에
                add_edge!(precedence_graph, v1, v2)   # v1→v2 직접 엣지 추가(v 를 건너뛴 관계)
            end
        end
        add_edge!(precedence_graph, v, v)   # 자기 자신으로의 엣지(상류 판정 편의용)
    end
    # constraints
    # vcat : 수직(세로) 결합. r0(실로봇 위치) 뒤에 sF(작업 최종위치=더미로봇 출발지)를 이어붙임.
    r0 = vcat(r0, sF) # combine to get dummy robot ``spawn'' locations too   # 실로봇 + 더미로봇 위치 합치기
    for j in 1:M   # 각 작업 j 에 대해
        # constraint on dummy robot start time (corresponds to moment of object delivery)   # 더미로봇 시작시각 = 배달 완료 순간
        @constraint(model, tr0[j+N] == tof[j])   # j 번째 더미로봇(인덱스 j+N)은 작업 j 종료시각에 생김
        # dummy robots can't do upstream jobs   # 더미로봇은 상류(선행) 작업을 못 함
        for v in inneighbors(precedence_graph, j)
            @constraint(model, X[j+N, v] == 0)   # 더미로봇 j 가 선행작업 v 를 맡지 못하게 0 고정
        end
        # lower bound on task completion time (task can't start until it's available).   # 작업은 가용 전엔 시작 못 함
        @constraint(model, tor[j] >= to0[j])   # 로봇 도착시각 >= 부품 가용시각
        for i in 1:N+M   # 모든 (실+더미) 로봇 i 에 대해 Big-M 제약
            # X[i,j]=1(로봇 i 가 작업 j 담당)일 때만 "도착시각 >= 로봇가용 + 이동시간" 강제. 아니면 -Mm 로 느슨해짐.
            @constraint(model, tor[j] - (tr0[i] + D(r0[i], s0[j])) >= -Mm * (1 - X[i, j]))
        end
        @constraint(model, toc[j] == tor[j] + Δt_collect[j])   # 집기완료 = 도착 + 집기시간
        @constraint(model, tod[j] == toc[j] + D(s0[j], sF[j]))   # 배달시작 = 집기완료 + (출발지→목적지 이동시간)
        @constraint(model, tof[j] == tod[j] + Δt_deposit[j])     # 종료 = 배달시작 + 내려놓기시간
        """ "Job-shop" constraints specifying that no station may be double-booked. A station
        can only support a single COLLECT or DEPOSIT operation at a time, meaning that all
        the windows for these operations cannot overlap. In the constraints below, t1 and t2
        represent the intervals for the COLLECT or DEPOSIT operations of tasks j and j2,
        respectively. If eny of the operations for these two tasks require use of the same
        station, we introduce a 2D binary variable y. if y = [1,0], the operation for task
        j must occur before the operation for task j2. The opposite is true for y == [0,1].
        We use the big M method here as well to tightly enforce the binary constraints.
        """
        for j2 in j+1:M   # j 와 j2(>j) 작업 쌍에 대해 — station 중복예약 방지(job-shop)
            # `||` = "또는"(파이썬 or). 두 작업이 같은 station(출발지/목적지)을 공유하면 시간창이 겹치면 안 됨.
            if (s0[j] == s0[j2]) || (s0[j] == sF[j2]) || (sF[j] == s0[j2]) || (sF[j] == sF[j2])
                # @show j, j2   # (디버깅용) 변수값 출력 매크로 — 주석처리됨
                if s0[j] == s0[j2]   # 어느 위치가 겹치는지에 따라 비교할 시간창 t1, t2 선택
                    t1 = [tor[j], toc[j]]     # 작업 j 의 집기 시간창
                    t2 = [tor[j2], toc[j2]]   # 작업 j2 의 집기 시간창
                elseif s0[j] == sF[j2]
                    t1 = [tor[j], toc[j]]
                    t2 = [tod[j2], tof[j2]]
                elseif sF[j] == s0[j2]
                    t1 = [tod[j], tof[j]]
                    t2 = [tor[j2], toc[j2]]
                elseif sF[j] == sF[j2]
                    t1 = [tod, tof[j]]
                    t2 = [tod, tof[j2]]
                end
                tmax = @variable(model)   # 두 시간창 시작 중 더 늦은 값을 담을 보조변수
                tmin = @variable(model)   # 두 시간창 끝 중 더 이른 값을 담을 보조변수
                y = @variable(model, binary = true)   # 어느 작업이 먼저인지 정하는 이진 선택변수
                @constraint(model, tmax >= t1[1])   # tmax >= 두 시작점 모두
                @constraint(model, tmax >= t2[1])
                @constraint(model, tmin <= t1[2])   # tmin <= 두 끝점 모두
                @constraint(model, tmin <= t2[2])

                @constraint(model, tmax - t2[1] <= (1 - y) * Mm)   # y 값에 따라 tmax 를 한쪽 시작점에 고정(Big-M)
                @constraint(model, tmax - t1[1] <= y * Mm)
                @constraint(model, tmin - t1[2] >= (1 - y) * -Mm)   # y 값에 따라 tmin 을 한쪽 끝점에 고정
                @constraint(model, tmin - t2[2] >= y * -Mm)
                @constraint(model, tmin + 1 - X[j+N, j2] - X[j2+N, j] <= tmax) # NOTE +1 not necessary if the same robot is doing both  # 시간창 비겹침(같은 로봇이 둘 다면 +1 불필요)
            end
        end
    end
    cost = get_objective_expr(milp, cost_model)   # 목적함수 식 생성(선택한 cost_model 기준)
    @objective(model, Min, cost)   # @objective : 모델의 최적화 방향/목적 설정. Min = 최소화
    return milp   # 정식화된 MILP 반환
end

"""
    adj_mat_from_assignment_mat(sched,assignment_matrix)

Compute an adjacency matrix from an assignment matrix
"""
# 배정행렬(로봇↔작업)로부터 그래프 인접행렬(노드 간 엣지)을 만든다. 배정 결과를 실제 스케줄 엣지로 변환.
function adj_mat_from_assignment_mat(model::AssignmentMILP, sched::OperatingSchedule, assignment_matrix)
    M = size(assignment_matrix, 2)   # size(.,2) = 열 수 = 작업 수
    N = size(assignment_matrix, 1) - M   # 행 수 - M = 실제 로봇 수(앞 N행이 실로봇)
    @assert N == length(get_robot_ICs(sched))   # 계산한 N 이 실제 로봇 초기조건 수와 일치하는지 검증
    @unpack robot_ics, object_ics = model   # 모델에서 로봇/부품 초기조건 꺼내기
    # M = length(get_object_ICs(sched))
    assignment_dict = get_assignment_dict(assignment_matrix, N, M)   # 행렬 → {로봇 → 맡은 작업 목록} 딕셔너리
    G = get_graph(sched)
    adj_matrix = adjacency_matrix(G)   # 현재 그래프의 인접행렬(0/1)에서 시작
    for (robot_idx, task_list) in assignment_dict   # 각 로봇과 그가 맡은 작업 목록에 대해
        robot_id = get_robot_id(robot_ics[robot_idx].second)   # 로봇 ID
        robot_node = robot_ics[robot_idx].second   # 로봇 노드(.second = 쌍의 뒤쪽 값)
        if is_terminal_node(sched, robot_node)   # 로봇 노드가 종단(더 갈 곳 없음)이면
            v_go = get_vtx(sched, robot_node)   # 그 노드 자체를 GO 시작점으로
        else
            v_go = outneighbors(sched, robot_node)[1] # GO_NODE   # 아니면 첫 후속(GO 노드)을 시작점으로. [1]=첫 원소(줄리아 인덱스는 1부터)
        end
        if !is_terminal_node(sched, v_go)   # GO 노드는 종단이어야 함(아직 작업 미배정 상태)
            log_schedule_edges(sched)
            # `$(...)` : 문자열 보간(파이썬 f-string 의 {} 와 동일). 식의 결과를 문자열에 끼워넣음.
            @assert is_terminal_node(sched, v_go) "!is_terminal_node($(string(get_node(sched,v_go).node)))"
        end
        for object_idx in task_list   # 이 로봇이 맡은 각 작업(부품)에 대해 작업 체인을 엣지로 연결
            object_id = get_object_id(object_ics[object_idx].second)   # 부품 ID
            # object_node = get_node(sched,object_id)
            v_collect = outneighbors(sched, object_id)[1]   # 부품 → COLLECT(집기) 노드
            adj_matrix[v_go, v_collect] = 1   # GO → COLLECT 엣지 추가(이 로봇이 이 부품을 집으러 감)
            v_carry = outneighbors(sched, v_collect)[1]   # COLLECT → CARRY(운반)
            v_deposit = outneighbors(sched, v_carry)[1]   # CARRY → DEPOSIT(내려놓기)
            for v in outneighbors(sched, v_deposit)   # DEPOSIT 후속들 중에서
                if isa(get_vtx_id(sched, v), ActionID)   # isa(x, T) : x 가 타입 T 인지(파이썬 isinstance). 다음 GO(행동)노드 찾기
                    v_go = v   # 다음 작업의 시작점으로 갱신(연쇄 배정)
                    break
                end
            end
        end
    end
    return adj_matrix   # 완성된 인접행렬 반환
end


# 같은 이름 formulate_milp 의 SparseAdjacencyMILP 버전(다중 디스패치로 첫 인자 타입에 따라 이게 호출됨).
function formulate_milp(
    milp_model::SparseAdjacencyMILP,
    sched,
    problem_spec;
    # Union{SparseMatrixCSC,Nothing} : "희소행렬 또는 Nothing(없음)" 둘 중 하나의 타입. 파이썬 Optional[Matrix] 느낌.
    warm_start_soln::Union{SparseMatrixCSC,Nothing}=nothing,   # 따뜻한 시작(이전 해)으로 솔버 가속. 기본 없음
    optimizer=default_milp_optimizer(),
    t0_=Dict{AbstractID,Float64}(), # dictionary of initial times. Default is empty   # 미리 주어진 시작시각들
    tF_=Dict{AbstractID,Float64}(), # dictionary of initial times. Default is empty   # 미리 주어진 종료시각들
    Mm=10000, # for big M constraints   # Big-M 상수
    cost_model=SumOfMakeSpans(),
    job_shop=milp_model.job_shop,
    extra_constraints=nothing, # RESPEC: verified LLM re-specification (RespecProposal) or nothing   # LLM 재명세 추가제약(없으면 무시)
    kwargs...
)

    warm_start = false   # 따뜻한 시작 사용 여부 플래그
    if !isnothing(warm_start_soln)   # isnothing(x) : x 가 Nothing 인지 검사. 해가 주어졌으면
        warm_start = true   # 따뜻한 시작 켬
    end

    model = Model(optimizer_with_attributes(optimizer))   # JuMP 모델 생성
    set_optimizer_attributes(model, default_milp_optimizer_attributes()...)   # 기본 솔버 속성 적용

    G = get_graph(sched)
    # 좌변의 (a, b, c, ...) = 함수반환 : 여러 반환값을 한꺼번에 풀어서 받는 구조분해(파이썬과 동일).
    (missing_successors, missing_predecessors, n_eligible_successors,
        n_eligible_predecessors, n_required_successors, n_required_predecessors,
        upstream_vertices, non_upstream_vertices
    ) = preprocess_project_schedule(sched)   # 위에서 정의한 전처리 결과 8개를 받음

    Δt = get_min_duration(sched)   # 모든 노드의 최소 소요시간 벡터

    @variable(model, t0[1:nv(sched)] >= 0.0) # initial times for all nodes   # 모든 노드의 시작시각 변수
    @variable(model, tF[1:nv(sched)] >= 0.0) # final times for all nodes     # 모든 노드의 종료시각 변수

    # Precedence relationships   # 선후관계(엣지) 변수 행렬 Xa 를 빈 희소행렬로 초기화
    Xa = SparseMatrixCSC{VariableRef,Int}(nv(sched), nv(sched), ones(Int, nv(sched) + 1), Int[], VariableRef[])
    # EFFICIENCY objective input: per-(optional)-edge transport distance/energy = the
    # min travel duration for assigning edge v→v2. Captured here, summed over the chosen
    # Xa edges in get_objective_expr (Σ d·Xa). Keys match Xa's variable positions.
    # (한국어) EFFICIENCY(효율) 목적함수용 입력: 엣지 v→v2 를 배정할 때 드는 이동거리/에너지를 모아둠.
    #   키 (v,v2) → 비용. 나중에 get_objective_expr 에서 선택된 Xa 엣지들에 대해 Σ(비용·Xa) 로 합산됨.
    edge_costs = Dict{Tuple{Int,Int},Float64}()
    # set all initial times that are provided   # 주어진 시작/종료 시각 제약 추가
    for (id, t) in t0_
        v = get_vtx(sched, id)   # ID → 정점
        @constraint(model, t0[v] >= t)   # 시작시각 하한
    end
    for (id, t) in tF_
        v = get_vtx(sched, id)
        @constraint(model, tF[v] >= t)   # 종료시각 하한
    end
    # Precedence constraints and duration constraints for existing nodes and edges   # 기존 노드/엣지의 소요시간·선후 제약
    for v in Graphs.vertices(sched)
        @constraint(model, tF[v] >= t0[v] + Δt[v]) # NOTE Δt may change for some nodes   # 종료 >= 시작 + 최소소요
        for v2 in outneighbors(sched, v)   # 이미 존재하는 엣지 v→v2 마다
            if warm_start
                Xa[v, v2] = @variable(model, binary = true, start = warm_start_soln[v, v2])   # 이전 해를 시작값(start)으로 준 이진변수
            else
                Xa[v, v2] = @variable(model, binary = true)   # 그냥 이진변수
            end
            @constraint(model, Xa[v, v2] == 1) #TODO this edge already exists--no reason to encode it as a decision variable   # 이미 있는 엣지라 1로 고정
            @constraint(model, t0[v2] >= tF[v]) # NOTE DO NOT CHANGE TO EQUALITY CONSTRAINT. ...   # 후속 시작 >= 선행 종료(등호로 바꾸면 안 됨)
        end
    end

    # Big M constraints   # 아직 안 정해진(추가 가능한) 엣지마다 결정변수와 Big-M 시간 제약 추가
    for v in Graphs.vertices(sched)
        node = get_node_from_id(sched, get_vtx_id(sched, v))
        potential_match = false   # 이 정점에 추가 가능한 엣지가 있었는지 표시
        if outdegree(sched, v) < n_eligible_successors[v] # NOTE: Trying this out to save time on formulation   # 후속을 더 받을 여지가 있을 때만
            for v2 in non_upstream_vertices[v] # for v2 in Graphs.vertices(sched)   # 상류가 아닌 정점들만(사이클 방지)
                if indegree(sched, v2) < n_eligible_predecessors[v2]   # v2 가 선행을 더 받을 수 있으면
                    node2 = get_node_from_id(sched, get_vtx_id(sched, v2))
                    for (template, val) in missing_successors[v]   # v 의 빠진 후속 템플릿마다
                        if !matches_template(template, typeof(node2)) # possible to add an edge   # node2 가 안 맞으면
                            continue   # continue : 다음 반복으로 건너뜀(파이썬과 동일)
                        end
                        for (template2, val2) in missing_predecessors[v2]   # v2 의 빠진 선행 템플릿마다
                            if !matches_template(template2, typeof(node)) # possible to add an edge
                                continue
                            end
                            if (val > 0 && val2 > 0)   # 양쪽 모두 여유가 있으면 엣지 추가 가능
                                potential_match = true
                                new_node = align_with_successor(node, node2)   # 후속에 맞춰 노드 정보 정렬한 가상 노드

                                dt_min = generate_path_spec(sched, problem_spec, new_node).min_duration   # 이 엣지가 생길 때의 최소소요시간
                                # EFFICIENCY: per-edge transport ENERGY (payload hook: edge_energy(dt_min; payload_mass=...)).
                                # ×edge_cost_multiplier(sched,v): per-robot SoC bias (1.0 unless battery hook installed).
                                # (한국어) 이 엣지의 비용 = 이동에너지(edge_energy) × 로봇별 배율(edge_cost_multiplier).
                                #   배율은 기본 1.0(배터리/우선순위 훅이 없으면 원래 거리비용 그대로).
                                edge_costs[(v, v2)] = edge_energy(dt_min) * edge_cost_multiplier(sched, v)
                                if warm_start
                                    Xa[v, v2] = @variable(model, binary = true, start = warm_start_soln[v, v2])   # 따뜻한 시작값 포함 변수
                                else
                                    Xa[v, v2] = @variable(model, binary = true)   # 이진 결정변수
                                end
                                @constraint(model, tF[v] - (t0[v] + dt_min) >= -Mm * (1 - Xa[v, v2]))   # 엣지 선택 시 소요시간 반영(Big-M)
                                @constraint(model, t0[v2] - tF[v] >= -Mm * (1 - Xa[v, v2]))   # 엣지 선택 시 선후 시간 강제
                                break   # 이 (v,v2) 쌍은 처리 끝
                            end
                        end
                    end
                end
            end
        end
        if potential_match == false && job_shop == false   # 추가 엣지 가능성이 없고 job-shop 도 아니면
            @constraint(model, tF[v] == t0[v] + Δt[v]) # adding this constraint may provide some speedup   # 종료=시작+소요로 등호 고정(속도↑)
        end
    end

    # In the sparse implementation, these constraints must come after all possible edges are defined by a VariableRef
    # Xa * ones(...) = 각 행의 합(나가는 엣지 수). 정점별 후속 수가 [필수, 허용] 범위 안에 들도록 제약.
    @constraint(model, Xa * ones(nv(sched)) .<= n_eligible_successors)     # 나가는 엣지 수 <= 허용 후속
    @constraint(model, Xa * ones(nv(sched)) .>= n_required_successors)     # 나가는 엣지 수 >= 필수 후속
    @constraint(model, Xa' * ones(nv(sched)) .<= n_eligible_predecessors)  # Xa'=전치, 각 열 합 = 들어오는 엣지 수
    @constraint(model, Xa' * ones(nv(sched)) .>= n_required_predecessors)
    for i in 1:nv(sched)
        for j in i:nv(sched)   # i 이상 j 만 보면 (i,j)와 (j,i) 쌍을 한 번씩 처리
            # prevent self-edges and cycles   # 자기엣지/양방향(순환) 방지: Xa[i,j] + Xa[j,i] <= 1
            @constraint(model, Xa[i, j] + Xa[j, i] <= 1)
        end
    end

    """
    "Job-shop" constraints specifying that no station may be double-booked. A station
    can only support a single COLLECT or DEPOSIT operation at a time, meaning that all
    the windows for these operations cannot overlap. In the constraints below, t1 and t2
    represent the intervals for the COLLECT or DEPOSIT operations of tasks j and j2,
    respectively. If eny of the operations for these two tasks require use of the same
    station, we introduce a 2D binary variable y. if y = [1,0], the operation for task
    j must occur before the operation for task j2. The opposite is true for y == [0,1].
    We use the big M method here as well to tightly enforce the binary constraints.
    job_shop_variables = Dict{Tuple{Int,Int},JuMP.VariableRef}();
    """
    # Xj : job-shop 제약용 인접행렬(같은 station 쓰는 두 작업의 순서 변수). 빈 희소행렬로 초기화.
    Xj = SparseMatrixCSC{VariableRef,Int}(nv(sched), nv(sched), ones(Int, nv(sched) + 1), Int[], VariableRef[])
    if job_shop   # job-shop 모드일 때만
        for v in 1:nv(sched)
            node = get_node_from_id(sched, get_vtx_id(sched, v))
            for v2 in non_upstream_vertices[v] #v+1:nv(sched)
                # `~` 도 부정(not). v2>v(중복방지) & v 가 v2 의 상류 아님 & 둘 사이 엣지 없음 일 때만
                if v2 > v && ~(v in upstream_vertices[v2]) && ~(has_edge(sched, v, v2) || has_edge(sched, v2, v))
                    node2 = get_node_from_id(sched, get_vtx_id(sched, v2))
                    common_resources = intersect(resources_reserved(node), resources_reserved(node2))   # 공유 자원(station)
                    if length(common_resources) > 0   # 공유 자원이 있으면 동시 사용 금지 제약 필요
                        println("MILP FORMULATION: adding a job shop constraint between ", v, " (", string(node), ") and ", v2, " (", string(node2), ")")  # 로그 출력
                        # @show common_resources
                        # Big M constraints
                        Xj[v, v2] = @variable(model, binary = true) #   # v 가 먼저면 1
                        Xj[v2, v] = @variable(model, binary = true) # need both directions to have a valid adjacency matrix   # v2 가 먼저면 1
                        @constraint(model, Xj[v, v2] + Xj[v2, v] == 1)   # 둘 중 정확히 하나가 먼저(순서 결정)
                        @constraint(model, t0[v2] - tF[v] >= -Mm * (1 - Xj[v, v2]))   # v 먼저면 v2 는 v 종료 후 시작
                        @constraint(model, t0[v] - tF[v2] >= -Mm * (1 - Xj[v2, v]))   # v2 먼저면 반대
                    end
                end
            end
        end
    end

    # Full adjacency matrix
    # @expression : 모델에 "이름 붙은 식"을 등록(변수가 아니라 변수들의 조합). X = Xa + Xj (원소별 합). 전체 인접행렬.
    @expression(model, X, Xa .+ Xj) # Make X an expression rather than a variable

    # RESPEC: inject verified LLM re-specification constraints. This runs AFTER
    # all native constraints and BEFORE @objective, so it can only ADD
    # constraints (shrink the feasible set) and can never touch the objective.
    # `nothing` (the default) is a no-op, so existing call sites are unchanged.
    # `!==` : "동일 객체가 아님"(파이썬 is not). 추가제약이 주어졌을 때만 컴파일해 모델에 주입.
    if extra_constraints !== nothing
        compile_proposal!(model, t0, tF, Xa, sched, extra_constraints)   # LLM 재명세 제약을 모델에 추가
    end

    milp = SparseAdjacencyMILP(model, Xa, Xj, milp_model.job_shop) #, job_shop_variables   # 래퍼 구조체로 묶기
    cost1 = get_objective_expr(milp, cost_model, milp.model, sched, tF; edge_costs=edge_costs)   # 목적함수 식 생성
    @objective(milp.model, Min, cost1)   # 최소화 목적 설정
    LAST_EDGE_COSTS[] = edge_costs        # MEASUREMENT: stash the per-edge energies so handling_energy(milp) can score the chosen assignment post-solve (not thread-safe; for the A/B harness/metrics)
    return milp
end

# --- handling-energy measurement (stats[:HandlingEnergy]) ----------------------
# The per-edge ENERGY dict from the LAST formulate_milp, so a post-solve score
# Σ edge_energy·Xa (the realized handling energy of the CHOSEN assignment) can be read
# WITHOUT changing formulate_milp's return type. Global mutable — sequential use only.
# (한국어) "운반 에너지 측정"용. 방금 실행한 formulate_milp 의 엣지별 에너지 dict 를 여기 전역에 보관.
#   덕분에 풀이가 끝난 뒤 "실제로 선택된 배정의 총 에너지"를 formulate_milp 반환형을 안 바꾸고도 읽을 수 있음.
# `Ref(...)` : 값 하나를 담는 가변 상자(내용을 나중에 바꿀 수 있음). 전역 가변 → 순차 실행에서만 안전(스레드 X).
const LAST_EDGE_COSTS = Ref(Dict{Tuple{Int,Int},Float64}())

"""
    handling_energy(milp; edge_costs=LAST_EDGE_COSTS[]) -> Float64

Σ over CHOSEN assignment edges of their transport ENERGY (= the efficiency objective's value
on the solution). Use to compare two solves: energy↓ at makespan≈same is the headline. Reads
`value(Xa)` from the solved `milp`. Returns NaN if the model is unsolved."""
# (한국어) 풀이가 끝난 milp 에서 "선택된 배정 엣지들의 운반 에너지 합(Σ 에너지·Xa)"을 계산.
#   두 풀이를 비교할 때 핵심 지표: makespan 비슷한데 에너지↓ 이면 더 좋은 해. `LAST_EDGE_COSTS[]` = 상자 안 값 꺼내기.
function handling_energy(milp; edge_costs = LAST_EDGE_COSTS[])
    Xa = milp.Xa
    s = 0.0
    for ((v, v2), c) in edge_costs   # 엣지별 (에너지 c) 에 대해
        try
            s += c * value(Xa[v, v2])   # value(변수) = 최적화된 변수의 값(0/1). 선택된 엣지만 더해짐
        catch
            # 아직 안 풀렸거나 그 변수가 없으면 그냥 건너뜀(예외 무시)
        end
    end
    return s   # 총 운반 에너지
end

# -----------------------------------------------------------------------------
# Multi-objective planning weights (SPEED / EFFICIENCY). Module-level Ref, mirroring
# the RESPEC_* / RESTRICTION_ZONES pattern, so NO struct or signature changes. Default
# (speed=1, efficiency=0) reproduces the original SumOfMakeSpans objective EXACTLY.
# ADAPTABILITY (schedule-deviation / stability) is a REPLAN-time term — it needs a
# prior plan to deviate from — so it is applied in the respec re-solve (warm-started
# from the previous t0/Xa), NOT in this initial-plan objective. See
# docs/llm_navigator_plan.md ("objective must change: speed/efficiency/adaptability").
# -----------------------------------------------------------------------------
# (한국어) 다목적 계획 가중치를 담는 전역 상자. `(speed=…, efficiency=…, adaptability=…)` 는 이름있는 튜플(NamedTuple).
#   기본값 (speed=1, efficiency=0) 이면 원래의 makespan 목적과 완전히 동일(동작 보존).
const PLANNING_OBJECTIVE_WEIGHTS = Ref((speed = 1.0, efficiency = 0.0, adaptability = 0.0))
planning_objective_weights() = PLANNING_OBJECTIVE_WEIGHTS[]   # 현재 가중치를 읽어옴(상자 내용 꺼내기)
# 가중치 설정 함수. `;` 뒤 인자는 키워드 전용 — set_planning_objective_weights!(efficiency=0.3) 처럼 이름으로 지정.
function set_planning_objective_weights!(; speed = 1.0, efficiency = 0.0, adaptability = 0.0)
    PLANNING_OBJECTIVE_WEIGHTS[] = (speed = Float64(speed),
        efficiency = Float64(efficiency), adaptability = Float64(adaptability))   # 모두 Float64 로 맞춰 저장
    return PLANNING_OBJECTIVE_WEIGHTS[]
end

# -----------------------------------------------------------------------------
# Lightweight ENERGY model for the EFFICIENCY objective. Upgrades each edge's cost
# from raw travel duration (distance proxy) to a tunable ENERGY:
#     energy(edge) = pickup_overhead + dt_min·(idle_power + load_power·payload_mass)
# This is the SoC-depletion quantity a (future) per-robot battery budget draws down.
# Defaults (overhead=0, idle=1, load=0) reproduce the pure-distance cost EXACTLY, so
# behavior is preserved until tuned. `payload_mass` is a HOOK (default 1.0): set
# `load_power>0` and pass a per-object mass proxy (e.g. bounding-box volume from
# get_base_geom(node, HyperrectangleKey())) so heavier cargo costs more — the
# differential that later drives battery wear-leveling. Module-level Ref, mirroring
# PLANNING_OBJECTIVE_WEIGHTS. See docs/llm_navigator_plan.md (battery extension).
# -----------------------------------------------------------------------------
# (한국어) EFFICIENCY 목적함수에 쓰는 가벼운 "에너지 모델" 계수들을 담은 전역 상자(위 가중치와 같은 패턴).
#   기본값(overhead=0, idle=1, load=0)이면 에너지 = 이동시간 그대로 = 순수 거리비용과 동일(동작 보존).
const ENERGY_MODEL = Ref((pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.0))
energy_model() = ENERGY_MODEL[]   # 현재 에너지 모델 계수 읽기
# 에너지 모델 계수 설정(키워드 전용 인자). pickup_overhead=집기 고정비용, idle_power=이동 기본소모, load_power=적재무게 계수.
function set_energy_model!(; pickup_overhead = 0.0, idle_power = 1.0, load_power = 0.0)
    ENERGY_MODEL[] = (pickup_overhead = Float64(pickup_overhead),
        idle_power = Float64(idle_power), load_power = Float64(load_power))
    return ENERGY_MODEL[]
end
"Per-edge transport ENERGY (SoC drain) = fixed handling overhead + travel×power, with optional payload weighting."
# (한국어) 엣지 하나의 운반 에너지 = 집기 고정비용 + 이동시간 × (기본소모 + 적재무게×무게계수).
#   payload_mass 는 훅(기본 1.0) — 무거운 화물일수록 비용이 커지게 하려면 무게값을 넘겨줌.
function edge_energy(dt_min; payload_mass = 1.0)
    e = ENERGY_MODEL[]
    return e.pickup_overhead + dt_min * (e.idle_power + e.load_power * payload_mass)
end

# Optional per-edge cost multiplier keyed on the schedule vertex an assignment edge LEAVES.
# Two composable sources, both default to identity (1.0) so edge_costs are byte-for-byte
# unchanged unless something opts in:
#
#  (A) AGENT_COST_BIAS — an explicit per-agent cost factor registry (TIER-2 soft re-spec). The
#      DSL's DeprioritizeAgent registers `agent => factor` here (via `deprioritize_agent!`); the
#      energy-aware re-solve then multiplies that robot's frontier edges by `factor`, routing
#      work away from it WITHOUT removing it (feasible set unchanged). SAFETY: `deprioritize_agent!`
#      CLAMPS factor to [1, MAX_AGENT_COST_BIAS] — never < 1 (can't incentivize a robot) and never
#      a blowup value (numerical safety). So the LLM cannot weaponize this knob.
#  (B) EDGE_COST_MULTIPLIER — an optional function (battery SoC bias), default `nothing` => 1.0.
#      navigator/battery.jl points it at a function returning > 1 for low-SoC robots' edges.
#
# Final multiplier = agent_bias(owner(v)) × battery_fn(sched,v). Kept here (not in battery.jl)
# so essential_tg_coponents stays self-contained — battery.jl / the respec layer are included later.
# (한국어) EDGE_COST_MULTIPLIER = (선택적) 배터리 SoC 배율 함수 상자. Ref{Any} 라 어떤 함수든/nothing 담을 수 있음.
#   기본 nothing → 배율 1.0. navigator/battery.jl 가 여기에 "SoC 낮은 로봇 엣지는 >1" 함수를 꽂음.
const EDGE_COST_MULTIPLIER = Ref{Any}(nothing)
const MAX_AGENT_COST_BIAS  = 1.0e3   # 로봇별 소프트 비용배율의 상한(수치 안전용 — 너무 큰 값 방지)
# 로봇ID → 비용배율 을 담는 전역 딕셔너리 상자. DSL 의 DeprioritizeAgent 가 여기에 "로봇=>배율"을 등록.
const AGENT_COST_BIAS      = Ref(Dict{AbstractID,Float64}())

agent_cost_bias(id) = get(AGENT_COST_BIAS[], id, 1.0)   # 로봇 id 의 배율 조회(없으면 기본 1.0). get(dict,key,기본값)
"Register/raise a soft cost bias on `id`'s assignment edges. Clamped to [1, MAX] (safety)."
# (한국어) 로봇 id 의 작업 배정 엣지에 소프트 비용배율을 등록/상향. clamp 로 [1, MAX] 범위에 가둠 —
#   1 미만(로봇을 오히려 우대) 불가, 폭주값 불가 → LLM 이 이 손잡이를 악용 못 하게 하는 안전장치.
function deprioritize_agent!(id::AbstractID, factor::Real)
    AGENT_COST_BIAS[][id] = clamp(Float64(factor), 1.0, MAX_AGENT_COST_BIAS)   # clamp(x, lo, hi) = lo~hi 로 자름
    return AGENT_COST_BIAS[][id]
end
"Drop all (or one) soft agent cost biases."
clear_agent_bias!() = (empty!(AGENT_COST_BIAS[]); nothing)              # 모든 로봇 배율 초기화(비움)
clear_agent_bias!(id::AbstractID) = (delete!(AGENT_COST_BIAS[], id); nothing)   # 특정 로봇 배율만 제거

# Robot/agent that OWNS the assignment edge leaving vertex `v` (the entity doing the task).
# (한국어) 정점 v 에서 나가는 배정 엣지를 "소유한" 로봇(그 작업을 하는 개체)의 id 를 찾음. 못 찾으면 nothing.
function _edge_owner_id(sched, v)
    try
        return entity(get_node_from_id(sched, get_vtx_id(sched, v))).id   # 노드의 개체(entity)에서 id 꺼내기
    catch
        return nothing   # 개체/ id 가 없는 노드면 nothing
    end
end

# (한국어) 정점 v 를 떠나는 엣지의 최종 비용배율 = 로봇별 소프트배율 × 배터리 배율. 둘 다 기본 1.0 이면 그대로 1.0.
function edge_cost_multiplier(sched, v)
    m = 1.0
    if !isempty(AGENT_COST_BIAS[])   # 등록된 소프트배율이 하나라도 있으면
        id = _edge_owner_id(sched, v)
        id === nothing || (m *= agent_cost_bias(id))   # `조건 || 식` = 조건이 거짓일 때만 식 실행. id 있으면 배율 곱함
    end
    EDGE_COST_MULTIPLIER[] === nothing || (m *= EDGE_COST_MULTIPLIER[](sched, v))   # 배터리 함수가 꽂혀 있으면 그 배율도 곱함
    return m
end

# SumOfMakeSpans 목적함수에 대한 식 생성. f::SumOfMakeSpans 로 디스패치(이 목적일 때만 이 메서드).
function get_objective_expr(milp, f::SumOfMakeSpans, model, sched, tF; edge_costs=nothing)
    terminal_vtxs = sched.terminal_vtxs   # 종단(프로젝트 머리) 정점들
    if isempty(terminal_vtxs)   # 비어 있으면
        @warn "sched.terminal_vtxs is empty. Using get_all_terminal_nodes(sched) instead"   # @warn : 경고 로그
        terminal_vtxs = get_all_terminal_nodes(sched)   # 대신 모든 종단 노드를 사용
    end
    @variable(model, T[1:length(terminal_vtxs)])   # 각 프로젝트의 완료시각을 담을 변수 T
    for (i, project_head) in enumerate(terminal_vtxs)
        for v in project_head   # 프로젝트 머리에 속한 정점들마다
            @constraint(model, T[i] >= tF[v])   # T[i] >= 그 정점 종료시각(최댓값 역할)
        end
    end
    # ② SPEED: weighted terminal completion (the ORIGINAL makespan objective).
    # (한국어) SPEED 항 = 원래의 makespan 목적. 각 종단정점 종료시각 tF[v] 에 가중치를 곱해 합함.
    speed_term = @expression(model, sum(map(v -> tF[v] * get(sched.weights, v, 1.0), terminal_vtxs)))
    # Multi-objective augmentation. Default weights (efficiency=0) return the speed
    # term unchanged, so existing behavior is byte-for-byte preserved.
    w = planning_objective_weights()   # 현재 다목적 가중치(speed/efficiency) 읽기
    w.efficiency == 0.0 && return speed_term   # 효율 가중치가 0 이면 원래 목적 그대로 반환(동작 보존)
    # ③ EFFICIENCY = energy / material handling distance: total transport cost of the
    #    CHOSEN assignment edges, Σ d(v,v2)·Xa[v,v2]. Linear over the assignment vars and
    #    ORTHOGONAL to makespan — parallelism cuts time without cutting distance, smarter
    #    assignment cuts distance without cutting time — UNLIKE flow time, which is just
    #    another time term and collapses into speed. d(v,v2) = the per-edge transport
    #    ENERGY captured at formulation (`edge_costs`, via `edge_energy`). (Robot
    #    utilization is a RATIO
    #    busy/(N·makespan) — kept as a reported metric, not an objective term.)
    Xa = milp.Xa
    # 엣지 비용 정보가 없으면 효율항을 못 만드므로 speed 항만(가중치 적용) 반환
    (edge_costs === nothing || isempty(edge_costs)) && return @expression(model, w.speed * speed_term)
    # ③ EFFICIENCY 항 = 선택된 배정 엣지들의 총 운반비용 Σ(비용 c · Xa). makespan 과 직교(병렬화로 시간은 줄어도 거리는 안 줄어듦).
    eff_term = @expression(model, sum(c * Xa[e[1], e[2]] for (e, c) in edge_costs))
    return @expression(model, w.speed * speed_term + w.efficiency * eff_term)   # 최종 목적 = speed 항 + efficiency 항(가중합)
end


abstract type AbstractGreedyAssignment <: TaskGraphsMILP end   # 탐욕적 배정 방식들의 추상 부모
abstract type GreedyCost end   # 탐욕 배정에서 쓰는 비용 기준들의 추상 부모
struct GreedyPathLengthCost <: GreedyCost end   # 경로 길이를 기준으로 하는 탐욕 비용
struct GreedyFinalTimeCost <: GreedyCost end    # 종료 시각을 기준으로
struct GreedyLowerBoundCost <: GreedyCost end   # 하한값을 기준으로

"""
    GreedyAssignment{C,M} <: TaskGraphsMILP

GreedyAssignment maintains three sets: The "satisfied set" `C`, the "required
incoming" set `Ai`, and the "available outgoing" set `Ao`.

At each step, the algorithm identifies the nodes `v1 ∈ Ai` and `v2 ∈ Ao` with
shortest "distance" (in the context of `OperatingSchedule`s, this distance
refers to the duration of `v1` if an edge `v1 → v2` is added) and adds an edge
between them. The distance corresponding to an ineligible edge is set to Inf.

After adding the edge, the algorithm sweeps through a topological ordering of
the vertices and updates `C`, `Ai`, and `Ao`. In order for `v` to be placed in
`C`, `v` must have enough incoming edges and all of `v`'s predecessors must
already be in `C`. In order to be added to `Ai`, `v` must have less than the
required number of incoming edges and all of `v`'s predecessors must
already be in `C`. In order for `v` to be added to `Ao`, `v` must have less than
the allowable number of outgoing edges, and must be in `C`.
"""
# {C,M,P} : 비용모델 C, 탐욕비용 M, 문제명세 P 의 타입을 매개변수로 받는 탐욕 배정 구조체.
@with_kw struct GreedyAssignment{C,M,P} <: AbstractGreedyAssignment
    schedule::OperatingSchedule = OperatingSchedule()   # 대상 스케줄
    problem_spec::P = ProblemSpec()                     # 문제명세
    cost_model::C = SumOfMakeSpans()                    # 비용모델
    greedy_cost::M = GreedyPathLengthCost()             # 탐욕 선택 기준
    t0::Vector{Int} = zeros(Int, nv(schedule)) # get_tF(schedule)   # 노드별 시작시각(기본 0). nv(schedule)=정점 수
end

# 탐욕 배정은 실제 솔버가 아니지만 JuMP 인터페이스를 흉내내도록 상태를 고정 반환. `::Type` 없이 ::Abstract... 만 = 타입만 보고 디스패치.
JuMP.termination_status(::AbstractGreedyAssignment) = MOI.OPTIMAL          # 항상 "최적" 상태로 보고
JuMP.primal_status(::AbstractGreedyAssignment) = MOI.FEASIBLE_POINT        # 항상 "실행가능 해 있음"으로 보고
get_assignment_matrix(model::AbstractGreedyAssignment) = adjacency_matrix(get_graph(model.schedule))   # 배정행렬 = 스케줄 그래프의 인접행렬

"""
    get_best_pair(Ao,Ai,cost_func,filt=(a,b)->true)

Return `argmin v ∈ Ao, v2 ∈ Ai, cost_func(v,v2) s.t. filt(v,v2) == true`
"""
# Ao(나가는 후보)와 Ai(들어오는 후보)에서 비용이 가장 작고 필터 통과하는 (v,v2) 쌍을 찾음.
# filt=(a,b)->true : 필터 함수 기본값(항상 통과). 람다를 기본 인자로 줌.
function get_best_pair(Ao, Ai, cost_func, filt=(a, b) -> true)
    cost = Inf   # 지금까지의 최소 비용(무한대로 시작)
    a = -1   # 최적 v(미발견 표시)
    b = -2   # 최적 v2
    for v in Ao
        for v2 in Ai
            c = cost_func(v, v2)   # 이 쌍의 비용 계산
            if c < cost && filt(v, v2)   # 더 작고 필터 통과하면
                cost = c   # 최소 갱신
                a = v
                b = v2
            end
        end
    end
    return a, b, cost   # 최적 쌍과 그 비용 반환
end

# 탐욕 배정 알고리즘 본체. 매 단계 가장 짧은 거리의 엣지를 추가하며 스케줄을 완성.
function greedy_assignment!(model)
    sched = model.schedule
    problem_spec = model.problem_spec
    cache = preprocess_project_schedule(sched, true)   # 전처리 결과 캐시(둘째 인자 true)
    C = Set{Int}() # Closed set (these nodes have enough predecessors)   # 닫힌 집합(선행 충분한 노드들). Set=집합(파이썬 set)
    Ai = Set{Int}() # Nodes that don't have enough incoming edges        # 들어오는 엣지가 부족한 노드들
    Ao = Set{Int}() # Nodes that can have more outgoing edges            # 나가는 엣지를 더 받을 수 있는 노드들
    update_greedy_sets!(model, sched, cache, Ai, Ao, C; frontier=get_all_root_nodes(sched))   # 루트 노드부터 세 집합 초기화
    D = construct_schedule_distance_matrix(sched, problem_spec)   # 노드 간 거리행렬
    while length(Ai) > 0   # 들어오는 엣지가 부족한 노드가 남아있는 동안
        new_edges = select_next_edges(model, D, Ao, Ai)   # 추가할 엣지(들) 선택
        for (v, v2) in new_edges
            setdiff!(Ao, v)   # setdiff!(집합, x) : 집합에서 x 제거(in-place). v 는 더 이상 나가는 후보 아님
            setdiff!(Ai, v2)  # v2 는 더 이상 들어오는 후보 아님
            # Ao[v] = false
            # Ai[v] = false
            add_edge!(sched, v, v2)   # 스케줄에 엣지 추가
            # @info "..."   # (디버깅 로그, 주석처리)
        end
        # `[e[1] for e in new_edges]` : 리스트 컴프리헨션(파이썬과 동일). 새 엣지들의 출발 노드 집합을 다음 frontier 로.
        update_greedy_sets!(model, sched, cache, Ai, Ao, C; frontier=Set{Int}([e[1] for e in new_edges]))   # 집합 갱신
        # update_greedy_sets_vector!(...)   # (대안 구현, 주석처리)
        update_greedy_cost_model!(model, new_edges)   # 비용 모델 갱신
    end
    set_leaf_operation_vtxs!(sched)   # 말단 연산 정점 설정
    propagate_valid_ids!(sched, problem_spec)   # 유효 ID 전파(로봇ID 등 채우기)
    model   # (return 생략 시 마지막 식이 반환값) model 반환
end
JuMP.optimize!(model::AbstractGreedyAssignment) = greedy_assignment!(model)   # optimize! 호출 시 탐욕 알고리즘 실행하도록 연결


# 스케줄 전체에 "유효 ID"(로봇ID 등)를 선후관계 따라 전파해 노드들을 갱신.
function propagate_valid_ids!(sched::OperatingSchedule, problem_spec)
    @assert(is_cyclic(sched) == false, "is_cyclic(sched)") # string(sparse(adj_matrix))   # 사이클 없어야 함
    # Propagate valid IDs through the schedule
    for v in topological_sort_by_dfs(sched)   # 위상정렬 순서로(선행→후속)
        n_id = get_vtx_id(sched, v)
        node = get_node_from_id(sched, n_id)
        for v2 in inneighbors(sched, v)   # 선행 노드들의 정보로
            node = align_with_predecessor(sched, node, get_node_from_vtx(sched, v2))   # 노드를 선행에 맞춰 갱신
        end
        for v2 in outneighbors(sched, v)   # 후속 노드들의 정보로
            node = align_with_successor(sched, node, get_node_from_vtx(sched, v2))   # 노드를 후속에 맞춰 갱신
        end
        path_spec = get_path_spec(sched, v)
        if path_spec.fixed   # 경로가 고정된 노드면
            replace_in_schedule!(sched, path_spec, node, n_id)   # 기존 path_spec 유지하며 노드 교체
        else
            replace_in_schedule!(sched, problem_spec, node, n_id)   # 아니면 새 path_spec 생성하며 교체
        end
    end
    return true
end


"""
    update_project_schedule!

Args:
- solver
- sched
- adj_matrix - adjacency_matrix encoding the edges that need to be added to
    the project schedule

Adds all required edges to the project graph and modifies all nodes to
reflect the appropriate valid IDs (e.g., `Action` nodes are populated with
the correct `RobotID`s)
Returns `false` if the new edges cause cycles in the project graph.
"""
# solver 인자를 포함한 버전: 실제로는 인자 없는 버전으로 위임.
function update_project_schedule!(solver, sched::OperatingSchedule, problem_spec, adj_matrix)
    mtx = adjacency_matrix(sched)   # (현재 미사용) 인접행렬
    val = update_project_schedule!(sched, problem_spec, adj_matrix)   # solver 없는 버전 호출
    val   # 결과 반환
end
# 인접행렬에 따라 스케줄 그래프의 엣지를 새로 구성하고 노드 ID 를 갱신. 사이클이 생기면 false.
function update_project_schedule!(sched::OperatingSchedule, problem_spec, adj_matrix)
    # Add all new edges to project sched
    G = get_graph(sched)
    # remove existing edges first, so that there is no carryover between consecutive MILP iterations   # 이전 엣지 모두 제거(이월 방지)
    for e in collect(edges(G))
        rem_edge!(G, e)   # 엣지 삭제
    end
    # add all edges encoded by adjacency matrix   # 인접행렬이 1 인 곳마다 엣지 추가
    for v in Graphs.vertices(G)
        for v2 in Graphs.vertices(G)
            if adj_matrix[v, v2] >= 1
                add_edge!(G, v, v2)   # v→v2 엣지 추가
            end
        end
    end
    try
        propagate_valid_ids!(sched, problem_spec)   # ID 전파
        @assert validate(sched)   # 스케줄 유효성 검증
    catch e
        if isa(e, AssertionError)   # 검증 실패면
            showerror(stdout, e, catch_backtrace())   # 에러 표시
        else
            rethrow(e)   # 다른 예외는 다시 던짐
        end
        return false   # 실패 반환(사이클/검증 실패)
    end
    process_schedule!(sched)   # 시각·여유시간 재계산
    return true
end

"""
    update_project_schedule!(solver,milp_model::M,sched,problem_spec,
        adj_matrix) where {M<:TaskGraphsMILP}

Args:
- milp_model <: TaskGraphsMILP
- sched::OperatingSchedule
- problem_spec::ProblemSpec
- adj_matrix : an adjacency_matrix or (in the case where
    `milp_model::AssignmentMILP`), an assignment matrix

Adds all required edges to the schedule graph and modifies all nodes to
reflect the appropriate valid IDs (e.g., `Action` nodes are populated with
the correct `RobotID`s)
Returns `false` if the new edges cause cycles in the project graph.
"""
# 일반 MILP 모델용: 모델에서 인접행렬을 얻어 위 버전으로 위임. adj_matrix 기본값은 모델의 배정행렬.
function update_project_schedule!(solver, model::TaskGraphsMILP, sched, prob_spec,
    adj_matrix=get_assignment_matrix(model),
)
    update_project_schedule!(solver, sched, prob_spec, adj_matrix)
end
# AssignmentMILP 전용: 배정행렬을 먼저 인접행렬로 변환한 뒤 위임(다중 디스패치로 이 버전이 우선 선택됨).
function update_project_schedule!(solver, model::AssignmentMILP, sched, prob_spec,
    assignment_matrix=get_assignment_matrix(model),
)
    adj_matrix = adj_mat_from_assignment_mat(model, sched, assignment_matrix)   # 배정행렬 → 인접행렬
    update_project_schedule!(solver, sched, prob_spec, adj_matrix)
end


#################################################

# @with_kw_noshow : @with_kw 와 같지만 자동 show(출력) 메서드는 안 만듦(아래에서 직접 정의하므로).
# 이 구조체 = 계획 진행상황 캐시. 완료/활성 노드 집합과 우선순위 큐를 가짐.
@with_kw_noshow struct PlanningCache
    closed_set::Set{Int} = Set{Int}()    # nodes that are completed   # 완료된 노드 집합
    active_set::Set{Int} = Set{Int}()    # active nodes               # 현재 활성 노드 집합
    # PriorityQueue{키,우선순위} : 우선순위 큐. 여기 우선순위는 (Int, Float64) 튜플(계획필요여부, 여유시간).
    node_queue::PriorityQueue{Int,Tuple{Int,Float64}} = PriorityQueue{Int,Tuple{Int,Float64}}() # active nodes prioritized by slack  # 여유시간 우선 큐
end

# 캐시 내용을 보기 좋게 들여쓰기 출력하는 함수. io::IO 는 출력 대상 스트림(파이썬 file 객체 비슷).
function sprint_cache(io::IO, cache::PlanningCache; label_pad=14, pad=5)
    lpad(str) = sprint_padded(str; pad=label_pad, leftaligned=true)    # 왼쪽 정렬 패딩 헬퍼(지역함수)
    rpad(str) = sprint_padded(str; pad=label_pad, leftaligned=false)   # 오른쪽 정렬 패딩 헬퍼
    spad(str; kwargs...) = sprint_padded_list(str; pad=pad, leftaligned=false, kwargs...)   # 목록 패딩 헬퍼
    print(io, "PlanningCache:", "\n")   # 헤더 출력("\n"=줄바꿈)
    print(io, "\t", lpad("closed_set:  "), cache.closed_set, "\n")   # 완료 집합 출력("\t"=탭)
    print(io, "\t", lpad("active_set:  "), cache.active_set, "\n")   # 활성 집합 출력
    print(io, "\t", lpad("node_queue:  "), cache.node_queue, "\n")   # 큐 출력
end

# Base.show : 객체를 출력할 때 호출되는 표준 함수에 PlanningCache 용 동작 추가(파이썬 __repr__/__str__ 비슷).
function Base.show(io::IO, cache::PlanningCache)
    sprint_cache(io, cache)   # 위 함수로 위임
end

# 노드 v 의 큐 우선순위 계산: (경로계획 필요여부 0/1, 최소 여유시간). 계획 필요한 것/여유 적은 것이 우선되도록.
function isps_queue_cost(sched::OperatingSchedule, v::Int)
    path_spec = get_path_spec(sched, v)
    # `init=Inf`: a node whose slack vector is EMPTY (no downstream deadline / a degenerate post-
    # line-stop schedule) has no urgency -> Inf (least urgent). Without init, `minimum([])` THROWS
    # and crashes update_planning_cache! after an OOD fallback (observed 2026-07-07).
    return (Int(path_spec.plan_path), minimum(get_slack(sched, v); init = Inf))   # (Bool→Int, 여유 최소값)
end

# 계획 캐시 초기화: 루트 노드들을 활성 집합과 큐에 넣음.
function initialize_planning_cache(sched::OperatingSchedule)
    cache = PlanningCache()
    for v in get_all_root_nodes(sched)
        push!(cache.active_set, v)   # push!(집합, x) : 집합에 x 추가(파이썬 set.add). 활성 집합에 추가
        enqueue!(cache.node_queue, v => isps_queue_cost(sched, v)) # need to store slack   # 큐에 (v => 우선순위) 넣기
    end
    cache
end

"""
    `reset_cache!(cache,sched)`

    Resets the cache so that a solution can be repaired (otherwise calling
    low_level_search!() will return immediately because the cache says it's
    complete)
"""
# 캐시를 초기 상태로 되돌림(해를 다시 수리할 수 있게). 안 그러면 "이미 완료됨"으로 판단해 탐색이 바로 끝남.
function reset_cache!(cache::PlanningCache, sched::OperatingSchedule)
    process_schedule!(sched)   # 시각/여유 재계산
    empty!(cache.closed_set)   # empty!(컬렉션) : 비움(파이썬 .clear()). 완료 집합 비우기
    empty!(cache.active_set)   # 활성 집합 비우기
    empty!(cache.node_queue)   # 큐 비우기
    for v in Graphs.vertices(get_graph(sched))
        if is_root_node(get_graph(sched), v)   # 루트 노드면 다시 활성으로
            push!(cache.active_set, v)
            enqueue!(cache.node_queue, v => isps_queue_cost(sched, v))
        end
    end
    cache
end


"""
update_planning_cache!

Update cache continually. After a call to this function, the start and end times
of all schedule nodes will be updated to reflect the progress of active schedule
nodes (i.e., if a robot had not yet completed a GO task, the predicted final
time for that task will be updated based on the robot's current state and
distance to the goal).
All active nodes that don't require planning will be automatically marked as
complete.
"""
# 노드 v 가 완료되었을 때 캐시를 갱신: v 를 완료처리하고, 선행이 모두 끝난 후속들을 활성화, 시각/큐 갱신.
function update_planning_cache!(solver, sched::OperatingSchedule, cache::PlanningCache, v::Int, t=-1)
    active_set = cache.active_set   # 지역 별칭(같은 객체를 가리킴 — 수정하면 캐시에 반영됨)
    closed_set = cache.closed_set
    node_queue = cache.node_queue
    Δt = t - get_tF(sched, v)   # 실제 완료시각 t 와 예측 종료시각의 차이
    if Δt > 0   # 예측보다 늦게 끝났으면
        set_tF!(sched, v, t)   # 종료시각을 실제값으로 갱신
        process_schedule!(sched)   # 전체 시각/여유 재계산
    end
    # update closed_set
    activated_vtxs = Int[]   # 이번에 새로 활성화된 정점 모음
    push!(closed_set, v)   # v 를 완료 집합에 추가
    # update active_set
    setdiff!(active_set, v)   # v 를 활성 집합에서 제거
    for v2 in outneighbors(sched, v)   # v 의 후속들 중
        active = true
        for v1 in inneighbors(sched, v2)   # 후속 v2 의 모든 선행이
            if !(v1 in closed_set)   # 하나라도 아직 미완료면
                active = false   # v2 는 아직 활성화 불가
                break
            end
        end
        if active   # 모든 선행 완료 시
            push!(activated_vtxs, v2)
            push!(active_set, v2)               # add to active set   # 활성 집합에 추가
        end
    end
    # update priority queue   # 활성 노드들의 큐 우선순위 갱신
    for v2 in active_set
        node_queue[v2] = isps_queue_cost(sched, v2)   # 딕셔너리처럼 큐[키]=우선순위 로 갱신
    end
    return cache
end

#######################################

# global : "전역변수" 선언. 모듈 어디서나 공유되는 변수. 기본 솔버와 그 속성들을 전역으로 보관.
global MILP_OPTIMIZER = nothing   # 기본 MILP 솔버(처음엔 미설정)
# Dict{Union{String,MOI...}, Any} : 키는 문자열 또는 솔버속성 객체, 값은 무엇이든(Any). 솔버 옵션 저장용.
global DEFAULT_MILP_OPTIMIZER_ATTRIBUTES = Dict{Union{String,MOI.AbstractOptimizerAttribute},Any}()   # 기본 솔버 속성들

"""
    default_milp_optimizer()

Returns the black box optimizer to be use when formulating JuMP models.
"""
default_milp_optimizer() = MILP_OPTIMIZER   # 현재 설정된 기본 솔버를 돌려줌

"""
    set_default_milp_optimizer!(optimizer)

Set the black box optimizer to be use when formulating JuMP models.
"""
function set_default_milp_optimizer!(optimizer)
    global MILP_OPTIMIZER = optimizer   # 함수 안에서 전역변수를 바꾸려면 global 키워드 필요(파이썬과 동일)
end

"""
    default_milp_optimizer_attributes()

Return a dictionary of default optimizer attributes.
"""
default_milp_optimizer_attributes() = DEFAULT_MILP_OPTIMIZER_ATTRIBUTES   # 기본 솔버 속성 딕셔너리를 돌려줌

"""
    set_default_milp_optimizer_attributes!(vals)

Set default optimizer attributes.
e.g. `set_default_milp_optimizer_attributes!(Dict("PreSolve"=>-1))`
"""
# Pair 와 가변인자 pairs... 를 받아 재귀적으로 하나씩 추가(가변 개수의 속성 설정). "키=>값" 쌍들을 받음.
function set_default_milp_optimizer_attributes!(pair::Pair, pairs...)
    push!(DEFAULT_MILP_OPTIMIZER_ATTRIBUTES, pair)   # 속성 하나 추가
    set_default_milp_optimizer_attributes!(pairs...)   # 나머지 쌍들에 대해 재귀 호출
end
set_default_milp_optimizer_attributes!(d::Dict) = set_default_milp_optimizer_attributes!(d...)   # 딕셔너리면 펼쳐서(...) 위 버전 호출
set_default_milp_optimizer_attributes!() = nothing   # 인자 없으면(재귀 종료) 아무것도 안 함

"""
    clear_default_milp_optimizer_attributes!()

Clear the default optimizer attributes.
"""
function clear_default_milp_optimizer_attributes!()
    empty!(DEFAULT_MILP_OPTIMIZER_ATTRIBUTES)   # 속성 딕셔너리 비우기
end

########################

"""
    PathNode{S,A}

Includes current state `s`, action `a`, next state `sp`
"""
# {S,A} : 상태 타입 S, 행동 타입 A 를 매개변수로 받음. 경로의 한 단계(현재상태 → 행동 → 다음상태)를 담음.
# `S()` : 타입 S 의 기본 생성자 호출(기본값 인스턴스). S 가 무엇이든 그 빈 객체를 만듦.
@with_kw struct PathNode{S,A}
    s::S = S() # state        # 현재 상태
    a::A = A() # action       # 취한 행동
    sp::S = S() # next state  # 다음 상태
end
"""
    get_s

Get the first state in a `PathNode`.
"""
get_s(p::P) where {P<:PathNode} = p.s    # 현재 상태 읽기
"""
    get_a

Get the action in a `PathNode`.
"""
get_a(p::P) where {P<:PathNode} = p.a    # 행동 읽기
"""
    get_sp

Get the next state in a `PathNode`.
"""
get_sp(p::P) where {P<:PathNode} = p.sp  # 다음 상태 읽기
# PathNode{S,A} 패턴매칭으로 타입 매개변수 S, A 를 꺼내 반환 — 이 노드의 상태/행동 "타입"이 무엇인지 알려줌.
state_type(p::PathNode{S,A}) where {S,A} = S   # 상태 타입 S 반환
action_type(p::PathNode{S,A}) where {S,A} = A  # 행동 타입 A 반환
# Base.string : 표준 string 함수 확장. 경로노드를 "상태 -- 행동 -- 다음상태" 문자열로. $(...) 는 식 보간.
Base.string(p::PathNode) = "$(string(get_s(p))) -- $(string(get_a(p))) -- $(string(get_sp(p)))"

# {P1<:PathNode,P2<:PathNode} : 두 경로노드 타입을 매개변수로. 두 에이전트(로봇)의 충돌 정보를 담는 구조체.
@with_kw struct Conflict{P1<:PathNode,P2<:PathNode}
    conflict_type::Symbol = :NullConflict   # 충돌 종류(심볼). 기본은 "충돌 없음"
    agent1_id::Int = -1   # 충돌한 첫 에이전트 ID(-1=미정)
    agent2_id::Int = -1   # 둘째 에이전트 ID
    node1::P1 = P1()      # 첫 에이전트의 경로노드
    node2::P2 = P2()      # 둘째 에이전트의 경로노드
    t::Int = -1           # 충돌 발생 시각
end

""" Checks if a conflict is valid """
# 충돌이 유효한지 검사: (상태충돌 또는 행동충돌) 이고, 두 에이전트가 서로 다르며, 둘 다 ID 가 유효(-1 아님)할 때.
# `(... )` 안에 && 로 여러 줄을 이어 한 불리언 식으로 만듦. 여러 줄로 나눠도 하나의 식.
is_valid(c::C) where {C<:Conflict} = ((is_state_conflict(c) || is_action_conflict(c))   # 상태 또는 행동 충돌이고
                                      && (agent1_id(c) != agent2_id(c))   # 두 에이전트가 다르고
                                      && (agent1_id(c) != -1)              # 첫 ID 유효
                                      && (agent2_id(c) != -1))             # 둘째 ID 유효
