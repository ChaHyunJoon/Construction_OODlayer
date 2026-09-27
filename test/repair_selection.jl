# =============================================================================
# test/repair_selection.jl — T7 선택기·certificate·commit 판정의 순수 게이트(단독 실행, runtests.jl 미포함 — 브리프 요구 없음).
#
#   julia +lts --project=. test/repair_selection.jl
#
# ConstructionBots 를 로드하지 않는다(supervisor 는 생성 코드를 싣지 않는 프로세스다). 에피소드 수준의 commit/활성화는
# `test/repair_commit_replay.jl`.
# =============================================================================
using Test, JSON3, SHA
include(joinpath(@__DIR__, "..", "src", "verification", "repair_supervisor.jl"))
const S = RepairSupervisor
const R = RepairTypes
const TC = TaskContract
const TX = ToolExecution
const BR = BranchRunner

cand(id, outcome, eligible; k = 1, extra...) = (; proposal_id = id, submission_index = k, outcome, eligible, extra...)
wj(p, d) = open(io -> JSON3.write(io, d), p, "w")
rt(x) = JSON3.read(JSON3.write(x), Dict{String,Any})

"합성 부모 디렉터리: contract.json · envelope · task_contract.json(digest 기록)."
function fake_parent(dir; gaps = ["task_world: original task contract not supplied (T5)"], tc_ok = true)
    mkpath(dir)
    write(joinpath(dir, "t0.envelope.json"), "{\"envelope\":1}")
    wj(joinpath(dir, "task_contract.json"), Dict("semantic_edges" => [], "atol" => 1e-6))
    sha = bytes2hex(sha256(read(joinpath(dir, "task_contract.json"))))
    wj(joinpath(dir, "contract.json"), Dict("checkpoint_id" => "t0", "envelope" => joinpath(dir, "t0.envelope.json"),
        "t0_iter" => 1, "batch_pos" => 1, "sim_params" => Dict("max_time_steps" => 100000, "max_num_iters_no_progress" => 3000,
        "sim_batch_size" => 50), "pi0" => Dict("REPAIR_ABLATION" => "all"), "gaps" => gaps, "parent_pid" => 1,
        "required_ids" => ["PC1"], "real_ledger" => joinpath(dir, "ledger.jsonl"),
        "task_contract" => Dict("sha256" => tc_ok ? sha : "0"^64, "path" => joinpath(dir, "task_contract.json"))))
    write(joinpath(dir, "held.json"), "{}")
    return dir
end
prop(name, code; id = "p-" * name, k = 1) = Dict{String,Any}("schema_version" => "tool-proposal/1", "checkpoint_id" => "t0",
    "proposal_id" => id, "submission_index" => k, "tool_name" => name, "specification" => Dict{String,Any}(),
    "impl_name" => name, "impl_code" => code, "params" => Dict{String,Any}(),
    "calls" => [Dict{String,Any}("primitive" => name, "args" => Dict{String,Any}())])
ps_a = Dict{String,Any}("nodes" => Dict("a" => "RobotGo"), "closed" => ["a"])
"합성 enactment(판정 쪽 파일 모양)."
fake_enactment(raw; post = ps_a, fields = String[], classes = ["geometry"]) = Dict{String,Any}(
    "schema" => "enactment/1", "status" => "enacted", "mode" => "full", "proposal_id" => raw["proposal_id"],
    "checkpoint_id" => "t0", "proposal_sha256" => TC.digest(rt(raw)), "impl_name" => raw["impl_name"],
    "post_state" => post, "post_state_sha256" => TC.digest(post), "trace_digest" => "td", "engine_steps" => 0, "batch_pos" => 1,
    "effect_classes" => classes, "body_changes" => ["poses(3)"], "harness_changes" => String[], "adapter_log" => Any[],
    "unobservable" => String[], "audit" => Dict("fields_changed_by_action" => fields, "methods_changed_by_action" => String[],
    "fields_changed_by_engine" => String[]), "postprocess" => Dict("checks_run" => ["scene_resync"], "failures" => String[],
    "unsupported" => String[], "log" => Any[], "fields_changed" => String[]),
    "body" => Dict("verdict" => "admit", "partial" => false, "steps" => [Dict("name" => raw["impl_name"], "status" => "applied", "detail" => "x")]),
    "registration" => Dict("why" => nothing), "wall_s" => 1.0)
okverify = Dict{String,Any}("mismatched_blocks" => String[], "counters_equal" => true, "rng_equal" => true)
rollout(branch, outcome = :COMPLETE; steps = 800) = R.RolloutReport(branch, "t0", outcome, outcome === :UNKNOWN ? :wall_timeout : nothing,
    outcome === :COMPLETE ? :project_complete : outcome === :FAIL_WITHIN_BUDGET ? :no_progress_limit : :none, steps, 1.0, 1.0, 0, Dict{String,Int}())

@testset "T7 selection / certificate / commit decisions (pure)" begin

@testset "[1] 선택 표(§7.2) — 모든 조합" begin
    kinds = Dict("elig" => cand("c", :COMPLETE, true), "complete_but_rejected" => cand("c", :COMPLETE, false),
                 "fail" => cand("c", :FAIL_WITHIN_BUDGET, false), "unknown" => cand("c", :UNKNOWN, false),
                 "no_rollout" => cand("c", nothing, false),
                 # T10b 판정: worker 가 집행을 폐기(partial·throw·관측 불가·등록 거절)해 rollout 이 UNKNOWN 으로 보여도 후보의 거절이다
                 "discarded" => cand("c", :UNKNOWN, false; discarded = true))
    for (k, c) in kinds
        # 기준 COMPLETE → 무엇이든 NOOP. 실패·거절은 raw regression, UNKNOWN 은 regression 아님(사유로 남음).
        s = S.select_repair("t0", :COMPLETE, [c])
        @test s.selected === :noop && s.classification === :baseline_complete && s.selected_proposal_id === nothing
        @test s.raw_regressions == (k in ("fail", "complete_but_rejected", "no_rollout", "discarded") ? ["c"] : String[])
        @test s.candidate_outcomes["c"] === (k == "elig" ? :COMPLETE : k == "fail" ? :FAIL_WITHIN_BUDGET : k == "unknown" ? :UNKNOWN : :REJECTED)
        k == "unknown" && @test any(r -> startswith(r, "candidate_unknown: c"), s.reasons)
        # 기준 FAIL → eligible COMPLETE 만 TOOL
        s = S.select_repair("t0", :FAIL_WITHIN_BUDGET, [c])
        @test (s.selected, s.classification) == (k == "elig" ? (:tool, :rescued) : (:noop, :unsolved))
        @test isempty(s.raw_regressions)
        # 기준 UNKNOWN → 무엇이든 NOOP + 인증 불가(분모에 남는다)
        s = S.select_repair("t0", :UNKNOWN, [c]; baseline_note = "UNKNOWN cause wall_timeout")
        @test s.selected === :noop && s.classification === :certification_unavailable && haskey(s.candidate_outcomes, "c")
        # identity mismatch(gap) → 기준 rollout 이 COMPLETE·FAIL 이어도 NOOP + 인증 불가
        for b in (:COMPLETE, :FAIL_WITHIN_BUDGET)
            s = S.select_repair("t0", b, [c]; gaps = ["identity: parent t0 world blocks differ: globals"])
            @test s.selected === :noop && s.classification === :certification_unavailable && s.baseline_outcome === :UNKNOWN
            @test any(r -> occursin("identity", r), s.reasons) && any(r -> occursin("baseline rollout was $(b)", r), s.reasons)
        end
    end
    # 후보 결과 기록: COMPLETE 인데 검사에서 떨어진 후보는 COMPLETE 로 적히지 않는다
    @test S.select_repair("t0", :FAIL_WITHIN_BUDGET, [kinds["complete_but_rejected"]]).candidate_outcomes["c"] === :REJECTED
    @test_throws ArgumentError S.candidate_outcome(cand("x", :FAIL_WITHIN_BUDGET, true))      # eligible ⟹ COMPLETE
    # 폐기 표시가 없으면(인증 공백 — wall·자원 한도) UNKNOWN 은 UNKNOWN 이다; discarded=false 도 같다
    @test S.candidate_outcome(cand("u", :UNKNOWN, false; discarded = false)) === :UNKNOWN
    @test S.DISCARDED_ENACTMENTS == (:partial, :threw, :unobservable, :registration_rejected) && !(:timeout in S.DISCARDED_ENACTMENTS)
    @test_throws ArgumentError S.select_repair("t0", :COMPLETE, [cand("a", nothing, false), cand("a", nothing, false)])
end

@testset "[2] 여러 후보: 최초 제출 순서(submission_index), XY 이동량으로 순위를 매기지 않는다" begin
    # 입력 순서가 아니라 submission_index 순서 — k=1 이 뒤에 있어도 먼저다. 이동량이 큰/작은 것은 입력에도 없다.
    cs = [cand("big_shift", :COMPLETE, true; k = 3, xy_shift = 9.0), cand("assign", :COMPLETE, true; k = 1, xy_shift = 0.0),
          cand("small_shift", :COMPLETE, true; k = 2, xy_shift = 0.1), cand("fails", :FAIL_WITHIN_BUDGET, false; k = 0)]
    s = S.select_repair("t0", :FAIL_WITHIN_BUDGET, cs)
    @test s.selected === :tool && s.selected_proposal_id == "assign"
    @test S.select_repair("t0", :FAIL_WITHIN_BUDGET, reverse(cs)).selected_proposal_id == "assign"
    # 동률이면 입력 순서
    @test S.select_repair("t0", :FAIL_WITHIN_BUDGET, [cand("x", :COMPLETE, true; k = 1), cand("y", :COMPLETE, true; k = 1)]).selected_proposal_id == "x"
    # 초반 진행 뒤 긴 정지·nav_blocked=0 뒤 정지: rollout 이 FAIL 이면 그 밖의 신호와 무관하게 선택되지 않는다
    cs = [cand("early_progress_then_stall", :FAIL_WITHIN_BUDGET, false; k = 1, closed_at_200 = 120),
          cand("nav_blocked0_then_stall", :FAIL_WITHIN_BUDGET, false; k = 2, nav_blocked = 0)]
    s = S.select_repair("t0", :FAIL_WITHIN_BUDGET, cs)
    @test s.selected === :noop && s.classification === :unsolved
end

@testset "[2b] 초반 진행 뒤 정지 · nav_blocked=0 뒤 정지 — trusted validator 가 원본 완료 조건으로 FAIL 을 낸다" begin
    root = mktempdir(); par = fake_parent(joinpath(root, "parent")); C = BR._json(joinpath(par, "contract.json"))
    C["node_ids"] = ["PC1", "n1", "n2", "n3"]; C["zone_keys"] = ["z"]
    function export!(id; closed, no_progress, n_blocked)
        d = mkpath(joinpath(root, id))
        wj(joinpath(d, "terminal.json"), Dict("iter" => 3001 + 200, "no_progress" => no_progress, "complete" => true,
            "terminal_reason" => "project_complete", "n_blocked" => n_blocked,
            "resume" => Dict("mismatched_blocks" => [], "dispatch_guard" => [], "fingerprint_mismatches" => [], "rvo_tie_watch" => []),
            "branch" => Dict("schema" => BR.EXPORT_SCHEMA, "id" => id, "checkpoint_id" => "t0",
                "sim_params" => C["sim_params"], "pi0_t0" => C["pi0"], "pi0_end" => C["pi0"],
                "ablation_counts" => Dict("ladder_zone_fired" => 0), "closed_node_ids" => closed, "audit" => Dict())))
        open(io -> println(io, JSON3.write(Dict("respec_history" => [], "recovery" => []))), joinpath(d, "shadow_MONITOR_IO.jsonl"), "w")
        sup = (exitcode = 0, termsignal = 0, timed_out = false, leftover = 0, wall_s = 1.0, cpu_s = 1.0)
        return BR.validate_branch(d, C; branch_id = id, sup)
    end
    # 초반에 거의 다 닫았지만(원본 ProjectComplete 는 못 닫음) 무진전 한도에 걸림 — worker 는 complete=true 라고 주장
    v = export!("early"; closed = ["n1", "n2", "n3"], no_progress = 3000, n_blocked = 3)
    @test v.report.outcome === :FAIL_WITHIN_BUDGET && v.report.terminal_reason === :no_progress_limit
    @test v.checks["claim_agrees"] === false
    v2 = export!("navzero"; closed = ["n1"], no_progress = 3000, n_blocked = 0)      # 존 해소(nav_blocked 0) 뒤 정지
    @test v2.report.outcome === :FAIL_WITHIN_BUDGET
    s = S.select_repair("t0", :FAIL_WITHIN_BUDGET, [cand("early", v.report.outcome, false), cand("navzero", v2.report.outcome, false; k = 2)])
    @test s.selected === :noop && s.candidate_outcomes == Dict("early" => :FAIL_WITHIN_BUDGET, "navzero" => :FAIL_WITHIN_BUDGET)
end

@testset "[3] SelectionReport 불변식(T7 강화)" begin
    @test_throws ArgumentError R.SelectionReport("t0", :FAIL_WITHIN_BUDGET, :tool, "p", :rescued, String[], Dict("p" => :REJECTED), String[])
    @test_throws ArgumentError R.SelectionReport("t0", :FAIL_WITHIN_BUDGET, :tool, "p", :rescued, String[], Dict{String,Symbol}(), String[])
    @test_throws ArgumentError R.SelectionReport("t0", :FAIL_WITHIN_BUDGET, :noop, nothing, :unsolved, ["q"], Dict("q" => :FAIL_WITHIN_BUDGET), ["x"])
    @test_throws ArgumentError R.SelectionReport("t0", :COMPLETE, :noop, nothing, :baseline_complete, ["q"], Dict("q" => :COMPLETE), String[])
    @test_throws ArgumentError R.SelectionReport("t0", :COMPLETE, :noop, nothing, :baseline_complete, String[], Dict("q" => :WEIRD), String[])
    @test R.SelectionReport("t0", :COMPLETE, :noop, nothing, :baseline_complete, ["q"], Dict("q" => :REJECTED), String[]).raw_regressions == ["q"]
end

@testset "[4] 상태 기계" begin
    walk(path) = foldl((a, b) -> S.transition(a, b), path[2:end]; init = path[1])
    @test walk([:CAPTURED, :IDENTITY_VERIFIED, :PROPOSALS_FROZEN, :BASELINE_AND_CANDIDATE_ROLLOUTS, :SELECTED_TOOL,
                :PRECOMMIT_VERIFIED, :COMMITTED, :REPLAY_CHECKED]) === :REPLAY_CHECKED
    @test walk([:CAPTURED, :IDENTITY_VERIFIED, :PROPOSALS_FROZEN, :BASELINE_AND_CANDIDATE_ROLLOUTS, :SELECTED_TOOL,
                :REJECT_CANDIDATE, :SELECTED_NOOP, :PRECOMMIT_VERIFIED, :COMMITTED, :REPLAY_CHECKED]) === :REPLAY_CHECKED
    @test walk([:CAPTURED, :CERTIFICATION_UNAVAILABLE, :SELECTED_NOOP, :COMMITTED, :REPLAY_CHECKED]) === :REPLAY_CHECKED
    for (a, b) in ((:CAPTURED, :SELECTED_TOOL), (:BASELINE_AND_CANDIDATE_ROLLOUTS, :COMMITTED), (:SELECTED_TOOL, :COMMITTED),
                   (:CERTIFICATION_UNAVAILABLE, :SELECTED_TOOL), (:REJECT_CANDIDATE, :SELECTED_TOOL), (:REPLAY_CHECKED, :COMMITTED))
        @test_throws ArgumentError S.transition(a, b)
    end
    @test Set(keys(S.TRANSITIONS)) == Set(S.STATES)
end

@testset "[5] certificate · stale 판정 · 같은 이름 재등록" begin
    root = mktempdir(); par = fake_parent(joinpath(root, "parent"))
    raw = prop("t7_same!", "function t7_same!(env)\n    return :a\nend")
    cdir = mkpath(joinpath(root, "cand-1"))
    wj(joinpath(cdir, "enactment.json"), fake_enactment(raw)); write(joinpath(cdir, "effect_trace.json"), "[]")
    judged = (; unobserved = ["terminal_precedence_vacuous: 3/3"])
    sel = S.select_repair("t0", :FAIL_WITHIN_BUDGET, [cand("p-t7_same!", :COMPLETE, true)])
    lim = BR.Limits(wall_s = 10, cpu_s = 10, mem_bytes = 10)
    env = Dict("DEMO_SEED" => "26", "OPENAI_API_KEY" => "zzz")
    gaps = S.checkpoint_gaps(BR._json(joinpath(par, "contract.json")), par)
    @test isempty(gaps)                                       # T5 이전 문구의 gap 은 task_contract.json digest 가 맞아 해소
    cert = S.build_certificate(; parent_dir = par, verify = okverify, selection = sel, baseline = rollout("noop", :FAIL_WITHIN_BUDGET),
                               gaps, launch_env = env, limits = lim, cand = (; raw, dir = cdir, rollout = rollout("p"), judged))
    for k in ("checkpoint", "config", "task", "proposal", "source", "params_sha256", "calls_sha256", "effect", "post_state_sha256",
              "continuation", "rng", "budget", "validators", "outcomes", "selection", "unobserved")
        @test cert[k] !== nothing
    end
    @test cert["rng"]["exogenous_seeds"] == Dict("DEMO_SEED" => "26") && !occursin("zzz", JSON3.write(cert))   # 비밀 값 없음
    @test cert["proposal"]["file_sha256"] == TC.digest(rt(raw)) && cert["certification_available"] === true
    @test cert["validators"]["effect"] == EffectValidation.EFFECT_VALIDATOR_VERSION
    @test "terminal_precedence_vacuous: 3/3" in cert["unobserved"]
    sha = S.certificate_sha256(cert)
    @test sha == S.certificate_sha256(rt(cert))               # 파일 왕복해도 같은 digest
    cur() = S.current_facts(par, okverify; campaign_dir = root)
    @test isempty(S.stale_reasons(cert, cur(); raw))
    # 같은 함수 이름을 다른 코드로 → stale
    raw2 = prop("t7_same!", "function t7_same!(env)\n    return :b\nend")
    @test any(r -> occursin("same name re-registered", r), S.stale_reasons(cert, cur(); raw = raw2))
    # 부모 t0 가 흔들림 / 파일이 바뀜 / campaign 정지 → stale
    @test any(r -> occursin("parent t0 changed", r), S.stale_reasons(cert, S.current_facts(par, merge(okverify, Dict("rng_equal" => false)); campaign_dir = root)))
    c = BR._json(joinpath(par, "contract.json")); c["parent_pid"] = 2; wj(joinpath(par, "contract.json"), c)
    @test any(r -> occursin("contract_sha256", r), S.stale_reasons(cert, cur()))
    c["parent_pid"] = 1; wj(joinpath(par, "contract.json"), c)
    S.stop_certification!(root, Dict("kind" => "test"))
    @test any(r -> occursin("campaign certification stopped", r), S.stale_reasons(cert, cur()))
    # 인증 불가로 발급된 certificate · NOOP certificate 로 도구 commit → stale
    cert2 = S.build_certificate(; parent_dir = par, verify = okverify, selection = S.select_repair("t0", :COMPLETE, []),
                                baseline = rollout("noop"), gaps = ["identity: x"], launch_env = env, limits = lim)
    rs = S.stale_reasons(cert2, S.current_facts(par, okverify; campaign_dir = mktempdir()); raw)
    @test any(r -> occursin("certification unavailable", r), rs) && any(r -> occursin("binds no proposal", r), rs)
end

@testset "[6] commit 대조: 조건부 코드의 다른 효과 · 숨은 상태 변경 · digest 위조" begin
    raw = prop("t7_probe!", "function t7_probe!(env)\n    return :ok\nend")
    a = fake_enactment(raw)
    @test isempty(S.compare_enactments(a, deepcopy(a)))
    ps2 = Dict{String,Any}("nodes" => Dict("a" => "RobotGo"), "closed" => String[])      # 조건부: 다른 효과
    m = S.compare_enactments(a, fake_enactment(raw; post = ps2, classes = ["geometry", "assignment"]))
    @test "post_state_sha256" in m && "effect_classes" in m
    m = S.compare_enactments(a, fake_enactment(raw; fields = ["globals.ConstructionBots.CAMERA_FOLLOW"]))     # 숨은 변경
    @test m == ["audit.fields_changed_by_action"]                                        # post-state 는 같다
    b = deepcopy(a); b["post_state"]["closed"] = String[]                                # digest 는 그대로, 상태만 위조
    @test "post_state_digest_self:b" in S.compare_enactments(a, b)
    b = deepcopy(a); b["body"]["steps"][1]["status"] = "threw"
    @test "body.steps" in S.compare_enactments(a, b)
    b = deepcopy(a); b["body"]["steps"][1]["detail"] = "other detail"; b["wall_s"] = 99.0   # 재현 대상이 아닌 값
    @test isempty(S.compare_enactments(a, b))
end

@testset "[7] 인증 전제: checkpoint gap · identity · native 의무" begin
    root = mktempdir()
    par = fake_parent(joinpath(root, "p1"); gaps = ["task_world: original task contract not supplied (T5)", "native: RVO pending"])
    @test S.checkpoint_gaps(BR._json(joinpath(par, "contract.json")), par) == ["native: RVO pending"]
    par2 = fake_parent(joinpath(root, "p2"); tc_ok = false)
    g = S.checkpoint_gaps(BR._json(joinpath(par2, "contract.json")), par2)
    @test any(x -> startswith(x, "task_world"), g) && any(x -> startswith(x, "task_contract unavailable"), g)
    @test isempty(S.identity_gaps(okverify))
    @test length(S.identity_gaps(Dict("mismatched_blocks" => ["globals"], "counters_equal" => false, "rng_equal" => false))) == 3
    d = mkpath(joinpath(root, "b"))
    @test !isempty(S.native_gaps(d))                                                       # terminal 없음 = 확인 불가
    tw(ws) = wj(joinpath(d, "terminal.json"), Dict("resume" => Dict("rvo_tie_watch" => ws)))
    tw([Dict("global" => "RVO", "ties" => [], "kd_restored" => false)]); @test isempty(S.native_gaps(d))
    tw([Dict("global" => "RVO", "ties" => [[1, 2]], "kd_restored" => true)]); @test isempty(S.native_gaps(d))
    tw([Dict("global" => "RVO", "ties" => [[1, 2]], "kd_restored" => false)]); @test length(S.native_gaps(d)) == 1
end

@testset "[8] replay 대조 · 보장 위반 → campaign 인증 정지" begin
    root = mktempdir()
    mk(id, rows; iter = 900, complete = true, ts = ps_a) = (d = mkpath(joinpath(root, id));
        open(io -> (println(io, "# iter\tloop"); foreach(r -> println(io, join(r, '\t')), rows)), joinpath(d, "trace.tsv"), "w");
        wj(joinpath(d, "terminal.json"), Dict("iter" => iter, "complete" => complete, "terminal_reason" => "project_complete",
                                              "branch" => Dict("task_state" => ts))); d)
    rows = [[i, "l$(i)", "c", "s", "sc", "r", "g", "rng$(i)"] for i in 1:5]
    a = mk("ref", rows)
    @test S.replay_compare(a, mk("same", [vcat(r[1:7], ["other_rng"]) for r in rows]); t0 = 1).match      # rng 열은 비교하지 않는다
    bad = deepcopy(rows); bad[4][2] = "PERTURBED"
    r = S.replay_compare(a, mk("div", bad); t0 = 1)
    @test !r.match && r.trace.first_divergent_iter == 4 && r.trace.divergent_columns == ["loop"]
    @test !S.replay_compare(a, mk("short", rows[1:4]); t0 = 1).match                                  # 종료 시점이 다름
    @test !S.replay_compare(a, mk("ts", rows; ts = Dict("x" => 1)); t0 = 1).match                    # terminal task_state
    @test !S.replay_compare(a, mk("it", rows; iter = 901); t0 = 1).match
    camp = mktempdir()
    @test !S.certification_stopped(camp)
    S.stop_certification!(camp, Dict("kind" => "post_activation_replay_mismatch", "reasons" => r.reasons))
    S.stop_certification!(camp, Dict("kind" => "second"))
    @test S.certification_stopped(camp) && length(JSON3.read(read(joinpath(camp, S.STOP_FILE), String))) == 2
end

@testset "[9] judge 교차검사: proposal_sha256 · checkpoint_id · post_state_sha256" begin
    root = mktempdir(); par = fake_parent(joinpath(root, "parent"))
    contract = BR._json(joinpath(par, "contract.json"))
    raw = prop("t7_x!", "function t7_x!(env)\n    return :ok\nend")
    pf = joinpath(root, "b.proposal.json"); wj(pf, raw)
    X = fake_enactment(raw)
    @test isempty(TX.cross_check(X, contract, pf))
    @test any(r -> occursin("proposal_sha256", r), TX.cross_check(merge(X, Dict("proposal_sha256" => "f"^64)), contract, pf))
    @test any(r -> occursin("checkpoint_id", r), TX.cross_check(merge(X, Dict("checkpoint_id" => "t9")), contract, pf))
    Y = deepcopy(X); Y["post_state"]["closed"] = String[]
    @test any(r -> occursin("post_state_sha256", r), TX.cross_check(Y, contract, pf))
    @test any(r -> occursin("proposal_id", r), TX.cross_check(merge(X, Dict("proposal_id" => "p-other")), contract, pf))
    @test any(r -> occursin("missing", r), TX.cross_check(X, contract, joinpath(root, "nope.json")))
    wj(pf, prop("t7_x!", "function t7_x!(env)\n    return :other\nend"))                    # 같은 이름, 다른 코드의 파일
    @test any(r -> occursin("proposal_sha256", r), TX.cross_check(X, contract, pf))
end


"""
t0 부모의 대역(시험용): 제어 파일 규약(`control/<n>.cmd` → `<n>.out.json`)에 답하는 비동기 task + `sleep` 프로세스.
생성 코드·CB 없이 supervisor 의 상태 기계·finally 경로를 잰다.
"""
function fake_live_parent(dir; verify = okverify)
    fake_parent(dir); mkpath(joinpath(dir, "control"))
    p = run(`sleep 600`; wait = false)
    seen = String[]
    @async while process_running(p)
        f = joinpath(dir, "control", "$(length(seen) + 1).cmd")
        if isfile(f)
            cmd = strip(read(f, String)); push!(seen, cmd)
            out = joinpath(dir, "control", "$(length(seen)).out.json")
            cmd == "verify" ? wj(out, verify) : wj(out, Dict("cmd" => cmd))
            cmd in ("resume", "exit") && kill(p)
        end
        sleep(0.05)
    end
    return (process = p, dir = dir, token = "fake", log = devnull), seen
end
lim0 = BR.Limits(wall_s = 30, cpu_s = 10, mem_bytes = 10)

@testset "[10] identity mismatch → rollout 없이 NOOP 재개, 분모에는 인증 불가로 남는다(supervise_episode!)" begin
    root = mktempdir()
    par, seen = fake_live_parent(joinpath(root, "parent"); verify = Dict("mismatched_blocks" => ["globals"], "counters_equal" => true, "rng_equal" => true))
    sv = S.Supervision(par; outroot = joinpath(root, "out"), launch_env = Dict("DEMO_SEED" => "1"), limits = lim0)
    S.supervise_episode!(sv; proposals = [prop("t7_a!", "function t7_a!(env)\n    return :a\nend")])
    @test [t["to"] for t in sv.transitions] == ["CAPTURED", "CERTIFICATION_UNAVAILABLE", "SELECTED_NOOP", "COMMITTED", "REPLAY_CHECKED"]
    @test sv.selection.classification === :certification_unavailable && sv.selection.candidate_outcomes == Dict("p-t7_a!" => :UNKNOWN)
    @test sv.baseline === nothing && isempty(sv.candidates)                    # 흔들린 checkpoint 에서 분기를 굴리지 않는다
    @test sv.certificate["certification_available"] === false && sv.replay.certified === false && sv.replay.violation === false
    @test seen == ["verify", "verify", "resume"] && !process_running(par.process)
    @test !S.certification_stopped(sv.campaign_dir) && isfile(joinpath(sv.outroot, "supervision.json"))
end

@testset "[11] supervisor 예외 → finally 가 t0 부모를 은퇴시킨다(고아 없음 — T4 우려)" begin
    root = mktempdir()
    par, seen = fake_live_parent(joinpath(root, "parent"))
    sv = S.Supervision(par; outroot = joinpath(root, "out"), launch_env = Dict{String,String}(), limits = lim0)
    @test_throws KeyError S.supervise_episode!(sv; proposals = [Dict{String,Any}("no_proposal_id" => 1)])
    @test seen == ["verify", "exit"] && !process_running(par.process)
end

@testset "[12] campaign 인증 정지 뒤의 사건은 인증 불가로 돈다" begin
    root = mktempdir()
    S.stop_certification!(joinpath(root, "campaign"), Dict("kind" => "post_activation_replay_mismatch"))
    par, seen = fake_live_parent(joinpath(root, "parent"))
    sv = S.Supervision(par; outroot = joinpath(root, "out"), launch_env = Dict{String,String}(), limits = lim0,
                       campaign_dir = joinpath(root, "campaign"))
    try
        S.verify_identity!(sv)
        @test sv.state === :CERTIFICATION_UNAVAILABLE && any(g -> occursin("campaign certification stopped", g), sv.gaps)
    finally
        S.retire!(sv)
    end
    @test !process_running(par.process)
end


@testset "[13] 기준 NOOP 이 UNKNOWN(wall_timeout) → 인증 불가 NOOP 재개, 위반 아님, campaign 정지 없음(T7 fix)" begin
    root = mktempdir()
    par, seen = fake_live_parent(joinpath(root, "parent"))
    sv = S.Supervision(par; outroot = joinpath(root, "out"), launch_env = Dict("DEMO_SEED" => "1"), limits = lim0,
                       campaign_dir = joinpath(root, "campaign"))
    try
        S.verify_identity!(sv); @test sv.state === :IDENTITY_VERIFIED
        S.freeze!(sv, Any[])
        # rollouts! 대역: 기준 분기가 wall timeout 으로 UNKNOWN(terminal 없음)
        sv.baseline = (report = rollout("noop", :UNKNOWN; steps = 0), violations = String[], checks = Dict{String,Any}(),
                       dir = mkpath(joinpath(sv.outroot, "noop")), supervisor = (wall_s = 30.0, cpu_s = 1.0, timed_out = true))
        S.advance!(sv, :BASELINE_AND_CANDIDATE_ROLLOUTS; why = "stub")
        S.select!(sv)
        S.commit!(sv)
    finally
        S.retire!(sv)
    end
    @test sv.selection.classification === :certification_unavailable && sv.selection.selected === :noop
    @test any(g -> startswith(g, "baseline UNKNOWN: wall_timeout"), sv.gaps)
    @test [t["to"] for t in sv.transitions][end-3:end] == ["CERTIFICATION_UNAVAILABLE", "SELECTED_NOOP", "COMMITTED", "REPLAY_CHECKED"]
    @test sv.certificate["certification_available"] === false                    # certificate 와 선택이 같은 말을 한다
    @test sv.certificate["selection"]["classification"] == "certification_unavailable"
    @test sv.replay.certified === false && sv.replay.violation === false && sv.replay.match === false
    @test !S.certification_stopped(sv.campaign_dir) && !isfile(joinpath(sv.campaign_dir, S.STOP_FILE))
    @test seen == ["verify", "verify", "resume"] && !process_running(par.process)
    # 같은 사실을 build_certificate 에 직접: gap 이 비어 있어도 인증 불가 분류면 인증 불가
    c = S.build_certificate(; parent_dir = par.dir, verify = okverify, selection = S.select_repair("t0", :UNKNOWN, []),
                            baseline = rollout("noop", :UNKNOWN), gaps = String[], launch_env = Dict{String,String}(), limits = lim0)
    @test c["certification_available"] === false
end

end
