# =============================================================================
# 교정 파일이 없어도 **서술자는 산다** 를 못박는다.
#
# 왜 (2026-08-26 실측): `route()` 의 `!have_det` 조기 반환이 `descriptors` 키 없이 Dict 를
# 돌려주고, 서술자를 계산하는 `event_descriptors_of` 는 그 반환 **뒤에** 있었다. 교정 파일
# 디렉토리가 아예 없으므로 **모든 LLM 결정이 문장 한 줄로 내려졌다** — surrogate 는 피처를
# 받는데 LLM 은 못 받는 비대칭 비교였다.
#
# 🔴 **2026-08-29 (§B-1): 이 파일의 명제는 더 강하게 성립한다.** novelty 축이 삭제되면서
# `route()` 에 **게이트라는 것이 아예 없어졌다** — `install_novelty!()` 도 `have_det` 조기
# 반환도 존재하지 않고, 남은 것은 서술자 계산과 `route_verdict` 호출 둘뿐이다. 즉 예전에는
# "교정이 없어도 산다" 였고 지금은 "교정이라는 개념이 없다" 다.
#
# 🔴 그래서 아래 넷을 **지웠다**(주석 처리도 `@test_skip` 도 아니다 — 이 레포의 규칙):
#   · (C)·(D) — `route_verdict` 의 두 번째·세 번째 분기를 치던 검사. **분기 자체가 없어졌다**
#     (`have_det`·`v`·`eps` 키워드가 삭제됐다). 오늘 `route_verdict` 는 분기 없는 한 갈래다.
#   · `d["enabled"]`·`d["target"]` 단언 — 두 키가 §B-1 에서 삭제됐다. `target` 은 뜻이 바뀐 채
#     `decide_all` 로 자리를 옮겼다(그 줄의 Ruling R2 주석).
#   · (G2) 의 `@test install_novelty!() == false` 와 그것을 만들던 `ENV["NOVELTY_CALIB"]` 조작 —
#     🔴 그 전제는 **이제 불필요하다.** 예전에 필요했던 이유는 `route()` 가 프로세스 전역
#     감지기 유무로 분기했기 때문이고(감지기가 이미 깔려 있으면 `install_novelty!()` 가 첫 줄에서
#     `true` 를 돌려줘 이 testset 의 전제가 조용히 깨졌다), 오늘 `route()` 는 그 전역을 **한 번도
#     안 읽는다.** 그러므로 스위트 안에서 어떤 파일이 감지기를 깔아 놓았든 이 검사의 결과는
#     같다 — 세울 전제가 없다.
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
    # (A) `route_verdict` 는 서술자를 그대로 싣는다.
    d = route_verdict(desc = DESC, policy = "dspy")
    @test haskey(d, "descriptors")
    @test d["descriptors"] == DESC

    # (B) 서술자 계산 자체가 실패한 경우는 nothing 이 실린다 — 키를 지우지 않는다.
    #     "못 쟀다" 와 "안 실었다" 를 구분할 수 있어야 한다.
    d2 = route_verdict(desc = nothing, policy = "dspy")
    @test haskey(d2, "descriptors")
    @test d2["descriptors"] === nothing
end

# =============================================================================
# (F1, 2026-08-26) 위 testset 은 `route_verdict` 를 **직접** 부른다 — `route(env, truth)` 자신은
# 한 번도 안 거친다. 그래서 이 파일이 실제로 막으려는 회귀(desc 계산이 조기 반환 **뒤에** 있던
# 옛 순서)가 거기엔 한 번도 안 걸린다: `route_verdict` 는 옛 버그가 나던 자리가 아니다 — 옛
# 버그는 `route()` 본문의 **줄 순서**였다. `route()` 를 직접 호출해 `event_descriptors_of` 를
# 스텁으로 갈아 끼우고, `route()` 가 스텁이 낸 값을 "descriptors" 로 돌려주는지 잰다.
# =============================================================================
@testset "route() 자체가 '조기 반환이 서술자 계산보다 먼저' 회귀를 잡는다" begin
    # event_descriptors_of 를 스텁으로 덮어쓴다 — env/truth 가 nothing 이라 원래 함수는
    # ood_features 에서 곧바로 던진다. 여기서 재는 것은 "route() 가 desc 를 실제로 route_verdict
    # 에 전달하는가" 이지 event_descriptors_of 자체의 계산이 아니다(그건 event_descriptors_of
    # 의 몫이고 이 파일의 관심사가 아니다).
    @eval event_descriptors_of(env, truth) = KNOWN_DESC
    r = route(nothing, nothing)
    @test haskey(r, "descriptors")
    @test r["descriptors"] == KNOWN_DESC
end

end # outer @testset "route_descriptors_survive" (G1)

end # module
