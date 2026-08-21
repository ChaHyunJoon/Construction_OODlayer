# 축소 상태 SMDP + OOD layer + replay buffer — 설계

작성 2026-08-20 · 브랜치 `oracle-rebuild-night-2026-08-10` · 기준 커밋 `0ed0c4be`

선행: `2026-08-20-sojourn-generative-smdp-design.md`(이하 **선행 spec**) ·
`2026-08-20-assimilation-buffer-design.md`(이하 **버퍼 spec**) ·
`docs/superpowers/reports/2026-08-20-phase1-completion.md`(이하 **완료 보고서**)

---

## 0. 이 문서가 정하는 것 / 대체하는 것

지도교수 피드백 셋을 반영해 **상태·행동공간·평가·데이터 파이프라인의 정의를 다시 세운다.**

| 선행 문서 | 이 문서가 하는 일 |
|---|---|
| 선행 spec §3 (상태 26필드) | 🔴 **대체.** 판정 기준을 바꿔 **7필드**로 줄인다 |
| 선행 spec §3-4 (`_hz_excluded` 가 role·health 에서 유도된다) | 🔴 **철회.** 완료 보고서 §4-2 가 반례 둘을 실측했다. 유도를 고치지 않고 **유도를 안 하게** 만든다 |
| 선행 spec §2 (τ 의 닫힌 형태) | **유지.** 이 문서는 그 수학을 안 건드린다 |
| 선행 spec §4 (보상의 가법 분해) | **유지** |
| 선행 spec §5 (생성 시뮬레이터) | **유지**, 인자만 바뀐다(§2-6) |
| 버퍼 spec 전체 | 🔴 **격하.** 층화 reservoir + 2축 우선순위는 **ablation 후보**로 내리고, 표준 uniform replay buffer 를 기준선으로 세운다(§7) |
| 완료 보고서 §4-7 차단 이슈 A · B | **소멸.** §4 참조 — 고치는 게 아니라 필드가 없어져서 닫힌다 |

**안 정하는 것**: MCTS 의 트리 노드 키·UCT 상수·root parallelization(별도 계획) · surrogate 의
feature 설계 · `cell_mild_*` degraded 세대의 hazard 파라미터.

---

## 1. 지도교수 피드백 셋 — 원문과 그 번역

> **(1) Semi-Markov Process**: this does feel highly dimensional, so I guess I would start by
> either making assumptions about the space, that reduce what you have to predict/maintain a
> belief on (e.g., maybe you can decide that you know the fleet position because you have good
> enough sensors and that is something you can get rid of). Explaining it intuitively in a real
> world setting can help with this!

번역: **"동역학이 예측해야 하는 것" 과 "이미 아는 것" 을 가르고, 후자를 상태에서 뺀다.**
이 프로젝트에 적용하면 기준이 하나 더 강해진다 — §2-1.

> **(2) OOD event definition**: Yes that makes sense! These failure events seem different enough
> to classify one as OOD and one as known.

번역: 사건 종류 셋 중 하나를 **test-only OOD** 로 지정하고 나머지로 학습한다 — §6.

> **(3) Replay Buffer design**: I think replay buffers are pretty common, so I would definitely
> start there. They are most commonly used in RL literature though rather than with surrogate
> models, so we can explore different options if needed, but I would start here since its well
> studied.

번역: **표준 uniform replay buffer 를 기준선으로 먼저 세운다.** 층화·우선순위는 그 위의
ablation 이지 출발점이 아니다 — §7.

---

## 2. 상태 — 26 → 7 필드

### 2-1. 판정 기준 (사용자 결정, 2026-08-20)

| | 기준 | 결과 |
|---|---|---|
| 2026-08-20 아침 | 행동이 **편집하는** 것만 (write-set) | 19필드. `F(τ|s,a)` 정의 불능 |
| 선행 spec | `(s,a) ↦ (s⁺, F(τ|·), R)` 계산에 필요한 것 전부 | 26필드 |
| **이 문서** | **이미 하드코딩된 하위 정책의 관할이거나, `s` 안의 다른 값에서 다시 만들 수 있거나, 상수면 상태가 아니다** | **7필드** |

세 술어가 서로 배타적이지 않다 — 하나라도 걸리면 뺀다.

**현장 비유 (지도교수 요청 (1)의 "intuitively in a real world setting").**
현장에 관제 대시보드가 하나 있다. 로봇이 어디 있고 배터리가 얼마인지는 **텔레메트리로 그냥
보인다** — 추정할 필요가 없다. 충돌 회피와 경로 우회는 각 로봇의 온보드 스택이 알아서 한다 —
관제가 개입할 일이 아니다. 관제가 **모르는 것은 딱 하나, 다음 고장이 언제 오는가**이고,
관제가 **결정하는 것도 딱 하나, 고장이 났을 때 공정표를 어떻게 고칠 것인가**이다.
`s` 는 그 결정에 필요한 것만 담는다.

### 2-2. 전수 판정

| 필드 | 판정 | 근거 |
|---|---|---|
| `Fleet.pose` | 제거 | 3계층 reactive 스택(TangentBug→PotentialField→RVO)의 관할. 선행 spec 의 Global Constraint 가 "이 정책 로직을 바꾸지 않는다" 로 관할을 이미 확정했다 |
| `Fleet.payload` | 제거 | 운반유닛 계층(`capture_robots!`)의 관할. `mode == :carry` 와 중복 |
| `Fleet.role` | 제거 | 개체 태그를 읽는 소비처가 없다. §2-4 의 멤버십으로 대체 |
| `Fleet.health` | 제거 | §2-4 의 멤버십으로 대체 |
| `Fleet.eff` (ε_r) | 제거 | **단, D-5 가 선행 조건**(§3). 그냥 빼면 잠재변수 혼합이다 |
| `Fleet.mode` | 제거 | `prog.closed` + `g.edges` + `g.binding` + 정적 씬의 **파생값**. 선행 spec §3-4 가 "노드 소요시간" 에 쓴 논리와 같다 |
| `Geo.build_delta` | 제거 | 완료 보고서 §3-5(a): 엔진에 출처가 없어 **상수 `(0,0)`**. 상수는 상태가 아니다 |
| `G.wedge_edges` | 제거 | **`edges` 의 부분집합**(§2-3). 읽는 것은 하드코딩 복구 루틴 `resolve_schedule_wedge!` |
| `G.dissolved_gates` | 제거 | 🔴 파생이 **아니다**(§2-3). 손실 압축으로 뺀다. 손실 크기는 측정한다 |
| `Prog.active` | 제거 | **`frontier(closed, edges)` 의 파생값**(§2-3). 값(시작시각)은 D-6 으로 불필요해진다 |
| `Prog.t` | 제거 | 이 정식화는 undiscounted · time-homogeneous SSP-SMDP 다. 절대시각이 상태에 있으면 **같은 상황이 시각별로 다른 트리 노드가 되어 통계가 쪼개진다** |
| `Courier` 8필드 | 제거 | `battery_courier_step!` 의 관할. 동역학은 `env.BATTERY_DELIVERIES[]` 에서 읽는다(§2-5) |
| `G.edges` | **유지** | 행동이 편집하는 대상 그 자체. `T_done` 의 입력 |
| `G.binding` | **유지** | `Replace` 가 재스탬프. `mode` 유도의 입력 |
| `Geo.poses` | **유지** | 🔴 `RelocateBuild` 가 `s` 에 남기는 **유일한** 흔적 (완료 보고서 §3-3) |
| `Geo.zones` | **유지** | 행동이 편집 + rate boundary 를 가른다. **기하까지** 나른다 |
| `Fleet.soc` | **유지** | λ 의 `exp(β_s(1−soc))` + `SwapBattery` 의 흔적 |
| `Fleet.usage_s` | **유지** | λ 의 `exp(β_u·û)` + 🔴 `Replace` 의 흔적 (§2-4) |
| `Prog.closed` | **유지** | 흡수상태 판정 + `active` 유도의 입력 |

### 2-3. 파생 주장의 실측 근거

**(a) `active = frontier(closed, edges)`** — `essential_tg_coponents.jl:1921-1932` 의 활성화
규칙 전문이 *"모든 선행이 `closed_set` 에 있으면 활성"* 이다. 순수 DAG frontier 다.

**(b) `wedge_edges ⊆ edges`** — 추가 지점 둘(`replace_robot.jl:297-298`, `:424-425`)이 모두
`add_edge!(sched, …)` **직후** `push!(WEDGE_EDGES[], …)` 이고, 제거 지점(`:1035-1036`)도
`rem_edge!` 직후 `filter!` 다. 장부는 "내가 추가한 엣지가 어느 것인가" 를 기억할 뿐이다.

**(c) 🔴 `dissolved_gates` 는 `edges` 의 여집합이라 복원되지 않는다.** `edges` 가 같은 두
상태가 "아직 안 넣은 엣지" 와 "복구가 풀어 준 엣지" 로 갈릴 수 있고, 그 차이가 미래
`_enforce_serial_frontiers!` 의 동작을 가른다. 빼는 근거는 파생이 아니라 **손실 압축 허용**
(CLAUDE.md 2026-08-20 아키텍처 전환: `s` 는 트리 노드를 색인할 뿐이다).
→ **측정 의무**: 스윕에서 `DISSOLVED_GATES[]` 가 비어 있지 않은 판의 비율을 센다.
0 에 가까우면 공짜이고, 아니면 그 수를 산출물에 남긴 채 뺀다.

**(d) `binding` 이 `edges` 에서 유도되는지는 아직 모른다.** `GraphBlock.edges` docstring 이
"precedence + **배정 엣지**" 라고 적으므로 유도 가능성이 있고, 유도되면 8 → 1 이 더 준다.
→ **측정 의무**. 유도되면 다음 세대에서 뺀다. 이 세대에서는 **유지**한다.

### 2-4. 멤버십이 `role`·`health` 를 대체한다 — 차단 이슈 B 가 여기서 닫힌다

선행 spec §3-4 는 `_hz_excluded()` 의 제외 집합이 `role`+`health` 에서 **유도된다**고 적었고,
완료 보고서 §4-2 가 살아 있는 env 에서 **반례 둘**을 측정해 그것을 뒤집었다(배송 중인 예비 ·
반출된 예비). 유도 규칙을 고치는 대신 **유도를 없앤다**:

> **`s.fleet` 의 멤버십 = "지금 위험에 노출된 로봇".**
> `simstate_of` 가 `_hz_excluded()`(= `active_spares()` ∪ `checked_out_spares()` ∪
> `keys(faulted_robots())`, `hazard.jl:394-402`)를 **직접 불러서** 뺀다.

귀결 셋:
1. 경량 레인(`rate_params`)과 무거운 레인(`hazard_step!`)이 **구성상 같은 집합** 위에서
   위험을 적분한다 → 게이트 N-G1 이 유효해진다.
2. `role` 어휘가 `RECOVERY_SPARES`·`CHECKED_OUT_SPARES` 를 못 담던 부채(완료 보고서 §5-1)가
   소멸한다 — 담을 어휘 자체가 없어졌다.
3. 죽은 로봇은 태그가 아니라 **부재**로 표현된다.

**`usage_s` 가 `Replace` 의 흔적인 이유** — `hazard.jl:296` 의 `_hz_ensure!` 가 새 로봇 등록 시
`st.usage_s[id] = 0.0` 을 찍는다. 즉 `Replace` 가 사는 것이 정확히 **마모 리셋**이다.
`usage_s` 를 빼면 λ 관점에서 `Replace` 와 `NOOP` 이 구분되지 않고, 그것은 완료 보고서 §3-3 이
`Geo.poses` 에서 잡아낸 "팔이 상태에서 투명해지는" 사고와 같은 모양이다.

### 2-5. `SwapBattery` 는 결정 시점에 `s` 에 흔적을 안 남긴다 — 트립와이어

배송 진행은 `env.BATTERY_DELIVERIES[]`(`battery_courier.jl:99`)에 살아 있고 경량 레인 함수는
전부 `(s, env)` 를 받으므로 **동역학은 온전하다.** 잃는 것은 트리 노드 식별력뿐이다:
`SwapBattery` 직후의 `s⁺` 가 `NOOP` 직후와 같다(배송 나간 예비는 `_hz_excluded()` 로 빠지고,
나머지 7필드 중 어느 것도 안 움직인다).

> 🔴 **트립와이어.** Phase 8(MCTS)이 transposition table 또는 `state_hash` 기반 노드 병합을
> 도입하면 `SwapBattery` 자식과 `NOOP` 자식이 한 노드로 합쳐진다. 그때는 **비행 중 배송을
> 나르는 필드를 `s` 에 되돌려야 한다.** 표준 MCTS 는 경로 색인이라 그 전까지는 필요 없다.
> CLAUDE.md 가 이미 `state_hash` 기반 병합을 금지하고 있다(생산 소비처 0개).

### 2-6. 확정 정의

```
s = (G, Geo, Fleet, Prog)                                     7 필드

G      edges   :: Set{Tuple{Int,Int}}
       binding :: Dict{Int,Int}                               2
Geo    poses   :: Dict{Int,NTuple{3,Float64}}   # 조립체
       zones   :: Dict{Symbol,NTuple{3,Float64}}  # key => (cx,cy,r)   2
Fleet  Dict{Int,RobotRec},  RobotRec = (soc::Float64, usage_s::Float64) 2
Prog   closed  :: Set{Int}                                    1
```

로봇 12대 기준 로봇 상태벡터 차원 **96 → 24**.

파생 접근자는 `s` 위의 **함수**로 둔다(필드가 아니다):

```julia
active_of(s)          = frontier(s.prog.closed, s.g.edges)
mode_of(s, env, rid)  = _hz_modes 규칙을 active_of(s)·s.g.binding·정적 씬에 적용
```

⚠️ `mode_of` 가 `env` 를 받으므로 `rate_params` 도 `env` 를 받는다. 선행 spec 이 `rates.jl` 에
기대하던 "엔진 없이 단독 시험 가능" 은 `rate_params` 한 함수에서만 깨진다 —
`integrated_hazard`·`inv_integrated_hazard` 는 `(A, a, Δ)` 만 받으므로 그대로 순수하고,
§2 의 닫힌 형태를 수치적분과 대조하는 시험도 그대로 선다.

### 2-7. 팔의 흔적 대조 (투명해지는 팔이 없는가)

| 팔 | `s` 안의 흔적 |
|---|---|
| `NOOP` | 없음 (정의) |
| `Replace` | `usage_s` 리셋 · `binding` 재스탬프 · `edges` 편집 |
| `RelocateBuild` | `Geo.poses` |
| `SwapBattery` | 결정 직후엔 없음 → §2-5 트립와이어 |

---

## 3. 사용자 결정 (D-1 ~ D-8)

| # | 결정 | 무엇이 걸려 있나 |
|---|---|---|
| D-1 | 무기억성을 이용해 rate block 만 최소 추가 | 선행 spec. **유지** |
| D-2 | 롤아웃 = 진짜 respec + 경량 명목 구간 | 선행 spec. **유지** |
| D-3 | `fire_require_spare = false` | **유지, 근거 교체** — 예비가 충분하다는 가정(D-7)이 깨진 순간 고장이 **조용히 영구 음소거**되는 것을 막는 안전장치 |
| D-4 | `mtbf_zone_s` 를 유한값으로 | **유지.** 단 zone 은 이제 test-only OOD(§6)이므로 이 값의 교정이 OOD 도착률을 정한다 |
| **D-5** | **`drain_sigma = 0.0`** | 🔴 **신규.** `eff`(ε_r)를 상태에서 빼려면 동역학에서 먼저 없애야 한다 — §3-1 |
| **D-6** | **rate boundary 를 `t0` 경과가 아니라 미완 노드의 계획 duration 에서 낸다** | 🔴 **신규.** 완료 보고서 §4-1 차단 이슈 A 의 해소 경로 — §4 |
| **D-7** | **창고 예비는 충분하다** | 🔴 **신규.** 예비 재고를 상태·행동 메뉴에서 뺀다 — §3-2 |
| **D-8** | **행동 신설을 L2 까지 허용한다** | 🔴 **신규(2026-08-21).** 제약 문법 + 파라미터 자유 원시연산을 LLM 에 노출하고, 재사용 우선 규칙을 둔다 — §5 |

### 3-1. D-5 — `eff` 를 상태에서 빼는 유일하게 정직한 방법

실측: `hazard.jl:100` 이 `drain_sigma = 0.15` 이고 `:295` 가
`st.eff[id] = _lognorm1(rng, st.params.drain_sigma)` 로 **로봇마다 다르게** 뽑는다.
그냥 상태에서 빼면 선행 spec §3-3 이 경고한 대로 **잠재변수 혼합**이 되어 `s` 에서 Markov 가
아니다 — 같은 `s` 가 서로 다른 방전율의 세계를 한 칸에 섞어 담는다.

**`drain_sigma = 0.0` 으로 동역학에서 없앤다.** 그러면 "배터리 개체차는 모델링하지 않는다" 가
`s` 의 침묵이 아니라 **hazard 손잡이로 선언된 가정**이 되고, `eff ≡ 1.0` 이라 상태에서 빠지는
것이 진짜로 공짜가 된다.

⚠️ 이 값은 **동역학을 가른다.** `generation` bump 대상이다(§8-3).

### 3-2. D-7 — 예비 충분 가정과 그 가드

**귀결 셋:**
1. `legal_actions` 의 예비 고갈 좁히기가 **삭제**된다. `Replace` 는 언제나 legal.
2. 예비 수 스윕(선행 계획 Task 15)이 **워치독 축만** 남는다.
3. `ForbidAgent` 가 `ReplaceAgent` 에 **약우월로 지배**된다 — §5-2.

🔴 **가정은 조용히 깨질 수 있다.** CLAUDE.md 알려진 한계 6번: `nearest_pool` 은 가장 가까운
창고 하나만 보므로 **전체 예비가 넉넉해도 그 창고가 비면** `pop_spare!` 가 `nothing` 을
돌려주고 `replan.jl:763` 이 `"empty_pool"` 로, `replace_robot.jl:1516` 이 `:no_spare` 로
강등한다. 그리고 그 신호는 전부 `@info`/`@warn` 이라 `Logging.Warn` 로거 아래에서는
**두 세대 모두 0건**으로 보였다("안 났다" 가 아니라 "못 본다").

> **가드**: 롤아웃·스윕 중 `pop_spare!` 가 `nothing` 을 돌려주거나 강등 경로를 타면 **죽는다.**
> 로그가 아니라 에러다. 가정이 조용히 거짓이 되는 경로를 없앤다.

---

## 4. 축소가 닫는 선행 차단 이슈, 남는 이슈

| # | 완료 보고서 §4-7 의 이슈 | 이 문서에서 |
|---|---|---|
| **A** | `Prog.active` 가 실제 시작시각이 아니라 MILP 계획시각 | 🟢 **소멸.** `active` 필드가 없다. D-6 이 rate boundary 를 `t0` 경과 없이 낸다 |
| **B** | `_hz_excluded` 가 `role`+`health` 로 유도 안 됨 | 🟢 **소멸.** §2-4 멤버십 인코딩 |
| C | `who`(Int) → `RobotID` 역함수 없음 | 🔵 남음. Task 9′ 가 역지도를 인터페이스에 추가 |
| D | `cell` 위험이 경량 레인에 없다 | 🔵 남음. Task 9′ 가 셋째 경쟁위험으로 추가. **`DeprioritizeAgent` 재평가 트리거이기도 하다**(§5-2) |
| E | hazard-off 에서 read-set 이 상수 | 🔵 남음. `enable_hazard!` 미호출 시 죽는 가드 |
| F | `s`/`env` 세대 도장 없음 | 🔵 남음. `s` 에 그래프 세대 도장 추가, 두 인자 받는 함수가 검사 |
| G | 갈래 19.17 ms — RVO 재구축분 미측정 | 🔵 남음. Task R4 가 축소 뒤 재측정 |
| H | `build_delta` 출처 없음 | 🟢 **소멸.** 필드를 뺐다 |

### 4-1. D-6 — rate boundary 의 새 정의

선행 계획 Task 8 은 `rem = ρ·dur(v) − (t − t0(v))` 를 썼고, 완료 보고서가 **활성 정점 15/15 가
`rem ≤ 0`** 임을 실측했다(`t0` 가 런 내내 0.0 에 붙박여 있어서). ρ 로는 못 고친다 — 활성 정점의
**8/14 가 `min_duration == 0.0`** 이라 `ρ·0 − (t−t0) ≤ 0` 이 모든 ρ 에 대해 참이다.

새 정의는 경과시간을 아예 안 쓴다:

```
T_plan_next(s, env; ρ) = ρ · min{ dur(v) : v ∈ active_of(s), dur(v) > 0 }
```

- **경과를 빼지 않는다.** `s` 에 시계가 없으므로 뺄 것도 없다. 이것은 "다음 완료까지 남은
  시간" 의 **상한 근사**이고, 경량 모델이 이미 ρ 로 흡수하는 종류의 편향이다.
- **`dur(v) == 0.0` 정점은 경계 후보에서 제외**한다. 0 을 돌려주면 `sample_sojourn` 이
  전진하지 못한다. 전부 0 이면 `Inf`(= 이 구간에 모드 변화가 없다).
- `T_done` 은 longest path 그대로이되 진행 중 노드의 잔여 보정을 **뺀다**(같은 이유).

⚠️ 이 근사가 τ 분포를 얼마나 흔드는지는 **게이트 N-G1(KS 검정)이 잰다.** 통과 못 하면 그것이
이 근사의 실패이지 닫힌 형태의 실패가 아니므로, 진단 시 둘을 갈라 볼 것.

---

## 5. 행동공간 — 세 층과 신설의 3단 사다리

### 5-1. 세 층

| | 무엇 | 누가 쓰나 |
|---|---|---|
| **`L_macro`** | `action_registry.json` 의 4팔 (`v3-4arms`) | surrogate · `Ĵ(a)` · MCTS 트리 |
| **`L_dsl`** | `RespecProposal{constraints::Vector{ConstraintSpec}, …}` — 이름 붙은 kind 들 | LLM escalation (오늘) |
| **`L_prim`** | 🔴 **신규.** MILP 제약 문법 + 파라미터 자유 수술 원시연산 | LLM 이 **신설**할 때 (§5-4·5-5) |

`L_macro` 는 `L_dsl` 에 파라미터를 고정한 투영이고, `L_dsl` 의 각 kind 는 `L_prim` 위의 **이름
붙은 지름길**이다. OOD 대응은 `L_prim` 에서 일어난다.

### 5-2. 🟢 `verify()` 는 이미 kind 무관이다 — 신설의 안전장치가 이미 있다

`verifier.jl:83-125` 의 일반 `verify(proposal, env, invariant)` 가 하는 일 넷:

```
(1) GRAMMAR      cs isa ConstraintSpec
(2) STATIC       referenced_ids(cs) ∩ invariant.closed_nodes == ∅   (과거를 안 건드린다)
(3) FEASIBILITY  formulate_milp(…; extra_constraints = proposal) → optimize! → FEASIBLE_POINT
(4) INVARIANT    satisfies_invariant(milp, env, invariant)
```

**넷 중 어느 것도 kind 를 안 본다.** MILP 로 컴파일되는 제약이면 무엇이든 이 검증을 통과해야
하고, 통과하면 안전하다. 실측 확인: `verifier.jl` 에 `verify_forbid_window` 도
`verify_forbid_agent` 도 **없다** — 그 둘은 처음부터 일반 검증만 받았다.

kind별 게이트(`verify_zone` · `verify_relocate` · `verify_replace` · `verify_swap_battery` ·
`verify_deprioritize` · `verify_reform`)가 따로 있는 이유는 그것들이 **MILP 에 도달하지 않는
기하/그래프 수술**이라 feasibility 로 검사할 수 없기 때문이다.

> **귀결**: 제약 티어의 행동 신설은 **오늘 이미 안전하게 검증된다.** 없는 것은 검증이 아니라
> **문법의 노출**이다.

### 5-3. 신설의 3단 사다리

| 수준 | 무엇 | 오늘 | 검증 |
|---|---|---|---|
| **L1** 파라미터 grounding | 어느 zone · 어느 로봇 · 어느 조립체 | ✅ | kind별 게이트 |
| **L2** 제약/기전 신설 | `(t0, tF, Xa)` 위의 아무도 안 짠 제약식 · 파라미터가 자유로운 수술 | 🔧 §5-4 · §5-5 | 🟢 일반 `verify()` + 일반 기하 검증기 |
| **L3** 기전 자체의 신설 | 코드에 없는 새 조작 | ❌ | — |

**L3 는 코드 생성 없이는 어떤 시스템도 못 한다.** 이것은 이 프로젝트의 한계가 아니라 범위의
선언이고, 그렇게 적는다. **L2 가 이 논문의 자리다.**

### 5-4. L2-a — MILP 제약 문법

`ForbidWindow` 와 `ForbidAgent` 는 **별개의 kind 가 아니라 같은 문법의 두 인스턴스**다:

```
ForbidWindow(v, t_lo, t_hi)  ≡  tF[v] ≤ t_lo  ∨  t0[v] ≥ t_hi        (Big-M 이접)
ForbidAgent(r)               ≡  Xa[v,v2] = 0   ∀ frontier 후보 엣지
```

🔴 **선행 판단 정정.** 이 문서의 초판은 두 kind 를 **삭제**하자고 적었다(매크로로서 죽었다는
근거로). 그 판단은 **철회한다** — 삭제하면 §5-2 의 일반 검증을 받는 **유일한 티어**가 통째로
사라진다. 매크로 어휘 `L_macro` 에서 빠지는 것은 그대로이고(이미 `v3-4arms` 에 없다),
`L_prim` 에서는 **문법의 인스턴스로 남는다.**

노출할 문법 (최소):

```
Constraint := Linear | Disjunction | Fix
Linear     := Σ cᵢ·Var ⋛ b            Var ∈ {t0[v], tF[v], Xa[v,v2]}
Disjunction:= Linear ∨ Linear          (Big-M 으로 컴파일)
Fix        := Xa[v,v2] = 0 | 1
```

- 노드·엣지·로봇은 **프롬프트가 준 목록에서 echo** 한다(좌표·id 를 지어내지 않는다 —
  `schema.py` 가 이미 강제하는 규약).
- `compile_constraint!` 의 기존 두 메서드가 이 문법의 백엔드가 된다.
- 검증은 **아무것도 새로 안 짠다**. `verify()` 그대로다.

### 5-5. L2-b — 수술 티어의 원시연산 노출

🔴 `RelocateBuild(zone)` 은 action 이 아니라 **solver 다.** 실측
(`restage_zone.jl:768-779`):

```julia
function translate_whole_build!(env; zone_keys = …, resume, verbose)
    Δ = _find_min_translation(env; zone_keys)          # ← Δ 를 함수가 스스로 찾는다
    Δ === nothing && (Δ = _find_clear_translation(fc, fR, env; zone_keys))
    _apply_uniform_translation!(env, Δ)                # ← 진짜 원시연산은 이것
```

"빌드를 옮긴다" 는 결정과 "Δ 를 찾는" 알고리즘이 한 덩어리다. 그래서 LLM 에 `RelocateBuild` 를
주면 그것은 **감춰 둔 매크로를 도로 고르는 것**이지 신설이 아니다.

> **원시연산을 그대로 노출한다**: `TranslateBuild(dx, dy)`.
> `_apply_uniform_translation!(env, Δ)` 이 이미 그 시그니처다.

귀결 넷:
1. known 세계(fault · battery)는 이 원시연산을 **한 번도 쓰지 않는다**
2. zone 사건에서 LLM 은 프롬프트의 ZONES 기하를 보고 **"빌드가 비켜야 하고 이만큼이면 된다"를
   스스로 유도**해야 한다
3. 검증은 **일반 기하 검증기**가 한다 — 옮긴 배치가 모든 zone 을 벗어나는가 · 도달 가능한가 ·
   `build_invariant` 를 지키는가. kind 를 안 본다
4. 🟢 **`_find_min_translation` 이 baseline 이 된다.** LLM 의 Δ 와 알고리즘의 최소 Δ 를 비교하는
   측정이 공짜로 생긴다

같은 방식으로 노출 가능한 원시연산이 더 있다(`restage_assembly!` · `replace_robot!` 의 그래프
splice). **이 세대에서는 `TranslateBuild` 하나만 연다** — zone 이 유일한 OOD 이므로 필요한 것이
그 하나이고, 나머지는 근거 없이 표면적을 넓히는 것이다.

### 5-6. 🔴 합성 gap — `maybe_respecify!` 는 first-match-wins 다

`replan.jl:452 · 529 · 679 · 798 · 898` 의 다섯 dispatch 분기가 **각각 `return` 한다.** 그래서

```julia
RespecProposal([RelocateBuild(:z3), ReplaceAgent(R7)])
    → _is_relocate_build 가 먼저 걸림 → RelocateBuild 만 집행하고 return
    → ReplaceAgent 는 조용히 버려진다
```

`constraints` 가 벡터인데 집행은 하나뿐이다. 여기엔 죽은 매크로가 하나도 안 끼어 있다 —
살아 있는 kind 셋만으로 발생한다. 그리고 test-only 4 case 중 **셋(`fault_zone` ·
`battery_zone` · `all`)이 다중 사건 epoch** 라, 순차 집행이 없으면 그 세 case 에서 LLM 이 무엇을
내든 하나만 먹힌다.

**순차 집행의 두 요구:**
1. **순서 규칙** — 기하(`TranslateBuild`) → 그래프(`ReplaceAgent`) → 배송(`SwapBattery`),
   `rvo_rebuild!` 는 **맨 끝**(선행 spec §5-2 의 핀 경고).
2. 🔴 **제약마다 직전 재검증** — `verify_*` 는 집행 전 상태에서 판정한다. 첫 집행이 둘째의
   전제조건을 무효화할 수 있고, 조용히 지나가면 `already_clear` / `:residual_blocked` 류의
   **무성 no-op** 이 된다.

### 5-7. 재사용 우선 규칙 (사용자 결정 D-8)

> 신설이 목적이 아니다. LLM 은 **먼저 기존 매크로로 대응 가능한지 판단하고**, 가능하면 그것을
> 쓰고, 아니면 `L_prim` 에서 합성한다.

이 규칙은 프롬프트에 명시되고 **양방향 지표로 측정된다**:

| 지표 | known 3 case 에서 | zone case 에서 |
|---|---|---|
| 합성률 (`L_prim` 사용 비율) | **낮아야 한다** — 높으면 과잉 합성 | **높아야 한다** |
| 재사용률 (`L_macro` 사용 비율) | 높아야 한다 | **낮아야 한다** — 높으면 탐지 실패 |

한 지표쌍이 양방향 음성 대조를 동시에 준다.

### 5-8. `L_dsl` 이 오늘 실제로 무엇인가 (전수 대조)

| kind | 상태 | 대응 사건 |
|---|---|---|
| `ReplaceAgent` | ✅ | fault |
| `SwapBattery` | ✅ | battery |
| `RelocateBuild` | ✅ 이지만 **solver 다** — `L_prim` 의 `TranslateBuild` 로 분해(§5-5) | zone |
| `ForbidZone` | ❌ **도메인 공집합** — `closed≈46` 부터 `n_restage_feasible == 0`, 이후 전부 조용한 no-op | (zone, 죽음) |
| `ReformTeam` | ❌ 은퇴. 복구가 `maybe_unwedge_nominal!` 로 명목 레인에 이관 | — |
| `ForbidAgent` | 🔧 매크로로는 죽음(D-7 이 `ReplaceAgent` 로 지배). **문법 인스턴스로 존속**(§5-4) | fault |
| `ForbidWindow` | 🔧 대응 사건 없음. **문법 인스턴스로 존속**(§5-4) | — |
| `DeprioritizeAgent` | ⏸ 제안 338 · **선택 0회**. 이슈 D 가 닫히면 재평가 | `cell`(degraded-but-alive) |

---

## 6. OOD — `zone` 이 test-only 다

### 6-1. 분할

기존 7 case 구조를 그대로 쓴다.

| | case | 역할 |
|---|---|---|
| **known (학습)** | `fault` · `battery` · `fault_battery` | 라벨셋 · surrogate 가 보는 세계 |
| **OOD (순수)** | `zone` | 가장 깨끗한 판정 |
| **OOD (혼합)** | `fault_zone` · `battery_zone` · `all` | known + OOD 동시 도착. §5-6 이 필요한 자리 |

### 6-2. known 세계에서 무엇이 사라지는가 — 매크로가 아니라 **기전 전체**다

`zone` 을 빼면 다음이 전부 known 세계 밖으로 나간다:

1. `RelocateBuild` 매크로 (surrogate support 가 `{0, 1, 3}` 이 된다)
2. 🔴 **`TranslateBuild` 원시연산도** — known 레인은 빌드를 옮기는 기전을 **한 번도 쓰지 않는다**
3. `RESTRICTION_ZONES` 를 읽는 어떤 대응도

즉 known 세계의 정식 서술은 **"제조 현장에서 일어나는 일은 로봇 고장과 배터리 방전 둘뿐이다"**
이고, 대응은 `Replace` · `SwapBattery` 둘뿐이다. zone 은 그 세계관 **밖에서** 도착한다.

**이것이 결함이 아니라 설계 의도다.** 다만 CLAUDE.md 2026-08-14 절이 기록한 실패 모양과
겉모습이 같다(*"support 가 `{0,1,2,7,8}` 이라 reform 에서 NOOP 밖에 못 골랐다"*). 그때는
버그였고 지금은 의도다 — **산출물 도장에 `train_kinds` 축을 추가**해 기계가 그 차이를 읽게 한다.

### 6-3. 탐지는 decision-space 기준 (랩미팅 합의 #2)

severity 임계값을 쓰지 않는다. **split conformal**:

1. known 3 case 의 held-out 조각을 calibration set 으로 `Ĵ(a)` 잔차의 `(1−α)` 분위수 `q` 를 잰다
2. 각 팔에 예측구간 `[Ĵ(a) − q, Ĵ(a) + q]`
3. **top-1 과 top-2 의 구간이 겹치면 escalate**

임계값이 사라지고 **α(위험 예산)** 하나만 남는다. 그것이 "원칙적" 이라는 말의 내용이다.

⚠️ zone 사건에서는 `L_macro` 의 팔이 `{NOOP, Replace, SwapBattery}` 뿐이라 **셋 다 나쁘고 서로
비슷하다**. 구간 겹침이 그 상황을 자연스럽게 잡아내는 것이 이 설계의 기대이고, 그것이
실제로 성립하는지가 N-G6 의 첫 축이다.

### 6-4. escalation 경로 — 문지기를 우회해 `L_prim` 으로 간다

🔴 `ood_mdp_shim.action_to_proposal` 이 `a in valid_actions(ctx) || return nothing` 으로 거른다.
CLAUDE.md: *"팔 메뉴가 아니라 문지기다. fault 가 리터럴 `[0,1]` 인 한 매크로 4 를 시켜도 조용히
NOOP 으로 무너진다."*

> escalation 은 **`action_to_proposal` 을 우회**해 `RespecProposal` 을 직접 만들고
> `verify` → `maybe_respecify!`(순차 집행판) 으로 간다. 그러지 않으면 escalate 해 놓고
> 닫힌 어휘로 되떨어진다.

🔴 그리고 `DSPY_PROGRAM=__seed_only__` 를 못박는다. 컴파일된 `dspy_real_program_gpt4o.json` 은
**battery 전용이라 zone 어휘가 없다**(CLAUDE.md). 안 맞추면 LLM 이 zone 에 실패했을 때
**추론 실패인지 어휘 부재인지 구분이 안 된다.**

### 6-5. 프롬프트가 명시해야 할 것 다섯

1. 알려진 매크로로 대응이 안 되는 사건일 수 있다는 **선언**
2. **재사용 우선 규칙**(§5-7) — 기존 매크로로 되면 그것을 쓴다
3. `L_prim` 문법 — MILP 제약 문법(§5-4) + `TranslateBuild(dx, dy)`(§5-5), 그리고 각각의
   **전제조건**(`schema.py` docstring 이 이미 담고 있는 수준)
4. **ZONES 섹션** — 활성 구역의 키와 기하 `(cx, cy, r)`. grounding 의 유일한 출처
5. `constraints` 가 **벡터**라 여러 제약·연산을 **합성**할 수 있다는 것

---

## 7. replay buffer — 표준 uniform 부터

### 7-1. 저장 단위는 SMDP transition

```julia
struct Transition
    s        :: SimState      # 7필드
    a        :: Int           # L_macro 0..3, 또는 escalation 이면 -1 + proposal 참조
    R        :: Float64       # −(τ + w_E·ΔE)
    tau      :: Float64
    s_next   :: SimState
    terminal :: Bool
    stamp    :: Stamp         # objective_hash · generation · vocab · train_kinds
end
```

`τ` 가 들어가는 것만 보통 RL 과 다르고, 그건 SMDP 라서다.

### 7-2. 버퍼는 진짜로 표준이다

```julia
mutable struct ReplayBuffer
    capacity :: Int                 # 고정. 기본 100_000
    data     :: Vector{Transition}  # 순환(ring). 차면 오래된 것부터 덮어쓴다
    idx      :: Int
    full     :: Bool
end
sample(rb, n; rng)                  # uniform, 비복원
```

**⛔ 이 세대에 안 짓는 것** (전부 버퍼 spec 에 있던 것, ablation 후보로 격하):
층화 reservoir(event type × severity) · `|Ĵ − 실현 J|` 우선순위 · instance 키 dict ·
pairwise 선호 환원.

이유 하나: **기준선 없이 복잡한 쪽으로 바로 가면 그 복잡도가 무엇을 사는지 영영 모른다.**
uniform 이 well-studied 한 바닥이고, 층화·우선순위는 "없을 때 실제로 무엇이 나빠지는가" 를
잰 뒤에만 얹는다.

### 7-3. 🔴 세대 도장이 버퍼에서 가장 조용하게 샌다

동역학이 갈린 뒤에도 버퍼에 옛 세대 transition 이 남아 있으면 **한 minibatch 안에 두 세계가
섞인다.** 에러가 안 나고 학습 곡선으로만 샌다. 이 레포가 반복해서 데인 "낡은 파일이 이번 세대의
참·거짓을 정한다" 의 버퍼 판이다.

> 1. 모든 transition 은 `(objective_hash, generation, vocab, train_kinds)` 도장을 단다.
> 2. 적재 시점에 현행 도장과 다르면 **죽는다.** 필터링·remap 하지 않는다.
> 3. 세대가 갈리면 버퍼를 **비운다.**

### 7-4. counterfactual 라벨이 여기로 들어온다

랩미팅 합의 #3(체크포인트에서 팔 전수 롤아웃)의 산출물이 곧 transition 4개다. 같은 `s` 에서
서로 다른 `a` 로 갈린 것들이 한 버퍼에 들어가고 uniform sampling 이 그대로 쓴다 — 별도 기전이
필요 없다. RW 의 *"exploration 용 stochasticity 가 필요한가"* 도 여기서 닫힌다:
**exploration 을 확률로 넣는 대신 체크포인트에서 전수로 넣는다.**

⚠️ 그 롤아웃들은 **같은 시드·같은 월드**에서 갈라져야 한다. 라벨 레인이 실행 레인과 세계가
갈려 `fault` 발화율이 100% → 23% 로 조용히 샌 적이 있다(`DS_HOTSWAP` 하나 빠뜨려서).
**버퍼 적재 지점에 그 검사를 단다.**

---

## 8. 게이트

| 게이트 | 무엇을 판정 | 어디 |
|---|---|---|
| **N-G0′** | `simstate_of` 가 env 를 충실히 읽는가 (7필드 음성 대조) | Phase 1R |
| **N-G1** | `sample_sojourn` 이 dt-루프와 같은 분포인가 (KS) | Phase 2 |
| **N-G2** | ρ 보정 뒤 팔 **순위**가 보존되는가 (Kendall τ) | Phase 2 |
| **N-G3** | 모델 λ 가 관측 도착률과 맞는가 (Poisson CI + χ²) | Phase 5 |
| **N-G4** | RVO 가 씬트리의 파생물인가 | Phase 3 |
| **N-G5** | 보상이 epoch 위로 가법적인가 | Phase 3 |
| **N-G6** | leave-one-failure-type-out — §8-1 | Phase 6 |
| **N-G7** | 다중 제약 집행이 단독과 **다른 결과**를 내는가 | Phase 4 |
| **N-G8** | 문법 왕복 — 문법으로 쓴 제약이 기존 kind 와 **같은 MILP 제약**을 만드는가 | Phase 4 |

### 8-1. N-G6 은 escalation률만 재면 안 된다

다섯을 함께 잰다:

1. zone OOD 에서 LLM proposal 의 **kind 분포** — `RelocateBuild` 가 나오는가
2. `verify_relocate` **통과율** — 내긴 냈는데 게이트에서 죽는가
3. 🔴 **집행이 세계를 실제로 바꿨는가** — `enact_applied=true` 는 *"효과 지점에 도달했다"* 이지
   *"세계가 바뀌었다"* 가 아니다. `RelocateBuild` 는 `:residual_blocked`/`:infeasible` 로,
   `ForbidZone` 은 `already_clear` 로 도달하고도 아무것도 안 바꾼다
4. **`L_macro` 음성 대조** — 같은 판을 4팔만으로 굴리면 NOOP 뿐인가
5. **known 3 case 의 escalation률이 α 근처인가** — 0 이면 구간이 너무 넓고, 높으면 conformal
   미교정
6. 🔴 **합성률 · 재사용률의 양방향 대조**(§5-7) — known 에서 합성률이 높으면 과잉 합성이고,
   zone 에서 재사용률이 높으면 탐지 실패다. 한 지표쌍이 양쪽 음성 대조를 동시에 준다
7. **LLM 의 Δ 대 baseline Δ** — `_find_min_translation` 이 낸 최소 이동과 비교한다(§5-5). 신설이
   "되긴 됐다" 와 "잘 됐다" 를 가른다

### 8-2. 게이트를 짜는 규칙

> **음성 대조를 먼저 실측한다.** 완료 보고서 §9 가 이 브랜치에서 "절대 실패할 수 없던 시험"
> 여섯 개를 찾았고 전부 초록불이었다. 초록불은 증거가 아니다.

### 8-3. 도장

이 문서가 가르는 축 셋:
- **D-5**(`drain_sigma`) · **D-6**(rate boundary) → 동역학이 갈린다 → `generation` bump
- **D-8**(`L_prim` 노출) → 행동공간이 갈린다 → `vocab` bump
- **train_kinds** → 산출물 도장에 **새 축**을 추가한다. 기존 도장 어느 것도 이 축을 못 나른다

---

## 9. 순서와 의존성

**계획서 A — SMDP 생성 시뮬레이터 + 행동 신설**

| Phase | 태스크 | 요지 |
|---|---|---|
| **1R** | R1 `SimState` 26→7 · R2 `simstate_of`+N-G0′ · R3 축소 근거 3건 실측 · R4 갈래 비용 재측정 | R3 = §2-3 (c)(d) + `active` 불변식 |
| **2** | 6′ hazard 손잡이(D-3·D-4·**D-5**) · 7′ `rates.jl` · 8′ `tplan.jl`(**D-6**) · 9′ `sojourn.jl`(이슈 C·D·E) · 10 ρ | 임계 경로 |
| **3** | 11 `rvo_rebuild!` · 12′ `generative.jl`(D-7 가드, 이슈 F) · 13 공통 재풀이 · 14 N-G5 | |
| **4** | C1 순차 집행 · C2 MILP 제약 문법(L2-a) · C3 `TranslateBuild`(L2-b) · C4 일반 기하 검증기 · C5 N-G7 · C6 N-G8 | §5. **D-8 의 집행** |
| **5** | C7 워치독 재설정 · C8 λ 교정(N-G3) | C7 은 선행 계획 Task 15 에서 **예비 축을 뺀 것**(D-7) |

**계획서 B — OOD layer + closed loop**

| Phase | 태스크 | 요지 |
|---|---|---|
| **6** | O1 라벨 분할 · O2 conformal · O3 escalation 배선 · O4 프롬프트 5항목 · O5 N-G6 | §6 |
| **7** | B1 버퍼 · B2 counterfactual 적재 · B3 재학습 루프 | §7 |

**Phase 8 (MCTS)** 는 별도 계획으로 남는다. §2-5 의 트립와이어를 그 계획이 물려받는다.

**의존성 두 개만 기억하면 된다**: Phase 4 는 Phase 3(공통 재풀이)이 있어야 제약이 실제로 해에
반영된다. Phase 6 은 Phase 4 가 있어야 escalation 이 `L_prim` 에 닿는다.

---

## 10. 이 문서가 주장하지 않는 것 · 미해결

1. **7필드가 충분하다고 주장하지 않는다.** 손실 압축을 명시적으로 허용했고(§2-3 (c)), 그 손실이
   실제로 아프면 트리 노드 키 설계(Phase 8)가 되돌린다. 조건은 §2-5 에 적었다.
2. **D-6 의 rate boundary 근사가 정확하다고 주장하지 않는다.** 상한 근사이고 N-G1 이 판정한다.
3. 🔴 **L3(기전 자체의 신설)은 못 한다**(§5-3). 코드에 없는 조작은 코드 생성 없이 만들 수 없고,
   그것은 이 프로젝트의 한계가 아니라 **범위의 선언**이다. `L_prim` 이 여는 것은 L2 까지다.
4. **`TranslateBuild` 말고 다른 원시연산은 이 세대에서 안 연다**(§5-5). zone 이 유일한 OOD 이므로
   필요한 것이 그 하나이고, 나머지는 근거 없이 표면적을 넓히는 것이다.
5. **미해결**: `binding` 이 `edges` 에서 유도되는가(§2-3 (d)) · `dissolved_gates` 손실 크기 ·
   `DeprioritizeAgent` 를 `cell` 사건에 되살릴 것인가 · ρ 가 스칼라 하나로 충분한가 ·
   갈래 비용의 RVO 재구축분 · MILP 제약 문법의 표현력 상한(어떤 대응이 문법 밖인가).
6. **범위 밖**: `cell_mild_*` degraded 세대의 hazard 파라미터 · MCTS · surrogate feature 설계.
