# =============================================================================
# selfimprove 불변식 I1–I4 (spec §9.3, §0.0 R5) — `tools/monitor/invariants.jl`.
# 완주한 작은 판(colored_8x8) 위에서 음성 대조 넷 + 양성 하나:
#   (c) 사건 시점 zone 삭제 → I1b fail
#   (d) 부품 하나와 그 목표를 함께 이동(= 부품이 조립체 안에서 다른 자리에 놓임) → I2 fail
#   (e) 빌드 전체 평면 평행이동(루트 조립체) → I1·I2 ok
#   (b) 빌드 노드 사이 의존 경로 끊기 → I1 fail
#   (a) ProjectComplete 노드 삭제 → I1 fail
#   + I3 는 아직 안 놓인 화물만 센다, I4 는 스트림 프레임에서 잰다(팔 미집행이면 "na").
# 실행: julia +lts --project=. test/selfimprove_invariants.jl
# =============================================================================
module SelfimproveInvariants

using Test
using ConstructionBots
const CB = ConstructionBots
import JSON3, Graphs, Random
using LinearAlgebra
import CoordinateTransformations

include(joinpath(@__DIR__, "..", "tools", "monitor", "invariants.jl"))

const ENV_, _ = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr", project_name = "selfimprove_inv",
    num_robots = 4, assignment_mode = :greedy, open_animation_at_end = false, save_animation = false,
    write_results = false, rng = Random.MersenneTwister(1), pre_sim_hook = snapshot_t0!)

inv() = JSON3.read(invariant_line(ENV_)[length("[invariant] ")+1:end], Dict{String,Any})

@testset "selfimprove invariants" begin
    @test CB.project_complete(ENV_)
    @testset "baseline: 완주 판은 전부 ok" begin
        CB.add_restriction_zone!(:si_z, [100.0, 100.0], 1.0)
        snapshot_zones!()
        r = inv()
        @test r["I1"] == "ok" && r["I1b"] == "ok" && r["I2"] == "ok"
        @test r["I3"] == 0 && r["I4"] == "na"
    end
    @testset "(c) zone 삭제 → I1b" begin
        CB.remove_restriction_zone!(:si_z)
        @test startswith(inv()["I1b"], "fail")
        CB.add_restriction_zone!(:si_z, [100.0, 100.0], 0.5)          # 줄인 것도 위반
        @test startswith(inv()["I1b"], "fail")
        CB.add_restriction_zone!(:si_z, [100.0, 100.0], 1.0)
        @test inv()["I1b"] == "ok"
    end
    @testset "(d) 부품 하나를 그 목표와 함께 옮김 → I2" begin
        id = first(k for k in keys(INV_T0[].L0) if k isa CB.ObjectID)
        sn = CB.get_node(ENV_.scene_tree, id)
        lt = CB.local_transform(sn)
        CB.set_local_transform!(sn, CoordinateTransformations.Translation(0.5, 0.0, 0.0) ∘ lt)
        @test startswith(inv()["I2"], "fail")
        CB.set_local_transform!(sn, lt)
        @test inv()["I2"] == "ok"
    end
    @testset "(e) 빌드 전체 평면 평행이동 → ok" begin
        root = CB.get_node(ENV_.scene_tree, INV_T0[].root)
        lt = CB.local_transform(root)
        CB.set_local_transform!(root, CoordinateTransformations.Translation(3.0, -2.0, 0.0) ∘ lt)
        r = inv()
        @test r["I1"] == "ok" && r["I2"] == "ok"
        CB.set_local_transform!(root, CoordinateTransformations.Translation(0.0, 0.0, 0.7) ∘ lt)
        @test startswith(inv()["I2"], "fail")                          # 수직 이동은 평행이동이 아니다
        CB.set_local_transform!(root, lt)
    end
    @testset "I3 는 아직 안 놓인 화물의 표류만 센다" begin
        lift = first(n for n in CB.get_nodes(ENV_.sched) if CB.matches_template(CB.LiftIntoPlace, n) &&
                                                          CB.node_id(CB.entity(n)) isa CB.ObjectID)
        v = CB.get_vtx(ENV_.sched, CB.node_id(lift))
        delete!(ENV_.cache.closed_set, v)                  # 그 부품이 아직 안 놓였다고 치면
        @test inv()["I3"] >= 1                             # 시작 자세에서 멀리 떨어진 free 화물 = 표류
        push!(ENV_.cache.closed_set, v)
        @test inv()["I3"] == 0
    end
    @testset "I4 는 스트림 프레임에서" begin
        fr = [Dict("sim_t" => 1.0, "n_closed" => 5), Dict("sim_t" => 2.0, "n_closed" => 5),
              Dict("sim_t" => 3.5, "n_closed" => 6)]
        @test i4_from_frames(fr, (5, 1.5)) == 2.0
        @test i4_from_frames(fr[1:2], (5, 1.5)) == Inf
        @test i4_from_frames(fr, nothing) == "na"
    end
    @testset "(b) 빌드 노드 의존 경로 끊기 → I1" begin
        g = CB.get_graph(ENV_.sched)
        pc = first(v for v in Graphs.vertices(g)
                   if CB.matches_template(CB.ProjectComplete, CB.get_node(ENV_.sched, v)))
        for u in collect(Graphs.inneighbors(g, pc))
            Graphs.rem_edge!(g, u, pc)
        end
        @test startswith(inv()["I1"], "fail")
    end
    @testset "(a) ProjectComplete 삭제 → I1" begin
        pc = first(n for n in CB.get_nodes(ENV_.sched) if CB.matches_template(CB.ProjectComplete, n))
        CB.rem_node!(ENV_.sched, CB.node_id(pc))
        @test startswith(inv()["I1"], "fail")
    end
end
CB.clear_restriction_zones!()

end # module
