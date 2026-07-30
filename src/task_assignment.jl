# ============================================================================
#  이 파일은 "작업 배정(task assignment)"을 담당 — 어느 로봇이 어느 작업(부품 운반)을 맡을지 결정.
#  배정 기준은 "각 작업이 얼마나 걸리는가(소요시간 하한)"이며, 그걸 그리디(greedy)하게 최소화함.
#  Julia 문법 참고:
#   · function f(x::T) ... end : x 가 타입 T 일 때만 적용되는 메서드 정의(다중 디스패치).
#   · 같은 이름의 함수를 인자 타입만 바꿔 여러 번 정의 = "타입마다 다른 동작" (파이썬엔 없는 개념).
#   · `δ`, `ϵ`, `θ`, `ω` 등 그리스문자도 그냥 변수 이름(Julia 는 유니코드 변수명 허용).
#   · `!` 로 끝나는 함수 = 인자를 직접 수정(in-place)한다는 관례.
# ============================================================================

# duration_lower_bound : "이 작업의 최소 소요시간"을 계산하는 함수(노드 종류마다 버전이 여러 개 — 다중 디스패치).
# 인자 없는(시간 0인) 기본 버전 — 한 줄짜리 함수 정의 축약형. ::ConstructionPredicate = 이 타입일 때 적용.
duration_lower_bound(node::ConstructionPredicate) = 0.0
# 시작점→목표점 이동의 최소 소요시간 계산(거리/속도 기반). start,goal 은 좌표, max_speed 는 최대속도.
function duration_lower_bound(node::ConstructionPredicate,start,goal,max_speed)
    env_dt = rvo_default_time_step()        # 시뮬레이션 한 스텝의 시간간격(Δt)
    d = norm(goal-start)                    # 시작→목표 직선거리(norm = 벡터 크기/길이)
    δd = max_speed * env_dt                 # 한 스텝에 갈 수 있는 최대 거리(속도×Δt)
    num_steps = floor(d / δd)               # 거리/스텝당거리 = 필요한 스텝 수(floor = 내림)
    ϵ = capture_distance_tolerance()        # "도착했다"고 인정하는 허용 오차거리
    if abs(d - num_steps * δd) > ϵ # eps(Float64)  # 내림한 스텝으로 못 닿는 잔여거리가 허용오차보다 크면
        num_add_steps = ceil(ϵ / δd)        # 부족분을 메울 추가 스텝 수(ceil = 올림)
        num_steps += num_add_steps          # 스텝 수에 더해줌
    end
    return env_dt * num_steps               # 총 스텝 수 × Δt = 최소 소요시간
end
# EntityGo(로봇/운반체가 이동하는 작업)의 소요시간 — 시작/목표 위치를 좌표로 뽑아 위 함수에 넘김.
function duration_lower_bound(node::EntityGo)
    start = global_transform(start_config(node)).translation  # 시작 자세에서 위치(translation)만 추출
    goal = global_transform(goal_config(node)).translation    # 목표 자세에서 위치만 추출
    duration_lower_bound(node,start,goal,get_rvo_max_speed(entity(node)))  # 그 개체의 최대속도로 시간 계산
end
# 운반팀 형성(FormTransportUnit) 또는 화물 내려놓기(DepositCargo) 작업의 소요시간.
# Union{A,B} = "A 또는 B 타입일 때" 이 메서드 적용.
function duration_lower_bound(node::Union{FormTransportUnit,DepositCargo})
    start = global_transform(cargo_start_config(node)).translation  # 화물의 시작 위치
    goal = global_transform(cargo_goal_config(node)).translation    # 화물의 목표 위치
    duration_lower_bound(node,start,goal,default_loading_speed())    # 적재(loading) 기본속도로 시간 계산
end
# LiftIntoPlace(부품을 들어 제자리에 끼우는 작업)의 소요시간 — 회전과 평행이동을 따로 계산해 합산.
function duration_lower_bound(node::LiftIntoPlace)
    # Need to account for order of movement: rotate, then translate
    env_dt = rvo_default_time_step()        # 한 스텝의 시간간격(Δt)

    v_max = default_loading_speed()             # 최대 평행이동 속도
    ω_max = default_rotational_loading_speed()  # 최대 회전 속도(ω = 각속도)

    start_tform = global_transform(start_config(node))  # 시작 자세(위치+회전)
    goal_tform = global_transform(goal_config(node))    # 목표 자세
    tf_error = relative_transform(start_tform, goal_tform)  # 시작→목표의 차이(상대 변환)

    # translation error
    dx = tf_error.translation[1:2]          # 위치 차이 중 x,y 성분만(1:2 = 1,2번 원소)
    trans_dt = 0.0                          # 평행이동 소요시간 초기화
    if norm(dx) <= 1e-4                      # 위치 차이가 거의 없으면(1e-4 = 0.0001)
        trans_dt = env_dt                   # 한 스텝만
    else
        vel = normalize(dx) * min(v_max, norm(dx) / env_dt)  # 이동방향 단위벡터 × (최대속도와 필요속도 중 작은 값)
        trans_dt = duration_lower_bound(node, tf_error.translation[1:2], [0, 0], norm(vel))  # 그 속도로 걸리는 시간
    end
    # rotation error (estimate for time)
    r = RotationVec(tf_error.linear) # rotation vector  # 회전 차이를 "회전벡터" 형태로 변환
    θ = SVector(r.sx, r.sy, r.sz) # convert r to svector  # 회전벡터의 3성분을 고정크기 벡터 θ 로 (θ = 회전량)
    if norm(θ) <= 1e-4                      # 회전 차이가 거의 없으면
        rot_dt = 0.0                        # 회전 시간 0
    else
        ω = normalize(θ) * min(ω_max, norm(θ) / env_dt)  # 회전방향 단위벡터 × (최대각속도와 필요각속도 중 작은 값)
        rot_dt = duration_lower_bound(node, θ, [0, 0, 0], norm(ω))  # 그 각속도로 걸리는 시간
    end
    return trans_dt + rot_dt                # 평행이동 + 회전 시간을 더해 반환
end

# is_tight : 이 작업의 시간이 "빡빡한지(여유 없음)" 여부. 운반체/로봇 이동은 항상 true.
is_tight(node::Union{TransportUnitGo,RobotGo}) = true

# needs_path : 이 작업이 "이동 경로를 따로 계획해야 하는지" 여부. 아래 종류들은 제자리 작업이라 경로 불필요 → false.
needs_path(node::BuildPhasePredicate)    = false  # 조립단계 시작/종료 표시 노드: 경로 없음
needs_path(node::ObjectStart)            = false  # 물체의 시작 상태: 경로 없음
needs_path(node::AssemblyComplete)       = false  # 조립체 완성: 경로 없음
needs_path(node::AssemblyStart)          = false  # 조립체 시작: 경로 없음
needs_path(node::ProjectComplete)        = false  # 프로젝트 완료: 경로 없음

# generate_path_spec : 한 작업 노드의 "경로 사양(PathSpec)" 객체를 만든다 — 시간/특성 정보를 묶음.
function generate_path_spec(node::ConstructionPredicate)
    PathSpec(
        min_duration=duration_lower_bound(node),  # 최소 소요시간(위에서 정의한 함수로 계산)
        tight=is_tight(node),                     # 시간이 빡빡한지
        static=is_static(node),                   # 정지 상태인지(움직이지 않는지)
        free=is_free(node),                       # 자유롭게 배치 가능한지
        plan_path=needs_path(node)                # 경로 계획이 필요한지
    )
end
# 같은 이름의 다른 버전들 — 앞에 SceneTree/OperatingSchedule 인자를 받아도 결국 위 함수로 위임(다중 디스패치).
# `::SceneTree` 처럼 값 이름 없이 타입만 적으면 "그 인자는 받지만 안 쓴다"는 뜻.
generate_path_spec(::SceneTree,node) = generate_path_spec(node)
generate_path_spec(::OperatingSchedule,scene_tree::SceneTree,node) = generate_path_spec(scene_tree,node)

# 일반 스케줄(sched)을 "운영 스케줄(OperatingSchedule)"로 변환 — 각 노드에 경로 사양을 붙여 새 그래프 생성.
function convert_to_operating_schedule(sched)
    tg_sched = OperatingSchedule()              # 빈 운영 스케줄 생성
    for node in get_nodes(sched)                # 원본의 모든 노드를
        add_node!(tg_sched,ScheduleNode(node_id(node),node_val(node),  # (ID, 값, 경로사양) 으로 묶은 스케줄노드 추가
            generate_path_spec(node_val(node))))
        if matches_template(ProjectComplete,node)  # 이 노드가 "프로젝트 완료" 노드면
            push!(tg_sched.terminal_vtxs, get_vtx(tg_sched, node_id(node)))  # 종료 정점 목록에 등록
        end
    end
    for e in edges(sched)                       # 원본의 모든 엣지를
        add_edge!(tg_sched,get_vtx_id(sched,e.src),get_vtx_id(sched,e.dst))  # 새 스케줄에 동일하게 복원(시작ID→끝ID)
    end
    tg_sched                                    # 완성된 운영 스케줄 반환
end
# 반대 변환 — 운영 스케줄을 원하는 타입 T 의 그래프로 되돌림.
# ::Type{T} = "타입 자체"를 인자로 받음. where {T} = T 는 호출 시 정해지는 타입 매개변수.
function convert_from_operating_schedule(::Type{T},sched::OperatingSchedule) where {T}
    G = T()                                     # 요청한 타입의 빈 그래프 생성
    for node in get_nodes(sched)                # 모든 노드를
        add_node!(G,node.node,node_id(node))    # 내부 값(node.node)과 ID 로 새 그래프에 추가
    end
    for e in edges(sched)                       # 모든 엣지를
        add_edge!(G,get_vtx_id(sched,e.src),get_vtx_id(sched,e.dst))  # 동일하게 복원
    end
    G                                           # 변환된 그래프 반환
end

# is_valid : 노드(SceneNode)가 유효한지 — 그 노드의 ID 가 유효한지로 판단.
# is_valid(node::ConstructionPredicate) = is_valid(node_id(node))
is_valid(node::SceneNode) = is_valid(node_id(node))

# align_with_successor : 한 노드를 그 "뒤따르는 노드(succ)"에 맞춰 정렬(시작/목표 자세를 이어붙임).
# 일반 경우엔 아무것도 안 바꾸고 그대로 반환.
align_with_successor(node::ConstructionPredicate,succ::ConstructionPredicate) = node
# RobotGo(로봇 이동) → 뒤따르는 RobotGo 인 경우: 이 노드의 목표를 다음 노드의 시작에 맞춘 새 RobotGo 생성.
# where {T<:RobotGo} : succ 의 타입 T 가 RobotGo 의 하위타입이어야 함.
align_with_successor(node::RobotGo,succ::T) where {T<:RobotGo} = RobotGo(
    first_valid(entity(node),entity(succ)),  # 두 노드의 개체 중 유효한 것을 선택
    start_config(node),                      # 이 노드의 시작 자세는 유지
    start_config(succ),                      # 목표는 다음 노드의 시작 자세로 맞춤(이어붙이기)
    node_id(node)                            # ID 는 그대로
    )
# align_with_predecessor : 한 노드를 그 "앞선 노드(pred)"에 맞춰 정렬.
# pred 가 위치지정/이동 작업이면, 이 RobotGo 의 시작 자세를 pred 의 목표 자세에 맞춤.
align_with_predecessor(node::RobotGo,pred::T) where {T<:Union{EntityConfigPredicate,EntityGo}} = RobotGo(
    first_valid(entity(node),entity(pred)),  # 유효한 개체 선택
    goal_config(pred),                       # 시작 자세 = 앞선 노드의 목표 자세(이어받기)
    goal_config(node),                       # 이 노드의 목표는 유지
    node_id(node)
    )
# align_with_successor(node::T,succ::S) where {C,T<:EntityConfigPredicate{C},S<:EntityGo{C}} = T(first_valid(node,succ),start_config(node))

ALIGNMENT_CHECK_TOLERANCE = 1e-3   # 정렬이 맞는지 검사할 때 쓰는 허용 오차(전역 상수)

# get_matching_child_id : 운반팀(FormTransportUnit) 안에서, 앞선 로봇(pred)이 들어갈 "자리(슬롯)"의 ID 를 찾는다.
# 로봇이 운반체 둘레의 어느 위치에 붙는지를 상대 변환(위치)으로 매칭.
function get_matching_child_id(node::FormTransportUnit,pred::RobotGo)
    t_rel = relative_transform(                     # 운반팀 목표자세 기준, 로봇 목표자세의 상대 위치 계산
        global_transform(goal_config(node)),
        global_transform(goal_config(pred))
        )
    transport_unit = entity(node)                   # 운반체(여러 로봇으로 구성된 팀) 객체
    for id in collect(keys(robot_team(transport_unit)))  # 팀의 각 로봇 슬롯 ID 에 대해
        tform = child_transform(transport_unit,id)  # 그 슬롯의 (운반체 기준) 부착 위치
        if norm(tform.translation - t_rel.translation) <= 1e-3  # 슬롯 위치와 로봇 위치가 거의 일치하면
            return id                               # 그 슬롯 ID 반환
		end
    end
    return nothing                                  # 일치하는 슬롯 없으면 nothing
end

# 위와 같지만 화물 내려놓기(DepositCargo) → 뒤따르는 로봇(succ)의 슬롯을 찾는 버전.
function get_matching_child_id(node::DepositCargo,succ::RobotGo)
    t_rel = relative_transform(
        global_transform(goal_config(node)),        # 내려놓기 목표자세 기준
        global_transform(start_config(succ))        # 뒤따르는 로봇의 시작자세 상대 위치
        )
    transport_unit = entity(node)
    for id in collect(keys(robot_team(transport_unit)))
        tform = child_transform(transport_unit,id)
        if norm(tform.translation - t_rel.translation) <= 1e-3
            return id
		end
    end
    return nothing
end

# 운반팀 형성 노드를, 앞선 로봇에 맞춰 정렬 — 실제 로봇 ID 를 해당 슬롯에 끼워 넣는다(in-place 수정).
function align_with_predecessor(node::FormTransportUnit,pred::RobotGo)
    matching_id = get_matching_child_id(node,pred)  # 이 로봇이 들어갈 슬롯 찾기
    if !(matching_id === nothing)                   # 슬롯을 찾았으면 (=== nothing 은 "정확히 nothing 인가" 검사)
        transport_unit = entity(node)
        swap_robot_id!(transport_unit,matching_id,node_id(entity(pred)))  # 그 슬롯의 임시ID 를 실제 로봇ID 로 교체(! = 직접 수정)
    end
	node                                            # (수정된) 노드 반환
end
# 화물 내려놓기 다음의 로봇(node)을, 앞선 DepositCargo(pred)에 맞춰 정렬.
# sched 인자가 추가된 이유: 실제 RobotNode 정보는 스케줄에서만 꺼낼 수 있기 때문.
function align_with_predecessor(sched::OperatingSchedule,node::RobotGo,pred::DepositCargo)
    matching_id = get_matching_child_id(pred,node)  # 이 로봇에 해당하는 슬롯 ID
    if !(matching_id === nothing)
        if valid_id(matching_id)                    # 그 ID 가 유효하면
            # Have to pull the RobotNode from sched, because it's not accessible through DepositCargo
            robot_start = get_node(sched,RobotStart(RobotNode(matching_id,entity(node))))  # 스케줄에서 해당 로봇의 시작 노드 가져옴
            return RobotGo(RobotNode(matching_id,entity(robot_start)),start_config(node),goal_config(node),node_id(node))  # 실제 로봇으로 채운 새 RobotGo 반환
        end
    else
        @warn "$(node_id(node)) should be a child of $(node_id(pred))" node pred  # 매칭 실패 시 경고(이 로봇은 pred 의 자식이어야 함)
    end
    return node                                     # 그대로 반환
end

"""
    build_and_link_dummy_robot!(node,id,tform)

Create the dummy `RobotGo` nodes to go in (if `node::FormTransportUnit`) or out
(if `node::DepositCargo`) of node.
"""
# build_and_link_dummy_robot! : 운반팀에 들어가거나(FormTransportUnit) 빠져나올(DepositCargo) "더미(임시) 로봇 이동 노드"를 만든다.
# 아직 실제 로봇이 배정되기 전의 "자리표시용" 노드. id 는 슬롯 ID, tform 은 부착 상대 위치.
function build_and_link_dummy_robot!(node,id,tform)
    robot_go = RobotGo(RobotNode(id,GeomNode(nothing)))  # 형상 없는(nothing) 빈 로봇 이동 노드 생성
    set_parent!(goal_config(robot_go),goal_config(node))  # 이 더미의 목표자세를 node 의 목표자세에 종속시킴(상대좌표 기준)
    set_parent!(start_config(robot_go),goal_config(robot_go))  # 시작자세를 자신의 목표자세에 종속(같은 위치에서 출발)
    set_local_transform!(goal_config(robot_go),tform)    # 목표자세의 국소(상대) 변환을 슬롯 위치 tform 으로 설정
    robot_go                                             # 만든 더미 노드 반환
end

# add_dummy_robot_go_nodes! : 스케줄 전체를 훑어 모든 운반팀에 더미 로봇 노드들을 추가하고 엣지로 연결.
function add_dummy_robot_go_nodes!(sched)
    for node in get_nodes(sched)                        # 스케줄의 모든 노드에 대해
        if matches_template(FormTransportUnit,node)     # 운반팀 형성 노드면
            transport_unit = entity(node)
            for (id,tform) in robot_team(transport_unit)  # 팀의 각 슬롯(ID, 위치)에 대해
                robot_go = build_and_link_dummy_robot!(node,id,tform)  # 더미 로봇 노드 생성
                add_node!(sched, robot_go)              # 스케줄에 추가
                @assert add_edge!(sched,robot_go,node)  # 더미 → 운반팀형성 엣지(로봇이 들어옴). @assert = 추가 성공 확인
            end
        elseif matches_template(DepositCargo,node)      # 화물 내려놓기 노드면
            transport_unit = entity(node)
            for (id,tform) in robot_team(transport_unit)
                robot_go = build_and_link_dummy_robot!(node,id,tform)
                # add_node!(sched, robot_go)
                add_node!(sched, robot_go)
                @assert add_edge!(sched,node,robot_go)  # 내려놓기 → 더미 엣지(로봇이 빠져나감)
            end
        end
    end
end

# compute_backward_depth : 각 노드의 "뒤에서부터 센 깊이"를 계산(스케줄에서의 위상적 위치 측정).
function compute_backward_depth(sched)
    forward_depth = zeros(Int,nv(sched))                # 정점 수(nv)만큼 0으로 채운 앞방향 깊이 배열
    for v in topological_sort_by_dfs(sched)             # 위상정렬 순서(선행→후행)로 순회
        forward_depth[v] = maximum([0,                  # 들어오는 이웃들의 (깊이+1) 중 최댓값(없으면 0)
            map(vp->forward_depth[vp]+1,inneighbors(sched,v))...])  # ... 는 배열을 maximum 의 인자로 펼침(splat)
    end
    backward_depth = deepcopy(forward_depth)            # 앞방향 깊이를 깊은 복사해 시작값으로
    for v in reverse(topological_sort_by_dfs(sched))    # 역순(후행→선행)으로 순회
        backward_depth[v] = maximum(                    # 나가는 이웃들의 (깊이-1) 와 현재값 중 최댓값
            [backward_depth[v],
            map(vp->backward_depth[vp]-1,outneighbors(sched,v))...
            ])
    end
    return backward_depth                               # 뒤방향 깊이 배열 반환
end

export GreedyOrderedAssignment   # 이 타입을 외부에 공개(using 으로 바로 쓸 수 있게)

# GreedyOrderedAssignment : "그리디 순서 기반 작업배정" 문제를 담는 구조체.
# 타입 매개변수 3개 {C,M,P} = 비용모델 / 그리디비용 / 문제명세 의 타입을 빈칸으로 두고 생성 시 정함.
# <: AbstractGreedyAssignment = "그리디 배정"의 한 종류. = 뒤는 각 필드의 기본값(@with_kw 가 키워드 생성자 자동생성).
@with_kw struct GreedyOrderedAssignment{C,M,P} <: AbstractGreedyAssignment
    schedule::OperatingSchedule = OperatingSchedule()   # 배정할 작업들이 담긴 운영 스케줄
    problem_spec::P             = ProblemSpec()         # 문제 명세(여기선 실제로 scene_tree 가 들어감)
    cost_model::C               = SumOfMakeSpans()      # 비용 모델: makespan(전체 완료시간)들의 합
    greedy_cost::M              = GreedyPathLengthCost() # 그리디 선택 기준: 경로 길이 비용
    # 아래는 원작자가 주석처리해 둔 옛 필드들(현재 사용 안 함) — 무시해도 됨.
    # t0::Vector{Float64}         = get_tF(schedule)
    # ordering_graph::DiGraph     = get_graph(greedy_set_precedence_graph(schedule))
    # ordering_graph::DiGraph     = get_graph(construct_build_step_graph(schedule))
    # ordering::Vector{Int}       = topological_sort_by_dfs(ordering_graph)
    # frontier::Set{Int}          = get_all_root_nodes(ordering_graph)
end

# ▼▼▼ 아래 전체 블록은 원작자가 통째로 주석처리해 둔 옛 함수(construct_build_step_graph) — 현재 사용 안 함. 무시해도 됨. ▼▼▼
# """
#     construct_build_step_graph(sched)

# Returns a graph with the same nodes as sched, but with edges modified to enforce
# precedence (for assignment) between the tasks associated with each build phase.
# """
# function construct_build_step_graph(sched)
#     build_step_graph = CustomNDiGraph{_node_type(sched),_id_type(sched)}()
#     # build step dependency graph
#     for n in get_nodes(sched)
#         add_node!(build_step_graph,n,node_id(n))
#     end
#     for n in get_nodes(build_step_graph)
#         val = n.node
#         if matches_template(CloseBuildStep,n)
#             ob = get_node(build_step_graph,OpenBuildStep(val))
#             add_edge!(build_step_graph,ob,n)
#         end
#     end
#     # subassembly dependencies
#     for n in get_nodes(build_step_graph)
#         val = n.node
#         if matches_template(CloseBuildStep,n)
#             blanket = backward_cover(sched,get_vtx(sched,n),np->matches_template(CloseBuildStep,np))
#             for np in blanket
#                 if node_id(np) != node_id(n)
#                     add_edge!(build_step_graph,np,OpenBuildStep(val))
#                 end
#             end
#         end
#     end
#     # add tasks
#     for n in get_nodes(build_step_graph)
#         if matches_template(CloseBuildStep,n)
#             cb = n
#             ob = get_node(sched,OpenBuildStep(n.node))
#             for component in keys(assembly_components(n.node))
#                 if matches_template(ObjectID,component)
#                     transport_unit = TransportUnitNode(ObjectNode(component,GeomNode(nothing)))
#                 else
#                     transport_unit = TransportUnitNode(AssemblyNode(component,GeomNode(nothing)))
#                 end
#                 form_transport_unit = get_node(sched,FormTransportUnit(transport_unit))
#                 for np in node_iterator(sched,inneighbors(sched,form_transport_unit))
#                     if matches_template(RobotGo,np)
#                         add_edge!(build_step_graph,ob,np)
#                         add_edge!(build_step_graph,np,cb)
#                     end
#                 end
#                 deposit_cargo = get_node(sched,DepositCargo(transport_unit))
#                 for np in node_iterator(sched,outneighbors(sched,deposit_cargo))
#                     if matches_template(RobotGo,np)
#                         add_edge!(build_step_graph,cb,np)
#                     end
#                 end
#             end
#         end
#     end
#     build_step_graph
# end
# ▲▲▲ 주석처리된 옛 함수 블록 끝 ▲▲▲

# formulate_milp : "MILP(혼합정수선형계획) 문제를 구성"하는 함수. 이름은 MILP 지만, 여기선 그리디 배정 객체를 만들어 반환.
# 함수 인자 목록의 `;` 뒤(cost_model=..., kwargs...)는 키워드 인자. kwargs... 는 "그 외 모든 키워드 인자를 받아둠".
function formulate_milp(
        milp_model::GreedyOrderedAssignment,    # 기존 배정 설정(여기서 greedy_cost 만 가져옴)
        sched,                                  # 작업 스케줄
        problem_spec;                           # 문제 명세(scene_tree)
        cost_model=SumOfMakeSpans(),            # 비용 모델(기본: makespan 합)
        kwargs...                               # 나머지 키워드 인자(무시)
        )
    GreedyOrderedAssignment(                    # 입력들로 채운 새 배정 객체 생성·반환
        schedule=sched,
        problem_spec=problem_spec,
        cost_model=cost_model,
        greedy_cost = milp_model.greedy_cost,   # 그리디 비용 기준은 기존 모델 것을 재사용
    )
end
# set_leaf_vtxs! : 스케줄의 "종료 정점(말단)"과 각 루트의 가중치를 다시 설정(! = 스케줄 직접 수정).
# template=ProjectComplete : 어떤 노드를 종료점으로 볼지 기본값(프로젝트 완료 노드).
function set_leaf_vtxs!(sched::OperatingSchedule,template=ProjectComplete)
    empty!(get_terminal_vtxs(sched))            # 기존 종료 정점 목록 비우기
    empty!(get_root_node_weights(sched))        # 기존 루트 가중치 비우기
    for v in Graphs.vertices(sched)             # 모든 정점에 대해
        if is_terminal_node(sched,v) && matches_template(template,get_node(sched,v))  # 말단이면서 template 종류면
            push!(get_terminal_vtxs(sched),v)   # 종료 정점으로 등록
            get_root_node_weights(sched)[v] = 1.0  # 그 루트의 가중치를 1.0 으로(makespan 비용에서 동일 비중)
        end
    end
    sched                                       # 수정된 스케줄 반환
end
# JuMP.optimize! 를 우리 타입(GreedyOrderedAssignment)용으로 확장 — 솔버 호출 대신 그리디 배정을 실행.
# JuMP 패키지의 optimize! 함수에 "이 타입일 때의 동작"을 덧붙이는 메서드 확장.
function JuMP.optimize!(model::GreedyOrderedAssignment)
    # greedy_assignment!(model)
    assign_collaborative_tasks!(model)          # 실제 협업 작업 배정 수행(이 파일의 핵심 함수)
    set_leaf_vtxs!(model.schedule, ProjectComplete)  # 배정 후 종료 정점/가중치 정리
end

# construct_build_step_task_set : 한 조립단계(step_id)에서 수행해야 할 "운반 작업들"의 집합을 만든다.
function construct_build_step_task_set(sched,scene_tree,step_id)
    tasks = Set{AbstractID}()                   # 작업 ID 들을 담을 집합(중복 없음)
    n = get_node(sched,step_id)                 # 그 조립단계 노드
    for (part_id,tform) in assembly_components(n.node)  # 이 단계에서 추가되는 각 부품(ID, 부착변환)에 대해
        tu = get_node(scene_tree,TransportUnitNode(get_node(scene_tree,part_id)))  # 그 부품을 나르는 운반체 노드
        form_tu_node = get_node(sched,FormTransportUnit(tu))  # 그 운반체를 "형성"하는 작업 노드
        push!(tasks,node_id(form_tu_node))      # 작업 ID 를 집합에 추가
    end
    tasks                                       # 이 단계의 작업 집합 반환
end

# build_step_dependency_graph : 작업들 사이의 "선후 의존관계 그래프"를 만든다.
# 배정 중 순환(cycle)이 생기지 않도록(=서로 무한정 기다리는 교착 방지) 미리 의존 엣지를 깔아둠.
function build_step_dependency_graph(sched,scene_tree)
    dependency_graph = DiGraph(nv(sched)) # track robot -> build step edges  # 스케줄과 같은 정점 수의 빈 방향그래프
    # add edges between build steps and assemblies
    for n in get_nodes(sched)                       # 모든 노드에 대해
        v = get_vtx(sched,n)                         # 그 노드의 정점번호
        if matches_template(CloseBuildStep,n)        # "조립단계 종료(CloseBuildStep)" 노드면
            close_step_vtx = v                       # 종료 정점
            open_step_vtx = get_vtx(sched,OpenBuildStep(n.node))  # 짝이 되는 "단계 시작" 정점
            add_edge!(dependency_graph,open_step_vtx,close_step_vtx) # open -> close  # 시작→종료 의존
            next_vtx = first(outneighbors(sched,n))  # 종료 다음에 오는 노드(다음 단계 시작 또는 조립완성)
            add_edge!(dependency_graph,close_step_vtx,next_vtx) # close -> next vtx (OpenBuildStep or AssemblyComplete)  # 종료→다음 의존
            for (part_id,tform) in assembly_components(n.node)  # 이 단계에서 붙이는 각 부품에 대해
                part = get_node(scene_tree,part_id)  # 그 부품(또는 하위조립체) 노드
                if matches_template(AssemblyID,part_id)  # 부품이 사실 하위조립체면
                    start_vtx = get_vtx(sched,AssemblyComplete(part))  # 시작점 = 그 조립체가 완성되는 시점
                else
                    start_vtx = get_vtx(sched,ObjectStart(part))  # 개별 물체면 시작점 = 물체 시작
                end
                transport_vtx = get_vtx(sched,FormTransportUnit(TransportUnitNode(part)))  # 그 부품 운반팀 형성 정점
                add_edge!(dependency_graph, start_vtx, transport_vtx)      # 부품 준비됨 → 운반 시작 의존
                add_edge!(dependency_graph, open_step_vtx, transport_vtx)  # 단계 시작 → 운반 의존
                add_edge!(dependency_graph, transport_vtx, close_step_vtx) # 운반 완료 → 단계 종료 의존
            end
        end
    end
    dependency_graph                                # 완성된 의존 그래프 반환
end

"""
    assign_collaborative_tasks!(model)

Assign collaborative tasks in a greedy manner.
"""
# assign_collaborative_tasks! : 이 파일의 핵심 — 로봇들을 협업 운반 작업에 그리디하게 배정한다.
# 매 반복마다 "지금 할 수 있는 모든 (단계, 작업)" 중 비용(예상 완료시간)이 가장 작은 것을 골라 로봇팀을 배정.
function assign_collaborative_tasks!(model,
        # D = construct_schedule_distance_matrix(model.schedule,model.problem_spec)
    )
    sched       = model.schedule                # 작업 스케줄
    scene_tree  = model.problem_spec            # 장면 트리(여기에 부품/조립체 형상·위치 정보)
    # D = construct_schedule_distance_matrix(sched,scene_tree)
    # 모든 "조립체 시작" 노드를 ID→노드 딕셔너리로 수집 (Dict(... for ...) = 파이썬 dict comprehension 과 동일)
    assembly_starts = Dict(node_id(n)=>n for n in get_nodes(sched) if matches_template(AssemblyStart,n))
    assemblies_completed = Set{AbstractID}()    # 완성된 조립체 ID 들을 기록할 집합
    active_build_steps = Dict()                 # 현재 "진행 가능한 조립단계" → 그 단계의 남은 작업집합
    for (k,n) in assembly_starts                # 각 조립체의 시작 노드에 대해
        open_build_step = get_first_build_step(sched,n)  # 그 조립체의 첫 번째 조립단계
        step_id = node_id(open_build_step)
        active_build_steps[step_id] = construct_build_step_task_set(sched,scene_tree,step_id)  # 그 단계의 작업집합을 활성목록에 등록
    end
    # fill robots with go nodes
    robots = Set{Int}()                         # 배정 가능한(놀고 있는) 로봇들의 정점번호 집합
    for n in get_nodes(sched)
        if matches_template(RobotStart,n)        # 로봇 시작 노드면
            # OOD 1-1: 예비 풀(SPARE_POOLS)에 등록된 예비 로봇은 초기 배정에서 제외 → 진짜 idle 로 남겨
            # replace_robot! 인계 대상으로 보존. (예비 주입이 배정보다 먼저라 SPARE_POOLS 는 이미 채워짐.)
            # is_spare 는 respec/ood_injection.jl 에 정의(같은 모듈, 런타임 해석). Symbol 로 안전 호출.
            rid = try node_id(entity(n)) catch; nothing end
            if rid !== nothing && (try is_spare(rid) catch; false end)
                continue                         # 예비 로봇 → 후보 집합에 넣지 않음(작업 미배정 = idle 유지)
            end
            go_vtx = first(outneighbors(sched,n))  # 그 로봇의 첫 이동(RobotGo) 노드
            @assert isempty(outneighbors(sched,go_vtx))  # 아직 아무 작업도 안 붙은(말단) 상태인지 확인
            push!(robots,go_vtx)                 # 가용 로봇 집합에 추가
        end
    end
    robots, active_build_steps                  # (이 줄은 두 변수를 가리키는 표현식일 뿐 — 효과 없음)
    # assign tasks

    # 전체 조립단계 수 세기: OpenBuildStep 노드 개수 ([true for ...] 길이로 셈)
    NUM_BUILD_STEPS = length([true for n in get_nodes(sched) if matches_template(OpenBuildStep,n)])
    BUILD_STEPS_CLOSED = 0                       # 지금까지 완료(닫힌) 단계 수

    @info "Beginning task assignment"            # 배정 시작 로그
    # initialize dependency graph to track and prevent cycles
    dependency_graph = build_step_dependency_graph(sched,scene_tree)  # 순환 방지용 의존그래프 초기화
    # cost_func = (v,v2)->get_edge_cost(model,D,v,v2)
    distance_dict = Dict{Tuple{Int,Int},Float64}()  # (정점v, 정점v2) → 이동시간 캐시(같은 계산 반복 방지)
    # cost_func : 로봇 v 가 작업슬롯 v2 를 맡을 때의 "예상 완료시각"을 돌려주는 익명함수.
    # (v,v2)->begin ... end : 여러 줄짜리 익명함수(파이썬의 lambda 를 여러 줄로 쓴 것).
    cost_func = (v,v2)->begin
        if !haskey(distance_dict,(v,v2))         # 이 쌍의 거리(시간)를 아직 안 구했으면
            new_node = align_with_successor(get_node(sched,v).node,get_node(sched,v2).node)  # v 를 v2 에 맞춰 정렬한 가상 노드
            distance_dict[(v,v2)] = generate_path_spec(sched,scene_tree,new_node).min_duration  # 그 이동의 최소 소요시간을 캐시
        end
        return get_tF(sched,v) + distance_dict[(v,v2)]  # 로봇 v 가 지금 끝나는 시각 + 이동시간 = 작업 완료 예상시각
        # return distance_dict[(v,v2)]
        # get_edge_cost(model,D,v,v2)
    end
    while !isempty(active_build_steps)          # 진행 가능한 단계가 남아있는 동안 반복(메인 루프)
        # get best possible assignment of robots to a team task
        best_cost       = Inf                   # 지금까지 찾은 최소 비용(Inf = 무한대, 초기값)
        build_step_id   = nothing               # 최선 선택의 단계 ID
        task_id         = nothing               # 최선 선택의 작업 ID
        best_assignments = nothing              # 최선 선택의 (로봇=>슬롯) 배정 목록
        for (step_id,tasks) in active_build_steps  # 활성 단계들과 그 작업들을 모두 살펴봄
            step_vtx = get_vtx(sched,step_id)
            # filter out robots that would cause a cycle
            # filt_func = (v,v2)->!has_path(dependency_graph,step_vtx,v)
            # filt_func = (v,v2)->!has_path(sched,step_vtx,v)
            for task in tasks                   # 그 단계의 각 작업(운반팀 형성)에 대해
                task_node = get_node(sched,task)
                cargo = get_node(scene_tree,cargo_id(entity(task_node)))  # 이 작업이 나르는 화물 노드
                if matches_template(AssemblyNode,cargo) && !(node_id(cargo) in assemblies_completed)
                    continue                    # 화물이 하위조립체인데 아직 미완성이면 이 작업은 건너뜀(준비 안 됨)
                end
                # 이 작업에 필요한 "로봇 자리(슬롯)"들 = 들어오는 RobotGo 더미 노드들
                team_slots = Set(v for v in inneighbors(sched,task) if matches_template(RobotGo,get_node(sched,v)))
                assignments = []                # 이 작업에 대한 (로봇=>슬롯) 임시 배정 목록
                # filt_func : 순환을 만들 로봇은 제외하는 필터(이 작업에서 로봇 v 로 가는 경로가 이미 있으면 안 됨)
                filt_func = (v,v2)->!has_path(dependency_graph,get_vtx(sched,task),v)
                cost = 0.0                      # 이 팀 작업의 비용(가장 늦게 도착하는 로봇 기준)
                while !isempty(team_slots)      # 모든 슬롯이 채워질 때까지
                    robot, slot, c = get_best_pair(robots, team_slots,  # 가용 로봇×남은 슬롯 중 비용 최소 쌍 찾기
                        cost_func,              # 비용 함수
                        filt_func,              # 순환 방지 필터
                        )
                    cost = max(c,cost)          # 팀 비용 = 슬롯들 중 가장 큰(가장 늦는) 비용
                    if cost >= best_cost        # 이미 현재 최선보다 나쁘면
                        break                   # 더 볼 필요 없이 중단(가지치기)
                    end
                    push!(assignments,robot=>slot)  # 이 (로봇=>슬롯) 배정 기록
                    @assert slot in team_slots  # 안전 점검
                    @assert robot in robots
                    setdiff!(team_slots,slot) # remove slot from team_slots  # 채운 슬롯 제거
                    setdiff!(robots,robot) # remove robots from robots        # 쓴 로봇을 가용목록에서 임시 제거
                end
                # @info "assignment for $(summary(task)): $assignments"
                # replace robot in robot set
                for (robot,slot) in assignments # 위에서 임시로 뺀 로봇들을 다시 가용목록에 복원
                    push!(robots,robot)         # (아직 확정 배정이 아니라 "후보 평가"였으므로 되돌림)
                end
                # update best assignment
                if cost < best_cost             # 이 작업의 비용이 지금까지 최선보다 작으면
                    build_step_id = step_id     # 최선 후보 정보 갱신
                    task_id = task
                    best_assignments = assignments
                    best_cost = cost
                    # @info "updating best assignment to $(summary(task)): $assignments"
                end
            end
        end
        # update schedule
        @assert !(best_assignments === nothing) "no assignment found!"  # 배정을 못 찾았으면 에러(있어야 정상)
        # @info "best assignment selected $(summary(task_id)): $best_assignments"
        team_task_vtx = get_vtx(sched,task_id)       # 확정된 팀 작업의 정점
        open_step_vtx = get_vtx(sched,build_step_id)  # 그 단계 시작 정점
        close_step_vtx = get_vtx(sched,CloseBuildStep(get_node(sched,build_step_id).node))  # 단계 종료 정점
        for (robot,task) in best_assignments         # 확정된 각 (로봇=>슬롯) 배정을 실제 스케줄에 반영
            add_edge!(sched,robot,task)              # 로봇 → 작업슬롯 엣지(이 로봇이 이 자리를 맡음)
            # add RobotNode -> TeamTask and OpenBuildStep -> TeamTask edges to dependency graph.
            add_edge!(dependency_graph, robot,          team_task_vtx)  # 의존그래프에도 로봇→팀작업
            add_edge!(dependency_graph, open_step_vtx,  team_task_vtx)  # 단계시작→팀작업
            add_edge!(dependency_graph, team_task_vtx,  close_step_vtx) # 팀작업→단계종료
            setdiff!(robots,robot) # remove robots    # 이번엔 진짜로 배정됐으니 가용 로봇에서 제거
        end
        # add new robots
        # 작업이 끝나면 로봇들은 화물 내려놓기(DepositCargo) 후 다시 자유로워짐 → 그 로봇들을 가용목록에 추가
        deposit_node = get_node(sched,DepositCargo(entity(get_node(sched,task_id))))  # 이 작업의 화물 내려놓기 노드
        for v in outneighbors(sched,deposit_node)    # 내려놓기 다음에 나오는 노드들 중
            if matches_template(RobotGo,get_node(sched,v))  # 로봇 이동 노드면(=풀려난 로봇)
                robot = v
                push!(robots,robot)                  # 가용 로봇 집합에 다시 넣음
                # add TeamTask -> RobotNode edge to dependency graph
                add_edge!(dependency_graph, team_task_vtx,  robot)  # 팀작업→풀려난로봇 의존(작업 후 가용)
            end
        end
        # update schedule times
        update_schedule_times!(sched)                # 변경된 배정에 맞춰 스케줄의 시작/종료 시각 재계산
        # update active build step list
        delete!(active_build_steps[build_step_id], task_id)  # 방금 처리한 작업을 그 단계의 남은 작업집합에서 제거
        if isempty(active_build_steps[build_step_id])  # 그 단계의 모든 작업이 끝났으면
            BUILD_STEPS_CLOSED += 1                  # 완료 단계 수 +1
            @info "Assignment: closing build step $(summary(build_step_id)). $(BUILD_STEPS_CLOSED)/$(NUM_BUILD_STEPS) complete. "  # 진행상황 로그
            delete!(active_build_steps, build_step_id)  # 활성목록에서 이 단계 제거
            close_build_step = get_node(sched,CloseBuildStep(get_node(sched,build_step_id).node))  # 종료 노드
            next_node = get_node(sched,first(outneighbors(sched,close_build_step)))  # 그 다음 노드
            if matches_template(OpenBuildStep,next_node)  # 다음이 또 다른 조립단계면
                step_id = node_id(next_node)
                active_build_steps[step_id] = construct_build_step_task_set(  # 그 단계의 작업집합을 새로 활성화
                    sched,
                    scene_tree,
                    step_id)
                # @info "new build step $(summary(step_id)) with tasks $(active_build_steps[step_id])"
            else
                # assembly complete
                @assert matches_template(AssemblyComplete,next_node)  # 아니면 조립체 완성 노드여야 함
                push!(assemblies_completed,node_id(entity(next_node)))  # 그 조립체를 완성 목록에 등록(다른 작업의 화물로 쓸 수 있게)
                @info "Closing Assembly $(summary(node_id(entity(next_node))))"  # 조립체 완성 로그
            end
        end
    end
    @info "Assignment Complete!"                     # 전체 배정 완료 로그
    model                                            # 배정이 반영된 모델 반환
end
