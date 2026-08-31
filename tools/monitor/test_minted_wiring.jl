# =============================================================================
# tools/monitor/test_minted_wiring.jl
# 합성 tool 집행 **배선**의 순수 함수 게이트 (2026-08-30, T4).
#
# 🔴 서비스는 **아예 안 부른다** — `127.0.0.1:8077`/`:8079` 로 나가는 요청 0건(유료 호출).
#    `render_demo.jl` 도 안 돌린다(3분 + 유료 호출). 여기서 재는 것은 `enact.jl` 의
#    `enact_minted_decision!` 하나이고, 세계는 손으로 지은 최소 env 로 대신한다
#    (`test/minted_tool_enacts.jl` (11) 의 정본 관용구를 그대로 쓴다).
#
# 재는 명제 여덟
# --------------
# (1) `synth_lane` 이 없으면 `handled=false` 이고 **조용하지 않다** — 조기 반환에서도
#     `[minted]` 줄과 폴백 사유가 찍힌다.
#     🔴 `[minted]` 줄이 무조건 찍혀야 하는 이유: `policy_producer` 는 OOD 마다 도달하지
#     않는다(`is_reform_alarm` 조기 반환 · `truth_for_event` 의 NL 정확일치 조회 실패).
#     조건부로 찍으면 줄의 부재가 원인 셋을 갖게 되어 다음 태스크가 못 가른다.
#
# (2) 🔴 **`handled` 는 `(:admit) && applied` 가 아니다.** 1단계가 던져 세계가 절반일 수
#     있는 판(`applied=false`, `partial=true`, `world_maybe_dirty=true`)에서 `handled` 는
#     **참**이어야 한다 — 반쯤 편집된 세계 위에 기본 복구 사슬을 얹는 것이 안 얹는 것보다
#     나쁘기 때문이다. 판정은 파생 필드 `world_maybe_dirty` 로 한다.
#
# (3) 조용한 성공(`:admit` 인데 `world_maybe_dirty=false`)은 `handled=false` 다 — 그리고
#     그 폴백도 조용하지 않다. (2) 와 (3) 이 함께 `world_maybe_dirty` 규칙을 양쪽에서 못박는다.
#
# (4) 🔴 **삼상을 이상으로 뭉개지 않는다**(spec §9-2). 로그가 `applied`·`partial`·
#     `world_maybe_dirty` 를 **각각** 찍는다. 하나로 접으면 "불렀는데 아무 일도 없었다"와
#     "던져서 세계가 절반이다"가 읽는 사람에게 같은 관측이 된다.
#
# (5) 🔴 레지스트리가 망가져 `PRIMITIVE_TABLE` 이 `error(...)` 를 내도 **던지지 않는다.**
#     새면 `maybe_respecify!` 의 producer `try` 로 올라가 비-`:soft` 사건에서
#     `engage_fallback!`(= 라인 정지)이 걸리고, 로그는 JSON 오타가 아니라 OOD 를 탓하게 된다.
#
# (6) 🔴 MILP 프로브는 **센티넬**이다. 재풀이가 없으면 `n_candidate_edges` 를 숫자로 찍지
#     않는다 — `LAST_EDGE_COSTS[]` 는 그때 0 이 아니라 **미정의**이고, 맨 `length` 를 찍으면
#     "후보 간선 0" 과 "MILP 가 아예 안 돌았다" 가 같은 관측이 된다.
#
# (7) `policy_producer` 가 `macro_to_proposal` **앞**에서 집행하고, 처리했으면 dispatch 를
#     건너뛴다. 소스 텍스트로 잰다 — `render_demo.jl` 은 스크립트라 include 할 수 없고 이
#     태스크가 그 실행을 금지한다(≈3분 + 유료 호출). **실행**은
#     `test/render_lane_uses_llm_agent.jl` (B) 가 원문 eval 로 잰다.
#
# (8) 구역 진단 계측이 원시값만 찍는다 — 🔴 오라클 라벨(`verdict`·`relocate_*`)은 읽지도
#     찍지도 않는다. 그리고 찍는 아홉 필드 이름을 **진짜 `zone_diagnosis` 반환값**에 대고
#     잰다(그 println 은 렌더를 돌려야만 실행되므로 오타가 런타임까지 산다).
#
# ⚠️ `Suppressor` 는 이 프로젝트에 **없다**(`Project.toml`·`Manifest.toml` 둘 다 0건, 실측).
#    `@capture_out` 대신 stdlib `redirect_stdout` 을 쓴다. 레포에 기존 stdout 캡처 관용구가
#    없어서(`grep -rn redirect_stdout test tools` = 0건) 여기서 최소 헬퍼 하나를 만든다.
#
# 🔴 `test/runtests.jl` 은 모든 시험 파일을 **같은 `Main` 스코프**에 include 한다 — 그래서
#    이 파일도 자기 `module` 로 감싼다(`test/minted_tool_enacts.jl` 과 같은 관용구).
#
# 실행: julia +lts --project=. tools/monitor/test_minted_wiring.jl
# =============================================================================
module MintedWiring

using Test
using ConstructionBots
const CB = ConstructionBots

isdefined(CB, :BatteryTruth) ||
    CB.include(joinpath(@__DIR__, "..", "..", "src", "navigator", "navigator.jl"))

# 생산 코드. `enact.jl` 은 최상위 부작용이 없다(T2 커밋 1 의 요구조건) — 함수 정의뿐이라
# 이렇게 태울 수 있다. include 하는 쪽이 `const CB` 를 이미 들고 있어야 한다(위 줄).
include(joinpath(@__DIR__, "enact.jl"))

"""
    capture_out(f) -> (value, stdout_text)

`Suppressor` 없이 stdout 을 잡는다. 🔴 `f` 가 던져도 파이프를 반드시 되돌린다 — 안 그러면
이 파일 뒤의 모든 테스트 출력이 사라진 파이프로 새고 `Pkg.test()` 요약이 통째로 안 보인다.
"""
function capture_out(f)
    old = stdout
    rd, wr = redirect_stdout()
    local val, txt
    try
        val = f()
    finally
        redirect_stdout(old)
        close(wr)
        txt = read(rd, String)
        close(rd)
    end
    return val, txt
end

# `decide_all` 이 만드는 결정 행과 **같은 모양**의 최소 대역. `synth_lane` 만이 이 함수의 입력이다.
_dec(sl) = (macro_name = "NOOP", synth_lane = sl)

# 합성 레인 dict — `policy.jl::SYNTH_LANE_KEYS` 아홉 중 집행부가 읽는 것만 채운다.
# (아홉 키가 전부 존재한다는 계약은 `test/synth_lane_keys_survive.jl` 이 지킨다.)
_sl(; reach = "composed", names = String[], params = Dict{String,Any}(), tool = "MintedTool") =
    Dict{String,Any}("reach" => reach, "body_names" => names, "tool_name" => tool,
                     "params" => params, "missing_primitive" => nothing)

# `test/minted_tool_enacts.jl` (11) 의 정본 두 세계. 하나는 조용한 성공, 하나는 던진다.
const QUIET_ENV = (staging_circles = Dict{Symbol,Any}(),)   # → :no_staging (조용한 성공)
const THROW_ENV = (nope = 1,)                               # → :threw      (세계가 절반일 수 있다)
const BODY = ["translate_whole_build"]

@testset "T4 배선 — 합성 tool 집행 진입점" begin

    # -------------------------------------------------------------------------------------
    @testset "(1) synth_lane 이 없으면 handled=false 이고 조용하지 않다" begin
        r, out = capture_out(() -> enact_minted_decision!(nothing, nothing, (macro_name = "NOOP",)))
        @test r.handled === false
        @test r.verdict === :deferred
        @test occursin("[minted]", out)          # 🔴 조기 반환에서도 줄이 있다(C5)
        @test occursin("NOT handled", out)
        @test occursin("lane=absent", out)

        # 필드가 있는데 값이 `nothing` 인 경우도 같은 경로다 — 그러나 로그는 두 원인을 가른다.
        r2, out2 = capture_out(() -> enact_minted_decision!(nothing, nothing, _dec(nothing)))
        @test r2.handled === false && r2.verdict === :deferred
        @test occursin("lane=absent", out2)

        r3, out3 = capture_out(() -> enact_minted_decision!(nothing, nothing,
                                                           _dec(_sl(reach = nothing))))
        @test r3.handled === false && r3.verdict === :deferred
        @test occursin("lane=reach_nothing", out3)
    end

    # -------------------------------------------------------------------------------------
    @testset "(2) 던져서 세계가 절반일 수 있으면 handled=true 다 (applied 가 아니다)" begin
        r, out = capture_out(() -> enact_minted_decision!(THROW_ENV, nothing, _dec(_sl(names = BODY))))
        # 먼저 전제를 못박는다 — 이 판이 실제로 `applied=false, partial=true` 인가.
        @test r.verdict === :admit
        @test r.applied === false
        @test r.partial === true
        @test r.world_maybe_dirty === true
        # 🔴 이 한 줄이 C1 이다. 브리핑의 `(:admit) && applied` 로 되돌리면 빨개진다.
        @test r.handled === true
        @test occursin("handled=true", out)
        @test !occursin("NOT handled", out)      # 처리했으면 폴백 문구가 없어야 한다
        @test occursin("threw", out)             # 어느 단계가 던졌는지 steps 에 남는다
    end

    # -------------------------------------------------------------------------------------
    @testset "(3) 조용한 성공은 handled=false 이고 그 폴백도 조용하지 않다" begin
        r, out = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing, _dec(_sl(names = BODY))))
        @test r.verdict === :admit
        @test r.applied === false
        @test r.partial === false
        @test r.world_maybe_dirty === false
        @test r.handled === false                # :admit 이어도 세계를 안 건드렸으면 폴백한다
        @test occursin("NOT handled", out)
        @test occursin("no_staging", out)        # 왜 조용했는지가 로그에 있다
    end

    # -------------------------------------------------------------------------------------
    @testset "(4) 삼상을 이상으로 뭉개지 않는다 — 세 필드가 각각 찍힌다" begin
        for (env, tag) in ((QUIET_ENV, "quiet"), (THROW_ENV, "threw"))
            _, out = capture_out(() -> enact_minted_decision!(env, nothing, _dec(_sl(names = BODY))))
            @test occursin("applied=", out)
            @test occursin("partial=", out)
            @test occursin("world_maybe_dirty=", out)
            @test occursin("verdict=admit", out)
            # 반환값에서도 셋이 따로 산다(호출자가 하나만 읽고 다른 것의 답을 얻어 가면 안 된다).
            r = capture_out(() -> enact_minted_decision!(env, nothing, _dec(_sl(names = BODY))))[1]
            @test hasproperty(r, :applied) && hasproperty(r, :partial) &&
                  hasproperty(r, :world_maybe_dirty)
            @test r.world_maybe_dirty === (r.applied || r.partial)
        end

        # 거절은 세 필드가 전부 거짓이다 — "부르지 않았다".
        r, out = capture_out(() -> enact_minted_decision!(THROW_ENV, nothing,
                                                          _dec(_sl(names = ["teleport_the_build"]))))
        @test r.verdict === :reject
        @test r.applied === false && r.partial === false && r.world_maybe_dirty === false
        @test r.handled === false
        @test occursin("NOT handled", out)
    end

    # -------------------------------------------------------------------------------------
    @testset "(5) 레지스트리가 망가져도 던지지 않는다 — 렌더를 세우지 않는다" begin
        # 🔴 `PRIMITIVE_TABLE` 은 레지스트리가 없으면 설계상 `error(...)` 다. 그 예외가
        #    `enact_minted_decision!` 밖으로 새면 `maybe_respecify!` 의 producer `try` 가
        #    잡아 비-`:soft` 사건에서 `engage_fallback!`(라인 정지)을 건다.
        mktempdir() do dir
            withenv("PRIMITIVE_REGISTRY" => joinpath(dir, "__no_such_registry__.json")) do
                CB._reset_primitive_table!()
                @test_throws Exception CB.PRIMITIVE_TABLE()      # 전제: 정말로 던진다
                r, out = capture_out(() ->
                    enact_minted_decision!(THROW_ENV, nothing, _dec(_sl(names = BODY))))
                @test r.handled === false
                @test r.verdict === :reject                      # 아무것도 부르기 전에 돌아섰다
                @test occursin("FAILED", out)                    # 크게 찍는다
                @test occursin("[minted]", out)
                @test occursin("NOT handled", out)
                @test occursin("primitive_registry", r.reason)   # **무엇이** 틀렸는지가 사유다
            end
            CB._reset_primitive_table!()
        end
        @test length(CB.PRIMITIVE_TABLE()) == 19                 # 원래 레지스트리로 돌아왔다
    end

    # -------------------------------------------------------------------------------------
    @testset "(6) MILP 프로브는 센티넬이다 — 재풀이가 없으면 숫자를 안 찍는다" begin
        # 이 두 판은 `formulate_milp` 을 아예 안 부른다(zone 원시 하나뿐).
        for env in (QUIET_ENV, THROW_ENV)
            _, out = capture_out(() -> enact_minted_decision!(env, nothing, _dec(_sl(names = BODY))))
            @test occursin("ran_milp=false", out)
            @test occursin("n_candidate_edges=n/a(no re-solve)", out)
            # 🔴 `ran_milp` 없이 숫자를 찍지 않는다 — 0 과 "안 돌았다"는 다른 사건이다.
            @test !occursin("n_candidate_edges=0", out)
        end

        # 센티넬은 **호출 전에** 심긴다: 집행 전의 `LAST_EDGE_COSTS[]` 가 남아 있어도 그것을
        # 이 결정의 결과로 읽지 않는다.
        local saved = CB.LAST_EDGE_COSTS[]
        try
            CB.LAST_EDGE_COSTS[] = Dict{Tuple{Int,Int},Float64}((1, 2) => 3.0)  # 이전 결정의 찌꺼기
            _, out = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
                                                              _dec(_sl(names = BODY))))
            @test occursin("ran_milp=false", out)          # 찌꺼기를 재풀이로 읽지 않는다
            @test !occursin("n_candidate_edges=1", out)
        finally
            CB.LAST_EDGE_COSTS[] = saved
        end
    end

    # -------------------------------------------------------------------------------------
    # (7)(8) 은 **소스 텍스트**로 잰다. `render_demo.jl` 은 최상위에서 데모를 통째로 돌리는
    # 스크립트라 include 할 수 없고(그 파일 자신의 주석이 근거), 이 태스크의 제약이
    # `render_demo.jl` 실행을 금지한다(≈3분 + 유료 호출). `policy_producer` 의 **실행**은
    # `test/render_lane_uses_llm_agent.jl` (B) 가 원문 eval 로 잰다 — 여기서는 그 파일이 못
    # 재는 두 성질(호출 **순서**, 그리고 오라클 라벨 유출)만 잰다.
    # 🔴 못 찾으면 `error()` 다. 조용히 빈 문자열을 돌려주면 "블록이 없다"가 "검사할 것이
    #    없다"로 읽혀 초록이 된다.
    # -------------------------------------------------------------------------------------
    # 🔴 **주석 줄은 버린다.** 이것이 이 절의 결함 하나를 실제로 고친 조치다: 처음 판은
    #    `occursin("println", l)` 로 걸렀는데 Julia 의 여러 줄 `println` 은 **첫 줄에만**
    #    그 토큰이 있어서, 이어지는 줄에 `relocate_norm=$(zd.relocate_norm)` 를 붙이는 변이가
    #    초록으로 통과했다(실측). 그리고 이 파일과 `render_demo.jl` 의 주석 자체가 금지어와
    #    `enact_minted_decision!` 를 **설명하려고** 적으므로, 주석을 안 버리면 (7) 의 순서
    #    단언도 주석 줄을 집어 배선 삭제 변이를 놓친다(그것도 실측했다).
    function code_block(path, start, stop)
        lines = readlines(path)
        i = findfirst(l -> occursin(start, l), lines)
        i === nothing && error("code_block: $(repr(start)) 를 $(path) 에서 못 찾았다")
        j = findnext(l -> occursin(stop, l), lines, i + 1)
        j === nothing && error("code_block: $(repr(stop)) 를 $(path) 의 $(i) 줄 뒤에서 못 찾았다")
        return filter(l -> !startswith(strip(l), "#"), lines[i:j])
    end
    RENDER = joinpath(@__DIR__, "render_demo.jl")

    @testset "(7) policy_producer 가 macro_to_proposal **앞**에서 집행한다" begin
        src = code_block(RENDER, "function policy_producer(env, event)", r"^end$")
        ie = findfirst(l -> occursin("enact_minted_decision!", l), src)
        ip = findfirst(l -> occursin("macro_to_proposal(", l), src)
        @test ie !== nothing                 # 배선이 있다
        @test ip !== nothing                 # 옛 경로도 그대로 있다(폴백이 살아 있다)
        # 🔴 순서가 이 태스크의 전부다. 뒤로 가면 합성이 처리한 사건도 닫힌 어휘의 매크로로
        #    번역돼 dispatch 를 타고, 세계는 두 번 고쳐진다.
        @test ie !== nothing && ip !== nothing && ie < ip
        # 처리했으면 dispatch 를 건너뛴다 — 이 줄이 없으면 `handled` 는 계산만 되고 아무 힘이 없다.
        @test any(l -> occursin("handled", l) && occursin("return nothing", l), src)
    end

    @testset "(8) 구역 진단은 찍되 **오라클 라벨은 안 찍는다**" begin
        src = code_block(RENDER, "function inject_blocking_zone!(env;", r"^end$")
        @test any(l -> occursin("zone_diagnosis", l), src)
        @test any(l -> occursin("[zone] diag", l), src)
        # 🔴 `verdict`·`relocate_*` 는 오라클의 정답이다(`relocate_norm` 이 곧
        #    `min_shift_to_clear_m`). 새어 나가면 다음 태스크가 추론 대신 정답 준수를 재게
        #    된다. 찍는 것만이 아니라 **읽는 것부터** 금지한다 — 읽어 둔 값은 결국 어딘가로 샌다.
        for bad in ("relocate_norm", "relocate_delta", "relocate_feasible", "verdict")
            @test !any(l -> occursin(bad, l), src)
        end
        # 🔴 `zone_diagnosis(...).n_blocked`(막힌 **조립체**)와 기존 줄의 `nav_blocked=`
        #    (= `zone_blockage(...).n_blocked`, 항법 차단)를 합치지 않는다 — 다른 술어다.
        @test any(l -> occursin("n_nav_blocked=", l), src)
        @test any(l -> occursin("n_blocked=", l), src)

        # 🔴 **필드 이름을 진짜 반환값에 대고 잰다.** 이 계측은 `render_demo.jl` 을 돌려야만
        #    실행되는데 그 실행은 ≈3분 + 유료 호출이라 이 게이트가 못 태운다. 그래서 오타
        #    하나(`zd.n_blockedd`)나 `zone_diagnosis` 쪽 필드 개명이 **런타임에** 터지고,
        #    그 자리는 `catch` 가 없는 `println` 이다. 대신 여기서 이름을 대조한다.
        #    등록되지 않은 존은 env 를 한 번도 안 쓰고 `:no_such_zone` 전체 NamedTuple 을
        #    돌려주므로(그 함수의 첫 블록), 세계 없이 필드 집합을 얻을 수 있다.
        real = CB.zone_diagnosis(nothing, :__t4_no_such_zone__)
        @test real.verdict === :no_such_zone            # 전제: 정말 그 조기 반환이다
        used = Set{Symbol}()
        for l in src, m in eachmatch(r"zd\.([A-Za-z_][A-Za-z0-9_]*)", l)
            push!(used, Symbol(m.captures[1]))
        end
        @test length(used) == 9                          # 아홉 원시값을 찍는다
        for f in used
            @test hasproperty(real, f)
        end
    end
end

end # module
