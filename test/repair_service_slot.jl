# =============================================================================
# test/repair_service_slot.jl — T9 서비스 제안 source 슬롯(CB 없는 driver 쪽) 빠른 게이트. 단독 실행, runtests.jl 미포함.
#
#   julia +lts --project=. test/repair_service_slot.jl
#
# 서비스·worker 는 전부 stub(주입된 `post`·`observe`·`preflight`) — 모델 호출 0, 서비스 기동 0, worker 0.
# 끝까지 실제로 도는 판(가짜 LM 서비스 → observe worker → T6 preflight worker → 동결 → supervisor)은
# `test/repair_service_episode.jl` 이다.
# =============================================================================
using Test, JSON3, SHA
include(joinpath(@__DIR__, "..", "src", "verification", "repair_runtime.jl"))
const RT = RepairRuntime
const R = RepairTypes
const BR = BranchRunner
const G = RepairGeometryControl

const SCHEMA_SHA = RT._sha(RT.SCHEMA_FILE)
const PI0CELL = merge(BR.PI0, Dict("DEMO_OOD" => "none", "DEMO_ZONE" => "1", "DEMO_MODEL" => "tractor.mpd", "DEMO_SEED" => "26"))
const BUDGET = Dict{String,Any}("max_model_calls" => 4, "max_candidates" => 4, "max_total_tokens" => 20000, "max_cost_usd" => 1.0)

function parent_dir()
    d = mktempdir()
    open(io -> JSON3.write(io, Dict("checkpoint_id" => "t0")), joinpath(d, "contract.json"), "w")
    return d
end
prov() = Dict{String,Any}("source" => "service", "tool_proposal_schema_sha256" => SCHEMA_SHA,
                          "capability_contract_version" => R.DEFAULT_CAPABILITY_CONTRACT.version,
                          "service_code_fingerprint" => "feedfacefeedface")
tp(i; parent = nothing, name = "t9_c$(i)!") = merge(Dict{String,Any}("schema_version" => R.TOOL_PROPOSAL_SCHEMA_VERSION,
    "checkpoint_id" => "t0", "proposal_id" => "rid-s$(i)", "submission_index" => i, "tool_name" => "x",
    "specification" => Dict("mechanism" => "m"), "impl_name" => name, "impl_code" => "function $(name)(env)\n    return :ok\nend",
    "params" => Dict(), "calls" => [Dict("primitive" => name, "args" => Dict())], "provenance" => prov()),
    parent === nothing ? Dict{String,Any}() : Dict{String,Any}("parent_proposal_id" => parent))
gp(i, ref, x, y; parent = nothing) = merge(Dict{String,Any}("schema_version" => "geometry-patch/1", "checkpoint_id" => "t0",
    "proposal_id" => "rid-s$(i)", "submission_index" => i,
    "writes" => [Dict("config_ref" => ref, "xy" => Dict("x" => x, "y" => y))], "provenance" => prov()),
    parent === nothing ? Dict{String,Any}() : Dict{String,Any}("parent_proposal_id" => parent))
resp(arm, cands; calls = 3, submitted = length(cands)) = Dict{String,Any}("arm" => arm, "candidates" => cands,
    "compose_input" => Dict("spec_text" => "S", "spec" => Dict()), "error" => nothing,
    "ledger" => Dict{String,Any}("calls_used" => calls, "submitted" => submitted))
const GCTX = Dict{String,Any}("configs" => [Dict{String,Any}("config_ref" => "AssemblyID(3)", "x" => 1.0, "y" => -2.0,
                                                               "staging_radius" => 0.8, "closed" => false)], "zones" => Any[])
OBS = Dict{String,Any}("request" => Dict("kind" => "zone", "nl" => "a zone"), "geometry_context" => GCTX)

"stub 서비스: path 별 응답 대기열, 호출 기록."
function stub_post(script)
    calls = Tuple{String,Dict{String,Any}}[]
    f = (url, path, body) -> (push!(calls, (path, Dict{String,Any}(body))); popfirst!(script[path]))
    return f, calls
end
pf_ok() = (; gate = nothing, judged = nothing, eligible = false, feedback_allowed = true, run = nothing,
           reasons = ["enactment requires_runtime: requires_runtime: engine progress requested (step 1)"],
           feedback = ["enactment requires_runtime: requires_runtime: engine progress requested (step 1)"])
pf_rej(why) = (; gate = nothing, judged = nothing, eligible = false, feedback_allowed = true, run = nothing,
               reasons = [why, "task_contract_unavailable: x"], feedback = [why, "task_contract_unavailable: x"])
run_slot(post; arm = "general", preflight = (p, d, raw, i, e, l) -> pf_ok(), observe = (p, d, e, l) -> OBS) =
    RT.service_proposals!(; parent_dir = parent_dir(), root = mktempdir(), url = "http://stub", arm, budget = BUDGET,
                          launch_env = PI0CELL, run_ctx = Dict("repair_ablation" => "all"), post, observe, preflight)

@testset "T9 service slot (fast, no CB, no service)" begin

@testset "[1] 후보 source 는 정확히 하나 — 둘 다면 오류, enforce 는 fixture 거절, 예산은 기본값 없음" begin
    fx = Dict("ZONE_REPAIR_PROPOSALS" => "/x.json")
    sv = Dict("DSPY_URL" => "http://127.0.0.1:1", "ZONE_REPAIR_MAX_TOTAL_TOKENS" => "20000", "ZONE_REPAIR_MAX_COST_USD" => "2.5")
    @test_throws ErrorException RT.proposal_source(merge(fx, sv); mode = :shadow)
    e = try RT.proposal_source(merge(fx, sv); mode = :shadow) catch x; sprint(showerror, x) end
    @test occursin("choose exactly one proposal source", e)
    @test RT.proposal_source(fx; mode = :shadow).source === :fixture
    @test occursin("refuses a fixture", try RT.proposal_source(fx; mode = :enforce) catch x; sprint(showerror, x) end)
    @test_throws ErrorException RT.proposal_source(merge(fx, Dict("ZONE_REPAIR_ARM" => "geometry")); mode = :shadow)
    s = RT.proposal_source(sv; mode = :shadow)
    @test s.source === :service && s.arm == "general" && s.budget["max_total_tokens"] == 20000 && s.budget["max_cost_usd"] == 2.5
    @test s.budget["max_candidates"] == 4 && s.budget["max_model_calls"] == 4
    @test RT.proposal_source(merge(sv, Dict("ZONE_REPAIR_ARM" => "geometry")); mode = :shadow).arm == "geometry"
    for bad in ("Geometry", "g4", "", " general")
        @test_throws ErrorException RT.proposal_source(merge(sv, Dict("ZONE_REPAIR_ARM" => bad)); mode = :shadow)
    end
    for k in ("ZONE_REPAIR_MAX_TOTAL_TOKENS", "ZONE_REPAIR_MAX_COST_USD")
        e2 = copy(sv); delete!(e2, k)
        @test occursin(k, try RT.proposal_source(e2; mode = :shadow) catch x; sprint(showerror, x) end)
        @test_throws ErrorException RT.proposal_source(merge(sv, Dict(k => "0")); mode = :shadow)
    end
    @test_throws ErrorException RT.proposal_source(Dict{String,String}(); mode = :shadow)
    # production 진입(main)도 같은 함수로 부모를 띄우기 전에 죽는다
    d = mktempdir()
    withenv(merge(PI0CELL, fx, sv, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "ZONE_REPAIR_DIR" => joinpath(d, "m")))...) do
        @test occursin("choose exactly one", try RT.main(); "" catch x; sprint(showerror, x) end)
    end
    @test !isdir(joinpath(d, "m", "parent"))
    # run_episode!: 실제 enforce(시험 표식 없음) + fixture 는 부모 전에 거절; 서비스는 예산 필수
    @test occursin("refuses a fixture", try RT.run_episode!(; mode = :enforce, launch_env = PI0CELL, root = joinpath(d, "e"),
        proposals = [tp(1)], source = :fixture, capabilities = Dict("enforce_allowed" => true), out_dir = d); "" catch x; sprint(showerror, x) end)
    @test occursin("model budget", try RT.run_episode!(; mode = :shadow, launch_env = PI0CELL, root = joinpath(d, "s"),
        proposals = Dict{String,Any}[], source = :service, url = "http://x", out_dir = d); "" catch x; sprint(showerror, x) end)
    @test !isdir(joinpath(d, "e", "parent")) && !isdir(joinpath(d, "s", "parent"))
end

@testset "[2] t0 되먹임 — 경계 오류만, requires_runtime·판정 기반 부재는 아니다" begin
    rs = ["enactment requires_runtime: requires_runtime: engine progress requested (step 2)",
          "reject:malformed_envelope:/:required:impl_code", "enactment registration_rejected: reject:impl_unknown_call:f",
          "enactment threw: boom", "effects reject: task deleted", "post-enactment contract: closed forged",
          "postprocess_failed: resync", "unsupported: opaque callback", "task_contract_unavailable: missing",
          "no enactment export (worker killed or crashed before writing it): status unobservable",
          "cross_check: proposal_id x != y", "rollout: something", "reject:geometry_patch:unknown_config_ref:\"Q\""]
    @test RT.t0_feedback(rs) == rs[[2, 3, 4, 5, 6, 7, 8, 13]]
end

@testset "[3] 처음 3개 → t0 거절 1개 → 수정 호출 1회 → 동결 4개(제출 순서), U1 = U4[1]" begin
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1), tp(2), tp(3)])],
                                 "/zone_repair/revise" => [resp("general", [tp(4; parent = "rid-s2")]; calls = 4, submitted = 4)]))
    why = "enactment registration_rejected: reject:impl_unknown_call:t9_no_such_helper"
    out = run_slot(post; preflight = (p, d, raw, i, e, l) -> raw["proposal_id"] == "rid-s2" ? pf_rej(why) : pf_ok())
    @test out.gaps == String[] && out.record["status"] == "ok"
    @test [p["proposal_id"] for p in out.proposals] == ["rid-s1", "rid-s2", "rid-s3", "rid-s4"]
    @test [c[1] for c in calls] == ["/zone_repair/propose", "/zone_repair/revise"]
    rb = calls[2][2]
    @test [r["proposal_id"] for r in rb["rejected"]] == ["rid-s2"]
    @test rb["rejected"][1]["reasons"] == [why]          # requires_runtime / contract-unavailable are not fed back
    @test rb["ledger"]["calls_used"] == 3 && rb["parent_record_id"] == calls[1][2]["record_id"]
    @test haskey(calls[1][2], "request") && !haskey(calls[1][2], "geometry_context")   # the general arm gets no geometry context
    @test calls[1][2]["capability_contract_version"] == R.DEFAULT_CAPABILITY_CONTRACT.version
    v = RT.arm_views(out.proposals; arm = "general")
    @test v["U1"] == ["rid-s1"] && v["U4"] == v["V4"] == ["rid-s1", "rid-s2", "rid-s3", "rid-s4"] && v["U1"][1] == v["U4"][1]
    s2 = only(filter(s -> s["proposal_id"] == "rid-s2", out.record["submissions"]))
    @test s2["frozen"] === true && s2["t0_feedback"] == [why]              # 거절본도 동결 목록에 남는다(K 를 소비)
    @test out.record["revision"]["attempted"] === true
end

@testset "[4] 처음 4개면 수정 호출이 없다 · 거절이 없어도 없다" begin
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1), tp(2), tp(3), tp(4)])]))
    out = run_slot(post; preflight = (p, d, raw, i, e, l) -> pf_rej("enactment threw: x"))
    @test length(calls) == 1 && length(out.proposals) == 4 && out.record["revision"]["attempted"] === false
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1), tp(2)])]))
    out = run_slot(post)
    @test length(calls) == 1 && length(out.proposals) == 2
    # 호출을 다 쓴 원장(숨은 재시도가 4번째를 먹었다)이면 거절이 있어도 수정 호출은 없다
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1)]; calls = 4)]))
    out = run_slot(post; preflight = (p, d, raw, i, e, l) -> pf_rej("enactment threw: x"))
    @test length(calls) == 1 && out.record["revision"]["attempted"] === false
end

@testset "[5] 응답 계약 위반은 gap(조용히 얼리지 않는다) — 팔 불일치·기하 patch·원장 초과" begin
    for (r, pat) in ((resp("geometry", [tp(1)]), "arm"), (resp("general", [gp(1, "AssemblyID(3)", 1.0, 2.0)]), "not a tool-proposal/1"),
                     (resp("general", [tp(1)]; calls = 5), "model calls > 4"), (resp("general", [tp(1)]; submitted = 5), "candidates > K"))
        post, calls = stub_post(Dict("/zone_repair/propose" => [r]))
        out = run_slot(post; preflight = (a...) -> error("must not preflight after a contract gap"))
        @test !isempty(out.gaps) && any(g -> occursin(pat, g), out.gaps) && isempty(out.proposals)
    end
end

@testset "[6] 서비스 오류·관측 실패는 후보 0개 + 사유(gap 아님 — B0 는 잰다)" begin
    out = run_slot((u, p, b) -> error("connection refused"))
    @test isempty(out.proposals) && out.gaps == String[] && startswith(out.record["status"], "service_error")
    out = run_slot((u, p, b) -> error("unreachable"); observe = (a...) -> nothing)
    @test out.record["status"] == "observation_failed" && isempty(out.proposals)
    out = run_slot((u, p, b) -> error("unreachable"); observe = (a...) -> error("worker died"))
    @test out.record["status"] == "observation_failed" && occursin("worker died", out.record["observe_error"])
end

@testset "[7] G4 adapter — 모델 수치만 박는다, 문맥 밖 ref·형식 위반·중복·낡은 checkpoint 는 정적 거절" begin
    c = G.patch_to_proposal(gp(1, "AssemblyID(3)", 3.25, -0.125), GCTX; checkpoint_id = "t0")
    @test c.reasons == String[] && c.proposal !== nothing
    p = c.proposal
    @test R.parse_tool_proposal(p; checkpoint_id = "t0") isa R.ToolProposal          # 일반 봉투 그대로
    @test p["provenance"]["arm"] == "G4" && p["provenance"]["tool_proposal_schema_sha256"] == SCHEMA_SHA
    @test p["provenance"]["geometry_patch"]["writes"][1]["xy"] == Dict("x" => 3.25, "y" => -0.125)
    code = p["impl_code"]
    @test occursin("(\"AssemblyID(3)\", 3.25, -0.125)", code)
    # 🔴 추천 좌표를 계산하지 않는다: body 의 수치 리터럴은 모델이 낸 둘과 구조 상수(0.0, 인덱스)뿐이다
    lits = Set(m.match for m in eachmatch(r"(?<![A-Za-z_\d.])-?\d+\.\d+(?:e-?\d+)?", code))
    @test lits == Set(["3.25", "-0.125", "0.0"])
    @test !occursin(r"find_clear|min_translation|restage|relocat"i, code)
    @test occursin("reject:geometry_patch:unknown_config_ref", only(G.patch_to_proposal(gp(1, "AssemblyID(9)", 0.0, 0.0), GCTX; checkpoint_id = "t0").reasons))
    bad = gp(1, "AssemblyID(3)", 1.0, 1.0); delete!(bad["writes"][1], "xy")
    @test occursin("malformed", only(G.patch_to_proposal(bad, GCTX; checkpoint_id = "t0").reasons))
    dup = gp(1, "AssemblyID(3)", 1.0, 1.0); push!(dup["writes"], dup["writes"][1])
    @test occursin("duplicate_config_ref", only(G.patch_to_proposal(dup, GCTX; checkpoint_id = "t0").reasons))
    @test occursin("stale_checkpoint", only(G.patch_to_proposal(gp(1, "AssemblyID(3)", 1.0, 1.0), GCTX; checkpoint_id = "t1").reasons))
    inj = gp(1, "AssemblyID(3)\$(run(`id`))", 1.0, 1.0)
    @test occursin("unknown_config_ref", only(G.patch_to_proposal(inj, merge(GCTX, Dict("configs" => [Dict("config_ref" => "AssemblyID(3)\$(run(`id`))")])); checkpoint_id = "t0").reasons))
end

@testset "[8] G4 슬롯 — patch 는 변환 후 preflight, 변환 거절은 사유로 수정 호출에 간다" begin
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("geometry", [gp(1, "AssemblyID(3)", 4.0, -2.0), gp(2, "AssemblyID(7)", 0.0, 0.0)]; calls = 3)],
                                 "/zone_repair/revise" => [resp("geometry", [gp(3, "AssemblyID(3)", 5.0, -2.0; parent = "rid-s2")]; calls = 4, submitted = 3)]))
    seen = String[]
    out = run_slot(post; arm = "geometry", preflight = (p, d, raw, i, e, l) -> (push!(seen, raw["impl_name"]); pf_ok()))
    @test out.gaps == String[]
    @test haskey(calls[1][2], "geometry_context") && calls[1][2]["geometry_context"] == GCTX
    @test [p["proposal_id"] for p in out.proposals] == ["rid-s1", "rid-s3"]      # s2 는 코드가 될 수 없었다(동결 밖, 제출 수에는 셌다)
    @test all(p -> p["schema_version"] == R.TOOL_PROPOSAL_SCHEMA_VERSION && startswith(p["impl_name"], "g4_patch_"), out.proposals)
    @test length(seen) == 1                                                        # 변환된 첫 응답 후보만 preflight
    rb = calls[2][2]["rejected"]
    @test [r["proposal_id"] for r in rb] == ["rid-s2"] && occursin("unknown_config_ref", only(rb[1]["reasons"]))
    @test haskey(rb[1], "patch") && !haskey(rb[1], "impl_code")
    @test RT.arm_views(out.proposals; arm = "geometry") == Dict("G4" => ["rid-s1", "rid-s3"])
    s2 = only(filter(s -> s["proposal_id"] == "rid-s2", out.record["submissions"]))
    @test s2["frozen"] === false && occursin("unknown_config_ref", only(s2["rejected_before_freeze"]))
end

@testset "[10] 서비스 후보의 도장은 null 이어도 부재다(gap)" begin
    p = tp(1); p["provenance"]["tool_proposal_schema_sha256"] = nothing
    g = RT.decision_gaps([p]; source = :service, url = "x", service_gate = _ -> (true, "OK"), tree_fingerprint = () -> "feedfacefeedface")
    @test any(x -> occursin("lacks provenance.tool_proposal_schema_sha256", x), g)
    @test RT.decision_gaps([tp(1)]; source = :service, url = "x", service_gate = _ -> (true, "OK"),
                           tree_fingerprint = () -> "feedfacefeedface") == String[]      # 양성 대조
end

@testset "[11] HTTP 200 의 서비스 거절·오류는 모델 실패가 아니다 — status 로 가르고, ablation 불일치는 gap" begin
    err(e; calls = 0) = merge(resp("general", Any[]; calls, submitted = 0), Dict{String,Any}("error" => e, "compose_input" => nothing))
    for (e, want, isgap) in (("refused: repair_ablation mismatch: julia='all' service='none' -- no model call was made", "service_refused(propose)", true),
                             ("disabled: TOOL_SYNTHESIS != '1' -- no model call was made (R13)", "service_refused(propose)", false),
                             ("no LM configured -- no model call was made", "service_refused(propose)", false),
                             ("refused: the geometry arm needs a geometry context", "service_refused(propose)", false),
                             ("observe: budget: call budget: 2 of 4 model calls used and 2 mandatory stage(s) still need one", "budget_exhausted(propose)", false),
                             ("compose: AdapterParseError: bad", "service_error(propose)", false))
        post, _ = stub_post(Dict("/zone_repair/propose" => [err(e; calls = 2)]))
        out = run_slot(post; preflight = (a...) -> error("no preflight on a refusal"))
        @test startswith(out.record["status"], want) && isempty(out.proposals)
        @test out.record["model_outcome"] === nothing
        @test isgap == any(g -> occursin("repair_ablation", g), out.gaps)
    end
    # 모델 쪽 0 결과(오류 없음, expressible=True)는 status ok 이고 model_outcome 이 사유를 싣는다
    z = merge(resp("general", Any[]; calls = 2, submitted = 0), Dict{String,Any}("reason" => "no candidates: the design stage reported expressible=true"))
    post, _ = stub_post(Dict("/zone_repair/propose" => [z]))
    out = run_slot(post)
    @test out.record["status"] == "ok" && startswith(out.record["model_outcome"], "no_candidates: no candidates: the design")
    # 수정 호출의 거절: 첫 응답 후보는 동결된 채, status 는 그 거절을 싣는다
    post, _ = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1), tp(2)])],
                             "/zone_repair/revise" => [merge(resp("general", Any[]; calls = 3, submitted = 2),
                                                             Dict{String,Any}("error" => "refused: no LM configured -- no model call was made"))]))
    out = run_slot(post; preflight = (p, d, raw, i, e, l) -> pf_rej("enactment threw: x"))
    @test length(out.proposals) == 2 && startswith(out.record["status"], "service_refused(revise)")
    @test startswith(out.record["revision"]["status"], "service_refused(revise)")
    # G4: 관측 worker 가 기하 문맥을 못 만들었으면 서비스에 가지 않는다
    called = Ref(0)
    out = run_slot((u, p, b) -> (called[] += 1; error("must not be called")); arm = "geometry",
                   observe = (a...) -> merge(OBS, Dict("geometry_context" => Dict("error" => "MethodError: boom"))))
    @test called[] == 0 && startswith(out.record["status"], "observation_failed: geometry context: MethodError")
end

@testset "[12] 배정 센서는 요청 본문으로 가고 기록에 지문·읽기 전용 증거가 남는다" begin
    rb = [Dict{String,Any}("robot" => "BotID(1)", "available" => true, "open_goto_tasks" => 2)]
    ro = Dict{String,Any}("fields_compared" => 10, "rng_equal" => true, "fields_changed" => String[])
    post, calls = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(1)])]))
    out = run_slot(post; observe = (a...) -> merge(OBS, Dict("robot_bindings" => rb, "robot_bindings_sensor" => "robot-bindings/1",
                                                             "sensor_readonly" => ro)))
    @test calls[1][2]["robot_bindings"] == rb
    @test out.record["observation"]["robot_bindings_sensor"] == "robot-bindings/1" && out.record["observation"]["sensor_readonly"] == ro
    @test out.record["observation"]["robot_bindings_sha256"] == bytes2hex(sha256(JSON3.write(rb)))
end

@testset "[9] 동결 기록 파일 — 제출 순서·거절·preflight·원장" begin
    post, _ = stub_post(Dict("/zone_repair/propose" => [resp("general", [tp(2), tp(1)])]))
    root = mktempdir()
    out = RT.service_proposals!(; parent_dir = parent_dir(), root, url = "u", arm = "general", budget = BUDGET, launch_env = PI0CELL,
                                run_ctx = Dict(), post, observe = (a...) -> OBS, preflight = (a...) -> pf_ok())
    f = BR._json(joinpath(root, "proposal_source", "frozen_list.json"))
    @test f["frozen_proposal_ids"] == ["rid-s1", "rid-s2"] && [p["submission_index"] for p in f["frozen"]] == [1, 2]
    @test length(f["submissions"]) == 2 && all(s -> haskey(s, "preflight"), f["submissions"]) && length(f["responses"]) == 1
    @test f["responses"][1]["ledger"]["calls_used"] == 3
end

end # testset
