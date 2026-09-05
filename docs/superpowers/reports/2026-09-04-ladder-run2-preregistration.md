# 사전등록 — 유료 런 2 (사다리 L2·L3·L4) · 2026-09-04

> **이 문서는 결과를 보기 전에 쓰인다.** 런이 끝난 뒤 이 문서의 술어를 고치는 것은 금지다.
> 술어가 명제와 갈리면 **둘 다 적는다** (유료 런 1 이 그렇게 했고, 그 정직함이 아래 결정 1 을 낳았다).
>
> 상속: `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md` (결정 1~19).
> 아래는 그 문서를 **덮어쓰는 항목만** 적는다. 언급되지 않은 결정은 그대로 살아 있다.
> 판정의 정본: `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` §0.

---

## 결정 20 🔴 — L2 술어를 교정한다

선행 사전등록의 L2 술어는 `args_from == :calls ∧ steps[1].status !== nothing` 이었다.
유료 런 1 에서 `steps[1].status === :threw` 가 나왔고, `:threw !== nothing` 이므로
**술어는 초록인데 설계 §0 의 명제("호출이 예외 없이 끝났다")는 거짓**이었다.
`:threw` 는 모델이 고른 반환값이 아니라 **집행부가 찍은 표식**이다.

**새 술어 (런 2 부터 구속력을 갖는다):**

```
L2 = (args_from == :calls) ∧ (steps[1].status === :success)
```

- `:threw` → **거짓**(`nothing` 아님). 쟀는데 실패한 것이다.
- `steps` 가 비었거나 안 읽히면 → `nothing` (못 쟀다).
- 두 축은 여전히 **따로** 적는다. 인자 채널이 초록이고 무예외가 빨간 판이 실재한다(런 1).

## 결정 21 — L2 의 진단 채널

런 1 은 무엇이 던졌는지 기록 어디에도 안 남겨, 실행자가 사후에 격리 프로브로 재유도해야 했다.
Task 1 이 그 구멍을 닫는다. **런 2 의 판정 조건:** `steps[1].status === :threw` 이면
기록 줄과 결정 행이 **예외 메시지를 담아야 한다**. 안 담으면 그것은 Task 1 의 결함이고,
그 판은 L2 의 실패 원인에 대해 **침묵**한다(추론으로 메우지 않는다).

## 결정 22 — L3 술어

```
L3 = 결정 행의 interface_calls 가 비어 있지 않은 Vector{String}
```

- `nothing` = 못 쟀다(등록 실패 등). `[]` = **쟀는데 하나도 안 불렀다**(런 1 이 이것).
- 이름 우주는 **디스크의 산출물**이 광고하는 것: `methods ∪ types ∪ subtypes ∪ ambient`.
  `access` 는 안 든다. 산출물 `sha256` 을 런 전후로 떠서 이 우주가 안 움직였음을 보인다.
- 선행 결정 13 을 유지한다: **불리언이 아니라 목록으로 읽는다.** 히트가 타입 생성자뿐이면
  (예: `ScheduleNode(...)`) 그것은 **약한 증거**로 따로 적고, bang 함수 히트와 구분한다.
- 🔴 **Task 3 이 프롬프트를 바꿨으므로 이 축은 처치의 직접 대상이다.** 그래서 런 전에
  프롬프트 블록의 자·줄 수를 실측해 적는다 — 선행 실측은 **606줄 / 29,660자**였다.
  값이 안 변했으면 Task 3 이 안 실린 것이고, 그러면 이 런은 L3 에 대해 **아무 처치도 안 한 런**이다.

## 결정 23 — L4 술어를 `world_delta_body` 로 옮긴다

선행 결정 8 은 `delta_scope == "body+harness_resolve"` 이면 귀속 불가라고 못박았다.
런 1 이 그 자리에 떨어졌고, 그것은 **구조적**이다 — `_resolve_if_needed!` 는 원시의 선언된
`surface` 가 `"sched"`/`"milp"` 면 무조건 하네스 재풀이를 돌리므로(`src/respec/minted_tool.jl:672-676`),
`surface="sched"` body 는 **영원히** 귀속 불가다.

Task 2 가 body 직후·재풀이 직전의 다이제스트(`world_delta_body`)를 만든다.

```
L4 = world_delta_body 의 성분 중 하나 이상이 0 이 아니다
```

- `world_delta_body === nothing` → **못 쟀다**(`false` 아님).
- 전 성분 0 → **쟀는데 세계가 안 바뀌었다**(`nothing` 아님).
- 봉투 델타(`world_delta`)는 **참고값**으로 계속 적되 L4 판정에 쓰지 않는다.
- 🔴 다섯째 축 `n_weights_changed` 가 이번에 생긴다. 런 1 의 body 가 편집한 것이 바로
  `sched.weights` 였고 네 축은 그것을 못 봤다. **단 런 1 의 body 는 `weights` 를
  project-head 정점이 아니라 `BotID` 의 정수로 색인했으므로 `haskey` 가 전부 거짓이었을
  가능성이 높다** — 즉 축을 더해도 0 이 나올 수 있고, 그 0 은 계측 실패가 아니라 **참**이다.

## 결정 24 🔴 — 음성 대조 런을 사전에 못박는다

데모의 명제는 "본 적 없는 사건에도 build 를 완주했다" 가 아니라 **"tool 덕분에 완주했다"** 이다.
후자는 tool 없는 같은 판이 있어야만 말할 수 있다.

- 대조군의 기전: `TOOL_SYNTHESIS=1` **없이** 뜬 서비스. `synthesize.py:189-193` 이
  정확히 `"1"` 일 때만 합성을 켠다(`"true"`/`"yes"` 는 안 된다). 그런 서비스는 세대 게이트를
  `exit=0` 으로 **통과하고** 런은 합성 레인이 꺼진 채 진행된다.
- **8077 을 죽이지 않는다.** 대조 서비스는 **8078** 에 따로 띄운다.
- 두 런은 같은 `DEMO_*` 환경을 쓴다. `DEMO_CASE_TAG` 만 다르다(스트림 파일이 안 겹치게).
- 🔴 **시드가 같은지 확인할 것.** 사건 발화 step 이 두 런에서 다르면 그것은 대조가 아니다.
  두 로그의 `battery drawn at step=` 줄을 대조해 같은 step 인지 적는다. **다르면 대조는
  무효이고, 그렇게 보고한다** — 사후에 시드를 맞춰 다시 돌리는 것은 되지만 그 사실을 적는다.

**대조에서 읽는 것 (사전에 고정):**

| 축 | 어디서 | 대조에 기대하는 것 |
|---|---|---|
| 완주 | `project_complete(env)` (`src/route_planning.jl:631-641`), 출력은 `src/demo_utils.jl:391-394` | 미지 — **이것이 측정 대상이다** |
| 최종 `n_closed` / `n_total` | 진행 막대 마지막 줄 | 미지 |
| 총 step 수 | `step_num` 마지막 값 | 미지 |
| `[minted]` 줄 | stdout | 대조에는 **없어야 한다** (있으면 대조가 안 된 것) |

🔴 **대조가 완주해도 데모는 죽지 않는다.** 그 경우의 정직한 진술은 "이 사건은 tool 없이도
완주하지만, tool 은 X 를 바꿨다(makespan/step/closed)" 이고, 그것을 그대로 적는다.
**완주 여부만이 유일한 결과 변수가 아니다** — step 수와 최종 closed 수도 사전에 등록한다.

## 결정 25 — 과금과 재생

- 상한 **8회**. 런 1 은 5회였다(결정 agent 1 + 합성 4단계). Task 3 이 단계 수를 안 바꾸므로
  기대값은 다시 5 이고, `/rewrite` 가 발화하면 +1 이다.
- 계수기: 캐시 DB 를 `immutable=1` 로 열어 런 전 `T` 기준 `count(store_time > T)`.
  ⚠️ `DSPY_CACHE=0` 이면 라이브 호출이 행을 **안 남긴다** — 이 계수기는 과금 원장이 아니라
  **재생 오염 대조**다(선행 결정 17). `~/.dspy_cache` 의 **파일 바이트는 세 층 모두 신뢰 불가**다.
- `/health` 의 `calls`/`billed` 는 결정 agent(`_ask`)만 센다 — 합성 레인은 안 센다.

## 결정 26 — 이월된 알려진 위험

- **R17**: `battery_report()` 는 `BATTERY_FLEET[] === nothing` 이면 던진다. 광고는 전제조건
  없이 돼 있다. body 가 그것을 부르고 던지면 그것은 **우리 쪽 결함**이지 모델의 작성 실패가 아니다 —
  그 판의 L2 실패는 그렇게 귀속한다.
- **R37**: `hot_swap_robot!` 의 `has_vertex`-만 게이트는 **미측정**이다. body 가 그것을 부르면
  그 성공 상태는 L4 의 증거가 아니고, 그 판은 L4 에 대해 `nothing` 이다.
- 새 위험: Task 2 가 `enact_minted!` 에 `probe` 키워드를 더한다. `probe` 가 던지면 삼켜야 한다.
  집행이 계측 때문에 죽으면 그 판은 **전 사다리가 무효**다.

## 런 전 체크리스트 — 전 항목 통과해야 실행한다

| # | 항목 | 방법 |
|---|---|---|
| A1 | 우리 경로에 미커밋 없음 | `git status --short` — 선재 삭제 218건은 **예외로 명시**하고 센다 |
| A2 | 전체 스위트 | `0 failed · 1 errored(Gurobi 10009) · 0 broken`, `passed ≥ 2910` |
| A3 | 산출물 바이트 게이트 | `test/world_interface_current.jl` 전 testset 초록 |
| A4 | 산출물 신원 | `sha256sum wm4spacecraft_manufacturing/core/world_interface.json` — 런 **전후** |
| B1 | 서비스 세대 | 8077 재기동 후 `REQUIRE_TOOL_SYNTHESIS=1 bash -c 'source tools/require_current_service.sh && require_current_service http://127.0.0.1:8077'` = PASS |
| B2 | 🔴 `REQUIRE_SYNTH_MULTI_AGENT` 를 **켜지 않는다** | 어떤 레인도 그 이름을 안 읽어서, 켜면 옳은 런이 `FAIL flag_off` 로 죽는다 |
| B3 | `/rewrite` 라우트 존재 | 무료 `openapi.json` 읽기. **유료 호출 금지** |
| B4 | 프롬프트 블록 크기 | 실측해 적는다. 선행값 606줄 / 29,660자와 **달라야** Task 3 이 실린 것이다 |
| C1 | 캐시 DB 기준시각 `T` | `immutable=1` 로 열어 `max(store_time)` 과 행 수. **절대 행 수를 계약으로 삼지 않는다** |
| D1 | 산출물 치우기 | `results/synth_lane_records.jsonl` 와 `tools/monitor/streams/tractor__battery_mild.jsonl` 를 `…pre-run2.jsonl` 로 |
| D2 | `DEMO_N=0` 확인 | 사건이 **하나**여야 판정이 한 줄에서 읽힌다 |

## 판정 순서 — 이 순서로만 읽는다

L0 (`wrote`) → L1 (`registered`) → L2 (`args_from` · `steps[1].status`) → L3 (`interface_calls`)
→ L4 (`world_delta_body`) → 완주(`PROJECT COMPLETE!`) → 대조와의 비교.

**아래 칸이 초록이 아니면 위 칸은 `nothing` 이지 `false` 가 아니다.**
