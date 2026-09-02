# 화물 금지 제약 (`ForbidHeavyCargo`) 구현 계획

> **에이전트 작업자에게:** 이 계획은 **태스크마다 파일이 하나씩** 이다. 한 세션에서 **한 파일만**
> 열어 끝까지 수행하라. 각 파일은 자기완결적이다 — spec 을 안 읽어도 되도록 필요한 사실을
> 전부 안에 실어 두었다. 순서대로 하라(뒤 태스크가 앞 태스크의 산출을 쓴다).

**목표** payload wear-leveling 의 지렛대를 **비용 편향에서 하드 제약으로** 옮긴다.
"이 로봇은 1대당 부담 상위 N 개 화물을 맡지 않는다" 를 MILP 가 강제하게 만든다.

**왜** `reprice_agent_by_payload` 는 목적을 달성하지 못한다(실측: 두 판·전 체크포인트·
`light_bias` 32 까지 대상 로봇이 일을 **하나도 안 잃는다**). 원인은 원리적이다 — 대상 로봇을
밀어내면 운반 에너지가 **9.4배** 비싸지고(2.375 → 22.25) makespan 차이는 **0** 이라, 목적값
차이 전부가 에너지항이다. wear-leveling 은 "에너지를 일부러 더 쓴다"는 결정이므로 에너지항
안에서 싸우는 것은 자기모순이다. 제약으로 막으면 대가가 **목적값의 +0.06%**, 0.2초 OPTIMAL 이다.

**설계문서(구속력 있는 권위)** `docs/superpowers/specs/2026-09-01-cargo-ban-design.md`
계획과 spec 이 어긋나면 **spec 이 이긴다.**

---

## Global Constraints — 모든 태스크에 적용된다

🔴 **git**
- 작업트리에 **남의 삭제 218건**이 있다. `git add -A` · `git add .` · `git commit -a` **금지.**
  언제나 경로를 명시해서 스테이징하고, 커밋 전에 `git diff --cached --name-status | grep -c '^D'`
  가 **0** 인지 확인하라.
- `git checkout` · `git stash` · `git restore` · `git clean` **금지.**
- 브랜치: `oracle-rebuild-night-2026-08-10`

🔴 **실행 명령**
- Julia 는 **언제나** `julia +lts --project=.` (Manifest 가 1.10.11 에 고정). 맨 `julia` 금지.
- Python 은 레포 루트의 `.venv/bin/python`.

🔴 **시험 작성 규약**
- `test/runtests.jl` 은 모든 시험 파일을 **같은 `Main` 스코프**에 include 한다 →
  새 시험 파일은 **자기 `module` 로 감싸라.**
- navigator 계층이 필요하면:
  `isdefined(CB, :BatteryTruth) || CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))`
- 새 시험 파일은 `test/runtests.jl` 에 **등록**해야 한다. 안 하면 아무도 안 돌린다.

🔴 **측정 규약** (이 레포가 여러 번 데인 자리)
- **빈-통과 방지 단언을 반드시 넣어라.** "0개를 처리하고 초록" 이 최악이다. 이번 조사에서
  프로브가 실제로 `금지행=0` 으로 공허하게 초록을 냈다.
- **삼상 규약**: "못 쟀다" 는 `nothing` 이지 `0` 이 아니다. 절대 섞지 마라.
- **반환 심볼은 세계가 변했다는 증거가 아니다.** 세계를 직접 재라(배정·간선 수 등).
- 프로브의 모든 집계는 **함수 안**에서 하라 — Julia 최상위 `for` 의 카운터는 조용한 0 이 된다.
- 결정론 단위는 **디렉터리**다(프로세스가 아니다). 비교 실험은 한 프로세스 안에서 하라.

---

## 태스크 목록

| # | 파일 | 산출 | 게이트 |
|---|---|---|---|
| 1 | `task-1-owner-selector.md` | 🔴 spec §6 미결 해소 — 컴파일러가 쓸 소유자 선택자를 **측정으로** 정한다. production 코드 없음 | — (기록이 산출) |
| 2 | `task-2-constraint-type.md` | `ForbidHeavyCargo` 타입 + 컴파일러 + `referenced_ids` + export | G-1 |
| 3 | `task-3-standing-store.md` | 지속 금지 보관소 + `state_globals` 등록 + formulate 훅 | G-5 · G-6 |
| 4 | `task-4-lifetime.md` | `swap_battery!` 가 그 로봇의 금지를 해제 | G-3 |
| 5 | `task-5-fault-exception.md` | 고장 수습 중 금지를 끈다(보험) | G-4 |
| 6 | `task-6-scoped-release.md` | `release_pending_assignments!` 에 `agent` 범위 인자 | — |
| 7 | `task-7-alphabet.md` | 원시 `forbid_heavy_cargo` 추가 · `reprice_agent_by_payload` 제거 · 표 셋 | G-7 |
| 8 | `task-8-end-to-end.md` | 종단 — body 가 집행되고 **세계가 움직이는지** | G-2 · G-8 |

**Task 1 은 코드를 쓰지 않는다.** 측정해서 답을 기록하는 것이 산출이고, Task 2 가 그 답을 쓴다.

---

## 공용 픽스처 — 각 태스크의 시험이 쓰는 보조 함수

여러 태스크의 시험 코드가 `fixture()` · `busiest_pending_agent()` 를 부른다. **정본은 없다** —
아래를 각 시험 파일 안에 복사해 쓰라(시험 파일은 서로 격리된 module 이므로 공유하지 않는다).

```julia
"배터리·hazard·에너지 가중치가 켜진 env 를 만들어 `target_closed` 작업이 끝난 시점까지 전진."
function fixture(; board = "tractor.mpd", nr = 10, target_closed = 60)
    env = CB.run_lego_demo(; ldraw_file = board, project_name = "cargoban", num_robots = nr,
                             assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    # 🔴 셋 다 필요하다. run_lego_demo 는 배터리를 초기화하지 않고(→ :no_fleet),
    #    init_objective_weights! 없이는 목적함수가 edge_costs 를 통째로 버린다.
    CB.enable_battery!(env); CB.enable_hazard!(env; seed = 7); CB.init_objective_weights!()
    k = 0
    while length(CB.simstate_of(env).prog.closed) < target_closed && k < 6000
        CB.step_environment!(env); CB.update_planning_cache!(env, 0.0); k += 1; CB.set_sim_step!(k)
    end
    return env
end

"미래 배정 간선을 가장 많이 가진 로봇. 🔴 문자열은 **모듈 한정 형태**다 —
`\"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)\"`. 손으로 짧게 쓰면 조용히 못 찾는다."
function busiest_pending_agent_string(env)
    sched = env.sched; inv = CB.build_invariant(env)
    act = Set{CB.AbstractID}(CB.get_vtx_id(sched, v) for v in env.cache.active_set)
    t = Dict{String,Int}()
    for e in Graphs.edges(CB.get_graph(sched))
        v, v2 = e.src, e.dst
        CB.is_assignment_edge(sched, v, v2) || continue
        i1 = CB.get_vtx_id(sched, v); i2 = CB.get_vtx_id(sched, v2)
        (i1 in inv.closed_nodes || i2 in inv.closed_nodes || i1 in act || i2 in act) && continue
        o = CB._edge_owner_id(sched, v); o === nothing && continue
        t[string(o)] = get(t, string(o), 0) + 1
    end
    isempty(t) && error("미래 배정 간선이 0 — 재분배 창이 닫혔다. target_closed 를 줄여라")
    return sort(collect(t), by = kv -> -kv[2])[1][1]
end
```

⚠️ **재분배 창은 빌드 후반에 닫힌다** (실측: `closed ≈ 247/287` 부터 해제 가능 간선 0).
`target_closed` 를 너무 크게 잡으면 위 함수가 죽는다 — 그것이 설계대로의 신호다.

⚠️ `busiest_pending_agent_string` 은 **문자열**을 준다. `ForbidHeavyCargo` 는 `AbstractID` 를
받는다. 변환이 필요한 곳에서 **조용히 실패하지 않게** 하라(못 찾으면 `:unknown_agent`).

---

## 이미 있는 것 — 복사해서 쓸 프로브

| 파일 | 무엇을 보여주나 |
|---|---|
| `tools/probes/probe_minted_body_enacts.jl` | body 집행 + **세계를 양쪽에서 재는** 방식(Task 8 의 본보기) |
| `tools/probes/probe_scoped_release.jl` | 좁힌 release 구현(`release_scoped!`)과 `burden` 계산 |
| `tools/probes/probe_can_a_be_displaced.jl` | formulate 뒤 `Xa` 상계를 눌러 컴파일러 없이 금지 효과를 내는 기법 |
| `tools/probes/probe_ban_vs_fault.jl` | 금지 + 고장 실행가능성(Task 5 의 근거) |
| `tools/probes/probe_kappa_renormalization.jl` | 두 배정을 고정해 놓고 같은 비용으로 평가하는 방식 |
