# L2 레인 배선 설계 — OOD 사건에 대한 행동 합성 (STEP 1: 진단 전용)

- 날짜: 2026-08-25
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`, HEAD `8b81e6ee`)
- 상태: 설계 초안. 구현 계획은 별도 문서.
- 선행 문서: `2026-08-24-unified-llm-respec-design.md` (§2~§4 를 **승계**하고 일부를 **정정**한다)

> **근거 구분 규약.** 이 문서의 모든 수치는 **2026-08-25 이 머신에서 실제로 실행해 얻은 것**이다.
> 코드를 읽고 추론한 것은 **추론이라고 표시**한다. 이 레포는 정적 추론이 뒤집힌 이력이 많고,
> 이 세션에서만 내 판단이 두 번 뒤집혔다(§2-5).

---

## 0. 한 줄 요약

닫힌 매크로 어휘(`NOOP`·`Replace`·`SwapBattery`)가 답할 수 없는 OOD 사건에 대해, LLM 이
**자유 파라미터를 가진 행동을 합성**하게 하고 4층 안전장치로 거른다. **STEP 1 에서 집행은
계속 매크로가 한다** — 합성된 행동은 생성·검증·기록만 되고 세계를 바꾸지 않는다.

어휘 세 종류, 축 세 개:

```
TranslateBuild(dx, dy)          기하축   — forbid zone
ShedLoad(agent, factor)         부하축   — mild battery      ← 신규 kind
LinearConstraint / Disjunction  시간축   — 진단용(오답 축 측정)
```

---

## 1. 이 문서가 선행 spec 을 정정하는 지점

`2026-08-24-unified-llm-respec-design.md` 는 승인된 상태이고 §2~§4(와이어 계약·안전 규칙·채점
배선)를 그대로 승계한다. 아래 넷만 이 문서가 **바꾼다**. 전부 2026-08-25 실측이 근거다.

| 선행 spec | 이 문서 | 근거 |
|---|---|---|
| `constraints` union = `ReplaceAgent`·`SwapBattery`·`TranslateBuild`·`LinearConstraint`·`Disjunction` | **로봇 kind 둘을 뺀다.** `ShedLoad` 를 더한다 | §3 D-13 |
| §3.4 일관성 게이트(macro↔constraints) | **STEP 1 에서 안 잰다** — known 레인은 매크로가 계속 집행하므로 잴 대상이 없다 | §3 D-13 |
| §1 "레인 2 입력 = NL + 서술자 6개 + valid 메뉴" | **서술자 채널은 죽어 있다.** 복구가 이 작업의 선행조건 | §2-1 |
| §4.3 "unscored 로 인쇄할 구간이 남지 않는다" | mild battery(soc>0.2)·zone 은 unscored 로 남는다(2026-08-25 어휘 결정 이후) | §2-2 |

---

## 2. 이 설계의 근거 — 2026-08-25 측정

### 2-1. 🔴 LLM 은 오늘 서술자를 받지 못한다

시뮬레이션 스트림에서 뽑은 `llm_input` 전문:

```
OBSERVATION: Robot R1 has broken down at (-0.7, 0.7) and cannot move.
```

`MEASURED STATE` 블록이 없다. 같은 결정에서 surrogate 는 받는다:

```
OOD kind=fault, severity=1.0, spares_left=12, agents_pending=4, progress=0.19, n_active=22
```

사슬(실측): `route()` 는 `install_novelty!()` 실패 시 `descriptors` 키 **없이** 조기 반환
(`policy.jl:390-394`) → `decide_all` 의 `desc = nothing` → payload 에 미포함 → `_llm_input` 이 문장만
렌더. 그리고 교정 파일 경로 `wm4spacecraft_manufacturing/novelty/novelty_calibration.json` 은
**디렉토리 자체가 존재하지 않는다.**

**귀결**: 오늘 기록된 모든 LLM 결정은 문장 한 줄로 내린 것이고, surrogate 와의 비교는 입력이
다른 비교다. `TranslateBuild` 의 Δ 유도도 `ShedLoad` 의 factor 유도도 상태 없이는 불가능하므로
**이 채널 복구가 이 작업의 Task 1 이다.**

(⚠️ `nl_mode="observation"` 은 정상 작동한다 — 주입 문구의 지시절이 실제로 제거된 것을 확인했다.
다만 `fault_robot!` 원문에는 `"; dispatch the nearest backup robot..."` 이 남아 있어
`LLM_NL_MODE=raw` 와 오프라인 라벨 레인은 답을 넘겨받는다. battery 쪽은 2026-08-05 에 정리됐다.)

### 2-2. 사건 4종의 진단 품질 — 시뮬 5런 + 통제 프로브 34콜

시뮬은 `run_demo.jl`, `DEMO_POLICY=dspy`, gpt-4o, 같은 world seed. `C0` 은 무사건 대조군.

| 런 | 사건 | 상태 | closed | sim_seconds | energy/closed | 채점 |
|---|---|---|---|---|---|---|
| C0 | 없음 | complete | 291/313 | 20.60 | 264 | — |
| K1 | fault ×4 | complete | 291/313 | 73.62 | 865 | **4/4** |
| K2 | severe battery ×4 | complete | 291/313 | 37.00 | 329 | **4/4** |
| O1 | mild battery ×3 + deep ×1 | complete | 291/313 | 23.55 | 280 | 1/1 (3건 unscored) |
| O2 | forbid zone ×1 | **stall** | **274/313** | 130.20 | 817 | 0건 (unscored) |

판정:

- **severe battery: 진단이 건전하다.** 8/8 `SwapBattery`, 근거문이 정확한 자원 논증을 한다
  — *"the robot itself is not faulty … without consuming a spare robot."*
- **fault: 미검증.** 시뮬 4건 모두 `agent_pending>0` 이라 정답이 갈리는 조건이 안 나왔다.
  프로브로 만들어 보면: 문장만 줄 때 `pend=0`(a\*=NOOP)에서 **0/2**, 서술자를 주면 **3/5**,
  `pend=1`(a\*=Replace)에서 **1/3**. `a*` 는 `pend>0` 이라는 **이산 술어**인데 LLM 이 받는
  `work_at_risk` 는 연속 비율이라 0→1 계단이 `0.00→0.11` 로 뭉개진다.
- **mild battery: severity 를 못 가른다.** 3팔 메뉴에서 soc 0.25 와 0.45 가 **둘 다** SwapBattery.
  ⚠️ 2026-08-24 보고서의 *"근거 문장은 severity 를 정확히 구분하는데 argmax 만 무너진다"* 는
  **틀렸다** — 근거 문장 자체가 일관되지 않는다(0.25 "흡수 가능", 0.45 "50% 아래라 교체").
- **zone: 3팔 메뉴를 주면 진단이 정확하다** — *"a spatial constraint rather than a fault or
  depletion issue"* 라며 로봇 팔을 거부한다. 같은 조건에서 **surrogate 는 SwapBattery 를 고른다.**

### 2-3. 🔴 `[NOOP]`-only 메뉴는 근거문을 오염시킨다

메뉴가 하나뿐일 때 모델의 근거문(실측):

- mild battery: *"**Since NOOP is the only valid action**, it is the default choice."*
- zone: *"Since NOOP is the only valid action, **it implies that the exclusion zone does not
  currently affect any active robot operations**."*

두 번째가 특히 나쁘다 — **메뉴 모양으로부터 없는 세계 사실을 역추론한다.** 그리고 그 판은
274/313 에서 멈췄다. 같은 사건에서 모델이 받은 프롬프트에는 이렇게 적혀 있었다:

```
  of which blocked       = 3      (구역이 사는 한 이 노드는 영영 못 닫는다)
  work frozen by those   = 32     (그 뒤에 걸려 얼어붙는 미완 노드)
  min_shift_to_clear_m   = 2.38   (모든 미완 목표를 구역 밖으로 빼는 최소 강체이동)
```

**닫힌 어휘의 무능이 실제 빌드 실패를 냈고, 라벨에는 거짓 근거가 붙은 NOOP 이 남았다.**
이것이 L2 레인이 필요한 이유다.

### 2-4. SwapBattery 는 공짜가 아니다 — mild battery 에 새 행동이 필요한 이유

대조군 대비 사건당 추가 비용(실측):

| 팔 | sim_seconds/건 | energy/closed |
|---|---|---|
| `SwapBattery` | **+4.1 s** | 264 → 329 (+25%) |
| `Replace` | +13.3 s | 264 → 865 (+228%) |

레지스트리 cost(`SwapBattery 0.2` / `Replace 1.0`)는 **창고 예비 본체라는 자원만** 센다.
창고 왕복 시간과 `halt_build` 라인 정지는 그 숫자에 없다.

그리고 **degraded-but-alive 상태가 실재한다** — `BATTERY_DERATE`(기본 `hi=0.5, min_factor=0.35`)를
`run_demo.jl:596` 이 기본으로 켠다. 실측 `stall=true@0.15 derate=true`:

```
soc ≤ 0.15          속도배율 0.0        정지
0.15 < soc < 0.50   0.35 ~ 1.0 선형     느리지만 계속 일한다   ← 여기
soc ≥ 0.50          1.0                무영향
```

🔴 `action_registry.json` 이 `Deprioritize` 를 지운 사유 — *"이 하니스의 배터리 사건은 '저하'가
아니라 '정지'(SoC 0)라 … **degraded-but-alive 상태가 없다**"* — 는 **오늘 거짓이다.** derate 는
2026-08-05 에 들어왔고 삭제는 2026-08-20 이므로 **삭제 시점에 이미 틀린 근거였다.**

### 2-5. 스파이크 — `Σ Xa[a] ≤ k` 인코딩은 **반증됐다**

부하 상한을 `LinearConstraint` 로 쓰려던 초안을 실측으로 죽였다. `colored_8x8`,
`assignment_mode=:greedy`(= `run_demo.jl` 과 같은 모드):

| 시나리오 | Xa 구조적 nonzero | 로봇당 frontier | 로봇당 후보 엣지 |
|---|---|---|---|
| t=0 (frozen=∅) | 423 | 1 | **0** |
| mid-build (closed=89/342) | 423 | 0–2 | **0** |
| `release_pending_assignments!` 직후 | **3197** | 0–1 | **55** |

두 가지가 각각 독립적으로 죽인다:

1. **수술 전에는 셀 것이 없다.** `:greedy` 는 MILP 이전에 이미 전부 배정한다 — frontier 가
   `outdeg=1`(구조적 엣지 = `Xa==1` 고정)이고 `n_eligible_succ=1` 이라 대안 자리가 없다.
2. **수술 후에도 중간이 없다.** 55개는 **같은 한 칸에 대한 55개의 대안**이지 55개의 일이 아니다.
   모델 자신의 차수 제약 `Xa*ones .<= n_eligible_successors`(=1)가 `Σ_v2 Xa[v,v2] ≤ 1` 을 강제한다.
   frontier 가 로봇당 1개(14대 중 13대)이므로 `Σ Xa[a] ∈ {0,1}` — `k=0`=`ForbidAgent`, `k=1`=공허.

**스파이크가 덤으로 잡은 것 둘** (질문보다 크다):

- 🔴 **`ForbidAgent` 는 이 레인에서 MILP 제약을 0개 추가한다.** 수술이 선행하지 않으면 컴파일러
  루프가 돌고 아무것도 안 건다. 즉 일반 `verify()` 경로로 그냥 emit 하면 **조용한 no-op 인데
  `Admit` 으로 통과한다.** `baselines.jl:173` 의 B3 오라클이 지금 그 경로에 있다.
- 🔴 **측정 레인은 재풀이를 한 번도 하지 않는다.** 4런 13결정 전부 `ran_milp = False`
  (`Replace`×4, `SwapBattery`×5, `NOOP`×4). 그러므로 `AGENT_COST_BIAS`(목적함수 재가격)는
  **그냥 켜면 무효다** — `edge_cost_multiplier` 는 `formulate_milp` 이 `edge_costs` 를 만들 때만
  읽히는데 그 함수가 안 불린다. **이것이 삭제된 `DeprioritizeAgent` 가 "제안 338회 대비 선택
  0회" 였던 이유를 설명한다** — 골라도 정의상 아무 일도 일어나지 않았다.

### 2-6. `release_pending_assignments!` 는 **되돌릴 수 없다**

`fault_robot_and_reassign!` 은 수술 → `verify` 순서이고, `verify` 가 `Reject` 를 내면
`:rejected` 를 반환하는데 **떼어낸 엣지를 복구하는 코드가 없다**(`reassign.jl:388-394`).
호출부는 그 뒤 `engage_fallback!`(line stop)을 건다. 즉 이 수술은 **일방통행 문**이다.

→ 이 사실이 §7-4 의 설계 제약이 된다: **`ShedLoad` 는 STEP 1 에서 완전 검증이 불가능하다.**

---

## 3. 결정 사항 (사용자 결정, 2026-08-25)

| # | 결정 | 근거 |
|---|---|---|
| **D-11** | **STEP 1 = 진단 전용.** `constraints` 는 생성·검증·기록만, 집행은 계속 `macro` | 선행 spec §3.3 불변식. O2 의 274/313 을 STEP 2 의 기준선으로 보존 |
| **D-12** | Δ 유도 입력은 **zone center+radius 만.** `min_shift_to_clear_m` 은 결정 레인 프롬프트에서 **뺀다** | 그 값은 `_find_min_translation` 의 답이다. 주면 L2 신설이 아니라 `RelocateBuild` 받아쓰기가 된다(`spec_dsl.jl:342`) |
| **D-13** | union 에 **로봇 kind 를 넣지 않는다** | `emitted_key` 가 `ReplaceAgent→(:fault,·)` / `SwapBattery→(:battery,·)` 로 **사건 클래스를 인코딩**한다(`ood_truth.jl`). zone 사건에서 emit 하면 없는 사건 클래스가 채점기에 주입된다 |
| **D-14** | 실효성 위반은 **거부**한다 (`Reject(:inert)`) | 통과했는데 아무것도 안 고치는 제약이 라벨로 쌓이면 §2-3 의 거짓 NOOP 오염과 같아진다 |
| **D-15** | L2 자유 파라미터 축을 **둘** 연다 — 기하(`TranslateBuild`) + 부하(`ShedLoad`) | mild battery 는 채점 격차가 아니라 **행동 격차**다(§2-4). SwapBattery 의 +4.1s 를 안 쓰고도 빌드가 끝날 수 있다 |
| **D-16** | `LinearConstraint`/`Disjunction` 은 남기되 **진단용** | zone 에는 구조적으로 inert(§5-3), mild battery 에는 부하축이 답이다. 남기는 값어치는 "LLM 이 엉뚱한 축으로 답했다" 를 `:inert` 로 **측정**하는 것 |

---

## 4. 목표 구조

```
OOD 주입 (fault | battery | zone)
  │  NL 관찰 + 서술자 6개 + valid 메뉴 + zones(center·radius) + agents(id·label)
  ▼
POST /decide → DSPy PickMacro (gpt-4o)
                 reasoning    무슨 일이 났는가        ← 인식
                 constraints  DSL JSON 문자열          ← 합성   (신규)
                 macro        valid 중 하나            ← 결정
                 ranking, margin
  ▼
서비스: ① schema.py 검증  ② id 접지
  ▼
Julia:  ③ 안전 게이트(kind별)   ④ 실효성 게이트
        macro 집행 (STEP 1 — 기존 사슬 그대로, 변경 없음)
        constraints + 4층 판정을 결정 행에 기록
```

출력 필드 순서 `reasoning → constraints → macro` 가 곧 **"합성한 다음에 결정"** 이다
(DSPy adapter 가 선언 순서대로 생성한다).

🔴 **불변식 (선행 spec §3.3 승계): `constraints` 가 어떤 층에서 실패하든 `macro` 는 그대로 산다.**
STEP 1 에서 집행은 매크로가 하므로, 합성 실패가 결정을 바꾸면 "같은 세계" 비교가 깨진다.

---

## 5. 어휘 — 3종, 축 셋

### 5-1. `TranslateBuild(dx, dy)` — 기하축 (기존 자산)

이미 존재하는 것(실측): DSL 타입 + 비유한 Δ 거부 생성자(`spec_dsl.jl:363`), pydantic 스키마 +
`extra="forbid"` + 기본값 없음(`schema.py:290`), **게이트 `verify_translate`**(`verifier.jl:518`,
전용 테스트 `test/respec_verify_translate.jl`), 집행부 `_apply_uniform_translation!`
(`restage_zone.jl:616`).

**이 작업이 하는 것은 배선뿐이다** — 새 기전을 안 만든다.

`verify_translate` 가 이미 실효성 검사를 갖고 있다: `|Δ| ≥ _TB_MIN_DELTA`(hollow admit 금지) ·
`translate_clears_zones` · `_within_workspace_bounds`. 즉 이 kind 는 §6 의 ④가 이미 닫혀 있다.

### 5-2. `ShedLoad(agent, factor)` — 부하축 (신규 kind)

**의미**: "이 로봇은 살아 있고 명령을 받을 수 있지만 느리다. 죽이지 말고, **평소보다 일을 덜
받게** 하라." 창고 예비 본체도 배터리 배송도 소모하지 않는다.

**왜 새 kind 인가** — `ForbidAgent` 와 `NOOP` 사이의 연속체이고, 그 중간이 `Σ Xa` 축에는 없고
목적함수 축에만 있다(§2-5):

```
factor = 1        NOOP 과 동일 (편향 없음)
1 < factor < ∞    이 로봇의 배정 엣지가 비싸진다 → 솔버가 알아서 덜 준다   ← 신설분
factor → ∞        ForbidAgent 와 극한에서 같다
```

**집행부는 셋의 합성이고 셋 다 이미 존재한다** (추론 아님 — 각각 코드 위치를 확인했다):

```
① release_pending_assignments!(env, inv; faulted = agent)   reassign.jl:121   후보 엣지를 연다 (423→3197)
② deprioritize_agent!(agent, factor)                        essential_tg_coponents.jl:1379  clamp[1, 1e3]
③ MILP 재풀이                                                기존           이때 ②가 목적함수에 들어간다
```

②만 켜면 무효라는 것이 §2-5 의 실측이다 — ③이 없으면 `edge_cost_multiplier` 가 아예 안 읽힌다.
**삭제된 `DeprioritizeAgent` 를 그대로 되살리면 안 되는 이유가 이것이다.**

**생성자 계약** (`spec_dsl.jl` 에 추가):
- `factor` 는 유한해야 한다. 아니면 **생성자에서 죽는다**(클램프 금지 — 조용한 폴백 금지).
- `factor ≥ 1.0` 이어야 한다. `< 1` 은 그 로봇을 **우대**하는 것이고 문법 오류다.
- `factor == 1.0` 은 생성자가 아니라 **집행부/게이트가** `:inert` 로 거부한다 —
  0 을 `TranslateBuild` 생성자가 아니라 집행부가 거부하는 것과 같은 규약(`spec_dsl.jl:353-360`).

### 5-3. `LinearConstraint` / `Disjunction` — 시간축 (진단용)

이미 존재한다(실측): 컴파일 `compiler.jl:143·178`, 접지 검사 `grammar_ground_check`
(`verifier.jl:654`), 테스트 `test/respec_grammar.jl`. 게이트는 **kind 를 안 보는** `verify()`
(`verifier.jl:83`)다.

🔴 **zone 사건에서는 구조적으로 항상 inert 다.** 구역에는 수명이 없고(`RESTRICTION_ZONES` 를
지우는 곳이 시뮬 루프에 없다), 막힘의 정의가 *"the node can never close **while the zone
lives**"* 이며, `VarRef` 는 `t0`/`tF` 만 허용한다(`:xa` 는 의도적으로 닫혀 있다 —
`llm_bridge.jl:422`). **시간을 어떻게 재배치해도 영영 안 닫히는 노드는 안 닫힌다.**

그래서 이 채널의 역할은 수복이 아니라 **측정**이다: 기하 문제에 시간 제약으로 답하려 한
시도가 `Reject(:inert)` 로 세어진다.

---

## 6. 안전 스택 — 4층

| 층 | 어디 | 무엇을 본다 | 실패 시 기록 |
|---|---|---|---|
| ① 문법·타입 | 서비스, `schema.py` `model_validate` (`extra="forbid"`, 기본값 없음) | 닫힌 union · 필수 필드 · 생성자 불변식 | `constraints=[]`, `constraints_error="parse"\|"schema"` |
| ② 접지 | 서비스(id 대조) + Julia `grammar_ground_check` | 참조한 로봇/노드/변수가 **실재**하는가 | 그 제약 **하나만** 버리고 `constraints_dropped` 에 기록 |
| ③ 안전 | Julia, kind 별 | 과거불가침 · MILP feasibility · 기하 경계 | `Reject(reason)` |
| ④ 실효성 | Julia, kind 별 | **관측된 막힘에 닿는가** | `Reject(:inert)` |

②를 줄리아의 `verify()` 에만 맡기지 않는 이유: STEP 1 의 측정 레인은 `verify()` 를 아예 타지
않으므로(§2-5: `ran_milp=False`) 환각한 id 를 셀 자리가 서비스밖에 없다.

### kind 별 ③④ 매핑

| kind | ③ 안전 | ④ 실효성 | 상태 |
|---|---|---|---|
| `TranslateBuild` | `verify_translate` (경계·구역) | `verify_translate` (`\|Δ\|≥_TB_MIN_DELTA`, `translate_clears_zones`) | ✅ 둘 다 있음 |
| `ShedLoad` | **STEP 1 에서 불가** (§7-4) | 축소판: `factor>1` ∧ 그 agent 가 pending 배정을 실제로 소유 | ⚠️ 부분 |
| `LinearConstraint`/`Disjunction` | `verify()` (kind 무관) | **신규**: 참조 노드 ∩ frozen 집합 ≠ ∅ | ⚠️ ④ 신규 |

**④의 판정 규칙은 화이트리스트가 아니라 필요조건이다.** "우리가 승인한 수복 목록" 을 두면
예상 못한 좋은 수복까지 잘린다. 대신 **"이 제약이 관측된 막힘에 닿을 수 있는가"** 라는
필요조건만 본다. 막힘이 관측되지 않은 사건에서는 어떤 제약도 `:inert` 다.

`LinearConstraint` 의 frozen 집합은 `zone_diagnosis` 가 이미 계산한다 — O2 런 실측으로
`n_nav_downstream = 32`, `n_nav_blocked = 3`.

---

## 7. `ShedLoad` 상세

### 7-1. 와이어 형태

```jsonc
{"kind": "ShedLoad", "agent": "RobotID(5)", "factor": 4.0}
```

`agent` 는 프롬프트의 `agents` 목록이 준 **정확한 id 문자열**을 그대로 echo 해야 한다
(`open_agent_descriptors` 가 만드는 형태 — `llm_bridge.jl:139`). 지어낸 id 는 ②에서 걸린다.

### 7-2. `factor` 를 LLM 이 무엇에서 유도하는가

프롬프트가 주는 것: 그 로봇의 **SoC**, `agent_pending`(그 로봇이 진 미완 운반 작업 수),
서술자 6개, 활성 함대 크기. 주지 **않는** 것: 정답 factor, `AGENT_COST_BIAS` 의 현재 값,
"얼마면 충분한가" 에 대한 어떤 힌트도. (D-12 와 같은 규약 — 오라클의 답을 안 준다.)

### 7-3. `Replace`·`SwapBattery` 와의 자원 대비 (프롬프트에 실을 표)

| 행동 | 소모 자원 | 실측 비용(사건당) |
|---|---|---|
| `NOOP` | 없음 | 0 |
| `ShedLoad` | 없음 (스케줄 품질만) | **미측정 — STEP 2 가 잰다** |
| `SwapBattery` | 배터리 + 창고 왕복 + 라인 정지 | +4.1 sim s, energy/closed +25% |
| `Replace` | **창고 예비 본체**(희소) + 왕복 | +13.3 sim s, energy/closed +228% |

### 7-4. 🔴 STEP 1 에서 완전 검증이 불가능하다 — 그리고 그것이 괜찮은 이유

`ShedLoad` 의 ③(MILP feasibility)은 ①수술이 선행해야 의미가 있는데, **그 수술은 되돌릴 수
없다**(§2-6). STEP 1 은 세계를 안 바꾸는 것이 불변식이므로 ③을 돌릴 수 없다.
그리고 `snapshot`/`restore!`/`fork` 는 이 레포가 **짓지 않기로 명시한 것**이다(`.claude/CLAUDE.md`).

**STEP 1 의 처리**: ①②와 **축소판 ④**만 돌린다 —
```
factor > 1.0                                   (생성자·문법)
그 agent 가 pending 배정 엣지를 실제로 소유한다   (읽기 전용, 그래프만 본다)
```
그리고 결정 행에 `verify = "deferred"` 를 기록한다. **`unknown` 이나 `agree` 로 뭉개지 않는다** —
"못 쟀다" 와 "재서 통과했다" 는 다른 사건이고, 이 레포는 그 둘을 섞어 여러 번 데였다.

**비되돌림 수술을 STEP 1 이 안 한다는 것 자체가 D-11(진단 전용)의 가장 강한 근거다.**
`ShedLoad` 의 완전 게이트(`verify_shed`: 비파괴 시험 풀이)는 §9 의 STEP 2 선행조건이다.

---

## 8. 프롬프트 채널 변경

| 채널 | 변경 | 근거 |
|---|---|---|
| 서술자 6개 | **복구한다** (`novelty/` 재생성 또는 `route()` 가 서술자만은 항상 싣게) | §2-1. 없으면 Δ·factor 유도가 불가능 |
| `zones` (center·radius·covers) | **추가** | `TranslateBuild` docstring 이 요구하는 유일한 입력 |
| `agents` (id·label) | **추가** | `ShedLoad.agent` 접지 |
| `nodes` (AssemblyComplete 마일스톤 ≈ 9개) | **추가** | `LinearConstraint` 의 `VarRef.node`. 전체 미완 노드(~255)가 아니라 마일스톤만 |
| `min_shift_to_clear_m` | **제거** | D-12 |
| 피해 증거(`of which blocked`, `work frozen by those`) | **유지** | 오라클의 답이 아니라 개입의 근거다 |

⚠️ 프롬프트가 바뀌므로 **기존 dspy 녹화와의 직접 비교가 끊긴다.** 선행 spec §7.1 이 이미
"같은 세계 불변식은 폐기한다" 로 그 비용을 받아들였다.

---

## 9. 결정 행 스키마 · 채점 · 승격 게이트

`run_demo.jl` 의 `this_decision` Dict 에 추가(선행 spec §4.1 승계 + `verify`/`efficacy` 신설):

```julia
"constraints"         => [...]        # 검증을 통과해 파싱된 DSL
"constraints_raw"     => "..."        # 감사용 원문
"constraints_error"   => nothing      # "parse" | "schema" | nothing
"constraints_dropped" => []           # ② 접지 실패로 버린 것 (환각 id)
"verify"              => "admit"      # "admit" | "reject:<reason>" | "deferred"
"efficacy"            => "resolves"   # "resolves" | "inert" | "deferred"
"emitted_keys"        => [...]        # CB.emitted_key 로 **Julia 가** 계산
```

키 매핑은 Julia 에서만 계산한다 — 파이썬에 한 벌 더 두면 `schema.py ↔ spec_dsl.jl` lockstep
에서 이미 겪는 이중 정의 문제가 하나 더 생긴다.

**STEP 2 승격 게이트가 읽을 것** (임계값은 STEP 1 측정 **후에** 정한다 — 지금 숫자를 지어내지
않는다):

- `constraints_error` 비율 (①의 실패율)
- `constraints_dropped` 건수 (②가 잡은 환각 id)
- `verify == "admit"` 비율, 그리고 `reject` 사유 분포
- `efficacy == "inert"` 비율 — **특히 kind 별로.** zone 사건에서 `LinearConstraint` 가 몇 번
  나왔나가 곧 "엉뚱한 축으로 답했다" 의 빈도다
- `ShedLoad` 의 `verify == "deferred"` 비율 (= §7-4 의 미검증 구간 크기)
- **비파괴 시험 풀이(`verify_shed`)가 지어졌는가** — `ShedLoad` 집행 전환의 하드 선행조건

---

## 10. 공개된 위험

1. **L2 가 합성한 Δ 가 매번 `_find_min_translation` 의 Δ 와 같아질 수 있다.** 그러면 승격되는
   "새 macro" 는 사실상 2026-08-24 에 삭제한 `RelocateBuild` 다. 이건 실패가 아니라 **loop 가
   삭제된 좋은 행동을 스스로 재유도했다는 검증**으로 읽어야 한다. D-12(min_shift 은닉)가 이
   위험을 **검사 가능하게** 만든다 — 답을 안 주고도 같은 Δ 에 도달하는지가 측정값이 된다.
2. **`ShedLoad` 는 STEP 1 에서 `deferred` 로만 쌓인다** (§7-4). 이 축의 값어치는 STEP 2 전에는
   증명되지 않는다. mild battery 사건 수만큼 `deferred` 행이 생기는 것이 정상이다.
3. **`ForbidAgent` 의 조용한 no-op 은 이 작업이 안 고친다** (§2-5). `baselines.jl:173` 의 B3
   오라클이 지금 그 경로에 있고, B3 를 쓰는 비교는 그만큼 오염돼 있다. 별개 작업으로 남긴다.
4. **서술자 채널 복구(§8)가 이 작업의 최대 미지수다.** `novelty/` 디렉토리와
   `export_novelty_calibration.py` 가 **둘 다 없다.**
   🔴 **이 문서가 정하는 기본 경로: 교정 파일을 재생성하지 않고 `route()` 를 고친다** —
   `install_novelty!()` 가 실패해도 `event_descriptors_of` 는 계산해 `rt["descriptors"]` 에
   싣고, 라우팅 판정만 비활성으로 둔다. 근거: 라우팅(교정값이 필요)과 서술자 계산(교정값이
   **필요 없다** — `novelty.jl:310` 의 순수 함수다)이 지금 한 게이트에 묶여 있는 것 자체가
   결함이고, 교정 파일 재생성은 이 작업의 범위 밖 의존성을 끌고 온다.
   ⚠️ 이 수정은 라우터를 켜지 않는다 — `enabled=false` 는 그대로다.
5. **`min_shift_to_clear_m` 제거는 기존 zone 녹화의 프롬프트를 바꾼다.** §8 의 대가 그대로.

---

## 11. 이 문서가 **안 하는 것** (범위 선언)

- **집행 전환(STEP 2).** `run_demo.jl` 집행 사슬 은퇴 · `verify()` 거절 시 폴백 · `verify_shed`
  비파괴 시험 풀이는 전부 별도 spec 이다.
- **`Deprioritize` 매크로 복원.** `ShedLoad` 는 레지스트리 항목이 아니다 — id 도 cost 도 없다.
  레지스트리 승격(L3)은 관측이 쌓인 뒤의 별도 결정이다.
- **`:xa` 채널 개방.** §2-5 가 그 축의 인코딩을 반증했고, `llm_bridge.jl:422` 의 함정 서술도
  그대로 유효하다.
- **`ForbidAgent` no-op 수정** (위험 3).
- **mild battery 의 채점 근거 확보.** `reference_policy` 가 그 구간을 unscored 로 두는 것은
  이 문서가 안 바꾼다. `ShedLoad` 는 **행동 격차**를 메우지 채점 격차를 메우지 않는다.
