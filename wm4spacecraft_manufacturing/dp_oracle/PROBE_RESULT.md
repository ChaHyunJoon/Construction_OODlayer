# PROBE_RESULT: prefix 결정성 — 표집 방식 확정

측정 스크립트: `wm4spacecraft_manufacturing/dp_oracle/probe_prefix_determinism.jl`
원본 raw 출력: `wm4spacecraft_manufacturing/dp_oracle/probe_result_raw.json`
측정일: 2026-08-13. 환경: `julia +lts --project=.` (1.10.11), repo root, 순차 실행(병렬 없음).

## sampling_mode: replay

## 질문과 답

묻는 것: "닫힌 노드 c(=30)에 도달해 사건을 주입하는 **바로 그 순간**의 상태가, 같은 build seed 로
재실행할 때마다 재현되는가?" (런 전체의 재현성이 아니다 — 2026-08-11 관측된 `n_closed 149->123`
발산은 런 전체 숫자라 이 질문에 답하지 않는다.)

**답: 그렇다.** `AT_CLOSED=30`, `ORACLE_SEED=1`(build seed) 로 10회 반복한 지문이 **10/10 완전히
동일**했다. 그래서 DP 오라클의 각 팔(arm)은 "노드에서 prefix 를 1회만 만들고 그 뒤를 in-process
로 분기(fork)"할 필요가 없다 — **매 팔마다 build seed 를 고정한 채 그냥 처음부터 다시 굴리면(replay)
주입 시점의 상태가 결정론적으로 재현된다.** 이게 `replay` 판정이다.

## Step 2 raw 결과 (10/10 identical)

```json
{"identical": true, "n": 10, "wall_s_total": 112.2, "wall_s_mean": 11.2}
```

10회 모두 완전히 동일한 지문:

```json
{"closed": 58, "active": 22, "pending_queue": 80, "sim_step": 2, "sim_seconds": 0.05,
 "soc_sorted": [1.0 x22]}
```

(closed=58 은 `AT_CLOSED=30` 문턱을 넘은 시점의 실제 닫힌 노드 수 — build 초반에 "장부성" 노드
다수가 한꺼번에 닫히기 때문에 30을 넘어서자마자 58에서 잡힌다. `sim_step=2` 도 같은 이유: 이
시점은 물리적으로 시뮬레이션 "중반"이 아니라 초반 몇 스텝 안이다. 그래도 `gen_oracle_mc.jl` 의
실제 `schedule_studied_fault!` 도 동일한 `closed_at` 문턱(12/20/30/45/60) 방식을 쓰므로, 여기서
관측한 결정성은 프로덕션 주입 메커니즘 그대로에 대한 답이다.)

**Step 3 (deepcopy 충실성)은 건너뛰었다** — Step 2 가 `identical=true` 이므로 태스크 룰링에 따라
불필요(replay 경로가 이미 성립).

## 참고: deepcopy/fork 가 애초에 구조적으로 막혀 있다는 근거 (Step 3 미실행이지만 기록해 둠)

Step 2 가 이미 `replay` 를 확정했으므로 아래는 검증이 아니라 **참고용 소스 확인**이다(시뮬레이션
안 돌림, grep 근거만):

- `run_lego_demo`(`src/full_demo.jl:137`)는 매번 **새** `PlannerEnv` 를 처음부터 만든다. 기존
  env 를 이어받아 계속 진행시키는 재개(resume) 진입점이 코드베이스 어디에도 없다.
- 물리 상태의 상당 부분이 `PlannerEnv` 필드가 아니라 **프로세스 전역 `Ref`/싱글턴**이다:
  `rvo_global_sim()`/`rvo_global_id_map()`(`src/rvo_interface.jl:46`, PyCall 너머 RVO2 C++
  시뮬레이터 인스턴스 하나뿐), `BATTERY_FLEET`(`src/navigator/battery.jl:111`), `HAZARD_STATE`
  (`src/mdp/hazard.jl`), `OOD_SCHEDULE`(`src/respec/ood_injection.jl:1077`), `SIM_STEP`
  (`src/respec/asset_ledger.jl:100`).
- 즉 `deepcopy(env)` 가 구조체 자체는 복제해도, 두 "가지"를 각자 진행시키려 하면 여전히 **같은**
  RVO C++ 인스턴스가 물리 스텝을 계산하므로 두 계보가 서로 간섭한다. `fork` 경로는 이 하니스
  구조상 애초에 성립하지 않는다 — 다행히 Step 2 결과가 `replay` 로 이미 충분하므로 이 제약은
  걸림돌이 되지 않는다.

## 벽시계 시간 (Task 2+ CPU-hour 예산에 쓸 것 — 반드시 아래 구분을 지킬 것)

**중요: 이 프로브 자체는 지문을 찍은 직후 시뮬레이션을 강제 종료시키는 프로브 전용 "fast-abort"
트릭을 쓴다(`probe_prefix_determinism.jl` 내부 문서 참조, `gen_oracle_mc.jl` 은 손대지 않음).
그래서 프로브가 찍은 벽시계 시간은 "지문 재현성 측정 비용"일 뿐, 실제 DP 오라클 샘플링(=매 팔마다
전체 rollout 을 끝까지 굴려야 하는 `run_one`)의 비용과 다르다.** 셋을 구분해서 기록한다:

| 측정 대상 | 값 | 근거 |
|---|---|---|
| 프로브 자체, 콜드(1회차, JIT 포함, fast-abort) | **85.7s** | probe run [1/10] |
| 프로브 자체, 웜(2~10회차, fast-abort) | **~2.9s/run** | probe run [2/10]~[10/10], 평균 2.93s |
| **프로덕션 전체 rollout, 콜드(새 프로세스, fast-abort 없음)** | **88.0s / 91.0s** (2회 측정) | `run_one(...; inject=false)` 단독 실행 |
| **프로덕션 전체 rollout, 웜(같은 프로세스 두 번째 호출부터, fast-abort 없음)** | **8.1s/run** | 같은 프로세스에서 `run_one` 2회 연속 호출 — 1회차 88.0s, 2회차 8.1s |

**해석**: `run_one` 의 벽시계 비용은 거의 전부 **프로세스당 1회 JIT/패키지 로드 오버헤드**(~80s)이고,
같은 프로세스 안에서 반복되는 실제 시뮬레이션 자체는 **~8s/rollout**이다. 이것은 `gen_oracle_mc.jl`
자체의 기존 설계 근거(534-543행 주석, "MC_ONLY 는 유닛마다 새 프로세스라 기동비용이 지배적 ->
MC_BATCH 로 기동을 1회로 상각")와 정확히 일치한다 — 이번 실측이 그 설계 판단을 재확인한 것이다.

**Task 2+ 를 위한 CPU-hour 예산 지침**: 새 프로세스 1개당 rollout 을 하나만 돌리면(=구세대
`MC_ONLY` 방식) rollout 당 실효비용은 ~90s 로 잡아야 한다. `MC_BATCH`/`MC_AGGREGATE` 처럼 **같은
프로세스에서 여러 rollout 을 연속 실행**하면 실효비용은 워커(프로세스)당 1회 ~90s 착수비 +
rollout 당 ~8s 로 잡을 것 — 후자를 쓰지 않고 전자의 숫자(~90s/rollout)로 전체 예산을 잡으면
대략 **10배 과대추정**이 되어 스케줄을 불필요하게 부풀릴 수 있다(반대로 후자 숫자를 배치 없이
가정하면 과소추정으로 실제보다 훨씬 오래 걸린다 — 반드시 실행 방식과 숫자를 짝지어 쓸 것).

## AT_CLOSED=30 이 실제로 대표하는 지점에 대한 경고

`AT_CLOSED=30` 은 closed count 기준으로는 이르지만(총 313 노드 중 초반 58에서 잡힘, sim_step=2),
`schedule_studied_fault!` 가 실제 프로덕션에서 쓰는 5개 문턱(12/20/30/45/60) 중 하나이므로 이
자체는 문제가 아니다 — 다만 "prog_b 중간 구간을 대표"한다는 브리프의 묘사는 **build 진행률
기준으로는 초반**이라는 점을 후속 태스크가 오인하지 않도록 명시해 둔다. 이번 프로브가 확인한
것은 이 문턱에서의 결정성이며, 다른 문턱(12/20/45/60)에 대해서도 같은 논리(build seed 고정 +
위험 프로세스는 그 순간에 arm)가 적용되므로 재현성 결론은 이 문턱에 국한되지 않고 일반화된다고
본다(단, 이후 태스크가 의심스러우면 같은 프로브를 `AT_CLOSED` 값만 바꿔 재실행할 수 있다).

## 접근자 실제 이름 (브리프의 placeholder 대체표)

| 브리프 placeholder (존재하지 않음) | 실제로 쓴 접근자 | 근거 |
|---|---|---|
| `CB.n_closed(env)` | `length(env.cache.closed_set)` | `route_planning.jl:124`, `run_one` 도 동일 필드로 `closed` 산출 |
| `CB.n_active_agents(env)` | `length(env.cache.active_set)` | `route_planning.jl:123`, `essential_tg_coponents.jl:1662 PlanningCache` |
| `CB.total_pending(env)` | `length(env.cache.node_queue)` | 같은 `PlanningCache` |
| `CB.sim_seconds(env)` | `CB._current_sim_step() * env.dt` | `respec/asset_ledger.jl:100-102`(`SIM_STEP`/`_current_sim_step`), `PlannerEnv.dt` |
| `CB.agent_socs(env)` | `CB.battery_report().soc` | `navigator/battery.jl:316`(기존 리포터, 새로 안 만듦) |

`grep -rn "function n_closed\|n_active\|pending" src/` 는 무결과 — 브리프가 가정한 이름들은
저장소에 없다.
