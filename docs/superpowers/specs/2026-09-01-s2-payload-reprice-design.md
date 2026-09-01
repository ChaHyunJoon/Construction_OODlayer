# S2 — payload 재가격(wear-leveling)을 L2 주조 도구로 만든다

작성 2026-09-01. 선행 레인: S1(`2026-08-31-s1-observation-and-thresholds`).
이 문서의 모든 수치는 **이 레인이 직접 잰 것**이고 재현 명령을 함께 적는다. 인용한 기존
보고서 수치는 전부 재검증했고, 뒤집힌 것은 §2 에 따로 모았다.

---

## 0. 사용자 결정 (이 spec 의 전제)

| # | 결정 | 근거 |
|---|---|---|
| **D-1** | **mild 배터리 메뉴는 `["NOOP"]` 그대로 둔다.** NOOP 을 빼지 않는다 | §1-1 |
| **D-2** | 재분배는 매크로 4번째 팔이 아니라 **L2 주조 도구**로 낸다 | 어휘·도장·라벨 격자를 안 건드린다 |
| **D-3** | 재분배의 개념은 **완주 가능성이 아니라 wear-leveling** 이다 | §4 |
| **D-4** | ③(후보 간선 정확 카운트)을 **결정 시점에서** 재고 나서 이 spec 을 쓴다 | §1-4 |
| **D-5** | payload 의존성은 `edge_energy`(①②)가 아니라 **`edge_cost_multiplier` 클로저**에 넣는다 | §4(b). ①②는 전역이라 모든 레인의 배정 지문을 바꿔 기존 녹화를 무효화한다 |
| **D-5a** | (D-5 의 집행 정정, §2-5) 그 클로저는 **3인자** `(sched, v, v2)` 여야 하고 화물은 **`v2` 한 홉 아래**에서 읽는다 | 2026-08-30 설계는 `v` 쪽을 읽어 후보 간선에서 항상 1.0 = 무동작이었다 |

**D-3 을 다시 적어 둔다** — 이 문서에서 "이 로봇이 남은 일을 마칠 수 있는가" 라는 논증은
**쓰지 않는다.** 배터리 SoC 자체는 빌드 진행에 문제가 없다는 것이 전제다. 옳은 논증은:
SoC 가 낮은 로봇이 큰 payload 작업을 하면 SoC 가 빠르게 줄고, 시간이 지나면 SwapBattery 가
걸릴 확률이 높아진다. 그러니 **상대적으로 가까운 로봇 중 SoC 가 높은 쪽에 payload 가 큰
작업을 배선한다.** 목표는 완주 판정이 아니라 드는 에너지와 미래 개입 확률을 낮추는 것이다.
레포가 이미 이 개념에 이름을 붙여 뒀다: `essential_tg_coponents.jl:1329` 의
*"the differential that later drives **battery wear-leveling**"*.

---

## 1. 측정된 사실

### 1-1. mild 에서 NOOP 을 빼면 L2 가 **영구히** 발화 불가가 된다

`synthesize.py:612` 의 `maybe_synthesize` 는 **`expressible == False` 에서만** 발화한다
(`None` 도 `True` 도 아니다).

| 상태 | `expressible` | L2 발화 |
|---|---|---|
| 오늘 (mild 메뉴 `["NOOP"]`) | `True` ("55% 충분") | ❌ |
| NOOP 제거 → 메뉴가 **빔** | `None` (`no_tools`) | ❌ **영구** |
| 목표 | `False` | ✅ |

`battery_arms` 의 mild 분기는 `COST==0` 필터라 활성 팔이 `[0]` 하나뿐이다 — NOOP 을 빼면
메뉴가 빈다. 빈 메뉴의 부수 피해 둘(실측):

* `dspy_service.py:176` `_valid_for` 의 falsy 폴백 — `valid=[]` 를 넣으면 실측으로
  `['NOOP','Replace','SwapBattery']` **전체 3팔**이 돌아온다(`build_tools` 도 3개를 낸다).
  mild 가 `Replace` 까지 받는다 = 의도의 정반대. 2026-08-24 `VALID["zone"]=[]` 와 같은 부류.
* `chosen=""` → `available=false` → `policy.jl:1703` 이 런을 **죽인다**(T11 이 조용한
  canonical 폴백을 일부러 없앴다). `_blank_decision` docstring 의 *"canonical 폴백이 선다"* 는
  그 이후로 낡은 문장이다 — 이 spec 이 그 정정을 기록한다.

⟹ **D-1.** 그리고 `test/battery_menu_lanes_agree.jl` 의 *"mild 는 닫힌 어휘에 수복이 없다"*
testset 은 **뒤집지 않는다**(S1 보고서 §4-2 의 예고는 집행되지 않는다).

### 1-2. 후보 배정 간선은 0 이다 — 정답원에서 직접

`formulate_milp` 이 Big-M 후보 루프에서만 채우는 `edge_costs` 를 `CB.LAST_EDGE_COSTS[]` 로
읽는다. 조건 3개를 손으로 복제하지 않는다(`policy.jl:226-232` 의 경고). 센티넬로
`ran_formulate=true` 를 매번 확인했다.

| 판 | `nv` | `ne` | `slots_upper_bound` | **후보** | `nnz(Xa)` |
|---|---|---|---|---|---|
| `colored_8x8`·greedy·6대 | 342 | 423 | 14 | **0** | 423 |
| `tractor.mpd`·greedy·10대 | 305 | 337 | 18 | **0** | 337 |
| `tractor.mpd`·**milp**·10대 | 305 | 337 | 18 | **0** | 337 |

🔴 **음성 대조가 가설을 죽였다** — `:milp` 로 배정해도(600초 풀어 gap 8.47% 해까지) 0 이다.
"greedy 가 슬롯을 채워서" 는 원인이 아니고, **배정 모드는 해법이 아니다.**

### 1-3. 죽는 지점은 조건② — 받는 쪽이 포화다

`formulate_milp` 의 Big-M 루프와 같은 순서로 단계별 생존 수를 셌다(tractor·greedy·10대):

```
조건① outdegree(v) < n_eligible_successors[v]   = 18    ← 전부 RobotGo, outdeg=0, n_elig_succ=1
원시 쌍 (v, non_upstream_vertices[v])            = 3176
+ 조건② indegree(v2) < n_eligible_predecessors[v2] = 0   ◀ 여기서 전멸
+ 조건③ 템플릿 매치 · val>0                        = 0
```

3176개 대상 중 **선행을 하나라도 더 받을 수 있는 노드가 0개**다. 모든 `FormTransportUnit` 이
로봇 정원을 이미 채웠다.

### 1-4. `release_pending_assignments!` 가 그 포화를 푼다 — 그러나 창이 닫힌다

`release_pending_assignments!`(`reassign.jl:121`)는 미래 배정 엣지를 `rem_edge!` 로 제거하고
슬롯을 미배정 상태로 되돌린다 = 조건②를 여는 유일한 동작.

**t=0 짝 대조**: 43개 해제(`ne` 337→294) ⟹ 후보 **0 → 2103**.

**결정 시점**(`S2_CANDIDATE_PROBE=1`, battery×6, `DEMO_BSOC=0.30`, `DEMO_POLICY=canonical`,
`DEMO_ROUTER=0`, `DEMO_SEED=1`, `DEMO_OOD_SEED=7`, `DEMO_N=6`; 프로브 실패 0건):

| `closed` | 해제 엣지 | 후보 간선 |
|---|---|---|
| 54 / 77 | 33 | 1320 |
| 109 | 26 | 890 |
| 141 | 20 | 591 |
| 163 | 17 | 461 |
| 220 | 4 | 80 |
| **247** | **0** | **0** |

총 노드 287. `slots_upper_bound` 은 **전 구간 18로 고정** — 상계가 무정보라는 증거가 하나 더.

⟹ **재가격은 원리적으로 무효가 아니라 지평이 있다.** 미배정 미래 작업이 남아 있는 동안만
성립하고 `closed≈247`(86%) 부터 죽는다.
🔴 **S1 의 mild 보드 결정은 `closed=259` 였다 — 창이 닫힌 뒤다.** 그 사건이 손쓸 도리가 없어
보인 이유가 이것이고, 이 spec 의 §6 이 그 사실을 설계로 흡수한다.

### 1-5. 오늘의 mild 경로는 재풀이를 시도조차 안 한다

실측 로그: `[recover] energy term N/A for NOOP — 이 분기는 formulate_milp 을 아예 부르지
않는다(재풀이 없음)`. 후보 0 이라 무효인 게 아니라 그 앞에서 끝난다.

### 1-6. payload 채널을 막는 층들

| # | 무엇이 닫혀 있나 | 위치 |
|---|---|---|
| ① | `edge_costs[(v,v2)] = edge_energy(dt_min) * edge_cost_multiplier(sched, v)` 가 `payload_mass` 를 안 넘긴다(기본 1.0) | `:1141`, `:1586` |
| ② | `ENERGY_MODEL` 기본 `load_power = 0.0` → payload 항에 0 이 곱해진다 | `:1337` |
| ③ | `AUTO_EFFICIENCY_KAPPA = nothing` 이면 목적함수가 `edge_costs` 를 통째로 버린다 | `:1318` |

🔴 **`load_power = 1.0` 로만 바꾸는 것은 아무 일도 안 한다** — `payload_mass` 가 여전히 1.0
상수라 `dt·(1+1·1) = 2·dt`, 즉 모든 간선에 같은 배율(단조 재척도)이라 배정 순서가 안 바뀐다.
설계 노트가 *"set `load_power>0` **and** pass a per-object mass proxy"* 라고 **and** 로 적은
이유다. 그리고 1.0 은 크기도 틀릴 공산이 크다: 실측 payload 는 `0.32768 … 12.800 kg`
(평균 2.4846) 이라 `1+m` 이 **1.33 … 13.8배** — 이동시간 항을 압도해 "가까운 로봇" 축이
사라진다. ⚠️ 그 kg 자체가 프록시다(`battery.jl:72` `payload_density = 100.0`, 주석이
*"verify density/units before claiming"*).

**그러나 ①②는 이 spec 의 필수가 아니다** — §4 를 보라.

---

## 2. 이 레인이 뒤집은 기록

1. 🔴 **2026-08-30 §6-1 항목 3 *"Phase D 재가격은 원리적으로 무효"* → 조건부 반증.**
   원리적 무효가 아니라 **release 없이 무효**다(§1-4). 재가격 경로는 창 안에서 살아 있다.
2. 🔴 **`test/respec_grammar.jl:20` 의 `n_candidate_edges(nnz Xa) = 423` 은 후보 간선이 아니다.**
   423 = `ne(sched)` = 고정 구조 간선 전부이고 그 판의 진짜 후보도 **0** 이다. 이 숫자를
   "후보 423개" 로 인용한 곳은 전부 틀렸다. (괄호 안 `(nnz Xa)` 은 정직했고 이름이 문제였다.)
3. 🔴 **`rebalance_for_battery!`(`battery.jl:747`)의 `:rebalanced` 는 침묵 성공이다.**
   `build_invariant → formulate_milp → optimize! → commit_respec!` 만 하고
   **`release_pending_assignments!` 를 절대 안 부른다** — 자유도 0 인 스케줄을 다시 푼다.
   2026-08-30 이 "또 하나의 침묵 성공" 이라고만 적은 현상의 원인이 이것이다.
5. 🔴 **2026-08-30 계획서의 `payload_edge_multiplier` 는 후보 간선에서 항상 1.0 = 무동작이다.**
   그 함수는 `m = _payload_mass(env, node_v, …)` 로 **`v` 쪽** 질량을 쓰는데,
   `_payload_mass_measured` 는 `TransportUnitGo|DepositCargo|FormTransportUnit` 이 아니면
   던진다(`battery.jl:206`). 실측(release 후 tractor, 후보 2103개):

   | 어디서 재나 | 잴 수 있는 간선 |
   |---|---|
   | `v` (SOURCE, 전부 `RobotGo`) | **0 / 2103** ◀ 계획서가 쓰는 쪽 |
   | `v2` (TARGET, 전부 `RobotGo`) | 0 / 2103 |
   | **`v2` 한 홉 아래 (전부 `FormTransportUnit`)** | **2103 / 2103** |

   한 홉 아래 질량 `0.32768 … 12.800`, 평균 3.486, **서로 다른 값 15종**(39배 범위) — 축은
   존재하고 분산도 충분하다. 계획서가 한 홉 위를 보고 있었을 뿐이다.
   ⟹ **D-5a.** 그리고 로봇 신원은 `v` 에서 읽는다: `_edge_owner_id(sched, v)` 가
   **18개 전부 유효한** `BotID{DeliveryBot}`, 반면 `v2` 는 43개 전부 무효
   (`reset_slot_to_invalid!` 의 의도대로). ⟹ 계약은 **"로봇은 `v` 에서, 화물은 `v2` 한 홉
   아래에서"** 다.

6. 🔴 **`_PAYLOAD_REF = 2.29` 는 이 판에 대해 틀렸다.** 계획서는 `rates.jl` 의 짐 질량 실측
   `0.0 … 2.29 kg` 을 인용했는데 그것은 **다른 픽스처**의 값이다. tractor.mpd 의 실측
   상한은 **12.800** 이다(2026-08-30 §6-1 의 `0.32768 … 12.800` 과 일치). 2.29 를 쓰면
   대부분의 화물에서 정규화 인자가 1을 넘어 배수가 과도해진다.

7. **S1 의 `slots_upper_bound` 은 무정보다** — 값 자체는 재현되지만(18, 전 구간 고정)
   후보가 0 이든 1320 이든 18 이다. 이 값으로 전제조건 판정을 하면 안 된다.

---

## 3. 설계 — L2 주조 도구의 body

L2 가 주조하는 도구의 body 는 **최소 셋**이어야 한다:

```
release_pending_assignments  →  reprice_agent_by_payload  →  commit_respec
        (알파벳에 있음)              (새로 만든다)              (알파벳에 있음)
```

알파벳 19개 중 **첫째와 셋째는 이미 있다.** 새로 만드는 것은 가운데 하나뿐이다.

* 첫째가 없으면 후보 간선이 0 이라 재가격 클로저가 **0번 호출**되고, 세계는 바이트 동일인데
  L2 는 `handled=true` 로 기록한다(§1-3, §2-3).
* 셋째가 없으면 `reprice_agent_by_payload` 의 `mechanism` 이 직접 적듯 *"INERT ON ITS OWN …
  without a re-solve the world is byte-identical"* 이다.

🔴 **`mechanism`·`preconditions` 에 "release 를 먼저 붙여라"라고 **명령하지 않는다**.**
사실만 적는다(이 원시는 후보 간선이 있을 때만 효과가 있다 / 후보 간선은 미배정 미래 작업이
있을 때만 생긴다). 명령을 적으면 재는 것이 추론이 아니라 프롬프트 준수가 된다 —
`_EXPRESSIBLE_DESC` 주석이 이미 그 대가를 기록해 뒀다(2026-08-29, 1/3 → 3/3).
body 에 재풀이가 안 붙으면 그것은 결함이 아니라 **원시 문서의 실패**이고 관측 대상이다.

---

## 4. 새 추정기 — wear-leveling

목표 비용은 payload 와 SoC 가 **곱으로 결합**하는 형태다:

```
cost(로봇 r, 간선 e) = dt_e · (idle_power + load_power · m_e) · f(SoC_r)
```

SoC 가 낮은 로봇은 **무거운 간선에서 불균형하게** 더 비싸지고, `dt` 가 살아 있으니 거리도
함께 거래된다. "가까운 로봇 중 SoC 높은 쪽에 무거운 작업" 이 목적함수에서 자동으로 나온다.
완주 판정은 어디에도 안 들어간다(D-3).

**구현 경로는 둘이다. ✅ 사용자가 2026-09-01 에 (b) 를 승인했다(D-5).**

* (a) `edge_energy` 쪽 — ①②를 열어 `payload_mass` 를 넘기고 `load_power>0` 으로 둔다.
  전역 변경이라 **모든 레인의 배정 지문이 바뀐다.** 기존 녹화와 같은 세계가 아니게 된다.
* (b) **`edge_cost_multiplier` 쪽** ← 채택 (D-5). 🔴 **단, §2-5 의 실측이 집행 방식을 정정한다.** `edge_cost_multiplier(sched, v)`(`:1398`)가
  `EDGE_COST_MULTIPLIER[]` 클로저를 곱한다. 그 클로저가 `v` 의 노드에서 payload 를 **직접
  읽으면** payload 의존성이 배율에 들어간다 — 계획서의
  `_payload_factor(m, light_bias) = 1 + light_bias·(m/_PAYLOAD_REF)` 가 그 모양이다.
  ⟹ **①②를 안 건드려도 되고, 변경이 이 원시가 설치된 동안으로 국한된다.**

  **집행 형태(D-5a).** 기존 2인자 `edge_cost_multiplier(sched, v)` 는 **그대로 두고**
  3인자 메서드를 **더한다**:

  ```julia
  edge_cost_multiplier(sched, v, v2) =
      edge_cost_multiplier(sched, v) *                       # SoC·agent 축 (기존, 무변경)
      (EDGE_PAYLOAD_MULTIPLIER[] === nothing ? 1.0 :
       EDGE_PAYLOAD_MULTIPLIER[](sched, v, v2))              # payload 축 (새로, 기본 무효)
  ```

  훅이 없으면 3인자 == 2인자라 **기본이 바이트 동일**이다. 생산 호출부는 둘뿐이고
  (`:1141` MILP · `:1586` greedy) 둘 다 이미 `v2` 를 손에 쥐고 있다
  (`greedy_edge_cost(::GreedyEnergyAwareCost, sched, v, v2, dt)` 는 시그니처에 이미 있다).
  나머지 참조 3건은 `tools/tests.jl` 의 2인자 단언이라 손대지 않는다.
  두 축이 **곱**해지므로 `payload × SoC` 결합이 정확히 이 자리에서 생긴다.

  ⚠️ (b) 를 고르는 근거는 §1-6 의 실측 뒤에 바뀐 것이다. 측정 전에는 "채널(①②)을 먼저 열고
  플래너가 쓰는 값을 그대로 읽자" 가 권고였는데, ①②가 **전역**이라 모든 레인의 배정 지문을
  바꾼다는 점과 (b) 로도 같은 곱 결합이 나온다는 점이 확인되면서 뒤집혔다. 이 문단은 그
  번복을 숨기지 않기 위해 남긴다.

여전히 ③(`AUTO_EFFICIENCY_KAPPA`)은 필요하다 — κ 가 `nothing` 이면 목적함수가 `edge_costs`
를 통째로 버린다. `run_demo.jl:531-532` 가 `ENERGY_OBJECTIVE=1`(기본)일 때
`init_objective_weights!()` 를 부른다는 것은 확인했으나, **그 경로가 이 도구의 재풀이에도
실제로 살아 있는지는 미측정**이다(§9).

🔴 **`_PAYLOAD_REF` 와 `light_bias` 의 값은 이 spec 이 단정하지 않는다.** 실측 payload 범위
(0.33 … 12.8 kg, 평균 2.48)와 `payload_density=100.0` 이 프록시라는 사실 위에서, 배정 지문이
실제로 움직이는 최소 크기를 **음성 대조와 함께** 재는 것이 T-4 의 일이다.

---

## 5. 사실 블록 — `expressible=False` 가 정직해지는 조건

`_battery_block`(S1/T2)은 이미 `pending_transports` · `heaviest_payload_kg` ·
`total_payload_kg` · `fleet_soc_median` · `robots_with_higher_soc` · `this_robot_soc` 를 싣는다.
빠진 것은 **"그래서 이 배선이 비싸다"** 를 말할 수 있는 값이다.

규약은 그대로다 — **사실만 적고 "그러니 무엇을 하라"는 절대 안 적는다.**
`test_battery_block.py` 의 금지어 검사와 줄 수 감사를 통과해야 한다.

🔴 **새 추정량을 지어내지 않는다.** 프롬프트에 적을 숫자는 **플래너가 실제로 쓰는 비용**에서
와야 한다. §4(b)를 하고 나면 그 값이 존재한다(그 로봇의 pending 간선들의 배율/비용). 두 번째
진실원을 만들면 이 레포가 반복해 겪은 실패로 돌아간다.

⚠️ **`expressible == False` 비율을 성공 지표로 쓰지 않는다.** `_EXPRESSIBLE_DESC` 주석이
직접 적듯 그 비율은 부분적으로 **프롬프트 준수**를 잰다. 세대를 가르는 키는 `decision_source`.

---

## 6. 창(window) — 결정 시점 의존 가용성

§1-4 가 강제하는 설계다. 재분배는 **미배정 미래 작업이 남아 있을 때만** 성립한다.

* 창이 열려 있을 때(`closed ≲ 220`) — 재분배가 가능한 답이고, mild 사건에서
  `expressible=False` → L2 → 주조 → 집행이 의미를 갖는다.
* 창이 닫힌 뒤(`closed ≳ 247`) — 옮길 일 자체가 없다. **이때는 어떤 어휘로도 답이 없고,
  L2 도 발화하면 안 된다** — 합성할 것이 없기 때문이다. 이 구간의 정직한 답은 NOOP 이다.

⟹ 이것은 결함이 아니라 **측정해야 할 성질**이다. "늦은 mild 사건은 답이 없다" 는 관측이
"모델이 틀렸다" 로 기록되면 안 된다. 결정 행에 창의 상태를 남긴다(§8 G-3).

🔴 **그래서 S2 의 평가는 `closed` 로 층화해야 한다.** 층화 없이 mild 정답률 하나를 내면
창 밖 사건이 창 안 사건의 성적을 오염시킨다.

---

## 7. 안 하는 것

* **매크로 어휘를 안 건드린다** — `action_registry.json` · `vocab` 도장 · 라벨 격자 ·
  `MACRO_TO_TOOL` 전부 그대로(D-2).
* **`battery_menu_lanes_agree.jl` 의 mild testset 을 안 뒤집는다**(D-1).
* **①②(`edge_energy` payload 배선 · `load_power`)를 안 건드린다**(§4b). 필요해지면 그때
  별도 결정으로 연다 — 전역 배정 지문이 바뀌는 변경이라 기존 녹화를 무효화한다.
* **`rebalance_for_battery!` 를 고치지 않는다.** 그 침묵 성공은 §2-3 에 기록만 하고, 이
  레인은 새 경로를 쓴다. (고치는 것은 그 자체로 별도 레인이다 — 배터리 분기의 이중 호출
  문제가 붙어 있다: `.claude/CLAUDE.md` §구현자가 부딪힐 지점.)

---

## 8. 게이트

| # | 무엇을 못박나 | 음성 대조 |
|---|---|---|
| **G-1** | `release_then_candidates` 가 비개입이다 | 같은 env 에 두 번 불러 원본 `ne` 불변 · `INVALID_ID_COUNTERS` 불변 · 두 호출 값 동일. 카운터 복원을 빼면 빨개져야 한다 |
| **G-2** | body 에 release 가 없으면 세계가 **바이트 동일**이다 | release 있는 판과 없는 판의 배정 엣지 집합 차이. `:rebalanced` 심볼을 증거로 쓰지 않는다 |
| **G-3** | 결정 행에 창의 상태가 남는다 | 창이 닫힌 판에서 그 필드가 `0`(못 쟀다 아님)으로 기록되는지 |
| **G-4** | 재가격이 **실제로 배정을 바꾼다** | `light_bias=0` 이면 배정이 바이트 동일, `>0` 이면 달라진다. 두 방향 다 있어야 측정이다 |
| **G-5** | 사실 블록에 판정이 안 샌다 | `test_battery_block.py` 의 금지어 + 줄 수 감사 확장 |

🔴 **G-2·G-4 는 반환 심볼로 판정하지 않는다.** 세계가 바뀌었는가를 가르는 관측은
`length(LAST_EDGE_COSTS[]) > 0` 와 재풀이 전후 배정 엣지 집합의 차이 둘뿐이다(2026-08-30 §6-1).

---

## 9. 미측정 · 위험

1. **③ `AUTO_EFFICIENCY_KAPPA` 가 이 도구의 재풀이 경로에서 살아 있는가** — 미측정.
   `LAST_AUTO_EFFICIENCY_W` 를 읽어 확인해야 한다. 2026-08-30 은 κ=0.01 을 켠 뒤에도
   `LAST_AUTO_EFFICIENCY_W = 0.0` 이었다고 적었는데, 그것은 후보 0 인 판의 관측이라
   **창이 열린 판에서 다시 재야 한다.** ⟹ T-1 의 첫 일.
2. **창의 경계가 판·시드에 따라 어디인가** — 한 판(seed 1, `DEMO_OOD_SEED=7`)만 쟀다.
   `closed≈247` 은 이 판의 값이지 상수가 아니다.
3. **release 가 결정 시점에 안전한가** — 진행중(active) 작업은 보존한다고 코드가 적지만,
   실제 판에서 release 후 재풀이가 완주를 깨지 않는지는 **미측정**이다. 프로브는 사본에만
   걸었으므로 이 위험을 아직 만난 적이 없다.
4. **`_payload_mass` 의 density 가 미검증** — `battery.jl:72` 주석이 직접 그렇게 적는다.
   kg 숫자를 물리량으로 인용하지 말 것.
5. **`decision_source` 가 세대 판별 키다.** `expressible==False` 비율로 성공을 주장하지 말 것.

---

## 10. 재현 명령

프로브 셋은 `tools/probes/` 에 넣었다 — **일회성 측정 스크립트**이고 스위트에 안 싣는다
(SMDP 계열과 같은 규약: 독립 프로세스). 지우면 §1-2·§1-3·G-1 의 재현 경로가 사라진다.

```bash
# ③ 정확 카운트 (t=0, 세 판 — colored_8x8/tractor × greedy/milp)
julia +lts --project=. tools/probes/probe_candidate_edges.jl

# 단계별 생존 수 (A→F, 어느 조건에서 죽는가)
julia +lts --project=. tools/probes/probe_where_it_dies.jl

# 비개입 검증 (G-1)
julia +lts --project=. tools/probes/probe_copy_safe.jl

# 결정 시점 창 (아래 참고: S2_CANDIDATE_PROBE 는 7c49c4d6 이 지웠다 — 지금은 무조건 돈다)
DEMO_OOD=battery DEMO_BSOC=0.30 DEMO_POLICY=canonical \
DEMO_ROUTER=0 DEMO_SEED=1 DEMO_N=6 DEMO_OOD_SEED=7 DEMO_OOD_LO=0.15 DEMO_OOD_HI=0.90 \
julia +lts --project=. tools/monitor/run_demo.jl
```

🔴 최종 리뷰 F5 정정: `S2_CANDIDATE_PROBE` 게이트는 `7c49c4d6` 에서 삭제됐다
(`grep -rn S2_CANDIDATE_PROBE` 는 이제 이 계획서·이 스펙에만 걸린다 — 코드엔 0건). 위 네 번째
명령에 그 변수를 주는 것은 더 이상 아무 효과가 없다(빠뜨려도 똑같이 돈다) — 지웠다.

`release_then_candidates`(`tools/monitor/policy.jl`)는 이 레인이 추가한 유일한 소스 변경이고
**무조건 돈다** — `ood_features`(`policy.jl:363`) 안에서 env 게이트 없이 매번 불린다. 위
"결정 시점 창" 명령(canonical/router=0)에서는 `ood_features` 가 결정마다 두 번 불린다
(`event_descriptors_of` 경유·`_f` 직접 호출, `policy.jl:530`·`:1901`) — 즉 결정당 두 번
release+formulate 를 문다. **기본 꺼짐이 아니다.** 비개입 계약(원본 sched/scene_tree 불변)은
그 docstring 에 여전히 있다 — 바뀐 것은 "부르느냐 마느냐" 이지 "부르면 세계를 건드리느냐" 가
아니다.
