# Plan V1 완료 보고 — 축 1: 어휘 미달 라우터

**계획서:** `docs/superpowers/plans/2026-08-27-vocabulary-gap-router-v1.md`
**설계서(binding authority):** `docs/superpowers/specs/2026-08-27-vocabulary-indexed-router-design.md`
**브랜치:** `oracle-rebuild-night-2026-08-10` · **커밋 범위:** `81e16b70..2955924b` (10커밋)
**실행:** 2026-08-27, subagent-driven-development. 구현자 5 · 리뷰어 6 · 독립 검증 에이전트 1(opus/max).

---

## 🔴 이 보고서에서 가장 중요한 한 문장

**축 1 은 오늘 구조적으로 침묵한다.** 배포 지원집합이 `{0,1,2}` = 어휘 전체(라벨셋 33행,
macro `{0:12, 1:12, 2:9}`)이므로 `unsupported` 는 언제나 빈 목록이다.
**이 계획이 고친 것은 "발화했을 때 흐르는가" 이지 "발화한다" 가 아니다.**
축 1 로 무언가를 측정했다고 보고하기 전에 이 문장을 먼저 적을 것. 어휘가 자라는 것은 V3 이다.

---

## 무엇이 지어졌나

| 커밋 | 무엇 |
|---|---|
| `b703a987` | `psi()` 가 미등록 매크로 id 에 `KeyError`. 판정은 truthiness 가 아니라 **멤버십**(`MACRO_SPECS[0]` 은 빈 리스트라 truthiness 로 고치면 NOOP 이 죽는다) |
| `b3e9c7b0` | `select_lane -> (lane, axis, reason)`. **어휘 미달이 novelty 보다 먼저.** 고아 게이트 `test_lane_select.jl` 을 `runtests.jl` 에 배선 |
| `394779a2`·`c57f8640`·`e43df0f0` | 격상을 novelty 교정 게이트에서 분리. `router_drives()` 신설. `rt["router_axis"]` + `run_demo.jl` 화이트리스트 |
| `bdb0bdda` | 지원집합을 `/health` 에 데이터로 노출. `set(range(5))` 구세대 폴백 제거. 유도를 `_unsupported_for` 한 곳으로 |
| `f4631fcd` | R1 양방향 음성 대조 6개 |
| `52d2234d`·`49bd149e`·`2955924b` | 최종 수정 웨이브 F1~F8 |

**끝에서 끝까지 사슬**(독립 검증이 코드로 추적, 끊긴 곳 없음):
`_load_surrogate` → `_state["surro_support"]` → `_unsupported_for` → `"UNSUPPORTED:…"` →
`decide()` 파싱 → HTTP → `policy_entry` → `escalation_target` → `supported` → `select_lane` →
`rt["router_axis"]` → 결정 행 → `llm_ood_eval._router_drove` · dashboard · `[router]` 화면 줄.

---

## 🔴 계획서가 틀렸던 곳 — 실행이 잡아낸 것

사전 검증(전문: `…-preflight-verification.md`)이 **8건 REFUTED**. 그중 실행 경로를 바꾼 셋:

1. **`@testset` 안의 `const` 는 Julia 1.10 문법 에러다.** 런타임이 아니라 **파싱** 실패라 파일
   전체가 안 돌고 기존 testset 4개까지 죽는다. 계획서 테스트 코드를 그대로 썼으면 Task 2 가
   시작부터 막혔다.
2. **`import dspy_service` 직후 `_state["surro_support"]` 키가 없다**(`_load_surrogate()` 는 FastAPI
   startup 에서만 돈다). 계획서의 Task 4·5 테스트가 **구현과 무관하게 실패한다.**
3. **`tools/test_policy_escalation.jl` 에 `@testset` 이 하나도 없다.** 계획서의 "마지막 `@testset`
   뒤에 추가" 는 존재하지 않는 앵커이고, 파일이 `exit(...)` 로 끝나므로 그대로 붙이면 **죽은 코드**다.

그리고 실행 중 **가장 큰 계획서 결함**(Ruling R11):

> 계획서는 격상 게이트를 `have_det && router_enabled()` → `router_enabled()` 로 바꾸라고 한다.
> 🔴 그런데 **`router_enabled()` 자체가 `install_novelty!()` 다**(`policy.jl:109`) — 교정 JSON 이
> 없으면 `false`. 그리고 이 작업 트리에 `wm4spacecraft_manufacturing/novelty/` 는 **없다.**
> 즉 계획서가 시킨 교체는 **교정 파일 결합을 하나도 끊지 못한다.** 계획서가 스스로 내건
> 목적이 달성되지 않는다.

설계서 §3 이 요구한 것은 **별도 손잡이 `ROUTER_DRIVES`** 였다. 그래서
`router_drives() = ROUTER_MODE != "0" && POLICY != "noop"` 를 신설했다 — `install_novelty!()` 를
부르지 않는 순수한 사람 손잡이. `router_enabled()`·`have_det`·novelty 축(`policy.jl:461`)은 그대로.

---

## 🔴 "실패할 수 없는 게이트" — 이 실행에서 네 번 나왔다

이 레포의 시그니처 실패다. 각각 **음성 대조로** 잡았다.

1. **Task 3 의 첫 회귀 검사가 호출부를 안 겨눴다.** 게이트 줄을 `router_enabled()` 로 되돌려도
   새 검사 다섯이 전부 초록이었다. → `decide_all` 의 **lowered IR** 에서 호출 수를 세는
   T9/T9b 로 교체. `/tmp` 되돌림 사본에서 `n_drives=0 n_enabled=2` 로 실제 빨개짐 확인.
2. **T8/T9 는 이름을 셌지 의존을 재지 않았다.** `escalation_allowed = router_drives() &&
   install_novelty!()` 를 주입하면 18개 검사가 전부 통과한다(독립 검증 실측).
   → T9c(`install_novelty` 등장 0회) + T9d(양성 대조) 추가.
3. **`tools/test_policy_escalation.jl` 이 고아 게이트였다** — R11 회귀의 유일한 방어선이
   사람이 손으로 쳐야만 돌았다. `runtests.jl:156-166` 이 2026-08-25 에 같은 실패(R-66)를 기록한다.
   → **subprocess 로** 배선(파일이 `exit()` 로 끝나므로 `include` 하면 `Pkg.test()` 가 그 자리에서
   초록 종료하고 이후가 통째로 안 돈다).
4. 🔴 **그 배선이 곧바로 다섯 번째를 드러냈다.** `Pkg.test()` 가 `@stdlib` 없는
   `JULIA_LOAD_PATH` 를 물려줘서 게이트가 `ArgumentError: Package InteractiveUtils not found` 로
   죽고 **검사를 0개 실행한 채** 스위트는 초록이었다. → `addenv(cmd, "JULIA_LOAD_PATH" => nothing)`.
   재리뷰어가 오염된 부모 env 에서 독립 재현했다.

---

## 실측 기준선 (🔴 CLAUDE.md 와 계획서의 숫자는 낡았다)

| 명령 | 계획서/CLAUDE.md 주장 | **실측** |
|---|---|---|
| pytest `src/respec/llm_service/ wm4spacecraft_manufacturing/` (+`--ignore`) | "전부 PASS" | **3 failed / 98 passed** |
| `Pkg.test()` | "11 pass / 1 error" | **254 pass / 1 error** |
| `tools/monitor/test_lane_select.jl` | — | 36 |
| `tools/test_policy_escalation.jl` | — | 30 |
| `test/policy_macro_binding.jl` | — | 40 |
| `test/route_descriptors_survive.jl` | — | 17 |
| `test/battery_menu_lanes_agree.jl` | — | 12 |

- `Pkg.test()` 의 **1 error 는 Gurobi 라이선스 없음**이고 회귀가 아니다.
- pytest 의 **3 failed 는 `wm4spacecraft_manufacturing/smdp/test_gate_ng2.py`** 이고 이 계획 이전부터
  빨갛다. 원인(독립 검증): 그 파일 자기 픽스처가 `arms=(0,1,2,3)` 인데 `v4-3arms` 에 팔 3 이 없다
  (재번호 드리프트). 🔴 **그 게이트 자신이 "분해 불가 — 초록도 빨강도 증거가 아니다" 를 찍는다.**
  픽스처 한 줄이면 고쳐진다. V1 범위 밖이라 안 건드렸다.
- 🔴 **모든 pytest 호출에 `--ignore=src/respec/llm_service/test_propose.py`** 가 필요하다.
  그 파일은 테스트가 아니라 import 시점에 실행되는 스크립트다. ⚠️ 정정: `sys.exit(1)` 은
  **`ANTHROPIC_API_KEY` 가 없을 때만**이고, 키가 있으면 실제 POST 가 나간다(더 나쁘다).

---

## 행동 변화 — 알고 있어야 할 것

🔴 **`DEMO_ROUTER` 를 안 켠 기본 실행에서 이제 레인 선택이 돈다.** `ROUTER_MODE=="auto"` 가
예전에는 "탐지기(교정 파일)가 있으면 켠다" 였는데 `router_drives()` 는 교정 파일을 안 보므로
"켠다" 가 됐다. 교정 파일이 없어 한 번도 라우팅 안 하던 기본 데모 판이 이제 라우팅된다.
설계서 §3 이 명령하는 바다. **`DEMO_ROUTER=0` 은 여전히 막으므로 비교 실행 보호는 유지된다.**

그 변화가 **기록에 정직하게 남도록** 같이 고쳤다(F3): `route_verdict` 가 `drives_lane` 을 나르고,
`router_drives()` 가 참일 때 `reason` 이 더 이상 "gate inactive / DEMO_POLICY fixed for the run" 을
주장하지 않으며, `dashboard.html` 이 `enabled` 가 아니라 **구동 사실**을 보고, `run_demo.jl` 의
`[router]` 줄이 레인 전환 사건에서 찍힌다. 안 고쳤으면 화면이 라우터가 결정한 판에 대해
**"ROUTER off"** 를 띄웠을 것이다 — 이 레포의 "로그에 없다 ≠ 안 났다" 의 역방향.

---

## 남은 구멍 — 숨기지 않는다

1. 🔴 **`decide()` 의 파싱 단계(`dspy_service.py:789`)를 어떤 테스트도 덮지 않는다.**
   이 환경에 `OPENAI_API_KEY` 가 설정돼 있고, `decide()` 가 유료 호출을 안 하는 것은
   "아무도 `dspy.configure` 를 안 불렀다" 는 **우연** 덕이다(Ruling R9). 테스트는 `decide` 가
   파싱하는 단일 진실원(`surrogate_rank` 의 `"UNSUPPORTED:…"`)을 대신 단언한다.
   **파이썬 반쪽과 Julia 반쪽이 만나는 유일한 지점이 여기이고, 그것이 안 덮여 있다.**
2. 🔴 **`surrogate_rank` 의 `if not scorable:` 분기가 `UNSUPPORTED:` 접두사를 떨어뜨린다**
   (`dspy_service.py:493-495`). 그래서 그 경우 `/decide` 가 `unsupported: []` 를 보내고 Julia 가
   `supported=true`·`axis="none"` 으로 읽는다. 한 줄이면 닫힌다.
   ⚠️ 재리뷰 판정: **오늘 도달 불가**다 — `scorable` 이 비는 것은 NOOP 을 포함한 **어떤** 유효
   매크로도 지원집합에 없을 때뿐인데, 현행 지원집합은 `{0,1,2}` 이고 NOOP=0 이 모든 메뉴에 있다.
   현실적인 최강 미달("NOOP 만 지원")은 `:512-513` 이 잡아 규약대로 낸다. **V2 후속.**
3. **`dashboard.html` 은 기계 검사가 없다**(JS 하네스도 node 도 없다). 변경은 `var` 하나 +
   `else if` 하나로 국소적이고 재리뷰어가 legacy 분기 무손상·구세대 스트림 무영향을 읽어서
   확인했다. **사람이 라우터가 몬 스트림 하나를 브라우저로 한 번 봐 줄 것.**
4. **`rt["target"]` 은 라우터가 레인을 몰아도 기본 정책 이름에 머문다** — 진실은 이제
   `drives_lane`/`router_axis`/`enacted` 에 있고 `llm_ood_eval.py` docstring 이 그렇게 적는다.
   V2 정리 대상.
5. **스윕 게이트의 `support_measured` 경고는 `print` 이지 하드 스톱이 아니다.**
   축 1 이 발화할 수 없었던 스윕도 "ok" 로 보고된다. 사용자 결정 사항.
6. **`test_gate_ng2.py` 3 failed** — 선존, 픽스처 한 줄. 위 참조.

---

## 이 계획이 안 한 것 (설계대로)

- 축 2(conformal) — V2. 반사실 라벨이 선행조건.
- 반사실 라벨 생산자 · 재학습 자동화 · `train_macros` 도장 — V3. **경계가 실제로 움직이는가(R2)는
  V3 이 준다.**
- `src/safety/novelty.jl` 삭제 — 사용자 결정: 새 라우터를 먼저 짓고 나중에.

---

## 부록 — CLAUDE.md 정정 후보

| CLAUDE.md 주장 | 실제 |
|---|---|
| `Pkg.test()` 기준선 "11 pass / 1 error" | **254 pass / 1 error** (11 은 최상위 testset 행 수를 센 옛 숫자로 보인다) |
| `v3-4arms` (2026-08-20 절) | 레지스트리는 `v4-3arms` (설계서 부록이 이미 지적) |
| `배포 surrogate 의 지원집합은 wm_datasets.N44_PLUS78` | 죽은 상수. 현행은 `ORACLE_DATASET` (설계서 부록) |
| `require_vocab 은 소비처가 0개다` | 거짓, 6곳이 쓴다 (설계서 부록) |

전체 실측은 `…-preflight-verification.md`(793줄) · `…-postflight-verification.md`(499줄).
