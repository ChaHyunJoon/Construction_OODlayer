# =============================================================================
#  공통 MILP 재풀이 — **CB 본체의 한 벌** (판정 1, 2026-09-02)
# =============================================================================
# 🔴 왜 이 파일이 생겼나 (실측이 계기다). `synthesize.py` 는 두 곳에서 프롬프트에
#    *"THE HARNESS RE-SOLVES THAT MILP AUTOMATICALLY AFTER EVERY TOOL BODY"* 라고 적고,
#    2026-09-01 에 `commit_respec` 을 알파벳에서 뺀 근거가 바로 그 문장이다. 그런데
#    **집행 엔진에서 그 약속은 거짓이었다**:
#      · `using ConstructionBots` 뒤 `isdefined(CB, :resolve_assignments!) == false`
#        — 재풀이는 `src/smdp/mdp.jl` 이 **런타임 include** 하는 SMDP 모듈 안에만 살았다.
#      · `enact_minted_decision!` 의 유일한 프로덕션 호출자 `tools/monitor/render_demo.jl` 은
#        `navigator/navigator.jl` 만 include 한다 — `smdp/mdp.jl` 은 **안 부른다.**
#    ⟹ 주조 body 가 배정 간선을 떼면 **아무도 재배정하지 않은 채** `handled=true` 로
#      기본 복구 사슬까지 삼켰다. NOOP 보다 나쁜 결과다.
#    그리고 2026-09-02 F7 이후 mild 레인이 실제로 `reach="composed"` 인 body
#    (`release_pending_assignments`)를 내기 시작했으므로, 그때까지 우리를 **우연히**
#    보호하던 `reach=="composed"` 게이트가 사라졌다.
#
# 🔴 **복제 금지.** 두 벌은 갈린다 — 이 레포는 `train_kinds`·`require_vocab` 에서 이미 그
#    실패 모양을 밟았다. `src/smdp/generative.jl` 의 `apply_action!` 과 `enact_minted!` 는
#    **이 파일의 같은 함수**를 부른다.
#
# 🔴 여기로 같이 올라온 셋, 그리고 그 이유:
#    · `_responsible_robots` — `navigator/battery.jl` 에 있었는데 배터리와 무관한 **순수
#      스케줄 접근자**다(노드 타입 다섯에 대한 dispatch). 거기 두면 재풀이가 런타임
#      include 에 의존하게 되고, 프로덕션 집행 경로가 그 include 를 안 하는 판이 생긴다.
#    · `assignment_binding` — `simstate_of`(smdp/observe.jl) 안에 인라인으로 있던 루프.
#      배정을 읽는 **두 번째 구현을 만들지 않기 위해** 함수로 뽑아 양쪽이 같이 부른다.
#      (그 규칙은 `resolve_assignments!` 의 옛 docstring 이 직접 적어 둔 것이다.)
#    · `_int_key` — 같은 이유로 `smdp/observe.jl` 에서 올라왔다. `assignment_binding` 이
#      부르는데 그 파일은 런타임 include 다. 🔴 **다시 구현하지 않았다** — `Bool <: Integer`
#      때문에 `.id === true` 가 `RobotID(1)` 과 조용히 충돌하는 것을 막는 가드가 그 안에
#      있고, 손으로 다시 쓰면 그 가드가 사라진다(이 작업에서 실제로 그렇게 쓸 뻔했다).

# 이 노드의 일을 실제로 하는 물리 로봇들: RobotGo 는 한 대, 운반유닛(TransportUnit)은 팀
# 전원에 분산. RobotID 벡터 반환.
# Physical robots responsible for an active node: a RobotGo is one robot; a TransportUnit
# spreads work over its whole team. Returns a Vector of RobotIDs.
# 🔴 2026-09-02: `navigator/battery.jl` 에서 여기로 옮겼다(호출자는 battery.jl · hazard.jl ·
#    observe.jl · 이 파일 — 전부 같은 모듈이라 이름 해석은 그대로다).
function _responsible_robots(node)
    if node isa RobotGo || node isa RobotStart
        return [node_id(entity(node))]
    elseif node isa TransportUnitGo || node isa FormTransportUnit || node isa DepositCargo
        return collect(keys(robot_team(node)))     # robot_team(pred) -> robot_team(entity) -> n.robots
    else
        return Any[]
    end
end

"""
    assignment_binding(sched) -> Dict{Int,Int}

정점 → 그 정점을 맡은 로봇(정수 키). **배정을 읽는 단 하나의 구현**이다 —
`simstate_of`(`src/smdp/observe.jl`)의 `g.binding` 과 `resolve_assignments!` 의
`n_reassigned` 가 같은 이 함수를 부른다.

⚠️ **하한이다**: 팀이 맡은 정점은 `first(sort(...))` 하나만 담으므로, 정렬 첫째가 안 바뀌는
팀 구성 변경은 여기서 안 보인다. 0 이 아니면 확실히 바뀐 것이고, 0 이라고 안 바뀐 것은 아니다.

🔴 `_responsible_robots` 호출을 `try ... catch; () end` 로 감싸지 말 것. 그 함수는 else
분기에서 항상 `Any[]` 를 반환하고 **절대 던지지 않으므로** 그 catch 는 죽은 방어 코드가
아니라 "조용한 폴백 금지" 위반이다: 어느 날 새 노드 타입이 추가돼 이 호출이 정말로 던지면
그 정점이 결과에서 **조용히** 빠지고, 그 누락은 어디서도 안 보인다.

⚠️ `_responsible_robots` 는 정렬돼 있지 않다(Dict 순회 순서). 정렬 첫째를 쓴다 — 안 하면
같은 세계가 프로세스마다 다른 binding 을 얻는다(이 레포의 재현성 결함과 같은 뿌리).
"""
function assignment_binding(sched)
    binding = Dict{Int,Int}()
    for v in Graphs.vertices(sched)
        rs = _responsible_robots(get_node(sched, v).node)
        isempty(rs) && continue
        binding[v] = _int_key(first(sort!(collect(rs); by = string)))
    end
    return binding
end

"""
    _int_key(id) -> Int

`AbstractID` 를 정수 키로. **`hash` 폴백을 두지 않는다** — 조용한 충돌은 서로 다른 두 로봇을
한 레코드로 합치고(그러면 `s` 가 거짓말을 한다), 그 사고는 에러 없이 성능으로만 샌다.
모양이 다르면 죽는 편이 낫다.

🔴 2026-09-02: `src/smdp/observe.jl` 에서 여기로 옮겼다. 여기 있는 `assignment_binding` 이
이것을 부르는데 그 파일은 **런타임 include** 라, 놔두면 프로덕션 집행 경로(navigator 만
로드한다)에서 재풀이가 `UndefVarError` 로 죽는다. 호출자 33곳은 전부 같은 모듈이라 이름
해석은 그대로다.
"""
function _int_key(id)
    hasproperty(id, :id) ||
        error("_int_key: $(typeof(id)) 에 `.id` 가 없다 — s 의 정수 키를 만들 수 없다 " *
              "(hash 폴백은 두지 않는다: 조용한 충돌보다 죽는 편이 낫다)")
    v = getproperty(id, :id)
    # 🔴 `Bool <: Integer` **다**. `v isa Integer` 만 보면 `.id === true` 인 id 가 통과해 `1` 이
    # 되고 `RobotID(1)` 과 **조용히 충돌한다** — 이 함수가 막으라고 존재하는 바로 그 사고가
    # 이 함수 안에서 일어난다(리뷰 라운드 2 실측: `_int_key((id=true,)) == _int_key(RobotID(1))`).
    # 오늘의 id 타입 중 `Bool` 페이로드는 없지만, 이 가드의 존재 이유는 **아무도 예상 못 한
    # id 모양**을 잡는 것이다 — 그 역할에 구멍이 있으면 가드가 아니다.
    v isa Bool &&
        error("_int_key: $(typeof(id)).id 가 Bool 이다(값: $(v)) — Julia 에서 `Bool <: Integer` 라 " *
              "`Int(true) == 1` 이 되어 RobotID(1) 과 조용히 충돌한다. 정수 키로 받지 않는다")
    v isa Integer ||
        error("_int_key: $(typeof(id)).id 가 $(typeof(v)) 다(Integer 가 아니다) — 값: $(v)")
    return Int(v)
end

"""공통 재풀이가 실제로 돈 횟수. **조용히 무동작**이 아니라는 것을 시험이 이걸로 본다."""
const RESOLVE_CALLS = Ref(0)

"""
    resolve_assignments!(env; optimizer = _respec_optimizer()) -> (; ran_milp, n_reassigned, status)

**모든 팔 뒤에, 그리고 모든 주조 body 뒤에 도는 공통 MILP 재풀이.**
남은 스케줄을 현재 그래프·기하 위에서 **추가 제약 없이** 다시 푼다. 어떤 팔에서든 같은 코드가
돌아야 `Ĵ(a)` 의 차이가 **팔의 차이**가 된다.

⚠️ **실측된 시그니처**(직관과 다르니 확인하고 쓸 것):
  · `release_pending_assignments!` → `(env, invariant::InvariantSpec; faulted, agent)`
    (`src/respec/reassign.jl`. 🔴 `faulted` 와 `agent` 는 **배타적**이다 — 둘 다 주면 `ArgumentError`.
     `agent` 는 범위를 **좁힌다**: 그 로봇이 소유한 미래 배정 간선**만 떼고** 나머지는 그대로 둔다)
  · `assign_collaborative_tasks!`  → 첫 인자가 `model` 이다(`task_assignment.jl`)
대신 **`rebalance_for_battery!`(`navigator/battery.jl`)의 모양**을 그대로 쓴다 — 그 함수는
이름만 배터리이고, 하는 일은 `build_invariant` 로 완료·진행중을 얼리고 추가 제약 없이
재정식화 + `optimize!` + `commit_respec!` 다.

### 기록된 의미 결정 — **NOOP 도 재푼다**

재푼다. 안 그러면 NOOP 만 체계적으로 다른 파이프라인을 타고, 그 차이가 팔의 성질로 오독된다.
⚠️ 대가: NOOP 이 "아무것도 안 함" 이 아니라 **"제약 변화 없이 다시 품"** 이 된다.

### ⚠️ 항진성 — `n_reassigned` 를 반드시 볼 것

관측된 판들은 `n_candidate_edges = 0` 이라 MILP 가 순수 makespan 으로 후퇴했다. **후보 간선이
0 이면 공통 재풀이가 아무것도 안 바꾼다.** 그래서 `ran_milp` 은 증거가 **아니다** — 설계상
모든 팔에서 `true` 다. 증거는 `n_reassigned`(= 재풀이 전후로 배정이 바뀐 정점 수)다.

### ⚠️ 시간 — 범위를 안 좁힌 release 뒤에는 이 호출이 오래 걸린다

S2 실측: 전 구간 release 뒤 재풀이는 60초 `TIME_LIMIT` 을 친다. 대상 에이전트로 **범위를
좁힌** release(후보 1/19) 뒤에는 0.2초 `OPTIMAL`. `_respec_optimizer()` 에는 시간 제한이
걸려 있지 않으므로, 좁히지 않은 body 는 집행 경로를 그만큼 잡아 둔다. **이것은 알려진
대가이고 여기서 숨기지 않는다.**

### 실패 경로 — 조용히 넘어가지 않는다

`:infeasible` / `:commit_failed` 를 **반환한다**(던지지 않는다). 호출자가 반드시 보게 한다.
"""
function resolve_assignments!(env; optimizer = _respec_optimizer())
    RESOLVE_CALLS[] += 1
    before = assignment_binding(env.sched)
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
    after = assignment_binding(env.sched)
    n = 0
    for v in union(keys(before), keys(after))
        get(before, v, -1) == get(after, v, -1) || (n += 1)
    end
    return (ran_milp = true, n_reassigned = n, status = :resolved)
end
