# Task 2 — 제약 종류 `ForbidHeavyCargo` 를 만든다

> **선행:** Task 1 이 끝나 있어야 한다. 이 태스크는 Task 1 이 정한 **소유자 선택자**를 쓴다.
> `task-1-owner-selector.md` 의 "결정" 줄을 먼저 읽어라. 비어 있으면 Task 1 을 먼저 하라.

## 무엇을 만드는가

> "이 로봇은 자기가 맡을 예정인 화물 중 **1대당 부담 상위 `n` 개**를 맡지 않는다."

기존 `ForbidAgent`(로봇을 통째로 퇴역)의 **좁힌 판**이다. 로봇은 계속 살아서 다른 일을 한다.

🔴 **얼린 목록이면 안 된다.** `Xa` 는 `formulate_milp` **안에서만** 존재하고
(`src/respec/verifier.jl:111` 이 명시), 그래프는 formulate 사이에 바뀐다. 생성 시점에 얼린
`Xa[u,v]=0` 목록은 나중 formulate 에서 결정변수가 아닐 수 있고 → `Reject(:ungrammatical)` →
고장 경로에서 **라인 영구 정지**다. 그래서 **컴파일할 때마다 대상을 다시 찾는 규칙**이어야 한다.
기존 `ForbidAgent` 컴파일러가 정확히 그렇게 되어 있다(`compiler.jl:66-83`).

## 1대당 부담의 정의 — 이 값만 쓴다

```
1대당 부담 = _payload_mass_measured(env, inner, params) / length(robot_team(inner))
```

`inner` 는 도착 슬롯 `v2` 의 `Graphs.outneighbors` 한 홉 뒤에 있는 화물 운반 노드다.

⚠️ **`_payload_mass_measured` 자체를 고치지 마라.** 그 함수는 물리 회계
(`account_battery_step!`)가 쓰고 있다. 나누기는 **여기서** 한다.

**왜 나누는가**(`src/navigator/battery.jl:290-295`):
```julia
moved_mass = p.m_robot * length(robots) + m_payload   # m_robot = 60.0
share      = km * moved_mass * speed / length(robots) # 팀원끼리 균등 분배
```
팀이 크면 짐 부담을 **나눠 진다**. 실측(tractor)에서 두 순서가 7.5% 어긋난다 —
`m=12.8, 팀4 → 3.20` 이 `m=9.011, 팀2 → 4.506` 보다 **가볍다**.

## Files

- Modify: `src/respec/spec_dsl.jl` — `ForbidAgent`(:59) 바로 아래에 struct 추가
- Modify: `src/respec/compiler.jl` — `compile_constraint!(…, cs::ForbidAgent)`(:66) 아래에 메서드 추가
- Modify: `src/respec/verifier.jl:688` — `referenced_ids` 한 줄 추가
- Modify: `src/ConstructionBots.jl:102` — export 목록에 이름 추가
- Create: `test/forbid_heavy_cargo.jl`
- Modify: `test/runtests.jl` — 새 시험 파일 등록

## Interfaces

- **Produces** (Task 3·7 이 쓴다):
  - `ForbidHeavyCargo(agent::AbstractID, n::Int)` — 생성자는 `n >= 1` 을 강제한다
  - `compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidHeavyCargo) -> Int`
    반환값은 **모델에 실제로 추가한 행 수**다(🔴 이 계약은 `test/respec_grammar.jl` 이
    다른 제약들에 대해 이미 단언한다 — 행 수와 다르면 hollow admit 을 못 잡는다)
  - `referenced_ids(cs::ForbidHeavyCargo) -> Tuple` — `(cs.agent,)`
- **Consumes**: `is_agent_frontier` 또는 `_edge_owner_id`(Task 1 이 정한 것),
  `isassigned_edge(Xa, u, v2)`, `_payload_mass_measured`, `robot_team`

⚠️ 컴파일러는 `env` 를 못 받는다(인자가 `model, t0, tF, Xa, sched, cs` 뿐이다). 그런데
`_payload_mass_measured(env, node, p)` 는 `env.scene_tree` 를 쓴다. **이 불일치를 먼저 풀어라.**
선택지: (a) `sched` 에서 화물 노드를 직접 읽는 경로를 찾는다, (b) 씬트리 없이 되는 대리값을
쓴다, (c) 컴파일 시점에 접근 가능한 전역에서 씬트리를 얻는다. 🔴 **추측하지 말고 코드를 읽고
정하라.** 답이 (b)가 되면 spec §3 의 정의가 바뀌는 것이므로 **사용자에게 물어라.**

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/forbid_heavy_cargo.jl`:

```julia
# 🔴 runtests.jl 이 같은 Main 스코프에 include 하므로 자기 module 로 감싼다.
module ForbidHeavyCargoTests
using Test
using ConstructionBots
const CB = ConstructionBots
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "ForbidHeavyCargo 타입 계약" begin
    rid = CB.RobotID(3)
    c = CB.ForbidHeavyCargo(rid, 2)
    @test c.agent === rid
    @test c.n == 2
    # 🔴 n < 1 은 0개 제약 = hollow admit 이다. 생성자가 막아야 한다.
    @test_throws Exception CB.ForbidHeavyCargo(rid, 0)
    # verify 가 "과거를 건드리는가" 를 보려면 이 제약이 어떤 노드를 참조하는지 알아야 한다.
    @test CB.referenced_ids(c) == (rid,)
    # 문법 단계가 이 타입을 받아들여야 한다(ConstraintSpec 하위여야 verify (1) 을 통과).
    @test c isa CB.ConstraintSpec
end
end # module
```

- [ ] **Step 2: 시험이 실패하는 것을 확인한다**

```
julia +lts --project=. -e 'include("test/forbid_heavy_cargo.jl")'
```
기대: `UndefVarError: ForbidHeavyCargo not defined`

- [ ] **Step 3: struct 를 추가한다**

`src/respec/spec_dsl.jl`, `ForbidAgent` 정의 바로 아래:

```julia
"""
    ForbidHeavyCargo(agent, n)

"`agent` 는 자기가 맡을 예정인 화물 중 **1대당 부담 상위 `n` 개**를 맡지 않는다."

`ForbidAgent`(로봇 통째 퇴역)의 좁힌 판이다 — 로봇은 계속 살아서 다른 일을 한다.
1대당 부담 = `payload / 팀크기`(`battery.jl:290-295` 의 `share` 가 그렇게 나눈다).

🔴 **금지 대상은 컴파일할 때마다 다시 찾는다.** 목록을 얼려 두면 그래프가 바뀐 뒤 그 참조가
결정변수가 아니게 되어 `Reject(:ungrammatical)` 이 되고, 고장 경로에서 그것은 라인 영구
정지다(`replan.jl:889-892` → `engage_fallback!`).
"""
struct ForbidHeavyCargo <: ConstraintSpec
    agent::AbstractID
    n::Int
    function ForbidHeavyCargo(agent::AbstractID, n::Integer)
        n >= 1 || error("ForbidHeavyCargo: n 은 1 이상이어야 한다 — 0 개 금지는 hollow admit 이다 (받은 값: $(n))")
        return new(agent, Int(n))
    end
end
```

`src/ConstructionBots.jl:102` 의 export 목록에 `ForbidHeavyCargo` 를 더한다.
`src/respec/verifier.jl:688` 옆에:

```julia
referenced_ids(cs::ForbidHeavyCargo) = (cs.agent,)   # 이 제약이 건드리는 것은 그 로봇 하나
```

- [ ] **Step 4: 시험이 통과하는 것을 확인한다**

```
julia +lts --project=. -e 'include("test/forbid_heavy_cargo.jl")'
```

- [ ] **Step 5: 🔴 G-1 — "0개를 걸고 초록" 을 막는 시험을 먼저 쓴다**

실제 env 로 formulate 를 돌려 **추가된 행 수가 0 이 아닌지** 단언한다.

```julia
@testset "G-1 🔴 컴파일러가 실제로 행을 추가한다 (0 이면 빨강)" begin
    env = fixture()                       # tractor, closed≈60 — 아래 Step 6 참조
    agent = busiest_pending_agent(env)    # 미래 배정을 가장 많이 가진 로봇
    inv = CB.build_invariant(env)
    CB.release_pending_assignments!(env, inv)     # 후보 간선을 연다
    prop = CB.RespecProposal(CB.ConstraintSpec[CB.ForbidHeavyCargo(agent, 1)], "gate", "test")
    n_rows = Ref(0)
    # compile_constraint! 의 반환값을 직접 잰다 — 모델을 세우지 않고도 셀 수 있어야 한다.
    # (세우는 편이 쉬우면 formulate_milp 을 돌리고 그 안에서 센 값을 전역에 남겨 읽어도 된다.)
    @test n_rows[] > 0
end
```

⚠️ **이 시험을 어떻게 구현할지는 구현자가 정한다.** 핵심 계약은 하나다:
**금지가 걸린 판에서 추가된 행 수가 0 이면 시험이 빨개진다.** 이번 조사에서 프로브가 실제로
`금지행=0` 으로 공허하게 초록을 냈고, 그 사고를 여기서 막는다.

- [ ] **Step 6: 컴파일러를 쓴다**

`src/respec/compiler.jl`, `ForbidAgent` 메서드 아래. **Task 1 이 정한 선택자**를 쓴다.
`ForbidAgent`(:66-83)의 구조를 그대로 따르되 도착점을 부담 상위 `n` 개로 좁힌다:

```julia
function compile_constraint!(model, t0, tF, Xa, sched, cs::ForbidHeavyCargo)
    # 1) cs.agent 소유의 (u, v2) 후보를 모은다 — Task 1 이 정한 선택자로.
    #    조건은 ForbidAgent 와 같다: isassigned_edge(Xa,u,v2) 이고 !has_edge(sched,u,v2).
    # 2) 각 v2 의 1대당 부담을 잰다. 못 재는 v2 는 **건너뛴다**(0 으로 치지 않는다).
    # 3) 부담 내림차순 상위 cs.n 개 v2 만 남긴다.
    # 4) 그 v2 로 가는 모든 (u, v2) 에 @constraint(model, Xa[u, v2] == 0), 행 수를 센다.
    # 5) 추가한 행 수를 반환한다.
    return n
end
```

🔴 **행 수를 정확히 반환하라.** 반환값이 실제 행 수와 다르면 hollow admit 을 못 잡는다.
🔴 **부담을 못 잰 도착점은 건너뛴다.** "못 쟀다" 를 "부담 0" 으로 접으면 그것이 조용한 오작동이다.

- [ ] **Step 7: 전체 시험**

```
julia +lts --project=. -e 'include("test/forbid_heavy_cargo.jl")'
julia +lts --project=. -e 'include("test/respec_grammar.jl")'     # 문법 왕복이 안 깨졌는지
julia +lts --project=. test/runtests.jl 2>&1 | tail -5
```
🔴 전체 스위트의 기준선은 **2279 pass / 0 fail / 1 error** 다. 그 1 error 는 알려진
`Gurobi Error 10009: No Gurobi license found` 이고 정상이다. **파이프로 자르지 마라** —
요약 줄이 사라진다(이 레인에서 실제로 그 사고가 났다).

- [ ] **Step 8: 커밋**

```bash
git add src/respec/spec_dsl.jl src/respec/compiler.jl src/respec/verifier.jl \
        src/ConstructionBots.jl test/forbid_heavy_cargo.jl test/runtests.jl
git diff --cached --name-status | grep -c '^D'    # 🔴 0 이어야 한다
git commit -m "respec: ForbidHeavyCargo — 1대당 부담 상위 N 화물을 특정 로봇에게 금지"
```
