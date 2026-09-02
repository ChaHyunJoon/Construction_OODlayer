# Task 7 — 알파벳: `forbid_heavy_cargo` 추가, `reprice_agent_by_payload` 제거

> **선행:** Task 3 (보관소가 있어야 원시가 넣을 곳이 생긴다).

## 무엇을 하는가

**추가**: 원시 `forbid_heavy_cargo(agent, n)` — 하는 일은 §Task 3 보관소에
`{agent → n}` 을 넣는 것뿐이다.

**제거**: `reprice_agent_by_payload` 를 **레지스트리에서만** 뺀다(사용자 결정 2026-09-01).
🔴 `src/navigator/payload_bias.jl` 과 `test/payload_*.jl` 은 **그대로 둔다** —
무효함을 보여주는 음성 대조이고, `_payload_factor` 는 "1대당 부담" 계산에 재사용된다.
κ 설계가 바뀌면 되살릴 수 있다.

**왜 빼는가**: 실측상 argmin 을 못 움직인다. 두 판·전 체크포인트·`light_bias` 32 까지
대상 로봇이 일을 하나도 안 잃고, 음성 대조와 `n_reassigned` 이 완전히 같다. 원인은 원리적이다 —
그 로봇을 밀어내면 운반 에너지가 **9.4배** 비싸지고(2.375 → 22.25) makespan 차이는 **0** 이라,
목적값 차이 전부가 에너지항이다. 남겨두면 모델이 무효한 재료를 골라 `handled=true` 인데
세계는 바이트 동일한 판이 생긴다.

## Files

- Modify: `wm4spacecraft_manufacturing/core/primitive_registry.json`
- Modify: `src/respec/minted_tool.jl` — 표 셋
- Modify: `test/minted_tool_enacts.jl` — 게이트 상수와 개수
- Modify: `tools/monitor/test_minted_wiring.jl` · `test/runtests.jl` — 개수 산문
- Create: `src/…` 어딘가에 `forbid_heavy_cargo!(env; agent, n)` (구현자가 위치 정함)

## 🔴 기존 게이트가 자동으로 잡는 것 — 미리 알고 가라

`test/minted_tool_enacts.jl` 에 이런 게이트가 있고, 알파벳이 바뀌면 **먼저 빨개진다**:

- `ENACTABLE_TODAY` 상수(현재 8개 이름) 와 `length(tbl) == 19`
- 게이트 (11)(13): `keys(SILENT_SUCCESS_STATUSES) == ENACTABLE_TODAY`,
  `keys(WORLD_UNCHANGED_STATUSES) == ENACTABLE_TODAY`,
  `keys(PRIMITIVE_RESUMES_CACHE) == ENACTABLE_TODAY`
- 게이트 (12): `REGISTRY_SURFACE_TODAY` 가 이름→impl 짝과 `params` 키를 못박는다
- 불변식: 원시마다 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`

⟹ **표를 채우기 전까지는 빨간 게 정상이다.** 그것이 설계다.

## 새 원시의 성질 — 표에 어떻게 넣는가

`forbid_heavy_cargo!` 는 보관소에 항목 하나를 넣고 끝난다. 세계(스케줄·씬트리·캐시)를
**안 건드린다**. `reprice_agent_by_payload` 와 **같은 성질**이므로 그 행을 참고하라:

```julia
SILENT_SUCCESS_STATUSES:  "forbid_heavy_cargo" => Set([:banned, :unknown_agent])
WORLD_UNCHANGED_STATUSES: "forbid_heavy_cargo" => Set([:banned, :unknown_agent])
PRIMITIVE_RESUMES_CACHE:  "forbid_heavy_cargo" => false
```

🔴 **`:banned` 도 조용한 성공이다.** 이 원시가 노리는 적응(재풀이가 다른 계획을 고르는 것)은
이 원시의 반환이 아니라 **뒤이은 MILP 재풀이**의 몫이다. `reprice_agent_by_payload` 에서
`:repriced` 를 조용한 성공으로 넣은 것과 같은 논거다(S2 lane Ruling 5).

⚠️ 반환 상태 이름(`:banned` 등)은 **실제 구현이 내는 값과 일치해야 한다.** 구현을 먼저 쓰고
`return` 문을 읽어서 표를 채워라 — 추측하지 마라.

- [ ] **Step 1: 원시 함수를 쓴다**

```julia
"""
    forbid_heavy_cargo!(env; agent::AbstractString, n::Integer = 1) -> (; status, agent, n)

`agent` 가 1대당 부담 상위 `n` 개 화물을 맡지 않도록 지속 금지를 등록한다.

🔴 **이 함수 자체는 세계를 안 바꾼다.** `STANDING_CARGO_BANS` 에 항목 하나를 넣을 뿐이고,
효과는 **다음 MILP 정식화**가 그것을 읽을 때 난다. 그래서 `:banned` 도 조용한 성공이다.

status: `:banned` | `:unknown_agent`
"""
```

⚠️ `agent` 는 **모듈 한정 문자열**로 온다(`"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(4)"`).
손으로 짧게 쓴 형태는 조용히 `:unknown_agent` 가 된다 — 이 레포가 이미 데인 자리다.
문자열 → `AbstractID` 해석에 실패하면 **`:unknown_agent` 를 돌려라**(던지지 마라).

- [ ] **Step 2: 레지스트리 항목을 더한다**

```json
{
  "name": "forbid_heavy_cargo",
  "surface": "milp",
  "params": {
    "agent": {"type": "string", "description": "robot that must not take its heaviest pending cargo"},
    "n": {"type": "integer", "minimum": 1, "maximum": 3,
          "description": "how many of that robot's heaviest pending cargo items to forbid"}
  },
  "mechanism": "...",
  "when_to_use": "...",
  "reversible": false,
  "consumes": [],
  "preconditions": ["inert until the harness's automatic post-body MILP re-solve reads it; do NOT add a re-solve step to the body"],
  "gate": null, "gate_arity": null,
  "impl": "forbid_heavy_cargo!",
  "harness_args": ["env"],
  "psi": { ... 10축 전부 ... },
  "source": "..."
}
```

🔴 `psi` 는 **10축 전부**를 실어야 한다. 하나라도 빠지면 `primitive_registry.py` 가
**import 시점에 큰 소리로 죽는다**(그게 설계다). 축 이름과 순서는 JSON 최상위 `psi_axes` 가
단일 진실원이다. `a_reversible` 은 항목의 `reversible` 과 **일치해야** 한다.

🔴 `mechanism` 은 프롬프트에 **전문 그대로** 실린다. 함정을 반드시 적어라 —
"이 원시는 혼자서는 아무 효과가 없고, harness 가 body 뒤에 자동으로 도는 재풀이가 읽을 때
효과가 난다". 그리고 **"재풀이를 붙여라"는 지시를 쓰지 마라** — 그 문구가 모델에게
알파벳에 없는 단계를 지어내게 만든다(2026-09-01 에 `commit_respec` 이 그렇게 나왔다).

- [ ] **Step 3: `reprice_agent_by_payload` 항목을 레지스트리에서 지운다**

JSON 을 재직렬화하지 말고 **해당 객체 블록만 텍스트로 지워라**(포맷이 통째로 바뀌면 리뷰가
불가능해진다). 지운 뒤 `json.loads` 로 파싱되는지 확인하라.

- [ ] **Step 4: 표 셋과 게이트 상수를 갱신한다**

`src/respec/minted_tool.jl` 의 세 표에서 `reprice_agent_by_payload` 행을 빼고
`forbid_heavy_cargo` 행을 넣는다. 그리고 **개수 산문을 실측으로 갱신하라**:

```julia
# 실제 숫자를 재는 스크립트 (산술로 추정하지 마라)
tbl = CB.PRIMITIVE_TABLE()
en = sort([n for n in keys(tbl) if CB.resolve_primitive(n).enactable])
println(length(tbl), " 중 ", length(en), " : ", en)
```

`test/minted_tool_enacts.jl` 의 `ENACTABLE_TODAY` 와 `length(tbl) == N`,
`tools/monitor/test_minted_wiring.jl` 의 `PRIMITIVE_TABLE()` 개수, `test/runtests.jl` 의 산문을
**그 실측값으로** 고쳐라.

- [ ] **Step 5: 프롬프트 게이트를 확인한다**

```
.venv/bin/python -m pytest src/respec/llm_service/test_synthesize.py -q
```
🔴 `test_every_alphabet_name_is_visible_in_the_prompt` 가 새 원시 이름이 프롬프트에 보이는지
자동으로 잰다. `test_context_carries_every_operational_mechanism_verbatim` 의 개수 tripwire
(`== 19`)도 새 값으로 고쳐야 한다 — **의도적으로** 사람이 보게 만든 장치다.

- [ ] **Step 6: 전체 시험** — 기준선 2279 / 0 fail / 1 error(개수 변화만큼 총계가 움직인다.
      움직인 양을 **설명할 수 있어야** 한다 — per-primitive 루프가 몇 개인지 세어 산술을 맞춰라)
- [ ] **Step 7: 커밋** (경로 명시, `grep -c '^D'` 가 0)
