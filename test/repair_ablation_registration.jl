# test/repair_ablation_registration.jl — 등록 게이트(명세 §6 층 2)
#   julia +lts --project=. test/repair_ablation_registration.jl
using ConstructionBots, Test
const CB = ConstructionBots

const BODIES = Dict(
    :direct    => "function t1!(env)\n    translate_whole_build!(env)\n    return (; status = :ok)\nend",
    :qualified => "function t2!(env)\n    ConstructionBots.translate_whole_build!(env)\n    return (; status = :ok)\nend",
    :getfield  => "function t3!(env)\n    g = getfield(ConstructionBots, :translate_whole_build!)\n    g(env)\n    return (; status = :ok)\nend",
    :string    => "function t4!(env)\n    g = getfield(ConstructionBots, Symbol(\"translate_whole_build!\"))\n    g(env)\n    return (; status = :ok)\nend",
    :alias     => "function t5!(env)\n    f = translate_whole_build!\n    f(env)\n    return (; status = :ok)\nend",
    :kwdefault => "function t6!(env; f = translate_whole_build!)\n    f(env)\n    return (; status = :ok)\nend",
    :restage   => "function t7!(env)\n    restage_all_blocked!(env)\n    return (; status = :ok)\nend",
    :diag      => "function t8!(env)\n    d = zone_diagnoses(env)\n    return (; status = :ok)\nend",
    :setter    => "function t9!(env)\n    for (k, z) in active_restriction_zones()\n        nothing\n    end\n    return (; status = :ok)\nend",
)

"레벨을 세우고 body 하나를 등록 규약에 태운다. name 은 코드의 함수 이름과 같아야 한다."
function check(level::Symbol, key::Symbol)
    CB.set_repair_ablation!(level)
    code = BODIES[key]
    name = String(match(r"function (\w+!)", code)[1])
    return CB.check_impl_conventions(name, code)
end

@testset "ablated_symbols_in 는 여섯 모양을 다 본다" begin
    d = CB.ablated_names(:all)
    for k in (:direct, :qualified, :getfield, :string, :alias, :kwdefault)
        @test CB.ablated_symbols_in(Meta.parse(BODIES[k]), d) == [:translate_whole_build!]
    end
    @test CB.ablated_symbols_in(Meta.parse(BODIES[:setter]), d) == Symbol[]
end

@testset "레벨별 거절" begin
    try
        for lvl in (:translate, :all), k in (:direct, :qualified, :getfield, :string, :alias, :kwdefault)
            @test check(lvl, k) == "reject:ablated_primitive:translate_whole_build! — this function is not available in this world"
        end
        @test startswith(something(check(:translate, :diag), ""), "reject:ablated_primitive:zone_diagnoses")
        @test check(:translate, :restage) === nothing          # A1 에는 restage 가 남는다
        @test startswith(something(check(:all, :restage), ""), "reject:ablated_primitive:restage_all_blocked!")
        @test check(:all, :setter) === nothing
        for k in keys(BODIES)                                  # none 에서는 ablation 사유가 절대 안 나온다
            r = check(:none, k)
            @test r === nothing || !startswith(r, "reject:ablated_primitive")
        end
    finally
        CB.set_repair_ablation!(:none)
    end
end

@testset "가까운 이름 제안에 차단 이름이 안 나온다" begin
    try
        CB.set_repair_ablation!(:all)
        near = CB._near_miss_names(:translate_whole_building!)
        @test !any(n -> Symbol(n) in CB.ablated_names(:all), near)
        CB.set_repair_ablation!(:none)
        @test "translate_whole_build!" in CB._near_miss_names(:translate_whole_building!)   # 대조: none 에서는 나온다
    finally
        CB.set_repair_ablation!(:none)
    end
end
