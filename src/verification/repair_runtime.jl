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
isdefined(Main, :RepairGeometryControl) || include(joinpath(@__DIR__, "..", "..", "tools", "monitor", "repair_geometry_control.jl"))

module RepairRuntime

using JSON3, SHA
import HTTP
import ..RepairTypes as R
import ..BranchRunner as BR
import ..RepairSupervisor as RS
import ..ToolExecution as TX
import ..RepairGeometryControl as GCTL

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
            # T9: null 도 부재다(값 없는 도장이 아래 대조를 조용히 건너뛰지 않게)
            source === :service && get(prov, k, nothing) === nothing && push!(g, "proposal $(id): service proposal lacks provenance.$(k)")
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

# ---- 부모·분기에 넘기는 env: 허용 목록 ------------------------------------------------------------
const POLICY_JL = joinpath(ROOT, "tools", "monitor", "policy.jl")
"런타임이 읽는 비설정 이름(설정 인벤토리 밖): julia 패키지/스레드 손잡이와 PyCall 인터프리터."
const RUNTIME_ENV_NAMES = ("PYTHON", "CB_PYTHON")
const RUNTIME_ENV_PREFIXES = ("JULIA_",)

"""
    config_env_inventory() -> (; names::Set{String}, prefixes::Vector{String})

설정 지문의 ENV 분류(`tools/monitor/policy.jl` 의 `CONFIG_ENV_RESULT`·`CONFIG_ENV_CELL_AXIS`·`CONFIG_ENV_OBSERVATIONAL`·
`_CONFIG_ENV_PREFIXES`)를 **그 파일에서** 읽는다 — 목록을 다시 적지 않는다. policy.jl 을 실행하지 않고 구문만 읽는다(driver 는 CB·HTTP
를 싣지 않는다). 네 값이 문자열 리터럴 배열/튜플이 아니면 오류(조용히 빈 허용 목록이 되지 않는다).
"""
function config_env_inventory()
    want = Dict("CONFIG_ENV_RESULT" => :n, "CONFIG_ENV_CELL_AXIS" => :n, "CONFIG_ENV_OBSERVATIONAL" => :n, "_CONFIG_ENV_PREFIXES" => :p)
    names = Set{String}(); prefixes = String[]; seen = Set{String}()
    for x in Meta.parseall(read(POLICY_JL, String)).args
        (x isa Expr && x.head === :const && x.args[1] isa Expr && x.args[1].head === :(=)) || continue
        k = string(x.args[1].args[1]); haskey(want, k) || continue
        v = x.args[1].args[2]
        (v isa Expr && v.head in (:vect, :tuple) && all(a -> a isa String, v.args)) ||
            error("$(POLICY_JL): $(k) is not a literal list of strings — cannot build the env allowlist")
        want[k] === :n ? union!(names, v.args) : append!(prefixes, v.args)
        push!(seen, k)
    end
    seen == Set(keys(want)) || error("$(POLICY_JL): missing $(setdiff(Set(keys(want)), seen)) — cannot build the env allowlist")
    return (; names, prefixes)
end

"""
    launch_env_from(env) -> Dict{String,String}

부모·분기 worker 에 넘기는 셀 env. 🔴 **허용 목록**이다(T8 리뷰): 운영자 셸의 나머지(이름이 비밀 패턴에 안 걸리는 토큰·DSN·
KUBECONFIG …)는 넘어가지 않는다 — 분기는 생성 코드를 돌리고 능력표상 UDP·unix socket 유출을 못 막는다. 허용 = 설정 인벤토리
(render 경로가 읽는 모든 이름, `config_env_inventory`) ∪ 그 접두사 ∪ `RUNTIME_ENV_*`, `ZRV_*` 는 뺀다(하니스가 새로 단다).
두 번째 층으로 `BranchRunner.worker_env` 가 `DENY_ENV` 이름 패턴(자격 증명·`_URL`)을 또 지운다. 부모와 분기가 **같은** 목록을 받으므로
신원 digest 는 그대로 맞는다.
"""
function launch_env_from(env::AbstractDict)
    inv = config_env_inventory()
    ok(k) = !startswith(k, "ZRV_") && (k in inv.names || k in RUNTIME_ENV_NAMES ||
                                        any(p -> startswith(k, p), inv.prefixes) || any(p -> startswith(k, p), RUNTIME_ENV_PREFIXES))
    return Dict{String,String}(String(k) => String(v) for (k, v) in env if ok(String(k)))
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

# ---- T9: 서비스 제안 source (일반 MAS → 코드 후보, 호출·후보 예산) ------------------------------------
const ARMS = ("general", "geometry")
"설계 §7.2 의 고정값: 후보 K=4, 모델 호출 4회(observe 1 · design 1 · compose 1 · compose_revision 1)."
const MODEL_K = 4
const MODEL_CALLS = 4

"`ZONE_REPAIR_ARM` — 정확히 `general|geometry`. 그 밖은 오류다(오타가 주 팔↔G4 로 조용히 접히지 않는다)."
parse_arm(s::AbstractString) = s in ARMS ? String(s) :
    error("ZONE_REPAIR_ARM=$(repr(s)) is not one of general|geometry (no fallback)")

"""
    service_budget(env) -> Dict

모델 예산. token·cost 한도는 **기본값이 없다**(설계 §7.2·manifest 가 필수로 요구) — 없거나 양수가 아니면 오류.
"""
function service_budget(env::AbstractDict)
    t = tryparse(Int, strip(get(env, "ZONE_REPAIR_MAX_TOTAL_TOKENS", "")))
    c = tryparse(Float64, strip(get(env, "ZONE_REPAIR_MAX_COST_USD", "")))
    (t === nothing || t < 1) && error("[zrv] the service source needs ZONE_REPAIR_MAX_TOTAL_TOKENS (a positive integer, no default)")
    (c === nothing || !(c > 0)) && error("[zrv] the service source needs ZONE_REPAIR_MAX_COST_USD (a positive number, no default)")
    return Dict{String,Any}("max_model_calls" => MODEL_CALLS, "max_candidates" => MODEL_K,
                            "max_total_tokens" => t, "max_cost_usd" => c)
end

"""
    proposal_source(env; mode) -> (; source, fixture, url, arm, budget)

후보 source 는 **정확히 하나**: fixture(`ZONE_REPAIR_PROPOSALS`) 또는 서비스(`DSPY_URL`). 🔴 둘 다 있으면 오류다(T8 까지는
fixture 가 조용히 이겼다). enforce 는 fixture 를 거절한다. `ZONE_REPAIR_ARM`·예산 손잡이는 서비스에서만 뜻이 있어 fixture 와
함께 오면 오류다(무시되는 손잡이를 남기지 않는다).
"""
function proposal_source(env::AbstractDict; mode::Symbol)
    pf, url = strip(get(env, "ZONE_REPAIR_PROPOSALS", "")), strip(get(env, "DSPY_URL", ""))
    !isempty(pf) && !isempty(url) &&
        error("[zrv] both ZONE_REPAIR_PROPOSALS (fixture) and DSPY_URL (service) are set — choose exactly one proposal source")
    if !isempty(pf)
        mode === :enforce && error("[zrv] ZONE_REPAIR_VERIFICATION=enforce refuses a fixture proposal source (ZONE_REPAIR_PROPOSALS)")
        for k in ("ZONE_REPAIR_ARM", "ZONE_REPAIR_MAX_TOTAL_TOKENS", "ZONE_REPAIR_MAX_COST_USD")
            isempty(strip(get(env, k, ""))) || error("[zrv] $(k) only applies to the service source, not to a fixture file")
        end
        return (; source = :fixture, fixture = String(pf), url = "", arm = "fixture", budget = nothing)
    end
    isempty(url) && error("[zrv] no proposal source: set ZONE_REPAIR_PROPOSALS (fixture file) or DSPY_URL (service)")
    return (; source = :service, fixture = "", url = String(url), arm = parse_arm(get(env, "ZONE_REPAIR_ARM", "general")),
            budget = service_budget(env))
end

"""
t0 경계 오류만 모델에 되먹인다(설계 §6.1): 문/등록 거절, t0 throw·partial, 효과·post-enactment 계약·후처리·unsupported,
G4 변환 거절. 🔴 `requires_runtime` 은 거절이 아니고, 판정 기반의 부재(계약 없음·export 없음·cross_check·timeout)는 모델 오류가
아니므로 빠진다. full rollout 결과는 이 함수에 올 일이 없다(preflight 만 부른다).
"""
const T0_FEEDBACK_PREFIXES = ("reject:", "enactment threw", "enactment registration_rejected", "enactment partial",
                              "effects ", "post-enactment contract:", "postprocess_failed:", "unsupported:")
t0_feedback(reasons) = String[String(r) for r in reasons if any(p -> startswith(String(r), p), T0_FEEDBACK_PREFIXES)]

"U1 = 동결 목록의 첫 후보, U4 = V4 = 같은 목록 전체(설계 §9.2). G4 는 자기 목록."
function arm_views(frozen; arm::AbstractString)
    ids = [String(p["proposal_id"]) for p in sort(collect(frozen); by = p -> Int(p["submission_index"]))]
    arm == "general" && return Dict{String,Any}("U1" => first(ids, 1), "U4" => ids, "V4" => ids)
    arm == "geometry" && return Dict{String,Any}("G4" => ids)
    return Dict{String,Any}("fixture" => ids)
end

"서비스 POST. 🔴 `retries = 0` — HTTP 재전송은 유료 파이프라인을 원장 밖에서 다시 돌린다."
function service_post(url::AbstractString, path::AbstractString, body::AbstractDict)
    t = something(tryparse(Int, strip(get(ENV, "DSPY_TIMEOUT_S", ""))), 300) * MODEL_CALLS
    r = HTTP.post(rstrip(url, '/') * path, ["Content-Type" => "application/json"], JSON3.write(body);
                  readtimeout = t, retries = 0, status_exception = false)
    r.status == 200 || error("HTTP $(r.status) from $(path): $(first(String(r.body), 300))")
    return JSON3.read(String(r.body), Dict{String,Any})
end

"t0 관측: 일회용 observe worker(부모 checkpoint 복원 — 부모는 관측 코드를 안 돈다). 못 만들면 nothing."
function observe_via_worker(parent_dir, dir, launch_env, limits)
    BR.run_branch(; parent_dir, branch_id = "observe", outroot = dir, launch_env, limits, mode = "observe")
    f = joinpath(dir, "observe", "observation.json")
    return isfile(f) ? _json(f) : nothing
end

"t0 preflight(T6): 새 샌드박스 worker 가 첫 engine 진행 요청 직전까지. 반환 = `execute_tool_isolated` 결과."
preflight_via_worker(parent_dir, dir, raw, i, launch_env, limits) =
    TX.execute_tool_isolated(; parent_dir, raw, outroot = joinpath(dir, "preflight"), branch_id = "pre-$(i)",
                             launch_env, limits, mode = "preflight")

"응답 계약: 팔 일치 · 후보 종류가 팔과 같다 · id 유일 · 원장이 예산 안. 어긋나면 gap(→ 인증 불가, 조용히 얼리지 않는다)."
function response_gaps(resp::AbstractDict; arm::AbstractString, stage::AbstractString)
    g = String[]
    get(resp, "arm", nothing) == arm || push!(g, "$(stage): service answered arm $(repr(get(resp, "arm", nothing))) for a $(arm) request")
    want = arm == "general" ? R.TOOL_PROPOSAL_SCHEMA_VERSION : GCTL.GEOMETRY_PATCH_SCHEMA_VERSION
    for c in get(resp, "candidates", Any[])
        c isa AbstractDict && get(c, "schema_version", nothing) == want ||
            push!(g, "$(stage): a candidate is not a $(want) (arm $(arm)) — no fallback between arms")
    end
    led = get(resp, "ledger", nothing)
    if led isa AbstractDict
        get(led, "calls_used", 0) <= MODEL_CALLS || push!(g, "$(stage): ledger reports $(led["calls_used"]) model calls > $(MODEL_CALLS)")
        get(led, "submitted", 0) <= MODEL_K || push!(g, "$(stage): ledger reports $(led["submitted"]) candidates > K=$(MODEL_K)")
    else
        push!(g, "$(stage): service response carries no call/candidate ledger")
    end
    return g
end

_new_record_id() = bytes2hex(sha256(string(time_ns(), "|", getpid(), "|zrv-t9")))[1:24]

"""
    service_proposals!(; parent_dir, root, url, arm, budget, launch_env, run_ctx, limits = LIMITS,
                       post = service_post, observe = observe_via_worker, preflight = preflight_via_worker)
        -> (; proposals::Vector{Dict}, record::Dict, gaps::Vector{String})

T8 이 남긴 서비스 source 슬롯. t0 에서:
  1. 관측 — 일회용 observe worker 가 `observation.json`(결정 레인과 같은 `/decide` 페이로드 + G4 기하 문맥).
  2. `/zone_repair/propose` — observe 1 · design 1 · compose 1(후보 batch). 서비스 원장이 호출·후보를 센다.
  3. G4 면 patch → ToolProposal(`RepairGeometryControl.patch_to_proposal`; 변환 거절은 t0 정적 사유).
  4. 후보마다 t0 preflight(T6, 병렬) → t0 경계 사유(`t0_feedback`)만 모은다.
  5. 사유가 있고 호출·후보가 남으면 `/zone_repair/revise` 한 번(남은 후보 몫 안). 수정본은 preflight 하지 않는다(더 되먹일 호출이 없다).
  6. 동결 목록 = 제출 순서, 거절 기록·preflight 기록·원장과 함께 `<root>/proposal_source/frozen_list.json`.
서비스 오류·관측 실패는 **후보 0개**(기록에 사유) — B0 는 그대로 잰다. 응답 계약 위반은 gap.
`post`·`observe`·`preflight` 는 시험이 바꿔 끼운다.
"""
function service_proposals!(; parent_dir::AbstractString, root::AbstractString, url::AbstractString, arm::AbstractString,
                            budget::AbstractDict, launch_env::AbstractDict, run_ctx::AbstractDict, limits = LIMITS,
                            post = service_post, observe = observe_via_worker, preflight = preflight_via_worker)
    parse_arm(arm)
    dir = joinpath(root, "proposal_source"); mkpath(dir)
    cid = String(_json(joinpath(parent_dir, "contract.json"))["checkpoint_id"])
    rec = Dict{String,Any}("arm" => arm, "budget" => budget, "status" => "ok", "submissions" => Dict{String,Any}[],
                           "responses" => Dict{String,Any}[], "gaps" => String[])
    gaps = rec["gaps"]
    frozen = Dict{String,Any}[]
    finish() = (rec["frozen_proposal_ids"] = [p["proposal_id"] for p in frozen];
                _write(joinpath(dir, "frozen_list.json"), merge(rec, Dict("frozen" => frozen)));
                (; proposals = frozen, record = rec, gaps))
    obs = try observe(parent_dir, dir, launch_env, limits) catch e
        rec["observe_error"] = first(sprint(showerror, e), 500); nothing
    end
    if obs === nothing
        rec["status"] = "observation_failed"
        return finish()
    end
    gctx = get(obs, "geometry_context", Dict{String,Any}())
    base = Dict{String,Any}("arm" => arm, "checkpoint_id" => cid, "budget" => budget, "run_ctx" => run_ctx,
                            "capability_contract_version" => R.DEFAULT_CAPABILITY_CONTRACT.version)
    arm == "geometry" && (base["geometry_context"] = gctx)
    rid = _new_record_id()
    r1 = try post(url, "/zone_repair/propose", merge(base, Dict("request" => obs["request"], "record_id" => rid))) catch e
        rec["status"] = "service_error: " * first(sprint(showerror, e), 300)
        return finish()
    end
    push!(rec["responses"], Dict{String,Any}(k => v for (k, v) in r1 if k != "candidates"))
    append!(gaps, response_gaps(r1; arm, stage = "propose"))
    isempty(gaps) || return finish()
    # ---- 3·4. 변환(G4)과 t0 preflight ------------------------------------------------------------
    subs = rec["submissions"]
    first_cands = Dict{String,Any}[]
    for c in get(r1, "candidates", Any[])
        s = Dict{String,Any}("proposal_id" => c["proposal_id"], "submission_index" => c["submission_index"],
                             "stage" => "compose", "parent_proposal_id" => get(c, "parent_proposal_id", nothing))
        if arm == "geometry"
            cv = GCTL.patch_to_proposal(c, gctx; checkpoint_id = cid)
            if cv.proposal === nothing
                s["frozen"] = false; s["rejected_before_freeze"] = cv.reasons; s["t0_feedback"] = cv.reasons
                s["revisable_source"] = c
                push!(subs, s); continue
            end
            c = cv.proposal
        end
        s["frozen"] = true
        push!(subs, s); push!(first_cands, c)
    end
    pre = asyncmap(i -> (try preflight(parent_dir, dir, first_cands[i], i, launch_env, limits) catch e
                             (; gate = nothing, eligible = false, feedback_allowed = false, reasons = [first(sprint(showerror, e), 300)],
                              feedback = String[], judged = nothing, run = nothing) end), eachindex(first_cands); ntasks = 4)
    for (c, x) in zip(first_cands, pre)
        s = only(filter(s -> s["proposal_id"] == c["proposal_id"], subs))
        fb = x.feedback_allowed ? t0_feedback(x.feedback) : String[]
        s["preflight"] = Dict{String,Any}("reasons" => x.reasons, "feedback_allowed" => x.feedback_allowed,
            "enactment_status" => (x.judged === nothing ? nothing : String(x.judged.enactment.status)))
        s["t0_feedback"] = fb
        s["revisable_source"] = arm == "geometry" ? c["provenance"]["geometry_patch"] : c
    end
    append!(frozen, first_cands)
    # ---- 5. 선택적 수정 호출 --------------------------------------------------------------------------
    led = r1["ledger"]
    rejected = Dict{String,Any}[]
    for s in subs
        isempty(get(s, "t0_feedback", String[])) && continue
        r = Dict{String,Any}("proposal_id" => s["proposal_id"], "reasons" => s["t0_feedback"])
        arm == "general" ? (r["impl_code"] = get(s["revisable_source"], "impl_code", nothing)) :
                           (r["patch"] = s["revisable_source"])
        push!(rejected, r)
    end
    foreach(s -> delete!(s, "revisable_source"), subs)
    can = led["calls_used"] < MODEL_CALLS && led["submitted"] < MODEL_K && !isempty(rejected) &&
          get(r1, "compose_input", nothing) isa AbstractDict
    rec["revision"] = Dict{String,Any}("attempted" => can, "n_rejected_at_t0" => length(rejected),
        "calls_used_before" => led["calls_used"], "submitted_before" => led["submitted"])
    if can
        r2 = try post(url, "/zone_repair/revise", merge(base, Dict("ledger" => led, "compose_input" => r1["compose_input"],
                      "rejected" => rejected,
                      "record_id" => _new_record_id(), "parent_record_id" => rid))) catch e
            rec["revision"]["error"] = "service_error: " * first(sprint(showerror, e), 300); nothing
        end
        if r2 !== nothing
            push!(rec["responses"], Dict{String,Any}(k => v for (k, v) in r2 if k != "candidates"))
            append!(gaps, response_gaps(r2; arm, stage = "revise"))
            isempty(gaps) || return finish()
            for c in get(r2, "candidates", Any[])
                s = Dict{String,Any}("proposal_id" => c["proposal_id"], "submission_index" => c["submission_index"],
                                     "stage" => "compose_revision", "parent_proposal_id" => get(c, "parent_proposal_id", nothing))
                if arm == "geometry"
                    cv = GCTL.patch_to_proposal(c, gctx; checkpoint_id = cid)
                    cv.proposal === nothing && (s["frozen"] = false; s["rejected_before_freeze"] = cv.reasons; push!(subs, s); continue)
                    c = cv.proposal
                end
                s["frozen"] = true; push!(subs, s); push!(frozen, c)
            end
        end
    end
    # ---- 6. 동결 ------------------------------------------------------------------------------------
    sort!(frozen; by = p -> Int(p["submission_index"]))
    ids = [p["proposal_id"] for p in frozen]
    allunique(ids) || push!(gaps, "proposal ids are not unique across the propose/revise responses: $(ids)")
    length(frozen) <= MODEL_K || push!(gaps, "$(length(frozen)) frozen candidates > K=$(MODEL_K)")
    return finish()
end

"""
    run_episode!(; mode, launch_env, root, proposals, source, url = "", capabilities = nothing, out_dir,
                 noise_floor = :measure, baseline_override = nothing, log_io = stdout, campaign_dir = root,
                 commit_id = "commit", arm = "general", budget = nothing) -> Dict

한 에피소드(설계 §3.1: 첫 존 사건에서 최대 한 repair transaction). 반환 = `<root>/episode.json` 의 내용(`exit_code` 포함).
`capabilities`·`baseline_override` 를 손으로 넘기는 것은 시험뿐이다(`main` 은 실측값만 넘기고 override 를 안 넘긴다).
T9: `source = :service` 면 `arm`(general|geometry)·`budget`(`service_budget`)이 필수이고, t0 에서 `service_proposals!` 가 후보를
만들어 동결한다(`proposals` 인자는 무시된다). 기록에 `proposal_source`(원장·제출·preflight·거절)와 `arm_views`(U1/U4/V4 또는 G4)가 붙는다.
"""
function run_episode!(; mode::Symbol, launch_env::AbstractDict, root::AbstractString, proposals::AbstractVector,
                      source::Symbol, url::AbstractString = "", capabilities = nothing, out_dir::AbstractString,
                      noise_floor::Union{Bool,Symbol} = :measure, baseline_override::Union{Nothing,Symbol} = nothing,
                      log_io::IO = stdout, campaign_dir::AbstractString = root, commit_id::AbstractString = "commit",
                      arm::AbstractString = "general", budget = nothing)
    mode in (:shadow, :enforce) || error("run_episode! needs mode shadow|enforce, got $(mode)")
    if mode === :enforce
        p = enforce_problems(capabilities)
        isempty(p) || error("[zrv] ZONE_REPAIR_VERIFICATION=enforce refused: " * join(p, "; "))
        # T9: 사람 fixture 는 모델 후보가 아니다 — 실제 enforce 에서 세계를 바꾸는 source 가 될 수 없다(시험 전용 문만 예외).
        source === :fixture && get(capabilities, "test_forced", false) !== true &&
            error("[zrv] ZONE_REPAIR_VERIFICATION=enforce refuses a fixture proposal source (ZONE_REPAIR_PROPOSALS)")
    end
    source === :service && (parse_arm(arm); budget isa AbstractDict || error("service source needs a model budget"))
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
        # T9: 서비스 source — t0 관측(일회용 observe worker) → 제안 → t0 preflight → (선택) 수정 호출 → 후보 동결.
        extra = String[]
        if source === :service
            sp = service_proposals!(; parent_dir = par.dir, root, url, arm, budget, launch_env,
                                    run_ctx = Dict{String,Any}("repair_ablation" => get(launch_env, "REPAIR_ABLATION", "none")))
            proposals = sp.proposals
            rec["proposal_source"] = sp.record
            rec["n_proposals"] = length(proposals)
            append!(extra, sp.gaps)
        end
        rec["arm_views"] = arm_views(proposals; arm = source === :service ? arm : "fixture")
        # 🔴 결정 **전**: 서비스·source·API·schema·권한 지문.
        pre = vcat(decision_gaps(proposals; source, url), extra)
        rec["decision_gaps"] = pre
        props = proposals
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
    src = proposal_source(ENV; mode)                     # T9: 둘 다/둘 다 없음/enforce+fixture/팔·예산 — 부모를 띄우기 전에 죽는다
    source, url, arm, budget = src.source, src.url, src.arm, src.budget
    proposals = source === :fixture ? load_proposals(src.fixture) : Dict{String,Any}[]
    if source === :service
        ok, line = service_gate(url)
        ok || error("[zrv] the proposal service does not serve this tree (generation gate): $(line)")
    end
    launch = launch_env_from(ENV)
    rec = run_episode!(; mode, launch_env = launch, root, proposals, source, url, capabilities = caps, out_dir = out,
                       campaign_dir = abspath(get(ENV, "ZONE_REPAIR_CAMPAIGN_DIR", root)), arm, budget)
    return something(rec["exit_code"], 1)
end

end # module RepairRuntime
