# 공통 목적함수 J — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 세 respec 제안자(DP / surrogate / LLM)와 그 아래 두 플래너(greedy, MILP)가 **하나의 목적함수 J** 를 최소화하도록 배선한다.

**Architecture:** `objective.json` 을 단일 진실원으로 두고, Julia/Python 양쪽에 얇은 로더 + `J()` 구현을 하나씩 만든다. greedy 는 죽어 있던 `greedy_cost` 확장점을 되살려 디스패치로 비용을 고르게 하고, MILP 는 `DeprioritizeAgent` 에만 국소적으로 켜져 있던 κ 를 전역 기본값으로 승격한다. 모든 변경은 **동작보존 배선 → 검증 → 활성화** 순서로 쪼개져 있고, 배선 단계가 게이트다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`), Python 3.12 (`/home/chahj578/Construction_OODlayer/.venv/bin/python`), JuMP/HiGHS, JSON3.

**Spec:** `docs/superpowers/specs/2026-08-13-unified-objective-design.md`

---

## Scope Ruling (plan-level)

Spec §8 lists 9 단계. 이 계획은 **단계 1~5 + §9 검증 하니스**(= 코드 작업 전부)를 다룬다.
단계 6~9 는 코드가 아니라 **계산 캠페인**이다(630판 스윕 재실행, surrogate 재라벨·재학습,
prefix 결정성 재측정, DP 계획 재개). 각각 수 시간~수 일이 걸리고 단계 5 의 산출물에 게이트되므로,
이 계획이 끝난 뒤 별도 계획으로 집행한다. 단계 6~9 의 시간 추정은 이 문서 맨 끝 부록에 있다.

## Spec Corrections (실측으로 확인, 2026-08-13)

계획은 spec 이 아니라 **실제 코드**에 대해 작성됐다. spec 과 다른 확인 사실:

| Spec 진술 | 실제 |
|---|---|
| `cost_func` 클로저가 `task_assignment.jl:46-51` | **`src/task_assignment.jl:478-486`**. 게다가 `distance_dict` 메모이제이션을 품고 있다 |
| `set_planning_objective_weights` | 실제 이름은 **`set_planning_objective_weights!`** (bang), `essential_tg_coponents.jl:1274` |
| `get_objective_expr` 조기반환이 `:1423` | **`:1439`**. `:1423` 은 auto-scaling `if` 블록의 시작 |
| `verify()` 가 `replan.jl` 에 있음 | **`src/respec/verifier.jl:83`**. `replan.jl:932` 는 호출만 함 |
| `results_4pol` 에 **energy 필드가 없다** | **틀림.** `tools/monitor/run_demo.jl:648-663` 이 `"battery" → "total_energy_J"`, `"energy_per_closed"`, `min_soc`, `soc_spread` 를 이미 기록한다 |
| `results_4pol` 에 makespan 이 없다 | **맞음.** `sim_seconds = dt × steps` 만 있다 |
| `gen_oracle_dataset.jl` 이 라벨을 고른다 | **틀림.** 그건 raw dumper 다(`:1631-1635`). 라벨 선택은 Python `e1_analyze.cost_lex_key` 가 한다 |
| `gen_oracle_mc.jl` 이 energy 를 기록 | **안 한다.** `enable_battery!` 는 `:313` 에서 켜지만 `run_one` 의 반환 레코드(`:338-346`)에 에너지가 없다 |
| `dp_solve.py` 가 소비처 | **그 파일은 저장소에 없다.** 소비처 목록에서 제외 |
| `MACRO_COST` 가 3곳에 복붙 | **4곳** (`e1_analyze.py:220`, `export_surrogate.py:99`, `features_agnostic.py:164`, `gen_oracle_dataset.jl:1038`) + 파생 1곳(`action_registry.py:38`) |
| `update_greedy_cost_model!` 이 정의 없이 호출 | 맞음(`essential_tg_coponents.jl:1543`). **다만 도달 불가** — 그 경로는 `greedy_assignment!` 안이고, 그것을 부르는 `JuMP.optimize!(::AbstractGreedyAssignment)`(`:1549`) 는 더 구체적인 `JuMP.optimize!(::GreedyOrderedAssignment)`(`task_assignment.jl:378`) 에 가려진다. `GreedyAssignment` 는 저장소 어디서도 생성되지 않는다 |

## Global Constraints

이 절의 요구사항은 **모든 태스크에 암묵적으로 포함**된다.

1. **에너지 항은 J 의 완주 분기에만 들어간다** (spec §3.1). 미완주 분기에 에너지가 들어가면 "일찍 죽는 것"이 이득이 된다. 위반 시 즉시 실패.
2. **λ·MACRO_COST 는 J 에 들어가지 않는다** (spec §3.2). `MACRO_COST` 표 자체는 특징량으로 남기므로 **삭제하지 않는다** — 비용함수에서만 뺀다.
3. **`objective.json` 이 단일 진실원.** 상수(`kappa`, `C_fail`, `C_unclosed`, `tie_eps`, `T_scale`, `Eg_scale`, `M_ref`, `E_ref`)를 코드에 리터럴로 복붙하지 않는다.
4. **`null` 스케일로 J 를 계산하면 에러.** 0 이나 1 로 조용히 폴백하지 않는다 (spec §5).
5. **ENV 덮어쓰기 우선순위:** `MC_COST_FAIL` / `MC_COST_UNCLOSED` 가 설정돼 있으면 ENV 가 이기고, 그 사실이 산출물의 해시에 반영돼 **다른 세대로 취급**된다 (spec §5).
6. **`GreedyFinalTimeCost` 는 현행 동작을 바이트 단위로 보존한다** (spec §6.2). 태스크 2 의 게이트.
7. **배선과 활성화를 한 커밋에 섞지 않는다** (spec §8). 디스패치 배선(태스크 2)과 에너지 켜기(태스크 6)는 별개 태스크·별개 커밋.
8. **LLM 은 목적함수를 프롬프트로 받지 않는다.** `src/respec/llm_service/schema.py:214-218` 의 `"Never change the objective directly"` 문구를 **수정하지 않는다** (spec §6.3).
9. **Julia 명령은 언제나 `julia +lts --project=.`**. Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`.
10. **기대 baseline:** `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = **11 pass / 1 error** (Gurobi 라이선스 없음). 그 1 error 는 실패가 아니다. 그 이상으로 나빠지면 회귀다.
11. 작업 디렉토리 = `/home/chahj578/Construction_OODlayer`, 브랜치 = `oracle-rebuild-night-2026-08-10` (main/master 아님).
12. 커밋 메시지는 한 줄 요약 + 필요시 본문. 각 태스크는 자기 커밋(들)을 남긴다.

---

## File Structure

| 파일 | 신규/수정 | 책임 |
|---|---|---|
| `wm4spacecraft_manufacturing/objective.json` | 신규 | 목적함수 상수의 단일 진실원 |
| `wm4spacecraft_manufacturing/objective.py` | 신규 | Python 로더 + `J()` + 해시 + ENV 우선순위 |
| `wm4spacecraft_manufacturing/objective.jl` | 신규 | Julia 로더 + `J()` + 해시 (objective.py 와 동일 수식) |
| `wm4spacecraft_manufacturing/test_objective.py` | 신규 | J 의 단위검사 (§9 검사 중 계산 가능한 것 전부) |
| `wm4spacecraft_manufacturing/audit_objective.py` | 신규 | 소비처들이 같은 파일을 읽는지 기계적 감사 (`audit_action_vocab.py` 패턴) |
| `wm4spacecraft_manufacturing/measure_objective_scales.py` | 신규 | 기존 세대 덤프에서 `M_ref`/`E_ref` 측정 |
| `test/greedy_assignment_regression.jl` | 신규 | 태스크 2 의 게이트 — 배정 골든 해시 |
| `test/objective_hooks_smoke.jl` | 신규 | §9 의 배터리 훅 활성 검사 + greedy 디스패치 생존 검사 |
| `src/essential_tg_coponents.jl` | 수정 | `greedy_edge_cost` 디스패치 · `GreedyEnergyAwareCost` · 전역 κ 기본값 |
| `src/task_assignment.jl` | 수정 | `cost_func` 클로저를 `greedy_edge_cost` 디스패치로 |
| `src/respec/replan.jl` | 수정 | `DeprioritizeAgent` 국소 κ 스코프 제거 |
| `wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl` | 수정 | `energy_J` 기록 · `scalar_cost` → `J` |
| `tools/monitor/run_demo.jl` | 수정 | `makespan` 기록 |
| `wm4spacecraft_manufacturing/e1_analyze.py` | 수정 | `cost_lex_key` → J 기반 |

---

## Task 1: 런 레벨 기록 — `energy_J` 와 `makespan`

Spec §8 단계 1. **동작을 바꾸지 않는다** — 필드만 추가한다.
실측 결과 두 레인이 서로 다른 쪽이 비어 있다:

- `gen_oracle_mc.jl` (오라클 레인): `makespan` 은 있고 **에너지가 없다**. `enable_battery!` 는 `:313` 에서 이미 켜져 있으므로 `CB.battery_report()` 가 부르면 나온다.
- `tools/monitor/run_demo.jl` (4pol 평가 레인): 에너지는 `"battery"` 아래 이미 있고 **makespan 이 없다**. 이 레인은 `return_env_before_sim=true` 로 env 만 받아 **수동 루프**를 돌기 때문에 `stats[:Makespan]` 이 존재하지 않는다. 실현 makespan = `env.dt × result.steps` (= 지금의 `sim_seconds`).

**Ruling (계획자):** `run_demo.jl` 의 실현 makespan 은 `sim_seconds` 와 **같은 값**이지만, 여섯 소비처에게 "sim_seconds 가 makespan 이다"를 가르치는 대신 **명시적 `"makespan"` 키를 하나 더 쓴다.** 한 줄 비용으로 spec §2.3 이 지적한 모호함이 사라진다. 완주하지 않은 런에서도 값은 그대로 쓴다(그때는 "멈춘 시각"이며 J 의 미완주 분기에서 `tie_eps` 계수로만 쓰인다 — `gen_oracle_mc.jl:146` 의 현행 의미와 같다). 틀렸을 경우의 비용: 필드 하나가 중복되는 것뿐.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl:338-346`
- Modify: `tools/monitor/run_demo.jl:616-673`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces:
  - `gen_oracle_mc.jl` 의 `run_one` 반환 NamedTuple 에 `energy_J::Float64` 필드 추가 (배터리 없으면 `NaN`)
  - `run_demo.jl` 의 `DEMO_SUMMARY` JSONL 행에 최상위 `"makespan"` 키 추가 (`Float64` 또는 `null`)

- [ ] **Step 1: `gen_oracle_mc.jl` 의 반환 레코드에 `energy_J` 추가**

`wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl:338-346` 의 현행 코드는 이렇다:

```julia
    return (complete = CB.project_complete(env),
            closed    = length(env.cache.closed_set),
            total     = length(CB.get_nodes(env.sched)),
            makespan  = try Float64(get(stats, :Makespan, NaN)) catch; NaN end,
            seen      = SEEN[], n_events = N_EVENTS[],
            # 사후(post-decision) 고장 수 — rollout 들이 정말 서로 다른 미래를 겪었는지의 증거
            hz_break = hz.n_break, hz_cell = hz.n_cell, hz_zone = hz.n_zone,
            hz_pending_break = hz.n_break_pending, hz_capped = hz.capped,
            hz_sim_s = hz.t)
```

`makespan` 줄 바로 아래에 `energy_J` 를 끼워 넣는다:

```julia
    return (complete = CB.project_complete(env),
            closed    = length(env.cache.closed_set),
            total     = length(CB.get_nodes(env.sched)),
            makespan  = try Float64(get(stats, :Makespan, NaN)) catch; NaN end,
            # 실현 구동에너지[J] — 목적함수 J 의 완주 분기가 쓰는 값(objective.json, spec §3).
            # 배터리 레이어가 꺼져 있거나 report 가 실패하면 NaN(J 계산 시 에러로 드러난다).
            energy_J  = (try
                    local _fl = CB.BATTERY_FLEET[]
                    _fl === nothing ? NaN : Float64(CB.battery_report(_fl).total_energy_J)
                catch e
                    @warn "[MC] battery_report 실패 — energy_J=NaN" exception = e
                    NaN
                end),
            seen      = SEEN[], n_events = N_EVENTS[],
            # 사후(post-decision) 고장 수 — rollout 들이 정말 서로 다른 미래를 겪었는지의 증거
            hz_break = hz.n_break, hz_cell = hz.n_cell, hz_zone = hz.n_zone,
            hz_pending_break = hz.n_break_pending, hz_capped = hz.capped,
            hz_sim_s = hz.t)
```

- [ ] **Step 2: `run_one` 의 레코드가 JSONL 로 나가는 지점에서도 `energy_J` 가 살아 나가는지 확인**

`gen_oracle_mc.jl` 안에서 `run_one` 의 반환값이 JSONL 로 직렬화되는 곳을 찾는다:

```bash
cd /home/chahj578/Construction_OODlayer && grep -n "append_unit!\|JSON3.write\|run_one(" wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl
```

레코드를 **필드 화이트리스트로 골라 쓰는** 코드가 있으면 거기에도 `energy_J` 를 추가한다.
NamedTuple 을 통째로 직렬화하고 있으면 추가 작업 없음. 어느 쪽인지 report 파일에 적는다.

- [ ] **Step 3: `run_demo.jl` 의 요약 행에 `"makespan"` 추가**

`tools/monitor/run_demo.jl` 의 `rec = Dict(...)` 안, 현행 `"sim_seconds"` 줄은 이렇다:

```julia
            "sim_seconds" => (try Float64(env.dt) * result.steps catch; nothing end),
```

바로 아래에 추가한다:

```julia
            # 실현 makespan[sim s] — 이 레인은 return_env_before_sim=true 로 수동 루프를 돌기 때문에
            # 플래너의 stats[:Makespan] 이 존재하지 않는다. 실현 시간 = dt × steps 가 곧 makespan 이다.
            # sim_seconds 와 같은 값이지만, 목적함수 J 의 소비처가 이름으로 읽게 하려고 별도 키로 낸다.
            "makespan" => (try Float64(env.dt) * result.steps catch; nothing end),
```

- [ ] **Step 4: 정적 확인 — 두 파일이 파싱되고 필드가 실제로 들어갔는지**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e 'include("tools/monitor/run_demo.jl")' 2>&1 | head -3   # (실행됨 — 아래 주의 참조)
```

**주의:** `run_demo.jl` 은 include 하면 실제로 데모를 돌린다. 대신 파싱만 검사한다:

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e 'Meta.parseall(read("tools/monitor/run_demo.jl", String)); println("run_demo.jl parses OK")'
julia +lts --project=. -e 'Meta.parseall(read("wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl", String)); println("gen_oracle_mc.jl parses OK")'
grep -c '"makespan" =>' tools/monitor/run_demo.jl                       # 기대: 1
grep -c 'energy_J  =' wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl   # 기대: 1
```

Expected: 두 파일 모두 `parses OK`, 두 grep 모두 `1`.

- [ ] **Step 5: 실동작 스모크 — 4pol 레인 한 판**

한 판을 돌려 `makespan` 이 실제로 유한한 값으로 찍히는지 본다. 6~10분 걸린다.

```bash
cd /home/chahj578/Construction_OODlayer
rm -f /tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t1_smoke.jsonl
DEMO_SUMMARY=/tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t1_smoke.jsonl \
DEMO_SEED=3 DEMO_OOD_SEED=3 \
  timeout 3600 julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tail -5
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json,sys
r=json.loads(open('/tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t1_smoke.jsonl').readline())
assert 'makespan' in r, 'makespan key missing'
assert isinstance(r['makespan'], float) and r['makespan'] > 0, r['makespan']
b = r.get('battery') or {}
assert b.get('total_energy_J', 0) > 0, ('energy missing/zero', b)
print('OK makespan=%.3f energy_J=%.1f sim_seconds=%.3f' % (r['makespan'], b['total_energy_J'], r['sim_seconds']))
"
```

Expected: `OK makespan=... energy_J=... sim_seconds=...` 이고 `makespan == sim_seconds`.
**실패하면 멈추고 보고한다** — 이 값이 J 의 입력이므로 여기서 틀리면 이후 전부 오염된다.

- [ ] **Step 6: 실동작 스모크 — 오라클 레인 1 rollout**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
MC_K=1 MC_ACTIONS=0 ORACLE_LOG=/tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t1_mc.jsonl \
  timeout 3600 julia +lts --project=/home/chahj578/Construction_OODlayer oracle/gen_oracle_mc.jl 2>&1 | tail -20
```

출력 JSONL 에 `energy_J` 가 있고 유한하며 0 보다 큰지 확인한다. **`ORACLE_LOG` / `MC_ONLY` /
`MC_AGGREGATE` 의 실제 의미는 스크립트 상단 주석에서 먼저 읽는다** — 출력 경로 이름이 다르면
그쪽을 쓰고, 무엇을 썼는지 report 파일에 적는다.

이 스모크가 30분 안에 끝나지 않으면 **중단하고**, 대신 Step 4 의 정적 확인 + 다음 근거로 갈음한다:
`gen_oracle_dataset.jl:1471-1475` 가 **이미 같은 방식으로** `CB.battery_report(fl).total_energy_J` 를
읽어 정상 동작하고 있다(같은 API, 같은 배터리 설정). 갈음했다면 report 파일에 그 사실을 적는다.

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl tools/monitor/run_demo.jl
git commit -m "feat(objective): record realized energy_J (MC lane) and makespan (4pol lane)

목적함수 J 의 두 입력이 각 레인에서 반쪽씩 비어 있었다:
- gen_oracle_mc.jl: 배터리는 켜져 있으나 energy_J 를 반환 레코드에 안 담았다
- run_demo.jl: 에너지는 battery.* 아래 있으나 makespan 키가 없었다(sim_seconds 로 대신)
동작 변경 없음 — 필드 추가만. spec §8 단계 1."
```

---

## Task 2: greedy 비용을 `greedy_cost` 디스패치로 배선 — **차단 게이트**

Spec §8 단계 2, §6.2, §11-6. **이 태스크는 동작을 바꾸지 않는다.** 죽어 있던 확장점을 살리되,
기존 `GreedyCost` 타입 전부가 **현행 공식을 그대로** 내도록 한다. 에너지는 태스크 6 에서 켠다.

실측 확인: `greedy_cost` 필드는 4곳에서 쓰이고 **읽히는 곳은 `task_assignment.jl:360`
한 곳뿐**이며, 그마저 다음 struct 로 값을 넘기기만 한다. 실제 비용은
`task_assignment.jl:478-486` 의 클로저에 하드코딩돼 있다.

**Ruling (계획자):** 세 기존 타입(`GreedyPathLengthCost`, `GreedyFinalTimeCost`,
`GreedyLowerBoundCost`)은 **전부 같은 현행 공식**을 낸다. `GreedyPathLengthCost` 에
"거리만" 같은 그럴듯한 의미를 새로 부여하지 않는다 — 그것이 `GreedyOrderedAssignment` 의
**기본값**(`task_assignment.jl:275`)이므로, 의미를 주는 순간 기본 생성된 모델의 동작이 조용히
바뀐다. 지금 세 타입은 구분 불가능한 죽은 마커이고, 구분 불가능한 채로 유지하는 것이
바이트 보존 계약(Global Constraint 6)이다. 틀렸을 경우의 비용: 나중에 누가
`GreedyPathLengthCost` 에 의미를 주고 싶어지면 그때 별도 커밋으로 하면 된다.

**Files:**
- Modify: `src/essential_tg_coponents.jl:1457-1461` (타입 정의 근처에 `greedy_edge_cost` 추가)
- Modify: `src/task_assignment.jl:478-486` (클로저 → 디스패치)
- Create: `test/greedy_assignment_regression.jl`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `greedy_edge_cost(gc::GreedyCost, sched, v, v2, dt::Float64)::Float64` — 태스크 6 이 여기에 `GreedyEnergyAwareCost` 메서드를 하나 더 붙인다
  - `test/greedy_assignment_regression.jl` — 태스크 6 이 다시 돌린다

- [ ] **Step 1: 회귀 게이트의 골든값을 먼저 만든다 (코드 변경 전!)**

**순서가 중요하다.** 변경 *전에* 골든을 떠야 회귀를 잡을 수 있다.

`test/greedy_assignment_regression.jl` 을 만든다:

```julia
# ============================================================================
#  greedy 배정 회귀 게이트 (spec §9 "greedy 회귀 검사", 계획 태스크 2)
#
#  assign_collaborative_tasks! 는 이 저장소의 모든 숫자가 올라앉은 핵심 스케줄링 함수다.
#  비용 클로저를 greedy_cost 디스패치로 바꾸는 변경이 배정을 **한 엣지도** 바꾸지 않았음을
#  기계적으로 증명한다.
#
#  왜 시뮬레이션이 아니라 배정만 보는가:
#    이 하니스의 시뮬레이션은 런간 재현성이 없다(makespan 노이즈 ~4.6%, spec §4.2).
#    반면 **배정 단계는 결정적이다** — run_lego_demo(return_env_before_sim=true) 는
#    고정 rng 로 스케줄을 세우고 거기서 멈춘다. 그러므로 게이트는 시뮬 결과가 아니라
#    배정 그래프 자체에 건다.
#
#  사용법:
#    골든 생성:  GREEDY_GOLDEN_WRITE=1 julia +lts --project=. test/greedy_assignment_regression.jl
#    검사:       julia +lts --project=. test/greedy_assignment_regression.jl
# ============================================================================

using ConstructionBots
using Test
using Random
using Graphs
using SHA
const CB = ConstructionBots

const GOLDEN_PATH = joinpath(@__DIR__, "greedy_assignment_golden.txt")
const SEED = 3
const NROB = 12

"고정 시드로 env 를 배정 직후 상태까지만 세운다(시뮬 안 함)."
function build_env()
    model = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd")
    return CB.run_lego_demo(; ldraw_file = model, project_name = "greedy_reg",
        num_robots = NROB, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(SEED))
end

"""
배정 결과의 정규 지문. 두 성분을 담는다:
  (1) 스케줄 그래프의 모든 엣지 (정렬) — 어떤 로봇이 어떤 일감에 붙었는가
  (2) 모든 정점의 tF (6자리 반올림) — 언제 끝나는가
비용식이 조금이라도 달라지면 argmin 이 갈리고 둘 중 하나가 반드시 바뀐다.
"""
function assignment_fingerprint(env)
    sched = env.sched
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    println(io, "--tF--")
    for v in 1:Graphs.nv(sched)
        println(io, v, "=", round(CB.get_tF(sched, v), digits = 6))
    end
    body = String(take!(io))
    return bytes2hex(SHA.sha256(body)), body
end

env = build_env()
digest, body = assignment_fingerprint(env)

if get(ENV, "GREEDY_GOLDEN_WRITE", "0") == "1"
    open(GOLDEN_PATH, "w") do io
        println(io, digest)
        print(io, body)
    end
    println("[greedy-reg] GOLDEN WRITTEN: $digest -> $GOLDEN_PATH")
    println("[greedy-reg] edges+tF lines = ", count(==('\n'), body))
else
    @testset "greedy 배정 회귀 (디스패치 배선이 배정을 바꾸지 않는다)" begin
        @test isfile(GOLDEN_PATH)
        golden_lines = readlines(GOLDEN_PATH)
        golden_digest = first(golden_lines)
        if digest != golden_digest
            # 어디가 갈렸는지 알려준다 — 해시만 다르다고 하면 디버깅이 불가능하다.
            golden_body = join(golden_lines[2:end], "\n") * "\n"
            gl = split(golden_body, '\n'); nl = split(body, '\n')
            for i in 1:min(length(gl), length(nl))
                gl[i] == nl[i] || (println("[greedy-reg] 첫 불일치 line $i: golden=$(gl[i]) new=$(nl[i])"); break)
            end
            println("[greedy-reg] golden lines=$(length(gl)) new lines=$(length(nl))")
        end
        @test digest == golden_digest
    end
end
```

- [ ] **Step 2: 골든 생성 — 아직 코드는 안 건드린 상태로**

```bash
cd /home/chahj578/Construction_OODlayer
GREEDY_GOLDEN_WRITE=1 timeout 3600 julia +lts --project=. test/greedy_assignment_regression.jl 2>&1 | tail -5
```

Expected: `[greedy-reg] GOLDEN WRITTEN: <64자 hex> -> .../greedy_assignment_golden.txt`

**모델 파일 이름 주의:** `tractor.mpd` 가 없으면 `run_lego_demo` 가 던진다. 실제로 쓸 수 있는
모델은 이렇게 찾는다 — `test/test_demo.jl` 이 무엇을 쓰는지 먼저 보고 같은 것을 쓴다:

```bash
grep -n "ldraw_file\|\.mpd\|\.ldr" test/test_demo.jl | head -10
```

찾은 이름으로 `build_env()` 의 기본값을 고친다.

- [ ] **Step 3: 골든이 재현되는지 확인 (같은 코드로 두 번)**

```bash
cd /home/chahj578/Construction_OODlayer
timeout 3600 julia +lts --project=. test/greedy_assignment_regression.jl 2>&1 | tail -10
```

Expected: `Test Summary: ... | 2 passed`.

**이것이 통과하지 않으면 게이트 자체가 무의미하다** — 배정이 결정적이지 않다는 뜻이므로,
멈추고 BLOCKED 로 보고한다. (계획자 주: 배정은 결정적일 것으로 예상하지만, 이 저장소는
시뮬 재현성이 깨져 있는 전력이 있으므로 실제로 확인해야 한다.)

- [ ] **Step 4: 골든을 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add test/greedy_assignment_regression.jl test/greedy_assignment_golden.txt
git commit -m "test(greedy): assignment fingerprint regression gate (pre-change golden)

배정 그래프 엣지 + 전 정점 tF 의 sha256. 시뮬이 아니라 배정만 본다 —
이 하니스는 런간 재현성이 없지만(makespan 노이즈 ~4.6%) 배정 단계는 결정적이다.
spec §9 'greedy 회귀 검사' / 계획 태스크 2 의 게이트."
```

- [ ] **Step 5: `greedy_edge_cost` 디스패치 함수를 추가**

`src/essential_tg_coponents.jl` 의 `GreedyCost` 타입 정의(1457-1461) **바로 아래**에 넣는다.
현행 정의는 이렇다:

```julia
abstract type AbstractGreedyAssignment <: TaskGraphsMILP end
abstract type GreedyCost end
struct GreedyPathLengthCost <: GreedyCost end
struct GreedyFinalTimeCost <: GreedyCost end
struct GreedyLowerBoundCost <: GreedyCost end
```

그 뒤에 추가:

```julia
# ---------------------------------------------------------------------------
# greedy 배정의 엣지 비용 — 디스패치 확장점 (spec §6.2, 계획 태스크 2)
#
# 배경: 위 세 타입은 `GreedyOrderedAssignment.greedy_cost` 에 저장돼 있었지만 **읽는 메서드가
#   하나도 없었다**. 실제 비용은 assign_collaborative_tasks! 안의 클로저에 하드코딩돼 있었고,
#   어느 타입을 넘겨도 동작이 같았다. 여기서 그 확장점을 살린다.
#
# 계약(중요): 세 기존 타입은 **전부 현행 공식을 그대로** 낸다. GreedyPathLengthCost 는
#   GreedyOrderedAssignment 의 기본값이므로, 여기에 "거리만" 같은 새 의미를 주면 기본 생성된
#   모델의 스케줄이 조용히 바뀐다. 구분 불가능한 채로 두는 것이 바이트 보존 계약이다.
#   에너지를 보는 새 타입은 별도 커밋에서 추가한다(GreedyEnergyAwareCost).
#
# 인자: sched=스케줄, v=출발 정점(로봇의 현재 go 노드), v2=도착 정점(일감 슬롯),
#       dt=v→v2 이동에 걸리는 최소 소요시간(min_duration; 호출자가 캐시해 넘긴다).
greedy_edge_cost(::GreedyPathLengthCost, sched, v, v2, dt::Float64) = get_tF(sched, v) + dt
greedy_edge_cost(::GreedyFinalTimeCost,  sched, v, v2, dt::Float64) = get_tF(sched, v) + dt
greedy_edge_cost(::GreedyLowerBoundCost, sched, v, v2, dt::Float64) = get_tF(sched, v) + dt
```

`export` 목록이 이 파일에 있으면 `greedy_edge_cost` 도 export 한다(같은 파일에서
`export GreedyPathLengthCost` 같은 줄을 찾아 그 옆에 붙인다). 없으면 `CB.greedy_edge_cost`
로 접근 가능하므로 그대로 둔다.

- [ ] **Step 6: `assign_collaborative_tasks!` 의 클로저를 디스패치로 바꾼다**

`src/task_assignment.jl:478-486` 의 현행 코드:

```julia
    cost_func = (v,v2)->begin
        if !haskey(distance_dict,(v,v2))
            new_node = align_with_successor(get_node(sched,v).node,get_node(sched,v2).node)
            distance_dict[(v,v2)] = generate_path_spec(sched,scene_tree,new_node).min_duration
        end
        return get_tF(sched,v) + distance_dict[(v,v2)]
        # return distance_dict[(v,v2)]
        # get_edge_cost(model,D,v,v2)
    end
```

이렇게 바꾼다 — **메모이제이션은 그대로 두고, 마지막 한 줄만 디스패치로 넘긴다**:

```julia
    # 비용 계산은 model.greedy_cost 로 디스패치한다(essential_tg_coponents.jl 의 greedy_edge_cost).
    # 이 필드는 예전부터 있었으나 읽는 곳이 없어 죽어 있었다(spec §2.4). 기본 타입들은 전부
    # 예전 공식(get_tF + 이동시간)을 그대로 내므로 이 변경만으로는 배정이 바뀌지 않는다 —
    # test/greedy_assignment_regression.jl 이 그것을 강제한다.
    gcost = model.greedy_cost
    cost_func = (v,v2)->begin
        if !haskey(distance_dict,(v,v2))
            new_node = align_with_successor(get_node(sched,v).node,get_node(sched,v2).node)
            distance_dict[(v,v2)] = generate_path_spec(sched,scene_tree,new_node).min_duration
        end
        return greedy_edge_cost(gcost, sched, v, v2, distance_dict[(v,v2)])
    end
```

`distance_dict` 는 `Dict{Tuple{Int,Int},Float64}` 이므로 값은 이미 `Float64` 다 —
`greedy_edge_cost` 의 `dt::Float64` 시그니처와 맞는다.

- [ ] **Step 7: 회귀 게이트를 돌린다 — 이것이 태스크 2 의 통과 조건**

```bash
cd /home/chahj578/Construction_OODlayer
timeout 3600 julia +lts --project=. test/greedy_assignment_regression.jl 2>&1 | tail -15
```

Expected: `Test Summary: ... | 2 passed`, 즉 **해시가 골든과 정확히 같다**.

**해시가 다르면 다음으로 가지 않는다.** 출력의 `첫 불일치 line` 을 읽고 원인을 찾는다.
흔한 원인: `get_tF` 를 두 번 부르는 순서 차이는 아니고, 대개 `Float64` 승격이나
`gcost` 를 클로저 밖에서 잡지 않아 타입 불안정이 생긴 경우다.

- [ ] **Step 8: 전체 테스트 스위트 — 기대 baseline 유지 확인**

```bash
cd /home/chahj578/Construction_OODlayer
timeout 5400 julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -25
```

Expected: **11 passed / 1 errored** (Gurobi 라이선스 없음 — Global Constraint 10).
이보다 나빠지면 회귀다.

- [ ] **Step 9: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add src/essential_tg_coponents.jl src/task_assignment.jl
git commit -m "refactor(greedy): dispatch edge cost through model.greedy_cost

greedy_cost 필드는 4곳에서 쓰였으나 읽히는 곳이 한 군데(값 전달)뿐이었다 —
실제 비용은 assign_collaborative_tasks! 의 클로저에 하드코딩. 그 확장점을 살린다.
기존 세 GreedyCost 타입은 전부 현행 공식(get_tF + dt)을 그대로 내므로 동작 불변:
test/greedy_assignment_regression.jl 해시 일치로 확인. spec §6.2 / §8 단계 2."
```

- [ ] **Step 10: 죽은 코드 확인 및 제거 (spec §11-7) — 별도 커밋**

spec §11-7 이 확인하라고 한 것: `update_greedy_cost_model!` 이 정의 없이 호출되는데
그 경로가 죽은 코드인지 도달 시 던지는지.

**확인된 사실** (계획 단계 실측):
- `update_greedy_cost_model!` 은 저장소 어디에도 **정의가 없다**. 호출은 `essential_tg_coponents.jl:1543` 한 곳.
- 그 줄은 `greedy_assignment!` 안에 있고, `greedy_assignment!` 를 부르는 것은
  `JuMP.optimize!(model::AbstractGreedyAssignment)` (`:1549`) 뿐이다.
- 그 메서드는 더 구체적인 `JuMP.optimize!(model::GreedyOrderedAssignment)`
  (`task_assignment.jl:378`) 에 언제나 가려진다.
- `GreedyAssignment`(`essential_tg_coponents.jl:1483-1489`) 는 저장소 어디서도 **생성되지 않는다**.

먼저 스스로 재확인한다:

```bash
cd /home/chahj578/Construction_OODlayer
grep -rn "update_greedy_cost_model!" --include=*.jl .          # 기대: 호출 1곳만, 정의 0곳
grep -rn "GreedyAssignment(" --include=*.jl . | grep -v "GreedyOrderedAssignment("   # 기대: 0곳
```

두 기대가 모두 맞으면 `greedy_assignment!` 함수(1520-1548), 그 아래
`JuMP.optimize!(model::AbstractGreedyAssignment) = greedy_assignment!(model)` (1549) 을
**삭제하지 말고**, 대신 죽은 코드임을 못박는 주석을 함수 바로 위에 단다:

```julia
# ⚠️ DEAD CODE (2026-08-13 확인). 이 함수는 도달 불가다:
#   - 유일한 진입로 JuMP.optimize!(::AbstractGreedyAssignment) 는 언제나 더 구체적인
#     JuMP.optimize!(::GreedyOrderedAssignment)(task_assignment.jl:378)에 가려진다.
#   - 유일한 다른 구체 타입 GreedyAssignment 는 저장소 어디서도 생성되지 않는다.
#   - 그리고 아래 update_greedy_cost_model! 은 저장소에 **정의가 없다** — 도달하면 UndefVarError.
# 지우지 않고 표시만 하는 이유: TaskGraphs.jl 계열 상위 패키지가 이 이름을 기대할 수 있고,
# 삭제는 이 계획(목적함수 통일)의 범위 밖이다. spec §11-7 의 "확인" 요구는 이것으로 충족.
```

**Ruling (계획자):** spec §11-7 은 "죽은 코드면 지운다"고 했으나 **표시만 하고 남긴다.**
이유: 이 계획의 게이트는 "동작 불변"이고, 죽은 코드 삭제는 그 계약에 아무 것도 보태지 않으면서
`AbstractGreedyAssignment` 를 쓰는 외부 코드를 깨뜨릴 위험만 있다. 삭제는 값이 0 이고
위험은 0 이 아니다. 틀렸을 경우의 비용: 죽은 코드 30줄이 한 릴리스 더 남는 것.

```bash
cd /home/chahj578/Construction_OODlayer
git add src/essential_tg_coponents.jl
git commit -m "docs(greedy): mark greedy_assignment! / update_greedy_cost_model! as dead code

spec §11-7 확인 결과: 정의 없는 update_greedy_cost_model! 을 부르지만 그 경로는 도달 불가
(구체 메서드에 가려짐 + GreedyAssignment 는 생성되지 않음). 표시만 하고 삭제는 범위 밖."
```

---

## Task 3: 스케일 측정 — `M_ref` / `E_ref` / `T_scale` / `Eg_scale`

Spec §8 단계 3, §4. κ 를 정하려면 시간·에너지 스케일을 먼저 알아야 한다.
**태스크 4 가 `objective.json` 을 만들 때 그 숫자를 박아 넣는다** — 그러므로 이 태스크는
파일을 쓰지 않고 **측정 리포트**를 낸다.

**Ruling (계획자):** spec §8 은 단계 3(측정) → 단계 4(`objective.json` 생성) 순인데,
측정 결과를 어디에 쓸지가 그때 없다. 그래서 이 태스크는 스크래치패드에 JSON 리포트를 쓰고,
태스크 4 가 그 리포트를 읽어 `objective.json` 을 만든다. spec 의 순서 의도(측정이 κ 의 유일한
근거)는 그대로 지킨다. 틀렸을 경우의 비용: 없음 — 순서와 근거가 동일하다.

**Files:**
- Create: `wm4spacecraft_manufacturing/measure_objective_scales.py`

**Interfaces:**
- Consumes: 태스크 1 이 추가한 `makespan`(4pol 레인) / `energy_J`(MC 레인) 필드. **다만 기존 세대 덤프에는 그 필드가 없다** — 아래 Step 1 의 폴백 규칙을 따른다.
- Produces: JSON 리포트 (스크래치패드), 키: `M_ref`, `E_ref`, `T_scale`, `Eg_scale`, `n_samples`, `sources`, `notes`

- [ ] **Step 1: 어떤 덤프가 실제로 쓸 수 있는지 먼저 조사한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
ls results_4pol/*.jsonl 2>/dev/null
find results_4pol* -name 'rows.jsonl' 2>/dev/null | head
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json, glob, collections
paths = sorted(glob.glob('results_4pol/*.jsonl')) + sorted(glob.glob('results_4pol*/shards/*/*/rows.jsonl'))
print('files:', len(paths))
keys = collections.Counter(); n = 0; ncomp = 0; nener = 0
for p in paths[:400]:
    for line in open(p):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        n += 1; keys.update(r.keys())
        if r.get('complete'): ncomp += 1
        if (r.get('battery') or {}).get('total_energy_J'): nener += 1
print('rows=%d complete=%d with_energy=%d' % (n, ncomp, nener))
print('keys:', sorted(keys))
"
```

이 출력이 **측정의 근거**다. report 파일에 그대로 붙인다.

**폴백 규칙:** 기존 세대 행에는 `makespan` 키가 없다(태스크 1 이 이제 막 추가했다).
그 행들에는 `sim_seconds` 를 makespan 으로 쓴다 — 태스크 1 에서 확인했듯 두 값은
**같은 계산**(`dt × steps`)이다. 에너지는 `row["battery"]["total_energy_J"]` 에서 읽는다.

완주 행이 **30개 미만**이면 표본이 너무 작다. 그때는 멈추지 말고, `n_samples` 를 리포트에
정직하게 적고 `notes` 에 "표본 부족 — κ 의 실효 크기가 흔들릴 수 있다(spec §11-3)" 를 넣는다.

- [ ] **Step 2: `measure_objective_scales.py` 를 쓴다**

```python
#!/usr/bin/env python3
"""목적함수 J 의 스케일 상수를 기존 세대 런에서 측정한다 (spec §4, §8 단계 3).

    M_ref / E_ref  = 완주 런의 makespan / energy_J 중앙값 → w_E = kappa * M_ref / E_ref
    T_scale        = M_ref 와 같다 (J 의 시간항 규모 = 런의 시간 규모)
    Eg_scale       = greedy 한 배정 결정 하나의 에너지 규모.
                     직접 계측한 적이 없으므로 여기서는 **런 에너지 / 닫힌 노드 수**로 근사한다
                     (= 결정 한 건이 평균적으로 지불하는 에너지). 근사임을 notes 에 명시한다.

이 스크립트는 아무 파일도 고치지 않는다 — JSON 리포트만 stdout/‑o 로 낸다.
objective.json 은 태스크 4 가 이 리포트를 읽어 만든다.

사용:
    .venv/bin/python measure_objective_scales.py -o /path/to/report.json
"""
import argparse, glob, json, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _rows(patterns):
    """주어진 glob 패턴들에서 JSONL 행을 전부 읽는다. 깨진 줄은 건너뛴다."""
    seen_files = []
    for pat in patterns:
        for path in sorted(glob.glob(os.path.join(HERE, pat))):
            seen_files.append(os.path.relpath(path, HERE))
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line), path
                    except json.JSONDecodeError:
                        continue
    _rows.files = seen_files


def _makespan(row):
    """실현 makespan. 신세대 행은 'makespan', 구세대 행은 'sim_seconds'(같은 dt*steps 계산)."""
    for k in ("makespan", "sim_seconds"):
        v = row.get(k)
        if isinstance(v, (int, float)) and v > 0:
            return float(v)
    return None


def _energy(row):
    """실현 구동에너지[J]. 4pol 레인은 battery 하위, 오라클 레인은 최상위 energy_J."""
    v = row.get("energy_J")
    if isinstance(v, (int, float)) and v > 0:
        return float(v)
    b = row.get("battery") or {}
    v = b.get("total_energy_J")
    if isinstance(v, (int, float)) and v > 0:
        return float(v)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=None, help="리포트 JSON 경로 (없으면 stdout)")
    ap.add_argument("--glob", action="append", default=None,
                    help="스캔할 glob 패턴 (반복 가능). 기본: results_4pol 계열 전부")
    args = ap.parse_args()

    patterns = args.glob or [
        "results_4pol/*.jsonl",
        "results_4pol*/shards/*/*/rows.jsonl",
        "results_oracle*/shards/*/*/rows.jsonl",
    ]

    mks, ens, per_closed = [], [], []
    n_total = n_complete = 0
    files = []
    for row, path in _rows(patterns):
        n_total += 1
        if path not in files:
            files.append(os.path.relpath(path, HERE))
        if not row.get("complete"):
            continue
        m, e = _makespan(row), _energy(row)
        if m is None or e is None:
            continue
        n_complete += 1
        mks.append(m)
        ens.append(e)
        closed = row.get("closed") or 0
        if closed > 0:
            per_closed.append(e / closed)

    if n_complete == 0:
        print(json.dumps({"error": "완주 + makespan + energy 를 모두 가진 행이 하나도 없다",
                          "n_rows_scanned": n_total, "files": files[:20]},
                         ensure_ascii=False, indent=2))
        return 1

    M_ref = statistics.median(mks)
    E_ref = statistics.median(ens)
    Eg_scale = statistics.median(per_closed) if per_closed else None

    notes = []
    if n_complete < 30:
        notes.append("표본 부족(완주 %d건 < 30) — κ 의 실효 크기가 흔들릴 수 있다 (spec §11-3)" % n_complete)
    notes.append("Eg_scale 은 직접 계측이 아니라 '런 에너지 / 닫힌 노드 수'의 중앙값 근사다 "
                 "(greedy 결정 한 건의 에너지 규모를 계측한 적이 없다).")
    notes.append("구세대 행은 makespan 키가 없어 sim_seconds(= dt × steps, 같은 계산)를 썼다.")

    report = {
        "M_ref": M_ref,
        "E_ref": E_ref,
        "T_scale": M_ref,     # J 의 시간항 규모 = 런의 makespan 규모
        "Eg_scale": Eg_scale,
        "n_samples": n_complete,
        "n_rows_scanned": n_total,
        "makespan_stats": {"median": M_ref, "min": min(mks), "max": max(mks),
                           "stdev": statistics.stdev(mks) if len(mks) > 1 else 0.0},
        "energy_stats": {"median": E_ref, "min": min(ens), "max": max(ens),
                         "stdev": statistics.stdev(ens) if len(ens) > 1 else 0.0},
        "sources": files[:50],
        "notes": notes,
    }
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text + "\n")
        print("wrote %s" % args.out)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python measure_objective_scales.py \
  -o /tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/objective_scales.json
```

Expected: `M_ref`, `E_ref`, `Eg_scale` 가 유한한 양수. `n_samples` 를 report 파일에 적는다.

`error` 가 나오면 Step 1 의 조사 결과로 `--glob` 패턴을 고쳐 다시 돌린다.
그래도 0건이면 **BLOCKED** — 기존 세대 덤프에 에너지가 기록된 완주 런이 없다는 뜻이므로,
태스크 1 의 계측을 켠 채 짧은 파일럿(4~6판)을 돌려야 한다. 그 경우 다음을 쓴다:

```bash
cd /home/chahj578/Construction_OODlayer
for s in 1 2 3 4; do
  DEMO_SUMMARY=/tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/pilot.jsonl \
  DEMO_SEED=$s DEMO_OOD_SEED=$s timeout 3600 julia +lts --project=. tools/monitor/run_demo.jl > /dev/null 2>&1
done
```
그런 다음 `--glob` 대신 그 파일을 가리키게 스크립트를 한 번 더 돌린다
(패턴 인자를 절대경로로 받도록 `--glob` 이 이미 지원한다 — `HERE` 와 조인되므로 상대경로로 준다).
파일럿은 판당 ~2분, 4판이면 ~8~15분.

- [ ] **Step 4: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/measure_objective_scales.py
git commit -m "feat(objective): measure M_ref/E_ref/T_scale/Eg_scale from existing-generation runs

κ 를 정하려면 시간·에너지 스케일이 먼저 필요하다(spec §8 단계 3). 이 스크립트는 아무 것도
고치지 않고 리포트만 낸다 — objective.json 은 다음 태스크가 이 숫자로 만든다."
```

리포트 JSON 전체를 report 파일에 붙여 넣는다 — **다음 태스크가 그 숫자를 읽는다.**

---

## Task 4: `objective.json` + J 구현 (Python·Julia) + 단위검사

Spec §5, §3, §9. 목적함수의 단일 진실원과 그것을 읽는 얇은 로더 둘.

**Files:**
- Create: `wm4spacecraft_manufacturing/objective.json`
- Create: `wm4spacecraft_manufacturing/objective.py`
- Create: `wm4spacecraft_manufacturing/objective.jl`
- Create: `wm4spacecraft_manufacturing/test_objective.py`

**Interfaces:**
- Consumes: 태스크 3 의 리포트에서 `M_ref`, `E_ref`, `T_scale`, `Eg_scale`, `n_samples`
- Produces (태스크 5·6 이 이 이름들을 쓴다):
  - Python: `objective.load() -> dict`, `objective.J(*, complete, closed, total, makespan, energy_J, cfg=None) -> float`, `objective.objective_hash(cfg=None) -> str`, `objective.ObjectiveError`
  - Julia: `Objective.load()`, `Objective.J(; complete, closed, total, makespan, energy_J, cfg=nothing)`, `Objective.objective_hash(cfg=nothing)`

- [ ] **Step 1: `objective.json` 을 만든다**

`C_fail` / `C_unclosed` / `tie_eps` 는 **새로 정하지 않고** `gen_oracle_mc.jl:142-144` 의
현행 값을 그대로 옮긴다. `M_ref`/`E_ref`/`T_scale`/`Eg_scale` 은 태스크 3 리포트의 숫자를 박는다.

`wm4spacecraft_manufacturing/objective.json`:

```json
{
  "_doc": [
    "목적함수 J 의 단일 진실원. 이 값들이 코드에 리터럴로 복붙되면 조용히 갈린다.",
    "함정 29(MACRO_COST 가 4곳에 복붙됨)를 목적함수에서 미리 막는다.",
    "J(run) = complete ? makespan + w_E*energy_J : C_fail + C_unclosed*(total-closed) + tie_eps*makespan",
    "w_E = kappa * M_ref / E_ref  (무차원 kappa 하나가 greedy/MILP/J 세 자리를 같이 움직인다)",
    "에너지 항은 완주 분기에만 들어간다 — 실패 분기에 넣으면 '일찍 죽는 것'이 이득이 된다.",
    "C_fail/C_unclosed 는 ENV(MC_COST_FAIL / MC_COST_UNCLOSED)로 덮어쓸 수 있고, 덮어쓴 런은",
    "해시가 달라져 다른 세대로 취급된다.",
    "M_ref/E_ref/T_scale/Eg_scale 이 null 이면 J 계산은 에러다 — 0 이나 1 로 폴백하지 않는다."
  ],
  "kappa": 0.01,
  "C_fail": 10000.0,
  "C_unclosed": 100.0,
  "tie_eps": 0.001,
  "T_scale": null,
  "Eg_scale": null,
  "M_ref": null,
  "E_ref": null,
  "calibrated_from": null
}
```

그런 다음 태스크 3 리포트의 실측값으로 `T_scale`/`Eg_scale`/`M_ref`/`E_ref` 를 채우고,
`calibrated_from` 에 이렇게 적는다 (숫자는 리포트에서 가져온다):

```json
  "calibrated_from": {
    "date": "2026-08-13",
    "n_complete_runs": 0,
    "makespan_median": 0.0,
    "makespan_stdev": 0.0,
    "energy_median": 0.0,
    "energy_stdev": 0.0,
    "source": "measure_objective_scales.py over results_4pol* (구세대 — spec §7)",
    "note": "구세대 런에서 잰 스케일이다. 신세대 스윕(단계 6) 뒤 재교정 대상."
  }
```

**κ = 0.01 은 자리표시자다** (spec §4.1, §11-5). 그대로 둔다 — 교정은 단계 6 이후다.

- [ ] **Step 2: `objective.py` 를 쓴다**

```python
#!/usr/bin/env python3
"""목적함수 J 의 단일 진실원 로더 (spec §3, §5).

    J(run) = complete ? makespan + w_E * energy_J
                      : C_fail + C_unclosed * (total - closed) + tie_eps * makespan
    w_E    = kappa * M_ref / E_ref

규칙(어겼을 때 조용히 새는 종류의 결함이므로 전부 에러로 만든다):
  - 스케일(M_ref/E_ref)이 null 인 채로 완주 런의 J 를 계산하면 ObjectiveError.
  - 완주 런인데 energy_J 가 없거나 유한하지 않으면 ObjectiveError.
  - 에너지 항은 완주 분기에만 들어간다 (spec §3.1).
  - λ·MACRO_COST 같은 개입비용은 J 에 들어가지 않는다 (spec §3.2).

ENV 우선순위: MC_COST_FAIL / MC_COST_UNCLOSED 가 설정돼 있으면 ENV 가 이기고,
그 사실이 objective_hash() 에 반영돼 산출물이 **다른 세대**로 갈린다 (spec §5, §7).
"""
import hashlib
import json
import math
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
OBJECTIVE_PATH = os.path.join(_HERE, "objective.json")

# ENV 로 덮어쓸 수 있는 키와 그 ENV 이름. gen_oracle_mc.jl:142-143 의 현행 경로를 그대로 유지한다.
ENV_OVERRIDES = {"C_fail": "MC_COST_FAIL", "C_unclosed": "MC_COST_UNCLOSED"}

# 스케일 상수 — null 이면 J 의 완주 분기를 계산할 수 없다.
SCALE_KEYS = ("kappa", "M_ref", "E_ref")


class ObjectiveError(RuntimeError):
    """목적함수 설정이 불완전하거나 입력이 J 를 정의하지 못할 때."""


_CACHE = None


def load(path=None, refresh=False):
    """objective.json 을 읽고 ENV 덮어쓰기를 적용한 **유효 설정**을 돌려준다."""
    global _CACHE
    if _CACHE is not None and not refresh and path is None:
        return _CACHE
    p = path or OBJECTIVE_PATH
    if not os.path.exists(p):
        raise ObjectiveError("objective.json 이 없다: %s" % p)
    with open(p) as fh:
        cfg = json.load(fh)
    cfg.pop("_doc", None)
    cfg["_env_overrides"] = {}
    for key, env_name in ENV_OVERRIDES.items():
        raw = os.environ.get(env_name)
        if raw is None:
            continue
        cfg[key] = float(raw)
        cfg["_env_overrides"][env_name] = raw
    if path is None:
        _CACHE = cfg
    return cfg


def objective_hash(cfg=None):
    """유효 설정의 sha256(앞 16자). 산출물에 박아 세대 혼입을 막는다 (spec §7)."""
    cfg = cfg if cfg is not None else load()
    payload = {k: v for k, v in cfg.items() if not k.startswith("_")}
    payload["_env_overrides"] = cfg.get("_env_overrides", {})
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def energy_weight(cfg=None):
    """w_E = kappa * M_ref / E_ref. 스케일이 없으면 에러 — 0 으로 폴백하지 않는다."""
    cfg = cfg if cfg is not None else load()
    missing = [k for k in SCALE_KEYS if cfg.get(k) is None]
    if missing:
        raise ObjectiveError(
            "objective.json 의 %s 가 null 이다 — 파일럿 측정(measure_objective_scales.py) 없이는 "
            "완주 런의 J 를 계산할 수 없다. 0 이나 1 로 폴백하지 않는다 (spec §5)." % ", ".join(missing))
    e_ref = float(cfg["E_ref"])
    if not (math.isfinite(e_ref) and e_ref > 0):
        raise ObjectiveError("E_ref 가 양의 유한값이 아니다: %r" % cfg["E_ref"])
    return float(cfg["kappa"]) * float(cfg["M_ref"]) / e_ref


def J(*, complete, closed, total, makespan, energy_J=None, cfg=None):
    """실현된 런 하나의 목적함수 값 (작을수록 좋다)."""
    cfg = cfg if cfg is not None else load()
    ms = float(makespan) if makespan is not None else float("nan")

    if not complete:
        # 미완주 분기: gen_oracle_mc.jl:146 의 scalar_cost 를 그대로 물려받는다.
        # **에너지는 들어가지 않는다** — 일찍 죽는 것이 이득이 되면 안 된다 (spec §3.1).
        return (float(cfg["C_fail"])
                + float(cfg["C_unclosed"]) * (int(total) - int(closed))
                + float(cfg["tie_eps"]) * (ms if math.isfinite(ms) else 0.0))

    if not math.isfinite(ms):
        raise ObjectiveError("완주 런인데 makespan 이 유한하지 않다: %r" % makespan)
    if energy_J is None or not math.isfinite(float(energy_J)):
        raise ObjectiveError(
            "완주 런인데 energy_J 가 없다/유한하지 않다: %r — 구세대 덤프이거나 배터리 레이어가 "
            "꺼진 런이다. J 는 이를 조용히 0 으로 두지 않는다 (spec §5)." % (energy_J,))
    return ms + energy_weight(cfg) * float(energy_J)


def J_row(row, cfg=None):
    """JSONL 행 하나에서 J 를 뽑는다. 4pol 레인(battery 하위)과 MC 레인(최상위) 둘 다 읽는다."""
    energy = row.get("energy_J")
    if energy is None:
        energy = (row.get("battery") or {}).get("total_energy_J")
    makespan = row.get("makespan")
    if makespan is None:
        makespan = row.get("sim_seconds")
    return J(complete=bool(row.get("complete")), closed=int(row.get("closed") or 0),
             total=int(row.get("total") or 0), makespan=makespan, energy_J=energy, cfg=cfg)


if __name__ == "__main__":
    c = load()
    print(json.dumps({k: v for k, v in c.items() if not k.startswith("_")},
                     ensure_ascii=False, indent=2))
    print("env_overrides:", c.get("_env_overrides"))
    print("objective_hash:", objective_hash(c))
    try:
        print("w_E:", energy_weight(c))
    except ObjectiveError as e:
        print("w_E: <unavailable>", e)
```

- [ ] **Step 3: `objective.jl` 을 쓴다 — Python 과 **같은 수식** **

```julia
# ============================================================================
#  목적함수 J 의 단일 진실원 로더 (Julia 쪽). objective.py 와 **같은 수식**을 낸다.
#
#    J(run) = complete ? makespan + w_E * energy_J
#                      : C_fail + C_unclosed * (total - closed) + tie_eps * makespan
#    w_E    = kappa * M_ref / E_ref
#
#  두 구현이 갈리면 오라클 라벨과 Python 분석이 다른 것을 최소화하게 된다 —
#  audit_objective.py 가 그 일치를 기계적으로 검사한다.
#
#  ENV 우선순위: MC_COST_FAIL / MC_COST_UNCLOSED 가 있으면 ENV 가 이기고 해시가 갈린다.
# ============================================================================
module Objective

using JSON3
using SHA

const OBJECTIVE_PATH = joinpath(@__DIR__, "objective.json")
const ENV_OVERRIDES = ("C_fail" => "MC_COST_FAIL", "C_unclosed" => "MC_COST_UNCLOSED")
const SCALE_KEYS = ("kappa", "M_ref", "E_ref")

struct ObjectiveError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ObjectiveError) = print(io, "ObjectiveError: ", e.msg)

const _CACHE = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

"objective.json 을 읽고 ENV 덮어쓰기를 적용한 유효 설정."
function load(; path::AbstractString = OBJECTIVE_PATH, refresh::Bool = false)
    if _CACHE[] !== nothing && !refresh && path == OBJECTIVE_PATH
        return _CACHE[]
    end
    isfile(path) || throw(ObjectiveError("objective.json 이 없다: $path"))
    cfg = Dict{String,Any}(JSON3.read(read(path, String), Dict{String,Any}))
    delete!(cfg, "_doc")
    ov = Dict{String,String}()
    for (key, env_name) in ENV_OVERRIDES
        haskey(ENV, env_name) || continue
        cfg[key] = parse(Float64, ENV[env_name])
        ov[env_name] = ENV[env_name]
    end
    cfg["_env_overrides"] = ov
    path == OBJECTIVE_PATH && (_CACHE[] = cfg)
    return cfg
end

"유효 설정의 sha256 앞 16자. objective.py 의 objective_hash 와 같은 문자열을 내야 한다."
function objective_hash(cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    payload = Dict{String,Any}(k => v for (k, v) in cfg if !startswith(k, "_"))
    payload["_env_overrides"] = get(cfg, "_env_overrides", Dict{String,String}())
    # 키 정렬 + 공백 없는 직렬화로 Python 의 json.dumps(sort_keys, separators) 와 맞춘다.
    blob = _canonical_json(payload)
    return bytes2hex(SHA.sha256(blob))[1:16]
end

"Python 의 json.dumps(sort_keys=True, separators=(',',':')) 와 바이트 동일한 직렬화."
function _canonical_json(x)
    if x isa AbstractDict
        parts = ["$(_canonical_json(String(k))):$(_canonical_json(v))"
                 for k in sort(collect(String.(keys(x))))
                 for v in (x[k isa String ? k : Symbol(k)],)]
        return "{" * join(parts, ",") * "}"
    elseif x isa AbstractVector
        return "[" * join(_canonical_json.(x), ",") * "]"
    elseif x === nothing
        return "null"
    elseif x isa Bool
        return x ? "true" : "false"
    elseif x isa AbstractString
        return JSON3.write(x)
    elseif x isa Integer
        return string(x)
    elseif x isa AbstractFloat
        # Python 의 repr(float) 와 맞춘다: 정수값도 소수점을 남긴다 (10000.0)
        return isinteger(x) ? string(Float64(x)) : string(Float64(x))
    else
        return JSON3.write(x)
    end
end

"w_E = kappa * M_ref / E_ref. 스케일이 null 이면 에러 — 0/1 로 폴백하지 않는다."
function energy_weight(cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    missing = [k for k in SCALE_KEYS if get(cfg, k, nothing) === nothing]
    isempty(missing) || throw(ObjectiveError(
        "objective.json 의 $(join(missing, ", ")) 가 null 이다 — 파일럿 측정 없이는 완주 런의 J 를 " *
        "계산할 수 없다. 0 이나 1 로 폴백하지 않는다 (spec §5)."))
    e_ref = Float64(cfg["E_ref"])
    (isfinite(e_ref) && e_ref > 0) || throw(ObjectiveError("E_ref 가 양의 유한값이 아니다: $(cfg["E_ref"])"))
    return Float64(cfg["kappa"]) * Float64(cfg["M_ref"]) / e_ref
end

"실현된 런 하나의 목적함수 값 (작을수록 좋다)."
function J(; complete, closed, total, makespan, energy_J = nothing, cfg = nothing)
    cfg = cfg === nothing ? load() : cfg
    ms = makespan === nothing ? NaN : Float64(makespan)
    if !complete
        # 미완주 분기에는 에너지가 들어가지 않는다 (spec §3.1).
        return Float64(cfg["C_fail"]) +
               Float64(cfg["C_unclosed"]) * (Int(total) - Int(closed)) +
               Float64(cfg["tie_eps"]) * (isfinite(ms) ? ms : 0.0)
    end
    isfinite(ms) || throw(ObjectiveError("완주 런인데 makespan 이 유한하지 않다: $makespan"))
    (energy_J !== nothing && isfinite(Float64(energy_J))) || throw(ObjectiveError(
        "완주 런인데 energy_J 가 없다/유한하지 않다: $energy_J — 구세대 덤프이거나 배터리가 꺼진 " *
        "런이다. J 는 이를 조용히 0 으로 두지 않는다 (spec §5)."))
    return ms + energy_weight(cfg) * Float64(energy_J)
end

end # module
```

- [ ] **Step 4: `test_objective.py` — §9 의 검사 중 지금 계산 가능한 것 전부**

```python
#!/usr/bin/env python3
"""목적함수 J 의 계약 검사 (spec §9). 시뮬레이션 없이 도는 순수 단위검사.

    .venv/bin/python test_objective.py     # exit 0 = 전부 통과
"""
import math
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objective  # noqa: E402

FAILED = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + (("  — " + str(detail)) if detail else ""))
    ok or FAILED.append(name)


CFG = objective.load()
# 스케일이 채워져 있어야 완주 분기를 검사할 수 있다.
HAVE_SCALES = all(CFG.get(k) is not None for k in objective.SCALE_KEYS)


def better_ssp(a, b):
    """gen_oracle_mc.jl:165 의 사전식 순위. a 가 b 보다 나으면 True."""
    if a["complete"] != b["complete"]:
        return a["complete"]
    if a["complete"]:
        return a["makespan"] < b["makespan"]
    if a["closed"] != b["closed"]:
        return a["closed"] > b["closed"]
    return a["makespan"] < b["makespan"]


def run(r):
    return objective.J(complete=r["complete"], closed=r["closed"], total=r["total"],
                       makespan=r["makespan"], energy_J=r.get("energy_J"))


# ---- 1) 순서동치 — argmin J 가 better_ssp 1등을 재현하는가 (spec §9) ----------------
if HAVE_SCALES:
    E = CFG["E_ref"]
    cases = [
        dict(complete=True,  closed=300, total=300, makespan=900.0, energy_J=E),
        dict(complete=False, closed=299, total=300, makespan=10.0),
        dict(complete=False, closed=250, total=300, makespan=500.0),
        dict(complete=False, closed=200, total=300, makespan=500.0),
        dict(complete=True,  closed=300, total=300, makespan=800.0, energy_J=E),
    ]
    ssp_best = cases[0]
    for c in cases[1:]:
        if better_ssp(c, ssp_best):
            ssp_best = c
    j_best = min(cases, key=run)
    check("순서동치: argmin J == better_ssp 1등",
          (j_best["complete"], j_best["closed"], j_best["makespan"])
          == (ssp_best["complete"], ssp_best["closed"], ssp_best["makespan"]),
          "J=%r ssp=%r" % (j_best, ssp_best))

    # ---- 2) 실패 보상 검사 — 미완주가 완주보다 낮은 J 를 받는 경우가 있는가 (spec §3.1) ----
    worst_complete = run(dict(complete=True, closed=300, total=300,
                              makespan=1e4, energy_J=1e3 * E))
    best_fail = run(dict(complete=False, closed=300, total=300, makespan=0.0))
    check("실패 보상 없음: 최악의 완주 J < 최선의 미완주 J",
          worst_complete < best_fail, "%.3f vs %.3f" % (worst_complete, best_fail))

    # ---- 3) 에너지는 완주 분기에만 (spec §3.1) ----
    a = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    b = objective.J(complete=False, closed=250, total=300, makespan=500.0, energy_J=1e9)
    check("미완주 J 는 energy_J 를 무시한다", a == b, "%.6f vs %.6f" % (a, b))

    # ---- 4) 에너지가 J 를 실제로 움직이는가 (동점해소자로서 살아 있는가, spec §4.2) ----
    lo = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=E)
    hi = objective.J(complete=True, closed=300, total=300, makespan=100.0, energy_J=2 * E)
    check("같은 makespan 이면 에너지가 적은 쪽이 이긴다", lo < hi, "%.6f < %.6f" % (lo, hi))

    # κ 가 동점해소자 크기인가 — 에너지 배가 makespan 1% 차이를 뒤집지 못해야 한다 (spec §4.1)
    faster = objective.J(complete=True, closed=300, total=300,
                         makespan=CFG["M_ref"] * 0.99, energy_J=2 * E)
    slower = objective.J(complete=True, closed=300, total=300,
                         makespan=CFG["M_ref"], energy_J=E)
    check("κ 는 동점해소자다: 1% 더 빠른 계획을 에너지가 뒤집지 못한다",
          faster < slower, "faster=%.4f slower=%.4f kappa=%r" % (faster, slower, CFG["kappa"]))
else:
    check("스케일 미측정 — 완주 분기 검사 건너뜀 (objective.json 의 M_ref/E_ref 가 null)", True)

# ---- 5) null 스케일이면 에러, 조용한 폴백 없음 (spec §5) ----
null_cfg = dict(CFG)
null_cfg["M_ref"] = None
try:
    objective.J(complete=True, closed=1, total=1, makespan=10.0, energy_J=5.0, cfg=null_cfg)
    check("null 스케일 → 에러", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("null 스케일 → 에러", True)

# ---- 6) 완주인데 energy 없음 → 에러 ----
try:
    objective.J(complete=True, closed=1, total=1, makespan=10.0, energy_J=None)
    check("완주 + energy 없음 → 에러", False, "에러가 안 났다")
except objective.ObjectiveError:
    check("완주 + energy 없음 → 에러", True)

# ---- 7) 현행 상수를 그대로 물려받았는가 (gen_oracle_mc.jl:142-144) ----
check("C_fail == 10000.0", CFG["C_fail"] == 10000.0, CFG["C_fail"])
check("C_unclosed == 100.0", CFG["C_unclosed"] == 100.0, CFG["C_unclosed"])
check("tie_eps == 1.0e-3", abs(CFG["tie_eps"] - 1.0e-3) < 1e-12, CFG["tie_eps"])

# ---- 8) ENV 덮어쓰기가 해시를 가른다 (spec §5, §7) ----
h_plain = objective.objective_hash(objective.load(refresh=True))
os.environ["MC_COST_FAIL"] = "12345.0"
h_env = objective.objective_hash(objective.load(refresh=True))
del os.environ["MC_COST_FAIL"]
objective.load(refresh=True)
check("ENV 덮어쓴 런은 다른 해시(다른 세대)", h_plain != h_env, "%s vs %s" % (h_plain, h_env))

# ---- 9) Julia 구현이 같은 J 와 같은 해시를 내는가 ----
JL = r'''
include(joinpath(@__DIR__, "objective.jl"))
using .Objective
cfg = Objective.load()
println("HASH=", Objective.objective_hash(cfg))
println("JFAIL=", Objective.J(complete=false, closed=250, total=300, makespan=500.0, cfg=cfg))
try
    println("JOK=", Objective.J(complete=true, closed=300, total=300,
                                makespan=100.0, energy_J=Float64(cfg["E_ref"]), cfg=cfg))
catch e
    println("JOK=ERROR")
end
'''
jl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_objective_probe.jl")
with open(jl_path, "w") as fh:
    fh.write(JL)
try:
    out = subprocess.run(["julia", "+lts", "--project=/home/chahj578/Construction_OODlayer",
                          jl_path], capture_output=True, text=True, timeout=600).stdout
    kv = dict(l.split("=", 1) for l in out.strip().splitlines() if "=" in l)
    check("Julia/Python 해시 일치", kv.get("HASH") == objective.objective_hash(),
          "%s vs %s" % (kv.get("HASH"), objective.objective_hash()))
    py_fail = objective.J(complete=False, closed=250, total=300, makespan=500.0)
    check("Julia/Python 미완주 J 일치",
          abs(float(kv.get("JFAIL", "nan")) - py_fail) < 1e-9,
          "%s vs %.9f" % (kv.get("JFAIL"), py_fail))
    if HAVE_SCALES:
        py_ok = objective.J(complete=True, closed=300, total=300,
                            makespan=100.0, energy_J=CFG["E_ref"])
        check("Julia/Python 완주 J 일치",
              abs(float(kv.get("JOK", "nan")) - py_ok) < 1e-9,
              "%s vs %.9f" % (kv.get("JOK"), py_ok))
finally:
    os.path.exists(jl_path) and os.remove(jl_path)

print("\n%d/%d 통과" % (0 if FAILED else 1, 1) if False else
      "\n실패 %d건: %s" % (len(FAILED), FAILED) if FAILED else "\n전부 통과")
sys.exit(1 if FAILED else 0)
```

- [ ] **Step 5: 검사가 실패하는 것을 먼저 본다 (TDD)**

`objective.json` 의 스케일이 아직 `null` 인 상태(Step 1 의 첫 버전)로 돌리면
완주 분기 검사가 건너뛰어진다. 스케일을 채운 뒤 돌린다:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_objective.py
```

Expected: 처음에는 Julia 해시 일치가 깨질 가능성이 높다(정규 JSON 직렬화가 미묘하다).
**깨지면 `_canonical_json` 을 고쳐 맞춘다.** 두 언어가 다른 해시를 내면 §7 의 세대 판정이
"항상 불일치"가 되어 무용지물이 된다.

`_canonical_json` 을 맞추기 어려우면 **더 단순한 규약으로 바꾼다**: 해시 대상을
`json.dumps(payload, sort_keys=True)` 이 아니라 **`objective.json` 파일의 바이트 + ENV
덮어쓰기 문자열**로 정의한다. 그러면 두 언어가 같은 바이트를 해싱하므로 반드시 일치한다.
그렇게 바꿨으면 두 파일의 주석과 이 계획의 Interfaces 설명을 함께 고치고 report 에 적는다.

- [ ] **Step 6: 통과할 때까지 고친 뒤 커밋**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_objective.py    # 기대: exit 0, 전부 통과
echo "exit=$?"
```

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/objective.json wm4spacecraft_manufacturing/objective.py \
        wm4spacecraft_manufacturing/objective.jl wm4spacecraft_manufacturing/test_objective.py
git commit -m "feat(objective): objective.json single source of truth + J in Python and Julia

J(run) = complete ? makespan + w_E*energy_J : C_fail + C_unclosed*(total-closed) + tie_eps*makespan.
에너지는 완주 분기에만(spec §3.1). null 스케일이면 에러 — 0/1 폴백 없음(§5).
ENV 덮어쓰기는 유지하되 해시를 갈라 다른 세대로 만든다(§7).
C_fail/C_unclosed/tie_eps 는 gen_oracle_mc.jl:142-144 의 현행 값을 그대로 옮긴 것."
```

---

## Task 5: 소비처 배선 + `audit_objective.py`

Spec §5.1, §8 단계 4. 여섯 소비처가 같은 파일을 읽게 하고, 기계적으로 감사한다.

**Ruling (계획자):** spec §5.1 의 소비처 6곳 중 **`dp_solve.py` 는 저장소에 존재하지 않는다**
(계획 단계 실측). 목록에서 뺀다. 대신 실제로 J 를 쓰는 곳은 다음 4곳 + Julia 플래너 2곳이다:
`gen_oracle_mc.jl`(scalar_cost), `e1_analyze.py`(cost_lex_key), `objective.py`, `objective.jl`,
그리고 태스크 6 이 배선할 greedy·MILP 의 κ. 틀렸을 경우의 비용: `dp_solve.py` 가 나중에
생기면 그때 감사 목록에 한 줄 추가하면 된다.

**Files:**
- Modify: `wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl:140-193`
- Modify: `wm4spacecraft_manufacturing/e1_analyze.py:219-225`
- Create: `wm4spacecraft_manufacturing/audit_objective.py`

**Interfaces:**
- Consumes: `objective.py` / `objective.jl` 의 `load`, `J`, `objective_hash`, `ObjectiveError`
- Produces: `audit_objective.py` (exit 0 = 전부 일치)

- [ ] **Step 1: `gen_oracle_mc.jl` 의 `scalar_cost` 를 `Objective.J` 로 위임**

현행(`:142-148`):

```julia
const COST_FAIL     = parse(Float64, get(ENV, "MC_COST_FAIL", "10000.0"))
const COST_UNCLOSED = parse(Float64, get(ENV, "MC_COST_UNCLOSED", "100.0"))
const COST_TIE_EPS  = 1.0e-3

scalar_cost(r) = r.complete ? Float64(r.makespan) :
    COST_FAIL + COST_UNCLOSED * (r.total - r.closed) +
    COST_TIE_EPS * (isfinite(r.makespan) ? r.makespan : 0.0)
```

이렇게 바꾼다:

```julia
# 목적함수 상수의 단일 진실원 — 리터럴 복붙 금지(spec §5). ENV 덮어쓰기는 Objective.load 안에서
# 처리되고, 덮어쓴 런은 objective_hash 가 달라져 다른 세대로 취급된다(§7).
include(joinpath(@__DIR__, "..", "objective.jl"))
using .Objective

const OBJ_CFG  = Objective.load()
const OBJ_HASH = Objective.objective_hash(OBJ_CFG)
# 아래 세 상수는 하위호환용 별칭이다(로그·기존 코드가 이름으로 읽는다). 값의 출처는 objective.json.
const COST_FAIL     = Float64(OBJ_CFG["C_fail"])
const COST_UNCLOSED = Float64(OBJ_CFG["C_unclosed"])
const COST_TIE_EPS  = Float64(OBJ_CFG["tie_eps"])

# 목적함수 J (spec §3). 완주 분기에만 에너지가 들어간다.
# 주의: r 에 energy_J 가 없으면(구세대 레코드) Objective.J 가 던진다 — 조용히 0 이 되지 않는다.
scalar_cost(r) = Objective.J(complete = r.complete, closed = r.closed, total = r.total,
                             makespan = r.makespan,
                             energy_J = hasproperty(r, :energy_J) ? r.energy_J : nothing,
                             cfg = OBJ_CFG)
```

**주의:** `test/mdp_mc_label_smoke.jl` 의 `_res(...)` 헬퍼는 `energy_J` 없이 NamedTuple 을 만든다.
그 테스트의 완주 케이스가 이제 던진다. 그 테스트도 함께 고친다 — 아래 Step 3.

- [ ] **Step 2: `better_ssp` 는 그대로 두고, `check_order_equivalence` 에 해시 로그를 붙인다**

`better_ssp`(`:165-168`)는 **바꾸지 않는다** — 그것이 J 의 순서동치를 검사하는 기준이다.
`check_order_equivalence` 의 경고 메시지에 해시를 넣어, 산출물이 어느 세대인지 로그에 남긴다:

```julia
    ok || @warn "[MC] scalar cost is NOT order-equivalent to better_ssp — raise MC_COST_FAIL" ssp_best sc_best objective_hash=OBJ_HASH
```

그리고 JSONL 행에 해시를 박는다. `gen_oracle_mc.jl` 안에서 행을 쓰는 지점을 찾아
(`grep -n "JSON3.write\|append_unit!" wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl`)
각 행에 `"objective_hash" => OBJ_HASH` 를 추가한다. **소비처가 현재 해시와 다르면 에러로 멈추는
것**이 spec §7 의 계약이므로, 해시를 기록하지 않으면 그 계약이 성립하지 않는다.

- [ ] **Step 3: `test/mdp_mc_label_smoke.jl` 을 새 J 에 맞춘다**

`_res` 헬퍼(`test/mdp_mc_label_smoke.jl:27-28`)에 `energy_J` 를 추가한다:

```julia
_res(; complete, closed, total = 300, makespan, energy_J = 0.0) =
    (complete = complete, closed = closed, total = total, makespan = makespan, energy_J = energy_J)
```

`energy_J = 0.0` 기본값은 **완주 케이스에서 에너지 항을 0 으로 만든다** — 그러면 이 테스트의
기존 단언(완주끼리는 makespan 이 결정)이 그대로 성립한다. 이것은 "조용한 폴백"이 아니라
**테스트가 명시적으로 고른 값**이다(에너지 축을 이 테스트가 검사하지 않으므로 상수로 고정).
`objective.json` 의 스케일이 `null` 이면 `energy_weight` 가 던지므로 완주 케이스가 실패한다 —
그때는 이 테스트가 태스크 4 의 스케일 채우기가 안 됐다고 알려주는 것이 맞다.

```bash
cd /home/chahj578/Construction_OODlayer
timeout 900 julia +lts --project=. test/mdp_mc_label_smoke.jl 2>&1 | tail -20
```

Expected: 전부 통과. **특히 "스칼라 비용 == lexicographic 순위" testset 이 통과해야 한다** —
그것이 spec §9 의 순서동치 검사다.

- [ ] **Step 4: `e1_analyze.py` 의 `cost_lex_key` 를 J 기반으로**

현행(`:219-225`):

```python
MACRO_COST = {0: 0.0, 1: 1.0, 2: 0.3, 3: 1.0, 4: 1.0, 5: 1.8, 6: 0.8, 7: 1.5, 8: 0.2}  # 8=SwapBattery


def cost_lex_key(complete, closed, makespan, macro, lam):
    return lex_key(complete, closed - lam * MACRO_COST[int(macro)], makespan)
```

호출자 5곳(`verify.py`, `dspy_real_experiment.py`, `firegrid_report.py`, `ladder.py`, 그리고
`e1_analyze.py:300`)이 전부 `max(rows, key=cost_lex_key(...))` 형태로 쓴다 — **키를 최대화**한다.
J 는 최소화 대상이므로 **부호를 뒤집어 반환**하면 호출자를 안 고쳐도 된다.

```python
# 개입 비용표. **J 에는 들어가지 않는다**(spec §3.2) — MC 오라클이 개입에 비용을 매긴 적이 없고
# 발행된 오라클 숫자 전부가 그 기준으로 나왔다. 통일 방향은 오라클 쪽이다.
# 이 표는 특징량으로 계속 쓰이므로 남긴다.
MACRO_COST = {0: 0.0, 1: 1.0, 2: 0.3, 3: 1.0, 4: 1.0, 5: 1.8, 6: 0.8, 7: 1.5, 8: 0.2}  # 8=SwapBattery


def cost_lex_key(complete, closed, makespan, macro, lam, energy_J=None):
    """정렬키 = -J. 호출자들이 max(...) 로 쓰므로 부호를 뒤집는다.

    이름과 시그니처는 하위호환을 위해 유지하지만 **의미가 바뀌었다**(spec §3.2):
      - λ·MACRO_COST 항이 사라졌다. macro/lam 인자는 받되 무시한다.
      - 대신 완주 런은 makespan + w_E·energy_J 로 순위가 매겨진다.
    energy_J 가 None 인 완주 런은 objective.J 가 에러를 낸다 — 구세대 덤프로 신세대 기준을
    적용하려는 시도이므로 조용히 넘기지 않는다(spec §7).
    """
    import objective
    return -objective.J(complete=bool(complete), closed=int(closed),
                        total=int(_TOTAL_FOR_LEX), makespan=makespan, energy_J=energy_J)
```

**문제:** `cost_lex_key` 시그니처에 `total` 이 없다. J 의 미완주 분기는 `total - closed` 가 필요하다.
호출자들이 `total` 을 안 넘긴다.

**Ruling (구현자가 결정할 것 — 아래 둘 중 하나, report 에 어느 쪽인지 적는다):**
- **(A) 권장** — 시그니처에 `total` 을 키워드로 추가하고(`total=None`), 5곳의 호출자를
  `r.total` 을 넘기도록 고친다. 행에 `total` 이 있음은 확인됐다(`run_demo.jl`, `gen_oracle_*`).
  `total=None` 이면 `ObjectiveError` 를 던진다.
- **(B)** — `e1_analyze.py` 에 `cost_lex_key_row(row, lam=0.0)` 를 새로 만들어
  `objective.J_row(row)` 를 쓰고, 5곳의 호출자를 그쪽으로 옮긴다. 기존 `cost_lex_key` 는
  `DeprecationWarning` 을 내며 남긴다.

먼저 호출자 5곳을 확인한다:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "cost_lex_key" *.py
```

각 호출 지점에서 `r` 이 무엇인지(dict 인가 NamedTuple 인가, `total`/`energy_J` 를 갖는가)
확인한 뒤 (A) 나 (B) 를 고른다. **어느 쪽이든 5곳 전부를 고쳐야 한다** — 한 곳이라도
옛 의미로 남으면 §7 의 세대 혼입이 그대로 재현된다.

- [ ] **Step 5: `audit_objective.py` — 소비처가 같은 파일을 읽는지 기계적 감사**

`audit_action_vocab.py` 의 패턴을 그대로 따른다(하나의 `check()` 헬퍼, 소비처별 프로브,
`OK`/`FAIL` 리스트, 요약 출력, 불일치 시 `sys.exit(1)`).

```python
#!/usr/bin/env python3
"""목적함수 상수의 단일 진실원 감사 (spec §5.1). audit_action_vocab.py 와 같은 형식.

    .venv/bin/python audit_objective.py    # exit 0 = 전부 일치

리터럴 복붙은 에러 없이 성능으로만 새는 종류의 결함이다 — 그래서 기계로 검사한다.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import objective  # noqa: E402

CFG = objective.load()
OK, FAIL = [], []


def check(where, bad):
    (FAIL if bad else OK).append((where, bad))


# --- 1) objective.py 가 objective.json 을 읽는가 + 상수를 리터럴로 안 박았는가 -------------
src = open(os.path.join(HERE, "objective.py")).read()
bad = []
"objective.json" in src or bad.append("objective.json 을 안 읽는다")
for lit in ("10000.0", "100.0"):
    # 주석/독스트링 밖에서 리터럴이 대입되는지만 본다.
    for line in src.splitlines():
        s = line.split("#", 1)[0]
        if re.search(r"=\s*%s\b" % re.escape(lit), s):
            bad.append("리터럴 %s 대입: %s" % (lit, line.strip()))
check("objective.py", bad)

# --- 2) objective.jl 도 같은 파일을 읽는가 -----------------------------------------------
jsrc = open(os.path.join(HERE, "objective.jl")).read()
bad = []
"objective.json" in jsrc or bad.append("objective.json 을 안 읽는다")
check("objective.jl", bad)

# --- 3) gen_oracle_mc.jl 이 objective.jl 을 include 하고 리터럴을 안 쓰는가 -----------------
mc = open(os.path.join(HERE, "oracle", "gen_oracle_mc.jl")).read()
bad = []
'objective.jl' in mc or bad.append("objective.jl 을 include 하지 않는다")
re.search(r'get\(ENV,\s*"MC_COST_FAIL",\s*"10000', mc) and bad.append(
    "COST_FAIL 을 아직 리터럴 기본값으로 파싱한다 (objective.json 이 출처여야 함)")
"objective_hash" in mc or bad.append("산출물에 objective_hash 를 기록하지 않는다 (spec §7)")
check("oracle/gen_oracle_mc.jl", bad)

# --- 4) e1_analyze.py 의 cost_lex_key 가 J 로 위임하는가 -----------------------------------
e1 = open(os.path.join(HERE, "e1_analyze.py")).read()
bad = []
"import objective" in e1 or "from objective" in e1 or bad.append("objective 모듈을 안 쓴다")
m = re.search(r"def cost_lex_key\(.*?\n(?:.*?\n)*?\n", e1)
body = m.group(0) if m else ""
"MACRO_COST[" in body and bad.append("cost_lex_key 가 아직 λ·MACRO_COST 를 쓴다 (spec §3.2 위반)")
"MACRO_COST" in e1 or bad.append("MACRO_COST 표가 사라졌다 — 특징량으로 남겨야 한다 (spec §3.2)")
check("e1_analyze.py", bad)

# --- 5) Julia 플래너의 전역 κ 기본값이 objective.json 에서 오는가 (태스크 6 이 배선) ---------
etg = open(os.path.join(HERE, "..", "src", "essential_tg_coponents.jl")).read()
bad = []
if "AUTO_EFFICIENCY_KAPPA" in etg:
    if "objective.json" not in etg and "objective_kappa" not in etg:
        bad.append("전역 κ 기본값이 objective.json 과 연결돼 있지 않다 (태스크 6 미완이면 예상됨)")
check("src/essential_tg_coponents.jl (전역 κ)", bad)

# --- 6) Julia 와 Python 의 해시가 일치하는가 ----------------------------------------------
probe = os.path.join(HERE, "_audit_objective_probe.jl")
bad = []
try:
    with open(probe, "w") as fh:
        fh.write('include(joinpath(@__DIR__, "objective.jl"))\nusing .Objective\n'
                 'println("HASH=", Objective.objective_hash())\n')
    out = subprocess.run(["julia", "+lts", "--project=" + os.path.dirname(HERE), probe],
                         capture_output=True, text=True, timeout=600)
    jl_hash = next((l.split("=", 1)[1].strip() for l in out.stdout.splitlines()
                    if l.startswith("HASH=")), None)
    py_hash = objective.objective_hash()
    jl_hash == py_hash or bad.append("해시 불일치 julia=%s python=%s (stderr: %s)"
                                     % (jl_hash, py_hash, out.stderr[-300:]))
except Exception as e:
    bad.append("julia probe 실패: %r" % (e,))
finally:
    os.path.exists(probe) and os.remove(probe)
check("Julia/Python objective_hash", bad)

# --- 7) 스케일이 채워져 있는가 -------------------------------------------------------------
bad = [k for k in ("kappa", "M_ref", "E_ref", "T_scale", "Eg_scale") if CFG.get(k) is None]
check("objective.json 스케일 채움", ["null: %s" % ", ".join(bad)] if bad else [])

# --- 요약 --------------------------------------------------------------------------------
for where, bad in OK + FAIL:
    print(("OK        " if not bad else "MISMATCH  ") + where)
    for b in bad:
        print("            - " + b)
print("\n%d/%d consistent" % (len(OK), len(OK) + len(FAIL)))
print("objective_hash:", objective.objective_hash())
sys.exit(1 if FAIL else 0)
```

- [ ] **Step 6: 감사와 검사를 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python audit_objective.py; echo "audit exit=$?"
/home/chahj578/Construction_OODlayer/.venv/bin/python test_objective.py;  echo "test exit=$?"
timeout 900 julia +lts --project=/home/chahj578/Construction_OODlayer \
  /home/chahj578/Construction_OODlayer/test/mdp_mc_label_smoke.jl 2>&1 | tail -15
```

Expected: 감사는 항목 5(전역 κ)만 MISMATCH 여도 된다 — 그건 태스크 6 이 배선한다.
**나머지가 전부 OK 여야 한다.** `test_objective.py` 는 exit 0.

기존 Python 계약도 깨지지 않았는지 확인한다:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
/home/chahj578/Construction_OODlayer/.venv/bin/python test_surrogate_support.py; echo "exit=$?"
/home/chahj578/Construction_OODlayer/.venv/bin/python audit_action_vocab.py;      echo "exit=$?"
```

Expected: 둘 다 exit 0 (7/7, 6/6).

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl wm4spacecraft_manufacturing/e1_analyze.py \
        wm4spacecraft_manufacturing/audit_objective.py test/mdp_mc_label_smoke.jl \
        wm4spacecraft_manufacturing/verify.py wm4spacecraft_manufacturing/ladder.py \
        wm4spacecraft_manufacturing/firegrid_report.py wm4spacecraft_manufacturing/dspy_real_experiment.py
git commit -m "feat(objective): route MC oracle and e1_analyze through the shared J

gen_oracle_mc.scalar_cost -> Objective.J; e1_analyze.cost_lex_key -> -J (λ·MACRO_COST 제거, spec §3.2).
산출물에 objective_hash 를 박아 세대 혼입을 막는다(§7). audit_objective.py 가 소비처 일치를 감사한다."
```

(실제로 고친 파일만 `git add` 한다 — 위 목록은 (A)/(B) 선택에 따라 달라진다.)

---

## Task 6: 에너지 활성화 — `GreedyEnergyAwareCost` + MILP 전역 κ

Spec §8 단계 5, §6.2, §6.3. **여기서 처음으로 동작이 바뀐다.**

**Files:**
- Modify: `src/essential_tg_coponents.jl` (`GreedyEnergyAwareCost` + 전역 κ 기본값)
- Modify: `src/respec/replan.jl:901-914` (국소 κ 스코프 제거)
- Create: `test/objective_hooks_smoke.jl`

**Interfaces:**
- Consumes: 태스크 2 의 `greedy_edge_cost(gc, sched, v, v2, dt)`, 태스크 4 의 `objective.json`
- Produces: `GreedyEnergyAwareCost` 타입, 전역 `AUTO_EFFICIENCY_KAPPA[]` 기본값

- [ ] **Step 1: `GreedyEnergyAwareCost` 를 추가한다**

`src/essential_tg_coponents.jl` 의 태스크 2 에서 추가한 `greedy_edge_cost` 블록 바로 아래:

```julia
"""
에너지를 보는 greedy 비용 (spec §6.2).

    cost = get_tF(v) + dt + w_g · edge_energy(dt) · edge_cost_multiplier(sched, v)

`edge_cost_multiplier` 가 `agent_cost_bias × 배터리 SoC 배율` 을 나른다 — 즉 이 한 항으로
greedy 경로에서도 `DeprioritizeAgent` 와 배터리 SoC 조향이 살아난다. 지금까지 둘 다 무력이었다.

w_g = κ · T_scale / Eg_scale 이며, objective.json 이 출처다(단일 진실원, spec §5).
"""
struct GreedyEnergyAwareCost <: GreedyCost end

# w_g 의 전역 상자. objective.json 에서 채워진다(set_greedy_energy_weight! / init_objective_weights!).
# nothing 이면 GreedyEnergyAwareCost 를 쓰는 것 자체가 에러다 — 0 으로 조용히 폴백하지 않는다.
const GREEDY_ENERGY_W = Ref{Union{Nothing,Float64}}(nothing)

function greedy_edge_cost(::GreedyEnergyAwareCost, sched, v, v2, dt::Float64)
    w = GREEDY_ENERGY_W[]
    w === nothing && error("GreedyEnergyAwareCost 를 쓰려면 w_g 가 필요하다 — objective.json 의 " *
                           "kappa/T_scale/Eg_scale 로 init_objective_weights! 를 먼저 부를 것 (spec §5).")
    return get_tF(sched, v) + dt + w * edge_energy(dt) * edge_cost_multiplier(sched, v)
end
```

- [ ] **Step 2: `objective.json` 에서 κ 와 스케일을 읽어 두 자리에 심는 초기화 함수**

같은 파일에 추가한다 (`AUTO_EFFICIENCY_KAPPA` 정의 근처, `:1308` 부근):

```julia
"""
    init_objective_weights!(; path = <repo>/wm4spacecraft_manufacturing/objective.json)

목적함수 상수를 **한 파일에서** 읽어 두 자리에 심는다 (spec §4, §5):

  - `AUTO_EFFICIENCY_KAPPA[]` ← `kappa`  (MILP 의 에너지 항; 정식화마다 자기 스케일로 환산됨)
  - `GREEDY_ENERGY_W[]`       ← `kappa · T_scale / Eg_scale`  (greedy 의 에너지 항)

둘 다 "에너지 항은 시간 항 크기의 약 κ 배만큼 가치가 있다"를 뜻한다 —
κ 하나만 돌리면 세 자리(greedy, MILP, J)가 같이 움직인다.

스케일이 null 이면 던진다. 조용히 0/1 로 폴백하면 "energy 도 최소화한다"가 명목상 주장이 된다.
"""
function init_objective_weights!(; path::AbstractString = joinpath(@__DIR__, "..",
        "wm4spacecraft_manufacturing", "objective.json"))
    isfile(path) || error("objective.json 이 없다: $path")
    cfg = JSON3.read(read(path, String), Dict{String,Any})
    kappa = get(cfg, "kappa", nothing)
    kappa === nothing && error("objective.json 에 kappa 가 없다")
    AUTO_EFFICIENCY_KAPPA[] = Float64(kappa)
    T_scale, Eg_scale = get(cfg, "T_scale", nothing), get(cfg, "Eg_scale", nothing)
    if T_scale === nothing || Eg_scale === nothing
        GREEDY_ENERGY_W[] = nothing
        @warn "objective.json 의 T_scale/Eg_scale 이 null — greedy 에너지 항은 비활성. " *
              "GreedyEnergyAwareCost 를 쓰면 에러가 난다 (spec §5)."
    else
        Float64(Eg_scale) > 0 || error("Eg_scale 이 양수가 아니다: $Eg_scale")
        GREEDY_ENERGY_W[] = Float64(kappa) * Float64(T_scale) / Float64(Eg_scale)
    end
    return (kappa = AUTO_EFFICIENCY_KAPPA[], w_g = GREEDY_ENERGY_W[])
end
```

`JSON3` 가 이 파일에서 이미 쓰이는지 확인하고, 아니면 모듈 최상단의 `using` 목록에 추가한다:

```bash
cd /home/chahj578/Construction_OODlayer
grep -n "^using\|^import" src/ConstructionBots.jl | head -30
grep -n "JSON3" src/essential_tg_coponents.jl src/ConstructionBots.jl | head
```

`init_objective_weights!`, `GreedyEnergyAwareCost`, `GREEDY_ENERGY_W` 를 export 한다
(같은 파일/`ConstructionBots.jl` 의 export 목록 관례를 따른다).

**Ruling (계획자):** `init_objective_weights!` 를 모듈 `__init__` 에서 **자동으로 부르지 않는다.**
명시적 opt-in 으로 둔다. 이유: 자동 호출은 `objective.json` 이 없거나 스케일이 null 인 환경에서
패키지 로딩 자체를 깨뜨릴 수 있고, `Pkg.test()` 의 기대 baseline(11/1)을 조용히 바꾼다.
호출은 태스크 6 Step 3 이 배선하는 지점 한 곳에서 한다. 틀렸을 경우의 비용: 호출을 잊은
경로에서 κ 가 `nothing` 으로 남아 **에너지가 꺼진 채 돈다** — 그래서 Step 5 의 배터리 훅
활성 검사가 필요하다.

- [ ] **Step 3: MILP 전역 κ — `replan.jl` 의 국소 스코프를 제거한다**

`src/respec/replan.jl:901-914` 의 현행 코드:

```julia
        prev_kappa = AUTO_EFFICIENCY_KAPPA[]
        AUTO_EFFICIENCY_KAPPA[] = DEPRIORITIZE_KAPPA[]
        milp = try
            formulate_milp(
                SparseAdjacencyMILP(), env.sched, env.scene_tree;
                optimizer = optimizer, t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF)
        finally
            AUTO_EFFICIENCY_KAPPA[] = prev_kappa         # 반드시 원복(예외가 나도)
        end
        if LAST_AUTO_EFFICIENCY_W[] > 0.0
            @info "[RESPEC] deprioritize re-solve: energy term ON (auto w_eff=$(round(LAST_AUTO_EFFICIENCY_W[]; sigdigits = 3)), κ=$(DEPRIORITIZE_KAPPA[]))"
        else
            @warn "[RESPEC] deprioritize re-solve: energy term NOT active -- the bias cannot steer this solve"
        end
```

이렇게 바꾼다 — 국소 켜기/원복이 사라지고 전역 κ 를 그대로 쓴다:

```julia
        # κ 는 이제 전역 기본값이다(objective.json → init_objective_weights!, spec §6.3).
        # 예전에는 이 한 정식화에만 켰다가 즉시 원복했고, 그래서 **나머지 모든 매크로의 재풀이가
        # 에너지를 버린 채** 돌았다(spec §2.2). 배터리 SoC 훅도 같은 항에 실려 있어 함께 무력이었다.
        milp = formulate_milp(
            SparseAdjacencyMILP(), env.sched, env.scene_tree;
            optimizer = optimizer, t0_ = invariant.frozen_t0, tF_ = invariant.frozen_tF)
        if LAST_AUTO_EFFICIENCY_W[] > 0.0
            @info "[RESPEC] deprioritize re-solve: energy term ON (auto w_eff=$(round(LAST_AUTO_EFFICIENCY_W[]; sigdigits = 3)), κ=$(AUTO_EFFICIENCY_KAPPA[]))"
        else
            @warn "[RESPEC] deprioritize re-solve: energy term NOT active -- the bias cannot steer this solve. init_objective_weights! 를 불렀는가?"
        end
```

`DEPRIORITIZE_KAPPA`(`replan.jl:95`)는 **삭제하지 않는다** — 다른 곳에서 참조될 수 있다.
참조가 없으면 죽은 상수임을 주석으로 표시한다:

```bash
cd /home/chahj578/Construction_OODlayer && grep -rn "DEPRIORITIZE_KAPPA" --include=*.jl .
```

- [ ] **Step 4: 두 실행 레인에 `init_objective_weights!` 호출을 심는다**

에너지를 실제로 쓰는 레인은 둘이다. 각각 env 를 만든 **직후**, 시뮬 시작 **전**에 부른다.

`tools/monitor/run_demo.jl` — `CB.enable_battery!(env; ...)` 줄 근처(`:397` 부근):

```julia
# 목적함수 가중치를 objective.json 에서 심는다 (spec §4, §5). ENERGY_OBJECTIVE=0 이면 끈다
# (구세대 재현용 탈출구 — 껐다는 사실이 아래 로그에 남는다).
if get(ENV, "ENERGY_OBJECTIVE", "1") == "1"
    local w = CB.init_objective_weights!()
    println(">>> objective weights: κ=$(w.kappa) w_g=$(w.w_g)")
else
    println(">>> objective weights: DISABLED (ENERGY_OBJECTIVE=0) — 구세대 동작")
end
```

`wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl` — `CB.enable_battery!` 줄(`:313`) 근처에
같은 블록을 넣는다.

- [ ] **Step 5: §9 의 두 검사를 스모크 테스트로 만든다**

`test/objective_hooks_smoke.jl`:

```julia
# ============================================================================
#  spec §9 의 두 검사:
#    (a) 배터리 훅 활성 검사 — 재풀이에서 LAST_AUTO_EFFICIENCY_W[] > 0 인가
#        (지금까지는 DeprioritizeAgent 에서만 참이었다 — spec §2.2 의 결함)
#    (b) greedy 디스패치 생존 검사 — greedy_cost 를 바꾸면 배정이 실제로 달라지는가
#        (§2.4 의 결함: 값이 저장만 되고 안 읽히는 상태로 되돌아가는 것을 막는다)
#
#    julia +lts --project=. test/objective_hooks_smoke.jl
# ============================================================================
using ConstructionBots
using Test
using Random
using Graphs
const CB = ConstructionBots

@testset "objective.json 이 두 자리에 심긴다" begin
    w = CB.init_objective_weights!()
    @test CB.AUTO_EFFICIENCY_KAPPA[] !== nothing
    @test CB.AUTO_EFFICIENCY_KAPPA[] > 0.0
    @test w.kappa == CB.AUTO_EFFICIENCY_KAPPA[]
    # T_scale/Eg_scale 이 채워져 있으면 w_g 도 양수여야 한다.
    if CB.GREEDY_ENERGY_W[] !== nothing
        @test CB.GREEDY_ENERGY_W[] > 0.0
    end
end

# 배정만 하고 멈추는 env 빌더(greedy_assignment_regression.jl 과 같은 모델·시드).
function build_env(gcost)
    return CB.run_lego_demo(; ldraw_file = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd"),
        project_name = "objhook", num_robots = 12, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(3),
        greedy_cost = gcost)
end

function fingerprint(env)
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(env.sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    for v in 1:Graphs.nv(env.sched)
        println(io, v, "=", round(CB.get_tF(env.sched, v), digits = 6))
    end
    return String(take!(io))
end

@testset "greedy 디스패치 생존 — greedy_cost 를 바꾸면 배정이 달라진다" begin
    CB.init_objective_weights!()
    if CB.GREEDY_ENERGY_W[] === nothing
        @info "T_scale/Eg_scale 미측정 — 이 검사 건너뜀"
        @test true
    else
        base   = fingerprint(build_env(CB.GreedyFinalTimeCost()))
        energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
        # 다르면 확장점이 살아 있다는 뜻. 같으면 §2.4 의 결함이 되살아난 것 —
        # 다만 w_g 가 너무 작아 argmin 이 한 번도 안 갈리는 경우도 같은 증상이라, 그때는
        # w_g 를 크게 키워 다시 본다(디스패치가 살아 있음만 확인하는 목적).
        if base == energy
            CB.GREEDY_ENERGY_W[] = 1.0e6   # 확실히 지배적인 값
            energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
            @info "w_g 를 1e6 으로 키워 재검사 (원래 w_g 로는 배정이 안 갈렸다 = κ 가 동점해소자 크기)"
        end
        @test base != energy
    end
end
```

`run_lego_demo` 가 `greedy_cost` 키워드를 받는지 먼저 확인한다:

```bash
cd /home/chahj578/Construction_OODlayer
grep -n "greedy_cost" src/full_demo.jl
grep -n "function run_lego_demo" src/full_demo.jl
```

`full_demo.jl:600,615` 가 `greedy_cost=GreedyFinalTimeCost()` 를 **하드코딩**하고 있으면,
`run_lego_demo` 에 `greedy_cost = GreedyFinalTimeCost()` 키워드를 추가하고 그 두 곳이
키워드를 쓰도록 고친다(기본값이 현행 값이므로 동작 불변).

- [ ] **Step 6: 검사를 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer
timeout 3600 julia +lts --project=. test/objective_hooks_smoke.jl 2>&1 | tail -25
```

Expected: 전부 통과.

**회귀 게이트 재확인 — 켜기 전 상태가 여전히 보존되는가:**

```bash
cd /home/chahj578/Construction_OODlayer
timeout 3600 julia +lts --project=. test/greedy_assignment_regression.jl 2>&1 | tail -10
```

Expected: **여전히 통과**. `run_lego_demo` 의 기본 `greedy_cost` 가 `GreedyFinalTimeCost` 이므로
골든 해시가 바뀌면 안 된다. **바뀌면 Step 5 의 키워드 추가가 기본값을 바꾼 것이다** — 고친다.

```bash
cd /home/chahj578/Construction_OODlayer
timeout 5400 julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -25
/home/chahj578/Construction_OODlayer/.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py
```

Expected: `Pkg.test()` = 11 passed / 1 errored. 감사는 **이제 7/7 전부 OK**
(항목 5 전역 κ 가 이 태스크에서 배선됐다).

- [ ] **Step 7: 배터리 훅 활성 검사 — 실제 재풀이 한 판**

`LAST_AUTO_EFFICIENCY_W[] > 0` 이 **Deprioritize 아닌 매크로의 재풀이에서도** 참인지 본다.
respec 재풀이를 타는 케이스로 한 판 돌리고 로그를 본다:

```bash
cd /home/chahj578/Construction_OODlayer
DEMO_SUMMARY=/tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t6_hook.jsonl \
DEMO_SEED=3 DEMO_OOD_SEED=3 \
  timeout 3600 julia +lts --project=. tools/monitor/run_demo.jl 2>&1 \
  | tee /tmp/claude-1035/-home-chahj578/2eefc69a-7b2a-4d79-8850-5dc3bf74e1e9/scratchpad/t6_hook.log \
  | grep -i "energy term\|objective weights\|RESPEC" | tail -30
```

Expected: `>>> objective weights: κ=... w_g=...` 가 찍히고, 재풀이가 일어났다면
`energy term ON` 이 나온다. `energy term NOT active` 가 나오면 **§2.2 의 결함이 남아 있는 것**
— 원인을 찾아 고친다(대개 `init_objective_weights!` 호출이 그 경로 앞에 없다).

재풀이가 한 번도 안 일어난 판이면 그 사실을 report 에 적고, `DEMO_OOD_SEED` 를 바꿔
한두 판 더 시도한다(판당 ~2~10분). 세 판 안에 재풀이가 안 나오면 그 사실을 report 에 적고
넘어간다 — 검사 자체는 `test/objective_hooks_smoke.jl` 의 첫 testset 이 이미 커버한다.

- [ ] **Step 8: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add src/essential_tg_coponents.jl src/respec/replan.jl src/full_demo.jl \
        tools/monitor/run_demo.jl wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl \
        test/objective_hooks_smoke.jl
git commit -m "feat(objective): activate energy — GreedyEnergyAwareCost + global MILP kappa

greedy: edge_energy(dt)·edge_cost_multiplier(sched,v) 항을 추가한 새 GreedyCost 타입.
  edge_cost_multiplier 가 agent_cost_bias × 배터리 SoC 배율을 나르므로, 이 한 항으로
  greedy 경로에서도 DeprioritizeAgent 와 SoC 조향이 처음으로 실효를 갖는다.
MILP: κ 를 DeprioritizeAgent 국소 스코프에서 전역 기본값으로 승격 — 나머지 모든 매크로의
  재풀이가 에너지를 버린 채 돌던 결함(spec §2.2)을 고친다.
둘 다 objective.json 의 kappa 하나에서 나온다(단일 진실원, §4). ENERGY_OBJECTIVE=0 으로 끌 수 있다."
```

---

## Task 7: 세대 교체 표시 + 무력 검사 리포터

Spec §7, §9 의 "무력 검사". 마지막 태스크.

**Files:**
- Create: `wm4spacecraft_manufacturing/report_energy_decisiveness.py`
- Modify: `wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md` (🔴 배너)
- Modify: `/home/chahj578/Construction_OODlayer/.claude/CLAUDE.md` (세대 절 갱신)

**Interfaces:**
- Consumes: `objective.py` 의 `J`, `J_row`, `objective_hash`
- Produces: `report_energy_decisiveness.py` (오라클 덤프가 생기면 돌린다)

- [ ] **Step 1: 무력 검사 리포터**

spec §9: "에너지 항이 a\* 를 한 번이라도 바꾸는가 — 0 이면 0 이라고 보고한다."

`wm4spacecraft_manufacturing/report_energy_decisiveness.py`:

```python
#!/usr/bin/env python3
"""에너지 항이 실제로 결정을 바꾸는가 (spec §9 '무력 검사').

각 (instance) 별로 후보 팔들의 J 를 두 번 계산한다:
  - 에너지 포함 (w_E = kappa·M_ref/E_ref)
  - 에너지 제외 (w_E = 0)
argmin 이 갈리는 instance 수를 센다. **0 이면 0 이라고 보고한다** —
"energy 도 최소화한다"가 명목상 주장으로 남는 상황을 숨기지 않는다.

    .venv/bin/python report_energy_decisiveness.py <dump.jsonl> [--key instance_id]
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objective  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", help="instance × macro 행이 담긴 JSONL")
    ap.add_argument("--key", default="instance_id", help="instance 를 식별하는 필드명")
    ap.add_argument("--arm", default="macro", help="팔(후보)을 식별하는 필드명")
    args = ap.parse_args()

    cfg = objective.load()
    cfg_noE = dict(cfg)
    cfg_noE["kappa"] = 0.0   # 에너지 항만 끈다

    groups = collections.defaultdict(list)
    skipped = 0
    with open(args.dump) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if args.key not in r or args.arm not in r:
                skipped += 1
                continue
            groups[r[args.key]].append(r)

    flipped, evaluated, errors = 0, 0, 0
    examples = []
    for inst, rows in groups.items():
        try:
            with_e = min(rows, key=lambda r: objective.J_row(r, cfg=cfg))
            no_e = min(rows, key=lambda r: objective.J_row(r, cfg=cfg_noE))
        except objective.ObjectiveError:
            errors += 1
            continue
        evaluated += 1
        if with_e[args.arm] != no_e[args.arm]:
            flipped += 1
            len(examples) < 10 and examples.append(
                {"instance": inst, "with_energy": with_e[args.arm], "without": no_e[args.arm]})

    print(json.dumps({
        "objective_hash": objective.objective_hash(cfg),
        "kappa": cfg["kappa"],
        "instances_evaluated": evaluated,
        "instances_where_energy_flipped_argmin": flipped,
        "flip_rate": (flipped / evaluated) if evaluated else None,
        "instances_skipped_missing_fields": skipped,
        "instances_error_missing_energy": errors,
        "examples": examples,
        "verdict": ("에너지가 a* 를 한 번도 바꾸지 않았다 — κ 가 노이즈에 묻혀 있다 (spec §4.2, §11-1). "
                    "'energy 도 최소화한다'는 현재 명목상 주장이다."
                    if evaluated and flipped == 0 else
                    "에너지가 %d/%d instance 에서 a* 를 바꿨다." % (flipped, evaluated)
                    if evaluated else "평가 가능한 instance 가 없다"),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

돌려 본다 — 지금 있는 덤프로:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
ls oracle/out/*.jsonl
/home/chahj578/Construction_OODlayer/.venv/bin/python report_energy_decisiveness.py \
  oracle/out/n44_plus78.jsonl --key instance_id --arm macro
```

**구세대 덤프에는 `energy_J` 가 없으므로 `instances_error_missing_energy` 가 전부일 것이 정상이다.**
그 사실을 report 에 그대로 적는다 — 이 리포터는 단계 6~7 의 신세대 덤프에서 쓰인다.
`--key` 의 실제 필드명은 덤프의 첫 행을 보고 맞춘다:

```bash
/home/chahj578/Construction_OODlayer/.venv/bin/python -c "
import json; print(sorted(json.loads(open('oracle/out/n44_plus78.jsonl').readline()).keys()))"
```

- [ ] **Step 2: 구세대 결과 문서에 🔴 배너 (spec §7-1)**

`wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md` 의 **맨 위**에 붙인다
(삭제하지 않는다 — 되돌리기와 비교에 쓴다):

```markdown
> # 🔴 구세대 (2026-08-13 목적함수 통일 이전)
>
> 이 문서의 모든 수치는 **에너지가 목적함수에서 버려지던 세대**의 것이다.
> 2026-08-13 부터 greedy·MILP·오라클 라벨이 전부 `objective.json` 의 공통 J 를 최소화한다
> (`docs/superpowers/specs/2026-08-13-unified-objective-design.md`). 플래너 동역학이 바뀌었으므로
> **이 수치를 현재 성능으로 인용하지 말 것.** 신세대 수치는 630판 스윕 재실행(spec §8 단계 6) 뒤에 나온다.
>
> 판정 계약: 산출물의 `objective_hash` 가 현재 `objective.json` 의 해시와 다르면 다른 세대다.
```

먼저 이 문서에 이미 배너가 있는지 확인하고, 형식을 맞춘다:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
head -20 md/RESULTS_D20_2026-08-12.md
head -12 md/RESULTS_FARDEPOT_2026-08-12.md   # 기존 🔴 배너의 형식을 본다
```

- [ ] **Step 3: CLAUDE.md 의 "★ 결과 세대" 절 갱신**

`/home/chahj578/Construction_OODlayer/.claude/CLAUDE.md` 의 `## ★ 결과 세대` 절에
**맨 앞**에 한 문단을 추가한다:

```markdown
### 2026-08-13 — 목적함수 통일로 또 한 번 세대가 갈렸다

`wm4spacecraft_manufacturing/objective.json` 이 목적함수 J 의 단일 진실원이다.
greedy(`GreedyEnergyAwareCost`) · MILP(전역 `AUTO_EFFICIENCY_KAPPA`) · 오라클 라벨
(`gen_oracle_mc.scalar_cost`) · Python 분석(`e1_analyze.cost_lex_key`) 이 전부 그 J 를 본다.
설계: `docs/superpowers/specs/2026-08-13-unified-objective-design.md`.

- **세대 판정 계약**: 산출물의 `objective_hash` 필드가 현재 `objective.json` 의 해시와 같은가.
  `.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py` (exit 0 = 소비처 전부 일치).
- **기계적 계약 3종**: `test_objective.py` · `audit_objective.py` · `test/greedy_assignment_regression.jl`.
- 이 날 이전의 모든 결과 문서(= `RESULTS_D20_2026-08-12.md` 포함)는 구세대다.
- `ENERGY_OBJECTIVE=0` 으로 구세대 동작을 재현할 수 있다(끈 사실이 로그에 남는다).
- **아직 안 한 것**: 630판 스윕 재실행(단계 6), surrogate 재라벨·재학습(단계 7),
  prefix 결정성 재측정(단계 8), DP 계획 재개(단계 9). 그때까지 신세대 성능 수치는 없다.
```

- [ ] **Step 4: 전체 계약 재확인**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
P=/home/chahj578/Construction_OODlayer/.venv/bin/python
$P test_objective.py;          echo "test_objective=$?"
$P audit_objective.py;         echo "audit_objective=$?"
$P audit_action_vocab.py;      echo "audit_action_vocab=$?"
$P test_surrogate_support.py;  echo "test_surrogate_support=$?"
cd /home/chahj578/Construction_OODlayer
timeout 3600 julia +lts --project=. test/greedy_assignment_regression.jl 2>&1 | tail -5
timeout 3600 julia +lts --project=. test/objective_hooks_smoke.jl 2>&1 | tail -5
timeout 900  julia +lts --project=. test/mdp_mc_label_smoke.jl 2>&1 | tail -5
timeout 5400 julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20
```

Expected: 파이썬 4개 전부 exit 0, Julia 테스트 3개 전부 통과, `Pkg.test()` = 11 passed / 1 errored.
**하나라도 어긋나면 그 사실을 report 에 그대로 적는다** — 통과했다고 쓰지 않는다.

- [ ] **Step 5: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/report_energy_decisiveness.py \
        wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md .claude/CLAUDE.md
git commit -m "docs(objective): generation banner + energy decisiveness reporter

spec §7: 구세대 결과 문서에 🔴 배너, CLAUDE.md 에 세대 판정 계약(objective_hash) 기록.
spec §9 무력 검사: 에너지가 a* 를 한 번이라도 바꾸는지 세는 리포터 — 0 이면 0 이라고 보고한다."
```

---

## 부록 A: 단계 6~9 (이 계획의 범위 밖) 시간 추정

| 단계 | 무엇 | 추정 시간 | 근거 |
|---|---|---|---|
| 6 | 630판 스윕 재실행 (신세대) | **3~8 시간** (병렬) / ~21시간 (순차) | 판당 ~121 s 실측(`.superpowers/sdd/2026-08-11-seed20-verification/progress.md`). greedy 라 병렬 유지 가능(`run_4pol_parallel.sh`). 프로세스당 ~2.5GB 이므로 병렬도는 RAM 이 정한다(CLAUDE.md 함정 30) |
| 7 | surrogate 재라벨 + 재학습 | **12~20 시간** | 재라벨 = 68 instance × 7 매크로 ≈ 476 full sim. 재학습 자체는 수 분. `test_surrogate_support.py` 재검증 포함 |
| 8 | prefix 결정성 재측정 (주입점 4개) | **1~3 시간** | 주입점당 몇 판. 깨지면 DP 표집이 `measured` 경로로 가서 K 가 2배 (spec §11-2) |
| 9 | DP 계획 재개 (`2026-08-13-dp-oracle.md` Task 2~12) | **별도 계획** — 수 일 | 이미 `.superpowers/sdd/2026-08-13-dp-oracle/` 에 진행 원장이 있다 |

## 부록 B: 이 계획(태스크 1~7) 시간 추정

| 태스크 | 코드 작업 | 검증 실행 | 합계 |
|---|---|---|---|
| 1 런 레벨 기록 | ~15 분 | ~15~25 분 (스모크 2판) | **30~40 분** |
| 2 greedy 디스패치 (게이트) | ~25 분 | ~40~70 분 (env 빌드 3회 + `Pkg.test()`) | **65~95 분** |
| 3 스케일 측정 | ~25 분 | ~5 분 (또는 파일럿 필요 시 +15분) | **30~45 분** |
| 4 objective.json + J | ~40 분 | ~10 분 (순수 단위검사) | **50 분** |
| 5 소비처 배선 + 감사 | ~45 분 | ~20 분 | **65 분** |
| 6 에너지 활성화 | ~40 분 | ~60~90 분 (env 빌드 3회 + 스모크 + `Pkg.test()`) | **100~130 분** |
| 7 세대 표시 + 리포터 | ~25 분 | ~50 분 (전체 계약 재확인) | **75 분** |
| | | **소계** | **약 7~8 시간** |
| | | 리뷰 루프 여유 (×1.3) | **약 9~10 시간** |

가장 긴 항목은 코드가 아니라 **Julia env 빌드와 `Pkg.test()`** 다(각각 수 분~수십 분).
태스크 2 와 6 이 그 때문에 무겁다.

---

## Self-Review

**Spec coverage:**

| Spec 절 | 담당 태스크 |
|---|---|
| §2.3 (기록이 없다) | 태스크 1 |
| §2.4 (greedy 확장점 미배선) | 태스크 2 |
| §3 (J 정의) | 태스크 4 |
| §3.1 (에너지는 완주 분기만) | 태스크 4 Step 4 검사 3, Global Constraint 1 |
| §3.2 (λ·MACRO_COST 제외) | 태스크 5 Step 4 |
| §4 (κ 와 단위, 세 자리 공유) | 태스크 4(J), 태스크 6(greedy·MILP) |
| §4.1 (κ 는 동점해소자) | 태스크 4 Step 4 검사 4 |
| §4.2 (노이즈 한계 — 정직한 보고) | 태스크 7 Step 1 |
| §5 / §5.1 (objective.json, 소비처) | 태스크 4, 5 |
| §6.1 (greedy 유지, MILP 는 safety layer) | 유지 — `assignment_mode` 를 건드리지 않는다 |
| §6.2 (greedy 디스패치) | 태스크 2, 6 |
| §6.3 (MILP 전역 κ) | 태스크 6 |
| §7 (세대 교체) | 태스크 5 (해시 기록), 태스크 7 (배너) |
| §8 단계 1~5 | 태스크 1~6 |
| §8 단계 6~9 | **범위 밖** (부록 A) |
| §9 검사 7종 | 순서동치·실패보상·null 스케일 = 태스크 4; 회귀 = 태스크 2; 배터리 훅·디스패치 생존 = 태스크 6; 해시 = 태스크 5; 무력 = 태스크 7 |
| §10 (범위 밖) | 존중 — adaptability / handling_energy 를 J 에 안 넣는다 |
| §11-7 (`update_greedy_cost_model!`) | 태스크 2 Step 10 |

**미커버 (의도적, 위의 Ruling 참조):** §5.1 의 `dp_solve.py`(존재하지 않음),
§8 단계 6~9(계산 캠페인), §11-1·§11-3(알려진 구멍 — 완화가 아니라 보고 대상).

**Type consistency:** `greedy_edge_cost(gc, sched, v, v2, dt::Float64)` 는 태스크 2 에서 정의되고
태스크 6 이 메서드를 하나 더 붙인다 — 시그니처 동일. `objective.J(...)` 는 Python·Julia 모두
키워드 인자 `complete, closed, total, makespan, energy_J, cfg` — 동일. `objective_hash` 는
양쪽 모두 16자 hex 문자열.

**알려진 위험 (실행자가 마주칠 것):**
1. 태스크 2 Step 3 에서 배정이 결정적이지 않으면 게이트가 성립하지 않는다 → BLOCKED 보고.
2. 태스크 4 Step 5 의 Julia/Python 정규 JSON 해시 일치는 미묘하다 → 대안(파일 바이트 해시)을 명시해 뒀다.
3. 태스크 5 Step 4 의 `cost_lex_key` 시그니처 변경은 호출자 5곳에 파급된다 → (A)/(B) 선택지를 명시해 뒀다.
4. 모델 파일 이름(`tractor.mpd`)이 틀릴 수 있다 → 태스크 2 Step 2 에서 `test_demo.jl` 을 보고 맞추게 했다.
