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
#    `rate_params` 는 씬 인자를 받으므로 `derive.jl` 에 산다.
# =============================================================================

const _A_ZERO_TOL = 1e-12    # |a| 가 이보다 작으면 λ 상수 극한을 쓴다 (수치 안정)

"""
    integrated_hazard(A, a, Δ) -> Float64

∫₀^Δ A·e^{a t} dt = (A/a)(e^{aΔ} − 1).  `a → 0` 극한은 `A·Δ`.

🔴 `expm1` 을 쓴다. `exp(x) - 1.0` 은 `|x|` 가 작을 때 **파국적 상쇄**를 일으킨다 —
`_A_ZERO_TOL`(1e-12)과 ~1e-8 사이의 띠에서 유효숫자가 통째로 날아간다. 실측:
`a = 1e-9, Δ = 1.0` 에서 `exp` 판은 수치적분 대비 상대오차 ≈ 2e-7 로, 시험의 `rtol = 1e-6`
까지 **5배**밖에 안 남았다. 그 띠는 이 함수가 실제로 쓰이는 구간이다(느린 λ 증가).
"""
function integrated_hazard(A::Float64, a::Float64, Δ::Float64)
    abs(a) < _A_ZERO_TOL && return A * Δ
    return (A / a) * expm1(a * Δ)
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
    x = a * E / A                     # `integrated_hazard` 의 expm1 인자와 짝이 되는 형태
    x <= -1.0 && return Inf           # a<0 에서 총위험을 넘어섰다 (구 `1 + x <= 0` 과 동치)
    Δ = log1p(x) / a                  # 🔴 log(1 + x) 는 |x| 가 작을 때 상쇄된다
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

🔴 **베껴 쓸 때 틀리기 쉬운 세 자리** (2026-08-21 T7 실측):
  · `:manip` 의 **팀 분할을 빠뜨리지 말 것** — 6인 팀이면 로봇당 전력이 **6배** 커진다.
  · `:carry = walk_W + k_move·m_robot·v_ref` 는 `m_robot` 을 **두 번** 센다
    (`walk_W` 자체가 `idle_W + k_move·m_robot·v_ref` 로 교정된 값이다, battery.jl:93-96).
  · **`BatteryParams` 에 `m_payload` 필드는 없다** — 짐 질량은 `_payload_mass(env, node, p)`
    가 씬에서 잰다. 위 kwarg 는 호출자가 넘기는 값이다.

⚠️ **기준 조건(`team = 1, m_payload = 0, speed = v_ref`)이 경량 레인의 선언된 근사다** —
`speed`·`m_payload`·`team` 셋 다 `s` 에서 유도되지 않고(로봇 pose 와 화물 기하가 상태에서
빠졌다) 구간 내내 상수도 아니다. **세 대입의 부호가 서로 다르므로 순부호를 유도해 둔다:**

| 대입 | P 에 주는 부호 | 근거 / 실측 (colored_8x8 · 6로봇 · step 261) |
|---|---|---|
| `speed = v_ref` ← 실현 속도 | **위(+), 구성상 항상** | `v_ref = 4.0` 은 `rvo_default_max_speed()` 그 자체다(battery.jl:70) — 실현 속도가 이걸 넘을 수 없다. 실측 범위 `0.0 … 3.99999 m/s`(12개 이동 노드) |
| `m_payload = 0` ← 실제 짐 | **아래(−)** | `km·(m_payload/team)·speed` 항이 사라진다. 실측 짐 질량 `0.0 … 2.29 kg` — `m_robot = 60 kg` 의 **3.8%** |
| `team = 1` ← 실제 팀 크기 | `:manip` **위(+)** · 이동 모드 **영향 없음** | manip 할증을 안 나눈다: team 2 에서 `1000 W` vs `550 W`. 이동 모드는 `(m_robot·team + m_payload)/team` 이라 `m_payload = 0` 이면 team 이 약분된다 |

🔴 **순부호는 양(+)이지만 무조건은 아니다.** 이동 모드에서
`P_light − P_true = km·[m_robot·(v_ref − speed) − (m_payload/team)·speed]`
이므로, 로봇이 **최고속으로 짐을 지고** 달리는 극단(`speed → v_ref`)에서는 두 번째 항만 남아
부호가 뒤집힌다. 이 픽스처의 실측 크기로는 뒤집히려면 `speed > v_ref·m_robot/(m_robot+m_payload)`
`= 4.0·60/62.29 ≈ 3.853 m/s` 여야 하는데, 뒤집히더라도 그 폭은 `km·m_payload·v_ref ≈ 15 W`
(P 의 3%)로 작다. 실측: step 261 의 fleet 6대 **전부 양(+)**, 집계도 양(+).
`test/smdp_derive.jl` 의 Ruling 2 testset 이 `@test e_light > e_engine` 과 로봇별
`@test a_light >= a_true` 로 이 부호를 **단언**하고 실현 속도·짐 질량 범위를 `@info` 로 찍는다.
그 단언은 불변식이 아니라 **트립와이어**다 — 빨개지면 "선언한 상한이 더는 성립하지 않는다".

🔴 **아래 숫자는 실행마다 달라진다. 인용하지 말고 시험을 돌려라.** 권위는 이 문단이 아니라
`test/smdp_derive.jl` 이 매 실행 찍는 `@info` — `T7 잔차 (A)/(B)/(C)` 세 줄이다.
같은 시험·같은 시드로 **두 디렉토리에서 잰 값**을 나란히 둔다(2026-08-21):

|  | laneF (장부 step 261) | laneF + 병합된 observe.jl (장부 step 95) |
|---|---|---|
| 실현 속도 범위 | `0.0 … 3.99999` | `0.0 … 1.794` |
| 짐 질량 범위 | `0.0 … 2.29 kg` | `0.0 … 0.0 kg` |
| 지수 오차 `Δa/a` | **3.7%** | **5.7%** |
| `β_s·P/C` 가 `a` 에서 차지하는 비중(상한) | 8.0% | 8.0% |
| 에너지 비 (집계, `s.fleet`) | **1.48배** | **2.98배** |
| 에너지 비 (로봇 최대) | 4.56배 | 5.00배 |
| 분리비 (C) | 12.8 | 34.6 |

두 열의 차이가 요점이다: **스칼라 하나로 못 박을 수 있는 값이 아니다.** 시험은 유도된 상한
(`Δa/a ≤ β_s·P/C ÷ a`)과 분리비 바닥값만 강제하고, 관측치는 찍기만 한다 — 숫자가 움직여도
이 표가 자동으로 빨개지지는 **않는다**(`SCENE-INCANTATION.md` §2 가 정확히 그렇게 낡았다).

🔴 **잔차의 크기는 소비처마다 다르다. 하나의 숫자로 둘을 재지 말 것:**

  · **지수(exponent) — 게이트 N-G1 이 본다.** `a` 안에서 이 대입이 건드리는 것은
    `β_s·P/C` 항 하나뿐이므로, **그 항이 `a` 에서 차지하는 비중이 오차의 상한**이다:
        이동 모드 `P = 500 W` → `1.2·500/8.28e6 = 7.25e-5` vs `β_u/U = 1/600 = 1.67e-3` → **4.2%**
        `:manip`  `P = 1000 W` →                        `1.45e-4`                      → **8.0%**
    ⚠️ 상한으로 인용할 값은 **8%** 다("약 4%" 는 이동 모드만의 값이다).
    실측 최대 상대오차 `Δa/a = 3.7%`. Δ = 60 s 구간이면 λ 배수로 `exp(60·6.2e-5) ≈ 1.004`.

  · **에너지 — 게이트 N-G5 가 본다. 🔴 위의 4~8% 로 재면 안 된다.** N-G5 는 `Σ ΔE` 와
    `energy_J` 를 직접 비교하므로 오차가 `P_light / P_true` **그 자체**다. 실측(step 261,
    `s.fleet` 6대): 집계 `100.0 J` vs `67.68 J` = **1.48배(오차 48%)**, 로봇 하나로는
    **최대 4.6배**(거의 멈춰 선 `:transit` 로봇: `500 W` vs `≈110 W`).
    지수 오차(3.7%)와 **자릿수가 다르다 — 실측 12.8배**.
    N-G5 의 허용오차를 지수 쪽 숫자에서 뽑으면 게이트가 통과할 수 없다.
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
