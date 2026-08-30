# T8~T12 실행 후 남은 부족한 점 — 무엇이 아직 OOD 를 못 다루는가

> **범위.** `docs/superpowers/plans/2026-08-29-single-channel-tool-lane-plan.md` 의 **T8~T12**
> 를 2026-08-29 에 집행한 뒤 남은 결함 목록이다. 계획서의 §0-B(반증된 것)와 같은 규약으로
> 쓴다: **전부 이 워크트리에서 실측했거나 소스를 직접 태워 확인했고**, 항목마다 *무엇이 부족한가 ·
> 어디를 보면 되는가 · 무엇이 바뀌면 닫히는가* 를 적는다.
>
> 🔴 **이 문서를 안 읽고 스윕을 돌리지 말 것.** §A-1 과 §B-2 는 산출물이 "라우팅했다"고
> 주장하는 것과 실제로 일어난 일을 갈라놓는 종류다.

**집행된 커밋:** `d2360ef0`(T8) → `7eb0f94d`(T9) → `5ca1dc27`(T10) → `884aa9c9`(T11) →
`23655a6a`(T12 부분) → `978b905b`(픽스처) → `7620d3ad`(이 문서)

> ⚠️ **줄번호를 인용하지 않는다.** `46470d5a` 가 `policy.jl` 을 1835 → **1704** 줄로 줄여,
> 그 커밋 이전에 쓰인 `policy.jl:NNN` 인용은 ~440 줄 아래 전부 어긋난다(레포 전체에서 130건 이상).
> 이 문서는 그래서 **심볼 이름**으로만 가리킨다. 옛 판에서 인용을 옮겨 올 때 주의할 것.
>
> ## 🟢 갱신 (2026-08-29, 두 번째 세션 `chahj578-fd`) — **§A-1 · §B-1 · §B-2 · §C-2 가 닫혔다**
>
> `351203ed`(§A-1) · `f29292df`(§C-2) · `46470d5a`(§B-1·B-2). 아래 각 절에 ✅ 로 표시했다.
> **이 문서에서 아직 열려 있는 것은 §A-2 · §A-3 · §B-3 · §B-4 · §C-4, 그리고 새로 생긴 §F 다.**
>
> 🔴 **§B-2 의 예측이 집행으로 확인됐다.** 이 문서는 *"남은 1 fail 은 §B-1 없이는 안 닫힌다"* 고
> 적었고, novelty 삭제가 들어가자 **fail 이 1 → 0** 이 됐다. 그것이 §B-1 의 합격 신호였다.

**측정된 초록 (2026-08-29):**

| 게이트 | 값 |
|---|---|
| `.venv/bin/python -m pytest src/respec/llm_service/ -q` | **185 passed / 4 skipped** (착수 시 174) |
| `tools/monitor/test_lane_select.jl` | 45 / 45 |
| `test/tool_choice_gate.jl` | 57 / 57 |
| `test/tool_lane_keys_survive.jl` | **133 / 133** (교정 파일 있든 없든 — §C-1) |
| `tools/test_policy_escalation.jl` | 28 / 28 |
| `Pkg.test()` 전체 | **1486 passed / 0 failed / 1 errored** (착수 기준선 1529 / **14** / 1) |

🔴 **fail 0 이 이 계획의 종착점이다.** 착수 시 14 fail 이었고, 그중 12 는 T11 이(novelty 라우팅이
뿌리였다), 마지막 1 은 §B-1(novelty 삭제)이 닫았다. error 1 은 착수 기준선과 같은 Gurobi
라이선스(`test/runtests.jl:80`)이고 변경과 무관하다.
⚠️ **pass 가 1529 → 1486 으로 43 줄었다.** 무효가 된 시험을 지운 것이고(§D), `46470d5a` 가
그 감소분을 −11(`route_descriptors_survive`) / −25(`tool_choice_gate`) 로 분해해 적었다.
**이 감소를 "커버리지가 줄었다" 로 읽지 말 것** — 지운 것은 존재하지 않게 된 축의 시험이다.
🔴 이 숫자는 **두 세션이 독립적으로** 쟀다(`chahj578-fd` 와 이 세션, 같은 값).

🟢 **14 fail → 1 fail.** error 1 은 착수 기준선과 같은 Gurobi 라이선스이고 변경과 무관하다.
🔴 **남은 1 fail 의 정체는 §B-1 이다**(아래) — 새 결함이 아니라 **T12 미완의 증상**이다.

---

## A. 🔴 치명 — LLM 이 낯선 사건을 "낯설다"고 못 듣는다

### A-1. ✅ **닫혔다** (`351203ed`) — 라우터와 페이로드가 서로 다른 kind 를 말했다

> **어떻게 닫혔나.** `service_decide` 가 `payload["routing_kind"]` 를 싣고 프롬프트가 그것을
> 렌더한다. `payload["kind"]` 는 **안 건드렸다**(surrogate 피처 계약, 아래 그대로).
>
> 🔴 **이 문서의 처방과 한 곳이 다르고, 그쪽이 낫다.** 이 문서는 *"`agents`/`zones`/`lanes` 와
> 같은 키워드로 `decide_all` 이 넘긴다"* 고 적었다. 실제 구현은 **`service_decide` 안에서 직접
> 유도한다**(`service_decide` 안, `payload["routing_kind"] = …`) — 근거: 키워드는 *"호출자가 다른 값을 실을 수 있다"* 를 남기는데
> **그것이 바로 §A-1 결함 자체**이므로, 제자리 유도가 갈림을 구조적으로 불가능하게 만든다.
> ⚠️ 그 대가는 **생산 유도 사이트가 둘**이 된 것이다(`:538` 과 `:1375`). 이 레포는 규칙이 두 벌로
> 갈리는 사고를 반복했으므로 그 자리엔 기계 게이트가 필요한데, **있다** — 실측 확인:
> `test/service_decide_ships_routing_kind.jl` (2)절이 payload 쪽을, (3)절이 같은 사건의
> `rt["routing_kind"]` 를 **같은 절대값**으로 못박는다. 한쪽만 바뀌면 빨개진다.

**[역사] 아래는 닫히기 전의 기록이다** — 왜 이것이 결함이었는지의 근거이므로 남긴다.

T8 이 `routing_kind` 를 `ood_features` 의 `"kind"` 와 **일부러 다른 함수**로 뺐다. 라우팅에서는
그것이 옳다(§0-C 충돌 ①). 그런데 **그 비대칭이 라우팅에서 끝나고 페이로드로 안 이어진다.**

실측 (2026-08-29, `.venv/bin/python`):

```
VALID  = {'fault': ['NOOP','Replace'], 'battery': ['NOOP','Replace','SwapBattery']}
MACROS = ['NOOP','Replace','SwapBattery']

새 OODTruth 타입 하나가 발생했을 때:
  routing_kind(...)      = "unknown:MeteorTruth"   → select_lane → "dspy"      ✅ 옳다
  payload["kind"]        = "fault"                 (ood_features 의 else 분기)  🔴
  _valid_for(payload)    = ['NOOP', 'Replace']     (fault 메뉴)                 🔴
```

즉 **라우터는 OOD 를 알아봤는데 그 정보가 프롬프트에 한 글자도 안 실린다.** LLM 은 자기가
"처음 보는 사건"을 받았다는 사실을 모른 채 fault 사건으로서 답한다. `Replace`(로봇 교체)는
빔 붕괴·측위 상실 같은 사건과 아무 상관이 없는데, 그것이 메뉴의 유일한 개입 팔이다.

- **증거가 이미 레포 안에 있다.** T7 의 라이브 게이트 `_OUT_OF_VOCAB`
  (`src/respec/llm_service/test_live_single_channel.py:58-68`)의 두 사건("beam-collapse",
  "comms-loss")이 **둘 다 `kind="fault"`** 로 들어간다. 그 시험은 그 상태에서 `expressible=False`
  가 나오는지를 재는 것이므로 초록이 맞지만, **그것이 곧 이 결함의 재현 케이스다.**
- **왜 아무도 못 잡았나:** T8 의 교차 게이트(`test/tool_choice_gate.jl` (7)절)는 두 유도가
  **알려진 셋에서 일치**하는지만 잰다. 모르는 타입에서 둘이 갈리는 것은 **의도**라고 못박아
  놨는데, 그 갈림이 페이로드까지 새는지는 아무도 안 본다.
- **닫는 법 (한 줄짜리):** `service_decide` 가 `payload["routing_kind"] = rkind` 를 싣고,
  `_llm_input` 이 그 값이 `"unknown:"` 으로 시작하면 관찰 블록에 그 사실을 렌더한다.
  🔴 **`payload["kind"]` 는 절대 안 건드린다** — surrogate 피처가 그 열을 그렇게 배웠고
  (§0-C 충돌 ①), 바꾸면 학습과 다른 feature 로 배포되는 조용한 발산이 된다.
- **게이트:** `_valid_for` 가 아니라 **`_llm_input` 산출물**에 대해 잰다 — 메뉴는 안 바뀌므로
  메뉴를 재는 시험은 이 변경에 대해 구조적으로 눈이 멀다.

### A-2. 낯선 사건에 줄 수 있는 팔이 `NOOP` 하나다 (zone), 또는 틀린 팔 하나다 (새 타입)

kind 축에서 dspy 로 가는 사건은 오늘 **둘뿐**이고 둘 다 메뉴가 부실하다:

| 사건 | 라우팅 | LLM 이 받는 메뉴 | 근거 |
|---|---|---|---|
| `ZoneTruth` | ✅ dspy (`ood_kind`) | **`["NOOP"]`** | `valid_macros` 의 `truth isa CB.ZoneTruth` 분기 |
| 새 `OODTruth` 타입 | ✅ dspy (`unknown:X`) | `["NOOP","Replace"]` | `valid_macros` → `String[]` → 서비스 `_valid_for` 폴백 (§A-1) |

zone 의 `["NOOP"]` 은 **결함이 아니라 설계된 OOD 경계 표식**이다(`valid_macros` 의 그 분기 위 주석이 근거를
적는다: *"닫힌 어휘에 이 구역의 수복이 없다"*). LLM 은 `tool_choice="required"` 아래
`no_intervention` 하나만 든 메뉴를 받고, `expressible=false` 로 그 사실을 신고한다.

🔴 **그런데 그 신고 다음 칸이 비어 있다.** 실측:

```
grep -rn 'tool_minted|synthesis' --include='*.jl' src tools test   →  0건
```

즉 **합성 레인(T2)이 낸 것을 세계에 잇는 줄리아 코드가 한 줄도 없다.** 오늘의 상한은
**"OOD 를 handle 한다"가 아니라 "OOD 라고 신고한다"** 까지다. 그 다음 칸(L2 제약 신설과 그
집행)은 이 계획서 밖이고, `CLAUDE.md` 의 D-8 이 그 사다리를 정의한다.

### A-3. `kind ∈ train_kinds ∧ expressible=false` 조합이 **관측 불가능해졌다**

§0-C 충돌 ③이 예고한 대로다. kind 축은 *"surrogate 가 이 kind 를 배웠나"* 만 보고
*"이 메뉴로 이 사건을 다룰 수 있나"* 는 안 본다. 두 질문이 갈리는 사건 —
**어휘가 모자란 familiar 사건** — 은 이제 LLM 에 안 가므로 그 신호를 **영원히 못 본다.**

- 예전 축 1(어휘 미달)은 정확히 그 사건을 잡으라고 있었고, T11 이 그 축을 지웠다.
- 대가는 사용자 결정 1(§0-C)에 이미 들어 있다 — **결함이 아니라 선택**이다. 다만
  *"합성이 왜 안 도나"* 를 나중에 코드에서 찾게 되면 그 원인은 코드가 아니라 **라우팅**이다.
- **관측을 되찾고 싶으면** kind 축을 바꾸지 말고 `expressible` 을 surrogate 레인에서도
  **비용 없이** 재는 길(예: `valid_macros` ⊄ `surro_support` 를 결정 행에 남기기)을 만든다.

---

## B. 🟡 계획서에는 있는데 아직 안 한 것 (T12 미완)

### B-1. ✅ **닫혔다** (`46470d5a`) — novelty 축을 지웠다

**[역사] 아래는 닫히기 전의 기록이다.**

살아 있는 것: `install_novelty!` · `ROUTER_EPS` · `route()` 의 감지기 설치 ·
`route_verdict` 의 `novel`/`novelty_measured`/`enabled` · `NOVELTY_CALIB` 손잡이.

- 🟢 **결정에는 영향이 없다.** T11 이 `select_lane` 에서 novelty 를 읽는 경로를 전부 끊었다 —
  남은 것은 advisory 계산과 `rt` 기록뿐이고, 라우팅 결과를 바꾸지 않는다.
- 🔴 **그러나 비용과 혼동은 남는다.** 매 사건 서술자 6개 + z-거리를 계산하고, `rt["enabled"]`
  가 *"novelty 축이 실행을 정했는가"* 라고 계속 주장한다 — 그 주장은 **이제 거짓이다**
  (§0-C 충돌 ④). 화면·기록을 읽는 사람이 그 필드를 근거로 오독할 수 있다.
- **닫는 법:** T12 Step 2 표의 "novelty 일체" 행 그대로. 🔴 `event_descriptors_of` 와
  `descriptors` 는 **남긴다** — LLM 페이로드가 읽고, 그 함수는 교정값을 안 읽는다.

### B-2. ✅ **닫혔다** (`46470d5a`) — 그리고 **이 절의 진단이 맞았다**

`route()` 가 감지기를 설치하지 않게 되자 그 1 fail 이 **자동으로** 사라졌다(fail 1 → 0).
이 절이 §0-B ⑳ 의 처방을 반증하고 *"§B-1 만이 닫는다"* 고 적은 것이 집행으로 확인됐다.

**[역사] 아래는 그 반증의 근거다.**

실측: `grep -c 'clear_novelty_detector!\|set_novelty_detector!' test/tool_lane_keys_survive.jl`
→ **0**. 이 파일은 `CB.NOVELTY_DETECTOR[]` 를 건드리고 **복원하지 않는다.**

- §0-B ⑳ 이 이것을 "고칠 자리 ①"로 지목했고(그 1 fail 이 `tool_choice_gate.jl` (0)절을 죽였다),
  **아직 안 고쳤다.**
- 🟢 T11 이 뿌리 쪽을 반쯤 닫았다: 그 파일의 13 fail 은 novelty 라우팅이 원인이었고 지금
  **교정 파일이 있든 없든 133/133** 이다(§C-1). 그러나 **전역 누수 자체는 그대로**이므로
  스위트 순서에 따라 뒤따르는 게이트가 다른 세계를 볼 수 있다.
- ✅ **복원을 넣었다**(`const _PREV_DET` + `finally` 에서 되돌리기, `tool_choice_gate.jl` 과 같은
  규약). 그 파일은 단독 133/133 그대로다.
- 🔴 **그런데 그 1 fail 은 안 닫혔다** — 전체 스위트가 여전히 1503 / **1** / 1 이고, 실패는
  같은 자리다: `tool_choice_gate.jl:171` 의 `@test CB.novelty_detector() === nothing`.
  **실측된 값**(그 단언이 출력한 것):

  ```
  NoveltyDetector(..., alpha=0.05, meta=Dict("n_instances"=>82,
                  "kinds"=>["battery","fault","zoneblk"],
                  "source"=>"../oracle/out/firegrid_merged.jsonl", ...))
  ```

  🔴 **즉 누수가 아니었다** — 그것은 **교정 파일에서 로드된 진짜 감지기**다(`n_instances=82`,
  `kinds` 셋 = §0-C 실측표의 그 교정). 이 워크트리에 `novelty_calibration.json` 이 **존재하므로**
  (§0-C 정정 1), 스위트 안에서 **누군가 먼저** `install_novelty!()` 를 부르면 그 시점에
  전역이 채워지고, 그 뒤 도는 `tool_choice_gate.jl` 의 (0)절 전제가 깨진다.
  🔴 **그 "누군가" 는 이 파일 하나가 아니다** — `route()` 가 `install_novelty!()` 를 부르고,
  `route()` 는 `decide_all` 이 매번 부른다. **`decide_all` 을 부르는 모든 게이트가 후보다.**
  그래서 파일 하나에 `finally` 를 다는 것으로는 못 닫는다.
- **⟹ 닫는 법은 하나뿐이다: §B-1(novelty 삭제).** `route()` 가 감지기를 설치하지 않게 되면
  이 fail 은 **자동으로** 사라진다(§0-B ⑳ 도 *"T12 가 novelty 축을 통째로 지우므로 그때
  자동으로 닫히는 종류"* 라고 적었고, 그 판정이 맞았다).
  ⚠️ 그때까지 이 1 fail 을 **회귀로 오독하지 말 것.** 이것이 오늘 스위트의 정상 상태다.
- 🔴 **§0-B ⑳ 의 처방 ①("전역 복원을 넣어라")은 이로써 반증됐다.** 복원을 넣어도 안 닫힌다 —
  누수가 아니라 **교정 파일의 존재 + `route()` 의 게으른 설치**가 원인이기 때문이다.
  복원 자체는 옳으므로 남겼다(다른 게이트가 이 파일의 감지기를 물려받는 것은 여전히 막는다).

### B-3. 남은 잔재 셋

| 대상 | 자리 | 상태 |
|---|---|---|
| `DEMO_ALL_POLICIES` | `policy.jl` 머리말 ENV 목록 · `tools/test_policy_oracle.jl` | 손잡이가 아직 있다. T11 의 `want` 가 이미 대체했으므로 **죽은 손잡이**다 |
| `llm_macro` · `agrees_with_rule` | `record_decision!` 의 `DEMO_SUMMARY` input dict | 값이 `nothing` 으로 붕괴했고 **키는 남겼다** — 옛 녹화와 `KeyError` 로 구별되지 않도록. 의도적이지만 소비자가 그 사실을 모른다 |
| `escalation_target` · `surrogate_support_measured` | `policy.jl` 의 두 함수 정의 | 함수는 남겼다(진단용). 🔴 **생산 호출자가 0개**가 됐는데 docstring 이 아직 라우팅 이야기를 한다 |

### B-4. 계획서 §0-A 표가 아직 "T8~T12 미착수"로 적혀 있다

이 문서가 그 자리를 임시로 지지만, 계획서 본문의 진실원 표가 낡았다.

---

## C. 🟡 아직 안 쟀거나, 게이트가 엉뚱한 것을 재는 자리

### C-1. ✅ `Pkg.test()` 전체를 쟀다 — 그리고 **개별 게이트 초록이 전체의 증거가 아니었다**

착수 기준선은 §0-B ⑳ 의 **1529 pass / 14 fail / 1 error**(error 는 Gurobi 라이선스, 변경 무관).

| 시점 | 값 |
|---|---|
| 착수 기준선 | 1529 pass / **14 fail** / 1 error |
| T8~T12 직후(픽스처 고치기 **전**) | 1469 pass / **2 fail** / **5 error** |
| 픽스처 다섯 + 소스 계약 둘을 고친 뒤 | 1503 pass / **1 fail** / 1 error (`978b905b`) |
| 전역 누수(§B-2)까지 고친 뒤 | 1503 pass / **1 fail** / 1 error — **안 닫혔다**, 아래 |

🟢 **§0-B ⑳ 의 14 fail 중 12 가 닫혔다** — 그 뿌리가 novelty 라우팅이었고 T11 이 그것을 끊었다.
🔴 **그런데 error 가 1 → 5 로 늘었고, 그때 개별 게이트 다섯은 전부 초록이었다.** 이것이 이 절의
교훈이다: `decide_all` 을 재배선하면 그 파일을 include 하는 **모든** 게이트가 영향권인데,
개별 실행으로는 그중 내가 손댄 것만 보게 된다. 새 error 넷은 전부 §C-3 이 예측한 자리였다.

⚠️ 그리고 pass 가 1529 → 1469 로 **60 줄었다.** 그중 일부는 무효가 된 시험을 지운 것이고
(§D 참조), 일부는 **error 로 죽은 testset 이 그 아래를 못 돌아서**다 — 두 원인이 한 숫자에
섞여 있으므로 **이 감소분을 "시험을 60개 지웠다" 로 읽지 말 것.**

### C-2. ✅ **닫혔다** (`f29292df`) — 머리말 ⑤ + zone 메뉴 라이브 케이스(레지스트리 유도)

유료 호출 없이 닫았다. **[역사] 아래는 닫히기 전의 기록이다.**

§0-C 충돌 ②가 예고한 함정이고, **T11 이 그것을 시험 docstring 에 못박는 일을 안 했다.**

`test_live_single_channel.py` 의 `_IN_VOCAB` 은 `fault`·`battery` 이고, 그 둘은 새 라우터에서
**전부 surrogate 로 간다.** 그 시험은 `svc.macro()` 를 직접 부르므로 계속 초록이지만,
프로덕션에서 그 경로로 LLM 이 불릴 일이 없다. **그 초록을 "LLM 레인이 건강하다"의 근거로
인용하면 §0-B ⑦ 과 같은 종류의 오독이다.**

- **닫는 법:** 그 파일 머리말에 한 문단 — *"이 파일은 서비스 함수의 계약을 잰다. `fault`·
  `battery` 는 kind 색인 라우터에서 surrogate 로 가므로, 이 초록은 **프로덕션 LLM 레인이
  돈다는 증거가 아니다**. 그것을 재려면 `_OUT_OF_VOCAB`(= zone / 새 타입)로 재야 한다."*
- 더 나은 길: `_IN_VOCAB` 을 유지하되 **라이브 OOD 케이스를 zone 메뉴(`["NOOP"]`)로** 하나
  추가한다 — 그것이 오늘 실제로 도는 유일한 LLM 사건 모양이다.

### C-3. ✅ **예측이 맞았다 — 픽스처는 둘이 아니라 다섯이었다** (2026-08-29 실측으로 해소)

T11 실행 중 실측: `test/tool_choice_gate.jl` 과 `test/tool_lane_keys_survive.jl` 의 대역
`/health` 가 `{"status":"ok"}` 만 내서, 라우터가 설계대로 *"못 쟀다 → 죽는다"* 를 냈다.
**계획서 T11 의 Files 목록에 그 두 파일이 없다**(§0-B ⑲ 와 같은 종류의 누락).

⟹ 이 절은 원래 *"다른 대역 서버가 남아 있으면 같은 자리에서 또 죽는다"* 는 **예측**이었다.
전체 `Pkg.test()` 가 그것을 **확인했다.** 실측:

```bash
grep -rn '"/health"' --include='*.jl' test tools src   →  **5건**
```

`tool_lane_keys_survive.jl` · `tool_choice_gate.jl`(T11 에서 고침) 외에 **셋이 더 있었다**:
`test/tool_args_grounding.jl` · `test/service_decide_ships_zones.jl` ·
`test/service_decide_ships_agents.jl`. 전부 라우터가 "못 쟀다 → 죽는다"로 정당하게 죽었다.

**고친 방식이 셋에서 서로 다르다 — 그 차이가 정보다:**

| 파일 | 무엇이 필요했나 | 고친 법 |
|---|---|---|
| `tool_args_grounding.jl` | (9)절이 **dspy 가 집행된 판**을 재야 한다 | `surro_kinds: []`("쟀는데 비었다" → 전부 ood_kind → dspy). 🔴 옛 근거 *"surrogate 를 불가로 두면 select_lane 이 dspy 를 고른다"* 는 **거짓이 됐다** — 가용성 기반 선택이 곧 조용한 폴백이라 §0-C 결정 3 이 없앴다 |
| `service_decide_ships_{zones,agents}.jl` | **요청**을 재는 게이트라 응답은 최소치면 됐다 | 옛 `{"dspy":null,"surrogate":null}` 은 이제 못 쓴다(고른 레인이 unavailable ⟹ `error()`). **`payload["lanes"]` 를 읽어 요청된 레인마다** 최소 유효 결정을 돌려주게 바꿨다 — 라우팅이 또 바뀌어도 안 깨진다 |

🔴 **다음에 라우팅 규칙을 바꾸는 사람에게:** 가짜 `/health`/`/decide` 를 **하드코딩된 레인
목록**으로 쓴 픽스처는 라우팅 변경마다 깨진다. `service_decide_ships_*` 에 넣은
*"요청된 레인을 읽어 그대로 돌려준다"* 패턴이 그 문제를 구조적으로 없앤다 — 새 픽스처는
그 모양으로 쓸 것.

### C-3b. ✅ 소스 문자열 계약 둘도 대상이 교체됐다 (`tools/test_policy_oracle.jl`)

1차 측정의 **2 fail** 이 이것이었다. 둘 다 `policy.jl` 소스를 정규식으로 읽는 계약이고,
지키려는 **명제는 그대로인데 그것을 나르는 코드가 바뀌었다**:

- *"서비스 생략 게이트가 oracle 을 포함한다"* — `POLICY in ("canonical","noop","oracle")` 를
  T11 이 지웠다. 지키려던 것(*"oracle 판이 DSPy 서비스에 의존하지 않는다"*)은 **더 강하게**
  성립한다: 이제 `want = sel.lane in ("dspy","surrogate")` 가 정하므로 **이름 목록을 손으로
  적을 필요가 없고, 새 통제 레인을 더할 때 빠뜨릴 수도 없다.** 그 규칙을 못박도록 다시 썼다.
- *"표시 튜플 3곳"* — T12 가 반사실 비교(`others`)를 지워 **2곳**이 됐다. 개수는 회귀 감지용으로
  남기고, 진짜 명제(*"oracle 이 표시 튜플에 안 섞인다"*)를 직접 재는 검사를 **더했다**.
  🔴 개수를 3 으로 되돌리려 하지 말 것 — 늘었다면 안 부른 레인을 다시 읽는 자리가 생긴 것이다.

**결과: 39 passed / 0 failed.**

### C-4. 옛 (4)절의 명제가 뒤집혔다는 사실이 **한 파일에만** 적혀 있다

`tool_lane_keys_survive.jl` 의 옛 (4)절 *"폴백 분기에서도 8키가 존재하고 전부 nothing 이다"* 는
조용한 canonical 폴백을 전제했다. §0-C 결정 3 이 그것을 없앴으므로 **그 상태를 만들 수 없다** —
지우고 `@test_throws ErrorException` 으로 다시 썼다. 같은 전제 위에 선 시험이 다른 파일에
있는지는 **안 훑었다.** 확인 명령:

```bash
grep -rn 'fell_back\|"canonical"' --include='*.jl' test tools | grep -i test
```

---

## D. 이번 실행에서 계획서와 갈린 것 (다음 사람이 밟지 않도록)

**① `policy_entry` 는 레인과 무관하게 열한 키를 **언제나** 짓는다.**
`tool_lane_keys_survive.jl` (3)절에 `!haskey(surrogate_entry, "tool_called")` 를 적었다가
빨갰다. 안 부른 레인은 **`pol` 에서 키가 없고**, 부른 레인의 항목은 **키를 들되 값이
`nothing`** 이다. 하중은 존재가 아니라 **값**이다.

**② T11 이 T12 의 일부를 컴파일 의존으로 끌고 왔다.**
zone 에스컬레이션 블록 · `escalation_allowed` · `others`/`agree` · `requested` 는 `pol` 이
희소해지는 순간 `KeyError` 로 죽는다. T11 커밋에 포함시켰다 — **T12 를 마저 할 사람은 그
항목들이 이미 닫혀 있음을 전제할 것.**

**③ `pol[k]` 를 무조건 색인하는 자리가 셋 더 있었다.**
`policy.jl` 의 후보표(`:1666`) · `"by"` 열(`:1677`) · `render_demo.jl:748` 의 비교 줄.
앞 둘은 `haskey` 가드를 넣었고 셋째는 지웠다. 🔴 **`"by"` 열의 뜻이 좁아졌다** — 계산된
레인이 둘(canonical + 고른 것)뿐이라 비교 정보가 **구조적으로** 줄었다. 옛 녹화와 같은 표에
섞지 말 것.

**④ 되돌릴 수 없는 단절.** 결정 행에서 `llm`·`surrogate`·`agree`·`router_p`·`router_novel`
다섯 열이 사라졌고, 화면에서 `surro=…, dspy=…` 비교 줄이 사라졌다. **이 커밋 이전 녹화와
그 열들에서 비교가 끊긴다**(§0-C 충돌 ④). 옛 녹화를 읽는 분석은 키 부재를 *"값이 없다"* 가
아니라 **"세대가 다르다"** 로 읽어야 한다. 그 열이 필요했다면 지금은 이미 늦었다.

---

## E. 운영상 발견 하나 (계획 밖)

`ps` 로 확인: `tools/monitor/server.jl` 프로세스가 **15일째** 떠 있다(PID 2269414).
이 프로세스는 T8~T12 **이전 코드**를 들고 있다.

🔴 `.claude/projects/.../memory` 의 *"기본 포트의 DSPy 서비스가 현행 코드라는 보장이 없다"* 와
**정확히 같은 실패 모드**다(그때는 8077 에 나흘 묵은 프로세스가 `/health` 200 을 내고 있었다).
데모·스윕을 돌리기 전에 `ps -o lstart` 로 커밋 시각과 대조하고 재기동할 것 — 특히 이번엔
`/health` 의 `surro_kinds` 가 **없으면 라우터가 죽으므로**, 낡은 서비스는 조용히 새는 대신
시끄럽게 죽는다(그게 설계다). 그 죽음을 회귀로 오독하지 말 것.

---

## F. 🔴 **새로 생긴 결함** — novelty 삭제가 파이썬 소비처 둘을 고아로 만들었다 (임자 없음)

§B-1 이 novelty 축을 지우면서 결정 행의 `router_p`·`router_novel` 이 사라졌다. 그 두 열을
**입력으로 읽는 파이썬 분석기 둘**이 남아 있고, **아무도 안 고치기로 했다**(두 번째 세션이
범위 밖이라고 명시적으로 넘겼다). 실측(2026-08-29):

| 자리 | 무엇을 읽나 | 지금 상태 |
|---|---|---|
| `wm4spacecraft_manufacturing/reporting/shadow_score.py:141` `novelty_gate_replay` | `router_novel`/`router_p` | 🔴 입력이 **영구히 0건**. docstring 이 아직 **현재형**으로 *"라우터 on/off 와 무관하게 매 결정에서 계산·기록된다"* 고 주장한다 — 그 문장은 이제 거짓이다 |
| `wm4spacecraft_manufacturing/sweep/llm_ood_eval.py:289·325·343·351` | `router_p` 로 risk-coverage(선택적 예측) | 🔴 `risk_pairs` 가 항상 비고, 산출 1-d 가 조용히 빈 곡선이 된다 |

🔴 **위험한 실패 양식이다** — 둘 다 **에러를 안 낸다.** `ev.get("router_p")` 가 `None` 을 내고
짝이 안 만들어질 뿐이라, 분석은 **정상적으로 끝나고 빈 결과를 낸다.** 그것을 읽는 사람은
*"라우터 신뢰도로 위험-커버리지가 안 나왔다"* 를 **측정 결과**로 읽게 된다 — 사실은
**입력이 없어진 것**이다. 이 레포가 반복해 밟은 "조용히 새는" 자리와 같은 모양이고,
`CLAUDE.md` 의 §2026-08-18 항목 5(스윕 사전조건 게이트)가 경고하는 종류다.

**닫는 법은 셋 중 하나 — 고르는 것이 사람의 판정이다:**
1. **지운다.** novelty 축이 설계에서 빠졌으므로 그것을 재던 산출도 같이 간다(가장 정직하다).
2. **kind 축으로 다시 세운다.** risk-coverage 의 신뢰도 축을 `router_p` 대신
   `router_axis`(`known_kind`/`ood_kind`) 이분으로 바꾼다 — 연속값이 아니므로 곡선이 아니라
   두 점이 된다. 정보량이 줄지만 **축이 실재한다.**
3. **최소한 시끄럽게 만든다.** 입력 0건이면 빈 곡선을 내지 말고 죽거나 경고한다.

🔴 **아무것도 안 하면 3번조차 아니다** — 지금은 조용히 빈 결과를 낸다.

### F-3. 🔴 **가장 비싼 것** — 죽은 전제가 스윕 실행을 **막는다** (`chahj578-fd` 가 고치는 중)

§F 의 둘은 조용히 빈 결과를 냈다. 이것은 **실행 가능한 소비처**라 청구서가 더 크다.
실측(2026-08-29, 이 세션이 독립 확인):

```bash
grep -rn 'NOVELTY_CALIB' --include='*.jl' .
  → tools/test_router.jl:31 (시험) + 주석 2건.  **생산 소비처 0개.**
```

| 자리 | 무엇을 하나 |
|---|---|
| `sweep/llm_ood_eval.py` 의 `_validate_router_args` | `--router != 0` 인 스윕을 `--novelty-calib PATH` 없이는 **시작 자체를 거부**한다. 사유: *"calib 없이 라우터를 켜면 policy.jl 이 fail-open 으로 라우터를 꺼버려"* — 그 fail-open 은 `46470d5a` 가 지웠다 |
| `tools/monitor/regen_router_cases.sh` | 같은 죽은 전제로 `failed=all:novelty-calib-missing` 하드 종료 |

🔴 **두 방향으로 틀린다.** ① 교정 파일이 없는 사람은 **아무 이유 없이** 라우터 스윕을 못 돌린다.
② 파일을 가진 사람은 그것을 넘기고 *"라우터를 켰다"* 고 믿는데, 그 ON/OFF 구분은 이제
**아무 의미가 없다** — 하룻밤 스윕이 그 틀린 프레이밍 위에서 돈다. argparse help 는 아직
*"필수다"* 라고 적는다.

✅ **임자 있음** — `chahj578-fd` 가 요구를 제거하고 플래그는 받되 무효임을 문서화한다.

### F-2. 대시보드 ROUTER 배지 (두 번째 세션이 고치는 중)

`tools/monitor/dashboard.html:1274` 의 배지가 `rr.enabled` **하나만** 읽는다. `enabled` 가
사라졌으므로 **라우터가 실제로 몰았던 런에서 새 녹화가 "ROUTER OFF" 로 그려진다.**
같은 파일 `:1367` 의 routerBar 는 `enabled === true || drives_lane === true` 로 이미 옳게
처리한다 — 배지만 아무도 안 고친 별개 자리다. (실측으로 두 줄 다 확인했다.)

---

## G. 🔴 스윕 사후 게이트 `_router_drove` 가 **실패할 수 없는 게이트**가 됐다 (임자 없음)

`sweep/llm_ood_eval.py` 의 `_router_drove` 는 산출물에서 *"라우터가 **실제로** 몰았는가"* 를
사후에 재라고 있는 게이트다. T11 의 축 enum 교체가 그것을 자기참조로 만들었다.

**결함 ① (`chahj578-fd` 의 검증자가 찾음, 이 세션이 확인):**

```python
ROUTER_AXES = {"control", "vocabulary_gap", "novelty", "none"}   # ← T11 이전 enum
...
if not ((axes & ROUTER_AXES) or (True in drove)):     # "gate failed open"
```

T11 이후 실제 산출값은 `control` · **`known_kind`** · **`ood_kind`** · `fixed` 다
(`lane_select.jl` 의 세 `return` 에서 실측). 라우터가 **몰았을 때** 나오는 두 값
(`known_kind`/`ood_kind`)이 `ROUTER_AXES` 에 **없다** ⟹ 그 사건에서 축 가지는 언제나 빈 집합이다.
⚠️ *"항상 빈 집합"* 은 과장이다 — `control`(noop 통제 런)은 아직 양쪽에 다 있다. 그러나
**이 게이트가 존재하는 이유인 그 사건**에서는 비어 있다.
⟹ 게이트를 떠받치는 것은 `router_drives` 하나뿐인데, 그 값은 `router_drives()` =
`ROUTER_MODE != "0" && POLICY != "noop"` — **연산자가 넘긴 플래그의 메아리**이고, 같은 함수가
한 줄 위에서 `r.get("router") != want_router` 로 **이미 검사한 것**이다.
즉 게이트가 이제 **행동이 아니라 플래그를 자기 자신과 대조한다.**

**결함 ② 🔴 이 세션이 추가로 찾았다 — 같은 함수의 WARN 이 영구 거짓 소음이 됐다.**

```python
measured = {d.get("support_measured") for d in decisions}
if measured and True not in measured:
    print("    WARN: router drove, but surrogate support was never measured ... axis 1 could not have fired")
```

실측: `rt["support_measured"] = …` 를 쓰던 줄을 T11 이 지웠고, `policy.jl` 에 남은
`support_measured` 는 **함수 정의 둘뿐**이다(`grep -n` → 1035·1071, 둘 다 정의). 그래서
`run_demo.jl` 이 읽는 키가 **영원히 없고** `measured == {None}` 이므로 이 조건이 **항상 참**이다.
⟹ **모든 라우터 런이 이 경고를 찍는다.** 게다가 문구가 *"축 1 이 발화할 수 없었다"* 라고
말하는데 **축 1 은 존재하지 않는다.** 항상 켜지는 경고는 연산자에게 경고를 무시하도록 가르치므로,
빈 결과보다 나쁠 수 있다.

**닫는 법은 사람의 판정이다** — §F 와 같은 종류라 어느 세션도 임의로 정하지 않았다:
1. `ROUTER_AXES` 를 `{"control","known_kind","ood_kind","fixed"}` 로 갱신하고 WARN 을 지운다
   (가장 작다. 다만 게이트가 *"플래그의 메아리"* 인 것은 그대로다).
2. 게이트의 명제를 다시 정한다 — 라우터가 몰았다는 **행동의 증거**는 오늘 무엇인가?
   후보: 결정 행의 `lanes` 가 **하나**이고 그것이 `router_axis` 와 일관되는가(T11 이 만든,
   플래그와 독립인 사실).
3. 게이트를 지운다 — 명제를 다시 못 세우겠으면, 못 재는 게이트를 초록으로 두는 것보다 낫다.

🔴 **1번만 하고 멈추면 "게이트가 초록이다" 가 다시 근거로 인용된다** — 그것이 계획서 §0-B ⑦·⑯이
두 번 경고한 자리다(순수 함수만 재고 그 **효과**는 안 재는 게이트).

---

## 우선순위 (닫는 순서 제안)

| # | 항목 | 왜 이 순서인가 | 크기 |
|---|---|---|---|
| ~~1~~ | ~~**§C-1** `Pkg.test()` 전체~~ | ✅ **했다.** 그 결과가 §C-3·§C-3b 를 낳았고 둘 다 닫았다. **현행 정상 상태 = 1503 / 1 / 1** | — |
| ~~1~~ | ~~**§B-1** novelty 삭제~~ | ✅ **`46470d5a` 에서 닫혔다.** 예측대로 fail 이 1 → 0 이 됐다 | — |
| **1** | **§G** `_router_drove` 게이트 | 🔴 **임자 없음.** 스윕 건강을 재는 게이트가 자기참조가 됐고, WARN 은 매번 켜진다. 명제 재정의는 **사람 판정** | 30~60분 |
| ~~1~~ | ~~**§F-3** 죽은 NOVELTY_CALIB 전제~~ | ✅ **`chahj578-fd` 가 잡았다** — 실행을 막는 종류라 원래 최우선이었다 | — |
| 2 | **§F** 고아가 된 파이썬 소비처 둘 | 🔴 **임자가 없다.** 조용히 빈 결과를 내므로 발견이 늦다 — 지울지 다시 세울지가 **사람의 판정**이다 | 20분(지우기) ~ 60분(kind 축 재구성) |
| ~~2~~ | ~~**§A-1** `routing_kind` 를 페이로드에 싣는다~~ | ✅ **`351203ed`** | — |
| ~~3~~ | ~~**§C-2** T7 게이트 docstring 정정~~ | ✅ **`f29292df`** | — |
| ~~4~~ | ~~**§B-1·B-2** novelty 삭제~~ | ✅ **`46470d5a`** | — |
| 2 | **§B-3·B-4** 잔재 + 계획서 §0-A 표 | 낡은 서술이 다음 사람을 틀린 모델로 민다 | 20분 |
| 5 | **§A-2** 합성 → 집행 사슬 | 이 계획 **밖**이다. L2 레인의 몫 | 별도 계획 |

🔴 **2 를 3 보다 먼저 하지 말 것도, 뒤에 하지 말 것도 아니다 — 독립이다.** 다만 **1 은
언제나 먼저다.**
