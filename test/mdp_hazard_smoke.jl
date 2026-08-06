# ============================================================================
#  이 파일이 하는 일: MDP 1단계 산출물인 "확률적 고장 프로세스"(src/mdp/hazard.jl)의
#  수학이 실제로 맞는지 빠르게 검증하는 smoke 테스트. 실제 빌드(MILP/LDraw)를 돌리지
#  않고, 난수/위험률/지수시계만 떼어내 통계적으로 확인한다.
#
#  검증 항목:
#   1) ε_r(방전 효율 편차)의 평균이 1 (에너지 회계를 편향시키지 않아야 함)
#   2) Exp(1) 표집이 실제로 평균/분산 1
#   3) λ 가 설계대로 반응: 누적사용↑ / SoC↓ / 운반모드 → 커지고, 대기 → 작아짐
#   4) "지수 시계" 구성이 정확 표집인가 = 상수 λ 에서 고장시각의 평균이 1/λ
#   5) 같은 seed → 같은 실행(재현성), 다른 seed → 다른 실행
#   6) MTBF=Inf 면 그 위험이 완전히 꺼짐
#   7) 훅이 꺼져 있을 때 방전 배수가 정확히 1.0 (기존 실행 무변경 보장)
#
#   julia +lts --project=. test/mdp_hazard_smoke.jl
# ============================================================================

using ConstructionBots
using Test
using Random
using Statistics
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

@test CB.navigator_loaded()
@test CB.mdp_loaded()

# 테스트용 HazardState 를 env 없이 손으로 하나 만든다(로봇 id 는 그냥 Int 사용).
# 생성자는 hazard.jl 과 공유(_new_hazard_state) — 필드가 늘어도 테스트가 안 깨진다.
_mk_state(; seed = 0, kw...) = CB._new_hazard_state(CB.HazardParams(; kw...), seed)

@testset "난수 기본형" begin
    rng = Random.MersenneTwister(1)
    e = [CB._exp1(rng) for _ in 1:200_000]
    @test isapprox(mean(e), 1.0; atol = 0.02)          # Exp(1) 평균 = 1
    @test isapprox(std(e), 1.0; atol = 0.02)           # Exp(1) 표준편차 = 1

    rng2 = Random.MersenneTwister(2)
    f = [CB._lognorm1(rng2, 0.15) for _ in 1:200_000]
    @test isapprox(mean(f), 1.0; atol = 0.01)          # ε_r 평균 = 1 (에너지 회계 무편향)
    @test std(f) > 0.10                                 # 실제로 흩어져 있어야 확률적
    @test CB._lognorm1(rng2, 0.0) == 1.0               # σ=0 이면 결정론

    @test CB._rate(Inf) == 0.0                          # MTBF=Inf -> 위험 꺼짐
    @test CB._rate(0.0) == 0.0
    @test CB._rate(100.0) ≈ 0.01
end

@testset "λ 가 상태에 올바르게 반응" begin
    st = _mk_state(mtbf_break_s = 100.0, usage_scale_s = 100.0,
                   beta_usage = 1.0, beta_soc = 1.2,
                   mult_idle = 0.1, mult_carry = 2.0, mult_manip = 1.4)
    CB._hz_ensure!(st, 1)

    λ_ref = CB.hazard_rate(st, 1; mode = :transit, soc = 1.0)
    @test λ_ref ≈ 0.01                                  # 기준 조건 = 1/MTBF 정확히

    # 모드: 대기 < 이동 < 조작 < 운반
    @test CB.hazard_rate(st, 1; mode = :idle,  soc = 1.0) < λ_ref
    @test CB.hazard_rate(st, 1; mode = :manip, soc = 1.0) > λ_ref
    @test CB.hazard_rate(st, 1; mode = :carry, soc = 1.0) >
          CB.hazard_rate(st, 1; mode = :manip, soc = 1.0)

    # SoC 가 낮을수록 고장률 증가 (exp(β_s·(1−soc)))
    @test CB.hazard_rate(st, 1; mode = :transit, soc = 0.2) > λ_ref
    @test CB.hazard_rate(st, 1; mode = :transit, soc = 0.2) ≈ λ_ref * exp(1.2 * 0.8)

    # 누적 사용량(마모)이 쌓이면 고장률 증가
    st.usage_s[1] = 100.0                               # û = 1
    @test CB.hazard_rate(st, 1; mode = :transit, soc = 1.0) ≈ λ_ref * exp(1.0)

    # 셀 열화 위험은 SoC 에 의존하지 않아야 함(SoC 는 결과지 원인이 아니므로)
    st.usage_s[1] = 0.0
    @test CB._cell_rate(st, 1; mode = :transit) ≈ 1 / st.params.mtbf_cell_s
end

@testset "지수 시계가 정확 표집인가 (상수 λ -> Exp(λ) 고장시각)" begin
    # hazard_step! 의 적분 누적 로직만 떼어내 재현: Λ += λ·dt, Λ ≥ E 이면 고장.
    # 상수 λ 라면 고장시각 T 는 정확히 Exp(λ) 여야 하고 E[T] = 1/λ.
    λ = 0.02; dt = 0.025                                # dt = 1/40 s (엔진과 동일)
    rng = Random.MersenneTwister(7)
    T = Float64[]
    for _ in 1:20_000
        E = CB._exp1(rng); Λ = 0.0; t = 0.0
        while Λ < E
            Λ += λ * dt; t += dt
        end
        push!(T, t)
    end
    # dt 격자 위에서의 정확한 기대값: K = ceil(E/(λ·dt)) 는 p = 1−exp(−λ·dt) 인 기하분포이므로
    #   E[T] = dt / (1 − exp(−λ·dt)).   n=20000, sd≈1/λ 이므로 표준오차 ≈ (1/λ)/√n ≈ 0.35 → 3SE ≈ 1.1.
    T_grid = dt / (1 - exp(-λ * dt))
    @test isapprox(mean(T), T_grid; atol = 1.2)         # 격자 위 이론 평균과 일치(MC 오차 3SE 이내)
    @test isapprox(mean(T), 1 / λ; rtol = 0.03)         # 연속시간 평균 1/λ = 50 s 와도 일치
    @test isapprox(std(T), 1 / λ; rtol = 0.05)          # 지수분포이므로 표준편차도 1/λ
    # 이산화 편향은 정확히 dt/2 수준 — 스텝당 베르누이 근사와 달리 λ 에 비례하는 편향이 없다.
    @test abs(T_grid - 1 / λ) < dt
end

@testset "경쟁 위험: 여러 시계 중 가장 먼저 넘는 것이 발화" begin
    # 로봇 3대, λ 가 서로 다르면 가장 높은 λ 의 로봇이 가장 자주 먼저 고장나야 한다.
    rng = Random.MersenneTwister(11)
    λs = [0.01, 0.02, 0.04]; dt = 0.025
    first_ct = zeros(Int, 3)
    for _ in 1:5_000
        E = [CB._exp1(rng) for _ in 1:3]; Λ = zeros(3); winner = 0; t = 0.0
        while winner == 0
            Λ .+= λs .* dt; t += dt
            for i in 1:3
                Λ[i] >= E[i] && (winner = i; break)
            end
        end
        first_ct[winner] += 1
    end
    @test first_ct[3] > first_ct[2] > first_ct[1]
    # 경쟁위험 이론값: P(i 가 먼저) = λ_i / Σλ
    @test isapprox(first_ct[3] / 5_000, 0.04 / 0.07; atol = 0.03)
end

@testset "재현성 (같은 seed = 같은 실행)" begin
    a = _mk_state(seed = 42); b = _mk_state(seed = 42); c = _mk_state(seed = 43)
    for id in 1:5
        CB._hz_ensure!(a, id); CB._hz_ensure!(b, id); CB._hz_ensure!(c, id)
    end
    @test [a.eff[i] for i in 1:5] == [b.eff[i] for i in 1:5]
    @test [a.thr_break[i] for i in 1:5] == [b.thr_break[i] for i in 1:5]
    @test [a.eff[i] for i in 1:5] != [c.eff[i] for i in 1:5]
end

@testset "CRN: 등록 순서가 달라도 로봇별 난수열이 동일" begin
    # STEP 2 의 짝지은 비교(paired MC)가 성립하려면, 팔 A 가 스페어를 더 투입해 로봇 등록 순서가
    # 달라져도 "같은 로봇은 같은 운"을 받아야 한다. 공유 스트림이면 여기서 어긋난다.
    a = _mk_state(seed = 7); b = _mk_state(seed = 7)
    for id in [1, 2, 3, 4, 5];               CB._hz_ensure!(a, id) end   # 정순 등록
    for id in [5, 3, 99, 1, 4, 2];           CB._hz_ensure!(b, id) end   # 역순 + 중간에 낯선 로봇
    for id in 1:5
        @test a.eff[id]       == b.eff[id]
        @test a.thr_break[id] == b.thr_break[id]
        @test a.thr_cell[id]  == b.thr_cell[id]
    end
    # 로봇들끼리는 서로 다른 값을 받아야 한다(스트림이 실제로 갈라져 있는지)
    @test length(unique([a.eff[i] for i in 1:5])) == 5

    # 시드가 다르면 같은 로봇도 다른 운을 받아야 한다(= rollout k 마다 다른 미래)
    c = _mk_state(seed = 8); CB._hz_ensure!(c, 1)
    @test c.thr_break[1] != a.thr_break[1]

    # 셀 사건 심각도 스트림도 "그 로봇의 n 번째 사건"에 고정 — 한쪽에서 다른 로봇 사건이 먼저
    # 일어나도 대상 로봇의 심각도 열은 안 밀린다.
    ra1 = CB._robot_rng(a, 3); ra2 = CB._robot_rng(b, 3)
    @test [rand(ra1) for _ in 1:4] == [rand(ra2) for _ in 1:4]
end

@testset "꺼져 있으면 완전 무동작 (기존 실행 무변경)" begin
    @test CB.HAZARD_ENABLED[] == false
    @test CB.hazard_enabled() == false
    @test CB.hazard_drain_factor(:anything) == 1.0     # 훅이 꺼져 있으면 방전 배수 정확히 1.0
    @test CB.DRAIN_FACTOR_HOOK[] === nothing
    @test CB._drain_factor(:anything) == 1.0           # battery.jl 쪽 소비자도 1.0
    @test isempty(CB.hazard_events())
    r = CB.hazard_report()
    @test r.n_break == 0 && r.n_cell == 0 && r.n_zone == 0
end

@testset "MTBF=Inf 는 그 위험을 완전히 끔" begin
    st = _mk_state(mtbf_break_s = Inf, mtbf_cell_s = Inf, mtbf_zone_s = Inf)
    CB._hz_ensure!(st, 1)
    @test CB.hazard_rate(st, 1; mode = :carry, soc = 0.0) == 0.0
    @test CB._cell_rate(st, 1; mode = :carry) == 0.0
end

@testset "보정 도우미 expected_hazard_events" begin
    st = _mk_state(mtbf_break_s = 900.0, mtbf_cell_s = 1200.0, mtbf_zone_s = Inf)
    e = CB.expected_hazard_events(st, 500.0; n_robots = 8, mode = :transit)
    @test isapprox(e.breakdown, 8 * 500 / 900; rtol = 1e-9)
    @test isapprox(e.cell, 8 * 500 / 1200; rtol = 1e-9)
    @test e.zone == 0.0
end

println("\nmdp_hazard_smoke: ALL PASS")
