# export : 이 모듈을 `using ConstructionBots` 한 외부에서 모듈명 없이 바로 쓸 수 있게 공개하는 목록.
export
    PlannerEnv,                  # 시뮬레이션 환경 전체 상태를 담는 구조체
    step_environment!,           # 시뮬레이션을 한 시간스텝 전진시키는 함수
    get_cmd,                     # 각 노드(로봇/작업)에게 보낼 명령(목표 속도 등) 계산
    apply_cmd!,                  # 계산된 명령을 실제 상태(위치 등)에 적용(! = 인자 수정)
    project_complete,            # 프로젝트(조립)가 다 끝났는지 검사
    close_node!,                 # 한 작업 노드를 "완료" 처리
    preprocess_env!,             # 매 갱신 전 환경을 정리(운반유닛 결합/해체 등)
    update_planning_cache!,      # 완료된 노드를 반영해 활성/완료 집합을 갱신
    parent_build_step_is_active, # 이 노드의 상위 조립단계가 현재 활성인지 여부
    update_parent_build_status!  # 상위 조립단계 활성 여부를 캐시에 갱신


export
    use_rvo,                  # RVO(충돌회피) 사용 여부 조회
    set_use_rvo!,            # RVO 사용 여부 설정
    avoid_staging_areas,     # 적치(staging) 구역 회피 여부 조회
    set_avoid_staging_areas! # 적치 구역 회피 여부 설정

# global : 모듈 수준의 "전역 변수"(파이썬의 모듈 전역과 비슷). 함수 안에서 바꾸려면 다시 global 선언 필요.
global USE_RVO = true        # RVO 충돌회피를 켤지(true=사용)
use_rvo() = USE_RVO          # 한 줄 함수 — 현재 값 그대로 반환
function set_use_rvo!(val)    # 값을 바꾸는 setter(! = 전역상태 변경)
    global USE_RVO = val      # 함수 안에서 전역을 수정하려면 global 키워드 필요
end
global AVOID_STAGING_AREAS = false  # 적치 구역을 피해 다닐지 여부(기본 끔)
avoid_staging_areas() = AVOID_STAGING_AREAS  # 현재 값 반환
function set_avoid_staging_areas!(val)        # 값 설정
    global AVOID_STAGING_AREAS = val
end
global STAGING_BUFFER_RADIUS = 0.0  # 적치 원의 추가 여유반경(0이면 여유 없음)
staging_buffer_radius() = STAGING_BUFFER_RADIUS  # 현재 값 반환
function set_staging_buffer_radius!(val)          # 값 설정
    global STAGING_BUFFER_RADIUS = val
end

export
    Twist,           # 강체의 순간 운동(병진속도+각속도)을 묶은 타입
    optimal_twist,   # 목표까지의 오차로부터 최적 속도(twist) 계산
    integrate_twist  # twist 를 dt 만큼 적분해 위치/자세 변화량 계산

"""
    Twist
"""
# struct Twist : "트위스트"(강체의 순간 운동) 하나를 표현하는 새 타입(파이썬 class 와 비슷).
# vel = 병진(직선) 속도, ω(오메가) = 회전 각속도. SVector{3,Float64} = 길이 3 의 고정크기 실수벡터(x,y,z).
struct Twist
    vel::SVector{3,Float64}  # 직선 이동 속도 벡터 (m/s)
    ω::SVector{3,Float64}    # 각속도 벡터 (회전축 방향·크기로 회전속도 표현)
end
# Base.zero 확장 : Julia 표준 함수 zero 에 "Twist 의 0(정지 상태)"을 정의. ::Type{Twist} 는 값이 아니라 타입 자체를 인자로 받음.
Base.zero(::Type{Twist}) = Twist(SVector(0.0, 0.0, 0.0), SVector(0.0, 0.0, 0.0))  # 속도·각속도 모두 0 인 정지 트위스트

"""
    optimal_twist(tf_error,v_max,ω_max)

Given a pose error `tf_error`, compute the maximum magnitude `Twist` that
satisfies the bounds on linear and angular velocity and does not overshoot the
goal pose.
    tf_error = inv(state) ∘ goal # transform error from state to goal
    i.e., state ∘ tf_error == goal
"""
# 현재 자세와 목표 자세의 오차(tf_error)로부터, 속도/각속도 한계를 지키면서 목표를 넘어가지 않는 최적 트위스트를 구한다.
# v_max=최대 직선속도, ω_max=최대 각속도, dt=한 스텝 시간, ϵ_x/ϵ_θ=오차 무시 임계값(아주 작으면 멈춤).
function optimal_twist(tf_error, v_max, ω_max, dt, ϵ_x=1e-4, ϵ_θ=1e-4)
    # translation error
    dx = tf_error.translation              # 목표까지 남은 위치 오차 벡터(어디로 얼마나 가야 하는가)
    if norm(dx) <= ϵ_x                     # 남은 거리가 무시할 만큼 작으면(norm = 벡터 길이)
        vel = SVector(0.0, 0.0, 0.0)       # 직선속도 0 (이미 도착)
    else
        vel = normalize(dx) * min(v_max, norm(dx) / dt)  # 목표 방향(정규화)으로, 한 스텝에 넘지 않을 만큼의 속도
    end
    vel = any(isnan, vel) ? SVector(0.0, 0.0, 0.0) : vel  # NaN(계산 오류)가 섞이면 안전하게 0 으로(삼항식: 조건 ? 참 : 거짓)
    # rotation error
    r = RotationVec(tf_error.linear) # rotation vector   # 회전 오차를 "회전벡터"(축×각도) 형태로 변환
    θ = SVector(r.sx, r.sy, r.sz) # convert r to svector  # 회전벡터의 x,y,z 성분을 벡터 θ(세타)로 모음
    if norm(θ) <= ϵ_θ                      # 남은 회전량이 무시할 만큼 작으면
        ω = SVector(0.0, 0.0, 0.0)         # 각속도 0
    else
        ω = normalize(θ) * min(ω_max, norm(θ) / dt)  # 회전축 방향으로, 한 스텝에 넘지 않을 각속도
    end
    ω = any(isnan, ω) ? SVector(0.0, 0.0, 0.0) : ω  # 마찬가지로 NaN 방지
    Twist(vel, ω)                          # 직선속도+각속도를 묶어 트위스트로 반환(마지막 줄 값이 반환값)
end

"""
    apply_twist!(tf,twist,dt)

Integrate `twist::Twist` for `dt` seconds to obtain a rigid transform.
"""
# twist(순간 속도)를 dt 초 동안 적용했을 때의 "이동+회전 변환"을 만든다(속도 → 실제 위치/자세 변화로).
function integrate_twist(twist, dt)
    Δx = twist.vel * dt # translation increment   # 이번 스텝의 위치 변화량(속도×시간). Δ(델타)=변화량.
    ΔR = exp(cross_product_operator(twist.ω) * dt)  # 각속도로부터 이번 스텝의 회전행렬 계산(지수맵; 외적연산자→행렬, exp=행렬지수)
    # ∘ (동그라미)는 변환의 "합성"(파이썬에 직접 대응 없음). 먼저 회전(LinearMap) 후 이동(Translation)을 하나로 합침.
    Δ = CoordinateTransformations.Translation(Δx) ∘ CoordinateTransformations.LinearMap(ΔR)  # 이동변환 ∘ 회전변환
    return Δ                                      # 이번 스텝의 강체 변환(증분) 반환
end

"""
    PlannerEnv

Contains the Environment state and definition.
"""
# @with_kw : Parameters 패키지의 매크로. 키워드 생성자를 자동 생성 → PlannerEnv(dt=0.1) 처럼 필드명으로 만들 수 있게 함.
# struct PlannerEnv : 시뮬레이션 환경의 모든 상태를 한 곳에 모은 구조체. `= 기본값` 은 안 넘기면 들어갈 초기값.
@with_kw struct PlannerEnv
    sched::OperatingSchedule = OperatingSchedule()  # 작업 스케줄(어떤 작업을 어떤 순서로) 그래프
    scene_tree::SceneTree = SceneTree()             # 장면 트리(모든 로봇/부품의 위치·계층 관계)
    cache::PlanningCache = initialize_planning_cache(sched)  # 계획 캐시(현재 활성/완료된 노드 집합 등)
    staging_circles::Dict{AbstractID,LazySets.Ball2} = Dict{AbstractID,LazySets.Ball2}()  # 각 조립체의 적치 원(부품을 모아두는 원형 구역)
    active_build_steps::Set{AbstractID} = Set{AbstractID}()  # 현재 활성인 조립단계들의 ID 집합
    dt::Float64 = rvo_default_time_step()           # 한 시간스텝의 길이(초)
    agent_policies::Dict = Dict()                   # 각 에이전트(로봇)의 이동 정책(TangentBug/포텐셜장 등)
    agent_parent_build_step_active::Dict = Dict()   # 각 에이전트의 상위 조립단계 활성 여부 캐시
    staging_buffers::Dict{AbstractID,Float64} = Dict{AbstractID,Float64}() # dynamic buffer for staging areas  # 적치 원의 동적 여유반경(막히면 키움)
    max_robot_go_id::Int64 = Inf                    # 로봇 이동노드 ID 의 최댓값(우선순위 정규화용)
    max_cargo_id::Int64 = Inf                       # 화물 ID 의 최댓값(우선순위 정규화용)
end

# node 가 현재 "활성 집합"에 들어있는지 검사. `in` 은 파이썬과 동일(원소 포함 여부). env.sched 는 필드 접근(파이썬 . 과 동일).
node_is_active(env, node) = get_vtx(env.sched, node_id(node)) in env.cache.active_set   # 노드 → 정점번호 → 활성집합에 있나
node_is_closed(env, node) = get_vtx(env.sched, node_id(node)) in env.cache.closed_set    # 노드가 "완료 집합"에 들어있나

# 이 노드(에이전트)의 상위 조립단계 활성 여부를 계산해 캐시 딕셔너리에 저장(! = 환경 상태 수정).
function update_parent_build_status!(env::PlannerEnv, node)
    env.agent_parent_build_step_active[node_id(entity(node))] = parent_build_step_is_active(node, env)  # ID 키에 활성여부 저장
end

# parent_build_step_is_active : 같은 이름이지만 인자 타입이 달라 다른 메서드가 호출됨(다중 디스패치).
# (1) ID 를 받는 버전 — 미리 캐시해 둔 값을 그냥 꺼내 반환.
function parent_build_step_is_active(id::AbstractID, env::PlannerEnv)
    return get(env.agent_parent_build_step_active, id, false)    # 캐시에서 조회
end

# (2) 노드를 받는 버전 — 실제로 상위 조립단계를 찾아 활성집합에 있는지 직접 계산.
function parent_build_step_is_active(node, env::PlannerEnv)
    build_step = get_parent_build_step(env.sched, node)  # 이 노드의 상위 조립단계 노드를 찾음
    # && 는 단축평가(파이썬 and). 단계가 존재(nothing 아님)하고 + 그 ID 가 활성집합에 있으면 true.
    !(build_step === nothing) && node_id(build_step) in env.active_build_steps
end
# cargo_ready_for_pickup : 운반할 화물이 "집어올 준비"가 됐는지 검사(노드 종류별로 다른 메서드).
# Union{A,B,C} = 셋 중 한 타입일 때 이 메서드 사용.
function cargo_ready_for_pickup(n::Union{FormTransportUnit,TransportUnitGo,DepositCargo}, env::PlannerEnv)
    @unpack sched, scene_tree, cache = env  # @unpack : env 의 필드를 같은 이름의 지역변수로 한꺼번에 꺼냄(파이썬엔 직접 대응 없음)
    cargo = get_node(scene_tree, cargo_id(entity(n)))  # 이 노드가 다루는 화물 노드를 가져옴
    if matches_template(ObjectNode, cargo)  # 화물이 단일 부품(ObjectNode)이면
        return true                         # 부품은 언제나 집어올 수 있음
    else
        return node_is_closed(env, AssemblyComplete(cargo))  # 조립체면 "조립 완료" 노드가 닫혀야(완성돼야) 준비됨
    end
end
# RobotStart/RobotGo 노드용 — 로봇이 향하는 다음 작업의 화물이 준비됐는지로 위임.
function cargo_ready_for_pickup(n::Union{RobotStart,RobotGo}, env::PlannerEnv)
    if outdegree(env.sched, n) < 1          # 나가는 엣지가 없으면(다음 작업이 없으면)
        return false                        # 집을 화물 없음
    end
    cargo_ready_for_pickup(get_node(env.sched, first(outneighbors(env.sched, n))), env)  # 다음(첫 후행) 노드에 대해 재검사
end
# ScheduleNode 래퍼는 안쪽 실제 노드(.node)로 위임.
cargo_ready_for_pickup(n::ScheduleNode, env::PlannerEnv) = cargo_ready_for_pickup(n.node, env)

# Ideally, we want to set the priority of agents only within a certain region. If we
# can do this dynamically, we could also set one agent to have an α of 0, which would help
# reduce grid lock (by forcing other agents to move around it)
"""
    set_rvo_priority!(env, node)

Low alpha means higher priority
"""
# (기본 메서드) 위 타입들 외의 노드에는 아무것도 하지 않음. 빈 함수 본문(end 만 있음).
function set_rvo_priority!(env::PlannerEnv, node) end
# 이동하는 에이전트 노드들에 대해 RVO 우선순위 alpha 를 정함. alpha 가 낮을수록 우선순위 높음(남이 비켜줌).
function set_rvo_priority!(env::PlannerEnv, node::Union{RobotStart,RobotGo,FormTransportUnit,TransportUnitGo,DepositCargo})
    if matches_template(Union{FormTransportUnit,DepositCargo}, node)  # 운반유닛 결성/화물 내려놓기 작업이면
        alpha = 0.0                          # 최고 우선순위(절대 안 비킴 — 정밀 작업 중)
    elseif matches_template(TransportUnitGo, node)  # 운반유닛 이동이면
        if parent_build_step_is_active(node, env)   # 상위 조립단계가 활성이면
            c_id = cargo_id(entity(node)).id        # 화물 ID 숫자
            alpha = 0.0 + c_id / (10 * env.max_cargo_id)  # 화물ID 로 미세하게 우선순위 차등(거의 0, 데드락 방지용)
        else
            alpha = 1.0                       # 비활성이면 낮은 우선순위(잘 비켜줌)
        end
    elseif parent_build_step_is_active(node, env)   # 그 외(로봇 이동)인데 상위단계가 활성이면
        if cargo_ready_for_pickup(node, env)        # 집을 화물이 준비됐으면
            alpha = 0.1                       # 비교적 높은 우선순위
        else
            alpha = 0.5                       # 중간 우선순위
        end
    else
        alpha = 1.0                           # 그 외엔 가장 낮은 우선순위
    end
    # V5 (respec OOD 1-1): a RECOVERY SPARE adopts a faulted robot's tasks out of order and must
    # traverse the now-congested late build; without help it RVO-gridlocks. Give it top priority
    # (very low alpha) so other robots yield and it cuts through to finish the hand-off. Gated by
    # SPARE_PRIORITY (default on); inert in nominal runs (RECOVERY_SPARES empty).
    # (요약) 고장난 로봇의 일을 순서 뒤바꿔 넘겨받은 "복구용 스페어"는 이미 혼잡해진 후반 빌드를 뚫고 가야 함 → 최상위 우선순위(alpha 아주 낮게)를 줘서 남들이 비켜주게 함. get(ENV,키,기본) = 환경변수 조회(없으면 "1"). SPARE_PRIORITY 로 on/off, 평상시(스페어 없음)엔 무해.
    if get(ENV, "SPARE_PRIORITY", "1") == "1" && matches_template(RobotGo, node)
        is_recovery_spare(try entity(node).id catch; nothing end) && (alpha = min(alpha, 0.02))  # 복구용 스페어면 alpha 를 0.02 로 낮춤(더 낮은 쪽 선택)
    end
    # V6 (respec OOD 1-1): break a multi-robot TEAM deadlock. A FormTransportUnit needs ALL its
    # members in position simultaneously; if some are already waiting (in capture) and THIS robot
    # is the straggler, the waiting members can block its path so the team never forms. Give the
    # straggler top priority so others yield and it can complete the formation. Gated by
    # TEAM_PRIORITY (default on); harmless in nominal runs (just speeds up team forming).
    # (요약) 여러 로봇이 "동시에" 제자리에 모여야 하는 FormTransportUnit 팀 교착을 풂 — 일부는 이미 도착해 기다리는데 나만 뒤처진 낙오자(straggler)면, 기다리는 동료들이 내 길을 막아 대형이 영영 안 만들어질 수 있음. 이때 나를 최상위 우선순위로 올려 끼어들어 대형을 완성시킴. TEAM_PRIORITY 로 on/off.
    if get(ENV, "TEAM_PRIORITY", "1") == "1" && matches_template(RobotGo, node)
        try
            outs = outneighbors(env.sched, node)   # 이 로봇의 다음 작업들
            if !isempty(outs)
                nxt = get_node(env.sched, outs[1])  # 첫 후행 노드
                if matches_template(FormTransportUnit, nxt)  # 다음이 운반유닛 결성이면
                    tu = entity(nxt); meid = node_id(entity(node))  # tu=운반유닛, meid=내 ID
                    if !is_within_capture_distance(tu, get_node(env.scene_tree, meid))  # 나는 아직 제자리에 없으면
                        others_ready = 0                # 이미 제자리에 온 동료 수
                        for (mid, _) in robot_team(tu)  # 팀의 모든 멤버에 대해
                            mid == meid && continue     # 나 자신은 건너뜀
                            rn = get_node(env.scene_tree, mid)
                            is_within_capture_distance(tu, rn) && (others_ready += 1)  # 제자리에 있으면 카운트
                        end
                        others_ready >= 1 && (alpha = min(alpha, 0.03))   # straggler of a forming team  # 기다리는 동료가 하나라도 있으면 내가 낙오자 → 우선순위 올림
                    end
                end
            end
        catch   # 위 조회 중 예외가 나면 그냥 무시(우선순위 조정 생략)
        end
    end
    rvo_set_agent_alpha!(node, alpha)         # 계산한 alpha 를 RVO 시뮬레이터에 설정
end


"""
    LOADING_SPEED

The max velocity with which a part may be loaded (e.g., by LiftIntoPlace,
FormTransportUnit,DepositCargo)
"""
global LOADING_SPEED = 0.1                 # 부품을 싣거나 놓을 때의 최대 직선속도(천천히 정밀하게)
default_loading_speed() = LOADING_SPEED    # 현재 값 반환
function set_default_loading_speed!(val::Float64)  # 값 설정(::Float64 = 실수만 받음)
    global LOADING_SPEED = val
end

"""
    ROTATIONAL_LOADING_SPEED

The max rotational velocity with which a part may be loaded (e.g., by
LiftIntoPlace,FormTransportUnit,DepositCargo)
"""
global ROTATIONAL_LOADING_SPEED = 0.1      # 부품을 싣거나 놓을 때의 최대 회전속도
default_rotational_loading_speed() = ROTATIONAL_LOADING_SPEED  # 현재 값 반환
function set_default_rotational_loading_speed!(val::Float64)   # 값 설정
    global ROTATIONAL_LOADING_SPEED = val
end

# 시뮬레이션 메인 루프 — 환경을 max_time_steps 만큼 반복 전진시키며 조립을 진행(! = env 수정).
# 함수 인자에서 `;` 뒤는 키워드 인자. max_time_steps=2000 처럼 이름 붙여 호출 가능.
function simulate!(
    env;
    max_time_steps=2000,                   # 최대 시간스텝 수(이 안에 못 끝내면 중단)
)
    @unpack sched, cache = env             # env 에서 sched, cache 필드를 지역변수로 꺼냄
    iters = 0                              # 실제로 돈 스텝 수 기록용
    for k in 1:max_time_steps              # 1 부터 max_time_steps 까지 반복(1:N = 1..N 범위)
        iters = k                          # 현재 스텝 번호 저장
        if mod(k, 100) == 0                # 100 스텝마다(mod = 나머지) 진행상황 로그
            @info " ******************* BEGINNING TIME STEP $k: $(length(cache.closed_set))/$(nv(sched)) nodes closed *******************"  # $(...) = 문자열에 값 끼워넣기
        end
        ood_inject_step!(env, k)   # physical OOD generation (no-op unless scheduled)  # 예약된 이상상황(OOD) 주입(없으면 아무 일 안 함)
        respec_step!(env)          # verified LLM re-spec BEFORE driving (match test timing)   # OOD 처리(인계)를 구동 전에
        step_environment!(env)             # 환경을 한 스텝 전진(로봇 이동 등)
        update_planning_cache!(env, 0.0)   # 끝난 노드 반영해 활성/완료 집합 갱신
        RESPEC_ENABLED[] && _enforce_serial_frontiers!(env)   # E1 (V3): spare 동시-active task 1개 강제(respec 시만)
        if project_complete(env)           # 프로젝트가 다 끝났으면
            println("PROJECT COMPLETE!")   # 완료 메시지 출력
            break                          # 루프 종료
        end
    end
    return project_complete(env), iters    # (완료여부, 돈 스텝수) 두 값을 튜플로 반환
end

"""
    update_position_from_sim!(agent)

Update agent position from RVO simulator
"""
# RVO 시뮬레이터가 계산한 새 위치를 가져와 에이전트의 장면트리 좌표에 반영(! = agent 수정).
function update_position_from_sim!(agent)
    pt = rvo_get_agent_position(agent)     # RVO 가 정한 (x,y) 위치를 가져옴
    @assert has_parent(agent, agent) "agent $(node_id(agent)) should be its own parent"  # @assert : 가정 점검(거짓이면 에러). 에이전트는 자기 자신이 부모여야 함(독립 객체)
    set_local_transform!(agent, CoordinateTransformations.Translation(pt[1], pt[2], 0.0))  # z=0 평면 위 (x,y) 로 위치 설정
    # isapprox : "거의 같은가" 비교(부동소수 오차 허용). `.-` 는 원소별 뺄셈(브로드캐스트). 위치가 어긋나면 경고.
    if !isapprox(norm(global_transform(agent).translation[1:2] .- pt), 0.0; rtol=1e-6, atol=1e-6)
        @warn "Agent $node_id(agent) should be at $pt but is at $(global_transform(agent).translation[1:2])"  # 위치 불일치 경고
    end
    return global_transform(agent)         # 갱신된 전역 변환(위치/자세) 반환
end

# Counters for the CBF-vs-teleport comparison. `enforce_restriction_zone_clearance!` repairs a
# zone violation by SNAPPING the agent's position to the boundary -- a state jump, not a control
# action. The call site discards the return value, so these numbers were previously unobservable.
#
# MEASURED (tools/cbf_sim_eval.jl): enabling the CBF filter does NOT drive these to zero. In the
# blocking-zone scenario both arms recorded 2 snaps at identical depth (0.5513189724) while the
# filter itself saw NO violation -- i.e. the snaps came from an INITIAL CONDITION (a zone created
# on top of already-parked robots), which no velocity filter can prevent. The two mechanisms
# cover different failure modes; do not describe one as replacing the other.
# (측정 결과) CBF 필터를 켜도 이 계수는 0 이 되지 않는다. 남은 침범은 로봇이 이동해 들어간 것이
#   아니라 "주차된 로봇 위에 구역이 생성된" 초기조건이라 속도 필터로는 원리적으로 막을 수 없다.
#   두 기구는 서로 다른 실패모드를 담당한다 — 한쪽이 다른 쪽을 대체한다고 쓰지 말 것.
const ZONE_SNAP_STATS = Ref(Dict{Symbol,Any}(:calls => 0, :agents_snapped => 0, :max_depth => 0.0))
zone_snap_stats() = ZONE_SNAP_STATS[]
reset_zone_snap_stats!() = (ZONE_SNAP_STATS[] = Dict{Symbol,Any}(
    :calls => 0, :agents_snapped => 0, :max_depth => 0.0); nothing)

"""Enforce active no-go zones as a hard post-RVO physical-disc invariant."""
function enforce_restriction_zone_clearance!(env::PlannerEnv; margin::Float64=1e-4)
    isempty(RESTRICTION_ZONES[]) && return 0
    ZONE_SNAP_STATS[][:calls] += 1
    corrected = 0
    for id in get_vtx_ids(rvo_global_id_map())
        agent = try get_node(env.scene_tree, id) catch; continue end
        pos = collect(Float64, rvo_get_agent_position(agent))
        ar = try
            Float64(get_radius(get_cached_geom(agent, HypersphereKey())))
        catch
            default_robot_radius()
        end
        changed = false
        for (_, zone) in active_restriction_zones()
            c = collect(Float64, get_center(zone)[1:2])
            safe_r = Float64(get_radius(zone)) + ar + margin
            dvec = pos .- c
            d = norm(dvec)
            if d < safe_r
                direction = d > 1e-9 ? dvec ./ d : [1.0, 0.0]
                depth = safe_r - d                     # 얼마나 깊이 침범했는지(=순간이동 거리)
                if depth > ZONE_SNAP_STATS[][:max_depth]
                    ZONE_SNAP_STATS[][:max_depth] = depth
                end
                pos = c .+ safe_r .* direction
                changed = true
            end
        end
        if changed
            rvo_set_agent_position!(agent, pos)
            update_position_from_sim!(agent)
            corrected += 1
            ZONE_SNAP_STATS[][:agents_snapped] += 1
        end
    end
    return corrected
end

# 현재 활성인 모든 에이전트의 위치를 {정점번호 => 위치} 딕셔너리로 모아 반환.
function get_active_pos(env::PlannerEnv)
    pos_dict = Dict{Int,Vector{Float64}}()  # 정점번호(Int) → 위치(실수벡터) 딕셔너리
    for v in env.cache.active_set           # 활성 노드들의 정점번호 v 마다
        n = get_node(env.sched, v)          # 노드 객체
        agent = entity(n)                   # 그 노드가 다루는 에이전트(로봇/유닛)
        pos = global_transform(agent).translation  # 에이전트의 전역 위치(이동 성분)
        pos_dict[v] = pos                   # 딕셔너리에 저장
    end
    return pos_dict
end

# Optional per-step hook (battery SoC accounting). Default `nothing` => no-op, so step_environment!
# is byte-for-byte unchanged in normal runs. navigator/battery.jl points this at
# `account_battery_step!` via install_battery_step_hook!. Mirrors RESPEC_HOLD / EDGE_COST_MULTIPLIER.
# const ... = Ref{Any}(nothing) : 배터리 SoC(잔량) 회계용 "훅"(가변 박스). 기본값 nothing = 아무 일도 안 함 → 일반 실행에선 step_environment! 가 그대로 동작. navigator/battery.jl 가 이 자리에 함수를 꽂으면 매 스텝 배터리 소모를 계산한다.
const BATTERY_STEP_HOOK = Ref{Any}(nothing)

# SoC->motion gate hook: navigator/battery.jl points this at `soc_speed_factor(node)`, a
# multiplier in [0,1] applied to a moving agent's max_speed. Returns 0.0 for a flat robot so
# it physically STALLS. nothing (default) -> no gating, so nominal runs are byte-for-byte the
# same. Same inert-by-default Ref pattern as BATTERY_STEP_HOOK.
# SoC→속도 제한 훅: battery.jl 가 꽂으면, 움직이는 에이전트의 max_speed 에 [0,1] 배율을 곱한다(방전된 로봇이면 0.0 → 그 자리에 물리적으로 멈춤). 기본 nothing = 제한 없음(일반 실행은 완전히 동일). BATTERY_STEP_HOOK 과 같은 "기본은 비활성" 패턴.
const SOC_SPEED_HOOK = Ref{Any}(nothing)

"""
    step_environment!(env::PlannerEnv, sim=rvo_global_sim())

Step forward one time step.
"""
# 환경을 한 시간스텝 전진. sim 기본값 = 전역 RVO 시뮬레이터(안 넘기면 자동 사용).
function step_environment!(env::PlannerEnv, sim=rvo_global_sim())

    prev_active_pos_dict = get_active_pos(env)  # 이번 스텝 시작 시점의 위치들을 저장(나중에 "안 움직였나" 판단용)
    for v in env.cache.active_set           # 활성 노드마다
        node = get_node(env.sched, v).node  # 노드 객체(.node 로 래퍼 안의 실제 노드)
        # SAFETY (respec OOD 1-1): skip an active RobotGo/TransportUnitGo whose agent has NO RVO
        # agent yet (not a vertex of the RVO id map). Driving it calls rvo_get_agent_idx ->
        # BoundsError[-1]. Covers: a robot CAPTURED into a transport unit, a robot not (yet)
        # re-registered as root, AND a just-FORMED transport unit whose TransportUnitGo activates
        # before update_rvo_sim! has added it (e.g. after reform_stuck_teams! snaps a team into
        # formation). Nominal agents are always in the map, so this never fires in normal runs; it
        # only degrades a hard crash to a graceful one-step wait. See respec/replace_robot.jl.
        # (요약) 아직 RVO 에이전트로 등록되지 않은 이동 노드는 건너뜀 — 그대로 구동하면 rvo_get_agent_idx 가 없는 인덱스를 찾아 BoundsError 로 크래시. 일반 실행에선 모두 등록돼 있어 안 걸리고, respec 상황의 하드 크래시를 "한 스텝 대기"로 완화하는 안전장치.
        if (node isa RobotGo || node isa TransportUnitGo) &&
           !has_vertex(rvo_global_id_map(), node_id(entity(node)))  # RVO id 맵에 이 에이전트가 없으면
            continue
        end
        cmd = get_cmd(node, env)            # 이 노드에 보낼 명령(목표 트위스트 등) 계산
        apply_cmd!(node, cmd, env) # update non-rvo nodes  # 명령 적용(RVO 가 안 다루는 노드들 위치 직접 갱신)
    end

    for (_, policy) in env.agent_policies   # 모든 에이전트 정책 순회. `_` 는 "쓰지 않는 변수"(키 무시).
        if !isnothing(policy.dispersion_policy)  # 분산(포텐셜장) 정책이 있으면
            update_parent_build_status!(env, policy.dispersion_policy.node)  # 그 노드의 상위단계 활성 여부 캐시 갱신
        end
    end

    # RESPEC fallback (safe line-stop): when engage_fallback! has set RESPEC_HOLD[],
    # zero every agent's preferred velocity right before the RVO step so this and
    # subsequent steps hold position. Inert (flag false) for all normal runs, and
    # RESPEC_HOLD is only resolved at call time so referencing it here -- before
    # respec/respec.jl is included -- is fine (same pattern as compile_proposal!).
    # RESPEC_HOLD[] : 참조(Ref)를 [] 로 역참조해 그 안의 값을 읽음(파이썬엔 직접 대응 없음 — 일종의 가변 박스).
    if RESPEC_HOLD[]                        # 안전정지(라인스톱) 플래그가 켜져 있으면
        for id in get_vtx_ids(ConstructionBots.rvo_global_id_map())  # 모든 RVO 에이전트 ID 에 대해
            rvo_set_agent_pref_velocity!(id, (0.0, 0.0))  # 선호속도를 0 으로(그 자리 정지)
        end
    end

    # Step RVO
    if !isnothing(sim)                      # RVO 시뮬레이터가 있으면
        sim.doStep()                        # RVO 한 스텝 실행(충돌회피 반영해 위치 계산). sim.doStep() 은 파이썬 객체 메서드 호출
    end
    for id in get_vtx_ids(ConstructionBots.rvo_global_id_map())  # 모든 RVO 에이전트 ID 에 대해
        if use_rvo()                        # RVO 사용 중이면
            tform = update_position_from_sim!(get_node(env.scene_tree, id))  # RVO 결과 위치를 장면트리에 반영
        end
    end

    # swap transport unit positions if necessary
    swap_first_paralyzed_transport_unit!(env, prev_active_pos_dict)  # 운반유닛 결성 중 끼어 못 움직이는 로봇이 있으면 자리 교체

    # RVO and deadlock swaps may perturb safe positions. Re-establish each
    # active no-go zone as a hard physical barrier after both operations.
    enforce_restriction_zone_clearance!(env)

    # Battery SoC accounting (inert unless installed): debit each robot's battery for this step,
    # using realized motion (prev->new positions). See navigator/battery.jl account_battery_step!.
    # (요약) 훅이 설치돼 있으면(nothing 아니면) 실제 이동량(직전→현재 위치)으로 이번 스텝 배터리 소모를 정산. `A === nothing || B` = A 가 nothing 이 아닐 때만 B 실행(단축평가 관용구).
    BATTERY_STEP_HOOK[] === nothing || BATTERY_STEP_HOOK[](env, prev_active_pos_dict)

    # Set velocities to zero for all agents. The pref velocities are only overwritten if
    # agent is "active" in the next time step
    for id in get_vtx_ids(ConstructionBots.rvo_global_id_map())  # 모든 에이전트의 선호속도를
        rvo_set_agent_pref_velocity!(id, (0.0, 0.0))  # 0 으로 초기화(다음 스텝에 활성이면 다시 덮어씀)
    end
    return env                              # 갱신된 환경 반환
end


# 활성 에이전트 구성이 바뀌었으면 RVO 시뮬레이터를 새로 만들고 에이전트들을 다시 등록(! = 전역 sim 수정).
function update_rvo_sim!(env::PlannerEnv)
    @unpack sched, scene_tree, cache = env  # 필드 꺼내기
    active_nodes = [get_node(sched, v) for v in cache.active_set]  # 활성 노드 목록(배열 내포 — 파이썬 리스트 컴프리헨션과 동일)
    if rvo_sim_needs_update(scene_tree)     # RVO 시뮬레이터를 갱신해야 하면
        @info "New RVO simulation"          # 로그
        rvo_set_new_sim!()                  # 새 RVO 시뮬레이터 생성
        rvo_add_agents!(scene_tree)         # 현재 에이전트들을 시뮬레이터에 추가
        for node in active_nodes            # 각 활성 노드에
            set_rvo_priority!(env, node)    # 우선순위(alpha) 다시 설정
        end
    end
end

# 활성 노드 중 목표를 달성한 것들을 "완료"로 옮기고, 그로 인해 새로 활성화되는 노드까지 반영(! = 캐시 수정).
function update_planning_cache!(env::PlannerEnv, time_stamp::Float64)
    @unpack sched, cache = env
    # Skip over nodes that are already planned or just don't need planning
    updated = false                         # 이번에 뭔가 바뀌었는지 표시
    newly_updated = Set{Int}()              # 이번에 새로 완료된 정점들의 집합
    while true                              # 더 이상 바뀌는 게 없을 때까지 반복(연쇄 완료 처리)
        done = true                         # 이번 한 바퀴에 변화 없었다고 일단 가정
        for v in collect(cache.active_set)  # collect : 집합을 배열로 복사(순회 중 원본이 바뀌어도 안전하게)
            # println("Node v: $v")
            node = get_node(sched, v)        # 노드 객체
            # println("\t node_type: $(typeof(node))")
            if is_goal(node, env)            # 이 노드가 목표를 달성했으면
                close_node!(node, env)       # 노드를 완료 처리(필요한 결합/등록 등 수행)
                @info "node $(summary(node_id(node))) finished."  # 완료 로그
                update_planning_cache!(nothing, sched, cache, v, time_stamp)  # 저수준 캐시 갱신 함수 호출(활성→완료 이동)
                # @info "active nodes $([get_vtx_id(sched,v) for v in cache.active_set])"
                @assert !(v in cache.active_set) && (v in cache.closed_set)  # 활성에서 빠지고 완료에 들어갔는지 점검
                push!(newly_updated, v)      # 새로 완료된 목록에 추가(push! = 끝에 추가)
                done = false                 # 변화 있었음 → 한 바퀴 더 돌아야 함
                updated = true               # 전체적으로 갱신 있었음 표시
            end
        end
        if done                             # 한 바퀴 동안 아무 변화 없었으면
            break                           # 반복 종료
        end
    end
    if updated                              # 무언가 완료된 게 있었으면
        process_schedule!(sched)            # 스케줄 후처리(새로 활성화 가능한 노드 열기 등)
        preprocess_env!(env)                # 환경 정리(운반유닛 결합/해체 등)
        update_rvo_sim!(env)                # 에이전트 구성 바뀌었으면 RVO 재구성
    end
    newly_updated                           # 새로 완료된 정점 집합 반환
end

"""
    close_node!(node,env)

Ensure that a node is completed
"""
# close_node! : 노드 종류별로 다른 "완료 처리"(다중 디스패치). 래퍼는 안쪽 실제 노드로 위임.
close_node!(node::ScheduleNode, env::PlannerEnv) = close_node!(node.node, env)
# 일반 ConstructionPredicate 는 따로 할 일 없음 → nothing 반환.
close_node!(::ConstructionPredicate, env::PlannerEnv) = nothing #close_node!(n,env)
# 조립단계 "열기" 노드: 그 단계 ID 를 활성 조립단계 집합에 추가(= 단계 시작).
close_node!(n::OpenBuildStep, env::PlannerEnv) = push!(env.active_build_steps, node_id(n))
# 조립단계 "닫기" 노드: 그 단계에서 추가될 부품들을 조립체에 실제로 결합(부모-자식 엣지 연결).
function close_node!(node::CloseBuildStep, env::PlannerEnv)
    @unpack sched, scene_tree = env
    assembly = get_assembly(node)           # 이 단계가 속한 조립체
    @info "Closing BuildingStep $(node_id(node))"  # 로그
    delete!(env.active_build_steps, node_id(OpenBuildStep(node)))  # 대응하는 "열기" 단계를 활성집합에서 제거(단계 종료)
    for (id, tform) in assembly_components(node)  # 이 단계에서 붙일 (구성요소 id, 변환) 들에 대해
        if !has_edge(scene_tree, assembly, id)    # 아직 조립체에 안 붙어 있으면
            if !capture_child!(scene_tree, assembly, id)  # 자식으로 "포획"(결합) 시도, 실패하면
                # A respec RECOVERY (e.g. a restage that translated this assembly AFTER this
                # part was already delivered — restage_assembly! explicitly does not relocate
                # already-delivered parts) can leave a delivered part desynced from its slot,
                # so capture fails and the @assert below would CRASH the whole sim. Under
                # respec, snap the component to its prescribed slot and retry — the same
                # orchestrator geometric-surgery pattern reform uses — so recovery-induced
                # drift degrades to a completed placement, never a crash. Gated on
                # RESPEC_ENABLED so NOMINAL runs keep the original assert (bug-catching intact).
                # (요약) respec 복구(예: restage 로 조립체를 옮겼는데 이미 배달된 부품은 안 따라옴)로 부품이 제 슬롯에서 어긋나 포획이 실패할 수 있음. 이때 부품을 지정 슬롯으로 "스냅"시킨 뒤 다시 포획 → 크래시 대신 배치 완료로 완화. RESPEC_ENABLED 로 게이트해 일반 실행은 원래 @assert(버그 탐지) 유지.
                if RESPEC_ENABLED[]
                    child = get_node(scene_tree, id)
                    set_desired_global_transform!(child, global_transform(assembly) ∘ child_transform(assembly, id))  # 부품을 조립체 기준 지정 슬롯 위치로 강제 이동
                    capture_child!(scene_tree, assembly, id)  # 다시 포획 시도
                end
                has_edge(scene_tree, assembly, id) ||
                    @warn "Assembly $(string(node_id(assembly))) is unable to capture child $(string(id)). Current relative transform is $(relative_transform(assembly,get_node(scene_tree,id))), but should be $(child_transform(assembly,id))" assembly id  # 결합 실패 경고(현재/기대 상대변환 출력)
            end
        end
        @assert has_edge(scene_tree, assembly, id)  # 최종적으로 결합됐는지 점검
    end
end

"""
ensure that all transport units (if active) are formed or (conversely)
disbanded
"""
# 활성 운반유닛은 로봇들을 묶어두고, 활성 로봇이동 노드는 부모가 없도록(독립) 보장하는 정리 작업.
function preprocess_env!(env::PlannerEnv)
    @unpack sched, scene_tree, cache = env
    for v in cache.active_set               # 활성 노드마다
        node = get_node(sched, v)
        if matches_template(FormTransportUnit, node)  # 운반유닛 결성 노드면
            if !capture_robots!(entity(node), scene_tree)  # 팀 로봇들을 유닛 아래로 포획, 실패 시
                @warn "Unable to capture robots: $(node_id(node))"  # 경고
            end
        elseif matches_template(RobotGo, node)  # 로봇 이동 노드면
            # ensure that node does not still have a parent. SAFETY (respec OOD 1-1): a robot
            # captured into a transport unit while an individual RobotGo for it is still active
            # (multi-team double-booking from a single spare hand-off) would assert-crash here;
            # skip instead so the sim holds gracefully rather than aborting. Nominal runs never
            # hit this (an active RobotGo's robot is always its own root). See replace_robot.jl.
            # (요약) 활성 RobotGo 의 로봇은 원래 자기 자신이 루트(부모)여야 하지만, respec 인계(한 스페어의 중복 배정)로 로봇이 운반유닛에 포획된 채 개별 RobotGo 도 아직 활성일 수 있음. 그럼 아래 단정문에서 크래시하므로, 그런 경우엔 건너뛰어 중단 대신 정상 진행.
            has_parent(entity(node), entity(node)) || continue
        end
    end
end

# 프로젝트가 완료됐는지: 모든 "ProjectComplete" 노드가 완료 집합에 들어있으면 true.
function project_complete(env::PlannerEnv)
    @unpack sched, cache = env
    for n in get_nodes(sched)                # 스케줄의 모든 노드 검사
        if matches_template(ProjectComplete, n)  # 완료 표시 노드라면
            if !(get_vtx(sched, n) in cache.closed_set)  # 아직 완료되지 않았으면
                return false                 # 프로젝트 미완료
            end
        end
    end
    return true                              # 전부 완료 → 프로젝트 완료
end

# is_goal : 노드가 자신의 목표에 도달했는지 종류별로 판정(다중 디스패치). 래퍼는 안쪽 노드로 위임.
is_goal(n::ScheduleNode, env::PlannerEnv) = is_goal(n.node, env)
# 일반 술어 노드는 항상 목표 달성으로 간주(즉시 완료 가능).
is_goal(node::ConstructionPredicate, env::PlannerEnv) = true
# EntityGo(객체 이동): 현재 위치가 목표 위치의 포획거리 안에 들어왔는지로 판정.
function is_goal(node::EntityGo, env::PlannerEnv)
    agent = entity(node)                    # 이동 대상
    state = global_transform(agent)         # 현재 자세
    goal = global_transform(goal_config(node))  # 목표 자세
    return is_within_capture_distance(state, goal)  # 충분히 가까우면 도달
end
"""
    is_goal(node::RobotGo,sched,scene_tree)

If next node is FormTransportUnit, ensure that everybody else is in position.
"""
# RobotGo/TransportUnitGo: 위치 도달뿐 아니라 "다음 작업이 시작될 준비"까지 됐는지 함께 확인.
function is_goal(node::Union{RobotGo,TransportUnitGo}, env::PlannerEnv)
    @unpack sched, scene_tree, cache = env
    agent = entity(node)
    state = global_transform(agent)         # 현재 자세
    goal = global_transform(goal_config(node))  # 목표 자세

    if !is_within_capture_distance(state, goal)  # 아직 목표 위치에 못 왔으면
        return false                         # 목표 미달
    end
    if is_terminal_node(sched, node)         # 뒤에 아무 작업도 없는 말단 노드면
        # Does this need to be modified?
        # return true
        return false                         # (여기선) 완료로 안 봄 — 계속 대기
    end
    next_node = get_node(sched, outneighbors(sched, node)[1])  # 다음(후행) 노드. [1] 은 첫 원소(Julia 인덱스는 1부터)
    # Cannot reach goal until next_node is ready to become active
    # Should take care of requiring the parent build step to be active
    for v in inneighbors(sched, next_node)  # 다음 노드의 모든 선행 노드들이
        if !((v in cache.active_set) || (v in cache.closed_set))  # 활성도 완료도 아니면(아직 준비 안 됨)
            return false                     # 목표 미달(다음 작업 준비될 때까지 대기)
        end
    end
    # Cannot reach goal until all robots are in place
    if matches_template(FormTransportUnit, next_node)  # 다음이 운반유닛 결성이면
        tu = entity(next_node)               # 그 운반유닛
        for (id, tform) in robot_team(tu)    # 팀의 모든 로봇(id, 위치)에 대해
            robot = get_node(scene_tree, id)
            if !is_within_capture_distance(tu, robot)  # 한 로봇이라도 제 위치에 없으면
                return false                 # 아직 결성 준비 안 됨 → 대기
            end
        end
    end
    return true                              # 모든 조건 충족 → 목표 도달
end
# FormTransportUnit/DepositCargo: 다루는 화물이 목표 자세에 도달했는지로 판정.
function is_goal(node::Union{FormTransportUnit,DepositCargo}, env::PlannerEnv)
    agent = entity(node)
    cargo = get_node(env.scene_tree, cargo_id(agent))  # 이 작업이 다루는 화물
    state = global_transform(cargo)          # 화물의 현재 자세
    goal = global_transform(cargo_goal_config(node))  # 화물의 목표 자세
    return is_within_capture_distance(state, goal)
end
# LiftIntoPlace: 부품(화물)을 최종 위치에 올려놓는 작업 — 화물이 목표에 도달했는지로 판정.
function is_goal(node::LiftIntoPlace, env::PlannerEnv)
    cargo = entity(node)
    state = global_transform(cargo)
    goal = global_transform(goal_config(node))
    return is_within_capture_distance(state, goal)
end

# 운반유닛 결성을 기다리며 원 안에 들어와 있지만 막혀서 못 움직이는 로봇을, 더 가까운 다른 로봇과 자리 교체해 교착을 푼다.
function swap_first_paralyzed_transport_unit!(env::PlannerEnv, pos_before_step::Dict{Int,Vector{Float64}})
    @unpack sched, scene_tree, cache, dt = env
    for v in cache.active_set               # 활성 노드마다
        n = get_node(sched, v)
        if matches_template(RobotGo, n) && outdegree(sched, n) >= 1  # 로봇 이동 노드이고 다음 작업이 있으면
            next_node = get_node(sched, first(outneighbors(sched, n)))  # 첫 후행 노드
            while outdegree(sched, next_node) >= 1 && matches_template(RobotGo, next_node)  # 연속된 RobotGo 들을 건너뛰며
                next_node = get_node(sched, first(outneighbors(sched, next_node)))  # 다음 노드로 계속 전진
            end
            if matches_template(FormTransportUnit, next_node)  # 최종적으로 도달한 게 운반유닛 결성이면
                # is robot stuck?
                agent = entity(n)            # 이 로봇
                # SAFETY (respec OOD 1-1): if this robot has no individual RVO agent (not in the RVO
                # id map — e.g. captured into ANOTHER transport unit, or not yet re-registered), the
                # rvo_get_agent_pref_velocity below would crash (BoundsError[-1]). Skip it. Nominal
                # runs never hit this; only the multi-team double-booking from a single spare hand-off
                # (replace_robot!) can. See respec/replace_robot.jl.
                # (요약) 이 로봇에게 개별 RVO 에이전트가 없으면(id 맵에 없음 — 예: 다른 운반유닛에 포획됨/아직 재등록 전) 아래 rvo_get_agent_pref_velocity 가 크래시하므로 건너뜀. 일반 실행에선 안 걸림.
                has_vertex(rvo_global_id_map(), node_id(agent)) || continue
                transport_unit = entity(next_node)  # 결성될 운반유닛
                if has_parent(agent, transport_unit) || is_within_capture_distance(transport_unit, agent)  # 이미 묶였거나 제 위치면
                    continue                 # 교체 불필요 → 건너뜀
                end
                circ = get_cached_geom(transport_unit, HypersphereKey())  # 운반유닛의 외접원(영역)
                ctr = get_center(circ)[1:2]  # 원 중심 (x,y) (3D 중 앞 2개)
                rad = get_radius(circ)       # 원 반지름
                vel = rvo_get_agent_pref_velocity(agent)  # 로봇의 현재 선호속도
                pos = global_transform(agent).translation[1:2]  # 로봇 현재 (x,y)
                agent_radius = get_radius(get_cached_geom(agent, HypersphereKey()))  # 로봇 반지름
                if norm(pos .- ctr) < agent_radius + rad # within circle  # 로봇이 유닛 원 안에 있으면
                    swap = false             # 교체 여부 플래그
                    if norm([vel...]) < 1e-6 # stuck  # 선호속도가 거의 0(완전히 멈춤)이면. [vel...] 는 튜플을 배열로 펼침
                        swap = true          # 교체 대상
                    elseif haskey(pos_before_step, v)  # 직전 위치 기록이 있으면
                        pos_bs = pos_before_step[v]    # 스텝 시작 위치
                        vel_est = norm((pos[1:2] - pos_bs[1:2])) / dt  # 실제 이동량으로 추정한 속도
                        if vel_est < 1e-2    # 거의 안 움직였으면
                            swap = true      # 교착으로 보고 교체
                        end
                    end
                    if swap                  # 교체하기로 했으면
                        swap_carrying_positions!(next_node.node, n.node, env)  # 더 적합한 다른 로봇과 위치 교환
                    end
                end
            end
        end
    end
end

"""
    find_best_swap_candidate(node::FormTransportUnit,agent_node::RobotGo,env)

For agent
"""
# 막힌 로봇 대신 그 목표 자리에 들어갈, 가장 적합한(가깝고 목표에 더 가까운) 다른 팀 로봇을 찾는다.
function find_best_swap_candidate(node::FormTransportUnit, agent_node::RobotGo, env::PlannerEnv)
    @unpack sched, scene_tree = env
    transport_unit = entity(node)           # 운반유닛
    agent = entity(agent_node)              # 막힌 로봇
    goal = global_transform(goal_config(agent_node))  # 막힌 로봇이 가야 할 목표 자세
    state = global_transform(agent)         # 막힌 로봇 현재 자세
    if is_within_capture_distance(transport_unit, agent)  # 이미 제 위치면
        # no need to swap
        return nothing                      # 교체 불필요
    end
    # find best swap
    closest_id = nothing                    # 가장 가까운 후보 ID(아직 없음)
    dist = Inf                              # 지금까지 찾은 최소 거리(무한대로 시작)
    agent_dist = norm(goal.translation .- state.translation)  # 막힌 로봇과 목표 사이 거리
    for (id, tform) in robot_team(transport_unit)  # 팀의 모든 로봇에 대해
        if !(id == node_id(agent))          # 자기 자신은 제외
            other_agent = get_node(scene_tree, id)
            other_state = global_transform(other_agent)  # 다른 로봇 현재 자세
            if is_within_capture_distance(transport_unit, other_agent)  # 그 로봇이 이미 제 위치에 있으면(여유 있음)
                d1 = norm(goal.translation .- other_state.translation)  # 그 로봇과 (막힌 로봇의) 목표 사이 거리
                if d1 > agent_dist          # 그 로봇이 목표에서 오히려 더 멀면
                    continue                # 후보 제외
                end
                d = norm(state.translation .- other_state.translation)  # 막힌 로봇과 그 로봇 사이 거리
                if d < dist                 # 더 가까우면
                    dist = d                # 최소 거리 갱신
                    closest_id = id         # 후보 갱신
                end
            end
        end
    end
    return closest_id                       # 최적 교체 후보 ID(없으면 nothing) 반환
end

"""
    swap_carrying_positions!(node::FormTransportUnit,agent::RobotNode,env)

To be executed if `agent` is within the hypersphere but stuck.
"""
# 막힌 로봇과 후보 로봇의 위치를 장면트리와 RVO 시뮬레이터 양쪽에서 맞바꾼다(! = 상태 수정).
function swap_carrying_positions!(node::FormTransportUnit, agent_node::RobotGo, env::PlannerEnv)
    @unpack sched, scene_tree = env
    other_id = find_best_swap_candidate(node, agent_node, env)  # 교체할 상대 찾기
    if !(other_id === nothing)              # 상대가 있으면
        @assert matches_template(RobotID, other_id)  # 그게 로봇 ID 가 맞는지 점검
        agent = entity(agent_node)          # 막힌 로봇
        other_agent = get_node(scene_tree, other_id)  # 상대 로봇
        swap_positions!(agent, other_agent) # 장면트리상 위치 교환
        # swap positions in rvo_sim as well
        tmp = rvo_get_agent_position(agent) # RVO 위치도 교환 — 임시변수에 보관 후
        rvo_set_agent_position!(agent, rvo_get_agent_position(other_agent))  # 막힌 로봇 ← 상대 위치
        rvo_set_agent_position!(other_agent, tmp)  # 상대 ← 보관해둔 막힌 로봇 위치
    end
    return agent_node                       # 원래 로봇 노드 반환
end

"""
    swap_positions!(agent1,agent2)

Swap positions of two robots in simulation.
"""
# 두 로봇의 전역 자세(목표 위치)를 서로 맞바꾼다.
function swap_positions!(agent1, agent2)
    @info "Swapping agent $(summary(node_id(agent1))) with $(summary(node_id(agent2)))"  # 교체 로그
    tmp = global_transform(agent1)          # agent1 자세를 임시 보관
    set_desired_global_transform!(agent1, global_transform(agent2))  # agent1 ← agent2 자세
    set_desired_global_transform!(agent2, tmp)  # agent2 ← 보관한 agent1 자세
    return agent1, agent2
end

# 함수 본문 없이 이름만 선언(전방 선언). 아래 include 된 파일에서 실제 메서드들이 채워짐(다중 디스패치).
function query_policy_for_goal! end

# include : 다른 파일 코드를 여기에 그대로 붙여넣음(이 파일이 쓰는 이동정책 구현체들).
include("tangent_bug.jl")        # TangentBug 정책(장애물 가장자리를 따라 우회)
include("potential_fields.jl")   # 포텐셜장 정책(서로 밀어내며 분산)

"""
    circle_avoidance_policy()

Returns a 2D goal vector that will take the robot outside of circular boundary
regions while pursuing its main goal
"""
# 원형 금지구역(적치 원 등)을 피해 가면서 본래 목표(nominal_goal)로 향하는 2D 목표점을 계산한다.
# `;` 뒤는 키워드 인자. planning_radius=계획 반경, detour_horizon=우회 시작 거리, buffer=추가 여유.
function circle_avoidance_policy(circles, agent_radius, pos, nominal_goal;
    planning_radius::Float64=agent_radius * 2,       # 한 번에 내다보는 거리(기본=로봇 반경×2)
    detour_horizon::Float64=2 * planning_radius,     # 이 거리보다 가까워야 우회 시작
    buffer=staging_buffer_radius(),                  # 원에 더할 여유반경
)
    dmin = Inf                              # 지금까지 본 원 중 가장 가까운 침투거리(무한대로 시작)
    id = nothing                            # 가장 방해되는 원의 ID
    circ = nothing                          # 가장 방해되는 (부풀린) 원
    # Get the first circle to be intersected
    # for (i,c) in enumerate(circles)
    for (circ_id, c) in circles             # 모든 원 (ID, 원) 에 대해
        x = get_center(c)                   # 원 중심
        r = get_radius(c)                   # 원 반지름
        bloated_circle = LazySets.(x, r + agent_radius + buffer)  # 로봇 반경+여유만큼 부풀린 원(로봇을 점으로 취급하기 위해)
        if circle_intersects_line(bloated_circle, pos, nominal_goal)  # 현재→목표 직선이 이 원을 통과하면(방해됨)
            d = norm(x - pos) - (r + agent_radius) #- norm(x - pos) # penetration  # 원 표면까지 거리(음수면 이미 원 안)
            if d < dmin                     # 더 가까운(더 위험한) 원이면
                # penetration < 0 => pos is in circle
                dmin = d                    # 최소 침투거리 갱신
                # idx = i
                id = circ_id                # 방해 원 ID 갱신
                circ = bloated_circle       # 방해 원 갱신
            end
        end
    end
    goal = nominal_goal                     # 일단 목표를 본래 목표로 둠
    if circ === nothing                     # 가로막는 원이 없으면
        # nothing in the way
        return nominal_goal                 # 본래 목표 그대로 반환
    end
    c = get_center(circ)                    # 방해 원의 중심
    r = get_radius(circ)                     # 방해 원의 반지름
    if norm(nominal_goal - c) < r # nominal_goal is in circle  # 목표 자체가 원 안에 있으면(못 들어감)
        # wait outside
        # how to scale buffer here?
        if norm(nominal_goal - c) > 1e-3     # 목표가 중심과 충분히 떨어져 있으면
            goal = c + normalize(nominal_goal - c) * r  # 목표 방향으로 원 가장자리에서 대기
        else
            goal = c + normalize(pos - c) * r  # 목표가 중심에 너무 가까우면 내 쪽 가장자리에서 대기
        end
    elseif dmin >= 0                         # 아직 원 밖이지만(침투 없음) 충돌 경로에 있으면
        # not currently in a circle, but on a course for intersection
        if norm(nominal_goal - pos) < norm(nominal_goal - c)  # 내가 목표에 원보다 더 가까우면(이미 지나침)
            # Just keep going toward goal (on the clear side)--this statement should never be reached
            goal = nominal_goal              # 그냥 목표로 직진
        elseif dmin < detour_horizon         # 원이 우회 시작 거리보다 가까우면
            # detour to "skim" the circle
            if dmin < 1e-3                   # 사실상 원에 닿아 있으면
                dvec = pos - c               # 중심→나 방향 벡터
                goal = pos .+ [-dvec[2], dvec[1]]  # 그 벡터에 수직인 방향(원을 따라 옆으로)으로 살짝 비킴
            else
                # Pick a tangent point to shoot for
                pts = nearest_points_between_circles(  # 원에 접하는 두 접점 계산
                    pos[1:2], c[1:2], norm(pos - c), r
                )
                # 두 접점 중 본래 목표에 더 가까운 쪽을 선택. sort(...,by=함수) 는 함수값 기준 정렬, [1] 은 최솟값.
                goal = sort([pts...], by=p -> norm(nominal_goal - [p...]))[1]
            end
        else
            goal = nominal_goal              # 아직 충분히 멀면 목표로 직진
        end
    else                                     # dmin < 0 → 이미 원 안에 들어와 있으면
        # get goal points on the edge of the circle
        pts = nearest_points_between_circles(  # 빠져나갈 원 가장자리 점들 계산
            pos[1:2], get_center(circ)[1:2], planning_radius, get_radius(circ),
        )
        if pts === nothing                   # 계산 실패면
            goal = nominal_goal              # 목표로 직진
        else
            # select closest point to goal
            goal = sort([pts...], by=p -> norm(nominal_goal - [p...]))[1]  # 목표에 가장 가까운 탈출점 선택
        end
    end
    nominal_pt = pos + normalize(nominal_goal - pos) * min(planning_radius, norm(nominal_goal - pos))  # 본래 목표 방향으로 한 걸음(계획반경 이내) 간 지점
    f = g -> circle_intersection_with_line(circ, pos, g)  # 익명함수: 어떤 목표점 g 까지 직선이 원을 얼마나 침범하는지 측정
    # if norm(nominal_pt .- c) > norm(goal .- c)
    if f(nominal_pt) > f(goal)               # 직진 경로가 우회 경로보다 더 위험하면
        return nominal_goal                  # (역설적이지만 이 조건에선) 본래 목표 반환
    else
        return goal                          # 아니면 계산한 우회 목표 반환
    end
end

# 원(Ball2)의 반지름을 r 만큼 키운(부풀린) 새 원을 만든다. 중심은 그대로.
inflate_circle(circ::LazySets.Ball2, r::Float64) = LazySets.Ball2(get_center(circ), get_radius(circ) + r)
# inflate_circle(circ::GeometryBasics.HyperSphere,r::Float64) = GeometryBasics.HyperSphere(get_center(circ),get_radius(circ)+r)  # (다른 원 타입용 옛 버전 — 주석처리)

# 현재 활성인 조립단계들의 적치 원 목록(피해야 할 장애물)을 (ID => 2D원) 형태로 만들어 반환.
function active_staging_circles(env, exclude_ids=Set())
    buffer = env.staging_buffers # to increase radius of staging circles when necessary  # 막혔을 때 키운 여유반경 표
    # (... for ... if ...) : 제너레이터(지연 평가, 파이썬 제너레이터식과 동일). 제외 대상이 아닌 활성단계 노드들만 추림.
    node_iter = (get_node(env.sched, id).node for id in env.active_build_steps if !(id in exclude_ids))
    # 각 단계의 적치 원을 여유반경만큼 부풀린 뒤 2D 로 투영. `n => 값` 은 키=>값 쌍. get(buffer,키,0.0) 은 없으면 0.0.
    circle_iter = (node_id(n) => project_to_2d(
        inflate_circle(get_cached_geom(n.staging_circle), get(buffer, node_id(n), 0.0)
        )) for n in node_iter)
    # OOD 1-2: append navigation no-go zones (restriction districts) as static
    # obstacles, in the SAME (id => 2D Ball2) shape so TangentBug avoids them
    # identically. Always active (independent of active_build_steps / exclude_ids).
    # The flatten stays lazy and re-iterable (get_twist_cmd consumes it twice).
    # Iterators.flatten : 여러 제너레이터를 하나로 이어붙임(지연 평가 유지). 적치 원 + 통행금지 구역을 합쳐 반환.
    return Iterators.flatten((circle_iter, active_restriction_zones()))
end

# 로봇이 적치 원 근처에서 거의 못 움직이면, 그 원들의 여유반경을 조금씩 키워(더 크게 우회하도록) 교착을 완화(! = 버퍼 수정).
function inflate_staging_circle_buffers!(env, policy, agent, circle_ids;
    threshold=0.2,                          # "원하는 이동량 대비 실제 이동량"이 이 비율보다 작으면 막힌 것으로 봄
    delta=0.1 * default_robot_radius(),     # 한 번에 키우는 반경(로봇 반경의 10%)
    delta_max=4 * default_robot_radius(),   # 여유반경 최대 한도(로봇 반경의 4배)
)
    @unpack staging_buffers, dt = env
    # desird change in position
    desired_dx = dt * project_to_2d(policy.cmd.vel)  # 명령 속도로 이번 스텝에 원했던 이동량(2D)
    prev_pos = project_to_2d(policy.config.translation)  # 직전 위치
    pos = project_to_2d(global_transform(agent).translation)  # 현재 위치
    # true change in position
    dx = pos - prev_pos                     # 실제 이동량
    if norm(dx) < threshold * norm(desired_dx)  # 실제로 거의 안 움직였으면(막힘)
        # increase buffer
        for id in circle_ids                # 관련된 각 원에 대해
            buffer = get(staging_buffers, id, 0.0) + delta  # 현재 여유반경 + delta
            if buffer < delta_max - delta   # 아직 한도에 여유가 있으면
                buffer = min(buffer, delta_max)  # 한도를 넘지 않게 자름
                staging_buffers[id] = buffer     # 여유반경 갱신
                @info "increasing radius buffer of $(summary(id)) to $(buffer) because $(summary(node_id(agent))) is stuck"  # 로그
            end
        end
    end
end

# @with_kw mutable struct : 키워드 생성자 자동생성 + "mutable"(필드 값을 나중에 바꿀 수 있는 가변 구조체).
# 일반 struct 는 만든 뒤 필드 변경 불가지만, mutable 은 가능(파이썬 일반 객체처럼).
# 한 에이전트의 속도 제어기 — 두 가지 정책(주 이동/분산)을 담음.
@with_kw mutable struct VelocityController
    nominal_policy = nothing # TangentBugPolicy   # 주 이동 정책(TangentBug; 장애물 우회)
    dispersion_policy = nothing # potential field  # 분산 정책(포텐셜장; 서로 밀어냄)
    # RVO policy
end

"""
    active_build_step_countdown(step,env)

Measures how many build steps a step is away from becoming active.
"""
# 어떤 조립단계가 "활성"이 되기까지 앞으로 몇 단계 남았는지 센다(0 이면 이미 활성).
function active_build_step_countdown(step, env::PlannerEnv)
    @unpack sched = env
    open_step = get_node(sched, OpenBuildStep(step)).node  # 이 단계의 "열기" 노드
    k = 0                                   # 남은 단계 수 카운터
    while !(node_id(open_step) in env.active_build_steps)  # 이 단계가 아직 활성이 아닌 동안
        k += 1                              # 한 단계 더 거슬러 올라감
        close_step = get_node(sched, first(inneighbors(sched, open_step))).node  # 바로 앞 선행 노드
        if matches_template(CloseBuildStep, close_step)  # 그게 "닫기" 단계면(앞 단계가 끝나야 이 단계 시작)
            open_step = get_node(sched, OpenBuildStep(close_step)).node  # 그 앞 단계의 "열기"로 이동해 계속
        else
            break                           # 더 거슬러 올라갈 단계가 없으면 종료
        end
    end
    return k                                # 남은 단계 수 반환
end

"""
    get_twist_cmd(node,env)

Query the agent's policy to get the desired twist
"""
# 한 에이전트의 이동 정책(TangentBug + 포텐셜장)을 질의해 이번 스텝에 보낼 목표 트위스트(속도)를 계산.
function get_twist_cmd(node, env::PlannerEnv)
    @unpack sched, scene_tree, agent_policies, cache, dt = env
    agent = entity(node)                    # 이 노드의 에이전트
    goal = global_transform(goal_config(node))  # 최종 목표 자세
    mode = :not_set                         # 정책 상태(심볼; 나중에 set_policy_mode! 가 채움)
    ############ TangentBugPolicy #############
    policy = agent_policies[node_id(agent)].nominal_policy  # 이 에이전트의 주 이동(TangentBug) 정책
    if !(policy === nothing)                # 주 정책이 있으면
        pos = project_to_2d(global_transform(agent).translation)  # 현재 위치를 2D 로 투영
        excluded_ids = Set{AbstractID}()    # 장애물 계산에서 제외할 원들의 ID 집합

        #? Can we use the cached version here?
        if parent_build_step_is_active(node, env) && cargo_ready_for_pickup(node, env)  # 상위단계 활성 + 화물 준비됐으면
            parent_build_step = get_parent_build_step(sched, node)  # 자기 목적지인 단계의 원은
            push!(excluded_ids, node_id(parent_build_step))  # 장애물에서 제외(자기 목적지를 피하지 않도록)
        end
        # get circle obstacles, potentially inflated
        circles = active_staging_circles(env, excluded_ids)  # 피해야 할 원 장애물 목록

        # update policy and get goal
        policy.config = global_transform(agent)  # 정책에 현재 자세 갱신

        # TangentBug Policy
        parent_step_is_active = parent_build_step_is_active(node, env)  # 상위단계 활성 여부
        goal_pt = query_policy_for_goal!(policy, circles, pos, project_to_2d(goal.translation), parent_step_is_active)  # 정책이 추천하는 다음 목표점(2D)
        # 목표점(이동) ∘ 원래 목표 회전 을 합쳐 3D 목표 자세 구성. `goal_pt...` 는 (x,y)를 인자로 펼침, 0.0 은 z.
        new_goal = CoordinateTransformations.Translation(goal_pt..., 0.0) ∘ CoordinateTransformations.LinearMap(goal.linear)

        # 가장 방해되는 원을 찾음. `_, circ, _` 는 3개 반환값 중 가운데만 받고 나머지는 버림(언패킹).
        _, circ, _ = get_closest_interfering_circle(policy, circles, pos, project_to_2d(goal.translation); return_w_no_buffer=true)
        mode = set_policy_mode!(policy, circ, pos, project_to_2d(goal.translation), parent_step_is_active)  # 정책 상태(직진/원 진입/이탈 등) 결정

        twist = compute_twist_from_goal(agent, new_goal, dt) # nominal twist  # 그 목표로 향하는 기본 트위스트 계산
    else
        twist = compute_twist_from_goal(agent, goal, dt)  # 정책이 없으면 그냥 최종 목표로 직접 향함
    end
    if use_rvo()                            # RVO 충돌회피를 쓰는 경우에만 아래 보정 적용
        ############ Hacky Traffic Thinning #############
        # set nominal velocity to zero if close to goal (HACK)
        parent_step = get_parent_build_step(sched, node)  # 상위 조립단계
        if !(parent_step === nothing)
            countdown = active_build_step_countdown(parent_step.node, env)  # 그 단계가 활성까지 몇 단계 남았나
            dist_to_goal = norm(goal.translation .- global_transform(agent).translation)  # 목표까지 거리

            unit_radius = get_base_geom(entity(node), HypersphereKey()).radius  # 이 에이전트의 반지름
            if (mode != :EXIT_CIRCLE) && (dist_to_goal < 15 * unit_radius)  # 원 이탈 중이 아니고 목표에 꽤 가까우면
                # So the agent doesn't crowd its destination
                if matches_template(TransportUnitGo, node) && countdown >= 1  # 운반유닛이고 아직 1단계 이상 남았으면
                    twist = Twist(0.0 * twist.vel, twist.ω)  # 직선속도 0(목적지 주변 혼잡 방지), 회전은 유지
                elseif matches_template(RobotGo, node) && countdown >= 3  # 로봇이고 3단계 이상 남았으면
                    twist = Twist(0.0 * twist.vel, twist.ω)  # 마찬가지로 정지(미리 와서 붐비지 않게)
                end
            end
        end
        ############ Potential Field Policy #############
        policy = agent_policies[node_id(agent)].dispersion_policy  # 분산(포텐셜장) 정책
        # For RobotGo node, ensure that parent assembly is "pickup-able"
        ready_for_pickup = cargo_ready_for_pickup(node, env)  # 화물이 집을 준비 됐나
        #? Can we use the cached version here?
        build_step_active = parent_build_step_is_active(node, env)  # 상위단계 활성인가
        if !(policy === nothing)            # 분산 정책이 있으면
            update_dist_to_nearest_active_agent!(policy, env)  # 가장 가까운 활성 에이전트까지 거리 갱신
            update_buffer_radius!(policy, node, build_step_active, ready_for_pickup)  # 회피 버퍼반경 갱신
            if !(build_step_active && ready_for_pickup)  # 아직 작업할 때가 아니면(대기 중이면 → 흩어지기)
                # update policy
                policy.node = node          # 정책에 현재 노드 설정
                # compute target position
                nominal_twist = twist       # 위에서 구한 기본 트위스트
                pos = project_to_2d(global_transform(agent).translation)  # 현재 위치(2D)
                va = nominal_twist.vel[1:2] # 기본 정책의 속도(2D)
                target_pos = pos .+ va * dt # 그 속도로 한 스텝 갔을 때의 예상 위치
                # commanded velocity from current position
                vb = -1.0 * compute_potential_gradient!(policy, env, pos)  # 현재 위치 포텐셜의 음의 기울기(밀려나는 방향)
                # commanded velocity from current position
                vc = -1.0 * compute_potential_gradient!(policy, env, target_pos)  # 예상 위치에서의 밀려나는 방향
                # blend the three velocities
                a = 1.0                     # 기본속도 가중치
                b = 1.0                     # 현재위치 반발 가중치
                c = 0.0                     # 예상위치 반발 가중치(여기선 끔)
                v = (a * va + b * vb + c * vc)  # 세 속도를 가중합으로 섞음
                vel = clip_velocity(v, policy.vmax)  # 최대속도(vmax)를 넘지 않게 자름
                # compute goal
                goal_pt = pos + vel * dt    # 그 속도로 갈 새 목표점
                goal = CoordinateTransformations.Translation(goal_pt..., 0.0) ∘ CoordinateTransformations.LinearMap(goal.linear)  # 3D 목표 자세 구성
                twist = compute_twist_from_goal(agent, goal, dt) # nominal twist  # 새 목표로 향하는 트위스트로 교체
            else !(policy === nothing)      # 작업할 때가 됐으면(주: else 절이라 조건식은 실행만 되고 효과 없음)
                policy.dist_to_nearest_active_agent = 0.0  # 거리 0 으로(분산 끄기)
            end
        end
    end
    # return goal
    return twist                            # 최종 트위스트(목표 속도) 반환
end

# 에이전트의 현재 자세와 목표 자세 사이의 오차를 구해, 한계속도 내에서 최적 트위스트를 계산하는 헬퍼.
function compute_twist_from_goal(
    agent, goal, dt;
    v_max=get_rvo_max_speed(agent), ω_max=default_rotational_loading_speed()  # 최대 직선/회전 속도 기본값
)
    tf_error = relative_transform(global_transform(agent), goal)  # 현재→목표 의 상대 변환(=자세 오차)
    return optimal_twist(tf_error, v_max, ω_max, dt)  # 오차로부터 최적 트위스트 계산
end

# get_cmd : 노드 종류별로 보낼 명령을 계산(다중 디스패치). 명령이 필요 없는 술어 노드들은 nothing.
get_cmd(::Union{BuildPhasePredicate,EntityConfigPredicate,ProjectComplete}, env::PlannerEnv) = nothing
# 이동 노드(운반유닛/로봇): 목표를 향하는 선호속도를 계산해 RVO 시뮬레이터에 설정.
function get_cmd(node::Union{TransportUnitGo,RobotGo}, env::PlannerEnv)
    agent = entity(node)
    if use_rvo()                            # RVO 사용 중이면
        update_position_from_sim!(agent)    # 먼저 RVO 의 최신 위치를 반영
    end

    set_rvo_priority!(env, node)            # 이 노드의 우선순위(alpha) 설정

    #? Do we want to set the max speed to zero because its at its goal? I think we should
    #? still have agents be able to move, albeit slower? 10% of normal max speed?
    if is_goal(node, env)                   # 이미 목표에 도달했으면
        twist = zero(Twist) # desired velocity it to stay still #? Could change this?  # 정지 트위스트(가만히)
        max_speed = 0.1 * get_rvo_max_speed(agent)  # 최대속도는 평소의 10%만(살짝 자리 보정 가능)
    else
        twist = get_twist_cmd(node, env)    # 아직이면 정책으로 목표 트위스트 계산
        twist_vel = norm(twist.vel[1:2])    # 그 속도의 크기(2D)
        if twist_vel > 0.0                  # 움직이려 하면
            max_speed = min(get_rvo_max_speed(agent), twist_vel)  # 최대속도를 명령속도로 제한(불필요하게 빠르지 않게)
        else
            max_speed = get_rvo_max_speed(agent)  # 정지 명령이면 최대속도는 평소대로
        end
    end

    # Battery SoC gate: a flat robot (SoC<=stall threshold) gets max_speed*0 -> it STALLS in
    # place. Inert (factor 1.0) unless navigator/battery.jl installed the hook AND stall is on.
    # (요약) 배터리 SoC 게이트: 방전된 로봇(SoC ≤ 정지 임계값)은 max_speed 에 0 이 곱해져 그 자리에 멈춤. 훅이 없으면(기본) 배율 1.0 로 무효 → 일반 실행 불변.
    if SOC_SPEED_HOOK[] !== nothing
        max_speed *= Float64(SOC_SPEED_HOOK[](node))  # node = RobotGo/TransportUnitGo (the responsible unit)
    end

    # BREAKDOWN immobilization: a robot in FAULTED_ROBOTS that has NOT been replaced is still driven
    # (its nodes stay un-parked), so it would silently finish its own work and make an UNANSWERED
    # breakdown look harmless. Physically STOP it (max_speed 0) so an unaddressed breakdown actually
    # STALLS the build — this makes adaptation consequential (no-adapt fails, Replace completes). Once
    # ReplaceAgent parks the faulted robot's nodes they are no longer driven, so this affects ONLY the
    # no-response case. Self-contained (no navigator dependency); inert when nothing is faulted.
    # (요약) 고장(BREAKDOWN) 로봇 강제 정지: 아직 교체되지 않은 고장 로봇을 그대로 구동하면 제 일을 몰래 끝내버려 "대응 안 한 고장"이 무해해 보임. 물리적으로 멈춰(max_speed 0) 미대응 고장이 실제로 빌드를 정체시키게 함(대응 없으면 실패, Replace 하면 완주 → 적응의 효과를 드러냄). ReplaceAgent 가 park 하면 더는 구동 안 되므로 이 코드는 "무대응" 경우에만 작용. 고장 없으면 무효.
    if !isempty(FAULTED_ROBOTS[])
        stop = false                            # 이 노드를 멈출지 여부
        if node isa RobotGo
            rid = try entity(node).id catch; nothing end  # 로봇 ID(실패 시 nothing)
            stop = rid !== nothing && haskey(FAULTED_ROBOTS[], rid)  # 그 로봇이 고장 목록에 있으면 정지
        elseif node isa TransportUnitGo
            team = try robot_team(entity(node)) catch; nothing end  # 운반유닛의 팀 로봇들
            stop = team !== nothing && any(mid -> haskey(FAULTED_ROBOTS[], mid), keys(team))  # 팀원 중 하나라도 고장이면 정지
        end
        stop && (max_speed = 0.0)               # 정지 대상이면 최대속도 0
    end

    rvo_set_agent_max_speed!(agent, max_speed)  # RVO 에 최대속도 설정

    # L1 SAFETY FILTER (safety/cbf.jl). THE single chokepoint: every commanded velocity in the
    # whole simulator passes through this line, so filtering here -- rather than correcting
    # positions after the fact (`enforce_restriction_zone_clearance!`, which TELEPORTS an agent
    # to the zone boundary) -- makes the no-go invariant hold by CONTROL instead of by state
    # surgery. Inert unless `enable_cbf!()` was called, so normal runs are byte-identical.
    # (요약) 시뮬레이터의 모든 속도 명령이 지나는 유일한 길목. 여기서 미리 걸러야 "사후 순간이동"이
    #        아니라 "제어"로 금지구역을 지킨다. enable_cbf!() 전에는 완전 무해(원본 그대로 통과).
    pref_vel = cbf_filter_velocity(agent, twist.vel[1:2]; max_speed = max_speed)
    rvo_set_agent_pref_velocity!(agent, pref_vel)  # RVO 에 선호속도(가고 싶은 방향·빠르기) 설정
    return twist                            # 계산한 트위스트 반환
end
# 운반유닛 결성/화물 내려놓기: 화물을 목표 자세로 천천히(적재 속도로) 옮기는 트위스트 계산.
function get_cmd(node::Union{FormTransportUnit,DepositCargo}, env::PlannerEnv)
    agent = entity(node)
    cargo = get_node(env.scene_tree, cargo_id(agent))  # 다루는 화물
    # compute velocity (angular and translational) for cargo
    v_max = default_loading_speed()         # 적재 직선속도(느림)
    ω_max = default_rotational_loading_speed()  # 적재 회전속도(느림)
    g_tform = global_transform(cargo_goal_config(node))  # 화물 목표 자세
    return compute_twist_from_goal(cargo, g_tform, env.dt, v_max=v_max, ω_max=ω_max)  # 화물용 트위스트 계산
end
# 부품을 최종 위치에 올려놓기: 회전이 많이 남았으면 "회전 먼저" 한 뒤 이동(겹침/충돌 방지).
function get_cmd(node::LiftIntoPlace, env::PlannerEnv)
    cargo = entity(node)
    # compute velocity (angular and translational) for cargo
    t_des = global_transform(goal_config(node))  # 목표 자세
    v_max = default_loading_speed()
    ω_max = default_rotational_loading_speed()
    twist = compute_twist_from_goal(cargo, t_des, env.dt, v_max=v_max, ω_max=ω_max)  # 목표로 향하는 트위스트
    if norm(twist.ω) >= 1e-2                # 회전 오차가 꽤 남아 있으면
        # rotate first
        return Twist(0 * twist.vel, twist.ω)  # 직선이동은 멈추고 회전만 먼저 수행
    end
    return twist                            # 회전이 거의 끝났으면 그대로(이동 포함) 반환
end

# apply_cmd! : 계산된 명령(cmd)을 실제 상태에 적용(다중 디스패치). 술어 노드는 할 일 없음 → nothing.
apply_cmd!(::Union{BuildPhasePredicate,EntityConfigPredicate,ProjectComplete}, cmd, env::PlannerEnv) = nothing
# 조립단계 닫기/열기 노드는 명령이 nothing(cmd::Nothing) — 단순히 해당 노드를 완료 처리.
apply_cmd!(node::CloseBuildStep, cmd::Nothing, env::PlannerEnv) = close_node!(node, env)
apply_cmd!(node::OpenBuildStep, cmd::Nothing, env::PlannerEnv) = close_node!(node, env)
# 운반유닛 결성: 팀 로봇들을 유닛 아래로 묶고, 화물을 목표로 조금 옮기며, 충분히 가까우면 화물도 포획.
function apply_cmd!(node::FormTransportUnit, twist::Twist, env::PlannerEnv)
    @unpack sched, scene_tree, cache, dt = env
    agent = entity(node)                    # 운반유닛
    cargo = get_node(scene_tree, cargo_id(agent))  # 실어야 할 화물
    for (robot_id, _) in robot_team(agent)  # 팀의 각 로봇(위치는 `_`로 무시)
        if !has_edge(scene_tree, agent, robot_id)  # 아직 유닛에 안 묶였으면
            capture_child!(scene_tree, agent, robot_id)  # 자식으로 포획(묶기)
        end
        @assert has_edge(scene_tree, agent, robot_id)  # 묶였는지 점검
    end
    tform = integrate_twist(twist, dt)      # 이번 스텝의 이동/회전 변환
    set_local_transform!(cargo, local_transform(cargo) ∘ tform)  # 화물을 그만큼 이동(기존 자세 ∘ 증분)
    if is_within_capture_distance(agent, cargo)  # 유닛이 화물에 충분히 가까우면
        capture_child!(scene_tree, agent, cargo)  # 화물도 유닛에 포획(들어올림 완료)
        rvo_set_agent_max_speed!(agent, get_rvo_max_speed(agent))  # 다시 정상 최대속도 허용
    else
        rvo_set_agent_max_speed!(agent, 0.0)  # 아직이면 유닛은 멈춰서 화물 정렬에 집중
    end
end
# 화물 내려놓기: 화물을 목표로 조금 옮기고, 목표 도달 시 유닛을 해체(로봇들 분리).
function apply_cmd!(node::DepositCargo, twist::Twist, env::PlannerEnv)
    @unpack sched, scene_tree, cache, dt = env
    agent = entity(node)
    cargo = get_node(scene_tree, cargo_id(agent))
    tform = integrate_twist(twist, dt)      # 이번 스텝 변환
    set_local_transform!(cargo, local_transform(cargo) ∘ tform)  # 화물 이동
    # A transport unit formed by a respec Replace splice can reach DepositCargo without ever being
    # registered in the RVO sim (the splice drives the schedule without the nominal
    # update_planning_cache!->update_rvo_sim! refresh). Then rvo_set_agent_max_speed! throws a
    # BoundsError[-1] inside rvo_get_agent_idx, which aborts the WHOLE simulation — this is the real
    # cause of the mid-build Replace freezing at ~240/313. Register it on demand; if that is somehow not
    # possible this step, skip the RVO speed set rather than kill the run (it retries next step).
    # (요약) respec Replace 로 급조된 운반유닛이 RVO 에 한 번도 등록되지 않은 채 DepositCargo 까지 올 수 있음. 그러면 아래 rvo_set_agent_max_speed! 가 BoundsError 로 시뮬레이션 전체를 죽임(mid-build Replace 가 ~240/313 에서 멈추던 진짜 원인). 필요할 때 즉석에서 등록하고, 그래도 안 되면 이번 스텝은 RVO 속도 설정만 건너뜀(다음 스텝에 재시도)해 실행을 죽이지 않음.
    if use_rvo() && !has_vertex(rvo_global_id_map(), node_id(agent))  # RVO 쓰는데 이 유닛이 아직 미등록이면
        try update_rvo_sim!(env) catch end       # 즉석 등록 시도(실패해도 무시)
    end
    rvo_ready = !use_rvo() || has_vertex(rvo_global_id_map(), node_id(agent))  # RVO 안 쓰거나 등록됐으면 속도설정 OK
    if is_goal(node, env)                   # 화물이 목표 위치에 도달했으면
        disband!(scene_tree, agent)         # 운반유닛 해체(로봇들을 풀어줌)
        rvo_ready && rvo_set_agent_max_speed!(agent, get_rvo_max_speed(agent))  # 정상 속도 복귀
    elseif rvo_ready
        rvo_set_agent_max_speed!(agent, 0.0)  # 아직이면 멈춰서 정렬
    end
end
# 부품 올려놓기: 그냥 화물을 명령대로 조금 이동(별도 포획/해체 없음).
function apply_cmd!(node::LiftIntoPlace, twist::Twist, env::PlannerEnv)
    @unpack sched, scene_tree, cache, dt = env
    cargo = entity(node)
    tform = integrate_twist(twist, dt)
    set_local_transform!(cargo, local_transform(cargo) ∘ tform)  # 화물 이동
end
# 이동 노드(운반유닛/로봇): RVO 를 안 쓸 때만 위치를 직접 적분해 갱신(RVO 를 쓰면 RVO 가 위치를 정함).
function apply_cmd!(node::Union{TransportUnitGo,RobotGo}, twist::Twist, env::PlannerEnv)
    @unpack sched, scene_tree, cache, dt = env
    if !use_rvo()                           # RVO 미사용 시에만
        agent = entity(node)
        tform = integrate_twist(twist, dt)  # 트위스트를 적분해 이동량 계산
        set_local_transform!(agent, local_transform(agent) ∘ tform)  # 에이전트 위치 직접 갱신
    end
end
