# =============================================================================
# repair_branch_worker.jl — branch worker / t0 부모의 preload (T4). 설계 §5·§6.1·§7.1.
#
#   julia +lts --project=. -L tools/monitor/repair_branch_worker.jl tools/monitor/render_demo.jl
#
# render_demo.jl 을 고치지 않는다(T3 과 같은 `-L` preload). 역할은 `ZRV_BRANCH_ROLE`:
#   parent  (`ZRV_REPLAY_MODE=capture`) — t0 에서 checkpoint(T3) + `contract.json`(원본 완료 조건·예산·pi0 값·
#           실제 원장 위치)을 쓰고 **tick 없이** `control/<n>.cmd` 를 기다린다: `verify` · `resume` · `exit`.
#           `RESPEC_HOLD`·진행 카운터를 건드리지 않는다 — 대기는 이 훅 안의 sleep 이다.
#   branch  (`ZRV_REPLAY_MODE=resume`) — `EpisodeReplay.restore_at_t0!` → 자격 증명 재세척 → (있으면)
#           `ZRV_BRANCH_ACTION` 파일의 `branch_action!(env)` 를 **새 익명 모듈**에서 실행(감사 기록) →
#           `EpisodeReplay.continue_from!`(production `continue_simulation!`, invokelatest) → `terminal.json`
#           (고정 export, schema `branch-export/1`) → exit. 어느 단계든 던지면 `error.json` + exit 3.
# 판정은 여기서 하지 않는다 — supervisor 프로세스의 `BranchRunner.validate_branch` 가 JSON 만 읽고 한다.
#
# 감사 경계(설계 §6.1 — 무엇을 보고 무엇을 못 보나):
#   관측: 액션 전후의 (a) 세계 정준 필드 digest 차이(= 순 변경), (b) CB·하니스 모듈의 메서드 표 digest(override),
#         (c) world counter(메서드 정의 발생), (d) engine 진행 카운터(RVO doStep 수·sim 래퍼 정체성·SIM_STEP·캐시
#         시계); continuation 동안 매 스텝 경계의 보호 전역 digest(T3 trace 의 `globals` 열).
#   못 봄: 액션 **도중** 바꿨다 되돌린 변경, 한 스텝 **안**의 변경, Base 등 다른 모듈에 추가한 메서드의 의미,
#         이 파일의 감사 함수 자체를 액션이 재정의하는 것(같은 프로세스). 그래서 enforce 모드는 닫혀 있다.
# =============================================================================
include(joinpath(@__DIR__, "..", "..", "src", "verification", "episode_replay.jl"))   # 훅은 ZRV_REPLAY_MODE 가 설치
include(joinpath(@__DIR__, "..", "..", "src", "verification", "branch_runner.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "verification", "task_contract.jl"))       # T5 원본 작업 계약
include(joinpath(@__DIR__, "..", "..", "src", "verification", "tool_execution.jl"))      # T6 격리 도구 집행

module RepairBranchWorker

using ConstructionBots, JSON3, SHA, Random
import ..EpisodeReplay as ER
import ..EpisodeCheckpointIO as E
import ..BranchRunner as BR
import ..TaskContract as TC
import ..ToolExecution as TX
const CB = ConstructionBots

"pi0 의 정의(설계 §7.1): 존 NOOP 레인 고정 · 존 전용 solver/사다리 차단. 분기 t0·끝에서 같아야 한다."
const PI0_ENV = ("DEMO_POLICY", "DEMO_ROUTER", "REPAIR_ABLATION")
pi0_snapshot() = merge(Dict{String,Any}(k => get(ENV, k, nothing) for k in PI0_ENV),
    Dict{String,Any}("ablation_level" => String(CB.REPAIR_ABLATION[]), "ablation_armed" => CB._ABLATION_ARMED[],
                     "respec_hold" => CB.RESPEC_HOLD[]))

_write(path, d) = open(io -> JSON3.pretty(io, JSON3.write(d)), path, "w")
_ids(env, vs) = sort!([string(CB.node_id(CB.get_node(env.sched, v))) for v in vs])
project_complete_ids(env) = sort!([string(CB.node_id(n)) for n in CB.get_nodes(env.sched)
                                   if CB.matches_template(CB.ProjectComplete, n)])
_sp(sp) = Dict("max_time_steps" => sp.max_time_steps, "max_num_iters_no_progress" => sp.max_num_iters_no_progress,
               "sim_batch_size" => sp.sim_batch_size)

# ---- 감사 --------------------------------------------------------------------------------------
"감사 대상 모듈의 함수마다 메서드(시그니처·정의 위치) digest. 액션 뒤 달라진 이름 = override 관측."
function method_digests(mods = (CB, ER, E, BR, @__MODULE__))
    out = Dict{String,String}()
    for m in mods, n in names(m; all = true)
        isdefined(m, n) || continue
        f = getfield(m, n)
        f isa Function || continue
        rows = sort!([string(me.sig, "@", me.file, ":", me.line) for me in methods(f)])
        out["$(m).$(n)"] = bytes2hex(sha256(join(rows, "\n")))[1:16]
    end
    return out
end

function engine_counters(spd)
    el = CB.rvo_global_sim_wrapper().element
    return Dict{String,Any}("sim_step" => CB.SIM_STEP[], "iter" => spd.iter,
        "rvo_wrapper" => string(objectid(el)), "rvo_doSteps" => el isa CB.RVOSimHarness ? el.n_steps : -1,
        "cache_clock" => CB._CACHE_TIMESTAMP_COUNTER[])
end

function audit_snapshot(env, spd)
    W = E.world_lines(env; modules = ER.MODULES())
    return (fields = E.field_digests(W.lines, W.fields), methods = method_digests(),
            world = Base.get_world_counter(), engine = engine_counters(spd))
end

_changed(a::AbstractDict, b::AbstractDict) =
    sort!([String(k) for k in union(keys(a), keys(b)) if get(a, k, nothing) != get(b, k, nothing)])

"engine 진행이 액션 안에서 일어났나. 일어났으면 배치 위치가 어긋나므로 continuation 을 잇지 않는다(T6 adapter 몫)."
engine_advanced(a0, a1) = [k for k in ("sim_step", "iter", "rvo_wrapper", "rvo_doSteps") if a0.engine[k] != a1.engine[k]]

# ---- 자격 증명 재세척 -----------------------------------------------------------------------------
"import 가 checkpoint 의 ENV 를 되살린 뒤 한 번 더 지운다. 지운 이름만 돌려준다(값은 절대 안 싣는다)."
function scrub_env!()
    ks = sort!([k for k in keys(ENV) if BR.denied_env(k)])
    foreach(k -> delete!(ENV, k), ks)
    return ks
end

# ---- 분기 동작 ---------------------------------------------------------------------------------
"`file` 을 **새 익명 모듈**에 include 하고 `branch_action!(env)` 를 부른다(invokelatest — 방금 정의된 메서드)."
function run_action!(env, file::AbstractString)
    isempty(file) && return Dict{String,Any}("kind" => "noop")
    m = Module(:BranchAction)
    Base.include(m, file)
    r = Base.invokelatest(getfield(m, :branch_action!), env)
    return Dict{String,Any}("kind" => "file", "file" => file, "file_sha256" => bytes2hex(sha256(read(file))),
                            "returned" => r === nothing ? nothing : sprint(show, r)[1:min(end, 500)])
end

function _error_kind(e, bt)
    s = sprint(showerror, e)
    e isa OutOfMemoryError && return "resource_limit"
    occursin("identity mismatch", s) && return "identity_mismatch"
    frames = string.(stacktrace(bt))
    any(f -> occursin(r"JuMP|MathOptInterface|HiGHS", f), frames) && return "solver_error"
    return "exception"
end

function _fail(dir, stage, e, bt)
    _write(joinpath(dir, "error.json"), Dict("schema" => BR.EXPORT_SCHEMA, "stage" => stage,
        "kind" => _error_kind(e, bt), "exception_type" => string(typeof(e)),
        "message" => first(sprint(showerror, e), 2000),
        "frames" => [string(f)[1:min(end, 300)] for f in first(stacktrace(bt), 60)]))
    println("[zrv-branch] FAILED at $(stage): ", first(sprint(showerror, e), 300))
    flush(stdout); flush(stderr)
    exit(3)
end

function branch!(h, env0, ctx)
    dir, bid = h.dir, ENV["ZRV_BRANCH_ID"]
    stage = "restore"
    try
        st = ER.restore_at_t0!(h, ctx)
        (isempty(st.r.mismatched_blocks) && isempty(st.dup)) ||
            error("identity mismatch after import: blocks=$(st.r.mismatched_blocks) guard=$(st.dup)")
        scrubbed = scrub_env!()
        pi0_t0 = pi0_snapshot()
        stage = "action"
        prop = get(ENV, "ZRV_BRANCH_PROPOSAL", "")
        batch_pos, up_steps = st.ls.batch_pos, Any[]
        if isempty(prop)
            a0 = audit_snapshot(st.r.env, st.spd)
            act = run_action!(st.r.env, get(ENV, "ZRV_BRANCH_ACTION", ""))
            a1 = audit_snapshot(st.r.env, st.spd)
            adv = engine_advanced(a0, a1)
            isempty(adv) || error("engine advanced inside the branch action without the trusted adapter " *
                                  "($(adv)) — continuation batch alignment would be wrong; unsupported in T4")
            audit = Dict{String,Any}("fields_changed_by_action" => _changed(a0.fields, a1.fields),
                "methods_changed_by_action" => _changed(a0.methods, a1.methods),
                "world_counter_delta" => Int(a1.world - a0.world),
                "engine_before" => a0.engine, "engine_after" => a1.engine)
        else
            # T6: 생성 도구 — 등록 → body(trusted adapter) → 효과별 후처리. 폐기면 여기서 끝난다(exit).
            en = run_proposal!(st, ctx, dir, prop)
            act = Dict{String,Any}("kind" => "proposal", "file" => prop, "file_sha256" => bytes2hex(sha256(read(prop))),
                                   "proposal_id" => en.record["proposal_id"], "enactment_status" => en.record["status"],
                                   "engine_steps" => en.record["engine_steps"], "returned" => nothing)
            audit = Dict{String,Any}(en.record["audit"])
            batch_pos, up_steps = en.adapter.batch_pos, en.adapter.up_steps
        end
        audit["unobservable"] = ["mutations reverted before the action returned",
                                 "intra-step changes (only step boundaries are traced)",
                                 "methods added to modules outside the audited set",
                                 "redefinition of this audit code by the action (same process)"]
        stage = "continuation"
        # extra 는 **함수** — closed id·pi0_end·ablation 수는 continuation 이 끝난 세계에서 읽어야 한다.
        ER.continue_from!(h, st, ctx; batch_pos, up_steps, extra = () -> Dict{String,Any}("branch" => Dict{String,Any}(
            "schema" => BR.EXPORT_SCHEMA, "id" => bid, "checkpoint_id" => st.cp.checkpoint_id,
            "action" => act, "audit" => audit, "env_scrubbed_after_import" => scrubbed,
            "pi0_t0" => pi0_t0, "pi0_end" => pi0_snapshot(), "ablation_counts" => CB.ablation_counts(),
            "sim_params" => _sp(st.sp), "closed_node_ids" => _ids(st.r.env, st.r.env.cache.closed_set),
            "task_state" => TC.task_state(st.r.env, CB),      # T5: 신뢰 쪽이 원본 계약으로 terminal 을 재판정할 입력
            "project_complete_ids" => project_complete_ids(st.r.env), "pid" => getpid())))
    catch e
        _fail(dir, stage, e, catch_backtrace())
    end
    flush(stdout); flush(stderr)
    exit(0)
end

# ---- T6: 생성 도구 집행 ---------------------------------------------------------------------------
"""
제안 파일(`ZRV_BRANCH_PROPOSAL`)을 `ToolExecution.enact_proposal!` 로 집행하고 `enactment.json`·`effect_trace.json`
을 쓴다. `:enacted` 가 아니면 **worker 를 버린다**: preflight(`requires_runtime`·t0 끝)는 exit 0, 폐기(throw·partial·
후처리 실패·등록 부작용·미관측)는 `error.json`(stage=action) + exit 3 — continuation 없음, 되돌리기 없음.
preflight 는 `:enacted` 여도 continuation 을 하지 않는다(t0 에서 첫 engine 진행 직전까지가 전부다).
"""
function run_proposal!(st, ctx, dir, prop)
    mode = Symbol(get(ENV, "ZRV_BRANCH_MODE", "full"))
    proposal = JSON3.read(read(prop, String), Dict{String,Any})
    tcp = get(ENV, "ZRV_TASK_CONTRACT", "")
    C = isfile(tcp) ? JSON3.read(read(tcp, String), Dict{String,Any}) : nothing
    en = TX.enact_proposal!(st.r.env, ctx.factory_vis, ctx.anim, st.sp, st.spd; proposal, mode, CB, contract = C,
                            audit = audit_snapshot, engine = engine_counters, batch_pos = st.ls.batch_pos,
                            fail_probe = get(ENV, "ZRV_PROBE_POSTPROCESS_FAIL", "0") == "1")
    TX.write_enactment(dir, en)
    status = en.record["status"]
    println("[zrv-branch] enactment status=$(status) mode=$(mode) engine_steps=$(en.record["engine_steps"]) " *
            "classes=$(get(en.record, "effect_classes", String[])) exception=$(en.record["exception"])")
    flush(stdout); flush(stderr)
    if status != "enacted"
        status == "requires_runtime" && exit(0)
        _write(joinpath(dir, "error.json"), Dict("schema" => BR.EXPORT_SCHEMA, "stage" => "action", "kind" => "exception",
            "exception_type" => "ToolExecution.discarded", "message" => "discarded ($(status)): $(en.record["exception"])",
            "frames" => String[]))
        flush(stdout); flush(stderr)
        exit(3)
    end
    mode === :preflight && exit(0)
    return en
end

# ---- 부모: t0 에서 대기 ------------------------------------------------------------------------
"tick 여부를 보는 카운터 — 대기 동안 하나도 바뀌면 안 된다."
hold_counters(spd) = merge(engine_counters(spd), Dict{String,Any}("respec_hold" => CB.RESPEC_HOLD[],
    "no_progress" => spd.num_iters_no_progress, "stop" => spd.stop_simulating))

function hold!(h, env, ctx)
    get(ENV, "ZRV_BRANCH_ROLE", "") == "parent" || return nothing
    spd, sp = ctx.sim_process_data, ctx.sim_params
    cp, ls = h.t0.cp, h.t0.loop_state
    stream = CB.MONITOR_IO[] === nothing ? "" : (try CB.MONITOR_IO[].name catch; "" end)
    stream = replace(stream, r"^<file (.*)>$" => s"\1")
    contract = Dict{String,Any}("schema" => BR.CONTRACT_SCHEMA, "checkpoint_id" => cp.checkpoint_id,
        "envelope" => joinpath(h.dir, "t0.envelope.json"), "t0_iter" => spd.iter, "batch_pos" => ctx.batch_pos,
        "sim_params" => _sp(sp), "required_ids" => project_complete_ids(env),
        "node_ids" => _ids(env, CB.Graphs.vertices(env.sched)), "zone_keys" => ls.dispatch.zone_keys,
        "pi0" => Dict{String,Any}(k => v for (k, v) in pi0_snapshot() if k != "respec_hold"),
        "real_ledger" => stream, "parent_pid" => getpid(), "gaps" => cp.uncertifiable)
    # T5: 원본 작업 계약 — 생성 코드가 한 번도 돌지 않은 이 부모 프로세스가 t0 세계에서 유도해 **파일로** 둔다(신뢰 사본).
    #     유도가 실패해도 부모를 죽이지 않는다 — 계약 없음은 인증 불가 사유로 남는다.
    tcp = joinpath(h.dir, "task_contract.json")
    contract["task_contract"] = try
        _write(tcp, TC.derive_task_contract(env, CB; checkpoint_id = cp.checkpoint_id))
        Dict{String,Any}("path" => tcp, "sha256" => bytes2hex(sha256(read(tcp))),
                         "validator_version" => TC.TASK_CONTRACT_VALIDATOR_VERSION)
    catch e
        Dict{String,Any}("error" => first(sprint(showerror, e), 300))
    end
    _write(joinpath(h.dir, "contract.json"), contract)
    c0 = hold_counters(spd)
    _write(joinpath(h.dir, "held.json"), Dict("counters" => c0, "pid" => getpid(), "t0_iter" => spd.iter))
    println("[zrv-parent] holding at t0 iter=$(spd.iter) (no ticks) — waiting for control/<n>.cmd")
    flush(stdout)
    ctl = joinpath(h.dir, "control"); mkpath(ctl)
    deadline = time() + parse(Float64, get(ENV, "ZRV_HOLD_MAX_S", "21600"))
    n = 0
    while true
        f = joinpath(ctl, "$(n + 1).cmd")
        if isfile(f)
            n += 1
            cmd = strip(read(f, String))
            out = joinpath(ctl, "$(n).out.json")
            if cmd == "verify"
                mb = E.verify_world(cp, (; env, loop_state = ls, task_contract = nothing,
                                          fingerprints = cp.fingerprints); modules = ER.MODULES())
                c = hold_counters(spd)
                _write(out, Dict("cmd" => "verify", "mismatched_blocks" => String.(mb), "counters" => c,
                                 "counters_equal" => c == c0, "rng_equal" => copy(Random.default_rng()) == h.rng_at_t0))
            elseif cmd == "resume"
                _write(out, Dict("cmd" => "resume", "counters_equal" => hold_counters(spd) == c0))
                println("[zrv-parent] resume: continuing the original world under pi0"); flush(stdout)
                return nothing
            elseif cmd == "exit"
                _write(out, Dict("cmd" => "exit")); flush(stdout); exit(0)
            else
                _write(out, Dict("cmd" => cmd, "error" => "unknown command"))
            end
        end
        time() > deadline && (println("[zrv-parent] hold deadline passed — exiting"); flush(stdout); exit(3))
        sleep(0.2)
    end
end

function install!()
    role = get(ENV, "ZRV_BRANCH_ROLE", "")
    role == "parent" && (get(ENV, "ZRV_REPLAY_MODE", "") == "capture" || error("parent role needs ZRV_REPLAY_MODE=capture"))
    role == "branch" && (get(ENV, "ZRV_REPLAY_MODE", "") == "resume" || error("branch role needs ZRV_REPLAY_MODE=resume"))
    role == "parent" && (ER.T0_HANDLER[] = hold!)
    role == "branch" && (ER.RESUME_HANDLER[] = branch!)
    role in ("parent", "branch") && println("[zrv-worker] role=$(role) pid=$(getpid())")
    return nothing
end

end # module RepairBranchWorker

RepairBranchWorker.install!()
