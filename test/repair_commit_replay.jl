# =============================================================================
# test/repair_commit_replay.jl — T7 commit worker 전환의 에피소드 게이트(단독 실행, runtests.jl 미포함; 한 판 ≈ 1 시간).
#
#   julia +lts --project=. test/repair_commit_replay.jl <model> <case> <seed> <outroot>
#
# 실제 worker(T4 부모/분기 · T6 격리 집행)로 §7.3 commit 계약을 잰다. 부모 둘, 전부 순차·한 디렉터리.
#   A. 상태 기계를 단계별로: 신원 확인 → 동결(같은 함수 이름 두 후보) → NOOP 두 번(잡음 바닥) + 후보 rollout → 자연 선택.
#      이 fixture 의 NOOP 은 완주하므로 자연 선택은 NOOP 이다. commit 기계를 재려고 **강제 선택**(아래 FORCED) 한 도구
#      certificate 로: stale(같은 이름·다른 코드) · commit throw · 조건부 코드의 다른 효과 · 숨은 상태 변경 — 넷 다 활성화되지
#      않고 부모 t0 가 그대로여야 한다 → 마지막에 정상 commit: 활성화 → 부모 은퇴 → 활성 worker 궤적·종료 = 검증 분기.
#   B. `commit!`(상태 기계)로: 강제 도구 선택 + commit throw → REJECT_CANDIDATE → 손대지 않은 부모에서 NOOP 재개 →
#      부모 재개 궤적 = NOOP 기준 분기(REPLAY_CHECKED).
# 🔴 FORCED: 실제 TOOL 선택은 기준 NOOP 이 FAIL 인 판에서만 난다(T8/T10 의 코호트). 여기서는 commit 기계만 재므로
#    SelectionReport 를 손으로 만들고 사유에 적는다 — 그 certificate 의 `outcomes.baseline` 은 실제 값(COMPLETE)을 싣는다.
# 도구 source 는 손으로 쓴 시험 fixture 다(생성 코드가 아니다). 조건은 worker 의 `tempdir()`(= 분기 디렉터리) 이름으로 건다 —
#   검증 분기와 commit worker 가 같은 코드로 다른 세계 조건을 보게 하는 가장 작은 방법이다(ENV 는 제안 문이 막는다).
# =============================================================================
using Test, JSON3, SHA
include(joinpath(@__DIR__, "..", "src", "verification", "repair_supervisor.jl"))
const S = RepairSupervisor
const BR = BranchRunner
const TX = ToolExecution
const TC = TaskContract
const R = RepairTypes

model, case, seed, root = ARGS[1], ARGS[2], parse(Int, ARGS[3]), abspath(ARGS[4])
occursin("zz", root) && error("outroot must not contain the marker prefix `zz`")
mkpath(root)
env = BR.pi0_launch_env(model, case, seed)
LIM = BR.Limits(wall_s = 3600, cpu_s = 7200, mem_bytes = 24 * 2^30)
log(x...) = (println("[t7 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

const SHIFT = """
    T = CoordinateTransformations.Translation(dx, dy, 0.0)
    ts = Any[]
    for aid in sort!(collect(keys(env.staging_circles)); by = string)
        push!(ts, start_config(get_node(env.sched, AssemblyComplete(get_node(env.scene_tree, aid)))))
    end
    top(t) = (c = t; while !has_parent(c, c); c = get_parent(c); any(x -> x === c, ts) && return false; end; true)
    for t in ts
        top(t) && set_desired_global_transform!(t, T ∘ global_transform(t))
    end
    for aid in collect(keys(env.staging_circles))
        b = env.staging_circles[aid]
        env.staging_circles[aid] = LazySets.Ball2(Vector{Float64}(get_center(b)[1:2]) .+ [dx, dy], Float64(get_radius(b)))
    end
"""
# 기하(빌드 강체 이동, resync 는 하니스가) + 도구 안 engine 3 step(trusted adapter) — t0→t1 인계가 실제로 생긴다.
const PROBE = """
function t7_probe!(env; dx::Float64 = 0.3, dy::Float64 = -0.2)
    td = tempdir()
    occursin("zzcond", td) && (dx = 0.1)
$(SHIFT)    occursin("zzthrow", td) && error("t7 commit-only throw after the first state change")
    for _ in 1:3
        step_environment!(env)
    end
    occursin("zzhidden", td) && (CAMERA_FOLLOW[] = !CAMERA_FOLLOW[])
    return :shifted_and_stepped
end"""
# 같은 함수 이름, 다른 코드(진행만).
const SAME = """
function t7_probe!(env)
    for _ in 1:3
        step_environment!(env)
    end
    return :stepped
end"""
prop(code, id, k, cid) = Dict{String,Any}("schema_version" => "tool-proposal/1", "checkpoint_id" => cid, "proposal_id" => id,
    "submission_index" => k, "tool_name" => "t7_probe!", "specification" => Dict("mechanism" => "t7 fixture $(id)"),
    "impl_name" => "t7_probe!", "impl_code" => code, "params" => Dict{String,Any}(),
    "calls" => [Dict{String,Any}("primitive" => "t7_probe!", "args" => Dict{String,Any}())])
vok(v) = isempty(v["mismatched_blocks"]) && v["counters_equal"] === true && v["rng_equal"] === true
forced(sv, pid) = R.SelectionReport(String(sv.contract["checkpoint_id"]), :FAIL_WITHIN_BUDGET, :tool, pid, :rescued, String[],
    Dict(pid => :COMPLETE), ["FORCED (test): the fixture's NOOP completes; selection forced to exercise the commit machinery"])
function forced_cert(sv, pid)
    c = sv.candidates[pid]
    f = only(filter(f -> f["proposal_id"] == pid, sv.frozen))
    cert = S.build_certificate(; parent_dir = sv.parent.dir, verify = sv.verify0, selection = forced(sv, pid),
        baseline = sv.baseline.report, gaps = unique(sv.gaps), launch_env = env, limits = LIM,
        cand = (; raw = f["raw"], dir = c.dir, rollout = c.exec.run.report, judged = c.exec.judged))
    return cert, S.certificate_sha256(cert), f["raw"]
end
cr(r) = Dict{String,Any}("status" => String(r.report.status), "activated" => r.activated,
    "post_state_match" => r.report.post_state_match, "replay_match" => r.report.replay_match, "reasons" => r.report.reasons,
    "mismatches" => r.precommit === nothing ? nothing : r.precommit.mismatches,
    "precommit_ok" => r.precommit === nothing ? nothing : r.precommit.judged.precommit_ok,
    "handover" => r.handover)

camp = joinpath(root, "campaign")
A = Dict{String,Any}(); B = Dict{String,Any}()

# ----------------------------------------------------------------------------- 부모 A
parA = BR.start_parent(joinpath(root, "A", "parent"), env)
svA = nothing
try
    BR.wait_held(parA)
    global svA = S.Supervision(parA; outroot = joinpath(root, "A"), launch_env = env, limits = LIM, campaign_dir = camp)
    cid = String(svA.contract["checkpoint_id"])
    log("A: parent held at t0 iter=", svA.contract["t0_iter"])
    S.verify_identity!(svA); log("A: ", svA.state, " gaps=", svA.gaps)
    S.freeze!(svA, [prop(SAME, "p-same", 1, cid), prop(PROBE, "p-probe", 2, cid)])
    S.rollouts!(svA); log("A: rollouts baseline=", svA.baseline.report.outcome, " gaps=", svA.gaps,
                          " cands=", Dict(k => (v.outcome, v.eligible) for (k, v) in svA.candidates))
    S.select!(svA); log("A: natural selection ", svA.selection.selected, " ", svA.selection.classification)
    A["natural"] = S.selection_dict(svA.selection); A["natural_state"] = String(svA.state)
    A["states_before_commit"] = [t["to"] for t in svA.transitions]
    A["candidates"] = S.summary(svA)["candidates"]
    A["noise_floor_gap"] = [g for g in svA.gaps if startswith(g, "noise floor")]
    cert, sha, raw = forced_cert(svA, "p-probe")
    BR._write(joinpath(svA.outroot, "certificate.forced.json"), cert)
    A["cert_sha"] = sha; A["cert_t1"] = cert["continuation"]["t1_iter"]
    verif = svA.candidates["p-probe"].dir
    pdig0 = BR.dir_digest(parA.dir)
    ct(id; r = raw) = S.commit_tool!(; parent = parA, cert, cert_sha = sha, raw = r, verif_dir = verif, outroot = svA.outroot,
                                     commit_id = id, launch_env = env, limits = LIM, campaign_dir = camp)
    A["verify"] = Dict{String,Any}()
    for (k, id, r) in (("stale_same_name", "commit-stale", svA.frozen[1]["raw"]), ("throw", "commit-zzthrow", raw),
                       ("cond", "commit-zzcond", raw), ("hidden", "commit-zzhidden", raw))
        log("A: commit ", id)
        x = ct(id; r)
        A[k] = cr(x); A[k]["worker_dir_exists"] = isdir(joinpath(svA.outroot, id))
        A[k]["commit_enactment"] = isfile(joinpath(svA.outroot, id, "enactment.json")) ?
            (e = BR._json(joinpath(svA.outroot, id, "enactment.json")); Dict("status" => e["status"], "post_state_sha256" => get(e, "post_state_sha256", nothing),
             "fields" => get(get(e, "audit", Dict()), "fields_changed_by_action", nothing))) : nothing
        A["verify"][k] = BR.parent_command(parA, "verify")
        log("  → ", A[k]["status"], " activated=", A[k]["activated"], " reasons=", first(A[k]["reasons"], 3))
    end
    A["parent_dir_unchanged"] = BR.dir_digest(parA.dir) == pdig0
    log("A: commit commit-ok")
    x = ct("commit-ok")
    A["ok"] = cr(x)
    A["ok_active_world"] = isfile(joinpath(svA.outroot, "commit-ok.active_world.json"))
    A["parent_alive_after_activation"] = process_running(parA.process)
    A["verif_enactment"] = BR._json(joinpath(verif, "enactment.json"))["post_state_sha256"]
    A["same_enactment"] = BR._json(joinpath(svA.candidates["p-same"].dir, "enactment.json"))["post_state_sha256"]
    A["ok_enactment"] = BR._json(joinpath(svA.outroot, "commit-ok", "enactment.json"))["post_state_sha256"]
    log("  → ", A["ok"]["status"], " replay=", A["ok"]["replay_match"], " reasons=", A["ok"]["reasons"])
    # 보장 위반 검출기를 실제 산출물에 대고: 활성 worker trace 한 줄을 흔든 사본 → 불일치 → campaign 정지(별도 디렉터리)
    pert = mkpath(joinpath(root, "perturbed"))
    cp(joinpath(svA.outroot, "commit-ok", "terminal.json"), joinpath(pert, "terminal.json"))
    ls = readlines(joinpath(svA.outroot, "commit-ok", "trace.tsv"))
    i = findfirst(l -> !startswith(l, "#") && parse(Int, first(split(l, '\t'))) == svA.contract["t0_iter"] + 10, ls)
    f = split(ls[i], '\t'); f[2] = "PERTURBED"; ls[i] = join(f, '\t')
    write(joinpath(pert, "trace.tsv"), join(ls, "\n") * "\n")
    rp = S.replay_compare(verif, pert; t0 = svA.contract["t0_iter"])
    scamp = joinpath(root, "campaign-perturbed")
    rp.match || S.stop_certification!(scamp, Dict("kind" => "post_activation_replay_mismatch (planted)", "reasons" => rp.reasons))
    A["perturbed"] = Dict("match" => rp.match, "reasons" => rp.reasons, "stopped" => S.certification_stopped(scamp))
finally
    svA === nothing ? (process_running(parA.process) && BR.parent_command(parA, "exit")) : S.retire!(svA)
end
BR._write(joinpath(root, "t7_A.json"), A)

# ----------------------------------------------------------------------------- 부모 B
parB = BR.start_parent(joinpath(root, "B", "parent"), env)
svB = nothing
try
    BR.wait_held(parB)
    global svB = S.Supervision(parB; outroot = joinpath(root, "B"), launch_env = env, limits = LIM, campaign_dir = camp)
    cid = String(svB.contract["checkpoint_id"])
    nf = isempty(A["noise_floor_gap"])                 # 같은 칸(A)에서 잰 잡음 바닥을 쓴다
    S.verify_identity!(svB; noise_floor = nf)
    S.freeze!(svB, [prop(PROBE, "p-probe", 1, cid)])
    S.rollouts!(svB; noise_floor = nf)
    B["natural"] = S.selection_dict(S.select_repair(cid, svB.baseline.report.outcome,
        [(; proposal_id = "p-probe", submission_index = 1, outcome = svB.candidates["p-probe"].outcome,
            eligible = svB.candidates["p-probe"].eligible)]; gaps = unique(svB.gaps)))
    cert, sha, _ = forced_cert(svB, "p-probe")
    svB.selection = forced(svB, "p-probe"); svB.certificate = cert; svB.certificate_sha256 = sha
    S.advance!(svB, :SELECTED_TOOL; why = "FORCED (test): exercise commit failure → NOOP resume")
    log("B: commit! (throw) from ", svB.state)
    S.commit!(svB; commit_id = "commit-zzthrow")
    B["states"] = [t["to"] for t in svB.transitions]
    B["commit"] = cr(svB.commit)
    B["replay"] = Dict("match" => svB.replay.match, "reasons" => svB.replay.reasons, "certified" => svB.replay.certified,
                       "violation" => svB.replay.violation)
    B["parent_terminal"] = BR._json(joinpath(parB.dir, "terminal.json"))
    B["baseline"] = BR.report_dict(svB.baseline)
    BR._write(joinpath(svB.outroot, "supervision.json"), S.summary(svB))
    log("B: ", svB.state, " replay=", svB.replay.match, " ", svB.replay.reasons)
finally
    svB === nothing ? (process_running(parB.process) && BR.parent_command(parB, "exit")) : S.retire!(svB)
end
BR._write(joinpath(root, "t7_B.json"), B)

has(v, p) = any(x -> occursin(p, x), v)
@testset "T7 commit worker / activation / replay ($(model) $(case) s$(seed))" begin
    @testset "A: 신원·동결·rollout·자연 선택" begin
        @test A["states_before_commit"][1:5] == ["CAPTURED", "IDENTITY_VERIFIED", "PROPOSALS_FROZEN",
                                                 "BASELINE_AND_CANDIDATE_ROLLOUTS", A["natural_state"]]
        @test isempty(A["noise_floor_gap"])                                   # 두 NOOP 분기가 같다(잡음 바닥)
        @test A["natural"]["baseline_outcome"] == "COMPLETE" && A["natural"]["selected"] == "noop"   # NOOP 이 완주하는 판
        @test A["candidates"]["p-probe"]["eligible"] === true                 # 강제 commit 의 전제: 검증 분기는 통과였다
        @test A["same_enactment"] != A["verif_enactment"]                    # 같은 이름, 다른 코드 → 다른 효과
    end
    @testset "A: commit 이전 실패는 원본에 영향이 없다(부모 t0 그대로, 활성화 없음)" begin
        for k in ("stale_same_name", "throw", "cond", "hidden")
            @test A[k]["status"] == "aborted_resumed_noop" && A[k]["activated"] === false
            @test vok(A["verify"][k])
        end
        @test A["parent_dir_unchanged"] === true
        # stale: 같은 이름을 다른 코드로 → worker 를 띄우지도 않는다
        @test has(A["stale_same_name"]["reasons"], "same name re-registered") && A["stale_same_name"]["worker_dir_exists"] === false
        # commit throw: t1 에 닿지 못함(폐기)
        @test has(A["throw"]["reasons"], "never reached t1") && A["throw"]["commit_enactment"]["status"] == "partial"
        # 조건부 코드: 같은 코드·같은 checkpoint 인데 다른 효과 → post-state 대조에서 멈춘다
        @test A["cond"]["post_state_match"] === false && "post_state_sha256" in A["cond"]["mismatches"]
        # 숨은 변경: post-state 는 같지만 trusted 검사와 필드 감사 대조가 잡는다
        @test A["hidden"]["post_state_match"] === true && "audit.fields_changed_by_action" in A["hidden"]["mismatches"]
        @test A["hidden"]["precommit_ok"] === false && has(A["hidden"]["reasons"], "CAMERA_FOLLOW")
    end
    @testset "A: 정상 commit — 같은 코드를 새 worker 에서 재생 → 활성화 → 같은 continuation" begin
        ok = A["ok"]
        @test ok["status"] == "committed" && ok["activated"] === true && ok["post_state_match"] === true && ok["replay_match"] === true
        @test A["ok_enactment"] == A["verif_enactment"] && A["ok_active_world"] && A["parent_alive_after_activation"] === false
        h = ok["handover"]
        @test h["t0_iter"] == A["cert_t1"] - 3 && h["t1_iter"] == A["cert_t1"] && h["engine_steps"] == 3   # t1 을 t0 로 적지 않는다
        @test count(e -> e["kind"] == "pre_step", h["handover"]["events"]) == 3 && h["parent"]["retired"] === true
        @test h["handover"]["ledger"]["active_bytes_at_t1"] isa Integer
    end
    @testset "A: 활성화 뒤 불일치는 은폐하지 않는다(심은 한 줄 → 보장 위반 → campaign 정지)" begin
        @test A["perturbed"]["match"] === false && has(A["perturbed"]["reasons"], "trajectory diverges") && A["perturbed"]["stopped"] === true
        @test !S.certification_stopped(camp)                                  # 실제 campaign 은 멀쩡하다
    end
    @testset "B: commit throw → REJECT_CANDIDATE → 손대지 않은 원래 세계에서 NOOP 재개 → replay" begin
        @test B["states"][end-5:end] == ["SELECTED_TOOL", "REJECT_CANDIDATE", "SELECTED_NOOP", "PRECOMMIT_VERIFIED", "COMMITTED", "REPLAY_CHECKED"]
        @test B["commit"]["status"] == "aborted_resumed_noop" && B["commit"]["activated"] === false
        @test B["replay"]["match"] === true && B["replay"]["certified"] === true && B["replay"]["violation"] === false
        @test B["parent_terminal"]["complete"] === (B["baseline"]["outcome"] == "COMPLETE")
        @test B["parent_terminal"]["iter"] - svB.contract["t0_iter"] == B["baseline"]["sim_steps"]
    end
end
