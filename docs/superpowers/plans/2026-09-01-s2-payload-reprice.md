# S2 — payload 재가격(wear-leveling) L2 원시 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SoC 가 낮은 로봇에게 **무거운 화물 작업**만 비싸게 만들어, MILP 재풀이가 그 일을
가까운 고-SoC 로봇으로 옮기게 하는 L2 주조 원시 `reprice_agent_by_payload` 를 만든다.

**Architecture:** payload 축을 전역 에너지 모델(`edge_energy`/`load_power`)이 아니라
`edge_cost_multiplier` 에 **3인자 메서드로 더한다**. 훅이 없으면 기존 2인자와 바이트 동일이다.
로봇 신원은 후보 간선의 `v` 에서, 화물 질량은 `v2` **한 홉 아래**(`FormTransportUnit`)에서
읽는다 — 둘 다 실측으로 확정된 도달 경로다. 재가격은 `release_pending_assignments` 가 후보
간선을 열어둔 동안에만 뜻이 있으므로, 주조 도구의 body 는 release → reprice → commit 셋이다.

**Tech Stack:** Julia 1.10 (LTS), JuMP/HiGHS, `ConstructionBots` 패키지, JSON 원시 레지스트리.

**Spec:** `docs/superpowers/specs/2026-09-01-s2-payload-reprice-design.md`

## Global Constraints

- **기본 바이트 동일.** 새 훅·새 인자는 설치 전에는 기존 동작을 한 비트도 바꾸지 않는다.
  기존 2인자 `edge_cost_multiplier(sched, v)` 는 **시그니처도 본문도 건드리지 않는다**
  (`tools/tests.jl:1270·1374·1376` 의 2인자 단언이 그대로 초록이어야 한다).
- **삼상 규약: "못 쟀다" ≠ 0.** 화물을 못 재면 `nothing` 이고, 그때 배수는 **1.0**(벌하지 않음)
  이다. 0 이나 예외로 접지 않는다.
- **배수는 절대 1.0 미만이 되지 않는다.** 로봇에 인센티브를 주는 축이 아니고, 음의 비용은
  MILP 를 깨뜨린다.
- **정답 누수 금지.** 레지스트리 `mechanism` 에는 **기전만** 적고 "언제 쓰라"·"재풀이를 붙여라"
  는 적지 않는다. `when_to_use` 는 프롬프트에 안 실린다.
- **반환 심볼로 세계 변화를 판정하지 않는다.** 세계가 바뀌었는가의 관측은
  `length(LAST_EDGE_COSTS[]) > 0` 와 **재풀이 전후 배정 엣지 집합의 차이** 둘뿐이다.
- **Julia 시험은 독립 프로세스**로 돈다: `julia +lts --project=. test/<파일>.jl`.
  🔴 2026-09-01 최종 리뷰 F1 정정: "`test/runtests.jl` 에 싣지 않는다" 를 "레포 관례" 로 적었던
  것은 거짓이었다 — `runtests.jl` 은 이미 `run_lego_demo` 로 씬을 짓는 파일을 11개 이상 신고,
  S1 의 자매 게이트 `test/milp_slot_probe_is_pure.jl` 도 `:358` 에 배선돼 있다. 실제 이유는
  **런타임 비용**뿐이다: `payload_edge_multiplier.jl`(~0.9s)·`payload_reprice_install.jl`
  (~1.5s)은 씬을 안 짓고 빨라서 스위트에 배선했고(`test/runtests.jl` 끝부분), 씬을 짓는
  `payload_factor.jl`(~1.5분)·`payload_reprice_changes_plan.jl`(~2분)·
  `payload_release_is_safe.jl`(~7분) 셋은 스위트 시간을 크게 늘리므로 단독 실행으로 남긴다
  (컨트롤러 판단, 관례 아님).
- **`_PAYLOAD_REF = 12.8`** (tractor.mpd 실측 상한). 2026-08-30 계획서의 `2.29` 는 **다른
  픽스처**의 값이라 쓰지 않는다(spec §2-6).
- **커밋은 이 레인의 파일만 스테이징한다.** 작업 트리에 이 레인과 무관한 삭제 변경이 많다 —
  `git add -A` 를 절대 쓰지 않는다.

---

## File Structure

| 파일 | 책임 | 상태 |
|---|---|---|
| `src/essential_tg_coponents.jl` | 3인자 `edge_cost_multiplier` + `EDGE_PAYLOAD_MULTIPLIER` Ref, 호출부 2곳 | 수정 |
| `src/navigator/payload_bias.jl` | `_PAYLOAD_REF` · `_payload_factor` · `candidate_edge_payload_mass` · `payload_edge_multiplier` · `reprice_agent_by_payload!` · `clear_payload_bias!` | **신규** |
| `src/navigator/navigator.jl` | 위 파일 include | 수정 |
| `wm4spacecraft_manufacturing/core/primitive_registry.json` | 알파벳 19 → 20 | 수정 |
| `test/payload_edge_multiplier.jl` | Task 1 게이트 (바이트 동일 + 훅 결선) | **신규** |
| `test/payload_factor.jl` | Task 2 게이트 (순수 함수 + 한 홉 조회 실측) | **신규** |
| `test/payload_reprice_install.jl` | Task 3 게이트 (설치/해제/선택성) | **신규** |
| `test/payload_reprice_changes_plan.jl` | Task 5 게이트 (G-2·G-4, 음성 대조 포함) | **신규** |

---

### Task 0: κ 가 창이 열린 판에서 살아 있는지 먼저 잰다 (코드 변경 없음)

**왜 먼저인가.** spec §9-1. `AUTO_EFFICIENCY_KAPPA` 가 `nothing` 이거나
`LAST_AUTO_EFFICIENCY_W` 가 0 이면 목적함수가 `edge_costs` 를 통째로 버려서, 아래 모든
태스크가 **원리적으로 무효**가 된다. 2026-08-30 이 잰 `LAST_AUTO_EFFICIENCY_W = 0.0` 은
후보 간선이 0 인 판의 관측이라 결론으로 쓸 수 없다.

**Files:**
- Create: `tools/probes/probe_kappa_alive.jl`

**Interfaces:**
- Consumes: `CB.release_pending_assignments!`, `CB.build_invariant`, `CB.formulate_milp`,
  `CB.AUTO_EFFICIENCY_KAPPA`, `CB.LAST_AUTO_EFFICIENCY_W`, `CB.init_objective_weights!`
- Produces: 판정 하나 — κ 가 살아 있으면 Task 1 로, 죽어 있으면 **멈추고 사용자에게 보고**.

- [ ] **Step 1: 프로브를 쓴다**

```julia
# tools/probes/probe_kappa_alive.jl
# 🔴 모든 집계는 함수 안에서 한다(top-level for 의 카운터는 soft scope 로 조용한 0 이 된다).
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots

function main()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2kappa",
                             num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    println("kappa BEFORE init = ", CB.AUTO_EFFICIENCY_KAPPA[])
    CB.init_objective_weights!()
    println("kappa AFTER  init = ", CB.AUTO_EFFICIENCY_KAPPA[])

    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))

    CB.LAST_AUTO_EFFICIENCY_W[] = 0.0
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    ran = !(CB.LAST_EDGE_COSTS[] === sent)
    println("ran_formulate       = ", ran)
    println("n_candidate_edges   = ", ran ? length(CB.LAST_EDGE_COSTS[]) : -1)
    println("LAST_AUTO_EFFICIENCY_W = ", CB.LAST_AUTO_EFFICIENCY_W[])
    println("\n==== 판정 ====")
    println(CB.LAST_AUTO_EFFICIENCY_W[] > 0.0 ?
        "✅ κ 가 살아 있다 — 에너지 항이 목적식에 들어간다. Task 1 로 간다." :
        "🔴 κ 가 죽었다 — 목적식이 순수 makespan 이다. **여기서 멈추고 보고한다.**")
end

main()
```

- [ ] **Step 2: 돌린다**

Run: `cd /home/chahj578/Construction_OODlayer && julia +lts --project=. tools/probes/probe_kappa_alive.jl`
Expected: `n_candidate_edges` 가 2103 (창이 열렸다는 확인), 그리고 `LAST_AUTO_EFFICIENCY_W` 값.

- [ ] **Step 3: 판정에 따라 분기한다**

`LAST_AUTO_EFFICIENCY_W == 0.0` 이면 **이 계획을 여기서 중단**하고, 관측값과 함께 사용자에게
보고한다. 그 경우 payload 축은 목적식에 닿을 수 없으므로 Task 1~6 은 전부 무효다.

- [ ] **Step 4: 커밋**

```bash
git add tools/probes/probe_kappa_alive.jl
git commit -m "probe(s2): measure whether the energy weight survives on a released board"
```

---

### Task 1: 3인자 `edge_cost_multiplier` — payload 축을 위한 자리 (기본 바이트 동일)

**Files:**
- Modify: `src/essential_tg_coponents.jl:1370` (Ref 추가), `:1398-1406` (3인자 메서드 추가),
  `:1141` (MILP 호출부), `:1586` (greedy 호출부)
- Test: `test/payload_edge_multiplier.jl`

**Interfaces:**
- Consumes: 기존 `edge_cost_multiplier(sched, v)`
- Produces:
  - `CB.EDGE_PAYLOAD_MULTIPLIER :: Ref{Any}` — `nothing` 이거나 `(sched, v, v2) -> Float64`
  - `CB.edge_cost_multiplier(sched, v, v2) :: Float64`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/payload_edge_multiplier.jl
#   julia +lts --project=. test/payload_edge_multiplier.jl
# 🔴 이 파일이 지키는 것은 두 가지다: (a) 훅이 없으면 3인자가 2인자와 **바이트 동일**,
#    (b) 훅이 꽂히면 v2 를 받아 곱해진다. (a) 가 깨지면 이 변경은 전역 회귀다.
module PayloadEdgeMultiplierTest
using Test
using ConstructionBots
const CB = ConstructionBots

@testset "훅이 없으면 3인자 == 2인자 (바이트 동일)" begin
    CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    @test CB.edge_cost_multiplier(nothing, 1) == 1.0
    @test CB.edge_cost_multiplier(nothing, 1, 2) == CB.edge_cost_multiplier(nothing, 1)
end

@testset "훅이 꽂히면 곱해지고, 2인자는 안 변한다" begin
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> 2.5
    try
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 2.5
        @test CB.edge_cost_multiplier(nothing, 1) == 1.0
    finally
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    end
end

@testset "훅은 v2 를 실제로 받는다" begin
    seen = Tuple{Int,Int}[]
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> (push!(seen, (v, v2)); 1.0)
    try
        CB.edge_cost_multiplier(nothing, 7, 9)
        @test seen == [(7, 9)]
    finally
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
    end
end
end # module
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `julia +lts --project=. test/payload_edge_multiplier.jl`
Expected: FAIL — `UndefVarError: EDGE_PAYLOAD_MULTIPLIER not defined`

- [ ] **Step 3: Ref 를 더한다**

`src/essential_tg_coponents.jl` 의 `const EDGE_COST_MULTIPLIER = Ref{Any}(nothing)`(:1370)
**바로 아래**에 넣는다:

```julia
# payload 축 훅 (2026-09-01, S2). `EDGE_COST_MULTIPLIER`(SoC·agent 축)와 **별개의 상자**다.
# 🔴 왜 따로 두나: 하나로 합치면 재가격을 뗄 때 `nothing` 을 넣게 되고 그러면 SoC 항까지
#    같이 사라진다(2026-08-30 계획서가 그 위험을 직접 적었다). 두 축은 곱해지고 따로 꺼진다.
# 서명은 `(sched, v, v2) -> Float64` — payload 는 후보 간선의 **목적지 쪽**에 붙어 있어서
# `v` 만으로는 볼 수 없다(실측: 후보 2103개 전부 v/v2 가 RobotGo 이고 화물은 v2 한 홉 아래).
const EDGE_PAYLOAD_MULTIPLIER = Ref{Any}(nothing)
```

- [ ] **Step 4: 3인자 메서드를 더한다**

기존 `edge_cost_multiplier(sched, v)`(:1398) 을 **그대로 두고** 그 아래에 추가:

```julia
# (한국어) 후보 간선 (v -> v2) 의 최종 비용배율 = 기존 2인자 배율 × payload 배율.
# 훅이 없으면 곱이 1.0 이라 2인자와 **바이트 동일**이다 — 기존 호출자·시험은 그대로 초록.
function edge_cost_multiplier(sched, v, v2)
    m = edge_cost_multiplier(sched, v)
    EDGE_PAYLOAD_MULTIPLIER[] === nothing || (m *= EDGE_PAYLOAD_MULTIPLIER[](sched, v, v2))
    return m
end
```

- [ ] **Step 5: 호출부 둘을 3인자로 바꾼다**

`:1141` — 기존:
```julia
                                edge_costs[(v, v2)] = edge_energy(dt_min) * edge_cost_multiplier(sched, v)
```
새로:
```julia
                                edge_costs[(v, v2)] = edge_energy(dt_min) * edge_cost_multiplier(sched, v, v2)
```

`:1586` — 기존:
```julia
    return get_tF(sched, v) + dt + w * edge_energy(dt) * edge_cost_multiplier(sched, v)
```
새로:
```julia
    return get_tF(sched, v) + dt + w * edge_energy(dt) * edge_cost_multiplier(sched, v, v2)
```

(`greedy_edge_cost(::GreedyEnergyAwareCost, sched, v, v2, dt)` 는 `v2` 를 이미 인자로 받고
있으므로 시그니처 변경이 없다.)

- [ ] **Step 6: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/payload_edge_multiplier.jl`
Expected: PASS (3 testset)

- [ ] **Step 7: 기존 스위트가 안 깨졌는지 확인한다**

Run: `julia +lts --project=. tools/tests.jl`
Expected: `edge_cost_multiplier(nothing, 1)` 관련 세 단언(:1270·:1374·:1376) 포함 전부 초록.
🔴 하나라도 빨개지면 "바이트 동일" 계약이 깨진 것이다 — 되돌리고 원인을 찾는다.

- [ ] **Step 8: 커밋**

```bash
git add src/essential_tg_coponents.jl test/payload_edge_multiplier.jl
git commit -m "feat(s2): add 3-arg edge_cost_multiplier with a payload hook (inert by default)"
```

---

### Task 2: `payload_bias.jl` — 순수 함수와 한 홉 화물 조회

**Files:**
- Create: `src/navigator/payload_bias.jl`
- Modify: `src/navigator/navigator.jl` (include 추가)
- Test: `test/payload_factor.jl`

**Interfaces:**
- Consumes: `BatteryParams`, `_payload_mass_measured(env, node, p)`, `Graphs.outneighbors`,
  `get_node_from_id`, `get_vtx_id`
- Produces:
  - `CB._PAYLOAD_REF :: Ref{Float64}` (기본 `12.8`)
  - `CB._payload_factor(m_payload::Real, light_bias::Real) :: Float64`
  - `CB.candidate_edge_payload_mass(env, sched, v2, p::BatteryParams) :: Union{Nothing,Float64}`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/payload_factor.jl
#   julia +lts --project=. test/payload_factor.jl
# 🔴 집계는 전부 함수 안에서 한다 — top-level for 안의 카운터는 soft scope 로 조용한 0 이 된다.
module PayloadFactorTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

@testset "_payload_factor 는 순수하고 1.0 아래로 안 내려간다" begin
    @test CB._payload_factor(0.0, 0.5) == 1.0          # 짐이 없으면 벌점 없음
    @test CB._payload_factor(12.8, 0.0) == 1.0         # bias 0 이면 payload 항이 사라진다
    @test CB._payload_factor(12.8, 1.0) == 2.0         # ref 만큼 무거우면 정확히 2배
    @test CB._payload_factor(-5.0, 1.0) == 1.0         # 음수 질량은 clamp
    @test CB._payload_factor(12.8, -1.0) == 1.0        # 음수 bias 는 clamp (인센티브 금지)
    @test CB._payload_factor(6.4, 1.0) < CB._payload_factor(12.8, 1.0)   # 단조 증가
end

# 🔴 실측 게이트. 한 홉 조회가 **실제 후보 간선 전부**에서 값을 내는지 본다.
#    음성 대조: v2 자신에서 재면 하나도 못 잰다(그것이 2026-08-30 설계의 실패 지점이다).
function measure()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "payload_factor_gate",
                             num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    @assert !(CB.LAST_EDGE_COSTS[] === sent) "formulate 가 안 돌았다"
    ec = CB.LAST_EDGE_COSTS[]
    p = CB.BatteryParams()
    hop = 0; direct = 0; ms = Float64[]
    for (v, v2) in keys(ec)
        m = CB.candidate_edge_payload_mass(shim, sched, v2, p)
        m === nothing || (hop += 1; push!(ms, m))
        d = try CB._payload_mass_measured(shim,
                CB.get_node_from_id(sched, CB.get_vtx_id(sched, v2)), p) catch; nothing end
        d === nothing || (direct += 1)
    end
    return (n = length(ec), hop = hop, direct = direct, distinct = length(unique(round.(ms, digits=6))))
end

@testset "한 홉 조회가 후보 간선 전부에서 화물을 잰다" begin
    r = measure()
    @test r.n > 0                       # 창이 열려 있어야 이 시험이 의미가 있다
    @test r.hop == r.n                  # 🔴 전부 잰다
    @test r.direct == 0                 # 음성 대조: v2 자신에서는 하나도 못 잰다
    @test r.distinct >= 5               # 분산이 있어야 재가격이 팔을 가른다
end
end # module
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `julia +lts --project=. test/payload_factor.jl`
Expected: FAIL — `UndefVarError: _payload_factor not defined`

- [ ] **Step 3: 구현한다**

```julia
# src/navigator/payload_bias.jl
# =============================================================================
# payload 축 재가격 (S2, 2026-09-01). spec: docs/superpowers/specs/2026-09-01-s2-payload-reprice-design.md
#
# 🔴 **로봇은 `v` 에서, 화물은 `v2` 한 홉 아래에서 읽는다.** 실측(tractor, release 후 후보
#    2103개): v·v2 는 **전부 `RobotGo`** 라 어느 쪽에서도 화물을 못 잰다(0/2103). `v2` 의
#    후속은 **전부 `FormTransportUnit`** 이고 거기서 2103/2103 을 잰다(0.32768 … 12.800,
#    서로 다른 값 15종). 로봇 신원은 반대로 `v` 에만 있다(유효 id 18개; `v2` 는 43개 전부
#    무효 — `reset_slot_to_invalid!` 의 의도).
#    ⟹ 2026-08-30 계획서의 `payload_edge_multiplier`(= v 쪽 질량)는 후보 간선에서 **항상
#    1.0** 이었다. 그 설계로 돌아가지 말 것.
# =============================================================================

"""
    _PAYLOAD_REF

payload 정규화 기준 질량. **tractor.mpd 실측 상한 12.800 kg** 이다(2026-08-30 §6-1 의
`0.32768 … 12.800` · 이 레인의 후보 간선 실측과 일치).

⚠️ 2026-08-30 계획서의 `2.29` 는 `src/smdp/rates.jl` 의 **다른 픽스처** 값이라 쓰지 않는다 —
그 값을 쓰면 대부분의 화물에서 `m/ref > 1` 이 되어 배수가 과도해진다.
⚠️ 이 kg 자체가 프록시다(`battery.jl:72` `payload_density = 100.0`, 그 주석이
*"verify density/units before claiming"*). 물리량으로 인용하지 말 것.
"""
const _PAYLOAD_REF = Ref(12.8)

"""
    _payload_factor(m_payload, light_bias) -> Float64

화물 질량 → 비용 배수 `1 + light_bias·(m/_PAYLOAD_REF)`. 순수 함수.
**절대 1.0 미만이 되지 않는다** — 이 축은 로봇을 비싸게만 만들고 인센티브를 주지 않는다
(`deprioritize_agent` 의 clamp 와 같은 규약). 음의 비용은 MILP 를 깨뜨린다.
"""
_payload_factor(m_payload::Real, light_bias::Real) =
    1.0 + max(0.0, Float64(light_bias)) * max(0.0, Float64(m_payload)) / _PAYLOAD_REF[]

"""
    candidate_edge_payload_mass(env, sched, v2, p) -> Union{Nothing,Float64}

후보 간선 `(v, v2)` 가 나르게 될 화물의 질량. `v2` 는 배정 슬롯(`RobotGo`)이고 화물은 그
**후속 `FormTransportUnit`** 에 붙어 있다 — `policy.jl::_battery_load_features` 가 타는 것과
같은 한 홉이다.

`nothing` 은 **"못 쟀다"** 다(삼상 규약). 호출자는 그것을 0 으로 접지 말고 배수 1.0 으로
다뤄야 한다 — 모르는 것을 근거로 로봇을 벌하지 않는다.
"""
function candidate_edge_payload_mass(env, sched, v2, p::BatteryParams)
    outs = Graphs.outneighbors(sched, v2)
    isempty(outs) && return nothing
    succ = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
    return try
        _payload_mass_measured(env, succ, p)
    catch
        nothing            # 화물을 나르는 노드가 아니다 = 못 쟀다 (0 이 아니다)
    end
end
```

- [ ] **Step 4: navigator.jl 에 include 를 더한다**

`src/navigator/navigator.jl` 의 `include("battery.jl")` **바로 아래**에 넣는다
(`payload_bias.jl` 이 `BatteryParams`·`_payload_mass_measured` 를 쓰므로 battery 뒤여야 한다):

```julia
include("payload_bias.jl")        # payload 축 재가격 (의존: battery)
```

- [ ] **Step 5: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/payload_factor.jl`
Expected: PASS. 실측 testset 은 씬을 만들므로 수 분 걸린다.

- [ ] **Step 6: 커밋**

```bash
git add src/navigator/payload_bias.jl src/navigator/navigator.jl test/payload_factor.jl
git commit -m "feat(s2): payload factor + one-hop cargo lookup for candidate edges"
```

---

### Task 3: `reprice_agent_by_payload!` — 훅 설치와 해제

**Files:**
- Modify: `src/navigator/payload_bias.jl` (아래 내용 추가)
- Test: `test/payload_reprice_install.jl`

**Interfaces:**
- Consumes: Task 1 의 `EDGE_PAYLOAD_MULTIPLIER`, Task 2 의 `_payload_factor` ·
  `candidate_edge_payload_mass`; `BATTERY_FLEET`, `_edge_owner_id`
- Produces:
  - `CB.PAYLOAD_BIAS :: Ref{Union{Nothing,NamedTuple}}`
  - `CB.payload_edge_multiplier(env, sched, v, v2) :: Float64`
  - `CB.reprice_agent_by_payload!(env; agent::AbstractString, light_bias::Real = 0.5)`
    `-> NamedTuple` — `(status::Symbol, agent::String, installed::Bool)`,
    `status ∈ (:repriced, :no_fleet, :unknown_agent)`
  - `CB.clear_payload_bias!() -> Nothing`

- [ ] **Step 1: 실패하는 시험을 쓴다**

```julia
# test/payload_reprice_install.jl
#   julia +lts --project=. test/payload_reprice_install.jl
module PayloadRepriceInstallTest
using Test
using ConstructionBots
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

@testset "함대가 없으면 설치하지 않는다" begin
    CB.BATTERY_FLEET[] = nothing
    r = CB.reprice_agent_by_payload!(nothing; agent = "BotID{DeliveryBot}(2)")
    @test r.status === :no_fleet
    @test r.installed === false
    @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing   # 🔴 실패했으면 훅을 안 남긴다
end

@testset "훅이 없을 때 배수는 1.0 이다 (음성 대조)" begin
    CB.PAYLOAD_BIAS[] = nothing
    @test CB.payload_edge_multiplier(nothing, nothing, 1, 2) == 1.0
end

@testset "clear_payload_bias! 는 SoC 훅을 건드리지 않는다" begin
    CB.EDGE_COST_MULTIPLIER[] = (sched, v) -> 3.0      # SoC 축이 꽂혀 있다고 가정
    CB.EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> 2.0
    try
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 6.0
        CB.clear_payload_bias!()
        @test CB.EDGE_PAYLOAD_MULTIPLIER[] === nothing
        @test CB.edge_cost_multiplier(nothing, 1, 2) == 3.0   # 🔴 SoC 항은 살아 있다
    finally
        CB.EDGE_COST_MULTIPLIER[] = nothing
        CB.EDGE_PAYLOAD_MULTIPLIER[] = nothing
        CB.PAYLOAD_BIAS[] = nothing
    end
end
end # module
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `julia +lts --project=. test/payload_reprice_install.jl`
Expected: FAIL — `UndefVarError: reprice_agent_by_payload! not defined`

- [ ] **Step 3: 구현한다**

`src/navigator/payload_bias.jl` 끝에 추가:

```julia
"설치된 재가격 상태. `(agent::String, light_bias::Float64, params::BatteryParams)`."
const PAYLOAD_BIAS = Ref{Union{Nothing,NamedTuple}}(nothing)

"""
    payload_edge_multiplier(env, sched, v, v2) -> Float64

후보 간선 `(v, v2)` 의 payload 배수. 재가격 대상이 **아닌** 로봇의 간선에서는 1.0 이므로
설치 전후로 다른 로봇의 비용은 바이트 동일이다.

계약(실측 근거는 이 파일 머리말): 로봇 신원은 `v` 에서, 화물은 `v2` 한 홉 아래에서.
화물을 못 재면 1.0 이다 — 모르는 것을 근거로 벌하지 않는다(삼상 규약).
"""
function payload_edge_multiplier(env, sched, v, v2)
    st = PAYLOAD_BIAS[]
    st === nothing && return 1.0
    owner = _edge_owner_id(sched, v)
    (owner === nothing || string(owner) != st.agent) && return 1.0
    m = candidate_edge_payload_mass(env, sched, v2, st.params)
    m === nothing && return 1.0
    return _payload_factor(m, st.light_bias)
end

"""
    reprice_agent_by_payload!(env; agent, light_bias = 0.5) -> NamedTuple

한 로봇의 **후보 배정 간선** 비용을 그 간선이 나르게 될 화물 질량에 비례해 올린다. 로봇을
함대에서 빼지 않고 가벼운 화물 쪽으로 몰아주는 개입이다. 실행가능집합을 안 바꾸므로 문제를
infeasible 로 만들 수 없다.

🔴 **이것만으로는 무동작이다.** 간선 가중치는 MILP 재풀이가 읽어야 뜻을 갖고, 재풀이가 볼
후보 간선은 `release_pending_assignments!` 가 슬롯을 풀어야 생긴다. 실측: release 없이
후보 간선은 **0** 이고 그때 이 배수는 **0번 호출된다.**

🔴 국소 undo 는 없다. `clear_payload_bias!` 는 훅을 떼지만 그 편향으로 푼 계획은 못 되돌린다.
"""
function reprice_agent_by_payload!(env; agent::AbstractString, light_bias::Real = 0.5)
    fleet = BATTERY_FLEET[]
    fleet === nothing && return (status = :no_fleet, agent = String(agent), installed = false)
    known = Set(string(k) for k in keys(fleet.soc))
    String(agent) in known ||
        return (status = :unknown_agent, agent = String(agent), installed = false)
    PAYLOAD_BIAS[] = (agent = String(agent), light_bias = Float64(light_bias),
                      params = fleet.params)
    EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> payload_edge_multiplier(env, sched, v, v2)
    return (status = :repriced, agent = String(agent), installed = true)
end

"""
    clear_payload_bias!() -> Nothing

payload 훅만 뗀다. `EDGE_COST_MULTIPLIER`(SoC·agent 축)는 **건드리지 않는다** — 두 축을 한
상자에 넣었다면 여기서 SoC 항까지 사라졌을 것이다(그래서 Ref 를 둘로 나눴다).
"""
function clear_payload_bias!()
    PAYLOAD_BIAS[] = nothing
    EDGE_PAYLOAD_MULTIPLIER[] = nothing
    return nothing
end
```

- [ ] **Step 4: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/payload_reprice_install.jl`
Expected: PASS (3 testset)

- [ ] **Step 5: 커밋**

```bash
git add src/navigator/payload_bias.jl test/payload_reprice_install.jl
git commit -m "feat(s2): reprice_agent_by_payload! installs a v2-aware payload hook"
```

---

### Task 4: 알파벳 등재 (원시 19 → 20)

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/primitive_registry.json`

**Interfaces:**
- Consumes: Task 3 의 `reprice_agent_by_payload!`
- Produces: 알파벳 원시 `"reprice_agent_by_payload"` — `harness_args: ["env"]`,
  params `agent::string` · `light_bias::number`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/payload_reprice_install.jl` 끝(module `end` 앞)에 testset 을 더한다:

```julia
@testset "알파벳이 이 원시를 해석하고 결선한다" begin
    CB.include(joinpath(pkgdir(CB), "src", "respec", "minted_tool.jl"))
    tbl = CB.PRIMITIVE_TABLE()
    @test haskey(tbl, "reprice_agent_by_payload")
    r = CB.resolve_primitive("reprice_agent_by_payload")
    @test r.impl === CB.reprice_agent_by_payload!
    @test r.harness_args == ["env"]
    @test Set(keys(r.params)) == Set(["agent", "light_bias"])
end
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `julia +lts --project=. test/payload_reprice_install.jl`
Expected: FAIL — `haskey(tbl, "reprice_agent_by_payload")` 가 false

- [ ] **Step 3: 레지스트리에 등재한다**

`wm4spacecraft_manufacturing/core/primitive_registry.json` 의 `primitives` 배열 끝에 추가.
🔴 `mechanism` 에 **명령을 적지 않는다** — 기전만 적는다(Global Constraints 의 정답 누수 금지).

```json
{
  "name": "reprice_agent_by_payload",
  "surface": "env_param",
  "params": {
    "agent": {"type": "string", "description": "robot id whose candidate assignment edges are repriced"},
    "light_bias": {"type": "number", "minimum": 0.0, "maximum": 4.0,
                   "description": "how strongly heavier cargo is penalised for that robot; 0 disables the payload term"}
  },
  "mechanism": "Multiplies ONE robot's CANDIDATE assignment-edge costs by a factor that grows with the cargo mass the edge would carry, on top of the existing SoC-based multiplier (the SoC term is preserved byte-for-byte; the two multiply). The robot identity is read from the edge source; the cargo mass from the FormTransportUnit that follows the target slot. The factor is never below 1.0 -- a robot can be made more expensive, never cheaper -- and the feasible set is unchanged, so this cannot make the problem infeasible. Edges whose cargo cannot be measured keep factor 1.0. THIS IS INERT ON ITS OWN: it only changes weights that a MILP re-solve reads, and the only edges that carry these weights are the candidate edges that exist when pending assignments have been released; measured on this model, with no release there are zero such edges and this factor is evaluated zero times. There is no local undo: clearing the bias drops the hook but does not restore whatever plan the biased re-solve replaced.",
  "when_to_use": "The load axis when a robot must stay in service but should carry less.",
  "reversible": false,
  "consumes": [],
  "preconditions": [
    "the battery fleet must be initialised (enable_battery!)",
    "candidate assignment edges must exist for the weights to be read",
    "a MILP re-solve must run after this call or it has no effect"
  ],
  "gate": null,
  "gate_arity": null,
  "impl": "reprice_agent_by_payload!",
  "harness_args": ["env"],
  "psi": {
    "a_cost": 0.3, "a_intervenes": 1.0, "a_soft": 1.0, "a_restores_capacity": 0.0,
    "a_relocates_work": 0.5, "a_spatial": 0.0, "a_consumes_spare": 0.0,
    "a_reversible": 0.0, "a_scope": 1.0
  },
  "source": "src/navigator/payload_bias.jl",
  "notes": "S2 spec 4. psi 아홉 축은 판단이지 유도가 아니다 — deprioritize_agent(같은 soft/env_param 계열)에 앵커했고 a_relocates_work 만 0.5 로 뒀다(일을 없애지 않고 옮긴다)."
}
```

- [ ] **Step 4: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/payload_reprice_install.jl`
Expected: PASS (4 testset)

- [ ] **Step 5: 알파벳 크기 리터럴 6곳을 20 으로 고친다**

🔴 원시 수가 **여섯 자리에 리터럴로** 박혀 있다(실측). 리터럴을 **지우지 말고 값만 고친다** —
그 단언들이 "알파벳이 의도치 않게 늘거나 줄지 않았다"를 지키는 게이트다. **Python 한 자리를
빠뜨리기 쉽다.**

| 파일 | 줄 | 현재 |
|---|---|---|
| `tools/monitor/test_minted_wiring.jl` | 303 | `@test length(CB.PRIMITIVE_TABLE()) == 19` |
| `tools/monitor/test_minted_wiring.jl` | 326 | `@test length(CB.PRIMITIVE_TABLE()) == 19` |
| `test/minted_tool_enacts.jl` | 172 | `@test length(tbl) == 19` |
| `test/minted_tool_enacts.jl` | 210 | `@test length(CB.PRIMITIVE_TABLE()) == 19` |
| `test/minted_tool_enacts.jl` | 557 | `@test length(CB.PRIMITIVE_TABLE()) == 19` |
| `src/respec/llm_service/test_synthesize.py` | 86 | `assert len(prims) == len(_prim.PRIMITIVE_NAMES) == 19` |

전부 `19` → `20`.

- [ ] **Step 5b: 세 스위트를 돌린다**

```bash
julia +lts --project=. tools/monitor/test_minted_wiring.jl
julia +lts --project=. test/minted_tool_enacts.jl
cd src/respec/llm_service && python -m pytest test_synthesize.py -q && cd -
```
Expected: 셋 다 초록.

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/primitive_registry.json test/payload_reprice_install.jl
git commit -m "feat(s2): register reprice_agent_by_payload in the primitive alphabet"
```

---

### Task 5: 사슬이 실제로 계획을 바꾸는가 (G-2 · G-4)

**Files:**
- Test: `test/payload_reprice_changes_plan.jl`

**Interfaces:**
- Consumes: Task 1~4 전부 + `CB.release_pending_assignments!` · `CB.build_invariant` ·
  `CB.formulate_milp` · `CB.LAST_EDGE_COSTS`
- Produces: 없음 (게이트)

- [ ] **Step 1: 시험을 쓴다**

```julia
# test/payload_reprice_changes_plan.jl
#   julia +lts --project=. test/payload_reprice_changes_plan.jl
# 🔴 이 파일이 막으려는 실패 모양은 **침묵 성공**이다: 원시가 `:repriced` 를 내는데 세계는
#    바이트 동일인 것. 그래서 반환 심볼을 증거로 쓰지 않고 edge_costs 를 직접 비교한다.
#    음성 대조 둘을 짝으로 갖는다 — (a) release 없음, (b) light_bias = 0.
module PayloadRepriceChangesPlanTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

function fresh_env()
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2chain",
                       num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
end

"release 여부와 재가격 여부를 조합해 edge_costs 를 낸다."
function costs(env; release::Bool, agent = nothing, light_bias = 0.5)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    release && CB.release_pending_assignments!(shim, CB.build_invariant(env))
    CB.clear_payload_bias!()
    agent === nothing || CB.reprice_agent_by_payload!(shim; agent = agent, light_bias = light_bias)
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    @assert !(CB.LAST_EDGE_COSTS[] === sent) "formulate 가 안 돌았다"
    out = copy(CB.LAST_EDGE_COSTS[])
    CB.clear_payload_bias!()
    return out
end

"후보 간선에서 가장 많이 등장하는 유효 owner id (재가격 대상으로 쓴다)."
function busiest_agent(env)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    tally = Dict{String,Int}()
    for (v, _) in keys(CB.LAST_EDGE_COSTS[])
        id = CB._edge_owner_id(sched, v)
        id === nothing && continue
        tally[string(id)] = get(tally, string(id), 0) + 1
    end
    return first(sort(collect(tally), by = kv -> -kv[2]))[1]
end

@testset "G-2 · release 가 없으면 후보 간선이 없고 재가격은 무동작이다" begin
    env = fresh_env()
    a = busiest_agent(env)
    no_rel_plain = costs(env; release = false)
    no_rel_bias  = costs(env; release = false, agent = a, light_bias = 2.0)
    @test length(no_rel_plain) == 0                 # 🔴 실측된 사실: release 없이는 0
    @test no_rel_plain == no_rel_bias               # 세계가 바이트 동일
end

@testset "G-4 · release 뒤에는 재가격이 실제로 비용을 바꾼다" begin
    env = fresh_env()
    a = busiest_agent(env)
    base = costs(env; release = true)
    zero = costs(env; release = true, agent = a, light_bias = 0.0)   # 음성 대조
    hot  = costs(env; release = true, agent = a, light_bias = 2.0)
    @test length(base) > 0
    @test keys(base) == keys(zero) == keys(hot)     # 실행가능집합은 안 바뀐다
    @test base == zero                              # 🔴 bias 0 이면 바이트 동일
    @test base != hot                               # 🔴 bias > 0 이면 달라진다
    @test all(hot[k] >= base[k] - 1e-9 for k in keys(base))   # 절대 싸지지 않는다
    changed = count(k -> hot[k] > base[k] + 1e-9, collect(keys(base)))
    @test changed > 0
    @test changed < length(base)                    # 대상 로봇의 간선만 바뀐다(전역 배율이 아니다)
end
end # module
```

- [ ] **Step 2: 돌려서 확인한다**

Run: `julia +lts --project=. test/payload_reprice_changes_plan.jl`
Expected: PASS. 🔴 `base != hot` 이 실패하면 훅이 후보 간선에 안 닿는 것이다 — Task 1 의
호출부(:1141)가 3인자를 쓰는지 먼저 본다.
🔴 `changed == length(base)` 이면 대상 선택(`_edge_owner_id` 비교)이 안 먹은 것이다.

- [ ] **Step 3: 커밋**

```bash
git add test/payload_reprice_changes_plan.jl
git commit -m "test(s2): gate that release+reprice changes edge costs, with two negative controls"
```

---

### Task 6: 창의 상태를 결정 행에 남긴다 (G-3)

**Files:**
- Modify: `tools/monitor/policy.jl` (`decide_all` 의 프로브 블록, `ood_features`)

**Interfaces:**
- Consumes: `release_then_candidates(env)` (이미 있음, 이 레인이 추가함)
- Produces: 결정 행의 특징 `"s2_after_release_candidates" :: Union{Nothing,Int}`

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test/payload_reprice_changes_plan.jl` 끝(module `end` 앞)에 추가:

```julia
# 🔴 `include` 는 **모듈 최상위**에 둔다(파일 머리, `fresh_env` 정의 위). @testset 안에서
#    include 하면 함수 스코프로 들어가 `ood_features` 가 전역에 안 잡힌다.
#    → 이 파일 상단의 `CB.include(... navigator.jl)` 바로 아래에 다음 줄을 넣는다:
#         include(joinpath(pkgdir(CB), "tools", "monitor", "policy.jl"))
@testset "G-3 · 창의 상태가 특징으로 남는다" begin
    env = fresh_env()
    truth = CB.BatteryTruth(CB.RobotID(3), 0.55)
    d = ood_features(env, truth)
    @test haskey(d, "s2_after_release_candidates")
    @test d["s2_after_release_candidates"] isa Int          # 이 판은 창이 열려 있다
    @test d["s2_after_release_candidates"] > 0
end
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `julia +lts --project=. test/payload_reprice_changes_plan.jl`
Expected: FAIL — `haskey(d, "s2_after_release_candidates")` 가 false

- [ ] **Step 3: `ood_features` 에 필드를 더한다**

`tools/monitor/policy.jl` 의 `ood_features` 안, `d` 를 만든 뒤에 넣는다:

```julia
    # ---- S2 창(window): release 뒤에 후보 배정 간선이 몇 개 열리는가 --------------------
    # 🔴 이 값이 0 이면 **재분배가 원리적으로 불가능한 시점**이다(실측: closed≈247/287 부터
    #    0). 그 사건에서 정책이 NOOP 을 내는 것은 오답이 아니다 — 평가는 이 값으로 층화한다.
    # 🔴 `nothing`("못 쟀다")을 0("창이 닫혔다")으로 접지 않는다. 못 쟀으면 키를 안 싣는다.
    local _win = release_then_candidates(env)
    _win === nothing || (d["s2_after_release_candidates"] = _win.after)
```

- [ ] **Step 4: 시험이 통과하는지 확인한다**

Run: `julia +lts --project=. test/payload_reprice_changes_plan.jl`
Expected: PASS

- [ ] **Step 5: 데모 한 판으로 층화가 실제로 남는지 본다**

Run:
```bash
DEMO_OOD=battery DEMO_BSOC=0.30 DEMO_POLICY=canonical DEMO_ROUTER=0 DEMO_SEED=1 \
DEMO_N=6 DEMO_OOD_SEED=7 DEMO_OOD_LO=0.15 DEMO_OOD_HI=0.90 \
julia +lts --project=. tools/monitor/run_demo.jl
```
Expected: 완주하고, 결정마다 `s2_after_release_candidates` 가 **감소**하다가 후반에 0 이 된다
(이 레인이 잰 1320 → 890 → 591 → 461 → 80 → 0 과 같은 모양).
⚠️ `decide_all` 이 결정마다 `deepcopy` + `formulate` 를 하므로 판이 느려진다. 이것이
프로브를 `S2_CANDIDATE_PROBE` 로 게이트해 둔 이유이고, `ood_features` 로 옮기면 **항상**
돈다 — 느려진 벽시계 시간을 이전 세대와 비교하지 말 것.

- [ ] **Step 6: 커밋**

```bash
git add tools/monitor/policy.jl test/payload_reprice_changes_plan.jl
git commit -m "feat(s2): record the reassignment window on every decision row"
```

---

### Task 7: 비개입 계약(G-1)과 재풀이 안전성

**왜.** spec §8 G-1 은 게이트인데 아직 시험이 없다(이 레인이 손으로만 확인했다). 그리고
spec §9-3 — release 뒤의 재풀이가 **얼렸어야 할 일을 건드리지 않는지** 는 미측정이다.

**Files:**
- Test: `test/payload_release_is_safe.jl`

**Interfaces:**
- Consumes: `release_then_candidates` (policy.jl), `CB.build_invariant`,
  `CB.release_pending_assignments!`, `CB.INVALID_ID_COUNTERS`
- Produces: 없음 (게이트)

- [ ] **Step 1: 시험을 쓴다**

```julia
# test/payload_release_is_safe.jl
#   julia +lts --project=. test/payload_release_is_safe.jl
module PayloadReleaseIsSafeTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
include(joinpath(pkgdir(CB), "tools", "monitor", "policy.jl"))

function fresh_env()
    CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "s2safe",
                       num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                       open_animation_at_end = false, save_animation = false,
                       write_results = false, return_env_before_sim = true,
                       rng = Random.MersenneTwister(1))
end

@testset "G-1 · release_then_candidates 는 세계를 안 건드린다" begin
    env = fresh_env()
    ne0  = Graphs.ne(env.sched)
    ids0 = copy(CB.INVALID_ID_COUNTERS)
    r1 = release_then_candidates(env)
    r2 = release_then_candidates(env)
    @test Graphs.ne(env.sched) == ne0                 # 🔴 스케줄 원본 불변
    @test copy(CB.INVALID_ID_COUNTERS) == ids0        # 🔴 무효 ID 카운터 불변(시드 재현성)
    @test r1 !== nothing && r2 !== nothing
    @test r1 == r2                                    # 멱등
end

@testset "release 는 완료·진행중 작업을 건드리지 않는다" begin
    env = fresh_env()
    inv = CB.build_invariant(env)
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    active_before = Set(CB.get_vtx_id(env.sched, v) for v in env.cache.active_set)
    removed = CB.release_pending_assignments!(shim, inv)
    # 제거된 엣지의 어느 끝도 closed 이거나 active 이면 안 된다.
    for (v, v2) in removed
        id1 = CB.get_vtx_id(sched, v); id2 = CB.get_vtx_id(sched, v2)
        @test !(id1 in inv.closed_nodes) && !(id2 in inv.closed_nodes)
        @test !(id1 in active_before)   && !(id2 in active_before)
    end
end

@testset "release + 재가격 뒤의 재풀이가 feasible 하다" begin
    env = fresh_env()
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    CB.clear_payload_bias!()
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree;
                             optimizer = CB._respec_optimizer())
    CB.optimize!(milp)
    @test CB.primal_status(milp) == CB.MOI.FEASIBLE_POINT
end
end # module
```

- [ ] **Step 2: 돌려서 확인한다**

Run: `julia +lts --project=. test/payload_release_is_safe.jl`
Expected: PASS.
🔴 세 번째 testset 이 INFEASIBLE 이면 **release 가 결정 시점에 안전하지 않다** — 그 경우
Task 1~6 은 되돌리지 말고 **멈추고 보고한다**(spec §9-3 이 그 위험을 예고한 자리다).

- [ ] **Step 3: 커밋**

```bash
git add test/payload_release_is_safe.jl
git commit -m "test(s2): pin the probe's non-invasiveness and that release keeps the re-solve feasible"
```

---

## 이 계획이 하지 않는 것

- **①② (`edge_energy` payload 배선 · `load_power`)** — spec §7. 전역이라 모든 레인의 배정
  지문을 바꾼다. 필요해지면 별도 결정으로 연다.
- **`rebalance_for_battery!` 수리** — spec §7. 침묵 성공은 spec §2-3 에 기록만 한다.
- **mild 메뉴 변경 · 매크로 어휘 변경** — D-1 · D-2.
- **완주까지 가는 안전성 검증** — Task 7 은 재풀이가 **feasible** 한지와 얼린 일을 안 건드리는지
  까지만 잰다. release+재가격으로 푼 계획이 **판을 끝까지 완주시키는지**는 이 계획의 범위 밖이고,
  집행 레인의 첫 일이다(spec §9-3).
- **G-5(사실 블록 판정 누수)** — 사실 블록 자체를 안 건드리므로 이 계획에 없다.
- **사실 블록(§5) 확장** — 플래너가 쓰는 값이 존재해야 쓸 수 있으므로 Task 1~5 이후의 별도
  레인이다. spec §5 의 규약(새 추정량 금지, 판정 누수 금지)이 그때 적용된다.
