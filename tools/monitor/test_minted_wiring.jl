# =============================================================================
# tools/monitor/test_minted_wiring.jl
# 합성 tool 집행 **배선**의 순수 함수 게이트 (2026-08-30, T4).
#
# 🔴 서비스는 **아예 안 부른다** — `127.0.0.1:8077`/`:8079` 로 나가는 요청 0건(유료 호출).
#    `render_demo.jl` 도 안 돌린다(3분 + 유료 호출). 여기서 재는 것은 `enact.jl` 의
#    `enact_minted_decision!` 하나이고, 세계는 손으로 지은 최소 env 로 대신한다
#    (`test/minted_tool_enacts.jl` (11) 의 정본 관용구를 그대로 쓴다).
#
# 재는 명제 열하나 — (1)~(11). 🔴 **(5) 는 삭제됐다**(아래 그 자리의 설명 참고).
#   ⚠️ 2026-09-03 fix round 2 (F10): 이 줄은 fix round 1 까지 "재는 명제 열" 이었고, 그 동안
#   같은 라운드가 더한 (11) 이 색인에 없었다. 명제를 더하거나 빼면 이 줄도 같이 고칠 것 —
#   이 파일이 무엇을 덮는지 판단하는 다음 사람은 testset 목록이 아니라 여기를 읽는다.
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
# (5) 🔴 **삭제됨** (2026-09-03, Task 10). 전제(`PRIMITIVE_TABLE` 이 설계상 던진다)가 두 겹으로
#     사라졌고, 그 전제 줄 자체가 **조용한 항진**이었다 — `@test_throws Exception
#     CB.PRIMITIVE_TABLE()` 은 `UndefVarError <: Exception` 이라 심볼이 없어도 통과한다(실측).
#     줄 단위로 고치면 커버리지 0 인 자리에 초록 체크가 생기므로 절을 통째로 지웠다. 자세한
#     근거는 그 자리의 주석에 있다.
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
# (9) 🔴 자기신고와 무관하게 `handled` 는 **세계가** 정한다. 나머지 세 연언지는 하나도 안
#     풀린다(같은 body, env 만 다른 세 판). ⚠️ 옛 제목은 "`:admit_unsanctioned` 도 폴백을
#     건너뛴다" 였다 — 그 verdict 는 Task 9 가 지웠다(조합 단계가 없어졌다, D8). 재던 성질은
#     그대로이고 verdict 자리만 오늘의 값이다.
#
# (10) 🔴 `handled` 의 **첫** 연언지(`CB.minted_handled_verdict_ok`)를 verdict 하나만 움직여
#     고립시킨다. 오늘 이 조합은 `_r` 의 기본 인자 때문에 도달 불가지만, 그 기본값이 바뀌는
#     날 첫 연언지가 유일한 방어선이 된다 — 절 (10) 의 주석이 근거를 적는다.
#
# (11) 🔴 `registered` 는 삼상인데 **사건은 넷**이다 — `false` 가 "등록할 코드가 없어 시도조차
#     안 했다" 와 "시도했는데 규약 위반으로 거절됐다" 를 함께 덮는다. 가르는 것은
#     `impl_rejected_why` 이므로 **두 필드를 짝으로** 읽어야 넷이 일대일이 된다. 로그가 그
#     짝을 접지 않는지 값과 문자열 양쪽에서 잰다.
#
# 🔴 2026-09-03 (Task 10) — 원시 표는 런 스코프이고 기본이 비어 있다. 이 파일의 body 이름들은
#     `test/minted_seed_fixture.jl` 이 손으로 씨 뿌리고, 합성 레인 dict 의 미끼는 `reach` 가
#     아니라 `impl_name` 이다(Task 9). 그 둘 중 하나만 빠져도 이 파일의 거의 모든 절이
#     `verdict=deferred`/`unknown primitive` 로 떨어져 **배선을 한 줄도 안 태운 채** 빨개진다.
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

# 🔴 2026-09-03 (Task 10). 원시 표는 런 스코프이고 기본이 비어 있다(Task 2). 이 파일이 재는
#    것은 알파벳이 아니라 `enact_minted_decision!` 의 **배선**이고, 그 배선을 태우려면 body 의
#    이름이 표에서 해석돼야 한다. 근거·`register_minted_primitive!` 를 안 쓰는 이유는 그 파일에.
include(joinpath(@__DIR__, "..", "..", "test", "minted_seed_fixture.jl"))
seed_minted_fixture!()
check_minted_fixture()   # 🔴 F2: 오염된 픽스처로 아래를 돌리지 않는다

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

# 합성 레인 dict — `policy.jl::SYNTH_LANE_KEYS` 열셋 중 집행부가 읽는 것만 채운다.
# (그 키들이 전부 존재한다는 계약은 `test/synth_lane_keys_survive.jl` 이 지킨다.)
# 🔴 2026-09-03 (Task 10). 미끼가 `reach` 에서 `impl_name` 으로 옮겨졌다(Task 9) — 경계
#    (`enact_minted_decision!`)가 `impl_name === nothing` 하나로 막으므로, 그 값을 안 실은
#    픽스처는 전부 `lane=impl_name_nothing verdict=deferred` 로 떨어져 **이 파일이 재려던
#    배선을 한 줄도 안 태운다.** 기본값을 body 의 첫 이름에서 유도하고, "값을 안 실었다"
#    갈래를 겨냥할 때만 `impl_name = nothing` 을 명시한다.
#    ⚠️ `impl_code` 는 **안 싣는다.** 실으면 경계가 `register_minted_primitive!` 를 불러
#    `Core.eval` 로 이름을 CB 에 영구히 심는다 — 이 파일은 그 등록 경로가 아니라 그 뒤의
#    배선을 재고, 등록 경로는 `test/minted_end_to_end.jl` 이 잰다.
_sl(; reach = "composed", names = String[], params = Dict{String,Any}(), tool = "MintedTool",
      calls = nothing, impl_name = isempty(names) ? nothing : first(names)) =
    Dict{String,Any}("reach" => reach, "body_names" => names, "tool_name" => tool,
                     "impl_name" => impl_name,
                     "params" => params, "missing_primitive" => nothing,
                     # 🔴 삼상: 기본은 `nothing`("이 필드를 안 실었다")이지 `[]` 가 아니다.
                     "calls" => calls)

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
                                                           _dec(_sl(impl_name = nothing))))
        @test r3.handled === false && r3.verdict === :deferred
        @test occursin("lane=impl_name_nothing", out3)

        # ---- (1b) 🔴 그 줄이 **참인 말을 하고, 손에 든 증거를 버리지 않는다** ------------
        # 2026-08-30 최종 리뷰(IMPORTANT). 이 갈래는 `sl !== nothing` 이다 — 합성 레인이
        # **있다.** 그런데도 `reason=no synth lane on this decision` 을 찍고 있었다(거짓 진술),
        # 그리고 판별에 필요한 값 넷을 이미 손에 들고도 안 찍어서 T5 가 그 판별에 **유료 호출을
        # 한 번 더 썼다**. 그 넷이 "레인이 안 돌았다" · "돌다 터졌다" · "돌았고 expressible
        # 이라 안 쐈다" 를 가른다(spec §9-2 — 삼상을 이상으로 뭉개지 않는다).
        local sl4 = _sl(impl_name = nothing)
        sl4["synthesis_event"]  = true
        sl4["synthesis_ran"]    = false
        sl4["synthesis_error"]  = "boom: 합성기가 던졌다"
        sl4["tool_minted"]      = "disabled"
        r4, out4 = capture_out(() -> enact_minted_decision!(nothing, nothing, _dec(sl4)))
        @test occursin("lane=impl_name_nothing", out4)
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
            # 🔴 2026-09-03 (Task 10). 옛 판은 오염된 **레지스트리 파일 사본**
            #    (`PRIMITIVE_REGISTRY` + `_reset_primitive_table!`)으로 이 행을 만들었다.
            #    그 경로도 그 두 심볼도 삭제됐다(Task 2) — 런-스코프 표에 행 하나를 직접
            #    돌려 넣고 `finally` 로 픽스처를 되돌린다. 재는 성질은 안 바뀌었다.
        let saved = copy(CB.minted_table())
            try
                CB.minted_table()["release_pending_assignments"] = Dict{String,Any}(
                    "name" => "release_pending_assignments", "impl" => "process_schedule!",
                    "surface" => "sched", "harness_args" => ["env"],
                    "params" => Dict{String,Any}(), "reversible" => false)
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
            finally
                CB.minted_table()["release_pending_assignments"] =
                    saved["release_pending_assignments"]
            end
        end
    end

    @testset "(2d) 배정을 안 건드리는 body 뒤에는 안 돈다 — 그리고 그 사실이 기록된다" begin
        # 음성 대조. (2c) 와 **한 글자만 다르다**: surface 가 scene_tree 다.
            # 🔴 2026-09-03 (Task 10). 옛 판은 오염된 **레지스트리 파일 사본**
            #    (`PRIMITIVE_REGISTRY` + `_reset_primitive_table!`)으로 이 행을 만들었다.
            #    그 경로도 그 두 심볼도 삭제됐다(Task 2) — 런-스코프 표에 행 하나를 직접
            #    돌려 넣고 `finally` 로 픽스처를 되돌린다. 재는 성질은 안 바뀌었다.
        let saved = copy(CB.minted_table())
            try
                CB.minted_table()["restage_all_blocked"] = Dict{String,Any}(
                    "name" => "restage_all_blocked", "impl" => "process_schedule!",
                    "surface" => "scene_tree", "harness_args" => ["env"],
                    "params" => Dict{String,Any}(), "reversible" => false)
                local n0 = CB.RESOLVE_CALLS[]
                local sched = CB.OperatingSchedule()
                r, out = capture_out(() -> enact_minted_decision!(
                    sched, nothing, _dec(_sl(names = ["restage_all_blocked"]))))
                @test r.verdict === :admit
                @test CB.RESOLVE_CALLS[] == n0          # 🔴 한 번도 안 불렸다
                @test r.resolve === :not_needed_surface  # 🔴 조용히 안 부른 것이 아니라 기록됐다
                @test r.handled === true                 # 배정을 안 건드렸으니 폴백 억제는 그대로
                @test occursin("resolve=not_needed_surface", out)
            finally
                CB.minted_table()["restage_all_blocked"] = saved["restage_all_blocked"]
            end
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
            # 🔴 2026-09-03 (C1): `applied` 는 삼상이다 — `!r.applied` 는 `nothing` 에서
            #    TypeError 다. 함의는 `applied === true` 일 때만 뜻이 있다.
            @test r.applied !== true || r.world_maybe_dirty      # applied ⟹ dirty
            @test !r.partial || r.world_maybe_dirty      # partial ⟹ dirty
        end

        # 거절은 "부르지 않았다" 이다.
        # 🔴 2026-09-03 (Task 10). `applied` 는 `false` 가 아니라 **`nothing`("못 쟀다")** 이다 —
        #    한 발도 안 굴렸으니 잰 것이 없다(`_r` 의 기본값, C1/Task 9 F6-4). `false` 로
        #    적으면 "쟀는데 적응이 0 이었다" 는 다른 주장이 된다.
        r, out = capture_out(() -> enact_minted_decision!(THROW_ENV, nothing,
                                                          _dec(_sl(names = ["teleport_the_build"]))))
        @test r.verdict === :reject
        @test r.applied === nothing && r.partial === false && r.world_maybe_dirty === false
        @test r.handled === false
        @test occursin("NOT handled", out)
    end

    # -------------------------------------------------------------------------------------
    @testset "(4b) 🔴 옛 등식 `applied || partial` 은 거짓이다 — 닿는 fixture 로 못박는다" begin
        # 필요한 것은 "세계는 만졌는데 노린 적응은 아니다" 인 status 에 **실제로 닿는** 판이다.
        # `:residual_blocked` 는 진짜 기하가 있어야 나오므로 `test/minted_tool_enacts.jl` (13-h)
        # 의 값싼 대체물을 그대로 쓴다: `:unreadable_return` 은 `_step_applied=false`(못 쟀으니
        # 성공으로 안 센다) · `_step_touched_world=true`(못 쟀으니 깨끗하다고도 못 한다) 다.
        # 🔴 2026-09-03 (Task 10). 오염된 레지스트리 **파일 사본** 대신 런-스코프 표에 행 하나를
        #    직접 돌려 넣는다(그 파일 경로도 `_reset_primitive_table!` 도 삭제됐다).
        #    `restage_all_blocked` 의 impl 만 "반환 모양을 못 읽는" 함수로 돌린다.
        let saved = copy(CB.minted_table())
            try
                CB.minted_table()["restage_all_blocked"] = Dict{String,Any}(
                    "name" => "restage_all_blocked", "impl" => "process_schedule!",
                    "surface" => "physical", "harness_args" => ["env"],
                    "params" => Dict{String,Any}(), "reversible" => false)
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
                @test r.world_maybe_dirty !== (r.applied === true || r.partial)   # C1: 삼상 안전
                # 그리고 그 참이 실제로 힘을 갖는다 — 폴백이 억제된다.
                @test r.resume === :not_needed_self
                @test r.handled === true
                @test occursin("world_maybe_dirty=true", out)
                @test occursin("applied=false", out)
                @test occursin("handled=true", out)
            finally
                CB.minted_table()["restage_all_blocked"] = saved["restage_all_blocked"]
            end
        end
        # 🔴 2026-09-03 (Task 10). 옛 판은 여기서 `length(CB.PRIMITIVE_TABLE()) == 19` 로
        #    "원래 레지스트리로 돌아왔다" 를 확인했다. 그 심볼도 그 파일도 없다 — 오늘
        #    `finally` 가 행 하나를 제자리에 돌려놓고, 그 복구를 이렇게 잰다.
        @test CB.resolve_primitive("restage_all_blocked").impl === CB.restage_all_blocked!
    end

    # -------------------------------------------------------------------------------------
    # 🔴 2026-09-03 (Task 10) — **명제 (5) 는 통째로 삭제됐다. 고쳐 남기면 안 되는 자리다.**
    #
    # 그것이 재던 것: "레지스트리 파일이 없어 `PRIMITIVE_TABLE` 이 `error(...)` 를 내도 그
    # 예외가 `enact_minted_decision!` 밖으로 안 샌다". 그 전제는 두 겹으로 사라졌다 —
    # 레지스트리 파일이 없고(Task 2), `resolve_primitive` 는 이제 **던지지 않는다**(빈 표는
    # 그냥 `nothing` → `:reject`).
    #
    # 🔴 그리고 이 자리는 **조용한 항진(vacuous pass)의 실증 사례**다. 전제 줄이
    #   `@test_throws Exception CB.PRIMITIVE_TABLE()` 인데 `UndefVarError <: Exception` 이라
    #   심볼이 아예 없어도 **통과한다**(2026-09-03 직접 실측: `isdefined(CB,:PRIMITIVE_TABLE)
    #   = false` 인데 그 단언 하나짜리 testset 이 `1 pass`). 오늘 이 절이 초록이 아닌 유일한
    #   이유는 바로 윗줄 `CB._reset_primitive_table!()` 이 먼저 죽어서다 — 그 줄만 지우고
    #   전제를 남기면 **커버리지 0 인 자리에 초록 체크가 생긴다.** 그래서 줄 단위 수리를
    #   하지 않고 절을 통째로 지웠다.
    #
    # 남아 있는 성질("집행부는 던지지 않는다")은 다른 자리가 이미 잰다: `enact.jl` 의 본체가
    # 통째로 `try` 안이고, 미지 원시는 (4) 의 `teleport_the_build` 판이 `:reject` 로 잰다.

    # -------------------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------------------
    # 🔴 2026-09-03 (Task 10) — 옛 제목은 "(9) unsanctioned 도 폴백을 건너뛴다" 였다.
    #    `:admit_unsanctioned` verdict 자체가 사라졌다(Task 9): 그것은 "모델이 조합에
    #    실패했다고 신고했는데 body 는 있다" 를 재던 구분인데 **조합 단계가 없어졌다**(D8).
    #    그래서 verdict 를 재던 단언 넷은 잴 대상이 없어졌다(a).
    #    🔴 그러나 이 절의 **본체**는 verdict 가 아니라 `handled` 의 나머지 세 연언지가
    #    "같은 body·같은 던지는 지점, env 만 다른 세 판" 으로 하나도 안 풀린다는 것이고,
    #    그것은 그대로 살아 있는 계약이다. verdict 자리만 오늘의 값으로 바꿔 유지한다.
    @testset "(9) 자기신고와 무관하게 handled 는 세계가 정한다" begin
        # 🔴 판정의 근거는 자기신고가 아니라 세계다. `reach` 를 무엇으로 신고하든 결과가 같다.
        local env = throw_env_with_live_cache()
        r, out = capture_out(() -> enact_minted_decision!(
            env, nothing, _dec(_sl(reach = "needs_primitive", names = BODY))))
        # 전제부터 못박는다 — 이 판이 정말 "굴렸고 던졌고 재개는 성공했다" 인가.
        @test r.verdict === :admit
        @test r.partial === true
        @test r.world_maybe_dirty === true
        @test r.resume === :issued
        @test r.handled === true                       # 🔴 D3
        @test occursin("verdict=admit", out)
        # 🔴 `reach` 는 이제 경계 키가 아니다 — 그 값이 로그로 새면 죽은 어휘가 되살아난다.
        @test !occursin("reach=", out)
        @test !occursin("NOT handled", out)

        # 음성 대조: 같은 판을 `reach` 없이 보내도 **바이트 동일**이다(자기신고가 안 읽힌다).
        local env_b = throw_env_with_live_cache()
        rb, _ = capture_out(() -> enact_minted_decision!(env_b, nothing, _dec(_sl(names = BODY))))
        @test (rb.verdict, rb.partial, rb.resume, rb.handled) ==
              (r.verdict, r.partial, r.resume, r.handled)

        # 🔴 나머지 세 연언지는 하나도 안 풀렸다. 같은 body·같은 던지는 지점, env 만 다르다 —
        #    재개가 실패하면 폴백이 돈다.
        r2, out2 = capture_out(() -> enact_minted_decision!(
            THROW_ENV, nothing, _dec(_sl(names = BODY))))
        @test r2.verdict === :admit
        @test r2.resume === :failed
        @test r2.handled === false
        @test occursin("NOT handled", out2)

        # 🔴 그리고 세계를 안 건드린 조용한 성공도 그대로다 — verdict 는 같고 handled 는 거짓.
        r3, out3 = capture_out(() -> enact_minted_decision!(
            QUIET_ENV, nothing, _dec(_sl(names = BODY))))
        @test r3.verdict === :admit
        @test r3.world_maybe_dirty === false
        @test r3.handled === false
        @test occursin("NOT handled", out3)

        # 🔴 `impl_name === nothing` 은 여전히 조기 반환이다 — "못 쟀다"를 "아니라고 했다"로
        #    접지 않는다. (미끼가 `reach` 에서 여기로 옮겨졌다, Task 9.)
        r4, out4 = capture_out(() -> enact_minted_decision!(
            env, nothing, _dec(_sl(impl_name = nothing, names = BODY))))
        @test r4.verdict === :deferred && r4.handled === false
        @test occursin("lane=impl_name_nothing", out4)
    end

    # -------------------------------------------------------------------------------------
    @testset "(10) `handled` 의 첫 연언지 — 집행 계열 verdict 하나만 통과한다" begin
        # 🔴 **왜 이 시험이 있는가 — 이 절을 "도달 불가한 판을 재는 죽은 시험" 이라고 지우지 마라.**
        #    T7 의 변이시험 실측: `minted_handled` 에서 첫 연언지(`CB.minted_handled_verdict_ok`)를
        #    통째로 지워도 이 파일은 154/154 초록이었다. 오늘 `enact_minted!` 의 `:reject` 반환이
        #    전부 `_r(...)` 를 kwargs 없이 부르고 `_r` 이 `world_maybe_dirty = touched || partial`
        #    을 **둘 다 기본 `false`** 로 지으며, `:deferred` 는 `enact.jl` 의 조기 반환이라 식에
        #    도달조차 안 한다 — 즉 **둘째 연언지가 첫째를 오늘 완전히 가린다**.
        #    ⟹ 첫 연언지는 구멍이 아니라 오늘 항진적으로 잉여이고, 그것을 지키는 방어선이 `_r` 의
        #    **기본 인자 하나**뿐이다. 누가 그 기본값을 바꾸거나 `:reject` 경로에서 `partial=true`
        #    를 넘기는 날 첫 연언지가 유일한 방어선이 된다. 이 절은 **그날을 위한 것**이다.
        #
        # 🔴 나머지 세 연언지는 전부 통과값으로 고정한다 — verdict 하나만 움직여 첫 연언지를
        #    고립시키는 것이 이 절의 전부다(`resolve = :resolved` 는 `minted_tool.jl` 이 실제로
        #    쓰는 성공 태그이고 `resolve_failed` 셋 중 하나가 아니다).
        _verdict_row(v) = (verdict = v, world_maybe_dirty = true,
                           resume = :issued, resolve = :resolved)

        # 🔴 대조 팔. 이것이 없으면 아래 세 줄은 "함수가 늘 false 를 돌려준다" 로도 통과한다(공허).
        @test minted_handled(_verdict_row(:admit)) === true

        # 집행 계열이 아닌 verdict 는 나머지 셋이 다 통과해도 `handled` 가 아니다.
        @test minted_handled(_verdict_row(:reject)) === false
        @test minted_handled(_verdict_row(:deferred)) === false
        # 🔴 2026-09-03 (Task 10). 옛 판은 `:admit_unsanctioned` 를 **통과 팔**로 썼고, 그 한 줄이
        #    "`ENACTED_VERDICTS` 가 다시 `:admit` 하나로 좁아지는 회귀를 잡는다" 고 적혀 있었다.
        #    그 좁힘은 회귀가 아니라 **설계 결정으로 일어났다**(Task 9, D8 — 조합 단계가 없어져
        #    "허락 없이 굴렸다" 라는 사건 자체가 없다). 그래서 기대를 뒤집는다: 사라진 verdict 가
        #    되살아나면 여기서 빨개진다. 정본은 `CB.ENACTED_VERDICTS` 이고 크기를 여기 안 적는다.
        @test minted_handled(_verdict_row(:admit_unsanctioned)) === false
        @test :admit_unsanctioned ∉ CB.ENACTED_VERDICTS
    end
end

    # -------------------------------------------------------------------------------------
    @testset "(9) 🔴 인자 출처가 [minted] 줄에 찍힌다 (Step 5, B1)" begin
        # 없으면 유료 런의 로그로 "calls 로 값이 도착해 굴렀다" 와 "calls 가 없어 옛 params
        # 경로로 떨어져 인자 없이 굴렀다" 를 구별할 수 없다 — B1 을 배선한 목적이 그 구별이다.
        _, out_c = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
            _dec(_sl(names = BODY,
                     calls = [Dict{String,Any}("primitive" => "translate_whole_build",
                                               "args" => Dict{String,Any}())]))))
        @test occursin("args_from=calls", out_c)
        @test occursin("n_calls=1", out_c)

        r_p, out_p = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
                                          _dec(_sl(names = BODY))))
        @test occursin("args_from=params", out_p)
        @test occursin("n_calls=n/a", out_p)          # 🔴 "0" 이 아니다 — 못 쟀다
        @test r_p.args_from === :params                # 반환값에도 실린다(로그만이 아니다)

        # 조기 반환(합성 레인 없음)에서도 줄은 찍히고, 그 자리는 "도달 못 했다" 다.
        _, out_n = capture_out(() -> enact_minted_decision!(nothing, nothing,
                                          (macro_name = "NOOP",)))
        @test occursin("args_from=n/a", out_n)
    end

    # -------------------------------------------------------------------------------------
    @testset "(10) 🔴 발화한 판의 [minted] 줄이 agent-3 의 답을 싣는다" begin
        # 2026-09-03 라이브 실측이 계기: mild 보드에서 합성이 **발화했는데**
        # `reason=empty body` 로 거절됐고, agent-3 이 무엇을 냈는지는 **어디에도 안 남았다** —
        # `lane=present` 분기가 그것을 안 찍고, 스트림 jsonl 에는 합성 필드가 없고, 서비스는
        # 기록을 파일로 안 썼다. 값은 이미 `SYNTH_LANE_KEYS` 로 도착해 있었다 — 관측면만 없었다.
        #
        # 🔴 2026-09-03 (Task 10). 재던 필드가 옮겨졌다. `missing_primitive` 는 agent-3 의
        #    출력 필드가 아니게 됐고(`WriteToolImpl` 이 선언하지 않는다 — 라이브 판에서는
        #    언제나 `""`), Task 9 가 그 인용을 로그에서 지웠다. 오늘 같은 자리를 나르는 것은
        #    `registered`/`impl_rejected_why`(등록이 됐나, 안 됐으면 왜)와 `n_body_names` 다.
        #    ⟹ 재는 성질("발화했는데 거절된 판이 왜 그랬는지가 줄에 남는가")은 그대로다.
        _, out = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
            _dec(Dict{String,Any}("impl_name" => "adjust_tasks!", "body_names" => String[],
                                  "tool_name" => "DynamicTaskAdjustment",
                                  "params" => Dict{String,Any}(), "calls" => nothing))))
        @test occursin("tool=DynamicTaskAdjustment", out)
        @test occursin("n_body_names=0", out)
        @test occursin("verdict=reject", out)          # 빈 body 는 거절이다
        # 🔴 죽은 어휘가 로그로 되살아나지 않는다.
        @test !occursin("missing_primitive=", out)
        @test !occursin("reach=", out)
    end

    # -------------------------------------------------------------------------------------
    # 🔴 F6(2) (2026-09-03 fix round 1). 앞 절은 `occursin("registered=", out)` 이었다 —
    #    **부분문자열 존재**만 보므로 `registered=true` 도 `registered=false` 도 똑같이
    #    통과했다. 그런데 그 자리의 주석은 삼상 성질을 주장하고 있었다. `registered` 는
    #    `Union{Nothing,Bool}` 이고 로그에 **세 모양**으로 찍힌다. 값을 직접 가른다.
    #
    #    🔴 `false` 는 **두 사건을 덮는다** — "등록할 코드가 없어 시도조차 안 했다" 와
    #    "시도했는데 규약 위반으로 거절됐다". 둘을 가르는 것은 `impl_rejected_why` 이고,
    #    그래서 두 필드를 **짝으로** 읽어야 세 사건이 일대일이 된다.
    @testset "(11) 🔴 registered 는 삼상이고 로그가 그것을 접지 않는다" begin
        # (a) 등록을 **시도조차 안 했다** — `impl_code` 가 없다. `false` + 사유 없음.
        _, out_a = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
                                        _dec(_sl(names = BODY))))
        @test occursin("registered=false", out_a)
        @test occursin("impl_rejected_why=n/a", out_a)

        # (b) 조기 반환(`impl_name` 이 없다)도 같은 모양이다 — 확정된 `false` 다.
        r_b, out_b = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
                                          _dec(_sl(impl_name = nothing, names = BODY))))
        @test r_b.registered === false
        @test occursin("registered=false", out_b) && occursin("impl_rejected_why=n/a", out_b)

        # (c) 🔴 **시도했는데 거절됐다** — 같은 `false` 인데 사유가 붙는다. 이 짝이 (a)/(b) 와
        #     (c) 를 가르는 전부다. ⚠️ `check_impl_conventions` 는 `Core.eval` **앞**에서
        #     거절하므로 이 픽스처는 CB 에 아무 이름도 안 심는다(이 파일이 등록 경로를
        #     피하는 이유 그대로다 — 규약 위반은 그 경로에 안 들어간다).
        #     이름은 픽스처에 없는 것을 쓴다 — 등록이 **거절되므로** 표에 안 들어가고,
        #     따라서 뒤 절·뒤 파일이 이 이름을 물려받지 않는다.
        local bad = _sl(names = ["t10_wiring_bad_probe!"], impl_name = "t10_wiring_bad_probe!")
        bad["impl_code"] = "function t10_wiring_bad_probe!(env, other; k = 1)\n    return :ok\nend\n"
        r_c, out_c = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing, _dec(bad)))
        @test r_c.registered === false
        @test r_c.impl_rejected_why !== nothing
        @test occursin("reject:impl_positional_args_must_be_exactly_env", r_c.impl_rejected_why)
        @test occursin("registered=false", out_c)
        @test !occursin("impl_rejected_why=n/a", out_c)   # 🔴 여기서 (a)/(b) 와 갈린다
        @test r_c.verdict === :reject && isempty(r_c.steps)   # 등록 실패는 집행을 안 시도한다
        @test !haskey(CB.minted_table(), "t10_wiring_bad_probe!")   # 표를 안 건드렸다
        @test !isdefined(CB, Symbol("t10_wiring_bad_probe!"))       # eval 도 안 돌았다

        # (d) 🔴 `nothing`("몰라서 못 쟀다")은 `n/a` 로 찍힌다 — `false` 와 **다른 글자**여야
        #     한다. 그 갈래는 catch 경로(등록 판정에 닿기 전에 던진다)이고 이 파일의 순수 함수
        #     픽스처로는 못 만든다. 그래서 여기서는 **확정된 `false` 를 "못 쟀다" 로 적지
        #     않는다**는 것만 잰다(아래 두 줄). 그 경로 자체는 `test/minted_end_to_end.jl` (3)
        #     이 값으로 잰다.
        # ⚠️ 2026-09-03 fix round 2 (F11): 이 자리에 `@test string(false) != "n/a"` 가 있었다 —
        #    **실패할 수 없는 단언**이고(Julia 의 `string` 에 대한 사실이지 렌더러에 대한
        #    사실이 아니다) 주석은 렌더러 성질을 주장하고 있었다. 하필 "약한 검사가 너무
        #    약했다" 를 고치려고 만든 절 안이라 지웠다. 하중은 아래 두 줄이 전부 진다.
        @test !occursin("registered=n/a", out_a)   # 확정된 false 를 "못 쟀다" 로 적지 않는다
        @test !occursin("registered=nothing", out_a)

        # (e) `registered=true` 는 `Core.eval` 이 실제로 성공해야 나오고, 그것은 CB 에 이름을
        #     **영구히** 심는다(세션당 한 번만 안전). 이 파일은 순수 함수 게이트라 그 경로를
        #     일부러 안 태운다 — `test/minted_end_to_end.jl` (1) 이 그것을 잰다.
        #     여기서는 이 파일의 픽스처가 그 경로에 **안 들어갔다**는 것만 확인한다.
        @test !occursin("registered=true", out_a)

        # 양성 대조: body 가 있는 판은 같은 자리에 그 수가 찍힌다(빈-통과 방지).
        _, out2 = capture_out(() -> enact_minted_decision!(QUIET_ENV, nothing,
                                        _dec(_sl(names = BODY))))
        @test occursin("n_body_names=1", out2)
    end

end # module
