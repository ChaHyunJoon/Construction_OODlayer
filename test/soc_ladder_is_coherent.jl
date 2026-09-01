# =============================================================================
# **SoC 임계 넷이 하나의 사다리인가.** (2026-08-31, S1/T3)
#
# 왜 이 파일이 필요한가 — 2026-08-31 실측
# ----------------------------------------
# 임계 셋이 갈라져 (0.1, 0.2] 구간이 조용히 죽어 있었다: 그 구간은 `routing_kind` 가
# `unknown:battery_mild`(LLM 레인)를 내면서 `battery_arms` 는 개입 팔 셋을 다 준다 —
# 즉 그 구간에서 합성 레인은 구조적으로 절대 발화하지 않는다.
# 🔴 그리고 두 임계를 **함께 보는 게이트가 레포에 0개였다**: `test_lane_select.jl` 은
# REPLACE_SOC_THRESHOLD/battery_arms 를 0회 언급하고, `mild_menu_is_noop_only.jl` 은
# ROUTING_SEVERE_SOC/routing_kind 를 0회 언급한다. 이 파일이 그 사이를 잇는다.
#
# 재는 명제 여섯
#   (1) 라우팅 경계와 메뉴 경계가 **같다** — 사다리 전 구간에서 두 판정이 일치한다
#   (2) 정지 임계가 deep 경계보다 **엄격히 낮다**
#       (같으면 deep 안에 감속 구간이 없어져 battery_ladder_is_deep_only 단언 2 가
#        만족 불가능해진다 — D-6 이 그래서 폐기됐다)
#   (3) severe 데모 프리셋이 **정지 임계 아래로 확실히 떨어진다**
#       soc_after <= 1 - DEMO_BSOC 이므로 (1 - DEMO_BSOC) <= stall 이면 충분하다
#   (4) 두 엔진(run_demo · render_demo)의 DEMO_BSOC·DEMO_STALL_SOC 기본값이 같다
#   (5) 라벨 레인의 DS_STALL 이 실행 레인의 정지 임계와 같다
#   (6) `isdefined(...) ? REPLACE_SOC_THRESHOLD[] : X` / `try...catch; X end` 류 폴백 리터럴
#       여섯 곳이 전부 DEEP 과 같다 — navigator.jl 이 include 안 된 경로에서 옛 사다리가
#       조용히 되살아나는 것을 막는다.
#
# 변이시험 — 2026-08-31, 아래 다섯을 전부 실제로 돌려서 각각의 실패를 직접 봤다
# (task-3-report.md 에 각 mutation 의 실측 출력이 그대로 있다). 넷은 이 파일이 처음부터
# "일으키면 빨개진다"고 적었던 것이고, 다섯째(폴백)는 (3)의 정정과 같이 새로 더한 것이다.
#   · ROUTING_SEVERE_SOC 만 0.2 로 되돌리면 (1)이 빨개진다 — 실측: 8 passed, 3 failed.
#   · STALL_SOC_DEFAULT 를 REPLACE_SOC_THRESHOLD 와 같게 두면 (2)가 빨개진다 — 실측: 1 passed, 1 failed.
#   · 두 엔진 모두 DEMO_BSOC 기본값을 0.9 로 되돌리면 (3)이 빨개진다(1-0.9=0.09999… > STALL=0.05)
#     — 실측: 2 passed, 2 failed.
#   · 두 엔진 중 하나만 DEMO_BSOC 를 고치면(예: run_demo.jl 만 0.97) (4)가 빨개진다 —
#     실측: 2 passed, 1 failed.
#   · 폴백 여섯 곳 중 하나(battery.jl)만 리터럴 0.2 로 되돌리면 (6)이 빨개진다 —
#     실측: 11 passed, 1 failed.
#
# 🔴 **2026-08-31 실측 정정 — 계획 초안의 Step 2 음성대조 주장은 과장이었다.** 계획 초안은
#    "오늘의 HEAD 에 STALL=0.15 를 박으면 (1)(2)(3) 전부 빨갛다" 고 적었으나, 실제로 돌려
#    보면 **(1) 만 빨갛다(7 passed, 4 failed)**. (2)·(3)·(4)·(5)는 초록으로 남는다(당시
#    실측: 2/2, 4/4, 3/3, 3/3 전부 통과) — `0.15 < 0.2`(deep, 당시 HEAD 값)가 이미 참이고
#    `1.0 - 0.9 = 0.10 <= 0.15`(당시 STALL 스텁)도 이미 참이었기 때문이다. 이 파일이 HEAD 에서
#    실제로 잡던 결함은 (1)의 4 fail 뿐이었다 — 나머지는 위 변이시험처럼 T3 완료 뒤 값을
#    바꿔서 개별적으로 다시 확인해야 "잡는다"고 말할 수 있고, 위 다섯 줄이 그 실측이다.
#
# 실행: julia +lts --project=. test/soc_ladder_is_coherent.jl
# =============================================================================
module SocLadderIsCoherent

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
isdefined(@__MODULE__, :ActionRegistry) ||
    include(joinpath(REPO, "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))
include(joinpath(REPO, "tools", "monitor", "lane_select.jl"))
const AR = ActionRegistry

const DEEP  = Float64(CB.REPLACE_SOC_THRESHOLD[])
const STALL = Float64(CB.STALL_SOC_DEFAULT[])

"소스에서 리터럴 기본값을 읽는다 — 숫자를 여기 박으면 두 번째 진실원이 된다."
function envdefault(path, name)
    src = read(joinpath(REPO, path), String)
    m = match(Regex("get\\(ENV,\\s*\"$(name)\",\\s*\"([^\"]*)\"\\)"), src)
    m === nothing && error("$(path) 에서 $(name) 기본값을 못 찾았다 — 정규식을 고칠 것")
    return m.captures[1]
end

@testset "(1) 라우팅 경계와 메뉴 경계가 같다" begin
    for s in (0.0, 0.02, 0.05, DEEP - 1e-9, DEEP, nextfloat(DEEP), 0.15, 0.2, 0.3, 0.45, 0.9)
        local severe_by_routing = routing_kind("BatteryTruth", s) == "battery"
        local severe_by_menu    = length(AR.battery_arms(s, DEEP, true)) > 1
        @test severe_by_routing == severe_by_menu
    end
end

@testset "(2) 정지 임계가 deep 보다 엄격히 낮다" begin
    @test STALL < DEEP
    # 그래야 deep 안에 "정지하는 칸"과 "감속만 하는 칸"이 둘 다 존재할 수 있다.
    @test AR.battery_arms(STALL, DEEP, true) == AR.battery_arms(DEEP, DEEP, true)
end

@testset "(3) severe 프리셋이 정지 임계 아래로 확실히 떨어진다" begin
    for f in ("tools/monitor/run_demo.jl", "tools/monitor/render_demo.jl")
        local drop = parse(Float64, envdefault(f, "DEMO_BSOC"))
        # soc_after = max(floor_soc=0.0, soc_at_fire - drop) <= 1.0 - drop
        @test (1.0 - drop) <= STALL
        @test (1.0 - drop) <= DEEP        # 라우팅도 severe 로 간다
    end
end

@testset "(4) 두 엔진의 배터리 기본값이 같다" begin
    for name in ("DEMO_BSOC", "DEMO_STALL_SOC")
        @test envdefault("tools/monitor/run_demo.jl", name) ==
              envdefault("tools/monitor/render_demo.jl", name)
    end
    @test parse(Float64, envdefault("tools/monitor/run_demo.jl", "DEMO_STALL_SOC")) === STALL
end

@testset "(5) 라벨 레인의 정지 임계가 실행 레인과 같다" begin
    local gen = "wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl"
    @test parse(Float64, envdefault(gen, "DS_STALL")) === STALL
    # 학습 사다리의 모든 칸이 새 경계에서도 비교 가능해야 한다(battery_ladder_is_deep_only
    # 단언 1 과 같은 명제를 새 경계에서 다시 확인한다 — 그 파일과 겹치는 것이 의도다).
    for s in [parse(Float64, x) for x in split(envdefault(gen, "DS_BSOC"), ",")]
        @test length(AR.battery_arms(s, DEEP, true)) > 1
    end
end

@testset "(6) REPLACE_SOC_THRESHOLD 폴백 리터럴이 진실원과 같다" begin
    # `isdefined(...) ? REPLACE_SOC_THRESHOLD[] : X` 류(그리고 `try ... catch; X end` 류) 폴백이
    # navigator.jl 이 include 되지 않은 경로에서 X 를 조용히 쓴다. X 가 DEEP 과 갈리면 그 경로만
    # 옛 사다리에 남는다 — 에러 없이. 2026-08-31 (S1/T3) 실측: 여섯 곳 모두 리터럴 0.2 였다.
    local fallback_re = r"REPLACE_SOC_THRESHOLD\[\]\s*:\s*([0-9]*\.?[0-9]+)|REPLACE_SOC_THRESHOLD\[\]\)\s*catch;\s*([0-9]*\.?[0-9]+)\s*end"
    local fallback_files = [
        "src/respec/replace_robot.jl",
        "src/navigator/battery.jl",
        "src/smdp/hazard.jl",
        "tools/monitor/policy.jl",
        "wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl",
    ]
    local total_sites = 0
    for f in fallback_files
        local src_text = read(joinpath(REPO, f), String)
        local matches = collect(eachmatch(fallback_re, src_text))
        @test length(matches) >= 1
        for m in matches
            local lit = m.captures[1] === nothing ? m.captures[2] : m.captures[1]
            @test parse(Float64, lit) == DEEP
            total_sites += 1
        end
    end
    # 여섯 폴백 자리 전부를 봤는가 — 하나라도 빠지면(파일 경로가 바뀌거나 패턴이 안 맞으면)
    # 이 카운트가 먼저 샌다.
    @test total_sites == 6
end

end # module
