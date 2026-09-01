# test/payload_factor.jl
#   julia +lts --project=. test/payload_factor.jl
# 🔴 집계는 전부 함수 안에서 한다 — top-level for 안의 카운터는 soft scope 로 조용한 0 이 된다.
module PayloadFactorTest
using Test
using ConstructionBots
import Random, Graphs
const CB = ConstructionBots
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))

@testset "_payload_factor 는 순수하고 1.0 아래로 안 내려간다" begin
    @test CB._payload_factor(0.0, 0.5) == 1.0          # 짐이 없으면 벌점 없음
    @test CB._payload_factor(12.8, 0.0) == 1.0         # bias 0 이면 payload 항이 사라진다
    @test CB._payload_factor(12.8, 1.0) == 2.0         # ref 만큼 무거우면 정확히 2배
    @test CB._payload_factor(-5.0, 1.0) == 1.0         # 음수 질량은 clamp
    @test CB._payload_factor(12.8, -1.0) == 1.0        # 음수 bias 는 clamp (인센티브 금지)
    @test CB._payload_factor(6.4, 1.0) < CB._payload_factor(12.8, 1.0)   # 단조 증가
end

# 🔴 실측 게이트. 한 홉 조회가 **실제 후보 간선 전부**에서 값을 내는지 본다.
#    음성 대조: v2 자신에서 재면 하나도 못 잰다(그것이 2026-08-30 설계의 실패 지점이다).
function measure()
    env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "payload_factor_gate",
                             num_robots = 10, assignment_mode = :greedy, n_spare_per_pool = 2,
                             open_animation_at_end = false, save_animation = false,
                             write_results = false, return_env_before_sim = true,
                             rng = Random.MersenneTwister(1))
    sched, tree = deepcopy((env.sched, env.scene_tree))
    shim = (sched = sched, scene_tree = tree, cache = env.cache)
    CB.release_pending_assignments!(shim, CB.build_invariant(env))
    sent = Dict{Tuple{Int,Int},Float64}()
    CB.LAST_EDGE_COSTS[] = sent
    CB.formulate_milp(CB.SparseAdjacencyMILP(), sched, tree; optimizer = CB._respec_optimizer())
    @assert !(CB.LAST_EDGE_COSTS[] === sent) "formulate 가 안 돌았다"
    ec = CB.LAST_EDGE_COSTS[]
    p = CB.BatteryParams()
    hop = 0; direct = 0; ms = Float64[]
    for (v, v2) in keys(ec)
        m = CB.candidate_edge_payload_mass(shim, sched, v2, p)
        m === nothing || (hop += 1; push!(ms, m))
        d = try CB._payload_mass_measured(shim,
                CB.get_node_from_id(sched, CB.get_vtx_id(sched, v2)), p) catch; nothing end
        d === nothing || (direct += 1)
    end
    return (n = length(ec), hop = hop, direct = direct, distinct = length(unique(round.(ms, digits=6))))
end

@testset "한 홉 조회가 후보 간선 전부에서 화물을 잰다" begin
    r = measure()
    @test r.n > 0                       # 창이 열려 있어야 이 시험이 의미가 있다
    @test r.hop == r.n                  # 🔴 전부 잰다
    @test r.direct == 0                 # 음성 대조: v2 자신에서는 하나도 못 잰다
    @test r.distinct >= 5               # 분산이 있어야 재가격이 팔을 가른다
end
end # module
