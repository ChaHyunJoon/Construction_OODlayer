# test/zone_facts_is_sensor_only.jl — zone_facts 는 zone_diagnosis 의 관측 필드와 같고 해법기를 안 부른다
#   julia +lts --project=. test/zone_facts_is_sensor_only.jl   (수동 — env 빌드가 수 분)
using ConstructionBots, Test
import Random
const CB = ConstructionBots

pp  = CB.get_project_params("tractor.mpd")
env = CB.run_lego_demo(; ldraw_file = "tractor.mpd", project_name = "zone_facts",
                         num_robots = pp[:num_robots], model_scale = pp[:model_scale],
                         assignment_mode = :greedy, n_spare_per_pool = 2,
                         open_animation_at_end = false, save_animation = false,
                         write_results = false, return_env_before_sim = true,
                         rng = Random.MersenneTwister(1))

saved = copy(CB.RESTRICTION_ZONES[])
try
    CB.clear_restriction_zones!()
    ks = sort!(collect(keys(env.staging_circles)); by = string)
    root = argmax(k -> Float64(CB.get_radius(env.staging_circles[k])), ks)
    aid = first(k for k in ks if k != root)
    b = env.staging_circles[aid]
    CB.add_restriction_zone!(:zf, Vector{Float64}(CB.get_center(b)[1:2]), 0.5 * Float64(CB.get_radius(b)))

    @testset "관측 필드가 zone_diagnosis 와 같다" begin
        d = CB.zone_diagnosis(env, :zf)
        f = CB.zone_facts(env, :zf)
        solver = (:feasible, :n_restage_feasible, :relocate_delta, :relocate_norm, :relocate_feasible, :verdict)
        @test Set(keys(f)) == setdiff(Set(keys(d)), Set(solver))
        for k in keys(f)
            @test isequal(getfield(f, k), getfield(d, k))
        end
        @test f.n_blocked >= 1                     # 도메인: 존이 실제로 조립체 하나를 덮는다
    end

    @testset "무장된 :all 에서도 던지지 않는다 = 해법기 호출 0" begin
        try
            CB.set_repair_ablation!(:all); CB.arm_repair_ablation!()
            @test CB.zone_facts(env, :zf).exists
            @test !any(startswith(k, "denied:") for k in keys(CB.ablation_counts()))
        finally
            CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
        end
    end

    @testset "없는 존은 exists=false 이고 삼상 필드는 nothing" begin
        f = CB.zone_facts(env, :no_such)
        @test f.exists === false
        @test f.project_blocked === nothing
    end
finally
    CB.clear_restriction_zones!()
    for (k, z) in saved
        CB.add_restriction_zone!(k, Vector{Float64}(CB.get_center(z)[1:2]), Float64(CB.get_radius(z)))
    end
end
