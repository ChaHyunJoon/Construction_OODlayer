# =============================================================================
# 합성 body 의 이름 해석. (2026-08-30, T2)
#
# 재는 명제 셋
#   (1) 레지스트리의 모든 원시 이름이 CB 의 실제 callable 로 해석된다.
#   (2) 레지스트리에 없는 이름은 **조용히 무시되지 않고** nothing 을 낸다.
#   (3) `harness_args` 가 그대로 실려 나온다 — T3 의 인자 바인더가 이것을 읽는다.
#
# 🔴 이 게이트가 재지 **않는** 것: 그 함수가 무엇을 하는지, 인자가 맞는지.
#    그건 T3 의 게이트다.
#
# 🔴 navigator 계층을 미리 로드한다. 왜: 합성 body 의 집행은 render 레인에서 일어나고,
#    그 레인은 navigator 를 로드한다. 이 계획의 뒤 태스크가 어휘에 navigator-layer 원시를
#    하나 더한다 — 그 `impl` 은 bare `using ConstructionBots` 아래서는 정의돼 있지 않다.
#    이 guard 없이 이 파일이 단독으로 돌면, 진짜 결함과 무관한 이유로 빨개진다
#    (`test/battery_menu_lanes_agree.jl` · `test/mild_menu_is_noop_only.jl` 과 같은 관용구).
#
# 🔴 `test/runtests.jl` 은 모든 시험 파일을 **같은 `Main` 스코프**에 include 한다 — 그래서
#    이 파일도 자기 `module` 로 감싼다(안 그러면 다른 파일의 top-level `const` 와 충돌한다,
#    이 계획의 앞 태스크가 실제로 밟은 버그).
#
# 🔴 `test/primitive_registry_resolves.jl` 은 이미 있고 `isdefined` 만 잰다(그 impl 이름이
#    CB 심볼표에 존재하는지). 이 파일의 `resolve_primitive` 는 그보다 **더 엄격**하다 —
#    `isa Function` 까지 요구한다. "해석된다"의 뜻이 두 게이트에서 일부러 다르다.
#
# 변이시험 (넷 다 실제로 빨개지는 것을 봤다 — task-2-report.md 에 REAL 트랜스크립트):
#   · 오염된 레지스트리 사본(`impl` 을 오타)을 PRIMITIVE_REGISTRY 로 물리면 (1) 이 빨개진다.
#   · `resolve_primitive` 가 미지 이름에 임의 함수를 돌려주게 바꾸면 (2) 가 빨개진다.
#   · `resolve_primitive` 의 `reversible` 을 하드코드 `false` 로 바꾸면 (3) 이 빨개진다
#     (`r.reversible === true` 실패).
#   · `PRIMITIVE_TABLE()` 이 파일 없을 때 `error(...)` 대신 빈 `Dict{String,Any}()` 를
#     돌려주게 바꾸면 (4) 가 빨개진다(`@test_throws Exception` 이 "No exception thrown").
# =============================================================================
module MintedToolResolves

using Test
using ConstructionBots
const CB = ConstructionBots

isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

@testset "(1) 모든 원시 이름이 해석된다" begin
    tbl = CB.PRIMITIVE_TABLE()
    @test !isempty(tbl)
    for (name, _) in tbl
        r = CB.resolve_primitive(name)
        @test r !== nothing
        @test r.impl isa Function
        @test r.name == name
    end
end

@testset "(2) 미지 이름은 nothing 이다 — 조용히 통과시키지 않는다" begin
    @test CB.resolve_primitive("teleport_the_build") === nothing
    @test CB.resolve_primitive("") === nothing
    # 🔴 CB 에 실재하지만 **레지스트리에 없는** 이름도 거절한다. 알파벳은 레지스트리이지
    #    CB 의 전체 심볼 표가 아니다 — 그렇지 않으면 합성기가 아무 내부 함수나 부를 수 있다.
    @test isdefined(CB, :run_lego_demo)
    @test CB.resolve_primitive("run_lego_demo") === nothing
end

@testset "(3) harness_args 가 실려 나온다" begin
    r = CB.resolve_primitive("restage_all_blocked")
    @test r !== nothing
    @test "env" in r.harness_args
    @test r.surface == "scene_tree"
    @test r.reversible === true
end

@testset "(4) 오염된 레지스트리는 큰 소리로 죽는다" begin
    # 조용한 폴백 금지. 파일이 없으면 예외다 — 빈 표를 돌려주면 모든 body 가
    # "미지 원시" 로 보이고 원인이 레지스트리 부재라는 사실이 사라진다.
    withenv("PRIMITIVE_REGISTRY" => "/nonexistent/primitive_registry.json") do
        CB._reset_primitive_table!()
        @test_throws Exception CB.PRIMITIVE_TABLE()
    end
    CB._reset_primitive_table!()      # 다음 testset 을 위해 되돌린다
    @test !isempty(CB.PRIMITIVE_TABLE())
end

end # module
