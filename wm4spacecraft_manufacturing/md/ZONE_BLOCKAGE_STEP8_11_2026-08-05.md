# 구역 결정 — STEP 8~11: 커버리지를 **막힘**으로 바꾸다 (2026-08-05)

앞 문서(`ZONE_REDESIGN_STEP1_7_2026-08-05.md`)의 "다음에 할 일" 1~4 를 그대로 이어받는다.

> 1. 통로(corridor) 술어 — Δ 는 목표 디스크만 보장하고 경로는 보장하지 않는다
> 2. 실제로 막는 zone 사건 만들기
> 3. 팀 술어의 인과 검증
> 4. 라이브 데모 확인

STEP 6 의 결론은 "규칙의 개입 조건이 **기하는 맞고 인과가 틀렸다**" 였다. 이 문서는 그 인과를
코드 수준에서 **특정**하고, 그것을 재는 술어를 만들고, 그 술어가 고른 사건이 정말로 막는지
시뮬레이터로 확인한 기록이다.

---

## 0. 왜 덮여도 완주했나 — 기구를 특정했다

STEP 6 은 "root 하역목표를 8/8 삼켰는데도 291 노드를 전부 닫고 완주했다"를 관측했지만
**왜**인지는 열어 두었다. 코드 경로로 답이 나온다.

| 사실 | 위치 |
|---|---|
| 구역은 오직 한 곳에서 강제된다 — `enforce_restriction_zone_clearance!` 가 에이전트를 원 밖으로 **스냅** | `src/route_planning.jl:318-353` |
| 그 함수가 순회하는 것은 `get_vtx_ids(rvo_global_id_map())` = **RVO 에이전트(로봇·운반유닛)뿐** | 〃 `:322` |
| 그런데 `root_deposit_goals` 가 세는 목표는 **`LiftIntoPlace` 의 goal_config** | `src/respec/restage_zone.jl:348` |
| `apply_cmd!(::LiftIntoPlace, ...)` 는 **화물의 변환을 직접 적분**해 옮긴다 (RVO 경유 없음) | `src/route_planning.jl:1205-1210` |

즉 커버리지가 세던 목표는 **구역이 원리적으로 막을 수 없는 부류**였다. `root_goal_coverage` 의
독스트링이 주장하던 "frac≈1 이면 carrier 가 rim 에 영원히 선다"는 이 시뮬레이터에서 성립하지 않는다.
구역이 실제로 막을 수 있는 것은 **움직이는 주체가 RVO 에이전트인 목표**(`RobotGo` · `TransportUnitGo`)뿐이다.

주의: `LiftIntoPlace <: EntityGo` 이므로 **타입 검사로는 안 갈린다**(`_future_goal_discs` 가
`matches_template(EntityGo, n)` 로 이 셋을 한데 섞는 이유). 가르는 축은 타입이 아니라 **엔티티 종류**다.

### 측정으로 확인한 대비 (tractor, 시뮬 전 env)

```
nav(RobotGo/TransportUnitGo) = 123개, kinematic(LiftIntoPlace) = 27개, root deposit = 8개
  root 하역목표 8개는 전부 운동학(LiftIntoPlace) 목표    <- 좌표 일치로 확인
  그중 nav 목표와 좌표가 정확히 겹치는 것은 1개뿐
  root[i] -> 가장 가까운 nav(운반유닛) 목표까지 거리 = 0.0, 0.16, 0.24, 0.32, 0.32, 0.33, 0.33, 0.40
```

마지막 줄이 핵심이다. 운반유닛은 하역 지점 **근처**에 서고, 마지막 0.16~0.40 은 `LiftIntoPlace` 가
운동학적으로 처리한다. 그래서 하역 지점을 정확히 덮는 구역은 배송을 못 막고 **접근 경로만 늘린다**
— STEP 6 이 본 makespan 2.1 배가 정확히 그 값이다.

같은 구역(중심 core, r=0.5)에 대해:

```
root_covered = 8/8   nav_blocked = 1     <- 커버리지는 막힘의 상계일 뿐 같지 않다
```

---

## 1. STEP 8 — 막힘(blockage) 술어 `src/respec/zone_corridor.jl` (신규)

| 함수 | 무엇을 답하는가 |
|---|---|
| `_nav_goal_targets(env)` | 구역이 **막을 수 있는** 목표의 모수: 미완 `RobotGo`/`TransportUnitGo` 의 목표 + 그 주체의 반지름 |
| `_kinematic_goal_targets(env)` | 커버리지가 세던 부류(`LiftIntoPlace`) — 대비를 위해 1급으로 남김 |
| `goal_engulfed(goal, r_agent, zones)` | 포획볼(반지름 = `capture_distance_tolerance()`)이 통째로 배제원(`r_zone + r_agent`) 안인가 = **확정 막힘**(닫힌 식) |
| `free_space_status(start, goal, zones, r_agent)` | 부풀린 자유공간 격자 flood-fill: `:clear` / `:engulfed` / `:agent_trapped` / **`:disconnected`** |
| `zone_blockage(env)` | 위를 모아 `n_nav_goals · n_engulfed · n_disconnected · n_blocked · n_agent_trapped` + 운동학 대비 |

`:disconnected` 가 계획서가 요구한 **corridor 술어**다. `_minimum_clear_translation` 의 Δ 는
목표 디스크가 구역 밖임만 보장하고 **경로는 보장하지 않는다** — 목표가 완전히 비어 있어도 고리형
배치면 못 간다. 격자 상자는 {시작·목표·부풀린 구역 전부}를 3칸 여유로 감싸므로 바깥 띠가 항상
자유·연결이고, 따라서 **상자 때문에 거짓 `:disconnected` 가 나오지 않는다**.

정직한 한계 두 가지를 코드 주석과 독스트링에 명시했다:
- flood-fill 은 **이산화**다. `cell`(기본 = 로봇 반지름의 절반)보다 좁은 틈은 열린 것으로 읽힐 수 있어
  결과에 쓴 해상도를 함께 반환한다.
- `goal_engulfed` 는 구역을 하나씩 본다(보수적). 두 구역의 **합집합**으로만 삼켜지는 경우는
  flood-fill 쪽이 잡는다.

---

## 2. STEP 9 — 배선: 원시값은 싣고, 규칙은 opt-in

`zone_diagnosis` 에 원시값 5열을 추가했다: `n_nav_goals · n_nav_blocked · n_nav_engulfed ·
n_nav_disconnected · n_agent_trapped`. **판정(verdict)은 기본적으로 그대로**다.

인과 규칙은 `ZONE_CAUSAL_RULE=1` 로만 켜진다:

```
막을 수 있는 목표를 하나도 안 막았으면(n_nav_blocked == 0) -> :noop   (덮였든 말든)
그 외에는 기존 최소수복 순서(forbid_zone > relocate_build > line_stop)
```

기본이 꺼짐인 이유는 두 가지다. (a) 옛 라벨·게이트 재현성, (b) **아직 근거가 부족하다** —
규칙을 바꿀 자격은 STEP 10 이 "막는 사건에서 NOOP 이 실제로 실패한다"를 보인 뒤에 생긴다.
비용 이유로 `zone_diagnosis` 안에서는 engulf 만 계산하고(정확한 하한), 통로 검사는
`ZONE_CHECK_PATHS=1` 또는 `check_paths=true` 로 켠다.

### 검증 — `tools/tests.jl zone_corridor` (신규, **25/25 ALL GREEN**)

```
[1] root 하역목표는 전부 운동학 목표다 / 전부가 nav 목표인 것은 아니다        PASS
[2] 운동학 목표 위 구역: covered=1  blocked=0     <- 덮였다 ≠ 막혔다          PASS
    nav 목표 위 구역:    blocked=2 (engulf=2)                                  PASS
[3] 촘촘한 고리 -> :disconnected (목표 자체는 engulf 아님)                     PASS
    성긴 고리   -> :clear / 단일 원판 -> :clear (돌아가면 된다)                PASS
[4] root_covered=8 > nav_blocked=1  (커버리지가 막힘을 과대평가)               PASS
    덮기만 하는 구역: 커버리지 규칙 -> forbid_zone / 인과 규칙 -> noop         PASS
```

회귀: `tools/tests.jl zone_diagnosis` **42/42 ALL GREEN** (기본 OFF 가 옛 판정을 그대로 재현).

---

## 3. STEP 10 — 실제로 막는 zone 사건 (`tools/restage.jl causal`)

### 하니스 (그리고 그 하니스가 **아닌** 것)

`tools/restage.jl causal` 은 팔(arm)마다 **프로세스를 새로 띄운다**. RVO 시뮬레이터와 그 id 맵이
전역이라, 한 프로세스에서 두 팔을 돌리면 두 번째 팔이 첫 팔이 남긴 모션 상태 위에서 시작한다 —
`deepcopy` 대조군은 그래서 허구가 된다. 각 팔은 같은 세계를 다시 지어 같은 발화점(closed=58)에서 주입한다.

**정직한 차이**: 이 하니스에는 STEP 6 의 라벨 하니스가 켜 두었던 **자가치유 경로가 없다**.
`maybe_emit_reform_ood!` 는 `RESPEC_ENABLED[]` 를 요구하고(ood_injection.jl:579), `CARRIER_RESCUE` 는
기본 OFF 다(replace_robot.jl:804). 그러므로 여기서 재는 것은

> **순수 물리에서 이 구역이 완주를 막는가**

이고, STEP 6 이 잰 것은 "복구 장치를 켠 채로 막는가"다. **두 수치를 섞어 쓰면 안 된다.**

### 결과 — 두 절제 팔 (fired at closed=58/289, seed 고정)

| 팔 | 구역 | 진단 | 커버리지 규칙 | 인과 규칙 | 결과 |
|---|---|---|---|---|---|
| `blk_noop` | nav 목표(운반유닛) 위, r=0.07 | root **0**/8 · domain 0 · **nav_blocked 3**(engulf 3) · &#124;Δ&#124;=2.38 | `:noop` | `:noop`* | **stalled 254/289** (makespan 116.9) |
| `cov_noop` | core zone, r=0.321 | root **8**/8 · domain 0 · **nav_blocked 1** · trapped 2 · &#124;Δ&#124;=3.58 | `:relocate_build` | `:relocate_build` | **stalled 227/289** (makespan 113.4) |

**\* 이 줄이 이번 실험의 가장 중요한 산출이다.** `blk_noop` 의 구역은 root 하역목표를 **하나도**
안 덮고(`root_covered=0`) 재적치 도메인도 비어 있어(`domain=0`), 커버리지 기반 규칙은 그것을
**볼 수단 자체가 없다** — 무조건 `:noop` 이다. 그런데 그 구역은 실제로 완주를 막는다.

그리고 최초 구현의 인과 규칙도 똑같이 `:noop` 이라 답했다. 이유는 규칙을 **억제 조건으로만** 썼기
때문이다(`nav_blocked==0 → :noop`, 그 외에는 옛 커버리지 분기로 폴백). 막힘이 **발화 조건**이 아니면
커버리지가 0 인 사건에서는 여전히 눈이 없다. 그래서 규칙을 다음과 같이 고쳤다 — 커버리지를
**완전히 무시**한다:

```
ZONE_CAUSAL_RULE=1:
    n_nav_blocked == 0                 -> :noop
    n_nav_blocked > 0 ∧ 국소 도메인 有  -> :forbid_zone
    n_nav_blocked > 0 ∧ Δ 有            -> :relocate_build
    그 외                               -> :line_stop
```

### 1차 전체 (복구 사다리 OFF) — 그리고 대조군이 정정해 준 것

| 팔 | 개입 | 결과 |
|---|---|---|
| `control` | 구역 없음 | **complete** · closed 279/289 · makespan **19.73** |
| `blk_noop` | — | stalled **254** |
| `blk_reloc` | `translate_whole_build! -> :translated` | stalled **258** |
| `cov_noop` | — | stalled **227** |
| `cov_reloc` | `translate_whole_build! -> :translated` | stalled **258** |

두 개입 팔이 **정확히 같은 258** 에서 멈춘 것을 보고 처음에는 "하니스에 복구 사다리가 없어
모든 팔이 루트 엔드게임 교착에 걸린 것"이라고 적었다. **대조군이 그 진단을 뒤집었다**:
구역이 없으면 이 하니스는 767 스텝 만에 **완주**한다(makespan 19.73). 그러므로 네 정체는
하니스의 취약함이 아니라 **구역이 만든 것**이다.

남는 사실은 더 흥미롭다: **RelocateBuild 는 두 가족 모두에서 완주를 되찾지 못했다**
(227→258, 254→258). 그리고 STEP 6 의 라벨 하니스에서는 같은 core zone 이 NOOP 으로 **완주**했다
(closed 291, makespan 47) — 그 하니스에는 `RESPEC_ENABLED` 기반 reform 과 `CARRIER_RESCUE` 가
켜져 있었다. 즉 **복구 장치가 있느냐가 이 사건의 결론을 바꾼다.**

그래서 2차를 돈다: 데모와 같은 사다리(`recover_stalled_teams!` → `resolve_schedule_wedge!`)를
간격·예산·순서까지 **모든 팔에 동일하게** 걸고(`ZC_REFORM=400`, `ZC_REFORM_MAX=3`, 진전 시 예산 복구)
7팔 전부(3가족 × 2 + control)를 다시 돌린다 —
`oracle/run_zcausal_all.sh` → `out/zcausal_reform/`. 1차는 `out/zcausal/` 에 그대로 둔다.
2차가 답할 질문은 정확히 하나다:

> **복구 사다리로도 못 푸는 구역과, 사다리가 풀어 주는 구역이 갈리는가?**
> 갈린다면 그 경계가 곧 결정이고, `n_nav_blocked` 가 그 경계를 사전에 말해 주는지가 이 층의 값어치다.

### ★ 2차 (복구 사다리 ON, 모든 팔 동일) — **세 기준 전부 PASS**

`out/zcausal_reform/`, 채점 = `oracle/zcausal_report.py`.

| 가족 | 진단 | NOOP | RelocateBuild | 최선 |
|---|---|---|---|---|
| **blocking** (nav 목표 위) | root 0/8 · **nav_blocked 3** | stalled **254** (mk 117.3) | **complete 279** (mk 35.4) | **RelocateBuild** |
| **core zone** (root 목표) | root **8**/8 · nav_blocked 1 | stalled **232** (mk 132.8) | stalled **197** (mk 141.2) | **NOOP** |
| (control, 구역 없음) | — | complete 279 · mk **19.7** · reform 0 | | |

```
기준 (1) H(best|zone) = 1.000 bits   PASS      (분포: RelocateBuild 1, NOOP 1)
기준 (2) 동점률        = 0/2 = 0.0%  PASS
기준 (3) regret(closed): blocking·NOOP = 25 오답 / core·RelocateBuild = 35 오답
```

**STEP 6 이 실패했던 기준 (1)이 성립한다** — 같은 kind 안에서 정답이 뒤집히는 두 사건을 처음으로 만들었다.

### 정체의 귀속 — 상관이 아니라 인과

```
blk_noop:  reform 3회 전부 recover=no_team  wedge=not_applicable
           정체 시점 활성 EntityGo 6개 중 **이 구역이 막는 것 3개** (구역이 막는 노드 총 3개)
cov_noop:  reform 5회, 활성 8개 중 막는 것 1개
control:   reform 0회, 완주
```

멈춘 프론티어가 **곧 그 구역이 막는 집합**이다. 그리고 복구 사다리는 3회 모두 "손댈 팀이 없다"고
답했다 — 이건 팀 교착이 아니라 **기하적 봉쇄**라서 팀 복구로는 원리적으로 못 푼다. 그 구역을
치우는 유일한 수단이 공간형 팔이고, 실제로 `RelocateBuild` 가 완주를 되찾았다(254 → **279**).

### 두 규칙의 성적표 — 인과 규칙이 고친 것과 **아직 못 고친 것**

| 사건 | 실측 최선 | 커버리지 규칙 | 인과 규칙 |
|---|---|---|---|
| blocking (root 0, 막힘 3) | RelocateBuild | `:noop` ✗ (regret 25) | `:relocate_build` ✓ |
| core zone (root 8/8, 막힘 1) | NOOP | `:relocate_build` ✗ (regret 35) | `:relocate_build` ✗ |
| | | **0/2** | **1/2** |

인과 규칙은 **커버리지가 원리적으로 볼 수 없는 사건**(root_covered=0인데 실제로 막는 구역)을 고쳤다.
그러나 두 번째 줄에서 여전히 틀린다: core zone 은 nav 목표를 1개 막지만, 그걸 고치자고 빌드를
통째로 옮기면 **더 나빠진다**(232 → 197). 즉

> **막힘 > 0 은 개입의 필요조건이지 충분조건이 아니다.** 수복 자체의 파괴력이 함께 들어가야 한다.

이건 튜닝으로 덮을 문제가 아니라 다음 단계의 설계 문제다(막힌 노드 수 · 그 노드들이 잠그는 하류
작업량 vs 이동이 흩뜨리는 진행 중 작업량). 그래서 규칙은 **여전히 opt-in 으로 둔다** —
1/2 짜리 규칙을 기본으로 켜는 것은 정직하지 않다.

### `harmless` 가족은 만들지 못했다 (정직한 실패)

"커버리지 > 0, 막힘 = 0" 인 구역을 발화점(closed=58)에서 심으려 했으나 `status=no_target` —
그 시점의 **모든** 운동학 목표가 어떤 nav 목표의 배제원 안에 있었다(시뮬 전 env 에서는 여유 0.01 로
간신히 하나 있었다). 그러므로 그 가족은 이 세계·이 시점에서 구성되지 않는다.
이것도 결과다: **빌드가 진행될수록 커버리지와 막힘은 기하적으로 얽힌다.**

### 남은 한계 (다음 사람이 속지 않도록)

- **n = 2 사건, seed 1개, 발화점 1개(closed=58).** H=1.000 bits 는 "이 두 사건에서 답이 갈렸다"는
  뜻이지 분포에 대한 주장이 아니다. 통계를 붙이려면 seed·발화점·구역위치를 훑어야 한다.
- **`:disconnected` 는 아직 한 번도 실측에서 발화하지 않았다.** 두 사건 모두 `engulf` 로 잡혔다.
  통로 봉쇄 자체는 유닛테스트(고리 배치)에서만 확인됐다 — 실제 OOD 가족으로 만들려면 구역 **여러 개**를
  동시에 심어야 하고, 현재 주입기는 하나만 심는다.
- **인과 규칙은 2/2 가 아니라 1/2** (위 성적표). 기본은 계속 OFF.
- 라벨 파이프라인(`gen_oracle_dataset.jl` 의 행, `policy.jl::ood_features`)에는 아직 이 원시값을
  싣지 않았다. 특징 차원이 바뀌면 이미 export 된 서로게이트·novelty 교정과 호환이 깨지므로,
  STEP 3 이 zone 원시값을 다룬 것과 같은 방식(opt-in 열)으로 따로 붙여야 한다.

---

## 4. STEP 11 — 팀 술어의 인과 검증 (`tools/tests.jl zone_team_causal`) — **6/6 ALL GREEN**

계획서 3번: "슬롯이 덮였음은 증명했지만 그 팀이 **실제로 형성에 실패하는지**는 아직 아니다."

**설계**: 병렬 대조군이 아니라 **런 내 반전**(reversal). RVO 시뮬레이터와 id 맵이 전역이라
`deepcopy` 대조군은 모션 상태를 몰래 공유하고, 세계를 다시 지으면 이 런의 좌표를 재현하지 못한다.
그래서 같은 팀에 대해 `구역 ON → K 스텝` 과 `구역 OFF → 같은 K 스텝` 을 이어서 잰다.
제거가 형성을 복구시키면 바뀐 것은 구역뿐이므로 오히려 더 강한 증거다.
**nav 는 반드시 ON** — 구역 강제는 RVO 에이전트만 밀어내므로 `rvo_flag=false` 면 검사가 공허해진다.

```
대상 팀: ready=0 missing=2  gather=[1.302,-3.178]  slot_gap=2.119
진단:   teams_covered=1/5  nav_blocked=4(engulf=4)  trapped=1  verdict=relocate_build

[2] 구역 ON  1200 스텝 -> formed=false   slot_gap 2.119 -> 0.406   (빌드 자체는 진행: closed 51->151)
[3] 구역 OFF 같은 예산 -> formed=true    5 스텝 만에      gap -> 0.0
```

멤버들은 슬롯 **0.41 앞**(≈ 배제 반경 = 구역반지름 + 로봇반지름)에서 고정돼 있었고, 구역을 치우자
**5 스텝**만에 결합했다. 즉 이 팀은 "느렸던" 것이 아니라 **못 모였다**. 덤으로 특이성도 보인다:
같은 1200 스텝 동안 빌드 전체는 100 노드를 더 닫았다 — 이 구역은 빌드가 아니라 **그 팀**을 막았다.

이로써 커버리지 술어 중 **팀 슬롯 술어만은** 인과까지 확인됐다. 나머지(root 커버리지)는
0 장에서 본 대로 반대 방향의 답이 나왔다 — 같은 종류의 술어라도 결론이 갈린다는 뜻이고,
그래서 각각을 따로 재야 한다.

---

## 5. 다음에 할 일 (우선순위 순)

1. **개입의 비용을 규칙에 넣기.** 지금 인과 규칙은 1/2 다. 필요한 것은 임계값 튜닝이 아니라
   두 양의 비교다 — (a) 막힌 노드들이 잠그는 **하류 작업량**, (b) `translate_whole_build!` 가
   흩뜨리는 **진행 중 작업량**. (b) 는 이미 측정 가능하다(cov 가족: 232 → 197 = −35).
2. **다중 구역 주입기.** `:disconnected`(통로 봉쇄)는 구역이 하나면 무한 평면에서 원리적으로
   안 생긴다. 고리형(≥3개) 주입을 만들어야 그 가지가 실측에서 처음 발화하고, STEP 7 의
   `:line_stop` 게이트도 그때 비로소 의미를 갖는다.
3. **표본 확대.** seed × 발화점 × 구역위치 격자로 위 두 사건이 우연이 아님을 보이기
   (지금은 n=2, seed 1, 발화점 1).
4. **라벨·정책 경로에 원시값 싣기.** `gen_oracle_dataset.jl::capture_features` 와
   `policy.jl::ood_features` 에 `zone_nav_blocked` 계열을 STEP 3 과 같은 **opt-in 열**로.
   (특징 차원이 바뀌면 배포된 서로게이트·novelty 교정과 호환이 깨지므로 기본은 꺼짐.)
5. 라이브 데모(`render_demo.jl`)에서 새 원시값 + 게이트 실행 확인 — LLM 비용이 드는 유일한 항목.

## 6. 되돌리는 법

| 스위치 | 효과 |
|---|---|
| (기본) | 원시값만 실림. 판정·라벨·게이트는 STEP 1~7 과 **동일** |
| `ZONE_CAUSAL_RULE=1` | 개입 조건이 커버리지 → 막힘으로 바뀜 |
| `ZONE_CHECK_PATHS=1` | 통로(flood-fill) 검사까지 켬(기본은 engulf 만) |
| `zone_diagnosis(...; check_blockage=false)` | 막힘 계산 자체를 끔 → 새 열은 `-1` 센티넬 |
