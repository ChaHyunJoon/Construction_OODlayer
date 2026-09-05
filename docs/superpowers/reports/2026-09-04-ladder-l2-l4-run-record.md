# SDD ledger — plan: docs/superpowers/plans/2026-09-04-ladder-l2-l4-and-demo.md

Spec (구속력 있는 권위): docs/superpowers/specs/2026-09-03-callable-world-interface-design.md (§0 사다리, D9–D19)
선행 계획: docs/superpowers/plans/2026-09-03-callable-world-interface.md (커밋 3108add4..17aac73b, 완료)
Branch: oracle-rebuild-night-2026-08-10 · BASE at start: 3e5cca87
Worktree policy: NO git worktrees (사용자 결정 2026-09-02). 단일 체크아웃, 여러 세션 공유.
Validator: .claude/agents/callable-world-validator.md (opus, effort max, read-only)

## 사용자 목표 (2026-09-04, 직접)
4시간 안에 L2·L3·L4 를 전부 올려서, multi-agent LLM 이 본 적 없는 OOD 실패 사건에 대해
새 tool 을 생성하고 build 를 완주시킨다는 것을 **데모로 보인다**.

## Preflight conflict scan

| # | pair | 공유 파일/인터페이스 | produces → consumes | finding |
|---|---|---|---|---|
| A | T1 → T2 | `tools/monitor/enact.jl` | T1 이 `:1601` 렌더와 `record_world_delta!` 를 고치고, T2 가 **같은 두 자리**에 또 칸을 더한다 | 🔴 **충돌**. 병렬 금지. |
| B | T1 → T2 | `test/minted_end_to_end.jl` | 둘 다 파일 **끝**에 새 testset 추가 | 순차면 무해 |
| C | T2 | `test/minted_end_to_end.jl:998` `length(row["world_delta"])==4` · testset (17) 어휘 고정(`:1046,:1047,:1053`) | T2 가 다섯째 축을 더한다 | 계획서가 **미리 지목**했다. 갱신은 약화가 아니라 이동이어야 한다 |
| D | T3 vs T1·T2 | — | T3={world_interface.py, synthesize.py, pytest}, T1·T2={enact.jl, minted_tool.jl, test/*.jl} | **서로소** ✅ 병렬 가능 |
| E | T3 → T4 | 실행 중인 DSPy 서비스 | T3 이 파이썬을 고치면 PID 3161910 은 **낡은 세대**가 된다 | T4 Step 3b 가 재기동을 소유한다. 구현자는 서비스를 안 건드린다 |
| F | T2 → T4 | `world_delta_body` | T4 의 L4 술어가 T2 의 새 필드를 읽는다 | T2 가 안 들어오면 L4 는 오늘의 봉투 델타로 후퇴 |
| G | 모든 태스크 | 작업트리 | 미스테이징 삭제 **218건**이 선재(우리 것 아님) | Global Constraint 1: `git add -A` 금지, 명시 경로만 |
| H | T1 자기 | 기록 줄 형식 | `tools/monitor/test_minted_wiring.jl:277` 이 `occursin("threw", out)` | 그 단언은 `reason=body threw at …` 로 통과하므로 `steps=` 형식 변경에 무관 — 그래도 재측정 지시 |

### Preflight rulings

- **Ruling A1: Task 1 과 Task 2 를 한 구현자에게 순차로 준다** (두 브리프를 함께 주고, 각각 별도 커밋).
  근거: 같은 파일의 같은 두 함수를 만지므로 병렬은 불가능한데, 두 번의 dispatch+review 사이클은
  4시간 예산에서 ~30분을 태운다. 리뷰는 두 커밋을 **한 패키지**로 뜬다.
  대가: 리뷰 표면이 커진다. 커밋은 여전히 태스크마다 하나라 되돌리기는 그대로다.
- **Ruling A2: Task 3 을 Task 1·2 와 동시에 굴린다** (finding D — 파일 집합이 서로소).
  대가: 없다. `git index.lock` 재시도를 양쪽에 지시했다.
- **Ruling A3: 전체 스위트(22~23분)를 태스크마다 돌리지 않는다.** 구현자는 관련 시험 파일만
  단독 실행한다. 전체 스위트는 Task 4 의 런 전 체크리스트에서 **한 번** 돈다.
  근거: 예산. 대가: 태스크 사이에 든 회귀가 런 직전까지 안 보인다 — 그 자리가 체크리스트다.

## 실행 기록

계획 커밋 `3e5cca87`. BASE = `3e5cca87`.
사전등록 v3 커밋 `84fb7d56` (결정 20~26) — **결과를 보기 전에** 썼다.

Task 1+2 (Julia, enact.jl + minted_tool.jl): 구현자 dispatch (opus). Ruling A1 대로 한 agent 가 순차로.
Task 3 (Python, llm_service): 구현자 dispatch (opus). Ruling A2 대로 병렬.

- **Ruling A4: 음성 대조 런을 태스크와 **동시에** 굴린다.** 근거: 대조는 `TOOL_SYNTHESIS` 없이 뜬
  서비스(8078)를 쓰므로 합성 레인이 꺼져 있고, Task 1·2 의 enact.jl 변경은 tool 이 안 주조되면
  **불활성**이며, Task 3 의 프롬프트 변경은 합성 레인 전용이라 대조의 `/decide` 경로를 안 건드린다.
  시드 재현성 확인함: `render_demo.jl:1086` `rng = Random.MersenneTwister(DEMO_SEED)`, 기본 1
  ⟹ 처치와 대조가 **같은 step 에서 발화**한다. 대가: 대조가 유료 호출 ~1회를 더 쓴다(결정 agent).
  검증 조건: 두 로그의 `battery drawn at step=` 이 같아야 한다 — 다르면 대조 무효로 보고한다.
- **Ruling A5: 대조는 `DEMO_CASE_TAG=battery_mild` 를 처치와 **똑같이** 쓴다.** 근거: case tag 가
  라우터의 `routing_kind` 문자열에 들어가므로 태그를 바꾸면 라우팅 입력이 달라져 대조가 아니다.
  대가: 두 런이 같은 스트림 경로에 쓴다 → 대조 산출물을 처치 전에 옆으로 치운다.
- 대조 서비스 실측: 8078, `code_fingerprint 1697b61c53f3d2a2`, **`synth_tool_synthesis: False`** ✅.
  8077(PID 3161910)은 안 죽였다.
- 런 전 치움: `results/synth_lane_records.jsonl` → `…pre-run2.jsonl`,
  `tools/monitor/streams/tractor__battery_mild.jsonl` → `…pre-run2.jsonl`.

🔴 **Ruling A4 는 틀렸다 — 실측이 뒤집었다.** 대조 런이 시뮬레이션에 **들어가기도 전에** 죽었다:

```
[generation] FAIL stale — 서비스가 다른 바이트를 서빙 중이다:
  served=1697b61c53f3d2a2 tree=3bde93ab0ccbab63
ERROR: LoadError: [generation] 이 런은 DSPy 서비스를 쓴다(DEMO_POLICY=dspy)는데
  그 서비스가 이 트리를 서빙하고 있지 않다.
```

내가 놓친 기전: 세대 게이트(`render_demo.jl:737-746` → `require_current_service`)는 **`/decide` 경로냐
합성 경로냐를 안 가린다.** 서비스의 `code_fingerprint` 를 **작업트리 전체**의 해시와 대조하므로,
Task 3 이 `src/respec/llm_service/` 를 만지는 순간 **모든 런**(대조 포함)이 막힌다.
"대조는 Task 3 과 무관하다" 는 프롬프트 수준에선 참이지만 **게이트 수준에선 거짓**이다.

- 대가: 대조 런 하나를 버렸다. **유료 호출은 0** — 게이트가 `/decide` **앞**에서 막았다(로그 확인).
- 정정: 대조와 처치를 **둘 다 Task 4 창에서**, 두 서비스(8077·8078)를 **Task 3 착륙 뒤 재기동한 다음**
  연달아 굴린다. Ruling A5(같은 case tag)는 그대로 유효하다.
- 🔴 **이것이 이 레포의 서명 실패를 한 번 더 확인해 준다**: 정적 추론("무관하다")이 실측에 졌다.
  게이트가 안 막았으면 나는 **낡은 바이트로 돈 대조**를 진짜 대조로 보고했을 것이다.

- **Ruling A6: `MAX_TOKENS` 를 안 올린다.** Task 3 이 프롬프트(입력)를 늘리는데, 원래 유료 런 1 이
  죽은 사인은 `AdapterParseError`(출력 8필드 중 4) = **출력** 예산 고갈이었다. 그래서 위험을 봤다.
  실측: `dspy_service.py:82` `MAX_TOKENS = 2000` 이고, **선행 세션이 500→2000 으로 이미 올리며
  근거를 주석에 남겼다**(`:78-81`). 환경변수로 안 열려 있다. 어제 런은 이 상한 안에서 8필드를 다 냈다.
  ⟹ 지금 건드리면 런 사이에 변수가 하나 더 갈리고, 이득은 가설적이다.
  대가: Task 3 의 "이유를 주석으로 적으라"는 지시가 출력을 늘려 **또 잘릴 수 있다**.
  **감시 조건**: 런 2 가 `AdapterParseError` 나 `wrote=false` 로 죽으면 **그때** 4000 으로 올리고
  재런한다(그 재런은 처치의 재시도이지 새 조건이 아니다).

### Task 3 (Python, L3 프롬프트) — 1차 착륙

Task 3: DONE_WITH_CONCERNS, commit `b69a53b8` (4파일, +88/-2).
pytest **379 → 384 passed / 5 skipped / 0 failed** (+5 새 시험, 전부 음성 대조로 빨강 확인).
렌더 블록 **29,660자 606줄 → 30,403자 615줄** (직접 호출로 실측) ⟹ 사전등록 체크리스트 B4 충족
(값이 **움직였다** = Task 3 이 실렸다).

🔴 **구현자가 내 브리프의 수 둘을 정정했다 — 둘 다 받아들인다:**
 (1) pytest 기준선은 **379** 이지 브리프의 368 이 아니다. 내가 옛 원장 항목에서 **인용**한 수였다.
     이 레포가 반복해 밟는 "인용한 수" 실패를 내가 또 밟았고 구현자가 옳은 방향으로 잡았다.
 (2) Step 4 는 **무동작**이다 — 블록 크기를 못박는 선재 시험이 `src/respec/llm_service/` 에 **없다**.
     29,660/606 은 산문에만 산다. 새 핀 시험을 **안 만든 것이 옳다**(산출물 재생성마다 빨개진다).

- **Ruling A7: `RewriteToolImpl` 에도 반환 규약 예시를 준다** (구현자가 신고한 구멍을 승격).
  근거: `/rewrite` 는 이 시스템의 **유일한** 자기수정 채널(재시도 상한 1)이고, 그것이 발화하는
  때는 정확히 첫 body 가 거절된 때다. 쓰기 프롬프트에는 있고 재작성 프롬프트에는 없으면,
  **깨진 body 를 고치는 것이 유일한 일인 채널이 원래의 깨짐을 재생산할 수 있는 유일한 채널**이 된다.
  대가: 어떤 런도 안 밟으면 프롬프트 두 줄이 놀고 있는 것뿐이다.
  같이 지시: bare-Symbol 반환 예시도 양쪽에 (C2 확장이 조용히 억제되지 않게).

### 계측: `ladder_report.py`

commit `6d88bede`. 런 산출물(로그·스트림·합성기록)에서 사다리를 **기계로** 읽는다.
삼상 전면 적용 — UNMEASURED / FALSE / MEASURED-EMPTY / MEASURED-ZERO / TRUE 를 **다른 낱말**로 찍는다.
어제 런의 산출물로 검증: L0 TRUE · L1 TRUE · L2a TRUE · L2b **FALSE**(`threw`) ·
L3 **MEASURED-EMPTY** · L4 **MEASURED-ZERO(fallback, 귀속 불가라고 크게 경고)** · BUILD COMPLETE
(step 884, closed 287/305, 1m58s) — **알려진 답과 정확히 일치**. 입력 파일의 절대경로와 mtime 을
맨 위에 찍는다(새 런을 낡은 산출물로 채점하는 사고를 막는다).

Task 3: fix round 1/5 (1 addressed, 0 open — `RewriteToolImpl` 반환 규약 예시; commit `2c5e3619`).
pytest **384 → 387 passed / 5 skipped / 0 failed**. NC6 이 세 시험을 빨갛게 하고, NC7(bare-Symbol
절만 제거)이 **하나만** 빨갛게 해 셋이 한 덩어리로 붙어 있지 않음을 증명했다. 블록 크기 불변(30,403자).

- **Ruling A8: 구현자가 호출 선호 절을 `/rewrite` 에 **안** 넣은 것을 승인한다.** 그 근거가 옳다 —
  `RewriteToolImpl` 의 docstring 은 "그 문제 하나를 고쳐라, 나머지는 바꾸지 마라" 이고, 거기에
  호출 유도를 넣으면 되먹임 한 판이 **거절이 지목하지 않은 것까지** 고치게 돼 D17 이 재려는
  "되먹임이 무엇을 고쳤나" 의 사유 히스토그램이 흐려진다. 대가: 되먹임으로 들어온 body 는
  L3 압력을 안 받는다 — 그러나 첫 시도가 이미 그 압력을 받았다.
- **Ruling A9: `_RULES` 3 의 bare-Symbol 예시 비대칭을 **park 한다**(deferred minor).**
  근거: 규약 3 이 오늘 보여 주는 예시(`(; status = :success)`)는 **유효한** 형태다. 우리가 닫는
  실패 모드는 **무효한** 형태(`NamedTuple{(:status,)}(:success)`)이고, 그것은 두 OutputField desc
  양쪽에 다 들어갔다 — 설계 §1.3 이 "모델이 실제로 읽는 자리" 로 실측한 바로 그 자리다.
  셋째 언급은 측정 가능한 이득이 없고, 대가는 **이미 사전등록된 블록 크기(30,403자/615줄)를
  또 움직이는 것**이다. 사전등록 값의 안정성이 장식적 대칭보다 무겁다.

### Task 3 리뷰 1 — **SPEC ✅ / QUALITY changes-requested**

changes-requested 는 **Task 3 이 아니라 `ladder_report.py`(계측기)에 대한 것**이다.
`b69a53b8`+`2c5e3619` 는 단독으로 승인됐다.

여섯 항목 재유도: 1 CONFIRMED(29660/606 → **30403/615**, 두 커밋의 사본을 같은 산출물에 대고
직접 호출해 재유도 ⟹ **사전등록 B4 충족, 런 2 는 무처치 런이 아니다**) · 2 CONFIRMED · 3 CONFIRMED
(BEFORE 렌더의 `prefer` 히트 **0**) · 4 CONFIRMED(선호이지 규칙 아님; **D6 감춘 다섯 재측정 0/0/0/0/0,
누출 없음**) · 5 CONFIRMED(시험 24→32, 리뷰어가 넷을 독립 재현) · 6 **부분 REFUTED**.

🔴 **리뷰어가 내 계측기에서 거짓 양성 경로를 찾았다 (I1):** `ladder_report.py` 의 L4 "모양을 못
판정하겠다" 분기가 **TRUE 로 기본값을 준다**. 실측: `world_delta_body: false` → **TRUE**,
`{}` → **TRUE**, `"unchanged"` → **TRUE**. **쟀는데 음성인 것이 사다리의 표제 칸에서 최강 양성으로
찍힌다.** 오늘은 도달 불가(`record_world_delta!` 가 4-int dict 나 `nothing` 만 쓴다)지만
`world_delta_body` 는 **HEAD 에 생산자가 아직 없어서** 모양을 못박는 것이 하나도 없다 —
그것을 처음 만드는 코드가 바로 이 분기에 떨어질 수 있다. ⟹ 수정 지시: 못 판정하면 **UNMEASURED**.
계측기의 유일하게 안전한 기본값이다.

- I3: `steps=` 부재와 `steps=[]` 가 **둘 다 UNMEASURED** — `enact.jl` 이 일부러 쓰는 구분을 지운다.
- I2: rule 5 가 가리키는 표제(`FUNCTIONS YOU CAN CALL NOW`)를 못박는 시험이 없다 —
  리뷰어가 표제를 개명하니 **32시험 전부 초록**. 두 구현자에게 각각 되돌렸다(파일 서로소).
- **Ruling A10: m1(필드금지 어휘 가드가 약하다)과 m3(`_RULES` 표제가 "hard requirements" 인데
  규칙 5 는 선호다)을 **park 한다**.** 근거: 둘 다 **스펙 위반이 아니다**(diff 는 금지를 안 더한다)
  이고, 진짜 보호는 "Julia 쪽에 거절 표면이 아예 없다" 는 것이지 어휘 가드가 아니다.
  대가: 나중에 누가 선호를 금지로 굳히면 시험이 안 잡는다. **감시 조건**: 런 2 의 body 가
  `missing_primitive` 로 후퇴하면 `_RULES` 표제를 **첫째 용의자**로 본다.
- 리뷰어가 확인 못 한 것(기록): DSPy 어댑터가 `OutputField.desc` 를 **실제 프롬프트로 렌더하는지** —
  시험은 파이썬 속성을 읽지 렌더된 프롬프트를 안 읽는다. 🔴 **런 2 에서 L2b 가 또 반환문에서 죽으면
  이것이 첫째 용의자다.**

### 리뷰어의 "확인 불가" 를 측정으로 닫았다 — **CONFIRMED**

리뷰가 "시험이 파이썬 **속성**을 읽지 렌더된 프롬프트를 안 읽는다" 를 UNVERIFIABLE 로 남겼다.
그것이 참이면 Task 3 전체가 **불활성**이고 유료 런을 그걸 알아내는 데 태운다. 오프라인으로 쟀다
(어댑터 `format()` 은 순수 문자열 작업 — 프로바이더에 안 닿는다. 유료 호출 0, 포트 접촉 0):

- `dspy==3.3.0`. 서비스는 기본 어댑터에 안 맡긴다 — `dspy_service.py:575` 가
  `dspy.configure(lm=…, adapter=build_adapter())` 로 **`ChatAdapter(use_native_function_calling=True)`** 를 건다.
- `adapter.format(sig, demos=[], inputs={…})` (설치본 `dspy/adapters/base.py:366`) 로 **실제 클래스**를
  렌더: `desc` 는 **system message** 의 `Your output fields are:` 열거에 **축약 없이 그대로** 실린다.
  `WriteToolImpl` 6번 항목 · `RewriteToolImpl` 5번 항목 둘 다에 리터럴
  `` `return (; status = :success)` `` 존재. 🔴 그리고 그 문장은
  **`NamedTuple{(:status,)}(:success)` 는 유효한 Julia 가 아니며 `MethodError: no method matching
  length(::Symbol)` 를 던진다** 고 **런 1 이 죽은 그 실수를 이름으로** 적고 있다.
- 입력 쪽 sentinel 대조: `world_interface="ZZ_SENTINEL_123"` 이 **user message** 에
  `[[ ## world_interface ## ]]` 아래 그대로 나타난다 ⟹ 큰 블록도 무변형으로 실린다.

⟹ **Task 3 의 전제가 측정으로 섰다.** 남은 미지는 "모델이 읽고 따르는가" 뿐이고 그것은 유료 런의 몫이다.

### 계측기 수정 — commit `48c9e42d` (I1·I3·m2)

I1 판별 출력(7모양, `world_delta` 부재라 fallback 이 결과를 안 가림):
`absent`·`null`·`false`·`{}`·`"unchanged"` → **전부 UNMEASURED** (각각 사유가 다르다) ·
`all-zero 4-int dict` → **MEASURED-ZERO** · `non-zero dict` → **TRUE**.
⟹ 앞의 다섯이 **하나도 TRUE 를 안 말하고**, ZERO 와 TRUE 가 구분된다.
I3 판별 출력: `steps` 부재 → UNMEASURED · `steps=[]` → **MEASURED-EMPTY** ·
`[Foo!:success]` → TRUE · `[Foo!:threw]` → FALSE.
🔴 **컨트롤러가 독립으로 재실행해 확인**(보고서를 믿지 않았다): 어제 런의 산출물에 대해
L0 TRUE / L1 TRUE / L2a TRUE / L2b FALSE / L3 MEASURED-EMPTY / L4 MEASURED-ZERO(fallback 경고 유지) /
BUILD COMPLETE 884·287/305 — **알려진 답 불변**. 수정이 아무것도 안 감췄다.

**남은 흐름:** Task 2(진행중) → 리뷰 패키지(Task 1+2) + 전체 스위트(22분, 병렬) →
두 서비스 재기동 → 대조 런 → 처치 런 → `ladder_report.py` 채점 → 데모.

Task 3: fix round 2/5 (1 addressed, 0 open — I2 표제 참조 가드; commit `f33e5592`).
pytest **387 → 388 passed / 5 skipped / 0 failed**. 검증자의 **바로 그 개명 대조**로 빨강 확인.
구현자가 방어를 **둘 다** 놨고 근거가 옳다: `_CALLABLE_HEADING` 단일 진실원(정상적 개명은 규약 5 를
같이 데려간다) **더하기** 교차검사 시험(상수를 우회해 빌더에 다른 문자열을 박는 편집 — 검증자가
실제로 한 그 편집 — 은 구조적 수정으로는 못 잡는다). 시험이 `_RULES` 에서 표제명을 **정규식으로
뽑아** 쓰므로 정당한 개명을 막지 않는다.
🔴 **리팩터가 바이트 중립임을 실측**(HEAD 모듈과 새 모듈을 나란히 로드해 렌더 비교): **30,403자 /
615줄 불변** ⟹ 사전등록 B4 값이 그대로 산다. 이번 라운드는 프롬프트 텍스트를 안 바꿨다.
구현자 규율 기록: /tmp 사본의 실패 6 중 **5는 미변경 사본에서도 빨갛다**(레포 상대경로 Julia 소스·
`out_dspy` 를 읽는 시험들)는 것을 따로 확인하고 "내 시험 하나만 개명 때문에 빨갛다" 로 좁혔다.

**Task 3: complete (commits `b69a53b8`..`f33e5592`, 리뷰 clean — SPEC ✅ / QUALITY approved;
계측기 지적 둘은 `48c9e42d` 로 별도 착륙).**

### Task 1 + Task 2 (Julia) — 착륙

Task 1: commit `fd27a777`. Task 2: commit `35edb4f2`. DONE_WITH_CONCERNS.
시험(단독 실행, 전 → 후): `minted_end_to_end` **306 → 452** · `minted_tool_enacts` 473 ·
`minted_registration` 285 · `payload_reprice_install` 23 · `test_minted_wiring` 179
— 뒤 넷 **불변**, 0 fail / 0 error. `test_minted_wiring.jl:277` 의 `occursin("threw", out)` 생존.

🔴 **구현자가 내 계측기의 결함을 잡았다 — 유료 런을 태울 뻔한 것이다.**
`ladder_report.py` 의 steps 파서가 `steps=(\[[^\]]*\])` 와 `inner.split(",")[0]` 인데,
Task 1 이 넣은 detail 은 **예외 메시지**라 `]` 와 `,` 를 흔하게 담는다
(`no method matching f(::Vector{Int64}, ::Int64)` · `BoundsError … at index [4]`).
⟹ 파싱이 잘려 **L2b 가 조용히 UNMEASURED 로 떨어진다** — 이 런이 존재하는 이유인 바로 그 칸이다.
깊이 추적 기반 구조적 파싱으로 고치라고 되돌렸다(옛 `name:status` 형식 호환 유지 필수).

**브리프 정정 셋 (구현자 실측, 리뷰가 독립 판정 중):**
 (a) Step 3(5) 의 `delta_scope=="body+harness_resolve"` 는 이 파일의 fixture 로 **도달 불가** —
     `resolve_assignments!` 가 `env.scene_tree` 위에 MILP 를 세우는데 빈 스케줄이
     `get_objective_expr` 에서 던진다. (26e)가 같은 명제를 다른 술어로 잰다.
 (b) `_world_digest` 의 weights 가드는 **시험으로 도달 불가** — `get_root_node_weights` 가
     `OperatingSchedule` 로 타입돼 있어 가짜 sched 는 weights 모양과 무관하게 `MethodError` 다.
     가드는 유지하고 (26d)가 그 사실 자체를 짝 대조로 못박았다(가드가 발화한 척 안 했다).
 (c) 인용 줄번호 **넷이 틀렸다**(`_r` 1210→1209, binding 가드 948→947, `==4` 998→999,
     testset (17) 1046/1047→1050/1051), "early return ~11개" 는 실제 **13개**.
     🔴 내 브리프가 recon 의 수를 인용했고 넷이 어긋났다 — 구현자가 실측으로 잡았다.

**구현자 우려 (리뷰가 순위를 매긴다):** `body_probe` 가 던진 경로에서도 떠지므로 거기서
`world_delta_body` 는 "던지기까지의 편집" 을 뜻하는데 그 독법이 코드에 안 적혀 있다 ·
`minted_tool_enacts` (19) 가 기준선에서 한 번 error(파이썬 서브프로세스) 후 5회 초록 — flaky 로 보이나 재유도 안 함 ·
`render_demo.jl` 의 `record_world_delta!` 호출부는 **읽어서** 확인했지 돌려서 확인 안 했다.

전체 스위트 실행 시작(22~23분 예상, 백그라운드). 리뷰 dispatch 됨(opus, 스위트와 병렬).

계측기 파서 수정: commit `deb22a93`. 8모양 전부 정확 —
(c) `MethodError … length(::Symbol)` · (d) `f(::Vector{Int64}, ::Int64)` (옛 코드가 `Int64]` 의
`]` 에서 자르던 것) · (e) `BoundsError … at index [4]` (중첩 대괄호) 셋 다 **detail 전문 보존** ·
(f) detail 안의 쉼표가 항목 분리를 안 깬다 · (g) `[]` → MEASURED-EMPTY · (h) 부재 → UNMEASURED.
어제 런 재검증 **불변**. 옛 `name:status` 형식 호환 유지.

### 🔴 전체 스위트 (Task 1+2 착륙 후) — 기준 충족

`ConstructionBots Tests | 3056 pass · 0 fail · 1 error · 3057 · 23m01.9s`.
유일한 error = `test/runtests.jl:80` **Gurobi Error 10009: No Gurobi license found** = 기대값.
⟹ 기준 **0 failed · 1 errored · 0 broken**, `passed 3056 ≥ 2910` 충족 (사전등록 A2).

### Task 1+2 리뷰 1 — **SPEC ✅ / QUALITY changes-requested**

여덟 항목: 1 CONFIRMED(13개 반환 **전부** `_r` 경유 — 비-`_r` 반환 0, 구조적으로 `body_probe` 기본값이 덮는다) ·
2 CONFIRMED(**짝 대조**: `try/catch` 를 벗기면 `probe boom` 이 함수를 탈출한다) ·
3 CONFIRMED(`copy(w)` 가 `enact.jl:990` 에 있다; **제거 변이 → (26) 87→81 pass/6 fail**.
`binding` 은 같은 위험이 **없다** — `assignment_binding` 이 매번 새 Dict 를 만든다) ·
4 코드상 CONFIRMED / 게이트 UNVERIFIABLE(→ F1) · 5 CONFIRMED · 6 CONFIRMED(199/200/250 경계 대조) ·
7 (a) CONFIRMED — 🔴 **한 런 전체의 `resolve=` 히스토그램: `not_needed_surface 14 · threw 2 · none 1`,
`resolved` 는 0** (b) CONFIRMED (c) 줄번호 넷 CONFIRMED, 단 **"~11" 은 내 브리프가 옳았다**
(11 = **body 앞** 조기반환, 13 = 전체 `_r` 자리 — 서로 다른 것을 센 것이지 정정이 아니다) ·
8 CONFIRMED **이상**: `@test` 정확히 3줄 삭제, **3줄 전부 재진술**, 더해서 새 단언 3개.

**must-fix 둘 (되돌렸다):**
- 🟠 **F2 (측정 사슬을 끊는다)**: 200자 절단이 대괄호를 가르면 `ladder_report.py` 가
  `ValueError: ']' never balances` → **L2b 가 UNMEASURED**. 이 런이 존재하는 이유인 그 칸이다.
  옛 `name:status` 에서는 구조적으로 불가능했던 것을 **Task 1 의 형식 변경이 만들었다.**
  잘린 문자열의 불균형 괄호는 **어떤 파서도 못 고친다** ⟹ Julia 쪽 렌더러가 불변식을 세워야 한다.
  수용 기준을 **실제 채점기 왕복**으로 못박았다.
- 🟠 **F1**: `world_delta_body` 를 봉투 델타로 바꿔치기해도 **452/452 초록** — 이 칸의 존재 이유를
  지키는 게이트가 **비어 있다**. 값은 오늘 옳지만(양 경로 다 `_issue_resume!`/`_resolve_if_needed!`
  **앞**임을 소스로 확인) 그 줄이 움직이는 것을 아무도 안 잡는다. L4 의 **유일한** 증거 필드다.
- **Ruling A11: F3(로그 자리 셋이 `world_delta_body` 를 안 찍는다)·F4(행도 200자 상한)를 park 한다.**
  근거: 결정 **행**은 영향 없고 L4 채점은 행에서 읽는다 ⟹ 판정이 안 바뀐다. 대가: 로그만 보는
  사람이 `:1845`(집행-던짐 경로)에서 body 델타를 못 본다.
- 🔴 리뷰가 못 잰 것(기록): `resolve === :resolved` 레짐은 이 레포의 **어떤 fixture 로도 도달 불가** ⟹
  봉투와 body 가 실제로 얼마나 갈리는지는 **유료 런에서 처음** 관측된다.

### Task 1+2 fix round 1/5 — commit `2d259f61` (F1·F2, 2파일)

`minted_end_to_end` **452 → 542** / 0 fail. 나머지 넷 불변(473·285·23·179).
- **F2**: `_step_detail_line` 이 `(`·`[` → `<`, `)`·`]` → `>` 로 중화한다(ASCII, **접기와 절단 사이**에
  적용 ⟹ 자르는 위치와 무관하게 추적 대상 괄호가 안 남는다). 1:1 치환이라 상한 경계가 행 렌더러와
  바이트 동일. **결정 행은 원문자를 유지**(JSON 이라 괄호가 아무것도 안 닫는다).
  **실제 채점기 왕복 5/5**: bounds·method·mid-cut·all-brackets·stray 전부 `L2b FALSE` + detail 표시,
  UNMEASURED 0건. 미중화 짝 대조가 리뷰어의 실패를 **정확히 재현**
  (`']' never balances` → UNMEASURED · stray 는 꼬리가 조용히 사라짐).
- **F1**: 변이(`r.body_probe` → `_world_digest(env)`)가 (28b) 를 **빨갛게** 만든다(3 pass / 2 fail).
  🔴 근본 원인 실측: 하네스가 두 지문 **사이에** 움직이는 유일한 것이 `cache.active_set` 인데
  그것이 **다이제스트 축이 아니다**(`reset_cache_resume!` → `process_schedule!` 는 시각·slack 만
  재계산) ⟹ **가벼운 fixture 로는 둘을 절대 못 가른다.** (28)은 `active_build_steps` 를
  `cache.active_set` 에 **의도적으로 별칭**해 계측 장치를 만들고, 그것이 `PlannerEnv` 에 대한
  주장이 아님을 문서화했다. 그 fixture 의 **정직성 판정을 재리뷰에 넘겼다.**

- **Ruling A12: fix round 뒤 전체 스위트를 다시 안 돌린다(23분).** 근거: 변경 표면이
  `_step_detail_line` + 시험뿐이고, enact.jl 을 건드리는 다섯 파일을 구현자가 단독 실행해 초록이며,
  직전 커밋 `35edb4f2` 에서 전체 스위트가 3056/0/1/0 이었다. 대가: 그 다섯 파일 **밖**의 회귀가
  런까지 안 보인다. **완화**: 데모를 만드는 동안 전체 스위트를 배경으로 한 번 더 돌려 확인한다.

### 런 2 — 서비스·게이트 (사전등록 체크리스트 B)

🔴 `pkill -f "…port 8077"` 이 **자기 셸을 죽였다**(셸의 명령줄이 그 패턴을 담고 있어서).
포트별 PID 조회로 바꿔 해결. 8078 은 그 사고로 **낡은 세대가 살아남아** 있었고 따로 죽였다 —
안 잡았으면 대조 런이 또 stale 게이트로 죽었을 것이다.
- 8077 (처치): `code_fingerprint e851a241a24a813f` · `synth_tool_synthesis True` · `synth_multi_agent True` · `cache False`
- 8078 (대조): 같은 fingerprint · **`synth_tool_synthesis False`** · `cache False`
- 🔴 fingerprint 가 `1697b61c53f3d2a2` → **`e851a241a24a813f`** 로 바뀌었다 = Task 3 의 파이썬이 실렸다.
- 정본 게이트 **둘 다 PASS** (`[generation] OK ok`).
- 산출물 `sha256 f5258900e04498005ae79c0599712ad3b71e394930308b85f99bfa10d4cfe94f` (어제와 동일 = 인터페이스 무드리프트).
- 프롬프트 블록 **30,403자 / 615줄** = 사전등록 B4 값 그대로.

### 🔴 음성 대조 런 (A) — 실행됨, **깨끗한 대조**

`results/run2-control.log` · 산출물 보존: `results/synth_lane_records.control-run2.jsonl` ·
`tools/monitor/streams/control-run2.jsonl`.

**대조가 유효함의 증거 (사전등록 결정 24 의 검증 조건):**
- 게이트 `[generation] OK ok (fingerprint=e851a241a24a813f)` — 현행 트리.
- 사건이 **같은 자리에서** 발화: `battery drawn at step=108 (window 40–120)` ·
  `[ood] battery fired at step≈108 closed=97` — 어제 처치런과 **step·closed 둘 다 동일**.
  ⟹ 시드 재현성 확인, **대조가 무효가 아니다**.
- 라우터도 같다: `'unknown:battery_mild' is outside the surrogate's training kinds → escalate to LLM`.
- **tool 레인이 진짜로 꺼졌다**: `tool_minted=disabled synthesis_ran=false wrote=nothing registered=false`,
  verdict=`deferred`, `[minted] NOT handled → 기본 복구 사슬로 폴백한다`.
  합성기록도 일치: `enabled: False · ran: False · wrote: None · stages: []`
  (삼상 정확 — `wrote` 가 `false` 가 아니라 `None`).

**결과: `PROJECT COMPLETE!`** (log line 283). 시뮬레이션 2:04.

🔴 **⟹ 데모의 주장이 좁아진다. 사전등록 결정 24 가 이 경우를 미리 적어 뒀다.**
"tool 이 없으면 build 가 실패한다" 는 **말할 수 없다.** 이 사건은 tool 없이도 완주한다 —
기본 복구 사슬이 받아낸다. 정직한 주장은 **"본 적 없는 사건에서 LLM 이 새 tool 을 써서
등록·집행까지 갔고, 그 동안 build 는 완주했다"** 이고, 필요성이 아니라 **기전**의 시연이다.

⚠️ **2차 결과변수는 못 쓴다**: 진행 막대의 마지막 표본이 대조 step 865/closed 283,
어제 처치 884/287 인데 이것은 **주기적 표본**이지 최종 상태가 아니고, 두 런은 **다른 코드 세대**다.
차이를 주장하지 않는다. (그리고 대조가 **더 적은 step 에서** 끝났으므로 반대 방향으로도 못 쓴다.)

- **Ruling A13: 처치 런을 재리뷰 **뒤에** 돌린다.** 근거: 사전등록의 과금 상한이 **8회**이고
  처치 런 하나가 ~5회를 쓴다 ⟹ 재런하면 상한을 넘는다. 재리뷰가 F1/F2 에서 결함을 내면
  기록 채널이 틀린 채로 재는 것이라 그 런을 버려야 하는데, 그럴 예산이 없다.
  대가: 재리뷰를 기다리는 ~10분.

### 재리뷰 (fix round 1) — **F1 ADDRESSED · F2 ADDRESSED**, 그러나 새 Critical 하나

F2: (a) 252자 detail 로 `char[200]=='['` 을 **계산해서** 만든 mid-cut fixture — 중화가 절단 **앞**임이
증명됨 · (b) 실제 채점기로 5/5 FALSE+detail, 미중화 대조 둘 다 실패 재현 · (c) **행은 원문
`at index [4]` 유지, 줄은 `at index <4>`** — 의도적 분리 실측 · (d) `p!:ok` 바이트 동일,
`test_minted_wiring` 179/0 불변 · (e) 여섯 문자 **전부 1바이트**, 줄/행 바이트 길이 5케이스 동일.
🔴 **선행 리뷰가 제안했던 `⟦`/`⟧` 였다면 이 바이트 동일성이 깨졌을 것** — 구현자의 ASCII 선택이 옳았다.

F1: (f) 재리뷰가 변이를 **독립 재현**(`active` 0→−1, 5중 2 빨강), `minted_end_to_end` **542/0** 손검산.
(g) **판정: 구성상 통과하는 가짜 게이트가 아니라 정당한 계측 시험이다** — 정수 둘(−1/0)을 단언하고
`n_weights_changed==1` 비-0 대조가 어느 축이 갈렸는지 못박으며, 갈림의 원인이 **하네스 resume 이
두 지문 사이에 있다는 명제 그 자체**다. 전제도 확인됨(생산 모양 env 에서 두 튜플이 비트 동일
`(0,0,0,0,1)`). 🔴 **단 보고서가 안 적은 맹점**: `_world_digest` 의 `active` 축을
`env.active_build_steps` → `env.cache.active_set` 로 변이해도 (28)은 **완전 초록** — fixture 가 둘을
별칭하기 때문. ⟹ **`world_delta_body` 의 출처·시점은 지키지만 `active` 축의 정체는 안 지킨다.**

🔴🔴 **새 Critical N1 — 내 계측기가 어제보다 나빠졌다.**
`enact.jl:1826` 이 항목을 **공백**으로 잇는데 `ladder_report.py::split_top_level` 은 **쉼표**로 쪼갠다.
실측: `steps=[rr_a!:success rr_b!:success]` → `FALSE, status='success rr_b!:success', n_entries=1`.
다단계 body 는 도달 가능하다(`minted_tool.jl:1340` 이 원시마다 돈다).
**`35edb4f2` 의 옛 채점기는 같은 줄에 UNMEASURED 를 냈다** ⟹ 내 `deb22a93` 이 정직한 "못 쟀다" 를
**확신에 찬 틀린 FALSE** 로 바꿨다 — 이 런이 존재하는 이유인 바로 그 칸에서. 계측기가 낼 수 있는
최악의 결함이다. 되돌렸다(깊이 0 에서 공백도 분리; Julia 렌더러는 손대지 않는다 — 어휘가 시험에 물려 있다).
🟠 **N2**: 모델이 쓴 `status` 토큰이 중화 안 됨 — `status = "moved 3 robots [east"` 가
같은 `']' never balances` 를 **라이브로** 재현한다. Julia 쪽에 되돌렸다.
- **Ruling A14: deferred #1(`ladder_report.py` 에 시험 파일이 **아예 없다**)을 승격한다.**
  근거: N1 이 정확히 그 부재의 대가다. 채점기가 사다리의 유일한 판독기인데 그것을 지키는 시험이
  하나도 없으면, 다음 결함도 유료 런에서 처음 보인다. 대가: ~10분.

계측기 N1 수정 + 시험 파일 신설: commit `e67771a1`.
`tools/monitor/test_ladder_report.py` **19 passed** (이 채점기의 **최초** 시험 — Ruling A14).
- `steps=[rr_a!:success rr_b!:success]` → **TRUE, n_entries=2** (N1 케이스 닫힘)
- `steps=[rr_a!:threw rr_b!:success]` → **FALSE, n_entries=2** (첫 스텝으로 판정)
- 어제 런 재검증 **불변**(884/287/305).
- 🔴 **대조 런 채점 = 전 칸 UNMEASURED**, FALSE 아님:
  `L0 wrote UNMEASURED('wrote' 키 부재) · L1/L2a/L2b UNMEASURED(`[minted] lane=present` 줄 없음) ·
  L3 UNMEASURED(`interface_calls` explicitly null) · L4 UNMEASURED(`world_delta_body` explicitly null) ·
  BUILD PROJECT COMPLETE! 865/283/305`.
  ⟹ **tool 을 안 주조한 런의 사다리는 "거짓" 이 아니라 "못 쟀다" 로 읽힌다.** 삼상이 대조에서도 산다.

## 🔴🔴 처치 런 (B) — 유료, 사전등록된 본 결과 (2026-09-04 21:09)

산출물: `results/run2-treatment.log` · `results/synth_lane_records.treatment-run2.jsonl` ·
`tools/monitor/streams/treatment-run2.jsonl`. 채점: `ladder_report.py` (기계 판독, 손인용 없음).

사건은 대조와 **같은 자리**: `battery drawn at step=108` · `[ood] battery fired at step≈108 closed=97` ·
같은 라우터 escalate. `tool=TaskReallocationTool` · `surface=sched` · `expressible=False` ·
`stages=['observe','design','compose']`.

| 칸 | 판정 | 증거 |
|---|---|---|
| **L0** wrote | ✅ TRUE | 기록의 `wrote=True` |
| **L1** registered | ✅ TRUE | `registered=true impl_rejected_why=n/a` |
| **L2a** 인자 채널 | ✅ TRUE | `args_from=calls n_calls=1` |
| **L2b** 무예외 | ❌ **FALSE** | `steps=[TaskReallocationTool!:threw(KeyError: key "R1" not found)]` |
| **L3** 인터페이스 호출 | 🔴 **✅ TRUE — 사상 처음** | `interface_calls=['battery_report']` |
| **L4** 세계 변화 | **MEASURED-ZERO** | `world_delta_body` (**fallback=False**), 다섯 축 전부 0, `body_scope=body_only(probed)` |
| BUILD | ✅ **PROJECT COMPLETE!** | 865/283/305, sim 1:50 |

### 세 태스크가 전부 라이브에서 발화했다

1. **Task 1 ✅** — `:threw` 가 이제 **이유를 나른다**: `KeyError: key "R1" not found`.
   어제는 격리 프로브로 사후 재유도해야 했다. **인계 항목 1 이 닫혔다** — 추론이 아니라 직접 관측.
2. **Task 2 ✅** — `world_delta_body` 가 **fallback 없이** 읽혔고 `body_scope=body_only(probed)`.
   어제는 `delta_scope=body+harness_resolve` 하나 때문에 L4 가 귀속 불가였다.
   오늘은 `resolve=resolved` 인데도 **body 만의 창이 따로 있다**. **인계 항목 3 이 닫혔다.**
3. **Task 3 ✅✅** — 두 가지가 다 먹혔다:
   - 반환 규약: body 가 **`return (; status = :success)`** 를 썼다. 런 1 을 죽인
     `NamedTuple{(:status,)}(:success)` 가 **재발하지 않았다.**
   - 호출 선호: **`battery_report()` 를 실제로 불렀고**, 게다가 ambient 블록이 지시한 대로
     `if ConstructionBots.BATTERY_FLEET[] === nothing; return :no_battery_info` 로
     **전제조건까지 가드했다**(R17 이 걱정한 바로 그 자리).

### 🔴 새 실패 모드 — 식별자 **형식**의 환각

body: `function TaskReallocationTool!(env; robot_id="R1", ...)` → `soc[robot_id]` → KeyError.
`battery_report()` 의 `soc::Dict{Any, Float64}` 는 **로봇 ID 객체**(BotID)로 키가 잡히는데,
인터페이스가 `Any` 라고만 광고해서 모델이 **표시명 문자열 "R1"** 을 지어냈다.
어제의 환각은 **필드 이름**이었고 오늘의 환각은 **키 타입**이다 — 한 겹 더 안쪽으로 옮겨갔다.

⚠️ **그리고 body 의 재배정 로직은 전부 주석 처리된 placeholder 다**
(`# Example: update_task_allocation!(env.sched, task_id, new_robot_id)`).
⟹ **L4 의 0 은 두 번 참이다**: 던져서 못 갔고, 갔어도 no-op 이었다.
`expressible=False` 인데 재배정 원시가 광고에 없으니 모델이 스텁을 썼다.

### 사전등록 결정 27 의 적용 — **격하하지 않는다**

결정 27 은 "L3 이 배터리 계열 함수로 초록인데 L4 가 0 이면 L4 를 `nothing` 으로 격하" 를 적었다.
그러나 불린 것은 **`battery_report` 이고 그것은 읽기 함수다** — 세계를 바꿀 수가 없다.
결정 27 이 지목한 것은 `swap_battery!`·`dispatch_battery_courier!` 같은 **변경자**였다.
⟹ **계측기가 못 덮는 축의 문제가 아니므로 격하 사유가 없다.**
L4 = **MEASURED-ZERO 를 액면 그대로** 읽는다: 쟀고, 세계는 안 바뀌었다.

### 데모가 말할 수 있는 것 / 없는 것

- ✅ 말할 수 있다: 학습 분포 **밖**의 사건에서 multi-agent LLM 이 새 Julia tool 을 **썼고**,
  규약 검사를 통과해 **돌아가는 모듈에 등록됐고**, 인자를 받아 **집행됐고**,
  **광고된 세계 함수를 실제로 호출했고**(L3 최초), 그 동안 **build 는 완주했다**.
- ❌ 말할 수 없다: "tool 이 build 를 구했다" — 대조도 완주한다.
- ❌ 말할 수 없다: "tool 이 세계를 고쳤다" — L4 는 쟀고 **0** 이다. body 는 던졌고 로직은 스텁이었다.

### L2b 후속 (post-hoc, 사전등록 밖) — commit `f5eb329a`

**본 결과를 원장에 적은 뒤** 착수했다 ⟹ 결과를 보고 조건을 바꾼 것이 아니다. 그러나 이 런은
**사전등록된 런이 아니라 둘째 조건**이고, 보고할 때 그렇게 표시한다.

🔴 **구현자가 내 지시의 전제를 정정했다 — 산출물 경로는 애초에 불가능했다.**
`AMBIENT_ROOTS` 가 손으로 쓰는 것은 `name`·`accessor`·`precondition` 뿐이고 **`returns` 는
기계 유도**다(`_returns_string` 이 `Base.return_types` 를 읽어 `fieldnames`/`fieldtypes` 로 조립).
`soc::Dict{Any, Float64}` 는 **Julia 가 추론한 타입**이지 누가 쓴 텍스트가 아니다 ⟹ `Any` 를
좁히려면 `battery_report` 의 **반환 타입 자체**를 바꿔야 하고 그건 동역학 세대 파장이 있는
Julia 생산 변경이다. 파이썬 전용 경로가 **차선이 아니라 유일한 경로**였다.
- 규칙 6 을 `_RULES` 에 **일반 규칙으로** 넣었다(구현자 판단, 논거 수용): 두 런 연속 식별자
  환각이고(런1 필드명 · 런2 키 타입), WORLD TYPES 에 `Dict{AbstractID,…}` 필드가 **일곱** 있어
  같은 실수가 이미 복수 표면에 열려 있다. `_RULES` 는 모델이 쓰기 **전에** 읽는 자리이고
  ambient 줄은 18k자 안쪽이다.
- 블록 **30,403 → 30,747자 / 615 → 620줄**(+1.1%). pytest **388 → 390 / 0 fail**. 음성 대조 빨강 확인.
- 렌더 실측: `6. Identifiers in this world are OBJECTS, never strings. There is no "R1"-style
  display name anywhere: get an id out of env (e.g. keys(env.agent_policies)) …`
- 🔴 **구현자가 되돌린 미해결 항목**: `Any` 는 여전히 `Any` 다. 규칙 6 은 **산문으로** 갚을 뿐
  기계가 키 타입을 광고하게 만들지 않는다. 진짜 수리는 `battery_report` 의 반환 타입을 좁히는 것.

- **Ruling A15: 사전등록의 과금 상한 8 을 12 로 올리고 셋째 런을 돌린다.**
  경과: 대조 ~1 + 처치 ~4 = **5회**. 셋째 런이 ~4회 → 9회로 **상한을 넘는다.**
  근거: 그 상한의 목적은 **지출 통제**이지 측정 무결성이 아니다(무결성은 사전등록의 술어들이
  지킨다). 이 런은 실측된 가설 하나(식별자 규칙이 KeyError 를 닫는가)를 시험하고,
  사용자의 명시 목표가 이 세션 안에서 L2b 를 닫는 것이다.
  🔴 **조용히 넘지 않고 규칙으로 올린다** — 상한을 넘는 것과 상한이 없는 것은 다르다.
  대가: 유료 호출 ~4회. 이 런은 **사전등록 밖**이므로 본 결과를 대체하지 않고 **덧붙는다.**

## 런 3 (post-hoc 둘째 조건, 사전등록 밖) — 2026-09-04 21:23

서비스 `code_fingerprint ed59a10c70b4b051`(규칙 6 실림), 게이트 PASS. 산출물:
`results/run3-treatment.log` · `results/synth_lane_records.run3.jsonl` · `tools/monitor/streams/run3.jsonl`.

| 칸 | 런 2 (사전등록) | 런 3 (post-hoc) |
|---|---|---|
| L0 wrote | ✅ | ✅ |
| L1 registered | ✅ | 🔴 **FALSE** `reject:impl_keyword_needs_a_default:affected_robot` |
| L2a/L2b/L3/L4 | ✅/❌/✅/ZERO | **UNMEASURED** (L1 미달로 도달 못 함) |
| BUILD | COMPLETE | COMPLETE |

### 규칙 6 은 겨눈 것을 맞혔다 — 그리고 다른 것을 깼다

body 는 `"R1"` 류 문자열을 **하나도 안 썼다**. `keys(agent_policies)` 로 id 를 찾고
(`findfirst(x -> x == affected_robot, keys(agent_policies))`), 반환도 우리가 가르친 두 형태 중
하나(`return :success`)를 썼다. **식별자 환각은 사라졌다.**
그런데 시그니처가 `function TaskReallocationTool!(env; affected_robot, affected_tasks, alternative_robots)`
— **기본값 없는 키워드 인자 셋**이라 규약 검사에 걸렸다.
⟹ 🔴 **후속 수정이 한 실패를 다른 실패로 바꿨다.** 사다리 기준으로 런 3 은 런 2 보다 **낮다**.
프롬프트에 규칙을 더할 때마다 모델이 다른 규약을 어기는 자리로 옮겨간다는 것을 보여 준다.

### 🔴 새 차단 항목 — 자기수정 채널이 라이브에서 죽었고, 이유를 안 남긴다

```
[minted] rewrite: 왕복 실패 (원래 거절이 그대로 남는다): HTTP.RequestError:
```
D17 의 `/rewrite` 되먹임은 **정확히 이 상황**(등록 거절)을 위해 있고, 살아 있었다면 모델이
기본값 누락을 스스로 고칠 기회를 얻었다. 실측:
- 서비스 로그에 **`/rewrite` 요청이 한 번도 안 도착했다**(`/decide` 200 만 있다) ⟹ 클라이언트 쪽 실패.
- 라우트는 존재하고 살아 있다: `POST /rewrite` 빈 바디 → **http=200, 2.6s** (LLM 호출 없이).
- 클라이언트 설정은 넉넉하다: `readtimeout = 120, retries = 0` (`enact.jl:1361`).
- 🔴 **그리고 사유를 못 읽는다** — `HTTP.RequestError:` 뒤가 **비어 있다**. 우리가 방금 `steps`
  에 대해 닫은 것과 **똑같은 종류의 구멍**이 rewrite 실패 경로에 그대로 남아 있다.

- **Ruling A16: 여기서 런을 멈춘다.** 유료 ~9회(상한 12). 넷째 런은 rewrite 실패의 원인을
  모른 채 도는 것이라 같은 자리에 떨어질 가능성이 높다. 원인이 관측되지 않는 상태에서 런을 더
  태우는 것은 이 레포가 반복해 밟은 "추론으로 말하기" 자리다.
  ⟹ **런 2 를 본 결과로 두고, 런 3 을 둘째 조건으로 나란히 보고한다.**

### 🔴 전체 스위트 최종 (모든 수정 착륙 후)

`ConstructionBots Tests | 3180 pass · 0 fail · 1 error · 3181 · 24m32.8s`.
유일한 error = `test/runtests.jl:80` Gurobi 10009 (라이선스 없음) = 기대값.
⟹ 기준 **0 failed · 1 errored · 0 broken** 충족. 경과: 2910(세션 시작) → 3056 → **3180**.
Ruling A12 의 완화 조건(데모 중 배경 재실행)을 이행했고 **회귀 없음**을 확인했다.

## 실측: `soc` 키 타입의 출처 (사용자 질문에 답하며 잰 것)

```
src/navigator/battery.jl:104
    soc::Dict{Any,Float64}   # RobotID -> state of charge in [0,1]   # 로봇별 잔량
```
🔴 **주석은 `RobotID` 라고 말하는데 타입 선언은 `Any` 라고 말한다.** 그리고 인터페이스의
`returns` 는 `_returns_string` 이 `Base.return_types` 로 **기계 유도**한다
(`battery_report` 는 `soc = copy(fleet.soc)` 를 돌려준다).
⟹ 모델에게 `Dict{Any, Float64}` 라고 말한 것은 **우리가 이미 갖고 있던 정보를 타입 선언에서
버렸기 때문**이다. 모델은 `Any` 를 보고 가장 그럴듯한 것(표시명 문자열 `"R1"`)을 지어냈다.
**옳은 수리는 `Dict{AbstractID,Float64}` 로 좁히는 것** — 그러면 생성기가 스스로 올바른 키
타입을 광고하고 산문 규칙이 필요 없어진다. 반대 방향(`"R1"` 을 유효 키로 만들기)은 하나의
환각에 맞춰 세계를 고치는 것이라 안 된다.
⚠️ 미착수. `BatteryFleet` 소비처 감사가 붙는다(`fleet.soc[id]` 쓰기 자리 `:158·163·361-364`,
읽기 `:442·453·587`).

## 🛑 인계 — 다음 세션이 이어받을 것 (우선순위 순)

1. 🔴 **`/rewrite` 자기수정 채널이 라이브에서 죽고 사유를 안 남긴다.**
   `HTTP.RequestError:` 뒤가 비었다. 서비스에 요청이 **안 도착**했고 라우트는 살아 있다
   (빈 POST → 200, 2.6s), `readtimeout=120`(`enact.jl:1361`). 런 3 의 기본값 누락은 **바로 이
   채널이 고쳤어야 할 종류**다. 우리가 `steps` 에 대해 닫은 구멍이 한 층 위에 그대로 있다.
   **이걸 먼저 닫아야 다음 런이 원인을 관측으로 말한다.**
2. `soc::Dict{Any,Float64}` → `Dict{AbstractID,Float64}` (위 절). 기계가 진실을 말하게 한다.
3. 🔴 **설계 결정이 남아 있다: 재배정 원시를 광고할 것인가.** 런 2 body 의 재배정 로직이
   **전부 주석 처리된 placeholder** 였다(`# Example: update_task_allocation!(...)`).
   D6 가 다섯 능력을 감췄고 재배정 원시가 광고에 없으니 모델은 `expressible=False` 에서
   스텁을 쓴다. **L4 를 0 밖으로 내보내려면 이 결정을 먼저 해야 한다** — 키 형식 문제가 아니다.
4. 🔴 **"규칙 하나 더" 를 기본 처방으로 삼지 말 것** (런 3 이 실증). 환각은 층을 옮긴다:
   런1 필드명 → 런2 키 타입 → 런3 규약 위반.
5. deferred/parked: F3(로그 자리 셋이 `world_delta_body` 미표시) · F4(행 200자 상한) ·
   m1(필드금지 어휘 가드 약함) · m3(`_RULES` 표제가 "hard requirements" 인데 규칙 5 는 선호) ·
   (28) fixture 의 `active` 축 별칭 맹점 · `ladder_report.py` 의 `steps=` 위치를 첫 `find` 로 잡는 것.
6. 🔴 **원장은 gitignore 안이라 `git clean -fdx` 로 날아간다.** 핵심은 기억에 남겼다
   ([[ladder-l3-green-and-rules-move-the-failure]] · [[generation-gate-blocks-every-run-not-just-synthesis]]).

**데모 (발행됨):** https://claude.ai/code/artifact/0b53b9d3-d503-4320-bd69-678164659909
