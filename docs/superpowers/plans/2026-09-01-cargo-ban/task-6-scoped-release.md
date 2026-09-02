# Task 6 — `release_pending_assignments!` 에 범위 인자를 더한다

> 이 태스크는 Task 2·3 과 **독립**이다(먼저 해도 된다).

## 왜 — 지금은 재풀이가 60초에도 답을 못 낸다

L2 도구의 body 는 먼저 **재계산 여지를 열어야** 한다. 안 열면 후보 배정 간선이 0이고 재풀이가
아무것도 못 바꾼다(실측: T13 의 `n_reassigned` 이 closed 0/62/120/170/220/250 **전 구간 0**).

그런데 지금 `release_pending_assignments!` 는 **미래 배정을 전부** 푼다. 실측
(`tools/probes/probe_release_in_harness.jl` · `probe_scoped_release.jl`, colored_8x8, 두 팔 같은 60s 상한):

| closed | 전체 release 후보 | 좁힌 release 후보 | 전체 | **좁힘** |
|---|---|---|---|---|
| 0 | 3832 | 198 | 61.2s TIME_LIMIT gap 0.95 | **0.27s OPTIMAL** |
| 62 | 3356 | 178 | 60.4s TIME_LIMIT gap 0.85 | **0.23s OPTIMAL** |
| 120 | 2304 | 120 | 60.3s TIME_LIMIT gap 0.66 | **0.20s OPTIMAL** |
| 170 | 1500 | 89 | 60.3s TIME_LIMIT gap 0.33 | **0.19s OPTIMAL** |
| 220 | 640 | 58 | 60.2s TIME_LIMIT gap 0.085 | **0.27s OPTIMAL** |
| 250 | 364 | 42 | 60.3s TIME_LIMIT gap 0.0002 | **0.20s OPTIMAL** |

축소가 1/6(로봇 수)이 아니라 **~1/19** 인 이유: 후보는 간선 **쌍**이라 초선형으로 준다.
전체 release 는 후보 364개인 후반에도 60초 안에 최적성을 증명 못 한다.

## Files

- Modify: `src/respec/reassign.jl:121` — `release_pending_assignments!`
- Modify: `wm4spacecraft_manufacturing/core/primitive_registry.json` — `params` 에 `agent` 추가
- Create: `test/scoped_release.jl`
- Modify: `test/runtests.jl`

## 계약

```julia
release_pending_assignments!(env, invariant::InvariantSpec;
                             faulted = nothing,
                             agent::Union{Nothing,AbstractString} = nothing)
```

- `agent === nothing` (기본) → **오늘과 바이트 단위로 같은 동작**. 기존 호출자가 안 깨진다.
- `agent` 를 주면 **그 로봇이 소유한** 미래 배정 간선만 뗀다.

⚠️ `faulted` 와 `agent` 는 **다른 것**이다. `faulted` 는 범위를 **넓힌다**(그 로봇의 진행 중
목표까지 뗀다). `agent` 는 **좁힌다**. 둘 다 주는 경우의 의미를 정하고 docstring 에 적어라 —
정하기 애매하면 **둘 다 주면 error** 로 막아라(조용히 하나를 무시하는 것이 최악이다).

⚠️ "그 로봇이 소유한" 의 판정은 **Task 1 이 정한 선택자와 일관돼야 한다.** Task 1 결과를 읽어라.
(프로브에서는 `CB._edge_owner_id(sched, u)` 의 문자열 비교가 동작했다 — 전체 release 후에도
A 소유 144개를 찾았다.)

- [ ] **Step 1: 실패하는 시험 — 🔴 기본값 보존이 첫 단언이다**

```julia
module ScopedReleaseTests
using Test
using ConstructionBots, Graphs
const CB = ConstructionBots
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "🔴 agent 를 안 주면 오늘과 같은 동작이다" begin
    e1 = fixture(); e2 = fixture()          # 같은 시드, 같은 시점
    r1 = CB.release_pending_assignments!(e1, CB.build_invariant(e1))
    r2 = CB.release_pending_assignments!(e2, CB.build_invariant(e2); agent = nothing)
    @test length(r1) == length(r2)
    @test Set(r1) == Set(r2)
    @test !isempty(r1)                       # 🔴 빈-통과 방지: 실제로 뗀 게 있어야 비교가 뜻이 있다
end

@testset "agent 를 주면 그 로봇 것만 뗀다" begin
    env = fixture(); a = busiest_pending_agent_string(env)
    full = length(CB.release_pending_assignments!(fixture(), CB.build_invariant(env)))
    scoped = CB.release_pending_assignments!(env, CB.build_invariant(env); agent = a)
    @test !isempty(scoped)                   # 🔴 0 개면 이 시험은 공허하다
    @test length(scoped) < full              # 좁아졌다
    # 뗀 간선의 출발점이 전부 그 로봇 소유인가
    for (u, _) in scoped
        o = CB._edge_owner_id(env.sched, u)
        @test o !== nothing && string(o) == a
    end
end
end # module
```

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현** — `reassign.jl:121` 의 keep 규칙에 소유자 필터를 **하나 더** 얹는다.
      기존 keep 규칙(완료/진행중은 유지, faulted 는 비대칭)은 **그대로 두어라.**
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 레지스트리 `params` 에 `agent` 추가**

```json
"agent": {"type": ["string", "null"],
          "description": "release only the future assignment edges owned by this robot; null releases all of them"}
```
🔴 `type` 에 `"null"` 을 반드시 넣어라 — 안 넣으면 기본 호출이 타입 거절된다.

- [ ] **Step 6: 전체 시험** — 기준선 2279 / 0 fail / 1 error.
      `test/primitive_registry_resolves.jl` 과 `test/minted_tool_enacts.jl` 도 따로 돌려라
      (레지스트리 `params` 키를 못박는 게이트가 거기 있다 — 게이트 (12)).
- [ ] **Step 7: 커밋**

```bash
git add src/respec/reassign.jl wm4spacecraft_manufacturing/core/primitive_registry.json \
        test/scoped_release.jl test/runtests.jl
git diff --cached --name-status | grep -c '^D'    # 🔴 0
git commit -m "respec: release_pending_assignments! 에 agent 범위 인자 — 후보 1/19, 0.2s OPTIMAL"
```
