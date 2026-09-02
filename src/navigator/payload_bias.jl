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
**절대 1.0 미만이 되지 않는다** — 이 축은 로봇을 비싸게만 만들고 인센티브를 주지 않는다.
음의 비용은 MILP 를 깨뜨린다.

🔴 최종 리뷰 F8 정정: 여기 있던 "`deprioritize_agent` 의 clamp 와 같은 규약" 은 거짓이었다.
`deprioritize_agent!`(`essential_tg_coponents.jl:1386`)는 **양쪽 다** 자른다—
`clamp(factor, 1.0, MAX_AGENT_COST_BIAS)`(상한 1.0e3). 이 함수는 **아래쪽만** 자른다
(`max(0.0, ...)` 을 두 인자 각각에 걸 뿐, 결과 배수 자체에는 상한이 없다) — `light_bias`·
`m_payload` 를 크게 주면 배수가 그만큼 커진다. 🔴 상한을 새로 넣지 않는다 — 그것은 이
레인의 범위를 넘는 행동 변경이고, 이 무제한 손잡이는 **미룬 위험으로 기록**만 한다(조용히
막지 않는다).
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

"""
    cargo_burden_after(env, sched, v, p::BatteryParams) -> Union{Nothing,Float64}

배정 슬롯 `v` 가 나르게 될 화물의 **1대당 부담** = 화물질량 / 팀크기.

`nothing` 은 **"못 쟀다"** 다(삼상 규약) — 0 이 아니다. 호출자는 그것을 0 으로 접지 마라.
못 재는 경우 셋: 후속 노드가 없다 · 후속이 화물을 나르는 노드가 아니다 · 팀 크기를 못 얻거나
0 이다. 셋 다 `nothing` 이고, 그중 어느 것도 "부담 0" 이 아니다.

**왜 팀 크기로 나누나** — `account_battery_step!`(`battery.jl`)의 `share` 가
`moved_mass = m_robot·|team| + m_payload` 를 `length(robots)` 로 균등분배한다. 팀이 크면 같은
화물이라도 1대당 부담은 작다. 실측(tractor): `m=12.8, 팀4 → 3.20` < `m=9.011, 팀2 → 4.506`.

🔴 **단일 진실원이다.** 질량은 `candidate_edge_payload_mass` → `_payload_mass_measured` 한
곳에서만 나온다(그 계약은 `battery.jl` 의 `_payload_mass_measured` 위 주석이 못 박는다).
소비자가 둘이다 — `compile_constraint!(…, ::ForbidHeavyCargo)`(MILP 금지 대상 선정)와
LLM 프롬프트의 부담 순위. 두 번째 추정량을 만들지 마라.

⚠️ `p.payload_density` 는 `# TUNING KNOB` 이라 **절대값에 뜻이 없다.** 모든 후보에 공통인
양의 스칼라이므로 **순위는 `p` 와 무관하게 불변**이다 — 순위 용도에서는 어떤 `p` 를 줘도
같은 답이다. `p` 를 인자로 남긴 것은 절대값을 쓰는 호출자가 자기 출처를 고르게 하기 위해서다
(컴파일러는 `BATTERY_FLEET[].params`, 프롬프트 레인은 `BatteryParams()`).

⚠️ `env` 는 `env.scene_tree` 하나만 읽힌다 — `(scene_tree = …,)` NamedTuple 로도 부를 수 있다
(컴파일러가 `RESPEC_SCENE_TREE[]` 로 그렇게 부른다).
"""
function cargo_burden_after(env, sched, v, p::BatteryParams)
    outs = Graphs.outneighbors(sched, v)
    isempty(outs) && return nothing                      # 후속이 없다 = 못 쟀다
    inner = get_node_from_id(sched, get_vtx_id(sched, outs[1]))
    m = candidate_edge_payload_mass(env, sched, v, p)    # 같은 한 홉·같은 단일 추정량
    m === nothing && return nothing                      # 화물을 나르는 노드가 아니다 = 못 쟀다
    team = try
        length(robot_team(entity(inner)))
    catch
        0                                                # 팀을 못 읽었다
    end
    team > 0 || return nothing   # 🔴 0 으로 나누지 않는다. "팀 없음" = 못 쟀다 (∞ 도, 0 도 아니다)
    return Float64(m) / team
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
