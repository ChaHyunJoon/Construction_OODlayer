# 세션 상태 인계 (2026-09-05) — zone 레인, 유료 런 13판

이 문서는 컨텍스트 압축 직전에 쓴 것이다. **다음 세션은 이것부터 읽는다.**
표기: `[측정]` = 실제로 잼 · `[미측정]` = 코드 읽기. 코드는 **함수·testset 이름**으로 가리킨다.

---

## 0. 지금 무엇을 하고 있었나 (한 문단)

zone OOD 사건에서 multi-agent LLM 이 새 Julia 도구를 합성해 **미완주 build 를 완주시키는** 데모를
만드는 중. 배관은 전부 라이브에서 작동함을 확인했고, **모델 출력이 진동해서** 안 되고 있다.
사용자 지시로 모델을 `gpt-4o` → **`gpt-5.6-sol`** 로 바꾸는 중이며, 두 판(런 12·13)이 **배선에서**
죽어 **아직 sol 의 능력을 한 번도 관측하지 못했다**.

🔵 **진행 중인 작업 하나**: 런 13 의 blank decision 원인 진단(서브에이전트). 아래 §6.

---

## 1. 🔴 합격 기준 (사용자 정의, 구속력 있음)

> "multi agent workflow 가 새로운 tool 을 만들 때 **아무런 에러 없이** 만들어야 하고,
>  그에 따라 **simulation demo 까지 정확히** 만들 수 있어야 한다"

| # | 기준 | 술어 | 현재 |
|---|---|---|---|
| A1 | multi-agent 가 만든다 | `ORACLE BYPASS` 배너 0건 · `expressible=False` | ✅ (런 6·8·10·11) |
| A2 | **에러 없다** | `registered=true` · `steps[1].status === :success` · `partial=false` | ✅ 런 6·8 |
| A3 | 도구가 일한다 | L3 `interface_calls ≠ []` · **L4 `world_delta_body` ≠ 0** | ❌ 전 판 0 |
| A4 | 데모가 정확히 나온다 | `PROJECT COMPLETE!` + `render_demo.jl` 이 **발행** | ❌ |
| A5 | 결과가 더 낫다 | 대조 INCOMPLETE(270/305) → 완주 | ❌ |

🔴 **A4 는 아직 한 번도 안 태웠다** — 전부 `DEMO_ANIM=0` 으로 돌렸다. 기본값은 `1` 이고,
미완주면 `error("refusing to publish incomplete animation …")` 로 발행을 거부한다.
**최종 판정 런은 `DEMO_ANIM=1` 로 한 번 돌려 발행까지 확인해야 한다.**

🔴 **오라클(`DEMO_SYNTH_FIXTURE`)은 A1 을 만족하지 않는다.** 수단이지 목표가 아니다.

---

## 2. 사건과 대조 — **zone 으로 확정**

```bash
DEMO_MODEL=tractor.mpd DEMO_OOD=none DEMO_ZONE=1 DEMO_CASE_TAG=zone_mild \
DEMO_POLICY=dspy DEMO_ANIM=0
```
🔴 **`DEMO_OOD=none` 이 필수** — `DEMO_OOD=zone*` 은 `case_kinds` 에서 **하드에러**다.
zone 은 직교 플래그 `DEMO_ZONE=1` 로 켠다. 사건은 **pre-sim** 에 주입되고 결정은 `closed=54` 에 난다.

| | 대조 (tool off) | 오라클 `OracleZoneClear!` |
|---|---|---|
| 완주 | **INCOMPLETE** | ✅ **COMPLETE** |
| `t` / `n_closed` | 5776 / 270 | 1022 / **287** |
| `total_energy_J` | 242615 | 90406 |

**목표 body (오라클이 증명)**: `active_restriction_zones` → `restage_all_blocked!` →
(거절 `:already_started`) → **`translate_whole_build!`**. **2단 확대가 필요하다.**
🔴 완주 판정은 `CB.project_complete` 이지 `n_closed == n_total` 이 **아니다**(완주해도 287/305).

**mild battery 는 폐기했다** — 오라클 3판으로 개선 불가 판정(N = −2.13 / 0.0 / −3.52).
근거 정본: `docs/superpowers/reports/2026-09-05-oracle-reassignment-refutes-the-premise.md`.

---

## 3. 지표 (mild 용으로 만들었으나 zone 에서도 유효)

- 잡음 바닥 = **정확히 0** [측정]: 같은 디렉토리 순차 실행. 처치·대조가 사건 **전** 프레임에서 바이트 동일.
- `min_soc` 은 `energy_J[대상]` 의 충실한 변환(1.208e-7 soc/J, 18구간).
- 척도 무관: `N = 1 − ΔE_처치/ΔE_대조`, 사건 프레임 **이후** 증분만.
- 🔴 **`_battery_load_features`(`tools/monitor/policy.jl`)가 payload 를 팀 크기로 안 나눠 프롬프트에
  넣는다 — 120쌍 중 9쌍(7.5%) 순위 역전.** 미수정. 옳은 것은 `cargo_burden_after`.

---

## 4. 오늘 착륙한 커밋 (전부 변이 증명 있음)

| 커밋 | 무엇 |
|---|---|
| `b3a62982` | `release_pending_assignments!` 광고. 🔴 `export` 만으론 무동작(`callable:false`) — `_CURATED_SEEDS` 필요 |
| `bca635f1` | `/rewrite` catch 가 첫 줄이 아니라 진짜 사유를 찍는다 |
| `c0cff8f3`+`b62133b4` | 프레임에 에너지 축(`total_energy_J`·`soc_spread`·로봇별 `energy_J`) |
| `09204a2c` | `ood_event_target()` — 사건 대상을 **id 객체**로 답한다 |
| `c444666d` | 모듈 비수식 짧은 agent 형식 수용 |
| `bc1e9d5b` | **S5** 인자 채널이 지어낸 로봇 정체를 못 나른다(`_is_generated` 게이트, 변이 5) |
| `b99c2ce3` | **오라클 우회** `DEMO_SYNTH_FIXTURE` — 시끄럽고, 폴백 없고, 게이트 안 낮춤 |
| `5a2ede9d` | `forbid_heavy_cargo!` 광고 (감춘 다섯 → 셋) |
| `7596d0b1` | **L4 여섯째 축** `n_staging_moved` — 기하 수리가 안 보였다 |
| `57a7d588` | zone **종단성**을 그래프 사실로 계산해 보고(비율이 아니라 술어) |
| `86b5be25` | **S6** 자리채움 토큰 차단(변이 7) |
| `ba11fa09` | **키워드인자 타입** 광고(37/44 메서드) |
| `2a18fe44` | **메서드 `returns`** 광고 (블록 33k→40k자) |
| `94bd8132` | **D17b** 되먹임을 집행 **예외**까지(변이 8). `allow_redefine` 필요 |
| `fbf6d17c` | **D17c** 되먹임을 **잰 무동작**까지(변이 10). 상한 1 을 런 전체에 강제 |
| `730951cd` | 🔴 **`/rewrite` 가 한 번도 성공 못 한 진짜 이유 = `retries = 0`**(죽은 keep-alive 소켓). `retry_non_idempotent=true` 가 하중을 진다 |
| `1f715885` | 되먹임 params 계승 — 우리 설치 코드가 **원본 스키마를 덮어쓰고 있었다** |
| `5dd9d7f4` | `DSPY_MODEL_TYPE` / `DSPY_TEMPERATURE` knob (responses 전송) |
| `24d910ea` | `DSPY_MAX_TOKENS` knob |

---

## 5. 유료 런 13판 — 실패가 매번 **키워드인자에서** 났다

| 런 | 모델 | L1 | L2b | L3 | L4 | 죽은 자리 |
|---|---|---|---|---|---|---|
| 1–5 | gpt-4o | | ❌ | | 0 | 필드명 → `"R1"` → kwarg 기본값 → `::Int64` → `["R2"]` |
| 6 | gpt-4o | ✅ | **✅ 최초** | ✅ | 0 | 좌표 튜플 · 거짓 `:success` |
| 7 | gpt-4o | ✅ | ❌ | — | 0 | `["goal1",…]` |
| 8 | gpt-4o | ✅ | — | ✅ | 0 | **조립된 Symbol · 무동작** (예측 적중) |
| 9 | gpt-4o | ✅ | — | — | 0 | 무동작 게이트 발화, `/rewrite` 왕복 실패 |
| 10 | gpt-4o | ✅ | — | — | 0 | 🔴 **`/rewrite` 사상 처음 서비스 도착** → 고친 body 가 `reject:param_type` |
| 11 | gpt-4o | ✅ | — | ❌ None | 0 | 되먹임 완주(`retried`) → 두 번째 body 가 **주석 스텁** |
| 12 | **sol** | — | — | — | — | 🔴 **전송 오류** — function tools + reasoning_effort 거부 |
| 13 | **sol** | — | — | — | — | 🔴 **blank decision** — 진단 중 |

🔴 **13판 다 "세계에게 묻지 않고 식별자를 지어냈다" 다.** 모양만 바뀌었다.
🔴 **런 12·13 은 배선에서 죽어 sol 능력을 관측하지 못했다.**

---

## 6. 🔵 진행 중 / 즉시 다음 수

1. **진행 중**: 런 13 blank decision 진단(서브에이전트 `task-sol-blank-report.md`).
   ⓑ `tool_lane_error`(빈/파싱 불가) 인지 ⓒ `tool_calls_n==0`(호출 없음) 인지 가른다.
   🔴 유력 가설: **responses 에서 출력 상한이 추론 토큰을 포함하고 절단이 조용하다**.
   대조 사실: 같은 모델·같은 전송·`tool_choice="required"` 의 **작은** 프로브(1296 토큰)는
   tool call 을 정상 반환했다 [측정]. 실제 프롬프트는 **40k자**다.
2. 그 뒤 서비스 재기동 → 런 14(sol) → **sol 의 첫 유효 관측**.
3. sol 이 통과하면 → `DEMO_ANIM=1` 로 최종 판정 런(A4).
4. sol 도 같은 자리에서 죽으면 → 남은 것은 설계 결함이고, `gpt-5.5-pro`($30/$180) 비교가 다음.

### 서비스 기동 (현행)
```bash
DSPY_MODEL=gpt-5.6-sol DSPY_MODEL_TYPE=responses DSPY_TEMPERATURE=none DSPY_MAX_TOKENS=16000 \
TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 DSPY_CACHE=0 \
.venv/bin/python -m uvicorn dspy_service:app --app-dir src/respec/llm_service \
  --host 127.0.0.1 --port 8077
```
🔴 `pkill -f "…port 8077"` **금지**(자기 셸을 죽인다). 포트별 PID 로 죽인다.
🔴 `/health` 200 은 세대 증거가 아니다 — `tools/require_current_service.sh` 로 판정.
✅ `_served_files` 가 `test_*.py` 를 **제외**하므로 pytest 만 고친 커밋은 재기동 불필요.

---

## 7. 🔴 이 세션이 되풀이해 밟은 것 — 다음 세션이 알아야 할 것

1. **"배선했다" ≠ "작동한다".** `/rewrite` 는 3커밋·25변이 증명·모든 시험 초록인 채로
   **라이브에서 단 한 번도 안 돌았다**. 원인은 `retries=0` 이었고, 모든 시험이 **스텁**을 상대로 돌았다.
   ⟹ **라이브 왕복을 요구하는 게이트 없이 채널을 완성했다고 하지 말 것.**
2. **프롬프트가 세계에 없는 결과를 주장했다** — 두 번. mild 는 "느리게 움직인다"(실측 계수 1.0),
   zone 은 심각도를 기하 겹침으로(실제 해악은 종단성). **모델을 탓하기 전에 서술이 참인지 재라.**
3. **규칙을 더하면 실패가 옮겨간다** — 5회 측정. 처방은 산문이 아니라 **기계 유도된 사실**
   (키워드 타입 · 반환 타입 · 종단성 술어)이어야 한다.
4. **자기신고를 판정에 쓰지 말 것.** `steps[1].status` 는 모델이 반환한 심볼이다.
   런 6 이 `:success` 를 냈는데 세계는 안 움직였다. 진실은 L4 다.
5. **n=1 로 판정하지 말 것.** 런 간 분산이 크다(런 6 최고 → 런 11 최악). 내가 이 실수를 했다.

---

## 8. 아직 안 닫힌 것

- `test/smdp_global_inventory.jl` **HEAD 에서 빨감**(선행 존재, 미분류 전역 20) — 이 레인 것 아님.
- `_battery_load_features` 의 7.5% 오류(§3).
- `translate_whole_build!` 의 반환이 `NamedTuple` 로만 광고돼 tier-2 상태 어휘가 안 보인다.
- `world_delta_body` 여섯 축은 배터리 스왑·`SPARE_POOLS`·fault 플래그·배송을 **안 본다**.
- 되먹임 두 번째 시도가 또 무동작이면 상한 1 이라 끝이다. 두 시도의 `impl_code` 동일 여부를 안 찍는다.

---

## 부록 A — 런 13·14 (`gpt-5.6-sol`) 와 **진짜 병목**

### A.1 런 13 은 모델이 죽인 게 아니다

`(no error field)` 는 빈 결정이 아니라 **무응답**이었다. `service_decide` 의 하드코딩
`readtimeout = 60` 이 원인이고 라이브 왕복은 **74.33초**다. 서비스는 그 뒤에 결정을
**완주했고** 그 기록이 디스크에 남았다. 고침 `f2339edf`(`DSPY_TIMEOUT_S`, 기본 300) ·
`fb657a67`(`/rewrite` 도 같은 손잡이). 정본: `client-timeouts-masquerade-as-empty-answers`.

### A.2 sol 의 능력은 **무료로** 관측됐다

런 13 의 완주된 기록(`synth_lane_records.jsonl.run13` 0행)에서:

| 항목 | 값 |
|---|---|
| `expressible` | `False` (A1 발화) |
| `tool_minted` / `impl_name` | `True` / `translate_build_scene!` |
| `stages` | `["observe","design","compose"]` |
| **등록 게이트** | **통과** — `check_impl_conventions` → `nothing` |

음성 대조 5/5 가 거절됨(bang 없음 · 위치인자 · 기본값 없는 kwarg · `impl_unknown_call` ·
`impl_unknown_field`)이므로 그 "통과" 는 체커의 조용한 무동작이 아니다.
**sol 은 오라클과 같은 기전(빌드 전체 이동)에 스스로 도달했다.**

### A.3 런 14 (라이브, `DSPY_TIMEOUT_S` 고침 후) — 완주했고, 실패했다

```
[minted] tool=relocate_scene_subtrees_for_goal_reachability verdict=reject
         registered=true n_calls=0 args_from=calls
[minted] world_delta=... n_staging_moved=0 world_delta_body=n/a(not measured)
PROJECT INCOMPLETE!
```
`registered=true` 지만 `calls == []` — 도구는 등록됐는데 **부를 것이 없다.**

### A.4 🔴 13판을 관통하는 상수: **`params` 가 한 번도 비지 않았다**

| run | impl_name | #params | #calls | match |
|---|---|---|---|---|
| 6 | ZoneBypassTool! | 3 | 1 | True |
| 7 | ExclusionZoneBypass! | 2 | 1 | True |
| 8 | ZoneBypassTool! | 3 | 1 | True |
| 9 | ExclusionZoneBypassTool! | 3 | 1 | True |
| 10 | ZoneBypassTool! | 3 | 1 | True |
| 11 | NavigationGoalBypass! | 3 | 1 | True |
| 13 | translate_build_scene! | 2 | 1 | True |
| 13 | relocate_unreachable_navigation_goals! | 1 | 0 | False |
| 14 | relocate_scene_subtrees_for_goal_reachability! | 1 | 0 | False |

**매개변수 0개인 도구는 한 번도 안 나왔다.** 그런데 이 사건을 실제로 복구시키는
오라클은 `params == {}` 이고 서명이 `(env)` 뿐이며, 정체를 인자로 받지 않고
광고된 질의 verb 로 **스스로 읽는다**.

두 실패 갈래는 **같은 뿌리**다: `params` 가 스칼라 2~3개면 작곡이 값을 **지어내고**,
중첩 정체 구조면 작곡이 **아무것도 못 낸다**.

### A.5 어휘는 구멍이 아니다 — 서술이 구멍이다

- 이 사건을 푸는 verb 는 블록에 **`callable: True`** 로 실려 있다(213 메서드 중). 모델은
  **보고도 안 불렀다.**
- `WriteToolImpl` 에는 이미 *"Prefer CALLING the functions the world interface lists as
  callable…"* 이 있고, 런 13 의 body 는 **그것을 어기지 않았다** — 목록에 있는 함수를
  불렀다(`set_desired_global_transform!`), 다만 **층위가 너무 낮았다.**
- 작곡 단계는 자유롭지 않았다. **설계 단계가 이미 "이동량을 매개변수로 받는 도구" 를
  명세해 버렸다.** 지어낸 상수 `(0, 0.25, 0)` 은 그 명세의 직접적 귀결이다.

⟹ 인과의 자리는 `synthesize.py` 의 `DesignToolSpec` 이다. docstring 이 *"name the
parameters the tool must take"* 라고 **요구**하는데, **매개변수가 정당할 조건**을 말하는
자리가 없다. 접지 개념은 `ungrounded_feedback` 에만 있고 그것은 (a) 재설계에서만 채워지고
(b) *"selects among behaviours"* 즉 거동 스위치만 겨냥한다 — 런 6~14 를 죽인
**세계 정체를 지어내는 축**을 안 겨냥한다.

### A.6 A4 에 대한 정정

완주 게이트(`render_demo.jl:1248`)는 **`DEMO_ANIM` 과 무관하게 무조건** 걸린다 —
그 **거절 절반은 이미 여러 번 태워졌다**(런 14 도 그렇게 죽었다). 다만 `DEMO_ANIM=0` 이면
애니메이션 자체가 저장되지 않아 `publish_anim!()` 이 즉시 `false` 다. 그러므로
**최종 판정 런은 여전히 `DEMO_ANIM=1` + 완주 둘 다 필요하다.**

---

## 부록 B — 🔴 부록 A 의 정정 (독립 반증 검증, 2026-09-05)

부록 A 를 반증하라고 붙인 검증 에이전트가 **네 군데를 뒤집었다.** 부록 A 의 표를 인용하기 전에
이 절을 읽을 것.

### B.1 분모가 틀렸다 — "13판" 이 아니라 **9개 합성**이다

`results/synth_lane_records.jsonl` 는 `.run14` 와 **md5 동일**이고, `.run13` 은 `.run14` 의
**바이트 접두**다(`head -c 20692 …run14` 의 md5 = `.run13`). 즉 부록 A 의 표는 같은 행을
세 번 셌다. 실제로는 **9개 서로 다른 zone 합성**이고 `n_params ∈ {1,1,2,2,3,3,3,3,3}`.

- 런 2~5 는 **battery 사건**이다(`OOD armed: zone×0 + battery×1`) — C1 범위 밖.
- 런 12 는 **합성 0건**이다(`LMInvalidRequestError … reasoning_effort … /v1/chat/completions`).
- 🔴 **런 13 은 세계에 닿지 않았다**: `grep -c minted run13-sol.log` = **0**, 두 행 다
  `registered` 가 `null`. 부록 A 의 "등록 게이트 통과" 는 **런 13 의 사실이 아니라
  검증자가 나중에 그 body 로 직접 잰 결과**다. 그 구분을 흐리지 말 것.

**결론(C1)은 그래도 산다**: 레포 전체 **178개 json/jsonl 에 `params == {}` 인 기록이 0건**이다.

### B.2 `"R1"` 은 zone 기록에 없다

battery 런의 값인데 내가 인계문서에서 그대로 물려받아 zone 표에 실었다. 실제로 지어낸 값은
`build_root_id = "root"` 와 `translation = {"x":0,"y":0.25,"z":0}` 다.
그리고 **9개 전부 `params_flat=False`** 다 — "스칼라 2~3개" 라는 서술도 틀렸다.

### B.3 "중첩 정체 구조면 작곡이 아무것도 못 낸다" 는 **반증됐다**

런 6(`navigation_goals: array-of-{goal_id,position}`) · 런 9(`affected_goals`) ·
런 11(`blocked_goals` + `alternative_routes` + `resource_allocation`)은 **중첩 정체 배열인데도
calls 를 1개씩 냈다.** n=9 에서 두 갈래를 실제로 가르는 것은 중첩성이 아니라
**`minItems:1` 이 붙은 단일 배열 매개변수**다(2/2 가 빈다).

### B.4 접지 규칙은 이미 어딘가에 있었다 — **작곡 단계에**

`world_interface.py::_RULES` 의 규칙 1·6 이 접지를 **명시한다**. 다만 그것은 agent-3(작곡)의
프롬프트다. 참인 서술은 "아무 데도 없다" 가 아니라 **"설계 단계(agent-2)에는 없다"** 이고,
그것이 접지 패치가 메우는 자리다.

### B.5 🔴 그래서 **지어낸 값이 태어난 자리는 설계가 아니라 `calls` 필드다**

런 14 의 `calls==[]` 는 작곡이 실패한 게 아니라 **규칙을 지킨** 것이다. agent-3 자신의 기록:

> *"The event account does not provide the three goal IDs, their ancestor scene-object IDs, or
> valid collision-free target poses, so a concrete invocation cannot be safely fabricated and
> `calls` is empty."*

그런데 그 정직함이 **거절된다**: `calls_match_body` 는
`[c["primitive"] for c in calls] == body_names` 라서 `[]` 는 `False` → `reject:calls_disagree_with_body`.
반면 `[{"primitive": <impl_name>, "args": {}}]` 는 **`True`** 이고 **그것이 오라클 fixture 의
모양**이다. 그런데 `calls` 필드 desc 는 *"the arguments to use for THIS event"* 뿐 —
**빈 `args` 가 정당하다는 말이 없다.** 모델에게 남은 선택지가 "지어내 채운다" 아니면
"통째로 비운다(=거절)" 둘뿐이었다.

⟹ 접지 규칙은 **필요조건이지 충분조건이 아니다.**

### B.6 🔴 접지 규칙만으로는 런 13 의 body 도 안 산다

그 body 는 매개변수 **필수**다(`build_root_id === nothing && throw(...)`). `args: {}` 로 부르면
**던진다.** `_RULES` 규칙 1 의 처방("기본값 `nothing`, body 가 env 에서 먼저 해소")을 정면으로
어긴다. `params` 를 비우는 것과 **body 가 인자 없이 동작하는 것**은 다른 요구다.

### B.7 "오라클과 같은 기전" 은 **verb 수준의 말**이다

`translate_whole_build!` 는 Δ 를 **스스로 푼다**(`_find_min_translation` →
`_find_clear_translation` → `_build_footprint`) 그리고 `_apply_uniform_translation!` 로
**모든 조립체의 `start_config` + 모든 `staging_circles` 를 옮기고** `_resync_scene_drift!` 까지
부른다. 런 13 의 body 는 Δ 를 **받아서** 노드 **하나**에 `set_desired_global_transform!` 한다.
**등록 가능 ≠ 옳다.**

### B.8 곁가지 결함 셋

- 🔴 `tractor__zone_mild.jsonl.run12` 와 `.run13` 이 **바이트 동일**하다. 런 13 의 스트림
  아카이브는 런 12 의 복사본이다 — 런 13 스트림으로 뭘 재면 런 12 를 재는 것이다.
- 🔴 `_is_placeholder_token` 은 **끝자리 숫자를 요구**한다(`^[A-Za-z]+[ _\-]?\d+$`).
  `"goal1"` 은 잡히는데 **`"root"` 는 안 잡힌다** — 그대로 body 로 흘러갔다.
- ⚠️ **모델 전환(4o → sol)이 산출물에서 유도되지 않는다.** 런 6~11 로그에 `4o` 문자열이
  0건이다. 프롬프트는 전 구간 동일하므로(`synthesize.py` 최종 변경 09-04 18:51) 풀링은
  안전하지만, **실패 양상을 6→14 로 이어 말하는 주장은 근거가 약하다.**

---

## 부록 C — 런 15, 그리고 부록 B.8 의 정정

### C.1 🔴 부록 B.8 의 "스트림 아카이브 버그" 는 **틀렸다** — 그것은 양성 대조다

`tractor__zone_mild.jsonl.run12 == .run13`(md5 `9c1a17cf…`)은 사실이지만 **보존 순서 버그가
아니다.** 실측:

| 파일 | md5 |
|---|---|
| `.run12` / `.run13` | `9c1a17cf…` (동일) |
| `.run14` | `6a139f6b…` |
| `.run15` | `e899c37e…` |

런 12(전송오류)와 런 13(시한초과)은 **둘 다 tool 이 세계에 닿기 전에 죽어 같은 폴백 사슬**로
갔다. 시드가 고정돼 있으므로 바이트 동일이 **나와야 맞다** — 이것은 결함이 아니라
**결정론의 양성 대조**다([[sim-runs-must-be-seed-reproducible]]). 런 14·15 는 `[minted]` 거절
행이 스트림에 들어가서 서로도, 앞 둘과도 다르다.
⟹ 검증자의 "곁가지 결함 1" 을 철회한다. 동료 세션 `chahj578-51` 의 mtime 대조가 옳았다.

### C.2 런 15 — 세 번째 빈 `calls`, 그리고 **모델의 자기 진술 2건**

| K | impl_name | params_top / chars | calls | match | expressible |
|---|---|---|---|---|---|
| 1 (런13) | `translate_build_scene!` | 2 / 401 | **1** | **True** | False |
| 2 (프로브) | `relocate_unreachable_navigation_goals!` | 1 / 1048 | 0 | False | False |
| 3 (런14) | `relocate_scene_subtrees_for_goal_reachability!` | 1 / 560 | 0 | False | False |
| 4 (런15) | `lift_deliver_blocked_goal_cargo!` | 1 / 332 | 0 | False | False |

🔴 **`needs` 는 `''` 다 — 어휘 부족으로 신고하지 않았다.** "어휘는 구멍이 아니다" 와 일치한다.

**판별식이 3/3 으로 유지된다**: `minItems:1` 이 붙은 **단일 배열 매개변수** → `calls` 빔.
런 15 는 `deliveries` 하나였다.

**그리고 추론이 아니라 모델의 자기 진술이다:**
- 런 14: *"...cannot be safely fabricated and `calls` is empty."*
- 런 15: *"No event-specific calls can be populated because **the account gives counts but
  omits the three goal-node and cargo identifiers**."*

동료 세션의 채널 분석이 그 원인을 이미 짚었다: 페이로드가 **기수만** 싣고,
`build_design_context` 는 `state` 를 안 받으며(*"that is the bottleneck"* 이라고 스스로 적혀
있다), `build_compose_context` 로 건너가는 것은 agent-1 의 산문뿐이다.

### C.3 🔴 `args=={}` 만으로도 안 끝난다 — 게이트가 하나 더 있다

`calls_match_body` 를 통과해도 `bind_primitive_args` 가 body 의 **필수 kwarg** 를 못 채우면
거절이고, 안 걸러지면 런타임에 `… === nothing && throw` 로 던진다.
⟹ **`params=={}`(agent-2)와 `args=={}`(agent-3)는 서로 다른 요구이고 둘 다 필요하다.**
그래서 접지 패치와 `calls` 패치가 **함께** 가야 한다.

### C.4 세대 경계선

**런 15 까지가 옛 설계 지시문 세대**(`7fa3065c21e1aa47`)다. 접지/`calls` 패치가 랜딩된 뒤의
런은 **다른 시스템**이므로 런 6~15 와 같은 표에 섞지 말 것.
