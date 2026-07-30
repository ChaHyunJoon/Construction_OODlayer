# =============================================================================
# POTENTIAL FIELDS : 에이전트 분산(dispersion) / 국소 반발을 만드는 ② 중간 레이어
# -----------------------------------------------------------------------------
# 아이디어: 각 에이전트 위치 x에 스칼라 "포텐셜" U(x)를 정의하고,
#   속도 v = -∇U(x) (gradient descent)로 움직이면 포텐셜이 낮은 곳(=목표 근처,
#   다른 로봇에서 먼 곳)으로 자연히 이동한다.
# 이 파일은 (1) 여러 포텐셜 모양(cone/tent/barrier/...)을 정의하고,
#   (2) 로봇쌍 반발 포텐셜과 그 gradient를 우선순위(α)에 따라 합성한다.
# ForwardDiff 로 ∇U 를 자동미분으로 구한다.
# =============================================================================
# `abstract type ... end` = "추상 타입". 인스턴스를 만들 수 없고, 여러 구체 포텐셜의 공통 부모(상속용 빈 껍데기).
abstract type Potential end
# 같은 이름 potential 에 인자 타입별로 여러 메서드를 정의(다중 디스패치). v::Vector 메서드 = "리스트가 들어오면".
# 포텐셜 리스트의 합 U(x) = Σ Uᵢ(x) (중첩 원리). `for p in v` 는 제너레이터(파이썬 sum(... for ...)와 동일).
potential(v::Vector, x) = sum(potential(p, x) for p in v)
# ∇U(x): 단일 포텐셜은 자동미분으로. `x -> potential(v, x)` 는 익명함수(파이썬 lambda x: ...).
potential_gradient(v, x) = ForwardDiff.gradient(x -> potential(v, x), x)
# ∇U(x): 리스트면 각 gradient의 합 (∇Σ = Σ∇)
potential_gradient(v::Vector, x) = sum(potential_gradient(p, x) for p in v)
# "호출 가능 객체" 정의: (p::Potential)(x) 는 "Potential 인스턴스 p 를 함수처럼 p(x) 로 부르면 이 코드 실행".
# 파이썬의 __call__ 에 해당.
(p::Potential)(x) = potential(p, x)  # p(x) 호출 = potential(p,x)

"""
    ConePotential <: Potential

Produces a potential function in the shape of a cone.
"""
# `mutable struct` = 필드 값을 나중에 바꿀 수 있는 구조체(그냥 struct 는 생성 후 불변). 파이썬 class 와 가장 비슷.
# `<: Potential` = 이 타입은 Potential 의 하위 타입(상속). 위 익명-callable/디스패치들이 그대로 적용됨.
mutable struct ConePotential <: Potential
    c # coefficient (기울기 계수)
    R # radius (포화 반경: 이보다 멀면 값이 일정)
    x # center (꼭짓점 위치)
end
# 원뿔: U = c·min(R, |x_center - x|).  중심에서 멀수록 선형 증가, R에서 포화.
potential(p::ConePotential, x) = p.c * min(p.R, norm(p.x - x))

"""
    HelicalPotential
"""
# 나선형 포텐셜: 중심 기준 방위각(각도)에 비례하는 포텐셜(목표 방위 θ 로 돌게 유도).
mutable struct HelicalPotential
    c # coefficient
    x # center
    θ # desired angle
end
# 나선: 중심 기준 현재 방위각 ψ 와 목표각 θ 의 차이(Δθ)에 비례하는 포텐셜 → θ 방향으로 선회하도록 유도.
function potential(p::HelicalPotential, x)
    ψ = atan(x[2], x[1])                         # 현재 점의 방위각(원점 기준 atan2)
    Δθ = wrap_to_pi(angular_difference(θ, ψ))    # 목표각 θ 와의 차이를 (-π,π] 로 감싸기
    return p.c * Δθ                              # 각도차에 비례하는 포텐셜
end

"""
    TentPotential <: Potential

Produces a potential function in the shape of a tent
"""
mutable struct TentPotential <: Potential
    c # coefficient
    R # radius (포화 거리)
    x # start (선분 시작점)
    g # goal  (선분 끝점)
end
# 텐트: start→goal 선분으로부터의 수직거리에 비례하는 포텐셜(선분 주변 "능선").
#   xp = dx를 선분방향 v에 정사영한 성분.
#   투영이 선분 내부면 → 선분까지 수직거리 |dx-xp| 사용,
#   선분 밖이면 → 양 끝점 중 가까운 거리 사용. 둘 다 R에서 포화.
function potential(p::TentPotential, x)
    dx = x - p.x                                 # 시작점 기준 상대위치
    v = p.g - p.x                                # 선분(시작→끝) 방향벡터
    xp = dot(dx, v) * v / norm(v)^2              # dx의 선분방향 정사영(dot=내적)
    if 0.0 < dot(xp, normalize(v)) < norm(v)     # 정사영이 선분 구간 안인가
        return p.c * min(p.R, norm(dx - xp))     # 선분까지 수직거리
    else
        return p.c * min(p.R, min(norm(x - p.x), norm(x - (p.g)))) # 끝점까지 거리
    end
end

# 변환 포텐셜: 내부 포텐셜 값에 함수 f 를 한 번 더 씌움(예: 제곱, 클리핑 등 후처리).
mutable struct TransformPotential <: Potential
    p # potential
    f # function
end
potential(p::TransformPotential, x) = p.f(potential(p.p, x))   # f(내부포텐셜(x))

# 임의 포텐셜: 사용자가 준 함수 f 를 그대로 포텐셜로 사용.
mutable struct GenericPotential <: Potential
    f # function
end
potential(p::GenericPotential, x) = p.f(x)                     # 그냥 f(x)

# 스케일 포텐셜: 내부 포텐셜에 상수 c 를 곱함.
mutable struct ScaledPotential
    p # potential
    c # scalar
end
potential(p::ScaledPotential, x) = p.c * potential(p.p, x)     # c · 내부포텐셜(x)

"""
    ClippedPotential

Represents a clipped potential function
"""
mutable struct ClippedPotential <: Potential
    p # potential
    c # coefficient
    R # radius
end
# 클립: 내부 포텐셜을 최소 R 로 바닥을 깐 뒤 c 배(max 로 R 이하로 못 내려가게).
potential(p::ClippedPotential, x) = p.c * max(p.R, potential(p.p, x))

"""
    BarrierPotential

Encodes a potential field formed by inverting the squared value of a child
potential plus some minimum denominator value
"""
mutable struct BarrierPotential <: Potential
    p # potential (내부 포텐셜, 보통 거리류)
    c # coefficient
    z # minimum denominator (0 나눗셈 방지 최소값)
end
# 장벽: U = c / (z + p(x)²).  내부값 p가 0(=충돌 임박)에 가까울수록 폭발적으로 커짐
#   → 가까이 갈수록 강하게 미는 반발 장벽. z는 발산을 막는 하한.
potential(p::BarrierPotential, x) = p.c / (p.z + potential(p.p, x)^2)

"""
    RotationalPotential

Encodes a rotational field
"""
mutable struct RotationalPotential
    p # potential
    c # coefficient
    zmax # maximum magnitude
end
# function potential(p::RotationalPotential,x)
#     dx = potential_gradient(p.p,x)
#     v = [0.0,0.0,1.0]
#     @show z = cross(v,[dx...,0.0])[1:2]
#     return p.c * dot(z,x)
# end
# 회전장: 내부 포텐셜의 gradient ∇p 를 z축(연직)과 외적해 90° 돌린 벡터를 반환.
#   → 장애물을 향해/멀어지게가 아니라 "옆으로 돌아" 흐르게 만드는 소용돌이 성분.
#   zmax 로 크기 제한(clip).
function potential_gradient(p::RotationalPotential, x)
    dx = potential_gradient(p.p, x)
    v = [0.0, 0.0, 1.0]
    dz = cross(v, [dx..., 0.0])[1:2]      # ∇p 를 90° 회전 (z×∇p)
    if norm(dz) > p.zmax
        return p.zmax * normalize(dz)     # 크기 제한
    else
        return dz
    end
end

# 두 에이전트 사이 상호작용 포텐셜을 담는 래퍼. f=실제 함수, scale=세기.
mutable struct PairwisePotential
    f
    scale
end
# 호출 가능 객체: p(x1,x2,r1,r2) 로 부르면 내부 함수 f 에 그대로 전달(파이썬 __call__).
(p::PairwisePotential)(x1, x2, r1, r2) = p.f(x1, x2, r1, r2)

"""
    repulsion_potential(x,r,x2,r2;

Combines a cone potential and a 1/||x|| barrier potential for pairwise
repulsion.
"""
# 두 에이전트(반경 r, r2) 사이의 반발 포텐셜. 두 항의 합:
#   dx = x - x2 (상대위치),  R = r + r2 (두 반경 합 = 접촉거리)
#   f1 (cone)   = max(0, R+dr - |dx|)     : 거리가 R+dr 안으로 들어오면 선형 증가
#   f2 (barrier)= max(0, 1/(|dx|-dr) - 1/R): |dx|→dr 일 때 1/0 처럼 급증(강한 근접 반발)
#   dr 은 "여유 버퍼". |dx|>R+dr 이면 둘 다 0 → 멀면 상호작용 없음.
# `;` 뒤 dr 은 키워드 인자(기본값 = 로봇반경의 2배). 함수 호출(default_robot_radius())로 기본값 계산 가능.
function repulsion_potential(x, r, x2, r2;
    dr=2 * default_robot_radius(),
    # fillet_radius=0.5*default_robot_radius(),
)
    # `.-` 는 "브로드캐스트 뺄셈"(원소별 연산). 파이썬 numpy 의 x - x2 처럼 벡터 원소끼리 뺌.
    dx = x .- x2                                  # 두 에이전트 상대위치 벡터
    R = r + r2                                    # 두 반경 합(= 서로 닿는 거리)
    # cone (중거리: 선형 반발)
    f1 = max(0.0, R + dr - norm(dx))              # 거리가 R+dr 안으로 들어오면 선형으로 커짐, 밖이면 0
    # barrier (근거리: 폭발적 반발)
    f2 = max(0, 1 / (norm(dx) - dr) - 1 / R)      # 거리가 dr 에 가까울수록 1/0 처럼 급증
    return f1 + f2                                # 두 항의 합 = 최종 반발 포텐셜
end

# 실제 시뮬레이터에서 쓰는 분산 제어기. 에이전트마다 1개씩 가진다.
# (위의 PairwisePotential/GlobalPotentialController 류는 구버전/실험용)
# @with_kw : 필드에 기본값을 주고 키워드 생성자를 자동 생성(파이썬 dataclass 와 비슷).
# 필드 기본값이 다른 필드를 참조할 수 있음(예: max_buffer_radius 가 agent_radius 사용).
@with_kw mutable struct PotentialFieldController
    agent = nothing                          # 이 제어기가 담당하는 에이전트
    node = nothing                           # 스케줄 상의 노드(RobotGo/TransportUnitGo)
    agent_radius = 1.0                       # 에이전트 반경
    vmax = 1.0                               # 최대 속도
    # for modifying potentials
    dist_to_nearest_active_agent = Inf       # 가장 가까운 '활성' 에이전트까지 거리(버퍼 조절용)
    max_buffer_radius = 2.5 * agent_radius   # 포텐셜에 더할 버퍼 상한
    buffer_radius = max_buffer_radius        # 현재 버퍼(혼잡할수록 줄여 통행 허용)
    interaction_radius = 20 * ROBOT_RADIUS   # 이 거리 밖 상대는 무시(계산량 절감)
    # potentials between all pairs of robots (로봇쌍 반발: 위 repulsion_potential)
    # 필드에 익명함수(lambda)를 저장 — 두 에이전트 사이 반발을 계산하는 함수.
    pairwise_potentials = (x, r, xp, rp) -> repulsion_potential(x, r, xp, rp)
    # environment potentials (정적 환경 포텐셜; 기본 0 = 미사용)
    static_potentials = (x, r) -> 0.0        # 정적 환경 포텐셜(기본은 항상 0)
end
# 가장 가까운 '활성(작업중)' 에이전트까지의 거리(와 그 id)를 찾는다. `::타입` 표기로 인자 타입 고정(다중 디스패치).
function dist_to_nearest_active_agent(policy::PotentialFieldController, env::PlannerEnv)
    @unpack scene_tree, sched, cache = env                          # env 필드들을 지역변수로 풀기
    agent = policy.agent                                            # 내 에이전트
    pos = project_to_2d(global_transform(agent).translation)       # 내 위치를 2D(x,y)로 투영
    shortest_dist = Inf                                            # 지금까지 가장 짧은 거리
    id = nothing                                                   # 그 상대의 id
    for (other_id, other_p) in env.agent_policies                  # 모든 다른 에이전트 정책 순회
        other_policy = other_p.dispersion_policy                   # 상대의 분산(potential) 정책
        if !(other_policy === policy)                              # 자기 자신은 건너뜀
            other_node = other_policy.node                         # 상대의 스케줄 노드
            pbs_active = parent_build_step_is_active(node_id(entity(other_node)), env)  # 상대 작업이 활성인가
            if (pbs_active && cargo_ready_for_pickup(other_node, env))  # 활성이고 픽업 준비됐으면
                other_agent = other_policy.agent                   # 상대 에이전트
                other_rad = other_policy.agent_radius              # 상대 반경
                other_pos = project_to_2d(global_transform(other_agent).translation)  # 상대 위치 2D
                # other_rad = get_radius(get_base_geom(other_agent,HypersphereKey()))
                dist = norm(pos - other_pos) - (other_rad + policy.agent_radius)  # 표면-표면 거리
                if dist < shortest_dist                            # 더 가까우면 갱신
                    shortest_dist = min(dist, shortest_dist)       # 최단 거리 갱신
                    id = node_id(other_agent)                      # 그 상대 id 기록
                end
            end
        end
    end
    return id, shortest_dist                                       # (가장 가까운 활성 상대 id, 거리)
end
# 위에서 계산한 최단 거리를 policy 필드에 저장(in-place). 이름 끝 `!` 가 그 수정을 표시.
function update_dist_to_nearest_active_agent!(policy::PotentialFieldController, env::PlannerEnv)
    id, dist = dist_to_nearest_active_agent(policy, env)           # 다중 반환값을 두 변수로 분해
    policy.dist_to_nearest_active_agent = dist                     # 거리 저장
end

# 버퍼 반경을 상황에 맞게 조절:
#   기본: r_j = min(max_buffer, agent_radius / 가까운_활성에이전트거리)
#         → 활성 에이전트가 가까울수록(분모↓) 버퍼↑ = 더 강하게 비켜줌.
#   단, 자기 자신이 '활성'(운반 중이거나 픽업 준비된 로봇)이면 항상 최대 버퍼 사용.
# `Union{A, B}` = "A 이거나 B 타입"(파이썬 Union[A,B]). node 는 RobotGo 또는 TransportUnitGo.
# `::Bool` = 그 인자가 불리언 타입임을 명시.
function update_buffer_radius!(
    policy::PotentialFieldController,
    node::Union{RobotGo, TransportUnitGo},
    build_step_active::Bool,
    cargo_ready_for_pickup::Bool
)
    # 활성 상대가 가까울수록(분모↓) r_j↑. 단 상한 max_buffer 로 클립.
    r_j = min(policy.max_buffer_radius, policy.agent_radius / policy.dist_to_nearest_active_agent)
    # 내가 '활성' 에이전트인지 판정: 운반팀이 작업중이거나, 로봇이 작업중+픽업준비됨.
    active_agent = (
        (matches_template(TransportUnitGo, node) && build_step_active) ||
        (matches_template(RobotGo, node) && build_step_active && cargo_ready_for_pickup)
    )
    if active_agent
        r_j = policy.max_buffer_radius   # 작업 중인 에이전트는 최대 버퍼
    end
    policy.buffer_radius = r_j           # 계산한 버퍼를 policy 에 저장
end

# pairwise_potential_field(policy)
# 정적 환경 포텐셜의 gradient ∇U_static(pos) 를 자동미분으로 구함.
function static_potential_gradient(c::PotentialFieldController, pos)
    ForwardDiff.gradient(x -> c.static_potentials(x, c.agent_radius), pos)  # ∇ static_potentials
end
# 한 상대 에이전트에 대한 반발 포텐셜의 gradient ∇U_repulsion(pos) 를 자동미분으로 구함.
function pairwise_potential_gradient(c::PotentialFieldController, pos, other_pos, other_radius; dr=1.0)
    ForwardDiff.gradient(
        x -> c.pairwise_potentials(                # 익명함수: 내 위치 x 만 변수로 두고 미분
            x,
            c.agent_radius,
            other_pos,
            other_radius,
            ;                                      # 세미콜론 = 여기부터 키워드 인자
            dr=dr                                  # 반발 폭(상대 버퍼)
        ),
        pos)                                       # 이 점 pos 에서의 gradient
end

# 속도 크기가 vmax 를 넘으면 방향은 유지한 채 크기만 vmax 로 줄임(속도 제한).
function clip_velocity(vel, vmax)
    if norm(vel) > vmax
        v = vmax * normalize(vel)                  # 너무 빠르면 vmax 로 클립
    else
        v = vel                                    # 한도 내면 그대로
    end
    return v
end

# ── 우선순위(α) 기반 반발 스케일 ──────────────────────────────────────────
# α는 RVO priority(작을수록 높은 우선순위). 이 함수가 "계층적" 양보의 핵심:
#   α1 < α2  → 0.0  : 나(α1)가 상대(α2)보다 우선순위 높음 → 안 밀림(상대가 비켜야 함)
#   α1 == 0  → α2/(α1+min(α2,0.05)) : 내가 최고우선(0)인데도 살짝 반응(0 나눗셈 회피)
#   그 외    → α2/α1 : 상대 우선순위가 높을수록 더 크게 밀려남
function pairwise_potential_scale(policy::PotentialFieldController, α1, α2)
    if α1 < α2
        return 0.0 # precedence--no push (우선순위 높음 → 양보 안 함)
    elseif α1 == 0
        return α2 / (α1 + min(α2, 0.05))
    else
        return α2 / α1
    end
end

"""
    pairwise_potential_width(policy::PotentialFieldController,α1,α2)

How much extra width to add to pairwise potential.
"""
# 우선순위(α) 기반 반발 "폭" 추가량 — 위 pairwise_potential_scale 과 짝을 이뤄 반발 포텐셜을 얼마나 더 넓힐지 결정.
#   α1 < α2 → 0.0            : 내가 우선순위 높음 → 넓히지 않음(양보 안 함)
#   α1 == 0 → 로봇반경 1배    : 내가 최고우선(0)이면 넓게
#   그 외   → 로봇반경 0.5배  : 우선순위 낮으면 좁게
function pairwise_potential_width(policy::PotentialFieldController, α1, α2)
    if α1 < α2
        return 0.0 # no push
    elseif α1 == 0
        return default_robot_radius()
    else
        return 0.5 * default_robot_radius()
    end
end

# ── 분산 속도의 핵심: 위치 pos에서 받는 총 반발 gradient ∇U 계산 ───────────
# route_planning.get_twist_cmd 에서 vb = -∇U(pos) 로 써서 nominal 속도에 더한다.
#   ∇U = ∇U_static + Σ_(상대 j) ∇U_repulsion(pos, x_j)
# 우선순위 게이팅: α1 <= α2 인 상대(=나보다 우선순위 같거나 높음)는 건너뜀
#   → "나는 나보다 낮은 우선순위 로봇에게만 밀린다" = 계층적 통행권.
# interaction_radius 밖 상대는 무시.
function compute_potential_gradient!(policy::PotentialFieldController, env::PlannerEnv, pos)
    @unpack scene_tree, sched = env               # env 필드 풀기
    agent = policy.agent                          # 내 에이전트
    dp = static_potential_gradient(policy, pos)   # 정적 환경 성분(기본 0)
    α1 = rvo_get_agent_alpha(agent)               # 내 우선순위
    for other_agent in rvo_active_agents(scene_tree)   # 활성 상대 에이전트들 순회
        if !(agent === other_agent)               # 자기 자신 제외
            α2 = rvo_get_agent_alpha(other_agent) # 상대 우선순위
            if α1 <= α2 # can't be pushed by other agent (우선순위 높은 상대에겐 안 밀림)
                continue                          # `continue` = 이 반복 건너뜀(파이썬과 동일)
            end
            other_policy = env.agent_policies[node_id(other_agent)].dispersion_policy  # 상대 정책 조회
            other_rad = other_policy.agent_radius                          # 상대 반경
            scale = 1.0                                                    # 반발 세기 배율(현재 1)
            other_pos = project_to_2d(global_transform(other_agent).translation)  # 상대 위치 2D
            if norm(pos - other_pos) <= policy.interaction_radius  # 가까운 상대만
                # `.+` 는 브로드캐스트 덧셈(원소별). 상대로부터의 반발 gradient 를 누적.
                dp = dp .+ scale * pairwise_potential_gradient(
                    policy,
                    pos,
                    other_pos,
                    other_rad; # + dilate based on priority?
                    dr=other_policy.buffer_radius,  # 상대의 버퍼만큼 반발폭 확장
                )
            end
        end
    end
    return dp                                     # 총 포텐셜 gradient ∇U(pos)
end
# 속도명령 = -∇U 를 vmax 로 클립한 것(gradient descent: 포텐셜이 낮아지는 방향으로 이동).
function compute_velocity_command!(policy::PotentialFieldController, env::PlannerEnv, pos)
    dp = compute_potential_gradient!(policy::PotentialFieldController, env, pos)  # 총 gradient
    vel = clip_velocity(-1.0 * dp, policy.vmax)   # -gradient 방향, 속도 제한
    return vel
end


# (구버전/실험용) 로봇 하나의 상태·포텐셜을 담는 제어기. @with_kw 로 키워드 생성자 자동 생성.
@with_kw mutable struct PotentialController
    x = nothing # state
    v = nothing # velocity
    circ_idx = -1      # index of circle that robot may enter
    goal = nothing # goal position
    p = nothing # potential function
    dp = nothing # gradient of potential function
    radius = nothing # radius
    vmax = 1.0
end
ROBOT_RADIUS = 0.5    # 전역 상수: 기본 로봇 반경

# (구버전/실험용) 모든 로봇의 제어기와 포텐셜들을 모아 두는 전역 컨테이너. Dict() = 파이썬 dict.
@with_kw mutable struct GlobalPotentialController
    robot_controllers = Dict()        # 로봇별 제어기
    goal_potentials = Dict()          # 로봇별 목표 유인 포텐셜
    circle_potentials = Dict()        # 원(금지구역) 반발 포텐셜
    collision_potentials = Dict()     # 충돌 회피 포텐셜
    path_potentials = Dict()          # 경로 관련 포텐셜
    INTERACTION_RANGE = 5 * ROBOT_RADIUS   # 상호작용 고려 거리
end

# 모든 로봇 제어기를 한 번씩 갱신. 끝에 controller 를 그대로 반환(return 생략 가능 — 마지막 식이 반환값).
function update_potential_controllers!(controller)
    for (k, robot) in controller.robot_controllers    # (로봇키, 로봇) 쌍 순회
        update_potential_controller!(robot, k, controller)  # 각 로봇 갱신
    end
    controller                                        # 마지막 식 = 반환값
end
# 로봇 하나의 포텐셜 목록을 구성하고, gradient descent 로 속도를 정한다.
function update_potential_controller!(robot, i, global_controller)
    # i is the robot's index
    potentials = []                                   # 빈 배열(파이썬 [])
    C = global_controller                             # 줄여 쓰기용 별칭
    # pull robot toward its goal
    # `push!` = 배열 끝에 추가(파이썬 list.append). 이름 끝 `!` = 배열을 직접 수정.
    push!(potentials, C.goal_potentials[i])           # 목표 유인 포텐셜 추가
    # repel robot from circles in which it does not belong
    if robot.circ_idx > 0                             # 들어가면 안 되는 원이 지정돼 있으면
        push!(potentials, C.circle_potentials[robot.circ_idx])  # 그 원 반발 포텐셜 추가
    end
    # allow higher priority robots to push robot out of the way
    for (k, r) in C.robot_controllers                 # 다른 모든 로봇 순회
        p = C.path_potentials[k]                      # 그 로봇 경로 포텐셜
        if !(robot === r) && norm(r.x - robot.x) <= C.INTERACTION_RANGE  # 자신 아니고 가까우면
            if r.circ_idx < robot.circ_idx # replace with priority check (상대 우선순위 높으면)
                push!(potentials, p)                  # 그 로봇에게 밀리도록 포텐셜 추가
            end
        end
    end
    # set potentials
    robot.p = potentials                              # 구성한 포텐셜 목록 저장
    # compute local gradient of potential fields
    robot.dp = potential_gradient(robot.p, robot.x)   # 현재 위치에서의 ∇U
    # set velocity in direction of gradient descent
    vel = -1.0 * robot.dp                             # -∇U 방향으로 이동(하강)
    if norm(vel) > robot.vmax
        robot.v = robot.vmax * normalize(vel)         # 속도 제한
    else
        robot.v = vel                                 # 한도 내면 그대로
    end
    return robot                                      # 갱신된 로봇 반환
end
