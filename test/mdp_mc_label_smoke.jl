# ============================================================================
#  🔴 KNOWN DEAD AT HEAD — 이 파일은 현재 로드 자체가 안 된다. 고쳐 쓰거나 지울 것.
#
#  :24 가 가리키는 `wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl` 은 2026-08-18
#  파일 정리에서 **삭제됐다**. 그래서 이 테스트는 첫 include 에서 죽는다:
#      rc=1  ERROR: LoadError: SystemError: opening file ".../oracle/gen_oracle_mc.jl"
#  실측: pristine `git archive` 기준으로 `902f98ca` 에서도 죽었고 지금도 죽는다 —
#  **이 브랜치가 낸 회귀가 아니다.** 옮겨진 경로가 아니라 지워진 대상이라 경로만 고쳐서는
#  살아나지 않는다(= `test/mdp_hazard_smoke.jl` 과는 다른 원인, 같은 결과).
#
#  ⚠️ 이것이 두 번째 사례다. `Pkg.test()` 의 `runtests.jl` 은 4개 파일만 include 하고
#  `test/smdp_*.jl`·`test/mdp_*.jl` 를 하나도 안 보므로 **테스트가 썩어도 아무도 모른다.**
#  `test/mdp_hazard_smoke.jl` 이 HEAD 에서 죽어 있던 것도 같은 구멍이었다. `test/smdp_all.jl`
#  러너(또는 runtests.jl 에 include 몇 줄)가 아직 빚으로 남아 있다.
#
#  되살리려면: `gen_oracle_mc.jl` 을 git 이력에서 복구하거나(K-rollout MC 라벨러),
#  그 역할을 물려받은 `oracle/gen_oracle_dataset.jl` 의 `DS_MC_K>1` 경로로 이 테스트를
#  다시 쓸 것. 둘 다 이 태스크의 범위 밖이라 **사실만 적어 둔다.**
# ============================================================================
# ============================================================================
#  MDP STEP 2 — K-rollout 몬테카를로 Q 라벨러의 **집계 수학**만 빠르게 검증하는 테스트.
#  (전체 시뮬은 후보×K 회 full build 라 몇 십 분 걸린다. 여기서는 시뮬 없이
#   비용 스칼라화·평균/표준오차·짝지은 차이·동점 판정·CRN 분산감소만 확인한다.)
#
#  검증 항목:
#   1) 스칼라 비용이 기존 lexicographic 순위(완주>닫힌노드>makespan)를 그대로 재현
#   2) COST_FAIL 이 너무 작으면 순서 동치가 깨지고, 그걸 실제로 감지하는지
#   3) Q̂ = 평균비용, SE = std/√K 가 맞는지
#   4) 짝지은 차이(CRN)가 짝짓지 않은 것보다 표준오차가 실제로 작은지
#   5) 동점(|Δ| ≤ 1.96·SE_paired)을 승리로 세지 않고 동점으로 라벨하는지
#   6) 확실한 차이는 동점으로 잘못 라벨하지 않는지
#
#   julia +lts --project=. test/mdp_mc_label_smoke.jl
# ============================================================================

using ConstructionBots
using Test
using Random
using Logging   # @test_logs min_level=Logging.Warn — "경고가 나지 않는다"를 단언하려면 필요
const CB = ConstructionBots

# 라벨러 스크립트를 include 하면 함수 정의만 들어온다(직접 실행이 아니면 main 을 안 돌림).
const MC = joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "gen_oracle_mc.jl")
include(MC)

# energy_J = 0.0 은 **이 테스트가 명시적으로 고른 상수**다(조용한 폴백이 아니다). 이 테스트가
# 검사하는 축은 완주/닫힌노드/makespan 의 순서동치이지 에너지 축이 아니므로 에너지를 0 으로
# 고정해 그 축을 제거한다. objective.json 의 스케일이 null 이면 Objective.energy_weight 가
# 던져 완주 케이스가 실패하는데, 그때는 이 테스트가 "스케일이 안 채워졌다"고 알려주는 것이 맞다.
_res(; complete, closed, total = 300, makespan, energy_J = 0.0) =
    (complete = complete, closed = closed, total = total, makespan = makespan,
     energy_J = energy_J)

@testset "스칼라 비용 == lexicographic 순위" begin
    # 완주가 항상 미완주를 이긴다 (makespan 이 훨씬 길어도)
    done_slow = _res(complete = true,  closed = 300, makespan = 900.0)
    undone_f  = _res(complete = false, closed = 299, makespan = 10.0)
    @test scalar_cost(done_slow) < scalar_cost(undone_f)
    @test better(done_slow, undone_f)

    # 미완주끼리는 닫힌 노드가 많을수록 낫다
    a = _res(complete = false, closed = 250, makespan = 500.0)
    b = _res(complete = false, closed = 200, makespan = 500.0)
    @test scalar_cost(a) < scalar_cost(b)
    @test better(a, b)

    # 같은 닫힌 노드 수면 makespan 이 짧을수록 낫다
    c = _res(complete = false, closed = 250, makespan = 400.0)
    @test scalar_cost(c) < scalar_cost(a)

    # 완주끼리는 makespan 이 곧 비용
    d = _res(complete = true, closed = 300, makespan = 120.0)
    e = _res(complete = true, closed = 300, makespan = 140.0)
    @test scalar_cost(d) == 120.0 && scalar_cost(e) == 140.0

    # 무작위 쌍 300개에 대해 스칼라 비용이 교정 규칙(better_ssp)과 항상 일치하는지 (핵심 불변식)
    rng = Random.MersenneTwister(3)
    for _ in 1:300
        x = _res(complete = rand(rng, Bool), closed = rand(rng, 100:300), makespan = 50 + 900rand(rng))
        y = _res(complete = rand(rng, Bool), closed = rand(rng, 100:300), makespan = 50 + 900rand(rng))
        (x.complete == y.complete && x.closed == y.closed && x.makespan == y.makespan) && continue
        @test better_ssp(x, y) == (scalar_cost(x) < scalar_cost(y))
    end
end

@testset "에너지 축: 예산 안의 역전은 정상, 예산 밖은 위반 (spec §3.1/§4.1)" begin
    # 위 testset 은 energy_J 를 0.0 으로 고정해 에너지 축을 **제거**한다. 그래서 에너지가 만드는
    # better_ssp 와의 정당한 불일치를 하나도 검사하지 못했다 — 그 사각지대를 여기서 메운다.
    wE = Objective.energy_weight(OBJ_CFG)
    E_lo, E_hi = 1.0e5, 4.0e5
    budget = wE * (E_hi - E_lo)          # 이 안의 makespan 차이는 에너지가 뒤집어도 정상
    @test budget > 0.0                   # kappa/스케일이 채워져 있어야 이 검사가 의미를 갖는다

    fast_hungry = _res(complete = true, closed = 300, makespan = 20.0, energy_J = E_hi)
    slow_lean   = _res(complete = true, closed = 300, makespan = 20.0 + 0.5budget, energy_J = E_lo)

    @test better_ssp(fast_hungry, slow_lean)                      # better_ssp 는 에너지를 모른다
    @test scalar_cost(slow_lean) < scalar_cost(fast_hungry)       # J 는 에너지를 보고 뒤집는다
    @test explained_by_energy(fast_hungry, slow_lean)             # 예산 안 = 설명되는 역전
    # 예산 안의 역전은 **경고 없이** 통과해야 한다. 옛 코드는 여기서 "raise MC_COST_FAIL" 을
    # 띄웠고, 그 조치로는 절대 고쳐지지 않는 거짓경보였다.
    @test (@test_logs min_level = Logging.Warn check_order_equivalence([fast_hungry, slow_lean])) == true

    # 예산 **밖**이면 속도가 이겨야 하고 better_ssp 와도 일치한다(= 위반 아님)
    slow_lean_far = _res(complete = true, closed = 300, makespan = 20.0 + 2budget, energy_J = E_lo)
    @test scalar_cost(fast_hungry) < scalar_cost(slow_lean_far)
    @test better_ssp(fast_hungry, slow_lean_far)
    @test !explained_by_energy(fast_hungry, slow_lean_far)
    @test check_order_equivalence([fast_hungry, slow_lean_far]) == true

    # 미완주 쌍에는 에너지가 아예 들어가지 않는다(§3.1) — 에너지를 100배 줘도 J 가 같아야 한다.
    u1 = _res(complete = false, closed = 250, makespan = 500.0, energy_J = E_lo)
    u2 = _res(complete = false, closed = 250, makespan = 500.0, energy_J = 100E_hi)
    @test scalar_cost(u1) == scalar_cost(u2)
    @test !explained_by_energy(u1, u2)                            # 완주가 아니면 설명 대상 아님
end

@testset "legacy `better` 와 의도적으로 갈리는 지점 (문서화된 편차)" begin
    # 이 하니스는 완주해도 closed < total 이다(실측: YES 291/313). 완주 후 남은 노드는 미완의
    # 작업이 아니라 장부다. legacy 규칙은 그 장부 노드를 더 닫았다는 이유로 **더 느린 실행**을
    # 낫다고 판정한다. SSP 는 흡수상태 도달 후엔 경과시간만 세므로 makespan 을 봐야 맞다.
    fast_fewer  = _res(complete = true, closed = 291, makespan = 100.0)   # 빠르지만 장부 덜 닫음
    slow_more   = _res(complete = true, closed = 300, makespan = 400.0)   # 느리지만 장부 더 닫음

    @test better(slow_more, fast_fewer)              # legacy: 느린 쪽이 낫다고 함 (오판)
    @test better_ssp(fast_fewer, slow_more)          # SSP: 빠른 쪽이 낫다 (정답)
    @test scalar_cost(fast_fewer) < scalar_cost(slow_more)

    # 그 외(완주 vs 미완주, 미완주끼리)에서는 두 규칙이 일치해야 한다
    rng = Random.MersenneTwister(9)
    for _ in 1:200
        x = _res(complete = false, closed = rand(rng, 100:300), makespan = 50 + 900rand(rng))
        y = _res(complete = rand(rng, Bool), closed = rand(rng, 100:300), makespan = 50 + 900rand(rng))
        (x.complete == y.complete && x.closed == y.closed && x.makespan == y.makespan) && continue
        @test better(x, y) == better_ssp(x, y)
    end
end

@testset "순서 동치 점검기가 실제로 위반을 잡는다" begin
    ok = [_res(complete = true, closed = 300, makespan = 100.0),
          _res(complete = false, closed = 280, makespan = 500.0)]
    @test check_order_equivalence(ok) == true

    # COST_FAIL 보다 긴 완주 makespan 이 있으면 스칼라 순서가 뒤집힌다 → 경고와 함께 false
    bad = [_res(complete = true,  closed = 300, makespan = 5.0e5),   # COST_FAIL(1e4) 보다 큼
           _res(complete = false, closed = 299, makespan = 10.0)]
    @test (@test_logs (:warn,) match_mode = :any check_order_equivalence(bad)) == false
end

# 집계 입력 행 만들기 (aggregate 가 기대하는 필드 모양 그대로)
_row(a, k, cost; complete = true, brk = 0, cell = 0, capped = false) =
    (action = a, rollout = k, hz_seed = 1000 + k, complete = complete,
     closed = 300, total = 300, makespan = cost, cost = cost,
     hz_break = brk, hz_cell = cell, hz_zone = 0, hz_pending = 0,
     hz_capped = capped, hz_sim_s = 20.0, agent = "R1")

@testset "Q̂ / SE 계산" begin
    costs = [100.0, 110.0, 120.0, 130.0, 140.0]
    rows = [_row(0, k, costs[k]) for k in 1:5]
    out, meta = aggregate(rows)
    c = out[1]
    @test c.K == 5
    @test c.Q ≈ 120.0                                  # 평균
    @test c.se ≈ sqrt(sum((x - 120.0)^2 for x in costs) / 4) / sqrt(5)
    @test c.is_best                                     # 후보가 하나뿐이면 그게 최선
    @test c.delta_vs_best ≈ 0.0
end

@testset "CRN: 짝지은 차이가 짝 안 지은 것보다 표준오차가 작다" begin
    # 공유 궤적 잡음(rollout 마다 ±큰 값) + 팔 고유 효과(+20). 짝지으면 공유 잡음이 상쇄된다.
    rng = Random.MersenneTwister(11)
    shared = [200.0 * randn(rng) for _ in 1:12]          # rollout k 의 "운"
    rows = NamedTuple[]
    for k in 1:12
        push!(rows, _row(1, k, 100.0 + shared[k]))       # Replace
        push!(rows, _row(0, k, 120.0 + shared[k]))       # NOOP: 항상 정확히 20 나쁨
    end
    out, meta = aggregate(rows)
    best = only(filter(c -> c.is_best, out))
    other = only(filter(c -> !c.is_best, out))
    @test best.action == 1                               # Replace 가 이겨야 함
    @test other.delta_vs_best ≈ 20.0 atol = 1e-9         # 짝지은 차이는 잡음 없이 정확히 20
    @test other.se_paired ≈ 0.0 atol = 1e-9              # 공유 잡음이 완전히 상쇄
    @test other.se > 10.0                                # 짝 안 지으면 표준오차가 큼
    @test meta.crn_variance_reduction > 100.0            # 분산감소 배수가 실제로 크게 나옴
    @test !other.tied_with_best                          # 확실한 차이는 동점이 아님
end

@testset "동점은 동점으로 라벨한다 (승리로 세지 않음)" begin
    # 두 팔의 참 차이가 0 이고 잡음만 있는 경우 → 동점으로 표시되어야 한다.
    rng = Random.MersenneTwister(5)
    rows = NamedTuple[]
    for k in 1:10
        push!(rows, _row(1, k, 100.0 + 5randn(rng)))
        push!(rows, _row(0, k, 100.0 + 5randn(rng)))
    end
    out, _ = aggregate(rows)
    other = only(filter(c -> !c.is_best, out))
    @test other.tied_with_best                           # 구별 불가 → 동점
end

@testset "P(complete) / 사후 사건 수 / 상한 걸린 rollout 집계" begin
    rows = [_row(1, 1, 100.0; complete = true,  brk = 1, cell = 2),
            _row(1, 2, 100.0; complete = true,  brk = 3, cell = 0, capped = true),
            _row(1, 3, 9000.0; complete = false, brk = 0, cell = 1),
            _row(1, 4, 100.0; complete = true,  brk = 0, cell = 0)]
    out, _ = aggregate(rows)
    c = out[1]
    @test c.p_complete ≈ 0.75
    @test c.mean_hz_events ≈ (3 + 3 + 1 + 0) / 4
    @test c.n_capped == 1        # 미래가 잘린 rollout 은 반드시 따로 세어 보고해야 함
end

@testset "1-shot 기준선(rollout=0)은 MC 평균에 섞이지 않는다" begin
    # rollout 0 = 위험 프로세스를 끄고 한 번만 돌린 기존 라벨. Q̂ 계산에 들어가면 안 된다.
    rows = [_row(1, 0, 5.0), _row(0, 0, 7.0),            # 기준선 (터무니없이 싼 값)
            _row(1, 1, 100.0), _row(1, 2, 120.0),
            _row(0, 1, 200.0), _row(0, 2, 220.0)]
    out, meta, refs = aggregate(rows)
    @test length(refs) == 2                                # 기준선은 따로 빠져나온다
    a1 = only(filter(c -> c.action == 1, out))
    @test a1.K == 2                                        # rollout 0 은 K 에 안 셈
    @test a1.Q ≈ 110.0                                     # (100+120)/2 — 5.0 이 섞이지 않음
    @test meta.ref_best_action == 1
    @test meta.ref_agrees_with_mc                          # 이 경우 둘 다 action 1 이 최선

    # 기준선과 MC 의 argmin 이 갈리는 경우도 감지되어야 한다
    rows2 = [_row(0, 0, 5.0), _row(1, 0, 9.0),             # 1-shot 은 NOOP 이 낫다고 함
             _row(0, 1, 900.0), _row(0, 2, 900.0),         # 그러나 미래를 보면 NOOP 이 훨씬 나쁨
             _row(1, 1, 100.0), _row(1, 2, 100.0)]
    _, meta2, _ = aggregate(rows2)
    @test meta2.ref_best_action == 0
    @test meta2.best_action == 1
    @test !meta2.ref_agrees_with_mc
end

@testset "기준선만 있으면 집계가 빈 결과를 돌려준다(조용히 틀리지 않기)" begin
    out, meta, refs = aggregate([_row(1, 0, 5.0), _row(0, 0, 7.0)])
    @test isempty(out)
    @test length(refs) == 2
    @test meta.K == 0
end

println("\nmdp_mc_label_smoke: ALL PASS")
