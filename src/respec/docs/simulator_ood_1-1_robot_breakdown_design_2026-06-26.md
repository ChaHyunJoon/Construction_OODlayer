# OOD 1-1 로봇 고장(Robot Breakdown) — demo + LLM 번역 설계 (2026-06-26)

작성일: 2026-06-26. 1-2(ForbidZone, 항법 no-go zone)가 물리생성→LLM번역→검증→기하복구까지
end-to-end 완성된 뒤, **1-1 로봇 고장 + 방위별 spare pool** demo와 그 LLM 번역 구조를 설계한다.
상위 설계는 같은 폴더 `simulator_ood_generation_design_2026-06-23.md`(특히 §3). 본 문서는 그 §3을
**구현 가능한 step-by-step plan**으로 구체화하고, 한 가지 설계 결정을 새로 확정한다.

---

## 0. 현재 좌표 (어디서 시작하나)

| 레이어 | 1-2 (ForbidZone) | 1-1 (Robot fault) |
|---|---|---|
| 물리 생성 | ✅ `random_restriction_zone!` | ❌ spare pool 미구현 (`ood_injection.jl` "later") |
| 액션 코어(LLM-free) | ✅ `restage_all_blocked!`/`translate_whole_build!` | ⚠️ `fault_robot_and_reassign!` 존재하나 **double-booking으로 resume 완주 실패** |
| LLM 번역 | ✅ schema/propose/bridge/verify_zone | ⚠️ `ForbidAgent` 분기 있으나 코어가 막혀 e2e 미검증 |
| dispatch | ✅ `_is_zone_respec` | ✅ `_is_robot_fault`(→버그 코어) |

**핵심 전략(설계 §3.1 확정):** reassign double-booking 버그를 고치는 트랙과 **분리**해서,
**빈 task chain을 가진 spare 로봇에 고장 로봇의 chain을 통째로 id만 갈아끼우는 1:1 인계**로
버그를 *구조적으로 우회*한다. MILP 재solve·엣지 release 없음 → orphan/동시분기가 원천적으로
안 생김(= `resume_fulloop_status_2026-06-24.md`의 두 root cause를 둘 다 회피).

---

## 1. 설계 결정 (2026-06-26 사용자 확정)

### D1. LLM이 emit하는 DSL = **신규 `ReplaceAgent` (ForbidAgent와 구분)**
- 하는 일·구조·grounding은 `ForbidAgent`와 **동일**(로봇 고장 분류 + 정확한 robot id echo).
- 그러나 **별도의 ConstraintSpec 종류**로 둔다 — `ForbidAgent`(MILP 재배정 경로)와
  `ReplaceAgent`(spare 1:1 인계 경로)가 **dispatch·semantics에서 깔끔히 분리**되도록.
  - `ForbidAgent`는 "이 로봇 못 씀 → 남은 로봇으로 MILP 재배정"(일반 부하재분산, **버그 보유**).
  - `ReplaceAgent`는 "이 로봇 고장 → **가장 가까운 spare로 교대**"(MILP 없음, 버그 우회).
- 5번째 ConstraintSpec. 단 **MILP 제약 아님**(ForbidZone과 같은 부류) → `compile_constraint!`는
  generic 경로를 타지 않고 `maybe_respecify!`에서 전용 dispatch.

### D2. spare 선택은 **Julia 기하가 소유** (LLM 아님)
- "가장 가까운 풀에서 backup" = 4방위 중심까지 거리 최소 = 순수 기하. LLM은 좌표/거리/spare-id를
  만지지 않는다(ForbidZone에서 LLM이 좌표 안 만진 것과 동형, "LLM 불신·기하 우선").
- 따라서 `ReplaceAgent`는 **고장 로봇 id 하나만** 필드로 가진다(spare는 dispatch가 기하로 선택).
  spare를 LLM에 노출하는 건("북쪽 backup 켜줘") 미래 확장 — MVP 제외.

---

## Part A — 물리 OOD 생성 + 인계 코어 (LLM-free, "1-1 시뮬레이터 환경" 자체)

### A1. Spare pool 인프라 — `ood_injection.jl` (RESTRICTION_ZONES 패턴 복제)  ← **착수**
- module-level 저장소(PlannerEnv 불변 유지):
  - `const SPARE_POOLS = Ref(Dict{Symbol,Vector{RobotID}})` — `:north/:east/:south/:west → 미사용 spare ids`.
  - `const SPARE_POOL_CENTERS = Ref(Dict{Symbol,Vector{Float64}})` — 방위별 풀 중심(거리계산용).
- 헬퍼: `spare_pools` / `clear_spare_pools!` / `register_spare!` / `pop_spare!(key)` /
  `active_spares` / `pool_centers(bbox; margin)` / `nearest_pool(pos)`(중심까지 거리 최소 키).
- 배치: `add_directional_spare_pools!(scene_tree; n_spare, bbox, margin, geom)` —
  `add_robots_to_scene!`(construction_schedule.jl:1519) 패턴을 복제하되 **생성한 RobotID를 캡처**해
  방위별로 `register_spare!`. 4방위 클러스터에 각 `n_spare`대.
- **idle 보장(중요 통합점):** `set_robot_start_configs!`(construction_schedule.jl:1537)는 scene_tree의
  *모든* RobotNode에 RobotStart→RobotGo를 자동 생성하므로, spare를 scene_tree에 넣으면 자동으로
  **free idle 로봇**이 된다. 단 **초기 MILP 배정이 spare에 task를 주면 안 됨** → spare는
  **초기 plan/solve가 끝난 뒤(시뮬 시작 전) 주입**하거나, 초기 solve에서 spare free→slot 엣지를
  배제한다. (A1b에서 확정·배선; A1은 storage+geometry+placement 코어와 env-free 검증까지.)
- **done-gate(env-free):** clean load + `pool_centers`/`nearest_pool`이 표본 위치에 올바른 방위 반환 +
  `register_spare!`/`pop_spare!` round-trip + `add_directional_spare_pools!`가 scene_tree에
  `4*n_spare` RobotNode 추가하고 `SPARE_POOLS` 합계가 일치.

### A2. 물리 고장 주입 — `ood_injection.jl` (zone 생성기와 동형)
- `fault_robot!(env; target, key)`:
  1. 대상 로봇 `r` 선택(데모는 활성 운반 중 로봇이 시각적으로 좋음).
  2. 명령속도 영구 0 + **그 자리를 정적 장애물로 등록**(`add_restriction_zone!(:fault_r, pos, robot_r)`
     재사용 → 다른 로봇이 우회; §3.3-1 "장애물로 남김").
  3. NL 반환: `"Robot R{n} has broken down at (x,y) and cannot move; dispatch the nearest backup
     robot to take over its remaining work."`
- `schedule_ood!(K, fault_robot!)`로 step K 예약(기존 스케줄러 재사용).
- **불변식(버그 노트 반영):** 인계 후 faulted id가 어떤 RobotGo에도 안 남아야
  `rvo_get_agent_idx` 크래시가 안 남 → A3가 보장.

### A3. 인계 코어 `replace_robot!` — 신규 `src/respec/replace_robot.jl` (restage_zone.jl 패턴)
**MILP 없이** 고장 로봇 F의 잔여 chain을 spare S에 1:1 인계:
- `replace_robot!(env, faulted::RobotID, spare::RobotID; resume=true)`:
  1. F의 **frontier**(미닫힘 free RobotGo) 식별 — `robot_frontier_vtxs`(reassign.jl) 재사용.
  2. **닫힌 과거 불변** — closed 노드는 안 건드림(F가 이미 한 일은 F 기록으로 남김; safety).
  3. F의 잔여 RobotGo·FormTransportUnit 팀 슬롯 id를 **S로 re-stamp** — `replace_in_schedule!` +
     `RobotGo(RobotNode(S,…))` + `swap_robot_id!`(전부 reassign.jl primitive 재사용).
  4. S의 RobotStart를 F의 frontier에 graft(S는 빈 chain → **충돌 없는 단일 인계** = 우회의 핵심).
  5. frontier RobotGo `start_config`를 S 풀 위치로 보정(또는 RVO가 S 현 위치→goal 라우팅) — done-gate 미세점.
  6. `reset_cache_resume!`(구현됨)로 진행상태 보존 재개.
  7. status NamedTuple(`:replaced`/`:no_spare`/`:no_frontier`/`:already_done`).

### A4. fast-loop done-gate — `dev_session.jl` `spare_replace_test()` (설계 §3.4)
- `deepcopy(BASE_ENV)`(mid-build) → `fault_robot!` → `nearest_pool`→spare → `replace_robot!` →
  `reset_cache_resume!` → 완주까지 stepping.
- **assert:** `closed_set` monotone(never regress) / `project_complete` 도달(**reassign이 못 넘던
  done-gate**) / faulted id로 `rvo_get_agent_idx` 에러 0(F가 깨끗이 제거 = root cause #2 해소) /
  spare가 정확히 F chain 수행.
- **이 테스트 green = spare-pool 가설(§3.1) 입증 = 1-1 완주 블로커 제거.** Part A 종착점.

---

## Part B — LLM 번역 레이어 (1-2 STEP 5 복제 + 신규 ReplaceAgent 배선)

### B1. DSL 정의 — `spec_dsl.jl`
- `struct ReplaceAgent <: ConstraintSpec; agent::AbstractID; after::Float64; end`
  (ForbidAgent와 동일 필드, docstring으로 "spare 1:1 인계 경로, MILP 아님" 명시).

### B2. Python `schema.py` / `propose.py`
- `ReplaceAgent` Pydantic + ConstraintSpec union + TOOL_SCHEMA enum/properties에 추가.
- `propose.py` 분류 가이드: *"robot broke down / immobile / malfunction needing a backup →
  **ReplaceAgent**(echo exact robot id)"*. (단순 "이 로봇 쓰지마"는 ForbidAgent로 유지하되,
  고장→교대 맥락은 ReplaceAgent로 — 프롬프트로 구분.)

### B3. Julia bridge — `llm_bridge.jl`
- `_parse_proposal`에 `ReplaceAgent` 분기 추가(`id_resolver`로 robot id 역변환 — ForbidAgent와 동일).
- `open_agent_descriptors`는 그대로 재사용(고장 로봇 grounding 제공).

### B4. Verifier — `verifier.jl`
- `referenced_ids(::ReplaceAgent)` + 가벼운 게이트 `verify_replace(proposal, env)`:
  (a) faulted id가 닫힌 과거 아닌 실존 robot인지, (b) **가용 spare 존재**(`nearest_pool` 비어있지 않음).
  Reject면 fallback. (verify_zone과 같은 부류 — trial-solve 안 함.)

### B5. Dispatch — `replan.jl`
- `_is_robot_replace(p) = any(c -> c isa ReplaceAgent, p.constraints)`.
- `maybe_respecify!`에 분기 추가: `verify_replace` 게이트 → `nearest_pool`/`pop_spare!`/`replace_robot!`
  → `:replaced`면 `:admitted`, `:no_spare`/실패면 `engage_fallback!`.
  로그: `[RESPEC] robot-fault -> replace with nearest spare $(spare)`.
- 기존 `_is_robot_fault`(ForbidAgent→reassign) 경로는 **그대로 잔존**(별도 트랙).

### B6. mock e2e — `tools/mock_replace_e2e.jl` (mock_respec_e2e.jl 복제)
- 로컬 mock `/propose`가 fault NL에 `ReplaceAgent` 반환 → `respec_step!` → dispatch →
  `replace_robot!` → 완주. **LLM-free full enabled-loop PASS**가 done-gate(1-2 Stage 2 동형).

### B7. 실 LLM — 기존 turn-key 재사용
- `test_llm_classification.jl`에 fault NL 케이스 추가(zone/fault/window/replace 분류 정확도).
  서비스·키 배선은 1-2에서 완비(`run_real_llm_demo.ps1`).

---

## Part C — demo 통합 + 시각화

`demo_respec_forbidzone_anim.jl` 복제 → `demo_respec_replace_anim.jl`:
- 시작: 중앙 빌드 로봇 + **4방위 spare 클러스터** 배치, `RESPEC_ENABLED[]=true`.
- step K: `fault_robot!` 발화 → 고장 로봇 **회색/정적 마커**(zone disc 렌더 재사용) + NL `push_ood!`.
- respec: (mock 기본 / `USE_MOCK=0` 실 LLM) → `ReplaceAgent` → `replace_robot!`.
- **눈으로 보이는 것:** 고장 로봇 정지·회색, **가장 가까운 풀의 spare가 빌드로 진입**해 작업을
  이어받고 빌드 완주. (1-2의 "빨간 zone + 우회"에 대응하는 1-1의 "고장 + backup 교대".)

---

## 빌드 순서 (각 단계 LLM 없이 검증)

1. **A1** spare pool 인프라 + 4방위 배치 → env-free PASS  ← **현재**
2. **A2** `fault_robot!` 생성기(정적 장애물화 + NL)
3. **A3** `replace_robot!` 인계 코어
4. **A4** `spare_replace_test()` green ← **★ 핵심 done-gate: "1-1 시뮬레이터" + 버그 우회 증명**
5. **B1/B4/B5** ReplaceAgent DSL + verify_replace + dispatch 배선
6. **B6** `mock_replace_e2e.jl` PASS(enabled full-loop)
7. **C** 시각 demo
8. **B2/B7** 실 LLM 분류 + 시각 demo(turn-key)

1~4가 1순위("OOD가 생성·복구되는 시뮬레이터"), 5부터가 "LLM이 해석해 복구"하는 윗단.

---

## 리스크 / open question (done-gate에서 깨질 만한 곳)

- **R1 (최대 미지수): frontier graft의 기하 일관성.** spare는 풀(원격)에서 출발 → frontier
  RobotGo `start_config`/transport unit 형상이 spare 현 위치와 불일치하면 restage에서 본
  STALL(`restage_zone_status_2026-06-23.md`)과 같은 류가 재현될 수 있음. **A4가 직접 때리는
  done-gate** — STALL 시 frontier·deposit config 보정이 다음 작업.
- **R2: spare 고갈/원거리.** 가장 가까운 풀도 비면 `:no_spare`→safe-stop(`verify_replace` 게이트).
  데모는 `n_spare` 충분히.
- **R3: faulted 잔여노드 완전 제거**(버그 root cause #2). A3-3에서 closed 제외 전 RobotGo를
  *전부* re-stamp(누락 시 `rvo_get_agent_idx` 크래시 재현). A4의 "faulted id 에러 0" assert가 검증.
- **R4: 초기 MILP가 spare에 배정**(A1 idle 보장). spare는 초기 solve 후 주입 또는 초기 solve에서 배제.

이 plan은 reassign 버그 트랙과 독립적이라 그 버그가 미해결이어도 1-1 demo는 완주 가능(설계 §5 의도).

관련 메모리: OOD 생성 = [[constructionbots-ood-generation-design]], 기하 복구 패턴 =
[[constructionbots-forbidzone-llm-layer]], 빌드 평행이동 = [[constructionbots-wholebuild-phaseB]].

## 진행 로그
- **2026-06-26** — 설계 합의·문서화. D1(신규 `ReplaceAgent` DSL, ForbidAgent와 구분)·D2(spare 선택은
  기하) 확정. 코드 hook 식별 완료(`add_robots_to_scene!` construction_schedule.jl:1519,
  `set_robot_start_configs!`:1537이 idle spare 자동 생성, reassign.jl primitive 재사용). **A1 착수.**
- **2026-06-26 (b)** — **A1 코어 구현·검증 완료.** `ood_injection.jl`에 OOD 1-1 섹션 추가:
  - 저장소(module-level, PlannerEnv 불변): `SPARE_POOLS`(방위→RobotID 벡터) +
    `SPARE_POOL_CENTERS`(방위→2D 중심). 접근자 `spare_pools`/`spare_pool_centers`/`clear_spare_pools!`.
  - 헬퍼: `register_spare!`/`pop_spare!`(LIFO)/`active_spares`/`pool_centers(bbox;margin)`(4방위 중심)/
    `nearest_pool(pos;nonempty)`(예비 남은 최근접 풀; 없으면 nothing).
  - 배치: `add_directional_spare_pools!(scene_tree;...)` — `add_robots_to_scene!` 복제 + **만든
    RobotID 캡처**해 풀 등록. `_scene_robot_bbox` 헬퍼. `set_robot_start_configs!` 전에 호출 → idle spare.
  - export 추가(ConstructionBots.jl). 신규 `tools/spare_pool_check.jl`(env-free).
  - **검증(julia +lts, LLM-free):** 패키지 clean load + **20/20 PASS** — pool_centers(4방위 좌표) /
    register·pop·active_spares round-trip / nearest_pool(방위별 최근접 + 빈 풀 skip + nonempty=false 복원) /
    clear 양쪽 비우기 / 빈 저장소 nothing.
  - **남은 A1b(통합):** `add_directional_spare_pools!`의 실제 scene_tree 주입 + **초기 MILP가 spare에
    배정 안 되게**(초기 solve 후 주입 or free→slot 엣지 배제, R4) 배선. 그 다음 **A2** `fault_robot!`.
- **2026-06-26 (c)** — **자율 세션: B 레이어 전체 + A1b/A2/A3 구현, A4 done-gate 1차 실행(STALL 격리).**
  - **B(LLM 번역) 완성·검증:** B1 `ReplaceAgent` DSL(spec_dsl.jl, ForbidZone처럼 MILP 아님) + B3
    `_parse_proposal` 분기 + B4 `verify_replace`(static + spare-exists 게이트)+`referenced_ids` +
    B5 dispatch `_is_robot_replace`(replan.jl: nearest_pool→pop_spare→replace_robot!) + B2 Python
    `schema.py`/`propose.py`(ReplaceAgent Pydantic+enum+분류 가이드). `tools/test_replace_parse.jl`
    **9/9 GREEN**(분류·verify·referenced_ids·fail-closed), Python schema offline 검증 OK.
    **1-1 LLM 번역 레이어 end-to-end 완성**(실 LLM은 turn-key, mock 대체 가능).
  - **A1b(spare 주입) — 가설 확정·동작:** full_demo.jl에 `n_spare_per_pool` 키워드 추가, 정상 로봇
    배치 직후 `add_directional_spare_pools!` 주입. **핵심 발견: greedy 배정은 잉여 로봇을 안 쓰고
    idle로 남김** → A4에서 **8/8 spare 전부 idle 확인**(별도 MILP 배제 로직 불필요, R4 해소).
  - **A2(fault_robot!) 동작:** 활성 운반로봇 선택 + 정적 장애물 등록 + NL emit.
  - **A3(replace_robot!) splice 동작 + 버그 우회 확인:** mid-build(closed 54)에서 R7 고장 →
    nearest pool :east → spare R12 인계 → `:replaced`, 하류 6 task 재stamp, **MILP 없음**.
    resume 후 **RVO/identity assert 0**(reassign root cause #2 = faulted-robot rvo crash **회피 확인**),
    `closed_set` **monotone**, 54→**192**까지 진행.
  - **그러나 192/305 STALL**(완주 X) — 설계 R1(frontier-graft 기하) 발현. reassign과 달리 **assert
    없이** 멈춤 = 더 다루기 쉬운 실패 모드. `tools/spare_replace_test.jl` 10/11 PASS(완주만 FAIL).
- **2026-06-26 (d)** — **STALL 진단 좁힘 + B6 seam GREEN.**
  - **STALL 진단(`tools/spare_replace_test.jl` 토글 FAULT_OBSTACLE/FAULT/CLEAN):**
    - `obstacle=false`도 **동일 192 STALL** → 정적 장애물 deadlock 가설 **기각**(결정론적 기하).
    - **CONTROL(spare 있음, fault 없음) = 완주**(287/305, project_complete) → **idle spare는 빌드를
      안 막음**(A1b 완전 검증). STALL은 **순전히 hand-off 때문**.
    - clean-frontier 타깃(운반팀 미참여)으로 골라도 **동일 192 STALL** → mid-carry 가설도 기각.
    - **STALL frontier 덤프**: 16 active(4 TransportUnitGo + 12 RobotGo) gridlock. faulted R7 dead fg
      1개 active 잔류(R3), spare R12는 인계 12 RobotGo 보유하고 active로 진입. **healthy 로봇 9대까지
      동반 gridlock** → R12가 빌드의 협조적 운반 타이밍/경로에 합류 못해 endgame 전체가 R12 산출물을
      기다리는 구조적 정체로 추정(원격 :east 풀에서 합류).
  - **B6 mock e2e seam GREEN(4/4):** `tools/mock_replace_e2e.jl` — mock /propose가 NL에서
    ReplaceAgent grounding → `respec_step!`이 **:admitted**, spare 소비(8→7), RVO assert 0, fault
    지점 통과. **NL→push_ood!→respec_step!→mock LLM→ReplaceAgent→verify_replace→nearest_pool/
    pop_spare→replace_robot! 전체 배선 검증.** (완주는 R1 stall로 미assert — 의도된 스코프.)
    주의: one-shot 스케줄러는 action이 nothing 반환해도 fired=true → fault 트리거는 빌드 진행 후
    step(OOD_STEP=3)에 예약해야 발화(closed-count는 step 1에 이미 점프).
- **2026-06-26 (e)** — **STALL 근본원인 좁힘: 항법/거리 아님 → 운반팀 rendezvous/capture 완료 실패.**
  STALL 시 spare 위치 덤프 추가(`spare_replace_test.jl` [5]): **R12가 원격 :east 풀에서 잘 이동해
  자기 첫 active goal에서 0.01(robot_r=0.14 이내) = 목표 도달**했는데도 그 RobotGo가 안 닫힘.
  → **거리/`avoid_staging_areas` 가설 기각**(spare는 항법 OK). STALL은 **RobotGo→FormTransportUnit
  전이(운반팀 형성)·capture 조건**에서 막힘 = 4 TransportUnitGo 정체. hand-off가 팀 형성 타이밍을
  바꿔 **다로봇 운반 rendezvous deadlock**(co-member 상호 대기) 또는 capture 기하조건 불충족으로 추정.
  - **다음(STALL = 유일 잔여 블로커, A4 done-gate만 막음):** 운반팀 capture 머신 디버그가 핵심.
    ① fault 시점 R12가 인계받은 slot의 FormTransportUnit co-member들을 식별 → 그 팀이 R12 도착 후
    왜 capture 안 되는지(다른 member 위치/cargo pose) 추적. ② R7 dead fg 강제 close(R3)로 R7을
    프론티어에서 제거. ③ hand-off가 만든 팀-형성 순서 충돌이면, 인계를 **운반팀 경계에서만**
    허용(미형성 팀의 slot만 인계, 형성중/형성된 팀은 제외)하는 MVP 스코프로 좁힘. 이 stall만 풀면
    A4 GREEN(나머지 전 레이어 검증 완료).
  - **(f) R3도 기각:** `PARK_FAULTED=1`로 R7의 dead fg를 강제 close해 **faulted 로봇을 프론티어에서
    완전 제거(bound 0)**해도 **동일 193/305 STALL**, R12는 goal에 정확 도달(dist 0.0)인데 capture 안 됨.
    → **STALL은 순수하게 운반팀 형성/capture deadlock**(faulted 잔류 무관 확정). 4 TransportUnitGo가
    상호 대기. **다음 세션 1순위 = FormTransportUnit capture 머신 디버그**(R12 도착 후 그 팀의 다른
    member/cargo가 왜 안 모이는지 — 인계가 팀 형성 순서·예약을 깬 것으로 추정). 위 ③(미형성 팀만 인계)
    스코프 제한이 가장 빠른 GREEN 경로일 수 있음.
- **2026-06-26 (g)** — **STALL 근본원인 확정(중요): spare가 동시 frontier로 double-book.**
  FTU 형성조건(route_planning.jl:480-488 = 팀 전원이 동시에 capture 거리 내)을 단서로 운반팀·spare
  thread 구조를 덤프(`spare_replace_test.jl` [6][7]):
  - **R12(spare)가 3개 운반팀에 동시 소속**: R16과의 2-로봇 팀(R12 in_capture=**false**) + 단독 팀 2개
    (R12 in_capture=true). R12는 한 곳에만 있을 수 있어 R16팀 미형성 → cascade gridlock.
  - **R12 thread에 동시 active RobotGo 2개**(v230, v231), 둘 다 `predecessor=RobotGo[closed]`.
    = R7의 미완 slot들이 각각 **닫힌 feeder**를 가져 `reset_cache_resume!`가 **동시에 frontier로 활성화**.
  - **핵심 통찰: reassign double-booking이 spare에서 재발.** R7의 여러 작업은 원래 **MILP 시간(t0)**으로만
    직렬화돼 있었고 그래프상으론 다중 frontier. spare가 시간제약 없이 인계받으면 동시 활성 →
    한 로봇이 여러 운반팀에 동시 소속 → deadlock. **"spare-pool이 double-booking을 구조적으로 우회"
    가설은 부분적으로만 참**: 인계 thread는 하나여도 R7 미완 slot이 여럿이면 **명시적 직렬화 필요**.
  - **FIX 방향(다음 작업):** `replace_robot!`에서 인계 후 spare의 다중 frontier slot을 원래 t0 순으로
    정렬해 **직렬 precedence 추가**(slot_i의 DepositCargo → slot_{i+1})로 한 번에 1개만 active 되게.
    (cycle 위험은 t0 순서로 회피.) 이게 A4 done-gate GREEN의 유일 잔여 작업.
- **2026-06-26 (h)** — **직렬화 FIX 구현(부분 성공) + 잔류 2-task 격리.**
  `replace_robot!`에 `_serialize_spare_frontiers!` 추가(인계 후 reset_cache_resume! 전):
  spare의 모든 FTU-feeding slot을 원래 t0 순으로 정렬해 `deposit_i → slot_{i+1}` precedence 추가,
  각 edge는 **cycle 가드**(`has_path(nxt,dep)`면 skip — 이미 반대로 정렬돼 있다는 뜻)로 안전.
  `_adopted_task_deposit`는 slot→FTU→TUGo→DepositCargo를 **BFS**로 탐색.
  - **효과(단조 개선):** 완주 진행도 splice-only **192** → frontier-only 직렬화 **203** →
    전체 t0+cycle가드 **234**/305(완주목표 287)까지 상승. **crash 없음**(cycle 가드 동작).
  - **잔류:** 여전히 spare가 **동시 active RobotGo 2개**(v230=정당한 현재작업[slot1, feeder sg가
    이제 closed], **v231=초과 1개**). 이 쌍이 직렬화에서 누락 — **원인: replace 시점엔 v231 frontier가
    아직 안 드러남**(그 feeder는 resume 중 R12 진행으로 닫힘). 즉 **replace-time 1회 직렬화로는
    resume 중 뒤늦게 드러나는 frontier를 못 잡음.**
  - **다음(이 한 가지만 남음):** ① replace-time 직렬화를 **완전 total-order**로(모든 인계 task를
    무조건 1열로, deposit-walk 검증 + t0 안정정렬) 강화하거나, ② resume 루프에서 spare가 동시
    active 다수면 가장 이른 것만 남기고 나머지 defer(동적 직렬화), 또는 ③ replace 시점에 R7의
    "닫힌 feeder"들을 모두 찾아 그 successor slot들을 sg 체인 뒤로 미리 1열 연결. ①이 가장 깔끔.
  - **검증 무결성:** 이 변경은 `test_replace_parse.jl`(replace_robot! 미호출)·`spare_pool_check.jl`에
    무영향. `mock_replace_e2e.jl`(B6)은 완주 아닌 seam(:admitted+progress)만 assert라 영향 없음(재확인).
- **2026-06-26 (i)** — **근본원인 확정: replace가 운반유닛에 중복 spare-feeder 생성 → dedupe로 수정(double-booking 해소).**
  계측(`spare_replace_test.jl` [6][7] + `_adopted_task_deposit` 타입-보행 + pre-fault 스캔):
  - **두 R12 슬롯(v230,v231)이 같은 solo FTU(v40)를 먹음**(deposit 동일). **base env 동일-로봇 중복 feeder=0**
    → **replace_robot!이 중복을 생성**(빌드 고유 아님) 확정.
  - **FIX `_dedupe_spare_ftu_feeders!`**(replace_robot.jl, re-stamp 후): FTU team dict(권위적)보다 spare
    graph-feeder가 많으면 sg-도달 가능한 것만 남기고 잉여 edge 제거 + 그 노드 closed로 park.
    → **동시 active RobotGo 2→1, 중복 feeder 0**(검증됨). `_adopted_task_deposit`도 BFS→**타입-체인 보행**
    (slot→FormTransportUnit→TransportUnitGo→DepositCargo)으로 교정(BFS가 공유 하류 deposit 오집).
  - **그러나 여전히 192 STALL** — **더 깊은 원인 노출(double-booking과 별개):** R12가 **2-로봇 팀 2개**
    ({R3,R12},{R16,R12})의 공동 운반자라 R3·R16이 R12 도착을 기다리는데 R12는 다른 task 중 →
    **다로봇 운반팀 timing-coordination deadlock**. 고장 로봇이 여러 2-로봇 carry의 멤버였으면 단일
    spare가 그 타이밍을 못 맞춤(reassign이 어렵던 것과 같은 근원). **이는 단일-spare 인계의 본질적
    한계** = restage "미시작 assembly만" MVP와 동형.
  - **상태:** double-booking(구조)·중복feeder(구조)는 **해결**. 남은 건 **다로봇 팀 timing**(연구성).
    MVP 경로 = 고장 대상을 "2-로봇 팀 비참여(solo transport) 로봇"으로 한정하면 A4 GREEN 기대.
  - **다음:** ① 고장 타깃을 solo-transport 로봇으로 한정해 A4 GREEN 시도, ② Part C 시각 demo(인계 진행
    가시화), ③ B6/parse 무결성 재확인.
- **2026-06-26 (j)** — **두 구조 버그(double-booking·RVO 크래시) 해결로 안정화. 남은 건 다로봇 팀 coordination.**
  - **R3 수정 (RVO 크래시 해결):** solo 타깃 테스트가 `rvo_get_agent_idx BoundsError`로 크래시(고장
    로봇이 여전히 구동됨 = reassign root cause #2). **`replace_robot!`이 재stamp 후 고장 로봇의 잔여
    RobotGo(dead fg + orphan)를 모두 force-close**(closed_set 추가)하도록 R3 neutralization 통합 →
    **크래시 사라짐**("no RVO/identity assert" PASS). 고장 로봇 본체는 fault_robot!의 정적 장애물로 잔존.
  - **현재 안정 상태:** double-booking(dedupe)·RVO 크래시(R3) **모두 해결**. 동시 active RobotGo 1개,
    closed monotone, 무크래시, 빌드 54→**207**/305 진행. `replace_robot!` 파이프라인 =
    splice → re-stamp → **dedupe**(중복 feeder 제거) → **serialize**(t0 직렬화) → **R3 neutralize**(고장로봇 park).
  - **유일 잔여(연구성): 다로봇 운반팀 timing-coordination.** 조밀한 tractor 빌드에선 spare가 결국
    2-로봇 팀에 합류하게 되고({R1,spare} 등), 다른 healthy 로봇(R1)이 spare 도착을 기다리며 stall.
    추가로 spare의 인계 slot `goal_config`가 고장 로봇 기준이라 `feeder_at_goal=false`인데 `in_capture=true`인
    geometry 불일치(restage `_resync_scene_drift!` 류) 정황 → RobotGo→FormTransportUnit 전이 미발화.
    **이 둘이 다로봇 인계 완주의 본질적 잔여**(reassign이 어렵던 근원과 동일 계열). 단일-spare로
    2-로봇 carry 타이밍을 못 맞추는 한계 → MVP는 "고장 로봇이 2-로봇 carry 비참여" 시나리오로 스코프.
    (pick_solo_target이 R2를 골랐으나 R2도 2-로봇 팀 멤버였음 → tractor엔 순수 solo 로봇이 드묾.)
  - **다음 세션 진입점:** ① spare 인계 slot의 goal_config를 spare 현위치/실제 rendezvous로 보정
    (`_resync_scene_drift!` 류) → feeder_at_goal 불일치 해소가 1순위(단일 task 완주부터). ② 2-로봇 팀
    timing은 그 다음(인계 후 부분 재-timing 또는 팀 경계 인계 제약).
  - **최종 검증(이 세션):** dedupe+R3 변경 후 회귀 없음 — `mock_replace_e2e.jl`(B6) **4/4 GREEN**(seam,
    peak 203→**237**), `spare_pool_check.jl` **20/20**, 패키지 clean load. **Part C 시각 demo 완성:**
    신규 `tools/demo_respec_replace_anim.jl`(USE_MOCK 기본, 4방위 spare + fault_robot! + mock ReplaceAgent
    + 인계 애니메이션). 실행 시 8 spare 주입→step5 R2 고장→MOCK-LLM→ReplaceAgent→**[RESPEC] ADMITTED
    replace: spare 교대**→진행 후 stall(INCOMPLETE, 다로봇 잔여)→`results/tractor/.../visualization.html`
    (75M, RESPEC 파이프라인 로그 패널 임베드: NL→DSL→hand-off). **전체 OOD 1-1 파이프라인의 watchable demo.**
- **2026-06-27 (k)** — **§(j) 1순위 재진단 → 가설(goal_config drift) 기각, 진짜 근본원인(transform-binding) 확정·수정. 단일 task 완주 달성.**
  - **측정(STEP 0):** `spare_replace_test.jl diagnose_ftu`에 `GOAL_DRIFT` 계측 추가
    (`global_transform(goal_config(slot))` vs `global_transform(tu) ∘ child_transform(tu, rid)`).
    **결과 `GOAL_DRIFT=0.0`** — 스케줄 슬롯과 tu 기대 capture 슬롯은 (병진상) 동일 → **goal_config 드리프트 가설 기각.**
    그런데 solo FTU(v15, team=1)에서 **`feeder_at_goal=false`인데 `in_capture=true`, `dist to goal=0.01`** = 수학적 모순.
  - **진짜 원인:** `is_goal(::RobotGo)`의 `feeder_at_goal`은 **`entity(node)`(스케줄 노드의 RobotNode)**를,
    팀 형성 체크의 `in_capture`는 **`get_node(scene_tree, id)`(씬 로봇)**를 본다(route_planning.jl:459-460 vs 483-484).
    `_restamp_robot_go!`가 `RobotNode(new_id, entity(node))`로 **고장 로봇 노드에서 새 RobotNode를 mint** →
    그 transform이 컨트롤러/RVO가 구동하는 **씬 로봇과 분리**됨. 컨트롤러는 씬 로봇을 목표로 보내 `in_capture=true`가
    되지만, 스케줄 노드의 robot은 안 움직여 `feeder_at_goal` 영구 false → RobotGo→FormTransportUnit 전이 미발화.
  - **FIX(`_restamp_robot_go!`):** reassign.jl `rethread_robot_ids!`(L245-247)의 정식 패턴 채택 —
    `robot_start = get_node(sched, RobotStart(RobotNode(new_id, entity(node))))` 로 스페어의 **정식 scene-linked
    RobotNode**를 가져와 `RobotGo(RobotNode(new_id, entity(robot_start)), …)` 생성. 이제 re-stamp된 모든 노드가
    스페어 씬 로봇과 transform을 공유(정상 스케줄과 동형). **(j)의 `_resync_adopted_slot_goal!` 보정 함수는 불필요 → 미도입.**
  - **효과:** solo FTU **v15 완주**(stall 목록에서 사라짐), 진행 **207→235**/305, 무크래시·monotone, 회귀 없음(10/11 PASS, 유일 fail=완주 게이트).
  - **남은 단일 stall(순수 #2):** team=2 FTU **v56**(멤버 R1+스페어). R1은 `in_capture=true`로 대기,
    스페어는 `[7]`에서 **동시 active RobotGo 2개**(v237=FTU v56 슬롯, v270 별도 task) → 스페어가 v270 목표(dist 0.0)에
    가 있고 v56을 비워 R1 무한대기. = **다로봇 인계 시 스페어 double-booking 재발(replace-time 1회 직렬화가 resume 중
    뒤늦게 드러나는 frontier를 못 잡음, (h) 잔류와 동일).** tractor엔 순수-solo 로봇이 없어 MVP "solo-only 완주"는 이 빌드선 시연 불가.
  - **다음:** #2 직렬화 강화 — ① replace-time **total-order**(모든 인계 RobotGo를, FTU-feeder뿐 아니라 release-go까지
    t0로 1열) 또는 ② **동적 직렬화**(resume step 루프에서 스페어가 동시 active 다수면 가장 이른 것만 두고 나머지 defer).
    REPLACE_DEBUG=1로 v237/v270 직렬화 누락 지점 확인 중.
- **2026-06-27 (l)** — **#2 정밀 분류(dead-rest 경쟁 vs 다팀 double-booking RVO 크래시) + crash→graceful 가드 + dead-rest 파킹.**
  - **REPLACE_DEBUG 트레이스로 v270 정체 확정:** 강화 `[7]` 덤프(succs/terminal/t0/at_goal) →
    `v270: terminal=TRUE succs=[] at_goal=TRUE t0=5.58`(고장 로봇의 **중간 휴식 dead-end**), `v237: succs=[FormTransportUnit]`(진짜 task).
    re-stamp가 고장 로봇의 carry별 휴식노드를 스페어에 전부 넘겨 → 컨트롤러가 스페어를 진짜 task 대신 **dead-end 휴식(v270)으로 몰아 거기서 정지**
    (is_goal는 terminal을 절대 안 닫음, route_planning.jl:469) → 동료 R1 무한대기. **이건 "다로봇 timing"이 아니라 dead-end 경쟁.**
  - **FIX-A `_park_spare_dead_rests!`**(replace_robot.jl): 스페어의 잉여 terminal dead-end RobotGo(최종 휴식 1개=최대 t0만 남기고)를
    force-close. `replace_robot!`에 `park_rests::Bool=true` 키워드로 게이트. **무혐의 확정**(아래 격리).
  - **결정적 타깃화:** `pick_solo_target`이 `active_set`(Set) 순회로 **비결정적**(R2/R1 갈림)이었음 → 최소 id 정렬로 결정적(R1).
    이걸로 재현성 확보 후 격리: **PARK_RESTS=0(파킹 OFF)도 R1에서 동일 크래시** → **크래시는 파킹 무관, R1 시나리오 자체.**
  - **크래시 근본원인:** transform-binding fix(k)가 스페어를 **실제 팀 형성에 참여**시키면서, 단일 스페어가 한 운반유닛에 capture된 상태로
    **다른 운반유닛의 개별 RobotGo가 아직 active**(다팀 double-booking)면, capture된 로봇은 RVO map에서 빠져(child) `rvo_get_agent_idx→BoundsError[-1]`.
    (fix 전엔 스페어가 팀에 안 끼어 benign stall이라 이 크래시가 안 드러났음.) 경로: step_environment! 구동 루프 + `swap_first_paralyzed_transport_unit!` + preprocess_env! assert.
  - **FIX-B crash→graceful 가드(route_planning.jl, 3곳):** active RobotGo의 로봇이 **RVO id map에 없으면**(captured 또는 미등록 root)
    구동/스왑을 skip(`has_vertex(rvo_global_id_map(), node_id(agent))`), preprocess의 has_parent assert도 skip으로 완화.
    정상 빌드의 active 로봇은 항상 map에 있어 **무영향**; 다팀 double-booking 시 **하드 크래시를 graceful wait(stall)로** 강등.
  - **결과:** **모든 fault 타깃 무크래시.** 결정적 R1 = graceful **stall 219/305**(이전엔 크래시), R2 = stall 235. 단일 task 완주는 유지(k).
    `spare_replace_test` 10/11(유일 fail=완주 게이트, 이제 **크래시 아닌 stall**). **demo-safe 달성.**
  - **회귀 검증(core 가드 무영향 확인):** **CONTROL(FAULT=0, 무고장 정상빌드) GREEN — 완주 287/305 `:complete`, 4/4 PASS, 에러 0.**
    → route_planning.jl 가드는 정상 빌드에 무영향(active 로봇은 항상 RVO map에 있어 skip 미발화).
  - **남은 #2(연구성, 변함없음):** 다팀 인계 완주 = 단일 스페어가 동시 운반팀 타이밍을 못 맞춤. 가드는 안전망일 뿐 완주는 미해결.
    다음 = ① 동적 직렬화(스페어 동시-active 1개로 강제) ② 또는 인계를 팀 경계로 제한. tractor엔 순수-solo 로봇 없음(MVP 한계).

## 구현 현황 요약 (2026-06-27 갱신)
| 항목 | 상태 |
|---|---|
| A1 spare pool 인프라 + A1b 주입 | ✅ (20/20, greedy 잉여 idle, control 완주) |
| A2 fault_robot! | ✅ |
| A3 replace_robot! (splice+restamp-binding-fix+dedupe+serialize+park-rests+R3) | ✅ 동작(:replaced, 무크래시, monotone) |
| B1~B5 + B2 Python (LLM 번역 ReplaceAgent) | ✅ (test_replace_parse 9/9) |
| B6 mock e2e seam | ✅ (4/4) |
| Part C 시각 demo | ✅ (애니메이션 HTML 생성) |
| **단일 인계 task 완주(transform-binding)** | ✅ **해결**(§(k)) — solo FTU 완주, feeder_at_goal이 live 스페어 추적 |
| **모든 fault 타깃 무크래시(RVO map 가드)** | ✅ **해결**(§(l)) — 다팀 double-booking을 graceful stall로 강등(demo-safe) |
| **A4 done-gate(빌드 완주)** | ✅ **해결**(2026-06-27) — E1 동적직렬화 + V5 스페어우선순위 + **V6 team-straggler 우선순위**로 다로봇 deadlock 격파 → tractor early fault **완주 288/305 `:complete`, spare_replace_test 11/11 GREEN** |
| B7 실 LLM | ✅ turn-key(서비스+키 시 `[ReplaceAgent]`만, ForbidZone 과분류 없음) |

**= 1-1 LLM 번역 레이어·물리 인계 메커니즘 완성·검증. 다섯 버그/블로커(double-booking·RVO restamp-crash·transform-binding·
다팀 capture-crash·**다로봇 팀 deadlock**) 해결 → "로봇 고장 → 가장 가까운 spare 1:1 인계 → manufacturing 완주"가
tractor에서 sim 검증됨(궤적 207→235→246→254→**288/305 `:complete`**, V2/V3/V5/V6 누적). 자기진화 상세 = `llm_safety_layer_improvements_and_self_evolution_2026-06-27.md` Part E.
잔여(연구): 더 조밀한 동시-다팀 인계의 cyclic cargo-dependency(re-timing future work).**
</content>
</invoke>
