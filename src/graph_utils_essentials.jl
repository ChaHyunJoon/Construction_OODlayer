
# ============================================================================
#  이 파일은 GraphUtils 라이브러리에서 필요한 핵심 부분만 떼어 붙여넣은 것 —
#  이 프로젝트(다중 로봇 건설 TAMP 시뮬레이터)의 "그래프·트리 자료구조 기반".
#  주요 내용:
#   · ID 체계(AbstractID 계열): 로봇/장소/동작/작업/꼭짓점을 정수 번호로 구분하는 타입들.
#   · 캐시(CachedElement)와 캐시된 트리노드(CachedTreeNode): 값을 저장하고 "최신인지" 관리.
#   · 커스텀 그래프(AbstractCustomGraph 계열): Graphs.jl 위에 노드/엣지에 데이터를 붙인 그래프.
#   · 트리/그래프 순회(DFS, BFS 반복자), 노드 추가·삭제·교체, 이웃 규칙 검증 등.
#  이 프로젝트에서의 역할: 작업 스케줄·조립 트리 등을 담는 그래프 골격을 제공하는 최하위 유틸.
#  Julia 문법 참고:
#   · function f(x::T) ... end : x 가 타입 T 일 때만 적용되는 메서드(다중 디스패치).
#   · 같은 이름 함수를 인자 타입/개수만 바꿔 여러 번 정의 = "경우마다 다른 동작"(파이썬엔 없음).
#   · `::Type{T}` : 값이 아니라 "타입 그 자체"를 인자로 받음(예: get_unique_id(ObjectID)).
#   · `:이름` = 심볼(코드상의 이름 자체를 값으로), `@eval`/`@매크로` = 코드로 코드를 생성(메타프로그래밍).
#   · abstract type = 인스턴스 못 만드는 분류용 상위 타입, `<:` = "~의 하위 타입".
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
#   · (f(v) for v in it) = 게으른 제너레이터(파이썬과 동일 문법).
# ============================================================================

# Dict{KeyType,ValType}() : 빈 딕셔너리(파이썬 dict) 생성. 키 타입과 값 타입을 미리 지정.
# DataType : "타입 그 자체"를 값으로 담는 타입(파이썬에서 클래스 객체를 딕셔너리 키로 쓰는 것과 비슷).
VALID_ID_COUNTERS = Dict{DataType,Int}()    # 타입별로 "다음에 발급할 유효 ID 번호"를 1부터 세는 카운터
INVALID_ID_COUNTERS = Dict{DataType,Int}()  # 타입별로 "무효(placeholder) ID 번호"를 -1부터 거꾸로 세는 카운터

# abstract type ... end : "추상 타입" 선언. 인스턴스를 직접 만들 수 없고, 하위 타입들을 묶는 분류용 상위 타입(파이썬 ABC 비슷).
abstract type AbstractRobotType end                 # 모든 로봇 종류의 최상위 분류 타입
# struct Name <: Super end : 필드가 하나도 없는 빈 구조체(싱글턴 표식 타입). `<:` 로 상위 타입에 속함을 표시.
struct DeliveryBot <: AbstractRobotType end         # 배달 로봇 종류(필드 없는 표식용 타입)
# const : 값이 안 바뀌는 상수 이름. 여기선 DeliveryBot 타입에 별칭을 붙임.
const DefaultRobotType = DeliveryBot                # 기본 로봇 종류 = 배달 로봇

abstract type AbstractID end                        # 모든 ID 종류의 최상위 추상 타입

"""
    struct TemplatedID{T} <: AbstractID

A simple way to dispatch by Node type.
"""
# {T} : 타입 매개변수(제네릭). T 자리에 어떤 타입이든 끼워 넣어 "T로 구분되는 ID"를 만듦.
#       같은 정수라도 TemplatedID{NodeA} 와 TemplatedID{NodeB} 는 서로 다른 타입 → 다중 디스패치로 구분 가능.
struct TemplatedID{T} <: AbstractID
    id::Int             # 실제 식별번호(정수)
end

# @with_kw : 키워드 생성자 자동 생성 매크로. ObjectID(id=5) 처럼 부르거나 인자 없이 ObjectID() 도 가능(아래 기본값 사용).
@with_kw struct ObjectID <: AbstractID
    id::Int = -1        # 식별번호. 기본값 -1 은 "아직 미지정(무효)"을 뜻함
end

# {R<:AbstractRobotType} : 타입 매개변수 R 에 "AbstractRobotType 의 하위 타입"이라는 제약을 건 제네릭.
@with_kw struct BotID{R<:AbstractRobotType} <: AbstractID
    id::Int = -1        # 로봇 ID 번호. 기본값 -1 은 미지정
end

const RobotID = BotID{DeliveryBot}                  # 배달로봇용 ID 타입에 짧은 별칭

@with_kw struct LocationID <: AbstractID            # 장소를 가리키는 ID 타입
    id::Int = -1        # 장소 ID 번호(기본값 -1 = 미지정)
end

@with_kw struct ActionID <: AbstractID              # 동작(action)을 가리키는 ID 타입
    id::Int = -1        # 동작 ID 번호(기본값 -1 = 미지정)
end

@with_kw struct OperationID <: AbstractID           # 작업(operation)을 가리키는 ID 타입
    id::Int = -1        # 작업 ID 번호(기본값 -1 = 미지정)
end

"""
	AgentID
Special helper for identifying agents.
"""
@with_kw struct AgentID <: AbstractID               # 에이전트(로봇 등 행위자)를 가리키는 ID 타입
    id::Int = -1        # 에이전트 ID 번호(기본값 -1 = 미지정)
end

"""
	VtxID
Special helper for identifying schedule vertices.
"""
@with_kw struct VtxID <: AbstractID                 # 스케줄 그래프의 꼭짓점(vertex)을 가리키는 ID 타입
    id::Int = -1        # 꼭짓점 ID 번호(기본값 -1 = 미지정)
end

# Base.함수 = ... : 기존 표준 함수(Base 모듈)에 "이 타입일 때의 동작"을 추가(파이썬의 __메서드__ 오버라이드 비슷).
# where {A<:AbstractID} : 위에서 쓴 타입 매개변수 A 의 제약을 명시. id::A 는 "어떤 AbstractID 하위 타입이든"을 받는다는 뜻.
Base.summary(id::A) where {A<:AbstractID} = string(string(A), "(", get_id(id), ")")  # 요약 문자열: 예) "ObjectID(5)"
Base.string(id::A) where {A<:AbstractID} = summary(id)                                # 문자열 변환도 위 summary 와 동일하게

# mutable struct : 필드 값을 나중에 바꿀 수 있는 구조체(일반 struct 는 생성 후 값 변경 불가).
mutable struct Toggle
    status::Bool        # 켜짐/꺼짐 상태(참/거짓)
end

# val=true : 기본값이 있는 인자(파이썬 def f(val=True) 와 동일). 함수 이름 끝 `!` 는 인자를 직접 수정함을 표시.
function set_toggle_status!(t::Toggle, val=true)
    t.status = val      # 토글의 상태를 val 로 바꿈(in-place 수정)
end

get_toggle_status(t::Toggle) = copy(t.status)       # 토글 상태값의 복사본을 반환(원본 보호)

mutable struct Counter                              # 정수 카운터를 담는 변경가능 구조체
    status::Int         # 현재 카운트 값
end

function set_counter_status!(t::Counter, val::Int)  # 카운터 값을 val 로 설정(in-place)
    t.status = val      # 카운터의 상태를 val 로 바꿈
end

get_counter_status(t::Counter) = copy(t.status)     # 카운터 값의 복사본을 반환

"""
    CachedElement{E}

A mutable container for caching things.
"""
# {E} : 담을 값의 타입을 매개변수로 받는 제네릭 컨테이너. 어떤 타입 E 든 캐시로 감쌀 수 있음.
mutable struct CachedElement{E}
    element::E              # 캐시에 담긴 실제 값
    is_up_to_date::Bool     # 이 값이 최신인지(다시 계산 안 해도 되는지) 표시하는 플래그
    timestamp::Float64      # 마지막으로 갱신된 시각(논리 시계 값)
end

# [한글 요약] 아래 영어 설명 = 캐시 타임스탬프를 실제 시계(time()) 대신 "1씩 증가하는 논리 시계"로 쓰는 이유.
#            실제 시계는 해상도가 낮아(특히 Windows) 같은 순간에 만든 노드들이 같은 값을 갖고,
#            그러면 부모보다 최신인지 판정하는 `>` 비교가 어긋나 트리 전파가 무한히 위로 올라가(스택오버플로) 버림.
#            단조 증가 카운터를 쓰면 "나중 갱신 = 항상 더 큰 값"이 보장돼 캐시 판정이 정확·결정적이 됨.
# Monotonic logical clock for cache timestamps.
#
# Cache validity is decided by `cached_node_up_to_date` via the comparison
# `time_stamp(n) > time_stamp(get_parent(n))`. Using wall-clock `time()` for this
# is unsafe: on coarse-resolution clocks (notably Windows, ~ms or worse) many
# nodes created/updated in the same tick receive *equal* timestamps, so the
# strict `>` check reports valid nodes as stale. That sends transform-tree
# propagation (`get_cached_value!` -> `propagate_forward!`) walking up the parent
# chain instead of stopping at an up-to-date ancestor, which manifests as a
# nondeterministic StackOverflow / runaway when the parent chain contains a loop.
# A strictly-increasing logical counter guarantees a later update always compares
# greater, making the cache check correct and deterministic across runs.
# Ref{Float64}(0.0) : 하나의 값을 담는 "가변 상자"(포인터 비슷). const 라도 상자 안의 값은 바꿀 수 있음.
#                     상자 안 값에 접근/수정할 땐 대괄호 []를 붙임(아래 [] 참고).
const _CACHE_TIMESTAMP_COUNTER = Ref{Float64}(0.0)  # 캐시 타임스탬프용 단조 증가 논리 시계(0부터 시작)
function _next_cache_timestamp()                    # 시계를 1 올리고 새 타임스탬프를 반환하는 함수
    _CACHE_TIMESTAMP_COUNTER[] += 1.0               # 상자 안 값을 1 증가([] 로 상자 내부 접근)
    return _CACHE_TIMESTAMP_COUNTER[]               # 증가된 현재 값을 반환
end

# 같은 이름에 인자 개수만 다른 정의 = 다중 디스패치(파이썬에는 없음). 인자 수에 따라 다른 생성자가 호출됨.
CachedElement(element, flag) = CachedElement(element, flag, _next_cache_timestamp())  # 타임스탬프는 자동 발급해 3-필드 생성자 호출
CachedElement(element) = CachedElement(element, false)                                 # 플래그 생략 시 false(최신 아님)로 간주

"""
    transform_iter(f, it) = Base.Iterators.accumulate((a,b)->f(b), it)

Transform iterator that applies `f` to each element of `it`.
"""
# (f(v) for v in it) : "제너레이터 표현식"(파이썬과 동일 문법). it 의 각 원소 v 에 함수 f 를 적용해 게으르게(lazy) 만들어냄.
transform_iter(f, it) = (f(v) for v in it)          # it 의 모든 원소에 f 를 적용하는 게으른 이터레이터 반환

"""
    is_root_node(G, v)

Inputs:
    `G` - graph
    `v` - query vertex

Outputs:
    returns `true` if vertex v has no inneighbors
"""
# indegree(G,v) : 꼭짓점 v 로 "들어오는" 엣지 수. 0 이면 부모가 없는 뿌리(root) 노드.
is_root_node(G, v) = indegree(G, v) == 0            # 들어오는 엣지가 없으면 true(뿌리 노드)


"""
is_terminal_node(G, v)

Inputs:
    `G` - graph
    `v` - query vertex

Outputs:
    returns `true` if vertex v has no inneighbors
"""
# outdegree(G,v) : 꼭짓점 v 에서 "나가는" 엣지 수. 0 이면 자식이 없는 끝(terminal/leaf) 노드.
is_terminal_node(G, v) = outdegree(G, v) == 0       # 나가는 엣지가 없으면 true(말단 노드)

"""
    get_all_root_nodes
"""
function get_all_root_nodes(G)
    root_nodes = Set{Int}()                         # 뿌리 노드 번호를 담을 빈 정수 집합(파이썬 set)
    for v in Graphs.vertices(G)                     # 그래프의 모든 꼭짓점 v 를 순회
        if is_root_node(G, v)                       # v 가 뿌리 노드라면
            push!(root_nodes, v)                    # 집합에 v 추가(push! 는 in-place 추가)
        end
    end
    return root_nodes                               # 모든 뿌리 노드 집합 반환
end

"""
    get_all_terminal_nodes
"""
function get_all_terminal_nodes(G)
    root_nodes = Set{Int}()                         # 말단 노드 번호를 담을 빈 정수 집합(이름은 root지만 말단을 모음)
    for v in Graphs.vertices(G)                     # 모든 꼭짓점 순회
        if is_terminal_node(G, v)                   # v 가 말단 노드라면
            push!(root_nodes, v)                    # 집합에 추가
        end
    end
    return root_nodes                               # 모든 말단 노드 집합 반환
end


"""
    get_element(n::CachedElement)

Retrieve the element stored in n.
"""
get_element(n::CachedElement) = n.element           # 캐시에 담긴 실제 값(element 필드)을 반환

"""
    is_up_to_date(n::CachedElement)

Check if the n is up to date.
"""
is_up_to_date(n::CachedElement) = n.is_up_to_date   # 최신 여부 플래그를 반환

"""
    time_stamp(n::CachedElement)

Return the time_stamp at which n was last modified.
"""
time_stamp(n::CachedElement) = n.timestamp          # 마지막 갱신 타임스탬프를 반환

"""
    set_up_to_date!(n::CachedElement,val::Bool=true)

Set the time stamp of n.
"""
function set_up_to_date!(n::CachedElement, val::Bool=true)  # 최신 여부 플래그를 설정(기본값 true)

    n.is_up_to_date = val                           # 플래그를 val 로 변경
end
"""
    set_element!(n::CachedElement,g)

Set the element stored in n. Does NOT set the `is_up_to_date` flag.
"""
function set_element!(n::CachedElement, g)          # 캐시의 값을 g 로 교체(최신 플래그는 안 건드림)
    n.element = g                                   # element 필드를 g 로 변경
end
"""
    set_time_stamp!(n::CachedElement,t=time())

Set the time stamp of n.
"""
function set_time_stamp!(n::CachedElement, t=_next_cache_timestamp())  # 타임스탬프 설정(기본값은 다음 논리 시계)
    n.timestamp = t                                 # timestamp 필드를 t 로 변경
end
"""
    update_element!(n::CachedElement,g)

Set the element of n to g, update the `is_up_to_date` flag and the time stamp.
"""
function update_element!(n::CachedElement, g)       # 값 교체 + 최신표시 + 타임스탬프 갱신을 한 번에
    set_element!(n, g)                              # 값을 g 로 교체
    set_up_to_date!(n, true)                        # 최신 상태로 표시
    set_time_stamp!(n)                              # 타임스탬프를 현재 논리시계로 갱신
    return g                                        # 새로 넣은 값 g 를 반환
end

"""
    Base.copy(e::CachedElement)

Shares the e.element, since it doesn't need to be replaced until `set_element!`
is called. Copies `e.is_up_to_date` to preserve the cache state.
"""
# Base.copy 확장: CachedElement 를 복사. element 는 공유(나중에 set_element! 전까지 바꿀 필요 없음), 플래그는 복사.
Base.copy(e::CachedElement) = CachedElement(e.element, copy(is_up_to_date(e)), _next_cache_timestamp())  # 캐시 원소 복사본 생성

# Base.convert 확장: ::Type{...} 는 "값 없이 타입 자체"를 인자로 받는다는 뜻. 다른 타입 매개변수 T 의 CachedElement 로 변환.
Base.convert(::Type{CachedElement{T}}, e::CachedElement) where {T} = CachedElement{T}(get_element(e), is_up_to_date(e), _next_cache_timestamp())  # T 타입 캐시로 변환

# [:이름, :이름] : 콜론(:)이 붙은 심볼(Symbol)들의 배열. 심볼은 "코드상의 이름 자체"를 값으로 다루는 것(파이썬에 정확한 대응 없음).
const cached_element_accessor_interface = [:is_up_to_date, :time_stamp]  # 캐시 읽기(접근자) 함수 이름 목록
const cached_element_mutator_interface = [:update_element!, :set_time_stamp!, :set_element!, :set_up_to_date!]  # 캐시 수정(변경자) 함수 이름 목록

# SMatrix{3,3}(...) : 크기 3x3 고정 정적 행렬 생성. 아래 배열은 벡터 x 의 "외적 연산을 행렬로 표현"한 반대칭 행렬.
cross_product_operator(x) = SMatrix{3,3}(           # 3x3 고정크기 행렬을 만들어 반환
    [0.0 -x[3] x[2]                                 # 1행: x 와의 외적을 만드는 반대칭 행렬 성분
        x[3] 0.0 -x[1]                              # 2행
        -x[2] x[1] 0.0]                             # 3행
)

# 2π 는 줄리아에서 바로 쓸 수 있는 원주율*2 (유니코드 π). mod(a,b)=나머지(파이썬 a % b).
wrap_to_2pi(θ) = mod(θ, 2π)                         # 각도 θ 를 [0, 2π) 범위로 감싸서 반환

"""

    wrap_to_pi(θ₀)

wraps the angle θ₀ to a value in (-π,π]
"""
# θ₀ 처럼 아래첨자가 붙은 이름도 그냥 변수명(유니코드 식별자). 파이썬의 theta0 같은 것.
function wrap_to_pi(θ₀)
    θ = wrap_to_2pi(θ₀)                             # 먼저 [0, 2π) 로 감싼 뒤
    if θ > π                                        # π 보다 크면(즉 절반 넘었으면)
        θ = θ - 2π                                  # 2π 를 빼서 음수 쪽으로 옮김
    elseif θ <= -π                                  # -π 이하이면
        θ += 2π                                     # 2π 를 더해서 범위 안으로(θ = θ + 2π 축약)
    end
    return θ                                        # (-π, π] 범위의 각도 반환
end

"""
    wrap_idx(n,idx)

Wrap index to a one-dimensional array of length `n`
"""
# 줄리아 배열 인덱스는 1부터 시작. idx 가 n 을 넘거나 0 이하라도 1..n 안으로 순환시키는 계산.
wrap_idx(n,idx) = mod(idx-1,n)+1                    # idx 를 길이 n 의 1기반 순환 인덱스로 변환

"""
    wrap_get

Index into array `a` by first wrapping the indices `idx`.
"""
# where {R,N,A<:AbstractArray{R,N}} : a 는 "원소타입 R, 차원수 N 인 배열"이라는 제약. R,N 을 본문에서 활용.
function wrap_get(a::A,idxs) where {R,N,A<:AbstractArray{R,N}}
    # map(f, 1:N) : 1..N 각 차원 i 마다 그 차원 크기에 맞춰 인덱스를 감쌈. 끝의 `...`는 결과 배열을 개별 인덱스로 펼침(파이썬 *args).
    a[map(i->wrap_idx(size(a,i),idxs[i]),1:N)...]   # 각 차원 인덱스를 순환시킨 뒤 그 위치의 원소를 꺼냄
end

# ::Type{T} ... where {T} : 값이 아니라 "타입 T 자체"를 인자로 받음. get_unique_id(ObjectID) 처럼 타입을 넘겨 호출.
function get_unique_id(::Type{T}) where {T}
    global VALID_ID_COUNTERS                        # 전역 카운터 딕셔너리를 함수 안에서 쓰겠다고 선언
    id = get!(VALID_ID_COUNTERS, T, 1)              # T 키가 있으면 그 값, 없으면 1 을 넣고 1 을 반환
    VALID_ID_COUNTERS[T] += 1                        # 다음 발급을 위해 카운터 1 증가
    return T(id)                                    # T(id) 로 해당 타입의 ID 객체를 만들어 반환
end
function reset_id_counter!(::Type{T}) where {T}     # 특정 타입 T 의 유효ID 카운터를 1로 리셋
    global VALID_ID_COUNTERS                        # 전역 딕셔너리 사용 선언
    VALID_ID_COUNTERS[T] = 1                         # T 의 카운터를 1로 되돌림
end
function reset_all_id_counters!()                   # 모든 타입의 유효ID 카운터를 리셋
    global VALID_ID_COUNTERS                        # 전역 딕셔너리 사용 선언
    for k in collect(keys(VALID_ID_COUNTERS))       # 키(타입)들을 리스트로 모아 순회(순회 중 수정 안전하게)
        reset_id_counter!(k)                        # 각 타입 카운터를 리셋
    end
end
function get_unique_invalid_id(::Type{T}) where {T} # 무효(placeholder) ID 를 -1, -2, ... 순으로 발급
    global INVALID_ID_COUNTERS                      # 전역 무효 카운터 사용 선언
    id = get!(INVALID_ID_COUNTERS, T, -1)           # T 가 없으면 -1 을 시작값으로 넣고 반환
    INVALID_ID_COUNTERS[T] -= 1                      # 다음 발급을 위해 1 감소(더 작은 음수로)
    return T(id)                                    # 무효 ID 객체 생성해 반환
end
function reset_invalid_id_counter!(::Type{T}) where {T}  # 특정 타입의 무효ID 카운터를 -1로 리셋
    global INVALID_ID_COUNTERS                      # 전역 무효 카운터 사용 선언
    INVALID_ID_COUNTERS[T] = -1                      # T 의 무효 카운터를 -1로 되돌림
end
function reset_all_invalid_id_counters!()           # 모든 타입의 무효ID 카운터를 리셋
    global INVALID_ID_COUNTERS                      # 전역 무효 카운터 사용 선언
    for k in collect(keys(INVALID_ID_COUNTERS))     # 모든 타입 키를 순회
        reset_invalid_id_counter!(k)                # 각각 -1로 리셋
    end
end

get_id(id::AbstractID) = id.id                      # ID 객체에서 내부 정수 id 필드를 꺼냄
# Base.:+ 등 : `+`, `-`, `<` 같은 연산자도 함수라서 이렇게 ID 타입에 맞춰 동작을 새로 정의할 수 있음(연산자 오버로딩).
Base.:+(id::A, i::Int) where {A<:AbstractID} = A(get_id(id) + i)             # ID + 정수 → 번호를 더한 같은 종류의 ID
Base.:+(id::A, i::A) where {A<:AbstractID} = A(get_id(id) + get_id(i))       # ID + 같은종류ID → 두 번호를 더한 ID
Base.:-(id::A, i::Int) where {A<:AbstractID} = A(get_id(id) - i)             # ID - 정수 → 번호를 뺀 ID
Base.:-(id::A, i::A) where {A<:AbstractID} = A(get_id(id) - get_id(i))       # ID - 같은종류ID → 두 번호를 뺀 ID
Base.:(<)(id1::AbstractID, id2::AbstractID) = get_id(id1) < get_id(id2)      # ID 끼리 < 비교는 내부 번호로 비교
Base.:(>)(id1::AbstractID, id2::AbstractID) = get_id(id1) > get_id(id2)      # ID 끼리 > 비교도 내부 번호로
Base.isless(id1::AbstractID, id2::AbstractID) = id1 < id2                    # 정렬용 isless 도 위 < 정의를 사용
Base.convert(::Type{ID}, i::Int) where {ID<:AbstractID} = ID(i)             # 정수를 ID 타입으로 자동 변환할 때 ID(i) 호출
Base.copy(id::ID) where {ID<:AbstractID} = ID(get_id(id))                    # ID 복사 = 같은 번호로 새 ID 생성

valid_id(id::AbstractID) = get_id(id) > -1          # 번호가 -1 초과면 유효한 ID(-1 이하는 미지정/무효)

"""
    abstract type AbstractTreeNode{E,ID}

E is element type, ID is id type
"""
# {ID} 매개변수를 가진 추상 트리노드 타입. 하위(구체) 타입들은 id/parent/children 필드를 갖는다고 가정.
abstract type AbstractTreeNode{ID} end
# n::AbstractTreeNode{ID} ... = ID : 인자의 타입에서 ID 매개변수를 끄집어내 그 타입 자체를 반환(런타임에 ID 타입 알아내기).
_id_type(n::AbstractTreeNode{ID}) where {ID} = ID   # 이 노드의 ID 타입(예: ObjectID)을 반환

node_id(node::AbstractTreeNode) = node.id           # 노드의 id 필드 반환
get_parent(n::AbstractTreeNode) = n.parent          # 노드의 부모 반환
get_children(n::AbstractTreeNode) = n.children       # 노드의 자식들(딕셔너리) 반환
# haskey(dict, key) : 딕셔너리에 키가 있는지(파이썬 key in dict).
has_child(parent::AbstractTreeNode, child::AbstractTreeNode) = haskey(get_children(parent), node_id(child))  # parent 의 자식목록에 child 가 있나
# === : "동일 객체인지"(같은 메모리) 비교. ==(값 비교)보다 엄격. 파이썬 is 와 비슷.
has_parent(child::AbstractTreeNode, parent::AbstractTreeNode) = get_parent(child) == parent  # child 의 부모가 parent 와 같은가

function rem_parent!(child::AbstractTreeNode)       # child 를 현재 부모에서 떼어냄(in-place)
    delete!(get_children(get_parent(child)), node_id(child))  # 부모의 자식목록에서 child 항목 삭제
    child.parent = child                            # 부모를 자기 자신으로 설정(=부모 없음 = 뿌리 표시 관례)
end

function set_parent!(child::AbstractTreeNode, parent::AbstractTreeNode)  # child 의 부모를 parent 로 지정
    # @assert 조건 : 조건이 거짓이면 에러를 던지는 매크로(파이썬 assert). `!`는 부정(not).
    @assert !(child === parent)                     # 자기 자신을 부모로 두는 것 금지
    rem_parent!(child)                              # 기존 부모 관계 먼저 제거
    get_children(parent)[child.id] = child          # 새 부모의 자식목록에 child 등록
    child.parent = parent                           # child 의 부모를 parent 로 설정
    return true                                     # 성공 표시로 true 반환
end

"""
    get_root_node(n::AbstractTreeNode{E,ID}) where {E,ID}

Return the root node of a tree
"""
function get_root_node(n::AbstractTreeNode)         # n 이 속한 트리의 뿌리 노드까지 부모를 따라 올라감
    # identify the root of the tree
    ids = Set{AbstractID}()                         # 이미 방문한 노드 id 집합(순환 감지용)
    node = n                                        # 현재 노드를 n 으로 시작
    parent_id = nothing                             # 직전 노드 id (nothing = 파이썬 None)
    while !(parent_id === node_id(node))            # 부모로 올라가도 id 가 안 바뀌면(=자기부모=뿌리) 멈춤
        parent_id = node_id(node)                   # 현재 노드 id 기록
        if parent_id in ids                         # 이미 본 id 가 또 나오면 순환
            throw(ErrorException("Tree is cyclic!"))  # 트리가 순환이면 에러 발생
        end
        push!(ids, parent_id)                       # 방문 집합에 현재 id 추가
        node = get_parent(node)                     # 부모로 한 칸 올라감
    end
    return node                                     # 더 못 올라가는 뿌리 노드 반환
end


"""
    validate_tree(n::AbstractTreeNode)

Ensure that the subtree of n is in fact a tree--no cycles, and no duplicate ids
"""
# where {ID,N<:AbstractTreeNode{ID}} : N 은 ID 매개변수를 가진 트리노드 타입. 둘 다 본문에서 활용.
function validate_sub_tree(n::N) where {ID,N<:AbstractTreeNode{ID}}
    # Breadth-first search
    node = n                                        # 탐색 시작 노드
    # Dict(... => ...) : 키=>값 쌍으로 딕셔너리 생성. `=>` 는 Pair(쌍)를 만드는 연산자.
    frontier = Dict{AbstractID,AbstractTreeNode}(node_id(node) => node)  # 앞으로 방문할 노드들(id→노드)
    explored = Set{AbstractID}()                    # 이미 방문한 노드 id 집합
    while !isempty(frontier)                        # 방문할 노드가 남아있는 동안
        id, node = pop!(frontier)                   # 하나 꺼냄(딕셔너리 pop! 은 (키,값) 쌍 반환)
        if node_id(node) in explored                # 이미 방문한 노드면
            @warn "$node already explored--is there a cycle?"  # 경고 로그("$node"는 문자열 보간=파이썬 f-string)
            return false                            # 순환 의심 → 트리 아님(false)
        end
        push!(explored, node_id(node))              # 방문 처리
        for (child_id, child) in get_children(node) # 자식들(id, 노드)을 순회
            push!(frontier, child_id => child)      # 각 자식을 방문 대기열에 추가
        end
    end
    return true                                     # 끝까지 문제없으면 유효한 트리(true)
end

"""
    validate_tree(n::AbstractTreeNode)

Ensure that the transform tree is in fact a tree--no cycles, and no duplicate
ids
"""
function validate_tree(n::AbstractTreeNode)         # n 이 속한 전체 트리가 올바른 트리인지 검사
    node = get_root_node(n)                          # 먼저 뿌리까지 올라가서
    validate_sub_tree(node)                          # 뿌리부터 전체 서브트리를 검증
end

"""
    validate_embedded_tree(graph,f=v->get_node(graph,v))

Verify that all graph edges are mirrored by the parent-child structure stored in
the nodes.
"""
# f=v -> get_node(graph, v) : 기본 인자가 "익명함수(람다)". `v -> ...` 는 파이썬 lambda v: ... 와 같음. 꼭짓점→노드 변환.
function validate_embedded_tree(graph, f=v -> get_node(graph, v), early_stop=false)
    valid = true                                    # 전체 검증 통과 여부
    for e in edges(graph)                           # 그래프의 모든 엣지 e 순회
        src = f(edge_source(e))                      # 엣지의 출발 꼭짓점을 노드로 변환
        dst = f(edge_target(e))                      # 엣지의 도착 꼭짓점을 노드로 변환
        if !(has_child(src, dst) && has_parent(dst, src))  # 엣지가 부모-자식 관계로도 반영돼 있지 않으면(&&=논리 and)
            @warn "Property \"has_child(src,dst) && has_parent(dst,src)\" does not hold for edge $e"  # 경고
            valid = false                           # 검증 실패 표시
        end
        # 삼항연산자 cond ? a : b (파이썬 a if cond else b). early_stop 이고 무효면 break, 아니면 아무것도 안 함(nothing).
        early_stop && !valid ? break : nothing      # 조기중단 옵션이 켜져 있고 이미 실패면 루프 탈출
    end
    for u in Graphs.vertices(graph)                 # 모든 꼭짓점 u(부모 후보) 순회
        parent = f(u)                               # u 를 노드로 변환
        for v in Graphs.vertices(graph)             # 모든 꼭짓점 v(자식 후보) 순회 (모든 쌍 검사)
            child = f(v)                            # v 를 노드로 변환
            if has_child(parent, child) || has_parent(child, parent)  # 둘 사이에 부모/자식 관계가 하나라도 있으면(||=or)
                if !(has_child(parent, child) && has_parent(child, parent))  # 한쪽만 성립(짝이 안 맞으면)
                    if !(parent === child)          # 자기 자신이 아닌 경우에만
                        @warn "has_child($u,$v) = $(has_child(parent,child)) but has_parent($v,$u) = $(has_parent(child,parent))"  # 불일치 경고
                        valid = false               # 검증 실패
                    end
                end
                if !has_edge(graph, u, v)           # 부모-자식 관계인데 정작 그래프 엣지가 없으면
                    if !(parent === child)          # 자기 자신 제외
                        @warn "has_child($u,$v) && has_parent($v,$u) but !has_edge(graph,$u,$v)"  # 엣지 누락 경고
                        valid = false               # 검증 실패
                    end
                end
            end
            early_stop && !valid ? break : nothing  # 조기중단 옵션 시 실패하면 안쪽 루프 탈출
        end
    end
    return valid                                    # 최종 검증 결과 반환
end

"""
	depth_first_search(node::AbstractTreeNode,goal_function,expand_function,
		neighbor_function=outneighbors)

Returns the first vertex satisfying goal_function(graph,v). Only expands v if
expand_function(graph,v) == true.
"""
# 트리 노드용 깊이우선탐색(DFS). goal_function 이 참인 첫 노드를 반환. expand_function 이 참인 노드만 자식까지 펼침.
function depth_first_search(node::AbstractTreeNode,
    goal_function,                                  # 노드를 받아 "목표인지" true/false 판정하는 함수
    expand_function=v -> true,                      # 노드를 받아 "자식까지 탐색할지" 판정(기본: 항상 true)
    explored=Set{_id_type(node)}(),                 # 이미 방문한 노드 id 집합(기본: 빈 집합, 노드의 ID 타입으로)
    skip_first=false,                               # 시작 노드 자신은 목표여도 건너뛸지 여부
)
    if goal_function(node)                          # 현재 노드가 목표 조건을 만족하면
        if !(skip_first && isempty(explored))       # (첫 노드 건너뛰기 옵션이고 아직 아무것도 방문 안 했음)이 아니라면
            return node                             # 이 노드를 결과로 반환
        end
    end
    push!(explored, node_id(node))                  # 현재 노드를 방문 처리
    if expand_function(node)                        # 이 노드를 펼쳐도 되면
        for (_, child) in get_children(node)        # 자식들을 순회 (_ 는 키를 안 쓴다는 표시=파이썬 _)
            if !(node_id(child) in explored)        # 아직 방문 안 한 자식이면
                retval = depth_first_search(child,  # 그 자식에서 재귀적으로 DFS
                    goal_function,
                    expand_function,
                    explored)
                if !(retval === nothing)            # 재귀가 목표를 찾았으면(nothing 이 아니면)
                    return retval                   # 그 결과를 위로 전달
                end
            end
        end
    end
    return nothing                                  # 못 찾으면 nothing(None) 반환
end

"""
    has_descendant(node::AbstractTreeNode,other::AbstractTreeNode)

Check if `other` is a descendant of `node`.
"""
function has_descendant(node::AbstractTreeNode, other::AbstractTreeNode)  # other 가 node 의 자손인지 검사
    val = depth_first_search(node, v -> (v === other))  # node 서브트리에서 other 와 동일한 노드를 DFS 로 찾음
    return !(val === nothing)                       # 찾았으면 true(자손 있음), 못 찾으면 false
end

"""
    has_ancestor(node::AbstractTreeNode,other::AbstractTreeNode)

Check if `other` is an ancestor of `node`.
"""
function has_ancestor(node::AbstractTreeNode, other::AbstractTreeNode)  # other 가 node 의 조상인지 검사
    has_descendant(other, node)                     # "other 의 자손이 node 인가"로 뒤집어 확인
end

"""
    CachedTreeNode{ID} <: AbstractTreeNode{ID}

Abstract type representing a node with a cached value. Concrete subtypes have a
cached element (accessed via `cached_element(n)`).
"""
# 캐시된 값을 가진 트리노드의 추상 타입. AbstractTreeNode 의 하위이면서, cached_element(n) 으로 캐시에 접근.
abstract type CachedTreeNode{ID} <: AbstractTreeNode{ID} end

# {E,ID} : 원소타입 E, ID타입 ID 두 매개변수를 갖는 구체 트리노드. mutable = 부모/자식 등을 나중에 바꿀 수 있음.
mutable struct TreeNode{E,ID} <: CachedTreeNode{ID}
    id::ID                                          # 이 노드의 고유 ID
    element::CachedElement{E}                        # 노드가 들고 있는 캐시된 값
    parent::TreeNode                                # 부모 노드(자기 자신이면 뿌리)
    children::Dict{ID,TreeNode{E,ID}}                # 자식들(자식id → 자식노드)
    # struct 안의 함수 = "내부 생성자". new{...}() 로 필드를 직접 채워 객체를 만든 뒤 반환.
    function TreeNode{E,ID}(e::E) where {E,ID}
        t = new{E,ID}()                             # 필드 미지정 상태의 빈 객체 생성
        t.id = get_unique_id(ID)                    # 새 고유 ID 발급
        t.element = CachedElement(e)                # 주어진 값 e 를 캐시로 감싸 저장
        t.parent = t                                # 부모를 자기 자신으로(=뿌리)
        t.children = Dict{ID,TreeNode}()            # 자식 딕셔너리를 빈 것으로 초기화
        return t                                    # 완성된 노드 반환
    end
end

"""
    cached_element(n::CachedTreeNode)   = n.element

Default method for retrieving the cached element of n.
"""
cached_element(n::CachedTreeNode) = n.element       # 노드의 캐시 원소(element 필드) 반환
time_stamp(n::CachedTreeNode) = time_stamp(cached_element(n))  # 노드의 타임스탬프 = 캐시 원소의 타임스탬프

"""
    cached_node_up_to_date(n::CachedTreeNode)

Check if n is up to date.
"""
function cached_node_up_to_date(n::CachedTreeNode)  # 노드의 캐시값이 최신인지(부모보다 새 것인지) 판정
    if is_up_to_date(cached_element(n))             # 우선 캐시 자체가 최신 플래그면
        if !(n === get_parent(n))                   # 뿌리(자기부모)가 아니면
            return time_stamp(n) > time_stamp(get_parent(n))  # 내 타임스탬프가 부모보다 더 최신이어야 유효
        else
            return true                             # 뿌리는 비교 대상 없으니 항상 최신으로 간주
        end
    end
    return false                                    # 플래그가 이미 구식이면 false
end

"""
    set_cached_node_up_to_date!(n::CachedTreeNode,val=true)

Set "up to date" status of n to val.
"""
function set_cached_node_up_to_date!(n::CachedTreeNode, val=true, propagate=true)  # 노드 최신상태 설정 + 자식들에 전파
    old_val = is_up_to_date(cached_element(n))      # 바꾸기 전 기존 플래그 기록
    set_up_to_date!(cached_element(n), val)         # 이 노드의 캐시 플래그를 val 로 설정
    # propagate "outdated" signal up the tree
    # old_val 이 참일 때(=원래 최신이었을 때)만 자식들에 "구식" 신호를 내려보냄 — 이미 구식이었으면 다시 전파해봐야 낭비이므로 건너뜀.
    if propagate && old_val # reduce the amount of wasted forward propagation of "out-of-date" flag
        for (id, child) in get_children(n)          # 모든 자식에 대해
            set_cached_node_up_to_date!(child, false, propagate)  # 자식들을 "구식"으로 표시(재귀 전파)
        end
    end
    return n                                        # 갱신한 노드 반환
end

"""
    propagate_backward!(n::CachedTreeNode,args...)

Propagate information up the tree from n.
"""
# args... : 가변 인자(파이썬 *args). 몇 개가 오든 묶어서 받고, 호출 시 `...`로 다시 펼쳐 넘김.
function propagate_backward!(n::CachedTreeNode, args...)  # n 에서 부모 방향(위)으로 정보 전파 시작
    propagate_backward!(n, get_parent(n), args...)  # (자식 n, 부모) 2-인자 버전 호출, 추가인자 펼쳐서 전달
end
"""
    propagate_backward!(child::CachedTreeNode,parent::CachedTreeNode,args...)

Propagate information from child to parent.
"""
# 기본(아무것도 안 하는) 버전. 구체 노드 타입이 필요하면 이 메서드를 덮어써서 실제 전파 로직을 넣음.
propagate_backward!(child::CachedTreeNode, parent::CachedTreeNode, args...) = nothing  # 기본은 전파 없음(nothing)
"""
    propagate_forward!(n::CachedTreeNode,args...)

Propagate information down the tree from n.
"""
function propagate_forward!(n::CachedTreeNode, args...)  # n 에서 자식 방향(아래)으로 정보 전파 시작
    for (id, child) in get_children(n)              # 모든 자식에 대해
        propagate_forward!(n, child, args...)       # (부모 n, 자식) 2-인자 버전 호출
    end
    return n                                         # n 반환
end
"""
    propagate_forward!(parent::CachedTreeNode,child::CachedTreeNode,args...)

Propagate information from parent to child.
"""
# 기본(아무것도 안 하는) 버전. 구체 노드 타입에서 부모→자식 전파 로직을 덮어쓸 수 있음.
propagate_forward!(parent::CachedTreeNode, child::CachedTreeNode, args...) = nothing  # 기본은 전파 없음

"""
    update_element!(n::CachedTreeNode,element,args...)

Update cached element of n, and propagate relevant information forward and
backward via `propagate_forward!` and `propagate_backward!`
"""
function update_element!(n::CachedTreeNode, element, propagate=true, args...)  # 노드의 캐시값 갱신 + 양방향 전파
    update_element!(cached_element(n), element)     # 노드의 캐시 원소를 새 값으로 갱신(값/플래그/타임스탬프)
    set_cached_node_up_to_date!(n, true)            # 이 노드를 최신으로 표시
    if propagate                                    # 전파 옵션이 켜져 있으면
        propagate_backward!(n, args...)             # 부모 방향으로 정보 전파
        propagate_forward!(n, args...)              # 자식 방향으로 정보 전파
    end
    return n                                         # 갱신된 노드 반환
end

"""
    get_cached_value!(n::CachedTreeNode)

Return the up to date cached value of n. This triggers a reach back to parent
nodes if necessary.
"""
function get_cached_value!(n::CachedTreeNode)       # 노드의 최신 캐시값을 얻음(필요하면 부모에서 끌어옴)
    if !cached_node_up_to_date(n)                   # 캐시가 최신이 아니면
        propagate_forward!(get_parent(n), n) # retrieve relevant info from parent  # 부모→이 노드로 정보 갱신
    end
    get_element(cached_element(n))                  # 최신화된 캐시값 반환
end

# Graphs 패키지의 AbstractGraph{Int}(정수 꼭짓점 그래프)을 상속하는 우리만의 커스텀 그래프 최상위 추상 타입.
abstract type AbstractCustomGraph <: Graphs.AbstractGraph{Int} end

"""
    abstract type AbstractCustomNGraph{G,N,ID} <: AbstractCustomGraph

An abstract Custom Graph type, with an underlying graph of type `G`, nodes of
type `N` with ids of type `ID`. All concrete subtypes `CG<:AbstractCustomNGraph`
must implement the following methods: `get_graph(g::CG)`,`get_vtx_ids(g::CG)`,
`get_vtx_map(g::CG)`, and `get_nodes(g::CG)`. These methods are implemented by
default if `g::CG` has the following fields:
- `graph     ::CG`
- `nodes     ::Vector{N}`
- `vtx_map   ::Dict{ID,Int}`
- `vtx_ids   ::Vector{ID}`

Abstract subtypes of `AbstractCustomNGraph{G,N,ID}` include:
- `AbstractCustomNEGraph{G,N,E,ID}` - a graph with custom edges of type `E`
"""
# {G,N,ID} : 세 매개변수 — 바탕 그래프 타입 G, 노드 타입 N, ID 타입 ID. 이 셋으로 그래프 종류를 구분.
abstract type AbstractCustomNGraph{G,N,ID} <: AbstractCustomGraph end

"""
    abstract type AbstractCustomNEGraph{G,N,E,ID} <: AbstractCustomNGraph{G,N,ID}

An abstract Custom Graph type, with an underlying graph of type `G`, nodes of
type `N` with ids of type `ID`, and edges of type `E`. All concrete subtypes
`CG<:AbstractCustomNEGraph` must implement the required `AbstractCustomNGraph`
interface in addition to the following methods:
- `out_edges(g::CG)` : returns an integer-indexed forward adjacency list `fadj`
    such that `fadj[u::Int][v::Int]` contains the custom edge associated
    with `u → v`.
- `in_edges(g::CG)` : returns an integer-indexed backward adjacency list `badj`
    such that `badj[v::Int][u::Int]` contains the custom edge associated
    with `u → v`.
The above methods are implemented by default if `g::CG` has the following
fields:
- `outedges  ::Vector{Dict{Int,E}}`
- `inedges   ::Vector{Dict{Int,E}}`
"""
# 위 타입에 "엣지 타입 E"까지 추가한 버전(엣지에도 부가 데이터를 붙이는 그래프).
abstract type AbstractCustomNEGraph{G,N,E,ID} <: AbstractCustomNGraph{G,N,ID} end

# const ...{N,ID} = ... : 타입 별칭(여러 매개변수를 일부 고정한 짧은 이름). 여기선 바탕그래프를 방향그래프 DiGraph 로 고정.
const AbstractCustomNDiGraph{N,ID} = AbstractCustomNGraph{Graphs.DiGraph,N,ID}        # 방향그래프 기반 노드그래프 별칭
const AbstractCustomNEDiGraph{N,E,ID} = AbstractCustomNEGraph{Graphs.DiGraph,N,E,ID}  # 방향그래프 기반 노드+엣지그래프 별칭

"""
    abstract type AbstractCustomNTree{N,ID} <: AbstractCustomNDiGraph{N,ID}

Abstract custom graph type with tree edge structure.
"""
abstract type AbstractCustomNTree{N,ID} <: AbstractCustomNDiGraph{N,ID} end           # 트리 구조 커스텀 그래프(노드만)
abstract type AbstractCustomNETree{N,E,ID} <: AbstractCustomNEDiGraph{N,E,ID} end     # 트리 구조 커스텀 그래프(노드+엣지)
# Union{A,B} : "A 이거나 B"인 타입(합집합 타입). 둘 중 어느 트리든 받는 별칭.
const AbstractCustomTree = Union{AbstractCustomNTree,AbstractCustomNETree}            # 두 트리 타입을 묶은 별칭

# Common interface  (여러 커스텀 그래프 타입이 공통으로 갖추는 접근자/조작 함수 모음)
# 인자에서 매개변수 G/N/ID 를 뽑아 그 "타입 자체"를 반환하는 헬퍼들(앞의 ::는 값 이름 없이 타입만 패턴매칭).
_graph_type(::AbstractCustomNGraph{G,N,ID}) where {G,N,ID} = G   # 바탕 그래프 타입 G 반환
_node_type(::AbstractCustomNGraph{G,N,ID}) where {G,N,ID} = N    # 노드 타입 N 반환
_id_type(::AbstractCustomNGraph{G,N,ID}) where {G,N,ID} = ID     # ID 타입 ID 반환
"""
    get_graph(g::AbstractCustomNGraph{G,N,ID})

return the underlying graph of type `G`.
"""
get_graph(g::AbstractCustomGraph) = g.graph         # 커스텀 그래프 안의 바탕 그래프(graph 필드) 반환
get_graph(g::Graphs.AbstractGraph) = g              # 이미 일반 그래프면 자기 자신 반환(통일된 접근용)
"""
    get_vtx_ids(g::AbstractCustomNGraph{G,N,ID})

return the vector `Vector{ID}` of `g`'s unique vertex ids.
"""
get_vtx_ids(g::AbstractCustomNGraph) = g.vtx_ids    # 꼭짓점 번호 순서대로의 ID 목록(Vector) 반환
"""
    get_vtx_map(g::AbstractCustomNGraph{G,N,ID})

return a data structure (e.g, a 'Dict{ID,Int}') mapping node id to node index.
"""
get_vtx_map(g::AbstractCustomNGraph) = g.vtx_map    # ID→꼭짓점번호 매핑 딕셔너리 반환
"""
    get_nodes(g::AbstractCustomNGraph{G,N,ID})

Return the vector `Vector{N}` of `g`'s nodes.
"""
get_nodes(g::AbstractCustomNGraph) = g.nodes        # 꼭짓점 번호 순서대로의 노드 목록(Vector) 반환

# Base.zero 확장: "빈" 그래프를 생성. _graph_type(g)() 는 바탕그래프 타입의 빈 인스턴스(예: DiGraph()).
Base.zero(g::G) where {G<:AbstractCustomNGraph} = G(graph=_graph_type(g)())  # g 와 같은 종류의 빈 그래프 생성

# get_vtx : 다양한 입력(정수/ID/노드)을 "정수 꼭짓점 번호"로 통일해 주는 다중 디스패치 함수들.
get_vtx(g::AbstractCustomNGraph, v::Int) = v        # 이미 정수면 그대로 반환
get_vtx(g::AbstractCustomNGraph{G,N,ID}, id::ID) where {G,N,ID} = get(get_vtx_map(g), id, -1)  # ID 면 매핑에서 번호 찾기(없으면 -1)
get_vtx(g::AbstractCustomNGraph{G,N,ID}, node::N) where {G,N,ID} = get_vtx(g, node.id)         # 노드면 그 노드의 id 로 다시 조회
get_vtx_id(g::AbstractCustomNGraph, v::Int) = get_vtx_ids(g)[v]  # 정수 번호 v 에 해당하는 ID 반환
get_node(g::AbstractCustomNGraph, v) = get_nodes(g)[get_vtx(g, v)]  # v(정수/ID/노드)에 해당하는 실제 노드 반환

# @eval + for 루프 = "메타프로그래밍": 여러 함수를 코드로 자동 생성. $op 는 루프 변수 op(심볼)를 코드에 끼워 넣음(보간).
#   아래는 Graphs 의 여러 함수를 "우리 커스텀 그래프 → 바탕 그래프로 위임"하도록 한꺼번에 정의함.
for op in [:edgetype, :ne, :nv, :vertices, :edges, :is_cyclic, :topological_sort_by_dfs, :is_directed, :is_connected]
    @eval Graphs.$op(g::AbstractCustomNGraph) = Graphs.$op(get_graph(g))  # 각 함수: 커스텀그래프를 받으면 바탕그래프에 그대로 위임
end
for op in [:outneighbors, :inneighbors, :indegree, :outdegree, :has_vertex]
    @eval Graphs.$op(g::AbstractCustomNGraph, v::Int) = Graphs.$op(get_graph(g), v)  # 정수 꼭짓점 버전: 바탕그래프에 위임
    @eval Graphs.$op(g::AbstractCustomNGraph, id) = Graphs.$op(g, get_vtx(g, id))    # ID/노드 버전: 먼저 정수번호로 바꿔 호출
end
for op in [:bfs_tree]
    @eval Graphs.$op(g::AbstractCustomNGraph, v::Int; kwargs...) = $op(get_graph(g), v; kwargs...)  # kwargs...=키워드 인자 묶음 전달
    @eval Graphs.$op(g::AbstractCustomNGraph, id; kwargs...) = $op(get_graph(g), get_vtx(g, id); kwargs...)  # ID 버전
end
for op in [:has_edge] #,:add_edge!,:rem_edge!]
    @eval Graphs.$op(s::AbstractCustomNGraph, u, v) = $op(get_graph(s), get_vtx(s, u), get_vtx(s, v))  # 엣지 존재여부: 두 끝점을 정수로 바꿔 위임
end

"""
    node_id(node)

Return the id of a node. Part of the required node interface for nodes in an
 `AbstractCustomNGraph`.
"""
node_id(node) = node.id                             # 임의 노드의 id 필드 반환(노드 인터페이스의 일부)

"""
    node_val(node)

Return the value associated with a node. Part of the optional node interface for
nodes in an `AbstractCustomNGraph`.
"""
node_val(node) = node.val                           # 노드에 담긴 값(val 필드) 반환

"""
    edge_source(edge)

Returns the ID of the source node of an edge. Part of the required interface for
edges in an `AbstractCustomNEGraph`.
"""
edge_source(edge) = edge.src                        # 엣지의 출발 노드 ID(src 필드) 반환
"""
    edge_target(edge)

Returns the ID of the target node of an edge. Part of the required interface for
edges in an `AbstractCustomNEGraph`.
"""
edge_target(edge) = edge.dst                        # 엣지의 도착 노드 ID(dst 필드) 반환
"""
    edge_val(edge)

Returns the value associated with an edge. Part of the optional interface for
edges in an `AbstractCustomNEGraph`.
"""
edge_val(edge) = edge.val                           # 엣지에 담긴 값(val 필드) 반환


function set_vtx_map!(g::AbstractCustomNGraph, node, id, v::Int)  # 꼭짓점번호 v 위치에 노드/ID 매핑을 기록
    @assert nv(g) >= v                              # 그래프 꼭짓점 수가 v 이상인지 확인(범위 보장)
    get_vtx_map(g)[id] = v                           # ID→번호 매핑에 id↦v 등록
    get_nodes(g)[v] = node                           # 번호 v 위치의 노드를 node 로 설정
end
function insert_to_vtx_map!(g::AbstractCustomNGraph, node, id, idx::Int=nv(g))  # 새 노드를 목록 끝에 추가하고 매핑 등록
    push!(get_vtx_ids(g), id)                        # ID 목록 끝에 id 추가
    push!(get_nodes(g), node)                        # 노드 목록 끝에 node 추가
    set_vtx_map!(g, node, id, idx)                   # 해당 번호 idx 에 매핑 기록
end

"""
    replace_node!(g::AbstractCustomNGraph{G,N,ID},node::N,id::ID) where {G,N,ID}

Replace the current node associated with `id` with the new node `node`.
"""
function replace_node!(g::AbstractCustomNGraph{G,N,ID}, node::N, id::ID) where {G,N,ID}  # 기존 id 의 노드를 새 node 로 교체
    v = get_vtx(g, id)                              # id 의 꼭짓점 번호 조회
    @assert v != -1 "node id $(string(id)) is not in graph and therefore cannot be replaced"  # 없으면(-1) 에러
    set_vtx_map!(g, node, id, v)                    # 같은 번호 위치에 새 노드로 덮어씀
    node                                            # 교체한 노드 반환(함수 끝 값이 반환값)
end

"""
    add_node!(g::AbstractCustomNGraph{G,N,ID},node::N,id::ID) where {G,N,ID}

Add `node` to `g` with associated `id`.
"""
function add_node!(g::AbstractCustomNGraph{G,N,ID}, node::N, id::ID) where {G,N,ID}  # 그래프에 새 노드 추가
    @assert !has_vertex(g, id) "Trying to add node $(string(node)) with id $(string(id)) to g, but a node with id $(string(id)) already exists in g"  # 같은 id 중복 금지
    add_vertex!(get_graph(g))                        # 바탕 그래프에 꼭짓점 하나 추가
    insert_to_vtx_map!(g, node, id, nv(g))           # 노드/ID 를 목록과 매핑에 등록(번호 = 현재 꼭짓점 수)
    add_edge_lists!(g)                               # (엣지 그래프인 경우) 새 꼭짓점용 빈 엣지목록 칸 추가
    node                                             # 추가한 노드 반환
end
"""
    make_node(g::AbstractCustomNGraph{G,N,ID},val,id)

Construct a node of type `N` from val and id. This method must be implemented
for whatever custom node type is used.
"""
# function 이름 end : 본문 없는 "함수 이름만 선언". 실제 메서드는 다른 곳/구체타입에서 구현(인터페이스 자리 잡기용).
function make_node end                              # make_node 라는 함수 이름만 선언(구현은 각 노드타입이 제공)
# 아래는 "val 과 id 만 받으면 make_node 로 노드를 만들어 add_node! 한다"는 편의 버전들(다중 디스패치).
add_node!(g::AbstractCustomNGraph{G,N,ID}, val, id::ID) where {G,N,ID} = add_node!(g, make_node(g, val, id), id)  # 값+ID → 노드 생성 후 추가
# add_node!(g::AbstractCustomNEGraph{G,N,E,ID},val,id::ID) where {G,N,E,ID} = add_node!(g,make_node(g,val,id),id)  # (주석처리된 대안)
add_node!(g::AbstractCustomNGraph, val, id) = add_node!(g, make_node(g, val, id))  # 타입제약 없는 일반 버전
replace_node!(g::AbstractCustomNGraph{G,N,ID}, val, id::ID) where {G,N,ID} = replace_node!(g, make_node(g, val, id), id)  # 값으로 노드 만들어 교체

"""
    function add_child!(graph,parent,node,id)

add node `child` to `graph` with id `id`, then add edge `parent` → `child`
"""
function add_child!(g::AbstractCustomNGraph{G,N,ID}, parent, child, id) where {G,N,ID}  # 자식 노드 추가 + parent→child 엣지
    n = add_node!(g, child, id)                      # 먼저 child 를 새 노드로 추가
    if add_edge!(g, parent, id)                      # parent 에서 새 노드로 엣지 추가가 성공하면
        return n                                     # 추가된 노드 반환
    else
        rem_node!(g, id)                             # 실패 시 방금 넣은 노드를 도로 제거(롤백)
        return nothing                               # 실패 표시로 nothing 반환
    end
end

"""
    function add_parent!(graph,child,parent,id)

add node `parent` to `graph` with id `id`, then add edge `parent` → `child`
"""
function add_parent!(g::AbstractCustomNGraph{G,N,ID}, child, parent::N, id::ID) where {G,N,ID}  # 부모 노드 추가 + parent→child 엣지
    n = add_node!(g, parent, id)                     # 먼저 parent 를 새 노드로 추가
    if add_edge!(g, id, child)                       # 새 노드(부모)에서 child 로 엣지 추가 성공 시
        return n                                     # 추가된 노드 반환
    else
        rem_node!(g, id)                             # 실패하면 추가한 노드 롤백
        return nothing                               # 실패 표시
    end
end
# u 와 노드 v 만 줄 경우, v 의 id 를 자동으로 채워 위 3.5인자 버전을 호출하도록 add_child!/add_parent! 를 한꺼번에 정의.
for op in [:add_child!, :add_parent!]
    @eval $op(g::AbstractCustomNGraph{G,N,ID}, u, v::N) where {G,N,ID} = $op(g, u, v, v.id)  # id 생략 시 v.id 사용
end

"""
    swap_with_end_and_delete!(vec,v)

Replaces `vec[v]` with `last(vec)`, then removes the last element from `vec`
"""
# 배열에서 v 번째를 지울 때, 맨 끝 원소를 v 자리로 옮기고 끝을 잘라내는 빠른 삭제(순서 보존 안 됨, O(1)).
function swap_with_end_and_delete!(vec::Vector, v)
    vec[v] = last(vec)                              # v 자리에 마지막 원소를 덮어씀(last=마지막 원소)
    pop!(vec)                                       # 이제 중복된 마지막 원소를 제거
    return vec                                      # 수정된 배열 반환
end

"""
    rem_node!

removes a node (by id) from g.
Note about LightGraphs.rem_vertex!:
"internally the removal is performed swapping the vertices `v` and `nv(G)`, and
removing the last vertex `nv(G)` from the graph"
"""
# 주의: Graphs 의 rem_vertex! 는 내부적으로 "v 와 마지막 꼭짓점을 맞바꾼 뒤 마지막을 제거"함. 그래서 우리 목록도 같은 방식으로 맞춤.
function rem_node!(g::AbstractCustomNGraph{G,N,ID}, id::ID) where {G,N,ID}  # id 로 노드를 그래프에서 제거
    v = get_vtx(g, id)                              # id 의 꼭짓점 번호 조회
    rem_vertex!(get_graph(g), v)                    # 바탕 그래프에서 꼭짓점 v 제거(끝 꼭짓점과 swap)
    swap_with_end_and_delete!(get_nodes(g), v)      # 노드 목록도 같은 swap 방식으로 v 제거
    swap_with_end_and_delete!(get_vtx_ids(g), v)    # ID 목록도 같은 방식으로 v 제거
    delete!(get_vtx_map(g), id)                     # ID→번호 매핑에서 id 항목 삭제
    if v <= nv(g)                                   # v 자리에 끝 원소가 옮겨와 아직 유효한 위치면
        get_vtx_map(g)[get_vtx_ids(g)[v]] = v       # 그 옮겨온 노드의 매핑 번호를 v 로 갱신
    end
    delete_from_edge_lists!(g, v) # no effect except for AbstractCustomNEGraph  # 엣지목록에서도 v 칸 제거(엣지그래프만 효과)
    g                                               # 수정된 그래프 반환
end
rem_node!(g::AbstractCustomNGraph, v) = rem_node!(g, get_vtx_id(g, v))  # 정수 번호 v 로 부르면 ID 로 바꿔 위 함수 호출
function rem_nodes!(g::AbstractCustomNGraph, vtxs::Vector)  # 여러 꼭짓점을 한꺼번에 제거
    # map(f, vtxs) : 각 v 를 ID 로 변환. collect 로 실제 배열화(미리 ID 를 모아둬야 삭제 중 번호가 바뀌어도 안전).
    node_ids = collect(map(v -> get_vtx_id(g, v), vtxs))  # 지울 노드들의 ID 를 먼저 모음
    for id in node_ids                              # 각 ID 에 대해
        rem_node!(g, id)                            # 하나씩 제거
    end
    g                                               # 수정된 그래프 반환
end

# Edge graph interface  (엣지에도 데이터를 붙이는 그래프 전용 함수 모음 — 여기부터 in/out edges 다룸)
_edge_type(::AbstractCustomNEGraph{G,N,E,ID}) where {G,N,E,ID} = E  # 엣지 타입 매개변수 E 자체를 반환

"""
    in_edges(g::AbstractCustomNEGraph{G,N,E,ID})

Returns an integer-indexed backward adjacency list `badj` (e.g.,
`badj::Vector{Dict{Int,E}}`) such that `badj[v::Int][u::Int]` contains the
custom edge associated with `u → v`.
"""
in_edges(g::AbstractCustomNEGraph) = g.inedges      # 전체 들어오는-엣지 인접목록(inedges 필드) 반환
in_edges(g::AbstractCustomNEGraph, v) = in_edges(g)[get_vtx(g, v)]  # 꼭짓점 v 로 들어오는 엣지들(딕셔너리) 반환
in_edge(g::AbstractCustomNEGraph, v, u) = in_edges(g, v)[get_vtx(g, u)]  # u→v 엣지 하나(들어오는 쪽에서) 반환
function set_edge!(g::AbstractCustomNEGraph{G,N,E,ID}, u, v, edge::E) where {G,N,E,ID}  # u→v 엣지 객체를 양쪽 인접목록에 기록
    out_edges(g, u)[get_vtx(g, v)] = edge           # u 의 나가는목록에 v↦edge 저장
    in_edges(g, v)[get_vtx(g, u)] = edge            # v 의 들어오는목록에 u↦edge 저장
    edge                                            # 저장한 엣지 반환
end

"""
    out_edges(g::AbstractCustomNEGraph{G,N,E,ID})

Returns an integer-indexed forward adjacency list `fadj` (e.g.,
`fadj::Vector{Dict{Int,E}}`) such that `fadj[u::Int][v::Int]` contains the
custom edge associated with `u → v`.
"""
out_edges(g::AbstractCustomNEGraph) = g.outedges    # 전체 나가는-엣지 인접목록(outedges 필드) 반환
out_edges(g::AbstractCustomNEGraph, v) = out_edges(g)[get_vtx(g, v)]  # 꼭짓점 v 에서 나가는 엣지들(딕셔너리) 반환
out_edge(g::AbstractCustomNEGraph, u, v) = out_edges(g, u)[get_vtx(g, v)]  # u→v 엣지 하나(나가는 쪽에서) 반환
function get_edge(g::AbstractCustomNEGraph, u, v)   # u→v 엣지를 안전하게 가져오기
    @assert has_edge(g, u, v) "Edge $u → $v does not exist."  # 엣지가 없으면 에러
    return out_edge(g, u, v)                         # 있으면 그 엣지 반환
end
get_edge(g::AbstractCustomNEGraph, edge) = get_edge(g, edge_source(edge), edge_target(edge))  # 엣지객체로 부르면 양 끝점으로 조회
Graphs.has_edge(g::AbstractCustomNEGraph, e) = has_edge(g, edge_source(e), edge_target(e))    # has_edge 에 엣지객체 버전 추가

add_edge_lists!(g::AbstractCustomNGraph) = g        # (엣지 없는 그래프) 아무것도 안 하고 g 반환
function add_edge_lists!(g::AbstractCustomNEGraph{G,N,E,ID}) where {G,N,E,ID}  # (엣지 그래프) 새 꼭짓점용 빈 엣지칸 추가
    push!(g.outedges, Dict{Int,E}())                # 나가는목록에 빈 딕셔너리 한 칸 추가
    push!(g.inedges, Dict{Int,E}())                 # 들어오는목록에 빈 딕셔너리 한 칸 추가
    return g                                         # 그래프 반환
end
delete_from_edge_lists!(g::AbstractCustomNGraph, v::Int) = g  # (엣지 없는 그래프) 아무 효과 없이 g 반환
function delete_from_edge_lists!(g::AbstractCustomNEGraph, v::Int)  # (엣지 그래프) v 칸의 엣지목록 제거
    swap_with_end_and_delete!(in_edges(g), v)       # 들어오는목록에서 v 칸을 swap-삭제(rem_vertex! 방식과 일치)
    swap_with_end_and_delete!(out_edges(g), v)      # 나가는목록에서도 v 칸 swap-삭제
    # deleteat!(in_edges(g),v)                       # (대안: 순서보존 삭제 — 사용 안 함)
    # deleteat!(out_edges(g),v)
    return g                                         # 그래프 반환
end

function add_custom_edge!(g::AbstractCustomNEGraph{G,N,E,ID}, u, v, edge::E) where {G,N,E,ID}  # u→v 에 엣지객체까지 추가
    if !is_legal_edge(g, u, v, edge)                # 이 엣지가 허용되지 않으면
        @warn "An edge $u → $v is illegal in $g"    # 경고
        return false                                # 실패
    end
    if add_edge!(get_graph(g), get_vtx(g, u), get_vtx(g, v))  # 바탕 그래프에 엣지 추가 성공하면
        set_edge!(g, u, v, edge)                    # 우리 엣지 인접목록에도 엣지객체 기록
        return true                                 # 성공
    end
    @warn "Cannot add edge $u → $v. Does an edge already exist?"  # (이미 존재 등) 추가 실패 경고

    return false                                    # 실패
end
add_custom_edge!(g::AbstractCustomNEGraph, edge) = add_custom_edge!(g, edge_source(edge), edge_target(edge), edge)  # 엣지객체로 추가


add_custom_edge!(g::AbstractCustomNGraph, edge) = add_custom_edge!(g, edge_source(edge), edge_target(edge))  # (엣지 없는 그래프) 두 끝점만 추출해 추가
add_custom_edge!(g::AbstractCustomNGraph, u, v) = add_edge!(get_graph(g), get_vtx(g, u), get_vtx(g, v))      # u,v 를 정수화해 바탕그래프에 엣지 추가
add_custom_edge!(g::AbstractCustomNGraph, u, v, args...) = add_custom_edge!(g, u, v)                          # 여분 인자는 무시(엣지값 없는 그래프)

# Graphs 의 add_edge! 를 우리 커스텀 그래프용으로 연결 — 넘어온 인자들을 그대로 add_custom_edge! 로 위임(엣지 타입이 따로 없는 경우).
Graphs.add_edge!(g::AbstractCustomGraph, args...) = add_custom_edge!(g, args...) # no custom edge type here

"""
    make_edge(g::G,u,v,val) where {G}

Construct an edge `u → v` of type `_edge_type(g)` based on val. Default behavior
is to throw an error.
"""
# 기본 make_edge: 구현이 안 된 엣지타입에 대해 친절한 에러 메시지를 던짐(어떻게 고치는지 안내). """...""" 여러줄 문자열.
function make_edge(g::G, u, v, val) where {G}
    throw(ErrorException(                           # 예외를 발생시킴(파이썬 raise)
        """
        MethodError: `make_edge(g,u,v,val)` not implemented.
        To add an edge to a graph g::$G, either:
        - add the edge explicitly using `add_edge!(g,edge,[u,v])
        - make a default constructor for the edge type
        - implement `GraphUtils.make_edge(g,u,v,val)`
        """
    ))
end
make_edge(g, u, v) = make_edge(g, u, v, nothing)    # val 생략 시 nothing 으로 호출
function add_custom_edge!(g::AbstractCustomNEGraph, u, v, val)  # 값 val 로부터 엣지를 만들어 추가
    add_custom_edge!(g, u, v, make_edge(g, u, v, val))  # make_edge 로 엣지객체 생성 후 추가
end
function add_custom_edge!(g::AbstractCustomNEGraph, u, v)  # 값 없이 엣지 추가
    add_custom_edge!(g, u, v, make_edge(g, u, v))   # 기본 엣지를 만들어 추가
end

function replace_edge!(g::AbstractCustomNEGraph{G,N,E,ID}, u, v, edge::E) where {G,N,E,ID}  # 기존 u→v 엣지를 새 객체로 교체
    if has_edge(g, u, v)                            # 엣지가 존재하면
        set_edge!(g, u, v, edge)                    # 새 엣지객체로 덮어씀
        return true                                 # 성공
    end
    @warn "graph does not have edge $u → $v"        # 없으면 경고
    return false                                    # 실패
end
replace_edge!(g::AbstractCustomNEGraph, u, v, val) = replace_edge!(g, u, v, make_edge(g, u, v, val))  # 값으로 엣지 만들어 교체
function replace_edge!(g::AbstractCustomNEGraph{G,N,E,ID}, old_edge, edge::E) where {G,N,E,ID}  # 옛 엣지객체 기준 교체
    replace_edge!(g, edge_source(old_edge), edge_target(old_edge), edge)  # 옛 엣지의 양 끝점으로 교체 호출
end

function delete_edge!(g::AbstractCustomNEGraph, u, v)  # u→v 엣지 삭제(엣지 그래프)
    if rem_edge!(get_graph(g), get_vtx(g, u), get_vtx(g, v))  # 바탕그래프에서 엣지 제거 성공 시
        delete!(out_edges(g, u), get_vtx(g, v))     # u 의 나가는목록에서 v 항목 제거
        delete!(in_edges(g, v), get_vtx(g, u))      # v 의 들어오는목록에서 u 항목 제거
        return true                                 # 성공
    end
    @warn "Cannot remove edge $u → $v. Does it exist?"  # 실패 경고
    return false                                    # 실패
end
delete_edge!(g::AbstractCustomNGraph, u, v) = rem_edge!(get_graph(g), get_vtx(g, u), get_vtx(g, v))  # (엣지값 없는 그래프) 바탕에서만 제거
delete_edge!(g, edge) = delete_edge!(g, edge_source(edge), edge_target(edge))  # 엣지객체로 부르면 양 끝점으로 삭제
Graphs.rem_edge!(g::AbstractCustomGraph, args...) = delete_edge!(g, args...)   # rem_edge! 를 우리 delete_edge! 로 연결

# Tree interface  (트리 구조 그래프 전용 — 부모 찾기, 트리에서 허용되는 엣지 판정 등)
# get(컬렉션, 인덱스, 기본값) : 인덱스가 없으면 기본값 반환. 트리에서 부모는 "들어오는 이웃" 중 첫 번째(없으면 -1).
get_parent(g::AbstractCustomTree, v) = get(inneighbors(g, v), 1, -1)  # v 의 부모 꼭짓점 번호(없으면 -1)
is_legal_edge(g, u, v) = true                       # 일반 그래프: 모든 엣지 허용(기본값)
is_legal_edge(g, u, v, e) = is_legal_edge(g, u, v)  # 엣지객체까지 받는 버전도 결국 위 판정 사용
# 트리에서는 v 가 이미 부모를 가지면 안 되고(자식은 부모 하나) 자기-자기 엣지도 금지.
is_legal_edge(g::AbstractCustomTree, u, v) = !(has_vertex(g, get_parent(g, v)) || get_vtx(g, u) == get_vtx(g, v))  # 트리 엣지 합법성 판정

function add_custom_edge!(g::AbstractCustomTree, u, v)  # 트리에 u→v 엣지 추가
    is_legal_edge(g, u, v)                          # (반환값 안 쓰는 호출 — 사실상 아래 if 에서 다시 검사)
    if !is_legal_edge(g, u, v)                      # 합법적인 엣지가 아니면
        return false                                # 추가 거부
    end
    add_edge!(get_graph(g), get_vtx(g, u), get_vtx(g, v))  # 합법이면 바탕그래프에 엣지 추가
end


"""
    CustomGraph

An example concrete subtype of `AbstractCustomNGraph`.
"""
# 위에서 설명한 인터페이스(graph/nodes/vtx_map/vtx_ids 필드)를 실제로 갖춘 구체 그래프 타입. @with_kw 로 기본값 생성자 자동 추가.
@with_kw struct CustomNGraph{G<:AbstractGraph,N,ID} <: AbstractCustomNGraph{G,N,ID}
    graph               ::G                     = G()              # 바탕 그래프(기본값: 빈 G)
    nodes               ::Vector{N}             = Vector{N}()      # 노드 목록(기본값: 빈 배열)
    vtx_map             ::Dict{ID,Int}          = Dict{ID,Int}()   # ID→꼭짓점번호 매핑(기본값: 빈 딕셔너리)
    vtx_ids             ::Vector{ID}            = Vector{ID}() # maps vertex uid to actual graph node  # 번호→ID 목록
end
const CustomNDiGraph{N,ID} = CustomNGraph{DiGraph,N,ID}  # 바탕그래프를 방향그래프로 고정한 별칭

"""
    CustomNEGraph{G,N,E,ID}

Custom graph type with custom edge and node types.
"""
# 노드뿐 아니라 엣지에도 데이터를 붙이는 구체 그래프 타입. inedges/outedges 로 엣지객체들을 보관.
@with_kw struct CustomNEGraph{G,N,E,ID} <: AbstractCustomNEGraph{G,N,E,ID}
    graph               ::G                     = G()              # 바탕 그래프
    nodes               ::Vector{N}             = Vector{N}()      # 노드 목록
    vtx_map             ::Dict{ID,Int}          = Dict{ID,Int}()   # ID→번호 매핑
    vtx_ids             ::Vector{ID}            = Vector{ID}()     # 번호→ID 목록
    inedges             ::Vector{Dict{Int,E}}   = Vector{Dict{Int,E}}()   # 꼭짓점별 들어오는 엣지(딕셔너리) 목록
    outedges            ::Vector{Dict{Int,E}}   = Vector{Dict{Int,E}}()   # 꼭짓점별 나가는 엣지(딕셔너리) 목록
end
const CustomNEDiGraph{N,E,ID} = CustomNEGraph{N,E,ID}  # 짧은 별칭

"""
    CustomNTree

An example concrete subtype of `AbstractCustomNTree`.
"""
# 트리 구조 구체 그래프(노드만). 바탕그래프를 방향그래프 DiGraph 로 고정.
@with_kw struct CustomNTree{N,ID} <: AbstractCustomNTree{N,ID}
    graph               ::DiGraph               = DiGraph()       # 바탕 방향그래프
    nodes               ::Vector{N}             = Vector{N}()      # 노드 목록
    vtx_map             ::Dict{ID,Int}           = Dict{ID,Int}()  # ID→번호 매핑
    vtx_ids             ::Vector{ID}             = Vector{ID}()    # 번호→ID 목록
end

"""
    CustomNETree{G,N,E,ID}

Custom tree type with custom edge and node types.
"""
# 트리 구조 구체 그래프(노드+엣지). 위 트리에 엣지 데이터 보관용 in/out edges 추가.
@with_kw struct CustomNETree{N,E,ID} <: AbstractCustomNETree{N,E,ID}
    graph               ::DiGraph               = DiGraph()       # 바탕 방향그래프
    nodes               ::Vector{N}             = Vector{N}()      # 노드 목록
    vtx_map             ::Dict{ID,Int}          = Dict{ID,Int}()   # ID→번호 매핑
    vtx_ids             ::Vector{ID}            = Vector{ID}()     # 번호→ID 목록
    inedges             ::Vector{Dict{Int,E}}   = Vector{Dict{Int,E}}()  # 들어오는 엣지 목록
    outedges            ::Vector{Dict{Int,E}}   = Vector{Dict{Int,E}}()  # 나가는 엣지 목록
end

"""
    CustomNode{N,ID}

A custom node type. Fields:
- `id::ID`
- `val::N`
"""
# 표준 노드 타입: 식별자 id 와 값 val 만 담는 단순 구조체.
struct CustomNode{N,ID}
    id::ID              # 노드의 ID
    val::N              # 노드에 담긴 값
end
# 추가 생성자: id 만 주면 값은 N() (그 타입의 기본 생성자 결과)으로 채워 노드 생성.
CustomNode{N,ID}(id::ID) where {N,ID} = CustomNode{N,ID}(id,N())  # 값 생략 시 빈 값으로 노드 생성
# CustomNode 를 쓰는 그래프용 make_node 구현: 그래프의 노드타입으로 (id, val) 노드를 만듦.
function make_node(g::AbstractCustomNGraph{G,CustomNode{N,ID},ID},val::N,id) where {G,N,ID}
    _node_type(g)(id,val)                           # 그래프의 노드타입 생성자에 id,val 전달
end

"""
    CustomEdge{E,ID}

A custom node type. Fields:
- `id::ID`
- `val::E`
"""
# 표준 엣지 타입: 출발 src, 도착 dst, 값 val 을 담음.
struct CustomEdge{E,ID}
    src::ID             # 출발 노드 ID
    dst::ID             # 도착 노드 ID
    val::E              # 엣지에 담긴 값
end
CustomEdge{E,ID}(id1::ID,id2::ID) where {E,ID} = CustomEdge{E,ID}(id1,id2,E())  # 값 생략 시 빈 값으로 엣지 생성
# CustomEdge 를 쓰는 그래프용 make_edge 구현: u,v 를 ID 로 바꾸고 val 과 함께 엣지 생성.
function make_edge(g::AbstractCustomNEGraph{G,N,CustomEdge{E,ID},ID},u,v,val::E) where {G,N,E,ID}
    _edge_type(g)(                                  # 그래프의 엣지타입 생성자에
        get_vtx_id(g,get_vtx(g,u)),                 # u 를 정수번호→ID 로 변환한 출발 ID
        get_vtx_id(g,get_vtx(g,v)),                 # v 를 변환한 도착 ID
        val)                                        # 엣지 값
end

# 자주 쓰는 조합에 짧은 별칭: 노드/엣지에 표준 CustomNode/CustomEdge 를 끼운 그래프·트리 타입들.
const NGraph{G,N,ID} = CustomNGraph{G,CustomNode{N,ID},ID}                     # 표준노드 그래프
const NEGraph{G,N,E,ID} = CustomNEGraph{G,CustomNode{N,ID},CustomEdge{E,ID},ID}  # 표준노드+표준엣지 그래프
const NTree{N,ID} = CustomNTree{CustomNode{N,ID},ID}                           # 표준노드 트리
const NETree{N,E,ID} = CustomNETree{CustomNode{N,ID},CustomEdge{E,ID},ID}      # 표준노드+표준엣지 트리

# 두 그래프타입(CustomNGraph, CustomNTree)에 대해 Base.convert(복사 변환)를 자동 생성.
# @eval begin ... end : 여러 줄을 한꺼번에 코드로 생성. deepcopy = 내부까지 완전 복사(파이썬 copy.deepcopy).
for T in (:CustomNGraph,:CustomNTree)
    @eval begin
        function Base.convert(::Type{X},g::AbstractCustomNGraph{G,N,ID}) where {G,N,ID,X<:$T}
            X(                                       # 대상 타입 X 의 생성자에 모든 필드를 깊은 복사해 전달
                deepcopy(get_graph(g)),              # 바탕그래프 깊은복사
                deepcopy(get_nodes(g)),              # 노드목록 깊은복사
                deepcopy(get_vtx_map(g)),            # ID→번호 매핑 깊은복사
                deepcopy(get_vtx_ids(g))             # 번호→ID 목록 깊은복사
            )
        end
    end
end
# 엣지까지 있는 두 타입(CustomNEGraph, CustomNETree)용 convert 자동 생성.
for T in (:CustomNEGraph,:CustomNETree)
    @eval begin
        function Base.convert(::Type{X},g::AbstractCustomNEGraph{G,N,E,ID}) where {G,N,E,ID,X<:$T}
            X(
                deepcopy(get_graph(g)),              # 바탕그래프
                deepcopy(get_nodes(g)),              # 노드목록
                deepcopy(get_vtx_map(g)),            # ID→번호 매핑
                deepcopy(get_vtx_ids(g)),            # 번호→ID 목록
                deepcopy(in_edges(g)),               # 들어오는 엣지목록
                deepcopy(out_edges(g)),              # 나가는 엣지목록
            )
        end
    end
end


"""
	matches_template(template,node)

Checks if a candidate `node` satisfies the criteria encoded by `template`.
"""
# template(원하는 타입)에 node 가 맞는지 검사. S<:T 는 "S 가 T 의 하위타입인가"(파이썬 issubclass 비슷).
matches_template(template::Type{T},node::Type{S}) where {T,S} = S<:T  # 둘 다 타입일 때: node타입이 template의 하위면 참
matches_template(template::Type{T},node::S) where {T,S} = S<:T        # node가 값일 때: 그 타입 S 가 하위면 참
matches_template(template,node) = matches_template(typeof(template),node)  # template이 타입이 아니면 그 타입을 써서 비교
# Tuple 템플릿이면 "여럿 중 하나라도" 맞으면 참. any(...) = 파이썬 any(), map = 각 t 마다 검사.
matches_template(template::Tuple,node) = any(map(t->matches_template(t,node), template))  # 여러 후보 중 하나라도 매칭되면 참

matches_template(template::Type{T},n::CustomNode) where {T} = matches_template(template,node_val(n))  # CustomNode면 그 안의 값으로 비교



"""
	depth_first_search(graph,v,goal_function,expand_function,
		neighbor_function=outneighbors)

Returns the first vertex satisfying goal_function(graph,v). Only expands v if
expand_function(graph,v) == true.
"""
# 위의 트리노드용과 같은 이름이지만 이건 "(graph, v) 정수 꼭짓점" 버전(다중 디스패치로 구분됨).
# falses(n) = 길이 n 의 모두-false 불리언 배열. `;` 뒤 인자(skip_first)는 "키워드 인자"(호출 시 이름 필수).
function depth_first_search(graph,v,
		goal_function,                              # v 를 받아 목표인지 판정
		expand_function,                            # v 를 펼칠지 판정
		neighbor_function=outneighbors,             # 이웃 찾는 함수(기본: 나가는 이웃)
		explored=falses(nv(graph));                 # 방문 여부 불리언 배열(기본: 전부 미방문)
		skip_first=false,                           # 시작점을 건너뛸지(키워드 인자)
		)
	if goal_function(v)                             # 현재 꼭짓점이 목표면
		if !(skip_first && sum(explored) == 0)      # (첫 방문 건너뛰기 옵션 + 아직 아무것도 방문 안 함)이 아니면
			return v                                # 이 꼭짓점 반환
		end
	end
	explored[v] = true                              # v 를 방문 처리
	if expand_function(v)                           # v 를 펼쳐도 되면
		for vp in neighbor_function(graph,v)        # v 의 이웃 vp 들을 순회
			if !explored[vp]                        # 아직 방문 안 한 이웃이면
				u = depth_first_search(graph,vp,    # 그 이웃에서 재귀 DFS
					goal_function,
					expand_function,
					neighbor_function,
					explored)
				if has_vertex(graph,u)              # 재귀가 유효한 꼭짓점을 찾았으면(존재하는 번호면)
					return u                        # 그 결과 반환
				end
			end
		end
	end
	return -1                                       # 못 찾으면 -1 반환(이 버전은 nothing 대신 -1 사용)
end

"""
	has_path(graph,v,v2)

Return true if `graph` has a path from `v` to `v2`
"""
function has_path(graph,v,v2)                       # v 에서 v2 로 가는 경로가 있는지
	vtx = depth_first_search(graph,v,vtx->vtx==v2,vtx->true,outneighbors)  # v2 를 목표로 DFS(항상 펼침, 나가는 이웃)
	return vtx > 0                                  # 찾았으면(양수 꼭짓점) true, 못 찾으면(-1) false
end

"""
	node_iterator(graph,it)

Wraps an iterator over ids or vertices to return the corresponding node at each
iteration.
"""
node_iterator(graph,it) = transform_iter(v->get_node(graph,v),it)  # 꼭짓점/ID 이터레이터를 실제 노드 이터레이터로 변환

"""
	filtered_topological_sort(graph,template)

Iterator over nodes that match template.
"""
function filtered_topological_sort(graph,template)  # 위상정렬 순서대로 돌되 template 에 맞는 노드만 거르는 이터레이터
	# Base.Iterators.filter(pred, it) : 게으른 필터(파이썬 filter). topological_sort_by_dfs = 위상정렬 결과.
	Base.Iterators.filter(n->matches_template(template,n),
		# transform_iter(v->get_node(graph,v), topological_sort_by_dfs(graph))
		node_iterator(graph, topological_sort_by_dfs(graph))  # 위상정렬된 꼭짓점들을 노드로 변환한 이터레이터
		)
end

"""
    transplant!(graph,old_graph,id)

Share node with `id` in `old_graph` to `graph` with the same id.
"""
function transplant!(graph,old_graph,id)            # old_graph 의 노드(id)를 같은 id 로 graph 에 옮겨 담기(공유)
    add_node!(graph,get_node(old_graph,id),id)      # old_graph 에서 노드를 꺼내 graph 에 추가
end


"""
    backup_descendants(g::AbstractCustomNGraph{G,N,ID},template)

Return a dictionary mapping each node's id to the id of it's closest descendant
matching `template`.
"""
backup_descendants(g,f) = _backup_descendants(g,f,get_graph(g))            # 각 노드→f를 만족하는 가장 가까운 자손 id 매핑
backup_ancestors(g,f) = _backup_descendants(g,f,reverse(get_graph(g)))     # 방향을 뒤집어(reverse) 같은 로직으로 "조상" 계산
function _backup_descendants(g::AbstractCustomNGraph{G,N,ID},f,            # 실제 계산 본체(내부함수)
		graph=get_graph(g),                                                # 어느 그래프(정/역방향)로 볼지
		) where {G,N,ID}
    # Union{ID,Nothing} : 값이 ID 이거나 없음(nothing). 파이썬 Optional[ID] 와 같은 의미.
    descendant_map = Dict{ID,Union{ID,Nothing}}()   # 노드id → (가장 가까운 매칭 자손id 또는 nothing) 결과 저장
    for v in reverse(topological_sort_by_dfs(graph))  # 위상정렬을 거꾸로(말단→뿌리) 순회해 아래에서 위로 채움
		node = get_node(g,v)                        # 현재 꼭짓점의 노드
        if f(node)                                  # 이 노드 자신이 조건 f 를 만족하면
            descendant_map[node_id(node)] = node_id(node)  # 가장 가까운 매칭 자손 = 자기 자신
		elseif is_terminal_node(graph,v)            # 말단인데 자기도 매칭 안 되면
            descendant_map[node_id(node)] = nothing  # 매칭되는 자손 없음
		else
			descendant_map[node_id(node)] = nothing  # 일단 없음으로 초기화한 뒤
			for vp in outneighbors(graph,v)         # 자식들(나가는 이웃)을 보며
				id = get!(descendant_map,get_vtx_id(g,vp),nothing)  # 그 자식이 미리 계산해 둔 매칭자손 id 가져오기
				if !(id === nothing)                # 자식 쪽에 매칭 자손이 있으면
					descendant_map[node_id(node)] = id  # 그것을 내 매칭자손으로 채택
				end
            end
        end
    end
    descendant_map                                  # 완성된 매핑 반환
end

"""
	get_biggest_tree(graph,dir=:in)

Return the root/terminal vertex corresponding to the root of the largest tree in
the graph.
"""
# dir=:in : 기본 인자가 심볼 :in (옵션 선택용 라벨, 파이썬에서 문자열 플래그 쓰는 것과 비슷).
function get_biggest_tree(graph,dir=:in)            # 그래프에서 가장 큰 트리의 뿌리/말단 꼭짓점 반환
	if dir==:in                                     # 들어오는 방향 기준이면
    	leaves = collect(get_all_terminal_nodes(graph))  # 말단 노드들을 후보로(collect=집합→배열)
	else
    	leaves = collect(get_all_root_nodes(graph))      # 아니면 뿌리 노드들을 후보로
	end
	# argmax(...) : 최댓값의 "위치(인덱스)"를 반환. 각 후보에서 BFS 트리를 만들어 엣지 수(ne)가 가장 많은 것을 고름.
	v = argmax(map(v->ne(bfs_tree(graph,v;dir=dir)),leaves))  # 가장 큰 트리를 만드는 후보의 인덱스
	leaves[v]                                       # 그 인덱스의 후보 꼭짓점 반환
end

"""
	collect_subtree(graph,v,dir=:out)

Return a set of all nodes in the subtree of `graph` starting from `v` in
direction `dir`.
"""
function collect_subtree(graph,v,dir=:out,keep=true)  # v 에서 dir 방향으로 뻗는 서브트리의 모든 꼭짓점 집합
	descendants = Set{Int}()                        # 결과 꼭짓점 집합
	for e in edges(bfs_tree(graph,v;dir=dir))       # v 기준 BFS 트리의 엣지들을 순회
		push!(descendants,e.dst)                    # 각 엣지의 도착점을 집합에 추가
	end
	if keep                                         # 시작 꼭짓점 자신도 포함할지
		push!(descendants,v)                        # 포함하면 v 추가
	end
	descendants                                     # 집합 반환
end
collect_subtree(graph,vec::AbstractVector{Int},args...) = collect_subtree(graph,Set{Int}(vec),args...)  # 배열로 주면 집합으로 바꿔 호출
function collect_subtree(graph,starts::Set{Int},dir=:out,keep=true)  # 여러 시작점에서의 서브트리(BFS 직접 구현)
	frontier = Set{Int}(starts)                     # 방문 대기 집합(시작점들로 초기화)
	explored = Set{Int}()                           # 이미 방문한 집합
	# 삼항연산자: dir 이 :out 이면 나가는 이웃 함수, 아니면 들어오는 이웃 함수를 f 로 선택.
	f = dir == :out ? outneighbors : inneighbors    # 탐색 방향에 맞는 이웃 함수 선택
	while !isempty(frontier)                        # 대기 집합이 빌 때까지
		v = pop!(frontier)                          # 하나 꺼내
		push!(explored,v)                           # 방문 처리
		for vp in f(graph,v)                        # 그 이웃들을 보며
			if !(vp in explored)                    # 아직 방문 안 했으면
				push!(frontier,vp)                  # 대기 집합에 추가
			end
		end
	end
	if !(keep == true)                              # 시작점을 결과에서 빼야 하면
		setdiff!(explored,starts)                   # explored 에서 starts 를 제거(차집합, in-place)
	end
	return explored                                 # 방문한 전체 꼭짓점 집합 반환
end

"""
	collect_descendants(graph,v) = collect_subtree(graph,v,:out)
"""
collect_descendants(graph,v,keep=false) = collect_subtree(graph,v,:out,keep)  # v 의 자손 집합(:out 방향, 기본은 자신 제외)
"""
	collect_ancestors(graph,v) = collect_subtree(graph,v,:in)
"""
collect_ancestors(graph,v,keep=false) = collect_subtree(graph,v,:in,keep)  # v 의 조상 집합(:in 방향, 기본은 자신 제외)

"""
	required_predecessors(node)

Identifies the types (and how many) of required predecessors to `node`
Return type: `Dict{DataType,Int}`
"""
# 아래 4개는 본문 없는 함수 선언(인터페이스). 각 노드타입이 "필요/허용되는 앞·뒤 이웃 종류와 개수"를 구현해야 함.
function required_predecessors end                  # 노드에 꼭 필요한 선행(앞) 노드들의 종류·개수 (구현 위임)

"""
	required_successors(node)

Identifies the types (and how many) of required successors to `node`
Return type: `Dict{DataType,Int}`
"""
function required_successors end                    # 꼭 필요한 후행(뒤) 노드들의 종류·개수 (구현 위임)

"""
	eligible_predecessors(node)

Identifies the types (and how many) of eligible predecessors to `node`
Return type: `Dict{DataType,Int}`
"""
function eligible_predecessors end                  # 허용 가능한 선행 노드들의 종류·개수 (구현 위임)

"""
	eligible_successors(node)

Identifies the types (and how many) of eligible successors to `node`
Return type: `Dict{DataType,Int}`
"""
function eligible_successors end                    # 허용 가능한 후행 노드들의 종류·개수 (구현 위임)


"""
	num_required_predecessors(node)

Returns the total number of required predecessors to `node`.
"""
function num_required_predecessors(node)            # 필요한 선행 노드들의 "총 개수"(종류별 개수 합)
	n = 1                                           # 1부터 시작(자기 자신 몫 포함하는 관례로 보임)
	for (key,val) in required_predecessors(node)    # 종류(key)→개수(val) 딕셔너리를 순회
		n += val                                    # 개수를 누적
	end
	n                                               # 합 반환
end

"""
	num_required_successors(node)

Returns the total number of required successors to `node`.
"""
function num_required_successors(node)              # 필요한 후행 노드 총 개수
	n = 1                                           # 1부터 시작
	for (key,val) in required_successors(node)      # 종류→개수 순회
		n += val                                    # 누적
	end
	n                                               # 합 반환
end

"""
	num_eligible_predecessors(node)

Returns the total number of eligible predecessors to `node`.
"""
function num_eligible_predecessors(node)            # 허용 가능한 선행 노드 총 개수
	n = 1                                           # 1부터 시작
	for (key,val) in eligible_predecessors(node)    # 종류→개수 순회
		n += val                                    # 누적
	end
	n                                               # 합 반환
end

"""
	num_eligible_successors(node)

Returns the total number of eligible successors to `node`.
"""
function num_eligible_successors(node)              # 허용 가능한 후행 노드 총 개수
	n = 1                                           # 1부터 시작
	for (key,val) in eligible_successors(node)      # 종류→개수 순회
		n += val                                    # 누적
	end
	n                                               # 합 반환
end

"""
	validate_edge(n1,n2)

For an edge (n1) --> (n2), checks whether the edge is legal and the nodes
"agree".
"""
function validate_edge(a,b)                         # a→b 엣지가 두 노드의 허용규칙상 정당한지 검사
    valid = false                                   # 일단 무효로 시작
    for (key,val) in eligible_successors(a)         # a 가 허용하는 후행 종류들을 보며
        if matches_template(key,b) && val >= 1      # b 가 그 종류에 맞고 개수 여유(>=1)가 있으면
            valid = true                            # a 입장에선 OK
        end
    end
    for (key,val) in eligible_predecessors(b)       # b 가 허용하는 선행 종류들을 보며
        if matches_template(key,a) && val >= 1      # a 가 그 종류에 맞고 여유가 있으면
            valid = valid && true                   # a쪽 OK 이면서 b쪽도 OK (AND)
            return valid                            # 둘 다 만족하면 그 값 반환
        end
    end
    return false                                    # b쪽에서 맞는 게 없으면 무효
end

validate_edge(n1::CustomNode,n2) = validate_edge(node_val(n1),n2)              # n1 이 CustomNode 면 그 값으로 검사
validate_edge(n1::CustomNode,n2::CustomNode) = validate_edge(n1,node_val(n2))  # n2 도 CustomNode 면 그 값으로 검사
# CustomNode 에 대한 4개 인터페이스 함수를 "노드 값으로 위임"하도록 한꺼번에 정의.
for op in [:required_successors,:required_predecessors,:eligible_successors,:eligible_predecessors]
	@eval $op(n::CustomNode) = $op(node_val(n))     # 예: eligible_successors(CustomNode) = eligible_successors(그 값)
end

# extending the validation interface to allow dispatch on graph type
# (graph, node) 처럼 graph 를 앞에 받는 버전도 만들어 둠 — 그래프 정보가 필요 없으면 그냥 node 버전으로 위임.
for op in [
	:required_successors,
	:required_predecessors,
	:eligible_successors,
	:eligible_predecessors,
	:num_required_successors,
	:num_required_predecessors,
	:num_eligible_successors,
	:num_eligible_predecessors,
    ]
	@eval $op(graph,node) = $op(node)               # graph 인자는 무시하고 node 버전 호출
end
for op in [
	:validate_edge,
    ]
	@eval $op(graph,n1,n2) = $op(n1,n2)             # validate_edge 도 graph 인자 추가 버전을 위임
end

function validate_neighborhood(g,v)                 # 꼭짓점 v 의 이웃들이 규칙(필요/허용 종류·개수)을 지키는지 검사
	n = get_node(g,v)                               # v 의 노드
	# try/catch : 예외 처리(파이썬 try/except). 아래 @assert 실패 시 catch 로 잡음.
	try
		# (d, list, required, eligible) 튜플들을 순회 — 나가는 방향(:out)과 들어오는 방향(:in) 두 케이스를 한 번에 처리.
		for (d,list,required,eligible) in [
				(:out,outneighbors(g,v),required_successors(g,n),eligible_successors(g,n)),  # 후행(나가는) 이웃 규칙
				(:in,inneighbors(g,v),required_predecessors(g,n),eligible_predecessors(g,n)),  # 선행(들어오는) 이웃 규칙
			]
			for vp in list                          # 해당 방향의 각 이웃 vp
				np = get_node(g,vp)                 # 이웃 노드
				has_match = false                   # 이 이웃이 어떤 규칙에 매칭됐는지
				for k in keys(required)             # 먼저 "필요" 종류들과 대조
					if matches_template(k,np)       # 이웃이 종류 k 에 맞으면
						required[k] -= 1            # 그 종류 카운트 1 차감(딕셔너리 값 수정)
						@assert required[k] >= 0 "Node $v has too many $(string(d))neighbors of type $k"  # 음수면 너무 많음 → 에러
						has_match = true            # 매칭 성공
						break                       # 더 안 보고 다음 이웃으로
					end
				end
				for k in keys(eligible)             # 필요에서 못 찾았으면 "허용" 종류와 대조
					if matches_template(k,np)       # 종류 k 에 맞으면
						eligible[k] -= 1           # 허용 카운트 차감
						@assert eligible[k] >= 0 "Node $v has too many $(string(d))neighbors of type $k"  # 초과 시 에러
						has_match = true            # 매칭 성공
						break
					end
				end
				@assert has_match "Node $vp should not be an $(string(d))neighbor of node $v"  # 어디에도 안 맞으면 잘못된 이웃
			end
		end
	catch e                                         # 예외가 나면 e 로 받음
		if isa(e,AssertionError)                    # 그게 @assert 실패면
			bt = catch_backtrace()                  # 호출 스택 정보를 얻어
            showerror(stdout,e,bt)                  # 에러 내용을 화면에 출력(중단은 안 함)
		else
			rethrow(e)                              # 다른 종류 예외면 그대로 다시 던짐
		end
		return false                                # 검증 실패
	end
	return true                                     # 모든 이웃이 규칙을 지키면 통과
end

function validate_graph(g::AbstractCustomGraph)     # 그래프 전체(모든 엣지+모든 이웃관계)가 규칙에 맞는지 검사
    try
        for e in edges(g)                           # 모든 엣지 e 에 대해
            node1 = get_node(g,e.src)               # 출발 노드
            node2 = get_node(g,e.dst)               # 도착 노드
            @assert(validate_edge(g,node1,node2), string(" INVALID EDGE: ", string(node1), " --> ",string(node2)))  # 엣지 합법성 검사
        end
        for v in Graphs.vertices(g)                 # 모든 꼭짓점에 대해
			if !validate_neighborhood(g,v)          # 이웃 규칙 검사 실패 시
				return false                        # 전체 무효
			end
        end
    catch e                                         # 예외 처리
        if typeof(e) <: AssertionError              # @assert 실패면
            bt = catch_backtrace()                  # 스택 정보
            showerror(stdout,e,bt)                  # 에러 출력
        else
            rethrow(e)                              # 그 외 예외는 다시 던짐
        end
        return false                                # 실패
    end
    return true                                     # 전부 통과하면 유효
end

abstract type AbstractBFSIterator end               # 너비우선(BFS) 반복자들의 공통 추상 타입

# 아래 Base.* 메서드들은 줄리아의 "이터레이터 프로토콜"을 우리 BFS 반복자에 구현(파이썬 __iter__/__next__ 와 유사).
Base.IteratorSize(::AbstractBFSIterator) = Base.SizeUnknown()      # 미리 길이를 알 수 없음(동적으로 끝남)
Base.IteratorEltype(::AbstractBFSIterator) = Base.HasEltype()      # 원소 타입은 정해져 있음
Base.eltype(::AbstractBFSIterator) = Int                           # 원소 타입은 정수(꼭짓점 번호)
# Base.iterate : for 루프가 매 단계 호출하는 함수. (다음값, 다음상태)를 반환하거나, 끝이면 nothing 반환.
function Base.iterate(iter::AbstractBFSIterator,v=nothing)
	if !(v === nothing)                             # 첫 호출이 아니면(직전에 낸 값 v 가 있으면)
		update_iterator!(iter,v)                    # 그 v 를 기준으로 다음 프런티어를 갱신
	end
	if isempty(iter)                                # 더 낼 게 없으면
		return nothing                              # 반복 종료 신호
	end
	vp = pop!(iter)                                 # 다음 꼭짓점 하나 꺼냄
	return vp, vp                                   # (낼 값, 다음 상태)로 둘 다 vp 반환
end

# 구체 BFS 반복자. {G} 는 바탕 그래프 타입. @with_kw 로 각 필드에 기본값(필드끼리 참조 가능: frontier 가 graph 사용).
@with_kw struct BFSIterator{G} <: AbstractBFSIterator
	graph::G 				= Graphs.DiGraph()      # 탐색할 그래프
	frontier::Set{Int} 		= get_all_root_nodes(graph)  # 현재 단계에서 방문할 꼭짓점들(기본: 뿌리들)
	next_frontier::Set{Int}	= Set{Int}()            # 다음 단계 꼭짓점들을 모아두는 곳
	explored::Vector{Bool}  = _indicator_vec(nv(graph),frontier)  # 방문 표시 불리언 배열(frontier 위치를 true 로 시작)
	replace::Bool			= false # if true, allow nodes to reused  # true 면 이미 방문한 노드도 다시 큐에 넣음
end
BFSIterator(graph) = BFSIterator(graph=graph)                          # 그래프만으로 생성하는 편의 생성자
BFSIterator(graph,frontier) = BFSIterator(graph=graph,frontier=frontier)  # 시작 프런티어도 지정하는 생성자
Base.pop!(iter::BFSIterator) = pop!(iter.frontier)                    # 다음 꼭짓점은 프런티어 집합에서 하나 꺼냄
Base.isempty(iter::BFSIterator) = isempty(iter.frontier)              # 프런티어가 비면 반복 끝
function update_iterator!(iter::BFSIterator,v)                        # v 를 처리한 뒤 다음 프런티어 준비
	iter.explored[v] = true                          # v 방문 표시
	for vp in outneighbors(iter.graph,v)             # v 의 나가는 이웃들
		if iter.replace || !iter.explored[vp]        # 재방문 허용이거나 아직 방문 안 했으면
			push!(iter.next_frontier,vp)             # 다음 프런티어에 추가
			iter.explored[vp] = true                 # 미리 방문 표시(중복 추가 방지)
		end
	end
	if isempty(iter.frontier)                        # 현재 프런티어를 다 비웠으면(이번 레벨 끝)
		union!(iter.frontier, iter.next_frontier)    # 다음 프런티어를 현재로 합침(union!=합집합 in-place)
		empty!(iter.next_frontier)                   # 다음 프런티어 비우기
	end
end

# 정렬된 BFS 반복자. 프런티어를 Set 대신 Vector 로 두어 "번호 순서"를 유지(작은 번호부터 꺼냄).
@with_kw struct SortedBFSIterator{G} <: AbstractBFSIterator
	graph::G 				= Graphs.DiGraph()      # 탐색할 그래프
	frontier::Vector{Int}   = sort(collect(get_all_root_nodes(graph)))  # 시작 프런티어(뿌리들을 정렬한 배열)
	next_frontier::Vector{Int} = Vector{Int}()      # (이 구현에선 사실상 미사용) 다음 프런티어 버퍼
	explored::Vector{Bool}  = _indicator_vec(nv(graph),frontier)  # 방문 표시 배열
	replace::Bool			= false # if true, allow nodes to reused  # 재방문 허용 여부
end
SortedBFSIterator(graph) = SortedBFSIterator(graph=graph)                          # 그래프만으로 생성
SortedBFSIterator(graph,frontier) = SortedBFSIterator(graph=graph,frontier=frontier)  # 시작 프런티어 지정 생성
function Base.pop!(iter::SortedBFSIterator)          # 다음 꼭짓점 꺼내기
	v = popfirst!(iter.frontier)                     # 배열 맨 앞 원소를 꺼냄(popfirst!=앞에서 제거, FIFO 큐처럼)
end
Base.isempty(iter::SortedBFSIterator) = isempty(iter.frontier)  # 프런티어가 비면 끝
function update_iterator!(iter::SortedBFSIterator,v)  # v 처리 후 이웃을 프런티어 뒤에 붙임
	iter.explored[v] = true                          # v 방문 표시
	for vp in outneighbors(iter.graph,v)             # v 의 나가는 이웃들
		if iter.replace || !iter.explored[vp]        # 재방문 허용 또는 미방문이면
			push!(iter.frontier,vp)                  # 프런티어 끝에 추가
			iter.explored[vp] = true                 # 방문 표시
		end
	end
end
