export TangentBugPolicy   # 이 정책 타입을 모듈 밖에서 바로 쓸 수 있게 공개

# =============================================================================
# TANGENT BUG : 정적 원형 장애물(staging area)을 피해 목표로 가는 국소 항법기
# -----------------------------------------------------------------------------
# 역할: 계층의 ① 최상위 레이어. 직선으로 목표를 향하다가 "활성화되지 않은
#       조립영역(원으로 근사)"이 가로막으면, 그 원의 접선(tangent)을 따라
#       우회하는 waypoint를 만든다. 출력은 nominal twist(속도명령)이며,
#       그 뒤 potential field(②)와 RVO(③)가 추가로 보정한다.
# 핵심: 장애물을 반지름 r의 원으로 보고, 에이전트 반경+buffer만큼 부풀린(bloat)
#       원에 대해 기하학적으로 접선점/우회각을 계산한다.
# =============================================================================
@with_kw mutable struct TangentBugPolicy
    mode = :MOVE_TOWARD_GOAL            # 현재 상태기계 모드(아래 set_policy_mode! 참고)
    vmax = 1.0                          # 최대 선속도 [m/s]
    dt = 1/40.0                         # 제어 주기 [s] (시뮬레이터 40Hz)
    proximity_tolerance = 1e-2          # 원 경계 근접 판정 여유 [m]
    agent_radius = 0.5                  # 에이전트(로봇/운반팀) 반경 [m]
    planning_radius = 2 * agent_radius  # 계획 시야 반경
    detour_horizon = 2 * planning_radius# 이 거리 안의 장애물만 우회 대상으로 고려
    buffer = staging_buffer_radius()    # 원을 추가로 부풀리는 안전여유(staging 회피용)
    # store config and command
    config = identity_linear_map()      # 에이전트의 현재 6-DOF 포즈(transform)
    cmd = Twist(SVector(0.0, 0.0, 0.0), SVector(0.0, 0.0, 0.0)) # 마지막으로 계산한 속도명령
end

"""
    first_intersection_pt(circle,p1,p2)

Return closest point of intersection of `circle` with line from `p1` to `p2`

[기하] 선분 p1→p2 와 원(center c, radius r)의 첫(가까운) 교점을 구한다.
  pt = c를 직선에 내린 수선의 발(foot of perpendicular)
  b  = |pt - c|  : 직선과 중심 사이 거리. b>r 이면 교차 없음 → nothing
  a  = √(r²-b²)  : 현(chord) 절반 길이 (피타고라스)
  교점 = p1 방향으로 (|p1→pt| - a) 만큼 전진한 점 = 더 가까운 쪽 교점
"""
function first_intersection_pt(circle, p1, p2)
    c = get_center(circle)                 # 원의 중심 좌표
    r = get_radius(circle)                 # 원의 반지름
    pt = project_point_to_line(c, p1, p2)  # 중심 c의 직선 위 수직 투영점
    b = norm(pt - c)                       # 직선-중심 거리
    if b > r
        return nothing                     # 직선이 원을 스치지도 않음
    end
    a = sqrt(r^2 - b^2)                    # 반현(half-chord) 길이
    vec = pt - p1                          # p1 → 수선의 발(pt) 방향벡터
    return p1 + normalize(vec) * (norm(vec) - a)  # p1에서 더 가까운 교점
end

"""
    get_closest_interfering_circle(policy,circles,pos,nominal_goal)

Returns the id and bloated (by policy.agent_radius+buffer) circle closest to pos

[역할] pos에서 nominal_goal까지의 직선 경로를 가로막는 장애물 원들 중,
       에이전트가 부딪힐 정도(=가장 침투가 깊은=d가 가장 작은) 원을 고른다.
  - bloat: 원 반지름을 r + agent_radius(+buffer)로 부풀려 점-크기 에이전트로 환원
           (Minkowski sum: 에이전트를 점으로 보는 대신 원을 키운다)
  - d = |center-pos| - bloated_r : 부푼 원 경계까지의 부호거리(침투량).
        d<0 이면 pos가 이미 원 안에 들어가 있다는 뜻.
  - return_w_no_buffer=true 면 buffer를 빼고(부풀림 최소) 순수 충돌만 검사.
"""
# 인자에서 `;` 뒤는 "키워드 인자"(파이썬의 키워드 매개변수와 동일). return_w_no_buffer 는 기본값 false.
function get_closest_interfering_circle(policy, circles, pos, nominal_goal; return_w_no_buffer=false)
    # @unpack : Parameters 패키지의 매크로. policy 구조체의 필드들을 같은 이름의 지역변수로 한 번에 풀어줌
    #           (파이썬에서 a, b = obj.a, obj.b 를 여러 줄 한 번에 하는 것과 비슷).
    @unpack planning_radius, detour_horizon, proximity_tolerance, buffer,
    agent_radius, vmax, dt = policy
    dmin = Inf                             # 지금까지 본 가장 깊은 침투량(작을수록 깊게 막음). Inf=아직 없음
    id = nothing                           # 가장 막는 원의 id (없으면 nothing = 파이썬 None)
    circ = nothing                         # 그 원(부풀린 형태) 저장용
    pt = nominal_goal                      # 진입 교점 waypoint (못 찾으면 목표 그대로)
    for (circ_id, c) in circles            # 모든 (원 id, 원) 쌍을 순회
        x = get_center(c)                  # 이 원의 중심
        r = get_radius(c)                  # 이 원의 반지름
        # 에이전트 반경 + (옵션)buffer 만큼 원을 부풀림.
        # 여기서 `!` 는 불리언 NOT(파이썬 not). !return_w_no_buffer 가 true(=1)면 buffer를 더하고, false(=0)면 0을 곱해 뺌.
        # Ball2(중심, 반지름) = LazySets 의 유클리드 원/구. (모듈명.함수 호출은 파이썬과 동일)
        bloated_circle = LazySets.Ball2(x, r + agent_radius + buffer * (!return_w_no_buffer))
        if circle_intersects_line(bloated_circle, pos, nominal_goal)  # 직선이 이 원을 통과?
            d = norm(x - pos) - get_radius(bloated_circle) # penetration(부호거리)
            if d < dmin                    # 지금까지보다 더 깊게 막으면 갱신
                # penetration < 0 => pos is in circle (가장 깊이 막는 원을 선택)
                dmin = d                   # 최소 침투량 갱신
                id = circ_id               # 이 원을 후보로 기록
                circ = bloated_circle      # 부풀린 원 저장
                pt = first_intersection_pt(bloated_circle, pos, nominal_goal) # 진입 교점
            end
        end
    end
    return id, circ, pt                    # (가장 막는 원 id, 그 원, 진입 교점) 세 값을 한 번에 반환
end

# =============================================================================
# 상태기계(state machine): 가로막는 원과 에이전트/목표의 위치 관계로 모드 결정
#   :MOVE_TOWARD_GOAL  막힘 없음 → 그냥 목표로 직진
#   :WAIT_OUTSIDE      목표가 (아직 비활성) 원 내부 → 원 밖에서 대기/선회
#   :EXIT_CIRCLE       에이전트가 원 안에 갇힘 → 가장 가까운 경계로 탈출
#   :MOVE_ALONG_CIRCLE 원 경계에 거의 닿음 → 경계를 스치며 선회
#   :MOVE_TANGENT      원이 앞을 막음 → 접선점을 향해 우회
#   dmin = |center-pos| - r : 부푼 원 경계까지 부호거리(음수면 내부)
# =============================================================================
# 함수 이름 끝의 `!` = 관례상 "인자(policy)를 직접 수정함"을 표시. 여기선 policy.mode 를 바꾼다.
function set_policy_mode!(policy, circ, pos, nominal_goal, parent_step_active)
    @unpack planning_radius, detour_horizon, proximity_tolerance, buffer,
    agent_radius, vmax, dt = policy        # policy 필드들을 지역변수로 풀기
    dmin = Inf                             # 경계까지 부호거리(기본 무한대 = 막는 원 없음)
    c = nothing                            # 막는 원의 중심
    r = nothing                            # 막는 원의 반지름
    # `===` 는 "동일 객체인가" 비교(파이썬 is). circ === nothing = "circ 가 None 인가".
    # !(...) 로 부정 → "막는 원이 있으면"
    if !(circ === nothing)
        c = get_center(circ)               # 막는 원 중심
        r = get_radius(circ)               # 막는 원 반지름
        dmin = norm(c - pos) - r          # 경계까지 부호거리(음수=내부)
    end

    mode = policy.mode                     # 현재 모드에서 시작
    # `:이름` 은 Symbol(심볼). 파이썬에 정확히 대응은 없지만 "문자열 상수 같은 라벨"로 보면 됨(여기선 모드 이름).
    if circ === nothing
        mode = :MOVE_TOWARD_GOAL          # 막는 원 없음 → 직진
    else
        if norm(nominal_goal - c) < r # nominal_goal is in circle (목표가 원 안쪽인가)
            mode = :WAIT_OUTSIDE          # 목표가 원 안 → 일단 밖에서 대기

            # If we're in a circle and its not active, we need to get out
            goal_in_circle = norm(nominal_goal - c) < r   # 목표가 원 안?
            robot_in_circle = norm(pos - c) < r           # 로봇이 원 안?
            # 원이 아직 활성(조립중)이 아닌데 로봇·목표가 둘 다 안에 있으면 탈출.
            # `&&` 는 논리 AND(파이썬 and). !parent_step_active = "부모 작업단계가 비활성이면".
            if !parent_step_active && goal_in_circle && robot_in_circle
                mode = :EXIT_CIRCLE        # 비활성 원에 갇힘 → 빠져나가기
            end

        elseif dmin + proximity_tolerance >= 0
            # not currently in a circle, but on a course for intersection
            # 아직 원 밖이지만 직선 경로가 원과 교차하는 상황
            if norm(nominal_goal - pos) + agent_radius / 2 < norm(nominal_goal - c)
                # Just keep going toward goal (on the clear side)--this statement should never be reached
                mode = :MOVE_TOWARD_GOAL   # 목표가 원보다 가까운(안 막힌) 쪽 → 직진
            elseif dmin < detour_horizon  # 원이 우회 시야 안에 있을 때만 우회
                # detour
                if dmin < 2 * proximity_tolerance
                    # right at circle---just turn right to skim (경계에 거의 붙음)
                    mode = :MOVE_ALONG_CIRCLE   # 경계 스치며 선회
                else
                    # Pick a tangent point to shoot for (접선점으로 우회)
                    mode = :MOVE_TANGENT        # 접선점 향해 우회
                end
            else
                mode = :MOVE_TOWARD_GOAL   # 아직 멀다 → 일단 직진
            end
        else
            # INSIDE CIRCLE (dmin<0): 원 안에 갇힘 → 탈출
            mode = :EXIT_CIRCLE
        end
    end
    policy.mode = mode                     # 계산한 모드를 policy 에 저장(in-place 수정)
end

# =============================================================================
# 메인 정책: 모드별로 다음 waypoint(goal)를 정하고 그쪽으로 향하는 속도를 계산.
# 반환값 goal 은 route_planning.get_twist_cmd 에서 nominal twist 로 변환된다.
# 회전 기하 노트:
#   - 원 위를 한 스텝(호 길이 dr=vmax·dt) 진행할 때의 중심각:
#       dθ = 2·sin(0.5·dr/r)   (현 길이 dr ↔ 중심각의 관계, dr≪r 이면 dθ≈dr/r)
#   - 2x2 회전행렬 [cosθ -sinθ; sinθ cosθ] 로 반경벡터 dvec 를 dθ 만큼 돌려
#     경계 위의 다음 목표점을 만든다.
#   - 접선(tangent): pos에서 반지름 r 원에 그은 접선의 반각 ψ=asin(r/|c-pos|),
#     접선점은 반경벡터를 (π/2 - ψ) 만큼 회전시킨 위치.
# =============================================================================
# 이름 끝 `!` = policy(와 그 cmd/mode)를 직접 수정. 반환값은 다음 목표점 goal.
function tangent_bug_policy!(policy, circles, pos, nominal_goal, parent_step_active)
    @unpack planning_radius, detour_horizon, proximity_tolerance, buffer,
    agent_radius, vmax, dt = policy        # policy 필드들 풀기

    c = nothing                            # 막는 원 중심
    r = nothing                            # 막는 원 반지름
    id = nothing                           # 막는 원 id
    dmin = Inf                             # 경계까지 부호거리
    # 경로를 막는 가장 가까운 원과 (있으면) 진입 교점 waypoint 획득
    id, circ, waypoint = get_closest_interfering_circle(policy, circles, pos, nominal_goal)
    if !(circ === nothing)                 # 막는 원이 있으면
        c = get_center(circ)               # 그 중심
        r = get_radius(circ)               # 그 반지름
        dmin = norm(c - pos) - r           # 경계까지 부호거리
    end
    # select operating mode (위 상태기계)
    mode = set_policy_mode!(policy, circ, pos, nominal_goal, parent_step_active)

    # Select waypoint (모드별 목표점 결정)
    goal = nominal_goal                    # 기본 목표는 원래 목표
    if mode == :WAIT_OUTSIDE               # `==` 로 심볼(모드) 비교
        # 목표가 원 안 → 원 밖 경계를 따라 한 스텝 선회하며 활성화 대기
        if norm(nominal_goal - pos) + buffer > r
            dvec = normalize(pos - c) * (r + proximity_tolerance)  # 경계 위 반경벡터
            dr = vmax * dt                                         # 한 스텝 호 길이
            dθ = 2 * sin(0.5 * dr / r)                             # 대응 중심각
            goal = c + [cos(dθ) -sin(dθ); sin(dθ) cos(dθ)] * dvec  # dθ 회전한 경계점
        else
            goal = c + normalize(pos - c) * r                      # 가장 가까운 경계점
        end
    elseif mode == :MOVE_TOWARD_GOAL
        goal = nominal_goal                                        # 직진
    elseif mode == :MOVE_ALONG_CIRCLE     # 경계를 스치며 선회
        # 경계에 붙어 스치듯 선회 (WAIT_OUTSIDE의 선회와 동일한 호-각 계산)
        dvec = normalize(pos - c) * (r + proximity_tolerance)  # 중심→로봇 방향 경계 반경벡터
        # compute sector to traverse
        dr = vmax * dt                                         # 한 스텝에 진행할 호 길이
        dθ = 2 * sin(0.5 * dr / r)                             # 그에 대응하는 중심각
        # [a b; c d] 는 2x2 행렬 리터럴(세미콜론 ;=행 구분). 여기선 2D 회전행렬을 dvec 에 곱해 dθ 만큼 돌림.
        goal = c + [cos(dθ) -sin(dθ); sin(dθ) cos(dθ)] * dvec  # dθ 회전한 경계 위 다음 점
    elseif mode == :MOVE_TANGENT          # 접선점 향해 우회
        vec = c - pos # vector from pos to circle center (에이전트→중심)
        ψ = asin(r / norm(vec)) # yaw angle of right tangent line (접선 반각)
        dθ = π / 2 - ψ # CCW angular offset to tangent point (접선점까지 회전각)
        dvec = normalize(pos - c) * r                      # 중심→에이전트 방향 반경벡터
        goal = c + [cos(dθ) -sin(dθ); sin(dθ) cos(dθ)] * dvec  # 접선점
        # if goal causes intersection with another circle, choose waypoint instead
        # 접선점으로 가다 또 다른 원에 막히면, 단순 진입 교점(waypoint)으로 대체
        # 반환값 중 필요 없는 것은 `_` 로 버림(파이썬과 동일). 여기선 새로 막는 원의 id 만 확인.
        new_id, _, _ = get_closest_interfering_circle(policy, circles, pos, goal)
        # `||` 는 논리 OR(파이썬 or). "새 막는 원이 없거나, 원래 그 원이면" 무시; 그 외엔 우회 포기.
        if !(new_id === nothing || new_id == id)
            policy.mode = :MOVE_TOWARD_GOAL                # 또 막히면 접선 우회 포기
            goal = waypoint                                # 단순 진입 교점으로 대체
        end
    elseif mode == :EXIT_CIRCLE
        vec = pos - c                                      # 중심에서 바깥 방향
        if norm(vec) < 1e-3                                # 로봇이 거의 정확히 중심에 있으면
            goal = nominal_goal                            # 정확히 중심이면 목표로
        else
            goal = c + (r + 2 * proximity_tolerance) * normalize(vec) # 최단 탈출점
        end
    else
        # `$mode` 는 문자열 보간(파이썬 f-string 의 {mode}). 알 수 없는 모드면 에러 던짐.
        throw(ErrorException("Unknown controller mode $mode"))
    end
    # compute desired velocity: goal 방향으로 vmax, 단 한 스텝에 못 넘게 클립
    vec = goal - pos                                       # 목표까지의 변위 벡터
    if norm(vec) > vmax * dt                               # 한 스텝 이동 거리보다 멀면
        vel = vmax * normalize(vec)                        # 멀면 최대속도
    else
        vel = vec / dt                                     # 가까우면 한 스텝에 도달하는 속도
    end
    # `vel[1:2]...` 의 `...` 는 splat(펼치기): 벡터의 원소들을 인자로 풀어 넣음(파이썬 *args 와 같음).
    # Twist(선속도, 각속도): 2D 속도(vel x,y)에 z=0, 각속도 0 을 붙여 6-DOF twist 로 만듦.
    policy.cmd = Twist(SVector(vel[1:2]..., 0.0), SVector(0.0, 0.0, 0.0))  # 속도명령 저장
    # @show mode, dmin
    return goal                                            # 다음 목표점 반환
end

# 한 줄짜리 함수 정의(f(x) = ...). `::TangentBugPolicy` 는 "policy 가 이 타입일 때만 이 메서드"(다중 디스패치).
# `args...` 는 나머지 인자들을 한 묶음(가변인자)으로 받음. 즉 이 정책에 대한 goal 질의를 tangent_bug_policy! 로 위임.
query_policy_for_goal!(policy::TangentBugPolicy, args...) = tangent_bug_policy!(policy, args...)
