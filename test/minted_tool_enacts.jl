# =============================================================================
# 합성 body 의 집행. (2026-08-30, T3 / spec §5, §9-2)
#
# 재는 명제 열하나
#   (1) `reach != "composed"` 는 **집행하지 않는다** — `:deferred` 이지 `:admit` 이 아니다.
#   (2) body 에 미지 원시가 하나라도 있으면 **아무것도 집행하지 않고** `:reject` 다.
#       부분 집행은 undo 가 없는 이 설계에서 최악이다.
#   (3) 빈 body 는 `:admit` 이 아니다.
#   (4) `undo` 는 언제나 `:none` 이다. C 단계가 없다는 사실을 결과가 들고 다닌다.
#   (5) `env` 를 요구하는 원시에 `env` 가 없으면 거절이다.
#   (6) `env` 가 있으면 위치인자로 들어간다.
#   (7) 여러 원시가 하나의 params dict 을 나눠 갖는다 — 원시 단위 off-schema 거절 금지.
#   (8) 그러나 **아무 원시도 모르는** 인자는 body 전체를 본 뒤 거절된다(조용히 안 버린다).
#   (9) 🔴 알파벳 19 중 **실제로 부를 수 있는 것은 6** 이고, 나머지는 **부르기 전에**
#       어느 연언지가 깨졌는지와 함께 거절된다.
#  (10) 🔴 `zone_keys` 는 유도하지 않는다. 안 주면 키워드를 빼고, 주면 `Symbol` 로 강제해
#       살아 있는 존인지 **호출 전에** 검사한다.
#  (11) 🔴 "불렀는데 아무 일도 없었다"와 "부르지 않았다"는 다른 사건이다 — `applied` ·
#       `partial` 이 verdict 와 별개로 그것을 나른다.
#
# 변이시험 — 열하나 전부 실제로 빨갛게 만든 뒤 되돌렸다. 재현 방법(`src/respec/minted_tool.jl`):
#   · (1): `enact_minted!` 의 `reach == "composed" || return _r(:deferred, ...)` 줄을 지운다.
#   · (2): `enact_minted!` 의 해석 루프에서 `p === nothing && return _r(:reject, ...)` 를
#          `p === nothing && continue` 로 바꾼다.
#   · (3): `isempty(names) && return _r(:reject, "empty body: ...")` 의 `:reject` 를 `:admit` 로.
#   · (4): `_r` 안의 `undo = :none` 을 `undo = :maybe` 로.
#   · (5): `bind_primitive_args` 의 `ctx.env === nothing && return "reject:missing_harness_arg:env"`
#          줄을 지운다.
#   · (6): 같은 함수의 `push!(pos, ctx.env)` 를 `push!(pos, nothing)` 으로.
#   · (7): 같은 함수의 kw 선별 루프를 원시 단위 off-schema 거절로 되돌린다
#          (`haskey(prim.params, String(k)) || return "reject:off_schema:$(k)"`).
#   · (8): `enact_minted!` 의 `let known = ...` 블록 전체를 지운다.
#   · (9): `_enactability` 의 본문을 `return (true, :ok)` 하나로 바꾼다.
#   ·(10): `bind_primitive_args` 의 `haskey(live, k) || return "reject:unknown_zone_key:..."`
#          줄을 지운다.
#   ·(11): 집행 루프의 `applied |= _step_applied(...)` 를 `applied = true` 로.
#
# 🔴 이 게이트는 서비스도 MILP 도 안 쓴다. (11) 이 부르는 유일한 실제 원시는
#    `translate_whole_build!` 이고, 그 함수는 `isempty(env.staging_circles)` 첫 줄에서
#    `:no_staging` 으로 돌아선다 — 세계도 솔버도 필요 없다.
#
# 🔴 `test/runtests.jl` 은 모든 시험 파일을 **같은 `Main` 스코프**에 include 한다 — 그래서
#    이 파일도 자기 `module` 로 감싼다(이 계획의 앞 태스크가 실제로 밟은 버그).
#
# 🔴 navigator 계층 guard 는 `test/minted_tool_resolves.jl`(T2) 과 같은 관용구다.
# =============================================================================
module MintedToolEnacts

using Test
using ConstructionBots
const CB = ConstructionBots

isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))

# 세계를 안 건드리는 최소 컨텍스트. env 를 요구하는 원시는 (11) 말고는 안 부른다.
_synth(; reach = "composed", names = String[], params = Dict{String,Any}()) =
    Dict{String,Any}("reach" => reach, "body_names" => names,
                     "tool_name" => "t", "params" => params, "missing_primitive" => nothing)

@testset "(1) reach=needs_primitive 는 deferred 다" begin
    r = CB.enact_minted!(nothing, nothing,
                         _synth(reach = "needs_primitive", names = ["restage_all_blocked"]))
    @test r.verdict === :deferred
    @test r.applied === false
    @test occursin("needs_primitive", r.reason)
end

@testset "(2) 미지 원시 하나면 아무것도 안 한다" begin
    r = CB.enact_minted!(nothing, nothing,
                         _synth(names = ["restage_all_blocked", "teleport_the_build"]))
    @test r.verdict === :reject
    @test r.applied === false
    @test occursin("teleport_the_build", r.reason)
    # 🔴 첫 원시가 해석 가능해도 **집행 시도조차 없어야** 한다. undo 가 없으므로
    #    부분 집행은 되돌릴 수 없는 손상이다.
    @test isempty(r.steps)
end

@testset "(3) 빈 body 는 admit 이 아니다" begin
    r = CB.enact_minted!(nothing, nothing, _synth(names = String[]))
    @test r.verdict === :reject
    @test r.applied === false
    @test occursin("empty", r.reason)
end

@testset "(4) undo 는 언제나 none 이다" begin
    for s in (_synth(reach = "needs_primitive"), _synth(names = ["nope"]), _synth())
        @test CB.enact_minted!(nothing, nothing, s).undo === :none
    end
end

@testset "(5) 인자 바인딩 — env 를 요구하는 원시에 env 가 없으면 거절이다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    got = CB.bind_primitive_args(p, (env = nothing, truth = nothing, params = Dict{String,Any}()))
    @test got isa String                    # 거절 사유
    @test occursin("env", got)
end

@testset "(6) 인자 바인딩 — env 가 있으면 위치인자로 들어간다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    sentinel = Ref(:env_sentinel)
    got = CB.bind_primitive_args(p, (env = sentinel, truth = nothing, params = Dict{String,Any}()))
    @test got isa Tuple
    @test first(got)[1] === sentinel        # positional[1] == env
end

@testset "(7) 여러 원시가 params 를 나눠 갖는다 — 두 번째 원시에서 죽지 않는다" begin
    # 🔴 합성기는 tool 하나에 params dict 하나를 낸다. body 가 둘 이상이면 그 키들은
    #    원시들에 흩어진다. 원시 단위로 off-schema 를 거절하면 정상 body 가 죽는다.
    p = CB.resolve_primitive("restage_all_blocked")     # zone_keys 만 안다
    got = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                                     params = Dict{String,Any}("agent" => "R3")))
    @test got isa Tuple                    # 거절이 아니다 — 모르는 키는 그냥 안 넘긴다
    @test !haskey(NamedTuple(got[2]), :agent)
end

@testset "(8) 아무 원시도 모르는 인자는 body 전체를 본 뒤 거절된다" begin
    r = CB.enact_minted!(nothing, nothing,
                         _synth(names = ["restage_all_blocked"],
                                params = Dict{String,Any}("nonsense_knob" => 1)))
    @test r.verdict === :reject
    @test occursin("nonsense_knob", r.reason)
    @test r.applied === false
end

# =============================================================================
# (9) 🔴 집행 가능성은 `harness_args ⊆ {"env"}` 가 **아니다**.
#
# 그 술어 하나만 보면 19 중 15 가 집행 가능으로 표시되는데(빈 `harness_args` 가 공짜로
# 통과한다), 실제로 부를 수 있는 것은 6 뿐이다. 나머지 9 는 호출 시점 `MethodError` 로
# 죽고 집행부의 `try` 가 그것을 `:admit`/`applied` 로 보고한다 = 거절보다 나쁜 거짓 admit.
# 이 절이 그 6 을 **이름으로** 못 박는다 — 레지스트리 편집이 조용히 어휘를 좁히면 빨개진다.
# =============================================================================
const ENACTABLE_TODAY = sort(["force_advance_stuck_carrier", "recover_stalled_teams",
                              "reform_stuck_teams", "resolve_schedule_wedge",
                              "restage_all_blocked", "translate_whole_build"])

@testset "(9) 알파벳 19 중 집행 가능은 6 이고, 나머지는 부르기 전에 거절된다" begin
    tbl = CB.PRIMITIVE_TABLE()
    @test length(tbl) == 19
    got = sort([n for n in keys(tbl) if CB.resolve_primitive(n).enactable])
    @test got == ENACTABLE_TODAY               # 🔴 6/19. 넓어져도 좁아져도 빨개진다.

    # 집행 불가는 **부르기 전에**, 어느 연언지가 깨졌는지와 함께 거절된다.
    #  · commit_respec  — harness 에 `milp`/`proposal` 이 있다(solve 없이는 공급 불가) → :harness
    #  · swap_battery   — harness 는 env 하나인데 위치인자가 둘이다          → :arity
    for (nm, why) in (("commit_respec", :harness), ("swap_battery", :arity))
        p = CB.resolve_primitive(nm)
        @test p.enactable === false
        @test p.unenactable_why === why
        r = CB.enact_minted!(Ref(:e), nothing, _synth(names = [nm]))
        @test r.verdict === :reject
        @test occursin("reject:unenactable:$(nm):$(why)", r.reason)
        @test isempty(r.steps)               # 한 발도 안 나갔다
    end

    # 나머지 두 연언지(`:kwargs`·`:multimethod`)는 오늘 레지스트리에 자연 표본이 없다 —
    # 오염 사본을 물려서 잰다(T2 게이트 (4) 와 같은 관용구).
    mktempdir() do dir
        path = joinpath(dir, "primitive_registry.json")
        write(path, """
        {"primitives": [
          {"name":"kw_bad","impl":"recover_stalled_teams!","surface":"physical",
           "harness_args":["env"],"params":{"no_such_kwarg":{"type":"int"}},"reversible":false},
          {"name":"mm_bad","impl":"compile_constraint!","surface":"milp",
           "harness_args":[],"params":{},"reversible":false}
        ]}""")
        withenv("PRIMITIVE_REGISTRY" => path) do
            CB._reset_primitive_table!()
            @test CB.resolve_primitive("kw_bad").unenactable_why === :kwargs
            # 🔴 메서드가 여럿이어도 **던지지 않는다** (`compile_constraint!` 는 6개).
            @test CB.resolve_primitive("mm_bad").unenactable_why === :multimethod
            @test occursin("reject:unenactable:kw_bad:kwargs",
                           CB.enact_minted!(Ref(:e), nothing, _synth(names = ["kw_bad"])).reason)
        end
        CB._reset_primitive_table!()
    end
    @test length(CB.PRIMITIVE_TABLE()) == 19   # 원래 레지스트리로 돌아왔다
end

# =============================================================================
# (10) 🔴 `zone_keys` 를 truth 에서 유도하면 안 되는 이유는 실측 셋이다:
#   (a) 서비스가 존 키를 프롬프트에 렌더한다(`dspy_service.py::_zones_block`) — 모델이 준다.
#   (b) `RESTRICTION_ZONES[]` 는 `Dict{Symbol,Ball2}` 이고 소비자는 `haskey` 로 거른다.
#       String 키는 조용히 걸러져 `zones == []` → `translate_whole_build!` 가 Δ=0 ·
#       잔여 0 으로 `:already_clear` 를 낸다 = 맞는 답이 거짓 증거로 둔갑한다.
#   (c) 유도값은 callee 기본값(`collect(keys(RESTRICTION_ZONES[]))`)보다 **좁다**.
# =============================================================================
@testset "(10) zone_keys 는 유도하지 않고, 주면 Symbol 로 강제해 검사한다" begin
    p = CB.resolve_primitive("restage_all_blocked")
    saved = CB.RESTRICTION_ZONES[]
    try
        CB.RESTRICTION_ZONES[] = Dict{Symbol,CB.LazySets.Ball2}(
            :zone_blk_1 => CB.LazySets.Ball2([0.0, 0.0, 0.0], 1.0),
            :zone_blk_2 => CB.LazySets.Ball2([5.0, 0.0, 0.0], 1.0))

        # (c) 안 주면 **키워드를 아예 뺀다** — callee 기본값(살아 있는 존 전부)이 이긴다.
        kw = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                                        params = Dict{String,Any}()))[2]
        @test !haskey(kw, :zone_keys)

        # (b) String 을 주면 Symbol 로 강제된다 — 조용히 걸러지지 않는다.
        kw2 = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => ["zone_blk_1"])))[2]
        @test kw2.zone_keys == Symbol[:zone_blk_1]

        # 살아 있지 않은 존은 **호출 전에** 거절된다(살아 있는 키까지 사유에 싣는다).
        bad = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => ["zone_blk_9"])))
        @test bad isa String
        @test occursin("reject:unknown_zone_key:zone_blk_9", bad)
        @test occursin("zone_blk_1,zone_blk_2", bad)

        # 🔴 빈 목록은 기본값으로 폴백하지 않는다 — 폴백하면 "존 전부"가 되어 뜻이 뒤집힌다.
        empt = CB.bind_primitive_args(p, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("zone_keys" => String[])))
        @test empt == "reject:empty_zone_keys"

        # 그리고 거절은 집행부까지 그대로 올라간다 — 한 발도 안 나간다.
        r = CB.enact_minted!(Ref(:e), nothing,
                _synth(names = ["restage_all_blocked"],
                       params = Dict{String,Any}("zone_keys" => ["zone_blk_9"])))
        @test r.verdict === :reject
        @test r.applied === false
        @test isempty(r.steps)
    finally
        CB.RESTRICTION_ZONES[] = saved
    end
end

# =============================================================================
# (11) 🔴 "불렀는데 아무 일도 없었다" ≠ "부르지 않았다"(spec §9-2).
#
# `translate_whole_build!` 는 적치원이 없으면 `:no_staging` 을 돌려주는데, 그 함수의
# 상태들은 호출자에게 "성공"으로 취급되게 설계돼 있다. 그대로 `applied = true` 로 실으면
# **아무것도 안 한 집행**이 결정 행에 적응의 증거로 남는다.
# =============================================================================
@testset "(11) applied 는 status 로, partial 은 예외로 판정한다" begin
    # 순수 판정 함수부터 — 표는 `SILENT_SUCCESS_STATUSES` 하나다.
    @test CB._step_applied("translate_whole_build", :no_staging)    === false
    @test CB._step_applied("translate_whole_build", :already_clear) === false
    @test CB._step_applied("translate_whole_build", :translated)    === true
    @test CB._step_applied("restage_all_blocked",   :none)          === false
    @test CB._step_applied("restage_all_blocked",   :restaged_all)  === true
    # 표에 없는 원시는 보수적으로 참이다 — 모르는 것을 "안 했다"로 세면 조용히 샌다.
    @test CB._step_applied("resolve_schedule_wedge", :whatever)     === true

    # 끝에서 끝까지: 불렸고(:admit), 그러나 세계는 안 바뀌었다(applied=false).
    fake = (staging_circles = Dict{Symbol,Any}(),)      # 첫 줄에서 :no_staging 으로 돌아선다
    r = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r.verdict === :admit
    @test r.applied === false                          # 🔴 조용한 성공을 성공으로 세지 않는다
    @test r.partial === false
    @test length(r.steps) == 1
    @test r.steps[1].status === :no_staging
    @test occursin("적응", r.reason)                    # 사유가 그 사실을 말한다
    @test r.undo === :none

    # 던지면 `partial` 이 참이다 — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다.
    r2 = CB.enact_minted!((nope = 1,), nothing, _synth(names = ["translate_whole_build"]))
    @test r2.verdict === :admit
    @test r2.partial === true
    @test r2.steps[1].status === :threw
    @test occursin("undo 없음", r2.reason)
end

end # module
