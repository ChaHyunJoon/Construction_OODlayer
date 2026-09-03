# 생성 원시 합성 — 설계 (2026-09-03)

원시 인벤토리를 없애고, agent-3 을 **Julia 구현 작성자**로 교체한다. OOD 사건에서 LLM 이
기존 어휘를 조합하는 대신 **본 적 없는 원시의 코드를 써서** 등록하고 집행한다.

## 1. 동기 — 실측

**(a) 지금 만들어지는 것은 새 도구가 아니다.** 기록된 모든 판의 body 길이가 **1** 이다:

| 런 | reach | body |
|---|---|---|
| F2 mild · F7 mild · F8 mild | needs_primitive / composed / needs_primitive | `[release_pending_assignments]` |
| F8 zone | composed | `[translate_whole_build]` |
| 나머지 5판 | needs_primitive | `[]` |

집행 가능한 원시가 8개이고 body 가 길이 1이면 "새 tool" 의 공간은 **8개**다. 미리 저작할 수
있다. 이 레인이 재는 것은 발명이 아니라 **8지선다**다.

**(b) 빈 body 는 agent-3 의 결함이 아니다.** 라이브 mild 판(2026-09-03,
`results/synth_lane_records.jsonl`):

```
body_first       = "No body can be composed from the current inventory."
calls            = []          calls_unreadable = false
missing_primitive= "The inventory lacks any primitives that can modify a robot's
                    speed or efficiency directly."
```

`calls=[]` 이고 `calls_unreadable=false` 이므로 **파싱 실패가 아니라 명시적 거절**이다.

**(c) 거절은 옳다 — 어휘가 배관 때문에 좁다.** 19개 중 집행 가능 8개. 못 부르는 11개 중
**9개가 같은 이유(`arity`)** 다: impl 이 레지스트리 `params` 를 위치인자로 받는데 바인더는
`harness_args` 로만 위치인자를 만들고 params 는 키워드로 넘긴다. 그 9개 안에 **배터리 축이
통째로** 있다(`swap_battery` · `dispatch_battery_courier` · `replace_robot` ·
`hot_swap_robot` · `pop_spare` · `deprioritize_agent`). 배터리 사건에 쓸 원시가 하나도 없다.

`_enactability` 는 이것을 **정당하게** 막는다 — 안 막으면 호출 시점 `MethodError` 를 집행부의
`try` 가 `:admit` 으로 보고해 거짓 admit 이 된다. 8개 제한은 교육과정이 아니라 배관의 결과다.

## 2. 결정 (2026-09-03, 사용자)

| # | 결정 |
|---|---|
| D1 | 산출물은 **집행되는 코드**다 (명세가 아니라) |
| D2 | 생성 코드는 **라이브 세계에 바로** 실행된다 (사본 검증 없음, undo 없음) |
| D3 | 작성 agent 가 보는 것은 **세계 스키마 + 공개 API 시그니처**(구현 비공개) |
| D4 | 생성 원시는 **등록**되어 어휘에 남는다 (런 스코프) |
| D5 | 접근 **A** — agent-3 을 작성자로 교체(인벤토리 제거). 조합 단계는 없앤다 |
| D6 | API 표면 = `names(CB)` **그대로**(147 함수 / 208 메서드). 비공개 impl 10개는 **안 보여준다** |
| D7 | ψ 는 합성 기록에서 **뺀다** |
| D8 | 단일 agent 레인(`SynthesizeTool`)은 **삭제**한다 |

🔴 **D6 의 귀결:** 모델은 `release_pending_assignments!` 를 모른다 — 지금까지 유일하게 집행에
성공한 함수다. "배정 간선을 뗀다" 를 `sched`·`cache` 를 상대로 처음부터 다시 써야 한다.
그것이 가능한지가 이 설계의 **첫 번째 실현 가능성 위험**이고 첫 측정 대상이다.

## 3. 구조

```
agent-1 observe ──▶ agent-2 design (그대로)
                          │  spec (tool_name · params · mechanism)
                          ▼
agent-3  WriteToolImpl  ◀── world_interface.json (스키마 + 208 시그니처)
                          │  impl_name · impl_code · params · calls · surface · reversible · wrote
                          ▼
Julia: 규약 검사 → Core.eval(ConstructionBots, code) → 런-스코프 표에 등록
                          ▼
                  기존 enact_minted! (body_names=[impl_name], calls 로 인자 바인딩)
```

계약 (B)(agent-2 의 알파벳 실명)와 F2 의 **redaction 은 폐지된다** — 숨길 인벤토리가 없다.

## 4. `world_interface.json`

`primitive_registry.json` 과 **같은 패턴**: Julia 가 생성하고 두 언어가 읽는 한 파일.

```json
{
  "generated_from": "<git rev>",
  "types":   [{"name": "PlannerEnv", "fields": [{"name": "sched", "type": "OperatingSchedule"}, ...]}],
  "methods": [{"name": "reform_stuck_teams!", "signature": "(env::PlannerEnv; min_ready, snap_all)"}]
}
```

- **타입**: `PlannerEnv` 에서 시작해 그 필드 타입을 **1단계** 전개한다(무한 전개 금지).
- **메서드**: `names(CB)` 의 함수 전부, 메서드마다 한 줄.
- 게이트: 파일이 현행 코드와 일치하는지 재생성해 대조한다(`code_fingerprint` 와 같은 논거).

## 5. `WriteToolImpl` 계약

**입력**: `spec`(agent-2 명세 + 물리 원칙 + agent-1 로그), `world_interface`

**출력**

| 필드 | 뜻 |
|---|---|
| `impl_name` | Julia 함수 이름, `!` 로 끝난다 |
| `impl_code` | **단 하나의** `function … end` |
| `params` | 키워드 인자의 JSON 스키마(`bind_primitive_args` 의 타입 검사가 읽는다) |
| `calls` | 이 사건에서 넘길 실제 인자값 — 기존 B1 채널 그대로 |
| `surface` · `reversible` | 기록용 |
| `wrote` | 못 쓰겠다는 자기신고 (지금의 `reach` 자리) |

**규약 다섯** — 어기면 세계를 건드리기 **전에** `:reject`:

1. `function NAME(env; k=…, …)` — `env` 만 위치, 나머지 전부 키워드(기본값 필수).
   🔴 이러면 `_enactability` 의 arity·kwargs 연언지를 **구성상** 통과한다.
2. 메서드는 정확히 하나.
3. `_step_status` 가 읽을 수 있는 status 를 반환한다.
4. 최상위 표현식은 그 `function` 하나뿐 — 상수·매크로·다른 정의 금지.
5. 🔴 이름이 `ConstructionBots` 에 **이미 있으면 거절**. `Core.eval` 이 기존 이름을 덮으면
   시뮬레이터 코드를 런타임에 교체하는 것이고, 이 사슬에서 가장 나쁜 사고다.

## 6. 등록과 집행

- `register_minted_primitive!(name, code, params, surface, reversible)` — 규약 검사 → `Core.eval`
  → 런-스코프 표에 항목 추가. 실패는 **거절 문자열**이지 예외가 아니다.
- 🔴 **world age**: `Core.eval` 직후 정의된 함수는 현재 world 에서 직접 못 부른다.
  `enact_minted!` 의 호출 자리는 `Base.invokelatest` 여야 한다.
- 표는 **런 스코프**다. 파일에 안 쓴다 — 런끼리 오염되지 않는다.
- 그 밖의 집행 경로(`bind_primitive_args` · 타입 검사 · `zone_keys` 강제 · `args_from` ·
  `partial`/`world_maybe_dirty`)는 **손대지 않는다**.

## 7. 지워지는 것

이미 삭제됨: `core/primitive_registry.json` · `core/primitive_registry.py` ·
`core/test_psi_operational_primitives.py` · `test/primitive_registry_resolves.jl` ·
`test/minted_tool_resolves.jl` · `features_agnostic.py` 의 운용 원시 ψ 표.

이 계획에서 삭제: `synthesize.py` 의 `SynthesizeTool` · `maybe_synthesize` ·
`build_inventory_block` · `primitive_inventory_lines` · `predicate_inventory_lines` ·
`redact_inventory_names` · `_REDACTED_NAME` · `_inventory_names` · `parse_body` ·
psi/psi_stats 계열 · `SYNTH_MULTI_AGENT` 플래그 · `run_synthesis` 의 분기.

## 8. 기록

- ψ 계열 필드 제거(D7).
- `calls` · `calls_match_body` · `calls_flat` · `calls_unreadable` · `args_from` · `n_calls` 유지.
- 신설: `impl_name` · `impl_code` · `impl_rejected_why`(규약 위반 사유) · `registered`.

## 9. 위험

| 위험 | 상태 |
|---|---|
| 🔴 모델이 export 안 된 능력(`release_pending_assignments!`)을 처음부터 못 쓸 수 있다 | D6 의 의도된 대가. 첫 측정 대상 |
| 🔴 undo 없음 + 라이브 실행 → 생성 코드가 던지면 세계는 절반 | D2 의 의도된 대가. `partial=true` 로 기록 |
| world age 를 놓치면 `MethodError` | `invokelatest` 로 못박고 시험으로 잡는다 |
| 이름 충돌로 시뮬레이터 코드 덮어쓰기 | 규약 5 로 거절 |
| 어휘가 사라져 스위트가 크게 빨개진다 | 의도된 중간 상태. 이 계획이 닫는다 |
