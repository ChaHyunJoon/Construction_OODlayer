# Task 1 — 컴파일러가 쓸 **소유자 선택자**를 측정으로 정한다

> 🔴 **이 태스크는 production 코드를 한 줄도 쓰지 않는다.** 산출은 **측정된 답과 그 기록**이고,
> Task 2 가 그 답을 그대로 쓴다. 설계에서 추측으로 정하지 않기로 한 자리다(spec §6).

## 배경 — 왜 이게 미결인가

만들려는 제약은 *"이 로봇은 자기가 맡을 예정인 화물 중 1대당 부담 상위 N 개를 맡지 않는다"* 이다.
컴파일러가 MILP 를 세울 때 **"이 로봇 소유의 후보 배정"** 을 찾아야 하는데, 후보가 둘이고
2026-09-01 실측이 **서로 다른 답**을 냈다:

| 선택자 | 실측 결과 |
|---|---|
| `is_agent_frontier(sched, v, node, agent)` — 기존 `ForbidAgent` 가 쓰는 것 (`src/respec/compiler.jl:224`) | A 의 정점 **1개**를 찾았고, 그 정점은 후보 간선의 출발점이 **아니었다**(후보 중 `u ∈ frontier(A)` = **0개**) |
| `_edge_owner_id(sched, v)` (`src/essential_tg_coponents.jl`) | 전체 release 후에도 A 소유 **144개**를 찾았다 |

⚠️ **두 실측은 서로 다른 대상을 봤다.** `ForbidAgent` 컴파일러는 **`Xa` 의 구조적 비영 항목**
(`isassigned_edge(Xa, v, v2)`)을 훑고, 위 144 는 **`LAST_EDGE_COSTS`**(목적함수가 가격을 매긴
후보 간선)를 봤다. 단순 비교가 성립하지 않는다.

🔴 **유력한 가설 — 반드시 먼저 확인하라.** `is_agent_frontier` 는 전역 `RESPEC_FROZEN[]` 과
`RESPEC_PINNED[]` 를 읽는다(`compiler.jl:229-230`). 그 둘은 `fault_robot_and_reassign!` 이
매 재배정마다 채운다(`src/respec/reassign.jl:365-366`). **프로브가 그 함수를 안 거쳤으면 두
전역이 비어 있거나 낡았고, 그래서 frontier 가 1개로 쪼그라들었을 수 있다.** 즉 앞선 실측이
선택자의 성질이 아니라 **프로브 문맥의 성질**을 잰 것일 수 있다.

## 무엇을 답해야 하는가

**Q1.** `RESPEC_FROZEN[]`·`RESPEC_PINNED[]` 를 production 과 같게 채운 상태에서
`is_agent_frontier` 가 찾는 A 의 정점은 몇 개인가? (0/1 이면 가설 성립)

**Q2.** `formulate_milp` **안에서** — 즉 `Xa` 가 존재하는 곳에서 — 두 선택자가 각각 몇 개의
`(u, v2)` 쌍을 만드는가? 조건은 `ForbidAgent` 와 같게: `isassigned_edge(Xa, u, v2)` 이고
`!Graphs.has_edge(sched, u, v2)`(확정 간선은 절대 금지하지 않는다).

**Q3.** 그 쌍들의 도착점 `v2` 중 **1대당 부담을 잴 수 있는** 것은 몇 개인가?
(1대당 부담 = `_payload_mass_measured(env, inner, p) / length(robot_team(inner))`,
`inner` 는 `v2` 의 `outneighbors` 한 홉 뒤 화물 운반 노드)

**Q4.** 두 선택자의 답이 다르면, **어느 쪽이 실제로 A 의 미래 화물 작업을 가리키는가?**
판정 방법: 그 쌍들을 `Xa ≤ 0` 으로 눌러 풀었을 때 **A 가 실제로 그 화물을 잃는가.**

## Files

- Create: `tools/probes/probe_owner_selector.jl`
- Modify: 없음
- 기록: 이 파일 맨 아래 "결과" 절에 **측정값을 적어 넣고 커밋**한다

## 참고 — 이미 있는 것을 재사용하라

`tools/probes/probe_can_a_be_displaced.jl` 이 **`formulate_milp` 뒤에 `Xa` 상계를 0 으로 눌러**
컴파일러 없이 금지 효과를 내는 기법을 이미 검증했다. Q4 는 그 기법을 그대로 쓴다.
`tools/probes/probe_scoped_release.jl` 의 `release_scoped!` · `burden` 함수도 복사해 쓸 수 있다.

⚠️ `formulate_milp` 는 `Xa` 를 반환 객체(`milp.Xa`)로 들고 나온다. 그러므로 Q2 는 컴파일러
안에 들어가지 않아도 **formulate 뒤에** `milp.Xa` 로 잴 수 있다. `isassigned_edge(Xa, u, v2)`
도 밖에서 부를 수 있다.

- [ ] **Step 1: 픽스처를 세운다**

```julia
using ConstructionBots, Random, Graphs
using JuMP
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "smdp", "mdp.jl"))

function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "ownersel", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < 6000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    return env
end
```

- [ ] **Step 2: Q1 — 두 전역의 상태에 따라 frontier 가 달라지는지 잰다**

```julia
"RESPEC_FROZEN/PINNED 를 `build_invariant` 결과로 채운 뒤와 채우기 전의 frontier 크기를 비교."
function q1(env, agent)
    inv = CB.build_invariant(env)
    before_f = length(CB.RESPEC_FROZEN[]); before_p = length(CB.RESPEC_PINNED[])
    n_before = count_frontier(env, agent)
    # production 과 같게 채운다 (reassign.jl:365-366 이 하는 일)
    CB.RESPEC_FROZEN[] = inv.closed_nodes
    CB.RESPEC_PINNED[] = union(inv.closed_nodes,
        Set{CB.AbstractID}(CB.get_vtx_id(env.sched, v) for v in env.cache.active_set))
    n_after = count_frontier(env, agent)
    return (frozen_before = before_f, pinned_before = before_p,
            frontier_before = n_before, frontier_after = n_after)
end

function count_frontier(env, agent)
    n = 0
    for v in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        CB.is_agent_frontier(env.sched, v, node, agent) && (n += 1)
    end
    return n
end
```

⚠️ `RESPEC_PINNED[]` 에 무엇이 들어가는지는 **`reassign.jl:365-366` 을 직접 읽고** 그대로 맞춰라.
위 코드는 추정이다. 실제 코드와 다르면 **실제 코드를 따르고 이 브리프의 이 줄을 고쳐라.**

- [ ] **Step 3: Q2 — `Xa` 를 손에 들고 두 선택자를 센다**

```julia
"formulate 뒤 milp.Xa 로 두 선택자의 (u,v2) 쌍 수를 센다. ForbidAgent 와 같은 조건."
function q2(env, agent, agent_str)
    inv = CB.build_invariant(env)
    sent = Dict{Tuple{Int,Int},Float64}(); CB.LAST_EDGE_COSTS[] = sent
    milp = CB.formulate_milp(CB.SparseAdjacencyMILP(), env.sched, env.scene_tree;
                             optimizer = CB._respec_optimizer(),
                             t0_ = inv.frozen_t0, tF_ = inv.frozen_tF)
    CB.LAST_EDGE_COSTS[] === sent && error("formulate 가 안 돌았다 — 못 쟀다")
    Xa = milp.Xa
    pairs_frontier = Tuple{Int,Int}[]; pairs_owner = Tuple{Int,Int}[]
    for u in Graphs.vertices(env.sched)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, u))
        isf = CB.is_agent_frontier(env.sched, u, node, agent)
        own = CB._edge_owner_id(env.sched, u)
        iso = own !== nothing && string(own) == agent_str
        (isf || iso) || continue
        for v2 in Graphs.vertices(env.sched)
            CB.isassigned_edge(Xa, u, v2) || continue
            Graphs.has_edge(env.sched, u, v2) && continue   # 확정 간선은 절대 금지 안 함
            isf && push!(pairs_frontier, (u, v2))
            iso && push!(pairs_owner, (u, v2))
        end
    end
    return (milp = milp, frontier = pairs_frontier, owner = pairs_owner,
            ncand = length(CB.LAST_EDGE_COSTS[]))
end
```

- [ ] **Step 4: Q3 — 그 쌍들의 1대당 부담을 잰다**

```julia
function burden(env, v2, p)
    for v in Graphs.outneighbors(env.sched, v2)
        node = CB.get_node_from_id(env.sched, CB.get_vtx_id(env.sched, v))
        inner = try node.node catch; node end
        m = try CB._payload_mass_measured(env, inner, p) catch; continue end
        t = try length(CB.robot_team(inner)) catch; continue end
        t > 0 && return m / t
    end
    return nothing            # 🔴 "못 쟀다" 이지 0 이 아니다
end
```

각 선택자의 쌍 집합에 대해 **부담을 잰 도착점 수 / 전체 도착점 수** 를 보고하라.
🔴 **둘 다 0 이면 이 태스크는 실패다** — 부담을 못 재면 상위 N 을 고를 수 없다.
그 경우 `burden` 이 왜 실패하는지(노드 타입? `robot_team` 없음?)를 표본으로 찍어 보고하라.

- [ ] **Step 5: Q4 — 눌러 보고 A 가 실제로 화물을 잃는지 본다**

각 선택자마다: 부담 상위 N=1 도착점을 고르고, 그 도착점으로 가는 쌍 전부에
`JuMP.set_upper_bound(Xa[u, v2], 0.0)` 를 걸고 60초 상한으로 푼다. 그리고
**해 이전/이후의 `CB.simstate_of(env).g.binding` 을 비교해** A 가 그 작업을 잃었는지 센다.

🔴 **반드시 세 가지를 함께 찍어라**: 누른 쌍의 개수(0이면 공허), 종료 상태
(`termination_status`), A 가 잃은 작업 수. 개수가 0 인데 초록이면 그것이 이 레포의 단골 사고다.

⚠️ `set_upper_bound` 는 `formulate_milp` 이 만든 **그 모델**에만 걸린다. 두 선택자를 비교하려면
**각각 새로 formulate** 하라(같은 모델을 두 번 누르면 두 번째가 첫 번째 위에 쌓인다).

- [ ] **Step 6: 두 판에서 돌린다**

`tractor.mpd`(10대)와 `colored_8x8.ldr`(6대), 각각 `closed ≈ 60` 과 `closed ≈ 150`.
한 판에서만 재고 결론 내지 마라 — 이 레인에서 그 실수가 이미 두 번 났다.

- [ ] **Step 7: 결과를 이 파일에 적고 커밋한다**

```bash
git add tools/probes/probe_owner_selector.jl docs/superpowers/plans/2026-09-01-cargo-ban/task-1-owner-selector.md
git diff --cached --name-status | grep -c '^D'   # 🔴 0 이어야 한다
git commit -m "probe: ForbidHeavyCargo 컴파일러의 소유자 선택자를 측정으로 정한다"
```

---

## 결과 — 측정 후 여기에 적는다

| 판 | closed | Q1 frontier(전/후) | Q2 frontier 쌍 | Q2 owner 쌍 | Q3 부담 잰 비율 | Q4 A가 잃은 작업 |
|---|---|---|---|---|---|---|
| tractor | 60 | | | | | |
| tractor | 150 | | | | | |
| colored_8x8 | 60 | | | | | |
| colored_8x8 | 150 | | | | | |

**결정:** Task 2 의 컴파일러는 `___________` 를 선택자로 쓴다.

**근거:** (위 표의 어느 칸이 그렇게 말하는지 한 문장으로)

**⚠️ 못 쟀거나 예상과 달랐던 것:**
