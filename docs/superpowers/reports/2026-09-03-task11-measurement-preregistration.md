# Task 11 측정 사전등록 (유료 런 **전**에 적는다)

> 2026-09-03. 계획서 `docs/superpowers/plans/2026-09-03-generated-primitive-synthesis.md` Task 11.
> 근거 실측은 `.superpowers/sdd/2026-09-03-generated-primitive-synthesis/validation-phase3.md`
> (읽기전용 검증 agent, LM 호출 0건, 스크래치 포트 8079 에서만 서비스 기동).

🔴 **왜 사전등록인가.** 이 레포는 결과를 본 **뒤에** 무엇을 쟀는지 정하다가 반복해 데였다
(`decision_acc` 의 구세대 기준, "게이트 초록 = 기계로 보장됨", ψ 항진명제). 아래 넷은 전부
**결과를 보기 전에** 결정한 것이고, 런이 어떻게 나오든 이 문서가 판정 기준이다.

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

---

## 판정 넷 (이 순서로 읽는다)

1. `wrote` 가 `true` 인가 — 모델이 코드를 쓰려 했는가 (`None` = 못 쟀다 ≠ `false` = 못 쓰겠다고 신고)
2. `registered` — `true`/`false`/`nothing` 삼상. `false` 면 `impl_rejected_why` 가 **어느 규약이** 막았는지 나른다
3. `args_from == :calls` 이고 `n_calls ≥ 1` — 🔴 **B1 배선이 라이브에서 처음 증명되는 자리**
4. `steps[1].status` — 모델이 무슨 심볼을 반환했나 (**자기신고다**, 세계 변화의 증거가 아니다 — 결정 1)

## 비용 (실측, 계획 전 감사)

`/decide` 하나당 **3(비발화) ~ 7(발화)** 유료 호출. `case_kinds("battery")=[:battery]`,
`DEMO_N` 기본 0 → `n_robot=1` → **OOD 사건 정확히 하나** → **총 ~6회**.
⚠️ `run_synthesis` 는 호출자의 `expressible` 을 **무시**하므로 비발화 사건에서도 2회가 무조건 청구된다.
사건이 하나뿐이라 여기서는 무해하지만 **스윕에서는 `2k`** 가 된다.
⚠️ `/health` 의 `calls`·`billed` 는 `_ask` 안에서만 증가해 **합성 호출을 아예 안 센다** —
지출을 그 숫자와 대조하지 말 것. 정직한 장부는 기록의 `stages` + 1 이다.

## 런 전 체크리스트

- [ ] 진행 중인 `src/respec/minted_registration.jl` 계약 수정이 착륙했는가 (부분 등록 반쪽 상태)
- [ ] `results/synth_lane_records.jsonl` 을 옆으로 치웠는가 — 기존 1행은 **Task 8 이전 모양**이고
      계획서의 `readline()` 은 그 낡은 행을 읽는다(`KeyError`). **마지막 줄**을 읽을 것
- [ ] `REQUIRE_TOOL_SYNTHESIS=1` 을 **julia 줄에** 붙였는가 — 없으면 레인이 꺼진 서비스가
      게이트를 exit 0 으로 통과하고 **조용히 빈 유료 런**이 된다(실측)
- [ ] `REQUIRE_SYNTH_MULTI_AGENT=1` 은 **붙이지 않는다** — 어떤 레인도 안 읽는 플래그로 정상 런을 막는다
- [ ] `/health` 가 `cache:False` · `synth_tool_synthesis:True` 인가
