# LLM Safety Layer — Improvements over SISL ConstructionBots & Self‑Evolution Roadmap
**2026-06-27 · self-directed proposal**

연구 비전: *Safe Agentic AI for Multi-Robot Manufacturing Task Planning* (research_proposal_1pager.md).
3 기둥 = **Orchestrate / Verify(★) / Scale & Recover**. 이 문서는 지금까지 만든 LLM 안전 레이어(`src/respec/`)가
원본 ConstructionBots(SISL, RAS 2025) 대비 **무엇을 개선했는지**와, **안전·효율·비용 축에서 어떻게 더 진화시킬지**를
구체적 코드 앵커와 함께 제안한다.

---

## 0. 한 줄 요약

원본 CB는 **정적 TAMP**(계획 1회 계산→개루프 실행)다. 우리가 추가한 `respec/` 레이어는 **런타임 open-world 이벤트**를
자연어로 받아 **닫힌 DSL로 번역→형식 검증 게이트→부분 재명세(과거 불변)→안전 재개**하는 **neuro-symbolic 폐루프**다.
핵심 가치는 성능이 아니라 **신뢰성·유연성·실패복구**(제안서 §핵심 차별점). 두 OOD 데모(1-2 ForbidZone, 1-1 robot
breakdown)가 이 루프를 실증한다.

---

## Part A — 원본 ConstructionBots(SISL) 대비 개선점

### A.0 원본의 구조와 한계
- **계획**: assembly tree → MILP/greedy task allocation → RVO/TangentBug motion. **계획은 빌드 시작 전 1회** 계산.
- **실행**: 개루프. 런타임에 환경이 바뀌면(로봇 고장, 새 금지구역, 부품 위치 변화) **반영 경로가 없다.**
- **인터페이스**: 자연어 spec 불가. 제약 추가/변경은 코드 수정·전체 재최적화.
- **실패**: 로봇 1대 고장 = 전체 재계획(비쌈) 또는 정지. 부분 상태(이미 한 작업) 보존 재계획 메커니즘 없음.

### A.1 우리가 추가한 것 = "Verify 기둥" PoC (`src/respec/`)
파이프라인: **NL 이벤트 → `push_ood!` → `maybe_respecify!`([replan.jl:145](../replan.jl)) → llm_to_proposal(닫힌 DSL)
→ verify 게이트([verifier.jl](../verifier.jl)) → 전용 enactment → `reset_cache_resume!`(과거 보존 재개)**.

원본 대비 **6가지 안전 속성**을 새로 보장한다:

| # | 속성 | 메커니즘 | 코드 앵커 |
|---|---|---|---|
| **P1** | LLM은 **objective를 못 바꾼다** | 닫힌 `ConstraintSpec` DSL(추가 제약만). 구조적으로 불가능 | [spec_dsl.jl](../spec_dsl.jl) |
| **P2** | **실행 전 hard-constraint 검증** | GRAMMAR→STATIC→FEASIBLE→invariant 게이트, TOCTOU 없음(검증=실행 동일 모델) | [verifier.jl:65](../verifier.jl) |
| **P3** | **과거는 불변** | 완료/진행 노드 시각 freeze → 재계획은 **미래만** | `build_invariant`([verifier.jl:215](../verifier.jl)) |
| **P4** | **fail-closed** | 모든 reject/throw → 안전 정지(line-stop) | `engage_fallback!`→`RESPEC_HOLD`([replan.jl:412](../replan.jl)) |
| **P5** | **LLM 환각 비신뢰**: 공간/자원 선택은 **기하가 권위** | spare=`nearest_pool`(Julia), zone 존재는 `RESTRICTION_ZONES`가 권위 | [verifier.jl:122,153](../verifier.jl) |
| **P6** | **크래시 격리** | LLM은 별도 Python 프로세스(HTTP). 멈춘 LLM이 sim을 못 죽임 | [llm_service/](../llm_service/) |

**요지**: 원본은 "계획이 옳다고 믿고 실행"이고, 우리는 "**실행되는 모든 재명세는 안전 불변식을 절대 위반하지 않음**을
게이트가 보장"(thesis statement 그대로). LLM은 *유연한 번역기*일 뿐, **안전의 출처는 LLM이 아니라 verifier**.

### A.2 부분 재명세(전체 재최적화 회피)
- ForbidZone: MILP 재solve 없이 **기하 수술**(staging 이동, `translate_whole_build!`)로 복구 → 빠르고 과거 보존.
- ReplaceAgent: MILP 없이 **그래프 수술**(빈 spare chain에 1:1 인계) → 재배정 double-booking 우회.
- 둘 다 **admissible-but-unrecoverable면 fail-closed**(dispatch가 `:infeasible`/`:no_spare` 보고→fallback).

---

## Part B — 두 OOD 데모가 증명하는 것

| 데모 | OOD 클래스 | NL→DSL | enactment | 증명 |
|---|---|---|---|---|
| **1-2** | 공간 no-go zone | `ForbidZone` | restage(조립체 평행이동) | 공간 제약을 안전하게 흡수, nav-ON 완주 |
| **1-1** | 로봇 고장 | `ReplaceAgent` | nearest spare 1:1 인계 | 자원 실패를 백업으로 복구, 단일 task 완주·무크래시 |

이로써 **서로 다른 두 OOD 양상(공간 vs 자원)**이 *동일한* Orchestrate→Verify→Recover 루프로 처리됨을 보였다.
이것이 Y1 Gate "위반/이벤트를 넣으면 검증층이 잡고 안전하게 처리"의 실증이다.

---

## Part C — 자기진화 로드맵 (Safety / Efficiency / Cost)

각 항목: **무엇 · 왜 · 어떻게(코드 수준) · 우선순위(P0 즉시 / P1 / P2)**.

### C.1 SAFETY (★ 논문 심장 — C2 기여)

- **S1 (P1) 형식 spec 언어로 invariant 승격 (LTL/STL).**
  현재 invariant는 ad-hoc Julia 술어(시각 freeze)뿐([verifier.jl:185](../verifier.jl)). 제안서가 명시한 LTL/PDDL/STL로
  *충돌-자유·선후관계·deadlock-freedom·도달가능성*을 형식화하고 candidate MILP 해에 대해 model-check.
  → "안전 정의 v1"(year1_plan Q2)·"runtime shielding"(Y3)의 토대.

- **S2 (P0) Sandbox-simulate-before-commit (recoverability 게이트).**
  현재 verify는 *feasibility*만 본다; **recoverability**(인계가 실제로 완주되는가)는 dispatch에서야 드러난다
  — 이번 세션의 #2 다팀 stall이 그 증거. **제안**: admit 후 enact 전에 **경량 fast-forward 시뮬**(N step, RVO off)을
  돌려 진행도가 늘면 commit, 아니면 reject→fallback. 이러면 "admissible-but-unrecoverable"를 *실행 전에* 차단.
  → verify를 feasibility→**feasibility+recoverability**로 강화. (가장 큰 안전 갭을 닫음.)

- **S3 (P1) 적대적 검증 / 다중-LLM 합의.**
  단일 LLM 환각 완화: N개 제안을 뽑아 다수결, 또는 "critic" 패스가 제안을 **반박 시도**(refute). verify가 이미
  fail-closed라 비용 대비 안전 이득이 큼. (이번 세션의 ForbidZone 과분류 같은 오분류를 합의로 거른다.)

- **S4 (P1) 신뢰도-게이트 인간 위임 (3-tier fallback).**
  현재 fallback은 line-stop 1단계. 추가: verify가 K회 reject 또는 LLM self-confidence 낮음 → **human/solver 위임**
  (제안서 "불확실 시 human/solver로 위임"). 위임 큐 + UI 훅.

- **S5 (P1) Invariant 확장 — 충돌·deadlock·도달가능성 certificate.**
  `InvariantSpec`에 forbidden-region 술어·reachability 인증서 필드 추가([verifier.jl:32 주석이 이미 예고](../verifier.jl)).
  candidate 해가 *팀 동시-통과 corridor 충돌*·*순환 대기(deadlock)*를 만들면 reject.

- **S6 (P0·완료지향) Provenance/audit 로그 형식화.**
  데모의 RESPEC 로그 패널은 이미 NL→DSL→verdict→enactment를 기록. 이를 **구조화 감사로그**(JSONL: event, proposal,
  verdict, rationale, enactment, outcome)로 표준화 → 안전 메트릭(제약위반 횟수)·재현성·디버깅의 1급 자산.

### C.2 EFFICIENCY (C3 — scale & recover)

- **E1 (P0) #2 다팀 인계 완주 — 동적 직렬화. ✅ 구현·sim검증(부분).**
  resume 루프에서 robot이 동시 active 운반-task(succ=FTU) ≥2면 t0순으로 `deposit_i→slot_{i+1}` 체인 →
  reset_cache_resume!로 나머지 defer (`_enforce_serial_frontiers!`, replace_robot.jl). 매 스텝 호출,
  멱등(cycle 가드), 정상빌드 무동작.
  **검증(spare_replace_test, DYN_SERIAL=1, R2):** spare 동시-active RobotGo **2→1**(double-booking 제거),
  완주 **235→246**/305, 무크래시. clear=true(고장로봇 치움) 조합도 동일 246.
  **잔여(별개·더 어려움):** spare가 **early-t0 task를 늦은 혼잡 빌드에서** 수행하려다 RVO **네비게이션
  gridlock**(spare dist 1.92 정지). = 'scale & recover'(Y4)급 문제. 다음 후보:
  ① 직렬화 순서를 t0 대신 **readiness**(co-carrier 대기 중인 FTU 우선)로, ② 팀 경계 인계 제한.

- **E2 (P1) Incremental verify (warm-start + 캐시).**
  verify의 MILP는 이미 `warm_start_soln` 지원([verifier.jl:90](../verifier.jl)). 고장 직전 배정을 warm-start로 주입,
  OOD 간 MILP 해 캐시 → feasibility 게이트 비용↓.

- **E3 (P0) 제안 캐싱/메모이제이션.**
  동일·유사 OOD(같은 고장 유형)는 **DSL이 거의 결정적**(breakdown→ReplaceAgent(agent)). 이벤트 정규형 키로 캐시 →
  **LLM 호출 자체를 건너뜀**. `llm_bridge.jl`에 (event-template, grounded-ids)→proposal LRU 캐시. 비용·지연 동시 절감.

- **E4 (P1) 비동기 non-blocking respec.**
  LLM HTTP 호출이 sim step을 블록. `RESPEC_HOLD`(이미 존재)로 **호출 중 안전 line-stop**, 완료 시 재개 → 결정성 유지하며
  체감 지연 제거. (sim은 멈춰 안전, LLM은 백그라운드.)

- **E5 (P2) 계층적 국소 재명세.**
  Saturn V 수천 부품 스케일: OOD를 **영향받은 sub-assembly/영역에 국소화**해 재명세(전역 아님) → 확장성.

### C.3 COST (LLM API 비용)

- **K1 (P0) Tiered model cascade (cheap→escalate).**
  대부분 OOD는 단순 분류(어느 DSL kind인가). **Haiku로 1차 분류**, 불확실/verify reject 시에만 **Opus로 에스컬레이트**.
  `propose.py`의 `_MODEL`을 단일→캐스케이드로. 흔한 case(breakdown→ReplaceAgent)는 소형 모델로 충분 → 비용 ~10× 절감.

- **K2 (P1) 로컬 distilled 모델.**
  OOD eval 하니스가 (NL→DSL) 쌍을 대량 생성 가능(ood_generation). 이를 **소형 로컬 모델에 distill** →
  흔한 case는 API·지연 0. 롱테일만 클라우드. (자기진화 루프 C.4의 핵심.)

- **K3 (P1) 프롬프트 압축.**
  현재 프롬프트는 **모든 open_ids를 exhaustive**하게 보냄([propose.py:84](../llm_service/propose.py)). 영향 영역의
  관련 부분집합만 전송 → 토큰↓. zone/agent/node 디스크립터도 관련분만.

- **K4 (P0·저위험) Anthropic prompt caching.**
  tool schema·정적 프롬프트 프리픽스는 고정 → **prompt caching**으로 입력 토큰 비용↓(코드 1줄: cache_control).

- **K5 (P2) 배치 eval.**
  Y3 평가("어느 OOD 클래스를 LLM이 신뢰성 있게 번역?")는 Batch API로 → 평가 비용↓.

### C.4 ★ 자기진화 폐루프 (cross-cutting — "self-evolved"의 핵심)

> **verifier의 accept/reject + sandbox-sim(S2) 결과 = 학습 신호.**

1. **생성**: ood_generation이 OOD 시나리오를 자동 합성(커리큘럼).
2. **번역**: 캐스케이드/로컬 모델이 NL→DSL.
3. **판정**: verify 게이트 + S2 sandbox-sim이 admit/reject/recoverable 라벨 부여(**무료·자동 라벨러**).
4. **증류**: (NL, DSL, verdict, outcome)을 로컬 모델에 rejection-sampling/SFT로 학습 →
   *모든 거부가 모델을 가르친다*.
5. **반복**: completeness critic이 "아직 못 푸는 OOD 클래스"를 찾아 1로 피드백.

이 루프는 **안전(검증이 라벨러)·효율(완주율↑)·비용(로컬화)** 세 축을 *동시에* 끌어올린다. 검증층이 곧
**자기지도 학습의 oracle**이 되는 것이 이 프레임워크의 차별점.

---

## Part D — 우선순위 & 다음 행동

**P0(즉시·고가치)**: E1(다팀 완주), S2(recoverability 게이트), E3(제안 캐싱), K1(model cascade), K4(prompt cache), S6(감사로그).
**P1**: S1(LTL/STL), S3(다중-LLM), S4(human 위임), E2/E4, K2(distill)/K3.
**P2**: S5/E5/K5.

**추천 다음 스텝 (이번 세션 검증으로 좁혀진 frontier 기준)**
1. **완주의 마지막 1겹 = 일반 MRTA 협조** (V1~V5로 스페어는 완전 통합됨; 남은 건 *healthy* 로봇이 team=4
   carry에 동시도착 못 함). 후보: ① 인계 후 영향받은 팀의 **부분 재동기**(R15 포함 멤버 timing 재배치),
   ② team-size>2 의 "전원 동시 capture" 제약을 **순차 capture 허용**으로 완화(route_planning.jl:480-488).
   → S2(sandbox recoverability 게이트)와 묶으면, 못 풀리는 잔여는 admit 단계에서 reject→안전 fallback.
2. **K1 + E3** — Python 서비스 캐스케이드(Haiku→Opus) + Julia 제안 캐시. 비용·지연 절감(실 키 필요, sim-proxy로 검증).

코드 앵커는 아래. 모두 기존 fail-closed·verify 구조에 얹힌다.

---

## Part E — 이번 세션 SIM-검증 결과 (proposal은 구현+시뮬 검증으로만 인정)

각 항목은 ConstructionBots를 **실제로 시뮬레이션 실행**해 측정·확인했다(코드 변경 + sim 증거).

| # | 자기진화 항목 | 축 | 구현 | **SIM 검증 증거** |
|---|---|---|---|---|
| V1 | **RVO-map 구동 가드** (route_planning.jl ×3) | 안전 | active RobotGo의 로봇이 RVO map에 없으면(captured/미등록) 구동·스왑·assert를 skip | 결정적 R2/R1 고장: 이전 `rvo_get_agent_idx BoundsError[-1]` **크래시** → **graceful stall**(R1 219). **CONTROL(무고장) 완주 287/305 무회귀.** 모든 fault 타깃 무크래시 |
| V2 | **transform-binding fix** (`_restamp_robot_go!`) | 완주 | re-stamp가 스페어의 **scene-linked 정식 RobotNode**(reassign.jl 패턴) 사용 → `feeder_at_goal`이 live 스페어 추적 | solo FTU 완주(이전 영구 stall), 진행 **207→235** |
| V3 | **E1 동적 직렬화** (`_enforce_serial_frontiers!`) | 효율 | resume 매 스텝 "robot당 active 운반-task 1개" 재강제 | spare 동시-active RobotGo **2→1**(double-booking 제거), 완주 **235→246** |
| V4 | **데모 순수 spare 교체** (ood_injection/replan/demo) | 정확성 | `obstacle=false`(zone 미등록→LLM ForbidZone 과분류 차단, 빨간원 제거) + `clear=true`(고장로봇 화면밖 견인); `_robot_position_2d`는 기록된 고장위치 사용 | mock 데모 로그: 제안 **`[ReplaceAgent]`만**(이전 `[ReplaceAgent,ForbidZone×3]`), **"cleared its body"**, ADMITTED replace, 무크래시, HTML 생성 |
| V5 | **복구 스페어 RVO 우선순위** (`RECOVERY_SPARES`+`set_rvo_priority!` α=0.02) | 효율 | 스페어가 out-of-order task로 혼잡한 늦은 빌드를 통과해야 함 → 최고 우선순위로 남이 양보(가드: 활성 formation α=0.0엔 양보) | 스페어가 **gridlock 뚫고 제 위치 도달**(in_capture=true, dist 0.0), 완주 **246→254**, 무크래시 |
| **V6** | **team-straggler RVO 우선순위** (`set_rvo_priority!` α=0.03, TEAM_PRIORITY) | 효율/완주 | 다로봇 FTU는 **전원 동시 위치** 필요 → 일부가 먼저 와서 대기하면 **마지막 straggler의 경로를 막아** 팀이 영영 못 형성. straggler(팀 멤버 ≥1명 이미 in_capture인데 본인은 아직)에게 최고 우선순위 부여 | **deadlock 깨짐 → tractor early fault(closed=24, 실제 인계 4 task) 빌드 완주 288/305 `:complete`**, **spare_replace_test 11/11 GREEN** |

**누적 검증 궤적(각 단계 sim 측정):** 207 →(V2)→ 235 →(V3)→ 246 →(V5)→ 254 →(**V6**)→ **288/305 `:complete`**.
각 self-evolution이 **블로커를 한 겹씩 제거**해 마침내 완주: ① 스페어 개별 task 미작동(V2) → ② 스페어 double-booking(V3) → ③ 스페어 네비 gridlock(V5) → ④ **다로봇 팀 straggler가 대기 멤버에 막힘**(V6, route_planning.jl:480-488 "전원 동시 capture" 교착) → **완주**.
**= "로봇 고장 → 가장 가까운 spare 1:1 인계 → manufacturing 완주"가 tractor에서 sim 검증됨**(early fault, 실제 인계). 잔여: 더 이른/조밀한 동시-다팀 인계는 cyclic cargo-dependency가 남을 수 있음(re-timing은 future work).

**검증되지 않은(= 아직 제안 단계, 구현·검증 대기) 항목:** S1·S2·S3·S4·S5·S6, E2·E3·E4·E5, K1~K5.
이들은 다음에 **각각 구현→sim 실행→측정**으로 검증해야 인정. (특히 비용 항목 K1/K2/K4는 실 ANTHROPIC_API_KEY 필요 → sim-proxy 또는 키 주입 후 검증.)

**자기진화 폐루프 관점(C.4):** V1~V4는 모두 **verifier/sim이 라벨러**가 되어(크래시↔graceful, stall↔완주, 진행도) 다음 개선의
신호를 준 사례다 — "verifier가 자기지도 학습 oracle" 가설의 소규모 실증.

---

## Appendix — 코드 앵커
- 게이트: [verifier.jl](../verifier.jl) (`verify`/`verify_zone`/`verify_replace`/`build_invariant`/`satisfies_invariant`)
- 디스패치/fallback: [replan.jl](../replan.jl) (`maybe_respecify!`/`engage_fallback!`/`RESPEC_HOLD`)
- DSL: [spec_dsl.jl](../spec_dsl.jl) · 브리지: [llm_bridge.jl](../llm_bridge.jl) · 서비스: [llm_service/propose.py](../llm_service/propose.py)
- enactment: [restage_zone.jl](../restage_zone.jl)(1-2) · [replace_robot.jl](../replace_robot.jl)(1-1)
- 데모: [tools/demo_respec_replace_anim.jl](../../../tools/demo_respec_replace_anim.jl)
