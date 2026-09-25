# =============================================================================
# episode_replay.jl — t0 hook · 궤적 trace · export→(새 프로세스)import→NOOP 재개 (T3). 설계 §3.1·§3.3·§5.
#
# 로드: **실제 캠페인 런타임(`tools/monitor/render_demo.jl`)에 `-L` 로 먼저 싣는다** — render_demo.jl 을
#   고치지 않는다(production 배선은 T8). 모드는 환경변수 하나다:
#
#     ZRV_REPLAY_MODE=trace|capture|resume  ZRV_REPLAY_DIR=<출력>  [ZRV_CHECKPOINT=<t0 envelope json>]
#     julia +lts --project=. -L src/verification/episode_replay.jl tools/monitor/render_demo.jl
#
#   `ZRV_REPLAY_MODE` 가 없으면 이 파일은 모듈만 정의하고 **아무 훅도 설치하지 않는다**(시험·T4 용).
#
# 경계(설계 §3.1 — 코드 순서로 확인, 이름으로 적는다):
#   pre_injection  = `run_lego_demo` 가 `pre_sim_hook(env)`(= render_demo 의 `pre`)를 부르기 **직전**
#                    (`HARNESS_HOOK(:pre_sim_begin)`). 존·fault/battery 무장·배터리 전부 `pre` 안에서 일어난다.
#   post_injection = `pre` 직후(`:pre_sim_end`). presim 존은 여기서 `RESTRICTION_ZONES` 에 있고, 그 NL 이
#                    `RESPEC_QUEUE.pending` 에 있다(`inject_blocking_zone!` → `CB.push_ood!`).
#   t0             = `simulate!` 의 스텝 경계(`:step`, `iter += 1` 앞) 중 **존 사건이 대기열에 있는 첫 경계**.
#                    그 전에 `run_simulation!` 의 첫 `step_environment!` 가 이미 `enforce_restriction_
#                    zone_clearance!`(주입 후 물리 enforcement)를 돌았다. 다음 스텝의 `respec_step!` →
#                    `maybe_respecify!` → `poll_ood!` → producer(`policy_producer` → `decide_all`)가 그
#                    사건의 첫 결정이다 — t0 은 그 **앞**이다(poll 도 안 됐다: `dispatch.polled = false`).
# 재개(resume): 새 프로세스가 render_demo.jl 을 처음부터 돌리고(같은 코드·같은 로드 순서), 첫 `:step` 경계에서
#   checkpoint 를 import 한 뒤 **production `CB.continue_simulation!`** 으로 그 세계를 끝까지 굴리고 종료한다.
#   그 프로세스가 스스로 만든 세계(자기 `pre` 가 주입한 존 포함)는 import 가 통째로 덮는다 — 중복 주입/
#   중복 dispatch 여부는 import 직후 `dispatch` 대조와 블록 digest 가 판정한다.
# 외생 난수(§3.3): 이 런타임의 외생 추첨은 전부 t0 **이전**에 끝난다(`pre` 의 `MersenneTwister(DEMO_SEED)`
#   → 사건 종류·스텝·soc_drop, `MersenneTwister(DEMO_ZONE_SEED)` → 존 배치). 추첨 결과는 `OOD_SCHEDULE`
#   closure 의 포획 값으로 checkpoint 에 실린다 — 분기의 호출 횟수와 무관하게 (episode, kind, occurrence)
#   가 고정된다. 대상(robot)·발화 가능 여부는 발화 순간 **그 분기의 상태**로 계산된다(`retrying_action`).
#   t0 이후 전역 RNG 소비가 있으면 그것은 키 없는 결합이다 → trace 의 `rng` 열로 감시하고
#   `rng_advanced_after_t0` 로 보고한다(있으면 인증 불가).
# =============================================================================
isdefined(Main, :EpisodeCheckpointIO) || include(joinpath(@__DIR__, "episode_checkpoint.jl"))
isdefined(Main, :ReplayCompare) || include(joinpath(@__DIR__, "replay_compare.jl"))

module EpisodeReplay

using ConstructionBots, SHA, JSON3, Random, Serialization
import ..EpisodeCheckpointIO as E
import ..RepairTypes as R
import ..ReplayCompare
const CB = ConstructionBots

"재생 세계 버전. 외생 난수 adapter 를 바꾸지 않았으므로(추첨이 전부 t0 이전) 역사적 주입 동작과 같다."
const REPLAY_VERSION = "zrv-replay/1 (exogenous draws pre-t0, historical-compatible)"
const T0_HOOK = "ConstructionBots.simulate!:step-boundary(before iter+=1, before monitor_control_step!/" *
                "ood_inject_step!/respec_step!) — first boundary with a ZoneTruth event pending in RESPEC_QUEUE"

"trace 의 `globals` 열이 매 스텝 읽는 전역(있는 것만). 읽기만 한다."
const TRACE_GLOBALS_CB = (:RESTRICTION_ZONES, :RESPEC_QUEUE, :RESPEC_HOLD, :BATTERY_FLEET,
    :BATTERY_DELIVERIES, :FAULTED_ROBOTS, :SPARE_POOLS, :STALLED_ROBOTS, :WEDGE_EDGES,
    :CARRIER_LAST_D, :SNAP_COUNT, :_CACHE_TIMESTAMP_COUNTER, :VALID_ID_COUNTERS, :OOD_TRUTH_LOG,
    :_ABLATION_COUNTS, :DECOMMISSIONED_BODIES, :CHECKED_OUT_SPARES)
const TRACE_GLOBALS_MAIN = (:_REFORM_CT, :_REFORM_LAST_CLOSED, :_ZONE_CT, :_DECISION_N)

# ---- 한 스텝 경계의 가벼운 digest(읽기 전용) --------------------------------------------------
function _lines(pairs)
    w = E._Walk(String[], IdDict{Any,String}(), String[])
    for (p, x) in pairs; E._walk!(w, p, x); end
    return w.lines
end
_h(lines) = bytes2hex(sha256(join(lines, "\n")))[1:16]

"씬 트리: 노드마다 (id, 상대 변환, 부모 변환노드 id). 전역 변환 캐시는 **읽지 않는다**(`global_transform` 은 캐시를 갱신한다)."
_scene_pairs(env) = [("scene[$(i)]", (id = CB.node_id(n), lt = n.geom.parent.local_transform,
                                      parent = n.geom.parent.parent.id))
                     for (i, n) in enumerate(CB.get_nodes(env.scene_tree))]

function step_columns(env, loop)
    g = [("CB.$(n)", getfield(CB, n)) for n in TRACE_GLOBALS_CB if isdefined(CB, n)]
    append!(g, [("Main.$(n)", getfield(Main, n)) for n in TRACE_GLOBALS_MAIN if isdefined(Main, n)])
    sched = (nv = CB.Graphs.nv(env.sched),
             edges = [(e.src, e.dst) for e in CB.Graphs.edges(env.sched)],
             ids = [string(CB.node_id(n)) for n in CB.get_nodes(env.sched)])
    return (loop = _lines([("loop", loop)]),
            cache = _lines([("cache", env.cache)]),
            sched = _lines([("sched", sched)]),
            scene = _lines(_scene_pairs(env)),
            rvo = _lines([("rvo", CB.rvo_export_state(; residual = false).state), ("idmap", CB.RVO_ID_GLOBAL_MAP)]),
            globals = _lines(g),
            rng = _lines([("rng", copy(Random.default_rng()))]))
end

_loop(spd, b) = (iter = spd.iter, batch_pos = b, stop = spd.stop_simulating,
                 no_progress = spd.num_iters_no_progress, last_closed = spd.last_iter_num_closed,
                 closed_step_1 = spd.num_closed_step_1)

# ---- 상태 ------------------------------------------------------------------------------------
mutable struct Harness
    mode::Symbol                 # :trace | :capture | :resume
    dir::String
    trace_io::Union{Nothing,IO}
    detail::Union{Nothing,UnitRange{Int}}
    last_env::Any
    last_spd::Any
    last_sim_params::Any
    captured::Bool
    resumed::Bool
    pre::Any                     # (sha, path) at :pre_sim_begin
    post::Any
    rng_at_t0::Any
    t0_iter::Int
    terminal_written::Bool
end
const H = Ref{Union{Nothing,Harness}}(nothing)

function _trace!(h::Harness, env, spd, b)
    h.trace_io === nothing && return
    cols = step_columns(env, _loop(spd, b))
    println(h.trace_io, spd.iter, '\t',
            join((_h(getfield(cols, Symbol(c))) for c in ReplayCompare.TRACE_COLUMNS), '\t'))
    spd.iter % 50 == 0 && flush(h.trace_io)
    if h.detail !== nothing && spd.iter in h.detail
        d = joinpath(h.dir, "detail"); mkpath(d)
        open(joinpath(d, "$(spd.iter).txt"), "w") do io
            for c in ReplayCompare.TRACE_COLUMNS, l in getfield(cols, Symbol(c))
                println(io, c, '\t', l)
            end
        end
    end
end

# ---- 사건 경계 --------------------------------------------------------------------------------
"대기열의 사건 중 존 사건(주입기가 `ZoneTruth` 로 기록한 NL)의 위치. 없으면 nothing."
function zone_event_index()
    log = CB.ood_truth_log()
    for (i, ev) in enumerate(CB.RESPEC_QUEUE.pending)
        j = findlast(e -> String(e.nl) == ev, log)
        j !== nothing && log[j].truth isa CB.ZoneTruth && return i
    end
    return nothing
end

"dispatch cursor: 대기열 전체·존 사건 위치·존 키. import 직후 이것과 대조해 중복 주입/dispatch 를 막는다."
dispatch_cursor() = (pending = copy(CB.RESPEC_QUEUE.pending), zone_event_index = zone_event_index(),
                     polled = false, zone_keys = sort!([string(k) for k in keys(CB.RESTRICTION_ZONES[])]),
                     n_ood_truth = length(CB.ood_truth_log()))

# ---- 지문 --------------------------------------------------------------------------------------
_sha_file(p) = isfile(p) ? bytes2hex(sha256(read(p)))[1:16] : "missing"
function _loaded(name)
    for m in Base.loaded_modules_array()
        String(nameof(m)) == name && return m
    end
    return nothing
end
function fingerprints()
    rf = isdefined(Main, :run_fingerprint) ? Base.invokelatest(getfield(Main, :run_fingerprint)) :
         (code_rev = "unknown", code_dirty_digest = "unknown", config_digest = "unknown")
    root = pkgdir(CB)
    cbid = Base.PkgId(CB)
    cache = haskey(Base.pkgorigins, cbid) ? string(Base.pkgorigins[cbid].cachepath) : "none"
    image = unsafe_string(Base.JLOptions().image_file)
    highs = _loaded("HiGHS")
    R.Fingerprints(code_rev = rf.code_rev, code_dirty_digest = rf.code_dirty_digest,
        dirty_snapshot_digest = "none: working tree (code_dirty_digest)", config_digest = rf.config_digest,
        julia_version = string(VERSION), manifest_digest = _sha_file(joinpath(root, "Manifest.toml")),
        build_id = bytes2hex(sha256(image * "|" * cache * "|" * root))[1:16],
        julia_threads = Threads.nthreads(), solver_name = "HiGHS",
        solver_version = highs === nothing ? "not loaded" : string(pkgversion(highs)),
        solver_seed = 0, solver_threads = 0,       # HiGHS 기본값(random_seed=0, threads=기본) — CB 가 안 건드린다
        model = "none: pi0 (no model call)", service_code_fingerprint = "none: no service",
        prompt_digest = "none", schema_digest = "none", validator_version = "none",
        scorer_version = "none", capability_contract_version = R.DEFAULT_CAPABILITY_CONTRACT.version)
end

const MODULES = () -> [CB, Main]

# ---- 봉투(EpisodeCheckpoint) 저장/읽기 ---------------------------------------------------------
function save_envelope(path, cp::R.EpisodeCheckpoint, extra::Dict)
    d = Dict{String,Any}(String(f) => getfield(cp, f) for f in fieldnames(R.EpisodeCheckpoint))
    d["fingerprints"] = Dict(String(f) => getfield(cp.fingerprints, f) for f in fieldnames(R.Fingerprints))
    d["block_sha256"] = Dict(String(k) => v for (k, v) in cp.block_sha256)
    merge!(d, extra)
    open(io -> JSON3.pretty(io, JSON3.write(d)), path, "w")
end
function load_envelope(path)
    d = JSON3.read(read(path, String))
    fp = R.Fingerprints(; (Symbol(k) => (v isa AbstractString ? String(v) : v) for (k, v) in d.fingerprints)...)
    cp = R.EpisodeCheckpoint(String(d.checkpoint_id), String(d.t0_hook), d.zone_dispatch_in_progress, fp,
        String(d.artifact_path), String(d.artifact_sha256),
        Dict(Symbol(k) => String(v) for (k, v) in d.block_sha256),
        String(d.pre_injection_sha256), String(d.post_injection_sha256), String.(d.uncertifiable))
    return cp, d
end

# ---- 종료 기록 ---------------------------------------------------------------------------------
function terminal_record(env, spd, sim_params)
    complete = CB.project_complete(env)
    reason = complete ? "project_complete" :
             spd.num_iters_no_progress >= sim_params.max_num_iters_no_progress ? "no_progress_limit" :
             spd.iter >= sim_params.max_time_steps ? "max_sim_steps" : "none"
    zb = try CB.zone_blockage(env; check_paths = false) catch; nothing end
    cols = step_columns(env, _loop(spd, 0))
    return Dict{String,Any}("complete" => complete, "terminal_reason" => reason,
        "closed" => length(env.cache.closed_set), "total" => CB.Graphs.nv(env.sched),
        "iter" => spd.iter, "no_progress" => spd.num_iters_no_progress,
        "n_zones" => length(CB.RESTRICTION_ZONES[]),
        "n_blocked" => zb === nothing ? nothing : zb.n_blocked,
        "project_blocked" => zb === nothing ? nothing : zb.project_blocked,
        "ablation" => (try CB.ablation_summary_line() catch; nothing end),
        "final_digest" => Dict(String(c) => _h(getfield(cols, c)) for c in keys(cols)))
end

"필드별 정준 행 중 작은 것(≤ `cap` 행)을 파일로 남긴다 — digest 가 갈린 필드의 **줄 단위** 원인을 보려고."
function dump_small_fields(path, lines, fields; cap = 20_000)
    open(path, "w") do io
        for (_, f, s0, e0) in E._spans(lines, fields)
            e0 - s0 + 1 <= cap || continue
            for i in s0:e0; println(io, lines[i]); end
        end
    end
end

function _write_json(path, d)
    open(io -> JSON3.pretty(io, JSON3.write(d)), path, "w")
end

function _write_terminal!(h::Harness, env, spd, sim_params; extra = Dict{String,Any}())
    h.trace_io === nothing || flush(h.trace_io)
    get(ENV, "ZRV_DIAG_INVENTORY", "0") == "1" && inventory_sizes(env)
    t = terminal_record(env, spd, sim_params)
    if h.rng_at_t0 !== nothing
        t["rng_advanced_after_t0"] = copy(Random.default_rng()) != h.rng_at_t0
    end
    # 종료 시점 전체 세계 정준 digest(필드별) — 원본/재개 비교용. 원장 경계·Main 출력 경로는 설계상 다르다.
    W = E.world_lines(env; modules = MODULES())
    t["world_field_sha256"] = E.field_digests(W.lines, W.fields)
    dump_small_fields(joinpath(h.dir, "terminal_small_fields.tsv"), W.lines, W.fields)
    merge!(t, extra)
    _write_json(joinpath(h.dir, "terminal.json"), t)
    h.trace_io === nothing || flush(h.trace_io)
    println("[zrv] terminal complete=$(t["complete"]) reason=$(t["terminal_reason"]) closed=$(t["closed"]) iter=$(t["iter"])")
    return t
end

# ---- capture ----------------------------------------------------------------------------------
"""
checkpoint 한 장. 🔴 기본 RNG 를 앞뒤로 저장/복원한다 — 지문 계산(git 서브프로세스 등)이 전역 RNG 를
전진시켰다(T3 첫 행렬: capture 런의 `rng` 열만 원본과 달랐다). export 는 세계를 바꾸면 안 된다.
"""
function _export(h::Harness, id, env; loop_state = nothing, pre = "", post = "", hook = id, zdip = false)
    saved = copy(Random.default_rng())
    fp = fingerprints()
    copy!(Random.default_rng(), saved)
    cp, c = E.export_checkpoint(joinpath(h.dir, "ckpt"), id, env; modules = MODULES(), t0_hook = hook,
        zone_dispatch_in_progress = zdip, fingerprints = fp, loop_state,
        pre_injection_sha256 = pre, post_injection_sha256 = post)
    dump_small_fields(joinpath(h.dir, "ckpt", id * ".small_fields.tsv"), c.lines, c.fields)
    copy(Random.default_rng()) == saved || (copy!(Random.default_rng(), saved);
        println("[zrv] WARNING: export advanced the default RNG — restored"))
    return cp, c, E._sha(c.lines)
end

function _capture_t0!(h::Harness, env, ctx)
    spd, sp = ctx.sim_process_data, ctx.sim_params
    disp = dispatch_cursor()
    loop_state = (iter = spd.iter, batch_pos = ctx.batch_pos, stop_simulating = spd.stop_simulating,
        starting_frame = spd.starting_frame, num_closed_step_1 = spd.num_closed_step_1,
        last_iter_num_closed = spd.last_iter_num_closed, num_iters_no_progress = spd.num_iters_no_progress,
        num_iters_since_anim_save = spd.num_iters_since_anim_save, n_update_steps = length(ctx.update_steps),
        sim_params = Tuple(getfield(sp, i) for i in 1:fieldcount(typeof(sp))), dispatch = disp)
    t0 = time()
    cp, c, _ = _export(h, "t0", env; loop_state, pre = h.pre[1], post = h.post[1], hook = T0_HOOK, zdip = true)
    t = time() - t0
    save_envelope(joinpath(h.dir, "t0.envelope.json"), cp,
        Dict{String,Any}("replay_version" => REPLAY_VERSION, "dispatch" => disp,
                         "loop_state" => Dict(String(k) => (k === :dispatch || k === :sim_params ? string(v) : v)
                                              for (k, v) in pairs(loop_state)),
                         "gaps" => c.gaps, "native_residual" => E.residual_summary(c.native_residual),
                         "pre_injection_path" => h.pre[2], "post_injection_path" => h.post[2],
                         "capture_seconds" => t))
    h.rng_at_t0 = copy(Random.default_rng())
    h.t0_iter = spd.iter
    println("[zrv] t0 captured iter=$(spd.iter) batch_pos=$(ctx.batch_pos) zone_event_index=$(disp.zone_event_index) " *
            "pending=$(length(disp.pending)) gaps=$(length(c.gaps)) ($(round(t; digits = 1)) s)")
    foreach(g -> println("[zrv]   gap: ", g), c.gaps)
end

# ---- resume -----------------------------------------------------------------------------------
function _resume!(h::Harness, env0, ctx)
    cp, env_d = load_envelope(ENV["ZRV_CHECKPOINT"])
    mine = fingerprints()
    mm = R.fingerprint_mismatches(cp.fingerprints, mine)
    isempty(mm) || error("[zrv] identity mismatch — refusing to resume: $(mm)")
    t = @elapsed r = E.import_checkpoint(cp; modules = MODULES())
    ls = r.loop_state
    # 블록 digest 가 갈리면 **필드 이름**까지 내린다(capture 의 fields.json 과 대조) + 작은 필드 줄 덤프.
    W = E.world_lines(r.env; modules = MODULES(), loop_state = r.loop_state, task_contract = r.task_contract,
                      fingerprints = r.fingerprints)
    want = JSON3.read(read(replace(cp.artifact_path, r"\.jls$" => ".fields.json"), String)).field_sha256
    got = E.field_digests(W.lines, W.fields)
    field_mismatch = sort!([String(k) for k in union(String.(keys(want)), keys(got))
                            if get(want, Symbol(k), nothing) != get(got, String(k), nothing)])
    dump_small_fields(joinpath(h.dir, "t0_after_import.small_fields.tsv"), W.lines, W.fields)
    # 🔴 중복 주입/중복 dispatch 가드: 이 프로세스의 `pre` 도 존을 주입했고 사건을 넣었다. import 가 그것을
    #    통째로 덮었어야 한다 — 대기열·존 키·truth 로그 길이가 capture 때와 **정확히** 같아야 한다.
    now = dispatch_cursor()
    dup = String[]
    now.pending == ls.dispatch.pending || push!(dup, "RESPEC_QUEUE.pending differs: $(now.pending) vs $(ls.dispatch.pending)")
    now.zone_keys == ls.dispatch.zone_keys || push!(dup, "zone keys differ: $(now.zone_keys) vs $(ls.dispatch.zone_keys)")
    now.n_ood_truth == ls.dispatch.n_ood_truth || push!(dup, "ood truth log length differs")
    sp = ctx.sim_params
    Tuple(getfield(sp, i) for i in 1:fieldcount(typeof(sp))) == ls.sim_params ||
        push!(dup, "sim_params differ from capture")
    ls.n_update_steps == 0 || push!(dup, "capture had $(ls.n_update_steps) pending animation update steps (not carried)")
    shadow = E.attach_shadow_sinks!(r, h.dir; modules = MODULES())   # 원본과 같은 관측 호출(원장은 분기 파일)
    spd0 = ctx.sim_process_data
    spd = CB.SimProcessingData(ls.stop_simulating, ls.iter, ls.starting_frame, spd0.prog,
        ls.num_closed_step_1, ls.last_iter_num_closed, ls.num_iters_no_progress,
        ls.num_iters_since_anim_save, spd0.progress_update_fcn)
    println("[zrv] resumed from t0 iter=$(ls.iter) batch_pos=$(ls.batch_pos) import=$(round(t; digits = 1)) s " *
            "mismatched_blocks=$(r.mismatched_blocks) rehashed=$(r.n_dicts_rehashed) guard=$(isempty(dup) ? "ok" : dup)")
    h.resumed = true
    h.rng_at_t0 = copy(Random.default_rng())
    h.t0_iter = ls.iter
    h.last_env = r.env; h.last_spd = spd; h.last_sim_params = sp
    # 🔴 `invokelatest` 필수: import 가 역직렬화한 closure(예: `retrying_action` 의 `act`)는 **지금** 새 타입·
    #    메서드로 정의된다. 이 훅은 `run_lego_demo` 가 시작될 때 고정된 world age 안에서 돌므로 그대로
    #    부르면 그 메서드가 안 보인다 — T3 행렬 첫 all3 판이 218 스텝에서 `MethodError(::var"#act#59")` 로
    #    죽었다(fault 재시도 사건이 처음 발화한 스텝). T4 worker 도 같은 규칙을 따라야 한다.
    status = Base.invokelatest(CB.continue_simulation!, r.env, ctx.factory_vis, ctx.anim, sp, spd;
                               first_batch = sp.sim_batch_size - ls.batch_pos + 1)
    watches = [(k, v) for (k, v) in r.native_handles if v !== nothing]
    res_native = JSON3.read(read(replace(cp.artifact_path, r"\.jls$" => ".fields.json"), String)).native_residual
    _write_terminal!(h, r.env, spd, sp; extra = Dict{String,Any}(
        "resume" => Dict("import_seconds" => t, "mismatched_blocks" => String.(r.mismatched_blocks),
                         "mismatched_fields" => field_mismatch, "shadow_sinks" => shadow,
                         "n_dicts_rehashed" => r.n_dicts_rehashed, "dispatch_guard" => dup,
                         "fingerprint_mismatches" => String.(mm), "gaps" => cp.uncertifiable,
                         "rvo_tie_watch" => [Dict("global" => k, "doSteps_watched" => v.n_steps,
                                                  "ties" => v.ties, "resolved" => v.resolved,
                                                  "kd_restored" => v.kd_restored, "watch_mode" => v.watch,
                                                  "still_active" => CB.rvo_global_sim_wrapper().element === v)
                                             for (k, v) in watches]),
        "continue_simulation_status" => string(status),
        "rvo_residual_at_t0" => Dict(String(k) => Dict("global_time" => v.global_time, "n_builds" => v.n_builds,
                                                       "kd_known" => v.kd_known) for (k, v) in pairs(res_native))))
    flush(stdout); flush(stderr)
    exit(0)
end

"진단: 전역·env 필드마다 정준 행 수(상한 1e6 에서 끊는다). 폭주하는 필드를 찾는 데 쓴다."
function inventory_sizes(env; cap = 1_000_000)
    old = E.MAX_WORLD_LINES[]; E.MAX_WORLD_LINES[] = cap
    items = Any[("env.$(f)", getfield(env, f)) for f in fieldnames(typeof(env))]
    for e in E.global_inventory(MODULES())
        e.handling === :graph && push!(items, (E._gkey(e), getfield(e.mod, e.name)))
    end
    try
        for (k, x) in items
            w = E._Walk(String[], IdDict{Any,String}(), String[])
            err = ""
            t = @elapsed n = try E._walk!(w, k, x); length(w.lines) catch e; err = first(sprint(showerror, e), 900); -1 end
            (n < 0 || n > 20_000 || t > 1) && println("[zrv-diag] ", k, " lines=", n, " t=", round(t; digits = 2), " ", err)
            flush(stdout)
        end
    finally
        E.MAX_WORLD_LINES[] = old
    end
end

# ---- 훅 ---------------------------------------------------------------------------------------
function hook(phase::Symbol, env, ctx)
    h = H[]
    h === nothing && return nothing
    if phase === :pre_sim_begin && get(ENV, "ZRV_DIAG_INVENTORY", "0") == "1"
        inventory_sizes(env)
    end
    if phase in (:pre_sim_begin, :pre_sim_end)
        if h.mode === :capture
            id = phase === :pre_sim_begin ? "pre_injection" : "post_injection"
            cp, _, sha = _export(h, id, env; loop_state = (phase = phase,))
            phase === :pre_sim_begin ? (h.pre = (sha, cp.artifact_path)) : (h.post = (sha, cp.artifact_path))
            println("[zrv] $(id) exported world_sha=$(sha[1:16])")
        end
        return nothing
    end
    if phase === :sim_end
        # 시뮬 루프 종료 경계에서 종료 기록(스크립트 후처리 — 결과 출력·플래그 정리 — 전). resume 는
        # continuation 이 끝난 뒤 자기가 쓴다(여기서 쓰면 두 번이 된다).
        if !(h.mode === :resume) && !h.terminal_written
            h.terminal_written = true
            _write_terminal!(h, env, ctx.sim_process_data, ctx.sim_params;
                             extra = Dict{String,Any}("t0_iter" => h.t0_iter, "captured" => h.captured,
                                                      "written_at" => "sim_end"))
        end
        return nothing
    end
    if h.mode === :resume && !h.resumed
        return _resume!(h, env, ctx)
    end
    spd = ctx.sim_process_data
    h.last_env = env; h.last_spd = spd; h.last_sim_params = ctx.sim_params
    if h.mode === :capture && !h.captured && zone_event_index() !== nothing
        h.captured = true
        _capture_t0!(h, env, ctx)
    end
    _trace!(h, env, spd, ctx.batch_pos)
    return nothing
end

"""
    install!(mode; dir, detail = nothing)

`HARNESS_HOOK` 에 이 모듈의 훅을 꽂는다. trace/capture 는 프로세스 종료 때(`atexit`) 종료 기록을 쓴다.
"""
function install!(mode::Symbol; dir::AbstractString, detail = nothing)
    mode in (:trace, :capture, :resume) || error("ZRV_REPLAY_MODE must be trace|capture|resume, got $(mode)")
    mkpath(dir)
    io = open(joinpath(dir, "trace.tsv"), "w")
    println(io, "# iter\t", join(ReplayCompare.TRACE_COLUMNS, '\t'), "\t(mode=$(mode); boundary before the step)")
    CB.RVO_RECORD_BUILDS[] = true     # KdTree 순열 재연용 doStep 직전 위치 기록(읽기 전용)
    H[] = Harness(mode, String(dir), io, detail, nothing, nothing, nothing, false, false, ("", ""), ("", ""),
                  nothing, -1, false)
    CB.HARNESS_HOOK[] = hook
    mode === :resume || atexit() do
        h = H[]
        (h === nothing || h.last_env === nothing || h.terminal_written) && return
        try
            _write_terminal!(h, h.last_env, h.last_spd, h.last_sim_params;
                             extra = Dict{String,Any}("t0_iter" => h.t0_iter, "captured" => h.captured,
                                                      "written_at" => "atexit (no sim_end)"))
        catch e
            println("[zrv] terminal record failed: ", sprint(showerror, e))
        end
    end
    println("[zrv] harness installed mode=$(mode) dir=$(dir)")
    return nothing
end

function install_from_env!()
    m = get(ENV, "ZRV_REPLAY_MODE", "")
    isempty(m) && return nothing
    det = get(ENV, "ZRV_TRACE_DETAIL", "")
    detail = isempty(det) ? nothing : (p = parse.(Int, split(det, ':')); p[1]:p[2])
    install!(Symbol(m); dir = ENV["ZRV_REPLAY_DIR"], detail)
end

end # module EpisodeReplay

EpisodeReplay.install_from_env!()
