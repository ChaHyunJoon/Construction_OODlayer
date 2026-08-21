# =============================================================================
# test/smdp_rates.jl — Task T7, `rates.jl`
#
# spec §2-2 의 닫힌 형태가 **정말 맞는지** 수치 적분과 직접 대조한다. 이 파일은 씬도 엔진도
# 안 쓴다 — (A, a) 를 직접 넣기 때문이다. (엔진 대조는 test/smdp_derive.jl 에 있다.)
#   julia +lts --project=. test/smdp_rates.jl
# =============================================================================
using ConstructionBots, Test
const CB = ConstructionBots
CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "smdp", "mdp.jl"))

function numeric_integral(A, a, Δ; n = 200_000)     # 사다리꼴 — 닫힌 형태의 독립 대조군
    h = Δ / n
    s = 0.5 * (A * exp(a * 0.0) + A * exp(a * Δ))
    for i in 1:(n - 1); s += A * exp(a * i * h); end
    return s * h
end

@testset "integrated_hazard == 수치적분" begin
    for (A, a, Δ) in ((1e-3, 2e-4, 60.0), (5e-4, -3e-4, 120.0),
                      (2e-3, 0.0, 30.0), (1e-3, 1e-6, 900.0))
        @test CB.integrated_hazard(A, a, Δ) ≈ numeric_integral(A, a, Δ) rtol = 1e-6
    end
end

@testset "inv_integrated_hazard 는 진짜 역함수다" begin
    for (A, a) in ((1e-3, 2e-4), (5e-4, -3e-4), (2e-3, 0.0), (1e-3, 1e-9))
        for Δ in (1.0, 37.5, 300.0)
            E = CB.integrated_hazard(A, a, Δ)
            @test CB.inv_integrated_hazard(A, a, E) ≈ Δ rtol = 1e-6
        end
    end
end

@testset "a<0 에서 유한 총위험 — 발화 안 하면 Inf" begin
    A, a = 1e-3, -1e-3
    total = -A / a                        # lim_{Δ→∞} (A/a)(e^{aΔ}−1) = −A/a
    @test CB.inv_integrated_hazard(A, a, total * 0.99) < Inf
    @test CB.inv_integrated_hazard(A, a, total * 1.01) == Inf   # 🔴 음수를 내면 안 된다
    @test CB.inv_integrated_hazard(A, a, total)        == Inf   # 경계는 안전한 쪽으로
end

@testset "🔴 inv_integrated_hazard 는 절대 음수를 내지 않는다" begin
    for A in (0.0, 1e-9, 1e-3, 1.0), a in (-1e-1, -1e-3, 0.0, 1e-3, 1e-1)
        for E in (0.0, 1e-9, 1e-3, 1.0, 1e6, Inf, NaN)
            Δ = CB.inv_integrated_hazard(A, a, E)
            @test Δ >= 0.0                      # NaN 이면 이 단언이 먼저 빨개진다
        end
    end
    @test CB.inv_integrated_hazard(1e-3, 0.0, -1.0) == Inf      # 음수 E 도 안전한 쪽으로
end

@testset "🔴 |a·Δ| 가 작은 띠에서 상쇄가 없다 (BigFloat 대조 — expm1/log1p 가 load-bearing)" begin
    # `_A_ZERO_TOL`(1e-12)과 ~1e-8 사이의 띠에서 `exp(x) - 1.0` 은 파국적 상쇄를 일으킨다.
    # 실측(BigFloat 대조): 그 판의 상대오차 **8.2e-8** — 위 수치적분 시험의 rtol 1e-6 까지
    # 12배밖에 안 남는다. `expm1` 판은 **2.2e-16**. 이 시험이 그 차이를 붙잡는다.
    for (A, a, Δ) in ((1e-3, 1e-9, 1.0), (1e-3, 1e-10, 10.0),
                      (1e-3, -1e-9, 1.0), (1e-3, 1e-11, 1.0), (1e-3, 1e-6, 900.0))
        ref = Float64((big(A) / big(a)) * (exp(big(a) * big(Δ)) - 1))
        @test abs(CB.integrated_hazard(A, a, Δ) - ref) / abs(ref) < 1e-14
        # 역함수도 같은 띠에서 왕복해야 한다(log1p).
        @test abs(CB.inv_integrated_hazard(A, a, ref) - Δ) / Δ < 1e-9
    end
end

@testset "a→0 극한이 매끄럽다" begin
    A = 1e-3
    @test CB.integrated_hazard(A, 0.0, 50.0) ≈ A * 50.0
    @test CB.integrated_hazard(A, 1e-14, 50.0) ≈ A * 50.0 rtol = 1e-9
    @test CB.inv_integrated_hazard(A, 0.0, A * 50.0) ≈ 50.0
    @test CB.inv_integrated_hazard(A, 1e-14, A * 50.0) ≈ 50.0 rtol = 1e-9
end

@testset "rate_params_one 의 A 는 t=0 의 λ 와 같다" begin
    p   = CB.HazardParams()
    bp  = CB.BatteryParams()
    rec = CB.RobotRec(soc = 0.7, usage_s = 300.0)
    A, a = CB.rate_params_one(p, rec, :carry, bp, bp.capacity_J)
    @test A == CB.hazard_rate_from(p, 300.0, 0.7, :carry)
    @test a > 0                            # :carry 는 usage 도 늘고 soc 도 준다 → λ 가 는다
    idle = CB.RobotRec(soc = 1.0, usage_s = 0.0)
    Ai, ai = CB.rate_params_one(p, idle, :idle, bp, bp.capacity_J)
    @test ai ≈ p.beta_soc * CB.mode_power_W(bp, :idle) / bp.capacity_J
    #  🔴 대기도 idle_W 를 먹는다 — a == 0 이라고 단정하지 않는다(실측 battery.jl:244)
    @test Ai == CB.hazard_rate_from(p, 0.0, 1.0, :idle)
end

@testset "🔴 rate_params_one — 모드가 실제로 값을 가른다 (음성 대조)" begin
    p, bp = CB.HazardParams(), CB.BatteryParams()
    rec   = CB.RobotRec(soc = 0.7, usage_s = 300.0)
    got   = Dict(m => CB.rate_params_one(p, rec, m, bp, bp.capacity_J)
                 for m in (:idle, :transit, :carry, :manip))
    @test length(unique(first.(values(got)))) == 4          # A 가 네 모드 모두 다르다
    @test got[:idle][2] < got[:transit][2]                  # idle 만 usage 항이 없다
    @test_throws ErrorException CB.rate_params_one(p, rec, :sprint, bp, bp.capacity_J)
end

@testset "🔴 rates.jl 은 씬을 안 본다 (AST 기계 검사)" begin
    # 분리의 이유가 이것이다: 수치 대조군이 엔진에 묶이면 안 된다. 그래서 `env` 를 받는
    # 배치 함수 `rate_params` 는 **derive.jl** 에 산다(계획서는 rates.jl 이라고 적었다).
    #
    # 🔴 정규식으로 소스를 긁던 앞 판은 두 군데가 샜다: 금지 목록이 6개뿐이라
    # `global_transform`·`entity`·`get_node`·`Graphs`·`BATTERY_FLEET`·`HAZARD_STATE` 가
    # 전부 통과했고, `split(l, "#")[1]` 은 `#` 이 든 **문자열 리터럴**을 잘라 먹었다.
    # 이제 Julia 로 **파싱해서 심볼을 훑는다** — 주석·docstring 은 파서가 지우고,
    # 문자열 안의 `#` 은 애초에 심볼이 아니라 잡히지 않는다.
    src  = read(joinpath(@__DIR__, "..", "src", "smdp", "rates.jl"), String)
    syms = Set{Symbol}()
    walk(x) = (x isa Symbol && push!(syms, x);
               x isa Expr && foreach(walk, x.args); nothing)
    walk(Meta.parseall(src))

    banned = [:env, :sched, :scene_tree, :cache, :active_set,          # 씬/엔진 핸들
              :PlannerEnv, :SimState, :GraphBlock, :GeoBlock, :ProgBlock,
              :get_node, :get_nodes, :entity, :global_transform, :node_id,
              :matches_template, :Graphs, :get_active_pos,
              :BATTERY_FLEET, :HAZARD_STATE, :RESTRICTION_ZONES,        # 전역 상태
              :_responsible_robots, :_node_mode, :_payload_mass, :_hz_modes,
              :active_of, :modes_of, :mode_of, :rate_params]            # derive.jl 의 것들
    for b in banned
        @test !(b in syms)
    end
    # 음성 대조: 이 검사가 실제로 무언가를 잡을 수 있는가 (허용된 이름은 진짜로 거기 있다)
    for allowed in (:BatteryParams, :HazardParams, :RobotRec, :k_move, :hazard_rate_from,
                    :mode_power_W, :integrated_hazard, :inv_integrated_hazard)
        @test allowed in syms
    end
    @test hasmethod(CB.rate_params,
                    Tuple{CB.SimState,Any,CB.HazardParams,CB.BatteryParams,Float64})
end
