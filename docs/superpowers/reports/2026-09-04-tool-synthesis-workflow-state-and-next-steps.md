# Multi-agent OOD → tool generation 워크플로: 현재 상태 · 문제 · 다음 단계

작성 2026-09-04 (HEAD `8d534bf0`). 다음 세션이 이어받으라고 쓴 문서다.

## 0. 이 문서를 읽는 법

이 레포는 **"아무도 재유도하지 않은 주장이 사실로 굳는"** 실패를 반복해서 밟는다.
바로 오늘도 세 번 밟았다(§4). 그래서 이 문서는 두 가지를 지킨다.

1. **측정된 것과 추론한 것을 표기로 가른다.** `[측정]` 은 오늘 실제로 재서 얻은 값이고,
   `[미측정]` 은 코드를 읽어 세운 가설이다. **`[미측정]` 을 근거로 삼지 말고 먼저 재라.**
2. **코드를 가리킬 때 줄번호가 아니라 함수·testset 이름으로 적는다.** (`.claude/CLAUDE.md` 의 규약.
   오늘도 내가 브리프에 인용한 줄번호 넷이 어긋났고 구현자가 실측으로 잡았다.)

수치는 **자릿수 감각용**이다. 회귀 판정에 쓸 값은 **네가 지금 잰 값**이다.

---

## 1. 워크플로 현재 상태

### 1.1 사건에서 집행까지 — 실제 경로

```
시뮬레이션 (render_demo.jl)
  └─ OOD 주입: battery fault @ step≈108              [측정] closed=97 / 305
       └─ 라우터: routing_kind="unknown:battery_mild"
            → surrogate 학습 kinds 밖 → LLM 레인으로 escalate
                 └─ DSPy 서비스 :8077  (TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1)
                      ├─ 결정 agent   → 매크로 선택 (오늘 판: "NOOP R1")
                      └─ 합성 3~4단계 stages=["observe","design","compose"]
                           ObserveEvent → DesignToolSpec → WriteToolImpl
                           (게이트: agent-2 가 expressible=False 를 내야 발화)
                                └─ Julia 경계
                                     ├─ check_impl_conventions      규약 5종
                                     ├─ register_minted_primitive!  Core.eval 로 모듈에 심는다
                                     ├─ impl_interface_calls        L3 계측(거절 안 만든다)
                                     ├─ bind_primitive_args         calls 채널로 인자 바인딩
                                     └─ enact_minted!               body 호출 + world digest
```

**핵심 성질 넷** (설계를 바꾸기 전에 이해해야 하는 것):

- **`expressible=False` 가 합성의 유일한 방아쇠다.** agent-2 가 "기존 어휘로 표현 가능" 이라고
  판단하면 tool 은 아예 안 만들어진다. 단일 agent 레인에서는 이 값이 항상 `True` 였다 —
  **multi-agent 가 필수 조건이다.**
- **D6 은 다섯 능력을 일부러 감춘다.** `release_pending_assignments!` 등이 광고 목록에 없다
  (`test/world_interface_current.jl` 의 감춤 게이트가 못박는다). 모델이 없는 것을 **발명하는지**
  보려는 설계이지 버그가 아니다. §2 의 P3 이 이것과 정면으로 부딪힌다.
- **인터페이스는 산출물 하나가 진실원이다**: `wm4spacecraft_manufacturing/core/world_interface.json`.
  `tools/gen_world_interface.jl` 이 만들고 `test/world_interface_current.jl` 의 **바이트 게이트**가
  산출물==생성기를 지킨다. 파이썬 `world_interface.py` 가 그것을 프롬프트 블록으로 렌더한다.
  🔴 **`returns` 문자열은 손으로 쓰는 게 아니라 `Base.return_types` 로 기계 유도된다** —
  타입 선언을 좁히면 광고가 **저절로** 정확해진다(오늘 그렇게 고쳤다, §3 의 S2).
- **세대 게이트가 모든 런을 막는다.** `require_current_service` 가 서비스의 `code_fingerprint` 를
  `src/respec/llm_service/` **트리 전체** 해시와 대조한다. 엔드포인트를 안 가리므로,
  파이썬을 건드리는 작업이 하나라도 돌면 **tool-off 대조 런까지** 못 돈다.

### 1.2 사다리 — 판정 정본과 오늘의 값

판정 정본: `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` §0.
채점은 **손으로 하지 말고** `tools/monitor/ladder_report.py` 로 한다(§1.3).

| 칸 | 판정 필드 | 런 2 [측정] | 런 3 [측정] |
|---|---|---|---|
| **L0** 코드를 썼다 | `wrote == true` | ✅ | ✅ |
| **L1** 등록됐다 | `registered == true` | ✅ | 🔴 FALSE `reject:impl_keyword_needs_a_default` |
| **L2a** 인자 채널 | `args_from == :calls` | ✅ | UNMEASURED |
| **L2b** 예외 없이 끝났다 | `steps[1].status === :success` | 🔴 FALSE `KeyError: key "R1" not found` | UNMEASURED |
| **L3** 기존 함수를 불렀다 | `interface_calls ≠ []` | ✅ **사상 처음** `['battery_report']` | UNMEASURED |
| **L4** 세계가 바뀌었다 | `world_delta_body` ≠ 0 | **MEASURED-ZERO** (fallback 없음) | UNMEASURED |
| — | 빌드 완주 | ✅ `PROJECT COMPLETE!` | ✅ |

🔴 **L2b 의 술어를 `!== nothing` 으로 되돌리지 말 것.** 옛 술어는 `:threw` 로도 충족돼
**명제가 거짓인데 초록으로 읽혔다**. 2026-09-04 사전등록 결정 20 이 `=== :success` 로 고쳤다.

### 1.3 오늘 생긴 계측 인프라 — 다음 세션이 그대로 쓸 것

| 도구 | 무엇 | 왜 중요 |
|---|---|---|
| `tools/monitor/ladder_report.py` (+ `test_ladder_report.py`) | 런 산출물에서 사다리를 **기계로** 읽는다 | 손인용 금지. 삼상을 **다른 낱말**로 찍는다: UNMEASURED / FALSE / MEASURED-EMPTY / MEASURED-ZERO / TRUE |
| `steps[i].detail` 이 기록 줄·결정 행에 실린다 | `:threw` 가 **이유**를 나른다 | 이전엔 사후 프로브로 추론했다 |
| `world_delta_body` + `body_scope=body_only(probed)` | body 직후·하네스 재풀이 **직전** 다이제스트 | `surface="sched"` body 도 귀속 가능해졌다 |
| `n_weights_changed` | 다섯째 축 (`sched.weights`) | 런 1 의 body 가 편집한 축이 안 보였다 |
| 2026-09-04 사전등록 문서 | 술어를 **결과 보기 전에** 고정 | `…reports/2026-09-04-ladder-run2-preregistration.md` |

**삼상 규약은 이 레인의 헌법이다**: `nothing` = 못 쟀다 · `false` = 쟀는데 거짓 · `[]`/`0` =
쟀는데 비었다/안 움직였다. **이 셋을 뭉개는 코드는 결함이다.** 오늘 `ladder_report.py` 에서
"모양을 못 판정" 분기가 **TRUE 를 기본값으로** 주고 있었고(= 측정된 음성이 최강 양성으로 찍힘)
리뷰가 잡았다.

### 1.4 음성 대조 — 데모가 말할 수 있는 것의 상한

`TOOL_SYNTHESIS` **없이** 띄운 서비스(:8078)로 같은 시드·같은 사건을 돌린 결과 [측정]:
대조도 `PROJECT COMPLETE!`, 최종 수가 처치와 **완전히 동일**(step 865 · closed 283/305).

⟹ 🔴 **"tool 이 build 를 구했다" 는 말할 수 없다.** 이 사건은 기본 복구 사슬이 받아낸다.
그리고 그 동일성은 "재배정해도 효과가 없다" 는 뜻이 **아니다** — body 가 **첫 dict 읽기에서
던졌고**(`applied=false`), 재배정 로직은 전부 주석이었다. **세계를 건드린 적이 없다.**

---

## 2. 문제 — 순위대로

### P1 🔴 접지(grounding) 채널이 주조 body 레인에 없다 — **가장 깊은 것**

모델이 대상 로봇을 지목할 방법이 없다. [측정]

- `resolve_agent_id(env, s::AbstractString)` 가 `src/respec/llm_bridge.jl` 에 **존재한다.**
  그 파일 머리말이 스스로 이렇게 적는다: 접지 열거들은
  *"the single source of 'the set we showed the model' vs 'the set we accept back',
  and splitting them is exactly how grounding breaks silently."*
- 🔴 **그런데 그것은 매크로/결정 레인의 채널이다.** `resolve_agent_id` 는 **export 되지 않아**
  산출물의 광고 목록에 **없다** [측정] ⟹ 주조 body 가 부를 수 없다.
  하네스는 그것을 **자기가** 쓴다(`enact_minted_decision!` 안에서 매크로의 `tool_args["agent"]` 를 풀 때).
- 정준 문자열은 `string(rid)` where `rid isa RobotID` 이지 **`"R1"` 이 아니다** [측정].
  `"R1"` 은 결정 행의 표시 라벨(`chosen="NOOP R1"`)에서 온 것으로 보인다 `[미측정]`.
- 🔴 그리고 **id 객체는 인자 채널을 물리적으로 못 건넌다**: `bind_primitive_args` 가
  `_param_type_reject` 의 JSON 타이핑 아래 `ctx.params` 로 키워드를 만든다 [측정].
  ⟹ body **안에서** 푸는 것이 편의가 아니라 **유일한 경로**다.

**증상**: 런 2 가 `soc["R1"]` 로 죽었다. 타입도 문자열 형식도 둘 다 틀렸다.

### P2 🔴 자기수정 채널(`/rewrite`)이 라이브에서 죽었고 **사유를 안 남긴다**

D17 의 되먹임(Julia → `/rewrite` → agent-3, 재시도 상한 1)은 **정확히 등록 거절**을 위해 있다.
런 3 의 "기본값 누락" 은 바로 그것이 고쳤어야 할 종류였다. 그런데 [측정]:

```
[minted] rewrite: 왕복 실패 (원래 거절이 그대로 남는다): HTTP.RequestError:
```

- 서비스 로그에 `/rewrite` 요청이 **한 번도 안 도착했다**(`/decide` 200 만 있다) ⟹ 클라이언트 쪽 실패.
- 라우트는 살아 있다: 빈 POST → **200, 2.6s** (LLM 호출 없이).
- 클라이언트 설정은 넉넉하다: `readtimeout = 120, retries = 0`.
- 🔴 **`HTTP.RequestError:` 뒤가 비어 있다.** 우리가 `steps` 에 대해 방금 닫은 구멍과
  **똑같은 종류**가 한 층 위에 그대로 있다.

**이것이 최우선인 이유**: 이게 닫히기 전에는 **어떤 런도 실패 원인을 추론으로만** 말한다.
그리고 되먹임이 살아 있으면 규약 위반 종류의 실패는 **한 판 안에서** 스스로 복구된다.

### P3 🔴 재배정 원시가 광고에 없어서 모델이 **스텁**을 쓴다 — L4 가 0 인 진짜 이유

런 2 body 의 재배정 로직 [측정, 원문]:

```julia
for task in new_task_allocation
    task_id, new_robot_id = task
    if new_robot_id in higher_soc_robots
        # Reallocate task to new_robot_id
        # This would involve updating the schedule graph
        # Example: update_task_allocation!(env.sched, task_id, new_robot_id)
    end
end
```

**전부 주석이다.** `expressible=False`(어휘로 표현 불가)인데 재배정 원시도 광고에 없으니,
모델은 **부를 것이 없어서** 의도를 주석으로 적었다.

⟹ **L2b 를 닫아도 L4 는 0 이다.** 이건 키 형식 문제도 예외 문제도 아니고 **어휘 설계 문제**다.
그리고 D6 의 감춤 정책과 정면으로 부딪힌다 — 감추는 것이 실험의 요점인데, 감춘 결과가 스텁이면
사다리 위쪽은 구조적으로 도달 불가다.

### P4 ⚠️ 프롬프트에 규칙을 더하면 실패가 **사라지지 않고 옮겨간다** [측정 3회]

| | 환각/위반 | 무엇을 고쳤나 | 결과 |
|---|---|---|---|
| 런 1 | 필드 이름 (`node.assigned_robot`) | 타입 폐포 깊이 확장 | 환각 0건 — **대신** 필드 경로를 골라 L3=[] |
| 런 2 | 키 타입 (`"R1"`) | 호출 선호 + 반환 예시 | L3 초록 — **대신** 키 타입에서 죽음 |
| 런 3 | 규약 위반 (kwarg 기본값 없음) | 식별자 규칙 | `"R1"` 소멸 — **대신 L1 붕괴** |

🔴 **런 3 의 원인은 모델의 잘못이 아니라 우리가 만든 모순이었다**: 규칙 6 은 "id 를 env 에서
얻어라" 이고 규약은 "모든 키워드에 기본값" 인데, **기본값은 리터럴이어야 하므로 env 객체는
기본값이 될 수 없다.** 모델은 동시에 만족 못 하는 둘을 받고 하나를 버렸다.

⟹ **"규칙 하나 더" 를 기본 처방으로 삼지 말 것.** 규칙을 더하기 전에 **기존 규칙 전체와
동시 만족 가능한지** 검사하라(오늘 15쌍 전수 점검을 했고 불가능 쌍 하나를 찾았다).

### P5 ⚠️ 계측기 자신의 남은 구멍 (parked)

- `_world_delta_str` 의 네 로그 자리 중 셋이 `world_delta_body`/`body_scope` 를 안 찍는다
  (결정 **행**은 영향 없으므로 채점은 안 바뀐다).
- 결정 행의 `detail` 도 200자 상한 ⟹ 긴 예외는 **두 채널 모두에서** 복구 불가.
- `world_delta_body` 게이트의 fixture 가 `active_build_steps` 를 `cache.active_set` 에 **별칭**한다.
  🔴 그래서 `_world_digest` 의 `active` 축을 다른 것으로 바꿔도 **초록으로 남는다** —
  그 시험은 `world_delta_body` 의 **출처·시점**은 지키지만 **`active` 축의 정체**는 안 지킨다.
- `ladder_report.py` 가 `steps=` 를 첫 `str.find` 로 찾는다 — 앞 필드에 그 리터럴이 들어가면 오작동.

### P6 ⚠️ 데모는 **필요성**을 못 보인다

§1.4 참조. 이 사건은 tool 없이도 완주한다. 필요성을 보이려면 **기본 복구 사슬이 못 받는 사건**을
골라야 하고, 그 사건이 어떤 것인지가 아직 정해지지 않았다 `[미측정]`.

---

## 3. 다음 단계 — 무엇을, 왜, 어떻게 확인하는가

**순서에 의미가 있다.** S1 이 없으면 S3~S5 의 실패를 관측이 아니라 추론으로 읽게 된다.

### S1 (최우선) `/rewrite` 실패의 사유를 기록에 남기고 원인을 잡는다 — P2

- **무엇**: `_rewrite_once` 의 `catch` 가 예외 메시지를 **버린다**. `steps` 에 대해 한 것과
  똑같이 — `_one_line_rec` 로 접고 상한을 두고 기록 줄에 싣는다. 그 다음 원인을 본다.
- **왜 먼저**: 이게 없으면 넷째 런도 "왜 죽었는지" 를 추론으로만 말한다.
- **확인**: 일부러 죽는 URL(`DSPY_URL=http://127.0.0.1:1`)로 프로브를 돌려 기록 줄에
  사유 문자열이 **실제로 나타나는지** 본다. 음성 대조: 수정을 되돌리면 빨개져야 한다.
- **주의**: `/rewrite` 는 유료다. **원인 진단은 무료 경로로** 하라 —
  빈 POST(`{}`)는 200 을 내고 LLM 을 안 부른다 [측정].

### S2 ✅ `soc` 키 타입 좁히기 — **이미 착륙했다** (`5bfebe29`)

`Dict{Any,Float64}` → `Dict{BotID{DeliveryBot},Float64}`. 산출물 재생성, 바이트 게이트 초록,
시험 944 불변, `generation` 불변. 광고 문자열이 실제로 바뀐 것을 렌더로 확인했다 [측정].
🔴 **교훈**: `returns` 가 기계 유도이므로 **타입 선언을 고치는 것이 산문 규칙보다 낫다.**
같은 모양의 다른 `Any`/`Dict{Symbol,Any}` 가 인터페이스에 남아 있는지 훑을 가치가 있다
(오늘 실측으로는 렌더 본문에 `Dict{Any`·`Vector{Any}`·`Set{Any}`·후행 `:: Any` **전부 0건**).

### S3 접지 열거를 주조 body 레인에 노출할 것인가 — **설계 결정** (P1)

세 선택지, 각각 다른 것을 희생한다:

| 안 | 무엇 | 대가 |
|---|---|---|
| **A** `resolve_agent_id` 를 export 해 광고 | 모델이 이름→id 를 스스로 푼다 | 정준 문자열이 `string(rid)` 라 모델이 그 형식을 또 지어낼 수 있다 |
| **B** 사건의 대상 id 를 `env` 에 실어 광고 | 모델이 "이 사건의 로봇" 을 **직접** 얻는다 | `PlannerEnv` 에 사건-특정 필드가 생긴다(상태 정의 오염) |
| **C** 하네스가 body 인자의 문자열을 resolve | 모델은 이름만 쓰면 된다 | 매크로 레인의 `tool_args["agent"]` 와 **같은 오귀인 위험**을 주조 레인에 복제한다 |

🔴 **결정 전에 재라**: agent-2 의 `spec`/`mechanism` 문자열이 대상 로봇을 **어떤 형식으로**
지목하는지 [미측정]. 그것이 `string(rid)` 와 일치하면 A 가 거의 공짜다.

### S4 재배정 원시를 광고할 것인가 — **설계 결정** (P3)

이것이 **L4 를 0 밖으로 내보내는 유일한 길**이다. 그런데 D6 의 감춤 정책과 충돌한다.
정직한 프레이밍:

- 감춤의 목적은 "모델이 **없는 능력을 조합해 내는가**" 를 보는 것이다.
- 오늘의 관측은 "조합하지 않고 **주석으로 의도를 적는다**" 이다 [측정, 2판].
- ⟹ 감춘 채로 두면 사다리 위쪽은 **구조적으로 도달 불가**일 수 있다. 그렇다면 감춤은
  실험이 아니라 천장이다. **감춘 다섯 중 무엇을 왜 감추는지 다시 판정할 것.**

`[미측정]` 대안: 재배정 원시를 광고하되 **감춘 다섯은 그대로 두고** 다른 사건으로 조합 능력을
따로 재는 것. 그러면 L4 축과 조합 축이 분리된다.

### S5 넷째 유료 런 — S1 이 끝난 **뒤에**

오늘 착륙했으나 **런으로 검증 안 된** 커밋 셋: `1743856d`(규칙 1/6 모순 해소) ·
`5bfebe29`(키 타입) · `8d534bf0`(규칙부에서 구체 타입 인용 제거).

- 레시피는 §5.
- 🔴 **런 전에 사전등록 문서를 갱신하고 술어를 고정할 것.** 결과를 보고 술어를 고치지 않는다.
- ⚠️ 감시 항목: `first(keys(env.agent_policies))` 는 **모양**을 가르치지 선택 정책이 아니다.
  모델이 그대로 베끼면 명세가 지목한 로봇이 아니라 **임의의 로봇**을 고를 수 있다 —
  그러면 런은 깨끗이 돌지만 **행동은 틀린다.** L2b 초록을 그것과 혼동하지 말 것.

### S6 P5 의 계측기 구멍들 — 값이 싸고 각각 독립적이다

특히 **`world_delta_body` fixture 의 `active` 축 별칭 맹점**은 L4 판정을 지키는 시험의
구멍이므로 다음 런 전에 닫는 것이 좋다.

---

## 4. 함정 — 오늘 실제로 밟은 것들

1. 🔴 **세대 게이트는 대조 런까지 막는다.** `src/respec/llm_service/` 를 고치는 작업이 도는 동안
   **어떤 런도** 못 돈다(tool-off 대조 포함) — 게이트가 트리 전체를 해시하고 엔드포인트를 안 가린다.
   "대조는 합성 레인을 안 쓰니 무관하다" 는 프롬프트 수준에선 참이고 **게이트 수준에선 거짓**이다.
   ⟹ 런은 파이썬 편집이 **전부 착륙한 뒤** 서비스를 재기동하고 한 창에서 몰아 돌린다.
2. 🔴 **`pkill -f "…port 8077"` 은 자기 셸을 죽인다** — 셸의 명령줄이 그 패턴을 담고 있어서다.
   스크립트가 중간에 끊겨 **다른 포트의 낡은 서비스가 살아남았다.** 포트별 PID 조회로 죽일 것.
3. 🔴 **인용한 수가 세 번 틀렸다.** (a) pytest 기준선을 옛 원장에서 인용해 368 이라 적었다(실제 379).
   (b) recon 이 준 줄번호 넷이 어긋났다. (c) "early return ~11개" 가 세는 대상이 달랐다.
   **전부 구현자가 실측으로 잡았다.** 브리프에 수를 적을 때는 그 수를 **어떻게 쟀는지**도 적어라.
4. 🔴 **거짓 주장이 시험 docstring 에 박혀 게이트가 됐다.**
   `"there is no way to narrow Any from the artifact side"` — 이것이 그 결함을 **계속 열어 둔
   바로 그 이유**였고, 실제로는 30분 작업이었다. 전파 경로: agent 보고 → 컨트롤러 요약 →
   시험 docstring. **세 층 중 아무도 재유도하지 않았다.**
5. ⚠️ **배경 작업을 폴링하지 마라.** `run_in_background` 는 끝나면 **알림이 온다.**
   오늘 `sleep 240/540/420` 으로 20분 넘게 블로킹 대기했고, 그중 한 번은 Julia 출력 버퍼링을
   "죽었나?" 로 오독해 **폴링이 폴링을 낳았다.**
6. ⚠️ **`_one_line_rec` 절단이 괄호를 가르면 채점기가 죽는다.** 예외 메시지에 `]`·`,` 가 흔하다.
   렌더러가 중화(`(`·`[`→`<`, `)`·`]`→`>`)하고 채점기가 깊이 추적으로 파싱한다. **ASCII 로 유지할 것** —
   비-ASCII 치환은 바이트 길이를 바꿔 상한 경계를 깬다.

---

## 5. 재현 레시피

```bash
# 1) 서비스 두 개 (처치 / 대조). 포트별 PID 로 죽인다 — pkill -f 금지.
cd src/respec/llm_service
TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 DSPY_CACHE=0 \
  ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077 &
DSPY_CACHE=0 \
  ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8078 &   # tool OFF = 대조

# 2) 세대 게이트 — 정본 검사기로만 판정한다. /health 200 은 증거가 아니다.
REQUIRE_TOOL_SYNTHESIS=1 bash -c \
  'source tools/require_current_service.sh && require_current_service http://127.0.0.1:8077'
#    🔴 REQUIRE_SYNTH_MULTI_AGENT 는 켜지 말 것 — 어떤 레인도 안 읽어서 옳은 런이 FAIL flag_off 로 죽는다.

# 3) 런 전 산출물 치우기 (안 하면 옛 런을 채점한다)
mv -f results/synth_lane_records.jsonl results/synth_lane_records.prev.jsonl
mv -f tools/monitor/streams/tractor__battery_mild.jsonl tools/monitor/streams/prev.jsonl

# 4) 처치 런 (유료 ~4회). REQUIRE_TOOL_SYNTHESIS 는 **julia 줄에** 있어야 한다.
env REQUIRE_TOOL_SYNTHESIS=1 \
    DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_CASE_TAG=battery_mild \
    DEMO_BATTERY_STEPS=40,120 DEMO_POLICY=dspy DEMO_ANIM=0 DSPY_URL=http://127.0.0.1:8077 \
    julia +lts --project=. tools/monitor/render_demo.jl > results/runN.log 2>&1

# 5) 채점 — 손으로 로그를 읽지 말 것
python3 tools/monitor/ladder_report.py --log results/runN.log \
  --record results/synth_lane_records.jsonl \
  --stream tools/monitor/streams/tractor__battery_mild.jsonl
```

- `DEMO_BATTERY_STEPS=40,120` 은 **필수다.** 기본 창(40~700)은 낮은 SoC 로봇을 뽑아
  `routing_kind="battery"` → **surrogate 로 새서 $0 쓰고 아무것도 안 잰다.**
- 런 하나 ≈ **4~5분**(시뮬레이션 ~2분). 전체 스위트는 **~24분**이라 `src/`·`tools/` 를 바꿀 때만.
- 회귀 기준 [측정 2026-09-04]: `3180 passed / 0 failed / 1 errored / 0 broken`.
  유일한 error 는 `test/runtests.jl` 의 Demo → **Gurobi 10009 (라이선스 없음)** = 기대값.
  🔴 **이 수는 자라는 중이다. 인용하지 말고 재유도하라.**

---

## 6. 사람이 정해야 하는 것 (에이전트가 정하면 안 되는 것)

1. **S3** — 접지 열거를 주조 body 레인에 줄 것인가, 준다면 A/B/C 중 무엇인가.
2. **S4** — 재배정 원시를 광고할 것인가. **감춤이 실험인가 천장인가**를 판정하는 일이다.
3. **P6** — 데모가 *필요성*을 주장해야 하는가. 그렇다면 기본 복구 사슬이 **못 받는** 사건을
   골라야 하고, 그건 새 실험 설계다.
4. **과금 상한.** 오늘 사전등록은 8 이었고 셋째 런에서 12 로 올렸다(기록된 판정).
   넷째 런은 ~13회가 된다.

---

## 참고

- 원장(판정 전부 · 리뷰 보고 · 음성 대조 출력):
  `docs/superpowers/reports/2026-09-04-ladder-l2-l4-run-record.md`
- 사전등록(술어를 결과 보기 전에 고정): `docs/superpowers/reports/2026-09-04-ladder-run2-preregistration.md`
- 설계(사다리 정본): `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` §0
- 데모 페이지: https://claude.ai/code/artifact/0b53b9d3-d503-4320-bd69-678164659909
