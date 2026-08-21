# sojourn 생성 시뮬레이터 SMDP — 구현 계획

> 🔴 **2026-08-21 대체됨. Phase 0~1(태스크 1~5)만 유효하고 그것은 이미 집행됐다**
> (`docs/superpowers/reports/2026-08-20-phase1-completion.md`).
> **Phase 2 이후(태스크 6~16)는 이 문서로 실행하지 말 것** — 지도교수 피드백 반영으로 상태가
> 26 → 7 필드로 줄었고, Task 8 의 rate boundary 식은 **실측으로 반증됐다**(활성 정점 15/15 가
> `rem ≤ 0`). 현행 계획:
> · `docs/superpowers/plans/2026-08-21-reduced-state-smdp-action-synthesis.md` (계획서 A)
> · `docs/superpowers/plans/2026-08-21-ood-layer-replay-buffer.md` (계획서 B)
> · 설계: `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md`
>
> 이 문서를 지우지 않는 이유: Phase 0~1 이 실제로 이 계획으로 집행됐고, 완료 보고서가
> "계획 대비 무엇이 달라졌나" 를 이 문서에 대고 적는다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 명목 구간을 해석적으로 건너뛰는 생성 시뮬레이터 `G(s,a) → (s′, R, τ)` 를 세워, 실패 사건이 DAG/scene tree 를 고치는 과정을 undiscounted SSP-SMDP 로 모델링한다.

**Architecture:** `hazard.jl` 이 이미 쓰는 "적분 위험 + Exp(1) 문턱" 형태에서 `τ` 를 **닫힌 형태로** 뽑는다(로그 1회·나눗셈 1회). Exp(1) 무기억성이 `cum`·`thr` 를 상태에서 빼주므로 `s` 는 26필드로 끝난다. 행동 적용은 **진짜 respec + MILP 재풀이**로 정확히 하고, 그 사이의 명목 구간만 경량으로 건너뛴다.

**Tech Stack:** Julia 1.10 LTS (`julia +lts --project=.`), Python 3 (게이트·분석), HiGHS/JuMP (MILP), rvo2 (Python 바인딩)

**Spec:** `docs/superpowers/specs/2026-08-20-sojourn-generative-smdp-design.md`

## Global Constraints

- **테스트 실행**: SMDP 계열 Julia 테스트는 **독립 프로세스**로 돈다 — `julia +lts --project=. test/<name>.jl`. `test/runtests.jl` 에 싣지 않는다(전역 덮어쓰기가 다른 테스트를 오염시킨다).
- **로드 순서**: `CB.include(".../src/navigator/navigator.jl")` 를 먼저, `CB.include(".../src/smdp/mdp.jl")` 를 나중에. 새 smdp 파일은 `src/smdp/mdp.jl` 의 `include` 목록에 등록한다.
- **시드 고정 = 완전 재현**이 요구사항이다. 런 간 결과 차이는 노이즈가 아니라 **버그로 보고**한다. 비교 런은 **순차 실행**(동시 실행은 HiGHS 경합 + OOM).
- **결정성의 단위는 프로세스가 아니라 디렉토리**(컴파일 캐시). 비교 런은 **한 디렉토리** 안에서 돈다.
- **모든 `Set`/`Dict` 는 정렬해서 직렬화**한다(`simstate.jl` `_c`). 안 하면 같은 상태가 프로세스마다 다른 해시를 얻는다.
- **조용한 폴백 금지.** 도장·어휘 불일치는 `error()` 로 죽는다. remap 하지 않는다.
- **`Project.toml [deps]` 를 건드리지 않는다.** `SHA` 는 `Base.require` 로 Manifest 전이 의존성을 우회 로드한다(`simstate.jl:30`).
- **행동 어휘는 `wm4spacecraft_manufacturing/core/action_registry.json` 이 단일 진실원**이다. 현행 도장 `v3-4arms`, 4팔: `0=NOOP · 1=Replace · 2=RelocateBuild · 3=SwapBattery`. 사건 종류 셋: `fault · battery · zone`.
- **3계층 reactive policy(TangentBug → PotentialField → RVO2)의 규칙을 바꾸지 않는다.** 이 계획의 어떤 태스크도 `tangent_bug.jl` · `potential_fields.jl` · `get_twist_cmd` · `set_rvo_priority!` 의 **로직**을 수정하지 않는다. Task 11 만이 RVO 전역의 **격리 배선**을 추가한다.
- **"G6 PASS" · "G3 PASS" 를 어디에도 인용하지 않는다.**
- **소요시간 표기**: 각 태스크 제목 옆의 값은 숙련 개발자 1인 기준 **집중 작업 시간**이다. 재컴파일·스윕 대기는 별도로 표시한다.

**총 추정: 38.75 h 집중 작업 + 6.7~9.7 h 대기** (Phase 0~4). Phase 5(MCTS)는 별도 계획으로 분리한다.

---

## File Structure

| 파일 | 책임 | 태스크 |
|---|---|---|
| `wm4.../oracle/gen_oracle_dataset.jl` | 라벨 생성. **`ACTION_NAME` 리터럴 제거** | 1 |
| `wm4.../core/objective.json` | `J` 의 단일 진실원. `generation` 만 bump | 2 |
| `src/smdp/simstate.jl` | `s` 의 타입·정준 직렬화. **26필드로 확장** | 3 |
| `src/smdp/observe.jl` | **신규.** `simstate_of(env)` — env → `s` 의 유일한 경로 | 4 |
| `src/smdp/hazard.jl` | 실패 프로세스. 손잡이 둘 + `s` 기반 λ 진입점 | 6 |
| `src/smdp/rates.jl` | **신규.** `rate_params(s)` · `inv_integrated_hazard` — §2 의 순수 수학 | 7 |
| `src/smdp/tplan.jl` | **신규.** `node_duration` · `T_plan_next` · `T_done` · ρ | 8 |
| `src/smdp/sojourn.jl` | **신규.** `sample_sojourn` · `advance_to_rate_boundary!` | 9 |
| `src/route_planning.jl` | `rvo_rebuild!` 분리(가드 제거). **정책 로직 불변** | 11 |
| `src/smdp/generative.jl` | **신규.** `G(s,a;rng)` · `apply_action!` · `legal_actions` | 12, 13 |
| `src/smdp/mdp.jl` | 로더. 새 파일 등록 | 3, 7, 8, 9, 12 |

`rates.jl` 을 `sojourn.jl` 에서 분리하는 이유: 순수 수학(부작용 없음)이라 씬·엔진 없이 단독으로 시험할 수 있고, §2 의 닫힌 형태가 맞는지를 **적분과 직접 대조**하는 시험이 그 파일에만 붙는다.

---

# Phase 0 — 즉시 (지금 데이터를 오염시키는 것)

## Task 1: `ACTION_NAME` 을 레지스트리 파생으로 — **45분**

`gen_oracle_dataset.jl:121-129` 의 `ACTION_NAME` 은 구 9팔 리터럴이라 새 어휘(`v3-4arms`)에서 `2 => "Deprioritize"`, `3 => "ForbidZone"` 으로 **틀린 이름을 행에 찍는다.** 지금 만드는 모든 라벨이 오염된다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl:121-129`
- Test: `test/smdp_action_name_smoke.jl` (신규)

**Interfaces:**
- Consumes: `ActionRegistry.NAME :: Dict{Int,String}`, `ActionRegistry.IDS :: Vector{Int}` (`wm4.../oracle/action_registry.jl` 이 이미 제공)
- Produces: 없음 (내부 상수 교체)

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_action_name_smoke.jl
# ACTION_NAME 이 레지스트리와 갈리면 라벨 행에 틀린 이름이 찍힌다. 리터럴이 되살아나면
# 이 시험이 죽는다.
#   julia +lts --project=. test/smdp_action_name_smoke.jl
using Test
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
const AR = ActionRegistry

# gen_oracle_dataset.jl 을 통째로 로드하면 씬을 만들기 시작하므로, 상수 정의부만 정규식으로 읽는다.
const SRC = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing",
                          "oracle", "gen_oracle_dataset.jl"), String)

@testset "ACTION_NAME 은 레지스트리 파생이다" begin
    # 1) 이름 리터럴이 소스에 남아 있으면 안 된다
    @test !occursin("2=>\"Deprioritize\"", replace(SRC, " " => ""))
    @test !occursin("3=>\"ForbidZone\"",   replace(SRC, " " => ""))
    # 2) 레지스트리가 오늘 뭐라고 하는지 못박는다 (음성 대조의 기준선)
    @test AR.NAME[2] == "RelocateBuild"
    @test AR.NAME[3] == "SwapBattery"
    @test AR.VOCAB  == "v3-4arms"
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_action_name_smoke.jl`
Expected: 첫 두 `@test` 가 FAIL — 소스에 구 리터럴이 살아 있다.

- [ ] **Step 3: 리터럴을 파생으로 교체한다**

`gen_oracle_dataset.jl:121-129` 의 `const ACTION_NAME = Dict(0=>"NOOP", ... 7=>"RelocateBuild")` 블록 전체를 다음으로 바꾼다:

```julia
# 매크로 번호 → 이름. **레지스트리 파생**(action_registry.json 이 단일 진실원).
# 2026-08-20 이전에는 구 9팔 리터럴이었고, 4팔 재번호 뒤에는 2/3 을 "Deprioritize"/"ForbidZone"
# 으로 **틀리게** 찍었다. 리터럴을 되살리지 말 것 — test/smdp_action_name_smoke.jl 이 막는다.
const ACTION_NAME = Dict(i => ActionRegistry.NAME[i] for i in ActionRegistry.IDS)
```

- [ ] **Step 4: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_action_name_smoke.jl`
Expected: PASS (5 tests)

- [ ] **Step 5: 커밋**

```bash
git add test/smdp_action_name_smoke.jl wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
git commit -m "fix(labels): derive ACTION_NAME from the registry -- the 9-arm literal mislabeled 2/3"
```

---

## Task 2: `generation` bump — **30분**

이 설계는 `fire_require_spare` 와 `mtbf_zone_s` 로 **동역학을 가른다**. `objective.json` 의 스칼라는 하나도 안 바뀌므로 `objective_hash` 가 그 단절을 볼 수 없다 — `generation` 이 그 자리를 메운다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/objective.json:22`
- Test: `wm4spacecraft_manufacturing/smdp/test_stamps.py` (기존 파일에 추가)

**Interfaces:**
- Consumes: `objective.objective_hash(cfg)` (기존)
- Produces: 새 `objective_hash` 값 — 이후 모든 산출물이 이 도장을 단다

- [ ] **Step 1: 현재 해시를 기록한다**

Run:
```bash
python3 -c "import sys; sys.path.insert(0,'wm4spacecraft_manufacturing/core'); \
import objective as O; c=O.load(); print(c['generation'], O.objective_hash(c))"
```
Expected: `2026-08-19-vocab-6-arms-hazard-on <32자 해시>` — 이 값을 적어 둔다.

- [ ] **Step 2: 실패하는 시험을 쓴다**

`wm4spacecraft_manufacturing/smdp/test_stamps.py` 끝에 추가:

```python
def test_generation_declares_the_sojourn_dynamics():
    """generation 은 '오늘 참인 것'을 선언한다. 4팔 축소 + hazard 두 손잡이 변경 뒤에도
    구세대 문자열이 남아 있으면, 서로 다른 동역학의 산출물이 같은 도장을 공유한다."""
    cfg = objective.load()
    assert cfg["generation"] == "2026-08-20-4arms-sojourn-spare-off-zone-on", cfg["generation"]
```

- [ ] **Step 3: 실패를 확인한다**

Run: `python3 -m pytest wm4spacecraft_manufacturing/smdp/test_stamps.py -k generation -q`
Expected: FAIL — `2026-08-19-vocab-6-arms-hazard-on`

- [ ] **Step 4: bump 한다**

`objective.json` 의 `"generation"` 값을 `"2026-08-20-4arms-sojourn-spare-off-zone-on"` 으로 바꾼다. **다른 스칼라는 건드리지 않는다.**

- [ ] **Step 5: 통과 + 해시가 실제로 갈렸는지 확인한다**

Run:
```bash
python3 -m pytest wm4spacecraft_manufacturing/smdp/test_stamps.py -k generation -q
python3 -c "import sys; sys.path.insert(0,'wm4spacecraft_manufacturing/core'); \
import objective as O; c=O.load(); print(c['generation'], O.objective_hash(c))"
```
Expected: PASS, 그리고 해시가 Step 1 의 값과 **다르다**.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/objective.json wm4spacecraft_manufacturing/smdp/test_stamps.py
git commit -m "chore(objective): bump generation -- sojourn dynamics split the world"
```

---

# Phase 1 — 병목. 없으면 아래 전부가 검증 불가

## Task 3: `SimState` 26필드 — **2시간**

**Files:**
- Modify: `src/smdp/simstate.jl` (블록 정의 + `canonical` + `_BLOCK_NAMES` + `_canonical_blocks`)
- Test: `test/smdp_simstate_fields.jl` (신규)

**Interfaces:**
- Produces:
  - `GeoBlock(; poses, build_delta, zones::Dict{Symbol,NTuple{3,Float64}})`
  - `RobotRec(; pose, soc, health, payload, role, usage_s::Float64, mode::Symbol, eff::Float64)`
  - `ProgBlock(; t::Float64, closed::Set{Int}, active::Dict{Int,Float64})`
  - `CourierRec(; target, courier, depot, home, goal, phase, t_out::Float64, t_swap::Float64)`
  - `SimState(; g, geo, fleet, prog, courier)`
  - `canonical(s::SimState; omit::Set{Symbol})`, `state_hash(s; omit)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_simstate_fields.jl
# 26필드 s 의 필드 민감도. **모든** 필드가 해시에 닿아야 한다 — 안 닿는 필드는 그 자리에서
# 조용히 두 세계를 합친다.
#   julia +lts --project=. test/smdp_simstate_fields.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; kw...) = CB.RobotRec(; pose = (0.0, 0.0, 0.0), soc = 0.9, health = :healthy,
                              payload = nothing, role = :idle,
                              usage_s = 12.5, mode = :transit, eff = 1.03, kw...)

function _s(; kw...)
    base = (g   = CB.GraphBlock(edges = Set([(1, 2)]), binding = Dict(1 => 7),
                                wedge_edges = Set{Tuple{Int,Int}}(),
                                dissolved_gates = Set{Tuple{Int,Int}}()),
            geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)), build_delta = (0.0, 0.0),
                              zones = Dict(:z1 => (1.0, 2.0, 0.5))),
            fleet = Dict(7 => _rec()),
            prog  = CB.ProgBlock(t = 3.25, closed = Set([1]), active = Dict(2 => 3.0)),
            courier = CB.CourierRec[])
    return CB.SimState(; merge(base, NamedTuple(kw))...)
end

@testset "새 필드 넷이 해시에 닿는다" begin
    h0 = CB.state_hash(_s())
    # zones 는 **기하까지** 나른다 — 이름이 같고 반지름이 다르면 다른 상태다
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
              build_delta = (0.0, 0.0), zones = Dict(:z1 => (1.0, 2.0, 0.9))))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(usage_s = 99.0)))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(mode = :carry))))  != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(eff = 1.04))))     != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.26, closed = Set([1]),
                                               active = Dict(2 => 3.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.25, closed = Set([1, 2]),
                                               active = Dict(2 => 3.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(t = 3.25, closed = Set([1]),
                                               active = Dict(2 => 3.5)))) != h0
end

@testset "omit 에 :prog 를 넣을 수 있다" begin
    a = _s(); b = _s(prog = CB.ProgBlock(t = 99.0, closed = Set([1]), active = Dict(2 => 3.0)))
    @test CB.state_hash(a) != CB.state_hash(b)
    @test CB.state_hash(a; omit = Set([:prog])) == CB.state_hash(b; omit = Set([:prog]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:porg]))
end

@testset "courier 는 절대 시각을 든다" begin
    c(t) = CB.CourierRec(target = 1, courier = 2, depot = :d, home = (0.0, 0.0),
                         goal = (1.0, 1.0), phase = :outbound, t_out = t, t_swap = 9.0)
    @test CB.state_hash(_s(courier = [c(1.0)])) != CB.state_hash(_s(courier = [c(2.0)]))
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_simstate_fields.jl`
Expected: FAIL — `UndefKeywordError: keyword argument zones not assigned` (또는 `ProgBlock` 미정의)

- [ ] **Step 3: 블록을 확장한다**

`src/smdp/simstate.jl` 에서:

```julia
"""행동이 편집하는 기하 + **sojourn 이 읽는 zone**. `zones` 는 2026-08-20 엄격 축소에서
빠졌다가 이 설계에서 돌아왔다 — zone 이 `T_plan_next` 를 가르기 때문이다(spec §3-3).
⚠️ **기하까지** 나른다. 이름만 나르면 반지름이 다른 두 상태가 같은 해시를 낸다."""
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}
    build_delta::NTuple{2,Float64}
    zones::Dict{Symbol,NTuple{3,Float64}}   # key => (cx, cy, r)
end

"""로봇 하나의 레코드. 다섯 필드는 행동의 write-set, 뒤 셋은 sojourn 의 read-set 이다.
`usage_s`·`mode` 는 λ_r 의 인자이고, `eff`(ε_r)는 soc 감소율의 인자다 — 상수라 동역학
비용이 0 인데, 빼면 모델이 잠재변수 혼합이 되어 s 에서 Markov 가 아니다(spec §3-3).
`mode ∈ {:idle, :transit, :carry, :manip}` — 실측 hazard.jl:333-338, `:transit` 이 기준(배수 1.0)."""
@kwdef struct RobotRec
    pose::NTuple{3,Float64}
    soc::Float64
    health::Symbol
    payload::Union{Nothing,Int}
    role::Symbol
    usage_s::Float64
    mode::Symbol
    eff::Float64
end

"""스케줄 진행 + 시계. `T_plan_next` 와 흡수상태 판정이 이것을 읽는다(spec §3-3).
`active` 의 값은 그 정점이 **실제로 시작한 시각** — 진행 중 노드의 잔여 소요시간을 내려면
필요하다. `t` 는 절대 sim 초이고 `CourierRec.t_*` 의 해석 기준이다."""
@kwdef struct ProgBlock
    t::Float64
    closed::Set{Int}
    active::Dict{Int,Float64}
end
```

`CourierRec` 의 `step_out::Int`/`step_swap::Int` 를 `t_out::Float64`/`t_swap::Float64` 로 바꾸고 docstring 의 "⚠️ 절대 스텝 인덱스인데 시계가 없다" 경고를 지운다(부채 (4) 해소).

`SimState` 에 `prog::ProgBlock` 을 넣는다.

- [ ] **Step 4: 정준 직렬화를 갱신한다**

```julia
canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),delta=$(_c(b.build_delta))," *
    "zones=$(_c(b.zones)))"

canonical(r::RobotRec) = "(pose=$(_c(r.pose)),soc=$(_c(r.soc)),health=$(_c(r.health))," *
    "payload=$(_c(r.payload)),role=$(_c(r.role)),usage=$(_c(r.usage_s))," *
    "mode=$(_c(r.mode)),eff=$(_c(r.eff)))"

canonical(b::ProgBlock) = "Prog(t=$(_c(b.t)),closed=$(_c(b.closed)),active=$(_c(b.active)))"

canonical(c::CourierRec) = "Cr(target=$(c.target),courier=$(c.courier),depot=$(_c(c.depot))," *
    "home=$(_c(c.home)),goal=$(_c(c.goal)),phase=$(_c(c.phase))," *
    "out=$(_c(c.t_out)),swap=$(_c(c.t_swap)))"
```

`_BLOCK_NAMES` 에 `:prog` 를 넣고 `_canonical_blocks` 에 `:prog => canonical(s.prog)` 항목을 추가한다(`:geo` 다음, `:fleet` 앞).

⚠️ `t_out`/`t_swap` 은 이제 `Float64` 이므로 **`_c(...)` 를 통해서** 찍는다 — 예전 `Int` 는 `$(c.step_out)` 로 직접 꽂아도 안전했지만 float 은 `-0.0` 정규화가 필요하다(`_c(::Float64)` 의 `+ 0.0`).

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_simstate_fields.jl`
Expected: PASS (11 tests)

- [ ] **Step 6: 기존 smdp 시험이 안 깨졌는지 확인한다**

Run:
```bash
julia +lts --project=. test/smdp_crn_smoke.jl
julia +lts --project=. test/smdp_stamp_smoke.jl
julia +lts --project=. test/smdp_global_inventory.jl
```
Expected: 셋 다 PASS. (실패하면 `SimState` 생성자를 부르는 자리를 찾아 `prog`/`zones`/새 `RobotRec` 필드를 채운다.)

- [ ] **Step 7: 커밋**

```bash
git add src/smdp/simstate.jl test/smdp_simstate_fields.jl
git commit -m "feat(smdp): extend s to 26 fields -- write-set union sojourn read-set"
```

---

## Task 4: `simstate_of(env)` + 게이트 N-G0 — **4시간**

🔴 **지금 env 에서 `SimState` 를 만드는 코드가 한 줄도 없다.** 이것이 이 계획의 병목이다.

**Files:**
- Create: `src/smdp/observe.jl`
- Modify: `src/smdp/mdp.jl` (include 등록)
- Test: `test/smdp_observe_gate.jl` (신규, = N-G0)

**Interfaces:**
- Consumes: `PlannerEnv`(`sched`·`scene_tree`·`cache`·`dt`), `CB.BATTERY_FLEET[]`, `CB.HAZARD_STATE[]`, `CB.RESTRICTION_ZONES`, Task 3 의 블록 생성자
- Produces: `simstate_of(env)::SimState` — **읽기 전용**. env 를 절대 수정하지 않는다.

- [ ] **Step 1: 게이트 시험을 쓴다 (필드별 음성 대조)**

```julia
# test/smdp_observe_gate.jl   —  게이트 N-G0
# simstate_of(env) 가 실제 env 를 충실히 읽는가. 방법은 **음성 대조**다: env 를 한 군데씩
# 흔들고 해시가 갈리는지 본다. 안 갈리는 필드는 그 자리에서 두 세계를 조용히 합친다.
# 그리고 simstate_of 는 **읽기 전용**이어야 한다 — 관측이 세계를 바꾸면 롤아웃이 오염된다.
#   julia +lts --project=. test/smdp_observe_gate.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# colored_8x8 = 33부품 x 1층, 실측 ~4초. 가장 싼 실제 씬.
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.mpd", project_name = "ng0",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         rendering = false, process_animation_tasks = false)
CB.enable_battery!(env)
CB.enable_hazard!(env; seed = 11)
CB.step_environment!(env); CB.set_sim_step!(1); CB.update_planning_cache!(env, 0.0)

@testset "simstate_of 는 읽기 전용이다" begin
    before = (length(env.cache.closed_set), length(env.cache.active_set),
              copy(CB.BATTERY_FLEET[].soc))
    s = CB.simstate_of(env)
    @test length(env.cache.closed_set) == before[1]
    @test length(env.cache.active_set) == before[2]
    @test CB.BATTERY_FLEET[].soc == before[3]
    # 두 번 불러도 같은 해시 (관측이 부작용을 남기지 않는다)
    @test CB.state_hash(s) == CB.state_hash(CB.simstate_of(env))
end

@testset "N-G0 필드 민감도 — env 를 흔들면 해시가 갈린다" begin
    h0 = CB.state_hash(CB.simstate_of(env))
    rid = first(sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string))

    # soc
    old = CB.BATTERY_FLEET[].soc[rid]
    CB.BATTERY_FLEET[].soc[rid] = old - 0.1
    @test CB.state_hash(CB.simstate_of(env)) != h0
    CB.BATTERY_FLEET[].soc[rid] = old
    @test CB.state_hash(CB.simstate_of(env)) == h0   # 복원하면 되돌아온다

    # usage_s  (hazard 상태)
    st = CB.HAZARD_STATE[]
    oldu = st.usage_s[rid]; st.usage_s[rid] = oldu + 5.0
    @test CB.state_hash(CB.simstate_of(env)) != h0
    st.usage_s[rid] = oldu

    # eff (ε_r)
    olde = st.eff[rid]; st.eff[rid] = olde * 1.01
    @test CB.state_hash(CB.simstate_of(env)) != h0
    st.eff[rid] = olde

    # zone 기하 — 이름이 아니라 반지름만 바꾼다
    CB.RESTRICTION_ZONES[:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    h1 = CB.state_hash(CB.simstate_of(env))
    @test h1 != h0
    CB.RESTRICTION_ZONES[:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 2.0)
    @test CB.state_hash(CB.simstate_of(env)) != h1   # 🔴 이름 같고 반지름만 달라도 갈려야 한다
    delete!(CB.RESTRICTION_ZONES, :ng0probe)
    @test CB.state_hash(CB.simstate_of(env)) == h0

    # 시계
    CB.set_sim_step!(2)
    @test CB.state_hash(CB.simstate_of(env)) != h0
    CB.set_sim_step!(1)
end

@testset "진행 상태가 실제 캐시를 반영한다" begin
    s = CB.simstate_of(env)
    @test s.prog.closed == Set(env.cache.closed_set)
    @test Set(keys(s.prog.active)) == Set(env.cache.active_set)
    @test s.prog.t ≈ CB.sim_time(env.dt)
    @test length(s.fleet) == length(CB.BATTERY_FLEET[].soc)
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_observe_gate.jl`
Expected: FAIL with `UndefVarError: simstate_of not defined`

- [ ] **Step 3: `observe.jl` 을 구현한다**

```julia
# =============================================================================
# observe.jl — env → s 의 **유일한** 경로 (spec §6 C2, 게이트 N-G0)
#
# 계약 셋. 어기면 롤아웃이 조용히 틀린다:
#   (1) **읽기 전용.** env·전역을 하나도 수정하지 않는다. 관측이 세계를 바꾸면 같은 상태를
#       두 번 관측한 것만으로 갈래가 갈린다.
#   (2) **파생 금지.** 여기서 새 값을 계산하지 않는다. 엔진이 이미 들고 있는 값을 옮길 뿐이다.
#       계산은 tplan.jl / rates.jl 의 몫이다.
#   (3) **`mode` 는 hazard 의 분류기를 재사용한다.** 여기서 다시 분류하면 두 레인의 λ 가 갈린다.
# =============================================================================

"""
    simstate_of(env) -> SimState

현재 `env`(+ 배터리·hazard 전역)에서 `s` 를 읽는다. 읽기 전용.
"""
function simstate_of(env)
    sched, cache = env.sched, env.cache
    fleet_b = BATTERY_FLEET[]
    st      = HAZARD_STATE[]

    # --- G: 행동이 편집하는 그래프 부분 -----------------------------------------------
    edges = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(sched)
        push!(edges, (Graphs.src(e), Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in Graphs.vertices(sched)
        for rid in (try _responsible_robots(get_node(sched, v).node) catch; () end)
            binding[v] = _int_key(rid)      # 정점 → 담당 로봇. 여러 대면 마지막이 아니라
            break                            # **정렬 첫 번째**를 쓴다(_responsible_robots 가 정렬됨)
        end
    end
    g = GraphBlock(edges = edges, binding = binding,
                   wedge_edges     = Set{Tuple{Int,Int}}(collect(WEDGE_EDGES)),
                   dissolved_gates = Set{Tuple{Int,Int}}(collect(DISSOLVED_GATES)))

    # --- Geo: 기하. zone 은 **중심·반지름까지** 나른다 ---------------------------------
    poses = Dict{Int,NTuple{3,Float64}}()
    for n in get_nodes(env.scene_tree)
        matches_template(RobotNode, n) || continue
        tr = global_transform(n).translation
        poses[_int_key(node_id(n))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in RESTRICTION_ZONES
        zones[k] = (Float64(ball.center[1]), Float64(ball.center[2]), Float64(ball.radius))
    end
    geo = GeoBlock(poses = poses, build_delta = _build_delta(), zones = zones)

    # --- Fleet: write-set 5 + sojourn read-set 3 --------------------------------------
    modes = _hz_modes(env)                      # 계약 (3): hazard 의 분류기를 재사용
    fleet = Dict{Int,RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        k = _int_key(rid)
        n = try get_node(env.scene_tree, rid) catch; nothing end
        p = n === nothing ? (0.0, 0.0, 0.0) :
            (let tr = global_transform(n).translation
                 (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
             end)
        fleet[k] = RobotRec(
            pose    = p,
            soc     = Float64(get(fleet_b.soc, rid, 1.0)),
            health  = (rid in st.broken) ? :dead : :healthy,
            payload = _payload_of(env, rid),
            role    = _role_of(env, rid),
            usage_s = Float64(get(st.usage_s, rid, 0.0)),
            mode    = get(modes, rid, :idle),
            eff     = Float64(get(st.eff, rid, 1.0)),
        )
    end

    # --- Prog: 스케줄 진행 + 시계 ------------------------------------------------------
    active = Dict{Int,Float64}()
    for v in cache.active_set
        active[v] = Float64(get_t0(sched, v))
    end
    prog = ProgBlock(t = Float64(sim_time(env.dt)),
                     closed = Set{Int}(collect(cache.closed_set)),
                     active = active)

    return SimState(g = g, geo = geo, fleet = fleet, prog = prog,
                    courier = _courier_recs(env))
end
```

보조 함수 `_int_key` · `_build_delta` · `_payload_of` · `_role_of` · `_courier_recs` 는 같은 파일 아래쪽에 둔다. `_int_key(id) = Int(id.id)` 이고 `RobotID` 가 아닌 경우 `hash` 폴백은 **두지 않는다** — 조용한 충돌보다 죽는 편이 낫다.

⚠️ `WEDGE_EDGES`·`DISSOLVED_GATES`·`RESTRICTION_ZONES` 의 실제 이름과 타입은 구현 시 `grep -rn "WEDGE_EDGES\|DISSOLVED_GATES\|RESTRICTION_ZONES" src/` 로 확인한다. 이름이 다르면 **그 이름을 쓰고, 이 계획의 오류로 보고**한다.

- [ ] **Step 4: 로더에 등록한다**

`src/smdp/mdp.jl` 의 `include("simstate.jl")` 다음 줄에:

```julia
include("observe.jl")   # env → s. simstate.jl(타입)·hazard.jl(_hz_modes) 둘 다에 의존한다
```

- [ ] **Step 5: 게이트를 돌린다**

Run: `julia +lts --project=. test/smdp_observe_gate.jl`
Expected: PASS. **하나라도 실패하면 그 필드는 `s` 가 못 보는 것이고, 실패를 통과로 바꾸기 전에 왜 안 보이는지 먼저 적는다.**

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/observe.jl src/smdp/mdp.jl test/smdp_observe_gate.jl
git commit -m "feat(smdp): simstate_of(env) -- the only env->s path, with the N-G0 field-sensitivity gate"
```

---

## Task 5: 갈래 비용 측정 — **1.5시간** (+ 재컴파일 대기 ~10분)

`G(s,a)` 의 1단계(갈래용 env 만들기)가 얼마인지 **잰 적이 없다.** MCTS 예산이 여기서 정해진다.

**Files:**
- Create: `tools/monitor/measure_branch_cost.jl`
- Create: `results/smdp/branch_cost.json` (산출물)

**Interfaces:**
- Consumes: `simstate_of(env)` (Task 4)
- Produces: `results/smdp/branch_cost.json` — `{"deepcopy_ms": …, "rvo_rebuild_ms": …, "simstate_of_ms": …, "n": …}`

- [ ] **Step 1: 측정 스크립트를 쓴다**

```julia
# tools/monitor/measure_branch_cost.jl
# G(s,a) 1단계의 비용을 잰다. **추정하지 말고 잰다** — MCTS 예산이 여기서 나온다.
#   julia +lts --project=. tools/monitor/measure_branch_cost.jl
using ConstructionBots, Statistics, JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "branchcost",
                         num_robots = 12, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         rendering = false, process_animation_tasks = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 1)
for k in 1:200
    CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0)
end

bench(f, n) = (f(); [(@elapsed f()) * 1000 for _ in 1:n])   # 첫 회는 컴파일 — 버린다

N = 20
d  = bench(() -> deepcopy(env), N)
s  = bench(() -> CB.simstate_of(env), N)
out = Dict("n" => N,
           "deepcopy_ms"    => (median = median(d), min = minimum(d), max = maximum(d)),
           "simstate_of_ms" => (median = median(s), min = minimum(s), max = maximum(s)),
           "n_robots" => length(CB.BATTERY_FLEET[].soc),
           "n_closed" => length(env.cache.closed_set))
mkpath(joinpath(pkgdir(CB), "results", "smdp"))
open(joinpath(pkgdir(CB), "results", "smdp", "branch_cost.json"), "w") do io
    JSON3.pretty(io, out)
end
println(JSON3.write(out))
```

- [ ] **Step 2: 돌린다**

Run: `julia +lts --project=. tools/monitor/measure_branch_cost.jl`
Expected: JSON 한 줄. `deepcopy_ms.median` 이 **핵심 수치**다.

- [ ] **Step 3: 판정을 적는다**

`docs/superpowers/specs/2026-08-20-sojourn-generative-smdp-design.md` §9 의 미해결 1번을 실측값으로 바꾼다. 판정 기준:

- `deepcopy_ms.median < 5` → 갈래를 마음껏 만들어도 된다. Task 12 를 그대로 간다.
- `5 ≤ … < 50` → 롤아웃당 갈래 1회로 제한한다(트리 노드마다가 아니라).
- `≥ 50` → **spec §5-1 의 1단계를 다시 설계해야 한다.** `s` 위 순수 함수로 행동을 재구현하는 선택지를 사용자에게 다시 올린다. 이 계획을 여기서 **멈춘다**.

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/measure_branch_cost.jl results/smdp/branch_cost.json \
        docs/superpowers/specs/2026-08-20-sojourn-generative-smdp-design.md
git commit -m "measure(smdp): branch cost for G(s,a) step 1 -- the MCTS budget comes from here"
```

---

# Phase 2 — τ 의 두 성분

## Task 6: hazard 손잡이 둘 + `s` 기반 λ 진입점 — **2시간**

**Files:**
- Modify: `src/smdp/hazard.jl:107-108` (기본값), `:100` 부근(`mtbf_zone_s`), 파일 끝(새 진입점)
- Test: `test/smdp_hazard_knobs.jl` (신규)

**Interfaces:**
- Produces: `hazard_rate_from(params, usage_s, soc, mode) -> Float64` — **두 레인이 공유하는 λ 의 단일 진실원**

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_hazard_knobs.jl
# (1) 기본값 둘이 spec 의 D-3 · D-4 대로인가.
# (2) λ 의 단일 진실원 — 무거운 레인(hazard_rate)과 경량 레인(hazard_rate_from)이
#     **같은 수**를 내는가. 갈리면 롤아웃이 다른 세계를 탐색한다.
#   julia +lts --project=. test/smdp_hazard_knobs.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "D-3 · D-4 기본값" begin
    p = CB.HazardParams()
    @test p.fire_require_spare == false          # D-3
    @test isfinite(p.mtbf_zone_s)                # D-4 — Inf 면 zone 이 영원히 안 온다
    @test p.fire_safe_target == true             # 바꾸지 않는다 (핫스왑이 이미 무해화)
    @test p.drain_step_cv == 0.0                 # spec §2-5 — 0 을 유지한다
end

@testset "λ 의 단일 진실원" begin
    st = CB._new_hazard_state(CB.HazardParams(), 3)
    CB._hz_ensure!(st, 1)
    st.usage_s[1] = 240.0
    for mode in (:idle, :transit, :carry, :manip), soc in (1.0, 0.6, 0.05)
        heavy = CB.hazard_rate(st, 1; mode = mode, soc = soc)
        light = CB.hazard_rate_from(st.params, 240.0, soc, mode)
        @test heavy ≈ light rtol = 0.0            # 정확히 같아야 한다 — 근사가 아니다
    end
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_hazard_knobs.jl`
Expected: FAIL — `fire_require_spare == true`, `mtbf_zone_s == Inf`, `hazard_rate_from` 미정의

- [ ] **Step 3: 기본값을 바꾼다**

`src/smdp/hazard.jl` 의 `HazardParams` 에서:

```julia
    mtbf_zone_s::Float64    = 1800.0   # D-4 (2026-08-20): 유한값으로 켠다. 기본이 Inf 였던 탓에
                                       # 커밋된 전 런에서 n_zone = 0 이었다(실측) — zone 이 사건
                                       # 종류로 선언돼 있는데 한 번도 도착하지 않는 상태였다.
                                       # ⚠️ 이 값은 **미교정**이다. N-G3 이 교정한다.
```

```julia
    fire_require_spare::Bool= false    # D-3 (2026-08-20): 예비와 무관하게 발화한다.
                                       # true 면 예비 소진 후 고장이 **영구 음소거**되는데 모델은
                                       # 계속 적분한다 — 그러면 잔여가 Exp(1) 이 아니라 0 이 되어
                                       # spec §2-3 의 무기억성이 깨지고, 적합이 "예비가 없으면
                                       # 고장이 안 난다"를 물리 법칙으로 배운다.
                                       # 대신 예비 고갈은 legal_actions 가 좁아지는 것으로 드러난다.
```

- [ ] **Step 4: λ 를 단일 진실원으로 접는다**

`hazard_rate` 의 본문을 새 순수 함수로 옮기고 기존 함수는 래퍼로 만든다:

```julia
"""
    hazard_rate_from(p::HazardParams, usage_s, soc, mode) -> Float64

λ 의 **단일 진실원**. 무거운 레인(`hazard_rate`)과 경량 레인(`rates.jl`)이 둘 다 이것을 부른다.
인자가 전부 `s` 에 있는 값이라는 것이 spec §3-3 의 요점이다.
"""
function hazard_rate_from(p::HazardParams, usage_s::Float64, soc::Float64, mode::Symbol)
    base = _rate(p.mtbf_break_s)
    base == 0 && return 0.0
    u_hat = p.usage_scale_s > 0 ? usage_s / p.usage_scale_s : 0.0
    return base * p.mode * _mode_mult(p, mode) *
           exp(p.beta_usage * u_hat + p.beta_soc * (1.0 - clamp(soc, 0.0, 1.0)))
end

# 기존 시그니처는 얇은 래퍼로 남는다 — 호출자를 전부 고칠 필요가 없다.
hazard_rate(st::HazardState, id; mode::Symbol = :idle, soc::Float64 = 1.0) =
    hazard_rate_from(st.params, st.usage_s[id], soc, mode)
```

- [ ] **Step 5: 통과 + 기존 hazard 시험 회귀 확인**

Run:
```bash
julia +lts --project=. test/smdp_hazard_knobs.jl
julia +lts --project=. test/smdp_crn_smoke.jl
```
Expected: 둘 다 PASS

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/hazard.jl test/smdp_hazard_knobs.jl
git commit -m "feat(hazard): spare-independent firing, finite zone mtbf, single source of truth for lambda"
```

---

## Task 7: `rates.jl` — §2 의 닫힌 형태 — **2.5시간**

**Files:**
- Create: `src/smdp/rates.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_rates.jl` (신규)

**Interfaces:**
- Consumes: `hazard_rate_from` (Task 6), `SimState`·`RobotRec` (Task 3)
- Produces:
  - `rate_params(s::SimState, p::HazardParams, capacity_J::Float64) -> Dict{Int,NTuple{2,Float64}}` — `id => (A, a)`
  - `rate_params_one(p::HazardParams, rec::RobotRec, capacity_J::Float64) -> NTuple{2,Float64}`
  - `integrated_hazard(A, a, Δ) -> Float64`
  - `inv_integrated_hazard(A, a, E) -> Float64` — 발화하지 않으면 `Inf`
  - `mode_power_W(mode::Symbol) -> Float64` — `battery.jl` 의 모드별 전력을 읽는 얇은 함수.
    **Task 9 의 `energy_between` 과 Task 7 의 `a_r` 이 같은 이 함수를 쓴다** — 두 자리에
    숫자를 따로 두면 soc 감소율과 에너지 회계가 갈린다

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_rates.jl
# spec §2-2 의 닫힌 형태가 **정말 맞는지** 수치 적분과 직접 대조한다. 이 파일은 씬도 엔진도
# 안 쓴다 — 순수 수학이라 그래야 한다.
#   julia +lts --project=. test/smdp_rates.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# 사다리꼴 수치적분 — 닫힌 형태의 독립 대조군
function numeric_integral(A, a, Δ; n = 200_000)
    h = Δ / n
    s = 0.5 * (A * exp(a * 0.0) + A * exp(a * Δ))
    for i in 1:(n - 1); s += A * exp(a * i * h); end
    return s * h
end

@testset "integrated_hazard == 수치적분" begin
    for (A, a, Δ) in ((1e-3,  2e-4, 60.0), (5e-4, -3e-4, 120.0),
                      (2e-3,  0.0,  30.0), (1e-3,  1e-6, 900.0))
        @test CB.integrated_hazard(A, a, Δ) ≈ numeric_integral(A, a, Δ) rtol = 1e-6
    end
end

@testset "inv_integrated_hazard 는 진짜 역함수다" begin
    for (A, a) in ((1e-3, 2e-4), (5e-4, -3e-4), (2e-3, 0.0), (1e-3, 1e-9))
        for Δ in (1.0, 37.5, 300.0)
            E = CB.integrated_hazard(A, a, Δ)
            @test CB.inv_integrated_hazard(A, a, E) ≈ Δ rtol = 1e-6
        end
    end
end

@testset "a<0 에서 유한 총위험 — 발화 안 하면 Inf" begin
    A, a = 1e-3, -1e-3
    total = -A / a                       # lim_{Δ→∞} (A/a)(e^{aΔ}−1) = −A/a
    @test CB.inv_integrated_hazard(A, a, total * 0.99) < Inf
    @test CB.inv_integrated_hazard(A, a, total * 1.01) == Inf   # 🔴 절대 음수를 내면 안 된다
    @test CB.inv_integrated_hazard(A, a, total)        == Inf   # 경계는 안전한 쪽으로
end

@testset "a→0 극한이 매끄럽다" begin
    A = 1e-3
    @test CB.integrated_hazard(A, 0.0, 50.0) ≈ A * 50.0
    @test CB.integrated_hazard(A, 1e-14, 50.0) ≈ A * 50.0 rtol = 1e-9
    @test CB.inv_integrated_hazard(A, 0.0, A * 50.0) ≈ 50.0
    @test CB.inv_integrated_hazard(A, 1e-14, A * 50.0) ≈ 50.0 rtol = 1e-9
end

@testset "rate_params 의 A 는 t=0 의 λ 와 같다" begin
    p   = CB.HazardParams()
    rec = CB.RobotRec(pose = (0.0, 0.0, 0.0), soc = 0.7, health = :healthy,
                      payload = nothing, role = :transport,
                      usage_s = 300.0, mode = :carry, eff = 1.0)
    A, a = CB.rate_params_one(p, rec, 1.0e5)
    @test A ≈ CB.hazard_rate_from(p, 300.0, 0.7, :carry) rtol = 0.0
    @test a > 0                          # :carry 는 usage 도 늘고 soc 도 준다 → λ 가 는다
    idle = CB.RobotRec(pose = (0.0, 0.0, 0.0), soc = 1.0, health = :healthy,
                       payload = nothing, role = :idle, usage_s = 0.0, mode = :idle, eff = 1.0)
    @test CB.rate_params_one(p, idle, 1.0e5)[2] == 0.0   # 대기 = usage 도 soc 도 안 움직인다
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_rates.jl`
Expected: FAIL with `UndefVarError: integrated_hazard not defined`

- [ ] **Step 3: 구현한다**

```julia
# =============================================================================
# rates.jl — spec §2 의 닫힌 형태. **부작용 없는 순수 수학.**
#
# 모드가 상수인 구간에서 usage 와 soc 가 t 에 선형이므로 λ 가 지수형이 된다:
#     λ_r(t) = A_r · exp(a_r · t)
#     A_r = hazard_rate_from(p, usage_r, soc_r, mode_r)          (t = 0 의 값)
#     a_r = β_u/U · 1[mode ≠ :idle]  +  β_s · P(mode)·ε_r / C
# 그래서 적분도 역함수도 닫힌다. dt 루프가 필요 없는 이유가 이것뿐이다.
# =============================================================================

const _A_ZERO_TOL = 1e-12    # |a| 가 이보다 작으면 λ 상수 극한을 쓴다 (수치 안정)

"""
    integrated_hazard(A, a, Δ) -> Float64

∫₀^Δ A·e^{a t} dt = (A/a)(e^{aΔ} − 1).  `a → 0` 극한은 `A·Δ`.
"""
function integrated_hazard(A::Float64, a::Float64, Δ::Float64)
    abs(a) < _A_ZERO_TOL && return A * Δ
    return (A / a) * (exp(a * Δ) - 1.0)
end

"""
    inv_integrated_hazard(A, a, E) -> Float64

`integrated_hazard(A, a, Δ) == E` 를 푸는 `Δ`. 이 구간 안에서 발화하지 않으면 `Inf`.

🔴 `a < 0` 이면 총위험이 `−A/a` 로 유한하다. `E` 가 그보다 크면 **이 위험은 영원히 발화하지
않는다** — 로그 인자가 0 이하가 되므로 반드시 걸러야 한다. 안 거르면 `NaN` 이나 음수 `Δ` 가
나오고, 그것이 `findmin` 을 통과해 **τ < 0** 인 epoch 를 만든다.
"""
function inv_integrated_hazard(A::Float64, a::Float64, E::Float64)
    (A <= 0.0 || !isfinite(E) || E < 0.0) && return Inf
    abs(a) < _A_ZERO_TOL && return E / A
    arg = 1.0 + a * E / A
    arg <= 0.0 && return Inf          # a<0 에서 총위험을 넘어섰다
    Δ = log(arg) / a
    return (isfinite(Δ) && Δ >= 0.0) ? Δ : Inf
end

"""
    rate_params_one(p::HazardParams, rec::RobotRec, capacity_J) -> (A, a)

로봇 하나의 `(A, a)`. `mode` 별 전력은 배터리 계층의 값을 그대로 쓴다 — 여기서 다시
정의하면 두 레인의 soc 감소율이 갈린다.
"""
function rate_params_one(p::HazardParams, rec::RobotRec, capacity_J::Float64)
    A = hazard_rate_from(p, rec.usage_s, rec.soc, rec.mode)
    du = (rec.mode === :idle) ? 0.0 : (p.usage_scale_s > 0 ? 1.0 / p.usage_scale_s : 0.0)
    dsoc = capacity_J > 0 ? mode_power_W(rec.mode) * rec.eff / capacity_J : 0.0
    a = p.beta_usage * du + p.beta_soc * dsoc
    return (A, a)
end

"""
    rate_params(s::SimState, p::HazardParams, capacity_J) -> Dict{Int,NTuple{2,Float64}}

발화 가능한 로봇만 담는다. 죽었거나 창고에 주차된 예비는 `_hz_excluded()` 와 같은 규칙으로
빠진다 — 그 규칙의 인자(`health`·`role`)가 이미 `s` 에 있다는 것이 spec §3-4 의 요점이다.
"""
function rate_params(s::SimState, p::HazardParams, capacity_J::Float64)
    out = Dict{Int,NTuple{2,Float64}}()
    for k in sort!(collect(keys(s.fleet)))
        rec = s.fleet[k]
        rec.health === :dead        && continue
        rec.role   === :spare_parked && continue
        out[k] = rate_params_one(p, rec, capacity_J)
    end
    return out
end
```

`mode_power_W(mode::Symbol)` 은 `battery.jl` 의 모드별 전력을 읽는 얇은 함수다. 구현 시 `grep -n "idle_W\|transit_W\|carry_W\|manip_W" src/navigator/battery.jl` 로 실제 필드 이름을 확인하고 **그 값을 그대로 쓴다.** 여기서 숫자를 복붙하지 않는다.

- [ ] **Step 4: 로더에 등록한다**

`src/smdp/mdp.jl` 에 `include("rates.jl")` 를 `observe.jl` 다음에 추가한다.

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_rates.jl`
Expected: PASS (24 tests)

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/rates.jl src/smdp/mdp.jl test/smdp_rates.jl
git commit -m "feat(smdp): closed-form integrated hazard and its inverse (spec section 2-2)"
```

---

## Task 8: `tplan.jl` — rate boundary — **3시간**

**Files:**
- Create: `src/smdp/tplan.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_tplan.jl` (신규)

**Interfaces:**
- Consumes: `SimState`(Task 3), `env.sched`(소요시간 조회용)
- Produces:
  - `node_duration(env, v) -> Float64` — ρ 보정 전 원값
  - `T_plan_next(s, env; rho = 1.0) -> Float64` — **다음 노드 완료까지 남은 시간**(현재 `s.prog.t` 기준). 활성 노드가 없으면 `Inf`
  - `T_done(s, env; rho = 1.0) -> Float64` — 남은 스케줄의 longest path
  - `RHO :: Ref{Float64}` — Task 10 이 채운다

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_tplan.jl
# T_plan_next 는 **결정 epoch 가 아니라 λ 의 구간상수 경계**다(spec §2-4). 여기서 재는 것은
# "다음에 모드가 바뀌는 순간이 언제인가" 뿐이다.
#   julia +lts --project=. test/smdp_tplan.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.mpd", project_name = "tplan",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         rendering = false, process_animation_tasks = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 5)
CB.step_environment!(env); CB.set_sim_step!(1); CB.update_planning_cache!(env, 0.0)

@testset "T_plan_next 는 양수이고 유한하다" begin
    s = CB.simstate_of(env)
    Δ = CB.T_plan_next(s, env)
    @test Δ > 0.0            # 🔴 0 이나 음수면 sample_sojourn 이 무한루프에 빠진다
    @test isfinite(Δ)
end

@testset "T_plan_next ≤ T_done" begin
    s = CB.simstate_of(env)
    @test CB.T_plan_next(s, env) <= CB.T_done(s, env) + 1e-9
end

@testset "ρ 는 선형 배수다" begin
    s = CB.simstate_of(env)
    @test CB.T_plan_next(s, env; rho = 2.0) ≈ 2.0 * CB.T_plan_next(s, env; rho = 1.0) rtol = 1e-9
end

@testset "완주 상태에서 T_done = 0, T_plan_next = Inf" begin
    s  = CB.simstate_of(env)
    s2 = CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet, courier = s.courier,
                     prog = CB.ProgBlock(t = s.prog.t,
                                         closed = Set(1:Graphs.nv(env.sched)),
                                         active = Dict{Int,Float64}()))
    @test CB.T_done(s2, env) == 0.0
    @test CB.T_plan_next(s2, env) == Inf
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_tplan.jl`
Expected: FAIL with `UndefVarError: T_plan_next not defined`

- [ ] **Step 3: 구현한다**

```julia
# =============================================================================
# tplan.jl — 논문 식 (4) 의 대응물. **경량 롤아웃 모델 그 자체**다(spec §5-4).
#
# ⚠️ 여기서 재는 것은 slack 이 아니다. `cache.node_queue` 가 드는 것은 "이 노드가 얼마나
#    늦어도 되는가"(slack)이고, 필요한 것은 "다음 완료가 언제인가"다. 계획서 이전 세대가
#    그 둘을 혼동했다.
#
# ⚠️ `min_duration = duration_lower_bound(node)` 는 **하한**이다. 실제 주행은 3계층 reactive
#    스택(TangentBug 우회 · potential field 반발 · RVO 상호회피)을 거치므로 더 길다.
#    ρ 가 그 격차를 흡수한다 — 그리고 **경량 모델은 혼잡·교착을 원리적으로 볼 수 없다.**
# =============================================================================

const RHO = Ref(1.0)    # Task 10(N-G2)이 무거운 레인에서 적합해 채운다

"정점 v 의 계획 소요시간(ρ 보정 전)."
node_duration(env, v::Int) = Float64(get_min_duration(env.sched, v))

"""
    T_plan_next(s, env; rho = RHO[]) -> Float64

`s.prog.t` 기준으로 **다음 노드 완료까지 남은 시간**. 활성 노드가 없으면 `Inf`.
활성 정점 `v` 의 잔여 = `ρ·dur(v) − (t − start(v))`, 아래로 0 에서 자르지 않고
**최소 한 양자는 남긴다** — 0 을 돌려주면 `sample_sojourn` 이 전진하지 못한다.
"""
function T_plan_next(s::SimState, env; rho::Float64 = RHO[])
    isempty(s.prog.active) && return Inf
    best = Inf
    for (v, t0) in s.prog.active
        rem = rho * node_duration(env, v) - (s.prog.t - t0)
        rem <= 0.0 && (rem = eps(Float64) * max(1.0, abs(s.prog.t)))
        rem < best && (best = rem)
    end
    return best
end

"""
    T_done(s, env; rho = RHO[]) -> Float64

미완 스케줄 DAG 의 longest path — 아무것도 고장 나지 않으면 언제 끝나는가.
위상정렬 1회. 흡수상태(전부 닫힘)에서는 0.
"""
function T_done(s::SimState, env; rho::Float64 = RHO[])
    sched = env.sched
    open_v = [v for v in Graphs.vertices(sched) if !(v in s.prog.closed)]
    isempty(open_v) && return 0.0
    finish = Dict{Int,Float64}()
    for v in Graphs.topological_sort_by_dfs(get_graph(sched))
        v in s.prog.closed && continue
        head = 0.0
        for u in Graphs.inneighbors(get_graph(sched), v)
            u in s.prog.closed && continue
            head = max(head, get(finish, u, 0.0))
        end
        dur = rho * node_duration(env, v)
        haskey(s.prog.active, v) && (dur = max(0.0, dur - (s.prog.t - s.prog.active[v])))
        finish[v] = head + dur
    end
    return maximum(values(finish))
end
```

- [ ] **Step 4: 로더에 등록한다**

`src/smdp/mdp.jl` 에 `include("tplan.jl")` 를 `rates.jl` 다음에 추가한다.

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_tplan.jl`
Expected: PASS (6 tests)

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/tplan.jl src/smdp/mdp.jl test/smdp_tplan.jl
git commit -m "feat(smdp): T_plan_next as the rate boundary, T_done as the absorbing horizon"
```

---

## Task 9: `sample_sojourn` + 게이트 N-G1 — **3시간**

**Files:**
- Create: `src/smdp/sojourn.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_sojourn.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng1.py` (신규)

**Interfaces:**
- Consumes: `rate_params`·`inv_integrated_hazard`·`integrated_hazard`(Task 7), `T_plan_next`·`T_done`(Task 8)
- Produces:
  - `sample_sojourn(s, env, p, rng; delta_max = Inf) -> (tau::Float64, event::Tuple{Symbol,Any})`
  - `advance_to_rate_boundary!(s, env, Δ) -> SimState` (새 `s` 를 돌려주는 함수형)
  - `advance_to(s, env, Δ) -> SimState` — **rate boundary 를 넘지 않는** 부분 전진.
    `Δ ≤ T_plan_next(s, env)` 를 전제하고, 노드를 닫지 않고 시계·usage·soc·pose 만 옮긴다.
    `sample_sojourn` 이 돌려준 τ 는 정의상 마지막 boundary 이후의 잔여이므로 이것이 맞다.
    ⚠️ `advance_to_rate_boundary!` 와 **다른 함수**다 — 이름이 비슷하니 헷갈리지 말 것.
  - `energy_between(s_a, s_b) -> Float64` — 두 상태 사이의 소비 에너지 [J].
    `Σ_r mode_power_W(mode_r)·eff_r·(t_b − t_a)` (모드가 상수인 구간 전제, spec §2-1)

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_sojourn.jl
#   julia +lts --project=. test/smdp_sojourn.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.mpd", project_name = "sojourn",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         rendering = false, process_animation_tasks = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7)
CB.step_environment!(env); CB.set_sim_step!(1); CB.update_planning_cache!(env, 0.0)
const S0 = CB.simstate_of(env)
const P  = CB.HazardParams()

@testset "τ > 0 이고 유한하다" begin
    for seed in 1:50
        τ, ev = CB.sample_sojourn(S0, env, P, MersenneTwister(seed))
        @test τ > 0.0                    # 🔴 게이트 G3 의 경량 레인 판
        @test isfinite(τ)
        @test ev[1] in (:failure, :terminal)
    end
end

@testset "같은 시드 = 같은 τ" begin
    a = CB.sample_sojourn(S0, env, P, MersenneTwister(42))
    b = CB.sample_sojourn(S0, env, P, MersenneTwister(42))
    @test a[1] == b[1] && a[2] == b[2]
end

@testset "λ 를 키우면 τ 가 줄어든다 (단조성)" begin
    slow = CB.HazardParams(mode = 0.1)
    fast = CB.HazardParams(mode = 10.0)
    med(p) = (ts = [CB.sample_sojourn(S0, env, p, MersenneTwister(k))[1] for k in 1:200];
              sort!(ts)[100])
    @test med(fast) < med(slow)
end

@testset "delta_max 는 지평선이다" begin
    τ, ev = CB.sample_sojourn(S0, env, CB.HazardParams(mode = 1e-9),
                              MersenneTwister(1); delta_max = 5.0)
    @test τ ≈ 5.0
    @test ev[1] === :horizon
end

@testset "dt 루프가 없다 — 200 회 표집이 1 초 안에" begin
    CB.sample_sojourn(S0, env, P, MersenneTwister(0))     # 컴파일 소진
    t = @elapsed for k in 1:200; CB.sample_sojourn(S0, env, P, MersenneTwister(k)); end
    @test t < 1.0
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_sojourn.jl`
Expected: FAIL with `UndefVarError: sample_sojourn not defined`

- [ ] **Step 3: 구현한다**

```julia
# =============================================================================
# sojourn.jl — spec §5-3. **dt 루프가 없다.**
#
# 두 종류의 시각을 구분한다(spec §2-4):
#   decision epoch  = 실패 도착. 행동 선택이 있다. 이 함수가 돌려주는 것.
#   rate boundary   = 다음 노드 완료. 행동 선택이 **없다**. 이 루프 안에만 있다.
# =============================================================================

_exp1_draw(rng) = -log(rand(rng))

"""
    sample_sojourn(s, env, p, rng; delta_max = Inf) -> (τ, event)

`event` 는 `(:failure, robot_key)` · `(:failure, :zone)` · `(:terminal, nothing)` ·
`(:horizon, nothing)` 중 하나.
"""
function sample_sojourn(s::SimState, env, p::HazardParams, rng;
                        delta_max::Float64 = Inf)
    cap = Float64(BATTERY_FLEET[].params.capacity_J)
    cur = s
    t   = 0.0
    E   = Dict(k => _exp1_draw(rng) for k in sort!(collect(keys(cur.fleet))))
    Ez  = _exp1_draw(rng)
    λz  = _rate(p.mtbf_zone_s) * p.mode

    while true
        rp = rate_params(cur, p, cap)
        Δ_fail, who = Inf, nothing
        for (k, (A, a)) in rp
            haskey(E, k) || continue
            d = inv_integrated_hazard(A, a, E[k])
            d < Δ_fail && (Δ_fail = d; who = k)
        end
        if λz > 0
            dz = Ez / λz
            dz < Δ_fail && (Δ_fail = dz; who = :zone)
        end

        Δ_node = T_plan_next(cur, env)
        Δ_stop = delta_max - t

        if Δ_fail <= min(Δ_node, Δ_stop)
            return (t + Δ_fail, (:failure, who))
        elseif Δ_stop <= Δ_node
            return (delta_max, (:horizon, nothing))
        end

        # rate boundary — 결정이 아니다. 소진하고 계속 간다.
        for (k, (A, a)) in rp
            haskey(E, k) && (E[k] -= integrated_hazard(A, a, Δ_node))
        end
        λz > 0 && (Ez -= λz * Δ_node)
        cur = advance_to_rate_boundary!(cur, env, Δ_node)
        t  += Δ_node
        isempty(cur.prog.active) && return (t, (:terminal, nothing))
    end
end
```

`advance_to_rate_boundary!(s, env, Δ)` 는 같은 파일에 둔다. 하는 일 넷:

1. `prog.t += Δ`, 잔여가 소진된 활성 정점을 `closed` 로 옮기고 후행을 활성화(`env.sched` 의 선행관계를 읽어 `T_plan_next` 와 **같은 규칙**으로)
2. 로봇마다 `usage_s += Δ·1[mode ≠ :idle]`, `soc -= mode_power_W(mode)·eff·Δ/C` (아래로 `floor_soc` 클램프)
3. `mode` 재분류 — 새 활성 집합 기준
4. `pose` 를 계획 경로 위에서 선형 보간

⚠️ (4)가 경량 모델의 **유일한 근사**다. 3계층 스택을 안 돌리므로 실제 궤적이 아니다.

같은 파일에 **부분 전진**과 **에너지 회계**도 둔다:

```julia
"""
    advance_to(s, env, Δ) -> SimState

rate boundary 를 **넘지 않는** 전진. 노드를 닫지 않고 시계·usage·soc·pose 만 옮긴다.
`sample_sojourn` 이 돌려준 τ 는 마지막 boundary 이후의 잔여이므로 이 함수가 맞다.
`Δ > T_plan_next(s, env)` 면 **죽는다** — 조용히 넘어가면 닫혀야 할 노드가 안 닫힌 채
시간만 흐르고, 그 뒤 모든 λ 가 틀린 모드에서 계산된다.
"""
function advance_to(s::SimState, env, Δ::Float64)
    Δ <= T_plan_next(s, env) + 1e-9 ||
        error("advance_to: Δ=$(Δ) 가 rate boundary $(T_plan_next(s, env)) 를 넘는다")
    return _advance_fields(s, Δ)      # advance_to_rate_boundary! 와 공유하는 (2) 부분
end

"""
    energy_between(a::SimState, b::SimState) -> Float64

두 상태 사이의 소비 에너지 [J]. 모드가 상수인 구간이라 닫힌 형태다(spec §2-1).
`a` 의 모드를 쓴다 — 구간 내내 그 모드였기 때문이다.
"""
function energy_between(a::SimState, b::SimState)
    Δ = b.prog.t - a.prog.t
    Δ <= 0 && return 0.0
    return sum(mode_power_W(r.mode) * r.eff * Δ for r in values(a.fleet); init = 0.0)
end
```

- [ ] **Step 3b: `max_events` 상한을 에러로 올린다** (spec §2-5)

`HazardParams.max_events = 64` 는 런어웨이 방지 상한이다. `hazard_step!` 은 상한에 닿으면
**조용히 `return nothing`** 한다(`hazard.jl:443`) — 그러면 프로세스가 멈춘 것을 아무도 모르고
`τ` 가 영원히 `T_done` 이 된다. 롤아웃에서는 이것이 "실패가 더는 안 온다"는 거짓 세계다.

`sample_sojourn` 의 루프에 반복 횟수 상한을 두고, 닿으면 **죽는다**:

```julia
        n_boundary += 1
        n_boundary > p.max_events * 16 && error(
            "sample_sojourn: rate boundary 를 $(n_boundary) 번 넘었다 — T_plan_next 가 " *
            "전진하지 않거나 λ 가 0 이다. 조용히 T_done 을 돌려주면 '실패가 안 오는 세계'를 " *
            "탐색하게 된다.")
```

시험에 음성 대조를 하나 넣는다: `λ = 0` 이고 `T_plan_next` 가 `eps` 만 돌려주는 픽스처에서
`@test_throws ErrorException CB.sample_sojourn(...)`.

- [ ] **Step 4: 게이트 N-G1 을 쓴다 — 정확 표집 vs dt-루프**

```python
#!/usr/bin/env python3
"""게이트 N-G1 — sample_sojourn 이 hazard_step! 의 dt-루프와 **같은 분포**를 내는가.

이것은 근사 검사가 아니다. spec §2-2 가 정확 표집을 주장하므로 KS 검정이 통과해야 한다.
떨어지면 셋 중 하나다: (a) 닫힌 형태가 틀렸다, (b) advance_to_rate_boundary! 가 usage/soc 를
엔진과 다르게 굴린다, (c) 아직 못 닫은 유예 기전이 있다(spec §2-5).

  python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
"""
import json, sys
from scipy.stats import ks_2samp

ALPHA = 0.01   # 위험 예산. 낮게 잡는다 — 여기서 위양성으로 죽는 것이 위음성보다 낫다

def main(path):
    d = json.load(open(path))
    light, heavy = d["light_tau"], d["heavy_tau"]
    assert len(light) >= 200 and len(heavy) >= 200, (len(light), len(heavy))
    st, p = ks_2samp(light, heavy)
    print(f"n_light={len(light)} n_heavy={len(heavy)} KS={st:.4f} p={p:.4g}")
    print(f"median light={sorted(light)[len(light)//2]:.4f} "
          f"heavy={sorted(heavy)[len(heavy)//2]:.4f}")
    if min(light) <= 0 or min(heavy) <= 0:
        print("FAIL: tau <= 0 이 있다"); return 1
    if p < ALPHA:
        print(f"FAIL: 두 분포가 갈린다 (p={p:.4g} < {ALPHA})"); return 1
    print("PASS"); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

짝 데이터를 만드는 Julia 쪽은 `tools/monitor/gen_ng1_pairs.jl` 에 둔다: 같은 `s` 에서
(가) `sample_sojourn` 을 200회, (나) hazard 를 켠 실제 `step_environment!` 루프를 200회(다른 hazard 시드로) 돌려 **첫 사건까지의 시간**을 모은다.

- [ ] **Step 5: 통과를 확인한다**

Run:
```bash
julia +lts --project=. test/smdp_sojourn.jl
julia +lts --project=. tools/monitor/gen_ng1_pairs.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
```
Expected: Julia PASS, 게이트 `PASS`

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/sojourn.jl src/smdp/mdp.jl test/smdp_sojourn.jl \
        tools/monitor/gen_ng1_pairs.jl wm4spacecraft_manufacturing/smdp/gate_ng1.py \
        results/smdp/ng1_pairs.json
git commit -m "feat(smdp): exact sojourn sampler with no dt loop, gated against the engine by KS (N-G1)"
```

---

## Task 10: ρ 적합 + 게이트 N-G2 — **2.5시간** (+ 스윕 대기 ~30분)

**Files:**
- Create: `tools/monitor/fit_rho.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng2.py`
- Modify: `src/smdp/tplan.jl` (`RHO[]` 기본값)

**Interfaces:**
- Consumes: `node_duration`(Task 8), 무거운 레인의 실제 노드 완료 시각
- Produces: `results/smdp/rho.json` — `{"rho": …, "n_nodes": …, "ratio_p10": …, "ratio_p90": …}`

- [ ] **Step 1: 실측 짝을 모은다**

`tools/monitor/fit_rho.jl` 은 `tractor.mpd` 를 hazard 없이 완주시키면서 정점마다 `(계획 소요시간 `get_min_duration`, 실제 소요시간 `실제 close 시각 − 실제 활성화 시각`)` 을 기록한다. `update_planning_cache!` 가 정점을 닫는 순간의 `sim_time(env.dt)` 를 쓴다.

- [ ] **Step 2: ρ 를 적합한다**

`ρ = median(실제/계획)`. **평균이 아니라 중앙값**이다 — 교착 한 번이 평균을 통째로 끌고 간다.

- [ ] **Step 3: 게이트 N-G2 를 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G2 — ρ 보정 뒤 T_plan 의 편향이 **팔 간 비교를 뒤집는가**.

정확도 게이트가 아니다(spec §5-4). 경량 모델은 3계층 스택을 안 돌리므로 절대값은 틀린다.
물어야 할 것은 하나다: 같은 사건에서 경량 모델이 매기는 팔 순위가 무거운 레인의 순위와
같은가.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json \
          results/smdp/arm_ranks.json
"""
import json, sys
from scipy.stats import kendalltau

MIN_TAU = 0.6     # 순위상관 하한
MAX_TOP1_FLIP = 0.10   # top-1 이 뒤집히는 사건의 비율 상한

def main(rho_path, ranks_path):
    rho = json.load(open(rho_path))
    d = json.load(open(ranks_path))
    print(f"rho={rho['rho']:.3f}  ratio p10/p90 = {rho['ratio_p10']:.2f}/{rho['ratio_p90']:.2f}")
    taus, flips = [], 0
    for ev in d["events"]:
        t, _ = kendalltau(ev["light_rank"], ev["heavy_rank"])
        taus.append(t)
        if ev["light_rank"][0] != ev["heavy_rank"][0]:
            flips += 1
    med = sorted(taus)[len(taus)//2]
    frac = flips / len(d["events"])
    print(f"n_events={len(d['events'])} median kendall tau={med:.3f} top1_flip={frac:.1%}")
    ok = med >= MIN_TAU and frac <= MAX_TOP1_FLIP
    print("PASS" if ok else
          f"FAIL: tau {med:.3f} < {MIN_TAU} 또는 top1_flip {frac:.1%} > {MAX_TOP1_FLIP:.0%}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
```

- [ ] **Step 4: 돌리고 판정한다**

Run:
```bash
julia +lts --project=. tools/monitor/fit_rho.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json results/smdp/arm_ranks.json
```

`ratio_p90 / ratio_p10 > 3` 이면 **스칼라 ρ 하나로 부족하다** — spec §9 미해결 5번이 발화한 것이다. 그 사실을 §9 에 실측으로 적고, 혼잡도(활성 로봇 수) 의존 ρ 를 후속 작업으로 올린다. **이 태스크에서 즉흥적으로 모델을 늘리지 않는다.**

- [ ] **Step 5: `RHO[]` 기본값을 채우고 커밋**

```bash
git add src/smdp/tplan.jl tools/monitor/fit_rho.jl \
        wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json results/smdp/arm_ranks.json
git commit -m "feat(smdp): fit rho against the heavy lane; gate on rank preservation not accuracy (N-G2)"
```

---

# Phase 3 — 생성 인터페이스

## Task 11: `rvo_rebuild!` + 게이트 N-G4 — **2시간**

🔴 spec §5-2 정정 2. `update_rvo_sim!` 은 `rvo_sim_needs_update` 로 가드돼 있어서 **에이전트가 추가될 때만** 재구축한다. 갈래가 위치만 옮겼으면 가드가 `false` 라 오염이 남는다.

**3계층 정책 로직은 하나도 바뀌지 않는다** — 술어만 뺀 같은 구성 경로다.

**Files:**
- Modify: `src/route_planning.jl:465-477`
- Test: `test/smdp_rvo_rebuild.jl` (신규, = N-G4)

**Interfaces:**
- Produces: `rvo_rebuild!(env) -> PlannerEnv` (무조건 재구축), `update_rvo_sim!(env)` (기존 동작 유지)

- [ ] **Step 1: 게이트 시험을 쓴다**

```julia
# test/smdp_rvo_rebuild.jl   —  게이트 N-G4
# RVO 는 씬트리의 **파생물**이다(spec §5-2). 그 명제가 참이면 재구축만으로 갈래 오염이 지워진다.
# 거짓이면 그건 롤아웃 문제가 아니라 **기존 실행 레인의 버그**다.
#   julia +lts --project=. test/smdp_rvo_rebuild.jl
using ConstructionBots, Test
const CB = ConstructionBots

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.mpd", project_name = "ng4",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false,
                         rendering = false, process_animation_tasks = false)
for k in 1:50; CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0); end

# ⚠️ `rvo_get_agent_position` 의 실제 시그니처(노드를 받는가 id 를 받는가)를 구현 시
#    `grep -n "function rvo_get_agent_position" -A4 src/rvo_interface.jl` 로 확인하고 맞춘다.
positions() = Dict(id => CB.rvo_get_agent_position(CB.get_node(env.scene_tree, id))
                   for id in sort!(collect(CB.get_vtx_ids(CB.rvo_global_id_map())); by = string))

@testset "재구축 후 위치 == 씬트리" begin
    CB.rvo_rebuild!(env)
    for (id, p) in positions()
        n  = CB.get_node(env.scene_tree, id)
        tr = CB.project_to_2d(CB.global_transform(n).translation)
        @test p[1] ≈ tr[1] atol = 1e-9
        @test p[2] ≈ tr[2] atol = 1e-9
    end
end

@testset "🔴 update_rvo_sim! 은 오염을 못 지운다 (음성 대조)" begin
    before = positions()
    victim = first(sort!(collect(keys(before)); by = string))
    CB.rvo_set_agent_position!(CB.get_node(env.scene_tree, victim), (99.0, 99.0))
    CB.update_rvo_sim!(env)                       # 가드가 false → 아무 일도 안 한다
    @test CB.rvo_get_agent_position(victim)[1] ≈ 99.0
    CB.rvo_rebuild!(env)                          # 무조건 재구축은 지운다
    @test CB.rvo_get_agent_position(victim)[1] ≈ before[victim][1] atol = 1e-9
end

@testset "재구축이 멱등이다" begin
    CB.rvo_rebuild!(env); a = positions()
    CB.rvo_rebuild!(env); b = positions()
    @test a == b
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_rvo_rebuild.jl`
Expected: FAIL with `UndefVarError: rvo_rebuild! not defined`

- [ ] **Step 3: 가드를 분리한다**

`src/route_planning.jl:465-477` 의 `update_rvo_sim!` 을 다음으로 바꾼다:

```julia
"""
    rvo_rebuild!(env)

RVO 시뮬레이터를 씬트리에서 **무조건** 다시 만든다. `update_rvo_sim!` 의 본문에서 술어만 뺀
것이고 구성 경로도 α 재적용도 같다 — **3계층 정책 규칙은 하나도 안 바뀐다.**

왜 가드 없는 판이 따로 필요한가(spec §5-2 정정 2): `rvo_sim_needs_update` 는
"필요한 에이전트가 맵에 없는가"만 본다. 롤아웃 갈래가 **위치만 옮기고 에이전트를 추가하지
않았으면** 가드가 false 라 재구축이 안 일어나고 오염이 다음 갈래로 샌다.

⚠️ **`apply_action!` 도중에 부르면 안 된다.** `replace_robot.jl:835` 가
`rvo_set_agent_max_speed!(tu, 0.0)` 로 핀을 걸고 같은 함수 안에서 force-close 한 뒤 :890 에서
복원한다. 재구축이 그 사이에 끼면 핀이 `get_rvo_max_speed(tu)` 로 되돌아가 RVO 가 유닛을
목표 밖으로 밀어내고, 그 함수가 막으려던 실패가 되살아난다. **완전히 끝난 뒤에만** 부른다.

⚠️ α 는 `cache.active_set` 에 대해서만 재적용된다(기존 동작 그대로). 활성 밖 에이전트의 α 는
`rvo_add_agent!` 의 기본값으로 돌아간다 — 그래서 무거운 레인에서는 **갈래 전환 시에만** 부른다.
"""
function rvo_rebuild!(env::PlannerEnv)
    @unpack sched, scene_tree, cache = env
    rvo_set_new_sim!()
    rvo_add_agents!(scene_tree)
    for v in cache.active_set
        set_rvo_priority!(env, get_node(sched, v))
    end
    return env
end

function update_rvo_sim!(env::PlannerEnv)
    if rvo_sim_needs_update(env.scene_tree)
        @info "New RVO simulation"
        rvo_rebuild!(env)
    end
    return env
end
```

`rvo_rebuild!` 를 `src/ConstructionBots.jl` 의 export 목록에 추가한다(`update_rvo_sim!` 옆).

- [ ] **Step 4: 통과 + 실행 레인 회귀 확인**

Run:
```bash
julia +lts --project=. test/smdp_rvo_rebuild.jl
julia +lts --project=. test/respec_determinism_smoke.jl
julia +lts --project=. tools/monitor/smoke_run.jl
```
Expected: 셋 다 PASS. **smoke_run 의 makespan 이 이 변경 전과 같아야 한다** — `update_rvo_sim!` 의 동작은 바뀌지 않았으므로.

- [ ] **Step 5: 커밋**

```bash
git add src/route_planning.jl src/ConstructionBots.jl test/smdp_rvo_rebuild.jl
git commit -m "feat(rvo): split the unguarded rebuild out of update_rvo_sim! -- policy rules unchanged (N-G4)"
```

---

## Task 12: `generative.jl` — `G(s,a)` — **4시간**

**Files:**
- Create: `src/smdp/generative.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_generative.jl` (신규)

**Interfaces:**
- Consumes: `action_to_proposal(ctx, a)`(`wm4.../oracle/ood_mdp_shim.jl:291`), `simstate_of`(4), `sample_sojourn`·`advance_to`·`energy_between`(9), `rvo_rebuild!`(11), `RESOLVE_CALLS`·`resolve_assignments!`(13 — 이 태스크에서는 **본문이 빈 스텁**으로 두고 Task 13 이 채운다)
- Produces:
  - `legal_actions(s, event_kind::Symbol) -> Vector{Int}`
  - `apply_action!(env, ctx, a::Int) -> Nothing`
  - `generate(s, env, ctx, a, p, rng; delta_max) -> (s′, R, τ, event)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_generative.jl
#   julia +lts --project=. test/smdp_generative.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "legal_actions 는 레지스트리 상한 안에 있다" begin
    @test CB.legal_actions_kind(:fault)   ⊆ Set([0, 1])
    @test CB.legal_actions_kind(:battery) ⊆ Set([0, 1, 3])
    @test CB.legal_actions_kind(:zone)    ⊆ Set([0, 2])
    @test 0 in CB.legal_actions_kind(:fault)     # NOOP 은 언제나 있다
end

@testset "🔴 예비가 0 이면 Replace 가 메뉴에서 빠진다 (D-3 의 요점)" begin
    s_nospare = _state_with_spares(0)     # 픽스처: role=:spare_parked 인 로봇이 없는 s
    s_spare   = _state_with_spares(3)
    @test !(1 in CB.legal_actions(s_nospare, :fault))
    @test   1 in CB.legal_actions(s_spare,   :fault)
    @test   0 in CB.legal_actions(s_nospare, :fault)   # NOOP 으로 감수한다
end

@testset "행동이 진짜로 그래프를 고친다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    CB.apply_action!(env, ctx, 1)                       # Replace
    s1 = CB.simstate_of(env)
    @test CB.state_hash(s1) != CB.state_hash(s0)
    @test s1.g.binding != s0.g.binding                  # 배정 엣지가 재스탬프됐다
    @test s1.fleet[ctx.agent_key].health === :dead      # 고장 로봇이 죽은 채 남았다
end

@testset "NOOP 은 그래프를 안 고친다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    CB.apply_action!(env, ctx, 0)
    s1 = CB.simstate_of(env)
    @test s1.g.edges == s0.g.edges
    @test s1.g.binding == s0.g.binding
end

@testset "generate 는 τ>0 과 유한 R 을 낸다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    s1, R, τ, ev = CB.generate(s0, env, ctx, 0, CB.HazardParams(), MersenneTwister(3))
    @test τ > 0.0
    @test isfinite(R)
    @test R <= 0.0                                       # 보상은 비용의 음수다 (spec §4)
    @test s1.prog.t ≈ s0.prog.t + τ  rtol = 1e-9
end
```

`_state_with_spares` · `_fault_fixture` 는 같은 파일 위쪽에 둔다. `_fault_fixture` 는 `colored_8x8` 씬을 만들고 `CB.fault_action(...)` 으로 사건 하나를 심은 뒤 `(env, ctx)` 를 돌려준다.

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_generative.jl`
Expected: FAIL with `UndefVarError: legal_actions_kind not defined`

- [ ] **Step 3: `legal_actions` 를 구현한다**

```julia
"""
    legal_actions_kind(kind::Symbol) -> Vector{Int}

레지스트리가 정하는 **상한**. `ActionRegistry.kind_valid` 의 얇은 래퍼다 — 여기서 리터럴을
쓰지 않는다(Global Constraint: 어휘의 단일 진실원은 JSON 하나).
"""
legal_actions_kind(kind::Symbol) = ActionRegistry.kind_valid(String(kind))

"""
    legal_actions(s, kind) -> Vector{Int}

상태를 아는 좁히기. 지금 좁히는 축은 **예비 재고** 하나다.

D-3 으로 `fire_require_spare = false` 가 됐으므로, 예비 고갈은 이제 "고장이 안 나는" 것이
아니라 **"고칠 수 없는"** 것으로 나타난다. 그 사실이 드러나는 유일한 자리가 여기다.
"""
function legal_actions(s::SimState, kind::Symbol)
    arms = legal_actions_kind(kind)
    n_spare = count(r -> r.role === :spare_parked && r.health === :healthy, values(s.fleet))
    n_spare == 0 && (arms = filter(a -> a != 1, arms))   # 1 = Replace 는 창고 본체를 먹는다
    isempty(arms) && return [0]
    0 in arms || pushfirst!(arms, 0)
    return sort!(arms)
end
```

- [ ] **Step 4: `apply_action!` 과 `generate` 를 구현한다**

```julia
"""
    apply_action!(env, ctx, a) -> Nothing

행동을 **진짜 respec 으로** 집행한다(spec D-2). 근사 모델이 아니다 — DAG·scene tree 편집이
정확해야 그 편집을 SMDP 로 모델링한다는 주장이 성립한다.

순서가 중요하다. `rvo_rebuild!` 는 **맨 마지막**이다(spec §5-2 정정 2 의 핀 경고).
"""
function apply_action!(env, ctx, a::Int)
    prop = action_to_proposal(ctx, a)
    prop === nothing || apply_respec!(env, prop)
    resolve_assignments!(env)          # 공통 MILP 재풀이 — Task 13 이 채운다
    update_schedule_times!(env.sched)
    update_planning_cache!(env, 0.0)
    rvo_rebuild!(env)                  # ← 반드시 마지막
    return nothing
end

"""
    generate(s, env, ctx, a, p, rng; delta_max = Inf) -> (s′, R, τ, event)

`G(s,a)`. spec §5-1.
"""
function generate(s::SimState, env, ctx, a::Int, p::HazardParams, rng;
                  delta_max::Float64 = Inf)
    apply_action!(env, ctx, a)
    s_plus = simstate_of(env)
    τ, ev  = sample_sojourn(s_plus, env, p, rng; delta_max = delta_max)
    s_next = advance_to(s_plus, env, τ)
    R      = -(τ + objective_w_E() * energy_between(s_plus, s_next))
    return (s_next, R, τ, ev)
end
```

`objective_w_E()` 도 이 파일에 둔다 — `Objective.load()` 의 `kappa * M_ref / E_ref` 를 읽을 뿐이고 **여기서 숫자를 계산하지 않는다**(단일 진실원은 `objective.json`):

```julia
function objective_w_E()
    c = Objective.load()
    return Float64(c["kappa"]) * Float64(c["M_ref"]) / Float64(c["E_ref"])
end
```

`resolve_assignments!` 는 이 태스크에서 **빈 스텁**으로 둔다(`RESOLVE_CALLS[] += 1; return (ran_milp=false, n_reassigned=0)`). Task 13 이 채운다 — 그래야 Task 12 의 시험이 Task 13 을 기다리지 않는다.

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_generative.jl`
Expected: PASS (16 tests)

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/generative.jl src/smdp/mdp.jl test/smdp_generative.jl
git commit -m "feat(smdp): G(s,a) -- real respec for the edit, closed-form jump for the nominal interval"
```

---

## Task 13: 공통 MILP 재풀이 — **3시간**

spec §1-E 의 미구현분. 모든 팔 뒤에 **같은** 재풀이가 돌아야 `Ĵ(a)` 비교가 팔의 성질이 된다.

**Files:**
- Modify: `src/smdp/generative.jl` (`resolve_assignments!`)
- Test: `test/smdp_common_resolve.jl` (신규)

**Interfaces:**
- Produces: `resolve_assignments!(env) -> NamedTuple` — `(ran_milp::Bool, n_reassigned::Int)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_common_resolve.jl
# 재풀이는 **파이프라인의 성질**이어야 한다. 어떤 팔에서든 돈다 — NOOP 에서도.
# 그것이 spec §1-E 가 게이트 G6 을 폐기한 이유다.
#   julia +lts --project=. test/smdp_common_resolve.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "모든 팔이 재풀이를 부른다" begin
    for a in (0, 1)
        env, ctx = _fault_fixture()
        CB.RESOLVE_CALLS[] = 0
        CB.apply_action!(env, ctx, a)
        @test CB.RESOLVE_CALLS[] == 1      # 팔마다 정확히 한 번
    end
end

@testset "재풀이는 결정론적이다" begin
    env1, ctx1 = _fault_fixture(); CB.apply_action!(env1, ctx1, 1)
    env2, ctx2 = _fault_fixture(); CB.apply_action!(env2, ctx2, 1)
    @test CB.state_hash(CB.simstate_of(env1)) == CB.state_hash(CB.simstate_of(env2))
end

@testset "재풀이가 스케줄을 유효하게 남긴다" begin
    env, ctx = _fault_fixture()
    CB.apply_action!(env, ctx, 1)
    @test CB.validate(env.sched)           # 무효 스케줄이면 롤아웃 전체가 무의미
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_common_resolve.jl`
Expected: FAIL — `RESOLVE_CALLS` 미정의

- [ ] **Step 3: 구현한다**

```julia
const RESOLVE_CALLS = Ref(0)    # 계측용. 시험이 "정말 돌았는가"를 이걸로 본다

"""
    resolve_assignments!(env) -> (ran_milp, n_reassigned)

**모든 팔 뒤에 도는 공통 재풀이.** 미배정 프론티어를 현재 그래프·기하 위에서 다시 푼다.
어떤 팔에서든 같은 코드가 돌아야 `Ĵ(a)` 의 차이가 팔의 차이가 된다(spec §1-E).

⚠️ 스케줄이 유효하지 않으면 **죽는다.** 조용히 넘어가면 그 롤아웃의 나머지가 전부 거짓이다.
"""
function resolve_assignments!(env)
    RESOLVE_CALLS[] += 1
    n = release_pending_assignments!(env)          # 재배정 대상 프론티어를 연다
    ran = false
    if n > 0
        ran = true
        assign_collaborative_tasks!(env)           # 실행 레인과 **같은** 배정기
    end
    validate(env.sched) || error("resolve_assignments!: 스케줄이 무효다 — 이 롤아웃은 못 쓴다")
    return (ran_milp = ran, n_reassigned = n)
end
```

⚠️ `release_pending_assignments!` · `assign_collaborative_tasks!` 의 실제 이름·시그니처는 구현 시 `grep -rn "release_pending_assignments\|assign_collaborative_tasks" src/` 로 확인한다.

- [ ] **Step 4: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_common_resolve.jl`
Expected: PASS (5 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/generative.jl test/smdp_common_resolve.jl
git commit -m "feat(smdp): one common MILP re-solve after every arm (spec 1-E)"
```

---

## Task 14: 게이트 N-G5 — 보상 분해 — **2시간**

**Files:**
- Create: `tools/monitor/check_reward_decomposition.jl`
- Create: `wm4spacecraft_manufacturing/smdp/gate_ng5.py`

**Interfaces:**
- Consumes: `generate`(Task 12)
- Produces: `results/smdp/ng5_decomposition.json`

- [ ] **Step 1: 무엇을 검사하는지 못박는다**

spec §4 는 `J = Σ τ_k + w_E · Σ ΔE_k` 를 주장한다. 이 게이트는 **한 판에서** 그 등식이 성립하는지 본다.

- [ ] **Step 2: 검사 스크립트를 쓴다**

`tools/monitor/check_reward_decomposition.jl` 이 hazard 를 켠 한 판을 끝까지 굴리면서 epoch 마다 `(τ_k, ΔE_k)` 를 모으고, 종단에서 `makespan` 과 `battery_report().total_energy_J` 를 읽어 JSON 으로 낸다.

- [ ] **Step 3: 게이트를 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G5 — 보상이 epoch 위로 정말 가법적인가 (spec §4).

깨지는 방식이 셋이고 전부 조용하다:
  (a) epoch 가 [0, T_end] 를 안 덮는다  → sum(tau) < makespan
  (b) 지평선에서 잘렸다                → sum(tau) < makespan (같은 증상, 다른 원인)
  (c) 에너지 회계가 이중 계상됐다      → sum(dE) != energy_J

  python3 wm4spacecraft_manufacturing/smdp/gate_ng5.py results/smdp/ng5_decomposition.json
"""
import json, sys

RTOL = 1e-6

def main(path):
    d = json.load(open(path))
    st, se = sum(d["tau"]), sum(d["dE"])
    m, e = d["makespan"], d["energy_J"]
    ok = True
    for name, got, want in (("sum(tau) vs makespan", st, m), ("sum(dE) vs energy_J", se, e)):
        rel = abs(got - want) / max(abs(want), 1e-12)
        print(f"{name}: {got:.6f} vs {want:.6f}  rel={rel:.2e}")
        if rel > RTOL:
            ok = False
    print(f"n_epochs={len(d['tau'])} terminal={d['terminal']}")
    print("PASS" if ok else f"FAIL: 보상 분해가 성립하지 않는다 (rtol={RTOL})")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 4: 돌린다**

Run:
```bash
julia +lts --project=. tools/monitor/check_reward_decomposition.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng5.py results/smdp/ng5_decomposition.json
```
Expected: `PASS`

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/check_reward_decomposition.jl \
        wm4spacecraft_manufacturing/smdp/gate_ng5.py results/smdp/ng5_decomposition.json
git commit -m "test(smdp): gate the additive reward decomposition over epochs (N-G5)"
```

---

# Phase 4 — 데이터

## Task 15: 예비 수·워치독 재설정 — **2시간** (+ 스윕 대기 ~1시간)

D-3 으로 예비 없이도 고장이 나므로 **미완주 판이 늘어난다.** 재스윕 전에 이 축을 정해야 한다.

**Files:**
- Create: `tools/monitor/sweep_spares_watchdog.jl`
- Modify: `docs/superpowers/specs/2026-08-20-sojourn-generative-smdp-design.md` §9

- [ ] **Step 1: 격자를 정한다**

`DEMO_SPARES ∈ {2, 4, 6}` × `stall_limit ∈ {2500, 5000}` — 6칸, 각 3시드 = 18판.

- [ ] **Step 2: 돌리고 완주율을 잰다**

Run: `julia +lts --project=. tools/monitor/sweep_spares_watchdog.jl`

⚠️ **순차 실행**한다(동시 실행은 HiGHS 경합 + OOM 으로 결과가 갈린다).

- [ ] **Step 3: 고른다**

기준: 완주율 **60~85%** 인 칸. 100% 면 예비가 희소하지 않아 `Replace`/`NOOP` 구분이 사라지고, 30% 미만이면 `J` 가 실패 분기에 지배당해 팔 간 차이가 안 보인다.

⚠️ 알려진 함정: hazard-on 판은 빌드가 죽은 뒤에도 각 사건이 워치독을 **리셋**해서 makespan 의 57~68% 가 죽은 빌드 위의 패딩이었다(실측). 완주율만이 아니라 **`n_closed / n_total` 도 함께** 본다.

- [ ] **Step 4: 값과 근거를 spec §9 에 적고 커밋**

```bash
git add tools/monitor/sweep_spares_watchdog.jl results/smdp/spares_watchdog.json \
        docs/superpowers/specs/2026-08-20-sojourn-generative-smdp-design.md
git commit -m "measure(smdp): pick spare count and watchdog for the spare-independent hazard world"
```

---

## Task 16: hazard-on 재스윕 + 게이트 N-G3 (λ 교정) — **3시간** (+ 스윕 대기 ~5~8시간)

**Files:**
- Create: `wm4spacecraft_manufacturing/smdp/gate_ng3.py`
- Modify: `src/smdp/hazard.jl` (교정된 `mtbf_*`)

- [ ] **Step 1: 도장을 먼저 확인한다**

Run:
```bash
python3 -c "import sys; sys.path.insert(0,'wm4spacecraft_manufacturing/core'); \
import objective as O, action_registry as A; c=O.load(); \
print(c['generation'], O.objective_hash(c), A.VOCAB)"
```
Expected: Task 2 의 새 `generation`, `v3-4arms`. **다르면 스윕을 시작하지 않는다** — 구세대 도장으로 5~8시간을 태우게 된다.

- [ ] **Step 1b: `require_vocab` 을 생산자에 배선한다** (선행 spec N-7-3)

Step 1 은 사람이 눈으로 보는 검사다. 도장은 지금 **write-only** 이고 소비처가 0개라,
`relabel_2026-08-19.jsonl` 이 서로 다른 세 세대의 도장을 달고 있는데 아무도 안 잡는다(실측).
4팔 재번호로 id 0..3 이 연속이 되면서 구세대 행이 **조용히 읽히므로** 도장이 유일한 방어선이다.

스윕 생산자가 입력 산출물을 읽는 자리에 `ActionRegistry.require_vocab(obj, where)` 를 넣는다.
불일치면 **죽는다** — remap 하지 않는다.

```bash
grep -rn "require_vocab" wm4spacecraft_manufacturing/ | grep -v "def \|function "
# 배선 전: 소비처 0개. 배선 뒤: 최소 1개.
```

- [ ] **Step 2: 스윕을 돌린다**

Task 15 가 고른 예비 수·워치독으로, `DEMO_HAZARD=1` · `DEMO_HOTSWAP=1` 을 켜고 돈다.
**⚠️ 라벨 레인은 실행 레인과 같은 세계여야 한다** — `DS_HOTSWAP=1` 을 빠뜨리면 `fault` 발화율이 100% → 23% 로 **에러 없이** 샌다(2026-08-15 실측). 생성된 파일의 `hot_swap` 필드가 `{"enabled": true, "mode": "via_depot"}` 인지 확인한다.

- [ ] **Step 3: 게이트 N-G3 을 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G3 — 모델 λ 가 관측 도착률과 맞는가.

정확 표집기를 만들어도 **틀린 λ 를 정확히 표집할 뿐**이다. 현행 신뢰구간은
Poisson 95% CI [0.24, 7.22] — 참 도착률이 예측의 0.12~3.6배 어디든 될 수 있다는 뜻이라
못 쓴다.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng3.py results/smdp/hazard_on_sweep.json
"""
import json, sys
from scipy.stats import chisquare, poisson

MAX_CI_RATIO = 1.8    # CI 상한/하한. 1.8 이면 참값이 예측의 대략 ±35% 안이라는 뜻

def main(path):
    d = json.load(open(path))
    ok = True
    for kind in ("fault", "battery", "zone"):
        obs = d["observed_counts"][kind]      # 판별 관측 사건 수
        exp = d["expected_counts"][kind]      # 모델 λ 로부터의 기대값
        n = sum(obs)
        lo, hi = poisson.interval(0.95, max(n, 1))
        ratio = hi / max(lo, 1e-9)
        st, p = chisquare(obs, exp) if n >= 20 else (float("nan"), float("nan"))
        print(f"{kind}: n={n} expected={sum(exp):.1f} CI=[{lo:.0f},{hi:.0f}] "
              f"ratio={ratio:.2f} chi2_p={p:.4g}")
        if n < 20:
            print(f"  FAIL: {kind} 사건이 {n} 개뿐 — 교정할 표본이 없다"); ok = False
        elif ratio > MAX_CI_RATIO:
            print(f"  FAIL: CI 폭 {ratio:.2f} > {MAX_CI_RATIO}"); ok = False
        elif p < 0.01:
            print(f"  FAIL: 관측이 모델과 갈린다 (p={p:.4g})"); ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 4: 교정하고 다시 돌린다**

`mtbf_break_s` · `mtbf_cell_s` · `mtbf_zone_s` 를 관측 도착률에 맞춰 조정하고 Step 2~3 을 반복한다. **`zone` 이 특히 미교정이다** — Task 6 이 넣은 `1800.0` 은 근거 없는 초기값이다.

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/hazard.jl wm4spacecraft_manufacturing/smdp/gate_ng3.py \
        results/smdp/hazard_on_sweep.json
git commit -m "fix(hazard): calibrate arrival rates against the hazard-on sweep (N-G3)"
```

---

# Phase 5 — MCTS (별도 계획)

MCTS + UCT + root parallelization 은 **독립 하위시스템**이고 Phase 0~4 가 전부 통과한 뒤에야 시작할 수 있다(그 전에는 굴릴 생성 모델이 없다). 별도 spec/plan 을 받는다. 그 계획이 다룰 것:

- 트리 노드 키 — `s` 자체인가, `s` + read-set 요약인가 (선행 spec §11 N-11-1)
- read-set ablation (N-11-2)
- root parallelization 과 재컴파일 잡음 바닥의 관계
- **UCT 는 표준형으로 구현한다**: `Q̄(n) + c·sqrt(ln N(parent) / N(n))`. 논문 식 (8)과 Pettet et al. 식 (3)은 분자/분모가 뒤집혀 있다 — 그대로 옮기면 자식을 많이 방문할수록 exploration bonus 가 커진다.

⛔ 이 계획 어디에도 `snapshot`/`restore!`/dp 격자/G1/G-M 은 없다. 되살리자는 제안이 나오면 `2026-08-20-tamp-nominal-smdp-failure-design.md` §11-2 를 먼저 읽을 것.

---

# 소요시간 요약

| Phase | 태스크 | 집중 작업 | 대기 |
|---|---|---|---|
| 0 | 1, 2 | 1.25 h | — |
| 1 | 3, 4, 5 | 7.5 h | ~10 min |
| 2 | 6, 7, 8, 9, 10 | 13.5 h | ~30 min |
| 3 | 11, 12, 13, 14 | 11 h | — |
| 4 | 15, 16 | 5.5 h | 6~9 h |
| | **합** | **38.75 h** | **6.7~9.7 h** |

리뷰·수정 왕복을 15% 얹으면 **약 44.5 h 집중 작업**. 하루 5 h 기준 **9 근무일**.

**임계 경로**: Task 4(`simstate_of`) → Task 9(sojourn) → Task 12(`G(s,a)`) → Task 16(λ 교정).
Task 5 가 `deepcopy_ms.median ≥ 50` 을 내면 **Task 12 앞에서 멈추고** 설계를 다시 올린다.
