# ============================================================================
#  이 파일이 하는 일: 빌드 준비 파이프라인을 단계별로 실행하며 "여러 구성요소"를 그림으로 그려 보는 시각화 스크립트.
#  프로젝트 속 역할: stage_graph_plots.jl 과 거의 같은 흐름(LDraw 파싱 → 모델 스펙 → scene tree → 근사 기하 →
#  운반유닛 → 부분 스케줄 → 스테이징 → 작업배정)을 따르되, 중간에 (1) 운반유닛의 2D 배치(로봇이 화물을 어떻게 드는지),
#  (2) 스케줄 그래프, (3) 스테이징 구역, (4) 배정 후 스케줄 그래프를 실제로 display 로 화면에 띄움.
#  실행: REPL 에서 include("scripts/plot_various_components.jl") 로 흘려 돌림.
#  Julia 문법 참고:
#   · using X : 패키지 로드(그림/좌표/최적화용 패키지 다수). 여기선 Measures·Compose(2D 그리기)도 씀.
#   · f(...; key=val) : 세미콜론 뒤 키워드 인자. 15cm 처럼 숫자+단위 = Measures 의 길이 리터럴.
#   · @assert 조건 "메시지" : 거짓이면 즉시 중단(중간 상태 검증).
#   · display(plt) : 그림 객체를 화면(플롯 창/노트북)에 출력.
#   · :tractor, :greedy 등 :이름 = Symbol. (G, v) -> ... = 그래프 그리기 콜백(익명함수), ? : 삼항식.
#  도메인 용어(원어 유지): scene tree, transport unit, staging, makespan, MILP, RVO, tangent_bug, dispersion.
# ============================================================================

using ConstructionBots

using Printf
using Parameters
using Random
using StaticArrays
using LinearAlgebra
using Dates
using StatsBase
using JLD2
using ProgressMeter
using Logging
using TOML
using LazySets
using GeometryBasics
using CoordinateTransformations
using Rotations
using Graphs
using JuMP
using PyCall
using MeshCat
using SparseArrays
using LDrawParser
using Colors
using Measures
using Compose
using HiGHS
using ECOS



# ---- 실행 설정 ----
project_params = get_project_params(:tractor)  # 프로젝트를 이름(Symbol)으로 선택 — tractor

ldraw_file = project_params[:file_name]      # 조립도 파일명
project_name = project_params[:project_name] # 결과 폴더명
model_scale = project_params[:model_scale]   # 모델 스케일
num_robots = project_params[:num_robots]     # 로봇 수

open_animation_at_end = true         # 이 스크립트는 그림 위주지만 애니메이션 관련 플래그도 보관
save_animation_along_the_way = false
save_animation = false
anim_active_agents = false
anim_active_areas = false
update_anim_at_every_step = false

rvo_flag = true                      # 회피/분산 정책 플래그
tangent_bug_flag = true
dispersion_flag = true

assignment_mode = :greedy            # 작업배정 방식(그리디)
milp_optimizer = :highs              # MILP 쓸 때 솔버
optimizer_time_limit = 100           # MILP 제한시간(초)
look_for_previous_milp_solution = false
save_milp_solution = false
previous_found_optimizer_time = 200

write_results = false
overwrite_results = false

# ---- 로봇/기하/시뮬레이션 세부 파라미터 ----
robot_scale = model_scale * 0.7   # 로봇 크기 배율
robot_height = 10 * robot_scale   # 로봇 높이
robot_radius = 25 * robot_scale   # 로봇 반지름
num_object_layers = 1
max_steps = 50                    # (여기선 시뮬레이션을 끝까지 안 돌리므로 참고값)
staging_buffer_factor = 1.2
build_step_buffer_factor = 0.5
base_results_path = joinpath(dirname(pathof(ConstructionBots)), "..", "results")
results_path = joinpath(base_results_path, project_name)
process_updates_interval = 25
save_anim_interval = 500
max_num_iters_no_progress = 10000
sim_batch_size = 50
log_level = Logging.Warn
milp_optimizer_attribute_dict = Dict()

ignore_rot_matrix_warning = true

rng = Random.MersenneTwister(1)  # 난수생성기(시드 1 → 로봇 배치 재현 가능)

process_animation_tasks = save_animation || save_animation_along_the_way || open_animation_at_end  # 애니메이션 처리 필요 여부

visualizer = nothing


filename = joinpath(dirname(pathof(ConstructionBots)), "..", "LDraw_files", ldraw_file)  # 조립도 파일 전체 경로
@assert ispath(filename) "File $(filename) does not exist."  # 파일 존재 확인

global_logger(ConsoleLogger(stderr, log_level))  # 로거 설정

# Adding additional attributes for GLPK, HiGHS, and Gurobi
time_limit_key = nothing

anim_prog_file_name = "visualization_"

anim_prog_path = joinpath(results_path, anim_prog_file_name)

sim_params = ConstructionBots.SimParameters(
    sim_batch_size,
    max_steps,
    process_animation_tasks,
    save_anim_interval,
    process_updates_interval,
    update_anim_at_every_step,
    anim_active_agents,
    anim_active_areas,
    anim_prog_path,
    save_animation_along_the_way,
    max_num_iters_no_progress
)

# ---- 전역 상태 초기화 + 기본값 세팅(ID 카운터·로봇 기하·RVO/적재 속도 등) ----
ConstructionBots.reset_all_id_counters!()          # 노드 ID 카운터 리셋
ConstructionBots.reset_all_invalid_id_counters!()  # 임시 ID 카운터 리셋
ConstructionBots.set_default_robot_geom!(Cylinder(Point(0.0, 0.0, 0.0), Point(0.0, 0.0, robot_height), robot_radius))  # 기본 로봇 형상=원기둥
ConstructionBots.set_rvo_default_time_step!(1 / 40.0)  # RVO 시간간격(40Hz)

ConstructionBots.set_rvo_default_neighbor_distance!(16 * ConstructionBots.default_robot_radius())      # RVO 이웃 인식 거리
ConstructionBots.set_rvo_default_min_neighbor_distance!(10 * ConstructionBots.default_robot_radius())  # RVO 최소 이웃 거리

ConstructionBots.set_default_loading_speed!(50 * ConstructionBots.default_robot_radius())            # 적재 직선 속도
ConstructionBots.set_default_rotational_loading_speed!(50 * ConstructionBots.default_robot_radius())  # 적재 회전 속도

ConstructionBots.set_staging_buffer_radius!(ConstructionBots.default_robot_radius()) # for tangent_bug policy  # 스테이징 여유반경

# Setting default optimizer for staging layout
ConstructionBots.set_default_geom_optimizer!(ECOS.Optimizer)  # 스테이징 배치용 기하 최적화 솔버(ECOS)
ConstructionBots.set_default_geom_optimizer_attributes!(MOI.Silent() => true)  # 조용히 실행

# ---- 파이프라인 시작: 조립도 파싱 + 좌표계/스케일 적용 ----
model = parse_ldraw_file(filename; ignore_rotation_determinant=ignore_rot_matrix_warning)  # .ldr 파싱
populate_part_geometry!(model; ignore_rotation_determinant=ignore_rot_matrix_warning)      # 부품 3D 기하 채우기
LDrawParser.change_coordinate_system!(model, ldraw_base_transform(), model_scale; ignore_rotation_determinant=ignore_rot_matrix_warning)  # 좌표계 변환 + 스케일

## CONSTRUCT MODEL SPEC
# 모델 스펙 구성: 조립 순서/포함관계 그래프(model_spec)와 ID/색 매핑 생성.
print("Constructing model spec...")
spec = ConstructionBots.construct_model_spec(model)         # 전체 스펙 그래프
model_spec = ConstructionBots.extract_single_model(spec)    # 단일 모델 추출
id_map = ConstructionBots.build_id_map(model, model_spec)   # 요소↔노드 ID 매핑
color_map = ConstructionBots.construct_color_map(model_spec, id_map)  # 부품 색 매핑
@assert ConstructionBots.validate_graph(model_spec)         # 스펙 그래프 유효성 검증
print("done!\n")

## CONSTRUCT SceneTree
# scene tree 구성: 조립 스펙을 로봇/부품/조립체 노드가 달린 공간 트리로 변환.
print("Constructing scene tree...")
assembly_tree = ConstructionBots.construct_assembly_tree(model, model_spec, id_map)  # 조립 트리
scene_tree = ConstructionBots.convert_to_scene_tree(assembly_tree)                   # → scene tree
# @info print(scene_tree, v -> "$(summary(node_id(v))) : $(get(id_map,node_id(v),nothing))", "\t")
print("done!\n")

# Compute Approximate Geometry
# 근사 기하 계산: 각 노드에 감싸는 구/직육면체를 씌워 충돌·배치 계산을 빠르게.
print("Computing approximate geometry...")
start_geom_approx = time()
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HypersphereKey())      # 감싸는 구
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HyperrectangleKey())   # 감싸는 직육면체
GEOM_APPROX_TIME = time() - start_geom_approx
print("done!\n")

# Define TransportUnit configurations
# 운반유닛 구성: 각 화물을 로봇들이 어떻게 둘러싸 들지 계산.
print("Configuring transport units...")
config_transport_units_time = time()
ConstructionBots.init_transport_units!(scene_tree; robot_radius=robot_radius)  # 로봇 반지름 기준 초기화
config_transport_units_time = time() - config_transport_units_time
print("done!\n")

# validate SceneTree
# scene tree 검증: 트리와 각 노드의 변환 트리가 일관적인지 확인.
print("Validating scene tree...")
root = ConstructionBots.get_node(scene_tree, collect(ConstructionBots.get_all_root_nodes(scene_tree))[1])  # 루트 노드
ConstructionBots.validate_tree(ConstructionBots.get_transform_node(root))  # 루트 변환 트리 검증
ConstructionBots.validate_embedded_tree(scene_tree, v -> ConstructionBots.get_transform_node(ConstructionBots.get_node(scene_tree, v)))  # 각 노드 변환 트리 검증
print("done!\n")

## Add robots to scene tree
# 로봇을 격자 후보 위치들 중 무작위로 뽑아 시작 위치에 배치.
robot_spacing = 5 * robot_radius                                   # 로봇 간 간격
robot_start_box_side = ceil(sqrt(num_robots)) * robot_spacing      # 시작구역 한 변 길이
xy_range = (-robot_start_box_side/2:robot_spacing:robot_start_box_side/2)  # 격자 좌표 범위
vtxs = ConstructionBots.construct_vtx_array(; spacing=(1.0, 1.0, 0.0), ranges=(xy_range, xy_range, 0:0))  # 후보 격자점(z=0 평면)

robot_vtxs = StatsBase.sample(rng, vtxs, num_robots; replace=false)  # num_robots 개를 비복원 무작위 추출

ConstructionBots.add_robots_to_scene!(scene_tree, robot_vtxs, [ConstructionBots.default_robot_geom()])  # 뽑힌 위치에 로봇 추가

## Recompute approximate geometry for when the robot is transporting it
# Add temporary robots to the transport units and recalculate the bounding geometry
# then remove them after the new geometries are calcualted
# 운반 중 크기 반영: 임시 로봇을 붙여 "로봇+화물" 감싸는 기하를 다시 계산 후 임시 로봇 제거.
ConstructionBots.add_temporary_invalid_robots!(scene_tree; with_edges=true)  # 임시 로봇 부착
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HypersphereKey())
@assert all(map(node -> ConstructionBots.has_vertex(node.geom_hierarchy, ConstructionBots.HypersphereKey()), ConstructionBots.get_nodes(scene_tree)))  # 모든 노드 구 근사 확인
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HyperrectangleKey())
@assert all(map(node -> ConstructionBots.has_vertex(node.geom_hierarchy, ConstructionBots.HyperrectangleKey()), ConstructionBots.get_nodes(scene_tree)))  # 직육면체 근사 확인
ConstructionBots.remove_temporary_invalid_robots!(scene_tree)  # 임시 로봇 제거

## Construct Partial Schedule (without robots assigned)
# 부분 스케줄 구성: 로봇 배정 전, 작업 순서 뼈대만 만듦.
print("Constructing partial schedule...")
ConstructionBots.jump_to_final_configuration!(scene_tree; set_edges=true)  # 완성 배치로 점프(목표 자세 확보)
sched = ConstructionBots.construct_partial_construction_schedule(model, model_spec, scene_tree, id_map)  # 부분 스케줄 생성
@assert ConstructionBots.validate_schedule_transform_tree(sched)  # 변환 트리 유효성 검증
print("done!\n")


#### Plot 2D hulls with robot carrying positions ####
# 각 운반유닛의 2D 외곽(로봇이 화물을 드는 배치)을 그려 화면에 표시(display).
ns = []
for n in scene_tree.nodes
    if ConstructionBots.matches_template(ConstructionBots.TransportUnitNode, n)  # 운반유닛 노드마다
        plt = ConstructionBots.render_transport_unit_2d(scene_tree, n; scale=15cm)  # 2D 그림 생성(scale=15cm 크기)
        display(plt)  # 화면 출력
    end
end


#### Plot the schedule ####
# 스케줄 그래프용 헬퍼: 이 노드가 제목에 ID를 붙일 주요 작업 타입인지 판정.
_node_type_check(n) = ConstructionBots.matches_template((ObjectStart, AssemblyStart, AssemblyComplete, FormTransportUnit, TransportUnitGo, DepositCargo, LiftIntoPlace), n)

# 배정 전 스케줄 그래프 그리기(왼→오 배치, 주요 노드엔 제목에 ID 부착 — 삼항식 ?:) 후 화면 표시.
plt = ConstructionBots.display_graph(
    sched;
    grow_mode=:from_left,           # 왼→오 성장
    align_mode=:split_aligned,      # 정렬 방식
    draw_node_function=(G, v) -> ConstructionBots.draw_node(ConstructionBots.get_node(G, v);  # 노드 그리기 콜백
        title_text=_node_type_check(ConstructionBots.get_node(G, v)   # 주요 노드면 제목에 ID 덧붙임
        ) ? string(ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
            "$(ConstructionBots.get_id(ConstructionBots.node_id(ConstructionBots.get_node(G,v))))") : ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
        subtitle_text="",
        title_scale=_node_type_check(ConstructionBots.get_node(G, v)  # 주요 노드는 기본 크기, 아니면 0.45
        ) ? ConstructionBots._title_text_scale(ConstructionBots.get_node(G, v)) : 0.45,
    ),
    pad=(0.0, 0.0)
)
display(plt)  # 그린 그래프를 화면에 출력


# Generate staging plan
# 스테이징 계획 생성: 조립 전 부품/운반유닛이 대기·집결할 원형 구역 배치.
max_object_transport_unit_radius = ConstructionBots.get_max_object_transport_unit_radius(scene_tree)  # 가장 큰 운반유닛 반지름

staging_circles, bounding_circles = ConstructionBots.generate_staging_plan!(scene_tree, sched;  # 스테이징 원 계산
    buffer_radius=staging_buffer_factor * max_object_transport_unit_radius,                     # 조립체 주변 여유반경
    build_step_buffer_radius=build_step_buffer_factor * ConstructionBots.default_robot_radius() # 빌드 스텝별 여유반경
)

#### Plot the staging area ####
# 스테이징 구역 그림(save_image=false 라 파일저장은 안 함, 화면 확인용).
ConstructionBots.plot_staging_area(
    sched, scene_tree, staging_circles;
    save_file_name="temp_staging_area.pdf",
    save_image=false
)

# Make sure all transforms line up
# 스테이징 반영 후 운반 작업 변환 보정 + 재검증(post_staging=true).
ConstructionBots.calibrate_transport_tasks!(sched)
@assert ConstructionBots.validate_schedule_transform_tree(sched; post_staging=true)

# Task Assignments
# ---- 작업배정: 운영 스케줄로 변환 후, 어느 로봇이 어느 작업을 맡을지 그리디로 결정 ----
ConstructionBots.add_dummy_robot_go_nodes!(sched)  # 배정용 더미 RobotGo 노드 추가
@assert ConstructionBots.validate_schedule_transform_tree(sched; post_staging=true)

ConstructionBots.set_default_loading_speed!(50 * ConstructionBots.default_robot_radius())            # 적재 속도 재설정
ConstructionBots.set_default_rotational_loading_speed!(50 * ConstructionBots.default_robot_radius())

tg_sched = ConstructionBots.convert_to_operating_schedule(sched)  # operating schedule 로 변환

milp_model = ConstructionBots.SparseAdjacencyMILP()  # (참고용) 바로 아래에서 그리디로 덮어씀
milp_model = ConstructionBots.GreedyOrderedAssignment(  # 실제 배정기: 그리디(완료시간 비용)
    greedy_cost=ConstructionBots.GreedyFinalTimeCost(),
)
milp_model = ConstructionBots.formulate_milp(milp_model, tg_sched, scene_tree)  # 배정 문제 정식화

optimize!(milp_model)  # 배정 풀기(그리디 실행)

validate_schedule_transform_tree(  # 결과를 원래 스케줄 타입으로 되돌려 재검증
    ConstructionBots.convert_from_operating_schedule(typeof(sched), tg_sched)
    ; post_staging=true
)
ConstructionBots.update_project_schedule!(nothing, milp_model, tg_sched, scene_tree)  # 배정 결과를 스케줄에 반영
@assert ConstructionBots.validate(tg_sched)  # 최종 운영 스케줄 검증

#### Plot the schedule with robots assigned ####
# 배정 후 스케줄 그래프 그리기(로봇 배정된 tg_sched) 후 화면 표시.
plt = ConstructionBots.display_graph(
    tg_sched;
    grow_mode=:from_left,
    align_mode=:split_aligned,
    draw_node_function=(G, v) -> ConstructionBots.draw_node(ConstructionBots.get_node(G, v);
        title_text=_node_type_check(ConstructionBots.get_node(G, v)
        ) ? string(ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
            "$(ConstructionBots.get_id(ConstructionBots.node_id(ConstructionBots.get_node(G,v))))") : ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
        subtitle_text="",
        title_scale=_node_type_check(ConstructionBots.get_node(G, v)
        ) ? ConstructionBots._title_text_scale(ConstructionBots.get_node(G, v)) : 0.45,
    )
)
display(plt)
