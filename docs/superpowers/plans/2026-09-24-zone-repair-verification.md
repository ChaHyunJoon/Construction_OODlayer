# 존 기하 복구와 완주 보존 검증기 — 구현 계획

작성: 2026-09-24

상태: **계획 작성 완료 / 구현 및 실험 미실행**. 아래 체크박스는 구현 완료 증거를 확보한 뒤 체크한다.

설계 기준: [존 기하 복구와 완주 보존 검증기 설계](../specs/2026-09-24-zone-repair-verification-design.md).

## 목표

모델이 직접 목표 기하를 옮겨 성공한 4판의 방법을 일반화하고, NOOP로 완주하던 판을 모델 개입으로 실패시키는 회귀를 차단한다.

실행 구조:

```text
존 주입 후·모델 호출 전 전체 상태 보존
  → 모델의 GeometryPatch 후보 생성·동결
  → 동일 상태의 격리 프로세스에서 NOOP / 각 후보를 끝까지 실행
  → NOOP 완주면 NOOP 유지
  → NOOP 실패 + 유효한 후보 완주면 그 후보만 채택
  → 원래 상태에 동일 transaction 적용·후속 실행 재현 확인
```

**CBF는 도입하지 않는다.** 작업 범위는 checkpoint, 기하 변경 transaction과 resync, 전체 후속 실행 비교, 채택·재현 검증이다.

## 고정 계약

- 존 NOOP는 정상 주행·스케줄 실행을 계속하는 정책이다. 기존 ablation의 `none` 팔과 구분한다.
- 모델이 목적지와 이동량을 계산한다. 실행기에 존 복구 해법기나 목적지 최적화기를 추가하지 않는다.
- V1의 모델 출력은 XY 평행이동을 담는 declarative `GeometryPatch`다. 임의 body는 역사적 재생용 worker에서만 실행한다.
- task/edge 삭제·추가, closed/active 직접 쓰기, zone 변경, 물리 로봇 pose 변경, scorer 변경, 모델의 simulation step 호출을 금지한다.
- 전체 완료 조건은 수정 전의 필수 작업과 조립 관계에서 나온다. 변경된 목표 자체를 성공의 유일한 기준으로 삼지 않는다.
- `nav_blocked=0`, 존 해소, 잠깐의 progress는 완주를 대체하지 않는다.
- 한 episode에서 최대 한 repair transaction을 채택한다. 이후 존은 NOOP, fault/battery와 일반 복구는 공통 정책을 따른다.
- 후보는 기본 K=4, 모델 호출은 최초 포함 최대 4회다. schema 재시도·재작성도 모델 호출 예산에 포함한다.
- 후속 모델 호출에 제공하는 피드백은 정적/transaction 검사 결과뿐이다. NOOP 결과·미래 사건·전체 rollout 결과는 모델에게 제공하지 않는다.
- 분기마다 원래 episode의 절대 simulation 예산을 유지한다. worker wall timeout과 인프라 오류는 `UNKNOWN`으로 분리한다.
- 정확한 상태 복원과 후속 실행 재현이 확인되지 않으면 인증 모드를 활성화하지 않는다.
- 최종 상태를 shadow에서 복사하지 않는다. 원래 시점에 검증한 patch만 적용한다.
- 역사적 4/13/27 코호트와 새 코드의 같은-checkpoint 결과를 별도 보고한다. timeout·missing을 계획 분모에서 빼지 않는다.
- 이번 문서 작성은 구현·서비스 재시작·모델 호출·sweep 실행을 포함하지 않는다.

## 작업 순서와 의존성

| 작업 | 산출물 | 선행 작업 |
|---|---|---|
| T0 | 역사적 코호트와 실행 body 연결 | 없음 |
| T1 | 타입·schema·실험 manifest | T0 |
| T2 | 전체 상태 capture/export/import | T1 |
| T3 | native 상태·난수·사건 복원과 동일성 검증 | T2 |
| T4 | 격리 branch worker와 전체 runtime 실행 | T3 |
| T5 | 기하 patch 검증과 원본 task contract | T1 |
| T6 | 원자적 적용·필수 resync·후처리 | T3, T5 |
| T7 | 선택기·certificate·커밋 | T4, T6 |
| T8 | 실제 존 사건 경로 연결 | T7 |
| T9 | 모델 proposal 경로와 후보 예산 | T1, T5, T6 |
| T10 | 회귀·고장 주입·역사적 재생 검증 | T8, T9 |
| T11 | 모델 실험·paired 평가·결과 보고 | T10 |

의존성을 통과한 작업부터 진행한다. T2–T4의 상태 복원 검증이 가장 먼저 해결할 기술적 위험이다.

## T0. 역사적 코호트와 실제 실행 body 고정

입력:

- `results/2026-09-23-baseline-free/README.md`와 해당 source snapshot/campaign 원장.
- `results/2026-09-23-repair-ablation/README.md`, 실행 원장·streams·sweep 결과.

제안 파일:

- `tools/monitor/build_repair_cohort.py`
- `test/fixtures/repair_verification/cohort.json`
- `test/fixtures/repair_verification/legacy/`의 body chain·출처 manifest.

작업:

- [ ] `(model, scenario, seed, zone_seed)`로 canonical/A2 결과를 join하고 source/config 지문도 저장한다.
- [ ] `run_ctx`, `record_id`, `parent_record_id`, rewrite 차수, 실제 집행 기록을 연결한다. 마지막 함수명 일치 행을 실행 body로 대체하지 않는다.
- [ ] easy 27, hard 93, A2 easy-success 14, regression 13, rescue 4의 membership을 추출한다. 미관측·timeout을 별도 기록한다.
- [ ] rescue anchor를 고정한다: tractor all3 s2, tractor zone s5, tractor zone s16, X-wing zone s4.
- [ ] 각 anchor의 setter 대상·변환·resync·cache 조작·step 호출을 기록하고 원래 조립 의미를 감사한다.
- [ ] 역사적 source snapshot 복원이 가능한지 확인하고, 코드/prefix 차이 때문에 동일 세계라고 할 수 없는 항목을 표시한다.

통과 조건: membership과 실제 body 출처를 기계적으로 추적할 수 있다. 수가 다르면 원인을 보고하고 기존 4/13/27 분류를 조용히 덮어쓰지 않는다. 과거 complete가 원본 작업 조건을 위반하면 별도 오류로 남긴다.

## T1. 타입, 상태 전이, 실험 manifest 정의

제안 파일:

- `src/verification/repair_types.jl`
- `src/respec/llm_service/geometry_patch.schema.json`
- `tools/monitor/grid/repair_verification_manifest.schema.json`
- `test/repair_contracts.jl`

작업:

- [ ] `EpisodeCheckpoint`, `GeometryPatch`, `ValidationReport`, `TransactionReport`, `RolloutReport`, `SelectionReport`, `CommitReport`를 정의한다.
- [ ] patch에는 checkpoint/proposal ID, semantic config reference, expected-before, desired-global, 설명을 포함한다. 좌표 단위와 수치 transform 표현을 고정한다.
- [ ] 결과를 `COMPLETE`, `FAIL_WITHIN_BUDGET`, `UNKNOWN`으로 구분하고, patch 기각·no-op·인증 불가는 별도 원인 코드로 보존한다.
- [ ] manifest에 source snapshot·dirty digest·Julia/Manifest/build·solver·thread·model/service·prompt/schema 지문을 넣는다.
- [ ] episode simulation-step/시간 상한, terminal stall 설정, worker wall 예산, 총 token·비용 상한, 후보/호출 한도를 필수 필드로 둔다. 기존 campaign에서 확인한 값과 새 선택값을 구분한다.
- [ ] 모든 팔이 사용할 후속 정책 `pi0`, 사건 생성 규칙, 존 solver/사다리 차단 설정을 명시한다.
- [ ] 위치 허용 범위와 수치 tolerance를 기존 workspace·pickup/capture 판정에서 확인해 수치로 manifest에 고정한다. 필수 값 누락은 실행 오류로 처리한다.
- [ ] 미래 난수/NOOP 결과/certificate를 모델 관측 schema에서 제외한다.

통과 조건: invalid schema, NaN, stale ID, 금지 필드, 비어 있는 예산을 조용히 보정하지 않고 거절한다. 새 schema는 역사적 body 재생과 혼용되지 않는다.

## T2. 전체 checkpoint capture/export/import 구현

제안 파일:

- `src/verification/episode_checkpoint.jl`
- `test/repair_checkpoint.jl`

참고: `src/smdp/state_globals.jl`, `src/smdp/simstate.jl`, `src/smdp/generative.jl`. 이 모듈들을 그대로 전체 snapshot으로 간주하거나 부작용을 확인하지 않고 production에 통째로 include하지 않는다.

작업:

- [ ] task contract, 전체 sched/scene/transform tree, alias, attachments, cache, 시간, progress/stall 상태를 inventory에 올린다.
- [ ] zone/fault/spare/battery/delivery, ID counters, 복구 budget, hold latch, route 내부 상태와 runtime의 모듈 밖 상태를 포함한다.
- [ ] env와 관련 전역을 하나의 객체 그래프로 복제해 공유 참조를 보존한다.
- [ ] pending event, dispatch cursor, retry closure 상태, RNG/hazard 누적값·threshold를 명시적으로 저장한다.
- [ ] 외부 핸들·closure 등 직렬화 불가능한 항목은 명시적 adapter를 만든다. 누락 상태는 인증 불가로 처리한다.
- [ ] capture/read-only audit가 원래 세계와 RNG를 바꾸지 않는지 검사한다.
- [ ] exact artifact digest와 필드별 차이를 출력한다. 축약 `state_hash`나 반올림 좌표 해시를 전체 동일성 증거로 쓰지 않는다.

통과 조건: 각 동역학 관련 필드가 어디에 저장·복원되는지 inventory로 설명된다. 원본을 바꿨다가 복원해 graph/queue/RNG/alias가 일치하고 수치 상태가 고정 tolerance를 만족한다.

## T3. RVO·외생 난수·사건 경계의 재현성 확보

대상 파일:

- `src/verification/episode_checkpoint.jl`
- 필요 시 `src/rvo_interface.jl`의 native export/import adapter.
- `src/verification/episode_replay.jl`(신규)
- `test/repair_checkpoint_replay.jl`

작업:

- [ ] RVO agent identity/order, 위치·실제 속도·preferred velocity, 반지름·priority, 장애물, 시계·파라미터를 export/import한다.
- [ ] 기존 `rvo_rebuild!`가 지우는 동적 정보를 확인한다. 위치 일치만으로 복원 성공이라 하지 않는다.
- [ ] 첫 존 주입과 기존 enforcement 후, 그 사건의 모델 호출 전 hook을 `t0`로 고정한다. 실제 호출 경로에서 순서를 확인하고 dispatch cursor와 함께 저장한다.
- [ ] 존 주입 전/후 상태를 보존하고, worker 재개 시 중복 주입·중복 dispatch를 막는다.
- [ ] 난수 원천을 episode/event/entity/occurrence별로 결합한다. state-dependent 사건의 시각·대상은 각 분기 상태에서 계산한다.
- [ ] 새 난수 adapter가 역사적 세계를 바꾸면 새 replay 버전으로 표시한다.
- [ ] 동일 빌드·solver 설정에서 원본 NOOP 실행과 export/import 후 NOOP 실행을 **전체 종료까지** 비교한다.

통과 조건: easy/hard × robot/TU × zone/all3에서 해당되는 상태를 포함한 fixture가 원본 후속 실행을 재현한다. 두 복원 분기끼리만 일치하는 시험으로 대체하지 않는다. 반복 실행의 종료 결과가 갈리면 인증 모드는 비활성 상태를 유지한다.

## T4. 별도 프로세스 branch worker와 전체 rollout

제안 파일:

- `tools/monitor/repair_branch_worker.jl`
- `src/verification/branch_runner.jl`
- `test/repair_branch_isolation.jl`
- `test/repair_rollout.jl`

작업:

- [ ] branch마다 독립 프로세스·출력 디렉터리·원장 namespace를 사용한다. 동일 프로세스의 RVO 전역을 공유하지 않는다.
- [ ] 주 세계는 tick 없이 `t0`에 머문다. 검증 대기를 위해 `RESPEC_HOLD`나 진행 카운터를 변경하지 않는다.
- [ ] production과 동일한 step/cache/event/terminal 순서를 호출하는 runtime continuation을 분리·재사용한다. 별도 간이 simulator를 만들지 않는다.
- [ ] `pi0`의 존 NOOP, 공통 fault/battery/일반 복구, 존 전용 solver/사다리 차단을 branch마다 확인한다.
- [ ] 원래 episode의 남은 예산으로 종료하고, wall timeout·worker crash·solver 오류는 원인이 있는 `UNKNOWN`으로 남긴다.
- [ ] 예산 중단 시 worker와 그 하위 프로세스를 정리하고 parent 상태를 검사한다.
- [ ] A가 RVO/zone/cache/spare/ID/RNG를 변경해도 parent와 B의 trajectory가 바뀌지 않는지 시험한다.
- [ ] N→A와 A→N 순서를 바꿔 같은 결과를 얻는지 확인한다.

통과 조건: NOOP rollout은 원본 runtime과 같고, 후보 오류와 실행 순서가 다른 세계를 오염시키지 않는다. shadow 실행이 실제 원장·서비스 호출 수·실제 episode 비용을 중복 기록하지 않는다.

## T5. GeometryPatch와 원본 작업 조건 검증

제안 파일:

- `src/respec/geometry_patch.jl`
- `src/verification/task_contract.jl`
- `test/repair_geometry_patch.jl`
- `test/repair_task_contract.jl`

작업:

- [ ] semantic reference를 checkpoint 내부 ID와 config 객체로 해석한다.
- [ ] XY 이동만 허용하고 회전/Z, expected-before, workspace 범위, 수치 유한성을 검사한다.
- [ ] alias/상속 관계를 따라 최종 global transform의 충돌과 실제 영향 범위를 계산한다.
- [ ] 원본 필수 작업·부품·선후 관계·assembly 상대 기하·attachment를 모델 제안과 독립적으로 저장한다.
- [ ] pickup/deposit/lift 연결과 완료된 구조의 정합성을 검사한다. 모델이 `preserve_relative`를 생략해도 보호 관계는 유지한다.
- [ ] task/edge/closed/zone/로봇 pose/scorer 변경은 schema와 실제 diff 양쪽에서 차단한다.
- [ ] 실제 변경 없는 patch는 `noop_equivalent`로 분류한다.
- [ ] 존·항법 센서 결과를 기록하되 full-scene collision validator와 동일시하지 않는다.
- [ ] `nav_blocked >= 2` 또는 robot target을 일괄 거절하는 규칙을 넣지 않는다.

통과 조건: task 삭제, goal=start 변경만으로 얻은 허위 complete, alias 충돌, 미지원 물리 이동을 검출한다. 관계없는 blocked goal이 남았다는 이유만으로 유효한 작업을 제거하거나 전체 기하를 강제 이동하지 않는다.

## T6. 원자적 적용, 필수 resync, 공통 후처리

대상 파일:

- `src/respec/geometry_transaction.jl`(신규)
- `src/respec/zone_facts.jl`, `src/respec/restage_zone.jl`
- `src/respec/minted_tool.jl`, `src/respec/common_resolve.jl`의 실제 후처리 경로.
- `test/repair_geometry_transaction.jl`
- `test/repair_resync.jl`

작업:

- [ ] `validate → setters → diff/contract → resync → cache/preprocess/resolve → RVO 갱신 → postcondition` 순서를 구현한다.
- [ ] 상속 관계를 고려해 setter를 적용하고 최종 global transform이 선언값과 일치하는지 확인한다.
- [ ] 기하 변경이 있으면 필요한 resync를 실행기가 수행한다. empty/no-op patch에는 불필요한 scene 수정이 없어야 한다.
- [ ] 이동된 free 본체와 TU의 실제 잔차를 검사한다. 로봇을 목표로 snap하거나 잡힌 cargo를 free object로 처리하지 않는다.
- [ ] 현재 helper가 tolerance 때문에 남기는 작은 drift와 관련 없는 기존 drift를 시험한다. 영향 범위 밖 이동은 기각한다.
- [ ] 필요하면 helper에 대상·tol·이동 보고 옵션을 추가하되 기존 호출의 기본 의미는 보존한다.
- [ ] cache resume/preprocess/assignment resolve 공통 후처리를 helper로 추출해 한 번만 실행한다. 허용된 runtime binding 변경과 모델의 금지된 graph 변경을 분리한다.
- [ ] setter 일부 성공 후 throw/불일치 시 candidate 전체를 기각한다. commit 경로의 예외에는 full checkpoint를 복원한다.

통과 조건: partial 적용을 남긴 채 진행하지 않는다. 첫/두 번째 setter 실패, resync 실패, 후처리 실패 뒤 parent 상태와 NOOP trajectory가 보존된다. resync 호출 로그만으로 정합성 통과 판정을 내리지 않는다.

## T7. 선택기, certificate, 커밋 구현

제안 파일:

- `src/verification/repair_supervisor.jl`
- `test/repair_selection.jl`
- `test/repair_commit_replay.jl`

선택 표:

| NOOP | 후보 | 선택 |
|---|---|---|
| COMPLETE | 어떤 결과든 | NOOP |
| FAIL_WITHIN_BUDGET | COMPLETE + contract 통과 | PATCH |
| FAIL_WITHIN_BUDGET | 실패·거절·UNKNOWN | NOOP |
| UNKNOWN 또는 identity mismatch | 어떤 결과든 | NOOP + 인증 불가 |

작업:

- [ ] 선택 표와 후보 tie-break를 pure function으로 구현한다. tie-break는 unique config 수 → XY 이동 norm 합 → 제안 순서다.
- [ ] checkpoint/config/task/proposal/diff/continuation/외생 난수/budget/validator 지문과 두 분기 결과를 certificate에 묶는다.
- [ ] precommit에서 현재 세계가 원래 `t0`인지 확인한다. stale certificate는 기각한다.
- [ ] 검증한 동일 patch transaction만 주 세계에 적용하고 shadow post-transaction 상태와 비교한다.
- [ ] 동일 continuation을 실행해 trajectory·terminal outcome을 검증한다.
- [ ] mismatch는 보장 위반으로 기록하고 campaign 인증을 중단한다. 사후 검출을 성공적인 rollback이라고 보고하지 않는다.
- [ ] NOOP 선택에서도 state/정책/예산이 원래 기준과 같은지 검사한다.

통과 조건: 모든 선택 표 조합, 복수 후보, stale certificate, 적용 후 state mismatch를 시험한다. 초반 progress 뒤 장기 stall하는 후보와 `nav_blocked=0` 뒤 stall하는 후보는 채택되지 않는다.

## T8. 실제 존 사건 경로 연결

대상 파일:

- `tools/monitor/render_demo.jl`의 `policy_producer`와 실제 주입/dispatch 경로.
- `tools/monitor/enact.jl`의 존 repair 집행 분기.
- `src/ConstructionBots.jl` 등 필요한 module wiring.
- `test/repair_runtime_wiring.jl`

작업:

- [ ] 설정 `ZONE_REPAIR_VERIFICATION=off|shadow|enforce`를 정의한다. 기본값은 `off`, 오타는 기동 오류다.
- [ ] `off`는 기존 경로, `shadow`는 주 세계 존 NOOP + 후보 평가, `enforce`는 검증기 선택을 실행하도록 연결한다. 팔과 모드를 manifest에 기록한다.
- [ ] `t0` capture가 모든 존 관련 LLM/body 변경보다 먼저 실행되는지 검사한다. 현재 `decide_all` 등에 숨은 집행이 있으면 경계를 분리한다.
- [ ] `shadow/enforce`에서 raw minted body가 주 세계에 우회 진입하지 못하게 한다.
- [ ] 검증 후 zone dispatch가 중복 집행되지 않게 하고, 이후 존은 `pi0`를 따르게 한다.
- [ ] fault/battery/일반 복구와 설정 `off`의 기존 동작을 확인한다.
- [ ] source/service/schema 지문 불일치를 실제 결정 전에 검출한다.

통과 조건: 최종 사용 경로에서 capture→proposal→worker→selection→commit 순서가 관측된다. 시험 harness에서만 돌아가는 미연결 검증기를 완료로 간주하지 않는다.

## T9. 모델 proposal 경로와 관측·예산 연결

대상 파일:

- `src/respec/llm_service/`의 실제 요청·출력·prompt 경로(구현 시작 시 위치 확인).
- `geometry_patch.schema.json`
- 해당 Python 계약 시험 파일.

작업:

- [ ] 현재 센서의 존 기하·목표 위치·작업 관계·도달 가능성을 읽어 proposal 관측을 구성한다.
- [ ] 기하 수정 절차를 안내하되 anchor seed/성공 좌표/사람 oracle/자동 계산된 목적지를 노출하지 않는다.
- [ ] schema에 맞는 patch만 받아 Julia validator로 보내고, 임의 코드·함수 호출 출력은 거절한다.
- [ ] K=1과 K=4가 동일한 첫 후보를 공유하도록 episode별 후보 목록을 저장한다. G1은 첫 후보, G4/V4는 동결된 동일 목록을 평가한다.
- [ ] 최초 포함 최대 4회 안에서 정적/transaction 실패 피드백으로 재제안하게 한다. provider 오류도 호출/비용 원장에 남긴다.
- [ ] 전체 rollout을 통한 탐색 피드백은 V1에서 제외한다. 모든 후보가 동결되기 전에 baseline 결과를 모델 입력에 섞지 않는다.
- [ ] malformed/missing/provider-error를 원인이 있는 실패로 기록하고, model capability 결과와 인프라 실패를 함께 보고한다.

통과 조건: 서비스 fixture로 schema/예산/피드백 경계를 검사한다. 무료 회귀 검증에서는 live model 호출이 0회여야 한다. Python 시험은 repo 루트에서 기존 `.venv/bin/python -m pytest` 진입점을 사용한다.

## T10. 무료 회귀 검증과 과거 body 재생

제안 파일:

- `tools/monitor/replay_repair_cohort.jl`
- `test/fixtures/repair_verification/patches/`
- `results/2026-09-24-zone-repair-verification/validation/`

작업:

- [ ] T0의 anchor body에서 좌표 변경 trace를 추출해 declarative patch fixture로 옮긴다. 수동 변환 사실과 원본을 함께 기록한다.
- [ ] 유효한 4개 성공 기전이 새 인터페이스에서 표현되고 완주하는지 검사한다. 실패하면 표현 제약/동기화/의미 위반 중 원인을 밝힌다.
- [ ] 13개 역사적 regression의 raw harm 재현과 검증기 기각을 확인한다.
- [ ] easy 27 중 새 B0가 완주하는 모든 판이 최종 NOOP 선택으로 보존되는지 검사한다. B0 자체가 달라지면 baseline drift로 별도 보고한다.
- [ ] 같은 body·params의 L0/L1 통제 재생으로 resync 단독 효과를 측정한다. L1은 resync만 추가하고 다른 개선을 섞지 않는다.
- [ ] body 내부 step 호출과 예외가 있는 경우 resync 삽입 위치를 명시한다. 인과 비교를 만들 수 없는 body는 비교 불가로 표시한다.
- [ ] 전체 120개 계획 episode에서 source/prefix/identity, UNKNOWN, solver/사다리 발동을 확인한다.
- [ ] T2–T8의 fault injection·격리·커밋 시험 결과를 파일별 exit code와 함께 저장한다.

통과 조건: 보장 전제인 복원·격리·커밋 재현에 실패한 상태로 모델 sweep을 진행하지 않는다. anchor 실패나 기존 결과 불일치는 숨기지 않고 보고한다. “8판은 resync 때문에 실패했다”는 주장은 L0/L1 결과가 뒷받침하는 범위에서만 한다.

## T11. 모델 실험과 결과 보고

대상 파일:

- `tools/monitor/grid/`의 campaign 실행·fingerprint·budget 연결.
- `tools/monitor/summarize_repair_verification.py`(신규)
- `results/2026-09-24-zone-repair-verification/README.md`와 manifests/원장.

실험 팔:

| 팔 | 정의 | 목적 |
|---|---|---|
| B0 | 공통 `pi0`, 존 NOOP | 동시대 기준 |
| L0 | 역사적 A2 body 재생 | 과거 실패·성공 재현 |
| L1 | L0 + resync만 추가 | 동기화의 인과 효과 |
| G1 | 기하 안내, 첫 후보 | 첫 시도 해결률·회귀율 |
| G4 | 같은 안내, 최대 4후보 | 후보 수 효과 |
| V4 | G4의 동일 후보 + NOOP 비교 채택 | 검증기의 선택 효과 |

작업:

- [ ] model/service/prompt/schema/source·예산을 동결하고 manifest를 검증한다. 값이 비면 실행하지 않는다.
- [ ] fixture 파일·oracle body가 live 모델 입력이나 실제 proposal 경로에 섞이지 않는지 확인한다.
- [ ] 무료 게이트 통과 후 파일럿을 실행한다. tractor/X-wing, zone/all3 및 유효 anchor와 regression을 포함하고 파일럿 membership을 사전 기록한다.
- [ ] 파일럿에서 지문·예산·분기 결과·commit replay가 맞으면 120 episode 계획 격자를 수행한다. provider 시간대 차이를 줄이도록 실행 순서를 기록·분산한다.
- [ ] 동일 후보의 G1/G4/V4 결과를 연결해 모델 향상과 선택기 효과를 분리한다. V4를 위해 모델을 다시 호출하지 않는다.
- [ ] 아래 지표를 전체 계획 분모와 유효 paired 분모로 함께 보고한다.
- [ ] 개발에 사용한 120개를 회귀 세트로 표시한다. 새 seed 평가를 할 경우 prompt/validator/budget 동결 후 별도 manifest로 실행한다.

필수 지표:

- B0 미완주 시드에서의 첫 후보 rescue, best-of-K rescue, 최종 선택 rescue.
- B0 완주 시드에서의 raw regression과 selected regression.
- easy 보존, anchor 유지, harmful 후보 기각, no-op equivalent, 부분 적용/정합성 실패.
- `nav_blocked` 1/2 이상, robot/TU, zone/all3별 결과.
- resync 실제 적용·잔차, 최종 task contract, baseline drift, replay mismatch.
- planned/scored/complete/failed/UNKNOWN/missing/provider error의 분모 표.
- model calls/tokens/cost, 모든 branch CPU·wall·sim steps, 검증 지연, makespan/energy.
- 존 해법기 호출·자동 존 사다리 발동 및 일반 복구 기여.

통과 조건: 선택 후 regression은 paired B0 완주 판에서 0이어야 한다. 정확한 재현 조건 밖의 판에는 보장을 주장하지 않는다. hard rescue의 실제 증가는 측정 결과로 판단하며 설계만으로 달성됐다고 보고하지 않는다.

## 구현 종료 체크리스트

- [ ] T0–T11 완료 증거와 남은 제한을 기록했다.
- [ ] 원래 NOOP 실행과 복원 실행의 전체 결과가 일치한다.
- [ ] 모델의 금지된 구조 변경·partial 적용·씬 불일치를 차단한다.
- [ ] 전체 rollout과 최종 commit에서 같은 후보가 같은 결과를 만든다.
- [ ] 쉬운 판의 보존을 모델의 문제 해결로 합산하지 않는다.
- [ ] 역사적 4/13/27과 새 기준선에서의 결과를 구분해 보고했다.
- [ ] 적용 범위·필수 설정·실행 방법·실험 결과 링크를 문서화했다.

현재 완료된 것은 이 계획 문서의 작성뿐이다. 코드와 위 시험 파일들은 구현 예정이며, 나열된 게이트와 sweep은 아직 실행하지 않았다.
