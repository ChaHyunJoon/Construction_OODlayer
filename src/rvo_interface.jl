using PyCall   # 줄리아 안에서 파이썬 라이브러리(여기선 rvo2)를 호출하기 위한 패키지

# =============================================================================
# RVO2 INTERFACE : 상호 충돌회피(③ 최하위 레이어)용 Python RVO2 래퍼
# -----------------------------------------------------------------------------
# RVO(Reciprocal Velocity Obstacles): 각 에이전트가 "선호속도(pref velocity)"를
#   내면, 모든 에이전트가 서로의 속도를 고려해 충돌 없는 새 속도를 동시에 푼다.
#   (책임을 절반씩 나눠 부담 → reciprocal). 실제 풀이는 sisl/Python-RVO2(C++).
# 이 파일의 역할:
#   (1) Julia AbstractID ↔ RVO 정수 인덱스 매핑(RVOAgentMap) 관리
#   (2) 시뮬레이터 생성/파라미터(반경·최대속도·이웃거리) 설정
#   (3) 매 스텝 pref velocity / alpha(우선순위) 주입, 결과 속도/위치 읽기
# 상위 레이어(tangent bug ①, potential field ②)가 만든 속도를 pref로 넣는다.
# =============================================================================

# struct = 새 데이터 타입(파이썬 class 와 비슷, 값을 담는 틀).
# RVO 시뮬레이터 내부의 에이전트 정수 인덱스를 감싸는 래퍼
struct IntWrapper
    idx::Int                          # 감싸고 있는 실제 정수 인덱스
end

# const = 상수(이름을 한 번 정하면 안 바꿈). 여기선 긴 그래프 타입에 짧은 별명(RVOAgentMap)을 붙임.
# NGraph{DiGraph,IntWrapper,AbstractID} : 방향그래프, 노드값=IntWrapper, ID=AbstractID 인 그래프 타입.
const RVOAgentMap = NGraph{DiGraph,IntWrapper,AbstractID}
# nv(m) = 그래프의 노드 개수(number of vertices) → 등록된 에이전트 수. `f(x) = ...` 는 한 줄 함수 정의.
rvo_map_num_agents(m::RVOAgentMap) = nv(m)
# id(줄리아 ID)와 idx(RVO 정수 인덱스)의 대응을 맵에 등록. 이름 끝 `!` = 인자를 직접 수정(in-place)함을 표시.
function set_rvo_id_map!(m::RVOAgentMap, id::AbstractID, idx::Int)
    # @assert 조건 "메시지" : 조건이 거짓이면 에러로 중단. $(...) 는 문자열 안에 값 끼워넣기.
    @assert nv(m) == idx "RVOAgentMap shows $(nv(m)) agents, but this index is $idx"  # 새 인덱스는 현재 노드 수와 같아야(순서대로 추가됨)
    @assert !has_vertex(m, id) "Agent with id $(id) has already been added to schedule"  # 같은 id 가 이미 있으면 안 됨
    add_node!(m, IntWrapper(idx), id)  # idx 를 감싸 노드로, id 를 그 노드 ID 로 그래프에 추가
end
# 같은 함수의 인자 순서만 바꾼 버전(idx 를 먼저 줘도 동작). 다중 디스패치로 인자 타입에 맞춰 자동 선택됨.
set_rvo_id_map!(m::RVOAgentMap, idx::Int, id::AbstractID) = set_rvo_id_map!(m, id, idx)

# 줄리아 ID 로 RVO 인덱스를 조회. `.idx` 는 IntWrapper 안의 필드 접근. 아래는 입력 타입별로 꺼내는 방법만 다름.
rvo_get_agent_idx(id::AbstractID) = node_val(get_node(rvo_global_id_map(), id)).idx  # ID → 노드 → IntWrapper → idx
rvo_get_agent_idx(node::SceneNode) = rvo_get_agent_idx(node_id(node))                # 장면노드면 그 ID 로 다시 조회
rvo_get_agent_idx(node::ConstructionPredicate) = rvo_get_agent_idx(entity(node))     # 술어(predicate)면 그 대상 entity 로
rvo_get_agent_idx(node::ScheduleNode) = rvo_get_agent_idx(node.node)                 # 스케줄노드면 그 안의 .node 로

# global = 전역변수 선언. id↔idx 매핑을 담는 전역 맵을 빈 상태로 초기화.
global RVO_ID_GLOBAL_MAP = RVOAgentMap()
# 전역 맵을 꺼내는 게터(getter) 함수.
function rvo_global_id_map()
    RVO_ID_GLOBAL_MAP   # 마지막 줄의 값이 반환값(return 생략 가능)
end
# 전역 맵을 통째로 교체하는 세터(setter). 함수 안에서 전역변수를 바꾸려면 global 키워드 필요.
function set_rvo_global_id_map!(val)
    global RVO_ID_GLOBAL_MAP = val
end
rvo_map_num_agents() = rvo_map_num_agents(rvo_global_id_map())                    # 인자 없는 버전: 전역 맵의 에이전트 수
set_rvo_id_map!(id::AbstractID, idx::Int) = set_rvo_id_map!(rvo_global_id_map(), id, idx)  # 인자 없는 버전: 전역 맵에 등록
# 전역 맵을 새 빈 맵으로 리셋(시뮬레이션 다시 시작할 때).
function rvo_reset_agent_map!()
    global RVO_ID_GLOBAL_MAP = RVOAgentMap()
end

# (...) 안의 for = "제너레이터"(파이썬의 제너레이터 표현식). 등록된 각 에이전트 노드를 scene_tree 에서 찾아 하나씩 내줌.
rvo_active_agents(scene_tree) = (get_node(scene_tree, node_id(n)) for n in get_nodes(rvo_global_id_map()))

global RVO_PYTHON_MODULE = nothing   # 파이썬 rvo2 모듈을 담을 전역 변수(아직 비어있음 = nothing)
# 로드된 rvo2 파이썬 모듈을 돌려주는 게터.
function rvo_python_module()
    RVO_PYTHON_MODULE
end
# rvo2 모듈 전역변수를 교체하는 세터.
function set_rvo_python_module!(val)
    global RVO_PYTHON_MODULE = val
end

# rvo2 파이썬 모듈을 다시 불러온다(reset 후 재import).
function reset_rvo_python_module!()
    set_rvo_python_module!(nothing)            # 먼저 비우고
    set_rvo_python_module!(pyimport("rvo2"))   # pyimport 로 파이썬 rvo2 모듈을 import 해 저장
end

# 새 RVO 시뮬레이터 생성. 파라미터 의미:
#   dt           : 시간 스텝 [s]
#   neighbor_dist: 충돌회피 시 고려할 이웃 탐색 반경 [m]
#   max_neighbors: 동시에 고려할 최대 이웃 수 (계산량 제한)
#   horizon      : 다른 '에이전트'와의 충돌을 내다보는 시간지평 [s]
#   horizon_obst : 정적 '장애물'에 대한 시간지평 [s]
#   radius       : 기본 에이전트 반경 [m]
#   max_speed    : 기본 최대 속도 [m/s]
# 함수 인자에서 첫 `;` 뒤는 모두 "키워드 인자"(이름 붙여 호출, 기본값 있음). `x::Float64=...` 는 타입+기본값.
function rvo_new_sim(;
    dt::Float64=1 / 40.0,                       # 시간 스텝 [s] (1/40 = 0.025초)
    neighbor_dist::Float64=2.0,                 # 이웃 탐색 반경 [m]
    max_neighbors::Int=5,                       # 동시에 고려할 최대 이웃 수
    horizon::Float64=2.0,                       # 다른 에이전트와의 충돌 예측 시간지평 [s]
    horizon_obst::Float64=1.0,                  # 정적 장애물에 대한 시간지평 [s]
    radius::Float64=0.5,                        # 기본 에이전트 반경 [m]
    max_speed::Float64=rvo_default_max_speed(), # 기본 최대 속도 [m/s] (전역 기본값 함수에서 가져옴)
    default_vel=(0.0, 0.0)                      # 기본 속도 (x, y) 튜플
)
    reset_rvo_python_module!()   # rvo2 모듈 재import
    rvo_reset_agent_map!()       # id↔idx 매핑 초기화
    rvo_python_module().PyRVOSimulator(   # 파이썬 모듈의 PyRVOSimulator(=C++ RVO2 시뮬레이터) 인스턴스 생성·반환
        dt, neighbor_dist, max_neighbors, horizon, horizon_obst, radius, max_speed, default_vel
    )
end

# global RVO_SIM_WRAPPER = RVOSimWrapper(nothing)   # (옛 코드 — 무시)
# CachedElement{Any} : 값을 캐시(저장)해두는 래퍼. {Any} = 아무 타입이나 담는다는 타입 매개변수. (값, 유효플래그, 시각) 으로 초기화.
global RVO_SIM_WRAPPER = CachedElement{Any}(nothing, false, time())
rvo_global_sim_wrapper() = RVO_SIM_WRAPPER   # 시뮬레이터 캐시 래퍼를 돌려주는 게터
# 새 시뮬레이터를 전역 캐시에 설정. sim 인자를 안 주면 rvo_new_sim() 으로 기본 시뮬레이터를 새로 만든다.
function rvo_set_new_sim!(sim=rvo_new_sim())
    set_element!(rvo_global_sim_wrapper(), sim)   # 캐시 래퍼 안에 새 시뮬레이터를 넣음
    # rvo_global_sim_wrapper().sim = sim          # (옛 코드 — 무시)
end
# rvo_global_sim() = rvo_global_sim_wrapper().sim  # (옛 코드 — 무시)
rvo_global_sim() = get_element(rvo_global_sim_wrapper())  # 전역 시뮬레이터 인스턴스를 캐시에서 꺼냄

# RVO PARAMETERS  (아래 전역변수들은 속도·이웃거리의 기본값. 각각 게터/세터 쌍으로 읽고 바꿈)
global RVO_MAX_SPEED_VOLUME_FACTOR = 0.01   # 부피 1당 깎이는 최대속도 양(부피가 클수록 느려짐)
global RVO_MAX_SPEED = 4.0                  # 기본 최대 속도 [m/s]
global RVO_MIN_MAX_SPEED = 1.0              # 최대속도의 하한(아무리 느려도 이 값 이상)
function rvo_default_max_speed()            # 기본 최대속도 게터
    RVO_MAX_SPEED
end
function set_rvo_default_max_speed!(val)    # 기본 최대속도 세터
    global RVO_MAX_SPEED = val
end
function rvo_default_max_speed_volume_factor()      # 부피 감속 계수 게터
    RVO_MAX_SPEED_VOLUME_FACTOR
end
function set_rvo_default_max_speed_volume_factor!(val)  # 부피 감속 계수 세터
    global RVO_MAX_SPEED_VOLUME_FACTOR = val
end
function rvo_default_min_max_speed()        # 최대속도 하한 게터
    RVO_MIN_MAX_SPEED
end
function set_rvo_default_min_max_speed!(val)  # 최대속도 하한 세터
    global RVO_MIN_MAX_SPEED = val
end

""" get_rvo_max_speed(node) """
# `::RobotNode` 처럼 값 이름 없이 타입만 적으면 "이 타입일 때만 이 메서드를 쓴다"(다중 디스패치).
# 단일 로봇은 기본 최대속도.
get_rvo_max_speed(::RobotNode) = rvo_default_max_speed()
# 운반팀/적재물은 부피가 클수록 느리게:
#   vmax_eff = max(vmax - vol·factor, min_max_speed)
#   → 큰 payload를 든 팀은 기동성이 떨어진다는 물리적 직관을 모델링.
function get_rvo_max_speed(node)
    rect = get_base_geom(node, HyperrectangleKey())  # 노드의 기본 형상을 "직육면체(경계상자)"로 가져옴
    vol = LazySets.volume(rect)              # 경계상자 부피
    # Speed limited by volume
    vmax = rvo_default_max_speed()           # 기본 최대속도에서 출발
    delta_v = vol * rvo_default_max_speed_volume_factor()  # 부피 비례 감속량
    return max(vmax - delta_v, rvo_default_min_max_speed())# 하한 보장
end

""" get_rvo_radius(node) """
# 노드의 기본 형상을 "구(hypersphere)"로 가져와 그 반지름을 RVO 에이전트 반경으로 사용.
get_rvo_radius(node) = get_base_geom(node, HypersphereKey()).radius


global RVO_DEFAULT_TIME_STEP = 1 / 40.0     # 기본 시간 스텝 [s]
function rvo_default_time_step()            # 기본 시간 스텝 게터
    RVO_DEFAULT_TIME_STEP
end
function set_rvo_default_time_step!(val)    # 기본 시간 스텝 세터
    global RVO_DEFAULT_TIME_STEP = val
end


global RVO_DEFAULT_NEIGHBOR_DISTANCE = 2.0                     # 기본 이웃 탐색 거리 [m]
global RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE = 1.0                 # 이웃 탐색 거리의 하한 [m]
global RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR = 1.0    # 속도에 따라 탐색거리를 조절하는 비례계수
function rvo_default_neighbor_distance()            # 기본 이웃거리 게터
    RVO_DEFAULT_NEIGHBOR_DISTANCE
end
function set_rvo_default_neighbor_distance!(val)    # 기본 이웃거리 세터
    global RVO_DEFAULT_NEIGHBOR_DISTANCE = val
end
function rvo_default_min_neighbor_distance()        # 이웃거리 하한 게터
    RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE
end
function set_rvo_default_min_neighbor_distance!(val)  # 이웃거리 하한 세터
    global RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE = val
end
function rvo_default_neighborhood_velocity_scale_factor()      # 속도-탐색거리 비례계수 게터
    RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR
end
function set_rvo_default_neighborhood_velocity_scale_factor!(val)  # 속도-탐색거리 비례계수 세터
    global RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR = val
end

# 이웃 탐색 거리: 빠른(느린) 에이전트일수록 더 멀리(가까이) 살핀다.
#   d = max(default - (v/vmax)·scale, min_dist)
function get_rvo_neighbor_distance(node)
    d = rvo_default_neighbor_distance()                            # 기본 탐색거리에서 시작
    v_ratio = get_rvo_max_speed(node) / rvo_default_max_speed()    # 이 노드 최대속도가 기본대비 얼마나 빠른지(비율)
    delta_d = v_ratio * rvo_default_neighborhood_velocity_scale_factor()  # 비율에 따른 탐색거리 조정량
    d = max(d - delta_d, rvo_default_min_neighbor_distance())      # 조정 후 하한 보장(마지막 줄 값이 반환됨)
end

# 에이전트(로봇/운반팀)를 RVO 시뮬레이터에 등록하고 id↔idx 매핑을 저장.
# `Union{A,B}` = A 또는 B 둘 중 아무 타입이나 받는다는 합집합 타입.
# 반경/최대속도/이웃거리를 위 함수들로 산출해 개별 설정.
function rvo_add_agent!(agent::Union{RobotNode,TransportUnitNode}, sim)
    rad = get_rvo_radius(agent) * 1.05 # Add a little bit of padding for visualization  # 시각화용 여유 5% 추가
    max_speed = get_rvo_max_speed(agent)                     # 이 에이전트의 최대속도 산출
    neighbor_dist = get_rvo_neighbor_distance(agent)         # 이 에이전트의 이웃 탐색거리 산출
    pt = project_to_2d(global_transform(agent).translation)  # 3D 포즈 → 2D 평면위치
    agent_idx = sim.addAgent((pt[1], pt[2]))                 # RVO에 추가, 인덱스 획득 (sim.addAgent 는 파이썬 메서드 호출)
    set_rvo_id_map!(node_id(agent), agent_idx)               # Julia id ↔ RVO idx 저장
    sim.setAgentNeighborDist(agent_idx, neighbor_dist)       # 이 에이전트의 이웃거리 설정
    sim.setAgentMaxSpeed(agent_idx, max_speed)               # 최대속도 설정
    sim.setAgentRadius(agent_idx, rad)                       # 반경 설정
    return agent_idx                                         # RVO 인덱스 반환
end


# 에이전트의 현재 위치를 RVO 시뮬레이터에서 읽어옴.
function rvo_get_agent_position(n)
    rvo_idx = rvo_get_agent_idx(n)                  # 노드 → RVO 인덱스
    rvo_global_sim().getAgentPosition(rvo_idx)      # 시뮬레이터에서 (x,y) 위치 조회
end
# 에이전트 위치를 강제로 설정(텔레포트). pos[1],pos[2] = x,y.
function rvo_set_agent_position!(node, pos)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentPosition(idx, (pos[1], pos[2]))
end

# pref velocity 주입: 상위 레이어(①②)가 계산한 "가고 싶은 속도"를 RVO에 전달.
#   다음 sim.doStep() 에서 RVO가 이걸 최대한 존중하되 충돌 없는 속도로 보정한다.
function rvo_set_agent_pref_velocity!(node, vel)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentPrefVelocity(idx, (vel[1], vel[2]))  # 선호속도 (vx,vy) 설정
end

# 현재 설정된 선호속도를 읽어옴.
function rvo_get_agent_pref_velocity(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentPrefVelocity(idx)
end
# doStep() 후 RVO가 실제로 정한 충돌회피 속도를 읽어옴(위치 적분에 사용).
function rvo_get_agent_velocity(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentVelocity(idx)
end

# 에이전트의 최대속도를 설정. speed 를 안 주면 노드로부터 계산한 기본값 사용.
function rvo_set_agent_max_speed!(node, speed=get_rvo_max_speed(node))
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentMaxSpeed(idx, speed)
end
# alpha = 동적 우선순위(작을수록 높음). sisl이 RVO2를 fork해 추가한 기능으로,
#   충돌회피 책임 분담을 비대칭으로 만든다(우선순위 낮은 쪽이 더 많이 양보).
#   값은 route_planning.set_rvo_priority! 가 작업 상태에 따라 매 스텝 갱신.
function rvo_set_agent_alpha!(node, alpha=0.5)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentAlpha(idx, alpha)   # 우선순위 alpha 설정
end
# 현재 alpha(우선순위) 값을 읽어옴.
function rvo_get_agent_alpha(node)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().getAgentAlpha(idx)
end

# 메타프로그래밍: 아래 타입 목록 각각에 대해 같은 메서드를 자동으로 찍어낸다(반복 코드 줄이기).
# `:RobotStart` 처럼 `:` 가 붙으면 "심볼"(이름 자체를 값으로 다룸). @eval 은 코드를 만들어 실행하는 매크로.
for T in (
    :RobotStart,           # 로봇 시작
    :RobotGo,              # 로봇 이동
    :FormTransportUnit,    # 운반팀 대형 형성
    :TransportUnitGo,      # 운반팀 이동
    :DepositCargo          # 적재물 내려놓기
)
    @eval begin
        # $T 는 위 루프의 T(타입 이름)를 코드 안에 끼워넣음 → 이 5개 타입에 대해 "RVO 에이전트 자격 있음(true)" 메서드 생성.
        rvo_eligible_node(n::$T) = true
    end
end
# 위 5개에 해당하지 않는 그 외 모든 노드는 RVO 에이전트 자격 없음(false). (가장 일반적인 fallback 메서드)
rvo_eligible_node(n) = false

# 현재 scene_tree에서 "독립적으로 움직이는 단위"만 RVO 에이전트로 등록:
#   - 자유 로봇: 다른 노드에 매달려 있지 않은 root 로봇(=팀에 안 묶인 단독 로봇)
#   - 운반팀(TransportUnit): 대형(formation)이 갖춰진 팀 전체를 하나의 에이전트로
#   (팀에 묶인 개별 로봇은 팀 에이전트로 대표되므로 따로 등록하지 않음)
# sim 인자를 안 주면 전역 시뮬레이터를 사용.
function rvo_add_agents!(scene_tree, sim=rvo_global_sim())
    for node in get_nodes(scene_tree)                 # 장면 트리의 모든 노드를 순회
        if matches_template(RobotNode, node)          # 이 노드가 로봇이면 (matches_template = 타입 일치 검사)
            if is_root_node(scene_tree, node)        # 팀에 안 묶인 단독 로봇
                idx = rvo_add_agent!(node, sim)       # RVO 에이전트로 등록
            end
        elseif matches_template(TransportUnitNode, node)  # 운반팀 노드면
            if is_in_formation(node, scene_tree)     # 대형 완성된 운반팀
                idx = rvo_add_agent!(node, sim)       # RVO 에이전트로 등록
            end
        end
    end
end

# 위 등록 대상 중 아직 전역 맵에 없는 에이전트가 있는지 검사 → 있으면 시뮬레이터 갱신 필요(true).
function rvo_sim_needs_update(scene_tree)
    for node in get_nodes(scene_tree)                 # 모든 노드를 순회하며
        if matches_template(RobotNode, node)          # 로봇이고
            if is_root_node(scene_tree, node)         # 단독 로봇인데
                if !has_vertex(rvo_global_id_map(), node_id(node))  # 아직 맵에 등록 안 됐으면
                    return true                       # 갱신 필요
                end
            end
        elseif matches_template(TransportUnitNode, node)  # 운반팀이고
            if is_in_formation(node, scene_tree)      # 대형이 완성됐는데
                if !has_vertex(rvo_global_id_map(), node_id(node))  # 아직 맵에 없으면
                    return true                       # 갱신 필요
                end
            end
        end
    end
    return false                                      # 빠진 에이전트 없음 → 갱신 불필요
end
