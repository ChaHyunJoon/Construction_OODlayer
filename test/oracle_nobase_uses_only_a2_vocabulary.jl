# 오라클 body 는 A2 에서 광고된 이름만 쓴다 — 그래야 오라클 완주가 "A2 어휘로 풀 수 있다" 의 증거가 된다
#   julia +lts --project=. test/oracle_nobase_uses_only_a2_vocabulary.jl
using ConstructionBots, Test
import JSON3
const CB = ConstructionBots
fx = JSON3.read(read(joinpath(pkgdir(CB), "tools", "fixtures", "oracle_zone_clear_nobase.json"), String))
code = String(fx.impl_code); name = String(fx.impl_name)
art = JSON3.read(read(joinpath(pkgdir(CB), "src", "decision", "core", "world_interface.ablate_all.json"), String))
advertised = Set(String(m.name) for m in art.methods)

@testset "A2 등록 게이트를 통과한다" begin
    try
        CB.set_repair_ablation!(:all)
        @test CB.check_impl_conventions(name, code) === nothing
    finally
        CB.set_repair_ablation!(:none)
    end
end

@testset "CB 의 이름을 부른다면 그것은 A2 에 광고된 이름이다" begin
    f = Meta.parse(code)
    cs, fs, ls = Symbol[], Tuple{Any,Symbol}[], Symbol[]
    CB._walk_body!(cs, fs, ls, f.args[2])
    for c in unique(cs)
        c in ls && continue
        isdefined(Base, c) && continue
        Base.binding_module(CB, c) === CB || continue      # CB 밖(CoordinateTransformations 등)의 이름은 제외
        @test String(c) in advertised
    end
end
