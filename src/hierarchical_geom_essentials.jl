
# ============================================================================
#  이 파일은 HierarchicalGeometry 라이브러리에서 가져온 "계층적 기하(hierarchical geometry)"
#  유틸리티 모음 — 로봇/부품/조립체의 형상(geometry), 위치·회전(transform), 충돌용 근사도형,
#  그리고 이들을 부모-자식으로 엮는 SceneTree(장면 트리)를 다룬다.
#  프로젝트 역할: 다중로봇 건설 TAMP 시뮬레이터가 "무엇이 어디에 어떤 자세로 있는가"와
#   "무엇이 무엇을 감싸는가(bounding volume)"를 계산·관리하는 기반 자료구조·연산을 제공.
#  큰 그림(핵심 3덩어리):
#   1) transform 계산 : 좌표계 사이 상대/절대 변환, 회전 보간, 항등변환 등.
#   2) 트리 노드 : TransformNode(위치캐시) → GeomNode(형상) → SceneNode(로봇/부품/조립체/운반팀) → SceneTree.
#   3) bounding volume 근사 : 형상을 구(sphere)/직육면체(hyperrectangle)/원기둥 등 단순도형으로 over-근사.
#  Julia 문법 참고:
#   · function f(x::T) ... end 또는 f(x::T) = ... : x 가 타입 T 일 때만 적용되는 메서드(다중 디스패치).
#     같은 이름을 인자 타입만 바꿔 여러 번 정의 = "타입마다 다른 동작"(파이썬엔 없는 개념).
#   · ::Type{S} : "값"이 아니라 "타입 그 자체"를 인자로 받음(주로 변환·근사 목표 타입 지정에 사용).
#   · (t::LinearMap)(g) : 객체를 "함수처럼 호출"하는 정의(호출연산자 오버로드) — 변환을 형상에 적용.
#   · :symbol / :(A.B) : 코드(이름)를 값으로 다룸. for T in (...) @eval ... : 여러 타입에 같은 메서드를
#     한꺼번에 찍어내는 "코드 생성" 기법($T 로 타입을 코드에 끼워넣음).
#   · `!` 로 끝나는 함수 = 인자/상태를 직접 수정(in-place)한다는 관례. `∘` = 함수 합성(수학 f∘g).
#   · [f(x) for x in xs] = 컴프리헨션(comprehension, 파이썬과 동일). `.` 연산(예: `.+`, `max.`) = 원소별 계산.
#   · 기하/변환 용어(HierarchicalGeometry, GeometryBasics, transform, bounding volume, hyperrectangle,
#     sphere 등)는 원어 그대로 두고 한국어로 "설명만" 덧붙였다.
# ============================================================================

# global 변수 : 모듈 전체에서 공유되는 "전역 변수". 함수 안에서 바꾸려면 다시 `global` 키워드로 표시해야 함.
global DEFAULT_GEOM_OPTIMIZER = nothing   # 기하 계산에 쓸 기본 최적화 솔버(처음엔 비어있음/nothing)
# Dict{키타입, 값타입}() : 빈 딕셔너리. 키는 "문자열 또는 솔버속성", 값은 Any(아무 타입). 솔버 옵션 저장용.
global DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES = Dict{Union{String,MOI.AbstractOptimizerAttribute},Any}()

"""
    default_geom_optimizer()

Returns the black box optimizer to use when formulating JuMP models.
"""
# `f() = 값` : 한 줄짜리 함수 정의(축약형). 현재 설정된 기본 솔버를 그냥 돌려줌.
default_geom_optimizer() = DEFAULT_GEOM_OPTIMIZER

"""
    set_default_geom_optimizer!(optimizer)

Set the black box optimizer to use when formulating JuMP models.
"""
# 이름 끝 `!` = 전역 상태를 바꾸는 함수(관례). 기본 솔버를 새로 지정.
function set_default_geom_optimizer!(optimizer)
    global DEFAULT_GEOM_OPTIMIZER = optimizer   # 전역변수에 새 솔버 대입(함수 안이라 global 명시 필요)
end


"""
    default_geom_optimizer_attributes()

Return a dictionary of default optimizer attributes.
"""
# 현재 저장된 솔버 옵션 딕셔너리를 그대로 반환.
default_geom_optimizer_attributes() = DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES

"""
    set_default_geom_optimizer_attributes!(vals)

Set default optimizer attributes.
e.g. `set_default_geom_optimizer_attributes!(Dict("PreSolve"=>-1))`
"""
# pair::Pair : "키=>값" 하나. pairs... 의 `...` = "나머지 인자 전부를 묶어 받음"(파이썬 *args). 재귀로 하나씩 처리.
function set_default_geom_optimizer_attributes!(pair::Pair, pairs...)
    push!(DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES, pair)   # 옵션 딕셔너리에 키=>값 추가
    set_default_geom_optimizer_attributes!(pairs...)  # 남은 인자들로 자기 자신 재호출(다 떨어질 때까지)
end
# 딕셔너리 하나로 부르면 d... 로 펼쳐서 각 키=>값을 위 함수로 넘김.
set_default_geom_optimizer_attributes!(d::Dict) = set_default_geom_optimizer_attributes!(d...)
# 인자가 하나도 없을 때(재귀 종료 지점) — 아무것도 안 하고 끝냄.
set_default_geom_optimizer_attributes!() = nothing

"""
    clear_default_geom_optimizer_attributes!()

Clear the default optimizer attributes.
"""
# 솔버 옵션 딕셔너리를 통째로 비움(empty! = 안의 원소를 모두 제거).
function clear_default_geom_optimizer_attributes!()
    empty!(DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES)
end

# const 이름 = 타입 : "이 이름은 항상 이 타입을 가리킨다"는 별칭(상수). 긴 타입 이름을 짧게 부르려는 용도.
# BaseGeometry : 공/직육면체/볼록다면체 중 아무거나 = "기본 도형 타입들의 묶음".
const BaseGeometry = Union{LazySets.Ball2,Hyperrectangle,AbstractPolytope}
const BallType = LazySets.Ball2   # 구(공) 타입의 짧은 별칭
# get_center / get_radius : 도형 종류별로 "중심점"과 "반지름"을 꺼내는 함수(타입마다 따로 정의 = 다중 디스패치).
get_center(s::LazySets.Ball2) = LazySets.center(s)   # Ball2(구)의 중심
get_radius(s::LazySets.Ball2) = s.radius             # Ball2의 반지름(필드 직접 접근, 파이썬 s.radius 와 동일)
get_center(s::GeometryBasics.HyperSphere) = s.center # HyperSphere(구)의 중심
get_radius(s::GeometryBasics.HyperSphere) = s.r      # HyperSphere의 반지름
# GeometryBasics.Sphere(...) : LazySets 의 공을 GeometryBasics 의 구 타입으로 변환하는 생성자. s.center... 로 좌표 펼침.
GeometryBasics.Sphere(s::LazySets.Ball2) = GeometryBasics.Sphere(GeometryBasics.Point(s.center...), s.radius)
# Base.convert : 줄리아의 표준 "타입 변환" 함수에 우리 규칙 추가. ::Type{S} 는 변환할 목표 타입(값 아님). where {S<:...} 로 S 제한.
Base.convert(::Type{S}, s::LazySets.Ball2) where {S<:GeometryBasics.HyperSphere} = S(GeometryBasics.Point(s.center...), s.radius)
const RectType = Hyperrectangle   # 직육면체 타입의 짧은 별칭
get_center(s::Hyperrectangle) = s.center   # 직육면체의 중심
get_radius(s::Hyperrectangle) = s.radius   # 직육면체의 반쪽 크기(각 축 방향 반지름)
# Hyperrectangle 을 GeometryBasics 의 사각박스로 변환. `.-` 는 원소별 뺄셈(중심-반지름=한쪽 구석), 2*반지름=전체 크기.
GeometryBasics.HyperRectangle(s::Hyperrectangle) = GeometryBasics.HyperRectangle(GeometryBasics.Vec((s.center .- s.radius)...), 2 * GeometryBasics.Vec(s.radius...))


# 기본 로봇 형상 = 원기둥(Cylinder). 바닥점(0,0,0)부터 윗점(0,0,0.25)까지, 반지름 0.5. Point{3,Float64}=3D 실수좌표.
global DEFAULT_ROBOT_GEOM = GeometryBasics.Cylinder(
    GeometryBasics.Point{3,Float64}(0.0, 0.0, 0.0),    # 원기둥 바닥 중심 좌표
    GeometryBasics.Point{3,Float64}(0.0, 0.0, 0.25),   # 원기둥 윗면 중심 좌표(높이 0.25)
    0.5                                                # 반지름
)
"""
    default_robot_geom()

Get the default robot geometry.
"""
# 현재 설정된 기본 로봇 형상을 그대로 반환.
default_robot_geom() = DEFAULT_ROBOT_GEOM
"""
    set_default_robot_geom!(geom)

Set the default robot geometry.
"""
# 기본 로봇 형상을 새로 지정(! = 전역 상태 변경).
function set_default_robot_geom!(geom)
    global DEFAULT_ROBOT_GEOM = geom
end

# 기본 로봇 반지름을 구함. isa(...) = 타입 검사(파이썬 isinstance).
function default_robot_radius()
    geom = default_robot_geom()                 # 현재 로봇 형상 가져오기
    if isa(geom, GeometryBasics.Cylinder)       # 원기둥이면
        return geom.r                           # 원기둥의 반지름 필드 반환
    else
        return 0.25                             # 원기둥이 아니면 기본값 0.25
    end
end
# 기본 로봇 높이를 구함.
function default_robot_height()
    geom = default_robot_geom()
    if isa(geom, GeometryBasics.Cylinder)       # 원기둥이면
        return norm(geom.origin - geom.extremity)  # 바닥점-윗점 벡터의 길이(norm=벡터 크기) = 높이
    else
        return 0.1                              # 아니면 기본값 0.1
    end
end

# Z축을 버리는 "2D 투영 행렬"(2x3). 3D점 (x,y,z)에 곱하면 (x,y)만 남음. SMatrix=크기고정 행렬. 값은 열 우선으로 채움.
const Z_PROJECTION_MAT = SMatrix{2,3,Float64}(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

"""
    project_to_2d(geom,t=CoordinateTransformations.LinearMap(Z_PROJECTION_MAT)) = t(geom)
"""
# 3D 형상을 2D(바닥 평면)로 투영. LinearMap(행렬) 은 "행렬을 곱하는 변환"을 만들고, t(geom) 으로 형상에 적용.
project_to_2d(geom, t=CoordinateTransformations.LinearMap(Z_PROJECTION_MAT)) = t(geom)

"""
    project_to_3d(geom,t=CoordinateTransformations.LinearMap(transpose(Z_PROJECTION_MAT))) = t(geom)
"""
# 2D 형상을 다시 3D 로 되돌림(z=0 평면에 얹음). transpose = 행렬 전치(투영행렬의 반대 모양).
project_to_3d(geom, t=CoordinateTransformations.LinearMap(transpose(Z_PROJECTION_MAT))) = t(geom)

"""
    transform(geom,t)

Transform geometry `geom` according to the transformation `t`.
"""
# 변환 t 를 형상 v 에 적용. CoordinateTransformations 의 변환객체는 "함수처럼 호출"되므로 t(v) 가 곧 변환 결과.
transform(v, t) = t(v)
# (t::Translation)(g) : "평행이동 변환을 함수처럼 호출"하는 정의. 도형 g 를 t.translation 만큼 옮김(LazySets.translate 사용).
(t::CoordinateTransformations.Translation)(g::BaseGeometry) = LazySets.translate(g, Vector(t.translation))

"""
    (t::CoordinateTransformations.LinearMap)(g::Hyperrectangle)

"rotating" a Hyperrectangle `g` results in a new Hyperrectangle that bounds the
transformed version `g`.
"""
# 직육면체를 회전(LinearMap)하면 축에 안 맞게 기울어짐 → 기울어진 모양을 감싸는 새 직육면체로 근사(overapproximate).
# 먼저 직육면체를 꼭짓점 다면체(VPolytope)로 바꿔 회전한 뒤, 다시 직육면체로 over-근사.
(t::CoordinateTransformations.LinearMap)(g::Hyperrectangle) = overapproximate(t(convert(LazySets.VPolytope, g)), Hyperrectangle)
# AffineMap(회전+이동)도 마찬가지로 처리.
(t::CoordinateTransformations.AffineMap)(g::Hyperrectangle) = overapproximate(t(convert(LazySets.VPolytope, g)), Hyperrectangle)
# 평행이동만이면 모양이 안 바뀌므로, 중심만 옮기고 반지름은 그대로 둔 직육면체 반환.
(t::CoordinateTransformations.Translation)(g::Hyperrectangle) = Hyperrectangle(t(g.center), g.radius)

# 아래 for+@eval 는 "같은 메서드들을 여러 변환 타입에 대해 한꺼번에 정의"하는 코드 생성 기법.
# T 에 타입 이름(심볼 :(...))을 하나씩 대입하고, @eval 이 그 자리에서 실제 코드로 펼침. $T 는 T 값을 코드에 끼워넣기.
for T in (
    :(CoordinateTransformations.AffineMap),   # 여기선 AffineMap(회전+이동) 한 가지에 대해
)
    @eval begin
        # 다각형(Ngon) 배열에 변환 적용: 각 원소에 t 를 map 으로 적용해 같은 타입 V 로 다시 묶음.
        (t::$T)(v::V) where {N<:GeometryBasics.Ngon,V<:AbstractVector{N}} = V(map(t, v))
        # 원기둥: 바닥점/윗점만 변환하고 반지름 r 은 유지.
        (t::$T)(g::C) where {C<:GeometryBasics.Cylinder} = C(t(g.origin), t(g.extremity), g.r)
        (t::$T)(g::VPolytope) = VPolytope(map(t, vertices_list(g)))    # 꼭짓점다면체: 모든 꼭짓점을 변환
        (t::$T)(g::HPolytope) = HPolytope(map(t, constraints_list(g)))  # 반평면다면체: 각 제약(면)을 변환
        (t::$T)(g::VPolygon) = VPolytope(map(t, vertices_list(g)))      # 꼭짓점다각형 → 다면체로 변환
        (t::$T)(g::HPolygon) = HPolytope(map(t, constraints_list(g)))   # 반평면다각형 → 다면체로 변환
        # (t::$T)(g::BufferedPolygon) = ...                            # (주석처리된 옛 코드)
        # (t::$T)(g::BufferedPolygonPrism) = ...                       # (주석처리된 옛 코드)
        (t::$T)(::Nothing) = nothing                                   # 형상이 없으면(nothing) 변환해도 nothing
        (t::$T)(g::LazySets.Ball2) = LazySets.Ball2(t(g.center), g.radius)  # 공: 중심만 변환, 반지름 유지
    end
end

# 위와 같은 메서드들을 LinearMap(회전만)과 Translation(이동만) 두 타입에 대해 정의.
for T in (
    :(CoordinateTransformations.LinearMap),
    :(CoordinateTransformations.Translation),
)
    @eval begin
        (t::$T)(v::V) where {N<:GeometryBasics.Ngon,V<:AbstractVector{N}} = V(map(t, v))   # 다각형 배열 변환
        (t::$T)(g::G) where {G<:GeometryBasics.Ngon} = G(map(t, g.points))                 # 다각형 한 개: 꼭짓점들 변환
        (t::$T)(g::C) where {C<:GeometryBasics.Cylinder} = C(t(g.origin), t(g.extremity), g.r)  # 원기둥 변환
        (t::$T)(g::VPolytope) = VPolytope(map(t, vertices_list(g)))
        (t::$T)(g::HPolytope) = HPolytope(map(t, constraints_list(g)))
        (t::$T)(g::VPolygon) = VPolytope(map(t, vertices_list(g)))
        (t::$T)(g::HPolygon) = HPolytope(map(t, constraints_list(g)))
        # (t::$T)(g::BufferedPolygon) = ...
        # (t::$T)(g::BufferedPolygonPrism) = ...
        (t::$T)(::Nothing) = nothing
        (t::$T)(g::LazySets.Ball2) = LazySets.Ball2(t(g.center), g.radius)
    end
end

# 항등변환(아무것도 안 바꾸는 변환) 만들기. zero(SVector)=영벡터(이동 0), one(SMatrix)=단위행렬(회전 0). compose 로 둘을 합성.
identity_linear_map3() = CoordinateTransformations.compose(CoordinateTransformations.Translation(zero(SVector{3,Float64})), CoordinateTransformations.LinearMap(one(SMatrix{3,3,Float64})))
identity_linear_map2() = CoordinateTransformations.compose(CoordinateTransformations.Translation(zero(SVector{3,Float64})), CoordinateTransformations.LinearMap(one(SMatrix{3,3,Float64})))
identity_linear_map() = identity_linear_map3()   # 기본 항등변환은 3D 버전
# 크기조절 변환: 단위행렬에 scale 을 곱해 "scale 배 확대/축소"하는 변환. `∘` 는 함수 합성(수학의 합성기호, f∘g).
scaled_linear_map(scale) = CoordinateTransformations.LinearMap(scale * one(SMatrix{3,3,Float64})) ∘ identity_linear_map()
# Hyperrectangle 의 좌표 타입을 T 로 통일해 변환하는 convert 메서드.
Base.convert(::Type{Hyperrectangle{Float64,T,T}}, rect::Hyperrectangle) where {T} = Hyperrectangle(T(rect.center), T(rect.radius))

"""
    relative_transform(a::AffineMap,b::AffineMap)

compute the relative transform `t` between two frames, `a`, and `b` such that
    t = inv(a) ∘ b
    b = a ∘ t
    a = b ∘ inv(t)

    i.e. (a ∘ t)(p) == a(t(p)) == b(p)
"""
# 두 좌표계 a,b 사이의 "상대 변환" = inv(a)∘b. 즉 a 기준에서 b 가 어디에 있는지(a 를 되돌리고 b 를 적용). inv=역변환.
relative_transform(a::A, b::B) where {A<:CoordinateTransformations.Transformation,B<:CoordinateTransformations.Transformation} = inv(a) ∘ b

# Rotations.rotation_error : 두 회전 사이의 "각도 오차"를 구하는 함수에 AffineMap 용 메서드 추가.
function Rotations.rotation_error(
    a::CoordinateTransformations.AffineMap,    # 변환 a (회전+이동) — 회전 부분만 사용
    b::CoordinateTransformations.AffineMap,    # 변환 b
    error_map=MRPMap())                        # 오차를 표현하는 방식(기본 MRPMap)
    rot_err = Rotations.rotation_error(
        Rotations.QuatRotation(a.linear),      # a 의 회전행렬(.linear)을 쿼터니언으로 변환
        Rotations.QuatRotation(b.linear), error_map)  # b 도 마찬가지로 → 둘의 회전 오차 계산
end
# relative_transform 과 rotation_error 두 함수에, "트리+노드" 또는 "노드 두 개"를 받는 편의 메서드를 한꺼번에 정의.
for op in (:relative_transform, :(Rotations.rotation_error))
    # 트리와 부모/자식 정점을 주면, 각자의 전역변환(global_transform)을 구해 위 함수에 넘김.
    @eval $op(tree::AbstractCustomTree, parent, child, args...) = $op(
        global_transform(tree, parent),
        global_transform(tree, child),
        args...
    )
    # 노드 객체 두 개를 주면, 각 노드의 전역변환을 구해 넘김.
    @eval $op(parent, child, args...) = $op(
        global_transform(parent),
        global_transform(child),
        args...
    )
end

"""
    interpolate_rotation(Ra,Rb,c=0.5)

compute a rotation matrix `ΔR` such that `Ra*ΔR` is c/1.0 of the way to `Rb`.
    R = R⁻¹ Rb
    θ = axis + magnitude representation
    ΔR = exp(cross_product_operator(θ)*c)
"""
# 회전 Ra 에서 Rb 까지 c 비율(0~1)만큼 "사이 회전"을 구함(보간). c=0.5 면 중간 회전.
function interpolate_rotation(Ra, Rb, c=0.5)
    R = inv(Ra) * Rb                              # Ra 에서 Rb 로 가는 차이 회전
    r = Rotations.RotationVec(R) # rotation vector  # 그 회전을 "축*각도" 벡터 표현으로 변환
    Rotations.RotationVec(r.sx * c, r.sy * c, r.sz * c)  # 각 성분에 c 를 곱해 회전량을 c 배로 줄인 회전 반환
end
# 변환 Ta 에서 Tb 까지 c 비율만큼 보간(회전과 이동을 따로 보간해 합침).
function interpolate_transforms(Ta, Tb, c=0.5)
    R = interpolate_rotation(Ta.linear, Tb.linear, c)         # 회전 부분 보간
    t = (1 - c) * Ta.translation + c * Tb.translation         # 이동 부분은 선형 보간((1-c)·시작 + c·끝)
    CoordinateTransformations.Translation(t) ∘ CoordinateTransformations.LinearMap(R)  # 이동+회전 합쳐 새 변환 생성
end

# 변환 노드를 가리키는 ID 타입(정수 하나를 감쌈). 기본값 -1(아직 미지정).
@with_kw struct TransformNodeID <: AbstractID
    id::Int = -1
end

"""
    TransformNode

Has a parent field that points to another TransformNode.
"""
# mutable struct : "내용을 바꿀 수 있는 구조체"(보통 struct 는 한번 만들면 불변). 노드끼리 부모/자식으로 엮여 트리를 이룸.
# <: CachedTreeNode{...} : "캐시 기능이 있는 트리 노드"의 하위 타입. 전역변환을 매번 다시 계산 않고 캐싱함.
# 핵심 개념: 각 노드는 "부모 기준 상대 위치(local)"를 갖고, 거기서 "절대 위치(global)"를 계산해 캐시에 저장.
mutable struct TransformNode <: CachedTreeNode{TransformNodeID}
    id::TransformNodeID                                            # 이 노드의 고유 ID
    local_transform::CoordinateTransformations.Transformation # transform from the parent frame to the child frame  # 부모→자식 상대 변환
    global_transform::CachedElement{CoordinateTransformations.Transformation}  # 절대(전역) 변환 — 캐시로 보관
    parent::TransformNode # parent node                           # 부모 노드(자기 자신을 가리키면 루트)
    children::Dict{AbstractID,CachedTreeNode}                     # 자식 노드들(ID→노드 딕셔너리)
    # 내부 생성자: 상대변환 a 와 전역변환 캐시 b 를 받아 노드를 만든다.
    function TransformNode(
        a::CoordinateTransformations.Transformation,
        b::CachedElement)
        t = new()                                # new() : 필드 미지정 빈 객체 생성(아래에서 하나씩 채움)
        t.id = get_unique_id(TransformNodeID)    # 새 고유 ID 발급
        t.local_transform = a                    # 상대변환 설정
        t.global_transform = b                   # 전역변환 캐시 설정
        t.parent = t                             # 부모를 자기 자신으로(=처음엔 루트)
        t.children = Dict{AbstractID,CachedTreeNode}()  # 자식은 빈 딕셔너리로 시작
        return t
    end
end
# 인자 없는 생성자: 항등변환(원점, 회전 없음)으로 초기화한 노드를 만든다.
function TransformNode()
    TransformNode(identity_linear_map(), CachedElement(identity_linear_map()))
end

# Base.show : 객체를 화면/REPL 에 어떻게 보여줄지 정의(파이썬의 __repr__/__str__). ::MIME"text/plain" 은 상세 출력용.
Base.show(io::IO, ::MIME"text/plain", m::TransformNode) = print(
    io, "TransformNode(", get_id(node_id(m)), ")\n",   # 헤더 줄: 노드 ID
    "  local:  ", local_transform(m), "\n",            # 상대변환 출력
    "  global: ", global_transform(m), "\n",           # 전역변환 출력
    "  parent: ", string(node_id(m.parent)), "\n",     # 부모 ID 출력
    "  children: ", map(k -> string("\n    ", string(k)), collect(keys(get_children(m))))..., "\n",  # 자식 ID 들을 줄바꿈해 나열
)
# 간단(한 줄) 출력 버전.
Base.show(io::IO, m::TransformNode) = print(io, "TransformNode(", get_id(node_id(m)), ") - ", m.global_transform)

# Cached Tree interface  (아래는 "캐시 트리 노드"가 갖춰야 할 표준 함수들을 TransformNode 용으로 구현)
cached_element(n::TransformNode) = n.global_transform                 # 캐시되는 요소 = 전역변환
tf_up_to_date(n::TransformNode) = cached_node_up_to_date(n)           # 캐시가 최신인지(다시 계산 불필요한지) 여부
set_tf_up_to_date!(n::TransformNode, val=true) = set_cached_node_up_to_date!(n, val)  # 최신 여부 플래그 설정
local_transform(n::TransformNode) = n.local_transform                # 상대변환 꺼내기
set_global_transform!(n::TransformNode, t, args...) = update_element!(n, t, args...)  # 전역변환 캐시 갱신
global_transform(n::TransformNode) = get_cached_value!(n)             # 전역변환 얻기(필요하면 재계산 후 캐시)
# propagate_forward! : 부모의 전역변환으로부터 자식의 전역변환을 계산해 내려보냄(트리 위→아래 갱신).
function propagate_forward!(parent::TransformNode, child::TransformNode)
    if parent === child                                         # 부모가 자기 자신이면(루트면)
        set_global_transform!(child, local_transform(child))    # 전역 = 상대 그대로
    else
        set_global_transform!(child, global_transform(parent) ∘ local_transform(child))  # 전역 = 부모전역 ∘ 자기상대
    end
    global_transform(child)                                     # 갱신된 전역변환 반환
end
# 노드의 상대변환을 새로 설정. update=true 면 즉시 전역변환도 다시 계산.
function set_local_transform!(n::TransformNode, t, update=false)
    n.local_transform = t ∘ identity_linear_map() # guarantee AffineMap?  # 항등변환과 합성해 AffineMap 형태로 보장
    set_tf_up_to_date!(n, false)                               # 상대가 바뀌었으니 캐시는 "구식"으로 표시
    if update
        global_transform(n) # just get the global transform   # 곧바로 전역변환 재계산(캐시 갱신)
    end
    return n.local_transform
end
# "전역 좌표계 기준의 변환 t" 를 주면, 부모 회전을 고려해 올바른 상대변환으로 바꿔 설정.
function set_local_transform_in_global_frame!(n::TransformNode, t, args...)
    rot_mat = CoordinateTransformations.LinearMap(global_transform(get_parent(n)).linear)  # 부모의 회전 부분만 추출
    set_local_transform!(n, inv(rot_mat) ∘ t)                  # 부모 회전을 되돌린 뒤 t 적용 → 상대변환으로
end

export set_desired_global_transform!   # 이 함수를 모듈 밖에 공개
"""
    set_desired_global_transform!(n::TransformNode,t,args...)

Set a transform node's global local transform such that its global transform
(respecting it's current parent) will be `t`.
"""
# 노드 n 의 "절대 위치"가 t 가 되도록 상대변환을 역산해 설정.
function set_desired_global_transform!(n::TransformNode, t, args...)
    if has_parent(n, n)                                # 부모가 자기 자신이면(루트면)
        set_local_transform!(n, t)                     # 상대 = 절대(t) 그대로
    else
        parent = get_parent(n)                         # 부모 노드
        tform = relative_transform(global_transform(parent), t)  # 부모 절대 기준 t 까지의 상대변환 계산
        set_local_transform!(n, tform)                 # 그 상대변환을 설정
    end
end
# 아래 두 const 는 "접근(읽기) 함수 이름 목록"과 "변경(쓰기) 함수 이름 목록". 뒤에서 for+@eval 로 일괄 메서드 생성에 쓰임.
const transform_node_accessor_interface = [:tf_up_to_date, :local_transform, :global_transform]
const transform_node_mutator_interface = [:set_tf_up_to_date!, :set_local_transform!, :set_global_transform!, :set_local_transform_in_global_frame!, :set_desired_global_transform!]

export set_desired_global_transform_without_affecting_children!   # 공개
"""
    set_desired_global_transform_without_affecting_children!()
"""
# 노드 n 을 원하는 절대위치 t 로 옮기되, 자식들의 절대위치는 그대로 유지되게 한다(자식이 부모 따라 안 끌려가게).
function set_desired_global_transform_without_affecting_children!(n::TransformNode, t, args...)
    tf_dict = Dict{TransformNodeID,CoordinateTransformations.AffineMap}()  # 자식들의 현재 절대위치를 백업할 딕셔너리
    child_dict = get_children(n)                       # n 의 자식들
    for (id, c) in child_dict                          # 각 자식의
        tf_dict[id] = global_transform(c)              # 현재 절대위치를 기록
    end
    set_desired_global_transform!(n, t, args...)       # n 을 원하는 위치로 이동(이때 자식들도 함께 끌려감)
    for (id, tf) in tf_dict                            # 백업해 둔 절대위치로
        set_desired_global_transform!(child_dict[id], tf)  # 각 자식을 원위치로 되돌림
    end
    global_transform(n)                                # n 의 최종 절대위치 반환
end

"""
    rem_parent!(child::TransformNode)

Ensure that the detached child does not "jump" in the global frame when detached
from the parent.
"""
# 자식을 부모에서 떼어낼 때, 절대 위치가 갑자기 바뀌지(점프하지) 않도록 처리.
function rem_parent!(child::TransformNode)
    tf = global_transform(child)                       # 떼기 전 현재 절대위치 저장
    delete!(get_children(get_parent(child)), node_id(child))  # 부모의 자식 목록에서 이 자식 제거
    set_local_transform!(child, tf)                    # 상대변환을 절대위치 그대로 설정(이제 루트가 되므로 상대=절대)
    child.parent = child                               # 부모를 자기 자신으로(루트화)
end

# 접근 함수들에 "트리+정점" 또는 "트리+노드"를 받는 편의 메서드를 일괄 생성.
for op in transform_node_accessor_interface
    @eval $op(tree::AbstractCustomTree, v) = $op(get_node(tree, v))      # 정점 v → 노드를 찾아 호출
    @eval $op(tree::AbstractCustomTree, n::TransformNode) = $op(n)       # 노드 직접 호출
end
# 변경 함수들에도 같은 식으로 편의 메서드 일괄 생성(추가 인자 args... 포함).
for op in transform_node_mutator_interface
    @eval $op(tree::AbstractCustomTree, v, args...) = $op(get_node(tree, v), args...)
    @eval $op(tree::AbstractCustomTree, n::TransformNode, args...) = $op(n, args...)
end

"""
    set_child!(tree,parent,child,new_local_transform)

Replace existing edge `old_parent` → `child` with new edge `parent` → `child`.
Set the `child.local_transform` to `new_local_transform`.
"""
# 트리에서 parent→child 엣지를 설정(기존 부모 엣지는 떼고 새로 연결). t 는 새 상대변환(기본값=현재 상대변환 유지).
function set_child!(tree::AbstractCustomTree, parent, child,
    t=relative_transform(tree, parent, child),   # 기본 상대변환: 현재 부모-자식 상대 위치
    edge=nothing                                 # 엣지에 붙일 부가정보(없으면 nothing)
)
    Graphs.rem_edge!(tree, get_parent(tree, child), child)   # child 의 기존 부모와의 엣지 제거
    if Graphs.add_edge!(tree, parent, child, edge)           # 새 parent→child 엣지 추가 성공하면
        set_parent!(get_node(tree, child), get_node(tree, parent)) # for TransformNode  # 변환노드 레벨에서도 부모 설정
        @assert !Graphs.is_cyclic(tree) "adding edge $(parent) → $(child) made tree cyclic"  # 순환(사이클) 안 생겼는지 점검
        set_local_transform!(tree, child, t)                 # child 의 상대변환을 t 로 설정
        return true                                          # 성공
    end
    return false                                             # 엣지 추가 실패
end
const transform_tree_mutator_interface = [:set_local_transform!, :set_global_transform!]  # (다른 곳에서 쓰일 함수 이름 목록)
# 새 노드를 추가하고 곧바로 parent 의 자식으로 연결. 연결 실패하면 추가한 노드를 도로 제거.
function add_child!(tree::AbstractCustomTree, parent, child, child_id)
    n = add_node!(tree, child, child_id)                # 노드 추가
    if set_child!(tree, get_node(tree, parent), child_id)  # 부모-자식 연결 시도
        return n                                        # 성공 시 추가된 노드 반환
    else
        rem_node!(tree, child_id)                       # 실패 시 방금 추가한 노드 제거
        return nothing
    end
end

# 기하(형상) 노드를 가리키는 ID 타입.
@with_kw struct GeomID <: AbstractID
    id::Int = -1
end

# GeomNode{G} : 3D 형상 하나를 담는 노드. {G} = 형상의 구체적 타입(빈칸). base_geom 은 "원본 형상", cached_geom 은 "변환 적용된 형상" 캐시.
mutable struct GeomNode{G} <: CachedTreeNode{GeomID}
    id::GeomID                          # 노드 ID
    base_geom::G                        # 원본 형상(부모 기준 좌표, 변환 전)
    parent::TransformNode               # 이 형상의 위치/회전을 담는 변환노드
    cached_geom::CachedElement{G}       # 전역변환을 적용한 형상(캐시)
end
# 형상만 주면: 새 ID, 항등 변환노드, 형상 캐시로 초기화.
function GeomNode(geom)
    GeomNode(get_unique_id(GeomID), geom, TransformNode(), CachedElement(geom))
end
# 형상과 변환노드 tf 를 주면: 그 tf 를 부모 변환노드로 사용.
function GeomNode(geom, tf)
    GeomNode(get_unique_id(GeomID), geom, tf, CachedElement(geom))
end
get_children(n::GeomNode) = Dict{AbstractID,CachedTreeNode}()  # 형상노드는 자식이 없음(빈 딕셔너리)
cached_element(n::GeomNode) = n.cached_geom                    # 캐시되는 요소 = 변환된 형상
set_cached_geom!(n::GeomNode, geom) = update_element!(n, geom) # 변환된 형상 캐시 갱신

get_base_geom(n::GeomNode) = n.base_geom            # 원본 형상 꺼내기
get_transform_node(n::GeomNode) = n.parent          # 이 형상의 변환노드 꺼내기
# 형상노드의 변환 관련 "읽기" 함수들을, 내부 변환노드로 위임하도록 일괄 생성.
for op in transform_node_accessor_interface
    @eval $op(g::GeomNode, args...) = $op(get_transform_node(g))
end
# "쓰기" 함수들도 변환노드로 위임.
for op in transform_node_mutator_interface
    @eval $op(g::GeomNode, args...) = $op(get_transform_node(g), args...)
end
set_parent!(a::GeomNode, b::TransformNode) = set_parent!(get_transform_node(a), b)  # 형상노드의 부모를 변환노드 b 로
set_parent!(a::GeomNode, b::GeomNode) = set_parent!(a, get_transform_node(b))       # 부모가 형상노드면 그 변환노드를 부모로
# 변환노드 갱신 시, 형상노드의 캐시 형상도 다시 계산(원본 형상에 전역변환 적용).
function propagate_forward!(t::TransformNode, n::GeomNode)
    transformed_geom = transform(get_base_geom(n), global_transform(n))  # 원본 형상에 전역변환 적용
    set_cached_geom!(n, transformed_geom)                                # 결과를 캐시에 저장
end

"""
    get_cached_geom(n::GeomNode)

If `n.cached_geom` is out of date, transform it according to
`global_transform(n)`. Updates both the global transform and geometry if
necessary.
"""
# 캐시된(변환 적용된) 형상을 얻음. 캐시가 구식이면 자동으로 재계산 후 반환.
get_cached_geom(n::GeomNode) = get_cached_value!(n)

"""
    Base.copy(n::GeomNode)

Shares `n.base_geom`, deepcopies `n.transform_node`, and copies `n.cached_geom`
(see documenation for `Base.copy(::CachedElement)`).
"""
# 형상노드 복사: 원본 형상(base_geom)은 공유(메모리 절약), 변환노드는 깊은 복사(독립), 캐시는 얕은 복사.
Base.copy(n::GeomNode) = GeomNode(
    get_unique_id(GeomID),          # 새 ID 부여
    n.base_geom,                    # 원본 형상은 그대로 공유
    copy(get_transform_node(n)),    # 변환노드는 복사(독립적으로 움직이도록)
    copy(n.cached_geom)             # 캐시 형상도 복사
)

# abstract type : "직접 만들 수 없는 추상 타입"(파이썬의 추상 베이스 클래스). 아래 구체 타입들의 공통 부모 역할.
# GeometryKey : "어떤 종류의 근사 형상을 가리키는 열쇠"들의 공통 부모. 형상 계층에서 키로 쓰임.
abstract type GeometryKey end
"""
    BaseGeomKey <: GeometryKey

Points to any kind of geometry.
"""
# 아래 struct 들은 모두 "필드 없는 빈 타입"(태그 역할). 어떤 근사 형상을 뜻하는지 구분하는 라벨일 뿐.
struct BaseGeomKey <: GeometryKey end       # 원본/기본 형상을 가리키는 키
"""
    PolyhedronKey <: GeometryKey

Points to a polyhedron.
"""
struct PolyhedronKey <: GeometryKey end      # 다면체 근사 키
struct PolygonKey <: GeometryKey end         # (2D)다각형 근사 키
struct OctagonalPrismKey <: GeometryKey end  # 팔각기둥 근사 키
"""
    ZonotopeKey<: GeometryKey

Points to a zonotope. Might not be useful for approximating shapes that are very
asymmetrical.
"""
struct ZonotopeKey <: GeometryKey end        # 조노토프(평행육면체 합) 근사 키
struct HyperrectangleKey <: GeometryKey end  # 직육면체(축정렬 박스) 근사 키
struct HypersphereKey <: GeometryKey end     # 구(바운딩 스피어) 근사 키
struct CylinderKey <: GeometryKey end        # 원기둥 근사 키
struct CircleKey <: GeometryKey end          # 원(2D) 근사 키
struct ConvexHullKey <: GeometryKey end      # 볼록껍질 근사 키

# construct_child_approximation : 키(종류)에 따라 형상을 그 종류로 "over-근사(겉을 감싸는 더 단순한 형상)"한다(다중 디스패치).
# overapproximate(형상, 목표타입) : 주어진 형상을 빈틈없이 감싸는 목표타입 형상을 만든다.
construct_child_approximation(::PolyhedronKey, geom, args...) = LazySets.overapproximate(geom, equatorial_overapprox_model(), args...)   # 다면체로 근사
construct_child_approximation(::HypersphereKey, geom, args...) = LazySets.overapproximate(geom, LazySets.Ball2{Float64,SVector{3,Float64}}, args...)  # 3D 구로 근사
construct_child_approximation(::HyperrectangleKey, geom, args...) = LazySets.overapproximate(geom, Hyperrectangle{Float64,SVector{3,Float64},SVector{3,Float64}}, args...)  # 3D 직육면체로 근사
construct_child_approximation(::PolygonKey, geom, args...) = LazySets.overapproximate(geom, ngon_overapprox_model(8), args...)   # 8각형(다각형)으로 근사
construct_child_approximation(::CircleKey, geom, args...) = LazySets.overapproximate(geom, LazySets.Ball2{Float64,SVector{2,Float64}}, args...)   # 2D 원으로 근사
construct_child_approximation(::CylinderKey, geom, args...) = LazySets.overapproximate(geom, GeometryBasics.Cylinder, args...)   # 원기둥으로 근사
construct_child_approximation(::OctagonalPrismKey, geom, args...) = LazySets.overapproximate(geom, BufferedPolygonPrism(regular_buffered_polygon(8, 1.0; buffer=0.05 * default_robot_radius())), args...)   # 팔각기둥(여유버퍼 포함)으로 근사


"""
    GeometryHierarchy

A hierarchical representation of geometry
Fields:
* graph - encodes the hierarchy of geometries
* nodes - geometry nodes
"""
# GeometryHierarchy : 한 물체의 여러 근사 형상(원본, 박스, 구 등)을 키로 묶어 트리로 관리하는 자료구조.
# <: AbstractCustomNTree{GeomNode, GeometryKey} : 노드값=GeomNode, ID=GeometryKey 인 커스텀 트리.
@with_kw struct GeometryHierarchy <: AbstractCustomNTree{GeomNode,GeometryKey}
    graph::Graphs.DiGraph = Graphs.DiGraph()                       # 형상 간 부모-자식(원본→근사) 연결구조
    nodes::Vector{GeomNode} = Vector{GeomNode}()                   # 형상 노드들
    vtx_map::Dict{GeometryKey,Int} = Dict{GeometryKey,Int}()       # 키 → 정점번호 변환표
    vtx_ids::Vector{GeometryKey} = Vector{GeometryKey}() # maps vertex uid to actual graph node  # 정점번호 → 키
end
# 형상노드 하나로 시작하는 계층을 만든다(그 형상을 BaseGeomKey 로 등록).
function geom_hierarchy(geom::GeomNode)
    h = GeometryHierarchy()                 # 빈 계층 생성
    add_node!(h, geom, BaseGeomKey())       # 원본 형상을 "기본 형상" 키로 추가
    return h
end
# get_base_geom 과 get_cached_geom 을 GeometryHierarchy 용으로 일괄 정의(키로 형상을 조회, 없으면 nothing).
for op in (:get_base_geom, :get_cached_geom)
    @eval begin
        function $op(n::GeometryHierarchy, k=BaseGeomKey())
            if Graphs.has_vertex(n, k)              # 그 키의 형상이 계층에 있으면
                return $op(get_node(n, k))          # 그 노드에서 형상을 꺼내 반환
            else
                return nothing                      # 없으면 nothing
            end
        end
    end
end

"""
    add_child_approximation!(g::GeometryHierarchy, child_key, parent_key,
        base_geom=get_base_geom(g,parent_id), args...)

Overapproximate `g`'s type `parent_key` geometry with geometry of type
`child_key`, and add this new approximation to `g` under key `child_key` with an
edge from `parent_key` to `child_key`.
"""
# 계층 g 안에서, parent_id 형상을 child_id 종류로 근사해 새 형상으로 추가하고, parent→child 엣지를 잇는다.
function add_child_approximation!(g::GeometryHierarchy,
    child_id,                                # 새로 만들 근사 형상의 키(종류)
    parent_id,                               # 근사의 바탕이 되는 기존 형상의 키
    base_geom=get_base_geom(g, parent_id),   # 바탕 형상(기본값: parent_id 의 원본 형상)
    args...
)
    @assert Graphs.has_vertex(g, parent_id) "g does not have parent_id = $parent_id"  # 부모 형상이 있어야 함
    @assert !Graphs.has_vertex(g, child_id) "g already has child_id = $child_id"      # 자식 키가 아직 없어야 함
    node = get_node(g, parent_id)                                  # 부모 형상 노드
    geom = construct_child_approximation(child_id, base_geom, args...)  # 바탕 형상을 child_id 종류로 근사
    add_node!(g,
        GeomNode(geom, node.parent), # Share parent                # 근사 형상을 새 노드로 추가(변환노드는 부모와 공유)
        child_id
    ) # todo needs parent
    Graphs.add_edge!(g, parent_id, child_id)                       # 부모 형상 → 근사 형상 엣지 추가
    return g
end

"""
    abstract type SceneNode

A node of the `SceneTree`. Each concrete subtype of `SceneNode`
contains all of the following information:
- All required children (whether for a temporary or permanent edge)
- Required Parent (For a permanent edge only)
- Geometry of the entity represented by the node
- Unique ID accessible via `node_id(node)`
- Current transform--both global (relative to base frame) and local (relative to
current parent)
- Required transform relative to parent (if applicable)

"""
# SceneNode : 장면 트리의 노드들이 공유하는 추상 부모 타입(로봇/물체/조립체/운반팀 노드의 공통 베이스).
abstract type SceneNode end
abstract type SceneAssemblyNode <: SceneNode end   # 조립체 계열 노드의 중간 추상 타입
# SceneNode interface
node_id(n::SceneNode) = n.id                       # 노드의 id 필드를 반환

# 형상노드 관련 "읽기" 함수 이름들을 한 목록으로 모음(변환노드 읽기 함수들 + 형상 관련). `...` 로 기존 목록을 펼쳐 합침.
const geom_node_accessor_interface = [
    transform_node_accessor_interface...,
    :get_base_geom, :get_cached_geom, :get_transform_node
]
# "쓰기" 함수 이름 목록(변환노드 쓰기 함수들).
const geom_node_mutator_interface = [
    transform_node_mutator_interface...
]

# 위 읽기 함수들을 SceneNode/CustomNode 에서 내부 형상(n.geom 또는 노드값)으로 위임하도록 일괄 생성.
for op in geom_node_accessor_interface
    @eval $op(n::SceneNode) = $op(n.geom)            # 장면노드 → 그 형상(.geom)에 위임
    @eval $op(n::CustomNode) = $op(node_val(n))      # 커스텀노드 → 그 안의 값에 위임
end
# 쓰기 함수들도 같은 식으로 위임.
for op in geom_node_mutator_interface
    @eval $op(n::SceneNode, args...) = $op(n.geom, args...)
    @eval $op(n::CustomNode, args...) = $op(node_val(n), args...)
end
set_parent!(a::SceneNode, b::SceneNode) = set_parent!(a.geom, b.geom)            # 장면노드 부모설정 → 형상끼리 위임
set_parent!(a::CustomNode, b::CustomNode) = set_parent!(node_val(a), node_val(b)) # 커스텀노드 부모설정 → 값끼리 위임
rem_parent!(a::GeomNode) = rem_parent!(get_transform_node(a))   # 형상노드 부모분리 → 변환노드에 위임
rem_parent!(a::SceneNode) = rem_parent!(a.geom)                 # 장면노드 부모분리 → 형상에 위임
rem_parent!(a::CustomNode) = rem_parent!(node_val(a))           # 커스텀노드 부모분리 → 값에 위임
# 부모/자식/후손 관계 확인 함수들을, 장면노드 → 내부 변환노드로 위임하도록 일괄 생성.
for op in (:(has_parent), :(has_child), :(has_descendant))
    @eval begin
        $op(a::SceneNode, b::SceneNode) = $op(get_transform_node(a), get_transform_node(b))
    end
end

# 장면노드의 특정 키(k) 형상을 조회 — 노드 안의 형상계층(geom_hierarchy)으로 위임.
get_cached_geom(n::SceneNode, k::GeometryKey) = get_cached_geom(n.geom_hierarchy, k)  # 변환 적용된 형상
get_base_geom(n::SceneNode, k::GeometryKey) = get_base_geom(n.geom_hierarchy, k)      # 원본 형상
# 장면노드에 근사 형상 추가 — 형상계층으로 위임.
function add_child_approximation!(n::SceneNode, args...)
    add_child_approximation!(n.geom_hierarchy, args...)
end

"""
    required_transforms_to_children(n::SceneNode)

Returns a dictionary mapping child id to required relative transform.
"""
# 이 노드가 자식들에게 요구하는 "상대 변환들"의 딕셔너리를 반환. 기본 SceneNode 는 자식이 없어 빈 딕셔너리.
function required_transforms_to_children(n::SceneNode)
    return TransformDict{AbstractID}()
end

"""
    required_transform_to_parent(n::SceneNode,parent_id)

Returns the required transform relative to the parent.
"""
# `function 이름 end` : 본문 없이 "이름만 선언"(다른 곳에서 타입별 메서드를 채워 넣을 빈 함수). 파이썬엔 직접 대응 없음.
function required_transform_to_parent end

"""
    Base.copy(n::N) where {N<:SceneNode}

Shares `n.base_geom`, deepcopies `n.transform_node`, and copies `n.cached_geom`
(see documenation for `Base.copy(::CachedElement)`).
"""
# 임의의 장면노드 복사: 같은 타입 N 으로, 형상만 복사해 재생성(N(n, ...) 형태의 "복사 생성자" 호출).
Base.copy(n::N) where {N<:SceneNode} = N(n, copy(n.geom))

# RobotNode{R} : 로봇 한 대를 나타내는 노드. {R} = 로봇 종류 타입 매개변수. id 는 그 종류의 봇 ID.
struct RobotNode{R} <: SceneNode
    id::BotID{R}                       # 로봇 ID(종류 R 포함)
    geom::GeomNode                     # 로봇의 형상(위치/회전 포함)
    geom_hierarchy::GeometryHierarchy  # 로봇 형상의 근사 계층
end
RobotNode(id::BotID, geom) = RobotNode(id, geom, geom_hierarchy(geom))  # ID+형상 → 계층 자동생성
RobotNode(n::RobotNode, geom) = RobotNode(n.id, geom)                   # 기존 노드 + 새 형상(복사용)
RobotNode(id::BotID, n::RobotNode) = RobotNode(id, n.geom, n.geom_hierarchy)  # 새 ID + 기존 노드의 형상/계층

# ObjectNode : 움직이지 않는 단일 강체(부품 하나)를 나타내는 노드.
struct ObjectNode <: SceneNode
    id::ObjectID
    geom::GeomNode
    geom_hierarchy::GeometryHierarchy
end
ObjectNode(id::ObjectID, geom) = ObjectNode(id, geom, geom_hierarchy(geom))  # 계층 자동생성
ObjectNode(n::ObjectNode, geom) = ObjectNode(n.id, geom)                     # 복사용
has_component(n::SceneNode, id) = false   # 기본적으로 장면노드는 "구성요소"를 안 가짐(조립체/운반팀만 가짐 → 아래서 재정의)
# Necessary for copying
RobotNode{R}(n::RobotNode, args...) where {R} = RobotNode(n.id, args...)   # 타입매개변수 명시 복사 생성자

# TransformDict{T} : "ID(타입 T) → 변환" 딕셔너리의 별칭. 조립체가 자식들의 상대위치를 저장하는 데 쓰임.
const TransformDict{T} = Dict{T,CoordinateTransformations.Transformation}
"""
    abstract type SceneNode end

An Abstract type, of which all nodes in a SceneTree are concrete subtypes.
"""
# 조립체를 가리키는 ID 타입.
@with_kw struct AssemblyID <: AbstractID
    id::Int = -1
end

# AssemblyNode : 여러 부품/하위조립체가 단단히 결합된 "조립체"를 나타내는 노드.
struct AssemblyNode <: SceneNode
    id::AssemblyID                                         # 조립체 ID
    geom::GeomNode                                         # 조립체 형상(보통 비어있고 자식들로 구성)
    components::TransformDict{Union{ObjectID,AssemblyID}}  # 구성요소: (부품/하위조립체 ID → 조립체 기준 상대변환)
    geom_hierarchy::GeometryHierarchy                      # 형상 근사 계층
end
AssemblyNode(n::AssemblyNode, geom) = AssemblyNode(n.id, geom, n.components, geom_hierarchy(geom))  # 복사(형상만 교체)
AssemblyNode(id, geom) = AssemblyNode(id, geom, TransformDict{Union{ObjectID,AssemblyID}}(), geom_hierarchy(geom))  # 빈 구성요소로 생성
assembly_components(n::AssemblyNode) = n.components                 # 구성요소 딕셔너리 꺼내기
add_component!(n::AssemblyNode, p) = push!(n.components, p)         # 구성요소(ID=>변환) 추가
has_component(n::AssemblyNode, id) = haskey(assembly_components(n), id)  # 그 ID 가 구성요소에 있는지
child_transform(n::AssemblyNode, id) = assembly_components(n)[id]   # 특정 자식의 상대변환 조회
num_components(n) = length(assembly_components(n))                  # 구성요소 개수
required_transforms_to_children(n::AssemblyNode) = assembly_components(n)  # 자식들에 요구하는 상대변환 = 구성요소 딕셔너리

# TransportUnitNode{C,T} : 화물 하나를 함께 옮기는 "로봇 팀(운반 유닛)"을 나타내는 노드.
# {C} = 화물 ID 타입(부품 또는 조립체), {T} = 화물 변환 타입. cargo 는 (화물ID => 변환) 쌍.
struct TransportUnitNode{C<:Union{ObjectID,AssemblyID},T} <: SceneNode
    geom::GeomNode                                # 운반팀 전체 형상
    cargo::Pair{C,T}                              # 운반 대상 화물: (화물ID => 화물의 상대변환)
    robots::TransformDict{BotID} # must be filled with unique invalid ids  # 팀 로봇들: (로봇ID → 팀 내 상대위치)
    geom_hierarchy::GeometryHierarchy             # 형상 근사 계층
end
TransportUnitNode(n::TransportUnitNode, geom) = TransportUnitNode(geom, n.cargo, n.robots, geom_hierarchy(geom))  # 복사(형상교체)
TransportUnitNode(geom, cargo) = TransportUnitNode(geom, cargo, TransformDict{BotID}(), geom_hierarchy(geom))     # 빈 로봇팀으로 생성
TransportUnitNode(geom, cargo_id::Union{AssemblyID,ObjectID}) = TransportUnitNode(geom, cargo_id => identity_linear_map())  # 화물ID만 주면 변환=항등
TransportUnitNode(cargo::Pair) = TransportUnitNode(GeomNode(nothing), cargo)            # 형상 없이 화물쌍만
TransportUnitNode(cargo_id::Union{AssemblyID,ObjectID}) = TransportUnitNode(cargo_id => identity_linear_map())  # 화물ID만
TransportUnitNode(cargo::Union{AssemblyNode,ObjectNode}) = TransportUnitNode(node_id(cargo))  # 화물노드를 주면 그 ID 사용
robot_team(n::TransportUnitNode) = n.robots                # 팀 로봇 딕셔너리 꺼내기
cargo_id(n::TransportUnitNode) = n.cargo.first             # 화물 ID (Pair 의 first = 키)
# 삼항식: 화물 ID 가 조립체 ID 면 AssemblyNode, 아니면 ObjectNode 라는 "화물의 노드 종류"를 반환.
cargo_type(n::TransportUnitNode) = isa(cargo_id(n), AssemblyID) ? AssemblyNode : ObjectNode
Base.copy(n::TransportUnitNode) = TransportUnitNode(n, copy(n.geom))   # 복사(형상도 복사)
# 운반팀이 자식들(로봇들+화물)에게 요구하는 상대변환 = 로봇팀 딕셔너리와 화물쌍을 합친 것(merge).
function required_transforms_to_children(n::TransportUnitNode)
    merge(robot_team(n), Dict(n.cargo))
end

# TransportUnitID : 운반팀을 가리키는 ID 타입. TemplatedID{Tuple{...}} = 여러 타입을 묶은 "틀 기반 ID".
const TransportUnitID = TemplatedID{Tuple{T,C}} where {C,T<:TransportUnitNode}
# 운반팀의 ID 는 (TransportUnitNode, 화물타입C) 틀에 화물 ID 번호를 넣어 만든다.
node_id(n::TransportUnitNode{C,T}) where {C,T} = TemplatedID{Tuple{TransportUnitNode,C}}(get_id(cargo_id(n)))
Base.convert(::Pair{A,B}, pair) where {A,B} = convert(A, pair.first) => convert(B, p.second)  # Pair 의 키/값을 각각 A,B 타입으로 변환

has_component(n::TransportUnitNode, id::Union{ObjectID,AssemblyID}) = id == cargo_id(n)  # 그 ID 가 이 팀의 화물인지
has_component(n::TransportUnitNode, id::BotID) = haskey(robot_team(n), id)               # 그 로봇이 이 팀 소속인지
# 화물 ID 의 상대변환 조회 — 있으면 cargo.second(값), 없으면 에러.
child_transform(n::TransportUnitNode, id::Union{ObjectID,AssemblyID}) = has_component(n, id) ? n.cargo.second : throw(ErrorException("TransportUnitNode $n does not have component $id"))
child_transform(n::TransportUnitNode, id::BotID) = robot_team(n)[id]   # 로봇 ID 의 팀 내 상대위치 조회
add_robot!(n::TransportUnitNode, p) = push!(robot_team(n), p)          # 팀에 로봇(ID=>변환) 추가
remove_robot!(n::TransportUnitNode, id) = delete!(robot_team(n), id)   # 팀에서 로봇 제거
add_robot!(n::TransportUnitNode, r, t) = add_robot!(n, r => t)         # (로봇ID, 변환) → 쌍으로 만들어 추가
add_robot!(n::TransportUnitNode, t::CoordinateTransformations.AffineMap) = add_robot!(n, get_unique_invalid_id(RobotID) => t)  # 변환만 주면 임시 무효ID 로 자리만 채움
# 팀의 모든 로봇이 실제로 트리에 연결돼 "대형(formation)"을 이뤘는지 확인. all(...) = 전부 참인지.
function is_in_formation(n::TransportUnitNode, scene_tree)
    all([Graphs.has_edge(scene_tree, n, id) for (id, _) in robot_team(n)])
end
# 팀의 로봇들을 운반팀 노드의 자식으로 "포획"(연결). 하나라도 실패하면 formed=false.
function capture_robots!(agent::TransportUnitNode, scene_tree)
    formed = true                                              # 대형 완성 여부(일단 참)
    for (robot_id, _) in robot_team(agent)                     # 팀의 각 로봇에 대해
        if !Graphs.has_edge(scene_tree, agent, robot_id)       # 아직 연결 안 됐으면
            if !capture_child!(scene_tree, agent, robot_id)    # 포획 시도, 실패하면
                formed = false                                 # 대형 미완성 표시
            end
        end
    end
    return formed
end

"""
    swap_robot_id!(transport_unit,old_id,new_id)

Robot `new_id` takes robot `old_id`'s plave in `robot_team(transport_unit)`.
"""
# 운반팀에서 로봇 old_id 를 빼고 new_id 로 같은 자리(상대위치)에 교체.
function swap_robot_id!(transport_unit, old_id, new_id)
    team = robot_team(transport_unit)                       # 팀 딕셔너리
    tform = child_transform(transport_unit, old_id)         # 기존 로봇의 자리(상대변환) 보관
    # @info "robot team before swap" team
    remove_robot!(transport_unit, old_id)                   # 기존 로봇 제거
    add_robot!(transport_unit, new_id => tform)             # 새 로봇을 같은 자리에 추가
    # @info "robot team after swap" team
end

export recurse_child_geometry   # 공개

"""
    recurse_child_geometry(node::SceneNode,tree,key=BaseGeomKey(),depth=typemax(Int))

Return an iterator over all geometry elements matching `key` that belong to
`node` or to any of `node`'s descendants down to depth `depth`.
"""
# 노드와 그 후손들의 형상을 depth 깊이까지 재귀적으로 모아 반복자로 반환. typemax(Int)=사실상 무제한 깊이.
# (기본 SceneNode 버전: 자식이 없으므로 자기 형상만)
function recurse_child_geometry(node::SceneNode, tree, key=BaseGeomKey(), depth=typemax(Int))
    if depth < 0                                  # 깊이 한도를 넘으면
        return nothing                            # 중단
    end
    geom = [get_base_geom(node, key)]             # 이 노드의 형상을 배열로
    if !(geom[1] === nothing)                     # 형상이 있으면
        return geom                               # 그것을 반환
    end
    return nothing                                # 없으면 nothing
end
# (딕셔너리 버전: 자식 ID→변환 들을 순회하며 각 자식의 형상을 그 변환으로 옮겨 모음)
function recurse_child_geometry(dict::TransformDict, tree, key=BaseGeomKey(), depth=typemax(Int))
    if depth < 0
        return nothing
    end
    geoms = []                                    # 모은 형상들을 담을 배열
    for (child_id, tform) in dict                 # 각 자식(ID, 상대변환)에 대해
        if Graphs.has_vertex(tree, child_id)      # 그 자식이 트리에 있으면
            child_geom = recurse_child_geometry(get_node(tree, child_id), tree, key, depth)  # 자식의 형상 재귀 수집
            if !(child_geom === nothing)
                push!(geoms, transform_iter(tform, child_geom))  # 자식 형상을 부모기준 변환으로 옮겨 추가
            end
        end
    end
    if isempty(geoms)                             # 모은 게 없으면
        return nothing
    end
    Base.Iterators.flatten(geoms)                 # 중첩된 형상들을 한 줄로 펼쳐 반복자로 반환
end
# (조립체/운반팀 버전: 자기 형상 + 자식들 형상을 함께 모음. depth-1 로 한 단계 내려감)
function recurse_child_geometry(node::Union{TransportUnitNode,AssemblyNode},
    tree, key=BaseGeomKey(), depth=typemax(Int)
)
    if depth < 0
        return nothing
    end
    geom = [get_base_geom(node, key)]                                          # 자기 형상
    child_geom = recurse_child_geometry(required_transforms_to_children(node), tree, key, depth - 1)  # 자식들 형상(한 단계 아래)
    if (geom[1] === nothing)                      # 자기 형상이 없으면
        return child_geom                         # 자식 형상만
    elseif (child_geom === nothing)               # 자식 형상이 없으면
        return geom                               # 자기 형상만
    else
        return Base.Iterators.flatten((geom, child_geom))   # 둘 다 있으면 합쳐서 반환
    end
end


"""
    abstract type SceneTreeEdge

Concrete subtypes are `PermanentEdge` or `TemporaryEdge`. The idea is that
the former is not allowed to be removed, whereas the latter stays in place.
"""
# SceneTreeEdge : 장면 트리의 엣지(연결) 종류의 추상 부모. 영구/임시 두 종류가 있음.
abstract type SceneTreeEdge end
struct PermanentEdge <: SceneTreeEdge end   # 영구 엣지: 한번 붙으면 못 떼는 연결(조립체-부품)
struct TemporaryEdge <: SceneTreeEdge end   # 임시 엣지: 운반 끝나면 떼는 연결(운반팀-로봇/화물)
# make_edge : 부모(U)/자식(V) 타입 조합에 따라 어떤 엣지를 만들지 결정. 이중 for 로 모든 조합에 메서드 일괄 생성.
for U in (:TransportUnitID, :TransportUnitNode)   # 운반팀이 부모면
    for V in (:RobotID, :RobotNode, :AssemblyID, :AssemblyNode, :ObjectID, :ObjectNode)
        @eval make_edge(g, u::$U, v::$V) = TemporaryEdge()   # → 임시 엣지(운반 후 분리)
    end
end
for U in (:AssemblyID, :AssemblyNode)   # 조립체가 부모면
    for V in (:ObjectID, :ObjectNode, :AssemblyID, :AssemblyNode)
        @eval make_edge(g, u::$U, v::$V) = PermanentEdge()   # → 영구 엣지(조립 완료 후 고정)
    end
end

"""
    SceneTree <: AbstractCustomNETree{SceneNode,SceneTreeEdge,AbstractID}

A tree data structure for describing the current configuration of a multi-entity
system, as well as the desired final configuration. The configuration of the
system is defined by the topology of the tree (i.e., which nodes are connected
by edges) and the configuration of each node (its transform relative to its
parent node).

There are four different concrete subtypes of `SceneNode`
- `ObjectNode` refers to a single inanimate rigid body
- `RobotNode` refers to a single rigid body robot
- `AssemblyNode` refers to a rigid collection of multiple objects and/or subassemblies
- `TransportUnitNode` refers to a team of one or more robot that fit together as
a transport team to move an assembly or object.

The edges of the SceneTree are either `PermanentEdge` or `TemporaryEdge`.

Temporary edges (removed after transport is complete)
- TransportUnitNode → RobotNode
- TransportUnitNode → ObjectNode
- TransportUnitNode → AssemblyNode

Permanent edges (cannot be broken after placement)
- AssemblyNode → AssemblyNode
- AssemblyNode → ObjectNode
"""
# SceneTree : 시스템(로봇·부품·조립체)의 현재/최종 배치를 담는 트리. 노드값=SceneNode, 엣지=SceneTreeEdge, ID=AbstractID.
# <: AbstractCustomNETree{...} : 노드와 엣지 둘 다 부가타입을 갖는 커스텀 트리(NE = Node+Edge typed).
@with_kw struct SceneTree <: AbstractCustomNETree{SceneNode,SceneTreeEdge,AbstractID}
    graph::Graphs.DiGraph = Graphs.DiGraph()                       # 연결구조
    nodes::Vector{SceneNode} = Vector{SceneNode}()                 # 노드 목록
    vtx_map::Dict{AbstractID,Int} = Dict{AbstractID,Int}()         # ID → 정점번호
    vtx_ids::Vector{AbstractID} = Vector{AbstractID}()             # 정점번호 → ID
    inedges::Vector{Dict{Int,SceneTreeEdge}} = Vector{Dict{Int,SceneTreeEdge}}()   # 각 정점으로 "들어오는" 엣지들(종류 포함)
    outedges::Vector{Dict{Int,SceneTreeEdge}} = Vector{Dict{Int,SceneTreeEdge}}()  # 각 정점에서 "나가는" 엣지들
end
add_node!(tree::SceneTree, node::SceneNode) = add_node!(tree, node, node_id(node))  # 노드의 ID 를 자동으로 써서 추가
get_vtx(tree::SceneTree, n::SceneNode) = get_vtx(tree, node_id(n))                  # 노드 → 정점번호(노드 ID 로 조회)
# 트리 전체 복사: 연결구조와 변환표는 깊은 복사, 노드들은 각각 copy 로 복사.
function Base.copy(tree::SceneTree)
    SceneTree(
        graph=deepcopy(tree.graph),                  # 그래프 깊은 복사
        nodes=map(copy, tree.nodes), # TODO This may cause problems with TransformNode  # 각 노드 복사
        vtx_map=deepcopy(tree.vtx_map),              # ID→정점 표 복사
        vtx_ids=deepcopy(tree.vtx_ids)               # 정점→ID 표 복사
    )
end

"""
    set_child!(tree::SceneTree,parent::AbstractID,child::AbstractID)

Only eligible children can be added to a candidate parent in a `SceneTree`.
Eligible edges are those for which the child node is listed in the components of
the parent. `ObjectNode`s and `RobotNode`s may not have any children.
"""
# 장면 트리에서 parent 의 자식으로 child 를 설정. 단 child 가 parent 의 "구성요소"로 등록돼 있어야만 허용.
function set_child!(tree::SceneTree, parent::AbstractID, child::AbstractID)
    node = get_node(tree, parent)                  # 부모 노드
    @assert has_component(node, child) "$(get_node(tree,child)) cannot be a child of $(node)"  # 자격 점검
    t = child_transform(node, child)               # 부모가 정해 둔 자식의 상대변환
    child_node = get_node(tree, child)             # 자식 노드
    set_child!(tree, parent, get_vtx(tree, child), t, make_edge(tree, node, child_node))  # 적절한 엣지종류로 연결
end
set_child!(tree::SceneTree, parent::SceneNode, args...) = set_child!(tree, node_id(parent), args...)  # 부모를 노드로 줘도 ID 로 변환
set_child!(tree::SceneTree, parent::SceneNode, child::SceneNode) = set_child!(tree, node_id(parent), node_id(child))  # 둘 다 노드
set_child!(tree::SceneTree, parent::AbstractID, child::SceneNode, args...) = set_child!(tree, parent, node_id(child), args...)  # 자식만 노드
# 엣지를 강제로 제거(영구/임시 구분 없이). 먼저 자식의 부모연결을 풀어 절대위치 유지하고, 엣지 삭제.
function force_remove_edge!(tree::SceneTree, u, v)
    rem_parent!(get_node(tree, v))                 # 자식 v 를 부모에서 떼되 절대위치 유지
    if Graphs.has_edge(tree, u, v)                 # 엣지가 있으면
        delete_edge!(tree, u, v)                   # 삭제
    end
end

"""
    Graphs.rem_edge!(tree::SceneTree,u,v)

Edge may only be removed if it is not permanent.
"""
# 일반 엣지 제거: 영구 엣지는 못 지우게 막음(assert). 임시 엣지만 제거 가능.
function Graphs.rem_edge!(tree::SceneTree, u, v)
    if !Graphs.has_edge(tree, u, v)                # 엣지가 없으면
        return true                                # 할 일 없음(성공으로 간주)
    end
    @assert !isa(get_edge(tree, u, v), PermanentEdge) "Edge $u → $v is permanent!"  # 영구 엣지면 에러
    force_remove_edge!(tree, u, v)                 # 임시 엣지면 강제 제거
end

"""
    disband!(tree::SceneTree,n::TransportUnitNode)

Disband a transport unit by removing the edge to its children.
"""
# 운반팀 해산: 팀의 모든 로봇과 화물에 대한 엣지를 끊는다(운반 완료 시).
function disband!(tree::SceneTree, n::TransportUnitNode)
    for (r, tform) in robot_team(n)                # 각 로봇에 대해
        if !Graphs.has_edge(tree, n, r)            # 연결돼 있어야 하는데 아니면
            @warn "Disbanding $n -- $r should be attached, but is not"  # 경고
        end
        Graphs.rem_edge!(tree, n, r)               # 운반팀 → 로봇 엣지 제거
    end
    Graphs.rem_edge!(tree, n, cargo_id(n))         # 운반팀 → 화물 엣지 제거
    return true
end

# 포획(자식 붙이기) 허용 오차 — 위치 오차 한계. global 전역변수.
global CAPTURE_DISTANCE_TOLERANCE = 1e-2
capture_distance_tolerance() = CAPTURE_DISTANCE_TOLERANCE       # 현재 위치 허용오차 조회
function set_capture_distance_tolerance!(val)
    global CAPTURE_DISTANCE_TOLERANCE = val                     # 위치 허용오차 설정
end
global CAPTURE_ROTATION_TOLERANCE = 1e-2                        # 회전 오차 한계
capture_rotation_tolerance() = CAPTURE_ROTATION_TOLERANCE       # 회전 허용오차 조회
function set_capture_rotation_tolerance!(val)
    global CAPTURE_ROTATION_TOLERANCE = val                     # 회전 허용오차 설정
end

export is_within_capture_distance   # 공개

"""
    is_within_capture_distance(parent,child,ttol=capture_distance_tolerance(),rtol=capture_rotation_tolerance())

Returns true if the error between `relative_transform(parent,child)` and
`child_transform(parent,node_id(child))` is small enough for capture of `child`
by parent.
"""
# 부모/자식 노드를 받아, 현재 상대위치(t)와 "있어야 할 상대위치(t_des)"가 충분히 가까운지 판정.
function is_within_capture_distance(parent::SceneNode, child::SceneNode, args...)
    t = relative_transform(global_transform(parent), global_transform(child))  # 현재 부모기준 자식 상대변환
    t_des = child_transform(parent, node_id(child))                            # 부모가 정해 둔 목표 상대변환
    is_within_capture_distance(t, t_des, args...)                              # 두 변환의 오차로 판정(아래 메서드)
end

# 변환 t 와 목표 t_des 의 위치/회전 오차가 허용범위(ttol/rtol) 안이면 true.
function is_within_capture_distance(t, t_des, ttol=capture_distance_tolerance(), rtol=capture_rotation_tolerance())
    et = norm(t.translation - t_des.translation) # translation error          # 위치 오차 = 두 이동 벡터 차이의 크기
    er = Inf                                                                   # 회전 오차(일단 무한대로 둠)
    # Rotation error
    # QuatVecMap -- cheapest to compute, but goes singular at 180 degrees  (sign ambiguity)
    # MRPMap     -- singular at 360 degrees (sign ambiguity)
    # 두 가지 회전오차 표현법으로 각각 계산(각 방식은 특정 각도에서 발산/특이점이 있어 둘 다 구함).
    er_quatvecmap = norm(Rotations.rotation_error(t, t_des, Rotations.QuatVecMap()))  # 180도에서 특이
    er_mrpmap = norm(Rotations.rotation_error(t, t_des, Rotations.MRPMap()))          # 360도에서 특이

    quatvecmap_singular = isnan(er_quatvecmap) || isinf(er_quatvecmap)  # 첫 방식이 발산(특이점)했는지 (|| = 또는)
    mrpmap_singular = isnan(er_mrpmap) || isinf(er_mrpmap)              # 둘째 방식이 발산했는지
    @assert !(quatvecmap_singular && mrpmap_singular) "Both QuatVecMap and MRPMap are singular. This should not happen."  # 둘 다 발산은 불가
    if quatvecmap_singular                          # 첫 방식만 발산했으면
        er = er_mrpmap                              # 둘째 값 사용
    elseif mrpmap_singular                          # 둘째만 발산했으면
        er = er_quatvecmap                          # 첫째 값 사용
    else
        er = min(er_quatvecmap, er_mrpmap)          # 둘 다 멀쩡하면 더 작은 값 사용
    end
    if et < ttol && er < rtol                       # 위치오차·회전오차 모두 허용 안이면 (&& = 그리고)
        return true                                 # 포획 가능
    end
    return false
end

"""
    capture_child!(tree::SceneTree,u,v,ttol,rtol)

If the transform error of `v` relative to the transform prescribed for it by `u`
is small, allow `u` to capture `v` (`v` becomes a child of `u`).
"""
# u 가 v 를 포획(자식으로 흡수). v 가 제자리(목표 상대위치)에 충분히 가까울 때만 성공.
function capture_child!(tree::SceneTree, u, v, ttol=capture_distance_tolerance(), rtol=capture_rotation_tolerance())
    nu = get_node(tree, u)                          # 포획하는 쪽 노드
    nv = get_node(tree, v)                          # 포획당하는 쪽 노드
    @assert has_component(nu, node_id(nv)) "$nu cannot capture $nv"  # v 가 u 의 구성요소여야 함
    if is_within_capture_distance(get_node(tree, u), get_node(tree, v), ttol, rtol)  # 충분히 가까우면
        if !is_root_node(tree, v)                   # v 가 이미 다른 부모에 붙어있으면
            p = get_node(tree, get_parent(tree, v)) # current parent  # 현재 부모
            @assert(isa(p, TransportUnitNode),      # 그 부모는 반드시 운반팀이어야 함
                "Trying to capture child $v from non-TransportUnit parent $p")
            # NOTE that there may be a time gap if the cargo has to be lifted
            # into place by a separate "robot"
            disband!(tree, p)                       # 기존 운반팀 해산(v 를 자유롭게)
        end
        return set_child!(tree, u, v)               # u 의 자식으로 연결
    end
    # t = relative_transform(tree,u,v)
    # t_des = child_transform(nu,node_id(nv))
    # et = norm(t.translation - t_des.translation) # translation error
    # er = norm(Rotations.rotation_error(t,t_des)) # rotation_error
    # if et < ttol && er < rtol
    #     if !is_root_node(tree,v)
    #         p = get_node(tree,get_parent(tree,v)) # current parent
    #         @assert(isa(p, TransportUnitNode),
    #             "Trying to capture child $v from non-TransportUnit parent $p")
    #         # NOTE that there may be a time gap if the cargo has to be lifted
    #         # into place by a separate "robot"
    #         disband!(tree,p)
    #     end
    #     return set_child!(tree,u,v)
    # end
    return false                                    # 가깝지 않으면 포획 실패
end

# 장면 트리로부터 "의존 그래프"를 만든다 — 각 노드에서 그 노드가 요구하는 자식들로 엣지를 그음.
# (실제 트리 엣지는 아직 안 붙었을 수 있으므로, 위상정렬용으로 별도 그래프를 구성)
function construct_scene_dependency_graph(scene_tree)
    G = Graphs.DiGraph(Graphs.nv(scene_tree))       # 노드 수만큼의 빈 방향그래프(nv = 노드 개수)
    for n in get_nodes(scene_tree)                  # 각 노드에 대해
        for (child_id, _) in required_transforms_to_children(n)  # 그 노드가 요구하는 각 자식에
            Graphs.add_edge!(G, get_vtx(scene_tree, n), get_vtx(scene_tree, child_id))  # 노드→자식 엣지 추가
        end
    end
    return G
end

"""
    compute_approximate_geometries!(scene_tree,key=HypersphereKey(),base_key=key;
        leaves_only=false,ϵ=0.0)

Walk up the tree, computing bounding spheres (or whatever other geometry).
Args:
- key: determines the type of overapproximation geometry to compute
- base_key: determines the type of child geometry on which to base a parent's
    geometry
Example:
    compute_approximate_geometries!(tree,HyperrectangleKey(),BaseGeomKey()) will
    compute a Hyperrectangle approximation of each object and assembly. The
    computation for each assembly's Hyperrectangle will be based on the
    BaseGeomKey geometry of all of that assembly's children.
"""
# 트리를 잎→뿌리 방향으로 훑으며, 각 노드에 바운딩 형상(기본: 바운딩 스피어)을 계산해 채워 넣는다.
# key: 만들 근사 형상 종류, base_key: 부모 형상을 만들 때 바탕으로 삼을 자식 형상 종류. ϵ: 근사 여유(부풀림).
function compute_approximate_geometries!(scene_tree, key=HypersphereKey(), base_key=key;
    leaves_only=false,                              # true 면 잎(말단) 노드만 처리
    ϵ=0.0,                                          # 근사 시 여유 두께
)
    # Build dependency graph (to enable full topological sort)
    G = construct_scene_dependency_graph(scene_tree)  # 위상정렬용 의존 그래프 구성
    # 위상정렬을 뒤집어 "자식 먼저, 부모 나중" 순서로 노드 ID 들을 생성(부모는 자식 형상에 의존하므로).
    ids = (get_vtx_id(scene_tree, v) for v in reverse(Graphs.topological_sort_by_dfs(G)))
    for node in node_iterator(scene_tree, ids)      # 그 순서대로 각 노드를
        h = node.geom_hierarchy                     # 노드의 형상 계층
        if !Graphs.has_vertex(h, key)               # 아직 그 종류 형상이 없으면
            if isa(node, Union{ObjectNode,RobotNode})   # 노드가 잎(부품/로봇)이면
                for (k1, k2) in [(BaseGeomKey(), base_key), (base_key, key)]  # 원본→base_key→key 2단계로 근사 사슬 생성
                    if !Graphs.has_vertex(h, k2)    # k2 형상이 아직 없으면
                        base_geom = recurse_child_geometry(node, scene_tree, k1, 1)  # k1 형상 수집
                        if !(base_geom === nothing)
                            add_child_approximation!(h, k2, k1, base_geom)  # k1 → k2 근사 추가
                        end
                    end
                end
            elseif leaves_only == false             # 잎이 아니고(조립체 등) 잎만 처리모드가 아니면
                geoms = recurse_child_geometry(node, scene_tree, base_key, 1)  # 자식들의 base_key 형상 모으기
                if !(geoms === nothing)
                    add_child_approximation!(h, key, BaseGeomKey(), geoms)  # 그것들을 감싸는 key 형상 추가
                else
                    @warn "Unable to recurse child geometry" node  # 자식 형상을 못 모으면 경고
                end
            end
        end
    end
    return scene_tree
end

export remove_geometry!   # 공개
remove_geometry!(n::GeometryHierarchy, key) = rem_node!(n, key)        # 형상계층에서 그 키 형상 노드 제거
remove_geometry!(n::SceneNode, key) = rem_node!(n.geom_hierarchy, key) # 장면노드 → 형상계층에 위임
# 트리의 모든 노드에서 그 키의 형상을 제거.
function remove_geometry!(scene_tree::SceneTree, key)
    for n in get_nodes(scene_tree)
        remove_geometry!(n, key)
    end
end


"""
    jump_to_final_configuration!(scene_tree;respect_edges=false)

Jump to the final configuration state wherein all `ObjectNode`s and
`AssemblyNode`s are in the configurations specified by their parent assemblies.
"""
# 모든 부품/조립체를 "조립 완성 상태(부모가 정한 최종 위치)"로 즉시 점프시킨다(경계상자 계산 등 사전준비용).
function jump_to_final_configuration!(scene_tree; respect_edges=false, set_edges=false)
    for node in get_nodes(scene_tree)               # 각 노드에 대해
        if matches_template(AssemblyNode, node)     # 조립체이면
            for (id, tform) in assembly_components(node)  # 그 구성요소(자식 ID, 상대변환)마다
                # if Graphs.has_edge(scene_tree, node, id)
                force_remove_edge!(scene_tree, node, id)  # 기존 엣지를 일단 제거
                set_child!(scene_tree, node, id)          # 부모가 정한 상대변환으로 자식 위치 설정(엣지 재연결)
                if !set_edges                             # 엣지를 남기지 않을 모드면
                    force_remove_edge!(scene_tree, node, id)  # 위치만 정하고 엣지는 다시 제거
                end
                # end
                # if !respect_edges || Graphs.has_edge(scene_tree,node,id)   # (주석처리된 옛 코드)
                #     set_local_transform!(get_node(scene_tree,id),tform)
                # end
            end
        end
    end
    scene_tree
end

"""
    project_point_to_line(p,p1,p2)

project `p` onto line between `p1` and `p2`
"""
# 점 p 를, p1-p2 를 잇는 직선 위로 수직 투영한 점을 구한다.
function project_point_to_line(p, p1, p2)
    base = p2 - p1                                  # 직선 방향 벡터
    leg = p - p1                                    # p1 에서 p 로 가는 벡터
    v = p1 + dot(leg, base) * base / norm(base)^2   # p1 + (leg 의 base 방향 성분) = 투영점 (dot=내적)
end

"""
    project_onto_vector(vec,b)

project `vec` onto `b`.
"""
# 벡터 vec 를 벡터 b 방향으로 투영(b 방향 성분만 남김). = b * (vec·b)/(b·b).
project_onto_vector(vec, b) = b * dot(vec, b) / dot(b, b)
# project_onto_unit_vector(vec,b) = project_onto_vector(vec,normalize(b))   # (주석처리된 옛 코드)

"""
"""
# a 의 b 방향 투영 길이(부호 포함) = (a·b)/|b|.
projection_norm(a, b) = dot(a, b) / norm(b)

"""
    circle_intersects_line(circle,line)

Return true if `circle` intersect `line`.
"""
# 원과 선분 사이의 부호거리: 음수면 교차(겹침), 양수면 떨어짐. (반환값 = 가장 가까운 거리 - 반지름)
function circle_intersection_with_line(circle, line)
    p1, p2 = line.points[1], line.points[2]         # 선분의 두 끝점 (한 줄에 두 변수 동시 대입)
    c = get_center(circle)                          # 원 중심
    pt = project_point_to_line(c, p1, p2)           # 중심을 직선에 투영한 점
    d = norm(p2 - p1)                               # 선분 길이
    d1 = norm(p1 - pt)                              # p1~투영점 거리
    d2 = norm(p2 - pt)                              # p2~투영점 거리
    r = get_radius(circle)                          # 원 반지름
    if isapprox(d, d1 + d2)                         # 투영점이 선분 "안"에 있으면(d ≈ d1+d2)
        return norm(c - pt) - r                     # 중심~직선 수직거리 - 반지름
    else                                            # 투영점이 선분 밖이면
        return min(norm(c - p1), norm(c - p2)) - r  # 더 가까운 끝점까지 거리 - 반지름
    end
end
circle_intersects_line(args...) = circle_intersection_with_line(args...) < 0  # 부호거리가 음수면 교차(true)
# 끝점 두 개(pt1, pt2)를 받아 Line 을 만들어 위 함수에 넘기는 편의 버전. pt1... 로 좌표 펼침.
circle_intersection_with_line(circle, pt1, pt2) = circle_intersection_with_line(circle,
    GeometryBasics.Line(GeometryBasics.Point(pt1...), GeometryBasics.Point(pt2...)))





"""
    extract_points_and_radii(lazy_set)

Returns an iterator over points and radii.
"""
# extract_points_and_radii : 형상에서 "(점, 반지름)" 쌍들을 뽑아낸다(바운딩 구/박스 계산의 입력). 다각형은 각 꼭짓점+반지름0.
# zip(...) : 두 묶음을 짝지음(파이썬 zip). repeated(0.0) = 0.0 을 무한히 반복(각 점의 반지름을 0 으로).
extract_points_and_radii(n::GeometryBasics.Ngon) = zip(GeometryBasics.coordinates(n), Base.Iterators.repeated(0.0))

# 원기둥은 옆면 둘레를 c(기본16)개로 샘플링한 점들로 근사(평평한 위/아래면을 점으로 표현할 다른 방법이 없어 근사).
function extract_points_and_radii(n::GeometryBasics.Cylinder, c=16)
    # Approximate, because there's no other way to account for the cylinder's flat top and bottom
    v = normalize(n.extremity - n.origin)           # 원기둥 축 방향 단위벡터(normalize=길이1로)
    θ_range = 0.0:(2π/c):(2π*(c-1)/c)               # 0~거의2π 를 c 등분한 각도들(range = 등간격 수열)
    extract_points_and_radii(Base.Iterators.flatten([
        # 바닥 원주 위 점들: 축 v 에 수직인 반지름 방향(cross=외적)으로 r 만큼 떨어진 점
        map(θ -> SVector(n.origin + normalize(cross(SVector{3,Float64}(cos(θ), sin(θ), 0.0), v)) * n.r), θ_range),
        # 윗면 원주 위 점들: 같은 방식으로 extremity(윗점) 기준
        map(θ -> SVector(n.extremity + normalize(cross(SVector{3,Float64}(cos(θ), sin(θ), 0.0), v)) * n.r), θ_range),
    ]))
end
extract_points_and_radii(n::LazySets.Ball2) = [(n.center, n.radius)]   # 공은 (중심, 반지름) 하나
extract_points_and_radii(n::Union{Hyperrectangle,AbstractPolytope}) = zip(LazySets.vertices(n), Base.Iterators.repeated(0.0))  # 박스/다면체는 꼭짓점들+반지름0
# 점 모음(벡터/펼침/생성자) 종류들에 대해 "각 원소에서 점·반지름을 뽑아 한 줄로 펼치는" 메서드 일괄 정의.
for T in (:AbstractVector, :(Base.Iterators.Flatten), :(Base.Generator))
    @eval extract_points_and_radii(n::$T) = Base.Iterators.flatten(map(extract_points_and_radii, n))
end
extract_points_and_radii(n::SVector) = [(n, 0.0)]   # 단일 점은 (점, 반지름0) 하나

LazySets.dim(::Type{SVector{N,T}}) where {N,T} = N        # SVector{N,...} 의 차원은 N
LazySets.dim(::Type{LazySets.Ball2{T,V}}) where {T,V} = LazySets.dim(V)  # 공의 차원은 그 중심벡터 V 의 차원

Base.convert(::Type{LazySets.Ball2{T,V}}, b::LazySets.Ball2) where {T,V} = LazySets.Ball2(V(b.center), T(b.radius))  # 공의 좌표/반지름 타입을 V,T 로 통일 변환

"""
    overapproximate_sphere(points_and_radii,N=3,ϵ=0.0)

The bounding sphere ought to be constructed instead by iteratively adding points
and updating the sphere.
"""
# 점들(과 반지름들)을 모두 감싸는 "최소 바운딩 구"를 최적화로 구한다. N=차원, ϵ=여유.
function overapproximate_sphere(points_and_radii, N=3, ϵ=0.0)
    model = Model(default_geom_optimizer())                 # 최적화 모델 생성
    set_optimizer_attributes(model, default_geom_optimizer_attributes()...)  # 솔버 옵션 적용
    @variable(model, v[1:N])                                # 구의 중심 좌표(길이 N 벡터) 변수
    @variable(model, d >= 0.0)                              # 구의 반지름 변수(≥0)
    @objective(model, Min, d)                               # 목적: 반지름 d 최소화(가장 작은 구)
    list_is_empty = true                                    # 점이 하나도 없는지 표시
    for (pt, r) in points_and_radii                         # 각 (점, 반지름)에 대해
        list_is_empty = false
        # 제약: 중심~점 거리 + 그 점 반지름 + ϵ ≤ d (2차 원뿔로 표현 = 점이 구 안에 들어가도록)
        @constraint(model, [(d - r - ϵ), map(i -> (v[i] - pt[i]), 1:N)...] in SecondOrderCone())
    end
    if list_is_empty                                        # 점이 없으면
        # return nothing
        return LazySets.Ball2(SVector(zeros(N)...), 0.0)    # 반지름0 인 원점 구 반환
    end
    optimize!(model)                                        # 최적화 실행
    ball = LazySets.Ball2(SVector{N,Float64}(value.(v)), max(0.0, value(d)))  # 구한 중심/반지름으로 구 생성(음수 반지름 방지)
    return ball
end
# 점들을 감싸는 "바운딩 원기둥"을 구한다 — xy 평면에서 바운딩 원(2D)을 구하고, z 범위는 최소/최대로.
function overapproximate_cylinder(points_and_radii, ϵ=0.0)
    N = 2                                                   # xy 평면(2D)에서 바운딩 원 계산
    b = overapproximate_sphere(points_and_radii, N, ϵ)      # xy 바운딩 원(중심·반지름)
    zhi = -Inf                                              # z 최댓값(초기 -무한대)
    zlo = Inf                                               # z 최솟값(초기 +무한대)
    for (pt, r) in points_and_radii                         # 각 점의 z 좌표로
        if pt[3] > zhi                                      # 더 높으면
            zhi = pt[3]                                     # 최댓값 갱신
        end
        if pt[3] < zlo                                      # 더 낮으면
            zlo = pt[3]                                     # 최솟값 갱신
        end
    end
    # get z values
    return GeometryBasics.Cylinder(                         # 바닥(zlo)~윗면(zhi), 반지름은 xy 원 반지름
        GeometryBasics.Point(b.center[1], b.center[2], zlo),
        GeometryBasics.Point(b.center[1], b.center[2], zhi),
        b.radius)
end

# 여러 입력 형상 타입($T)에 대해, LazySets.overapproximate(형상, 목표타입) 메서드를 한꺼번에 정의(over-근사 구/박스/원기둥).
for T in (:AbstractPolytope, :LazySet, :AbstractVector, :(GeometryBasics.Ngon), :Any)
    @eval begin
        # 목표가 구(Ball2)면: 점·반지름을 뽑아 바운딩 구를 계산해 H 타입으로 변환.
        function LazySets.overapproximate(lazy_set::$T, ::Type{H}, ϵ::Float64=0.0, N=LazySets.dim(H)) where {H<:LazySets.Ball2}
            return convert(H, overapproximate_sphere(extract_points_and_radii(lazy_set), N, ϵ))
        end
        # 목표가 직육면체(Hyperrectangle)면: 각 축의 최소/최대를 구해 축정렬 박스 생성.
        function LazySets.overapproximate(lazy_set::$T, ::Type{H}, ϵ::Float64=0.0) where {A,V<:AbstractVector,H<:Hyperrectangle{A,V,V}}
            # overapproximate_hyperrectangle(extract_points_and_radii(lazy_set),ϵ)
            high = -Inf * ones(V)                          # 각 축 최댓값(초기 -무한대 벡터)
            low = Inf * ones(V)                            # 각 축 최솟값(초기 +무한대 벡터)
            for (pt, r) in extract_points_and_radii(lazy_set)  # 각 점에 대해
                high = max.(high, pt .+ r)                 # .max/.+ = 원소별 최대/덧셈 → 축별 최댓값 갱신
                low = min.(low, pt .- r)                   # 축별 최솟값 갱신
            end
            ctr = (high .+ low) / 2                        # 박스 중심 = (최대+최소)/2
            widths = (high .- low) / 2                     # 박스 반쪽크기 = (최대-최소)/2
            if any(widths .< 0)                            # 폭이 음수면(점이 없었던 경우)
                ctr = zeros(V)                             # 0 크기 박스로
                widths = zeros(V)
            end
            Hyperrectangle(ctr, widths .+ (ϵ / 2))         # 여유 ϵ/2 더해 박스 생성
        end
        # 목표가 원기둥(Cylinder)이면: 바운딩 원기둥 계산.
        function LazySets.overapproximate(lazy_set::$T, m::Type{C}, ϵ::Float64=0.0) where {C<:GeometryBasics.Cylinder}
            overapproximate_cylinder(extract_points_and_radii(lazy_set), ϵ)
        end
    end
end

# 공(Ball2)을 감싸는 직육면체: 중심은 그대로, 각 축 반쪽크기는 반지름+ϵ.
function LazySets.overapproximate(lazy_set::LazySets.Ball2, model::Type{H}, ϵ::Float64=0.0) where {A,V<:AbstractVector,H<:Hyperrectangle{A,V,V}}
    ctr = lazy_set.center                           # 박스 중심 = 공 중심
    r = lazy_set.radius + ϵ                          # 박스 반쪽크기 = 공 반지름 + 여유
    Hyperrectangle(V(ctr), r * ones(V))             # 정육면체 형태 박스 생성
end

# 중심이 고정된 구(sphere)에 대해, 모든 점을 감싸도록 반지름만 키운 구를 반환.
function LazySets.overapproximate(lazy_set, sphere::H, ϵ::Float64=0.0) where {V,T,H<:LazySets.Ball2{T,V}}
    r = 0.0                                          # 필요한 반지름(0부터 키움)
    for (pt, rad) in extract_points_and_radii(lazy_set)  # 각 점에 대해
        r = max(norm(pt - get_center(sphere)) + rad + ϵ, r)  # 중심~점 거리(+그점 반지름+ϵ)의 최댓값으로 갱신
    end
    LazySets.Ball2(V(get_center(sphere)), T(r))     # 같은 중심, 키운 반지름의 구 반환
end

"""
    construct_support_placement_aggregator

Construct an objective function that scores a selection of indices into `pts`.
Balances a neighbor-neighbor metric with a all-all metric
Args
* pts - a vector of points
* n - the number of indices to be selected
* [f_neighbor = v->1.0*minimum(v)] - a function mapping a vector of distances
    to a scalar value.
* [f_inner = v->1.0*minimum(v)] - a function mapping a vector of distances
    to a scalar value.
"""
# 점들 pts 중에서 n 개를 고른 "선택(인덱스 집합)"에 점수를 매기는 목적함수를 만들어 반환(클로저).
# 이웃-이웃 간격 지표(f_neighbor)와 전체-전체 간격 지표(f_inner)를 균형 있게 합산.
function construct_support_placement_aggregator(pts, n,
    f_neighbor=v -> 1.0 * minimum(v) + (0.5 / n) * sum(v),   # 이웃 거리 벡터 → 점수(최솟값 위주 + 합 일부)
    f_inner=v -> (0.1 / (n^2)) * minimum(v)                  # 전체쌍 거리 → 점수(최솟값에 작은 가중)
)
    D = [norm(v - vp) for (v, vp) in Base.Iterators.product(pts, pts)]  # 모든 점쌍 거리 행렬(product=데카르트곱)
    # 선택된 인덱스들의 "이웃끼리(순환 다음 점)" 거리들로 이웃 점수 계산. wrap_get=인덱스가 넘치면 처음으로 순환.
    d_neighbor = (idxs) -> f_neighbor(
        map(i -> wrap_get(D, (idxs[i], wrap_get(idxs, i + 1))), 1:length(idxs))
    )
    # 선택된 인덱스들의 "모든 쌍" 거리들로 전체 점수 계산.
    d_inner = (idxs) -> f_inner(
        [wrap_get(D, (i, j)) for (i, j) in Base.Iterators.product(idxs, idxs)]
    )
    d = (idxs) -> d_neighbor(idxs) + d_inner(idxs)          # 최종 점수 = 이웃 점수 + 전체 점수 (이 함수를 반환)
end

"""
    spaced_neighbors(polygon,n::Int,aggregator=sum)

Return the indices of the `n` vertices of `polygon` whose neighbor distances
maximize the utility metric defined by `aggregator`. Uses local optimization,
so there is no guarantee of global optimality.
"""
# 다각형 꼭짓점 중 n 개를, 점수함수를 최대로 만드는 쪽으로 고른다(지역 탐색이라 전역 최적은 보장 안 됨).
function spaced_neighbors(polygon::LazySets.AbstractPolygon, n::Int,
    score_function=construct_support_placement_aggregator(vertices_list(polygon), n),  # 기본 점수함수
    ϵ=1e-8)                                          # 개선으로 인정할 최소 점수 증가량
    pts = vertices_list(polygon)                    # 다각형 꼭짓점들
    @assert length(pts) >= n "length(pts) = $(length(pts)), but n = $n"  # 꼭짓점이 n 개 이상이어야 함
    if length(pts) == n                             # 꼭짓점 수가 정확히 n 이면
        return collect(1:n), 0.0                    # 전부 선택(1..n)하고 점수 0 반환
    end
    best_idxs = SVector{n,Int}(collect(1:n)...)      # 초기 선택 = 처음 n 개
    d_hi = score_function(best_idxs)                # 그 선택의 현재 최고 점수
    idx_list = [best_idxs]                          # 탐색 이력
    while true                                       # 더 이상 개선 없을 때까지 반복
        updated = false                             # 이번 라운드에 개선됐는지
        # 각 선택 인덱스를 -1/0/+1 만큼 움직인 모든 조합을 시도(product 로 n 개의 (-1,0,1) 곱집합 생성).
        for deltas in Base.Iterators.product(map(i -> (-1, 0, 1), 1:n)...)
            idxs = sort(map(i -> wrap_idx(length(pts), i), best_idxs .+ deltas))  # 이동 후 정렬(wrap_idx=범위 순환)
            if length(unique(idxs)) == n            # 서로 다른 n 개를 잘 고른 경우만(중복 없으면)
                if score_function(idxs) > d_hi + ϵ  # 점수가 의미있게 더 높으면
                    best_idxs = map(i -> wrap_idx(length(pts), i), idxs)  # 최선 선택 갱신
                    d_hi = score_function(idxs)     # 최고 점수 갱신
                    push!(idx_list, best_idxs)      # 이력에 추가
                    updated = true                  # 개선됨 표시
                end
            end
        end
        if !updated                                 # 한 바퀴 돌아도 개선이 없으면
            break                                   # 종료(지역 최적 도달)
        end
    end
    return best_idxs, d_hi                           # 최선 선택과 그 점수 반환
end

# perimeter : 점들의 둘레 길이(연속한 점들 사이 거리 합). zip(앞부분, 뒷부분)으로 인접쌍을 만듦.
perimeter(pts) = sum(map(v -> norm(v[1] - v[2]), zip(pts[1:end-1], pts[2:end]))) #sum(map(i->norm(wrap_get(pts,(i,i+1))),1:length(pts)))
perimeter(p::LazySets.AbstractPolygon) = perimeter(vertices_list(p))   # 다각형이면 꼭짓점들로 둘레 계산

"""
    select_support_locations(polygon, r)

Select support locations where options are the vertices of `polygon` and the
robot radius is `r`.
"""
# 다각형 꼭짓점들 중에서 로봇(반지름 r)이 화물을 떠받칠 "지지 위치"들을 고른다.
function select_support_locations(polygon::LazySets.AbstractPolygon, r;
    score_function_constructor=construct_support_placement_aggregator,  # 점수함수 생성기(키워드 인자)
)
    n = select_num_robots(polygon, r)               # 필요한 로봇 수 결정
    if n == 1                                        # 한 대면
        sphere = overapproximate(polygon, LazySets.Ball2{Float64,SVector{2,Float64}})  # 다각형의 바운딩 원
        support_pts = [LazySets.center(sphere)]      # 그 원 중심 한 점만 지지점으로
        return support_pts
    end
    pts = vertices_list(polygon)                    # 다각형 꼭짓점들
    pts = reduce_to_valid_candidate_list(pts, r)    # 서로 너무 가까운 점 제거(로봇끼리 안 겹치게)

    reduced_polygon = VPolygon(pts)                 # 걸러진 점들로 새 다각형(볼록껍질)

    # The desired number of robots can't be more than the number of valid points
    # We also use the vertices list of the reduced polygon so we are only considering the
    # convex hull of the valid points``
    n = min(n, length(vertices_list(reduced_polygon))) # Can cannot be greater than the number of valid points  # 로봇 수는 유효점 개수 이하

    if n == 1                                        # 줄였더니 한 대로 충분하면
        sphere = overapproximate(polygon, LazySets.Ball2{Float64,SVector{2,Float64}})
        support_pts = [LazySets.center(sphere)]      # 중심 한 점
        return support_pts
    end

    score_function = score_function_constructor(pts, n)        # 점수함수 생성
    best_idxs, _ = spaced_neighbors(reduced_polygon, n, score_function)  # 잘 퍼진 n 개 꼭짓점 선택
    if length(best_idxs) < n                         # 요청보다 적게 골라졌으면
        @warn "$n support points requested, but only $(length(best_idxs)) returned for polygon with $(length(pts)) vertices"  # 경고
    end
    support_pts = pts[best_idxs]                     # 선택된 인덱스의 실제 좌표들
    return support_pts
end

"""
    reduce_to_valid_candidate_list(pts, r; ϵ=0.5*r)

Reduce the list of candidate points to those that are at least `2r+ϵ` away from each other.
This selects points that are "far" away from each other.
"""
# 점들 중 서로 최소 2r+ϵ 이상 떨어진 점들만 골라낸다(로봇끼리 안 부딪히게 "멀리 떨어진" 점 선택). ϵ 기본 0.5r.
function reduce_to_valid_candidate_list(pts, r; ϵ=0.5 * r)
    pts_c = deepcopy(pts)                            # 원본 보호 위해 깊은 복사
    candidate_pts = Vector{Vector{Float64}}()       # 선택된 후보점들

    # The first candidate point is the point furthest from the origin
    pts_dist = norm.(pts_c, 2)                      # 각 점의 원점으로부터 거리(.norm = 원소별, 2=유클리드)
    first_candidate_idx = argmax(pts_dist)          # 가장 먼 점의 인덱스(argmax=최댓값 위치)
    push!(candidate_pts, pts_c[first_candidate_idx])  # 첫 후보로 추가
    deleteat!(pts_c, first_candidate_idx)           # 남은 점 목록에서 제거

    while !isempty(pts_c)                           # 남은 점이 있는 동안
        # 각 (후보, 남은점) 쌍의 거리 행렬 두 개를 미리 채울 빈 행렬로 생성(undef=미초기화).
        dist_to_candidates = Matrix{Float64}(undef, length(candidate_pts), length(pts_c))
        lp_dist_to_candidates = Matrix{Float64}(undef, length(candidate_pts), length(pts_c))
        # 이중 for(한 줄): 각 후보 c_pt 와 각 남은점 pt 사이 거리 계산.
        for (ii, c_pt) in enumerate(candidate_pts), (jj, pt) in enumerate(pts_c)
            dist_to_candidates[ii, jj] = norm(c_pt - pt, 2)
            lp_dist_to_candidates[ii, jj] = norm(c_pt - pt, 2)
        end

        # Determine feasible points
        min_dist_to_candidates = minimum(dist_to_candidates, dims=1)  # 각 남은점의 "가장 가까운 후보까지" 거리(열별 최소)
        bool_mask = vec(min_dist_to_candidates .> (2 * r + ϵ))        # 그 거리가 2r+ϵ 보다 큰지(겹침 없는지) 불리언 마스크
        pts_c = pts_c[bool_mask]                     # 조건 통과한 점들만 남김

        if isempty(pts_c)                            # 남은 게 없으면
            break                                    # 종료
        end

        # Select next candidate: feasible and furthest sum lp norm from candidates
        sum_lp_dist = vec(sum(lp_dist_to_candidates, dims=1))  # 각 점의 "모든 후보까지 거리 합"
        sum_lp_dist = sum_lp_dist[bool_mask]         # 통과한 점들에 대해서만

        next_candidate_idx = argmax(sum_lp_dist)     # 후보들로부터 가장 멀리 떨어진 점 선택
        push!(candidate_pts, pts_c[next_candidate_idx])  # 후보로 추가
        deleteat!(pts_c, next_candidate_idx)         # 목록에서 제거
    end

    @assert !isempty(candidate_pts) "Starting point should always be an option"  # 최소 첫 점은 항상 있어야 함
    return candidate_pts
end

"""
    select_num_robots(polygon,r)

polygon: the polygon whose vertices are eligible locations for placing robots
r: the robot radius
"""
# 다각형 모양과 로봇 반지름 r 로부터 운반에 필요한 로봇 수를 추정.
function select_num_robots(polygon, r)
    # Extract length and width from spectral value decomposition
    pts = vertices_list(polygon)                    # 꼭짓점들
    # svd : 특이값 분해. 점들 행렬의 특이값으로 모양의 "긴 쪽/짧은 쪽" 크기를 가늠. `_` 는 안 쓰는 반환값 버림.
    _, S, _ = svd(hcat(convert.(Vector, pts)...))   # hcat 으로 점들을 열로 붙여 행렬화 후 SVD
    L = S[1] # length                               # 가장 큰 특이값 = 길이(긴 방향)
    W = S[2] # width                                # 둘째 특이값 = 폭(짧은 방향)

    neighbor_dists = map(i -> norm(pts[i] - pts[i+1]), 1:length(pts)-1)  # 이웃 꼭짓점 간 거리들
    push!(neighbor_dists, norm(pts[end] - pts[1]))  # 마지막↔첫 꼭짓점 거리도 추가(닫힌 다각형)
    N = length(pts) - length(findall(neighbor_dists .< 2 * r))  # 너무 가까운 변(2r 미만)을 뺀 유효 꼭짓점 수
    p = perimeter(polygon)                          # 둘레 길이
    x = p / (π * r)                                 # 둘레를 로봇 한 대가 차지하는 폭으로 나눈 대략적 수용량
    if W >= 2 * r                                   # 폭이 로봇 지름 이상이면(넓적한 모양)
        n = Int(floor(max(1, min(N, min(x, 2 * sqrt(x))))))  # 여러 지표의 최솟값으로 로봇 수 결정(최소 1)
    else # long and skinny                          # 길고 가느다란 모양이면
        n = Int(floor(max(1, min(x, 2))))           # 최대 2대 정도로 제한
    end
    @info "number of robots in transport unit: $(n)"  # 결정된 로봇 수 로그
    return n
end

"""
    compute_hierarchical_2d_convex_hulls(scene_tree)

Compute the 2d projected convex hull of each `ObjectNode` and each
`AssemblyNode` in scene_tree.
"""
# 각 부품/조립체의 형상을 바닥평면(2D)으로 투영한 "볼록껍질(convex hull)"을 트리 전체에 대해 계산.
function compute_hierarchical_2d_convex_hulls(scene_tree)
    cvx_hulls = Dict{AbstractID,Vector{GeometryBasics.Point{2,Float64}}}()  # 노드ID → 2D 볼록껍질 점들
    for v in reverse(Graphs.topological_sort_by_dfs(scene_tree))  # 자식 먼저(잎→뿌리) 순서로 순회
        node = get_node(scene_tree, v)
        if matches_template(ObjectNode, node)        # 부품(잎)이면
            pts = map(project_to_2d, GeometryBasics.coordinates(get_base_geom(node)))  # 형상 꼭짓점들을 2D 로 투영
            cvx_hulls[node_id(node)] = convex_hull(pts)  # 그 점들의 볼록껍질 저장
        elseif matches_template(AssemblyNode, node)  # 조립체면
            pts = nothing                            # 자식들의 점을 모을 변수
            for (child_id, tform) in assembly_components(node)  # 각 자식(ID, 상대변환)에 대해
                # 자식의 2D 점 → 3D 로 올림 → 자식 상대변환 적용 → 다시 2D 로 투영. ∘ 는 함수 합성(오른쪽부터 적용).
                composite_tform = project_to_2d ∘ tform ∘ project_to_3d
                child_pts = map(composite_tform, cvx_hulls[child_id])  # 자식 볼록껍질을 부모기준 2D 좌표로 변환
                if pts === nothing                   # 첫 자식이면
                    pts = child_pts                  # 그대로 시작
                else
                    append!(pts, child_pts)          # 이후엔 이어붙임
                end
            end
            cvx_hulls[node_id(node)] = convex_hull(pts)  # 모든 자식 점들의 볼록껍질 저장
        end
    end
    cvx_hulls                                        # 노드별 2D 볼록껍질 딕셔너리 반환
end
