# =============================================================================
# 합성 body 의 집행. (2026-08-30, T3 / spec §5, §9-2)
#
# 재는 명제 열둘
#   (1) `reach != "composed"` 는 **집행하지 않는다** — `:deferred` 이지 `:admit` 이 아니다.
#   (2) body 에 미지 원시가 하나라도 있으면 **아무것도 집행하지 않고** `:reject` 다.
#       부분 집행은 undo 가 없는 이 설계에서 최악이다.
#   (3) 빈 body 는 `:admit` 이 아니다.
#   (4) `undo` 는 언제나 `:none` 이다. C 단계가 없다는 사실을 결과가 들고 다닌다.
#   (5) `env` 를 요구하는 원시에 `env` 가 없으면 거절이다.
#   (6) `env` 가 있으면 위치인자로 들어간다.
#   (7) 여러 원시가 하나의 params dict 을 나눠 갖는다 — 원시 단위 off-schema 거절 금지.
#   (8) 그러나 **아무 원시도 모르는** 인자는 body 전체를 본 뒤 거절된다(조용히 안 버린다).
#   (9) 🔴 알파벳 20 중 **실제로 부를 수 있는 것은 7** 이고, 나머지는 **부르기 전에**
#       어느 연언지가 깨졌는지와 함께 거절된다.
#  (10) 🔴 `zone_keys` 는 유도하지 않는다. 안 주면 키워드를 빼고, 주면 `Symbol` 로 강제해
#       살아 있는 존인지 **호출 전에** 검사한다.
#  (11) 🔴 "불렀는데 아무 일도 없었다" · "부르지 않았다" · "못 쟀다"는 서로 다른 사건이다 —
#       `applied`(노린 적응) · `partial`(던졌다) · `world_maybe_dirty`(둘 중 하나) 가 verdict 와
#       별개로 그것을 나른다. 표는 **집행 가능한 여섯 전부**를 덮어야 한다.
#  (12) 🔴 레지스트리의 이름→impl 짝과 params 키를 못 박는다 — (9) 는 이름 집합만 재므로,
#       params 에 키를 더하거나 impl 을 다른 함수로 돌리면 스위트가 전부 초록인 채
#       부를 수 있는 표면이 넓어진다.
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
#   ·(11b): `SILENT_SUCCESS_STATUSES` 에서 `"force_advance_stuck_carrier"` 행을 지운다
#           (= 리뷰 전의 결함 상태. 커버리지 단언과 :disabled 단언이 빨개진다).
#   ·(11c): `_step_status` 의 `COUNT_RETURN_PRIMITIVES` 갈래를 지운다(맨 Int 를 못 읽는다).
#   ·(11d): `_step_applied` 의 `status in UNMEASURABLE_STATUSES ? false :` 를 지운다
#           (= 못 잰 것이 다시 성공으로 샌다).
#   ·(11e): `_step_status` 의 `try`/`catch` 를 지운다(Hostile 반환이 예외로 새어 나간다).
#   ·(11f): `_r` 의 `world_maybe_dirty = applied || partial` 를 `= applied` 로
#           (던진 경우가 깨끗한 세계로 보고된다).
#   ·(12a): 레지스트리에서 `restage_all_blocked` 의 params 에 `"resume"` 를 더한다.
#   ·(12b): 레지스트리에서 `resolve_schedule_wedge` 의 impl 을 `recover_stalled_teams!` 로 돌린다.
#   ·(13a): `PRIMITIVE_RESUMES_CACHE["recover_stalled_teams"]` 를 `true` 로
#           (= 리뷰가 잡은 CRITICAL 의 상태 — 재개가 조용히 안 나간다).
#   ·(13b): `enact_minted!` 의 루프 뒤 재개 블록을 통째로 지운다.
#   ·(13c): `WORLD_UNCHANGED_STATUSES` 를 `SILENT_SUCCESS_STATUSES` 의 별칭으로 되돌린다
#           (= 옮겨진 빌드가 world_maybe_dirty=false 로 보고되는 IMPORTANT 결함).
#   ·(13d): `_step_touched_world` 의 `UNMEASURABLE_STATUSES ? true :` 를 `false` 로.
#   ·(13e): 던진 경로의 `_issue_resume!` 호출을 지운다.
#   ·(14a): `bind_primitive_args` 의 `_param_type_reject` 호출을 지운다(= 최종 리뷰 이전 상태 —
#           타입 틀린 param 이 호출 경계에서 던지고 그 예외가 `partial=true` 로 기록된다).
#   ·(14b): `PARAM_JSON_TYPES["boolean"]` 을 `Any` 로(= `"true"` 문자열이 통과한다).
#   ·(14c): `_param_type_reject` 의 `t === nothing && return "no_declared_type"` 을
#           `t === nothing && return nothing` 으로(= 선언 없는 param 이 조용히 통과한다).
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

# `getproperty` 가 던지는 반환값. (11) 이 "못 읽는 모양은 예외가 아니라 기록"을 잰다.
struct Hostile end
Base.hasproperty(::Hostile, ::Symbol) = true
Base.getproperty(::Hostile, ::Symbol) = error("이 반환값은 읽을 수 없다")

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
# 그 술어 하나만 보면 20 중 16 이 집행 가능으로 표시되는데(빈 `harness_args` 가 공짜로
# 통과한다), 실제로 부를 수 있는 것은 7 뿐이다. 나머지 9 는 호출 시점 `MethodError` 로
# 죽고 집행부의 `try` 가 그것을 `:admit`/`applied` 로 보고한다 = 거절보다 나쁜 거짓 admit.
# 이 절이 그 7 을 **이름으로** 못 박는다 — 레지스트리 편집이 조용히 어휘를 좁히면 빨개진다.
# =============================================================================
const ENACTABLE_TODAY = sort(["force_advance_stuck_carrier", "recover_stalled_teams",
                              "reform_stuck_teams", "reprice_agent_by_payload",
                              "resolve_schedule_wedge",
                              "restage_all_blocked", "translate_whole_build"])

@testset "(9) 알파벳 20 중 집행 가능은 7 이고, 나머지는 부르기 전에 거절된다" begin
    tbl = CB.PRIMITIVE_TABLE()
    @test length(tbl) == 20
    got = sort([n for n in keys(tbl) if CB.resolve_primitive(n).enactable])
    @test got == ENACTABLE_TODAY               # 🔴 20 중 7. 넓어져도 좁아져도 빨개진다.

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
    @test length(CB.PRIMITIVE_TABLE()) == 20   # 원래 레지스트리로 돌아왔다
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
# (11) 🔴 "불렀는데 아무 일도 없었다" ≠ "부르지 않았다" ≠ "못 쟀다"(spec §9-2).
#
# 2026-08-30 리뷰가 잡은 결함: 처음 `SILENT_SUCCESS_STATUSES` 를 zone 원시 둘만 채웠더니
# **집행 가능한 여섯 중 넷**이 아무 일도 안 하고 `applied = true` 를 냈다. 그중
# `force_advance_stuck_carrier!` 는 `CARRIER_RESCUE != "1"`(= 손 안 댄 **기본 환경**)이면
# 언제나 `:disabled, moved=0` 이다 — 매 런이 "적응했다"로 결정 행에 남았을 것이다.
# `reform_stuck_teams!` 는 아예 NamedTuple 이 아니라 맨 `Int` 를 돌려준다.
# 그래서 이 절은 이제 **여섯 전부**를 이름으로 잰다.
# =============================================================================
@testset "(11) applied 는 status 로, partial 은 예외로, 못 쟀으면 false 다" begin
    # 🔴 표는 집행 가능한 여섯을 **빠짐없이** 덮어야 한다. 어휘가 늘면(이 계획의 뒤 태스크가
    #    원시를 하나 더한다) 표를 채우기 전까지 여기서 먼저 빨개진다 — `_step_applied` 의
    #    보수적 기본값(참)으로 조용히 새는 길을 막는 것이 이 단언 하나다.
    @test sort(collect(keys(CB.SILENT_SUCCESS_STATUSES))) == ENACTABLE_TODAY

    # 여섯 원시의 실제 return 문에서 읽은 상태들. 왼쪽=조용한 성공(false), 오른쪽=진짜 적응(true).
    quiet = [("restage_all_blocked", :none), ("restage_all_blocked", :infeasible),
             ("restage_all_blocked", :residual_blocked),
             ("translate_whole_build", :no_staging), ("translate_whole_build", :already_clear),
             ("translate_whole_build", :infeasible), ("translate_whole_build", :residual_blocked),
             # 🔴 CARRIER_RESCUE 미설정이 기본값이다 — 이 한 줄이 리뷰가 잡은 결함이다.
             ("force_advance_stuck_carrier", :disabled), ("force_advance_stuck_carrier", :no_carrier),
             ("recover_stalled_teams", :no_team), ("recover_stalled_teams", :stuck),
             # recover 는 carrier 의 결과를 그대로 전달한다 — :disabled 가 여기로도 올라온다.
             ("recover_stalled_teams", :disabled), ("recover_stalled_teams", :no_carrier),
             ("resolve_schedule_wedge", :not_applicable), ("resolve_schedule_wedge", :no_wedge),
             ("reform_stuck_teams", :moved_none)]
    for (n, st) in quiet
        @test CB._step_applied(n, st) === false
    end
    real = [("restage_all_blocked", :restaged_all), ("restage_all_blocked", :partial),
            ("translate_whole_build", :translated),
            ("force_advance_stuck_carrier", :carrier_closed),
            ("force_advance_stuck_carrier", :carrier_advanced),
            ("recover_stalled_teams", :snapped), ("recover_stalled_teams", :restaged),
            ("recover_stalled_teams", :unwedged), ("recover_stalled_teams", :force_snapped),
            ("resolve_schedule_wedge", :unwedged), ("reform_stuck_teams", :moved)]
    for (n, st) in real
        @test CB._step_applied(n, st) === true
    end

    # 🔴 "못 쟀다"는 성공이 아니다. 모양을 못 읽었다는 것은 세계가 변했는지 **모른다**는 뜻이다.
    #    이것은 표에 없는 원시의 보수적 기본값(참)보다 **먼저** 판정된다.
    @test CB._step_applied("restage_all_blocked", :unreadable_return) === false
    @test CB._step_applied("primitive_not_in_table", :unreadable_return) === false
    # 표에 없는 원시의 그 밖 상태는 보수적으로 참이다. ⚠️ 위 커버리지 단언 때문에 집행
    # 가능한 여섯에 대해서는 이 기본값에 **도달할 수 없다**.
    @test CB._step_applied("primitive_not_in_table", :whatever) === true

    # 반환 모양 읽기 — 세 갈래.
    @test CB._step_status("translate_whole_build", (status = :translated,)) === :translated
    @test CB._step_status("reform_stuck_teams", 0) === :moved_none   # 맨 Int 를 개수로 읽는다
    @test CB._step_status("reform_stuck_teams", 3) === :moved
    @test CB._step_status("restage_all_blocked", 3) === :unreadable_return  # 개수 원시가 아니다
    @test CB._step_status("whatever", nothing) === :unreadable_return
    @test occursin("unreadable return shape", CB._step_detail(nothing))

    # 🔴 `getproperty` 가 던지는 반환값도 **기록**이지 예외가 아니다. 오늘의 여섯에는 그런
    #    반환이 없지만 이 계획의 뒤 태스크가 어휘에 원시를 하나 더한다.
    @test CB._step_status("whatever", Hostile()) === :unreadable_return
    @test occursin("unreadable return shape", CB._step_detail(Hostile()))

    # 끝에서 끝까지: 불렸고(:admit), 그러나 세계는 안 바뀌었다(applied=false).
    fake = (staging_circles = Dict{Symbol,Any}(),)      # 첫 줄에서 :no_staging 으로 돌아선다
    r = CB.enact_minted!(fake, nothing, _synth(names = ["translate_whole_build"]))
    @test r.verdict === :admit
    @test r.applied === false                          # 🔴 조용한 성공을 성공으로 세지 않는다
    @test r.partial === false
    @test r.world_maybe_dirty === false
    @test length(r.steps) == 1
    @test r.steps[1].status === :no_staging
    @test occursin("적응", r.reason)                    # 사유가 그 사실을 말한다
    @test r.undo === :none

    # 던지면 `partial` 이 참이다 — 세계는 절반만 고쳐졌을 수 있고 되돌릴 방법이 없다.
    r2 = CB.enact_minted!((nope = 1,), nothing, _synth(names = ["translate_whole_build"]))
    @test r2.verdict === :admit
    @test r2.partial === true
    @test r2.applied === false                         # applied 는 status 전용이다(뒤집지 않는다)
    # 🔴 그래서 파생 필드가 따로 있다 — 한 필드만 읽고 다른 것의 답을 얻어 가면 안 된다.
    @test r2.world_maybe_dirty === true
    @test r2.steps[1].status === :threw
    @test occursin("undo 없음", r2.reason)

    # 거절은 세계에 손을 안 댔다.
    @test CB.enact_minted!(nothing, nothing, _synth(names = ["nope"])).world_maybe_dirty === false
end

# =============================================================================
# (12) 🔴 레지스트리 편집 둘이 게이트를 전부 초록으로 둔 채 **부를 수 있는 표면을 넓힌다**.
#   (a) `restage_all_blocked` 의 params 에 `"resume"` 를 더한다 → 연언지 (iii) 은 그대로
#       성립하고(진짜 kwarg 다) 이름 집합도 그대로라 (9) 는 초록인데, 이제 LLM 이 준
#       `resume` 가 `reset_cache_resume!` 까지 흘러가고 (8) 의 미지 인자 거절도 그 키를
#       더는 안 막는다.
#   (b) `resolve_schedule_wedge` 의 impl 을 `recover_stalled_teams!` 로 돌린다 → arity 1 ·
#       env-only · 단일 메서드라 여전히 집행 가능, 이름 집합 그대로, 스위트 전부 초록인데
#       알파벳이 **다른 함수**를 집행한다.
# `test/primitive_registry_resolves.jl` 은 `params` 가 **존재**하는지만 보지 키를 안 본다.
# 그래서 이 절이 이름→impl 짝과 params 키 **둘 다**를 못 박는다.
# =============================================================================
const REGISTRY_SURFACE_TODAY = Dict{String,Tuple{String,Vector{String}}}(
    "apply_uniform_translation"   => ("_apply_uniform_translation!", ["delta"]),
    "commit_respec"               => ("commit_respec!", String[]),
    "compile_constraint"          => ("compile_constraint!", ["constraint_type"]),
    "deprioritize_agent"          => ("deprioritize_agent!", ["agent", "factor"]),
    "dispatch_battery_courier"    => ("dispatch_battery_courier!", ["target"]),
    "force_advance_stuck_carrier" => ("force_advance_stuck_carrier!", ["tol"]),
    "hot_swap_robot"              => ("hot_swap_robot!", ["faulted", "mode"]),
    "pop_spare"                   => ("pop_spare!", ["pool"]),
    "recover_stalled_teams"       => ("recover_stalled_teams!", String[]),
    "reform_stuck_teams"          => ("reform_stuck_teams!", ["min_ready", "snap_all"]),
    "release_pending_assignments" => ("release_pending_assignments!", ["faulted"]),
    "replace_robot"               => ("replace_robot!", ["faulted", "spare"]),
    "reprice_agent_by_payload"    => ("reprice_agent_by_payload!", ["agent", "light_bias"]),
    "reset_slot_to_invalid"       => ("reset_slot_to_invalid!", ["slot_v"]),
    "resolve_schedule_wedge"      => ("resolve_schedule_wedge!", String[]),
    "restage_all_blocked"         => ("restage_all_blocked!", ["zone_keys"]),
    "restage_assembly"            => ("restage_assembly!", ["assembly_id", "zone_keys"]),
    "rethread_robot_ids"          => ("rethread_robot_ids!", String[]),
    "swap_battery"                => ("swap_battery!", ["agent"]),
    "translate_whole_build"       => ("translate_whole_build!", ["zone_keys"]),
)

@testset "(12) 레지스트리의 이름→impl 짝과 params 키를 못 박는다" begin
    tbl = CB.PRIMITIVE_TABLE()
    @test sort(collect(keys(tbl))) == sort(collect(keys(REGISTRY_SURFACE_TODAY)))
    for (n, (impl, prms)) in REGISTRY_SURFACE_TODAY
        p = CB.resolve_primitive(n)
        @test p !== nothing
        # 이름→impl 짝. `nameof` 로 실제로 해석된 함수의 이름을 되읽는다 — 레지스트리 문자열이
        # 아니라 **CB 가 준 callable** 을 본다.
        @test String(nameof(p.impl)) == impl
        # params 키. 이 집합이 곧 LLM 이 이 원시에 넘길 수 있는 손잡이 전부다.
        @test sort(collect(keys(p.params))) == sort(prms)
    end
end

# =============================================================================
# (13) 🔴 2026-08-30 (T4 리뷰). 두 결함을 한꺼번에 막는다.
#
#  (a) CRITICAL — **집행 가능한 여섯 중 셋이 스케줄 캐시를 스스로 재개하지 않는다.**
#      `enact_minted!` 은 `impl(env)` 를 날것으로 부르므로, body `["recover_stalled_teams"]`
#      가 `:snapped` 를 내면 `applied=true → handled=true` 가 되어 기본 복구 사슬을 건너뛴다.
#      세계는 고쳐졌는데 프론티어가 낡은 채 남고, 그 OOD 사건은 **이미 소비돼 다시 오지
#      않는다** = 성공과 구별되지 않는 미복구(`ood_injection.jl`: "예외는 안 난다").
#
#  (b) IMPORTANT — **`world_maybe_dirty=false` 인데 빌드가 이미 옮겨져 있다.**
#      `translate_whole_build!` 의 `:residual_blocked` 는 `_apply_uniform_translation!` 이
#      돈 **뒤**에 나온다. 표가 하나뿐이면 `applied=false → world_maybe_dirty=false` 라
#      "세계가 깨끗하다"고 보고하는 옮겨진 빌드가 된다.
#
# 🔴 (a) 를 **실제로 볼 수 있는** 픽스처: 손으로 지은 env 로는 못 본다(재개는 `env.cache`·
#    `env.sched` 를 쓴다). 그래서 **진짜** `OperatingSchedule` + `PlanningCache` 를 만들고
#    `active_set` 에 낡은 정점을 심어 둔다 — 재개가 실제로 일어나면 그 자리가 비워진다.
#    아래 (13-e) 가 양성 대조, (13-f) 가 음성 대조다(같은 픽스처, 반대 결과).
# =============================================================================
@testset "(13) 스케줄 캐시 재개 · 세계 접촉 표" begin
    # ---- 표 셋의 커버리지 -------------------------------------------------------------
    @test sort(collect(keys(CB.WORLD_UNCHANGED_STATUSES))) == ENACTABLE_TODAY
    @test sort(collect(keys(CB.PRIMITIVE_RESUMES_CACHE)))  == ENACTABLE_TODAY

    # 🔴 불변식: 원시마다 `WORLD_UNCHANGED ⊆ SILENT_SUCCESS`. 세계를 안 건드렸으면 노린
    #    적응도 당연히 안 일어났다. 이 포함이 `applied ⟹ world_maybe_dirty` 를 보장한다 —
    #    즉 T4 의 `handled` 판정이 `applied` 판정보다 **넓기만** 하다(좁아지지 않는다).
    for n in ENACTABLE_TODAY
        @test issubset(CB.WORLD_UNCHANGED_STATUSES[n], CB.SILENT_SUCCESS_STATUSES[n])
    end

    # ---- 두 표가 갈리는 자리를 **값으로** 못박는다 (b) --------------------------------
    # 🔴 이 셋이 결함의 실체다: 조용한 성공이지만 세계는 이미 건드렸다.
    for (n, st) in (("translate_whole_build", :residual_blocked),
                    ("translate_whole_build", :already_clear),
                    ("restage_all_blocked",   :residual_blocked))
        @test CB._step_applied(n, st) === false         # 노린 적응은 아니다
        @test CB._step_touched_world(n, st) === true    # 🔴 그러나 세계는 건드렸다
    end
    # 나머지 조용한 성공은 두 표에서 같다 — 위 셋만 예외라는 것을 전수로 못박는다.
    for n in ENACTABLE_TODAY, st in CB.SILENT_SUCCESS_STATUSES[n]
        expected_touch = (n, st) in (("translate_whole_build", :residual_blocked),
                                     ("translate_whole_build", :already_clear),
                                     ("restage_all_blocked",   :residual_blocked))
        @test CB._step_touched_world(n, st) === expected_touch
    end

    # 🔴 "못 쟀다"의 답은 두 질문에서 **반대**다. 적응했다고 셀 수는 없지만, 세계가 깨끗하다고
    #    말할 수도 없다.
    @test CB._step_applied("translate_whole_build", :unreadable_return) === false
    @test CB._step_touched_world("translate_whole_build", :unreadable_return) === true
    # 표에 없는 원시도 마찬가지로 보수적이다(양쪽 다 "건드렸다").
    @test CB._step_touched_world("primitive_not_in_table", :whatever) === true

    # ---- 재개 표 (a) — 소스에서 읽은 값 그대로 --------------------------------------
    @test CB.PRIMITIVE_RESUMES_CACHE["restage_all_blocked"]         === true
    @test CB.PRIMITIVE_RESUMES_CACHE["translate_whole_build"]       === true
    @test CB.PRIMITIVE_RESUMES_CACHE["resolve_schedule_wedge"]      === true
    @test CB.PRIMITIVE_RESUMES_CACHE["reform_stuck_teams"]          === false
    @test CB.PRIMITIVE_RESUMES_CACHE["recover_stalled_teams"]       === false
    @test CB.PRIMITIVE_RESUMES_CACHE["force_advance_stuck_carrier"] === false

    # `_needs_cache_resume` = 세계를 건드렸고 && 스스로 재개 안 한다. 전수로 잰다.
    for n in ENACTABLE_TODAY, st in CB.SILENT_SUCCESS_STATUSES[n]
        @test CB._needs_cache_resume(n, st) ===
              (CB._step_touched_world(n, st) && !CB.PRIMITIVE_RESUMES_CACHE[n])
    end
    # 🔴 실제 적응 상태에서: 자체 재개 안 하는 셋은 참, 하는 셋은 거짓.
    @test CB._needs_cache_resume("recover_stalled_teams", :snapped) === true
    @test CB._needs_cache_resume("reform_stuck_teams", :moved) === true
    @test CB._needs_cache_resume("force_advance_stuck_carrier", :carrier_closed) === true
    @test CB._needs_cache_resume("translate_whole_build", :translated) === false
    @test CB._needs_cache_resume("restage_all_blocked", :restaged_all) === false
    @test CB._needs_cache_resume("resolve_schedule_wedge", :unwedged) === false
    # 아무 일도 안 한 판은 재개도 필요 없다(멱등이어도 안 해도 되는 일은 안 한다).
    @test CB._needs_cache_resume("recover_stalled_teams", :stuck) === false
    # ⚠️ 모르는 원시의 기본값은 "재개 안 함"(참)이다 — 모르는 것을 "알아서 하겠지"로 접으면
    #    그것이 곧 조용한 미복구다.
    @test CB._needs_cache_resume("primitive_not_in_table", :whatever) === true

    # ---- (13-c) `_issue_resume!` 가 진짜로 프론티어를 다시 짓는가 --------------------
    # 🔴 no-op 이 아님을 **세계 상태로** 확인한다: 낡은 정점을 심어 두고, 재개 뒤 사라지는지.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 12345)
        env = (cache = cache, sched = sched)
        @test CB._issue_resume!(env) === (:issued, "")
        @test isempty(cache.active_set)               # 낡은 프론티어가 실제로 지워졌다

        # ---- (13-d) 멱등 — 자체 재개한 원시 뒤에 한 번 더 나가도 해롭지 않다 --------
        # 근거 셋 중 셋째(소스·생산선례는 PRIMITIVE_RESUMES_CACHE docstring 에 있다).
        push!(cache.closed_set, 7)
        CB._issue_resume!(env)
        local a1, c1 = copy(cache.active_set), copy(cache.closed_set)
        CB._issue_resume!(env)
        @test cache.active_set == a1 && cache.closed_set == c1   # 두 번째 호출이 아무것도 안 바꾼다
    end

    # `env` 가 cache/sched 를 안 들고 있으면 **기록**이지 예외가 아니다.
    @test CB._issue_resume!((nope = 1,))[1] === :failed
    @test CB._issue_resume!(nothing)[1] === :failed

    # ---- (13-e) 양성 대조 — enact_minted! 이 실제로 재개를 집행한다 ------------------
    # 던진 단계는 무엇을 하다 던졌는지 모른다 → 보수적으로 재개한다. 이 판은 **진짜 캐시**를
    # 들고 있으므로 재개가 성공하고, 낡은 프론티어가 지워진 것이 관측된다.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 999)
        env = (cache = cache, sched = sched)          # scene_tree 없음 → reform 이 던진다
        r = CB.enact_minted!(env, nothing, _synth(names = ["reform_stuck_teams"]))
        @test r.verdict === :admit
        @test r.partial === true
        @test r.steps[1].status === :threw
        @test r.resume === :issued                    # 🔴 재개를 실제로 불렀다
        @test isempty(cache.active_set)               # 🔴 그리고 그것이 세계에 보인다
        @test occursin("resume=issued", r.reason)     # 조용하지 않다
    end

    # ---- (13-f) 음성 대조 — 안 건드렸으면 재개도 안 한다 -----------------------------
    # 같은 픽스처, 반대 결과. 이 쌍이 (13-e) 를 "언제나 재개한다" 로 읽는 길을 막는다.
    let sched = CB.OperatingSchedule(), cache = CB.initialize_planning_cache(sched)
        push!(cache.active_set, 999)
        env = (cache = cache, sched = sched, staging_circles = Dict{Symbol,Any}())
        r = CB.enact_minted!(env, nothing, _synth(names = ["translate_whole_build"]))
        @test r.steps[1].status === :no_staging
        @test r.world_maybe_dirty === false
        @test r.resume === :not_needed_untouched
        @test cache.active_set == Set([999])          # 🔴 프론티어가 그대로 = 재개 안 했다
        @test occursin("resume=not_needed", r.reason)
    end

    # ---- (13-h) 🔴 `world_maybe_dirty` 가 `applied` 가 아니라 `touched` 로 지어지는가 ----
    # (b) 결함의 실체를 **집행 경로 끝에서** 잰다. 그러려면 "조용한 성공인데 세계는 건드렸다"
    # 인 status 를 실제로 내는 판이 필요한데, `:residual_blocked` 는 진짜 기하가 있어야 나온다.
    # `:unreadable_return` 이 같은 성질을 값싸게 준다: `_step_applied=false`(못 쟀으니 성공으로
    # 안 센다) · `_step_touched_world=true`(못 쟀으니 깨끗하다고도 못 한다).
    # 오염 사본으로 `restage_all_blocked` 의 impl 만 "반환 모양을 못 읽는" 함수로 돌린다.
    mktempdir() do dir
        path = joinpath(dir, "primitive_registry.json")
        write(path, """
        {"primitives": [
          {"name":"restage_all_blocked","impl":"process_schedule!","surface":"physical",
           "harness_args":["env"],"params":{},"reversible":false}
        ]}""")
        withenv("PRIMITIVE_REGISTRY" => path) do
            CB._reset_primitive_table!()
            local sched = CB.OperatingSchedule()      # env 자리에 그대로 넣는다 — impl 이 이걸 받는다
            local r = CB.enact_minted!(sched, nothing, _synth(names = ["restage_all_blocked"]))
            @test r.steps[1].status === :unreadable_return
            @test r.applied === false                 # 못 쟀으면 적응했다고 안 센다
            @test r.partial === false                 # 던지지 않았다
            # 🔴 그런데도 참이다. `_r` 이 `applied || partial` 로 되돌아가면 이 줄이 빨개진다.
            @test r.world_maybe_dirty === true
            # 이 원시는 스스로 재개하므로 대신 부르지 않는다(멱등이어도 안 해도 되는 일은 안 한다).
            @test r.resume === :not_needed_self
            @test occursin("resume=not_needed", r.reason)
        end
        CB._reset_primitive_table!()
    end
    @test length(CB.PRIMITIVE_TABLE()) == 20          # 원래 레지스트리로 돌아왔다

    # ---- (13-g) 아무것도 안 부른 판의 resume 은 :none 이다 ---------------------------
    @test CB.enact_minted!(nothing, nothing, _synth(names = ["nope"])).resume === :none
    @test CB.enact_minted!(nothing, nothing, _synth(reach = "needs_primitive")).resume === :none
end

# =============================================================================
# (14) 🔴 2026-08-30 최종 리뷰 (IMPORTANT) — **타입 틀린 param 은 예외가 아니라 거절이다.**
#
# 레지스트리 `params` 의 **값**은 아무것도 못 박혀 있지 않았고 `bind_primitive_args` 는 매치된
# param 을 검증 없이 넘겼다(`zone_keys` 만 예외). 집행 가능한 여섯이 실제로 받는 타입 있는
# 키워드는 셋이다: `min_ready::Int` · `snap_all::Bool` · `tol::Float64`.
#
# `{"snap_all": "true"}` 는 **호출 경계의 `convert` 에서** 죽는다 — impl 본문은 한 줄도 안
# 돌았으므로 세계는 **증명 가능하게** 손대지 않은 상태다. 그런데 `enact_minted!` 의 `catch` 는
# 그것을 무조건 `partial = true` 로 적고, 그러면 `world_maybe_dirty = true` → T4 의
# `handled = true` 가 되어 **아무 일도 안 일어난 세계 위에서 기본 복구 사슬이 건너뛰어진다.**
# 즉 LLM 의 오타 하나가 폴백을 삼킨다.
#
# 그래서 이 절이 재는 것은 두 가지다: (i) 타입 오류가 `verdict=:reject` 로 나오는가(= 세계
# 무접촉, `steps` 비어 있음, 폴백이 산다), (ii) **맞는 타입은 여전히 통과하는가**(음성 대조 —
# 없으면 "전부 거절" 이라는 퇴화한 구현이 이 절을 통째로 초록으로 만든다).
# =============================================================================
@testset "(14) 선언된 타입으로 변환 안 되는 param 은 거절이다" begin
    # ---- 전제: 오늘 집행 가능한 여섯에서 타입 있는 키워드는 이 셋이다 ------------------
    local rf = CB.resolve_primitive("reform_stuck_teams")
    local fa = CB.resolve_primitive("force_advance_stuck_carrier")
    @test String(rf.params["min_ready"]["type"]) == "integer"
    @test String(rf.params["snap_all"]["type"])  == "boolean"
    @test String(fa.params["tol"]["type"])       == "number"

    # ---- (14-a) 순수 판정식. 스키마는 레지스트리에서 오고 여기서 다시 안 적는다 ---------
    @test CB._param_type_reject(rf.params["snap_all"], "true") !== nothing   # 문자열 → Bool 불가
    @test CB._param_type_reject(rf.params["snap_all"], true)   === nothing
    @test CB._param_type_reject(rf.params["min_ready"], 1.5)   !== nothing   # InexactError
    @test CB._param_type_reject(rf.params["min_ready"], 2)     === nothing
    @test CB._param_type_reject(rf.params["min_ready"], 2.0)   === nothing   # 변환은 된다
    @test CB._param_type_reject(fa.params["tol"], 0.02)        === nothing
    @test CB._param_type_reject(fa.params["tol"], "0.02")      !== nothing
    # 합집합 선언(`["string","null"]`)은 하나라도 변환되면 통과한다.
    local rp = CB.resolve_primitive("release_pending_assignments")
    @test CB._param_type_reject(rp.params["faulted"], "R3")    === nothing
    @test CB._param_type_reject(rp.params["faulted"], nothing) === nothing
    @test CB._param_type_reject(rp.params["faulted"], 3)       !== nothing
    # 🔴 선언이 없거나 모르는 타입이면 거절이다 — 통과시키면 레지스트리 편집이 게이트 전부
    #    초록인 채로 호출 표면을 넓힌다(R46 이 parked 한 확장 경로).
    @test CB._param_type_reject(Dict{String,Any}(), 1) == "no_declared_type"
    @test CB._param_type_reject(Dict{String,Any}("type" => "widget"), 1) ==
          "unknown_declared_type:widget"

    # ---- (14-b) 바인더가 그것을 **거절 문자열**로 낸다 ---------------------------------
    local bad = CB.bind_primitive_args(rf, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("snap_all" => "true")))
    @test bad isa String
    @test occursin("reject:param_type:snap_all", bad)
    @test occursin("reform_stuck_teams", bad)          # 어느 원시인지가 사유에 있다
    # 음성 대조 — 맞는 타입은 통과하고 값이 그대로 실린다("전부 거절" 구현을 막는다).
    local ok = CB.bind_primitive_args(rf, (env = Ref(:e), truth = nothing,
                    params = Dict{String,Any}("snap_all" => true, "min_ready" => 2)))
    @test ok isa Tuple
    @test ok[2].snap_all === true && ok[2].min_ready == 2

    # ---- (14-c) 🔴 집행부까지: `:reject` 이지 `partial` 이 아니다 -----------------------
    # 이것이 결함의 실체다. 고치기 전에는 `verdict=:admit, partial=true,
    # world_maybe_dirty=true` 였고 T4 가 그것을 `handled=true` 로 읽어 폴백을 삼켰다.
    local r = CB.enact_minted!(Ref(:e), nothing,
                _synth(names = ["reform_stuck_teams"],
                       params = Dict{String,Any}("min_ready" => 1.5)))
    @test r.verdict === :reject
    @test isempty(r.steps)                 # 🔴 한 발도 안 나갔다
    @test r.partial === false
    @test r.applied === false
    @test r.world_maybe_dirty === false     # ⟹ T4 의 handled 가 거짓 ⟹ 폴백이 산다
    @test r.resume === :none
    @test occursin("reject:param_type:min_ready", r.reason)
end

end # module
