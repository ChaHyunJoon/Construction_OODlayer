# =============================================================================
# repair_runtime.jl — `ZONE_REPAIR_VERIFICATION=off|shadow|enforce` 의 production 배선 (T8). 설계 §3.1·§6.1·§7.3.
#
# 진입점은 **production 스크립트 그 자체**다: `tools/monitor/render_demo.jl`(campaign.py·server.jl 이 띄우는 파일)이 맨 위에서
# 모드를 보고 `off` 가 아니면 이 파일의 `main()` 으로 넘어간다. `off`(기본)는 이 파일을 싣지도 않는다 — 오늘과 같은 경로.
#
# shadow/enforce 에서 render_demo 프로세스(= 이 모듈, **ConstructionBots 를 로드하지 않는다**)는 에피소드 driver 다:
#   1. 기동 검사: pi0 손잡이(존 NOOP 레인·존 solver/사다리 차단·공통 canonical fault/battery) · 우회 손잡이 금지 ·
#      enforce 면 샌드박스 능력표(`BranchRunner.sandbox_capabilities`, 실측) — `enforce_allowed == false` 면 **거절**(조용히
#      shadow 로 내려가지 않는다) · 후보 source(fixture 파일 / 서비스 — 서비스면 세대 게이트).
#   2. 원래 세계 = `BranchRunner.start_parent`(render_demo + worker preload, role=parent). 부모는 **실제** 산출물 자리
#      (`DEMO_OUT_DIR`)에 실제 스트림을 쓰고, t0(존 사건이 대기열에 있는 첫 스텝 경계 — 그 사건의 어떤 결정·body 보다 앞)에서
#      checkpoint 를 쓰고 tick 없이 기다린다.
#   3. 결정 전 신원 검사(`decision_gaps`: 서비스 check_health · source/API/schema/권한 지문) → `RepairSupervisor.supervise_episode!`
#      (후보마다 새 샌드박스 worker, 선택, certificate). shadow = 도구가 선택돼도 원래 세계는 NOOP 로 계속(관측 전용).
#      enforce = 선택된 도구를 새 commit worker 에 재생·검증 후 **활성 세계로 전환**(부모 은퇴).
#   4. render/monitor/episode 로그 = 활성 세계: 부모의 run.log 를 이 프로세스 stdout 으로 흘리고(campaign 이 `[run-ctx]`·
#      `[score]` 를 읽는 자리), 활성화되면 commit worker 의 shadow 원장을 **실제 스트림에 이어 붙이고**(t0 이후 = 활성 세계의
#      기록) 그 worker 의 log 를 `[active-world]` 접두사로 흘린 뒤 그 terminal 로 `[score]` 를 쓴다. 후보·NOOP 분기의 원장은
#      분기 디렉터리(T4 namespace)에만 있다 — 실제 스트림에 섞이지 않는다.
#   t0 capture 가 없으면(지연/라이브 존은 한 스텝 안에서 주입·dispatch 된다 — T3) 원래 세계는 pi0 로 끝까지 가고 이 판은
#   `certification_unavailable` 로 **명시** 기록된다.
# =============================================================================
isdefined(Main, :RepairSupervisor) || include(joinpath(@__DIR__, "repair_supervisor.jl"))

module RepairRuntime

using JSON3, SHA
import ..RepairTypes as R
import ..BranchRunner as BR
import ..RepairSupervisor as RS

const RUNTIME_VERSION = "repair-runtime/1"
const EPISODE_SCHEMA = "zone-repair-episode/1"
const MODES = ("off", "shadow", "enforce")
const ROOT = BR.ROOT
"production 분기 한도(T7 에피소드 게이트와 같은 값)."
const LIMITS = BR.Limits(wall_s = 3600, cpu_s = 7200, mem_bytes = 24 * 2^30)
const SCHEMA_FILE = joinpath(ROOT, "src", "respec", "llm_service", "tool_proposal.schema.json")
const GATE_SH = joinpath(ROOT, "tools", "require_current_service.sh")
const SERVICE_DIR = joinpath(ROOT, "src", "respec", "llm_service")
"pi0 를 정의하는 셋(`RepairBranchWorker.PI0_ENV` 와 같은 이름, 값은 `BranchRunner.PI0`)."
const PI0_KEYS = ("DEMO_POLICY", "DEMO_ROUTER", "REPAIR_ABLATION")
"결정 하나를 pi0/supervisor 밖으로 돌리는 손잡이 — 검증 모드에서는 켜져 있으면 기동하지 않는다."
const BYPASS_KEYS = ("DEMO_SYNTH_FIXTURE", "DEMO_FORCE_MACRO", "DS_DEVIATE_AT")

_json(p) = JSON3.read(read(p, String), Dict{String,Any})
_write(p, d) = open(io -> JSON3.pretty(io, JSON3.write(d)), p, "w")
_sha(p) = bytes2hex(sha256(read(p)))

"정확히 `off|shadow|enforce`. 그 밖(대소문자·공백·빈 값 포함)은 오류 — 오타로 조용히 off 가 되지 않는다."
parse_mode(s::AbstractString) = s in MODES ? Symbol(s) :
    error("ZONE_REPAIR_VERIFICATION=$(repr(s)) is not one of off|shadow|enforce")

"""
    startup_problems(env) -> Vector{String}

검증 모드 기동 전제(빈 목록 = 통과). 공통 continuation pi0 가 아니면 원래 세계·분기·commit worker 가 서로 다른 정책을
돌게 되어 certificate 가 무의미하고(설계 §3.1 — fault/battery 는 공통 정책), 우회 손잡이는 생성 body 나 강제 결정을
supervisor 를 거치지 않고 세계에 넣는다.
"""
function startup_problems(env::AbstractDict)
    p = String[]
    for k in PI0_KEYS
        v = get(env, k, nothing)
        v == BR.PI0[k] || push!(p, "$(k)=$(v === nothing ? "<unset>" : repr(v)) — pi0 needs $(k)=$(BR.PI0[k]) " *
                                   "(zone NOOP lane · zone solver/ladder blocked · common canonical fault/battery policy)")
    end
    for k in BYPASS_KEYS
        isempty(strip(get(env, k, ""))) ||
            push!(p, "$(k) is set — it injects a generated body or forces a decision around pi0 and the supervisor")
    end
    get(env, "MONITOR_INTERACTIVE", "0") == "1" &&
        push!(p, "MONITOR_INTERACTIVE=1 — live operator zones are injected and dispatched inside one step; no t0 capture exists")
    return p
end

"""
    enforce_problems(caps) -> Vector{String}

설계 §6.1: 권한 경계를 강제할 수 없으면 enforce 를 켜지 않는다. `caps` = `BranchRunner.sandbox_capabilities` 의 결과
(production 은 **기동마다 실측**한다 — `main`). 🔴 시험만 `caps` 를 손으로 만들어 넘길 수 있고(`run_episode!` 의 Julia 키워드),
그 경우 `test_forced = true` 표식이 에피소드 기록의 `enforce_gate` 에 남는다. 환경변수로 여는 길은 없다.
"""
function enforce_problems(caps)
    caps isa AbstractDict || return ["no sandbox capability report"]
    caps["enforce_allowed"] === true && return String[]
    return ["sandbox capability report says enforce_allowed=false — not enforced: " *
            join(get(caps, "not_enforced", ["?"]), ", ")]
end

"fixture 후보 파일: ToolProposal JSON 객체의 배열. 형식이 틀리면 기동 전에 죽는다(판을 굴린 뒤 알게 되지 않게)."
function load_proposals(path::AbstractString)
    v = JSON3.read(read(path, String))
    v isa AbstractVector && !isempty(v) && all(x -> x isa AbstractDict, v) ||
        error("ZONE_REPAIR_PROPOSALS=$(path) must be a non-empty JSON array of ToolProposal objects")
    return [JSON3.read(JSON3.write(x), Dict{String,Any}) for x in v]
end

"""
    service_gate(url) -> (ok, line)

세대 게이트를 **부른다**(`tools/require_current_service.sh` → `generation.py` 의 `check_health`) — 판정식을 Julia 에
다시 적지 않는다(CLAUDE.md). 합성 레인 플래그 둘을 요구한다(T9 의 후보는 3-agent 합성 레인에서 온다).
"""
function service_gate(url::AbstractString)
    cmd = setenv(`bash -c 'source "$0" && require_current_service "$1"' $GATE_SH $url`,
                 merge(Dict(ENV), Dict("REPO_ROOT" => ROOT, "REQUIRE_TOOL_SYNTHESIS" => "1", "REQUIRE_SYNTH_MULTI_AGENT" => "1")))
    pipe = Pipe()
    p = run(pipeline(ignorestatus(Cmd(cmd; dir = ROOT)); stdout = pipe, stderr = pipe); wait = false)
    close(pipe.in)
    out = read(pipe, String); wait(p)
    lines = filter(!isempty, strip.(split(out, '\n')))
    return (p.exitcode == 0, isempty(lines) ? "rc=$(p.exitcode), no output" : String(last(lines)))
end

"이 트리의 서비스 코드 지문 — `generation.code_fingerprint` 를 부른다(다시 적지 않는다). 못 재면 nothing."
function tree_service_fingerprint()
    py = joinpath(ROOT, ".venv", "bin", "python")
    isfile(py) || (py = "python3")
    code = "import sys; sys.path.insert(0, sys.argv[1]); import generation; print(generation.code_fingerprint(sys.argv[1]))"
    s = try strip(read(`$py -c $code $SERVICE_DIR`, String)) catch; "" end
    return (isempty(s) || s == "None") ? nothing : String(s)
end

"""
    decision_gaps(proposals; source, url = "", service_gate = service_gate, tree_fingerprint = tree_service_fingerprint)
        -> Vector{String}

**결정 전**(t0, 후보 동결 앞) 신원 검사. gap 이 하나라도 있으면 그 사건은 인증 불가(→ rollout 없이 NOOP).
  * 서비스(`source == :service`): 세대 게이트(`check_health`) — unreachable/unstamped/blind/stale/flag_off 전부 gap.
  * API: 후보의 `schema_version` == `RepairTypes.TOOL_PROPOSAL_SCHEMA_VERSION`.
  * schema: `provenance.tool_proposal_schema_sha256`(있으면) == 이 트리의 `tool_proposal.schema.json` digest.
  * 권한: `provenance.capability_contract_version`(있으면) == `DEFAULT_CAPABILITY_CONTRACT.version`.
  * source: `provenance.service_code_fingerprint`(있으면) == 이 트리의 서비스 코드 지문.
  서비스 후보는 세 도장이 **필수**다(없으면 gap) — fixture 는 `provenance.source = "fixture"` 이고 도장이 선택이다.
"""
function decision_gaps(proposals::AbstractVector; source::Symbol, url::AbstractString = "",
                       service_gate = service_gate, tree_fingerprint = tree_service_fingerprint)
    g = String[]
    if source === :service
        ok, line = service_gate(url)
        ok || push!(g, "service generation gate failed before the decision ($(url)): $(line)")
    end
    schema_sha = _sha(SCHEMA_FILE)
    tfp = Ref{Any}(:unmeasured)
    for p in proposals
        id = string(get(p, "proposal_id", "?"))
        sv = get(p, "schema_version", nothing)
        sv == R.TOOL_PROPOSAL_SCHEMA_VERSION ||
            push!(g, "proposal $(id): API schema_version $(repr(sv)) != $(R.TOOL_PROPOSAL_SCHEMA_VERSION)")
        prov = get(p, "provenance", Dict{String,Any}())
        prov isa AbstractDict || (prov = Dict{String,Any}())
        for k in ("tool_proposal_schema_sha256", "capability_contract_version", "service_code_fingerprint")
            source === :service && !haskey(prov, k) && push!(g, "proposal $(id): service proposal lacks provenance.$(k)")
        end
        v = get(prov, "tool_proposal_schema_sha256", nothing)
        v === nothing || v == schema_sha || push!(g, "proposal $(id): schema digest $(v) != tree $(schema_sha)")
        v = get(prov, "capability_contract_version", nothing)
        v === nothing || v == R.DEFAULT_CAPABILITY_CONTRACT.version ||
            push!(g, "proposal $(id): permission contract $(v) != $(R.DEFAULT_CAPABILITY_CONTRACT.version)")
        v = get(prov, "service_code_fingerprint", nothing)
        if v !== nothing
            tfp[] === :unmeasured && (tfp[] = tree_fingerprint())
            v == tfp[] || push!(g, "proposal $(id): generated by service source $(v) != this tree $(something(tfp[], "unmeasurable"))")
        end
    end
    return g
end

# ---- 활성 세계의 기록을 따라가기 ------------------------------------------------------------------
"""
    follow!(src, sink, stop; from = 0) -> Task

`src` 파일에 새로 붙는 **완결된 줄**을 `sink(bytes)` 로 넘긴다(0.2 s 폴링). `stop[]` 가 참이 된 뒤 한 번 더 비우고 끝난다.
"""
function follow!(src::AbstractString, sink, stop::Ref{Bool}; from::Integer = 0)
    return @async begin
        off = Int(from); buf = UInt8[]
        try
            while true
                done = stop[]
                if isfile(src) && filesize(src) > off
                    data = open(io -> (seek(io, off); read(io)), src)
                    off += length(data); append!(buf, data)
                    k = findlast(==(UInt8('\n')), buf)
                    k === nothing || (sink(buf[1:k]); buf = buf[k+1:end])
                end
                if done
                    isempty(buf) || sink(buf)
                    break
                end
                sleep(0.2)
            end
        catch e
            println("[zrv-runtime] follower of $(src) failed: ", sprint(showerror, e))
        end
    end
end

log_sink(io::IO; prefix = "") = bytes -> begin
    for l in split(String(bytes), '\n'; keepempty = false)
        println(io, prefix, l)
    end
    flush(io)
end
append_sink(path::AbstractString) = bytes -> open(io -> (write(io, bytes); flush(io)), path, "a")

"부모가 t0 에서 대기(`held.json`)하거나 끝날 때까지. 끝났으면 nothing(= t0 capture 가 없었다)."
function wait_held_or_exit(par)
    f = joinpath(par.dir, "held.json")
    while true
        isfile(f) && return _json(f)
        process_running(par.process) || return (sleep(0.5); isfile(f) ? _json(f) : nothing)
        sleep(1)
    end
end

"활성 commit worker 의 terminal 로 쓰는 `[score]` 줄 — render_demo 꼬리는 그 worker 에서 돌지 않는다(continuation 뒤 exit)."
score_line(t::AbstractDict) = "[score] complete=$(get(t, "complete", nothing)) closed=$(get(t, "closed", nothing)) " *
    "n_zones=$(get(t, "n_zones", nothing)) n_blocked=$(get(t, "n_blocked", nothing)) " *
    "project_blocked=$(get(t, "project_blocked", nothing)) iter=$(get(t, "iter", nothing)) active_world=commit_worker"

"""
    run_episode!(; mode, launch_env, root, proposals, source, url = "", capabilities = nothing, out_dir,
                 noise_floor = :measure, baseline_override = nothing, log_io = stdout, campaign_dir = root) -> Dict

한 에피소드(설계 §3.1: 첫 존 사건에서 최대 한 repair transaction). 반환 = `<root>/episode.json` 의 내용(`exit_code` 포함).
`capabilities`·`baseline_override` 를 손으로 넘기는 것은 시험뿐이다(`main` 은 실측값만 넘기고 override 를 안 넘긴다).
"""
function run_episode!(; mode::Symbol, launch_env::AbstractDict, root::AbstractString, proposals::AbstractVector,
                      source::Symbol, url::AbstractString = "", capabilities = nothing, out_dir::AbstractString,
                      noise_floor::Union{Bool,Symbol} = :measure, baseline_override::Union{Nothing,Symbol} = nothing,
                      log_io::IO = stdout, campaign_dir::AbstractString = root, commit_id::AbstractString = "commit")
    mode in (:shadow, :enforce) || error("run_episode! needs mode shadow|enforce, got $(mode)")
    if mode === :enforce
        p = enforce_problems(capabilities)
        isempty(p) || error("[zrv] ZONE_REPAIR_VERIFICATION=enforce refused: " * join(p, "; "))
    end
    mkpath(root)
    rec = Dict{String,Any}("schema" => EPISODE_SCHEMA, "runtime_version" => RUNTIME_VERSION, "mode" => String(mode),
        "root" => root, "source" => String(source), "n_proposals" => length(proposals),
        "enforce_gate" => mode === :enforce ? (get(capabilities, "test_forced", false) === true ? "FORCED (test)" : "measured: enforce_allowed") : nothing,
        "baseline_override" => baseline_override === nothing ? nothing : "FORCED (test): $(baseline_override)",
        "started_at" => time())
    par = BR.start_parent(joinpath(root, "parent"), launch_env; out_dir)
    stop_parent_log = Ref(false); stop_active = Ref(false)
    tasks = Task[follow!(joinpath(par.dir, "run.log"), log_sink(log_io), stop_parent_log)]
    sv = nothing
    try
        held = wait_held_or_exit(par)
        if held === nothing
            # 원래 세계가 t0 capture 없이 끝났다(지연/라이브 존 — 설계상 capture 불가, T3). 조용히 넘기지 않는다.
            rec["certification"] = "unavailable"
            cu = joinpath(par.dir, "certification_unavailable.jsonl")
            rec["certification_reasons"] = vcat(["no t0 capture: the original world finished without a zone event pending at a step boundary"],
                isfile(cu) ? [String(get(JSON3.read(l), :reason, l)) for l in eachline(cu) if !isempty(strip(l))] : String[])
            rec["active_world"] = Dict{String,Any}("kind" => "original_world", "dir" => par.dir)
            rec["exit_code"] = par.process.exitcode
            return rec
        end
        contract = _json(joinpath(par.dir, "contract.json"))
        rec["t0_iter"] = contract["t0_iter"]
        # 🔴 결정 **전**: 서비스·source·API·schema·권한 지문.
        pre = decision_gaps(proposals; source, url)
        source === :service && isempty(pre) &&
            push!(pre, "service proposal source is not wired yet (T9) — no candidates frozen")
        rec["decision_gaps"] = pre
        props = source === :fixture ? proposals : Dict{String,Any}[]
        outroot = joinpath(root, "supervision")
        sv = RS.Supervision(par; outroot, launch_env, limits = LIMITS, campaign_dir)
        if mode === :enforce
            aw = joinpath(outroot, commit_id * ".active_world.json")
            push!(tasks, @async begin
                while !isfile(aw) && !stop_active[]; sleep(0.3); end
                if isfile(aw)
                    sleep(0.3)
                    h = _json(aw); led = h["handover"]["ledger"]
                    rec["real_ledger_splice"] = Dict{String,Any}("real" => led["real_until_t0"], "active" => led["active_from_t0"],
                        "real_bytes_at_activation" => isfile(led["real_until_t0"]) ? filesize(led["real_until_t0"]) : nothing)
                    println(log_io, "[zrv-runtime] commit worker ", h["commit_worker_id"], " is the active world from t1=",
                            h["t1_iter"], " — its ledger continues the real stream ", led["real_until_t0"]); flush(log_io)
                    fs = Task[follow!(joinpath(h["dir"], "run.log"), log_sink(log_io; prefix = "[active-world] "), stop_active)]
                    isempty(led["real_until_t0"]) ||
                        push!(fs, follow!(led["active_from_t0"], append_sink(led["real_until_t0"]), stop_active))
                    foreach(wait, fs)
                end
            end)
        end
        RS.supervise_episode!(sv; proposals = props, noise_floor, shadow = mode === :shadow, pre_gaps = pre,
                              baseline_override, commit_id)
        rec["supervision"] = RS.summary(sv)
        rec["certificate"] = joinpath(outroot, "certificate.json")
        rec["certification"] = sv.selection !== nothing && sv.selection.classification === :certification_unavailable ?
                               "unavailable" : "available"
        if sv.commit !== nothing && sv.commit.activated
            cdir = joinpath(outroot, commit_id)
            t = isfile(joinpath(cdir, "terminal.json")) ? _json(joinpath(cdir, "terminal.json")) : Dict{String,Any}()
            rec["active_world"] = Dict{String,Any}("kind" => "commit_worker", "dir" => cdir,
                "handover" => joinpath(outroot, commit_id * ".active_world.json"), "terminal" => t)
            stop_active[] = true; foreach(wait, tasks[2:end])
            println(log_io, score_line(t))
            haskey(t, "ablation") && println(log_io, "[ablation] ", t["ablation"])
            rec["exit_code"] = get(t, "complete", false) === true ? 0 : 1
        else
            rec["active_world"] = Dict{String,Any}("kind" => "original_world", "dir" => par.dir)
            rec["exit_code"] = par.process.exitcode
        end
        return rec
    finally
        stop_parent_log[] = true; stop_active[] = true
        # 정상 경로에서는 여기서 부모가 이미 끝났다(NOOP 재개를 기다렸거나, 활성화로 은퇴했거나, t0 없이 끝났다).
        # 예외로 왔으면 t0 에서 기다리는 부모를 고아로 두지 않는다(`supervise_episode!` 의 finally 와 겹쳐도 무해).
        process_running(par.process) && (kill(par.process); wait(par.process))
        foreach(t -> (try wait(t) catch end), tasks)
        try close(par.log) catch end
        rec["finished_at"] = time()
        _write(joinpath(root, "episode.json"), rec)
        println(log_io, "[zrv-episode] mode=$(mode) certification=$(get(rec, "certification", "?")) ",
                "state=$(sv === nothing ? "-" : sv.state) active_world=$(get(get(rec, "active_world", Dict()), "kind", "?")) ",
                "exit_code=$(get(rec, "exit_code", "?")) record=$(joinpath(root, "episode.json"))")
        flush(log_io)
    end
end

"""
    main() -> Int  (프로세스 종료 코드)

render_demo.jl 이 `ZONE_REPAIR_VERIFICATION != off` 일 때 부른다. 기동 검사(모드·pi0·우회·enforce 능력표·후보 source·서비스
게이트)를 **부모를 띄우기 전에** 끝낸다 — 어느 하나라도 틀리면 오류로 죽는다(조용히 off/shadow 로 내려가지 않는다).
"""
function main()
    mode = parse_mode(get(ENV, "ZONE_REPAIR_VERIFICATION", "off"))
    mode === :off && error("RepairRuntime.main is only for shadow|enforce")
    probs = startup_problems(ENV)
    isempty(probs) || error("[zrv] ZONE_REPAIR_VERIFICATION=$(mode) refused at startup:\n  - " * join(probs, "\n  - "))
    od = get(ENV, "DEMO_OUT_DIR", "")
    out = isempty(od) ? joinpath(ROOT, "tools", "monitor") : abspath(od)
    root = abspath(get(ENV, "ZONE_REPAIR_DIR", joinpath(out, "zone_repair", "run_$(round(Int, time()))_$(getpid())")))
    ispath(root) && error("[zrv] ZONE_REPAIR_DIR=$(root) exists — each episode gets a fresh namespace")
    caps = nothing
    if mode === :enforce
        caps = BR.sandbox_capabilities(joinpath(root, "capabilities"))
        p = enforce_problems(caps)
        isempty(p) || error("[zrv] ZONE_REPAIR_VERIFICATION=enforce refused (design §6.1: no enforce without an enforceable " *
                            "boundary): $(join(p, "; ")). Capability report: $(joinpath(root, "capabilities", "capabilities.json")). " *
                            "Use ZONE_REPAIR_VERIFICATION=shadow to evaluate candidates without changing the world.")
    end
    pf = strip(get(ENV, "ZONE_REPAIR_PROPOSALS", ""))
    url = strip(get(ENV, "DSPY_URL", ""))
    if !isempty(pf)
        source, proposals = :fixture, load_proposals(pf)
    else
        isempty(url) && error("[zrv] no proposal source: set ZONE_REPAIR_PROPOSALS (fixture file) or DSPY_URL (service)")
        ok, line = service_gate(url)
        ok || error("[zrv] the proposal service does not serve this tree (generation gate): $(line)")
        source, proposals = :service, Dict{String,Any}[]
    end
    launch = Dict{String,String}(String(k) => String(v) for (k, v) in ENV if !startswith(String(k), "ZRV_"))
    rec = run_episode!(; mode, launch_env = launch, root, proposals, source, url, capabilities = caps, out_dir = out,
                       campaign_dir = abspath(get(ENV, "ZONE_REPAIR_CAMPAIGN_DIR", root)))
    return something(rec["exit_code"], 1)
end

end # module RepairRuntime
