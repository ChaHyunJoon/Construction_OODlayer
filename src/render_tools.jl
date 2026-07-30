# ============================================================================
#  이 파일은 "시각화/렌더링(rendering)"을 담당 — 로봇 건설(construction) 과정을 3D 로 그려서 보여줌.
#  MeshCat(브라우저 3D 뷰어)로 장면(scene)을 그리고, 로봇 이동·조립·OOD 회복 과정을 animation 으로 재생.
#  또 Compose 라이브러리로 위에서 내려다본 2D 도면(적치 계획, 운반유닛 배치 등)도 그림.
#  프로젝트 안 역할: 스케줄러/플래너가 계산한 결과를 사람이 눈으로 확인할 수 있게 화면에 표현하는 층.
#  Julia 문법 참고:
#   · function f(x::T) ... end : x 가 타입 T 일 때만 적용되는 메서드(다중 디스패치 = 타입마다 다른 동작).
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
#   · `::Type` = 인자 타입 제한, `:symbol` = 코드/이름을 값으로 다루는 심볼.
#   · @macro (예: @unpack, @eval, @with_kw) = 코드를 자동 생성/변형하는 매크로.
#   · do ... end 블록 = 함수의 첫 인자로 넘기는 익명함수(주로 atframe 에서 "이 프레임에 실행할 동작").
#   · [f(x) for x in xs] = comprehension(리스트 내포), `θ`,`ω` 등 그리스문자도 그냥 변수 이름.
# ============================================================================

# struct AnimationWrapper : MeshCat 의 애니메이션 객체와 "현재 프레임 번호 카운터"를 한 묶음으로 감싸는 타입.
# (애니메이션을 만들 때마다 지금 몇 번째 프레임인지 따로 추적해야 해서 둘을 같이 들고 다님)
struct AnimationWrapper
    anim::MeshCat.Animation     # MeshCat 의 실제 애니메이션 객체(프레임별 변환 기록을 담음)
    step::Counter               # 현재 프레임 번호를 세는 카운터
end
# 아래는 "외부 생성자" — AnimationWrapper(정수) 처럼 부르면 빈 애니메이션 + 그 정수에서 시작하는 카운터를 만듦.
AnimationWrapper(step::Int) = AnimationWrapper(MeshCat.Animation(MeshCat.Visualizer()), Counter(step))
# Bind the animation to the REAL visualizer. MeshCat's `atframe` only records
# settransform!/setprop! calls that target `animation.visualizer`; binding to a
# throwaway `Visualizer()` (as the method above does) silently records nothing.
# 위 버전은 임시 Visualizer 에 묶여 아무것도 기록 안 됨 → 진짜 vis 를 받아 묶는 버전(다중 디스패치로 인자 수에 따라 구분).
AnimationWrapper(step::Int, vis; fps::Int=30) = AnimationWrapper(MeshCat.Animation(vis; fps=fps), Counter(step))
current_frame(a::AnimationWrapper) = get_counter_status(a.step)  # 현재 프레임 번호 반환(카운터 값 읽기)
# current_frame(::Nothing) : 애니메이션이 없을(Nothing) 때 호출되는 버전 → 0 반환(다중 디스패치)
current_frame(::Nothing) = 0
step_animation!(::Nothing, step=1) = nothing                      # 애니메이션이 없으면 프레임 전진은 아무것도 안 함
# step_animation! : 프레임 카운터를 step 만큼 앞으로 전진(`!` = 인자를 직접 수정). 기본 step=1.
step_animation!(a::AnimationWrapper, step=1) = set_counter_status!(a.step, current_frame(a) + step)
set_current_frame!(a::AnimationWrapper, val) = set_counter_status!(a.step, val)  # 현재 프레임을 val 로 강제 설정

# MeshCat.atframe : MeshCat 의 atframe 함수에 우리 AnimationWrapper 용 동작을 덧붙임(메서드 확장).
# 첫 인자 f 는 "그 프레임에서 실행할 함수"(보통 do 블록). 내부의 진짜 anim.anim 에 위임.
MeshCat.atframe(f, anim::AnimationWrapper, frame::Integer) = atframe(f, anim.anim, frame)
# 애니메이션이 Nothing 일 땐 프레임 기록 없이 그냥 f() 를 즉시 실행(애니메이션 안 만들 때의 처리)
MeshCat.atframe(f, anim::Nothing, frame::Integer) = f()

"""
    construct_color_map(model_spec,id_map)

Given the color code in the `SubFileRef`s of model_spec, create a dict mapping
node ids to colors. Should only be applicable to models (not assemblies).
"""
# 모델 명세의 SubFileRef 들에 적힌 LDraw 색상 코드를 읽어, "노드 ID → 색상" 딕셔너리를 만든다.
function construct_color_map(model_spec, id_map)
    color_map = Dict{Union{String,AbstractID},AlphaColor}()  # 결과: ID → 색상(투명도 포함)
    ldraw_color_dict = LDrawParser.get_color_dict()  # LDraw 색상코드 → 실제 색 변환표 가져오기
    for n in get_nodes(model_spec)                   # 명세의 모든 노드 순회
        if isa(node_val(n), SubFileRef)              # 노드 값이 파일참조면(색상 코드를 가짐)
            color_key = node_val(n).color            # 그 참조의 색상 코드
            if haskey(id_map, node_id(n))            # 이 노드가 대응표에 있으면
                id = id_map[node_id(n)]              # 대응되는 새 ID
                if haskey(ldraw_color_dict, color_key) && isa(id, ObjectID)  # 색상코드가 유효하고 + 물체(ObjectID)이면
                    color_map[id] = ldraw_color_dict[color_key]  # 그 물체에 색 지정
                    color_map[id_map[id]] = color_map[id]        # 반대방향 ID 에도 같은 색 등록(양방향)
                end
            end
        end
    end
    return color_map
end

# @with_kw mutable struct : 키워드 생성자 자동생성 + `mutable` = "생성 후에도 필드 값을 바꿀 수 있음"
# (기본 struct 는 불변. 여기선 vis 노드들을 나중에 채워야 하므로 mutable).
# FactoryVisualizer : 3D 시각화에 필요한 모든 핸들(시각화기, 장면트리, 각종 vis 노드 딕셔너리)을 한 곳에 모은 묶음.
@with_kw mutable struct FactoryVisualizer
    vis = nothing                          # MeshCat 시각화기(브라우저 뷰어). 기본 nothing.
    scene_tree = SceneTree()               # 장면 트리(로봇/부품/조립체의 위치 계층). 기본 빈 트리.
    vis_nodes = Dict{AbstractID,Any}() # Dict from AbstractID -> vis[string(id)]  # 각 ID 의 MeshCat 표시 노드
    geom_nodes = Dict{GeometryKey,Dict{AbstractID,Any}}() # Dict containing the overapproximation layers (HypersphereKey,etc.)  # 형상 근사 레이어별(구/직육면체 등) 노드들
    active_flags = Dict{AbstractID,Any}() # contains vis nodes for flagging agents as active or not  # 에이전트 활성표시용 노드들
    faulted_flags = Dict{AbstractID,Any}() # RED disc under a robot, shown once it is faulted (OOD 1-1)  # 고장난 로봇 표시용(빨간 원판)
    dispatched_flags = Dict{AbstractID,Any}() # CYAN ring under a robot dispatched FROM a depot (hot-swap replacement) — so a distinct unit is visibly tracked driving in
    battery_tints = Dict{AbstractID,Any}() # red body overlays for battery-depleted robots
    staging_nodes = Dict{AbstractID,Any}()  # 적치/조립 위치를 나타내는 표시 노드들
end

"""
    populate_visualizer!(scene_tree,vis,id_map)

Populate the geometry (and transforms) of a MeshCat visualizer.
"""
# 장면 트리의 모든 노드의 형상(geometry)과 위치를 MeshCat 시각화기에 실제로 그려 넣는다.
# `;` 뒤는 키워드 인자. kwargs... 는 "나머지 키워드들을 모아서 그대로 아래로 전달"(파이썬 **kwargs).
function populate_visualizer!(scene_tree, vis;
    color_map=Dict(),          # ID → 색상 표(없으면 빈 딕셔너리)
    material_type=nothing,     # 사용할 재질 타입(없으면 기본 재질)
    wireframe=false,           # 와이어프레임(선만) 표시 여부
    kwargs...
)
    vis_root = vis["root"]                            # 시각화기의 "root" 그룹 노드(여기 아래에 모든 객체를 매달음)
    vis_nodes = Dict{AbstractID,Any}()               # ID → 표시 노드
    base_geom_nodes = Dict{AbstractID,Any}()         # ID → 기본형상 표시 노드
    for v in topological_sort_by_dfs(scene_tree)     # 위상정렬 순서로 각 정점 순회(부모 먼저)
        node = get_node(scene_tree, v)
        id = node_id(node)
        vis_nodes[id] = vis_root[string(id)]         # root 아래에 이 ID 이름의 하위 노드 경로 생성/획득
        vis_node = vis_nodes[id]
        geom_vis_node = vis_node["base_geom"]        # 그 아래 "base_geom" 하위 노드(형상이 들어갈 자리)
        base_geom_nodes[id] = geom_vis_node
        # geometry
        geom = get_base_geom(node)                   # 이 노드의 기본 형상 데이터
        if !(geom === nothing)                       # 형상이 있으면
            if isa(geom, GeometryPrimitive)          # 이미 기본도형(구/박스 등)이면
                M = geom                             # 그대로 사용
            else
                # filter : 조건에 맞는 원소만 남김(파이썬 filter). 여기선 Line(선)은 메시에서 제외.
                filtered_geom = filter(m -> !isa(m, GeometryBasics.Line), geom)
                M = GeometryBasics.Mesh(             # 좌표 + 면 정보로 3D 메시 생성
                    coordinates(filtered_geom),
                    faces(filtered_geom)
                )
            end
            if !(material_type === nothing)          # 재질 타입이 지정됐으면
                mat = material_type(; wireframe=wireframe, kwargs...)  # 재질 객체 생성
                mat.color = get(color_map, id, mat.color)  # 색상표에 이 ID 색이 있으면 적용(없으면 기본색 유지)
                setobject!(geom_vis_node, M, mat)    # 메시 + 재질을 시각화 노드에 설정(화면에 표시)
            else
                setobject!(geom_vis_node, M)         # 재질 없이 메시만 설정
            end
        end
        # settransform!(vis_node,local_transform(node))  # (옛 코드 — 지역 변환 대신 전역 변환 사용)
        settransform!(vis_node, global_transform(node))  # 노드의 전역 위치/회전을 시각화 노드에 적용
    end
    factory_vis = FactoryVisualizer(                 # 위 결과들을 한 묶음(FactoryVisualizer)으로 포장
        vis=vis,
        scene_tree=scene_tree,
        vis_nodes=vis_nodes
    )
    factory_vis.geom_nodes[BaseGeomKey()] = base_geom_nodes  # 기본형상 레이어 등록(BaseGeomKey 라는 레이어 키로)
    factory_vis
end

# 각 로봇/운반유닛 발밑에 "활성 표시용 원판(얇은 원기둥)"을 추가한다(작업 중일 때 켜는 초록 불빛 같은 것).
function add_indicator_nodes!(factory_vis;
    cylinder_depth=0.0025,                # 원판 두께(아주 얇게)
    cylinder_radius_pad=0.02,             # 반지름 여유(에이전트보다 살짝 크게)
    active_color=RGB(0.0, 1.0, 0.0),      # 활성 색(초록)
    faulted_color=RGB(1.0, 0.0, 0.0),     # 고장 색(빨강) — OOD 1-1 고장 로봇 표시
    dispatched_color=RGB(0.0, 0.85, 1.0), # 디스패치 색(시안) — 창고(depot)에서 나온 교체 로봇 표시
    kwargs...
)
    # @unpack a, b, c = obj : Parameters 패키지 매크로 — obj 의 필드 a,b,c 를 같은 이름 지역변수로 한 번에 꺼냄(파이썬엔 없는 편의 기능).
    @unpack vis, vis_nodes, scene_tree = factory_vis
    active_flags = Dict{AbstractID,Any}()
    faulted_flags = Dict{AbstractID,Any}()
    dispatched_flags = Dict{AbstractID,Any}()
    battery_tints = Dict{AbstractID,Any}()
    for n in get_nodes(scene_tree)                   # 장면의 모든 노드 중
        if matches_template(Union{TransportUnitNode,RobotNode}, n)  # 운반유닛 또는 로봇이면
            vis_node = vis_nodes[node_id(n)]         # 그 노드의 표시 노드
            geom = get_base_geom(n, HypersphereKey())  # 그 에이전트를 감싸는 구(bounding sphere)
            mod_center_point = Vector(get_center(geom))  # 구의 중심점을 (수정 가능한) 벡터로
            mod_center_point[3] = 0.0                # z(높이)를 0 으로 → 바닥에 깔리게
            cylinder = GeometryBasics.Cylinder(      # 얇은 원기둥(원판) 생성
                Point(mod_center_point...),          # 윗면 중심 (... 는 벡터를 좌표 인자들로 펼침)
                Point((mod_center_point .- [0.0, 0.0, cylinder_depth])...),  # 아랫면 중심(z 를 두께만큼 내림, .- 는 원소별 뺄셈)
                get_radius(geom) + cylinder_radius_pad,  # 반지름(에이전트 + 여유)
            )
            setobject!(vis_node["active"],           # 그 표시노드의 "active" 자리에 원판 설정
                cylinder,
                MeshLambertMaterial(color=active_color, kwargs...))  # 초록 재질
            active_flags[node_id(n)] = vis_node["active"]  # 나중에 켜고 끌 수 있게 핸들 저장
            if matches_template(RobotNode, n)        # 로봇에만 고장 표시(빨간 원판)를 따로 단다 — active 보다 살짝 크게
                body = get_base_geom(n)
                if body !== nothing
                    tint_node = vis_node["battery_tint"]
                    setobject!(tint_node, body,
                        MeshLambertMaterial(color=RGBA{Float32}(1, 0, 0, 0.72)))
                    setvisible!(tint_node, false)
                    battery_tints[node_id(n)] = tint_node
                end
                fcyl = GeometryBasics.Cylinder(
                    Point((mod_center_point .+ [0.0, 0.0, cylinder_depth])...),       # active 원판보다 살짝 위
                    Point((mod_center_point .- [0.0, 0.0, cylinder_depth])...),
                    get_radius(geom) + 2 * cylinder_radius_pad)
                setobject!(vis_node["faulted"], fcyl,
                    MeshLambertMaterial(color=faulted_color, kwargs...))             # 빨간 재질
                faulted_flags[node_id(n)] = vis_node["faulted"]
                # CYAN ring, larger/higher still, shown while this robot is a depot-dispatched
                # replacement (recovery spare) so a DISTINCT unit is visibly tracked driving in.
                dcyl = GeometryBasics.Cylinder(
                    Point((mod_center_point .+ [0.0, 0.0, 2 * cylinder_depth])...),
                    Point((mod_center_point .- [0.0, 0.0, cylinder_depth])...),
                    get_radius(geom) + 3 * cylinder_radius_pad)
                setobject!(vis_node["dispatched"], dcyl,
                    MeshLambertMaterial(color=dispatched_color, kwargs...))
                dispatched_flags[node_id(n)] = vis_node["dispatched"]
            end
        end
    end
    factory_vis.active_flags = active_flags          # 묶음에 활성표시 노드들 기록
    factory_vis.faulted_flags = faulted_flags        # 고장표시 노드들 기록
    factory_vis.dispatched_flags = dispatched_flags  # 창고 디스패치(교체) 표시 노드들 기록
    factory_vis.battery_tints = battery_tints
    factory_vis
end

# convert_to_renderable : 수학적 집합 표현(LazySets)을 MeshCat 이 그릴 수 있는 형상으로 바꿈(타입별 다중 디스패치).
convert_to_renderable(geom) = geom                                       # 기본: 그대로 둠
convert_to_renderable(geom::LazySets.Ball2) = GeometryBasics.Sphere(geom)  # 2-노름 공 → 구(Sphere)로
convert_to_renderable(geom::Hyperrectangle) = GeometryBasics.HyperRectangle(geom)  # 초직육면체 → 박스로

# 특정 "형상 근사 레이어"(예: 모든 물체의 bounding sphere)를 한꺼번에 표시한다.
# key 기본값 = HypersphereKey()(구 근사). RGBA{Float32}(0,1,0,0.3) = 반투명 초록.
function show_geometry_layer!(factory_vis, key=HypersphereKey();
    color=RGBA{Float32}(0, 1, 0, 0.3),                              # 표시색(반투명 초록)
    wireframe=true,                                                  # 선만 그릴지 여부
    material=MeshLambertMaterial(color=color, wireframe=wireframe),  # 위 옵션으로 만든 재질
)
    @unpack vis_nodes, scene_tree = factory_vis      # 필요한 필드 꺼내기
    geom_nodes = Dict{AbstractID,Any}()
    for (id, vis_node) in vis_nodes                  # 각 ID 와 그 표시노드에 대해
        node = get_node(scene_tree, id)
        geom = get_base_geom(node, key)              # 이 노드의 해당 레이어 형상(예: 구) 가져오기
        node_name = string(key)                      # 레이어 키를 문자열 이름으로
        setobject!(vis_node[node_name], convert_to_renderable(geom), material)  # 그릴 수 있는 형태로 바꿔 표시
        geom_nodes[id] = vis_node[node_name]         # 핸들 저장
    end
    factory_vis.geom_nodes[key] = geom_nodes         # 이 레이어 노드들을 묶음에 등록
    factory_vis
end

"""
    rotate_camera!(vis,anim;

Rotate camera at fixed angular rate while keeping focus on a given point
"""
# 카메라를 한 점(origin)을 바라본 채 일정한 각속도로 빙 돌리는 애니메이션을 만든다.
# θ, dθ 는 그리스문자(theta) 변수 — 각도/각도증가량. rc=반지름, hc=높이.
function rotate_camera!(vis, anim;
    rc=10,                            # 카메라 회전 반지름
    dθ=0.005,                         # 프레임당 각도 증가량(라디안)
    hc=2,                             # 카메라 높이
    θ_start=0,                        # 시작 각도
    k_start=0,                        # 시작 프레임
    k_final=current_frame(anim),      # 끝 프레임(기본은 현재 프레임까지)
    radial_decay_factor=0.0,          # 0 이 아니면 반지름이 점점 줄어 나선형이 됨
    origin=[0.0, 0.0, 0.0],           # 카메라가 바라볼 중심점
)
    θ = θ_start                       # 현재 각도
    for k in k_start:k_final          # 시작~끝 프레임까지 한 프레임씩
        rc -= k * radial_decay_factor # spiral  # 프레임이 갈수록 반지름 줄임(나선)
        # Y-coord is up for camera        # MeshCat 카메라는 Y축이 위쪽
        camera_tform = CoordinateTransformations.Translation(rc * cos(θ), hc, -rc * sin(θ))  # 원 위의 카메라 위치 계산
        θ = wrap_to_pi(θ + dθ)        # 각도 증가 후 -π~π 범위로 감싸기
        atframe(anim, k) do           # k번째 프레임에 아래 동작을 기록(do ... end 가 그 프레임에서 실행될 함수)
            setprop!(vis["/Cameras/default/rotated/<object>"], "position", camera_tform.translation)  # 카메라 위치 속성 갱신
            settransform!(vis["/Cameras/default"], CoordinateTransformations.Translation(origin...))   # 카메라 기준점을 origin 으로 이동
        end
    end
    anim
end

# --- Camera-follow (opt-in) ---------------------------------------------------
# Keep the animation camera centred on the moving "manufacturing point" (centroid of the ACTIVE
# agents) so a whole-build relocation (e.g. after a ForbidZone whole-build translate) stays in
# frame instead of drifting off-screen. INERT unless `CAMERA_FOLLOW[] = true`, so normal runs are
# unchanged. The per-frame target is computed at tuple-build time (demo_utils.jl) and applied in
# the animation's `atframe` block via `settransform!(vis["/Cameras/default"], Translation(t...))`.
# CAMERA_FOLLOW : "카메라가 움직이는 작업지점을 따라가게 할지" on/off 스위치. Ref(...) = 값을 담는 상자
# (전역 플래그를 나중에 바꿀 수 있게 함). 기본 false 라 평소 실행에는 영향 없음.
const CAMERA_FOLLOW = Ref(false)
# Maps the build centroid's WORLD (x,y) to the MeshCat camera TARGET origin. The MeshCat camera is
# Y-UP (see rotate_camera! above: eye at Y=hc, comment "MeshCat 카메라는 Y축이 위쪽"), while the
# WORLD is Z-UP (the /Grid is the world x-y plane). The standard z-up→y-up change of basis is
# (x,y,z)->(x,z,-y); for a build on the ground (z=0) that is (x,0,-y). So as the build translates by
# world Δ=(Δx,Δy), the camera target pans by (Δx,0,-Δy) — i.e. the VIEW follows the exact direction
# the manufacturing site moved. If it comes out mirrored, flip the sign via set_camera_follow_map!
# (tools/demo_energy_adaptive_anim.jl exposes CAM_MAP=x0-y|x0y|xy0|-x0y for a one-env-var switch).
# CAMERA_FOLLOW_MAP : "월드 좌표 (x,y) → 카메라 목표점 (x,0,-y)" 변환 함수를 담은 상자.
# 월드는 z축이 위(Z-UP)이고 MeshCat 카메라는 y축이 위(Y-UP)라, 축을 맞바꾸는 변환이 필요함.
const CAMERA_FOLLOW_MAP = Ref{Any}((x, y) -> (Float64(x), 0.0, -Float64(y)))
# 위 변환 함수를 다른 것으로 갈아끼우는 세터(부호가 뒤집혀 보일 때 매핑을 바꿈).
set_camera_follow_map!(f) = (CAMERA_FOLLOW_MAP[] = f)
# 지금 활성 에이전트들의 평균 위치(작업 중심점)를 구해 카메라가 바라볼 목표점을 계산한다.
function _camera_follow_target(env)
    d = get_active_pos(env)              # 활성 에이전트들의 현재 위치 딕셔너리(ID → 위치)
    isempty(d) && return nothing         # 활성 에이전트가 없으면 따라갈 대상 없음 → nothing
    ps = collect(values(d))              # 위치들만 리스트로
    cx = sum(p -> p[1], ps) / length(ps) # x 평균(중심점 x)
    cy = sum(p -> p[2], ps) / length(ps) # y 평균(중심점 y)
    return CAMERA_FOLLOW_MAP[](cx, cy)   # 중심점을 카메라 목표점 좌표로 변환해 반환
end

# 적치 구역(staging area)들을 바닥에 깔린 원판(얇은 원기둥)으로 시각화한다.
# staging_circles : ID → 적치원(중심+반지름) 딕셔너리. root_key 는 vis 안의 그룹 이름.
function render_staging_areas!(vis, scene_tree, sched, staging_circles, root_key="staging_circles";
    color=RGBA{Float32}(1, 0, 1, 0.1),                              # 표시색(반투명 자홍)
    wireframe=false,
    material=MeshLambertMaterial(color=color, wireframe=wireframe),  # 재질
    include_build_steps=true,                                        # 조립단계 원도 그릴지
    dz=0.0,                                                          # z 오프셋(높이 미세조정)
)
    staging_nodes = Dict{AbstractID,Any}()
    staging_vis = vis[root_key]                      # vis 안의 적치원 그룹 노드
    for (id, geom) in staging_circles                # 각 적치원에 대해
        node = get_node(scene_tree, id)
        sphere = LazySets.Ball2([geom.center..., 0.0], geom.radius)  # 2D 원을 z=0 인 3D 공으로
        ctr = Point(project_to_2d(sphere.center)..., 0.0)            # 중심을 2D 로 투영 후 z=0 점으로
        cylinder = Cylinder(ctr, Point((ctr .- [0.0, 0.0, 0.01])...), sphere.radius)  # 얇은 원기둥 생성
        setobject!(staging_vis[string(id)],          # 그 ID 자리에 원판 표시
            cylinder,
            material,
        )
        staging_nodes[id] = staging_vis[string(id)]  # 핸들 저장
        cargo = get_node(scene_tree, id)             # 이 적치원에 놓일 화물(부품/조립체)
        if isa(cargo, AssemblyNode)                  # 화물이 조립체면
            cargo_node = get_node(sched, AssemblyComplete(cargo))  # 스케줄에서 "조립완료" 노드
        else
            cargo_node = get_node!(sched, ObjectStart(cargo, TransformNode()))  # 부품이면 "물체 시작" 노드(없으면 생성, get_node!)
        end
        t = project_to_3d(project_to_2d(global_transform(start_config(cargo_node)).translation))  # 시작 위치를 2D→3D 로 평탄화(z 제거)
        tform = CoordinateTransformations.Translation(t) ∘ identity_linear_map()  # 평행이동만 하는 변환 (∘ = 함수합성, 회전은 항등)
        settransform!(staging_nodes[id], tform)      # 원판을 그 위치로 이동
        # settransform!(staging_nodes[id],global_transform(start_config(cargo_node)))  # (옛 코드 — 전체 변환을 쓰던 버전)
    end
    for n in node_iterator(sched, topological_sort_by_dfs(sched))  # 스케줄을 위상정렬 순으로 순회
        if matches_template(OpenBuildStep, n)        # "조립단계 시작" 노드면
            id = node_id(n)
            sphere = get_cached_geom(node_val(n).staging_circle)  # 그 단계의 적치원(캐시된 형상)
            ctr = Point(project_to_2d(sphere.center)..., -0.02)   # 중심(z 를 살짝 아래로)
            cylinder = Cylinder(ctr, Point((ctr .- [0.0, 0.0, 0.01])...), sphere.radius)  # 원판 생성
            setobject!(staging_vis[string(id)],
                cylinder,
                material,
            )
            staging_nodes[id] = staging_vis[string(id)]
        end
    end
    staging_nodes                                    # 만든 적치 표시노드들 반환
end

"""
    visualize_staging_plan(vis,sched,scene_tree)

Render arrows pointing from start->goal for LiftIntoPlace nodes.
"""
# 적치 계획을 화살표로 시각화 — 각 부품/조립체가 시작점 → 목표점으로 옮겨가는 경로를 화살표로 그린다.
function visualize_staging_plan(vis, sched, scene_tree;
    objects=false                        # 개별 물체(부품)의 운반 화살표도 그릴지 여부
)
    vis_arrows = vis["arrows"]           # 화살표 그룹
    vis_triads = vis["triads"]           # 좌표축 표시(triad) 그룹
    bounding_vis = vis["bounding_circles"]  # 경계원 그룹
    delete!(vis_arrows)                  # 이전 내용 모두 지우고 새로 그림
    delete!(vis_triads)
    delete!(bounding_vis)
    for n in get_nodes(sched)            # 스케줄의 모든 노드에 대해
        if matches_template(LiftIntoPlace, n)  # "제자리에 들어올리기" 노드면
            # LiftIntoPlace path             # 들어올리기 경로(적치 위치 → 최종 위치)
            p1 = Point(global_transform(start_config(n)).translation...)  # 시작점
            p2 = Point(global_transform(goal_config(n)).translation...)   # 목표점
            lift_vis = ArrowVisualizer(vis_arrows[string(node_id(n))])    # 화살표 시각화기
            setobject!(lift_vis, MeshPhongMaterial(color=RGBA{Float32}(0, 1, 0, 1.0)))  # 초록 화살표
            settransform!(lift_vis, p1, p2)  # p1 → p2 화살표 배치
            # Transport path                 # 운반 경로(시작점 → 적치점)
            cargo = entity(n)                # 이 노드가 다루는 화물
            if isa(cargo, AssemblyNode)      # 조립체면
                c = get_node(sched, AssemblyComplete(cargo))  # 조립완료 노드
                color = RGBA{Float32}(1, 0, 0, 1.0)           # 빨강
            elseif objects == true           # 부품이고 + objects 옵션이 켜져있으면
                # continue
                c = get_node(sched, ObjectStart(cargo))       # 물체 시작 노드
                color = RGBA{Float32}(0, 0, 1, 1.0)           # 파랑
            else
                continue                     # 부품인데 objects=false 면 건너뜀
            end
            p3 = Point(global_transform(start_config(c)).translation...)  # 운반 시작점
            transport_vis = ArrowVisualizer(vis_arrows[string(node_id(c))])
            setobject!(transport_vis, MeshPhongMaterial(color=color))
            settransform!(transport_vis, p3, p1)  # p3 → p1 운반 화살표 배치
        elseif matches_template(AssemblyComplete, n)  # "조립완료" 노드면
            triad_vis = vis_triads[string(node_id(n))]
            setobject!(triad_vis, Triad(0.25))         # 좌표축 표시(크기 0.25) 그리기
            settransform!(triad_vis, global_transform(goal_config(n)))  # 목표 위치에 배치
        end
    end
    for (id, geom) in bounding_circles   # 각 경계원에 대해 (주: bounding_circles 는 외부 스코프 변수)
        if isa(id, AssemblyID)           # ID 가 조립체면
            node = get_node(scene_tree, id)
        else
            node = get_node(scene_tree, node_val(get_node(sched, id)).assembly)  # 아니면 그 노드가 속한 조립체
        end
        sphere = LazySets.Ball2([geom.center..., 0.0], geom.radius)  # 원을 z=0 공으로
        b_vis = bounding_vis[string(id)]
        setobject!(b_vis,
            convert_to_renderable(sphere),
            MeshPhongMaterial(color=RGBA{Float32}(1, 0, 1, 0.1)),  # 반투명 자홍
        )
        cargo_node = get_node(sched, AssemblyComplete(node))
        settransform!(b_vis, global_transform(start_config(cargo_node)))  # 시작 위치에 배치
    end
    return vis_triads, vis_arrows, bounding_vis  # 세 그룹 핸들 반환
end

# 적치 계획을 "거꾸로" 애니메이션 — 부품들이 목표(시작 설정) 위치로 매끄럽게 이동하는 모습을 프레임마다 그린다.
# v_max/ω_max = 최대 직선/회전 속도, ϵ_v/ϵ_ω = 도착 판정 임계값(아주 작은 수), dt = 시간 간격.
function animate_reverse_staging_plan!(vis, vis_nodes, scene_tree, sched, nodes=get_nodes(scene_tree);
    v_max=1.0,
    ω_max=1.0,
    ϵ_v=1e-4,
    ϵ_ω=1e-4,
    dt=0.1,
    interp=false,                        # true 면 속도제어 대신 단순 보간(interpolation) 사용
    interp_steps=10,                     # 보간 단계 수
    objects=false,
    anim=nothing,                        # 애니메이션 객체(없으면 즉시 렌더만)
)
    # jump_to_final_configuration!(scene_tree;set_edges=true)  # (옛 코드)
    graph = deepcopy(get_graph(scene_tree))  # 장면 트리 그래프를 깊은 복사(원본 안 건드리고 작업용 사본 사용)
    # initialize goal sequences for each ObjectNode and AssemblyNode  # 각 노드의 목표 위치열 초기화
    goals = Dict{AbstractID,Vector{CoordinateTransformations.AffineMap}}()  # ID → 거쳐갈 목표 변환들의 리스트
    goal_idxs = Dict{AbstractID,Int}()   # ID → 현재 몇 번째 목표를 향하는지
    interp_idxs = Dict{AbstractID,Int}() # ID → 보간 남은 단계 수
    for node in nodes                    # 대상 노드들에 대해
        if matches_template(AssemblyNode, node)        # 조립체면
            start_node = get_node(sched, AssemblyStart(node))  # 조립체 시작 노드
        elseif matches_template(ObjectNode, node)      # 물체면
            start_node = get_node(sched, ObjectStart(node))    # 물체 시작 노드
        else
            continue                     # 둘 다 아니면 건너뜀
        end
        if !has_vertex(sched, node_id(LiftIntoPlace(node)))  # 이 노드에 "들어올리기" 단계가 없으면
            continue                     # 건너뜀
        end
        lift_node = get_node(sched, LiftIntoPlace(node))     # 들어올리기 노드(현재 미사용)
        goal_list = goals[node_id(node)] = Vector{CoordinateTransformations.AffineMap}()  # 빈 목표 리스트 생성+등록
        goal_idxs[node_id(node)] = 1     # 첫 목표부터
        interp_idxs[node_id(node)] = interp_steps  # 보간 단계 초기화
        # push!(goal_list, global_transform(start_config(lift_node)))  # (옛 코드)
        push!(goal_list, global_transform(start_config(start_node)))  # 목표 = 시작 설정의 전역 위치
    end
    # animate                            # 실제 애니메이션 루프
    active_set = get_all_root_nodes(graph)  # 현재 처리 중인 정점들(루트부터 시작)
    closed_set = Set{Int}()              # 이미 처리 끝낸 정점들
    # _close_node : 지역 함수 정의. begin...end 는 여러 줄을 한 표현식으로 묶음. 정점을 닫고 자식들을 활성집합에 추가.
    _close_node(graph, v, active_set, closed_set) = begin
        push!(closed_set, v)             # 이 정점을 완료 처리
        union!(active_set, outneighbors(graph, v))  # 그 자식들을 활성집합에 합침
    end
    while !isempty(active_set)           # 처리할 정점이 남아있는 동안 반복
        setdiff!(active_set, closed_set) # 활성집합에서 이미 끝난 것 제거
        for v in collect(active_set)     # 활성 정점들에 대해 (collect 로 순회 중 변경 안전하게 복사)
            node = get_node(scene_tree, v)
            if !haskey(goals, node_id(node))  # 목표가 없는 노드면
                _close_node(graph, v, active_set, closed_set)  # 닫고
                continue
            end
            goal_idx = goal_idxs[node_id(node)]  # 현재 목표 인덱스
            if goal_idx > length(goals[node_id(node)])  # 목표를 다 지났으면
                _close_node(graph, v, active_set, closed_set)  # 닫고
                continue
            end
            goal = goals[node_id(node)][goal_idx]  # 현재 향할 목표 변환
            tf_error = relative_transform(global_transform(node), goal)  # 현재 위치와 목표의 차이(오차변환)
            twist = optimal_twist(tf_error, v_max, ω_max, dt)  # 그 오차를 줄이는 최적 속도(직선+회전)
            # @show tf_error, twist          # (디버그 출력 — @show 는 변수와 값을 같이 찍음)
            # 속도가 임계값 이하(도착)거나 보간이 끝났으면 다음 목표로
            if norm(twist.vel) <= ϵ_v && norm(twist.ω) <= ϵ_ω || interp_idxs[node_id(node)] == 0
                goal_idxs[node_id(node)] += 1            # 다음 목표로 인덱스 증가
                interp_idxs[node_id(node)] = interp_steps  # 보간 카운터 리셋
            end
            if interp                        # 보간 방식이면
                isteps = interp_idxs[node_id(node)]  # 남은 보간 단계
                # @show summary(node_id(node)), goal_idxs[node_id(node)], goal, isteps  # (디버그)
                @assert isteps > 0           # 0보다 커야 함(0으로 나누기 방지)
                tform = interpolate_transforms(global_transform(node), goal, 1.0 / isteps)  # 현재→목표를 1/isteps 만큼 보간
                interp_idxs[node_id(node)] -= 1  # 보간 단계 하나 소모
            else                             # 속도제어 방식이면
                tform = global_transform(node) ∘ integrate_twist(twist, dt)  # 현재 위치에 dt 동안의 이동 합성
            end
            set_desired_global_transform!(get_transform_node(node), tform)  # 계산한 새 위치를 적용
        end
        to_update = collect_descendants(graph, active_set, true)  # 갱신해야 할(영향받는) 후손 정점들 모으기
        animate_update_visualizer!(scene_tree, vis_nodes, [get_node(scene_tree, v) for v in to_update]; anim=anim)  # 그 노드들 시각화 갱신
        render(vis)                      # 화면 렌더
    end
end

# 운반유닛(tu) 하나를 위에서 내려다본 2D 도면으로 그린다(화물 윤곽 + 로봇들 + 배치점 + 볼록껍질).
# Compose 패키지로 벡터 그래픽을 그림. 4cm 같은 값은 Measures 의 길이 단위.
function render_transport_unit_2d(scene_tree, tu, cvx_hull=[];
    scale=4cm,                                   # 전체 그림 크기 배율
    hull_thickness=0.01,                         # 볼록껍질 선 두께
    line_thickness=0.0025,                       # 일반 선 두께
    hull_color=RGB(0.0, 1.0, 0.0),               # 볼록껍질 색(초록)
    config_pt_radius=2 * hull_thickness,         # 로봇 배치점 반지름
    config_pt_color=RGB(1.0, 0.5, 0.2),          # 배치점 색(주황)
    robot_color=RGB(0.1, 0.5, 0.9),              # 로봇 색(파랑)
    geom_fill_color=RGBA(0.9, 0.9, 0.9, 0.3),    # 화물 형상 채움색(연회색 반투명)
    geom_stroke_color=RGBA(0.0, 0.0, 0.0, 1.0),  # 화물 형상 외곽선(검정)
    robot_radius=default_robot_radius(),         # 로봇 반지름(기본값)
    rect2d=project_to_2d(get_base_geom(tu, HyperrectangleKey())),  # 운반유닛의 2D 경계상자(그림 범위 산정용)
    xpad=(0, 0),                                 # 좌우 여백
    ypad=(0, 0),                                 # 상하 여백
    bg_color=nothing,                            # 배경색
    overlay_for_single_robot=false,              # 로봇이 1대일 때 덧칠 표시 여부
)
    if length(robot_team(tu)) == 1 && overlay_for_single_robot  # 로봇 1대 + 덧칠 옵션이면
        robot_overlay = (context(),              # 그 로봇 위치에 반투명 원을 추가로 그림
            [Compose.circle(project_to_2d(tform.translation)..., ROBOT_RADIUS) for (id, tform) in robot_team(tu)]...,  # 각 로봇 위치에 원(리스트 컴프리헨션 후 ... 로 펼침)
            Compose.fill(RGBA(robot_color, 0.8)),
        )
    else
        robot_overlay = (context(),)             # 아니면 빈 컨텍스트
    end
    set_default_graphic_size(rect2d.radius[1] * scale, rect2d.radius[2] * scale)  # 그림 기본 크기를 경계상자 비율로 설정
    Compose.compose(                             # 여러 그래픽 레이어를 겹쳐 합성(뒤로 갈수록 아래층)
        context(units=unit_box_from_rect(rect2d, xpad=xpad, ypad=ypad)),  # 좌표계(단위박스) 설정
        (context(),
            robot_overlay,                       # 로봇 덧칠 레이어
            plot_base_geom_2d(get_node(scene_tree, cargo_id(tu)), scene_tree;  # 화물의 2D 형상 그리기
                fill_color=geom_fill_color,
                stroke_color=geom_stroke_color,
            ),
            Compose.linewidth(line_thickness * max(h, w)),  # 선 두께 설정(주: h,w 는 외부 스코프 변수)
            (context(),                          # 볼록껍질(convex hull) 다각형 레이어
                Compose.polygon([(p[1], p[2]) for p in cvx_hull]),  # 껍질 점들로 다각형
                Compose.stroke(hull_color),
                Compose.linewidth(hull_thickness * max(h, w)),
                Compose.fill(nothing),           # 채움 없음(선만)
            ),
            (context(),                          # 로봇 배치점(작은 점들) 레이어
                [Compose.circle(project_to_2d(tform.translation)..., config_pt_radius * max(h, w)) for (id, tform) in robot_team(tu)]...,
                Compose.fill(config_pt_color),
            ),
        ),
        (context(),                              # 실제 로봇(원) 레이어
            [Compose.circle(project_to_2d(tform.translation)..., robot_radius) for (id, tform) in robot_team(tu)]...,
            Compose.fill(robot_color),
        ),
        (context(), Compose.rectangle(), Compose.fill(bg_color))  # 맨 아래 배경 사각형
    )
end

# 한 노드(및 그 자식들)의 형상을 위에서 본 2D 다각형들로 그린다.
# `_` 로 시작하는 키워드는 "내부용 옵션" 관례(어떤 종류의 면을 표시할지 등).
function plot_base_geom_2d(node, scene_tree;
    fill_color=RGBA(1.0, 0.0, 0.0, 0.5),     # 채움색(반투명 빨강)
    stroke_color=RGBA(0.0, 0.0, 0.0, 1.0),   # 외곽선(검정)
    _show_lines=false,                       # 선(Line) 표시 여부
    _show_triangles=false,                   # 삼각형 표시 여부
    _show_quadrilaterals=true,               # 사각형 표시 여부
    _use_unit_box=false,                     # 자체 단위박스 좌표계 쓸지
    tform=identity_linear_map(),             # 형상에 먼저 적용할 변환(기본 항등=그대로)
    geom_key=BaseGeomKey(),                  # 어떤 형상 레이어를 그릴지
)
    polygon_pts = []                         # 그릴 다각형들의 점목록 모음
    for geom_element in recurse_child_geometry(node, scene_tree, geom_key)  # 자식들까지 재귀로 형상 수집
        if isa(geom_key, BaseGeomKey)        # 기본형상(실제 메시)이면
            for geom in geom_element         # 각 면에 대해
                if isa(geom, GeometryBasics.Line) && _show_lines  # 선이고 표시옵션 켜져있으면
                    push!(polygon_pts, Vector([(p[1], p[2]) for p in tform(geom).points]))  # 변환 후 (x,y)만 뽑아 추가
                elseif isa(geom, Triangle) && _show_triangles     # 삼각형이면
                    push!(polygon_pts, Vector([(p[1], p[2]) for p in tform(geom).points]))
                elseif isa(geom, GeometryBasics.Quadrilateral) && _show_quadrilaterals  # 사각형이면
                    push!(polygon_pts, Vector([(p[1], p[2]) for p in tform(geom).points]))
                end
            end
        elseif isa(geom_key, HyperrectangleKey)  # 직육면체 근사 레이어면
            r = tform(geom_element)          # 변환 적용한 직육면체
            push!(polygon_pts, [             # 그 직육면체의 네 모서리(중심±반지름)로 사각형 만들기
                (r.center[1] - r.radius[1], r.center[2] - r.radius[2]),
                (r.center[1] - r.radius[1], r.center[2] + r.radius[2]),
                (r.center[1] + r.radius[1], r.center[2] + r.radius[2]),
                (r.center[1] + r.radius[1], r.center[2] - r.radius[2]),
            ])
        end
    end
    if _use_unit_box                         # 단위박스 좌표계를 쓰면
        r = get_base_geom(node, HyperrectangleKey())  # 노드의 경계상자로
        unit_box = unit_box_from_rect(r)     # 단위박스 생성
        ctx = context(units=unit_box)        # 그 좌표계 컨텍스트
    else
        ctx = context()                      # 아니면 기본 컨텍스트
    end
    Compose.compose(                         # 다각형들을 하나의 그래픽으로 합성
        ctx,
        Compose.polygon(polygon_pts),        # 수집한 다각형들 그리기
        Compose.fill(fill_color),
        Compose.stroke(stroke_color),
    )
end

# 직육면체(r)로부터 Compose 의 UnitBox(좌표 원점과 폭/높이) 좌표계를 만든다.
function unit_box_from_rect(r;
    pad=0.0,                                 # 사방 여백(기본 0)
    xpad=(pad, pad),                         # 좌우 여백(왼쪽, 오른쪽)
    ypad=(pad, pad),                         # 상하 여백
)
    unit_box = UnitBox(
        r.center[1] - r.radius[1] - xpad[1],  # 좌표 원점 x(왼쪽 끝 - 여백)
        r.center[2] - r.radius[2] - ypad[1],  # 좌표 원점 y(아래쪽 끝 - 여백)
        2 * r.radius[1] + sum(xpad),          # 전체 폭(지름 + 좌우여백 합)
        2 * r.radius[2] + sum(ypad),          # 전체 높이(지름 + 상하여백 합)
    )
end

"""
    animate_preprocessing_steps!

Step through the different phases of preprocessing
"""
# 전처리 단계들을 차례로 보여주는 애니메이션(실제 형상 → 직육면체 근사 → 적치이동 → 다시 형상 ... 의 시연).
function animate_preprocessing_steps!(
    factory_vis,
    sched;
    anim=nothing,
    dt=0.0,
    interp_steps=80,
    kwargs...,
)
    @unpack vis, vis_nodes, scene_tree, geom_nodes = factory_vis  # 필요한 필드 꺼내기
    base_geom_nodes = geom_nodes[BaseGeomKey()]         # 실제 형상 레이어 노드들
    rect_nodes = geom_nodes[HyperrectangleKey()]        # 직육면체 근사 레이어 노드들

    atframe(anim, current_frame(anim)) do               # 현재 프레임에 아래 초기 설정을 기록
        # Hide robots                                   # 로봇/운반유닛 숨기기
        for n in get_nodes(scene_tree)
            if isa(n, Union{TransportUnitNode,RobotNode})
                setvisible!(vis_nodes[node_id(n)], false)
            end
        end
        setvisible!(base_geom_nodes, true)              # 실제 형상은 보이게
        setvisible!(rect_nodes, false)                  # 직육면체는 숨김
        jump_to_final_configuration!(scene_tree; set_edges=true)  # 완성된 최종 배치로 점프
        update_visualizer!(scene_tree, vis_nodes)       # 시각화 갱신
    end
    step_animation!(anim)                               # 다음 프레임으로
    # First, show the components of the final assembly turning into the hyperectangles  # 부품들을 직육면체로 변신
    for (ii, n) in enumerate(get_nodes(scene_tree))     # (번호 ii, 노드 n)
        if isa(n, Union{AssemblyNode,ObjectNode})       # 조립체/물체면
            atframe(anim, current_frame(anim)) do
                setvisible!(rect_nodes[node_id(n)], true)        # 직육면체 보이게
                setvisible!(base_geom_nodes[node_id(n)], false)  # 실제 형상 숨김
                update_visualizer!(scene_tree, vis_nodes, [n])
            end
            if mod(ii, 2) == 0                          # 두 개마다 한 프레임 전진(속도 조절)
                step_animation!(anim)
            end
        end
    end
    # Show objects moving to the staging/building locations  # 조립체들이 적치/조립 위치로 이동
    animate_reverse_staging_plan!(
        vis, vis_nodes, scene_tree, sched,
        filter(n -> isa(n, AssemblyNode), get_nodes(scene_tree));  # 조립체만 골라서
        anim=anim, interp=true, dt=dt, interp_steps=interp_steps, kwargs...
    )

    # Go from hyperectangles back to the full geometries (legos)  # 직육면체 → 다시 실제 레고 형상
    for n in get_nodes(scene_tree)
        if isa(n, ObjectNode)                           # 물체에 대해
            atframe(anim, current_frame(anim)) do
                setvisible!(base_geom_nodes[node_id(n)], true)   # 실제 형상 보이게
                setvisible!(rect_nodes[node_id(n)], false)       # 직육면체 숨김
                update_visualizer!(scene_tree, vis_nodes, [n])
            end
        end
    end
    set_current_frame!(anim, current_frame(anim) + 10)  # 프레임을 10 건너뜀(잠깐 멈춤 효과)

    # Show the legos going to the starting locations    # 레고들이 시작 위치로 이동
    animate_reverse_staging_plan!(vis, vis_nodes, scene_tree, sched,
        filter(n -> isa(n, ObjectNode), get_nodes(scene_tree)); dt=dt, interp=true,  # 물체만 골라서
        interp_steps=interp_steps, anim=anim, kwargs...
    )
    atframe(anim, current_frame(anim)) do
        setvisible!(rect_nodes, false)                  # 직육면체 모두 숨김
        setvisible!(base_geom_nodes, true)              # 실제 형상 모두 보이게
    end
    step_animation!(anim)
    # Make robots visible again                         # 로봇 다시 보이게
    for n in get_nodes(scene_tree)
        if isa(n, Union{TransportUnitNode,RobotNode})
            atframe(anim, current_frame(anim)) do
                setvisible!(vis_nodes[node_id(n)], true)
                update_visualizer!(scene_tree, vis_nodes, [n])
            end
        end
    end
    step_animation!(anim)
    atframe(anim, current_frame(anim)) do
        set_scene_tree_to_initial_condition!(scene_tree, sched; remove_all_edges=true)  # 장면을 초기 상태로 되돌림
        update_visualizer!(scene_tree, vis_nodes)
    end
    set_current_frame!(anim, current_frame(anim) + 10)  # 끝에 여유 프레임
    vis
end

# MeshCat.setvisible! 에 "여러 노드 딕셔너리를 한 번에 보이게/숨기게" 하는 메서드를 추가(확장).
function MeshCat.setvisible!(vis_nodes::Dict{AbstractID,Any}, val)
    for (k, v) in vis_nodes      # 딕셔너리의 각 표시 노드에 대해
        setvisible!(v, val)      # val(true/false) 대로 표시 토글
    end
end

"""
    update_visualizer!(scene_tree, vis_nodes)

Update the MeshCat transform tree.
"""
# update_visualizer! : 주어진 노드들의 현재 전역 위치를 MeshCat 변환 트리에 반영(여러 버전을 다중 디스패치로 제공).
# 버전 1 — (표시노드 딕셔너리, 노드목록) 을 받는 가장 단순한 형태.
function update_visualizer!(vis_nodes, nodes)
    for n in nodes               # 각 노드에 대해
        settransform!(vis_nodes[node_id(n)], global_transform(n))  # 표시노드를 그 노드의 전역 위치로 이동
    end
    return vis_nodes
end
# 버전 2 — 첫 인자로 SceneTree 를 받는 형태(::SceneTree 로 구분). 내용은 위와 동일.
function update_visualizer!(scene_tree::SceneTree, vis_nodes, nodes)
    for n in nodes
        settransform!(vis_nodes[node_id(n)], global_transform(n))
    end
    return vis_nodes
end
# 버전 3 — nodes 를 키워드(기본=전체 노드)로 받아 버전 2 에 위임.
function update_visualizer!(scene_tree::SceneTree, vis_nodes; nodes=get_nodes(scene_tree))
    update_visualizer!(scene_tree, vis_nodes, nodes)
end
# 버전 4 — FactoryVisualizer 묶음을 받아 그 안의 트리/노드를 꺼내 위임. args... 는 나머지 인자 그대로 전달.
function update_visualizer!(factory_vis::FactoryVisualizer, args...)
    update_visualizer!(factory_vis.scene_tree, factory_vis.vis_nodes, args...)
end

# 위 갱신을 "애니메이션 프레임에 기록하면서" 수행. anim 이 없으면 그냥 즉시 갱신.
function animate_update_visualizer!(args...; anim=nothing, step=1)
    if anim === nothing                  # 애니메이션이 없으면
        return update_visualizer!(args...)  # 즉시 갱신만
    else
        atframe(anim.anim, current_frame(anim)) do  # 현재 프레임에 갱신 동작을 기록
            return update_visualizer!(args...)
        end
        step_animation!(anim, step)      # 프레임 전진
    end
end

# 시뮬레이션 매 스텝마다 호출 — "지금 화면에 갱신해야 할 노드들"과 활성/비활성 표시 대상들을 추려 반환한다.
# env 는 시뮬레이션 환경(장면트리·스케줄·캐시 등을 담은 큰 객체).
function visualizer_update_function!(
    factory_vis, env, newly_updated=Set{Int}();  # newly_updated = 이번에 새로 갱신된 정점들
    # render_stages=true
)
    @unpack vis, vis_nodes, staging_nodes = factory_vis

    # OOD 1-2: draw any active restriction (no-go) zones so the detour is visible.
    draw_restriction_zones!(vis)         # 활성 통행금지 구역을 그려서 우회가 보이게 함
    # OOD 1-1: draw the spare-robot REPOSITORY stations + any decommissioned (hot-swapped) bodies.
    draw_spare_depots!(vis)              # 방위별 예비 로봇 창고(depot) 스테이션 표시
    draw_decommissioned_robots!(vis)    # 교체로 은퇴한 고장 로봇의 회색 마커 표시

    closed_steps_nodes = []              # 닫힌(비활성) 조립단계 표시노드들
    active_build_nodes = []              # 활성 조립단계 표시노드들
    fac_active_flags_nodes = []          # 활성 표시를 켤 에이전트 ID 들

    scene_nodes = Set{SceneNode}()       # 이번에 갱신할 장면 노드들의 집합(중복 방지)
    for id in get_vtx_ids(ConstructionBots.rvo_global_id_map())  # RVO(충돌회피) 대상 에이전트들에 대해
        has_vertex(env.scene_tree, id) || continue   # hot-swap/replace 로 씬트리에서 빠진 stale 노드 skip(BoundsError 방지)
        agent = get_node(env.scene_tree, id)
        push!(scene_nodes, agent)        # 에이전트 추가
        for vp in collect_descendants(env.scene_tree, agent)  # 그 에이전트의 모든 후손(자식 부품 등)도
            push!(scene_nodes, get_node(env.scene_tree, vp))
        end
    end
    # if render_stages
    closed_steps = setdiff(keys(staging_nodes), env.active_build_steps)  # 활성단계가 아닌 적치노드들 = 닫힌 단계
    for id in closed_steps
        push!(closed_steps_nodes, staging_nodes[id])
        # setvisible!(staging_nodes[id],false)  # (직접 숨기는 대신 목록만 반환 — 호출측에서 처리)
    end
    for id in env.active_build_steps     # 현재 활성인 조립단계들
        push!(active_build_nodes, staging_nodes[id])
        # setvisible!(staging_nodes[id],true)
    end
    # end

    # setvisible!(factory_vis.active_flags,false)

    for v in union(env.cache.active_set, newly_updated)  # 활성 집합 + 새로 갱신된 정점들 합집합 순회
        node = get_node(env.sched, v)
        if matches_template(EntityGo, node)         # 에이전트 이동 노드면
            agent = entity(node)
            object = agent                          # 대상 객체 = 에이전트 자신
        elseif matches_template(Union{FormTransportUnit,DepositCargo}, node)  # 운반유닛 형성/화물 내려놓기면
            agent = entity(node)
            object = get_node(env.scene_tree, cargo_id(entity(node)))  # 대상 = 그 화물
        else
            agent = nothing                         # 그 외는 해당 없음
            object = nothing
        end
        if matches_template(Union{RobotNode,TransportUnitNode}, agent)  # 에이전트가 로봇/운반유닛이고
            if ConstructionBots.parent_build_step_is_active(node, env)  # 그 부모 조립단계가 활성이며
                if ConstructionBots.cargo_ready_for_pickup(node, env)   # 화물이 픽업 준비됐으면
                    push!(fac_active_flags_nodes, node_id(agent))       # 활성표시 켤 대상에 추가
                    # setvisible!(factory_vis.active_flags[node_id(agent)],true)
                end
            end
        end
        if !(object === nothing) && has_vertex(env.scene_tree, node_id(object)) && !(object in scene_nodes)  # 대상 객체가 씬트리에 살아있고 아직 집합에 없으면
            push!(scene_nodes, object)              # 추가
            for vp in collect_descendants(env.scene_tree, object)  # 그 후손들도 추가
                push!(scene_nodes, get_node(env.scene_tree, vp))
            end
        end
    end
    # OOD 1-1: robots currently faulted (FAULTED_ROBOTS grows monotonically), so this reflects
    # the faults observed up to this step -> the RED flag turns on from the breakdown step onward.
    fac_faulted_flags_nodes = collect(keys(ConstructionBots.faulted_robots()))
    # OOD 1-1: robots dispatched FROM a depot as a hot-swap replacement (recovery spares grow
    # monotonically), so the CYAN ring turns on from the swap step onward and tracks the unit
    # driving in from the depot.
    fac_dispatched_flags_nodes = collect(ConstructionBots.recovery_spares())
    fac_battery_tint_nodes = AbstractID[]
    try
        swapped = ConstructionBots.hot_swap_assets()
        for entry in ConstructionBots.ood_truth_log()
            truth = entry.truth
            truth isa ConstructionBots.BatteryTruth &&
                truth.soc_after <= ConstructionBots.REPLACE_SOC_THRESHOLD[] &&
                !haskey(swapped, truth.robot) &&
                push!(fac_battery_tint_nodes, truth.robot)
        end
    catch
    end
    return scene_nodes, closed_steps_nodes, active_build_nodes, fac_active_flags_nodes,
           fac_faulted_flags_nodes, fac_dispatched_flags_nodes, unique(fac_battery_tint_nodes)
end

# 노드들의 위치를 갱신하고 화면을 렌더하는 보조 함수(주: 여기 vis 는 외부 스코프 변수).
function call_update!(scene_tree, vis_nodes, nodes, dt)
    update_visualizer!(scene_tree, vis_nodes, nodes)  # 위치 갱신
    render(vis)                                       # 렌더
end

# 모델 명세 그래프를, 각 조립단계 노드 자리에 실제 조립 사진(png)을 넣어 시각화한다.
function render_model_spec_with_pictures(model_spec;
    base_image_path="",                  # 사진 파일들이 있는 기본 폴더 경로
    bg_color="white",                    # 노드 배경색
    stroke_color="black",                # 노드 외곽선
    use_original_coords=true,            # 원본 그래프 좌표를 쓸지
    picture_scale=2.0,                   # 사진 크기 배율
    scale=1,                             # 전체 배율
    aspect_stretch=(1.0, 1.0),           # 가로/세로 늘림비
    label_pos=(0.0, 0.0),                # 라벨 위치
    label_fontsize=14pt,                 # 라벨 글자 크기(pt = 포인트 단위)
    label_radius=1cm,                    # 라벨 배경원 반지름
    label_bg_color=nothing,              # 라벨 배경색
    label_stroke_color=nothing,          # 라벨 테두리색
    labels=Dict(),                       # 노드ID → 라벨 텍스트 딕셔너리
    kwargs...
)
    plt_spec = contract_by_predicate(model_spec, n -> matches_template(BuildingStep, n))  # 조립단계 노드들을 합쳐 간략화
    plt = display_graph(plt_spec, scale=1) #,enforce_visited=true)  # (먼저 그려 좌표 확보)
    # match pictures to assembly names    # 사진 파일을 조립 이름에 매칭
    counts = Dict()                      # 부모이름별 등장 횟수(파일명 번호용)
    file_names = Dict()                  # 노드ID → 사진 파일경로
    for n in node_iterator(plt_spec, topological_sort_by_dfs(plt_spec))  # 위상정렬 순으로 노드 순회
        parent_name = node_val(n).parent # 이 노드가 속한 부모(하위모델) 이름
        count = get!(counts, parent_name, 1)  # 그 부모의 현재 카운트(없으면 1로 시작)
        name_string = split(node_val(n).parent, ".")[1]  # 확장자 앞부분만 이름으로 사용
        filename = joinpath(base_image_path, string(name_string, @sprintf("%02i", count), ".png"))  # "이름01.png" 식 경로 (@sprintf 로 2자리 0채움)
        file_names[node_id(n)] = filename  # 노드ID → 파일경로 등록
        counts[parent_name] = counts[parent_name] + 1  # 카운트 +1
    end
    if use_original_coords               # 원본 좌표를 쓰면
        coords = get_layout_coords(model_spec)  # 원본 그래프 레이아웃 좌표
        x = [coords[1][get_vtx(model_spec, id)] for id in get_vtx_ids(plt_spec)]  # 각 노드의 x 좌표 추출
        y = [coords[2][get_vtx(model_spec, id)] for id in get_vtx_ids(plt_spec)]  # y 좌표 추출
    else
        x, y = get_layout_coords(plt_spec)  # 아니면 간략화 그래프의 레이아웃 좌표
    end

    # _color_func : 라벨이 있는 노드면 색 c, 없으면 nothing 을 반환하는 익명함수(삼항 ?: 사용).
    _color_func = (v, c) -> haskey(labels, get_vtx_id(plt_spec, v)) ? c : nothing

    plt = display_graph(plt_spec, (x, y),  # 좌표 (x,y) 로 그래프 그리기
        # draw_node_function : 각 노드를 어떻게 그릴지 정하는 콜백(그래프 G, 정점 v 를 받아 그래픽 반환).
        draw_node_function=(G, v) -> Compose.compose(  # 여러 레이어를 겹쳐 한 노드 그림 구성
            Compose.context(),
            (Compose.context(),              # 라벨 레이어(텍스트 + 배경원)
                (context(),
                    Compose.text(
                        label_pos...,
                        get(labels, get_vtx_id(plt_spec, v), ""),  # 이 노드의 라벨 텍스트(없으면 빈 문자열)
                        hcenter,             # 가로 중앙정렬
                        vcenter,             # 세로 중앙정렬
                    ),
                    Compose.fontsize(label_fontsize),
                ),
                (context(),
                    Compose.circle(label_pos..., label_radius),  # 라벨 배경원
                    Compose.fill(_color_func(v, label_bg_color)),    # 라벨 있을 때만 채움
                    Compose.stroke(_color_func(v, label_stroke_color)),
                ),
            ),
            (Compose.context(), bitmap("image/png", read(file_names[get_vtx_id(G, v)]),  # 사진(png) 비트맵 레이어
                -(picture_scale - 1.0) / 2,  # 배율에 맞춰 중앙정렬되도록 위치 보정
                -(picture_scale - 1.0) / 2,
                picture_scale,
                picture_scale,
            )),
            (Compose.context(), circle(), fill(bg_color), Compose.stroke(stroke_color)),  # 맨 아래 배경원
        ),
        scale=scale,
        aspect_stretch=aspect_stretch,
    )
end

get_id(s::String) = s   # 문자열은 그 자체가 ID — 그대로 반환(다른 타입용 get_id 들의 문자열 버전)
# Rendering schedule nodes
# _title_string : 그래프 노드 안에 표시할 짧은 제목 문자열을 노드 종류별로 정의(다중 디스패치).
# 기본 버전: 타입 이름의 마지막 부분 첫 글자를 사용. where {S<:SceneNode} = "S 는 SceneNode 의 하위타입".
_title_string(n::S) where {S<:SceneNode} = split(string(typeof(n)), ".")[end][1]
_title_string(n::RobotNode) = "R"          # 로봇 = R
_title_string(n::ObjectNode) = "O"         # 물체 = O
_title_string(n::AssemblyNode) = "A"       # 조립체 = A
_title_string(n::TransportUnitNode) = "T"  # 운반유닛 = T

_title_string(::BuildingStep) = "B"        # 조립단계 = B
_title_string(::SubFileRef) = "S"          # 파일참조 = S
_title_string(::SubModelPlan) = "M"        # 하위모델 = M

_title_string(n::ConstructionBots.EntityConfigPredicate) = _title_string(n.entity)  # 설정조건 노드는 그 안의 엔티티 제목을 따름
_title_string(::ConstructionBots.RobotStart) = "R"          # 로봇 시작
_title_string(n::ConstructionBots.ObjectStart) = "O"        # 물체 시작
_title_string(::ConstructionBots.AssemblyStart) = "sA"      # 조립체 시작(start Assembly)
_title_string(::ConstructionBots.AssemblyComplete) = "cA"   # 조립체 완료(complete Assembly)
_title_string(::ConstructionBots.OpenBuildStep) = "oB"      # 조립단계 열기
_title_string(::ConstructionBots.CloseBuildStep) = "cB"     # 조립단계 닫기
_title_string(::ConstructionBots.RobotGo) = "G"             # 로봇 이동
_title_string(::ConstructionBots.FormTransportUnit) = "F"   # 운반유닛 형성
_title_string(::ConstructionBots.DepositCargo) = "D"        # 화물 내려놓기
_title_string(::ConstructionBots.TransportUnitGo) = "T"     # 운반유닛 이동
_title_string(::ConstructionBots.LiftIntoPlace) = "L"       # 제자리로 들어올리기
_title_string(::ConstructionBots.ProjectComplete) = "P"     # 프로젝트 완료

# 아래는 "코드로 코드를 생성"하는 부분 — 여러 함수를 반복문으로 한꺼번에 정의.
# :(이름) 은 "심볼/표현식"(코드 자체를 값으로 다룸). @eval 은 그 코드를 실제 정의로 평가(매크로).
# 효과: 각 함수에 "CustomNode/ScheduleNode 를 받으면 그 안의 실제 값으로 위임"하는 메서드를 자동 추가.
for op in (
    :(_node_shape),
    :(_node_color),
    :(_title_string),
    :(_subtitle_string),
    :(_subtitle_text_scale),
    :(_title_text_scale)
)
    @eval $op(n::CustomNode, args...) = $op(node_val(n), args...)   # CustomNode → 그 노드 값으로 위임
    @eval $op(n::ScheduleNode, args...) = $op(n.node, args...)      # ScheduleNode → 그 안 노드로 위임
end

_subtitle_text_scale(n::Union{ConstructionPredicate,SceneNode}) = 0.28  # 부제 글자 크기 비율
_title_text_scale(n::Union{ConstructionPredicate,SceneNode}) = 0.28     # 제목 글자 크기 비율

# _subtitle_string : 노드 아래 표시할 부제(주로 ID 문자열)를 종류별로 정의.
# "$(...)" 는 문자열 보간 — 괄호 안 값을 문자열에 끼워넣음(파이썬 f-string 의 {} 와 같음).
_subtitle_string(n::SceneNode) = "$(get_id(node_id(n)))"                # 기본: ID 그대로
_subtitle_string(n::Union{EntityGo,EntityConfigPredicate,FormTransportUnit,DepositCargo}) = _subtitle_string(entity(n))  # 그 안 엔티티의 부제를 따름
_subtitle_string(n::BuildPhasePredicate) = _subtitle_string(n.assembly) # 조립체의 부제를 따름
_subtitle_string(n::ObjectNode) = "o$(get_id(node_id(n)))"             # 물체: "o" + ID
_subtitle_string(n::RobotNode) = "r$(get_id(node_id(n)))"             # 로봇: "r" + ID
_subtitle_string(n::AssemblyNode) = "a$(get_id(node_id(n)))"          # 조립체: "a" + ID
# 운반유닛: 화물이 조립체면 "a", 아니면 "o" 접두어(삼항 ?: 로 분기)
_subtitle_string(n::TransportUnitNode) = cargo_type(n) == AssemblyNode ? "a$(get_id(node_id(n)))" : "o$(get_id(node_id(n)))"


# 자주 쓰는 색상들을 상수로 정의(RGB 는 0~1 범위의 빨강/초록/파랑).
SPACE_GRAY = RGB(0.2, 0.2, 0.2)     # 진회색
BRIGHT_RED = RGB(0.6, 0.0, 0.2)     # 진빨강
LIGHT_BROWN = RGB(0.6, 0.3, 0.2)    # 연갈색
LIME_GREEN = RGB(0.2, 0.6, 0.2)     # 라임그린
BRIGHT_BLUE = RGB(0.0, 0.4, 1.0)    # 밝은 파랑

# _node_color : 노드 종류별 표시 색을 정의(다중 디스패치).
_node_color(::RobotNode) = SPACE_GRAY         # 로봇 = 진회색
_node_color(::ObjectNode) = SPACE_GRAY        # 물체 = 진회색
_node_color(::AssemblyNode) = BRIGHT_BLUE     # 조립체 = 파랑
_node_color(::TransportUnitNode) = LIME_GREEN # 운반유닛 = 초록

_node_color(::BuildingStep) = LIGHT_BROWN     # 조립단계 = 갈색
_node_color(::SubFileRef) = BRIGHT_RED        # 파일참조 = 빨강
_node_color(::SubModelPlan) = SPACE_GRAY      # 하위모델 = 회색

_node_color(::ConstructionBots.EntityConfigPredicate) = _node_color(n.entity)  # 설정조건: 그 엔티티 색(주: n 미지정 — 호출시 외부 n 필요)
_node_color(::ConstructionBots.RobotStart) = SPACE_GRAY        # 로봇 시작 = 진회색
_node_color(::ConstructionBots.ObjectStart) = SPACE_GRAY       # 물체 시작 = 진회색
_node_color(::ConstructionBots.AssemblyStart) = SPACE_GRAY     # 조립체 시작 = 진회색
_node_color(::ConstructionBots.AssemblyComplete) = SPACE_GRAY  # 조립체 완료 = 진회색
_node_color(::ConstructionBots.OpenBuildStep) = LIGHT_BROWN    # 조립단계 열기 = 갈색
_node_color(::ConstructionBots.CloseBuildStep) = LIGHT_BROWN   # 조립단계 닫기 = 갈색
_node_color(::ConstructionBots.ProjectComplete) = SPACE_GRAY   # 프로젝트 완료 = 진회색
_node_color(::ConstructionBots.RobotGo) = LIME_GREEN           # 로봇 이동 = 라임그린
_node_color(::ConstructionBots.FormTransportUnit) = LIME_GREEN # 운반유닛 형성 = 라임그린
_node_color(::ConstructionBots.TransportUnitGo) = LIME_GREEN   # 운반유닛 이동 = 라임그린
_node_color(::ConstructionBots.DepositCargo) = LIME_GREEN      # 화물 내려놓기 = 라임그린
_node_color(::ConstructionBots.LiftIntoPlace) = BRIGHT_BLUE    # 제자리로 들어올리기 = 파랑

# 그래프 g 의 정점 v 를 그리는 함수 — 정점번호를 실제 노드로 바꿔 노드 버전 draw_node 에 위임.
function draw_node(g::AbstractCustomNGraph, v, args...; kwargs...)
    draw_node(get_node(g, v), args...; kwargs...)
end

# 적치 계획 전체를 위에서 본 2D 도면(원들 + 조립체 형상)으로 그리고, 선택적으로 PDF 로 저장한다.
function plot_staging_area(
    sched, scene_tree, staging_circles;
    save_file_name="staging_area.pdf",   # 저장 파일명
    save_image=true,                     # 파일로 저장할지
    nominal_width=30cm,                  # 그림 기준 너비
    node_list=node_iterator(sched, topological_sort_by_dfs(sched)),  # 순회할 노드 목록(위상정렬 순)
    show_intermediate_stages=false,      # 중간 적치원도 그릴지
)

    _final_stage_stroke_color = "red"    # 최종 적치원 외곽선(빨강)
    _final_stage_bg_color = nothing      # 최종 적치원 채움(없음)

    _stage_stroke_color = "yellow"       # 중간 적치원 외곽선(노랑)
    _stage_bg_color = RGBA(1.0, 1.0, 0.0, 0.5)  # 중간 적치원 채움(반투명 노랑)

    _bounding_stroke_color = "blue"      # 경계원 외곽선(파랑)
    _bounding_bg_color = nothing

    _dropoff_stroke_color = "green"      # 하차원 외곽선(초록)
    _dropoff_bg_color = nothing


    base_geom_layer = Compose.compose(   # 바닥에 깔 조립체 형상 레이어
        context(),
        Compose.linewidth(0.02pt),       # 아주 얇은 선
        plot_assemblies(sched, scene_tree,  # 모든 완성 조립체의 2D 형상 그리기
            fill_color=RGBA(0.5, 0.5, 0.5, 0.9),  # 회색 채움
            stroke_color=nothing,
        ))

    bg_color = nothing                   # 배경색(없음=투명)

    staging_circs = []                   # 모든 적치원
    final_staging_circs = []             # 최종(말단) 적치원
    bounding_circs = []                  # 경계원
    dropoff_circs = []                   # 하차원
    for n in node_list                   # 노드 목록 순회
        if matches_template(AssemblyStart, n)   # 조립체 시작 노드면 (아무 동작 안 함 — 빈 분기)
        elseif matches_template(CloseBuildStep, n)  # 조립단계 닫기 노드면


            push!(staging_circs, node_id(n) => get_cached_geom(node_val(n).staging_circle))  # 적치원 추가 (=> 키=>값 쌍)

            push!(bounding_circs, node_id(n) => get_cached_geom(node_val(n).bounding_circle))  # 경계원 추가

            is_terminal_build_step = true   # 이게 마지막 조립단계인지 판정
            for v in outneighbors(sched, n)  # 뒤따르는 노드들 중
                if matches_template(OpenBuildStep, get_node(sched, v))  # 또 다른 단계 열기가 있으면
                    is_terminal_build_step = false  # 마지막이 아님
                end
            end
            is_terminal_build_step ? nothing : continue  # 마지막 단계가 아니면 아래 건너뜀(삼항을 if 대용)
            push!(final_staging_circs, node_id(n) => get_cached_geom(node_val(n).staging_circle))  # 최종 적치원에 추가

        elseif matches_template(DepositCargo, n)  # 화물 내려놓기 노드면
            tu = entity(n)                  # 운반유닛
            a = get_node(scene_tree, cargo_id(tu))  # 화물 노드(미사용)
            tf = global_transform(goal_config(n))  # 내려놓을 목표 위치 변환
            push!(dropoff_circs, node_id(n) => tf(get_base_geom(tu, HypersphereKey())))  # 변환 적용한 구를 하차원으로 추가
        end
    end

    bbox = staging_plan_bbox(staging_circs)  # 모든 적치원을 감싸는 경계상자 계산
    bg_ctx = (context(), Compose.rectangle(), Compose.fill(bg_color))  # 배경 사각형 레이어

    Compose.set_default_graphic_size(nominal_width, (bbox.widths[2] / bbox.widths[1]) * nominal_width)  # 가로:세로 비율 맞춰 그림 크기 설정


    circles_ctx = (context(),            # 각종 원들을 묶은 레이어
        (context(),                      # 최종 적치원들
            [Compose.circle(c.center[1], c.center[2], c.radius) for (k, c) in final_staging_circs]...,  # 각 원 그리기
            Compose.stroke(_final_stage_stroke_color),
            Compose.fill(_final_stage_bg_color),
        ),
        (context(),                      # 중간 적치원들(옵션 켜질 때만 — 컴프리헨션의 if 필터)
            [Compose.circle(c.center[1], c.center[2], c.radius) for (k, c) in staging_circs if show_intermediate_stages]...,
            Compose.stroke(_stage_stroke_color),
            Compose.fill(_stage_bg_color),
        ),
        (context(),                      # 하차원들
            [Compose.circle(c.center[1], c.center[2], c.radius) for (k, c) in dropoff_circs]...,
            Compose.stroke(_dropoff_stroke_color),
            Compose.fill(_dropoff_bg_color),
        ),
        (context(),                      # 경계원들
            [Compose.circle(c.center[1], c.center[2], c.radius) for (k, c) in bounding_circs]...,
            Compose.stroke(_bounding_stroke_color),
            Compose.fill(_bounding_bg_color),
        ),
    )

    plt = Compose.compose(               # 형상 + 원 + 배경을 합성한 기본 그림
        context(units=UnitBox(bbox.origin..., bbox.widths...)),  # 경계상자 기준 좌표계
        base_geom_layer,
        circles_ctx,
        bg_ctx
    )

    circs = transform_final_assembly_staging_circles(sched, scene_tree, staging_circles)  # 최종 조립 적치원을 실제 위치로 변환


    forms = [Compose.circle(v.center..., v.radius) for v in values(circs)]  # 그 원들을 그래픽으로
    stage_plt = Compose.compose(context(), plt,  # 위 그림에 회색 외곽 원들 + 어두운 배경을 더함
        (context(units=UnitBox(bbox.origin..., bbox.widths...)),
            forms...,
            Compose.fill(nothing),
            Compose.stroke(RGBA(0.5, 0.5, 0.5, 1.0)),  # 회색 테두리
        ),
        (context(), Compose.rectangle(),
            Compose.fill(RGB(0.25, 0.25, 0.25)),  # 어두운 회색 배경
        )
    )
    if save_image                        # 저장 옵션이면
        draw(PDF(save_file_name), stage_plt)  # PDF 파일로 그리기
    end
    display(stage_plt)                   # 화면에 표시
end

# 적치원들 전체를 감싸는 2D 경계상자(bounding box)를 계산한다.
function staging_plan_bbox(staging_circs)
    xlo = minimum(c.center[1] - c.radius for (k, c) in staging_circs)  # 가장 왼쪽 x (제너레이터로 최솟값)
    ylo = minimum(c.center[2] - c.radius for (k, c) in staging_circs)  # 가장 아래 y
    xhi = maximum(c.center[1] + c.radius for (k, c) in staging_circs)  # 가장 오른쪽 x
    yhi = maximum(c.center[2] + c.radius for (k, c) in staging_circs)  # 가장 위 y
    GeometryBasics.Rect2d(xlo, ylo, xhi - xlo, yhi - ylo)  # (원점x, 원점y, 폭, 높이) 사각형 생성
end
# 위 함수의 그래프 버전 — 그래프에서 적치원을 먼저 뽑은 뒤 경계상자 계산(다중 디스패치).
staging_plan_bbox(sched::AbstractGraph) = staging_plan_bbox(extract_build_step_staging_circles(sched))

# 스케줄에서 각 조립단계(CloseBuildStep)의 적치원을 모아 딕셔너리로 반환한다.
function extract_build_step_staging_circles(sched)
    circs = Dict()
    for n in get_nodes(sched)
        if matches_template(CloseBuildStep, n)  # 조립단계 닫기 노드면
            circs[node_id(n)] = get_cached_geom(node_val(n).staging_circle)  # 그 적치원을 등록
        end
    end
    circs
end

# 각 적치원을 해당 조립체의 최종 목표 위치로 평행이동시켜 새 원들을 만든다.
function transform_final_assembly_staging_circles(sched, scene_tree, staging_circles)
    circs = Dict()
    for (k, v) in staging_circles        # k=ID, v=원
        tform = global_transform(goal_config(get_node(sched,  # 그 조립체의 "조립완료" 목표 변환
            AssemblyComplete(get_node(scene_tree, k)))))
        # circ = LazySets.translate(v,tform.translation[1:2])  # (옛 코드 — translate 사용 버전)
        circ = LazySets.Ball2(v.center + tform.translation[1:2], v.radius)  # 중심을 (x,y) 평행이동한 새 원
        circs[k] = circ
    end
    circs
end

# 완성된 모든 조립체의 2D 형상을 그 목표 위치에 그려 하나의 그래픽으로 합친다.
function plot_assemblies(sched, scene_tree;
    base_ctx=context(),                  # 기본 컨텍스트
    kwargs...,
)
    ctxs = []
    for n in get_nodes(sched)            # 스케줄 노드 순회
        if matches_template(AssemblyComplete, n)  # 조립완료 노드면
            tform = global_transform(goal_config(n))  # 그 조립체의 목표 위치 변환
            push!(ctxs, plot_base_geom_2d(entity(n), scene_tree; tform=tform, kwargs...))  # 변환 적용해 2D 형상 그리기
        end
    end
    Compose.compose(base_ctx, ctxs...)   # 모든 형상을 합성
end
