# Task 11 측정 사전등록 (유료 런 **전**에 적는다)

> 2026-09-03. 계획서 `docs/superpowers/plans/2026-09-03-generated-primitive-synthesis.md` Task 11.
> 근거 실측은 `.superpowers/sdd/2026-09-03-generated-primitive-synthesis/validation-phase3.md`
> (읽기전용 검증 agent, LM 호출 0건, 스크래치 포트 8079 에서만 서비스 기동).
>
> **2026-09-04 갱신 (계획서 `docs/superpowers/plans/2026-09-03-callable-world-interface.md`
> Task 10).** 결정 1~4 는 그대로 두고 **결정 5~12** 를 더했다. 근거 실측은
> `.superpowers/sdd/2026-09-03-callable-world-interface/` 의 task-8 리뷰·task-9 보고서·
> task-4 리뷰·task-34 재리뷰와 그 원장 `progress.md` 다. 여전히 **유료 호출 0건**에서 쓴다.
> 갱신 시점 HEAD `d53a649d`.
>
> **2026-09-04 갱신 2 (같은 계획서, 판정 R36·R37).** 결정 1~11 은 그대로 두고 **결정 12 를
> 개정**했으며 **결정 13~19** 를 더했다. 런 전 체크리스트는 **C 절을 통째로 교체**하고
> A·B·D 절에 항목을 더했다. 근거 실측은
> `.superpowers/sdd/2026-09-03-callable-world-interface/wave-d-f2-review.md`(유료 런 직전 최종
> 검증) · `wave-b-review.md` · `wave-b-fix-report.md` · `wave-d-report.md`, 그리고 그 원장
> `progress.md` 의 판정 R32~R37 이다. 이 갱신도 **유료 호출 0건**에서 썼다 — 서비스를 띄우지도
> 부르지도 않았고, 캐시 DB 는 `immutable=1` **읽기 전용**으로만 열었다(결정 17).
> 갱신 시점 HEAD `4f9ec2be`.
>
> 🔴 **개정도 사전등록이다.** 결정 12 가 바뀐 것은 결과를 봐서가 아니라 그 사이에 **생산자가
> 착륙**해서다(F-2 `9922a7d9` · wave D 의 D5 `54d9f4f3`). 무엇이 왜 바뀌었는지를 그 결정 안에
> 남긴다 — 지우지 않는다. 결과를 본 뒤에 바꾸는 것은 여전히 금지다.

🔴 **왜 사전등록인가.** 이 레포는 결과를 본 **뒤에** 무엇을 쟀는지 정하다가 반복해 데였다
(`decision_acc` 의 구세대 기준, "게이트 초록 = 기계로 보장됨", ψ 항진명제). 아래 **열아홉**은 전부
**결과를 보기 전에** 결정한 것이고, 런이 어떻게 나오든 이 문서가 판정 기준이다.

🔴 **삼상 규약이 문서 전체를 지배한다:** `nothing`("못 쟀다") · `false`/`[]`("재서 없다") · 값.
"못 쟀다" 를 "0 이었다" 로 접는 순간 이 문서는 아무것도 안 지킨다.

---

## 결정 1 (R11) — Task 11 은 **세계가 바뀌었는지 못 잰다**

이것은 고칠 버그가 아니라 **설계의 성질**이다. agent-3 의 계약에 status 어휘 필드도 효과 단언도
없기 때문이다. 실측된 이유:

| 후보 관측 | 왜 답이 못 되나 |
|---|---|
| `handled` | 생성 body 면 **구성상 ~100%**. `minted_handled` 의 앞 두 연언지(`:admit` · `world_maybe_dirty`)가 이 경로에서 상수다 |
| `applied` | 생성 원시에서 **항상 `nothing`**. 탈출로는 "등록 행이 자기 status 어휘를 선언하는 것"인데 Task 8·9 는 그 필드를 **안 더했다**(실측: `WriteToolImpl` 출력 7종에 없다) |
| `world_maybe_dirty` | 생성 원시면 **무조건 `true`** — 누락 기본값이 아니라 명시 분기다 |
| `steps[i].status` | 모델이 고른 반환 심볼. 자기신고다 |
| `ran_milp` · `closed=` | 호출 **뒤에만** 찍힌다. 이 경로엔 전후 스냅샷이 없다(손으로 쓴 zone 팔에는 있다) |

**단 하나의 예외**: 모델이 `surface ∈ {"sched","milp"}` 를 선언하면 `resolve_assignments!` 가
`assignment_binding` 을 전후로 재고 `n_reassigned` 을 낸다 — 그것은 주장이 아니라 **진짜 그래프
차분**이다. 세 단서: (1) 자기신고한 surface 를 통해서만 도달한다, (2) **배정** 변화만 본다,
(3) 🔴 `n_reassigned` 은 구조화 필드가 아니라 `reason` **문자열 안의 부분문자열**이다.

> **기록용 문장**: Task 11 은 모델이 코드를 썼다는 것, 그 코드가 우리 규약을 통과해 eval 됐다는 것,
> 우리 인자 채널이 값을 실어 날랐다는 것, 그리고 그 코드가 무슨 심볼을 반환했는지를 잴 수 있다.
> **그보다 강한 주장은 현재 계측이 지지하지 않는다.**

## 결정 2 (R10) — `withheld` 버킷은 **532 이름 폭**이다. D6 로 세는 것은 다섯뿐

`impl_rejected_why` 의 `…_exists_withheld` 는 "CB 가 소유하고 export 안 된 bang 이름" 전부를
뜻한다 — CB 의 596개 bang 이름 중 **532개**이고 gensym(`#@pack_…`)과 온갖 private helper 를 포함한다.
`_rehome_robot!` 충돌은 `release_pending_assignments!` 충돌과 **바이트 동일한 사유 문자열**을 낸다.

**D6 로 세는 다섯 (이 다섯만):**

```
release_pending_assignments!
recover_stalled_teams!
resolve_schedule_wedge!
force_advance_stuck_carrier!
forbid_heavy_cargo!
```

🔴 **로그에서 `withheld` 를 보고 "D6 성립" 이라고 읽지 말 것.** 이름을 대조한다.
(분류기 자체는 건전하다 — `Base.binding_module` 이 `add_edge!`(Graphs)·`push!`(Base) 등
~30개 `using` 모듈에서 온 이름을 `imported` 로 가른다. 그 분리가 없으면 위 여섯이 전부 D6 오탐이었다.
export 된 64개는 `shown` 으로 간다. 음성 대조 셋 다 통과.)

## 결정 3 (R9) — `…_exists_withheld` 거절은 **두 관측으로 따로 적는다**

그것은 **가장 강한 D6 신호**인 동시에 **하드 등록 실패**다 — 한 런이 둘을 동시에 보여줄 수 없다
(등록이 거절되면 집행이 없다). 합쳐서 하나의 판정으로 무너뜨리지 않는다:

- **D6 축**: 위 다섯 중 하나에 충돌했나 → D6 성립(모델이 감춘 능력을 스스로 재유도했다)
- **집행 축**: 등록 실패 → `args_from`·`steps` 는 **이 런에서 못 쟀다**(`nothing`, `false` 아님)

두 축이 같은 런에서 다 초록일 수 없다는 것 자체가 설계의 귀결이지 실패가 아니다.

## 결정 4 (R12) — 런이 **dspy 로 라우팅됐는지** 먼저 확인한다

🔴 `DEMO_BSOC` 는 절대값이 아니라 **낙폭**이다. 트리거 시점(step 40~700)에 뽑힌 로봇이 SoC 0.55
아래면 `soc_after ≤ 0.1` → `routing_kind="battery"` → `surro_kinds` 안 → **surrogate 로 간다**.
그러면 **$0 을 쓰고 아무것도 안 재는데 런은 건강해 보인다.** `DEMO_BATTERY_STEPS=40,120` 이 그 창을 없앤다.


## 결정 5 (D17) — D6 의 판정 단위가 **호출**에서 **사건**으로 바뀐다

`/rewrite` 가 들어오면서 사건 하나가 agent-3 을 **최대 두 번** 부른다. 그러므로
"모델이 감춘 능력을 스스로 재유도했다"(D6)의 판정 단위는 **사건**이지 호출이 아니다.
🔴 로그에서 `withheld` 를 보고 성립이라 읽지 말 것은 그대로다 — 이름을 대조한다(결정 2).

재시도 상한 1 은 카운터가 아니라 **구조**다(`_reject_malformed` 가 즉시 반환한다) —
task-9 보고서 §6·§10 이 가짜 서비스로 실측했다. 그리고 이 채널이 **측정 가능한** 이유는
둘째 거절이 **자기 사유**를 나르기 때문이다(같은 §6-B: 첫 사유 `…impl_positional_args…` ≠
둘째 사유 `…impl_name_is_qualified…`, 첫 사유로 덮이지 않았다).

🔴 **아무것도 못 고친 rewrite 는 기록에서 세 모양으로 갈리고, 뭉치면 안 된다:**

| 기록의 모양 | 무슨 일이 일어났나 |
|---|---|
| `[minted] rewrite: 되먹임 1회 — 원래 사유=A` 가 있고 최종 `impl_rejected_why=B`(≠A) | 되먹임이 돌았고 **다른 코드**가 왔고 그것도 거절됐다 — D17 이 재려는 판 |
| 같은 줄이 있고 최종 `impl_rejected_why=A`(바이트 동일) | agent-3 이 `wrote=false`("못 고치겠다")를 냈다. 왕복 실패와 **같은 최종 사유**를 남기므로 `[minted] rewrite: 왕복 실패 …` 줄의 유무로 가른다 |
| `[minted] rewrite: 되먹임 1회` 줄 자체가 없다 | 되먹임이 **시도조차 안 됐다**(`_sl_is_rewritable` 이 false 이거나 거절이 그 자리보다 앞이다) → `nothing`, "실패" 아님 |

🔴 `spec` 이 빈 채로 나가면 agent-3 은 **명세 없이** 고쳐야 하고, 그 판의 실패는 모델이 아니라
우리 배선이다(task-9 보고서 §4·§11-1). 런 전 체크리스트가 그것을 막는다.

## 결정 6 (D18) — L4 는 `world_delta` 하나로 판정하고, **오늘은 stdout 에서 읽는다**

`handled`·`applied`·`world_maybe_dirty`·`steps.status` 는 결정 1 이 적은 이유로 여전히
답이 못 된다. **`world_delta` 만 본다.**

🔴 **그 값은 오늘 어떤 구조화 산출물에도 안 실린다.** `render_demo.jl` 은 `_m.handled` 만 읽고
결정 행은 집행 **앞**에서 닫힌다(task-8 리뷰 F1). 실측: HEAD `d53a649d` 의
`tools/monitor/render_demo.jl` 에 `world_delta` 문자열 **0건**(`/usr/bin/grep`).

⟹ **L4 판정의 산출물은 `results/task11-run.log` 이고, 읽는 방법은 stdout 파싱이다:**

* 자리: `[minted] world_delta=` 로 시작하는 **자기 줄**(`tools/monitor/enact.jl` 의 `println`).
* 그 줄이 `global_logger(…, Logging.Warn)` 을 넘는 것은 **짝지은 대조**로 확인됐다
  (task-8 리뷰 §8: `@info` stdout 0 / stderr 0 으로 삼켜짐 · `@warn` stderr 1 생존 · `println` 생존).
* 잡는 명령은 이미 레시피 안에 있다 — `2>&1 | tee results/task11-run.log` 뒤
  `/usr/bin/grep -aE "\[minted\]…"`(`validation-phase3.md` §V10). **새로 짓지 않는다.**

**삼상**: `world_delta=n/a(not measured)` = **못 쟀다**(`nothing`) · `world_delta=closed=0 …`
= **재서 0**. 🔴 두 문자열을 정규식 하나로 뭉치지 않는다.
⚠️ 로그 문구가 두 모양이다 — 성공 줄에는 `(n_binding_changed 는 하한이다)` 가 붙고 catch 줄
(`[minted] FAILED …` 뒤)에는 안 붙는다(task-8 리뷰 m4). 정규식은 둘 다 받아야 한다.

⚠️ 구조화 행(task-8 리뷰 F1 의 3줄, 판정 R19)이 유료 런 **전에** 착륙하면 결정 행에 같은 값의
**둘째 사본**이 생긴다. 둘이 갈리면 **stdout 이 정본이다** — 이 문서가 결과를 보기 전에 고른
산출물이 그것이기 때문이다. (갈렸다는 사실 자체는 결함으로 따로 적는다.)

> 🔴 **2026-09-04 갱신 2 — 그 "둘째 사본" 이 실제로 착륙했다.** wave A `963c756d` 가
> `render_demo.jl` 에 `record_world_delta!(_m)` 를 넣었고(위 "0건" 실측은 그 이전 HEAD
> `d53a649d` 에 대한 것이다), wave D 의 D5 `54d9f4f3` 가 같은 행에 `interface_calls` 를
> 더했다. **그래도 L4 의 정본은 stdout 이다** — 결과를 보기 전에 고른 것을 그대로 둔다.
> 갈리면 결함으로 적는다. 같은 행이 L3 에 대해서는 **유일한** 산출물이라는 것이 결정 14 다.

## 결정 7 (D18) — 성분 넷은 **같은 무게가 아니다**

🔴 `active` 와 `n_edges` 는 이 레포에서 **0 이외의 값을 낸 것을 아무도 본 적이 없었다**
(task-8 보고서 우려 3). 리뷰가 레시피를 만들어 셋 다 움직이는 것을 보였고
(task-8 리뷰 F3 실측: `active=2` · `n_edges=1` · `n_binding_changed=1/2`), 그 대조를
시험에 넣는 것은 판정 R19 가 유료 런 전 차단 항목으로 잡았다.

**판정 규칙**: 🔴 **양성 대조가 없는 성분의 `0` 은 "안 바뀌었다" 의 증거가 아니다.**
그 성분은 그 런에서 `nothing`("못 쟀다")으로 읽는다 — `false`("재서 없다") 가 아니다.

그러므로 런 기록은 **런 시점에 어느 성분이 양성 대조를 가졌는지**를 반드시 적는다.
판정식(재유도 가능): `test/minted_end_to_end.jl` 에 그 성분에 대해 **0 이 아닌 값**을 단언하는
줄이 있는가.

| 성분 | 오늘(HEAD `d53a649d`) 양성 대조 | 근거 |
|---|---|---|
| `closed` | ✅ 있다 | `:580-581` — 리터럴이 아니라 `length(env.cache.closed_set) - before` 재유도값과 대조하고 `== 1` 을 단언 |
| `active` | ❌ 없다 | `:608` 에 `== 0` 단언만 |
| `n_edges` | ❌ 없다 | `:609` 에 `== 0` 단언만 |
| `n_binding_changed` | ❌ 없다 | `:610` 에 `== 0` 단언만 |

🔴 **`n_binding_changed` 는 하한이다**(`assignment_binding` 의 docstring). `> 0` 은 변화를
증명하고 `== 0` 은 무변화를 증명하지 않는다 — 양성 대조가 생겨도 이 성질은 그대로다.

## 결정 8 (D18) — `world_delta` 는 body 가 아니라 **집행 봉투**를 잰다

`_issue_resume!`·`_resolve_if_needed!` 는 `CB.enact_minted!` **안**에서 돈다. 그러므로
`surface ∈ RESOLVE_SURFACES`(= `{"sched","milp"}`, `src/respec/minted_tool.jl` 이 진실원)인
판에서는 **하네스 자신의 공통 MILP 재풀이**가 사후 지문에 들어온다. 그리고
`resolve_assignments!` 의 `n_reassigned` 과 `world_delta.n_binding_changed` 는 **같은
`assignment_binding`** 을 읽는다 — 두 수가 같은 것을 센다.

**이 사전등록이 고르는 판독(코드 변경 0):**

* `resolve === :not_needed_surface` 인 판의 `world_delta` **만** "body 단독이 세계를 바꿨다"
  로 읽는다.
* `resolve === :resolved` 인 판은 **봉투 전체**의 차분이다 → L4 에 대해 `nothing` 이다.
  모델의 공로로도 우리 공로로도 적지 않는다.

두 값은 **같은 로그 줄**에 있다(`[minted] lane=present … resolve=…`), 그 옆에 `ran_milp=` 도 있다.

⚠️ 이 항목은 완전한 `PlannerEnv` 없이는 실측 불가였다 — 합성 sched 로는 재풀이가 `scene_tree`
부재로 던진다(task-8 리뷰 §CANNOT VERIFY 2). **코드 구조에서 유도한 결론이지 실측이 아니다.**
그리고 라이브에서 agent-3 이 어떤 surface 를 낼지는 유료 런 전에는 알 수 없다(프롬프트가
다섯을 가르친다). 시험 (10)(11) 은 `env_param` 을 골라 이 경로를 **일부러 피한다** —
즉 유료 런이 들어갈 계측 체제를 덮는 시험이 하나도 없다.

## 결정 9 (D13) — `needs` 는 실패의 **설명**이지 실패가 아니다

`needs != ""` 이면서 `registered == true` 인 런은 **성공한 런**이다. 그 문자열은 다음
인터페이스 확장의 입력이지 이번 런의 판정이 아니다.
삼상 유지: `needs is None` = **못 쟀다**(task-5 리뷰가 런타임으로 확인 —
`blank_synthesis_record(kind="battery")["needs"] is None`, 그리고 agent-3 의 실제 경로인
`_copy_body_fields` 는 `_BODY_FIELDS` 를 순회하므로 삼상이 끝까지 산다).

## 결정 10 (D15) — "모델이 실패했다" 와 "우리 검사기가 거절했다" 를 기록에서 가른다

`check_impl_conventions` 는 `Core.eval` **앞**에서 돈다(`src/respec/minted_registration.jl` 의
`register_minted_primitive!`: `why = check_impl_conventions(...)` 가 `Core.eval(...)` 보다
먼저다). ⟹ 거절은 더 이상 크래시가 아니라 **문자열**이고, 그 문자열이 그대로 `/rewrite` 의
되먹임이다(결정 5). 그래서 두 축을 **반드시 따로 적는다**:

| 관측 | 무엇에 대한 사실인가 |
|---|---|
| `wrote == false` (합성 기록) | **모델** — agent-3 이 못 쓰겠다고 신고했다 |
| `wrote == true` ∧ `registered == false` ∧ `impl_rejected_why` 가 `reject:` 로 시작 | **우리 검사기** — 코드는 왔고 규약이 막았다. 어느 규약인지는 `reject:` 뒤의 코드가 나른다 |
| `wrote` 가 `None` / `registered` 가 `nothing` | **못 쟀다.** `false` 아님 |
| `[minted] rewrite: 왕복 실패 …` · `rewrite:` 접두 | **서비스·전송** — 모델도 검사기도 아니다 |
| `rewrite_read:` 접두 | **우리 파서** — 받아 놓고 못 읽었다(task-9 보고서 §11-3 이 처방이 다르다고 일부러 접두를 갈랐다) |
| `[minted] FAILED (집행부가 던졌다 …)` | 등록은 통과했고 **body 가 돌다 던졌다** |

🔴 **그리고 `reject:` 가 언제나 "모델의 잘못" 은 아니다.** 우리가 광고한 것을 부른 body 도
거절되거나 죽을 수 있다 — `battery_report` 는 `BATTERY_FLEET[] === nothing` 이면 던진다
(task-3 리뷰 F1; 전제조건은 `8ca31771` 이 프롬프트에 실었다), `…_exists_withheld` 는
결정 2·3 의 자리다. ⟹ 런 뒤에 관측된 `reject:` 코드를 **하나씩** 이 축으로 분류하고,
분류가 애매하면 `nothing` 으로 남긴다. 뭉뚱그려 "모델이 또 실패했다" 로 세지 않는다.

## 결정 11 — 이 사전등록이 가리키는 **프롬프트 산출물의 신원**

이 문서가 판정하는 것은 **오늘의 프롬프트**에 대한 런이다. Task 3·4 와 그 수정 라운드가
프롬프트를 실질적으로 바꿨다(task-3+4 재리뷰 §회계, 그리고 아래를 오늘 독립 재유도했다):

| 축 | `b4db643d` | 오늘 |
|---|---|---|
| 프롬프트 줄 / 문자 | 474 / 21,471 | **526 / 26,315** |
| argpath **줄** | 35 | **86** |
| 경로를 가진 **메서드** | 30 | **32** |
| 경로가 없는 인자의 `missing: <타입>` 주석 | 없음 | **있다**(설계 §6.2) |

⟹ 런 기록에 산출물의 신원을 적는다. **재유도 명령을 적지 수를 인용하지 않는다:**

```bash
sha256sum wm4spacecraft_manufacturing/core/world_interface.json
# 2026-09-04 HEAD d53a649d 실측: 02cc38b704820e03…  ← 시험 (2) 가 바이트로 지키는 그 파일
cd src/respec/llm_service && ../../../.venv/bin/python -c \
 "import json,world_interface as WI; s=WI.build_world_interface_block(json.load(open('../../../wm4spacecraft_manufacturing/core/world_interface.json'))); print(len(s.splitlines()), len(s))"
# 2026-09-04 실측: 526 26315
```

산출물 자체의 수(JSON 을 직접 세서 얻었다): `types 67 · methods 210 · callable 186 · access 9키`.

🔴 이 수들은 **인용용이 아니라 대조용**이다. 런 시점에 다시 재고, 다르면 이 사전등록은
**다른 프롬프트**를 두고 쓴 것이므로 그 사실을 기록에 적는다.

## 결정 12 (L3) — ~~이 런에서 못 잰다~~ → **개정: 목록으로 잰다** (2026-09-04 갱신 2, R36-A)

**원문(HEAD `d53a649d`)은 "L3 = `nothing`" 이었다.** 근거는 "정적 호출 대상 ∩ 인터페이스" 를
**산출물로 내는 생산자가 없다**(수집된 호출 집합이 `check_impl_conventions` 안에서 버려진다)
였고, 그 시점에 그것은 참이었다. 🔴 **그 사이에 생산자가 착륙했다:**

* **F-2 `9922a7d9`**(판정 R32) — 교집합의 이름 우주를 `names(CB)` 에서 **산출물이 실제로
  광고하는 이름**으로 좁혔다. 실측된 효과: `SwapBattery(1,2)` 를 부르는 body 는 이제
  `String[]` 을 받는데 `:SwapBattery in names(CB)` 는 여전히 참이다(wave-d-f2-review).
* **wave D 의 D5 `54d9f4f3`** — `resolve_primitive` 의 `interface_calls`(기본값 `nothing`)가
  `enact_minted_decision!` 의 **반환 튜플 네 자리 전부**와 **결정 행**까지 간다.

⟹ **L3 은 이 런에서 잰다. 단 불리언이 아니다** — 판독 규칙은 결정 13(목록으로 읽는다) ·
결정 14(결정 행에서 읽는다) · 결정 16(이름 우주를 핀으로 고정한다)이다.

🔴 **원문의 경고 하나는 그대로 살아 있다**: `n_body_names` 는 L3 이 **아니다**. `body_names` 는
agent-3 자신의 `impl_name` 하나이고(`src/respec/llm_service/synthesize.py` 의 Task 8 주석이
진실원) 구성상 크기 ≤ 1 이며 호출 대상을 안 나른다. 이 둘을 섞어 읽으면 L3 이 공짜로 초록이 된다.

## 결정 13 (R36-A) — L3 은 **불리언이 아니라 목록**이다

값은 정렬된 문자열 목록이고 삼상이다: `nothing`(못 쟀다) · `String[]`(재서 없다) ·
비지 않은 목록. 세 상태가 서로 유도 불가능하고 셋 다 도달 가능하다는 것은 실측됐다
(wave-d-f2-review: 메모리·로그·직렬화 세 층 + 산출물 아홉 모양 프로브).

🔴 **광고된 타입 생성자도 점수를 낸다.** 줄리아에서 타입은 callable 이고 생성자 호출은 메서드
호출이므로 spec §0 L3 의 명제("기존 **함수**를 최소 하나 불렀다")를 어기지 않는다(판정 R32,
옵션 A). 그리고 순회는 **호출 자리만** 센다 — `x = VtxID`(맨 참조)는 `String[]` 이고
`VtxID(1)`(호출)만 잡힌다(같은 리뷰의 실측). 즉 "이름을 찍기만 해도" 초록이 되지는 않는다.

⚠️ **그러나 생성자 히트는 함수 호출보다 약한 증거다.** 반례가 실재한다: D5 의 대표 양성 시험
(`test/minted_end_to_end.jl` 의 (23a))의 body 는 L3 을 **전부 타입 생성자로** 받는다(실측).
"L3 초록" 이 "세계 함수를 불렀다" 를 뜻하지 않는 판이 있다는 뜻이다.

**판정 규칙(코드 변경 0):**

* 런 기록에 목록을 **원소 그대로** 적는다. 🔴 "L3 초록" 이라는 불리언은 **발견이 아니다.**
* 각 원소를 산출물의 **`methods` 블록**과 교차한다(재유도 명령):

```bash
python3 -c "import json;j=json.load(open('wm4spacecraft_manufacturing/core/world_interface.json'));\
print(sorted({m['name'] for m in j['methods']} | {a['accessor'].rstrip('()') for a in j['ambient']}))"
```

  * 교집합이 **≥1** → **"기존 함수를 불렀다"** (spec §0 의 L3 명제 성립)
  * 목록은 비지 않았는데 교집합이 **0**(전부 `types`/`subtypes` 에서 온 이름) → **"생성자만"**.
    그 판은 **L3 명제에 대해 `nothing`** 으로 적고 목록은 그대로 남긴다. `false` 가 아니다.

⚠️ **L3 은 D6 신호를 광고하지 않는다.** 결정 2 의 감춘 다섯은 광고 집합에 **하나도 없다**
(wave-d-f2-review 실측; 이 갱신 시점에 위 명령으로 `release_pending_assignments!` 부재를
재확인했다). L3 목록과 결정 2 의 다섯은 서로 **다른 것**을 재므로 한 칸으로 합치지 않는다.

## 결정 14 (R36-A) — L3 은 stdout 이 아니라 **결정 행**에서 읽는다

🔴 **`interface_calls` 는 어떤 로그 줄에도 안 실린다**(wave-d-f2-review 가 e2e 전체 출력에서
실측). 값은 반환 튜플과 `record_world_delta!` 의 **직렬화 행**으로만 간다.

⚠️ `tools/monitor/enact.jl` 의 `_rec_line` docstring 한 줄이 그 반대를 적는다. **그 문장은
틀렸다**(같은 리뷰의 Minor-1) — 여기 반복하지 않는다. 그것을 믿고 stdout 을 grep 하면
**L3 을 전량 놓친다.**

**산출물의 자리(재유도 가능):** `record_world_delta!` 는 `CB.MONITOR_RESPEC[]` 를 **제자리에서**
고치고, 그 행은 `monitor_emit!` 의 프레임에 `respec`/`respec_history` 로 직렬화된다.
`render_demo.jl` 은 그 스트림을 자기 `stream_path`(= `tools/monitor/streams/` 아래
`<model_base>__<CASE_TAG><접미사>.jsonl`)로 연다 — **경로의 진실원은 그 파일의 `stream_path`**
이고 런 끝의 `[render] DONE — … frames` 줄이 프레임 수를 찍는다.

* 읽는 법: **집행 뒤에 emit 된 프레임**(마지막 프레임이 안전하다)의 `respec_history` 에서 그
  결정을 찾아 `interface_calls` 를 본다. 결정 행 자체는 집행 **앞**에서 닫히지만 이 값은
  제자리 변이로 나중에 실린다.
* 🔴 **키의 부재**는 `null` 과 다르다 — 그것은 "이 코드 이전 세대의 산출물" 이라는 셋째 사건이다
  (`enact.jl` 의 그 자리 주석이 진실원).
* 삼상: 스트림 파일이 없거나 프레임이 0이면 **못 쟀다**(`nothing`). "L3 이 비었다" 가 아니다.

## 결정 15 (R36-A) — `zone_keys` 경고가 뜬 판의 `n=0` 은 "세계가 이미 깨끗" 이 아니다

`zone_keys` 를 `Vector{String}` 으로 주석한 body 는 바인딩에 성공하고 `(:already_clear, n = 0)`
을 내면서 **아무것도 안 바꾼다**(wave D 의 D6 실측, 네 칸 표의 ③). wave D 는 이것을
**고치지 않았고** 시끄럽게만 했다 — `[minted] ⚠️ zone_keys …` 경고 한 줄. 진짜 처방은 agent-3
프롬프트를 `Vector{Symbol}` 쪽으로 미는 것인데 그 자리는 **D19 로 바이트 동결된 `_RULES`** 라
이 라운드 밖이다(wave D 열린 항목 1, 리뷰가 그 판단에 동의).

**판정 규칙**: 🔴 **그 경고 줄이 뜬 판의 `n=0`·`:already_clear` 를 "재서 0"(`false`)으로 세지
않는다. 그 판은 L4 에 대해 `nothing` 이다.** `steps[i].status` 는 결정 1 이 적은 이유로 여전히
답이 못 된다(모델의 자기신고).

* 잡는 법: `/usr/bin/grep -a "\[minted\] ⚠️ zone_keys" results/task11-run.log`.
  그 줄은 `println` 이라 `Logging.Warn` 을 넘는다(결정 6 과 같은 근거).
* ⚠️ 같은 철자 + **없는 키** 판(④)은 HEAD 이전에도 이미 `unknown_zone_key` 를 냈다 — 그 반쪽은
  결함이 아니었고 고칠 것이 없었다(wave-d-f2-review 의 정정 (i); 원 지시가 틀렸다).

## 결정 16 (R36-A) — L3 의 **이름 우주는 디스크의 산출물**이다 → 런 전에 핀하고 해시를 적는다

F-2 이후 L3 이 점수를 주는 이름은 `wm4spacecraft_manufacturing/core/world_interface.json` 이
광고하는 것뿐이다. ⟹ **산출물이 바뀌면 L3 의 뜻이 바뀐다.** 이것은 가정이 아니라 실제 위험이다 —
리뷰 시점에 다른 세션이 그 생성기와 산출물을 편집 중이었고, 그 뒤 `4f9ec2be` 가 산출물을 다시 썼다.

🔴 **런 전에 해시를 찍어 기록에 남기고, 런 뒤에 다시 찍어 같은지 본다.** 다르면 그 런의 L3 은
**어느 이름 우주에 대한 값인지 모른다** ⟹ `nothing`.

```bash
sha256sum wm4spacecraft_manufacturing/core/world_interface.json
git status --porcelain wm4spacecraft_manufacturing/core/world_interface.json   # 비어야 한다
julia +lts --project=. -e 'include("test/world_interface_current.jl")'          # 산출물 == 코드(바이트 게이트)
```

2026-09-04 이 갱신 시점 실측(**대조용이지 인용용이 아니다**; 위 첫 두 명령을 직접 돌려 얻었다;
바이트 게이트는 이 갱신에서 안 돌렸다 — 런 전에 돌린다):
HEAD `4f9ec2be` · 작업 트리 깨끗 · `sha256 = f5258900e04498…`.

⚠️ **산출물이 없거나·못 읽거나·모양이 아니면 등록은 그대로 성공하고 L3 만 `nothing` 이 된다**
— `[]` 가 아니다. 아홉 모양(파일 없음·디렉토리·깨진 JSON·타입 오류·전부 빈 배열 …)에 대해
전부 `nothing` 이고 throw 0건임이 실측됐다(wave-d-f2-review). ⚠️ 그리고 `_world_interface_path()`
는 레포 레이아웃에 묶여 있어 패키지를 다른 곳에서 로드하면 L3 이 전 구간 `nothing` 이 된다
(같은 리뷰의 ledger 4) — 런은 레포 안에서 돈다는 전제를 기록에 적는다.

## 결정 17 (R36-B) — 🔴 과금·재생 판별식을 **캐시 DB 의 `store_time`** 으로 바꾼다

**이 결정은 이 문서의 옛 체크리스트 C 항목(`find ~/.dspy_cache -type f | wc -l` 의 전후 차분)을
폐기하고 대체한다.** 그 방법은 세 층 전부에서 신뢰할 수 없다는 것이 **실측됐다** —
`-shm`/`-wal` 은 DB 를 **열기만 해도** 바뀌고 `cache.db` 는 **WAL 체크포인트만으로도** 바뀐다.
둘 다 유료 호출 **0건**인 세션에서 실제로 일어났다(wave-d-f2-review §"내 유료 호출: 0건").

**정본은 캐시 DB 안이다.** 읽기는 `immutable=1` 로 하면 원본을 한 바이트도 안 건드린다:

```bash
python3 - <<'PY'
import glob, os, sqlite3, datetime as dt
tot = 0; mx = ma = None
for shard in sorted(glob.glob(os.path.expanduser("~/.dspy_cache/*/cache.db"))):
    c = sqlite3.connect("file:%s?immutable=1" % shard, uri=True)
    n  = c.execute("select count(*) from Cache").fetchone()[0]
    s_ = c.execute("select max(store_time)  from Cache").fetchone()[0]
    a_ = c.execute("select max(access_time) from Cache").fetchone()[0]
    c.close(); tot += n
    if s_ and (mx is None or s_ > mx): mx = s_
    if a_ and (ma is None or a_ > ma): ma = a_
print("rows", tot, "max_store", dt.datetime.fromtimestamp(mx), "max_access", dt.datetime.fromtimestamp(ma))
# 런 뒤에는 T = 런 시작 epoch 로 이것도 센다:
#   select count(*) from Cache where store_time  > T   (새 항목 = 실제 모델 호출)
#   select count(*) from Cache where access_time > T   (히트 = 재생)
PY
```

🔴 **판정 규칙 — 뜻이 서비스의 `cache` 레짐에 따라 갈린다.** 그 레짐은 내가 친 기동 줄이 아니라
`/health` 가 말한다(체크리스트 B):

| `/health` 의 `cache` | 런 뒤 관측 | 어떻게 읽나 |
|---|---|---|
| `False`(§V10 레시피의 레짐) | 새 store 0 · 새 access 0 | **기대값.** 이 런은 공유 캐시를 읽지도 쓰지도 않았다 ⟹ **재생이 아님**이 확정된다. 🔴 그러나 이것은 **과금 장부가 아니다** — 캐시가 꺼져 있으면 라이브 호출도 행을 안 남긴다. 지출 장부는 합성 기록의 `stages`(+되먹임 1회당 +1)뿐이다 |
| `False` | 새 store > 0 **또는** 새 access > 0 | 🔴 **모순이다.** 캐시는 모든 인스턴스가 공유하므로 켜진 레짐의 다른 프로세스·다른 세션이 쓰고 있다는 뜻이다. 런을 라이브로 읽기 **전에** 그것부터 가른다 |
| `True` | `count(store_time > T) > 0` | **라이브.** 그 수가 이 런이 실제로 낸 모델 호출 수다 |
| `True` | store 0 인데 `max(access_time) > T` | **재생.** 옛 날짜의 응답이 돌아왔다 — 오늘의 모델을 잰 것이 아니다 |
| `True` | store 0 · access 0 인데 `stages` 가 차 있다 | **못 쟀다.** 기록과 계수기가 어긋난다 — 라이브로 읽지 않는다 |

🔴 **절대 행 수를 계약으로 삼지 않는다.** 이 갱신을 쓰며 위 코드를 **직접 돌렸다**(읽기 전용):
16 샤드 · **행수 5152** · `max(store_time) = max(access_time) = 2026-09-01 00:44:49`.
리뷰가 **같은 방법**으로 잰 값은 **5408 행**(날짜는 같다) — 🔴 **행 수가 재현되지 않았다.**
행이 줄었는데 `store_time` 은 안 움직였으므로 **추가가 아니라 삭제**이고, 유력한 원인은
diskcache 의 크기 기반 축출이다(각 샤드에 `Settings` 표와 count/size 트리거가 있는 것을 확인했다).
⟹ **계약은 "런 전후를 같은 방법으로 잰 차분" 이고, 그중 날카로운 것은 `max(store_time)` 이다**
— 축출은 행을 줄일 수는 있어도 `store_time` 을 앞으로 밀 수는 없다.

⚠️ `immutable=1` 은 **체크포인트된 본 DB 만** 읽고 `-wal` 은 안 본다. 오늘 16 샤드 전부에서
WAL 포함 계수와 immutable 계수가 **같음**을 확인했다(샤드 셋을 스크래치로 복사해 대조 — 원본
미접촉). 그래도 런 전후는 **반드시 같은 방법**으로 잰다.

🔴 `/health` 의 `calls`·`billed` 가 과금 계수기가 아닌 이유는 `.claude/CLAUDE.md` 의 Gotchas 가
소유한다 — **여기 다시 적지 않는다**(이 문서 "비용 갱신" 절도 그것을 가리킨다).

⚠️ 시험 스위트는 이 계수기를 오염시키지 않는다: 히트 계수 미끼 서버를 `DSPY_URL` 에 심고
전체 `Pkg.test()` 를 돌려 실서비스 접촉 **0**(미끼 히트 0 · 8077 `connect()` 0 · 모든 connect 가
루프백)을 실측했고, 미끼 자체의 비-0 대조도 했다(wave-d-f2-review 의 D2 판정). 즉 런 전에
스위트를 돌려도 T 이후의 새 행은 그 스위트의 것이 아니다.

## 결정 18 (R36-C) — 프롬프트는 이제 **순위를 주장하지 않는다** ⟹ 모델의 선택이 측정 대상이다

인자당 경로 순서는 이 계획에서 두 번 갈렸고 **두 번째가 순위를 통째로 없앴다**(판정 R33).
근거는 둘 다 **측정**이다:

1. "정밀도 등급" 휴리스틱이 실제 키 조성과 **역상관**이었다 — 완벽히 정밀한 원이 강등되고 섞인
   원이 승격됐다(wave-b-review 가 살아 있는 `PlannerEnv` 에서 실측).
2. `AbstractID` 를 내는 아홉 경로의 **선언된 산출 타입이 9/9 동일**하다 — 선언은 "이 경로가 어떤
   구상 id 를 내는가" 에 대해 **0비트**를 나른다(wave-b-fix-report §1).

상한은 4 → 12 로 올라가 **오늘 아무것도 안 자른다**(절단기가 아니라 트립와이어이고, 물면
게이트가 빨개진다). ⟹ **모든 `AbstractID` 인자가 아홉 경로를 전부, 사전순으로, 순위 없이 본다.**

🔴 **그러므로 아홉 중 무엇을 고르는가가 이제 측정 대상의 일부다.** 낮은 정밀도의 원을 고른 body 는
**우리가 자른 결과가 아니라 모델의 선택**이다. 런 기록에 body 가 실제로 쓴 경로를 적는다
(`impl_code` 를 읽어 얻으므로 **사후 관찰 노트**이지 이 사전등록의 판정이 아니다).

⚠️ **조성 비율을 상수로 인용하지 않는다.** 두 보고서가 다 그렇게 적는다 — 그 비율은 보드와 함대
크기의 함수다. 인용하려면 그 런의 env 에서 다시 재고 어떻게 쟀는지 적는다.

⚠️ **프롬프트는 "이 목록은 순위가 아니다" 라고 말하지 못한다** — 그 문장이 들어갈 자리는 D19 로
동결된 `_RULES` 안이고 이 라운드는 그 파일을 안 건드렸다. 모델이 첫 줄을 추천으로 읽을 가능성은
남아 있고, **그것도 이 런이 처음 재는 것**이다.

**프롬프트의 신원은 결정 11 과 같은 규약으로 — 재유도 명령을 적지 수를 인용하지 않는다:**

```bash
sha256sum wm4spacecraft_manufacturing/core/world_interface.json
cd src/respec/llm_service && ../../../.venv/bin/python -c \
 "import json,world_interface as WI; s=WI.build_world_interface_block(json.load(open('../../../wm4spacecraft_manufacturing/core/world_interface.json'))); print(len(s.splitlines()), len(s))"
python3 -c "import json;j=json.load(open('wm4spacecraft_manufacturing/core/world_interface.json'));\
print({k:len(v) for k,v in j.items()})"
```

🔴 **결정 11 의 표에 박힌 수(526 줄 / 26,315 자 등)는 이 프롬프트에 대해 낡았다** — R33 이
argpath 줄 수를 바꿨기 때문이다. 그 표는 이제 "무엇을 대조하라" 는 뜻으로만 읽고, 값은 위
명령이 낸다. (이 갱신 시점에 둘째 명령을 직접 돌린 값 = **606 줄 / 29,660 자**, HEAD `4f9ec2be`.
🔴 대조용이다 — 런 시점에 다시 재고, 다르면 **다른 프롬프트**를 두고 쓴 사전등록임을 기록에 적는다.)

## 결정 19 (R36-D / R37) — `hot_swap_robot!` 은 **안 쟀다**: 그 성공은 증거가 아니다

`swap_battery!` 의 조용한 거짓 성공은 **고쳐졌다**(C1/R34, `f522cc5e`): 로봇이 아닌 id 에
`status = :battery_swapped` · `soc_before = nothing` 을 돌려주던 판이 사라졌고, `swap_battery!` 와
`_apply_battery_swap!` **둘 다** "그 노드가 실제로 로봇인가" 로 문지기를 좁혔으며 구별되는
`:not_a_robot` 이 생겼다. 삼상이 산다: `:battery_swapped` · `:no_robot`(노드가 없다) ·
`:not_a_robot`(노드는 있는데 로봇이 아니다). 게이트는 `test/swap_battery_rejects_non_robot.jl`.

🔴 **`hot_swap_robot!` 은 같은 모양의 `has_vertex`-만 문지기를 그대로 갖고 있고, 이 라운드는
그것을 고치지도 재지도 않았다**(판정 R37 — 자리는 `src/respec/replace_robot.jl` 의
`hot_swap_robot!` 이다; 줄번호로 적지 않는다). wave B fix 는 "뒤에서 `pop_spare!`·재홈잉을 하므로
거짓 **성공**이 나기는 더 어렵다" 고 적었지만 🔴 **그것은 추론이지 측정이 아니다.**

**판정 규칙**: 🔴 **런의 body 가 `hot_swap_robot!` 를 부르면 그 함수가 낸 성공 status 를 "세계가
바뀌었다" 의 증거로 세지 않는다. 그 판은 L4 에 대해 `nothing` 이다**(못 쟀다 — "안 바뀌었다"가
아니다). `world_delta` 가 **비-0** 이면 그것은 별개의 관측이므로 결정 6·7·8 의 규칙대로 그대로
적는다(그 축은 이 문지기를 안 지난다).

* 잡는 법: `impl_code` 와 L3 목록에서 그 이름을 찾는다. 🔴 그 이름은 산출물의 `methods` 에
  **광고돼 있다**(이 갱신 시점에 확인) — 즉 모델이 부를 수 있고, 부르면 L3 점수까지 받는다.

## 비용 갱신 (D17)

`/decide` 하나당 **3(비발화) ~ 7(발화)** 에 **되먹임 1회당 +1**. 사건 하나짜리 런의
상한은 **8회**다.

⚠️ **`/health` 의 `calls`·`billed` 로 지출을 정산하지 말 것.** 두 이유가 겹친다 —
(a) 그 카운터는 `_ask` 안에서만 증가해 **합성 호출을 아예 안 센다**(`validation-phase3.md` §V1),
(b) `prog()` **뒤**에서 증가하므로 **캐시 히트도 센다**(`.claude/CLAUDE.md` Gotchas).
정직한 장부는 합성 기록의 `stages`(+되먹임 1회당 +1) 하나다.
🔴 **`~/.dspy_cache` 의 "새 항목 수" 를 파일 개수로 세던 옛 방법은 폐기됐다 — 결정 17 이
그 자리를 대체한다**(캐시가 꺼진 레짐에서는 라이브 호출도 행을 안 남기므로, 그 계수기는
과금 장부가 아니라 **재생 오염 통제**다).

---

## 판정 다섯 (설계 §0 의 사다리 순서로 읽는다 — 결과를 보고 바꾸지 않는다)

| # | 칸 | 판정 | **어디서 읽나** |
|---|---|---|---|
| 1 | L0 | `wrote == true` (`None` = 못 쟀다 ≠ `false` = 못 쓰겠다고 신고) | `results/synth_lane_records.jsonl` 의 **마지막 줄** |
| 2 | L1 | `registered` 삼상. `false` 면 `impl_rejected_why` 가 **어느 규약이** 막았는지 나른다 | `results/task11-run.log` 의 `[minted] lane=present …` 줄. 축 분리는 **결정 10** |
| 3 | L2 | `args_from == :calls` ∧ `n_calls ≥ 1` ∧ `steps[1].status !== nothing` — 🔴 **B1 배선이 라이브에서 처음 증명되는 자리** | 같은 줄의 `args_from=` · `n_calls=` · `steps=[…]` |
| 4 | L3 | `interface_calls` **삼상 목록**(결정 13). 산출물 `methods` 와 교차해 "생성자만" 판을 가른다 | 🔴 **결정 행** — 모니터 스트림 `.jsonl` 의 `respec_history`(결정 14). **stdout 아님** |
| 5 | L4 | `world_delta` (결정 6·7·8). 성분별로 삼상을 따로 읽는다 | `[minted] world_delta=` 줄 + **같은 판의** `resolve=` |

`steps[1].status` 는 여전히 **모델의 자기신고**다(결정 1) — L2 의 "예외 없이 끝났다" 이지
세계 변화의 증거가 아니다. 세계 변화는 오직 5번이 답한다.

🔴 **5번(L4)을 `nothing` 으로 떨어뜨리는 판이 셋 있고, 셋 다 미리 정해 뒀다:**
`resolve === :resolved`(결정 8) · `[minted] ⚠️ zone_keys` 경고가 뜬 판(결정 15) ·
body 가 `hot_swap_robot!` 를 부른 판(결정 19). 그리고 4번(L3)은 산출물 해시가 런 전후로 갈리면
`nothing` 이다(결정 16).

---

## 런 전 체크리스트

정본 레시피는 `.superpowers/sdd/2026-09-03-generated-primitive-synthesis/validation-phase3.md`
§V10 의 COPY-PASTEABLE 블록이다 — **여기 베끼지 않는다.** 아래는 그 블록을 돌리기 전에
성립해야 하는 조건들이다.

### A. 산출물과 코드

- [ ] 🔴 **유료 런의 차단 항목이 전부 착륙했는가.** 목록의 진실원은
      `.superpowers/sdd/2026-09-03-callable-world-interface/progress.md` 의 판정 **R19·R20·R21**
      이다(여기 베끼지 않는다). ⚠️ **R21 은 그 뒤 R33 이 철회했다** — 정밀도 순위 자체가 없어졌다
      (결정 18). 그 항목을 차단 항목으로 다시 세우지 말 것.
      최소한 이 둘은 명령 하나씩으로 확인된다:
      · `/usr/bin/grep -n -A4 'const SYNTH_LANE_KEYS' tools/monitor/policy.jl` 에 `"mechanism"`
        이 있는가 — 없으면 결정 5 의 `spec` 이 빈 채로 나가고 **모델이 아니라 우리 배선을 잰다**
        (2026-09-04 실측: 열넷 중 없다).
      · `/usr/bin/grep -n 'world_delta\.' test/minted_end_to_end.jl` 이 `active`·`n_edges`·
        `n_binding_changed` 에 대해 **0 이 아닌 값**을 단언하는 줄을 내는가 — 결정 7 의 표를
        그때 다시 채운다(2026-09-04 실측: 셋 다 `== 0` 뿐).
- [ ] `world_interface.json` 이 **오늘 재생성**됐는가 —
      `julia +lts --project=. tools/gen_world_interface.jl` 뒤
      `git status --porcelain wm4spacecraft_manufacturing/core/world_interface.json` 이 **비었는가**.
      🔴 낡은 스키마를 받은 모델의 실패는 기록에서 **모델의** 실패로 남는다.
- [ ] **결정 11 의 두 명령을 돌려 신원을 기록에 적었는가**(sha256 + 렌더 줄/문자 수).
      런 뒤가 아니라 **런 전**에 적는다. 🔴 결정 11 의 표에 박힌 수는 **R33 이후 낡았다** —
      값은 명령이 내고, 오늘의 대조값은 **결정 18** 이 갖고 있다.
- [ ] 🔴 **스위트의 빨강 둘이 커밋으로 착륙했는가**(판정 R35). `test/render_lane_uses_llm_agent.jl`
      (`UndefVarError: record_world_delta!` — 🔴 하필 **유료 런이 쓰는 렌더 레인의 게이트**다) ·
      `test/minted_registration.jl` (26)(스위트 안에서만 빨간 전역 오염). 둘 다 이 계획이 만든
      상속 결함이고, 리뷰 시점에 다른 세션이 고치는 중이었지만 **미커밋이었다**
      (2026-09-04 이 갱신 시점에도 `git status` 가 두 파일을 `M` 으로 낸다 — 실측).
      확인 명령: `git status --porcelain test/render_lane_uses_llm_agent.jl test/minted_registration.jl`
      가 비고, `julia +lts --project=. -e 'using Pkg; Pkg.test()'` 의 실패 집합이 **Gurobi 하나**로
      줄었는가. ⚠️ 기준선은 트리마다 다르다 — 총계를 인용하지 말고 **실패 집합**을 본다
      (BASE/HEAD 둘 다 `1 failed · 2 errored` 였음이 wave-d-f2-review 의 실측이다).
- [ ] 🔴 **산출물을 핀했는가**(결정 16). `sha256sum wm4spacecraft_manufacturing/core/world_interface.json`
      을 **런 전에** 기록에 적고, `git status --porcelain` 이 그 경로에 대해 비었는지 보고,
      `julia +lts --project=. -e 'include("test/world_interface_current.jl")'` 로 산출물==코드를
      확인한다. **런 뒤에 다시 찍어 같은지 본다** — 다른 세션이 그 생성기를 편집 중이었던 전례가
      있고, 갈리면 그 런의 L3 은 어느 이름 우주의 값인지 모른다.

### B. 서비스 — 200 은 아무것도 뜻하지 않는다

- [ ] 🔴 **`/health` 200 은 세대 도장이 아니다.** 08-30/08-31 기동 uvicorn **다섯**이 사흘째
      200 을 냈고 그중 어느 것도 시험 대상 코드를 갖고 있지 않았다.
      판정은 `ps -p <pid> -o lstart` × `git log -1 --format=%ad -- src/respec/llm_service/` 이고,
      **정본 판정기는 `src/respec/llm_service/generation.py` 의 `check_health` 하나다**
      (셸 진입점은 `tools/require_current_service.sh`). 🔴 **그 판정식을 여기 다시 적지 않는다 —
      부른다.** 반드시 `REQUIRE_TOOL_SYNTHESIS=1` 을 얹어 부른다(그것이 없으면
      플래그 꺼진 서비스가 `OK ok exit=0` 으로 통과한다 — §V10 의 음성 대조 실측).
- [ ] `REQUIRE_TOOL_SYNTHESIS=1` 을 **julia 줄에** 붙였는가 — 없으면 레인이 꺼진 서비스가
      게이트를 exit 0 으로 통과하고 **조용히 빈 유료 런**이 된다(실측).
- [ ] `REQUIRE_SYNTH_MULTI_AGENT=1` 은 **붙이지 않는다.**
      🔴 **전제가 갈렸다.** `.claude/CLAUDE.md` 는 "합성 레인은 `TOOL_SYNTHESIS=1`
      `SYNTH_MULTI_AGENT=1` **둘 다** 일 때만 돈다" 고 적고 그것이 이 문서를 여는 근거였지만,
      **D8 이 단일 agent 레인을 삭제한 뒤로 그 문장은 이 세대에 대해 거짓이다**:
      레인 스위치는 `synthesize.synthesis_enabled()`(= `TOOL_SYNTHESIS == "1"`) 하나이고,
      `run_synthesis` 에는 분기가 없으며, `SYNTH_MULTI_AGENT` 는 `dspy_service` 의
      `_synth_multi_agent_stamp()` 가 `/health` 에만 싣는 **세대 도장**이다(그 함수의 docstring 이
      진실원). 요구하면 정상 런이 `FAIL flag_off` 로 막힌다(§V10 실측).
      ⚠️ 살아 있는 위험 자체는 그대로다 — **레인이 꺼진 서비스에서 관측한 "합성이 안 터진다" 는
      모델에 대한 사실이 아니다.** 그것을 막는 것은 바로 위의 `REQUIRE_TOOL_SYNTHESIS=1` 이다.
- [ ] `/health` 를 **직접 읽어** `cache:False` · `synth_tool_synthesis:True` 인가
      (내가 친 기동 줄이 아니라 서비스가 자기 레짐을 말하게 한다).
- [ ] 🔴 **서비스가 `/rewrite` 를 라우팅하는가.** 무료 읽기로 확인한다(핸들러를 안 태운다):
      `curl -s $DSPY_URL/openapi.json | python3 -c "import sys,json;print(sorted(json.load(sys.stdin)['paths']))"`.
      **실측(2026-09-04, wave-d-f2-review):** 그 시점 8077 에 살아 있던 것은 **09-03 세대**이고
      라우트가 `['/decide','/health','/macro']` — **`/rewrite` 가 없었다.**
      ⟹ 라우트가 없으면 그것은 "이 세대는 되먹임을 안 한다" 가 아니라 **낡은 서비스**의 징후다.
      바로 위 항목의 정본 판정기(`check_health` / `tools/require_current_service.sh`)로 세대를
      가르고 **현행 세대로 다시 띄운 뒤** 이 검사를 통과시킨다. 그러고도 없으면 결정 5 는 이 런에서
      `nothing` 이고, 되먹임은 조용히 "왕복 실패 → 원래 거절" 로 떨어진다(task-9 보고서 §9 가 실제로 본 판).
      ⚠️ 그 세대 의존은 유료 0건 보호막이기도 했다 — 현행 세대로 띄우는 순간 그 우연한 보호는
      사라지고, 스위트가 실서비스에 안 닿는 것은 **루프백 배선** 덕분이 된다(wave-d-f2-review D2).

### C. 라이브인가 재생인가

- [ ] 🔴 **파일 개수·바이트로 판별하지 않는다 — 그 방법은 폐기됐다**(결정 17).
      `-shm`/`-wal` 은 DB 를 **열기만 해도**, `cache.db` 는 **WAL 체크포인트만으로도** 바뀐다.
      둘 다 유료 0건 세션에서 실제로 관측됐다.
- [ ] 🔴 **결정 17 의 스니펫을 런 전(T 를 적어 두고)·런 후에 한 번씩 돌렸는가.**
      `immutable=1` 읽기 전용이라 캐시를 안 건드린다. 기록에 남길 것: `rows` ·
      `max(store_time)` · `max(access_time)` · `count(store_time > T)` · `count(access_time > T)`.
      **전후를 반드시 같은 방법으로** 잰다.
- [ ] 🔴 **판정은 `/health` 의 `cache` 레짐과 짝지어 읽는다 — 결정 17 의 표가 정본이다.**
      §V10 레시피는 `DSPY_CACHE=0` 으로 띄우므로 기대값은 "새 store 0 · 새 access 0" 이고,
      그때 이 계수기는 **과금 장부가 아니라 재생 오염 통제**다. 그 레짐에서 새 항목이 **보이면**
      그것은 다른 프로세스가 같은 캐시를 쓰고 있다는 뜻이다(캐시는 전 인스턴스 공유).
- [ ] ⚠️ **절대 행 수를 계약으로 삼지 않는다** — 축출이 행을 줄인다(결정 17 이 실측을 적는다).
      `stages` 와 계수기가 어긋나면 **못 쟀다**로 적고 라이브로 읽지 않는다.

### D. 기록의 자리

- [ ] `results/synth_lane_records.jsonl` 을 옆으로 치웠는가 — 기존 행은 **Task 8 이전 모양**이고
      `readline()` 은 그 낡은 행을 읽는다(`KeyError`). **마지막 줄**을 읽을 것.
      ⚠️ `SYNTH_RECORD_LOG` 가 `""`/`"0"` 이면 기록이 **아예 안 써진다** — 그 셸에서 export 된
      적이 없는지 확인한다.
- [ ] 🔴 **런이 dspy 로 라우팅되는가**(결정 4). `DEMO_BSOC` 는 절대값이 아니라 낙폭이다.
- [ ] 🔴 **L3 의 산출물 자리가 열렸는가**(결정 14). 런 끝의 `[render] DONE — … frames` 가
      **0 이 아닌가**, 그리고 그 스트림 `.jsonl`(경로의 진실원은 `render_demo.jl` 의
      `stream_path`)의 **마지막 프레임**에 `respec_history` 가 있고 그 결정 항목에
      `interface_calls` 키가 있는가. 키가 **없으면** 그것은 이 코드 이전 세대의 산출물이라는
      셋째 사건이고, 프레임이 0이면 L3 은 **못 쟀다**(`[]` 아님).
- [ ] 판정 다섯의 산출물 **셋**이 같은 런의 것인가: `results/task11-run.log`(L1·L2·L4) ·
      `results/synth_lane_records.jsonl` 의 마지막 줄(L0) · 모니터 스트림 `.jsonl` 의 마지막
      프레임(L3). 셋 중 하나라도 다른 런에서 오면 사다리의 칸들이 **다른 세계의 관측**이 된다.
