# 존 기하 복구와 완주 보존 검증기 설계

작성: 2026-09-24. 상태: **구현 전 설계**. 이번 변경은 이 문서뿐이며 런타임 변경·실험 실행 결과를 뜻하지 않는다.

목표는 (1) 모델이 직접 계산한 기하 변경의 실제 해결률을 높이고, (2) NOOP로 완주하는 세계를 모델 개입으로 실패시키지 않는 것이다. 두 목표는 별도 지표로 평가한다.

## 1. 결정과 보장 범위

**V1은 사건 단위의 runtime assurance supervisor로 구현한다.** 모델의 후보를 격리된 세계에서 실행하고, 동일한 사건 직전 상태에서 존 NOOP 정책과 끝까지 비교한다. 이 설계의 완주 판정은 유한한 실험 종료 예산에 대한 것이다.

**사용자 결정(2026-09-24): CBF는 도입하지 않는다.** 설계 범위는 전체 상태 보존, 원자적 기하 변경과 resync, 동일 상태에서의 NOOP 대비 완주 검증이다. 씬과 스케줄 정합성은 실행 계약으로, 완주는 전체 후속 실행으로 검사한다.

V1의 보장:

> 동일한 전체 초기 상태, 고정된 후속 정책, 동일한 외생 난수 실현, 동일한 종료 조건에서 기준 분기가 완주하면 선택된 분기도 완주한다.

이 명제는 정확한 분기·재현·커밋을 전제로 한다. 알려지지 않은 현실의 미래 교란이나 다른 난수 실현 전체에 대한 보장이 아니다. 검증 결과의 replay가 어긋나면 인증 실패이며, 이미 발생한 물리적 부작용을 사후 rollback할 수 있다는 뜻도 아니다.

**NOOP는 존 복구에 대한 NOOP다.** 로봇 주행, 정상 스케줄 실행, 기존 fault/battery 처리를 모두 정지하는 정책이 아니다. `none`은 사람이 쓴 존 복구 base를 가진 기존 ablation 팔이므로 NOOP 대조군과 혼용하지 않는다.

## 2. 확인한 현재 코드와 선행 결함

2026-09-24 작업 트리의 HEAD는 `30640f16`; 미커밋 변경이 있으므로 이 SHA만으로 재현 가능하다고 간주하지 않는다.

| 위치 | 확인한 사실 | 설계상 조치 |
|---|---|---|
| `src/respec/minted_tool.jl`, `enact_minted!` | body가 중간에 throw하면 앞선 변경에 undo가 없고 partial로 남을 수 있음 | 주 세계에서 임의 body 실행 금지. 과거 body는 격리 worker에서만 재생 |
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

`all3`의 나머지 사건은 공통 정책을 계속 사용한다. 모델 팔마다 다른 fault/battery 처리를 쓰면 존 기하 개입의 효과로 해석할 수 없다.

### 3.2 역사적 결과와 새 실험 구분

9/23 canonical은 `results/2026-09-23-baseline-free/README.md`의 source snapshot까지 포함한 세계다. A2와 seed가 같아도 같은 코드·동적 prefix라는 뜻은 아니다. 기존 4/13/27 분류는 **역사적 회귀 코호트**로 고정하고, 새 코드의 같은-checkpoint 인과 비교와 별도로 보고한다.

역사적 분석 재현에는 각 campaign의 보존된 소스·설정·실제 집행 body 순서를 사용한다. 함수명 검색의 마지막 행을 실제 실행 body로 간주하지 않는다. `run_ctx`, `record_id`, `parent_record_id`, rewrite 차수와 실행 trace로 연결한다.

### 3.3 외생 변수

환경 난수는 `(episode, event kind, entity identity, occurrence index)`에 대응하는 난수 원천으로 정렬한다. 두 분기의 호출 횟수가 달라도 외생 난수 결합이 유지되어야 한다.

진행량에 따라 발생하는 사건, 적격 대상 선택, 상태 의존 hazard는 해당 분기의 상태에서 계산한다. 기준 분기의 실제 발생 시각·대상을 수정 분기에 강제로 복사하지 않는다. 공유하는 것은 외생 난수/사건 생성 규칙이며, 행동에 의해 달라지는 사건 결과는 아니다.

이 난수 adapter가 역사적 주입 동작을 바꾸면 새 세계 버전으로 표시하고 원본 재생과 구분한다. 미래 난수나 NOOP의 결과는 모델 입력으로 노출하지 않는다.

## 4. 새 인터페이스: 모델은 GeometryPatch를 제출

아래 이름은 **제안 API**이며 현재 존재한다고 가정하지 않는다.

```julia
capture_episode_checkpoint(ctx)::EpisodeCheckpoint
start_branch(cp, branch_spec)::BranchHandle
validate_patch(cp, patch)::ValidationReport
apply_geometry_transaction!(ctx, patch)::TransactionReport
rollout_to_terminal!(branch, continuation, budget)::RolloutReport
select_verified_patch(baseline, candidates)::SelectionReport
commit_verified_patch!(ctx, cp, patch, certificate)::CommitReport
```

`GeometryPatch`는 다음 필드를 가진다.

```json
{
  "schema_version": 1,
  "checkpoint_id": "immutable artifact ID",
  "proposal_id": "model proposal ID",
  "intent": "restore blocked work reachability",
  "blocked_goal_refs": ["stable semantic reference"],
  "writes": [{
    "config_ref": "stable reference to a schedule transform",
    "expected_before": {"translation": [0, 0, 0], "rotation": "identity"},
    "desired_global": {"translation": [1, 0, 0], "rotation": "identity"}
  }],
  "preserve_relative": [["config reference A", "config reference B"]],
  "rationale": "model explanation; never trusted as validation"
}
```

좌표는 형식 예시이며 해법 값이 아니다. 실제 schema는 수치 SE(3) 표현·단위·차원을 고정한다. V1은 기존 성공 기전과 맞추어 XY 평행이동만 허용하고 회전·Z는 보존한다. 판당 이동 가능한 위치 범위는 모델별 기존 workspace 설정에서 읽어 manifest에 고정한다. 임의의 작은 이동량 상한으로 전체 이동 해법을 막지 않는다.

안정적인 참조는 checkpoint 내부의 semantic entity/task/config identity로 해석한다. 다른 빌드에서 얻은 정점 번호를 그대로 재사용하지 않는다. 같은 객체를 가리키는 alias와 transform-tree 상속을 해석해 **최종 global transform**이 서로 충돌하는지 검사한다.

모델은 센서 사실, 기하 및 작업 관계를 읽을 수 있다. 후보 목적지, 이동량, 어떤 작업 기하를 함께 바꿀지는 모델이 결정한다. 실행기는 별도의 staging/translation solver로 목적지를 만들어 주지 않는다. 보호 대상 관계는 모델의 `preserve_relative` 선언과 무관하게 원본 task contract에서도 유도한다.

금지: task/edge 삭제·추가, closed/active 상태 직접 쓰기, zone 변경·삭제, 물리 로봇 pose 쓰기, sensor/scorer 변경, solver/사다리 설정 변경, `step_environment!` 호출, 파일·서비스 부작용. 임의 코드의 AST 검사에만 의존하지 않고 declarative patch만 주 세계에 적용한다.

`nav_blocked`와 로봇/TU 분류는 층화 분석과 후보 우선순위에 쓴다. `nav_blocked >= 2` 또는 robot target이라는 이유만으로 개입을 거절하지 않는다.

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

## 6. 기하 transaction의 검사와 실행

순서는 아래로 고정한다. 중간 단계에서 실패하면 worker를 버리고 주 세계는 그대로 유지한다.

1. `checkpoint_id`, expected-before, 대상 ID, 수치 유한성, 범위, 중복/alias 충돌 확인.
2. 원본 task contract와 보호된 graph/status/zone fingerprint 저장.
3. 선언된 global transform을 의존 순서에 맞춰 `set_desired_global_transform!`로 적용. 최종 값이 선언과 같은지 확인. 하나라도 불일치면 전체 기각.
4. 전체 transform diff와 실제 영향을 받은 dependency footprint 계산. 완료된 구조의 상대 기하, attachment, pickup/deposit/lift 대응 관계를 검사.
5. 필요한 scene resync 수행. 현재 공개 래퍼가 바꾼 객체를 전후 diff로 기록. 선언된 기하의 dependency footprint 밖 객체가 움직이면 V1은 기각한다.
6. 원래 runtime과 같은 cache resume/preprocess/필요한 assignment resolve를 한 번의 공통 경로로 수행. 현재 `enact_minted!` 안의 후처리와 이중 호출하지 않도록 내부 helper를 분리한다. 재배정이 정당하게 바꾸는 binding과 모델이 금지된 구조를 바꾸는 행위를 별도 기록한다.
7. RVO와 route 파생 상태를 갱신한 후 transaction postcondition 검사. 이 재구축이 원래 동적 상태를 바꾸지 않는지 선행 게이트에서 확인한다.
8. 같은 주입 조건/스케줄러로 전체 후속 실행.

`resync` postcondition은 **이동된 자유 본체와 대응 TU의 기준 기하**에 적용한다. 로봇 현재 위치를 목적지와 같게 강제하지 않는다. 잡힌 cargo나 이미 배치된 부품을 free object처럼 teleport하지 않는다.

현재 helper는 XY 거리 tol만 보므로 단순히 호출됐다는 로그로 통과시키지 않는다. 위치 오차 tolerance는 pickup/capture 판정에 쓰는 실제 허용치보다 엄격하게 정하고 manifest에 넣는다. 작은 drift를 helper가 남기면 기각하고 원인을 보고한다. 필요하면 별도 후속 변경에서 helper에 선택 대상·tol·이동 보고 기능을 추가하되 기존 호출의 기본 의미는 유지한다.

**최종 task 의미 검사:** 원래 필수 작업·부품 수·선후 관계를 유지하고, 원래 설계의 조립 상대 변환/attachment를 만족해야 한다. 허용된 세계 평행이동만 원본 contract에 반영한다. 수정된 목표를 자기 자신의 성공 기준으로 사용하지 않는다. nav goal을 start로 바꿔 이동을 없앴더라도 실제 deposit/assembly 조건을 충족해야 성공이다.

`zone_blockage(check_paths=true)` 및 `free_space_status`는 존과 항법 관련 센서로 사용한다. 이것만으로 full-scene collision-free 또는 전체 build feasibility를 인증하지 않는다. 신규 collision validator가 없으면 그 항목은 `unverified`로 남기고, 완주 보장과 물리 안전 보장을 혼용하지 않는다.

실제 diff가 없는 patch는 `noop_equivalent`. partial/throw/NaN/목표 setter 불일치/미지원 물리 이동은 기각한다. 아직 남아 있는 다른 blocked goal이 있다는 이유만으로 전체 복구 가능성을 부정하지는 않으며 최종 완주 실행이 결정한다.

## 7. 전체 실행, 채택, 커밋

### 7.1 고정 continuation과 예산

`pi0`: 존은 NOOP, 존 전용 solver/자동 복구 사다리는 차단, 나머지는 manifest에 고정한 공통 정책. 일반 복구도 종류별 실제 발동 횟수를 기록한다.

원본 task contract의 전체 완료 조건, 기존 runtime의 terminal stall 조건, episode 절대 simulation-step/시간 상한을 분기마다 동일하게 적용한다. 숫자는 역사적 campaign 설정을 확인해 새 manifest에 **필수 명시**하고, 비어 있으면 실행을 거절한다. 후보마다 예산을 새로 늘리거나 progress counter를 초기화하지 않는다.

worker wall timeout은 simulation failure와 다른 `UNKNOWN`이다. provider/solver 오류도 별도 필드로 남긴다. 느린 후보가 더 긴 simulated horizon을 얻어서는 안 된다.

### 7.2 상태 기계

```text
CAPTURED -> IDENTITY_VERIFIED -> PROPOSALS_FROZEN
         -> BASELINE_AND_CANDIDATE_ROLLOUTS
         -> SELECTED_NOOP | SELECTED_PATCH
         -> PRECOMMIT_VERIFIED -> COMMITTED -> REPLAY_CHECKED

각 검증 오류 -> REJECT_CANDIDATE 또는 CERTIFICATION_UNAVAILABLE
```

모델 성능을 재는 주 실험은 후보를 기준 분기 결과를 보기 전에 생성·동결한다. 최대 후보 수 K=4, 모델 호출 최대 4회(최초 포함)를 기본 설계값으로 고정한다. 후보 간 모든 model/token/rollout 비용을 합산한다. 총 token 한도와 wall 예산은 실행 manifest에 추가로 필수 지정한다.

V1의 후속 모델 호출에는 **정적/transaction 검사 실패**만 제공하고 전체 rollout의 완주·미완주나 미래 사건은 제공하지 않는다. rollout 피드백을 통한 재탐색은 별도 `search_feedback` 팔이다. K=1과 K=4를 나눠 모델 자체 개선과 샘플 수 효과를 분리한다.

| 기준 분기 | 후보 분기 | 선택 및 분류 |
|---|---|---|
| COMPLETE | 무엇이든 | NOOP. 후보가 실패면 raw regression으로 기록 |
| FAIL_WITHIN_BUDGET | COMPLETE + task/transaction 검사 통과 | PATCH. rescued로 기록 |
| FAIL_WITHIN_BUDGET | 실패·거절·UNKNOWN | NOOP. 해결 실패 |
| UNKNOWN / identity mismatch | 무엇이든 | NOOP. 인증 불가. rescue 분모에서 조용히 제외하지 않음 |

여러 후보가 통과하면 수정된 unique config 수, 전체 XY 이동 norm 합, proposal 순서의 사전 고정 lexicographic 순서로 선택한다. 기본 목적은 완주 보존이며 makespan/energy 최적화는 보조 보고다.

배포형 운용은 baseline이 COMPLETE이면 후보 생성을 생략할 수 있다. 다만 모델 평가에서는 쉬운 시드에도 후보를 생성·재생하여 raw regression이 숨지 않게 한다.

### 7.3 커밋 계약

완료된 shadow의 terminal state를 `t0`에 덮어쓰지 않는다. 원래 `t0`에 선택한 **동일 patch transaction**만 적용하고 검증 때 사용한 continuation을 실행한다. 시뮬레이션 미래 시간을 건너뛰어서는 안 된다.

certificate는 checkpoint/config/task-contract digest, proposal/실제 diff digest, continuation digest, 외생 난수 식별자, budget, validator 버전, baseline/candidate 결과를 포함한다. precommit에서 현재 세계의 상태가 `t0`와 같고 cert가 유효한지 확인한다. 달라졌으면 기각하고 새 상태에서 다시 검증해야 한다.

주 세계에서 transaction을 실행하는 동안은 tick을 진행하지 않는다. 예외가 나면 검증된 full checkpoint 복원 후 NOOP로 재개한다. transaction 후 상태를 shadow의 post-transaction 상태와 비교한다. 이후 trajectory/terminal replay가 다르면 **보장 위반**으로 보고하고 해당 campaign 인증을 중단한다. 사후 검출은 이미 발생한 실패를 없애는 장치가 아니다.

V1의 기본 증명은 간단하다. baseline이 완주하면 동일한 상태에서 같은 pi0를 실행한다. baseline이 실패할 때는 완주가 확인된 후보만 같은 조건으로 실행한다. 이 증명에 정확한 상태 복원/고정 continuation/일치하는 미래 실현 중 하나라도 빠지면 보장은 성립하지 않는다.

## 8. 검증기의 역할과 한계

기하 patch는 모델이 계산한 목표 위치 변경이다. 실행기는 변경 후 기하·작업 정합성을 검사하고, 동일 checkpoint에서 존 NOOP와 수정안을 각각 끝까지 실행해 채택 여부를 결정한다. 목적지나 이동량을 대신 계산하는 최적화기를 추가하지 않는다.

수정 대상 목표의 존 여유와 도달 가능성을 검사하되, 완주에 불필요한 원래 blocked goal까지 모두 이동하도록 강제하지 않는다. `closed` 증가, `nav_blocked` 감소, 존 해소만으로 완주를 인정하지 않는다.

전체 후속 실행을 짧은 horizon으로 대체하면 이후 stall을 놓칠 수 있다. 이 설계는 명시된 종료 예산까지 실행하고, 검증을 끝내지 못한 분기는 `UNKNOWN`으로 처리한다. 완주 보장 범위는 §1과 §7의 재현 조건으로 한정한다.

## 9. 검증 실험과 채점

### 9.1 코호트와 데이터

기본 격자는 tractor/X-wing × zone/all3 × 30 seeds = 120 episode. 계획한 모든 판을 주 분모에 유지하고 timeout/provider error/인증 불가를 따로 표시한다. 기존 A2의 116, hard 89는 관측 분모이며 새 실험의 고정 분모로 사용하지 않는다.

역사적 코호트 manifest에는 다음 membership을 저장한다: easy 27, hard 93, A2 easy-success 14, A2 regression 13, A2 rescue 4. 사용자 분석의 4개 anchor는 tractor all3 s2, tractor zone s5, tractor zone s16, X-wing zone s4다. 나머지 membership은 기존 결과 join으로 추출하고 수가 어긋나면 원인부터 보고한다.

4개 anchor의 실제 body와 최종 task 의미를 먼저 감사한다. 강화된 task contract가 기존 성공을 거절하면 `historical_complete_but_contract_invalid`로 기록한다. 기존 성공을 유지하려고 invariant를 완화하지 않는다. 유효한 body는 trace→declarative patch의 수동 변환 fixture로 보관하여 이동 기전이 새 인터페이스에서도 표현되는지 검사한다. fixture나 성공 좌표는 모델 프롬프트에 넣지 않는다.

### 9.2 팔

| 팔 | 제안 방식 | 실행 | 용도 |
|---|---|---|---|
| B0 | zone NOOP | pi0 | 동시대 기준 |
| L0 | 역사적 A2 body trace | 원본 동작을 worker에서 재생 | 역사적 재현 |
| L1 | L0와 동일 body/params | resync만 추가한 통제 재생 | resync 인과 효과. 다른 개선을 섞지 않음 |
| G1 | 기하 전용 안내, K=1 | transaction; 후보 worker 결과 | guided 모델의 첫 후보 해결률/회귀율 |
| G4 | 같은 안내, K=4 | 같은 transaction; 후보 worker 결과 | 샘플 수 효과 |
| V4 | G4의 **동일 후보** | 전체 NOOP 비교 후 채택 | 검증기의 순수 선택 효과 |

G1/G4는 보호 없이 주 세계를 훼손시키는 팔이 아니라 candidate worker의 raw outcome을 채점한다. L1은 원본 body가 직접 step을 호출한 위치까지 고려해 resync 삽입 위치를 명시하고 기록한다. 이후 새 transaction의 효과와 합쳐 인과 해석하지 않는다.

선택적으로 같은 declarative 인터페이스에 절차 안내를 제거한 G0를 추가하면 출력 형식 효과와 풀이 안내 효과를 분리할 수 있다. 안내에 성공 기전(기하 변경)을 명시하므로 G1/G4는 **guided A2**이며 기존의 무유도 기전 발견 능력을 재는 실험과 다르다.

새 seed 집합은 코호트·프롬프트·budget·validator를 동결한 뒤 사용한다. 원래 120개는 개발/회귀 세트로 표시한다. 지도 4판의 seed/좌표로 조건 분기하지 않는다.

### 9.3 지표

- `rescue_rate = selected_complete / contemporaneous_B0_failures`, UNKNOWN 별도. 역사적 hard 코호트 성적도 병기.
- `raw_regression_rate = candidate_failed / B0_complete`; 첫 후보와 best-of-K를 구분.
- `selected_regression_rate = selected_failed / B0_complete`; 인증 불가와 replay mismatch도 숨기지 않음.
- `easy_preserved`, `valid_anchor_retained`, `rejected_harmful`, `noop_equivalent`, partial/throw/desync/contract reject 수.
- 목표별 nav block 수, target kind, zone 해소 여부, resync 실제 이동 대상/거리, scene residual, 필수 task 만족 여부.
- model calls/tokens/cost, 모든 branch CPU·wall·sim steps, 검증 지연 p50/p95/max, makespan/energy.
- 사람이 쓴 존 solver 호출·자동 존 ladder 발동 수. 숨은 기여가 있으면 별도 분류.

L1이 8판을 복구하는지는 측정할 가설이다. resync 미호출이라는 상관만으로 실패 원인이 증명됐다고 쓰지 않는다. V4의 easy 보존을 모델 rescue로 합산하지 않는다.

## 10. 구현 파일과 완료 게이트

| 파일(제안) | 책임 |
|---|---|
| `src/verification/episode_checkpoint.jl` | 전체 checkpoint adapter, 복원·동등성·alias 검사 |
| `src/respec/geometry_patch.jl` | patch schema, stable ref, dependency footprint, contract validation |
| `src/respec/geometry_transaction.jl` | setters/resync/후처리의 원자적 실행과 diff |
| `src/verification/repair_supervisor.jl` | certificate, selection, precommit, replay 검사 |
| `tools/monitor/repair_branch_worker.jl` | 프로세스별 실제 runtime continuation, shadow logs |
| `tools/monitor/render_demo.jl`, `tools/monitor/enact.jl` | t0 capture와 존 전용 dispatch, 기존 후처리 중복 제거 |
| `src/respec/llm_service/`의 실제 출력 schema·prompt 위치 | declarative proposal와 guided 조건. 위치는 구현 때 호출 경로 확인 |
| `tools/monitor/grid/` | pairing manifest, 고정 budgets, planned denominator, 지문 |
| `test/repair_*.jl` | 아래 acceptance tests |
| `results/2026-09-24-zone-repair-verification/` | 추후 manifest, checkpoints, branch/candidate/selection/replay 원장 |

순서와 통과 조건:

1. **데이터 게이트:** 역사적 4/13/27 membership과 실제 실행 body chain을 확인. source snapshot 복원 실패·prefix 차이를 명시.
2. **checkpoint 게이트:** mutation 없는 live continuation과 export/import NOOP continuation을 전체 종료까지 비교. NOOP 두 분기만 서로 같은 것으로 대체하지 않음. easy/hard, robot/TU, zone/all3 경계를 포함. actor/global/RNG/queue를 바꿨다가 복원하는 fault injection 및 alias 검사.
3. **격리 게이트:** branch A가 zone/cache/RVO/spare/ID/RNG를 바꾸어도 parent와 B의 후속 궤적은 불변. 실행 순서 N→A와 A→N이 같아야 함. worker crash/timeout도 parent를 바꾸지 않음.
4. **transaction 게이트:** 첫 setter 후 throw, 두 번째 setter 실패, alias 중복, NaN, stale checkpoint, 금지 graph 변경을 주입. 모두 기각되고 parent와 NOOP 궤적 동일. no-op에서 불필요한 resync가 세계를 바꾸지 않는지 검사.
5. **정합성 게이트:** 이동된 free body/TU, 이동하지 않은 robot, grasped cargo, 작은 drift, unrelated drift를 포함. resync가 돌아도 contract를 깨면 거절. goal=start 및 task 삭제를 이용한 허위 complete를 검출.
6. **전체 실행 게이트:** 초반 progress 후 장기 stall 후보, nav_blocked=0 후 stall 후보를 거절. horizon/UNKNOWN 처리와 candidate별 예산 재설정 금지 시험.
7. **코호트 게이트:** 유효한 4개 성공 기전은 표현·재생 가능해야 함. 역사적 13판의 해당 raw harm을 재현했다면 선택기는 모두 기각해야 함. 역사적 easy 27 중 새 B0도 완주하는 판은 전부 보존. B0에서 달라진 판은 baseline drift로 별도 조사.
8. **커밋 게이트:** 선택 patch의 실제 commit+continuation이 shadow의 post-state 및 terminal outcome을 재현. state mismatch면 인증 중단. shadow terminal state를 복사하는 구현은 금지.
9. **모델 실험:** 위 게이트 후 G1/G4/V4 수행. hard rescue 증가는 실험 목표이며 설계만으로 성공을 약속하지 않음.

이 문서 작성 단계에서는 구현 시험·유료 모델 호출·전체 sweep을 실행하지 않았다.
