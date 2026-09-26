# =============================================================================
# branch_runner.jl — 별도 프로세스 branch worker 의 supervisor 쪽과 trusted validator (T4). 설계 §5·§6.1·§7.1.
#
# 🔴 이 모듈은 ConstructionBots 를 **로드하지 않는다** — 생성 코드를 실행하는 프로세스(worker)와 다른 프로세스에서
#    JSON/JSONL(고정·code-free export)만 읽는다. custom deserialize 도 callback 도 없다. worker 가 적은 `complete`·
#    점수는 쓰지 않고, 부모(t0 에서 멈춘 원래 세계, 생성 코드 0)가 쓴 `contract.json` 의 원본 완료 조건으로 다시 판정한다.
#
# 역할:
#   * `start_parent` / `parent_command` — 원래 세계를 t0 에서 **tick 없이** 세워 두는 프로세스(render_demo + worker
#     preload, role=parent). supervisor 가 `verify`(t0 세계 digest·tick 카운터 대조) · `resume`(원래 세계에서 pi0 재개)
#     · `exit` 를 보낸다. `RESPEC_HOLD`·진행 카운터를 건드리지 않는다(대기는 훅 안의 sleep 이다).
#   * `run_branch` — 분기마다 **새 프로세스·새 디렉터리(원장 namespace)**. env 는 상속하지 않고 새로 만든다
#     (`worker_env`: 자격 증명·서비스 주소 제거). `zrv_sandbox.py` 로 OS 경계를 걸고(Landlock·rlimit·setsid),
#     wall 초과면 프로세스 그룹 + 토큰 스윕으로 하위 트리까지 죽인다.
#   * `validate_branch` — trusted validator. `RepairTypes.RolloutReport` 를 만든다. UNKNOWN 은 원인과 함께.
#   * `sandbox_capabilities` — 경계마다 **음성 시험**으로 잰 능력표. 하나라도 못 막으면 `enforce_allowed = false`.
#
# 무엇을 **못** 하나(능력표에 기계로 실린다): 같은 프로세스 안의 메서드/채점기 override(Julia 에 권한 경계가 없다),
#   worker 가 쓰는 export 자체의 위조, UDP·pathname unix socket, 액션 도중 되돌린 일시적 변경.
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))

module BranchRunner

using JSON3, SHA, Sockets
import ..RepairTypes as R

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JULIA = joinpath(Sys.BINDIR, "julia")          # supervisor 와 같은 바이너리(julia +lts 가 고른 것)
const SANDBOX_PY = joinpath(ROOT, "tools", "monitor", "zrv_sandbox.py")
const WORKER = joinpath(ROOT, "tools", "monitor", "repair_branch_worker.jl")
const RENDER = joinpath(ROOT, "tools", "monitor", "render_demo.jl")
const CONTRACT_SCHEMA = "branch-contract/1"
const EXPORT_SCHEMA = "branch-export/1"

"""
자격 증명·서비스 주소 모양의 환경변수. worker 의 **실행 env 에서 빼고**(`worker_env`), import 가 checkpoint 의
ENV 를 되살린 뒤에도 worker 가 한 번 더 지운다(`repair_branch_worker.jl` — 비밀이 아닌 모양의 `DSPY_URL` 은
checkpoint 에 값째 실려 되살아난다).
"""
const DENY_ENV = r"KEY|TOKEN|SECRET|PASSW|CREDENTIAL|COOKIE|AUTH|_URL$|^OPENAI|^ANTHROPIC"i
# `ZRV_BRANCH_TOKEN` 은 우리 스윕용 표식이라 예외(값은 무작위 namespace 문자열이지 자격 증명이 아니다).
denied_env(k) = k != "ZRV_BRANCH_TOKEN" && occursin(DENY_ENV, k)

Base.@kwdef struct Limits
    wall_s::Float64
    cpu_s::Int
    mem_bytes::Int
end

_json(path) = JSON3.read(read(path, String), Dict{String,Any})
_write(path, d) = open(io -> JSON3.pretty(io, JSON3.write(d)), path, "w")

# ---- env ---------------------------------------------------------------------------------------
"상속하지 않는 최소 env(부모 셸의 손잡이·비밀을 끊는다 — T3 드라이버의 `env -i` 와 같은 뜻)."
base_env() = Dict("HOME" => ENV["HOME"], "PATH" => ENV["PATH"], "USER" => get(ENV, "USER", ""),
                  "LANG" => "C.UTF-8")

"`launch` 에서 거부 이름을 뺀 사본과 뺀 **이름**들(값은 절대 싣지 않는다)."
function scrub(launch::AbstractDict)
    removed = sort!([String(k) for k in keys(launch) if denied_env(String(k))])
    return Dict{String,String}(String(k) => String(v) for (k, v) in launch if !denied_env(String(k))), removed
end

"worker 실행 env = 최소 env + 세척한 셀 손잡이 + 하니스 키. 부모 프로세스의 ENV 는 한 글자도 안 넘어간다."
function worker_env(launch::AbstractDict, extra::AbstractDict)
    clean, removed = scrub(launch)
    env = merge(base_env(), clean, Dict{String,String}(String(k) => String(v) for (k, v) in extra))
    return env, removed
end

# ---- pi0 셀 env ----------------------------------------------------------------------------------
"""
pi0 = 존 NOOP(canonical 레인) + 존 복구 base/사다리 차단(`REPAIR_ABLATION=all`) + 9/23 캠페인 set_env(DSPY_URL 제외).
🔴 `tools/monitor/zrv_replay_episode.sh` 의 `PI0=(…)` 와 같은 값이다 — `test/repair_rollout.jl` 이 두 목록의 일치를 잰다.
"""
const PI0 = Dict("DEMO_ROUTER" => "0", "DEMO_POLICY" => "canonical", "REPAIR_ABLATION" => "all",
    "CARRIER_RESCUE" => "1", "DEMO_ANIM" => "0", "ENERGY_OBJECTIVE" => "1", "RESPEC_DEPRIO_KAPPA" => "0.25",
    "RESPEC_TRANSLATE_ON_INFEASIBLE" => "0", "RESTAGE_NAV_BUFFER" => "0", "RESTAGE_RING_STEP_FRAC" => "0.34",
    "RESTAGE_ZONE_MARGIN_FRAC" => "0.5", "SPARE_PRIORITY" => "1", "TEAM_PRIORITY" => "1", "ZONE_CAUSAL_RULE" => "0",
    "ZONE_CHECK_PATHS" => "0", "ZONE_DOMAIN_GATE" => "0", "ZONE_RESCUE" => "1")
const MODEL_FILES = Dict("tractor" => "tractor.mpd", "xwing" => "30051-1 - X-wing Fighter - Mini.mpd")

"셀(model × case × seed)의 launch env — T3 드라이버와 같은 조합."
function pi0_launch_env(model::AbstractString, case::AbstractString, seed::Integer)
    c = case == "zone" ? Dict("DEMO_OOD" => "none", "DEMO_ZONE" => "1") :
        case == "all3" ? Dict("DEMO_OOD" => "fault_battery", "DEMO_OOD_SEED" => string(seed), "DEMO_ZONE" => "1") :
        error("case must be zone|all3")
    return merge(PI0, c, Dict("DEMO_MODEL" => MODEL_FILES[model], "DEMO_SEED" => string(seed),
                              "DEMO_ZONE_SEED" => string(seed), "DEMO_CASE_TAG" => "pi0_$(case)"))
end

# ---- OS 경계 -----------------------------------------------------------------------------------
"worker 가 읽을 수 있는 곳. 레포는 **하위 경로만**(코드·지문 git diff 대상·모델 파일·python) — `.superpowers`·
`results` 같은 역사적 결과·다른 분기 출력은 목록에 없어 못 읽는다."
read_paths() = vcat(["/usr", "/etc", "/lib", "/lib64", "/bin", "/sbin", "/dev", "/sys", "/opt",
                     joinpath(homedir(), ".julia"),
                     # git 전역 설정(코드 지문 `git diff` 가 읽는다 — 못 읽으면 git 이 죽고 지문이 "unknown" 이 된다)
                     joinpath(homedir(), ".config", "git"), joinpath(homedir(), ".gitconfig"),
                     # LDraw 부품 라이브러리(LDrawParser 기본 위치; LDConfig.ldr 색표 등)
                     joinpath(homedir(), "Documents", "ldraw")],
                    [joinpath(ROOT, p) for p in (".git", ".gitignore", "src", "tools", "test", "Project.toml", "Manifest.toml",
                                                 "LDraw_files", ".venv")])
const PROC_FILES = ["/proc/cpuinfo", "/proc/meminfo", "/proc/stat", "/proc/loadavg", "/proc/filesystems",
                    "/proc/sys/kernel/osrelease"]

"시스템 python(표준 라이브러리만 쓴다). PATH 의 python3 는 레포 `.venv` 일 수 있어 피한다 — 샌드박스 읽기 목록과 무관하게."
python3() = isfile("/usr/bin/python3") ? "/usr/bin/python3" :
            something(Sys.which("python3"), "python3 not found — the sandbox wrapper cannot run")

"`cmd` 를 `zrv_sandbox.py` 로 감싼다. `write` 아래만 쓰기, `read` 아래만 읽기, TCP connect 금지, rlimit, setsid."
function sandboxed(cmd::Cmd; write::Vector{String}, read::Vector{String} = read_paths(), limits::Limits)
    py = python3()
    args = String[SANDBOX_PY]
    for w in write; append!(args, ["--write", w]); end
    for r in read; append!(args, ["--read", r]); end
    append!(args, ["--list", ROOT])     # 이름 목록만(git ls-files 가 `.` 을 연다). 파일 **내용**은 read 목록 밖이면 못 읽는다
    for f in PROC_FILES; append!(args, ["--proc-file", f]); end
    append!(args, ["--cpu", string(limits.cpu_s), "--mem", string(limits.mem_bytes), "--"])
    return Cmd(vcat([py], args, cmd.exec))
end

"자식 전체(대기한 손자 포함)의 누적 CPU 초 — 실행 전후 차가 그 분기의 CPU 다."
function children_cpu_s()
    ru = zeros(Int64, 18)                     # struct rusage (x86_64): utime, stime 이 앞 4 칸
    ccall(:getrusage, Cint, (Cint, Ptr{Int64}), -1, ru) == 0 || return NaN   # RUSAGE_CHILDREN = -1
    return ru[1] + ru[2] / 1e6 + ru[3] + ru[4] / 1e6
end

"환경변수 `ZRV_BRANCH_TOKEN=<token>` 을 가진 살아 있는 프로세스(setsid 로 그룹을 벗어난 자손도 잡힌다)."
function token_pids(token)
    needle = "ZRV_BRANCH_TOKEN=" * token
    out = Int[]
    for d in readdir("/proc")
        pid = tryparse(Int, d)
        (pid === nothing || pid == getpid()) && continue
        env = try read("/proc/$(pid)/environ") catch; continue end
        any(==(needle), split(String(env), '\0')) && push!(out, pid)
    end
    return out
end
_kill(pid, sig) = ccall(:kill, Cint, (Cint, Cint), pid, sig)

"""
프로세스 그룹(샌드박스가 `setsid` → pgid = pid)에 TERM→KILL, 그 뒤 토큰 스윕으로 남은 자손을 KILL.
반환: 스윕 후에도 살아 있는 pid 수(0 이어야 한다).
"""
function kill_tree!(p::Base.Process, token; grace = 5.0, pg::Integer = getpid(p))
    _kill(-pg, 15)
    t = time()
    while process_running(p) && time() - t < grace; sleep(0.1); end
    _kill(-pg, 9)
    for _ in 1:3
        pids = token_pids(token)
        isempty(pids) && break
        foreach(q -> _kill(q, 9), pids)
        sleep(0.3)
    end
    return length(token_pids(token))
end

"worker 의 가상/상주 메모리 최댓값(kB) — 한도 설정 근거(`/proc/<pid>/status`)."
function _sample_mem!(peak, pid)
    for l in (try eachline("/proc/$(pid)/status") catch; String[] end)
        for k in keys(peak)
            startswith(l, k * ":") && (peak[k] = max(peak[k], something(tryparse(Int, split(l)[2]), 0)))
        end
    end
end

"""
    supervise(cmd, env, log; wall_s, token) -> NamedTuple

env 를 **통째로 교체**해서 띄우고(상속 없음) wall 을 감시한다. 정상 종료여도 토큰 스윕을 한다(떠돌이 자손 정리).
"""
function supervise(cmd::Cmd, env::AbstractDict, log::AbstractString; wall_s::Real, token::AbstractString,
                   on_tick = nothing)
    cpu0 = children_cpu_s()
    io = open(log, "w")
    p = run(pipeline(setenv(cmd, env); stdout = io, stderr = io); wait = false)
    pid = getpid(p)                               # 샌드박스가 setsid → 이 pid 가 프로세스 그룹 id
    t0 = time(); timed_out = false; peak = Dict("VmPeak" => 0, "VmHWM" => 0)
    at_kill = leftover = 0
    # 🔴 T7: `on_tick`(commit 명령)이나 폴링이 던져도 worker 트리를 남기지 않는다 — 정리는 finally 에서.
    try
        while process_running(p)
            if time() - t0 > wall_s; timed_out = true; break; end
            _sample_mem!(peak, pid)
            on_tick === nothing || on_tick(p)
            sleep(0.5)
        end
    finally
        at_kill = length(token_pids(token))       # 정리 전 살아 있던 토큰 프로세스 수(정리 시험이 항진이 아님을 보인다)
        leftover = kill_tree!(p, token; pg = pid)
        wait(p)
        close(io)
    end
    return (exitcode = p.exitcode, termsignal = p.termsignal, timed_out = timed_out, leftover = leftover,
            token_procs_at_kill = at_kill, wall_s = time() - t0, cpu_s = children_cpu_s() - cpu0,
            vm_peak_kb = peak["VmPeak"], rss_peak_kb = peak["VmHWM"])
end

# ---- 부모(원래 세계, t0 에서 대기) --------------------------------------------------------------
"""
    start_parent(dir, launch_env) -> (process, dir, token)

원래 에피소드를 render_demo 로 띄우고 t0 에서 checkpoint·`contract.json` 을 쓴 뒤 **tick 없이** 명령을 기다리게
한다. 부모는 생성 코드를 돌리지 않는 신뢰 세계라 샌드박스를 걸지 않는다(env 는 똑같이 새로 만든다).
"""
function start_parent(dir::AbstractString, launch_env::AbstractDict; hold_max_s = 6 * 3600,
                      out_dir::AbstractString = joinpath(dir, "out"))
    ispath(dir) && error("parent dir exists: $(dir) — each run gets a fresh namespace")
    mkpath(joinpath(dir, "control"))
    token = "parent-" * string(time_ns())
    # T8: production 에서는 `out_dir` = 그 판의 **실제** 산출물 뿌리(`DEMO_OUT_DIR`) — 부모가 원래 세계이므로 실제 스트림을
    #     원래 자리에 쓴다. 분기는 여전히 자기 디렉터리(`run_branch`)라 shadow 원장과 섞이지 않는다.
    env, removed = worker_env(launch_env, Dict("ZRV_REPLAY_MODE" => "capture", "ZRV_REPLAY_DIR" => dir,
        "ZRV_BRANCH_ROLE" => "parent", "ZRV_BRANCH_TOKEN" => token, "ZRV_HOLD_MAX_S" => string(hold_max_s),
        "DEMO_OUT_DIR" => String(out_dir)))
    _write(joinpath(dir, "launch.json"), Dict("env_names" => sort!(collect(keys(env))), "removed_env" => removed))
    io = open(joinpath(dir, "run.log"), "w")
    p = run(pipeline(setenv(`$JULIA --project=$ROOT -L $WORKER $RENDER`, env); stdout = io, stderr = io); wait = false)
    return (process = p, dir = String(dir), token = token, log = io)
end

"부모가 t0 에서 대기에 들어갈 때까지 기다린다(`held.json`). 부모가 먼저 죽으면 에러."
function wait_held(par; timeout_s = 7200)
    f = joinpath(par.dir, "held.json")
    t = time()
    while !isfile(f)
        process_running(par.process) || error("parent exited before reaching t0 (see $(par.dir)/run.log)")
        time() - t > timeout_s && error("parent did not reach t0 in $(timeout_s) s")
        sleep(1)
    end
    return _json(f)
end

"""
    parent_command(par, cmd; timeout_s) -> Dict

`verify` → `{mismatched_blocks, counters, counters_equal}` · `resume` → 원래 세계에서 pi0 재개 · `exit`.
명령은 `control/<n>.cmd` 파일(원자적 rename), 답은 `control/<n>.out.json`.
"""
function parent_command(par, cmd::AbstractString; timeout_s = 600)
    ctl = joinpath(par.dir, "control")
    n = count(f -> endswith(f, ".cmd"), readdir(ctl)) + 1
    tmp = joinpath(ctl, "$(n).tmp")
    write(tmp, cmd); mv(tmp, joinpath(ctl, "$(n).cmd"))
    out = joinpath(ctl, "$(n).out.json")
    t = time()
    while !isfile(out)
        process_running(par.process) || error("parent died while handling `$(cmd)`")
        time() - t > timeout_s && error("parent did not answer `$(cmd)` in $(timeout_s) s")
        sleep(0.3)
    end
    sleep(0.2)                                  # 부모가 파일을 다 쓰고 닫을 시간
    return _json(out)
end

"실제 원장(부모의 모니터 스트림 파일)의 크기·digest — 분기 전후로 같아야 한다(분기는 원장에 못 쓴다)."
function ledger_digest(contract::AbstractDict)
    p = String(contract["real_ledger"])
    isfile(p) || return Dict("path" => p, "exists" => false)
    return Dict("path" => p, "exists" => true, "bytes" => filesize(p), "sha256" => bytes2hex(sha256(read(p))))
end

"디렉터리 전체(제어 파일 제외)의 (경로, 크기, sha256) digest — 대기 중인 부모의 출력은 분기 동안 한 바이트도 안 바뀌어야 한다."
function dir_digest(dir; exclude = ("control",))
    rows = String[]
    for (r, _, fs) in walkdir(dir), f in fs
        p = joinpath(r, f); rel = relpath(p, dir)
        any(e -> startswith(rel, e), exclude) && continue
        push!(rows, string(rel, "\t", filesize(p), "\t", bytes2hex(sha256(read(p)))))
    end
    return (n_files = length(rows), sha256 = bytes2hex(sha256(join(sort!(rows), "\n"))))
end

# ---- 분기 --------------------------------------------------------------------------------------
"""
    run_branch(; parent_dir, branch_id, outroot, launch_env, limits, action_file = "", sandbox = true)
        -> NamedTuple (report::RolloutReport, violations, checks, supervisor, dir)

새 프로세스·새 디렉터리(`outroot/branch_id`, 이미 있으면 에러)·새 원장 namespace 에서 부모의 t0 checkpoint 를
복원하고, (있으면) `action_file` 의 `branch_action!(env)` 를 부른 뒤 production continuation 으로 원래 예산까지
굴린다. 판정은 `validate_branch`(이 프로세스, 생성 코드 없음)가 한다.
"""
function run_branch(; parent_dir::AbstractString, branch_id::AbstractString, outroot::AbstractString,
                    launch_env::AbstractDict, limits::Limits, action_file::AbstractString = "",
                    sandbox::Bool = true, extra_env::AbstractDict = Dict{String,String}(),
                    proposal_file::AbstractString = "", mode::AbstractString = "full", on_tick = nothing)
    occursin(r"^[A-Za-z0-9_.-]+$", branch_id) || error("branch_id must be a plain name: $(branch_id)")
    all(k -> startswith(String(k), "ZRV_PROBE_"), keys(extra_env)) || error("extra_env may only carry ZRV_PROBE_* test keys")
    # T6: 생성 도구(ToolProposal JSON)는 `proposal_file` 로 — worker 가 등록·body·후처리·(full 이면) continuation.
    isempty(action_file) || isempty(proposal_file) || error("give action_file or proposal_file, not both")
    # T9 `observe`: 일회용 worker 가 t0 를 복원해 관측 파일(`observation.json`)만 쓰고 끝난다 — 동작·continuation 없음.
    mode in ("full", "preflight", "commit", "observe") || error("mode must be full|preflight|commit|observe")
    mode == "observe" && !(isempty(proposal_file) && isempty(action_file)) && error("observe mode runs no action or proposal")
    mode == "commit" && isempty(proposal_file) && error("commit mode replays a proposal — give proposal_file")
    dir = joinpath(outroot, branch_id)
    ispath(dir) && error("branch dir exists: $(dir) — each branch gets a fresh namespace")
    mkpath(joinpath(dir, "tmp"))
    contract = _json(joinpath(parent_dir, "contract.json"))
    token = branch_id * "-" * string(time_ns())
    env, removed = worker_env(launch_env, Dict("ZRV_REPLAY_MODE" => "resume", "ZRV_REPLAY_DIR" => dir,
        "ZRV_CHECKPOINT" => String(contract["envelope"]), "ZRV_BRANCH_ROLE" => "branch",
        "ZRV_BRANCH_ID" => branch_id, "ZRV_BRANCH_TOKEN" => token, "ZRV_BRANCH_ACTION" => action_file,
        "DEMO_OUT_DIR" => joinpath(dir, "out"), "TMPDIR" => joinpath(dir, "tmp"),
        "ZRV_RESULTS_DIR" => joinpath(dir, "results"),
        "ZRV_BRANCH_PROPOSAL" => proposal_file, "ZRV_BRANCH_MODE" => mode,
        "ZRV_TASK_CONTRACT" => joinpath(parent_dir, "task_contract.json"), extra_env...))
    cmd = `$JULIA --project=$ROOT -L $WORKER $RENDER`
    if sandbox
        rd = vcat(read_paths(), [joinpath(parent_dir, "ckpt"), String(contract["envelope"]),
                                 joinpath(parent_dir, "task_contract.json")])
        isempty(action_file) || push!(rd, action_file)
        isempty(proposal_file) || push!(rd, proposal_file)
        cmd = sandboxed(cmd; write = [String(dir), "/dev/null"], read = rd, limits)
    end
    _write(joinpath(dir, "launch.json"), Dict("branch_id" => branch_id, "token" => token, "sandbox" => sandbox,
        "action_file" => action_file, "proposal_file" => proposal_file, "mode" => mode, "env_names" => sort!(collect(keys(env))), "removed_env" => removed,
        "limits" => Dict("wall_s" => limits.wall_s, "cpu_s" => limits.cpu_s, "mem_bytes" => limits.mem_bytes),
        "cmd" => collect(cmd.exec)))
    sup = supervise(cmd, env, joinpath(dir, "run.log"); wall_s = limits.wall_s, token, on_tick)
    _write(joinpath(dir, "supervisor.json"), Dict(String(k) => v for (k, v) in pairs(sup)))
    return validate_branch(dir, contract; branch_id, sup)
end

# ---- trusted validator --------------------------------------------------------------------------
const SIGKILL, SIGXCPU = 9, 24

"스택/메시지로 원인 분류 — 오직 UNKNOWN 의 **원인 표기**에만 쓴다(판정을 바꾸지 않는다)."
function _error_cause(err::AbstractDict)
    k = String(get(err, "kind", ""))
    k == "identity_mismatch" && return :identity_mismatch
    k == "solver_error" && return :solver_error
    k == "resource_limit" && return :resource_limit
    return :worker_crash
end

"모니터 shadow 원장(JSONL)의 마지막 행 — respec_history·recovery 가 누적돼 있다."
function _last_ledger_row(dir)
    p = joinpath(dir, "shadow_MONITOR_IO.jsonl")
    isfile(p) || return nothing
    last = nothing
    for l in eachline(p)
        isempty(strip(l)) || (last = l)
    end
    return last === nothing ? nothing : JSON3.read(last, Dict{String,Any})   # 객체가 아니면 던진다(호출자가 거둔다)
end

"""
    validate_branch(dir, contract; branch_id, sup) -> NamedTuple

**생성 코드와 다른 프로세스**에서 고정 export(`terminal.json`·`error.json`·shadow JSONL)만 읽어 판정한다.
- 완료 = 부모 contract 의 원본 `ProjectComplete` 노드 id 가 **전부** export 의 closed id 에 있다(worker 의
  `complete` 필드는 안 쓴다). 종료 사유는 contract 의 예산으로 다시 계산한다.
- UNKNOWN 원인: wall 초과 → `:wall_timeout`, SIGXCPU/SIGKILL(우리 kill 아님)·OOM → `:resource_limit`,
  worker 오류 파일 → 분류, 그 밖의 비정상 종료·terminal 없음 → `:worker_crash`, 복원 불일치 → `:identity_mismatch`,
  pi0/예산 계약 위반 → `:contract_violation`(사유는 `violations`).
"""
function validate_branch(dir::AbstractString, contract::AbstractDict; branch_id::AbstractString, sup)
    cid = String(contract["checkpoint_id"])      # contract 는 부모(생성 코드 0)가 쓴 신뢰 입력
    violations = String[]
    checks = Dict{String,Any}("leftover_processes" => sup.leftover)
    # supervisor 가 직접 본 사실(파일 불필요)이 먼저다.
    sup_cause = sup.timed_out ? :wall_timeout :
                (sup.termsignal == SIGXCPU || (sup.termsignal == SIGKILL && !sup.timed_out)) ? :resource_limit : nothing
    reason, steps, ladder, recov = :none, 0, 0, Dict{String,Int}()
    cause = sup_cause
    # 🔴 worker 가 쓴 파일은 **적대적 입력**이다(생성 코드가 terminal.json 을 깨진 JSON·배열·틀린 타입으로 덮어쓰고
    #    exit 0 할 수 있다). 해석은 전부 이 try 안에서 하고, 어떤 형태로 깨져도 던지지 않고 UNKNOWN 으로 끝낸다 —
    #    validator 가 던지면 T6 후보 루프가 멈추고 t0 에서 기다리는 부모에게 exit 가 안 간다.
    try
        cause, reason, steps, ladder, recov = _judge_export!(violations, checks, dir, contract, cid, branch_id, sup, sup_cause)
    catch e
        e isa InterruptException && rethrow()
        empty!(violations); empty!(recov)
        push!(violations, "malformed export: " * first(sprint(showerror, e), 300))
        reason, steps, ladder = :none, 0, 0
        cause = sup_cause === nothing ? :contract_violation : sup_cause
        checks["malformed_export"] = true
    end
    outcome = cause !== nothing ? :UNKNOWN : reason === :project_complete ? :COMPLETE : :FAIL_WITHIN_BUDGET
    report = R.RolloutReport(String(branch_id), cid, outcome, cause, reason, steps, Float64(sup.wall_s),
                             Float64(sup.cpu_s), ladder, recov)
    return (; report, violations, checks, supervisor = sup, dir = String(dir))
end

"export 의 한 값을 기대 타입으로. 아니면 던진다(→ `validate_branch` 가 malformed export 로 거둔다)."
_typed(x, T, what) = x isa T ? x : throw(ArgumentError("$(what) is $(typeof(x)), expected $(T)"))
_strs(x, what) = String[_typed(v, AbstractString, "$(what)[]") for v in _typed(x, AbstractVector, what)]

"export 해석·판정 본체. 형태가 틀리면 던진다 — 호출자가 거둔다."
function _judge_export!(violations, checks, dir, contract, cid, branch_id, sup, sup_cause)
    tp, ep = joinpath(dir, "terminal.json"), joinpath(dir, "error.json")
    term = isfile(tp) ? _json(tp) : nothing        # 객체가 아니면(배열·숫자·깨진 JSON) 여기서 던진다
    err = isfile(ep) ? _json(ep) : nothing
    cause = sup_cause !== nothing ? sup_cause :
            err !== nothing ? _error_cause(err) :
            (sup.exitcode != 0 || term === nothing) ? :worker_crash : nothing
    err === nothing || (checks["error"] = Dict(k => (v = get(err, k, nothing); v isa AbstractString ? String(v) : v)
                                              for k in ("stage", "kind", "exception_type", "message")))
    reason, steps, ladder, recov = :none, 0, 0, Dict{String,Int}()
    if term !== nothing
        iter = _typed(term["iter"], Integer, "terminal.iter")
        steps = iter - Int(contract["t0_iter"])
        b = get(term, "branch", nothing)
        if !(b isa AbstractDict) || get(b, "schema", "") != EXPORT_SCHEMA
            push!(violations, "export schema missing/other than $(EXPORT_SCHEMA)")
        else
            b["id"] == branch_id || push!(violations, "export branch id $(b["id"]) != $(branch_id)")
            b["checkpoint_id"] == cid || push!(violations, "export checkpoint $(b["checkpoint_id"]) != $(cid)")
            res = _typed(term["resume"], AbstractDict, "terminal.resume")
            mb, dg, fm = (_typed(res[k], AbstractVector, "resume.$(k)")
                          for k in ("mismatched_blocks", "dispatch_guard", "fingerprint_mismatches"))
            idok = isempty(mb) && isempty(dg) && isempty(fm)
            checks["identity"] = Dict("mismatched_blocks" => mb, "dispatch_guard" => dg, "fingerprint_mismatches" => fm,
                                      "rvo_ties" => [_typed(w, AbstractDict, "rvo_tie_watch[]")["ties"]
                                                     for w in _typed(res["rvo_tie_watch"], AbstractVector, "resume.rvo_tie_watch")])
            idok || (cause === nothing && (cause = :identity_mismatch))
            # import 가 되살린 자격 증명 모양 키를 worker 가 지웠다면 분기 ENV 가 capture 와 그 키만큼 다르다(이름만).
            checks["env_scrubbed_after_import"] = _strs(get(b, "env_scrubbed_after_import", String[]), "env_scrubbed_after_import")
            # 예산: 원래 episode 의 절대 예산 그대로여야 한다(분기가 늘릴 수 없다).
            sp = _typed(b["sim_params"], AbstractDict, "branch.sim_params")
            for k in ("max_time_steps", "max_num_iters_no_progress", "sim_batch_size")
                get(sp, k, nothing) == contract["sim_params"][k] ||
                    push!(violations, "budget $(k) = $(get(sp, k, nothing)) != original $(contract["sim_params"][k])")
            end
            iter <= contract["sim_params"]["max_time_steps"] ||
                push!(violations, "horizon $(iter) exceeds max_time_steps")
            # pi0: 존 NOOP · 존 전용 solver/사다리 차단 · 레인 고정. 분기 시작(t0 import 뒤)과 끝 두 번 본다.
            for (when, key) in (("t0", "pi0_t0"), ("end", "pi0_end"))
                s = _typed(b[key], AbstractDict, "branch.$(key)")
                for (k, v) in contract["pi0"]
                    get(s, k, nothing) == v || push!(violations, "pi0 $(k) at $(when) = $(get(s, k, nothing)) != $(v)")
                end
            end
            # 감사 경계가 **관측한** runtime override 는 계약 위반이다(못 관측한 것은 능력표가 enforce 를 막는다).
            mc = _strs(get(_typed(get(b, "audit", Dict()), AbstractDict, "branch.audit"), "methods_changed_by_action", String[]),
                       "methods_changed_by_action")
            isempty(mc) || push!(violations, "runtime methods changed by the action: $(join(mc, ", "))")
            ladder = _typed(get(_typed(b["ablation_counts"], AbstractDict, "branch.ablation_counts"), "ladder_zone_fired", 0),
                            Integer, "ladder_zone_fired")
            ladder == 0 || push!(violations, "zone ladder fired $(ladder) times")
            # 원장에 안 남는 명목 레인 복구(`maybe_unwedge_nominal!`)는 판 카운터에서 센다(T10a).
            for (k, v) in b["ablation_counts"]
                startswith(String(k), "recovery:") && (recov[String(k)] = get(recov, String(k), 0) + Int(v))
            end
            row = _last_ledger_row(dir)
            if row === nothing
                push!(violations, "shadow ledger missing (cannot check zone decisions)")
            else
                for d in _typed(row["respec_history"], AbstractVector, "ledger.respec_history")
                    ev = String(d["input"]["event"]); ch = String(d["chosen"])
                    k = "decision:$(ev):$(first(split(ch)))"; recov[k] = get(recov, k, 0) + 1
                    ev == "ZONE" && !startswith(ch, "NOOP") && push!(violations, "zone decision $(ch) (pi0 requires NOOP)")
                end
                for r in _typed(row["recovery"], AbstractVector, "ledger.recovery")
                    k = "recovery:$(r["action"]):$(r["status"])"; recov[k] = get(recov, k, 0) + 1
                end
            end
            closed = Set(_strs(b["closed_node_ids"], "branch.closed_node_ids"))
            req = String.(contract["required_ids"])
            complete = !isempty(req) && all(in(closed), req)
            np, mx = _typed(term["no_progress"], Integer, "terminal.no_progress"), Int(contract["sim_params"]["max_time_steps"])
            reason = complete ? :project_complete :
                     np >= contract["sim_params"]["max_num_iters_no_progress"] ? :no_progress_limit :
                     iter >= mx ? :max_sim_steps : :none
            claimed = get(term, "complete", nothing); creason = get(term, "terminal_reason", nothing)
            checks["worker_claimed"] = Dict("complete" => claimed, "terminal_reason" => creason)
            checks["claim_agrees"] = claimed === complete && creason isa AbstractString && String(creason) == String(reason)
            reason === :none && push!(violations, "ended without a budget terminal")
        end
        # 계약 위반이 있으면 그 판은 정의된 실험(pi0·원래 예산)의 결과가 아니다. 위반 없이 종료 사유만 없으면 crash.
        if cause === nothing && !isempty(violations)
            cause = violations == ["ended without a budget terminal"] ? :worker_crash : :contract_violation
        end
    end
    return cause, reason, steps, ladder, recov
end

"보고서 한 장을 JSON 으로(기록용)."
report_dict(v) = Dict("branch" => v.report.branch, "checkpoint_id" => v.report.checkpoint_id,
    "outcome" => String(v.report.outcome),
    "unknown_cause" => v.report.unknown_cause === nothing ? nothing : String(v.report.unknown_cause),
    "terminal_reason" => String(v.report.terminal_reason), "sim_steps" => v.report.sim_steps,
    "wall_s" => v.report.wall_s, "cpu_s" => v.report.cpu_s, "zone_ladder_fired" => v.report.zone_ladder_fired,
    "general_recovery" => v.report.general_recovery, "violations" => v.violations, "checks" => v.checks,
    "dir" => v.dir)

# ---- 능력표 ------------------------------------------------------------------------------------
"""
    sandbox_capabilities(dir) -> Dict

경계마다 **음성 시험**(샌드박스 안에서 금지 동작 시도 → 막혀야 한다)과 **양성 대조**(같은 동작이 샌드박스 밖에서는
된다 — 시험이 항진이 아님)를 실제로 돌려 표로 만든다. `enforce_allowed` 는 설계 §6.1 의 필수 경계가 **전부**
enforced 일 때만 true — 같은 프로세스 override 는 이 호스트·이 런타임에서 원리상 막을 수 없어 항상 false 다.
"""
function sandbox_capabilities(dir::AbstractString)
    mkpath(dir)
    inside = mkpath(joinpath(dir, "inside")); outside = mkpath(joinpath(dir, "outside"))
    lim = Limits(wall_s = 30, cpu_s = 20, mem_bytes = 2_000_000_000)
    py = python3()
    token = "cap-" * string(time_ns())
    env = merge(base_env(), Dict("ZRV_BRANCH_TOKEN" => token))
    run_py(code; sb = true, e = env) = begin
        c = Cmd([py, "-c", code])
        c = sb ? sandboxed(c; write = [inside, "/dev/null"], limits = lim) : c
        pipe = Pipe()
        p = run(pipeline(ignorestatus(setenv(c, e)); stdout = pipe, stderr = pipe); wait = false)
        close(pipe.in)
        o = read(pipe, String); wait(p)
        (code = p.exitcode, signal = p.termsignal, out = o)
    end
    caps = Dict{String,Any}()
    rec!(name, enforced, neg, pos; note = "") =
        (caps[name] = Dict("enforced" => enforced, "negative" => neg, "positive_control" => pos, "note" => note))

    # 1. host write 밖
    tgt = joinpath(outside, "probe.txt")
    neg = run_py("open('$(tgt)','w').write('x')")
    pos = run_py("open('$(tgt)','w').write('x')"; sb = false)
    rec!("host_write_outside_branch_dir", neg.code != 0 && occursin("Permission", neg.out) && pos.code == 0,
         neg.out[max(1, end - 200):end], pos.code; note = "Landlock: write/create/remove only beneath the branch dir")
    rm(tgt; force = true)
    # 2. 자격 증명 읽기: 다른 프로세스 environ(여기선 supervisor 자신), 홈의 dotfile
    neg = run_py("open('/proc/$(getpid())/environ','rb').read(1)")
    pos = run_py("open('/proc/$(getpid())/environ','rb').read(1)"; sb = false)
    rec!("read_foreign_proc_environ", neg.code != 0 && pos.code == 0, neg.out[max(1, end - 200):end], pos.code;
         note = "same-uid /proc/<pid>/environ holds API keys; Landlock read allowlist excludes /proc except self")
    hf = joinpath(homedir(), ".bashrc")
    if isfile(hf)
        neg = run_py("open('$(hf)','rb').read(1)"); pos = run_py("open('$(hf)','rb').read(1)"; sb = false)
        rec!("read_home_dotfiles", neg.code != 0 && pos.code == 0, neg.out[max(1, end - 200):end], pos.code)
    end
    # 3. env 세척: 거부 이름을 가진 launch env 를 넘겨도 worker env 에 없다
    fake = Dict("OPENAI_API_KEY" => "zrv-dummy-not-a-key", "DSPY_URL" => "http://127.0.0.1:1", "DEMO_SEED" => "1")
    wenv, removed = worker_env(fake, Dict("ZRV_BRANCH_TOKEN" => token))
    neg = run_py("import os;print(sorted(k for k in os.environ if k in ('OPENAI_API_KEY','DSPY_URL')))"; e = wenv)
    rec!("credential_env_scrubbed", endswith(strip(neg.out), "[]") && removed == ["DSPY_URL", "OPENAI_API_KEY"],
         neg.out[max(1, end - 120):end], removed; note = "env is rebuilt from scratch; denied names removed (values never logged)")
    # 4. 네트워크: TCP connect 는 local listener 로 잰다(서비스 호출 수가 늘지 않는가 = 받은 연결 수)
    srv = listen(ip"127.0.0.1", 0); port = Int(getsockname(srv)[2])
    accepted = Ref(0); acc = @async while true
        s = try accept(srv) catch; break end
        accepted[] += 1; close(s)
    end
    neg = run_py("import socket;socket.create_connection(('127.0.0.1',$(port)),timeout=3)")
    sleep(0.3); n_neg = accepted[]
    pos = run_py("import socket;socket.create_connection(('127.0.0.1',$(port)),timeout=3)"; sb = false)
    sleep(0.3); n_pos = accepted[] - n_neg
    close(srv)
    rec!("tcp_connect", neg.code != 0 && n_neg == 0 && n_pos == 1, neg.out[max(1, end - 200):end], n_pos;
         note = "Landlock NET: connect(TCP) denied for every port; listener accepted $(n_neg) from the sandbox")
    # UDP 는 Landlock 이 다루지 않는다 — 막히지 않는다는 것을 **측정**해 적는다.
    us = UDPSocket(); uport = 40000 + Int(time_ns() % 20000); bind(us, ip"127.0.0.1", uport)
    got = Ref(false); rt = @async (try recv(us); got[] = true catch end)
    run_py("import socket;socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b'x',('127.0.0.1',$(uport)))")
    sleep(0.5); close(us)
    rec!("udp_send", !got[], got[] ? "datagram RECEIVED from the sandbox" : "not received", nothing;
         note = "Landlock ABI has no UDP control; unprivileged seccomp not wired → exfiltration over UDP possible")
    # 5. signal scope: 도메인 밖 프로세스에 signal 금지
    neg = run_py("import os;os.kill($(getpid()),0)")
    pos = run_py("import os;os.kill($(getpid()),0)"; sb = false)
    rec!("signal_outside_domain", neg.code != 0 && pos.code == 0, neg.out[max(1, end - 200):end], pos.code;
         note = "Landlock scope SIGNAL (ABI>=6)")
    # 6. 자원 한도: CPU·메모리
    t = time()
    neg = run_py("while True: pass"; e = env)
    rec!("cpu_limit", neg.signal in (SIGXCPU, SIGKILL) && time() - t < 60, "signal=$(neg.signal) after $(round(time() - t; digits = 1)) s", nothing;
         note = "RLIMIT_CPU=$(lim.cpu_s)s (soft SIGXCPU, hard +5s SIGKILL)")
    neg = run_py("b=bytearray(3_000_000_000);print('ALLOCATED')")
    pos = run_py("b=bytearray(3_000_000_000);print('ALLOCATED')"; sb = false)
    rec!("memory_limit", !occursin("ALLOCATED", neg.out) && occursin("ALLOCATED", pos.out),
         neg.out[max(1, end - 120):end], occursin("ALLOCATED", pos.out); note = "RLIMIT_AS=$(lim.mem_bytes) B")
    # 7. wall timeout + 하위 트리 정리(setsid 로 그룹을 벗어난 손자 포함)
    c = sandboxed(`sh -c "sleep 1000 & setsid sleep 1001 & sleep 1002"`; write = [inside, "/dev/null"], limits = lim)
    s = supervise(c, env, joinpath(dir, "tree.log"); wall_s = 2, token)
    rec!("wall_timeout_kills_tree", s.timed_out && s.token_procs_at_kill >= 3 && s.leftover == 0 && isempty(token_pids(token)),
         "timed_out=$(s.timed_out) leftover=$(s.leftover)", s.token_procs_at_kill;
         note = "process group kill + ZRV_BRANCH_TOKEN /proc sweep (catches setsid escapees that keep the env)")
    # 8. 원리상 못 막는 것(같은 프로세스 안) — 측정이 아니라 선언. enforce 를 막는 값이다.
    rec!("same_process_runtime_override", false, "not enforceable", nothing;
         note = "Julia has no in-process capability boundary: generated code in the worker can redefine methods " *
                "(continuation, export writer, audit) before they run; the worker's export can be forged")
    sock = "/tmp/zrv-cap-$(getpid())-$(time_ns() % 100000).sock"      # sun_path ≤ 108 B
    us2 = listen(sock); n_unix = Ref(0)
    @async while true
        c2 = try accept(us2) catch; break end
        n_unix[] += 1; close(c2)
    end
    run_py("import socket;s=socket.socket(socket.AF_UNIX);s.connect('$(sock)')")
    sleep(0.3); close(us2); rm(sock; force = true)
    rec!("pathname_unix_socket_connect", n_unix[] == 0, "listener accepted $(n_unix[]) from the sandbox", nothing;
         note = "a local service on a pathname unix socket outside the branch dir")
    required = ["host_write_outside_branch_dir", "read_foreign_proc_environ", "credential_env_scrubbed",
                "tcp_connect", "udp_send", "cpu_limit", "memory_limit", "wall_timeout_kills_tree",
                "same_process_runtime_override", "pathname_unix_socket_connect"]
    abi = try strip(read(`$(py) -c "import ctypes;l=ctypes.CDLL(None);l.syscall.restype=ctypes.c_long;print(l.syscall(444,None,0,1))"`, String)) catch; "?" end
    out = Dict("schema" => "sandbox-capabilities/1", "host" => gethostname(), "kernel" => strip(read(`uname -r`, String)),
               "landlock_abi" => abi, "capabilities" => caps,
               "not_enforced" => sort!([k for k in required if !(haskey(caps, k) && caps[k]["enforced"] === true)]),
               "enforce_allowed" => all(k -> haskey(caps, k) && caps[k]["enforced"] === true, required))
    _write(joinpath(dir, "capabilities.json"), out)
    return out
end

end # module BranchRunner
