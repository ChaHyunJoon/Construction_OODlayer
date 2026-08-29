# 단일 채널 tool 레인 구현 계획 — tool 호출의 실패 케이스를 전부 닫는다

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 결정의 모든 성분을 **한 번의 tool 호출**로 받아, 집행과 채점이 갈릴 수 없게 만들고, 이 레인에서 tool 호출이 실패할 수 있는 경로를 하나씩 닫는다.

**Architecture:** 텍스트 `OutputField` 다섯을 없애고 `action`(`ToolCalls`) 하나만 남긴다. `macro`·`reasoning`·`expressible`·`ranking` 은 세 tool 의 **공통 인자**가 된다. `tool_choice="required"` 를 항상 싣고 `parallel_tool_calls=False` 로 다중 호출을 원천 차단한다. `chosen` 은 tool **이름**에서 유도하므로 `enact_target` 이 읽는 값과 정의상 같다.

**Tech Stack:** Python 3.12 / dspy 3.3.0 / FastAPI / pytest — `.venv/bin/python`. Julia 1.10 (`julia --project=.`).

**Spec:** `docs/superpowers/specs/2026-08-29-single-channel-tool-lane-design.md`

## Global Constraints

- 파이썬 인터프리터는 **`.venv/bin/python`** 하나다. `dspy 3.3.0`.
- `dspy_service.py:44` 의 `import numpy, sklearn.ensemble` 는 **`import dspy` 앞**에 있어야 한다. 순서를 바꾸면 surrogate 로드가 죽고 레인이 조용히 canonical 로 폴백한다.
- 🔴 **`git add -A` / `git add .` / `git commit -a` 금지.** 작업 트리에 남의 미커밋 삭제가 212건 있다. 반드시 명시 경로로 `git add`.
- **site-packages 를 고치지 않는다.** 재설치에 날아가고 레포 밖과 조용히 갈린다.
- 행동 어휘 단일 진실원은 `wm4spacecraft_manufacturing/core/action_registry.json` — 리터럴 복붙 금지. 현행 `v4-3arms`: `NOOP` · `Replace` · `SwapBattery`.
- 매 태스크 끝에 `.venv/bin/python -m pytest src/respec/llm_service/ -q` 가 초록이어야 한다. 착수 시점 기준선 **146 passed**(2026-08-29 실측) — 이 숫자는 태스크마다 자란다. 회귀 판정은 **직전 태스크에서 네가 잰 값**과 비교한다.
  🔴 **T3 은 이 제약의 유일한 예외다**(실행 중 판정, 아래 §0-B). T3 은 `macro()` 가 아직 읽는
  텍스트 필드를 지우므로 스위트를 **일부러 빨갛게 남긴다**. T3 끝의 정상 상태는 초록이 아니라
  **`124 passed / 48 failed`** 이고, 그중 정보가 있는 것은 26개뿐이다(§0-B ⑨).

---

## 0-A. 실행 상태 (2026-08-29, subagent-driven + max-reasoning 검증자)

| 태스크 | 상태 | 커밋 | 스위트 |
|---|---|---|---|
| — | 선행: F1 마감분(미커밋이던 것)을 분리 커밋 | `011ed3c0` | 146 passed |
| — | 계획서·설계서를 트래킹에 넣음 | `316faae6` | 146 passed |
| **T1** | ✅ 완료 (검증 2라운드) | `bd64ba11` → `3965d061` → `01cee573` | **155 passed / 0 failed** |
| **T2** | ✅ 완료 (검증 2라운드) | `f1dbee69` → `c48ffc95` → `6bb875ad` | **170 passed / 0 failed** |
| **T3** | ✅ 완료 (검증 1라운드) | `198d0440` → `d2c408a1` | **124 passed / 48 failed** ← 설계대로 |
| **T4** | ✅ 완료 (음성 대조 6종) | `7d525078` | **168 passed / 0 failed** |
| T5~T7 | ⬜ 미착수 | — | — |

✅ **T1~T3 이 열어 둔 두 구멍은 T4 가 닫았다**(실측, §0-B ⑪):
`macro()` 의 `NameError` 는 사라졌고(가짜 LM 으로 끝까지 태워 `decision_source="tool"` 확인),
`tool_args` 는 한 키(`agent`)만 실어 `ground_tool_args` 가 더 이상 `reject:off_schema_param` 을
안 낸다. **파이썬 레인은 이제 돈다.**

🔴 **그래도 아직 스윕을 돌리지 말 것 — 이유가 바뀌었다.** 남은 것은 배선이다:
① `TOOL_CHOICE_DEFAULT` 가 아직 `None` 이라 **호출을 강제하지 않는다**(실측 호출률 0/3 —
F3). T5 가 `"required"` 로 되돌린다.
② 줄리아 `TOOL_LANE_KEYS` 가 아직 옛 열 개라 `decision_source`·`tool_arg_error` 가 **결정
행에 안 실린다**(그리고 `test/tool_lane_keys_survive.jl` (6)절이 그 사실로 빨갛다). T6 이 닫는다.
⟹ 지금 돌리면 죽지는 않지만, tool 호출이 거의 안 오고 새 진단 키가 기록에서 빠진 **읽을 수
없는 스윕**이 된다.

## 0-B. 실행 중 반증되거나 정정된 것 — **다음 태스크가 이걸 안 읽으면 같은 자리를 다시 밟는다**

전부 T1~T3 실행 중에 이 머신에서 실측했거나 라이브러리를 직접 태워 확인했다.

**① F9 는 "신규 위험" 이 아니라 HEAD 에서 이미 발화 중이다.** 계획서는 F9 를 T4 가 닫을
장래 위험으로 적었다. 실측(`julia +lts --project=.`):
`ground_tool_args(env,"swap_body",{agent,macro,reasoning,expressible,ranking})` →
`("reject:off_schema_param", "선언 밖 인자=[expressible,macro,ranking,reasoning] 선언=[agent]")`.
`no_intervention` 도 같다. `_first_tool_call` 이 다섯 키를 전부 복사하고 `dspy_service.py:1340`
이 그대로 싣는다. → **T4 의 `_GROUNDING_ARGS` 필터가 계획대로 이걸 닫는다.** 계획서에 더할 것은
"T1~T4 사이는 안전한 정지점이 아니다" 한 줄뿐이다(§0-A).

**② 🔴 `test/tool_args_grounding.jl` 은 이 축에 대해 구조적으로 눈이 멀었다.** 계획서 T1 Step 5
는 이 계열이 빨개지면 멈추라고 적었는데, **빨개지지 않았다 — 145/145 초록이었다.** 이유:
`_PY_EXTRACT`(`:153-159`)가 `inspect.signature(_FUNCS[name])` 즉 **파이썬 함수 시그니처**를 읽고,
`build_tools()` 가 실제로 내는 JSON 스키마를 안 읽는다. 그 파일의 docstring 은 두 어휘를 묶는다고
주장하지만 이 축은 안 묶는다. → **T6 이 재조준하거나 이름을 바꿀 것.** T4 의 새 게이트는
`_GROUNDING_ARGS` ↔ `TOOL_PARAM_SCHEMA` 만 덮으므로, `build_tools()` 산출 ↔ 줄리아 축은 여전히
아무도 안 지킨다. **이 계획서의 옛 T1 Step 5 문장을 근거로 이 게이트를 다시 믿지 말 것.**

**③ 🔴 F14 는 틀렸다 — §4-1 구제 경로는 여전히 도달 가능하고, 그 유일한 방아쇠가 §5-1 과 충돌한다.**
계획서 F14 는 "§4-1 구제는 이 설계에서 뺄 것이 없어 무의미" 라고 적었고 T4 의 코드(`:650-654`)는
`except Exception` 하나로 받아 `no_call` 반환에 `error=err` 를 채운다. 실측: 검증자가 그 분기에
**여섯 가지 방법으로 도달**했다 — fc=False 에서 `action='not-json'` / `{}` / `None` /
action 키 없음 / `{'tool_calls':'str'}`, 그리고 **fc=True 에서 빈 응답**. `dspy/adapters/base.py:171-176`
이 텍스트도 tool_calls 도 없으면 **시그니처와 무관하게**
`AdapterParseError("The LM returned an empty or null response.")` 를 던지기 때문이다.
⟹ native FC 판에서 살아남은 유일한 방아쇠가 **정확히 §5-1 의 `no_call` 사건**인데, T4 를 쓰인
대로 구현하면 거기에 `error` 를 채운다 — §5-1 은 **`error` 에 아무것도 안 넣는다**고 못박는다
(장애와 계약 위반을 가르는 것이 그 키의 존재 이유다). `_blank_decision` 의 docstring 도
"`error` 는 비운다" 라고 적는데 `pred is None` 경로가 그걸 덮어쓴다.
→ **T4 는 빈 응답 `AdapterParseError` 를 진짜 프로바이더 장애와 갈라서 `error` 를 쓸지 정해야 한다.**

**④ `tool_arg_error` 로 실패 종류를 세면 안 된다.** `check_tool_args` 는 **처음 걸린 사유 하나만**
낸다. 순서는 `unknown_tool → args_not_a_dict → tool_missing_impl → valid_not_a_sequence →
agent_ids_not_a_sequence → missing_args → off_schema_args → expressible_not_a_bool →
macro_outside_menu → agent_outside_enum`. 실측: agent 가 틀렸고 **동시에** 다른 것도 틀리면
언제나 다른 쪽이 보고된다 ⟹ 이 문자열로 센 **F10 발생 수는 항상 과소집계다.** → **T7** 및 스윕
행을 읽는 사람은 축마다 따로 셀 것. (순서를 바꾸지 않기로 판정한 근거는 T2 절 끝의 정정 참조.)

**⑤ "접지 성공률" 은 `tool_arg_error is None` 이 아니다.** 스펙대로 잘 만들어진
`no_intervention` 호출은 파이썬에서 `None`(접지할 것이 없다)을 내는데 줄리아는 같은 호출에
`deferred:no_groundable_param` 을 낸다(`llm_bridge.jl:200-203` 이 그 구별의 이유를 적는다).
파이썬 반환이 2상인 것은 spec §3-5 대로라 규약 위반이 아니지만, **두 레인이 같은 이름의 비율을
서로 다른 분모로 계산하게 된다.** → **T7**/대시보드: NOOP 을 "접지됨" 에 접어 넣지 말 것.

**⑥ 파이썬 `want`(5키)와 줄리아 `TOOL_PARAM_SCHEMA`(1키)는 같은 축을 서로 다른 기준집합으로 잰다.**
T4 의 교차 게이트가 묶는 것은 `_GROUNDING_ARGS` ↔ `TOOL_PARAM_SCHEMA` 이고 그건 맞다. 그러나
`check_tool_args` 의 `off_schema_args` 는 5키 `want` 를 쓴다 — 두 검증기는 "off-schema" 의 뜻에
대해 **설계상 영원히 불일치**한다. → **T4**: `_GROUNDING_ARGS` 옆에 한 줄로 적어 둘 것. 나중에
둘을 한 게이트로 읽는 사람이 나온다.

**⑦ 소스를 읽는 게이트 셋은 `macro()` 가 런타임에 죽어 있어도 못 본다.**
`test_the_new_keys_stay_above_the_tool_lane_marker` · `test_synthesis_keys_sit_above_…` ·
줄리아 `test/tool_lane_keys_survive.jl` 은 전부 `dspy_service.py` **소스**를 파싱한다(AST/정규식,
줄리아 것은 요청 0건). **지금 셋 다 초록인데 `macro()` 는 매 호출 `NameError` 로 죽는다.**
소스 배치 게이트로서는 맞지만 **레인이 돈다는 증거가 아니다.** → **T6/T7**: 이들의 초록을 레인
건강의 근거로 인용하지 말 것. 그걸 재는 것은 T7 의 라이브 게이트다.

**⑧ `expressible` 의 JSON-Schema 타입은 T3 이 한때 무방비로 만들었다.** T3 이 지운
`test_expressible_is_declared` 는 존재뿐 아니라 **타입**도 못박고 있었다. 실측: `COMMON_ARGS` 의
`"expressible": {"type":"boolean"}` 을 `"string"` 으로 바꿔도 스위트가 **바이트 동일**하게 초록이었다.
`d2c408a1` 의 `test_the_common_args_keep_their_json_schema_types` 가 넷의 타입을 못박아 닫았다
(변이 7종 전부 이 시험 하나만 붉힌다). ⚠️ **다섯 번째 공통 인자는 여전히 타입 없이 들어올 수 있다**
— 다만 그 *도착* 자체는 시끄럽다(T2 의 `want` 가 구조적으로 유도되어 접지 시험 10개가 붉어진다).

**⑨ T3 의 48 red 는 22 + 26 이다. "48이 초록이 됐다" 는 T4 의 성공 기준이 아니다.**
22개는 `_EXPR` 랜드마인만으로 죽는다 — T4 가 `_EXPR` 참조를 지우는 순간 조립이 맞든 틀리든
초록이 된다. **정보가 있는 것은 나머지 26개**이고, 그것이 T4 가 조립 로직으로 직접 풀어야 할
잔여 레드셋이다. 두 목록(node id + 한 줄 이유)은
`.superpowers/sdd/2026-08-29-single-channel-tool-lane-plan/task-3-report.md` §8 에 있고 검증자의
독립 측정과 node 단위로 일치한다. → **T4 의 성공 기준은 "그 26개가 초록" 이다.**

**⑩ 설계서 세대 주의.** 2026-08-26 설계서는 "`macro` 는 별도 `OutputField` 로 남는다" 고 적는다.
**그 문장은 폐기됐다** — 이 계획이 딛는 2026-08-29 설계 §2 는 다섯 `OutputField` 를 전부 지우고
§3-1 이 `macro` 를 tool 인자로 옮겨 `macro_tool_agree` 를 살린다. 옛 설계서를 들고 T3 을 리뷰하면
멀쩡한 구현을 결함으로 잡는다(실제로 그럴 뻔했다).

**⑪ T4 실행 결과 — 계획서 Step 3 의 코드를 그대로 쓰면 안 되는 자리가 여섯이었다.**
전문은 `.superpowers/sdd/2026-08-29-single-channel-tool-lane-plan/task-4-report.md`. 요지:
(a) 빈 응답 `AdapterParseError` 는 `error` 가 아니라 **`tool_lane_error`** 로 보고한다 —
§0-B ③ 이 남긴 결정을 그렇게 내렸고, 문자열이 아니라 **예외 타입**으로 가른다(메시지 sniff 는
dspy 가 문구를 바꾸는 날 조용히 죽는다). 그래서 `no_call` 은 세 하위 사건을 덮고
`error`·`tool_lane_error`·`tool_calls_n` 이 가른다(새 키 0개).
(b) 계획서의 새 반환 dict 에 **`tool_minted` 가 빠져 있다** — 그대로 쓰면 `/decide` 가
`KeyError` 로 죽는다(라이브 레인은 `/decide` 로만 들어온다).
(c) 계획서 Step 1 의 시험 코드 두 곳이 이 harness 에서 **틀리다**: `agent` 리터럴이 그 파일의
`AGENTS` 에 없어 조립 시험 넷이 조용히 접지 실패 경로를 재고, `fc=True` 는 `_FCDummy` 가 native
tool_call 을 직렬화 못 해 `tool_called` 이 **언제나 None** 이 된다(조립 시험은 `fc=False` 여야 한다).
(d) 🔴 음성 대조 M6 이 **계획서의 가드 하나를 결함으로 잡았다**: `said` 를 접지 실패 시 `None`
으로 접는 줄은 어떤 시험도 안 붙잡았고(지워도 168 전부 초록), 접지 실패의 대부분이 `agent` 축
이므로 그 부분모집단 전체를 불일치율의 분모에서 조용히 뺀다. 지웠다.

**⑫ 🔴 §0-B ⑦ 의 "소스 게이트 셋 다 초록" 은 `test/tool_lane_keys_survive.jl` 에 대해 거짓이었다.**
T4 착수 **전**(`3e62d50e` 의 파이썬)으로 되돌려 잰 값: **152 pass / 13 fail** — (3)절
"enacted 가 dspy 가 아니면 8키가 전부 nothing 이다" 에서 이미 13개가 빨갰다(뿌리는 하나로 보인다:
`_MODE[] = :surro` 인데 `d.enacted` 가 `"dspy"` 로 나오고 그 전제가 깨져 아래가 연쇄로 무너진다).
그 절은 파이썬을 한 줄도 안 읽는 순수 줄리아 mock 이라 **이 레인과 무관하고 T4 의 범위 밖이다.**
T4 후는 150/15 — 즉 **T4 가 더한 실패는 정확히 2개이고 둘 다 (6)절**(교차언어 키 등호)이며
T6 이 닫는다. → **이 파일의 초록을 어떤 근거로도 인용하지 말 것. 지금 초록이 아니다.**
누가 (3)절을 고칠지는 **미정이다** — 이 계획에 그 태스크가 없다.

**⑬ 구조적으로 도달 불가가 된 사건 하나.** "강등 전 macro 로 일치를 잰다" 는 계약이 위반되는
사건을 **이제 만들 수 없다**: 갈리려면 `MACRO_TO_TOOL[said] == 부른 tool` 이면서
`TOOL_TO_MACRO[부른 tool] ∉ valid` 여야 하는데, 두 조건이 합쳐지면 `said ∉ valid` 라 T2 의
`check_tool_args` 가 `macro_outside_menu` 로 먼저 거른다. 계약은 코드에 남기고 시험만 지웠다 —
T2 의 **검사 순서가 바뀌면 그 사건이 되살아난다.**

**⑭ `native_fc` 의 값 종류가 셋이 됐다.** `True`/`False`/`None`. `no_tools` 행은 LM 을 아예 안
불렀으므로 `None`("못 쟀다")이지 `False`("물었는데 안 켜졌다")가 아니다. 예전 C8 축약은 실제로
물어서 `False` 를 쟀다 — 두 값을 접으면 그 두 사건이 섞인다. `policy.jl:1219-1221` 의
*"`native_fc` 는 null 가능한 넷에 들지 않는다"* 는 주석은 **이제 거짓이다.** T6 이 정정할 것.

---

## 0. 이 계획이 닫는 실패 케이스 — 이것이 계획의 축이다

전부 2026-08-29 에 이 머신에서 실측했거나 설치된 라이브러리를 직접 태워 확인한 것이다.

| # | 실패 | 어떻게 나타나나 | 오늘 상태 | 닫는 태스크 |
|---|---|---|---|---|
| **F1** | `tool_choice` 오설정 | dspy 의 닫힌 enum 에서 `ValidationError` → 포괄 except → `error` → `policy_entry` 가 레인을 `available=false` 로 버린다. **결정 전체가 매 사건 사라지고 아무도 말 안 해 준다** | ✅ 닫힘 (2026-08-29) | T7 회귀 게이트만 |
| **F2** | tool 0개인데 `tool_choice` 전송 | `openai_format.py:81-83` 이 `tool_choice` 를 `tools` 와 **무관하게** 싣는다 → 프로바이더 400 | 부분 (`_ask` 의 `if tools:`) | **T5** |
| **F3** | 강제 없이 호출이 안 나온다 | 실측 **0/3**. 프롬프트·필드 제거·행위자 프레이밍 전부 0/3. 모델이 판단 과제로 보면 답변하고 행동하지 않는다 | 🔴 열림 | **T5** |
| **F4** | `required` 가 텍스트 채널을 비운다 | `content=None` → `adapters/base.py:168` 이 `value={}`, `:181` 이 전 필드 `None`. **예외가 안 난다** → §4-1 구제가 발화조차 안 함 | 🔴 2콜로 우회 중 | **T3** |
| **F5** | 집행 ≠ 채점 | 실측 **3/3**. `fault-severe`: 채점 `Replace`, 집행 `deliver_battery` | ✅ 닫힘 (T4, `7d525078`) | T7 라이브 확인 |
| **F6** | `expressible` 오판 (T1 은 **문구를 payload 에 싣기만** 한다 — 기록되는 값이 tool 인자에서 나오는 것은 T3 부터고, 행동 변화의 증거는 T7 뿐이다) | 어휘 밖 사건에서 **1/3만** `False`. 모델이 "표현 불가"와 "개입 불필요"를 혼동 → T2 합성이 정작 필요할 때 안 돈다 | 🔴 열림 | **T1** + T7 실측 |
| **F7** | R26 이 `chosen` 을 같이 지운다 | 단일 채널에서 `chosen` 이 `tool_called` 에서 나오는데 R26 이 그것을 `None` 으로 만든다 | ✅ 닫힘 (T4) — `chosen` 은 억제 **전** 이름에서 나온다 | — |
| **F8** | R26 행 ↔ 메뉴 거절(C8②) 구별 불가 | 둘 다 `tool_called is None` | ✅ `tool_calls_n` 이 가른다 | **T4** (0으로 안 덮음 유지) |
| **F9** | ✅ **닫힘 (T4, 실측)** — 옛 상태: `tool_args` 에 공통 인자가 샌다 (T1~T3 HEAD 에서 발화 중이었다, §0-B ①) | 줄리아 `TOOL_PARAM_SCHEMA`(`llm_bridge.jl:148-151`)는 `agent`/`reason` **둘만** 선언한다. 새면 `ground_tool_args` 가 `reject:off_schema_param` → **집행이 전 사건에서 정지** | 🔴 신규 **고위험** | **T4** 교차 게이트 |
| **F10** | enum 밖 `agent` id | `dspy.Tool` 에 `strict` 필드가 **없다**(실측: `model_fields` = `arg_desc·arg_types·args·desc·func·has_kwargs·name`). 스키마가 강제가 아니다 | 부분 (줄리아만) | **T2** |
| **F11** | 다중 tool 호출 | `_first_tool_call` 이 첫 번째만 쓰고 나머지를 버린다 | 부분 (기록만) | **T5** (원천 차단) |
| **F12** | 필수 인자 누락 | `required` 목록이 강제가 아니다(F10 과 같은 뿌리). `expressible` 이 없으면 `None` → T2 합성이 안 돈다 | 🔴 열림 | **T2** |
| **F13** | `expressible` 이 bool 이 아니다 | `bool("False") is True` — 거짓 `True` 가 조용히 기록된다 | ✅ `isinstance` 검사 | **T4** (유지) |
| **F14** | ✅ 닫힘 (T4) — tool 인자 JSON 파싱 실패 | `AdapterParseError`. ~~§4-1 구제는 이 설계에서 뺄 것이 없어 무의미~~ 🔴 **이 판단은 반증됐다** — 구제 분기는 여전히 도달 가능하고 native FC 판에서 살아남은 방아쇠가 `no_call` 이다(§0-B ③) | 🔴 재정의 필요 | **T4** |
| **F15** | `required` 인데 호출이 없다 | 계약 위반 | ✅ 닫힘 (T4) — `decision_source="no_call"`, `error` 는 안 채운다 | — |
| **F16** | 프로바이더 장애 | `LMError` | ✅ `error` | 유지 |

**F9 가 이 계획에서 가장 위험하다.** 조용하지 않고 시끄럽게 실패하지만(`reject:off_schema_param`), 그 시끄러움이 **집행 레인 전체를 멈춘다**. T4 의 교차 게이트가 파이썬이 내는 `tool_args` 키 집합과 줄리아의 `TOOL_PARAM_SCHEMA` 를 집합 등식으로 묶는다.

---

## 파일 구조

| 파일 | 책임 | 태스크 |
|---|---|---|
| `src/respec/llm_service/tool_registry.py` | tool 정의·공통 인자·`MACRO_TO_TOOL`/`TOOL_TO_MACRO`·인자 접지 | T1, T2 |
| `src/respec/llm_service/test_tool_registry.py` | 위의 게이트 | T1, T2 |
| `src/respec/llm_service/dspy_service.py` | 시그니처·요청 손잡이·`macro()` 응답 조립 | T3, T4, T5 |
| `src/respec/llm_service/test_macro_returns_tool_call.py` | 응답 조립 게이트 | T3, T4 |
| `src/respec/llm_service/test_tool_choice_forced.py` | 요청 손잡이 게이트 | T5 |
| `src/respec/llm_service/test_native_fc_active.py` · `test_native_fc_wired.py` | native FC 발화 게이트 | T3 |
| `tools/monitor/policy.jl` | `TOOL_LANE_KEYS`·`service_decide` | T6 |
| `test/tool_choice_gate.jl` | 줄리아 게이트 | T6 |
| `src/respec/llm_service/test_live_single_channel.py` | 라이브 실측 (유료, 기본 skip) | T7 |

---

## ⏱ 소요시간 요약

추정 기준: 내가(에이전트) 실행하는 벽시계 시간이고 **시험 실행 시간을 포함**한다. 측정된 상수: `pytest src/respec/llm_service/ -q` = **11초**, `julia --project=. test/<file>.jl` = **3~6분**(콜드 컴파일 지배), `Pkg.test()` = **약 5분**, 유료 호출 = **15~30초/콜**.

| 태스크 | 내용 | 닫는 실패 | 추정 |
|---|---|---|---|
| T1 | tool 스키마: 공통 인자 넷 + `expressible`·`reasoning` 설명 개정 + `TOOL_TO_MACRO` | F6 | **40~60분** |
| T2 | 파이썬 인자 접지 계층 (`check_tool_args`) | F10, F12 | **50~70분** |
| T3 | 시그니처를 `action` 하나로 축소 | F4 | **30~45분** |
| T4 | `macro()` 단일 채널 조립 + `decision_source` 삼상 + F9 교차 게이트 | F5·F7·F8·F9·F13·F14·F15 | **90~120분** |
| T5 | 요청 손잡이: `required` 고정 · `parallel_tool_calls=False` · `no_tools` 조기 반환 | F2, F3, F11 | **30~40분** |
| T6 | 줄리아 배선: `decision_source` 나르기 · `text_rescue` 제거 | — | **40~60분** |
| T7 | 라이브 실측 게이트 + 전체 회귀 | F1 회귀 · F6 확인 | **30~45분** |
| | **합계** | | **5.2 ~ 7.3시간** |

여기에 마지막 `Pkg.test()` 전체 1회(약 5분)와 유료 호출 약 12건(T7)이 더해진다.

⚠️ **T4 가 전체의 4분의 1이다.** 쪼개고 싶으면 T4-a(조립)와 T4-b(실패 경로 삼상)로 나눌 수 있으나, 둘이 같은 함수의 같은 반환 dict 을 만지므로 리뷰 경계가 서지 않는다 — 하나로 둔다.

---

# Task 1: tool 스키마 — 공통 인자 넷과 개정된 설명

> ✅ **완료 (2026-08-29): `bd64ba11` → `3965d061` → `01cee573`. 155 passed / 0 failed.**
> 계획서 코드에서 **바뀐 것 셋** — 다시 쓸 일이 있으면 이 상태가 진실원이다:
> 1. `COMMON_ARGS` 의 파라미터 이름이 `valid` → **`emitted`** 다. 계약도 좁아졌다: "이 사건에서
>    **실제로 tool 로 나가는** 매크로". 이유: `agents=[]` 인 사건에서 `swap_body` 는 안 나가는데
>    `no_intervention` 의 `macro` enum 에 `"Replace"` 가 남아, **스키마가 스스로 만든 불일치**를
>    T4 가 `macro_tool_agree=False` 로 기록하게 된다(실측). `ranking` 은 그대로 **전체 채점 메뉴**를
>    말한다 — 이 비대칭은 의도된 것이다(모델이 보는 메뉴가 셋이 된다: `valid_actions` 전체 ·
>    `ranking` 전체 · `macro` enum 은 호출 가능한 것만).
> 2. `build_tools` 는 "이 매크로가 tool 로 나가는가" 를 **한 곳에서만** 판정한다. 한 번의 순회로
>    `(macro, tool_name, unique_args)` 를 모으고 enum 도 `dspy.Tool` 구성도 그 목록에서만 유도한다.
>    (중간 판이 그 조건을 두 벌 적었고, 검증자가 한쪽에만 스킵 규칙을 얹어 **전 시험 초록인 채로**
>    두 벌이 갈릴 수 있음을 실측했다. `tool_registry.py:89-90` 이 그 규칙의 진실원이다.)
> 3. 계획서 Step 2 의 기대값 "7 failed" 는 틀렸다 — **실측 5 failed / 2 passed**.
>    `test_the_unique_args_are_untouched` 와 `test_all_args_are_required` 는 구현 **전에도** 초록이었다.
>    후자는 그 뒤 "넷이 각각 `required` 에 있다" 를 직접 단언하도록 강화됐다(옛 집합 등식만으로는
>    `expressible` 을 통째로 지워도 초록이었다 — 실측).

**Files:**
- Modify: `src/respec/llm_service/tool_registry.py` (`build_tools` 는 `:104-127`, `MACRO_TO_TOOL` 는 `:87`)
- Test: `src/respec/llm_service/test_tool_registry.py`

**Interfaces:**
- Produces: `COMMON_ARGS(valid: List[str]) -> Dict[str, Any]` — 네 인자의 JSON Schema 조각
- Produces: `TOOL_TO_MACRO: Dict[str, str]` — `MACRO_TO_TOOL` 의 정확한 역표
- Produces: `build_tools(agents, valid) -> List[dspy.Tool]` — 시그니처 불변, 각 tool 이 고유 인자 + 공통 인자 넷을 갖는다
- Consumes: 없음

**닫는 실패:** F6 (`expressible` 오판 1/3 → 3/3)

- [ ] **Step 1: 실패하는 시험을 쓴다** — `test_tool_registry.py` 끝에 덧붙인다

```python
# ---- 2026-08-29 (단일 채널): 결정 성분이 tool 인자로 들어간다 --------------------------------
_COMMON = ("macro", "reasoning", "expressible", "ranking")


def test_every_tool_carries_the_four_common_args():
    """🔴 텍스트 OutputField 가 사라지므로 이 넷이 결정의 **유일한** 운반체다."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])
    assert len(tools) == 3
    for t in tools:
        props = t.format_as_litellm_function_call()["function"]["parameters"]["properties"]
        for name in _COMMON:
            assert name in props, "%s 에 %s 가 없다" % (t.name, name)


def test_the_unique_args_are_untouched():
    """음성 대조: 공통 인자를 더하는 것이 접지용 고유 인자를 밀어내면 안 된다."""
    tools = {t.name: t for t in
             reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])}
    for name in ("swap_body", "deliver_battery"):
        p = tools[name].format_as_litellm_function_call()["function"]["parameters"]["properties"]
        assert p["agent"]["enum"] == ["r1"], "agent enum 이 접지의 재료다"
    p = tools["no_intervention"].format_as_litellm_function_call()["function"]["parameters"]["properties"]
    assert p["reason"]["type"] == "string"


def test_macro_arg_is_an_enum_of_this_events_legal_macros():
    """어휘 밖 macro 를 낼 여지를 스키마에서 줄인다(강제는 아니다 -- F10)."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "NOOP"])
    p = tools[0].format_as_litellm_function_call()["function"]["parameters"]["properties"]
    assert p["macro"]["enum"] == ["Replace", "NOOP"]


def test_all_args_are_required():
    """🔴 `expressible` 이 빠지면 T2 합성의 방아쇠가 사라진다. 스키마에서 요구한다."""
    tools = reg.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])
    for t in tools:
        params = t.format_as_litellm_function_call()["function"]["parameters"]
        assert set(params["required"]) == set(params["properties"])


def test_expressible_description_separates_the_two_events():
    """🔴 실측(2026-08-29): 옛 문구로는 어휘 밖 사건에서 1/3 만 False 였다. 나머지 둘은
    reasoning 에서 "근본 원인을 못 고친다" 고 말하면서 True 를 냈다 -- 모델이 "표현 불가" 와
    "개입 불필요" 를 혼동한다. 개정 문구가 그 둘을 **명시적으로** 가르고, 그때 3/3 이 됐다.
    이 시험은 그 두 문장이 사라지지 않게 지킨다."""
    d = reg.COMMON_ARGS(["Replace", "NOOP"])["expressible"]["description"]
    assert "unnecessary" in d and "outside the menu" in d, \
        "두 사건을 가르는 문장이 빠지면 발화율이 1/3 로 돌아간다"


def test_reasoning_description_asks_for_the_gap_in_words():
    """`margin` 스칼라를 없앤 대가로 이 문장이 그 자리를 나른다(spec §3-3)."""
    d = reg.COMMON_ARGS(["Replace", "NOOP"])["reasoning"]["description"]
    assert "runner-up" in d and "not as a number" in d


def test_tool_to_macro_is_the_exact_inverse():
    """🔴 두 표가 갈리면 `chosen` 이 조용히 틀린다 -- 이 설계에서 `chosen` 은 tool 이름에서만
    나오므로 이 등식이 곧 결정의 정확성이다."""
    assert reg.TOOL_TO_MACRO == {v: k for k, v in reg.MACRO_TO_TOOL.items()}
    assert len(reg.TOOL_TO_MACRO) == len(reg.MACRO_TO_TOOL), "역표가 값 충돌로 줄면 안 된다"
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q -k "common_args or unique_args or macro_arg or all_args or expressible_description or reasoning_description or exact_inverse"`
Expected: 7 failed — `AttributeError: module 'tool_registry' has no attribute 'COMMON_ARGS'`

- [ ] **Step 3: 구현한다** — `tool_registry.py` 의 `MACRO_TO_TOOL` 정의 **아래**에 붙인다

```python
# 🔴 tool 이름 -> 매크로 이름. `MACRO_TO_TOOL` 에서 **유도한다** — 손으로 두 벌 적으면 갈린다.
#    이 설계에서 `chosen` 은 오직 이 표를 통해 나오므로, 여기가 틀리면 결정이 틀린다.
TOOL_TO_MACRO = {v: k for k, v in MACRO_TO_TOOL.items()}
assert len(TOOL_TO_MACRO) == len(MACRO_TO_TOOL), \
    "MACRO_TO_TOOL 이 두 매크로를 같은 tool 에 보낸다 — 역표가 성립하지 않는다"

# ---- 결정 성분을 나르는 공통 인자 (2026-08-29, 단일 채널) ------------------------------------
# 🔴 왜 인자인가. `tool_choice="required"` 판에서 프로바이더는 tool 호출만 내고 message content
#    를 비운다. 그러면 텍스트 OutputField 는 `adapters/base.py:168·181` 이 **예외 없이** 전부
#    `None` 으로 만든다. 즉 강제 하에서 결정을 받을 수 있는 채널은 tool 인자 **하나뿐**이다.
_EXPRESSIBLE_DESC = (
    "false if NOTHING in this tool menu can remove the CAUSE of what you observed -- "
    "i.e. you are calling a tool only because you must, not because it fixes anything. "
    "Answering NOOP because intervening is unnecessary is NOT this: that is true. "
    "Set false when the fix this event needs is outside the menu entirely.")
# 🔴 마지막 두 문장이 하중을 받는다. 실측(2026-08-29): 이 두 문장이 없는 옛 문구
#    ("false if NO available tool can address what you observed")로는 어휘 밖 사건 셋 중
#    **하나만** False 였고, 개정 후 3/3 이 됐다. 대조군(진짜 배터리 사건)은 양쪽 다 True —
#    거짓 양성은 안 생겼다.
#    ⚠️ 대가: 이 문구는 모델에게 *언제 false 라고 말할지*를 가르친다. 그래서 `expressible ==
#    False` 비율은 부분적으로 **프롬프트 준수**를 잰다. 세대를 가르는 키는 `decision_source` 다.

_REASONING_DESC = (
    "one sentence: why this action, and how clearly it beats the runner-up -- "
    "say that in words (e.g. \"clearly better than X\" / \"only marginally better than X\" / "
    "\"essentially tied with X\"), not as a number.")
# 🔴 `margin` 스칼라를 없앤 자리다(spec §3-3). 그 값은 계산된 적이 없는 자기 신고였고 무엇과도
#    대조된 적이 없다(실측: harm 0.88 사건이 0.5, soc 12% 사건이 0.8). 실측(2026-08-29): 이
#    문구로 3/3 이 비교 절을 산문에 담았고, 어느 대안보다 나은지까지 말해 숫자보다 정보가 많다.


def COMMON_ARGS(valid):
    """세 tool 이 **전부** 갖는 결정 성분 인자. 고유 인자(`agent`/`reason`)와 합쳐 쓴다.

    🔴 `valid` 를 받는 이유는 `macro` enum 이 **이 사건의** legal 매크로여야 하기 때문이다.
    모듈 상수로 굳히면 사건마다 다른 메뉴를 못 따라간다.
    """
    return {
        "macro": {"type": "string", "enum": list(valid),
                  "description": "the macro name this call enacts"},
        "reasoning": {"type": "string", "description": _REASONING_DESC},
        "expressible": {"type": "boolean", "description": _EXPRESSIBLE_DESC},
        "ranking": {"type": "string",
                    "description": "ALL legal macros ordered best-first, comma separated"},
    }
```

그리고 `build_tools` 의 두 `out.append(...)` 를 다음으로 바꾼다:

```python
def build_tools(agents, valid) -> List[dspy.Tool]:
    """이 요청에서 호출 가능한 tool 목록.

    `agents` : [{"id": ..., "label": ...}, ...] — 실재하는 로봇만.
    `valid`  : 이 사건에서 legal 한 **매크로** 이름 목록(호출자가 세계를 보고 계산한 것).

    🔴 로봇 id 가 하나도 없으면 로봇을 지목하는 tool 을 **아예 안 낸다.** 빈 enum 은 provider 가
    거부하거나 아무 문자열이나 통과시키는데, 후자면 ②접지가 조용히 뚫린다.

    🔴 2026-08-29: 각 tool 이 `COMMON_ARGS(valid)` 를 함께 싣는다 — 그것이 이 설계에서 결정을
    받는 유일한 채널이다.
    """
    agent_ids = [a["id"] for a in (agents or []) if a.get("id")]
    common = COMMON_ARGS(valid)
    out = []
    for macro in (valid or []):
        name = MACRO_TO_TOOL.get(macro)
        if name is None:
            continue
        if _needs_agent(name):
            if not agent_ids:
                continue
            args = dict(_agent_arg(agent_ids))
        else:
            args = {"reason": {
                "type": "string",
                "description": "what you observed that made intervention unnecessary"}}
        args.update(common)
        out.append(dspy.Tool(_FUNCS[name], args=args))
    return out
```

- [ ] **Step 4: 시험이 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q`
Expected: 전부 PASS

- [ ] **Step 5: 파일 전체 회귀를 본다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ -q`
Expected: PASS.
~~⚠️ `test_tool_args_grounding` 계열이 깨지면 **멈추고 T2 를 앞당긴다** — 인자 집합이 바뀌었다는 뜻이다.~~
🔴 **이 트립와이어는 작동하지 않는다(2026-08-29 실측).** 인자 집합이 실제로 바뀌었는데
`test/tool_args_grounding.jl` 은 **145/145 초록**이었다 — `_PY_EXTRACT`(`:153-159`)가 파이썬 **함수
시그니처**를 읽고 `build_tools()` 가 내는 JSON 스키마를 안 읽기 때문이다. 전문은 §0-B ②.
이 줄을 근거로 그 게이트를 믿지 말 것.

- [ ] **Step 6: 커밋**

```bash
git add src/respec/llm_service/tool_registry.py src/respec/llm_service/test_tool_registry.py
git commit -m "T1: 결정 성분을 tool 인자로 옮긴다 — expressible 설명이 두 사건을 가른다"
```

---

# Task 2: 파이썬 인자 접지 계층

> ✅ **완료 (2026-08-29): `f1dbee69` → `c48ffc95` → `6bb875ad`. 170 passed / 0 failed.**
> 계획서 코드에서 **더해진 것** — `check_tool_args` 는 계획서 본문보다 넓다:
> 1. **총함수다. 어떤 입력에도 예외를 안 던지고 사유 문자열을 낸다.** `valid=None`·`agent_ids=None`·
>    dict 아닌 `args`·`MACRO_TO_TOOL` 에만 있고 `_FUNCS` 에 없는 이름 전부. 🔴 이유가 중요하다:
>    T4 가 `macro()` 안에서 이걸 부르는데, 거기서 난 예외는 응답의 `error` 로 삼켜지고
>    `policy_entry` 가 **레인 전체를 `available=false`** 로 버린다 — 사유를 보고하라고 만든 검증기가
>    조용한 전면 폴백의 원인이 된다. (남은 구멍: `valid=7` 처럼 **truthy 인데 타입이 틀린** 값은
>    아직 던진다. `x or []` 는 falsy 만 잡는다. T4 호출부에서는 도달 불가.)
> 2. **`str` 인 `valid` 를 거절한다.** `args["macro"] not in valid` 가 문자열에 대해 **부분문자열
>    매칭**을 해서, `valid="Replace,SwapBattery"` 면 `macro="Swap"` 이 조용히 접지에 성공한다(실측).
>    `agent_ids` 도 같다.
> 3. 12개 가드 **전부** 자기 시험에 묶여 있고, 각 거절 시험은 사유 문자열의 **머리**를 못박는다
>    (`why.startswith("unknown_tool:")`). 느슨한 부분문자열 단언(`"reason" in why` 는 `reasoning`
>    때문에 항상 참)이 가드를 놓치는 것을 실측으로 두 번 잡았다.
> 4. **검사 순서는 안 바꿨다** — `agent_outside_enum` 이 마지막이라 F10 이 과소집계된다는 사실은
>    docstring 에 적어 두는 쪽을 택했다. 근거와 귀결은 §0-B ④.

**Files:**
- Modify: `src/respec/llm_service/tool_registry.py`
- Test: `src/respec/llm_service/test_tool_registry.py`

**Interfaces:**
- Consumes: T1 의 `COMMON_ARGS` · `MACRO_TO_TOOL`
- Produces: `check_tool_args(name: str, args: dict, valid: List[str], agent_ids: List[str]) -> Optional[str]` — `None` 이면 접지 성공, 문자열이면 **거절 사유**

**닫는 실패:** F10 (enum 밖 `agent` id), F12 (필수 인자 누락) — spec §3-5

🔴 **왜 파이썬에도 필요한가.** `dspy.Tool` 에는 `strict` 필드가 **없다**(실측: `model_fields` = `arg_desc·arg_types·args·desc·func·has_kwargs·name`). 즉 `enum` 도 `required` 도 프로바이더에게 **권고**이지 강제가 아니다. 줄리아의 `ground_tool_args`(`llm_bridge.jl:238`)가 같은 것을 검사하지만, 그것은 **집행 직전**이라 그때는 이미 응답이 기록됐다. 잘못된 인자가 기록에 남으면 나중에 그 행을 읽는 사람이 "모델이 이렇게 답했다" 로 읽는다.

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
def test_grounding_accepts_a_well_formed_call():
    """음성 대조 먼저 — 검증이 정상 호출을 막으면 레인이 통째로 죽는다."""
    ok = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace, NOOP"},
        ["Replace", "NOOP"], ["r1"])
    assert ok is None


def test_grounding_rejects_an_agent_outside_the_enum():
    """🔴 F10. dspy.Tool 에 strict 가 없으므로 enum 은 권고다 — 실제로 뚫릴 수 있다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r9", "macro": "Replace", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and "agent" in why and "r9" in why


def test_grounding_rejects_a_missing_required_arg():
    """🔴 F12. `expressible` 이 없으면 T2 합성의 방아쇠가 조용히 사라진다."""
    why = reg.check_tool_args(
        "swap_body", {"agent": "r1", "macro": "Replace", "reasoning": "x", "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and "expressible" in why


def test_grounding_rejects_a_macro_outside_this_events_menu():
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "SwapBattery", "reasoning": "x", "expressible": True,
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and "macro" in why


def test_grounding_rejects_an_unknown_tool():
    why = reg.check_tool_args("teleport", {}, ["NOOP"], ["r1"])
    assert why is not None and "teleport" in why


def test_grounding_rejects_a_non_bool_expressible():
    """🔴 F13 의 짝. `bool("False") is True` 라 문자열을 받아 주면 거짓 True 가 기록된다."""
    why = reg.check_tool_args(
        "swap_body",
        {"agent": "r1", "macro": "Replace", "reasoning": "x", "expressible": "False",
         "ranking": "Replace"},
        ["Replace", "NOOP"], ["r1"])
    assert why is not None and "expressible" in why


def test_no_intervention_needs_reason_not_agent():
    assert reg.check_tool_args(
        "no_intervention",
        {"reason": "nothing broke", "macro": "NOOP", "reasoning": "x", "expressible": True,
         "ranking": "NOOP"},
        ["NOOP"], []) is None
    why = reg.check_tool_args(
        "no_intervention",
        {"macro": "NOOP", "reasoning": "x", "expressible": True, "ranking": "NOOP"},
        ["NOOP"], [])
    assert why is not None and "reason" in why
```

- [ ] **Step 2: 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q -k "grounding or no_intervention_needs"`  ← 🔴 따옴표 없으면 셸이 쪼갠다(계획서 원문의 결함)
Expected: FAIL — `has no attribute 'check_tool_args'`

- [ ] **Step 3: 구현한다** — `COMMON_ARGS` 아래에 붙인다

```python
def check_tool_args(name, args, valid, agent_ids):
    """tool 호출 인자를 검증한다. `None` = 접지 성공, 문자열 = **거절 사유**.

    🔴 왜 여기서도 검사하나. `dspy.Tool` 에 `strict` 가 없어(실측) `enum`·`required` 가 전부
    권고다. 줄리아의 `ground_tool_args`(`llm_bridge.jl:238`)가 같은 축을 집행 직전에 보지만,
    거기 닿을 때는 이미 응답이 기록된 뒤다 — 잘못된 인자가 남으면 그 행을 읽는 사람이
    "모델이 이렇게 답했다" 로 읽는다.

    🔴 사유 문자열은 **그대로 응답의 `tool_arg_error` 에 실린다.** 사람이 읽고 바로 고칠 수
    있어야 하므로 나쁜 값과 기대값을 둘 다 담는다.
    """
    if name not in MACRO_TO_TOOL.values():
        return "unknown_tool: %r (등록된 것은 %s)" % (
            name, ", ".join(sorted(MACRO_TO_TOOL.values())))
    if not isinstance(args, dict):
        return "args_not_a_dict: %r" % (args,)
    want = set(COMMON_ARGS(valid)) | ({"agent"} if _needs_agent(name) else {"reason"})
    missing = sorted(want - set(args))
    if missing:
        return "missing_args: %s (요구=%s 실려온=%s)" % (
            ",".join(missing), ",".join(sorted(want)), ",".join(sorted(args)))
    extra = sorted(set(args) - want)
    if extra:
        return "off_schema_args: %s (요구=%s)" % (",".join(extra), ",".join(sorted(want)))
    # 🔴 bool 은 `isinstance` 로 본다. `bool("False") is True` 라 캐스팅하면 거짓 True 가 난다.
    if not isinstance(args["expressible"], bool):
        return "expressible_not_a_bool: %r" % (args["expressible"],)
    if args["macro"] not in valid:
        return "macro_outside_menu: %r (이 사건의 메뉴=%s)" % (args["macro"], ",".join(valid))
    if _needs_agent(name) and args["agent"] not in agent_ids:
        return "agent_outside_enum: %r (실재하는 id=%s)" % (
            args["agent"], ",".join(agent_ids) or "<없음>")
    return None
```

- [ ] **Step 4: 통과 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q`
Expected: 전부 PASS

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/tool_registry.py src/respec/llm_service/test_tool_registry.py
git commit -m "T2: tool 인자 접지 계층 — strict 가 없는 스키마를 런타임이 대신 지킨다"
```

---

# Task 3: 시그니처를 `action` 하나로 축소

> ✅ **완료 (2026-08-29): `198d0440` → `d2c408a1`. 124 passed / 48 failed — 설계대로 빨갛다.**
> 계획서에 없던 판정 셋:
> 1. **`test_native_fc_wired.py` 의 두 시험을 지웠다** — `test_macro_stays_a_separate_output_field`
>    와 `test_expressible_is_declared`. 그 둘은 "`macro`/`expressible` 이 **출력 필드다**" 를 단언하는데
>    이 태스크가 지우는 것이 정확히 그 설계다(고칠 것이 아니라 참이 아니게 된 것). 각 자리에 한 줄
>    주석을 남겼다. 그 파일의 기대값은 **6 → 4 passed**.
>    ⚠️ 대가: `test_expressible_is_declared` 는 **타입**도 못박고 있었고 아무것도 그 자리를 안 메웠다
>    — `d2c408a1` 의 `test_the_common_args_keep_their_json_schema_types` 가 닫았다(§0-B ⑧).
> 2. **`_EXPR` 를 정말로 지웠다.** 그래서 `dspy_service.py:1187`·`:1273` 이 정의되지 않은 이름을
>    참조하고 `macro()` 가 매 호출 `NameError` 로 죽는다. 남겨 두는 대안은 `delete(_EXPR)` 를
>    **조용한 no-op** 으로 만들어 "지웠다" 는 거짓을 만든다(`Signature.delete` 는 `fields.pop(name, None)`).
>    T4 가 통째로 지울 코드 안의 시끄러운 `NameError` 가 낫다고 판정했다.
> 3. **48 red 의 분해가 이 태스크의 진짜 산출물이다** — 22 랜드마인 + 26 진짜. §0-B ⑨.

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py:201-224` (`SelectTool`), `:962` (`_FC_IN`/`_FC_OUT`/`_EXPR`)
- Test: `src/respec/llm_service/test_native_fc_active.py`, `test_native_fc_wired.py`, `test_macro_returns_tool_call.py`

**Interfaces:**
- Consumes: T1 의 tool 스키마
- Produces: `SelectTool` 의 `output_fields == {"action"}`. 이름은 **안 바꾼다**(33개 참조를 건드리지 않는다).

**닫는 실패:** F4

- [ ] **Step 1: 실패하는 시험을 쓴다** — `test_native_fc_active.py` 끝에

```python
def test_the_signature_has_exactly_one_output_field():
    """🔴 F4. `tool_choice="required"` 판에서 프로바이더가 content 를 비우면
    `adapters/base.py:168` 이 `value={}` 를, `:181` 이 전 필드 `None` 을 만든다 — **예외 없이.**
    채울 수 없는 필드를 남기면 그 사실이 조용하다. 그래서 아예 없앤다."""
    assert list(svc.SelectTool.output_fields) == ["action"]


def test_the_input_fields_are_unchanged():
    """음성 대조: 입력 셋은 그대로여야 한다 — `tools` 가 빠지면 native FC 가 안 선다."""
    assert set(svc.SelectTool.input_fields) == {"state", "tools", "valid_actions"}


def test_native_fc_still_fires_on_the_reduced_signature():
    """출력 필드를 줄여도 네 조건이 그대로 서는지 — 배선이 아니라 발화를 잰다."""
    assert svc.native_fc_active(svc.SelectTool) is True
```

- [ ] **Step 2: 실패 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_native_fc_active.py -q -k "exactly_one_output or input_fields_are_unchanged or still_fires_on_the_reduced"`
Expected: 첫 시험 FAIL — `['reasoning','expressible','action','macro','ranking','margin'] != ['action']`

- [ ] **Step 3: 구현한다** — `SelectTool` 본문을 다음으로 바꾼다

```python
class SelectTool(dspy.Signature):
    __doc__ = SEED_DOC
    state: str = dspy.InputField(desc="decision-time observation of the OOD event")
    # 🔴 이 필드가 native FC 의 스위치다 (spec §2-4 조건 2). 없으면 dspy 가 ValueError.
    tools: List[dspy.Tool] = dspy.InputField(desc="the recovery tools available here")
    valid_actions: str = dspy.InputField(desc="ONLY these macros are legal for this event")

    # 🔴 유일한 출력 필드다 (2026-08-29, 단일 채널). `reasoning`·`expressible`·`macro`·
    #    `ranking`·`margin` 다섯 텍스트 OutputField 를 여기서 **삭제했다.**
    #    이유: `tool_choice="required"` 판에서 프로바이더가 message content 를 비우고,
    #    `adapters/base.py:168` 이 `value = ... if text and ... else {}`, `:181` 이
    #    `value.setdefault(field_name, None)` 을 하므로 **예외 없이** 전 필드가 `None` 이 된다
    #    (실측: 그 응답 모양을 어댑터에 직접 흘려 재현). 채울 수 없는 필드를 남기면 조용하다.
    #    결정 성분은 `tool_registry.COMMON_ARGS` 가 tool 인자로 나른다.
    action: dspy.ToolCalls = dspy.OutputField()
```

`_FC_IN` 줄도 바꾼다 — `_EXPR` 는 더 이상 시그니처 필드가 아니다:

```python
# 🔴 이 두 이름은 `SelectTool` 의 필드명과 **같아야 한다.** `Signature.delete` 는 없는 이름에
#    에러를 내지 않으므로(`dspy/signatures/signature.py:446`, `fields.pop(name, None)`), 갈리면
#    축약이 조용히 아무것도 안 지운다.
#    🔴 2026-08-29: `_EXPR` 를 없앴다 — `expressible` 은 이제 시그니처 필드가 아니라 tool
#    인자다. 남겨 두면 `delete(_EXPR)` 가 조용히 no-op 이 되어 "지웠다" 는 거짓을 만든다.
_FC_IN, _FC_OUT = "tools", "action"
```

- [ ] **Step 4: 통과 확인 + 무엇이 깨졌는지 본다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ -q`
Expected: 새 시험 3개 PASS. **실측 결과 `124 passed / 48 failed`** (`test_macro_returns_tool_call.py` 19 · `test_tool_choice_forced.py` 28 · `test_synthesize.py` 1). 47개가 `NameError: name '_EXPR' is not defined`(`dspy_service.py:1273`), 1개가 `AttributeError: module 'dspy_service' has no attribute '_EXPR'`. **그중 22개는 `_EXPR` 랜드마인일 뿐이고 정보가 있는 것은 26개다** — 목록은 `.superpowers/sdd/.../task-3-report.md` §8. 원문: — 그것들은 텍스트 채널을 전제한다. 깨진 목록을 적어 두고 **T4 에서 함께 고친다**(지금 고치지 않는다: 조립 로직이 아직 안 바뀌었다).

- [ ] **Step 5: 커밋** — 깨진 시험이 있으므로 `--no-verify` 없이, 깨진 사실을 메시지에 적는다

```bash
git add src/respec/llm_service/dspy_service.py src/respec/llm_service/test_native_fc_active.py
git commit -m "T3: 시그니처를 action 하나로 줄인다 (텍스트 채널 삭제)

강제 하에서 채울 수 없는 필드를 남기지 않는다. text_rescue 를 전제한 시험들이
빨간 상태로 남는다 — T4 가 조립 로직과 함께 고친다."
```

---

# Task 4: `macro()` 단일 채널 조립

> ✅ **완료 (2026-08-29): `7d525078`. 168 passed / 0 failed. 소요 약 70분(추정 90~120분).**
> 보고서: `.superpowers/sdd/2026-08-29-single-channel-tool-lane-plan/task-4-report.md`.
> **아래 Step 3 의 코드를 다시 쓸 일이 있으면 그 보고서 §1 이 진실원이다** — 계획서 코드와
> 갈린 자리가 여섯이고 전부 실측 근거가 있다(§0-B ⑪). 특히:
> 1. `except Exception` + `error=err` 는 **쓰지 않았다** — `AdapterParseError` 를 따로 받아
>    `tool_lane_error` 로 보고한다(§5-1). 예외 **타입**으로 가르지 메시지 문자열로 안 가른다.
> 2. Step 3 의 반환 dict 에 `tool_minted` 가 빠져 있다 — 그대로 쓰면 `/decide` 가 죽는다.
> 3. Step 1 의 시험 코드는 `agent` 리터럴과 `fc=True` 둘 다 이 harness 에서 틀리다.
> 4. `said = ... if tool_arg_error is None else None` 가드는 **지웠다**(음성 대조 M6).
> 5. 이 태스크가 남긴 빨간 것: `test/tool_lane_keys_survive.jl` (6)절 2개 — T6 이 닫는다.
>
> 🔴 **착수 전 필독 — T1~T3 실행이 이 태스크의 전제 넷을 바꿨다(§0-B 전문).**
> 1. **성공 기준은 "48이 초록" 이 아니라 "그 26개가 초록" 이다.** 22개는 `_EXPR` 참조를 지우는
>    것만으로 조립이 맞든 틀리든 초록이 된다. 목록:
>    `.superpowers/sdd/2026-08-29-single-channel-tool-lane-plan/task-3-report.md` §8. (§0-B ⑨)
> 2. 🔴 **아래 Step 3 의 `except Exception` + `error=err` 는 그대로 쓰면 안 된다.**
>    F14 의 "구제가 무의미하다" 는 판단이 반증됐다 — `dspy/adapters/base.py:171-176` 이 텍스트도
>    tool_calls 도 없으면 **시그니처와 무관하게** `AdapterParseError("The LM returned an empty or
>    null response.")` 를 던지고, native FC 판에서 그것이 도달하는 유일한 방아쇠가 **§5-1 의
>    `no_call` 사건**이다. 그런데 §5-1 은 그 사건에 **`error` 를 채우지 말라**고 못박는다(장애와
>    계약 위반을 가르는 것이 그 키의 이유다). 빈 응답 `AdapterParseError` 를 진짜 `LMError` 와
>    **갈라서** 처리할 것. (§0-B ③)
> 3. `check_tool_args` 를 **맨입력으로 불러도 된다** — T2 가 총함수로 만들었다(예외 대신 사유
>    문자열). 단 `valid=7` 같은 truthy-오타입은 아직 던진다. 그리고 **"접지 성공률" 을
>    `tool_arg_error is None` 으로 세지 말 것**: 규약대로 만들어진 `no_intervention` 도 `None` 이다
>    (§0-B ⑤).
> 4. `_GROUNDING_ARGS`(2키) 와 `check_tool_args` 의 `want`(5키)는 **서로 다른 기준집합**이다.
>    한 게이트로 읽지 않도록 `_GROUNDING_ARGS` 옆에 한 줄 적을 것 (§0-B ⑥).
> 5. F9 는 장래 위험이 아니라 **지금 발화 중**이다 — 이 태스크가 그걸 끄는 태스크다 (§0-B ①).

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py` — `macro()` 의 `:1233-1260`(text_rescue 절, **삭제**), `:1126-1160`(§4-1 구제, **삭제**), `:1270-1345`(조립·반환 dict)
- Test: `src/respec/llm_service/test_macro_returns_tool_call.py`, `test_tool_choice_forced.py`

**Interfaces:**
- Consumes: T1 `TOOL_TO_MACRO`·`COMMON_ARGS`, T2 `check_tool_args`, T3 축소된 `SelectTool`
- Produces: `/macro` 응답 dict — `chosen` · `decision_source`(`"tool"`|`"no_tools"`|`"no_call"`) · `tool_arg_error` · `margin=None`. `text_rescue` 키는 **사라진다**.

**닫는 실패:** F5, F7, F8, F9, F13, F14, F15

- [ ] **Step 1: 실패하는 시험을 쓴다** — `test_macro_returns_tool_call.py` 끝에

```python
# ---- 2026-08-29 단일 채널 ---------------------------------------------------------------------
def _call(name="swap_body", **argkw):
    """tool 호출 하나를 낸 가짜 예측. 인자는 기본 완전형이고 kw 로 덮는다."""
    args = {"agent": "RobotID(DeliveryBot)(1)", "macro": "Replace", "reasoning": "r",
            "expressible": True, "ranking": "Replace, SwapBattery, NOOP"}
    args.update(argkw)
    return {"action": {"tool_calls": [{"name": name, "args": args}]}}


def test_chosen_comes_from_the_tool_name_not_from_any_text_field():
    """🔴 F5. `enact_target` 이 읽는 것은 `tool_called` 다. `chosen` 을 같은 값에서 유도해야
    집행과 채점이 갈릴 수 없다 — 실측에서 그 둘이 3/3 갈렸다."""
    _install(_call("deliver_battery", macro="SwapBattery"), fc=True)
    out = svc.macro(_req())
    assert out["tool_called"] == "deliver_battery"
    assert out["chosen"] == "SwapBattery" == svc.TOOL_TO_MACRO["deliver_battery"]
    assert out["decision_source"] == "tool"


def test_a_disagreeing_macro_arg_does_not_move_the_decision():
    """🔴 F5 의 핵심. macro 인자가 어긋나도 **집행이 이긴다.** 어긋난 사실은 기록만 된다."""
    _install(_call("deliver_battery", macro="Replace"), fc=True)
    out = svc.macro(_req())
    assert out["chosen"] == "SwapBattery", "tool 이 결정이다"
    assert out["macro_tool_agree"] is False, "어긋남은 기록된다"


def test_tool_args_carries_only_the_grounding_arg():
    """🔴 F9 — 이 계획에서 가장 위험한 자리. 줄리아 `TOOL_PARAM_SCHEMA`(llm_bridge.jl:148-151)
    는 `agent`/`reason` 둘만 선언한다. 공통 인자가 새면 `ground_tool_args` 가
    `reject:off_schema_param` 을 내고 **집행이 전 사건에서 정지한다.**"""
    _install(_call(), fc=True)
    out = svc.macro(_req())
    assert set(out["tool_args"]) == {"agent"}, \
        "공통 인자가 tool_args 로 새면 줄리아 집행이 멈춘다"


def test_the_python_and_julia_param_schemas_agree():
    """🔴 F9 교차 게이트. 두 표를 집합 등식으로 묶는다 — 한쪽만 늘리면 여기서 죽는다.

    🔴 이 게이트는 `_GROUNDING_ARGS`(2키) ↔ 줄리아 `TOOL_PARAM_SCHEMA` 만 묶는다. **`build_tools()`
    가 내는 JSON 스키마(5키) ↔ 줄리아 축은 아무도 안 지킨다** — 그걸 지킨다고 주장하는
    `test/tool_args_grounding.jl` 은 파이썬 **함수 시그니처**를 읽어서 이 축에 눈이 멀었고,
    T1 이 인자 넷을 더했을 때 145/145 초록이었다(실측, §0-B ②). 재조준은 T6 몫이다."""
    import re, pathlib
    src = pathlib.Path(__file__).resolve().parents[2] / "respec" / "llm_bridge.jl"
    text = src.read_text(encoding="utf-8")
    block = text[text.index("const TOOL_PARAM_SCHEMA"):]
    block = block[:block.index("\n\n")]
    julia = {m[0]: set(m[1].split()) for m in
             [(a, " ".join(re.findall(r'"(\w+)"\s*=>\s*(?:true|false)', b)))
              for a, b in re.findall(r'"(\w+)"\s*=>\s*Dict\{String,Bool\}\((.*?)\)', block)]}
    for name in reg.MACRO_TO_TOOL.values():
        want = {"agent"} if reg._needs_agent(name) else {"reason"}
        assert julia[name] == want, "%s: julia=%s python=%s" % (name, julia[name], want)


def test_margin_key_survives_as_none():
    """키가 사라지면 소비자가 '레인이 안 돌았다' 와 '값이 없다' 를 못 가른다."""
    _install(_call(), fc=True)
    out = svc.macro(_req())
    assert "margin" in out and out["margin"] is None


def test_text_rescue_key_is_gone():
    _install(_call(), fc=True)
    assert "text_rescue" not in svc.macro(_req())


def test_r26_suppresses_enactment_but_keeps_the_decision():
    """🔴 F7. R26 은 `tool_called` 를 지우지만 `chosen` 은 억제 **전** 이름에서 나온다 —
    규약이 '기록은 하되 집행에는 안 넘긴다' 이지 '결정을 지운다' 가 아니다."""
    _install(_call("no_intervention", macro="NOOP", expressible=False,
                   agent=None, reason="menu cannot fix this"), fc=True)
    out = svc.macro(_req())
    assert out["tool_called"] is None, "집행에 안 넘긴다"
    assert out["tool_called_forced"] == "no_intervention", "기록은 남는다"
    assert out["chosen"] == "NOOP", "결정은 살아 있다"
    assert out["tool_calls_n"] == 1, "F8 — 메뉴 거절(0)과 가르는 판별키다"
    assert out["expressible"] is False, "T2 합성의 방아쇠"


def test_a_forced_regime_with_no_call_is_named():
    """🔴 F15. `required` 인데 호출이 없다 = 계약 위반. `error` 와 가려야 한다."""
    _install({"action": {"tool_calls": []}}, fc=True)
    out = svc.macro(_req())
    assert out["decision_source"] == "no_call"
    assert out["chosen"] == ""
    assert out["error"] is None, "프로바이더 장애가 아니다 — error 를 쓰면 두 사건이 섞인다"


def test_an_empty_menu_never_calls_the_lm():
    """🔴 F2 의 짝. tool 이 0개면 결정을 받을 채널이 없다 — 부를 이유가 없고 과금만 한다."""
    before = svc._state["calls"]
    out = svc.macro(_req(agents=[], valid=["Replace"]))   # agent 없는 Replace -> tool 0개
    assert out["decision_source"] == "no_tools"
    assert out["tools_offered"] == 0
    assert svc._state["calls"] == before, "LM 을 부르면 안 된다"


def test_bad_tool_args_are_reported_not_enacted():
    """🔴 F10·F12. 접지 실패는 집행에 안 넘기되 **사유를 남긴다.**"""
    _install(_call(agent="RobotID(GhostBot)(9)"), fc=True)
    out = svc.macro(_req())
    assert out["tool_arg_error"] is not None and "agent" in out["tool_arg_error"]
    assert out["tool_called"] is None, "접지 안 된 호출을 집행에 넘기지 않는다"
    assert out["tool_calls_n"] == 1, "호출은 왔다는 사실은 남는다"
```

- [ ] **Step 2: 실패 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_macro_returns_tool_call.py -q`
Expected: 새 시험 전부 FAIL

- [ ] **Step 3: 구현한다** — `macro()` 를 다음 형태로 재작성한다

```python
@app.post("/macro")
def macro(req: MacroRequest):
    valid = _valid_for(req)
    prog = _state["program"] or _load_program()
    line = _llm_input(req)
    agent_ids = [a["id"] for a in (getattr(req, "agents", None) or []) if a.get("id")]
    tools = build_tools(getattr(req, "agents", None), valid)

    # ---- F2 · 5-2: 메뉴가 비면 LM 을 안 부른다 ---------------------------------------------
    # 🔴 단일 채널에서는 tool 이 0개면 결정을 받을 채널이 **아예 없다**(출력 필드가 `action`
    #    하나뿐이다). 예전의 C8 축약(텍스트로 묻기)은 이 설계에 존재하지 않는다.
    #    그리고 tool 0개 + `tool_choice` 는 프로바이더 400 이다
    #    (`clients/openai_format.py:81-83` 이 둘을 무관하게 싣는다 — 실측).
    if not tools:
        return _blank_decision(valid, line, "no_tools", tools_offered=0)

    sig = prog.signature
    native_fc = native_fc_active(sig)
    tool_choice_sent = tool_choice(req)
    pred, err = None, None
    try:
        pred = _ask(prog, sig, line, valid, tools, tool_choice_sent)
    except Exception as e:
        # 🔴 F14. §4-1 의 `AdapterParseError` 구제는 이 설계에서 **뺄 것이 없다** — 텍스트
        #    필드가 없으므로 "tool 필드를 뺀 시그니처로 다시 묻기" 가 성립하지 않는다.
        #    그래서 파싱 실패도 장애도 똑같이 `error` 로 보고한다.
        err = "%s: %s" % (type(e).__name__, e)

    if pred is None:
        d = _blank_decision(valid, line, "no_call", tools_offered=len(tools))
        d.update(error=err, native_fc=native_fc, tool_choice=tool_choice_sent)
        return d

    tool_called, tool_args_all, n_calls = _first_tool_call(getattr(pred, _FC_OUT, None))
    if tool_called is None:
        # 🔴 F15. `required` 를 걸었는데 호출이 없다 = 프로바이더 계약 위반.
        #    `error` 에 넣지 않는다 — 장애와 계약 위반은 다른 사건이고 가려져야 한다.
        d = _blank_decision(valid, line, "no_call", tools_offered=len(tools))
        d.update(native_fc=native_fc, tool_choice=tool_choice_sent, tool_calls_n=n_calls)
        return d

    # ---- F10 · F12 · F13: 인자 접지 -----------------------------------------------------
    tool_arg_error = check_tool_args(tool_called, tool_args_all, valid, agent_ids)
    said = tool_args_all.get("macro") if tool_arg_error is None else None
    expressible = tool_args_all.get("expressible")
    expressible = expressible if isinstance(expressible, bool) else None
    reasoning = (tool_args_all.get("reasoning") or "").strip()
    raw_rank = (tool_args_all.get("ranking") or "").strip()

    # 🔴 F9. `tool_args` 에는 **고유 인자만.** 줄리아 `TOOL_PARAM_SCHEMA` 가 `agent`/`reason`
    #    둘만 선언하므로, 공통 인자가 새면 `ground_tool_args` 가 `reject:off_schema_param` 을
    #    내고 집행이 전 사건에서 멈춘다. 교차 게이트가 이 집합 등식을 지킨다.
    tool_args = {k: v for k, v in tool_args_all.items() if k in _GROUNDING_ARGS}

    # 🔴 F5 · F7. 결정은 tool **이름**에서 나온다 — R26 억제 **전** 이름이다.
    #    억제는 집행을 막는 것이지 결정을 지우는 것이 아니다(R26 규약).
    chosen = TOOL_TO_MACRO.get(tool_called, "")
    coerced = chosen not in valid
    if coerced:
        chosen = "NOOP" if "NOOP" in valid else valid[0]

    # 🔴 F8. 일치 판정은 억제 전 이름으로 잰다. 그리고 `n_calls` 는 **절대 0 으로 안 덮는다** —
    #    R26 행(`tool_called is None` & `n>0`)과 메뉴 거절(`n==0`)을 가르는 유일한 키다.
    expected_tool = MACRO_TO_TOOL.get(said)
    called_said = tool_called

    # ---- R26 + 접지 실패: 집행에서 뺀다 ---------------------------------------------------
    tool_called_forced, tool_args_forced = None, {}
    if (expressible is False or tool_arg_error is not None) and tool_called is not None:
        tool_called_forced, tool_args_forced = tool_called, tool_args
        tool_called, tool_args = None, {}

    ranking = [m for m in (s.strip() for s in raw_rank.split(",")) if m in valid]
    for m in valid:
        if m not in ranking:
            ranking.append(m)

    synthesis = maybe_synthesize(expressible=expressible, kind=req.kind, state=line,
                                 tools=tools)
    return {"policy": "dspy:%s" % MODEL, "chosen": chosen, "ranking": ranking,
            # 🔴 `margin` 은 이 설계가 없앴다(spec §3-3). **키는 남기고 값은 안 채운다** —
            #    키가 사라지면 소비자가 "레인이 안 돌았다" 와 "값이 없다" 를 못 가른다.
            #    그 내용은 `reasoning` 이 산문으로 나른다.
            "margin": None, "reasoning": reasoning, "valid": valid,
            "coerced": coerced, "state": line, "llm_calls": _state["calls"], "error": err,
            "decision_source": "tool",
            "tool_called": tool_called, "tool_args": tool_args,
            "tool_called_forced": tool_called_forced, "tool_args_forced": tool_args_forced,
            "tool_calls_n": n_calls, "tools_offered": len(tools),
            "tool_arg_error": tool_arg_error,
            "expressible": expressible,
            "macro_tool_agree": (None if (called_said is None or expected_tool is None)
                                 else called_said == expected_tool),
            "native_fc": native_fc, "tool_choice": tool_choice_sent,
            "synthesis": synthesis}
```

그리고 헬퍼 둘을 `macro()` **위**에 둔다:

```python
# 🔴 줄리아 `TOOL_PARAM_SCHEMA`(`src/respec/llm_bridge.jl:148-151`)가 선언하는 인자 이름 전부.
#    `tool_args` 로 나가는 것은 **이 집합뿐이다** — 공통 인자가 섞이면 `ground_tool_args` 가
#    `reject:off_schema_param` 을 내고 집행이 전 사건에서 멈춘다(F9).
#    교차 게이트: test_macro_returns_tool_call.py::test_the_python_and_julia_param_schemas_agree
_GROUNDING_ARGS = frozenset(("agent", "reason"))


def _blank_decision(valid, line, source, tools_offered):
    """결정을 못 낸 사건의 응답. `error` 는 **비운다** — 장애가 아니다.

    🔴 `chosen=""` 이면 `policy.jl:1301` 의 `policy_entry` 가 `available=false` 로 떨어뜨려
    canonical 폴백이 선다. 그 경로는 이미 있고, 여기서 하는 일은 **왜 그렇게 됐는지**를
    `decision_source` 로 남기는 것뿐이다.
    """
    return {"policy": "dspy:%s" % MODEL, "chosen": "", "ranking": list(valid),
            "margin": None, "reasoning": "", "valid": valid, "coerced": False,
            "state": line, "llm_calls": _state["calls"], "error": None,
            "decision_source": source,
            "tool_called": None, "tool_args": {},
            "tool_called_forced": None, "tool_args_forced": {},
            "tool_calls_n": 0, "tools_offered": tools_offered, "tool_arg_error": None,
            "expressible": None, "macro_tool_agree": None,
            "native_fc": None, "tool_choice": None,
            "synthesis": maybe_synthesize(expressible=None, kind=None, state=line)}
```

`dspy_service.py` 상단 import 에 `TOOL_TO_MACRO` · `check_tool_args` 를 더한다.

- [ ] **Step 4: 통과 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_macro_returns_tool_call.py -q`
Expected: PASS

- [ ] **Step 5: T3 이 깨뜨린 시험들을 정리한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ -q`
텍스트 채널·`text_rescue`·§4-1 구제를 전제한 시험은 **삭제한다**(고치지 않는다 — 그 동작이 사라졌다). `test_tool_choice_forced.py` 의 (6) 절 전체가 여기 해당한다. 삭제한 각 시험마다 파일 상단 주석에 **무엇이 왜 사라졌는지** 한 줄씩 남긴다.

- [ ] **Step 6: 커밋**

```bash
git add src/respec/llm_service/dspy_service.py \
        src/respec/llm_service/test_macro_returns_tool_call.py \
        src/respec/llm_service/test_tool_choice_forced.py
git commit -m "T4: 단일 채널 조립 — chosen 이 tool 이름에서 나오고, 실패마다 이름이 붙는다"
```

---

# Task 5: 요청 손잡이 — 강제 고정 · 다중 호출 차단

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py` — `build_adapter()` `:227-233`, `TOOL_CHOICE_DEFAULT` `:1007`
- Test: `src/respec/llm_service/test_tool_choice_forced.py`, `test_native_fc_wired.py`

**Interfaces:**
- Consumes: T4 의 `macro()`
- Produces: `build_adapter()` 가 `parallel_tool_calls=False` 를 단 어댑터를 낸다. `TOOL_CHOICE_DEFAULT = "required"`.

**닫는 실패:** F2, F3, F11 — spec §3-6 · §4-3

- [ ] **Step 1: 실패하는 시험을 쓴다**

```python
def test_the_default_is_required(monkeypatch):
    """🔴 F3. 강제 없이는 호출이 0/3 이었다(실측). 프롬프트·필드 제거·행위자 프레이밍
    전부 0/3 — 프롬프트로 대체 불가능하다."""
    monkeypatch.delenv(svc.TOOL_CHOICE_ENV, raising=False)
    assert svc.TOOL_CHOICE_DEFAULT == "required"
    assert svc.tool_choice(_req(tool_choice=None)) == "required"


def test_the_env_knob_can_still_turn_it_off(monkeypatch):
    """음성 대조: 되돌려 재는 길이 막히면 안 된다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "")
    assert svc.tool_choice(_req(tool_choice=None)) is None


def test_parallel_tool_calls_is_disabled_at_the_source():
    """🔴 F11. 예전에는 여러 호출이 오면 첫 번째만 쓰고 나머지를 버렸다(기록만 함).
    프로바이더에게 애초에 하나만 내라고 말할 수 있다 — 실측: 이 플래그가 lm_kwargs 에 실린다."""
    assert svc.build_adapter().parallel_tool_calls is False


def test_the_flag_reaches_the_provider_request():
    """배선이 아니라 도달을 잰다."""
    class _LM:
        supports_function_calling = True
        model = "openai/gpt-4o"
    kw = {}
    tools = svc.build_tools([{"id": "r1", "label": "a"}], ["Replace", "SwapBattery", "NOOP"])
    svc.build_adapter()._call_preprocess(
        _LM(), kw, svc.SelectTool,
        {"tools": tools, "state": "s", "valid_actions": "Replace, SwapBattery, NOOP"})
    assert kw["parallel_tool_calls"] is False
```

- [ ] **Step 2: 실패 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_choice_forced.py -q -k "default_is_required or parallel_tool_calls or reaches_the_provider_request or still_turn_it_off"`
Expected: FAIL

- [ ] **Step 3: 구현한다**

```python
def build_adapter():
    """native FC 를 켜고 **다중 호출을 원천 차단한** 어댑터.

    🔴 `parallel_tool_calls=False` (2026-08-29, F11). 이 레인의 결정은 사건당 행동 **하나**다.
    예전에는 여럿 오면 `_first_tool_call` 이 첫 번째만 쓰고 나머지를 버렸다 — 버린 사실을
    `tool_calls_n` 에 남기긴 했지만, 애초에 안 오게 하는 편이 낫다.
    실측: 이 플래그가 `adapters/base.py:118-119` 를 지나 `lm_kwargs["parallel_tool_calls"]`
    로 실린다(`None` 이면 키 자체를 안 보낸다).
    ⚠️ `tool_calls_n` 은 **그대로 잰다.** 이 플래그가 프로바이더에서 안 지켜질 수 있고,
    그때 조용해지면 안 된다 — 그리고 그 값은 F8 의 판별키이기도 하다.

    ⚠️ 어댑터 **클래스**는 일부러 못박지 않는다(`JSONAdapter` 는 `ChatAdapter` 의 자식이고
    플래그를 그대로 물려받는다). 우리가 주장하는 것은 네 조건이지 클래스가 아니다.
    """
    return dspy.ChatAdapter(use_native_function_calling=True, parallel_tool_calls=False)
```

```python
# 🔴 2026-08-29 (단일 채널): `None` 이었다. **강제가 기본이다.**
#    근거(실측): 강제 없이 tool 호출률이 0/3 이었고, 프롬프트에 호출 지시를 넣어도, 텍스트
#    출력 필드를 전부 없애도, 행위자 프레이밍을 지시문 맨 앞에 놔도 전부 0/3 이었다.
#    양성 대조(산술 과제)는 tool 3개에도 부른다 — 배선이 아니라 **과제의 성질**이다.
#    그리고 강제가 예전에 텍스트 채널을 죽이던 인과는 이 설계에서 끊겼다(텍스트 필드가 없다).
TOOL_CHOICE_DEFAULT = "required"
```

- [ ] **Step 4: 통과 확인**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ -q`
Expected: 전부 PASS

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/dspy_service.py src/respec/llm_service/test_tool_choice_forced.py
git commit -m "T5: required 를 기본으로, 다중 호출을 원천 차단한다"
```

---

# Task 6: 줄리아 배선

> 🔴 **이 태스크에 일이 하나 늘었다(§0-B ②).** `test/tool_args_grounding.jl` 의 `_PY_EXTRACT`
> (`:153-159`)가 `inspect.signature(_FUNCS[name])` 를 읽는다 — **파이썬 함수 시그니처**이지
> `build_tools()` 가 내는 JSON 스키마가 아니다. 그래서 T1 이 tool 마다 인자 넷을 더했는데도
> **145/145 초록**이었고, 그 파일 docstring 의 "두 어휘를 묶는다" 는 주장은 이 축에 대해 거짓이다.
> 재조준(스키마 키 집합에 묶기)하거나, 못 묶는다면 **docstring 이 안 지키는 것을 명시**할 것.
> 음성 대조 없이 초록인 게이트는 이 레포가 반복해 밟은 실패 모드다.
>
> ⚠️ 그리고 `test/tool_lane_keys_survive.jl` 을 **레인 건강의 증거로 인용하지 말 것** — 그것은
> `dspy_service.py` **소스**를 읽고 요청을 0건 보낸다. T3 이후 `macro()` 가 매 호출 `NameError` 로
> 죽는 동안에도 초록이었다(§0-B ⑦).

**Files:**
- Modify: `tools/monitor/policy.jl` — `TOOL_LANE_KEYS` `:1149-1161`, `service_decide` 의 `tool_choice` 인자 `:591`·`:661`, `route` 호출부 `:1416`
- Test: `test/tool_choice_gate.jl`

**Interfaces:**
- Consumes: T4 의 응답 dict
- Produces: `TOOL_LANE_KEYS` 가 `decision_source` · `tool_arg_error` 를 나르고 `text_rescue` 를 뺀다.

- [ ] **Step 1: 실패하는 시험을 쓴다** — `test/tool_choice_gate.jl` 끝에

```julia
@testset "단일 채널 키" begin
    # 🔴 `text_rescue` 는 사라졌다 — 그 동작(2차 호출)이 이 설계에 없다.
    @test !("text_rescue" in TOOL_LANE_KEYS)
    # 🔴 세대 표식이자 실패 사건의 이름.
    @test "decision_source" in TOOL_LANE_KEYS
    @test "tool_arg_error" in TOOL_LANE_KEYS

    # 폴백 dict 도 같은 키 집합을 낸다 — 키가 사라지면 "레인이 안 돌았다" 와 "값이 없다" 를
    # 못 가른다.
    local blank = tool_lane_fields(nothing)
    @test Set(String.(keys(blank))) == Set(TOOL_LANE_KEYS)

    # 실측 응답 모양이 그대로 통과한다.
    local b = (chosen = "SwapBattery", ranking = ["SwapBattery"], margin = nothing,
               rationale = "clearly better than Replace", decision_source = "tool",
               tool_called = "deliver_battery", tool_args = Dict("agent" => "r1"),
               tool_calls_n = 1, tools_offered = 3, expressible = true,
               native_fc = true, tool_lane_error = nothing, macro_tool_agree = true,
               tool_choice = "required", tool_arg_error = nothing)
    local e = policy_entry(b, "dspy")
    @test e["available"] === true
    @test e["chosen"] == "SwapBattery"
    @test e["margin"] === nothing          # 🔴 margin 이 없어도 경계가 안 깨진다
    @test e["decision_source"] == "tool"
end
```

- [ ] **Step 2: 실패 확인**

Run: `julia --project=. test/tool_choice_gate.jl`
Expected: FAIL — `decision_source` 가 `TOOL_LANE_KEYS` 에 없다. (⏱ 콜드 컴파일로 3~6분)

- [ ] **Step 3: 구현한다**

`TOOL_LANE_KEYS` 를 바꾼다:

```julia
const TOOL_LANE_KEYS = ("tool_called", "tool_args", "tool_calls_n", "tools_offered",
                        "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                        "tool_choice",
                        # ---- 2026-08-29 (단일 채널) --------------------------------------
                        # `decision_source` = "tool" | "no_tools" | "no_call".
                        #   🔴 **두 실패를 한 값으로 접지 않는다.** `no_tools` 는 우리가 메뉴를
                        #   못 만든 것이고 `no_call` 은 프로바이더가 `required` 계약을 어긴
                        #   것이다 — 원인도 대응도 다르다.
                        #   🔴 이 키의 **존재 자체**가 세대 표식이다: 없는 행은 이 설계
                        #   이전의 것이고, `macro_tool_agree` 와 `expressible` 이 다른 양을
                        #   재고 있으므로 한 표에 섞으면 안 된다.
                        # `tool_arg_error` = 인자 접지 실패 사유(`nothing` 이면 성공).
                        #   집행에서 뺀 이유가 R26(`expressible=false`)인지 접지 실패인지를
                        #   이 키가 가른다 — 둘 다 `tool_called === nothing` 이다.
                        "decision_source", "tool_arg_error")
```

`text_rescue` 를 언급하는 주석 블록을 지우고, `service_decide` 의 `tool_choice` 키워드와 `:661` 의 payload 적재, `:1416` 의 `tool_choice_for(...)` 호출을 **제거한다**. `tool_choice_for` 함수 자체와 그 진리표 시험은 **남긴다**(되돌릴 때 필요하다) — 함수 docstring 에 "2026-08-29 단일 채널 이후 생산 호출자가 0개다" 를 적는다.

- [ ] **Step 4: 통과 확인**

Run: `julia --project=. test/tool_choice_gate.jl`
Expected: PASS (⏱ 3~6분)

- [ ] **Step 5: 커밋**

```bash
git add tools/monitor/policy.jl test/tool_choice_gate.jl
git commit -m "T6: decision_source 를 나르고 text_rescue 를 뺀다"
```

---

# Task 7: 라이브 실측 게이트 + 전체 회귀

> 🔴 **집계 규칙 셋 — 안 지키면 이 게이트가 내는 수치가 틀린다(§0-B ④⑤⑦).**
> 1. **`tool_arg_error` 문자열로 실패 종류를 세지 말 것.** `check_tool_args` 는 처음 걸린 사유
>    하나만 내고 `agent_outside_enum`(F10)이 순서상 마지막이라, 두 군데가 동시에 틀리면 F10 은
>    보고되지 않는다 ⟹ **F10 은 항상 과소집계**. 축마다 따로 셀 것.
> 2. **"접지 성공률" 을 `tool_arg_error is None` 으로 세지 말 것.** 규약대로 만들어진
>    `no_intervention` 호출도 `None` 이다(접지할 것이 없다) — 줄리아는 같은 호출에
>    `deferred:no_groundable_param` 을 낸다. NOOP 을 "접지됨" 분자에 넣으면 두 레인이 같은 이름의
>    비율을 다른 분모로 계산한다.
> 3. **소스를 읽는 게이트 셋의 초록을 레인 건강의 증거로 쓰지 말 것**(§0-B ⑦). 레인이 실제로
>    도는지를 재는 것은 이 태스크의 라이브 게이트뿐이다.
> 4. F6 확인을 **`expressible == False` 비율만으로** 하지 말 것 — 그 비율은 부분적으로 프롬프트
>    준수를 재고, 메뉴가 하나뿐인 사건은 어휘 공백과 무관한 이유로 `False` 를 낸다.
>    `tools_offered` 로 층화할 것.

**Files:**
- Create: `src/respec/llm_service/test_live_single_channel.py`
- Test: 전체

**Interfaces:**
- Consumes: T1~T6 전부
- Produces: 유료 게이트. 기본 skip, `LIVE_LLM=1` 일 때만 돈다.

**닫는 실패:** F6 확인 · F1 회귀

- [ ] **Step 1: 라이브 게이트를 쓴다**

```python
"""유료 게이트 — 기본 skip. `LIVE_LLM=1 .venv/bin/python -m pytest ... -q` 로 돈다.

🔴 왜 별도 파일인가. 이 레포의 다른 시험은 **라이브 LM 을 한 번도 안 부른다**(가짜 LM 으로
kwargs 를 단언한다). 그 규약을 깨지 않으려고 유료 시험을 격리한다. CI 에서 자동으로 돌면 안 된다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)

pytestmark = pytest.mark.skipif(os.environ.get("LIVE_LLM") != "1",
                                reason="유료 호출 — LIVE_LLM=1 일 때만 돈다")

_AGENTS = [{"id": "RobotID(DeliveryBot)(1)", "label": "DeliveryBot 1"}]
_MENU = ["Replace", "SwapBattery", "NOOP"]

_IN_VOCAB = {
    "fault": dict(kind="fault", severity=0.8, spare_count=2, progress=0.35, n_active=6,
                  nl="A transport robot suffered a hardware fault mid-delivery and stopped; "
                     "its payload is still attached and two spare bodies are staged.",
                  descriptors=[0.62, 0.41, 0.30, 0.55, 0.35, 0.22]),
    "battery": dict(kind="battery", severity=0.5, soc=0.12, spare_count=1, progress=0.55,
                    n_active=5,
                    nl="A delivery robot's battery fell to 12% while carrying a payload.",
                    descriptors=[0.30, 0.52, 0.18, 0.44, 0.55, 0.15]),
}
_OUT_OF_VOCAB = {
    "beam-collapse": dict(kind="fault", severity=0.9, spare_count=2, progress=0.4, n_active=6,
        nl="A structural support beam collapsed across the staging area. No robot is damaged "
           "and no battery is low, but the build geometry underneath is now invalid and the "
           "affected assemblies must be re-specified before any transport can resume.",
        descriptors=[0.90, 0.75, 0.55, 0.20, 0.40, 0.05]),
    "comms-loss": dict(kind="fault", severity=0.85, spare_count=3, progress=0.3, n_active=7,
        nl="The fleet lost the shared localization signal. Every robot is healthy and charged, "
           "but none can determine its own pose, so no transport or assembly can proceed.",
        descriptors=[0.82, 0.80, 0.10, 0.15, 0.30, 0.08]),
}


def _decide(ev):
    svc._configure_dspy()
    svc._load_program()
    return svc.macro(svc.MacroRequest(valid=_MENU, agents=_AGENTS, **ev))


@pytest.mark.parametrize("name", sorted(_IN_VOCAB))
def test_a_tool_is_called_and_the_channels_cannot_diverge(name):
    """🔴 F3 · F5. 강제 하에서 호출이 오고, 집행과 채점이 같은 값에서 나온다."""
    out = _decide(_IN_VOCAB[name])
    assert out["decision_source"] == "tool"
    assert out["tool_called"] in svc.TOOL_TO_MACRO
    assert out["chosen"] == svc.TOOL_TO_MACRO[out["tool_called"]]
    assert out["tool_calls_n"] == 1, "F11 — parallel_tool_calls=False"
    assert set(out["tool_args"]) <= {"agent", "reason"}, "F9"
    assert out["tool_arg_error"] is None, "F10/F12"
    assert out["expressible"] is True
    assert out["reasoning"], "margin 을 대신하는 산문이 비면 안 된다"


@pytest.mark.parametrize("name", sorted(_OUT_OF_VOCAB))
def test_out_of_vocabulary_events_report_expressible_false(name):
    """🔴 F6. 옛 문구로는 이 사건들이 `True` 를 냈다(1/3). 개정 문구가 3/3 을 만들었다 —
    T2 합성의 유일한 방아쇠이므로 여기가 조용히 퇴화하면 합성 레인이 영원히 안 돈다."""
    out = _decide(_OUT_OF_VOCAB[name])
    assert out["expressible"] is False
    assert out["tool_called"] is None, "R26 — 강제된 호출은 집행의 근거가 아니다"
    assert out["tool_called_forced"] is not None, "기록은 남는다"
    assert out["tool_calls_n"] > 0, "F8 — 메뉴 거절과 가르는 판별키"
    assert out["chosen"], "F7 — 결정은 살아 있다"
```

- [ ] **Step 2: 라이브 게이트를 돌린다** (⏱ 유료 4콜, 약 2분)

Run: `LIVE_LLM=1 .venv/bin/python -m pytest src/respec/llm_service/test_live_single_channel.py -q`
Expected: 4 passed

- [ ] **Step 3: 파이썬 전체 회귀**

Run: `.venv/bin/python -m pytest src/respec/llm_service/ -q`
Expected: PASS (skip 4). F1 게이트(`test_a_misconfigured_value_dies_loudly...`)가 살아 있는지 확인한다.

- [ ] **Step 4: 줄리아 전체 회귀** (⏱ 약 5분)

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: 기존 baseline + T6 이 더한 만큼. 유일한 error 는 `test/runtests.jl:80` 의 Gurobi 라이선스이고 **변경과 무관하다.**

- [ ] **Step 5: 커밋**

```bash
git add src/respec/llm_service/test_live_single_channel.py
git commit -m "T7: 라이브 게이트 — 실패 목록이 실제로 닫혔는지 유료로 잰다"
```

---

## 자기검토 기록

**spec 커버리지.** §2 시그니처 → T3. §3 스키마·설명 개정 → T1. §3-3 `margin` 제거 → T1·T4. §4-1 매핑 → T4. §4-2 R26/`chosen` → T4. §4-3 강제 고정 → T5. §4-4 `decision_source` 삼상 → T4·T6. §5-1 `no_call` → T4. §5-2 `no_tools` → T4. §5-3 `AdapterParseError` → T4. §6 삭제 목록 → T3·T4·T6.

**spec 을 넘어선 것 둘** (사용자 지시 2026-08-29: *"tool calling 에서 발생할 수 있는 모든 실패 케이스를 제거"*):
- **T2 인자 접지 계층** (F10·F12) — spec 에 없다. 근거는 `dspy.Tool` 에 `strict` 가 없다는 실측.
- **T5 의 `parallel_tool_calls=False`** (F11) — spec 에 없다. 근거는 그 플래그가 `lm_kwargs` 에 실린다는 실측.

✅ **둘 다 spec 에 backfill 했다** (§3-5 인자 접지 계층 · §3-6 다중 호출 원천 차단, 2026-08-29). 계획이 설계를 앞서는 상태를 남기지 않았다.

**타입 일관성.** `check_tool_args(name, args, valid, agent_ids) -> Optional[str]` 는 T2 정의, T4 소비. `TOOL_TO_MACRO: Dict[str,str]` 는 T1 정의, T4·T7 소비. `COMMON_ARGS(valid) -> Dict[str,Any]` 는 T1 정의, T2 소비. `_GROUNDING_ARGS: frozenset` 는 T4 안에서만 산다.
