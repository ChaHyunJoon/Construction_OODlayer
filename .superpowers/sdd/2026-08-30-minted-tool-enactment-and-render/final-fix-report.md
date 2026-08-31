# 최종 수정 파동 — 다섯 번째 조용한 미복구와 그 옆의 여섯

> BASE `81ee7f8b` (브랜치 `oracle-rebuild-night-2026-08-10`). 유료 OpenAI 호출 **0건**,
> `render_demo.jl` 실행 **0건**, `127.0.0.1:8077`/`:8079` 로의 POST **0건**.
> 파이썬 소스 편집 **0건**(`dspy_service.py` 는 읽기만 했다 — 남의 미커밋 작업).
> `git add -A` / `git add .` / `git commit -a` **미사용** — 명시 경로만 인덱스에 넣었다.

## 0. 한 화면 요약

| # | 등급 | 상태 |
|---|---|---|
| 1 | CRITICAL | ✅ `handled` 에 `resume !== :failed` 연언지 추가. 게이트 (2) 정정 + 새 게이트 (2b) |
| 2 | CRITICAL | ✅ 반증된 등식을 게이트와 생산 docstring 양쪽에서 제거. 닿는 fixture 로 (4b) 신설 |
| 3 | IMPORTANT | ✅ `bind_primitive_args` 가 선언 타입 변환 실패를 **거절**로 바꾼다(최소 수정) |
| 4 | IMPORTANT | ✅ 조기 반환이 갈래마다 참인 사유 + 판별 키 다섯을 찍는다 |
| 5 | IMPORTANT | ✅ 합성 레인 교차언어 게이트 신설(줄리아 단독, 파이썬 편집 0) |
| 6 | MINOR | ✅ `WORLD_UNCHANGED_STATUSES` 문구 정정 |
| 7 | — | ✅ 마감 보고서 (a)(b)(c) 정정. (b) 는 스트림 파일에 대고 **직접 검증**했다 |

**스위트: `2082 passed / 0 failed / 1 errored` (Gurobi Error 10009).** 인수 기준 충족.
델타 **+77** (2005 기준) — 전부 새 단언이고 파일별로 정확히 설명된다(§3).

---

## 1. 각 발견, 무엇을 고쳤고 왜 그렇게 고쳤는가

### F1 (CRITICAL) — `resume=:failed` 인데 `handled=true`

`enact_minted_decision!` 이 `resume` 를 로그와 반환에 싣고도 **판정에 안 썼다.**
다섯 상태(`:issued` · `:failed` · `:not_needed_self` · `:not_needed_untouched` · `:none`)를
`enact_minted!` 의 표에서 유도하면, "프론티어가 낡았다" 를 뜻하는 것은 `:failed` 하나다 —
나머지 넷은 각각 "재개했다" · "원시가 스스로 했다" · "안 건드렸으니 필요 없다" · "아무것도
안 불렀다" 이다. 그래서 **`:failed` 하나만** 막는다(추측으로 넓히지 않았다):

```julia
local handled = (r.verdict === :admit) && r.world_maybe_dirty &&
                (r.resume !== :failed)
```

게이트: 옛 (2) 는 `resume === :failed` 와 `handled === true` 를 **함께** 단언해 버그를
인증하고 있었다. 이제 **같은 body·같은 던지는 지점, env 만 다른 쌍**이다 —
(2) 는 진짜 `OperatingSchedule` + `initialize_planning_cache` 를 든 env(재개 성공,
`active_set` 이 실제로 비워지는 것까지 관측) → `handled=true`;
(2b) 는 캐시 없는 env(재개 실패) → `handled=false` + `NOT handled` 폴백 문구.

### F2 (CRITICAL) — 반증된 규칙이 게이트와 생산 산문 양쪽에

R48 은 `world_maybe_dirty = touched || partial` 로 바꿨는데
`test_minted_wiring.jl` (4) 는 `applied || partial` 을 단언하고 있었고,
`enact_minted_decision!` docstring 도 같은 죽은 등식을 **가르치고** 있었다.

- (4) 는 이제 경계에서 관측 가능한 **참인 함의 둘**만 단언한다(`applied ⟹ dirty`,
  `partial ⟹ dirty`). `touched` 는 이 경계에 노출되지 않으므로 등식을 여기서 재적을 수 없다.
- 새 (4b) 가 "만졌는데 적응은 아님" status 에 **실제로 닿는다**: 오염 레지스트리로
  `restage_all_blocked` 의 impl 을 `process_schedule!` 로 돌려 `:unreadable_return` 을 낸다
  (`test/minted_tool_enacts.jl` (13-h) 의 정본 관용구). 결과 `applied=false · partial=false ·
  world_maybe_dirty=true` — 옛 등식이 값으로 거짓이 된다. 그리고 그 참이 **힘을 갖는다**:
  `handled=true` 로 폴백이 억제된다.
- docstring 은 정의를 `enact_minted!` 의 `_r` 하나에 위임한다(어휘 단일 진실원).

### F3 (IMPORTANT) — 타입 틀린 param 이 무동작을 `handled=true` 로

집행 가능한 여섯이 받는 **타입 있는** 키워드는 셋이다(레지스트리에서 실측):
`reform_stuck_teams!(env; min_ready::Int, snap_all::Bool)` ·
`force_advance_stuck_carrier!(env; tol::Float64)`.
리뷰어 triage 대로 **최소 수정**만 했다 — `PARAM_JSON_TYPES`(JSON-Schema `type` → Julia 타입)
+ `_param_type_reject`(선언 타입으로 `convert` 되는가). 스키마는 레지스트리 항목에서 오고
여기서 다시 안 적는다.

- 판정 기준이 `isa` 가 아니라 **`convert`** 인 이유: JSON 은 `2.0` 을 Float64 로 읽고
  `min_ready=2.0` 은 실제로 잘 도는 판이다. `isa` 로 재면 정상 판을 거절한다.
- 합집합 선언(`["string","null"]`)을 받는다 — 하나라도 변환되면 통과.
- 🔴 선언 없음/모르는 타입은 **거절**이다. 통과시키면 값 스키마를 넓히는 레지스트리 편집이
  게이트 전부 초록인 채로 호출 표면을 넓힌다(R46 의 확장 경로).
- 🔴 **전면 값 스키마 못박기(범위·enum·items)는 안 팠다** — R46 대로 parked 유지.

### F4 (IMPORTANT) — 조기 반환이 거짓말을 하고 증거를 버렸다

`sl !== nothing && reach === nothing` 갈래는 합성 레인이 **있는데도**
`reason=no synth lane on this decision` 을 찍었다. 이제 갈래마다 사유가 다르고,
`synthesis_event` · `synthesis_ran` · `synthesis_error` · `tool_minted` · `missing_primitive`
를 찍는다. 없는 값은 `nothing` 으로 찍는다 — `false` 로 접으면 "못 쟀다"와 "거짓이다"가
같은 관측이 된다(spec §9-2). 새 헬퍼 `_synth_lane_field` 가 String/Symbol 두 모양을 다 읽는다
(`policy.jl::_synth_view` 가 같은 이유로 같은 왕복을 한다).

### F5 (IMPORTANT) — `SYNTH_LANE_KEYS` 교차언어 그물

`test/synth_lane_keys_survive.jl` 에 `tool_lane_keys_survive.jl` (6)절의 관용구를 옮겼다.
값의 출처가 둘이라 그물도 둘이다:
(a) `dspy_service.py` 의 `out["dspy"]` 리터럴, `# ---- tool ` 표식 **위**에 `tool_minted` 와
그릇 `synthesis` 가 있는가; (b) `synthesize.py` 가 짓는 기록 dict 의 키가 `_SYNTH_RENAME` 을
통해 나머지 여덟을 덮는가. 사전은 `policy.jl` 것 하나를 쓰고 여기서 다시 안 적는다.
🔴 **파이썬 편집 0건** — `ast` 로 읽기만 하고, 음성 대조 셋은 전부 `mktempdir()` 안의 사본
위에서 일어난다. 모든 파이썬 호출은 `env -u OPENAI_API_KEY` 로 감쌌다. 못 닿으면 skip 이
아니라 **빨간색**이다.

### F6 (MINOR) — 문구

`WORLD_UNCHANGED_STATUSES` 의 "한 바이트도" → "세계 상태를 하나도 안 바꾸고" + 근거 주석:
`force_advance_stuck_carrier!` 는 `:no_carrier` 반환 **전에** `CARRIER_LAST_D[node_id(tu)] = d`
를 쓴다(실측). 분류는 그대로 옳다 — 그 dict 은 진행 메모이지 세계 상태가 아니고
(`clear_carrier_progress!` 가 언제든 통째로 비운다), 이 표가 재는 질문("폴백을 그 위에 쌓아도
되나")에 무관하다.

### F7 — 마감 보고서 정정 셋 (전부 **먼저 검증하고** 고쳤다)

**(a) 1607 은 산술이 아니라 실측이다.** 근거 셋을 직접 확인했다:
`task-1-report.md:78` — *"**1607 passed / 0 failed / 1 errored**"*;
커밋 `05f1d2b5` 메시지 — *"1607 pass / 0 fail / 1 error(Gurobi, 무관)"*;
`task-2-report.md:5` — *"delta +68 vs. prior 1607"*. §1-2 표의 해당 칸을 고쳤다.
나머지 둘(`0f895b46` 기준선 · T5 재구성 node id)은 **정당한 flag 라 그대로 뒀다.**

**(b) 사후 분석은 양쪽이 아니라 한쪽만 막혀 있다 — 그리고 유료 호출 1건은 낭비였다.**
`tools/monitor/streams/tractor__zone_minted.jsonl` 을 직접 집계했다(8,032,428 bytes, 115행):

```text
respec.input.policies.dspy (synthesis_event, synthesis_ran, synthesis_error, tool_minted, reach)
   (False, False, None, None, None)  ×115        # 115행 전부
집행 키 전수 검색(applied / partial / world_maybe_dirty / steps / resume / handled) → 히트 0건
```

즉 §2 가 "뭉갰다" 고 적은 세 상태의 판별값은 **이미 디스크에 있었다** — T5 의 세 번째 유료
`/macro` 프로브는 **필요하지 않았다.** 진짜로 없는 것은 **집행 결과**다. §3-9 · §7-2 · §0 ·
§2 · parked 표를 그렇게 고쳤고, 낭비된 유료 호출을 정직하게 적었다.

**(c) 세 매크로 이름의 소유자는 `test/smdp_stamp_smoke.jl` 이다.**
`@test ActionRegistry.NAME == Dict(0 => "NOOP", 1 => "Replace", 2 => "SwapBattery")` —
레포 전체에서 그 등식을 단언하는 줄리아 파일은 이것 하나다(`grep -rn "NAME =="`).
보고서가 지목한 `test/policy_macro_binding.jl` 은 이름을 리터럴로 **안 적는다** — 메뉴를
`ActionRegistry` 에서 뽑아 쓰고, 그 파일 자신의 주석이 *"여기에 `SwapBattery` 라고 적으면 이
파일이 어휘의 또 다른 사본이 된다"* 고 그 규약을 명시한다. §7-3 표를 고쳤다.

---

## 2. 🔴 변이시험 — 실제로 빨개지는 것을 봤다 (전부 되돌렸다)

> 실행: `julia +lts --project=. <게이트파일>`. 아래는 **실제 출력**이다.

### M1 — F1 의 연언지를 지운다 (`handled` 를 리뷰 이전으로)

```text
MUTATION M1 applied: resume 연언지 제거
(2b) 🔴 재개가 실패하면 handled=false 다 — 폴백을 삼키지 않는다: Test Failed at .../test_minted_wiring.jl:221
  Expression: occursin("NOT handled", out)
   Evaluated: occursin("NOT handled", "[minted] lane=present tool=MintedTool reach=composed verdict=admit
     applied=false partial=true world_maybe_dirty=true handled=true undo=none resume=failed
     steps=[translate_whole_build:threw] reason=body threw at translate_whole_build — 세계는 절반만
     고쳐졌을 수 있다(undo 없음) [resume=FAILED: type NamedTuple has no field cache — 🔴 프론티어가
     낡은 채로 남았다]\n[minted] ran_milp=false n_candidate_edges=n/a(no re-solve) closed=n/a\n")
Test Summary:                                                 | Pass  Fail  Total  Time
T4 배선 — 합성 tool 집행 진입점                               |  114     3    117  9.1s
  (2b) 🔴 재개가 실패하면 handled=false 다 — 폴백을 삼키지 않는다 |    5     3      8  2.3s
ERROR: LoadError: Some tests did not pass: 114 passed, 3 failed, 0 errored, 0 broken.
```

🔴 이 트랜스크립트 자체가 결함의 증거다: `resume=FAILED … 프론티어가 낡은 채로 남았다` 를
로그가 적으면서 같은 줄이 `handled=true` 라고 적는다. 실패는 **(2b) 세 줄에만** 걸린다.

### M2 — F2 의 규칙을 R48 이전으로 (`_r` 의 `touched||partial` → `applied||partial`)

```text
MUTATION M2 applied: _r 의 world_maybe_dirty 를 반증된 `applied || partial` 로 되돌린다
(4b) 🔴 옛 등식 `applied || partial` 은 거짓이다 — 닿는 fixture 로 못박는다: Test Failed at ...:296
(4b) ... Test Failed at ...:297
(4b) ... Test Failed at ...:299
  (4b) 🔴 옛 등식 `applied || partial` 은 거짓이다 — 닿는 fixture 로 못박는다 |    7     5     12   4.5s
ERROR: LoadError: Some tests did not pass: 112 passed, 5 failed, 0 errored, 0 broken.
```

### M2b — 🔴 **반대 방향**: 옛 등식을 정상 코드에 대고 단언하면 빨개진다

이것이 F2 의 핵심 주장("게이트가 옳은 코드를 상대로 빨개진다")의 직접 증거다.

```text
MUTATION M2b applied: 반증된 옛 규칙을 (4b) 의 fixture 에 대고 단언한다 (생산 코드는 정상)
(4b) 🔴 옛 등식 `applied || partial` 은 거짓이다 — 닿는 fixture 로 못박는다: Test Failed at ...:294
  Expression: r.world_maybe_dirty === (r.applied || r.partial)
   Evaluated: true === false
ERROR: LoadError: Some tests did not pass: 117 passed, 1 failed, 0 errored, 0 broken.
```

### M3 — F3 의 타입 검증 호출을 지운다 (= 리뷰 이전 상태)

```text
MUTATION M3 applied: bind_primitive_args 에서 타입 검증 호출을 지운다
(14) 선언된 타입으로 변환 안 되는 param 은 거절이다: Test Failed at .../minted_tool_enacts.jl:611
  Expression: bad isa String
   Evaluated: ((Base.RefValue{Symbol}(:e),), (snap_all = "true",)) isa String
(14) ... Test Failed at ...:626
  Expression: r.verdict === :reject
   Evaluated: admit === reject
(14) ... Test Failed at ...:627
  Expression: isempty(r.steps)
   Evaluated: isempty(NamedTuple[(name = "reform_stuck_teams", status = :threw,
     detail = "TypeError: in keyword argument min_ready, expected Int64, got a value of type Float64")])
(14) ... Test Failed at ...:628
  Expression: r.partial === false
   Evaluated: true === false
ERROR: LoadError: Some tests did not pass: 18 passed, 7 failed, 2 errored, 0 broken.
```

🔴 `status = :threw … expected Int64, got a value of type Float64` → `partial === true`.
**결함이 주장한 그대로다**: 세계는 손도 안 댔는데 `partial=true` 가 되어
`world_maybe_dirty=true` → `handled=true` 로 폴백이 삼켜진다.

### M3b / M3c — 타입 표와 "선언 없음" 판정이 하중을 진다

```text
MUTATION M3b applied: PARAM_JSON_TYPES["boolean"] => Any
  Expression: CB._param_type_reject(rf.params["snap_all"], "true") !== nothing
   Evaluated: nothing !== nothing
ERROR: LoadError: Some tests did not pass: 23 passed, 2 failed, 2 errored, 0 broken.

MUTATION M3c: `t === nothing && return "no_declared_type"` → `return nothing`
  Expression: CB._param_type_reject(Dict{String, Any}(), 1) == "no_declared_type"
   Evaluated: nothing == "no_declared_type"
ERROR: LoadError: Some tests did not pass: 26 passed, 1 failed, 0 errored, 0 broken.
```

### M4 — F4 의 조기 반환을 옛 하드코딩 사유로 되돌린다

```text
MUTATION M4 applied: 조기 반환 줄을 옛 하드코딩 사유로 되돌리고 판별 키를 버린다
(1) ...: Test Failed at .../test_minted_wiring.jl:173
  Expression: occursin("synthesis_event=true", out4)
   Evaluated: occursin("synthesis_event=true", "[minted] lane=reach_nothing tool=MintedTool reach=n/a
     verdict=deferred applied=false partial=false world_maybe_dirty=false handled=false undo=none
     resume=none steps=[] ran_milp=n/a(not armed) reason=no synth lane on this decision\n…")
(1) ...: Test Failed at ...:179
  Expression: !(occursin("no synth lane", r4.reason))
   Evaluated: !(occursin("no synth lane", "no synth lane on this decision"))
(1) ...: Test Failed at ...:180
  Expression: r4.reason != r.reason
   Evaluated: "no synth lane on this decision" != "no synth lane on this decision"
```

(총 9줄 red, 전부 (1) 안. 🔴 마지막 두 줄이 **거짓 진술 그 자체**를 보여준다 — 레인이 있는
갈래와 없는 갈래가 글자 그대로 같은 사유를 냈다.)

### M5 / M5b — F5 의 교차언어 그물 (생산 파이썬 소스는 **안 건드렸다**)

```text
MUTATION M5: 파이썬 synthesize.py 사본에서 "ran" 을 개명 (생산 소스 무변경)
🔴 교차언어 — 합성 아홉이 파이썬 소스에 묶여 있다: Test Failed at .../synth_lane_keys_survive.jl:242
  Expression: get(_SYNTH_RENAME, k, k) in rec
   Evaluated: "ran" in Set(["canon", "psi", "mechanism", … "synthesis_event", "kind", …])
ERROR: LoadError: Some tests did not pass: 15 passed, 1 failed, 0 errored, 0 broken.

MUTATION M5b: dspy_service.py 사본에서 out["dspy"] 의 "synthesis" 를 개명
  Expression: "synthesis" in above
   Evaluated: "synthesis" in Set(["policy", "rationale", "error", "ranking", "tool_minted",
     "tool_args_forced", "synthesis_renamed", "chosen", "coerced", "tool_called_forced", "margin"])
ERROR: LoadError: Some tests did not pass: 15 passed, 1 failed, 0 errored, 0 broken.
```

🔴 M5 가 F5 가 서술한 정확한 시나리오다 — 이 게이트 **이전에는** 같은 개명이 줄리아 게이트를
하나도 안 건드렸다(그 그물이 존재하지 않았으므로).

게이트 자신도 같은 변이 셋을 **매 실행마다** 사본 위에서 돌려 음성 대조를 유지한다.

### 되돌림 확인

세 게이트 파일 전부 다시 초록으로 돌아오는 것을 확인했고, `git diff` 에 변이가 남아 있지
않다(§4 의 파일 목록이 커밋한 것의 전부다). 생산 파이썬(`synthesize.py`)은 `git diff` 에
**나타나지 않는다** — 한 글자도 안 고쳤다.

---

## 3. 스위트 · 델타

```text
julia +lts --project=. -e 'using Pkg; Pkg.test()'
  minted tool wiring (tools/monitor/test_minted_wiring.jl) |  117           117     2.1s
ERROR: LoadError: Some tests did not pass: 2082 passed, 0 failed, 1 errored, 0 broken.
```

`fail == 0` · `error == 1`(Gurobi Error 10009, 이 계획 이전부터 존재) — **인수 기준 충족.**

**델타 +77 (2005 → 2082), 전부 새 단언이다.** 파일별로 HEAD 사본을 그 자리에 놓고
직접 재서 분해했다(측정이지 산술이 아니다):

| 파일 | HEAD | 지금 | 델타 | 무엇 |
|---|---|---|---|---|
| `tools/monitor/test_minted_wiring.jl` | 83 | 117 | **+34** | (1b) 판별 키 9 · (2)/(2b) 재구성 +9 · (4) 함의 +2 · (4b) 신설 12 · 기타 정리 |
| `test/minted_tool_enacts.jl` | 247 | 274 | **+27** | (14) 타입 검증 게이트 |
| `test/synth_lane_keys_survive.jl` | 46 | 62 | **+16** | 교차언어 절(단언 10 + 음성 대조 6) |
| 합 | | | **+77** | 2005 + 77 = **2082** ✅ |

⚠️ HEAD 사본으로 잰 `test_minted_wiring.jl` 은 `80 passed / 3 failed` 로 나왔다 — 그 3건은
**옛 게이트 (2) 가 고쳐진 `handled` 를 상대로 낸 실패**이고(= F1 의 "게이트가 버그를
인증한다" 의 반대 방향 증거), HEAD 코드에서의 총 단언 수는 83 이다.

감소한 단언 **0건**. 생산 코드의 동작 회귀로 인한 pass 감소 **없음**.

---

## 4. 커밋 위생

🔴 작업 트리는 236건의 미커밋 변경(212+ 삭제 + 남의 진행 중 작업 `tools/monitor/policy.jl` ·
`tools/monitor/lane_select.jl` · `src/respec/llm_service/dspy_service.py` ·
`test/tool_lane_keys_survive.jl` 등)을 안고 있다. **`git add -A` / `git add .` /
`git commit -a` 를 한 번도 쓰지 않았다** — 아래 경로만 명시적으로 인덱스에 넣었다.

```text
tools/monitor/enact.jl                  (F1 · F2 docstring · F4)
src/respec/minted_tool.jl               (F3 · F6)
tools/monitor/test_minted_wiring.jl     (F1 게이트 · F2 게이트 · F4 게이트)
test/minted_tool_enacts.jl              (F3 게이트)
test/synth_lane_keys_survive.jl         (F5 게이트)
docs/superpowers/reports/2026-08-30-minted-tool-enactment.md   (F7)
.superpowers/sdd/2026-08-30-minted-tool-enactment-and-render/progress.md        (R50~R55)
.superpowers/sdd/2026-08-30-minted-tool-enactment-and-render/final-fix-report.md (이 파일)
```

새 줄리아 시험 **파일**은 만들지 않았다 — 세 게이트 전부 `test/runtests.jl` 에 **이미 등재된**
파일에 절을 더한 것이다(`runtests.jl:192` · `:374` · `:392`). 따라서 등재 누락이 없다.

---

## 5. 남은 것 · 이 초록이 무엇의 증거가 **아닌가**

1. 🔴 **`resume=:issued` 와 `handled=true` 는 여전히 진짜 빌드에서 실행된 적이 없다.**
   이번 파동도 그것을 바꾸지 않았다(렌더 금지). 게이트는 판정의 유무를 못박을 뿐이고,
   원증상(낡은 프론티어 ⇒ 복구 무효)은 full run 이라야 관측된다.
2. 🔴 **undo 는 여전히 없다**(Plan B 의 C 단계). F1 의 수정은 "재개 실패 시 폴백을 살린다" 이지
   "절반 고쳐진 세계를 되돌린다" 가 아니다. 그 판에서는 폴백이 절반 고쳐진 세계 위로 간다 —
   조용한 미복구보다 낫다는 판단이고(R50), **그 판단이 이 파동에서 유일하게 값을 치른 자리다.**
3. **R46(레지스트리 값 스키마 전면 못박기)는 그대로 parked.** F3 은 `type` 한 축만 본다 —
   `minimum`/`maximum`/`enum`/`items` 는 아무도 안 본다. 오늘 그 값이 live 원시에 닿는 표면은
   `zone_keys`(이미 강제 변환·확인)와 위 세 스칼라뿐이라는 것이 그 parking 의 근거다.
4. **R45(`recover_stalled_teams!` 의 `:restaged` 가 숨기는 한 겹 더 깊은 침묵 성공)도 그대로.**
   그 원시가 body 에 들어가는 순간 이 레인의 `applied` 는 다시 신뢰할 수 없다.
5. **F5 의 그물은 "이름이 존재하는가" 만 잰다** — 값의 의미가 파이썬에서 바뀌는 회귀는
   여전히 못 잡는다. 그 자리는 루프백 게이트(`tool_lane_keys_survive.jl`)의 몫이고, 그 파일은
   지금 남의 미커밋 편집을 안고 있어 이 파동이 건드리지 않았다.
6. **스위트 숫자는 커밋의 값이 아니라 작업 트리의 값이다** — 이 트리에는 남의 미커밋 작업이
   있다(마감 보고서 §1-1 의 같은 caveat).
