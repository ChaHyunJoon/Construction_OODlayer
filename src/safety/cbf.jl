# =============================================================================
#  cbf.jl -- L1 CONTINUOUS SAFETY FILTER (Control Barrier Function, QP form)
#            + L0 BACKUP CONTROLLER (the real line-stop)
# =============================================================================
#
# WHERE THIS SITS IN THE SAFETY STACK
# -----------------------------------
#   L3  latent / learned      surrogate value ranking      COST, never safety
#   L2  symbolic shield       verifier.jl admit/reject     schedule-level consistency
#   L1  continuous CBF-QP     >>> THIS FILE <<<            physical safety, LLM-independent
#   L0  backup controller     >>> THIS FILE <<<            always-available safe action
#
# The contract between layers: **safety claims are sourced from L1/L0 ONLY.** L3 is a learned
# component and is known to be unreliable on novel disturbance classes (see the LOKO benchmark
# in wm4spacecraft_manufacturing/openworld_experiments.py loko). Sourcing safety from a learned layer
# would make every safety claim only as strong as the training distribution. Sourcing it here
# instead means: whatever the LLM proposes, whatever the surrogate ranks, and even if BOTH
# produce nothing at all, the physical no-go invariant still holds.
#
# HOW THIS RELATES TO THE EXISTING TELEPORT (corrected -- read this before claiming otherwise)
# --------------------------------------------------------------------------------------------
# `enforce_restriction_zone_clearance!` (route_planning.jl) also enforces the no-go discs, but it
# does so AFTER `sim.doStep()` by **snapping the robot's position** to the zone boundary:
#
#     pos = c .+ safe_r .* direction ;  rvo_set_agent_position!(agent, pos)
#
# That is a state jump, not a control action: physically unrealisable, blind to other robots,
# silent about the interval between samples, and offering no safe set for a fallback to aim at.
#
# It is TEMPTING to conclude "so the CBF filter replaces it". THAT WAS CLAIMED HERE AND IT IS
# WRONG -- tools/cbf_sim_eval.jl measured it and the claim failed:
#
#     arm       zone teleports   deepest snap      cbf violations seen by the filter
#     CBF_OFF        2            0.5513189724               --
#     CBF_ON         2            0.5513189724                0
#
# Identical to ten decimal places, and the filter never observed h < 0. The teleports were not
# robots DRIVING into a zone; they were an INITIAL CONDITION -- the zone was created on top of
# already-parked robots. A velocity filter cannot undo a violation that exists before any
# velocity is commanded, and it should not pretend to.
#
# The two mechanisms cover DIFFERENT failure modes:
#     dynamic entry  (a robot moves toward a zone)   -> this filter, by shaping the command
#     initial violation (a zone appears on a robot)  -> the snapper, or this file's infeasible-
#                                                       recovery path (which the loop order
#                                                       currently never reaches, see below)
#
# A second measured fact worth recording: across both evaluated scenarios there were ZERO dynamic
# zone violations even with the filter off. The existing navigation stack (TangentBug + potential
# field) already avoids zones in practice. So the value of this layer is NOT "it fixes existing
# violations" -- it is:
#   1. a GUARANTEE (forward invariance of {h >= 0}) rather than an empirical observation that a
#      heuristic happened to keep robots out;
#   2. it makes L0 real -- v = 0 is provably feasible, so fail-closed stops being nominal;
#   3. physical safety holds INDEPENDENTLY of the LLM and the surrogate -- including when they
#      propose nothing at all, which is the case the whole open-world argument rests on;
#   4. measured cost ~0 (identical closed-node count; 0.1-0.3% of commands modified).
# Item 3 is the one that matters for this project's safety argument.
#
# The filter acts on the COMMANDED VELOCITY before the step:
#
#     h(p)  = ||p - c|| - (R_zone + r_robot + margin)          >= 0  is "safe"
#     h'(p) = (p-c)/||p-c|| . v
#     CBF   : h' >= -alpha * h        (forward invariance of {h >= 0})
#
# rewritten as a linear constraint on v:  a . v <= b,  a = -(p-c)/||p-c||,  b = alpha*h.
#
# Then the filter is the projection
#
#     v* = argmin_v ||v - v_pref||^2   s.t.   a_i . v <= b_i  for every active zone i
#
# and the robot is commanded v* instead of v_pref. Nothing teleports.
#
# WHY L0 IS PROVABLY AVAILABLE (this is the key property)
# -------------------------------------------------------
# At v = 0 every constraint reads  0 <= alpha*h_i, which holds **iff h_i >= 0**. So as long as
# the system is currently safe, THE ZERO VELOCITY IS ALWAYS A FEASIBLE POINT of the QP. The QP
# can therefore never be infeasible while safe, and "stop everything" is a always-available
# recovery action. That is exactly what a CBF backup controller needs, and it is why
# `engage_fallback!` -- which until now only set a flag nothing ever read (see PATCHES.md:95,
# "make RESPEC_HOLD[] actually zero RVO preferred") -- can now be given real teeth by routing
# it through `cbf_hold!(true)`.
#
# If we ever start already-violating (h < 0, e.g. a zone is injected ON TOP of a robot), the QP
# may be infeasible; the filter then returns the RECOVERY velocity -- radially outward from the
# most-violated zone, i.e. "drive to the nearest point of the safe set", which is precisely the
# behaviour `engage_fallback!`'s own docstring promised for "when CBF/HJ reachability lands".
#
# NO NEW DEPENDENCIES
# -------------------
# The QP is 2-D with a handful of linear constraints, so it is solved EXACTLY by enumerating
# active sets (unconstrained point, each single-constraint projection, each pair intersection)
# and taking the feasible candidate closest to v_pref. Adding OSQP/JuMP-QP would risk the
# Julia 1.10 manifest (see memory: Pkg.add under 1.12 silently breaks the build), and would be
# absurd overkill for a 2x2 system.
#
# INERT BY DEFAULT
# ----------------
# `CBF_ENABLED[] = false` out of the box, mirroring the repo convention for every added seam
# (RESPEC_ENABLED, SOC_SPEED_HOOK, BATTERY_STEP_HOOK, monitor). A normal run is byte-identical
# until someone calls `enable_cbf!()`.
#
# -----------------------------------------------------------------------------
# [한국어 설명]
# 이 파일이 하는 일: 로봇에게 내릴 "속도 명령"을 실행 직전에 걸러서(filter) 절대 금지구역에
#   들어가지 못하게 만든다. 이것이 안전층 4단 중 L1(연속 물리 안전)과 L0(최후 정지)이다.
#
# 왜 필요한가: 기존 코드(enforce_restriction_zone_clearance!)는 RVO가 한 스텝 움직인 "뒤에"
#   구역 안에 들어간 로봇을 경계로 **순간이동**시켜 규칙을 지킨다. 이건 제어가 아니라 상태 조작이라
#   ① 실제 로봇은 순간이동 불가 ② 다른 로봇 위로 튀어 들어갈 수 있음 ③ 스텝 사이 구간은 보장 못 함
#   ④ "안전집합"이라는 개념이 없어 fallback 이 목표로 삼을 지점이 없음.
#
# CBF 는 이걸 "속도를 미리 깎는" 방식으로 푼다:
#   h(p) = (로봇~구역중심 거리) - (구역반지름+로봇반지름) ≥ 0 이면 안전.
#   h 가 0 에 가까워질수록 그쪽으로 가는 속도성분을 줄이도록 강제(h' ≥ -α·h).
#   그 조건은 속도 v 에 대한 1차 부등식이 되므로, "원하는 속도 v_pref 에서 가장 가까우면서
#   부등식을 만족하는 v" 를 구하는 2차계획(QP)으로 풀린다.
#
# 핵심 성질: v=0 을 넣으면 부등식이 "0 ≤ α·h" 가 되어 **현재 안전하기만 하면 항상 성립**한다.
#   즉 "전부 정지"는 언제나 실행 가능한 안전행동이고, 그래서 L0(라인스톱)이 원리적으로 보장된다.
#   지금까지 engage_fallback! 은 아무도 안 읽는 플래그만 켰는데(PATCHES.md:95 의 미해결 TODO),
#   이제 이 필터를 통해 진짜로 로봇을 멈출 수 있다.
#
# 의존성 추가 없음: 2차원 QP 는 제약이 몇 개뿐이라 (무제약해 / 각 제약에 수직투영 / 두 제약 교점)
#   후보를 전부 따져 가장 가까운 실행가능점을 고르면 **정확해**가 나온다. 솔버 패키지 불필요.
#
# 기본 비활성: CBF_ENABLED[]=false 라 enable_cbf!() 를 부르기 전엔 기존 동작과 완전히 동일하다.
#
# [Julia 문법 참고]
#   · Ref(x)        : 값을 담는 가변 상자. 내용은 `상자[]` 로 읽고 쓴다(전역 설정용 관례).
#   · Base.@kwdef   : 필드 기본값을 주는 구조체 매크로.
#   · @inbounds     : 배열 범위검사 생략(성능). 인덱스가 안전함이 확실할 때만.
#   · `a \ b`       : 선형계 A x = b 풀이(여기선 2x2).
#   · nothing       : 파이썬의 None.
#   · `f!` 이름      : 인자/전역 상태를 직접 바꾸는 함수라는 관례.
# =============================================================================

# ---- configuration knobs (all module-level Refs; PlannerEnv stays immutable) -------------

"Master switch. `false` (default) = this file is completely inert; runs are unchanged."
const CBF_ENABLED = Ref(false)

"""
CBF class-K gain `alpha` in  h' >= -alpha*h.

Bigger alpha = the robot is allowed to approach the boundary faster (less conservative, but the
velocity must be cut harder at the last moment). Smaller alpha = it starts slowing down from
further away. 2.0 is a mild default for the ~1 m/s, dt~0.1 s regime of this simulator.
(값이 클수록 경계 가까이까지 빨리 접근 허용, 작을수록 멀리서부터 미리 감속.)
"""
const CBF_ALPHA = Ref(2.0)

"Extra clearance added on top of (zone radius + robot radius), in metres."
const CBF_MARGIN = Ref(0.0)

"""
L0 line-stop. When `true` the filter commands ZERO velocity for every agent.

This is the always-available safe action proved above (v=0 satisfies every CBF constraint while
h >= 0). `engage_fallback!` routes through `cbf_hold!` so that the fail-closed path in
replan.jl actually stops the robots instead of only setting an unread flag.
"""
const CBF_HOLD = Ref(false)

"Also enforce robot-robot separation (OFF by default: RVO already handles inter-agent avoidance,
and stacking a hard CBF on top of it can deadlock a dense formation). Kept as an opt-in axis."
const CBF_INTER_AGENT = Ref(false)

"Fallback robot radius when an agent's cached hypersphere geometry is unavailable."
const CBF_DEFAULT_RADIUS = Ref(0.5)

# ---- statistics (evidence, not decoration) -----------------------------------------------
# These counters exist so claims about this filter are MEASURED rather than asserted. They are
# what falsified the original "the filter replaces the teleport" claim (see the header): with the
# filter on, `zone_snaps` did NOT drop, while `violations` stayed 0 -- proving the remaining
# snaps were initial-condition violations the filter never had a chance to prevent.
# Report `min_h` and `violations` from an actual run; do not infer safety from "it was enabled".
# (이 계수기들이 "필터가 텔레포트를 대체한다"는 최초 주장을 반증했다: 필터를 켜도 텔레포트 수는
#  그대로였고 violations 는 0 이었다 = 남은 침범은 필터가 손댈 수 없는 초기조건이었다는 뜻.
#  "켜 놨으니 안전하다"가 아니라 실제 실행의 min_h/violations 를 재서 보고할 것.)
const CBF_STATS = Ref(Dict{Symbol,Any}(
    :calls          => 0,      # 필터가 불린 횟수
    :modified       => 0,      # 실제로 속도를 깎은 횟수
    :held           => 0,      # L0 정지로 0 을 반환한 횟수
    :infeasible     => 0,      # 이미 침범 상태라 복구 속도를 반환한 횟수
    :min_h          => Inf,    # 관측된 최소 barrier 값(음수면 침범)
    :violations     => 0,      # 필터 호출 시점에 h<0 이던 횟수
    :total_cut      => 0.0,    # 깎인 속도 크기의 누적합(보수성 비용의 척도)
))

cbf_stats() = CBF_STATS[]

"Reset the counters (call at the start of a measured run)."
function reset_cbf_stats!()
    CBF_STATS[] = Dict{Symbol,Any}(:calls => 0, :modified => 0, :held => 0, :infeasible => 0,
                                   :min_h => Inf, :violations => 0, :total_cut => 0.0)
    return nothing
end

_bump!(k, v = 1) = (CBF_STATS[][k] = CBF_STATS[][k] + v)

"""
    enable_cbf!(; alpha, margin, inter_agent)

Turn the L1 filter on. Idempotent; also resets the statistics so a measured run starts clean.
"""
function enable_cbf!(; alpha::Real = CBF_ALPHA[], margin::Real = CBF_MARGIN[],
                       inter_agent::Bool = CBF_INTER_AGENT[])
    CBF_ENABLED[] = true
    CBF_ALPHA[] = Float64(alpha)
    CBF_MARGIN[] = Float64(margin)
    CBF_INTER_AGENT[] = inter_agent
    reset_cbf_stats!()
    @info "[CBF] L1 velocity filter ENABLED" alpha = CBF_ALPHA[] margin = CBF_MARGIN[] inter_agent
    return nothing
end

"Turn the filter off and release any line-stop."
function disable_cbf!()
    CBF_ENABLED[] = false
    CBF_HOLD[] = false
    return nothing
end

"""
    cbf_hold!(on::Bool)

Engage / release the L0 line-stop. `on=true` makes the filter return zero velocity for every
agent on every call -- the always-available safe action. This is what gives `engage_fallback!`
real physical effect.
"""
function cbf_hold!(on::Bool = true)
    CBF_HOLD[] = on
    on && @warn "[CBF] L0 LINE-STOP engaged: all agents commanded to zero velocity."
    return nothing
end

# =============================================================================
#  Exact 2-D QP:  min ||v - p||^2   s.t.  A v <= b
# =============================================================================
# For a strictly convex QP the optimum is either the unconstrained point, or lies on the
# boundary of one active constraint (perpendicular projection), or at the intersection of two.
# In 2-D that is the COMPLETE candidate set, so enumerating it is exact -- no iteration, no
# tolerance tuning, no solver dependency.
#
# (2차원에서는 최적점이 ① 무제약해 ② 한 제약면에 수직투영한 점 ③ 두 제약면의 교점 중 하나다.
#  후보가 유한하므로 전부 검사해 실행가능한 것 중 가장 가까운 것을 고르면 정확해가 된다.)

"제약 A v <= b 를 tol 오차 안에서 모두 만족하는가."
function _qp_feasible(v, A, b; tol = 1e-9)
    @inbounds for i in eachindex(b)
        if A[i][1] * v[1] + A[i][2] * v[2] > b[i] + tol
            return false
        end
    end
    return true
end

"""
    solve_qp2d(p, A, b) -> (v, ok)

Closest point to `p` inside the polyhedron {v : a_i . v <= b_i}. `A` is a vector of 2-tuples /
2-vectors, `b` a vector of scalars. Returns `(v, true)` on success, `(p, false)` if the
polyhedron is empty (which, per the note above, can only happen when some h_i < 0).
"""
function solve_qp2d(p::AbstractVector{<:Real}, A::AbstractVector, b::AbstractVector{<:Real})
    pv = Float64[p[1], p[2]]
    isempty(b) && return (pv, true)                      # 제약이 없으면 원하는 속도 그대로

    best = nothing
    bestd = Inf

    # ---- 후보 ①: 무제약해 = p 자신 --------------------------------------------------------
    if _qp_feasible(pv, A, b)
        return (pv, true)                                # 이미 만족하면 그게 최적 (깎을 필요 없음)
    end

    m = length(b)

    # ---- 후보 ②: 각 제약면에 수직투영 ------------------------------------------------------
    @inbounds for i in 1:m
        ai = Float64[A[i][1], A[i][2]]
        n2 = ai[1]^2 + ai[2]^2
        n2 < 1e-18 && continue                           # 퇴화한 제약(법선 0)은 건너뜀
        # v = p - a*(a.p - b)/||a||^2  : a.v = b 인 직선 위의 가장 가까운 점
        s = (ai[1] * pv[1] + ai[2] * pv[2] - b[i]) / n2
        v = Float64[pv[1] - s * ai[1], pv[2] - s * ai[2]]
        if _qp_feasible(v, A, b)
            d = (v[1] - pv[1])^2 + (v[2] - pv[2])^2
            if d < bestd
                bestd = d; best = v
            end
        end
    end

    # ---- 후보 ③: 두 제약면의 교점 ---------------------------------------------------------
    @inbounds for i in 1:(m - 1), j in (i + 1):m
        a1 = Float64[A[i][1], A[i][2]]
        a2 = Float64[A[j][1], A[j][2]]
        det = a1[1] * a2[2] - a1[2] * a2[1]              # 2x2 행렬식
        abs(det) < 1e-12 && continue                     # 두 면이 평행하면 교점 없음
        # 크래머 공식으로 a1.v=b_i, a2.v=b_j 를 푼다.
        vx = (b[i] * a2[2] - a1[2] * b[j]) / det
        vy = (a1[1] * b[j] - b[i] * a2[1]) / det
        v = Float64[vx, vy]
        if _qp_feasible(v, A, b)
            d = (v[1] - pv[1])^2 + (v[2] - pv[2])^2
            if d < bestd
                bestd = d; best = v
            end
        end
    end

    best === nothing && return (pv, false)               # 실행가능 영역이 비었음(이미 침범 상태)
    return (best, true)
end

# =============================================================================
#  Barrier construction
# =============================================================================

"에이전트의 물리 반지름(캐시된 구 기하). 없으면 기본값."
function cbf_agent_radius(agent)
    try
        return Float64(get_radius(get_cached_geom(agent, HypersphereKey())))
    catch
        try
            return Float64(default_robot_radius())
        catch
            return CBF_DEFAULT_RADIUS[]
        end
    end
end

"""
    cbf_zone_barriers(pos, r) -> Vector{(h, grad)}

For every ACTIVE no-go zone, the barrier value `h = ||p-c|| - (R + r + margin)` and its gradient
`(p-c)/||p-c||`. `h >= 0` means "outside the zone by at least the clearance".
"""
function cbf_zone_barriers(pos::AbstractVector{<:Real}, r::Real)
    out = Tuple{Float64,Vector{Float64}}[]
    isempty(RESTRICTION_ZONES[]) && return out
    px, py = Float64(pos[1]), Float64(pos[2])
    for (_, zone) in active_restriction_zones()
        c = get_center(zone)
        dx = px - Float64(c[1]); dy = py - Float64(c[2])
        d = sqrt(dx * dx + dy * dy)
        R = Float64(get_radius(zone))
        h = d - (R + Float64(r) + CBF_MARGIN[])
        # 중심에 정확히 겹친 퇴화 상황이면 임의 방향(+x)으로 밀어낸다.
        g = d > 1e-9 ? Float64[dx / d, dy / d] : Float64[1.0, 0.0]
        push!(out, (h, g))
    end
    return out
end

"""
    cbf_interagent_barriers(agent, pos, r) -> Vector{(h, grad)}

Optional robot-robot separation barriers. Responsibility is shared 50/50 with the other agent
(the standard decentralised-CBF convention), which is why the gradient is halved: each robot
takes half the burden of keeping the pair apart. OFF by default.
(선택적 로봇-로봇 이격. 상대도 스스로 피하므로 책임을 절반씩 나눈다 = 기울기를 1/2.)
"""
function cbf_interagent_barriers(agent, pos::AbstractVector{<:Real}, r::Real)
    out = Tuple{Float64,Vector{Float64}}[]
    CBF_INTER_AGENT[] || return out
    px, py = Float64(pos[1]), Float64(pos[2])
    me = try node_id(agent) catch; nothing end
    for id in get_vtx_ids(rvo_global_id_map())
        id === me && continue
        other = try get_node(scene_tree_for_cbf(), id) catch; continue end
        q = try collect(Float64, rvo_get_agent_position(other)) catch; continue end
        ro = cbf_agent_radius(other)
        dx = px - q[1]; dy = py - q[2]
        d = sqrt(dx * dx + dy * dy)
        h = d - (Float64(r) + ro + CBF_MARGIN[])
        g = d > 1e-9 ? Float64[dx / (2d), dy / (2d)] : Float64[0.5, 0.0]   # 1/2 = 책임 분담
        push!(out, (h, g))
    end
    return out
end

# Inter-agent barriers need the scene tree; it is set once per run by the sim loop when the
# option is on, so the filter stays a pure function of (agent, v_pref) at the call site.
const CBF_SCENE_TREE = Ref{Any}(nothing)
scene_tree_for_cbf() = CBF_SCENE_TREE[]
set_cbf_scene_tree!(t) = (CBF_SCENE_TREE[] = t; nothing)

# =============================================================================
#  The filter
# =============================================================================

"""
    cbf_filter_velocity(agent, v_pref; max_speed) -> v_safe

THE L1 SAFETY FILTER. Returns the velocity actually commanded to `agent`.

Order of business:
  1. inert if disabled                     -> v_pref unchanged
  2. L0 line-stop engaged                  -> zero (always safe while h >= 0)
  3. build barriers, assemble  a.v <= b    with a = -grad(h), b = alpha*h
  4. solve the 2-D QP exactly
  5. infeasible (already violating)        -> RECOVERY: drive out of the worst zone
  6. rescale to `max_speed` if needed      -- safe, because scaling DOWN a solution keeps
                                              a.(s v) = s(a.v) <= s b <= b whenever b >= 0

(요약: ①꺼져있으면 그대로 ②정지명령이면 0 ③각 구역마다 부등식 만들고 ④2D QP 정확히 풀고
 ⑤이미 침범 중이면 바깥으로 탈출 속도 ⑥최대속도 초과시 축소 — 축소는 안전성 보존됨.)
"""
function cbf_filter_velocity(agent, v_pref; max_speed::Real = Inf)
    CBF_ENABLED[] || return v_pref                       # 비활성이면 원본 그대로(완전 무해)

    vp = Float64[Float64(v_pref[1]), Float64(v_pref[2])]
    _bump!(:calls)

    # ---- (2) L0: 전면 정지 ---------------------------------------------------------------
    if CBF_HOLD[]
        _bump!(:held)
        norm_vp = sqrt(vp[1]^2 + vp[2]^2)
        _bump!(:total_cut, norm_vp)
        return (0.0, 0.0)
    end

    pos = try collect(Float64, rvo_get_agent_position(agent)) catch
        return v_pref                                    # 위치를 못 읽으면 개입하지 않음(안전한 no-op)
    end
    r = cbf_agent_radius(agent)

    # ---- (3) barrier -> 선형 제약 ---------------------------------------------------------
    bars = cbf_zone_barriers(pos, r)
    append!(bars, cbf_interagent_barriers(agent, pos, r))
    isempty(bars) && return v_pref                       # 활성 구역이 없으면 필터할 것도 없음

    A = Vector{Vector{Float64}}()
    b = Float64[]
    alpha = CBF_ALPHA[]
    worst_h = Inf; worst_g = Float64[1.0, 0.0]
    for (h, g) in bars
        # h' = g.v >= -alpha*h   <=>   (-g).v <= alpha*h
        push!(A, Float64[-g[1], -g[2]])
        push!(b, alpha * h)
        if h < worst_h
            worst_h = h; worst_g = g
        end
    end
    if worst_h < CBF_STATS[][:min_h]
        CBF_STATS[][:min_h] = worst_h
    end
    worst_h < 0 && _bump!(:violations)

    # ---- (4) QP ---------------------------------------------------------------------------
    v, ok = solve_qp2d(vp, A, b)

    # ---- (5) 이미 침범 중이라 풀 수 없음 -> 안전집합으로 복귀하는 속도 ----------------------
    if !ok
        _bump!(:infeasible)
        sp = isfinite(max_speed) ? Float64(max_speed) : sqrt(vp[1]^2 + vp[2]^2)
        sp <= 0 && (sp = 1.0)
        v = Float64[worst_g[1] * sp, worst_g[2] * sp]    # 가장 깊이 침범한 구역의 바깥 방향으로
    end

    # ---- (6) 최대속도 제한 (하향 스케일은 제약을 보존한다) ----------------------------------
    if isfinite(max_speed) && max_speed > 0
        nv = sqrt(v[1]^2 + v[2]^2)
        if nv > max_speed
            s = max_speed / nv
            v = Float64[v[1] * s, v[2] * s]
        end
    end

    cut = sqrt((v[1] - vp[1])^2 + (v[2] - vp[2])^2)
    if cut > 1e-9
        _bump!(:modified)
        _bump!(:total_cut, cut)
    end
    return (v[1], v[2])
end

# =============================================================================
#  Certificate / audit helpers
# =============================================================================

"""
    cbf_certificate(env) -> NamedTuple

Audit the CURRENT state: the minimum barrier value over all agents and all active zones, and
how many agents are violating. This is the runtime evidence that the invariant held -- report
`min_h >= 0` rather than asserting safety from the fact that the filter was switched on.
(켜 놨으니 안전하다고 주장하지 말고, 실제 최소 h 를 재서 보고하기 위한 감사 함수.)
"""
function cbf_certificate(env)
    min_h = Inf
    n_viol = 0
    n_agents = 0
    for id in get_vtx_ids(rvo_global_id_map())
        agent = try get_node(env.scene_tree, id) catch; continue end
        pos = try collect(Float64, rvo_get_agent_position(agent)) catch; continue end
        n_agents += 1
        r = cbf_agent_radius(agent)
        for (h, _) in cbf_zone_barriers(pos, r)
            h < min_h && (min_h = h)
            h < 0 && (n_viol += 1)
        end
    end
    return (min_h = min_h, n_violations = n_viol, n_agents = n_agents,
            enabled = CBF_ENABLED[], hold = CBF_HOLD[])
end

"Pretty one-line summary of the filter's activity for a finished run."
function cbf_report()
    s = CBF_STATS[]
    return string("[CBF] calls=", s[:calls], " modified=", s[:modified],
                  " held=", s[:held], " infeasible=", s[:infeasible],
                  " violations=", s[:violations],
                  " min_h=", round(s[:min_h] == Inf ? NaN : s[:min_h], digits = 4),
                  " total_cut=", round(s[:total_cut], digits = 3))
end
