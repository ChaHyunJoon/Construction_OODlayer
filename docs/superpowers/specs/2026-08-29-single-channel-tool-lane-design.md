# 단일 채널 tool 레인 — 결정과 행동을 한 호출에서 받는다

- 날짜: 2026-08-29
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`, HEAD `5ac07c4d`)
- 상태: 설계 초안. 구현 계획은 별도 문서.
- 이 문서는 자족적이다 — 다른 spec 을 인용하지 않는다.

> **근거 구분 규약.** *실측*은 2026-08-29 에 이 머신에서 gpt-4o 에 실제 유료 호출을 내어 얻은
> 것이거나 설치된 라이브러리를 직접 태워 확인한 것이다. 코드를 읽고 추론한 것은 **추론이라고
> 표시**한다. 이 레포는 정적 추론이 뒤집힌 이력이 많다.

---

## 0. 한 줄 요약

**텍스트 출력 필드를 없애고, 결정의 모든 성분을 tool 호출의 인자로 받는다.** `tool_choice`
는 `"required"` 로 고정한다. 채널이 하나뿐이므로 집행(`tool_called`)과 채점(`chosen`)이
같은 값에서 나오고, 두 채널이 갈리는 사건이 **정의상 존재하지 않는다.**

```
이전 (HEAD 5ac07c4d)                        이 설계
──────────────────────────────              ──────────────────────────
1콜  required → tool call                   1콜  required → tool call
     content 가 빔 → 텍스트 전멸                  ├ agent / reason      (행동)
2콜  tool 없이 텍스트만 다시 물음                   └ macro · reasoning ·
     └ 1콜을 **안 보고** 답함                        expressible ·
                                                    ranking          (결정)
집행 = 1콜의 tool                            집행 = tool_called
채점 = 2콜의 macro          ⟹ 3/3 불일치     채점 = TOOL_TO_MACRO[tool_called]
```

---

## 1. 이 설계가 딛는 실측

전부 2026-08-29 실측이다. 사건 셋(`fault` · `battery` · `fault-severe`)은 같은 것을 계속 쓴다.

### 1-1. 강제 없이는 tool 을 안 부른다 — 프롬프트로 못 고친다

| # | 조건 | tool 수 | 과제 | 호출 |
|---|---|---|---|---|
| A | 현행 HEAD | 3 | 우리 사건 | **0/3** |
| ① | 지시문에 "tool 을 호출해 실행하라" 추가 | 3 | 우리 사건 | **0/3** |
| B | `macro` 출력 필드 제거 | 3 | 우리 사건 | **0/3** |
| D | 텍스트 출력 필드 **전부** 제거 | 3 | 우리 사건 | **0/3** |
| E/F | 행위자 프레이밍을 지시문 **맨 앞**에 | 3 | 우리 사건 | **0/3** |
| P | 양성 대조 (산술) | 1 | 산술 | ✅ |
| Q/R | 산술 + 선택지(`do_nothing` 포함) | 2, 3 | 산술 | ✅ |
| I | 명령형 "로봇 1을 교체하라" + 우리 tools | 3 | 명령 | ✅ |
| K | **우리 state** + `swap_body` 하나 | 1 | 우리 사건 | ✅ |
| L/M/N | 우리 state + 2개 (세 조합 **전부**) | 2 | 우리 사건 | **0/3** |

경계에서 확인(LM 래핑): tool 3개가 실제로 LM 에 도달하고(`['swap_body','deliver_battery',
'no_intervention']`), `tool_choice` 키는 없고, native FC 네 조건이 전부 참이다
(`lm.supports_function_calling=True` · `ChatAdapter` · `use_native_function_calling=True` ·
`native_fc_active(sig)=True`). **배선은 멀쩡하다.**

🔴 판정: 개수 문제가 **아니다**(산술은 tool 3개에도 부른다). *우리 과제 + 선택지가 둘 이상*
일 때만 안 부른다. 모델이 판단 과제로 인식하면 **행동하지 않고 답변한다.** ⟹ 강제는 프롬프트로
대체 불가능하다. `bfb491d8`/`5ac07c4d` 가 `required` 로 간 이유는 실재한다.

### 1-2. 강제의 해악은 강제가 아니라 **두 번째 눈먼 호출**에서 왔다

HEAD 의 `text_rescue` 가 실제로 작동하는지 이번에 **처음 검증했다**(그 전까지는 교정 파일이
없어 경로에 도달 불가였다 — §1-4).

| 사건 | 레짐 | `tool_called` | `chosen` | `expressible` | `macro_tool_agree` | `text_rescue` |
|---|---|---|---|---|---|---|
| fault | 통제 | `None` | SwapBattery | `True` | `None` | `None` |
| fault | 강제 | `no_intervention` | SwapBattery | `True` | 🔴 `False` | `True` |
| battery | 통제 | `None` | SwapBattery | `True` | `None` | `None` |
| battery | 강제 | `no_intervention` | SwapBattery | `True` | 🔴 `False` | `True` |
| fault-severe | 통제 | `None` | SwapBattery | `True` | `None` | `None` |
| fault-severe | 강제 | `deliver_battery` | **Replace** | `True` | 🔴 `False` | `True` |

✅ `text_rescue` 는 회귀를 고쳤다 — `expressible` 3/3 생존, `chosen` 안 깎임(`coerced=False`).
🔴 그러나 **`macro_tool_agree` 가 3/3 `False`** 다. `fault-severe` 가 가장 뚜렷하다: 텍스트는
`Replace`(몸체 교체), 행동은 `deliver_battery`(배터리 배달). `enact_target` 이 읽는 것은
`tool_called` 이므로 **집행은 `deliver_battery`, 채점은 `Replace`** 였다.

원인은 구조다: 1차는 tool 만, 2차는 텍스트만 내고 **두 호출이 서로를 안 본다.** 일관될 이유가
없다.

### 1-3. 단일 채널 프로토타입 — 세 지표가 동시에 선다

버려질 프로토타입(레포 미변경)으로 잰 것이다.

| | HEAD (강제 + `text_rescue`) | 이 설계 |
|---|---|---|
| 호출률 | 3/3 | **3/3** |
| `macro_tool_agree` | 3/3 `False` | **3/3 `True`** |
| `expressible` | `True` (2차 호출로 구제) | `True` (1콜) |
| 집행 vs 채점 | 🔴 갈림 | ✅ 같은 값 |
| LM 호출 수 | 2 | **1** |
| `agent` 접지 | 유지 | 유지 — 스키마 6인자로 늘려도 enum 의 실재 id 정확 |

부수 관측: 사건별 결정이 `fault→Replace` · `battery→SwapBattery` · `fault-severe→Replace` 로
갈렸다. 통제 판에서 **3/3 전부 SwapBattery** 로 쏠렸던 것과 대비된다(유일 통로를 막은 사건에
배터리 배달을 고르던 문제). 이 설계의 **목표가 아니었고**, 사건 셋으로 잰 것이므로 주장이 아니라
관측으로만 적는다.

### 1-4. 라우터는 지금 죽어 있었다

`wm4spacecraft_manufacturing/novelty/novelty_calibration.json` 이 작업 트리에서 삭제돼 있었고
(HEAD 에는 존재), `install_novelty!` 가 fail-open 으로 `false` 를 내어 `novelty_measured=false`
⟹ `tool_choice_for` 가 **모든 사건에 `nothing`** 을 냈다. 즉 `5ac07c4d` 의 게이트는 병합 이후
한 번도 발화한 적이 없다. 복구 후 `[NOVELTY] v2 n_cal=82 alpha=0.05` 로 적재됨을 확인했다.

이 설계는 `tool_choice` 를 **항상** `"required"` 로 두므로 그 게이트를 더는 쓰지 않는다(§4-3).

---

## 2. 시그니처

```python
class EnactTool(dspy.Signature):
    __doc__ = SEED_DOC                       # 변경 없음
    state: str          = dspy.InputField(...)
    tools: List[dspy.Tool] = dspy.InputField(...)
    valid_actions: str  = dspy.InputField(...)
    action: dspy.ToolCalls = dspy.OutputField()      # ← 유일한 출력 필드
```

🔴 `reasoning` · `expressible` · `macro` · `ranking` · `margin` 다섯 `OutputField` 를 **전부
삭제한다.** 이유: `tool_choice="required"` 판에서 프로바이더는 tool 호출만 내고 `message.content`
를 비우며, 그러면 dspy 의 `adapters/base.py:168` 이

```python
value = self.parse(processed_signature, text) if text and processed_signature.output_fields else {}
...
value.setdefault(field_name, None)        # :181
```

로 **예외 없이** 전 필드를 `None` 으로 만든다(실측: 이 응답 모양을 어댑터에 직접 흘려 재현).
남겨두면 채울 수 없는 필드가 되고, 그 사실이 조용하다.

🔴 `SEED_DOC` 은 **안 바꾼다.** 2026-08-29 에 "tool 을 호출해 실행하라" 문단을 넣어 재봤고
호출률이 0/3 그대로였다(§1-1 ①). 효과가 없는 문장을 프롬프트에 남기지 않는다.

---

## 3. Tool 스키마 — 결정 성분이 인자로 들어간다

세 tool 전부가 **공통 인자 넷**을 갖는다. 고유 인자(`agent` enum 또는 `reason`)는 그대로다.

```json
{"agent":       {"type":"string", "enum":["RobotID(DeliveryBot)(1)", ...],
                 "description":"exact robot id, copied verbatim from this parameter's enum list"},
 "macro":       {"type":"string", "enum":["Replace","SwapBattery","NOOP"],
                 "description":"the macro name this call enacts"},
 "reasoning":   {"type":"string",  "description": <§3-3>},
 "expressible": {"type":"boolean", "description": <§3-2>},
 "ranking":     {"type":"string",  "description":"ALL legal macros ordered best-first, comma separated"}}
```

다섯 전부 `required` 다.

### 3-1. `macro` 를 인자로 남기는 이유

`chosen` 은 tool **이름**에서 유도하므로 `macro` 인자는 결정에 안 쓰인다. 그래도 남기는 이유는
`macro_tool_agree` 를 **살려두기 위해서다** — 이제 그것은 *한 호출 안의 자기모순*(같은 JSON 에서
`macro="Replace"` 라고 쓰면서 `deliver_battery` 를 부르는 일)을 잰다. 집행은 tool 이름에서만
나오므로 이 값이 어긋나도 **집행과 채점은 갈릴 수 없다.** 즉 측정을 안 버리고 0 보장이 선다.

### 3-2. `expressible` 설명을 개정한다 — 이것이 T2 의 유일한 방아쇠다

기존 문구(`"false if NO available tool can address what you observed"`)로는 어휘 밖 사건에서
**1/3 만** `False` 가 나왔다. 나머지 둘은 reasoning 에서 *"근본 원인을 못 고친다"* 고 말하면서
`expressible=True` 를 냈다 — 모델이 **"표현 불가"와 "개입 불필요"를 혼동한다.**

개정 문구:

```
false if NOTHING in this tool menu can remove the CAUSE of what you observed --
i.e. you are calling a tool only because you must, not because it fixes anything.
Answering NOOP because intervening is unnecessary is NOT this: that is true.
Set false when the fix this event needs is outside the menu entirely.
```

실측 A/B (같은 사건 · 같은 스키마 · 같은 강제, **설명만** 다르게):

| 사건 | 기존 | 개정 |
|---|---|---|
| beam-collapse (구조물 붕괴 → 재명세 필요) | ✅ `False` | ✅ `False` |
| comms-loss (측위 신호 상실) | 🔴 `True` | ✅ `False` |
| zone-blockage (배제구역이 접근로를 덮음) | 🔴 `True` | ✅ `False` |
| 대조: 진짜 배터리 사건 | ✅ `True` | ✅ `True` |
| **어휘 밖 발화율** | **1/3** | **3/3** |

거짓 양성 없음(대조군 `True` 유지).

⚠️ **대가를 명시한다.** 이 문구는 모델에게 *언제 false 라고 말할지*를 가르친다. 그래서
`expressible == False` 비율은 이제 부분적으로 **프롬프트 준수**를 잰다. 필드 *정의*를 명확히
한 것이지 결정 규칙을 준 것이 아니므로 `dspy_service.py:176-184` 의 금지에는 안 걸리지만,
이 개정 **이전** 행과 이후 행을 한 표에 섞으면 안 된다. 가르는 키는 §4-4 의 `decision_source`
다(그 키가 없는 행이 이전 세대다).

### 3-3. `margin` 은 인자에서 **뺀다** — 그 내용은 `reasoning` 이 산문으로 나른다

`margin` 은 계산값이 아니라 **모델의 자기 신고 스칼라**였고, 무엇과도 대조된 적이 없다. 실측
관측: `fault→0.3` · `battery→0.8` · `fault-severe→0.5`. 서술자상 가장 명백한 사건
(`fault-severe`: harm 0.88, "유일 통로 막힘")이 중간값을 받았다 — 보정된 신호로 읽을 근거가 없다.

⟹ 숫자를 지어내게 하는 대신 **말로 하게 한다.** `reasoning` 의 설명을 다음으로 바꾼다:

```
one sentence: why this action, and how clearly it beats the runner-up --
say that in words (e.g. "clearly better than X" / "only marginally better than X" /
"essentially tied with X"), not as a number.
```

실측 (2026-08-29, 사건 셋, 이 문구 그대로). 인자 키는 `['agent','expressible','macro',
'ranking','reasoning']` 다섯 — `margin` 없음. **3/3 이 비교를 산문에 담았다:**

| 사건 | `reasoning` 안의 비교 절 |
|---|---|
| fault | "…This action is **clearly better than SwapBattery** due to the higher harm and work at risk levels, and NOOP is not an option as the robot is stopped mid-delivery." |
| battery | "SwapBattery is **clearly better than Replace** because it resolves the battery issue without consuming a spare robot, which is a scarce resource. It is also more effective than NOOP…" |
| fault-severe | "**clearly better than SwapBattery and NOOP** because the robot is dead and blocking the corridor…" |

숫자보다 **정보가 많다** — 어느 대안보다 나은지와 그 이유를 함께 말한다(`margin=0.3` 은 둘 다
안 말했다).

⚠️ 두 가지를 적어 둔다. (1) `fault-severe` 의 문장이 `"clearly better than…"` 으로 **시작**해
"why this action" 절이 앞에 없다 — 내용은 다 있으나 문장 조각처럼 읽힌다. (2) 세 사건 모두
`"clearly better"` 였다 — **`"essentially tied"` 단계는 한 번도 안 나왔다.** 등급의 아래쪽은
미검증이다.

얻는 것: 불확실성이 **읽을 수 있는 형태**로 남고, 가짜 정밀도가 사라진다.
잃는 것: 기계가 정렬·임계할 수 있는 스칼라가 없어진다. 🔴 **오늘 그 스칼라를 그렇게 쓰는
소비처는 0개다** — 유일한 소비처가 대시보드 후보표의 표시 문자열이다(아래).

**줄리아 경계는 안 깨진다** (실측 확인 필요 항목 → 구현 T1 게이트):
`policy_entry`(`policy.jl:1307`)가 `"margin" => (try Float64(b.margin) catch; nothing end)` 라
값이 없으면 예외를 삼키고 `nothing` 이 된다. 대시보드(`policy.jl:1671`)는
`pol[enacted]["margin"] !== nothing` 을 먼저 보므로 후보표의 `score` 칸이 **빈 문자열**이 된다.
⚠️ 응답 dict 에서 `margin` **키 자체는 남기고 `None` 을 넣는다** — 키가 사라지면 소비자가
"레인이 안 돌았다" 와 "레인이 돌았는데 값이 없다" 를 못 가른다(이 레포의 반복된 함정).

### 3-4. `ranking` 은 남긴다

`ranking` 은 지어낸 스칼라가 아니라 **실제 순서**이고, 후보표가 그것으로 행을 만든다
(`policy.jl:1664`). 인자 하나 값이므로 스키마 부담도 작다.

🔴 되돌리는 조건: `agent` 인자가 enum 밖 값을 내기 시작하면 **`ranking` 부터 뺀다.** 표시
전용이고 결정·채점에 안 쓰인다(`dspy_service.py:18-21` 이 그 지위를 못박아 뒀다).

⚠️ 참고 — 이 레포에는 `margin` 이라는 이름의 값이 셋 있고 성질이 다르다: dspy 레인(자기 신고,
**이 설계가 없앤다**) · surrogate 레인(`predict_delta_J` 계산) · `CB.decision_margin`(점수
벡터에서 계산). 대시보드는 셋을 구분 없이 찍는다. 이 설계 이후 그 자리에 남는 것은 **계산값
둘뿐**이므로 혼동이 줄지만, 이름 충돌 자체는 안 고친다(§7).

### 3-5. 인자 접지 계층 — 스키마는 강제가 아니다

🔴 **`dspy.Tool` 에는 `strict` 필드가 없다** (실측: `model_fields` =
`arg_desc · arg_types · args · desc · func · has_kwargs · name`). 그리고
`format_as_litellm_function_call()` 의 `parameters` 는 `{properties, required, type}` 뿐이라
`additionalProperties` 도 없다. ⟹ **`enum` 도 `required` 도 프로바이더에게 권고이지 강제가
아니다.** 다음 셋이 실제로 뚫릴 수 있다:

- enum 밖 `agent` id → 존재하지 않는 로봇을 집행에 넘긴다
- `expressible` 누락 → `None` → T2 합성의 방아쇠가 조용히 사라진다
- `expressible` 이 문자열 → `bool("False") is True` 라 **거짓 `True`** 가 기록된다

줄리아의 `ground_tool_args`(`llm_bridge.jl:238`)가 같은 축을 보지만 **집행 직전**이라, 거기
닿을 때는 이미 응답이 기록된 뒤다 — 잘못된 인자가 남으면 그 행을 읽는 사람이 *"모델이 이렇게
답했다"* 로 읽는다. 그래서 서비스가 응답을 만들기 **전에** 검사한다.

`check_tool_args(name, args, valid, agent_ids) -> Optional[str]` — `None` 이면 접지 성공,
문자열이면 거절 사유이고 그 값이 그대로 응답의 `tool_arg_error` 가 된다. 접지에 실패한 호출은
**R26 과 같은 처리를 받는다**: `tool_called` 를 비우되 `tool_called_forced` 에 보관하고
`tool_calls_n` 은 안 덮는다. 두 억제를 가르는 키는 `tool_arg_error` 자체다.

### 3-6. 다중 호출은 원천 차단한다

이 레인의 결정은 사건당 행동 하나다. 예전에는 여럿 오면 `_first_tool_call` 이 첫 번째만 쓰고
나머지를 버렸다(개수만 `tool_calls_n` 에 기록). 프로바이더에게 애초에 하나만 내라고 말할 수 있다:
`dspy.ChatAdapter(use_native_function_calling=True, parallel_tool_calls=False)`.

실측: 그 플래그가 `adapters/base.py:118-119` 를 지나 `lm_kwargs["parallel_tool_calls"] = False`
로 실린다(`None` 이면 키 자체를 안 보낸다).

⚠️ **`tool_calls_n` 은 그대로 잰다.** 플래그가 프로바이더에서 안 지켜질 수 있고 그때 조용해지면
안 된다 — 그리고 그 값은 R26 행과 메뉴 거절을 가르는 판별키이기도 하다(§4-2).

---

## 4. 응답 조립

### 4-1. 매핑

| 응답 키 | 출처 |
|---|---|
| `chosen` | `TOOL_TO_MACRO[tool_called]` — **집행과 같은 값** |
| `rationale` (`reasoning`) | args `reasoning` — 확신 격차를 산문으로 포함한다 (§3-3) |
| `expressible` | args `expressible` |
| `ranking` | args `ranking` 을 콤마로 분해 |
| `margin` | **항상 `None`** — 키는 남기고 값은 안 채운다 (§3-3) |
| `tool_called` · `tool_args` | tool 이름 / 고유 인자(`agent` 또는 `reason`)만 |
| `tool_calls_n` · `tools_offered` | 그대로 |
| `macro_tool_agree` | `MACRO_TO_TOOL[args.macro] == tool_called` |
| `native_fc` · `tool_choice` | 그대로 |
| `text_rescue` | **삭제** |

🔴 `tool_args` 에는 **고유 인자만** 담는다. 공통 넷은 이미 자기 자리(`expressible` 등)로
갔으므로 여기 또 넣으면 같은 값이 두 곳에 살고, `enact_target` 이 읽는 접지 인자와 결정 성분이
한 dict 에 섞인다.

### 4-2. R26 과 `chosen` — 이 설계가 새로 만드는 결정

R26 은 `expressible is False` 인데 강제된 호출이 온 사건에서 `tool_called` 를 `None` 으로
지운다(집행에 안 넘긴다). 그런데 이 설계에서는 `chosen` 이 `tool_called` 에서 나오므로 **같이
사라질 수 있다.**

🔴 **`chosen` 은 억제 *전* 이름에서 유도한다.** 근거: R26 의 규약이 *"기록은 하되 집행에는 안
넘긴다"* 이고, `macro_tool_agree` 도 억제 전 값(`called_said`)을 쓴다. 결정을 지우는 것은 그
규약이 아니다.

실측(beam-collapse):

```
tool call           : no_intervention  (calls_n=1)
expressible         : False
-- R26 적용 후 --
tool_called         : None                ← 집행에 안 넘김
tool_calls_n        : 1                   ← 거절(C8②)과 가르는 판별키. 0 으로 덮지 않는다
tool_called_forced  : 'no_intervention' {'reason': '...not addressed by the available macros.'}
chosen              : 'NOOP'              ← 억제 전 이름에서
T2 발화             : YES
```

### 4-3. `tool_choice` 는 항상 `"required"`

`policy.jl` 의 `tool_choice_for` 게이트는 더 쓰지 않는다 — 그 게이트의 존재 이유가 *"강제하면
`expressible` 이 사라진다"* 였고(§1-2), 이 설계에서 그 인과가 끊긴다.

🔴 **남기는 것**: `DSPY_TOOL_CHOICE` 환경변수 손잡이와 그 값 검증. 되돌려 재는 길이고, 오설정이
레인 전체를 조용히 죽이는 것을 막는다(허용집합 `("auto","required","none")`; `""` 는 "키를 안
보냄"). 이 검증은 이 설계와 무관하게 2026-08-29 에 이미 들어갔다.

### 4-4. 새 키 `decision_source` — **세 값이다**

| 값 | 뜻 |
|---|---|
| `"tool"` | 정상. 호출이 왔고 그 이름이 결정이다 |
| `"no_tools"` | 메뉴가 비었다 — 부를 것이 없었다(C8, §5-2). **LM 을 안 부른다** |
| `"no_call"` | 메뉴가 있고 강제했는데도 호출이 없었다 — 계약 위반(§5-1) |

🔴 **두 실패를 한 값으로 접지 않는다.** `no_tools` 는 우리가 메뉴를 못 만든 것이고 `no_call` 은
프로바이더가 계약을 어긴 것이다 — 원인도 대응도 다르다. 이 레포는 `tools_offered` 의 세 사건과
C8 에서 이미 같은 함정을 밟았다.

이 키의 **존재 자체**가 세대 표식이다: 없는 행은 이 설계 이전의 것이고, `macro_tool_agree` 와
`expressible` 이 다른 양을 재고 있으므로 한 표에 섞으면 안 된다.

---

## 5. 실패 경로

### 5-1. 강제했는데 호출이 없다

`required` 를 걸었으므로 프로바이더 계약상 일어나지 않아야 한다. 그러나 **일어나지 않는다고
가정하지 않는다** — 이 레포가 반복해 데인 자리는 언제나 "일어날 리 없다"고 적어 둔 쪽이었다.

발생 시: `chosen=""` · `decision_source="no_call"` · 나머지 결정 키는 `None`. `policy_entry`
(`policy.jl:1301`)가 빈 `chosen` 을 보고 `available=false` 로 떨어뜨려 canonical 폴백이 선다.
**`error` 에는 아무것도 안 넣는다** — 프로바이더 장애가 아니라 계약 위반이고, 두 사건은 가려져야
한다.

### 5-2. tool 이 0개다 (C8)

`build_tools` 가 `[]` 를 낼 수 있다(실재 로봇 id 가 없으면 agent 를 받는 tool 을 안 낸다).
그때 **`tool_choice` 를 실으면 안 된다** — `clients/openai_format.py:81-83` 이 `tool_choice` 를
`tools` 와 무관하게 싣기 때문에 프로바이더 400 이 된다(실측 확인). 현행 `_ask` 의 `if tools:`
가드를 그대로 유지한다.

🔴 그런데 이 설계에서는 tool 이 0개면 **결정 성분을 받을 채널이 아예 없다.** 출력 필드가
`action` 하나뿐이기 때문이다. ⟹ tool 이 0개인 요청은 `decision_source="no_tools"` 로 즉시 떨어뜨린다
(LM 을 부르지 않는다 — 부를 이유가 없고 과금만 한다).

### 5-3. `AdapterParseError`

tool 인자가 스키마를 어겨 파싱이 깨지는 경우. 현행 §4-1 구제(tool 필드를 뺀 시그니처로 재질의)는
이 설계에서 **의미가 없다** — 뺄 텍스트 필드가 없다. 그러므로 그 구제를 삭제하고, 예외는
`error` 로 보고한다.

---

## 6. 삭제되는 것

- `SelectTool` 의 텍스트 `OutputField` 다섯
- `text_rescue` 감지·2차 호출·삼상 키 전부 (`dspy_service.py:1233-1260` 및 그 시험 절)
- §4-1 `AdapterParseError` 구제 (§5-3)
- `policy.jl` 의 `tool_choice_for` 호출부 (함수와 그 시험은 남긴다 — 되돌릴 때 필요하다)

---

## 7. 이 문서가 안 하는 것

- **`margin` 세 값의 이름 충돌을 안 고친다** (§3-3). 별개 작업이다.
- **어휘를 안 늘린다.** `beam-collapse` · `comms-loss` · `zone-blockage` 는 셋 다 `chosen=NOOP`
  으로 떨어진다 — 그 사건들을 고칠 macro 가 어휘에 없기 때문이다. 그것을 메우는 것이 T2 이고,
  이 설계는 T2 의 **방아쇠를 신뢰할 수 있게** 만들 뿐이다(§3-2).
- **`expressible == False` 의 하류(T2 합성 자체)를 안 바꾼다.** `TOOL_SYNTHESIS=1` 게이트와
  `maybe_synthesize` 는 그대로다.
- **모델을 안 바꾼다.** §1-1 의 결론(`판단 과제면 안 부른다`)이 gpt-4o 고유인지 일반적인지는
  재지 않았다.

---

## 8. 공개된 위험

1. **`expressible` 발화율이 프롬프트 준수와 섞인다** (§3-2). 세대 간 비교 시 `decision_source`
   로 갈라야 한다.
2. **사건 셋으로 잰 것이다.** §1-3 의 3/3 은 표본 3이다. 구현 후 넓은 스윕으로 재확인해야 한다.
3. **`macro_tool_agree` 가 재는 양이 바뀐다** — "두 눈먼 호출의 불일치" → "한 호출 안의
   자기모순". 이전 세대 행과 섞으면 안 된다.
4. **`required` 고정은 매 사건 과금 호출을 보장한다.** 이전에는 강제 판만 2콜, 나머지는 1콜이었다.
   이 설계는 전 사건 1콜이므로 총량은 줄지만, "부르지 않아 싼" 경로가 사라진다.
5. **`margin` 이 사라져 기계가 읽을 확신도 스칼라가 없다** (§3-3). 오늘 그런 소비처는 0개지만,
   나중에 "확신 낮으면 escalate" 같은 규칙을 원하면 **계산된** 양을 새로 정의해야 한다 —
   자기 신고 숫자를 되살리는 것이 아니라.
6. **`no_intervention` 이 `expressible=False` 의 운반체가 된다.** 강제 하에서 "메뉴 밖" 을 말하는
   유일한 방법이 그 tool 을 부르는 것이다. R26 이 그 호출을 집행에서 걸러내지만, `tool_called_forced`
   를 안 읽는 소비자에게는 "개입 안 함" 과 구별되지 않는다. 가르는 키는 `expressible` 자체다.
