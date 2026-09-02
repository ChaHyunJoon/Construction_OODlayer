# Task 3 — 지속 금지 보관소와 formulate 훅

> **선행:** Task 2 (`ForbidHeavyCargo` 타입과 컴파일러가 있어야 한다).

## 무엇을 만드는가

금지는 **한 번 걸리면 그 로봇의 배터리를 갈아끼울 때까지** 살아있어야 한다(수명은 Task 4).
그러려면 어딘가에 담겨 있어야 하고, **모든 MILP 정식화가 그것을 읽어야** 한다.

🔴 **왜 "모든" 인가** (사용자 결정, 2026-09-01). T13 재풀이만 읽게 하면
`verify` · `fault_robot_and_reassign!` · `rebalance_for_battery!` 가 금지를 무시한다. 그러면
고장 재배정 한 번에 무거운 짐이 그 로봇에게 **돌아간다** — 수명 계약과 모순이다.

## Files

- Create 또는 Modify: 보관소 전역 — `src/respec/spec_dsl.jl` 또는 `src/respec/compiler.jl`
  (구현자가 정한다. `AGENT_COST_BIAS` 가 사는 곳과 같은 계층이면 좋다)
- Modify: `src/essential_tg_coponents.jl:1219-1220` — 훅 두 줄
- Modify: `src/smdp/state_globals.jl` — `:state` 로 등록
- Modify: `src/ConstructionBots.jl` — export
- Create: `test/cargo_ban_store.jl`
- Modify: `test/runtests.jl` — 등록

## Interfaces

- **Produces** (Task 4·5·7 이 쓴다):
  - `STANDING_CARGO_BANS :: Ref{Dict{AbstractID,Int}}` — `{로봇 → n}`
  - `set_cargo_ban!(agent::AbstractID, n::Integer) -> Nothing`
  - `clear_cargo_ban!(agent::AbstractID) -> Bool` — 있었으면 `true`
  - `clear_all_cargo_bans!() -> Nothing`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/cargo_ban_store.jl`:

```julia
module CargoBanStoreTests
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "보관소 기본 계약" begin
    CB.clear_all_cargo_bans!()
    r3 = CB.RobotID(3); r7 = CB.RobotID(7)
    @test isempty(CB.STANDING_CARGO_BANS[])
    CB.set_cargo_ban!(r3, 2)
    @test CB.STANDING_CARGO_BANS[][r3] == 2
    CB.set_cargo_ban!(r7, 1)
    @test length(CB.STANDING_CARGO_BANS[]) == 2
    # 같은 로봇에 다시 걸면 덮어쓴다(중복 누적이 아니다)
    CB.set_cargo_ban!(r3, 3)
    @test CB.STANDING_CARGO_BANS[][r3] == 3
    @test length(CB.STANDING_CARGO_BANS[]) == 2
    @test CB.clear_cargo_ban!(r3) === true
    @test CB.clear_cargo_ban!(r3) === false      # 없는 것을 지우면 false — 조용한 성공 금지
    @test length(CB.STANDING_CARGO_BANS[]) == 1
    CB.clear_all_cargo_bans!()
    @test isempty(CB.STANDING_CARGO_BANS[])
end

@testset "🔴 G-6 롤아웃 경계에서 지워지도록 :state 로 등록돼 있다" begin
    # state_globals.jl 의 분류표에 이름이 있어야 한다. 없으면 이전 판의 금지가 다음 판을 오염시킨다.
    src = read(joinpath(@__DIR__, "..", "src", "smdp", "state_globals.jl"), String)
    @test occursin("STANDING_CARGO_BANS", src)
    @test occursin(r":STANDING_CARGO_BANS\s*=>\s*:state", src)
end
end # module
```

- [ ] **Step 2: 실패 확인** — `julia +lts --project=. -e 'include("test/cargo_ban_store.jl")'`

- [ ] **Step 3: 보관소를 만든다**

```julia
"""
    STANDING_CARGO_BANS

지금 살아있는 화물 금지들: `{로봇 id → n}`. `ForbidHeavyCargo(로봇, n)` 로 컴파일된다.

🔴 **에피소드 중에 변한다** — `src/smdp/state_globals.jl` 에 **`:state` 로 등록해야 한다.**
선례는 같은 파일의 `:AGENT_COST_BIAS => :state  # Deprioritize 의 지연 효과` 다. 등록을
빠뜨리면 롤아웃 경계에서 안 지워져 **이전 판의 금지가 다음 판을 오염시킨다.**

수명은 "그 로봇에 `swap_battery!` 가 일어날 때까지" 다(사용자 결정 2026-09-01) —
술어가 아니라 **사건**이라 임계값도 확인 시점도 정할 필요가 없다.
"""
const STANDING_CARGO_BANS = Ref(Dict{AbstractID,Int}())

set_cargo_ban!(agent::AbstractID, n::Integer) = (STANDING_CARGO_BANS[][agent] = Int(n); nothing)
"있었으면 지우고 `true`, 없었으면 `false`. 🔴 조용한 성공을 만들지 않으려고 값을 돌려준다."
clear_cargo_ban!(agent::AbstractID) = (pop!(STANDING_CARGO_BANS[], agent, nothing) !== nothing)
clear_all_cargo_bans!() = (empty!(STANDING_CARGO_BANS[]); nothing)
```

`state_globals.jl` 의 분류표에 추가:
```julia
:STANDING_CARGO_BANS    => :state,   # 화물 금지. swap_battery! 까지 산다
```

- [ ] **Step 4: formulate 훅 — 한 자리다**

`src/essential_tg_coponents.jl:1219-1220` 을 이렇게 바꾼다:

```julia
    if extra_constraints !== nothing
        compile_proposal!(model, t0, tF, Xa, sched, extra_constraints)   # LLM 재명세 제약
    end
    # 🔴 지속 화물 금지: **모든** formulate 가 읽는다(사용자 결정 2026-09-01).
    #    T13 재풀이만 읽게 하면 verify · fault_robot_and_reassign! · rebalance_for_battery! 가
    #    금지를 무시해서, 고장 재배정 한 번에 무거운 짐이 그 로봇에게 돌아간다.
    _compile_standing_cargo_bans!(model, t0, tF, Xa, sched)
```

```julia
"살아있는 화물 금지를 전부 컴파일한다. 추가한 행 수를 반환."
function _compile_standing_cargo_bans!(model, t0, tF, Xa, sched)
    isempty(STANDING_CARGO_BANS[]) && return 0
    n = 0
    # 🔴 순회 순서를 고정한다 — Dict 순회 순서가 모델 구성 순서를 바꾸면 같은 시드가 다른 판을
    #    만든다(이 레포가 이미 데인 축: MEMORY.md sim-runs-must-be-seed-reproducible).
    for agent in sort(collect(keys(STANDING_CARGO_BANS[])), by = string)
        n += compile_constraint!(model, t0, tF, Xa, sched,
                                 ForbidHeavyCargo(agent, STANDING_CARGO_BANS[][agent]))
    end
    return n
end
```

⚠️ `essential_tg_coponents.jl` 이 `compile_constraint!`·`ForbidHeavyCargo` 를 볼 수 있는지
**확인하라**(include 순서). 안 보이면 훅을 호출만 하고 구현은 `compiler.jl` 에 두는 식으로
방향을 뒤집어라 — 순환 의존을 만들지 마라.

- [ ] **Step 5: 🔴 G-5 — 다른 경로도 읽는지 잰다**

```julia
@testset "🔴 G-5 verify 와 rebalance 경로도 금지를 읽는다" begin
    env = fixture(); agent = busiest_pending_agent(env)
    CB.clear_all_cargo_bans!()
    inv = CB.build_invariant(env)
    CB.release_pending_assignments!(env, inv)
    # 금지 없이 formulate → 그 로봇이 그 화물을 가져가는 해가 존재한다(양성 대조)
    # 금지 걸고 같은 경로(verify 가 쓰는 formulate)로 → 그 배정이 불가능해진다
    # 🔴 두 판의 "누른 행 수" 를 함께 찍어라. 0 이면 이 시험은 공허하다.
end
```

⚠️ **양성 대조 없이 "금지 후 안 가져감" 만 보면 공허하다.** 금지 전에는 **가져갔다**는 것을
같은 픽스처에서 먼저 보여라.

- [ ] **Step 6: 전체 시험** — Task 2 Step 7 과 같다. 기준선 **2279 / 0 fail / 1 error**.

- [ ] **Step 7: 커밋**

```bash
git add src/respec/spec_dsl.jl src/essential_tg_coponents.jl src/smdp/state_globals.jl \
        src/ConstructionBots.jl test/cargo_ban_store.jl test/runtests.jl
git diff --cached --name-status | grep -c '^D'    # 🔴 0
git commit -m "respec: 지속 화물 금지 보관소 — 모든 formulate 가 읽는다"
```
