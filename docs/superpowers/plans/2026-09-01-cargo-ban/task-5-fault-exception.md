# Task 5 — 안전 예외: 고장 수습이 마모 평준화를 이긴다

> **선행:** Task 3 (보관소).

## 왜 — 되돌릴 수 없는 실패에 대한 보험이다

로봇이 고장나면 `_enact_one!`(`src/respec/replan.jl:883-895`)이
`fault_robot_and_reassign!` 을 부르고, 실패하면 이렇게 한다:

```julia
if res.status != :admitted
    @warn "[RESPEC] reassign $(res.status) -> fallback"
    engage_fallback!(env)          # 🔴 라인 영구 정지
end
```

`engage_fallback!` 은 자기 docstring 이 *"first fallback = permanent end of the run, and that
is the design"* 이라고 적고, **푸는 production 호출자가 0개**다(설계상). 즉 화물 금지 때문에
고장 재배정이 안 되면 **그 실행은 되살릴 수 없다.**

🔴 **실측(2026-09-01, `tools/probes/probe_ban_vs_fault.jl`, tractor·closed=60, 상한 60s):**
로봇 1/2/3 대에 금지(금지행 4/8/11 at N=1, 13/25/35 at N=3)를 걸고 고장 1건을 얹어도
**전부 실행 가능했다.** 즉 **이 예외는 관측된 결함에 대한 대응이 아니다.**

⚠️ 그 측정은 전 팔이 `TIME_LIMIT` 라 목적값은 비교 불가다(증거: N=3 의 B1 이 12.7768 로
대조 13.2019 보다 낮다 — 제약을 더했는데 좋아지는 것은 최적해에서 불가능). 건전한 것은
실행가능 판정뿐이고, `FEASIBLE_POINT` 는 해의 존재를 실제로 증명하므로 그 방향은 확실하다.
그리고 그것은 **한 판·한 시점**이다.

⟹ 넣는 이유는 **비대칭**이다: 예외 비용은 네 줄, 안 넣고 틀렸을 때 비용은 복구 불가능한 런 종료.
**코드 주석에 "관측된 결함이 아니라 보험" 이라고 정확히 적어라** — 나중에 누가 읽고 "여기서
실제로 문제가 났었구나" 로 오해하면 안 된다.

## Files

- Modify: `src/respec/reassign.jl` — `fault_robot_and_reassign!` 본문
- Create: `test/cargo_ban_fault_exception.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: 실패하는 시험**

```julia
module CargoBanFaultExceptionTests
using Test
using ConstructionBots
const CB = ConstructionBots
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "🔴 G-4 고장 수습 중에는 금지가 꺼지고, 끝나면 되살아난다" begin
    env = fixture()
    a = CB.RobotID(3)
    CB.clear_all_cargo_bans!(); CB.set_cargo_ban!(a, 2)

    # (a) 복원 — 재배정이 끝나면 금지가 그대로 있어야 한다
    faulted = some_other_robot(env, a)
    CB.fault_robot_and_reassign!(env, faulted)
    @test CB.STANDING_CARGO_BANS[][a] == 2        # 🔴 되살아났다

    # (b) 🔴 그 안에서 실제로 **꺼졌는지** 를 재야 한다. 반환값으로는 알 수 없다.
    #     방법: 재배정이 formulate 하는 순간의 보관소 크기를 훅으로 기록하거나,
    #     `_compile_standing_cargo_bans!` 이 그때 0 행을 냈는지 센다.
    #     🔴 이 단언 없이 (a) 만 두면 "예외가 아예 없어도 초록" 이다 — 공허한 시험이다.
    @test observed_bans_during_reassign == 0

    # (c) 예외가 던져도 복원돼야 한다 (finally 계약)
    CB.set_cargo_ban!(a, 2)
    try
        CB.fault_robot_and_reassign!(env, CB.RobotID(99999))   # 없는 로봇 → 던지거나 거절
    catch
    end
    @test CB.STANDING_CARGO_BANS[][a] == 2        # 🔴 예외 경로에서도 되살아났다
    CB.clear_all_cargo_bans!()
end
end # module
```

⚠️ **(b) 를 어떻게 관측할지는 구현자가 정한다.** 가장 단순한 방법: `_compile_standing_cargo_bans!`
이 마지막으로 추가한 행 수를 전역 `Ref` 에 남기고 시험이 읽는 것. 그 `Ref` 도 `state_globals.jl`
에 등록해야 하는지 판단하라(로그성이면 `:log`).

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 예외를 넣는다**

`fault_robot_and_reassign!` 본문을 감싼다:

```julia
    # 🔴 고장 수습은 마모 평준화보다 우선한다. 화물 금지 때문에 재배정이 실행 불가가 되면
    #    `_enact_one!`(replan.jl:889-892)이 `engage_fallback!` 를 부르고 그것은 **복구 불가능한
    #    런 종료**다(푸는 production 호출자 0개, 설계상).
    #
    #    ⚠️ 이것은 **관측된 결함에 대한 대응이 아니라 보험이다.** 실측(2026-09-01,
    #    tools/probes/probe_ban_vs_fault.jl, tractor·closed=60): 로봇 3대에 금지 + 고장 1건까지
    #    전부 실행 가능했다. 한 판·한 시점에서 안 났다는 것이 "안 난다"는 뜻은 아니고,
    #    이 실패는 되돌릴 수가 없어서 네 줄로 보험을 든다.
    local _saved_bans = copy(STANDING_CARGO_BANS[])
    empty!(STANDING_CARGO_BANS[])
    try
        ... 기존 본문 ...
    finally
        STANDING_CARGO_BANS[] = _saved_bans
    end
```

⚠️ **얕은 복사로 충분한지 확인하라.** `copy` 는 `Dict` 를 한 겹 복사한다. 값이 `Int` 이므로
충분하지만, 나중에 값 타입이 바뀌면 여기가 조용히 깨진다 — 주석에 그 사실을 남겨라.

⚠️ 기존 본문에 **이른 `return` 이 여러 개** 있다(`:rejected` · `:fallback` 등).
`try`/`finally` 는 그것들을 전부 덮는다 — 그래서 `finally` 를 쓰는 것이다. `return` 앞마다
복원을 손으로 넣지 마라(하나 빠뜨리면 금지가 영영 사라진다).

- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 전체 시험** — 기준선 2279 / 0 fail / 1 error
- [ ] **Step 6: 커밋**

```bash
git add src/respec/reassign.jl test/cargo_ban_fault_exception.jl test/runtests.jl
git diff --cached --name-status | grep -c '^D'    # 🔴 0
git commit -m "respec: 고장 수습 중에는 화물 금지를 끈다 (보험 — 관측된 결함 아님)"
```
