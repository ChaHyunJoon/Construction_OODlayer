# 사다리 L2·L3·L4 와 데모 (2026-09-04)

> 선행 설계(**구속력 있는 권위**): `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` (D9–D19).
> 선행 계획: `docs/superpowers/plans/2026-09-03-callable-world-interface.md` (Task 1~10, 커밋 `3108add4..17aac73b`).
> 이 계획은 그 설계를 **되돌리지 않는다** — 유료 런 1 이 드러낸 세 구멍을 닫고 사다리를 끝까지 올린다.

**Goal (사용자, 2026-09-04):** OOD 실패 사건에서 multi-agent LLM 이 **새 tool 을 생성**하고,
그 tool 이 **등록되고 · 인자를 받고 · 예외 없이 돌고 · 광고된 함수를 부르고 · 세계를 실제로 바꿔서**,
본 적 없는 사건에도 불구하고 **build 가 완주**한다는 것을 데모로 보인다.

---

## 0. 오늘 실측된 출발점 (유료 런 1, commit `17aac73b`)

기록 줄 원문 (`results/task11-run.log:447-449`):

```
[minted] lane=present tool=AdjustR1Operation verdict=admit applied=false partial=true
  world_maybe_dirty=true handled=true undo=none resume=issued resolve=resolved
  args_from=calls n_calls=1 n_body_names=1 registered=true impl_rejected_why=n/a
  steps=[AdjustR1Operation!:threw] reason=body threw at AdjustR1Operation! …
[minted] world_delta=closed=0 active=0 n_edges=0 n_binding_changed=0 delta_scope=body+harness_resolve
```

| 칸 | 오늘 | 막는 것 (실측된 기전) |
|---|---|---|
| L0 `wrote` | ✅ | — |
| L1 `registered` | ✅ | — |
| L2 인자채널 `args_from==:calls` | ✅ | — |
| L2 무예외 `steps[1].status === :success` | ❌ `:threw` | **예외 메시지가 기록에 안 나온다.** 메시지는 `src/respec/minted_tool.jl:1339` 이 이미 `steps[i].detail` 에 담는데, `tools/monitor/enact.jl:1601` 의 렌더가 `name:status` 만 찍고 detail 을 버린다. 결정 행에는 `steps` 자체가 실리지 않는다. |
| L3 `interface_calls ≠ []` | ❌ `[]` | **프롬프트가 필드 쓰기를 명시적으로 허락하고 함수 호출을 권하지 않는다.** `src/respec/llm_service/world_interface.py:77` 의 표제가 `"WORLD TYPES (fields you may read and write):"` 이고, 렌더된 29,660자 어디에도 "함수를 부르라"는 문장이 없다(실측). 한편 `_walk_body!`(`src/respec/minted_registration.jl:129-130`)는 필드 접근을 `calls` 가 아니라 `fields` 로 보내므로 `weights[k] *= f` 는 **구성상** L3 에 0 을 기여한다. |
| L4 `world_delta ≠ 0` 이고 귀속 가능 | ⚫ | 이유 **둘**. (a) `_world_digest`(`tools/monitor/enact.jl:913-916`)가 네 축 `closed/active/n_edges/binding` 만 읽고 **`env.sched.weights` 를 안 본다** — 이 body 가 편집한 바로 그것이다. (b) `_delta_scope`(`enact.jl:1009-1010`)는 `resolve` 태그만 보고, `resolve` 는 원시의 **선언된 `surface`** 가 `RESOLVE_SURFACES=Set(["sched","milp"])`(`src/respec/minted_tool.jl:619`) 에 들면 무조건 하네스 재풀이를 돌린다(`minted_tool.jl:672-676`) → `surface="sched"` body 는 **영원히** `body+harness_resolve` 다. 다이제스트는 집행 봉투 **바깥**에 두 개뿐(`enact.jl:1555`, `:1557`)이라 body 만의 창이 없다. |

**빌드 완주는 오늘 이미 참이다** — 같은 런의 `results/task11-run.log:592` 가 `PROJECT COMPLETE!`
(305 노드 중 287 closed 후 완주, 시뮬레이션 1m58s). 이 계획이 더하는 것은 완주 **여부**가 아니라
**완주가 tool 덕분이라고 말할 수 있는 증거**다 — 그래서 Task 5 가 음성 대조를 요구한다.

---

## Global Constraints

1. 🔴 **`git add -A` / `git add .` 금지.** 이 작업트리에는 우리 것이 아닌 **미스테이징 삭제 218건**이
   선재한다(`git status --short | grep '^ D' | wc -l` = 218). 반드시 **명시 경로만** `git add` 한다.
2. **worktree 금지** (사용자 결정 2026-09-02). 체크아웃은 하나이고 여러 세션이 공유한다.
3. **회귀 기준**: `0 failed · 1 errored(Gurobi 10009, `test/runtests.jl:80`) · 0 broken`,
   `passed ≥ 2910`. 새 testset 이 pass 수를 늘리는 것은 회귀가 아니다(선행 계획의 판정 P1).
   전체 스위트는 **22~23분**이다 — `src/` 나 `tools/` 를 바꾼 태스크만 돌린다.
4. **Julia 실행**: `julia +lts --project=.`. **Python**: `.venv/bin/python -m pytest`.
5. **DSPy 서비스를 건드리지 않는다.** PID 3161910 / `code_fingerprint 1697b61c53f3d2a2` /
   `TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 DSPY_CACHE=0` 가 살아 있다. 세대 확인은 정본 검사기
   (`src/respec/llm_service/require_current_service.sh`)로만 한다. 파이썬을 고친 뒤에는
   **재기동이 필요하다** — 그 재기동은 Task 4 가 소유한다(구현자는 안 한다).
6. **유료 호출 금지 (Task 4 제외).** 구현자와 리뷰어는 `DSPY_URL` 로 어떤 요청도 보내지 않는다.
7. 삼상 규약: `nothing` = "못 쟀다", `false` = "쟀는데 거짓". 새 필드도 이 규약을 따른다.

---

## Task 1: `:threw` 의 예외 메시지를 기록 줄과 결정 행에 싣는다

**왜.** 유료 런 1 이 `:threw` 로 죽었는데 **어떤 예외인지 어디에도 없다.** 실행자는 격리 프로브로
사후에 재유도해야 했다(`NamedTuple{(:status,)}(:success)` → `MethodError: no method matching
length(::Symbol)`). 이 구멍이 닫히기 전에는 어떤 재런도 실패 원인을 **추론으로만** 말한다.

**실측된 사실 (재유도 불필요, 그러나 실행 전에 눈으로 확인할 것):**
- `src/respec/minted_tool.jl:1338-1339` 이 이미 메시지를 담는다:
  `push!(steps, (name = r.prim.name, status = :threw, detail = first(split(sprint(showerror, e), "\n"))))`
- 성공 경로도 `detail` 을 담는다: `minted_tool.jl:1366` `push!(steps, (name=…, status=st, detail=dt))`.
  즉 **필드는 이미 있다.** 새로 만들 것이 없다.
- 버려지는 자리: `tools/monitor/enact.jl:1601`
  `" steps=[", join([string(s.name, ":", s.status) for s in r.steps], " "), "]",`
- 줄 스크러버: `enact.jl:838` `_one_line_rec(x) = String(strip(replace(x, r"\s+" => " ")))`, `_rec_line` 은 `enact.jl:835`.
- 결정 행에 `steps` 는 **실리지 않는다**. 행을 제자리 갱신하는 함수는 `record_world_delta!`
  (`enact.jl:1035-1062`)이고 오늘 `rs["world_delta"]`(`:1040`)와 `rs["interface_calls"]`(`:1053`) 둘만 쓴다.

**Step 1.** `enact.jl:1601` 의 렌더를 바꿔, `detail` 이 비어 있지 않은 스텝은
`name:status(detail)` 로 찍는다. `detail` 은 모델·예외에서 온 임의 문자열이므로
**반드시** (a) `_one_line_rec` 로 접고 (b) **200자로 자른다**(자르면 말미에 `…`).
`detail` 이 `""` 이거나 `nothing` 이면 오늘과 **바이트 동일한** `name:status` 를 찍는다.
- 근거: `enact.jl:823` 의 D8 docstring 이 `steps` 의 detail 을 개행 보유 문자열로 이미 지목했다.
- 상한 200 의 근거: 기록 줄은 grep 대상이고 스택트레이스 한 줄이 수 KB 가 될 수 있다.
  `showerror` 의 첫 줄만 담기지만 `MethodError` 의 첫 줄은 후보 메서드를 나열할 수 있다.

**Step 2.** `record_world_delta!`(`enact.jl:1035`)에 **셋째 칸** `rs["steps"]` 를 싣는다.
값은 `Vector{Dict{String,Any}}` 로 `"name"`/`"status"`(둘 다 `String`)/`"detail"`(`String`, 같은 200자 상한)
세 키. `m.steps` 가 비었으면 `[]`(빈 배열, `nothing` 아님 — "쟀는데 없다"). `m.steps` 자체가
읽히지 않으면 `nothing`.
- 🔴 함수 이름이 `record_world_delta!` 인 채로 세 칸을 싣게 된다. `enact.jl:1050` 근처에 이미
  "두 칸을 싣는다" 는 주석이 있다 — **그 주석을 갱신**하고, 이름을 안 바꾸는 이유를 한 줄로 남긴다
  (호출자가 `tools/monitor/render_demo.jl:846` 한 곳이고 이름 변경은 이 태스크의 범위 밖이다).
- `rs` 가 없거나 쓰기가 던지면 오늘의 `catch`(`enact.jl:1057`)가 그대로 삼킨다 — 렌더는 계속된다.

**Step 3 — 시험 (`test/minted_end_to_end.jl` 에 새 testset 을 **끝에** 추가).**
1. 던지는 body 를 집행해 `r.steps[1].detail` 이 비지 않음을 단언하고, **기록 줄에 그 메시지의
   특징적 부분문자열이 나타남**을 단언한다(줄은 `sprint` 이나 `redirect_stdout` 으로 잡는다 —
   이 파일에 선재하는 방식을 따를 것).
2. **음성 대조 (필수)**: 같은 단언이 Step 1 의 편집을 되돌리면 **빨개지는가**. 되돌린 사본을
   `/tmp` 에 만들어 확인하고 결과를 보고서에 적는다. **레포 안의 것은 절대 깨지 말 것.**
3. 개행 대조: `detail` 에 `"\n"` 이 든 스텝을 만들어 기록 줄이 **한 줄로 남는지** 단언한다.
4. 절단 대조: 250자 `detail` 이 200자+`…` 로 잘리는지 단언한다.
5. `rs["steps"]` 가 세 키를 갖는지, 빈 steps 가 `[]` 인지 단언한다.
   ⚠️ `test/minted_end_to_end.jl:998` 의 `@test length(row["world_delta"]) == 4` 는 **다른 키**이므로
   이 태스크는 그것을 건드리지 않는다.

**검증.** `julia +lts --project=. -e 'using Pkg; Pkg.test()'` 는 돌리지 **않는다**(22분).
대신 `test/minted_end_to_end.jl` · `test/minted_tool_enacts.jl` · `test/minted_registration.jl` ·
`tools/monitor/test_minted_wiring.jl` 을 각각 단독 실행하고 전후 수를 보고한다.
🔴 `tools/monitor/test_minted_wiring.jl:277` 의 `@test occursin("threw", out)` 이 살아남는지 확인할 것.

**커밋.** 명시 경로만: `tools/monitor/enact.jl` · `test/minted_end_to_end.jl`.

---

## Task 2: L4 의 두 구멍 — `sched.weights` 축과 body 만의 다이제스트

**왜.** 유료 런 1 의 body 는 `sched.weights` 를 편집했는데 `world_delta` 의 네 축이 전부 0 이었고,
`delta_scope` 는 `body+harness_resolve` 라 0 이든 아니든 **귀속 불가**였다. 두 결함은 독립이다.

**실측된 사실:**
- `_world_digest` — `tools/monitor/enact.jl:889`, 반환 `:913-916`
  `(closed=length(env.cache.closed_set), active=length(env.active_build_steps),
    n_edges=CB.Graphs.ne(env.sched.graph), binding=CB.assignment_binding(env.sched))`.
  가드 둘: `:911`, `:912` (`_is_countable_world_set(x) = x isa AbstractSet`, `:850`). 전부-아니면-무.
- `_world_delta` — `enact.jl:939-962`. `binding` 은 다이제스트에 있지만 **델타 출력이 아니다**;
  출력은 `(closed, active, n_edges, n_binding_changed)` 넷.
- `env.sched.weights::Dict{Int,Float64}` — 선언 `src/essential_tg_coponents.jl:215`
  (`struct OperatingSchedule`, `@with_kw`). 접근자 `get_root_node_weights` `:219`.
  레포 전체의 쓰기 자리는 `src/task_assignment.jl:367`(`empty!`)·`:371` 둘뿐.
  ⚠️ **동명이인 주의**: `src/essential_tg_coponents.jl:632` 의 `MultiDeadlineCost.weights::Vector{Float64}` 는 **무관**하다.
- 다이제스트 호출 자리는 정확히 둘: `enact.jl:1555` `local _pre = _world_digest(env)` 와
  `enact.jl:1557` `world_delta = _world_delta(_pre, _world_digest(env))`. 그 사이의 `:1556` 이
  `local r = CB.enact_minted!(env, truth, sl)` — **집행 봉투 전체**다.
- `_delta_scope` — `enact.jl:1009-1010`. `resolve` 가 어디서 오는지: `enact.jl:1626` 이
  `CB.enact_minted!` 의 `r.resolve` 를 그대로 나른다. 그 값을 정하는 것은
  `_resolve_if_needed!`(`src/respec/minted_tool.jl:669-677`)이고 판정 기준은 원시의 **선언된
  `surface` 문자열**이 `RESOLVE_SURFACES = Set(["sched","milp"])`(`minted_tool.jl:619`)에 드는지다.
  하네스 재풀이 자리: 정상 경로 `minted_tool.jl:1391`, 던진 경로 `minted_tool.jl:1356`.
- 소비자: `_world_delta_str` `enact.jl:982-986` · `record_world_delta!` 의 직렬화 dict `enact.jl:1040-1044`.

**Step 1 — 다섯째 축.** `_world_digest` 에 `weights = CB.get_root_node_weights(env.sched)` 를 더하고,
`_world_delta` 에 `n_weights_changed` 를 더한다. 세는 법은 `n_binding_changed` 와 **같은 모양**으로:
`b.weights` 를 돌며 `a.weights` 의 값과 다르거나 없는 키를 세고, `a.weights` 에만 있는 키를 더한다.
값 비교는 `!=` 가 아니라 `!isequal` (Float64 의 `NaN` 때문).
- **가드 필수.** `_world_delta` 의 `binding` 가드(`enact.jl:948`)와 **같은 이유·같은 모양**으로
  `(a.weights isa AbstractDict && b.weights isa AbstractDict) || return nothing`.
  근거: 문자열이 들어오면 `length` 가 조용히 거짓 측정값을 만든다(그 결함이 `binding` 에서 실제로 났다).
- 다이제스트 쪽 가드: `weights` 가 `AbstractDict` 가 아니면 `_world_digest` 는 `nothing`
  (전부-아니면-무 규약 유지). `env.sched` 가 없으면 오늘의 `catch` 가 이미 `nothing` 을 낸다.
- 🔴 `Dict` 는 **얕은 참조**다. `_pre` 의 `weights` 가 살아 있는 Dict 를 가리키면 body 의 편집이
  `_pre` 에도 보여 델타가 **항상 0** 이 된다. 반드시 **스냅샷을 뜬다**: `copy(...)`.
  같은 위험이 `binding` 에도 있는지 확인하고 보고서에 적는다(고치는 것은 이 태스크의 범위 밖이면 이월).
- 소비자 셋을 전부 갱신: `_world_delta_str`(다섯째 항 추가) · `record_world_delta!` 의 dict
  (`"n_weights_changed"` 키) · 결과 튜플 docstring(`enact.jl:1153-1157`).
- 🔴 **깨질 것을 미리 안다**: `test/minted_end_to_end.jl:998` `@test length(row["world_delta"]) == 4`
  → `== 5`. `enact.jl:1046-1047` 의 `_world_delta_str` 문자열을 어휘로 못박는 testset (17)
  (`test/minted_end_to_end.jl:1046,1047,1053`) 도 갱신 대상이다. 갱신은 **약화가 아니라 이동**이어야 한다 —
  단언을 지우지 말고 새 모양에 맞춰 다시 적는다.

**Step 2 — body 만의 다이제스트.** `CB.enact_minted!` 에 **선택적 키워드** `probe = nothing` 을 더한다.
`probe !== nothing` 이면 `enact_minted!` 는 body 루프가 끝난 **직후**(`src/respec/minted_tool.jl:1367`
의 `end` 뒤, `:1369` 의 캐시 재개 **앞**) 와 **던진 경로**(`minted_tool.jl:1356` 의 `_resolve_if_needed!`
**앞**) 두 곳에서 `probe()` 를 한 번 부르고 그 값을 결과 튜플의 새 필드 `body_probe` 로 나른다.
- `probe` 가 던지면 삼키고 `body_probe = nothing` (계측이 집행을 못 죽인다).
- `probe === nothing` 이면 `body_probe = nothing` 이고 **다른 모든 동작이 오늘과 동일**해야 한다.
- 결과 튜플의 모양은 `_r`(`minted_tool.jl:1210-1215`)이 소유한다 — 기본값 `body_probe = nothing` 을
  거기 더해야 모든 조기 반환이 필드를 갖는다.
- `enact.jl:1555-1557` 에서: `_pre` 를 뜬 뒤 `probe = () -> _world_digest(env)` 를 넘기고,
  `world_delta_body = _world_delta(_pre, r.body_probe)` 를 만든다.
  기존 `world_delta`(봉투 전체)는 **그대로 둔다** — 지우지 않는다.
- `_delta_scope` 는 그대로 두고, **새 상수** `"body_only(probed)"` 를 `world_delta_body` 의 scope 로
  쓴다. 즉 기록 줄이 두 쌍을 찍는다:
  `world_delta=<봉투> delta_scope=<오늘의 값> world_delta_body=<body만> body_scope=body_only(probed)`
  `r.body_probe === nothing` 이면 `world_delta_body=n/a(not measured)`.
- `record_world_delta!` 에 넷째 칸 `rs["world_delta_body"]` 를 싣는다(같은 모양, `nothing` 가능).

**Step 3 — 시험** (`test/minted_end_to_end.jl` 끝에 새 testset).
1. `sched.weights` 를 실제로 바꾸는 fixture body 로 `world_delta.n_weights_changed > 0` 을 단언.
2. **음성 대조**: 아무것도 안 바꾸는 body 로 `n_weights_changed == 0` (`nothing` 아님).
3. **얕은 참조 대조**: `copy` 를 빼면 (1) 이 빨개지는지 `/tmp` 사본으로 확인하고 보고서에 적는다.
4. `weights` 를 `"문자열"` 로 바꾼 가짜 sched 로 `_world_digest === nothing` 을 단언.
5. `world_delta_body`: `surface="sched"` 인 body 로 `delta_scope=="body+harness_resolve"` 이면서
   **동시에** `world_delta_body !== nothing` 임을 단언 — 이것이 이 Step 의 존재 이유다.
6. `probe = nothing` 일 때 `enact_minted!` 의 반환이 오늘과 같은지(회귀 대조).

**검증.** `test/minted_end_to_end.jl` · `test/minted_tool_enacts.jl` · `test/minted_registration.jl` ·
`test/payload_reprice_install.jl` · `tools/monitor/test_minted_wiring.jl` 단독 실행. 전후 수 보고.

**커밋.** 명시 경로만: `tools/monitor/enact.jl` · `src/respec/minted_tool.jl` · `test/minted_end_to_end.jl`.

🔴 **Task 1 과 같은 파일(`tools/monitor/enact.jl`)을 만진다 — 병렬로 굴리지 않는다. Task 1 다음이다.**

---

## Task 3: L3 — 프롬프트가 함수 호출을 권한다 (Python 단독)

**왜.** 모델은 인터페이스를 **읽고서 부르지 않기로** 했다. 깊이-1 폐포 수정이 먹혀 환각이 0건이었고
**바로 그래서** 필드 경로가 더 쉬운 길이 됐다. 오늘 프롬프트는 그 선택을 **명시적으로 허락**한다.

**실측된 사실:**
- `src/respec/llm_service/world_interface.py` (109줄). `build_world_interface_block()` `:75-109`.
  렌더된 블록 = **29,660자 / 606줄**, 다섯 표제:
  `_RULES`(`:43-54`, 822자) · `WORLD TYPES (fields you may read and write):`(`:77`, 7,650자) ·
  `AMBIENT WORLD STATE …`(`:86`, 503자) · `FUNCTIONS YOU CAN CALL NOW …`(`:101`, 18,078자) ·
  `FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET:`(`:106`, 2,607자).
- 렌더된 전문에 `prefer` / `rather than` / `instead of` 류의 **호출 선호 지시가 없다**(정규식 실측).
- `agent-3` = `WriteToolImpl(dspy.Signature)` `src/respec/llm_service/synthesize.py:381`.
  `impl_code` OutputField desc `:420-421`. 다른 절반은 `build_compose_context` `:688-716`.
- 광고된 **callable 인 bang 함수가 77개**다 (`swap_battery!` · `hot_swap_robot!` ·
  `dispatch_battery_courier!` · `fault_robot_and_reassign!` · `replace_robot!` · `restage_assembly!` 등).
  L3 은 도달 가능하다 — 어휘의 구멍이 아니라 **지시의 부재**다.
- L3 의 계측기(`impl_interface_calls`, `src/respec/minted_registration.jl:799-838`)는 **거절을 만들지 않는다**.
  이름 우주는 산출물의 `methods ∪ types ∪ subtypes ∪ ambient` = 215 이름. `access` 는 **안 든다**.

**Step 1 — 반환 규약의 리터럴 예시.** 유료 런 1 이 죽은 자리는 반환문이었다
(`return NamedTuple{(:status,)}(:success)` → `MethodError: length(::Symbol)`).
`_RULES`(`world_interface.py:43-54`)의 반환 규약 항목에 **복사 가능한 한 줄 예시**를 붙인다:
정확히 `return (; status = :success)`. 그리고 같은 문장을 `WriteToolImpl` 의 `impl_code`
OutputField desc(`synthesize.py:420-421`)에도 붙인다 — 설계 §1.3 의 실측대로 **출력 슬롯 옆이
모델이 실제로 읽는 자리**다.
- ⚠️ 오늘의 규약 문장을 **지우지 않는다**. 예시를 **더한다**.

**Step 2 — 호출 선호 지시.** `_RULES` 에 규약을 하나 더한다. 문구는 대략:
> Prefer CALLING the functions listed under "FUNCTIONS YOU CAN CALL NOW" over writing struct
> fields by hand. A function call carries the module's own invariants; a raw field write does not.
> Write a field directly only when no listed function produces the required effect, and say why
> in a comment.

그리고 `world_interface.py:77` 의 표제를 필드 쓰기를 **권하지 않는** 문구로 바꾼다
(예: `WORLD TYPES (what the world is made of; you may read these, and write them only as a last resort):`).
- ⚠️ **필드 쓰기를 금지하지 않는다.** 금지하면 거짓 거절 표면이 생기고, D6 이 감춘 다섯 능력
  때문에 어떤 사건은 필드 경로 말고 길이 없다. 이것은 **선호**이지 규칙이 아니다.

**Step 3 — 그 지시가 실제로 렌더되는지 시험.** `src/respec/llm_service/` 의 선재하는 pytest 규약을 따라
새 시험을 더한다: 렌더된 블록에 (a) 리터럴 `return (; status = :success)` 가 있다 (b) 호출 선호
문장이 있다 (c) 표제가 더 이상 필드 쓰기를 무조건 허락하지 않는다.
**음성 대조**: 각 단언이 그 편집을 되돌리면 빨개지는지 `/tmp` 사본으로 확인하고 보고서에 적는다.

**Step 4 — 회귀.** 블록의 자·줄 수를 못박는 선재 시험이 있으면 **실측값으로 갱신**하고, 갱신 전후
값을 둘 다 보고서에 적는다(이 레포는 "인용한 수" 로 반복해 틀렸다).

**검증.** `.venv/bin/python -m pytest src/respec/llm_service/ -q` — 오늘의 기준은
**368 passed / 5 skipped** 다. 새 시험 수만큼 늘어야 하고 failed 는 0 이어야 한다.
🔴 **서비스를 재기동하지 않는다** (Global Constraint 5). 유료 호출을 하지 않는다.

**커밋.** 명시 경로만: `src/respec/llm_service/world_interface.py` ·
`src/respec/llm_service/synthesize.py` · 새/수정 pytest 파일.

**Task 1·2 와 파일 집합이 서로소다 — 병렬로 굴린다.**

---

## Task 4: 사전등록 v3 + 유료 런 2 (컨트롤러가 소유한다)

**Step 1 — 사전등록 v3** (`docs/superpowers/reports/2026-09-04-ladder-run2-preregistration.md`).
선행 문서 `docs/superpowers/reports/2026-09-03-task11-measurement-preregistration.md` 를 상속하되
**결과를 보기 전에** 아래를 못박는다:
- 🔴 **L2 술어 교정.** 선행 사전등록의 `steps[1].status !== nothing` 은 `:threw` 로도 충족돼
  설계 §0 의 명제("예외 없이 끝났다")와 갈린다(유료 런 1 이 실증). **새 술어:
  `args_from == :calls` ∧ `steps[1].status === :success`.** `:threw` 는 **거짓**이지 `nothing` 이 아니다.
- L3 술어: 결정 행의 `interface_calls` 가 비어 있지 않은 `Vector{String}`. `nothing` = 못 쟀다.
  목록으로 읽는다(선행 결정 13) — 생성자 히트는 약한 증거로 따로 적는다.
- L4 술어: **`world_delta_body`** 로 읽는다(Task 2). 봉투 델타는 참고값이다.
  `world_delta_body === nothing` = 못 쟀다. 전 성분 0 = 쟀는데 안 바뀌었다.
- 🔴 **음성 대조 런을 사전에 못박는다** (Step 3). 데모의 명제는 "tool 덕분에 완주했다" 이므로
  tool 없는 같은 판이 있어야 한다.
- 알려진 위험 이월: R17(`battery_report` 가 `BATTERY_FLEET[]===nothing` 에서 던진다) ·
  R37(`hot_swap_robot!` 의 `has_vertex`-만 게이트는 **미측정** — body 가 그것을 부르면 그 성공
  상태는 L4 증거가 아니다).
- 과금 상한 **8회**. 계수기는 캐시 DB 를 `immutable=1` 로 열어 `count(store_time > T)` (선행 결정 17).
  ⚠️ `DSPY_CACHE=0` 레짐에서는 행이 안 남으므로 이것은 **과금 원장이 아니라 재생 오염 대조**다.

**Step 2 — 런 전 체크리스트 (전 항목 통과해야 실행).**
1. `git status --porcelain` 에 **우리 경로**의 미커밋이 없다(선재 삭제 218건은 예외로 명시).
2. 산출물 바이트 게이트: `test/world_interface_current.jl` 초록.
3. 서비스 세대: `src/respec/llm_service/require_current_service.sh` 가 PASS.
   **Task 3 이 파이썬을 고쳤으므로 반드시 재기동**하고 새 `code_fingerprint` 를 적는다.
4. `/rewrite` 라우트 존재 (무료 `openapi.json` 으로 확인 — 유료 호출 금지).
5. 산출물 `sha256` 을 런 **전후로** 뜬다.
6. 프롬프트 블록의 자·줄 수를 런 전에 실측해 적는다(선행 값 606줄 / 29,660자 대조).

**Step 3 — 두 런.** 실측(recon): 런 하나는 end-to-end **약 4.5분**(시뮬레이션 1m58s).

🔴 **음성 대조의 기전은 실측으로 이미 알려져 있다** (`validation-phase3.md:117-124`):
`TOOL_SYNTHESIS=1` **없이** 뜬 서비스는 세대 게이트를 `exit=0` 으로 **통과하고**, 런은
합성 레인이 조용히 꺼진 채 진행된다. 그것이 대조군이다 — 같은 시드·같은 사건·같은 라우터,
tool 만 없다. 대조군은 두 번째 uvicorn 을 **다른 포트(8078)** 에 띄워 만든다(8077 을 죽이지 않는다).

```bash
# 대조 서비스 (tool 합성 OFF)
cd src/respec/llm_service && DSPY_CACHE=0 \
  ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8078 &

# (A) 음성 대조
env DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_CASE_TAG=battery_mild_control \
    DEMO_BATTERY_STEPS=40,120 DEMO_POLICY=dspy DEMO_ANIM=0 DSPY_URL=http://127.0.0.1:8078 \
    julia +lts --project=. tools/monitor/render_demo.jl 2>&1 | tee results/run2-control.log

# (B) 처치 — 유료
env REQUIRE_TOOL_SYNTHESIS=1 \
    DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_BSOC=0.45 DEMO_CASE_TAG=battery_mild \
    DEMO_BATTERY_STEPS=40,120 \
    DEMO_POLICY=dspy DEMO_ANIM=0 DSPY_URL=http://127.0.0.1:8077 \
    julia +lts --project=. tools/monitor/render_demo.jl 2>&1 | tee results/run2-treatment.log
```
- 🔴 **`REQUIRE_SYNTH_MULTI_AGENT=1` 을 절대 켜지 않는다** — 어떤 레인도 `SYNTH_MULTI_AGENT` 를
  읽지 않아서, 켜면 **옳은 런이** `FAIL flag_off` 로 죽는다(`validation-phase3.md:130-137`).
- `REQUIRE_TOOL_SYNTHESIS=1` 은 **julia 줄에** 있어야 한다(`render_demo.jl:737-746` 이 환경을 그대로 넘긴다).
- 런 전에 두 산출물을 옆으로 치운다:
  `results/synth_lane_records.jsonl` → `…pre-run2.jsonl`,
  `tools/monitor/streams/tractor__battery_mild.jsonl` → `…pre-run2.jsonl`.
- **완주 판정의 정본은 `PROJECT COMPLETE!` 문자열이 아니라** `project_complete(env)`
  (`src/route_planning.jl:631-641`) = `ProjectComplete` 템플릿 노드가 `cache.closed_set` 에 있는가.
  출력 자리는 `src/demo_utils.jl:391-394` (`PROJECT COMPLETE!` / `PROJECT INCOMPLETE!`).

**Step 3b — 8077 재기동** (Task 3 이 파이썬을 고쳤으므로 필수):
```bash
kill 3161910
cd src/respec/llm_service && TOOL_SYNTHESIS=1 SYNTH_MULTI_AGENT=1 DSPY_CACHE=0 \
  ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077 \
  >> ../../../results/run2-service.log 2>&1 &
REQUIRE_TOOL_SYNTHESIS=1 bash -c 'source tools/require_current_service.sh && \
  require_current_service http://127.0.0.1:8077'
```

**Step 4 — 판정.** 설계 §0 의 L0→L4 순서로 읽고, **결과를 보고 술어를 바꾸지 않는다.**
`PROJECT COMPLETE!` 여부와 최종 `n_closed/n_total` · step 수를 두 런에서 비교한다.

---

## Task 5: 데모 산출물

Task 4 의 두 런에서, 사용자가 화면에 띄울 수 있는 하나의 문서를 만든다:
사건(무엇이 OOD 였나) → 라우터의 escalate 줄 → 세 agent 의 stages → 모델이 쓴 body 원문 →
등록·인자·집행 기록 줄 → 사다리 L0~L4 표(증거 필드와 함께) → 처치 vs 음성 대조의 완주 비교.
**수는 전부 두 런의 산출물에서 뽑는다 — 이 계획서나 선행 보고서에서 인용하지 않는다.**
