# Task 4 — 수명: `swap_battery!` 가 금지를 해제한다

> **선행:** Task 3 (보관소가 있어야 한다).

## 계약

금지는 **그 로봇에 배터리 교체가 일어나는 순간**까지 산다. 사용자 결정(2026-09-01):
술어(`SoC ≥ θ`)가 아니라 **사건**이다 — 임계값도, 누가 언제 확인하는지도 정할 필요가 없다.

해제 지점은 production 에 **하나뿐**이다: `swap_battery!(env, role)` (`src/respec/replan.jl:1213`
에서 불린다). 그 로봇의 금지를 거기서 지운다.

## Files

- Modify: `swap_battery!` 정의부 (위치는 `grep -rn "function swap_battery!" src/` 로 찾아라)
- Create: `test/cargo_ban_lifetime.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: 실패하는 시험**

```julia
module CargoBanLifetimeTests
using Test
using ConstructionBots
const CB = ConstructionBots
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "🔴 G-3 swap_battery! 가 그 로봇의 금지만 지운다" begin
    env = fixture()                       # 배터리가 켜진 env
    a = CB.RobotID(3); b = CB.RobotID(7)
    CB.clear_all_cargo_bans!()
    CB.set_cargo_ban!(a, 2); CB.set_cargo_ban!(b, 1)
    @test length(CB.STANDING_CARGO_BANS[]) == 2      # 양성 대조: 실제로 둘이 걸려 있다

    CB.swap_battery!(env, a)

    @test !haskey(CB.STANDING_CARGO_BANS[], a)       # a 는 풀렸다
    @test CB.STANDING_CARGO_BANS[][b] == 1           # 🔴 b 는 그대로 — 남의 금지를 지우면 안 된다
    CB.clear_all_cargo_bans!()
end
end # module
```

⚠️ `swap_battery!` 의 실제 시그니처를 **먼저 확인하라**. `role` 이 `AbstractID` 인지 문자열인지
확인하고 보관소의 키 타입과 맞춰라. 안 맞으면 `haskey` 가 조용히 거짓을 내고 금지가 영영 안 풀린다
— 이 레포가 존 키(String vs Symbol)에서 정확히 그 사고를 겪었다.

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 해제를 넣는다**

```julia
    # 🔴 배터리를 갈았으므로 이 로봇의 화물 금지는 목적을 다했다(수명 계약, 사용자 결정 2026-09-01).
    #    금지는 "SoC 가 낮은 동안 무거운 짐을 피한다" 이고, 교체가 그 조건을 없앤다.
    clear_cargo_ban!(role)
```

- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 전체 시험** — 기준선 2279 / 0 fail / 1 error
- [ ] **Step 6: 커밋**

```bash
git add <수정한 파일들> test/cargo_ban_lifetime.jl test/runtests.jl
git diff --cached --name-status | grep -c '^D'    # 🔴 0
git commit -m "respec: 배터리 교체가 그 로봇의 화물 금지를 해제한다"
```
