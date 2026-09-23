# test/repair_ablation_core.jl — 존 복구 base ablation 핵심(순수, env 없음)
#   julia +lts --project=. test/repair_ablation_core.jl
using ConstructionBots, Test
const CB = ConstructionBots

@testset "레벨 파싱은 셋만 받고 나머지는 크게 죽는다" begin
    @test CB.parse_repair_ablation("none") === :none
    @test CB.parse_repair_ablation("translate") === :translate
    @test CB.parse_repair_ablation("all") === :all
    for bad in ("", "ALL", "a2", "None", " all")
        @test_throws ErrorException CB.parse_repair_ablation(bad)
    end
    @test CB.repair_ablation_from_env(Dict{String,String}()) === :none
    @test CB.repair_ablation_from_env(Dict("REPAIR_ABLATION" => "all")) === :all
    @test_throws ErrorException CB.repair_ablation_from_env(Dict("REPAIR_ABLATION" => ""))
end

@testset "차단 목록은 명세 §3 과 같고 translate ⊂ all 이다" begin
    @test isempty(CB.ablated_names(:none))
    @test Set(CB.ablated_names(:translate)) == Set([:translate_whole_build!, :_apply_uniform_translation!,
        :_find_min_translation, :_find_clear_translation, :_minimum_clear_translation,
        :zone_relocatable, :core_zone_for_severity, :zone_diagnosis, :zone_diagnoses])
    @test Set(CB.ablated_names(:all)) == union(Set(CB.ablated_names(:translate)),
        Set([:find_clear_staging_center, :restage_assembly!, :restage_all_blocked!]))
    # 센서는 어느 목록에도 없다
    for s in (:zone_blockage, :active_restriction_zones, :zone_blocked_assemblies, :root_deposit_goals,
              :root_goal_coverage, :zone_clears_root_goals, :zone_team_coverage, :zone_facts)
        @test !(s in CB.ablated_names(:all))
    end
    @test_throws ErrorException CB.ablated_names(:bogus)
    # 목록의 이름은 전부 모듈에 실제로 있다(오타 방지)
    for s in CB.ablated_names(:all)
        @test isdefined(CB, s)
    end
end

@testset "가드: 무장·레벨·면제" begin
    try
        CB.set_repair_ablation!(:all); CB.disarm_repair_ablation!()
        @test CB._ablation_gate(:translate_whole_build!) === nothing          # 무장 전 = 무동작
        CB.arm_repair_ablation!()
        @test_throws CB.AblatedPrimitiveError CB._ablation_gate(:translate_whole_build!)
        @test CB._ablation_gate(:zone_blockage) === nothing                  # 목록 밖
        @test CB.ablation_counts()["denied:translate_whole_build!"] == 1
        r = CB.ablation_exempt(:monitor_record) do
            CB._ablation_gate(:zone_diagnosis); :ran
        end
        @test r === :ran
        @test CB.ablation_counts()["exempt:monitor_record"] == 1
        @test_throws CB.AblatedPrimitiveError CB._ablation_gate(:zone_diagnosis)  # 면제 밖으로 나오면 다시 막힌다
        @test CB.ablation_blocks_zone_ladder()
        CB.set_repair_ablation!(:translate)
        @test CB._ablation_gate(:restage_all_blocked!) === nothing           # A1 에는 restage 가 남는다
        CB.set_repair_ablation!(:none); CB.arm_repair_ablation!()
        @test CB._ablation_gate(:translate_whole_build!) === nothing
        @test !CB.ablation_blocks_zone_ladder()
        line = CB.ablation_summary_line()
        @test occursin("level=none armed=true denied=0 exempt=0 ladder_zone_skipped=0 ladder_zone_fired=0", line)
    finally
        CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
    end
end

@testset "오류 문구는 대안을 적지 않는다" begin
    msg = sprint(showerror, CB.AblatedPrimitiveError(:translate_whole_build!, :all))
    @test occursin("translate_whole_build!", msg)
    @test !occursin("restage", msg) && !occursin("instead", msg)
end
