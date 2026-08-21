# =============================================================================
# tplan.jl — 논문 식 (4) 의 대응물. **경량 롤아웃 모델 그 자체**다(spec §5-4).
#
# 이 파일이 정하는 것 하나: **λ 가 구간상수인 구간의 경계가 어디인가.** `rates.jl` 의
# λ(t) = A·e^{a t} 는 "모드가 안 변하는 동안" 정확하다. 모드는 노드가 끝나야 변한다. 그래서
# `T_plan_next` 는 **결정 epoch 가 아니라 λ 의 구간상수 경계**이고(spec §2-4), 소저너 샘플러가
# 해석적으로 적분해도 되는 구간의 상한이다. 이 값을 넘어서 적분하면 그 뒤는 틀린 λ 다.
#
# ─────────────────────────────────────────────────────────────────────────────
# 🔴 D-6 (2026-08-21, 사용자 결정): **경과시간을 빼지 않는다.**
#
#    선행 설계는  rem = ρ·dur(v) − (s.prog.t − t0(v))  를 썼다. 두 가지로 죽는다:
#      1. `get_t0` 는 **MILP 가 계획한 시작 시각**이고, 레포의 호출자가 전부 `t = 0.0` 을
#         넘겨 `update_schedule_times!` 가 실질적으로 도달하지 않으므로 런 내내 0.0 에
#         붙박인다 — 실측(선행 완료 보고서): 활성 정점 **15/15 가 `rem ≤ 0`**.
#      2. ρ 로 못 고친다 — 활성의 **8/14 가 `min_duration == 0.0`** 이라 `ρ·0 − Δ ≤ 0` 이
#         **모든 ρ** 에 대해 참이다.
#    그리고 7필드 `s` 에는 애초에 시계가 없다(`ProgBlock` 은 `closed` 뿐이다). 그래서 뺄 것이
#    없다 — 이건 근사이기 이전에 **가용 정보의 한계**다.
#
#    🔴 **근사의 방향(부호)** — 이 자리에서 못박는다:
#      · 축 1 (D-6 이 만드는 편향): 진행 중인 노드의 **남은** 계획시간 대신 **전체** 계획시간을
#        쓴다 ⇒ `T_plan_next ≥ (남은 계획시간)`. 이 축에서는 **엄밀한 상한(over-estimate)** 이고,
#        경계를 늦게 잡으므로 λ 를 **한 구간 너무 길게** 상수로 취급한다.
#      · 축 2 (반대 부호의 교란): `min_duration = duration_lower_bound(node)` 는 **하한**이다.
#        실제 주행은 3계층 reactive 스택(TangentBug→PotentialField→RVO2)을 거치므로 더 길다.
#        이 축에서는 **과소평가**다.
#      ⇒ 두 축의 부호가 반대이므로 **실현 경계에 대한 순 부호는 선험이 아니라 실측**이다.
#        `test/smdp_tplan.jl` 끝의 "D-6 upper-bound bias" 블록이 그 비(pred/actual)를 재고,
#        게이트 **N-G1(Task T9)** 이 그 크기를 판정한다. 여기서 정확하게 만들려 하지 않는다.
#
#    ⚠️ **경량 모델은 혼잡·교착을 원리적으로 볼 수 없다.** ρ 가 축 2 의 격차를 흡수하는
#       스칼라이고, 그 값은 **Task T10 이 무거운 레인에 적합해서** 채운다(아래 `RHO`).
# ─────────────────────────────────────────────────────────────────────────────
#
# 🔴 이 파일은 로봇 모드를 **한 번도 보지 않는다** — 그래서 `mode_of` 를 로봇 루프에서
#    부르는 T7 리뷰의 금지(배치 경로를 이차로 되돌리는 것)에 애초에 걸리지 않는다. 경계는
#    "어떤 노드가 언제 끝나는가" 만으로 정해지고, 그건 스케줄의 성질이지 함대의 성질이 아니다.
#    복잡도는 `O(|active|)` (T_plan_next) · `O(|V| + |E|)` (T_done) 로 **함대 크기와 무관**하다.
#    ⚠️ 이 자리에 모드 조건("팀이 있는 노드만")을 넣고 싶어지면, 그때는 반드시
#    `modes_of`/`rate_params`(배치, 함대에 선형)를 쓸 것 — `mode_of` 를 루프에 넣지 말 것.
#
# 🔴 조용한 폴백 금지: 스케줄에 없는 정점 · 음수/비유한 소요시간은 `error()` 다. 0 이나
#    기본값으로 때우면 "짧은 노드가 있다" 와 "그 노드가 다른 세계의 것이다" 가 한 값으로 합쳐진다.
# =============================================================================

"""
    RHO :: Ref{Float64}

계획 소요시간 → 실현 소요시간의 보정 배수. `min_duration` 이 **하한**이라 실제는 항상 더 길고,
그 격차를 흡수하는 스칼라 하나다.

🔴 **현재 값 `1.0` 은 잠정(provisional) 기본값이고 적합된 값이 아니다.** 이 자리의 주인은
**Task T10 (게이트 N-G2)** 이고, 무거운 레인의 실현 시간에 적합해서 채운다. T8 은 그 값을
스스로 적합하지 않는다 — `1.0` 은 "보정 없음"이라는 뜻이지 "1.0 이 맞다"는 뜻이 아니다.
`T_plan_next`/`T_done` 이 ρ 에 대해 **정확히 선형**이므로(시험이 못박는다) T10 이 이 `Ref` 하나만
바꾸면 두 함수가 같이 움직인다.
"""
const RHO = Ref(1.0)

"""
    node_duration(env, v::Int) -> Float64

정점 `v` 의 **계획 소요시간**(ρ 보정 전 원값) = `get_min_duration(env.sched, v)`.

⚠️ 이름대로 **하한**이다(`task_assignment.jl:86` 이 `duration_lower_bound(node)` 를 넣는다).
실현 시간이 아니다 — 위 헤더의 "축 2".

🔴 폴백 없음: `env.sched` 에 없는 정점, 음수, 비유한 값은 전부 `error()`.
"""
function node_duration(env, v::Int)
    Graphs.has_vertex(env.sched, v) ||
        error("node_duration: 정점 $(v) 가 env.sched 에 없다 — `s` 와 스케줄이 다른 세계다. " *
              "0 으로 때우지 않는다(그러면 '즉시 끝나는 노드' 와 구분이 사라진다)")
    d = Float64(get_min_duration(env.sched, v))
    isfinite(d) ||
        error("node_duration: 정점 $(v) 의 min_duration = $(d) — 유한하지 않다. " *
              "스케줄 노드는 유한 시간에 끝난다는 가정이 깨졌다")
    d < 0.0 &&
        error("node_duration: 정점 $(v) 의 min_duration = $(d) < 0 — 음수 소요시간이다. " *
              "clamp 하지 않는다(경계가 조용히 과거로 간다)")
    return d
end

"""
    T_plan_next(s::SimState, env; rho = RHO[]) -> Float64

다음 모드 변화까지의 시간 = **활성 정점 중 가장 짧은 계획 소요시간**(ρ 배). 활성 정점은
`active_of(s)`(모든 선행이 닫혔고 자신은 안 닫힌 정점)다.

`dur == 0` 인 정점은 **후보에서 뺀다.** 0 을 돌려주면 `sample_sojourn` 이 전진하지 못하고
`n_boundary` 상한에서 죽거나 시뮬 시간 0 초 만에 DAG 를 통과한다. eps 로 클램프하는 것도 같은
자리에서 죽는다(1.8e-15 는 전진이 아니다) — 그래서 **뺀다**.

활성이 없거나 전부 `dur == 0` 이면 **`Inf`**: "이 구간 안에는 모드 변화가 없다" = 소저너
샘플러가 경계 없이 해석적으로 적분해도 된다. (`T_done` 의 대응 값은 `Inf` 가 아니라 `0.0` 이다
— 아래 그 docstring 을 볼 것. 두 함수가 서로 다른 질문에 답한다.)

⚠️ 이 값은 **결정 epoch 가 아니다.** 사건(고장·배터리)이 그 전에 터지면 소저너가 그것을 먼저
돌려준다. 여기서 재는 것은 λ 의 파라미터가 바뀌는 순간 하나뿐이다.

복잡도 `O(|s.g.edges| + |active| log|active|)` — **함대 크기와 무관**하다(헤더의 T7 리뷰 항목).
"""
function T_plan_next(s::SimState, env; rho::Float64 = RHO[])
    rho > 0.0 || error("T_plan_next: rho = $(rho) — 양수여야 한다(0 이면 경계가 즉시가 된다)")
    best = Inf
    # `active_of` 는 `Set` 을 돌려준다 — 순회 순서가 정의돼 있지 않다. 정렬해서 돈다:
    # 값(min)은 순서에 안 흔들리지만 **어느 정점이 먼저 error 를 내는지**가 흔들린다.
    for v in sort!(collect(active_of(s)))
        d = node_duration(env, v)         # 스케줄 밖 정점은 여기서 죽는다(폴백 없음)
        d > 0.0 || continue               # 🔴 dur == 0 은 경계 후보가 아니다
        rd = rho * d
        rd < best && (best = rd)
    end
    return best
end

"""
    T_done(s::SimState, env; rho = RHO[]) -> Float64

미완 스케줄 DAG 의 **longest path**(ρ 배) — 아무것도 고장 나지 않으면 언제 끝나는가.
닫힌 정점은 통째로 빼고, 남은 정점들의 유도 부분그래프에서 잰다.

**흡수상태(전부 닫힘)에서는 `0.0`.** 🔴 이것이 `T_plan_next` 의 `Inf` 에 대응하는 값이고,
둘의 방향이 반대인 것은 **두 함수가 서로 다른 질문에 답하기 때문**이다:
  · `T_plan_next` = "다음 경계까지 얼마나?" → 경계가 없으면 `Inf`(= 끝까지 적분해도 된다)
  · `T_done`      = "끝나기까지 얼마나?"   → 이미 끝났으면 `0.0`
`T_done` 을 `Inf` 로 두면 "끝났다" 와 "영원히 안 끝난다" 가 한 값으로 합쳐진다. 반대로
`T_plan_next` 를 `0.0` 으로 두면 소저너가 전진하지 못한다. 그래서 이 비대칭은 의도적이다.
남은 정점이 있는데 그 소요시간이 전부 0 이어도 `0.0` 이다(= 남은 일이 즉시 끝난다).

진행 중 노드의 잔여 보정을 **하지 않는다** — D-6 과 같은 이유(시계가 없다). 그래서 `T_done`
역시 같은 방향의 상한 편향을 갖는다(헤더의 축 1).

🔴 **순환 불가**: `Graphs.topological_sort_by_dfs` 는 사이클을 만나면
`error("The input graph contains at least one loop.")` 로 **죽는다**(Graphs 1.13.1,
`traversals/dfs.jl:104`). 조용히 돌지 않는다. 위상정렬이 선행을 먼저 내주므로 아래 루프의
`finish[u]` 는 항상 이미 채워져 있다 — 한 번 순회로 끝난다.

불변식: `T_plan_next(s, env; rho) ≤ T_done(s, env; rho)` 또는 `T_done == 0`. 활성 정점은
열려 있고 그 정점의 `finish` 가 이미 `ρ·dur` 이상이기 때문이다(시험이 400 스텝 전수로 못박는다).

복잡도 `O(|V| + |E|)`.
"""
function T_done(s::SimState, env; rho::Float64 = RHO[])
    rho > 0.0 || error("T_done: rho = $(rho) — 양수여야 한다")
    sched = env.sched
    closed = s.prog.closed
    any(v -> !(v in closed), Graphs.vertices(sched)) || return 0.0   # 흡수상태
    G      = get_graph(sched)
    finish = Dict{Int,Float64}()
    best   = 0.0
    for v in Graphs.topological_sort_by_dfs(G)      # 사이클이면 여기서 죽는다
        v in closed && continue
        head = 0.0
        for u in Graphs.inneighbors(G, v)
            u in closed && continue
            # 위상정렬 덕에 `u` 는 이미 처리됐다. `get` 폴백을 두지 않는다 — 없으면 순서
            # 가정이 깨진 것이고, 그건 조용히 0 으로 때울 일이 아니다.
            haskey(finish, u) ||
                error("T_done: 선행 $(u) 가 아직 안 풀렸다 — 위상정렬 가정이 깨졌다(정점 $(v))")
            head = max(head, finish[u])
        end
        f = head + rho * node_duration(env, v)
        finish[v] = f
        f > best && (best = f)
    end
    return best
end
