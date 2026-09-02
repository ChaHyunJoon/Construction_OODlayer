# 설계: 화물 금지 제약 (`ForbidHeavyCargo`) — payload wear-leveling 의 지렛대 교체

**날짜** 2026-09-01 · **브랜치** `oracle-rebuild-night-2026-08-10` · **선행** `2026-09-01-s2-payload-reprice-design.md`

이 문서가 **구속력 있는 권위**다. 계획서·브리프가 이 문서와 어긋나면 이 문서가 이긴다.

---

## 1. 무엇을 고치는가

S2 는 `reprice_agent_by_payload` 를 만들었다 — 대상 로봇의 무거운 화물 간선을 비싸게 만들어
MILP 재풀이가 그 일을 남에게 넘기게 하려는 원시다. **그 원시는 목적을 달성하지 못한다.**

실측(2026-09-01, `tools/probes/probe_why_argmin_wont_move.jl`): colored_8x8·tractor 두 판,
전 체크포인트, `light_bias ∈ {0, 0.5, 2, 4, 32}` 전부에서 **대상 로봇이 일을 하나도 잃지 않는다.**
그리고 재가격 팔과 음성 대조(재가격 없이 같은 release 만)의 `n_reassigned` 이 **완전히 같다**.

### 왜 (원인은 하나로 좁혀졌다)

`probe_kappa_renormalization.jl`, tractor·closed=60:

| bias | `w_eff` | `eff(S_A)` | `eff(S_B)` | Δenergy |
|---|---|---|---|---|
| 0 | 0.00045405 | **2.375** | **22.25** | −0.00902 |
| 32 | 0.00038499 | 10.274 | 22.25 | −0.00461 |

- `Δspeed = 0.0` — **makespan 이 완전히 동일하다**(검산: `14.551078 − 0.00045405×2.375 = 14.550000`,
  `14.560103 − 0.00045405×22.25 = 14.550000`). 목적값 차이 +0.009024 는 **전부 에너지항**이다.
- 🔴 **A 를 밀어내면 에너지가 9.4배 비싸진다**(2.375 → 22.25). A 가 그 일을 쥔 이유는 **가장 가깝기
  때문**이고 MILP 는 에너지 목적함수가 시켜야 할 일을 이미 하고 있다.
- 재정규화 자기상쇄는 **반증됐다**: `w_eff` 는 15%만 줄고 `eff_b(S_A)` 는 4.3배 큰다. 차등은 커진다.
- 외삽하면 뒤집는 데 `light_bias ≈ 80` 이 필요하다. JSON 상한은 4.0 이다.

⟹ **원리적 문제다.** wear-leveling 은 *"운반 에너지를 일부러 더 쓴다"* 는 결정인데, 에너지항의
존재 이유는 그 최소화다. 비용 편향은 **에너지항에게 자기를 배신하라고 설득하는 셈**이다.

### 대안은 측정으로 확인됐다

`probe_can_a_be_displaced.jl` — `ForbidAgent`(로봇 퇴역)가 아니라 **A 의 재탈환 간선만**
`Xa ≤ 0` 으로 막으면:

| closed | 기준 obj | 차단 obj | Δ | 판정 |
|---|---|---|---|---|
| 60 | 14.5511 | 14.5601 | **+0.062%** | 둘 다 OPTIMAL, 0.2s |
| 151 | 14.5531 | 14.5628 | **+0.067%** | 둘 다 OPTIMAL, 0.2s |

A 는 계속 살아서 다른 일을 한다. **그 +0.06% 가 정확히 "이 개입이 쓰는 추가 운반 에너지"** 이고,
논문이 그대로 쓸 숫자다.

---

## 2. 전제조건 — 이것 없이는 아무것도 안 움직인다

### 2-1. 🔴 T13 공통 재풀이는 지금 무동작이다

`resolve_assignments!`(`src/smdp/generative.jl:238`)은 **구현돼 있고** `apply_action!`(`:360`)이
NOOP 포함 모든 팔 뒤에 부른다(CLAUDE.md 가 "미구현" 이라고 적어둔 것은 2026-09-01 에 정정됐다).

그런데 `release_pending_assignments!` 를 안 부르므로 후보 간선이 없다. 실측
(`probe_release_in_harness.jl`, colored_8x8):

| closed | 0 | 62 | 120 | 170 | 220 | 250 |
|---|---|---|---|---|---|---|
| release 없는 후보 간선 | 0 | 0 | 0 | 0 | 0 | 0 |
| `n_reassigned` | 0 | 0 | 0 | 0 | 0 | 0 |

아무도 못 본 이유: `test/smdp_common_resolve.jl:97` 의 단언이 `@test r.n_reassigned >= 0` 이라는
**항진**이다.

### 2-2. release 는 **팔이** 하고, **범위를 좁혀야** 한다

**팔이 한다** — harness(`resolve_assignments!`)로 옮기면 NOOP 이 함대 전체를 재배정하는
(closed=62 에서 `n_reassigned=198`) 가장 파괴적인 팔이 된다. null action 이 성립하지 않는다.
그리고 fault 팔이 이미 자기 안에서 `faulted` 로 범위를 좁혀 release 한다
(`replan.jl:888` → `reassign.jl:374`) — 관행이 이미 action 쪽이다.

**범위를 좁혀야 한다** — `probe_scoped_release.jl`:

| closed | 전체 후보 | 좁힌 후보 | 비 | 전체 | **좁힘** |
|---|---|---|---|---|---|
| 0 | 3832 | 198 | 0.052 | 61.2s TIME_LIMIT gap 0.95 | **0.27s OPTIMAL** |
| 62 | 3356 | 178 | 0.053 | 60.4s TIME_LIMIT gap 0.85 | **0.23s OPTIMAL** |
| 120 | 2304 | 120 | 0.052 | 60.3s TIME_LIMIT gap 0.66 | **0.20s OPTIMAL** |
| 170 | 1500 | 89 | 0.059 | 60.3s TIME_LIMIT gap 0.33 | **0.19s OPTIMAL** |
| 220 | 640 | 58 | 0.091 | 60.2s TIME_LIMIT gap 0.085 | **0.27s OPTIMAL** |
| 250 | 364 | 42 | 0.115 | 60.3s TIME_LIMIT gap 0.0002 | **0.20s OPTIMAL** |

축소가 1/6(로봇 수)이 아니라 **~1/19** 인 이유: 후보는 간선 **쌍**이라 초선형으로 준다.
전체 release 는 후보 364개인 후반에도 60초 안에 최적성을 증명 못 한다.

⚠️ release 는 `reversible: false` 이고 `INVALID_ID_COUNTERS` 를 해제 간선 수만큼 영구히 깎는다
(실측 드리프트 = released 와 1:1). 프로브는 스냅샷/복원해야 한다.

### 2-3. 구조는 열려 있다

풀린 슬롯마다 **A 아닌 로봇이 후보 출발점으로 존재한다**: colored_8x8 11/11 · 4/4,
tractor 5/5 · 3/3. 재배정은 구조적으로 가능하다.

---

## 3. payload 프록시에 대한 사실 (설계가 의존한다)

`_payload_mass_measured`(`src/navigator/battery.jl:206`)는 **질량이 아니다**:

```julia
r = get_base_geom(cargo, HyperrectangleKey()).radius
return p.payload_density * 8.0 * prod(r)      # = 밀도(100) × 축정렬 bbox 부피
```

실측 분포 — 🔴 **이 세 줄이 재는 것은 `판 전체 화물`이다**(colored_8x8 의 96+3, tractor 의 15
같은 표본 크기가 그것을 보여 준다). `_heavy_cargo_targets` 가 실제로 정렬하는 집합은 그것이
아니라 **표적 로봇 한 대가 소유한 후보 도착점**이고, 그 집합 위에서 다시 재면 숫자가 다르다
(Task 8 실측: colored_8x8 = 고유값 **1개**(11-way 동점), tractor = **5개**). 아래 숫자는
지우지 않고 둔다 — **다른 집합의 측정**으로서는 유효하기 때문이다. 🔴 그러나 "상위 N 이 갈리는가"
를 판정할 때 인용해야 하는 것은 아래가 아니라
`docs/superpowers/plans/2026-09-01-cargo-ban/task-8-end-to-end.md:129-141` 의 표다.

- **판 전체 화물 기준**(← 아래 숫자): colored_8x8 은 고유값 **2개**(2.2938×96 팀2, 15.7286×3 팀4)
  — 사실상 무차등 판이라 재가격이 원리적으로 못 갈린다. tractor 는 고유값 **15개**,
  0.328 … **12.8**(`_PAYLOAD_REF` 가 정확히 이 판의 최대값), 팀 크기 1·2·4.
- **표적 로봇의 후보 도착점 기준**(← 금지가 실제로 정렬하는 집합, Task 8 실측):
  colored_8x8 `BotID{DeliveryBot}(1)` 후보 11개 → 고유값 **1개**(1.14688 × 11, 전부 동점) ⟹
  "상위 1" 은 오로지 tie-break 가 정한다. tractor `BotID{DeliveryBot}(2)` 후보 5개 →
  고유값 **5개**([0.3277, 2.7884], 최댓값 동점 1).

🔴 **1대당 부담은 다른 양이다.** `account_battery_step!`(`battery.jl:290-295`):

```julia
moved_mass = p.m_robot * length(robots) + m_payload   # m_robot = 60.0
share      = km * moved_mass * speed / length(robots) # 팀원끼리 균등 분배
```

⟹ 1대당 짐 부담 = `m_payload / 팀크기`. tractor 에서 두 순서가 어긋나는 쌍이 **9/120 (7.5%)**:

| m_payload | 팀 | m/팀 |
|---|---|---|
| **12.8** | 4 | **3.20** |
| **9.011** | 2 | **4.506** ← 1대당은 이쪽이 무겁다 |
| 2.294 | 2 | 1.147 |
| 1.147 | 1 | 1.147 ← 동률인데 프록시는 2배로 본다 |

⚠️ 규모: 1대당 짐 부담은 최대 4.5 로 **로봇 자기 질량 60 대비 7.5%** 다.

**사용자 결정(2026-09-01)**: 프록시는 팀 크기를 **곱하지 않는다** — action 이 로봇 한 대를
지목하므로 양도 그 로봇의 부담이어야 한다. 회계식대로면 그것은 `m_payload / 팀크기` 다.
**이 설계의 "1대당 부담" 은 언제나 이 값이다.**

---

## 4. 설계

### 4-1. 새 제약 종류 — `ForbidHeavyCargo(agent, n)`

> "이 로봇은 자기가 맡을 예정인 화물 중 **1대당 부담 상위 `n` 개**를 맡지 않는다."

기존 `ForbidAgent`(로봇 통째 퇴역)의 좁힌 판이다. `ForbidAgent` 와 **같은 모양**으로 만든다:
`compile_constraint!` 안에서 대상을 **그때그때 다시 찾고** 해당 `Xa` 항목에 `== 0` 을 건다.

🔴 **얼린 목록이면 안 된다.** `Xa` 는 `formulate_milp` 안에서만 존재하고(`verifier.jl:111`),
그래프는 formulate 사이에 바뀐다. 생성 시점에 얼린 `Xa[u,v]=0` 목록은 나중 formulate 에서
결정변수가 아닐 수 있고 → `Reject(:ungrammatical)` → **고장 경로에서 라인 영구 정지**다.
`ForbidAgent` 가 매 컴파일마다 frontier 를 다시 찾는 것이 정확히 이 문제를 피하는 설계다.

**필요한 메서드는 둘뿐이다**(실측: `grep -rn "::ForbidAgent" src/`):
`compile_constraint!`(`compiler.jl`) · `referenced_ids`(`verifier.jl:688`).
`_enact_kind`(`replan.jl:545`)는 미지 타입을 `:generic` 으로 안전하게 흘린다.
🔴 LLM 이 직접 emit 하지 않으므로 `schema.py`·action registry·ψ 축·monitor 배선은 **건드리지 않는다.**

### 4-2. 지속 금지 보관소

`{로봇 id → n}` 형태의 프로세스 전역. `state_globals.jl` 에 **`:state` 로 등록한다** —
선례는 같은 파일 `:108` 의 `:AGENT_COST_BIAS => :state  # Deprioritize 의 지연 효과` 다.
등록 안 하면 롤아웃 경계에서 안 지워져 이전 판의 금지가 다음 판을 오염시킨다.

### 4-3. 모든 formulate 가 읽는다

훅 자리는 **한 곳**이다 — `essential_tg_coponents.jl:1219`:

```julia
if extra_constraints !== nothing
    compile_proposal!(model, t0, tF, Xa, sched, extra_constraints)
end
_compile_standing_cargo_bans!(model, t0, tF, Xa, sched)   # ← 추가
```

**사용자 결정**: (a)"T13 만 읽는다" 가 아니라 (b)"모든 formulate 가 읽는다". 이유는 파급이 아니라
**누수**다 — (a)면 `verify`·`fault_robot_and_reassign!`·`rebalance_for_battery!` 가 금지를 무시해
고장 재배정 한 번에 무거운 짐이 A 에게 돌아간다. 수명 계약(§4-5)과 모순이다.

### 4-4. 새 원시 — `forbid_heavy_cargo(agent, n)`

레지스트리 항목. 하는 일은 §4-2 보관소에 `{agent → n}` 을 넣는 것뿐이다.
`n` 은 LLM 파라미터, JSON `minimum: 1, maximum: 3`(사용자 결정).

🔴 이 원시는 **자기 힘으로 세계를 안 바꾼다** — `reprice_agent_by_payload` 와 같은 성질이다.
`minted_tool.jl` 의 표 셋(`SILENT_SUCCESS_STATUSES` · `WORLD_UNCHANGED_STATUSES` ·
`PRIMITIVE_RESUMES_CACHE`)을 채워야 게이트 (9)(11)(13)이 초록이 된다.

### 4-5. 수명 — `swap_battery!` 까지

**사용자 결정**: 술어(SoC ≥ θ)가 아니라 **사건**이다. 임계값도 확인 시점도 정할 필요가 없다.
해제 지점은 production 에 **하나뿐**이다 — `swap_battery!(env, role)`(`replan.jl:1213`).
그 로봇의 금지를 거기서 지운다.

### 4-6. 🔴 안전 예외 — 고장 수습이 마모 평준화를 이긴다

`fault_robot_and_reassign!` 이 자기 solve 동안만 금지를 비우고 `finally` 로 복원한다.

**왜**: 실패하면 `_enact_one!`(`replan.jl:889-892`)이 `engage_fallback!` 를 부르고, 그것은
*"first fallback = permanent end of the run, and that is the design"* 이며 **푸는 production
호출자가 0개**다. 즉 편의 규칙이 되돌릴 수 없는 런 종료를 일으킬 수 있다.

**실측(`probe_ban_vs_fault.jl`, tractor·closed=60, 상한 60s)**: 로봇 1/2/3대에 금지
(금지행 4/8/11, N=1 · 13/25/35, N=3)를 걸고 고장 1건을 얹어도 **전부 실행 가능**했다.

⚠️ 전 팔이 `TIME_LIMIT` 라 목적값은 **비교 불가**다(증거: N=3 의 B1 이 12.7768 로 대조 13.2019
보다 낮다 — 제약을 더했는데 좋아지는 것은 최적해에서 불가능). 건전한 것은 실행가능 판정뿐이고,
`FEASIBLE_POINT` 는 해의 존재를 실제로 증명하므로 그 방향은 확실하다.

🔴 **그러므로 이 예외는 관측된 결함에 대한 대응이 아니라, 되돌릴 수 없는 실패에 대한 보험이다.**
코드 주석에 그렇게 적는다. 한 판·한 시점에서 안 났다는 것이 "안 난다"는 뜻은 아니다.

### 4-7. `release_pending_assignments!` 에 범위 인자

`agent::Union{Nothing,AbstractString} = nothing` 을 더한다. 주면 그 로봇이 소유한 미래 배정
간선만 뗀다. 레지스트리 `params` 에 `agent` 를 더한다.

설계상 잘 맞는다: `enact_minted!` 은 body 의 원시들이 params dict **하나를 나눠 갖게** 하므로
(`minted_tool.jl` 의 (5)(6) 단계) `agent` 하나가 두 원시에 자동으로 흐른다.

⚠️ **선택자 미결(§6)**: "그 로봇이 소유한" 을 무엇으로 판정할지가 아직 안 정해졌다.

### 4-8. `reprice_agent_by_payload` 를 레지스트리에서 제거

**사용자 결정**: 알파벳에서만 뺀다. `src/navigator/payload_bias.jl` 과 `test/payload_*.jl` 은
**존치** — 무효함을 보여주는 음성 대조이고, `_payload_factor` 는 §3 의 "1대당 부담" 계산에
재사용된다. κ 설계가 바뀌면 되살릴 수 있다.

---

## 5. 최종 형태

LLM 이 주조하는 tool 의 body:

```
1. release_pending_assignments(agent="…")     # 그 로봇의 미래 배정만 풀어 재계산 여지를 만든다
2. forbid_heavy_cargo(agent="…", n=1)          # 상위 1개 화물을 그 로봇에게 금지
```

그 뒤 `apply_action!` 의 T13 재풀이가 돌고, formulate 가 금지를 읽어 그 화물을 남에게 준다.
금지는 그 로봇에 `swap_battery!` 가 일어날 때까지 모든 formulate 에서 유지된다.

---

## 6. 🔴 미결 — 설계에서 추측으로 정하지 않는다

**컴파일러가 "이 로봇 소유의 화물" 을 찾는 선택자.** 후보 둘:

- `is_agent_frontier`(`ForbidAgent` 가 쓰는 것) — 실측에서 **A 의 정점 1개**를 찾았고 그 정점은
  후보 간선의 출발점이 **아니었다**(후보 간선 중 `u ∈ frontier(A)` = **0개**)
- `_edge_owner_id` — 전체 release 후에도 A 소유 **144개**를 찾았다

⚠️ 두 방식이 보는 대상이 다르다: `ForbidAgent` 컴파일러는 **`Xa` 의 구조적 비영 항목**을 훑고,
위 실측은 **`LAST_EDGE_COSTS`(목적함수가 가격 매긴 후보)** 를 봤다. 단순 비교가 성립하지 않는다.

**구현 첫 태스크가 이것을 잰다.** 그리고 게이트 G-1(§7)이 "금지행 0" 을 빨갛게 만들어
잘못 고른 선택자를 반드시 잡는다.

---

## 7. 게이트

| # | 명제 | 왜 |
|---|---|---|
| **G-1** | 금지가 걸린 판에서 컴파일러가 추가한 행 수가 **0 이 아니다** | 🔴 조용히 아무것도 안 막는 것이 최악. 이번 조사에서 프로브가 실제로 `금지행=0` 으로 공허하게 초록을 냈다 |
| **G-2** | 그 로봇이 **실제로 그 화물을 잃는다** | 반환값이 아니라 배정 결과(`binding`)를 잰다. 침묵 성공 방지 |
| **G-3** | `swap_battery!` 후 그 로봇의 금지가 사라진다 | 수명 계약 |
| **G-4** | 고장 수습 중 금지가 꺼지고 `finally` 로 복원된다 | §4-6. 양성·음성 대조 둘 다 |
| **G-5** | `verify`·`rebalance_for_battery!` 등 **다른 formulate 경로도** 금지를 읽는다 | 한 군데라도 새면 짐이 돌아온다 |
| **G-6** | 보관소가 `state_globals.jl` 에 `:state` 로 등록돼 있다 | 롤아웃 경계 오염 방지 |
| **G-7** | 레지스트리에 `reprice_agent_by_payload` 가 없고 `forbid_heavy_cargo` 가 있다; 표 셋이 알파벳을 덮는다 | 기존 게이트 (9)(11)(13)이 자동으로 잡는다 |
| **G-8** | body `[release(agent=A), forbid_heavy_cargo(agent=A,n)]` 가 `:admit` 되고 **세계가 움직인다** | 종단. `probe_minted_body_enacts.jl` 과 같은 방식으로 세계를 양쪽에서 잰다 |

---

## 8. 하지 않는 것 (YAGNI)

- 임계값 θ — 상위 `n` 으로 갈음(사용자 결정)
- SoC 조건부 발동 — 손잡이가 둘이 되면 학습·평가의 교란이 는다
- LLM 이 제약을 직접 emit — `schema.py` 는 `:xa` 를 **의도적으로** 막아뒀고(`:189-192`) 그 이유
  (*"the prompt ships no list of which (u,v) pairs are actual decision variables"*)는 여전히 유효하다
- κ(에너지 가중치) 조정 — 전역 손잡이이고 CLAUDE.md 가 경고한 파급(*"changes the FIRST plan of
  every run, invalidating recorded streams / oracle labels / the surrogate training set"*)이 크다
- `_payload_mass_measured` 를 팀 크기로 나누도록 **고치는 것** — 그 함수는 물리 회계가 쓰고 있다.
  "1대당 부담" 은 이 설계 안에서 `m/T` 로 **계산**하고, 전역 정의는 건드리지 않는다

---

## 9. 재현

```
julia +lts --project=. tools/probes/probe_release_in_harness.jl      # T13 무동작 · 전체 release 미수렴
julia +lts --project=. tools/probes/probe_scoped_release.jl          # 좁힌 release 수렴
julia +lts --project=. tools/probes/probe_why_argmin_wont_move.jl tractor.mpd 10 60,150,240
julia +lts --project=. tools/probes/probe_kappa_renormalization.jl   # Δspeed=0 · 9.4배
julia +lts --project=. tools/probes/probe_can_a_be_displaced.jl      # 제약이면 +0.06%
julia +lts --project=. tools/probes/probe_ban_vs_fault.jl tractor.mpd 10 60   # 금지+고장 실행가능
```

⚠️ `probe_can_a_be_displaced.jl` 의 `makespan(env.sched)` 출력은 10012/14.55 를 오가는 센티넬이라
**인용 금지**다. 믿을 값은 증명된 최적 목적값이다.
