# 축소 상태 SMDP + 행동 신설 — 구현 계획 (계획서 A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `s` 를 26 → 7 필드로 줄이고, 그 위에서 생성 시뮬레이터 `G(s,a) → (s′, R, τ)` 를 완성한 뒤, LLM 이 **아무도 안 짠 대응을 만들고 검증이 그것을 안전하게 만드는** 경로(`L_prim`)를 연다.

**Architecture:** 상태 축소의 기준은 "이미 하드코딩된 하위 정책의 관할이거나, `s` 안의 다른 값에서 다시 만들 수 있거나, 상수면 상태가 아니다". 그 결과 `s = (G, Geo, Fleet, Prog)` 7필드이고 로봇당 `(soc, usage_s)` 둘이다. 명목 구간은 `λ(t) = A·e^{at}` 의 닫힌 형태로 건너뛰고, 행동은 진짜 respec 으로 집행한다. 행동 신설은 두 갈래로 연다 — MILP 제약 문법(일반 `verify()` 가 이미 검증한다)과 파라미터가 자유로운 기하 원시연산 `TranslateBuild(dx, dy)`.

**Tech Stack:** Julia 1.10 LTS (`julia +lts --project=.`), Python 3 (게이트·분석), HiGHS/JuMP (MILP), rvo2 (Python 바인딩)

**Spec:** `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md`

## Global Constraints

- **테스트 실행**: SMDP 계열 Julia 테스트는 **독립 프로세스**로 돈다 — `julia +lts --project=. test/<name>.jl`. `test/runtests.jl` 에 싣지 않는다(전역 덮어쓰기가 다른 테스트를 오염시킨다).
- **로드 순서**: `CB.include(".../src/navigator/navigator.jl")` 를 먼저, `CB.include(".../src/smdp/mdp.jl")` 를 나중에. 새 smdp 파일은 `src/smdp/mdp.jl` 의 `include` 목록에 등록한다.
- **시드 고정 = 완전 재현**이 요구사항이다. 런 간 결과 차이는 노이즈가 아니라 **버그로 보고**한다. 비교 런은 **순차 실행**(동시 실행은 HiGHS 경합 + 프로세스당 ~2.5 GB 로 OOM).
- **결정성의 단위는 프로세스가 아니라 디렉토리**(컴파일 캐시). 비교 런은 **한 디렉토리** 안에서 돈다.
- **모든 `Set`/`Dict` 는 정렬해서 직렬화**한다(`simstate.jl` 의 `_c`). 안 하면 같은 상태가 프로세스마다 다른 해시를 얻는다.
- **조용한 폴백 금지.** 도장·어휘 불일치, 가정 위반은 `error()` 로 죽는다. remap 하지 않는다.
- **`Project.toml [deps]` 를 건드리지 않는다.** `SHA` 는 `Base.require` 로 Manifest 전이 의존성을 우회 로드한다(`simstate.jl:30`).
- **행동 어휘의 단일 진실원은 `wm4spacecraft_manufacturing/core/action_registry.json`** 이다. 현행 도장 `v3-4arms`, 4팔: `0=NOOP · 1=Replace · 2=RelocateBuild · 3=SwapBattery`. 사건 종류 셋: `fault · battery · zone`.
- **3계층 reactive policy(TangentBug → PotentialField → RVO2)의 규칙을 바꾸지 않는다.** 이 계획의 어떤 태스크도 `tangent_bug.jl` · `potential_fields.jl` · `get_twist_cmd` · `set_rvo_priority!` 의 **로직**을 수정하지 않는다. Task 11 만이 RVO 전역의 **격리 배선**을 추가한다.
- **"G6 PASS" · "G3 PASS" 를 어디에도 인용하지 않는다.**
- **게이트를 짤 때는 음성 대조를 먼저 실측한다.** 초록불은 증거가 아니다 — 이 브랜치에서 "절대 실패할 수 없던 시험" 여섯 개가 전부 초록이었다.
- **소요시간 표기**: 각 태스크 제목 옆의 값은 숙련 개발자 1인 기준 **집중 작업 시간**이다. 재컴파일·스윕 대기는 별도로 표시한다.

**총 추정: 55.5 h 집중 작업 + 7~10 h 대기** (Phase 1R~5). OOD layer 와 replay buffer 는 **계획서 B** 로 분리한다.

---

## File Structure

| 파일 | 책임 | 태스크 |
|---|---|---|
| `src/smdp/simstate.jl` | `s` 의 타입·정준 직렬화. **7필드로 축소** | R1 |
| `src/smdp/observe.jl` | `simstate_of(env)` — env → `s` 의 유일한 경로. 멤버십으로 축소 | R2 |
| `tools/monitor/measure_reduction_evidence.jl` | **신규.** 축소 근거 3건 실측 | R3 |
| `tools/monitor/measure_branch_cost.jl` | 갈래 비용 재측정 | R4 |
| `src/smdp/hazard.jl` | 실패 프로세스. 손잡이 셋 + `s` 기반 λ 진입점 | T6 |
| `src/smdp/rates.jl` | **신규.** `rate_params` · `inv_integrated_hazard` — spec §2 의 순수 수학 | T7 |
| `src/smdp/derive.jl` | **신규.** `active_of(s)` · `mode_of(s, env, k)` — `s` 의 파생 접근자 | T7 |
| `src/smdp/tplan.jl` | **신규.** `node_duration` · `T_plan_next` · `T_done` · ρ | T8 |
| `src/smdp/sojourn.jl` | **신규.** `sample_sojourn` · `advance_to` · `energy_between` | T9 |
| `src/route_planning.jl` | `rvo_rebuild!` 분리(가드 제거). **정책 로직 불변** | T11 |
| `src/smdp/generative.jl` | **신규.** `G(s,a;rng)` · `apply_action!` · `legal_actions` | T12, T13 |
| `src/respec/spec_dsl.jl` | `LinearConstraint` · `TranslateBuild` 추가 | C2, C3 |
| `src/respec/compiler.jl` | `LinearConstraint` 컴파일 | C2 |
| `src/respec/replan.jl` | `maybe_respecify!` 를 **순차 집행**으로 | C1 |
| `src/respec/verifier.jl` | `verify_translate` — 일반 기하 검증기 | C4 |
| `src/smdp/mdp.jl` | 로더. 새 파일 등록 | R1, T7, T8, T9, T12 |

`derive.jl` 을 `rates.jl` 에서 분리하는 이유: `active_of`/`mode_of` 는 `s` 의 **파생 접근자**이고 `rates.jl` 은 **순수 수학**이다. 섞으면 `rates.jl` 이 씬을 참조하게 되어 수치적분 대조 시험이 엔진에 묶인다.

---

# Phase 1R — 상태 축소 (병목. 없으면 아래 전부가 옛 상태 위에 선다)

## Task R1: `SimState` 26 → 7 필드 — **3시간**

spec §2-6. `CourierRec` 블록을 통째로 삭제하고 `RobotRec` 을 8 → 2 필드로 줄인다.

**Files:**
- Modify: `src/smdp/simstate.jl` (블록 정의 + `canonical` + `_BLOCK_NAMES` + `_canonical_blocks`)
- Test: `test/smdp_simstate_fields.jl` (전면 재작성)

**Interfaces:**
- Produces:
  - `GraphBlock(; edges::Set{Tuple{Int,Int}}, binding::Dict{Int,Int})`
  - `GeoBlock(; poses::Dict{Int,NTuple{3,Float64}}, zones::Dict{Symbol,NTuple{3,Float64}})`
  - `RobotRec(; soc::Float64, usage_s::Float64)`
  - `ProgBlock(; closed::Set{Int})`
  - `SimState(; g, geo, fleet::Dict{Int,RobotRec}, prog)`
  - `canonical(s::SimState; omit::Set{Symbol})`, `state_hash(s; omit)` — 시그니처 불변
- 🔴 **삭제**: `CourierRec` 타입 전체, `RobotRec` 의 `pose`·`health`·`payload`·`role`·`mode`·`eff`, `GeoBlock.build_delta`, `GraphBlock.wedge_edges`·`dissolved_gates`, `ProgBlock.t`·`active`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_simstate_fields.jl
# 7필드 s 의 필드 민감도. **모든** 필드가 해시에 닿아야 한다 — 안 닿는 필드는 그 자리에서
# 조용히 두 세계를 합친다. 그리고 **지운 필드가 정말 지워졌는지**를 음성 대조로 못박는다:
# 옛 이름으로 생성자를 부르면 죽어야 한다. 안 죽으면 축소가 안 된 것이다.
#   julia +lts --project=. test/smdp_simstate_fields.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

_rec(; soc = 0.9, usage_s = 12.5) = CB.RobotRec(; soc = soc, usage_s = usage_s)

function _s(; kw...)
    base = (g   = CB.GraphBlock(edges = Set([(1, 2)]), binding = Dict(1 => 7)),
            geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                              zones = Dict(:z1 => (1.0, 2.0, 0.5))),
            fleet = Dict(7 => _rec()),
            prog  = CB.ProgBlock(closed = Set([1])))
    return CB.SimState(; merge(base, NamedTuple(kw))...)
end

@testset "일곱 필드가 전부 해시에 닿는다" begin
    h0 = CB.state_hash(_s())
    @test CB.state_hash(_s(g = CB.GraphBlock(edges = Set([(1, 3)]),
                                             binding = Dict(1 => 7)))) != h0
    @test CB.state_hash(_s(g = CB.GraphBlock(edges = Set([(1, 2)]),
                                             binding = Dict(1 => 8)))) != h0
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 1.0)),
                                             zones = Dict(:z1 => (1.0, 2.0, 0.5))))) != h0
    # zones 는 **기하까지** 나른다 — 이름이 같고 반지름이 다르면 다른 상태다
    @test CB.state_hash(_s(geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                             zones = Dict(:z1 => (1.0, 2.0, 0.9))))) != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(soc = 0.8))))      != h0
    @test CB.state_hash(_s(fleet = Dict(7 => _rec(usage_s = 99.0)))) != h0
    @test CB.state_hash(_s(prog = CB.ProgBlock(closed = Set([1, 2])))) != h0
end

@testset "🔴 음성 대조 — 지운 필드는 정말 지워졌다" begin
    # 옛 필드 이름으로 생성자를 부르면 죽어야 한다. 살아 있으면 축소가 안 된 것이다.
    @test_throws MethodError CB.RobotRec(soc = 0.9, usage_s = 1.0, eff = 1.0)
    @test_throws MethodError CB.RobotRec(soc = 0.9, usage_s = 1.0, mode = :transit)
    @test_throws MethodError CB.GeoBlock(poses = Dict{Int,NTuple{3,Float64}}(),
                                         zones = Dict{Symbol,NTuple{3,Float64}}(),
                                         build_delta = (0.0, 0.0))
    @test_throws MethodError CB.GraphBlock(edges = Set{Tuple{Int,Int}}(),
                                           binding = Dict{Int,Int}(),
                                           wedge_edges = Set{Tuple{Int,Int}}())
    @test_throws MethodError CB.ProgBlock(closed = Set{Int}(), t = 0.0)
    # CourierRec 타입 자체가 없다
    @test !isdefined(CB, :CourierRec)
end

@testset "omit 은 네 블록만 받는다" begin
    a = _s(); b = _s(prog = CB.ProgBlock(closed = Set([1, 2])))
    @test CB.state_hash(a) != CB.state_hash(b)
    @test CB.state_hash(a; omit = Set([:prog])) == CB.state_hash(b; omit = Set([:prog]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:courier]))
    @test_throws ErrorException CB.canonical(a; omit = Set([:porg]))
end

@testset "정준 직렬화가 순서에 무관하다" begin
    a = CB.SimState(g = CB.GraphBlock(edges = Set([(1, 2), (3, 4)]),
                                      binding = Dict(1 => 7, 2 => 8)),
                    geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                      zones = Dict(:z1 => (1.0, 2.0, 0.5))),
                    fleet = Dict(7 => _rec(), 8 => _rec(soc = 0.5)),
                    prog = CB.ProgBlock(closed = Set([1])))
    b = CB.SimState(g = CB.GraphBlock(edges = Set([(3, 4), (1, 2)]),
                                      binding = Dict(2 => 8, 1 => 7)),
                    geo = CB.GeoBlock(poses = Dict(1 => (0.0, 0.0, 0.0)),
                                      zones = Dict(:z1 => (1.0, 2.0, 0.5))),
                    fleet = Dict(8 => _rec(soc = 0.5), 7 => _rec()),
                    prog = CB.ProgBlock(closed = Set([1])))
    @test CB.state_hash(a) == CB.state_hash(b)
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_simstate_fields.jl`
Expected: FAIL — `UndefKeywordError: keyword argument pose not assigned` (현행 `RobotRec` 이 8필드를 요구한다)

- [ ] **Step 3: 블록을 축소한다**

`src/smdp/simstate.jl` 의 블록 정의 다섯을 다음으로 **교체**한다:

```julia
"""행동이 편집하는 스케줄 그래프 부분. 2026-08-21 축소에서 `wedge_edges`·`dissolved_gates` 가
빠졌다 — 전자는 `edges` 의 부분집합이고(실측: `replace_robot.jl:297-298`·`:424-425` 가
`add_edge!` **직후** 장부에 적는다), 후자는 하드코딩 복구 루틴의 메모라 손실 압축으로 뺐다
(spec §2-3). ⚠️ `dissolved_gates` 는 `edges` 로 복원되지 **않는다** — 그 손실은 감수한 것이다."""
@kwdef struct GraphBlock
    edges::Set{Tuple{Int,Int}}          # precedence + 배정 엣지. Replace 가 편집한다
    binding::Dict{Int,Int}              # 정점 → 바인딩된 로봇 id. Replace 가 재스탬프한다
end

"""행동이 편집하는 기하 + sojourn 이 읽는 zone. `build_delta` 는 2026-08-21 축소에서 빠졌다 —
엔진에 출처가 없어 **상수 `(0,0)`** 이었고 상수는 상태가 아니다.
⚠️ `zones` 는 **기하까지** 나른다. 이름만 나르면 반지름이 다른 두 상태가 같은 해시를 낸다.
⚠️ `poses` 는 **조립체** 위치다(로봇이 아니다). `RelocateBuild` 가 `s` 에 남기는 유일한 흔적."""
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}
    zones::Dict{Symbol,NTuple{3,Float64}}   # key => (cx, cy, r)
end

"""로봇 하나의 레코드 — **두 필드뿐이다.** λ 와 에너지가 읽는 것이 이 둘이 전부다
(`λ = base·mult(mode)·exp(β_u·usage_s/U + β_s·(1−soc))`, spec §2-1).

2026-08-21 축소에서 빠진 여섯과 그 처분(spec §2-2):
  `pose`·`payload` — 3계층 reactive 스택 + 운반유닛 계층의 관할
  `role`·`health`  — **`fleet` 의 멤버십**으로 대체(아래 SimState docstring)
  `mode`           — `prog.closed`+`g.edges`+`g.binding` 의 파생. `derive.jl` 의 `mode_of`
  `eff` (ε_r)      — **D-5 로 동역학에서 없앴다**(`drain_sigma = 0.0`). 그냥 빼면 잠재변수
                     혼합이 되어 s 에서 Markov 가 아니다 — 뺀 게 아니라 없앤 것이다

🔴 `usage_s` 를 되돌리지 말 것: `_hz_ensure!`(hazard.jl:296)가 새 로봇에 `usage_s = 0.0` 을
찍으므로 **이 필드가 `Replace` 팔의 유일한 흔적**이다. 빼면 λ 관점에서 Replace 와 NOOP 이
구분되지 않는다."""
@kwdef struct RobotRec
    soc::Float64        # [0,1]. SwapBattery 가 되돌린다
    usage_s::Float64    # 누적 활동 초. Replace 가 0 으로 되돌린다
end

"""스케줄 진행. **`closed` 하나뿐이다.**
2026-08-21 축소에서 빠진 둘:
  `active` — `frontier(closed, edges)` 의 파생(실측 `essential_tg_coponents.jl:1921-1932`:
             "모든 선행이 closed_set 에 있으면 활성"). `derive.jl` 의 `active_of`
  `t`      — 이 정식화는 undiscounted · **time-homogeneous** SSP-SMDP 다. 절대시각이 상태에
             있으면 같은 상황이 시각별로 다른 트리 노드가 되어 통계가 쪼개진다"""
@kwdef struct ProgBlock
    closed::Set{Int}
end

"""s = (G, Geo, Fleet, Prog) — **7 필드**. 판정 기준(spec §2-1):
**이미 하드코딩된 하위 정책의 관할이거나, `s` 안의 다른 값에서 다시 만들 수 있거나,
상수면 상태가 아니다.**

🔴 **`fleet` 의 멤버십이 곧 "지금 위험에 노출된 로봇" 이다.** `simstate_of` 가
`_hz_excluded()`(주차 예비 ∪ 반출 예비 ∪ 고장)를 직접 불러서 뺀다. 그래서 경량 레인과 무거운
레인이 **구성상 같은 집합** 위에서 위험을 적분한다(spec §2-4). 죽은 로봇은 태그가 아니라
**부재**로 표현된다 — `health` 필드를 되살리지 말 것.

⚠️ `SwapBattery` 는 결정 직후 `s` 에 흔적을 남기지 않는다(배송은 `env.BATTERY_DELIVERIES[]`
에 산다). **트리 노드를 `state_hash` 로 병합하는 소비처가 생기면 그 순간 SwapBattery 자식이
NOOP 자식과 합쳐진다** — spec §2-5 의 트립와이어."""
@kwdef struct SimState
    g::GraphBlock
    geo::GeoBlock
    fleet::Dict{Int,RobotRec}
    prog::ProgBlock
end
```

`CourierRec` 의 struct 정의와 그 docstring 을 **삭제**한다.

- [ ] **Step 4: 정준 직렬화를 갱신한다**

`canonical` 메서드 다섯을 다음으로 교체하고 `CourierRec` 메서드를 삭제한다:

```julia
canonical(b::GraphBlock) = "G(edges=$(_c(b.edges)),bind=$(_c(b.binding)))"

canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),zones=$(_c(b.zones)))"

canonical(r::RobotRec) = "(soc=$(_c(r.soc)),usage=$(_c(r.usage_s)))"

canonical(b::ProgBlock) = "Prog(closed=$(_c(b.closed)))"
```

`_BLOCK_NAMES` 와 `_canonical_blocks` 를 교체한다:

```julia
const _BLOCK_NAMES = Set([:g, :geo, :fleet, :prog])

_canonical_blocks(s::SimState) = (
    :g     => canonical(s.g),
    :geo   => canonical(s.geo),
    :fleet => "Fleet=" * _c(s.fleet),
    :prog  => canonical(s.prog),
)
```

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_simstate_fields.jl`
Expected: PASS (19 tests)

- [ ] **Step 6: 기존 smdp 시험의 회귀를 확인한다**

Run:
```bash
julia +lts --project=. test/smdp_simstate_smoke.jl
julia +lts --project=. test/smdp_crn_smoke.jl
julia +lts --project=. test/smdp_stamp_smoke.jl
julia +lts --project=. test/smdp_global_inventory.jl
julia +lts --project=. test/smdp_clock_smoke.jl
```
Expected: `smdp_simstate_smoke.jl` 는 **깨진다**(옛 필드를 쓴다) — 이 태스크에서 같이 고친다. 나머지 넷은 PASS.

`smdp_simstate_smoke.jl` 에서 옛 필드를 참조하는 자리를 새 생성자로 바꾼다. 🔴 **필드를 참조하던 단언을 지우지 말고 새 필드에 대한 단언으로 옮긴다** — 지우면 커버리지가 조용히 준다.

- [ ] **Step 7: 커밋**

```bash
git add src/smdp/simstate.jl test/smdp_simstate_fields.jl test/smdp_simstate_smoke.jl
git commit -m "feat(smdp): reduce s from 26 to 7 fields -- membership replaces role and health"
```

---

## Task R2: `simstate_of` 축소 + 게이트 N-G0′ — **3시간**

**Files:**
- Modify: `src/smdp/observe.jl`
- Test: `test/smdp_observe_gate.jl` (전면 재작성, = N-G0′)

**Interfaces:**
- Consumes: `PlannerEnv`(`sched`·`scene_tree`·`cache`), `CB.BATTERY_FLEET[]`, `CB.HAZARD_STATE[]`, `CB.RESTRICTION_ZONES[]`, `CB._hz_excluded()`, Task R1 의 블록 생성자
- Produces: `simstate_of(env)::SimState` — **읽기 전용**. env 를 절대 수정하지 않는다
- 🔴 **삭제**: `_role_of` · `_sched_roles` · `_payload_of` · `_courier_recs` · `_build_delta`
- 유지: `_int_key`

- [ ] **Step 1: 게이트 시험을 쓴다**

```julia
# test/smdp_observe_gate.jl   —  게이트 N-G0′
# simstate_of(env) 가 실제 env 를 충실히 읽는가. 방법은 **음성 대조**다: env 를 한 군데씩
# 흔들고 해시가 갈리는지 본다. 안 갈리는 필드는 그 자리에서 두 세계를 조용히 합친다.
#   julia +lts --project=. test/smdp_observe_gate.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

# colored_8x8.ldr = 33부품 x 1층, 실측 ~4초. 가장 싼 실제 씬.
# ⚠️ 확장자는 .ldr 이다(.mpd 가 아니다 — 선행 계획의 오류 P4).
# ⚠️ `rendering`·`process_animation_tasks` 는 kwarg 가 아니다(선행 계획의 오류 P5).
env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng0",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
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
    @test CB.state_hash(s) == CB.state_hash(CB.simstate_of(env))
end

@testset "N-G0′ 필드 민감도 — env 를 흔들면 해시가 갈린다" begin
    h0  = CB.state_hash(CB.simstate_of(env))
    rid = first(sort!(collect(keys(CB.BATTERY_FLEET[].soc)); by = string))

    old = CB.BATTERY_FLEET[].soc[rid]
    CB.BATTERY_FLEET[].soc[rid] = old - 0.1
    @test CB.state_hash(CB.simstate_of(env)) != h0
    CB.BATTERY_FLEET[].soc[rid] = old
    @test CB.state_hash(CB.simstate_of(env)) == h0        # 복원하면 되돌아온다

    st   = CB.HAZARD_STATE[]
    oldu = st.usage_s[rid]; st.usage_s[rid] = oldu + 5.0
    @test CB.state_hash(CB.simstate_of(env)) != h0
    st.usage_s[rid] = oldu

    # zone 기하 — 이름이 아니라 반지름만 바꾼다
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 1.0)
    h1 = CB.state_hash(CB.simstate_of(env))
    @test h1 != h0
    CB.RESTRICTION_ZONES[][:ng0probe] = CB.LazySets.Ball2([0.0, 0.0], 2.0)
    @test CB.state_hash(CB.simstate_of(env)) != h1        # 🔴 반지름만 달라도 갈려야 한다
    delete!(CB.RESTRICTION_ZONES[], :ng0probe)
    @test CB.state_hash(CB.simstate_of(env)) == h0
end

@testset "🔴 멤버십이 _hz_excluded 와 정확히 일치한다 (spec §2-4)" begin
    s  = CB.simstate_of(env)
    ex = CB._hz_excluded()
    all_ids = collect(keys(CB.BATTERY_FLEET[].soc))
    expect  = Set(CB._int_key(r) for r in all_ids if !(r in ex))
    @test Set(keys(s.fleet)) == expect
    # 음성 대조: 하나를 제외 집합에 넣으면 fleet 에서 빠져야 한다
    victim = first(sort!(collect(expect)))
    vid    = first(r for r in all_ids if CB._int_key(r) == victim)
    push!(CB.CHECKED_OUT_SPARES[], vid)
    @test !(victim in keys(CB.simstate_of(env).fleet))
    delete!(CB.CHECKED_OUT_SPARES[], vid)
    @test victim in keys(CB.simstate_of(env).fleet)
end

@testset "🔴 시계·배송·역할이 s 에 없다 (음성 대조)" begin
    s0 = CB.simstate_of(env)
    CB.set_sim_step!(2)
    @test CB.state_hash(CB.simstate_of(env)) == CB.state_hash(s0)   # t 가 없다
    CB.set_sim_step!(1)
    @test !hasproperty(s0.prog, :t)
    @test !hasproperty(s0.prog, :active)
    @test !hasproperty(s0, :courier)
    @test !hasproperty(first(values(s0.fleet)), :role)
    @test !hasproperty(first(values(s0.fleet)), :mode)
end

@testset "진행 상태가 실제 캐시를 반영한다" begin
    s = CB.simstate_of(env)
    @test s.prog.closed == Set(env.cache.closed_set)
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_observe_gate.jl`
Expected: FAIL — `simstate_of` 가 아직 옛 블록을 만든다(`UndefKeywordError` 또는 `MethodError`)

- [ ] **Step 3: `simstate_of` 를 축소한다**

`src/smdp/observe.jl` 의 본문을 다음으로 교체한다:

```julia
"""
    simstate_of(env) -> SimState

현재 `env`(+ 배터리·hazard 전역)에서 `s` 를 읽는다. **읽기 전용.**

계약 셋(어기면 롤아웃이 조용히 틀린다):
  (1) env·전역을 하나도 수정하지 않는다.
  (2) 새 값을 계산하지 않는다 — 엔진이 이미 들고 있는 값을 옮길 뿐이다.
  (3) 🔴 **`fleet` 멤버십은 `_hz_excluded()` 를 직접 부른다.** 여기서 role·health 로 다시
      유도하면 두 레인이 서로 다른 집합 위에서 위험을 적분한다(spec §2-4, 완료 보고서 §4-2 가
      반례 둘을 실측했다).
"""
function simstate_of(env)
    sched, cache = env.sched, env.cache
    fleet_b = BATTERY_FLEET[]
    fleet_b === nothing && error("simstate_of: BATTERY_FLEET[] 가 비어 있다 — " *
                                 "enable_battery!(env) 를 먼저 부를 것")
    st = HAZARD_STATE[]
    st === nothing && error("simstate_of: HAZARD_STATE[] 가 비어 있다 — " *
                            "enable_hazard!(env) 없이는 usage_s 가 전부 0 이라 λ 가 평평해진다 " *
                            "(이슈 E). 조용히 0 을 채우지 않는다")

    # --- G ---------------------------------------------------------------------------
    edges = Set{Tuple{Int,Int}}()
    for e in Graphs.edges(sched)
        push!(edges, (Graphs.src(e), Graphs.dst(e)))
    end
    binding = Dict{Int,Int}()
    for v in Graphs.vertices(sched)
        rs = try _responsible_robots(get_node(sched, v).node) catch; () end
        isempty(rs) && continue
        # ⚠️ `_responsible_robots` 는 **정렬돼 있지 않다**(Dict 순회 순서 — 선행 계획의 오류 P2).
        # 정렬 첫째를 쓴다. 안 하면 같은 세계가 프로세스마다 다른 binding 을 얻는다.
        binding[v] = _int_key(first(sort!(collect(rs); by = string)))
    end
    g = GraphBlock(edges = edges, binding = binding)

    # --- Geo: 조립체 기하 + zone(중심·반지름까지) --------------------------------------
    poses = Dict{Int,NTuple{3,Float64}}()
    for n in get_nodes(env.scene_tree)
        matches_template(AssemblyNode, n) || continue
        tr = global_transform(n).translation
        poses[_int_key(node_id(n))] = (Float64(tr[1]), Float64(tr[2]), Float64(tr[3]))
    end
    zones = Dict{Symbol,NTuple{3,Float64}}()
    for (k, ball) in RESTRICTION_ZONES[]
        zones[k] = (Float64(ball.center[1]), Float64(ball.center[2]), Float64(ball.radius))
    end
    geo = GeoBlock(poses = poses, zones = zones)

    # --- Fleet: 멤버십 = 위험에 노출된 로봇, 레코드는 두 필드 --------------------------
    excluded = _hz_excluded()
    fleet = Dict{Int,RobotRec}()
    for rid in sort!(collect(keys(fleet_b.soc)); by = string)
        rid in excluded && continue
        haskey(st.usage_s, rid) ||
            error("simstate_of: $(rid) 가 hazard 상태에 없다 — usage_s 를 지어내지 않는다")
        fleet[_int_key(rid)] = RobotRec(soc     = Float64(fleet_b.soc[rid]),
                                        usage_s = Float64(st.usage_s[rid]))
    end

    return SimState(g = g, geo = geo, fleet = fleet,
                    prog = ProgBlock(closed = Set{Int}(collect(cache.closed_set))))
end
```

`_role_of` · `_sched_roles` · `_payload_of` · `_courier_recs` · `_build_delta` 의 정의와 docstring 을 **삭제**한다. `_int_key` 는 그대로 둔다.

- [ ] **Step 4: 게이트를 돌린다**

Run: `julia +lts --project=. test/smdp_observe_gate.jl`
Expected: PASS. **하나라도 실패하면 그 필드는 `s` 가 못 보는 것이고, 실패를 통과로 바꾸기 전에 왜 안 보이는지 먼저 적는다.**

⚠️ `AssemblyNode` · `CHECKED_OUT_SPARES` 의 실제 이름을 구현 시 확인한다:
`grep -rn "matches_template(AssemblyNode\|CHECKED_OUT_SPARES" src/ | head`. 다르면 **그 이름을 쓰고 이 계획의 오류로 보고**한다.

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/observe.jl test/smdp_observe_gate.jl
git commit -m "feat(smdp): simstate_of reads the 7-field state; fleet membership is _hz_excluded"
```

---

## Task R3: 축소 근거 3건 실측 — **2시간** (+ 실행 대기 ~15분)

spec §2-3 이 세 명제를 세웠다. 둘은 실측 근거가 있고 하나는 **손실을 감수한 것**이다. 그 손실 크기와 남은 유도 가능성을 **재고 넘어간다.** 재지 않으면 다음 세대가 근거 없이 되돌린다.

**Files:**
- Create: `tools/monitor/measure_reduction_evidence.jl`
- Create: `results/smdp/reduction_evidence.json` (산출물)

**Interfaces:**
- Consumes: `simstate_of`(R2), `CB.DISSOLVED_GATES[]`, `CB.WEDGE_EDGES[]`
- Produces: `results/smdp/reduction_evidence.json` —
  `{"dissolved_nonempty_frac": …, "binding_derivable": …, "active_is_frontier": …, "wedge_subset_of_edges": …, "n_steps": …}`

- [ ] **Step 1: 측정 스크립트를 쓴다**

```julia
# tools/monitor/measure_reduction_evidence.jl
# spec §2-3 의 세 명제를 **실측한다**. 추정하지 않는다.
#   (a) dissolved_gates 가 비어 있지 않은 스텝의 비율  — 손실 압축의 크기
#   (b) binding 이 edges 에서 유도되는가              — 유도되면 다음 세대에서 뺀다
#   (c) active == frontier(closed, edges)             — active 를 뺀 근거의 재확인
#   (d) wedge_edges ⊆ edges                           — wedge 를 뺀 근거의 재확인
#   julia +lts --project=. tools/monitor/measure_reduction_evidence.jl
using ConstructionBots, JSON3
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "redevid",
                         num_robots = 12, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 3)

"frontier(closed, edges) — essential_tg_coponents.jl:1921-1932 의 활성화 규칙 그대로."
function frontier(closed, edges, verts)
    preds = Dict(v => Int[] for v in verts)
    for (u, v) in edges; push!(preds[v], u); end
    return Set(v for v in verts if !(v in closed) && all(u -> u in closed, preds[v]))
end

N = 400
n_dissolved, n_binding_ok, n_frontier_ok, n_wedge_ok = 0, 0, 0, 0
for k in 1:N
    CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0)
    s     = CB.simstate_of(env)
    verts = collect(CB.Graphs.vertices(env.sched))

    isempty(CB.DISSOLVED_GATES[]) || (n_dissolved += 1)

    # (c) active 가 frontier 인가
    frontier(s.prog.closed, s.g.edges, verts) == Set(env.cache.active_set) && (n_frontier_ok += 1)

    # (d) wedge_edges ⊆ edges 인가
    all(e -> e in s.g.edges, CB.WEDGE_EDGES[]) && (n_wedge_ok += 1)

    # (b) binding 이 edges 만으로 재구성되는가.
    #     정점 v 의 담당 로봇을, v 로 들어오는 엣지의 출발점 중 로봇 정점인 것으로 유도해 본다.
    derived = Dict{Int,Int}()
    for (u, v) in s.g.edges
        haskey(s.g.binding, u) && !haskey(derived, v) && (derived[v] = s.g.binding[u])
    end
    all(k2 -> get(derived, k2, nothing) == s.g.binding[k2],
        collect(keys(s.g.binding))) && (n_binding_ok += 1)
end

out = Dict("n_steps" => N,
           "dissolved_nonempty_frac" => n_dissolved / N,
           "binding_derivable_frac"  => n_binding_ok / N,
           "active_is_frontier_frac" => n_frontier_ok / N,
           "wedge_subset_frac"       => n_wedge_ok / N)
mkpath(joinpath(pkgdir(CB), "results", "smdp"))
open(joinpath(pkgdir(CB), "results", "smdp", "reduction_evidence.json"), "w") do io
    JSON3.pretty(io, out)
end
println(JSON3.write(out))
```

- [ ] **Step 2: 돌린다**

Run: `julia +lts --project=. tools/monitor/measure_reduction_evidence.jl`
Expected: JSON 한 줄.

- [ ] **Step 3: 판정을 spec §2-3 · §10 에 적는다**

| 측정 | 값 | 무엇을 한다 |
|---|---|---|
| `active_is_frontier_frac` | `< 1.0` | 🔴 **여기서 멈춘다.** `active` 를 뺀 근거가 거짓이다 — Task T8 의 rate boundary 가 틀린 집합 위에 선다. spec §2-3 (a) 를 정정하고 사용자에게 올린다 |
| `wedge_subset_frac` | `< 1.0` | 🔴 같은 이유로 멈춘다. spec §2-3 (b) 를 정정한다 |
| `dissolved_nonempty_frac` | 값 그대로 | spec §2-3 (c) 에 **실측값으로** 기록한다. `> 0.05` 면 손실이 실재하므로 §10 미해결에 그 수를 적는다 |
| `binding_derivable_frac` | `== 1.0` | spec §10 미해결 4번을 닫고 **다음 세대에서 `binding` 을 뺀다**(이 세대에서는 빼지 않는다 — 축소를 두 번 하면 회귀 원인이 안 갈린다) |

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/measure_reduction_evidence.jl results/smdp/reduction_evidence.json \
        docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md
git commit -m "measure(smdp): the three reduction claims, measured rather than asserted"
```

---

## Task R4: 갈래 비용 재측정 — **1시간** (+ 재컴파일 대기 ~10분)

`s` 가 26 → 7 필드가 됐으므로 `simstate_of` 비용이 바뀐다. MCTS 예산이 여기서 나온다.

**Files:**
- Modify: `tools/monitor/measure_branch_cost.jl`
- Modify: `results/smdp/branch_cost.json` (재생성)

**Interfaces:**
- Consumes: `simstate_of`(R2)
- Produces: `results/smdp/branch_cost.json` — `{"deepcopy_ms": …, "simstate_of_ms": …, "n": …}`

- [ ] **Step 1: 스크립트의 씬 인자를 고치고 축소 전 값을 기록한다**

기존 `results/smdp/branch_cost.json` 의 값을 적어 둔다 (완료 보고서 실측: `deepcopy` 중앙 **19.17 ms**, `simstate_of` 중앙 **17.59 ms**).

- [ ] **Step 2: 돌린다**

Run: `julia +lts --project=. tools/monitor/measure_branch_cost.jl`
Expected: JSON 한 줄. `simstate_of_ms.median` 이 **17.59 보다 작아야 한다** — 안 작으면 축소가 비용을 안 줄인 것이고, 그 사실 자체가 결과다(비용을 지배하는 것이 필드 수가 아니라 씬 순회라는 뜻).

- [ ] **Step 3: 판정을 적는다**

`deepcopy_ms.median` 기준:

- `< 5` → 갈래를 마음껏 만들어도 된다
- `5 ≤ … < 50` → 롤아웃당 갈래 1회로 제한한다(트리 노드마다가 아니라)
- `≥ 50` → **spec §5-1 의 1단계를 다시 설계해야 한다.** 이 계획을 여기서 **멈춘다**

🔴 **이 값은 하한이다.** 3계층 중 `deepcopy` 가 격리하는 것은 둘뿐이고 **RVO2 는 프로세스 전역**(`RVO_SIM_WRAPPER`)이라 격리되지 않는다. 진짜 갈래 비용 = `deepcopy + rvo_rebuild!` 이고 후자는 Task T11 전까지 못 잰다. **Task T12 가 이 값을 전부로 알고 예산을 짜면 모자란다.**

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/measure_branch_cost.jl results/smdp/branch_cost.json
git commit -m "measure(smdp): re-measure branch cost after the state reduction"
```

---

# Phase 2 — τ 의 두 성분

## Task T6: hazard 손잡이 셋 + λ 의 단일 진실원 — **2시간**

D-3 · D-4 는 선행 spec 에서 왔고 **D-5 가 신규**다. 셋 다 동역학을 가르므로 `generation` 을 함께 올린다.

**Files:**
- Modify: `src/smdp/hazard.jl` (`HazardParams` 기본값 셋 + 파일 끝의 새 진입점)
- Modify: `wm4spacecraft_manufacturing/core/objective.json` (`generation`)
- Test: `test/smdp_hazard_knobs.jl` (신규)

**Interfaces:**
- Produces: `hazard_rate_from(p::HazardParams, usage_s::Float64, soc::Float64, mode::Symbol) -> Float64` — **두 레인이 공유하는 λ 의 단일 진실원**

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_hazard_knobs.jl
# (1) 손잡이 셋이 spec 의 D-3 · D-4 · D-5 대로인가.
# (2) λ 의 단일 진실원 — 무거운 레인(hazard_rate)과 경량 레인(hazard_rate_from)이 **같은 수**를
#     내는가. 갈리면 롤아웃이 다른 세계를 탐색한다.
#   julia +lts --project=. test/smdp_hazard_knobs.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "D-3 · D-4 · D-5 기본값" begin
    p = CB.HazardParams()
    @test p.fire_require_spare == false          # D-3
    @test isfinite(p.mtbf_zone_s)                # D-4 — Inf 면 zone 이 영원히 안 온다
    @test p.drain_sigma == 0.0                   # D-5 — eff 를 s 에서 빼려면 먼저 없애야 한다
    @test p.drain_step_cv == 0.0                 # 유지
    @test p.fire_safe_target == true             # 바꾸지 않는다
end

@testset "🔴 D-5 의 음성 대조 — eff 가 진짜로 상수 1.0 이다" begin
    st = CB._new_hazard_state(CB.HazardParams(), 8)
    for i in 1:8; CB._hz_ensure!(st, i); end
    @test all(v -> v == 1.0, values(st.eff))
    # σ 를 되살리면 갈린다 — 이 시험이 D-5 를 되돌리는 변경을 잡는다
    st2 = CB._new_hazard_state(CB.HazardParams(drain_sigma = 0.15), 8)
    for i in 1:8; CB._hz_ensure!(st2, i); end
    @test !all(v -> v == 1.0, values(st2.eff))
end

@testset "λ 의 단일 진실원" begin
    st = CB._new_hazard_state(CB.HazardParams(), 3)
    CB._hz_ensure!(st, 1)
    st.usage_s[1] = 240.0
    for mode in (:idle, :transit, :carry, :manip), soc in (1.0, 0.6, 0.05)
        heavy = CB.hazard_rate(st, 1; mode = mode, soc = soc)
        light = CB.hazard_rate_from(st.params, 240.0, soc, mode)
        @test heavy == light          # 근사가 아니라 **정확히** 같아야 한다
    end
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_hazard_knobs.jl`
Expected: FAIL — `fire_require_spare == true`, `mtbf_zone_s == Inf`, `drain_sigma == 0.15`, `hazard_rate_from` 미정의

- [ ] **Step 3: 기본값 셋을 바꾼다**

`src/smdp/hazard.jl` 의 `HazardParams` 에서 세 줄을 교체한다:

```julia
    mtbf_zone_s::Float64    = 1800.0   # D-4 (2026-08-20): 유한값으로 켠다. 기본이 Inf 였던 탓에
                                       # 커밋된 전 런에서 n_zone = 0 이었다(실측) — zone 이 사건
                                       # 종류로 선언돼 있는데 한 번도 도착하지 않는 상태였다.
                                       # ⚠️ **미교정 초기값**이다. Task C8(N-G3)이 교정한다.

    fire_require_spare::Bool= false    # D-3 (2026-08-20, 근거는 2026-08-21 에 교체): 예비와
                                       # 무관하게 발화한다. 이제 예비는 충분하다고 **가정**하므로
                                       # (D-7) 이 손잡이가 막는 것은 "예비 소진 시 음소거" 가
                                       # 아니라 **그 가정이 깨졌을 때 조용히 음소거되는 것**이다.
                                       # true 로 되돌리면 가정 위반이 에러가 아니라 침묵이 된다.

    drain_sigma::Float64    = 0.0      # D-5 (2026-08-21): ε_r 개체차를 **동역학에서 없앤다.**
                                       # 0.15 였을 때는 로봇마다 방전 효율이 달랐고, 그 값을 s 에서
                                       # 빼면 모델이 잠재변수 혼합이 되어 s 에서 Markov 가 아니었다.
                                       # 0 으로 두면 eff ≡ 1.0 이라 s 에서 빠지는 것이 공짜다.
                                       # ⚠️ 되살리려면 RobotRec 에 eff 를 **같은 커밋에서** 넣을 것.
```

- [ ] **Step 4: λ 를 단일 진실원으로 접는다**

`hazard_rate` 의 본문을 새 순수 함수로 옮기고 기존 함수는 래퍼로 만든다:

```julia
"""
    hazard_rate_from(p::HazardParams, usage_s, soc, mode) -> Float64

λ 의 **단일 진실원**. 무거운 레인(`hazard_rate`)과 경량 레인(`rates.jl`)이 둘 다 이것을 부른다.
인자가 전부 `s` 에서 나온다는 것이 spec §2-6 의 요점이다 — `usage_s`·`soc` 는 `RobotRec` 의
두 필드이고 `mode` 는 `derive.jl` 의 `mode_of` 가 낸다.
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

- [ ] **Step 4b: 🔴 라벨 레인의 독립 기본값을 같이 고친다**

실측: `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl:150` 이

```julia
    drain_sigma  = parse(Float64, get(ENV, "DS_DRAIN_SIGMA", "0.15")),
```

로 **`HazardParams` 와 무관하게 0.15 를 자기 기본값으로 들고 있다.** `hazard.jl` 만 고치면
**실행 레인은 D-5 세계인데 라벨 레인은 옛 세계**가 된다 — 이 레포가 이미 데인 실패 모양이다
(`DS_HOTSWAP` 하나 빠뜨려 `fault` 발화율이 100% → 23% 로 조용히 샜다).

그 줄의 기본값을 `"0.0"` 으로 바꾸고, **두 레인이 같은 값을 쓰는지 단언**을 시험에 추가한다:

```julia
@testset "🔴 라벨 레인이 실행 레인과 같은 세계다" begin
    src = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle",
                        "gen_oracle_dataset.jl"), String)
    @test occursin("\"DS_DRAIN_SIGMA\", \"0.0\"", replace(src, " " => ""))
    @test CB.HazardParams().drain_sigma == 0.0
end
```

⚠️ 같은 방식으로 독립 기본값을 든 `DS_*` 손잡이가 더 있는지 확인한다:
`grep -n 'get(ENV, "DS_' wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl | head -40`.
`HazardParams`/`BatteryParams` 와 이름이 겹치는 것은 전부 대조한다.

- [ ] **Step 5: `generation` 을 올린다**

`wm4spacecraft_manufacturing/core/objective.json` 의 `"generation"` 을
`"2026-08-21-reduced-state-sojourn-drainsigma0"` 로 바꾼다. **다른 스칼라는 건드리지 않는다.**

Run:
```bash
python3 -c "import sys; sys.path.insert(0,'wm4spacecraft_manufacturing/core'); \
import objective as O; c=O.load(); print(c['generation'], O.objective_hash(c))"
```
Expected: 새 generation 과, **이전과 다른** 해시.

- [ ] **Step 6: 통과 + 회귀 확인**

Run:
```bash
julia +lts --project=. test/smdp_hazard_knobs.jl
julia +lts --project=. test/smdp_crn_smoke.jl
julia +lts --project=. test/smdp_stamp_smoke.jl
```
Expected: 셋 다 PASS. `smdp_stamp_smoke.jl` 이 옛 generation 을 못박고 있으면 새 값으로 고친다.

- [ ] **Step 7: 커밋**

```bash
git add src/smdp/hazard.jl test/smdp_hazard_knobs.jl \
        wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl \
        wm4spacecraft_manufacturing/core/objective.json test/smdp_stamp_smoke.jl
git commit -m "feat(hazard): spare-independent firing, finite zone mtbf, deterministic drain (D-3/4/5)"
```

---

## Task T7: `derive.jl` + `rates.jl` — **3시간**

`mode` 를 상태에서 뺐으므로 파생 접근자가 먼저 필요하고, 그 위에 spec §2 의 닫힌 형태가 선다.

**Files:**
- Create: `src/smdp/derive.jl`
- Create: `src/smdp/rates.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_derive.jl`, `test/smdp_rates.jl` (둘 다 신규)

**Interfaces:**
- Consumes: `hazard_rate_from`(T6), `SimState`·`RobotRec`(R1)
- Produces:
  - `active_of(s::SimState) -> Set{Int}`
  - `mode_of(s::SimState, env, k::Int) -> Symbol` — `:idle | :transit | :carry | :manip`
  - `mode_power_W(p::BatteryParams, mode::Symbol) -> Float64`
  - `rate_params_one(p::HazardParams, rec::RobotRec, mode::Symbol, bp, capacity_J) -> NTuple{2,Float64}`
  - `rate_params(s::SimState, env, p::HazardParams, bp, capacity_J) -> Dict{Int,NTuple{2,Float64}}`
  - `integrated_hazard(A, a, Δ) -> Float64`
  - `inv_integrated_hazard(A, a, E) -> Float64` — 발화하지 않으면 `Inf`

- [ ] **Step 1: 실패하는 시험 둘을 쓴다**

```julia
# test/smdp_derive.jl
# active_of / mode_of 가 엔진의 값과 **같은가**. 다르면 경량 레인과 무거운 레인이 서로 다른
# 로봇을 서로 다른 모드로 굴린다 — 에러 없이 λ 만 갈린다.
#   julia +lts --project=. test/smdp_derive.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "derive",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 5)

@testset "active_of == 엔진의 active_set (40 스텝 내내)" begin
    for k in 1:40
        CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0)
        s = CB.simstate_of(env)
        @test CB.active_of(s) == Set(env.cache.active_set)
    end
end

@testset "mode_of == _hz_modes (같은 분류기)" begin
    s     = CB.simstate_of(env)
    heavy = CB._hz_modes(env)
    for (k, _) in s.fleet
        rid = first(r for r in keys(CB.BATTERY_FLEET[].soc) if CB._int_key(r) == k)
        @test CB.mode_of(s, env, k) === get(heavy, rid, :idle)
    end
end

@testset "🔴 음성 대조 — mode_of 가 상수가 아니다" begin
    # `f(x) == f(x)` 로는 아무것도 못 잡는다(이 브랜치가 실제로 데인 함정). 활성 집합을 비우면
    # 전부 :idle 이 되어야 한다 — 안 되면 mode_of 가 s 를 안 보고 있다.
    s  = CB.simstate_of(env)
    s0 = CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet,
                     prog = CB.ProgBlock(closed = Set(1:CB.Graphs.nv(env.sched))))
    @test all(k -> CB.mode_of(s0, env, k) === :idle, keys(s0.fleet))
end
```

```julia
# test/smdp_rates.jl
# spec §2-2 의 닫힌 형태가 **정말 맞는지** 수치 적분과 직접 대조한다. 이 파일은 씬도 엔진도
# 안 쓴다 — (A, a) 를 직접 넣기 때문이다.
#   julia +lts --project=. test/smdp_rates.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

function numeric_integral(A, a, Δ; n = 200_000)     # 사다리꼴 — 닫힌 형태의 독립 대조군
    h = Δ / n
    s = 0.5 * (A * exp(a * 0.0) + A * exp(a * Δ))
    for i in 1:(n - 1); s += A * exp(a * i * h); end
    return s * h
end

@testset "integrated_hazard == 수치적분" begin
    for (A, a, Δ) in ((1e-3, 2e-4, 60.0), (5e-4, -3e-4, 120.0),
                      (2e-3, 0.0, 30.0), (1e-3, 1e-6, 900.0))
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
    total = -A / a                        # lim_{Δ→∞} (A/a)(e^{aΔ}−1) = −A/a
    @test CB.inv_integrated_hazard(A, a, total * 0.99) < Inf
    @test CB.inv_integrated_hazard(A, a, total * 1.01) == Inf   # 🔴 음수를 내면 안 된다
    @test CB.inv_integrated_hazard(A, a, total)        == Inf   # 경계는 안전한 쪽으로
end

@testset "a→0 극한이 매끄럽다" begin
    A = 1e-3
    @test CB.integrated_hazard(A, 0.0, 50.0) ≈ A * 50.0
    @test CB.integrated_hazard(A, 1e-14, 50.0) ≈ A * 50.0 rtol = 1e-9
    @test CB.inv_integrated_hazard(A, 0.0, A * 50.0) ≈ 50.0
    @test CB.inv_integrated_hazard(A, 1e-14, A * 50.0) ≈ 50.0 rtol = 1e-9
end

@testset "rate_params_one 의 A 는 t=0 의 λ 와 같다" begin
    p   = CB.HazardParams()
    bp  = CB.BatteryParams()
    rec = CB.RobotRec(soc = 0.7, usage_s = 300.0)
    A, a = CB.rate_params_one(p, rec, :carry, bp, bp.capacity_J)
    @test A == CB.hazard_rate_from(p, 300.0, 0.7, :carry)
    @test a > 0                            # :carry 는 usage 도 늘고 soc 도 준다 → λ 가 는다
    idle = CB.RobotRec(soc = 1.0, usage_s = 0.0)
    Ai, ai = CB.rate_params_one(p, idle, :idle, bp, bp.capacity_J)
    @test ai ≈ p.beta_soc * CB.mode_power_W(bp, :idle) / bp.capacity_J
    #  🔴 대기도 idle_W 를 먹는다 — a == 0 이라고 단정하지 않는다(실측 battery.jl:244)
end
```

- [ ] **Step 2: 실패를 확인한다**

Run:
```bash
julia +lts --project=. test/smdp_derive.jl
julia +lts --project=. test/smdp_rates.jl
```
Expected: 둘 다 FAIL — `UndefVarError: active_of not defined` · `integrated_hazard not defined`

- [ ] **Step 3: `derive.jl` 을 구현한다**

```julia
# =============================================================================
# derive.jl — `s` 의 **파생 접근자**. 상태에서 뺀 값을 필요할 때 다시 만든다(spec §2-6).
#
# 🔴 여기서 새 분류 규칙을 만들지 않는다. `mode_of` 는 hazard 의 `_node_mode` 를 재사용한다 —
#    다시 분류하면 경량 레인과 무거운 레인의 λ 가 갈린다.
# =============================================================================

"""
    active_of(s::SimState) -> Set{Int}

지금 진행 중인 스케줄 정점 = **모든 선행이 닫혔고 자신은 안 닫힌 정점**.
실측 근거: `essential_tg_coponents.jl:1921-1932` 의 활성화 규칙이 정확히 이것이다.
Task R3 가 400 스텝에서 엔진의 `cache.active_set` 과 동등함을 확인한다.
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

"""
    mode_of(s::SimState, env, k::Int) -> Symbol

로봇 `k`(= `s.fleet` 의 키)의 전력·위험 모드. 한 로봇이 여러 활성 노드에 걸리면 **더 무거운
모드**를 채택한다(운반 > 조작 > 이동) — `_hz_modes` 와 같은 순위다.
"""
function mode_of(s::SimState, env, k::Int)
    rank(m) = m === :carry ? 3 : m === :manip ? 2 : m === :transit ? 1 : 0
    best = :idle
    for v in active_of(s)
        get(s.g.binding, v, nothing) == k || continue
        node = try get_node(env.sched, v).node catch; nothing end
        node === nothing && continue
        m = _node_mode(node)
        m == IDLE && continue
        sym = m == TRANSIT ? :transit : (m == CARRY ? :carry : :manip)
        rank(sym) > rank(best) && (best = sym)
    end
    return best
end
```

- [ ] **Step 4: `rates.jl` 을 구현한다**

```julia
# =============================================================================
# rates.jl — spec §2 의 닫힌 형태. **부작용 없는 순수 수학.**
#
# 모드가 상수인 구간에서 usage 와 soc 가 t 에 선형이므로 λ 가 지수형이 된다:
#     λ_r(t) = A_r · exp(a_r · t)
#     A_r = hazard_rate_from(p, usage_r, soc_r, mode_r)        (t = 0 의 값)
#     a_r = β_u/U · 1[mode ≠ :idle]  +  β_s · P(mode) / C      (D-5 로 ε_r ≡ 1)
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
    mode_power_W(p::BatteryParams, mode::Symbol) -> Float64

모드별 전력 [W]. **`battery.jl` 의 값을 그대로 읽는다** — 여기서 숫자를 다시 정의하면 soc
감소율과 에너지 회계가 갈린다. `:carry` 는 이동에 적재 질량이 얹히므로 `walk_W` 위에
`k_move·m_payload·v_ref` 를 더한다.
"""
function mode_power_W(p::BatteryParams, mode::Symbol)
    mode === :idle    && return p.idle_W
    mode === :transit && return p.walk_W
    mode === :manip   && return p.manip_W
    mode === :carry   && return p.walk_W + k_move(p) * p.m_robot * p.v_ref
    error("mode_power_W: 알 수 없는 모드 $(mode) — 조용히 idle 로 떨어뜨리지 않는다")
end

"""
    rate_params_one(p, rec::RobotRec, mode, bp::BatteryParams, capacity_J) -> (A, a)

로봇 하나의 `(A, a)`. `rec` 는 두 필드뿐이고 `mode` 는 `derive.jl` 이 낸다.
"""
function rate_params_one(p::HazardParams, rec::RobotRec, mode::Symbol,
                         bp::BatteryParams, capacity_J::Float64)
    A    = hazard_rate_from(p, rec.usage_s, rec.soc, mode)
    du   = (mode === :idle) ? 0.0 : (p.usage_scale_s > 0 ? 1.0 / p.usage_scale_s : 0.0)
    dsoc = capacity_J > 0 ? mode_power_W(bp, mode) / capacity_J : 0.0    # ε_r ≡ 1 (D-5)
    return (A, p.beta_usage * du + p.beta_soc * dsoc)
end

"""
    rate_params(s, env, p, bp, capacity_J) -> Dict{Int,NTuple{2,Float64}}

`s.fleet` **전부**를 담는다. 🔴 여기서 `role`/`health` 로 거르지 않는다 — 멤버십이 이미
`_hz_excluded()` 로 걸러져 있다(spec §2-4). 거르면 두 번 거르는 것이고, 그 둘이 어긋나면
게이트 N-G1 이 서로 다른 집합을 비교하게 된다.
"""
function rate_params(s::SimState, env, p::HazardParams,
                     bp::BatteryParams, capacity_J::Float64)
    out = Dict{Int,NTuple{2,Float64}}()
    for k in sort!(collect(keys(s.fleet)))
        out[k] = rate_params_one(p, s.fleet[k], mode_of(s, env, k), bp, capacity_J)
    end
    return out
end
```

⚠️ `BatteryParams` 의 실제 필드 이름을 구현 시 확인한다:
`grep -n "idle_W\|walk_W\|manip_W\|m_robot\|v_ref\|k_move" src/navigator/battery.jl`.
다르면 **그 이름을 쓰고 이 계획의 오류로 보고**한다.

- [ ] **Step 5: 로더에 등록한다**

`src/smdp/mdp.jl` 의 `include("observe.jl")` 다음에:

```julia
include("derive.jl")   # s 의 파생 접근자. simstate.jl(타입)·hazard.jl(_node_mode) 에 의존
include("rates.jl")    # spec §2 의 닫힌 형태. derive.jl·hazard.jl 에 의존
```

- [ ] **Step 6: 통과를 확인한다**

Run:
```bash
julia +lts --project=. test/smdp_derive.jl
julia +lts --project=. test/smdp_rates.jl
```
Expected: 둘 다 PASS

- [ ] **Step 7: 커밋**

```bash
git add src/smdp/derive.jl src/smdp/rates.jl src/smdp/mdp.jl \
        test/smdp_derive.jl test/smdp_rates.jl
git commit -m "feat(smdp): derived accessors for the fields we dropped, plus the closed-form hazard"
```

---

## Task T8: `tplan.jl` — rate boundary (D-6) — **2.5시간**

🔴 **선행 계획 Task 8 의 식을 버린다.** 그 식은 `rem = ρ·dur(v) − (t − t0(v))` 였는데 완료 보고서가 **활성 정점 15/15 가 `rem ≤ 0`** 임을 실측했다(`t0` 가 런 내내 0.0 에 붙박여서). ρ 로는 못 고친다 — 활성 정점의 **8/14 가 `min_duration == 0.0`** 이라 `ρ·0 − (t−t0) ≤ 0` 이 모든 ρ 에 대해 참이다.

**Files:**
- Create: `src/smdp/tplan.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_tplan.jl` (신규)

**Interfaces:**
- Consumes: `active_of`(T7), `env.sched`
- Produces:
  - `node_duration(env, v::Int) -> Float64` — ρ 보정 전 원값
  - `T_plan_next(s, env; rho = RHO[]) -> Float64` — 다음 모드 변화까지. 활성 노드가 없거나 전부 `dur == 0` 이면 `Inf`
  - `T_done(s, env; rho = RHO[]) -> Float64` — 남은 스케줄의 longest path
  - `RHO :: Ref{Float64}` — Task T10 이 채운다

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_tplan.jl
# T_plan_next 는 **결정 epoch 가 아니라 λ 의 구간상수 경계**다(spec §2-4). 재는 것은
# "다음에 모드가 바뀌는 순간이 언제인가" 뿐이다.
#
# 🔴 D-6: 경과시간을 빼지 않는다. `s` 에 시계가 없으므로 뺄 것도 없다. 상한 근사이고
#    그 편향은 N-G1 이 판정한다.
#   julia +lts --project=. test/smdp_tplan.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "tplan",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 5)
CB.step_environment!(env); CB.set_sim_step!(1); CB.update_planning_cache!(env, 0.0)

@testset "🔴 T_plan_next 는 언제나 양수다 (400 스텝 내내)" begin
    # 선행 설계가 죽은 자리가 정확히 여기다: eps 클램프로 1.8e-15 를 돌려주면
    # sample_sojourn 이 전진하지 못하고 n_boundary 상한에서 죽거나 시뮬 시간 0 초 만에
    # DAG 를 통과한다. 400 스텝 전수로 못박는다.
    for k in 1:400
        CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0)
        s = CB.simstate_of(env)
        Δ = CB.T_plan_next(s, env)
        @test Δ > 0.0
        @test !isnan(Δ)
        isempty(CB.active_of(s)) && @test Δ == Inf
    end
end

@testset "dur == 0 정점은 경계 후보에서 빠진다" begin
    s = CB.simstate_of(env)
    act = CB.active_of(s)
    durs = [CB.node_duration(env, v) for v in act]
    if any(d -> d == 0.0, durs) && any(d -> d > 0.0, durs)
        @test CB.T_plan_next(s, env) ≈ minimum(d for d in durs if d > 0.0)
    end
end

@testset "T_plan_next ≤ T_done" begin
    s = CB.simstate_of(env)
    @test CB.T_plan_next(s, env) <= CB.T_done(s, env) + 1e-9 || CB.T_done(s, env) == 0.0
end

@testset "ρ 는 선형 배수다" begin
    s = CB.simstate_of(env)
    a = CB.T_plan_next(s, env; rho = 1.0)
    isfinite(a) && @test CB.T_plan_next(s, env; rho = 2.0) ≈ 2.0 * a rtol = 1e-9
end

@testset "완주 상태에서 T_done = 0, T_plan_next = Inf" begin
    s  = CB.simstate_of(env)
    s2 = CB.SimState(g = s.g, geo = s.geo, fleet = s.fleet,
                     prog = CB.ProgBlock(closed = Set(1:CB.Graphs.nv(env.sched))))
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
# 🔴 D-6 (2026-08-21): 경과시간을 빼지 않는다. 선행 설계는
#        rem = ρ·dur(v) − (s.prog.t − t0(v))
#    를 썼는데, `get_t0` 는 **MILP 가 계획한 시작 시각**이고 레포의 호출자 7곳이 전부
#    `t = 0.0` 을 넘겨 `update_schedule_times!` 가 도달하지 않으므로 런 내내 0.0 에
#    붙박인다(실측: 40 스텝에 활성 14개 전부 t0 == 0.0). 그러면 rem 이 음수로 가고
#    T_plan_next 가 eps 를 돌려준다. ρ 로도 못 고친다 — 활성의 8/14 가 dur == 0 이라
#    `ρ·0 − Δ ≤ 0` 이 모든 ρ 에서 참이다.
#
#    그래서 `s` 에서 시계를 지우고 식을 **상한 근사**로 바꿨다. 그 편향은 N-G1 이 잰다.
#
# ⚠️ `min_duration = duration_lower_bound(node)` 는 **하한**이다. 실제 주행은 3계층 reactive
#    스택을 거치므로 더 길다. ρ 가 그 격차를 흡수하고, **경량 모델은 혼잡·교착을 원리적으로
#    볼 수 없다.**
# =============================================================================

const RHO = Ref(1.0)    # Task T10(N-G2)이 무거운 레인에서 적합해 채운다

"정점 v 의 계획 소요시간(ρ 보정 전)."
node_duration(env, v::Int) = Float64(get_min_duration(env.sched, v))

"""
    T_plan_next(s, env; rho = RHO[]) -> Float64

다음 모드 변화까지의 시간 = **활성 정점 중 가장 짧은 계획 소요시간**(ρ 보정).
`dur == 0` 인 정점은 후보에서 뺀다 — 0 을 돌려주면 `sample_sojourn` 이 전진하지 못한다.
활성이 없거나 전부 0 이면 `Inf`(= 이 구간에 모드 변화가 없다).
"""
function T_plan_next(s::SimState, env; rho::Float64 = RHO[])
    best = Inf
    for v in active_of(s)
        d = node_duration(env, v)
        d > 0.0 || continue
        rd = rho * d
        rd < best && (best = rd)
    end
    return best
end

"""
    T_done(s, env; rho = RHO[]) -> Float64

미완 스케줄 DAG 의 longest path — 아무것도 고장 나지 않으면 언제 끝나는가.
위상정렬 1회. 흡수상태(전부 닫힘)에서는 0.
진행 중 노드의 잔여 보정을 **하지 않는다** — D-6 과 같은 이유(시계가 없다).
"""
function T_done(s::SimState, env; rho::Float64 = RHO[])
    sched = env.sched
    any(v -> !(v in s.prog.closed), Graphs.vertices(sched)) || return 0.0
    finish = Dict{Int,Float64}()
    for v in Graphs.topological_sort_by_dfs(get_graph(sched))
        v in s.prog.closed && continue
        head = 0.0
        for u in Graphs.inneighbors(get_graph(sched), v)
            u in s.prog.closed && continue
            head = max(head, get(finish, u, 0.0))
        end
        finish[v] = head + rho * node_duration(env, v)
    end
    return isempty(finish) ? 0.0 : maximum(values(finish))
end
```

- [ ] **Step 4: 로더에 등록한다**

`src/smdp/mdp.jl` 에 `include("tplan.jl")` 를 `rates.jl` 다음에 추가한다.

- [ ] **Step 5: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_tplan.jl`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/tplan.jl src/smdp/mdp.jl test/smdp_tplan.jl
git commit -m "feat(smdp): rate boundary without a clock -- D-6 replaces the elapsed-time formula"
```

---

## Task T9: `sojourn.jl` + 게이트 N-G1 — **4시간**

이슈 C(역지도) · D(`cell` 경쟁위험) · E(hazard-off 가드)를 여기서 같이 닫는다.

**Files:**
- Create: `src/smdp/sojourn.jl`
- Modify: `src/smdp/derive.jl` (`robot_id_of`), `src/smdp/hazard.jl` (`cell_rate_from`)
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_sojourn.jl`, `tools/monitor/gen_ng1_pairs.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng1.py` (전부 신규)

**Interfaces:**
- Consumes: `rate_params`·`integrated_hazard`·`inv_integrated_hazard`(T7), `T_plan_next`·`T_done`(T8)
- Produces:
  - `robot_id_of(k::Int) -> RobotID` — 🔴 **이슈 C 의 해소.** `_int_key` 의 역지도
  - `cell_rate_from(p::HazardParams, usage_s::Float64, mode::Symbol) -> Float64` — 🔴 **이슈 D**
  - `sample_sojourn(s, env, p, bp, rng; delta_max = Inf) -> (tau::Float64, event::Tuple{Symbol,Any})`
  - `advance_to(s, env, Δ, bp) -> SimState` — rate boundary 를 **넘지 않는** 전진
  - `advance_to_rate_boundary(s, env, Δ, bp) -> SimState` — 노드를 닫고 넘어간다
  - `energy_between(s, env, Δ, bp) -> Float64` — 구간 소비 에너지 [J]

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_sojourn.jl
#   julia +lts --project=. test/smdp_sojourn.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "sojourn",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7)
CB.step_environment!(env); CB.set_sim_step!(1); CB.update_planning_cache!(env, 0.0)
const S0 = CB.simstate_of(env)
const P  = CB.HazardParams()
const BP = CB.BATTERY_FLEET[].params

@testset "τ > 0 이고 유한하다" begin
    for seed in 1:50
        τ, ev = CB.sample_sojourn(S0, env, P, BP, MersenneTwister(seed))
        @test τ > 0.0
        @test isfinite(τ)
        @test ev[1] in (:failure, :terminal, :horizon)
    end
end

@testset "같은 시드 = 같은 τ" begin
    a = CB.sample_sojourn(S0, env, P, BP, MersenneTwister(42))
    b = CB.sample_sojourn(S0, env, P, BP, MersenneTwister(42))
    @test a[1] == b[1] && a[2] == b[2]
end

@testset "λ 를 키우면 τ 가 줄어든다 (단조성)" begin
    slow = CB.HazardParams(mode = 0.1)
    fast = CB.HazardParams(mode = 10.0)
    med(p) = (ts = [CB.sample_sojourn(S0, env, p, BP, MersenneTwister(k))[1] for k in 1:200];
              sort!(ts)[100])
    @test med(fast) < med(slow)
end

@testset "delta_max 는 지평선이다" begin
    τ, ev = CB.sample_sojourn(S0, env, CB.HazardParams(mode = 1e-9), BP,
                              MersenneTwister(1); delta_max = 5.0)
    @test τ ≈ 5.0
    @test ev[1] === :horizon
end

@testset "🔴 이슈 C — who 를 RobotID 로 되돌릴 수 있다" begin
    k = first(sort!(collect(keys(S0.fleet))))
    rid = CB.robot_id_of(k)
    @test rid isa CB.RobotID
    @test CB._int_key(rid) == k
    @test_throws ErrorException CB.robot_id_of(-999)   # 없는 키는 조용히 넘어가지 않는다
end

@testset "🔴 이슈 D — 경쟁위험이 셋이다" begin
    # break · cell · zone. 엔진(hazard_step!)이 셋을 독립적으로 검사하므로 경량 레인도 셋이다.
    kinds = Set{Symbol}()
    for seed in 1:400
        _, ev = CB.sample_sojourn(S0, env, CB.HazardParams(mode = 50.0), BP,
                                  MersenneTwister(seed))
        ev[1] === :failure && push!(kinds, ev[2] isa Symbol ? ev[2] : :break)
    end
    @test :zone in kinds
    @test :cell in kinds        # 없으면 경량 레인이 2위험, 엔진이 3위험이다
end

@testset "dt 루프가 없다 — 200 회 표집이 1 초 안에" begin
    CB.sample_sojourn(S0, env, P, BP, MersenneTwister(0))          # 컴파일 소진
    t = @elapsed for k in 1:200
        CB.sample_sojourn(S0, env, P, BP, MersenneTwister(k))
    end
    @test t < 1.0
end

@testset "advance_to 는 boundary 를 넘으면 죽는다" begin
    Δ = CB.T_plan_next(S0, env)
    isfinite(Δ) && @test_throws ErrorException CB.advance_to(S0, env, Δ * 2.0, BP)
end

@testset "energy_between 이 양수이고 Δ 에 선형이다" begin
    e1 = CB.energy_between(S0, env, 1.0, BP)
    e2 = CB.energy_between(S0, env, 2.0, BP)
    @test e1 > 0.0
    @test e2 ≈ 2.0 * e1 rtol = 1e-9
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_sojourn.jl`
Expected: FAIL with `UndefVarError: sample_sojourn not defined`

- [ ] **Step 3: 이슈 C · D 의 두 보조 함수를 먼저 만든다**

`src/smdp/derive.jl` 끝에:

```julia
"""
    robot_id_of(k::Int) -> RobotID

`_int_key` 의 **역지도**(이슈 C). `s` 는 벌거벗은 `Int` 키를 나르는데 `apply_action!` →
`action_to_proposal` 은 진짜 `RobotID` 를 요구한다.

🔴 id 카운터가 **타입별**이라 `RobotID(3)`·`AssemblyID(3)`·`TransportUnitID(3)` 이 공존한다.
그래서 `RobotID(k)` 를 그냥 만들지 않고 **살아 있는 함대에서 찾는다.** 못 찾으면 죽는다 —
조용히 없는 로봇을 지목하면 그 롤아웃 전체가 거짓이다.
"""
function robot_id_of(k::Int)
    fleet_b = BATTERY_FLEET[]
    fleet_b === nothing && error("robot_id_of: BATTERY_FLEET[] 가 비어 있다")
    for rid in keys(fleet_b.soc)
        _int_key(rid) == k && return rid
    end
    error("robot_id_of: 키 $(k) 에 해당하는 로봇이 함대에 없다")
end
```

`src/smdp/hazard.jl` 의 `hazard_rate_from` 옆에:

```julia
"""
    cell_rate_from(p::HazardParams, usage_s, mode) -> Float64

**셋째 경쟁위험**(이슈 D). `hazard_step!` 은 `break`·`cell`·`zone` 셋을 **독립적으로**
검사하는데(`hazard.jl:466-470`, 그 자리 주석이 셋을 합치지 말라고 직접 경고한다) 경량 레인이
둘만 세면 N-G1 이 **2위험 표집기와 3위험 엔진**을 비교하게 된다.
`_cell_rate` 와 같은 식이고 인자가 전부 `s` 에서 나온다(soc 는 안 쓴다).
"""
function cell_rate_from(p::HazardParams, usage_s::Float64, mode::Symbol)
    base = _rate(p.mtbf_cell_s)
    base == 0 && return 0.0
    u_hat = p.usage_scale_s > 0 ? usage_s / p.usage_scale_s : 0.0
    return base * p.mode * _mode_mult(p, mode) * exp(p.beta_usage * u_hat)
end
```

⚠️ `_cell_rate` 의 실제 본문을 `sed -n '360,370p' src/smdp/hazard.jl` 로 확인하고 **그대로 옮긴다.** 다르면 그 본문을 쓰고 이 계획의 오류로 보고한다.

- [ ] **Step 4: `sojourn.jl` 을 구현한다**

```julia
# =============================================================================
# sojourn.jl — spec §5-3. **dt 루프가 없다.**
#
# 두 종류의 시각을 구분한다(spec §2-4):
#   decision epoch  = 실패 도착. 행동 선택이 있다. 이 함수가 돌려주는 것.
#   rate boundary   = 다음 노드 완료. 행동 선택이 **없다**. 이 루프 안에만 있다.
#
# 경쟁위험 셋: break(로봇별) · cell(로봇별) · zone(전역). 합치지 않는다.
# =============================================================================

_exp1_draw(rng) = -log(rand(rng))

"""로봇마다 usage/soc 를 Δ 만큼 굴린 새 `s`. 노드는 닫지 않는다."""
function _advance_fields(s::SimState, env, Δ::Float64, bp::BatteryParams)
    cap = Float64(bp.capacity_J)
    fleet = Dict{Int,RobotRec}()
    for (k, r) in s.fleet
        m = mode_of(s, env, k)
        fleet[k] = RobotRec(
            soc     = clamp(r.soc - mode_power_W(bp, m) * Δ / cap, 0.0, 1.0),
            usage_s = r.usage_s + (m === :idle ? 0.0 : Δ))
    end
    return SimState(g = s.g, geo = s.geo, fleet = fleet, prog = s.prog)
end

"""
    advance_to(s, env, Δ, bp) -> SimState

rate boundary 를 **넘지 않는** 전진. `Δ > T_plan_next(s, env)` 면 **죽는다** — 조용히 넘어가면
닫혀야 할 노드가 안 닫힌 채 시간만 흐르고, 그 뒤 모든 λ 가 틀린 모드에서 계산된다.
"""
function advance_to(s::SimState, env, Δ::Float64, bp::BatteryParams)
    Δ <= T_plan_next(s, env) + 1e-9 ||
        error("advance_to: Δ=$(Δ) 가 rate boundary $(T_plan_next(s, env)) 를 넘는다")
    return _advance_fields(s, env, Δ, bp)
end

"""
    advance_to_rate_boundary(s, env, Δ, bp) -> SimState

경계까지 가서 **그 경계를 만든 정점을 닫는다.** 후행 정점의 활성화는 `active_of` 가 자동으로
한다(파생값이므로 따로 열 것이 없다 — spec §2-3 (a)).
"""
function advance_to_rate_boundary(s::SimState, env, Δ::Float64, bp::BatteryParams)
    s2 = _advance_fields(s, env, Δ, bp)
    closed = copy(s.prog.closed)
    for v in active_of(s)
        d = node_duration(env, v)
        (d > 0.0 && RHO[] * d <= Δ + 1e-9) && push!(closed, v)
    end
    length(closed) > length(s.prog.closed) ||
        error("advance_to_rate_boundary: Δ=$(Δ) 에서 닫힌 노드가 없다 — 전진하지 못한다")
    return SimState(g = s2.g, geo = s2.geo, fleet = s2.fleet,
                    prog = ProgBlock(closed = closed))
end

"""
    energy_between(s, env, Δ, bp) -> Float64

구간 `[0, Δ]` 의 소비 에너지 [J]. 모드가 상수인 구간이라 닫힌 형태다(spec §2-1).
`s` 의 모드를 쓴다 — 구간 내내 그 모드였기 때문이다.
"""
energy_between(s::SimState, env, Δ::Float64, bp::BatteryParams) =
    Δ <= 0 ? 0.0 : sum(mode_power_W(bp, mode_of(s, env, k)) for k in keys(s.fleet); init = 0.0) * Δ

"""
    sample_sojourn(s, env, p, bp, rng; delta_max = Inf) -> (τ, event)

`event` 는 `(:failure, robot_key)` · `(:failure, :zone)` · `(:failure, :cell)` ·
`(:terminal, nothing)` · `(:horizon, nothing)` 중 하나.
`(:failure, k)` 의 `k::Int` 는 `robot_id_of(k)` 로 되돌린다(이슈 C).
"""
function sample_sojourn(s::SimState, env, p::HazardParams, bp::BatteryParams, rng;
                        delta_max::Float64 = Inf)
    cap = Float64(bp.capacity_J)
    cur = s
    t   = 0.0
    Eb  = Dict(k => _exp1_draw(rng) for k in sort!(collect(keys(cur.fleet))))  # break
    Ec  = Dict(k => _exp1_draw(rng) for k in sort!(collect(keys(cur.fleet))))  # cell
    Ez  = _exp1_draw(rng)                                                      # zone
    λz  = _rate(p.mtbf_zone_s) * p.mode
    n_boundary = 0

    while true
        rp = rate_params(cur, env, p, bp, cap)
        Δ_fail, who = Inf, nothing
        for (k, (A, a)) in rp
            d = inv_integrated_hazard(A, a, Eb[k])
            d < Δ_fail && (Δ_fail = d; who = k)
            # cell 은 soc 에 안 의존하므로 a 의 soc 항이 빠진 상수율이다
            Ac = cell_rate_from(p, cur.fleet[k].usage_s, mode_of(cur, env, k))
            dc = Ac > 0 ? Ec[k] / Ac : Inf
            dc < Δ_fail && (Δ_fail = dc; who = :cell)
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
        isfinite(Δ_node) || return (t + Δ_stop, (:terminal, nothing))

        # rate boundary — 결정이 아니다. 소진하고 계속 간다.
        for (k, (A, a)) in rp
            Eb[k] -= integrated_hazard(A, a, Δ_node)
            Ac = cell_rate_from(p, cur.fleet[k].usage_s, mode_of(cur, env, k))
            Ec[k] -= Ac * Δ_node
        end
        λz > 0 && (Ez -= λz * Δ_node)
        cur = advance_to_rate_boundary(cur, env, Δ_node, bp)
        t  += Δ_node

        n_boundary += 1
        n_boundary > p.max_events * 16 && error(
            "sample_sojourn: rate boundary 를 $(n_boundary) 번 넘었다 — T_plan_next 가 " *
            "전진하지 않거나 λ 가 0 이다. 조용히 T_done 을 돌려주면 '실패가 안 오는 세계'를 " *
            "탐색하게 된다")
        isempty(active_of(cur)) && return (t, (:terminal, nothing))
    end
end
```

- [ ] **Step 5: 로더 등록 + 통과 확인**

`src/smdp/mdp.jl` 에 `include("sojourn.jl")` 를 `tplan.jl` 다음에 추가한다.

Run: `julia +lts --project=. test/smdp_sojourn.jl`
Expected: PASS

- [ ] **Step 6: 게이트 N-G1 을 쓴다 — 정확 표집 vs dt-루프**

```python
#!/usr/bin/env python3
"""게이트 N-G1 — sample_sojourn 이 hazard_step! 의 dt-루프와 **같은 분포**를 내는가.

근사 검사가 아니다. spec §2-2 가 정확 표집을 주장하므로 KS 검정이 통과해야 한다.
떨어지면 넷 중 하나다:
  (a) 닫힌 형태가 틀렸다
  (b) advance_to_rate_boundary 가 usage/soc 를 엔진과 다르게 굴린다
  (c) 🔴 D-6 의 rate boundary 상한 근사가 분포를 흔든다  ← 이 세대에 새로 생긴 후보
  (d) 아직 못 닫은 유예 기전이 있다(spec §2-5)

  진단 순서: (c) 를 먼저 본다. rho 를 바꿔 가며 KS 가 단조로 움직이면 (c) 다.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
"""
import json, sys
from scipy.stats import ks_2samp

ALPHA = 0.01   # 위험 예산. 낮게 잡는다 — 여기서 위양성으로 죽는 것이 위음성보다 낫다

def main(path):
    d = json.load(open(path))
    light, heavy = d["light_tau"], d["heavy_tau"]
    assert len(light) >= 200 and len(heavy) >= 200, (len(light), len(heavy))
    if min(light) <= 0 or min(heavy) <= 0:
        print("FAIL: tau <= 0 이 있다"); return 1
    st, p = ks_2samp(light, heavy)
    print(f"n_light={len(light)} n_heavy={len(heavy)} KS={st:.4f} p={p:.4g}")
    print(f"median light={sorted(light)[len(light)//2]:.4f} "
          f"heavy={sorted(heavy)[len(heavy)//2]:.4f}")
    print(f"kind mix light={d['light_kinds']} heavy={d['heavy_kinds']}")
    if set(d["light_kinds"]) != set(d["heavy_kinds"]):
        print("FAIL: 두 레인의 사건 종류 집합이 다르다 (이슈 D)"); return 1
    if p < ALPHA:
        print(f"FAIL: 두 분포가 갈린다 (p={p:.4g} < {ALPHA})"); return 1
    print("PASS"); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

짝 데이터를 만드는 Julia 쪽은 `tools/monitor/gen_ng1_pairs.jl` 에 둔다: 같은 `s` 에서
(가) `sample_sojourn` 을 200회, (나) hazard 를 켠 실제 `step_environment!` 루프를 200회(hazard 시드만 바꿔) 돌려 **첫 사건까지의 시간과 그 종류**를 모아 `{"light_tau": [...], "heavy_tau": [...], "light_kinds": [...], "heavy_kinds": [...]}` 로 낸다.

- [ ] **Step 7: 게이트를 돌린다**

Run:
```bash
julia +lts --project=. tools/monitor/gen_ng1_pairs.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
```
Expected: `PASS`. **FAIL 이면 위 (a)~(d) 중 어느 것인지 적고 나서 고친다.** 특히 (c) 는 이 세대가 새로 만든 근사이므로 여기서 드러나는 것이 정상이다.

- [ ] **Step 8: 커밋**

```bash
git add src/smdp/sojourn.jl src/smdp/derive.jl src/smdp/hazard.jl src/smdp/mdp.jl \
        test/smdp_sojourn.jl tools/monitor/gen_ng1_pairs.jl \
        wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
git commit -m "feat(smdp): exact sojourn over three competing risks, gated against the engine by KS"
```

---

## Task T10: ρ 적합 + 게이트 N-G2 — **2.5시간** (+ 스윕 대기 ~30분)

**Files:**
- Create: `tools/monitor/fit_rho.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng2.py`
- Modify: `src/smdp/tplan.jl` (`RHO[]` 기본값)

**Interfaces:**
- Consumes: `node_duration`(T8), 무거운 레인의 실제 노드 완료 시각
- Produces: `results/smdp/rho.json` — `{"rho": …, "n_nodes": …, "ratio_p10": …, "ratio_p90": …}`

- [ ] **Step 1: 실측 짝을 모은다**

`tools/monitor/fit_rho.jl` 은 `tractor.mpd` 를 hazard 없이 완주시키면서 정점마다
`(계획 소요시간 = get_min_duration, 실제 소요시간 = 실제 close 시각 − 실제 활성화 시각)` 을 기록한다.
`update_planning_cache!` 가 정점을 닫는 순간의 `sim_time(env.dt)` 를 쓴다. 🔴 활성화 시각은
`get_t0` 가 아니라 **그 정점이 `cache.active_set` 에 처음 들어온 스텝**을 스크립트가 직접 기록한다
(D-6 이 밝힌 대로 `get_t0` 는 안 움직인다).

- [ ] **Step 2: ρ 를 적합한다**

`ρ = median(실제/계획)`. **평균이 아니라 중앙값**이다 — 교착 한 번이 평균을 통째로 끌고 간다.

- [ ] **Step 3: 게이트 N-G2 를 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G2 — ρ 보정 뒤 T_plan 의 편향이 **팔 간 비교를 뒤집는가**.

정확도 게이트가 아니다(spec §5-4). 경량 모델은 3계층 스택을 안 돌리므로 절대값은 틀린다.
물어야 할 것은 하나다: 같은 사건에서 경량 모델이 매기는 팔 순위가 무거운 레인의 순위와 같은가.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json \
          results/smdp/arm_ranks.json
"""
import json, sys
from scipy.stats import kendalltau

MIN_TAU = 0.6          # 순위상관 하한
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
    med = sorted(taus)[len(taus) // 2]
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

`ratio_p90 / ratio_p10 > 3` 이면 **스칼라 ρ 하나로 부족하다** — spec §10 미해결 5번이 발화한 것이다. 그 사실을 실측으로 적고 혼잡도(활성 로봇 수) 의존 ρ 를 후속 작업으로 올린다. **이 태스크에서 즉흥적으로 모델을 늘리지 않는다.**

- [ ] **Step 5: `RHO[]` 기본값을 채우고 커밋**

```bash
git add src/smdp/tplan.jl tools/monitor/fit_rho.jl \
        wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json results/smdp/arm_ranks.json
git commit -m "feat(smdp): fit rho against the heavy lane; gate on rank preservation not accuracy"
```

---

# Phase 3 — 생성 인터페이스

## Task T11: `rvo_rebuild!` + 게이트 N-G4 — **2시간**

🔴 `update_rvo_sim!` 은 `rvo_sim_needs_update` 로 가드돼 있어 **에이전트가 추가될 때만** 재구축한다. 갈래가 위치만 옮겼으면 가드가 `false` 라 오염이 남는다.

**3계층 정책 로직은 하나도 바뀌지 않는다** — 술어만 뺀 같은 구성 경로다.

**Files:**
- Modify: `src/route_planning.jl` (`update_rvo_sim!` 부근), `src/ConstructionBots.jl` (export)
- Test: `test/smdp_rvo_rebuild.jl` (신규, = N-G4)

**Interfaces:**
- Produces: `rvo_rebuild!(env) -> PlannerEnv` (무조건 재구축). `update_rvo_sim!(env)` 는 동작 불변

- [ ] **Step 1: 게이트 시험을 쓴다**

```julia
# test/smdp_rvo_rebuild.jl   —  게이트 N-G4
# RVO 는 씬트리의 **파생물**이다(spec §5-2). 그 명제가 참이면 재구축만으로 갈래 오염이 지워진다.
# 거짓이면 그건 롤아웃 문제가 아니라 **기존 실행 레인의 버그**다.
#   julia +lts --project=. test/smdp_rvo_rebuild.jl
using ConstructionBots, Test
const CB = ConstructionBots

env = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "ng4",
                         num_robots = 6, assignment_mode = :greedy,
                         open_animation_at_end = false, save_animation = false)
for k in 1:50
    CB.step_environment!(env); CB.set_sim_step!(k); CB.update_planning_cache!(env, 0.0)
end

# ⚠️ `rvo_get_agent_position` 의 실제 시그니처를 구현 시 확인한다:
#    grep -n "function rvo_get_agent_position" -A4 src/rvo_interface.jl
positions() = Dict(id => CB.rvo_get_agent_position(CB.get_node(env.scene_tree, id))
                   for id in sort!(collect(CB.get_vtx_ids(CB.rvo_global_id_map())); by = string))

@testset "재구축 후 위치 == 씬트리" begin
    CB.rvo_rebuild!(env)
    for (id, p) in positions()
        tr = CB.project_to_2d(CB.global_transform(CB.get_node(env.scene_tree, id)).translation)
        @test p[1] ≈ tr[1] atol = 1e-9
        @test p[2] ≈ tr[2] atol = 1e-9
    end
end

@testset "🔴 update_rvo_sim! 은 오염을 못 지운다 (음성 대조)" begin
    before = positions()
    victim = first(sort!(collect(keys(before)); by = string))
    CB.rvo_set_agent_position!(CB.get_node(env.scene_tree, victim), (99.0, 99.0))
    CB.update_rvo_sim!(env)                       # 가드가 false → 아무 일도 안 한다
    @test CB.rvo_get_agent_position(CB.get_node(env.scene_tree, victim))[1] ≈ 99.0
    CB.rvo_rebuild!(env)                          # 무조건 재구축은 지운다
    @test CB.rvo_get_agent_position(CB.get_node(env.scene_tree, victim))[1] ≈
          before[victim][1] atol = 1e-9
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

`src/route_planning.jl` 의 `update_rvo_sim!` 을 다음으로 바꾼다:

```julia
"""
    rvo_rebuild!(env)

RVO 시뮬레이터를 씬트리에서 **무조건** 다시 만든다. `update_rvo_sim!` 의 본문에서 술어만 뺀
것이고 구성 경로도 α 재적용도 같다 — **3계층 정책 규칙은 하나도 안 바뀐다.**

왜 가드 없는 판이 따로 필요한가: `rvo_sim_needs_update` 는 "필요한 에이전트가 맵에 없는가" 만
본다. 롤아웃 갈래가 **위치만 옮기고 에이전트를 추가하지 않았으면** 가드가 false 라 재구축이
안 일어나고 오염이 다음 갈래로 샌다.

⚠️ **`apply_action!` 도중에 부르면 안 된다.** `replace_robot.jl:835` 가
`rvo_set_agent_max_speed!(tu, 0.0)` 로 핀을 걸고 같은 함수 안에서 force-close 한 뒤 :890 에서
복원한다. 재구축이 그 사이에 끼면 핀이 풀려 RVO 가 유닛을 목표 밖으로 밀어낸다.
**완전히 끝난 뒤에만** 부른다.
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
Expected: 셋 다 PASS. **`smoke_run` 의 makespan 이 이 변경 전과 같아야 한다** — `update_rvo_sim!` 의 동작은 안 바뀌었으므로.

- [ ] **Step 5: 커밋**

```bash
git add src/route_planning.jl src/ConstructionBots.jl test/smdp_rvo_rebuild.jl
git commit -m "feat(rvo): split the unguarded rebuild out of update_rvo_sim! -- policy rules unchanged"
```

---

## Task T12: `generative.jl` — `G(s,a)` — **4시간**

**Files:**
- Create: `src/smdp/generative.jl`
- Modify: `src/smdp/mdp.jl`
- Test: `test/smdp_generative.jl` (신규)

**Interfaces:**
- Consumes: `ActionRegistry`(🔴 `src/` 에 Julia 소비처가 **아직 0개** — Step 3 이 로드를 새로 배선한다), `action_to_proposal(ctx, a)`(`wm4.../oracle/ood_mdp_shim.jl`), `simstate_of`(R2), `sample_sojourn`·`advance_to`·`energy_between`(T9), `robot_id_of`(T9), `rvo_rebuild!`(T11), `resolve_assignments!`(T13 — 이 태스크에서는 **스텁**)
- Produces:
  - `assert_paired(s::SimState, env)` — 🔴 **이슈 F 의 해소**
  - `legal_actions(s::SimState, kind::Symbol) -> Vector{Int}`
  - `apply_action!(env, ctx, a::Int) -> Nothing`
  - `generate(s, env, ctx, a, p, bp, rng; delta_max) -> (s′, R, τ, event)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_generative.jl
#   julia +lts --project=. test/smdp_generative.jl
using ConstructionBots, Test, Random
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "smdp_fixtures.jl"))    # _fault_fixture 를 여기 둔다

@testset "legal_actions_kind 는 레지스트리 **파생**이다" begin
    # 🔴 여기에 팔 번호를 리터럴로 적지 않는다. 적으면 레지스트리가 바뀔 때 이 시험이
    #    정당한 어휘 변경에 대해 거짓으로 빨개진다. 검사할 것은 **파생 관계**뿐이다.
    AR = CB.ActionRegistry
    env0, _ = _fault_fixture()
    s0 = CB.simstate_of(env0)
    for k in (:fault, :battery, :zone)
        @test Set(CB.legal_actions_kind(k)) == Set(AR.kind_valid(String(k)))
        @test Set(CB.legal_actions_kind(k)) ⊆ Set(AR.IDS)
        @test 0 in CB.legal_actions(s0, k)                # NOOP 은 언제나 있다
    end
    # 오늘의 어휘를 **기준선으로만** 못박는다 — 갈리면 이 줄을 갱신하고 그 사실을 보고한다
    @test AR.VOCAB == "v3-4arms"
end

@testset "🔴 D-7 — 예비 재고가 메뉴를 좁히지 않는다" begin
    # 예비는 충분하다고 **가정**한다(spec §3-2). 그래서 legal_actions 는 s 를 보고도
    # Replace 를 빼지 않는다. 가정이 깨지는 것은 메뉴가 아니라 **에러**로 드러난다.
    env, ctx = _fault_fixture()
    s = CB.simstate_of(env)
    @test 1 in CB.legal_actions(s, :fault)
    @test CB.legal_actions(s, :fault) == CB.legal_actions_kind(:fault)
end

@testset "🔴 D-7 가드 — 예비가 실제로 마르면 죽는다" begin
    env, ctx = _fault_fixture()
    saved = deepcopy(CB.SPARE_POOLS[])
    empty!(CB.SPARE_POOLS[])                     # 가정을 고의로 깬다
    @test_throws ErrorException CB.apply_action!(env, ctx, 1)
    CB.SPARE_POOLS[] = saved
end

@testset "🔴 이슈 F — s 와 env 가 짝인지 검사한다" begin
    env, ctx = _fault_fixture()
    s = CB.simstate_of(env)
    @test CB.assert_paired(s, env) === nothing
    CB.apply_action!(env, ctx, 1)                # 그래프 수술로 정점 번호가 재부여된다
    @test_throws ErrorException CB.assert_paired(s, env)   # 낡은 s 는 조용히 안 지나간다
end

@testset "행동이 진짜로 그래프를 고친다" begin
    env, ctx = _fault_fixture()
    s0 = CB.simstate_of(env)
    CB.apply_action!(env, ctx, 1)                # Replace
    s1 = CB.simstate_of(env)
    @test CB.state_hash(s1) != CB.state_hash(s0)
    @test s1.g.binding != s0.g.binding           # 배정 엣지가 재스탬프됐다
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
    bp = CB.BATTERY_FLEET[].params
    s1, R, τ, ev = CB.generate(s0, env, ctx, 0, CB.HazardParams(), bp, MersenneTwister(3))
    @test τ > 0.0
    @test isfinite(R)
    @test R <= 0.0                                # 보상은 비용의 음수다 (spec §4)
end
```

`test/smdp_fixtures.jl` 에 `_fault_fixture()` 를 둔다: `colored_8x8.ldr` 씬을 만들고
`enable_battery!` · `enable_hazard!` 후 200 스텝 굴린 뒤 `CB.fault_action(...)` 으로 사건 하나를
심어 `(env, ctx)` 를 돌려준다. ⚠️ 실제 주입 함수 이름을 `grep -n "function fault_action\|_pick_active_robot" src/respec/ood_injection.jl` 로 확인한다.

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_generative.jl`
Expected: FAIL with `UndefVarError: legal_actions_kind not defined`

- [ ] **Step 3: `assert_paired` 와 `legal_actions` 를 구현한다**

🔴 **먼저 `ActionRegistry` 를 로드해야 한다.** 실측: `src/` 안의 Julia 코드는 오늘 이 모듈을
**한 번도 로드하지 않는다**(`grep -rn "ActionRegistry" src/` → Julia 소비처 0개. Python 쪽
`dspy_service.py` · `steering_signature.py` 만 `action_registry.py` 를 쓴다). 그래서 이 태스크가
그 배선을 **새로 만든다.** `generative.jl` 머리에 런타임 include 를 둔다 — `mdp.jl` 이 이미 쓰는
것과 같은 패턴이다:

```julia
# 행동 어휘의 단일 진실원. `src/` 에서 이 모듈을 로드하는 것은 **이 파일이 처음이다** —
# 그래서 상대경로를 여기서 한 번만 적고 다른 곳에서 리터럴을 쓰지 않는다.
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(pkgdir(@__MODULE__), "wm4spacecraft_manufacturing",
                     "oracle", "action_registry.jl"))
```

⚠️ 실제 경로를 먼저 확인한다:
`ls wm4spacecraft_manufacturing/{oracle,core}/action_registry.jl`.
CLAUDE.md 2026-08-18 폴더 재편 이후 **`core/` 에 있을 수 있다** — 있는 쪽을 쓰고 이 계획의
오류로 보고한다.

```julia
"""
    assert_paired(s::SimState, env) -> Nothing

🔴 **이슈 F 의 해소.** `T_plan_next(s, env)` 처럼 `s` 와 `env` 를 **독립 인자로** 받는 함수는
둘이 같은 세계인지 확인해야 한다. `s.g.edges`·`s.prog.closed` 는 **스케줄 정점 인덱스**로
키가 잡혀 있고 `Replace` 의 그래프 수술이 그 번호를 **재부여**한다. 짝이 아니면
`T_done(s_old, env_new)` 가 조용히 엉뚱한 노드를 인덱싱한다.

spec §4 는 "`s` 에 그래프 세대 도장을 추가하라" 고 적었는데, **도장 대신 직접 대조**한다 —
필드를 늘리지 않고 O(E) 로 정확히 같은 것을 확인할 수 있기 때문이다(도장은 대리 지표라
충돌하면 거짓 통과가 난다).
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
"""
function legal_actions(s::SimState, kind::Symbol)
    arms = collect(legal_actions_kind(kind))
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

순서가 중요하다. `rvo_rebuild!` 는 **맨 마지막**이다(T11 의 핀 경고).
"""
function apply_action!(env, ctx, a::Int)
    _assert_spares_available(env, a)          # D-7 가드
    prop = action_to_proposal(ctx, a)
    prop === nothing || apply_respec!(env, prop)
    resolve_assignments!(env)                 # 공통 MILP 재풀이 — Task T13 이 채운다
    update_planning_cache!(env, 0.0)
    rvo_rebuild!(env)                         # ← 반드시 마지막
    return nothing
end

"""D-7 가드. 예비가 실제로 마르면 **죽는다**(spec §3-2).

CLAUDE.md 알려진 한계 6번: `nearest_pool` 은 가장 가까운 창고 하나만 보므로 전체 예비가
넉넉해도 **그 창고**가 비면 `pop_spare!` 가 `nothing` 을 돌려주고 `:no_spare` 로 강등된다.
그 신호는 전부 `@info`/`@warn` 이라 `Logging.Warn` 로거 아래에서 **보이지 않는다.**
그래서 로그가 아니라 에러로 만든다 — "안 났다" 와 "못 본다" 를 가른다."""
function _assert_spares_available(env, a::Int)
    a == 1 || return nothing                  # 1 = Replace 만 창고를 먹는다
    total = sum(length(v) for v in values(SPARE_POOLS[]); init = 0)
    total > 0 || error(
        "apply_action!: Replace 인데 예비가 하나도 없다 — D-7('예비는 충분하다')이 깨졌다. " *
        "DEMO_SPARES 를 올리거나 그 가정을 spec 에서 되돌릴 것. 조용히 NOOP 으로 떨어뜨리지 않는다")
    return nothing
end

"""
    generate(s, env, ctx, a, p, bp, rng; delta_max = Inf) -> (s′, R, τ, event)

`G(s,a)`. spec §5-1.
"""
function generate(s::SimState, env, ctx, a::Int, p::HazardParams, bp::BatteryParams, rng;
                  delta_max::Float64 = Inf)
    assert_paired(s, env)
    apply_action!(env, ctx, a)
    s_plus = simstate_of(env)
    τ, ev  = sample_sojourn(s_plus, env, p, bp, rng; delta_max = delta_max)
    s_next = advance_to(s_plus, env, τ, bp)
    R      = -(τ + objective_w_E() * energy_between(s_plus, env, τ, bp))
    return (s_next, R, τ, ev)
end

"""`w_E` 는 `objective.json` 이 단일 진실원이다. 여기서 숫자를 계산하지 않는다."""
function objective_w_E()
    c = Objective.load()
    return Float64(c["kappa"]) * Float64(c["M_ref"]) / Float64(c["E_ref"])
end
```

`resolve_assignments!` 는 이 태스크에서 **빈 스텁**으로 둔다
(`RESOLVE_CALLS[] += 1; return (ran_milp = false, n_reassigned = 0)`). Task T13 이 채운다 —
그래야 T12 의 시험이 T13 을 기다리지 않는다.

- [ ] **Step 5: 로더 등록 + 통과 확인**

`src/smdp/mdp.jl` 에 `include("generative.jl")` 를 `sojourn.jl` 다음에 추가한다.

Run: `julia +lts --project=. test/smdp_generative.jl`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add src/smdp/generative.jl src/smdp/mdp.jl test/smdp_generative.jl test/smdp_fixtures.jl
git commit -m "feat(smdp): G(s,a) with a paired-state assertion and a hard guard on the spare assumption"
```

---

## Task T13: 공통 MILP 재풀이 — **3시간**

CLAUDE.md 의 확정 설계(2026-08-20, 미구현분). 모든 팔 뒤에 **같은** 재풀이가 돌아야 `Ĵ(a)` 비교가 팔의 성질이 된다.

**Files:**
- Modify: `src/smdp/generative.jl` (`resolve_assignments!`)
- Test: `test/smdp_common_resolve.jl` (신규)

**Interfaces:**
- Produces: `resolve_assignments!(env) -> NamedTuple` — `(ran_milp::Bool, n_reassigned::Int)`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/smdp_common_resolve.jl
# 재풀이는 **파이프라인의 성질**이어야 한다. 어떤 팔에서든 돈다 — NOOP 에서도.
#   julia +lts --project=. test/smdp_common_resolve.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

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

@testset "🔴 음성 대조 — 재풀이가 항진적이지 않다" begin
    # CLAUDE.md 경고: 후보 간선이 0개면 공통 재풀이가 **아무것도 안 바꾼다**.
    # "재풀이를 켰다" 가 아니라 "재풀이가 실제로 계획을 바꿨다" 를 재야 한다.
    env, ctx = _fault_fixture()
    r = CB.resolve_assignments!(env)
    @test r.n_reassigned >= 0
    r.n_reassigned == 0 && @info "n_reassigned == 0 — 이 픽스처에서는 재풀이가 항진적이다. " *
                                 "게이트로 쓰지 말 것"
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/smdp_common_resolve.jl`
Expected: FAIL — `RESOLVE_CALLS` 미정의 또는 스텁이라 `n_reassigned` 가 언제나 0

- [ ] **Step 3: 구현한다**

```julia
const RESOLVE_CALLS = Ref(0)    # 계측용. 시험이 "정말 돌았는가" 를 이걸로 본다

"""
    resolve_assignments!(env) -> (ran_milp, n_reassigned)

**모든 팔 뒤에 도는 공통 재풀이.** 미배정 프론티어를 현재 그래프·기하 위에서 다시 푼다.
어떤 팔에서든 같은 코드가 돌아야 `Ĵ(a)` 의 차이가 팔의 차이가 된다.

⚠️ 스케줄이 유효하지 않으면 **죽는다.** 조용히 넘어가면 그 롤아웃의 나머지가 전부 거짓이다.
⚠️ 이 함수가 `release_pending_assignments!` 를 부르는 것이 Phase 4 C2 의 전제조건이다 —
`ForbidAgent` 류 제약은 **후보(Big-M) 엣지에만** 걸리므로, 프론티어를 먼저 열지 않으면
0 개 제약으로 컴파일되어 "hollow admit" 이 된다(`compiler.jl:66` 의 주석이 그렇게 적는다).
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

⚠️ `release_pending_assignments!` · `assign_collaborative_tasks!` · `validate` 의 실제 이름·시그니처를 `grep -rn "release_pending_assignments\|assign_collaborative_tasks" src/` 로 확인한다.

- [ ] **Step 4: 통과를 확인한다**

Run: `julia +lts --project=. test/smdp_common_resolve.jl`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/generative.jl test/smdp_common_resolve.jl
git commit -m "feat(smdp): one common MILP re-solve after every arm"
```

---

## Task T14: 게이트 N-G5 — 보상 분해 — **2시간**

**Files:**
- Create: `tools/monitor/check_reward_decomposition.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng5.py`

**Interfaces:**
- Consumes: `generate`(T12)
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

🔴 **이 게이트가 D-6 의 상한 근사를 다시 잡는다.** `T_plan_next` 가 상한이라 경량 레인의 `Σ τ` 가 실제 makespan 보다 **클 수** 있다. FAIL 이면 그 부호를 먼저 보고, 양(+)이면 D-6 의 편향이지 회계 버그가 아니다 — spec §10 (2)에 실측값으로 적는다.

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/check_reward_decomposition.jl \
        wm4spacecraft_manufacturing/smdp/gate_ng5.py results/smdp/ng5_decomposition.json
git commit -m "test(smdp): gate the additive reward decomposition over epochs"
```

---

# Phase 4 — 행동 신설 (D-8)

spec §5. **여기가 이 계획의 논문 기여다.** `L_prim` 을 열어 LLM 이 아무도 안 짠 대응을 만들게 하고, 검증이 그것을 안전하게 만든다.

## Task C1: `maybe_respecify!` 를 순차 집행으로 — **3시간**

🔴 실측: `replan.jl:452 · 529 · 679 · 798 · 898` 의 다섯 dispatch 분기가 **각각 `return` 한다.** 그래서 `RespecProposal([RelocateBuild(:z3), ReplaceAgent(R7)])` 은 첫 번째만 집행하고 나머지를 **조용히 버린다.**

**Files:**
- Modify: `src/respec/replan.jl` (`maybe_respecify!`)
- Test: `test/respec_sequential_enact.jl` (신규)

**Interfaces:**
- Produces: `maybe_respecify!(env, proposal; …) -> Symbol` — 시그니처 불변, **동작만** 순차로

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/respec_sequential_enact.jl
# 제약 벡터의 **모든** 원소가 집행되는가. 지금은 first-match-wins 라 하나만 먹는다.
#   julia +lts --project=. test/respec_sequential_enact.jl
using ConstructionBots, Test
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

@testset "🔴 두 제약이 둘 다 집행된다" begin
    env, ctx = _fault_zone_fixture()          # fault + zone 이 동시에 도착한 판
    zk  = first(sort!(collect(keys(CB.RESTRICTION_ZONES[])); by = string))
    rid = _faulted_robot(env)
    before_poses  = _assembly_poses(env)
    before_binding = copy(CB.simstate_of(env).g.binding)

    prop = CB.RespecProposal(CB.ConstraintSpec[CB.RelocateBuild(zk), CB.ReplaceAgent(rid, 0.0)])
    CB.maybe_respecify!(env, prop)

    @test _assembly_poses(env) != before_poses                   # RelocateBuild 가 먹었다
    @test CB.simstate_of(env).g.binding != before_binding        # ReplaceAgent 도 먹었다
end

@testset "🔴 순서가 고정이다 — 기하 먼저, 그래프 나중" begin
    env, ctx = _fault_zone_fixture()
    zk  = first(sort!(collect(keys(CB.RESTRICTION_ZONES[])); by = string))
    rid = _faulted_robot(env)
    CB.ENACT_ORDER_LOG[] = Symbol[]
    CB.maybe_respecify!(env,
        CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(rid, 0.0), CB.RelocateBuild(zk)]))
    # 제안에 적힌 순서가 아니라 **집행 순서 규칙**을 따른다
    @test CB.ENACT_ORDER_LOG[] == [:relocate, :replace]
end

@testset "🔴 제약마다 직전 재검증한다" begin
    # 첫 집행이 둘째의 전제조건을 무효화하면 둘째는 **거부**돼야 한다.
    # 같은 zone 에 RelocateBuild 를 두 번 걸면, 첫 번째가 이미 비켰으므로 두 번째는
    # 도메인이 비어 거부돼야 한다 — 조용히 no-op 이면 안 된다.
    env, ctx = _fault_zone_fixture()
    zk = first(sort!(collect(keys(CB.RESTRICTION_ZONES[])); by = string))
    st = CB.maybe_respecify!(env,
        CB.RespecProposal(CB.ConstraintSpec[CB.RelocateBuild(zk), CB.RelocateBuild(zk)]))
    @test st in (:partial, :admitted)
    @test any(r -> r.status !== :ok, CB.LAST_ENACT_REPORT[])
end

@testset "단일 제약의 동작은 안 바뀐다 (회귀)" begin
    env, ctx = _fault_fixture()
    rid = _faulted_robot(env)
    before = copy(CB.simstate_of(env).g.binding)
    CB.maybe_respecify!(env, CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(rid, 0.0)]))
    @test CB.simstate_of(env).g.binding != before
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/respec_sequential_enact.jl`
Expected: FAIL — 첫 testset 에서 `binding` 이 안 바뀐다(`RelocateBuild` 가 먼저 걸려 `return` 했다)

- [ ] **Step 3: 순차 집행으로 바꾼다**

`maybe_respecify!` 의 `if/elseif` 사슬을 **제약별 루프**로 바꾼다. 각 분기의 본문은 그대로 두고 `return` 을 **결과 기록**으로 바꾼다:

```julia
const ENACT_ORDER_LOG  = Ref(Symbol[])          # 시험이 순서를 보는 창
const LAST_ENACT_REPORT = Ref(NamedTuple[])     # 제약별 (kind, status, detail)

"""집행 순서 규칙. **기하 → 그래프 → 배송**, 그리고 RVO 재구축은 호출자가 맨 끝에 한다.

왜 이 순서인가: 기하 수술(`TranslateBuild`/`RelocateBuild`)이 조립체 좌표를 옮기고,
그래프 수술(`ReplaceAgent`)은 그 좌표 위에서 인계 대상을 고른다. 반대로 하면 인계가 옛
좌표를 보고 정해진 뒤 그 아래에서 땅이 움직인다."""
_enact_rank(c::ConstraintSpec) =
    c isa TranslateBuild || c isa RelocateBuild ? 1 :
    c isa ForbidZone                            ? 2 :
    c isa ReplaceAgent                          ? 3 :
    c isa SwapBattery                           ? 4 : 5
```

```julia
function maybe_respecify!(env, proposal; kwargs...)
    ENACT_ORDER_LOG[]  = Symbol[]
    LAST_ENACT_REPORT[] = NamedTuple[]
    ordered = sort(proposal.constraints; by = _enact_rank)
    n_ok = 0
    for c in ordered
        # 🔴 제약마다 **직전** 재검증한다. verify_* 는 집행 전 상태에서 판정하므로,
        #    앞선 집행이 전제조건을 무효화했으면 여기서 걸러야 한다. 조용히 지나가면
        #    already_clear / :residual_blocked 류의 **무성 no-op** 이 된다.
        one = RespecProposal(ConstraintSpec[c], proposal.rationale, proposal.source_event)
        st, detail = _enact_one!(env, one; kwargs...)
        push!(LAST_ENACT_REPORT[], (kind = nameof(typeof(c)), status = st, detail = detail))
        st === :ok && (n_ok += 1)
    end
    n_ok == 0 && return :fallback
    return n_ok == length(ordered) ? :admitted : :partial
end
```

`_enact_one!(env, one; kwargs...)` 은 **기존 다섯 분기를 그대로 옮긴 것**이다 — 술어
(`_is_relocate_build` 등)와 본문을 바꾸지 않고, `return :admitted` 를 `return (:ok, …)` 로,
거부를 `return (:rejected, reason)` 으로 바꾼다. 각 분기 진입 시 `push!(ENACT_ORDER_LOG[], :relocate)` 류를 한 줄 넣는다.

🔴 **분기 본문의 로직을 손대지 않는다.** 이 태스크가 바꾸는 것은 **제어 흐름 하나**다.

- [ ] **Step 4: 통과 + 실행 레인 회귀 확인**

Run:
```bash
julia +lts --project=. test/respec_sequential_enact.jl
julia +lts --project=. test/respec_determinism_smoke.jl
julia +lts --project=. tools/monitor/smoke_run.jl
```
Expected: 셋 다 PASS. **`smoke_run` 의 makespan 이 변경 전과 같아야 한다** — 실행 레인은 제약을 하나씩만 내므로 순차 집행이 동작을 안 바꾼다. 다르면 그 자체가 발견이다(어딘가 제약 벡터가 둘 이상이었다는 뜻).

- [ ] **Step 5: 커밋**

```bash
git add src/respec/replan.jl test/respec_sequential_enact.jl
git commit -m "fix(respec): enact every constraint, not just the first match"
```

---

## Task C2: MILP 제약 문법 (L2-a) + 행동공간 축소 — **5시간**

spec §5-4 · §5-8. 두 가지를 **한 태스크에서** 한다:
1. `(t0, tF, Xa)` 위의 제약 문법을 노출한다 — `ForbidWindow`·`ForbidAgent` 가 그 인스턴스다
2. 🔴 **LLM 이 emit 할 수 있는 kind 를 5종으로 줄인다** (D-9)

둘을 나누면 안 되는 이유: 문법 없이 kind 를 빼면 그 사이에 `L_dsl` 이 표현력을 잃고, kind 를
안 빼고 문법만 넣으면 같은 일을 하는 후보가 둘이 되어 LLM 이 어느 쪽으로 새는지가 측정 잡음이 된다.

⚠️ **Julia 타입은 지우지 않는다.** 실측한 내부 생산자:
`ForbidAgent` → `src/navigator/baselines.jl:173·192·201` · `src/respec/reassign.jl` ·
`ForbidWindow` → `tools/dev_session.jl` · `tools/tests.jl`.
지우는 것은 **행동공간의 표면적**(= `schema.py` union + `llm_bridge.jl` 파서 스위치)뿐이다.

**Files:**
- Modify: `src/respec/spec_dsl.jl` (`VarRef` · `LinearConstraint` · `Disjunction`)
- Modify: `src/respec/compiler.jl` (두 컴파일 메서드)
- Modify: `src/respec/verifier.jl` (`referenced_ids`)
- Modify: `src/respec/llm_service/schema.py` (Pydantic 모델 **추가 2 · 제거 5**)
- Modify: `src/respec/llm_bridge.jl` (파서 스위치 — 같은 5종 제거)
- Test: `test/respec_grammar.jl`, `test/respec_action_space.jl` (둘 다 신규)

**Interfaces:**
- Produces:
  - `VarRef(kind::Symbol, node::AbstractID, node2::Union{Nothing,AbstractID})` — `kind ∈ {:t0, :tF, :xa}`
  - `LinearConstraint(terms::Vector{Tuple{Float64,VarRef}}, rel::Symbol, rhs::Float64)` — `rel ∈ {:le, :ge, :eq}`
  - `Disjunction(left::LinearConstraint, right::LinearConstraint)`
  - `compile_constraint!(model, t0, tF, Xa, sched, cs)` 두 메서드
  - `referenced_ids(cs)` 두 메서드
- 🔴 **제거(행동공간에서만)**: `ForbidZone` · `ReformTeam` · `ForbidAgent` · `ForbidWindow` ·
  `DeprioritizeAgent` — `schema.py` 와 `llm_bridge.jl` 파서에서. **타입과 컴파일러는 그대로 둔다**

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/respec_grammar.jl
# 🔴 문법이 **진짜로 제약을 추가하는가.** 이 레포의 대표적 실패 모양이 "hollow admit" —
# 컴파일이 0개 제약을 내고도 통과하는 것이다. 개수와 효과를 둘 다 본다.
#   julia +lts --project=. test/respec_grammar.jl
using ConstructionBots, Test
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

env, _ = _fault_fixture()
sched  = env.sched
v      = first(_schedulable_vertices(env))
nid    = CB.get_vtx_id(sched, v)

@testset "문법이 타입 검사를 통과한다" begin
    lc = CB.LinearConstraint([(1.0, CB.VarRef(:tF, nid, nothing))], :le, 42.0)
    @test lc isa CB.ConstraintSpec
    @test CB.referenced_ids(lc) == (nid,)
    dj = CB.Disjunction(lc, CB.LinearConstraint([(1.0, CB.VarRef(:t0, nid, nothing))], :ge, 99.0))
    @test dj isa CB.ConstraintSpec
    @test nid in CB.referenced_ids(dj)
end

@testset "🔴 컴파일이 0 이 아닌 제약을 낸다 (hollow admit 방지)" begin
    lc = CB.LinearConstraint([(1.0, CB.VarRef(:tF, nid, nothing))], :le, 42.0)
    n  = _count_added_constraints(env, lc)
    @test n >= 1
    dj = CB.Disjunction(lc, CB.LinearConstraint([(1.0, CB.VarRef(:t0, nid, nothing))], :ge, 99.0))
    @test _count_added_constraints(env, dj) >= 2       # Big-M 이접은 제약 둘 + 이진변수 하나
end

@testset "🔴 문법 왕복 — ForbidWindow 와 같은 해를 낸다 (게이트 N-G8)" begin
    fw = CB.ForbidWindow(nid, 10.0, 20.0)
    dj = CB.Disjunction(
        CB.LinearConstraint([(1.0, CB.VarRef(:tF, nid, nothing))], :le, 10.0),
        CB.LinearConstraint([(1.0, CB.VarRef(:t0, nid, nothing))], :ge, 20.0))
    @test _solved_times(env, fw) ≈ _solved_times(env, dj) rtol = 1e-6
end

@testset "🔴 문법 밖은 거부한다" begin
    @test_throws Exception CB.VarRef(:bogus, nid, nothing)
    @test_throws Exception CB.LinearConstraint([(1.0, CB.VarRef(:t0, nid, nothing))], :lt, 1.0)
    # xa 는 노드 둘을 요구한다 — 하나만 주면 죽는다
    @test_throws Exception CB.VarRef(:xa, nid, nothing)
end
```

`_count_added_constraints(env, cs)` 와 `_solved_times(env, cs)` 는 `smdp_fixtures.jl` 에 둔다:
전자는 `formulate_milp(...; extra_constraints = RespecProposal([cs]))` 전후의
`num_constraints(model; count_variable_in_set_constraints = false)` 차이를 세고, 후자는
`optimize!` 후 `value.(model[:t0])` 를 돌려준다.

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/respec_grammar.jl`
Expected: FAIL with `UndefVarError: VarRef not defined`

- [ ] **Step 3: 문법 타입을 정의한다**

`src/respec/spec_dsl.jl` 에 추가한다:

```julia
"""
    VarRef(kind, node, node2)

MILP 결정변수 하나에 대한 참조. `kind` 는 셋뿐이다:
  `:t0` → `t0[v]`   (그 노드의 시작시각)
  `:tF` → `tF[v]`   (그 노드의 종료시각)
  `:xa` → `Xa[u,v]` (배정 후보 엣지. `node2` 필수)

🔴 **정점 인덱스가 아니라 `AbstractID` 로 참조한다.** 그래프 수술이 정점 번호를 재부여하므로
인덱스로 적은 제약은 수술 뒤에 엉뚱한 노드를 가리킨다. 기존 `ForbidWindow.node` 와 같은 규약이다.
"""
struct VarRef
    kind::Symbol
    node::AbstractID
    node2::Union{Nothing,AbstractID}
    function VarRef(kind::Symbol, node::AbstractID, node2 = nothing)
        kind in (:t0, :tF, :xa) ||
            error("VarRef: kind 는 :t0 | :tF | :xa 뿐이다 (받은 값: $(kind))")
        kind === :xa && node2 === nothing &&
            error("VarRef: :xa 는 노드 둘을 요구한다 (Xa[u,v])")
        kind !== :xa && node2 !== nothing &&
            error("VarRef: $(kind) 는 노드 하나만 받는다")
        return new(kind, node, node2)
    end
end

"""
    LinearConstraint(terms, rel, rhs)

`Σ cᵢ·varᵢ  ⋛  rhs`. `rel ∈ {:le, :ge, :eq}`.

이것이 **L2-a 의 전부**다(spec §5-4). `ForbidAgent` 는 `Xa[u,v] = 0` 들의 모음이고
`ForbidWindow` 는 아래 `Disjunction` 이다 — 둘은 별개의 kind 가 아니라 이 문법의 인스턴스다.
LLM 이 여기서 **아무도 안 짠 제약**을 만들 수 있고, 그것을 안전하게 만드는 것은
`verifier.jl:83` 의 일반 `verify()` 다(kind 를 안 본다).
"""
struct LinearConstraint <: ConstraintSpec
    terms::Vector{Tuple{Float64,VarRef}}
    rel::Symbol
    rhs::Float64
    function LinearConstraint(terms, rel::Symbol, rhs::Real)
        rel in (:le, :ge, :eq) ||
            error("LinearConstraint: rel 은 :le | :ge | :eq 뿐이다 (받은 값: $(rel))")
        isempty(terms) && error("LinearConstraint: 항이 없다 — 0개 제약은 hollow admit 이다")
        return new(collect(Tuple{Float64,VarRef}, terms), rel, Float64(rhs))
    end
end

"""
    Disjunction(left, right)

`left ∨ right`. Big-M + 이진변수로 컴파일된다. `ForbidWindow(v, t_lo, t_hi)` 가 정확히
`Disjunction(tF[v] ≤ t_lo, t0[v] ≥ t_hi)` 다.
"""
struct Disjunction <: ConstraintSpec
    left::LinearConstraint
    right::LinearConstraint
end
```

- [ ] **Step 4: 컴파일과 `referenced_ids` 를 구현한다**

`src/respec/compiler.jl` 에 추가한다:

```julia
_var_of(t0, tF, Xa, sched, r::VarRef) =
    r.kind === :t0 ? t0[get_vtx(sched, r.node)] :
    r.kind === :tF ? tF[get_vtx(sched, r.node)] :
                     Xa[get_vtx(sched, r.node), get_vtx(sched, r.node2)]

_lin_expr(t0, tF, Xa, sched, cs::LinearConstraint) =
    sum(c * _var_of(t0, tF, Xa, sched, r) for (c, r) in cs.terms)

function compile_constraint!(model, t0, tF, Xa, sched, cs::LinearConstraint)
    e = _lin_expr(t0, tF, Xa, sched, cs)
    cs.rel === :le && @constraint(model, e <= cs.rhs)
    cs.rel === :ge && @constraint(model, e >= cs.rhs)
    cs.rel === :eq && @constraint(model, e == cs.rhs)
    return 1
end

function compile_constraint!(model, t0, tF, Xa, sched, cs::Disjunction)
    Mm = 1e5                                   # ForbidWindow 와 **같은** Big-M 상수
    b  = @variable(model, binary = true)
    l  = _lin_expr(t0, tF, Xa, sched, cs.left)
    r  = _lin_expr(t0, tF, Xa, sched, cs.right)
    # b == 1 → left 활성, b == 0 → right 활성
    cs.left.rel  === :le ? @constraint(model, l <= cs.left.rhs  + Mm * (1 - b)) :
    cs.left.rel  === :ge ? @constraint(model, l >= cs.left.rhs  - Mm * (1 - b)) :
                           @constraint(model, l == cs.left.rhs)
    cs.right.rel === :le ? @constraint(model, r <= cs.right.rhs + Mm * b) :
    cs.right.rel === :ge ? @constraint(model, r >= cs.right.rhs - Mm * b) :
                           @constraint(model, r == cs.right.rhs)
    return 2
end
```

`src/respec/verifier.jl` 의 `referenced_ids` 옆에:

```julia
referenced_ids(cs::LinearConstraint) =
    Tuple(unique(vcat([r.node for (_, r) in cs.terms],
                      [r.node2 for (_, r) in cs.terms if r.node2 !== nothing])))
referenced_ids(cs::Disjunction) =
    Tuple(unique(vcat(collect(referenced_ids(cs.left)), collect(referenced_ids(cs.right)))))
```

- [ ] **Step 4b: 🔴 행동공간을 5종으로 줄인다 (D-9)**

```julia
# test/respec_action_space.jl
# 행동공간은 **LLM 이 emit 할 수 있는 것**이다. 타입이 존재하는 것과는 다르다.
#   julia +lts --project=. test/respec_action_space.jl
using ConstructionBots, Test
const CB = ConstructionBots

const EMITTABLE = Set(["ReplaceAgent", "SwapBattery", "TranslateBuild",
                       "LinearConstraint", "Disjunction"])
const REMOVED   = Set(["ForbidZone", "ReformTeam", "ForbidAgent", "ForbidWindow",
                       "DeprioritizeAgent"])

@testset "파서가 받는 kind 가 정확히 5종이다" begin
    for k in EMITTABLE
        @test CB.parse_proposal(_stub_json(k)) isa CB.RespecProposal
    end
end

@testset "🔴 뺀 kind 를 내면 **죽는다** (조용히 무시하지 않는다)" begin
    for k in REMOVED
        @test_throws Exception CB.parse_proposal(_stub_json(k))
    end
end

@testset "🔴 타입과 컴파일러는 살아 있다 (엔진이 쓴다)" begin
    # 행동공간에서 뺐다고 타입을 지우면 baselines.jl 과 reassign.jl 이 깨진다.
    @test isdefined(CB, :ForbidAgent)
    @test isdefined(CB, :ForbidWindow)
    @test hasmethod(CB.compile_constraint!,
                    Tuple{Any,Any,Any,Any,Any,CB.ForbidAgent})
end

@testset "🔴 엔진 내부 경로가 여전히 돈다 (회귀)" begin
    # fault_robot_and_reassign! 은 내부에서 ForbidAgent 를 만든다 — 파서를 좁힌 것이
    # 그 경로에 닿으면 안 된다.
    env, _ = _fault_fixture()
    r = CB.fault_robot_and_reassign!(env, _faulted_robot(env); resume = true)
    @test r !== nothing
end
```

`_stub_json(kind)` 는 그 kind 의 최소 유효 JSON 을 만든다(`smdp_fixtures.jl`).

**구현**: `schema.py` 의 discriminated union 에서 다섯 클래스를 빼고(클래스 정의는 주석과 함께
남겨 두되 union 에서 제외), `llm_bridge.jl:283-292` 의 `kind` 스위치에서 다섯 분기를 제거한다.
🔴 **제거된 kind 가 오면 `error()` 로 죽는다** — `nothing` 을 돌려주면 LLM 이 뺀 팔을 내도
조용히 NOOP 으로 무너지고, 그건 이 레포가 `valid_actions` 문지기에서 이미 데인 실패 모양이다.

각 제거 자리에 근거를 한 줄씩 남긴다 (spec §5-8 의 표를 그대로):

```julia
# 2026-08-21 D-9: 행동공간에서 뺐다. **타입은 남는다**(엔진 내부 생산자가 있다).
#   ForbidZone        도메인 공집합 (closed≈46 이후 n_restage_feasible == 0)
#   ReformTeam        은퇴 — 복구가 maybe_unwedge_nominal! 로 명목 레인에 이관
#   ForbidAgent       D-7 아래 ReplaceAgent 에 약우월로 지배
#   ForbidWindow      대응 사건 없음 (도착 시점이 확률변수다)
#   DeprioritizeAgent 선택 0회. cell 위험은 battery kind 로 도착하므로 SwapBattery 가 답이다
#                     (_hz_fire_cell! → battery_action, hazard.jl:583)
```

- [ ] **Step 5: `schema.py` 에 노출한다**

`src/respec/llm_service/schema.py` 에 `LinearConstraint`·`Disjunction` Pydantic 모델을 추가하고 discriminated union 에 넣는다. docstring 에 **무엇을 참조할 수 있는지**(프롬프트의 NODES/AGENTS 목록에서 echo)와 **왜 이것이 신설 경로인지**를 적는다. `llm_bridge.jl` 의 파서에 두 kind 를 추가한다.

- [ ] **Step 6: 통과 + 회귀 확인**

Run:
```bash
julia +lts --project=. test/respec_grammar.jl
julia +lts --project=. test/respec_determinism_smoke.jl
```
Expected: 둘 다 PASS

- [ ] **Step 7: 커밋**

```bash
git add src/respec/spec_dsl.jl src/respec/compiler.jl src/respec/verifier.jl \
        src/respec/llm_bridge.jl src/respec/llm_service/schema.py \
        test/respec_grammar.jl test/respec_action_space.jl
git commit -m "feat(respec): expose the constraint grammar and cut the emittable space to five kinds"
```

---

## Task C3: `TranslateBuild` 원시연산 (L2-b) — **2.5시간**

spec §5-5. 🔴 `RelocateBuild(zone)` 은 **action 이 아니라 solver 다** — `translate_whole_build!` 이 `_find_min_translation` 으로 Δ 를 스스로 찾는다. LLM 에 그걸 주면 신설이 아니라 **감춰 둔 매크로를 도로 고르는 것**이다.

**Files:**
- Modify: `src/respec/spec_dsl.jl` (`TranslateBuild`), `src/respec/compiler.jl` (no-op 메서드), `src/respec/replan.jl` (dispatch 분기), `src/respec/llm_service/schema.py`
- Test: `test/respec_translate_build.jl` (신규)

**Interfaces:**
- Produces: `TranslateBuild(dx::Float64, dy::Float64) <: ConstraintSpec`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/respec_translate_build.jl
# LLM 이 Δ 를 **직접 정한다**. 알고리즘이 찾아 주는 게 아니다.
#   julia +lts --project=. test/respec_translate_build.jl
using ConstructionBots, Test
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

@testset "TranslateBuild 가 정확히 그 Δ 만큼 옮긴다" begin
    env, _ = _zone_fixture()
    before = _assembly_poses(env)
    CB.maybe_respecify!(env, CB.RespecProposal(CB.ConstraintSpec[CB.TranslateBuild(3.0, -1.5)]))
    after = _assembly_poses(env)
    for k in keys(before)
        @test after[k][1] ≈ before[k][1] + 3.0 atol = 1e-9
        @test after[k][2] ≈ before[k][2] - 1.5 atol = 1e-9
    end
end

@testset "🔴 Δ 가 0 이면 거부한다 (무성 no-op 방지)" begin
    env, _ = _zone_fixture()
    st = CB.maybe_respecify!(env, CB.RespecProposal(CB.ConstraintSpec[CB.TranslateBuild(0.0, 0.0)]))
    @test st === :fallback
end

@testset "🔴 baseline 과 비교 가능하다" begin
    # _find_min_translation 이 낸 최소 이동이 baseline 이다. LLM 의 Δ 를 그것과 잰다.
    env, _ = _zone_fixture()
    Δ0 = CB._find_min_translation(env; zone_keys = collect(keys(CB.RESTRICTION_ZONES[])))
    @test Δ0 !== nothing
    @test CB.translate_clears_zones(env, Δ0)              # baseline 은 당연히 비켜야 한다
    @test !CB.translate_clears_zones(env, (0.0, 0.0))     # 안 움직이면 안 비켜진다
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/respec_translate_build.jl`
Expected: FAIL with `UndefVarError: TranslateBuild not defined`

- [ ] **Step 3: 구현한다**

`src/respec/spec_dsl.jl`:

```julia
"""
    TranslateBuild(dx, dy)

빌드 전체를 **주어진** 강체 변위 `(dx, dy)` 만큼 옮긴다.

🔴 `RelocateBuild(zone)` 와의 차이가 이 계획의 요점이다(spec §5-5): `RelocateBuild` 는
`translate_whole_build!` 이 `_find_min_translation` 으로 Δ 를 **스스로 찾는** solver 다.
`TranslateBuild` 는 Δ 를 **제안자가 정한다** — 그래서 LLM 이 ZONES 기하를 보고 "빌드가
비켜야 하고 이만큼이면 된다" 를 유도해야 하고, 그것이 L2 신설이다.

안전은 `verify_translate`(일반 기하 검증기)가 담당한다 — zone 이름을 안 받으므로 kind 별
전제조건이 없고, 결과 배치가 조건을 만족하는지만 본다.
"""
struct TranslateBuild <: ConstraintSpec
    dx::Float64
    dy::Float64
end
```

`src/respec/compiler.jl` 에 no-op 메서드 (닫힌 합집합 계약 유지):

```julia
# --- TranslateBuild: SPATIAL — compiles to NOTHING here -------------------------
# RelocateBuild/ForbidZone 과 같은 티어다: 기하 수술이지 타이밍/배정 제약이 아니다.
compile_constraint!(model, t0, tF, Xa, sched, cs::TranslateBuild) = 0
```

`src/respec/replan.jl` 의 `_enact_one!` 에 분기를 추가한다(C1 이 만든 루프 안):

```julia
if any(c -> c isa TranslateBuild, one.constraints)
    push!(ENACT_ORDER_LOG[], :translate)
    c = first(c for c in one.constraints if c isa TranslateBuild)
    (c.dx == 0.0 && c.dy == 0.0) && return (:rejected, "zero displacement")
    v = verify_translate(one, env)
    v isa Reject && return (:rejected, v.reason)
    _apply_uniform_translation!(env, (c.dx, c.dy))
    reset_cache_resume!(env.cache, env.sched)
    return (:ok, "translated by ($(c.dx), $(c.dy))")
end
```

`_enact_rank` 에 `c isa TranslateBuild` 를 rank 1 로 넣는다(C1 의 코드에 이미 있다).

`schema.py` 에 `TranslateBuild` 를 추가한다 — docstring 에 **"좌표를 지어내지 말고 ZONES 섹션의 기하에서 유도하라"** 를 적는다.

- [ ] **Step 4: 통과 확인 + 커밋**

Run: `julia +lts --project=. test/respec_translate_build.jl`
Expected: PASS (`verify_translate` 는 C4 가 만든다 — 그 전까지는 이 태스크의 시험 중
"거부" 케이스가 실패한다. C3 · C4 를 **한 커밋으로 묶어도 된다**.)

```bash
git add src/respec/spec_dsl.jl src/respec/compiler.jl src/respec/replan.jl \
        src/respec/llm_service/schema.py test/respec_translate_build.jl
git commit -m "feat(respec): TranslateBuild -- the primitive under RelocateBuild, with the delta free"
```

---

## Task C4: 일반 기하 검증기 — **3시간**

spec §5-5 (3). `verify()` 가 MILP 티어를 kind 무관으로 검증하듯, 기하 티어에도 kind 를 안 보는 검증기를 둔다.

**Files:**
- Modify: `src/respec/verifier.jl`
- Test: `test/respec_verify_translate.jl` (신규)

**Interfaces:**
- Produces:
  - `translate_clears_zones(env, Δ::NTuple{2,Float64}) -> Bool`
  - `verify_translate(proposal::RespecProposal, env) -> Union{Admit,Reject}`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/respec_verify_translate.jl
# 🔴 이 검증기는 kind 를 안 본다. "결과 배치가 조건을 만족하는가" 만 본다 —
# 그것이 신설된 행동을 안전하게 만드는 방법이다(spec §5-2 의 기하 티어 대응물).
#   julia +lts --project=. test/respec_verify_translate.jl
using ConstructionBots, Test
const CB = ConstructionBots
include(joinpath(@__DIR__, "smdp_fixtures.jl"))

env, _ = _zone_fixture()
_p(dx, dy) = CB.RespecProposal(CB.ConstraintSpec[CB.TranslateBuild(dx, dy)])

@testset "비키는 Δ 는 통과, 안 비키는 Δ 는 거부" begin
    Δ0 = CB._find_min_translation(env; zone_keys = collect(keys(CB.RESTRICTION_ZONES[])))
    @test CB.verify_translate(_p(Δ0[1], Δ0[2]), env) isa CB.Admit
    @test CB.verify_translate(_p(0.0, 0.0), env)     isa CB.Reject
end

@testset "🔴 검증기가 env 를 바꾸지 않는다" begin
    before = _assembly_poses(env)
    CB.verify_translate(_p(7.0, 7.0), env)
    @test _assembly_poses(env) == before
end

@testset "🔴 터무니없는 Δ 는 거부한다" begin
    # zone 은 비키지만 작업영역이 도달 불가로 나가는 경우
    r = CB.verify_translate(_p(1e6, 1e6), env)
    @test r isa CB.Reject
end

@testset "🔴 verify 는 읽기 전용이다 (spec §5-1b)" begin
    # verify() 가 상태를 안 바꾼다는 것은 **가정이지 실측이 아니었다.** 시행풀이가 전역
    # (HiGHS 상태·RNG)을 건드리면 "관측이 세계를 바꾸는" 사고가 된다 — simstate_of 에
    # 읽기 전용 게이트를 둔 것과 같은 이유다. 통과·거부 **양쪽**에서 본다.
    inv = CB.build_invariant(env)
    for prop in (_p(3.0, -1.5), _p(0.0, 0.0))          # 통과 후보 · 거부 확정
        h0 = CB.state_hash(CB.simstate_of(env))
        CB.verify(prop, env, inv)
        @test CB.state_hash(CB.simstate_of(env)) == h0
    end
end

@testset "🔴 음성 대조 — 검증기가 상수 Admit 이 아니다" begin
    n_admit = count(d -> CB.verify_translate(_p(d, 0.0), env) isa CB.Admit, 0.0:1.0:20.0)
    @test 0 < n_admit < 21     # 전부 통과도 전부 거부도 아니어야 한다
end
```

- [ ] **Step 2: 실패를 확인한다**

Run: `julia +lts --project=. test/respec_verify_translate.jl`
Expected: FAIL with `UndefVarError: verify_translate not defined`

- [ ] **Step 3: 구현한다**

```julia
"""
    translate_clears_zones(env, Δ) -> Bool

빌드 전체를 `Δ` 만큼 옮겼을 때 **남은 작업**이 모든 제한구역을 벗어나는가.
`_future_work_discs(env)` 를 그대로 쓴다 — `restage_zone.jl` 이 이미 "미완 스케줄이 도달해야
하는 목표 + 비루트 staging 작업영역" 으로 정의해 둔 집합이고, 여기서 다시 정의하면 두 곳의
기준이 갈린다. **env 를 수정하지 않는다** — 원판을 옮겨 보고 버리는 것이 아니라 좌표만 더한다.
"""
function translate_clears_zones(env, Δ::NTuple{2,Float64})
    for (c, r) in _future_work_discs(env)
        cx, cy = c[1] + Δ[1], c[2] + Δ[2]
        for (_, ball) in RESTRICTION_ZONES[]
            hypot(cx - ball.center[1], cy - ball.center[2]) < (r + ball.radius) && return false
        end
    end
    return true
end

"""
    verify_translate(proposal, env) -> Admit | Reject

기하 티어의 **일반** 검증기. kind 별 전제조건을 안 본다 — 결과 배치가 조건을 만족하는지만 본다.
조건 셋:
  (1) 변위가 0 이 아니다        — 0 은 NOOP 과 바이트 동일한 **무성 no-op** 이다
  (2) 모든 zone 을 벗어난다     — `translate_clears_zones`
  (3) 작업영역이 경계 안에 남는다 — `_within_workspace_bounds`

🔴 (1)이 이 레포의 반복된 실패 모양을 막는다: `enact_applied = true` 는 "효과 지점에 도달했다"
이지 "세계가 바뀌었다" 가 아니다. 도달하고도 아무것도 안 바꾸는 팔은 로그상 성공으로 보인다.
"""
function verify_translate(proposal::RespecProposal, env)
    cs = filter(c -> c isa TranslateBuild, proposal.constraints)
    isempty(cs) && return Reject(:not_translate, "no TranslateBuild in proposal")
    length(cs) == 1 || return Reject(:ambiguous, "more than one TranslateBuild")
    c = first(cs)
    Δ = (c.dx, c.dy)
    (Δ[1] == 0.0 && Δ[2] == 0.0) && return Reject(:zero_displacement, "silent no-op")
    translate_clears_zones(env, Δ) ||
        return Reject(:residual_blocked, "future work still intersects a zone after Δ=$(Δ)")
    _within_workspace_bounds(env, Δ) ||
        return Reject(:out_of_bounds, "translated build leaves the workspace")
    return Admit(proposal, 1)
end
```

⚠️ `_future_work_discs` · `_within_workspace_bounds` 의 실제 이름을
`grep -n "_future_work_discs\|bounds" src/respec/restage_zone.jl | head` 로 확인한다. 후자가
없으면 **새로 만들되 `_build_footprint(env)` 와 씬 경계에서 유도한다** — 숫자를 지어내지 않는다.

- [ ] **Step 4: 통과 확인 + 커밋**

Run:
```bash
julia +lts --project=. test/respec_verify_translate.jl
julia +lts --project=. test/respec_translate_build.jl
```
Expected: 둘 다 PASS

```bash
git add src/respec/verifier.jl test/respec_verify_translate.jl
git commit -m "feat(respec): a kind-agnostic geometric verifier for synthesized displacements"
```

---

## Task C5: 게이트 N-G7 — 다중 제약 집행 — **2시간**

**Files:**
- Create: `tools/monitor/check_multi_enact.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng7.py`

**Interfaces:**
- Consumes: `maybe_respecify!`(C1), `generate`(T12)
- Produces: `results/smdp/ng7_multi_enact.json`

- [ ] **Step 1: 무엇을 검사하는지 못박는다**

🔴 **음성 대조가 이 게이트의 전부다.** CLAUDE.md 실측: 조합 팔 5·6 은 65/65 instance 에서 `5≡4`, `6≡2` 로 **정보량이 0** 이었다. 같은 사고를 여기서 미리 잡는다:

> 제약 2개 proposal `[A, B]` 의 종단 결과가 `[A]` 단독·`[B]` 단독과 **둘 다 달라야** 한다.
> 하나와라도 같으면 그 조합은 정보를 안 나른다.

- [ ] **Step 2: 측정 스크립트를 쓴다**

`tools/monitor/check_multi_enact.jl` 이 `fault_zone` 픽스처에서 세 판을 **순차로**(HiGHS 경합 회피) 굴린다: `[TranslateBuild]` · `[ReplaceAgent]` · `[TranslateBuild, ReplaceAgent]`. 각 판의 종단 `(makespan, energy_J, n_closed, state_hash)` 를 JSON 으로 낸다. 시드·커밋·디렉토리를 전부 고정한다.

- [ ] **Step 3: 게이트를 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G7 — 다중 제약 집행이 정보를 나르는가.

CLAUDE.md 실측 배경: 조합 팔 5·6 은 65/65 instance 에서 단독 팔과 **바이트 동일**했다
(5≡4, 6≡2). 그것은 조합이 실패한 게 아니라 **집행 경로가 없어서** 조합이 단독으로
무너진 것이었다. 순차 집행을 켠 뒤에도 같은 증상이면 무언가가 여전히 버려지고 있다.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng7.py results/smdp/ng7_multi_enact.json
"""
import json, sys

def main(path):
    d = json.load(open(path))
    a, b, ab = d["only_a"], d["only_b"], d["both"]
    print(f"only_a  = {a}")
    print(f"only_b  = {b}")
    print(f"both    = {ab}")
    ok = True
    if ab["state_hash"] == a["state_hash"]:
        print("FAIL: [A,B] 가 [A] 단독과 같다 — B 가 버려졌다"); ok = False
    if ab["state_hash"] == b["state_hash"]:
        print("FAIL: [A,B] 가 [B] 단독과 같다 — A 가 버려졌다"); ok = False
    if a["state_hash"] == b["state_hash"]:
        print("FAIL: 두 단독 팔이 서로 같다 — 픽스처가 두 팔을 구분하지 못한다 "
              "(게이트가 항진적이다)"); ok = False
    for r in d["enact_report"]:
        print(f"  {r['kind']}: {r['status']} ({r['detail']})")
    if any(r["status"] != "ok" for r in d["enact_report"]):
        print("NOTE: 일부 제약이 거부됐다 — 위 사유를 읽고 의도된 거부인지 확인할 것")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 4: 돌린다**

Run:
```bash
julia +lts --project=. tools/monitor/check_multi_enact.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng7.py results/smdp/ng7_multi_enact.json
```
Expected: `PASS`

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/check_multi_enact.jl wm4spacecraft_manufacturing/smdp/gate_ng7.py \
        results/smdp/ng7_multi_enact.json
git commit -m "test(respec): gate that a two-constraint proposal differs from both singletons"
```

---

## Task C6: 게이트 N-G8 — 문법 왕복 — **1.5시간**

**Files:**
- Create: `tools/monitor/check_grammar_roundtrip.jl`, `wm4spacecraft_manufacturing/smdp/gate_ng8.py`

**Interfaces:**
- Consumes: `LinearConstraint`·`Disjunction`(C2)
- Produces: `results/smdp/ng8_roundtrip.json`

- [ ] **Step 1: 무엇을 검사하는지 못박는다**

문법이 **기존 kind 를 재현할 수 있어야** 그 문법이 충분히 표현적이라고 말할 수 있다:

| 기존 kind | 문법 표현 |
|---|---|
| `ForbidWindow(v, t_lo, t_hi)` | `Disjunction(tF[v] ≤ t_lo, t0[v] ≥ t_hi)` |
| `ForbidAgent(r)` | `LinearConstraint([(1.0, Xa[u,v])], :eq, 0.0)` × frontier 후보 엣지 |

두 표현이 **같은 제약 개수와 같은 해**를 내면 문법이 그 kind 를 포함한다.

- [ ] **Step 2: 측정 스크립트와 게이트를 쓴다**

`tools/monitor/check_grammar_roundtrip.jl` 이 실제 씬에서 정점 하나·로봇 하나를 골라 두 쌍을 만들고, 각각 `formulate_milp` → `optimize!` 해서 `(n_constraints, objective_value, t0_vector_hash)` 를 JSON 으로 낸다.

```python
#!/usr/bin/env python3
"""게이트 N-G8 — 노출한 문법이 기존 kind 를 재현하는가.

재현 못 하면 그 문법은 `L_dsl` 보다 좁고, "LLM 이 새 제약을 만든다" 는 주장이
"LLM 이 더 약한 제약을 만든다" 가 된다.

🔴 음성 대조: n_constraints 가 0 이면 hollow admit 이다. 해가 같은 것보다 **먼저** 본다.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng8.py results/smdp/ng8_roundtrip.json
"""
import json, sys

RTOL = 1e-6

def main(path):
    d = json.load(open(path)); ok = True
    for name, pair in d["pairs"].items():
        native, grammar = pair["native"], pair["grammar"]
        print(f"{name}: native n={native['n_constraints']} obj={native['objective']:.6f} | "
              f"grammar n={grammar['n_constraints']} obj={grammar['objective']:.6f}")
        if native["n_constraints"] == 0 or grammar["n_constraints"] == 0:
            print(f"  FAIL: 0개 제약 — hollow admit"); ok = False; continue
        rel = abs(native["objective"] - grammar["objective"]) / max(abs(native["objective"]), 1e-12)
        if rel > RTOL:
            print(f"  FAIL: 목적값이 다르다 (rel={rel:.2e})"); ok = False
        if native["t0_hash"] != grammar["t0_hash"]:
            print(f"  NOTE: 목적값은 같은데 해가 다르다 — 동점 해다. 목적값 일치로 통과시킨다")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 3: 돌린다**

Run:
```bash
julia +lts --project=. tools/monitor/check_grammar_roundtrip.jl
python3 wm4spacecraft_manufacturing/smdp/gate_ng8.py results/smdp/ng8_roundtrip.json
```
Expected: `PASS`

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/check_grammar_roundtrip.jl wm4spacecraft_manufacturing/smdp/gate_ng8.py \
        results/smdp/ng8_roundtrip.json
git commit -m "test(respec): gate that the exposed grammar reproduces the kinds it generalizes"
```

---

# Phase 5 — 교정

## Task C7: 워치독 재설정 — **1.5시간** (+ 스윕 대기 ~40분)

🔴 선행 계획 Task 15 는 `DEMO_SPARES × stall_limit` 2차원 격자였다. **D-7 이 예비 축을 없앴으므로** 워치독 축만 남는다. 다만 **예비 수는 가정이 성립할 만큼 넉넉하게** 고정해야 하고, 그 값은 T12 의 가드가 안 터지는 최솟값으로 정한다.

**Files:**
- Create: `tools/monitor/sweep_watchdog.jl`
- Modify: `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md` §10

- [ ] **Step 1: 격자를 정한다**

`stall_limit ∈ {2500, 5000}` × 5시드 = 10판. `DEMO_SPARES` 는 **고정**하되 두 후보(4, 8)에서 T12 가드가 터지는지만 먼저 본다.

- [ ] **Step 2: 돌리고 잰다**

Run: `julia +lts --project=. tools/monitor/sweep_watchdog.jl`

⚠️ **순차 실행**한다(동시 실행은 HiGHS 경합 + OOM).

측정 둘: 완주율, 그리고 **`n_closed / n_total`**.

- [ ] **Step 3: 고른다**

기준: 완주율 **60~85%** 인 칸. 100% 면 사건이 희소해 팔 간 차이가 안 보이고, 30% 미만이면 `J` 가 실패 분기에 지배당한다.

⚠️ 알려진 함정: hazard-on 판은 빌드가 죽은 뒤에도 각 사건이 워치독을 **리셋**해서 makespan 의 57~68% 가 죽은 빌드 위의 패딩이었다(실측). **완주율만 보지 말고 `n_closed / n_total` 도 본다.**

- [ ] **Step 4: 값과 근거를 spec §10 에 적고 커밋**

```bash
git add tools/monitor/sweep_watchdog.jl results/smdp/watchdog.json \
        docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md
git commit -m "measure(smdp): pick the watchdog under the plentiful-spares assumption"
```

---

## Task C8: λ 교정 + 게이트 N-G3 — **3시간** (+ 스윕 대기 ~5~8시간)

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
Expected: T6 의 새 `generation`, `v3-4arms`. **다르면 스윕을 시작하지 않는다** — 구세대 도장으로 5~8시간을 태우게 된다.

- [ ] **Step 1b: `require_vocab` 을 생산자에 배선한다**

Step 1 은 사람이 눈으로 보는 검사다. 도장은 지금 **write-only** 이고 소비처가 0개라, 서로 다른 세대의 도장이 한 파일에 섞여도 아무도 안 잡는다(실측). 4팔 재번호로 id 0..3 이 연속이 되면서 구세대 행이 **조용히 읽히므로** 도장이 유일한 방어선이다.

스윕 생산자가 입력 산출물을 읽는 자리에 `ActionRegistry.require_vocab(obj, where)` 를 넣는다. 불일치면 **죽는다** — remap 하지 않는다.

```bash
grep -rn "require_vocab" wm4spacecraft_manufacturing/ | grep -v "def \|function "
# 배선 전: 소비처 0개. 배선 뒤: 최소 1개.
```

- [ ] **Step 2: 스윕을 돌린다**

C7 이 고른 워치독·예비 수로, `DEMO_HAZARD=1` · `DEMO_HOTSWAP=1` 을 켜고 돈다.
**⚠️ 라벨 레인은 실행 레인과 같은 세계여야 한다** — `DS_HOTSWAP=1` 을 빠뜨리면 `fault` 발화율이 100% → 23% 로 **에러 없이** 샌다(2026-08-15 실측). 생성된 파일의 `hot_swap` 필드가 `{"enabled": true, "mode": "via_depot"}` 인지 확인한다.

- [ ] **Step 3: 게이트 N-G3 을 쓴다**

```python
#!/usr/bin/env python3
"""게이트 N-G3 — 모델 λ 가 관측 도착률과 맞는가.

정확 표집기를 만들어도 **틀린 λ 를 정확히 표집할 뿐**이다.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng3.py results/smdp/hazard_on_sweep.json
"""
import json, sys
from scipy.stats import chisquare, poisson

MAX_CI_RATIO = 1.8    # CI 상한/하한. 1.8 이면 참값이 예측의 대략 ±35% 안이라는 뜻

def main(path):
    d = json.load(open(path)); ok = True
    for kind in ("fault", "battery", "zone", "cell"):
        obs = d["observed_counts"].get(kind)
        exp = d["expected_counts"].get(kind)
        if obs is None or exp is None:
            print(f"{kind}: FAIL — 관측/기대가 없다. 경쟁위험 넷을 다 세는가?"); ok = False; continue
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

`mtbf_break_s` · `mtbf_cell_s` · `mtbf_zone_s` 를 관측 도착률에 맞춰 조정하고 Step 2~3 을 반복한다. **`zone` 이 특히 미교정이다** — T6 이 넣은 `1800.0` 은 근거 없는 초기값이고, 계획서 B 에서 zone 이 **유일한 OOD** 가 되므로 그 도착률이 곧 OOD 노출량이다.

- [ ] **Step 5: 커밋**

```bash
git add src/smdp/hazard.jl wm4spacecraft_manufacturing/smdp/gate_ng3.py \
        results/smdp/hazard_on_sweep.json
git commit -m "fix(hazard): calibrate all four arrival rates against the hazard-on sweep"
```

---

# 소요시간 요약

| Phase | 태스크 | 집중 작업 | 대기 |
|---|---|---|---|
| 1R | R1, R2, R3, R4 | 9 h | ~25 min |
| 2 | T6, T7, T8, T9, T10 | 14 h | ~30 min |
| 3 | T11, T12, T13, T14 | 11 h | — |
| 4 | C1, C2, C3, C4, C5, C6 | 17 h | — |
| 5 | C7, C8 | 4.5 h | 6~9 h |
| | **합** | **55.5 h** | **6.9~9.9 h** |

리뷰·수정 왕복을 15% 얹으면 **약 64 h 집중 작업**. 하루 5 h 기준 **13 근무일**.

**임계 경로**: R1 → R2 → T7 → T8 → T9(N-G1) → T12 → C1 → C2/C3 → C8.

**멈춤 지점 셋** (여기서 실패하면 다음으로 안 간다):
1. **R3** — `active_is_frontier_frac < 1.0` 또는 `wedge_subset_frac < 1.0` 이면 축소의 근거가 거짓이다
2. **R4** — `deepcopy_ms.median ≥ 50` 이면 spec §5-1 을 다시 설계해야 한다
3. **T9 의 N-G1** — 경량 레인이 엔진과 다른 분포를 내면 그 위의 모든 롤아웃이 다른 세계다

**계획서 B(OOD layer + replay buffer)는 Phase 4 가 끝나야 시작할 수 있다** — escalation 이 `L_prim` 에 닿아야 zone 이 진짜 OOD 가 된다.
