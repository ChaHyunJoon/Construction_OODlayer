# 일반 도구 생성과 완주 보존 검증기 — 구현 계획

작성: 2026-09-24

상태: **계획 작성 완료 / 구현 및 실험 미실행**. 아래 체크박스는 구현 완료 증거를 확보한 뒤 체크한다.

설계 기준: [일반 도구 생성과 완주 보존 검증기 설계](../specs/2026-09-24-zone-repair-verification-design.md).

입력·처리 흐름: [멀티 에이전트 정보 흐름과 그림](../specs/2026-09-24-zone-repair-information-flow.md).

## 목표

Observe–Design–Compose의 일반적인 tool generation을 유지하면서, 생성 도구의 실제 효과를 격리 실행하고 NOOP와 비교해 유해한 개입을 차단한다. 기하 이동으로 성공한 4판은 회귀 사례이며 생성 기전의 제한이 아니다.

개정: 기존 GeometryPatch 중심 계획을 일반 source-code 도구 생성으로 변경했다. 기하 전용 방식은 보조 실험 G4에만 남긴다. 기존 링크를 보존하기 위해 파일명은 유지한다.

```text
사건 직후·모델 호출 전 전체 checkpoint
  → Observe: 무엇이 깨졌는지 보고
  → Design: 필요한 효과와 유지할 조건 설계
  → Compose: 실제 ToolProposal 코드 생성
  → 후보별 새 worker에서 등록·실행·실제 효과 검사
  → 전체 후보 동결 후 동일 상태의 NOOP / 후보 continuation 실행
  → 고정 규칙으로 선택
  → 새 commit worker에서 동일 코드 재생·검증 후 활성 세계 전환
```

**CBF는 도입하지 않는다.** 작업 범위는 전체 상태 보존, 일반 도구 생성과 격리 집행, 효과별 정합성 검사, 전체 완주 비교다. 구현·서비스 재시작·모델 호출·sweep은 아직 실행하지 않았다.

## 고정 계약

- 주 출력은 Julia 함수 source와 params/calls를 가진 `ToolProposal`이다. 기하 patch·고정 복구 template·기전 메뉴 선택으로 제한하지 않는다.
- 기존 Observe→Design→Compose와 runtime env 조회 방식을 유지한다. Design은 원본 전체 관측과 구현 primitive inventory를 직접 받지 않는다. Compose는 world interface를 받아 도구 코드를 쓴다.
- 주 프롬프트에 목표 이동·XY 변경을 강제하지 않는다. 관측과 센서는 기하뿐 아니라 의존성·배정·자원·진행 상태를 포함한다.
- 존 NOOP는 정상 주행·스케줄을 계속하는 정책이다. 기존 `none`은 NOOP 대조군이 아니다.
- 필수 작업/제품/물리 선행조건·존·원본 완료 조건은 보존한다. 배정·임시 graph·적법한 자원 작업은 일괄 금지하지 않고 의미에 따라 검사한다.
- 필수 task 삭제, 완료 위조, 공짜 자원 생성, runtime/validator override, 금지 base 우회, host 부작용은 금지한다.
- 생성 source 등록·평가·실행은 candidate마다 새 disposable worker에서 한다. `Core.eval` 정의는 env rollback/table reset으로 지워지지 않는다.
- supervisor와 trusted validator는 생성 코드를 실행하지 않는다. 코드가 반환한 success나 설명만 믿지 않고 실제 효과·독립 작업 계약으로 검사한다.
- 도구는 상태 변경·작업 예약·예산 안의 engine 진행을 조합한다. step 호출은 trusted adapter로 사건·작업 조건·비용·예산을 함께 처리한다. 직접 시계 조작/검사 우회/미지원 persistent callback은 기각한다.
- 기하를 바꾼 경우만 필요한 resync와 기하 검사. 다른 효과에는 해당 validator/후처리를 적용한다. 효과를 분류하지 못하면 unsupported로 보고한다.
- 기본 최대 source 후보 K=4, 모델 호출 최대 4회. Observe 1회→Design 1회→Compose 1회에서 코드 후보를 batch로 낼 수 있고, 네 번째 호출은 남은 후보 수 안에서 Compose 수정에 쓴다. 거절/수정본도 K를 소비한다.
- 후보마다 전체 3단계를 반복하지 않는다. provider/schema 재시도도 호출 예산에 포함한다. 총 token/cost 한도를 별도로 둔다.
- 피드백 preflight는 t0에서 첫 engine 진행 요청 직전에 멈춘다. 진행 필요는 requires_runtime이며 거절이 아니다. 미래 사건과 도구의 시간 진행 후 결과, NOOP/전체 rollout 결과로 재작성하지 않는다.
- 원본 작업과 전체 종료 예산으로 완주를 판단한다. 잠깐의 progress나 존 해소는 성공이 아니다. UNKNOWN과 계획 분모를 숨기지 않는다.
- 선택 후 같은 checkpoint에서 **동일 코드·호출**을 새 commit worker에 재생한다. terminal shadow 복사와 supervisor eval을 금지한다.
- 역사적 4/13/27과 새 paired 결과, 모델 능력과 검증기의 보호 효과를 구분한다.

## 작업 순서와 의존성

| 작업 | 산출물 | 선행 |
|---|---|---|
| T0 | 역사적 코호트·실행 body 연결 | 없음 |
| T1 | ToolProposal·결과 타입·권한/실험 manifest | T0 |
| T2 | 전체 checkpoint capture/export/import | T1 |
| T3 | native·난수·사건 재현 | T2 |
| T4 | disposable worker·독립 채점·전체 continuation | T3 |
| T5 | 일반 source 계약·원본 task·효과 validator | T1 |
| T6 | 격리 도구 집행·효과별 후처리 | T4, T5 |
| T7 | 선택·certificate·commit worker 전환 | T6 |
| T8 | production 사건 경로 연결 | T7 |
| T9 | 일반 MAS·코드 후보·호출 예산 | T1, T5, T6 |
| T10 | 기하/비기하 회귀·고장 주입·역사적 재생 | T8, T9 |
| T11 | U1/U4/V4 주 실험·G4 보조 비교 | T10 |

상태 복원과 효과의 신뢰 가능한 관측이 먼저다. 이 게이트가 실패하면 enforce 모드를 활성화하지 않는다.

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

## T1. 타입, 실행 권한, 실험 manifest 정의

제안 파일: `src/verification/repair_types.jl`, `src/respec/llm_service/tool_proposal.schema.json`, `tools/monitor/grid/repair_verification_manifest.schema.json`, `test/repair_contracts.jl`.

- [ ] `EpisodeCheckpoint`, `ToolProposal`, `ValidationReport`, `EnactmentReport`, `RolloutReport`, `SelectionReport`, `CommitReport`를 정의한다.
- [ ] source/name/specification/params/calls/checkpoint/proposal/parent ID를 envelope에 담는다. claimed_effects는 참고이며 실행 권한이 아니다.
- [ ] 현행 `{}` params와 runtime sensor 조회를 지원한다. 모델이 실행 시 알아낼 좌표·ID를 호출자에게 요구하게 만들지 않는다.
- [ ] COMPLETE/FAIL_WITHIN_BUDGET/UNKNOWN과 reject/unsupported/noop-equivalent/인증 불가를 구분한다.
- [ ] 원본 의미 조건과 변경 가능한 runtime 구조를 분리한 capability contract를 정의한다. graph 변경 전체를 금지하지 않는다.
- [ ] code/config/dirty snapshot/Julia/build/solver/thread/model/service/prompt/schema/validator 지문을 저장한다.
- [ ] 절대 simulation 예산, wall/CPU/memory, token/cost, 호출·후보 한도를 필수 manifest 필드로 둔다.
- [ ] 공통 continuation pi0, 외생 난수 규칙, 존 base/사다리 차단, 실제 비용 기록을 명시한다.
- [ ] validator/scorer/권한 경계는 모델과 별도 버전으로 고정한다. 누락 설정을 조용히 보완하지 않는다.

통과 조건: malformed code envelope, stale checkpoint, 금지된 API 권한, 비어 있는 budget을 거절한다. 함수를 수치 geometry patch로 변환하는 경로는 주 팔에 없다.

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
- [ ] 존 주입 전/후 상태를 보존하고, worker 재개 시 중복 주입·중복 dispatch를 막는다. 도구의 적법한 자원/배정 변경은 분기 상태의 차이로 반영한다.
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

- [ ] branch·재작성·commit마다 새 프로세스·출력 디렉터리·원장 namespace를 사용한다. RVO와 생성된 메서드 정의를 공유하지 않는다.
- [ ] network/host write/credential/실제 원장 권한을 제거하고 OS 자원 한도를 강제한다. 단순 프로세스 분리가 이 권한을 막는다고 가정하지 않는다.
- [ ] trusted validator는 생성 코드와 별도 프로세스에서 원본 contract와 고정 code-free export를 읽는다. worker가 준 score는 신뢰하지 않는다.
- [ ] 보호된 상태 변경과 engine action을 관측/제한하는 감사 경계를 만든다. 전후 diff만으로 일시적 금지 동작까지 잡았다고 주장하지 않는다.
- [ ] 주 세계는 tick 없이 `t0`에 머문다. 검증 대기를 위해 `RESPEC_HOLD`나 진행 카운터를 변경하지 않는다.
- [ ] production과 동일한 step/cache/event/terminal 순서를 호출하는 runtime continuation을 분리·재사용한다. 별도 간이 simulator를 만들지 않는다.
- [ ] `pi0`의 존 NOOP, 공통 fault/battery/일반 복구, 존 전용 solver/사다리 차단을 branch마다 확인한다.
- [ ] 원래 episode의 남은 예산으로 종료하고, wall timeout·worker crash·solver 오류는 원인이 있는 `UNKNOWN`으로 남긴다.
- [ ] 예산 중단 시 worker와 그 하위 프로세스를 정리하고 parent 상태를 검사한다.
- [ ] A가 RVO/zone/cache/spare/ID/RNG를 변경해도 parent와 B의 trajectory가 바뀌지 않는지 시험한다.
- [ ] N→A와 A→N 순서를 바꿔 같은 결과를 얻는지 확인한다.

통과 조건: NOOP rollout은 원본 runtime과 같고, 후보 오류와 실행 순서가 다른 세계를 오염시키지 않는다. shadow 실행이 실제 원장·서비스 호출 수·실제 episode 비용을 중복 기록하지 않는다. 동일 프로세스의 scorer/런타임 override, native/host escape를 막을 수 없으면 enforce 모드를 열지 않는다.

## T5. 일반 ToolProposal과 효과·작업 조건 검증

제안 파일: `src/verification/tool_proposal.jl`, `src/verification/task_contract.jl`, `src/verification/effect_validation.jl`, `test/repair_tool_proposal.jl`, `test/repair_task_contract.jl`, `test/repair_effect_validation.jl`.

- [ ] 현행 source/AST/등록/calls/ablation 검사를 재사용하고 source hash·API 권한을 묶는다. 정적 검사만으로 모든 효과를 증명했다고 하지 않는다.
- [ ] 원본 필수 제품·작업·물리 선행조건·assembly/attachment를 별도 trusted contract로 저장한다.
- [ ] runtime의 배정/임시 dependency와 원본 의미적 선행조건을 구분한다. 합법적 임시 edge 제거·스케줄 재구성·재배정을 평가할 수 있게 한다.
- [ ] 보조 작업 생성·원본 task refinement는 원본 작업과의 추적 가능한 대응을 요구한다. 대응 검증이 없으면 unsupported다.
- [ ] 자원 가용성/보존, 정당한 상태 전이, 시간·에너지·재고 비용을 검사한다. 자원 작업 요청과 직접 자원 위조를 구분한다.
- [ ] 기하, 배정, graph, 자원, 조합의 실제 diff·trace를 분류한다. 모델이 효과를 선언하지 않아도 필요한 검사를 수행한다.
- [ ] task 삭제, status 위조, 임시 zone 제거 후 복원, scorer/센서/기존 메서드 override를 검출한다.
- [ ] 로봇 teleport와 허용된 engine action을 구분한다. 정상 step 호출을 trusted engine adapter로 중재하고 시계 조작/검사 우회와 미지원 callback을 구분한다.
- [ ] no-op는 상태와 예약 작업·효과 trace가 모두 없는지로 판단한다. 지원되지 않는 효과를 기하로 강제 변환하지 않는다.

통과 조건: 합법적인 비기하 코드와 혼합 코드를 받아들이고, 같은 종류의 변경을 이용한 작업 생략·위조는 거절한다. 새로 생성한 helper와 계산/조건 분기/반복을 허용하며 고정 도구 template 목록을 만들지 않는다.

## T6. 격리 source 집행과 실제 효과별 후처리

대상 파일: `src/verification/tool_execution.jl`(신규), `src/respec/minted_registration.jl`, `src/respec/minted_tool.jl`, `src/respec/common_resolve.jl`, `src/respec/zone_facts.jl`, `src/respec/restage_zone.jl`, `test/repair_tool_execution.jl`, `test/repair_resync.jl`.

- [ ] 새 worker에 checkpoint를 복원한 뒤 도구 등록→body 실행→실제 효과 audit→후처리→독립 contract 검사 순서를 구현한다.
- [ ] body의 일반 env 조회·계산·조건부 변경을 유지한다. 전체 source를 geometry patch로 번역하지 않는다.
- [ ] 기하 변경에는 transform/attachment 검사, 필요한 resync, 실제 잔차 검사를 수행한다. 기하를 바꾸지 않은 도구에는 resync를 실행하지 않는다.
- [ ] 배정/팀 변경에는 가용성·중복·연결과 관련 cache, graph에는 원본 선행조건·frontier, 자원 작업에는 보존·정당한 비용을 검사한다.
- [ ] 모델이 resync나 후처리를 호출한 경우에도 실제 정합성을 확인하고 필요한 보충만 한다. body와 harness의 변경·호출을 나눠 기록한다.
- [ ] `enact_minted!` 내부의 공통 resume/preprocess/resolve 후처리를 재사용·분리해 중복 집행하지 않는다.
- [ ] free 본체/TU와 잡힌 cargo/로봇을 구분한다. 현재 resync helper의 tolerance·범위 밖 이동을 검사한다.
- [ ] step 호출은 trusted engine adapter로 처리해 정상 scheduler·사건·비용·작업 검사를 통과하게 한다. 도구 내부 진행도 전체 episode 예산을 소비하며 시계/예산 직접 변경은 막는다.
- [ ] preflight는 첫 step 직전에 requires_runtime으로 중단한다. 후보 동결 후 처음부터 전체 body를 실행하고, 미래를 본 뒤 발생한 실패는 모델 피드백으로 보내지 않는다. 각 실제 step 전 변경별 정합성을 검사한다.
- [ ] throw/partial/등록 부작용/timeout/미관측 효과는 worker 전체 폐기. 함수 table reset을 코드 rollback으로 사용하지 않는다.

통과 조건: 첫 상태 변경 뒤 throw, 일부 API 성공 후 실패, 후처리 실패에도 parent와 NOOP trajectory가 같다. 기하·비기하·혼합 효과에 맞는 검사가 실제로 실행되고 누락된 검사 adapter는 unsupported로 드러난다.

## T7. 선택기, certificate, commit worker 전환

제안 파일: `src/verification/repair_supervisor.jl`, `test/repair_selection.jl`, `test/repair_commit_replay.jl`.

| NOOP | 후보 | 선택 |
|---|---|---|
| COMPLETE | 무엇이든 | NOOP |
| FAIL_WITHIN_BUDGET | COMPLETE + 원본 contract 통과 | TOOL |
| FAIL_WITHIN_BUDGET | 실패·거절·UNKNOWN | NOOP |
| UNKNOWN / identity mismatch | 무엇이든 | NOOP + 인증 불가 |

- [ ] 선택 표를 pure function으로 구현한다. 여러 도구가 통과하면 최초 제출 순서로 고른다. XY 이동량으로 비기하 도구를 순위화하지 않는다.
- [ ] checkpoint/config/task/source/params/calls/effect-trace/post-state/continuation/RNG/budget/validator 지문을 certificate에 넣는다.
- [ ] 원래 활성 worker를 t0에 보존하고, 선택된 동일 코드를 새 commit worker에서 재생한다. 이전 후보 프로세스를 재사용하지 않는다.
- [ ] post-enactment 상태와 실제 효과를 shadow와 비교하고 trusted 검사 통과 뒤에만 활성 simulation worker를 전환한다.
- [ ] 실패하면 commit worker를 버리고 기존 세계에서 NOOP로 재개한다. 새 함수 정의를 원본 세계에서 undo하려 하지 않는다.
- [ ] 도구가 engine을 진행했다면 t0→t1의 step·사건·비용·로그도 실제 집행으로 인계한다. 선택 후 정상 continuation을 실행해 trajectory·terminal replay를 검증한다. 불일치는 보장 위반으로 기록하고 인증을 중단한다.
- [ ] shadow terminal state를 현재 세계에 복사하거나 미래 simulated time을 건너뛰지 않는다.

통과 조건: stale certificate, 같은 함수명 재등록, 조건부 코드의 다른 효과, 숨은 상태 변경, commit throw를 포함해 시험한다. commit 이전의 실패는 원본에 영향이 없고, 이후 불일치는 은폐하지 않는다.

## T8. 실제 사건 경로와 활성 simulator 연결

대상 파일: `tools/monitor/render_demo.jl`, `tools/monitor/enact.jl`, 필요한 module wiring, `test/repair_runtime_wiring.jl`.

- [ ] `ZONE_REPAIR_VERIFICATION=off|shadow|enforce`를 두고 기본 off, 오타는 오류로 처리한다.
- [ ] off는 기존 경로, shadow는 원본 NOOP+후보 평가, enforce는 supervisor의 선택과 commit-worker 전환을 사용한다.
- [ ] t0 capture가 존 관련 LLM/body 변경보다 먼저인지 확인한다. `decide_all` 등의 숨은 집행은 분리한다.
- [ ] raw body를 supervisor나 보존된 원본 worker에 직접 등록·실행하는 우회 경로를 막는다.
- [ ] render/monitor/episode 로그가 supervisor의 활성 worker를 읽도록 연결한다. shadow 로그와 실제 실행 로그를 분리한다.
- [ ] 같은 사건을 중복 dispatch하지 않고 이후 존은 pi0를 따른다. 도구 밖 fault/battery/일반 복구 정책은 공통으로 유지한다.
- [ ] service/source/API/schema/권한 지문 불일치를 결정 전에 검사한다.
- [ ] off의 기존 동작과 일반 사건 처리를 회귀 검증한다.

통과 조건: production 경로에서 capture→source 생성→worker 집행→검증→선택→새 commit worker→정상 continuation이 실제 연결된다. harness에만 존재하는 실행기를 완료로 간주하지 않는다.

## T9. 일반 MAS 입력·코드 출력·후보 예산

대상 파일: `src/respec/llm_service/synthesize.py`, `dspy_service.py`, `tool_proposal.schema.json`, 관련 Python 계약 시험.

- [ ] ObserveEvent/DesignToolSpec/WriteToolImpl의 일반 역할을 유지하고 output envelope를 ToolProposal에 연결한다.
- [ ] 관측·센서가 기하/항법 이외에도 배정·의존성·팀·자원·진행 상태를 포괄하는지 확인한다. 새 센서는 동시대 팔에 공통 제공한다.
- [ ] Design의 관측 보고서 경로와 구현 inventory 비노출을 유지한다. 기하 변경을 강제하는 RepairIntent/GeometryContext 주 입력은 제거한다.
- [ ] Compose에 world types/sensors/state APIs를 전달하고 runtime env 조회가 가능한 일반 Julia body를 생성하게 한다. 해법 base 차단은 유지한다.
- [ ] prompt에 기하 이동·XY 변경·고정 기전 선택을 강제하는 문장이 없는지 검사한다. 과거 성공 seed/좌표/oracle을 주지 않는다.
- [ ] 최초 source 후보와 제출 순서를 기록한다. U1은 첫 코드, U4/V4는 같은 최대 4개 코드 목록을 공유한다.
- [ ] Observe/Design/Compose 각 1회와 선택적 Compose 수정 1회의 공통 호출 예산을 강제한다. 한 Compose 응답은 여러 완전한 코드 후보를 포함할 수 있다.
- [ ] 총 제출 후보는 거절·수정본 포함 4개 이하다. 처음 4개 제출하면 수정 후보 예산은 없고, 처음 3개라면 남은 1개를 수정 호출로 제출할 수 있다.
- [ ] source/schema/provider 재시도와 원장을 모두 예산에 포함한다. token/cost 부족으로 잘린 코드를 정상 후보로 취급하지 않는다.
- [ ] 현재 집행 경계의 compile/권한/effect/contract 오류만 피드백한다. full rollout이나 미래 교란 정보를 재작성에 사용하지 않는다.
- [ ] 기하 전용 GeometryPatch 인터페이스는 G4 비교 모드에만 둔다. 주 코드 경로에 geometry schema를 강제하지 않는다.
- [ ] G4 전용 geometry schema와 `tools/monitor/repair_geometry_control.jl` adapter를 구현한다. 모델이 제출한 수치 변경만 engine API로 적용하고 일반 효과 validator·동일 task contract·전체 rollout을 공유한다. 추천 좌표를 계산하지 않는다.

통과 조건: 비기하 fixture 요청이 일반 source 후보로 끝까지 통과하고, MAS가 geometry-only mode로 조용히 폴백하지 않는다. 무료 서비스 시험은 live model 0회이며 repo 루트에서 기존 Python 시험 진입점을 사용한다.

## T10. 무료 회귀·비기하 수용·역사적 재생 검증

제안 파일: `tools/monitor/replay_repair_cohort.jl`, `test/fixtures/repair_verification/tools/`, `results/2026-09-24-zone-repair-verification/validation/`.

- [ ] 유효한 4개 anchor를 원본 source/호출 chain 그대로 일반 ToolProposal 경로에서 재생한다. geometry patch 수동 번역으로 대체하지 않는다.
- [ ] 과거 body의 step 호출은 trusted adapter로 재생한다. 실제로 검사·재현이 불가능한 동작은 원본 L0와 unsupported 사유를 따로 보고한다. 이를 모델의 의미적 실패로 바꾸지 않는다.
- [ ] 합법적인 비기하 fixture를 추가한다: 가용 로봇 재배정, 원본 과제를 보존하는 임시 edge 복구, 실제 자원 작업 예약, 기하+배정 혼합. 사람 fixture는 validator 시험 전용이며 모델 성공에 합산하지 않는다.
- [ ] task 삭제/완료 위조/zone 제거 후 복원/자원 위조/런타임 override/host write/등록 메서드 잔존/부분 적용을 고장 주입한다.
- [ ] 13개 역사적 raw regression을 재현하고 선택기가 기각하는지 확인한다.
- [ ] easy 27 중 새 B0도 완주하는 판을 보존한다. B0가 달라진 경우 baseline drift를 조사한다.
- [ ] L0/L1은 동일 body·params에 resync만 차이가 나도록 통제한다. body 내부 step 때문에 비교를 만들 수 없으면 불가 사유를 표시한다.
- [ ] 120개 계획 episode의 prefix/identity/UNKNOWN/solver/사다리 발동을 보고하고 무료 시험의 exit code·원장을 저장한다.

통과 조건: 기하 이외에도 생성·등록·검증 경로가 열려 있음이 시험으로 확인된다. 격리·독립 채점·복원·커밋 게이트 실패 상태로 모델 sweep을 진행하지 않는다. anchor/역사적 불일치와 검증기 coverage 한계를 숨기지 않는다.

## T11. 일반 생성 주 실험과 기하 전용 보조 비교

대상 파일: `tools/monitor/grid/`, `tools/monitor/summarize_repair_verification.py`(신규), `results/2026-09-24-zone-repair-verification/README.md`와 manifests/원장.

| 팔 | 정의 | 목적 |
|---|---|---|
| B0 | 공통 pi0, 존 NOOP | 기준 |
| L0/L1 | 역사적 코드 원본 / resync만 추가 | 역사·동기화 원인 분석 |
| U1 | 일반 코드 생성의 첫 후보 | 첫 시도 능력 |
| U4 | 같은 일반 생성, 최대 4 source 후보 | 후보 수 효과 |
| V4 | U4의 동일 코드 + NOOP 비교 선택 | 검증기 보호 효과 |
| G4 | 기하 전용 안내·GeometryPatch, 최대 4후보 | 제한된 생성 방식의 보조 비교 |

- [ ] model/service/source/prompt/interface/schema/validator·예산을 동결하고 필수 manifest를 확인한다.
- [ ] 주 팔 U1/U4/V4에 기하 강제 안내나 과거 성공 fixture가 노출되지 않았는지 감사한다.
- [ ] 무료 게이트 후 tractor/X-wing × zone/all3를 포함한 사전 고정 파일럿을 실행한다.
- [ ] 파일럿에서 identity·예산·효과 감사·commit replay를 확인한 뒤 120 episode 격자를 수행한다.
- [ ] U1/U4/V4는 동일한 코드 후보를 재사용한다. 선택기 성적을 위해 새 source를 생성하지 않는다.
- [ ] G4에는 동일 task contract·전체 실행·선택기를 적용한다. 다만 입력 안내와 출력 형식이 다르므로 단일 요인 비교라고 주장하지 않는다.
- [ ] 실제 기하/배정/스케줄/자원/혼합/기타 효과를 사후 분류한다. 비기하 성공이 없으면 능력 결과와 인터페이스/validator 거절 비율을 함께 분석한다.
- [ ] 원래 120개는 개발·회귀 세트로 보고하고 새 seed 평가는 별도 동결 manifest로 수행한다.

필수 지표:

- B0 미완주에서 첫 코드/최대 4코드/최종 선택 rescue.
- B0 완주에서 raw regression과 selected regression.
- 코드 생성·등록·실행 성공, 조건부/복합 효과, unsupported 효과와 금지 효과 기각률.
- easy 보존, anchor 유지, no-op equivalent, partial/throw, effect/contract 위반.
- 기하 변경 때만 resync 기여, 비기하 후처리 기여, body와 harness 각각의 효과.
- nav_blocked 1/2 이상, robot/TU, zone/all3, 기전별 결과.
- planned/scored/complete/failure/UNKNOWN/missing/provider-error 분모, baseline drift·replay mismatch.
- model calls/tokens/cost, 모든 branch의 CPU·wall·sim steps, 검증 지연, makespan/energy.
- 숨은 존 base/자동 사다리와 공통 일반 복구 기여.

통과 조건: paired B0 완주 판의 selected regression은 0이어야 한다. 일반 생성 공간과 측정 조건을 명시하며 hard rescue 증가는 실제 결과로 판단한다. 사람 fixture 성공이나 NOOP 보존을 모델 도구 생성 성공으로 계산하지 않는다.

## 구현 종료 체크리스트

- [ ] T0–T11 완료 증거와 남은 제한을 기록했다.
- [ ] 원래 NOOP 실행과 복원 실행의 전체 결과가 일치한다.
- [ ] 합법적인 기하/비기하 도구를 수용하고 원본 작업 위반·partial·정합성 실패를 차단한다.
- [ ] 전체 rollout과 새 commit worker에서 같은 source/params/calls가 같은 효과와 결과를 만든다.
- [ ] 생성 코드가 supervisor·독립 validator·원본 worker를 오염시키지 않는다.
- [ ] 쉬운 판의 보존을 모델의 문제 해결로 합산하지 않는다.
- [ ] 역사적 4/13/27과 새 기준선에서의 결과를 구분해 보고했다.
- [ ] 적용 범위·필수 설정·실행 방법·실험 결과 링크를 문서화했다.

현재 완료된 것은 이 계획 문서의 작성뿐이다. 코드와 위 시험 파일들은 구현 예정이며, 나열된 게이트와 sweep은 아직 실행하지 않았다.
