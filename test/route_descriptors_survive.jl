# =============================================================================
# 교정 파일이 없어도 **서술자는 산다** 를 못박는다.
#
# 왜 (2026-08-26 실측): `route()` 의 `!have_det` 조기 반환이 `descriptors` 키 없이 Dict 를
# 돌려주고, 서술자를 계산하는 `event_descriptors_of` 는 그 반환 **뒤에** 있었다. 교정 파일
# 디렉토리가 아예 없으므로 **모든 LLM 결정이 문장 한 줄로 내려졌다** — surrogate 는 피처를
# 받는데 LLM 은 못 받는 비대칭 비교였다.
#
# 실행: julia +lts --project=. test/route_descriptors_survive.jl
# =============================================================================
module RouteDescriptorsSurvive

using Test
using ConstructionBots
const CB = ConstructionBots
const REPO = normpath(joinpath(@__DIR__, ".."))
isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))
include(joinpath(REPO, "tools", "monitor", "policy.jl"))

const DESC = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60]

@testset "서술자는 라우팅 게이트와 독립이다" begin
    # (A) 교정 없음 = 라우터 비활성. 그래도 서술자는 실려야 한다.
    d = route_verdict(desc = DESC, have_det = false, drives = false, policy = "dspy")
    @test haskey(d, "descriptors")
    @test d["descriptors"] == DESC
    @test d["enabled"] == false
    @test d["target"] == "dspy"

    # (B) 서술자 계산 자체가 실패한 경우는 nothing 이 실린다 — 키를 지우지 않는다.
    #     "못 쟀다" 와 "안 실었다" 를 구분할 수 있어야 한다.
    #     ⚠️ (A) 와 같은 첫 번째 분기(`!have_det`)를 친다 — `desc` 값만 다르다. 세 번째
    #     분기(`have_det=true`, `v=nothing`, "descriptors unavailable")는 (D) 가 별도로 친다.
    d2 = route_verdict(desc = nothing, have_det = false, drives = false, policy = "dspy")
    @test haskey(d2, "descriptors")
    @test d2["descriptors"] === nothing

    # (C) route_verdict 의 세 번째(최종) 분기 — 교정도 있고 서술자도 있다.
    d3 = route_verdict(desc = DESC, have_det = true, drives = true, policy = "dspy",
                       v = (novel = true, p = 0.01, score = 2.0), eps = 0.05)
    @test haskey(d3, "descriptors")
    @test d3["descriptors"] == DESC
    @test d3["enabled"] == true

    # (D) 가운데 분기 — 교정은 있는데(`have_det=true`) 서술자 계산이 실패했다(`v=nothing`,
    #     route() 에서는 `desc === nothing` 일 때만 이 분기로 온다). (A)/(B) 는 둘 다
    #     `have_det=false` 분기만 쳤으므로 이 분기는 여기서 처음 직접 호출된다 — 나중에 누가
    #     `merge(base, ...)` 를 이 분기에서만 raw `Dict(...)` 로 바꿔도 (A)/(B)/(C) 는 안 잡는다.
    d4 = route_verdict(desc = nothing, have_det = true, drives = false, policy = "dspy")
    @test haskey(d4, "descriptors")
    @test d4["descriptors"] === nothing
    @test d4["enabled"] == false
    @test d4["reason"] == "descriptors unavailable"
end

# =============================================================================
# (F1, 2026-08-26) 위 testset 은 전부 `route_verdict` 를 **직접** 부른다 — `route(env, truth)`
# 자신은 한 번도 안 거친다. 그래서 이 파일이 실제로 막으려는 회귀(desc 계산이 `!have_det`
# 조기 반환 **뒤에** 있던 옛 순서)가 이 파일에 한 번도 안 걸린다: `route_verdict` 는 옛 버그가
# 나던 자리가 아니다 — 옛 버그는 `route()` 본문의 **줄 순서**였다. `route()` 를 직접 호출해
# `event_descriptors_of` 를 스텁으로 갈아 끼우고, 교정 없음(`have_det=false`)에서도
# `route()` 가 스텁이 낸 값을 "descriptors" 로 돌려주는지 잰다.
# =============================================================================
const KNOWN_DESC = [0.11, 0.22, 0.33, 0.44, 0.55, 0.66]

@testset "route() 자체가 '조기 반환이 서술자 계산보다 먼저' 회귀를 잡는다" begin
    prev_calib = get(ENV, "NOVELTY_CALIB", nothing)
    ENV["NOVELTY_CALIB"] = "/definitely/not/a/file.json"   # install_novelty!() -> false
    try
        # event_descriptors_of 를 스텁으로 덮어쓴다 — env/truth 가 nothing 이라 원래 함수는
        # ood_features 에서 곧바로 던진다. 여기서 재는 것은 "route() 가 desc 를 실제로 route_verdict
        # 에 전달하는가" 이지 event_descriptors_of 자체의 계산이 아니다(그건 event_descriptors_of
        # 의 몫이고 이 파일의 관심사가 아니다).
        @eval event_descriptors_of(env, truth) = KNOWN_DESC
        r = route(nothing, nothing)
        @test haskey(r, "descriptors")
        @test r["descriptors"] == KNOWN_DESC
        @test r["enabled"] == false
    finally
        prev_calib === nothing ? delete!(ENV, "NOVELTY_CALIB") : (ENV["NOVELTY_CALIB"] = prev_calib)
    end
end

end # module
