# =============================================================================
# rates.jl — spec §2 의 닫힌 형태. **부작용 없는 순수 수학.**
#
# 모드가 상수인 구간에서 usage 와 soc 가 t 에 선형이므로 λ 가 지수형이 된다:
#     λ_r(t) = A_r · exp(a_r · t)
#     A_r = hazard_rate_from(p, usage_r, soc_r, mode_r)        (t = 0 의 값)
#     a_r = β_u/U · 1[mode ≠ :idle]  +  β_s · P(mode) / C      (D-5 로 ε_r ≡ 1)
# 그래서 적분도 역함수도 닫힌다. dt 루프가 필요 없는 이유가 이것뿐이다.
#
# 🔴 이 파일은 씬(scene)도 엔진도 참조하지 않는다. 그것이 `derive.jl` 과 갈라놓은 **이유**다 —
#    수치 적분 대조군(`test/smdp_rates.jl`)이 엔진에 묶이면 안 된다. 배치 함수
#    `rate_params` 는 씬 인자를 받으므로 `derive.jl` 에 산다(계획서는 여기라고 적었다).
# =============================================================================

const _A_ZERO_TOL = 1e-12    # |a| 가 이보다 작으면 λ 상수 극한을 쓴다 (수치 안정)

"""
    integrated_hazard(A, a, Δ) -> Float64

∫₀^Δ A·e^{a t} dt = (A/a)(e^{aΔ} − 1).  `a → 0` 극한은 `A·Δ`.
"""
function integrated_hazard(A::Float64, a::Float64, Δ::Float64)
    abs(a) < _A_ZERO_TOL && return A * Δ
    return (A / a) * (exp(a * Δ) - 1.0)
end

"""
    inv_integrated_hazard(A, a, E) -> Float64

`integrated_hazard(A, a, Δ) == E` 를 푸는 `Δ`. 이 구간 안에서 발화하지 않으면 `Inf`.

🔴 `a < 0` 이면 총위험이 `−A/a` 로 유한하다. `E` 가 그보다 크면 **이 위험은 영원히 발화하지
않는다** — 로그 인자가 0 이하가 되므로 반드시 걸러야 한다. 안 거르면 `NaN` 이나 음수 `Δ` 가
나오고, 그것이 `findmin` 을 통과해 **τ < 0** 인 epoch 를 만든다. 경계(`E == −A/a`)는
안전한 쪽(`Inf`)으로 간다. **어떤 입력에도 음수를 돌려주지 않는다.**
"""
function inv_integrated_hazard(A::Float64, a::Float64, E::Float64)
    (A <= 0.0 || !isfinite(E) || E < 0.0) && return Inf   # !isfinite 가 NaN 도 잡는다
    abs(a) < _A_ZERO_TOL && return E / A
    arg = 1.0 + a * E / A
    arg <= 0.0 && return Inf          # a<0 에서 총위험을 넘어섰다
    Δ = log(arg) / a
    return (isfinite(Δ) && Δ >= 0.0) ? Δ : Inf
end

"""
    mode_power_W(p::BatteryParams, mode::Symbol; team = 1, m_payload = 0.0, speed = p.v_ref)

로봇 **한 대**가 이 모드에서 빨아들이는 전력 [W]. 🔴 `battery.jl:225-280` 의
`account_battery_step!` 이 실제로 부과하는 값과 **같은 식**이다 (대기 기저 + 모드 할증):

    :idle              idle_W
    :manip             idle_W + (manip_W − idle_W) / team          ← 팀이 나눠 진다
    :transit / :carry  idle_W + k_move(p)·(m_robot·team + m_payload)·speed / team

`test/smdp_derive.jl` 의 "Ruling 2" 시험이 실제 판에서 한 스텝을 굴려 엔진의 에너지 장부
(`BatteryFleet.energy_J`, `_debit!` 만이 쓴다)와 대조한다.

🔴 **계획서의 식은 틀렸다** (2026-08-21 T7 실측):
  · `:manip` 에 팀 분할이 없다 — 6인 팀이면 로봇당 전력이 **6배** 커진다.
  · `:carry = walk_W + k_move·m_robot·v_ref` 는 `m_robot` 을 **두 번** 센다
    (`walk_W` 자체가 `idle_W + k_move·m_robot·v_ref` 로 교정된 값이다, battery.jl:93-96).
  · 주석은 `m_payload` 라고 적었는데 식은 `p.m_robot` 을 쓴다. 그리고 **`BatteryParams` 에
    `m_payload` 필드는 없다** — 짐 질량은 `_payload_mass(env, node, p)` 가 씬에서 잰다.

⚠️ **기준 조건(`team = 1, m_payload = 0, speed = v_ref`)이 경량 레인의 선언된 근사다.**
실현 속도는 `s` 에 없고(로봇 pose 가 상태에서 빠졌다) 구간 내내 상수도 아니다 — `v_ref` 는
최대 속도이므로 **상한 근사**다(D-6 의 rate boundary 와 같은 종류의 편향이고, 부호가 같다:
λ 를 과대평가해서 더 일찍 발화시킨다). 이 자리의 실측 잔차는 T7 보고서에 적혀 있고 게이트
N-G1·N-G5 가 그 크기를 판정한다.
"""
function mode_power_W(p::BatteryParams, mode::Symbol;
                      team::Int = 1, m_payload::Float64 = 0.0, speed::Float64 = p.v_ref)
    team >= 1 || error("mode_power_W: team = $(team) — 담당 로봇이 0 명인 노드는 " *
                       "할증 대상이 아니다(battery.jl:256 이 `isempty(robots)` 로 건너뛴다)")
    mode === :idle    && return p.idle_W
    mode === :manip   && return p.idle_W + (p.manip_W - p.idle_W) / team
    (mode === :transit || mode === :carry) &&
        return p.idle_W + k_move(p) * (p.m_robot * team + m_payload) * speed / team
    error("mode_power_W: 알 수 없는 모드 $(mode) — 조용히 idle 로 떨어뜨리지 않는다")
end

"""
    rate_params_one(p, rec::RobotRec, mode, bp::BatteryParams, capacity_J) -> (A, a)

로봇 하나의 `(A, a)`. `rec` 는 두 필드뿐이고 `mode` 는 `derive.jl` 이 낸다.

`a` 의 두 항:
  · `β_u/U · 1[mode ≠ :idle]` — `hazard_step!`(hazard.jl:481)이 `:idle` 이 아닐 때만
    `usage_s += dt` 한다. 대기 중에는 마모가 안 쌓인다.
  · `β_s · P(mode)/C` — 🔴 **대기도 `idle_W` 를 먹는다**(battery.jl:244 가 켜져 있는 모든
    로봇에 대기 기저를 부과한다). 그래서 `:idle` 이어도 `a == 0` 이 아니다.
"""
function rate_params_one(p::HazardParams, rec::RobotRec, mode::Symbol,
                         bp::BatteryParams, capacity_J::Float64)
    A    = hazard_rate_from(p, rec.usage_s, rec.soc, mode)
    P    = mode_power_W(bp, mode)          # 알 수 없는 모드는 여기서 죽는다(폴백 없음)
    du   = (mode === :idle) ? 0.0 : (p.usage_scale_s > 0 ? 1.0 / p.usage_scale_s : 0.0)
    dsoc = capacity_J > 0 ? P / capacity_J : 0.0    # ε_r ≡ 1 (D-5)
    return (A, p.beta_usage * du + p.beta_soc * dsoc)
end
