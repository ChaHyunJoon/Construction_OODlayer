# 6번·7번 설계 — 복구가능성 사전점검 / 자동등록·재학습

*작성 2026-07-28. 범위 **A**(파이프라인 동작 증명: mock 신규 kind, e2e 1회 통과).
측정 근거를 만드는 범위 B는 5번에서만 한다.*

관련: [artifacts_openworld/README.md](../artifacts_openworld/README.md) (현황), `md/EVALUATION.md`, `md/STATUS.md`

---

## 0. 이 문서가 정하는 것

| | 무엇을 | 왜 지금 |
|---|---|---|
| **7-a** | 어휘(vocabulary) 단일 진실원본 registry | 6번·7번·5번이 **전부** 이걸 읽는다. 먼저 안 하면 세 번 중복 구현 |
| **6** | 실행 전 복구가능성 게이트 (L2) | 현재는 되돌릴 수 없는 수술을 **한 뒤에** 실패를 안다 |
| **7-b** | 자동 등록 → 라벨 → 재학습 → 배포 오케스트레이터 | 재료는 다 있음. 새로 만들 것은 **배포 게이트** |

범위 A에서 **하지 않는** 것: 새 DSL 제약 타입 추가, 새 OOD를 시뮬레이터에 실제 주입, LOKO 측정.
(전부 5번의 몫이다. 여기서는 mock 신규 kind 하나로 배관이 뚫리는지만 본다.)

---

## 1. 공통 전제 — 어휘가 세 종류인데 여섯 곳에 흩어져 있다

먼저 **이름이 섞여 있다는 것**부터 풀어야 한다. 지금 "kind"라는 말이 서로 다른 세 가지를 가리킨다.

| 층 | 우리말 | 무엇인가 | 현재 개수 |
|---|---|---|---|
| **EVENT** | 사건 종류 | 세상에서 벌어진 일 (로봇이 고장났다 / 배터리가 닳았다) | 3~4 (불일치) |
| **ACTION** | 대응 매크로 | 우리가 고를 수 있는 대응 (교체한다 / 아무것도 안 한다) | 5 |
| **CONSTRAINT** | DSL 제약 | 그 대응을 솔버가 읽는 형식으로 적은 것 | 6 |

**EVENT ≠ ACTION ≠ CONSTRAINT**인데, 예를 들어 `zone`(사건)과 `ForbidZone`(제약)이 이름이 겹쳐
읽는 사람이 같은 것으로 착각하게 되어 있다. registry는 이 셋을 분리해서 적는다.

### 실측: 지금 어휘가 박혀 있는 여섯 곳

| # | 파일 | 무엇이 | 개수 |
|---|---|---|---|
| 1 | [schema.py:179](../../ConstructionBots.jl/src/respec/llm_service/schema.py#L179) | TOOL_SCHEMA enum (+ Pydantic 클래스 6개) | CONSTRAINT 6 |
| 2 | [spec_dsl.jl:59-175](../../ConstructionBots.jl/src/respec/spec_dsl.jl#L59) | struct 정의 | CONSTRAINT 6 |
| 3 | [e1_analyze.py:139](../e1_analyze.py#L139) | `kinds = ["fault","battery","zone","zoneblk"]` one-hot | EVENT 4 |
| 4 | [export_surrogate.py:97](../export_surrogate.py#L97) | `MACRO_COST` | ACTION 5 |
| 4' | [export_surrogate.py:258](../export_surrogate.py#L258), [:309](../export_surrogate.py#L309) | `names` dict가 **두 번 따로** 정의됨 | ACTION 5 ×2 |
| 4'' | [export_surrogate.py:108](../export_surrogate.py#L108) | `INTERACT`에 `kind_fault/kind_battery/kind_zoneblk` | EVENT 3 |
| 5 | [ood_stream.jl:119](../../ConstructionBots.jl/src/navigator/ood_stream.jl#L119) | `kinds=[:fault,:battery,:zone]` | EVENT 3 |
| 6 | [ood_mdp_shim.jl](../oracle/ood_mdp_shim.jl) | `valid_actions` / `canonical_action` | EVENT→ACTION 표 |

**신규 EVENT 하나 추가 = 여섯 곳 수동 편집.** 그리고 3번(EVENT 4)과 5번(EVENT 3)이 이미
어긋나 있다 — `zoneblk`는 라벨 데이터에는 있는데 주입기에는 없다. 이런 어긋남이 조용히
생기는 구조가 자동화의 진짜 적이다.

### 7-a 설계: `registry/ood_registry.json` + 양쪽 로더

```jsonc
{
  "version": 4,
  "events": [                                  // EVENT: 사건 종류
    {"name": "fault",   "status": "stable",
     "valid_macros": [0, 1, 2], "canonical": 1,
     "descriptors": {"harm": "severity", "resource_loss": "1.0"}},
    {"name": "battery", "status": "stable",  "valid_macros": [0, 1, 2], "canonical": 2, ...},
    {"name": "zoneblk", "status": "stable",  "valid_macros": [0, 3],    "canonical": 3, ...}
  ],
  "macros": [                                  // ACTION: 대응 매크로
    {"id": 0, "name": "NOOP",         "constraint": null,               "cost": 0.0},
    {"id": 1, "name": "Replace",      "constraint": "ReplaceAgent",     "cost": 1.0},
    {"id": 2, "name": "Deprioritize", "constraint": "DeprioritizeAgent","cost": 0.3},
    {"id": 3, "name": "ForbidZone",   "constraint": "ForbidZone",       "cost": 1.0},
    {"id": 4, "name": "ReformTeam",   "constraint": "ReformTeam",       "cost": 1.0}
  ],
  "constraints": ["ForbidWindow","ForbidAgent","ForbidZone",
                  "ReplaceAgent","ReformTeam","DeprioritizeAgent"]
}
```

**핵심 결정: Julia 쪽 타입은 registry에서 만들지 않는다.**
`spec_dsl.jl`의 struct는 컴파일 타임 타입이라 런타임 생성이 위험하다. 대신 Julia는 registry를
**읽어서 대조만** 한다(`src/respec/ood_registry.jl`: `known_events()`, `valid_macros(event)`).
어긋나면 로드 시점에 에러. → **범위 A에서 신규 EVENT는 기존 매크로 조합으로만 처리**되므로
Julia 코드 변경이 0이다. 이것이 A를 싸게 만드는 결정이며, 5번의 parameterized macro family와
같은 철학이다(실행 가능성은 닫아두고 어휘만 연다).

**소비처 개조**: 1·3·4·4'·4''·5·6번을 registry 참조로 바꾼다. 특히 4'의 중복 `names` dict 두 개는
제거. `featurize`의 one-hot 열은 registry 순서로 **생성**한다(그래야 신규 EVENT가 자동으로 열을 얻는다
— 지금은 신규 kind가 "전부 0인 행"이 되는 바로 그 구조적 문제).

**재발 방지**: `tools/check_registry_sync.py`가 여섯 곳을 실제로 파싱해 registry와 대조.
`verify.py`에 **R1 항목**으로 편입해 정규 시험지(현 8문항 → 9문항)에 넣는다.
이 검사 하나가 "수동 동기화 여섯 곳" 문제를 영구히 끝낸다.

---

## 2. 6번 — 실행 전 복구가능성 사전점검 (L2 게이트)

### 2.1 지금 무엇이 문제인가

현재 게이트는 다섯 갈래인데, **MILP를 타는 하나만 실현가능성을 실제로 확인한다.**

| 경로 | 검사하는 것 | 복구가능성 |
|---|---|---|
| [verify()](../../ConstructionBots.jl/src/respec/verifier.jl#L83) (스케줄 제약) | 문법 + 과거불변 + **MILP 풀이** | ✅ 사전 확인 |
| [verify_zone()](../../ConstructionBots.jl/src/respec/verifier.jl#L141) | 과거불변 + 구역 실존 | ❌ |
| [verify_replace()](../../ConstructionBots.jl/src/respec/verifier.jl#L173) | 과거불변 + spare 존재 | ❌ |
| [verify_deprioritize()](../../ConstructionBots.jl/src/respec/verifier.jl#L213) | 과거불변 + 로봇 실존 | (불필요 — soft라 구조적으로 안전) |
| [verify_reform()](../../ConstructionBots.jl/src/respec/verifier.jl#L241) | 낀 팀 실존 | ❌ |

`verify_zone`·`verify_replace`의 docstring이 이미 이걸 자백하고 있다:
> *"Feasibility-of-recovery is NOT decided here … so an admissible-but-unrecoverable zone still fails closed."*

fail-closed니까 **안전하기는 하다.** 문제는 **비용과 시점**이다:

1. 실패를 아는 시점이 `restage_all_blocked!` / `replace_robot!`이 **씬트리를 이미 수술한 뒤**다
   ([replan.jl:392](../../ConstructionBots.jl/src/respec/replan.jl#L392)의 `:residual_blocked` 등).
2. 그리고 그 실패의 결말이 `engage_fallback!` = **라인 전체 정지**다. 건강한 다른 로봇들의
   독립적인 일까지 같이 멈춘다.
3. 우리는 이 실패모드들을 **이미 겪었다**: phantom-spare double-book, mid-build Replace의
   cyclic OpenBuildStep 의존. 즉 "무엇을 잡아야 하는지" 알고 시작할 수 있다.

### 2.2 설계: 3단 사다리 — 싼 것부터, 비싼 것은 의심될 때만

```
        제안(proposal)
             │
        [기존 싼 검사]  과거불변 · 존재성          ← 지금 있는 것
             │
   ┌─────────┴──────────┐
   │  R0  자원 회계      │  ~1ms   스페어 예약회계 · 커버리지
   │  R1  그래프 도달성  │  ~10ms  드라이런 후 사이클/도달불가 검사
   │  R2  짧은 롤아웃    │  ~초    ★ 게이트가 의심할 때만
   └─────────┬──────────┘
             │
        Admit / Reject(:unrecoverable)
```

**R0 — 자원 회계 (정적, ~1ms)**

- *Replace*: 지금은 `isempty(active_spares())` 하나만 본다. 이를 **예약 회계**로 승격 —
  이미 다른 fault에 배정 예약된 spare를 빼고 센다. (phantom-spare double-book 때 만든
  A-1 배정제외 상태를 **읽기만** 하면 되므로 새 상태를 만들지 않는다.)
- *ForbidZone*: 구역이 덮은 disc 집합에 대해 **옮길 자리가 존재하는지**만 기하 예산으로 확인
  (실제 이동 전에 후보 위치 존재성만).
- *공통 — 커버리지*: 이 대응이 제거·차단하는 자원 이후에도 **모든 열린 작업에 수행 가능한
  로봇이 최소 1대 남는가.** "완주 불가"의 가장 흔한 원인이 여기서 잡힌다.

**R1 — 그래프 도달가능성 (~10ms)**

- 제안을 **스케줄 그래프 복사본에** 드라이런 적용 → 열린 노드들의 전제조건에
  **사이클이나 도달불가**가 생기는지 검사(`Graphs.is_cyclic` / 위상정렬 시도).
- mid-build Replace 완주 실패의 원인이 정확히 cyclic OpenBuildStep 의존이었으므로
  **이미 관측된 실패를 재현 검사로 갖고 시작한다.** (반증 시험 재료가 확보돼 있다는 뜻)
- 씬트리 전체가 아니라 **스케줄 그래프만** 복사하므로 싸다.

**R2 — 짧은 롤아웃 (초 단위, 조건부)**

- R0·R1을 통과했지만 3번에서 만든 `escalation_verdict`(모델 내부 이견 / 입력 낯섦도)가
  **"확인 권고"**를 낸 경우에만 실행.
- **여기서 3번의 잔여 작업과 6번이 합쳐진다.** README 5절이 남긴 숙제 —
  *"게이트가 확인 권고를 냈을 때 실제로 오라클을 호출하고 그 결과로 대응을 바꾸는 배선"* —
  이 R2 그 자체다. 두 개를 따로 만들지 말고 **하나로 구현한다.**

### 2.3 핵심 설계 판단 — 거부기가 아니라 **강등기**로 만든다

가장 중요한 결정이다. R0/R1이 "불가"를 냈을 때 **정지시키면 안 된다.**

"Replace 불가"의 올바른 대응은 라인 정지가 아니라 **Deprioritize나 재분배**다. 그리고 그 강등
경로는 **이미 코드에 있다** — [`_replace_via_reassign!`](../../ConstructionBots.jl/src/respec/replan.jl#L243)이
"스페어가 없으면 전체를 얼리지 말고 다른 활성 로봇에게 재분배"를 정확히 그렇게 한다.
지금은 그 강등이 `replace` 한 경로에만 하드코딩돼 있을 뿐이다.

그래서:

```
R0/R1 불가  →  registry.valid_macros(event)에서 다음 후보를 producer에게 요청
            →  재검증 (최대 2회)
            →  모든 후보가 불가일 때만  engage_fallback!  (라인 정지)
```

이래야 6번이 "제안을 더 많이 거절하는 장치"가 아니라 **"멈추는 대신 차선을 찾는 장치"**가 된다.
정지는 최후에만.

### 2.4 구현 형태 (기존 호출부 무변경)

- `Verdict` 타입을 늘리지 않는다. **`Reject(:unrecoverable, detail)`** 새 사유만 추가 —
  호출부 14곳이 전부 `isa Reject`로 분기하므로 기존 코드 수정이 0이다.
- 삽입점: 각 `verify_*`의 마지막 `return Admit(...)` 직전 5곳 + `verify()` 1곳.
- **opt-in 플래그**로 켠다(`set_recoverability_gate!`). CBF의 `set_failclosed_stop!`과 같은 이유 —
  무조건 켜면 기존 데모 전부의 거동이 바뀐다.

### 2.5 검증 계획

| 무엇 | 어떻게 | 왜 이게 증거인가 |
|---|---|---|
| 단위 12~16문항 | `tools/test_recoverability.jl` — 스페어 0/예약초과/사이클 주입 | 게이트가 **잡아야 할 것을 잡는다** |
| **반증 시험** | 이미 관측된 실패(mid-build Replace 과다구독)를 R0가 **사전에** 잡는가 | 사후→사전 전환이 실제로 일어났다 |
| 회귀 (기계 2~3h) | B5 6/6 · B7 3-OOD 스트림 · hot-swap 데모를 게이트 켠 채 완주 | 게이트가 **과잉거부하지 않는다** |

세 번째가 가장 중요하다. 안전 게이트는 아무것도 통과 안 시키면 100% 안전하므로,
**"멀쩡한 것을 막지 않는다"**는 증거가 없으면 게이트를 켤 수 없다.

---

## 3. 7-b — 자동 등록 → 라벨 → 재학습 → 배포

### 3.1 재료는 이미 다 있다

| 단계 | 쓸 것 | 상태 |
|---|---|---|
| 라벨 생성 | `oracle/run_parallel_openworld.ps1` + `gen_oracle_dataset.jl` + `ood_mdp_shim.jl` | ✅ 있음 (3 lanes, RAM 상한) |
| 학습·평가 | `surrogate_model.py` (RF 단일화 완료) | ✅ 있음 |
| 배포 | `export_surrogate.py --cost-aware` → `surrogate_linear.json` | ✅ 있음 |
| 검증 | `verify.py` 8문항 | ✅ 있음 |

**새로 만들 것은 오케스트레이터 하나와 — 진짜 산출물인 — 배포 게이트다.**

### 3.2 `autoregister.py` 7단계

```
1 DETECT     미지 사건 신호 수집.  범위 A에서는 `--new-kind mockfail` CLI로 mock 주입 허용
2 REGISTER   registry에 status:"provisional"로 등록.
             valid_macros=전체(보수적), canonical=0(NOOP, 가장 안전)
3 LABEL      run_parallel_openworld.ps1을 신규 unit mix로 호출
             (A범위 최소: seed 2 x progress 2 = 4 unit, 3 lanes로 약 40분)
4 MERGE      기존 + 신규 -> merged_v<N>.jsonl.  ★ 원본은 절대 덮어쓰지 않음(9.2h 자산)
5 RETRAIN    export_surrogate.py --cost-aware + LOO 정직성 검사
6 GATE       아래 3조건 전부 통과해야만 배포              ← 이 단계가 핵심
7 DEPLOY     원자적 교체(tmp -> rename, 이전 것은 .bak.v<N>) + Julia 스모크 -> 실패 시 자동 롤백
```

### 3.3 배포 게이트 — 자기진화가 자기퇴화가 되지 않게

**재학습 자동화 자체에는 위험이 없다(스크립트 이어붙이기다). 위험은 게이트 없는 자동 배포다.**
이 프로젝트는 이미 그 실패모드를 두 번 겪었다:

- 평가는 HistGradientBoosting, 배포는 RandomForest → **발표 숫자가 배포된 시스템을 설명하지 못함**
- export 정직성 검사가 raw `closed`로 채점 → 광고된 regret `0.000`의 실제 값이 `0.100`

그래서 통과 조건을 **세 개** 둔다. 하나라도 실패하면 배포하지 않고 이전 모델을 유지한다.

| 조건 | 기준 | 막는 실패 |
|---|---|---|
| **G1 무회귀** | `verify.py` 점수가 기존 이하로 떨어지지 않음 (현 legacy 7/8 유지) | 물리 상식 위반 모델의 배포 |
| **G2 기존 kind 보호** | 기존 EVENT들의 LOIO regret이 유의하게 나빠지지 않음 (paired bootstrap CI 상한 < +0.02) | 신규 데이터가 기존 성능을 갉아먹는 것 |
| **G3 신규 kind 유효** | 신규 EVENT에서 `always_per_kind` / NOOP 베이스라인보다 나음 | "배웠다"는 착각 (실제로는 아무것도 안 배움) |

**버전 고정**: 모든 산출물에 `registry.version`을 새긴다(`surrogate_*.json`의 `meta`에 필드 추가).
Julia 로더가 registry 버전과 모델 버전이 다르면 **거부**한다 — 어휘와 모델이 어긋난 채
돌아가는 상황을 원천 차단.

### 3.4 범위 A의 성공 판정

> mock 신규 EVENT 하나를 넣고 `autoregister.py`를 한 번 돌렸을 때,
> **사람 개입 없이** registry 등록 → 라벨 4 unit → 재학습 → 게이트 판정 → (통과 시) 배포 →
> Julia 스모크까지 도달하고, **G1~G3 중 하나를 일부러 실패시키면 배포가 차단되고 롤백된다.**

두 번째 절이 첫 번째보다 중요하다. 게이트가 실제로 막는 것을 보여야 게이트다.

---

## 4. 실행 순서와 시간

registry가 6번의 강등 루프(`valid_macros`)에도 쓰이므로 **7-a를 먼저** 한다.

| 순서 | 항목 | 구현 | 기계 |
|---|---|---|---|
| 1 | **7-a** registry + 6곳 개조 + sync 검사(verify.py R1) | 4.5h | — |
| 2 | **6** R0 (2.5h) · R1 (3h) · 강등 루프 (2h) · 시험 (2h) | 9.5h | 2~3h (회귀 3데모) |
| 3 | **7-b** 오케스트레이터 + 배포 게이트 + 원자적 교체/롤백 | 4h | — |
| 4 | e2e 1회 (mock kind, 4 unit) + 게이트 차단 실증 | 2h | ~1h |
| | **합계** | **20h** | **3~4h** (구현과 병렬) |

> 앞서 A범위를 12~18h로 잡았는데 **20h로 올렸다.** 차이는 registry 통합(4.5h)을 제대로 넣었기
> 때문이다. 최소로 하면(신규 kind 등록 경로만, 6곳 개조 생략) 15h지만, 그러면 5번에서 같은 일을
> 다시 하게 되고 어긋남도 그대로 남는다. **20h를 권한다.**

자율 세션 2회(각 ~10h) 규모.

---

## 5. 결정이 필요한 지점 하나

**6번의 강등 루프(2.3절)를 이번에 넣을 것인가.**

- **넣으면**: 6번이 "멈추는 대신 차선을 찾는" 장치가 되어 실제로 유용하다. 대신 기존 데모들의
  거동이 바뀔 수 있어 회귀 확인 범위가 넓어진다(위 표의 기계 2~3h가 여기서 나온다).
- **안 넣으면**: 순수 거부 게이트. 구현 2h 절약, 회귀 위험 0. 하지만 "복구 불가를 미리 알았는데
  결국 라인을 세운다"가 되어 6번의 값어치가 절반이다.

**권장: 넣되 opt-in 플래그 뒤에 둔다.** 기본 OFF면 기존 데모는 무변경이고, 회귀 확인은
플래그 ON인 새 시나리오에서만 하면 된다. CBF의 `set_failclosed_stop!`에서 이미 검증된 방식이다.
