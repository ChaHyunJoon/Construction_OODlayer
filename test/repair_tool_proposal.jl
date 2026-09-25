# =============================================================================
# test/repair_tool_proposal.jl — T5 제안 문(門) 게이트 (단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_tool_proposal.jl
#
# [1]–[4] 은 ConstructionBots 를 **싣기 전에** 돈다 — supervisor 쪽 문이 CB 없이 서는지가 그 자체로 시험이다.
# [5] 는 CB 를 실은 뒤 현행 등록 규약(`check_impl_conventions`) 재사용을 본다.
# =============================================================================
using Test, JSON3
include(joinpath(@__DIR__, "..", "src", "verification", "tool_proposal.jl"))
const R = RepairTypes
const G = ToolProposalGate

const BASE = R.read_json(joinpath(@__DIR__, "fixtures", "repair_verification", "contracts", "corpus.json"))["bases"]["proposal"]
prop(code; name = "balance_idle_carriers!", kw...) = merge(deepcopy(BASE),
    Dict{String,Any}("impl_name" => name, "tool_name" => chop(name), "impl_code" => code,
                     "calls" => [Dict{String,Any}("primitive" => name, "args" => Dict{String,Any}())]),
    Dict{String,Any}(String(k) => v for (k, v) in kw))
gate(raw; level = :all) = G.gate_proposal(raw; checkpoint_id = "cp-1", ablation_level = level)

# 고정 template 이 아닌 일반 도구: 지역 helper · 반복 · 조건 분기 · 계산 · 세계 API 조합.
const NOVEL = """
function balance_idle_carriers!(env; max_moves::Int = 3)
    score(v) = length(string(v)) + (v in env.cache.closed_set ? 100 : 0)
    moved = 0
    for v in sort(collect(env.cache.active_set); by = score)
        moved >= max_moves && break
        if v in env.cache.closed_set
            continue
        end
        moved += 1
    end
    return (; status = moved > 0 ? :moved : :nothing_to_do, moved = moved)
end"""

@testset "T5 ToolProposal gate" begin
    @testset "[0] supervisor 문은 CB 없이 선다" begin
        @test !isdefined(Main, :ConstructionBots)
        @test :restage_all_blocked! in G.AblationNames.ablated_names(:all)   # 같은 파일(repair_ablation.jl)을 실었다
    end

    @testset "[1] 일반 코드 수용 — helper·반복·조건·계산, 도구 이름 목록 없음" begin
        g = gate(prop(NOVEL))
        @test g.report.verdict === :accept
        @test g.static_only === true                       # 정적 통과는 효과 증명이 아니다
        @test isempty(g.report.adapter_calls)
        # 이름이 전혀 다른 새 도구도 같은 문을 지난다(메뉴가 없다)
        other = replace(NOVEL, "balance_idle_carriers!" => "stagger_team_departures!")
        @test gate(prop(other; name = "stagger_team_departures!")).report.verdict === :accept
        # engine 진행 호출은 거절이 아니라 adapter 중재 대상
        stepper = "function wait_then_check!(env)\n    step_environment!(env)\n    return :ok\nend"
        gs = gate(prop(stepper; name = "wait_then_check!"))
        @test gs.report.verdict === :accept && gs.report.adapter_calls == [:step_environment!]
    end

    @testset "[2] 존 복구 base ablation — 레벨을 따른다, 사유는 등록 규약과 같은 문구" begin
        body = "function relocate_it!(env)\n    restage_all_blocked!(env)\n    return :ok\nend"
        g = gate(prop(body; name = "relocate_it!"); level = :all)
        @test g.report.verdict === :reject
        @test g.report.reasons == ["reject:ablated_primitive:restage_all_blocked! — this function is not available in this world"]
        @test gate(prop(body; name = "relocate_it!"); level = :none).report.verdict === :accept
        # 모듈이 변수에 담겨도(넓은 보행 규칙) · 가드 기계장치 이름도
        indirect = "function relocate_it!(env)\n    m = parentmodule(zone_blockage)\n    f = getfield(m, :restage_all_blocked!)\n    return f(env)\nend"
        @test gate(prop(indirect; name = "relocate_it!")).report.verdict === :reject
        disarm = "function relocate_it!(env)\n    disarm_repair_ablation!()\n    return :ok\nend"
        @test occursin("disarm_repair_ablation!", only(gate(prop(disarm; name = "relocate_it!")).report.reasons))
        # translate 레벨은 translate 목록만
        @test gate(prop(body; name = "relocate_it!"); level = :translate).report.verdict === :accept
    end

    @testset "[3] 봉투·권한(T1 재사용)" begin
        @test gate(prop("function x!(env)\n    run(`ls`)\nend"; name = "x!")).report.reasons == ["reject:forbidden_api:run"]
        stale = gate(merge(prop(NOVEL), Dict{String,Any}("checkpoint_id" => "cp-0")))
        @test stale.report.verdict === :reject && startswith(only(stale.report.reasons), "reject:stale_checkpoint")
        bad = prop(NOVEL); bad["calls"][1]["primitive"] = "something_else!"
        @test startswith(only(gate(bad).report.reasons), "reject:calls_disagree_with_body")
    end

    @testset "[4] source 묶음 digest — 실행 실체만 덮는다" begin
        b0 = gate(prop(NOVEL)).binding
        @test b0 == gate(prop(NOVEL)).binding                                  # 결정적
        @test length(b0["proposal_sha256"]) == 64 && b0["ablation_level"] == "all"
        p1 = prop(NOVEL); p1["params"] = Dict{String,Any}("max_moves" => 2)
        @test gate(p1).binding["proposal_sha256"] != b0["proposal_sha256"]     # 인자가 다르면 다른 실행
        p2 = prop(NOVEL); p2["calls"][1]["args"] = Dict{String,Any}("max_moves" => 1)
        @test gate(p2).binding["proposal_sha256"] != b0["proposal_sha256"]
        p3 = prop(NOVEL * "\n")
        @test gate(p3).binding["source_sha256"] != b0["source_sha256"]
        p4 = prop(NOVEL); p4["claimed_effects"] = ["assignment"]; p4["specification"] = Dict{String,Any}("mechanism" => "different words")
        @test gate(p4).binding["proposal_sha256"] == b0["proposal_sha256"]     # 설명·선언은 실행이 아니다
        @test gate(prop(NOVEL); level = :none).binding["ablation_level"] == "none"
    end
end

# ---- CB 를 실은 뒤: 현행 등록 규약 재사용 ------------------------------------------------------
using ConstructionBots
const CB = ConstructionBots
@testset "T5 source gate (check_impl_conventions 재사용)" begin
    p = G.gate_proposal(prop(NOVEL); checkpoint_id = "cp-1", ablation_level = :none).proposal
    @test G.source_gate(p, CB).verdict === :accept
    invented = replace(NOVEL, "moved += 1" => "moved += find_suitable_robot(env)")
    pi_ = G.gate_proposal(prop(invented); checkpoint_id = "cp-1", ablation_level = :none).proposal
    r = G.source_gate(pi_, CB)
    @test r.verdict === :reject && startswith(only(r.reasons), "reject:impl_unknown_call:find_suitable_robot")
    # 같은 차단 이름에 대해 supervisor 문과 등록 규약이 **같은 문구**를 낸다(목록이 한 파일에서 온다)
    body = "function relocate_it!(env)\n    restage_all_blocked!(env)\n    return :ok\nend"
    old = CB.REPAIR_ABLATION[]
    try
        CB.set_repair_ablation!(:all)
        pb = G.gate_proposal(prop(body; name = "relocate_it!"); checkpoint_id = "cp-1", ablation_level = :none).proposal
        @test G.source_gate(pb, CB).reasons == G.gate_proposal(prop(body; name = "relocate_it!");
            checkpoint_id = "cp-1", ablation_level = :all).report.reasons
    finally
        CB.set_repair_ablation!(old)
    end
end
