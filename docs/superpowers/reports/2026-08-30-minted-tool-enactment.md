# 합성 tool 이 세계를 고치는 레인 — 어디서 멈췄고, 이 초록이 무엇의 증거가 **아닌가**

> **범위.** 계획서 `docs/superpowers/plans/2026-08-30-minted-tool-enactment-and-render.md`
> (상위 권위: `docs/superpowers/specs/2026-08-26-tool-synthesis-lane-design.md`) 의 **마감
> 산출물**이다. 원장은 `.superpowers/sdd/2026-08-30-minted-tool-enactment-and-render/progress.md`,
> 검증 5라운드는 같은 디렉토리의 `validation-round{1,2,3,4,5}.md`.
> 브랜치 `oracle-rebuild-night-2026-08-10`, 착수 HEAD `0f895b46` → 종료 HEAD `86b7eb35`.
>
> 🔴 **이 계획은 완주하지 않았다.** T8·T0·T1·T2·T3·T4 가 들어갔고, **T5(분수령)에서 계획서
> 자신의 정지 규칙에 걸려 멈췄다.** T6·T7·T9 는 **한 줄도 구현되지 않았다** — 사용자 결정
> D-B 때문이다. 이 문서는 성공 보고가 아니라 **측정 보고**이고, 가장 값나가는 부분은 §3(무엇의
> 증거가 아닌가)과 §4(계획서 자신이 반증당한 목록)다.
>
> **이 문서의 인용 규약(§1-1, R15):** 실행 파일은 **줄번호가 아니라 심볼로** 인용한다.
> 계획서 §0 이 줄번호로 10건 인용했고 **그중 하나가 죽은 코드를 가리켰다** — §4 를 보라.

---

## 0. 한 화면 요약

배선(Phase A)과 인터프리터(Phase B)와 렌더 집행(Phase C 전반)은 **들어갔고 게이트가 붙었다.**
그리고 T5 의 첫 라이브 판에서 **합성은 발화하지 않았다.** 이유는 배선도 알파벳도 아니고
**모델이 `expressible: true` 라고 답했기 때문이다** — 이 사건이 닫힌 어휘(`["NOOP"]`) 안에서
표현 가능하다는 모델의 판정. 그것이 계획서 T5 Step 3 의 정지 규칙(*"배선 셋을 확인한 뒤
사용자에게 올린다. 프롬프트로 뒤집지 않는다"*)을 그대로 발동시켰다.

사용자 결정(원장 말미, 2026-08-30):

| | 결정 | 귀결 |
|---|---|---|
| **D-A** | zone 레인: 모델의 **관측 채널을 넓히지 않는다** | `_zones_block` 에 아무것도 더하지 않는다. zone 레인은 `expressible=true` 라는 **측정 결과로 닫힌다** |
| **D-B** | Phase D: **레버를 재설계한 뒤 진행한다** | T6/T7/T9 를 설계대로 집행하지 않는다(라운드 4 가 그 레버를 **무동작**으로 실측했다). 재설계는 별도 작업이고 §6 이 그 출발점이다 |

유료 OpenAI 호출은 이 세션 전체에서 **5건**이다 — T0 의 기준선 2판(2건)과 T5(보드 1판 +
`/macro` 프로브 2건 = 3건). 🔴 **검증 5라운드는 전부 유료 0건**이었고, §4 의 반증 전부가
**유료 판을 쓰기 전에** 나왔다.

---

## 1. 착수·종료 실측

### 1-1. 두 스위트

| | 착수 (`0f895b46`) | 종료 (`86b7eb35`) |
|---|---|---|
| `Pkg.test()` | **1553 pass / 0 fail / 1 error — 추론값, 측정 아님** (아래) | **2005 pass / 0 fail / 1 error** (이 보고서를 쓰며 재유도) |
| `pytest src/respec/llm_service/` | 194 passed / 5 skipped (라운드 1 이 재유도) | **194 passed / 5 skipped** (이 보고서를 쓰며 재실행) |

**🔴 계획서 §1-3 이 적은 "기준선 1487 pass" 는 낡았다.** 그 숫자는
`docs/superpowers/reports/2026-08-29-gap-closure-session.md` 의 **종료값**이고, 이 세션은
`0f895b46` 에서 스위트를 **따로 재지 않았다**. 그러므로 착수값은 **측정된 적이 없다.**
유일한 사전 관측은 T8 의 첫(결함 있는) 실행 — `task-8-report.md` 가 인용한
`1553 pass / 2 error`(Demo 의 Gurobi + T8 자신의 게이트 error) 이고, 여기서 T8 게이트의
error 를 빼면 착수 트리는 `1553 pass / 0 fail / 1 error` 였을 것이다. **이것은 산술이지
측정이 아니다.** 계획서의 1487 과 이 1553 의 차(66)는 이 세션이 설명할 수 있는 양이 아니다 —
두 값은 서로 다른 두 커밋의 값이고, 그 사이 구간은 이 계획의 범위 밖이다.

**재유도한 명령(이 보고서 작성 시점, 작업 트리 그대로):**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'
#  → ERROR: LoadError: Some tests did not pass: 2005 passed, 0 failed, 1 errored, 0 broken.
.venv/bin/python -m pytest src/respec/llm_service/ --ignore=src/respec/llm_service/test_propose.py -q
#  → 194 passed, 5 skipped, 2 warnings in 12.32s
```

⚠️ 두 값 다 **작업 트리**의 값이지 커밋의 값이 아니다. 이 트리에는 남의 미커밋 작업이 있다
(`tools/monitor/policy.jl`·`tools/monitor/lane_select.jl`·`src/respec/llm_service/dspy_service.py`
및 212건의 미커밋 삭제). 파이썬 숫자는 특히 그렇다 — `dspy_service.py` 가 수정된 상태다.

**그 1 error 는 Gurobi 라이선스다.** `task-8-report.md` 가 인용한 그대로:
`Demo | 1 error (Gurobi Error 10009: No Gurobi license found — 기대된 것, T8 이전부터 존재)`.
이 계획의 변경과 무관하고, 착수·종료 두 시점에서 **개수가 같다**.

### 1-2. pass 델타를 태스크별로, 어느 게이트의 단언인지까지

| 커밋 | 태스크 | pass | 델타 | 그 델타를 낸 단언 |
|---|---|---|---|---|
| (착수, 추론) | — | 1553 | — | — |
| `9c8e8b26`→`3196928a` | T8 | 1561 | **+8** | `test/mild_menu_is_noop_only.jl` 의 8단언 (`task-8-report.md`) |
| `05f1d2b5` | T1 | *1607* | **+46** | `test/synth_lane_keys_survive.jl` 의 testset 합 1+12+19+4+10 (원장·T1 보고 둘 다 **절대값은 안 적는다** — 1607 은 1561+46 의 산술이다) |
| `d9c00896`→`cca671ec` | T2 | 1675 | **+68** | `test/minted_tool_resolves.jl` 의 새 testset 합 (원장) |
| `5b9dec28` | T3 | 1739 | **+64** | `test/minted_tool_enacts.jl` 의 단언 수 (`task-3-report.md`: *"델타: 1675 → 1739 = +64. 정확히 `minted_tool_enacts` 의 단언 수다"*) |
| `29cb0a1d` | T3 fix | 1834 | **+95** | 같은 파일이 12 testset · 159 단언으로 커짐. 🔴 **원장과 T3 재리뷰는 이 구간을 "1675 → 1834 = +159 = 게이트 단언 수" 로 적는다** — 즉 같은 증가를 두 방식으로 분해한 것이고, 두 인용 모두 남긴다 |
| `02aa5b9e` | T4 | 1913 | **+79** | `tools/monitor/test_minted_wiring.jl` 의 79단언 (`task-4-report.md`: *"델타 +79 = 신규 게이트 79단언, 정확히 일치"*) |
| `fa59eebf` | T4 fix | **2005** | **+92** | 캐시 재개 표(`PRIMITIVE_RESUMES_CACHE`) + `WORLD_UNCHANGED_STATUSES` 분리의 새 단언 (원장) |

**모든 델타가 새 게이트의 단언이다. 삭제된 단언은 한 건**(T3 fix 가 버그를 못박던
`_step_applied("resolve_schedule_wedge", :whatever) === true` 를 지우고 status 별 단언 28개로
교체) 이고, 그 교체는 순증 안에 흡수돼 있다. 생산 코드의 동작 회귀로 인한 pass 감소는 **없다**.

### 1-3. 인수 기준은 pass 문턱이 아니었다 (R11)

이 계획이 실제로 쓴 인수 기준은 **`fail == 0 && error == 1`(Gurobi) + pass 델타가 설명
가능할 것**이다. 계획서 초안의 `pass ≥ 1487` 문턱은 **폐기했다.** 이유는 그 1487 을 낸
보고서(`2026-08-29-gap-closure-session.md`)가 스스로 *"pass 감소를 회귀로 읽지 말 것"* 이라고
적고 **1503 → 1487 로 낮춘 fix 를 기록**하기 때문이다 — 단언 삭제는 정상적인 감소이고,
`tools/test_policy_escalation.jl` 처럼 서브프로세스로 도는 파일의 손실은 **pass 수에 구조적으로
안 보인다.** 문턱은 그 둘을 구분하지 못한다.

⚠️ **이 기준의 사각지대는 기록해 둔다:** 회귀가 오직 pass **감소**로만 나타나면 `fail==0` 은
그것을 못 잡는다. 그래서 "델타가 설명 가능할 것" 이 조건으로 붙었고, §1-2 표가 그 조건을
이행한 것이다.

---

## 2. 판 대조표 — **판은 셋이지 넷이 아니다**

계획서 Task 10 은 네 판(zone_before · zone_minted · battery_mild_before · battery_mild_minted)의
대조표를 요구한다. 🔴 **`battery_mild_minted` 는 존재하지 않는다.** 그 판을 만드는 태스크가
T9 이고, T9 는 T6·T7 과 함께 **사용자 결정 D-B 로 집행되지 않았다**(라운드 4 가 그 레버를
무동작으로 실측했으므로). 없는 판을 표에 빈칸으로 두는 대신 그 사실을 여기 적는다.

| 판 | 파일 | 레인 | 유료 |
|---|---|---|---|
| `zone_before` | `results/baseline_2026-08-30/zone_before.log` | `DEMO_ZONE=1 DEMO_POLICY=router DEMO_ROUTER=auto` (R23) | 1 |
| `battery_mild_before` | `results/baseline_2026-08-30/battery_mild_before.log` | 같은 레인 | 1 |
| `zone_minted` | `results/2026-08-30-zone-minted/render.log` | 같은 레인 + T1~T4 배선 | 1 (+ `/macro` 프로브 2) |

### 판별 인용 (로그에서 그대로, `tr '\r' '\n'` 후)

**`zone_before`**

```
[zone] blocking zone on transport vtx=143 @[1.094, 0.416] r=0.07 -> nav_blocked=3/131
[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM (kind=unknown:zone, axis=ood_kind)
[policy] ZoneTruth → NOOP (enacted=dspy; rule=NOOP)
[enact] target=- source=none tool_agent=- verify=deferred:no_groundable_param reject=no_tool_agent
PROJECT INCOMPLETE!
```
`[minted]` 줄 **없음** — 이 판은 T4 **이전**이라 그 계측 자체가 코드에 없다. 이 부재는
합성에 대한 관측이 **아니다.**

**`battery_mild_before`**

```
[ood] battery fired at step≈601 closed=245
[router] 'unknown:battery_mild' is outside the surrogate's training kinds → escalate to LLM (kind=unknown:battery_mild, axis=ood_kind)
[policy] BatteryTruth → NOOP (enacted=dspy; rule=NOOP)
[enact] target=ConstructionBots.BotID{ConstructionBots.DeliveryBot}(1) source=truth tool_agent=- verify=deferred:no_groundable_param reject=no_tool_agent
PROJECT COMPLETE!
```
`[zone]` 줄 없음(존을 안 쐈다), `[minted]` 줄 없음(T4 이전).
🔴 그리고 **`[recover]` 도 `SILENT-FALLBACK` 도 한 줄도 없다** — T0 이 R1 의 **뒤집은 기대값**
으로 심은 계측이 침묵했고, 그것이 `enact_recovery!` 가 죽은 코드라는 실측 확인이다(§4 참조).
그 결과 이 판은 **무개입 판**이다. 같은 로그가 결정 시점을 `closed=245`, `n_total: 305` 로
찍는다.

**`zone_minted`**

```
[zone] blocking zone on transport vtx=153 @[1.094, 0.416] r=0.07 -> nav_blocked=3/131
[zone] diag n_blocked=3 n_nav_blocked=3 root_covered=0/8 n_work_overlap=6 n_teams_covered=0 n_nav_goals=131 n_nav_engulfed=3 n_agent_trapped=0
[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM (kind=unknown:zone, axis=ood_kind)
[policy] ZoneTruth → NOOP (enacted=dspy; rule=NOOP)
[enact] target=- source=none tool_agent=- verify=deferred:no_groundable_param reject=no_tool_agent
[minted] lane=reach_nothing tool=n/a reach=n/a verdict=deferred applied=false partial=false world_maybe_dirty=false handled=false undo=none resume=none steps=[] ran_milp=n/a(not armed) reason=no synth lane on this decision
[minted] NOT handled → 기본 복구 사슬로 폴백한다 (이 폴백은 조용하지 않다 — 위 verdict 가 이유다)
PROJECT INCOMPLETE!
```

### 이 표에서 읽히는 것과 읽히지 않는 것

- **`zone_before` 와 `zone_minted` 의 결과는 같다**: `NOOP` → `PROJECT INCOMPLETE!` →
  애니메이션 발행 거부(`refusing to publish incomplete animation for model=tractor.mpd
  case=none`). 계획서가 겨냥한 산출물 ①(`tractor__zone_minted.html`)은 **생기지 않았다.**
- ⚠️ **두 zone 판은 바이트 동일하지 않다**: 주입 정점이 `vtx=143` → `vtx=153` 으로 다르다.
  중심 `[1.094, 0.416]`·반지름 `0.07`·`nav_blocked=3/131` 은 동일하다(T5 보고가 같은 것을
  적는다). 즉 두 판은 **같은 기하의 다른 정점**이고, 완전한 재현이 아니다.
- `zone_minted` 의 `steps=[]` 와 `ran_milp=n/a(not armed)` 는 **인터프리터가 한 번도 안
  불렸다**는 뜻이다. 배선은 그 앞에서 끝났다.
- 🔴 `[minted] lane=reach_nothing` 한 줄이 **세 상태를 뭉갠다** — "expressible=true 라서 안
  쐈다" · "expressible 을 못 쟀다(None)" · "쐈는데 오류" 가 글자 그대로 같은 줄을 낸다.
  이것 때문에 원인 판별에 **유료 호출을 하나 더 썼다**(T5 보고 §7 우려 ①). 그 세 번째 호출이
  `zones`·`routing_kind` 를 실은 프롬프트에서 `expressible: true`, `tool_called:
  no_intervention`, `tool_arg_error: null` 을 관측해 (b)와 (c)를 배제했다.

---

## 3. 🔴 이 작업이 **무엇의 증거가 아닌가**

이 절이 이 보고서의 요점이다.

1. **판은 각각 n=1 이다.** 시드 하나, 모델 하나(`gpt-4o`), LEGO 모델 하나(`tractor.mpd`),
   로봇 10대. **인과의 증거가 아니고 비율의 증거도 아니다.** 세 판 중 둘은 같은 결과를 냈지만
   그것은 재현이 아니라 관측 둘이다(게다가 주입 정점이 다르다, §2).

2. **`expressible=false` 비율은 부분적으로 프롬프트 준수를 잰다.** `expressible` 은 모델의
   **tool 호출 인자**에서만 온다(`dspy_service.py` 의 `tool_args_all.get("expressible")`, bool
   이 아니면 `None`). 모델이 그 인자를 생략하면 합성은 **조용히** 안 쏘고 로그는 같은 줄을
   낸다. 즉 이 축의 어떤 비율도 "모델의 추론" 과 "모델의 인자 성실성" 을 섞고 있다.

3. 🔴 **계획서 §0 [16] 은 반증됐다 — `battery_mild` 기준선은 무개입 판이다.**
   계획서는 `render_demo.jl :: enact_recovery!` 가 LLM 의 NOOP 을 무시하고
   `rebalance_for_battery!` 를 돌린다고 적었다. 라운드 1(E-1)이 **호출자 0개**를 보였고,
   T0 의 계측이 **한 줄도 안 찍힘**으로 그것을 실측 확인했다.
   ⟹ **앞으로의 어떤 대조도 "무개입 vs X" 로 적어야 한다.** 계획서 Task 10 이 지시한
   *"SoC 만 본 재가격 vs SoC×payload 재가격"* 이라는 문장은 **거짓이다.** 그 문장을 쓰면
   존재한 적 없는 개입을 대조군으로 세우는 것이다.

4. **mild 메뉴가 `["NOOP"]` 인 것은 이 작업이 만든 조건이 아니다.** 2026-08-25 부터 그랬고
   (`ActionRegistry.battery_arms`, `action_registry.jl` 의 docstring 이 zone 과 같은 논증으로
   적는다), T8 은 그것을 **확인하고 게이트로 못박았을 뿐**이다
   (`test/mild_menu_is_noop_only.jl`). "메뉴를 좁혀서 합성이 터졌다" 로 읽으면 거짓이다.
   — 덧붙여 이번 판에서는 합성이 **터지지도 않았다.**

5. **undo 가 없다.** Plan B 의 C 단계(연산 단위 안전층 + 국소 undo)는 이 계획의 범위 밖이고
   (계획서 §1-2·§5), body 중간에서 실패한 tool 은 세계를 절반만 고친 채 남는다. 결정 행이
   그것을 `undo=none` 으로 박는다(§2 의 `[minted]` 줄에 실제로 찍혀 있다).
   🔴 **이 배선으로 스윕을 돌리면 안 된다.**

6. 🔴 **알파벳은 19 넓지만 집행 가능한 것은 6 뿐이다.**
   `test/minted_tool_enacts.jl :: ENACTABLE_TODAY` 가 그 여섯을 이름으로 못박는다 —
   `force_advance_stuck_carrier` · `recover_stalled_teams` · `reform_stuck_teams` ·
   `resolve_schedule_wedge` · `restage_all_blocked` · `translate_whole_build`.
   나머지 13은 세 연언지 판정식(`harness_args ⊆ {"env"}` **and** `nargs-1 ==
   length(harness_args)` **and** `keys(params) ⊆ kwarg_decl`) 중 하나가 깨져 **부르기 전에**
   거절되고, 거절 라벨은 넷이다(`harness | multimethod | arity | kwargs`).
   ⟹ **"모델의 조합 능력" 에 대한 어떤 주장도 이 6/19 에 갇혀 있다.** 그리고 그 격차는
   **하네스의 성질이지 모델의 성질이 아니다.** 합성 프롬프트는 19개를 다 보여주므로 높은
   reject 율은 정상 동작이다(R40).

7. 🔴 **`resume=:issued` 와 `handled=true` 경로는 진짜 빌드에서 아직 한 번도 실행되지
   않았다.** T4 가 그 둘을 신설하고 게이트를 붙였지만(진짜 `OperatingSchedule` +
   `initialize_planning_cache` 에 낡은 `active_set` 을 심은 양성/음성 대조 (13-e)/(13-f)),
   T5 의 판은 인터프리터를 **한 번도 부르지 않았다**(`steps=[]`). 게이트는 재개의 유무를
   못박을 뿐이고, 원증상(낡은 프론티어 ⇒ 복구 무효)은 full run 이라야 관측된다.
   **"이 경로는 검증됐다" 로 읽으면 안 된다 — "게이트가 있고 실행된 적은 없다" 다.**

8. **parked 결함 하나가 `applied` 의 신뢰 범위를 정한다.** `recover_stalled_teams!` 의
   `:restaged` 는 **한 겹 더 깊은 침묵 성공을 숨긴다** — 중첩된 `restage_*` 가 `:none` 을
   냈어도 이쪽은 `:restaged` 로 보고한다. R45 가 그것을 **의도적으로 안 팠다**(이 계획이
   겨냥한 두 body 에 그 원시가 없으므로). 🔴 **그 원시가 body 에 들어가는 순간 이 레인의
   `applied` 는 더 이상 신뢰할 수 없다.** 다만 `steps` 에 status 가 그대로 남으므로 사후
   판별은 가능하다.

9. **결정 JSON 에 합성 집행의 흔적이 없다.** `record_decision!` 이 배선보다 먼저 돌고 수정되지
   않았다(채점기 비오염을 위한 의도된 설계). 그래서 사후 분석은 **stdout 파싱**뿐인데, 그
   stdout 이 위 §2 대로 lossy 하다. **현재 사후분석 경로는 양쪽 다 막혀 있다.**

---

## 4. 🔴 계획서 자신의 주장 중 검증이 **반증한** 것

검증은 다섯 라운드 돌았고 **전부 유료 호출 0건**이었다. 라운드 1 하나가 **9 CONFIRMED /
11 REFUTED / 2 UNVERIFIABLE** 을 냈다. 아래는 그중 이 계획의 설계를 실제로 바꾼 것들이다.

| 계획서/설계의 주장 | 반증한 측정 | 안 잡혔으면 치렀을 대가 | 유료 판 이전? |
|---|---|---|---|
| §0 [16] `enact_recovery!` 가 battery_mild 에 조용히 개입한다 | `grep` 전수: **정의 1 · 주석 4 · 호출 0**. 생산 producer 는 `policy_producer` 이고 `RESPEC_PRODUCER[]` 는 그것/`canonical_producer` 만 받는다 (라운드 1 E-1) | T9·T10 의 **해석 규칙이 통째로 뒤집힌다** — 존재한 적 없는 개입을 대조군으로 세우고, T4 의 인수 기준 *"`SILENT-FALLBACK` 줄이 나오면 안 된다"* 는 **반증 불가능한 문장**이 된다 | ✅ (그리고 T0 의 계측이 실측으로 재확인) |
| §0 [6] `harness_args` 는 사실상 `"env"` 하나다 | 레지스트리 전수: **10종**(`env` 15 · `sched` 2 · `invariant`·`scene_tree`·`model`·`t0`·`tF`·`Xa`·`milp`·`proposal` 각 1). `commit_respec` 는 `["env","milp","proposal"]` (라운드 1 B-2) | Phase D 의 재풀이 원시가 **구조적으로 영원히 거절**되고, 거절 이유가 `unknown_harness_arg:milp` 라는 **오도하는 이름**으로 나간다. T2 의 resolve 게이트는 그동안 초록 | ✅ |
| `params` 가 live 경로에서 인터프리터에 도착한다 | `SYNTH_LANE_KEYS` 여덟에 `params` 가 **없다**(라운드 1 X-1). 파이썬은 이미 그 이름으로 싣는다 | Phase D 원시가 필수 kwarg 없이 불려 `UndefKeywordError` → `catch` 가 그것을 **`:admit`+`applied=true`** 로 보고. **던진 것이 성공으로 기록된다.** 그리고 T3 게이트 (8)은 영원히 공허 | ✅ |
| `policy_entry(b; label=…)` 에 `Dict{String,Any}` fixture | 실제 시그니처는 `policy_entry(b, label)` — **위치인자**이고 `b` 는 **Symbol 키**로 읽힌다(`get(b, :error, …)`). kwarg 호출은 `MethodError`, String-키 fixture 는 `available=false chosen=""` 로 **실패 분기**를 탄다 (라운드 1 H1) | T1 의 게이트가 *"성공 분기"* 라 이름 붙인 채 **실패 분기를 재고**, 그 변이시험이 안 빨개진다. 이 레포가 이름 붙인 실패 모양 그대로 | ✅ |
| §0 [13] `_PAYLOAD_REF = 2.29` 는 실측 payload 상한이다 | `src/smdp/rates.jl` 의 그 수는 **colored_8x8 · 6로봇 · step 261** 의 관측치이고, **같은 파일이 붉은 글씨로 "인용하지 말고 시험을 돌려라"** 라고 적는다 (라운드 1 D-5). 라운드 4 가 정량적으로 악화시켰다: tractor 의 짐 질량 최대 **12.80 kg = 2.29 의 5.6배** | 근거 없는 상수를 "실측" 이라 부르고, 게이트가 같은 리터럴을 다시 적어 **상수와 시험이 구성상 일치**한다(아무것도 안 재는 시험). 대상 판에서는 자릿수까지 틀렸다 | ✅ |
| T3 의 `zone_keys` 는 truth 에서 유도하면 된다 / String 이어도 무해하다 | `RESTRICTION_ZONES[]` 는 `Dict{Symbol,Ball2}` 이고 모든 소비처가 `haskey` 로 거른다. **`haskey(d::Dict{Symbol}, ::String)` 은 조용히 `false`** — 필터가 `KeyError` 를 먹는다(라운드 3 음성 대조). 그리고 `dspy_service.py::_zones_block` 이 모델에게 **`zone "zone_blk_1"` 을 직접 보여준다** | 🔴 이 계획에서 **가장 위험한 침묵 폴백.** 모델이 **맞게 답한 것 때문에** 벌을 받고, `translate_whole_build! :already_clear`(|Δ|=0, residual=0, 세계 바이트 동일)가 **"존이 치워졌다는 증거"** 로 보고된다. T5 가 `PROJECT COMPLETE` 를 내면서 아무 일도 안 한 판을 성공으로 기록했을 것 | ✅ |
| T2 의 include 순서 논증 (*"navigator 보다 먼저 로드되면 로드 시점 UndefVarError"*) | Julia 는 자유 전역을 정의 시점에 안 푼다 → include 는 안전. **진짜 문제는 다른 것**: `src/navigator/` 는 패키지 로드 경로에 **없고** 런타임 include 다. 계획서가 제시한 대안(`src/ConstructionBots.jl` 끝)은 **navigator 를 로드하지 않으므로 아무것도 사지 못한다** (라운드 1 H3) | T6·T8 의 게이트가 **스위트에선 초록, 단독 실행에선 UndefVarError** 인 **순서 의존 초록**이 된다 — `tool_lane_keys_survive.jl` 머리말이 이미 이름 붙인 함정 | ✅ |
| T6 게이트 (1) 은 "훅이 안 걸렸을 때 배수가 바이트 동일" 을 잰다 | 그 테스트는 `clear_payload_bias!()` 를 부른 **직후** 그 함수의 효과를 단언한다 — **어떤 도달 가능한 상태도 이것을 실패시킬 수 없다.** 배수를 한 번도 평가하지 않고, 계획서가 적은 변이도 안 빨개진다. 게다가 프로세스 전역을 복원 없이 오염시킨다 (라운드 1 H7) | Phase D 의 핵심 안전 성질이 **실패할 수 없는 게이트**로 지켜진 것처럼 보였을 것 | ✅ |
| T7 의 치환 불변성 게이트가 통과한다 | `_nodes_block` 의 `%-8s` 패딩 때문에 `a.replace("A4","XXXX")` 는 10자, `b` 는 8자 → **불일치**. 그리고 `test_absent_nodes_render_is_byte_identical` 은 **자기 자신과 비교**라 공허. 또 pydantic `extra='ignore'` 라 구현 **전에** 4개 중 2개가 이미 초록 (라운드 1 X-3) | 헌장의 *"정답을 프롬프트에 싣지 않는다"* 를 나르는 유일한 게이트가 **포맷 문제로** 빨개져 누수로 오독됐을 것. 그리고 red→green 서사가 거짓이 된다 | ✅ (T7 자체는 미집행) |
| T3 게이트 (2)(8) 이 주장한 이유로 통과한다 | `enact_minted!` 는 `bind` 를 먼저 돌고, `env === nothing` 이면 **주장한 이유에 닿기 전에** 반환한다 → 네 단언 중 **뜻을 나르는 하나만** 실패 (라운드 1 X-2) | 세 단언이 통과하므로 "거의 초록" 으로 보이고, 게이트가 무엇을 재는지 아무도 다시 안 본다 | ✅ |
| §0 이 실행 파일을 **줄번호로** 10건 인용한다 | 그중 `render_demo.jl:646` 이 **죽은 코드**를 가리켰다(위 첫 행). §1-1 이 스스로 금지한 규약 위반 (라운드 1 RISK 9 → R15) | 줄번호는 파일이 줄면 썩는다 — 이 레포에 전례가 있다(`policy.jl` 1835→1704). 죽은 코드를 가리킨 인용이 **계획 전체의 전제**였다 | ✅ |
| §0 [20] 서비스 하나가 현행 코드로 떠 있다 | `/health` 의 `calls` 는 0 이 아니라 **1**, 그리고 **uvicorn 이 둘**(:8077, :8079). `TOOL_SYNTHESIS=1` 이 :8077 프로세스 환경에 실려 있어 `expressible=false` POST 는 **과금된다** (라운드 1 X-4) | 스윕이 조용히 **다른 서비스**와 말한다. 이 레포가 이미 실측한 "묵은 프로세스가 `/health` 200 을 낸다" 함정 | ✅ |
| **검증 자신의 앞 라운드**: R2(b) 의 `enactable = harness_args ⊆ suppliable` | 그 식은 19개 중 **15개**를 집행 가능으로 표시하는데 실제로는 **6개**다. 나머지는 호출 시점 `MethodError` 로 죽고 `catch` 가 그것을 `:admit`+`applied=true` 로 보고 — **거절보다 더 나쁘다** (라운드 2 Q6 → R19). T3 이 실측으로 6/19 를 확인했고, 심지어 `compile_constraint!` 은 메서드가 **6개**라 `only(methods(...))` 가 던진다 | 알파벳의 절반 이상이 "집행 가능" 으로 기록되고, 그 거짓이 로그가 아니라 **결정 행**에 남는다 | ✅ |
| **검증 자신의 앞 라운드**: R32/R35 의 T5b(canonical 판에서 `LAST_EDGE_COSTS[]` 계측) | 결정 시점에 그것을 정직하게 잴 자리가 **없다** — (a) 렌더 레인에 post-enactment 훅이 **0개**, (b) 그 값은 0 이 아니라 **미정의**(결정 경로가 `formulate_milp` 을 안 부른다), (c) 강제 `rebalance_for_battery!` 프로브는 계측이 아니라 **개입**이다(`optimize!` → `commit_respec!`) (라운드 5 Q4 → R36) | `0` 을 찍어 **"후보 간선 0"과 "MILP 가 안 돌았다"를 뭉갠다** — spec §9-2 의 삼상 붕괴. 그리고 canonical 판이 더 이상 canonical 이 아니게 된다 | ✅ |
| T4 의 Edit 앵커 `macro_to_proposal(truth, decision.macro_name; env=env, …)` | 실제 리터럴은 `env = env` — **`=` 양옆에 공백**이 있다 (라운드 5 Q1 → R37) | Edit 이 **조용히 매치 실패**한다 | ✅ |
| 라운드 4 가 계획서에서 찾은 것: `string(owner) != st.agent` 로 남의 엣지를 거른다 | `_owner_robot` 은 81/81 에서 **`BotID{DeliveryBot}` 객체**를 낸다. String vs RobotID 비교는 에러가 아니라 **항상 참** ⟹ 모든 엣지가 factor 1.0, 훅은 `:installed`, 보드는 초록, **세계는 그대로** | Phase D 전체가 "성공을 보고하는 무동작" 으로 렌더되고 T10 에 **개선으로 적혔을 것** | ✅ |

**세 가지를 덧붙인다.**

1. **자기 자신을 반증한 라운드가 둘이다**(R19 가 R2(b) 를, R36 이 R32/R35 를). 검증자가
   자기 앞 결정을 뒤집었다는 사실이 이 세션에서 가장 건강한 신호다.
2. **T4 의 구현자와 리뷰어도 자기 게이트의 "실패할 수 없는" 결함 2건을 스스로 찾아 고쳤다** —
   여러 줄 `println` 은 토큰이 **첫 물리 줄에만** 실리고, `findfirst` 가 자기 **주석**을
   매치하고 있었다(주석이 금지 라벨과 심볼 이름을 담고 있었으므로). 둘 다 처음엔 초록이었다.
3. **위 전부가 유료 판을 쓰기 전에 잡혔다.** 유료 5건 중 2건은 기준선 녹화(T0), 3건은
   T5 의 정지 판이다. 반증 때문에 낭비된 유료 호출은 **0건**이다. 반대로, 잡히지 않았다면
   최소 두 판(zone_minted, battery_mild_minted)이 **무동작을 성공으로 기록한 채** 렌더됐을
   것이다.

---

## 5. 룰링 전문 — 사용자를 대신해 내린 결정 52건

원장의 모든 `Ruling:` 을 순서대로 싣는다. **대가 칸에 † 가 붙은 것은 원장에 명시적
"대가(틀렸을 때)" 줄이 없어 룰링 본문에서 유도한 것**이다(15건). 나머지 37건은 원장의 문장이다.

| # | 결정 | 틀렸을 때의 대가 |
|---|---|---|
| S1 | 새 worktree 가 아니라 **현재 작업 트리**에서 일한다 (212건의 남의 미커밋 삭제 + "결정성의 단위는 디렉토리(컴파일 캐시)") | 격리가 없어 실패한 태스크의 잔재가 트리에 남는다. 각 태스크가 커밋으로 끝나므로 `git checkout -- <path>` 로 회수 가능 |
| S2 | `git add -A` / `git add .` / `git commit -a` **금지**를 모든 브리프에 싣는다 | 남의 작업 삭제를 통째로 커밋한다. revert 로 회수 가능하나 비싸다 |
| S3 | 실행 순서를 **T8 → T0 → T1 → T2 → T3 → T4 → T5 → T6 → T7 → T9 → T10** 으로 | 없음. 순서만 바뀌고 의존은 지켜진다 |
| R1 | §0 [16] 반증 — T0 의 계측 println 은 넣되 **기대값을 뒤집는다**(찍히면 안 된다). T9·T10 의 해석 규칙이 "무개입 vs X" 로 뒤집힌다 | validator 가 간접 호출을 놓쳤다면 T9 대조가 오염된다. 계측 println 이 정확히 그 경우를 잡는다 — 비용은 한 줄 |
| R2 | §0 [6] 반증 — 바인더는 (a) 라운드 2 측정 뒤에만 넓히고, (b) 공급 불가 원시는 `resolve_primitive` 시점에 `enactable=false`, (c) 그 격차를 게이트가 센다 | 바인더가 넓어져 안전층이 검사할 표면이 는다. undo 없는 설계에서 실제 위험 |
| R3 | `SYNTH_LANE_KEYS` 를 **아홉**으로(`params` 추가) | 결정 행이 한 열 넓어진다. 없음에 가깝다 |
| R4 | `policy_entry(fake, "dspy")` **위치인자** + `JSON3.read(JSON3.write(...))` Symbol-키 fixture | 없음. 실측된 시그니처를 따를 뿐 |
| R5 | include 지점 확정: `minted_tool.jl` → `respec.jl`, `payload_bias.jl` → **`navigator/navigator.jl`**, 두 게이트에 navigator guard | include 중복이면 재정의 경고. 회수 쉬움 |
| R6 | T3 게이트 (2)(8) 에 sentinel `env = Ref(:e)` | 없음. 그대로 두면 **뜻을 나르는 한 단언만** 실패한다 |
| R7 | T7 치환 불변성은 등길이 센티넬(`"A4"`→`"Z9"`), byte-identical 은 **구현 전 golden** 과 비교, Step 2 기대값 정정(4개 중 2개는 이미 초록) | golden 파일이 하나 는다 |
| R8 | `_PAYLOAD_REF` 는 **선언된 손잡이**로 적고 `rates.jl` 을 근거로 인용하지 않는다. 게이트는 리터럴 대신 `CB._PAYLOAD_REF` 를 참조 | 없음. 단조성은 어떤 양수 상수에서도 성립 |
| R9 | T6 게이트 (1) 재작성 — 재는 명제를 "재가격 안 걸린 로봇의 엣지에서 두 배수가 바이트 동일" 로 바꾸고 `try…finally clear_payload_bias!()` 로 감싼다 | 게이트가 조금 더 비싸진다 |
| R10 | `tools/monitor/test_minted_wiring.jl` 을 `test/runtests.jl` 에 **등재**한다(사전 스캔의 "orphan gate" 판정은 반증됐다 — `runtests.jl` 은 `tools/` 를 이미 2건 include 한다) | † 등재를 빠뜨리면 게이트가 고아가 되어 아무도 안 돌린다 |
| R11 | 인수 기준을 **`fail==0 && error==1` + pass 델타 설명 가능**으로 (pass 문턱 폐기) | 회귀가 pass 감소로만 나타나면 못 잡는다. 그래서 "설명 가능할 것" 이 조건 |
| R12 | T5 직전에 서비스를 정리하고 **사용 포트를 모든 명령에 로그로** 남긴다 | 유료 호출의 귀속이 불가능해진다. 지금 고치는 것이 싸다 |
| R13 | agent 매칭은 새 문자열 규약을 발명하지 않고 `enact.jl` 의 기존 접지 경로를 재사용 | `:unknown_agent` 가 영구 결과가 되고 **모델 실패처럼 보인다** |
| R14 | `enact_minted_decision!` 전체를 `try…catch` — 던지면 `handled=false`+`verdict=:reject`+이유를 찍고 정상 반환 | 진짜 결함이 한 판 더 조용해진다. 그래서 반드시 println 을 남긴다 |
| R15 | 새로 쓰는 코드·주석·보고서는 **전부 심볼로** 인용. §0 는 이 보고서가 정정 | † 줄번호는 파일이 줄면 썩고, 이미 죽은 코드를 가리킨 전례가 있다 |
| R16 | 라운드 2 검증을 **T3 앞에** 세운다 | † 라운드 2 없이 T3 을 짜면 R2(a) 의 미확정 부분이 구현으로 굳는다 |
| R17 | **바인더를 넓히지 않는다** — `"env"` 만. zone body 는 env-only 로 끝까지 집행되고, `commit_respec` 에 `milp` 을 줘도 알파벳에 **푸는 행위가 없다** | 모델이 `commit_respec` 을 조합하면 거절된다. R19 가 그 거절을 정직한 이유로 만든다 |
| R18 | Phase D 의 재풀이는 **새 원시 하나**(`rebalance_for_battery!(env)`)로 온다. T6 의 Files 에 추가 + navigator guard | 알파벳이 1 넓어진다. `mechanism` 산문이 재풀이를 정확히 서술해야 한다 |
| R19 | `enactable` 은 **세 연언지**(`harness ⊆ {env}` ∧ arity ∧ kwargs). 19 중 **13이 빨갛다** | 알파벳의 집행 가능 폭이 6/19 로 드러난다. **그것이 주 산출물이지 실패가 아니다** |
| R20 | `zone_keys` 를 **`Symbol` 로 강제 변환**하고 `RESTRICTION_ZONES[]` 에 없으면 거절 + 전용 게이트 | 이 계획에서 **가장 위험한 침묵 폴백**. 안 고치면 T5 가 `PROJECT COMPLETE` 를 내면서 아무 일도 안 한 판을 성공으로 기록한다 |
| R21 | `params.agent` 는 zone_keys 와 **같은 규약**으로 — 없으면 truth 에서 유도, 있으면 접지, 실패하면 거절. 🔴 프롬프트에 `agents` 를 싣는 것은 **범위 밖** | 모델이 어느 로봇인지 스스로 못 고른다. 이 데모에선 후보가 하나라 손실이 없지만 **일반화의 증거로 읽으면 안 된다** |
| R22 | `restage_assembly!` 의 필수 위치인자는 R19 의 둘째 항이 자동으로 걸러낸다 — 별도 조치 없음 | † 거절 이유가 부정확하면 T5 의 실패 분해가 원시를 잘못 지목한다 |
| R23 | T0 의 zone 기준선을 **`router` 레인**으로 돌린다(계획서의 `canonical` 이 아니라) — 레인이 다르면 T5 의 통제가 아니다 | router 레인이 `PROJECT INCOMPLETE` 를 재현 안 할 수 있다. 그것은 실패가 아니라 정보다 |
| R24 | `results/*` 가 gitignore 이므로 `git add -f` 로 명시 경로만 추적한 판단을 **승인**. T5·T9 브리프에도 `-f` 를 싣는다 | 로그 2개(수백 KB)가 레포에 들어온다. 되돌리기 쉽다 |
| R25 | **침묵 성공 status 7종**을 목록화 — 평범한 성공은 `{:partial,:restaged_all,:translated}` 뿐 | 진짜 성공한 판이 한 번 보수적으로 기록된다. 그 반대보다 압도적으로 싸다 |
| R26 | 계획서의 `zone_keys` 유도 규약 **폐기** — 안 주면 kwarg 를 안 넘긴다(callee 기본값 = 살아 있는 모든 존), 주면 강제 변환·실재 확인·아니면 거절. 빈 리스트도 거절이지 폴백이 아니다 | 모델이 실재 키를 줬는데 형식이 달라 거절될 수 있다. 그 거절은 **이유가 정확하고 로그에 남는다** |
| R27 | 반환 NamedTuple 의 필드를 무조건 접근하지 않는다(`hasproperty` 방어) | † `:none` 한 번에 `r.residual` 이 던지고 `catch` 가 그것을 `:admit`+`applied=true` 로 보고 — 최악의 조합 |
| R28 | T4 의 범위를 넓혀 **존 진단을 결정 전에 찍는다**(T5 의 전제 확인). `verdict`·`relocate_norm` 은 **오라클 라벨**이라 프롬프트에 안 싣는다 | T4 가 println 두 개만큼 커진다 |
| R29 | 잔량은 **둘 다 라벨을 달아** 찍는다(`_count_future_goals_in_zone` vs `_count_future_work_overlaps`) | † 하나만 찍고 "잔량" 이라 부르면 그것이 이 레포의 tautological cross-check 실패 모양이다 |
| R30 | `test/minted_tool_resolves.jl` 에 navigator guard 를 **넣는다**(집행은 navigator 를 로드하는 렌더 레인에서 일어나므로) | 게이트가 navigator 로드 비용을 문다(수 초) |
| R31 | Phase D 의 결함은 Phase C 를 안 건드린다 — T3→T4→T5 를 그대로 간다 | † 틀렸다면 T5 의 판이 Phase D 결함의 영향을 받는다(라운드 2·3 이 그렇지 않음을 이미 쟀다) |
| R32 | **Phase D 는 측정 하나를 기다린다** — T6 앞에 계측 태스크 T5b | 3분과 판 1개. 그 반대(무동작 판을 유료로 렌더하고 "개선" 으로 적기)는 계획 전체의 신뢰를 깎는다 |
| R33 | 측정과 무관하게 T6 이 고칠 둘: (a) `_PAYLOAD_REF` 를 실측 범위에서, (b) agent 비교를 **ID 동등성**으로 + 음성 대조 게이트 | † 안 고치면 (a) 정규화가 5.6배 증폭이 되고 (b) 모든 엣지가 factor 1.0 인 채 보드가 초록이 된다 |
| R34 | 삼상 정의 정밀화 — `admit`/`reject`/`deferred` 의 경계와 **`applied` 는 침묵 성공 목록 밖의 status 가 하나라도 있을 때만 참** | 진짜 성공한 판이 한 번 보수적으로 `applied=false` 로 기록될 수 있다. 그 반대보다 압도적으로 싸다 |
| R35 | T5b 의 계측을 T4 에 태운다(둘 다 `render_demo.jl` 계측) | † 태스크를 쪼개면 유료 판 순서가 흐트러진다. 추가 작업 0 |
| R36 | **T5b 폐기** — 결정 시점에 `LAST_EDGE_COSTS[]` 를 정직하게 잴 자리가 없다. 대신 `enact_minted_decision!` 안에서 **센티넬**(`ran_milp = !(LAST_EDGE_COSTS[] === _sent)`)로 잰다 | Phase D 가 무동작임을 판을 돌린 뒤에 안다. **그 전에 알 방법이 없다는 것**이 이 라운드의 결론 |
| R37 | 계획서의 Edit 앵커 공백 정정(`env = env`) | † 그대로 Edit 하면 조용히 매치 실패한다 |
| R38 | 모든 OOD 사건이 `policy_producer` 에 닿지는 않는다(조기 `nothing` 가드 둘) — 브리프에 싣는다 | † `[minted]` 줄이 없을 때 **후보 원인이 셋**임을 모르면 잘못된 진단을 한다 |
| R39 | 계측의 기계적 제약: `@info` 는 삼켜지므로 전부 `println`; `n_blocked` **두 개**를 구별; 오라클 라벨은 로그에만 | † 뭉치면 T5 가 **잘못된 양**을 읽는다 |
| R40 | T5·T9 에서 **높은 reject 율은 정상 동작**이고, 프롬프트에서 un-enactable 원시를 숨기지 않는다 | 판 하나가 reject 로 끝날 수 있다. 그 reject 는 이유가 정확하다 |
| R41 | T6 은 자기 원시의 status 표를 **body 에 넣기 전에** 채운다 | † 안 채우면 나머지 원시가 status 무관하게 `applied=true` 가 된다 |
| R42 | `handled = :admit && (applied ‖ partial)` — 절반 고쳐진 세계 위에 기본 복구 사슬을 또 쌓지 않는다 | † 반대로 하면 부분 집행 위에 복구가 겹쳐 세계가 더 나빠진다 |
| R43 | `applied` 는 **status-only 로 유지**하고 파생값 **`world_maybe_dirty = applied ‖ partial`** 를 따로 낸다 | 반환 NamedTuple 이 한 필드 넓어진다 |
| R44 | `_step_status`/`_step_detail` 을 `try` 안으로 (T6 이 알파벳을 넓히면 도달 가능해지므로) | † 리뷰어는 "오늘의 6개에는 도달 불가" 라 Minor 로 뒀지만, 이 계획 안에서 도달 가능해진다 |
| R45 | `recover_stalled_teams!` 의 `:restaged` 가 숨기는 한 겹 더 깊은 침묵 성공은 **parked, 의도적으로 안 판다** | 모델이 그 원시를 조합하면 그 판의 `applied` 가 과대 보고된다. `steps` 의 status 로 사후 판별은 가능하다 |
| R46 | 레지스트리 **값 스키마** 못박기는 최종 리뷰로 미룬다. 단 T6 은 자기 params 값을 스스로 검증해야 한다 | 값 스키마를 넓히는 편집이 게이트 전부 초록인 채 통과한다. 최종 리뷰가 triage |
| R47 | 🔴 T5 의 유료 판 **전에** 캐시 재개를 고친다 — 원시별 재개 표를 **소스에서 읽어** 만들고, 재개 안 하는 원시가 세계를 바꿨으면 body 끝에서 한 번 `reset_cache_resume!` | 이미 재개한 원시 뒤에 한 번 더 재개한다. 낭비이지 손상이 아니라면 허용 |
| R48 | 표를 **둘로 가른다** — `SILENT_SUCCESS_STATUSES`(달성 여부) ⟂ `WORLD_UNCHANGED_STATUSES`(접촉 여부). `:residual_blocked` 는 첫째에 있고 둘째에는 없다 | 필드가 하나 늘고 표가 둘이 된다. 지금 안 가르면 zone 매크로가 어휘로 돌아오는 순간 이 거짓말이 **제어 흐름**이 된다 |
| R49 | T5 의 서비스 기동 — :8079 는 건드리지 않고 :8077 만 재기동, `ps lstart` 로 시각 확인, `TOOL_SYNTHESIS=1` 명시 | 남의 서비스를 안 죽이는 대신 포트 혼동 위험이 남는다. `DSPY_URL` 명시로 막는다 |

🔴 **R47 의 대가는 실제로 실현될 뻔했다.** T4 리뷰가 찾은 Critical 이 그것이다: 집행 가능한
6개 중 **3개가 스케줄 캐시를 재개하지 않는데**(`reform_stuck_teams!`·`recover_stalled_teams!`·
`force_advance_stuck_carrier!`) `handled=true` 가 재개해 줄 유일한 호출자를 건너뛴다.
그 판의 로그는 `verdict=admit applied=true handled=true` 를 찍고, 실제로는 **프론티어가 낡았고
OOD 사건은 소비돼 재시도되지 않는다.** 유료 판 전에 고쳤고, 게이트가 진짜
`OperatingSchedule` + `initialize_planning_cache` 로 그 대조를 세운다((13-e)/(13-f)).

---

## 6. 🔴 Phase D 재설계 브리프 — 측정된 사슬과 열린 물음

사용자 결정 D-B 는 *"레버를 재설계한 뒤 진행한다"* 이다. 이 절이 그 재설계의 출발점이다.
**아래는 전부 라운드 4 의 읽기 전용 프로브(판 0개, 유료 0건)와 라운드 5 의 소스 재유도다.**

### 6-1. 측정된 사슬 (실측 순서대로)

1. ✅ **payload 축은 `tractor.mpd` 에서 살아 있다.** payload-capable 노드 **81/81** 이
   `_payload_mass > 0`, 범위 **0.32768 … 12.800 kg**, 평균 **2.4846 kg**.
   ⟹ 계획서 §0 [13] 이 인용한 `0.0 … 0.0 kg` 우려는 **다른 모델(colored_8x8)의 step-local
   산물**이었다 — 모델의 성질이 아니다. **"payload 가 항등 0 이라 무동작" 은 아니다.**
2. 🔴 **그런데 `n_candidate_edges = 0` 이다.** `length(LAST_EDGE_COSTS[]) = 0`,
   `nnz(Xa) = 329` 가 전부 **`Xa == 1` 로 고정된 구조 간선**. `edge_costs` 는 Big-M 후보
   루프에서만 채워지는데 그 루프가 **한 번도 안 돈다**(빈 배정 슬롯이 없다).
   `init_objective_weights!()` 로 κ=0.01 을 켠 뒤에도 `LAST_AUTO_EFFICIENCY_W = 0.0` 이고
   목적식이 **순수 makespan 으로 후퇴**한다.
3. ⟹ **`formulate_milp` 은 `EDGE_COST_MULTIPLIER[]` 를 무조건 읽지만 오직 `edge_costs`
   경유이고, 고정 간선은 거기 안 들어간다.** 재가격 클로저는 **0번 호출된다.**
   ⟹ Phase D 의 재가격은 이 판에서 **원리적으로 무해하고 원리적으로 무효**다.
   (부호까지 적어 둔다: 설령 후보 간선이 생겨도 payload factor 는 **≥ 1** 이라 이미 선택
   안 된 후보를 더 밀어낼 뿐이다.)
4. 🔴 **그런데 `rebalance_for_battery!` 는 여전히 `:rebalanced` 를 낸다** — 또 하나의 침묵
   성공. 그 심볼은 "커밋이 성공했다" 이지 "계획이 바뀌었다" 가 아니다. 후보 간선 0 인 판에서
   "세계가 바뀌었나" 를 가르는 관측은 **반환 심볼이 아니라** (a) `length(LAST_EDGE_COSTS[]) > 0`
   와 (b) 재풀이 전후 배정 엣지 집합의 차이 둘뿐이다.
   (그리고 `:commit_failed` 는 **바이트 동일이 아니다** — 부분 재구축을 남긴다.)
5. 🔴 **계획서의 `string(owner) != st.agent` 비교는 절대 매치할 수 없다.** `_owner_robot` 은
   `BotID{DeliveryBot}` **객체**를 낸다(81/81, `n_nothing=0`). String vs RobotID 는 에러가
   아니라 **항상 참** ⟹ 모든 엣지가 factor 1.0, `status=:installed`, 보드는 초록, **세계는
   그대로**. 올바른 비교는 ID 대 ID (`owner == st.agent`) 이고, `truth.robot` 이 이미
   `RobotID` 이며 `fleet.soc` 의 키와 **같은 타입**이라(`haskey` 실측 참, 내용 기반
   `==`/`hash`) 문자열 왕복 자체가 불필요하다.

### 6-2. 🔴 정직한 측정 caveat — 이것을 지우지 말 것

위 2·3 은 **`closed = 0`(사전-시뮬)** 에서 잰 값이다. 실제 결정은
**`closed = 245 / n_total = 305`** 에서 난다(`battery_mild_before.log` 의
`[ood] battery fired at step≈601 closed=245`).

라운드 4 는 결정 시점에도 0 일 것이라는 **기전**을 준다 — 후보 간선은 미배정 슬롯에서만
생기고 시뮬 루프는 노드를 닫을 뿐 슬롯을 만들지 않으며, 슬롯을 되돌리는 것은
`hot_swap_robot!` 의 엣지 수술뿐인데 **이 판의 팔은 NOOP 이라 그 수술이 없다.**
그러나 **그것은 논증이지 결정 시점의 측정이 아니다.**

그리고 라운드 5 는 **결정 시점에 그 수를 정직하게 잴 자리가 없다**는 것을 확정했다:
(a) 결정 시점에 live `env` 를 가진 유일한 심볼은 `policy_producer` 인데 거기선 집행이 아직
안 일어났고 렌더 레인에 post-enactment 훅이 **0개**다; (b) 그 값은 0 이 아니라 **미정의**다 —
`0` 을 찍으면 "후보 간선 0" 과 "MILP 가 한 번도 안 돌았다" 가 **같은 관측**이 된다;
(c) 강제 `rebalance_for_battery!` 프로브는 계측이 아니라 **개입**이다.

⟹ **유일한 비개입 프로브는 T4 가 심은 센티넬이다**:
`ran_milp = !(CB.LAST_EDGE_COSTS[] === _sent)` — `enact_minted_decision!` 안에서 호출 전에
새 dict 를 꽂고 호출 후 **동일성**으로 재풀이 여부를 판정한다. `length(...)` 를 `ran_milp`
없이 찍는 것은 **금지**다(삼상 붕괴). 그 센티넬은 T5 의 판에서 `n/a(not armed)` 를 찍었다 —
인터프리터가 안 불렸으므로 무장 자체가 안 됐다. **즉 이 값은 아직 한 번도 실측된 적이 없다.**

### 6-3. 재설계된 레버가 닿아야 할 곳

- **후보 간선의 가격이 아니라 고정 간선이다.** `EDGE_COST_MULTIPLIER[]` 는 `edge_costs`
  경유로만 목적식에 닿고, 이 판의 329개 간선은 전부 `Xa == 1` 로 고정돼 그 사전에 안 들어간다.
  후보 간선을 만들지 않는 한 어떤 배수도 무효다. **이것은 계획서에 없는 설계다.**
- 그러므로 재설계의 첫 물음은 "배수를 어떻게 계산하나" 가 아니라
  **"이 판에서 무엇이 재배정 가능한 자유도인가"** 다.
- `_PAYLOAD_REF` 는 **선언된 손잡이**로 다시 이름 붙여야 한다(R8·R33). `2.29` 는 대상 판에서
  5.6배 작다.
- agent 비교는 **ID 동등성**으로(R33(b)), 그리고 그 오류를 **red 로 만드는 음성 대조**를
  게이트에 넣어야 한다: truth 의 로봇이 소유한 정점에서
  `payload_edge_multiplier(env, sched, v) > battery_edge_multiplier(sched, v)`.
  타입이 어긋나면 두 값이 **같아져** 즉시 빨개진다.
- `rebalance_for_battery!` 를 알파벳에 넣는다면(R18) `SILENT_SUCCESS_STATUSES` /
  `WORLD_UNCHANGED_STATUSES` / `PRIMITIVE_RESUMES_CACHE` **세 표를 body 에 넣기 전에**
  채워야 한다(R41, 게이트가 `keys(...) == ENACTABLE_TODAY` 를 못박는다).

### 6-4. 열린 물음 (재설계가 답해야 할 것)

1. **결정 시점(`closed=245/305`)에 후보 간선이 정말 0 인가?** 기전은 "그렇다" 를 가리키지만
   측정된 적이 없고, 비개입으로 잴 유일한 자리는 집행이 실제로 일어나는 T4 의 센티넬이다.
   즉 **집행이 한 번은 일어나야 답이 나온다** — 닭과 달걀.
2. **후보 간선을 만드는 개입이 이 데모에 존재하는가?** (`hot_swap_robot!` 계열의 엣지 수술이
   유일한 알려진 경로다. 그것은 mild 레인의 팔이 아니다.)
3. **payload 축이 목적식에 닿는 다른 경로가 있는가** — `edge_costs` 말고?
4. **`LAST_EDGE_COSTS[]` 는 프로세스 전역이고 `:infeasible` 경로에서도 덮인다.** Phase D 가
   재풀이를 하나 더 끼우면 **다음 결정의 센티넬이 이번 재풀이를 자기 것으로 오인**할 수 있다.
   전역 하나에 두 소비자가 붙는 설계를 유지할 것인가?
5. **애초에 battery_mild 가 이 레인의 옳은 사건인가?** zone 판이 `expressible=true` 를 냈고,
   mild 메뉴는 zone 과 **구조적으로 같다**(둘 다 `["NOOP"]`). 계획서 §4 의 위험표가 스스로
   적듯, 두 레인이 다른 답을 낸다면 그 차이를 만드는 것은 **관찰문과 payload 채널뿐**이다 —
   그리고 그 채널을 넓히는 것은 D-A 가 zone 에 대해 **거부한** 종류의 개입이다.

---

## 7. 사용자에게 남는 것

### 7-1. 🔴 병합 전 반드시 고칠 것 (T4 의 parked minor 넷 중 첫째)

**`tools/monitor/test_minted_wiring.jl` 이 반증된 pre-fix 규칙을 아직 단언한다:**

```julia
@test r.world_maybe_dirty === (r.applied || r.partial)
```

R48 이 그 등식을 **깼다** — `:residual_blocked` 는 "적응은 못 했다"(`applied=false`)이면서
동시에 "세계를 만졌다"(`world_maybe_dirty=true`) 이고, `translate_whole_build :already_clear`
도 `_apply_uniform_translation!` 이 Δ 와 무관하게 `_resync_scene_drift!` 를 부르므로 세계를
만진다. **지금 초록인 이유는 그 fixture 둘이 그 status 에 한 번도 안 닿기 때문이고**(fixture
운), 닿는 순간 이 단언은 거짓말이 된다. 최종 리뷰가 triage 할 것.

### 7-2. T4 의 나머지 parked minor 셋

- `WORLD_UNCHANGED_STATUSES` 의 docstring "세계를 한 바이트도 안 건드리고" 는 `CARRIER_LAST_D`
  기록 때문에 **문자 그대로는 거짓**이다.
- `resume=:issued` 는 아직 **진짜 빌드에서 태워진 적이 없다**(빈 스케줄에서만). T5 의 판이
  그 자리였는데 인터프리터가 안 불렸다 ⟹ **여전히 미실행**.
- 영속 결정 행에 합성 집행의 흔적이 없다(`record_decision!` 이 배선보다 먼저 돈다). 의도된
  설계지만 **사후 분석은 stdout 파싱뿐**이고 그 stdout 이 lossy 하다(§2).

### 7-3. 그 밖의 parked 항목

| 출처 | 항목 |
|---|---|
| T8 | 보고서의 `+8 pass / −1 error` 델타는 **사전 기준선 없이 사후 추론**이다(§1-1 이 같은 문제를 안는다) |
| T8 | 리터럴 제거의 대가로 단언이 약해졌다 — `length(AR.kind_valid(:battery)) == 3`. **이 게이트만으로는 세 팔이 무엇인지 안 잰다**(이름 동일성은 `policy_macro_binding.jl` 이 소유) |
| T0 | dspy 레인이 실제로 구동했다는 증거가 보고서·커밋메시지에 **명시적으로** 적히지 않았다(로그에는 있다) |
| T0 | board 2 가 foreground 지시 도착 전에 background 로 떠 있었다 — 재실행(유료 1건) 대신 blocking 을 택한 **공개된 이탈** |
| T1 | 새 게이트가 `"NOOP"` 을 fixture filler 로 4번 리터럴로 적는다(단독 설계가 강제한 것, 단언 대상은 아님) |
| T3 | 🔴 **세 번째 레지스트리 확장 경로가 열려 있다** — testset (12) 는 `params` 의 **키**만 못박고 **값 스키마**(type/items/enum)와 `mechanism` 산문은 아무것도 안 본다. `synthesize.py::_fmt_params` 가 그 값을 모델에게 렌더하고 `bind_primitive_args` 는 매치된 param 을 **검증 없이** 넘긴다(`zone_keys` 만 강제 변환·확인) |
| T3 | `ctx.truth` 가 두 함수에서 죽었다(T4 용으로 의도적 보존) |
| T5 | `[minted] lane=reach_nothing` 이 삼상을 뭉갠다 — 조기 반환 줄에 최소한 `synthesis_event`/`synthesis_ran`/`synthesis_error`/`expressible` 을 실을 것 |
| T5 | 애니메이션 거부 메시지가 `case=none` 이라고 적는다 — `DEMO_CASE_TAG=zone_minted` 가 그 메시지에 도달하지 않는다 |
| R45 | `recover_stalled_teams!` 의 `:restaged` 가 숨기는 한 겹 더 깊은 침묵 성공(§3-8) |
| R46 | 레지스트리 값 스키마 전면 못박기 |

### 7-4. 사용자 판단이 필요한 열린 결정

1. **zone 레인을 여기서 닫은 채 둘 것인가.** D-A 는 "관측 채널을 넓히지 않는다" 였다.
   T5 보고 §7 우려 ⑤ 가 그 결정의 근거를 적는다 — `_zones_block` 은 `build_center`·
   `build_radius`·`max_shift`·`work_reach` 를 **일부러 안 싣고**(정답을 프롬프트에 안 싣는
   설계), 그래서 모델이 보는 것은 "반경 0.07 원반이 조립체 3개를 덮는다" 까지다.
   **그 입력에 대해 NOOP 은 불합리한 독해가 아니다.** 손댈 자리는 프롬프트 문구가 아니라
   **어떤 측정값을 실을 것인가** 이고, 그것은 spec §6-2(정답 누수)와 정면으로 맞닿는다.
2. **Phase D 재설계를 착수할 것인가** — §6-3·§6-4 가 그 브리프다. brainstorming 부터
   다시 하는 별도 작업이다.
3. **`build_tools` 의 동적 등재**(spec §3-1 의 `composed` 처리)는 이 계획이 **안 건드렸다**.
   합성된 tool 이 *다음* 결정의 메뉴에 오르는 느린 루프는 여전히 열려 있다.
4. **이 브랜치의 마감** — 남은 것은 최종 전체 리뷰와 §7-1 의 수정이다.

---

## 8. 이 보고서가 새로 돌린 명령 (전부 읽기 전용, 유료 0건)

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'
#   → 2005 passed, 0 failed, 1 errored, 0 broken       (종료 실측, §1-1)
.venv/bin/python -m pytest src/respec/llm_service/ --ignore=src/respec/llm_service/test_propose.py -q
#   → 194 passed, 5 skipped, 2 warnings in 12.32s      (종료 실측, §1-1)
tr '\r' '\n' < results/baseline_2026-08-30/zone_before.log         # §2 의 인용
tr '\r' '\n' < results/baseline_2026-08-30/battery_mild_before.log # §2 의 인용
tr '\r' '\n' < results/2026-08-30-zone-minted/render.log           # §2 의 인용
```

`127.0.0.1:8077`·`:8079` 로의 POST 는 **하지 않았다.** `render_demo.jl` 도 **돌리지 않았다.**
소스 파일은 **한 글자도 고치지 않았다** — 이 보고서 하나만 새로 만들었다.
