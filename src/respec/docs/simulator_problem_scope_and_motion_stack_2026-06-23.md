# ConstructionBots 시뮬레이터: 문제 범위 · 목적함수 · 모션 스택 분석

작성일: 2026-06-23

이 문서는 "현재 시뮬레이터가 무엇을 풀 수 있는가", "목적함수(objective)는 어떻게
정의되어 있는가", "충돌회피 모션 스택은 어떻게 계층적으로 구성되는가"를 코드 위치와
함께 정리한 것이다. 부속 작업으로 `tangent_bug.jl`, `potential_fields.jl`,
`rvo_interface.jl`에 한국어 인라인 주석(수식 포함)을 추가했다.

---

## 1. 시뮬레이터가 푸는 문제 = Multi-Robot Assembly Planning (TAMP)

ConstructionBots.jl은 **다중 로봇 조립 계획(multi-robot assembly planning)** 시뮬레이터다.
LEGO/LDraw 모델을 여러 모바일 로봇이 부품을 운반·배치해 완성한다. 실제 끼워맞춤의
kino-dynamic 디테일은 추상화하고, 상위 추상 수준에서 다음 4개 하위문제를 다룬다 (README):

1. **Transport team configuration** — 한 payload를 몇 대 로봇이 어떤 배치로 운반?
2. **Spatial layout / staging** — 각 assembly를 어디서 짓고 부품을 어디로 배달?
3. **Sequential task allocation & team forming** — 어떤 로봇이 어떤 payload를 순차 운반?
   (payload 수 ≫ 로봇 수이므로 로봇은 여러 payload를 순서대로 처리)
4. **Heterogeneous collision avoidance** — 적재/비적재 로봇·팀이 서로·공사장과 충돌 없이 이동?

→ 즉 **TAMP가 맞다**: Task planning(스케줄 + 할당) + Transit/Motion planning(이동 + 충돌회피).

### 결론적 교정 (사용자 이해 대비)
| 사용자의 이해 | 실제 |
|---|---|
| 문제는 TAMP | ✅ 맞음 |
| objective가 TAMP를 빨리 끝내려 함 | ✅ 맞음 — `SumOfMakeSpans` (가중 완료시각 합 최소화) |
| collision avoidance를 위해 **objective가 hierarchical**하게 정의됨 | ⚠️ **부분 교정** — 충돌회피는 위 makespan **목적함수에 포함되지 않음**. 별도의 **계층형 reactive 속도 제어기**(TangentBug→PotentialField→RVO)이고, 그 안의 "계층"은 **α(priority) 시스템**임 |

핵심: **윗단(이산 최적화)** 과 **아랫단(연속 반응 제어)** 은 분리되어 있다.
- 윗단: 명시적 목적함수(makespan)로 "누가·무엇을·언제" 결정 (task assignment).
- 아랫단: 목적함수 없는 **우선순위 기반 계층형 속도 제어**로 충돌 회피 (simulation loop).

---

## 2. 윗단 — Task Allocation 목적함수 (makespan)

### 2.1 목적함수: `SumOfMakeSpans`
terminal node(프로젝트 완료 노드)들의 완료시각 `tF[v]`의 **가중합**을 최소화.

- 정의: `src/essential_tg_coponents.jl:536-539`
- MILP 목적식: `src/essential_tg_coponents.jl:1078-1091`
  ```julia
  cost1 = @expression(model, sum(map(v -> tF[v] * get(sched.weights, v, 1.0), terminal_vtxs)))
  ```
- 주의: 단순 max makespan이 아니라 **weighted sum of completion times**.

### 2.2 weight는 어떻게 계산되는가? → **사실상 계산되지 않고 1.0으로 고정**
이번 조사의 핵심 발견.

- `sched.weights :: Dict{Int,Float64}` — terminal vtx → weight. (`essential_tg_coponents.jl:160`)
- 채워지는 유일한 곳: `set_leaf_vtxs!` (`src/task_assignment.jl:313-323`)
  ```julia
  function set_leaf_vtxs!(sched::OperatingSchedule, template=ProjectComplete)
      empty!(get_terminal_vtxs(sched))
      empty!(get_root_node_weights(sched))
      for v in Graphs.vertices(sched)
          if is_terminal_node(sched,v) && matches_template(template,get_node(sched,v))
              push!(get_terminal_vtxs(sched), v)
              get_root_node_weights(sched)[v] = 1.0     # ← 전부 1.0 하드코딩
          end
      end
      sched
  end
  ```
- 따라서 LEGO 단일모델 데모에서:
  - 모든 terminal node weight = 1.0
  - ProjectComplete 노드가 보통 1개 → 목적함수 = `tF[ProjectComplete]` = 사실상 **최종 조립 완료시각(makespan) 그 자체**.
- 일반 가중치 인프라(`MultiDeadlineCost.weights`, `deadlines`)는 존재하나
  (`essential_tg_coponents.jl:531-547`) 현재 코드 경로에서는 가중치를 1.0 외 값으로 쓰지 않는다.
  → **여러 프로젝트를 동시에 다른 우선순위로 돌리고 싶을 때** 확장할 수 있는 자리이지만,
    지금은 비활성. (respec/확장 시 후보 지점)

### 2.3 목적함수를 푸는 solver
파라미터 `assignment_mode` (`src/full_demo.jl:64`): `:greedy` / `:milp` / `:milp_w_greedy_warm_start`.

- **Greedy**: `GreedyOrderedAssignment` (`task_assignment.jl:226-236`),
  핵심 루프 `assign_collaborative_tasks!` (`task_assignment.jl:374-519`).
  로봇-태스크 비용 ≈ `get_tF(sched, v) + distance`.
- **MILP**: `AssignmentMILP` / `SparseAdjacencyMILP` (`essential_tg_coponents.jl:591-617`),
  `formulate_milp` (`essential_tg_coponents.jl:729`).

### 2.4 선행관계(precedence) 표현
노드 타입별 required predecessor/successor 규칙으로 DAG 구성:
`src/construction_schedule.jl:275-316`. 시간 전파(topological): `update_schedule_times!`
(`construction_schedule.jl:290-301`) — `t0(v) = max(predecessor tF)`, `tF = t0 + min_duration`.

---

## 3. 아랫단 — 계층형 충돌회피 모션 스택

매 timestep 한 에이전트의 명령속도를 만드는 함수: **`get_twist_cmd`**
(`src/route_planning.jl:737-827`). 위→아래로 3개 레이어가 순차 합성된다.

```
route planning (goal config)
      │  nominal goal
      ▼
① Tangent Bug      : 정적 원형 staging area 우회 waypoint          [tangent_bug.jl]
      │  nominal twist
      ▼
② Potential Field  : 이웃 에이전트 반발(분산), 우선순위(α) 게이팅   [potential_fields.jl]
      │  보정된 twist
      ▼
③ RVO2 (pref vel)  : 상호 충돌회피 최종속도                         [rvo_interface.jl]
      │  setAgentPrefVelocity → sim.doStep()
      ▼
  실제 속도(getAgentVelocity)로 위치 적분
```

- pref velocity 주입: `route_planning.jl:862`
- α(priority) 설정: `route_planning.jl:146-172` (`set_rvo_priority!`)
- RVO step: `route_planning.jl` `step_environment!` 내 `sim.doStep()`

### 3.1 ① Tangent Bug (`src/tangent_bug.jl`)
- 정적 장애물(=비활성 staging 원)을 반지름 r 원으로 보고, 직선 경로가 막히면 **접선**을 따라 우회.
- 상태기계 모드: `MOVE_TOWARD_GOAL` / `WAIT_OUTSIDE` / `EXIT_CIRCLE` /
  `MOVE_ALONG_CIRCLE` / `MOVE_TANGENT` (`set_policy_mode!`).
- 기하 핵심(주석 추가됨):
  - 선-원 교점: `b=|center→line|`, 반현 `a=√(r²-b²)`.
  - 원 위 한 스텝(호 `dr=vmax·dt`) → 중심각 `dθ=2·sin(0.5·dr/r)`.
  - 접선점: 접선 반각 `ψ=asin(r/|c-pos|)`, 반경벡터를 `π/2-ψ` 회전.
- 에이전트 반경+buffer만큼 원을 **bloat**(Minkowski)하여 점-에이전트로 환원.

### 3.2 ② Potential Field / Dispersion (`src/potential_fields.jl`)
- `v = -∇U(x)` (gradient descent). 실사용 제어기는 `PotentialFieldController`.
- 로봇쌍 반발: `repulsion_potential` = cone(중거리 선형) + barrier(근거리 1/d 폭발).
- **우선순위(α) 게이팅이 "계층"의 본질**:
  - `compute_potential_gradient!` (`potential_fields.jl:263-290`): `α1 ≤ α2`인 상대는 **skip**
    → "나는 나보다 우선순위 낮은 로봇에게만 밀린다."
  - `pairwise_potential_scale` (`238-246`): `α1<α2 → 0` (양보 안 함).
  - `update_buffer_radius!` (`195-210`): 가까운 활성 에이전트일수록 버퍼↑, 작업 중이면 최대.

### 3.3 ③ RVO2 (`src/rvo_interface.jl`)
- Python-RVO2(C++)의 Julia 래퍼. 모든 에이전트의 pref velocity를 받아 충돌 없는 속도를 동시 해법.
- **α (동적 우선순위)**: sisl이 RVO2를 fork해 추가. `rvo_set_agent_alpha!`/`getAgentAlpha`.
  작을수록 높은 우선순위 → 양보 책임을 비대칭 분담.
- 이질성(heterogeneity) 모델링:
  - 최대속도 ∝ 부피 역비례: `get_rvo_max_speed` — 큰 payload 팀은 느림.
  - 이웃거리 ∝ 속도: `get_rvo_neighbor_distance`.
- 에이전트 단위: 단독 로봇은 root일 때, 운반팀은 formation 완성 시 **팀 전체**가 1 에이전트
  (`rvo_add_agents!`).

### 3.4 α(priority) 값 체계 (`set_rvo_priority!`)
낮을수록 우선:
- `0.0` — FormTransportUnit / DepositCargo / 활성 운반 중(cargo id로 미세 구분)
- `0.1` — 픽업 준비된 활성 RobotGo
- `0.5` — 활성이지만 픽업 미준비 RobotGo
- `1.0` — 비활성(최저)

→ "조립 임박/적재 에이전트가 통행권을 가지며, 한가한 로봇이 길을 비켜주는" 계층 구조.

---

## 4. 두 계층이 만나는 곳 (전체 루프)

- 진입점: `src/full_demo.jl` (parse → schedule DAG → scene tree → staging → **assignment** → simulate)
- 시뮬 루프: `src/demo_utils.jl:38` `run_simulation!` → `:77` `simulate!`
  - `step_environment!` (`route_planning.jl:251`): 명령 산출 → RVO step → 위치 갱신
  - `update_planning_cache!` (`route_planning.jl:312`): `is_goal` 노드 close, successor 활성화
- 종료조건(=암묵적 "최대한 빨리 끝낸다"의 실현): 모든 `ProjectComplete` close
  → `project_complete` (`route_planning.jl:388-398`).

주요 토글(`full_demo.jl`): `num_robots`, `rvo_flag`, `dispersion_flag`, `tangent_bug_flag`,
`assignment_mode`.

---

## 5. 변경 사항(이 작업에서 추가한 것)
- `src/tangent_bug.jl` — 구조체/함수/기하 수식 한국어 인라인 주석 추가 (코드 무변경, 주석만).
- `src/potential_fields.jl` — 포텐셜 종류 수식, 반발/우선순위 스케일, gradient 합성 주석 추가.
- `src/rvo_interface.jl` — 시뮬레이터 파라미터, 속도/이웃거리 산식, pref velocity/α 주석 추가.
- 본 문서 신규 작성.

## 6. 후속 검토 후보 (선택)
- makespan 목적함수에 혼잡/충돌 비용을 **실제로 통합**하는 것이 가능/바람직한가
  (현재는 완전 분리; 충돌회피는 reactive).
- `sched.weights`를 1.0 외 값으로 활용하는 다중 프로젝트 우선순위 시나리오.
- α priority 정책이 makespan에 미치는 영향(통행권 양보 ↔ 처리량 trade-off).
