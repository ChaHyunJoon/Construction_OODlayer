# =============================================================================
# tool_execution.jl — 생성 도구(ToolProposal)의 격리 집행과 실제 효과별 후처리 (T6). 설계 §6.1–6.3·§7.1·§2.
#
# 두 쪽이 한 파일에 있다(T5 와 같은 구성 — 로드에 ConstructionBots 가 필요 없다; CB 는 **인자**로 받는다):
#   * worker 쪽(생성 코드를 싣는 disposable branch worker 안의 신뢰 하니스 코드): `enact_proposal!` —
#     t0 복원 뒤 **등록 → body(trusted engine adapter 아래) → 실제 효과 audit → 효과별 후처리 → export**.
#     body 는 production `enact_minted!(…; envelope = false)` 로 **한 번** 굴리고, 후처리 봉투는 production 과
#     같은 `post_body_envelope!` 를 **실제 diff 로 분류한 효과**에 따라 한 번 부른다(모델의 `surface`·
#     `claimed_effects` 로 고르지 않는다). 기하 효과에만 resync(필요할 때만) + 실제 잔차 검사.
#   * supervisor 쪽(생성 코드 0, JSON 만 읽는다): `execute_tool_isolated`(제안 문 → worker → 판정),
#     `judge_candidate`(T4 rollout + T5 효과 검증 + 원본 작업 계약(post-enactment·terminal) + 후처리 결과를
#     한 후보 판정으로 묶는다 — 계약을 어긴 COMPLETE 는 `eligible = false`).
#
# 집행 순서(설계 §6.2 — 이 파일의 단일 진실원):
#   1. supervisor: `ToolProposalGate.gate_proposal`(봉투·권한·ablation·binding). 거절이면 worker 를 안 띄운다.
#   2. 새 worker 에 t0 checkpoint 복원(T4 `restore_at_t0!`), 원본 작업 계약(부모 t0 파일)을 묶는다.
#   3. `register_minted_primitive!`(현행 AST·규약·ablation 문 + `Core.eval`). 등록이 세계·메서드를 바꾸면
#      `:registration_rejected`(등록 부작용) — body 를 안 굴린다.
#   4. body 실행. body 안의 `step_environment!` 는 `ENGINE_STEP_ADAPTER` 로 **정상 루프 한 반복**
#      (`simulate!` batch 1: 훅·사건 주입·respec·step·캐시·무진전 카운터·배치 끝 `monitor_emit!`)이 되고 같은
#      절대 episode 예산을 쓴다. 매 step 앞: 코드 구간 검사(T5 `code_segment!`) + 계약 + 기하면 resync 보충.
#      preflight 모드는 첫 step 요청에서 `preflight_stop` 을 찍고 멈춘다(`:requires_runtime` — 거절 아님).
#   5. 실제 trace 에서 효과 분류 → 효과별 후처리(아래 `CHECK_ADAPTERS`) → post-enactment 상태 보존.
#   6. (full 모드) 반환 후 공통 continuation(T4 `continue_from!`, adapter 가 넘긴 배치 위치)으로 원래 예산까지.
#   throw · 일부 API 성공 후 실패 · 후처리 실패 · 등록 부작용 · 미관측 효과(override·hook·중재 안 된 engine
#   진행) · timeout → **worker 통째로 폐기**(continuation 없음). 함수 table reset 은 rollback 이 아니다 —
#   `Core.eval` 정의는 프로세스에 남으므로 프로세스를 버린다(설계 §2).
#
# 🔴 못 보는 것(그래서 enforce 는 여전히 닫혀 있다 — T4 `enforce_allowed = false`): 코드 구간 안에서 바꿨다
#    되돌린 변경, 한 스텝 안의 변경, 같은 프로세스 안의 하니스 재정의(이 파일 포함), worker export 위조.
#    `judge_candidate` 는 T5 의 `unobserved` 를 그대로 싣고 운반 닻 검사를 건너뛴 사슬 수를 더한다.
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))
isdefined(Main, :TaskContract) || include(joinpath(@__DIR__, "task_contract.jl"))
isdefined(Main, :EffectValidation) || include(joinpath(@__DIR__, "effect_validation.jl"))
isdefined(Main, :ToolProposalGate) || include(joinpath(@__DIR__, "tool_proposal.jl"))
isdefined(Main, :BranchRunner) || include(joinpath(@__DIR__, "branch_runner.jl"))

module ToolExecution

using JSON3, SHA
import ..RepairTypes as R
import ..TaskContract as TC
import ..EffectValidation as EV
import ..ToolProposalGate as PG
import ..BranchRunner as BR

const TOOL_EXECUTION_VERSION = "tool-execution/1"
const ENACTMENT_SCHEMA = "enactment/1"

"""
검사 adapter inventory(설계 §6.3 표): 실제 diff 에서 나온 효과 종류 → 그 효과에 **실제로 도는** 검사/후처리.
선택 메뉴가 아니다. 효과가 나왔는데 행이 없으면 `unsupported: missing_check_adapter:<class>`.
`VALIDATOR_ADAPTERS` 는 supervisor 가 export 로 재판정하는 T5 규칙(worker 는 안 돈다); 나머지는 worker 안의
신뢰 하니스 코드가 세계에 대고 실행하고, 실행한 이름이 export `postprocess.checks_run` 에 실린다.
"""
const CHECK_ADAPTERS = Dict{Symbol,Vector{Symbol}}(
    :geometry => [:transform_attachment, :scene_resync, :geometry_residual, :cache_resume],
    :assignment => [:team_slot, :assignment_availability, :assignment_completeness, :cache_resume, :assignment_resolve],
    :schedule_graph => [:semantic_precedence, :graph_acyclic, :cache_resume],
    :resource => [:resource_conservation],
    :other => Symbol[])
const VALIDATOR_ADAPTERS = Set([:transform_attachment, :team_slot, :semantic_precedence, :resource_conservation])
"코드 구간에서 움직이면 안 되는 engine 카운터(T4 `engine_counters`; 캐시 논리 시계는 읽기로도 움직여 뺀다)."
const ENGINE_KEYS = ("sim_step", "iter", "rvo_wrapper", "rvo_doSteps")
"무엇이든 이 거리보다 작으면 드리프트 0 으로 본다(sub-tolerance 기록의 바닥)."
const DRIFT_FLOOR = 1e-6

_changed(a::AbstractDict, b::AbstractDict) =
    sort!([String(k) for k in union(keys(a), keys(b)) if get(a, k, nothing) != get(b, k, nothing)])
_one(e) = first(replace(sprint(showerror, e), r"\s+" => " "), 400)
"JSON 왕복 — worker 안 상태 비교·digest 를 파일을 읽는 판정 쪽과 같은 모양으로(raw 와 왕복 Dict 의 digest 는 다르다)."
_js(x) = JSON3.read(JSON3.write(x), Dict{String,Any})

"task_state 절 단위 변경 목록(`절` 또는 사전 절이면 `절(바뀐 키 수)`). body / harness 변경 기록에 쓴다."
function sections_changed(a::AbstractDict, b::AbstractDict)
    out = String[]
    for k in sort!(collect(union(keys(a), keys(b))))
        k == "schema" && continue
        x, y = get(a, k, nothing), get(b, k, nothing)
        x == y && continue
        push!(out, (x isa AbstractDict && y isa AbstractDict) ?
                   "$(k)($(length(_changed(x, y))))" : String(k))
    end
    return out
end

# =============================================================================
# worker 쪽 — trusted engine adapter
# =============================================================================
"하니스가 body 에 던지는 중단. `kind`: `:preflight`(첫 step 직전) · `:violation`(step 앞 검사 실패) · `:budget`(episode 예산 끝) · `:foreign`."
struct HarnessStop <: Exception
    kind::Symbol
    why::String
end
Base.showerror(io::IO, e::HarnessStop) = print(io, "HarnessStop(", e.kind, "): ", e.why)

mutable struct EngineAdapter
    env::Any
    CB::Module
    fv::Any
    anim::Any
    sp::Any                      # SimParameters (원래 episode 의 것 — 예산은 여기서만 읽는다)
    spd::Any                     # SimProcessingData (continuation 과 같은 객체)
    mode::Symbol                 # :preflight | :full
    batch_pos::Int               # **다음** 스텝의 배치 안 위치(1-based)
    up_steps::Vector{Any}
    steps::Int
    stop::Union{Nothing,HarnessStop}
    trace::Vector{Any}
    snap::Function               # kind -> 사건 Dict(state + engine)
    contract::Any                # 원본 작업 계약(Dict) 또는 nothing
    log::Vector{Any}             # 하니스 보충(step 앞 resync) 기록
    tol::Float64
    audit::Function              # T4 audit_snapshot — 필드 diff 를 **코드 구간마다** 따로 잰다
    seg_audit::Any               # 현재 코드 구간 시작의 audit
    code_fields::Set{String}     # 코드 구간(도구가 세계를 직접 만진 구간)에서 바뀐 필드
    engine_fields::Set{String}   # engine 구간(정상 루프 반복)에서 바뀐 필드 — 판정 대상 아님, 기록
end

_halt!(a::EngineAdapter, kind, why) = (a.stop = HarnessStop(kind, why); throw(a.stop))

"코드 구간 a→b 의 위반과 실제 효과 종류(T5 규칙 그대로)."
function code_segment(a::AbstractDict, b::AbstractDict, tag)
    V, cls = String[], Set{Symbol}()
    EV.code_segment!(V, cls, a, b, tag)
    return V, cls
end

"""
    (a::EngineAdapter)(env)

body 의 `step_environment!(env)` 가 여기로 온다. 순서: 앞선 중단이면 다시 던짐 → `pre_step` 스냅샷(코드 구간 끝) →
preflight 면 `preflight_stop` 으로 바꾸고 중단 → 코드 구간 검사 + 원본 계약 → 예산(production 규칙: 배치 시작에서만
`max_time_steps`, 매 스텝 `stop_simulating`) → 기하가 바뀐 구간이면 resync 보충(하니스) → 정상 루프 한 반복
(`simulate!` batch 1, 훅의 배치 위치 = 실제 위치) → 배치 끝이면 `monitor_emit!` → `post_step` 스냅샷.
"""
function (a::EngineAdapter)(env)
    a.stop === nothing || throw(a.stop)
    env === a.env || _halt!(a, :foreign, "step requested on an env that is not the branch world")
    CB = a.CB
    push!(a.trace, a.snap("pre_step"))
    n = a.steps + 1
    if a.mode === :preflight
        a.trace[end]["kind"] = "preflight_stop"
        _halt!(a, :preflight, "requires_runtime: engine progress requested (step $(n)); preflight stops before it")
    end
    prev, cur = a.trace[end-1]["state"], a.trace[end]["state"]
    V, cls = code_segment(prev, cur, "pre_step$(n)")
    a.contract === nothing || append!(V, TC.evaluate_task_contract(a.contract, cur).violations)
    # 이 코드 구간의 필드·메서드 audit — 보호 전역 변경·override 는 step 전에 멈춘다. engine 이 바꾸는 보호 전역(사건 큐·
    # ablation 수·정책 카운터)은 engine 구간에 따로 적혀 도구 탓이 되지 않는다(전 구간 한 번 diff 로는 가를 수 없다 — T6 실측).
    a_now = a.audit(env, a.spd)
    seg = _changed(a.seg_audit.fields, a_now.fields)
    union!(a.code_fields, seg)
    append!(V, ["protected_global_changed:$(f)" for f in seg if f in EV.PROTECTED_FIELDS])
    mseg = _changed(a.seg_audit.methods, a_now.methods)
    isempty(mseg) || push!(V, "runtime_override:" * join(mseg, ","))
    if !isempty(V)
        a.trace[end]["kind"] = "action_end"          # 검사가 멈춘 자리 = 판정할 끝 상태
        _halt!(a, :violation, "pre_step_violation@$(n): " * join(first(V, 5), "; "))
    end
    spd, sp = a.spd, a.sp
    if spd.stop_simulating || (a.batch_pos == 1 && spd.iter >= sp.max_time_steps)
        a.trace[end]["kind"] = "action_end"
        _halt!(a, :budget, "episode budget exhausted inside the tool (iter=$(spd.iter), stop=$(spd.stop_simulating))")
    end
    if :geometry in cls                               # step 앞 정합성: 기하가 바뀐 구간이면 필요한 resync 만 보충
        d = Base.invokelatest(CB.scene_drift, env; tol = a.tol)
        ids = [x.id for x in d if x.would_snap]
        if !isempty(ids)
            Base.invokelatest(CB.resync_scene_to_schedule!, env)
            push!(a.log, Dict{String,Any}("action" => "resync_scene_to_schedule!", "by" => "harness",
                                          "when" => "before_step_$(n)", "snapped" => ids))
            # 🔴 engine 구간은 신뢰 구간이다 — 하니스 resync 가 로봇·잡힌 화물을 옮겼다면(운행 중 운반 유닛째 snap)
            #    그 teleport 가 다음 step 안에 숨는다. 여기서 보고 멈춘다(worker 폐기).
            mv = protected_moved(cur, _js(TC.task_state(env, CB)), d)
            isempty(mv) || (a.trace[end]["kind"] = "action_end";
                            _halt!(a, :violation, "harness resync before step $(n) would move protected bodies: " * join(mv, "; ")))
        end
    end
    CB.ENGINE_STEP_ADAPTER[] = nothing
    try
        sp1 = CB.SimParameters(1, (getfield(sp, i) for i in 2:fieldcount(CB.SimParameters))...)
        a.up_steps = Base.invokelatest(CB.simulate!, env, a.fv, a.anim, sp1, spd, a.up_steps, a.batch_pos - 1)
    finally
        CB.ENGINE_STEP_ADAPTER[] = a
    end
    a.steps = n
    a.batch_pos += 1
    if a.batch_pos > sp.sim_batch_size                # continue_simulation! 의 배치 끝과 같은 자리
        Base.invokelatest(CB.monitor_emit!, env, spd.iter)
        a.batch_pos = 1
    end
    # engine 구간 audit 은 배치 끝 `monitor_emit!` **뒤**에 닫는다(T7) — 앞에 닫으면 그 방출이 다음 코드 구간(도구 탓)에 적힌다.
    a_post = a.audit(env, a.spd)
    union!(a.engine_fields, _changed(a_now.fields, a_post.fields))
    a.seg_audit = a_post
    push!(a.trace, a.snap("post_step"))
    return env
end

"""
resync(하니스 보충)가 옮기면 안 되는 것이 움직였나: 로봇 자세·RVO 위치, 루트가 아닌(잡힌·놓인) 화물 본체/운반 유닛.
`_resync_scene_drift!` 는 로봇을 **직접** 옮기지 않지만, 운행 중인(형성된) 운반 유닛이 루트라 snap 되면 그 자식인
로봇·화물이 **같이** 옮겨진다(실측 — `test/repair_resync.jl` [3]). 그 이동을 사유로 돌려준다(비면 없음).
"""
function protected_moved(pre::AbstractDict, post::AbstractDict, drift)
    out = String[]
    snapped_tus = [x.id for x in drift if x.would_snap && x.kind === :tu]
    for (r, p) in post["robots"]
        get(pre["robots"], r, nothing) == p && get(pre["rvo"], r, nothing) == get(post["rvo"], r, nothing) && continue
        push!(out, "robot_moved:$(r)" * (isempty(snapped_tus) ? "" : " (via snapped transport unit(s) $(join(snapped_tus, ",")))"))
    end
    for x in drift
        x.free && continue
        sec = x.kind === :tu ? "tus" : "scene"
        get(pre[sec], x.id, nothing) == get(post[sec], x.id, nothing) || push!(out, "attached_moved:$(x.id)")
    end
    return out
end

"trace 의 코드 구간(engine 구간 `pre_step→post_step` 밖)을 모두 T5 규칙으로 — (위반, 효과 종류)."
function classify(trace)
    V, cls = String[], Set{Symbol}()
    for i in 1:length(trace)-1
        ka, kb = trace[i]["kind"], trace[i+1]["kind"]
        (ka == "pre_step" && kb == "post_step") && continue
        v, c = code_segment(trace[i]["state"], trace[i+1]["state"], "seg$(i):$(ka)->$(kb)")
        append!(V, v); union!(cls, c)
    end
    return V, [c for c in R.EFFECT_CLASSES if c in cls]
end

"코드 구간에서 engine 카운터가 움직였으면 adapter 밖의 진행이다(관측·예산 우회 — worker 폐기)."
function unmediated_engine(trace)
    out = String[]
    for i in 1:length(trace)-1
        (trace[i]["kind"] == "pre_step" && trace[i+1]["kind"] == "post_step") && continue
        e1, e2 = trace[i]["engine"], trace[i+1]["engine"]
        for k in ENGINE_KEYS
            get(e1, k, nothing) == get(e2, k, nothing) || push!(out, "unmediated_engine_advance:$(k)@seg$(i)")
        end
    end
    return out
end

# ---- 배정 검사(worker, 세계에 대고) -------------------------------------------------------------
"열린 노드마다 책임 로봇(정렬 문자열)과, 로봇마다 활성 운반 노드 수. 배정 가용성·이중 배정 비교의 전/후 표."
function assignment_table(env, CB)
    pairs, active = Set{Tuple{String,String}}(), Dict{String,Int}()
    closed = env.cache.closed_set
    for v in CB.Graphs.vertices(env.sched)
        v in closed && continue
        n = CB.get_node(env.sched, v)
        rs = [string(r) for r in CB._responsible_robots(n.node)]
        id = string(CB.node_id(n))
        foreach(r -> push!(pairs, (r, id)), rs)
        if v in env.cache.active_set && CB.matches_template(Union{CB.FormTransportUnit,CB.TransportUnitGo,CB.DepositCargo}, n)
            foreach(r -> (active[r] = get(active, r, 0) + 1), rs)
        end
    end
    return (pairs = pairs, active = active)
end

"새로 생긴 (로봇, 열린 노드) 배정이 못 쓰는 로봇(고장·퇴역)이면 위반; 활성 운반을 둘 이상 새로 맡은 로봇도 위반."
function assignment_findings(env, CB, t0tab)
    t1 = assignment_table(env, CB)
    bad = Set{String}(string(k) for k in keys(CB.FAULTED_ROBOTS[]))
    union!(bad, [string(k) for k in keys(CB.DECOMMISSIONED_BODIES[])])
    F = String[]
    for (r, id) in sort!(collect(setdiff(t1.pairs, t0tab.pairs)))
        r in bad && push!(F, "assignment_unavailable_robot:$(r)->$(id)")
    end
    for (r, k) in sort!(collect(t1.active))
        k >= 2 && get(t0tab.active, r, 0) < 2 && push!(F, "assignment_double_booked:$(r):$(k)_active_transport_nodes")
    end
    return F
end

"""
배정이 비어 있는 열린 작업(`construction_schedule.jl` `required_predecessors` 기준): 들어오는 RobotGo 가 팀 자리 수보다
적은 FormTransportUnit, 앞 작업(RobotStart/DepositCargo/RobotGo)이 없는 RobotGo(= 로봇 사슬에서 떨어진 자리 —
`release_pending_assignments!` 가 만든다). body 전후로 비교해 **새로 비어진** 작업이 있을 때만 공통 재풀이가 필요하다 —
재배정이 끝난 도구(예: 인계) 뒤에 재풀이를 강제하지 않는다(설계 §6.3 "필요한 보충만").
"""
function unassigned_work(env, CB)
    out = Set{String}()
    closed, S, G = env.cache.closed_set, env.sched, CB.Graphs
    isrobotpred(u) = CB.matches_template(Union{CB.RobotStart,CB.DepositCargo,CB.RobotGo}, CB.get_node(S, u))
    for v in G.vertices(S)
        v in closed && continue
        n = CB.get_node(S, v)
        if CB.matches_template(CB.FormTransportUnit, n)
            have = count(u -> CB.matches_template(CB.RobotGo, CB.get_node(S, u)), G.inneighbors(S, v))
            have < length(CB.robot_team(n.node)) && push!(out, string(CB.node_id(n)))
        elseif CB.matches_template(CB.RobotGo, n)
            any(isrobotpred, G.inneighbors(S, v)) || push!(out, string(CB.node_id(n)))
        end
    end
    return out
end

# ---- 효과별 후처리 ------------------------------------------------------------------------------
"""
    postprocess!(env, CB; classes, before, after_body, asg0, short0, adapters, tol, fail_probe) -> Dict

실제 효과 `classes` 에 맞는 worker adapter 만 실행한다. 기하가 없으면 resync 를 **부르지 않는다**; 기하가 있어도
드리프트가 없으면(body 가 스스로 맞췄으면) 보충하지 않는다(설계 §6.3). 반환: `checks_run`, `failures`(→ worker 폐기),
`unsupported`, `notes`, `log`(하니스가 부른 것 — body 와 따로).
"""
function postprocess!(env, CB; classes, before, after_body, asg0, short0 = Set{String}(), adapters = CHECK_ADAPTERS,
                      tol::Float64, fail_probe::Bool = false)
    run, F, U, notes, log = String[], String[], String[], String[], Any[]
    for c in classes
        haskey(adapters, c) || push!(U, "missing_check_adapter:$(c)")
    end
    want(a) = any(c -> a in get(adapters, c, Symbol[]), classes)
    ran!(a) = (String(a) in run || push!(run, String(a)))
    try
        d_pre = NamedTuple[]
        if want(:scene_resync)
            d0 = Base.invokelatest(CB.scene_drift, env; tol = tol)
            d_pre = d0
            ran!(:scene_resync)
            ids = [x.id for x in d0 if x.would_snap]
            if isempty(ids)
                push!(notes, "scene_resync_not_needed: no free body/TU beyond tol=$(round(tol; digits = 4))")
            else
                Base.invokelatest(CB.resync_scene_to_schedule!, env)
                push!(log, Dict{String,Any}("action" => "resync_scene_to_schedule!", "by" => "harness",
                                            "when" => "after_body", "snapped" => ids))
            end
            for x in d0
                if !x.free && get(before["poses"], x.start_id, nothing) != get(after_body["poses"], x.start_id, nothing)
                    push!(U, "resync_out_of_scope:attached_body_start_moved:$(x.id)")
                end
            end
        end
        if want(:geometry_residual)
            d1 = Base.invokelatest(CB.scene_drift, env; tol = tol)
            ran!(:geometry_residual)
            for x in d1
                x.would_snap && push!(F, "geometry_residual:$(x.id):$(round(x.dist; digits = 4))")
                x.free && DRIFT_FLOOR < x.dist <= tol &&
                    push!(notes, "sub_tolerance_drift:$(x.id):$(round(x.dist; digits = 4)) (resync helper tolerance)")
            end
            # 하니스가 로봇·잡힌 화물을 옮겼나(운행 중 운반 유닛째 snap) — 옮겼으면 후처리 실패(worker 폐기)
            append!(F, ["postprocess_" * m for m in protected_moved(after_body, _js(TC.task_state(env, CB)), d_pre)])
        end
        if want(:graph_acyclic)
            ran!(:graph_acyclic)
            CB.Graphs.is_cyclic(CB.get_graph(env.sched)) && push!(F, "schedule_graph_cyclic")
        end
        short = String[]
        if want(:assignment_completeness)
            ran!(:assignment_completeness)
            short = sort!(collect(setdiff(unassigned_work(env, CB), short0)))
            isempty(short) && push!(notes, "assignment_resolve_not_needed: no open task lost its robot assignment")
        end
        resume = want(:cache_resume) && isempty(F)
        resolve = want(:assignment_resolve) && !isempty(short) && isempty(F)
        if resume || resolve
            ev = Base.invokelatest(CB.post_body_envelope!, env; resume = resume, touched = true, resolve = resolve,
                                   resolve_skip_why = "no newly unassigned task in the real diff")
            resume && ran!(:cache_resume)
            resolve && ran!(:assignment_resolve)
            push!(log, Dict{String,Any}("action" => "post_body_envelope!", "by" => "harness",
                                        "resume" => String(ev.resume), "resume_detail" => ev.resume_detail,
                                        "resolve" => String(ev.resolve), "resolve_detail" => ev.resolve_detail))
            ev.resume === :failed && push!(F, "cache_resume_failed: $(ev.resume_detail)")
            resolve && ev.resolve in (:infeasible, :commit_failed, :threw) &&
                push!(F, "assignment_resolve_$(ev.resolve): $(ev.resolve_detail)")
        end
        if want(:assignment_availability)
            ran!(:assignment_availability)
            append!(F, assignment_findings(env, CB, asg0))
        end
        fail_probe && error("ZRV_PROBE_POSTPROCESS_FAIL: injected postprocess failure after the harness changed the world")
    catch e
        e isa InterruptException && rethrow()
        push!(F, "postprocess_threw: " * _one(e))
    end
    va = unique(sort!([String(a) for c in classes for a in get(adapters, c, Symbol[]) if a in VALIDATOR_ADAPTERS]))
    return Dict{String,Any}("checks_run" => run, "failures" => F, "unsupported" => U, "notes" => notes, "log" => log,
                            "validator_adapters" => va)
end

# ---- 한 후보 집행 --------------------------------------------------------------------------------
_zone_truth(CB) = (log = CB.ood_truth_log(); j = findlast(e -> e.truth isa CB.ZoneTruth, log); j === nothing ? nothing : log[j].truth)

"""
    enact_proposal!(env, fv, anim, sp, spd; proposal, mode, CB, contract, audit, engine, batch_pos,
                    adapters = CHECK_ADAPTERS, fail_probe = false) -> (; record, trace, adapter)

worker 쪽 한 후보 집행(파일 머리말의 3–5). `audit(env, spd)` = T4 `RepairBranchWorker.audit_snapshot`,
`engine(spd)` = T4 `engine_counters`. 반환 `record` 는 code-free Dict(schema `enactment/1`) — `status ∈
RepairTypes.ENACTMENT_STATUSES`. 세계를 되돌리지 않는다: `status != :enacted` 면 호출자가 worker 를 버린다.
"""
function enact_proposal!(env, fv, anim, sp, spd; proposal::AbstractDict, mode::Symbol, CB::Module, contract,
                         audit::Function, engine::Function, batch_pos::Int, adapters = CHECK_ADAPTERS,
                         fail_probe::Bool = false, tol::Float64 = Float64(CB.default_robot_radius()))
    mode in (:preflight, :full) || error("mode must be :preflight or :full")
    t_start = time()
    impl = String(proposal["impl_name"])
    clk() = Dict{String,Any}("iter" => spd.iter, "no_progress" => spd.num_iters_no_progress,
                             "stop" => spd.stop_simulating, "last_closed" => spd.last_iter_num_closed)
    # 상태는 JSON 왕복한 값으로 든다 — worker 안 digest(trace·post_state)가 파일을 읽는 판정 쪽 digest 와 같아야 한다
    # (raw Dict 과 왕복 Dict 의 `TC.digest` 는 다르다 — 실측).
    state() = _js(TC.task_state(env, CB; extra_clock = clk()))
    snap(kind) = Dict{String,Any}("kind" => kind, "state" => state(), "engine" => engine(spd))
    X = Dict{String,Any}("schema" => ENACTMENT_SCHEMA, "version" => TOOL_EXECUTION_VERSION, "mode" => String(mode),
        "proposal_id" => String(proposal["proposal_id"]), "checkpoint_id" => String(proposal["checkpoint_id"]),
        "proposal_sha256" => TC.digest(proposal), "impl_name" => impl)
    trace = Any[]
    adapter = nothing
    function finish(status, exc = nothing)
        X["status"] = String(status); X["exception"] = exc
        X["engine_steps"] = adapter === nothing ? 0 : adapter.steps
        X["batch_pos"] = adapter === nothing ? batch_pos : adapter.batch_pos
        X["trace_digest"] = TC.digest([Dict("kind" => e["kind"], "state" => TC.digest(e["state"])) for e in trace])
        X["wall_s"] = time() - t_start
        return (; record = X, trace, adapter)
    end
    # ---- 3. 등록 --------------------------------------------------------------------------------
    s_pre, a_pre = snap("action_start"), audit(env, spd)
    why = try
        CB.register_minted_primitive!(name = impl, code = String(proposal["impl_code"]),
            params = proposal["params"], surface = String(get(proposal, "surface", "unknown")),
            reversible = get(proposal, "reversible", false) === true)
    catch e
        "reject:registration_threw:" * _one(e)          # 계약상 던지지 않는다 — 던지면 그것도 거절 사유
    end
    a_reg, s_reg = audit(env, spd), snap("action_start")
    reg = Dict{String,Any}("why" => why,
        "fields_changed" => [f for f in _changed(a_pre.fields, a_reg.fields) if !(f in EV.HARNESS_FIELDS) && !(f in EV.OBSERVATION_FIELDS)],
        # 등록이 만든 이름만 뺀다: 그 함수 자신과 lowering 이 만든 키워드 본체(`#<impl>#N`) — **새로 생긴** 키일 때만.
        "methods_changed" => [m for m in _changed(a_pre.methods, a_reg.methods)
                              if !(!haskey(a_pre.methods, m) && (m == "ConstructionBots.$(impl)" ||
                                                                startswith(m, "ConstructionBots.#$(impl)#")))],
        "state_changed" => TC.digest(s_pre["state"]) != TC.digest(s_reg["state"]))
    X["registration"] = reg
    X["before_state"] = s_reg["state"]
    why === nothing || return finish(:registration_rejected, String(why))
    (isempty(reg["fields_changed"]) && isempty(reg["methods_changed"]) && !reg["state_changed"]) ||
        return finish(:registration_rejected, "registration_side_effect: fields=$(reg["fields_changed"]) " *
                                              "methods=$(reg["methods_changed"]) state_changed=$(reg["state_changed"])")
    # ---- 4. body (trusted engine adapter 아래, production enact_minted! 한 번 — 봉투 없이) ---------------
    asg0, short0 = assignment_table(env, CB), unassigned_work(env, CB)
    push!(trace, s_reg)
    adapter = EngineAdapter(env, CB, fv, anim, sp, spd, mode, batch_pos, Any[], 0, nothing, trace, snap,
                            contract, Any[], tol, audit, a_reg, Set{String}(), Set{String}())
    synth = Dict{String,Any}("impl_name" => impl, "body_names" => [impl], "calls" => proposal["calls"],
                             "params" => proposal["params"])
    CB.ENGINE_STEP_ADAPTER[] = adapter
    r = try
        CB.enact_minted!(env, _zone_truth(CB), synth; envelope = false)
    catch e
        e isa InterruptException && rethrow()
        (verdict = :threw_outside_body, reason = _one(e), partial = true, steps = NamedTuple[], applied = nothing)
    finally
        CB.ENGINE_STEP_ADAPTER[] = nothing
    end
    a_body = audit(env, spd)
    stop = adapter.stop
    post_stop_mut = false
    if stop === nothing
        push!(trace, snap("action_end"))
    else
        post_stop_mut = TC.digest(state()) != TC.digest(trace[end]["state"])
    end
    after_body = trace[end]["state"]
    X["after_body_state"] = after_body
    union!(adapter.code_fields, _changed(adapter.seg_audit.fields, a_body.fields))   # 마지막 코드 구간(마지막 step 뒤 → 반환)
    X["audit"] = Dict{String,Any}("fields_changed_by_action" => sort!(collect(adapter.code_fields)),
        "fields_changed_by_engine" => sort!(collect(adapter.engine_fields)),
        "methods_changed_by_action" => _changed(a_reg.methods, a_body.methods),
        "world_counter_delta" => Int(a_body.world - a_reg.world), "engine_before" => a_reg.engine,
        "engine_after" => a_body.engine,
        "window" => "code segments only (after registration → body return, minus adapter engine steps); harness postprocess excluded")
    X["body"] = Dict{String,Any}("verdict" => String(r.verdict), "reason" => r.reason, "partial" => r.partial,
        "applied" => r.applied, "steps" => [Dict("name" => s.name, "status" => String(s.status), "detail" => s.detail) for s in r.steps],
        "harness_stop" => stop === nothing ? nothing : Dict("kind" => String(stop.kind), "why" => stop.why),
        "changed_after_harness_stop" => post_stop_mut)
    X["body_changes"] = sections_changed(s_reg["state"], after_body)
    X["adapter_log"] = adapter.log
    unobs = String[]
    isempty(X["audit"]["methods_changed_by_action"]) || push!(unobs, "runtime_override:" * join(X["audit"]["methods_changed_by_action"], ","))
    for f in X["audit"]["fields_changed_by_action"]
        f in EV.HOOK_FIELDS && push!(unobs, "persistent_callback:$(f)")
    end
    append!(unobs, unmediated_engine(trace))
    X["unobservable"] = unobs
    # ---- 상태 판정(폐기 여부) ---------------------------------------------------------------------
    r.verdict in (:reject, :deferred) && return finish(:registration_rejected, "body_not_run: " * String(r.reason))
    if stop !== nothing
        stop.kind === :preflight && return finish(:requires_runtime, stop.why)
        stop.kind === :violation && return finish(:partial, stop.why)
        stop.kind === :foreign && return finish(:unobservable, stop.why)
        post_stop_mut && return finish(:unobservable, "the body changed the world after the harness stopped it ($(stop.why))")
    end
    if r.partial && stop === nothing
        det = isempty(r.steps) ? r.reason : r.steps[end].detail
        changed = TC.digest(s_reg["state"]) != TC.digest(after_body)
        return finish(changed ? :partial : :threw, "body threw: " * String(det))
    end
    isempty(unobs) || return finish(:unobservable, join(unobs, "; "))
    # ---- 5. 실제 효과 → 효과별 후처리 ------------------------------------------------------------
    _, classes = classify(trace)
    X["effect_classes"] = String.(classes)
    a_pp0 = a_body
    pp = postprocess!(env, CB; classes, before = s_reg["state"], after_body, asg0, short0, adapters, tol, fail_probe)
    post = state()
    a_pp = audit(env, spd)
    pp["fields_changed"] = _changed(a_pp0.fields, a_pp.fields)
    X["postprocess"] = pp
    X["post_state"] = post
    X["post_state_sha256"] = TC.digest(post)
    X["harness_changes"] = sections_changed(after_body, post)
    stop !== nothing && stop.kind === :budget && push!(pp["notes"], "episode budget ended inside the tool: " * stop.why)
    isempty(pp["failures"]) || return finish(:partial, "postprocess_failed: " * join(pp["failures"], "; "))
    return finish(:enacted)
end

"worker 가 쓰는 두 파일(고정 code-free): `enactment.json` · `effect_trace.json`(사건마다 kind·state·engine)."
function write_enactment(dir::AbstractString, en)
    open(io -> JSON3.write(io, en.trace), joinpath(dir, "effect_trace.json"), "w")
    open(io -> JSON3.write(io, en.record), joinpath(dir, "enactment.json"), "w")
    return nothing
end

# =============================================================================
# supervisor 쪽 — 판정(JSON 만; 생성 코드 없음)
# =============================================================================
_json(p) = JSON3.read(read(p, String), Dict{String,Any})
_s(x) = x === nothing ? nothing : String(x)

"운반 사슬 중 닻 검사(T5 fix I1)를 건너뛴 사슬 수 — source/assembly_complete 가 없으면 규칙이 조용히 지나간다."
function anchor_unobserved(C::AbstractDict)
    ch = get(C, "transport_chains", Any[])
    n = count(c -> get(c, "source", nothing) === nothing || get(c, "assembly_complete", nothing) === nothing ||
                   get(c, "deposit_rel_assembly", nothing) === nothing || get(c, "ftu_rel_source", nothing) === nothing, ch)
    return n == 0 ? String[] : ["transport_anchor_unchecked: $(n)/$(length(ch)) transport chains have no source/assembly_complete anchor — the anchor rule skipped them"]
end

"""
    cross_check(X, contract, proposal_file) -> Vector{String}

worker 가 쓴 enactment 의 신원 필드를 신뢰 쪽 사실과 대조한다(T7): `proposal_sha256` ↔ supervisor 가 쓴 제안 파일의 digest,
`proposal_id` ↔ 그 파일, `checkpoint_id` ↔ 부모 contract, `post_state_sha256` ↔ `digest(post_state)`. 어긋남마다
`"cross_check:…"` 사유(비면 일치). 제안 파일이 없으면 대조 불가도 사유다.
"""
function cross_check(X::AbstractDict, contract::AbstractDict, proposal_file::AbstractString)
    out = String[]
    P = try isfile(proposal_file) ? _json(proposal_file) : nothing catch; nothing end
    if P === nothing
        push!(out, "cross_check: submitted proposal file missing/unreadable ($(basename(proposal_file))) — proposal_sha256 cannot be checked")
    else
        get(X, "proposal_sha256", nothing) == TC.digest(P) ||
            push!(out, "cross_check: proposal_sha256 $(get(X, "proposal_sha256", nothing)) != digest of the submitted proposal")
        get(X, "proposal_id", nothing) == get(P, "proposal_id", missing) ||
            push!(out, "cross_check: proposal_id $(get(X, "proposal_id", nothing)) != submitted $(get(P, "proposal_id", nothing))")
    end
    get(X, "checkpoint_id", nothing) == contract["checkpoint_id"] ||
        push!(out, "cross_check: checkpoint_id $(get(X, "checkpoint_id", nothing)) != contract $(contract["checkpoint_id"])")
    if haskey(X, "post_state") || get(X, "post_state_sha256", nothing) !== nothing
        ps = get(X, "post_state", nothing)
        (ps isa AbstractDict && get(X, "post_state_sha256", nothing) == TC.digest(ps)) ||
            push!(out, "cross_check: post_state_sha256 does not match digest(post_state)")
    end
    return out
end

"""
    judge_candidate(parent_dir, branch_dir; rollout = nothing, proposal_file = branch_dir * ".proposal.json") -> NamedTuple

한 후보의 판정. 입력은 전부 파일(부모 t0 의 `task_contract.json`, worker 의 `enactment.json`·`effect_trace.json`·
`terminal.json`)과 `rollout`(= `BranchRunner.run_branch` 의 결과, full 모드). 생성 코드를 싣지 않는다.
`eligible` ⟺ 집행 `:enacted` ∧ 효과 판정 accept/noop ∧ 후처리 실패·unsupported 없음 ∧ post-enactment 계약 통과 ∧
rollout `COMPLETE`·위반 없음 ∧ **terminal 계약 통과**(T4 validator 는 계약을 안 본다 — 여기서 묶는다).
`precommit_ok` = 위에서 rollout·terminal 을 뺀 것(T7 commit worker 의 t1 판정). 둘 다 `cross_check` 통과를 요구한다.
`feedback_allowed` 는 preflight 에서만 참이다(t0 에서 첫 engine 진행 직전까지의 결과 — 설계 §6.1).
"""
function judge_candidate(parent_dir::AbstractString, branch_dir::AbstractString; rollout = nothing,
                         proposal_file::AbstractString = branch_dir * ".proposal.json")
    contract = _json(joinpath(parent_dir, "contract.json"))
    tcp = joinpath(parent_dir, "task_contract.json")
    tcm = get(contract, "task_contract", Dict{String,Any}())
    reasons, unobserved = String[], String[]
    C = if isfile(tcp) && get(tcm, "sha256", "") == bytes2hex(sha256(read(tcp)))
        _json(tcp)
    else
        push!(reasons, "task_contract_unavailable: $(get(tcm, "error", "missing or digest mismatch"))"); nothing
    end
    C === nothing || append!(unobserved, anchor_unobserved(C))
    ep, trp = joinpath(branch_dir, "enactment.json"), joinpath(branch_dir, "effect_trace.json")
    X = try isfile(ep) ? _json(ep) : nothing catch e; push!(reasons, "malformed_export: enactment.json " * _one(e)); nothing end
    trace = try isfile(trp) ? JSON3.read(read(trp, String), Vector{Any}) : nothing catch e; push!(reasons, "malformed_export: effect_trace.json " * _one(e)); nothing end
    sup = rollout === nothing ? nothing : rollout.supervisor
    wall = sup === nothing ? 0.0 : Float64(sup.wall_s); cpu = sup === nothing ? 0.0 : Float64(sup.cpu_s)
    mode = X === nothing ? "unknown" : String(get(X, "mode", "unknown"))
    effects = contract_post = contract_terminal = nothing
    pp = Dict{String,Any}("checks_run" => String[], "failures" => String[], "unsupported" => String[], "notes" => String[], "log" => Any[])
    local enact::R.EnactmentReport
    if X === nothing || !(get(X, "status", nothing) isa AbstractString) || !(Symbol(X["status"]) in R.ENACTMENT_STATUSES)
        st = (sup !== nothing && sup.timed_out) ? :timeout : :unobservable
        push!(reasons, "no enactment export (worker killed or crashed before writing it): status $(st)")
        if rollout !== nothing
            rollout.report.unknown_cause === nothing || push!(reasons, "rollout UNKNOWN: $(rollout.report.unknown_cause)")
            haskey(rollout.checks, "error") && push!(reasons, "worker error: $(get(rollout.checks["error"], "message", ""))")
        end
        enact = R.EnactmentReport(X === nothing ? "?" : String(get(X, "proposal_id", "?")), String(contract["checkpoint_id"]),
                                  basename(branch_dir), st, nothing, Dict{String,Any}[], String[], String[], 0, wall, cpu, nothing)
    else
        st = Symbol(X["status"])
        exc = _s(get(X, "exception", nothing))
        st === :threw && exc === nothing && (exc = "threw")
        summ = trace === nothing ? Dict{String,Any}[] :
               [Dict{String,Any}("kind" => e["kind"], "state_sha256" => TC.digest(e["state"]), "engine" => get(e, "engine", nothing)) for e in trace]
        post = get(X, "post_state_sha256", nothing)
        st === :enacted && post === nothing && (st = :unobservable; push!(reasons, "enacted without post_state_sha256"))
        enact = R.EnactmentReport(String(X["proposal_id"]), String(X["checkpoint_id"]), basename(branch_dir), st, exc, summ,
                                  String.(get(X, "body_changes", String[])), String.(get(X, "harness_changes", String[])),
                                  Int(get(X, "engine_steps", 0)), wall, cpu, _s(post))
        haskey(X, "postprocess") && (pp = X["postprocess"])
        exc === nothing || push!(reasons, "enactment $(st): $(exc)")
        append!(reasons, cross_check(X, contract, proposal_file))
        if C !== nothing && trace !== nothing && haskey(X, "after_body_state") && haskey(X, "audit")
            effects = EV.validate_effects(C, X["before_state"], X["after_body_state"]; audit = X["audit"], trace = trace,
                                          proposal_id = String(X["proposal_id"])).report
            append!(unobserved, effects.unobserved)
        end
        C !== nothing && haskey(X, "post_state") &&
            (contract_post = TC.task_contract_report(C, X["post_state"]; terminal = false, proposal_id = String(X["proposal_id"])))
        contract_post === nothing || append!(unobserved, contract_post.unobserved)
    end
    xcheck_ok = !any(r -> startswith(r, "cross_check:"), reasons)
    append!(reasons, ["postprocess_failed: $(f)" for f in pp["failures"]])
    append!(reasons, ["unsupported: $(u)" for u in pp["unsupported"]])
    effects === nothing || effects.verdict in (:accept, :noop_equivalent) || append!(reasons, ["effects $(effects.verdict): $(x)" for x in effects.reasons])
    contract_post === nothing || contract_post.verdict === :accept || append!(reasons, ["post-enactment contract: $(x)" for x in contract_post.reasons])
    rep = rollout === nothing ? nothing : rollout.report
    if rep !== nothing && C !== nothing
        tp = joinpath(branch_dir, "terminal.json")
        ts = try (t = _json(tp); t["branch"]["task_state"]) catch; nothing end
        if ts === nothing
            rep.outcome === :COMPLETE && push!(reasons, "terminal task_state missing — COMPLETE cannot be checked against the contract")
        else
            contract_terminal = TC.task_contract_report(C, ts; terminal = true, proposal_id = String(enact.proposal_id))
            contract_terminal.verdict === :accept || append!(reasons, ["terminal contract: $(x)" for x in contract_terminal.reasons])
            append!(unobserved, contract_terminal.unobserved)     # terminal 에서 선행 검사는 공허하다(T7)
        end
        isempty(rollout.violations) || append!(reasons, ["rollout: $(x)" for x in rollout.violations])
    end
    # t1(도구 반환·후처리 직후)까지의 판정 — T7 commit worker 는 이것이 참이고 검증 분기와 같을 때만 활성화된다.
    precommit_ok = xcheck_ok && enact.status === :enacted && effects !== nothing && effects.verdict in (:accept, :noop_equivalent) &&
                   isempty(pp["failures"]) && isempty(pp["unsupported"]) &&
                   contract_post !== nothing && contract_post.verdict === :accept
    eligible = precommit_ok &&
               rep !== nothing && rep.outcome === :COMPLETE && isempty(rollout.violations) &&
               contract_terminal !== nothing && contract_terminal.verdict === :accept
    feedback_allowed = mode == "preflight"
    return (; enactment = enact, effects, contract_post, contract_terminal, rollout = rep, eligible, precommit_ok, reasons,
            unobserved = unique(unobserved), mode, feedback_allowed,
            feedback = feedback_allowed ? copy(reasons) : String[],
            checks_run = String.(pp["checks_run"]), validator_adapters = String.(get(pp, "validator_adapters", String[])),
            harness_log = vcat(X === nothing ? Any[] : get(X, "adapter_log", Any[]), pp["log"]),
            notes = String.(pp["notes"]), effect_classes = X === nothing ? String[] : String.(get(X, "effect_classes", String[])))
end

"""
    execute_tool_isolated(; parent_dir, raw, outroot, branch_id, launch_env, limits, mode = "full",
                          sandbox = true, extra_env = Dict()) -> NamedTuple

설계 §4 의 이름(`execute_tool_isolated(cp, proposal)`)을 T4 부모/분기 틀에 맞춘 것: `parent_dir` 가 checkpoint
(부모가 t0 에서 tick 없이 기다린다). 1) 제안 문(생성 코드 실행 없음) — 거절이면 worker 없이 돌려준다.
2) 새 worker(`BranchRunner.run_branch(…; proposal_file, mode)`). 3) `judge_candidate`.
반환: `(; gate, judged, eligible, reasons, feedback_allowed, feedback, run)`.
`mode = "commit"`(T7): full 과 같은 등록·body·후처리 뒤 worker 가 t1 에서 **멈춰** `held_t1.json` 을 쓰고 `activate`/`exit`
명령을 기다린다. 명령은 `on_tick(p)`(supervisor 폴링 루프에서 불린다)가 보낸다 — `RepairSupervisor.commit_tool!` 가 쓴다.
"""
function execute_tool_isolated(; parent_dir::AbstractString, raw::AbstractDict, outroot::AbstractString,
                               branch_id::AbstractString, launch_env::AbstractDict, limits::BR.Limits,
                               mode::AbstractString = "full", sandbox::Bool = true,
                               extra_env::AbstractDict = Dict{String,String}(), on_tick = nothing)
    contract = _json(joinpath(parent_dir, "contract.json"))
    g = PG.gate_proposal(raw; checkpoint_id = String(contract["checkpoint_id"]),
                         ablation_level = Symbol(contract["pi0"]["REPAIR_ABLATION"]))
    if g.report.verdict !== :accept
        return (; gate = g.report, judged = nothing, eligible = false, reasons = copy(g.report.reasons),
                feedback_allowed = true, feedback = copy(g.report.reasons), run = nothing)
    end
    mkpath(outroot)
    pf = joinpath(outroot, branch_id * ".proposal.json")
    ispath(pf) && error("proposal file exists: $(pf) — each candidate gets a fresh namespace")
    open(io -> JSON3.write(io, raw), pf, "w")
    v = BR.run_branch(; parent_dir, branch_id, outroot, launch_env, limits, sandbox, extra_env,
                      proposal_file = pf, mode, on_tick)
    j = judge_candidate(parent_dir, v.dir; rollout = mode in ("full", "commit") ? v : nothing, proposal_file = pf)
    return (; gate = g.report, judged = j, eligible = j.eligible, reasons = j.reasons,
            feedback_allowed = j.feedback_allowed, feedback = j.feedback, run = v)
end

end # module ToolExecution
