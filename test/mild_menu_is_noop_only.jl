# =============================================================================
# mild SoC 구간의 메뉴는 NOOP 하나다. (2026-08-30, T8)
#
# 왜 이 파일이 필요한가
# ----------------------
# 이 성질은 2026-08-25 부터 참이지만, 그것을 **이 데모가 실제로 쓰는 SoC 에서** 못박는
# 시험이 없다. `battery_menu_lanes_agree.jl` 은 두 레인의 **합의**를 보므로, 두 레인이
# 나란히 개입 팔을 되찾아도 초록이다. 그런데 Phase D 전체(합성 발화 → payload 재가격 →
# 렌더)가 정확히 이 값 하나에 걸려 있다 — 메뉴에 `SwapBattery` 가 하나만 돌아와도
# `expressible` 이 뒤집히고 합성 레인이 발화하지 않는다.
#
# 재는 명제 셋
#   (1) DEMO_BSOC=0.45(이 데모의 값)에서 메뉴는 정확히 ["NOOP"] 이다.
#   (2) 경계가 `REPLACE_SOC_THRESHOLD[]` 이고, 그 **위**가 mild 다(경계값 자체는 deep).
#   (3) 손잡이가 켜져 있다 — `DS_BATTERY_SOC_SPLIT` 기본값이 "1" 이다.
#
# 🔴 이 게이트가 재지 **않는** 것: 모델이 실제로 `expressible=false` 라고 답하는지.
#    그건 프롬프트 준수 축이고 라이브 호출로만 잰다(T9 Step 1).
#
# 변이시험 (실패하는 것을 실제로 볼 것)
#   · `battery_arms` 의 mild 분기를 `[i for i in up if COST[i] == 0.0]` 에서 `up` 으로
#     되돌리면 (1) 의 첫 어서션이 빨개진다.
#   · 부등호를 `<` 로 바꾸면 (2) 가 빨개진다.
#   · `soc_split_enabled` 의 기본값을 "0" 으로 바꾸면 (3) 이 빨개진다.
#   · `battery_arms` 의 `(soc isa Real && isfinite(soc)) || return up` 가드를 지우면 (4) 가
#     빨개진다(수정 라운드 2, 리뷰 Important 2-a: NaN 이 `Float64(NaN) <= Float64(thr)` 에서
#     `false` 로 새서 mild 분기로 떨어지고, `nothing` 은 `Float64(nothing)` 에서 아예 죽는다).
#   · `kind_valid` 에서 `if k in String.(collect(REGISTRY[i].kinds))` 필터를 지우고
#     `active_ids()` 를 그대로 돌려주면(어떤 kind 를 물어도 필터링을 안 하면) (1) 의 두 번째
#     어서션(zone 비교)이 빨개진다(수정 라운드 2, 리뷰 Important 2-b) — `kind_valid(:zone)` 이
#     더는 빈 벡터가 아니라 `kind_valid(:battery)` 와 같은 3팔을 돌려주기 때문이다. 오늘의
#     레지스트리에서 활성 3팔이 전부 "battery" kind 를 갖고 있어(battery_arms 가 부르는
#     `kind_valid(:battery)` 는 우연히 그대로라) (1) 의 첫 어서션·(2)·(3)·(4) 는 이 변이로는
#     안 움직인다 — 딱 이 어서션만 겨눈 변이다.
#
# 🔴 2026-08-30, T8 수정 라운드 1: 이 파일을 처음엔 감싸지 않은 채(top-level) 썼더니
# `Pkg.test()` 전체 스위트에서만 빨개졌다(단독 실행은 초록) — `test/smdp_action_name_smoke.jl`
# 도 `Main` 스코프에 `const AR = ActionRegistry` 를 박아 두고 있어서, 두 파일이 같은
# 프로세스에 같이 include 되면 두 번째 바인딩이 "invalid redefinition of constant" 로 죽었다.
# `battery_menu_lanes_agree.jl` · `policy_macro_binding.jl` · `battery_ladder_is_deep_only.jl`
# 이 전부 자기 `module` 로 감싸는 이유가 바로 이것이다 — 그 규약을 따른다.
# =============================================================================
module MildMenuIsNoopOnly

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))

# src/navigator/ 는 컴파일된 패키지의 일부가 아니라 호출자가 런타임에 include 하는
# 모듈이다 — 이 게이트를 단독으로(`julia ... test/mild_menu_is_noop_only.jl`) 돌리면
# `CB.REPLACE_SOC_THRESHOLD` 가 아직 없다. 형제 게이트들과 같은 가드를 쓴다.
isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
const AR = ActionRegistry

const _THR = Float64(CB.REPLACE_SOC_THRESHOLD[])

@testset "(3) SoC 분할 손잡이가 기본으로 켜져 있다" begin
    # 🔴 리터럴 "1" 을 여기 두 번째로 적지 않는다 — 함수의 판정을 그대로 믿되,
    #    프로세스 환경이 오염된 채로 이 파일이 도는 것은 막는다.
    withenv("DS_BATTERY_SOC_SPLIT" => nothing) do
        @test AR.soc_split_enabled() === true
    end
end

@testset "(1) 이 데모의 SoC 에서 메뉴는 NOOP 하나다" begin
    # 0.45 = `regen_router_cases.sh` 의 battery_mild 프리셋(DEMO_BSOC=0.45).
    #   리터럴인 이유: 그 값이 **이 시험이 재는 대상**이지 유도할 값이 아니다.
    ids = AR.battery_arms(0.45, _THR, true)
    @test [AR.NAME[i] for i in ids] == ["NOOP"]
    # zone 과 같은 모양인지 나란히 본다 — 두 레인이 같은 규약이라는 것이 설계의 주장이다.
    @test [AR.NAME[i] for i in sort(unique(vcat(0, AR.kind_valid(:zone))))] == ["NOOP"]
end

@testset "(2) 경계는 REPLACE_SOC_THRESHOLD 이고 그 위가 mild 다" begin
    deep = AR.battery_arms(_THR, _THR, true)              # 경계값 자체는 deep
    mild = AR.battery_arms(nextfloat(_THR), _THR, true)   # 바로 위는 mild
    @test length(deep) > 1
    @test [AR.NAME[i] for i in mild] == ["NOOP"]
    # 상한이 실제로 셋이라는 것도 같이 본다 — deep 이 줄어들면(예: 2 로) `length(deep) > 1` 은
    # 여전히 초록이면서 이 시험의 뜻이 바뀐다. 어휘 단일 진실원 규약(이름은 리터럴 금지)에 따라
    # **개수만** 리터럴로 적는다 — 이름 일치는 이 파일의 몫이 아니라 `policy_macro_binding.jl`
    # 의 몫이다(그 파일이 리터럴 없이 레지스트리에서 이름을 유도해 잰다).
    @test length(AR.kind_valid(:battery)) == 3
end

@testset "(4) soc 가 미기록이면 좁히지 않는다" begin
    # 모르는 것을 근거로 메뉴를 줄이지 않는다(`battery_arms` 의 docstring).
    @test length(AR.battery_arms(NaN, _THR, true)) > 1
    @test length(AR.battery_arms(nothing, _THR, true)) > 1
end

end # module
