# sojourn 을 생성 시뮬레이터로 풀어 SMDP 를 세운다 — 설계

작성 2026-08-20 · 기준 HEAD `50e938bc`
선행 `2026-08-20-tamp-nominal-smdp-failure-design.md`(프레이밍) · `2026-08-19-smdp-state-representation-design.md`

> **이 문서의 지위**: 선행 문서의 **§5(상태) · §10(19필드 엄격 축소) · §11(생성 MCTS 전환)** 을
> 구체화하고 **일부 수정**한다. 프레이밍(§0)과 4팔 행동공간(§10)은 **그대로 승계**한다.
> "실측" 표시는 이 레포에서 직접 확인한 것이고 나머지는 설계 주장이다.
> 🔴 = 지금 참이 아닌 것, ⏳ = 결정됐지만 미구현.

---

## 0. 이 문서가 닫는 구멍

선행 문서 §10 이 스스로 적어둔 것:

> "이 `s` 만으로는 `F(τ|s,a)` 도 `P` 도 모른다. sojourn 모델 `Υ` 는 `s` 밖에서 조달해야 하는데,
> 그 넷을 `s` 밖 어디에 둘지는 **아직 정해지지 않았다**."

이 문서가 그것을 정한다. 답은 "`s` 밖"이 아니라 **"`s` 안, 단 7필드만"** 이다.
그리고 그 7필드로 충분한 이유는 설계 선택이 아니라 **`hazard.jl` 이 이미 쓰고 있는 표집 방식의
수학적 성질**이다(§2).

---

## 1. 사용자 결정 넷 (2026-08-20)

| # | 결정 | 무엇이 걸려 있었나 |
|---|---|---|
| **D-1** | **무기억성을 이용해 rate block 만 최소 추가** | `F(τ|s,a)` 정의 가능 여부 |
| **D-2** | **롤아웃 = 진짜 respec + 경량 명목 구간** | DAG/scene tree 편집이 모델 안에 있는가 |
| **D-3** | **`fire_require_spare = false`** | 점과정 무결성 · 예비 희소성의 의미 |
| **D-4** | **`mtbf_zone_s` 를 유한값으로 켠다** | zone 이 실패 도착인가 시나리오 장치인가 |

**D-3 의 귀결**: 예비 고갈이 **물리 법칙이 아니라 보상의 결과**가 된다. 예비가 0 이면
`legal(fault) = {NOOP}` 으로 메뉴가 줄고 고장 로봇은 죽은 채 남아 `J` 가 나빠진다.
선행 문서 N-3-4(검열 회계)가 **소멸한다** — 검열 자체가 없어진다.

**D-4 의 귀결**: 세 사건 종류(`fault` · `battery` · `zone`)가 **하나의 경쟁위험 과정**으로
통일된다. `_hz_fire_zone!` 은 이미 완전 구현돼 있고 배치 난수까지 발생 순번으로 결정론적으로
시드한다(실측: `hazard.jl:598-614`). 선행 문서 N-3-5("zone 레인이 구조적으로 죽어 있다")는
**파라미터 하나로 해소**된다 — 기본값이 `mtbf_zone_s = Inf` 였을 뿐이다.

---

## 2. τ 는 닫힌 형태다 — 이 문서의 핵심 결과

선행 문서 어디에도 없는 결과다. `hazard.jl` 을 읽고 나온 것이다.

### 2-1. 구간 안에서 세 양이 전부 해석적으로 적분된다

모드가 상수인 구간에서:

| 양 | 시간 의존 | 근거 (실측) |
|---|---|---|
| `usage_r(t) = usage_r + t·1[mode ≠ :idle]` | **선형** | `hazard.jl:468` `st.usage_s[id] += dt` |
| `soc_r(t) = soc_r − P(mode)·ε_r·t / C` | **선형** | `battery.jl:154-158` `e = power_W·dt·ε_r`, `soc -= e/capacity` |
| `λ_r(t) = A_r · exp(a_r t)` | **지수** | 위 둘이 선형 → `hazard.jl:351-359` 의 `exp(β_u·û + β_s(1−soc))` 지수부가 `t` 에 선형 |

여기서

```
A_r = base · mode_global · mult(mode_r) · exp(β_u·û_r + β_s(1 − soc_r))
a_r = β_u/U · 1[mode_r ≠ :idle]  +  β_s · P(mode_r)·ε_r / C
```

`a_r → 0` 인 경우(대기 중이고 방전도 없음)는 `λ_r` 이 상수인 극한이고, 아래 식들은 전부
`lim_{a→0}` 이 잘 정의된다(구현에서 `|a| < ε` 분기 필요).

### 2-2. 적분 위험과 그 역함수

$$\Lambda_r(\Delta)=\int_0^{\Delta}\!\lambda_r(t)\,dt=\frac{A_r}{a_r}\big(e^{a_r\Delta}-1\big)$$

$$\Lambda_r(\Delta)=E_r \;\Longrightarrow\; \Delta_r=\frac{1}{a_r}\ln\!\Big(1+\frac{a_r E_r}{A_r}\Big)$$

`a_r E_r / A_r ≤ −1` 이면 그 위험은 이 구간 안에서 **발화하지 않는다**(`Δ_r = ∞`).
`a_r < 0`(충전 중 등)에서 실제로 일어날 수 있으므로 구현에서 반드시 다뤄야 한다.

**즉 `T_fail` 은 근사가 아니라 정확 표집이고, 로그 한 번 · 나눗셈 한 번이다.**
지금은 이것을 `dt = 0.025 s` 로 20,000 번 적분하고 있다(`hazard_step!`).

### 2-3. 무기억성이 `cum`·`thr` 를 `s` 에서 빼준다

`hazard.jl:296,299` 가 `thr_break[id] = _exp1(rng)` — **Exp(1) 문턱**이고
`hazard.jl:472-473` 이 `cum_break += λ·dt` — **적분 위험 누적**이다(실측).
발화 조건은 `cum ≥ thr`.

Exp(1) 은 무기억이므로, **아직 발화하지 않았다는 조건 하에서**

$$\text{thr}_r-\text{cum}_r \;\sim\; \mathrm{Exp}(1)\quad\text{(과거와 무관)}$$

⇒ **`cum_*`·`thr_*` 는 `s` 에 넣을 필요가 없다.** 그 둘은 정당하게 `ξ`(재생 상태)이고,
`F(τ|s,a)` 를 정의하는 데 필요한 것은 **`λ` 의 인자뿐**이다.

이것이 D-1 의 전부다. 상태가 작아지는 이유가 "손실을 감수해서"가 아니라
**"수학적으로 그 정보가 상태에 없어도 되기 때문"** 이다 — 선행 문서 §11-1 이 손실 압축을
정당화하려 했던 자리를, 손실 없이 대체한다.

### 2-4. `T_plan_next` 는 결정 epoch 가 아니다 — λ 의 구간상수 경계다

선행 문서 §0 의 `τ = min(T_plan(s⁺), min_r T_fail,r, Δ_max)` 에서 `T_plan` 이 왜 τ 에
들어가는지가 모호했다(§4 가 `T_plan_next` 와 `T_plan` 을 나눠 놓았지만 뜻이 달랐다).

**정확한 뜻**: 노드가 닫히면 로봇의 `mode` 가 바뀌고 `A_r`·`a_r` 가 갈린다. 그러므로
`T_plan_next` 는 **λ 가 구간상수(정확히는 위 지수형)를 유지하는 구간의 끝**이다.
그 시각에 결정은 일어나지 않는다 — 표집기가 내부적으로 재계산할 뿐이다.

두 종류의 시각을 문서 전체에서 구분한다:

| | 무엇 | 행동 선택 |
|---|---|---|
| **decision epoch** | 실패 사건 도착 | **있다** (SMDP 의 결정 시점) |
| **rate boundary** | 다음 노드 완료 | **없다** (표집기 내부) |

⇒ 선행 문서 §0 의 τ 식을 다음으로 대체한다:

$$\tau_{k+1}=\min\Big(\min_r T_{\text{fail},r},\;\; T_{\text{zone}},\;\; T_{\text{done}}(s^+_k)\Big)$$

`T_zone` 은 함대 수준이라 `r` 로 최소화되지 않는다(D-4).

`T_done` = 남은 빌드를 아무것도 안 고장 나고 끝내는 데 걸리는 시각(= 흡수상태 도달).
`T_plan_next` 는 이 식에 **안 나온다** — 표집 알고리즘 안에만 있다.
`Δ_max` 는 τ 절단이 아니라 **롤아웃 지평선**으로만 쓴다(자르면 §4 의 보상 분해가 깨진다).
지평선에 닿으면 그 롤아웃은 **끝나고 종단 가치 추정치가 붙는다** — 그 시각은 decision epoch
가 아니고, 그 판의 `Σ τ_k` 는 makespan 이 아니다(§4 의 등식은 완주·미완주 판에만 성립한다).

### 2-5. 정확 표집이 깨지는 자리 — 전부 닫아야 한다

| 기전 | 무엇을 깨나 | 처분 |
|---|---|---|
| `fire_require_spare = true` | 문턱을 넘었는데 발화를 미룸 ⇒ 잔여가 Exp(1) 이 아니라 0 | **D-3 으로 false** |
| `fire_safe_target = true` | 같음 | `hot_swap_enabled()` 이면 `_hz_safe_target` 이 항상 `true`(실측 `hazard.jl:498`). 실행 레인은 `DEMO_HOTSWAP=1` 로 항상 켠다 ⇒ **이미 무해**. ⚠️ 핫스왑을 끄는 레인이 생기면 되살아난다 |
| `drain_step_cv > 0` | 매 스텝 iid 흔들림 ⇒ `soc` 가 선형이 아님 | 기본 0. **0 을 유지한다**(선행 문서도 CRN 근거로 그렇게 적었다) |
| `max_events` 상한 | 상한에 닿으면 프로세스가 조용히 멈춤 | 롤아웃에서 상한 도달을 **에러로 올릴 것** |

---

## 3. 상태 — 판정 기준을 바꾼다

### 3-1. 기준 변경

| | 기준 | 결과 |
|---|---|---|
| 2026-08-20 (선행 §10) | **행동이 편집하는 것만** (write-set) | 19필드. `F(τ|s,a)` 정의 불능 |
| **이 문서** | **`(s,a) ↦ (s⁺, F(τ|·), R)` 를 계산하는 데 필요한 것 전부, 그 이상은 없음** | 26필드 |

선행 문서 §11-6 이 이미 지적한 것을 집행하는 것이다 — *"논문의 기준은 write-set 이 아니라
read-set 이다"*. 다만 read-set 을 통째로 넣지 않고 **sojourn 과 보상이 실제로 읽는 것만** 넣는다.

### 3-2. 정의

```
s = (G, Geo, Fleet, Prog, Courier)                                  26 필드

G      edges · binding · wedge_edges · dissolved_gates          4    변화 없음
Geo    poses · build_delta · zones                              3    +1
Fleet  로봇당: pose · soc · health · payload · role             5    변화 없음
              + usage_s · mode · eff                           +3
Prog   t · closed · active                                     +3    신규 블록
Cour   target·courier·depot·home·goal·phase·t_out·t_swap         8    step_* → 절대시각
```

타입:

```julia
Geo.zones   :: Dict{Symbol,NTuple{3,Float64}}   # key => (cx, cy, r)  ← 이름만이 아니라 기하까지
Prog.t      :: Float64                          # 절대 sim 초
Prog.closed :: Set{Int}                         # 닫힌 스케줄 정점
Prog.active :: Dict{Int,Float64}                # 활성 정점 => 그 정점이 실제로 시작한 시각
Fleet.mode  :: Symbol                           # :idle | :transit | :carry | :manip
                                                #   실측 hazard.jl:333-338 (_mode_mult),
                                                #   :transit 이 기준 조건(배수 1.0)
Fleet.eff   :: Float64                          # ε_r. 로봇당 상수
```

`CourierRec.step_out`/`step_swap` 은 **절대 스텝 인덱스**였고 `Clock` 이 없어 해석 불능이었다
(선행 문서 부채 (4)). `Prog.t` 가 생겼으므로 **절대 시각 `t_out`/`t_swap`** 으로 바꾼다.

### 3-3. 추가 7필드 각각의 정당화

| 필드 | 없으면 계산 불능인 것 | §2 의 어느 항 |
|---|---|---|
| `usage_s` | `λ_r` 의 `exp(β_u·û)` | `A_r`, `a_r` |
| `mode` | `λ_r` 의 `mult(mode)`, `soc` 감소율 `P(mode)` | `A_r`, `a_r` |
| `eff` (ε_r) | `soc` 감소율. **상수라 동역학 비용 0** | `a_r` |
| `zones` (기하 포함) | `T_plan_next` — zone 이 경로를 가른다 | rate boundary |
| `closed` | `T_plan_next`, 흡수상태 판정 | rate boundary, `T_done` |
| `active` (시작 시각 포함) | 진행 중 노드의 **잔여** 소요시간 | rate boundary |
| `t` | `CourierRec.t_*` 해석, 보상의 절대시간 | `R` |

`eff` 를 빼면 모델이 **잠재변수 혼합**이 되어 `s` 에서 Markov 가 아니다. 상수이므로 넣는
비용이 사실상 0 이다.

`zones` 를 **기하까지** 나르는 것이 선행 문서 N-5-2 가 경고한 "문제가 이동한 것"을 닫는다 —
이름만 나르면 반지름이 다른 두 상태가 같은 해시를 낸다.

### 3-4. 여전히 `s` 에 안 들어가는 것

| | 왜 |
|---|---|
| `cum_*` · `thr_*` | **§2-3 무기억성.** 잔여가 항상 Exp(1) |
| `rng_*` | ξ. 해시 불가능한 불투명 객체 |
| `n_nodes` · 스케줄 정점의 정적 속성 | **문제 파라미터**이지 상태가 아니다 |
| 노드 소요시간 | `(G, Geo)` 와 정적 씬에서 **유도**된다(`duration_lower_bound`) |
| 이번 epoch 를 연 사건 | 행동 메뉴는 호출자 ctx 가 정한다. **선행 문서 §10 (3) 그대로 승계** |
| RVO 시뮬레이터 상태 | **씬트리의 파생물**이다(§5-2) |
| `_hz_excluded()` 의 제외 집합 | `role`(`:spare_parked` 등)과 `health`(`:dead`)에서 **유도**된다 — 둘 다 이미 `s` 에 있다(실측 `hazard.jl:394-410`) |

---

## 4. 보상이 τ 로 정확히 분해된다 — undiscounted SSP-SMDP

현행 `objective.json` 의 `J` 는 사실 epoch 위로 **가법적**이다:

$$J=\underbrace{\textstyle\sum_k \tau_k}_{\text{makespan}}\;+\;w_E\underbrace{\textstyle\sum_k \Delta E_k}_{\text{energy}}
\qquad\Longrightarrow\qquad
R_k=-\big(\tau_k+w_E\,\Delta E_k\big)$$

- `−τ_k` 항이 논문 식 (3) 의 rate reward `r(x,a)·Υ` 에 정확히 대응한다(`r ≡ −1`).
- `ΔE_k` 는 구간 내 모드별 전력 × 시간의 합 — §2-1 대로 **닫힌 형태**로 나온다.
- 미완주는 흡수상태의 종단 벌점 `−(C_fail + C_unclosed·(n − closed))`.
- **할인 없음.** 08-17 랩미팅에서 합의한 undiscounted SSP-SMDP 그대로다.
  선행 문서들이 인용하던 `γ = 0.90` 은 이 정식화에서 **쓰지 않는다** — 흡수상태가 있고
  `τ_k > 0` 이므로 할인 없이도 정의된다.

⇒ `objective.json` 의 **스칼라는 하나도 안 바꾼다.** 단 동역학이 갈리므로 `generation` 은
bump 한다(§6 C8).

⚠️ `makespan = Σ τ_k` 는 **epoch 가 `[0, T_end]` 를 빈틈없이 덮을 때만** 참이다.
`Δ_max` 로 τ 를 자르면 깨진다 — 그래서 §2-4 대로 `Δ_max` 는 롤아웃 지평선으로만 쓴다.

---

## 5. 생성 시뮬레이터

### 5-1. 인터페이스

```
G(s, a; rng) -> (s′, R, τ, next_event)

 1. env′ ← 갈래용 env               (분기 비용은 아직 안 쟀다 — §9)
 2. 행동 적용 — 진짜 respec (D-2)
      action_to_proposal(ctx, a)     ← ood_mdp_shim.jl:291. 이미 4팔 id 로 정렬돼 있다
      apply_respec!(env′, proposal)  ← replace_robot / restage_zone / battery_courier
      공통 MILP 재풀이               ← 선행 §1-E 결정, ⏳ 미구현
      update_schedule_times!(env′.sched)
      update_rvo_sim!(env′)          ← §5-2
    ⇒ s⁺ = simstate_of(env′)         ← 🔴 이 함수가 지금 없다 (§6 C2)
 3. 명목 구간 — 정확 표집 (§2)
      (τ, ev) = sample_sojourn(s⁺, rng)
      s′      = advance(s⁺, τ)
 4. R = −(τ + w_E·ΔE)                ← §4
```

### 5-2. RVO — 씬트리의 파생물이다 (2026-08-20 정정 기록)

이 문서의 초안은 경량 레인에서 `set_use_rvo!(false)` 를 제안했다. **철회한다. 틀렸다.**

실측:

- `rvo_interface.jl:204-215` `rvo_add_agent!` — 위치는 `global_transform(agent).translation`,
  반경·최대속도·이웃거리도 전부 **에이전트에서 유도**된다.
- `route_planning.jl:465-477` `update_rvo_sim!` — `rvo_set_new_sim!()` →
  `rvo_add_agents!(scene_tree)` → `set_rvo_priority!`. 즉 **씬트리에서 통째로 재구축**한다.
- 실행 레인은 새 에이전트가 생길 때마다 **이미 이 재구축을 하고 있다.**

⇒ RVO 가 들고 있는 것 중 씬트리에 없는 정보는 **순간 속도뿐**이고, 그것도 매 스텝 pref
velocity 에서 다시 계산된다. **그러므로 스냅샷도, 비활성화도, 정책 변경도 필요 없다.**
갈래를 바꿀 때 씬트리에서 다시 만들면 된다.

🔴 **정정 2 (2026-08-20, 3계층 점검)**: 이 문서의 이전 판은 그 재구축을 `update_rvo_sim!(env)`
로 하라고 적었다. **불충분하다.** `route_planning.jl:467` 이 `rvo_sim_needs_update(scene_tree)`
로 가드하는데, 그 술어는 **"필요한 에이전트가 맵에 없는가"** 만 본다(실측 `rvo_interface.jl:302-317`).
롤아웃 갈래가 **위치만 옮기고 에이전트를 추가하지 않았으면 가드가 `false`** 라 재구축이 일어나지
않고 **갈래 오염이 그대로 남는다.**

⇒ 가드 없는 재구축 함수가 필요하다. `update_rvo_sim!` 의 본문에서 **술어만 뺀 것**이고,
구성 경로도 α 재적용도 동일하다 — **정책 규칙은 하나도 안 바뀐다.**

```julia
function rvo_rebuild!(env::PlannerEnv)
    rvo_set_new_sim!()
    rvo_add_agents!(env.scene_tree)
    for v in env.cache.active_set
        set_rvo_priority!(env, get_node(env.sched, v))
    end
    return env
end
update_rvo_sim!(env) = rvo_sim_needs_update(env.scene_tree) ? rvo_rebuild!(env) : env
```

⚠️ **`rvo_rebuild!` 를 `apply_action!` 도중에 부르면 안 된다.** `replace_robot.jl:835` 가
`rvo_set_agent_max_speed!(tu, 0.0)` 로 핀을 걸고 **같은 함수 안에서** force-close 한 뒤 :890 에서
복원한다(실측). 재구축이 그 사이에 끼면 핀이 `get_rvo_max_speed(tu)` 로 되돌아가 RVO 가 유닛을
목표 밖으로 밀어내고, 그 함수가 막으려던 실패(`64 carrier_advanced, 0 unwedged`)가 되살아난다.
**`apply_action!` 이 완전히 끝난 뒤에만** 부른다.

⚠️ **α 재적용 범위**: `update_rvo_sim!` 도 `rvo_rebuild!` 도 `cache.active_set` 만 순회한다.
활성 집합 밖 에이전트의 α 는 `rvo_add_agent!` 의 기본값으로 돌아간다. 지금도 그렇지만
**재구축 빈도가 올라가면 실행 레인 거동이 바뀔 수 있다** — 무거운 레인에서는 재구축을
**갈래 전환 시에만** 한다.

respec 이 RVO 에 쓰는 것도 **정책이 아니라 동기화**다:
`rvo_set_agent_position!`(씬트리 편집을 미러에 반영) ·
`rvo_set_agent_max_speed!(tu, 0.0)`(노드가 닫히기 전 밀려나지 않게 하는 임시 핀,
`replace_robot.jl:835` 에서 걸고 `:890` 에서 되돌린다).
**ORCA 속도 계산과 alpha 우선순위 규칙은 어디서도 바뀌지 않는다.**

무거운 레인과 경량 레인 **둘 다 `use_rvo() == true` 로 돈다.**

### 5-2b. 3계층 reactive policy 점검 결과 (2026-08-20)

`get_twist_cmd`(`route_planning.jl:737-827`)가 합성하는 세 계층
(① TangentBug → ② PotentialField → ③ RVO2, α 우선순위 게이팅)에 대해 이 설계의 변경 전부를
점검했다. 근거: `src/respec/docs/simulator_problem_scope_and_motion_stack_2026-06-23.md` §3.

| 계층 | 상태가 사는 곳 | 이 설계가 건드리는가 |
|---|---|---|
| ① TangentBug | `env.agent_policies[id].nominal_policy` — **env 필드** | ❌ 규칙·상태 모두 불변. `deepcopy(env)` 로 갈래마다 자동 격리 |
| ② PotentialField | `env.agent_policies[id].dispersion_policy` — **env 필드** | ❌ 같음 |
| ③ RVO2 | **프로세스 전역** `RVO_SIM_WRAPPER` + id map | ⚠️ 규칙은 불변. **격리가 자동이 아니라서** 갈래 전환 시 재구축 필요(정정 2) |
| α 우선순위 | `set_rvo_priority!` · `env.agent_parent_build_step_active` | ❌ 규칙 불변. 재구축 시 재적용 범위만 주의 |

**결론: 세 계층의 어떤 규칙도 바뀌지 않는다.** 유일한 작업은 ③ 이 전역이라 갈래 간 누수를
막는 배선이고, 그것도 기존 구성 경로를 그대로 쓴다.

🔴 **다만 경량 레인은 세 계층을 아예 돌리지 않는다.** `advance_to_rate_boundary!` 는 계획 경로
위의 직선 보간으로 pose 를 옮긴다. 그러므로 **경량 모델은 혼잡·교착을 원리적으로 볼 수 없다.**
그 격차가 곧 §5-4 의 `ρ` 이고, N-G2 가 재는 것이다. "경량 롤아웃이 교착을 예측한다"고
주장하면 안 된다.

### 5-3. `sample_sojourn` — dt 루프가 없다

```julia
function sample_sojourn(s, rng)
    t = 0.0
    E = Dict(r => rand_exp1(rng) for r in robots(s))     # ξ 가 아니라 이 자리에서 뽑는다
    Ez = rand_exp1(rng)                                   # 함대 수준 zone 위험 (D-4)
    while true
        A, a = rate_params(s)                             # λ_r(u) = A_r·exp(a_r·u)   §2-1
        Δ_r  = inv_integrated_hazard.(A, a, E)            # §2-2. 발화 안 하면 Inf
        Δz   = Ez / λ_zone
        Δ_fail, who = findmin(vcat(Δ_r, Δz))
        Δ_node = T_plan_next(s)                           # rate boundary — 결정 epoch 아님 §2-4
        if Δ_fail < Δ_node
            return (t + Δ_fail, failure_event(who))
        end
        advance_to_rate_boundary!(s, Δ_node)              # closed 갱신 · mode 재분류
                                                          # usage·soc 선형 갱신 · pose 보간
        E  .-= integrated_hazard.(A, a, Δ_node)           # §2-2
        Ez  -= λ_zone * Δ_node
        t   += Δ_node
        project_complete(s) && return (t, :terminal)
        t > Δ_max && return (Δ_max, :horizon)
    end
end
```

### 5-4. `T_plan` 의 편향과 보정계수 ρ

`update_schedule_times!`(`essential_tg_coponents.jl:364-375`)가 이미 위상정렬로 `t0`/`tF` 를
채운다 — `T_plan_next` 는 **새 알고리즘이 아니라 배선**이다.

⚠️ 다만 `min_duration = duration_lower_bound(node)`(`task_assignment.jl:86`)는 **하한**이고,
실제 RVO 주행은 혼잡 때문에 더 길다. 스칼라 보정 `ρ ≥ 1` 하나를 무거운 레인에서 적합해
곱한다. 논문 식 (4) 의 닫힌 형태 time block 이 하는 일과 정확히 같은 역할이다.

**정확도가 아니라 편향 방향이 판정 기준이다** — `ρ` 보정 후 편향이 팔 간 비교를 뒤집는지만
본다(선행 §11-3 의 판단을 그대로 승계).

---

## 6. 코드 변경 목록

| # | 파일 | 변경 | 종류 |
|---|---|---|---|
| **C1** | `src/smdp/simstate.jl` | 19 → 26필드. `CourierRec.step_*` → `t_out`/`t_swap`. `canonical` 갱신. `_BLOCK_NAMES` 에 `:prog` 추가 | 수정 |
| **C2** | `src/smdp/observe.jl` | 🔴 **`simstate_of(env)::SimState`**. 실측: 지금 env 에서 `SimState` 를 만드는 코드가 **한 줄도 없다**. 이게 없으면 아래 전부가 검증 불가 | **신규 · 병목** |
| **C3** | `src/smdp/tplan.jl` | `node_duration(s,v)` · `T_plan_next(s)` · `T_done(s)` · 보정계수 ρ | 신규 |
| **C4** | `src/smdp/sojourn.jl` | §5-3 정확 표집기 + `rate_params(s)` | 신규 |
| **C5** | `src/smdp/hazard.jl` | `fire_require_spare=false`(D-3) · `mtbf_zone_s` 유한 기본값(D-4) · **`hazard_rate` 를 `s` 에서도 부를 수 있게** — 두 레인이 같은 λ 정의를 공유해야 한다 | 수정 |
| **C6** | `src/smdp/generative.jl` | `G(s,a;rng)` · `apply_action!` · `legal_actions(s, event)` | 신규 |
| **C-RVO** | `src/route_planning.jl:465-477` | `rvo_rebuild!(env)`(가드 없는 재구축)를 분리하고 `update_rvo_sim!` 을 그 위의 얇은 래퍼로. `apply_action!` **뒤에만** 호출. §5-2 정정 2 | 수정 |
| **C7** | `wm4.../oracle/gen_oracle_dataset.jl:121` | 🔴 `ACTION_NAME` 이 구 9팔 리터럴이라 새 어휘에서 `2 => "Deprioritize"`, `3 => "ForbidZone"` 으로 **틀리게 찍는다**. 레지스트리 파생으로 교체 | **수정 · 지금 오염 중** |
| **C8** | `wm4.../core/objective.json` | `generation` bump. 스칼라는 안 바꾼다(§4) | 수정 |
| **C9** | 선행 §1-E | 모든 팔 뒤 **공통 MILP 재풀이** | ⏳ 미구현분 |

---

## 7. 게이트

| 게이트 | 내용 | 판정 |
|---|---|---|
| **N-G0 `simstate_of` 왕복** | `simstate_of(env)` 가 실제 env 를 충실히 읽는가. 필드별 음성 대조(env 를 흔들면 해시가 갈리는가) | 🔴 신규 · **1순위** |
| **N-G1 sojourn 정확성** | 같은 시드에서 `sample_sojourn` 의 τ 분포 vs `hazard_step!` dt-루프의 τ 분포. **정확 표집이므로 KS 검정이 통과해야 한다** — 근사가 아니다 | 🔴 신규 · §2 의 유일한 검증 |
| **N-G2 `T_plan` 충실도** | ρ 보정 후 편향이 팔 간 비교를 뒤집는가 | 선행 §11-3 승계 |
| **N-G3 λ 교정** | 관측 도착률 vs 모델. 현행 Poisson 95% CI `[0.24, 7.22]` — 못 쓴다 | 선행 §3 승계 |
| **N-G4 RVO 파생성** | 재구축 후 모든 에이전트 위치가 `global_transform` 과 일치하는가. **깨지면 롤아웃 문제가 아니라 기존 실행 레인의 버그다** | 🔴 신규 |
| **N-G5 보상 분해** | 한 판에서 `Σ τ_k == makespan` 이고 `Σ ΔE_k == energy_J` 인가 (부동소수 허용오차 내) | 🔴 신규 · §4 의 검증 |
| **G-S** τ 의 행동 의존 | ✅ PASS (49/64, p=4.39e-21). 문장만 `T_plan` 으로 | 승계 |
| **G2** 결정 커플링 | ✅ PASS (0.203 / suffix 0.984) | 승계 |
| **G3** τ > 0 | 🔴 미구현. 실측 최소 τ = 1 dt = 실패선 한 양자 위 | 승계 |
| ~~G1 snapshot~~ · ~~G-M Markov~~ · ~~G6~~ | 선행 §11-2 폐기 유지 | ⛔ |
| ~~N-3-4 검열 회계~~ | **D-3 으로 소멸** — 검열 자체가 없어졌다 | ✅ 해소 |
| ~~N-3-5 zone 구조적 0~~ | **D-4 로 해소** | ✅ 해소 |

⚠️ **"G6 PASS" · "G3 PASS" 를 어디에도 쓰지 말 것.** 선행 문서 §9 그대로.

---

## 8. 순서

```
[0] 즉시 — 지금 데이터를 오염시키는 것
     C7  ACTION_NAME 오라벨          (~30분)
     C8  generation bump

[1] 병목 — 없으면 아래 전부가 검증 불가
     C2  simstate_of(env)   →  N-G0
     C1  simstate 26필드
     +   갈래 비용(env 분기) 측정                  ← §9 미해결 1

[2] τ 의 두 성분. [1] 뒤에 병렬 가능
     C5  hazard 두 손잡이 + hazard_rate(s,·)
     C4  sojourn.jl         →  N-G1   (정확 표집 vs dt-루프, KS)
     C3  tplan.jl           →  N-G2   (ρ 적합)

[3] 생성 인터페이스
     C6  generative.jl + C-RVO  →  N-G4
     C9  공통 MILP 재풀이
         →  N-G5 (보상 분해)

[4] 데이터
     hazard-on 재스윕       →  N-G3 (λ 교정)
     ⚠️ 예비 수·워치독을 **먼저** 정할 것. D-3 으로 미완주 판이 늘어나므로
        선행 문서 N-7-1 이 더 급해졌다
     ⚠️ 도장 축(선행 N-7-2)·소비처 배선(N-7-3)은 그대로 살아 있다

[5] MCTS + UCT(표준형) + root parallelization
     N-11-1 트리 노드 키  →  N-11-2 read-set ablation
```

⛔ 이 순서에 `snapshot`/`restore!`/dp 격자/G1/G-M 은 **없다**. 되살리자는 제안이 나오면
선행 문서 §11-2 를 먼저 읽을 것.

---

## 9. 이 문서가 주장하지 않는 것 · 미해결

1. **갈래 비용을 쟀다 (Task 5, 2026-08-20).** `G(s,a)` 의 1단계(`env′` 만들기 = `deepcopy(env)`)
   실측: `deepcopy_ms.median = 19.17 ms`(n=20, min 18.85 · max 23.00 ms) — 트랙터 씬(12 로봇,
   200 스텝 전진, `n_closed=134`)에서. **5–50 ms 구간** → 갈래를 마음껏 만들 수는 없다:
   **롤아웃당 갈래 1회로 제한한다(트리 노드마다가 아니라).** Task 12 는 이 제약 아래에서
   설계할 것 — 계획서 그대로는 못 간다. 참고로 `simstate_of` 관측 비용도 같은 자릿수다
   (`simstate_of_ms.median = 17.59 ms`) — 갈래 비용의 지배항이 `deepcopy` 단독이 아니라 env
   크기 전반일 가능성을 시사한다. 원자료: `results/smdp/branch_cost.json`, 측정 스크립트:
   `tools/monitor/measure_branch_cost.jl`.
   ⚠️ **이 값은 갈래 비용의 완전한 합이 아니라 하한이다.** §5-2b 가 확인했듯 3계층
   reactive policy 중 TangentBug·PotentialField 는 `env` 필드라 `deepcopy` 로 자동
   격리되지만, RVO2 는 프로세스 전역(`RVO_SIM_WRAPPER`, `src/rvo_interface.jl:107`)이라
   갈래 전환마다 별도 재구축(`rvo_rebuild!`, 아직 미구현·Task 11)이 필요하고 그 비용은
   여기 안 잡혀 있다.
2. **`simstate_of` 는 있고, N-G0 가 채웠다 — 다만 완전하다고 주장하지는 않는다.**
   `simstate_of(env)`(`src/smdp/observe.jl`, Task 4, 커밋 `5f8dd58b`+`18ed52db`)가
   구현됐고, `test/smdp_observe_gate.jl` 가 **378 단언 전부 통과**로 게이팅한다. 26필드
   중 21필드는 교란→해시 갈림→복원→해시 일치의 격리 실측이 딸려 있다(그 필드가 실제로
   해시에 닿는다는 증거). 게이트가 **못 세운 것**은 따로 있다:
   - **값 동등만으로 검사된 넷: `edges`·`binding`·`payload`·`mode`.** 스케줄 그래프·씬트리
     수술을 같은 프로세스 안에서 안전하게 되돌릴 방법이 없어 음성 대조(해시 갈림)를 못
     붙였다 — 값이 엔진과 같다는 것만 보인다.
   - **엔진 출처가 아예 없는 둘.** `build_delta` 는 상수 `(0.0,0.0)` 을 돌려준다(누적기가
     소스 어디에도 없음을 확인한 뒤 지어내지 않고 상수로 못박았다). `prog.active` 는
     spec §3-2(169줄, "그 정점이 **실제로 시작한** 시각")의 정의와 달리 **MILP 가
     계획한 `t0`** 를 나른다 — 실행 중 실제 시작 시각을 기록하는 실행 경로가 없다
     (`test/smdp_observe_gate.jl:293-319`). 이 격차는 **Task 8 의 `T_plan_next` 를
     구조적으로 막는다**. 둘 다 게이트에 전용 단언으로 못 박혀 있어서, 누가 진짜 출처를
     배선하면 그 단언이 먼저 빨개진다 — 그래서 지금은 안전하게 열어 둘 수 있다.
3. **λ 가 교정된 적이 없다.** `expected_hazard_events()` 는 미검증이고 Poisson 95% CI 가
   `[0.24, 7.22]` 다. 정확 표집기를 만들어도 **틀린 λ 를 정확히 표집할 뿐이다.**
4. **`mtbf_zone_s` 의 값이 아직 없다.** D-4 는 "켠다"만 정했다.
5. **`ρ` 가 스칼라 하나로 충분한지 모른다.** 혼잡은 활성 로봇 수에 의존할 수 있다.
   N-G2 가 그것을 드러낸다.
6. **명목 레인의 결정론은 여전히 디렉토리 단위다.** 실측 19.875 vs 19.050(다른 워크트리).
   이 설계에서 그것은 모델의 계약이 아니라 **실험 재현성** 문제로 격하된다(선행 §11-5 승계).
7. **`ReplayState` 의 `cum_*`/`thr_*` 는 남지만 CRN 근거로 인용하지 말 것.**
   §2-3 이 그것들을 모델에서 뺐고, 분산 감소 기전은 root parallelization 이다.
