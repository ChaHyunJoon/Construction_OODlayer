# =============================================================================
# generative.jl — spec §5-1. **`G(s,a)`**: MCTS 가 `(s,a) → (s′, R, τ, event)` 를 표집하는
# 생성 시뮬레이터.
#
# 이 파일이 지키는 계약 넷:
#
#  1. **행동은 근사가 아니라 진짜 respec 이다**(spec D-2). `apply_action!` 은 실제 DAG·씬트리
#     편집을 부른다 — 그래야 "그 편집을 SMDP 로 모델링한다" 는 주장이 성립한다.
#  2. **조용한 폴백 금지.** 어휘 밖 id · 문지기에서 걸러진 팔 · 라인 스톱은 전부 `error()` 다.
#     🔴 특히 `ood_mdp_shim.action_to_proposal` 은 `a in valid_actions(ctx) || return nothing`
#     으로 **조용히 NOOP 팔로 무너진다**(.claude/CLAUDE.md 살아있는 결함 5번). 이 파일은 그
#     침묵을 **상속하지 않는다** — 집행할 수 없는 행동은 "결정처럼 보이는 무동작"이 아니라
#     이름 붙은 에러다.
#  3. **`rvo_rebuild!` 는 언제나 맨 마지막**(T11 의 핀 경고). RVO2 는 프로세스 전역이라
#     `deepcopy(env)` 가 격리하지 못한다 — 포크한 세계로 들어갈 때마다 다시 유도해야 한다.
#  4. **트리는 행동 경로로 색인한다. `state_hash` 로 색인하지 않는다** — 아래
#     `action_path_key` 의 docstring 이 그 측정된 근거를 들고 있다.
#
# 로드 순서: `mdp.jl` 이 `sojourn.jl` **다음**에 include 한다(sample_sojourn·advance_to·
# advance_to_rate_boundary·energy_between·_active_with_durations·_close_vertices 를 쓴다).
# =============================================================================

# --- 행동 어휘의 단일 진실원 배선 --------------------------------------------------------
#
# 🔴 **`src/` 안의 Julia 코드가 `ActionRegistry` 를 로드하는 것은 이 파일이 처음이다.**
#    그 배선을 여기서 한 번만 만들고, 어디서도 팔 번호 리터럴을 쓰지 않는다.
#
# ⚠️ **`action_registry.jl` 이 아니라 `ood_mdp_shim.jl` 을 include 한다.** 전자만 넣으면
#    `action_to_proposal`/`valid_actions`/`event_context` 가 CB 안에 없다(그 셋은
#    `oracle/ood_mdp_shim.jl` 에 있고, 그 파일이 자기 형제인 `action_registry.jl` 을 이미
#    include 한다). shim 을 include 하면 **한 번의 include 로 둘 다** 들어오고,
#    `ActionRegistry` 가 두 벌 생기는 일도 없다. 경로는
#    `wm4spacecraft_manufacturing/oracle/action_registry.jl` — `core/` 가 아니라 `oracle/`
#    이다(JSON 만 `core/` 에 있다).
#
# shim 은 본문 전체에서 `CB.` 접두사로 심볼을 부른다(원래 Main 스코프에 로드되던 파일이다).
# 이 모듈 안에서 그 이름을 자기 자신에 묶어 주면 파일을 한 글자도 안 고치고 그대로 쓸 수 있다.
isdefined(@__MODULE__, :CB) || Core.eval(@__MODULE__, :(const CB = $(@__MODULE__)))
isdefined(@__MODULE__, :action_to_proposal) ||
    include(joinpath(pkgdir(@__MODULE__), "wm4spacecraft_manufacturing",
                     "oracle", "ood_mdp_shim.jl"))

# --- 목적함수 가중치의 단일 진실원 --------------------------------------------------------
#
# ⚠️ **`Objective.load()` 를 여기서 부를 수 없다.** `core/objective.jl`
#    은 `module Objective` 안에서 `using SHA` 를 하는데, `SHA` 는 `Project.toml [deps]` 에
#    없다(Manifest 전이 의존성뿐). 패키지 모듈 안에서는 [deps] 밖 이름을 `using` 으로 못
#    부른다 — `simstate.jl:22-36` 이 정확히 같은 자리에서 데고 `Base.require` 로 우회한
#    기록을 남겼다. Global Constraint 가 `[deps]` 수정을 금지하므로, **단일 진실원인 JSON
#    파일 자체**를 읽는다(모듈이 아니라 파일이 진실원이라는 것이 그 Global Constraint 의
#    문장 그대로다). `Objective.load()` 의 ENV 덮어쓰기는 `C_fail`/`C_unclosed` 둘뿐이라
#    `w_E = κ·M_ref/E_ref` 에 닿지 않는다 — 두 경로가 같은 값을 낸다.
const OBJECTIVE_JSON = normpath(joinpath(pkgdir(@__MODULE__), "wm4spacecraft_manufacturing",
                                         "core", "objective.json"))

"""
    objective_w_E() -> Float64

`w_E = κ · M_ref / E_ref` [1/J]. **여기서 숫자를 계산하지 않는다** — `objective.json` 이
단일 진실원이다. 키가 없거나 `null` 이면 폴백하지 않고 죽는다(0 이나 1 로 떨어지면 에너지
항이 조용히 사라지거나 makespan 을 압도한다).
"""
function objective_w_E()
    cfg = JSON3.read(read(OBJECTIVE_JSON, String))
    v = Dict{String,Float64}()
    for k in ("kappa", "M_ref", "E_ref")
        haskey(cfg, Symbol(k)) && cfg[Symbol(k)] !== nothing ||
            error("objective_w_E: $(OBJECTIVE_JSON) 에 '$(k)' 가 없거나 null 이다 — " *
                  "0/1 로 폴백하지 않는다(에너지 항이 조용히 사라지거나 makespan 을 압도한다)")
        v[k] = Float64(cfg[Symbol(k)])
    end
    v["E_ref"] > 0.0 || error("objective_w_E: E_ref = $(v["E_ref"]) — 양수여야 한다")
    return v["kappa"] * v["M_ref"] / v["E_ref"]
end

# =============================================================================
#  이슈 F — s 와 env 가 짝인가
# =============================================================================
"""
    assert_paired(s::SimState, env) -> Nothing

🔴 **이슈 F 의 해소.** `T_plan_next(s, env)` 처럼 `s` 와 `env` 를 **독립 인자로** 받는 함수는
둘이 같은 세계인지 확인해야 한다. `s.g.edges`·`s.prog.closed` 는 **스케줄 정점 인덱스**로
키가 잡혀 있고 `Replace` 의 재스탬프 경로가 그 번호를 **재부여**한다. 짝이 아니면
`T_done(s_old, env_new)` 가 조용히 엉뚱한 노드를 인덱싱한다.

spec §4 는 "`s` 에 그래프 세대 도장을 추가하라" 고 적었는데, **도장 대신 직접 대조**한다 —
필드를 늘리지 않고 O(E) 로 정확히 같은 것을 확인할 수 있기 때문이다(도장은 대리 지표라
충돌하면 거짓 통과가 난다).

🔴 **`prog.closed` 는 일부러 대조하지 않는다.** 경량 레인은 `s` 만 전진시키고 `env` 는 안
민다(`sample_sojourn` 이 `_cross_boundary` 로 노드를 닫는 것은 `s` 안에서다). 그래서 정상
사용에서 `s.prog.closed` 는 언제나 `env` 보다 **앞서 있거나 같다** — 닫힌 집합을 짝 판정에
넣으면 정상 경로가 전부 빨개진다. 여기서 지키는 불변식은 하나다: **그래프 세대가 같은가.**
"""
function assert_paired(s::SimState, env)
    cur = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(env.sched)
        push!(cur, (Graphs.src(e), Graphs.dst(e)))
    end
    s.g.edges == cur || error(
        "assert_paired: s 와 env 가 다른 그래프 세대다 " *
        "(s: $(length(s.g.edges)) 엣지, env: $(length(cur)) 엣지). " *
        "그래프 수술 뒤에는 simstate_of(env) 로 s 를 다시 읽을 것 — 낡은 s 는 엉뚱한 정점을 " *
        "인덱싱한다")
    return nothing
end

# =============================================================================
#  메뉴
# =============================================================================
"""
    legal_actions_kind(kind::Symbol) -> Vector{Int}

레지스트리가 정하는 **상한**. `ActionRegistry.kind_valid` 의 얇은 래퍼다 — 여기서 리터럴을
쓰지 않는다(Global Constraint: 어휘의 단일 진실원은 JSON 하나).
"""
legal_actions_kind(kind::Symbol) = ActionRegistry.kind_valid(String(kind))

"""
    legal_actions(s, kind) -> Vector{Int}

🔴 **D-7 이후 이 함수는 `s` 를 보고 좁히지 않는다.** 예비는 충분하다고 가정하므로 좁힐 축이
없다. 그래도 `s` 를 인자로 남기는 이유: 이 시그니처가 소비처의 계약이고, 가정이 바뀌면
여기가 좁히는 자리이기 때문이다.

⚠️ 선행 계획에는 "예비가 0 이면 Replace 를 뺀다" 는 좁히기가 있었다. **되살리지 말 것** —
D-7 아래에서는 그 분기가 도달 불가능하고, 도달했다면 그것은 가정 위반이므로 메뉴를 좁힐 게
아니라 `apply_action!` 에서 **죽어야 한다**.

🔴 **이것은 `valid_actions(ctx)` 와 같은 집합이 아니다 — 상한이다.** shim 의
`valid_actions` 는 결정 시점의 기하(zone)·SoC(battery)로 **더 좁힌다.** MCTS 가 노드를
확장할 때는 둘의 교집합을 써야 한다: 상한에만 있고 `valid_actions` 에 없는 팔을
`apply_action!` 에 넣으면 (조용한 NOOP 이 아니라) **에러**가 난다. 그게 의도다 — 침묵보다
낫다. 좁히려면 좁힌다는 사실이 호출자 코드에 보여야 한다.
"""
function legal_actions(s::SimState, kind::Symbol)
    arms = collect(legal_actions_kind(kind))
    isempty(arms) && return [0]
    0 in arms || pushfirst!(arms, 0)
    return sort!(arms)
end

# =============================================================================
#  트리 색인 — 🔴 `state_hash` 가 **아니다**
# =============================================================================
"""
    action_path_key(path) -> String

**트리 노드와 리플레이 버퍼의 색인 키.** 루트에서 여기까지의 **행동 경로**를 문자열 하나로
정규화한다 — 버퍼·트리는 `constraints` 로 색인한다.

🔴 **왜 `state_hash` 가 아닌가 — 이제 측정된 기전이 있다**
(`nondeterminism-investigation.md`). Julia 는 `ConstructionBots` 를 재precompile 할 때마다
새 `build_id` 를 발급하고, 그것이 `TypeName.hash` 를 시드하므로 CB 가 정의한 모든 ID 타입의
`hash` 가 바뀐다 → 그 ID 를 키로 쓰는 `Dict`/`Set` 의 순회 순서가 바뀐다 →
bounding-sphere 적합이 바뀐다 → 배정 DAG 와 **정점 번호**가 바뀐다.

그래서 `prog.closed`(정점 번호로 저장된다)는 디렉토리/재컴파일을 건너 **이식 가능하지 않고**,
결과가 두 방향으로 동시에 나쁘다 — 실측:

  1. 서로 **다른** 두 세계가 `prog.closed` 해시 충돌로 **같은 키를 얻어 병합된다.**
  2. **같은** 세계가 정점 번호 비이식성 때문에 **다른 키를 얻어 병합되지 않는다**
     (`state_hash` `152868d2…` vs `0f684381…`).

⚠️ 그 위에 `SwapBattery` 트립와이어가 얹힌다: `SwapBattery` 는 결정 직후 `s` 에 흔적을 안
남긴다(배송은 `env.BATTERY_DELIVERIES[]` 에 산다) — `state_hash` 병합을 도입하는 순간 그
자식이 `NOOP` 자식과 합쳐진다.

**따라서 `state_hash` 는 한 디렉토리 안의 진단 도구로만 쓴다.** transposition table ·
rollout dedup · golden-hash 게이트를 그 위에 세우지 않는다.

경로의 원소는 팔 id(`Int`)이거나 제약 벡터(L2 행동: `TranslateBuild` 처럼 파라미터가 자유로운
원시연산)다. 그 밖의 타입은 조용히 문자열로 만들지 않고 **죽는다** — 색인 키가 조용히
충돌하는 것이 이 함수가 막으려는 바로 그 실패이기 때문이다.
"""
action_path_key(path::AbstractVector) = join((_arm_key(x) for x in path), "/")

_arm_key(a::Integer) = string(Int(a))
_arm_key(cs::AbstractVector{<:ConstraintSpec}) =
    "[" * join(sort!(String[string(c) for c in cs]), ",") * "]"   # 🔴 정렬 — Set 순서를 안 믿는다
_arm_key(x) = error(
    "action_path_key: 색인할 수 없는 팔 $(typeof(x)) — 팔 id(Int) 이거나 " *
    "Vector{<:ConstraintSpec} 여야 한다. 조용히 string() 으로 떨어뜨리지 않는다 " *
    "(그러면 서로 다른 행동이 같은 키로 병합된다)")

# =============================================================================
#  집행
# =============================================================================
"""공통 재풀이가 실제로 돈 횟수. **조용히 무동작**이 아니라는 것을 시험이 이걸로 본다."""
const RESOLVE_CALLS = Ref(0)

"""
    resolve_assignments!(env; optimizer = _respec_optimizer()) -> (; ran_milp, n_reassigned, status)

**모든 팔 뒤에 도는 공통 MILP 재풀이** (확정 설계 `.claude/CLAUDE.md` §⏳ 2026-08-20).
남은 스케줄을 현재 그래프·기하 위에서 **추가 제약 없이** 다시 푼다. 어떤 팔에서든 같은 코드가
돌아야 `Ĵ(a)` 의 차이가 **팔의 차이**가 된다.

⚠️ **실측된 시그니처 셋**(직관과 다르니 확인하고 쓸 것):
  · `release_pending_assignments!` → `(env, invariant::InvariantSpec; faulted, agent)`
    (`src/respec/reassign.jl:149`. 🔴 `faulted` 와 `agent` 는 **배타적**이다 — 둘 다 주면 `ArgumentError`.
     `agent` 는 범위를 **좁힌다**: 그 로봇이 소유한 미래 배정 간선만 둔다)
  · `assign_collaborative_tasks!`  → 첫 인자가 `model` 이다(`task_assignment.jl:433`)
  · 맨이름 `validate` 는 **존재하지 않는다**
    (`validate_tree`/`validate_embedded_tree`/`validate_sub_tree` 뿐)
대신 **`rebalance_for_battery!`(`battery.jl:715`)의 모양**을 그대로 쓴다 — 그 함수는 이름만 배터리이고, 하는 일은 `build_invariant` 로 완료·진행중을
얼리고 추가 제약 없이 재정식화 + `optimize!` + `commit_respec!` 다.

### 기록된 의미 결정 — **NOOP 도 재푼다**

CLAUDE.md 가 "NOOP 도 재풀이할 것인가는 **의미 결정**이다" 라고 남겨 둔 자리다.
**재푼다.** 안 그러면 NOOP 만 체계적으로 다른 파이프라인을 타고, 그 차이가 팔의 성질로
오독된다 — 이 태스크의 존재 이유가 정확히 그것을 막는 것이다.
⚠️ 대가: NOOP 이 "아무것도 안 함" 이 아니라 **"제약 변화 없이 다시 품"** 이 된다. 그것이
`Ĵ(NOOP)` 의 정의이고, 논문이 NOOP 을 그렇게 서술해야 한다.

### ⚠️ 항진성 — `n_reassigned` 를 반드시 볼 것

CLAUDE.md 경고: 관측된 판들은 `n_candidate_edges = 0` 이라 MILP 가 순수 makespan 으로
후퇴했다. **후보 간선이 0 이면 공통 재풀이가 아무것도 안 바꾼다.**
그래서 `ran_milp` 은 증거가 **아니다** — 설계상 모든 팔에서 `true` 다(CLAUDE.md: "G6 은 모든
팔에서 `ran_milp=true` 가 되고 그게 설계상 정상이다. 'G6 PASS' 를 인용하지 말 것").
증거는 `n_reassigned` 다.

`n_reassigned` 의 정의: **재풀이 전후로 `binding` 이 바뀐 정점 수.**
`simstate_of(env).g.binding` 을 쓴다 — 배정을 읽는 두 번째 구현을 만들지 않기 위해서다.
⚠️ **하한이다**: `binding` 은 팀에서 `first(sort(...))` 하나만 담으므로(`observe.jl:96`),
정렬 첫째가 안 바뀌는 팀 구성 변경은 여기서 안 보인다. 0 이 아니면 확실히 바뀐 것이고,
0 이라고 안 바뀐 것은 아니다.

### 실패 경로 — 조용히 넘어가지 않는다

`:infeasible` / `:commit_failed` 를 **반환한다**(던지지 않는다). CLAUDE.md 가 "반환값을
무시하면 안 된다 — 현재 배터리 분기(`run_demo.jl:391`)는 아예 안 본다" 고 적은 그 자리이므로,
호출자가 반드시 보게 한다(`apply_action!` 이 죽는다).
🔴 **D-14 가 이 자리를 다시 연다**: 재풀이 불능은 "버그"가 아니라 세계의 사실일 수 있고,
그러면 예외가 아니라 **terminal 전이**여야 한다(`briefs/task-D14-brief.md`).
"""
function resolve_assignments!(env; optimizer = _respec_optimizer())
    RESOLVE_CALLS[] += 1
    before = simstate_of(env).g.binding
    inv    = build_invariant(env)                     # 이미 한/하는 일은 고정
    milp   = formulate_milp(SparseAdjacencyMILP(), env.sched, env.scene_tree;
                            optimizer = optimizer,
                            t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)   # extra_constraints 없음
    optimize!(milp)
    if primal_status(milp) != MOI.FEASIBLE_POINT
        return (ran_milp = true, n_reassigned = 0, status = :infeasible)
    end
    ok = commit_respec!(env, milp,
                        RespecProposal(ConstraintSpec[], "common re-solve (T13)", "smdp-generative");
                        resume = true)                # 🔴 resume=true — 진행도를 보존한다
    ok === false && return (ran_milp = true, n_reassigned = 0, status = :commit_failed)
    after = simstate_of(env).g.binding
    n = 0
    for v in union(keys(before), keys(after))
        get(before, v, -1) == get(after, v, -1) || (n += 1)
    end
    return (ran_milp = true, n_reassigned = n, status = :resolved)
end

"""
    _assert_spares_available(env, prop) -> Nothing

D-7 가드. 예비가 실제로 마르면 **죽는다**(spec §3-2).

`.claude/CLAUDE.md` 알려진 한계 2번: `nearest_pool` 은 가장 가까운 창고 하나만 보므로 전체
예비가 넉넉해도 **그 창고**가 비면 `pop_spare!` 가 `nothing` 을 돌려주고 `:no_spare` 로
강등된다(`replan.jl:1350` 이 `_replace_via_reassign!` 로 흘린다). 그 신호는 전부
`@info`/`@warn` 이라 `Logging.Warn` 로거 아래에서 **보이지 않는다.** 그래서 로그가 아니라
에러로 만든다 — "안 났다" 와 "못 본다" 를 가른다.

⚠️ **팔 번호 리터럴(`a == 1`)로 가드하지 않는다.** `a == 1 || return nothing` 은 두 번째
진실원이다(재번호가 한 번 더 오면 조용히 엉뚱한 팔을 지킨다). 창고 본체를 실제로 먹는 것은 **`ReplaceAgent` 제약**이고
(`replan.jl:_is_robot_replace` → `pop_spare!`), 그건 타입으로 정확히 판정된다.
"""
function _assert_spares_available(env, prop)
    prop === nothing && return nothing
    any(c -> c isa ReplaceAgent, prop.constraints) || return nothing
    total = sum(length(v) for v in values(SPARE_POOLS[]); init = 0)
    total > 0 || error(
        "apply_action!: ReplaceAgent 인데 예비가 하나도 없다 — D-7('예비는 충분하다')이 깨졌다. " *
        "DEMO_SPARES / n_spare_per_pool 를 올리거나 그 가정을 spec 에서 되돌릴 것. " *
        "조용히 NOOP 으로 떨어뜨리지 않는다")
    return nothing
end

"""
    apply_action!(env, ctx, a::Int) -> NamedTuple

행동을 **진짜 respec 으로** 집행한다(spec D-2). 근사 모델이 아니다 — DAG·scene tree 편집이
정확해야 그 편집을 SMDP 로 모델링한다는 주장이 성립한다.

**`env` 를 제자리에서 바꾼다.** 그러므로 호출 전에 갈래를 떠 두어야 한다:
`e = deepcopy(env); rvo_rebuild!(e)`. R4 가 잰 `deepcopy_ms.median ∈ [5,50)` 은 **하한**이다
— `deepcopy` 는 세 항법 계층 중 둘만 격리하고 **RVO2 는 프로세스 전역**이다. 그래서 분기
비용은 `deepcopy + rvo_rebuild!` 이고, 판정은 "롤아웃마다 한 번" 이지 "트리 노드마다"가 아니다.
⚠️ 그리고 `deepcopy` 는 respec **전역**(`SPARE_POOLS`·`RESTRICTION_ZONES`·`FAULTED_ROBOTS`
…)도 격리하지 않는다 — `test/smdp_generative.jl` 이 그 누수를 수치로 기록한다.

**반환값**은 이름 붙은 결과다 — `Nothing` 을 내면 "집행됐다/거부됐다"가 호출자에게 안 보인다:

    (a, outcome, enacted, branch, resolve)

`outcome ∈ (:noop, :admitted, :rejected)`. `:noop` 은 **a == 0 을 골랐다** 는 뜻이고
`:rejected` 는 `verify()` 가 문을 닫았다는 뜻이다(계획: "거부 = NOOP 과 같은 전이").
둘은 다른 사건이므로 다른 이름을 준다.

🔴 **죽는 자리 넷 — 전부 "조용한 NOOP" 이 될 뻔한 자리다:**
  · 어휘 밖 id
  · `action_to_proposal` 이 `nothing` 을 냈다(= shim 의 문지기 `a in valid_actions(ctx)` 에
    걸렸거나, ctx 에 그 팔이 요구하는 대상이 없다). shim 은 여기서 **조용히 NOOP 팔로**
    무너지지만 이 함수는 그 침묵을 상속하지 않는다.
  · D-7 예비 가정 위반
  · 집행이 라인을 멈췄다(`RESPEC_HOLD[]` latch). `release_fallback!` 은 production 소비처가
    0개라 그 뒤의 모든 전이가 죽은 세계 위에서 일어난다 — 롤아웃을 계속하면 안 된다.

순서가 중요하다. `rvo_rebuild!` 는 **맨 마지막**이다(T11 의 핀 경고).
"""
function apply_action!(env, ctx, a::Int)
    a in ActionRegistry.IDS || error(
        "apply_action!: 어휘 밖 행동 id $(a) — 현행 어휘 $(ActionRegistry.VOCAB) 의 " *
        "id 는 $(ActionRegistry.IDS) 다. 조용히 NOOP 으로 떨어뜨리지 않는다")
    ActionRegistry.is_active(a) || error(
        "apply_action!: 행동 $(a)($(ActionRegistry.NAME[a])) 는 활성 팔이 아니다 " *
        "(은퇴했거나 실험 게이트가 꺼져 있다)")

    RESPEC_HOLD[] && error(
        "apply_action!: 라인이 이미 멈춰 있다(RESPEC_HOLD). 멈춘 라인 위의 집행은 무의미하고 " *
        "release_fallback! 은 production 소비처가 0개다 — 이 롤아웃을 계속하지 않는다")

    prop   = a == 0 ? nothing : action_to_proposal(ctx, a)
    branch = :none
    outcome = :noop

    if a != 0
        prop === nothing && error(
            "apply_action!: 행동 $(a)($(ActionRegistry.NAME[a])) 를 이 사건에서 제안으로 " *
            "만들 수 없다 — shim 의 문지기 valid_actions(ctx) = $(valid_actions(ctx)) 이고 " *
            "ctx(type=$(ctx.type), agent=$(ctx.agent), zone=$(ctx.zone)) 다. " *
            "🔴 ood_mdp_shim.action_to_proposal 은 여기서 nothing 을 돌려주어 **조용히 NOOP 팔로** " *
            "무너지지만, G(s,a) 는 그 침묵을 상속하지 않는다 — 집행할 수 없는 행동은 결정처럼 " *
            "보이는 무동작이 아니다. 메뉴를 legal_actions(s,kind) ∩ valid_actions(ctx) 로 좁힐 것")
        _assert_spares_available(env, prop)

        # `maybe_respecify!` 의 집행 꼬리를 그대로 쓴다(`_enact_one!`). 그 함수가 두 로그를
        # 호출자가 비워 준다고 가정하므로(`maybe_respecify!:832-833` 과 같은 자리) 여기서 비운다.
        ENACT_ORDER_LOG[]   = Symbol[]
        LAST_ENACT_REPORT[] = NamedTuple[]
        outcome = _enact_one!(env, prop)
        branch  = isempty(ENACT_ORDER_LOG[]) ? :generic : last(ENACT_ORDER_LOG[])
        outcome in RESPEC_VERDICTS || error(
            "apply_action!: _enact_one! 이 어휘 밖 판정 $(outcome) 을 냈다 — " *
            "$(RESPEC_VERDICTS) 중 하나여야 한다")
        RESPEC_HOLD[] && error(
            "apply_action!: 행동 $(a)($(ActionRegistry.NAME[a])) 집행이 라인을 멈췄다 " *
            "(판정 $(outcome), 분기 $(branch)). 멈춘 라인 위에서는 어떤 전이도 의미가 없고 " *
            "release_fallback! 은 production 소비처가 0개다 — 조용히 롤아웃을 이어가지 않는다")
    end

    res = resolve_assignments!(env)        # 공통 MILP 재풀이 (T13) — **모든 팔 뒤에** 돈다
    # 🔴 반환값을 무시하지 않는다. CLAUDE.md 가 지적한 그 자리다 —
    #    `run_demo.jl:391` 의 배터리 분기는 `rebalance_for_battery!` 의 판정을 **아예 안 본다**.
    #    재풀이가 실패했는데 롤아웃을 이어가면 그 뒤의 τ·R 이 전부 없는 계획 위의 값이다.
    # ⚠️ D-14 가 이 자리를 다시 연다: 재풀이 불능은 버그가 아니라 세계의 사실일 수 있고,
    #    그러면 예외가 아니라 **terminal 전이**여야 한다(briefs/task-D14-brief.md).
    res.status === :resolved || error(
        "apply_action!: 공통 재풀이가 $(res.status) 다 (행동 $(a)($(ActionRegistry.NAME[a])), " *
        "판정 $(outcome)). 재풀이가 실패한 계획 위에서는 어떤 전이도 의미가 없다 — " *
        "조용히 롤아웃을 이어가지 않는다")
    update_planning_cache!(env, 0.0)
    rvo_rebuild!(env)                      # ← 반드시 마지막(RVO 는 씬트리의 파생물, spec §5-2)
    return (a = a, outcome = outcome, enacted = (outcome === :admitted),
            branch = branch, resolve = res)
end

# =============================================================================
#  전진 — τ 만큼 `s` 를 민다 (rate boundary 를 몇 개든 넘으면서)
# =============================================================================
"""
    _advance_over(s, env, τ, bp; guard) -> (s′, E, n_boundary)

`s` 를 `τ` 만큼 전진시키고 그 구간의 소비 에너지 `E` [J] 를 함께 낸다.

⚠️ **`advance_to(s⁺, env, τ, bp)` 한 번으로는 안 된다.** `advance_to` 는 **rate boundary 를
넘지 않는** 전진이고 `Δ > T_plan_next` 면 설계대로 죽는다. 그런데 `sample_sojourn` 의 `τ` 는
경계를 **몇 개든** 넘어서 온다(이 픽스처 실측: `T_plan_next = 0.025 s` vs `T_done ≈ 32.7 s`) —
그렇게 쓰면 흔한 경우에 `generate` 가 그냥 죽는다. `test/smdp_generative.jl` 이 그 자리를
음성 대조로 못박는다.

그래서 소저너가 **자기 안에서** 하는 것과 같은 걸음으로 다시 걷는다. 공개 API 만 쓴다
(`T_plan_next` · `advance_to` · `advance_to_rate_boundary` · `energy_between`) —
🔴 이것이 `advance_to` 의 유일한 소비처다. 은퇴시키지 말 것.

`E` 를 구간마다 따로 적분하는 이유: `energy_between` 은 **모드가 상수인 구간**에서만
정확하다고 자기 docstring 이 선언한다. 경계를 넘으면 모드가 바뀌므로 한 번에
`energy_between(s⁺, env, τ, bp)` 를 부르면 그 선언된 정의역 밖이다.
"""
function _advance_over(s::SimState, env, τ::Float64, bp::BatteryParams; guard::Int = 1024)
    (isfinite(τ) && τ >= 0.0) ||
        error("_advance_over: τ = $(τ) — 유한한 비음수여야 한다(Inf 를 적분 상한으로 쓰지 않는다)")
    cur = s
    rem = τ
    E   = 0.0
    nb  = 0
    nd  = 0
    while true
        act, durs = _active_with_durations(cur, env)
        if isempty(act)
            # 흡수 상태. 소저너도 여기서 `(:terminal, nothing)` 을 냈으므로 남은 시간은 0 이어야 한다.
            rem <= 1e-6 || error(
                "_advance_over: 활성 정점이 없는데 $(rem) s 가 남았다 — sample_sojourn 이 낸 τ 와 " *
                "이 재걸음이 같은 세계를 안 걷고 있다")
            return (cur, E, nb)
        end
        if !any(>(0.0), durs)
            # 🔴 `dur == 0` 프론티어는 **시간 0 으로** 닫는다 — 소저너와 같은 처리(sojourn.jl:288).
            #    이렇게 해야 `T_plan_next` 의 `Inf` 계약을 적분 상한으로 만나지 않는다.
            cur = _close_vertices(cur, act)
            nd += 1
            nd > guard && error("_advance_over: dur==0 프론티어를 $(nd) 번 흘렸다 — 스케줄이 전진하지 않는다")
            continue
        end
        b = T_plan_next(cur, env)
        (isfinite(b) && b > 0.0) || error(
            "_advance_over: T_plan_next = $(b) 인데 dur>0 인 활성이 있다 — tplan.jl 의 주 경로 전제가 깨졌다")
        if rem <= b + _SOJ_TOL
            E += energy_between(cur, env, rem, bp)
            return (advance_to(cur, env, rem, bp), E, nb)
        end
        E  += energy_between(cur, env, b, bp)
        cur = advance_to_rate_boundary(cur, env, b, bp)
        rem -= b
        nb  += 1
        nb > guard && error(
            "_advance_over: rate boundary 를 $(nb) 번 넘었다 — sample_sojourn 의 같은 가드보다 " *
            "먼저 여기서 죽는다면 두 걸음이 갈린 것이다")
    end
end

# =============================================================================
#  G(s,a)
# =============================================================================
"""
    generate(s, env, ctx, a, p, bp, rng; delta_max = Inf) -> (; s, R, τ, event, E)

`G(s,a)`. spec §5-1. MCTS 가 이걸로 `(s,a) → (s′, R, τ)` 를 표집한다.

    R = -(τ + w_E · E[0,τ])

보상은 **비용의 음수**이고 `w_E` 는 `objective.json` 에서 온다(spec §4). 언제나 `R ≤ 0` 이다.

🔴 **`E` 를 같이 돌려준다.**
게이트 **N-G5a** 는 `R + (τ + w_E·E) == 0` 이라는 **레인 안의 항등식**을 검사하는데,
`E` 를 역산(`E = (−R − τ)/w_E`)해서 뽑으면 그 등식이 **정의상 항진**이 된다. 그래서 `E` 는
소비처가 **직접** 받아야 한다. 부수 효과로 `objective.json` 의 두 번째 소비처도 없어진다.
근거 전문: `briefs/task-T14-ng5-redefinition.md`.

⚠️ **반환은 `NamedTuple` 이다 — 위치 기반 구조분해를 쓰지 말 것.** 필드로 받아야 나중에
필드가 하나 늘어도 호출자가 안 깨진다.

🔴 **`env` 를 제자리에서 바꾼다.** `s` 는 "호출자가 이 env 의 짝이라고 믿는 상태" 이고,
그 믿음을 `assert_paired` 가 먼저 검사한다. 갈래는 호출자가 뜬다(`deepcopy` + `rvo_rebuild!`).

⚠️ **선언된 근사 하나**: 돌려주는 `s′` 는 **사건이 도착한 시각의 상태**이지 그 사건이
집행된 뒤의 상태가 아니다. 사건의 집행(고장 로봇 등록·배터리 방전 등)은 **다음** 결정에서
`ctx` 를 통해 들어온다 — 이 함수가 `env` 에 사건을 심지 않는다. 그 자리는 아직 열려 있다.
"""
function generate(s::SimState, env, ctx, a::Int, p::HazardParams, bp::BatteryParams, rng;
                  delta_max::Float64 = Inf)
    assert_paired(s, env)
    apply_action!(env, ctx, a)
    s_plus = simstate_of(env)
    τ, ev  = sample_sojourn(s_plus, env, p, bp, rng; delta_max = delta_max)
    s_next, E, _ = _advance_over(s_plus, env, τ, bp; guard = 16 * p.max_events)
    R = -(τ + objective_w_E() * E)
    isfinite(R) || error("generate: R = $(R) 가 비유한이다 (τ=$(τ), E=$(E))")
    isfinite(E) && E >= 0.0 ||
        error("generate: E = $(E) — 유한한 비음수여야 한다. 음수 에너지를 0 으로 접지 않는다")
    return (s = s_next, R = R, τ = τ, event = ev, E = E)
end
