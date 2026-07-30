# 시뮬레이터 OOD 이벤트 *생성* 설계 (2026-06-23)

작성일: 2026-06-23. 이 문서는 respec layer의 **앞단** — "시뮬레이터가 OOD 이벤트를
**물리적으로 생성**하는 환경"을 어떻게 만들 것인가 — 의 설계/계획서다. 기존 docs는
이벤트가 이미 `push_ood!("문자열")` 로 주어진다고 *전제*하고 그 뒤(translate→verify→
re-solve→resume)를 다룬다. 여기서 다루는 것은 그 전제 자체를 만드는 일이다.

> 관계: 이 문서는 `autonomy_impl_workflow_2026-06-22.md`의 **Piece 2 (detection/
> injection)** 를 구체화·교정한다. 그 문서의 Piece 2는 injection을 "수동 `push_ood!`
> 문자열"로 두고 *detection*에 집중했지만, 사용자가 원하는 것은 시뮬레이터가 두 종류의
> OOD를 **실제 물리 상태로 발생**시키는 것이다. detection은 그 다음 단계다.

---

## 0. 두 OOD가 기존 layer와 맺는 관계 (가장 중요한 교정)

| OOD | 윗단(respec) 매핑 | 윗단 상태 | 아랫단(물리 생성) 상태 |
|---|---|---|---|
| **1-1 로봇 고장 → 백업 대체** | `ForbidAgent` → reassign | 존재하나 **reassign double-booking 버그로 완주 불가** (resume_fulloop_status_2026-06-24) | **없음** — eval은 known id로 함수 직접 호출만 |
| **1-2 출입금지 구역** | (신규 필요) | 기존 `ForbidWindow`는 **시간창×노드-작업 금지**이지 **공간 통행 금지가 아님** | **없음** — 항법 스택에 정적 장애물 주입 메커니즘 자체가 신규 |

**확정된 의미 (2026-06-23 사용자 결정):**
- **1-2 = 항법 no-go zone (공간 장애물).** 로봇이 그 구역을 물리적으로 통행 못함.
  → `active_staging_circles`에 `Ball2`로 주입, TangentBug/RVO가 회피. 재-routing/재-
  staging을 강제하는 진짜 공간 제약. **신규 DSL 제약 `ForbidZone` 필요** (기존
  ForbidWindow로는 표현 불가 — 그건 시간 제약).
- **1-1 = 방위별(동서남북) spare robot pool.** 시작 시 4개 방위 위치에 idle 예비 로봇
  풀을 둔다. 고장 발생 시 **고장 지점에서 가장 가까운 풀**의 예비 로봇 1대가 활성화되어
  고장 로봇을 대체한다.

---

## 1. 공통 인프라 — 물리 이벤트를 시뮬 도중 발생시키는 자리

### 1.1 주입 지점 (코드 근거)
시뮬 루프: `simulate!` (route_planning.jl:199) → 매 스텝 `step_environment!` →
`respec_step!(env)` (demo_utils.jl:96 부근, replan.jl:58). 현재 `respec_step!`은
`RESPEC_QUEUE`(문자열 큐)만 drain한다.

물리 OOD 생성기는 이 **앞**에 꽂힌다: 매 스텝(또는 스케줄된 시각에) env의 물리 상태를
변형하고 그에 대응하는 NL 문자열을 `push_ood!` 한다. 즉 생성기는 **(a) 물리 상태 변형
+ (b) NL 이벤트 enqueue** 두 가지를 한다. (b)가 기존 respec 파이프라인의 진입점이다.

### 1.2 신규 모듈: `ood_injection.jl` (src/respec/)
시나리오 스크립트가 시간/조건 기반으로 OOD를 트리거하는 스케줄러.

```julia
# 개념 스케치 (구현 시 정밀화)
mutable struct OODSchedule
    triggers::Vector{Tuple{Int, Function}}  # (발생 step, env -> NL string 생성기)
end
function ood_inject_step!(env, sched::OODSchedule, k::Int)
    for (step, gen!) in sched.triggers
        if k == step
            nl = gen!(env)        # ① 물리 상태 변형 + ② NL 문자열 반환
            push_ood!(nl)         # 기존 respec 파이프라인으로 흘려보냄
        end
    end
end
```

PlannerEnv 구조체(route_planning.jl:97, `@with_kw struct`, **불변**)는 건드리지
않는다 — 신규 상태(restriction zones, spare pools)는 기존 패턴대로 **module-level
Ref/Dict** 으로 둔다 (`RESPEC_ENABLED`, `RESPEC_HOLD`와 동일한 회피책).

---

## 2. OOD 1-2 — 출입금지 구역 (항법 no-go zone)

### 2.1 핵심 hook (코드 근거)
`active_staging_circles(env, exclude_ids)` (route_planning.jl:672) 가
TangentBug가 회피하는 **정적 원형 장애물 집합**을 만든다. `get_twist_cmd`
(route_planning.jl:754)가 이걸 받아 `query_policy_for_goal!`로 우회 waypoint를 낸다.

→ **restriction zone = 이 iterator에 추가되는 `Ball2`.** 한 줄로 전체 모션 스택
(TangentBug 우회 + 버퍼 inflation + RVO)이 그 구역을 자동 회피한다.

### 2.2 구현
1. **신규 zone 저장소** (module-level): `RESTRICTION_ZONES = Ref(Dict{Symbol,Ball2}())`
   (방위/난수 시드로 키잉). PlannerEnv 불변성 유지.
2. **`active_staging_circles` 확장**: 반환 iterator에 `RESTRICTION_ZONES[]`의 원들을
   concat. (staging 원과 동일 형식 `id => Ball2(2d center, r)` 이므로 다운스트림 무변경.)
   - 주의: zone은 `active_build_steps`와 무관하게 **항상 활성**이어야 하므로 exclude
     로직을 타지 않게 별도 합성한다.
3. **생성기** (`ood_injection.jl`): 빌드 영역 bounding box 안에서 난수로 중심·반경을
   뽑아 `Ball2` 생성 → `RESTRICTION_ZONES[]`에 등록 → NL 문자열 반환
   (예: `"A safety exclusion zone (center≈(x,y), radius r) is now active; robots
   must not enter it."`).
4. **신규 DSL 제약 `ForbidZone`** (spec_dsl.jl): 윗단(respec)이 이 공간 이벤트를
   받아 **무엇을** 해야 하는지. 두 가지 enactment 후보:
   - **(A) 순수 항법 제약** — zone은 항법 스택이 이미 회피하므로 스케줄 재-solve가
     불필요할 수도 있다. 단, zone이 어떤 assembly의 **staging area를 덮으면** 그
     부품을 거기서 조립/배달 불가 → 재-staging이 필요 → **공간 layout 재배치**가
     respec의 일. 이건 현재 MILP가 다루지 않는 차원(공간)이라 **신규 작업**.
   - **(B) zone↔node 매핑 후 작업 금지** — zone에 staging이 걸린 노드를 찾아
     `ForbidWindow`처럼 그 노드 작업을 금지. 기존 ood_eval의 "zone closure" 우회
     해석과 동일. 빠르지만 "통행 금지"의 본질(우회 항법)은 항법 스택이 이미 처리.

> **P-Zone 결정 (2026-06-23, 사용자 확정): (A) layout 재배치.** zone이 staging area를
> 덮어 빌드가 infeasible해지면 LLM이 `ForbidZone`으로 해석하고, **막힌 assembly를
> zone 밖으로 재배치**한다. 단 LLM은 좌표를 직접 고르지 않는다 — 기존 기하 planner의
> 불변식(비-overlap·ring-packing)을 재사용한다. 상세 구현은 **§7** 참조.

### 2.3 검증 (LLM-free fast loop)
`tools/dev_session.jl`에 `zone_test()`:
- `deepcopy(BASE_ENV)` → 경로상에 zone 하나 주입 → 몇 스텝 stepping → 해당 zone
  내부로 진입하는 에이전트가 없음을 assert (위치 샘플). zone 없을 때 대조군과 비교해
  우회로 길어짐(경로 변화) 확인. 초 단위, sim 전체/LLM 불필요.

---

## 3. OOD 1-1 — 로봇 고장 + 방위별 spare robot pool

### 3.1 현재와의 차이
기존 `fault_robot_and_reassign!` (reassign.jl)은 고장 로봇의 task를 **남은 기존
로봇들에게 재분배**한다 (spare 없음). 이 방식이 **double-booking 버그의 근원**:
이미 commit된 chain을 가진 healthy 로봇에 추가 work를 엮으면 geometry-miss orphan/
동시 분기 충돌이 난다 (resume_fulloop_status_2026-06-24).

**spare-pool 모델의 이점 (가설):** 새 예비 로봇은 **task chain이 비어 있다**. 고장
로봇의 chain을 통째로 그 spare에게 **id만 갈아끼우면** 동시 분기가 생기지 않는다 →
double-booking 버그를 **구조적으로 우회**할 가능성. (검증 필요 — 3.4의 done-gate.)

### 3.2 spare pool 구성 (코드 근거)
로봇 생성: full_demo.jl:291-298, 빌드영역 중앙 box에 `num_robots`대를 난수 배치.
- **신규**: 빌드영역 bounding box의 **동/서/남/북 4 위치**에 각 `n_spare`대의
  RobotNode를 추가 배치 (`add_robots_to_scene!` 재사용, 위치만 4 방위 클러스터로).
  spare 로봇은 시작 시 **어떤 task에도 할당되지 않음** (RobotStart만, free 상태로 대기).
- **신규 저장소** (module-level): `SPARE_POOLS = Ref(Dict{Symbol,Vector{RobotID}})()`
  — `:north/:east/:south/:west → 미사용 spare ids`. 활성화 시 pop.

### 3.3 고장 → 대체 워크플로
생성기(`ood_injection.jl`)가 step K에서:
1. **물리 고장 주입**: 대상 로봇 `r`의 명령속도를 영구 0으로 고정(혹은 장애물화) →
   `step_environment!`에서 더 이상 구동 안 됨. (faulted 로봇이 그 자리에 **정적
   장애물로 남는지**(2.1의 zone처럼 Ball2로 등록) vs 사라지는지 — 추천: **장애물로
   남김** = 더 현실적, 다른 로봇이 우회.)
2. **가장 가까운 풀 선택**: `r`의 현재 위치에서 4 방위 풀 중심까지 거리 최소 풀 선택,
   그 풀에서 spare `s` 하나 pop.
3. **NL 이벤트 enqueue**: `push_ood!("Robot r has malfunctioned; replace it with the
   nearest spare s.")` — 단, **현재 respec은 `ForbidAgent`만 처리**(replan.jl:107
   `_is_robot_fault`). spare 대체는 신규 액션이므로 둘 중:
   - **(A) 최소 변경**: NL은 그대로 robot fault → 기존 reassign 경로. spare를 "재분배
     대상 로봇 풀"에 추가만 하고 MILP가 자유 재배정. "백업이 가장 가까운 데서 온다"는
     **비용함수(거리)로 자연 유도** (greedy/MILP가 이미 거리비용 사용,
     simulator_problem_scope_and_motion_stack 2.3).
   - **(B) 명시적 대체**: 신규 `replace_robot!(env, faulted, spare)` — 고장 로봇의
     **전체 chain을 spare id로 re-stamp** (3.1의 우회). reassign보다 단순(재최적화
     없이 id 교체)하고 double-booking을 피함.

> **설계 결정 필요 (P-Spare):** (A) 기존 reassign 재사용(+spare를 풀에 추가) vs
> (B) 신규 1:1 chain 인계. **MVP 추천 = (B)를 먼저 시도** — double-booking 버그를
> 우회할 수 있고 "backup replaces"의 의미에 정확히 부합. (A)는 reassign 버그가
> 고쳐지면 더 일반적(부하 재분산)이라 후속.

### 3.4 검증 (LLM-free fast loop)
`tools/dev_session.jl`에 `spare_replace_test()`:
- `deepcopy(BASE_ENV)`(mid-build) → 로봇 `r` 고장 주입 → 가장 가까운 풀에서 spare
  선택 → `replace_robot!`(B안) → `reset_cache_resume!` → 완주까지 stepping.
- assert: `closed_set` monotone(never regress), 완주(`project_complete`), 고장
  로봇이 더 이상 구동 안 됨(`rvo_get_agent_idx` 에러 없음), spare가 정확히 그
  chain을 수행. **이것이 reassign double-booking을 우회하는지가 핵심 done-gate.**

---

## 4. 우선순위 (사용자 요청: "OOD 생성 환경부터")

빌드 순서 — 각 단계는 LLM 없이 fast loop로 검증:

1. **공통 인프라** — `ood_injection.jl`(스케줄러) + module-level 저장소.
   `simulate!` 루프에 `ood_inject_step!` 1줄 추가. (PlannerEnv 무변경.)
2. **1-2 항법 zone 생성** — `RESTRICTION_ZONES` + `active_staging_circles` 확장 +
   난수 zone 생성기. `zone_test()` green (우회 확인). **여기까지가 "출입금지 구역이
   생성되는 시뮬레이터" 자체.** respec 액션(ForbidZone DSL)은 그 다음.
3. **1-1 spare pool 생성** — 4 방위 spare 배치 + `SPARE_POOLS` + 고장 주입 +
   `replace_robot!`(B안). `spare_replace_test()` green (완주). 이게 green이면
   reassign double-booking을 우회한 셈.
4. **respec 연결** — 2의 NL→`ForbidZone` 신규 DSL(translate+verify+compile),
   3의 NL→대체 액션. (기존 4/4 DSL 파이프라인에 1종 추가.)
5. (후속) detection 자동화(autonomy Piece 2), 시각화(Piece 3).

**1·2·3이 사용자가 1순위로 원한 "OOD 이벤트가 생성되는 시뮬레이터 환경"이다.**
4부터가 "LLM이 그걸 해석해 TAMP를 재설계"하는 윗단 연결.

---

## 5. 미해결/결정 대기

- **P-Zone** (2.2): zone respec 액션을 layout 재배치(A)까지 vs 영향노드 작업금지(B).
  추천 = 항법회피 필수 + respec은 (B) MVP, (A)는 후속 연구.
- **P-Spare** (3.3): 고장 대체를 신규 1:1 chain 인계(B) vs 기존 reassign 재사용(A).
  추천 = (B) 먼저 (double-booking 우회 + 의미 부합).
- **reassign double-booking 버그**: spare-pool (B안)이 우회하면 1-1 완주의 블로커가
  사라진다. 단 일반 부하재분산(A안/기존 reassign)은 여전히 버그 보유 — 별도 트랙으로
  resume_fulloop_status_2026-06-24의 orphan 문제를 계속 추적.
- **신규 DSL `ForbidZone`**: 4 kinds(Precede/Deadline/ForbidWindow/ForbidAgent)에
  5번째 추가. spec_dsl.jl + compiler.jl + schema.py/propose.py(프롬프트) + verifier.

## 7. ForbidZone re-staging 구현 plan (P-Zone = A)

### 7.1 핵심 단순화 — ring 재packing 불필요, 강체 평행이동
기하 조사(Explore) 결론: 부품은 assembly 원점 기준 **상대 배치**라, assembly의
`start_config`(AssemblyComplete 노드의 TransformNode)를 **강체 평행이동(rigid
translate)** 하면 자손(부품 staging/배달 goal, deposit config)이 transform 트리
parent-child 체인으로 **전부 같이 이동**한다. 따라서 문제가 "ring 재packing"이 아니라
**"반경 R인 assembly 원의 새 중심을 zone·타 staging과 안 겹치게 찾기"** (2D 원배치)로
축소된다. runtime goal의 source of truth = 스케줄 노드 `goal_config` (scene_tree 아님,
route_planning.jl:746) → 강체 이동이 그대로 반영됨.

- **MILP 재solve 불필요**: 할당(Xa)·시간 구조 불변, 기하만 변경. `ForbidAgent`(재배정)
  와 달리 solver를 안 부른다. 이동 후 `reset_cache_resume!`(이미 구현)로 바로 이어감.
- **mutation API**: `set_desired_global_transform!(start_config(ac_node), Translation(Δ)∘gt)`
  (hierarchical_geom_essentials.jl:301, parent 존중).

### 7.2 LLM-free 코어 (reassign.jl 패턴 그대로 — 먼저 구현·검증)
신규 `src/respec/restage_zone.jl`:
- **`find_clear_staging_center(env, assembly_id, R; zone_keys, margin)`** — old center
  c0 주위 동심 ring(증가 반경×24각)을 훑어 **모든 RESTRICTION_ZONES + 다른 모든
  staging circle과 (반경합+margin) 이상** 떨어진 첫 중심을 반환(거리 최소). 없으면
  `nothing`(infeasible). ring solver의 정신(원을 겹침 없이 배치)을 1-원 버전으로 재사용.
- **`restage_assembly!(env, assembly_id; zone_keys, resume=true)`** — (1) AssemblyComplete
  스케줄 노드 조회, (2) **safety: 이미 closed면 거부**(아직 안 지어진 것만 이동 — 사용자
  합의 MVP), (3) `find_clear_staging_center`로 c1, (4) Δ=c1−c0 강체 평행이동,
  (5) `env.staging_circles[id]=Ball2(c1,R)` 갱신, (6) `reset_cache_resume!`. 상태 NamedTuple
  반환(`:restaged`/`:infeasible`/`:already_built`/`:no_node`). LLM-free 직접 진입점
  (= `fault_robot_and_reassign!` 대응).
- **DSL**: `ForbidZone(assembly::AbstractID, zone::Symbol)` (spec_dsl.jl). **MILP 제약
  아님** → generic compile 경로 안 탐. `ForbidAgent`처럼 `maybe_respecify!`에서 전용
  dispatch(다음 단계).

### 7.3 검증 (dev_session.jl `restage_test()`)
mid-build env deepcopy → 아직 안 지어진 assembly의 staging을 덮는 zone 주입 →
`restage_assembly!` → 이동 후 (a) 부품 goal들이 Δ만큼 평행이동, (b) 새 위치가 zone·타
staging과 무overlap, (c) **`reset_cache_resume!` 후 완주(`closed_set` monotone)** assert.
(c)가 핵심 done-gate — 강체 이동이 빌드 일관성을 깨지 않음을 증명.

### 7.4 다음 단계 (LLM 레이어 — 코어 검증 후)
- **detector**: `respec_step!` 앞에서 `_zone_clear_of_goals` 스캔 → zone이 덮은
  assembly 식별 → NL 이벤트 emit(어떤 assembly가 막혔는지 포함).
- **LLM 번역**: schema.py/propose.py에 `ForbidZone` 분기 + assembly grounding(기존
  node label 재사용). verifier: 기하 feasibility(=`find_clear_staging_center` 존재)
  게이트. `maybe_respecify!`에 `_is_zone_respec` dispatch → `restage_assembly!`.
- **staleness 보정(후속)**: OpenBuildStep.staging_circle(active_staging_circles가 읽는
  build-step 원)과 assembly_complete.inner/outer circle이 강체 이동을 따라오는지 확인,
  안 따라오면 갱신. 이미 배달된 부품 relocation은 범위 밖(MVP는 미시작 assembly만).

## 6. 진행 로그
- **2026-06-23** — 설계 합의. 1-2=항법 no-go zone, 1-1=방위별 spare pool로 확정.
  코드 hook 식별: `active_staging_circles`(zone), full_demo.jl:291-298 +
  `add_robots_to_scene!`(spare pool), `respec_step!` 앞단(주입 지점). 본 문서 작성.
  autonomy_impl_workflow Piece 2를 이 문서로 교정(injection=물리 생성). 다음:
  공통 인프라 + `zone_test()`.
- **2026-06-23** — **공통 인프라 + OOD 1-2(zone 생성) 구현 완료 & 검증.** 신규
  `src/respec/ood_injection.jl`:
  - **zone 상태**: module-level `RESTRICTION_ZONES = Ref(Dict{Symbol,Ball2})`
    (PlannerEnv 불변 유지) + `add_restriction_zone!` / `clear_restriction_zones!` /
    `remove_restriction_zone!` / `active_restriction_zones`(`key=>2D Ball2` iterator,
    staging 원과 동형).
  - **생성기**: `random_restriction_zone!`(activity bbox 안 난수 배치, seed 재현가능)
    + `activity_bbox`(active agent 위치 ∪ staging circle 범위) + `restriction_zone_event`(NL).
  - **공통 스케줄러**: `OODTrigger` / `OOD_SCHEDULE` / `schedule_ood!` /
    `ood_inject_step!`(due trigger 1회 발화 → 물리 변형 + NL `push_ood!`; 빈 스케줄이면
    free no-op).
  - **항법 연결**: `active_staging_circles`(route_planning.jl)를 `Iterators.flatten`로
    zone iterator를 append하게 1줄 확장 → TangentBug/`get_closest_interfering_circle`가
    zone을 정적 장애물로 동일 취급. (lazy·re-iterable 유지 — get_twist_cmd가 2회 소비.)
  - **루프 주입**: `simulate!`(route_planning.jl & demo_utils.jl 둘 다) `step_environment!`
    앞에 `ood_inject_step!(env, k)` 1줄. demo_utils엔 respec seam이 이미 있고,
    route_planning simulate!엔 `respec_step!`도 함께 추가(둘 다 비활성 시 no-op).
  - **export** 추가(ConstructionBots.jl) + `tools/dev_session.jl`에 `zone_test()`.
  - **검증 (julia +lts, LLM-free)**: 패키지 clean load. zone geometry 6/6 PASS —
    control(zone없음→무간섭) / shape(center·radius) / plumbing(obstacle set 포함) /
    flatten(active_staging_circles 합성) / detour(경로상 zone이 실제 소비자
    `get_closest_interfering_circle`에 의해 interfering으로 flag) / no-false-pos(경로
    밖 zone은 무시). 스케줄러 4/4 PASS — pre/fire-once/no-double-fire/empty-noop.
  - **주의**: fast BASE_ENV는 `tangent_bug_flag=false`라 full 모션스택 회피는 안 돎 →
    `zone_test()`는 실제 소비자(`get_closest_interfering_circle`)를 직접 호출해 검증
    (full 우회 궤적은 tangent_bug 켠 1회 렌더런에서 최종 확인). route_planning.jl:587
    `circle_avoidance_policy`는 line 600 `LazySets.(x,…)` 오타로 **dead code** — 실제
    경로는 tangent_bug.jl의 `get_closest_interfering_circle`/`query_policy_for_goal!`.
  - **다음**: (a) OOD 1-1 spare pool(§3) — `SPARE_POOLS` + 4방위 배치 +
    `replace_robot!` + `spare_replace_test()`; (b) zone의 respec 액션 = 신규 DSL
    `ForbidZone`(P-Zone 결정 후); (c) tangent_bug 켠 full-render 우회 확인.
- **2026-06-23 (b)** — **full-render 1회 확인 → placement 결함 발견·수정.**
  `tools/run_zone_demo.jl`(tangent_bug+rvo+render, step150 주입)로 zone(빨간 disc)이
  렌더되는 것은 확인. 그러나 **우회 효과 없음**: 옛 `random_restriction_zone!`이
  `activity_bbox`(활동영역 **사각 bbox**) 안 **균일 난수**로 중심을 뽑아, 트래픽이
  희소한 사각형 빈 구석(북쪽)에 떨어져 어떤 로봇 경로도 교차하지 않음 + 반경도
  2~4·robot_r로 작음. → "난수 자체는 동작하나 **효과를 보장 못 하는 배치 전략**"이
  진단. **수정**: `random_restriction_zone!`을 `placement` 전략으로 재작성 —
  - `:on_path`(기본): 활성 `EntityGo`의 (pos→goal) 선분 위(frac 0.4~0.6)에 배치,
    반경을 `min(frac,1-frac)·seglen − margin`로 clamp해 **양 끝점(특히 goal)을 zone
    밖**에 유지(우회는 강제, deadlock은 회피). 최소 1대가 반드시 우회.
  - `:traffic_centroid`(fallback): 활성 로봇 centroid + spread 비례 반경 + jitter.
  - fallback 체인 `on_path → centroid → bbox-center`. `_active_travel_segments`/
    `_active_centroid` 헬퍼 추가. **검증(env-free)**: 20-unit 경로 중점 zone(r=5.0,
    bloat=5.5) → start·goal 모두 zone 밖 + interfering flag = ON-PATH GEOMETRY OK.
  - 주의(개념 교정): no-go zone은 **정적이 맞음**(출입금지 구역이 이동하면 비현실적).
    사용자가 본 "위치 불변"은 버그 아님; 진짜 문제는 배치였음. 시간가변 시나리오가
    필요하면 `schedule_ood!`로 여러 step에 zone을 여러 개 예약(각자 random)하면 됨.
  - **재실행**: `julia +lts --project=. tools/run_zone_demo.jl` (코드가 새 배치를
    자동 사용 — seed=7도 이제 트래픽 위에 놓임).
- **2026-06-23 (c)** — **on_path 재실행 → deadlock(빌드 미완) 발견·수정.** 새 on_path
  배치로 재실행하니 `No progress for 10000 iterations → PROJECT INCOMPLETE`(closed=174).
  **원인(중요): reassignment 무관** — 이 데모엔 OOD 1-1/RESPEC이 없음. **정적 no-go
  zone이 빌드가 필요로 하는 목표/스테이징 영역을 영구히 막아 plan이 infeasible**해진
  것. on_path는 주입 시점 그 로봇의 goal만 zone 밖에 뒀을 뿐, 나중에 다른 로봇이
  도달해야 할 목표가 zone에 걸리면 stall. + auto-radius(0.25·seglen)가 이 스케일
  (robot_radius≈0.14)에선 너무 커서 스테이징을 삼킴. (JLD2 "store function by name"
  경고는 INCOMPLETE 시 변수덤프의 익명함수 직렬화 경고 — **무해**.)
  **이것이 OOD 1-2의 본질**: 정적 출입금지 구역은 재계획(re-staging) 없이는 빌드를
  infeasible하게 만들 수 있음 → ④ `ForbidZone`(막힌 assembly 재-staging)의 동기.
  **데모용 수정**(deadlock 없이 우회만 보이게): `random_restriction_zone!`에 (1) 반경
  `≤ 3·robot_radius` cap(`max_radius`), (2) `_zone_clear_of_goals`로 **모든 staging
  circle과 겹치지 않는 자리**를 retry(`attempts`)로 탐색, 못 찾으면 best+`@warn`.
  **검증(env-free)**: 패키지 clean load; 가드 = 목표영역 위 zone reject, 먼 zone accept
  = GUARD OK. **주의**: 이 가드는 "데모에서 빌드가 안 멈추게" 하는 우회책일 뿐, 진짜
  복구(infeasible 감지→재-staging)는 ④의 respec 작업.
- **2026-06-23 (d)** — **④ ForbidZone re-staging: P-Zone=A 확정 + LLM-free 코어 구현.**
  Explore로 staging/transform 머신 매핑 → 핵심 단순화 발견(§7.1): 부품은 assembly 원점
  상대배치라 `start_config` 강체 평행이동만으로 staging subtree 전체가 일관되게 이동,
  **ring 재packing·MILP 재solve 불필요**. 구현:
  - **DSL** `ForbidZone(assembly::AbstractID, zone::Symbol)` (spec_dsl.jl) — MILP 제약
    아님 명시; `ForbidAgent`처럼 전용 dispatch 예정.
  - **신규 `src/respec/restage_zone.jl`**: `find_clear_staging_center`(c0 주위 동심 ring
    스캔으로 zone+타 staging 무overlap 최근접 중심; 없으면 nothing=infeasible) +
    `restage_assembly!`(AC노드 조회 → closed면 거부 → 중심탐색 → 강체이동
    `set_desired_global_transform!` → staging_circles 갱신 → `reset_cache_resume!`;
    status NamedTuple). include+export 추가.
  - **fast loop**: dev_session.jl `restage_test()` (미시작 assembly staging에 zone 주입
    → restage → 완주·monotone·zone_clear assert).
  - **검증**: 패키지 clean load + `find_clear_staging_center` env-free PASS(중심이 zone
    3.0≥2.75 & sibling 2.83≥2.25 이격, 예산부족 시 nothing). **restage_assembly! 전체
    (강체이동+resume 완주)는 BASE_ENV 빌드 후 `restage_test()`로 검증 중**(done-gate).
  - **다음(LLM 레이어)**: detector(_zone_clear_of_goals로 막힌 assembly 식별→NL emit) +
    LLM 번역(schema/propose에 ForbidZone 분기, assembly grounding) + verifier 기하 게이트
    + `maybe_respecify!`에 `_is_zone_respec` dispatch.
- **2026-06-23 (e)** — **restage 코어 end-to-end 검증 → STALL 발견(미해결, 핸드오프).**
  `tools/restage_validate.jl`(Revise-free standalone)로 실제 env 검증: control(재배치
  없는 resume)은 46→**279 complete**, 그러나 restage(AssemblyID3 [-0,-0.58]→[7.84,-0.58],
  zone_clear=true)는 46→**108 STALLED**(20k iters 무진행, monotone). **강체이동만으로는
  빌드 일관성 불충분** — start_config 자손 goal은 따라오나 (b)build-step staging 원(항법
  장애물)/(c)transport·deposit config가 안 따라온 것으로 추정. 중심탐색의 nesting 버그
  (부모⊃자식 원을 충돌로 오인)는 수정함(originally-separate만 회피). zone=R(staging 전체)
  로 잡아 ~2R 큰 이동 강제된 것도 한 요인 → goal-기반 기준으로 완화 가능.
  **상태·재개절차는 `restage_zone_status_2026-06-23.md`** (stall frontier 덤프 진단 →
  부정합 transform 보정 → done-gate). 사용자 요청으로 진단 실행 중단(빌드 중이라 출력
  없음). **다음 세션 진입점 = 그 문서 STEP 1.**
</content>
</invoke>
