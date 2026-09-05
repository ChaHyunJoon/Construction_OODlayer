# 계획: L4 를 도달 가능하게 만들고, 데모에 필요성을 준다

작성 2026-09-04. BASE `58e7a0f4`.
근거 문서: `docs/superpowers/reports/2026-09-04-tool-synthesis-workflow-state-and-next-steps.md`
설계 정본(사다리): `docs/superpowers/specs/2026-09-03-callable-world-interface-design.md` §0
recon 실측: `.superpowers/recon-2026-09-04.md`

## 0. 사용자 결정 (에이전트가 뒤집지 않는다)

| # | 결정 | 근거 |
|---|---|---|
| **S3 = B** | 사건의 대상 로봇 id 를 `env` 에 실어 광고한다 | "`PlannerEnv` 에 사건 특정 필드가 생긴다고 해서 state 의 definition 이 오염되는 건 아니다" |
| **S4 = 광고한다** | 재배정 동사를 광고 목록에 넣는다. L4 는 **유지**한다 | L4 를 지우면 "tool 이 세계를 바꿨다" 를 볼 눈이 사라질 뿐 사실은 안 바뀐다. 그리고 P6 목표가 L4 보다 강하다 |
| **P6 = 필요성을 보인다** | 실험 대상은 surrogate 가 배운 적 없는 **mild battery depletion** 이다. 새 tool 이 build 를 **incomplete → complete** 으로 되돌리는지를 본다. tool 은 **payload 와 SoC 를 함께 보고 에너지를 아끼는 재배정**이어야 하고, 그 추론은 multi-agent 가 해야 한다 | 사용자 지시 |
| **과금 상한** | 없다 | 사용자 지시 |

🔴 **S4 가 광고하는 것은 "능력" 이지 "답" 이 아니다.** 어느 로봇의 어느 작업을 누구에게
넘길지, payload×SoC 교환비가 무엇인지는 어휘 어디에도 없다 — 그 전부가 모델의 추론 부담이다.
감춘 나머지 넷(`recover_stalled_teams!` · `resolve_schedule_wedge!` ·
`force_advance_stuck_carrier!` · `forbid_heavy_cargo!`)은 **그대로 감춘다** ⟹ 조합 능력 축과
발명 능력 축이 분리된다.

## 1. Global Constraints — 모든 태스크가 지킨다

1. 🔴 **코드를 가리킬 때 함수·testset 이름으로 적는다. 줄번호 금지.** 이 레포에서 줄번호는
   조용히 낡고, 과거 세션이 낡은 줄번호를 인용해 도달 불가능한 경로를 사실처럼 보고했다.
2. 🔴 **삼상 규약**: `nothing` = 못 쟀다 · `false` = 쟀는데 거짓 · `[]`/`0` = 쟀는데 비었다.
   이 셋을 뭉개는 코드는 결함이다.
3. 🔴 **게이트를 고칠 때는 변이를 심어 빨개지는지 본다.** "이 시험이 X 를 지킨다" 는 증거가 아니다.
   음성 대조 없는 초록은 보고하지 않는다.
4. 🔴 **`git add -A` / `git add .` / `git commit -a` 금지.** 작업 트리에 219개 삭제가 미커밋이다.
   반드시 명시 경로로 `git add`.
5. 🔴 **`src/respec/llm_service/` 를 건드리면 세대 지문이 바뀐다** — 시험 파일도 포함이다
   (게이트가 트리 전체를 해시한다). 라이브 런은 파이썬 편집이 **전부 착륙한 뒤** 서비스를
   재기동하고 한 창에서 몰아 돌린다.
6. 🔴 **`pkill -f "…port 8077"` 금지** — 셸 자신의 명령줄이 그 패턴을 담아 자기를 죽인다.
   포트별 PID 조회로 죽인다.
7. 회귀 기준선은 **네가 지금 잰 값**이다. 문서의 수를 인용하지 말고 재유도한다.
8. 배경 작업을 `sleep` 으로 폴링하지 않는다 — 끝나면 알림이 온다.

## 2. 이 계획이 정정하는 인계 문서의 오류

🔴 **S1 의 진단이 틀렸다 — 실측으로 반증했다.**
인계 문서는 "`_rewrite_once` 의 `catch` 가 예외 메시지를 **버린다**" 고 적었다. 버리지 않는다.
`tools/monitor/enact.jl` 의 `_rewrite_once` `catch` 는
`first(split(sprint(showerror, e), "\n"))` 를 찍는다 — **메시지를 첫 줄로 자르는 것**이 사유를
먹는다. 실측(2026-09-04):

```
HTTP.RequestError 의 showerror 8줄:
  1: "HTTP.RequestError:"          ← 현재 코드가 찍는 전부
  2..6: HTTP.Request 덤프
  7: "Underlying error:"
  8: "boom: the real cause"        ← 진짜 사유
대조: HTTP.ConnectError 는 첫 줄이 이미 정보를 나른다(그래서 이 결함이 안 보였다)
```

⟹ 고칠 자리는 `catch` 의 존재가 아니라 **절단 방식**이다: `steps[i].detail` 에 이미 쓰는
`_one_line_rec`(모든 공백을 한 칸으로 접는다 — 줄바꿈 포함) + `_cap_detail` 로 갈아탄다.

## 3. 태스크

---

### Task 1 — `/rewrite` 실패가 사유를 나른다 (S1, P2)

**무엇**: `tools/monitor/enact.jl` 의 `_rewrite_once` `catch` 절이 예외를 첫 줄로 자르지 않고
전문을 한 줄로 접어 상한 안에서 찍게 한다.

- 현재: `first(split(sprint(showerror, e), "\n"))`
- 목표: 이 파일이 `steps[i].detail` 에 이미 쓰는 경로와 **같은 것**을 쓴다 —
  `_cap_detail(_one_line_rec(sprint(showerror, e)))`.
  🔴 `_neutralize_brackets` 를 쓸지 말지를 **판정하고 근거를 적어라**: 이 줄은 결정 **행**이
  아니라 기록 줄이므로 `ladder_report.py` 의 파서를 지나가지 않을 수 있다. 지나간다면 중화한다.
- 스택트레이스가 상한을 다 먹으면 사유가 다시 안 보인다. `showerror` 출력에서 `Stacktrace:`
  **이후를 버리는지** 판정하고 근거를 적어라(`ConnectError` 는 2줄째부터 스택이다).

**시험** (`test/minted_end_to_end.jl` 또는 새 파일):
1. `HTTP.RequestError(HTTP.Request("POST","/rewrite"), ErrorException("SENTINEL_CAUSE"))` 를
   만들어 로깅 경로를 태우고, 찍힌 줄에 `"SENTINEL_CAUSE"` 가 **있음**을 단언한다.
2. 🔴 **음성 대조**: 소스에서 그 표현을 옛 `first(split(...))` 로 되돌리는 문자열 치환을 하고
   같은 단언이 **빨개지는지** 확인한다(이 파일의 `_one_line_rec` 게이트가 쓰는 것과 같은 수법 —
   `@test occursin(...)` + `replace(src, ... => ..., count = 1)`).

**그 다음 — 원인 진단 (무료 경로만)**:
- 🔴 `/rewrite` 는 유료다. 진단은 **빈 POST(`{}`)** 로 한다 — 200 을 내고 LLM 을 안 부른다.
- 라우트가 살아 있고(빈 POST 200/2.6s), 서비스 로그에 `/rewrite` 요청이 **한 번도 안 도착했다**
  ⟹ 클라이언트 쪽 실패다. 위 수정이 착륙하면 다음 런에서 사유가 로그에 뜬다.
- 이 태스크는 **사유가 뜨게 만드는 것까지**다. 원인 자체는 사유를 보고 나서 고친다.

**완료 판정**: 시험 초록 + 음성 대조 빨강 확인 + 커밋.

---

### Task 2 — 재배정 동사를 광고한다 (S4)

**무엇**: `release_pending_assignments!` 를 광고 목록에 넣는다. 나머지 넷은 그대로 감춘다.

🔴 **recon 실측이 이 태스크를 싸게 만든다 — 배선은 이미 다 있다:**
- 광고 규칙은 `names(CB)`(exported only)다. 별도 allowlist 가 없다 ⟹ **`export` 한 줄이 곧 광고**.
- `release_pending_assignments!` 는 **이미 집행 가능한 minted 원시 여덟 중 하나**다:
  `src/respec/minted_tool.jl` 의 `WORLD_UNCHANGED_STATUSES`(`:unknown_agent`·`:both_scopes`) ·
  `EDGELIST_RETURN_PRIMITIVES` · `PRIMITIVE_RESUMES_CACHE`(**false**) 행이 전부 있다.
  집행부·상태 판독·재개 판정이 전부 준비돼 있고 **모델에게 안 보일 뿐**이다.
- 🔴 **2026-09-03 (D8) 이후 파이썬 쪽에 primitive inventory 는 없다.** `synthesize.py` 가
  `class SynthesizeTool` 과 함께 지웠다 — agent-3 은 **world interface 블록만** 보고 조합한다.
  ⟹ 광고 말고 다른 채널이 없다.

**시그니처가 태스크의 진짜 내용이다** [실측]:
```julia
release_pending_assignments!(env, invariant::InvariantSpec;
                             faulted = nothing,
                             agent::Union{Nothing,AbstractString} = nothing)
```
- 🔴 위치인자가 **둘**인데 주조 body 의 규약 1 은 위치인자 ≡ `env` 하나다.
  ⟹ body 는 `invariant` 를 스스로 만들어야 하고, 그 함수 `build_invariant(env)` 는
  **이미 광고돼 있다**. **이것이 조합 부담의 핵심이고, 일부러 남긴다.**
- `agent` 는 **String** 이고 정준 집합은 `_schedule_agent_ids(env.sched)` 다. 짧은 형태
  `"BotID{DeliveryBot}(4)"` 는 `:unknown_agent` 로 떨어진다 ⟹ **S3(Task 3)이 정확히 이 구멍을 메운다.**
- `faulted` 는 넓히고 `agent` 는 좁힌다. 둘 다 주면 `:both_scopes` 로 조용히 거절된다.
- 🔴 이 원시는 **재풀이를 안 한다**(자기 docstring 이 선언). 하네스의
  `_resolve_if_needed!` 가 `surface ∈ {"sched","milp"}` 일 때 `resolve_assignments!` 를 부른다.
  ⟹ 모델이 `surface="sched"` 를 골라야 재풀이가 돈다. 런 2 가 실제로 그렇게 골랐다.
- ⚠️ **좁힌 release 는 수렴하고 전체 release 는 안 한다** [실측]: 전체는 어느 시점에도 60s 안에
  최적성을 증명 못 하고, 대상 하나로 좁히면 후보가 ~1/19 로 줄어 0.2s 에 `OPTIMAL`.
  ⟹ 모델이 `agent=` 로 좁히지 않으면 런이 시간 제한에 걸린다. 프롬프트가 그것을 아는가를 판정하라.

**바꿀 것**:
1. `src/ConstructionBots.jl` 의 export 블록에 `release_pending_assignments!` 추가.
2. `tools/gen_world_interface.jl` 로 `wm4spacecraft_manufacturing/core/world_interface.json` 재생성.
   바이트 게이트가 산출물==생성기를 지키므로 재생성 없이는 시험이 빨개진다.
3. **네 게이트를 갱신한다** — 다섯을 넷으로 줄이고, 🔴 **새로 광고된 것에 양성 단언을 더한다**
   (감춤 게이트가 빈 통과가 되지 않게):
   - `test/world_interface_current.jl` testset `"(4) 🔴 비공개 impl 은 실리지 않는다 (설계 D6)"`
   - `src/respec/llm_service/test_world_interface_block.py`
   - `src/respec/llm_service/test_world_interface_render.py`
   - `src/respec/llm_service/test_synthesize_multi.py` 의 `_WITHHELD_FIVE`
   각 자리의 **머리말/이름도 갱신한다** — "다섯" 이라고 적힌 산문이 넷이 되면 거짓말이 된다.
4. 🔴 **`check_impl_conventions` 규약 5 의 `impl_name_exists_shown` / `impl_name_exists_withheld`
   갈래를 재판정하라.** 이제 이 이름은 withheld 가 아니라 shown 이다. 두 사유를 가르는 판정이
   산출물을 읽는다면 자동으로 따라오고, 하드코딩 목록이라면 고쳐야 한다. **어느 쪽인지 실측하라.**
5. 렌더 실측: 프롬프트 블록에 이 메서드가 **실제로** 나타나는지, 어느 제목
   (`FUNCTIONS YOU CAN CALL NOW` vs `…CANNOT OBTAIN YET`) 아래인지 확인하고 그 문자열을 보고에 적어라.
   🔴 `invariant::InvariantSpec` 인자 때문에 `callable=false` 로 분류되면 모델이 "지금은 못 부른다"
   로 읽는다 — 그러면 이 태스크는 **무동작이다**. 반드시 확인하라.

**완료 판정**: `julia +lts --project=. -e 'using Pkg; Pkg.test()'` 의 회귀 기준선을 **직접 재고**
(이전 값 인용 금지), pytest 를 돌리고, 렌더 실측 문자열을 보고에 적는다.

---

### Task 3 — 사건 대상 id 를 env 에 실어 광고한다 (S3 = B)

**무엇**: OOD 사건이 지목한 로봇을 모델이 **직접** 얻는 채널을 만든다.

**왜 이 형태인가** [실측]:
- `resolve_agent_id`(`src/respec/llm_bridge.jl`)는 export 되지 않아 산출물에 없고,
  그것은 **매크로/결정 레인의 채널**이지 주조 body 의 채널이 아니다.
- 🔴 **id 객체는 인자 채널을 물리적으로 못 건넌다**: `bind_primitive_args` 가
  `PARAM_JSON_TYPES` 의 JSON 타이핑 아래 `ctx.params` 로 키워드를 만든다.
  ⟹ body **안에서** 푸는 것이 편의가 아니라 **유일한 경로**다.
- 런 2 는 `soc["R1"]` 로 죽었다 — 타입도 문자열 형식도 둘 다 틀렸다.

**설계**:
1. `PlannerEnv` 에 사건 대상 필드를 더한다(사용자 결정 B). 이름·타입·기본값을 정하고 근거를 적어라.
   🔴 **기본값은 `nothing` 이어야 한다** — "사건이 없다" 와 "사건이 있는데 대상을 모른다" 를
   가르지 못하면 삼상 규약 위반이다.
2. 그 필드를 쓰는 **exported 접근자**를 만든다. 🔴 **반환 형식이 이 태스크의 전부다**:
   `release_pending_assignments!` 의 `agent` 는 `_schedule_agent_ids(env.sched)` 의 원소와
   **문자열로 같아야** 한다. 접근자가 그 정준 문자열을 내는지 **실측으로 확인하라** —
   짧은 형태 `"BotID{DeliveryBot}(4)"` 는 `:unknown_agent` 로 떨어진다.
3. OOD 주입부(`src/respec/ood_injection.jl`)가 사건을 낼 때 그 필드를 채운다. 사건이 끝나면
   치우는지 여부를 판정하고 근거를 적어라(안 치우면 다음 사건이 낡은 대상을 본다).
4. `AMBIENT_ROOTS` 항목을 더해 ambient 블록에 실린다면 그렇게 한다 —
   🔴 `returns` 는 손으로 쓰는 게 아니라 `Base.return_types` 로 **기계 유도**된다.
   타입 선언을 좁히면 광고가 저절로 정확해진다. `Any` 를 내지 않는 타입을 선언하라.

**시험**: 접근자가 낸 문자열을 `release_pending_assignments!` 에 그대로 먹여
`:unknown_agent` 가 **아닌** 것을 단언한다(= 두 레인의 접지가 같은 세계임을 기계로 못박는다).
🔴 음성 대조: 짧은 형태를 먹이면 `:unknown_agent` 가 나오는 것도 같이 단언한다.

---

### Task 4 — 계측기의 남은 구멍 (S6, P5)

각각 독립적이고 값이 싸다. **한 배치로 묶어 한 명에게 준다.**

1. 🔴 **`world_delta_body` fixture 의 `active` 축 별칭 맹점** — fixture 가
   `active_build_steps` 를 `cache.active_set` 에 **별칭**해서, `_world_digest` 의 `active` 축을
   다른 것으로 바꿔도 시험이 초록으로 남는다. 그 시험은 `world_delta_body` 의 **출처·시점**은
   지키지만 **`active` 축의 정체**는 안 지킨다. **별칭을 끊고 변이로 빨개지는지 확인하라.**
2. `_world_delta_str` 의 네 로그 자리 중 셋이 `world_delta_body`/`body_scope` 를 안 찍는다.
   (결정 **행**은 영향 없으므로 채점은 안 바뀐다 — 그래도 로그가 거짓말을 하지 않게 한다.)
3. `ladder_report.py` 가 `steps=` 를 첫 `str.find` 로 찾는다 — 앞 필드에 그 리터럴이 들어가면
   오작동. 구조적으로 찾게 고치고 회귀 시험을 더한다.
4. 결정 행의 `detail` 200자 상한 — 긴 예외가 **두 채널 모두에서** 복구 불가다.
   Task 1 과 같은 종류의 결함이다. 상한을 재판정하라(늘릴지, 두 채널의 상한을 다르게 할지).

🔴 **넷 다 변이를 심어 빨개지는지 확인한 것만 완료로 친다.**

---

### Task 5 — 필요성 지표: 완주가 아니라 에너지·마모 (P6, **개정**)

🔴 **2026-09-04 사용자 결정으로 이 태스크가 갈렸다.** 원래 계획은 "기본 복구 사슬이 못 받는
사건을 고른다" 였다. recon 이 그 길이 막혀 있다고 보고했고(검증 중), 사용자가
**"mild 는 유지하고 지표를 바꾼다"** 를 골랐다.

**왜 원래 길이 막혔나** [코드 읽기, 독립 검증 중 — `.superpowers/validation-p6.md`]:
- `mild` 의 정의는 `soc_after > REPLACE_SOC_THRESHOLD = 0.1` 이고 물리적 정지 문턱은
  `STALL_SOC_DEFAULT = 0.05` 다 ⟹ **mild 로봇은 한 번도 실제로 멈추지 않는다.**
- 메뉴가 NOOP 으로 제한되는데 그 NOOP 이 무해한 이유가 바로 그것이다 — 고장난 게 없다.
- ⟹ 대조가 완주한 것은 "복구 사슬이 잘 받았다" 가 아니라 **"복구할 일이 없었다"** 다.
  없는 손상은 고칠 수 없으므로 완주 여부로는 필요성을 영원히 못 보인다.
- 이것은 레포가 이미 적어 둔 것과 일치한다: **"payload 재가격은 wear-leveling 이지 완주
  판정이 아니다 — 근거는 '못 끝낸다'가 아니라 '미래 SwapBattery 확률'"**.

**무엇**: 사건은 mild battery depletion 그대로 두고, **처치 vs 대조를 가르는 지표**를
완주 여부가 아니라 **에너지·마모**로 정의하고 **런 전에 못박는다.**

**할 일**:
1. **후보 지표를 열거하고 각각 측정 가능성을 실측하라.** 최소한 이 넷:
   - 함대 에너지 총량(로봇당 `usage_s` 합 또는 drain 적분) — 어디서 읽나?
   - 사건 이후 `SwapBattery` 배송 발생 수 (`env.BATTERY_DELIVERIES[]`)
   - 종료 시점 함대 최소 SoC / SoC 분포의 하위 꼬리
   - makespan (step 수)
   그리고 사용자가 지목한 **payload×SoC 결합량**: 낮은 SoC 로봇에 배정된 payload 가중 작업량.
   🔴 **`payload 는 질량이 아니라 bbox 부피**이고 1대당 부담은 `m_payload/팀크기` 라
   순서가 7.5% 어긋난다 — 지표 정의에 이것을 반영하라(auto-memory).
2. 🔴 **각 후보가 산출물에 실제로 남는지 실측하라.** 안 남으면 계측을 더하는 것이 이 태스크의
   일부다. `_world_digest` 는 배터리·배송을 **한 축도 안 덮는다**(recon 실측) — L4 축과
   결과 지표는 **다른 계측**이다. 뭉치지 말 것.
3. 🔴 **지표마다 잡음 바닥을 먼저 재라.** 같은 디렉토리 3회 반복은 동일하지만, 디렉토리가
   다르면 makespan 이 19.875 vs 19.050 으로 갈린다(재컴파일 잡음). ⟹ **처치·대조는 같은
   디렉토리에서 순차로** 돌린다(병렬 금지 — HiGHS 가 다른 스케줄을 내고 프로세스당 ~2.5GB).
   잡음 폭보다 작은 차이는 지표로 못 쓴다.
4. **판정식을 사전등록 문서에 못박는다.** 삼상으로: 못 쟀다 / 쟀는데 차이 없다 / 쟀는데 개선.
   🔴 결과를 보고 지표를 고르지 않는다.
5. ⚠️ **현재 대조와 처치는 최종 수가 완전히 동일하다**(step 865 · closed 283/305). 그 동일성은
   tool 이 세계를 **한 번도 안 건드렸기** 때문이다(L4 = MEASURED-ZERO). Task 2·3 이 착륙해
   L4 가 0 을 벗어나야 비로소 두 런이 갈리고 지표가 잴 것이 생긴다.
   ⟹ **이 태스크의 지표 정의는 Task 2·3 과 무관하게 지금 할 수 있지만, 값을 재는 것은 그 뒤다.**

**산출**: 지표 정의 하나(또는 소수의 primary + secondary) + 각각의 계측 경로 + 잡음 바닥 실측 +
사전등록에 넣을 판정식. 이것이 없으면 Task 6 을 열지 않는다.

---

### Task 6 — 사전등록 + 넷째 유료 런

🔴 **Task 1·2·3·5 가 전부 착륙한 뒤에.** 그리고 🔴 **런 전에 사전등록 문서를 갱신하고 술어를
고정한다. 결과를 보고 술어를 고치지 않는다.**

레시피는 인계 문서 §5. 감시 항목:
- `DEMO_BATTERY_STEPS=40,120` 은 **필수**다. 기본 창은 낮은 SoC 로봇을 뽑아
  `routing_kind="battery"` → surrogate 로 새서 $0 쓰고 아무것도 안 잰다.
- `REQUIRE_SYNTH_MULTI_AGENT` 는 켜지 말 것 — 어떤 레인도 안 읽어서 옳은 런이 FAIL 로 죽는다.
- 🔴 `first(keys(env.agent_policies))` 는 **모양**을 가르치지 선택 정책이 아니다. 모델이 그대로
  베끼면 명세가 지목한 로봇이 아니라 **임의의 로봇**을 고른다 — 런은 깨끗이 돌지만 행동은 틀린다.
  **L2b 초록을 그것과 혼동하지 말 것.** Task 3 이 이 자리를 정확히 겨눈다.
- 채점은 `tools/monitor/ladder_report.py` 로만. 손인용 금지.

---

## 4. 검증 전용 에이전트

🔴 **각 태스크가 끝날 때마다, 구현자·리뷰어와 **별개로** 최대 추론 검증 에이전트를 돌린다.**
그 에이전트는 고치지도 커밋하지도 않고 주장마다
**CONFIRMED / REFUTED / UNVERIFIABLE** 만 낸다. 특히 재유도할 것:
- "이 시험이 X 를 지킨다" 는 주장 → **변이를 심어** 확인
- 인용된 수 → 직접 재유도
- "게이트가 초록" → 음성 대조가 실제로 빨간지
