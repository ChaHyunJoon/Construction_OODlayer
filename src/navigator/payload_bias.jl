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
