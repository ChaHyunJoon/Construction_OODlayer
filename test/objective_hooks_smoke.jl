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
    # println (not @info): 이 파일의 어느 testset 이든 build_env 뒤로 옮겨지면 @info 는 조용히
    # 사라진다 — run_lego_demo 이 전역 로거를 Warn 으로 낮추고 원복하지 않는다(아래 finally 주석).
    println(">>> objective weights: κ=", w.kappa, "  w_g=", w.w_g)
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
        local w_real = CB.GREEDY_ENERGY_W[]
        # 기본값은 **실패 쪽**이다: 예외로 빠져나가면 그대로 찍힌다. 판정 문자열이 결과보다
        # 낙관적이면 안 된다 — 실패를 "통과"로 인쇄하는 것이 이 파일에서 가장 나쁜 버그다.
        local verdict = "❌ 판정 불가 — 예외로 중단됨"
        try
            base   = fingerprint(build_env(CB.GreedyFinalTimeCost()))
            energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
            # 다르면 확장점이 살아 있다는 뜻. 같으면 §2.4 의 결함이 되살아난 것 —
            # 다만 w_g 가 너무 작아 argmin 이 한 번도 안 갈리는 경우도 같은 증상이라, 그때는
            # w_g 를 크게 키워 다시 본다(디스패치가 살아 있음만 확인하는 목적).
            local boosted = false
            if base == energy
                CB.GREEDY_ENERGY_W[] = 1.0e6   # 확실히 지배적인 값
                energy = fingerprint(build_env(CB.GreedyEnergyAwareCost()))
                boosted = true
            end
            # 판정은 **실제 결과에서** 유도한다. 예전에는 1e6 재검사가 실패해도 finally 가
            # "약한 통과"를 찍었다 — @test 는 실패를 기록만 하고 던지지 않기 때문이다.
            local ok = base != energy
            verdict = if !ok
                "❌ 실패 — w_g=1e6 으로 키워도 배정이 안 갈렸다. greedy_cost 디스패치 확장점이 " *
                "죽었다(§2.4 결함 재발): 값이 저장만 되고 아무도 안 읽는 상태로 되돌아갔다."
            elseif boosted
                "약한 통과 — 실제 w_g=$(w_real) 로는 배정이 안 갈려 w_g=1e6 으로 " *
                "재검사했다 (디스패치 생존만 확인, 실제 w_g 의 실효는 미검증)"
            else
                "강한 통과 — 실제 w_g=$(w_real) 만으로 배정이 갈렸다 (에너지 항이 동점해소자 이상)"
            end
            @test ok
        finally
            CB.GREEDY_ENERGY_W[] = w_real   # 1e6 이 다음 testset/호출자로 새 나가지 않게 원복
            # `@info` 가 아니라 `println` 을 쓴다(방어적). run_lego_demo 이 예전에는
            # `global_logger(ConsoleLogger(stderr, Warn))` 를 심고 **원복하지 않아서** 첫
            # build_env 이후의 모든 @info 가 조용히 사라졌고, 실제로 이 줄이 통째로 안 찍혀
            # 라운드 1 에서 틀린 결론을 보고했다. 그 누수는 고쳤지만(래퍼가 finally 로 원복),
            # 진단 출력이 로깅 설정에 의존하지 않는 편이 낫다 — println 은 그 층을 안 탄다.
            println(">>> greedy 디스패치 판정: ", verdict,
                    "  (w_g restored = ", CB.GREEDY_ENERGY_W[], ")")
        end
    end
end
