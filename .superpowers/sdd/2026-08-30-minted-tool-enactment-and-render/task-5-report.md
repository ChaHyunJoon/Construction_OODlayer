# Task 5 보고 — 첫 라이브 합성 발화 시도 (분수령)

**상태: STOP (브리프 Step 3 의 정지 조건에 도달).** 합성은 발화하지 않았다. 이유는 배선
결함도 알파벳 부족도 아니고, **모델이 이 사건을 `["NOOP"]` 안에서 표현 가능하다고 판정했기
때문**이다. 브리프와 교정문이 금지한 대로 프롬프트로 뒤집지 않았다.

유료 호출 **3/3** 사용. 렌더 보드 1판(재시도 없음) + `/macro` 2회.

## 1. 서비스 (C1)

`:8079` 는 건드리지 않았다. `:8077` 의 옛 PID `1147128`(13:07:53 기동)만 죽이고 재기동.

- 새 PID **1232581**, 기동 시각 **Sun Aug 30 19:20:23 2026** (= 지금)
- `/health` → `{"status":"ok","policy":"dspy:gpt-4o","program":"(seed only)","demos":0,"calls":0,
  "surrogate":"oracle_dataset.jsonl (33 rows / 12 instances, macro support [0, 1, 2], rule
  deadband_Jbar, objective_hash 489268e6659e5ae9, vocab v4-3arms)","surro_support":[0,1,2],
  "surro_kinds":["battery","fault"],"policies":["dspy","surrogate"]}`
- `calls:0` 이 새 프로세스임을 확인해 준다(묵은 프로세스 함정 회피).
- 🔴 `TOOL_SYNTHESIS=1` 이 **프로세스 환경에 실제로 실렸는지**를 `/proc/1232581/environ` 로
  직접 확인했다(`TOOL_SYNTHESIS=1`, `OPENAI_API_KEY` 존재). `/health` 는 이 값을 안 싣는다.
  응답의 `synthesis.enabled: true` 가 독립 확증이다.

## 2. Step 2 — `/macro` 프로브 (유료 1)

브리프의 페이로드 그대로:

```
{"chosen":"NOOP","expressible":true,"tool_minted":null}
synthesis: {"synthesis_event":false,"ran":false,"enabled":true,"kind":"zone",
            "expressible":true,"K":0,"error":null,
            "reason":"not a firing event: expressible is True; T2 fires only on False (spec 8-1)"}
```

판정표상 `expressible: true` → Step 3.

🔴 **그러나 이 프로브는 보드의 입력을 충실히 재현하지 않는다.** 브리프의 페이로드에는
`zones` 도 `routing_kind` 도 없다. 그 둘이 없으면 `_zones_block` 과 `_unfamiliar_block` 이
**둘 다 빈 문자열**을 낸다(두 함수의 계약이 명시적으로 그렇다). 즉 이 프로브는 존 기하도,
"낯선 사건" 이라는 사실도 안 실은 프롬프트를 잰 것이다. 그래서 이것만으로 정지하지 않고
Step 3 의 배선 검사로 갔다.

## 3. Step 3 — 배선 검사 세 개: **전부 통과**

1. **`zones` 채널이 실린다.** `policy.jl` 의 `service_decide` 호출부가
   `zones = CB.open_zone_descriptors(env)` 를 넘기고, 같은 파일이 `zones === nothing ||
   (payload["zones"] = zones)` 로 싣는다. `llm_bridge.jl:open_zone_descriptors` 는 구역마다
   `key/center/radius/covers/covers_root`(+ 렌더되지 않는 네 키)를 낸다.
2. **`_unfamiliar_block` 이 렌더된다.** `lane_select.jl:routing_kind` 가
   `ZoneTruth -> "unknown:zone"`, `policy.jl` 이 `payload["routing_kind"]` 로 싣고,
   `_unfamiliar_block` 은 `rk.startswith("unknown:")` 에서 렌더한다.
   **보드 로그가 이것을 실행으로 확증한다**: `[router] 'unknown:zone' is outside the
   surrogate's training kinds → escalate to LLM (kind=unknown:zone, axis=ood_kind)`.
3. **`mechanism` 산문이 실제 기전을 말한다.** `restage_all_blocked` 는 greedy 재배치·상태
   4종·"루트 자체 목표는 못 건드리고 그때 `translate_whole_build` 가 유일한 지렛대" 까지
   적고, `translate_whole_build` 는 강체 변위의 건전성 근거와 상태 4종을 적는다. 잘린 곳 없음.

세 개가 다 통과했으므로 브리프대로 **프롬프트를 고치지 않았다.** `synthesize.py` 는
**한 글자도 안 건드렸다**(`git status` 로 clean 확인).

## 4. Step 4 — 보드 (유료 2). 실제로 관측한 줄

```
[zone] blocking zone on transport vtx=153 @[1.094, 0.416] r=0.07 -> nav_blocked=3/131
[zone] diag n_blocked=3 n_nav_blocked=3 root_covered=0/8 n_work_overlap=6 n_teams_covered=0 n_nav_goals=131 n_nav_engulfed=3 n_agent_trapped=0
[router] 'unknown:zone' is outside the surrogate's training kinds → escalate to LLM (kind=unknown:zone, axis=ood_kind)
[policy] ZoneTruth → NOOP (enacted=dspy; rule=NOOP)
[enact] target=- source=none tool_agent=- verify=deferred:no_groundable_param reject=no_tool_agent
[minted] lane=reach_nothing tool=n/a reach=n/a verdict=deferred applied=false partial=false world_maybe_dirty=false handled=false undo=none resume=none steps=[] ran_milp=n/a(not armed) reason=no synth lane on this decision
[minted] NOT handled → 기본 복구 사슬로 폴백한다 (이 폴백은 조용하지 않다 — 위 verdict 가 이유다)
PROJECT INCOMPLETE!
ERROR: LoadError: refusing to publish incomplete animation for model=tractor.mpd case=none
```

기준선(C7, `results/baseline_2026-08-30/zone_before.log`)과 **결과가 같다**: `NOOP` →
`PROJECT INCOMPLETE!` → 애니메이션 발행 거부. 산출물 ①(`tractor__zone_minted.html`)은
**생기지 않았다.** (vtx 가 143→153 으로 다르지만 중심·반지름·`nav_blocked=3/131` 은 동일.)

### C4 가 요구한 해석

- 🔴 **알파벳 이유가 아니다.** `n_blocked=3`(막힌 **조립체** 수, `n_nav_blocked` 와 다름)이
  0 이 아니므로 `restage_all_blocked!` 의 `:none` 조기 반환은 **발동하지 않았을 것**이다.
  게다가 `root_covered=0/8` 이라 루트 자체 목표는 존 밖이다 — 즉 `translate_whole_build`
  없이 `restage_all_blocked` **하나로 충분했을, 존 레인에 가장 유리한 판**이었다.
  이번 실패를 알파벳 탓으로 돌릴 근거는 없다.
- `ran_milp=n/a(not armed)`, `steps=[]` — 인터프리터는 **한 번도 불리지 않았다.** 따라서
  C3 의 "reject 는 정상" 도, C4 의 `handled=true` / `resume=:issued` 첫 실행도 **이 판에서는
  전혀 도달하지 못했다.** 그 두 경로는 여전히 실제 빌드에서 미실행 상태다.

## 5. 왜 발화하지 않았나 — 유료 3 으로 확정

`[minted] lane=reach_nothing` 만으로는 원인을 못 가른다(§7 우려 ①). 서비스 코드에서
`expressible` 은 **모델의 tool 호출 인자**에서 나오고(`tool_args_all.get("expressible")`,
bool 이 아니면 `None`), `maybe_synthesize` 는 **`expressible is False` 하나로만** 발화한다.
그래서 `reach=nothing` 은 (a) `true` (b) `None`(못 쟀다) (c) 발화 후 오류 셋 다와 양립한다.

이것을 가르려고 마지막 호출을 **통제 대조**에 썼다: 브리프의 프로브 페이로드에
**`zones` 와 `routing_kind` 두 채널만 추가**한 것(= §2 프로브의 유일한 결손을 메운 것).

```
{"chosen":"NOOP","expressible":true,"tool_minted":null,
 "tool_called":"no_intervention","tool_calls_n":1,"decision_source":"tool","tool_arg_error":null}
synthesis.reason: "not a firing event: expressible is True; T2 fires only on False (spec 8-1)"
```

⟹ 존 기하(`covers` 3건, `covers_root:false`)와 "낯선 사건" 블록을 **둘 다 실은** 프롬프트에서도
모델은 `expressible: true` 를 냈고, `no_intervention` 을 1회 정상 호출했으며 접지 오류도 없다.
`(b) None` 과 `(c) 오류` 는 배제된다. **발화하지 않은 이유는 모델의 판정 하나다.**

⚠️ 정직성 단서: 이 대조의 `covers` 노드 id 3개는 보드 로그의 `n_blocked=3` /
`root_covered=0/8` 에 맞춰 **내가 재구성한 값**이다(보드의 실제 페이로드는 어디에도 안 남는다,
§7 우려 ②). 개수와 `covers_root` 는 실측이고 id 문자열은 아니다.

## 6. 결론

브리프 Step 3 의 정지 규칙 그대로다: **배선 검사 세 개가 다 통과했는데도 `expressible` 이
`true` 다.** 이것은 배선 결함이 아니라 "이 사건이 정말 어휘 밖인가" 에 대한 모델의 판정이고,
그것을 프롬프트로 뒤집는 것은 측정이 아니다. `_EXPRESSIBLE_DESC` 및 어떤 프롬프트 경로에도
`min_shift_to_clear_m` / `zone_relocate_norm` / `when_to_use` / "존이면 false" 류의 힌트를
**넣지 않았다.** 사용자 판단을 기다린다.

## 7. 우려 (전부 이번 판에서 실제로 데인 것)

1. 🔴 **`[minted] lane=reach_nothing` 이 삼상을 일상으로 뭉갠다.** "expressible=true 라서
   안 쐈다" · "expressible 을 못 쟀다(None)" · "쐈는데 오류" 가 **글자 그대로 같은 줄**을
   낸다. `SYNTH_LANE_KEYS` 아홉(`synthesis_event`·`synthesis_ran`·`synthesis_error`·
   `tool_minted` 포함)은 결정 행에 **이미 실려 있는데 한 개도 안 찍힌다**. 이 한 줄 때문에
   원인 판별에 유료 호출 하나를 더 썼다. 조기 반환 줄에 최소한
   `synthesis_event`/`synthesis_ran`/`synthesis_error`/`expressible` 을 실을 것을 제안한다.
2. **보드의 결정이 디스크에 아무것도 안 남긴다.** 이 판이 쓴 것은 `render.log` 와
   `stats.toml` 뿐이고 결정 JSON 이 없다. C5 는 "JSON 말고 stdout 을 읽으라" 인데, 그 stdout
   이 우려 ① 대로 손실적이다. 사후분석 경로가 지금 **둘 다 막혀 있다.**
3. `expressible` 이 tool 호출 인자에서만 나오므로, 모델이 그 인자를 빠뜨리면 `None` 이 되어
   합성이 **조용히** 안 쏜다(우려 ① 과 같은 줄을 내면서). 발화 게이트가 모델의 인자 성실성에
   걸려 있다.
4. 애니메이션 거부 메시지가 `case=none` 이라고 적는다 — `DEMO_CASE_TAG=zone_minted` 가 그
   메시지에 도달하지 않는다. 사소하지만 로그로 판을 구분할 때 헷갈린다.
5. `_zones_block` 은 `build_center`·`build_radius`·`max_shift`·`work_reach` 를 **의도적으로
   렌더하지 않는다**(정답을 프롬프트에 안 싣는 설계). 그 결정 자체는 옳다고 보지만, 결과적으로
   모델이 보는 것은 "반지름 0.07 짜리 원반이 조립체 3개를 덮는다" 까지이고 그 정도면 NOOP 로
   충분하다는 판정이 **모델 입장에서 비합리적이지 않다.** 이 판정을 바꾸고 싶다면 손댈 자리는
   프롬프트 지시문이 아니라 **어떤 측정을 실을 것인가** 이고, 그것은 사용자 결정 사항이다.

## 8. 코드 변경

**없다.** `synthesize.py` 를 포함해 소스 파일을 하나도 고치지 않았으므로 스위트를 다시 돌리지
않았다(직전 상태 2005 passed 그대로). 커밋한 것은 `results/2026-08-30-zone-minted/` 의
증거 3건과 이 보고서뿐이다.
