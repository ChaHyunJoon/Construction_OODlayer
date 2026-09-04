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

🔴 **왜 사전등록인가.** 이 레포는 결과를 본 **뒤에** 무엇을 쟀는지 정하다가 반복해 데였다
(`decision_acc` 의 구세대 기준, "게이트 초록 = 기계로 보장됨", ψ 항진명제). 아래 **열둘**은 전부
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

## 결정 12 (L3) — L3 은 이 런에서 **못 잰다**

설계 §0 의 L3 판정 필드는 "정적 호출 대상 ∩ 인터페이스 ≠ ∅" 이고, 그 값이 D15 의 AST 순회에서
"이미 만드는 값" 이라고 적혀 있다. 🔴 **오늘 그것을 산출물로 내는 생산자가 없다** — 수집된
호출 집합이 `check_impl_conventions` 안에서 버려진다(진행 원장의 Task 6 deferred 항목).

그리고 `n_body_names` 는 **그것이 아니다**: `body_names` 는 agent-3 자신의 `impl_name` 하나다
(`src/respec/llm_service/synthesize.py` 의 Task 8 주석이 진실원) — 구성상 크기 ≤ 1 이고
호출 대상을 안 나른다. 이 둘을 섞어 읽으면 L3 이 공짜로 초록이 된다.

⟹ **L3 = `nothing`.** 런 뒤 `impl_code` 를 손으로 읽어 호출 이름을 세는 것은 가능하지만
**사후 수작업**이므로 이 사전등록의 판정이 아니라 **관찰 노트**로만 적는다.

## 비용 갱신 (D17)

`/decide` 하나당 **3(비발화) ~ 7(발화)** 에 **되먹임 1회당 +1**. 사건 하나짜리 런의
상한은 **8회**다.

⚠️ **`/health` 의 `calls`·`billed` 로 지출을 정산하지 말 것.** 두 이유가 겹친다 —
(a) 그 카운터는 `_ask` 안에서만 증가해 **합성 호출을 아예 안 센다**(`validation-phase3.md` §V1),
(b) `prog()` **뒤**에서 증가하므로 **캐시 히트도 센다**(`.claude/CLAUDE.md` Gotchas).
정직한 장부는 둘이다: 합성 기록의 `stages` + 1, 그리고 `~/.dspy_cache` 의 **새 항목 수**
(체크리스트 참조).

---

## 판정 다섯 (설계 §0 의 사다리 순서로 읽는다 — 결과를 보고 바꾸지 않는다)

| # | 칸 | 판정 | **어디서 읽나** |
|---|---|---|---|
| 1 | L0 | `wrote == true` (`None` = 못 쟀다 ≠ `false` = 못 쓰겠다고 신고) | `results/synth_lane_records.jsonl` 의 **마지막 줄** |
| 2 | L1 | `registered` 삼상. `false` 면 `impl_rejected_why` 가 **어느 규약이** 막았는지 나른다 | `results/task11-run.log` 의 `[minted] lane=present …` 줄. 축 분리는 **결정 10** |
| 3 | L2 | `args_from == :calls` ∧ `n_calls ≥ 1` ∧ `steps[1].status !== nothing` — 🔴 **B1 배선이 라이브에서 처음 증명되는 자리** | 같은 줄의 `args_from=` · `n_calls=` · `steps=[…]` |
| 4 | L3 | **못 잰다 → `nothing`** | 결정 12 |
| 5 | L4 | `world_delta` (결정 6·7·8). 성분별로 삼상을 따로 읽는다 | `[minted] world_delta=` 줄 + **같은 판의** `resolve=` |

`steps[1].status` 는 여전히 **모델의 자기신고**다(결정 1) — L2 의 "예외 없이 끝났다" 이지
세계 변화의 증거가 아니다. 세계 변화는 오직 5번이 답한다.

---

## 런 전 체크리스트

정본 레시피는 `.superpowers/sdd/2026-09-03-generated-primitive-synthesis/validation-phase3.md`
§V10 의 COPY-PASTEABLE 블록이다 — **여기 베끼지 않는다.** 아래는 그 블록을 돌리기 전에
성립해야 하는 조건들이다.

### A. 산출물과 코드

- [ ] 🔴 **유료 런의 차단 항목이 전부 착륙했는가.** 목록의 진실원은
      `.superpowers/sdd/2026-09-03-callable-world-interface/progress.md` 의 판정 **R19·R20·R21**
      이다(여기 베끼지 않는다). 최소한 이 둘은 명령 하나씩으로 확인된다:
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
      런 뒤가 아니라 **런 전**에 적는다.

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
- [ ] 서비스가 `/rewrite` 를 아는가: `curl -s -o /dev/null -w '%{http_code}' -X POST
      $DSPY_URL/rewrite -H 'Content-Type: application/json' -d '{}'` 가 **404 가 아닌가.**
      🔴 404 면 결정 5 는 이 런에서 `nothing` 이다 — 그 세대는 `/rewrite` 를 안 갖고 있고
      되먹임은 조용히 "왕복 실패 → 원래 거절" 로 떨어진다(task-9 보고서 §9 가 실제로 본 판).

### C. 라이브인가 재생인가

- [ ] 🔴 **DSPy 는 `~/.dspy_cache` 를 모든 인스턴스가 공유하고, `/health` 의 `calls` 는
      캐시 히트도 센다 — 과금 카운터가 아니다.** 프롬프트가 바이트 동일이면 **옛 날짜의 응답이
      재생된다**(음성 대조가 특히 위험하다). 이 레포가 써 온 판별법은 하나다:
      런 **전후**로 `find ~/.dspy_cache -type f | wc -l` 을 재서 **새 항목 수**를 기록한다.
      새 항목이 0 인데 `stages` 가 차 있으면 그 런은 **재생**이지 라이브가 아니다.
      (§V10 이 `DSPY_CACHE=0` 으로 띄우라고 적는 이유가 이것이다 — 그래도 **재고 적는다**.)

### D. 기록의 자리

- [ ] `results/synth_lane_records.jsonl` 을 옆으로 치웠는가 — 기존 행은 **Task 8 이전 모양**이고
      `readline()` 은 그 낡은 행을 읽는다(`KeyError`). **마지막 줄**을 읽을 것.
      ⚠️ `SYNTH_RECORD_LOG` 가 `""`/`"0"` 이면 기록이 **아예 안 써진다** — 그 셸에서 export 된
      적이 없는지 확인한다.
- [ ] 🔴 **런이 dspy 로 라우팅되는가**(결정 4). `DEMO_BSOC` 는 절대값이 아니라 낙폭이다.
- [ ] 판정 다섯의 산출물 둘이 **같은 런의 것**인가: `results/task11-run.log` 와
      `results/synth_lane_records.jsonl` 의 마지막 줄. 두 파일이 다른 런에서 오면 L0 과
      L1~L4 가 다른 세계의 관측이 된다.
