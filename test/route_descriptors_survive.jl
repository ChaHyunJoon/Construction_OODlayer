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
const KNOWN_DESC = [0.11, 0.22, 0.33, 0.44, 0.55, 0.66]

# (G1, 2026-08-26) 아래 두 testset 을 **바깥 @testset 하나로** 감싼다. 왜: 최상위 @testset 은
# 실패(빨강)로 끝나면 `TestSetException` 을 던져 그 지점에서 파일 실행이 멈춘다. 이 파일이
# 형제(sibling) top-level @testset 둘로 있던 동안, 이 파일을 헤더가 문서화한 명령
# (`julia +lts --project=. test/route_descriptors_survive.jl`)으로 단독 실행하면: 첫 번째
# testset 이 빨개지는 순간 **두 번째 — `route()` 자체를 직접 재는 F1 게이트, 이 파일이 존재하는
# 이유 — 가 아예 실행되지 않고 요약에도 안 찍힌다.** `Pkg.test()` 안에서는 두 testset 이 스위트의
# 바깥 testset 에 이미 감싸여 있어 이 문제가 안 드러난다 — 즉 단독 실행과 스위트 실행이 서로
# 다른 것을 보고했다. 하나로 묶으면 두 실행 경로가 같은 결과를 낸다(내부 testset 하나가
# 실패해도 바깥 testset 은 다음 내부 testset 을 계속 돈다 — 멈추는 것은 **최상위** testset 뿐).
@testset "route_descriptors_survive" begin

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
@testset "route() 자체가 '조기 반환이 서술자 계산보다 먼저' 회귀를 잡는다" begin
    prev_calib = get(ENV, "NOVELTY_CALIB", nothing)
    ENV["NOVELTY_CALIB"] = "/definitely/not/a/file.json"   # install_novelty!() -> false, **단**
                                                            # 아래 (G2) 참고 — 항상 그런 건 아니다
    try
        # (G2, 2026-08-26) 전제조건(have_det=false)을 가정하지 말고 잰다. `install_novelty!()`
        # (policy.jl:74) 는 프로세스 전역 감지기가 **이미 설치돼 있으면 첫 줄에서 곧바로 true 를
        # 돌려주고 위 ENV["NOVELTY_CALIB"] 줄은 아예 안 읽는다** — 그러면 이 줄은 아무 효과가
        # 없고 이 testset 의 전제(have_det=false)가 조용히 깨진다. 오늘 이 스위트 순서에서는
        # 이 파일 앞에 감지기를 까는 testset 이 없어 안전하지만(`tools/test_novelty.jl`·
        # `tools/test_router.jl` 은 감지기를 깐다 — 이 파일보다 먼저 배선되면 이 전제가
        # 소리 없이 깨진다), 나중 코드가 그 순서를 몰라도 되게 여기서 직접 단언한다. 이게
        # 깨지면 아래 `r["enabled"] == false` 가 "descriptors" 와 무관한 `true == false` 로
        # 실패해 원인이 안 보이게 새므로, 그 전에 여기서 이름을 밝혀 죽인다.
        @test install_novelty!() == false
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

end # outer @testset "route_descriptors_survive" (G1)

end # module
