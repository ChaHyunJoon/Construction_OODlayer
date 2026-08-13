# ============================================================================
#  spec §9 의 두 검사:
#    (a) 배터리 훅 활성 검사 — 재풀이에서 LAST_AUTO_EFFICIENCY_W[] > 0 인가
#        (지금까지는 DeprioritizeAgent 에서만 참이었다 — spec §2.2 의 결함)
#    (b) greedy 디스패치 생존 검사 — greedy_cost 를 바꾸면 배정이 실제로 달라지는가
#        (§2.4 의 결함: 값이 저장만 되고 안 읽히는 상태로 되돌아가는 것을 막는다)
#
#  ⚠️ 지문(fingerprint) 비교는 **한 프로세스 안에서만** 유효하다. 태스크 2 의 5회 실측이
#     보인 대로, 재컴파일만으로도 배정 지문이 갈린다(test/greedy_cost_dispatch_equivalence.jl
#     의 머리말 참조). 이 파일은 두 env 를 같은 프로세스에서 만들어 비교하므로 유효하다 —
#     여기서 찍힌 지문을 다른 julia 런의 지문과 비교하면 안 된다.
#
#  ⚠️ test/runtests.jl 에 등록하지 않는다(수동 게이트 — 등록하면 기대 baseline 11/1 이 바뀐다).
#
#    julia +lts --project=. test/objective_hooks_smoke.jl
# ============================================================================
using ConstructionBots
using Test
using Random
using Graphs
const CB = ConstructionBots

@testset "objective.json 이 두 자리에 심긴다" begin
    w = CB.init_objective_weights!()
    @test CB.AUTO_EFFICIENCY_KAPPA[] !== nothing
    @test CB.AUTO_EFFICIENCY_KAPPA[] > 0.0
    @test w.kappa == CB.AUTO_EFFICIENCY_KAPPA[]
    # T_scale/Eg_scale 이 채워져 있으면 w_g 도 양수여야 한다.
    if CB.GREEDY_ENERGY_W[] !== nothing
        @test CB.GREEDY_ENERGY_W[] > 0.0
    end
    @info "objective weights" kappa = w.kappa w_g = w.w_g
end

@testset "w_g 가 없으면 GreedyEnergyAwareCost 는 조용히 폴백하지 않고 던진다 (spec §5)" begin
    saved = CB.GREEDY_ENERGY_W[]
    try
        CB.GREEDY_ENERGY_W[] = nothing
        @test_throws ErrorException CB.greedy_edge_cost(
            CB.GreedyEnergyAwareCost(), CB.OperatingSchedule(), 1, 2, 1.0)
    finally
        CB.GREEDY_ENERGY_W[] = saved
    end
end

# 배정만 하고 멈추는 env 빌더(greedy_assignment_regression.jl 과 같은 모델·시드).
function build_env(gcost)
    return CB.run_lego_demo(; ldraw_file = get(ENV, "GREEDY_REG_MODEL", "tractor.mpd"),
        project_name = "objhook", num_robots = 12, assignment_mode = :greedy,
        save_animation = false, write_results = false, overwrite_results = true,
        return_env_before_sim = true, rng = Random.MersenneTwister(3),
        greedy_cost = gcost)
end

function fingerprint(env)
    io = IOBuffer()
    for e in sort(collect(Graphs.edges(env.sched.graph)), by = x -> (Graphs.src(x), Graphs.dst(x)))
        println(io, Graphs.src(e), "->", Graphs.dst(e))
    end
    for v in 1:Graphs.nv(env.sched)
        println(io, v, "=", round(CB.get_tF(env.sched, v), digits = 6))
    end
    return String(take!(io))
end

@testset "greedy 디스패치 생존 — greedy_cost 를 바꾸면 배정이 달라진다" begin
    CB.init_objective_weights!()
    if CB.GREEDY_ENERGY_W[] === nothing
        @info "T_scale/Eg_scale 미측정 — 이 검사 건너뜀"
        @test true
    else
        base   = fingerprint(build_env(CB.GreedyFinalTimeCost()))
        energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
        # 다르면 확장점이 살아 있다는 뜻. 같으면 §2.4 의 결함이 되살아난 것 —
        # 다만 w_g 가 너무 작아 argmin 이 한 번도 안 갈리는 경우도 같은 증상이라, 그때는
        # w_g 를 크게 키워 다시 본다(디스패치가 살아 있음만 확인하는 목적).
        if base == energy
            CB.GREEDY_ENERGY_W[] = 1.0e6   # 확실히 지배적인 값
            energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
            @info "w_g 를 1e6 으로 키워 재검사 (원래 w_g 로는 배정이 안 갈렸다 = κ 가 동점해소자 크기)"
        end
        @test base != energy
    end
end
