# 호출 가능한 세계 인터페이스 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OOD 사건 하나에서 LLM 이 **등록되고 · 인자를 받고 · 예외 없이 돌아 · 세계를 바꾸는** Julia 함수 하나를 내게 한다 (설계 §0 의 L1–L4).

**Architecture:** 사슬 일곱 칸 중 셋만 고친다. ③ agent-3 이 보는 인터페이스(폐포 · 무타입 컨테이너 · `env` 밖 상태 · 도달 경로 · `needs` 채널), ⑤ 등록 직전 정적 검사, ⑦ 인자 변환 · 되먹임 · 세계 계측. agent-1·agent-2 의 프롬프트와 규약 다섯은 **한 글자도 안 바꾼다**.

**Tech Stack:** Julia 1.10 (ConstructionBots, InteractiveUtils, JSON3, Graphs) · Python 3.12 (dspy 3.3, FastAPI, pytest)

**Spec:** `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` (결정 D9–D19)

## Global Constraints

- **TDD 필수.** 모든 생산 코드는 먼저 빨간 시험을 보고 쓴다. 시험을 못 봤으면 코드를 지우고 다시 시작한다.
- **삼상 규약.** `nothing`("못 쟀다") · `false`/`[]`("재서 없다") · 값 — 셋을 절대 섞지 않는다.
- **예외가 아니라 거절.** 집행 경로에서 새는 예외는 `enact_minted!` 를 기록 대신 예외로 끝내고 호출자가 세계 상태를 잃는다. 모든 실패는 `:reject` 와 사유 문자열이다.
- **진실원 하나.** 같은 사실을 두 곳에 적지 않는다.
- **커밋은 명시 경로로만.** 작업트리에 **다른 세션의 미커밋 삭제 218건**이 있다. `git add -A` 금지. 푸시 금지.
- **grep 주의.** 이 셸의 `grep` 은 gitignore 를 따르는 ugrep 래퍼다. 레포 전체 주장은 `/usr/bin/grep`.
- **`_RULES`(`world_interface.py`)와 agent-2 프롬프트 문자열은 안 바꾼다** (D19 — D6 측정의 대조군).
- **규약 4 는 안 푼다** (D14 — 설계 §1.4). 이미 게이트가 있다:
  `test/minted_registration.jl` 테스트셋 (20) 이 run 2 의 실제 코드에 대해 사유가
  정확히 `"reject:impl_not_single_expression:2"` 임을 바이트로 못박는다. 새 검사를
  더할 때 그 시험이 빨개지면 **검사의 자리가 틀린 것**이지 규약이 틀린 것이 아니다.
- Julia 단일 파일: `julia +lts --project=. -e 'include("test/<f>.jl")'`
- Julia 전체: `julia +lts --project=. -e 'using Pkg; Pkg.test()'`
- 🔴 **전체 스위트의 기준선**(2026-09-03, 이 작업트리에서 실측):
  **2374 passed · 0 failed · 1 errored · 0 broken**, 10분 07초.
  그 1건은 `Demo` 테스트셋의 `Gurobi Error 10009: No Gurobi license found` 로 **환경 문제이고 기대값이다**.
  "회귀 없음" 은 **이 수와 같다**는 뜻이다 — `2374/0/1/0` 이 아니면 회귀다.
- Python: 레포 루트에서 `python3 -m pytest -q src/respec/llm_service/`

## 시간 — 측정된 검증 비용

🔴 아래 **검증 비용은 이 계획을 쓰면서 실제로 잰 것**이다(`/usr/bin/time`, 2026-09-03, 이 작업트리).
"구현" 열은 **추정**이고 측정치가 아니다 — 그 둘을 섞어 읽지 말 것.

| 명령 | 측정 |
|---|---|
| `julia … tools/gen_world_interface.jl <out>` (생성기 단독) | **10.8 s** |
| `include("test/world_interface_current.jl")` (서브프로세스 재생성 포함) | **20.8 s** |
| `include("test/minted_registration.jl")` | **14.1 s** |
| `include("test/minted_end_to_end.jl")` | **23.8 s** |
| `pytest -q src/respec/llm_service/` (357 passed · 5 skipped) | **15.7 s** |
| `CB.include(navigator/navigator.jl)` (런타임 include 한 번) | **1.9 s** |
| `Pkg.test()` (전체 Julia 스위트) | **10 분 07 초** (벽시계 607.5s · 테스트셋 합 9m44.3s) |

| Task | 결정 | 검증 명령 (측정 합) | 구현 추정 |
|---|---|---|---|
| 1 | D10 | 전체 Julia 스위트 **10m07s** + 게이트 20.8s | 20 분 |
| 2 | D9 | 새 시험 ~15s + 게이트 20.8s | 90 분 |
| 3 | D12 | 게이트 20.8s + 전체 Julia 스위트 **10m07s** | 45 분 |
| 4 | D11 | 새 시험 ~15s + 게이트 20.8s + pytest 15.7s | 90 분 |
| 5 | D13 | pytest 15.7s | 30 분 |
| 6 | D15 | minted_registration 14.1s + e2e 23.8s | 90 분 |
| 7 | D16 | minted_registration 14.1s + e2e 23.8s | 60 분 |
| 8 | D18 | e2e 23.8s | 45 분 |
| 9 | D17 | pytest 15.7s + e2e 23.8s | 90 분 |
| 10 | — | 유료 런 1회 (사건당 최대 7+1 호출) | 30 분 |

⚠️ Task 1 과 3 만 전체 스위트를 부른다(둘 다 `src/` 의 생산 코드를 바꾼다). 나머지 여덟은
파일 단위 시험으로 충분하고, 그래서 반복 주기가 20–40초다.

## File Structure

| 파일 | 책임 | Task |
|---|---|---|
| `src/route_planning.jl` | `PlannerEnv` 필드 선언 — 두 `Dict` 를 좁힌다 | 1 |
| `src/ConstructionBots.jl` | export 목록 — `battery_report` 하나 추가 | 3 |
| `tools/gen_world_interface.jl` | 산출물 생성기. 폐포 · 앰비언트 · 도달 경로 · 호출가능성 | 2·3·4 |
| `wm4spacecraft_manufacturing/core/world_interface.json` | 산출물(생성물, 커밋됨) | 2·3·4 |
| `test/world_interface_closure.jl` | **신설** — 폐포/도달경로 로직의 단위 시험 | 2·4 |
| `test/world_interface_current.jl` | 산출물 ↔ 현행 코드 게이트 | 1·2·3·4 |
| `src/respec/llm_service/world_interface.py` | 산출물 → 프롬프트 블록 렌더 | 3·4 |
| `src/respec/llm_service/synthesize.py` | `WriteToolImpl` 계약 · `needs` · `/rewrite` 프로그램 | 5·9 |
| `src/respec/llm_service/dspy_service.py` | `/rewrite` 엔드포인트 | 9 |
| `src/respec/minted_registration.jl` | 규약 검사 · 정적 검사 · `param_types` 추출 | 6·7 |
| `src/respec/minted_tool.jl` | `bind_primitive_args` 의 타입 변환 | 7 |
| `tools/monitor/enact.jl` | 세계 다이제스트 · `/rewrite` 왕복 | 8·9 |
| `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md` | 사전등록 갱신 | 10 |

---

### Task 1: `PlannerEnv` 의 무타입 `Dict` 둘을 좁힌다 (D10)

`agent_policies::Dict` 는 선언 타입이 맨 `Dict` 라 정보가 0이다. 어떤 폐포 깊이로도
`VelocityController` 에 도달하지 못한다 — 그 값 타입이 **선언에 없기 때문**이다.
Task 2 의 폐포가 의미를 가지려면 이것이 먼저 들어와야 한다.

**Files:**
- Modify: `src/route_planning.jl:115-116`
- Modify: `test/world_interface_current.jl` (테스트셋 (5) 추가)
- Modify: `wm4spacecraft_manufacturing/core/world_interface.json` (재생성물)

**Interfaces:**
- Produces: `world_interface.json` 의 `PlannerEnv.agent_policies.type` 문자열이
  `VelocityController` 를 포함한다. Task 2 의 폐포가 이 문자열을 따라간다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/world_interface_current.jl` 의 `end # module` **앞**에 붙인다:

```julia
@testset "(5) 🔴 D10: 무타입 Dict 두 개가 값 타입을 말한다" begin
    j = JSON3.read(read(ART, String))
    t = only(filter(x -> x.name == "PlannerEnv", collect(j.types)))
    ft = Dict(String(f.name) => String(f.type) for f in t.fields)
    # 🔴 이것이 없으면 모델은 `robot.charge` 를 지어낸다 (설계 §1.5)
    @test occursin("VelocityController", ft["agent_policies"])
    @test occursin("Bool", ft["agent_parent_build_step_active"])
    # 빈-통과 방지: 이미 타입이 실려 있던 필드는 그대로여야 한다
    @test occursin("Ball2", ft["staging_circles"])
    @test occursin("Float64", ft["staging_buffers"])
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: 테스트셋 (5) 의 첫 두 `@test` 가 FAIL (`ft["agent_policies"] == "Dict"`).
⏱ 약 21초.

- [ ] **Step 3: 선언을 좁힌다**

`src/route_planning.jl:115-116` 을 이렇게 바꾼다:

```julia
    agent_policies::Dict{AbstractID,VelocityController} = Dict{AbstractID,VelocityController}()   # 각 에이전트(로봇)의 이동 정책(TangentBug/포텐셜장 등)
    agent_parent_build_step_active::Dict{AbstractID,Bool} = Dict{AbstractID,Bool}()               # 각 에이전트의 상위 조립단계 활성 여부 캐시
```

🔴 `VelocityController` 는 같은 파일 `:975` 에 정의돼 있지만 **`PlannerEnv` 보다 뒤**다.
Julia 는 struct 필드의 타입 주석을 정의 시점에 해석하므로, 좁히기 전에
`VelocityController` 정의를 `PlannerEnv` 정의보다 **앞으로 옮겨야** 한다. 옮기는 것은
`@with_kw mutable struct VelocityController … end` 블록(`:975-979`) 하나뿐이고, 그 위의
주석도 함께 옮긴다.

- [ ] **Step 4: 산출물을 재생성한다**

```bash
julia +lts --project=. tools/gen_world_interface.jl
```
Expected: `wrote …/world_interface.json`. ⏱ 약 11초.

- [ ] **Step 5: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: 테스트셋 (1)–(5) 전부 PASS. ⏱ 약 21초.

- [ ] **Step 6: 🔴 전체 스위트로 회귀를 확인한다**

Run: `julia +lts --project=. -e 'using Pkg; Pkg.test()'`
Expected: 이 작업트리의 기준선과 같은 수. **Gurobi 라이선스 에러 1건은 환경 문제로 기대값이다.**
🔴 이 단계를 건너뛰지 말 것 — 이 태스크는 시뮬레이터의 생산 타입을 바꾼다.
소비자는 세 파일뿐이지만(`full_demo.jl:817` 이 쓰고, `potential_fields.jl:220,351` 과
`route_planning.jl:410,1015,1064` 가 읽는다) 그 사실은 grep 이지 시험이 아니다.
⏱ **10 분 07 초**(실측).

- [ ] **Step 7: 커밋**

```bash
git add src/route_planning.jl test/world_interface_current.jl \
        wm4spacecraft_manufacturing/core/world_interface.json
git commit -m "D10: PlannerEnv 의 무타입 Dict 둘을 좁힌다 — 폐포가 따라갈 값 타입을 만든다"
```

---

### Task 2: 타입 전개를 고정점으로 만든다 (D9)

오늘 생성기는 `PlannerEnv` 한 뿌리를 **1단계만** 전개한다 — 필드까지 실린 타입이 4개,
이름만 등장하는 타입이 9개다. 모델이 정확히 쓴 것은 전부 정의된 타입이고 지어낸 것은
전부 침묵한 타입이다(설계 §1.5, 예외 없음).

**Files:**
- Modify: `tools/gen_world_interface.jl`
- Create: `test/world_interface_closure.jl`
- Modify: `test/world_interface_current.jl` (테스트셋 (6) 추가)
- Modify: `wm4spacecraft_manufacturing/core/world_interface.json` (재생성물)

**Interfaces:**
- Consumes: Task 1 의 좁힌 선언.
- Produces: `tools/gen_world_interface.jl` 이 다음을 export 한다(같은 파일 안 함수) —
  `_unwrap(T)` · `_tname(T)::String` · `_type_candidates!(acc, T, d=0)` ·
  `_defined_in_cb(S)::Bool` · `world_type_closure()::Vector{DataType}` (이름 정렬).
  Task 4 가 `world_type_closure()` 를 그대로 쓴다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/world_interface_closure.jl
module WorldInterfaceClosure
using Test
using ConstructionBots
import JSON3
const CB = ConstructionBots
const GEN = normpath(joinpath(@__DIR__, "..", "tools", "gen_world_interface.jl"))
const ART = normpath(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "core",
                              "world_interface.json"))

@testset "(1) 폐포가 run 3 이 지어낸 타입들에 실제로 도달한다" begin
    j = JSON3.read(read(ART, String))
    names_in = Set(String[String(t.name) for t in j.types])
    # 🔴 run 3 은 `node.assigned_robot` 을 지어냈다. ScheduleNode 의 실제 필드는 (id, node, spec).
    @test "ScheduleNode" in names_in
    # 🔴 run 3 은 `robot.charge` 를 지어냈다. 값 타입은 VelocityController 이고 그런 필드가 없다.
    @test "VelocityController" in names_in
    @test "PathSpec" in names_in
    @test "AbstractID" in names_in
end

@testset "(2) 추상 타입은 필드가 아니라 subtypes 를 싣는다" begin
    # 🔴 `fieldnames(SceneTreeEdge)` 는 ArgumentError 를 **던진다**(실측).
    #    순진한 전이 전개는 생성기를 죽인다.
    j = JSON3.read(read(ART, String))
    e = only(filter(x -> x.name == "SceneTreeEdge", collect(j.types)))
    @test haskey(e, :subtypes) && !haskey(e, :fields)
    @test Set(String.(collect(e.subtypes))) == Set(["PermanentEdge", "TemporaryEdge"])
    # 빈-통과 방지: 구상 타입은 반대여야 한다
    s = only(filter(x -> x.name == "ScheduleNode", collect(j.types)))
    @test haskey(s, :fields) && !haskey(s, :subtypes)
    @test Set(String[String(f.name) for f in s.fields]) == Set(["id", "node", "spec"])
end

@testset "(3) 🔴 서드파티 타입은 절대 안 들어온다 — 폐포가 폭발한다" begin
    # 실측: 필터를 풀면 깊이 2 에서 1,302 타입, 깊이 3 에서 25,160 타입.
    j = JSON3.read(read(ART, String))
    ns = Set(String[String(t.name) for t in j.types])
    for gone in ("Dict", "Set", "SimpleDiGraph", "PriorityQueue", "Ball2")
        @test !(gone in ns)
    end
    @test 40 <= length(ns) <= 120   # 상한: 폭발 트립와이어. 실측 66.
end

@testset "(4) 폐포는 이름으로 정렬돼 결정적이다" begin
    # 🔴 `subtypes` 의 반환 순서는 계약이 아니다. 정렬이 없으면 게이트 (2) 의 바이트
    #    비교가 실행마다 이유 없이 흔들린다 (`method_entries` 의 MergeSort 와 같은 논거).
    j = JSON3.read(read(ART, String))
    ns = String[String(t.name) for t in j.types]
    @test ns == sort(ns)
end
end # module
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_closure.jl")'`
Expected: (1) 의 `ScheduleNode`/`VelocityController`/`PathSpec` FAIL, (2) FAIL
(`SceneTreeEdge` 항목 자체가 없어 `only` 가 던진다), (4) 는 오늘의 4개가 우연히
정렬돼 있으면 PASS 일 수 있다 — 그것은 빈-통과이고 (1)·(2) 가 게이트다. ⏱ 약 15초.

- [ ] **Step 3: 생성기의 전개를 고정점으로 바꾼다**

`tools/gen_world_interface.jl` 의 맨 위 `using` 에 `InteractiveUtils` 를 더한다
(🔴 `subtypes` 가 거기 있다 — 없으면 `UndefVarError` 다, 실측).

`_tname` 과 `type_entry` 를 바꾸고, `:90-101` 의 루프 전체를 아래로 교체한다:

```julia
using InteractiveUtils     # subtypes

_unwrap(T) = T isa UnionAll ? Base.unwrap_unionall(T) : T

# 🔴 `Union` 에는 `nameof` 가 없다 — `apply_cmd!(node::Union{TransportUnitGo,RobotGo}, …)`
#    의 렌더가 정확히 여기서 MethodError 로 죽는다(실측).
function _tname(T)
    S = _unwrap(T)
    S isa DataType ? string(nameof(S)) : string(T)
end

"""
    _type_candidates!(acc, T, d=0)

필드 타입 하나에서 "모델이 알아야 할 타입" 을 전부 뽑아 `acc` 에 넣는다.
`Dict{AbstractID,Ball2}` 는 자기 자신 + `AbstractID` + `Ball2` 를 낳는다.
`TypeVar` 는 상한(`ub`)으로 내려간다. `Union` 은 양쪽으로 갈라진다.
`d` 는 **타입 매개변수 중첩**의 상한이지 폐포의 깊이가 아니다 — 폐포는 고정점이다.
"""
function _type_candidates!(acc, T, d = 0)
    d > 4 && return acc
    T isa TypeVar && return _type_candidates!(acc, T.ub, d + 1)
    if T isa Union
        _type_candidates!(acc, T.a, d + 1); _type_candidates!(acc, T.b, d + 1); return acc
    end
    S = _unwrap(T)
    S isa DataType || return acc
    push!(acc, S)
    for p in S.parameters
        (p isa Type || p isa TypeVar) && _type_candidates!(acc, p, d + 1)
    end
    return acc
end

"""
    world_type_closure() -> Vector{DataType}

`PlannerEnv` **와 `PlannerEnv` 를 인자로 받는 모든 메서드의 인자 타입**을 씨앗으로,
CB 소유 타입만 따라가는 고정점. 이름으로 정렬해 반환한다.

🔴 **씨앗에 메서드 인자를 넣는 이유**(설측). 필드만 따라가면 49타입이고
`PlannerEnv` 를 받는 23개 메서드 중 13개만 호출 가능해진다. 메서드 인자까지 넣으면
66타입이고 **23개 전부**가 열린다 — 새로 열리는 11개는 전부 `apply_cmd!`(7)·
`close_node!`(4) 로, 스케줄 노드를 실제로 여닫고 명령을 먹이는 유일한 공개 경로다.

🔴 **CB-only 필터는 절대 풀지 않는다.** 실측: 풀면 깊이 2 에서 1,302타입,
깊이 3 에서 25,160타입이다.
"""
function world_type_closure()
    seeds = Any[CB.PlannerEnv]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(_unwrap(m.sig).parameters)[2:end]
            any(T -> _unwrap(T) === CB.PlannerEnv, Ts) || continue
            for T in Ts; _type_candidates!(seeds, T); end
        end
    end
    seen = Dict{String,DataType}()
    frontier = copy(seeds)
    while !isempty(frontier)
        S = _unwrap(popfirst!(frontier))
        S isa DataType || continue
        n = _tname(S)
        (haskey(seen, n) || !_defined_in_cb(S)) && continue
        seen[n] = S
        nexts = Any[]
        if isabstracttype(S)
            append!(nexts, subtypes(S))
        else
            try
                for ft in fieldtypes(S); _type_candidates!(nexts, ft); end
            catch
                # 🔴 구상 타입인데 fieldtypes 가 던지는 모양은 오늘 없다. 던지면
                #    그 타입은 필드 없이 실린다 — 조용한 폴백이 아니라 아래 type_entry
                #    가 같은 판정을 다시 하고 정직하게 빈 fields 를 낸다.
            end
        end
        append!(frontier, nexts)
    end
    # 🔴 `subtypes` 의 순서는 계약이 아니다. 정렬해야 게이트 (2) 의 바이트 비교가 산다.
    return DataType[seen[k] for k in sort(collect(keys(seen)))]
end

"""
    type_entry(T) -> Dict

구상 타입이면 `fields`, 추상 타입이면 `subtypes`. **둘 다 실지 않는다** —
독자(시험 (2)·파이썬 렌더)가 어느 쪽인지로 분기한다.

🔴 `fieldnames(SceneTreeEdge)` 는 `ArgumentError: type does not have a definite
   number of fields` 를 **던진다**(실측). 추상 타입에 필드를 물으면 안 된다.
"""
function type_entry(T)
    S = _unwrap(T)
    isabstracttype(S) && return Dict(
        "name" => _tname(S),
        "subtypes" => sort(String[_tname(U) for U in subtypes(S)]))
    return Dict(
        "name" => _tname(S),
        "fields" => [Dict("name" => string(f), "type" => string(t))
                     for (f, t) in zip(fieldnames(S), fieldtypes(S))])
end
```

그리고 `:90-101` 의 손으로 쓴 루프(`roots = [CB.PlannerEnv]` … `end`)를 **지우고**
아래 한 줄로 바꾼다:

```julia
types = Dict{String,Any}[type_entry(T) for T in world_type_closure()]
```

- [ ] **Step 4: 산출물을 재생성한다**

```bash
julia +lts --project=. tools/gen_world_interface.jl
```
Expected: `wrote …`. ⏱ 약 11초. 확인:

```bash
python3 -c "
import json; d=json.load(open('wm4spacecraft_manufacturing/core/world_interface.json'))
print('types', len(d['types']), 'methods', len(d['methods']))"
```
Expected: `types 66 methods 208` (타입 수는 Task 1 의 좁힘이 들어온 뒤의 값이다 —
66 에서 ±2 는 정상이지만 4 나 1,302 이면 무언가 틀렸다).

- [ ] **Step 5: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_closure.jl")'`
Expected: 4개 테스트셋 전부 PASS. ⏱ 약 15초.

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: (1)–(5) 전부 PASS — 특히 (2)(서브프로세스 재생성 바이트 비교)와
(4)(`release_pending_assignments!` 부재)가 살아 있어야 한다. ⏱ 약 21초.

- [ ] **Step 6: 게이트에 폭발 트립와이어를 더한다**

`test/world_interface_current.jl` 의 `end # module` 앞에:

```julia
@testset "(6) 🔴 폐포가 폭발하지 않았다" begin
    j = JSON3.read(read(ART, String))
    @test 40 <= length(j.types) <= 120     # 실측 66. 서드파티 필터를 풀면 1,302 이상이다.
    @test !isempty(j.methods)
end
```

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: (1)–(6) PASS. ⏱ 약 21초.

- [ ] **Step 7: 커밋**

```bash
git add tools/gen_world_interface.jl test/world_interface_closure.jl \
        test/world_interface_current.jl \
        wm4spacecraft_manufacturing/core/world_interface.json
git commit -m "D9: 타입 전개를 고정점으로 — 4타입 → 66타입, env 메서드 23개가 전부 열린다"
```

---

### Task 3: `env` 밖의 세계 상태를 싣는다 (D12)

🔴 battery OOD 의 SoC 는 `PlannerEnv` 의 필드가 **아니다** — 모듈 전역
`BATTERY_FLEET::Ref{Union{Nothing,BatteryFleet}}`(`src/navigator/battery.jl:111`)에 산다.
Task 1·2 를 다 해도 폐포는 `env` 를 따라가므로 거기 못 닿는다. **모델은 `robot.charge` 를
또 지어낸다.**

측정된 배관 사실 둘:
1. `src/navigator/navigator.jl` 은 **런타임 include** 다. 정적 `using ConstructionBots` 만
   한 생성기에는 `battery_report` 가 **아예 없다**(`UndefVarError`, 실측).
2. 그 파일들에는 `export` 문이 없다 — include 해도 `names(CB)` 는 186 그대로다(실측).
   그러므로 `ConstructionBots.jl` 의 export 목록에 **손으로 한 이름을 더해야** 한다.

집행 경로는 안전하다: `tools/monitor/render_demo.jl:18` 이 navigator 를 먼저 include 하고
`policy.jl` 은 그 뒤에만 include 된다(`policy.jl:480` 의 주석이 그 순서를 적는다).

**Files:**
- Modify: `src/ConstructionBots.jl` (export 목록 `:105-109` 근처)
- Modify: `tools/gen_world_interface.jl`
- Modify: `src/respec/llm_service/world_interface.py`
- Modify: `test/world_interface_current.jl` (테스트셋 (7) 추가)
- Modify: `wm4spacecraft_manufacturing/core/world_interface.json` (재생성물)

**Interfaces:**
- Produces: 산출물에 `"ambient"` 키가 생긴다 —
  `[{"name": "battery fleet", "accessor": "battery_report()", "returns": "<문자열>"}]`.
  `build_world_interface_block` 이 그것을 `AMBIENT WORLD STATE` 표제로 렌더한다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/world_interface_current.jl` 의 `end # module` 앞에:

```julia
@testset "(7) 🔴 D12: env 밖 세계 상태가 실리고, 그 접근자는 실제로 부를 수 있다" begin
    j = JSON3.read(read(ART, String))
    @test haskey(j, :ambient) && !isempty(j.ambient)
    accs = Set(String[String(a.accessor) for a in j.ambient])
    @test "battery_report()" in accs
    # 🔴 산출물이 **부를 수 없는 이름을 광고하면 안 된다**. 접근자의 이름이 실제로
    #    export 표면에 있어야 한다 — 없으면 모델이 그것을 부르고 UndefVarError 로 죽는다.
    ms = Set(String[String(m.name) for m in j.methods])
    for a in j.ambient
        base = first(split(String(a.accessor), "("))
        @test base in ms
    end
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_current.jl")'`
Expected: (7) 의 첫 `@test` 가 FAIL (`haskey(j, :ambient)` 가 false). ⏱ 약 21초.

- [ ] **Step 3: `battery_report` 를 export 한다**

`src/ConstructionBots.jl` 의 battery 줄(`:109`)에 이어 붙인다:

```julia
       dispatch_battery_courier!, battery_courier_step!, clear_battery_deliveries!,
       battery_report,                                           # D12: SoC 읽기(순수). 정의는 navigator/battery.jl(런타임 include)
```

🔴 **이것은 D6 위반이 아니다.** D6 이 감추는 것은 세계를 바꾸는 **능력**이고
`battery_report` 는 순수 읽기다. 감춘 다섯(`release_pending_assignments!` 외)은 그대로다.

- [ ] **Step 4: 생성기가 navigator 를 로드하고 ambient 를 낸다**

`tools/gen_world_interface.jl` 의 `const CB = ConstructionBots` **바로 뒤**에:

```julia
# 🔴 navigator 층은 **런타임 include** 다(`src/navigator/navigator.jl`). 그것 없이는
#    `battery_report` 가 아예 정의되지 않아(실측: UndefVarError) 아래 method_entries 의
#    `isdefined` 검사에서 조용히 빠진다 — 산출물이 export 목록과 어긋난다.
#    집행 경로도 같은 include 를 한다(`tools/monitor/render_demo.jl:18`), 그러므로
#    생성기와 런타임이 **같은 모듈**을 본다. 비용은 1.9초(실측).
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

"""
앰비언트 세계 상태 — `PlannerEnv` 에 없지만 세계인 것. **손으로 유지되는 유일한 목록**이고,
그래서 게이트 `(7)` 이 "접근자가 `names(CB)` 에 있다" 를 지킨다.
"""
const AMBIENT_ROOTS = [
    (name = "battery fleet", accessor = "battery_report()",
     returns = "(total_energy_J::Float64, min_soc::Float64, mean_soc::Float64, " *
               "soc_spread::Float64, n_depleted::Int, soc::Dict{Any,Float64})"),
]
```

`JSON3.pretty` 호출의 dict 에 키를 하나 더한다:

```julia
    JSON3.pretty(io, Dict("types" => types,
                          "methods" => method_entries(),
                          "ambient" => [Dict("name" => a.name, "accessor" => a.accessor,
                                             "returns" => a.returns)
                                        for a in AMBIENT_ROOTS]))
```

- [ ] **Step 5: 파이썬 렌더에 표제를 더한다**

`src/respec/llm_service/world_interface.py` 의 `build_world_interface_block` 에서,
`WORLD TYPES` 블록과 `FUNCTIONS` 블록 **사이**에 넣는다:

```python
    amb = b.get("ambient") or []
    if amb:
        parts += ["", "AMBIENT WORLD STATE (not on env; read it with the accessor shown):"]
        for a in amb:
            parts.append("- %s" % a["name"])
            parts.append("    %s  ->  %s" % (a["accessor"], a["returns"]))
```

🔴 `_RULES` 는 한 글자도 안 바꾼다 (D19).

- [ ] **Step 6: 산출물을 재생성하고 초록을 확인한다**

```bash
julia +lts --project=. tools/gen_world_interface.jl
julia +lts --project=. -e 'include("test/world_interface_current.jl")'
```
Expected: (1)–(7) PASS. ⏱ 약 11초 + 21초.

Python 쪽 확인:
```bash
cd src/respec/llm_service && python3 -c "
import world_interface as WI
b = WI.build_world_interface_block()
assert 'AMBIENT WORLD STATE' in b and 'battery_report()' in b, 'ambient 블록이 안 렌더된다'
print('ok — block chars', len(b))"
```

- [ ] **Step 7: 🔴 전체 스위트로 회귀를 확인한다**

Run: `julia +lts --project=. -e 'using Pkg; Pkg.test()'`
Expected: 기준선과 같은 수. 🔴 export 목록을 바꾸면 `using ConstructionBots` 하는 모든
파일의 이름 해석이 바뀔 수 있다 — 특히 `battery_report` 라는 이름을 자기 스코프에서
따로 정의하는 파일이 있으면 충돌한다. ⏱ **10 분 07 초**(실측).

- [ ] **Step 8: 커밋**

```bash
git add src/ConstructionBots.jl tools/gen_world_interface.jl \
        src/respec/llm_service/world_interface.py test/world_interface_current.jl \
        wm4spacecraft_manufacturing/core/world_interface.json
git commit -m "D12: env 밖 세계 상태(battery SoC)를 인터페이스에 싣는다 — 생성기가 navigator 를 로드한다"
```

---

### Task 4: 도달 경로와 호출 가능성 (D11)

모델은 208줄짜리 평평한 이름 목록을 보고 "선택자가 없다" 고 판단해 placeholder 를 썼다
(설계 §1.2). 인자마다 `env` 로부터의 경로가 붙으면 부를 수 있는 것이 **호출부째로** 손에 들어온다.

**Files:**
- Modify: `tools/gen_world_interface.jl`
- Modify: `src/respec/llm_service/world_interface.py`
- Modify: `test/world_interface_closure.jl` (테스트셋 (5)(6) 추가)
- Create: `src/respec/llm_service/test_world_interface_render.py`
- Modify: `wm4spacecraft_manufacturing/core/world_interface.json` (재생성물)

**Interfaces:**
- Consumes: Task 2 의 `world_type_closure()` · `_tname` · `_unwrap`.
- Produces: 산출물에 `"access"` 키(`{타입이름: [경로문자열, …]}`)가 생기고, `methods` 의 각
  항목에 `"callable"::Bool` 과 `"argpaths"::Vector{String}` 이 붙는다.

- [ ] **Step 1: 실패하는 시험을 쓴다 (Julia 쪽)**

`test/world_interface_closure.jl` 의 `end # module` 앞에:

```julia
@testset "(5) 도달 경로 색인이 run 3 이 필요로 한 타입들을 짚는다" begin
    j = JSON3.read(read(ART, String))
    @test haskey(j, :access)
    acc = Dict(String(k) => String[String(x) for x in v] for (k, v) in pairs(j.access))
    @test any(p -> occursin("env.sched.nodes", p), acc["ScheduleNode"])
    @test any(p -> occursin("env.agent_policies", p), acc["VelocityController"])
    # 빈-통과 방지: 도달 못 하는 타입은 색인에 키가 없거나 빈 목록이다
    @test all(v -> v isa Vector, values(acc))
end

@testset "(6) 🔴 호출 가능성 분할 — 오늘 5 에서 16 으로" begin
    j = JSON3.read(read(ART, String))
    ms = collect(j.methods)
    @test all(m -> haskey(m, :callable), ms)
    envms = [m for m in ms if occursin("PlannerEnv", String(m.signature))]
    @test length(envms) == 23                      # 실측
    ok = [m for m in envms if m.callable === true]
    @test length(ok) == 23                         # D9 의 씨앗 확장이 전부 연다
    bang = [m for m in ok if endswith(String(m.name), "!")]
    @test length(bang) == 16                       # 오늘은 5 였다
    @test "apply_cmd!" in Set(String[String(m.name) for m in bang])
    @test "close_node!" in Set(String[String(m.name) for m in bang])
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/world_interface_closure.jl")'`
Expected: (5) 의 `haskey(j, :access)` FAIL, (6) 의 `haskey(m, :callable)` FAIL. ⏱ 약 15초.

- [ ] **Step 3: 생성기에 도달 경로 색인을 더한다**

`tools/gen_world_interface.jl` 에 추가한다:

```julia
"""
    access_index(closure) -> Dict{String,Vector{String}}

폐포의 각 타입에 대해 `env` 로부터 그 값을 얻는 **경로 문자열**들. 필드 그래프의 순수
순회이므로 결정적이다. 컨테이너는 원소를 꺼내는 모양으로 적는다 —
`Vector{T}` 는 `…[i]`, `Dict{K,V}` 는 `keys(…)`/`values(…)`.

🔴 이 색인이 §1.2 의 실패를 정면으로 겨냥한다: 모델이 지어낸 것은 전부 "그 값을 어디서
   얻는지 안 적힌" 타입이었다.
"""
function access_index(closure)
    want = Set(String[_tname(S) for S in closure])
    out  = Dict{String,Vector{String}}()
    add!(n, p) = (n in want && push!(get!(out, n, String[]), p))
    # 너비 우선. 경로가 길어지면 모델에게 쓸모가 없으므로 3 홉에서 끊는다.
    frontier = Tuple{DataType,String,Int}[(CB.PlannerEnv, "env", 0)]
    seen = Set{String}(["PlannerEnv"])
    while !isempty(frontier)
        (S, path, hop) = popfirst!(frontier)
        hop >= 3 && continue
        isabstracttype(S) && continue
        for (f, ft) in zip(fieldnames(S), fieldtypes(S))
            fp = string(path, ".", f)
            U  = _unwrap(ft)
            U isa DataType || continue
            if U <: AbstractVector && length(U.parameters) >= 1
                E = _unwrap(U.parameters[1])
                E isa DataType || continue
                add!(_tname(E), string(fp, "[i]"))
                (_tname(E) in seen) || (push!(seen, _tname(E));
                    push!(frontier, (E, string(fp, "[i]"), hop + 1)))
            elseif U <: AbstractDict && length(U.parameters) >= 2
                K, V = _unwrap(U.parameters[1]), _unwrap(U.parameters[2])
                K isa DataType && add!(_tname(K), string("keys(", fp, ")"))
                if V isa DataType
                    add!(_tname(V), string("values(", fp, ")"))
                    (_tname(V) in seen) || (push!(seen, _tname(V));
                        push!(frontier, (V, string("values(", fp, ")"), hop + 1)))
                end
            elseif U <: AbstractSet && length(U.parameters) >= 1
                E = _unwrap(U.parameters[1])
                E isa DataType && add!(_tname(E), string("for x in ", fp))
            else
                add!(_tname(U), fp)
                (_tname(U) in seen) || (push!(seen, _tname(U));
                    push!(frontier, (U, fp, hop + 1)))
            end
        end
    end
    # 🔴 결정성: 경로 목록도 정렬한다.
    for (k, v) in out; out[k] = sort(unique(v)); end
    return out
end

const _SCALARISH = (Real, AbstractString, Symbol, Bool, Char)

"이 인자 타입을 모델이 손에 넣을 수 있는가."
function _arg_obtainable(T, reach)
    T isa Union && return _arg_obtainable(T.a, reach) && _arg_obtainable(T.b, reach)
    S = _unwrap(T)
    S === Any && return true
    S === CB.PlannerEnv && return true
    S isa DataType || return false
    S === Nothing && return true
    any(P -> S <: P, _SCALARISH) && return true
    return _tname(S) in reach
end
```

`method_entries()` 를 인자 하나 받게 고치고 두 열을 더한다:

```julia
function method_entries(reach, acc)
    out = Dict{String,Any}[]
    for n in sort(names(CB))
        isdefined(CB, n) || continue
        f = getfield(CB, n)
        f isa Function || continue
        for m in methods(f)
            Ts = collect(Base.unwrap_unionall(m.sig).parameters)[2:end]
            callable = all(T -> _arg_obtainable(T, reach), Ts)
            paths = String[]
            if callable
                nms = Base.method_argnames(m)
                for (i, T) in enumerate(Ts)
                    S = _unwrap(T)
                    (S === CB.PlannerEnv || S === Any) && continue
                    ps = get(acc, _tname(S), String[])
                    isempty(ps) && continue
                    nm = length(nms) >= i + 1 ? String(nms[i + 1]) : "_"
                    startswith(nm, "#") && (nm = "_")
                    push!(paths, string(nm, " <- ", first(ps)))
                end
            end
            push!(out, Dict("name" => string(n), "signature" => _sig_string(m),
                            "callable" => callable, "argpaths" => paths))
        end
    end
    sort!(out, by = e -> (e["name"], e["signature"]), alg = MergeSort)
    return out
end
```

마지막 쓰기 블록을 고친다:

```julia
closure = world_type_closure()
types   = Dict{String,Any}[type_entry(T) for T in closure]
acc     = access_index(closure)
reach   = Set(String[_tname(S) for S in closure])
open(dst, "w") do io
    JSON3.pretty(io, Dict("types" => types,
                          "access" => acc,
                          "methods" => method_entries(reach, acc),
                          "ambient" => [Dict("name" => a.name, "accessor" => a.accessor,
                                             "returns" => a.returns)
                                        for a in AMBIENT_ROOTS]))
end
```

- [ ] **Step 4: 산출물 재생성 + Julia 초록**

```bash
julia +lts --project=. tools/gen_world_interface.jl
julia +lts --project=. -e 'include("test/world_interface_closure.jl")'
julia +lts --project=. -e 'include("test/world_interface_current.jl")'
```
Expected: 두 파일 전부 PASS. ⏱ 약 11 + 15 + 21초.

🔴 (6) 의 `length(bang) == 16` 이 다른 수로 나오면 **그 수를 시험에 적고 이 계획의
§시간 표와 설계 §4.1 을 같이 고친다** — 실측을 따라가지, 계획서를 따라가지 않는다.

- [ ] **Step 5: 파이썬 렌더 시험을 쓴다 (빨강)**

```python
# src/respec/llm_service/test_world_interface_render.py
"""렌더가 두 표제로 갈리고 인자 경로를 붙인다는 계약. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _block():
    import world_interface as WI
    return WI.build_world_interface_block()


def test_the_two_headings_exist():
    b = _block()
    assert "FUNCTIONS YOU CAN CALL NOW" in b
    assert "FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET" in b


def test_a_callable_method_carries_its_argument_paths():
    b = _block()
    head, _, tail = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    # `close_node!(node::ScheduleNode, env::PlannerEnv)` 는 호출 가능해야 하고,
    # `node` 를 어디서 얻는지가 그 줄 아래 붙어야 한다.
    assert "close_node!" in head
    assert "node <- env.sched.nodes[i]" in head


def test_the_withheld_capabilities_are_in_neither_heading():
    """🔴 D6. 가르는 것은 렌더이지 모집단이 아니다."""
    b = _block()
    for hidden in ("release_pending_assignments!", "recover_stalled_teams!",
                   "resolve_schedule_wedge!", "force_advance_stuck_carrier!",
                   "forbid_heavy_cargo!"):
        assert hidden not in b, "%s 가 샜다" % hidden


def test_the_rules_text_is_byte_identical():
    """🔴 D19. `_RULES` 를 바꾸면 D6 측정이 오염된다."""
    import world_interface as WI
    assert WI._RULES.startswith("HOW YOUR CODE IS CALLED")
    assert "Helper closures defined INSIDE your function body are fine." in WI._RULES
    assert _block().startswith(WI._RULES)
```

Run: `python3 -m pytest -q src/respec/llm_service/test_world_interface_render.py`
Expected: 앞의 두 시험 FAIL. ⏱ 약 5초.

- [ ] **Step 6: 파이썬 렌더를 고친다**

`build_world_interface_block` 의 `FUNCTIONS THE MODULE ALREADY HAS` 블록을 교체한다:

```python
    now = [m for m in b["methods"] if m.get("callable")]
    later = [m for m in b["methods"] if not m.get("callable")]
    parts += ["", "FUNCTIONS YOU CAN CALL NOW (every argument is obtainable from env):"]
    for m in now:
        parts.append("- %s %s" % (m["name"], m["signature"]))
        for p in m.get("argpaths") or []:
            parts.append("      %s" % p)
    parts += ["", "FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET:"]
    for m in later:
        parts.append("- %s %s" % (m["name"], m["signature"]))
```

- [ ] **Step 7: 초록을 확인한다**

Run: `python3 -m pytest -q src/respec/llm_service/`
Expected: 전부 PASS (신설 4건 포함). ⏱ 약 16초.

- [ ] **Step 8: 커밋**

```bash
git add tools/gen_world_interface.jl src/respec/llm_service/world_interface.py \
        src/respec/llm_service/test_world_interface_render.py \
        test/world_interface_closure.jl \
        wm4spacecraft_manufacturing/core/world_interface.json
git commit -m "D11: 도달 경로 색인 + 호출 가능성 분할 — 인자마다 env 로부터의 경로를 붙인다"
```

---

### Task 5: `needs` 채널 (D13)

run 2·3 의 최상위 placeholder 는 **모델이 없는 능력을 신고할 자리가 없어서** 코드가 된
문장이다(설계 §1.2). 그 자리를 만든다.

**Files:**
- Modify: `src/respec/llm_service/synthesize.py` (`WriteToolImpl` · `_BODY_FIELDS`)
- Create: `src/respec/llm_service/test_needs_channel.py`

**Interfaces:**
- Produces: 기록에 `needs::Optional[str]` 열이 생긴다. `_BODY_FIELDS` 에 `"needs"` 가 들어간다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
# src/respec/llm_service/test_needs_channel.py
"""agent-3 이 "없다" 를 말할 채널. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def test_writetoolimpl_declares_needs():
    import synthesize as SY
    assert "needs" in SY.WriteToolImpl.output_fields


def test_needs_comes_before_impl_code():
    """🔴 잘림이 스칼라를 먹지 않게 — run 1 이 `params` 한가운데서 잘려 죽었다."""
    import synthesize as SY
    order = list(SY.WriteToolImpl.output_fields)
    assert order.index("needs") < order.index("impl_code")


def test_needs_is_a_recorded_body_field():
    import synthesize as SY
    assert "needs" in SY._BODY_FIELDS
    assert "needs" not in SY._NON_STR_BODY_FIELDS   # 문자열이다


def test_blank_record_carries_needs_as_none():
    """삼상: 못 쟀으면 None 이지 "" 가 아니다."""
    import synthesize as SY
    rec = SY.blank_synthesis_record(kind="battery")
    assert rec.get("needs", "MISSING") is None
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `python3 -m pytest -q src/respec/llm_service/test_needs_channel.py`
Expected: 4건 FAIL. ⏱ 약 5초.

- [ ] **Step 3: 시그니처에 필드를 더한다**

`synthesize.py` 의 `WriteToolImpl` 에서 `reversible` **뒤**, `impl_code` **앞**에:

```python
    needs: str = dspy.OutputField(desc=
        "a capability your body required that you could not find in the world interface; "
        "empty string if none")
```

🔴 자리가 계약이다 — 위 주석 블록이 적는 그대로, 값싼 스칼라는 `impl_code` 앞에 둔다.

`_BODY_FIELDS` 에 `"needs"` 를 더한다:

```python
_BODY_FIELDS = ("impl_name", "impl_code", "surface", "reversible", "wrote", "calls",
               "reach", "missing_primitive", "needs")
```

`blank_synthesis_record` / `_blank` 가 `_BODY_FIELDS` 를 순회해 `None` 으로 채우는지
확인한다. 안 하면 그 자리에 `rec["needs"] = None` 을 명시한다.

- [ ] **Step 4: 초록을 확인한다**

Run: `python3 -m pytest -q src/respec/llm_service/`
Expected: 전부 PASS. ⏱ 약 16초.

🔴 기존 시험 중 `WriteToolImpl` 의 출력 필드 **수**를 세는 것이 있으면 그것도 갱신한다:
```bash
/usr/bin/grep -rn "output_fields" src/respec/llm_service/*.py | head
```

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/synthesize.py src/respec/llm_service/test_needs_channel.py
git commit -m "D13: agent-3 에게 '없다'를 말할 채널을 준다 — needs 출력 필드"
```

---

### Task 6: 지어낸 이름·필드를 `Core.eval` 전에 거절한다 (D15)

실측(프로브 P2·P3): 미정의 함수를 부르는 body 도, 없는 필드를 읽는 body 도
`Core.eval` 을 **통과한다**. `UndefVarError` 는 **집행 중에** 난다 — 그때는 세계가
이미 반쯤 편집됐을 수 있고 되먹임 문장도 raw 예외다.

**Files:**
- Modify: `src/respec/minted_registration.jl`
- Modify: `test/minted_registration.jl`

**Interfaces:**
- Produces: `check_impl_conventions` 이 두 사유를 더 낸다 —
  `reject:impl_unknown_call:<이름>` · `reject:impl_unknown_field:<타입>.<필드> — fields are (…)`.
  Task 9 의 `/rewrite` 가 이 문자열을 그대로 되먹인다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/minted_registration.jl` 의 마지막 `end` 앞에:

```julia
@testset "(21) 🔴 D15: 미정의 호출 대상은 eval 전에 거절된다" begin
    # run 2·3 이 실제로 쓴 모양이다.
    code = """
    function d15_probe_a!(env; x::Int=1)
        r = find_suitable_robot(x)
        return (status = :ok,)
    end
    """
    why = CB.check_impl_conventions("d15_probe_a!", code)
    @test why !== nothing
    @test startswith(why, "reject:impl_unknown_call:")
    @test occursin("find_suitable_robot", why)
    # 🔴 등록 자체가 막혀야 한다 — eval 이 돌면 이 태스크는 실패다.
    @test !isdefined(CB, :d15_probe_a!)
end

@testset "(22) 🔴 D15: 없는 필드 접근도 eval 전에 거절된다" begin
    code = """
    function d15_probe_b!(env; x::Int=1)
        return (status = Symbol(env.sched.nodes[1].assigned_robot),)
    end
    """
    why = CB.check_impl_conventions("d15_probe_b!", code)
    @test why !== nothing
    @test startswith(why, "reject:impl_unknown_field:")
    @test occursin("assigned_robot", why)
    # 되먹임이 쓸모 있으려면 **실제 필드가 문장 안에** 있어야 한다
    @test occursin("id", why) && occursin("node", why) && occursin("spec", why)
end

@testset "(23) 🔴 D15 음성 대조 — 옳은 body 는 통과한다" begin
    # 기존 함수를 부르고 존재하는 필드만 읽는다. 지역 클로저도 쓴다(규약 4 는 허용).
    code = """
    function d15_probe_ok!(env; t::Float64=0.0)
        pick(v) = v
        update_planning_cache!(env, t)
        n = length(env.cache.closed_set)
        return (status = Symbol("closed_", pick(n)),)
    end
    """
    @test CB.check_impl_conventions("d15_probe_ok!", code) === nothing
end

@testset "(24) 🔴 D15 는 모르면 통과시킨다 (거짓 거절 금지)" begin
    # 수신자 타입을 정적으로 못 아는 필드 접근은 **막지 않는다**.
    code = """
    function d15_probe_dyn!(env; x::Int=1)
        y = env.agent_policies
        z = first(values(y)).nominal_policy
        return (status = :ok,)
    end
    """
    @test CB.check_impl_conventions("d15_probe_dyn!", code) === nothing
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: (21)(22) FAIL(`why === nothing`), (23)(24) PASS(빈-통과 — 검사가 아직 없다). ⏱ 약 14초.

- [ ] **Step 3: 정적 검사를 더한다**

`src/respec/minted_registration.jl` 의 `check_impl_conventions` 안, 마지막
`return nothing` **바로 앞**에 넣고, 아래 두 도우미를 그 함수 **위**에 정의한다:

```julia
"""
    _walk_body!(calls, fields, locals, ex)

body 의 AST 를 걸어 (1) 호출 대상 이름 (2) `수신자.필드` 쌍 (3) 지역 정의 이름을 모은다.
🔴 **보수적이다.** 모르면 안 모은다 — 거짓 거절은 모델의 옳은 코드를 우리 파서의 한계로
   막고, 그것은 이 레인이 재려는 것 자체를 파괴한다.
"""
function _walk_body!(calls, fields, locals, ex)
    ex isa Expr || return
    if ex.head === :call && !isempty(ex.args) && ex.args[1] isa Symbol
        push!(calls, ex.args[1])
    elseif ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call &&
           ex.args[1].args[1] isa Symbol
        push!(locals, ex.args[1].args[1])            # `helper(x) = …` 지역 정의
    elseif ex.head === :function && ex.args[1] isa Expr && ex.args[1].head === :call &&
           ex.args[1].args[1] isa Symbol
        push!(locals, ex.args[1].args[1])            # 중첩 `function helper(x) … end`
    elseif ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        push!(fields, (ex.args[1], ex.args[2].value))
    end
    for a in ex.args; _walk_body!(calls, fields, locals, a); end
end

"`env.<f>` 꼴 하나만 정적으로 타입을 안다. 그 이상은 모른다고 답한다."
function _static_receiver_type(recv)
    recv === :env && return PlannerEnv
    if recv isa Expr && recv.head === :. && recv.args[1] === :env &&
       recv.args[2] isa QuoteNode
        f = recv.args[2].value
        f in fieldnames(PlannerEnv) || return nothing
        T = fieldtype(PlannerEnv, f)
        S = T isa UnionAll ? Base.unwrap_unionall(T) : T
        return S isa DataType && isstructtype(S) && !isabstracttype(S) ? S : nothing
    end
    return nothing
end
```

그리고 `return nothing` 앞:

🔴 **자리가 계약이다 — 이 검사는 규약 다섯 **전부의 뒤**에 온다.** 특히
`impl_not_single_expression` 보다 뒤여야 한다. run 2 의 실제 코드(`LIVE_BARE`)는 최상위
정의가 둘이면서 **동시에** 미정의 `find_suitable_robot` 을 부르는데,
`test/minted_registration.jl` 의 테스트셋 (20) 이 그 입력에 대해 사유가 정확히
`"reject:impl_not_single_expression:2"` 임을 **바이트로** 못박는다(그 시험의 주석: "이 단언이
빨개지면 규약을 고칠 것이 아니라 그것이 발견이다"). 순서를 앞으로 옮기면 그 게이트가
D14 를 지키지 못한 채 빨개진다.

```julia
    # 🔴 D15. 지어낸 이름·필드는 **eval 전에** 거절한다. 실측(프로브 P2·P3): 오늘은
    #    둘 다 `Core.eval` 을 통과해 **집행 중에** UndefVarError 로 터진다 — 그때는 세계가
    #    이미 반쯤 편집됐을 수 있고, agent-3 에게 돌아갈 문장도 raw 예외다.
    local body = length(f.args) >= 2 ? f.args[2] : nothing
    if body !== nothing
        local cs, fs, ls = Symbol[], Tuple{Any,Symbol}[], Symbol[]
        _walk_body!(cs, fs, ls, body)
        # 시그니처의 키워드 이름도 지역이다
        for k in kws; (k isa Expr && k.args[1] isa Symbol) && push!(ls, k.args[1]); end
        for k in kws
            k isa Expr && k.args[1] isa Expr && k.args[1].head === :(::) &&
                k.args[1].args[1] isa Symbol && push!(ls, k.args[1].args[1])
        end
        push!(ls, :env, Symbol(name))
        for c in unique(cs)
            (c in ls) && continue
            isdefined(@__MODULE__, c) && continue
            isdefined(Base, c) && continue
            isdefined(Core, c) && continue
            return "reject:impl_unknown_call:$(c) — 이 이름의 함수는 이 모듈에도 Base 에도 " *
                   "없다. 세계 인터페이스가 실제로 가진 함수만 부르거나, 도우미를 body " *
                   "**안쪽**에 정의하라"
        end
        for (recv, fld) in fs
            S = _static_receiver_type(recv)
            S === nothing && continue                # 🔴 모르면 통과 (시험 (24))
            fld in fieldnames(S) && continue
            return "reject:impl_unknown_field:$(nameof(S)).$(fld) — fields are " *
                   "($(join(String.(collect(fieldnames(S))), ", ")))"
        end
    end
    return nothing
```

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: (1)–(24) 전부 PASS. ⏱ 약 14초.

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: 전부 PASS. ⏱ 약 24초.

🔴 여기서 빨개지면 **먼저 그 이름이 진짜로 존재하는지 확인한다**:

```bash
julia +lts --project=. -e 'using ConstructionBots; const CB=ConstructionBots;
  s = Symbol("<거절된 이름>");
  println("CB=", isdefined(CB,s), " Base=", isdefined(Base,s), " Core=", isdefined(Core,s))'
```

- **존재한다** → 검사가 틀렸다. 시험을 고치지 말고 **검사를 넓혀라**(예: 지역 정의 수집이
  그 모양을 놓쳤다).
- **존재하지 않는다** → 그 시험의 toy body 는 애초에 호출하면 `UndefVarError` 로 죽는
  코드였고, 옛 느슨함에 기대고 있었다. 시험을 고치되 **왜 고쳤는지 그 자리에 적는다**.
  어느 쪽인지 기록 없이 넘어가지 말 것.

- [ ] **Step 5: 커밋**

```bash
git add src/respec/minted_registration.jl test/minted_registration.jl
git commit -m "D15: 지어낸 이름·필드를 Core.eval 전에 거절한다 — 집행 중 UndefVarError 를 되먹임 가능한 사유로 바꾼다"
```

---

### Task 7: 인자 채널의 타입 변환 (D16)

실측(프로브 P1): `bind_primitive_args` 가 **JSON3 의 지연 뷰를 그대로 넘긴다**. 그리고
🔴 **Julia 의 키워드 인자는 `convert` 가 아니라 타입 단언이다** — 위치인자와 달리 자동
변환이 없다. 그래서 등록이 처음 성공하는 순간 호출이 `TypeError` 로 죽는다:

```
CALL 🔴 THREW => TypeError: in keyword argument task_ids,
                 expected Vector{String}, got a value of type JSON3.Array{String, …}
```

**Files:**
- Modify: `src/respec/minted_registration.jl` (`impl_param_types` 신설 · 등록 행에 열 추가)
- Modify: `src/respec/minted_tool.jl` (`bind_primitive_args`)
- Modify: `test/minted_end_to_end.jl`

**Interfaces:**
- Consumes: Task 6 이 이미 걷는 `sig`/`kws`.
- Produces: 등록 행에 `"param_types" => Dict{String,Any}`(키워드 이름 → `Type`).
  주석 없는 키워드는 **키가 없다**. `bind_primitive_args` 가 새 사유
  `reject:param_convert:<키>:expected <T>, got <타입>` 을 낸다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/minted_end_to_end.jl` 의 마지막 `end` 앞에:

```julia
@testset "(7) 🔴 D16: JSON3 배열·객체가 선언 타입으로 변환돼 호출이 산다" begin
    CB.reset_minted_table!()
    code = """
    function d16_array_tool!(env; task_ids::Array{String,1}=String[], k::Int=0)
        return (status = Symbol("saw_", length(task_ids), "_", k),)
    end
    """
    params = Dict{String,Any}("task_ids" => Dict("type" => "array",
                                                 "items" => Dict("type" => "string")),
                              "k" => Dict("type" => "integer"))
    @test CB.register_minted_primitive!(name = "d16_array_tool!", code = code,
                                        params = params, surface = "sched",
                                        reversible = false) === nothing
    prim = CB.resolve_primitive("d16_array_tool!")
    @test prim !== nothing
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_array_tool!","args":{"task_ids":["t1","t2","t3"],"k":7}}]"""))
    @test !(calls isa String)
    b = CB.bind_primitive_args(prim, (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test !(b isa String)
    # 🔴 뷰가 아니라 네이티브 컨테이너여야 한다
    @test b[2].task_ids isa Vector{String}
    r = Base.invokelatest(getfield(CB, Symbol("d16_array_tool!")), b[1]...; b[2]...)
    @test r.status === :saw_3_7
end

@testset "(8) 🔴 D16: 변환 실패는 예외가 아니라 거절이다" begin
    CB.reset_minted_table!()
    code = """
    function d16_bad_tool!(env; n::Int=0)
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_bad_tool!", code = code,
        params = Dict{String,Any}("n" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    calls = CB.normalize_calls(JSON3.read(
        """[{"primitive":"d16_bad_tool!","args":{"n":"not a number"}}]"""))
    b = CB.bind_primitive_args(CB.resolve_primitive("d16_bad_tool!"),
                               (env = :DUMMY, truth = nothing, params = calls[1][2]))
    @test b isa String
    @test startswith(b, "reject:param_convert:n:")
end

@testset "(9) 🔴 D16: 주석 없는 키워드는 오늘 그대로 흐른다" begin
    CB.reset_minted_table!()
    code = """
    function d16_plain_tool!(env; anything="x")
        return (status = :ok,)
    end
    """
    @test CB.register_minted_primitive!(name = "d16_plain_tool!", code = code,
        params = Dict{String,Any}("anything" => Dict("type" => "string")),
        surface = "sched", reversible = false) === nothing
    prim = CB.resolve_primitive("d16_plain_tool!")
    @test !haskey(prim.param_types, "anything")   # 키가 **없다** (nothing 을 넣지 않는다)
end
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: (7) 의 `b[2].task_ids isa Vector{String}` FAIL 또는 `invokelatest` 가
`TypeError` 를 던진다. (8) FAIL. (9) 는 `prim.param_types` 가 없어 에러. ⏱ 약 24초.

- [ ] **Step 3: `impl_param_types` 를 만든다**

🔴 `check_impl_conventions` 는 `Union{Nothing,String}` 을 반환한다 — 타입을 실어 보낼
자리가 없다. 반환 타입을 바꾸면 호출자 전부와 시험 열몇이 따라 바뀐다. **별도 순수 함수**로 짓는다.
`src/respec/minted_registration.jl` 에 추가:

```julia
"""
    impl_param_types(code) -> Dict{String,Any}

시그니처의 키워드에서 **타입 주석**만 뽑는다. 주석이 없거나 우리가 못 읽는 모양이면
그 키는 **없다**(`nothing` 을 값으로 넣지 않는다 — 삼상 규약).

🔴 `T` 는 모델이 쓴 **AST 조각**이지 `Type` 이 아니다. `Core.eval` 로 바꿔야 하는데 그
   eval 은 임의 코드를 돌릴 수 있다. 그래서 **타입 표현식의 모양**(`Symbol` ·
   `Expr(:curly, …)`)만 통과시키고, 아니면 그 키를 버린다 — 거절이 아니다.
   여기서 거절하면 모델의 정상 코드를 우리 파서의 한계로 막는다.
🔴 순수 함수다. eval 은 **타입 표현식 하나**에만 돌고 세계를 안 건드린다.
"""
function impl_param_types(code::AbstractString)
    out = Dict{String,Any}()
    local top
    try; top = Meta.parseall(code); catch; return out; end
    exprs = [x for x in top.args if !(x isa LineNumberNode)]
    length(exprs) == 1 || return out
    f = exprs[1]
    (f isa Expr && f.head === :function) || return out
    sig = f.args[1]
    (sig isa Expr && sig.head === :call) || return out
    kb = findfirst(x -> x isa Expr && x.head === :parameters, sig.args[2:end])
    kb === nothing && return out
    for k in sig.args[2:end][kb].args
        (k isa Expr && k.head === :kw) || continue
        lhs = k.args[1]
        (lhs isa Expr && lhs.head === :(::) && length(lhs.args) == 2 &&
         lhs.args[1] isa Symbol) || continue
        texpr = lhs.args[2]
        _is_type_shape(texpr) || continue
        local T
        try; T = Core.eval(@__MODULE__, texpr); catch; continue; end
        T isa Type || continue
        out[String(lhs.args[1])] = T
    end
    return out
end

"타입 표현식의 **모양**인가. 호출·보간·매크로는 전부 거짓이다."
_is_type_shape(e) =
    e isa Symbol ||
    (e isa Expr && e.head === :curly && all(_is_type_shape, e.args)) ||
    (e isa Expr && e.head === :. && length(e.args) == 2 && e.args[2] isa QuoteNode)
```

`register_minted_primitive!` 안, 🔴 **규약 검사 통과 뒤 · `Core.eval` 전에**
(F7 의 "검증은 eval 앞" 불변식 안쪽이다):

```julia
    local _ptypes = impl_param_types(code)
```

그리고 등록 행 dict 에 열을 더한다:

```julia
        "param_types"  => _ptypes,
```

- [ ] **Step 4: 바인더가 변환하게 한다**

`src/respec/minted_tool.jl` 의 `bind_primitive_args` 안, `kw[Symbol(k)] = v` **를 교체**한다:

```julia
        # 🔴 D16 (프로브 P1). Julia 의 **키워드 인자는 `convert` 가 아니라 타입 단언**이다 —
        #    위치인자와 달리 자동 변환이 없다. 그리고 `/decide` 를 거쳐 온 값은 네이티브
        #    컨테이너가 아니라 `JSON3.Array`/`JSON3.Object` 의 **지연 뷰**다. 둘이 겹쳐,
        #    등록이 처음 성공하는 순간 호출이 `TypeError` 로 죽는다(실측). 변환은 우리 몫이다.
        #    🔴 예외가 아니라 거절이다: 여기서 던지면 `enact_minted!` 의 catch 가 손도 안 댄
        #    세계를 `partial=true → handled=true` 로 적어 폴백을 삼킨다.
        local T = get(prim.param_types, String(k), nothing)
        if T === nothing
            kw[Symbol(k)] = v                 # 주석 없는 키워드는 오늘 그대로 흐른다
        else
            local cv
            try
                cv = convert(T, v)
            catch
                return "reject:param_convert:$(k):expected $(T), got $(typeof(v)) (원시 $(prim.name))"
            end
            kw[Symbol(k)] = cv
        end
```

🔴 `resolve_primitive` 가 만드는 원시 객체에 `param_types` 필드가 실리는지 확인한다.
안 실리면 그 자리에 더한다 — **기본값은 빈 `Dict{String,Any}()`** 이지 `nothing` 이 아니다
(손으로 씨 뿌린 알려진 원시 여덟은 이 열이 없다).

```bash
/usr/bin/grep -n "harness_args\s*=\|function resolve_primitive" src/respec/minted_tool.jl
```

- [ ] **Step 5: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: (1)–(9) 전부 PASS. ⏱ 약 24초.

Run: `julia +lts --project=. -e 'include("test/minted_registration.jl")'`
Expected: 전부 PASS. ⏱ 약 14초.

- [ ] **Step 6: 커밋**

```bash
git add src/respec/minted_registration.jl src/respec/minted_tool.jl test/minted_end_to_end.jl
git commit -m "D16: 경계가 JSON3 뷰를 선언 타입으로 변환한다 — kwarg 는 convert 가 아니라 단언이다"
```

---

### Task 8: 세계 다이제스트 (D18)

사전등록 결정 1(R11)이 적은 그대로 오늘의 계측으로는 세계가 바뀌었는지 못 잰다 —
`handled` 는 구성상 ~100%, `applied` 는 항상 `nothing`, `world_maybe_dirty` 는 무조건
`true`, `steps.status` 는 자기신고다.

**Files:**
- Modify: `tools/monitor/enact.jl`
- Modify: `test/minted_end_to_end.jl`

**Interfaces:**
- Produces: `enact_minted_decision!` 의 반환 NamedTuple 에 `world_delta` 가 붙는다 —
  `NamedTuple` `(closed, active, n_edges, n_binding_changed)` 이거나, 스냅샷을 못 찍었으면
  **`nothing`**(삼상: `nothing` = 못 쟀다).

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/minted_end_to_end.jl` 의 마지막 `end` 앞에:

```julia
@testset "(10) 🔴 D18: 집행 전후 세계 다이제스트가 기록된다" begin
    # 세계를 확실히 바꾸는 생성 원시 하나 — closed_set 에 정점을 하나 넣는다.
    code = """
    function d18_touch_tool!(env; v::Int=1)
        push!(env.cache.closed_set, v)
        return (status = :touched,)
    end
    """
    env = _fresh_env()                       # 이 파일이 이미 쓰는 헬퍼
    before = length(env.cache.closed_set)
    sl = Dict{String,Any}(
        "tool_name" => "d18_touch_tool!", "impl_name" => "d18_touch_tool!",
        "impl_code" => code, "surface" => "sched", "reversible" => false,
        "wrote" => true,
        "params" => Dict{String,Any}("v" => Dict("type" => "integer")),
        "calls"  => [Dict("primitive" => "d18_touch_tool!",
                          "args" => Dict("v" => 999_001))])
    r = enact_minted_decision!(env, nothing, sl)
    @test r.world_delta !== nothing
    @test r.world_delta.closed == length(env.cache.closed_set) - before
    @test r.world_delta.closed == 1
end

@testset "(11) 🔴 D18: 무동작 원시의 차분은 0 이다 — nothing 이 아니다" begin
    code = """
    function d18_noop_tool!(env; v::Int=1)
        return (status = :did_nothing,)
    end
    """
    env = _fresh_env()
    sl = Dict{String,Any}(
        "tool_name" => "d18_noop_tool!", "impl_name" => "d18_noop_tool!",
        "impl_code" => code, "surface" => "sched", "reversible" => false, "wrote" => true,
        "params" => Dict{String,Any}("v" => Dict("type" => "integer")),
        "calls"  => [Dict("primitive" => "d18_noop_tool!", "args" => Dict("v" => 1))])
    r = enact_minted_decision!(env, nothing, sl)
    @test r.world_delta !== nothing            # 🔴 "쟀는데 0" 이지 "못 쟀다" 가 아니다
    @test r.world_delta.closed == 0
    @test r.world_delta.n_binding_changed == 0
end
```

🔴 `_fresh_env()` 가 이 파일에 없으면 이 파일이 이미 쓰는 env 생성 방식을 그대로 쓴다:
```bash
/usr/bin/grep -n "PlannerEnv(\|_fresh_env\|function _env" test/minted_end_to_end.jl | head
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: (10)(11) 이 `type NamedTuple has no field world_delta` 로 FAIL. ⏱ 약 24초.

- [ ] **Step 3: 스냅샷을 찍는다**

`tools/monitor/enact.jl` 에 함수를 더한다 (`enact_minted_decision!` **위**):

```julia
"""
    _world_digest(env) -> Union{Nothing,NamedTuple}

값싼 세계 지문. 집행 **전후**로 찍어 차분을 낸다. 못 찍으면 `nothing`("못 쟀다").

🔴 왜 필요한가(사전등록 결정 1 = R11). 오늘의 관측 넷 중 어느 것도 "세계가 바뀌었다" 를
   못 잰다: `handled` 는 생성 body 면 구성상 ~100%, `applied` 는 항상 `nothing`,
   `world_maybe_dirty` 는 무조건 `true`, `steps.status` 는 모델의 자기신고다.
⚠️ `assignment_binding` 은 스스로 **하한**이라고 적는다(팀이 맡은 정점은 정렬 첫째만
   담는다) — 0 이 아니면 확실히 바뀐 것이고, 0 이라고 안 바뀐 것은 아니다.
"""
function _world_digest(env)
    try
        return (closed   = length(env.cache.closed_set),
                active   = length(env.active_build_steps),
                n_edges  = Graphs.ne(env.sched.graph),
                binding  = CB.assignment_binding(env.sched))
    catch
        return nothing
    end
end

"두 지문의 차분. 한쪽이라도 `nothing` 이면 `nothing`."
function _world_delta(a, b)
    (a === nothing || b === nothing) && return nothing
    changed = 0
    for (v, r) in b.binding
        get(a.binding, v, nothing) === r || (changed += 1)
    end
    for v in keys(a.binding); haskey(b.binding, v) || (changed += 1); end
    return (closed = b.closed - a.closed,
            active = b.active - a.active,
            n_edges = b.n_edges - a.n_edges,
            n_binding_changed = changed)
end
```

`enact_minted_decision!` 안에서 `local r = CB.enact_minted!(env, truth, sl)` 를 감싼다:

```julia
        local _pre = _world_digest(env)
        local r = CB.enact_minted!(env, truth, sl)
        local world_delta = _world_delta(_pre, _world_digest(env))
```

로그 줄에 더한다 (`ran_milp` 를 찍는 `println` 뒤):

```julia
        println("[minted] world_delta=", world_delta === nothing ? "n/a(not measured)" :
                string("closed=", world_delta.closed, " active=", world_delta.active,
                       " n_edges=", world_delta.n_edges,
                       " n_binding_changed=", world_delta.n_binding_changed))
```

🔴 반환 NamedTuple **네 자리 전부**에 `world_delta` 를 더한다 — 이 함수의 필드 집합은
반환 자리마다 같아야 한다(파일의 기존 규약, `:845` 주석). 도달 못 한 자리는 `nothing` 이다.

- [ ] **Step 4: 초록을 확인한다**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: (1)–(11) 전부 PASS. ⏱ 약 24초.

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/enact.jl test/minted_end_to_end.jl
git commit -m "D18: 집행 전후 세계 다이제스트 — R11 이 '못 잰다'고 적은 축을 잰다"
```

---

### Task 9: 거절 사유 되먹임 (`/rewrite`) (D17)

`impl_rejected_why` 는 오늘 `tools/monitor/enact.jl` 안에만 있고 **파이썬으로 돌아가는
길이 없다**. 그러므로 이것은 엔드포인트 하나가 아니라 **채널 하나**다.

**Files:**
- Modify: `src/respec/llm_service/synthesize.py` (`RewriteToolImpl` · `rewrite_impl`)
- Modify: `src/respec/llm_service/dspy_service.py` (`/rewrite`)
- Modify: `tools/monitor/enact.jl` (왕복 + 재등록 1회)
- Create: `src/respec/llm_service/test_rewrite_channel.py`

**Interfaces:**
- Produces: `POST /rewrite {impl_name, impl_code, impl_rejected_why, spec, tool_name}` →
  `{"wrote": bool, "impl_name": str, "impl_code": str, "params": str,
    "calls": list, "surface": str, "reversible": bool, "error": str|null}`.
  Julia 는 `r.registered === false` 이고 `impl_rejected_why !== nothing` 일 때만 부른다.

- [ ] **Step 1: 실패하는 시험을 쓴다 (파이썬)**

```python
# src/respec/llm_service/test_rewrite_channel.py
"""거절 사유 되먹임 채널. 유료 0건 — dspy 프로그램은 가짜로 바꿔 끼운다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class _FakePred:
    wrote = True
    impl_name = "fixed_tool!"
    impl_code = "function fixed_tool!(env; k::Int=0)\n    return (status = :ok,)\nend"
    params = '{"k": {"type": "integer"}}'
    calls = [{"primitive": "fixed_tool!", "args": {"k": 1}}]
    surface = "sched"
    reversible = False


def _fake_program(**kw):
    return _FakePred()


def test_rewrite_signature_declares_the_rejection_reason():
    import synthesize as SY
    assert "impl_rejected_why" in SY.RewriteToolImpl.input_fields
    assert "impl_code" in SY.RewriteToolImpl.input_fields


def test_rewrite_impl_returns_a_body_and_records_the_reason():
    import synthesize as SY
    out = SY.rewrite_impl(
        tool_name="t!", spec="a spec",
        impl_name="broken_tool!", impl_code="function broken_tool!(env) end",
        impl_rejected_why="reject:impl_not_single_expression:2",
        program=_fake_program)
    assert out["wrote"] is True
    assert out["impl_name"] == "fixed_tool!"
    assert out["error"] is None
    assert out["rewrite_of_why"] == "reject:impl_not_single_expression:2"


def test_rewrite_impl_never_raises():
    """🔴 이 경로에서 새는 예외는 Julia 쪽에서 세계 상태를 잃게 만든다."""
    import synthesize as SY

    def _boom(**kw):
        raise RuntimeError("provider is down")

    out = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                          impl_rejected_why="reject:whatever", program=_boom)
    assert out["wrote"] is None            # 🔴 삼상: 못 쟀다
    assert "provider is down" in out["error"]
```

- [ ] **Step 2: 빨간 것을 확인한다**

Run: `python3 -m pytest -q src/respec/llm_service/test_rewrite_channel.py`
Expected: 3건 FAIL (`AttributeError: module 'synthesize' has no attribute 'RewriteToolImpl'`). ⏱ 약 5초.

- [ ] **Step 3: 파이썬 쪽을 쓴다**

`synthesize.py` 의 `WriteToolImpl` **뒤**에:

```python
class RewriteToolImpl(dspy.Signature):
    """Your previous Julia implementation was REJECTED before it ran. You are given the
    exact rejection reason. Fix that one problem and return the corrected implementation.
    Change nothing else. The same hard requirements still apply."""
    spec: str = dspy.InputField(desc="the tool specification you were given")
    world_interface: str = dspy.InputField(desc=
        "the world's types and fields, the functions the module already has, and the hard "
        "requirements your function must satisfy to be callable")
    impl_code: str = dspy.InputField(desc="the implementation that was rejected")
    impl_rejected_why: str = dspy.InputField(desc=
        "the exact reason it was rejected -- fix this and only this")

    wrote: bool = dspy.OutputField(desc="false if you cannot fix it")
    impl_name: str = dspy.OutputField(desc="the Julia function name; must end with `!`")
    surface: str = dspy.OutputField(desc="which world surface this edits")
    reversible: bool = dspy.OutputField(desc="can this be undone")
    impl_code: str = dspy.OutputField(desc=
        "exactly one `function <impl_name>(env; k=<default>, ...) ... end` and nothing else")
    params: str = dspy.OutputField(desc="JSON schema of the keyword arguments")
    calls: List[Dict[str, Any]] = dspy.OutputField(desc=
        'the arguments to use for THIS event: [{"primitive": "<impl_name>", '
        '"args": {<keyword>: <value>}}]')


def rewrite_impl(*, tool_name, spec, impl_name, impl_code, impl_rejected_why,
                 blob=None, program=None):
    """agent-3 을 **한 번** 더 돌려 거절을 고치게 한다.

    🔴 **절대 안 던진다.** 이 경로에서 새는 예외는 Julia 쪽 집행부가 기록 대신 예외로
       끝나게 하고, 호출자는 세계 상태를 알 방법을 잃는다.
    🔴 삼상: `wrote` 는 `None`("못 쟀다") · `False`("못 고치겠다") · `True`.
    """
    out = {"wrote": None, "impl_name": None, "impl_code": None, "params": None,
           "calls": None, "surface": None, "reversible": None, "error": None,
           "rewrite_of_why": impl_rejected_why}
    prog = program or dspy.ChainOfThought(RewriteToolImpl)
    try:
        p = prog(spec=spec, world_interface=compose_interface(blob),
                 impl_code=impl_code, impl_rejected_why=impl_rejected_why)
    except Exception as e:                      # noqa: BLE001 — 위 규약
        out["error"] = "rewrite: %s: %s" % (type(e).__name__, e)
        return out
    w = getattr(p, "wrote", None)
    out["wrote"] = w if isinstance(w, bool) else None
    out["impl_name"] = getattr(p, "impl_name", None) or None
    out["impl_code"] = strip_code_fence(getattr(p, "impl_code", None) or "") or None
    out["params"] = getattr(p, "params", None) or None
    out["calls"] = normalize_calls(getattr(p, "calls", None))
    out["surface"] = getattr(p, "surface", None) or None
    rv = getattr(p, "reversible", None)
    out["reversible"] = rv if isinstance(rv, bool) else None
    return out
```

`dspy_service.py` 에 엔드포인트를 더한다 (`/macro` 근처):

```python
class RewriteRequest(BaseModel):
    tool_name: str = ""
    spec: str = ""
    impl_name: str = ""
    impl_code: str = ""
    impl_rejected_why: str = ""


@app.post("/rewrite")
def rewrite(req: RewriteRequest):
    """D17. 등록/바인딩 거절 사유를 agent-3 에게 **한 번** 되먹인다.

    🔴 재시도 상한은 호출자(Julia)가 지킨다 — 이 엔드포인트는 상태가 없다.
    """
    import synthesize as SY
    return SY.rewrite_impl(tool_name=req.tool_name, spec=req.spec,
                           impl_name=req.impl_name, impl_code=req.impl_code,
                           impl_rejected_why=req.impl_rejected_why)
```

- [ ] **Step 4: 파이썬 초록**

Run: `python3 -m pytest -q src/respec/llm_service/`
Expected: 전부 PASS. ⏱ 약 16초.

- [ ] **Step 5: Julia 쪽 왕복을 배선한다**

🔴 **`@goto` 를 쓰지 말 것.** Julia 의 `@goto` 는 `try` 블록 안팎으로 못 뛴다.
등록 자리(`tools/monitor/enact.jl`)의 실제 모양은 이것이다:

```julia
            local why = CB.register_minted_primitive!(
                name = String(nm), code = String(cd), ...)
            why !== nothing && return _reject_malformed(why)
            registered = true
```

`_reject_malformed` 는 **즉시 반환**한다. 그러므로 되먹임은 그 반환 **앞**에 들어가고,
재시도가 정확히 한 번인 것은 루프가 아니라 **구조**로 보장된다(두 번째 거절은 곧장 반환).

먼저 도우미를 `enact_minted_decision!` **위**에 정의한다:

```julia
"""
    _rewrite_once(sl, nm, cd, why) -> Union{Nothing,NamedTuple}

거절 사유를 agent-3 에게 **한 번** 되먹여 고친 body 를 받는다. 못 받으면 `nothing`.

🔴 **절대 안 던진다.** 여기서 새면 집행부가 기록 대신 예외로 끝나고 호출자는 세계 상태를
   잃는다 — 이 파일 전체가 지키는 규약이다. 서비스가 안 떠 있는 것도 정상 경로다.
🔴 세계를 안 건드린다. 이 시점에 등록은 실패했고 `Core.eval` 은 안 돌았다.
"""
function _rewrite_once(sl, nm::AbstractString, cd::AbstractString, why::AbstractString)
    try
        body = JSON3.write(Dict(
            "tool_name" => something(_synth_lane_field(sl, "tool_name"), ""),
            "spec"      => something(_synth_lane_field(sl, "mechanism"), ""),
            "impl_name" => nm, "impl_code" => cd, "impl_rejected_why" => why))
        resp = HTTP.post(DSPY_URL * "/rewrite",
                         ["Content-Type" => "application/json"], body;
                         readtimeout = 120, retries = 0)
        f = JSON3.read(String(resp.body))
        (get(f, :wrote, nothing) === true) || return nothing
        (get(f, :impl_code, nothing) isa AbstractString) || return nothing
        (get(f, :impl_name, nothing) isa AbstractString) || return nothing
        return (impl_name = String(f.impl_name), impl_code = String(f.impl_code),
                params = get(f, :params, nothing), calls = get(f, :calls, nothing),
                surface = get(f, :surface, nothing), reversible = get(f, :reversible, nothing))
    catch e
        println("[minted] rewrite: 왕복 실패 (원래 거절이 그대로 남는다): ",
                first(split(sprint(showerror, e), "\n")))
        return nothing
    end
end
```

그리고 `why !== nothing && return _reject_malformed(why)` **한 줄을 교체**한다:

```julia
            # 🔴 D17. 거절 사유를 agent-3 에게 **한 번** 되먹인다. 재시도가 한 번인 것은
            #    루프가 아니라 **구조**다 — 두 번째 거절은 곧장 `_reject_malformed` 로 간다.
            if why !== nothing
                local fx = _rewrite_once(sl, String(nm), String(cd), why)
                fx === nothing && return _reject_malformed(why)
                println("[minted] rewrite: 되먹임 1회 — 원래 사유=", why)
                # 🔴 `sl` 을 갱신한다: 아래 집행부가 `calls`/`params` 를 여기서 읽는다.
                #    안 갱신하면 새 body 를 등록해 놓고 **낡은 인자**로 부른다.
                sl["impl_name"] = fx.impl_name
                sl["impl_code"] = fx.impl_code
                fx.params  !== nothing && (sl["params"]  = fx.params)
                fx.calls   !== nothing && (sl["calls"]   = fx.calls)
                fx.surface !== nothing && (sl["surface"] = fx.surface)
                local why2 = CB.register_minted_primitive!(
                    name = fx.impl_name, code = fx.impl_code,
                    params = something(_synth_lane_field(sl, "params"), Dict{String,Any}()),
                    surface = String(something(fx.surface, "unknown")),
                    reversible = fx.reversible === true)
                # 🔴 두 번째 거절은 **그 사유**를 나른다 — 첫 사유로 덮으면 되먹임이
                #    무엇을 못 고쳤는지가 기록에서 사라진다.
                why2 !== nothing && return _reject_malformed(why2)
            end
            registered = true
```

⚠️ `sl` 이 `Dict{String,Any}` 가 아닌 모양(`JSON3.Object`)으로 오는 경로에서는 위
`sl[...] = ...` 이 던진다. 등록 직전에 `sl isa AbstractDict && !(sl isa JSON3.Object)` 를
확인하고, 아니면 되먹임을 **건너뛴다**(원래 거절을 그대로 반환) — 되먹임은 있으면 좋은
것이지 반드시 도는 것이 아니다.

⚠️ `DSPY_URL` 은 `tools/monitor/policy.jl:20` 이 정의한다. 두 벌을 만들지 말 것 —
`enact.jl` 이 그것을 못 보면 로드 순서를 고치지, `get(ENV, "DSPY_URL", …)` 을 복사하지 않는다.

- [ ] **Step 6: Julia 초록**

Run: `julia +lts --project=. -e 'include("test/minted_end_to_end.jl")'`
Expected: (1)–(11) 전부 PASS. 🔴 서비스가 안 떠 있으면 `/rewrite` 왕복은 `catch` 로
떨어지고 **원래 거절이 그대로 남는다** — 그것이 시험이 통과해야 하는 모양이다. ⏱ 약 24초.

- [ ] **Step 7: 커밋**

```bash
git add src/respec/llm_service/synthesize.py src/respec/llm_service/dspy_service.py \
        src/respec/llm_service/test_rewrite_channel.py tools/monitor/enact.jl
git commit -m "D17: 거절 사유 되먹임 채널 — Julia -> /rewrite -> agent-3, 재시도 상한 1"
```

---

### Task 10: 사전등록 갱신과 유료 런

🔴 **결과를 보기 전에** 무엇이 판정인지 적는다. 이 레포는 반대로 하다가 반복해 데였다.

**Files:**
- Modify: `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md`

- [ ] **Step 1: 사전등록에 결정 셋을 더한다**

문서 끝에 붙인다:

```markdown
## 결정 5 (D17) — D6 의 뜻이 "1발" 에서 "재시도 포함" 으로 바뀐다

`/rewrite` 가 들어오면서 사건 하나가 agent-3 을 **최대 두 번** 부른다. 그러므로
"모델이 감춘 능력을 스스로 재유도했다"(D6)의 판정 단위는 **사건**이지 호출이 아니다.
🔴 로그에서 `withheld` 를 보고 성립이라 읽지 말 것은 그대로다 — 이름을 대조한다.

## 결정 6 (D18) — `world_delta` 가 L4 의 유일한 판정이다

`handled`·`applied`·`world_maybe_dirty`·`steps.status` 는 결정 1 이 적은 이유로 여전히
답이 못 된다. **`world_delta` 만 본다.** ⚠️ `n_binding_changed` 는 하한이다
(`assignment_binding` 의 docstring) — 0 이라고 안 바뀐 것은 아니다.

## 결정 7 (D13) — `needs` 는 실패의 **설명**이지 실패가 아니다

`needs != ""` 이면서 `registered == true` 인 런은 **성공한 런**이다. 그 문자열은 다음
인터페이스 확장의 입력이지 이번 런의 판정이 아니다.

## 비용 갱신 (D17)

`/decide` 하나당 **3(비발화) ~ 7(발화)** 에 **되먹임 1회당 +1**. 사건 하나짜리 런의
상한은 **8회**다.
```

- [ ] **Step 2: 런 전 체크리스트를 확인한다**

기존 체크리스트에 더한다:

```markdown
- [ ] `world_interface.json` 이 **오늘 재생성**됐는가 (`julia … tools/gen_world_interface.jl`
      뒤 `git status` 가 깨끗한가) — 낡은 스키마를 받은 모델의 실패는 기록에서 **모델의**
      실패로 남는다
- [ ] `/health` 의 세대 도장이 현행 커밋인가 — 🔴 기본 포트에 며칠 묵은 uvicorn 이
      `/health` 200 을 내고 있던 전례가 있다. `ps -o lstart` 로 커밋 시각과 대조한다
- [ ] 서비스가 `/rewrite` 를 아는가: `curl -s -X POST localhost:8077/rewrite -H
      'Content-Type: application/json' -d '{}' | head -c 200` 이 404 가 아닌가
```

- [ ] **Step 3: 커밋**

```bash
git add docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md
git commit -m "사전등록 갱신: D17 이 D6 판정 단위를, D18 이 L4 판정을 바꾼다 (런 전에 적는다)"
```

- [ ] **Step 4: 유료 런**

사전등록 문서의 런 전 체크리스트를 **전부** 통과시킨 뒤 실행한다.
판정은 설계 §0 의 사다리 L0→L4 순서로 읽는다. 결과를 보고 판정을 바꾸지 않는다.
