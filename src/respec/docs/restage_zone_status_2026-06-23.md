# ForbidZone re-staging — 진행상황 & 핸드오프 (2026-06-23)

OOD 1-2(출입금지 구역)의 ④단계 = **LLM이 `ForbidZone`으로 해석 → 막힌 assembly를
기존 ring planner 정신으로 zone 밖에 재배치**. 이 문서는 구현 중단 시점의 상태와
**재개 방법**을 담는다. 상위 설계는 `simulator_ood_generation_design_2026-06-23.md`
§7 참조. 이 문서는 그 §7의 진행상황 스냅샷이다.

---

## TL;DR (현재 상태)

- ✅ **LLM-free 기하 코어 구현 완료** (`src/respec/restage_zone.jl`): `ForbidZone` DSL +
  `find_clear_staging_center`(zone·sibling 무overlap 중심 탐색) + `restage_assembly!`
  (강체 평행이동 + `reset_cache_resume!`). 패키지 clean load.
- ✅ **기하 단위검증 통과**(env-free): 중심 탐색이 zone·sibling을 정확히 회피, 예산
  부족 시 `nothing`(infeasible).
- ✅ **재배치 메커니즘 동작 확인**: 실제 env에서 AssemblyID(3)을 강체이동(zone_clear=
  true), 빌드가 crash 없이 resume되어 진행(46→108, monotone).
- ❌ **미해결 블로커**: 재배치 후 빌드가 **108/289에서 STALL**(20k iters 무진행).
  control(재배치 없는 resume)은 279로 완주 → **강체이동이 빌드 체인 일관성을 깬다**는
  뜻. "start_config만 옮기면 전부 따라온다"는 가설이 **불완전**함이 입증됨.
- ⏸ **중단 시점**: stall의 원인을 찾기 위해 **stuck active frontier를 덤프하는 진단
  실행을 돌리던 중 사용자 요청으로 중단**(env 빌드 중이라 진단 출력은 없음).

---

## 무엇이 done이고 무엇이 깨졌나

### Done & 검증됨
| 항목 | 파일 | 검증 |
|---|---|---|
| 공통 인프라(OOD 스케줄러) + zone 생성 + TangentBug 회피 | `src/respec/ood_injection.jl`, `route_planning.jl active_staging_circles` | `zone_test()` 6/6 + 스케줄러 4/4 (이전 세션) |
| zone 마커(빨간 disc) 렌더 | `ood_injection.jl draw_restriction_zones!`, `render_tools.jl` | MeshCat 그리기 OK |
| `random_restriction_zone!` on_path 배치 + goal-clear 가드 | `ood_injection.jl` | env-free GUARD OK |
| `ForbidZone(assembly,zone)` DSL | `src/respec/spec_dsl.jl` | load OK |
| `find_clear_staging_center` (nesting-aware) | `src/respec/restage_zone.jl` | env-free FIND-CENTER OK |
| `restage_assembly!` 강체이동 + resume | `src/respec/restage_zone.jl` | **부분** — 이동·resume은 되나 완주 X (아래) |

### 깨진 것 — restage 후 빌드 STALL
- **증거**(`tools/restage_validate.jl`, tractor 289노드, fault-free):
  - control_resume: closed 46 →(end) **279** | status=**complete** monotone=true  ✅
  - restage(AssemblyID 3, [-0.0,-0.58]→[7.84,-0.58], zone_clear=true):
    closed 46 →(end) **108/289** | status=**stalled** monotone=true  ❌
- **핵심**: stall(=20k iters 무진행)이지 slow 아님. 재배치 자체(중심탐색·강체이동)는
  맞으나, 이동 후 빌드가 108에서 더는 진행 못 함.

---

## 왜 stall 하나 — 가설 (재개 시 검증할 것)

§7.1의 "부품은 assembly 원점 상대배치라 start_config 강체이동이면 자손 goal이 전부
따라온다"는 **부분적으로만 맞다**. 다음 중 하나(들)가 따라오지 않아 stall로 추정:

1. **OpenBuildStep.staging_circle (TangentBug 장애물)이 강체이동을 안 따라옴.**
   `active_staging_circles`가 읽는 build-step 원이 절대좌표 캐시면, 부품 goal은 새
   위치(7.84)로 갔는데 장애물 원은 옛 위치에 남아 항법 부정합 → 로봇이 새 staging에
   도달/형성 못 함. **1순위 의심.**
2. **이동한 sub-assembly의 운반(Transport)·deposit 체인 부정합.** AssemblyID(3)을 새
   위치에서 짓고 나면 부모로 운반해야 하는데, FormTransportUnit/TransportUnitGo/
   DepositCargo의 cargo_start/loaded/deployed config가 옛 staging 기준이면 픽업·운반·
   배치가 어긋남.
3. **7.84 = 너무 큰 이동.** zone 반경 = assembly의 staging 반경 R로 잡아 "원 전체가
   zone을 벗어나려면 ~2R 이동"이 강제됨. 큰 이동이 위 1·2의 부정합을 키웠을 수 있음.
   → **goal-기반 기준**(원 전체가 아니라 부품 delivery goal만 zone 밖)으로 바꾸면
   이동량이 작아져 stall이 사라질 가능성. (현재는 circle-기반 = 과보수.)

---

## 재개 절차 (다음 세션)

### STEP 1 — stall 원인 핀포인트 (중단했던 진단)
`tools/restage_validate.jl`에 이미 **stall 시 active frontier 덤프** 코드가 있다
(EntityGo는 pos/goal/거리까지). 그냥 실행:
```bash
cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
julia +lts --project=. tools/restage_validate.jl
```
출력의 `--- STALL @ closed=... : active frontier ---` 블록을 본다:
- EntityGo가 goal에서 **멀리 떨어져 멈춰**(d 큼) 있으면 → 항법 도달 실패(가설 1, zone
  장애물/위치 부정합).
- FormTransportUnit/DepositCargo가 멈춰 있으면 → 운반/배치 체인 부정합(가설 2).
- 어떤 노드가 stuck인지가 곧 어떤 transform이 안 따라왔는지를 가리킨다.

### STEP 2 — 부정합 transform 보정
STEP 1 결과에 따라:
- 가설 1이면: `restage_assembly!`에서 강체이동 시 그 assembly의 **OpenBuildStep
  staging_circle(들)도 같은 Δ로 이동**시키거나, 애초에 transform-frame 부착이면 왜
  안 따라오는지 확인. (active_staging_circles가 읽는 소스를 추적: route_planning.jl:674,
  `n.staging_circle` = OpenBuildStep의 cached geom.)
- 가설 2면: 이동한 assembly의 transport task config들을 새 위치 기준으로 재유도
  (construction_schedule.jl `calibrate_transport_tasks!` / `align_construction_predicates!`
  근방 로직 재사용 검토).

### STEP 3 — (가설 3 완화) goal-기반 이동으로 전환 — 선택
`find_clear_staging_center`의 기준을 "staging 원 전체가 zone 밖"에서 "부품 delivery
goal들 + 빌드위치가 zone 밖"으로 바꾸면 이동량이 작아진다. 작은 이동이 stall을
없애는지 먼저 싸게 확인하려면, 테스트 zone을 **작게**(예: `4*default_robot_radius()`)
주고 **작은 sub-assembly**(staging 반경 최소)를 골라 재실행. 작은 이동도 stall이면
가설 1·2가 진짜 원인(이동량 무관).

### STEP 4 — done-gate
`restage_validate.jl`의 restage_check가 `status=complete monotone=true zone_clear=true`
= **PASS**가 되면 LLM-free 코어 완성. 그 다음에야 LLM 레이어로 진행.

### STEP 5 — LLM 레이어 (코어 PASS 후에만)
- detector: `respec_step!` 앞에서 `_zone_clear_of_goals`(ood_injection.jl)로 zone이
  덮은 assembly 식별 → NL 이벤트 emit.
- LLM 번역: `llm_service/schema.py`·`propose.py`에 `ForbidZone` 분기 + assembly
  grounding(기존 node label 재사용). verifier: 기하 feasibility(=find_clear_staging_center
  존재) 게이트. `replan.jl maybe_respecify!`에 `_is_zone_respec` dispatch →
  `restage_assembly!`.

---

## 이번 세션에 만지/추가한 파일

- `src/respec/spec_dsl.jl` — `ForbidZone(assembly::AbstractID, zone::Symbol)` 추가.
- `src/respec/restage_zone.jl` — **신규**. `find_clear_staging_center`,
  `restage_assembly!`, `_assembly_complete_node`.
- `src/respec/respec.jl` — `include("restage_zone.jl")`.
- `src/ConstructionBots.jl` — export `ForbidZone, restage_assembly!,
  find_clear_staging_center` (그리고 앞서 추가한 zone/스케줄러/마커 export).
- `tools/dev_session.jl` — `restage_test()` 추가(Revise 세션용).
- `tools/restage_validate.jl` — **신규**. Revise 없는 standalone 검증 드라이버
  (control_resume + restage_check + **stall 시 frontier 덤프**). 이게 재개의 주력 도구.
- `src/respec/docs/simulator_ood_generation_design_2026-06-23.md` — §2 P-Zone 결정(A),
  §7 구현 plan, §6 진행 로그.

## 재현 커맨드 (요약)
```bash
cd C:\Users\chahj\PythonCodes\venv\ConstructionBots.jl
# 전체 검증(빌드 ~수분 + 실행): control 완주 + restage stall 진단
julia +lts --project=. tools/restage_validate.jl
# 패키지 로드만 확인
julia +lts --project=. -e 'using ConstructionBots; println("OK")'
```
주의:
- **반드시 `julia +lts`** (1.10). 1.12에서 Pkg.add 시 빌드 깨짐(메모리 참조).
- `dev_session.jl`은 **Revise 필요**(전역 env). `--project=.` 단독 실행 땐 Revise가
  없어 `tools/restage_validate.jl`(Revise-free)을 쓴다.
- `restage_validate.jl`이 매 실행마다 env를 새로 빌드(~수분). 반복 디버깅은 dev_session
  + Revise가 빠르나 Revise 설치 필요.

## 핵심 교훈 (재개 시 기억)
강체 평행이동만으로는 **부족**하다. 재배치는 (a) 부품 delivery goal(자동 따라옴) 외에
(b) **build-step staging 원(항법 장애물)** 과 (c) **transport/deposit config**까지
일관되게 옮겨야 한다. STEP 1 덤프가 (b)냐 (c)냐를 가른다.

---

## STEP 1 실행 완료 — 진단 확정 (2026-06-24)

`tools/restage_validate.jl`을 실행해 stall frontier를 덤프했다. **가설 1·2 모두 빗나갔고
진짜 원인이 확정됐다.**

### 증거 (restage AssemblyID(3), Δ=[7.84, 0.0], closed 46→108 STALL)
stall난 frontier는 전부 `RobotGo`이고 **모두 goal에 d=0.0으로 정상 도착**해 있다. 막힌 건
그 successor `FormTransportUnit`이 "OFF-position robots"를 기다리는 것:
```
cargo ObjectID(15) pos=[-2.3, 0.34]  tu@[-2.3, 0.34]      ← 화물·운반유닛은 옛 위치 그대로
RobotGo(40) goal=[5.54, 0.29]  d2tu=7.84                  ← 로봇 목표만 +7.84(=Δ) 이동
```
모든 stuck 로봇에서 (robot goal − cargo/tu) 오프셋이 **7.6~8.0 ≈ Δx=7.84**로 일관.

### 확정된 근본 원인
- **가설 1(staging 원이 항법장애물로 안 따라옴) = 틀림.** 로봇은 목표에 d=0.0으로 도착함.
  항법/장애물 문제가 아님.
- **가설 2(transport/deposit 부정합) = 방향만 맞음.** 깨진 건 deposit이 아니라 **pickup
  (FormTransportUnit 랑데부) 쪽**.
- **진짜 원인:** `set_desired_global_transform!(start_config(ac), …)` 강체이동이 transform
  트리에서 **화물 pickup을 담당하는 RobotGo goal까지 Δ 이동**시켰는데, 화물 ObjectNode는
  별도 grid 위치(다른 transform parent)라 안 움직임 → 로봇은 "배달될 새 위치"로 가서
  화물을 기다리고, 화물은 옛 위치에 있어 FormTransportUnit이 영원히 성립 못 함 → deadlock.
  강체이동이 **움직여야 할 것(최종 build/deposit goal) vs 움직이면 안 되는 것(grid pickup
  랑데부)**을 구분하지 못함.

### 다음 — 수정 방향 (STEP 2 재정의)
빌더는 transport task config를 `calibrate_transport_tasks!`(construction_schedule.jl,
place_objects 단계에서 호출)로 assembly 기하에서 유도한다. **가장 정합적 수정 = restage
강체이동 직후 그 assembly 부품들의 transport task를 재유도**(pickup은 grid 고정, deposit만
새 위치). 단 코드 진입 전 **RobotGo(40).goal_config가 정말 AssemblyComplete(3) start_config의
자손인지 빠른 probe로 확인**(캐시 덕에 수 초) → 수정 빗나감 방지.

### 속도 개선 (이번 세션)
`tools/restage_validate.jl`에 **BASE_ENV Serialization 캐시** 추가
(`tempdir()/cb_base_env_p4_v1.jls`). 첫 실행만 빌드(~12분), 이후 로드 수 초. PlannerEnv는
순수 Julia(rvo_flag=false라 PyObject 없음)라 stdlib Serialization으로 안전. 빌드 파라미터
바꾸면 `CACHE_VERSION` bump 또는 파일 삭제. 반복 디버깅이 이제 빠름.

> ⚠️ **캐시 깨짐(2026-06-25 확인):** 위 "PyObject 없어 안전" 가정은 **틀렸다**. RVO
> agent 인덱스 맵이 **모듈 전역**(`rvo_global_id_map()`, src/rvo_interface.jl)이라 PlannerEnv
> 직렬화에 안 담긴다. `rvo_flag=false` 여도 `step_environment!`(route_planning.jl:304-324)가
> 이 전역 맵을 순회·인덱싱하므로, 캐시를 **로드한** 프로세스(전역 맵 비어 있음)는
> `rvo_get_agent_idx` 에서 `BoundsError([-1])` 로 죽는다. 캐시를 **만든** 프로세스는 빌드 때
> 채워져 통과 → 그래서 첫 세션엔 안 보였다. **우회: 매 실행 전 `.jls` 삭제(=항상 fresh
> 빌드).** 캐시 유지하려면 `rvo_global_id_map()`/`rvo_global_sim`도 같이 저장·복원하거나
> 로드 후 RVO 재초기화 필요(미구현).

---

## ✅ 해결 — restage 후 빌드 완주 PASS (2026-06-25)

STEP 1 진단(랑데부 deadlock)을 근본 원인까지 추적해 수정, **restage_check PASS**.
```
control_resume: closed 46 ->(end) 279 | status=complete monotone=true
restage_check : closed 46 ->(end) 279/289 | status=complete monotone=true zone_clear=true -> PASS
```

### 근본 원인 (확정)
씬(scene) 물리 노드는 sim 시작 때 `set_scene_tree_to_initial_condition!`
(construction_schedule.jl:1462-1469)가 `global_transform(start_config(n))`를 **스냅샷 복사**한
뒤 **독립**이다. `restage_assembly!`의 강체이동은 **스케줄 transform 트리**(start_config(ac)의
자손: ObjectStart.config → FormTransportUnit.config → delivery/lift goal)만 Δ 옮길 뿐,
대응하는 **씬 노드(조립체 본체·부품 object·운반유닛 tu)는 안 따라온다**. 로봇 RobotGo goal은
스케줄 자손이라 Δ 이동 → 로봇/화물/tu/assembly-기준이 정확히 Δ 어긋나 (a)FormTransportUnit
랑데부 불성립 또는 (b)최종 capture 실패(`has_edge` assert)로 정지. (STEP 1 가설 1·2 모두
빗나갔고, 진짜 원인은 **스케줄↔씬 좌표 desync**였다.)

### 수정 (`restage_zone.jl`, 강체이동 직후)
열거가 까다로워(중첩·다단계 빌드스텝) **드리프트 직접 감지**로 처리:
- 이동 직후 **free(루트=아직 안 집힘/안 놓임)** 씬 노드 중, 자기 스케줄 `start_config`에서
  `tol(=robot radius)` 이상 벌어진 것만 그 위치로 스냅(`set_desired_global_transform!`).
- 대상: 모든 `ObjectStart`/`AssemblyComplete` 의 **개체 본체 + 그 운반유닛**(존재 시).
  **로봇은 제외**(제어가 goal 로 몰고 감 — RobotStart 안 건드림). 이동에 안 휩쓸린 다른
  assembly 의 진행 중 노드는 드리프트 0 이라 자동 제외.

### 디버깅 과정 (한 겹씩)
108 stall(부품 미이동) → object+tu resync: 103 assert(assembly 본체 미이동) → +본체 resync:
121 stall(`assembly_components`가 중첩 부품 누락) → +드리프트 enum: 227 stall(하위 조립체의
운반유닛 미이동) → +assembly TU resync: **279 PASS**.

### 검증 도구 보강 (`tools/restage_validate.jl`)
- `explain_block`: stall 시 각 frontier 노드가 **왜 is_goal 게이트를 못 넘는지** 출력
  (terminal / successor-미준비 / FormTransportUnit 팀 OFF-position + cargo·tu·로봇 좌표).
  거리 d=0.0 만 보던 기존 덤프로는 안 보이던 "랑데부 desync"를 바로 짚어줌.
- `_run_to_end` catch 가 assert 예외 + 관련 LiftIntoPlace carry-chain 좌표를 덤프.

### 남은 일 / 한계 (MVP)
- 수정은 restage 시점에 그 assembly 가 **pending(빌드 전)** 임을 가정(현재 게이트와 일치).
  부분 빌드된 assembly 의 재배치는 free 가드로 막혀 있고 미지원.
- 하위 조립체 재귀 이동은 드리프트 감지로 사실상 커버되나(레벨 무관), 전용 테스트는 없음.
- BASE_ENV 캐시 RVO 전역 미복원 이슈(위 ⚠️) 별도.
- 다음: STEP 5 LLM 레이어(detector→번역→verifier→`maybe_respecify!` dispatch).

---

## 다중-assembly 복구 + 항법 검증 (Phase a/3/4 + root-clear, 2026-06-25)

단일 `restage_assembly!`로는 **하나의 zone이 여러 assembly의 적치영역을 덮는** 경우를 놓친다.
그 확장과 항법(nav) 켠 검증.

### 구현
- **Phase a — `restage_all_blocked!`** (`restage_zone.jl`): zone이 덮는 RELOCATABLE assembly를
  전부 검출(`zone_blocked_assemblies`: root·이미시작 제외, 적치원 overlap)해 **큰 것부터 순차
  재배치**. `find_clear_staging_center`가 live `staging_circles`를 읽어 앞서 옮긴 걸 자동 회피,
  드리프트 재동기화는 idempotent라 N회 호출에 합성됨. 캐시 재빌드는 끝에 1회.
- **Phase 3 — residual 실현가능성**: 재배치 후 `_count_future_goals_in_zone`로 **zone 안에 남은
  future EntityGo goal 수**를 셈. >0이면 옮길 수 없는 goal(주로 root)이 갇힌 것 → `:residual_blocked`
  (그 외 `:infeasible`/`:partial`/`:restaged_all`/`:none`). 거짓 `:restaged_all` 방지.
- **Phase 4 — dispatch**: `replan.jl maybe_respecify!`에 `_is_zone_respec`(ForbidZone 포함) 분기 →
  `restage_all_blocked!` 직행(robot-fault와 같은 geometric 전용 경로). `:residual_blocked/:partial/
  :infeasible` → `engage_fallback!`. `:restaged_all` → `:admitted`, `:none` → `:noop`.
- **root-clear 생성 가드**: `root_deposit_goals(env)`(root 직접 구성품의 LiftIntoPlace goal =
  옮길 수 없는 중앙 deposit), `zone_clears_root_goals(center,r,env)`. zone 생성 시 root deposit을
  안 덮게 제약하면 주입된 OOD가 restage-RECOVERABLE 해진다. (`_zone_clear_of_goals`=순수 detour
  가드의 보완: 이건 sub-assembly 적치 침범은 허용하되 root만 금지.) 모두 export.

### 검증 (tractor)
- **nav-OFF 회귀** (`restage_validate.jl restage_all_check`): R=3.79 zone이 **7개 assembly**를
  덮음 → restage_all `restaged_all`(7 moved) → **279/289 완주 PASS**. 다중 재배치가 기하적 정합.
- **nav-ON** (`restage_navon.jl`, rvo+tangent+dispersion ON): residual 게이트가 정확히 작동 —
  중앙 R=3.79 → residual=44, leaf R=0.48 → residual=9, root-clear R=0.44 → residual=2, 전부
  `residual_blocked` → fallback. **거짓 성공 0건.**

### 핵심 발견 — tractor는 너무 빽빽해 nav-ON positive 데모가 불가
- root@[1.5,0.96]가 중앙이고 **root deposit goal이 sub-assembly 중심에서 0.44밖에 안 떨어짐**.
  → root를 비키면(root-clear) zone이 R=0.44로 쪼그라들고, 그 초소형 disc 안에도 **여전히 2개의
  un-relocatable goal**(active 빌드/중간 deposit). 중앙에 깨끗이 restage-가능한 zone 자리가 없음.
- **즉 "공간이 작다/빽빽하다"가 binding constraint.** 모든 레이어는 올바름(가능한 건 복구,
  못 하는 건 정직한 fallback). 깨끗한 positive 데모엔 **(A) 덜 빽빽한 모델**(조립체 spread 큰
  것; `NAVON_PROJECT`로 교체 가능) 또는 **(B) root까지 덮였을 때 whole-build 평행이동**(넓은
  공간 필요) 필요.

### 변경 파일
`restage_zone.jl`(zone_blocked_assemblies, restage_all_blocked!, _count_future_goals_in_zone,
root_deposit_goals, zone_clears_root_goals), `replan.jl`(_is_zone_respec + dispatch),
`ConstructionBots.jl`(export), `tools/restage_validate.jl`(restage_all_check),
`tools/restage_navon.jl`(nav-ON 드라이버: mode none/single/all, target central/peripheral/bestclear,
NAVON_PROJECT, root-clear 자동 clamp, residual 리포트).
</content>
