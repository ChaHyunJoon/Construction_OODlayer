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

@testset "차단 함수 11개는 본문 첫 문장이 자기 이름의 가드다(소스 고정)" begin
    gated = Dict(
        "restage_zone.jl" => [:translate_whole_build!, :_apply_uniform_translation!, :_find_min_translation,
            :_find_clear_translation, :_minimum_clear_translation, :zone_relocatable, :core_zone_for_severity,
            :find_clear_staging_center, :restage_assembly!, :restage_all_blocked!],
        "zone_diagnosis.jl" => [:zone_diagnosis])
    for (file, fns) in gated
        top = Meta.parseall(read(joinpath(pkgdir(CB), "src", "respec", file), String))
        found = Dict{Symbol,Bool}()
        # 최상위 표현식을 훑되, `@doc "..." function f(...) ... end` 형태의 Core.@doc 매크로콜과
        # begin/toplevel 블록도 펼쳐서 그 안의 :function 정의까지 본다.
        function visit!(a)
            a isa Expr || return
            if a.head === :macrocall && length(a.args) >= 1 &&
               (a.args[1] === Symbol("@doc") || (a.args[1] isa GlobalRef && a.args[1].name === Symbol("@doc")))
                for arg in a.args
                    arg isa Expr && visit!(arg)
                end
                return
            end
            if a.head in (:block, :toplevel)
                for arg in a.args
                    visit!(arg)
                end
                return
            end
            a.head === :function || return
            sig = a.args[1]
            sig isa Expr && sig.head === :where && (sig = sig.args[1])
            sig isa Expr && sig.head === :(::) && (sig = sig.args[1])   # 반환 타입 표기 `f(...)::T`
            sig isa Expr && sig.head === :call || return
            nm = sig.args[1]
            nm in fns || return
            first_stmt = first(x for x in a.args[2].args if !(x isa LineNumberNode))
            found[nm] = first_stmt == :(_ablation_gate($(QuoteNode(nm))))
        end
        for a in top.args
            visit!(a)
        end
        for fn in fns
            @test get(found, fn, false)
        end
    end
end

import JSON3
@testset "팔별 산출물: 차단 이름 0회, 센서·setter 는 남는다" begin
    base = JSON3.read(read(joinpath(pkgdir(CB), "src", "decision", "core", "world_interface.json"), String), Dict{String,Any})
    for lvl in (:translate, :all)
        b = CB.ablate_interface_blob(base, lvl)
        s = JSON3.write(b)
        for n in CB.ablated_names(lvl)
            @test !occursin(String(n), s)
        end
        names = Set(m["name"] for m in b["methods"])
        for keep in ("zone_facts", "zone_blockage", "active_restriction_zones", "set_desired_global_transform!",
                     "global_transform", "reset_cache_resume!")
            @test keep in names
        end
        @test length(b["methods"]) < length(base["methods"])
    end
    b1 = CB.ablate_interface_blob(base, :translate)
    @test "restage_all_blocked!" in Set(m["name"] for m in b1["methods"])      # A1 에는 남는다
    rs = only(m for m in b1["methods"] if m["name"] == "restage_all_blocked!")
    @test !any(occursin("translate_whole_build!", x) for x in get(rs, "status_meanings", String[]))
    @test CB.ablate_interface_blob(base, :none) === base
    # (커밋된 팔별 산출물이 현행 코드와 같은지는 test/world_interface_current.jl 의 재생성 바이트 비교가
    #  지킨다 — Step 5. 여기서 Dict 동등으로 또 재면 진실원이 둘이 된다.)
end

@testset "무장된 :all 에서 차단 함수는 인자를 보기 전에 던진다" begin
    saved = copy(CB.RESTRICTION_ZONES[])
    try
        CB.set_repair_ablation!(:all); CB.arm_repair_ablation!()
        @test_throws CB.AblatedPrimitiveError CB.translate_whole_build!(nothing)
        @test_throws CB.AblatedPrimitiveError CB.restage_all_blocked!(nothing)
        @test_throws CB.AblatedPrimitiveError CB.zone_diagnosis(nothing, :z)
        @test_throws CB.AblatedPrimitiveError CB._find_min_translation(nothing)
        # zone_diagnoses 는 존마다 zone_diagnosis 를 부른다 — 존이 하나도 없으면 빈 목록이라 안 던진다.
        # 그래서 존 하나를 심고 잰다(도메인이 퇴화하면 항진명제다).
        CB.add_restriction_zone!(:abl_t, [1.0e4, 1.0e4], 1.0)
        @test_throws CB.AblatedPrimitiveError CB.zone_diagnoses(nothing)
        CB.disarm_repair_ablation!()
        # 무장 해제면 가드가 무동작 → 원래 함수가 nothing 을 받아 **다른** 예외를 낸다
        err = try CB.translate_whole_build!(nothing); nothing catch e; e end
        @test !(err isa CB.AblatedPrimitiveError)
    finally
        CB.set_repair_ablation!(:none); CB.disarm_repair_ablation!()
        CB.clear_restriction_zones!()
        for (k, z) in saved
            CB.add_restriction_zone!(k, Vector{Float64}(CB.get_center(z)[1:2]), Float64(CB.get_radius(z)))
        end
    end
end
