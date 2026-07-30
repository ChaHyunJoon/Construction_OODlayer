# ============================================================================
#  이 파일이 하는 일: 시뮬레이션을 "끝까지 돌리지 않고", 빌드 준비 단계까지만 진행한 뒤 그 중간 산출물을
#  그림으로 그려 확인하는 디버그/시각화 스크립트(자동 테스트 아님).
#  프로젝트 속 역할: LDraw 모델 파싱 → 모델 스펙 → scene tree(로봇/부품/조립체 트리) → 근사 기하 →
#  운반유닛 구성 → 부분 스케줄 → staging(스테이징: 조립 전 대기배치) 계획 → 작업배정(MILP/greedy) 까지의
#  파이프라인을 한 줄씩 실행하고, 중간중간 render/plot 함수로 스케줄 그래프·운반유닛 배치·스테이징 구역을 그림.
#  실행: 대개 REPL에서 include("test/stage_graph_plots.jl") 로 한 번에 흘려 돌림.
#  Julia 문법 참고:
#   · using X : 패키지 로드. 이 스크립트는 그림/최적화에 쓰는 여러 패키지를 한꺼번에 불러옴.
#   · x::T = val : 변수에 타입을 명시하며 대입(문서화/성능 힌트). 최상위 스코프라도 허용.
#   · @assert 조건 "메시지" : 조건이 거짓이면 즉시 에러(중간 상태 검증용).
#   · @warn "..." : 경고 로그 출력. Module.func(...) : 모듈 내부 함수 직접 호출.
#   · f(...; key=val) : 세미콜론 뒤 키워드 인자. () -> Expr : 익명함수(람다), 여기선 optimizer 생성기.
#   · :greedy, :milp 등 :이름 = Symbol(모드 스위치). String(...)·string(...) = 문자열 변환/이어붙이기.
#   · draw_node_function=(G, v) -> ... : 그래프 그리기 콜백을 익명함수로 넘김. ? : 은 삼항 조건식.
#  도메인 용어(원어 유지): scene tree, staging, makespan, MILP, RVO, tangent_bug, dispersion, transport unit.
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

using HiGHS
using Gurobi
using ECOS



# ---- 실행 설정(무엇을·어떻게 그릴지) ----
project_params = get_project_params(4) # 4 = tractor  # 이 스크립트에서 다룰 프로젝트(tractor)의 파일/스케일/로봇수


open_animation_at_end = false        # 이 스크립트는 그림만 보므로 애니메이션 관련은 전부 끔
save_animation_along_the_way = false
save_animation_at_end = false
anim_active_agents = false
anim_active_areas = false
update_anim_at_every_step = false

rvo_flag = true                      # 회피/분산 정책 플래그(스테이징 계획 등에 영향)
tangent_bug_flag = true
dispersion_flag = true
assignment_mode = :greedy            # 작업배정 방식(기본 그리디)

write_results = false
overwrite_results = false

ldraw_file = project_params[:file_name]
project_name = project_params[:project_name]
model_scale = project_params[:model_scale]
num_robots = project_params[:num_robots]

assignment_mode = assignment_mode
milp_optimizer = :gurobi # :gurobi :highs
optimizer_time_limit = 100

rvo_flag = rvo_flag
tangent_bug_flag = tangent_bug_flag
dispersion_flag = dispersion_flag

open_animation_at_end = open_animation_at_end
save_animation = save_animation_at_end
save_animation_along_the_way = save_animation_along_the_way
anim_active_agents = anim_active_agents
anim_active_areas = anim_active_areas

write_results = write_results
overwrite_results = overwrite_results

look_for_previous_milp_solution = false
save_milp_solution = false
previous_found_optimizer_time = 200

# ---- 로봇/기하/시뮬레이션 세부 파라미터(타입 명시 = 문서화 겸 성능 힌트) ----
robot_scale::Float64 = model_scale * 0.7   # 로봇 크기 배율(모델 스케일에 비례)
robot_height::Float64 = 10 * robot_scale   # 로봇 높이(원기둥)
robot_radius::Float64 = 25 * robot_scale   # 로봇 반지름
num_object_layers::Int = 1
max_steps::Int = 100000                    # 시뮬레이션 최대 스텝(여기선 실제로 안 돌리지만 파라미터로 보관)
staging_buffer_factor::Float64 = 1.2       # 스테이징 구역 여유반경 배수
build_step_buffer_factor::Float64 = 0.5    # 빌드 스텝별 여유반경 배수
base_results_path::String = joinpath(dirname(pathof(ConstructionBots)), "..", "results")
results_path::String = joinpath(base_results_path, project_name)
process_updates_interval::Int = 25
block_save_anim::Bool = false
save_anim_interval::Int = 500
max_num_iters_no_progress::Int = 10000
sim_batch_size::Int = 50
log_level::Logging.LogLevel = Logging.Warn
milp_optimizer_attribute_dict::Dict = Dict()

ignore_rot_matrix_warning = true

rng::Random.AbstractRNG = Random.MersenneTwister(1)  # 난수생성기(시드 1 고정 → 로봇 배치 재현 가능)

process_animation_tasks = save_animation || save_animation_along_the_way || open_animation_at_end  # 셋 중 하나라도 켜져 있으면 애니메이션 처리 필요

if rvo_flag && !dispersion_flag  # RVO 는 켰는데 dispersion 을 끄면 권장되지 않는 조합 → 경고
    @warn "RVO is enabled but dispersion is disabled. This is not recommended."
end

# record statistics
# 이번 실행 설정을 통계 딕셔너리에 기록(나중에 결과 파일로 남길 때 씀).
stats = Dict()
stats[:rng] = "$rng"
stats[:modelscale] = model_scale
stats[:robotscale] = robot_scale
stats[:assignment_mode] = string(assignment_mode)
stats[:rvo_flag] = rvo_flag
stats[:tangent_bug_flag] = tangent_bug_flag
stats[:dispersion_flag] = dispersion_flag
stats[:OptimizerTimeLimit] = optimizer_time_limit

if assignment_mode == :milp
    stats[:Optimizer] = string(milp_optimizer)
end

if save_animation_along_the_way
    save_animation = true
end

visualizer = nothing
if process_animation_tasks
    visualizer = MeshCat.Visualizer()
end

mkpath(results_path)  # 결과 저장 폴더 없으면 생성
filename = joinpath(dirname(pathof(ConstructionBots)), "..", "LDraw_files", ldraw_file)  # 조립도 파일 경로 조립(패키지 위치 기준)
@assert ispath(filename) "File $(filename) does not exist."  # 파일 실제 존재 확인(없으면 즉시 중단)

global_logger(ConsoleLogger(stderr, log_level))  # 로거를 이 스크립트의 로그레벨로 설정

# Adding additional attributes for GLPK, HiGHS, and Gurobi
# ---- MILP 솔버별 설정: 선택한 solver 종류에 맞춰 optimizer 생성기와 속성(시간제한 등)을 다르게 지정 ----
time_limit_key = nothing  # 솔버마다 "시간제한" 속성 키 이름이 달라 여기에 담아둠
if assignment_mode == :milp || assignment_mode == :milp_w_greedy_warm_start  # MILP 를 쓰는 모드일 때만 솔버 설정
    milp_optimizer_attribute_dict[MOI.Silent()] = false  # 솔버 로그 출력 허용(MOI = MathOptInterface 공통 속성)
    default_milp_optimizer = nothing
    if milp_optimizer == :glpk
        default_milp_optimizer = () -> GLPK.Optimizer(; want_infeasibility_certificates=false)
        milp_optimizer_attribute_dict["tm_lim"] = optimizer_time_limit * 1000
        milp_optimizer_attribute_dict["msg_lev"] = GLPK.GLP_MSG_ALL
        time_limit_key = "tm_lim"
    elseif milp_optimizer == :gurobi
        default_milp_optimizer = () -> Gurobi.Optimizer()  # Gurobi 솔버 생성기(호출 때마다 새 인스턴스)
        # default_milp_optimizer = Gurobi.Optimizer
        milp_optimizer_attribute_dict["TimeLimit"] = optimizer_time_limit  # Gurobi 의 시간제한 속성명은 "TimeLimit"
        # MIPFocus: 1 -- feasible solutions, 2 -- optimal solutions, 3 -- bound
        milp_optimizer_attribute_dict["MIPFocus"] = 1  # 탐색 초점: 1=실현가능해를 빨리 찾기 우선
        time_limit_key = "TimeLimit"
    elseif milp_optimizer == :highs
        default_milp_optimizer = () -> HiGHS.Optimizer()
        milp_optimizer_attribute_dict["time_limit"] = Float64(optimizer_time_limit)
        milp_optimizer_attribute_dict["presolve"] = "on"
        time_limit_key = "time_limit"
    else
        @warn "No additional parameters for $milp_optimizer were set."
    end
    ConstructionBots.set_default_milp_optimizer!(default_milp_optimizer)          # 위에서 고른 솔버를 기본 MILP 솔버로 등록
    ConstructionBots.clear_default_milp_optimizer_attributes!()                   # 기존 속성 초기화 후
    ConstructionBots.set_default_milp_optimizer_attributes!(milp_optimizer_attribute_dict)  # 이번 속성으로 설정
end

# ---- 결과 파일 이름 앞부분(prefix) 만들기: 켜진 정책/배정모드를 문자열로 이어붙여 실험 구분 ----
if rvo_flag
    prefix = "RVO"
else
    prefix = "no-RVO"
end
if dispersion_flag
    prefix = string(prefix, "_Dispersion")
else
    prefix = string(prefix, "_no-Dispersion")
end
if tangent_bug_flag
    prefix = string(prefix, "_TangentBug")
else
    prefix = string(prefix, "_no-TangentBug")
end
soln_str_pre = ""
if assignment_mode == :milp
    soln_str_pre = "milp_"
    prefix = string(soln_str_pre, prefix)
elseif assignment_mode == :greedy
    soln_str_pre = "greedy_"
    prefix = string(soln_str_pre, prefix)
elseif assignment_mode == :milp_w_greedy_warm_start
    soln_str_pre = "milp-ws_"
    prefix = string(soln_str_pre, prefix)
else
    error("Unknown assignment mode: $(assignment_mode)")
end
mkpath(joinpath(results_path, prefix))  # 그 prefix 이름의 하위 결과 폴더 생성

name_augment = ""
if !overwrite_results  # 덮어쓰기 안 할 땐 파일명 앞에 타임스탬프를 붙여 매 실행마다 새 파일로 저장
    name_augment = string(Dates.format(Dates.now(), "yyyymmdd_HHMMSS"), "_")  # 예: 20260716_ 133000_
end

stats_file_name = string(name_augment, "stats", ".toml")
anim_file_name = string(name_augment, "visualization.html")
anim_prog_file_name = string(name_augment, "visualization_")

stats_path = joinpath(results_path, prefix, stats_file_name)
anim_path = joinpath(results_path, prefix, anim_file_name)
anim_prog_path = joinpath(results_path, prefix, anim_prog_file_name)


# 위 개별 파라미터들을 하나의 SimParameters 구조체로 묶음(인자 순서가 정해져 있으니 순서 유지 중요).
sim_params = ConstructionBots.SimParameters(
    sim_batch_size,
    max_steps,
    process_animation_tasks,
    save_anim_interval,
    process_updates_interval,
    block_save_anim,
    update_anim_at_every_step,
    anim_active_agents,
    anim_active_areas,
    anim_prog_path,
    save_animation_along_the_way,
    max_num_iters_no_progress
)

# ---- 전역 상태 초기화 + 기본값 세팅(ID 카운터·로봇 기하·RVO/적재 속도 등) ----
ConstructionBots.reset_all_id_counters!()          # 노드 ID 카운터 리셋(새 빌드마다 ID 1부터)
ConstructionBots.reset_all_invalid_id_counters!()  # 임시(invalid) ID 카운터도 리셋

ConstructionBots.set_default_robot_geom!(  # 기본 로봇 형상을 원기둥(Cylinder)으로 지정
    Cylinder(Point(0.0, 0.0, 0.0), Point(0.0, 0.0, robot_height), robot_radius)
)

ConstructionBots.set_rvo_default_time_step!(1 / 40.0)  # RVO 한 스텝 시간간격(40Hz)
ConstructionBots.set_default_loading_speed!(50 * ConstructionBots.default_robot_radius())            # 적재(들기/내리기) 직선 속도
ConstructionBots.set_default_rotational_loading_speed!(50 * ConstructionBots.default_robot_radius())  # 적재 회전 속도
ConstructionBots.set_staging_buffer_radius!(ConstructionBots.default_robot_radius()) # for tangent_bug policy  # 스테이징 여유반경(tangent_bug 용)
ConstructionBots.set_rvo_default_neighbor_distance!(16 * ConstructionBots.default_robot_radius())      # RVO 이웃 인식 거리
ConstructionBots.set_rvo_default_min_neighbor_distance!(10 * ConstructionBots.default_robot_radius())  # RVO 최소 이웃 거리

# Setting default optimizer for staging layout
ConstructionBots.set_default_geom_optimizer!(ECOS.Optimizer)  # 스테이징 배치용 기하 최적화 솔버(ECOS, 원뿔최적화)
ConstructionBots.set_default_geom_optimizer_attributes!(MOI.Silent() => true)  # 그 솔버는 조용히(로그 off)

# ---- 파이프라인 시작: LDraw 조립도 파일을 파싱하고 좌표계를 프로젝트 스케일에 맞춤 ----
pre_execution_start_time = time()  # 전처리 시작 시각(소요시간 측정용)
model = parse_ldraw_file(filename; ignore_rotation_determinant=ignore_rot_matrix_warning)  # .ldr 파싱 → model
populate_part_geometry!(model; ignore_rotation_determinant=ignore_rot_matrix_warning)      # 각 부품의 3D 기하 채우기
LDrawParser.change_coordinate_system!(model, ldraw_base_transform(), model_scale; ignore_rotation_determinant=ignore_rot_matrix_warning)  # 좌표계 변환 + 스케일 적용

## CONSTRUCT MODEL SPEC
# 모델 스펙 구성: 파싱된 model 에서 "조립 순서/포함관계"를 담은 그래프(model_spec)와 ID/색 매핑을 만듦.
print("Constructing model spec...")
spec = ConstructionBots.construct_model_spec(model)         # 전체 스펙 그래프 생성
model_spec = ConstructionBots.extract_single_model(spec)    # 그중 단일 모델만 추출
id_map = ConstructionBots.build_id_map(model, model_spec)   # model 요소 ↔ 스펙 노드 ID 매핑
color_map = ConstructionBots.construct_color_map(model_spec, id_map)  # 부품별 색 매핑
@assert ConstructionBots.validate_graph(model_spec)         # 스펙 그래프가 유효한지 검증
print("done!\n")

## CONSTRUCT SceneTree
# scene tree 구성: 조립 스펙을 실제 로봇/부품/조립체 노드가 달린 공간 트리(scene tree)로 변환.
print("Constructing scene tree...")
assembly_tree = ConstructionBots.construct_assembly_tree(model, model_spec, id_map)  # 조립 트리 먼저
scene_tree = ConstructionBots.convert_to_scene_tree(assembly_tree)                   # → scene tree 로 변환
# @info print(scene_tree, v -> "$(summary(node_id(v))) : $(get(id_map,node_id(v),nothing))", "\t")
print("done!\n")

# Compute Approximate Geometry
# 근사 기하 계산: 충돌/배치 계산을 빠르게 하려고 각 노드에 감싸는 구(Hypersphere)와 직육면체(Hyperrectangle)를 씌움.
print("Computing approximate geometry...")
start_geom_approx = time()
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HypersphereKey())      # 감싸는 구
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HyperrectangleKey())   # 감싸는 직육면체
GEOM_APPROX_TIME = time() - start_geom_approx  # 근사 기하 계산에 걸린 시간
print("done!\n")

# Define TransportUnit configurations
# 운반유닛 구성: 각 화물을 몇 대의 로봇이 어떻게 둘러싸 들지(transport unit) 배치를 계산.
print("Configuring transport units...")
config_transport_units_time = time()
ConstructionBots.init_transport_units!(scene_tree; robot_radius=robot_radius)  # 로봇 반지름 기준으로 운반유닛 초기화
config_transport_units_time = time() - config_transport_units_time
print("done!\n")

# validate SceneTree
# scene tree 검증: 트리 구조와 각 노드에 박힌(embedded) 변환 트리가 일관적인지 확인.
print("Validating scene tree...")
root = ConstructionBots.get_node(scene_tree, collect(ConstructionBots.get_all_root_nodes(scene_tree))[1])  # 루트 노드 하나 얻기
ConstructionBots.validate_tree(ConstructionBots.get_transform_node(root))  # 루트의 변환 트리 검증
ConstructionBots.validate_embedded_tree(scene_tree, v -> ConstructionBots.get_transform_node(ConstructionBots.get_node(scene_tree, v)))  # 각 노드의 변환 트리 검증(콜백으로 노드→변환노드 지정)
print("done!\n")

## Add robots to scene tree
# 로봇을 격자 후보 위치들 중에서 무작위로 뽑아 시작 위치에 배치.
robot_spacing = 5 * robot_radius                                   # 로봇 간 간격
robot_start_box_side = ceil(sqrt(num_robots)) * robot_spacing      # 로봇들을 담을 정사각 시작구역 한 변 길이
xy_range = (-robot_start_box_side/2:robot_spacing:robot_start_box_side/2)  # 중심 기준 격자 좌표 범위(range)
vtxs = ConstructionBots.construct_vtx_array(; spacing=(1.0, 1.0, 0.0), ranges=(xy_range, xy_range, 0:0))  # 후보 격자점(x,y 평면, z=0)

robot_vtxs = StatsBase.sample(rng, vtxs, num_robots; replace=false)  # 그중 num_robots 개를 비복원 무작위 추출(rng 고정)

ConstructionBots.add_robots_to_scene!(scene_tree, robot_vtxs, [ConstructionBots.default_robot_geom()])  # 뽑힌 위치에 로봇 추가

## Recompute approximate geometry for when the robot is transporting it
# Add temporary robots to the transport units and recalculate the bounding geometry
# then remove them after the new geometries are calcualted
# 운반 중 크기 반영: 임시 로봇을 운반유닛에 붙여 "로봇+화물" 상태의 감싸는 기하를 다시 계산한 뒤, 임시 로봇 제거.
ConstructionBots.add_temporary_invalid_robots!(scene_tree; with_edges=true)  # 임시(invalid) 로봇을 엣지까지 달아 부착
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HypersphereKey())
@assert all(map(node -> ConstructionBots.has_vertex(node.geom_hierarchy, ConstructionBots.HypersphereKey()), ConstructionBots.get_nodes(scene_tree)))  # 모든 노드에 구 근사가 생겼는지 확인
ConstructionBots.compute_approximate_geometries!(scene_tree, ConstructionBots.HyperrectangleKey())
@assert all(map(node -> ConstructionBots.has_vertex(node.geom_hierarchy, ConstructionBots.HyperrectangleKey()), ConstructionBots.get_nodes(scene_tree)))  # 직육면체 근사도 확인
ConstructionBots.remove_temporary_invalid_robots!(scene_tree)  # 임시 로봇 제거(계산용이었으므로)

## Construct Partial Schedule (without robots assigned)
# 부분 스케줄 구성: 아직 어느 로봇이 맡을지는 안 정한 채, 작업 순서(스케줄) 뼈대를 만듦.
print("Constructing partial schedule...")
ConstructionBots.jump_to_final_configuration!(scene_tree; set_edges=true)  # 우선 완성 배치로 점프(목표 자세 확보)
sched = ConstructionBots.construct_partial_construction_schedule(model, model_spec, scene_tree, id_map)  # 부분 스케줄 생성
@assert ConstructionBots.validate_schedule_transform_tree(sched)  # 스케줄의 변환 트리 유효성 검증
print("done!\n")

### Plot the robot positions on the assemblies/objects ###
# 각 운반유닛(TransportUnitNode)에 대해 로봇들이 화물을 어떻게 둘러싸는지 2D로 렌더(여기선 display 주석 처리).
for n in scene_tree.nodes
    if ConstructionBots.matches_template(ConstructionBots.TransportUnitNode, n)  # 노드가 운반유닛 타입이면
        c_id = ConstructionBots.cargo_id(n)                                     # 그 유닛이 나르는 화물 ID
        plt = ConstructionBots.render_transport_unit_2d(scene_tree, n)          # 배치 그림 생성
        # display(plt)
        # push!(cargo_ids, c_id)
    end
end

### Plot the schedule ###
# 스케줄 그래프를 그리기 위한 헬퍼: 이 노드가 "제목에 ID를 붙일 만한" 주요 작업 타입인지 판정.
_node_type_check(n) = ConstructionBots.matches_template((ObjectStart, AssemblyStart, AssemblyComplete, FormTransportUnit, TransportUnitGo, DepositCargo, LiftIntoPlace), n)

# 배정 전 스케줄 그래프 그리기: 왼→오 방향으로 배치, 주요 작업 노드엔 제목에 ID를 붙임(삼항식 ?:).
plt = ConstructionBots.display_graph(
    sched;
    grow_mode=:from_left,           # 그래프를 왼쪽에서 오른쪽으로 성장시키며 배치
    align_mode=:split_aligned,      # 노드 정렬 방식
    draw_node_function=(G, v) -> ConstructionBots.draw_node(ConstructionBots.get_node(G, v);  # 각 노드 그리는 콜백(G=그래프, v=정점)
        title_text=_node_type_check(ConstructionBots.get_node(G, v)   # 주요 작업 노드면 제목에 ID를 덧붙이고, 아니면 기본 제목만
        ) ? string(ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
            "$(ConstructionBots.get_id(ConstructionBots.node_id(ConstructionBots.get_node(G,v))))") : ConstructionBots._title_string(ConstructionBots.get_node(G, v)),
        subtitle_text="",
        title_scale=_node_type_check(ConstructionBots.get_node(G, v)  # 주요 노드는 원래 글자크기, 아니면 0.45로 작게
        ) ? ConstructionBots._title_text_scale(ConstructionBots.get_node(G, v)) : 0.45,
    ),
    pad=(0.0, 0.0)
);


## Generate staging plan
# 스테이징 계획 생성: 각 조립체를 만들기 전, 부품/운반유닛이 대기·집결할 원형 구역들을 배치.
max_object_transport_unit_radius = ConstructionBots.get_max_object_transport_unit_radius(scene_tree)  # 가장 큰 운반유닛 반지름(여유공간 산정 기준)

staging_circles, bounding_circles = ConstructionBots.generate_staging_plan!(scene_tree, sched;  # 스테이징 원들 계산(scene_tree/sched 를 갱신)
    buffer_radius=staging_buffer_factor * max_object_transport_unit_radius,                     # 조립체 주변 여유반경
    build_step_buffer_radius=build_step_buffer_factor * ConstructionBots.default_robot_radius() # 빌드 스텝별 여유반경
)

#### Plot the staging area ####
# 스테이징 구역을 그림으로(여기선 save_image=false 라 파일저장 안 함).
ConstructionBots.plot_staging_area(
    sched, scene_tree, staging_circles;
    save_file_name="staging_area.pdf",
    save_image=false
);


# Make sure all transforms line up
# 스테이징 반영 후 운반 작업들의 변환이 서로 맞도록 보정하고, 다시 유효성 검증(post_staging=true).
ConstructionBots.calibrate_transport_tasks!(sched)
@assert ConstructionBots.validate_schedule_transform_tree(sched; post_staging=true)

# Task Assignments
# ---- 작업배정: 스케줄을 "운영 스케줄"로 바꾸고, 어느 로봇이 어느 작업을 맡을지 최적화(여기선 그리디)로 결정 ----
ConstructionBots.add_dummy_robot_go_nodes!(sched)  # 배정용 더미 RobotGo 노드 추가
@assert ConstructionBots.validate_schedule_transform_tree(sched; post_staging=true)

ConstructionBots.set_default_loading_speed!(50 * ConstructionBots.default_robot_radius())            # 적재 속도 재설정(안전하게 다시 지정)
ConstructionBots.set_default_rotational_loading_speed!(50 * ConstructionBots.default_robot_radius())

tg_sched = ConstructionBots.convert_to_operating_schedule(sched)  # 배정/실행에 쓰는 operating schedule 로 변환

milp_model = ConstructionBots.SparseAdjacencyMILP()  # (참고용) MILP 모델 객체 — 바로 아래에서 그리디로 덮어씀
milp_model = ConstructionBots.GreedyOrderedAssignment(  # 실제로 쓸 배정기: 그리디(완료시간 비용 기준)
    greedy_cost=ConstructionBots.GreedyFinalTimeCost(),  # 비용 = 최종 완료시간(makespan) 관점
)
milp_model = ConstructionBots.formulate_milp(milp_model, tg_sched, scene_tree)  # 스케줄/씬으로 배정 문제 정식화

optimize!(milp_model)  # 배정 문제 풀기(그리디 실행)

validate_schedule_transform_tree(  # 배정 결과를 원래 스케줄 타입으로 되돌려 유효성 재검증
    ConstructionBots.convert_from_operating_schedule(typeof(sched), tg_sched)
    ; post_staging=true
)
ConstructionBots.update_project_schedule!(nothing, milp_model, tg_sched, scene_tree)  # 최적화 결과를 스케줄에 반영(로봇 배정 확정)
@assert ConstructionBots.validate(tg_sched)  # 최종 운영 스케줄 유효성 검증

# Plot the schedule with robots assigned
# 배정 후 스케줄 그래프 그리기(위와 같은 방식, 이번엔 로봇이 배정된 tg_sched 를 그림).
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
);
