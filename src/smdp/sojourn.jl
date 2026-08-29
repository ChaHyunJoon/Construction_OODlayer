# =============================================================================
# sojourn.jl — spec §5-3. **dt 루프가 없다.**
#
# 두 종류의 시각을 구분한다(spec §2-4):
#   decision epoch  = 실패 도착. 행동 선택이 있다. 이 파일이 돌려주는 것.
#   rate boundary   = 다음 노드 완료. 행동 선택이 **없다**. 이 루프 안에만 있다.
#
# 경쟁위험 **셋**: break(로봇별) · cell(로봇별) · zone(전역). 합치지 않는다 —
# `hazard_step!`(hazard.jl:497-509)이 셋을 **독립적으로** 검사하고, 그 자리 주석이 예전에
# 둘을 `elseif` 로 묶었다가 "우선순위 큐"가 되어 버렸던 사고를 직접 기록하고 있다.
#
# 🔴 **호출 규약(T7 리뷰에서 이관)**: 모드는 언제나 `modes_of`(배치, 함대에 선형)로 한 번에
#    받는다. `mode_of` 를 로봇별 루프에서 부르면 배치 경로가 호출 지점에서 이차로 되돌아간다.
#    이 파일의 어느 루프에도 `mode_of` 가 없다 — 있으면 그것이 회귀다.
#    `rate_params`(derive.jl)와의 동치는 `test/smdp_derive.jl` 의 "rate_params 가 mode_of 와
#    같은 모드를 쓴다" testset 이 이미 못박는다(`rp[k] == rate_params_one(...)`). 여기서는
#    `modes_of` 를 **경계당 한 번** 부르고 그 결과를 rates · cell · 필드전진 셋이 나눠 쓴다.
#
# 🔴 **조용한 폴백 금지**: 함대에 없는 로봇 · 비유한 rate · 음수 소저너는 전부 `error()`.
#    `τ` 는 모든 반환 지점에서 `_ret` 를 통과한다(사후조건을 한 자리에 모은다).
#
# 🔴 **`T_plan_next == Inf` 의 계약**(T8 이 복원, tplan.jl:113): `Inf` ⟺ 남은 계획 작업의
#    소요시간이 전부 0 ⟺ `T_done == 0`. 이 파일은 **적분 상한으로 `Inf` 를 쓰지 않는다** —
#    `dur == 0` 인 활성 정점은 계획상 시간을 쓰지 않으므로 `_drain_zero_frontier!` 가
#    **시간 0 으로** 먼저 닫는다. 그래서 아래 루프가 `T_plan_next` 를 부르는 시점에는 활성
#    프론티어에 `dur > 0` 인 정점이 반드시 하나 이상 있고, 주 경로가 유한값을 낸다.
#    ⚠️ 그 결과 `T_plan_next` 의 `_zero_frontier_fallback` 가지는 **이 호출자에게는** 도달
#    불가다. 그 가지는 `T_plan_next` 자신의 불변식(`≤ T_done`)을 위한 것이고, 소저너는 같은
#    자리를 **드레인**으로 지나간다. 둘 중 어느 쪽도 죽은 코드가 아니다.
# =============================================================================

# Exp(1) 문턱. 🔴 엔진의 `_exp1`(hazard.jl:203) **그 자체**를 쓴다 — 복사본을 두면
# `rand == 0` 하한 처리가 두 레인에서 갈린다(엔진은 `max(rand, 1e-12)`).
_exp1_draw(rng) = _exp1(rng)

const _SOJ_TOL = 1e-9      # 경계 비교의 수치 여유. 시간 단위[s]

"""
    DRAIN_DT :: Ref{Float64}

**`dur == 0` 프론티어를 닫는 데 경량 레인이 쓰는 시뮬 시간[s].** 기본 `0.0` = T9 의 동작
그대로(= 선언된 근사: 계획상 시간을 안 쓰는 정점이므로 시간 0 으로 닫는다).

🔴 **이것은 ρ 와 독립인 두 번째 손잡이이고, 그것이 존재 이유의 전부다**(Task T10).
T9 보고서 §5-1 이 실측으로 남긴 문제: N-G1 의 격차를 만드는 기전이 최소 둘인데
(ρ 가 흡수하는 **rate boundary 편향**, 그리고 이 **드레인의 시간 비용**) 둘 다 부호가 같아서
("경량이 스케줄을 앞질러 나간다") **ρ 스윕만으로는 갈리지 않는다.** `RHO[]` 와 이 `Ref` 를
**따로** 흔들면 2×2 요인설계가 되고, 그때 비로소 각 기전의 몫을 분해할 수 있다.

값의 뜻: 엔진은 `dur == 0` 인 정점도 스텝 경계에서 닫으므로 **최소 `dt_sim`** 을 쓴다.
그래서 자연스러운 프로브 값은 `dt_sim`(= `env.dt * bp.seconds_per_step` = 0.025 s)이다.

⚠️ **기본값을 바꾸지 않는다.** 이 값을 N-G1 이 통과할 때까지 올리는 것은 ρ 를 그렇게 하는
것과 **같은 종류의 잘못**이다 — 게이트가 판정하기로 되어 있는 오차를 손잡이가 흡수한다.
프로브는 **재는** 도구이지 고치는 도구가 아니다.

> `DRAIN_DT[] > 0` 일 때 드레인은 길이 `DRAIN_DT[]` 의 **작은 rate boundary 하나**처럼
> 취급된다: 그 구간 안에서 위험이 먼저 오면 그 사건을 돌려주고, 아니면 문턱을 그만큼
> 소진하고 필드를 전진시킨 뒤 정점을 닫는다. `n_boundary` 에는 세지 않는다(계획상 경계가
> 아니다) — `sample_sojourn_probe` 가 `n_drain` 으로 따로 센다.
"""
const DRAIN_DT = Ref(0.0)

# --- 사건 인코딩 --------------------------------------------------------------
"""
    event_kind(ev::Tuple{Symbol,Any}) -> Symbol

`sample_sojourn` 이 낸 사건의 **종류** — `:break | :cell | :zone | :terminal | :horizon`.
게이트 N-G1 이 두 레인의 종류 집합을 비교할 때 쓰는 유일한 접근자다(이슈 D).
"""
function event_kind(ev::Tuple{Symbol,Any})
    ev[1] === :terminal && return :terminal
    ev[1] === :horizon  && return :horizon
    ev[1] === :failure  || error("event_kind: 알 수 없는 사건 $(ev) — 조용히 넘어가지 않는다")
    w = ev[2]
    w isa Int                        && return :break
    (w isa Tuple && length(w) == 2 && w[1] === :cell) && return :cell
    w === :zone                      && return :zone
    error("event_kind: 알 수 없는 failure payload $(w)")
end

"""
    event_robot_key(ev) -> Union{Nothing,Int}

사건의 대상 로봇 키(`s.fleet` 의 정수 키). `zone`·`terminal`·`horizon` 은 `nothing`.
"""
function event_robot_key(ev::Tuple{Symbol,Any})
    ev[1] === :failure || return nothing
    w = ev[2]
    w isa Int && return w
    (w isa Tuple && length(w) == 2 && w[1] === :cell) && return w[2]::Int
    w === :zone && return nothing
    error("event_robot_key: 알 수 없는 failure payload $(w)")
end

"""
    event_robot(ev) -> Union{Nothing,RobotID}

`event_robot_key` 를 **살아 있는 함대의 `RobotID`** 로 되돌린다(이슈 C).
`apply_action!` → `action_to_proposal` 이 진짜 `RobotID` 를 요구하므로, 소비처가
`RobotID(k)` 를 손으로 만들지 않게 하는 것이 이 함수의 존재 이유다.
"""
function event_robot(ev::Tuple{Symbol,Any})
    k = event_robot_key(ev)
    return k === nothing ? nothing : robot_id_of(k)
end

# --- 전진 --------------------------------------------------------------------
"""로봇마다 usage/soc 를 Δ 만큼 굴린 새 `s`. 노드는 닫지 않는다.
`modes` 는 **호출자가 `modes_of` 로 한 번에 받아 온 것**이다(로봇별 `mode_of` 금지)."""
function _advance_fields(s::SimState, Δ::Float64, bp::BatteryParams, modes::Dict{Int,Symbol})
    cap = Float64(bp.capacity_J)
    cap > 0 || error("_advance_fields: capacity_J = $(cap) — 양수여야 한다")
    fleet = Dict{Int,RobotRec}()
    for k in sort!(collect(keys(s.fleet)))
        r = s.fleet[k]
        haskey(modes, k) ||
            error("_advance_fields: 로봇 $(k) 의 모드가 없다 — modes_of 가 s.fleet 전원을 " *
                  "덮지 않았다. :idle 로 떨어뜨리지 않는다")
        m = modes[k]
        fleet[k] = RobotRec(soc     = clamp(r.soc - mode_power_W(bp, m) * Δ / cap, 0.0, 1.0),
                            usage_s = r.usage_s + (m === :idle ? 0.0 : Δ))
    end
    return SimState(g = s.g, geo = s.geo, fleet = fleet, prog = s.prog)
end

"""
    advance_to(s, env, Δ, bp) -> SimState

rate boundary 를 **넘지 않는** 전진. `Δ > T_plan_next(s, env)` 면 **죽는다** — 조용히 넘어가면
닫혀야 할 노드가 안 닫힌 채 시간만 흐르고, 그 뒤 모든 λ 가 틀린 모드에서 계산된다.

⚠️ `sample_sojourn` 은 경계를 넘을 때 `_cross_boundary` 를 쓰고 이 함수를 부르지 않는다.
소비처는 `generative.jl` 의 `_advance_over` 와 `test/smdp_sojourn.jl` 이다 — 그 둘이 없어지면
**이 함수도 은퇴시킬 것.** 소비처 없는 API 를 계약만 지킨 채 남겨 두면 다음 세대가 "누군가
쓰겠지" 로 읽는다.
"""
function advance_to(s::SimState, env, Δ::Float64, bp::BatteryParams)
    (isfinite(Δ) && Δ >= 0.0) ||
        error("advance_to: Δ = $(Δ) — 유한한 비음수여야 한다(0 으로 clamp 하지 않는다)")
    b = T_plan_next(s, env)
    Δ <= b + _SOJ_TOL ||
        error("advance_to: Δ=$(Δ) 가 rate boundary $(b) 를 넘는다 — 넘어가면 그 뒤의 λ 가 " *
              "틀린 모드에서 계산된다")
    return _advance_fields(s, Δ, bp, modes_of(s, env))
end

"""
    advance_to_rate_boundary(s, env, Δ, bp) -> SimState

경계까지 가서 **그 경계까지 계획상 끝나는 활성 정점을 전부 닫는다**(`ρ·dur ≤ Δ`).
후행 정점의 활성화는 `active_of` 가 자동으로 한다(파생값이라 따로 열 것이 없다 — spec §2-3 (a)).

🔴 **전진의 정의는 "닫힌 노드가 늘었다" 가 아니라 "`dur > 0` 인 노드가 닫혔다" 다.**
`dur == 0` 인 활성 정점은 `ρ·0 ≤ Δ` 라 **어떤 Δ 에도** 걸린다 — 그것만으로 전진을 인정하면
아무리 작은 Δ 도 통과하는 항진명제가 되고, 소저너가 시간을 사고도 아무것도 못 사는 구간을
무한히 반복한다. 그래서 둘을 나눠 센다.
⚠️ 반대로 `dur == 0` 인 정점을 **닫지 않으면**(`d > 0.0 &&` 가드) 그 정점이 영원히 활성으로
남아 후행 전체가 막힌다.

프론티어에 `dur > 0` 인 정점이 **하나도 없는** 경우(= `T_plan_next` 가 폴백을 타는 자리)는
이 함수가 아니라 `_close_vertices` 가 **시간 0 으로** 처리한다. `sample_sojourn` 의 루프
머리를 볼 것.
"""
function advance_to_rate_boundary(s::SimState, env, Δ::Float64, bp::BatteryParams)
    act, durs = _active_with_durations(s, env)
    return _cross_boundary(s, act, durs, Δ, bp, modes_of(s, env))
end

"활성 정점과 그 계획 소요시간을 **한 번에** 낸다(정렬됨). 소저너 루프가 이걸 재사용한다."
function _active_with_durations(s::SimState, env)
    act  = sort!(collect(active_of(s)))                  # Set 순회 순서를 안 믿는다
    durs = Float64[node_duration(env, v) for v in act]   # 스케줄 밖 정점은 여기서 죽는다
    return act, durs
end

"닫힌 집합에 `vs` 를 더한 새 `s`. **필드는 그대로** — 시간이 안 흘렀다는 뜻이다."
function _close_vertices(s::SimState, vs)
    closed = copy(s.prog.closed)
    for v in vs; push!(closed, v); end
    return SimState(g = s.g, geo = s.geo, fleet = s.fleet, prog = ProgBlock(closed = closed))
end

"경계 넘기의 알맹이. `act`/`durs`/`modes` 를 호출자가 이미 갖고 있으면 그것을 그대로 쓴다."
function _cross_boundary(s::SimState, act::Vector{Int}, durs::Vector{Float64},
                         Δ::Float64, bp::BatteryParams, modes::Dict{Int,Symbol})
    (isfinite(Δ) && Δ > 0.0) ||
        error("advance_to_rate_boundary: Δ = $(Δ) — 유한한 양수여야 한다. `Inf` 를 적분 " *
              "상한으로 쓰지 않는다(tplan.jl 의 Inf 계약)")
    s2     = _advance_fields(s, Δ, bp, modes)
    closed = copy(s.prog.closed)
    n_pos  = 0
    for (i, v) in enumerate(act)
        RHO[] * durs[i] <= Δ + _SOJ_TOL || continue
        push!(closed, v)
        durs[i] > 0.0 && (n_pos += 1)
    end
    n_pos > 0 ||
        error("advance_to_rate_boundary: Δ=$(Δ) 에서 dur>0 인 노드가 하나도 안 닫혔다 — " *
              "시간만 흐르고 전진하지 못한다")
    return SimState(g = s2.g, geo = s2.geo, fleet = s2.fleet,
                    prog = ProgBlock(closed = closed))
end

"""
    energy_between(s, env, Δ, bp) -> Float64

구간 `[0, Δ]` 의 소비 에너지 [J]. 모드가 상수인 구간이라 닫힌 형태다(spec §2-1).
`s` 의 모드를 쓴다 — 구간 내내 그 모드였기 때문이다.

⚠️ `mode_power_W` 의 선언된 근사(`team = 1, m_payload = 0, speed = v_ref`)를 그대로 물려받는다.
실측 잔차는 `test/smdp_derive.jl` 의 "T7 잔차 (A)" 가 매 실행 찍는다(집계 과대추정).
게이트 **N-G5** 가 그 크기를 판정한다 — N-G1 의 숫자로 재지 말 것(rates.jl 의 분리비 참조).
"""
function energy_between(s::SimState, env, Δ::Float64, bp::BatteryParams)
    (isfinite(Δ) && Δ >= 0.0) ||
        error("energy_between: Δ = $(Δ) — 유한한 비음수여야 한다(음수를 0 으로 접지 않는다)")
    Δ == 0.0 && return 0.0
    modes = modes_of(s, env)             # 🔴 배치 한 번. 로봇별 mode_of 금지
    tot = 0.0
    for k in sort!(collect(keys(s.fleet)))
        haskey(modes, k) || error("energy_between: 로봇 $(k) 의 모드가 없다")
        tot += mode_power_W(bp, modes[k])
    end
    tot += bp.idle_W * _n_charged_outside_fleet(s)   # 아래 참조 (T12 리뷰 Important 1)
    return tot * Δ
end

"""
    _n_charged_outside_fleet(s::SimState) -> Int

**엔진이 대기전력을 부과하는데 `s.fleet` 에는 없는 로봇 수.** 실질적으로 = 고장 로봇 수.

🔴 **왜 이게 필요한가 (T12 리뷰 Important 1, 이 세션이 독립 확인).** 두 모집단이 다르다:

| | 정의 | 코드 |
|---|---|---|
| 엔진이 과금하는 집합 | `keys(fleet.soc) \\ parked` | `battery.jl:242-246` |
| `s.fleet` | `keys(fleet.soc) \\ _hz_excluded()` | `simstate_of` (spec §2-4) |

`parked = active_spares() ∪ checked_out_spares()` 이고
`_hz_excluded() = parked ∪ keys(faulted_robots())` 이므로 **차집합이 정확히 고장 로봇**이다.
그리고 그 상태는 `Replace` 가 치울 때까지 지속되므로, 고치지 않으면 **고장 발생 ~ Replace
사이의 모든 전이가 `idle_W × |고장| × Δ` 만큼 에너지를 과소계상한다.**

⚠️ 이건 **근사가 아니라 모집단 정의 불일치**다 — 런타임에 정확히 셀 수 있으므로 허용오차로
덮지 않는다. (`mode_power_W` 의 `team=1, m_payload=0, speed=v_ref` 기본값은 **선언된 근사**라
별개다. T7 잔차 (A) 가 그 크기를 재고, 게이트 N-G5c 가 그것을 진단으로 다룬다 —
`briefs/task-T14-ng5-redefinition.md`.)

🔴 **델타를 덧붙이지 않고 엔진과 같은 방식으로 유도한다.** "고장 로봇을 더한다"로 적으면
`_hz_excluded()` 의 구성이 바뀌는 날 조용히 갈린다. 여기서는 두 집합의 **크기 차**를 직접 재고,
음수가 나오면(= 두 정의가 예상 밖 방향으로 어긋남) **죽는다**.

`BATTERY_FLEET[]` 가 없으면 0 이다 — 함대가 없으면 엔진도 아무에게도 과금하지 않는다.
"""
function _n_charged_outside_fleet(s::SimState)
    fleet = BATTERY_FLEET[]
    fleet === nothing && return 0
    parked = Set{Any}()
    try union!(parked, active_spares())      catch; end
    try union!(parked, checked_out_spares()) catch; end
    n_charged = count(id -> !(id in parked), keys(fleet.soc))
    n_extra   = n_charged - length(s.fleet)
    n_extra >= 0 || error(
        "energy_between: 엔진 과금 집합($(n_charged))이 s.fleet($(length(s.fleet)))보다 작다 — " *
        "`_hz_excluded()` 와 `battery.jl` 의 parked 정의가 예상 밖 방향으로 어긋났다. " *
        "0 으로 접지 않는다")
    return n_extra
end

# --- 표집 --------------------------------------------------------------------
"""λ_cell 의 지수 계수 `a_c`. `rate_params_one` 의 `a` 에서 **soc 항을 뺀 것**이다 —
셀 열화는 마모(usage)만의 함수이고 soc 는 결과지 원인이 아니기 때문(`_cell_rate` 의 주석)."""
_cell_exponent(p::HazardParams, mode::Symbol) =
    (mode === :idle) ? 0.0 : (p.usage_scale_s > 0 ? p.beta_usage / p.usage_scale_s : 0.0)

"모든 반환 지점의 사후조건을 한 자리에 모은다. τ 가 음수/NaN/Inf 면 조용히 나가지 않는다."
function _ret(τ::Float64, ev::Tuple{Symbol,Any}, nb::Int, nd::Int, td::Float64)
    (isfinite(τ) && τ >= 0.0) ||
        error("sample_sojourn: τ = $(τ) (사건 $(ev)) — 유한한 비음수여야 한다. " *
              "Inf 를 소저너로 돌려주면 '실패가 안 오는 세계'를 탐색하게 된다")
    (isfinite(td) && td >= 0.0) ||
        error("sample_sojourn: 드레인 누적시간 = $(td) — 유한한 비음수여야 한다")
    td <= τ + _SOJ_TOL ||
        error("sample_sojourn: 드레인이 쓴 시간 $(td) 이 τ = $(τ) 보다 크다 — " *
              "드레인은 τ 의 부분집합이어야 한다")
    event_kind(ev)      # 인코딩이 알려진 모양인지 여기서 한 번 검증한다
    return (τ, ev, nb, nd, td)
end

"""
    _first_failure(cur, ks, modes, p, bp, cap, Eb, Ec, Ez, λz) -> (Δ, who)

지금 상태에서 **모드가 상수인 동안** 세 경쟁위험 중 가장 먼저 오는 것까지의 시간과 그 정체.
`sample_sojourn_probe` 의 주 루프와 (드레인 비용을 켰을 때의) 드레인 구간이 **같은 식**을
쓰도록 뽑아낸 것이다 — 두 자리에 같은 산술을 두 번 적으면 한쪽만 고쳐지는 날이 온다.
"""
function _first_failure(cur::SimState, ks::Vector{Int}, modes::Dict{Int,Symbol},
                        p::HazardParams, bp::BatteryParams, cap::Float64,
                        Eb::Dict{Int,Float64}, Ec::Dict{Int,Float64},
                        Ez::Float64, λz::Float64)
    Δ_fail, who = Inf, nothing
    for k in ks
        haskey(cur.fleet, k) ||
            error("sample_sojourn: 로봇 $(k) 가 s.fleet 에서 사라졌다 — 경량 레인이 " *
                  "함대를 조용히 바꾸지 않는다")
        rec  = cur.fleet[k]
        A, a = rate_params_one(p, rec, modes[k], bp, cap)   # derive.jl 의 rate_params 와 같은 식
        (isfinite(A) && isfinite(a) && A >= 0.0) ||
            error("sample_sojourn: 로봇 $(k) 의 (A, a) = ($(A), $(a)) 가 비유한/음수다 — " *
                  "조용히 Inf 로 떨어뜨리지 않는다")
        db = inv_integrated_hazard(A, a, Eb[k])
        db < Δ_fail && (Δ_fail = db; who = k)
        # cell 은 soc 를 **안 본다** — usage 만의 지수형이라 a_c = β_u/U·1[mode ≠ :idle].
        Ac = cell_rate_from(p, rec.usage_s, modes[k])
        (isfinite(Ac) && Ac >= 0.0) ||
            error("sample_sojourn: 로봇 $(k) 의 cell rate = $(Ac) 가 비유한/음수다")
        ac = _cell_exponent(p, modes[k])
        dc = inv_integrated_hazard(Ac, ac, Ec[k])
        dc < Δ_fail && (Δ_fail = dc; who = (:cell, k))
    end
    if λz > 0.0
        dz = Ez / λz                     # zone 은 상수율(usage·soc 를 안 본다)
        dz < Δ_fail && (Δ_fail = dz; who = :zone)
    end
    return (Δ_fail, who)
end

"`Δ` 만큼 로봇별 문턱을 소진한다(제자리 수정). zone 문턱은 스칼라라 호출자가 뺀다."
function _consume_thresholds!(cur::SimState, ks::Vector{Int}, modes::Dict{Int,Symbol},
                              p::HazardParams, bp::BatteryParams, cap::Float64,
                              Eb::Dict{Int,Float64}, Ec::Dict{Int,Float64}, Δ::Float64)
    for k in ks
        rec  = cur.fleet[k]
        A, a = rate_params_one(p, rec, modes[k], bp, cap)
        Eb[k] -= integrated_hazard(A, a, Δ)
        Ac = cell_rate_from(p, rec.usage_s, modes[k])
        Ec[k] -= integrated_hazard(Ac, _cell_exponent(p, modes[k]), Δ)
    end
    return nothing
end

"""
    sample_sojourn(s, env, p, bp, rng; delta_max = Inf) -> (τ, event)

다음 **decision epoch** 까지의 시간과 그 사건. `event` 는

| event | 뜻 |
|---|---|
| `(:failure, k::Int)`            | 로봇 `k` 의 **break** |
| `(:failure, (:cell, k::Int))`   | 로봇 `k` 의 **cell** 열화 |
| `(:failure, :zone)`             | 전역 **zone** 출현 |
| `(:terminal, nothing)`          | 남은 활성 정점이 없다(에피소드 종료) |
| `(:horizon, nothing)`           | `delta_max` 에 닿았다 |

종류는 `event_kind`, 대상 로봇은 `event_robot_key`/`event_robot`(= 이슈 C 의 역지도)로 읽는다.

🔴 **cell 사건은 로봇을 나른다** — payload 가 `:cell` 이 아니라 `(:cell, k)` 인 이유다.
엔진의 `_hz_fire_cell!`(hazard.jl:592)은 특정 로봇의 soc 를 떨어뜨리고
`battery_action(env, id, ...)` 를 부르므로, 로봇을 버리면 생성 시뮬레이터가 그 전이를
**집행할 수 없다.**

`τ` 는 언제나 유한한 비음수다(`_ret` 가 못박는다). `τ == 0` 은 **흡수상태에서만** 나온다.
"""
function sample_sojourn(s::SimState, env, p::HazardParams, bp::BatteryParams, rng;
                        delta_max::Float64 = Inf)
    τ, ev = sample_sojourn_probe(s, env, p, bp, rng; delta_max = delta_max)
    return (τ, ev)
end

"""
    sample_sojourn_traced(s, env, p, bp, rng; delta_max = Inf) -> (τ, event, n_boundary)

`sample_sojourn` + **넘은 rate boundary 의 개수**. 시험과 게이트가 "dt 루프가 없다"를 벽시계가
아니라 **구조**로 재기 위해 존재한다: dt 루프였다면 `τ / dt_sim` 번 돌았을 자리에서 이 값이
자릿수로 작아야 한다.
"""
function sample_sojourn_traced(s::SimState, env, p::HazardParams, bp::BatteryParams, rng;
                               delta_max::Float64 = Inf)
    τ, ev, nb = sample_sojourn_probe(s, env, p, bp, rng; delta_max = delta_max)
    return (τ, ev, nb)
end

"""
    sample_sojourn_probe(s, env, p, bp, rng; delta_max = Inf)
        -> (τ, event, n_boundary, n_drain, drain_time_s)

`sample_sojourn_traced` + **드레인 계측 둘**. Task T10 의 분해가 쓰는 진입점이다:

| 값 | 뜻 |
|---|---|
| `n_drain` | `dur == 0` 프론티어를 흘린 횟수 |
| `drain_time_s` | 그 흘림이 **소비한 시뮬 시간의 합** = `n_drain * DRAIN_DT[]` (기본 0.0) |

`DRAIN_DT[] == 0.0`(기본)이면 `drain_time_s == 0.0` 이고 τ·event·n_boundary 는 T9 의 값과
**비트 동일**하다 — 드레인 분기가 시간을 안 쓰는 경로 그대로이기 때문이다.
"""
function sample_sojourn_probe(s::SimState, env, p::HazardParams, bp::BatteryParams, rng;
                              delta_max::Float64 = Inf)
    (delta_max >= 0.0 && !isnan(delta_max)) ||
        error("sample_sojourn: delta_max = $(delta_max) — 비음수여야 한다")
    cap = Float64(bp.capacity_J)
    cap > 0 || error("sample_sojourn: capacity_J = $(cap) — 양수여야 한다")
    isfinite(p.mode) ||
        error("sample_sojourn: HazardParams.mode = $(p.mode) — 유한해야 한다(비유한 rate 금지)")

    cur = s
    t   = 0.0
    ks  = sort!(collect(keys(cur.fleet)))
    isempty(ks) && error("sample_sojourn: s.fleet 가 비어 있다 — 위험에 노출된 로봇이 0 명인 " *
                         "상태를 표집하지 않는다")
    # 🔴 문턱은 **정렬된 키 순서**로 뽑는다. Dict 순회 순서로 뽑으면 같은 시드가 프로세스마다
    #    다른 짝을 만든다(이 레포의 근본 비결정성이 정확히 그 모양이다).
    Eb  = Dict{Int,Float64}(k => _exp1_draw(rng) for k in ks)   # break
    Ec  = Dict{Int,Float64}(k => _exp1_draw(rng) for k in ks)   # cell
    Ez  = _exp1_draw(rng)                                       # zone
    λz  = _rate(p.mtbf_zone_s) * p.mode
    isfinite(λz) && λz >= 0.0 ||
        error("sample_sojourn: λ_zone = $(λz) — 유한한 비음수여야 한다")

    n_boundary = 0
    n_drain    = 0
    t_drain    = 0.0
    guard      = 16 * p.max_events
    drain_dt   = DRAIN_DT[]
    (isfinite(drain_dt) && drain_dt >= 0.0) ||
        error("sample_sojourn: DRAIN_DT[] = $(drain_dt) — 유한한 비음수여야 한다")

    while true
        # (0) 활성 프론티어를 **한 번만** 훑는다(정렬 + 소요시간). 아래의 모든 결정이 이걸 쓴다.
        act, durs = _active_with_durations(cur, env)
        isempty(act) && return _ret(t, (:terminal, nothing), n_boundary, n_drain, t_drain)

        if !any(>(0.0), durs)
            # 🔴 프론티어가 **전부 `dur == 0`** — `T_plan_next` 가 폴백을 타는 바로 그 자리다
            #    (tplan.jl:158-160). 계획상 시간을 안 쓰는 정점들이므로 **시간 0 으로** 닫고
            #    다시 본다. `Inf` 를 적분 상한으로 받는 일이 이 한 줄로 사라진다.
            #    ⚠️ 선언된 근사: 엔진은 이런 정점도 스텝 경계에서 닫으므로 `dt_sim` 만큼 늦다.
            #    🔴 T10 의 프로브(`DRAIN_DT[] > 0`)가 정확히 그 근사를 흔든다 — 아래.
            n_drain += 1
            n_drain > guard &&
                error("sample_sojourn: dur==0 프론티어를 $(n_drain) 번 흘렸다 — 스케줄이 " *
                      "전진하지 않는다")
            if drain_dt <= 0.0
                cur = _close_vertices(cur, act)          # T9 의 경로 그대로(시간 0)
                continue
            end
            # --- 프로브: 드레인에 `drain_dt` 만큼의 시뮬 시간을 물린다 -----------------
            #     길이 `drain_dt` 의 작은 경계 하나와 **같은 규칙**으로 처리한다: 그 안에서
            #     위험이 먼저 오면 그 사건이 답이고, 아니면 문턱을 소진하고 필드를 밀고 닫는다.
            modes_d = modes_of(cur, env)
            Δ_fd, who_d = _first_failure(cur, ks, modes_d, p, bp, cap, Eb, Ec, Ez, λz)
            Δ_stop_d = delta_max - t
            if Δ_fd <= drain_dt && Δ_fd <= Δ_stop_d
                return _ret(t + Δ_fd, (:failure, who_d), n_boundary, n_drain, t_drain)
            elseif Δ_stop_d <= drain_dt
                return _ret(delta_max, (:horizon, nothing), n_boundary, n_drain, t_drain)
            end
            _consume_thresholds!(cur, ks, modes_d, p, bp, cap, Eb, Ec, drain_dt)
            λz > 0.0 && (Ez -= λz * drain_dt)
            cur = _close_vertices(_advance_fields(cur, drain_dt, bp, modes_d), act)
            t       += drain_dt
            t_drain += drain_dt
            continue
        end

        modes = modes_of(cur, env)          # 🔴 경계당 한 번(배치). 로봇별 mode_of 금지
        Δ_fail, who = _first_failure(cur, ks, modes, p, bp, cap, Eb, Ec, Ez, λz)

        # 🔴 경계의 권위는 `T_plan_next` 다(단일 진실원). 위에서 `dur > 0` 인 활성이 있음을
        #    확인했으므로 여기서는 **주 경로**여야 하고, 그것을 트립와이어로 못박는다 —
        #    폴백을 탔다면 그건 이 루프의 전제가 깨졌다는 뜻이다.
        Δ_node = T_plan_next(cur, env)
        want   = RHO[] * minimum(d for d in durs if d > 0.0)
        (isfinite(Δ_node) && Δ_node > 0.0 && abs(Δ_node - want) <= _SOJ_TOL) ||
            error("sample_sojourn: T_plan_next = $(Δ_node) 인데 주 경로 값은 $(want) 다 — " *
                  "tplan.jl 의 Inf 계약/주 경로 전제가 깨졌다")
        Δ_stop = delta_max - t

        if Δ_fail <= Δ_node && Δ_fail <= Δ_stop
            return _ret(t + Δ_fail, (:failure, who), n_boundary, n_drain, t_drain)
        elseif Δ_stop <= Δ_node
            return _ret(delta_max, (:horizon, nothing), n_boundary, n_drain, t_drain)
        end

        # rate boundary — 결정이 아니다. 문턱을 소진하고 계속 간다.
        _consume_thresholds!(cur, ks, modes, p, bp, cap, Eb, Ec, Δ_node)
        λz > 0.0 && (Ez -= λz * Δ_node)
        cur = _cross_boundary(cur, act, durs, Δ_node, bp, modes)
        t  += Δ_node
        n_boundary += 1
        n_boundary > guard && error(
            "sample_sojourn: rate boundary 를 $(n_boundary) 번 넘었다 — T_plan_next 가 " *
            "전진하지 않거나 λ 가 0 이다. 조용히 T_done 을 돌려주면 '실패가 안 오는 세계'를 " *
            "탐색하게 된다")
    end
end
