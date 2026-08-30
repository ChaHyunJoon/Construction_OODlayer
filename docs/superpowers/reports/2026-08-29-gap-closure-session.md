# §A-1 · §C-2 · §B-1·B-2 를 닫았다 — 무엇이 바뀌었고, 무엇을 일부러 안 했나

> **범위.** `docs/superpowers/reports/2026-08-29-t8-t12-remaining-gaps.md` 의 우선순위 표
> **2 · 3 · 4**. 계획서는 `docs/superpowers/plans/2026-08-29-t8-t12-gap-closure.md`.
> 이 문서는 **결정과 그 대가**를 나른다 — 수치는 전부 이 트리에서 실측했다.
>
> 🔴 **이 세션 중 다른 Claude 세션이 같은 트리에서 작업하고 있었다**(`chahj578-07`). 조율했고,
> 그쪽 산출물은 `7620d3ad`·`698aa117`·`107cd4df`(전부 docs)다. 두 세션의 측정은 **독립적으로
> 일치했다** — 아래 초록은 양쪽이 따로 잰 값이다.

## 착수 · 종료 실측

| | 착수 `7620d3ad` | 종료 `56c0091c` |
|---|---|---|
| `Pkg.test()` | 1503 pass / **1 fail** / 1 error | **1487 pass / 0 fail / 1 error** |
| `pytest src/respec/llm_service/` | 185 passed / 4 skipped | **191 passed / 5 skipped** |

error 는 두 시점 모두 `test/runtests.jl:80` 의 Gurobi 라이선스 — 변경과 무관하다.

🔴 **pass 감소를 회귀로 읽지 말 것.** 삭제된 단언은 **44개**이고 그 분해가 중요하다:
**36 pass + 1 fail + 7 서브프로세스.** 마지막 7 은 `tools/test_policy_escalation.jl` 의 것인데
그 파일은 `runtests.jl:371` 이 **서브프로세스로** 돌려 스위트에는 단언 2개로만 보인다 — 그 손실은
pass 수에 **구조적으로 안 보인다**(그 파일 자신의 요약이 28 → 21 로 그 증거다). 여기에 새 게이트가
더해져 순증이 난다. 상류-사망 검사는 깨끗하다: 다른 모든 testset 의 수가 두 런에서 동일하다.

---

## 닫힌 것 셋

### §A-1 — 라우터가 본 OOD 를 LLM 도 본다 (`351203ed`)

`service_decide` 가 `payload["routing_kind"]` 를 싣고, `_llm_input` 이 그 값이 `"unknown:"` 으로
시작하면 **UNFAMILIAR EVENT 블록**을 렌더한다. 🔴 `payload["kind"]` 는 한 글자도 안 건드렸다
(`ood_features` 본문 4205B **바이트 동일** 확인) — surrogate 가 그 열을 그렇게 배웠다.

🔴 **계획서·다른 세션의 처방과 갈린 자리 (Ruling R1).** 둘 다 `service_decide` 에 **키워드**를
더하라고 했다. 그러지 않고 **함수 안에서 유도**했다(`routing_kind(String(nameof(typeof(truth))))`).
근거: 키워드는 *"호출자가 다른 값을 실을 수 있다"* 를 남기는데 **그것이 §A-1 결함 그 자체**다.
검증자가 확인: `policy.jl:543`(페이로드)와 `:1380`(라우터)이 같은 `truth` 에 대해 **바이트 동일한 식**.
⚠️ 대가는 유도 지점이 둘이라는 것이고, 그것을 지키는 것은 리뷰가 아니라 **기계 게이트**다 —
`test/service_decide_ships_routing_kind.jl` (2)(3) 이 같은 사건에서 두 값을 같은 절대값으로 못박는다.

게이트 둘: 파이썬은 **`_llm_input` 산출물**을 잰다(메뉴를 재는 시험은 이 변경에 구조적으로 눈이
멀다 — 메뉴는 안 바뀐다), 줄리아는 **요청 본문**을 잰다. 둘 다 필요하다: pydantic 이 선언 안 된
키를 조용히 버리는 축이 그 사이에 있다.

### §C-2 — 그 초록이 무엇의 증거가 **아닌지** (`f29292df`)

`test_live_single_channel.py` 머리말의 "이렇게 인용하지 말 것" 목록에 ⑤ 를 더했다:
`_IN_VOCAB`(`fault`·`battery`)는 T11 라우터에서 **전부 surrogate 로 가므로** 이 초록은
**프로덕션 LLM 레인이 돈다는 증거가 아니다**. 그리고 오늘 실제로 도는 모양(zone 메뉴 = `[NOOP]`,
레지스트리에서 유도)을 라이브 케이스로 더했다.
⚠️ 유료 호출은 안 했다 — 그 케이스가 **라이브에서** 초록일지는 안 쟀고, 그 사실이 시험
docstring 에 적혀 있다.

### §B-1·B-2 — novelty 축 삭제 (`46470d5a` 및 후속 셋)

`install_novelty!` · `ROUTER_EPS` · `router_enabled` · `route_verdict` 의 여덟 키가 사라졌다.
`event_descriptors_of`·`descriptors`·`drives_lane`·`router_drives`·`tool_choice_for`·
`src/safety/novelty.jl` 은 **남았다**.

🔴 **§B-2 의 처방은 실측으로 반증됐다.** 보고서 §0-B ⑳ 은 *"`tool_lane_keys_survive.jl` 에 전역
복원을 넣으면 그 1 fail 이 닫힌다"* 고 했다. 복원은 `7620d3ad` 에 들어갔고 **안 닫혔다.**
진짜 원인: 교정 JSON 이 이 트리에 **존재하고**, `route()` 가 감지기를 **게으르게** 설치하며,
`decide_all` 이 매 사건 `route()` 를 부른다 ⟹ `decide_all` 을 부르는 **모든 게이트가 설치자**이고
한 파일의 `finally` 로는 닫을 수 없다. 첫 설치자는 `runtests.jl:141` 의
`service_decide_ships_agents.jl` 이었다(복원을 넣은 파일보다 **먼저** 돈다).
**novelty 삭제만이 닫는다** — §B-1 의 예측이 맞았고 §B-2 의 처방이 틀렸다.

---

## 이 작업이 **만든** 결함들, 그리고 그것이 말해 주는 것

리뷰 다섯 번과 독립 검증 한 번이 **거짓 주석 여덟 개**를 잡았다. 동작 결함은 **0** 이었다.
🔴 **패턴이 교훈이다: 두 라운드가 각각 거짓 주장을 *다르게 거짓인* 주장으로 바꿨다.**
최종 리뷰가 그래서 *"세 번째가 있다고 가정하라"* 는 규칙을 세웠고 — 셋을 더 찾았다.

- `dashboard.html` 에 삭제된 `enabled` 를 읽는 자리가 **둘** 있었다(배지 · `enacted_by`). 그대로
  뒀으면 라우터가 실제로 몬 판이 화면에서 **"ROUTER OFF"** 로 렌더됐다.
- `test_live_single_channel.py` 의 `policy.jl:NNN` 인용이 **둘** 썩었다(하나는 첫 리뷰가, 하나는
  최종 리뷰가 잡았다). policy.jl 이 1835 → 1704 줄로 줄었다.
  🔴 **규약: 실행 파일 안에서는 줄번호가 아니라 심볼로 인용한다.**
- `regen_router_cases.sh` 가 **자기모순**이었다: 장벽 제거를 "사후에 잰다(§3절)" 로 정당화했는데
  §3 은 그것을 못 잰다고 스스로 적는다.

---

## 🔴 사용자 판단으로 올리는 것 (일부러 안 했다)

셋 다 **판단이 필요해서** 남겼고, 셋 다 **에러를 안 낸다.**

| # | 자리 | 왜 사람이 정해야 하나 |
|---|---|---|
| 1 | **`ROUTER_AXES`** (`sweep/llm_ood_eval.py`) — `{control, vocabulary_gap, novelty, none}` 인데 T11 의 실제 축은 `{control, known_kind, ood_kind, fixed}` | 이름만 고치면 **게이트의 판정이 바뀐다**. 지금 `_router_drove` 를 지탱하는 것은 `router_drives` 하나이고 그것은 게이트가 이미 본 플래그의 메아리다 = **실패할 수 없는 게이트**. 무엇을 신뢰도 축으로 다시 세울지가 설계 결정이다 |
| 2 | **§F — `router_p` 소비처** (`llm_ood_eval.py` risk-coverage · `reporting/shadow_score.py`) | T12 이후 입력이 없다. **에러 없이 빈 곡선을 낸다** — 읽는 사람은 "측정했더니 평평했다" 로 읽는다. 지울지 / `router_axis` 위에 다시 세울지 / 최소한 시끄럽게 만들지가 선택이다 |
| 3 | **`regen_router_cases.sh` §(3) `n_routed`** | `lane_reason` 이 무조건 쓰이므로 router-on 과 router-off 를 **못 가른다**. 선재 결함이라 주석에 그 무능력만 적었다. 대체 신호(`router_axis`)는 위 1과 같은 결정이다 |

⚠️ **운영:** `tools/monitor/server.jl`(PID 2269414)이 15일째 **T8 이전 코드**로 떠 있다.
데모·스윕 전에 재기동할 것. 그리고 `MacroRequest` 는 `extra=ignore` 라 **낡은 서비스는
`routing_kind` 를 조용히 버린다** — 라이브 출력에 UNFAMILIAR 블록이 있는지로 확인할 것.
