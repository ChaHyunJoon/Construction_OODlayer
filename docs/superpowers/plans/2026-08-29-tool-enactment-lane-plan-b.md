# Plan B — tool 이 실제로 DAG/씬트리를 고치게 만든다

**상위 권위**: `docs/superpowers/specs/2026-08-26-tool-synthesis-lane-design.md` (구속력 있는 spec).
이 계획서는 그 spec 의 논증이고, 충돌하면 spec 이 이긴다.

**딛는 트리**: `7226b629` (`oracle-rebuild-night-2026-08-10`), Plan A 27커밋 완료 상태.

---

## 0. 한 줄 요약

Plan A 는 **"고르고 재는 레인"** 을 지었다. 원 설계도의 *"tool 이 DAG 를 고친다"* 는 부분은
**오늘 존재하지 않는다.** Plan B 는 그 한 문장을 참으로 만드는 배선이고, 그 위에서만 T2(합성)가
말이 된다.

---

## 1. 오늘의 실측 (2026-08-29, HEAD `7226b629`)

전부 이 세션에서 명령 출력으로 확인했다. 손계산 없음.

| # | 주장 | 실측 근거 |
|---|---|---|
| 1 | tool 본문은 **아무것도 안 한다** | `src/respec/llm_service/tool_registry.py:57·70·79` 세 자리 모두 `raise AssertionError(_NEVER)`, `_NEVER = "never called: Julia enacts this"` (`:36`) |
| 2 | 집행은 **LLM 이 고른 agent 를 안 본다** | `tools/monitor/run_demo.jl` 의 하드코딩 사슬. `mac == "Replace"` → `CB.hot_swap_robot!(env, truth.robot; ...)`, `mac == "SwapBattery"` → `CB.swap_battery!(env, truth.robot; ...)`. 인자는 **`truth.robot`**, 즉 주입기가 이미 아는 값이다 |
| 3 | 집행부가 보는 것은 **매크로 이름 하나** | `run_demo.jl:286` `mac = decision.macro_name`. `decision` 에 tool 관련 필드가 없다 |
| 4 | 레인 키가 **Julia 로 안 넘어온다** | `policy_entry` 의 성공 분기가 키 8개를 손으로 들고 있다 — `chosen·ranking·margin·rationale·scores·unsupported·label·available`. `tool_called`/`tool_args`/`tools_offered`/`native_fc`/`macro_tool_agree`/`tool_lane_error`/`expressible`/`tool_calls_n` **전부 탈락** |
| 5 | 서비스는 그 8개를 **이미 내고 있다** | `src/respec/llm_service/dspy_service.py:1030-1073` (`decide()`), `:1103-1107` (`macro()`) |
| 6 | `.jl` 에서 `tool_args` 는 **주석 1건뿐** | `grep -rn tool_args --include='*.jl'` → `tools/monitor/policy.jl:565` 한 줄, 그것도 "나르는 것이 없다"고 적은 주석이다 |
| 7 | `primitive_registry.json` **없다** | `find . -name 'primitive_registry*'` → 0건 |
| 8 | T2 합성기 **없다** | `grep -rn 'SynthesizeTool\|New_tools' --include='*.py'` → 0건 |
| 9 | 접지 그물은 **실재하지만 이 레인을 못 본다** | `grammar_ground_check` 정의 `src/respec/verifier.jl:654`, 호출 `verifier.jl:104`·`llm_bridge.jl:512`. 둘 다 `RespecProposal` 을 받는다 — tool 인자는 거기 안 닿는다 |
| 10 | ④ 실효성 층의 재료는 **이미 있다** | `src/respec/zone_corridor.jl` 의 순수 술어: `goal_engulfed:180` · `free_space_status:220` · `_downstream_unfinished:296` · `zone_blockage:344` |

**귀결 한 줄**: 오늘 LLM 의 tool 호출은 **세계에 대해 인과가 없다.** 매크로 이름만 인과가 있고,
그 인과는 Plan A 이전과 같은 하드코딩 사슬이다.

---

## 2. spec §9-1 선행조건 재측정 — spec 이 낡았다

spec §9-1 은 세 선행조건을 "🔴 아직 안 고쳐졌다"로 적어 두었다. **오늘 기준으로 그중 둘은 끝났다.**

| 선행조건 | spec 의 서술 | 2026-08-29 실측 | 판정 |
|---|---|---|---|
| ① 서술자 채널 복구 | "`if !have_det` 조기 반환이 `descriptors` 키 없이 돌려준다" | `tools/monitor/policy.jl:506` 에서 `desc` 를 **먼저** 계산하고 `:511` 이 `route_verdict(desc = desc, have_det = false, ...)` 로 싣는다 | ✅ **끝남** |
| ② payload 확장 `agents`/`zones`/`nodes` | 셋 다 필요 | `agents` 만 있다 (`policy.jl:572` `payload["agents"] = agents`). `zones`·`nodes` 는 payload 에 **없다** | ⚠️ **1/3** |
| ③ `action_registry.json` 의 doc 분리 | §6-2 | 매크로 0·1·2 전부 `mechanism`/`when_to_use` 별도 필드. 렌더도 갈라져 있다 — `core/action_registry.py:194` 가 `when_to_use` 를 안 싣고 `core/test_registry_doc_split.py` 가 그것을 지킨다 | ✅ **끝남** |

**작업 0 (기록 정정)**: ✅ **완료.** spec §9-1 을 세 항목의 오늘 판정 + 근거 줄로 고쳤고,
그 아래 프롬프트 채널 표에 **2026-08-29 실측** 열을 붙였다.

### 2-1. 🔴 그 정정 중에 나온 것 — 선행조건 목록에 **빠져 있던 네 번째 항목**

프롬프트 채널 표의 `min_shift_to_clear_m` **제거** 행(§1-4 규약)이 **미이행**이다. 실측:
`src/respec/llm_service/dspy_service.py:800` 이 그 필드를 `_GEOM_COVERAGE` 에 들고 있고
`_geometry_block()`(`:829-848`)이 `WHAT THIS ZONE COVERS` 블록으로 **프롬프트에 렌더한다**.

이것이 지금까지 아무 작업 항목에도 안 잡힌 이유는 단순하다 — **§9-1 의 세 선행조건에 안 들어
있었다.** 표에만 있었고 표는 아무도 작업 목록으로 읽지 않았다.

🔴 **B3 의 하드 선행조건으로 승격한다.** §1-4 가 이걸 빼라고 한 이유(오라클의 답을 프롬프트에
실으면 재는 것이 추론이 아니라 프롬프트 준수가 된다 — 실측 전례: 서술자가 `harm=0.02` 인데도
"restage 하라"를 따라 ForbidZone 을 골랐다)는 **T2 가 기하 축에서 파라미터를 유도하는 순간 더
강해진다.** 합성기에게 정답 이동량을 그대로 보여주면 §5-3 의 P-예측이 전부 무의미해진다.

⚠️ 같은 종류를 한 번 더 찾는다: `tool mechanism` 행도 ⚠️ 다 — 실려 있긴 한데
`tool_registry.py` 의 docstring 이 `action_registry.json` 의 `mechanism` 을 **읽지 않고 손으로
복사**한 것이라 두 벌이 갈라질 수 있다. B0 가 레지스트리를 하나 더 만드는 단계이므로
**"docstring 의 단일 진실원은 어디인가"** 를 B0 에서 함께 정한다.

---

## 3. 남은 단계

각 단계는 **게이트를 먼저 실패시켜 본 다음** 통과시킨다. 이 세션의 반복 교훈:
게이트는 실패하는 것을 본 적이 없으면 완성이 아니다.

### B0 — 원시 연산 알파벳을 파일로 (`primitive_registry.json`)

**무엇** — spec §2-3 의 인벤토리(산문 표)를 §7-1 스키마의 JSON 으로 만든다. 항목당:
`name · surface(sched|scene_tree|env_param|physical) · params · mechanism · when_to_use ·
reversible · consumes · preconditions · gate · impl`.

**왜 먼저인가** — 이게 T2 가 조합할 알파벳이자, 사용자가 세운 상시 원칙
*"docstring 은 최대한 상세하게 — LLM 이 자기가 무엇을 가졌고 DAG 를 어디까지 고칠 수 있는지
알아야 한다"* 가 실제로 사는 유일한 자리다. 알파벳 없이 B3 는 못 짓는다.

**🔴 섞지 않는다** — `action_registry.json`(채점 어휘, 3항목 고정) 과 **다른 파일**이다.
spec §7-2: `emitted_key` 가 사건 클래스를 인코딩하므로 원시 연산을 섞으면 없는 사건 클래스가
채점기로 밀반입된다.

**게이트**
1. `impl` 의 모든 이름이 `CB` 에서 실제 callable 로 해석된다 (Julia 테스트).
   **변이시험**: `impl` 하나를 오타 내면 테스트가 죽어야 한다.
2. `gate` 가 `null` 이 아닌 항목은 그 Julia 함수도 실재해야 한다.
3. `reversible: false` 인 항목(`release_pending_assignments!`, `pop_spare!`)은 §8 ③층에서
   되돌릴 수 없다는 사실이 스키마에 남는다.

**크기** — 인벤토리 항목 ~14개. 파일 1개 + 테스트 1개.

---

### B1 — tool 인자를 집행까지 배선 (이 계획의 본체)

원 설계도의 *"tool 이 씬트리/DAG 를 고친다"* 는 여기서만 참이 된다. 셋으로 쪼갠다.

#### B1a — 레인 키를 Julia 로 나른다

`policy_entry` 의 손으로 든 키 목록(실측 4)을 고쳐 레인 키 8개를 통과시키고,
`decide_all` 이 그걸 `decision` 에 노출한다.

**게이트**: 서비스 응답에 `tool_called` 를 넣은 뒤 `decision` 에서 읽어 단언.
**변이시험**: 키 하나를 `policy_entry` 에서 지우면 테스트가 죽어야 한다.
(이 파일은 전례가 있다 — spec 이 인용하는 대로, 예전에 `"unsupported"` 를 지워도 9개 검사가
전부 초록이었다. 손으로 쓴 복제본을 테스트로 착각한 사고다. 같은 실수를 반복하지 않는다.)

#### B1b — 집행이 LLM 의 인자를 읽는다

`run_demo.jl` 의 사슬에서 `truth.robot` 을 **tool 인자의 agent** 로 바꾼다.
`tool_args` 가 없거나 거절되면 `truth.robot` 로 떨어지되, **그 사실이 결정 행에 남아야 한다**
(조용한 폴백 금지 — 그러면 "LLM 이 골랐다"와 "주입기가 알려줬다"가 구분 불가능해진다).

**게이트 (이 계획에서 가장 중요한 하나)**: `tool_args` 의 agent 가 `truth.robot` **과 다른**
사건을 만들고, 세계가 **그 다른 agent 에서** 바뀌었는지 관측한다.
**변이시험**: 배선을 되돌리면(=`truth.robot` 로 되돌리면) 이 테스트가 죽어야 한다.
오늘 이 테스트는 정의상 실패한다 — 그게 실측 2 의 내용이다.

#### B1c — 접지를 강제한다 (오늘 이 층은 **없다**)

실측 9: 그물은 있는데 tool 인자에 안 닿는다. 경계에서 `tool_args` 를 검사하는 자리를 만든다.
결과는 **삼상**이어야 한다 — `admit` / `reject:<reason>` / `deferred`.
🔴 `deferred`(못 쟀다) 를 `admit`(재서 통과했다) 로 뭉개지 않는다 (spec §9-2, 이 레포가
여러 번 데인 자리).

**게이트**: 실재하지 않는 agent id 를 담은 `tool_args` → `reject:ungrounded` 로 기록되고,
**결정 자체는 지워지지 않는다** (spec §4-1: tool 실패가 결정을 지우면 안 된다).

**의존**: B1a → B1b → B1c 순서. B1c 는 B1b 보다 **먼저 머지돼도 된다**(더 안전하다).

---

### B2 — 결정 행 스키마를 spec §9-2 까지 채운다

B1 이후 남는 필드: `verify`("admit"|"reject:<reason>"|"deferred") · `efficacy`("resolves"|
"inert"|"deferred") · `tool_minted` · `emitted_keys`(**Julia 가** `CB.emitted_key` 로 계산).

`efficacy` 는 ④층이다: `zone_corridor.jl` 의 순수 술어(실측 10)로 **편집 전후를 재측정**해서
"관측된 막힘에 실제로 닿았는가"만 본다. 화이트리스트가 아니라 필요조건이다(spec §1-4 승계).

**게이트**: 아무것도 안 푸는 편집이 `:inert` 로 떨어진다.
**변이시험**: 사전 측정을 사후 측정으로 바꿔치기하면 모든 편집이 `resolves` 가 되고 테스트가 죽어야 한다.

**부수 효과**: 이 단계가 끝나면 spec §8-1 의 대체 신호 넷(`expressible=false` 비율 ·
`reach=needs_primitive` 비율 · `minted=false` 비율 · ③④ 거절 사유 분포)이 처음으로 **측정 가능**해진다.
승격 게이트 임계값은 그 뒤에 정한다 — spec §9-3: 지금 숫자를 지어내지 않는다.

---

### B3 — T2 합성 (`SynthesizeTool`) — 사용자의 `ChainOfThought(New_tools)`

**무엇** — spec §5-1 시그니처. 사용자가 세운 형태 그대로:

- `context` = 레포의 물리 원리(3층 로봇 정책 · 씬트리 · DAG 설계) +
  {현재 상태, 최종 목표, OOD 사건의 새로운 성질, 무엇이 바뀌어야 하는가, 현재 가진 tool 들}
- `question` = OOD 사건의 성질
- 출력 = 그 사건을 다룰 수 있는 tool — **B0 의 원시 알파벳으로만 조합된다**

**두 단계 판정** (spec §5-2-2) 과 **ψ 중복 처리**: 중복은 차단이 아니라 **측정**이다
(`minted=false` 비율이 곧 "재발명 빈도"이고, spec §5-2-3 이 말하는 "어휘 폭발"의 정량이다).

**시험지** — spec §5-3 의 반증 가능한 예측 P1·P2·P3. P2 는 `reprice_agent` 계약을 **지어야** 한다.

**의존**: B0(알파벳) + B2(판정 층). 둘 없이 B3 는 판정 불가능한 텍스트 생성기다.

**🔴 범위 제약 (spec §2-5, 실측)**: 서비스는 Julia 에게 되물을 수 없다 — `MacroRequest` 는
단방향 push 이고 서비스는 별도 uvicorn 프로세스다. 따라서 T1·T2 는 **단일 턴**이다.
다중 턴 ReAct 루프는 Julia 쪽 질의 엔드포인트 신설이 선행조건이고, 이 계획의 범위 밖이다.

---

### C — 안전 스택 ③ 을 제안 단위에서 **연산 단위**로

각 tool 이 자기 전제조건을 검사하고 실패 시 **원복**한다. spec §8 이 "이 설계의 핵심 변화"라고
부르는 것. 오늘은 `verify()` 하나가 제안 전체를 보는데 그 입도로는 부하 축을 `deferred` 로만
쌓을 수 있었다.

**하드 선행조건** (spec §9-3): **`reprice_agent` 의 국소 undo 가 지어졌는가.** 없으면 부하 축은
집행으로 전환하지 않는다. `deprioritize_agent!` 는 **MILP 재풀이 없으면 무효**이고(spec §2-3 B),
`release_pending_assignments!` 는 **비가역**이다(§2-3 A, spec §1-3(e)).

---

### 곁가지 — 프롬프트 채널 마무리 (B3 착수 전까지)

세 개 남았고, 셋 다 §9-1 아래 표에 실측 상태로 박아 두었다.

1. **`zones` 추가** (`center·radius·covers`) — 기하 축의 **유일한** 입력. ForbidZone 사건에서
   T2 가 파라미터를 유도하려면 필수. B1c 와 같이 가면 싸다(둘 다 payload 를 건드린다).
2. **`nodes` 추가** — 마일스톤 ~9개만. 미완 노드 전체(~255) 가 아니다.
3. 🔴 **`min_shift_to_clear_m` 제거** — §2-1. **B3 의 하드 선행조건.**
   게이트: 그 필드가 렌더된 프롬프트 문자열에 나타나지 않는다.
   **변이시험**: `_GEOM_COVERAGE` 에 도로 넣으면 테스트가 죽어야 한다.

---

## 4. 순서와 의존

```
작업 0 (spec 정정)  ──┐
                      ├─→ B1a ─→ B1b ─→ [원 설계도가 참이 되는 지점]
B0 (알파벳 + 게이트) ─┤        ↘
                      └─→ B1c ─→ B2 ─→ B3 ─→ C
                          (+ zones/nodes)   ↑
                                            └── 🔴 min_shift_to_clear_m 제거가 하드 선행조건
```

- **B1b 가 분수령이다.** 그 앞은 전부 계측이고, 그 뒤부터 LLM 의 출력이 세계에 인과를 갖는다.
- **B0 와 B1 은 서로 독립**이라 병렬 가능. B3 는 둘 다 필요하다.
- **C 는 마지막**이고, `reprice_agent` undo 라는 자기만의 선행조건을 갖는다.

## 5. 비용과 위험

- 🔴 **`127.0.0.1:8077` 로 가는 `/decide`·`/macro` POST 는 전부 사용자 계정의 유료 OpenAI 호출**이다.
  B1b·B3 의 게이트는 가능한 한 **DummyLM/고정 응답**으로 짜고, 라이브 호출은 승격 판정에서만 쓴다.
  (`/health` GET 은 무료.)
- 🔴 **살아 있는 서비스가 HEAD 기준으로 낡았다** — Task 4 이전 코드를 메모리에 들고 있다.
  B1a 를 재기 전에 재시작이 필요하다.
- ⚠️ B1b 는 **세계를 바꾸는 코드 경로**를 건드린다. 게이트가 통과하기 전에는 스위프를 돌리지 않는다.
- ⚠️ `pytest` 는 **항상** `--ignore=src/respec/llm_service/test_propose.py` 를 달고 돈다
  (그 파일은 import 시점에 유료 Anthropic 호출을 낼 수 있다).

## 6. 이 계획이 안 하는 것

- 채점 근거 확보 — mild battery(`soc > 0.2`) 와 zone 은 `reference_policy` 가 **unscored** 로 둔다.
  이 레인이 겨냥하는 두 사건을 채점기가 채점하지 않는다는 사실은 이 계획이 안 바꾼다(spec §11).
- 다중 턴 ReAct (§2-5).
- `action_registry.json` 의 어휘 변경 — 3항목 고정, `vocab = v4-3arms`.
