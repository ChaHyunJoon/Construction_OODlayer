# Stochastic-Failure TAMP as a Proper MDP — clean-slate design

작성일 2026-07-31. 기존 설계 문서/코드의 정의를 일절 참조하지 않고, 문제를 처음부터 다시
정식화한다. 목표는 "부분적/편의적 MDP"가 아니라, **transition kernel과 최적방정식이
수학적으로 닫히는 MDP**를 쓰고, 그 안에서 다음 아이디어를 유지하는 것:

> 라벨링된 적 없는 (처음 보는) OOD → LLM이 대응.
> 한 번이라도 경험한 OOD → surrogate가 cost-efficient하게 대응.

---

## 0. 모델링 커밋먼트 (먼저 못 박고 시작)

| 항목 | 선택 | 이유 |
|---|---|---|
| 관측 | **중앙집중 full observability** (coordinator가 전 로봇 상태를 안다) | 통신 제약이 문제의 본질이 아님. 제약 넣으면 Dec-POMDP가 되고 novelty가 통신으로 옮겨감. 단, latent degradation은 예외 (§3) |
| 시간 | **continuous-time hybrid system 위의 SMDP** (event-triggered decision epoch) | 저수준 실행(motion planning + reactive avoidance)은 dt 단위, 결정은 초~분 단위. 같은 시간축에 두면 horizon이 10^5로 터짐 |
| 목적 | **undiscounted SSP (stochastic shortest path)**, 흡수상태 = 조립 완료 | makespan 최소화는 goal-reaching cost. discount γ<1 은 makespan을 왜곡함 |
| 행동 | **parameterized options (macro) 위의 SMDP**, 단 옵션집합은 **열려 있음** | 원시 assignment 공간은 NP-hard·조합폭발. 옵션으로 제한하되 그 제한으로 인한 최적성 gap을 명시적으로 측정 (§4.4) |
| 확률성 | **failure point process가 유일한 exogenous 확률원** | "TAMP에 failure를 stochastic하게 주입해 stochastic MDP로 바꾼다"는 요구를 그대로 형식화 |

---

## 1. 시간 모델: 왜 SMDP인가, decision epoch은 언제인가

기저 시스템은 hybrid: 연속 상태(로봇 pose, SoC, 부품 pose)가 ODE로 흐르고, 이산 상태(build
step 상태, assignment)가 이벤트로 점프한다. 여기에 **결정 시점(decision epoch)** 을 정의한다.

decision epoch τ_0 < τ_1 < ... 은 아래 이벤트 중 **먼저 오는 것**에서 발생:

- **E1 (failure)**: 로봇 r의 sudden breakdown, 또는 SoC가 임계 e_min 도달
- **E2 (task completion)**: 로봇이 transport/place를 끝내 free 상태가 됨 → 재배정 여지 발생
- **E3 (build step transition)**: precedence가 풀려 새 build step이 open됨
- **E4 (watchdog tick)**: 위 셋이 Δ_max 동안 없으면 강제 epoch (process well-definedness 보장)

epoch 사이에는 **저수준 폐루프 컨트롤러**(경로추종 + reactive collision avoidance + grasp/place
FSM)가 현재 커밋된 plan을 실행한다. 즉 옵션의 internal policy가 곧 저수준 실행기다.

holding time:

```
τ_{k+1} − τ_k  =  min( T_plan_event(s_k, a_k),   min_r T_fail_r )
```

`T_plan_event`는 커밋된 plan이 결정론적으로 예정한 다음 E2/E3 시각, `T_fail_r`은 §5의
hazard process에서 나오는 확률변수. 이 min 구조가 **holding-time 분포 F(τ | s, a)를 명시적으로
준다** — SMDP가 well-defined해지는 지점이다.

> 핵심: 확률성이 "가끔 노이즈를 뿌린다"가 아니라 **다음 결정 시점 자체를 확률화**한다.
> 같은 (s, a)에서도 어떤 실행에서는 계획대로 E2에 도달하고, 어떤 실행에서는 그 전에
> 로봇이 죽는다. 이것이 이 문제를 진짜 stochastic하게 만드는 유일하고 충분한 메커니즘.

---

## 2. 상태공간 S — 전체 정의

s = (X_A, X_R, X_G, X_C, X_H). 각 블록은 "빼면 Markov가 깨지는가"를 기준으로 넣었다.

### 2.1 X_A — assembly / task-network state (조립 논리)

정적 구조: assembly tree `T = (P, B, ≺)` — 부품 P, build step B, precedence ≺.
동적 부분:

- 각 build step b ∈ B: `status_b ∈ {blocked, open, in_progress, closed}`, 설치 완료된 부품 집합
- 각 부품/서브어셈블리 p: `phase_p ∈ {at_source, in_transit, staged, installed}`
- 남은 task 집합 `Θ(s)` = 아직 안 끝난 transport/place 작업 (X_A에서 유도됨)

**왜 필요한가**: 앞으로 남은 문제의 feasibility와 critical path가 전적으로 여기서 결정됨.

### 2.2 X_R — fleet state (로봇당)

로봇 r ∈ R (활동 중 + **창고의 spare 포함**):

- `pose_r ∈ SE(2)`, `vel_r` — 속도까지 넣어야 reactive controller가 memoryless가 됨 (§3.2)
- `health_r ∈ {healthy, degraded, dead}`
- `soc_r ∈ [0,1]`
- `payload_r` — 운반 중인 부품 id + 상대 grasp transform (∅ 가능)
- `role_r ∈ {transport, cargo_team_member, idle, charging, spare_parked}`
- `usage_r` — 누적 주행거리 / 누적 부하적분 (**hazard가 이력에 의존하면 필수**, §3.1)

### 2.3 X_G — geometric state (공간)

- 운반 중이 아닌 모든 부품/서브어셈블리의 world pose
- staging 배치: 각 서브어셈블리에 배정된 staging 위치/반경
- 동적 장애물 집합 / no-go zone 집합 (OOD가 생성 가능하므로 상태에 포함)

### 2.4 X_C — commitment state (**대부분 빠뜨리는, Markov의 핵심**)

- 현재 assignment σ: `Θ(s) → 로봇(팀)`, partial map (미배정 = 유예)
- 각 in-flight task의 진행도: 시작 시각, 계획 경로, 남은 경로 인덱스
- 팀 편성(cargo team membership), 예약된 staging slot

**왜 상태인가**: plan은 "생각"이지 물리가 아니니 상태가 아니라고 보기 쉽지만, 이 도메인에서는
**전환비용이 실재**한다 — 이미 절반 간 로봇을 돌리는 비용, 들고 있던 부품을 내려놓는 비용,
팀 재편성 비용. 전환비용이 있으면 "현재 커밋"은 미래 비용에 영향을 주므로 **정의상 상태의 일부**다.
X_C를 빼면 같은 물리상태에서 서로 다른 미래비용이 나와 Markov가 즉시 깨진다.

### 2.5 X_H — hazard / exogenous state

- 로봇별 hazard 파라미터 θ_r = (기저 고장률 λ_0r, drain 계수, 열화 계수)
- 전역 exogenous mode m (예: 먼지↑, 조도↓ → 고장률 전역 상승). **비정상성(drift)의 원천**
- θ_r, m 이 관측 불가면 belief b(θ, m)을 상태에 넣어 belief-MDP로 승격 (§3.1)

### 2.6 시계 t

비용을 `w_t · τ` (경과시간)로 매기면 process는 time-homogeneous하고 **t는 상태에서 빠진다**.
납기(deadline)나 시간의존 hazard를 넣는 순간 t를 다시 넣어야 한다. 현재 설계는 t 미포함.

---

## 3. Markov property — 위협과 수리, 그리고 **경험적 충분성 검정**

"Is the decision Markovian? Does the state encode all relevant information for the subsequent
assignment problem?" 에 대한 정면 답변. 결론부터: **위 s는 Markov가 되도록 설계되었고, 깨질 수
있는 통로가 5개 있으며 각각에 대해 수리 또는 승격 경로가 있다.**

### 3.1 위협 1 — 열화 기억 (degradation memory)
고장확률이 "얼마나 오래/무겁게 일했는가"에 의존하면 순간 pose/SoC만으로는 부족.
- **수리 A**: hazard를 관측가능한 `usage_r`, `soc_r`, `payload_r`의 함수로만 정의 → Markov 유지
- **수리 B**: 진짜 latent 열화 z_r 이 있다고 인정 → **belief b(z)를 상태에 포함** (belief-MDP는
  여전히 MDP). 이때 상태는 (물리상태, b) 이고, 관측은 "고장이 안 났다"는 survival 정보.
- **금지**: usage도 belief도 없이 그냥 넣기 → 이게 non-Markov의 1번 원인.

### 3.2 위협 2 — 저수준 컨트롤러의 내부 기억
reactive collision avoidance는 (pose, vel) 주어지면 memoryless. 경로추종기는 "경로 위 어디까지
왔는가"라는 인덱스를 들고 있다 → X_C의 잔여경로에 포함되어 있음. **속도를 상태에서 빼면 깨진다.**

### 3.3 위협 3 — 부분실행 기억
"서브어셈블리를 절반 배달한 로봇"은 `phase_p` + `payload_r` + 잔여경로로 완전히 표현된다. OK.

### 3.4 위협 4 — 비정상 exogenous mode (drift)
OOD 주입분포가 시간에 따라 변하면 stationary MDP가 아니다. 수리: mode m(또는 belief)을 상태에
포함 (§2.5). 포함 안 하면 **정의상 non-stationary POMDP**이고, 그때는 "이력 인코딩"이 필수가 된다.

### 3.5 위협 5 — 학습자의 기억을 환경상태와 섞는 것 (**가장 흔한 개념오류**)
"이 OOD를 전에 본 적 있는가"는 **환경의 상태가 아니다.** 환경은 우리가 뭘 배웠는지 모른다.
이것은 §9의 **meta-level 상태**다. 둘을 한 상태벡터에 섞으면 transition kernel이 정의되지 않는다
(환경 dynamics가 우리 데이터셋에 의존하게 되므로).

### 3.6 경험적 충분성 검정 (이론 주장 말고 실제로 재는 법)

φ(s)가 충분통계인지 **두 가지 검정**으로 반증 가능하게 만든다.

**T1. Conditional label variance test (직접적)**
같은 φ 근방(또는 정확히 같은 discrete 부분)에 도달한, **서로 다른 이력**의 상태쌍을 모은다.
각각에 대해 oracle 라벨 Q(s, ω)를 K회 몬테카를로로 구한다.

```
Var[ Q̂ | φ ]  =  Var_MC(몬테카를로 노이즈)  +  Var_hidden(φ가 못 담은 정보)
```
`Var_hidden ≈ 0` 이면 충분. 유의하게 크면 φ 불충분 → 무엇이 빠졌는지 residual을 이력 feature에
회귀시켜 범인을 찾는다.

**T2. History-augmentation subopt_norm test (실용적)**
φ와 φ⊕h(직전 h epoch의 이벤트/누적 카운터/이전 결정)로 각각 surrogate를 학습 → 동일 평가셋에서
**decision suboptimality**을 paired 비교. h를 넣어 subopt_norm이 유의하게 떨어지면 φ는 불충분했던 것.
(정확도가 아니라 subopt_norm으로 재는 이유는 §8.3.)

이 두 검정을 "설계가 옳다"의 증거로 리포트한다. 이게 리뷰어 질문에 대한 **실증적** 답이다.

---

## 4. 행동공간 A(s)

### 4.1 원시 행동공간 (참조용 정의)
epoch에서 coordinator가 실제로 바꿀 수 있는 것 전부:

```
a = ( σ'      : 남은 task → 로봇팀 배정 (재배정 포함)
    , Δfleet  : spare 투입 / 로봇 은퇴 / 충전 파견 / payload 소유권 이전(hot-swap)
    , Δgeom   : staging 위치 재배치, no-go zone 추가/삭제, 빌드 전체 평행이동
    , Δobj    : task 우선순위 가중치, 간선비용 승수(예: SoC-bias) )
```

이 공간은 `|robots|^|tasks|` 규모 + 연속 파라미터. **원시공간 위에서 Q를 학습하는 것은 불가능**하고,
사실 MILP 오라클도 이 공간 위의 argmin이다.

### 4.2 실사용 행동공간: parameterized options (SMDP)

각 옵션 ω = (I_ω, π_ω, β_ω): 개시집합 / 내부정책 / 종료조건.

| 옵션 | 파라미터 | 내부정책 π_ω (호출되는 solver) | 개시집합 I_ω |
|---|---|---|---|
| `CONTINUE` | — | 현 plan 그대로 실행 | 항상 |
| `REASSIGN(J)` | task 부분집합 J | J에 대해서만 assignment MILP 재해 | J ⊆ Θ(s) |
| `REPLACE(r → r')` | 죽은 r, spare r' | identity-preserving hot-swap 후 잔여 plan 유지 | r' 가용 spare, r ∈ {dead, degraded} |
| `RECHARGE(r)` | 로봇 r | r의 task 이관 + 충전소 경로 | soc_r > 0 |
| `DEPRIORITIZE(b)` | build step b | b 서브트리의 가중치 하향 → 전역 재스케줄 | b가 blocked 아님 |
| `RESTAGE(p, x)` | 부품 p, 새 위치 x | staging 재배치 + 영향받은 경로 재계획 | p ∈ staged |
| `FORBIDZONE(Z)` | 영역 Z | 항법 그래프에서 Z 제거 후 재라우팅 | — |
| `TRANSLATE_BUILD(Δ)` | 이동 Δ | 빌드 전체 평행이동 | 조립 초기 단계 |

**중요**: 옵션을 고르는 것은 "대략적 방향"을 고르는 것이고, **파라미터 채우기와 실제 plan 합성은
여전히 결정론적 solver가 한다.** surrogate는 plan을 만들지 않는다 — **옵션들 사이의 탐색을 없앤다.**
이 구분이 §10의 속도 논쟁의 핵심이다.

### 4.3 열린 행동공간 (open-world) — LLM의 진짜 역할

A는 고정집합이 아니다. 처음 보는 이벤트에서는 A_macro 안에 좋은 수선책이 아예 없을 수 있다.
그래서 생성자를 둔다:

```
g_LLM : (s, event e)  →  ω_new = (I_new, π_new, β_new)   [DSL로 표현된 새 옵션]
```

새 옵션은 **admissibility filter**(전제조건 검사 + 안전 제약 + 시뮬레이션 dry-run)를 통과해야만
A에 편입된다. 이때 MDP는 "action space가 시간에 따라 커지는 MDP"가 되고, 편입 시점 이전의
가치함수는 **하한**이 된다 (A ⊂ A' ⇒ V^{A'} ≤ V^{A}, 비용 최소화 기준). 이 단조성이 open-world
확장을 수학적으로 안전하게 만든다.

### 4.4 제한으로 인한 최적성 gap을 숨기지 않기

A_macro ⊂ A_raw 이므로 V^macro(s) ≥ V*(s). gap을 **측정**한다: 작은 인스턴스에서 원시공간 위
완전탐색(또는 긴 시간 MILP)으로 V*를 구해 `V^macro − V*`를 보고한다. "옵션으로 근사했다"가 아니라
"옵션 근사의 손실이 x%다"라고 말할 수 있어야 부분적 MDP가 아니게 된다.

---

## 5. Transition kernel P(s' | s, a)

두 단계로 분해된다. 이 분해가 커널을 실제로 시뮬레이션 가능하게 만든다.

### 5.1 결정론적 즉시 편집 (controlled part)
```
s⁺ = f(s, a)      — X_C, X_G, X_R.role 을 즉시 갱신. 확률성 없음.
```

### 5.2 확률적 실행 구간 (uncontrolled part)

holding time τ 동안:

**(a) 결정론적 흐름**: 저수준 컨트롤러가 pose/부품pose를 전개. SoC는
```
d soc_r/dt = −( c_idle + c_move · ‖v_r‖ + c_load · m_payload,r ) · (1 + ε_r)
```
ε_r 은 로봇별 랜덤 효율편차 (에피소드 내 고정 또는 OU 프로세스) → **배터리는 "예측가능하지만
불확실한" 점진적 위험**이 된다. ε=0이면 배터리는 확률적이지 않다는 점을 명심.

**(b) 급작 고장 = 경쟁위험 점과정 (competing-risks point process)**
로봇 r의 hazard rate
```
λ_r(t) = λ_0r · exp( β_u · usage_r(t) + β_c · 1[carrying] + β_s · (1 − soc_r(t)) + β_m · m )
```
구간 내 최초 고장 시각
```
P( T_fail_r > τ )  =  exp( − ∫_0^τ λ_r(u) du )
T_first = min_r T_fail_r          (competing risks)
```
그리고 §1대로 `τ_{k+1} = min(T_plan_event, T_first)`.

**(c) 흡수/막다른 상태**: 남은 task를 수행할 수 있는 로봇 자원이 물리적으로 없으면
`s_dead` (완주 불가). SSP는 dead-end를 다뤄야 하므로 **finite-penalty SSP**를 쓴다:
`c(s_dead) = C_fail < ∞`. (무한대로 두면 최적정책이 정의 안 되는 상태가 생긴다.)

### 5.3 OOD kind의 형식적 정의

exogenous 이벤트 e는 이벤트 공간 E 위의 값이다: `e = (type, robot, 시점, 심각도, 문맥)`.
- **seen OOD**: e가 학습데이터의 support E_seen 안 (또는 그 근방)
- **novel OOD**: e ∉ E_seen

**kind 라벨은 E 위의 사후적 분할일 뿐, MDP의 일부가 아니다.** 그래서 상태 featurization에
kind one-hot을 넣으면 안 된다 (§8.1) — 새 kind가 들어올 자리가 없어진다.

---

## 6. 비용함수 (SSP)

epoch k에서 발생하는 비용:

```
c(s_k, a_k, τ_{k+1}) =  w_t · τ_{k+1}                       (makespan)
                      + w_e · Σ_r ∫ 소비전력                 (에너지)
                      + w_h · (사망 로봇 수, 낙하 부품, 충돌)  (하드웨어 손실)
                      + w_s · 안전제약 위반 적분              (안전)
                      + w_c · C_compute(a_k)                 (결정 산출 비용) ★
```

목적:
```
minimize  E[ Σ_k c(s_k, a_k, τ_{k+1}) + C_fail · 1[dead-end] ]
```
`Σ_k τ` 가 정확히 총 makespan이 되므로 w_t 항 하나로 makespan이 표현된다.

★ **C_compute를 비용에 넣는 것이 이 설계의 요점 중 하나다.** MILP 오라클 호출은 초~분,
LLM 호출은 초 + 토큰비용, surrogate는 밀리초. 이걸 비용에 넣지 않으면 "항상 오라클을 부른다"가
최적이 되어 문제 자체가 사라진다. 넣는 순간 **"싸고 충분히 좋은 결정기를 언제 쓸 것인가"가
최적화 문제의 일부**가 된다 (§9).

---

## 7. 최적방정식과 "오라클 라벨"의 정체

SMDP Bellman (undiscounted SSP):
```
Q(s, ω) = E_{τ, s'} [ c(s, ω, τ) + V(s') ]
V(s)    = min_{ω ∈ A(s)} Q(s, ω) ,     V(goal) = 0
```

### 7.1 라벨 생성 = 정직하게 말하면 Monte-Carlo policy evaluation

`Q(s, ω)`의 라벨을 만드는 유일하게 옳은 방법:
```
for k = 1..K:
    s⁺ = f(s, ω)                       # 옵션 즉시 적용
    behavior policy π_b 로 끝까지 롤아웃  # 도중의 추가 failure도 샘플링
    G_k = 누적비용
Q̂(s,ω) = mean(G_k),  표준오차 = std/√K
```

**흔한 함정 (반드시 피할 것)**: "옵션 적용 후, 더 이상 고장이 없다고 가정하고 MILP를 한 번 풀어
그 makespan을 라벨로 쓴다." 이건 certainty-equivalent 1-shot 값이고 **MDP의 Q가 아니다.**
그렇게 만든 surrogate는 myopic value function이지 MDP 정책이 아니며, 여러 번 연쇄 고장이 나는
상황에서 체계적으로 틀린다 (특히 "지금 spare를 아껴둘 것인가"류 판단에서 정반대로 틀림).

- π_b 로는 (i) 현재 surrogate 정책(on-policy), 또는 (ii) 옵션별 greedy planner를 쓴다.
- K는 표준오차가 옵션 간 격차보다 작아질 때까지. **격차 < 노이즈이면 그 상태는 tie이며,
  tie를 tie로 보고하는 것이 subopt_norm 평가에서 중요** (틀린 걸로 세면 안 됨).
- 비용이 크면 fitted-Q iteration으로 부트스트랩 (`G = c + V̂_θ(s')`)해 rollout 길이를 줄인다.

### 7.2 이 MDP는 어디까지 풀 수 있는가
상태공간이 연속·고차원이라 정확해는 없다. 실용 경로:
1. **1-step lookahead + 학습된 V̂** (= 위 Q̂ 회귀) — 기본
2. **fitted-Q iteration** — 연쇄 고장 반영
3. **MCTS/rollout over options** — 시간 여유 있을 때 (오라클 역할)

---

## 8. Surrogate 설계

### 8.1 featurization φ(s) — 설계 규칙 4개

1. **순열 등변성**: 로봇 집합과 task 집합에 대해 index-free. → set encoder 또는 assembly tree +
   robot set 위의 GNN. (초기엔 "정렬된 top-k + 집계통계"로 근사 가능)
2. **네 블록 모두 포함**: X_A(남은 build step 수, critical path 길이, open step의 fan-out),
   X_R(로봇별 pose·SoC·payload·health, spare 수), X_G(부품-목적지 거리행렬 요약),
   X_C(진행 중 task의 잔여시간, 배정 slack, 전환비용 추정).
3. **assignment 관련 충분통계 명시적 주입**: 후보 로봇-task 거리 상위 k개, 스케줄 slack,
   병목 build step id, 재배정 시 sunk cost. — GNN이 이걸 스스로 배우길 기다리지 말고 넣는다.
4. **event/option은 물리 서술자로 표현, kind one-hot 금지**:
   `(고장 로봇의 SoC, 그 로봇이 critical path 위에 있는가, payload의 하위트리 크기,
     남은 spare 수, 영향 반경, 심각도)`. 이래야 **처음 보는 kind도 φ 안에 들어온다.**
   옵션도 마찬가지로 one-hot이 아니라 옵션 서술자(영향 task 수, 예상 전환비용, 필요 자원)로.
   → LLM이 만든 **새 옵션도 같은 회귀함수로 점수를 받을 수 있다.**

### 8.2 학습 대상: Q-회귀 vs 정책분류 (Ryan의 "NN classifier" 제안에 대한 답)

| | 정책 분류기 π(s) → ω | **Q 회귀 f(φ(s), ψ(ω)) → 값** |
|---|---|---|
| 결정 정렬 | 직접적 | 간접적 |
| tie/margin 표현 | 못함 | 함 (신뢰구간까지) |
| **새 옵션 일반화** | **불가** (출력 헤드가 고정) | **가능** (옵션 서술자 입력) |
| VoI 게이팅 | 불가 (불확실성 해석 곤란) | 가능 (§9) |
| 데이터 효율 | 좋음 | 라벨당 K rollout 필요 |

**결론: Q 회귀를 주 모델로, 분류기는 baseline으로.** open-world(§4.3)와 metareasoning(§9)이
둘 다 값·불확실성을 요구하므로 분류기로는 설계가 닫히지 않는다.
모델 계열은 tree ensemble(RF/GBT) → 데이터 늘면 set/graph NN. NN 분류기는 Ryan 제안대로
"같은 φ, 같은 split"에서의 비교 baseline으로 반드시 돌린다.

### 8.3 손실함수: MSE가 아니라 decision-focused

우리가 원하는 건 값의 정확도가 아니라 **argmin의 정확도**다.
```
Regret(s) = Q(s, ω̂) − min_ω Q(s, ω)      (실제 값 기준으로, 예측값 아님)
```
- 학습 손실: pairwise ranking / listwise + margin, 또는 SPO+ (smart predict-then-optimize)
- 보고 지표: **평균 subopt_norm, 파국선택률(subopt_norm > 임계치 비율), tie 제외 정확도**
- MSE는 진단용 보조지표로만

---

## 9. LLM ↔ surrogate 분담을 MDP 안으로 넣기 (metareasoning)

"처음 본 건 LLM, 본 적 있는 건 surrogate"는 **휴리스틱이 아니라, 비용에 C_compute를 넣은
MDP의 최적 정책으로 유도된다.** 이것이 이 설계의 두 번째 요점.

### 9.1 meta-level MDP

object-level(물리) MDP와 **분리된** 층:

- **meta-state**: `m = ( φ(s), 각 옵션의 Q̂와 epistemic 불확실성 u(ω),
                        novelty score η(φ(s), e), 남은 compute budget, 현재까지 쓴 결정기들 )`
- **meta-action**: `{ ACCEPT(surrogate argmin), QUERY_LLM, CALL_ORACLE(K rollouts),
                      ESCALATE(human) }`
- **meta-reward**: `− w_c · 해당 결정기의 비용 − E[남게 될 subopt_norm]`
- **종료**: ACCEPT하면 object-level 행동이 확정되고 이 epoch의 meta-episode 종료

### 9.2 최적 meta-policy = value of information 정지규칙

```
QUERY_LLM 을 택한다  ⟺  E[ subopt_norm 감소 | LLM 호출 ]  >  w_c · (LLM 비용)
```
- **seen OOD**: φ가 학습분포 내부 → epistemic u(ω) 작음 → 옵션 간 격차가 불확실성보다 큼
  → 기대 subopt_norm 감소 ≈ 0 → **ACCEPT (surrogate)**. ✅
- **novel OOD**: φ가 분포 밖 → u 큼, 또는 좋은 옵션이 A 안에 없음
  → 기대 subopt_norm 감소 큼 → **QUERY_LLM**. ✅

즉 원하던 분담이 **정의된 목적함수에서 자동으로 나온다.** 게이트 신호로 뭘 쓸지도 이 프레임이
결정한다: epistemic uncertainty(앙상블 분산 / conformal 폭)와 covariate novelty(밀도비·거리)
중 **"subopt_norm 감소량을 더 잘 예측하는 쪽"** — 이건 실험으로 고르는 것이지 취향이 아니다.

### 9.3 LLM의 두 역할을 분리할 것

1. **action-space generator** (§4.3): 새 옵션 ω_new 제안 → admissibility filter → A 확장.
   *novel OOD의 본질적 어려움은 "어느 옵션이 좋은가"가 아니라 "옵션이 없다"이므로 이쪽이 핵심.*
2. **zero-shot Q ranker**: 기존 옵션에 대한 사전순위 제공 (surrogate 불확실할 때의 prior).

### 9.4 assimilation loop (한 번 겪은 OOD는 싸지게)

```
novel event e
  → LLM이 ω_new 제안 → filter 통과 → A ← A ∪ {ω_new}
  → 오라클이 그 상태에서 K-rollout으로 Q 라벨 생성 (offline, 여유시간에)
  → 데이터셋 D ← D ∪ {(φ(s), ψ(ω), Q̂)}
  → surrogate 재학습 → 다음번 유사 e에서 u 작아짐 → VoI 규칙이 자동으로 ACCEPT
```
**중요**: 이 루프에서 변하는 것은 **agent의 지식상태**이지 환경상태가 아니다 (§3.5).
그래서 object-level MDP는 stationary하게 유지되고, meta-level만 학습에 따라 비정상적으로 변한다.
이 분리 덕분에 "환경이 학습에 의존한다"는 정의불능 상황을 피한다.

---

## 10. Ryan의 질문들에 대한 정면 답변

**Q1. "surrogate가 (결정을 하나 확정하고 남은 스텝을 MILP로 푸는 것)보다 빨라야 한다는 거지?"**

정확히는 **그것보다 |A(s)|·K 배 무거운 것**보다 빨라야 한다. 오라클 1 결정의 비용은
```
|A(s)| 개 옵션 × K 회 롤아웃 × (MILP 재해 + 시뮬레이션)
```
"하나 확정하고 MILP 한 번"은 **하나의 후보를 평가**하는 비용이지, **선택**하는 비용이 아니다.
선택하려면 모든 후보에 대해 그걸 해야 하고, 확률적이므로 각각을 K번 해야 한다.
surrogate는 |A(s)| 번의 forward pass(µs~ms)로 그 탐색을 대체한다.
추가로 세 가지가 더 있다:
- 확률성: MILP는 *plan*을 주지 *미래 고장 하의 기대값*을 주지 않는다. 둘은 다른 객체다.
- 온라인 지연: 결정하는 동안 로봇은 멈춰 있거나 잘못된 방향으로 간다 → 지연 자체가 makespan 비용
- **선택 후에는 여전히 결정론적 planner를 한 번 돌린다.** surrogate가 planner를 없애는 게 아니라
  **planner 호출 횟수를 |A|·K → 1 로 줄인다.** 주장의 정직한 형태는 이것.

**Q2. "결정이 Markovian인가? 후속 assignment 문제의 해에 필요한 정보를 상태가 다 담는가?"**

담도록 설계했다 (§2). 그리고 담기 위해 필요한 것은 통념보다 많다:
X_A(조립 논리) + X_R(pose·SoC·payload·health·**누적사용량**) + X_G(모든 부품의 물리적 위치) +
**X_C(현재 배정과 진행 중 작업 — 전환비용이 있으므로 상태다)** + X_H(hazard 파라미터/모드).
깨지는 통로는 5개이고(§3.1–3.5) 각각 수리 또는 belief 승격 경로가 있다.
그리고 **말로 끝내지 않고 T1/T2 검정(§3.6)으로 반증 가능하게 측정한다.**

**Q3. "Markov가 아니면 시간적 문맥 인코딩이 중요하다"**

동의. 우리 설계에서 이력이 필요한 지점은 정확히 두 곳으로 국소화된다:
(a) 잠재 열화 z_r → survival 이력으로 belief 갱신 (또는 usage_r로 대체),
(b) exogenous mode drift → 최근 이벤트 창으로 mode belief 추정.
그래서 "그냥 RNN에 전부 넣기"가 아니라, **누적 카운터 + 최근 h-창 요약**이라는 최소 이력을 쓰고,
T2 검정으로 그것이 실제로 subopt_norm을 줄이는지 확인한다. 줄이지 않으면 상태가 충분했다는 증거.

**Q4. "상태에 다른 로봇들의 위치, 부품의 물리적 위치, 실제 조립 상태가 다 들어가나?"**

들어간다 — 그리고 **왜** 들어가야 하는지가 명확하다:
- 다른 로봇 위치 → 재배정 후보의 이동시간 결정 + reactive avoidance로 인한 상호간섭
- 부품 물리 위치 → transport task의 실제 비용, staging 재배치 가능성
- 조립 상태 → 어떤 task가 legal한지(precedence), critical path가 뭔지
셋 중 하나만 빠져도 assignment sub-problem의 최적해가 상태의 함수가 아니게 된다.
단, 원시 좌표를 그대로 넣는 게 아니라 §8.1의 순열등변 인코딩 + 명시적 충분통계로 넣는다.

---

## 11. 가정, 알려진 구멍, 반증 계획

| # | 가정 | 깨지면 | 검증/대응 |
|---|---|---|---|
| A1 | 중앙집중 full observability | Dec-POMDP | 통신 제약 실험 시 belief 층 추가 |
| A2 | hazard가 관측가능 통계의 함수 | POMDP | §3.1 수리 B (belief-MDP) |
| A3 | 저수준 실행기가 (pose,vel)에서 memoryless | non-Markov | §3.6 T1 검정 |
| A4 | A_macro가 충분히 표현력 있음 | 최적성 gap | §4.4 gap 실측 + §4.3 LLM 확장 |
| A5 | 라벨이 K-rollout MC (1-shot certainty-equivalent 아님) | myopic 편향 | §7.1 — **현 시점 최우선 수정 대상** |
| A6 | exogenous mode 정상성 | drift | mode를 상태에 넣거나 novelty로 감지 |

### 즉시 할 일 (설계 → 구현 순서)
1. ~~§5 hazard/drain 프로세스를 **명시적 확률모델로 구현**~~ → **DONE (2026-07-31)**, §12 참조.
2. ~~§7.1 **K-rollout Monte-Carlo 라벨러**로 라벨 생성 교체~~ → **DONE (2026-07-31)**, §13 참조.
3. §8.1 featurization에서 **kind one-hot 제거**, 물리 서술자 + 옵션 서술자로 전환.
4. §3.6 **T1/T2 충분성 검정** 실행 → Markov 주장에 실증 근거 확보.
5. §9 meta-MDP를 **VoI 정지규칙**으로 구현 (임계값 하드코딩이 아니라 비용/이득 비교로).
6. §4.4 소형 인스턴스에서 **V^macro − V\*** 측정.

---

## 12. 구현 로그 — STEP 1: §5 확률적 고장 프로세스 (2026-07-31, 완료)

### 12.1 무엇이 바뀌었나

| | 이전 (`schedule_random_ood!`) | 이후 (`src/mdp/hazard.jl`) |
|---|---|---|
| 사건 시점 | 시뮬 시작 **전에** n개 진척점을 뽑아 고정 | 실행 중 상태의존 위험률에서 **생성** |
| 종류 선택 | `kinds` 에서 균등 추첨 | 세 개의 **경쟁 위험(competing risks)** 이 각자 시계를 돌려 경합 |
| 상태 의존성 | 없음 (로봇이 뭘 하든 같은 시점) | λ가 mode/누적사용/SoC/전역모드에 반응 |
| 배터리 방전 | 결정론적 (계획의 함수) | 로봇별 ε_r ~ LogNormal(평균 1) 로 무작위화 |
| 성격 | 무작위 **시나리오 생성기** | 진짜 **transition kernel** — P(s'\|s,a) 가 정의됨 |

핵심 구성(정확 표집, 스텝당 베르누이 근사 아님):
```
E_r ~ Exp(1) 한 번 뽑고,  Λ_r(t) = ∫₀ᵗ λ_r(u)du 를 누적,
Λ_r(t) ≥ E_r 이 되는 첫 순간에 발화.        →  T_first = min_r T_fail_r  (경쟁 위험)
```

### 12.2 산출물
- `src/mdp/hazard.jl` — `HazardParams`/`HazardState`/`enable_hazard!`/`hazard_step!`/
  `hazard_rate`/`hazard_features`/`hazard_report`/`expected_hazard_events`
- `src/mdp/mdp.jl` — 런타임 include 로더 (navigator 이후에 로드)
- `src/navigator/battery.jl` — `DRAIN_FACTOR_HOOK` 1곳 추가(`_debit!`). 훅 없으면 배수 1.0 이라
  기존 실행은 바이트 단위로 동일 (battery_smoke 32/32, battery_safety 27/27 무회귀)
- `test/mdp_hazard_smoke.jl` — 37/37 PASS
- `tools/demos.jl hazard_mdp` — e2e 데모

### 12.3 검증 결과
**단위(37/37)**: ε_r 평균=1 / Exp(1) 평균·분산=1 / λ가 carry>manip>transit>idle 및 SoC↓·마모↑에
정확히 설계식대로 반응 / 상수 λ에서 고장시각 평균이 격자 이론값 `dt/(1−e^{−λdt})` 와 일치하고
연속시간 `1/λ` 와의 이산화 편향이 `< dt` / 경쟁위험 승자 비율이 이론값 `λ_i/Σλ` 와 일치 /
같은 seed = 같은 실행 / 꺼짐 상태에서 완전 무동작.

**e2e (tractor, mock LLM)**: 같은 빌드·같은 계획인데 seed 만 바꾸면 사건 스트림이 달라짐
— seed 1은 t=1.87s 에 R7 1건, seed 2는 12건(고장 6 + 셀열화 6), `PROJECT COMPLETE`.
상태의존성이 로그에서 직접 보임: R1 의 λ_break 가 2.8e-2 → 7.4e-2 로 상승(SoC 0.37→0.36, 누적사용↑).

### 12.4 이 과정에서 드러난 것 (설계 수정 사항)

1. **경쟁 위험을 `elseif` 로 묶으면 안 된다.** 처음 구현에서 고장 위험과 셀 위험을 if/elseif 로
   두었더니, 발화가 유예된(안전 대상이 없어 못 터진) 고장 위험이 그 로봇의 셀 위험을 **영구히
   가려버렸다** — 경쟁 위험 모형이 아니라 우선순위 큐가 된 것. 두 위험은 반드시 독립 검사.

2. **깊은 방전은 물리적으로 breakdown 과 같은 사건이다.** 셀 열화가 SoC를 Replace 임계 아래로
   떨어뜨리면 downstream 이 그것을 고장으로 취급해 스페어 인계를 부르므로, 고장과 **동일한
   enactment 안전 조건**이 필요하다. 이걸 안 걸었을 때 첫 e2e 는 t=2.9s 에 다인 운반 중이던
   R7 을 깊은 방전시켜 팀이 형성 중 끼었고, 이후 270 시뮬초를 교착으로 날렸다.

3. **모형이 만든 사건 ≠ 엔진이 소화한 사건 — 반드시 따로 세야 한다.** `hazard_report()` 에
   `n_break_pending`(문턱은 넘었으나 발화 유예)을 넣었다. 이게 없으면 "사건 0건"이 *모형상
   안 일어남*인지 *엔진이 못 일으킴*인지 구별되지 않는다. 실제로 hot-swap 을 끄고 돌리면
   seed 2 에서 **crossed 6 / enacted 0** 이 나온다 — 보고하지 않으면 그냥 거짓말이 된다.

4. **HOT_SWAP 이 사실상 필수 전제다.** 스케줄 재각인(re-stamp) 교체 경로는 고장 로봇의 배정
   엣지를 넘겨야 해서 "단독 frontier" 상태에서만 안전하고, 그 조건은 드물다. 정체성 보존
   hot-swap 은 넘길 엣지가 필요 없어 운반 도중에도 안전하므로, 이걸 켜야 위험 프로세스가 만든
   사건과 엔진이 소화한 사건이 일치한다(crossed 6 / enacted 6).

5. **MTBF 는 빌드 길이에 맞춰야 한다.** 무사고 트랙터 빌드는 ~20 시뮬초다. MTBF 300~400 s 를
   쓰면 기대 사건 수가 1 미만이라 "아무 일도 안 일어나는" 실행이 나온다(실측 19.55 s / 1건).
   데모 기본값은 break=60 s / cell=45 s. `expected_hazard_events` 로 사전 확인할 것.
   **주차된 예비는 전원이 꺼져 위험 0 이므로 기대치 계산에서 제외**해야 한다(안 그러면 크게 과대추정).

### 12.5 사용법
```bash
julia +lts --project=. test/mdp_hazard_smoke.jl                    # 단위 37/37
SEED=1 julia +lts --project=. tools/demos.jl hazard_mdp            # e2e
SEED=2 julia +lts --project=. tools/demos.jl hazard_mdp            # 다른 사건 스트림
# ENV: SEED MTBF_BREAK MTBF_CELL MTBF_ZONE DRAIN_SIGMA HOT_SWAP STALL N_SPARE SHRINK
```

### 12.6 다음 (STEP 2 = §7.1 K-rollout MC 라벨러)
이제 `hazard_step!` 이 재현 가능한 확률 커널을 주므로, 같은 (s, ω)에서 **K개의 서로 다른 미래**를
굴릴 수 있다 — 이것이 1-shot certainty-equivalent 라벨을 진짜 Q 의 몬테카를로 추정으로 바꾸는
전제 조건이었다. seed 를 라벨러가 관리하면 옵션 간 비교를 **공통난수(common random numbers)** 로
짝지어 분산을 크게 줄일 수 있다(같은 seed = 같은 미래 고장열 → 옵션 차이만 남음).

---

## 13. 구현 로그 — STEP 2: §7.1 K-rollout 몬테카를로 Q 라벨러 (2026-07-31, 완료)

### 13.1 무엇이 바뀌었나

| | 이전 (`gen_oracle_fullsim.jl`) | 이후 (`gen_oracle_mc.jl`) |
|---|---|---|
| 라벨 | 옵션 실행 후 **고장 없다 가정**하고 1회 실행한 makespan | 위험 프로세스를 켠 채 **K회 굴려 평균** |
| 성격 | certainty-equivalent (myopic value) | Q(s,ω) 의 몬테카를로 추정 |
| 불확실성 | 없음 (점추정) | 표준오차 + **짝지은(paired) 차이** + 동점 판정 |
| 순위 규칙 | feasibility-lexicographic (평균 불가) | 유한벌점 SSP 스칼라 비용 (평균 가능) |
| 분산 | — | CRN 짝짓기로 **3.7배** 감소 (실측) |

### 13.2 반드시 지켜야 하는 두 가지 (이 파일이 존재하는 이유)

**(1) 결정 상태 s 는 모든 rollout 에서 동일해야 한다.**
위험 프로세스가 *연구 대상 사건까지* 만들게 두면 rollout k 마다 다른 상태 s_k 를 만나고, 평균은
`E_s[Q(s,ω)]`(상태 분포에 대한 평균)이 되어 우리가 라벨링하려는 `Q(s,ω)` 가 아니다.
→ 대상 고장은 결정론적으로 주입하고, **바로 그 순간에** 위험 시계를 켠다
(`schedule_studied_fault!`). 결정 이전 궤적은 모든 rollout·모든 팔에서 바이트 단위로 동일하고,
이후만 표집된다. 이것이 정확히 `s⁺ = f(s,ω)` 다음 rollout 이다.

**(2) lexicographic 순위는 평균낼 수 없다.**
`(complete? → closed → makespan)` 사전식 순서는 K=1 에서는 되지만 기대값을 못 만든다.
→ 설계 §6 의 유한벌점 SSP 스칼라로 바꾸되, **argmin 이 기존 순위를 재현**하도록 벌점을 고르고
그걸 `check_order_equivalence` 로 자동 점검한다. 벌점 `MC_COST_FAIL` 은 이제 **명시적 모델링
선택**이다 — "완주 못 할 위험" 과 "늦게 끝남" 사이의 환율. 사전식 규칙에 숨겨져 있었을 뿐,
선택은 원래부터 존재했다.

**교정 하나 (legacy 규칙의 버그):** 기존 `better()` 는 **둘 다 완주한 경우에도 closed 수로**
비교한다. 이 하니스는 완주해도 `closed < total` 이므로(실측 `YES 291/313`), 장부 노드를 몇 개
더 닫았다는 이유로 **더 느린 실행을 더 낫다고 판정**할 수 있다. 목표 도달 후 남은 노드는 미완의
작업이 아니라 장부다. SSP 는 흡수상태 이후 경과시간만 세므로 `better_ssp` 로 교정했고, legacy 와
갈리는 경우는 조용히 넘기지 않고 로그로 알린다.

### 13.3 CRN — STEP 1 설계가 공짜로 준 것 (그리고 깨질 뻔한 지점)

지수 시계 구성 덕분에 문턱 `E_r` 은 실행 전에 뽑히고, 팔마다 달라지는 건 `Λ_r(t)=∫λ` 적분
경로뿐이다 — 그게 바로 재려는 인과효과다. 그래서 rollout k 에서 모든 팔이 **같은 운**을 겪는다.

단, 원래 구현은 난수를 **공유 스트림에서 호출 순서대로** 뽑아 이 성질이 깨져 있었다. 팔 A 가
스페어를 하나 더 투입해 로봇 등록 순서가 밀리면 그 뒤 모든 뽑기가 어긋난다. → `hazard.jl` 을
**로봇별 전용 스트림**(시드 = `(기저시드, 로봇 id)` 의 결정론적 함수)으로 리팩터. 이제 ε_r,
초기 문턱, 그리고 "로봇 r 의 n 번째 셀 사건 심각도" 가 등록 순서와 무관하게 고정된다.
zone 배치도 발생 순번으로 시드를 준다. (예외: `drain_step_cv>0` 는 스텝 수 자체가 팔마다 달라
원리적으로 CRN 을 깬다 — 기본값 0.)

**실측 증거**: 같은 rollout 에서 두 팔의 사후 사건 수가 일치한다 (k=1: 양쪽 brk=4/cell=2,
k=2: 양쪽 brk=0/cell=3). 짝지은 표준오차가 짝 안 지은 것보다 **3.72배** 작았다.

### 13.4 산출물
- `wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl` — 라벨러(전체 스윕 / 단일 유닛 병렬 /
  집계 3가지 모드), 1-shot 기준선 열 포함
- `src/mdp/hazard.jl` — CRN 정확화(로봇별 스트림), `hazard_report().capped` 추가
- `test/mdp_mc_label_smoke.jl` — 집계 수학 검증 (시뮬 없이, 빠름)
- 아티팩트: `oracle/out/oracle_mc_units_s1.csv`, `oracle_mc_summary_s1.json`

### 13.5 검증 결과

**단위**: `mdp_mc_label_smoke` ALL PASS (스칼라 비용 ≡ `better_ssp` 무작위 300쌍 / legacy 편차
문서화 / 순서동치 위반 감지 / Q̂·SE / CRN 분산감소 / **동점 라벨링** / 상한 걸린 rollout 계수 /
기준선 분리). `mdp_hazard_smoke` 55/55 (CRN 테스트 추가).

**실사례 (확정본)** — tractor, build_seed=1, **K=10**, MTBF 500/500, 22회 full-sim
(기준선 2 + K=10 x 2 액션; k=4~10 은 4-way 병렬 샤드):

| | 1-shot 기준선 (위험 OFF) | **K=10 MC (확정)** |
|---|---|---|
| `1:Replace` | **19.23** (complete=YES) | **Q̂ = 3555 ± 2357**, **P(done)=0.80**, 사후사건 2.70 |
| `0:NOOP` | **46.62** (complete=YES) | **Q̂ = 20967 ± 3489**, **P(done)=0.20**, 사후사건 6.10 |
| Δ | 27.4 | **17411 ± 3690 (paired)** = **4.7 SE** |

**하니스 정합성 증거**: 사후 사건이 한 건도 안 뜬 rollout(k=9 NOOP: brk=0/cell=0)의 비용이
**46.6250 — 1-shot 기준선과 소수점까지 정확히 일치**한다. Replace 도 동일(19.2250).
즉 MC 라벨러는 표집된 미래에 사건이 없으면 1-shot 라벨로 **정확히 퇴화**한다. 두 경로가 같은
시뮬레이터·같은 비용함수를 쓰고 있다는 직접 증거이며, 차이는 오로지 "미래를 표집하느냐" 뿐이다.

**결과의 분포는 연속이 아니라 이봉(bimodal)이다**: 실패한 rollout 은 NOOP 이 전부 closed=151,
Replace 가 전부 closed=236 으로 **동일한 구조적 지점에서 wedge** 된다. 비용이 연속적으로 흔들리는
게 아니라 "살아남은 로봇이 충분했는가"의 거의 결정론적 함수다.

**핵심 관찰**: argmin 은 둘 다 `Replace` 로 일치했지만 **규모가 450배 다르다.** 1-shot 은
"NOOP 은 2.4배 느리지만 문제없이 완주한다(46.6초)" 라고 말한다. 실제 고장 프로세스 아래에서
**NOOP 의 완주율은 20%, Replace 는 80%** 다. argmin 이 같다고 1-shot 이 옳은 게 아니다 —
subopt_norm 을 compute 비용과 견주는 §9 의 VoI 게이트는 **크기가 보정된** Q 를 요구하는데,
1-shot 라벨로 학습한 surrogate 는 그 크기를 세 자릿수 틀리게 배운다.

**인과 사슬도 보인다**: NOOP 의 사후 사건 수가 6.10 으로 Replace 의 2.70 보다 많다. 죽은 로봇을
교체하지 않으면 빌드가 정체하고, 정체가 시뮬 시간을 태우고, 그동안 위험 시계가 계속 돌아 남은
로봇도 무너진다. 즉 "대응 안 함" 의 비용은 한 번의 손실이 아니라 **연쇄**다 — 이게 바로 1-shot
certainty-equivalent 라벨이 구조적으로 볼 수 없는 부분이다.

### 13.6 이 과정에서 드러난 것 (남은 보정 과제)

1. **MTBF 는 그 하니스의 빌드 길이로 보정해야 한다 — 데모 값을 옮겨쓰면 안 된다.**
   실측 이력: 60/45 → 사후 사건 16건·함대 전멸·벽시계 8분. 150/150 → 평균 5.3건, 6개 중 4개가
   `max_events` 상한에 걸림(라벨 낙관 편향). 500/500 → 상한 미도달.
   `expected_hazard_events` 는 마모·SoC 가속·carry 배수를 뺀 **하한**이라, 실측이 약 2배로 나온다.

2. **`max_events` 상한에 걸린 rollout 은 반드시 따로 세서 보고해야 한다.** 미래가 잘리면 라벨이
   낙관 편향되는데, "사건 N건" 만 보고하면 잘렸는지 알 수 없다. `n_capped` 로 집계·경고한다.

3. **정체 꼬리(stall tail)가 사후 사건의 주된 발생원이다 — 미해결.** 실패한 rollout 의
   `hz_sim_s ≈ 160초` 인데 정상 빌드는 20초다. 즉 사건 대부분이 생산적 작업 중이 아니라
   **죽은 빌드가 no-progress 상한을 태우는 동안** 발생한다. NOPROG 를 30000→6000 으로 줄여
   완화했지만 근본 해법은 아니다. MDP 로는 dead-end 가 **흡수상태**이므로 진입 이후의 dynamics 는
   비용에 영향을 주면 안 된다 → dead-end 판정 시 위험 시계를 **정지**시키는 것이 옳다.
   (다만 wedge 는 ReformTeam 으로 복구 가능한 경우가 있어, "복구 불가"와 "일시 정체"를 구분하는
   판정이 필요하다. STEP 2 범위 밖으로 남긴다.)

4. **K=3 은 라벨용으로 부족했다 — K=10 에서 해결.** K=3 에서는 Δ/SE_paired = 2.0 으로 1.96
   문턱을 겨우 넘겼지만, K=10 에서 **4.7 SE** 로 확실해졌다. K≥10 을 기준으로 삼는다.

5. **CRN 이득은 K=3 의 3.72배가 아니라 K=10 에서 1.14배다 (앞선 수치 정정).**
   원인이 분명하다: 결과 분포가 이봉이라 팔마다 **구조적으로 다른 결말**(완주 vs 동일 지점 wedge)에
   도달한다. CRN 은 두 팔이 비슷한 궤적을 겪을 때 공유 잡음을 상쇄해 주는 기법이라, 결말 자체가
   갈리면 짝짓기가 상쇄할 공통 성분이 거의 없다. K=3 의 3.72배는 소표본 우연이 섞인 값이었다.
   → **CRN 은 여전히 켜 둘 가치가 있지만(공짜이고 해가 없다), K 를 줄여주는 배수로 기대하면 안 된다.**

6. **"결정이 완주율을 못 바꾼다" 는 K=3 관찰은 철회한다.** K=10 에서 P(done) 은
   **Replace 0.80 vs NOOP 0.20** 으로 확연히 갈린다. K=3 에서 양쪽 0.33 으로 보였던 것은
   표본 3개짜리 착시였다. 다만 admissibility 를 **P(complete) 격차**로도 거는 것은 여전히 맞다.

### 13.7 사용법
```bash
# 전체 스윕 (기준선 2회 + K×|A| 회 full-sim)
MC_K=10 MC_ACTIONS="0,1" ORACLE_SEED=1 julia +lts --project=. \
  wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl

# 병렬: 유닛 하나씩 다른 프로세스로 (CSV 에 append)
MC_ONLY="1:3" julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl
MC_AGGREGATE=1 julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_mc.jl

# 집계 수학만 빠르게 검증 (시뮬 없음)
julia +lts --project=. test/mdp_mc_label_smoke.jl
```

### 13.8 다음 (STEP 3 = §8.1 featurization 에서 kind one-hot 제거)
이제 Q 라벨이 크기까지 의미를 갖는다. 다음은 그 라벨을 학습할 φ(s) 를 고치는 일 —
OOD kind one-hot 을 물리 서술자로 바꿔야 처음 보는 kind 가 φ 안에 들어오고,
`hazard_features(env)` 가 그 재료(soc / usage / λ / mode / p_fail_60s)를 이미 제공한다.

---

## 15. 구현 로그 — φ(관측 서술자)를 §2 상태정의에 맞추기 (2026-08-02)

### 15.1 문제: 설계는 §2를 썼는데 **구현된 φ는 §2가 아니었다**

96 instance 에피소드 데이터에서 T1(§3.6)이 처음으로 **명확한 실패**를 냈다.

| 지표 | 값 | 기준선 |
|---|---|---|
| φ로 완주 여부 예측 정확도 | 0.755 | 다수결 **0.745** |
| φ로 팔 순위(argmin) 적중 | 0.458 | 동전던지기 0.5 |

즉 **φ는 완주 여부조차 못 맞힌다**. 당시 φ 15개는 전부 집계 스칼라였다:
`progress, n_active, spare_count, closed_at_fire, total_nodes, severity, zone_overlap,
zone_radius, agent_pending, macro_cost, n_spare_cfg, decision_idx, raw_n_*`.

§2와 대조하면 무엇이 빠졌는지가 즉시 보인다:

| §2 블록 | 구현된 φ에 있었나 |
|---|---|
| X_A 조립/과제망 | 부분 (닫힌 노드 수뿐, **부품이 어디 있는지 없음**) |
| X_R 함대 | 부분 (당사자 soc 하나뿐, **pose/vel/팀 없음**) |
| X_G 기하 | **전무** |
| X_C 커밋먼트 | **전무** ← §2.4가 "Markov의 핵심"이라고 못 박은 블록 |
| X_H hazard | 부분 (severity) |

§2.4는 "X_C를 빼면 같은 물리상태에서 서로 다른 미래비용이 나와 Markov가 즉시 깨진다"고
썼는데, **구현이 정확히 그 상태였다**. 같은 "로봇 1대 고장"이라도 그 로봇이 유휴인지
화물을 절반 옮긴 상태인지에 따라 NOOP의 값이 완전히 달라지는데, φ에 그 축이 없었다.
T1 실패는 모델 문제가 아니라 **관측함수가 설계와 어긋난 것**이다.

이것은 Ryan의 질문 (c)("state가 로봇 위치·부품 위치·실제 조립상태를 포함하나")에 대해
지금까지의 데이터가 **"아니오"**라고 답하고 있었다는 뜻이기도 하다. §10의 답변은 설계
의도로는 맞았지만 구현으로는 뒷받침되지 않았다.

### 15.2 수리: raw 덤프 확장 + 파이썬 서술자

원칙은 기존과 동일하다 — **Julia는 원자료만 덤프, 서술자는 파이썬에서 재계산**.
서술자를 Julia에 구우면 정의를 바꿀 때마다 몇 시간짜리 라벨링을 버려야 한다.

`gen_oracle_dataset.jl :: capture_raw` 에 추가한 원자료:

```
raw_robot_x / raw_robot_y                 로봇 pose            (X_G)
raw_robot_mode                            IDLE/TRANSIT/CARRY/MANIPULATE  (X_C)
raw_robot_goal_x / raw_robot_goal_y       커밋된 작업의 목표    (X_C)
raw_n_carry / raw_n_transit / raw_n_manip 활성 노드 종류별 수   (X_C)
raw_cargo_id / x / y / placed             부품·서브어셈블리 위치와 설치여부 (X_A, X_G)
target_id                                 사건 대상 로봇 id = raw_* 벡터의 **조인 키**
```

`overnight_mdp.py :: derive_state_descriptors` 가 여기서 뽑는 서술자:

- **X_C**: `xc_idle/carry/transit/manip_frac`, `xc_inflight_dist_sum|max`, `xc_n_committed`
  — 남은 이동거리 합 = 이미 착수한 일의 잔여량 = **전환비용의 직접 대리치**
- **당사자 축(가장 중요)**: `xt_mode`(유휴/운반/조작), `xt_dist_to_goal`, `xt_soc`,
  `xt_team_size`(같은 목표를 공유하는 로봇 수 = 파급 규모), `xt_spare_dist_min`(교체
  로봇이 와야 할 거리 = 개입의 실제 지연비용)
- **X_G**: `xg_soc_min|p25|mean`(함대 SoC 분포), `xg_spread`
- **X_A**: `xa_placed_frac`, `xa_n_cargo`, `xa_cargo_spread`

구 덤프(raw_robot_mode 없음)에 대해서는 빈 dict를 돌려주므로 **옛 파일과 새 파일을 한
글롭에서 섞어 읽어도 안전**하다.

### 15.3 T2를 실제로 수행 가능하게 만든 것

T2(§3.6, "φ에 이력을 더하면 결정이 나아지는가 — 나아지면 Markov가 아니다")는 지금까지
`BLOCKED`였다. 이유는 두 가지였고 **둘 다 이번에 해소**했다:

1. 단일사건 데이터에는 이력이 원리적으로 없었다 → 다중사건 에피소드로 이미 해결.
2. 에피소드 행에 **φ와 분리된 이력 채널이 없었다** → `hist_*` 블록 신설:
   `hist_n_prior, hist_prev_macro, hist_prev_kind, hist_prev_closed, hist_dclosed_prev,
   hist_prev_severity, hist_prev_spare, hist_n_intervened, hist_prev_target`.
   전부 결정 t 시점에 **이미 관측 가능한 값**이다(미래 누출 아님).

**함정 하나를 같이 고쳤다**: `decision_idx`("이 에피소드에서 몇 번째 결정인가")는 과거
사건 수의 요약, 즉 **이력**이다. 그걸 φ에 둔 채 T2를 하면 "이력 없는 모델"이 이미 이력을
쥐고 시작하므로 검정이 무의미해진다. → φ에서 제외하고 이력 쪽으로 옮겼다.

검정은 짝지은 부호검정으로 한다(instance가 동일하므로). subopt_norm은 **항상 참 비용**으로 잰다.

### 15.4 Router 평가의 두 가지 결함 수리

1. **게이트를 배포 모델 위에서 평가하지 않고 있었다.** 배포 후보는 decision-focused
   모델(§8.3)인데 VoI 프론티어는 raw 타깃 모델의 margin/불확실성으로 그리고 있었다.
   "어느 모델을 쓸 것인가"와 "그 모델을 언제 못 믿을 것인가"가 서로 다른 모델을 가리키면
   프론티어는 배포 결정에 쓸 수 없다. → 두 모델 중 subopt_norm이 낮은 쪽을 배포 후보로 잡고
   그 모델의 신호로 게이트를 판정하도록 고쳤다.
2. **평균만 비교하고 있었다.** 28 instance에서 surrogate(focused) 0.107 vs
   always-Replace 0.179였던 이득이, 96 instance에서 0.167 vs 0.198로 좁아졌다. 즉 소표본
   낙관이 섞여 있었다. → instance가 동일하므로 **짝지은 부호검정**을 추가했다.

### 15.5 STEP 6 재실행 (노이즈 대조군)

이전 판(K=2)의 gap 0.66은 결론으로 쓸 수 없었다: seed 2의 "최선 확장 arm" 10
(`Replace@after=0`)은 macro 1(`ReplaceAgent(agent, ctx.after)`, 이 하니스에서 `after=0`)과
**정의상 동일한 행동**이므로 참 gap이 0인 쌍이었다.

재실행 설계: K=4, seed 1~3, arm {0,1,10,11,12,20,21,22}.
**arm 10을 노이즈 대조군으로 명시**한다 — 1과 10의 짝지은 차이는 "참 gap이 0인 쌍에서
측정된 몬테카를로 노이즈"이므로 그것이 곧 **노이즈 바닥**이다. 확장 arm의 gap이 이 바닥을
넘지 못하면 gap은 관측되지 않은 것이다. CRN(같은 rollout k = 같은 hazard seed)이므로
짝지은 비교가 유효하다.

측정된 gap은 여전히 **진짜 gap의 하한**이다 — 원시 배정공간 전체가 아니라 옵션의
연속 파라미터만 열었기 때문(§4.4).

### 15.6 STEP 6 결과 — 옵션 제한의 대가는 **관측되지 않았다** (2026-08-02, 완료)

96 full-sim (seed 1~3 × 8 arm × K=4), 완주율 70.8%, hazard 상한 도달 0건.

```
                     arm            Q̂         SE   완주율      (seed 1)
                    NOOP     13117.79    7553.02      50%
          Replace(macro)      3573.57    3542.15      75%
     Replace@0 [대조군]        3568.99    3543.67      75%
               Replace@5      3568.99    3543.67      75%
              Replace@15      3568.99    3543.67      75%
          Deprio ×10/50/200   ~13110      ~7555        50%
```

| | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| V^macro | 3573.57 | 22.12 | 3841.41 |
| V*(ext) | 3568.99 | 22.12 | 3841.41 |
| 최선 확장 arm | 10 (=macro 1) | 1 | 1 |
| 노이즈 바닥 \|Q̂(1)−Q̂(10)\| | 4.57 | 0.00 | 1.58 |

**평균 gap = 0.00, 노이즈 바닥 평균 = 2.05, 유의한 gap 을 보인 seed 0/3.**

세 seed 모두 최선 확장 arm 이 **대조군 쌍 안**에 있다 — 즉 macro 1 과 같은 정책이다.
이전 K=2 판의 "gap 0.66" 은 이것으로 **몬테카를로 노이즈로 확정**된다(노이즈 바닥과 같은 규모).

해석: 이 파라미터 범위에서 `Replace@{0,5,15}` 는 서로 구별되지 않고,
`Deprioritize×{10,50,200}` 은 셋 다 NOOP 의 값으로 붕괴한다. 즉 **옵션의 연속 파라미터를
여는 것으로는 얻을 것이 없다**. 원시 배정공간을 열지 않았으므로 이 gap 은 여전히 **하한**이다(§4.4).

부수적으로 확인된 것: 같은 arm 이 rollout 1·3 에서는 완주(비용 21)하고 2·4 에서는 미완주
(26200)한다. **Q̂ 의 SE 가 Q̂ 와 같은 자릿수**라는 뜻이고, 이 규모의 노이즈에서 gap 을 논하려면
노이즈 대조군이 선택이 아니라 필수다.

---

## 16. 에피소드 설계의 **구조적 제약** — 실측으로 드러난 것 (2026-08-02)

§15.2~15.5 를 다 고친 뒤 오염 없는 데이터(ep2 전용, 33 instance)로 재측정했더니
**설계가 아니라 하니스의 물리적 제약**이 결과를 지배하고 있었다.

### 16.1 두 제약이 정반대 방향을 가리킨다

**제약 A — 배치 경계.** 이 빌드는 첫 시뮬 배치에서 `closed` 가 0 → **58** 로 한 번에 뛴다
(probe 실측: 목표 10/20/30/40/50 인 probe 5개가 전부 `closed_at=58` 에서 잡힘).
그래서 기본 발화구간 `[8,60]` 은 세 사건이 **같은 스텝에 몰려 터진다** → `tau_to_next` 전부 0,
s₁≈s₂≈s₃. **"에피소드"가 실제로는 동시사건 3개였다.**

**제약 B — fault 타깃 가용성.** 늦추면(`[70,230]`) τ 는 21~103 으로 분리되지만
**fault 가 한 번도 안 터진다(실측 0건)**. 계획에는 fault 가 많이 잡혔는데 전부 SKIP 됐다.
`single_solo_fault_target` 은 "남은 solo 운반작업이 정확히 1개인 로봇"을 찾는데, 빌드 후반에는
그런 로봇이 없다(후반 화물은 다중로봇 팀이 필요). 폴백 두 개도 같이 실패한다.

**제약 C — 결정 관련성의 붕괴.** 늦을수록 남은 일이 적어 어떤 팔을 골라도 결과가 같다.

| 발화 깊이 | 동점률 |
|---|---|
| closed < 120 | 67% |
| closed ≥ 120 | **95%** |

| 결정 순번 | 동점률 |
|---|---|
| t=1 | 75% |
| t=2 | 92% |
| t=3 | **100%** |

kind 별로는 더 심하다: **`zoneblk` 는 22/22 = 100% 동점**. ForbidZone 이 늦게 걸리면
막을 pending staging area 가 이미 없어서 아무것도 안 막는다(`zone_overlap` 이 0 이 되는 것과 같은 현상).

### 16.2 그래서 무엇이 결론인가

`[8,60]` = 결정은 유의미하지만 시간적으로 분리 안 됨(SMDP 아님).
`[70,230]` = 시간적으로 분리되지만 fault 없음 + 85% 동점(결정 문제 아님).

**둘 다 쓸 수 없다.** 구간을 추측으로 정하면 9시간짜리 생성을 통째로 버리게 되므로,
대량 생성 **전에** 후보 구간을 1 seed 씩 돌려 세 지표를 재는 절차를 도입했다
(`tools/mdp_cfgprobe.sh` + `tools/probe_report.py`):

1. fault 가 실제로 터지는가 (0 이면 탈락)
2. `tau_to_next > 0` 인 결정이 있는가 (0 이면 SMDP 가 아님)
3. 동점률 — 결정적 instance 비율이 가장 높은 구간을 채택

### 16.3 이것이 설계에 주는 함의

동점 85% 는 "surrogate 가 나쁘다"가 아니라 **평가셋에 결정 문제가 거의 없다**는 뜻이다.
STEP 5 의 Router 결론(“surrogate 가 규칙을 못 이긴다”, 짝지은 부호검정 p=0.82)은
**표본 부족 + 동점 지배** 상태에서 나온 것이므로 아직 결론이 아니다.

더 근본적으로, 이 하니스는 **개입이 결과를 가르는 창(window)이 좁다**:
너무 이르면 사건이 뭉치고, 너무 늦으면 무해하다. 이 창을 넓히려면 설계 수준의 선택이 필요하다 —
(i) 더 큰 조립 모델(창이 절대적으로 길어짐), (ii) 배치 크기를 줄여 `closed` 를 촘촘히 진행시키기,
(iii) 확률 전이(hazard)를 켜서 동점을 깨기(같은 결정도 rollout 마다 결과가 달라진다 — STEP 6 에서
실제로 그렇게 나왔다: 같은 arm 이 rollout 1·3 완주 / 2·4 미완주).
**(iii) 이 가장 싸고 설계에도 맞다** — 우리는 애초에 확률적 MDP 를 만들려 했고, 결정론 에피소드는
변수 분리를 위한 임시 조치였다.
