# =============================================================================
# b0_episode.jl — B0(pi0) 한 판 (T10a). 설계 §7.1·§9.1·§9.2(B0 = 존 NOOP, pi0 로 채점).
#
#   julia +lts --project=. tools/monitor/grid/b0_episode.jl <manifest.json> [--check]
#
# 원래 세계는 production shadow 가 띄우는 **그 부모**다(`BranchRunner.start_parent` — render_demo + worker preload,
# role=parent, 허용 목록 launch env `RepairRuntime.launch_env_from`). supervisor 대신 이 스크립트가 t0 에서
# `verify`(부모 t0 세계 재확인 — 블록 digest·tick 카운터·RNG) → `resume`(pi0 로 끝까지) 두 명령만 보낸다.
# 분기·후보·모델 호출은 없다. 그래서 판마다 t0 capture·task contract·신원 증거가 남고, 원래 세계의 궤적은 shadow 와
# 같다(T8 §4: shadow 부모 스트림 = off 무하네스 스트림, 바이트 동일).
#
# 필요한 env: pi0 셋(`RepairRuntime.startup_problems`) · `ZONE_REPAIR_VERIFICATION=shadow` · `DEMO_OUT_DIR` ·
# `ZONE_REPAIR_DIR`(판 namespace, 없어야 함). campaign.py(runner=b0)가 판마다 짓는다.
# manifest(`repair_verification_manifest.schema.json`)가 검증을 통과하지 못하면 부모를 띄우기 **전에** exit 2.
# 기록: `<ZONE_REPAIR_DIR>/b0.json`(schema `zrv-b0-episode/1`). stdout 끝줄 `[b0] …`. 종료코드 = 부모 종료코드,
# driver 자신이 실패하면 `driver_error` 를 싣고 3.
# =============================================================================
include(joinpath(@__DIR__, "..", "..", "..", "src", "verification", "repair_runtime.jl"))

module B0Episode

using JSON3, SHA
import ..RepairRuntime as RT
import ..RepairSupervisor as RS
import ..BranchRunner as BR
import ..RepairTypes as R

const SCHEMA = "zrv-b0-episode/1"
_json(p) = JSON3.read(read(p, String), Dict{String,Any})

"manifest 를 읽어 검증한다. 문제가 있으면 사유 문자열, 없으면 nothing."
function manifest_problem(path)
    isfile(path) || return "manifest $(path) does not exist"
    m = R.read_json(path)
    e = R.validate_repair_manifest(m)
    e === nothing || return e
    "B0" in m["arms"] || return "manifest arms $(m["arms"]) do not include B0"
    return nothing
end

"부모 contract 의 예산이 manifest 와 같은가(다르면 위반 목록)."
function budget_violations(contract, m)
    sp, ep = contract["sim_params"], m["budget"]["episode"]
    v = String[]
    sp["max_time_steps"] == ep["max_sim_steps"]["value"] ||
        push!(v, "max_time_steps $(sp["max_time_steps"]) != manifest $(ep["max_sim_steps"]["value"])")
    sp["max_num_iters_no_progress"] == ep["max_num_iters_no_progress"]["value"] ||
        push!(v, "max_num_iters_no_progress $(sp["max_num_iters_no_progress"]) != manifest $(ep["max_num_iters_no_progress"]["value"])")
    return v
end

function main(args)
    isempty(args) && error("usage: b0_episode.jl <manifest.json> [--check]")
    mpath = abspath(args[1])
    p = manifest_problem(mpath)
    if p !== nothing
        println(stderr, "[b0] manifest refused: ", p); return 2
    end
    "--check" in args && (println("[b0] manifest ok ", mpath); return 0)
    m = R.read_json(mpath)
    probs = RT.startup_problems(ENV)
    get(ENV, "ZONE_REPAIR_VERIFICATION", "") == "shadow" ||
        push!(probs, "ZONE_REPAIR_VERIFICATION must be shadow (B0 runs the shadow original world)")
    isempty(probs) || (println(stderr, "[b0] refused:\n  - ", join(probs, "\n  - ")); return 2)
    root = abspath(ENV["ZONE_REPAIR_DIR"])
    ispath(root) && error("[b0] ZONE_REPAIR_DIR=$(root) exists — each episode gets a fresh namespace")
    out = abspath(ENV["DEMO_OUT_DIR"])
    mkpath(root)
    rec = Dict{String,Any}("schema" => SCHEMA, "manifest" => mpath, "manifest_sha256" => bytes2hex(sha256(read(mpath))),
        "cell" => Dict(k => get(ENV, k, nothing) for k in ("DEMO_MODEL", "DEMO_OOD", "DEMO_ZONE", "DEMO_SEED",
                                                           "DEMO_ZONE_SEED", "DEMO_OOD_SEED", "MONITOR_RUN_ID")),
        "started_at" => time())
    cpu0 = BR.children_cpu_s()
    par = BR.start_parent(joinpath(root, "parent"), RT.launch_env_from(ENV); out_dir = out)
    stop = Ref(false)
    follower = RT.follow!(joinpath(par.dir, "run.log"), RT.log_sink(stdout), stop)
    try
        held = RT.wait_held_or_exit(par)
        rec["t0_captured"] = held !== nothing
        if held === nothing
            cu = joinpath(par.dir, "certification_unavailable.jsonl")
            rec["certification_gaps"] = vcat(["no t0 capture: the original world finished without a zone event pending at a step boundary"],
                isfile(cu) ? [String(get(JSON3.read(l), :reason, l)) for l in eachline(cu) if !isempty(strip(l))] : String[])
        else
            contract = _json(joinpath(par.dir, "contract.json"))
            rec["t0_iter"] = contract["t0_iter"]
            rec["sim_params"] = contract["sim_params"]
            rec["budget_violations"] = budget_violations(contract, m)
            rec["task_contract"] = get(contract, "task_contract", nothing)
            v = BR.parent_command(par, "verify")
            rec["verify"] = v
            rec["certification_gaps"] = vcat(RS.checkpoint_gaps(contract, par.dir), RS.identity_gaps(v))
            rec["resume"] = BR.parent_command(par, "resume")
        end
        wait(par.process)
    catch e
        # driver/하니스 실패 — 세계의 결과가 아니다. 기록하고 부모를 확실히 끝낸 뒤 b0.json 을 쓴다(분석기가 UNKNOWN harness 로 센다).
        rec["driver_error"] = first(sprint(showerror, e), 500)
    finally
        # SIGTERM 만으로는 부족하다(T10a 실측: inference 도중의 부모가 TERM 뒤 끝나지 않아 campaign 시한까지 막혔다 →
        # wall_timeout 으로 오표기). TERM → grace 뒤 토큰 스윕 KILL.
        if process_running(par.process)
            kill(par.process)
            rec["parent_kill_survivors"] = BR.kill_tree!(par.process, par.token)
            wait(par.process)
        end
        stop[] = true
        try wait(follower) catch end
        try close(par.log) catch end
    end
    rec["exit_code"] = par.process.exitcode
    rec["cpu_s"] = BR.children_cpu_s() - cpu0
    tf = joinpath(par.dir, "terminal.json")
    rec["terminal"] = isfile(tf) ? (t = _json(tf); delete!(t, "world_field_sha256"); t) : nothing
    rec["parent_dir"] = par.dir
    rec["finished_at"] = time()
    open(io -> JSON3.pretty(io, JSON3.write(rec)), joinpath(root, "b0.json"), "w")
    t = rec["terminal"] === nothing ? Dict{String,Any}() : rec["terminal"]
    println("[b0] t0_captured=$(rec["t0_captured"]) gaps=$(length(get(rec, "certification_gaps", []))) ",
            "complete=$(get(t, "complete", nothing)) reason=$(get(t, "terminal_reason", nothing)) ",
            "exit_code=$(rec["exit_code"]) record=$(joinpath(root, "b0.json"))")
    haskey(rec, "driver_error") && (println(stderr, "[b0] DRIVER ERROR (harness, not a world outcome): ", rec["driver_error"]); return 3)
    return something(rec["exit_code"], 1)
end

end # module B0Episode

exit(B0Episode.main(ARGS))
