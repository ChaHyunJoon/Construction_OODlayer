# 일반 도구 생성과 완주 보존 검증기 설계

작성: 2026-09-24. 상태: **구현 전 설계**. 설계·계획·정보 흐름 문서의 개정이며 런타임 변경·실험 실행 결과를 뜻하지 않는다.

목표는 (1) 모델이 원인에 맞는 복구 기전과 도구 코드를 직접 생성하는 능력을 유지·개선하고, (2) NOOP로 완주하는 세계를 모델 개입으로 실패시키지 않는 것이다. 성공한 기하 이동 4판은 회귀 사례이며 주 생성 공간의 제한이 아니다. 두 목표는 별도 지표로 평가한다.

개정: 사용자의 일반 tool generation 유지 결정에 따라 GeometryPatch 중심 주 경로를 폐기했다. 기하 전용 방식은 비교 실험으로만 남긴다. 파일명은 기존 링크를 보존하기 위해 유지한다.

## 1. 결정과 보장 범위

**V1은 사건 단위의 runtime assurance supervisor로 구현한다.** 모델의 후보를 격리된 세계에서 실행하고, 동일한 개입 직전 상태(t0)에서 존 NOOP 정책과 끝까지 비교한다. 이 설계의 완주 판정은 유한한 실험 종료 예산에 대한 것이다.

**사용자 결정(2026-09-24): CBF는 도입하지 않는다.** 설계 범위는 일반 도구 코드 생성, 전체 상태 보존, 격리 집행과 실제 변경별 정합성 검사, 동일 상태에서의 NOOP 대비 완주 검증이다. 씬과 스케줄 정합성은 실행 계약으로, 완주는 전체 후속 실행으로 검사한다.

V1의 보장:

> 동일한 전체 초기 상태, 고정된 후속 정책, 동일한 외생 난수 실현, 동일한 종료 조건에서 기준 분기가 완주하면 선택된 분기도 완주한다.

이 명제는 정확한 분기·재현·커밋을 전제로 한다. 알려지지 않은 현실의 미래 교란이나 다른 난수 실현 전체에 대한 보장이 아니다. 검증 결과의 replay가 어긋나면 인증 실패이며, 이미 발생한 물리적 부작용을 사후 rollback할 수 있다는 뜻도 아니다.

**NOOP는 존 복구에 대한 NOOP다.** 로봇 주행, 정상 스케줄 실행, 기존 fault/battery 처리를 모두 정지하는 정책이 아니다. `none`은 사람이 쓴 존 복구 base를 가진 기존 ablation 팔이므로 NOOP 대조군과 혼용하지 않는다.

## 2. 확인한 현재 코드와 선행 결함

2026-09-24 작업 트리의 HEAD는 `30640f16`; 미커밋 변경이 있으므로 이 SHA만으로 재현 가능하다고 간주하지 않는다.

| 위치 | 확인한 사실 | 설계상 조치 |
|---|---|---|
| `src/respec/minted_tool.jl`, `enact_minted!` | body가 중간에 throw하면 앞선 변경에 undo가 없고 partial로 남을 수 있음 | 새 도구와 과거 body 모두 격리 worker에서 집행. 주 supervisor에서 코드를 eval하지 않음 |
| `src/respec/minted_registration.jl` | `Core.eval`로 등록된 함수는 table reset 뒤에도 프로세스에 남음 | 후보/재작성/커밋마다 새 프로세스. 원본 정의나 validator override 금지 |
| `src/respec/zone_facts.jl`, `resync_scene_to_schedule!` | `_resync_scene_drift!` 공개 래퍼 | 호출 성공과 실제 정합성 검사를 분리 |
| `src/respec/restage_zone.jl`, `_resync_scene_drift!` | FREE ObjectStart/AssemblyComplete 본체와 대응 TU의 XY drift를 기준으로 snap. 기본 tol은 로봇 반지름. 로봇은 직접 이동하지 않음 | 모든 씬 노드의 transform을 목표와 같게 만들었다고 가정하지 않음 |
| `src/smdp/simstate.jl` | 축약 `SimState`이며 전체 snapshot/restore/fork는 구현하지 않았다고 명시 | 이 타입과 `state_hash`를 완전 checkpoint로 사용 금지 |
| `src/smdp/state_globals.jl` | 일부 전역 inventory 및 baseline reset 지원. replay/setup, 모듈 밖 상태까지 완전 복원하는 API는 아님 | inventory를 출발점으로 사용하고 전체 checkpoint adapter 신설 |
| `src/smdp/generative.jl` | RVO2는 프로세스 전역. deepcopy로 respec 전역도 격리되지 않음. 재컴파일에 따른 ID/순서 비재현성 기록 | worker 프로세스 격리, 빌드 지문 고정, native 상태 복원 검증 필수 |
| `tools/monitor/render_demo.jl`, `policy_producer`; `tools/monitor/enact.jl` | 현재 결정·집행 경로 | 사건 전 checkpoint와 존 repair dispatch를 이 경로에 연결 |

기존 `rvo_rebuild!`의 위치 일치 시험만으로 동적 상태 복원이 증명되지 않는다. 현재 속도, preferred velocity, agent 순서, 시간, 장애물, 내부 설정 등을 포함해 원래 실행과 후속 궤적이 같아야 한다.

## 3. 비교 세계와 사건 경계

### 3.1 공통 실행 prefix

주 실험은 모든 팔이 동일한 초기화·주입·fault/battery 정책을 사용한다. 첫 존 사건의 주입과 기존 주입 후 물리 enforcement가 끝나고, **그 사건에 대한 모델 호출이나 body 실행 전**을 `t0`로 정의한다. 진행 중인 step의 어느 hook 경계인지도 manifest에 기록한다.

존 사건을 dispatch 중이라는 사실을 checkpoint에 포함한다. worker가 재개하며 같은 존을 두 번 주입하거나, dispatch 중인 이벤트를 중복 처리하면 실패다. 존 주입 전 상태와 주입 후 상태를 별도 보존하여 초기 겹침과 개입 후 침범을 구분한다.

V1은 한 checkpoint에서 최대 한 repair transaction을 채택한다. 그 뒤 존 사건에는 NOOP를 사용하고 후속 LLM 호출은 하지 않는다. 반복 개입 정책은 V2의 별도 정책 실험이다. 여러 모델 제안을 연속 적용해야 하는 해법은 하나의 원자적 batch로 표현한다.

`all3`의 나머지 사건은 공통 정책을 계속 사용한다. 모델 팔마다 다른 fault/battery 처리를 쓰면 생성 도구의 효과로 해석할 수 없다. 생성된 도구가 자원·배정에 개입하는 것은 후보 효과로 허용하되, 도구 밖의 후속 정책은 공통으로 유지한다.

### 3.2 역사적 결과와 새 실험 구분

9/23 canonical은 `results/2026-09-23-baseline-free/README.md`의 source snapshot까지 포함한 세계다. A2와 seed가 같아도 같은 코드·동적 prefix라는 뜻은 아니다. 기존 4/13/27 분류는 **역사적 회귀 코호트**로 고정하고, 새 코드의 같은-checkpoint 인과 비교와 별도로 보고한다.

역사적 분석 재현에는 각 campaign의 보존된 소스·설정·실제 집행 body 순서를 사용한다. 함수명 검색의 마지막 행을 실제 실행 body로 간주하지 않는다. `run_ctx`, `record_id`, `parent_record_id`, rewrite 차수와 실행 trace로 연결한다.

### 3.3 외생 변수

환경 난수는 `(episode, event kind, entity identity, occurrence index)`에 대응하는 난수 원천으로 정렬한다. 두 분기의 호출 횟수가 달라도 외생 난수 결합이 유지되어야 한다.

진행량에 따라 발생하는 사건, 적격 대상 선택, 상태 의존 hazard는 해당 분기의 상태에서 계산한다. 기준 분기의 실제 발생 시각·대상을 수정 분기에 강제로 복사하지 않는다. 공유하는 것은 외생 난수/사건 생성 규칙이며, 행동에 의해 달라지는 사건 결과는 아니다.

이 난수 adapter가 역사적 주입 동작을 바꾸면 새 세계 버전으로 표시하고 원본 재생과 구분한다. 미래 난수나 NOOP의 결과는 모델 입력으로 노출하지 않는다.

## 4. 생성 인터페이스: 실행 가능한 ToolProposal

주 출력은 일반 Julia 도구 함수다. 고정 기하 patch, 복구 템플릿 선택, 사전에 정한 기전 목록 중 하나로 제한하지 않는다. 모델은 센서 읽기, 계산, 조건 분기, 반복, 지역 helper, 허용된 세계 API 조합으로 새로운 절차를 작성한다. 여기서 일반성이란 기존 시뮬레이터가 표현하는 세계에 대한 도구 생성이며, 원본 과제나 시뮬레이터의 물리 법칙을 임의로 바꿀 권한을 뜻하지 않는다.

제안 API(아직 미구현):

```julia
capture_episode_checkpoint(ctx)::EpisodeCheckpoint
validate_tool_proposal(proposal, capability_contract)::ValidationReport
execute_tool_isolated(cp, proposal)::EnactmentReport
validate_effects(cp, enactment, task_contract)::ValidationReport
rollout_to_terminal!(branch, continuation, budget)::RolloutReport
select_verified_tool(baseline, candidates)::SelectionReport
commit_verified_tool!(supervisor, cp, proposal, certificate)::CommitReport
```

`ToolProposal`의 envelope는 다음 필드를 가진다. source code와 호출 인자가 실행의 실체이며, 설명과 self-reported success는 증거가 아니다.

| 필드 | 내용 |
|---|---|
| schema_version, checkpoint_id, proposal_id | 버전·입력 상태·후보 식별 |
| tool_name, specification | 필요한 효과, 사전조건, 유지할 조건 |
| impl_name, impl_code | 생성된 함수 이름과 Julia source |
| params, calls | 현행 호출 계약에 맞는 인자 schema·실제 값·호출 연결 |
| claimed_effects | 모델이 예상한 변경. 검사 범위를 제한하지 않는 참고 정보 |
| parent_proposal_id | 재작성이라면 원본 후보 연결 |

대상 ID·좌표·자원은 body가 실행 시 env의 센서로 읽고 계산할 수 있다. 호출자가 갖지 않은 값을 params로 지어내게 하지 않는다. 기본 `{}` 인자와 runtime 조회 방식을 유지한다.

### 4.1 멀티 에이전트 입력 계약

[정보 흐름과 그림](2026-09-24-zone-repair-information-flow.md)을 함께 갱신한다.

| 단계 | 입력 | 출력 |
|---|---|---|
| Observe | 현재 기하·항법·작업 의존성·로봇 상태·자원·진행 관측, 물리 원칙, 원본 목표 | 근거 필드가 있는 BreakageReport |
| Design | 검증된 보고서, 과제 목표, 기존 상위 대응 어휘와 일반 실행 계약 | ToolSpec: 필요한 효과·제약·사전조건. 기전은 필요한 경우 모델이 선택 |
| Compose | ToolSpec, 관측 보고서, world types/sensors/state APIs 및 실행 계약 | 실제 env를 조사하고 변경하는 ToolProposal의 source code |

현행 Design이 원본 전체 관측과 구현 primitive inventory를 직접 받지 않는 분해를 주 팔에서 유지한다. Compose에는 현행 world interface를 유지하고, 기하 전용 GeometryContext나 정답 목적지 입력을 의무화하지 않는다. 사용 가능한 관측·센서가 자원·배정·스케줄 관계도 포괄하는지 감사한다. 새 센서를 추가하면 모든 동시대 비교 팔에 공통 적용하고 지문을 남긴다.

Observe 보고서는 작업상 필요한 관측 설명이며 비공개 내부 사고 과정의 전송 계약이 아니다. 없는 관측은 unknown이다. 보고서의 근거 ID와 측정값을 확인하고 미확인 추론을 사실로 승격하지 않는다.

주 프롬프트는 "목표를 옮겨라", "XY만 바꿔라"를 강제하지 않는다. 기하 이동·재배정·자원 작업·임시 스케줄 복구·그 조합은 가능한 예이며 폐쇄된 선택 메뉴가 아니다. 성공 좌표나 사람이 쓴 존 복구 해법을 프롬프트에 넣지 않는다. 기존 A2의 존 base 차단은 유지한다.

### 4.2 보호할 의미와 변경 가능한 실행 상태

| 보호 대상 | 허용 가능한 변경의 예 | 금지 또는 검증 불가 |
|---|---|---|
| 필수 제품·작업·물리 선행조건 | 수행 로봇·팀 배정, 실행용 보조 노드, 적법한 임시 순서 조정 | 필수 작업 삭제/생략, 원본 조립 관계 손상 |
| 자원·동작 의미 | 실제 가용 자원 예약/해제, 허용된 교체·배송·충전 작업 요청 | 로봇/부품 생성 위조, 소모·비용 없는 배터리/재고 복구 |
| 원본 존·사건·완료 판정 | 존을 유지한 채 경로·작업 위치·수행 방식을 변경 | 존 삭제/완화, scorer/terminal/status 위조 |
| 물리 상태와 시간 | 시뮬레이터가 제공하는 적법한 작업의 효과 | 근거 없는 로봇 teleport, 시계·진행 budget 재설정 |
| 코드와 실행기 | worker 내부의 새 도구·지역 helper | 기존 런타임/센서/validator 재정의, 금지 base 우회, host 부작용 |

**그래프 수정 전체를 금지하지 않는다.** 원본 과제의 의미적 선행조건과 runtime의 배정·임시 의존성을 분리한다. 임시 edge 제거도 필수 작업의 수행 조건을 보존하면 후보로 평가한다. 분해/통합된 작업을 도입하면 원본 작업과의 추적 가능한 대응이 필요하며, 검증기가 지원하지 못하면 unsupported로 분류한다.

`nav_blocked`와 robot/TU는 관측·층화 변수다. 특정 값이나 기전이라는 이유만으로 생성 또는 검증을 생략하지 않는다.

## 5. 전체 checkpoint와 분기 격리

`EpisodeCheckpoint`는 다음을 포함하는 버전 있는 artifact다.

| 블록 | 필수 내용 |
|---|---|
| 모델·코드 | 소스 snapshot digest, Julia/Manifest/sysimage/build ID, solver 버전·seed·thread 설정, arm/ablation/config 지문 |
| task/world | 원본 task contract, 전체 sched와 transform-tree alias, scene tree와 attachment, 기하·staging, 물리 객체 상태 |
| 실행 상태 | cache frontier/closed/active, pending work, 시간·step, stalled/progress 기록, route 정책 내부 상태 |
| 전역 | zone·fault·spare·battery·delivery·restriction·ID counters, 복구 budget와 hold latch, policy/monitor 중 동역학에 영향을 주는 상태 |
| native 상태 | RVO agent identity/order, 위치·속도·preferred velocity·반지름·priority·시간·장애물·파라미터 및 후속 궤적에 필요한 내부 값 |
| 이벤트·난수 | 사건 queue, dispatch cursor, retry closure의 상태, RNG/hazard 누적값과 threshold, 미래 사건 규칙 |
| 원장 경계 | 이미 발생한 실제 비용/사건과 shadow 로그 namespace. shadow 출력을 실제 원장에 쓰지 않음 |

객체 그래프는 env와 관련 전역을 **같이** 복제하여 공유 참조 관계를 보존한다. 전역마다 독립 deepcopy를 하면 env가 가리키는 객체와 전역이 가리키는 객체가 갈라질 수 있다.

각 분기는 별도 OS 프로세스에서 실행한다. 주 프로세스는 시뮬레이션 tick을 진행하지 않고 원래 `t0`에 머문다. 이 대기는 `RESPEC_HOLD`를 임의로 바꾸는 행위가 아니며 원래 latch 값은 보존한다.

V1 구현 선택은 명시적 checkpoint export/import다. native 상태 복원이 불완전하면 인증 모드 활성화를 막는다. 재현 가능한 초기 상태부터의 replay는 개발용 대안이지만 동일 `t0` 동적 상태 검사를 통과해야 한다. Julia/native runtime을 단순 OS fork하면 안전하다고 가정하지 않는다.

`SimState.state_hash`와 9자리 반올림 해시는 equality certificate가 아니다. 정확한 직렬화 digest와 필드별 비교를 별도로 만든다. ID·graph·queue·RNG는 정확히 같아야 하고, 수치 오차는 planner의 분기 임계값과 연계한 명시적 tolerance로 검사한다. 허용 오차 내 상태라도 종료 결과가 갈리면 인증 실패다.

## 6. 일반 도구의 격리 집행과 변경별 검사

### 6.1 코드 실행 경계

생성·등록·컴파일·집행은 모두 후보 전용 disposable worker에서 한다. 생성 코드에 network, host 쓰기, 서비스 자격 증명, 실제 비용 원장 접근 권한을 주지 않는다. CPU·메모리·wall 한도를 둔다. 별도 프로세스라는 사실만으로 파일/네트워크 부작용이나 같은 프로세스의 scorer 변조가 막힌다고 가정하지 않는다.

현행 등록/AST/ablation gate를 재사용하되 그것만으로 일반 Julia 코드의 효과를 증명했다고 하지 않는다. 기존 메서드 override, native/host escape, 보호된 전역 접근을 차단하는 실행 권한 경계가 필요하다. 권한 경계를 강제할 수 없거나 변경을 관측할 수 없으면 enforce 모드는 활성화하지 않는다.

원본 task contract와 채점기는 생성 코드가 수정할 수 없는 supervisor/별도 trusted validator에 둔다. worker의 `status=:success`와 score는 신뢰하지 않는다. code-free의 고정 상태/효과 export schema로 독립 검사하고 custom deserialize/callback을 실행하지 않는다. 전후 diff만으로 "존을 잠깐 제거한 뒤 복원" 같은 효과를 검출했다고 하지 않는다. 보호된 세계 변경과 engine action은 신뢰되는 감사 경로로 기록·제한해야 한다.

도구는 현재 상태 변경, 지원된 작업 예약, 예산 안의 정상 simulation 진행을 조합할 수 있다. `step_environment!` 같은 시간 진행 호출은 trusted engine adapter를 통해 사건·원본 task 조건·시간/에너지/전체 예산을 함께 처리한다. 시계만 직접 바꾸거나 보호된 검사·scheduler를 우회하는 진행은 금지한다. 무한 loop는 자원 한도로 종료한다. opaque 지속 callback 등 재현·효과 관측을 지원하지 못한 형태는 unsupported로 별도 보고한다.

모델 재작성용 preflight는 t0에서 검사하되 첫 simulation 진행 요청 직전에 멈추고 `requires_runtime`으로 표시한다(거절 아님). 그 뒤의 source는 후보 동결 후 처음부터 재생해 평가한다. 도구 내부 진행으로 미래를 본 결과나 실행 후 오류를 V1의 재작성 피드백으로 보내지 않는다.

### 6.2 집행 순서

1. source/calls/schema/checkpoint/API 권한·ablation 검사.
2. 새 worker에 전체 checkpoint를 복원하고 보호된 원본 작업 계약과 비교 기준을 묶는다.
3. 도구를 등록·실행한다. body의 sensor read, 허용된 상태 변경과 engine action, 예외·자원 사용을 기록한다. arbitrary code를 geometry patch로 재작성하지 않는다.
4. 실제 전체 상태 diff·감사 trace에서 변경 유형을 판별한다. 모델의 claimed_effects만으로 검사 항목을 선택하지 않는다.
5. 변경별 정합성 검사와 필요한 일반 후처리를 수행한다. 목적지 계산·해결 전략·자동 존 복구는 추가하지 않는다.
6. 원본 task contract, 자원 보존·비용, 지원된 효과 범위를 검사하고 post-enactment 상태를 보존한다.
7. 후보가 동결된 뒤 동일 checkpoint에서 전체 source를 실행하고, 반환 후 공통 continuation으로 원래 종료 예산까지 진행한다. 도구 내부 engine 진행도 동일한 episode 예산·사건 규칙을 적용한다. 각 물리 step 전 정합성 검사를 수행하며 끝난 뒤의 diff만으로 중간 위반을 놓치지 않는다.

throw/partial/관측 불가 효과는 worker 전체를 폐기한다. 원본 세계는 손대지 않는다. no-op도 코드의 반환이 아니라 실제 상태·예약 작업·효과 trace가 없는지로 판정한다.

### 6.3 실제 변경별 후처리

| 검출된 변경 | 검사와 공통 후처리 |
|---|---|
| 스케줄 목표/scene geometry | transform-tree·attachment·작업 상대 기하 검사, 필요한 scene resync, 실제 잔차 검사 |
| 배정·팀 구성 | 가용성·자격·중복 배정·화물 연결, 해당 cache/assignment 갱신 |
| 실행 스케줄/임시 graph | 원본 선행조건·필수 작업 대응·deadlock/cycle 제약, frontier/cache 갱신 |
| 자원 예약·해제/작업 요청 | 자원 보존, 정당한 상태 전이, 시간·에너지·재고 비용의 정상 집행 |
| 여러 종류의 조합 | 관련 검사를 모두 수행하고 순서·중간 불일치·복합 효과 검사 |

표는 검사 adapter의 초기 inventory이며 모델의 기전 선택 메뉴가 아니다. 새 종류의 효과가 나오면 `unsupported_effect`로 남기고 필요한 일반 validator를 보강한다. 검증기가 그 효과를 이해하지 못한 결과와 모델이 해법을 못 만든 결과를 구분한다.

기하 변경이 없는 도구에 resync를 강제하지 않는다. 기하를 바꾼 도구는 body가 resync를 호출했는지와 무관하게 실제 정합성을 확인하고 필요할 때 실행기가 보충한다. 변화가 없는 씬 전체를 무조건 snap하지 않는다. 현재 helper의 FREE 본체/TU 범위와 XY tolerance 한계를 유지해 측정하며 로봇/잡힌 cargo의 부당한 이동을 막는다.

cache/preprocess/assignment resolve의 기존 집행 봉투를 공통 helper로 분리해 중복 집행하지 않는다. body와 harness가 각각 만든 변경을 별도 기록한다. 일반 동기화가 실패한 해법을 대신 찾아 준 것으로 보고되지 않도록 한다.

`zone_blockage`/`free_space_status`만으로 full-scene collision이나 모든 물리적 실현 가능성을 인증하지 않는다. 없는 validator는 unverified이고 완주 보장과 물리 안전 보장을 혼용하지 않는다.

## 7. 전체 실행, 채택, 커밋

### 7.1 고정 continuation과 예산

`pi0`: 존은 NOOP, 존 전용 solver/자동 복구 사다리는 차단, 나머지는 manifest에 고정한 공통 정책. 일반 복구도 종류별 실제 발동 횟수를 기록한다.

원본 task contract의 전체 완료 조건, 기존 runtime의 terminal stall 조건, episode 절대 simulation-step/시간 상한을 분기마다 동일하게 적용한다. 숫자는 역사적 campaign 설정을 확인해 새 manifest에 **필수 명시**하고, 비어 있으면 실행을 거절한다. 후보마다 예산을 새로 늘리거나 progress counter를 초기화하지 않는다.

worker wall timeout은 simulation failure와 다른 `UNKNOWN`이다. provider/solver 오류도 별도 필드로 남긴다. 느린 후보가 더 긴 simulated horizon을 얻어서는 안 된다.

### 7.2 상태 기계

```text
CAPTURED -> IDENTITY_VERIFIED -> PROPOSALS_FROZEN
         -> BASELINE_AND_CANDIDATE_ROLLOUTS
         -> SELECTED_NOOP | SELECTED_TOOL
         -> PRECOMMIT_VERIFIED -> COMMITTED -> REPLAY_CHECKED

각 검증 오류 -> REJECT_CANDIDATE 또는 CERTIFICATION_UNAVAILABLE
```

모델 성능을 재는 주 실험은 후보를 기준 분기 결과를 보기 전에 생성·동결한다. 최대 후보 수 K=4, 모델 호출 최대 4회(최초 포함)를 기본 설계값으로 고정한다. 후보 간 모든 model/token/rollout 비용을 합산한다. 총 token 한도와 wall 예산은 실행 manifest에 추가로 필수 지정한다.

호출은 Observe 1회, Design 1회, Compose 1회, 선택적 Compose 수정 1회로 배분한다. Compose 한 응답에 여러 후보를 담을 수 있다. 거절·수정본을 포함해 실제 제출된 후보는 총 4개 이하다. 최초 응답이 4개를 제출하면 재작성 후보 예산은 없고, 3개를 제출했다면 네 번째 호출에서 남은 1개를 제출할 수 있다. 모델 호출 예산과 후보 수는 별도 원장으로 관리하며 숨은 schema/provider 재시도도 호출 예산에 포함한다.

V1의 후속 모델 호출에는 **정적/transaction 검사 실패**만 제공하고 전체 rollout의 완주·미완주나 미래 사건은 제공하지 않는다. rollout 피드백을 통한 재탐색은 별도 `search_feedback` 팔이다. K=1과 K=4를 나눠 모델 자체 개선과 샘플 수 효과를 분리한다.

| 기준 분기 | 후보 분기 | 선택 및 분류 |
|---|---|---|
| COMPLETE | 무엇이든 | NOOP. 후보가 실패면 raw regression으로 기록 |
| FAIL_WITHIN_BUDGET | COMPLETE + task/transaction 검사 통과 | TOOL. rescued로 기록 |
| FAIL_WITHIN_BUDGET | 실패·거절·UNKNOWN | NOOP. 해결 실패 |
| UNKNOWN / identity mismatch | 무엇이든 | NOOP. 인증 불가. rescue 분모에서 조용히 제외하지 않음 |

여러 후보가 통과하면 최초 제출 순서로 선택한다. 기하 이동량이나 config 개수로 다른 종류의 도구를 편향되게 비교하지 않는다. 기본 목적은 완주 보존이며 makespan/energy 최적화는 보조 보고다.

배포형 운용은 baseline이 COMPLETE이면 후보 생성을 생략할 수 있다. 다만 모델 평가에서는 쉬운 시드에도 후보를 생성·재생하여 raw regression이 숨지 않게 한다.

### 7.3 커밋 계약

완료된 shadow의 terminal state를 복사하지 않는다. supervisor는 원래 `t0`의 활성 simulation worker를 보존한 채, 새 **commit worker**에 같은 checkpoint를 복원해 선택된 동일 source/params/calls를 다시 등록·집행한다. 후보 실행에서 등록한 함수가 남은 프로세스를 재사용하거나 supervisor 자체에 코드를 eval하지 않는다.

certificate에는 checkpoint/config/task/source/params/calls/실제 효과 trace/post-state/continuation/외생 난수/budget/validator 지문과 두 분기 결과를 포함한다. 원본이 `t0`에서 바뀌었거나 지문이 다르면 인증을 폐기한다. 조건부·반복·상태 조회를 하는 도구도 같은 상태에서 같은 효과를 재현해야 한다.

commit worker의 post-enactment 상태와 효과가 검증 분기와 같고 trusted validator를 통과한 뒤에만 그 worker를 활성 simulation 세계로 전환한다. 이는 t0에서 동일 도구를 실제로 다시 집행한 결과를 활성화하는 것이다. 도구가 engine을 진행했다면 t0→t1의 모든 step·사건·비용·로그를 실제 집행으로 인계하며, t1을 t0로 표기하지 않는다. 도구 반환 뒤의 미래 continuation 결과를 복사하지 않는다. 기존 render/monitor는 supervisor의 활성 worker를 읽도록 연결한다. 물리적 외부 actuator로의 배포는 이 시뮬레이터 설계 범위 밖이다.

등록/집행/검사 실패나 불일치면 commit worker를 버리고 손대지 않은 원래 worker에서 NOOP로 재개한다. table reset이나 env rollback으로 Julia 메서드 정의를 되돌렸다고 주장하지 않는다. 채택 후 같은 continuation을 실제로 실행하고 trajectory·terminal replay가 갈리면 보장 위반으로 기록하고 campaign 인증을 중단한다. 사후 검출은 발생한 실패를 없애지 못한다.

NOOP 완주 시에는 원래 세계의 동일 pi0를 재개한다. NOOP 실패 시에는 검증된 도구만 같은 상태/정책/미래 실현에서 집행한다. 정확한 복원·효과 관측·채점 독립성·동일 continuation이 보장의 전제다.

## 8. 생성 자유도와 검증의 경계

생성기는 문제 원인에 맞는 도구 코드를 제안한다. 검증기는 그 코드의 실제 효과와 원본 작업 조건을 검사하고, 같은 상태의 NOOP 대비 전체 실행 결과로 채택한다. 모델이 쓰는 해결 방법과 실행기가 강제하는 과제 조건을 구분한다.

graph 수정이라는 이유로 모두 금지하거나, 기하 이동이라는 이유로 자동 승인하지 않는다. 반대로 생성 자유도를 유지한다는 이유로 필수 작업 삭제·존 완화·상태 위조를 허용하지 않는다. 검사 범위 밖 효과는 unsupported로 보고하며, 새 해법을 하나씩 whitelist에 추가하는 방식으로 도구 생성 공간을 고정하지 않는다.

전체 후속 실행을 짧은 horizon으로 대체하지 않는다. 종료까지 검증하지 못하면 UNKNOWN이다. 생성 코드가 임의의 host/런타임을 수정할 수 있는 상태에서는 회귀 방지 보장이 성립하지 않는다. 이에 대한 구현 조건과 시험을 §6과 완료 게이트에 둔다.

## 9. 검증 실험과 채점

### 9.1 코호트와 데이터

기본 격자는 tractor/X-wing × zone/all3 × 30 seeds = 120 episode. 계획한 모든 판을 주 분모에 유지하고 timeout/provider error/인증 불가를 따로 표시한다. 기존 A2의 116, hard 89는 관측 분모이며 새 실험의 고정 분모로 사용하지 않는다.

역사적 코호트 manifest에는 다음 membership을 저장한다: easy 27, hard 93, A2 easy-success 14, A2 regression 13, A2 rescue 4. 사용자 분석의 4개 anchor는 tractor all3 s2, tractor zone s5, tractor zone s16, X-wing zone s4다. 나머지 membership은 기존 결과 join으로 추출하고 수가 어긋나면 원인부터 보고한다.

4개 anchor의 실제 body와 최종 task 의미를 먼저 감사한다. 강화된 task contract가 기존 성공을 거절하면 `historical_complete_but_contract_invalid`로 기록한다. 기존 성공을 유지하려고 invariant를 완화하지 않는다. 유효한 body는 원본 코드와 호출 chain 그대로 fixture로 보관하고 일반 ToolProposal 경로에서 재생한다. 기하 patch로 수동 번역하지 않는다. 원본 body의 step 호출도 trusted engine adapter로 재생할 수 있어야 한다. 실제 API 우회 등 지원 불가 부분은 원본 L0와 일반 경로의 unsupported 결과를 구분한다. 비기하 도구 fixture도 추가하되 어느 fixture도 모델 프롬프트에 넣지 않는다.

### 9.2 팔

| 팔 | 제안 방식 | 실행/채점 | 목적 |
|---|---|---|---|
| B0 | 존 NOOP | pi0 | 동시대 기준 |
| L0 | 역사적 A2 body chain | 원본 통제 재생 | 역사적 재현 |
| L1 | L0와 동일 body/params | resync만 추가한 통제 재생 | resync 인과 효과 |
| U1 | 일반 tool generation, 첫 source 후보 | 격리 집행·공통 후처리·raw outcome | 주 모델의 첫 시도 능력 |
| U4 | 같은 일반 생성, 최대 4 source 후보 | 같은 검증 봉투·후보별 raw outcome | 후보 수 효과 |
| V4 | U4의 **동일 코드 후보** | NOOP 비교 후 선택 | 검증기의 순수 선택 효과 |
| G4 | 기하 전용 안내·GeometryPatch, 최대 4후보 | 동일 원본 contract·예산·전체 실행 | 제한된 생성 방식과의 보조 비교 |

주 경로는 U1/U4/V4다. G4는 생성 방식 비교이므로 프롬프트·출력 형식·직접 기하 입력이 다름을 명시한다. G4와 U4 차이를 특정 한 요인의 효과로 해석하지 않는다. 양쪽에 동일한 선택기를 적용한 결과도 보고하되 원시 결과와 구분한다.

U1/U4는 주 세계를 무검증으로 변경하는 팔이 아니라 worker의 raw 결과를 채점한다. 모델이 다른 효과를 만든 경우에도 동일한 일반 validator를 사용한다. L1은 body 내부 step과 resync 삽입 위치까지 고정하고 다른 개선을 섞지 않는다.

모든 팔의 source/입력/budget/validator를 동결하고 새 seed로 별도 평가한다. 원래 120개는 개발·회귀 세트다. 기하 이동 4판의 성공을 일반 도구 생성의 유일한 학습 목표로 삼지 않는다.

### 9.3 지표

- `rescue_rate = selected_complete / contemporaneous_B0_failures`, UNKNOWN 별도. 역사적 hard 코호트 성적도 병기.
- `raw_regression_rate = candidate_failed / B0_complete`; 첫 후보와 best-of-K를 구분.
- `selected_regression_rate = selected_failed / B0_complete`; 인증 불가와 replay mismatch도 숨기지 않음.
- `easy_preserved`, `valid_anchor_retained`, `rejected_harmful`, `noop_equivalent`, partial/throw/desync/contract reject 수.
- 기하/배정/스케줄/자원/혼합/기타의 실제 효과 분류, raw code 등록·집행 성공률, unsupported 효과와 금지 효과의 기각률. 분류는 사후 분석용이며 생성 whitelist가 아니다.
- 목표별 nav block 수, target kind, zone 해소 여부, resync 실제 이동 대상/거리, scene residual, 필수 task 만족 여부.
- model calls/tokens/cost, 모든 branch CPU·wall·sim steps, 검증 지연 p50/p95/max, makespan/energy.
- 사람이 쓴 존 solver 호출·자동 존 ladder 발동 수. 숨은 기여가 있으면 별도 분류.

L1이 8판을 복구하는지는 측정할 가설이다. resync 미호출이라는 상관만으로 실패 원인이 증명됐다고 쓰지 않는다. V4의 easy 보존을 모델 rescue로 합산하지 않는다.

## 10. 구현 파일과 완료 게이트

| 파일(제안) | 책임 |
|---|---|
| `src/verification/episode_checkpoint.jl` | 전체 checkpoint와 복원·alias 검사 |
| `src/verification/tool_proposal.jl` | source/params/calls envelope와 등록 계약 |
| `src/verification/tool_execution.jl` | 격리 집행·effect audit·공통 후처리 |
| `src/verification/effect_validation.jl` | 실제 효과별 validator, unsupported 분류 |
| `src/verification/task_contract.jl` | 원본 작업 의미와 독립 채점 |
| `src/verification/repair_supervisor.jl` | 선택·certificate·commit worker 전환 |
| `tools/monitor/repair_branch_worker.jl` | candidate/NOOP/commit 실행과 shadow 원장 |
| `tools/monitor/render_demo.jl`, `tools/monitor/enact.jl` | t0 capture, supervisor와 활성 runtime 연결 |
| `src/respec/minted_registration.jl`, `src/respec/minted_tool.jl` | 기존 코드 등록·집행 재사용, trusted 후처리 분리 |
| `src/respec/llm_service/synthesize.py` 및 서비스 | 일반 Observe/Design/Compose 유지, 후보·호출 예산 |
| `tools/monitor/grid/`, `test/repair_*.jl` | paired campaign·아래 게이트 |

1. **데이터:** 역사적 4/13/27, 실제 body chain, source/prefix 차이를 확인한다.
2. **checkpoint:** 원본 NOOP와 복원 NOOP의 전체 종료 결과·상태 재현을 검증한다.
3. **격리:** 전역/RVO/RNG/등록 메서드/파일·서비스 부작용이 parent나 다른 branch로 새지 않는다. 같은 도구 이름의 후보도 새 프로세스에서 독립 실행된다.
4. **효과:** 기하 이외의 합법적 배정·임시 edge·자원 작업과 혼합 코드도 수용한다. 필수 task 삭제, 완료 위조, 일시적 zone 완화, runtime/scorer override, 설명에 없는 변경은 검출한다.
5. **후처리:** 기하 변경에 필요한 resync, 배정/graph/cache 및 자원 검사를 실제 효과에서 유도한다. partial/throw/미관측 효과는 폐기한다.
6. **전체 실행:** 초반 progress 또는 존 해소 후 stall 후보를 기각하고 UNKNOWN/예산 계약을 지킨다.
7. **코호트:** 유효한 4개 기전을 원본 source로 확인한다. 역사적 13판의 재현된 harm을 기각하고 새 B0도 완주하는 easy 판을 보존한다. 과거 body의 검증 계약 불일치는 숨기지 않는다.
8. **커밋:** 선택된 동일 코드의 새 worker 집행과 post-state·후속 실행을 재현한다. 실패 worker의 메서드 정의를 rollback했다고 하지 않는다.
9. **모델 실험:** U1/U4/V4를 주 실험, G4를 보조 비교로 수행한다. 일반 생성 공간이 유지되는지 비기하 fixture와 프롬프트 검사를 포함한다.

이 문서 작성 단계에서는 구현 시험·유료 모델 호출·전체 sweep을 실행하지 않았다.
