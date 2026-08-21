# test/smdp_hazard_knobs.jl
# (1) 손잡이 셋이 spec 의 D-3 · D-4 · D-5 대로인가.
# (2) λ 의 단일 진실원 — 무거운 레인(hazard_rate)과 경량 레인(hazard_rate_from)이 **같은 수**를
#     내는가. 갈리면 롤아웃이 다른 세계를 탐색한다.
#   julia +lts --project=. test/smdp_hazard_knobs.jl
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

@testset "D-3 · D-4 · D-5 기본값" begin
    p = CB.HazardParams()
    @test p.fire_require_spare == false          # D-3
    @test isfinite(p.mtbf_zone_s)                # D-4 — Inf 면 zone 이 영원히 안 온다
    @test p.drain_sigma == 0.0                   # D-5 — eff 를 s 에서 빼려면 먼저 없애야 한다
    @test p.drain_step_cv == 0.0                 # 유지
    @test p.fire_safe_target == true             # 바꾸지 않는다
end

@testset "🔴 D-5 의 음성 대조 — eff 가 진짜로 상수 1.0 이다" begin
    st = CB._new_hazard_state(CB.HazardParams(), 8)
    for i in 1:8; CB._hz_ensure!(st, i); end
    @test all(v -> v == 1.0, values(st.eff))
    # σ 를 되살리면 갈린다 — 이 시험이 D-5 를 되돌리는 변경을 잡는다
    st2 = CB._new_hazard_state(CB.HazardParams(drain_sigma = 0.15), 8)
    for i in 1:8; CB._hz_ensure!(st2, i); end
    @test !all(v -> v == 1.0, values(st2.eff))
end

@testset "λ 의 단일 진실원" begin
    st = CB._new_hazard_state(CB.HazardParams(), 3)
    CB._hz_ensure!(st, 1)
    st.usage_s[1] = 240.0
    for mode in (:idle, :transit, :carry, :manip), soc in (1.0, 0.6, 0.05)
        heavy = CB.hazard_rate(st, 1; mode = mode, soc = soc)
        light = CB.hazard_rate_from(st.params, 240.0, soc, mode)
        @test heavy == light          # 근사가 아니라 **정확히** 같아야 한다
    end
end

@testset "🔴 라벨 레인이 실행 레인과 같은 세계다" begin
    src = read(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle",
                        "gen_oracle_dataset.jl"), String)
    # 브리프 원문은 여기 needle 에 공백을 남겨 뒀는데(`", "`) haystack 은
    # `replace(src, " " => "")` 로 공백을 **전부** 지운다 — needle 도 공백을 지워야
    # 매칭된다(원문 그대로면 소스가 뭐든 영원히 FAIL). 실측 후 정정.
    @test occursin("\"DS_DRAIN_SIGMA\",\"0.0\"", replace(src, " " => ""))
    @test CB.HazardParams().drain_sigma == 0.0
end
