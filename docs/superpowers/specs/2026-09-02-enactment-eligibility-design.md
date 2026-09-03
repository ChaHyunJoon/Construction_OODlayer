# 집행 자격과 폴백 — 결정 2·3 설계 (2026-09-02)

> 범위: `enact_minted!` 의 **게이트 (1)** 하나와, 그 게이트를 통과한 행이 `handled` 로
> 번역되는 자리 하나. 그 둘 말고는 안 건드린다.
> 선행: 결정 1(공통 MILP 재풀이)은 `6de80454` 로 들어왔다 — 이 문서는 그 위에 선다.

---

## 0. 오늘의 사실 (전부 코드에서 읽었다, 추측 없음)

🔴 **이 표를 읽는 법(2026-09-03 T8 이 못박는다).** 표는 원래 **이 설계를 시작할 때**
(`6de80454` 위)의 사실로 적혔고, 그 뒤 이 레인(T0.5·T1·T2·T3+4·T5·T6·T7)이 그중 몇 행을
실제로 바꿨다. 갈린 행에는 **🔀** 를 붙이고 착수 시점의 사실과 **오늘의 사실을 같은 칸에**
적는다 — 지나간 사실을 지우지 않고 옆에 놓는 것이 이 문서의 관용구다.
🔴 **자리는 줄번호가 아니라 이름으로 가리킨다** — 이 레인에서 `enact.jl` 의 줄번호 인용이
**같은 밤에 두 번** 낡았고, 낡은 뒤에는 엉뚱한 코드를 가리켰다.

| 사실 | 자리 |
|---|---|
| 🔀 **착수 시점**: 게이트가 `reach == "composed"` 가 아니면 `:deferred` 로 돌아섰다. **오늘 그 게이트는 없다**(결정 2 = 이 문서가 만든 변경) — `reach === nothing`(못 쟀다)만 `:deferred` 이고, `reach != "composed"` 는 `sanctioned = false` 로 기록되며 `:admit_unsanctioned` 로 굴린다 | `src/respec/minted_tool.jl` 의 `enact_minted!` 단계 (1)(2) |
| 🔀 **착수 시점**: verdict 는 셋이었다 — `:admit` · `:reject` · `:deferred`. **오늘은 넷이다** — `:admit_unsanctioned` 가 더해졌고(결정 2), 그중 집행 계열 둘의 정본 집합이 `ENACTED_VERDICTS` 다 | `src/respec/minted_tool.jl` 의 `enact_minted!` docstring 표 |
| 🔀 `handled` 는 **네 연언지**의 논리곱이다. **오늘 그 정의를 소유하는 것은 함수 하나**다(T7 이 인라인 식을 추출했고 손베낀 복사본은 전부 지웠다). 첫 연언지는 `:admit` 리터럴이 아니라 `CB.minted_handled_verdict_ok`(= `ENACTED_VERDICTS`)이고 나머지 셋은 안 바뀌었다 — 🔴 식을 여기 베끼지 않는다 | `tools/monitor/enact.jl` 의 `minted_handled` |
| 프로덕션 소비자는 `.handled` **하나만** 읽는다 | `tools/monitor/render_demo.jl` 의 `policy_producer` (`_m.handled && return nothing`) |
| 알파벳 19, 집행 가능 8. `release_pending_assignments`·`forbid_heavy_cargo`·`resolve_schedule_wedge` 는 재풀이 표면(`sched`/`milp`) | `wm4spacecraft_manufacturing/core/primitive_registry.json`, `minted_tool.jl` 의 `RESOLVE_SURFACES` |
| 파이썬은 `reach` 와 body 의 불일치를 **이미 기록한다 — 강제는 안 한다** (`reach_matches_body`) | `src/respec/llm_service/synthesize.py:962-965` |
| F5 실측: agent-3 가 **이미 조합한 body** 에 `reach="needs_primitive"` 를 붙였다. 모자란다고 한 것은 원시가 아니라 agent-2 가 요구한 **우선순위 정렬**이었다 | `src/respec/llm_service/synthesize.py:1195-1200` |

🔴 마지막 줄이 이 변경의 **유일한 근거**다. 게이트는 "body 가 조합됐는가" 를 재려고
있는데, 실제로 읽고 있는 것은 "**모델이 조합됐다고 스스로 말했는가**" 다. 그 둘은
실측에서 이미 갈렸다.

---

## 1. 결정 (사용자가 이미 내린 것 셋)

- **D1** 게이트를 연다: `reach=="composed"` **OR** (모든 이름이 해석되고 모든 원시가 집행 가능).
- **D2** `reach != "composed"` 인데 굴린 행은 **별도 verdict** 로 남긴다 — "모델은 부족하다고
  했는데 우리가 굴렸다" 가 기록에 있어야 한다.
- **D3** 그 행에서도 기본 복구 폴백은 건너뛴다(`handled=true`).

---

## 2. 설계

### 2-1. D1 은 **코드를 더하는 변경이 아니라 빼는 변경**이다

`enact_minted!` 의 (3)(4) 단계가 이미 D1 의 조건 그 자체다:

- (3) `resolve_primitive(n) === nothing → :reject` — "모든 이름이 해석된다"
- (4) `p.enactable || → :reject` — "모든 원시가 집행 가능하다"
- (5)(6) 인자 판정·바인딩도 그대로 남는다 → 실패하면 `:reject` = **세계 무접촉** = 폴백 정상 작동

그러므로 D1 은 `reach == "composed" || return _r(:deferred, ...)` 한 줄을 지우고 **아래
단계들이 판정하게 두는 것**이다. 조건을 새로 짜지 않는다(두 벌이 되면 갈린다).

### 2-2. 그래도 `:deferred` 는 남아야 한다 — 두 원인으로

```julia
synth === nothing        && return _r(:deferred, "no synthesis record")
reach === nothing        && return _r(:deferred, "reach missing — 합성 레인이 값을 안 실었다")
```

`reach === nothing` 은 "레인이 안 돌았다/못 쟀다" 이지 "모델이 부족하다고 했다" 가 아니다.
🔴 삼상을 이상으로 뭉개지 않는다(spec §9-2) — **못 쟀다**를 **아니라고 했다**로 접으면
D2 의 새 verdict 가 두 사건을 뭉쳐 세게 된다.
(`enact.jl` 이 자기 층에서도 이 갈래를 조기 반환으로 막고 있지만, `enact_minted!` 는
프로브·시험이 직접 부르므로 **자기 층에서도** 막아야 한다.)

### 2-3. D2: 새 verdict 는 `:admit_unsanctioned`

```julia
sanctioned    = (reach == "composed")
admit_verdict = sanctioned ? :admit : :admit_unsanctioned
```

- **`:admit` 과 같은 것을 뜻한다**(불렀고 끝까지 갔다). 다른 것은 **누가 허락했는가** 뿐이다.
- 🔴 **던진 경로(`catch` 안의 `_r(:admit, ...)`, `minted_tool.jl:970`)도 같이 바꾼다.** 안 바꾸면
  "모델이 부족하다고 한 body 가 세계를 절반 고치고 던졌다" 가 정상 `:admit` 으로 기록된다 —
  정확히 D2 가 남기려는 행이 그 자리에서 사라진다.
- reason 이 근거를 나른다: `"unsanctioned(reach=needs_primitive, missing=<missing_primitive>)"`.
  `missing_primitive` 는 이미 synth 에 있다(`SYNTH_LANE_KEYS` 아홉 중 하나).

**대안으로 안 고른 것** — `verdict=:admit` 을 두고 `sanctioned::Bool` 필드를 더하기.
버린 이유: 소비자가 `verdict` 만 읽고 `sanctioned` 를 안 읽으면 그 행이 **조용히**
정상 admit 으로 집계된다. 사용자의 요구는 "기록에 있어야 한다" 이고, 필드는 안 읽히지만
verdict 는 로그 한 줄과 모든 단언이 이미 읽는다. 🔴 새 심볼은 기존 소비자를 **빨갛게**
만든다 — 그것이 이 선택의 값이다(조용한 통과보다 시끄러운 실패).

### 2-4. D3: `handled` 는 verdict 집합으로 판정한다

```julia
# src/respec/minted_tool.jl
const ENACTED_VERDICTS = (:admit, :admit_unsanctioned)   # "불렀다" 계열
minted_handled_verdict_ok(v::Symbol) = v in ENACTED_VERDICTS
```

```julia
# tools/monitor/enact.jl — 🔀 오늘 이 두 줄은 `minted_handled` 안에 있다(T7 이 추출했다)
local handled = CB.minted_handled_verdict_ok(r.verdict) && r.world_maybe_dirty &&
                (r.resume !== :failed) && !resolve_failed
```

🔴 **나머지 세 연언지는 그대로다.** 게이트는 **넓어지기만** 한다 — 이것이 결정 1 때
`resolve_failed` 를 더할 때 쓴 그 규칙이고, 여기서도 같다. 새 verdict 는 첫 연언지만
넓히고, 세계·프론티어·재풀이 안전장치 셋은 하나도 안 푼다.

### 2-5. 기록 (D2 의 "있어야 한다" 를 실제로 있게 하는 자리)

1. `[minted]` 로그 줄은 이미 `verdict=` 와 `reach=` 를 **둘 다** 찍는다(`enact.jl` 의
   `enact_minted_decision!` 이 내는 `[minted] lane=present` 줄).
   새 verdict 는 그 줄에 자동으로 나타난다 — 새 println 을 더하지 않는다.
2. 🔴 그러나 `NOT handled` 줄과 요약 프로브는 `verdict === :admit` 을 **식으로 베낀 자리**가
   셋 있다(§4 R2). 그 셋이 새 verdict 를 모르면 요약표가 "굴렸는데 안 굴렸다" 고 적는다 —
   (a) 에서 방금 고친 것과 **같은 실패 모양**이다(공허가 요약표에서 결과처럼 읽혔다).

---

## 3. 범위 밖 (일부러 안 한다)

- **`:reject` 행은 그대로 `:reject` 다.** 모델이 `needs_primitive` 라 했고 이름도 실제로
  알파벳 밖이면 그것은 **모델이 옳았던 행**이다. 새 verdict 를 안 붙인다 — 교차표
  `verdict × reach` 가 그 칸을 이미 센다.
- **`bind_primitive_args` 의 필수 kwarg 구멍은 안 고친다**(§4 R1). 다른 레인의 범위다
  (`test/payload_reprice_install.jl:150-158` 이 그렇게 못 박았다).
- **`expressible`·L2 발화·되먹임**은 안 건드린다. 이것은 집행부 한 자리다.
- **기본 복구 사슬 자체**는 안 건드린다.

---

## 4. 위험 — 넷, 전부 이름 붙여서 남긴다

**R1 (🔴 가장 큰 것) 알려진 구멍의 통행량이 는다.**
집행 중 **예외가 나면** `enact_minted!` 의 `catch` 가 `partial = true` 로 적고
(`minted_tool.jl` 의 `enact_minted!` 안 `catch`), `world_maybe_dirty = touched || partial` 이 참이 되어
`handled = true` 가 된다 — **세계를 한 바이트도 안 건드리고 던진 경우에도.** 그러면
`render_demo.jl` 의 `policy_producer` 가 기본 복구 사슬을 통째로 건너뛰고 그 OOD 사건은 **이미 소비돼**
다시 오지 않는다 = 성공과 구별되지 않는 미복구.

🔴 그 예외를 내는 자리를 **여덟 개 원시에서 전부 읽었다**(2026-09-02 실측, 추측 없음).
인자 문제로 **첫 편집 전에 던지는** 원시는 둘이고, 나머지 여섯은 kwarg 에 전부 기본값이 있다:

| 원시 | 던지는 조건 | 예외 | 자리 |
|---|---|---|---|
| 🔀 `forbid_heavy_cargo` | `agent` 를 **안 주면** (착수 시점엔 유일하게 기본값 없는 kwarg 였다) | **착수 시점** `UndefKeywordError`. **오늘은 안 던진다**(T0.5/T6): `agent` 에 기본값이 생겨 status `:missing_agent` 로 돌아서고 세계는 무접촉이다 | `cargo_ban_primitive.jl` 의 `forbid_heavy_cargo!` 단계 (0) |
| 🔀 `release_pending_assignments` | `faulted` 와 `agent` 를 **둘 다** 주면 | **착수 시점** `ArgumentError`. **오늘은 안 던진다**(T0.5/T6): status `:both_scopes` · `released = 0` · 스케줄 무접촉 | `reassign.jl` 의 `release_pending_assignments!` 첫 판정 |

🔴 **둘째 줄이 이 위험을 가설에서 실측으로 바꾼다.** `release_pending_assignments` 는
F7 에서 mild 레인이 **실제로 조합해 낸 그 원시**이고, 레지스트리의 `mechanism` 산문이
모델에게 *"passing both raises an error, so name at most one"* 이라고 **경고까지 하고 있다**
— 경고가 필요하다는 것은 그 실수가 도달 가능하다는 뜻이다. 그리고 `needs_primitive` 를
낸 모델은 인자를 잘못 채웠을 확률이 더 높다.

오늘은 `reach=="composed"` 행만 그 자리에 닿는다. 게이트를 열면 `needs_primitive` 행도 닿는다.

🔴 **닫힌 것은 위 두 입력 모양뿐이고, R1 의 일반형은 그대로 열려 있다.** `world_maybe_dirty`
가 "세계가 편집됐다" 가 아니라 "**던졌다**" 를 뜻하기 때문에, **첫 편집 전에 던지는 어떤
원시든** `handled=true` 로 기본 복구 사슬을 삼킨다 — 위 표의 둘은 그 일반형의 사례 둘이었을
뿐이다. 실측(독립 검증, `9006bdcd`): body `["translate_whole_build"]` + `staging_circles` 없는
env → `partial=true`, `world_maybe_dirty=true`, **`handled=TRUE`** 인데 **세계는 한 바이트도 안
변했다**. ⟹ 이 위험은 **미해결**이고, 일반형 수선(`bind_primitive_args` 의 필수 kwarg 검사,
또는 `world_maybe_dirty` 의 의미 자체)은 사용자 결정 대기 중이다.

→ 완화 선택지는 §7-2 에 셋으로 적었다. 🔴 어느 쪽을 고르든 T5 는 **새 verdict 행의
`steps[].status === :threw` 비율**을 센다 — 그 숫자가 이 항목의 사후 검증이다.

**R2 `handled` 식이 세 벌 복사돼 있다.**
`tools/monitor/enact.jl` 의 `minted_handled`(정본) · `tools/probes/probe_minted_body_enacts.jl:129` ·
`test/payload_reprice_install.jl:178`. 🔴 뒤의 둘은 **이미 낡았다** — 셋 다 결정 1 의
`!resolve_failed` 가 빠진 세 연언지다. `forbid_heavy_cargo` 의 surface 는 `milp` 이고
`RESOLVE_SURFACES` 안이므로, 그 시험의 던지는 판은 이제 재풀이를 거친다 = 복사본과
프로덕션이 **오늘 이미 갈렸을 수 있다**(미측정 — T0 에서 잰다).
→ 완화: `CB.minted_handled_verdict_ok` 를 도입하는 김에 세 벌을 전부 그 함수로 바꾼다.

**R3 망가진 `reach` 값도 이제 집행된다.**
`"Composed"`·`"unknown"` 같은 값은 `reach === nothing` 이 아니므로 통과해 `:admit_unsanctioned`
가 된다. 이것은 **의도한 것**이다 — D1 의 규칙은 "자기신고가 아니라 body 를 믿는다" 이고,
읽을 수 없는 자기신고는 신고가 없는 것과 같다. reason 이 그 리터럴을 그대로 적으므로
기록에서 `needs_primitive` 와 구별된다.

**R4 결정 1 의존.** body 가 배정 간선을 떼고 아무도 재배정하지 않는 사고는 `6de80454`
가 막는다. 이 변경은 그 커밋 **뒤에만** 안전하다 — 되돌리면 R4 가 되살아난다.

---

## 5. 되돌리기

게이트 한 줄과 `handled` 한 줄이다. `git revert` 로 원상복구되고, 되돌린 뒤 남는 것은
`ENACTED_VERDICTS` 상수 하나(무해)와 새 시험들(그 시험들은 되돌린 세계에서 정당하게 빨개진다).

---

## 6. 태스크 — 시간 추정 포함

⏱ **총 3.75 – 5.5 시간** (T0.5 포함) (Julia 재컴파일이 지배적이다. 스위트 한 판이 수 분이고,
`minted_tool_enacts.jl` 은 서비스·MILP 를 안 쓰므로 그중 싼 편이다.)

| # | 태스크 | 추정 | 되돌릴 수 있나 |
|---|---|---|---|
| T0 | 기준선 측정 | 25 – 40분 | — (측정만) |
| T0.5 | **R1 (B) 수선 — 막고 연다** (§8) | 45 – 60분 | 쉽다 |
| T1 | 게이트 열기 + 새 verdict (TDD) | 50 – 70분 | 쉽다 |
| T2 | `handled` 가 새 verdict 를 받는다 | 30 – 40분 | 쉽다 |
| T3 | 복사된 `handled` 식 세 벌 정리 | 25 – 35분 | 쉽다 |
| T4 | 프로브 요약표에 verdict·sanctioned 열 | 20 – 30분 | 쉽다 |
| T5 | 재측정 + R1 숫자 | 30 – 50분 | — (측정만) |

---

### T0 — 기준선 (25 – 40분)

🔴 **먼저 잰다.** 이 레포에서 기준선은 트리마다 다르고, HEAD 는 다른 레인의 수술로
일부러 빨간 자리가 있다. 안 재고 시작하면 T1 의 빨강이 내 것인지 남의 것인지 못 가른다.

- [ ] **S1** 남의 진행부터 본다
```bash
git log --since=6.hours --oneline; git status --short | grep -v '^ D'
```
- [ ] **S2** 관련 시험 셋의 오늘 상태를 파일로 남긴다
```bash
julia --project -e 'include("test/minted_tool_enacts.jl")'      2>&1 | tail -30
julia --project -e 'include("test/payload_reprice_install.jl")' 2>&1 | tail -30
julia --project -e 'include("tools/monitor/test_minted_wiring.jl")' 2>&1 | tail -30
```
- [ ] **S3** R2 를 실제로 잰다 — `payload_reprice_install.jl` 의 구멍 시험에서 `r.resolve` 를
  찍어 본다. `:resolved` 가 아니면 그 파일의 세 연언지 복사본은 **오늘 이미 거짓**이다.
- [ ] **S4** 세 결과를 `docs/superpowers/reports/2026-09-02-eligibility-baseline.md` 에 붙인다.
  (커밋하지 않는다 — T5 에서 대조로 쓴다.)

### T1 — 게이트 열기 + 새 verdict (50 – 70분)

**Files:** `src/respec/minted_tool.jl` (게이트 · `_r` 두 자리 · docstring 표),
`test/minted_tool_enacts.jl` (명제 (1) 재작성)

- [ ] **S1 실패하는 시험을 먼저 쓴다** — `test/minted_tool_enacts.jl` 의 `(1)` 을 통째로 바꾼다.
```julia
@testset "(1) reach=needs_primitive 여도 body 가 조합돼 있으면 집행한다" begin
    # 🔴 자기신고가 아니라 body 를 믿는다(F5 실측: agent-3 가 이미 조합한 body 에
    #    needs_primitive 를 붙였다 — synthesize.py:1195).
    fake = (staging_circles = Dict{Symbol,Any}(),)   # :no_staging 으로 첫 줄에서 돌아선다
    r = CB.enact_minted!(fake, nothing,
                         _synth(reach = "needs_primitive", names = ["translate_whole_build"]))
    @test r.verdict === :admit_unsanctioned          # 굴렸다, 그러나 허락은 없었다
    @test length(r.steps) == 1 && r.steps[1].status === :no_staging
    @test occursin("needs_primitive", r.reason)      # 사유가 자기신고를 그대로 인용한다
    @test r.undo === :none

    # 같은 body 를 composed 로 신고하면 verdict 만 갈린다 — 나머지는 바이트 동일이다.
    r2 = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r2.verdict === :admit
    @test [(s.name, s.status) for s in r2.steps] == [(s.name, s.status) for s in r.steps]
    @test r2.applied === r.applied && r2.world_maybe_dirty === r.world_maybe_dirty

    # 🔴 못 쟀다 ≠ 아니라고 했다. reach 가 없으면 예전처럼 deferred 다.
    r3 = CB.enact_minted!(fake, nothing, _synth(reach = nothing, names = ["translate_whole_build"]))
    @test r3.verdict === :deferred
    @test isempty(r3.steps)

    # 🔴 게이트가 열려도 (3)(4)(6) 은 그대로다 — 자격 없는 body 는 여전히 세계 무접촉이다.
    @test CB.enact_minted!(fake, nothing,
              _synth(reach = "needs_primitive", names = ["teleport_the_build"])).verdict === :reject
    @test CB.enact_minted!(fake, nothing,
              _synth(reach = "needs_primitive", names = ["swap_battery"])).verdict === :reject
    @test CB.enact_minted!(nothing, nothing,
              _synth(reach = "needs_primitive", names = ["restage_all_blocked"])).world_maybe_dirty === false
end
```
- [ ] **S2 빨간지 확인한다**
`julia --project -e 'include("test/minted_tool_enacts.jl")'` → `(1)` 에서 `:deferred !== :admit_unsanctioned`.
- [ ] **S3 최소 구현** — `src/respec/minted_tool.jl:891-893` 을 바꾼다
```julia
    reach = _synth_get(synth, "reach", nothing)
    # 🔴 못 쟀다(nothing)만 deferred 다. "모델이 부족하다고 했다"는 **집행을 막지 않는다** —
    #    게이트가 재려는 것은 body 가 조합됐는가이고, 그것은 아래 (3)(4)(6) 이 판정한다.
    #    자기신고를 믿었을 때 무엇을 잃었는지: synthesize.py:1195 (F5 실측).
    reach === nothing && return _r(:deferred, "reach missing — 합성 레인이 값을 안 실었다")
    sanctioned = (reach == "composed")
    admit_verdict = sanctioned ? :admit : :admit_unsanctioned
    unsanctioned_note = sanctioned ? "" :
        " — 🔴 unsanctioned(reach=$(reach), missing=$(something(_synth_get(synth, "missing_primitive", nothing), "n/a"))): " *
        "모델은 부족하다고 했는데 body 는 조합돼 있어 굴렸다"
```
  그리고 `:admit` 리터럴 **두 자리**를 `admit_verdict` 로, reason 끝에 `unsanctioned_note` 를 붙인다:
  `minted_tool.jl:970`(던진 경로) 과 `:999`(정상 경로).
- [ ] **S4 새 상수** — `ENACTED_VERDICTS` 와 `minted_handled_verdict_ok` 를 `enact_minted!` 위에 둔다(§2-4 코드).
- [ ] **S5 docstring 표에 네 번째 줄** (`minted_tool.jl:839-843`)
```
| `:admit_unsanctioned` | `:admit` 과 같다 — 다만 모델이 `reach != "composed"` 라고 신고한 body 였다 |
```
- [ ] **S6 초록 확인** → `include("test/minted_tool_enacts.jl")`
- [ ] **S7 변이시험** — `admit_verdict` 를 `:admit` 로 고정 → `(1)` 이 빨개지는지 보고 되돌린다.
  (이 파일의 규약이다: 명제마다 변이로 빨강을 확인한다.)
- [ ] **S8 커밋**
```bash
git add src/respec/minted_tool.jl test/minted_tool_enacts.jl
git commit -m "결정 2: 게이트가 자기신고 대신 body 를 본다 — 굴린 needs_primitive 는 :admit_unsanctioned 다"
```

⏱ 50 – 70분 — 편집은 20분, 나머지는 변이시험 3회 × 재컴파일.

### T2 — `handled` 가 새 verdict 를 받는다 (30 – 40분)

**Files:** `tools/monitor/enact.jl` (오늘의 `minted_handled`) + docstring, `tools/monitor/test_minted_wiring.jl`

- [ ] **S1 실패하는 시험** — `test_minted_wiring.jl` 에 절을 더한다
```julia
@testset "(9) unsanctioned 도 폴백을 건너뛴다 — 그러나 로그가 그 사실을 적는다" begin
    r, out = capture_out(() -> enact_minted_decision!(
        THROW_ENV, nothing, _dec(_sl(reach = "needs_primitive", names = BODY))))
    @test r.verdict === :admit_unsanctioned
    @test r.handled === true                    # D3: 반쯤 고쳐진 세계 위에 폴백을 안 얹는다
    @test occursin("verdict=admit_unsanctioned", out)
    @test occursin("reach=needs_primitive", out)
    @test !occursin("NOT handled", out)
    # 🔴 나머지 세 연언지는 안 풀렸다: 재개가 실패하면 unsanctioned 여도 폴백이 돈다.
    r2, out2 = capture_out(() -> enact_minted_decision!(
        (nope = 1,), nothing, _dec(_sl(reach = "needs_primitive", names = BODY))))
    @test r2.handled === false && occursin("NOT handled", out2)
end
```
- [ ] **S2 빨간지 확인** (`r.handled === false` 로 떨어진다)
- [ ] **S3 구현** — `enact.jl` 의 `handled` 식을 §2-4 의 두 줄로 바꾼다.
- [ ] **S4 docstring** — `enact_minted_decision!` 의 `handled` 문단에 한 줄 더한다:
  *"🔴 첫 연언지는 `:admit` 하나가 아니라 `ENACTED_VERDICTS` 둘이다(2026-09-02 결정 2·3).
  나머지 셋은 그대로 — 게이트는 넓어지기만 한다."*
- [ ] **S5 초록 확인 + 변이** (`minted_handled_verdict_ok` → `=== :admit` 로 되돌려 빨강 확인)
- [ ] **S6 커밋**

⏱ 30 – 40분.

### T3 — 복사된 `handled` 식 세 벌 (25 – 35분)

- [ ] **S1** `tools/probes/probe_minted_body_enacts.jl:129` · `:136` · `:138` 을
  `CB.minted_handled_verdict_ok(r.verdict)` 로 바꾼다. (그 파일은 이미 "식으로 베끼지 않는다" 를
  주석으로 적어 뒀는데 `:129` 에서 스스로 어겼다 — 그 주석을 참으로 만든다.)
- [ ] **S2** `test/payload_reprice_install.jl:178` 도 같은 함수로. 🔴 T0-S3 에서 잰 값이
  `:resolved` 가 아니었다면 `@test handled === true` 는 **틀린 단언**이므로, 잰 값으로
  고치고 그 사실을 주석에 적는다("이 시험의 복사본은 결정 1 뒤로 낡아 있었다").
- [ ] **S3** 두 파일 실행 → 초록 확인 → 커밋.

⏱ 25 – 35분. R2 가 실제 갈림이면 +15분.

### T4 — 요약표에 열을 올린다 (20 – 30분)

🔴 (a) 의 교훈 그대로다: **판정에 쓰는 값은 요약표의 열이어야 한다.** 세부 출력에만 있으면
요약표가 공허를 결과처럼 적는다.

- [ ] **S1** `probe_cargo_ban_end_to_end.jl` 절 A 와 `probe_minted_body_enacts.jl` 요약 줄에
  `verdict` · `sanctioned`(= `reach=="composed"`) · `threw_steps`(= `:threw` 인 단계 수) 세 열을 더한다.
- [ ] **S2** 판정 순서 맨 앞에 공허를 둔다 — 공허면 GREEN/RED 를 아예 안 찍는다.
  🔀 **오늘의 사실**: T7 이 그 판정을 **두 갈래**로 갈랐다. `probe_cargo_ban_end_to_end.jl` 의
  `_void_kind` / `_VOID_LABEL` 이 `VOID_NOSTEP`(아무 단계도 안 불렸다)와
  `VOID_UNAPPLIED`(단계는 불렸는데 `applied=false` — 잴 수 있는 편집이 0)를 구별한다.
  이 계획이 적은 한 갈래(`steps` 가 비었나)는 그중 앞의 것 하나뿐이었고, 실측에서 그
  갈래만으로는 `VOID` 가 한 번도 안 탔다. (`probe_minted_body_enacts.jl` 은 아직 갈리지 않은
  `⚪ VOID` 한 벌이다.)
- [ ] **S3** 커밋.

⏱ 20 – 30분.

### T5 — 재측정 (30 – 50분)

- [ ] **S1** `probe_minted_body_enacts.jl` 두 판(composed / needs_primitive 같은 body)을 돌린다.
  두 판의 `steps` 가 **바이트 동일**이고 verdict 만 갈리는지가 이 변경의 비퇴화 조건이다.
- [ ] **S2 R1 의 숫자** — `needs_primitive` 행에서 `:threw` 단계 비율을 센다. 0 이 아니면
  그 수치와 예외 종류를 보고에 적는다(그 숫자가 `bind_primitive_args` 수선의 값을 정한다).
- [ ] **S3** 전체 스위트 한 판 → T0 기준선과 대조. **차이가 있으면 그 파일 이름을 전부 적는다.**
- [ ] **S4** `docs/superpowers/reports/` 에 보고를 쓰고 커밋.

⏱ 30 – 50분 (전체 스위트가 지배적).

---

## 7. 결정됨 (사용자, 2026-09-02)

1. **verdict 이름 = `:admit_unsanctioned`.** 중립적이고 "누가 옳았는가" 를 말하지 않는다 —
   그 판정은 `verdict × reach × reach_matches_body` 교차표가 나중에 낸다.
2. **R1 = (B) 원시 국소 수선, 그리고 T1 앞에 놓는다(막고 연다).** 근거 셋:
   ① 사례가 가설이 아니라 mild 레인이 실제로 조합하는 원시(`release_pending_assignments`)에 있고,
   ② 실패 모양이 이 레포에서 최악이며(사건이 소비돼 다시 안 온다),
   ③ 뒤에 놓으면 T5 의 `:threw` 비율이 구멍 섞인 값이 되어 게이트 개방의 효과를 못 잰다.
   → **T0.5** 로 태스크에 들어갔다. (A) 바인더 수선은 여전히 범위 밖이다.

---

## 8. T0.5 — R1 (B): 인자 오류를 예외 대신 status 로 (45 – 60분)

**Files:** `src/respec/cargo_ban_primitive.jl:140` · `src/respec/reassign.jl:194-200` ·
`src/respec/minted_tool.jl` (두 표) · `test/minted_tool_enacts.jl` (명제 (11) 커버리지)

🔴 **왜 새 status 두 개인가**(`:unknown_agent` 재사용이 아니라). spec §9-2 — "인자를 **안 줬다**"
와 "**틀린 것을 줬다**" 는 다른 사건이고, 둘을 한 status 로 접으면 T5 가 R1 의 발생률을 못 센다.
표 두 줄씩 더 쓰는 것이 그 구별의 값보다 싸다.

🔴 **반환 모양은 이미 섞여 있어도 된다.** `_step_status` 는 `hasproperty(out, :status)` 를
**맨 먼저** 본다(`minted_tool.jl:797`) — `release_pending_assignments!` 가 평소 `Vector` 를
돌려주면서 조기 반환에서만 NamedTuple 을 내는 것은 `:unknown_agent`(`reassign.jl:207`) 가
이미 쓰는 관용구다.

🔴 **프로덕션 호출자 전수 확인 (실측 2026-09-02).** `release_pending_assignments!` 호출 17곳을
전부 읽었다 — `faulted` 와 `agent` 를 **동시에 주는 호출자는 하나도 없다**. 그러므로 예외를
status 로 바꾸는 것은 오늘 어떤 호출자의 동작도 바꾸지 않는다(그 자리는 지금 예외뿐이다).

- [ ] **S1 실패하는 시험을 먼저 쓴다** — `test/minted_tool_enacts.jl` 끝에 절을 더한다
```julia
@testset "(17) 인자 오류는 예외가 아니라 status 다 — 폴백을 삼키지 않는다" begin
    # 🔴 R1. 예외로 나가면 partial=true → world_maybe_dirty=true → handled=true 가 되어
    #    **세계를 한 바이트도 안 건드린 판이** 기본 복구 사슬을 삼킨다(사건은 이미 소비됐다).
    env = (cache = CB.PlanningCache(), sched = CB.OperatingSchedule())

    # (a) forbid_heavy_cargo 를 agent 없이 부른다 (여덟 중 유일하게 기본값 없던 kwarg)
    r = CB.enact_minted!(env, nothing,
                         _synth(names = ["forbid_heavy_cargo"], params = Dict{String,Any}()))
    @test r.steps[1].status === :missing_agent      # 던지지 않는다
    @test r.partial === false
    @test r.world_maybe_dirty === false             # ⟹ handled=false ⟹ 폴백이 정상으로 돈다
    @test r.applied === false

    # (b) release_pending_assignments 에 faulted 와 agent 를 둘 다 준다
    r2 = CB.enact_minted!(env, nothing,
             _synth(names = ["release_pending_assignments"],
                    params = Dict{String,Any}("faulted" => "R1", "agent" => "R2")))
    @test r2.steps[1].status === :both_scopes
    @test r2.partial === false
    @test r2.world_maybe_dirty === false

    # 🔴 음성 대조: "안 줬다" 와 "틀린 걸 줬다" 는 **다른 status** 다(spec §9-2).
    r3 = CB.enact_minted!(env, nothing,
             _synth(names = ["forbid_heavy_cargo"],
                    params = Dict{String,Any}("agent" => "no_such_robot")))
    @test r3.steps[1].status !== :missing_agent     # :unknown_agent 또는 :no_schedule
end
```
- [ ] **S2 빨간지 확인** — 오늘은 `:threw` 이고 `partial === true` 다.
`julia --project -e 'include("test/minted_tool_enacts.jl")'`
- [ ] **S3 `forbid_heavy_cargo!` 를 고친다** (`src/respec/cargo_ban_primitive.jl:140-142`)
```julia
function forbid_heavy_cargo!(env; agent::AbstractString = "", n::Real = 1)
    a = String(agent)
    # 🔴 (0) 안 준 인자 먼저. 기본값이 없으면 Julia 가 호출 경계에서 `UndefKeywordError` 를
    #     던지고, 집행부의 `try` 가 그것을 `partial=true` 로 적어 **세계를 안 건드린 판이**
    #     `handled=true` 로 기본 복구 사슬을 삼킨다(R1). 거절 = 세계 무접촉 = 폴백 정상.
    #     `:unknown_agent` 로 접지 않는다 — "안 줬다" 와 "틀린 걸 줬다" 는 다른 사건이다.
    isempty(a) && return (status = :missing_agent, agent = a, n = n)
```
  (나머지 본문은 그대로. `n` 은 요청값 그대로 싣는 규약을 지킨다.)
- [ ] **S4 `release_pending_assignments!` 를 고친다** (`src/respec/reassign.jl:198-200`)
  — `throw(ArgumentError(...))` 를 지우고 같은 자리에서 status 로 돌아선다
```julia
    # 🔴 던지지 않는다 (R1, 2026-09-02). 이 판정은 **첫 편집 전**이라 세계가 증명 가능하게
    #    깨끗한데, 예외로 나가면 `partial=true → world_maybe_dirty=true → handled=true` 가
    #    되어 아무것도 안 한 판이 기본 복구 사슬을 삼킨다. 레지스트리 산문이 모델에게
    #    "name at most one" 이라고 경고까지 하고 있다 = 이 실수는 도달 가능하다.
    #    ⚠️ 호출자 17곳을 전수 확인했다 — 둘을 동시에 주는 호출자는 없다(동작 변화 없음).
    #    🔴 `string` 이지 `String` 이 아니다 — `String(::RobotID)` 는 메서드가 없어서
    #    가장 흔한 `faulted` 타입에서 이 반환문 자체가 `MethodError` 로 나간다(= 예외의
    #    이름만 바뀌고 R1 은 안 닫힌다). 2026-09-02 독립 검증이 실측했고 T6 이 고쳤다.
    if faulted !== nothing && agent !== nothing
        return (status = :both_scopes, faulted = string(faulted),
                agent = string(agent), released = 0)
    end
```
- [ ] **S5 두 표에 넉 줄** (`src/respec/minted_tool.jl:246-254`, `:394-403`)
```julia
    "forbid_heavy_cargo"          => Set([:banned, :unknown_agent, :no_schedule, :invalid_n, :missing_agent]),
    "release_pending_assignments" => Set([:released_none, :unknown_agent, :both_scopes]),
```
  (`SILENT_SUCCESS_STATUSES` 와 `WORLD_UNCHANGED_STATUSES` **둘 다**. 🔴 불변식
  `WORLD_UNCHANGED ⊆ SILENT_SUCCESS` 를 지킨다 — 둘 다 첫 편집 전 반환이므로 양쪽에 들어간다.
  `WORLD_UNCHANGED` 의 `release_pending_assignments` 행에 `:released_none` 은 여전히 **넣지 않는다**.)
- [ ] **S6 명제 (11) 의 `quiet` 목록에 둘을 더한다** (`test/minted_tool_enacts.jl:369-371`)
```julia
             ("forbid_heavy_cargo", :missing_agent),
             ("release_pending_assignments", :both_scopes),
```
- [ ] **S7 초록 확인 + 변이시험** — S3 의 `= ""` 를 지우면 (17)(a) 가, S4 의 `return` 을
  `throw` 로 되돌리면 (17)(b) 가 각각 빨개지는 것을 확인하고 되돌린다.
- [ ] **S8 관련 시험 셋을 돌린다** (이 둘의 기존 소비자)
```bash
julia --project -e 'include("test/forbid_heavy_cargo.jl")'
julia --project -e 'include("test/cargo_ban_store.jl")'
julia --project -e 'include("test/payload_reprice_install.jl")'
```
- [ ] **S9 커밋**
```bash
git add src/respec/cargo_ban_primitive.jl src/respec/reassign.jl src/respec/minted_tool.jl test/minted_tool_enacts.jl
git commit -m "R1(B): 인자 오류는 예외가 아니라 status 다 — 안 건드린 세계가 폴백을 삼키지 않게"
```

⏱ 45 – 60분. 🔴 **T1 보다 먼저 돈다.**
