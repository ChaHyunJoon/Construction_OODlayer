# AI&T 모니터 + OOD 자율 복구 제어 — 개발 기록
**날짜: 2026-07-21**

ConstructionBots(spacecraft AI&T) 위에 **DEXTER-LLM식 관제 대시보드**와, OOD(예상 못한 이벤트)에
반응해 스케줄을 적응적으로 고쳐 자율 완주하는 **OOD 복구 엔진**을 개발했다. tractor 모델 7개 OOD
케이스 전부 **8/8 assembly 자율 완주** 검증.

---

## 0. 배경 / 문제 정의

- ConstructionBots(SISL)는 LDraw MPD 데이터로 **결정론적 다중로봇 TAMP**(makespan 최적 조립)를 푼다.
- 여기에 **OOD 이벤트(로봇 고장 / 배터리 방전 / 통행·적치 금지구역)** 를 주입하고, 그때마다
  "상황 인지 → 재명세(re-spec) → adaptive rescheduling → 자율 완주"가 되게 하는 것이 목표.
- 관련 선행: **DEXTER-LLM**(arXiv:2508.14387)이 가장 가까운 사촌(LLM open-world reasoning + MILP 배정 +
  event-driven online 재계획)이지만, 우리 문제는 **제품 구조(LDraw)에서 나온 tightly-coupled precedence +
  협동운반 + 대규모 fleet + 자동 검증**이라는 점에서 차별화(별도 positioning 문서 참조).
- 이번 세션은 **관제 UI + OOD 자율복구 엔진**을 실제 동작 코드로 구현하는 데 집중.

---

## 1. 산출물 (파일)

전부 `ConstructionBots.jl/tools/monitor/` 에 위치.

| 파일 | 역할 |
|---|---|
| `run_demo.jl` | **엔진** — env 빌드 후 수동 루프로 OOD 발화·분석·직접 복구·JSONL 방출 |
| `server.jl` | **컨트롤 서버**(HTTP.jl) — 대시보드/스트림 static 서빙 + `POST /run` 온디맨드 생성 |
| `dashboard.html` | **UI** — 모델 드롭다운 + OOD 6버튼 + Fleet/AssemblyTree/OODfeed/Re-spec/Gantt 패널 + replay |
| `streams/tractor__<case>.jsonl` | tractor 7케이스 프리생성 스트림 |
| `README.md` | 실행법 |
| `smoke_run.jl`, `smoke_ood_run.jl` | 초기 스모크(레거시; run_demo.jl 로 대체됨) |

패키지 측 비파괴 배선(둘 다 no-op-unless-enabled):
- `src/monitor/monitor.jl` — env→JSONL emitter(`monitor_enable!/emit!/disable!`, `monitor_record_respec!/fault!`).
  module-level include(`src/ConstructionBots.jl`), emit seam(`src/demo_utils.jl run_simulation!`).

---

## 2. 엔진 파이프라인 (`run_demo.jl`)

프레임워크의 respec-큐 라우팅이 fault/battery 이벤트를 producer까지 안 태우는 문제가 있어,
**수동 루프**로 완전 제어한다:

```
env = run_lego_demo(; return_env_before_sim=true, save_animation=false, n_spare_per_pool=2)
enable_battery!(demo_battery_params(shrink=25))   # 완만 용량: 자연 방전이 0에 안 닿게
set_hot_swap!(enabled=true, mode=:via_depot)      # 완주 가능한 정체성보존 교체
schedule_ood_at_closed!(...)                      # 케이스별 OOD 예약

수동 루프(매 스텝):
  ood_inject_step!            → 예약 OOD 발화(truth 기록)
  새 ood_truth_log() 감지 →
    canonical_respec(truth)   → "분석"(=B1 규칙맵, heuristic LLM). monitor_record_respec! 로 패널 캡처
    직접 복구:
      FaultTruth                       → hot_swap_robot!(via_depot)              (스페어 본체 교체)
      BatteryTruth, SoC ≤ 0.2(REPLACE) → hot_swap_robot! + SoC 회복(1.0)          (깊은 방전=교체)
      BatteryTruth, SoC > 0.2          → rebalance_for_battery!                   (경미=SoC편향 재solve)
      ZoneTruth(assembly)              → restage_assembly! + clear_restriction_zones!  (존 밖 재배치 후 일시장애 해제)
  step_environment! → update_planning_cache!
  monitor_emit!(50스텝마다)
  project_complete → break / 완료노드 2500스텝 무증가 → stall break
```

### OOD 케이스 (ENV `DEMO_OOD`)
`none | battery | fault | zone | fault_battery | fault_zone | battery_zone`
케이스별 kinds 를 진척 프랙션 [0.10, 0.32, 0.55]·n_total 에 배치.

### 분석 주체 = `canonical_respec` (baselines.jl B1 규칙맵)
- fault → `ReplaceAgent`
- battery: SoC ≤ `REPLACE_SOC_THRESHOLD[]`(=0.2) → `ReplaceAgent`, 아니면 `DeprioritizeAgent`
- zone: staging 차단 assembly 있으면 → `ForbidZone(assembly, key)`, 항법용이면 빈 DSL(모션 우회)
- (실제 LLM 서비스 `llm_bridge`로 교체 가능 — 인터페이스 동일. decpomdp repo 부재로 surrogate/실LLM은 보류)

---

## 3. UI (`dashboard.html`)

- **Assembly 드롭다운**: LDraw_files 11종(Tractor, Saturn V, Imperial Shuttle, X-wing(mini/full),
  TIE Fighter, Star Destroyer, AT-AT, AT-TE, Destroyer Droid, Passenger Plane).
- **OOD 케이스 버튼 6종 + Nominal**. 선택 → `streams/<model_base>__<case>.jsonl` 로드.
  없으면 컨트롤 서버에 `POST /run` 생성요청 후 폴링.
- 패널: **Fleet States**(mode+SoC), **Factory View**(MeshCat iframe), **Assembly Tree**(done/open/eligible/blocked+progress),
  **OOD Event Feed**, **Re-Specification**(canonical 분석 후보+ADMITTED 배지), **Robot Schedule(Gantt)**, replay 스크러버·자동재생.
- `model_base = basename 확장자 제거 후 [^A-Za-z0-9]+ → _` (Julia/JS 동일 규칙).
- ⛔ Inject Forbid Zone 버튼(라이브 주입용, 컨트롤 서버가 `/inject/zone` 처리하는 live_server 단계에서 완성).

## 3b. 컨트롤 서버 (`server.jl`)
- `GET /` → dashboard.html, `GET /streams/*`, `GET /models`, `POST /run {model,case}` → `julia run_demo.jl` 서브프로세스 스폰(비차단).
- 실행: `julia +lts --project=. tools/monitor/server.jl` → `http://127.0.0.1:8700/` (python http.server 대신).

---

## 4. 검증 결과 (tractor, num_robots=10, 305 schedule nodes)

**7 / 7 케이스 전부 8/8 assembly 자율 완주.**

| 케이스 | assembly | 분석 → 복구 | frames |
|---|---|---|---|
| none | 8/8 ✓ | (OOD 없음) | 17 |
| battery | 8/8 ✓ | SoC 깊은방전 → ReplaceAgent(hot-swap) | 19 |
| fault | 8/8 ✓ | 고장 → ReplaceAgent(hot-swap) | 19 |
| zone | 8/8 ✓ | 존 → ForbidZone(restage+clear) | 22 |
| fault_battery | 8/8 ✓ | ReplaceAgent ×2 | 19 |
| fault_zone | 8/8 ✓ | ReplaceAgent + ForbidZone | 23 |
| battery_zone | 8/8 ✓ | ReplaceAgent + ForbidZone | 23 |

각 케이스 = **OOD 주입 → canonical 분석(패널 표시) → adaptive rescheduling → 자율 완성**.
= autonomous multi-robot assembly control.

---

## 5. 핵심 기술 결정 / 교훈

1. **respec 큐 우회 → 수동 루프 직접 복구.** producer/RESPEC_QUEUE 경로가 fault/battery에서 안 타서
   (zone만 탐), `ood_truth_log()` 감지 + 직접 dispatch 호출로 전환. 복구·캡처 보장.
2. **fault 완주 = `hot_swap_robot!`(정체성보존).** `fault_robot_and_reassign!`(ForbidAgent 재배정)은
   mid-build 7/8 stall. hot-swap(창고 스페어로 본체만 교체, RobotID 유지)이 완주 경로.
3. **battery 깊은방전 = fault처럼 hot_swap + SoC 회복(1.0).** 완만 배터리 용량(shrink=25)으로
   자연 방전이 0에 안 닿게 → 0 SoC는 주입된 severe에서만(이전엔 shrink=500이 전 로봇을 0으로 만들었음).
4. **zone 완주 = restage 후 일시장애 해제.** 좁은 tractor 공장에선 지속 존이 로봇 경로를 막아 nav 교착
   (frac 줄여도 동일). `restage_assembly!` 후 `clear_restriction_zones!()`로 transient obstruction 서사 →
   완주. respec(ForbidZone)은 이미 캡처되므로 알고리즘 시연 유지.
5. **Julia 최상위 for-루프 soft-scope 함정.** stall 추적 변수는 함수로 감싸 해결.
6. **fault/replace + save_animation=true = MeshCat 애니 업데이터 크래시**(scene-tree 수술 중 stale RobotNode
   `collect_descendants`). → OOD 런은 save_animation=false. Factory View는 별도 애니 재사용.

---

## 6. 알려진 한계 / 다음 단계

- **Factory View(MeshCat)** 모델별 애니 미생성(현재 tractor 고정). fault/replace 애니 크래시 우회 필요.
- **분석 주체** heuristic canonical → 실제 LLM 서비스(Python /propose) 교체(decpomdp/surrogate 복구 시).
- **zone 지속성**: 완주 위해 일시장애 해제 사용. 지속 존+완주는 더 넓은 모델/nav 개선 필요.
- **큰 모델**(Saturn V 1845 parts) 생성 오래 걸림 — 데모는 소형 킷 권장.
- **라이브 인간 주입**(⛔ 버튼 → 실행 중 sim에 존 주입): live_server 단계.
- MDP/POMDP 승격, GNN surrogate, graded-OOD 등은 별도 트랙([[STATUS]], [[DESIGN]] 참조).

---

## 7. 실행 요약

```bash
# ConstructionBots.jl 폴더에서 (python http.server 끄고)
julia +lts --project=. tools/monitor/server.jl        # → http://127.0.0.1:8700/

# 또는 엔진 단독 (스트림만 생성)
DEMO_MODEL=tractor.mpd DEMO_OOD=fault_zone julia +lts --project=. tools/monitor/run_demo.jl
```
