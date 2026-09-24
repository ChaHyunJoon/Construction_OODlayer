# test/repair_contracts.jl — T1 계약(타입·실행 권한·manifest). ConstructionBots 를 로드하지 않는다.
#   julia +lts --project=. test/repair_contracts.jl
# 짝: .venv/bin/python -m pytest src/respec/llm_service/test_repair_contract_schemas.py (같은 corpus)
using Test
include(joinpath(@__DIR__, "..", "src", "verification", "repair_types.jl"))
const R = RepairTypes

const CORPUS = R.read_json(joinpath(@__DIR__, "fixtures", "repair_verification", "contracts", "corpus.json"))

function apply_ops(base, ops)
    d = deepcopy(base)
    for op in ops
        path = op["path"]; parent = d
        for k in path[1:end-1]
            parent = parent[k isa Integer ? k + 1 : k]
        end
        k = path[end]; k = k isa Integer ? k + 1 : k
        op["op"] == "set" ? (parent[k] = op["value"]) : delete!(parent, k)
    end
    return d
end

schema_for(base) = R.read_json(base == "proposal" ? R.TOOL_PROPOSAL_SCHEMA_PATH : R.MANIFEST_SCHEMA_PATH)

function julia_verdict(base, doc)
    if base == "proposal"
        rep = R.validate_tool_proposal(doc; checkpoint_id = "cp-1")
        return rep.verdict === :accept ? "accept" : only(rep.reasons)
    end
    e = R.validate_repair_manifest(doc)
    return e === nothing ? "accept" : e
end

@testset "corpus: 스키마 판정과 Julia 판정" begin
    for c in CORPUS["cases"]
        doc = apply_ops(CORPUS["bases"][c["base"]], c["ops"])
        schema_ok = R.schema_error(doc, schema_for(c["base"])) === nothing
        v = julia_verdict(c["base"], doc)
        @testset "$(c["name"])" begin
            @test schema_ok == c["schema_ok"]
            @test c["julia"] == "accept" ? v == "accept" : startswith(v, c["julia"] * ":")
        end
    end
end

@testset "네 통과 조건: 거절 사유 코드가 명시적이다" begin
    P = CORPUS["bases"]["proposal"]; M = CORPUS["bases"]["manifest"]
    # malformed envelope
    r = R.validate_tool_proposal(apply_ops(P, [Dict("op" => "del", "path" => ["calls"])]); checkpoint_id = "cp-1")
    @test r.verdict === :reject && r.stage === :envelope && r.reasons == ["reject:malformed_envelope:/:required:calls"]
    # stale checkpoint
    r = R.validate_tool_proposal(P; checkpoint_id = "cp-2")
    @test r.verdict === :reject && r.reasons == ["reject:stale_checkpoint:cp-1 != cp-2"]
    # forbidden API
    bad = apply_ops(P, [Dict("op" => "set", "path" => ["impl_code"],
        "value" => "function reassign_stuck_carry!(env)\n    ccall(:getpid, Cint, ())\nend")])
    r = R.validate_tool_proposal(bad; checkpoint_id = "cp-1")
    @test r.verdict === :reject && r.stage === :capability && r.reasons == ["reject:forbidden_api:ccall"]
    # empty budget
    @test R.validate_repair_manifest(apply_ops(M, [Dict("op" => "set", "path" => ["budget"], "value" => Dict{String,Any}())])) ==
          "reject:budget_invalid:/budget:required:episode"
end

@testset "{} params + 런타임 센서 조회가 정상 경로다" begin
    p = R.parse_tool_proposal(CORPUS["bases"]["proposal"]; checkpoint_id = "cp-1")
    @test p isa R.ToolProposal
    @test isempty(p.params) && isempty(only(p.calls).args)
    @test p.surface == "unknown" && p.reversible === false   # register_minted_primitive! 기본값과 같음
    s = R.read_json(R.TOOL_PROPOSAL_SCHEMA_PATH)
    @test !("required" in keys(s["properties"]["params"]))
    @test !("required" in keys(s["properties"]["calls"]["items"]["properties"]["args"]))
end

@testset "claimed_effects 는 권한을 주지도 빼지도 않는다" begin
    P = CORPUS["bases"]["proposal"]
    for code in ("function reassign_stuck_carry!(env)\n    run(`true`)\nend",
                 "function reassign_stuck_carry!(env)\n    return :ok\nend")
        verdicts = map((String[], ["geometry"], ["validator_override", "clock_reset"])) do claims
            d = apply_ops(P, [Dict("op" => "set", "path" => ["impl_code"], "value" => code),
                              Dict("op" => "set", "path" => ["claimed_effects"], "value" => claims)])
            r = R.validate_tool_proposal(d; checkpoint_id = "cp-1"); (r.verdict, r.reasons)
        end
        @test allequal(verdicts)
    end
end

@testset "capability 계약: graph 변경은 금지 목록이 아니다, step 은 adapter 로" begin
    C = R.DEFAULT_CAPABILITY_CONTRACT
    @test :temporary_edges in C.mutable_runtime && :task_assignment in C.mutable_runtime
    @test isempty(intersect(C.forbidden_api, [:add_edge!, :rem_edge!, :set_desired_global_transform!,
                                              :reset_cache_resume!, :preprocess_env!, :step_environment!]))
    @test isempty(intersect(C.protected, C.mutable_runtime))
    d = apply_ops(CORPUS["bases"]["proposal"], [Dict("op" => "set", "path" => ["impl_code"],
        "value" => "function reassign_stuck_carry!(env)\n    step_environment!(env)\nend")])
    r = R.validate_tool_proposal(d; checkpoint_id = "cp-1")
    @test r.verdict === :accept && r.adapter_calls == [:step_environment!]
    # 역사적 body 60개(T0 fixture)는 어휘 검사에 하나도 안 걸린다 — 목록이 실제 도구를 막지 않는다
    legacy = joinpath(@__DIR__, "fixtures", "repair_verification", "legacy")
    bodies = [joinpath(d, f) for d in readdir(legacy; join = true) if isdir(d) && !endswith(d, "source_snapshots")
              for f in readdir(d) if endswith(f, ".jl")]
    @test length(bodies) == 60
    @test all(b -> isempty(R.api_hits(read(b, String), C.forbidden_api)), bodies)
end

@testset "주 팔에 geometry patch 경로가 없다" begin
    for a in (:U1, :U4, :V4); @test R.ARM_PROPOSAL_FORMAT[a] === :tool_proposal; end
    @test R.ARM_PROPOSAL_FORMAT[:G4] === :geometry_patch_auxiliary
    s = R.read_json(R.TOOL_PROPOSAL_SCHEMA_PATH)
    @test !any(k -> occursin(r"geom|patch|xy|translat|delta"i, k), keys(s["properties"]))
    @test !any(n -> occursin(r"geom|patch"i, String(n)), names(R; all = true))
    arms = R.read_json(R.MANIFEST_SCHEMA_PATH)["properties"]["arms"]["items"]["enum"]
    @test Set(Symbol.(arms)) == Set(keys(R.ARM_PROPOSAL_FORMAT))
end

@testset "결과 어휘와 불변식" begin
    @test_throws ArgumentError R.RolloutReport("noop", "cp", :UNKNOWN, nothing, :none, 0, 0.0, 0.0, 0, Dict{String,Int}())
    @test_throws ArgumentError R.RolloutReport("noop", "cp", :COMPLETE, nothing, :max_sim_steps, 0, 0.0, 0.0, 0, Dict{String,Int}())
    @test_throws ArgumentError R.RolloutReport("noop", "cp", :FAIL_WITHIN_BUDGET, :wall_timeout, :none, 0, 0.0, 0.0, 0, Dict{String,Int}())
    to = R.RolloutReport("p1", "cp", :UNKNOWN, :wall_timeout, :none, 10, 3600.0, 1.0, 0, Dict{String,Int}())
    @test to.outcome === :UNKNOWN          # wall timeout 은 실패가 아니라 UNKNOWN
    # 선택 표
    @test R.SelectionReport("cp", :FAIL_WITHIN_BUDGET, :tool, "p1", :rescued, String[], Dict("p1" => :COMPLETE), String[]).selected === :tool
    @test_throws ArgumentError R.SelectionReport("cp", :COMPLETE, :tool, "p1", :rescued, String[], Dict{String,Symbol}(), String[])
    @test_throws ArgumentError R.SelectionReport("cp", :UNKNOWN, :noop, nothing, :unsolved, String[], Dict{String,Symbol}(), String[])
    @test R.SelectionReport("cp", :UNKNOWN, :noop, nothing, :certification_unavailable, String[], Dict{String,Symbol}(), ["baseline wall timeout"]).classification === :certification_unavailable
    # 거절·미지원·noop-equivalent·인증 불가·requires_runtime 은 서로 다른 판정이고 사유가 필요하다
    for v in (:reject, :unsupported, :noop_equivalent, :requires_runtime, :certification_unavailable)
        @test_throws ArgumentError R.ValidationReport(:effects, v, "p1", String[], "v")
        @test R.ValidationReport(:effects, v, "p1", ["why"], "v").verdict === v
    end
    @test_throws ArgumentError R.EnactmentReport("p", "c", "w", :threw, nothing, Dict{String,Any}[], String[], String[], 0, 0.0, 0.0, nothing)
    @test_throws ArgumentError R.CommitReport("c", "p", "h", "w", :committed, false, nothing, String[])
    @test_throws ArgumentError R.CommitReport("c", "p", "h", "w", :aborted_resumed_noop, nothing, nothing, String[])
end

@testset "지문: 빈 값 거절, 불일치 필드 보고, checkpoint 블록" begin
    kw = Dict(f => (T === Int ? 1 : "x") for (f, T) in zip(fieldnames(R.Fingerprints), fieldtypes(R.Fingerprints)))
    a = R.Fingerprints(; kw...)
    @test_throws ArgumentError R.Fingerprints(; merge(kw, Dict(:prompt_digest => ""))...)
    b = R.Fingerprints(; merge(kw, Dict(:validator_version => "y", :solver_seed => 2))...)
    @test R.fingerprint_mismatches(a, b) == [:solver_seed, :validator_version]
    @test isempty(R.fingerprint_mismatches(a, a))
    cp = R.EpisodeCheckpoint("cp-1", "after zone injection, before model call", true, a, "p", "h",
                             Dict(:native => "h"), "pre", "post", String[])
    @test length(R.certification_gaps(cp)) == length(R.CHECKPOINT_BLOCKS) - 1
    @test_throws ArgumentError R.EpisodeCheckpoint("cp-1", "t0", true, a, "p", "h", Dict(:state_hash => "h"), "pre", "post", String[])
end

@testset "manifest: 보완 없음, 템플릿의 빈 값은 거절, 역사값 표기" begin
    M = CORPUS["bases"]["manifest"]; before = deepcopy(M)
    @test R.validate_repair_manifest(M) === nothing
    @test M == before                                   # 기본값을 채워 넣지 않는다
    t = R.read_json(joinpath(dirname(R.MANIFEST_SCHEMA_PATH), "repair_verification_manifest.template.json"))
    @test startswith(R.validate_repair_manifest(t), "reject:")   # 미정 new_choice 가 null 이라 실행 거절
    ep = t["budget"]["episode"]
    @test (ep["max_sim_steps"]["value"], ep["max_num_iters_no_progress"]["value"], ep["wall_timeout_s"]["value"]) == (100000, 3000, 3600)
    @test all(ep[k]["source"] == "historical" for k in ("max_sim_steps", "max_num_iters_no_progress", "wall_timeout_s"))
    @test all(v["source"] == "new_choice" && v["value"] === nothing for v in values(t["budget"]["worker"]))
    @test t["cohort"]["sha256"] == R.file_sha256(joinpath(@__DIR__, "fixtures", "repair_verification", "cohort.json"))
end

@testset "변이: schema 에서 budget 필수를 빼면 빈 budget 게이트가 빨개진다" begin
    s = R.read_json(R.MANIFEST_SCHEMA_PATH)
    empty_budget = apply_ops(CORPUS["bases"]["manifest"], [Dict("op" => "del", "path" => ["budget"])])
    @test R.validate_repair_manifest(empty_budget; schema = s) !== nothing
    filter!(!=("budget"), s["required"])
    @test R.validate_repair_manifest(empty_budget; schema = s) === nothing   # 게이트가 schema 에 실려 있다
    # 모르는 키워드는 조용히 통과하지 않는다
    @test_throws ErrorException R.schema_error(1, Dict{String,Any}("multipleOf" => 2))
end
