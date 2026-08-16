# =============================================================================
#  battery_courier.jl -- SwapBattery 를 "물리적 배송"으로 만드는 계층
# -----------------------------------------------------------------------------
#  왜 이 파일이 생겼나 (2026-08-15 진단)
#  ---------------------------------------------------------------------------
#  `swap_battery!`(replace_robot.jl) 은 **장부 조작만** 했다: 같은 시뮬레이션 스텝 안에서
#  `fleet.soc[role] = 1.0` 을 찍고 stall 게이트를 열고 끝났다. 귀결이 둘이었다.
#
#   (1) 화면에서 **아무 일도 일어나지 않는다.** 방전 상태로 존재하는 프레임이 하나도 없어서
#       `render_tools.BATTERY_TINT_HOLD_FRAMES` 라는 **순수 연출용 hold** 로 빨강을 몇 프레임
#       붙잡아야 했다(그 상수의 docstring 이 그 사정을 적어 두었다). 즉 관객이 본 "빨강 깜박임"
#       은 사건이 아니라 사건이 없다는 것을 가리려던 표시였다.
#   (2) 배터리를 **누가 가져다 주는가**가 모델에 없다. 어휘상 SwapBattery 는 "창고 본체를 안
#       먹는다"(배터리는 unmetered)는 뜻이었는데, 그것이 "아무 자원도, 아무 시간도 안 든다"로
#       구현돼 있었다. 그래서 SwapBattery 는 언제나 공짜였고 Replace 와의 비교가 성립하지 않았다.
#
#  이 파일은 (1)(2)를 같이 고친다. SwapBattery 를 고르면 **가장 가까운 창고(depot)의 예비 로봇이
#  배터리를 들고 현장까지 주행**하고, 도착한 순간에 비로소 교체가 적용되며, 그 뒤 자기 슬롯으로
#  돌아가 자동 충전된다. 그동안 방전 로봇은 진짜로 방전 상태이므로 화면이 **연출 없이** 빨갛다.
#
#  자원 회계는 어휘의 뜻을 그대로 지킨다:
#   · 배터리는 **무한**이다 — 재고를 세지 않는다.
#   · 배송 로봇은 **빌려 쓰고 돌려준다** — `pop_spare!` 로 소비하지 않으므로 창고 재고
#     (`depot_available`)가 줄지 않는다. 그래서 ReplaceAgent 가 먹는 "창고 본체"라는 희소자원과
#     여전히 장부가 분리돼 있다. 드는 비용은 **시간과 라인 정지**이지 재고가 아니다.
#   · 창고에 주차된 예비는 `account_battery_step!` 의 `parked` 집합에 들어 있어 방전하지 않는다
#     (= 자동 충전). 배송 로봇은 풀에 등록된 채로 나가므로 그 성질이 그대로 유지된다.
#
#  비침습(non-invasive): `BATTERY_COURIER_CFG[].enabled` 가 false 인 동안 이 파일의 모든 훅은
#  무동작이고 `swap_battery!` 는 예전 경로(즉시 교체) 그대로다. 데모/시뮬레이터가
#  `set_battery_courier!(enabled=true)` 로 명시적으로 켠다.
#
#  문법 참고:
#   · Base.@kwdef struct : 필드 기본값을 주는 구조체 정의 매크로.
#   · Ref(x) / X[] : 전역 가변 "상자". 이 저장소가 모듈 전역 상태를 담는 관용구(SPARE_POOLS 와 동형).
#   · `A === nothing && return B` = A 가 nothing 이면 즉시 B 반환(가드 절).
#   · `!` 접미사 = 인자/전역 상태를 직접 바꾼다는 관례.
# =============================================================================

# ---------------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------------
"""
배터리 배송(courier) 설정.

- `enabled`    : 켜기/끄기. false 면 `swap_battery!` 는 예전처럼 즉시 교체한다(바이트 동일).
- `speed`      : 배송 로봇 주행속도 [m/s]. `<= 0` 이면 RVO 기본 최대속도를 쓴다.
- `arrive_r`   : 도착 판정 반경 [m]. `<= 0` 이면 로봇 반지름의 2.5배.
- `halt_build` : 배터리 교체가 **적용되기 전까지** 라인(주행)을 세울지. 요구사항 ③.
"""
Base.@kwdef struct BatteryCourierConfig
    enabled::Bool     = false
    speed::Float64    = 0.0
    arrive_r::Float64 = 0.0
    halt_build::Bool  = true
end

const BATTERY_COURIER_CFG = Ref(BatteryCourierConfig())

"""
    set_battery_courier!(; enabled=true, speed=0.0, arrive_r=0.0, halt_build=true)

배터리 배송 계층을 켜고 설정한다. 켜면 `SwapBattery` 는 즉시 회복이 아니라
**창고 예비 로봇의 왕복 배송**이 된다(`dispatch_battery_courier!` → `battery_courier_step!`).
"""
set_battery_courier!(; enabled::Bool = true, speed::Real = 0.0,
                       arrive_r::Real = 0.0, halt_build::Bool = true) =
    (BATTERY_COURIER_CFG[] = BatteryCourierConfig(; enabled = enabled,
        speed = Float64(speed), arrive_r = Float64(arrive_r), halt_build = halt_build); nothing)

battery_courier_enabled() = BATTERY_COURIER_CFG[].enabled

# ---------------------------------------------------------------------------------
# 상태 — 진행 중인 배송들
# ---------------------------------------------------------------------------------
"""
진행 중인 배터리 배송 한 건.

- `target`  : 방전되어 교체를 기다리는 로봇(이 로봇이 화면에서 빨갛다).
- `courier` : 배송을 맡은 창고 예비 로봇(화면에서 초록).
- `depot`   : 어느 방위 창고에서 나왔나.
- `home`    : 돌아가 설 주차 슬롯 좌표.
- `phase`   : `:outbound`(가는 중, 라인 정지) → `:returning`(교체 완료, 복귀 중).
- `goal`    : 이번 스텝의 목표점(주행 훅이 갱신 — `station_keeping_goal` 이 읽는다).
"""
mutable struct BatteryDelivery
    target::AbstractID
    courier::AbstractID
    depot::Symbol
    home::Vector{Float64}
    phase::Symbol
    goal::Vector{Float64}
    step_out::Int
    step_swap::Int
end

# courier id -> 배송. courier 를 키로 두는 이유: 주행 훅과 렌더가 "이 로봇이 배송 중인가"를
# 물어보는 쪽이라 그 조회가 O(1) 이어야 한다. target 조회는 건수가 한 자리라 선형 스캔으로 족하다.
const BATTERY_DELIVERIES = Ref(Dict{AbstractID,BatteryDelivery}())

battery_deliveries() = BATTERY_DELIVERIES[]
clear_battery_deliveries!() = (empty!(BATTERY_DELIVERIES[]); nothing)

"`rid` 가 지금 배터리를 배송 중인 창고 예비 로봇인가(→ 화면에서 초록)."
is_battery_courier(rid) = haskey(BATTERY_DELIVERIES[], rid)

"`rid` 가 배송 로봇을 **기다리는 중**인 방전 로봇인가(→ 화면에서 빨강 유지 + 그 자리에 정지)."
awaiting_battery_swap(rid) =
    any(d -> d.phase === :outbound && d.target == rid, values(BATTERY_DELIVERIES[]))

"아직 적용되지 않은 배터리 교체가 하나라도 있는가(= 라인 정지 조건)."
battery_swap_pending() = any(d -> d.phase === :outbound, values(BATTERY_DELIVERIES[]))

"라인을 지금 세워야 하는가 = 설정이 켜져 있고 && 미적용 교체가 있다. `soc_speed_factor` 가 읽는다."
battery_swap_halt_active() =
    BATTERY_COURIER_CFG[].halt_build && battery_swap_pending()

"""
    courier_goal(rid) -> Union{Vector{Float64},Nothing}

`rid` 가 배송 중이면 이번 스텝의 목표점, 아니면 `nothing`.
`station_keeping_goal`(ood_injection.jl)이 이것을 **먼저** 본다 — 안 그러면 배송 로봇이
자기 주차 슬롯으로 계속 끌려가 창고를 못 떠난다.
"""
function courier_goal(rid)
    d = get(BATTERY_DELIVERIES[], rid, nothing)
    d === nothing && return nothing
    return d.goal
end

# ---------------------------------------------------------------------------------
# 파견
# ---------------------------------------------------------------------------------
# 이 풀에서 "아직 배송 중이 아닌" 예비를 하나 고른다(꺼내지 않는다 — 빌려 쓰고 돌려주므로 재고 불변).
function _free_courier_in(key::Symbol)
    v = get(SPARE_POOLS[], key, RobotID[])
    for rid in Iterators.reverse(v)                 # LIFO — pop_spare! 와 같은 순서 감각
        is_battery_courier(rid) || return rid
    end
    return nothing
end

# 가장 가까운 창고부터 훑어 배송 가능한 예비가 있는 첫 창고를 고른다.
# `nearest_pool` 은 "가장 가까운 하나"만 주므로, 그 창고의 예비가 전부 이미 배송 중이면
# 사건이 조용히 불발한다 — 여기서는 거리순으로 전부 본다.
function _nearest_courier_depot(pos)
    p = Float64[pos[1], pos[2]]
    best = nothing; bestd = Inf; bestrid = nothing
    for (key, c) in SPARE_POOL_CENTERS[]
        rid = _free_courier_in(key)
        rid === nothing && continue
        d = norm(p .- c[1:2])
        if d < bestd
            bestd = d; best = key; bestrid = rid
        end
    end
    return best === nothing ? nothing : (depot = best, courier = bestrid)
end

"""
    dispatch_battery_courier!(env, target) -> Union{BatteryDelivery,Nothing}

`target` 에게 배터리를 가져다 줄 창고 예비 로봇을 파견한다. 이미 파견돼 있으면 그 배송을
그대로 돌려준다(중복 파견 없음). 배송 가능한 예비가 한 대도 없으면 `nothing`
— 호출자(`swap_battery!`)는 그때 예전 경로(현장 즉시 교체)로 떨어져 빌드가 절대 막히지 않는다.
"""
function dispatch_battery_courier!(env, target::AbstractID)
    # 같은 로봇에 대한 배송이 이미 떠 있으면 그것을 재사용한다.
    for d in values(BATTERY_DELIVERIES[])
        d.target == target && return d
    end
    tpos = _robot_scene_pos2d(env, target)
    pick = _nearest_courier_depot(tpos)
    pick === nothing && return nothing
    cid  = pick.courier
    home = Vector{Float64}(get(SPARE_SLOTS[], cid,
                               get(SPARE_POOL_CENTERS[], pick.depot, tpos))[1:2])
    d = BatteryDelivery(target, cid, pick.depot, home, :outbound,
                        Vector{Float64}(tpos), _current_sim_step(), -1)
    BATTERY_DELIVERIES[][cid] = d
    return d
end

# 배송을 마치고 창고에 도킹한 로봇을 만충으로 되돌린다(= 창고 자동 충전).
# 사실 배송 로봇은 `parked` 취급이라 나가 있는 동안에도 방전하지 않지만, "창고에서 자동 충전된다"
# 는 모델의 약속을 장부에도 명시적으로 남긴다 — 나중에 배송에 소모를 물리게 되면 이 줄이 그 회복점이다.
function _recharge_docked_courier!(rid)
    isdefined(@__MODULE__, :BATTERY_FLEET) || return nothing
    fleet = BATTERY_FLEET[]
    fleet === nothing && return nothing
    haskey(fleet.soc, rid) || return nothing
    fleet.soc[rid] = 1.0
    isdefined(@__MODULE__, :BatteryFleet) && delete!(fleet.depleted, rid)
    return nothing
end

# ---------------------------------------------------------------------------------
# 매 스텝 주행 훅
# ---------------------------------------------------------------------------------
"""
    battery_courier_step!(env) -> nothing

진행 중인 배송들을 한 스텝 전진시킨다. `step_environment!`(route_planning.jl)이
RVO→씬트리 동기화 **뒤에** 부른다. 배송이 없으면 즉시 반환하므로 평소 실행엔 영향이 없다.

주행은 **기구학적**이다 — 목표점을 향해 일정 속도로 위치를 직접 적분하고
`_rehome_robot!` 로 RVO 에이전트와 씬 몸체를 함께 옮긴다. 계획기/RVO 를 태우지 않는 이유:
  · 라인 정지(`halt_build`)가 `max_speed` 를 0 으로 만들기 때문에 RVO 주행에 얹으면 배송 로봇도
    같이 얼어붙는다 — 정지시킨 장본인이 못 움직이는 교착이 된다.
  · 예비 로봇의 `RobotGo` 는 이미 목표에 서 있어(`is_goal`) 선호속도가 0 으로 잡히는 경로라,
    계획기 쪽으로는 애초에 구동되지 않는다.
RVO 위치를 같이 갱신하므로 **다른 로봇들은 배송 로봇을 정상적으로 피한다.**
"""
function battery_courier_step!(env)
    battery_courier_enabled() || return nothing
    ds = BATTERY_DELIVERIES[]
    isempty(ds) && return nothing

    cfg = BATTERY_COURIER_CFG[]
    v   = cfg.speed > 0.0 ? cfg.speed : (try Float64(rvo_default_max_speed()) catch; 4.0 end)
    rr  = try Float64(default_robot_radius()) catch; 0.5 end
    arr = cfg.arrive_r > 0.0 ? cfg.arrive_r : 2.5 * rr
    dt  = try Float64(env.dt) catch; 1.0 / 40.0 end

    for (cid, d) in collect(pairs(ds))              # collect: 순회 중 삭제해도 안전하게
        cpos = _robot_scene_pos2d(env, cid)
        # 목표는 매 스텝 다시 읽는다 — 방전 로봇은 서 있지만, 복귀 슬롯과 달리 위치가
        # 다른 복구(예: Replace 로 re-home)에 의해 바뀔 수 있다.
        goal = d.phase === :outbound ? _robot_scene_pos2d(env, d.target) : d.home
        d.goal = Vector{Float64}(goal)
        Δ = Float64[goal[1] - cpos[1], goal[2] - cpos[2]]
        dist = norm(Δ)
        if dist <= arr
            if d.phase === :outbound
                # ★ 여기가 진짜 SwapBattery 다 — 배송 로봇이 도착한 순간에만 적용된다.
                _apply_battery_swap!(env, d.target; courier = cid, verbose = true)
                d.phase = :returning
                d.step_swap = _current_sim_step()
                @info "[COURIER] spare $(cid) reached R$(get_id(d.target)) — battery swapped; returning to :$(d.depot) depot."
            else
                _recharge_docked_courier!(cid)
                delete!(ds, cid)
                @info "[COURIER] spare $(cid) docked back at :$(d.depot) depot (recharging; inventory unchanged)."
            end
        else
            stepd = min(dist, v * dt)
            _rehome_robot!(env, cid, (cpos[1] + Δ[1] / dist * stepd,
                                      cpos[2] + Δ[2] / dist * stepd))
        end
    end
    return nothing
end
