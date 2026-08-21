# =============================================================================
# derive.jl — `s` 의 **파생 접근자**. 상태에서 뺀 값을 필요할 때 다시 만든다(spec §2-6).
#
# 🔴 여기서 새 분류 규칙을 만들지 않는다. 모드는 hazard 의 `_hz_modes` 와 **같은 두 출처**만
#    본다: 어떤 노드가 활성인가(= `s`) · 그 노드를 누가 맡는가(= `_responsible_robots`).
#    다시 분류하면 경량 레인과 무거운 레인의 λ 가 갈린다.
#
# 🔴 **팀 명부를 `s.g.binding` 에서 유도하지 않는다** (2026-08-21 T7 정정, spec §2-6 의 결함).
#    `_responsible_robots(node)` 는 팀 **전원**을 돌려주는데 `simstate_of` 는 그 중 한 명만
#    `binding[v]` 에 적는다(`observe.jl`: `first(sort(rs; by = string))`). binding 으로 팀을
#    유도하면 나머지 팀원이 전부 `:idle` 로 분류되고, `mult_idle = 0.10` vs `mult_carry = 2.0`
#    이므로 그 로봇들의 λ 가 **20배** 틀어진다. 팀 구성은 하위 계층의 관할이고 `s` 의
#    상태가 아니다 — 그래서 `mode_of` 의 시그니처가 애초에 `env` 를 받는다.
# =============================================================================

"""
    active_of(s::SimState) -> Set{Int}

지금 진행 중인 스케줄 정점 = **모든 선행이 닫혔고 자신은 안 닫힌 정점**.
실측 근거: `essential_tg_coponents.jl:1908-1932` 의 활성화 규칙이 정확히 이것이다
(후속 `v2` 의 모든 선행 `v1` 이 `closed_set` 에 있으면 `active_set` 에 넣는다).

⚠️ 알려진 한계: 어떤 간선에도 닿지 않는 고립 정점은 `s.g.edges` 에 흔적이 없어 여기서
보이지 않는다. `test/smdp_derive.jl` 이 120 스텝 전 구간에서 엔진의 `cache.active_set` 과의
동등성을 단언하므로, 그런 정점이 생기면 그 단언이 먼저 빨개진다.
"""
function active_of(s::SimState)
    preds = Dict{Int,Vector{Int}}()
    verts = Set{Int}()
    for (u, v) in s.g.edges
        push!(verts, u); push!(verts, v)
        push!(get!(preds, v, Int[]), u)
    end
    union!(verts, s.prog.closed)
    return Set(v for v in verts
               if !(v in s.prog.closed) &&
                  all(u -> u in s.prog.closed, get(preds, v, Int[])))
end

# 모드 우선순위. `_hz_modes`(hazard.jl:408) 의 `rank` 과 **같은 순서**여야 한다:
# 운반 > 조작 > 이동 > 대기. 한 로봇이 여러 활성 노드에 걸리면 더 무거운 쪽을 채택한다.
_mode_rank(m::Symbol) = m === :carry ? 3 : m === :manip ? 2 : m === :transit ? 1 : 0

"""
    modes_of(s::SimState, env) -> Dict{Int,Symbol}

`s.fleet` **전원**의 모드를 한 번의 순회로 낸다 — `active_of(s)` 를 딱 한 번만 계산한다.
`mode_of` 도 `rate_params` 도 이것 하나를 부른다(단일 분류기).

복잡도: `O(|edges| + Σ_{v ∈ active} |team(v)| · log + |fleet| log|fleet|)`.
🔴 **로봇 수에 대해 선형이지 이차가 아니다.** 계획서의 `mode_of` 는 로봇마다 `active_of(s)`
를 다시 만들어 배치 경로가 `O(|fleet| · |edges|)` 였다 — Task T9 의 rate boundary 가
로봇당 세 번씩 부르므로 그 자리에서 예산을 다 쓴다.
"""
function modes_of(s::SimState, env)
    out = Dict{Int,Symbol}(k => :idle for k in keys(s.fleet))
    for v in sort!(collect(active_of(s)))
        Graphs.has_vertex(env.sched, v) ||
            error("modes_of: 정점 $(v) 가 env.sched 에 없다 — `s` 와 스케줄이 다른 세계다. " *
                  "조용히 건너뛰지 않는다(그러면 그 노드의 팀 전원이 :idle 로 샌다)")
        node = get_node(env.sched, v).node
        m = _node_mode(node)                        # battery.jl: IDLE/TRANSIT/CARRY/MANIPULATE
        m == IDLE && continue
        sym  = m == TRANSIT ? :transit : (m == CARRY ? :carry : :manip)
        rank = _mode_rank(sym)
        # ⚠️ `_responsible_robots` 는 팀 노드에서 `collect(keys(robot_team(node)))` 라
        # **정렬돼 있지 않다**(Dict 순회 순서). 정렬해서 돈다 — 시드 고정 = 완전 재현.
        for id in sort!(collect(_responsible_robots(node)); by = string)
            k = _int_key(id)
            # `s.fleet` 밖의 로봇은 이미 `_hz_excluded()` 로 걸러진 것이다(spec §2-4).
            # 여기서 다시 거르는 게 아니라, 위험에 노출되지 않은 로봇에 모드를 붙이지 않을 뿐이다.
            haskey(out, k) || continue
            rank > _mode_rank(out[k]) && (out[k] = sym)
        end
    end
    return out
end

"""
    mode_of(s::SimState, env, k::Int) -> Symbol

로봇 `k`(= `s.fleet` 의 키)의 전력·위험 모드 — `:idle | :transit | :carry | :manip`.
`modes_of` 의 얇은 래퍼다(Task T6 이 `hazard_rate` 를 `hazard_rate_from` 의 래퍼로 둔 것과
같은 이유: 두 경로가 **구성상** 같은 값을 낸다).

🔴 `s.fleet` 에 없는 로봇은 `:idle` 로 떨어뜨리지 않고 **에러다.** 없는 로봇은 위험에서
빠져 있다는 뜻이고, 그것을 대기 중인 로봇과 한 값으로 합치면 두 레인이 서로 다른 집합 위에서
위험을 적분한다.
"""
function mode_of(s::SimState, env, k::Int)
    haskey(s.fleet, k) ||
        error("mode_of: 로봇 $(k) 가 s.fleet 에 없다 — `_hz_excluded()` 로 이미 빠진 로봇이거나 " *
              "다른 세계의 키다. :idle 로 떨어뜨리지 않는다")
    return modes_of(s, env)[k]
end

"""
    rate_params(s, env, p, bp, capacity_J) -> Dict{Int,NTuple{2,Float64}}

`s.fleet` **전부**의 `(A, a)`. 🔴 여기서 `role`/`health` 로 거르지 않는다 — 멤버십이 이미
`_hz_excluded()` 로 걸러져 있다(spec §2-4). 거르면 두 번 거르는 것이고, 그 둘이 어긋나면
게이트 N-G1 이 서로 다른 집합을 비교하게 된다.

⚠️ 계획서는 이 함수를 `rates.jl` 에 두라고 적었지만, `env` 를 받으므로 여기(scene 을 보는
레인)에 둔다. `rates.jl` 이 순수 수학으로 남는 것이 분리의 **이유**다.
"""
function rate_params(s::SimState, env, p::HazardParams,
                     bp::BatteryParams, capacity_J::Float64)
    modes = modes_of(s, env)                      # 🔴 로봇마다가 아니라 딱 한 번
    out = Dict{Int,NTuple{2,Float64}}()
    for k in sort!(collect(keys(s.fleet)))
        out[k] = rate_params_one(p, s.fleet[k], modes[k], bp, capacity_J)
    end
    return out
end
