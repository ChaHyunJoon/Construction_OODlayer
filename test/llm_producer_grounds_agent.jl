# =============================================================================
# 🔴 `llm_producer`(`DEMO_LLM=1`) 가 `enact_target` 을 **우회하지 않는다**.
#
# 무엇이 결함이었나 (2026-08-29 실측)
# -----------------------------------
# `render_demo.jl` 에는 producer 가 둘 있고 `set_respec_producer!` 가 `DEMO_LLM` 으로 하나를
# 고른다. T2b 에서 `policy_producer`(기본, `DEMO_LLM=0`)는 `enact_target` 뒤로 들어갔지만
# `llm_producer` 는 **안 들어갔다** — 그 레인은 `CB.llm_to_proposal` 이 돌려준 제안을 집행
# dispatcher 에 **그대로** 넘겼다. 그래서 그 판에서 LLM 이 고른 agent 는
#
#   · 접지 없이            — `_open_agent_pairs`(모델에게 **보여 준** 집합)와 대조된 적이 없다
#   · 출처 검사 없이       — 집행되는 팔과 인자의 팔이 같은지 안 물었다
#   · 강제/이탈 거절 없이  — `DEMO_FORCE_MACRO` 판에서도 LLM 의 agent 가 그대로 실렸다
#
# 세계에 닿았다. 한 레포에 엔진이 둘인데 한쪽만 문을 지나면 그 문은 없는 것과 같다.
#
# 🔴 **"`_default_id_resolver` 가 이미 접지한다" 는 반론이 이 파일의 (1) 에서 실측으로 죽는다.**
# 그 함수(`replan.jl:1687`)는 로봇 열거 **앞에** 스케줄 정점 id 공간 전체를 먼저 훑고
# `get_vtx_id` 를 그대로 돌려준다. 즉 **노드 id 문자열이 agent 자리를 통과한다** — 그리고
# `ReplaceAgent.agent` 의 필드 타입은 `AbstractID` 라(`spec_dsl.jl:177`) 그 값이 제약에
# **실제로 들어간다**. 리뷰어가 "세 번째 손복사 열거" 라고 부른 결함의 실체가 이것이다.
#
# 이 게이트가 재는 것
# -------------------
#  (1) 우회로가 **실재했다** — 열거 밖 문자열을 `_default_id_resolver` 는 받고 `resolve_agent_id`
#      는 거절한다. 이 음성 대조가 없으면 아래 검사들이 항진명제일 수 있다.
#  (2) 🔴 열거 밖 agent 를 담은 LLM 제안은 **집행에 닿지 않는다** — 폴백 제안이 `truth.robot`
#      을 가리킨다.
#  (3) 양성 대조 — 접지된 agent 는 **그대로 통과한다**(문이 전부 막는 문이면 아무것도 안 잰다).
#  (4) 🔴 강제 판(`DEMO_FORCE_MACRO`)에서 LLM 의 agent 를 거절한다. 같은 팔로 강제한 판에서는
#      **거절하지 않는다**(항목 4b 의 과잉거부 회귀 방지).
#  (5) 이탈 판(라우터의 `deviated`/`deviate_from`)에서 거절한다.
#  (6) 🔴 폴백은 **기록된다** — `source`·`tool_agent`(원문)·`reject`, 그리고 `log_enact` 한 줄.
#  (7) 🔴 `render_demo.jl` 의 `llm_producer` 가 이 함수에 **위임한다**(소스 텍스트).
#
# ⚠️ 서비스를 **한 번도 안 부른다.** `127.0.0.1:8000`(Anthropic propose) 도 `:8077`(DSPy) 도
# 요청 0건이다 — LLM 이 내는 산출물(`RespecProposal`)을 직접 지어 생산 함수에 먹인다.
#
# 왜 (7) 이 소스 텍스트인가: `render_demo.jl` 은 최상위에서 데모를 통째로 렌더하는 **스크립트**라
# 어떤 테스트도 include 할 수 없다. (2)~(6) 이 `llm_enact_target` 의 본체를 지키고, (7) 은
# `llm_producer` 가 그 함수를 **부른다**는 두 줄만 지킨다 — `test/enact_uses_llm_agent.jl` (10)
# 이 `run_demo.jl` 에 대해 쓰는 것과 같은 수법이고 같은 한계다.
#
# 변이시험(실제로 돌려 RED 를 확인한 것)은 태스크 보고서에 출력을 붙였다.
# =============================================================================

module LLMProducerGroundsAgent

using Test
using ConstructionBots
const CB = ConstructionBots
import Random

const REPO = normpath(joinpath(@__DIR__, ".."))

isdefined(CB, :BatteryTruth) || CB.include(joinpath(REPO, "src", "navigator", "navigator.jl"))

# 🔴 생산 코드를 **실제로** 태운다. 둘 다 최상위 부작용이 없다(policy.jl 은 const·@info 뿐이고
# 아무 HTTP 요청도 안 낸다). `macro_to_proposal`·`_macro_label` 은 `llm_producer` 가 폴백
# 제안을 다시 지을 때 쓰는 바로 그 함수들이므로 여기서도 **같은 것**을 부른다.
include(joinpath(REPO, "tools", "monitor", "policy.jl"))
include(joinpath(REPO, "tools", "monitor", "enact.jl"))

const TENV = CB.run_lego_demo(; ldraw_file = "colored_8x8.ldr",
                                project_name = "llm_producer_grounds_agent",
                                num_robots = 4, assignment_mode = :greedy,
                                n_spare_per_pool = 2,
                                open_animation_at_end = false, save_animation = false,
                                write_results = false, return_env_before_sim = true,
                                rng = Random.MersenneTwister(1))

const _MAC = "Replace"

# LLM 레인이 실제로 넘기는 것과 같은 모양의 제안 하나(첫 제약의 `agent` 가 집행이 읽는 자리다).
_prop(agent) = CB.RespecProposal(CB.ConstraintSpec[CB.ReplaceAgent(agent, 0.0)],
                                 "llm rationale", "BatteryTruth")

@testset "llm_producer 가 enact_target 을 우회하지 않는다 (Plan B / T2c)" begin

local descs = CB.open_agent_descriptors(TENV)
local A = CB.resolve_agent_id(TENV, descs[1]["id"])
local B = CB.resolve_agent_id(TENV, descs[2]["id"])
local truth = CB.BatteryTruth(A, 0.1)

# 🔴 **열거 밖 참조를 손으로 적지 않는다** — `_default_id_resolver` 가 받아들이는 스케줄 정점
# id 중 `resolve_agent_id` 가 거절하는 첫 번째를 **유도한다**. 리터럴로 적으면 그 문자열이
# 우연히 두 열거 어디에도 없는 값일 수 있어 (1) 이 항진명제가 된다.
local ghost_id = nothing
for v in CB.Graphs.vertices(TENV.sched)
    local s = string(CB.get_vtx_id(TENV.sched, v))
    CB.resolve_agent_id(TENV, s) === nothing || continue
    ghost_id = CB.get_vtx_id(TENV.sched, v)
    break
end

@testset "(1) 우회로가 실재했다 — 두 열거가 갈린다" begin
    @test A !== nothing && B !== nothing && A != B
    @test ghost_id !== nothing
    local gs = string(ghost_id)
    # 모델에게 보여 준 집합은 이 문자열을 **안 받는다**.
    @test CB.resolve_agent_id(TENV, gs) === nothing
    # 그런데 LLM 레인의 파서가 쓰는 해석기는 **받는다** — 던지지 않고 그 id 를 돌려준다.
    local hit = CB._default_id_resolver(TENV, gs)
    @test hit !== nothing
    @test string(hit) == gs
    # 그리고 그 값이 제약에 **실제로 들어간다**(`agent::AbstractID`).
    @test proposal_agent(_prop(ghost_id)) == ghost_id
end

@testset "(2) 🔴 열거 밖 agent 는 집행에 닿지 않는다" begin
    local prop = _prop(ghost_id)
    local tgt  = llm_enact_target(TENV, truth, prop, _MAC)
    @test tgt.source == "truth"          # tool 이 아니다
    @test tgt.agent == truth.robot       # 폴백 대상
    @test tgt.agent != ghost_id
    # 🔴 사유는 **접지 판정 그대로** 나른다: `enact_target` 은 `ground_tool_args` 판정을 먼저
    # 보고(규칙 1) 거기서 걸리므로 `"verify:" * 판정` 이다. 두 층(판정 층 / 해석기 층)이
    # 사유 문자열에서 구분된다 — 하나로 뭉개면 진단이 사라진다.
    @test tgt.verify == "reject:ungrounded_agent"
    @test tgt.reject == "verify:reject:ungrounded_agent"
    # 🔴 그리고 `llm_producer` 가 다시 짓는 제안이 가리키는 것이 그 폴백 대상이다.
    # (생산 코드와 **같은 함수**로 짓는다 — `macro_to_proposal`.)
    local fixed = macro_to_proposal(truth, _MAC; env = TENV, agent = tgt.agent)
    @test proposal_agent(fixed) == truth.robot
    @test proposal_agent(fixed) != ghost_id
    @test fixed.constraints[1] isa CB.ReplaceAgent   # 결정(팔)은 안 지워진다 (spec §4-1)
end

@testset "(3) 양성 대조 — 접지된 agent 는 그대로 통과한다" begin
    # B 는 truth.robot(A) 이 **아니다** — 두 값이 같으면 이 검사는 아무것도 안 잰다.
    local tgt = llm_enact_target(TENV, truth, _prop(B), _MAC)
    @test tgt.source == "tool"
    @test tgt.agent == B
    @test tgt.agent != truth.robot
    @test tgt.reject === nothing
    @test tgt.verify == "admit"
end

@testset "(4) 🔴 강제 판에서 LLM 의 agent 를 거절한다" begin
    # 팔이 실제로 갈아 끼워진 판: 강제 팔 != 집행되는 팔.
    local tgt = withenv("DEMO_FORCE_MACRO" => "SwapBattery") do
        llm_enact_target(TENV, truth, _prop(B), _MAC)
    end
    @test tgt.source == "truth"
    @test tgt.agent == truth.robot
    @test tgt.reject == "arm_overridden"
    # ⚠️ 과잉거부 회귀 방지(수정 라운드 항목 4b): 강제 팔이 집행되는 팔과 **같으면** 그 판의
    # tool 인자는 그 팔의 것이므로 거절할 이유가 없다.
    local same = withenv("DEMO_FORCE_MACRO" => _MAC) do
        llm_enact_target(TENV, truth, _prop(B), _MAC)
    end
    @test same.source == "tool"
    @test same.agent == B
end

@testset "(5) 이탈 판에서 LLM 의 agent 를 거절한다" begin
    # `policy.jl:1524` 가 이미 "팔이 바뀌었나" 로 계산해 둔 값.
    local dev = llm_enact_target(TENV, truth, _prop(B), _MAC;
                                 router = Dict{String,Any}("deviated" => true))
    @test dev.source == "truth"
    @test dev.reject == "arm_overridden"
    # override 이전 팔이 집행되는 팔과 다르다.
    local from = llm_enact_target(TENV, truth, _prop(B), _MAC;
                                  router = Dict{String,Any}("deviate_from" => "SwapBattery"))
    @test from.reject == "arm_overridden"
    # 게이트는 걸렸지만 팔은 안 바뀐 판 — 거절하지 않는다(항목 4b).
    local nochange = llm_enact_target(TENV, truth, _prop(B), _MAC;
                                      router = Dict{String,Any}("deviate_from" => _MAC,
                                                                "deviated" => false))
    @test nochange.source == "tool"
    @test nochange.agent == B
end

@testset "(6) 🔴 폴백은 기록된다 — 조용히 떨어지지 않는다" begin
    local tgt = llm_enact_target(TENV, truth, _prop(ghost_id), _MAC)
    # 원문 문자열이 **살아 있다**: "LLM 이 무엇을 골랐나" 와 "무엇이 집행됐나" 가 둘 다 읽힌다.
    @test tgt.tool_agent == string(ghost_id)
    @test tgt.reject !== nothing
    @test tgt.source != "tool"
    # 그리고 stdout 한 줄에 그 셋이 전부 실린다(`policy_producer` 와 **같은 함수**).
    local line = mktemp() do path, io
        redirect_stdout(() -> log_enact(tgt), io)
        flush(io)
        read(path, String)
    end
    @test occursin("[enact]", line)
    @test occursin("source=truth", line)
    @test occursin("reject=verify:reject:ungrounded_agent", line)
    @test occursin("tool_agent=" * string(ghost_id), line)
    @test occursin("target=" * string(truth.robot), line)
end

@testset "(7) 🔴 `render_demo.jl` 의 `llm_producer` 가 위임한다" begin
    local src = read(joinpath(REPO, "tools", "monitor", "render_demo.jl"), String)
    local i = findfirst("function llm_producer(", src)
    @test i !== nothing
    local j = findnext("\nend\n", src, last(i))
    @test j !== nothing
    local body = src[first(i):last(j)]
    # 게이트를 **부른다**. 규칙을 손으로 다시 쓰지 않는다.
    @test occursin("llm_enact_target(env, truth, prop, mac)", body)
    @test occursin("log_enact(tgt)", body)
    # 거절이면 폴백 제안을 `policy_producer` 와 **같은 함수**로 다시 짓는다.
    @test occursin("macro_to_proposal(truth, mac; env = env, agent = tgt.agent)", body)
    # 폴백 사유가 **영속되는 기록**(capture!)에 실린다.
    @test occursin("enact fallback: ", body)
    # 🔴 두 producer 가 **같은** 로그 함수를 쓴다 — 규칙(그리고 문구)의 복사본이 없다.
    @test occursin("log_enact(_tgt)", src)
    @test !occursin("println(\"[enact] target=", src)
    # 🔴 그리고 이 레인은 `enact_target` 을 **직접** 부르지 않는다 — 감싸개를 우회하는 두 번째
    # 호출부가 생기면 여기서 빨개진다(감싸개가 tool 레인 모양을 짓는 자리이기 때문이다).
    @test isempty(collect(eachmatch(r"(?<![A-Za-z_])enact_target\(", body)))
end

end # testset

end # module
