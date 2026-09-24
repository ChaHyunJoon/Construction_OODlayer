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

# ---- 최종 리뷰 I1 · m1 (2026-09-23): 가드 기계장치를 부르는 body 와 이름 충돌 ------------------------
const PROBES = Dict(
    :reset_level => "function p1!(env)\n    ConstructionBots.REPAIR_ABLATION[] = :none\n    return (; status = :ok)\nend",
    :disarm      => "function p2!(env)\n    disarm_repair_ablation!()\n    return (; status = :ok)\nend",
    :unarm_ref   => "function p3!(env)\n    _ABLATION_ARMED[] = false\n    return (; status = :ok)\nend",
    :exempt      => "function p4!(env)\n    ablation_exempt(:x) do\n        getfield(ConstructionBots, Symbol(join([\"translate\", \"whole\", \"build!\"], \"_\")))(env)\n    end\n    return (; status = :ok)\nend",
)
const PROBE_HIT = Dict(:reset_level => :REPAIR_ABLATION, :disarm => Symbol("disarm_repair_ablation!"),
                       :unarm_ref => :_ABLATION_ARMED, :exempt => :ablation_exempt)

function check_probe(level::Symbol, key::Symbol)
    CB.set_repair_ablation!(level)
    code = PROBES[key]
    return CB.check_impl_conventions(String(match(r"function (\w+!)", code)[1]), code)
end

@testset "기계장치 목록은 repair_ablation.jl 최상위 정의 집합과 같다(고정 목록)" begin
    defs = Set{Symbol}()
    function defname(ex)
        ex isa Expr || return nothing
        if ex.head === :macrocall        # docstring 이 감싼 정의
            return defname(ex.args[end])
        elseif ex.head === :const
            return defname(ex.args[1])
        elseif ex.head === :(=) || ex.head === :function
            lhs = ex.args[1]
            lhs isa Symbol && return lhs
            lhs isa Expr && lhs.head === :call && return lhs.args[1] isa Symbol ? lhs.args[1] : nothing
            lhs isa Expr && lhs.head === :where && return defname(Expr(:function, lhs.args[1]))
            return nothing
        elseif ex.head === :struct
            return ex.args[2] isa Symbol ? ex.args[2] : ex.args[2].args[1]
        end
        return nothing
    end
    top = Meta.parseall(read(joinpath(pkgdir(ConstructionBots), "src", "respec", "repair_ablation.jl"), String))
    for ex in top.args
        n = defname(ex)
        # `Base.showerror(...) = …` 는 남의 이름에 메서드를 더할 뿐 새 이름이 아니다
        n isa Symbol && push!(defs, n)
    end
    @test defs == Set(CB._ABLATION_MACHINERY)
    @test length(CB._ABLATION_MACHINERY) == length(unique(CB._ABLATION_MACHINERY))
    @test isempty(CB.ablation_reserved_names(:none))
    @test Set(CB.ablation_reserved_names(:all)) == Set(vcat(CB.ablated_names(:all), CB._ABLATION_MACHINERY))
    # export 금지는 그대로다(광고에 실리면 모델이 본다)
    @test !any(n -> n in names(ConstructionBots), CB._ABLATION_MACHINERY)
end

@testset "기계장치를 부르는 body 는 ablation 팔에서 중립 사유로 거절된다(I1)" begin
    try
        for lvl in (:translate, :all), k in keys(PROBES)
            @test check_probe(lvl, k) ==
                  "reject:ablated_primitive:$(PROBE_HIT[k]) — this function is not available in this world"
        end
        for k in keys(PROBES)                                  # none: ablation 사유는 절대 안 나온다
            r = check_probe(:none, k)
            @test r === nothing || !startswith(r, "reject:ablated_primitive")
        end
    finally
        CB.set_repair_ablation!(:none)
    end
end

@testset "차단·기계장치 이름을 impl_name 으로 고르면 중립 사유(m1)" begin
    body(n) = "function $(n)(env)\n    return (; status = :ok)\nend"
    try
        for (lvl, n) in ((:translate, "translate_whole_build!"), (:all, "restage_all_blocked!"),
                         (:all, "disarm_repair_ablation!"), (:translate, "set_repair_ablation!"))
            CB.set_repair_ablation!(lvl)
            @test CB.check_impl_conventions(n, body(n)) ==
                  "reject:ablated_primitive:$(n) — this function is not available in this world"
        end
        # A1 에는 restage 가 남는다 — 차단 이름이 아니므로 기존 충돌 사유 그대로
        CB.set_repair_ablation!(:translate)
        @test startswith(something(CB.check_impl_conventions("restage_all_blocked!", body("restage_all_blocked!")), ""),
                         "reject:impl_name_exists_shown:restage_all_blocked!")
        # none 에서는 바이트 동일: 기존 충돌 사유
        CB.set_repair_ablation!(:none)
        @test CB.check_impl_conventions("translate_whole_build!", body("translate_whole_build!")) ==
              "reject:impl_name_exists_shown:translate_whole_build! — 세계 인터페이스에 실려 있는 " *
              "이름이다. 기존 이름을 덮을 수 없다 — 다른 이름을 고르라"
        @test startswith(something(CB.check_impl_conventions("disarm_repair_ablation!", body("disarm_repair_ablation!")), ""),
                         "reject:impl_name_exists_withheld:disarm_repair_ablation!")
    finally
        CB.set_repair_ablation!(:none)
    end
end
