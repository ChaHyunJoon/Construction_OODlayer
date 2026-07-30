# =============================================================================
# monitor.jl — 런타임 모니터링 스트림 방출기 (JSONL 한 줄 = 한 프레임)
# -----------------------------------------------------------------------------
# ConstructionBots 모듈 안으로 runtime-include 되는 파일 (navigator/battery 와 동일 패턴).
# 매 sim 배치마다 env 상태를 JSON 한 줄로 방출 → tools/monitor/dashboard.html 이 재생.
#
# [비파괴 원칙] 기존 전역 상태만 "읽는다":
#   - env.cache.active_set / closed_set        (진행중/완료 스케줄 정점)
#   - env.scene_tree                           (로봇·어셈블리 위치/계층)
#   - BATTERY_FLEET[]  (있으면)                (SoC)
#   - ood_truth_log()  (있으면)                (OOD 이벤트 기록)
# respec 결정만 monitor_record_respec! 로 얕게 받아둔다(선택).
#
# JSON3 은 ConstructionBots 의 하드 의존성(Project.toml)이라 그대로 사용한다.
# =============================================================================

const MONITOR_IO      = Ref{Union{Nothing,IO}}(nothing)  # 열린 스트림 파일 핸들
const MONITOR_RESPEC  = Ref{Any}(nothing)                # 최근 respec 결정(선택)
const MONITOR_RESPEC_HISTORY = Any[]                     # every OOD decision in this run
const MONITOR_FAULTED = Set{Any}()                       # FAULT 로 표시할 로봇 id(선택)
const MONITOR_NODE_T  = Dict{Int,Any}()                  # Gantt: 스케줄 정점 v => {t0,t1,kind,label,robots}
const MONITOR_HANDOFF_T = Dict{Any,Float64}()            # logical robot id => physical spare handoff time

# ---- 스트림 열기/닫기 --------------------------------------------------------
"""    monitor_enable!(path) — JSONL 스트림 파일을 연다. run 시작 전에 호출."""
function monitor_enable!(path::AbstractString)
    monitor_disable!()
    empty!(MONITOR_NODE_T); empty!(MONITOR_HANDOFF_T); MONITOR_RESPEC[] = nothing; empty!(MONITOR_RESPEC_HISTORY); empty!(MONITOR_FAULTED)  # 새 run 이면 상태 초기화
    mkpath(dirname(path))
    MONITOR_IO[] = open(path, "w")
    @info "[monitor] streaming → $path"
    return MONITOR_IO[]
end

"""    monitor_disable!() — 스트림을 닫는다. run 종료 후 호출."""
function monitor_disable!()
    io = MONITOR_IO[]
    io === nothing || (close(io); MONITOR_IO[] = nothing)
    return nothing
end

# ---- 작은 도우미들 -----------------------------------------------------------
# NaN/Inf 는 JSON 에 못 쓰므로 null(=nothing) 로 바꾼다.
_mon_finite(x) = (x isa Real && !isfinite(x)) ? nothing : x

# 배터리 레이어가 로드돼 있으면 fleet 반환, 아니면 nothing.
function _mon_fleet()
    isdefined(@__MODULE__, :BATTERY_FLEET) || return nothing
    try
        return BATTERY_FLEET[]
    catch
        return nothing
    end
end

# 활성 스케줄 노드(=현재 행동)를 담당 로봇 목록으로 역매핑.
function _mon_actors(node, env=nothing)
    try
        if node isa Union{RobotGo, RobotStart}
            return Any[node_id(entity(node))]
        elseif node isa Union{TransportUnitGo, FormTransportUnit, DepositCargo}
            return collect(keys(robot_team(node)))
        elseif node isa LiftIntoPlace && env !== nothing
            # LiftIntoPlace moves cargo and therefore has no direct robot_team.
            # Attribute it to the nearest preceding team-bearing schedule node.
            start_v = get_vtx(env.sched, node_id(node))
            frontier = collect(Graphs.inneighbors(env.sched, start_v))
            seen = Set{Int}([start_v])
            for _ in 1:6
                next_frontier = Int[]
                for v in frontier
                    v in seen && continue
                    push!(seen, v)
                    pred = get_node(env.sched, v).node
                    actors = _mon_actors(pred, nothing)
                    isempty(actors) || return actors
                    append!(next_frontier, Graphs.inneighbors(env.sched, v))
                end
                frontier = next_frontier
                isempty(frontier) && break
            end
        end
    catch
    end
    return Any[]
end

# 스케줄 노드 → 대시보드용 RobotMode 문자열.
function _mon_mode(node)
    node isa TransportUnitGo && return "CARRY"
    node isa RobotGo && return "TRANSIT"
    node isa Union{FormTransportUnit, DepositCargo, LiftIntoPlace} && return "MANIPULATE"
    return "IDLE"
end

# Gantt 레인 색 구분용 종류 태그. 행위자(로봇)가 붙는 노드만 반환, 나머지는 ""(=Gantt 제외).
function _mon_gantt_kind(node)
    node isa RobotGo && return "go"
    node isa TransportUnitGo && return "carry"
    node isa FormTransportUnit && return "form"
    node isa DepositCargo && return "deposit"
    node isa LiftIntoPlace && return "lift"
    return ""
end

# 사람이 읽을 짧은 행동 라벨: "TransportUnitGo · TransportUnitID(4)" 형태.
function _mon_action(node)
    base = string(nameof(typeof(node)))
    tgt = ""
    try
        tgt = string(node_id(entity(node)))
    catch
    end
    isempty(tgt) ? base : string(base, " · ", tgt)
end

# ---- 로봇 스냅샷 -------------------------------------------------------------
function _mon_robots(env)
    fleet = _mon_fleet()
    # OOD truth is the authoritative event-time health observation. It remains
    # valid even if planner identity is subsequently rebound to a healthy spare.
    observed_soc = Dict{Any,Float64}()
    if isdefined(@__MODULE__, :ood_truth_log)
        for e in try ood_truth_log() catch; Any[] end
            e.truth isa BatteryTruth || continue
            observed_soc[e.truth.robot] = Float64(e.truth.soc_after)
        end
    end
    # rid => (mode, action) : 활성 노드에서 담당 로봇을 뽑아 채운다.
    act = Dict{Any,Tuple{String,String}}()
    for v in env.cache.active_set
        node = get_node(env.sched, v).node
        m = _mon_mode(node); a = _mon_action(node)
        for rid in _mon_actors(node, env)
            act[rid] = (m, a)
        end
    end
    swaps = try hot_swap_assets() catch; Dict{Any,Any}() end
    checked_out = Set(v.spare for v in values(swaps))
    out = Vector{Any}()
    for n in get_nodes(env.scene_tree)
        matches_template(RobotNode, n) || continue
        rid = node_id(n)
        rid in checked_out && continue
        swap = get(swaps, rid, nothing)
        mode, action = get(act, rid, ("IDLE", "await eligible step"))
        # The logical schedule id is reused by a healthy spare. Only the
        # original physical asset (emitted as the retired row below) is FAULT.
        (rid in MONITOR_FAULTED && swap === nothing) && (mode = "FAULT")
        soc = fleet === nothing ? nothing : _mon_finite(get(fleet.soc, rid, nothing))
        if swap === nothing && haskey(observed_soc, rid)
            soc = _mon_finite(observed_soc[rid])
        end
        depleted = fleet !== nothing && rid in fleet.depleted
        if swap === nothing && soc isa Real && soc <= REPLACE_SOC_THRESHOLD[]
            depleted = true
            mode = "DEPLETED"
        end
        pos = try
            collect(global_transform(n).translation)[1:2]
        catch
            nothing
        end
        display_id = swap === nothing ? rid : swap.spare
        push!(out, Dict{String,Any}(
            "id"       => string(display_id),
            "schedule_id" => string(rid),
            "replacement_for" => swap === nothing ? nothing : string(rid),
            "retired"  => false,
            "mode"     => mode,
            "action"   => action,
            "soc"      => soc,
            "depleted" => depleted,
            "pos"      => pos === nothing ? nothing : _mon_finite.(pos),
        ))
    end
    # Preserve the failed physical asset as its own dashboard row. The live
    # scene node keeps the logical schedule id for planner robustness, but the
    # operator must see that the original body stayed depleted and stopped.
    for (rid, swap) in swaps
        cause = hasproperty(swap, :cause) ? swap.cause :
                (swap.failed_soc isa Real && swap.failed_soc <= REPLACE_SOC_THRESHOLD[] ? :battery : :fault)
        retired_mode = cause == :battery ? "DEPLETED" : "FAULT"
        push!(out, Dict{String,Any}(
            "id" => string(rid), "schedule_id" => string(rid),
            "replacement_for" => nothing, "retired" => true,
            "mode" => retired_mode, "action" => "physical asset retired → $(swap.spare) took over",
            "soc" => _mon_finite(swap.failed_soc), "depleted" => cause == :battery,
            "pos" => _mon_finite.(swap.position),
        ))
    end
    return out
end

"Track short-lived schedule actions at simulation-step resolution for the Gantt view."
function monitor_track_schedule_step!(env, iter::Integer; dt=nothing)
    MONITOR_IO[] === nothing && return nothing
    sim_t = iter * (dt === nothing ? env.dt : dt)
    # Capture the hand-off at step resolution. Waiting for the next emitted
    # JSON frame (normally every 50 steps) incorrectly extended the failed
    # asset's Gantt lane beyond the actual failure time.
    swaps = try hot_swap_assets() catch; Dict{Any,Any}() end
    for rid in keys(swaps)
        get!(MONITOR_HANDOFF_T, rid, sim_t)
    end
    for v in env.cache.active_set
        haskey(MONITOR_NODE_T, v) && continue
        node = get_node(env.sched, v).node
        kind = _mon_gantt_kind(node)
        isempty(kind) && continue
        MONITOR_NODE_T[v] = Dict{String,Any}(
            "t0"=>sim_t, "t1"=>nothing, "kind"=>kind,
            "label"=>_mon_action(node),
            "robots"=>String[string(r) for r in _mon_actors(node, env)])
    end
    for v in env.cache.closed_set
        entry = get(MONITOR_NODE_T, v, nothing)
        entry !== nothing && entry["t1"] === nothing && (entry["t1"] = sim_t)
    end
    return nothing
end

# ---- 어셈블리 트리 스냅샷 (LDraw 계층 + 상태) --------------------------------
function _mon_assemblies(env)
    st   = env.scene_tree
    asms = [n for n in get_nodes(st) if matches_template(AssemblyNode, n)]
    asm_ids = Set(node_id(a) for a in asms)

    # 부모 맵: child id => parent assembly id
    parent = Dict{Any,Any}()
    for a in asms
        aid = node_id(a)
        for cid in keys(assembly_components(a))
            parent[cid] = aid
        end
    end

    closed = env.cache.closed_set
    active = env.cache.active_set

    # 스케줄을 한 번 훑어 (a) 완료된 AssemblyComplete, (b) 어셈블리별 build-step 회계를 모은다.
    #   build-step 진행률 = 닫힌 CloseBuildStep 수 / 전체 CloseBuildStep 수  → 실제 partial progress.
    done      = Set{Any}()             # AssemblyComplete 가 닫힌 assembly id
    bs_total  = Dict{Any,Int}()        # 어셈블리별 build step 총 수
    bs_closed = Dict{Any,Int}()        # 어셈블리별 닫힌 build step 수
    bs_active = Set{Any}()             # 지금 build step 이 열려있는(진행중) assembly id
    for v in 1:nv(env.sched)
        node = get_node(env.sched, v).node
        if node isa AssemblyComplete
            v in closed && push!(done, node_id(node.entity))
        elseif node isa CloseBuildStep
            aid = node_id(node.assembly)
            bs_total[aid] = get(bs_total, aid, 0) + 1
            v in closed && (bs_closed[aid] = get(bs_closed, aid, 0) + 1)
            v in active && push!(bs_active, aid)
        elseif node isa OpenBuildStep
            v in active && push!(bs_active, node_id(node.assembly))
        end
    end

    _level(aid) = begin
        d = 0; cur = aid
        while haskey(parent, cur); cur = parent[cur]; d += 1; d > 32 && break; end
        d
    end

    out = Vector{Any}()
    for a in asms
        aid      = node_id(a)
        component_ids = collect(keys(assembly_components(a)))
        childasm = [c for c in component_ids if c in asm_ids]
        direct_parts = [c for c in component_ids if !(c in asm_ids)]
        tot      = get(bs_total, aid, 0)
        cl       = get(bs_closed, aid, 0)
        isdone   = aid in done
        isopen   = !isdone && (cl > 0 || aid in bs_active) && cl < max(tot, 1)
        # frontier(=eligible): 아직 시작 안 했고(cl==0) 하위 서브어셈블리는 모두 완료 → 착수 가능
        elig     = !isdone && !isopen && cl == 0 &&
                   (!isempty(childasm) && all(c -> c in done, childasm))
        status   = isdone ? "done" : isopen ? "open" : elig ? "eligible" : "blocked"
        prog     = isdone ? 1.0 : (tot > 0 ? cl / tot : (isopen ? 0.5 : 0.0))
        push!(out, Dict{String,Any}(
            "id"       => string(aid),
            "parent"   => haskey(parent, aid) ? string(parent[aid]) : nothing,
            "level"    => _level(aid),
            "status"   => status,
            "frontier" => elig,
            "progress" => _mon_finite(prog),
            "ncomp"    => num_components(a),
            "role"     => !haskey(parent, aid) ? "root assembly" :
                          (isempty(childasm) ? "leaf assembly" : "subassembly"),
            "direct_parts" => length(direct_parts),
            "direct_assemblies" => length(childasm),
            "component_ids" => String[string(c) for c in component_ids],
            "build_steps_total" => tot,
            "build_steps_closed" => cl,
        ))
    end
    sort!(out, by = d -> (d["level"], d["id"]))  # 트리 렌더 편의상 level·id 정렬
    return out
end

# ---- OOD 이벤트 스냅샷 -------------------------------------------------------
function _mon_ood()
    isdefined(@__MODULE__, :ood_truth_log) || return Any[]
    log = try
        ood_truth_log()
    catch
        return Any[]
    end
    out = Vector{Any}()
    for e in log
        truth = e.truth
        kind = truth isa FaultTruth   ? "fault"   :
               truth isa ZoneTruth    ? "zone"    :
               truth isa BatteryTruth ? "battery" :
               truth isa ReformTruth  ? "reform"  : "other"
        d = Dict{String,Any}("at" => _mon_finite(e.at), "kind" => kind, "nl" => e.nl)
        if truth isa FaultTruth
            d["target"] = string(truth.robot)
        elseif truth isa BatteryTruth
            d["target"]    = string(truth.robot)
            d["soc_after"] = _mon_finite(truth.soc_after)
        elseif truth isa ZoneTruth
            d["zone"]     = string(truth.zone)
            d["center"]   = _mon_finite.(truth.center)
            d["radius"]   = _mon_finite(truth.radius)
            d["assembly"] = string(truth.assembly)
        end
        push!(out, d)
    end
    return out
end

# ---- respec 결정 기록(선택) -------------------------------------------------
"""
    monitor_record_respec!(; at, input, candidates, chosen, verdict)

respec 결정 하나를 얕게 기록해 다음 프레임에 실어 보낸다. 모든 값은 JSON 직렬화 가능해야 함.
- input      : Vector/Dict — open_agent_descriptors(env) 등 LLM 입력 grounding
- candidates : Vector{Dict} — 각 후보 macro + surrogate 예측 점수
- chosen     : 선택된 macro 설명(String)
- verdict    : "FEASIBLE" 또는 "REJECT: <reason>"
"""
function monitor_record_respec!(; at, input=nothing, candidates=Any[], chosen=nothing, verdict=nothing)
    decision = Dict{String,Any}(
        "at" => at, "input" => input, "candidates" => candidates,
        "chosen" => chosen, "verdict" => verdict,
    )
    push!(MONITOR_RESPEC_HISTORY, decision)
    MONITOR_RESPEC[] = decision
    return nothing
end

"Record the authoritative verifier/recovery trace for the current respec decision."
function monitor_record_verification!(; status, checks=Any[], execution=nothing, verdict=nothing)
    rs = MONITOR_RESPEC[]
    rs isa AbstractDict || return nothing
    rs["verification"] = Dict{String,Any}(
        "status" => String(status), "checks" => checks, "execution" => execution)
    verdict === nothing || (rs["verdict"] = verdict)
    passed = String(status) == "passed"
    for c in get(rs, "candidates", Any[])
        c isa AbstractDict || continue
        get(c, "chosen", false) && (c["verified"] = passed)
    end
    return nothing
end

# 로봇 고장을 대시보드에 FAULT 로 표시하고 싶을 때 OOD action 안에서 호출.
monitor_record_fault!(rid) = (push!(MONITOR_FAULTED, rid); nothing)
monitor_clear_fault!(rid)  = (delete!(MONITOR_FAULTED, rid); nothing)

# ---- 프레임 방출(메인 훅) ---------------------------------------------------
"""
    monitor_emit!(env, iter; dt=env.dt)

env 의 현재 상태를 JSONL 한 줄로 방출. sim 배치 끝에서 iter(=step counter)와 함께 호출.
스트림이 안 열려 있으면(=monitor_enable! 미호출) 아무것도 안 하고 즉시 반환한다.
"""
function monitor_emit!(env, iter::Integer; dt=nothing)
    if MONITOR_IO[] === nothing
        # ENV["MONITOR_STREAM"] 가 지정돼 있으면 최초 1회 자동 오픈(별도 드라이버 없이 기존 데모에 그대로).
        p = get(ENV, "MONITOR_STREAM", "")
        isempty(p) && return nothing
        monitor_enable!(p)
    end
    io = MONITOR_IO[]
    step_dt = dt === nothing ? env.dt : dt
    sim_t = iter * step_dt
    monitor_track_schedule_step!(env, iter; dt=step_dt)
    swaps = try hot_swap_assets() catch; Dict{Any,Any}() end
    for rid in keys(swaps)
        get!(MONITOR_HANDOFF_T, rid, sim_t)
    end
    swap_by_label = Dict(string(rid) => (swap=info, at=MONITOR_HANDOFF_T[rid]) for (rid, info) in swaps)
    checkout_by_label = Dict(string(info.spare) => (swap=info, at=MONITOR_HANDOFF_T[rid])
                             for (rid, info) in swaps)

    # --- Gantt: 스케줄 정점의 시작/종료 시각을 배치 단위로 누적(활성 진입=t0, 완료=t1) ---
    for v in env.cache.active_set
        haskey(MONITOR_NODE_T, v) && continue
        node = get_node(env.sched, v).node
        kind = _mon_gantt_kind(node)
        isempty(kind) && continue
        MONITOR_NODE_T[v] = Dict{String,Any}(
            "t0" => sim_t, "t1" => nothing, "kind" => kind,
            "label" => _mon_action(node),
            "robots" => String[string(r) for r in _mon_actors(node, env)],
        )
    end
    for v in env.cache.closed_set
        e = get(MONITOR_NODE_T, v, nothing)
        e !== nothing && e["t1"] === nothing && (e["t1"] = sim_t)
    end
    sched_rows = Vector{Any}()
    for (_, e) in MONITOR_NODE_T
        isempty(e["robots"]) && continue
        t1 = e["t1"] === nothing ? sim_t : e["t1"]
        for r in e["robots"]
            handoff = get(swap_by_label, r, nothing)
            checkout = get(checkout_by_label, r, nothing)
            if handoff === nothing && checkout === nothing
                push!(sched_rows, Dict{String,Any}(
                    "robot" => r, "kind" => e["kind"], "label" => e["label"],
                    "t0" => _mon_finite(e["t0"]), "t1" => _mon_finite(t1)))
            elseif checkout !== nothing
                # The depot spare's own standby/parking task ends when its
                # physical body is checked out. Do not let that obsolete lane
                # continue alongside its new replacement work.
                ht = checkout.at
                if e["t0"] < ht
                    push!(sched_rows, Dict{String,Any}(
                        "robot" => r, "kind" => e["kind"],
                        "label" => "depot standby until handoff",
                        "t0" => _mon_finite(e["t0"]),
                        "t1" => _mon_finite(min(t1, ht))))
                end
            else
                ht = handoff.at
                if e["t0"] < ht
                    push!(sched_rows, Dict{String,Any}(
                        "robot" => r, "kind" => e["kind"], "label" => e["label"],
                        "t0" => _mon_finite(e["t0"]), "t1" => _mon_finite(min(t1, ht))))
                end
                if t1 > ht
                    push!(sched_rows, Dict{String,Any}(
                        "robot" => string(handoff.swap.spare), "kind" => e["kind"],
                        "label" => "replacement for $(r) · $(e["label"])",
                        "t0" => _mon_finite(max(e["t0"], ht)), "t1" => _mon_finite(t1)))
                end
            end
        end
    end

    frame = Dict{String,Any}(
        "t"          => iter,
        "sim_t"      => _mon_finite(sim_t),
        "now"        => _mon_finite(sim_t),
        "n_closed"   => length(env.cache.closed_set),
        "n_active"   => length(env.cache.active_set),
        "robots"     => _mon_robots(env),
        "assemblies" => _mon_assemblies(env),
        "schedule"   => sched_rows,
        "ood"        => _mon_ood(),
        "respec"     => MONITOR_RESPEC[],
        "respec_history" => copy(MONITOR_RESPEC_HISTORY),
        "handoffs"   => [Dict("failed"=>string(rid), "spare"=>string(info.spare),
                              "at"=>MONITOR_HANDOFF_T[rid], "failed_soc"=>info.failed_soc)
                         for (rid, info) in swaps],
    )
    fleet = _mon_fleet()
    if fleet !== nothing && !isempty(fleet.soc)
        socs = collect(values(fleet.soc))
        frame["battery"] = Dict{String,Any}(
            "min_soc"    => _mon_finite(minimum(socs)),
            "mean_soc"   => _mon_finite(sum(socs) / length(socs)),
            "n_depleted" => length(fleet.depleted),
        )
    end
    println(io, JSON3.write(frame))
    flush(io)
    return nothing
end
# Optional live control-plane seam. Commands are consumed between simulation
# batches on the simulation thread, avoiding planner/MeshCat data races.
const MONITOR_CONTROL_HOOK = Ref{Union{Nothing,Function}}(nothing)
monitor_set_control_hook!(f::Function) = (MONITOR_CONTROL_HOOK[] = f)
monitor_clear_control_hook!() = (MONITOR_CONTROL_HOOK[] = nothing)
function monitor_control_step!(env, factory_vis, anim, iter::Integer)
    f = MONITOR_CONTROL_HOOK[]
    f === nothing || f(env, factory_vis, anim, iter)
    return nothing
end
