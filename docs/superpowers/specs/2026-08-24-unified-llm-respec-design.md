# 통합 LLM 재명세(re-specification) 설계

- 날짜: 2026-08-24
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`)
- 상태: 설계 승인됨. 구현 계획은 별도 문서.

---

## 0. 한 줄 요약

OOD 사건을 **하나의 LLM**(DSPy/gpt-4o)이 인식 → 번역 → 결정까지 한 번의 호출로 처리하게 만든다.
Claude `/propose` 경로는 제거한다. 1단계에서 번역(DSL)은 **채점·검사용 부산물**이고 집행은
지금처럼 매크로가 한다. 번역이 믿을 만하다고 측정된 뒤에 2단계에서 집행을 넘긴다.

---

## 1. 배경 — 현재 실제 배선 (측정된 사실)

두 개의 LLM 경로가 서로 다른 일을 하고, 그 사이는 하드코딩된 줄리아 규칙표다.

| | 레인 1 (번역) | 레인 2 (결정) |
|---|---|---|
| 서비스 | `llm_service/server.py` | `llm_service/dspy_service.py` |
| 모델 | Claude (`RESPEC_MODEL`, 기본 `claude-opus-4-8`) | gpt-4o (DSPy MIPROv2 컴파일 arm) |
| 키 | `ANTHROPIC_API_KEY` | `OPENAI_API_KEY` |
| 포트 | 8000 | 8077 (`policy.jl` 기본) / 8090 (`llm_ood_eval.py --dspy-url` 기본) |
| 입력 | NL 사건 + 엔티티 id 목록 | NL 관찰 + 서술자 6개 + valid 메뉴 |
| 출력 | DSL 제약 (`schema.py` 검증) | 매크로 이름 하나 |
| 호출부 | `llm_bridge.jl` → `maybe_respecify!` | `policy.jl:service_decide` |
| 살아 있는 곳 | `render_demo.jl` + `DEMO_LLM=1` **뿐** | `run_demo.jl` (측정 레인) |

핵심 사실 세 가지:

1. **측정 레인에는 번역 단계가 없다.** `run_demo.jl`은 `RESPEC_ENABLED=false`로 두고 고른
   매크로를 자체 if/elseif 사슬로 직접 집행한다(`hot_swap_robot!` / `swap_battery!` /
   `restage_all_blocked!`). DSL도 `verify()`도 `maybe_respecify!`도 타지 않는다.
   따라서 지금까지의 `dspy` 정책 수치는 **번역이 존재하지 않는 세계**의 것이다.
2. **Claude 제거는 측정 레인을 건드리지 않는다.** `/propose`는 렌더 데모와 오프라인
   `translate_eval.py`에서만 쓰인다.
3. **레인 2에는 엔티티 id 채널이 없다.** `MacroRequest`에 `agents`/`nodes`/`zones`가 없어서
   지금 상태로는 grounded DSL을 낼 수 없다.

### 1.1 살아 있는 매크로 어휘 (레지스트리를 실행해 확인)

```
MACROS      : {0:'NOOP', 1:'Replace', 2:'RelocateBuild', 3:'SwapBattery'}
KIND_VALID  : fault→[NOOP,Replace]  battery→[NOOP,Replace,SwapBattery]  zone→[NOOP,RelocateBuild]
RETIRED     : {}   EXPERIMENTAL : {}
```

`policy.jl:valid_macros`가 battery에 `"Deprioritize"`를, zone에 `"ForbidZone"`을 실어 보내지만
`_valid_for`의 `[m for m in req.valid if m in MACROS]` 필터가 **조용히 버린다**
(`dspy_service.py:142`). 즉 두 이름은 이미 죽은 텍스트다.

---

## 2. 목표 구조

```
OOD 주입
  │  NL 관찰 + 서술자 6개 + valid 메뉴 + 엔티티 id 목록
  ▼
POST /decide  →  DSPy PickMacro (gpt-4o, MIPROv2 컴파일 arm)
                   reasoning    : 무슨 일이 났는가          ← 인식
                   constraints  : DSL 제약 (schema.py 검증)  ← 번역
                   macro        : valid 중 하나              ← 결정
  ▼
Julia: 일관성 게이트(constraints ↔ macro, 진단 전용)
       매크로 집행 (STEP 1 — 기존 사슬 그대로)
       constraints → emitted_key → 결정 행에 기록 → grounding 채점
```

출력 필드를 `reasoning → constraints → macro` 순서로 선언한다. DSPy adapter는 선언 순서대로
필드를 생성시키므로, 이 순서가 곧 "번역한 **다음에** 결정"이다.

### 2.1 삭제

| 대상 | 처분 |
|---|---|
| `src/respec/llm_service/server.py` | 삭제 |
| `src/respec/llm_service/propose.py` | 삭제 |
| `src/respec/llm_service/test_propose.py` | 삭제 |
| `tools/translate_eval.py` | 삭제 (§4.4가 대체) |
| `tools/verify_battery_translation.py` | 삭제 |
| `render_demo.jl` 의 `llm_producer` · `USE_LLM` · `DEMO_LLM` | 삭제, `policy_producer` 단일화 |
| `llm_bridge.jl` 의 Claude HTTP 클라이언트 (`_respec_service_url` / `respec_service_ready` / `llm_to_proposal`) | 삭제 |
| `replan.jl:maybe_respecify!` 의 기본 LLM 분기 (`producer === nothing`) | producer 필수로 변경 |

### 2.2 살려서 옮기는 것

- **`schema.py` (484줄)** — import가 `typing` + `pydantic` 뿐이라 Claude 의존이 0이다.
  dspy 서비스 쪽(hjcrl venv)으로 옮겨 **DSPy 출력의 검증기**가 된다.
  `spec_dsl.jl`과의 lockstep 계약은 그대로 유지된다 (양쪽 11 kind, 확인함).
- **`llm_bridge.jl`의 descriptor 공급기** — `open_agent_descriptors` / `open_node_descriptors` /
  `open_zone_descriptors` / `open_node_id_strings`. 정확한 `RobotID(3)` 문자열을 만드는
  유일한 코드이고 `/decide`가 DSL을 내려면 반드시 필요하다.
  → 파일을 `src/respec/grounding_descriptors.jl` 로 개명하고 HTTP 부분만 잘라낸다.

### 2.3 컴파일된 MIPROv2 arm

`constraints`는 컴파일 산출물(`dspy_real_program_gpt4o*.json`)의 demo에 없는 필드가 된다.
`ranking`/`margin`이 이미 정확히 그 상태로 돌고 있으므로(`dspy_service.py:287`) partial demo
계약은 유지되고, `chosen`은 계속 `macro` 필드에서 나온다.

**단, 출력 필드가 늘면 프롬프트가 바뀌므로 `chosen`이 달라질 수 있다.** 바이트 동일은
요구하지 않는다 — §6의 기준을 쓴다.

---

## 3. 와이어 계약

### 3.1 Signature

```python
class PickMacro(dspy.Signature):
    __doc__ = SEED_DOC                    # 기존 유지 + 번역 원리 1줄 추가

    state:         str = dspy.InputField(...)          # 기존
    valid_actions: str = dspy.InputField(...)          # 기존
    entities:      str = dspy.InputField(              # 신규
        desc="the EXACT id strings you may reference; never invent one")

    reasoning:   str   = dspy.OutputField(...)         # 기존 — 인식
    constraints: str   = dspy.OutputField(             # 신규 — 번역
        desc="JSON array of DSL constraints that express the repair; [] if none")
    macro:       str   = dspy.OutputField(...)         # 기존 — 결정
    ranking:     str   = dspy.OutputField(...)         # 기존
    margin:      float = dspy.OutputField(...)         # 기존
```

`constraints`의 타입은 pydantic 객체가 아니라 **`str`(JSON 문자열)** 이다. `ranking`/`margin`과
같은 취급이 되어 컴파일 demo 계약이 유지되고, 검증은 `schema.py`로 우리가 직접 한다.
dspy typed-output에 맡기면 파싱 실패가 예외로 올라와 **결정까지 같이 죽는다** — §3.3의
불변식을 깬다.

### 3.2 `entities` 입력

`MacroRequest`에 `agents` / `nodes` / `zones` 필드를 추가하고 `policy.jl:service_decide`가
§2.2의 descriptor 함수로 채운다. 렌더링은 기존 `_geometry_block`과 같은 원칙 —
**사실만, 지시는 절대 쓰지 않는다**:

```
ENTITIES YOU MAY NAME (use these id strings exactly):
  agents:  RobotID(3)   "Robot R3, transport, carrying"
           RobotID(11)  "Robot R11, spare, idle"
  zones:   fault_3      center=(4.10,-2.35) r=0.55  covers=[AssemblyID(2)]
```

### 3.3 검증·강등 규칙 (서비스 쪽)

기존 `coerced` 규율을 그대로 따른다 — 죽지 않고, 무슨 일이 있었는지 남긴다.

| 단계 | 실패 시 |
|---|---|
| 1. JSON 파싱 | `constraints=[]`, `constraints_error="parse"` |
| 2. `schema.py` `RespecProposal.model_validate` | `constraints=[]`, `constraints_error="schema"` |
| 3. id 접지 검사 (`entities` 목록 대조) | 그 제약 **하나만** 버리고 `constraints_dropped`에 기록 |

> **불변식: `constraints`가 어떻게 실패하든 `macro`는 그대로 산다.**
> STEP 1에서 집행은 매크로가 하므로, 번역 실패가 결정을 바꾸면 "같은 세계" 비교가 깨진다.

3번을 줄리아의 `verify()`에 맡기지 않는 이유: STEP 1의 측정 레인은 `verify()`를 아예 타지
않으므로 환각한 id를 셀 자리가 서비스밖에 없다.

### 3.4 일관성 게이트 (Julia 쪽, STEP 1에서는 진단 전용)

| macro | 기대 DSL kind | 기대 대상 |
|---|---|---|
| `NOOP` | (제약 없음) | — |
| `Replace` | `ReplaceAgent` | `truth.robot` |
| `SwapBattery` | `SwapBattery` | `truth.robot` |
| `RelocateBuild` | `RelocateBuild` | `truth.zone` |

판정 3값 `:agree` / `:mismatch` / `:absent` 를 결정 행에 기록한다.
**STEP 1에서는 거절하지 않는다** — 거절하는 순간 세계가 바뀐다. 이 필드가 §7 승격 게이트의 입력이다.

### 3.5 응답 스키마

```jsonc
POST /decide → {
  "valid": [...], "state": "...", "llm_input": "...", "llm_input_mode": "nl",
  "dspy": {
    "chosen": "SwapBattery", "ranking": [...], "margin": 0.4,
    "rationale": "...", "policy": "dspy:gpt-4o", "coerced": false, "error": null,
    "constraints":         [{"kind":"SwapBattery","agent":"RobotID(3)"}],  // 신규
    "constraints_raw":     "[{\"kind\":...}]",                            // 신규(감사용 원문)
    "constraints_error":   null,                                          // 신규
    "constraints_dropped": []                                             // 신규
  },
  "surrogate": { ... }   // 불변
}
```

기존 필드는 하나도 바꾸지 않고 **추가만** 한다. 그래서 이 응답을 읽는 `policy.jl` ·
`run_demo.jl` · UI 는 갱신 전에도 계속 돈다.

---

## 4. 채점 배선

### 4.1 결정 행에 싣는 것 — 키 매핑의 단일 진실원

`run_demo.jl`의 `this_decision` Dict에 추가:

```julia
"constraints"         => [...]      # 서비스가 검증해 돌려준 DSL
"constraints_error"   => nothing    # "parse" | "schema" | nothing
"constraints_dropped" => []         # id 접지 실패로 버린 것
"consistency"         => "agree"    # agree | mismatch | absent
"emitted_keys"        => [["battery","RobotID(3)"]]   # CB.emitted_key 로 Julia 가 계산
"truth_keys"          => [["battery","RobotID(3)"]]   # CB.truth_key   로 Julia 가 계산
```

**키 매핑은 Julia에서만 계산한다.** PRF 자체는 집합 연산이라 파이썬이 해도 되지만,
`emitted_key`/`truth_key`의 *정의*를 파이썬에 한 벌 더 두면 `schema.py ↔ spec_dsl.jl`
lockstep에서 이미 겪는 이중 정의 문제가 하나 더 생긴다. Julia가 키까지 만들어 행에 싣고,
파이썬은 교집합·차집합만 한다.

### 4.2 리포트 확장 (`llm_ood_eval.py:summarize`)

```
per-kind decision rate:  FaultTruth 0.83 (10/12)  BatteryTruth 0.91 (10/11)
per-kind grounding    :  FaultTruth P=0.92 R=0.83 F1=0.87  (halluc 1, missed 2)
                         BatteryTruth P=1.00 R=0.91 F1=0.95 (halluc 0, missed 1)
                         ZoneTruth  unscored (§5.2)
translation health    :  agree 20/23 · mismatch 1 · absent 2 · parse_err 0 · schema_err 0
```

### 4.3 zone은 0이 아니라 `unscored`로 인쇄한다

§5.2 적용 후 `emitted_key`에 zone을 지목하는 분기가 하나도 없으므로 zone recall은 구조적으로 항상 0이다.
0으로 인쇄하면 "LLM이 zone 번역을 못한다"로 오독된다. `reference_policy`가 근거 없는
구간에 쓰는 관례를 그대로 따라 `unscored`로 인쇄한다.

### 4.4 오프라인 번역 eval — `tools/dspy_translate_eval.py`

시뮬·uvicorn·Julia 없이 dspy 프로그램을 in-process로 부르는 빠른 안쪽 루프.
기존 `tools/llm_fixture.json`(엔티티 id·라벨)을 `entities` 입력으로 재사용한다.

케이스는 **실제 주입기가 내보내는 문장**을 쓴다(손으로 지은 패러프레이즈가 아니라,
`fault_robot!`의 실제 출력에 `nl_mode="observation"`을 적용한 형태):

| 케이스 | 기대 macro | 기대 DSL |
|---|---|---|
| `fault_pending` | `Replace` | `ReplaceAgent(RobotID(k))` |
| `fault_idle` | `NOOP` | `[]` |
| `battery_deep` | `SwapBattery` | `SwapBattery(RobotID(k))` |

채점 축 셋: **macro 정답 · DSL kind+target 정답 · 둘의 일관성**.

> ⚠️ `tools/dump_llm_fixture.jl`이 두 워크트리 모두에 **없다** — `translate_eval.py`가
> docstring에서 재생성 방법이라고 안내하는 그 파일이다. `llm_fixture.json`만 남아 있어
> 실행은 되지만 씬이 바뀌면 갱신할 방법이 없다. 이 작업에서 작게 새로 쓴다
> (엔티티 목록만 필요하므로 원래보다 짧다).

---

## 5. 어휘·채점 규칙 변경 (결정 사항)

### 5.1 `Deprioritize` 전면 제거

soft battery 저하도 OOD 사건이므로 "우선순위만 낮추는" 대응을 두지 않는다.
battery는 severity와 무관하게 실제 개입(`SwapBattery`)으로 간다.

#### 제거 범위 (전수 grep으로 측정, 2026-08-24)

`DeprioritizeAgent`는 죽은 텍스트가 아니라 **compile / verify / dispatch까지 배선된 살아 있는
DSL kind**다. 26개 파일에 걸쳐 있고, 그중 주석만 있는 파일이 8개다.

**코드 수정이 필요한 파일** (괄호 = 주석 아닌 hit 수):

| 파일 | 성격 |
|---|---|
| `src/respec/replan.jl` (16) | dispatch 분기 — 가장 큰 덩어리 |
| `src/respec/verifier.jl` (4) | verify 경로 |
| `src/respec/spec_dsl.jl` (3) | 타입 정의 |
| `src/respec/compiler.jl` (1) | MILP 컴파일 |
| `src/essential_tg_coponents.jl` (1) | 우선순위 강등 실행부 |
| `src/navigator/ood_truth.jl` (3) | `emitted_key` 분기 |
| `src/navigator/baselines.jl` (2) | 기준정책 |
| `src/respec/llm_service/schema.py` (4) | pydantic 문법 (spec_dsl.jl과 lockstep — **동시에**) |
| `tools/monitor/policy.jl` (2) | `valid_macros` · `macro_to_proposal` |
| `tools/monitor/smoke_ood_run.jl` (1) | |
| `tools/tests.jl` (12) · `tools/demos.jl` (6) | |
| `test/respec_action_space.jl` (7) · `test/respec_sequential_enact.jl` (3) · `test/navigator_comparison_smoke.jl` (2) | 테스트 갱신 |

**주석만 있어 수정 불필요**: `objective.jl` · `objective.py` · `run_demo.jl` · `render_demo.jl` ·
`e2e.jl` · `test/objective_hooks_smoke.jl` · `llm_bridge.jl`.
`gen_oracle_dataset.jl`의 `"Deprioritize"` 4곳도 전부 주석이다 — 4팔 재번호 때 이미 빠졌다.

**삭제 예정 파일이라 자동 해결**: `propose.py` · `translate_eval.py` ·
`verify_battery_translation.py` (§2.1).

#### 제외: `wm4spacecraft_manufacturing/core/features_agnostic.py` (3 hits)

**건드리지 않는다.** 이 모듈은 행동을 id가 아니라 **효과 서술자 공간의 점**으로 적는
ψ-표현 실험이고(Chandak et al. AAAI'20), `_PRIMITIVE_TABLE`/`MACRO_SPECS`는 **옛 9팔 id 공간**
위에 있다(id 2=DeprioritizeAgent인데 현 레지스트리 2=RelocateBuild). 소비처는 이 모듈과 그
테스트뿐이다(확인함 — 외부 참조 0).

이 모듈의 존재 이유 자체가 "행동 하나가 사라져도 나머지의 ψ는 한 자리도 안 바뀐다"이고,
`psi_regression_check()`가 그 계약을 강제한다. 항목을 지우면 그 검사가 깨지고 기존 실험
숫자와의 비교가 무효가 된다. ψ 표는 **메뉴가 아니라 서술자 공간**이므로, 라이브 문법에서
kind를 지우면서 표를 그대로 두는 것이 일관된 처리다.

#### 5.1.1 필수 동반 수정 — `SwapBattery` 채점 구멍

`emitted_key`에는 `SwapBattery` 분기가 **없다**(정의는 `ood_truth.jl:152` 하나뿐임을 확인).
Deprioritize를 지우면 battery가 낼 수 있는 유일한 팔이 키를 못 만들어 **battery grounding이
항상 0**이 된다. 이 작업의 원래 목적(battery·fault 추론 품질 측정)이 원리적으로 불가능해진다.

방향은 이미 레포가 잡아 뒀다 — `canonical_respec(BatteryTruth)`는 이미 deep/mild를 합쳐
`SwapBattery(t.robot)` 하나만 낸다(`baselines.jl:96`). `emitted_key`/`truth_key`만 그 통합을
못 따라간 상태다. 따라서:

```julia
# emitted_key: 추가
elseif tn === :SwapBattery
    return (:battery, c.agent)      # SwapBattery.agent (spec_dsl.jl:218 확인)

# truth_key: severity 분기 제거
truth_key(t::BatteryTruth) = (:battery, t.robot)
```

### 5.2 zone grounding — 정의하지 않는다

`emitted_key`에 `RelocateBuild → (:zone, ·)` 분기를 **추가하지 않는다**. 아울러 이미 죽은
`ForbidZone → (:zone, ·)` 분기를 제거한다(ForbidZone은 레지스트리에서 은퇴 상태).
결과적으로 zone 사건의 grounding은 "채점 대상 엔티티 없음"으로 남고 §4.3대로 `unscored`로
인쇄된다. zone 대응에 대한 사전 지식을 채점 규칙에 심지 않는다는 기존 결정과 일치한다.

### 5.3 SoC 임계값 0.2로 통일

```
Julia  ood_truth.jl:129        REPLACE_SOC_THRESHOLD = Ref(0.2)
Python reference_policy.py:69  BATTERY_DEEP_SOC      = 0.5     ← 0.2 로 변경
```

`set_replace_soc_threshold!`를 부르는 코드는 레포에 없다(확인함). §5.1.1로 `truth_key`가
임계값을 안 쓰게 되므로, 남는 소비처는 `reference_policy`의 "SwapBattery 정답 vs unscored"
분기 하나다.

> **공개된 대가**: 0.5 → 0.2 로 내리면 `n44_plus78_d20` 사다리에서 SwapBattery가 이긴
> 세 rung 중 **0.30 · 0.50의 실측 근거가 채점에서 버려진다**(그 구간이 unscored가 된다).
> 지금 데이터로는 아무 채점도 바뀌지 않는다 — BatteryTruth 56건의 SoC 최댓값이 0.09999라
> 전부 0.2 아래다. mild battery를 굴리는 실행에서만 차이가 난다.

---

## 6. 작업 순서

| # | 작업 | 검증 |
|---|---|---|
| T1 | `schema.py` → dspy 서비스 쪽 이사 | hjcrl venv import + 기존 DSL 검증 테스트 통과 |
| T2 | `MacroRequest` + `agents`/`nodes`/`zones`, `_entities_block()` | 순수 렌더링 단위 테스트 (모델 호출 0) |
| T3 | `PickMacro`에 `entities` 입력 + `constraints` 출력 | 컴파일 arm 로딩 회귀 테스트 — partial demo 로드, `chosen`이 `macro`에서 나오는지 |
| T4 | 서비스 검증·강등 3단계 (§3.3) | 목 응답: 깨진 JSON→`parse`, 잘못된 kind→`schema`, 지어낸 id→`dropped`, **셋 다 `chosen` 생존** |
| T5 | `policy.jl`: descriptor 전송 + 일관성 게이트 + `emitted_keys` | `emitted_key` 재사용 확인, 게이트가 거절하지 않는지 |
| T6 | `run_demo.jl`: 결정 행 필드 6개 | 요약 jsonl 스키마 테스트 |
| T7 | `llm_ood_eval.py`: grounding 블록 + zone `unscored` | 기존 행으로 리포트가 안 깨지는지(하위호환) |
| T8 | §5.1 `Deprioritize` 전면 제거(파일 목록 확정됨) + §5.1.1 `SwapBattery` 키 추가 | §5.1 표의 파일 전부, `features_agnostic.py` 제외 확인, 채점기 교차 테스트 |
| T9 | §5.2 `emitted_key` 정리 (`ForbidZone` 분기 제거) | zone이 `unscored`로 인쇄되는지 |
| T10 | §5.3 임계값 0.2 통일 | 두 채점기가 같은 severity class를 내는지 교차 테스트 |
| T11 | Claude 경로 삭제 + `llm_bridge.jl` → `grounding_descriptors.jl` 분할 | 전체 테스트 스위트 |
| T12 | `dspy_translate_eval.py` + `dump_llm_fixture.jl` | 3케이스 통과 |

`schema.py`를 **먼저** 옮기는 이유: 그게 안 되면 나머지가 무의미하다. 검증기 없는
`constraints` 필드는 자유 텍스트일 뿐이다.

---

## 7. 검증 기준

### 7.1 "같은 세계" 비교 — 무엇을 요구하고 무엇은 요구하지 않는가

T3에서 프롬프트가 바뀌므로 **`chosen` 시퀀스의 바이트 동일은 요구하지 않는다**
(`temperature=0.0`, `cache=True`지만 프롬프트가 캐시 키다).

같은 seed 집합(≥15판)으로 T3 전/후를 돌려서:

1. `decision_rate`의 Wilson CI가 겹칠 것. 안 겹치고 나빠졌으면 **거기서 멈춘다.**
2. `per_kind`(FaultTruth · BatteryTruth) 각각도 같은 기준.
3. `chosen` 시퀀스 diff를 사람이 읽을 수 있게 파일로 남길 것 — 몇 개가 어느 방향으로 바뀌었는지.

### 7.2 물리 설정 도장 대조 (과거 사고 재발 방지)

전/후 비교 런은 실행 레인과 **같은 물리 설정**이어야 한다. `DS_HOTSWAP` 하나 어긋나면
에러 없이 fault 발화율이 100% → 23%로 새고, 그러면 "결정이 나빠졌다"가 아니라
"사건이 안 터졌다"를 보게 된다.

- 전/후 런의 설정 도장(`hot_swap`, `DS_SHRINK` 등)을 대조할 것.
- kind별 발화율(`fired == True` 비율)을 **매번** 집계할 것. 총 행 수만 보면 "좀 적네"로 지나간다.

### 7.3 채점기 교차 테스트 (T8/T10 이후 필수)

같은 `BatteryTruth`에 대해 Julia `truth_key`와 Python `reference_policy.reference_action`이
모순되지 않는지 — SoC 격자(0.02 / 0.15 / 0.25 / 0.45 / 0.6)에서 표로 대조한다.

---

## 8. STEP 2 (집행 전환) 승격 게이트

임계값은 STEP 1을 측정한 **뒤에** 정한다. 지금 숫자를 지어내지 않는다.
게이트가 읽을 필드는 §3.4 · §4.1에서 이미 정해졌다:

- `consistency == "agree"` 비율 (fault + battery)
- `constraints_error` 비율
- kind별 grounding F1
- `constraints_dropped`(환각한 id) 건수

이 넷이 나오면 "번역이 집행을 몰아도 되는가"에 근거로 답할 수 있다.
STEP 2 자체는 별도 spec이다 — `run_demo.jl` 집행 사슬 은퇴 + `verify()` 거절 시 폴백
설계가 들어가므로 이 문서에 섞지 않는다.

---

## 9. 공개된 위험

1. **`chosen`이 바뀔 수 있다** (§2.3). arm은 같지만 프롬프트가 바뀐다. §7.1이 판정 기준이다.
2. **0.30 · 0.50 rung의 실측 근거가 채점에서 버려진다** (§5.3). 지금 데이터로는 무영향.
3. **`Deprioritize` 제거는 이 작업에서 가장 큰 덩어리다.** 죽은 텍스트가 아니라
   compile / verify / dispatch까지 배선된 살아 있는 DSL kind이고, 코드 수정이 필요한 파일이
   13개(테스트 3개 포함), 그중 `replan.jl` 한 곳에만 16개 site가 있다(§5.1). 되돌리려면
   `spec_dsl.jl` · `schema.py` lockstep과 테스트가 함께 움직여야 한다.
   T8은 단일 커밋으로 묶고, 그 앞뒤로 전체 테스트 스위트를 돌린다.
4. **`laneC7` 워크트리와 갈라진다.** `sdd-lane-c7`의 `ood_truth.jl`은 이미 `ForbidZone`
   분기를 지운 상태이고 `src/smdp/`에 이 워크트리에 없는 파일들이 있다. 병합 시 충돌 지점이다.
