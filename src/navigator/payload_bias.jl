# =============================================================================
# payload 축 재가격 (S2, 2026-09-01). spec: docs/superpowers/specs/2026-09-01-s2-payload-reprice-design.md
#
# 🔴 **로봇은 `v` 에서, 화물은 `v2` 한 홉 아래에서 읽는다.** 실측(tractor, release 후 후보
#    2103개): v·v2 는 **전부 `RobotGo`** 라 어느 쪽에서도 화물을 못 잰다(0/2103). `v2` 의
#    후속은 **전부 `FormTransportUnit`** 이고 거기서 2103/2103 을 잰다(0.32768 … 12.800,
#    서로 다른 값 15종). 로봇 신원은 반대로 `v` 에만 있다(유효 id 18개; `v2` 는 43개 전부
#    무효 — `reset_slot_to_invalid!` 의 의도).
#    ⟹ 2026-08-30 계획서의 `payload_edge_multiplier`(= v 쪽 질량)는 후보 간선에서 **항상
#    1.0** 이었다. 그 설계로 돌아가지 말 것.
# =============================================================================

"""
    _PAYLOAD_REF

payload 정규화 기준 질량. **tractor.mpd 실측 상한 12.800 kg** 이다(2026-08-30 §6-1 의
`0.32768 … 12.800` · 이 레인의 후보 간선 실측과 일치).

⚠️ 2026-08-30 계획서의 `2.29` 는 `src/smdp/rates.jl` 의 **다른 픽스처** 값이라 쓰지 않는다 —
그 값을 쓰면 대부분의 화물에서 `m/ref > 1` 이 되어 배수가 과도해진다.
⚠️ 이 kg 자체가 프록시다(`battery.jl:72` `payload_density = 100.0`, 그 주석이
*"verify density/units before claiming"*). 물리량으로 인용하지 말 것.
"""
const _PAYLOAD_REF = Ref(12.8)

"""
    _payload_factor(m_payload, light_bias) -> Float64

화물 질량 → 비용 배수 `1 + light_bias·(m/_PAYLOAD_REF)`. 순수 함수.
**절대 1.0 미만이 되지 않는다** — 이 축은 로봇을 비싸게만 만들고 인센티브를 주지 않는다
(`deprioritize_agent` 의 clamp 와 같은 규약). 음의 비용은 MILP 를 깨뜨린다.
"""
_payload_factor(m_payload::Real, light_bias::Real) =
    1.0 + max(0.0, Float64(light_bias)) * max(0.0, Float64(m_payload)) / _PAYLOAD_REF[]

"""
    candidate_edge_payload_mass(env, sched, v2, p) -> Union{Nothing,Float64}

후보 간선 `(v, v2)` 가 나르게 될 화물의 질량. `v2` 는 배정 슬롯(`RobotGo`)이고 화물은 그
**후속 `FormTransportUnit`** 에 붙어 있다 — `policy.jl::_battery_load_features` 가 타는 것과
같은 한 홉이다.

`nothing` 은 **"못 쟀다"** 다(삼상 규약). 호출자는 그것을 0 으로 접지 말고 배수 1.0 으로
다뤄야 한다 — 모르는 것을 근거로 로봇을 벌하지 않는다.
"""
function candidate_edge_payload_mass(env, sched, v2, p::BatteryParams)
    outs = Graphs.outneighbors(sched, v2)
    isempty(outs) && return nothing
    succ = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
    return try
        _payload_mass_measured(env, succ, p)
    catch
        nothing            # 화물을 나르는 노드가 아니다 = 못 쟀다 (0 이 아니다)
    end
end

"설치된 재가격 상태. `(agent::String, light_bias::Float64, params::BatteryParams)`."
const PAYLOAD_BIAS = Ref{Union{Nothing,NamedTuple}}(nothing)

"""
    payload_edge_multiplier(env, sched, v, v2) -> Float64

후보 간선 `(v, v2)` 의 payload 배수. 재가격 대상이 **아닌** 로봇의 간선에서는 1.0 이므로
설치 전후로 다른 로봇의 비용은 바이트 동일이다.

계약(실측 근거는 이 파일 머리말): 로봇 신원은 `v` 에서, 화물은 `v2` 한 홉 아래에서.
화물을 못 재면 1.0 이다 — 모르는 것을 근거로 벌하지 않는다(삼상 규약).
"""
function payload_edge_multiplier(env, sched, v, v2)
    st = PAYLOAD_BIAS[]
    st === nothing && return 1.0
    owner = _edge_owner_id(sched, v)
    (owner === nothing || string(owner) != st.agent) && return 1.0
    m = candidate_edge_payload_mass(env, sched, v2, st.params)
    m === nothing && return 1.0
    return _payload_factor(m, st.light_bias)
end

"""
    reprice_agent_by_payload!(env; agent, light_bias = 0.5) -> NamedTuple

한 로봇의 **후보 배정 간선** 비용을 그 간선이 나르게 될 화물 질량에 비례해 올린다. 로봇을
함대에서 빼지 않고 가벼운 화물 쪽으로 몰아주는 개입이다. 실행가능집합을 안 바꾸므로 문제를
infeasible 로 만들 수 없다.

`agent` 는 로봇 id 의 **문자열 형태** — `string(id)` 가 실제로 내는 그대로여야 `Set(string(k)
for k in keys(fleet.soc))` 와 매칭된다. 이 레포에서 그 형태는 **모듈 한정**이다:
`string(CB.RobotID(2))` → `"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(2)"` (짧은
`"BotID{DeliveryBot}(2)"` 가 아니다 — 이 짧은 형태로 부르면 `:unknown_agent` 다). 실측:
`test_macro_returns_tool_call.py`, `tools/monitor/enact.jl`, `busiest_agent` 모두 완전-한정
형태를 주고받는다 — 이 함수도 같은 관례를 따른다. 형태를 직접 조립하지 말고 `string(id)` 로
파생할 것.

🔴 **이것만으로는 무동작이다.** 간선 가중치는 MILP 재풀이가 읽어야 뜻을 갖고, 재풀이가 볼
후보 간선은 `release_pending_assignments!` 가 슬롯을 풀어야 생긴다. 실측: release 없이
후보 간선은 **0** 이고 그때 이 배수는 **0번 호출된다.**

🔴 국소 undo 는 없다. `clear_payload_bias!` 는 훅을 떼지만 그 편향으로 푼 계획은 못 되돌린다.
"""
function reprice_agent_by_payload!(env; agent::AbstractString, light_bias::Real = 0.5)
    fleet = BATTERY_FLEET[]
    fleet === nothing && return (status = :no_fleet, agent = String(agent), installed = false)
    known = Set(string(k) for k in keys(fleet.soc))
    String(agent) in known ||
        return (status = :unknown_agent, agent = String(agent), installed = false)
    PAYLOAD_BIAS[] = (agent = String(agent), light_bias = Float64(light_bias),
                      params = fleet.params)
    EDGE_PAYLOAD_MULTIPLIER[] = (sched, v, v2) -> payload_edge_multiplier(env, sched, v, v2)
    return (status = :repriced, agent = String(agent), installed = true)
end

"""
    clear_payload_bias!() -> Nothing

payload 훅만 뗀다. `EDGE_COST_MULTIPLIER`(SoC·agent 축)는 **건드리지 않는다** — 두 축을 한
상자에 넣었다면 여기서 SoC 항까지 사라졌을 것이다(그래서 Ref 를 둘로 나눴다).
"""
function clear_payload_bias!()
    PAYLOAD_BIAS[] = nothing
    EDGE_PAYLOAD_MULTIPLIER[] = nothing
    return nothing
end
