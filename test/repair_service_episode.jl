# =============================================================================
# test/repair_service_episode.jl — T9 끝까지: **가짜 LM** 서비스 → production render_demo.jl(shadow) → 일회용 observe worker →
# `/zone_repair/propose` → T6 preflight worker → (t0 거절이 있으면) `/zone_repair/revise` → 후보 동결 → supervisor(NOOP·후보
# 전체 rollout·선택) → 원래 세계 NOOP 재개. 단독 실행, runtests.jl 미포함(≈30 분/판).
#
#   julia +lts --project=. test/repair_service_episode.jl <root> <offdir> general|geometry
#
# 🔴 유료 호출 0: 서비스는 `test/fixtures/repair_verification/fake_lm_service.py`(진짜 dspy_service 앱 + ScriptedLM)이고, 자격 증명
#    모양 env 를 전부 지운 최소 env 로 띄우며, `/__fake_lm_stats.provider_calls == 0` 을 단언한다(프로바이더 입구가 불리면 센다).
# `<offdir>` = T8 `run_off.sh` 의 off 기준 판(`pre-plain`) — shadow 의 원래 세계 실제 스트림이 그것과 바이트 동일해야 한다.
# =============================================================================
using Test, JSON3, SHA, Sockets
include(joinpath(@__DIR__, "..", "src", "verification", "repair_runtime.jl"))
const RT = RepairRuntime
const BR = BranchRunner
const R = RepairTypes
import HTTP
const ROOT = BR.ROOT
const RENDER = joinpath(ROOT, "tools", "monitor", "render_demo.jl")
const PI0CELL = merge(BR.PI0, Dict("DEMO_OOD" => "none", "DEMO_ZONE" => "1", "DEMO_MODEL" => "tractor.mpd",
                                   "DEMO_SEED" => "26", "DEMO_ZONE_SEED" => "26", "DEMO_CASE_TAG" => "pi0_zone"))
log(x...) = (println("[t9 ", Libc.strftime("%H:%M:%S", time()), "] ", x...); flush(stdout))

root, offdir, arm = abspath(ARGS[1]), abspath(ARGS[2]), ARGS[3]
arm in ("general", "geometry") || error("arm must be general|geometry")
mkpath(root)
const STREAM = "tractor__pi0_zone_s26_z26.jsonl"
off_stream = joinpath(offdir, "pre-plain", "out", "streams", STREAM)
off_score = only(filter(l -> startswith(l, "[score] "), readlines(joinpath(offdir, "pre-plain", "run.log"))))

function render(env::AbstractDict; logfile)
    e = merge(BR.base_env(), Dict{String,String}(String(k) => String(v) for (k, v) in env))
    open(logfile, "w") do io
        p = run(pipeline(ignorestatus(Cmd(setenv(`$(BR.JULIA) --project=$ROOT $RENDER`, e); dir = ROOT)); stdout = io, stderr = io); wait = false)
        t = time()
        while process_running(p)
            time() - t > 3 * 3600 && (kill(p); break)
            sleep(2)
        end
        wait(p)
        return (code = p.exitcode, out = read(logfile, String))
    end
end

# ---- 가짜 LM 서비스(최소 env — 자격 증명 없음) ----------------------------------------------------------------
port = (s = listen(ip"127.0.0.1", 0); p = Int(getsockname(s)[2]); close(s); p)
url = "http://127.0.0.1:$(port)"
ledger = joinpath(root, "service_ledger.jsonl")
senv = Dict("HOME" => ENV["HOME"], "PATH" => ENV["PATH"], "LANG" => "C.UTF-8", "REPAIR_ABLATION" => "all",
            "FAKE_REPAIR_SCRIPT" => arm, "SYNTH_RECORD_LOG" => ledger, "DSPY_CACHE" => "0")
slog = open(joinpath(root, "fake_service.log"), "w")
svc = run(pipeline(Cmd(setenv(`$(joinpath(ROOT, ".venv", "bin", "python")) test/fixtures/repair_verification/fake_lm_service.py $port`, senv);
                       dir = ROOT); stdout = slog, stderr = slog); wait = false)
stats() = JSON3.read(String(HTTP.get(url * "/__fake_lm_stats"; retries = 0).body), Dict{String,Any})
for _ in 1:120
    (try HTTP.get(url * "/health"; retries = 0, readtimeout = 5).status == 200 catch; false end) && break
    sleep(1)
end
log("fake service up at ", url, " arm=", arm)

zr = joinpath(root, "zr")
st0 = stats()
r = try
    render(merge(PI0CELL, Dict("ZONE_REPAIR_VERIFICATION" => "shadow", "DSPY_URL" => url, "ZONE_REPAIR_ARM" => arm,
                               "ZONE_REPAIR_MAX_TOTAL_TOKENS" => "20000", "ZONE_REPAIR_MAX_COST_USD" => "1.0",
                               "DEMO_OUT_DIR" => joinpath(root, "out"), "ZONE_REPAIR_DIR" => zr)); logfile = joinpath(root, "render.log"))
finally
    global st1 = try stats() catch e; Dict{String,Any}("error" => sprint(showerror, e)) end
    kill(svc); close(slog)
end
log("render done code=", r.code)

@testset "T9 service episode ($(arm), tractor zone s26, fake LM)" begin
    ep = BR._json(joinpath(zr, "episode.json"))
    ps = ep["proposal_source"]
    fl = BR._json(joinpath(zr, "proposal_source", "frozen_list.json"))
    sup = ep["supervision"]
    @test r.code == 0 && ep["exit_code"] == 0 && ep["source"] == "service"
    # 🔴 유료 0: 프로바이더 입구 0회, 자격 증명 env 없음, 가짜 LM 은 정확히 네 단계(observe·design·compose·compose_revision)
    @test st0["provider_calls"] == 0 && st1["provider_calls"] == 0 && st1["credential_env_left"] == []
    @test st1["stages"] == ["observe", "design", "compose", "compose_revision"] && st1["remaining_script"] == 0
    @test ps["status"] == "ok" && ps["gaps"] == String[] && ep["decision_gaps"] == String[]
    @test ps["model_outcome"] == "candidates: 2"                                   # 모델 쪽 결과(서비스 오류 아님)
    # T9 fix: 존 복구 전용 배정 센서 — 관측에 있고, 읽기 전용(실측), 지문이 기록·provenance 에 있고, observe 프롬프트에 닿았다
    @test st1["observe_has_bindings"] === true && st1["max_retries_seen"] == ["0"]
    ro = ps["observation"]["sensor_readonly"]
    @test ro["fields_changed"] == String[] && ro["rng_equal"] === true && ro["fields_compared"] > 100
    @test ps["observation"]["robot_bindings_sensor"] == "robot-bindings/1" && ps["observation"]["robot_bindings_error"] === nothing
    @test ps["responses"][1]["observation_stamps"]["observation_sensors"]["robot_bindings"]["version"] == "robot-bindings/1"
    # t0 관측은 일회용 observe worker 가 만들었다(부모가 아니다)
    ob = BR._json(joinpath(zr, "proposal_source", "observe", "observation.json"))
    @test ob["request"]["kind"] == "zone" && !isempty(ob["request"]["nl"]) && !isempty(ob["geometry_context"]["configs"])
    @test !isempty(ob["robot_bindings"]) && all(r -> !haskey(r, "error"), ob["robot_bindings"])
    @test !haskey(ob["request"], "robot_bindings")          # 결정 레인 페이로드(`service_payload`)는 그대로
    @test ob["checkpoint_id"] == BR._json(joinpath(zr, "parent", "contract.json"))["checkpoint_id"]
    # 두 원장: 서비스 원장 둘째 응답에서 호출 4 / 후보 3
    resp = ps["responses"]
    @test length(resp) == 2 && resp[1]["ledger"]["calls_used"] == 3 && resp[2]["ledger"]["calls_used"] == 4
    @test resp[2]["ledger"]["submitted"] == 3 && ps["revision"]["attempted"] === true
    rows = [JSON3.read(l, Dict{String,Any}) for l in eachline(ledger) if !isempty(strip(l))]
    @test [x["row_type"] for x in rows] == ["zone_repair_propose", "zone_repair_revise"]
    subs = Dict(s["submission_index"] => s for s in fl["submissions"])
    ids = fl["frozen_proposal_ids"]
    if arm == "general"
        # 비기하 후보(release)가 일반 source 후보로 끝까지: 서비스 → 동결 → t0 preflight(T6 worker) → 전체 rollout 판정
        @test length(ids) == 3 && endswith(ids[1], "-s1") && endswith(ids[3], "-s3")
        @test ep["arm_views"]["U1"] == [ids[1]] && ep["arm_views"]["U4"] == ids && ep["arm_views"]["V4"] == ids
        @test subs[1]["t0_feedback"] == String[] && subs[1]["preflight"]["enactment_status"] in ("enacted", "requires_runtime")
        @test any(x -> occursin("impl_unknown_call", x), subs[2]["t0_feedback"])        # 등록 거절 → 수정 호출로 되먹임
        @test subs[3]["stage"] == "compose_revision" && subs[3]["parent_proposal_id"] == ids[2]
        pf1 = BR._json(joinpath(zr, "proposal_source", "preflight", "pre-1", "enactment.json"))
        @test pf1["mode"] == "preflight" && !("geometry" in pf1["effect_classes"])
        c1 = sup["candidates"][ids[1]]
        x1 = BR._json(joinpath(c1["dir"], "enactment.json"))
        @test x1["mode"] == "full" && x1["status"] == "enacted" && !("geometry" in x1["effect_classes"])
        @test c1["outcome"] !== nothing                                                 # 전체 rollout 까지 갔다
        @test any(x -> occursin("impl_unknown_call", x), sup["candidates"][ids[2]]["reasons"])
    else
        @test length(ids) == 2 && endswith(ids[1], "-s1") && endswith(ids[2], "-s3")
        @test ep["arm_views"] == Dict("G4" => ids)
        @test subs[2]["frozen"] === false && occursin("unknown_config_ref", only(subs[2]["rejected_before_freeze"]))
        @test subs[1]["t0_feedback"] == String[]
        for id in ids
            c = sup["candidates"][id]
            x = BR._json(joinpath(c["dir"], "enactment.json"))
            @test x["status"] == "enacted" && "geometry" in x["effect_classes"]          # 같은 일반 효과 판별·후처리
            @test startswith(x["impl_name"], "g4_patch_")
        end
    end
    @test length(sup["candidates"]) == length(ids)
    @test sup["selection"]["classification"] == "baseline_complete" && sup["replay"]["match"] === true
    # shadow = 관측 전용: 서비스 source·observe worker·preflight 가 있어도 원래 세계 실제 스트림은 off 와 바이트 동일
    real = joinpath(root, "out", "streams", STREAM)
    @test isfile(real) && read(real) == read(off_stream)
    @test off_score in split(r.out, '\n')
    log("episode ok: frozen=", ids, " classification=", sup["selection"]["classification"],
        " candidates=", Dict(k => (v["outcome"], v["eligible"]) for (k, v) in sup["candidates"]))
end
