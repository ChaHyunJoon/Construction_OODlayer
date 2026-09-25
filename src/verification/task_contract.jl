# =============================================================================
# task_contract.jl — 원본 작업 계약(T5). 설계 §4.2·§6.1·§6.3, 정보 흐름 §3.
#
# 두 쪽이 한 파일에 있고 **로드에 ConstructionBots 가 필요 없다**:
#   * CB 쪽(신뢰 하니스 코드, 생성 코드가 돌기 **전**): `task_state(env, CB)` — 세계를 고정 code-free JSON 으로
#     편다. `derive_task_contract(env, CB; checkpoint_id)` — t0(또는 그 전)의 세계에서 원본 계약을 만든다.
#     CB 모듈은 **인자**로 받는다 — 이 파일은 `using ConstructionBots` 를 하지 않는다.
#   * 판정 쪽(trusted validator — T4 `BranchRunner` 처럼 CB 를 안 싣는 프로세스): `evaluate_task_contract`
#     `task_contract_report` 는 Dict/Vector/수/문자열만 읽는다. custom deserialize·callback·생성 코드 없음.
#
# 계약이 **무엇에서** 오는가(재사용 — 새로 지어낸 규칙이 아니다):
#   * 필수 작업 = 건설 술어 노드(`CONSTRUCTION_TYPES`). `RobotStart`/`RobotGo` 는 배정 영역이다 —
#     `construction_schedule.jl` 의 `required_predecessors` 표에서 로봇 노드만이 배정(`RobotGo => length(robot_team)`)
#     으로 건설 노드에 붙는다(실측 colored_8x8: 건설↔건설 간선 10종, 로봇 노드가 끼는 간선 4종).
#   * 의미적 선행 = t0 의 건설↔건설 간선 − `WEDGE_EDGES`(replace_robot.jl: spare 직렬화용 **임시** 간선 —
#     `add_edge!` 와 짝으로 기록되므로 `WEDGE_EDGES ⊆ edges`).
#   * 과거 불가침 = t0 의 closed 집합(`respec/verifier.jl` `build_invariant` 와 같은 뜻 — 끝난 일은 되돌리지 않는다).
#   * 조립 관계 = 씬 트리 조립체의 `assembly_components`(부모 기준 상대 변환)와, `validate_schedule_transform_tree
#     (post_staging=true)` 가 단언하는 `LiftIntoPlace.goal == AssemblyComplete.config ∘ child_transform` 관계.
#   * 운반 관계(물리 선행) = 같은 운반 유닛의 `FormTransportUnit → TransportUnitGo → DepositCargo → LiftIntoPlace`
#     사슬에서 한 노드의 끝 자세 = 다음 노드의 시작 자세. 🔴 이것이 goal=start 를 잡는다: `validate_schedule_
#     transform_tree(post_staging=true)` 는 `TUGo.goal == DepositCargo.config` 를 **보지 않는다**(실측: goal=start
#     뒤에도 true) — 그리고 그 세계는 끝까지 완주하며 최종 부품 자세 잔차도 0 이다(colored_8x8 실측). 즉 최종
#     제품 검사만으로는 운반 생략을 못 본다.
#
# 🔴 이 계약은 과거 성공을 지키려고 느슨해지지 않는다. 역사적 body 가 여기서 떨어지면 그것은
#    `historical_complete_but_contract_invalid`(T10 이 기록)다.
# =============================================================================
isdefined(Main, :RepairTypes) || include(joinpath(@__DIR__, "repair_types.jl"))

module TaskContract

using JSON3, SHA
import ..RepairTypes as R

const TASK_STATE_SCHEMA = "task-state/1"
const TASK_CONTRACT_SCHEMA = "task-contract/1"
const TASK_CONTRACT_VALIDATOR_VERSION = "task-contract-validator/1"

"필수 작업(건설 술어). 이 밖의 노드 종류(로봇 노드)는 배정 영역이다."
const CONSTRUCTION_TYPES = ("ObjectStart", "AssemblyStart", "AssemblyComplete", "OpenBuildStep", "CloseBuildStep",
    "FormTransportUnit", "TransportUnitGo", "DepositCargo", "LiftIntoPlace", "ProjectComplete")
const ASSIGNMENT_TYPES = ("RobotStart", "RobotGo")
"자세를 적는 노드 필드(있는 것만). 전역 변환이다."
const POSE_FIELDS = (:config, :start_config, :goal_config, :cargo_start_config, :cargo_goal_config)
"자세 비교 허용 오차(평행이동 m · 회전행렬 원소). t0 실측 차이는 1e-10 수준, 최종 부품 잔차는 0.0."
const DEFAULT_ATOL = 1e-6

# ---- 자세 대수 (CB 없이) -------------------------------------------------------------------
# 자세 = 12 수: [tx,ty,tz, R11,R12,R13,R21,R22,R23,R31,R32,R33] (전역).
_R(p) = [Float64(p[4 + 3(i - 1) + (j - 1)]) for i in 1:3, j in 1:3]
_t(p) = Float64[p[1], p[2], p[3]]
_pose(t, R) = vcat(t, vec(permutedims(R)))
"a ∘ b (b 를 a 의 좌표계에서 적은 것)."
compose(a, b) = _pose(_R(a) * _t(b) .+ _t(a), _R(a) * _R(b))
"inv(a) ∘ b — b 를 a 의 좌표계에서 본 상대 자세."
relpose(a, b) = (Rt = permutedims(_R(a)); _pose(Rt * (_t(b) .- _t(a)), Rt * _R(b)))
posediff(a, b) = maximum(abs.(Float64.(collect(a)) .- Float64.(collect(b))))
close_pose(a, b, atol) = a !== nothing && b !== nothing && length(a) == 12 && length(b) == 12 && posediff(a, b) <= atol

# ---- canonical JSON / digest ---------------------------------------------------------------
"키를 정렬한 JSON 문자열 — 프로세스·Dict 순회 순서와 무관한 digest 용."
canon(x) = x isa AbstractDict ? "{" * join(("$(JSON3.write(string(k))):$(canon(x[k]))" for k in sort!(collect(keys(x)); by = string)), ",") * "}" :
           x isa AbstractVector ? "[" * join((canon(v) for v in x), ",") * "]" : JSON3.write(x)
digest(x) = bytes2hex(sha256(canon(x)))

# =============================================================================
# CB 쪽: 고정 export (신뢰 하니스 코드가 부른다)
# =============================================================================
_s(id) = string(id)
"""
전역 변환을 **캐시를 건드리지 않고** 계산한다. `CB.global_transform` 은 읽기처럼 보이지만 캐시가 낡았으면 다시 계산해
`is_up_to_date`·값·논리 시계(`_CACHE_TIMESTAMP_COUNTER`)를 바꾸고 자식에게 전파한다(`get_cached_value!` →
`propagate_forward!`). 부모(생성 코드 0)가 t0 에서 계약을 유도하는 것이 세계 digest 를 바꾸면 T4 의 부모 `verify` 와
NOOP 궤적 대조가 깨진다 — 그래서 local 변환을 루트까지 합성한다(값은 캐시와 같은 식).
"""
function _pure_global(CB, t)
    p = CB.get_parent(t)
    return p === t ? CB.local_transform(t) : _pure_global(CB, p) ∘ CB.local_transform(t)
end
_gpose(CB, x) = _tf_pose(_pure_global(CB, x isa CB.TransformNode ? x : CB.get_transform_node(x)))
function _tf_pose(tf)
    t = Float64.(collect(tf.translation))
    Rm = hasproperty(tf, :linear) ? Float64.(Matrix(tf.linear)) : [1.0 0 0; 0 1.0 0; 0 0 1.0]
    return _pose(t, Rm)
end

"""
    task_state(env, CB; extra_clock = Dict()) -> Dict{String,Any}

세계의 고정 code-free export(schema `task-state/1`). **읽기만 한다** — 변환 캐시·논리 시계도 안 바꾼다(`_pure_global`;
시험 `[1]` 이 `world_lines` 필드 digest 로 잰다). 키:
`nodes`(id⇒종류) · `edges`([src,dst] id) · `closed`/`active` · `wedge_edges` · `poses`(건설 노드 id⇒필드⇒전역 자세) ·
`robot_poses`(배정 노드 id⇒필드⇒전역 자세) · `specs`(id⇒[min_duration, plan_path, tight, static, free, fixed]) ·
`team_slots`(FormTransportUnit id⇒[팀 안 로봇 자리의 상대 자세]) ·
`scene`(부품·조립체 id⇒전역 자세) · `tus`(운반 유닛 id⇒전역 자세) · `components`(조립체⇒자식⇒상대 자세) · `robots`(id⇒전역 자세) · `rvo`(id⇒[x,y]) ·
`staging`(조립체⇒[cx,cy,r]) · `zones`(key⇒[cx,cy,…,r]) · `resources`(pools·soc·energy_J·deliveries·ledger·faulted·
stalled·cargo_bans) · `clock`(sim_step + `extra_clock`).
"""
function task_state(env, CB::Module; extra_clock::AbstractDict = Dict{String,Any}())
    S = env.sched
    G = CB.Graphs
    vid = Dict{Int,String}()
    nodes, poses, rposes, specs, slots = Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}()
    for v in G.vertices(S)
        n = CB.get_node(S, v)
        id = _s(CB.node_id(n)); vid[v] = id
        p = n.node
        typ = String(nameof(typeof(p)))
        nodes[id] = typ
        sp = n.spec
        specs[id] = Any[Float64(sp.min_duration), sp.plan_path, sp.tight, sp.static, sp.free, sp.fixed]
        d = Dict{String,Any}()
        for f in POSE_FIELDS
            hasfield(typeof(p), f) || continue
            d[String(f)] = _gpose(CB, getfield(p, f))
        end
        (typ in CONSTRUCTION_TYPES ? poses : rposes)[id] = d
        typ == "FormTransportUnit" && (slots[id] = [_tf_pose(tf) for (_, tf) in CB.robot_team(CB.entity(p))])
    end
    edges = sort!([[vid[G.src(e)], vid[G.dst(e)]] for e in G.edges(S)])
    ids(vs) = sort!([vid[v] for v in vs if haskey(vid, v)])
    wedge = isdefined(CB, :WEDGE_EDGES) ?
        sort!([[vid[a], vid[b]] for (a, b) in CB.WEDGE_EDGES[] if haskey(vid, a) && haskey(vid, b)]) : Any[]
    st = env.scene_tree
    scene, comps, robots, rvo, tus = Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}()
    for n in CB.get_nodes(st)
        id = _s(CB.node_id(n))
        if CB.matches_template(CB.RobotNode, n)
            robots[id] = _gpose(CB, n)
            try
                if CB.use_rvo() && CB.Graphs.has_vertex(CB.rvo_global_id_map(), CB.node_id(n))
                    q = CB.rvo_get_agent_position(n); rvo[id] = Float64[q[1], q[2]]
                end
            catch
            end
        elseif CB.matches_template(CB.TransportUnitNode, n)
            tus[id] = _gpose(CB, n)
        elseif CB.matches_template(Union{CB.ObjectNode,CB.AssemblyNode}, n)
            scene[id] = _gpose(CB, n)
            if CB.matches_template(CB.AssemblyNode, n)
                comps[id] = Dict{String,Any}(_s(k) => _tf_pose(tf) for (k, tf) in CB.assembly_components(n))
            end
        end
    end
    staging = Dict{String,Any}(_s(k) => vcat(Float64.(collect(b.center)), Float64(b.radius)) for (k, b) in env.staging_circles)
    zones = Dict{String,Any}(String(k) => vcat(Float64.(collect(b.center)), Float64(b.radius)) for (k, b) in CB.RESTRICTION_ZONES[])
    res = Dict{String,Any}("pools" => Dict{String,Any}(String(k) => [_s(r) for r in v] for (k, v) in CB.SPARE_POOLS[]))
    fleet = isdefined(CB, :BATTERY_FLEET) ? CB.BATTERY_FLEET[] : nothing
    res["soc"] = fleet === nothing ? Dict{String,Any}() : Dict{String,Any}(_s(k) => Float64(v) for (k, v) in fleet.soc)
    res["energy_J"] = fleet === nothing ? Dict{String,Any}() : Dict{String,Any}(_s(k) => Float64(v) for (k, v) in fleet.energy_J)
    res["deliveries"] = Dict{String,Any}(_s(c) => Dict{String,Any}("target" => _s(d.target), "phase" => String(d.phase),
        "depot" => String(d.depot), "step_out" => d.step_out, "step_swap" => d.step_swap) for (c, d) in CB.BATTERY_DELIVERIES[])
    res["ledger"] = [Dict{String,Any}("role" => _s(a.role), "asset" => _s(a.asset), "event" => String(a.event),
        "t_in" => a.t_in, "t_out" => a.t_out) for a in CB.ASSET_LEDGER[]]
    res["faulted"] = sort!([_s(k) for k in keys(CB.FAULTED_ROBOTS[])])
    res["stalled"] = isdefined(CB, :STALLED_ROBOTS) ? sort!([_s(k) for k in (CB.STALLED_ROBOTS isa Ref ? CB.STALLED_ROBOTS[] : CB.STALLED_ROBOTS)]) : Any[]
    res["cargo_bans"] = isdefined(CB, :STANDING_CARGO_BANS) ? sort!([_s(k) for k in keys(CB.STANDING_CARGO_BANS[])]) : Any[]
    clock = merge(Dict{String,Any}("sim_step" => CB.SIM_STEP[]), Dict{String,Any}(String(k) => v for (k, v) in extra_clock))
    return Dict{String,Any}("schema" => TASK_STATE_SCHEMA, "nodes" => nodes, "edges" => edges,
        "closed" => ids(env.cache.closed_set), "active" => ids(env.cache.active_set), "wedge_edges" => wedge,
        "poses" => poses, "robot_poses" => rposes, "specs" => specs, "team_slots" => slots, "scene" => scene, "components" => comps, "robots" => robots, "rvo" => rvo, "tus" => tus,
        "staging" => staging, "zones" => zones, "resources" => res, "clock" => clock)
end

"""
    derive_task_contract(env, CB; checkpoint_id) -> Dict{String,Any}

원본 작업 계약(schema `task-contract/1`). **t0 이전·생성 코드 실행 전**의 세계에서만 부를 것 — 부른 뒤에는 JSON 으로
저장해 신뢰 쪽이 읽는다(생성 코드가 이 값을 바꿀 수 없게). 필드와 유도처는 파일 머리말.
"""
function derive_task_contract(env, CB::Module; checkpoint_id::AbstractString, atol::Real = DEFAULT_ATOL)
    s = task_state(env, CB)
    nodes = s["nodes"]
    iscon(id) = get(nodes, id, "") in CONSTRUCTION_TYPES
    wedge = Set(Tuple.(s["wedge_edges"]))
    semantic = [e for e in s["edges"] if iscon(e[1]) && iscon(e[2]) && !((e[1], e[2]) in wedge)]
    # 운반 사슬: 건설 간선 FTU→TUGo→Deposit→Lift 로 잇는다(종류로 고른다 — 이름 규칙에 기대지 않는다).
    succ = Dict{String,Vector{String}}(); pred = Dict{String,Vector{String}}()
    for (a, b) in s["edges"]; push!(get!(succ, a, String[]), b); push!(get!(pred, b, String[]), a); end
    only_of(xs, typ) = (m = [x for x in xs if get(nodes, x, "") == typ]; length(m) == 1 ? m[1] : nothing)
    # 씬 조립체 id → 그 AssemblyComplete 노드 id, 화물(부품/조립체) id → 부모 조립체 id
    ac_of = Dict{String,String}()
    for v in CB.Graphs.vertices(env.sched)
        n = CB.get_node(env.sched, v)
        CB.matches_template(CB.AssemblyComplete, n) && (ac_of[_s(CB.node_id(CB.entity(n)))] = _s(CB.node_id(n)))
    end
    parent_of = Dict{String,String}(c => a for (a, cs) in s["components"] for c in keys(cs))
    chains = Any[]
    for v in CB.Graphs.vertices(env.sched)
        n = CB.get_node(env.sched, v)
        CB.matches_template(CB.TransportUnitGo, n) || continue
        tugo = _s(CB.node_id(n))
        cargo = _s(CB.cargo_id(CB.entity(n)))
        ftu = only_of(get(pred, tugo, String[]), "FormTransportUnit")
        # 화물의 출처 노드(부품 = ObjectStart, 하위 조립체 = 그 AssemblyComplete) — FTU 의 건설 선행
        src = ftu === nothing ? nothing :
              (m = [x for x in get(pred, ftu, String[]) if get(nodes, x, "") in ("ObjectStart", "AssemblyComplete")];
               length(m) == 1 ? m[1] : nothing)
        dep = only_of(get(succ, tugo, String[]), "DepositCargo")
        lift = dep === nothing ? nothing : only_of(get(succ, dep, String[]), "LiftIntoPlace")
        asm = get(parent_of, cargo, nothing)
        ac = asm === nothing ? nothing : get(ac_of, asm, nothing)
        P = s["poses"]
        pz(id, f) = (id === nothing || !haskey(P, id)) ? nothing : get(P[id], f, nothing)
        rel(a, b) = (a === nothing || b === nothing) ? nothing : relpose(a, b)
        # 운반의 **양 끝 닻**(t0 상대 자세): 하역 자리는 받는 조립체의 staging 자세 기준(장부가 이미 그렇게 묶는다 —
        # `validate_schedule_transform_tree` 의 `assert_transform_tree_ancestor(goal_config(deposit), start_config(assembly_complete))`),
        # 팀 형성 자리는 화물 출처 자세 기준. 사슬 연속성만으로는 하역 노드째 옮기는 것을 못 본다(TUGo.goal 이 자식이라 따라온다).
        push!(chains, Dict{String,Any}("cargo" => cargo, "source" => src, "ftu" => ftu, "tugo" => tugo, "deposit" => dep,
            "lift" => lift, "assembly" => asm, "assembly_complete" => ac,
            "deposit_rel_assembly" => rel(pz(ac, "config"), pz(dep, "config")),
            "ftu_rel_source" => rel(pz(src, "config"), pz(ftu, "config"))))
    end
    sort!(chains; by = c -> c["tugo"])
    return Dict{String,Any}("schema" => TASK_CONTRACT_SCHEMA, "checkpoint_id" => String(checkpoint_id),
        "validator_version" => TASK_CONTRACT_VALIDATOR_VERSION, "atol" => Float64(atol),
        "derived_at_sim_step" => s["clock"]["sim_step"], "t0_state_sha256" => digest(s),
        "required_nodes" => Dict{String,Any}(k => v for (k, v) in nodes if v in CONSTRUCTION_TYPES),
        "products" => sort!([k for (k, v) in nodes if v in ("ProjectComplete", "AssemblyComplete")]),
        "semantic_edges" => semantic, "runtime_edges_at_t0" => [e for e in s["edges"] if !(e in semantic)],
        "closed_at_t0" => s["closed"], "components" => s["components"], "transport_chains" => chains,
        "specs" => Dict{String,Any}(k => s["specs"][k] for (k, v) in nodes if v in CONSTRUCTION_TYPES),
        "zones" => s["zones"], "robots" => sort!(collect(keys(s["robots"]))), "pools_at_t0" => s["resources"]["pools"],
        "derivation" => Dict{String,Any}(
            "required_nodes" => "construction predicate nodes at t0 (robot nodes are assignment)",
            "semantic_edges" => "construction↔construction edges at t0 minus WEDGE_EDGES (runtime serialization)",
            "closed_at_t0" => "past inviolability (respec/verifier.jl build_invariant)",
            "components" => "scene-tree assembly_components (child relative transforms)",
            "transport_chains" => "FTU→TUGo→Deposit→Lift per transport unit; pose continuity + end anchors " *
                                  "(Deposit.config rel receiving AssemblyComplete.config, FTU.config rel cargo source config) at t0",
            "specs" => "PathSpec of required nodes (min_duration + plan flags) — unchanged by legit translation and by a full run (measured)",
            "robot_team_slots" => "structural, on the evaluated state: every RobotGo→FormTransportUnit edge ends at one of the team's slots",
            "zones" => "RESTRICTION_ZONES at t0"))
end

# =============================================================================
# 판정 쪽 (CB 불필요)
# =============================================================================
_strset(x) = Set{String}(String(v) for v in x)
_pairset(x) = Set{Tuple{String,String}}((String(e[1]), String(e[2])) for e in x)

"""
u 에서 v 로 **아직 닫히지 않은 중간 노드만** 지나는 경로가 있는가.

근거(엔진의 활성화 규칙): 노드는 **직접** 선행이 전부 closed 면 활성이 된다(`essential_tg_coponents.jl` 의 active_set
규칙 — 순수 DAG frontier). 그래서 `u → x → v` 에서 x 가 이미 closed 면 x 는 v 를 u 에 묶지 않는다 — v 는 u 와 무관하게
열린다. 반대로 경로의 모든 중간 노드가 열려 있으면, 귀납으로 각 중간 노드는 자기 앞(결국 u)이 닫히기 전에 활성이 될 수
없으므로 v 도 u 보다 먼저 닫힐 수 없다 — 이후 그래프를 바꾸는 것이 공통 continuation 뿐이라는 전제 아래(도구의 그래프
편집은 action 경계의 스냅샷에서 이 함수로 판정된다).
"""
function _reachable_open(adj, u, v, closed)
    seen = Set{String}([u]); stack = [u]
    while !isempty(stack)
        x = pop!(stack)
        for y in get(adj, x, String[])
            y == v && return true
            (y in seen || y in closed) && continue
            push!(seen, y); push!(stack, y)
        end
    end
    return false
end

"""
    evaluate_task_contract(contract, state; terminal=false) -> (; violations, unsupported, notes)

`state` = `task_state` export(파싱된 JSON 도 된다). 🔴 판정에 worker 의 자기 보고(`complete`·점수)를 쓰지 않는다.
- 위반(violations): 필수 작업 삭제·종류 변경 · 의미 선행 끊김 · 과거 재개방 · 선행보다 먼저 닫힘(완료 위조 서명) ·
  존 삭제/변경 · 운반 연속성(goal=start 류) · 조립 상대 변환 · (terminal) 필수 작업 미완료·부품 자세 ≠ 조립체 ∘ 상대.
- unsupported: 원본 작업과의 대응을 검증할 수 없는 새 건설 노드(분해/통합) — 모델 실패가 아니라 검증기 범위 밖.
- notes: 위반 아닌 관측(존 추가 등).
"""
function evaluate_task_contract(contract::AbstractDict, state::AbstractDict; terminal::Bool = false)
    V, U, N = String[], String[], String[]
    atol = Float64(contract["atol"])
    nodes = state["nodes"]
    req = contract["required_nodes"]
    for (id, typ) in req
        got = get(nodes, id, nothing)
        got === nothing ? push!(V, "required_task_deleted:$(id)") :
            got != typ && push!(V, "required_task_type_changed:$(id):$(typ)->$(got)")
    end
    for (id, typ) in nodes
        typ in CONSTRUCTION_TYPES && !haskey(req, id) &&
            push!(U, "task_refinement_without_correspondence:$(id)")
    end
    E = _pairset(state["edges"])
    adj = Dict{String,Vector{String}}()
    for (a, b) in E; push!(get!(adj, a, String[]), b); end
    closed = _strset(state["closed"])
    for e in contract["semantic_edges"]
        u, v = String(e[1]), String(e[2])
        (haskey(nodes, u) && haskey(nodes, v)) || continue        # 삭제는 위에서 이미 잡았다
        # u 가 이미 닫혔으면 이 선행은 충족됐다. 열려 있으면 v 는 **열린 경로**로만 u 에 묶여야 한다(`_reachable_open`).
        # ⚠️ terminal(전부 closed)에서는 이 검사가 공허하다 — 순서는 action 경계 스냅샷에서 판정한다(보고서 fix 절).
        u in closed || (u, v) in E || _reachable_open(adj, u, v, closed) ||
            push!(V, "semantic_precedence_broken:$(u)->$(v)")
        v in closed && !(u in closed) && push!(V, "closed_before_predecessor:$(v)<-$(u)")
    end
    for id in contract["closed_at_t0"]
        String(id) in closed || push!(V, "past_reopened:$(id)")
    end
    z0, z1 = contract["zones"], state["zones"]
    for (k, g) in z0
        haskey(z1, k) ? (posediff(g, z1[k]) == 0 || push!(V, "zone_changed:$(k)")) : push!(V, "zone_removed:$(k)")
    end
    for k in keys(z1); haskey(z0, k) || push!(N, "zone_added:$(k)"); end
    P = state["poses"]
    pose(id, f) = (id === nothing || !haskey(P, id)) ? nothing : get(P[id], f, nothing)
    for c in contract["transport_chains"]
        cg = String(c["cargo"])
        close_pose(pose(c["tugo"], "goal_config"), pose(c["deposit"], "config"), atol) ||
            push!(V, "transport_skipped:tugo_goal!=deposit_config:$(cg)")
        close_pose(pose(c["tugo"], "start_config"), pose(c["ftu"], "config"), atol) ||
            push!(V, "transport_discontinuous:tugo_start!=ftu_config:$(cg)")
        close_pose(pose(c["deposit"], "cargo_goal_config"), pose(c["lift"], "start_config"), atol) ||
            push!(V, "deposit_discontinuous:deposit_cargo_goal!=lift_start:$(cg)")
        # 양 끝 닻: 하역 자리가 받는 조립체 기준으로, 팀 형성 자리가 화물 출처 기준으로 t0 과 같아야 한다.
        # 빌드 전체 이동·staging 이동은 조립체와 그 하역 자리를 **같이** 옮기므로 이 관계를 지킨다(시험 [4]).
        for (k, a_, af, b_, tag) in (("deposit_rel_assembly", c["assembly_complete"], "config", c["deposit"], "deposit"),
                                     ("ftu_rel_source", get(c, "source", nothing), "config", c["ftu"], "ftu"))
            want = get(c, k, nothing)
            want === nothing && continue
            pa, pb = pose(a_, af), pose(b_, "config")
            (pa !== nothing && pb !== nothing && close_pose(relpose(pa, pb), want, atol)) ||
                push!(V, "transport_anchor_moved:$(tag):$(cg)")
        end
        a = c["assembly"]
        if a !== nothing
            rel = get(get(contract["components"], a, Dict()), cg, nothing)
            acp = pose(c["assembly_complete"], "config")
            (rel !== nothing && acp !== nothing && close_pose(pose(c["lift"], "goal_config"), compose(acp, rel), atol)) ||
                push!(V, "install_pose_changed:lift_goal!=assembly∘relative:$(cg)")
        end
    end
    # 필수 작업의 시간·동작 명세(최소 소요시간 = 시간 비용). 합법 기하 이동·전체 실행에서 불변(실측).
    for (id, sp) in contract["specs"]
        got = get(state["specs"], id, nothing)
        got === nothing || collect(got) == collect(sp) || push!(V, "task_spec_changed:$(id)")
    end
    # 물리 선행: 팀을 이루는 로봇은 그 팀의 자리 중 하나에 도착해야 한다(배정이 바뀌어도 성립해야 하는 관계 — 평가 대상
    # 상태의 간선 위에서 본다). colored_8x8 t0 에서 68/68 성립, RobotGo goal=start 는 이것을 깬 채로도 완주했다(실측).
    RP, TS = state["robot_poses"], state["team_slots"]
    for (u, v) in E
        (get(nodes, u, "") == "RobotGo" && get(nodes, v, "") == "FormTransportUnit") || continue
        g = haskey(RP, u) ? get(RP[u], "goal_config", nothing) : nothing
        fc = pose(v, "config")
        ok = g !== nothing && fc !== nothing && any(sl -> close_pose(g, compose(fc, sl), atol), get(TS, v, Any[]))
        ok || push!(V, "robot_not_at_team_slot:$(u)->$(v)")
    end
    for (a, cs) in contract["components"]
        got = get(state["components"], a, nothing)
        got === nothing && (push!(V, "assembly_removed:$(a)"); continue)
        for (c, rel) in cs
            (haskey(got, c) && close_pose(got[c], rel, atol)) || push!(V, "assembly_relation_changed:$(a)/$(c)")
        end
    end
    if terminal
        missing_ = sort!([String(id) for id in keys(req) if !(String(id) in closed)])
        isempty(missing_) || push!(V, "required_tasks_not_closed:$(length(missing_)):" * join(first(missing_, 5), ","))
        sc = state["scene"]
        for c in contract["transport_chains"]
            a, cg = c["assembly"], String(c["cargo"])
            (a === nothing || c["lift"] === nothing || !(String(c["lift"]) in closed)) && continue
            rel = contract["components"][a][cg]
            (haskey(sc, cg) && haskey(sc, a) && close_pose(sc[cg], compose(sc[a], rel), atol)) ||
                push!(V, "final_part_pose!=assembly∘relative:$(cg)")
        end
    end
    return (; violations = V, unsupported = U, notes = N)
end

"""
    task_contract_report(contract, state; terminal=false, proposal_id=nothing) -> RepairTypes.ValidationReport

stage `:task_contract`. 위반 → `:reject`, 위반 없이 unsupported → `:unsupported`, 둘 다 없으면 `:accept`.
"""
function task_contract_report(contract::AbstractDict, state::AbstractDict; terminal::Bool = false, proposal_id = nothing)
    r = evaluate_task_contract(contract, state; terminal)
    v = !isempty(r.violations) ? :reject : !isempty(r.unsupported) ? :unsupported : :accept
    reasons = v === :accept ? String[] : vcat(r.violations, r.unsupported)
    return R.ValidationReport(:task_contract, v, proposal_id, reasons, TASK_CONTRACT_VALIDATOR_VERSION)
end

end # module TaskContract
