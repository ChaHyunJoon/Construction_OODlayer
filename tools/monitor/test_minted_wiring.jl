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
# (2b) 🔴 **그런데 `resume === :failed` 면 `handled` 는 거짓이다** (2026-08-30 최종 리뷰,
#     CRITICAL — 다섯 번째 조용한 미복구). 세계는 고쳐졌는데 `_issue_resume!` 이 던져
#     프론티어가 낡은 채 남은 판이다. `handled=true` 를 내면 `policy_producer` 가 `nothing`
#     을 반환해 기본 복구 사슬이 통째로 건너뛰어지고 그 OOD 사건은 **이미 소비돼 다시 오지
#     않는다** — `PRIMITIVE_RESUMES_CACHE` 의 docstring 이 "성공과 구별되지 않는 미복구" 라고
#     이름 붙인 바로 그 사건이다.
#     🔴 (2)와 (2b)는 **body 도 결정 행도 같고 오직 env 만 다르다**: (2)의 env 는 진짜
#     `OperatingSchedule`+`PlanningCache` 를 들어 재개가 성공하고, (2b)의 env 는 안 들어 실패한다.
#     이 쌍이 없으면 "`partial` 이면 언제나 `handled`" 와 "재개를 봐서 정한다" 가 구분되지 않는다.
#
# (3) 조용한 성공(`:admit` 인데 `world_maybe_dirty=false`)은 `handled=false` 다 — 그리고
#     그 폴백도 조용하지 않다. (2) 와 (3) 이 함께 `world_maybe_dirty` 규칙을 양쪽에서 못박는다.
#
# (4) 🔴 **삼상을 이상으로 뭉개지 않는다**(spec §9-2). 로그가 `applied`·`partial`·
#     `world_maybe_dirty` 를 **각각** 찍는다. 하나로 접으면 "불렀는데 아무 일도 없었다"와
#     "던져서 세계가 절반이다"가 읽는 사람에게 같은 관측이 된다.
#     🔴 그리고 그 셋의 **관계**는 룰링 R48 이 정한 `touched || partial` 이지
#     `applied || partial` 이 **아니다.** 이 파일은 2026-08-30 T4 fix 까지 그 반증된 등식을
#     단언하고 있었고, 초록이던 이유는 fixture 둘이 "만졌는데 적응은 아님" status 에 한 번도
#     안 닿았기 때문이다(fixture 운). 닿는 순간 그 단언은 **옳은 코드를 상대로** 빨개지고,
#     가장 자연스러운 "수정" 은 R48 을 되돌리는 것이 된다. 그래서 여기서는 (i) 참인 함의 둘만
#     단언하고, (ii) 실제로 그 status 에 **닿는 fixture** 를 하나 만들어 옛 등식이 거짓임을
#     값으로 못박는다.
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

"""
    throw_env_with_live_cache() -> NamedTuple

`THROW_ENV` 와 **같은 방식으로 던지는데 재개는 성공하는** env. `test/minted_tool_enacts.jl`
(13-e) 의 정본 관용구다 — 진짜 `OperatingSchedule` + `initialize_planning_cache` 에 낡은 정점을
심어 두면, 재개가 실제로 나갔는지가 `active_set` 으로 **관측 가능**해진다.

🔴 이것이 (2)/(2b) 쌍의 **유일한** 차이다: body·결정 행·던지는 지점이 전부 같고
`env.cache`/`env.sched` 의 유무만 다르다. 그래서 두 판의 `handled` 가 갈리면 그것을 가른 것은
`resume` 뿐이다.
"""
function throw_env_with_live_cache()
    sched = CB.OperatingSchedule()
    cache = CB.initialize_planning_cache(sched)
    push!(cache.active_set, 999)          # 낡은 프론티어 — 재개가 나가면 지워진다
    return (cache = cache, sched = sched) # `staging_circles` 없음 → translate_whole_build! 이 던진다
end

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

        # ---- (1b) 🔴 그 줄이 **참인 말을 하고, 손에 든 증거를 버리지 않는다** ------------
        # 2026-08-30 최종 리뷰(IMPORTANT). 이 갈래는 `sl !== nothing` 이다 — 합성 레인이
        # **있다.** 그런데도 `reason=no synth lane on this decision` 을 찍고 있었다(거짓 진술),
        # 그리고 판별에 필요한 값 넷을 이미 손에 들고도 안 찍어서 T5 가 그 판별에 **유료 호출을
        # 한 번 더 썼다**. 그 넷이 "레인이 안 돌았다" · "돌다 터졌다" · "돌았고 expressible
        # 이라 안 쐈다" 를 가른다(spec §9-2 — 삼상을 이상으로 뭉개지 않는다).
        local sl4 = _sl(reach = nothing)
        sl4["synthesis_event"]  = true
        sl4["synthesis_ran"]    = false
        sl4["synthesis_error"]  = "boom: 합성기가 던졌다"
        sl4["tool_minted"]      = "disabled"
        r4, out4 = capture_out(() -> enact_minted_decision!(nothing, nothing, _dec(sl4)))
        @test occursin("lane=reach_nothing", out4)
        @test occursin("synthesis_event=true", out4)
        @test occursin("synthesis_ran=false", out4)
        @test occursin("synthesis_error=boom", out4)
        @test occursin("tool_minted=disabled", out4)
        # 🔴 사유가 갈래마다 다르고, 레인이 있는 갈래에서 "레인이 없다" 라고 말하지 않는다.
        @test !occursin("no synth lane", out4)
        @test !occursin("no synth lane", r4.reason)
        @test r4.reason != r.reason               # `sl === nothing` 갈래와 같은 문장이 아니다
        @test occursin("no synth lane", r.reason)  # 그쪽은 그대로 참이다
        # 그리고 값이 **없는** 판은 `nothing` 으로 찍힌다 — `false` 로 접히지 않는다.
        @test occursin("synthesis_event=nothing", out3)
        @test occursin("synthesis_ran=nothing", out3)
    end

    # -------------------------------------------------------------------------------------
    @testset "(2) 던졌고 재개가 성공하면 handled=true 다 (applied 가 아니다)" begin
        local env = throw_env_with_live_cache()
        r, out = capture_out(() -> enact_minted_decision!(env, nothing, _dec(_sl(names = BODY))))
        # 먼저 전제를 못박는다 — 이 판이 실제로 `applied=false, partial=true` 인가.
        @test r.verdict === :admit
        @test r.applied === false
        @test r.partial === true
        @test r.world_maybe_dirty === true
        # 🔴 2026-08-30 T4 리뷰(CRITICAL): 스케줄 캐시 재개 판정이 로그에 실린다.
        @test r.resume === :issued
        @test isempty(env.cache.active_set)      # 🔴 재개가 실제로 나갔다 — 세계에 보인다
        # 🔴 이 한 줄이 C1 이다. 브리핑의 `(:admit) && applied` 로 되돌리면 빨개진다.
        @test r.handled === true
        @test occursin("handled=true", out)
        @test !occursin("NOT handled", out)      # 처리했으면 폴백 문구가 없어야 한다
        @test occursin("threw", out)             # 어느 단계가 던졌는지 steps 에 남는다
        @test occursin("resume=issued", out)
    end

    # -------------------------------------------------------------------------------------
    @testset "(2b) 🔴 재개가 실패하면 handled=false 다 — 폴백을 삼키지 않는다" begin
        # 같은 body, 같은 던지는 지점. 다른 것은 env 가 `cache`/`sched` 를 안 든다는 것뿐이고
        # 그래서 `_issue_resume!` 이 실패한다 = 세계는 절반 고쳐졌는데 프론티어가 낡았다.
        r, out = capture_out(() -> enact_minted_decision!(THROW_ENV, nothing, _dec(_sl(names = BODY))))
        # 전제 — 이 판이 정말 "던졌고 세계가 더러울 수 있고 재개가 실패했다" 인가.
        @test r.verdict === :admit
        @test r.partial === true
        @test r.world_maybe_dirty === true
        @test r.resume === :failed
        # 🔴 이 세 줄이 최종 리뷰의 CRITICAL 이다. `handled` 에서 `resume !== :failed` 연언지를
        #    빼면 전부 빨개진다 — 그리고 그 상태가 곧 다섯 번째 조용한 미복구다.
        @test r.handled === false
        @test occursin("handled=false", out)
        @test occursin("NOT handled", out)       # 🔴 폴백이 **살아 있다**, 그리고 조용하지 않다
        @test occursin("resume=failed", out)     # 그리고 무엇이 폴백을 살렸는지가 로그에 있다
    end

    # -------------------------------------------------------------------------------------
    @testset "(2a) 🔴 재풀이가 CB 본체에 산다 — 런타임 include 없이 존재한다" begin
        # 판정 1 의 근거였던 실측: 이 단언들은 2026-09-02 이전에 **거짓이었다.**
        #   `using ConstructionBots` 뒤 `isdefined(CB, :resolve_assignments!) == false`
        # 재풀이가 `src/smdp/mdp.jl` 의 런타임 include 안에만 살았기 때문이고, 이 파일이
        # 재는 프로덕션 집행 엔진(`render_demo.jl`)은 그 모듈을 include 하지 **않는다**.
        # ⟹ 프롬프트가 두 번 약속한 "the harness re-solves that MILP after every tool body"
        #   가 이 엔진에서 거짓이었고, body 가 배정 간선을 떼면 아무도 재배정하지 않았다.
        @test isdefined(CB, :resolve_assignments!)
        @test isdefined(CB, :assignment_binding)
        @test isdefined(CB, :RESOLVE_CALLS)
        # 🔴 `isdefined` 만으로는 부족하다 — 스위트 안에서는 다른 파일이 런타임 include 를
        #    먼저 했을 수 있어 **어디에 정의됐는지**가 진짜 명제다. 메서드의 소스 위치로 잰다.
        local loc = string(first(Base.functionloc(first(methods(CB.resolve_assignments!)))))
        @test occursin(joinpath("src", "respec"), loc)
        @test !occursin(joinpath("src", "smdp"), loc)
        # 배정을 읽는 구현도 한 벌이다 — `simstate_of` 가 이 함수를 부른다.
        local locb = string(first(Base.functionloc(first(methods(CB.assignment_binding)))))
        @test occursin(joinpath("src", "respec"), locb)
    end

    # -------------------------------------------------------------------------------------
    # 2026-09-02 (판정 1) — 공통 MILP 재풀이가 주조 body 뒤에 실제로 돈다.
    #
    # 🔴 계기는 실측이다. `synthesize.py` 는 프롬프트에서 두 번 "THE HARNESS RE-SOLVES THAT
    #    MILP AUTOMATICALLY AFTER EVERY TOOL BODY" 라고 약속하는데, 그 약속이 이 엔진에서
    #    **거짓이었다**: 재풀이는 SMDP 런타임 모듈 안에만 살았고 이 파일의 유일한 프로덕션
    #    호출자(render_demo.jl)는 그 모듈을 include 하지 않는다. 그래서 body 가 배정 간선을
    #    떼면 아무도 재배정하지 않은 채 `handled=true` 로 폴백까지 삼켰다.
    #    2026-09-02 F7 이후 mild 레인이 실제로 `release_pending_assignments` 하나짜리
    #    `composed` body 를 내기 시작했으므로, 그때까지 우리를 **우연히** 보호하던
    #    `reach=="composed"` 게이트도 사라졌다.
    #
    # 아래 셋은 **같은 body·같은 env, 레지스트리의 `surface` 만 다른 쌍**으로 가른다.
    @testset "(2c) 🔴 배정을 건드리는 body 뒤에는 재풀이가 돈다 — 실패하면 handled=false" begin
        # `surface="sched"` 인 원시 하나. impl 은 세계를 안 건드리는 것으로 두고(측정 대상은
        # 재풀이의 발화이지 그 원시의 효과가 아니다), env 는 재풀이가 **성립하지 않는** 스텁이라
        # `resolve` 가 실패로 끝난다 = "간선을 뗐는데 아무도 재배정 못 했다" 의 값싼 재현이다.
        mktempdir() do dir
            local path = joinpath(dir, "primitive_registry.json")
            write(path, """
            {"primitives": [
              {"name":"release_pending_assignments","impl":"process_schedule!","surface":"sched",
               "harness_args":["env"],"params":{},"reversible":false}
            ]}""")
            withenv("PRIMITIVE_REGISTRY" => path) do
                CB._reset_primitive_table!()
                local n0 = CB.RESOLVE_CALLS[]
                # 🔴 **재개가 성공하는** env 를 쓴다. 여기서 스텁 `OperatingSchedule` 을 넘기면
                #    `_issue_resume!` 이 먼저 실패해 `handled=false` 를 **재개 가드가 설명**하고,
                #    이 시험은 재풀이에 대해 아무것도 못 재게 된다(실측: 그 판에서 변이 R4 —
                #    handled 에서 재풀이 항을 빼기 — 가 초록이었다).
                local env = throw_env_with_live_cache()
                r, out = capture_out(() -> enact_minted_decision!(
                    env, nothing, _dec(_sl(names = ["release_pending_assignments"]))))
                @test r.verdict === :admit
                @test r.world_maybe_dirty === true
                # 전제: 다른 가드는 **열려 있다** — 그래야 아래 handled 가 재풀이의 몫이다.
                @test r.resume !== :failed
                # 🔴 재풀이가 **실제로 불렸다** — 카운터가 증거다(로그 문자열이 아니라).
                @test CB.RESOLVE_CALLS[] == n0 + 1
                @test r.resolve === :threw
                # 🔴 그리고 그 실패가 힘을 갖는다: 폴백이 살아난다.
                @test r.handled === false
                @test occursin("resolve=", out)
                @test occursin("NOT handled", out)
            end
            CB._reset_primitive_table!()
        end
    end

    @testset "(2d) 배정을 안 건드리는 body 뒤에는 안 돈다 — 그리고 그 사실이 기록된다" begin
        # 음성 대조. (2c) 와 **한 글자만 다르다**: surface 가 scene_tree 다.
        mktempdir() do dir
            local path = joinpath(dir, "primitive_registry.json")
            write(path, """
            {"primitives": [
              {"name":"restage_all_blocked","impl":"process_schedule!","surface":"scene_tree",
               "harness_args":["env"],"params":{},"reversible":false}
            ]}""")
            withenv("PRIMITIVE_REGISTRY" => path) do
                CB._reset_primitive_table!()
                local n0 = CB.RESOLVE_CALLS[]
                local sched = CB.OperatingSchedule()
                r, out = capture_out(() -> enact_minted_decision!(
                    sched, nothing, _dec(_sl(names = ["restage_all_blocked"]))))
                @test r.verdict === :admit
                @test CB.RESOLVE_CALLS[] == n0          # 🔴 한 번도 안 불렸다
                @test r.resolve === :not_needed_surface  # 🔴 조용히 안 부른 것이 아니라 기록됐다
                @test r.handled === true                 # 배정을 안 건드렸으니 폴백 억제는 그대로
                @test occursin("resolve=not_needed_surface", out)
            end
            CB._reset_primitive_table!()
        end
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
            @test occursin("resume=", out)
            @test occursin("verdict=admit", out)
            # 반환값에서도 셋이 따로 산다(호출자가 하나만 읽고 다른 것의 답을 얻어 가면 안 된다).
            r = capture_out(() -> enact_minted_decision!(env, nothing, _dec(_sl(names = BODY))))[1]
            @test hasproperty(r, :applied) && hasproperty(r, :partial) &&
                  hasproperty(r, :world_maybe_dirty)
            # 🔴 R48. 규칙은 `touched || partial` 이고 `touched` 는 이 경계에서 안 보인다 —
            #    그래서 여기서 단언할 수 있는 것은 **참인 함의 둘**뿐이다(역은 거짓이다).
            #    옛 등식 `world_maybe_dirty === (applied || partial)` 을 여기 적으면 아래
            #    (4b) 의 fixture 에서 옳은 코드를 상대로 빨개진다.
            @test !r.applied || r.world_maybe_dirty      # applied ⟹ dirty
            @test !r.partial || r.world_maybe_dirty      # partial ⟹ dirty
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
    @testset "(4b) 🔴 옛 등식 `applied || partial` 은 거짓이다 — 닿는 fixture 로 못박는다" begin
        # 필요한 것은 "세계는 만졌는데 노린 적응은 아니다" 인 status 에 **실제로 닿는** 판이다.
        # `:residual_blocked` 는 진짜 기하가 있어야 나오므로 `test/minted_tool_enacts.jl` (13-h)
        # 의 값싼 대체물을 그대로 쓴다: `:unreadable_return` 은 `_step_applied=false`(못 쟀으니
        # 성공으로 안 센다) · `_step_touched_world=true`(못 쟀으니 깨끗하다고도 못 한다) 다.
        # 오염 사본으로 `restage_all_blocked` 의 impl 만 "반환 모양을 못 읽는" 함수로 돌린다.
        mktempdir() do dir
            local path = joinpath(dir, "primitive_registry.json")
            write(path, """
            {"primitives": [
              {"name":"restage_all_blocked","impl":"process_schedule!","surface":"physical",
               "harness_args":["env"],"params":{},"reversible":false}
            ]}""")
            withenv("PRIMITIVE_REGISTRY" => path) do
                CB._reset_primitive_table!()
                local sched = CB.OperatingSchedule()   # env 자리에 그대로 — impl 이 이걸 받는다
                r, out = capture_out(() -> enact_minted_decision!(
                    sched, nothing, _dec(_sl(names = ["restage_all_blocked"]))))
                # 전제 — 이 판이 정말 그 status 에 닿았는가.
                @test r.verdict === :admit
                @test length(r.steps) == 1 && r.steps[1].status === :unreadable_return
                @test r.applied === false
                @test r.partial === false
                # 🔴 여기가 요점이다. 옛 등식이면 `false` 여야 하는 자리에서 **참**이다.
                @test r.world_maybe_dirty === true
                @test r.world_maybe_dirty !== (r.applied || r.partial)
                # 그리고 그 참이 실제로 힘을 갖는다 — 폴백이 억제된다.
                @test r.resume === :not_needed_self
                @test r.handled === true
                @test occursin("world_maybe_dirty=true", out)
                @test occursin("applied=false", out)
                @test occursin("handled=true", out)
            end
            CB._reset_primitive_table!()
        end
        # 🔴 2026-09-02 (cargo-ban T7) 실측 재확인: 표는 **19 그대로다**.
        #    `reprice_agent_by_payload` 가 나가고 `forbid_heavy_cargo` 가 들어온 1:1 교체라
        #    개수가 안 움직였다 — 즉 **이 숫자는 알파벳 교체를 못 잡는다.** 이름을 재는 것은
        #    `test/minted_tool_enacts.jl` 의 `ENACTABLE_TODAY`·`REGISTRY_SURFACE_TODAY` 다.
        @test length(CB.PRIMITIVE_TABLE()) == 19       # 원래 레지스트리로 돌아왔다
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
