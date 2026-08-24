# 통합 LLM 재명세(re-specification) 설계

- 날짜: 2026-08-24
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`)
- 상태: 설계 승인됨. 구현 계획은 별도 문서.

---

## 0. 한 줄 요약

OOD 사건을 **하나의 LLM**(DSPy/gpt-4o)이 인식 → 번역 → 결정까지 한 번의 호출로 처리하게 만든다.
Claude `/propose` 경로는 제거한다.

세 가지를 함께 바꾼다:

1. **어휘를 3팔로** — `NOOP` · `Replace` · `SwapBattery`. zone 사건은 LLM 결정 레인에서 빼고
   (surrogate 학습 증거용으로만 남긴다) `RelocateBuild`는 레지스트리에서 삭제,
   `DeprioritizeAgent` 잔재도 제거. id는 0..2로 재번호한다.
2. **메뉴를 연다** — 사건 종류별 후보 필터를 없애고 LLM에게 언제나 레지스트리 전체를 준다.
   어떤 팔이 이 상황에 말이 안 되는지 판단하는 것 자체가 측정 대상이다(§1.2).
3. **번역을 추가한다** — 출력 필드를 `reasoning → constraints → macro` 순으로 선언한다.

1단계에서 번역(DSL)은 **채점·검사용 부산물**이고 집행은 지금처럼 매크로가 한다.
번역이 믿을 만하다고 측정된 뒤에 2단계에서 집행을 넘긴다.

세 변경은 **한꺼번에 착지시키지 않는다** — 축 C → B → A 순서로 각각 측정한다(§6).

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
vocab stamp : "v3-4arms"
```

이것은 **바꾸기 전 상태의 기록**이다(§5가 목표 상태를 정한다).

`action_registry.json`의 `_doc`이 2026-08-20에 `Deprioritize`를 지운 이유를 남겨 뒀다 —
"어떤 사건에도 고유하게 안 붙었고 **제안 338회 대비 선택 0회**. 이 하니스의 배터리 사건은
'저하'가 아니라 '정지'(SoC 0)라 멈춘 로봇의 우선순위를 낮춰봐야 아무것도 안 풀린다.
degraded-but-alive 상태가 없다." 즉 레지스트리 차원의 제거는 이미 끝났고, 남은 것은
`DeprioritizeAgent` **DSL kind 잔재**다(§5.4).

`policy.jl:valid_macros`가 battery에 `"Deprioritize"`를, zone에 `"ForbidZone"`을 실어 보내지만
`_valid_for`의 `[m for m in req.valid if m in MACROS]` 필터가 **조용히 버린다**
(`dspy_service.py:142`). 즉 두 이름은 이미 죽은 텍스트다.

### 1.2 설계 원칙 — 후보 배제는 reasoning의 일부다

현재 `policy.jl:valid_macros`와 `dspy_service._valid_for`가 **사건 종류를 먼저 분류한 뒤**
그 종류에 legal한 팔만 골라 LLM에게 준다. 그러면 "무엇이 고장났는가"를 규칙이 이미 판단해
버린 뒤이고, LLM에게 남는 일은 좁혀진 메뉴에서 하나 집는 것뿐이다. **그 상태에서 측정되는
것은 추론이 아니라 선택이다.**

행동 후보는 어차피 적다(3개). 따라서:

> **LLM에게는 사건 종류와 무관하게 언제나 action registry 전체를 후보로 준다.**
> 어떤 팔이 이 상황에 말이 되지 않는지를 판단하는 것 자체가 LLM이 해야 할 추론이다.

이 원칙이 §5.3(kind 필터 폐지)의 근거이고, `nl_mode="observation"`(관찰문에서 지시절을
떼어내는 기존 장치)과 같은 방향이다 — 답을 미리 알려주지 않는다.

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
요구하지 않는다 — §7.1의 기준을 쓴다.

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

### 4.3 채점 대상은 fault · battery 둘뿐이다

§5.1로 zone 사건이 LLM 결정 레인에서 빠지므로, 남은 사건 종류는 `FaultTruth` · `BatteryTruth`
둘이고 **둘 다 grounding이 완전히 정의된다**:

| truth | truth_key | 정답 팔 | emitted_key |
|---|---|---|---|
| `FaultTruth` | `(:fault, robot)` | `Replace` | `ReplaceAgent → (:fault, agent)` ✅ 기존 |
| `BatteryTruth` | `(:battery, robot)` (§5.5) | `SwapBattery` | `SwapBattery → (:battery, agent)` ✅ §5.5 신규 |

`unscored`로 인쇄할 구간이 남지 않는다 — 다만 §5.6의 SoC 임계값 위(soc > 0.2)는
`reference_policy`가 여전히 `unscored`로 둔다(측정된 근거가 없는 구간).

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

### 5.1 zone 사건을 LLM 결정 레인에서 제거

zone은 앞으로 **OOD 시뮬레이션에서 surrogate가 잘 학습됐다는 증거로만** 쓴다. LLM 재명세
경로에서는 다루지 않는다. 따라서 결정 epoch를 만드는 사건 종류는 **fault · battery 둘**이다.

영향 지점: `ZoneTruth` 주입 스케줄, `llm_ood_eval.py --case zone`,
`reference_policy.reference_action`의 `ZoneTruth` 분기, `policy.jl:valid_macros`의 zone 분기,
`macro_to_proposal`의 zone 분기, `oracle_macro`의 zone 경로.

> **주의**: `ood_mdp_shim.jl` · `src/smdp/generative.jl` · `test/smdp_stamp_smoke.jl`은
> `ActionRegistry.kind_valid`를 계속 쓴다(오라클/SMDP 레인). zone을 그쪽에서까지 지우는 것은
> 이 spec의 범위가 **아니다** — LLM 결정 레인에서만 뺀다.

### 5.2 어휘를 3팔로 — 엔트리를 지우고 재번호한다

목표: `{0: NOOP, 1: Replace, 2: SwapBattery}`. `RelocateBuild`는 zone 전용 팔이므로 함께
빠진다. **은퇴 표식을 남기지 않고 `action_registry.json`에서 엔트리를 지우고 id를 0..2로
재번호한다.**

근거:

- zone 제거로 세계가 바뀌므로 라벨·오라클·surrogate는 **어차피 전부 재생성한다.**
  id를 고정해 구세대 산출물의 가독성을 지키는 것은 재생성하는 순간 값이 0이다.
- 은퇴 엔트리는 코드를 읽는 사람이 매번 "이건 살아 있나?"를 우회해야 하는 상시 비용이다.
- 2026-08-20의 9팔 → 4팔 축소가 정확히 같은 판단(폐기 + 삭제 + 재번호)이었다.

#### 필수 동반 조건 — 도장을 **실제로 검사하게** 만든다

재번호의 위험은 재해석 자체가 아니라 그것이 **조용하다는 것**이다. 재번호하면 디스크에
남은 `v3-4arms` 파일의 `macro=2`(RelocateBuild) 행이 새 어휘에서 `SwapBattery`로 에러 없이
읽힌다.

측정 결과(2026-08-24): `require_vocab`을 실제로 부르는 소비처는 **`gate_ng2.py:112` 하나뿐**이고,
`macro` 열을 읽는 나머지 7곳은 도장을 보지 않는다 —

```
e1_analyze.py:463 · surrogate_v2.py:144,237 · eval_surrogate_v2.py:162
export_surrogate.py:298 · dspy_service.py:260,463,464
```

레지스트리 `_doc`의 "지금 도장은 write-only 다"는 사실이었다. 따라서:

> **재번호와 `require_vocab` 배선을 같은 커밋에 넣는다.** 도장이 안 걸린 채로 재번호하는
> 것만 금지한다 — 그 조합이 조용한 오독을 만든다.

우선순위가 가장 높은 곳은 **디스크에서 파일을 자동 발견하는 로더**다:
`dspy_service.py:80`(`dspy_real_program_*.json` glob으로 최신 선택) 및 그 학습 행 로더
(`:251-260`). 사람이 경로를 명시하는 로더보다 사고 확률이 높다.

#### 동반 수정

- `vocab` 도장 `"v3-4arms"` → `"v4-3arms"`.
  `assert_vocab_arm_count(VOCAB, n_non_retired(REGISTRY))`가 도장의 팔 개수와 실제 개수를
  대조하므로 **반드시 같이 올려야 한다**(파이썬 `core/action_registry.py` ·
  줄리아 `oracle/action_registry.jl` 양쪽 로더).
- `wm4spacecraft_manufacturing/smdp/test_stamps.py:22`의 하드코딩
  `assert action_registry.VOCAB == "v3-4arms"` 갱신.
- `test/smdp_stamp_smoke.jl:118-121`의 `kind_valid` 기대값 갱신
  (`:zone`은 빈 목록이 된다).
- `cost` 값은 이름-비용 쌍 불변 규칙대로 옮긴다: `NOOP=0.0` · `Replace=1.0` · `SwapBattery=0.2`.
  `gen_oracle_dataset.jl MACRO_COST` · `e1_analyze.MACRO_COST` · `features_agnostic.MACRO_COST`와
  같은 값이어야 한다.

#### 재생성 대상 (축 C 이후)

`v3-4arms` 세대 산출물은 새 어휘에서 무효다. 재생성하고, 구세대 파일은 **지우거나 옮긴다**
— 남겨 두면 위의 무검사 로더가 집는다.

- 오라클 라벨셋 (`gen_oracle_dataset.jl`)
- 배포 surrogate (`export_surrogate.py` → `surrogate_v2`)
- DSPy 컴파일 프로그램의 학습 라벨 (`dspy_real_program_gpt4o*.json`의 근거 데이터)

재생성 런은 §7.2대로 실행 레인과 같은 물리 설정이어야 한다(`DS_HOTSWAP` 등).

### 5.3 kind 필터 폐지 — LLM에게는 레지스트리 전체를 준다

§1.2의 원칙을 배선하는 곳은 두 군데다.

**(a) `tools/monitor/policy.jl:valid_macros`** — 사건 종류별 분기를 전부 없애고 활성
레지스트리 전체 이름을 돌려준다. `zone_diagnosis`를 부르던 `named`/`domain` 계산 블록도
함께 사라진다(그 분기 하나만을 위해 존재했다).

**(b) `src/respec/llm_service/dspy_service.py:_valid_for`** — kind 폴백을 없앤다.

```python
def _valid_for(req) -> List[str]:
    caller = [m for m in (getattr(req, "valid", None) or []) if m in MACROS]
    return caller if caller else MACROS          # 기존: VALID.get(req.kind, MACROS)
```

`VALID`(= `KIND_VALID`에서 유도) 테이블은 LLM 경로에서 더 이상 쓰이지 않는다.
레지스트리의 `kinds` 필드 자체는 **남긴다** — 오라클/SMDP 레인(`ood_mdp_shim.jl`,
`generative.jl`)이 계속 쓴다.

`coerced` 규칙(어휘 밖 응답 → NOOP 강제)은 **유지한다.** 이제 그 규칙이 거르는 것은
"이 사건에 안 맞는 팔"이 아니라 "레지스트리에 없는 이름"뿐이다 — 그것이 옳은 방어선이다.

**채점상의 귀결**: fault 사건에서 `SwapBattery`가 메뉴에 오른다. `reference_policy`의
FaultTruth 정답은 `pending>0 → Replace`, `==0 → NOOP`이므로 LLM이 SwapBattery를 고르면
**오답으로 집계된다.** 이것은 결함이 아니라 의도다 — "이 팔은 이 상황에 말이 안 된다"를
판단하는 것이 측정 대상이다.

### 5.4 `DeprioritizeAgent` DSL kind 잔재 제거

레지스트리에서는 이미 빠졌다(§1.1). 남은 것은 DSL 문법·dispatch·테스트의 잔재다.

#### 제거 범위 (전수 grep으로 측정, 2026-08-24)

`DeprioritizeAgent`는 **compile / verify / dispatch까지 배선된 살아 있는 DSL kind**다.
26개 파일에 걸쳐 있고 그중 주석만 있는 파일이 8개다.

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
`e2e.jl` · `test/objective_hooks_smoke.jl` · `llm_bridge.jl` · `gen_oracle_dataset.jl`.

**삭제 예정 파일이라 자동 해결**: `propose.py` · `translate_eval.py` ·
`verify_battery_translation.py` (§2.1).

#### 제외: `wm4spacecraft_manufacturing/core/features_agnostic.py` (3 hits)

**건드리지 않는다.** 행동을 id가 아니라 **효과 서술자 공간의 점**으로 적는 ψ-표현 실험이고
(Chandak et al. AAAI'20), `_PRIMITIVE_TABLE`/`MACRO_SPECS`는 **옛 9팔 id 공간** 위에 있다
(id 2=DeprioritizeAgent인데 현 레지스트리 2=RelocateBuild). 소비처는 이 모듈과 그 테스트뿐이다
(확인함 — 외부 참조 0).

이 모듈의 존재 이유가 "행동 하나가 사라져도 나머지의 ψ는 한 자리도 안 바뀐다"이고
`psi_regression_check()`가 그 계약을 강제한다. 항목을 지우면 그 검사가 깨지고 기존 실험
비교가 무효가 된다. ψ 표는 **메뉴가 아니라 서술자 공간**이므로 라이브 문법에서 kind를
지우면서 표를 그대로 두는 것이 일관된 처리다.

### 5.5 필수 동반 수정 — `SwapBattery` 채점 구멍

`emitted_key`에는 `SwapBattery` 분기가 **없다**(정의는 `ood_truth.jl:152` 하나뿐임을 확인).
`Deprioritize`를 지우면 battery가 낼 수 있는 유일한 팔이 키를 못 만들어 **battery grounding이
항상 0**이 된다. 이 작업의 원래 목적(battery · fault 추론 품질 측정)이 원리적으로 불가능해진다.

방향은 이미 레포가 잡아 뒀다 — `canonical_respec(BatteryTruth)`는 이미 deep/mild를 합쳐
`SwapBattery(t.robot)` 하나만 낸다(`baselines.jl:96`). `emitted_key`/`truth_key`만 그 통합을
못 따라간 상태다.

```julia
# emitted_key: 추가
elseif tn === :SwapBattery
    return (:battery, c.agent)      # SwapBattery.agent (spec_dsl.jl:218 확인)

# emitted_key: 제거 — ForbidZone 분기(레지스트리 은퇴), DeprioritizeAgent 분기(§5.4)

# truth_key: severity 분기 제거
truth_key(t::BatteryTruth) = (:battery, t.robot)
```

### 5.6 SoC 임계값 0.2로 통일

```
Julia  ood_truth.jl:129        REPLACE_SOC_THRESHOLD = Ref(0.2)
Python reference_policy.py:69  BATTERY_DEEP_SOC      = 0.5     ← 0.2 로 변경
```

`set_replace_soc_threshold!`를 부르는 코드는 레포에 없다(확인함). §5.5로 `truth_key`가
임계값을 안 쓰게 되므로, 남는 소비처는 `reference_policy`의 "SwapBattery 정답 vs unscored"
분기 하나다.

> **공개된 대가**: 0.5 → 0.2로 내리면 `n44_plus78_d20` 사다리에서 SwapBattery가 이긴 세 rung
> 중 **0.30 · 0.50의 실측 근거가 채점에서 버려진다**(그 구간이 unscored가 된다).
> 지금 데이터로는 아무 채점도 바뀌지 않는다 — BatteryTruth 56건의 SoC 최댓값이 0.09999라
> 전부 0.2 아래다. mild battery를 굴리는 실행에서만 차이가 난다.

## 6. 작업 순서 — 세 축을 섞지 않는다

이 spec은 서로 다른 **세 개의 변경 축**을 담고 있다. 한꺼번에 착지시키면 결과가 나빠졌을 때
원인을 가를 수 없다.

| 축 | 내용 | `chosen`에 대한 영향 |
|---|---|---|
| **C** | 어휘 축소 (zone·RelocateBuild 제거, Deprioritize 잔재 제거) — §5.1·5.2·5.4·5.5·5.6 | 확실히 바뀐다 |
| **B** | 메뉴 개방 (kind 필터 폐지) — §5.3 | 확실히 바뀐다 |
| **A** | 번역 추가 (`constraints` 출력 필드 + `entities` 입력) — §2·§3·§4 | 바뀔 수 있다 |

**순서: C → B → A.** 각 축이 끝날 때마다 같은 seed 집합으로 측정하고 기록한다.
축 B는 그 자체로 이 연구의 결과다 — "규칙이 좁혀 준 메뉴"와 "레지스트리 전체 메뉴"에서
LLM의 정답률이 어떻게 다른가는 §1.2 원칙의 실증이다.

### 축 C — 어휘 축소

| # | 작업 | 검증 |
|---|---|---|
| C1 | `action_registry.json`: `RelocateBuild` 엔트리 삭제 + id 재번호 0..2 + `vocab` → `"v4-3arms"` + **`require_vocab` 배선**(§5.2) | `assert_vocab_arm_count` 통과, `MACROS == [0,1,2]`, 구세대 도장 파일이 **큰 소리로 죽는지** |
| C2 | 도장 하드코딩 갱신: `test_stamps.py:22`, `test/smdp_stamp_smoke.jl:118-121` | 두 테스트 통과 |
| C3 | zone을 LLM 결정 레인에서 제거 (§5.1) | `--case zone`이 명확히 거부되는지 (조용히 통과 금지) |
| C4 | `Deprioritize` 잔재 제거 (§5.4) — **단일 커밋**, `features_agnostic.py` 제외 | §5.4 표의 파일 전부 + 전체 테스트 스위트 |
| C5 | `emitted_key`/`truth_key` 정리 (§5.5) | fault·battery 둘 다 grounding이 정의되는지 |
| C6 | SoC 임계값 0.2 통일 (§5.6) | 채점기 교차 테스트 (§7.3) |
| C7 | 산출물 재생성 (오라클 라벨 · surrogate · DSPy 학습 라벨) + 구세대 파일 제거 | 새 파일 전부 `v4-3arms` 도장, kind별 발화율 집계(§7.2) |
| C8 | **측정** — 축 C 후 baseline | seed ≥15, `decision_rate` + `per_kind` 기록 |

### 축 B — 메뉴 개방

| # | 작업 | 검증 |
|---|---|---|
| B1 | `policy.jl:valid_macros` → 활성 레지스트리 전체 (§5.3a) | zone 분기·`zone_diagnosis` 블록이 함께 사라졌는지 |
| B2 | `dspy_service._valid_for` kind 폴백 제거 (§5.3b) | `valid`를 안 보내도 3팔 전체가 나오는지 |
| B3 | **측정** — 축 B 후 | C8과 같은 seed 집합. fault에서 SwapBattery 오선택 빈도를 별도 집계 |

### 축 A — 번역 추가

| # | 작업 | 검증 |
|---|---|---|
| A1 | `schema.py` → dspy 서비스 쪽 이사 | hjcrl venv import + 기존 DSL 검증 테스트 통과 |
| A2 | `MacroRequest` + `agents`/`nodes`/`zones`, `_entities_block()` | 순수 렌더링 단위 테스트 (모델 호출 0) |
| A3 | `PickMacro`에 `entities` 입력 + `constraints` 출력 | 컴파일 arm 로딩 회귀 — partial demo 로드, `chosen`이 `macro`에서 나오는지 |
| A4 | 서비스 검증·강등 3단계 (§3.3) | 목 응답: 깨진 JSON→`parse`, 잘못된 kind→`schema`, 지어낸 id→`dropped`, **셋 다 `chosen` 생존** |
| A5 | `policy.jl`: descriptor 전송 + 일관성 게이트 + `emitted_keys` | 게이트가 거절하지 않는지 |
| A6 | `run_demo.jl`: 결정 행 필드 6개 | 요약 jsonl 스키마 테스트 |
| A7 | `llm_ood_eval.py`: grounding 블록 | 기존 행으로 리포트가 안 깨지는지(하위호환) |
| A8 | Claude 경로 삭제 + `llm_bridge.jl` → `grounding_descriptors.jl` 분할 (§2.1·2.2) | 전체 테스트 스위트 |
| A9 | `dspy_translate_eval.py` + `dump_llm_fixture.jl` (§4.4) | 3케이스 통과 |
| A10 | **측정** — 축 A 후 | B3과 같은 seed 집합 + grounding PRF |

`schema.py`(A1)를 먼저 옮기는 이유: 그게 안 되면 나머지가 무의미하다. 검증기 없는
`constraints` 필드는 자유 텍스트일 뿐이다.

---

## 7. 검증 기준

### 7.1 "같은 세계" 불변식은 **폐기한다**

초안은 STEP 1이 기존 `dspy` 수치와 직접 비교 가능해야 한다고 요구했다. 축 B·C가 들어오면서
그 전제는 성립하지 않는다 — 어휘가 3팔로 줄고 메뉴가 개방되므로 **세계가 확실히 바뀐다.**

대신:

- 축 C 종료 시점(C8)을 **새 baseline**으로 삼는다. 이후 비교는 전부 C7 기준이다.
- 기존 `v3-4arms` 세대 수치는 "이전 세대"로 라벨링해 보관하되 새 수치와 같은 표에 섞지 않는다.
- 각 축의 측정(C8 · B3 · A10)은 **같은 seed 집합 · 같은 world seed**로 돌린다.
  축 간 차이가 정책 변화가 아니라 판 차이가 되면 안 된다.

축 A에서만은 여전히 "출력 필드 추가가 결정을 얼마나 흔드는가"를 따로 본다:
`decision_rate`의 Wilson CI가 B3과 겹치는지, `chosen` 시퀀스 diff를 파일로 남길 것.

### 7.2 물리 설정 도장 대조 (과거 사고 재발 방지)

축 간 비교 런은 실행 레인과 **같은 물리 설정**이어야 한다. `DS_HOTSWAP` 하나 어긋나면
에러 없이 fault 발화율이 100% → 23%로 새고, 그러면 "결정이 나빠졌다"가 아니라
"사건이 안 터졌다"를 보게 된다.

- 전/후 런의 설정 도장(`hot_swap`, `DS_SHRINK` 등)을 대조할 것.
- kind별 발화율(`fired == True` 비율)을 **매번** 집계할 것. 총 행 수만 보면 "좀 적네"로 지나간다.
- 어휘 도장(`vocab`)도 같이 본다 — C1 이후 산출물은 전부 `v4-3arms`여야 한다.

### 7.3 채점기 교차 테스트 (C5/C6 이후 필수)

같은 `BatteryTruth`에 대해 Julia `truth_key`와 Python `reference_policy.reference_action`이
모순되지 않는지 — SoC 격자(0.02 / 0.15 / 0.25 / 0.45 / 0.6)에서 표로 대조한다.

### 7.4 메뉴 개방의 부작용 계측 (B3 필수)

fault 사건에서 `SwapBattery`를, battery 사건에서 `Replace`를 고른 빈도를 **따로 집계한다.**
전체 `decision_rate` 하나로 뭉치면 "메뉴를 넓혔더니 나빠졌다"까지만 알 수 있고
**어떤 종류의 혼동인지**를 못 본다. 그 혼동표가 §1.2 원칙의 실제 결과다.

---

## 8. STEP 2 (집행 전환) 승격 게이트

임계값은 축 A를 측정한 **뒤에** 정한다. 지금 숫자를 지어내지 않는다.
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

1. **기존 `dspy` 수치와의 직접 비교가 끊긴다** (§7.1). 축 B·C가 세계를 바꾼다.
   C7을 새 baseline으로 다시 세우는 비용이 든다.
2. **fault 메뉴에 `SwapBattery`가 오른다** (§5.3). 고르면 오답으로 집계되는 것이 의도다.
   `decision_rate`가 축 B에서 떨어질 수 있고, 그 하락은 결함이 아니라 측정값이다 — §7.4의
   혼동표 없이 이 숫자만 보면 오독한다.
3. **`Deprioritize` 잔재 제거는 이 작업에서 가장 큰 덩어리다** (§5.4). compile / verify /
   dispatch까지 배선돼 있고 코드 수정이 필요한 파일이 13개(테스트 3개 포함), `replan.jl`
   한 곳에만 16개 site가 있다. C4는 단일 커밋으로 묶고 앞뒤로 전체 스위트를 돌린다.
4. **재번호 + 무검사 로더 = 조용한 오독** (§5.2). `require_vocab`의 실제 소비처는
   `gate_ng2.py` 하나뿐이고 `macro` 열을 읽는 나머지 7곳은 도장을 보지 않는다(측정함).
   도장 배선 없이 재번호하면 디스크에 남은 `v3-4arms` 파일의 `macro=2`(RelocateBuild) 행이
   `SwapBattery`로 에러 없이 읽힌다. **C1이 그 배선을 같은 커밋에 포함해야 하는 이유다.**
   구세대 파일 제거(C7)는 두 번째 방어선이지 첫 번째가 아니다.
5. **0.30 · 0.50 rung의 실측 근거가 채점에서 버려진다** (§5.6). 지금 데이터로는 무영향.
6. **`laneC7` 워크트리와 갈라진다.** `sdd-lane-c7`의 `ood_truth.jl`은 이미 `ForbidZone`
   분기를 지운 상태이고 `src/smdp/`에 이 워크트리에 없는 파일들이 있다. 병합 시 충돌 지점이다.
