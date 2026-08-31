# SDD ledger — plan: docs/superpowers/plans/2026-08-30-minted-tool-enactment-and-render.md

Spec (binding authority): docs/superpowers/specs/2026-08-26-tool-synthesis-lane-design.md — present, read.
Branch: oracle-rebuild-night-2026-08-10
Start HEAD: 0f895b46
Validator agent: `.claude/agents/minted-tool-validator.md` (opus, effort=max) — created this session.

## Setup rulings

Ruling: work in the CURRENT working tree, not a fresh git worktree — 이유: (a) 이 트리에는
212개 미커밋 삭제가 있어 worktree 는 다른 세계가 된다, (b) CLAUDE.md 가 "결정성의 단위는
프로세스가 아니라 디렉토리(컴파일 캐시)" 라고 실측을 적는다 — T0 기준선과 T5/T9 대조판은
반드시 같은 디렉토리에서 굴러야 한다. worktree 를 쓰면 이 계획의 유일한 대조축이 무너진다.
— 대가(틀렸을 때): main 이 아닌 기능 브랜치이긴 하나 격리가 없어 실패한 태스크의 잔재가
작업 트리에 남는다. 각 태스크가 커밋으로 끝나므로 `git checkout -- <path>` 로 회수 가능.

Ruling: `git add -A` / `git add .` / `git commit -a` 금지를 모든 implementer 브리프에 싣는다
— 작업 트리에 212개 남의 삭제가 미커밋 상태다(CLAUDE.md 명시). 명시 경로만 add.
— 대가(틀렸을 때): 남의 작업 삭제를 통째로 커밋한다. 회수는 revert 로 가능하나 비싸다.

Ruling: 태스크 실행 순서를 **T8 → T0 → T1 → T2 → T3 → T4 → T5 → T6 → T7 → T9 → T10** 으로 한다.
계획서 §3 이 직접 "세션이 하나면 T8 을 맨 앞에 두는 것이 낫다 — 0.5h 짜리이고, 그 표가 틀리면
Phase D 전체가 무의미해진다" 고 적는다. T8 은 유료 호출 0, 코드 변경 0(게이트만 추가)이라
앞에 두는 비용이 없다.
— 대가(틀렸을 때): 없음. 순서만 바뀌고 의존은 지켜진다.

## Pre-flight conflict scan

(작성 중 — validator 1라운드 결과와 함께 확정한다)

### 태스크 쌍 — 공유 파일 / 인터페이스

| 쌍 | 한쪽이 내는 것 | 다른 쪽이 받는 것 | 발견 |
|---|---|---|---|
| T0 → T5, T9 | `results/baseline_2026-08-30/*.log` | 대조군 인용 | 같은 디렉토리·같은 시드여야 성립. 위 worktree 룰링이 이것을 지킨다 |
| T0 → T4 | `render_demo.jl::enact_recovery!` 의 계측 println | T4 가 같은 파일의 `policy_producer` 를 고친다 | 순차라 충돌 없음. **단 T0 의 두 기준선 렌더는 T4 의 코드 변경 전에 끝나야 한다** — T4 뒤에 돌리면 그것은 기준선이 아니다 |
| T1 → T4 | `decision.synth_lane` (NamedTuple 필드) | `enact_minted_decision!(env,truth,decision)` | ⚠️ T4 는 `policy_producer` 에 도달하는 객체가 `decide_all` 의 반환 그 자체라고 가정한다. 검증 항목 H2 |
| T1 → T7 | `policy.jl` (`service_decide`, `decide_all`) | T7 이 같은 두 함수에 `nodes` 채널을 더한다 | 순차라 충돌 없음 |
| T2 → T3 | `resolve_primitive` / `PRIMITIVE_TABLE` | 같은 파일 뒷부분 | 없음 |
| T2 → T7 | `src/respec/minted_tool.jl` 의 include 지점 | T7 이 같은 파일에 `open_node_descriptors` 를 넣는데 그것은 `BATTERY_FLEET`·`_payload_mass`·`cargo_id`(navigator) 를 쓴다 | 🔴 **충돌**. T2 는 include 지점을 `respec.jl` 로 정하고 "안 되면 ConstructionBots.jl 끝" 이라는 조건부를 남긴다. 그 조건부를 T2 시점에 **T7 의 요구까지 보고** 한 번에 결정해야 한다 — 아니면 T7 에서 include 를 다시 옮기게 되고, 옮기는 순간 T2·T3 의 게이트가 다른 세계에서 돈다. 검증 항목 H3 |
| T2 게이트 ← T6 | `test/minted_tool_resolves.jl` 의 "(1) 모든 원시 이름이 해석된다" | T6 이 레지스트리에 `reprice_agent_by_payload` 를 **추가**한다 | 🔴 T6 이 `impl` 심볼을 CB 에 정의하지 않거나 include 를 빠뜨리면 **T2 의 게이트가 T6 에서 빨개진다**. 설계대로이지만 T6 브리프에 이 사실을 실어야 한다 |
| T3 게이트 ← 레지스트리 | `restage_all_blocked` 의 `surface`/`reversible`/`params` | T3 의 (3)(5)(6)(7) 이 리터럴로 단언 | 검증 항목 B. 레지스트리와 다르면 게이트가 처음부터 빨갛다 |
| T3 바인더 ← 레지스트리 | `harness_args` 값의 전체 집합 | `bind_primitive_args` 가 `"env"` 만 처리하고 나머지는 거절 | 🔴 `"env"` 아닌 harness arg 를 가진 원시는 **영구히 집행 불가**인데 T2 게이트는 초록이다(해석만 본다). 검증 항목 B |
| T6 → T7, T9 | `_payload_mass(env,node,fleet.params)` 호출 규약 | T7 의 `open_node_descriptors` 가 같은 호출을 반복 | 시그니처가 하나여야 한다. 검증 항목 D |
| T6 → T9 | `EDGE_COST_MULTIPLIER[]` 클로저 설치 | 렌더 레인이 `enable_battery!` 로 이미 훅을 점유 | 🔴 T6 의 `clear_payload_bias!` 가 훅을 `battery_edge_multiplier` 로 **되돌린다** — 원래 `nothing` 이었던 프로세스에서 이것은 복원이 아니라 **설치**다. nominal 판의 목적식을 바꿀 수 있다. 검증 항목 D/H7 |
| T7 → T9 | `nodes` 프롬프트 채널 | T9 의 라이브 발화가 이 채널에 걸려 있다 | 🔴 서비스 재기동 없이는 낡은 `MacroRequest` 가 `nodes` 를 **조용히 버린다**(extra=ignore). T9 브리프에 재기동 필수 |
| T8 → T5, T9 | 없음 (게이트만) | 메뉴 `["NOOP"]` 이라는 전제 | T8 이 앞에 서는 이유. 검증 항목 C |

### 태스크 내부 자기모순

| 태스크 | 발견 |
|---|---|
| T0 | 자기일관. 단 Step 2 의 zone 기준선이 `DEMO_POLICY=canonical` 인데 T5 의 대조판은 `DEMO_POLICY=router DEMO_ROUTER=auto` 다 — **두 판의 레인이 다르다.** 대조표(T10)에서 "canonical vs dspy+합성" 을 "무합성 vs 합성" 으로 읽으면 거짓이 된다 |
| T1 | 자기일관. 게이트가 `policy_entry` 를 직접 부르므로 서비스 불필요 |
| T2 | 🔴 include 지점이 **조건부**로 적혀 있다(위 T2→T7 행). 계획서가 스스로 "순서가 어긋나면 …" 이라고 적으므로 미해결 분기다 |
| T3 | 자기일관. 게이트 (5)(6)(7) 이 실제 레지스트리 내용에 의존 |
| T4 | 🔴 게이트를 `tools/monitor/test_minted_wiring.jl` 에 둔다 — `test/` 밖이므로 `test/runtests.jl` 이 안 집는다. 계획서 §1-1 "게이트는 …" 규약과 CLAUDE.md 의 "unwired gate is an orphan" 에 어긋난다. 검증 항목 H6 |
| T5 | 자기일관. Step 3 이 "고쳐도 되는 것/안 되는 것" 을 명시 |
| T6 | 🔴 게이트 (1) 이 `clear_payload_bias!()` 를 먼저 부른 뒤 훅이 `battery_edge_multiplier` 인지 단언한다 — `clear_payload_bias!` 의 정의가 정확히 그것을 설정하므로 **실패할 수 없는 게이트**일 가능성. 검증 항목 H7 |
| T7 | 🔴 `env.cache.closed_set` 원소 타입이 미확인이고, 틀리면 필터가 **조용히 무동작**이라고 계획서가 스스로 적는다. 검증 항목 H5 |
| T8 | 게이트가 `battery_arms(nothing, …)` 를 부른다 — 시그니처가 `Real` 을 요구하면 컴파일 실패. 검증 항목 C |
| T9 | 자기일관 |
| T10 | 자기일관 (보고서만) |

## Validator Round 1 — 9 CONFIRMED / 11 REFUTED / 2 UNVERIFIABLE (paid calls 0)
전문: `validation-round1.md`. 아래 룰링은 전부 그 보고서의 증거에 대고 내렸다.

Ruling R1 (§0 [16] 반증 — `enact_recovery!` 는 **호출자가 0개**인 죽은 함수다):
T0 Step 1 의 계측 println 은 **그대로 넣는다.** 단 **기대값을 뒤집는다** — 그 줄은 찍히면 안
되고, 안 찍히는 것이 dead-code 확인이다. 그러면 계측이 그 자체로 음성 대조가 된다(찍히면
validator 가 틀린 것이고, 그 사실을 즉시 안다). 🔴 그리고 **T9·T10 의 해석 규칙이 뒤집힌다**:
battery_mild 기준선은 "이미 개입된 판"이 아니라 **무개입 판**이다. T10 은 "SoC 재가격 vs
SoC×payload 재가격" 이 아니라 "무개입 vs payload 재가격" 으로 적어야 한다.
— 대가(틀렸을 때): validator 가 간접 호출 경로를 놓쳤다면 T9 대조가 오염된다. 계측 println 이
정확히 그 경우를 잡아준다 — 비용은 println 한 줄.

Ruling R2 (§0 [6] 반증 — `harness_args` 값이 10종, `bind_primitive_args` 는 `"env"` 만 안다):
`commit_respec ["env","milp","proposal"]` 이 **MILP 재풀이 원시**이고, 이것이 영구 거절되면
Phase D 전체(payload 재가격)가 **구조적으로 무동작**이다. T6 의 registry mechanism 이 스스로
"THIS IS INERT ON ITS OWN" 이라고 적는다. 따라서 T3 의 바인더는 다음 둘을 **동시에** 한다:
 (a) 하네스가 실제로 공급할 수 있는 인자를 최대한 지원한다(무엇이 가능한지는 라운드 2 가 잰다),
 (b) 공급 불가한 원시는 **`resolve_primitive` 시점에 `enactable=false` 로 표시**하고
     `enact_minted!` 가 body 에 그런 원시가 있으면 이유를 **정확히 이름 지어** 거절한다
     (`unenactable primitive: commit_respec (harness args milp, proposal not suppliable)`).
     지금 설계는 `reject:unknown_harness_arg:milp` 라는 **오도하는 이유**를 낸다.
 (c) 그 격차(알파벳 19 wide vs 집행 가능 15 wide)를 **레지스트리 게이트가 세게** 한다 —
     아무도 그 숫자를 기록하지 않는 것이 §1-1 "조용한 폴백 금지" 위반이다.
— 대가(틀렸을 때): 바인더가 필요 이상으로 넓어져 안전층이 검사할 표면이 늘어난다. undo 가
없는 이 설계에서 그것은 실제 위험이다. 그래서 (a) 는 라운드 2 의 측정 뒤에만 넓힌다.

Ruling R3 (X-1 반증 — `params` 가 `SYNTH_LANE_KEYS` 에 없어 live 경로에서 항상 빈 dict):
`SYNTH_LANE_KEYS` 를 **아홉**으로 한다(`params` 추가). 파이썬은 이미 `synthesis["params"]` 로
싣는다(A-1 실측). 이걸 안 고치면 T6 원시가 필수 kwarg 없이 불려 throw 하고, 그 throw 가
`:admit` 으로 보고된다 — 그리고 T3 게이트 (8) 은 영원히 공허하다.
— 대가(틀렸을 때): 결정 행이 한 열 넓어진다. 없음에 가깝다.

Ruling R4 (H1 반증 — `policy_entry(b, label)` 은 **위치인자**이고 `b` 는 **Symbol 키**로 읽힌다):
T1 게이트는 `policy_entry(fake, "dspy")` 로 부르고, fixture 를 `JSON3.read(JSON3.write(...))`
로 만들어 live 객체와 같은 Symbol-키 모양으로 짓는다. 계획서대로 `Dict{String,Any}` +
kwarg 를 쓰면 게이트가 **성공 분기라 이름 붙인 채 실패 분기를 재고**, 변이시험이 안 빨개진다.
— 대가(틀렸을 때): 없음. 실측된 시그니처를 따를 뿐이다.

Ruling R5 (H3 반증 — `src/navigator/` 는 패키지 로드 경로에 **없다**; 런타임 include 다):
 (a) `minted_tool.jl` → `src/respec/respec.jl` 에서 include (계획서 1안 유지, 이유는 다르다:
     자유 전역은 호출 시점에 풀리므로 include 시점 UndefVarError 는 애초에 안 난다).
 (b) 🔴 `payload_bias.jl` → **`src/navigator/navigator.jl`** 에서 include. 계획서가 대안으로
     제시한 `src/ConstructionBots.jl` 은 **틀렸다** — 그 파일은 navigator 를 로드하지 않는다.
 (c) `test/payload_bias_composes.jl` 과 `test/mild_menu_is_noop_only.jl` 은 파일 맨 위에
     `isdefined(CB,:BatteryTruth) || CB.include(.../src/navigator/navigator.jl)` 를 넣는다
     (`test/battery_menu_lanes_agree.jl` 의 기존 관용구). 없으면 **단독 실행에서 UndefVarError**,
     스위트 안에서는 앞선 파일이 이미 include 해서 **초록** — 순서 의존 초록이다.
— 대가(틀렸을 때): include 가 중복되면 Julia 가 재정의 경고를 낸다. 회수 쉬움.

Ruling R6 (X-2 반증 — T3 게이트 (2)(8) 이 주장하는 이유에 닿기 전에 `env===nothing` 으로 거절됨):
게이트 (2)(8) 에 sentinel `env = Ref(:e)` 를 넘긴다(게이트 (6)(7) 이 이미 쓰는 방식).
— 대가: 없음. 그대로 두면 세 단언은 통과하고 **뜻을 나르는 한 단언만** 실패한다.

Ruling R7 (X-3 반증 — T7 치환 불변성 게이트가 `%-8s` 패딩 때문에 실패):
등길이 센티넬(`"A4"` → `"Z9"`)을 쓴다. 그리고 `test_absent_nodes_render_is_byte_identical`
는 계획서대로면 **자기 자신과 비교**라 공허하다 — 구현 **전에** golden 문자열을 파일로 떠서
그것과 비교한다. T7 Step 2 의 기대값("전부 FAIL")도 정정: pydantic `extra='ignore'` 라
구현 전에 게이트 4개 중 **2개는 이미 초록**이다.
— 대가(틀렸을 때): golden 파일이 하나 늘어난다.

Ruling R8 (D-5 반증 — `2.29` 는 실측 상한이 아니라 한 fixture 의 step 261 관측치이고,
`rates.jl` 이 "인용하지 말라"고 적는다): `_PAYLOAD_REF` 는 **선언된 손잡이**로 적는다 —
"이 축의 정규화 상수이며 측정값이 아니다. 바꾸면 비용 스케일이 바뀐다" 로 docstring 을 고치고,
`rates.jl` 을 근거로 인용하지 않는다. 게이트는 상수를 리터럴로 다시 적지 말고
`CB._PAYLOAD_REF` 를 참조한다(안 그러면 상수와 시험이 구성상 일치해 아무것도 안 잰다).
— 대가(틀렸을 때): 없음. 단조성은 어떤 양수 상수에서도 성립한다.

Ruling R9 (H7 반증 — T6 게이트 (1) 은 **실패할 수 없다**): 재작성한다. 재는 명제를 바꾼다 —
"`clear_payload_bias!` 뒤에 훅이 X 다" 가 아니라 **"재가격이 안 걸린 로봇의 엣지에서
`payload_edge_multiplier` 가 `battery_edge_multiplier` 와 바이트 동일하다"** 를 잰다. 그리고
testset 전체를 `try … finally CB.clear_payload_bias!() end` 로 감싸 `EDGE_COST_MULTIPLIER[]`
가 스위트의 나머지로 새지 않게 한다(RISK 8).
— 대가(틀렸을 때): 게이트가 조금 더 비싸진다.

Ruling R10 (RISK 7 / H6 — `runtests.jl` 은 `tools/` 에서 실제로 include 한다(2건)):
T4 는 `tools/monitor/test_minted_wiring.jl` 을 `test/runtests.jl` 에 **등재하고**, 그 파일을
T4 의 Files 목록에 넣는다. (내 사전 스캔의 "orphan gate" 판정은 반증됐다 — 등재만 하면 된다.)

Ruling R11 (RISK 5 — `Pkg.test()` 인수 기준 "pass ≥ 1487" 은 불건전):
인수 기준을 **`fail == 0 && error == 1`(Gurobi) + pass 델타를 설명 가능할 것**으로 바꾼다.
1487 을 낸 그 보고서 자체가 어떤 fix 가 1503→1487 로 **낮춘** 것을 기록한다. 삭제된 단언은
정상적인 감소다.
— 대가(틀렸을 때): 회귀가 pass 감소로만 나타나면 못 잡는다. 그래서 "설명 가능할 것" 이 조건.

Ruling R12 (RISK 6 — uvicorn 이 :8077 과 :8079 **둘** 살아 있고 :8077 에 `TOOL_SYNTHESIS=1`):
T5 직전에 둘 다 죽이고 하나만 띄운다. 모든 T5/T9 명령에 사용 포트를 로그로 남긴다.
— 대가(틀렸을 때): 유료 호출의 귀속이 불가능해진다. 지금 고치는 것이 싸다.

Ruling R13 (RISK 2 — fleet 의 SoC 키는 `"ConstructionBots.BotID{...}(3)"` 로 stringify 되어
LLM 의 `"R3"` 과 절대 안 맞는다): T6 의 agent 매칭은 새 문자열 규약을 발명하지 않고
`tools/monitor/enact.jl` 의 기존 접지 경로(`enact_target` / `ground_tool_args`, 게이트
`test/enact_uses_llm_agent.jl`·`test/tool_args_grounding.jl`)를 재사용한다.
— 대가(틀렸을 때): `:unknown_agent` 가 영구 결과가 되고 **모델 실패처럼 보인다.**

Ruling R14 (RISK 3 — `enact_minted_decision!` 이 던지면 `maybe_respecify!` 의 producer try 가
`engage_fallback!` 를 불러 **라인 스톱**이 되고 production 에서 `release_fallback!` 이 없다):
T4 의 `enact_minted_decision!` 은 전체를 `try … catch` 로 감싸고, 던지면 `handled=false` +
`verdict=:reject` + 이유를 찍고 **정상 반환**한다. 레지스트리 결함이 렌더를 멈추면 로그가
OOD 를 탓하고 JSON 을 안 탓한다.
— 대가(틀렸을 때): 진짜 결함이 한 판 더 조용해진다. 그래서 반드시 println 을 남긴다.

Ruling R15 (RISK 9 — §0 의 근거표가 실행 파일에 **줄번호로** 인용한다(10건), §1-1 위반이고
그중 `render_demo.jl:646` 은 실제로 죽은 코드를 가리켰다): 새로 쓰는 코드·주석·보고서는
전부 심볼로 인용한다. 계획서 §0 는 T10 보고서에서 정정한다.

Ruling R16 (실행 순서 재조정): R2 가 T3 의 설계를 바꾸므로 **라운드 2 검증이 T3 앞에 서야
한다.** 순서: T8 → (라운드 2 병행) → T0 → T1 → T2 → T3 → T4 → T5 → T6 → T7 → T9 → T10.

## Validator Round 2 — 바인더 범위 결정 (paid calls 0). 전문: `validation-round2.md`

Ruling R17 (Q1·Q5 — **바인더를 넓히지 않는다**. R2(a) 를 이것으로 확정):
`bind_primitive_args` 는 `"env"` 만 지원한다. 근거 둘:
 (a) zone body(`restage_all_blocked!` + `translate_whole_build!`)는 **둘 다 `f(env; kwargs)`** 라
     env-only 바인더로 **끝까지 집행된다** → **Phase C(T5, 분수령)는 넓히기가 필요 없다.**
 (b) `commit_respec` 에 `milp` 을 쥐여줘도 소용없다 — 알파벳에는 재풀이의 **설정 반쪽과 커밋
     반쪽만 있고 푸는 것이 없다**(`formulate_milp`·`optimize!` 가 알파벳에 아예 없다).
     `milp` 은 "**푸는 행위로만** 공급 가능"하다.
— 대가(틀렸을 때): 모델이 `commit_respec` 을 조합하면 거절된다. R19 가 그 거절을 정직한
이유로 만든다.

Ruling R18 (Q1 — Phase D 의 재풀이는 **새 원시 하나**로 온다):
`rebalance_for_battery!(env; optimizer)` 가 `build_invariant` → `formulate_milp` → `optimize!`
→ `commit_respec!` 를 **`env` 하나 뒤에서 전부** 하고 빈 proposal 을 스스로 만든다(실측).
레지스트리에 원시 하나를 더한다: `impl: "rebalance_for_battery!"`, `harness_args: ["env"]`,
`params: {}`. 🔴 **T6 의 Files 에 이것이 추가된다**(계획서에는 `reprice_agent_by_payload` 하나만
있다). 그리고 그 심볼은 navigator 층이라 bare `using ConstructionBots` 에서 `isdefined=false` →
**`test/primitive_registry_resolves.jl` 에 navigator guard 줄을 넣는다**(R5(c) 와 같은 관용구).
안 넣으면 그 게이트가 스위트에선 초록, 단독에선 빨강인 순서 의존 게이트가 된다.
— 대가(틀렸을 때): 알파벳이 1 넓어진다. mechanism 산문이 재풀이를 정확히 서술해야 모델이
payload 재가격과 짝지어 조합한다.

Ruling R19 (Q6 — `enactable` 판정식은 **두 항**이다. 내 R2(b) 초안은 틀렸다):
`harness_args ⊆ suppliable` 만 쓰면 19개 중 15개를 "집행 가능"으로 표시하는데 **실제로는 6개**
뿐이다. 나머지 9개는 호출 시점 `MethodError` 로 죽고, T3 의 `catch` 가 그것을 **`:admit` +
`applied=true`** 로 보고한다 — 지금의 거절보다 **더 나쁘다**(삼상 뭉개기 + 조용한 폴백).
정직한 판정식: `harness_args ⊆ {"env"}` **AND** `nargs-1 == length(harness_args)` **AND**
`keys(params) ⊆ Base.kwarg_decl(only(methods(impl)))`. 기계로 유도 가능하고(실측 확인),
19개 중 **13개를 빨갛게** 만든다. 그 13이 진실이고, 그것을 기록하는 것이 §1-1 "조용한 폴백
금지" 다. `enact_minted!` 는 body 에 un-enactable 원시가 있으면 그 이름과 **어느 항이 깨졌는지**
를 적어 `:reject` 한다.
— 대가(틀렸을 때): 알파벳의 집행 가능 폭이 6/19 로 드러난다. 그것이 spec §3-1 이 말하는
`missing_primitive` 의 진짜 규모이고 **주 산출물이지 실패가 아니다**.

Ruling R20 (Q5 — 🔴 `zone_keys` 가 String 이면 **조용히 필터링돼 세계가 바이트 동일한데
`admit/applied=true` 가 난다**): `RESTRICTION_ZONES[]` 는 `Dict{Symbol,Ball2}` 이고 모든
소비처가 `haskey` 로 거른다. 레지스트리는 `array of string` 이라고 적어 모델을 String 으로
유도한다. `bind_primitive_args` 는 `zone_keys` 를 **반드시 `Symbol` 로 강제 변환**하고,
변환 후 `RESTRICTION_ZONES[]` 에 없는 키가 있으면 **거절**한다. 게이트를 하나 더 쓴다:
"존재하지 않는 zone_key 는 admit 이 아니다".
— 대가(틀렸을 때): 이것이 이 계획에서 가장 위험한 침묵 폴백이다. 안 고치면 T5 가
`PROJECT COMPLETE` 를 내면서 합성 tool 이 아무 일도 안 한 판을 성공으로 기록한다.

Ruling R21 (Q4 — `params.agent` 는 **접지 불가능하게 태어난다**: `maybe_synthesize` 에
`agents` 파라미터가 아예 없어 모델이 실재하는 로봇 id 를 알 길이 없다):
zone 의 `zone_keys` 와 **정확히 같은 규약**으로 푼다 — LLM 이 `agent` 를 안 줬으면
**truth 에서 유도**한다(`BatteryTruth.robot`). 줬으면 `CB.resolve_agent_id(env, s)`
(`src/respec/llm_bridge.jl`, CB 모듈 안이라 `minted_tool.jl` 에서 맨이름으로 부른다)로 접지하고,
`nothing` 이면 **거절**한다(`:unknown_agent` 를 조용한 성공으로 두지 않는다).
🔴 프롬프트에 `agents` 를 싣는 것은 **이 계획의 범위 밖으로 선언한다** — T7 은 `nodes` 채널
하나만 연다. 유도 규약이 있으면 Phase D 는 그것 없이 성립하고, 채널을 하나 더 여는 것은
별도 측정 대상이다.
— 대가(틀렸을 때): 모델이 "어느 로봇을 재가격할지" 를 스스로 못 고른다. truth 가 지목한
로봇으로 고정된다 — 이 데모의 사건에서는 그것이 유일한 후보라 손실이 없지만, **일반화의
증거로 읽으면 안 된다.** T10 이 그렇게 적는다.

Ruling R22 (Q5 caveat — `restage_assembly!(env, assembly_id::AbstractID; …)` 는 **필수 위치
인자**를 레지스트리가 string `param` 으로 선언한다): R19 의 두 번째 항(`nargs-1 ==
length(harness_args)`)이 이것을 자동으로 un-enactable 로 만든다. 별도 조치 불필요 — 다만
T5 의 실패 분해표가 이 원시를 권하므로, 모델이 그것을 조합하면 **거절 이유가 정확해야** 한다.

Ruling R23 (T0 의 zone 기준선 레인 — 내 사전 스캔의 T0 자기모순 행에 대한 결정):
계획서 T0 Step 2 는 zone 기준선을 `DEMO_POLICY=canonical` 로 녹화하는데 T5 의 대조판은
`DEMO_POLICY=router DEMO_ROUTER=auto` 다. **레인이 다르면 그것은 T5 의 통제가 아니다.**
T0 의 zone 기준선을 **`router`** 로 돌린다 — T4 이전이라 합성 집행이 아직 존재하지 않으므로,
같은 레인·같은 프롬프트·같은 유료 결정에서 **집행만 없는** 판이 나온다. 그것이 T10 이 인용할
유일한 정당한 대조군이다. canonical 판은 다시 재지 않는다 — §0 [10] 이 이미 기록했고
재측정이 어떤 결정도 바꾸지 않는다. 판 수는 계획서 예산 그대로 2판.
— 대가(틀렸을 때): router 레인이 `PROJECT INCOMPLETE` 를 재현 안 할 수 있다. 그것은 실패가
아니라 정보다 — 그 경우 T5 의 주장 자체가 다시 정의돼야 하고, 즉시 안다.

## 태스크 진행

Task 8: 구현 commit `9c8e8b26`. 스위트 1561 pass / 0 fail / 1 error(Gurobi).
Task 8: 리뷰 — Spec ✅ / 품질 2 Important.
  · Important 1: 게이트가 `["NOOP","Replace","SwapBattery"]` 를 **리터럴**로 적는다 —
    §1-1 어휘 단일 진실원 위반. 형제 게이트 `policy_macro_binding.jl` 이 자기 주석에서
    정확히 그것을 금지한다("여기에 'SwapBattery' 라고 적으면 이 게이트가 막으려는 결함이
    게이트 자신에게서 난다").
  · Important 2: testset (4) 와 testset (1) 의 zone 비교 단언이 **빨간 것을 본 적이 없다**.
Task 8: minor (deferred): 보고서의 +8 pass / −1 error 델타는 사전 기준선 없이 사후 추론이다
  (보고서가 스스로 그렇게 적는다). 최종 리뷰가 triage 할 것.
Task 8: fix round 1/5 — 위 두 Important 를 원 구현자에게 되돌림.

Task 0: 계측 삽입 완료(render_demo.jl), 기준선 2판 렌더 진행 중.
  🔴 이 세션의 첫 유료 호출 2건이 여기서 나간다.

관측된 운영 문제(이 세션의 규약이 된다): subagent 들이 백그라운드 작업을 띄우고
알림을 기다리며 **반복적으로 멈춘다**(T8 3회, T0 2회). 이후 모든 브리프에
"긴 명령은 foreground + 600000ms timeout" 을 싣는다.

Task 0: 구현 commit `8178e56d`. 두 기준선 녹화 완료. **유료 호출 2건 소진**(:8077, calls 1→3).
  · zone_before (router 레인, R23): `[zone] … vtx=143 @[1.094,0.416] r=0.07 nav_blocked=3/131`
    → `[policy] ZoneTruth → NOOP (enacted=dspy)` → `PROJECT INCOMPLETE!`
    🔴 계획서 §0 [10] 의 canonical 실측과 **숫자까지 동일**하다. router 레인에서 재현되므로
    T5 의 대조군이 유효하다.
  · battery_mild_before (router 레인): `[policy] BatteryTruth → NOOP` → `PROJECT COMPLETE!`
  · 🔴 **`[recover]`/`SILENT-FALLBACK` 이 두 판 모두에서 한 번도 안 찍혔다** — R1 의 뒤집은
    기대값이 맞았고, `enact_recovery!` 가 죽은 코드라는 검증이 **실측으로 확인**됐다.
    귀결: battery_mild 기준선은 **무개입 판**이다. T9·T10 이 그렇게 적어야 한다.

Ruling R24 (T0 보고의 concern 1 — `results/*` 가 `.gitignore` 에 있어 계획서의
`git add results/baseline_2026-08-30/` 는 **조용히 아무것도 안 담는다**):
`git add -f` 로 명시 경로만 추적한 구현자의 판단을 **승인한다.** 이 두 로그는 T5·T9·T10 이
인용할 증거이고, 커밋 안 되면 이 계획의 대조축이 재현 불가능해진다. `.gitignore` 규칙 자체는
건드리지 않는다(작업 트리에 이미 미커밋 수정이 있는 파일이다).
🔴 계획서 결함으로 기록: T5·T9 의 `git add results/...` 도 같은 이유로 조용히 실패한다.
그 두 태스크 브리프에 `-f` 를 실어야 한다.
— 대가(틀렸을 때): 로그 2개(수백 KB)가 레포에 들어온다. 되돌리기 쉽다.
Task 0: 리뷰 — Spec ✅ / 품질 Approved. Critical·Important 0건.
  · 로그가 `[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM`
    와 `(enacted=dspy; rule=NOOP)` 를 담아, 조용한 canonical 폴백이 **아니었음**이 확인됨.
  · minor (deferred): dspy 레인이 실제로 구동했다는 증거가 보고서·커밋메시지에 **명시적으로**
    적히지 않아 후대 독자가 재유도해야 한다.
  · minor (deferred): board 2 가 foreground 지시 도착 전에 background 로 이미 떠 있었다.
    구현자가 재실행(=유료 3번째 호출) 대신 foreground 로 blocking 을 택했다. 공개된 이탈.
Task 0: complete (commits 9c8e8b26..8178e56d, review clean)

## Validator Round 3 — zone 침묵 성공 (paid calls 0). 전문: `validation-round3.md`

Ruling R25 (Q3 — 🔴 **원시가 "성공" 을 내면서 세계를 바꾸지 않는 경로가 7개 있다**):
`enact_minted!` 는 원시의 status 를 **평범한 성공으로 취급해서는 안 되는 목록**을 갖는다:
  `restage_all_blocked!` → `:none` · `:infeasible` · `:residual_blocked`
  `translate_whole_build!` → `:no_staging` · `:infeasible` · `:already_clear` · `:residual_blocked`
평범한 성공은 오직 `{:partial, :restaged_all}` 과 `:translated` 뿐이다.
🔴 그중 **`translate_whole_build! :already_clear` 가 가장 위험하다** — |Δ|=0, residual=0,
세계 바이트 동일인데 `restage_zone.jl` 이 호출자에게 "성공으로 취급하라" 고 적는다. 그리고
그것이 정확히 **String `zone_keys` 가 도착하는 자리**다(`zones==[]` → Δ=[0,0] → residual 을
zone 0개에 대해 세어 `:already_clear`). 즉 잘못된 인자가 **"존이 치워졌다는 증거"** 로 보고된다.
`enact_minted!` 는 이 7개를 `steps` 에 `status` 그대로 싣되 verdict 를 `:admit` 로 뭉개지 않고
**`applied=false` 의 별도 상**으로 낸다(삼상 규약, spec §9-2).
— 대가(틀렸을 때): 진짜 성공한 판이 한 번 보수적으로 기록된다. 그 반대(무동작을 성공으로
기록)보다 압도적으로 싸다.

Ruling R26 (Q2 — 계획서 T3 의 `zone_keys` 유도 규약을 **폐기한다**):
계획서는 "LLM 이 존 키를 알 이유가 없다" 며 `kw[:zone_keys] = Symbol[ctx.truth.zone]` 로
truth 에서 유도한다. **두 군데가 틀렸다.**
 (a) 🔴 전제가 반증됐다 — `dspy_service.py::_zones_block` 이 모델에게 `zone "zone_blk_1"` 을
     **직접 보여준다**. 모델은 그 키를 안다. 그리고 강제 변환이 없으면 **맞게 답한 것 때문에
     벌을 받는다**(String → 조용히 필터링 → `:already_clear`).
 (b) 유도값이 callee 기본값보다 **좁다** — `restage_all_blocked!`/`translate_whole_build!` 의
     기본값은 둘 다 `collect(keys(RESTRICTION_ZONES[]))` 이고, 유도값은 `fault_zone`/`all`
     판에서 `fault_<id>` 키를 떨어뜨린다.
확정 규약: **주지 않았으면 kwarg 를 아예 안 넘긴다**(callee 기본값 = 살아 있는 모든 존).
줬으면 Vector 를 요구하고 각 원소를 `Symbol(string(e))` 로 강제 변환한 뒤, `RESTRICTION_ZONES[]`
에 없는 키가 하나라도 있으면 **body 실행 전에 거절**한다 —
`reject:unknown_zone_key:<k>:live=<정렬된 live 키>`, `applied=false`. 강제 변환 후 빈 리스트는
`reject:empty_zone_keys` 이고 **기본값으로 폴백하지 않는다**.
— 대가(틀렸을 때): 모델이 실재하는 키를 줬는데 형식이 달라 거절될 수 있다. 그 거절은
이유가 정확하고 로그에 남는다 — 조용한 `:already_clear` 와 정반대다.

Ruling R27 (Q3 — `restage_all_blocked!` 는 `:none` 일 때 필드가 **3개**이고 `residual` 이 없다):
`enact_minted!` 는 반환 NamedTuple 의 필드를 무조건 접근하지 않는다. `status` 만 `Symbol` 로
읽고, 나머지는 `hasproperty` 로 방어한다. 안 그러면 `:none` 한 번에 `r.residual` 이 던지고,
T3 의 `catch` 가 그것을 `:admit`+`applied=true` 로 보고한다 — 최악의 조합.

Ruling R28 (Q4 — 🔴 **T5 가 성립하는지 자체가 아직 미측정이다**):
`CB.zone_diagnosis(env, :zone_blk_1).n_blocked` 이 0 이면 `restage_all_blocked!` 가
`:none` 으로 조기 반환하고 zone 레인은 **알파벳의 한계로** 실패한다 — 그런데 T5 는 그것을
모델의 실패로 읽게 되어 있다. 그 함수의 docstring 이 직접 "0 이면 ForbidZone 팔은 침묵
no-op 이다" 라고 적는다.
결정: **T4 의 범위를 넓힌다.** T4 는 이미 `render_demo.jl` 을 고치므로, 존 주입부의 기존
`println` 에 `zone_blocked_assemblies` 길이와 root-goal 커버리지를 **결정이 나기 전에** 찍게
한다. 유료 호출 0, 판 0개로 T5 의 전제가 답해진다.
🔴 `zone_diagnosis(...).verdict` 와 `relocate_norm` 은 **오라클 라벨이다** — 로그에만 쓰고
어떤 프롬프트 경로에도 싣지 않는다(spec §6-2).
— 대가(틀렸을 때): T4 가 println 두 개만큼 커진다.

Ruling R29 (Q5 — 계획서 T5 의 실패 분해표가 **다른 양을 비교한다**):
`_count_future_work_overlaps(env; zone_keys, margin=1e-4)` 는 원시가 보고하는 `residual` 이
**아니다** — 원시는 `_count_future_goals_in_zone`(점-원 포함, margin 0.0, `EntityGo` 정점)을
쓰고 저쪽은 원-원 겹침(margin 1e-4, 비-root staging circle 포함)이다. **둘 다 라벨을 달아
찍는다.** 하나만 찍고 "잔량" 이라 부르면 그것이 이 레포의 tautological cross-check 실패 모양이다.
Task 8: fix round 1/5 (2 addressed, 0 open; commits 9c8e8b26..3196928a). 재리뷰 clean.
Task 8: minor (deferred): 리터럴 제거의 대가로 단언이 **약해졌다** —
  `[AR.NAME[i] for i in kind_valid(:battery)] == ["NOOP","Replace","SwapBattery"]` 가
  `length(AR.kind_valid(:battery)) == 3` 이 됐다. 이름 동일성은 `policy_macro_binding.jl` 이
  소유하므로 재리뷰가 승인했지만, **이 게이트만으로는 세 팔이 무엇인지 안 잰다**. 최종 리뷰가
  triage 할 것.
Task 8: complete (commits 0f895b46..3196928a, review clean, 2 minors parked)

Task 1: 착수 (BASE 3196928a). 보정 C1(키 9개=params 추가)·C2(policy_entry 위치인자)·
  C3(Symbol-키 fixture, 성공 분기를 탔다는 것을 먼저 단언) 을 실었다.
Task 1: 리뷰 — Spec ✅ / 품질 Approved. Critical·Important 0건.
  · 리뷰어가 5개 변이를 **직접** 적용·되돌리며 각각이 주장한 testset 만 빨갛게 만드는 것을 확인.
  · 결정적 검사 통과: `get(::JSON3.Object, ::Symbol, default)` 가 값을 꺼낸다 →
    Symbol 키 재작성이 라이브 `/decide` 경로를 조용히 0으로 만들지 않는다.
  · 델타 +46 이 새 파일의 testset 합(1+12+19+4+10)과 정확히 일치 — 설명됨.
  · minor (deferred): 새 게이트가 `"NOOP"` 을 fixture filler 로 4번 리터럴로 적는다.
    형제 게이트는 `ActionRegistry.NAME[0]` 에서 유도한다. 단독 설계(=`using ConstructionBots`
    없이 `policy.jl` 만 include)가 강제한 것이고 단언 대상이 아니지만, 이유를 한 줄 적을 것.
Task 1: complete (commits 3196928a..05f1d2b5, review clean, 1 minor parked)

Ruling R30 (T2 의 게이트가 어느 세계에서 도는가):
`test/minted_tool_resolves.jl` 은 navigator guard 를 **넣는다**. 이유: 집행은 렌더 레인에서
일어나고 그 레인은 navigator 를 로드한다. guard 없이 재면 **production 이 한 번도 안 도는
조건**을 재게 되고, R18 이 navigator 층 원시(`rebalance_for_battery!`)를 알파벳에 더하는
순간 그 게이트가 근거 없이 빨개진다.
— 대가(틀렸을 때): 게이트가 navigator 로드 비용을 문다(수 초).
Task 2: 구현 commit `d9c00896`. 스위트 1675 pass / 0 fail / 1 error. 델타 +68 = 새 testset 합.
  보정 C1~C6 전부 적용(include 지점 확정, JSON3 추가 안 함, navigator guard, module 래핑).
Task 2: 리뷰 — Spec ✅ / 품질 Approved + Important 1(변이 미기록, 리뷰어가 직접 돌려 게이트가
  유효함은 확인 — 실제 결함 아님). fix round 1/5 진행 중.

## Validator Round 4 — 🔴 **PHASE D 는 설계대로는 효과를 못 낸다** (paid calls 0)
전문: `validation-round4.md`. 읽기 전용 Julia probe 로 tractor 씬을 세워 실측했다(판 0개).

실측 사슬:
 1. payload 축은 **살아 있다** — `tractor.mpd` 의 payload-capable 노드 **81/81** 이
    `_payload_mass > 0`, 범위 **0.328 … 12.800 kg**, 평균 2.485. (§0 [13] 의 `0.0…0.0` 우려는
    다른 모델(colored_8x8)의 **step-local** 산물이었다 — 모델의 성질이 아니다.)
 2. 🔴 그런데 `n_candidate_edges = 0` 이다. `LAST_EDGE_COSTS[]` 길이 0, `nnz(Xa)=329` 가 전부
    **고정된 구조 간선**(`Xa==1`). `init_objective_weights!()` + κ=0.01 을 줘도
    `LAST_AUTO_EFFICIENCY_W` 가 **0.0** — 목적식이 순수 makespan 으로 후퇴한다.
 3. `formulate_milp` 은 `EDGE_COST_MULTIPLIER[]` 를 **무조건** 읽는다(플래그 없음) — 그러나
    오직 `edge_costs` 경유이고, 고정 간선은 거기 안 들어간다 ⟹ **클로저가 0번 불린다.**
 4. 그런데 `rebalance_for_battery!` 는 여전히 `:rebalanced` 를 낸다 = **또 하나의 침묵 성공.**
 5. 게다가 계획서의 비교식 `string(owner) != st.agent` 는 **절대 안 맞는다** — `_owner_robot`
    은 81/81 에서 `BotID{DeliveryBot}` **객체**를 낸다. String vs RobotID 비교는 에러가 아니라
    **항상 참**이라, 모든 엣지가 factor 1.0 을 받고 status 는 `:installed` 이며
    판은 "성공한 개입" 처럼 보이는데 아무것도 안 바뀐다.
⚠️ validator 가 스스로 적은 한계: 이 측정은 `closed=0`(pre-sim) 이고 실제 결정은
   `closed=245/305` 다. 후보 간선은 배정 슬롯이 비어 있는 곳에만 생기고, NOOP 경로는 슬롯을
   비우지 않는다 — 그래서 결정 시점에도 0일 가능성이 높지만 **확정은 아니다.**

Ruling R31 (Phase C 는 영향 없다): T3 → T4 → T5 를 그대로 간다. 라운드 2 가 zone body 는
env-only 바인더로 끝까지 집행됨을 확인했고, 라운드 3 이 침묵 성공 status 목록을 줬다.
Phase D 의 결함은 Phase C 의 어떤 것도 건드리지 않는다.

Ruling R32 (🔴 **Phase D 는 측정 하나를 기다린다** — T6 을 아직 dispatch 하지 않는다):
T6/T7/T9 를 설계대로 집행하면 "성공을 보고하는 무동작" 판이 나오고, 그것이 이 레포가
반복해 밟은 실패 모양이다. T6 앞에 **측정 태스크 T5b** 를 넣는다:
  · `DEMO_POLICY=canonical` 로 battery_mild 판 **1개** (🔴 **유료 호출 0**, ~3분)
  · 결정 시점에 `length(CB.LAST_EDGE_COSTS[])` 를 찍고, 강제 `rebalance_for_battery!` 직후에
    다시 찍는다. `zone_diagnosis` 계측(R28)과 같은 자리에 넣는다.
  · 0 이면 → payload **후보 간선 가격**은 이 판에서 레버가 아니다. Phase D 는 **고정 간선**에
    닿는 레버가 필요하고, 그것은 계획서에 없는 설계다 → 사용자 판단으로 올린다.
  · 0 이 아니면 → T6 을 R33 의 보정과 함께 그대로 간다.
— 대가(틀렸을 때): 3분과 판 1개. 그 반대(무동작 판을 유료로 렌더하고 T10 에 "개선"으로
적는 것)는 이 계획 전체의 신뢰를 깎는다.

Ruling R33 (측정과 무관하게 T6 이 반드시 고쳐야 할 두 가지):
 (a) `_PAYLOAD_REF = 2.29` 는 이 모델에서 **5.6배 작다**(tractor 평균 2.485 가 이미 넘는다).
     R8 대로 "선언된 손잡이" 로 적되, 값은 실측 범위(0.328…12.800)에서 고른다. `rates.jl` 을
     근거로 인용하지 않는다.
 (b) 🔴 agent 비교를 **ID 동등성**으로 한다: `owner === nothing && return base;
     owner == st.agent ? base * _payload_factor(...) : base`. R21 대로 truth 에서 유도하면
     `truth.robot` 이 이미 `RobotID` 이고 `fleet.soc` 키와 **같은 타입**이라
     (`haskey(fleet.soc, truth.robot) = true`, 내용 기반 `hash`/`==` 실측) 문자열 왕복이
     아예 필요 없다. `resolve_agent_id` 는 **모델이 문자열을 준 경우에만** 쓴다.
     음성 대조를 게이트에 넣는다: truth 의 로봇이 소유한 정점에서
     `payload_edge_multiplier(env,sched,v) > battery_edge_multiplier(sched,v)` —
     타입 불일치면 이 둘이 같아지므로 이 단언이 정확히 그 결함을 잡는다.
Task 2: fix round 1/5 (1 addressed, 0 open; commits d9c00896..cca671ec) — 네 testset 전부
  변이 기록 완비. 재리뷰 대기.

Ruling R34 (T3 의 삼상 정의를 **정밀화한다** — 계획서 초안은 던진 body 를 `:admit` 으로 적고
`applied=true` 로 두는데, 라운드 3·4 가 찾은 침묵 성공 status 들과 합치면 그 조합이
"아무 일도 안 했는데 성공" 을 낳는다):
  · `verdict = :admit` ⟺ body 의 모든 원시가 해석·집행가능·바인딩·**호출**됐다(status 무관).
  · `verdict = :reject` ⟺ 한 발도 호출하기 전에 반환했다.
  · `verdict = :deferred` ⟺ 집행할 사건이 아니었다(`reach != "composed"`, 합성 미실행).
  · 🔴 `applied = true` ⟺ **호출된 step 중 최소 하나가 침묵 성공 목록 밖의 status 를 냈다.**
    (목록은 R25: `restage_all_blocked! :none|:infeasible|:residual_blocked` ·
     `translate_whole_build! :no_staging|:infeasible|:already_clear|:residual_blocked` ·
     `rebalance_for_battery! :infeasible`)
  · `partial = true` ⟺ 중간에 던졌다 → 세계가 절반만 고쳐졌고 undo 가 없다.
  · `handled`(T4) = `:admit && applied`. **`partial` 이면 `handled=true`** — 절반 고쳐진 세계
    위에 기본 복구 사슬을 또 쌓지 않는다. 대신 로그가 크게 적는다.
— 대가(틀렸을 때): 진짜 성공한 판이 한 번 보수적으로 `applied=false` 로 기록될 수 있다.
  그 반대(무동작을 성공으로 기록)보다 압도적으로 싸다.
Task 2: 재리뷰 PASS — 변이가 각자의 testset 에만 정확히 걸리는 것까지 확인. 새 breakage 0.
Task 2: complete (commits 05f1d2b5..cca671ec, review clean)

Task 3: 착수 (BASE cca671ec, opus). 보정 C1(env-only 바인더)·C2(enactable 3항 판정식)·
  C3(zone_keys 유도 삭제 + Symbol 강제 + 실재 확인)·C4(삼상 정밀화 + 침묵 성공 집합)·
  C5(NamedTuple 필드 방어)·C6(게이트 (2)(8) sentinel env)·C7(기계 사실) 을 실었다.

Ruling R35 (T5b 의 계측은 T4 에 태운다 — 별도 태스크로 쪼개지 않는다):
R32 의 `LAST_EDGE_COSTS[]` 측정과 R28 의 `zone_diagnosis` 계측은 **둘 다 `render_demo.jl`
계측**이고 T4 가 이미 그 파일을 고친다. 순서는 T3 → T4(계측 포함) → T5(zone 판, 유료 1) →
T5b(canonical battery 판, **유료 0**) → Phase D 판정. 추가 작업 0.

## Validator Round 5 — T4 삽입 지점 확정 (paid calls 0). 전문: `validation-round5.md`

Ruling R36 (Q4 반증 — **R32/R35 의 T5b 를 폐기한다**):
`LAST_EDGE_COSTS[]` 를 결정 시점에 정직하게 잴 자리가 **없다.** (a) 결정 시점에 live `env` 를
가진 유일한 심볼은 `policy_producer` 인데 거기선 집행이 **아직 안 일어났다**(집행은 반환 후
`maybe_respecify!` 안이고, 렌더 레인에는 post-enactment 훅이 **0개**다). (b) 그 값은 0이 아니라
**미정의**다 — `formulate_milp` 만 쓰는데 결정 경로는 그걸 안 부른다. `0` 을 찍으면
"후보 간선 0" 과 "MILP 가 아예 안 돌았다" 를 **뭉개는** 것이고, 그것이 `enact_macro!` 가
sentinel 을 쓰는 이유다. (c) 강제 `rebalance_for_battery!` probe 는 측정이 아니라 **개입**이다
(`optimize!` → `commit_respec!(resume=true)` → `persist_milp_times!` + `reset_cache_resume!`,
`:commit_failed` 는 부분 재구축을 남긴다).
확정: **sentinel 로 `enact_minted_decision!` 안에서 잰다** — 호출 전 `LAST_EDGE_COSTS[]` 에
새 dict 를 꽂고, 호출 후 **동일성**으로 재풀이 여부를 판정한다:
`ran_milp = !(CB.LAST_EDGE_COSTS[] === _sent)`. 🔴 `length(...)` 를 `ran_milp` 없이 찍지 않는다.
귀결: **T5b 를 별도 판으로 돌리지 않는다.** Phase D 의 후보-간선 수는 T9 의 판에서 공짜로
나온다. 0 이면 그것은 실패가 아니라 **측정 결과**이고 T10 이 그렇게 적는다.
— 대가(틀렸을 때): Phase D 가 무동작임을 판을 돌린 뒤에 안다. 그 전에 알 방법이 **없다는 것**이
이 라운드의 결론이다.

Ruling R37 (Q1 함정 — 계획서의 앵커 문자열이 실제 코드와 **다르다**):
반환문의 실제 리터럴은 `return macro_to_proposal(truth, decision.macro_name; env = env,
agent = _tgt.agent)` — `=` 양옆에 **공백**이 있다. 계획서는 `env=env` 로 적는다. 그대로
Edit 하면 **조용히 매치 실패**한다. T4 브리프에 명시한다.

Ruling R38 (Q1 — 모든 OOD 사건이 `policy_producer` 에 닿는 것은 **아니다**):
조기 `nothing` 가드가 둘 — `is_reform_alarm(ev)` 와 `truth_for_event(event)`(NL 문자열
**정확 일치** `findlast`). `record_ood_truth!` 짝 없는 `push_ood!` 는 `[policy]` 줄도 결정 행도
없이 사라진다. 두 기준선은 사건 1개 / `[policy]` 1줄이라 여기서 샌 것은 없지만, T4·T5 가
"`[minted]` 줄이 없다" 를 볼 때 **후보 원인이 셋**이라는 뜻이다. 브리프에 싣는다.

Ruling R39 (Q3·Q6 — 계측의 기계적 제약):
 · `@info` 는 이 경로에서 **삼켜진다**(`full_demo.jl` 이 `ConsoleLogger(stderr, Warn)` 를
   sim 루프 둘레에 설치). 전부 `println` 으로 쓴다. 관용구는 `[소문자]` + `key=value` 한 줄.
 · 🔴 **`n_blocked` 이 두 개다**: `zone_diagnosis(...).n_blocked` = 막힌 **조립체** 수 /
   로그의 `nav_blocked=` = `n_nav_blocked`. 뭉치면 T5 가 잘못된 양을 읽는다.
 · 오라클 라벨 — **프롬프트에 절대 안 실린다**: `relocate_norm`(이것이 곧
   `min_shift_to_clear_m` 다) · `relocate_delta` · `relocate_feasible` · `verdict`.
   로그에는 `n_*` · `root_*` · `center` · `radius` 만 찍는다.
 · 잔량은 **둘 다** 라벨을 달아 찍는다: `_count_future_goals_in_zone`(원시가 보고하는 것) 과
   `_count_future_work_overlaps`(`enact.jl` 이 이미 "residual" 로 잘못 부르는 것).

Task 3: 구현 commit `5b9dec28` (DONE_WITH_CONCERNS). 스위트 1739 pass / 0 fail / 1 error.
  델타 +64 = 새 게이트(11 testset). 변이 11건, 각자 자기 testset 만 red.
  · 🔴 **집행 가능 6/19 확인** — 내 R19 의 예측이 실측으로 맞았다. 그리고 conjunct (i) 만으로는
    15개가 통과하는데, 그중 둘(`pop_spare`·`deprioritize_agent`)은 `harness_args` 가 **비어서**
    공허하게 통과한다. 세 항 판정식이 아니었으면 못 잡았다.
  · `only(methods(...))` 가 실제로 던진다 — `compile_constraint!` 은 **메서드가 6개**.
    구현자가 추측 대신 `:multimethod` 로 un-enactable 표시. 거절 라벨이 넷이 됐다
    (`harness|multimethod|arity|kwargs`). **승인한다** — 추측하지 않는 것이 이 레포의 규약이다.
  · C6 은 sentinel 대신 **재정렬**을 택했다(세계 불요 검사를 세계 요구 검사 앞으로).
    계획서 게이트가 그대로 통과하고 body 를 env 없이 검증할 수 있다 — 더 낫다.
  · 🔴 **내 보정 C3 의 마지막 문단이 반증됐다**: `RESTRICTION_ZONES` 는 navigator 층이 아니라
    `src/respec/ood_injection.jl` 에 있고 `respec.jl` 이 `minted_tool.jl` 보다 **먼저** include
    한다. 항상 정의돼 있어 우회가 불필요했다. (C3 (b) 의 `Dict{Symbol,Ball2}` 는 확인됨.)

Ruling R40 (T3 concern 1 — 13/19 가 un-enactable 인데 합성기 프롬프트는 19개를 다 보여준다):
T5·T9 에서 **높은 reject 율은 정상 동작이지 합성기의 실패가 아니다.** 그 사실을 T5 브리프와
T10 보고서에 명시한다. 🔴 프롬프트에서 un-enactable 원시를 숨기지 **않는다** — spec §3-1 은
`missing_primitive` 보고를 주 산출물로 본다. 알파벳 폭(19)과 집행 가능 폭(6)의 격차 자체가
이 레인의 측정 대상이다.
— 대가(틀렸을 때): 판 하나가 reject 로 끝날 수 있다. 그 reject 는 이유가 정확하다.

Ruling R41 (T3 concern 2 — `SILENT_SUCCESS_STATUSES` 가 zone 원시 둘만 덮는다):
나머지 4개 enactable 원시는 status 무관하게 `applied=true` 가 된다. **T6 이 자기 원시
(`rebalance_for_battery!`)의 status 표를 반드시 채운다** — 라운드 4 가 `:infeasible` 은 세계
바이트 동일, `:commit_failed` 는 **아니다**(부분 재구축)라고 이미 실측했다. 그리고 body 에
넣기 전에 표를 채운다는 규칙을 그 const 의 주석에 적는다.

Ruling R42 (T3 concern 3 — throw 시 `applied=false`, `partial=true`):
step 1 이 성공하고 step 2 가 던지면 세계는 바뀌었는데 `applied=false` 다. 과소 진술이지만
`partial` 이 그것을 나른다. **T4 의 `handled` 를 `(:admit) && (applied || partial)` 로 한다** —
절반 고쳐진 세계 위에 기본 복구 사슬을 또 쌓지 않는다(R34 의 의도).
Task 3: 리뷰 — Spec ✅ / 품질 Approved + Important 2 + Minor 3. 리뷰어가 enactable 6/19 를
  **독립적으로 재유도**했고 벡터 (a)(b)(c)(d) 를 전부 걸어봤다.
  · 🔴 Important 1: **집행 가능 6개 중 4개가 바이트 동일한 세계에서 `applied=true` 를 낸다.**
    `force_advance_stuck_carrier!` 는 `CARRIER_RESCUE != "1"`(=**기본값**)일 때 늘
    `(status=:disabled, moved=0)` → 모든 판에서 거짓 성공. `reform_stuck_teams!` 는
    **bare Int** 를 돌려줘 `:no_status_field` → `applied=true`. 게이트가 그 버그를
    **못박고 있다**(`_step_applied("resolve_schedule_wedge", :whatever) === true`).
  · Important 2: 레지스트리 편집 둘이 **게이트 전부 초록인 채로** 호출 표면을 넓힌다 —
    (a) `restage_all_blocked` 의 `params` 에 `"resume"` 추가 → LLM 이 `reset_cache_resume!` 를
    켤 수 있게 된다, (b) `resolve_schedule_wedge` 의 `impl` 을 다른 함수로 재지정.
  · minor (deferred): MUTATION 9 트랜스크립트가 5건만 적었는데 재현하면 12건이다
    (load-bearing 주장 — testset (9)만 빨개짐 — 은 유지).
  · minor (deferred): `ctx.truth` 가 C3 삭제 후 두 함수에서 죽었다. T4 용으로 의도적 보존.
Task 3: fix round 1/5 — Important 2건 + 승격된 minor 1건(`_step_status` 가 try 밖).

Ruling R43 (리뷰어에게 물은 `applied`/`partial` 의미론):
`applied` 는 **status-only 로 유지**한다 — throw 에서 뒤집으면 testset (11) 이 지키는 의미가
깨진다. 대신 (i) 필드를 "의도한 적응이 일어났다" 로 문서화하고, (ii) 파생값
**`world_maybe_dirty = applied || partial`** 을 함께 낸다. 어떤 호출자도 한 필드를 읽고
다른 필드의 답을 얻지 못하게 한다. T4 가 정확히 이것을 필요로 한다(R42).
— 대가(틀렸을 때): 반환 NamedTuple 이 한 필드 넓어진다.

Ruling R44 (승격 — `_step_status`/`_step_detail` 이 `try` 밖):
리뷰어는 "오늘의 6개에는 도달 불가" 라 Minor 로 뒀지만, **T6 이 알파벳에 원시를 더한다** —
즉 이 계획 안에서 도달 가능해진다. 이번 라운드에 고친다.
Task 3: fix round 1/5 (3 addressed, 0 open; commits 5b9dec28..29cb0a1d). 스위트 1834 pass /
  0 fail / 1 error. 게이트 12 testset · 159 단언 · 변이 18건(각자 자기 testset 만 red).
  · 구현자가 내가 지목하지 않은 **다섯 번째 경로**를 찾았다: `recover_stalled_teams!` 가
    `carrier.status` 를 **전달**해서 `:disabled`/`:no_carrier` 가 거기서도 표면화된다.
  · `:no_status_field` → `:unreadable_return` (새 `UNMEASURABLE_STATUSES`), 표보다 **먼저**
    검사, `applied=false`, detail 이 shape 를 이름 짓는다 = "못 쟀다" 가 "재서 통과했다" 로
    안 읽힌다(spec §9-2).
  · 버그를 못박던 단언을 삭제하고 status 별 단언 28개 + `keys(SILENT_SUCCESS_STATUSES) ==
    ENACTABLE_TODAY` 로 교체 — 보수적 기본값이 집행 가능한 6개에 대해 **도달 불가**해졌다.
  · 새 testset (12) 가 19행의 name→impl 짝(`nameof` 로 resolved callable 확인, 레지스트리
    문자열이 아니라)과 정렬된 `params` 키를 못박는다. 내가 준 편집 둘이 변이 12a/12b 로 red.
  · R43 구현: `world_maybe_dirty = applied || partial` 추가.
  · 트랜스크립트 정정: 변이 9 는 5건이 아니라 **12건** 실패 — 구현자의 `head -6` 절단이었다.

Ruling R45 (구현자의 새 우려 — `recover_stalled_teams!` 의 `:restaged` 는 한 겹 더 깊은
침묵 성공을 숨긴다: 중첩된 `restage_*` 가 `:none` 을 냈어도 이쪽은 `:restaged` 로 보고한다):
**parked, 의도적으로 안 판다.** 이유: 이 계획이 겨냥하는 두 body 에 그 원시가 없다
(zone = `restage_all_blocked`+`translate_whole_build`, battery = 재가격+재풀이). 한 겹 더
푸는 것은 원시의 반환 계약을 바꾸는 일이고 이 계획의 범위 밖이다.
🔴 **T10 보고서의 "무엇의 증거가 아닌가" 절에 반드시 적는다** — 그 원시가 body 에 들어가는
순간 이 레인의 `applied` 는 다시 신뢰할 수 없다.
— 대가(틀렸을 때): 모델이 `recover_stalled_teams` 를 조합하면 그 판의 `applied` 가 과대
보고된다. 로그의 steps 에 status 가 그대로 남으므로 사후에 판별 가능하다.
Task 3: 재리뷰 — 3 findings 전부 ADDRESSED, R43 룰링 구현 확인, 새 breakage 0.
  재리뷰가 6개 원시의 **모든 `return` 을 소스에서 재유도**했고 분류 안 된 status 가 0개임을
  확인. 스위트를 직접 돌려 `1834 pass / 0 fail / 1 error(Gurobi)`, 델타 +159 = 게이트 단언 수.
  옛 `applied` 의미론에 기댄 소비처가 레포 전체에 **0개**(T4 미작성).
  · ⚠️ 보고서의 "다섯 번째 경로" 주장이 **반증됐다**(무해): `carrier.status` 전달 둘 다
    `carrier.status in (:carrier_closed,:carrier_advanced) &&` 로 가드돼 있어
    `:disabled`/`:no_carrier` 는 거기서 절대 표면화 못 한다. 죽었지만 안전한 항목이다.
Task 3: minor (deferred): 🔴 **세 번째 레지스트리 확장 경로가 열려 있다** — testset (12) 는
  `params` 의 **키**만 못박고 **값 스키마**(type/items/enum)는 아무것도 안 본다.
  `synthesize.py::_fmt_params` 가 그 값을 모델에게 렌더하고, `bind_primitive_args` 는 매치된
  param 을 **검증 없이** 넘긴다(`zone_keys` 만 강제 변환·확인). `mechanism` 산문도 못박히지 않는다.
Task 3: complete (commits cca671ec..29cb0a1d, review clean, 5 minors parked)

Ruling R46 (위 세 번째 확장 경로):
일반 해법(값 스키마 전부 못박기)은 **최종 리뷰로 미룬다** — 오늘 집행 가능한 6개 중 값이
실제로 원시에 닿는 것은 `zone_keys` 뿐이고 그것은 이미 강제 변환·확인된다. 🔴 그러나
**T6 은 자기 params 값을 스스로 검증해야 한다**: `light_bias` 가 수치이고 자기 레지스트리
스키마의 [0,4] 안인지, `agent` 가 접지되는지. 그 둘은 LLM 이 주는 값이 그대로 live 원시에
닿는 이 계획 안의 유일한 새 표면이다.
— 대가(틀렸을 때): 레지스트리 값 스키마를 넓히는 편집이 게이트 전부 초록인 채로 통과한다.
  최종 리뷰가 triage 한다.

Task 4: 구현 commit `02aa5b9e` (DONE_WITH_CONCERNS). 스위트 1913 pass / 0 fail / 1 error.
  델타 +79 = 신규 게이트. 유료 호출 0, 렌더 0.
  · 🔴 구현자가 **자기 게이트의 "실패할 수 없는" 결함 2건을 스스로 찾아 고쳤다**:
    여러 줄 `println` 은 토큰이 **첫 물리 줄에만** 실리고, `findfirst` 가 자기 **주석**을
    매치하고 있었다(주석이 금지 라벨과 심볼 이름을 담고 있었으므로). 둘 다 처음엔 초록.
    `code_block`(주석 제거) 로 고친 뒤 둘 다 red. 이 레포가 이름 붙인 실패 모양 그대로다.
  · C7 의 `zone_diagnosis` 필드 아홉이 **전부 실재**함을 확인. 게이트 (8) 이 인쇄된 이름들을
    **live 반환**과 대조하므로 오타가 렌더 시점이 아니라 여기서 빨개진다.
  · 허용 목록 밖 파일 1개 수정: `test/render_lane_uses_llm_agent.jl` — 그 샌드박스가
    `policy_producer` 의 소스를 eval 하고 심볼을 명시 import 하므로 새 심볼이 없으면
    `UndefVarError`. 스텁 대신 **진짜를 import** 했다(스텁이면 샌드박스가 생산 코드와 다른
    것을 태운다). 그 파일은 작업 트리에서 clean 이었으므로 남의 작업은 안 담겼다. 확인함.
  · 🔴 concern: **`handled=true` 경로는 아직 한 번도 실행된 적이 없다.** T5 의 판이 처음이다.
Task 4: 리뷰 — Spec ✅ / 품질 **Critical 1 + Important 1 + Minor 2**. 리뷰어가 C3 를
  **경험적으로** 확인(`enact_minted!` 를 in-memory 로 던지게 만들어 전파 안 되는 것 관측),
  스위트를 직접 돌려 1913/0/1 재현, 구현자의 자기 결함 수정 2건도 직접 재변이해 red 확인.
  `handled=true` 경로 추적 결과: 프레임워크가 못 나아가는 상태는 **없다**(`:noop` 로 계속).

  🔴 **Critical — 집행 가능한 6개 중 3개가 스케줄 캐시를 재개하지 않고, `handled=true` 가
  재개해 줄 유일한 호출자를 건너뛴다.** `enact_minted!` 는 `r.prim.impl(env)` 를 날것으로
  부른다. `reform_stuck_teams!` · `recover_stalled_teams!` · `force_advance_stuck_carrier!` 는
  `reset_cache_resume!` 를 **내부에서 안 부른다** — `reform_stuck_teams!` 의 주석이 직접
  "호출자가 reset_cache_resume! 로 스케줄을 몬다" 고 적고, `ood_injection.jl` 이 그 대가를
  적는다: **"그래프는 바뀌었는데 캐시가 옛 프론티어를 들고 있어 복구가 무효 — 에러는 안 난다."**
  (`resolve_schedule_wedge!`·`restage_all_blocked!`·`translate_whole_build!` 는 재개한다.)
  구체적 실패: body `["recover_stalled_teams"]` → `:snapped` → `applied=true` → `handled=true`
  → `policy_producer` 가 `nothing` → `:noop`. 로그는 `verdict=admit applied=true handled=true`
  를 찍고 T9/T10 이 그것을 "합성 tool 이 세계를 고쳤다" 로 읽는다. 실제로는 프론티어가 낡았고
  아무것도 안 나아가며 **OOD 사건은 소비돼 재시도되지 않는다.** 게이트는 못 본다(손으로 만든
  env 에 `cache`/`sched` 가 없다). 이것은 CLAUDE.md 가 이름 붙인 실패 모양 그대로다.

  🔴 **Important — `world_maybe_dirty=false` 인데 빌드가 물리적으로 이동한 경우가 있다.**
  `translate_whole_build! :residual_blocked` 와 `restage_all_blocked! :residual_blocked` 가
  `SILENT_SUCCESS_STATUSES` 에 있어 `applied=false, partial=false → world_maybe_dirty=false`
  인데, `_apply_uniform_translation!`/`restage_assembly!` 는 **이미 돌았다.** C1 이 "세계가
  더러운가" 로 지정한 바로 그 필드가 이동된 빌드에 대해 `false` 를 찍는다.
  · minor (deferred): 영속 결정 행에 합성 집행의 흔적이 없다(`record_decision!` 이 배선보다
    먼저 돌고 수정되지 않는다). 의도된 설계(채점기 비오염)이지만 **T9/T10 은 산출물이 아니라
    stdout 을 파싱해야 한다.**
  · minor (no action): catch 경로의 `world_maybe_dirty=false` 는 `enact_minted!` 가 내부
    try 를 유지하는 한에서만 참인 합성적 주장 — docstring 에 적혀 있다.

Ruling R47 (Critical — 캐시 재개):
🔴 **T5 의 유료 판 전에 반드시 고친다.** 이것을 안 고치고 판을 돌리면 "성공을 보고하는
무동작" 을 유료로 렌더하고 T10 에 개선으로 적게 된다 — 이 계획이 처음부터 막으려던 바로 그것.
설계: 원시별로 "이 원시가 캐시를 재개하는가" 를 **소스에서 읽어** 표로 만들고
(`SILENT_SUCCESS_STATUSES` 와 같은 방식, `keys(...) == ENACTABLE_TODAY` 게이트 포함),
재개 안 하는 원시가 세계를 바꿨으면 `enact_minted!` 가 body **끝에서 한 번** `reset_cache_resume!`
를 부른다. 🔴 멱등성을 **소스에서 확인**한 뒤에 쓴다 — 확인 안 되면 "재개 필요" 원시가 하나라도
있을 때만 부른다. 그 호출 사실은 `steps` 나 reason 에 남는다(조용한 폴백 금지).
— 대가(틀렸을 때): 이미 재개한 원시 뒤에 한 번 더 재개한다. 낭비이지 손상이 아니라면 허용.

Ruling R48 (Important — 표를 **둘**로 가른다):
`:residual_blocked` 는 "적응을 달성 못 했다"(silent success)이면서 동시에 "세계를 만졌다" 다.
한 표로는 둘을 못 나른다. `SILENT_SUCCESS_STATUSES`(=`applied` 용, 달성 여부)와
**`WORLD_UNCHANGED_STATUSES`**(=`world_maybe_dirty` 용, 접촉 여부)를 **분리**한다.
`:residual_blocked` 는 첫째에 있고 둘째에는 **없다**. 각 status 의 소속은 원시 소스에서 유도한다.
— 대가(틀렸을 때): 필드가 하나 늘고 표가 둘이 된다. 지금 안 가르면 zone 매크로가 어휘로
돌아오는 순간 이 거짓말이 로그가 아니라 **제어 흐름**이 된다(리뷰어의 지적).
Task 4: fix round 1/5 (Critical + Important addressed; commits 02aa5b9e..fa59eebf).
  스위트 2005 pass / 0 fail / 1 error (+92).
  · Critical: 여섯 소스를 전부 읽고 `PRIMITIVE_RESUMES_CACHE` 신설. 재개하는 셋 /
    안 하는 셋(`force_advance_stuck_carrier!` 는 `update_planning_cache!` 를 부르지
    `reset_cache_resume!` 가 아니다). **멱등성을 소스에서 확인**했고
    (`resolve_schedule_wedge!` 가 이미 연달아 두 번 부른다) 그럼에도 **좁은 트리거**를 유지.
    미지 원시는 "재개 안 함" 으로 기본값. 결과가 새 `resume` 필드(5상) + reason + 로그에 남는다.
  · 🔴 **게이트가 이 결함을 실제로 본다**: 진짜 `OperatingSchedule` + `initialize_planning_cache`
    에 낡은 `active_set` 을 심어, (13-e) 양성 대조(재개가 나가고 프론티어가 **관측 가능하게**
    비워진다) + (13-f) 음성 대조(같은 fixture 에서 프론티어 보존). 내가 요구한 그대로다.
  · Important: `WORLD_UNCHANGED_STATUSES` 분리. 내 최소 요구를 **넘어 셋째**를 찾았다 —
    `translate_whole_build :already_clear` 도 세계를 만진다(`_apply_uniform_translation!` 이
    Δ 와 무관하게 `_resync_scene_drift!` 를 부른다). 불변식 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`
    를 여섯 전부에 대해 게이트 — `handled` 는 넓어지기만 한다.
  · 변이 9건(N1~N9) red 확인 후 되돌림.
  · concern: 원 증상(낡은 프론티어 ⇒ 복구 무효)은 **full run 이라야 관측된다** — 게이트는
    재개의 유무만 못박는다. T5 의 판이 그 자리다.
Task 4: 재리뷰 — 두 finding 전부 ADDRESSED. 재리뷰가 재개 표를 **소스에서 재유도**해 6/6 일치
  확인, 멱등성 확인, 그리고 **대조를 직접 깨뜨려** 진짜 대조임을 증명했다:
  Break A(재개 제거) → (13-e) RED `isempty(Set([999]))` = 낡은 프론티어가 관측 가능하게 남음.
  Break B(무조건 재개) → (13-f) RED `Set{Int64}() == Set([999])` = 보존돼야 할 것이 사라짐.
  구현자의 `:already_clear` 주장도 소스에서 확인(`_apply_uniform_translation!` 이 Δ 가드 없이
  `_resync_scene_drift!` 호출). 스위트 2005/0/1 재현, 델타 +92 전부 설명됨.
  판정: **"clear to spend the paid board."**
Task 4: minor (deferred) 🔴 **`tools/monitor/test_minted_wiring.jl` 이 반증된 pre-fix 규칙을
  아직 단언한다**: `r.world_maybe_dirty === (r.applied || r.partial)`. 지금 초록인 이유는 그
  fixture 둘이 "만졌는데 적응은 아님" status 에 한 번도 안 닿기 때문이고, 닿는 순간 거짓말이
  된다. **병합 전 반드시 고칠 것** — 최종 리뷰가 triage.
Task 4: minor (deferred): `WORLD_UNCHANGED_STATUSES` docstring 의 "세계를 한 바이트도 안
  건드리고" 는 `CARRIER_LAST_D` 기록 때문에 문자 그대로는 거짓.
Task 4: minor (deferred): `resume=:issued` 는 아직 **진짜 빌드에서 태워진 적이 없다**(빈
  스케줄에서만). T5 의 판이 그 자리다.
Task 4: complete (commits 29cb0a1d..fa59eebf, review clean, 4 minors parked)

Ruling R49 (T5 의 서비스 기동 — 계획서의 `pkill` 을 그대로 쓰지 않는다):
계획서 T5 Step 1 은 `pkill -f "uvicorn dspy_service:app"` 로 **둘 다** 죽인다. :8079 는 이
계획의 것이 아니므로 건드리지 않는다. :8077 만 재기동하고 `ps lstart` 로 시각을 확인한다.
🔴 재기동은 **필요하다**: `src/respec/llm_service/dspy_service.py` 가 작업 트리에서 수정된
상태이고(남의 WIP), 살아 있는 프로세스가 그 코드인지 보장이 없다 — 이 레포가 실측한
"낡은 프로세스가 /health 200 을 낸다" 함정이다. `TOOL_SYNTHESIS=1` 은 현재 :8077 에 이미
걸려 있음이 실측됐지만, 재기동 시 **명시적으로** 다시 건다.
— 대가(틀렸을 때): 남의 서비스를 죽이지 않는 대신 포트 혼동 위험이 남는다. `DSPY_URL` 명시로 막는다.

## Task 5 — **STOP** (계획서 Step 3 의 정지 규칙). commit `86b7eb35`. 유료 3/3 소진.

관측된 것:
```
[zone] blocking zone on transport vtx=153 @[1.094, 0.416] r=0.07 -> nav_blocked=3/131
[zone] diag n_blocked=3 n_nav_blocked=3 root_covered=0/8 n_work_overlap=6 n_teams_covered=0
       n_nav_goals=131 n_nav_engulfed=3 n_agent_trapped=0
[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM
[policy] ZoneTruth → NOOP (enacted=dspy; rule=NOOP)
[minted] lane=reach_nothing … verdict=deferred … handled=false … steps=[] ran_milp=n/a(not armed)
         reason=no synth lane on this decision
PROJECT INCOMPLETE!
```
🔴 **합성이 발화하지 않았다. `expressible: true` 다.**

진단 — **알파벳도 배선도 아니다**:
 · `n_blocked=3`(막힌 **조립체**), `root_covered=0/8` → `restage_all_blocked!` 는 `:none` 조기
   반환에 안 걸린다. 즉 이것은 **가장 유리한 zone 판**이었다. R28 이 걱정한 알파벳 한계가 아니다.
 · 배선 검사 셋 전부 통과(`[router] unknown:zone` 줄이 `_unfamiliar_block` 렌더를 증명).
 · 인터프리터는 **한 번도 안 불렸다**(`steps=[]`). T4 의 `handled=true`·`resume=:issued` 경로는
   여전히 미실행이다.
 · 🔴 구현자가 계획서 probe payload 의 결함을 잡았다 — `zones` 와 `routing_kind` 가 빠져 있어
   두 프롬프트 블록이 **빈 채로** 렌더된다. 그 채널 둘만 더해 재측정(유료 3번째):
   여전히 `expressible:true`, `tool_called:no_intervention`, `tool_arg_error:null`.
   → "못 쟀다" 도 "에러" 도 아니고 **모델의 판정**이다.
 · 프롬프트는 한 글자도 안 건드렸다. `synthesize.py` clean, 소스 변경 0.

Task 5: concerns (전부 기록):
 (1) `[minted] lane=reach_nothing` 이 세 상태를 한 줄로 뭉갠다 — 아홉 `SYNTH_LANE_KEYS` 는
     결정 행에 이미 있는데 안 찍힌다. 이것 때문에 유료 호출 하나를 더 썼다.
 (2) 결정 JSON 이 아예 안 쓰인다 → C5 는 stdout 을 보라는데 stdout 은 lossy. 사후 분석이
     양쪽 다 막혀 있다.
 (3) `expressible` 은 tool-call 인자에서만 온다 → 모델이 그 필드를 생략해도 같은 줄이 나온다.
 (4) `.superpowers/sdd/` 도 gitignore 대상이라 `-f` 필요(R24 의 확장).
 (5) 🔴 `_zones_block` 이 `max_shift`/`work_reach` 를 **일부러 안 싣는다**. 모델이 보는 것은
     "반경 0.07 원이 조립체 3개를 덮는다" 뿐이다. NOOP 은 그 입력에 대한 불합리한 독해가
     아니다. **레버는 프롬프트 문구가 아니라 "어떤 측정값을 실을 것인가" 이고, 그것은
     사용자 결정이다.**

## 🔴 사용자 결정 (2026-08-30, T5 STOP 이후)
D-A. zone 레인: **관측 채널을 넓히지 않는다. 여기서 계획을 멈추고 보고서만 쓴다.**
     → `_zones_block` 에 아무것도 추가하지 않는다. zone 레인은 `expressible=true` 라는
       **측정 결과**로 닫는다.
D-B. Phase D: **레버를 재설계한 뒤 진행한다.**
     → T6/T7/T9 를 설계대로 집행하지 **않는다**(후보 간선 0 이므로 무동작). 고정 간선에 닿는
       레버의 재설계는 brainstorming 부터 다시 하는 별도 작업이고 **이 세션의 범위를 넘는다.**
     → T10 보고서가 그 재설계의 출발점이 되도록, 측정된 사슬을 전부 담는다.

귀결: 남은 작업은 **T10(보고서) → 최종 전체 리뷰 → 브랜치 마감** 이다.
T6·T7·T9 는 집행하지 않는다(사용자 결정 D-B).

Task 10: 보고서 commit `81ee7f8b` — `docs/superpowers/reports/2026-08-30-minted-tool-enactment.md`
  (511줄, 9절). 유료 0건, 렌더 0. 종료 실측을 **직접 재유도**: Julia 2005/0/1, pytest 194/5.
  🔴 sourced 못 한 것 셋을 정직하게 표시했다: (a) `0f895b46` 시점 Julia 기준선은 이 세션에서
     **한 번도 안 쟀다** — 1553/0/1 은 T8 첫 실패 런에서의 **산술**이지 측정이 아니라고 명시.
     계획서의 1487 은 다른 커밋의 낡은 인용. (b) T1 커밋 직후 절대 pass 수(1607)는 원장에도
     T1 보고서에도 없다 — +46 델타만 있다. (c) T3 델타가 두 방식으로 기록됨(+64 그리고 +95 vs
     "1675→1834 = +159") — 둘 다 인용하고 임의로 하나를 고르지 않았다. (실제로는 모순이 아니다:
     초기 +64, 수정 +95, 합 +159.)
Task 10: complete (commit 81ee7f8b)

## 최종 리뷰 수정 파동 (2026-08-30, BASE `81ee7f8b`) — 유료 0건, 렌더 0

Ruling R50 (CRITICAL — **다섯 번째 조용한 미복구**: `resume === :failed` 인데 `handled=true`):
R47 이 `resume` 필드를 만들었는데 T4 의 `handled` 가 그것을 **한 번도 안 읽었다.** body
`["recover_stalled_teams"]` → `:snapped` → `need_resume` → `_issue_resume!` 이 던지면
`resume=:failed, applied=true, handled=true` 다 — 세계는 고쳐졌고 프론티어는 낡았는데 기본
복구 사슬이 통째로 건너뛰어지고 그 OOD 사건은 이미 소비돼 다시 오지 않는다. 이것이 정확히
`PRIMITIVE_RESUMES_CACHE` 의 docstring 이 막겠다고 적은 사건이다.
🔴 게이트가 그 버그를 **인증하고 있었다**: `test_minted_wiring.jl` (2) 가 `resume === :failed`
와 `handled === true` 를 **함께** 단언했다.
결정: `handled = (:admit) && world_maybe_dirty && (resume !== :failed)`. 다섯 상태 중
`:failed` 하나만 막는다 — 나머지 넷은 전부 "프론티어가 낡지 않았다" 이다(소스에서 유도).
게이트는 **같은 body·같은 던지는 지점, env 만 다른 쌍**으로 가른다: (2) 진짜
`OperatingSchedule`+`PlanningCache` → `resume=:issued` → `handled=true`; (2b) 캐시 없는 env
→ `resume=:failed` → `handled=false` + `NOT handled` 출력.
— 대가(틀렸을 때): 재개가 실패한 판에서 절반 고쳐진 세계 위로 폴백이 한 번 더 간다. 그 반대
  (조용한 미복구를 성공으로 기록)보다 압도적으로 싸다. undo 는 여전히 없다.

Ruling R51 (CRITICAL — 반증된 규칙이 게이트와 생산 산문 **양쪽**에 살아 있었다):
`test_minted_wiring.jl` (4) 의 `r.world_maybe_dirty === (r.applied || r.partial)` 와
`enact_minted_decision!` docstring 의 같은 등식. R48 이 그것을 `touched || partial` 로 바꿨다.
초록이던 이유는 fixture 운이고, 닿는 순간 **옳은 코드를 상대로** 빨개져 자연스러운 "수정" 이
R48 을 되돌리는 것이 된다.
결정: (4) 는 경계에서 관측 가능한 **참인 함의 둘**만 단언한다. 새 (4b) 가 오염 레지스트리로
`:unreadable_return` 에 실제로 닿아 옛 등식이 거짓임을 값으로 못박는다(`applied=false ·
partial=false · world_maybe_dirty=true`). docstring 은 정의를 `enact_minted!` 의 `_r` 하나에
위임하고 다시 적지 않는다(어휘 단일 진실원).

Ruling R52 (IMPORTANT — 타입 틀린 param 이 무동작을 `handled=true` 로 바꾼다):
레지스트리 `params` 의 **값**이 아무것도 못 박혀 있지 않고 `bind_primitive_args` 가 매치된
param 을 검증 없이 넘겼다(`zone_keys` 만 예외). `{"min_ready": 1.5}` 는 **호출 경계**에서
`TypeError: in keyword argument min_ready, expected Int64, got a value of type Float64` 로
죽는다 — impl 본문은 한 줄도 안 돌았다. 그런데 `enact_minted!` 의 `catch` 가 무조건
`partial=true` 를 적어 `handled=true` 가 되고, **증명 가능하게 손 안 댄 세계**에서 폴백이
삼켜진다(실측 트랜스크립트가 최종 보고서에 있다).
결정: 리뷰어 triage 대로 **최소 수정** — `PARAM_JSON_TYPES` + `_param_type_reject` 로
"선언된 타입으로 `convert` 되는가" 만 본다. 판정 기준은 `isa` 가 아니라 `convert` 다(JSON 이
`2.0` 을 Float64 로 읽는 정상 판을 거절하지 않기 위해). 선언 없음·모르는 타입은 **거절**이다.
🔴 R46 의 전면 값 스키마(범위·enum·items)는 **여전히 parked** — 이번에 안 팠다.

Ruling R53 (IMPORTANT — 조기 반환이 거짓말을 하고 증거를 버렸다):
`sl !== nothing && reach === nothing` 갈래에서 `reason=no synth lane on this decision` 은
**거짓 진술**이었고, 판별에 필요한 넷(`synthesis_event`/`synthesis_ran`/`synthesis_error`/
`tool_minted`)을 손에 들고도 안 찍었다. 그 뭉갬이 T5 에서 **유료 호출 1건을 낭비시켰다**.
결정: 갈래마다 다른 사유 + 그 넷(+`missing_primitive`)을 찍는다. 없는 값은 `nothing` 으로
찍는다(`false` 로 접지 않는다 — "못 쟀다"와 "거짓이다"는 다른 관측이다).

Ruling R54 (IMPORTANT — `SYNTH_LANE_KEYS` 에 교차언어 그물이 없었다):
`tool_lane_keys_survive.jl` (6)절은 파이썬 표식 **아래** 집합만 본다. 합성 키는 표식 **위**에
살고 여덟은 아예 `synthesize.py` 의 기록 dict 안이다. 그래서 파이썬에서 `ran` 을 개명하면
`synthesis_ran` 이 영원히 `nothing` 인데 **줄리아 게이트가 전부 초록**이었다.
결정: (6)절의 관용구를 `synth_lane_keys_survive.jl` 로 옮긴다 — `ast` 로 두 파일을 읽고,
`out["dspy"]` 표식 **위**에 `tool_minted`·`synthesis` 가 있는지 + `synthesize.py` 의 기록 키가
`_SYNTH_RENAME` 을 통해 아홉을 덮는지. 🔴 `dspy_service.py` 는 **읽기만** 한다(남의 미커밋
작업) — 변이는 전부 `mktempdir()` 안의 사본이다. 파이썬 편집 0건.

Ruling R55 (MINOR — 문구): `WORLD_UNCHANGED_STATUSES` 의 "한 바이트도" 는
`force_advance_stuck_carrier!` 의 `CARRIER_LAST_D` 기록 때문에 문자 그대로 거짓. 분류는 옳다
(진행 메모이지 세계 상태가 아니다). 문구만 참으로 바꾸고 근거를 적었다.

최종 리뷰: 보고서 정정 3건 — (a) 1607 은 **실측**이다(`task-1-report.md` · 커밋 `05f1d2b5`
메시지 · `task-2-report.md` 의 "+68 vs. prior 1607"), (b) 사후 분석은 **양쪽이 아니라 한쪽만**
막혀 있다(스트림 115행이 합성 레인을 영속한다; 없는 것은 집행 결과 — 전수 검색 0건) 그리고
**T5 의 세 번째 유료 호출은 불필요했다**, (c) 세 매크로 이름의 소유자는
`test/smdp_stamp_smoke.jl` 이지 `test/policy_macro_binding.jl` 이 아니다.
스위트 **2082 pass / 0 fail / 1 error(Gurobi 10009)** — 델타 +77 (2005 기준), 전부 새 단언:
`test_minted_wiring.jl` +34 (83→117) · `test/minted_tool_enacts.jl` +27 (247→274) ·
`test/synth_lane_keys_survive.jl` +16 (46→62). 변이 8건 전부 red 확인 후 되돌림.
전문: `final-fix-report.md`.
