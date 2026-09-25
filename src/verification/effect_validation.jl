# =============================================================================
# effect_validation.jl — 실제 diff·감사 trace 에서 효과를 분류하고 검사한다(T5). 설계 §6.1–6.3·§8.
#
# 🔴 CB 없이 로드된다(T4 validator 처럼 생성 코드를 싣는 프로세스와 다른 프로세스에서 JSON 만 읽는다).
# 입력은 셋 다 신뢰 하니스 코드(worker 안)가 쓴 **고정 code-free export** 다:
#   * `before` / `after` — `TaskContract.task_state` (도구 호출 직전 / 반환 직후).
#   * `trace` — 도구 실행 중 신뢰 감사 경로가 찍은 스냅샷 열. 사건 종류:
#       `action_start` · `pre_step` · `post_step` · `action_end` (+ `preflight_stop`).
#     `pre_step→post_step` 한 쌍 = trusted engine adapter 가 중재한 **engine 구간**(시계 +1 · 로봇 이동 · closed 증가 허용).
#     그 밖의 연속 두 사건 사이 = **코드 구간**(도구 body 가 세계를 직접 만진 구간 — 시계·로봇 자세·closed 가 그대로여야
#     하고, 자원은 보존 규칙을 지켜야 한다). trace 가 없으면 `[action_start=before, action_end=after]` 하나의 코드 구간.
#   * `audit` — T4 worker 의 감사(`fields_changed_by_action`·`methods_changed_by_action`, 선택 `opaque_added`).
#
# 🔴 분류는 `claimed_effects` 를 **읽지 않는다** — 코드 구간의 실제 diff 에서 유도한다. 효과 목록은 검사 adapter 의
#    초기 inventory 이지 생성 메뉴가 아니다: 모르는 변경은 기하로 바꿔 넣지 않고 `unsupported` 로 남긴다.
# 🔴 못 보는 것(그래서 enforce 는 열리지 않는다): 코드 구간 **안에서** 바꿨다 되돌린 변경(스냅샷 사이에 engine step 이
#    없으면 흔적이 없다 — 존을 지웠다 복원해도 그 사이 step 이 없으면 보이지 않는다), 한 스텝 안의 변경, export 위조.
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))
isdefined(Main, :TaskContract) || include(joinpath(@__DIR__, "task_contract.jl"))

module EffectValidation

import ..RepairTypes as R
import ..TaskContract as TC

const EFFECT_VALIDATOR_VERSION = "effect-validator/1"
"""
모든 효과 판정에 붙는 관측 경계(기계 판독). accept 여도 이 항목은 **보장하지 않는다** — T7 은 이 목록을 보고 완전 검사된
accept 와 구분한다. 판정마다 조건부 항목이 더해진다(`cache_only_fields:` · `derived_plan_after_last_engine_step:`).
"""
const UNOBSERVED_ALWAYS = [
    "intra_segment_change_and_undo: a change reverted between two consecutive trace snapshots leaves no trace",
    "intra_engine_step_changes: only step boundaries are snapshotted",
    "worker_export_forgery: task_state/audit are written inside the worker process",
    "methods_outside_audited_modules: overrides in Base or unaudited modules are not in methods_changed_by_action"]
const TRACE_KINDS = ("action_start", "pre_step", "post_step", "action_end", "preflight_stop")
"본체 교체 사건(스페어 본체를 소모한다). `:battery_swap` 은 같은 본체다(asset_ledger.jl)."
const BODY_EVENTS = ("asset_replacement", "tow_replacement")

# ---- T4 감사 필드의 처리 ----------------------------------------------------------------------
_g(n) = "globals.ConstructionBots.$(n)"
"""
의미가 `task_state` 절로 export 되는 필드(분류는 그 절의 diff 가 한다). `env.sched` 는 로봇·운반 유닛·부품 씬 노드를
**별칭으로** 품는다(RobotStart/FTU 의 entity — 실측: hot swap 의 `_rehome_robot!` 가 `env.sched.nodes[i].node.entity.geom.parent`
행만 바꿨다) — 그래서 그 절들도 `env.sched` 의 설명이 된다.
"""
const SEMANTIC_FIELDS = Dict(
    "env.sched" => ("nodes", "edges", "poses", "robot_poses", "specs", "team_slots", "wedge_edges", "robots", "tus", "scene", "components"),
    "env.scene_tree" => ("scene", "components", "robots", "tus"),
    "env.staging_circles" => ("staging",), _g("RESTRICTION_ZONES") => ("zones",), _g("SPARE_POOLS") => ("resources",),
    _g("BATTERY_DELIVERIES") => ("resources",), _g("BATTERY_FLEET") => ("resources",), _g("ASSET_LEDGER") => ("resources",),
    _g("FAULTED_ROBOTS") => ("resources",), _g("STALLED_ROBOTS") => ("resources",), _g("STANDING_CARGO_BANS") => ("resources",),
    _g("WEDGE_EDGES") => ("wedge_edges",), _g("SIM_STEP") => ("clock",))
"""
파생 **계획**(주행 정책·staging 완충). 현재 세계에서 계산되는 값이라, engine step 없이 코드가 바꿨다면 그것이 **어떤 세계에서**
계산됐는지 diff 로 알 수 없다 — 존을 잠깐 지우고 정책을 다시 계산한 뒤 복원하면 끝 상태는 같고 정책만 남는다(설계 §6.1:
diff 만으로 일시적 존 제거를 잡았다고 하지 않는다). 그래서 `:accept` 로 접지 않고 `:unsupported`(검증 불가) 로 표시한다.
"""
const DERIVED_PLAN_FIELDS = Set(["env.agent_policies", "env.staging_buffers"])
"다른 효과의 부수 장부·파생 캐시. 이것만 바뀌었으면 효과 `:other`."
const BOOKKEEPING_FIELDS = Set(vcat(["env.cache", "env.agent_parent_build_step_active",
    "env.active_build_steps", "env.max_cargo_id", "env.max_robot_go_id"],
    _g.(["VALID_ID_COUNTERS", "INVALID_ID_COUNTERS", "_CACHE_TIMESTAMP_COUNTER", "RECOVERY_SPARES", "CHECKED_OUT_SPARES",
         "HOT_SWAP_ASSETS", "DECOMMISSIONED_BODIES", "INPLACE_BREAKDOWN_MARKS", "DISSOLVED_GATES", "LAST_AUTO_EFFICIENCY_W",
         "LAST_CARGO_BAN_ROWS", "LAST_EDGE_COSTS", "LAST_ENACT_REPORT", "ENACT_ORDER_LOG", "RESOLVE_CALLS",
         "PRIMITIVE_RESUMES_CACHE", "CARRIER_LAST_D", "SNAP_COUNT", "ZONE_SNAP_STATS", "RVO_SIM_WRAPPER", "RVO_ID_GLOBAL_MAP",
         "SPARE_SLOTS", "OOD_TRUTH_LOG", "MONITOR_FAULTED", "MONITOR_HANDOFF_T", "MONITOR_NODE_T", "MONITOR_RECOVERY_LOG",
         "MONITOR_RESPEC", "MONITOR_RESPEC_HISTORY", "_IDENTITY_SEEN", "_VIS_FRAME", "_DRAWN_DECOMMISSIONED",
         "_DRAWN_DEPOT_MARKERS", "_DRAWN_INPLACE_MARKS", "_DRAWN_ZONE_MARKERS", "_BATTERY_SWAP_FRAME",
         "_BATTERY_TINT_FRAMES", "_COURIER_TINT_FRAMES"])))
"하니스(등록)의 변경 — 도구 효과가 아니다. no-op 판정에서도 뺀다. 기본 RNG 는 런타임이 소비하지 않는다(T3 실측)."
const HARNESS_FIELDS = Set(["rng.default", _g("_MINTED_EVER"), _g("_MINTED_TABLE")])
"""
관측 부작용: 읽기만 해도 바뀐다(실측: `zone_blockage` 한 번 → `_CACHE_TIMESTAMP_COUNTER` + `env.sched` 의 변환 캐시
`global_transform.is_up_to_date` 행). 캐시 논리 시계는 캐시 갱신 순서만 정한다(가정 — 보고서 우려). no-op 판정에서 뺀다.
"""
const OBSERVATION_FIELDS = Set([_g("_CACHE_TIMESTAMP_COUNTER")])
"""
변환 캐시(`CachedElement`)를 품는 필드. export 된 절이 하나도 안 바뀌었는데 이 필드만 바뀌었으면 **캐시 갱신**으로 본다 —
필드 단위 감사로는 캐시와 export 밖 의미 필드를 가를 수 없다(보고서 "검증 불가" 절). 그 밖의 의미 필드는 설명이 없으면
unsupported 다.
"""
const LAZY_CACHE_FIELDS = Set(["env.sched", "env.scene_tree"])
"지속 callback 을 심는 자리 — 재현·효과 관측 불가 → unsupported(설계 §6.1)."
const HOOK_FIELDS = Set(_g.(["BATTERY_STEP_HOOK", "DRAIN_FACTOR_HOOK", "SOC_SPEED_HOOK", "STALL_PROBE_HOOK", "MONITOR_CONTROL_HOOK"]))
"보호: 존 복구 base ablation · 사건/정책 latch · 물리 · 검사기/채점표 · 공통 continuation 정책 손잡이 · 실행 ENV · 하니스."
const PROTECTED_FIELDS = Set(vcat(["globals.Base.ENV", "env.dt", "fingerprints", "task_contract", "loop_state"],
    _g.(["REPAIR_ABLATION", "_ABLATION_ARMED", "_ABLATION_COUNTS", "_ABLATION_EXEMPT_DEPTH", "_ABLATE_ALL",
         "_ABLATE_TRANSLATE", "_ABLATION_MACHINERY",
         "RESPEC_HOLD", "RESPEC_ENABLED", "RESPEC_FROZEN", "RESPEC_PINNED", "RESPEC_PRODUCER", "RESPEC_QUEUE",
         "OOD_SCHEDULE", "OOD_EVENT_TARGET", "RESPEC_DRIFT_REPAIR", "UNWEDGE_INTERVAL",
         "RVO_MAX_SPEED", "RVO_MIN_MAX_SPEED", "RVO_MAX_SPEED_VOLUME_FACTOR", "RVO_DEFAULT_TIME_STEP",
         "RVO_DEFAULT_NEIGHBOR_DISTANCE", "RVO_DEFAULT_MIN_NEIGHBOR_DISTANCE", "RVO_DEFAULT_NEIGHBORHOOD_VELOCITY_SCALE_FACTOR",
         "LOADING_SPEED", "ROTATIONAL_LOADING_SPEED", "ROBOT_RADIUS", "DEFAULT_ROBOT_GEOM", "USE_RVO",
         "BATTERY_ACCOUNTING", "BATTERY_DERATE", "BATTERY_PENALTY", "BATTERY_STALL", "ENERGY_MODEL", "STALL_SOC_DEFAULT",
         "REPLACE_SOC_THRESHOLD", "BATTERY_COURIER_CFG", "HOT_SWAP_MODE", "HOT_SWAP_REPLACE",
         "ALIGNMENT_CHECK_TOLERANCE", "CAPTURE_DISTANCE_TOLERANCE", "CAPTURE_ROTATION_TOLERANCE", "IDENTITY_CHECK",
         "IDENTITY_CHECK_EVERY", "IDENTITY_STRICT", "SILENT_SUCCESS_STATUSES", "UNMEASURABLE_STATUSES",
         "WORLD_UNCHANGED_STATUSES", "ZONE_DOMAIN_GATE", "RELOCATE_GATE",
         "AGENT_COST_BIAS", "AUTO_EFFICIENCY_KAPPA", "AVOID_STAGING_AREAS", "DEPRIORITIZE_KAPPA", "EDGE_COST_MULTIPLIER",
         "EDGE_PAYLOAD_MULTIPLIER", "GREEDY_ENERGY_W", "PAYLOAD_BIAS", "PLANNING_OBJECTIVE_WEIGHTS", "MILP_OPTIMIZER",
         "DEFAULT_MILP_OPTIMIZER_ATTRIBUTES", "DEFAULT_GEOM_OPTIMIZER", "DEFAULT_GEOM_OPTIMIZER_ATTRIBUTES",
         "STAGING_BUFFER_RADIUS", "SPARE_DEPOT_DISTANCE", "SPARE_POOL_CENTERS", "SPARE_POOL_MARGIN_FACTOR", "DEPOT_INFO",
         "MONITOR_IO"])))

# ---- 입력 형태 (worker 가 쓴 파일 = 적대적 입력) ------------------------------------------------
const _STATE_KEYS = ("schema", "nodes", "edges", "closed", "poses", "scene", "components", "robots", "rvo",
                     "staging", "zones", "resources", "clock")
struct MalformedExport <: Exception
    msg::String
end
_need(ok, msg) = ok || throw(MalformedExport(msg))
function _check_state(s, what)
    _need(s isa AbstractDict, "$(what) is not an object")
    _need(get(s, "schema", nothing) == TC.TASK_STATE_SCHEMA, "$(what).schema != $(TC.TASK_STATE_SCHEMA)")
    for k in _STATE_KEYS; _need(haskey(s, k), "$(what) missing $(k)"); end
    for k in ("nodes", "poses", "scene", "components", "robots", "rvo", "staging", "zones", "resources", "clock")
        _need(s[k] isa AbstractDict, "$(what).$(k) is not an object")
    end
    for k in ("edges", "closed"); _need(s[k] isa AbstractVector, "$(what).$(k) is not an array"); end
    for e in s["edges"]; _need(e isa AbstractVector && length(e) == 2 && all(x -> x isa AbstractString, e), "$(what).edges entry"); end
    r = s["resources"]
    for k in ("pools", "soc", "energy_J", "deliveries"); _need(get(r, k, nothing) isa AbstractDict, "$(what).resources.$(k)"); end
    for k in ("ledger", "faulted", "stalled", "cargo_bans"); _need(get(r, k, nothing) isa AbstractVector, "$(what).resources.$(k)"); end
    _need(get(s["clock"], "sim_step", nothing) isa Integer, "$(what).clock.sim_step")
    return nothing
end

# ---- 코드 구간 검사와 분류 ----------------------------------------------------------------------
_ledger_new(a, b) = b["resources"]["ledger"][length(a["resources"]["ledger"])+1:end]
_poolset(s) = Set{String}(String(r) for v in values(s["resources"]["pools"]) for r in v)
_isassign(s, id) = get(s["nodes"], id, "") in TC.ASSIGNMENT_TYPES
_iscon(s, id) = get(s["nodes"], id, "") in TC.CONSTRUCTION_TYPES
_edgeset(s, pred) = Set{Tuple{String,String}}((String(e[1]), String(e[2])) for e in s["edges"] if pred(String(e[1]), String(e[2])))

"""
    code_segment!(V, classes, a, b, tag)

도구가 세계를 **직접** 만진 구간 a→b. 위반은 `V` 에, 실제 변경의 효과 종류는 `classes` 에.
"""
function code_segment!(V, classes, a, b, tag)
    # 시계: 코드 구간에서는 한 칸도 움직이면 안 된다(진행은 adapter 만).
    for k in union(keys(a["clock"]), keys(b["clock"]))
        get(a["clock"], k, nothing) == get(b["clock"], k, nothing) || push!(V, "clock_manipulation:$(k)@$(tag)")
    end
    new_rows = _ledger_new(a, b)
    ra, rb = a["resources"], b["resources"]
    # 원장은 append-only. 새 행의 role 에 한해 열린 행의 t_out 을 닫는 것만 허용(record_asset_swap! 이 그렇게 한다).
    la, lb = ra["ledger"], rb["ledger"]
    new_roles = Set{String}(String(r["role"]) for r in new_rows)
    if length(lb) < length(la)
        push!(V, "resource_forgery:ledger_truncated@$(tag)")
    else
        for (x, y) in zip(la, lb)
            same = all(k -> get(x, k, nothing) == get(y, k, nothing), ("role", "asset", "event", "t_in"))
            (same && (get(x, "t_out", nothing) == get(y, "t_out", nothing) ||
                      (get(x, "t_out", nothing) === nothing && String(x["role"]) in new_roles))) ||
                push!(V, "resource_forgery:ledger_rewritten:$(get(x, "role", "?"))@$(tag)")
        end
    end
    pa, pb = _poolset(a), _poolset(b)
    for r in setdiff(pb, pa); push!(V, "resource_forgery:spare_created:$(r)@$(tag)"); end
    consumed = setdiff(pa, pb)
    body_roles, body_assets = Set{String}(), Set{String}()
    for r in new_rows
        ev = String(r["event"])
        if ev in BODY_EVENTS
            String(r["asset"]) in consumed || push!(V, "resource_forgery:body_replacement_without_spare:$(r["role"])@$(tag)")
            push!(body_roles, String(r["role"])); push!(body_assets, String(r["asset"]))
        end
    end
    # 로봇: 생성·삭제 금지, 코드 구간의 자세 변화는 본체 교체(스페어 소모가 원장에 있는)로만 설명된다.
    ka, kb = Set(keys(a["robots"])), Set(keys(b["robots"]))
    for r in setdiff(kb, ka); push!(V, "resource_forgery:robot_created:$(r)@$(tag)"); end
    for r in setdiff(ka, kb); push!(V, "resource_forgery:robot_removed:$(r)@$(tag)"); end
    moved = String[]
    for r in intersect(ka, kb)
        (TC.posediff(a["robots"][r], b["robots"][r]) == 0 &&
         get(a["rvo"], r, nothing) == get(b["rvo"], r, nothing)) || push!(moved, String(r))
    end
    for r in moved
        r in body_roles || r in body_assets || push!(V, "robot_teleport:$(r)@$(tag)")
    end
    # 배터리: SoC 상승은 그 로봇의 원장 행(교체 사건)이 있어야 한다; 코드 구간의 SoC 하락·에너지 누계 감소도 위반.
    for (r, x) in rb["soc"]
        x0 = get(ra["soc"], r, nothing)
        x0 === nothing && continue
        x > x0 && !(String(r) in new_roles) && push!(V, "resource_forgery:battery_soc:$(r)@$(tag)")
        x < x0 && push!(V, "resource_changed_without_engine:battery_soc_decreased:$(r)@$(tag)")
    end
    for (r, x) in ra["energy_J"]
        y = get(rb["energy_J"], r, nothing)
        y !== nothing && y < x && push!(V, "cost_evasion:energy_J:$(r)@$(tag)")
    end
    # 배송(자원 작업 요청): 기존 배송 변조 금지, 새 배송은 outbound·풀의 스페어·실존 대상·현재 시각에서 출발.
    da, db = ra["deliveries"], rb["deliveries"]
    for (c, d) in da
        haskey(db, c) && db[c] != d && push!(V, "resource_forgery:delivery_tampered:$(c)@$(tag)")
    end
    for (c, d) in db
        haskey(da, c) && continue
        ok = get(d, "phase", "") == "outbound" && String(c) in pa && String(get(d, "target", "")) in ka &&
             get(d, "step_out", nothing) == a["clock"]["sim_step"]
        ok || push!(V, "resource_forgery:delivery_invalid:$(c)@$(tag)")
    end
    # 건강 상태: 해제(고장·정지·화물 금지 풀기)는 그 로봇의 원장 행이 있어야 한다. 새로 거는 것은 허용.
    for k in ("faulted", "stalled", "cargo_bans")
        for r in setdiff(Set{String}(String.(ra[k])), Set{String}(String.(rb[k])))
            r in new_roles || push!(V, "status_forgery:$(k)_cleared:$(r)@$(tag)")
        end
    end
    # closed: 코드가 건설 노드를 닫거나 무엇이든 다시 여는 것은 완료 위조. 배정 노드(RobotGo)를 닫는 것은 그 노드가
    # 더는 미완 건설 작업을 막지 않을 때만(replace_robot! 의 "parking" — 인계 뒤 고장 로봇의 남은 RobotGo).
    ca, cb = Set{String}(String.(a["closed"])), Set{String}(String.(b["closed"]))
    for id in setdiff(ca, cb); push!(V, "status_forgery:reopened:$(id)@$(tag)"); end
    newc = setdiff(cb, ca)
    for id in newc
        if _iscon(b, id)
            push!(V, "status_forgery:closed:$(id)@$(tag)")
        elseif _isassign(b, id)
            gating = any(e -> String(e[1]) == id && _iscon(b, String(e[2])) && !(String(e[2]) in cb), b["edges"])
            gating && push!(V, "status_forgery:assignment_closed_while_gating:$(id)@$(tag)")
        else
            push!(V, "status_forgery:closed_unknown_node:$(id)@$(tag)")
        end
    end
    # ---- 분류(실제 변경에서) ----
    (a["poses"] != b["poses"] || a["scene"] != b["scene"] || a["staging"] != b["staging"] ||
     a["components"] != b["components"] || get(a, "tus", nothing) != get(b, "tus", nothing)) && push!(classes, :geometry)
    asg(s) = _edgeset(s, (u, v) -> _isassign(s, u) || _isassign(s, v))
    con(s) = _edgeset(s, (u, v) -> _iscon(s, u) && _iscon(s, v))
    nodes_of(s, pred) = Set(k for (k, t) in s["nodes"] if pred(t))
    (asg(a) != asg(b) || nodes_of(a, t -> t in TC.ASSIGNMENT_TYPES) != nodes_of(b, t -> t in TC.ASSIGNMENT_TYPES) ||
     get(a, "robot_poses", nothing) != get(b, "robot_poses", nothing) ||
     any(id -> _isassign(b, id), newc)) && push!(classes, :assignment)
    (con(a) != con(b) || get(a, "wedge_edges", nothing) != get(b, "wedge_edges", nothing) ||
     get(a, "specs", nothing) != get(b, "specs", nothing) ||
     nodes_of(a, t -> t in TC.CONSTRUCTION_TYPES) != nodes_of(b, t -> t in TC.CONSTRUCTION_TYPES)) && push!(classes, :schedule_graph)
    ra != rb && push!(classes, :resource)
    return nothing
end

"""
engine 구간(adapter 가 한 스텝 굴렸다): 시계가 정확히 한 칸 전진해야 한다. 나머지는 engine 이 한 일이라 신뢰한다.
T6 adapter 의 trace 는 루프 반복 수 `iter` 를 `clock` 에 싣는다 — 그러면 규칙은 "`iter` 가 +1, 그 반복이 `SIM_STEP = iter` 로
맞췄다" 이다(`ood_inject_step!` 가 매 반복 `set_sim_step!(iter)`). 🔴 `SIM_STEP` +1 만 보면 에피소드 첫 반복에서 production
자신이 걸린다: t0 = iter 1 에서 `SIM_STEP` 은 아직 0 이고 첫 반복이 2 로 맞춘다(T6 tractor worker 실측 `0->2`).
"""
function engine_segment!(V, a, b, tag)
    ca, cb = a["clock"], b["clock"]
    if haskey(ca, "iter") && haskey(cb, "iter")
        (cb["iter"] == ca["iter"] + 1 && cb["sim_step"] == cb["iter"]) ||
            push!(V, "engine_step_clock_mismatch:iter $(ca["iter"])->$(cb["iter"]) sim_step $(ca["sim_step"])->$(cb["sim_step"])@$(tag)")
    else
        cb["sim_step"] == ca["sim_step"] + 1 ||
            push!(V, "engine_step_clock_mismatch:$(ca["sim_step"])->$(cb["sim_step"])@$(tag)")
    end
    return nothing
end

"""
    validate_effects(contract, before, after; audit, trace=nothing, proposal_id=nothing)
        -> (; report::RepairTypes.ValidationReport, classes, findings)

판정 우선순위: 위반 → `:reject` · 범위 밖 → `:unsupported` · preflight 가 첫 engine 진행 앞에서 멈춤 → `:requires_runtime` ·
상태·예약 작업·효과 trace 가 모두 없음 → `:noop_equivalent` · 그 밖 → `:accept`(효과 종류 포함).
worker 가 쓴 입력이 깨져 있으면 던지지 않고 `:certification_unavailable`(`malformed_export:`), 신뢰 쪽 자신의 예외는
같은 판정에 **다른 사유**(`validator_error:`) — 처방이 다르다(앞은 후보를, 뒤는 검증기를 고친다).
"""
function validate_effects(contract::AbstractDict, before, after; audit, trace = nothing, proposal_id = nothing)
    try
        _check_state(before, "before"); _check_state(after, "after")
        _need(audit isa AbstractDict, "audit is not an object")
        tr = trace === nothing ?
            Any[Dict{String,Any}("kind" => "action_start", "state" => before), Dict{String,Any}("kind" => "action_end", "state" => after)] : trace
        _need(tr isa AbstractVector && length(tr) >= 2, "trace needs at least action_start and a last event")
        for (i, e) in enumerate(tr)
            _need(e isa AbstractDict && get(e, "kind", nothing) isa AbstractString, "trace[$(i)] malformed")
            e["kind"] in TRACE_KINDS && _check_state(e["state"], "trace[$(i)].state")
        end
        _need(tr[1]["kind"] == "action_start" && TC.digest(tr[1]["state"]) == TC.digest(before), "trace does not start at `before`")
        _need(tr[end]["kind"] in ("action_end", "preflight_stop") && TC.digest(tr[end]["state"]) == TC.digest(after),
              "trace does not end at `after`")
    catch e
        e isa MalformedExport || rethrow()
        return _result(:certification_unavailable, ["malformed_export: " * e.msg], proposal_id, Symbol[],
                       Dict{String,Any}("unobserved" => copy(UNOBSERVED_ALWAYS)))
    end
    try
        return _validate(contract, before, after, audit, trace === nothing ?
            Any[Dict{String,Any}("kind" => "action_start", "state" => before), Dict{String,Any}("kind" => "action_end", "state" => after)] :
            trace, proposal_id)
    catch e
        e isa InterruptException && rethrow()
        return _result(:certification_unavailable, ["validator_error: " * first(sprint(showerror, e), 300)], proposal_id,
                       Symbol[], Dict{String,Any}("unobserved" => copy(UNOBSERVED_ALWAYS)))
    end
end

function _result(verdict, reasons, pid, classes, findings; adapter = Symbol[])
    rep = R.ValidationReport(:effects, verdict, pid, verdict === :accept ? String[] : reasons, EFFECT_VALIDATOR_VERSION,
                             classes, adapter, String.(get(findings, "unobserved", UNOBSERVED_ALWAYS)))
    return (; report = rep, classes, findings)
end

function _validate(contract, before, after, audit, tr, pid)
    V, U = String[], String[]
    classes = Set{Symbol}()
    n_engine = 0
    preflight = false
    for i in 1:length(tr)-1
        a, b = tr[i], tr[i+1]
        ka, kb = String(a["kind"]), String(b["kind"])
        kb in TRACE_KINDS || (push!(U, "unsupported_trace_event:$(kb)@$(i+1)"); continue)
        ka in TRACE_KINDS || continue
        tag = "seg$(i):$(ka)->$(kb)"
        if ka == "pre_step" && kb == "post_step"
            engine_segment!(V, a["state"], b["state"], tag); n_engine += 1
        elseif ka in ("action_start", "post_step") && kb in ("pre_step", "action_end", "preflight_stop")
            code_segment!(V, classes, a["state"], b["state"], tag)
            kb == "preflight_stop" && (preflight = true)
        else
            push!(V, "trace_order_invalid:$(tag)")
        end
    end
    # 보호 의미는 **모든** 스냅샷에서 성립해야 한다 — 중간에만 깨졌다 되돌린 것(존을 지우고 한 스텝 굴린 뒤 복원)은
    # 끝 상태 diff 로는 안 보이고 여기서만 보인다.
    for (i, e) in enumerate(tr)
        i == length(tr) && break
        String(e["kind"]) in TRACE_KINDS || continue
        r = TC.evaluate_task_contract(contract, e["state"])
        for v in r.violations; push!(V, "transient_protected_violation:$(v)@$(i):$(e["kind"])"); end
    end
    rc = TC.evaluate_task_contract(contract, after)
    append!(V, rc.violations); append!(U, rc.unsupported)
    # 감사 필드: 보호 → 거절, hook → unsupported(지속 callback), 모르는 필드 → unsupported, export 된 절이 안 바뀌었는데
    # 필드만 바뀐 것 → unsupported(export 가 못 보는 변경).
    fields = String.(get(audit, "fields_changed_by_action", String[]))
    methods = String.(get(audit, "methods_changed_by_action", String[]))
    isempty(methods) || push!(V, "runtime_override:" * join(methods, ","))
    for o in String.(get(audit, "opaque_added", String[])); push!(U, "unsupported_effect:persistent_callback:$(o)"); end
    changed_sections = Set{String}(k for k in keys(before) if get(before, k, nothing) != get(after, k, nothing))
    other = false
    unexported = String[]
    unobserved = copy(UNOBSERVED_ALWAYS)
    for f in fields
        if f in HARNESS_FIELDS || f in OBSERVATION_FIELDS
        elseif f in DERIVED_PLAN_FIELDS
            # engine step 이 없었으면 이 계획은 도구 코드가 계산했다 — 무슨 세계에서였는지 볼 수 없다.
            n_engine == 0 ? push!(U, "unverifiable:derived_plan_changed_without_engine:$(f)") :
                            push!(unobserved, "derived_plan_after_last_engine_step:$(f)")
        elseif f in PROTECTED_FIELDS
            push!(V, "protected_global_changed:$(f)")
        elseif f in HOOK_FIELDS
            push!(U, "unsupported_effect:persistent_callback:$(f)")
        elseif haskey(SEMANTIC_FIELDS, f)
            (any(s -> s in changed_sections, SEMANTIC_FIELDS[f]) || n_engine > 0) ||
                (f in LAZY_CACHE_FIELDS ? push!(unexported, f) : push!(U, "unsupported_effect:unexported_change:$(f)"))
        elseif f in BOOKKEEPING_FIELDS
            other = true
        else
            push!(U, "unsupported_effect:field:$(f)")
        end
    end
    other && isempty(classes) && push!(classes, :other)
    isempty(unexported) || push!(unobserved, "cache_only_fields: " * join(unexported, ","))
    cls = [c for c in R.EFFECT_CLASSES if c in classes]
    adapter = n_engine > 0 ? [:step_environment!] : Symbol[]
    findings = Dict{String,Any}("engine_steps" => n_engine, "violations" => V, "unsupported" => U,
                                "notes" => rc.notes, "fields" => fields, "cache_only_changes" => unexported,
                                "unobserved" => unobserved)
    !isempty(V) && return _result(:reject, vcat(V, U), pid, cls, findings; adapter)
    !isempty(U) && return _result(:unsupported, U, pid, cls, findings; adapter)
    preflight && return _result(:requires_runtime, ["requires_runtime: engine progress requested (preflight stopped before it)"],
                                pid, cls, findings; adapter)
    noop = n_engine == 0 && isempty(cls) && TC.digest(before) == TC.digest(after) &&
           all(f -> f in HARNESS_FIELDS || f in OBSERVATION_FIELDS || f in unexported, fields)
    noop && return _result(:noop_equivalent, ["noop_equivalent: no state diff, no scheduled work, no engine progress"],
                           pid, cls, findings)
    isempty(cls) && n_engine == 0 && return _result(:unsupported, ["unsupported_effect:unclassified_change"], pid, cls, findings)
    return _result(:accept, String[], pid, cls, findings; adapter)
end

end # module EffectValidation
