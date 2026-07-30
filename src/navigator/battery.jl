# ============================================================================
#  [한국어 안내] 이 파일 = "로봇별 배터리 잔량(SoC) 회계 + 배터리 OOD" 계층
#  ---------------------------------------------------------------------------
#  프로젝트 역할:
#   · 계획(MILP) 계층은 이미 "전체 함대 에너지"를 목적식에 넣는다. 여기서 빠진 건
#     "물리 로봇 한 대 한 대"의 에너지 예산 — 그걸 이 파일이 실행(execution) 중에 채운다.
#     매 스텝 로봇이 실제로 얼마나 움직였는지 읽어, 그 일을 한 로봇의 배터리를 깎는다.
#   · SoC(State of Charge) = 배터리 잔량(0~1). 세 가지로 쓰인다:
#       (1) 재계획 편향: 잔량 낮은 로봇에겐 가볍고 가까운 일만 가게 목적식 비용을 키움.
#       (2) 배터리 OOD: 시뮬 도중 갑자기 SoC 급락(셀 고장) 주입 -> LLM 이 대응(재배정/교체).
#       (3) 방전 정지(stall): SoC 가 0 근처면 로봇을 물리적으로 멈추고 예비로 교체.
#   · 비침습(non-invasive): 단독 파일로 수동 include. BATTERY_ACCOUNTING[] 이 켜지기 전엔
#     모든 훅이 "무동작(inert)"이라, 평소 실행엔 아무 영향이 없다.
#
#  문법 참고:
#   · Base.@kwdef struct : 필드에 기본값을 주는 구조체 정의 매크로. BatteryParams(idle_W=200) 식으로 생성.
#   · mutable struct : 생성 후 필드 변경 가능한 구조체(불변 struct 와 대비).
#   · Ref(x) / X[] : 전역 가변 "상자". X[] 로 읽고 X[] = v 로 쓴다. 훅/스위치를 담는 데 자주 씀.
#   · @enum RobotMode IDLE ... : 정수 상수 묶음(모드 이름표) 정의 매크로.
#   · x isa T : x 가 타입 T 인가?(런타임 타입 검사). `A && return B` = A 참일 때만 B 반환.
#   · `!` 접미사(_debit!, init_battery_fleet! 등) = 인자/전역 상태를 직접 바꾼다는 관례.
#   · Dict{Any,Float64} : 키 아무 타입, 값 실수인 사전. get(d, k, 기본값) = 없으면 기본값.
#   · try ... catch ... end : 예외를 삼키고 안전한 기본값으로 폴백(접근자 실패 대비).
#   · f(x; kw=1) : `;` 뒤는 키워드 인자. km = k_move(p) 처럼 한 줄 함수도 흔함.
# ============================================================================

# battery.jl
# ConstructionBots LLM Design-Space Navigator — per-PHYSICAL-robot battery SoC accounting.
# See docs/llm_navigator_plan.md ("Battery extension") and src/navigator/metrics.jl.
#
# WHY THIS FILE EXISTS
#   The planning layer already prices ENERGY at MILP-formulation time:
#     essential_tg_coponents.jl  edge_energy(dt_min; payload_mass)  -> edge_costs[(v,v2)]
#   giving a TOTAL fleet energy term in the objective. What is missing (plan doc, line
#   "Battery extension") is per-PHYSICAL-robot energy ACCOUNTING — grouping the work by the
#   robot that actually does it, so each robot has its own SoC budget. We do that grouping
#   at EXECUTION time (easier + more faithful than re-deriving it inside the MILP): we read
#   realized motion each step and debit the responsible robot's battery.
#
# MODEL (lightweight, NOT a battery-physics paper — Level-1 energy bookkeeping):
#     SoC_{k+1} = SoC_k - P_k * dt / E_cap         (per physical robot)
#   Power is mode-classified from the active schedule node, with a payload-linear term:
#     idle       (always, every powered-on robot)            P_idle
#     transit    (RobotGo, empty)         + k_move·m_robot·v
#     carry      (TransportUnitGo, loaded)+ k_move·(Σm_robot + m_payload)·v   (split over team)
#     manipulate (FormTransportUnit / DepositCargo / LiftIntoPlace) + P_manip
#   k_move is the cost-of-transport coefficient (CoT·g); calibrated below to hit the spec
#   anchors (Optimus: 100 W idle / 500 W walk / ~1 kW manipulate, 2.3 kWh). The payload term
#   is the SAME differential that drives the planning-side edge_energy load hook — keep them
#   consistent so the objective's PREDICTED energy matches the realized SoC drain.
#
# NON-INVASIVE: standalone, manually `include`d (like the other navigator/*.jl files). The
# step hook (`account_battery_step!`) is INERT until `BATTERY_ACCOUNTING[] = true`, so adding
# the one call into step_environment! changes nothing in normal runs (mirrors RESPEC_HOLD).
#
# (?) accessors verified against current code: entity/node_id/robot_team/cargo_id/get_node/
# get_nodes/matches_template/global_transform/get_base_geom(·,HyperrectangleKey()). The
# payload-mass proxy (bbox volume × density) is a HOOK — verify density/units before claiming
# physical Watts.

# ---------------------------------------------------------------------------------
# Parameters — physical units (SI). Defaults from the Optimus spec table.
# ---------------------------------------------------------------------------------
# 배터리 물리 파라미터(SI 단위). 기본값은 Optimus 스펙 표에서. @kwdef 라 필드 이름으로 골라 덮어쓸 수 있음.
Base.@kwdef struct BatteryParams
    capacity_J::Float64      = 2.3 * 3.6e6     # 2.3 kWh -> 8.28e6 J  (spec: ★★★ official)
    idle_W::Float64          = 100.0           # baseline draw, every powered-on robot (spec 2차)
    walk_W::Float64          = 500.0           # total draw walking unloaded at v_ref (spec 2차)
    manip_W::Float64         = 1000.0          # total draw during manipulation (spec 2차)
    v_ref::Float64           = 4.0             # reference walk speed = rvo_default_max_speed()=4.0 m/s (VERIFIED rvo_interface.jl:119)
    m_robot::Float64         = 60.0            # nominal robot mass [kg] (Optimus ~57-73 kg)
    payload_density::Float64 = 100.0           # mass proxy: kg per (sim bbox volume unit). TUNING KNOB.
    seconds_per_step::Float64= 1.0             # env.dt is ALREADY seconds (=1/40 s, VERIFIED full_demo.jl:272) so 1.0.
    floor_soc::Float64       = 0.0             # clamp; <floor means depleted (battery-OOD trigger)
end

# IMPORTANT (verified): with REAL spec numbers, gradual depletion is negligible within one
# build — idle drain/step = 100W·(1/40 s)/8.28e6 J ≈ 3e-7, so even 10^5 steps move SoC ~0.03.
# Two consequences this module is built around:
#   (1) SoC is used as a REPLAN-TIME BIAS/BUDGET (low-SoC robots get lighter/closer/fewer tasks
#       via `battery_edge_multiplier`), not as a quantity that visibly drains in a short build.
#   (2) The battery OOD is a SUDDEN health/SoC DROP (a degraded/failed cell), injected mid-sim —
#       see `inject_battery_fault!`. This is the "battery health drop -> respec" event the LLM
#       must react to by re-routing the affected robot's heavy/long hauls onto healthier robots.
# `demo_battery_params()` shrinks capacity so gradual depletion is ALSO visible in short demos.

"Scaled-down battery for SHORT demos so gradual depletion is visible (capacity ÷ `shrink`).
`shrink≈500` keeps a ~15 s build's robots in a visible mid-SoC band (not all flat at 0)."
# 짧은 데모용: 용량을 shrink 배 줄여 15초짜리 빌드에서도 잔량이 눈에 띄게 줄게 함. kw... = 나머지 필드 그대로 전달.
demo_battery_params(; shrink::Float64 = 500.0, kw...) =
    BatteryParams(; capacity_J = (2.3 * 3.6e6) / shrink, kw...)

# CoT coefficient k_move [W per (kg·v_ref)] calibrated so an unloaded robot walking at v_ref
# draws exactly walk_W:  idle_W + k_move·m_robot·v_ref = walk_W.
# 이동비용 계수 보정: "짐 없이 v_ref 로 걸으면 정확히 walk_W 소모"가 되도록 idle 초과분을 (질량×속도)로 나눔.
k_move(p::BatteryParams) = (p.walk_W - p.idle_W) / (p.m_robot * p.v_ref)

# ---------------------------------------------------------------------------------
# Fleet state — per physical robot. (RobotNode is immutable, so SoC lives here, keyed by id.)
# ---------------------------------------------------------------------------------
# 함대(fleet) 상태 = 물리 로봇들의 배터리 장부. RobotNode 는 불변이라 SoC 를 여기 id 키로 따로 보관. mutable = 갱신 가능.
mutable struct BatteryFleet
    params::BatteryParams
    soc::Dict{Any,Float64}            # RobotID -> state of charge in [0,1]   # 로봇별 잔량
    energy_J::Dict{Any,Float64}       # RobotID -> cumulative energy drawn [J] (for metrics)  # 누적 소비 에너지
    active_steps::Dict{Any,Int}       # RobotID -> # steps spent non-idle (utilization proxy)  # 일한 스텝 수(가동률)
    depleted::Set{Any}                # robots that hit floor_soc (line-stop candidates)  # 바닥까지 방전된 로봇
end

const BATTERY_ACCOUNTING = Ref(false)            # master on/off (inert by default)  # 전체 회계 켜기/끄기(기본 꺼짐)
const BATTERY_FLEET      = Ref{Union{Nothing,BatteryFleet}}(nothing)  # 현재 함대(없으면 nothing)를 담는 전역 상자

"""
    init_battery_fleet!(env; params=BatteryParams(), soc0=1.0) -> BatteryFleet

Enumerate every physical robot in the scene and give it a full battery. Call once after the
schedule/scene are built, before stepping. Stashes the fleet in `BATTERY_FLEET[]` and enables
accounting. Returns the fleet.
"""
# 씬(scene)의 모든 물리 로봇을 훑어 각자 만충 배터리를 부여. 스케줄/씬 완성 후·스텝 시작 전에 한 번 호출.
# 만든 함대를 BATTERY_FLEET[] 에 저장하고 회계를 켠다.
function init_battery_fleet!(env; params::BatteryParams=BatteryParams(), soc0::Float64=1.0)
    ids = [node_id(n) for n in get_nodes(env.scene_tree) if matches_template(RobotNode, n)]  # 로봇 노드들의 id 만 수집
    fleet = BatteryFleet(params,
        Dict{Any,Float64}(id => soc0 for id in ids),
        Dict{Any,Float64}(id => 0.0 for id in ids),
        Dict{Any,Int}(id => 0 for id in ids),
        Set{Any}())
    BATTERY_FLEET[] = fleet
    BATTERY_ACCOUNTING[] = true
    return fleet
end

# Debit one robot: energy = power·dt, SoC drops by energy/capacity. Clamp at floor; record depletion.
# 로봇 한 대 배터리 깎기: 에너지=전력×시간, SoC 는 에너지/용량 만큼 하락. 바닥(floor) 에 닿으면 depleted 로 기록.
function _debit!(fleet::BatteryFleet, id, power_W::Float64, dt_s::Float64)
    haskey(fleet.soc, id) || return            # unknown id (e.g. transient respec spare) -> skip  # 모르는 id 면 건너뜀
    e = power_W * dt_s                         # 이번 스텝 소비 에너지[J]
    fleet.energy_J[id] += e                    # 누적 소비에 더함
    s = fleet.soc[id] - e / fleet.params.capacity_J   # 잔량 = 기존 - (소비/용량)
    if s <= fleet.params.floor_soc
        s = fleet.params.floor_soc
        push!(fleet.depleted, id)
    end
    fleet.soc[id] = s
    return
end

# ---- mode classification + payload mass --------------------------------------------------

# 로봇의 전력 소모 모드 4종: 대기 / 빈몸이동 / 짐운반 / 정밀조작. @enum = 이름표 정수 상수 묶음.
@enum RobotMode IDLE TRANSIT CARRY MANIPULATE

# 진행 중인 스케줄 노드를 전력 모드로 분류. node 는 안쪽 predicate(.node). 어디에도 안 맞으면 IDLE.
# Classify an active schedule node into a power mode. `node` is the inner predicate (.node).
function _node_mode(node)
    node isa RobotGo            && return TRANSIT
    node isa TransportUnitGo    && return CARRY
    (node isa FormTransportUnit || node isa DepositCargo || node isa LiftIntoPlace) && return MANIPULATE
    return IDLE                 # RobotStart and anything else: baseline only
end

# 이 노드의 일을 실제로 하는 물리 로봇들: RobotGo 는 한 대, 운반유닛(TransportUnit)은 팀 전원에 분산. RobotID 벡터 반환.
# Physical robots responsible for an active node: a RobotGo is one robot; a TransportUnit
# spreads work over its whole team. Returns a Vector of RobotIDs.
function _responsible_robots(node)
    if node isa RobotGo || node isa RobotStart
        return [node_id(entity(node))]
    elseif node isa TransportUnitGo || node isa FormTransportUnit || node isa DepositCargo
        return collect(keys(robot_team(node)))     # robot_team(pred) -> robot_team(entity) -> n.robots
    else
        return Any[]
    end
end

# 짐 질량 근사값: 화물 바운딩박스 부피(반경 곱 8배)×밀도. 운반 안 하거나 형상 접근 실패면 0 으로 폴백(try/catch).
# Payload mass proxy from the cargo bounding box (HOOK; mirrors edge_energy's payload_mass).
# bbox half-extents .radius (SVector{3}) -> volume 8·∏radius -> ×density. Falls back to 0 on
# any node that carries nothing or whose geom is unavailable. VERIFY density/units.
function _payload_mass(env, node, p::BatteryParams)
    (node isa TransportUnitGo || node isa DepositCargo || node isa FormTransportUnit) || return 0.0
    try
        cargo = get_node(env.scene_tree, cargo_id(entity(node)))
        r = get_base_geom(cargo, HyperrectangleKey()).radius
        return p.payload_density * 8.0 * prod(r)
    catch
        return 0.0
    end
end

# ---------------------------------------------------------------------------------
# The per-step hook. Call near the END of step_environment!, after positions update, passing
# the prev-position dict captured at the top (prev_active_pos_dict). Two passes:
#   (1) idle baseline to EVERY powered-on robot,
#   (2) mode surcharge (above idle) to the robot(s) actually doing the work.
# Surcharges are DELTAS above idle, so there is no double counting.
# ---------------------------------------------------------------------------------
"""
    account_battery_step!(env, prev_pos) -> nothing

Debit one timestep of energy from each physical robot's battery. `prev_pos` is the
`get_active_pos(env)` snapshot taken at the start of the step (vertex -> position), used to
measure REALIZED speed (captures RVO slow-downs). Inert unless `BATTERY_ACCOUNTING[]`.
"""
# 매 스텝 배터리 회계 훅(step_environment! 끝부분에서 호출). prev_pos = 스텝 시작 시 위치 스냅샷(실제 속도 측정용).
# BATTERY_ACCOUNTING[] 이 꺼져 있으면 아무 것도 안 함. 아래는 세 단계(대기소모 / 작업할증 / 방전정지).
function account_battery_step!(env, prev_pos::Dict{Int,Vector{Float64}})
    BATTERY_ACCOUNTING[] || return                        # 회계 꺼져 있으면 즉시 종료
    fleet = BATTERY_FLEET[]; fleet === nothing && return  # 함대 없으면 종료
    p  = fleet.params
    dt = env.dt * p.seconds_per_step                      # 이번 스텝의 실제 시간[s]
    km = k_move(p)                                        # 이동비용 계수

    # (1) idle baseline — every powered-on robot. EXCEPT spares still parked in a depot: a
    # backup waiting in its repository is off/on the charger, so it does NOT drain until it is
    # dispatched (popped from the pool). Without this, idle spares slowly flatten over a long
    # build and a stall cascade can melt the whole fleet. `active_spares()` is empty in runs
    # without spare pools, so this is a no-op there.
    # Also exclude spares that have been CHECKED OUT of a depot for a hot-swap: they are popped
    # from the pool (so no longer in active_spares()) and teleported off-grid (retired). Without
    # this they'd keep draining and eventually self-stall, triggering a spurious second swap.
    # parked = 창고에 세워둔 예비(active_spares) + 핫스왑으로 빼내 은퇴시킨 예비(checked_out) = 방전 대상에서 제외.
    parked = union!(Set{Any}(active_spares()), Set{Any}(checked_out_spares()))
    for id in keys(fleet.soc)
        (id in parked) && continue                         # 주차된 예비는 소모 안 함
        _debit!(fleet, id, p.idle_W, dt)                   # 켜져 있는 모든 로봇에 대기전력 부과
    end

    # (2) 활성 노드별로 "대기 초과분(할증)"을 실제 일한 로봇(들)에게 부과. 할증은 대기 위 델타라 이중계산 없음.
    active_ids = Set{Any}()          # robots actually working this step (stall candidates)  # 이번에 일한 로봇들(정지 후보)
    for v in env.cache.active_set                          # 진행 중인 스케줄 정점들
        sched_node = get_node(env.sched, v)
        node = sched_node.node
        mode = _node_mode(node)
        mode == IDLE && continue                           # 대기 모드면 할증 없음

        robots = _responsible_robots(node)
        isempty(robots) && continue
        union!(active_ids, robots)
        for id in robots
            haskey(fleet.active_steps, id) && (fleet.active_steps[id] += 1)   # 가동 스텝 카운트 증가
        end

        if mode == MANIPULATE
            # 정지 상태 정밀작업: 일정한 할증을 팀이 나눠 부담.
            # Stationary precision work: constant surcharge, split over the team.
            surcharge = (p.manip_W - p.idle_W) / length(robots)
            for id in robots
                _debit!(fleet, id, surcharge, dt)
            end
        else  # TRANSIT or CARRY — realized speed × moved mass.  # 이동/운반: 실제 속도 × 움직인 질량
            new_pos = global_transform(entity(node)).translation   # 지금 위치
            old_pos = get(prev_pos, v, new_pos)                    # 스텝 시작 위치(없으면 지금 위치=이동 0)
            speed = dt > 0 ? norm((new_pos - old_pos)[1:2]) / dt : 0.0  # 실제 이동속도(x,y 평면). RVO 감속까지 반영
            m_payload = _payload_mass(env, node, p)                # 짐 질량
            moved_mass = p.m_robot * length(robots) + m_payload    # 로봇들 질량 + 짐
            unit_surcharge = km * moved_mass * speed          # total locomotion surcharge for the unit  # 유닛 전체 이동 할증
            share = unit_surcharge / length(robots)           # split equally over the team  # 팀원끼리 균등 분배
            for id in robots
                _debit!(fleet, id, share, dt)
            end
        end
    end

    # (3) STALL: any ACTIVELY-WORKING robot that just crossed the stall threshold breaks down
    # once -> physical fault + breakdown NL -> respec ReplaceAgent -> nearest spare takes over.
    # Only active workers trigger (a dead idle robot has nothing to hand off); the motion gate
    # still freezes anything flat. Inert unless stall enabled.
    # (3) 방전 정지: 이번에 "일하던" 로봇이 정지 임계값을 처음 넘으면 딱 한 번 고장 처리 -> 교체 OOD 발생.
    if BATTERY_STALL[].enabled
        thr = BATTERY_STALL[].threshold
        retired = Set{Any}(checked_out_spares())   # never re-stall a retired (checked-out) spare  # 은퇴 예비는 재정지 안 함
        for id in active_ids
            (id in retired) && continue
            (id in STALLED_ROBOTS[]) && continue                    # 이미 정지 처리된 로봇은 건너뜀(한 번만)
            (haskey(fleet.soc, id) && fleet.soc[id] <= thr) || continue  # 잔량이 임계값 이하일 때만
            push!(STALLED_ROBOTS[], id)                             # 정지 처리 기록(중복 방지)
            nl = _fire_battery_stall!(env, id)                     # 고장 OOD 발생시키기
            nl === nothing || @info "[STALL] robot R$(id.id) battery flat (SoC<=$(round(thr;digits=3))) -> breakdown OOD; dispatching nearest spare."
        end
    end
    return
end

# ---------------------------------------------------------------------------------
# Reporting — feeds RunMetrics (metrics.jl) and grounds a future battery-OOD / adaptability axis.
# ---------------------------------------------------------------------------------
"""
    battery_report(fleet=BATTERY_FLEET[]) -> NamedTuple

Fleet summary for the metric vector:
  total_energy_J, min_soc (wear-leveling / margin), mean_soc, n_depleted, soc (per-robot dict).
`min_soc` is the wear-leveling signal — identical batteries diverge under differential use, so
the WORST robot, not the mean, gates feasibility and is the natural battery-OOD trigger.
"""
# 함대 요약(지표 벡터용): 총 소비에너지 / 최소·평균 SoC / 편차 / 방전 로봇 수 / 로봇별 SoC.
# 최소 SoC 가 핵심: 같은 배터리도 사용량 차이로 벌어지므로, 평균이 아니라 "가장 나쁜 로봇"이 실현가능성을 좌우.
function battery_report(fleet::BatteryFleet=BATTERY_FLEET[])
    socs = collect(values(fleet.soc))
    return (total_energy_J = sum(values(fleet.energy_J)),
            min_soc  = isempty(socs) ? NaN : minimum(socs),
            mean_soc = isempty(socs) ? NaN : sum(socs) / length(socs),
            soc_spread = isempty(socs) ? NaN : (maximum(socs) - minimum(socs)),  # wear-leveling signal
            n_depleted = length(fleet.depleted),
            soc = copy(fleet.soc))
end

# =================================================================================
# BATTERY-OOD + SoC-aware REPLAN BIAS
# ---------------------------------------------------------------------------------
# The pieces that make replanning ENERGY/BATTERY-aware. The replan pipeline
# (replan.jl maybe_respecify! -> formulate_milp(SparseAdjacencyMILP) -> get_objective_expr)
# rebuilds the objective on EVERY OOD event and reads the global ENERGY_MODEL +
# PLANNING_OBJECTIVE_WEIGHTS + EDGE_COST_MULTIPLIER Refs. So we bias replans toward
# healthy robots WITHOUT touching replan.jl: we install an edge-cost multiplier that
# scales an assignment edge's energy by how depleted the robot OWNING that edge is.
# =================================================================================

# --- (a) battery-health OOD: a sudden SoC drop on a robot, injected mid-sim ------
"""
    inject_battery_fault!(env; target=nothing, soc_drop=0.6, enqueue=true) -> String

Drop a robot's State-of-Charge by `soc_drop` (a degraded/failed cell), injected mid-sim. When
`enqueue`, pushes a natural-language event onto the respec queue (`push_ood!`) so the respec loop
fires a replan; the installed `battery_edge_multiplier` then biases that replan to re-route the
robot's heavy/long hauls onto healthier robots. Returns the NL string (or "" if no fleet / no
eligible robot). Mirrors `fault_robot!`'s shape (it returns NL; the wrapper records truth).

The NL is SEVERITY-BRANCHED to match the canonical response (see `REPLACE_SOC_THRESHOLD`): a deep
discharge (resulting SoC ≤ threshold) reads as a BREAKDOWN ("treat as broken down, hand to a backup")
so the controller is cued to Replace; a mild degradation keeps the soft "avoid long hauls" wording so
the soft-bias path and any NL parsers are unchanged above the threshold.
"""
# 배터리-건강 OOD 주입: 한 로봇의 SoC 를 soc_drop 만큼 뚝 떨어뜨림(셀 열화/고장). enqueue 면 자연어 사건을 재명세 큐에 넣음.
# 반환값은 자연어(NL) 문자열(함대/대상 없으면 ""). 심각도에 따라 문구가 갈린다(깊은 방전=고장 취급 / 가벼운 열화=먼거리 피하기).
function inject_battery_fault!(env; target=nothing, soc_drop::Float64=0.6, enqueue::Bool=true)
    fleet = BATTERY_FLEET[]; fleet === nothing && return ""
    id = target === nothing ? _pick_battery_target(env, fleet) : target  # 대상 미지정 시 알아서 고름
    (id === nothing || !haskey(fleet.soc, id)) && return ""
    fleet.soc[id] = max(fleet.params.floor_soc, fleet.soc[id] - soc_drop)  # 잔량 하락(바닥 아래로는 안 감)
    soc_after = fleet.soc[id]
    soc_pct = round(Int, 100 * soc_after)                # 퍼센트 표기용 반올림
    # Guard the threshold: REPLACE_SOC_THRESHOLD lives in ood_truth.jl; fall back to 0.2 if a demo
    # include'd battery.jl standalone (matches the file's other isdefined cross-layer guards).
    # 임계값은 ood_truth.jl 소속; 이 파일만 단독 include 된 데모 대비해 없으면 0.2 로 폴백(isdefined 로 존재 확인).
    thr = isdefined(@__MODULE__, :REPLACE_SOC_THRESHOLD) ? REPLACE_SOC_THRESHOLD[] : 0.2
    nl = soc_after <= thr ?                              # 깊은 방전이면 "고장 취급" 문구, 아니면 "부담 줄이기" 문구
        "Robot R$(id.id)'s battery is critically flat at about $(soc_pct)% charge; it can no longer " *
        "drive or carry — treat it as broken down and hand its work to a backup robot." :
        "Robot R$(id.id)'s battery is degraded and now at about $(soc_pct)% charge; " *
        "it should avoid long-distance and heavy-payload hauls so it does not run flat."
    enqueue && push_ood!(nl)                             # enqueue 참이면 재명세 큐에 자연어 사건 투입
    return nl
end

# Pick the robot the battery OOD should hit. It MUST be a robot the response can act on, i.e. one
# that still has pending work; otherwise every macro (Replace, Deprioritize, NOOP) is a no-op and the
# event is vacuous. The old `_pick_low_margin_robot` took the HIGHEST-SoC robot, which — once the
# battery layer is on and the spare depots are provisioned — is always a PARKED SPARE (idle => never
# drains, and it owns no tasks). Same class of bug as the fault injector's target picker.
# Order: (1) a cleanly-replaceable working robot (solo transport frontier — Replace can actually
# hand its chain over), (2) any non-spare robot with a pending assignment, (3) the legacy fallback.
# 배터리 OOD 를 "대응 가능한" 로봇에게 꽂는 대상 선택. (남은 일이 있는 로봇이어야 교체/우선순위낮춤이 의미 있음)
# 순서: (1) 깔끔히 교체 가능한 작업 로봇 -> (2) 예비 아니고 남은 배정 있는 로봇 -> (3) 옛 폴백.
function _pick_battery_target(env, fleet::BatteryFleet)
    isempty(fleet.soc) && return nothing
    for f in (:pick_solo_fault_target, :pick_solo_frontier_target)   # 이 헬퍼들이 있으면 우선 사용(없으면 catch)
        rid = try getproperty(@__MODULE__, f)(env) catch; nothing end
        rid !== nothing && haskey(fleet.soc, rid) && return rid
    end
    # 남은 일(pending) 있고, 예비 아니고, 아직 방전 안 된 로봇들만 후보로.
    working = [id for (id, s) in fleet.soc
               if s > fleet.params.floor_soc &&
                  !(try is_spare(id) catch; false end) &&
                  (try _first_pending_assignment(env, id) !== nothing catch; false end)]
    isempty(working) || return argmax(id -> fleet.soc[id], working)  # 그 중 SoC 가장 높은(=오폭 아닌) 로봇
    return _pick_low_margin_robot(fleet)                              # 다 실패하면 옛 방식 폴백
end

# Legacy picker: highest SoC among non-depleted robots. Kept for callers that pass no env, but NOT
# used for OOD injection any more (see `_pick_battery_target`).
# 옛 선택기: 방전 안 된 로봇 중 SoC 최고를 고름. env 없는 호출자용으로 남겨둠(OOD 주입엔 더 이상 안 씀).
function _pick_low_margin_robot(fleet::BatteryFleet)
    isempty(fleet.soc) && return nothing
    cand = [id for (id, s) in fleet.soc if s > fleet.params.floor_soc]
    isempty(cand) && return nothing
    return argmax(id -> fleet.soc[id], cand)
end

# 잔량이 threshold 이하인 로봇들 = 재계획 때 "무거운/먼 일 피하게" 할 예산 집합.
"Robots at or below `threshold` SoC — the replan-time budget set (avoid heavy/long tasks)."
low_soc_robots(fleet::BatteryFleet=BATTERY_FLEET[]; threshold::Float64=0.25) =
    [id for (id, s) in fleet.soc if s <= threshold]

# --- (b) the per-robot edge-cost multiplier installed into the MILP objective ----
# penalty knobs: an edge owned by a robot at SoC s is multiplied by
#     1 + gain · max(0, soc_target − s)/soc_target           (soft de-prioritization)
# and by `hard_mult` (large) if s ≤ floor (depleted) so the solver routes around it.
# 배터리 페널티 손잡이: gain=소프트 벌점 세기, soc_target=목표 잔량, hard_mult=방전 로봇용 큰 배수(우회 유도).
const BATTERY_PENALTY = Ref((gain = 4.0, soc_target = 0.5, hard_mult = 1.0e3))
set_battery_penalty!(; gain=4.0, soc_target=0.5, hard_mult=1.0e3) =
    (BATTERY_PENALTY[] = (gain=Float64(gain), soc_target=Float64(soc_target), hard_mult=Float64(hard_mult)))

# SoC -> 로봇 한 대의 비용 배수. 방전(≤0)이면 큰 배수, 아니면 1 + gain×(목표대비 부족분).
# SoC -> cost multiplier for one robot.
function _soc_multiplier(soc::Float64)
    p = BATTERY_PENALTY[]
    soc <= 0.0 && return p.hard_mult
    deficit = max(0.0, p.soc_target - soc) / p.soc_target
    return 1.0 + p.gain * deficit
end

# =================================================================================
# BATTERY STALL: physically immobilize a flat robot and raise a breakdown OOD.
# When a robot's SoC <= threshold: (1) a MOTION gate zeroes its unit's max_speed
# (route_planning.SOC_SPEED_HOOK -> soc_speed_factor) so it STOPS where it is, and
# (2) the FIRST time an ACTIVELY-WORKING robot crosses the threshold we fault it and
# enqueue the breakdown NL, so the verified respec loop dispatches ReplaceAgent ->
# nearest_pool -> pop_spare! -> replace_robot! (the spare drives out of its depot and
# adopts the dead robot's remaining chain / re-forms its transport team).
# Inert unless `set_battery_stall!(enabled=true)`; energy-only / nominal runs unaffected.
# =================================================================================
# 방전 정지 설정: enabled=켜기, threshold=정지 SoC 경계, clear=죽은 로봇 견인 여부, obstacle=사체를 장애물로 둘지.
const BATTERY_STALL  = Ref((enabled = false, threshold = 0.001, clear = true, obstacle = false))
const STALLED_ROBOTS = Ref(Set{Any}())              # robots already stall-triggered (fire once)  # 이미 정지 처리된 로봇(한 번만)
stalled_robots() = STALLED_ROBOTS[]
clear_stalled_robots!() = (empty!(STALLED_ROBOTS[]); nothing)   # 정지 기록 초기화

"""
    set_battery_stall!(; enabled=true, threshold=0.001, clear=true, obstacle=false)

Turn the SoC->stall coupling on/off. A robot at/below `threshold` SoC is dead: its unit is
frozen by the motion gate and (if actively working) it triggers a breakdown OOD. Resets the
fire-once guard. Off by default so the soft energy-bias demo is unchanged.

Enactment of the dead robot (matches the proven 1-1 hand-off, docs V4):
- `clear=true`  (default): TOW the dead body off-grid so the spare takes over cleanly and the
  build completes. Leaving it in place (`clear=false`) can WEDGE follow-on transport teams in a
  tight staging area (they cannot route around a dead robot sitting on the build).
- `obstacle=false` (default): do NOT drop a no-go zone on the body (avoids the LLM ForbidZone
  over-classification). Set `obstacle=true` only if you want the body to stay and be detoured.
"""
# 방전->정지 연동을 켜고/끄는 스위치(발동 1회 가드도 리셋). 기본은 꺼짐이라 소프트 에너지-편향 데모엔 영향 없음.
set_battery_stall!(; enabled::Bool = true, threshold::Real = 0.001,
                     clear::Bool = true, obstacle::Bool = false) =
    (BATTERY_STALL[] = (enabled = enabled, threshold = Float64(threshold),
                        clear = clear, obstacle = obstacle);
     empty!(STALLED_ROBOTS[]); nothing)

"""
    soc_speed_factor(node) -> Float64

Motion-layer battery gate (installed as route_planning.SOC_SPEED_HOOK): 0.0 if ANY physical
robot responsible for `node` (a RobotGo robot, or a TransportUnit team) is at/below the stall
threshold, else 1.0. So a flat robot's whole unit physically stops. Inert (1.0) unless stall
is enabled and a fleet exists.
"""
# 모션 계층 배터리 게이트: node 를 맡은 로봇 중 하나라도 정지 임계 이하면 0.0(그 유닛 전체가 물리적으로 멈춤), 아니면 1.0.
function soc_speed_factor(node)
    BATTERY_STALL[].enabled || return 1.0                # 정지 기능 꺼져 있으면 항상 정상속도(1.0)
    fleet = BATTERY_FLEET[]; fleet === nothing && return 1.0
    thr = BATTERY_STALL[].threshold
    for id in _responsible_robots(node)
        (haskey(fleet.soc, id) && fleet.soc[id] <= thr) && return 0.0   # 방전 로봇 포함 -> 속도 0
    end
    return 1.0
end

# route_planning.SOC_SPEED_HOOK 를 위 함수로 연결(여러 번 호출해도 안전). 정지 켜지기 전엔 무동작.
"Point route_planning.SOC_SPEED_HOOK at `soc_speed_factor` (idempotent). Inert until stall on."
install_soc_speed_hook!() = (SOC_SPEED_HOOK[] = soc_speed_factor; nothing)

# Fire the breakdown OOD for a flat robot: record the physical fault (obstacle=true leaves the
# dead body in place as a static obstacle others detour around -- the chosen semantics; clear=
# false so it stalls where it died, not teleported), then enqueue the NL so the respec loop
# runs ReplaceAgent -> nearest spare hand-off. Returns the NL, or nothing if we DELIBERATELY
# skip replacement.
#
# We only replace a flat robot that BOTH (a) still has pending work to hand off AND (b) has an
# available spare in some pool. If it has no frontier it has effectively FINISHED (nothing to
# hand off) -- the motion gate just holds it at rest. If no spare is free we also skip, rather
# than fall through to the fragile general-reassign path (which can corrupt the schedule). In
# either skip case the robot stays put (dead), which is the intended "stalled robot" semantics.
# 방전 로봇에 대해 고장 OOD 를 발동: (a) 넘길 남은 일이 있고 (b) 쓸 예비가 있을 때만 교체. 둘 중 하나라도 없으면 그냥 멈춰 둠.
function _fire_battery_stall!(env, id)
    # (a) re-stamp 인계는 넘길 배정 엣지가 필요하지만, 정체성보존 핫스왑은 그게 없어도 되므로 핫스왑이면 운반 중 정지도 허용.
    hot_swap_enabled() || (_first_pending_assignment(env, id) === nothing && return nothing)
    nearest_pool(_ood_robot_pos2d(env, id)) === nothing && return nothing  # (b) no spare available  # 근처 예비 없으면 포기
    cfg = BATTERY_STALL[]
    nl = fault_robot!(env; target = id, obstacle = cfg.obstacle, clear = cfg.clear)  # 물리 고장 기록(설정대로 견인/장애물)
    nl === nothing && return nothing
    push_ood!(nl)                                        # 자연어 사건을 큐에 -> 검증된 재명세 루프가 ReplaceAgent 수행
    return nl
end

"""
    battery_edge_multiplier(sched, v) -> Float64

Cost multiplier for an assignment edge LEAVING schedule vertex `v`, based on the SoC of the
physical robot that owns `v`. Returns 1.0 (no effect) when accounting is off, no fleet exists,
or `v`'s owner is unknown — so the MILP objective is byte-for-byte preserved by default. This is
the function `EDGE_COST_MULTIPLIER[]` is pointed at by `install_battery_objective_hook!`.
"""
# 스케줄 정점 v 에서 나가는 배정 엣지의 비용 배수 = 그 엣지 주인 로봇의 SoC 로 결정. 회계 꺼짐/주인 불명이면 1.0(목적식 불변).
function battery_edge_multiplier(sched, v)
    BATTERY_ACCOUNTING[] || return 1.0
    fleet = BATTERY_FLEET[]; fleet === nothing && return 1.0
    id = try                                             # 노드 종류를 보고 주인 로봇 찾기(실패하면 catch 로 nothing)
        node = get_node(sched, v).node
        n = node isa RobotGo || node isa RobotStart ? node :
            (node isa TransportUnitGo || node isa FormTransportUnit || node isa DepositCargo) ? node : nothing
        n === nothing ? nothing : _owner_robot(n, fleet)
    catch
        nothing
    end
    (id === nothing || !haskey(fleet.soc, id)) && return 1.0
    return _soc_multiplier(fleet.soc[id])                # 주인 SoC -> 비용 배수
end

# The single physical robot to charge an edge to. For a team, use its WORST member (so a team
# containing a degraded robot is de-prioritized as a whole) — matches the wear-leveling intent.
# 엣지 비용을 물릴 물리 로봇 한 대. 팀이면 "가장 나쁜(최저 SoC) 멤버" 기준 -> 열화 멤버 포함 팀 전체가 후순위(마모 균등화 의도).
function _owner_robot(node, fleet::BatteryFleet)
    if node isa RobotGo || node isa RobotStart
        return node_id(entity(node))
    else
        members = [id for id in keys(robot_team(node)) if haskey(fleet.soc, id)]
        isempty(members) && return nothing
        return argmin(id -> fleet.soc[id], members)      # SoC 최소 멤버
    end
end

"""
    install_battery_objective_hook!()

Point `essential_tg_coponents.EDGE_COST_MULTIPLIER` at `battery_edge_multiplier`, so every
(re)formulated MILP scales per-edge energy by the owning robot's SoC. Idempotent. Call once after
`init_battery_fleet!`. Removing the hook: `EDGE_COST_MULTIPLIER[] = nothing`.
"""
# MILP 목적식의 엣지 비용 배수 훅을 battery_edge_multiplier 로 연결. init_battery_fleet! 뒤 한 번 호출. 여러 번 호출해도 안전.
function install_battery_objective_hook!()
    EDGE_COST_MULTIPLIER[] = battery_edge_multiplier
    return nothing
end

"""
    install_battery_step_hook!()

Point `route_planning.BATTERY_STEP_HOOK` at `account_battery_step!`, so step_environment! debits
each robot's battery every step. Idempotent. Removing: `BATTERY_STEP_HOOK[] = nothing`.
"""
# step_environment! 의 매-스텝 훅을 account_battery_step! 로 연결(매 스텝 배터리 깎기). 여러 번 호출해도 안전.
function install_battery_step_hook!()
    BATTERY_STEP_HOOK[] = account_battery_step!
    return nothing
end

"""
    enable_battery!(env; params=BatteryParams(), soc0=1.0, objective=true, step=true) -> BatteryFleet

One call to turn the whole battery layer on: init the fleet, and install the per-step accounting
hook (`step`) and the SoC-aware objective-bias hook (`objective`). Returns the fleet.
"""
# 배터리 계층 전체를 한 번에 켜기: 함대 초기화 + 스텝 훅 + SoC 편향 목적식 훅 설치. 정지 게이트는 깔아만 두고(무동작) 대기.
function enable_battery!(env; params::BatteryParams=BatteryParams(), soc0::Float64=1.0,
        objective::Bool=true, step::Bool=true)
    fleet = init_battery_fleet!(env; params=params, soc0=soc0)
    step      && install_battery_step_hook!()            # step 참이면 매-스텝 회계 훅 설치
    objective && install_battery_objective_hook!()       # objective 참이면 SoC 편향 목적식 훅 설치
    install_soc_speed_hook!()   # motion gate; inert until set_battery_stall!(enabled=true)
    return fleet
end

"""
    rebalance_for_battery!(env; optimizer=_respec_optimizer()) -> Symbol

Re-solve the REMAINING schedule with the SoC-biased energy objective in force, so work is
re-routed away from low-SoC robots — the energy-aware response to a battery-health OOD that needs
NO LLM and NO new DSL kind (the existing `EDGE_COST_MULTIPLIER` hook does the biasing). Freezes
completed/active work via `build_invariant`, re-formulates with NO extra constraints (just the
re-priced edges), and commits on success. Returns `:rebalanced`, `:infeasible`, or `:commit_failed`.
Call after a battery OOD (or whenever `min_soc` crosses a threshold). Requires the objective hook
installed and a non-zero efficiency weight (`set_planning_objective_weights!`).
"""
# 남은 스케줄을 SoC 편향 목적식으로 다시 풀어 잔량 낮은 로봇에서 일을 덜어냄 = LLM/새 DSL 없이 되는 에너지 대응.
# 완료/진행 중 작업은 build_invariant 로 얼리고, 추가 제약 없이(비용만 재가격) 재정식화 후 성공하면 커밋.
function rebalance_for_battery!(env; optimizer=_respec_optimizer())
    inv = build_invariant(env)                           # 이미 한/하는 일은 고정(frozen)
    milp = formulate_milp(SparseAdjacencyMILP(), env.sched, env.scene_tree;
        optimizer=optimizer, t0_=inv.frozen_t0, tF_=inv.frozen_tF)   # extra_constraints=nothing
    optimize!(milp)
    primal_status(milp) != MOI.FEASIBLE_POINT && return :infeasible   # 해가 없으면 실패
    ok = commit_respec!(env, milp,
        RespecProposal(ConstraintSpec[], "battery rebalance", "battery-OOD"); resume=true)
    return ok === false ? :commit_failed : :rebalanced   # 결과 심볼 반환
end

# --- (c) metric wiring: battery_report -> compute_metrics kwargs -----------------
"""
    battery_metrics_kwargs(fleet=BATTERY_FLEET[]) -> NamedTuple

Pull the battery axis-fields out of a fleet in the exact keyword shape `compute_metrics` /
`metrics_from_schedule` accept: `(energy=…, min_soc=…, soc_spread=…)`. Splat it in:
    metrics_from_schedule(sched; …, battery_metrics_kwargs()...)
Returns all-NaN when no fleet exists, so callers stay battery-agnostic. (battery.jl depends on
metrics.jl, never the reverse — keep this helper here, not in metrics.jl.)
"""
# battery_report 에서 배터리 축 값만 뽑아 compute_metrics 가 받는 키워드 모양으로 반환. 함대 없으면 전부 NaN(호출자 무관심 유지).
function battery_metrics_kwargs(fleet=BATTERY_FLEET[])
    fleet === nothing && return (energy = NaN, min_soc = NaN, soc_spread = NaN)
    r = battery_report(fleet)
    return (energy = r.total_energy_J, min_soc = r.min_soc, soc_spread = r.soc_spread)
end
