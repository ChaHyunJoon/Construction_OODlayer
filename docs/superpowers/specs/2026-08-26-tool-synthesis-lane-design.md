# Tool 합성 레인 설계 — 두 속도 루프로 OOD 행동을 만든다

- 날짜: 2026-08-26
- 워크트리: `Construction_OODlayer` (브랜치 `oracle-rebuild-night-2026-08-10`, HEAD `864b48a1`)
- 상태: 설계 초안. 구현 계획은 별도 문서.
- **선행 설계 문서**: 전부 삭제했다 (§1-1). 이 문서는 자족적이다 — 다른 spec 을 인용하지 않는다.

> **근거 구분 규약.** 이 문서에서 *실측*이라고 적은 것은 이 세션(2026-08-26)에 이 머신에서
> 코드를 직접 대조해 확인한 것이거나, 폐기되는 2026-08-25 문서에서 **측정치만 승계**한 것이다.
> 코드를 읽고 추론한 것은 **추론이라고 표시**한다. 이 레포는 정적 추론이 뒤집힌 이력이 많으므로,
> 승계한 줄 번호와 함수 이름은 이 세션에 전부 코드에 다시 대봤다.

---

## 0. 한 줄 요약

LLM이 **tool을 호출**해 그래프를 고치되, 호출할 tool이 없으면 **tool을 합성**한다. 합성된
tool 은 기존 원시 연산의 조합이거나(즉시 집행 가능), 없는 원시를 요구하는 명세다(기록 후
사람이 구현). 알파벳이 두 층이고, 각 층의 무능이 다음 층을 발화시킨다. **초기 개입 tool 은 둘**(`swap_body` · `deliver_battery`) — known failure
event 가 둘(robot breakdown · severe battery depletion)이기 때문이다. 여기에 개입하지 않음을
명시적으로 말하는 `no_intervention` 을 더해 T1 레지스트리는 셋으로 출발한다(§4-2).

```
T1  결정마다   tool 호출     알파벳 = tool 레지스트리 (초기 3개)
T2  OOD 시     tool 합성     알파벳 = 원시 연산 인벤토리
                             출력의 reach 가 "composed" 면 집행, "needs_primitive" 면 기록
```

---

## 1. 이 문서의 위치

### 1-1. 선행 설계 문서를 전부 삭제했다

2026-08-24 ~ 08-26 사이에 이 레인을 놓고 쓰인 설계 문서 넷을 **삭제했다**
(`l2-lane-wiring` · `hybrid-action-generation-stack` · `action-vocabulary-and-menu-contract` ·
`l2-composition-gate`). 사용자 판정: **그 설계들은 틀렸고, 남겨두면 인용될 뿐이다.**

🔴 **그러므로 이 문서는 그것들을 인용하지 않는다.** 옮겨온 것은 둘뿐이고, 둘 다
**2026-08-26 에 코드에서 직접 재확인한 것**이다:

- §1-3 의 관측 — 재측정이 불가능한 실행 기록. 문장은 옮기되 **줄 번호·함수 이름은 전부 재확인**했다.
- §5-2 의 `psi` — `features_agnostic.py:440` 에 실재함을 확인하고 본체를 읽었다.

문서 자체는 `git show 864b48a1:docs/superpowers/specs/<이름>.md` 로만 남아 있다
(마지막 셋은 커밋된 적이 없으므로 **복구 불가**).

### 1-2. 이 설계의 위치 — 합성과 집행이 한 레인이다

이전 설계들은 *"합성한 것은 기록만 하고, 집행은 계속 매크로가 한다"* 는 불변식 위에 있었다.
**이 문서는 그 불변식을 안 쓴다** — tool 은 실제로 그래프를 고치므로 합성과 집행이 한 레인으로
합쳐진다. 그 대가를 §10-2 에 적는다.

---

### 1-3. 승계하는 관측 — 2026-08-25 실측

아래는 폐기한 문서가 담고 있던 관측이다. **재측정이 불가능하므로**(그 세대의 산출물이 없다)
이 절이 **자족적으로** 옮겨 담는다 — 원문은 삭제됐고 `git show 864b48a1` 로만 볼 수 있다. 아래는 전부 2026-08-25 에 `run_demo.jl`,
`DEMO_POLICY=dspy`, gpt-4o, 같은 world seed 로 실제 실행해 얻은 것이다.

#### (a) 사건 4종의 진단 품질 — 시뮬 5런 + 통제 프로브 34콜

| 런 | 사건 | 상태 | closed | sim_seconds | energy/closed | 채점 |
|---|---|---|---|---|---|---|
| C0 | 없음(대조군) | complete | 291/313 | 20.60 | 264 | — |
| K1 | fault ×4 | complete | 291/313 | 73.62 | 865 | **4/4** |
| K2 | severe battery ×4 | complete | 291/313 | 37.00 | 329 | **4/4** |
| O1 | mild battery ×3 + deep ×1 | complete | 291/313 | 23.55 | 280 | 1/1 (3건 unscored) |
| O2 | forbid zone ×1 | **stall** | **274/313** | 130.20 | 817 | 0건 (unscored) |

- **severe battery: 진단이 건전하다.** 8/8 `SwapBattery`, 근거문이 정확한 자원 논증을 한다 —
  *"the robot itself is not faulty … without consuming a spare robot."*
- **fault: 미검증.** 시뮬 4건 모두 `agent_pending>0` 이라 정답이 갈리는 조건이 안 나왔다.
  프로브로 만들면 문장만 줄 때 `pend=0`(a\*=NOOP)에서 **0/2**, 서술자를 주면 **3/5**,
  `pend=1`(a\*=Replace)에서 **1/3**. `a*` 는 `pend>0` 이라는 **이산 술어**인데 LLM 이 받는
  `work_at_risk` 는 연속 비율이라 0→1 계단이 `0.00→0.11` 로 뭉개진다.
- **mild battery: severity 를 못 가른다.** 3팔 메뉴에서 soc 0.25 와 0.45 가 **둘 다**
  `SwapBattery`. 근거 문장 자체가 일관되지 않는다(0.25 "흡수 가능", 0.45 "50% 아래라 교체").
- **zone: 3팔 메뉴를 주면 진단은 정확하다** — *"a spatial constraint rather than a fault or
  depletion issue"* 라며 로봇 팔을 거부한다. **같은 조건에서 surrogate 는 `SwapBattery` 를 고른다.**

#### (b) `[NOOP]`-only 메뉴가 근거문을 오염시킨다

메뉴가 하나뿐일 때의 근거문(실측):

- mild battery: *"**Since NOOP is the only valid action**, it is the default choice."*
- zone: *"Since NOOP is the only valid action, **it implies that the exclusion zone does not
  currently affect any active robot operations**."*

두 번째가 특히 나쁘다 — **메뉴 모양에서 없는 세계 사실을 역추론한다.** 그리고 그 판이
274/313 에서 멈췄다. 같은 결정에서 모델이 받은 프롬프트에는 이렇게 적혀 있었다:

```
  of which blocked       = 3      (구역이 사는 한 이 노드는 영영 못 닫는다)
  work frozen by those   = 32     (그 뒤에 걸려 얼어붙는 미완 노드)
  min_shift_to_clear_m   = 2.38   (모든 미완 목표를 구역 밖으로 빼는 최소 강체이동)
```

🔴 **닫힌 어휘의 무능이 실제 빌드 실패를 냈고, 라벨에는 거짓 근거가 붙은 NOOP 이 남았다.**
이것이 이 레인이 존재하는 이유다. → §4-2 의 `no_intervention` 이 이 오염을 측정한다.

#### (c) 개입은 공짜가 아니고, degraded-but-alive 상태가 실재한다

대조군 대비 사건당 추가 비용(실측):

| 팔 | sim_seconds/건 | energy/closed |
|---|---|---|
| `SwapBattery` | **+4.1 s** | 264 → 329 (+25%) |
| `Replace` | +13.3 s | 264 → 865 (+228%) |

레지스트리 cost(`SwapBattery 0.2` / `Replace 1.0`)는 **창고 예비 본체라는 자원만** 센다.
창고 왕복 시간과 `halt_build` 라인 정지는 그 숫자에 없다.

그리고 `BATTERY_DERATE`(기본 `hi=0.5, min_factor=0.35`)를 `run_demo.jl:596` 이 기본으로 켠다.
실측 `stall=true@0.15 derate=true`:

```
soc ≤ 0.15          속도배율 0.0        정지
0.15 < soc < 0.50   0.35 ~ 1.0 선형     느리지만 계속 일한다   ← mild battery 가 여기다
soc ≥ 0.50          1.0                무영향
```

🔴 `action_registry.json` 이 `Deprioritize` 를 지운 사유 — *"이 하니스의 배터리 사건은 '저하'가
아니라 '정지'(SoC 0)라 degraded-but-alive 상태가 없다"* — 는 **거짓이다.** derate 는
2026-08-05 에 들어왔고 삭제는 2026-08-20 이므로 **삭제 시점에 이미 틀린 근거였다.**
→ §5-3 P2 의 `reprice_agent` 가 이 구간을 겨냥한다.

#### (d) 🔴 부하 상한을 제약으로 쓰려던 인코딩은 반증됐다

`colored_8x8`, `assignment_mode=:greedy`(= `run_demo.jl` 과 같은 모드):

| 시나리오 | Xa 구조적 nonzero | 로봇당 frontier | 로봇당 후보 엣지 |
|---|---|---|---|
| t=0 (frozen=∅) | 423 | 1 | **0** |
| mid-build (closed=89/342) | 423 | 0–2 | **0** |
| `release_pending_assignments!` 직후 | **3197** | 0–1 | **55** |

두 가지가 각각 독립적으로 죽인다:

1. **수술 전에는 셀 것이 없다.** `:greedy` 는 MILP 이전에 이미 전부 배정한다 — frontier 가
   `outdeg=1` 이고 `n_eligible_succ=1` 이라 대안 자리가 없다.
2. **수술 후에도 중간이 없다.** 55개는 **같은 한 칸에 대한 55개의 대안**이다. 차수 제약
   `Xa*ones .<= n_eligible_successors`(=1)가 `Σ_v2 Xa[v,v2] ≤ 1` 을 강제하고, frontier 가
   로봇당 1개(14대 중 13대)이므로 `Σ Xa[a] ∈ {0,1}` — `k=0`=`ForbidAgent`, `k=1`=공허.

**귀결**: 부하 축은 **제약(`Σ Xa ≤ k`)에 없고 목적함수에만 있다.** 이것이 §5-3 P2 가
`deprioritize_agent!` + 재풀이 조합을 예측하는 근거다.

**이 스파이크가 덤으로 잡은 것 둘** (질문보다 크다):

- 🔴 **`ForbidAgent` 는 이 레인에서 MILP 제약을 0개 추가한다.** 수술이 선행하지 않으면
  컴파일러 루프가 돌고 아무것도 안 건다 = **조용한 no-op 인데 `Admit` 으로 통과한다.**
  `baselines.jl:173` 의 B3 오라클이 지금 그 경로에 있다(§10 위험 7).
- 🔴 **측정 레인은 재풀이를 한 번도 하지 않는다.** 4런 13결정 전부 `ran_milp = False`
  (`Replace`×4, `SwapBattery`×5, `NOOP`×4). 그러므로 목적함수 재가격은 **그냥 켜면 무효다** —
  `edge_cost_multiplier` 는 `formulate_milp` 이 `edge_costs` 를 만들 때만 읽히는데 그 함수가
  안 불린다. **삭제된 `DeprioritizeAgent` 가 "제안 338회 대비 선택 0회" 였던 이유가 이것이다** —
  골라도 정의상 아무 일도 일어나지 않았다.

#### (e) 🔴 `release_pending_assignments!` 는 되돌릴 수 없다

`fault_robot_and_reassign!` 은 수술 → `verify` 순서이고, `verify` 가 `Reject` 를 내면
`:rejected` 를 반환하는데 **떼어낸 엣지를 복구하는 코드가 없다**(`reassign.jl:388-394` —
2026-08-26 에 재확인했다). 호출부는 그 뒤 `engage_fallback!`(line stop)을 건다.
→ §5-3 P2 의 국소 undo 가 이 설계의 최대 엔지니어링 항목인 이유다.

#### (f) LLM 은 오늘 서술자를 받지 못한다

`llm_input` 전문이 `OBSERVATION:` 한 줄뿐이고 `MEASURED STATE` 블록이 없다. 같은 결정에서
surrogate 는 `OOD kind=fault, severity=1.0, spares_left=12, agents_pending=4, progress=0.19,
n_active=22` 를 받는다. **오늘 기록된 모든 LLM 결정은 문장 한 줄로 내린 것이고, surrogate 와의
비교는 입력이 다른 비교다.** → §9-1 의 첫 선행조건.

### 1-4. 승계하는 규약 둘

| 규약 | 내용 | 근거 |
|---|---|---|
| **오라클의 답을 프롬프트에 싣지 않는다** | Δ 유도 입력은 zone center·radius 까지. `min_shift_to_clear_m` 은 결정 레인 프롬프트에서 **뺀다** | 그 값은 `_find_min_translation` 의 **답**이다. 주면 합성이 아니라 받아쓰기가 되고, 삭제된 `RelocateBuild`(`spec_dsl.jl:342`)를 베끼게 된다. §6-2 의 `when_to_use` 분리와 같은 규약이다 |
| **실효성 위반은 거부한다** | 문법·접지·안전을 통과했어도 관측된 막힘에 안 닿으면 `Reject(:inert)` | 통과했는데 아무것도 안 고치는 것이 라벨로 쌓이면 (b) 의 거짓 NOOP 오염과 같아진다 |

⚠️ **피해 증거는 유지한다.** `of which blocked`·`work frozen by those` 는 오라클의 답이 아니라
**개입의 근거**다. 빼는 것은 `min_shift_to_clear_m` 하나뿐이고, 그 제거가 기존 zone 녹화의
프롬프트를 바꾼다 — §10 위험 3 이 그 대가를 받는다.

---

## 2. 이 설계가 딛는 실측

### 2-1. 오늘 DSPy 가 NL 로 내놓는 것 — 전부 넷 (실측)

`dspy_service.py:180-191` 의 `PickMacro` 가 라이브 시그니처의 전부다.
`steering_signature.py` 의 `SteerDecision`(u/w/confidence/rationale)은 `laneC7` 전용이고 이
레인에 배선돼 있지 않다.

| 필드 | 형태 | 다운스트림 |
|---|---|---|
| `reasoning` | 자유 NL "one sentence" | **파싱 안 함.** 결정 행에 `rationale` 로 기록만 |
| `macro` | 문자열 | `chosen not in valid` → NOOP 강제 + `coerced=True` (`:701-704`) |
| `ranking` | 콤마 구분 문자열 | split → valid 필터 → 빠진 팔 뒤에 채움 (`:705-709`) |
| `margin` | float | `float()` try/except → 실패 시 0.0 |

**귀결**: `macro`·`ranking` 은 이미 닫힌 어휘이고 어휘 밖 답은 이미 강제 교정된다. 오늘
tool 로 대체할 자유 NL 표면은 `reasoning` 하나뿐인데, 그것은 **남겨야 하는 해석성 로그**다.
즉 이 작업은 레트로핏이 아니라 **신설**이다.

### 2-2. 기존 두 행동이 실제로 고치는 것 (실측)

편집 표면이 셋으로 갈린다.

| 행동 | 편집 표면 | 실제로 하는 일 | 근거 |
|---|---|---|---|
| `Replace` | **schedule graph (`sched`)** | `replace_in_schedule!` 로 같은 node id 자리에 새 노드를 넣고, 배정 엣지를 `rem_edge!`/`add_edge!` 로 다시 건다. scene tree 는 로봇 기하를 **읽기만** 한다 | `replace_robot.jl:177` · `:1178-1180` · `:1231-1234` |
| `SwapBattery` | **물리 측면채널 (RVO)** | 창고 예비를 빌려 현장까지 주행시키고, 도착한 순간에 교체를 적용한다. `battery_courier.jl` 에 `add_node!`·`add_edge!`·`sched` 참조가 **0개** — **스케줄 노드가 생기지 않는다** | `battery_courier.jl:167` · `:214` |
| (없음) | **scene tree** | **지금 이것을 고치는 행동이 없다.** `restage_*` 계열이 적치 배치를 옮기지만 어느 매크로도 그 경로에 없다 | §2-3 C |

🔴 **귀결**: *"모든 tool = 그래프 편집"* 이라는 하나의 추상으로 묶을 수 없다. §7 의 `surface`
필드가 이 사실을 스키마에 새기고, ③④ 게이트가 `surface` 별로 갈린다.

⚠️ **이름 공간이 둘이다.** 채점 어휘의 매크로 이름은 `Replace`(`action_registry.json`)이고,
DSL 스키마의 클래스 이름은 `ReplaceAgent`(`schema.py:107`)다. 서로 다른 층의 이름이므로 tool
이름이 어느 쪽을 따르는지 명시해야 한다 — §4-2 는 **둘 다 따르지 않고** 기전을 따라
`swap_body` 로 짓는다.

(⚠️ courier 는 `run_demo.jl:605` 에서 `DEMO_BATTERY_COURIER` 기본 `"1"` 로 **켜져 있다**.
구조체 기본값은 `enabled=false` 지만 데모 경로는 켠다. §1-3 의 +4.1 sim s 는 이 물리 배송 비용이다.)

### 2-3. 원시 연산 인벤토리 (실측 — `src/respec/` 9,500줄 전수)

**A. 스케줄 그래프 편집**

| 연산 | 위치 | 하는 일 | 가역성 |
|---|---|---|---|
| `release_pending_assignments!` | `reassign.jl:121` | 배정 엣지를 떼어 후보를 연다 (Xa nonzero 423→3197) | 🔴 **비가역** |
| `reset_slot_to_invalid!` | `reassign.jl:81` | slot 하나를 미배정으로 | |
| `rethread_robot_ids!` | `reassign.jl:245` | sched 의 로봇 id 를 scene tree 와 재동기 | 보조 |
| unwedging 4종 | `replace_robot.jl:458·588·803·979` | 교착 해소 | 명목 레인이 이미 자동 호출 |

**B. 목적함수(가격)**

| `deprioritize_agent!(agent, factor)` | `essential_tg_coponents.jl:1379` | 배정 엣지 비용 배율, `clamp[1, 1e3]` | 🔴 **MILP 재풀이 없으면 무효** |
|---|---|---|---|

**C. 기하 / 적치**

| `restage_assembly!` | `restage_zone.jl:202` | 조립체 하나 국소 재적치 | |
|---|---|---|---|
| `restage_all_blocked!` | `restage_zone.jl:517` | 막힌 것 전부 — **미개시 조립체만**이라 빌드 중반엔 공집합 | |
| `translate_whole_build!` / `_apply_uniform_translation!` | `restage_zone.jl:777·616` | 빌드 전체 강체이동 | `verify_translate` 이미 있음 ✅ |

**D. 배터리 / 자원**

| `swap_battery!` | `replace_robot.jl:1419` | SoC 복구 + stall 게이트 해제 | |
|---|---|---|---|
| `dispatch_battery_courier!` | `battery_courier.jl:167` | 창고 예비를 빌려 물리 배송 | DAG 안 건드림 |
| `replace_robot!` | `replace_robot.jl:1212` | 본체 교체 | `pop_spare!` 소모 |
| `pop_spare!` | `ood_injection.jl:387` | 창고 본체 소모 | 🔴 희소자원 |

**E. MILP**: `compile_constraint!`(4종만) · `commit_respec!`

**측정 전용 (편집 연산 0개)**: `zone_corridor.jl` 전체가 순수 술어다 — `goal_engulfed`,
`free_space_status`, `_downstream_unfinished`. ④ 실효성 층의 재료가 여기 있다.

### 2-4. DSPy 3.3.0 의 native function calling — 네 조건 (실측, 실행 확인)

`dspy.Tool` · `dspy.ToolCalls` · `dspy.ReAct` · `dspy.CodeAct` 전부 존재한다. native FC 가
실제로 켜지려면 **넷이 동시에** 맞아야 한다 (`.venv/…/dspy/adapters/base.py:96-121`):

| # | 조건 | 근거 |
|---|---|---|
| 1 | `use_native_function_calling = True` | `:96` |
| 2 | 시그니처의 **InputField** 에 `list[dspy.Tool]` (또는 `dspy.Tool`) | `_get_tool_call_input_field_name` `:609` |
| 3 | 시그니처의 **OutputField** 에 `ToolCalls` | `_get_tool_call_output_field_name` `:619` |
| 4 | `lm.supports_function_calling` | `:110` — gpt-4o 는 **True** (이 세션에 실행 확인) |

**실패 양상이 조건에 따라 다르다** — 이 구분이 중요하다:

- 🔴 **1 이 `False`면 조용히 버린다.** `:96-98` 이 `lm_kwargs` 에서 `tools`·`tool_choice`·
  `parallel_tool_calls` 를 **`pop` 한다.** 예외도 경고도 없다. "tool 처럼 생긴 출력" 은 그대로
  나오지만 그건 텍스트 직렬화이고 **강제가 아니다.**
- ✅ **1 은 `True` 인데 2 가 없으면 `ValueError` 를 던진다** (`:103-108`). 즉 배선을 반쯤 하다
  마는 사고는 **시끄럽게 죽는다.**

🔴 **기본값 `False` 는 DSPy 라이브러리 안에 있다** (`Adapter.__init__`, `base.py:54`) —
**site-packages 를 고치지 않는다.** 재설치에 날아가고 이 레포 밖에서 돌리는 사람과 조용히
갈린다. 켜는 자리는 `dspy_service.py:334` 다 (§4-1).

🔴 **켜지면 두 필드가 시그니처에서 삭제된다** (`:120-121` `signature.delete(...)`). tool 목록과
`ToolCalls` 필드는 **프롬프트 텍스트에 안 들어가고** provider 의 `tools` 파라미터로만 간다.
→ `mechanism`(§6) 은 프롬프트 산문이 아니라 **각 `dspy.Tool` 안**으로 들어간다.

**`tools` 는 InputField 값이므로 요청마다 다른 리스트를 넘긴다** (`:111`
`tools = inputs[tool_call_input_field_name]`). 이것이 §4-3 의 접지 기전이다.

### 2-5. 서비스는 Julia 에게 되물을 수 없다 (실측)

`dspy_service.py:339-407` 의 `MacroRequest` 는 **한 방향 push payload** 이고, 서비스는 별도
uvicorn 프로세스다. "스케줄 DAG 어디서 stall 이 나는지 조회"하는 대화형 tool 은 **지금 지을 수
없다** — Julia 쪽 질의 엔드포인트 신설이 선행조건이다.

**귀결**: T1 은 **단일 턴**이어야 한다(§4-1). 다중 턴 ReAct 루프는 이 문서의 범위 밖이다.

---

## 3. 두 속도 루프 — 이 설계의 뼈대

| 속도 | 모듈 | 입력 | 출력 | 발화 조건 |
|---|---|---|---|---|
| **T1** 결정마다 | `SelectTool` (`dspy.Predict` + `ToolCalls`) | NL 관찰 + 서술자 6 + tool 레지스트리의 `mechanism` + valid 메뉴 | `reasoning` · tool call · `macro` · **`expressible: bool`** | 항상 |
| **T2** OOD | `SynthesizeTool` (`dspy.ChainOfThought`) | context = 물리 원리 + {state, goal, novelty, what to change, existing tools, **원시 인벤토리**} / question = OOD 속성 | **새 tool 정의** = name + params + `mechanism` + body + **`reach`** | `expressible = false` |

### 3-1. 🔴 알파벳은 두 층이고, T2 의 출력은 그 경계를 넘을 수 있다

```
T1 알파벳 = tool 레지스트리 (초기 3개)         LLM 이 **호출**한다
T2 알파벳 = 원시 연산 인벤토리 (§2-3 의 A~E)    LLM 이 **조합**한다. 직접 호출은 못 한다
```

즉 `translate_whole_build!` 는 T1 에서 **호출 불가**지만 T2 에서 **조합 가능**하다. 이것이
초기 개입 tool 이 둘뿐인데도 T2 가 공허하지 않은 이유다.

T2 의 출력에는 그 tool 이 **현재 알파벳 안에서 끝나는지**가 붙는다:

| `reach` | 뜻 | 처리 |
|---|---|---|
| `composed` | body 가 전부 기존 원시다 | 정규화·동치 판정(§5-2) → 레지스트리 등재 → 다음 결정부터 T1 이 호출한다 |
| `needs_primitive` | body 가 인벤토리에 **없는** 능력을 요구한다 | tool 정의와 `missing_primitive` 를 **기록만** 한다. 집행 불가. 사람이 그 원시를 구현하면 알파벳이 넓어지고 이 정의가 살아난다 |

🔴 **`needs_primitive` 는 실패가 아니라 이 레인의 주 산출물 중 하나다.** 그 목록이 곧
*"닫힌 알파벳이 어디서 무능했는가"* 의 기록이고, §1-3 의 274/313 stall 이 그 목록의 첫
항목이다 — 그때 라벨에 남은 것은 **거짓 근거가 붙은 NOOP** 이었다.

🔴 **어느 `reach` 든 LLM 은 코드를 생성하지 않는다.** `composed` 는 기존 원시의 호출
시퀀스이고, `needs_primitive` 는 명세다. 새 원시 연산은 Julia 물리·스케줄 불변식을 건드리므로
③④층이 *검증할 대상 자체*를 새로 정의해야 하는데, LLM 이 쓴 코드가 그 정의를 같이 쓰면
안전 스택이 자기 자신을 검사하는 순환이 된다.

### 3-2. 왜 두 속도인가

각 층의 **실패가 다음 층의 입력**이 되고, 그 실패 자체가 측정값이다:

- `expressible = false` 의 빈도 = **닫힌 tool 집합이 얼마나 자주 무능한가** → T2 를 발화시킨다
- `reach = needs_primitive` 의 빈도 = **닫힌 원시 알파벳이 얼마나 자주 무능한가** → 사람을 발화시킨다

⚠️ 이 두 신호는 `constraints_error` 같은 **형식 오류율이 아니다.** 이 둘이 재는 것은
**어휘의 무능**이다.

> 🔴 **2026-08-29 정정.** 여기 있던 *"형식은 ①②층이 디코드 시점에 이미 막는다(§7)"* 는
> **거짓이다** — 이 레인에 디코드 시점 집행은 없다(실측과 상세는 §8 안전 스택 표 **아래의
> 같은 날짜 정정**). 위 구분 자체는 그대로 유효하다: 두 신호가 형식 오류율이 아닌 이유는
> 형식이 **막히기 때문**이 아니라, 그 둘이 재는 것이 애초에 **어휘의 무능**이라 다른 것이기
> 때문이다.

---

## 4. T1 — tool 호출

### 4-1. 시그니처

```python
class SelectTool(dspy.Signature):
    """<SEED_DOC — 원리 하나만. 결정표를 산문으로 주지 않는다. §6 참조>"""
    state: str  = dspy.InputField(desc="decision-time observation of the event")
    tools: list[dspy.Tool] = dspy.InputField(desc="the recovery tools available here")
    valid_actions: str = dspy.InputField(desc="ONLY these macros are legal for this event")

    reasoning: str    = dspy.OutputField(desc="one sentence")
    expressible: bool = dspy.OutputField(
        desc="false if NO available tool can address what you observed")
    action: dspy.ToolCalls = dspy.OutputField()
    macro: str        = dspy.OutputField(desc="the single best macro, from valid_actions")
    ranking: str      = dspy.OutputField(desc="ALL legal macros ordered best-first")
    margin: float     = dspy.OutputField(desc="0..1 confidence gap between 1st and 2nd")
```

배선 — `dspy_service.py:334` 한 줄:

```python
dspy.configure(lm=lm)                                              # 지금
dspy.configure(lm=lm,                                              # 바꿀 것
               adapter=dspy.ChatAdapter(use_native_function_calling=True))
```

🔴 **`tools: list[dspy.Tool]` InputField 가 없으면 `ValueError` 로 죽는다** (§2-4 조건 2).
`ToolCalls` OutputField 만 두는 것은 배선이 아니다.

⚠️ `tools` 와 `action` 은 native FC 가 켜지면 시그니처에서 **삭제되므로**(§2-4) 프롬프트 텍스트에
안 나온다. 모델이 보는 tool 설명은 전부 `dspy.Tool` 객체 안에 있다 — §4-3 을 볼 것.

### 4-2. 초기 tool 레지스트리 — 셋

known failure event 가 둘(robot breakdown · severe battery depletion)이므로 개입 tool 도 둘이다.

| tool | params | 근거 원시 연산 | `surface` | 소모 자원 |
|---|---|---|---|---|
| `swap_body(agent)` | agent: 동적 enum | `replace_robot!` (+ `pop_spare!`) | `sched` | 🔴 창고 예비 본체 |
| `deliver_battery(agent)` | agent: 동적 enum | `dispatch_battery_courier!` → `swap_battery!` | `physical` | 없음 (시간·라인정지) |
| `no_intervention(reason)` | reason: str | 없음 | — | 없음 |

**`no_intervention` 을 tool 로 두는 이유**: §1-3 의 실측이 `[NOOP]`-only 메뉴가 근거문을
오염시킨다는 것이었다. NOOP 을 "메뉴에 하나 남은 항목" 이 아니라 **명시적으로 호출하는 행동**으로
만들면 그 역추론이 줄어드는지가 측정 가능해진다. ⚠️ 이것은 **가설이고 측정 대상**이다 —
줄어든다고 단정하지 않는다.

### 4-3. ② 접지 — 요청마다 `dspy.Tool` 을 다시 만든다

`tools` 는 InputField 값이므로 **요청마다 다른 객체를 넘기면 된다**(§2-4). 별도의 스키마 굽기
기전이 필요 없다. 실행으로 확인한 형태:

```python
def deliver_battery(agent: str):
    """Borrow a spare robot from the depot to carry a fresh battery to `agent`.
    Consumes no depot spare body; costs travel time and a line stop."""   # ← mechanism
    raise AssertionError("never called — Julia enacts")

dspy.Tool(deliver_battery, args={"agent": {
    "type": "string",
    "enum": live_agent_ids,                       # ← 이 요청의 payload 에 실린 id 만
    "description": "exact robot id, copied from the prompt"}})
```

산출되는 스키마(실행 확인):

```json
{"name": "deliver_battery", "description": "<docstring 전문>",
 "parameters": {"type": "object", "required": ["agent"],
   "properties": {"agent": {"type": "string",
                            "enum": ["ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)",
                                     "ConstructionBots.BotID{ConstructionBots.DeliveryBot}(11)"],
                            "description": "exact robot id, copied from the prompt"}}}}
```

> 🔴 **2026-08-28 정정.** 위의 **스키마 모양**은 `format_as_litellm_function_call()` 실행으로 확인한
> 것이 맞다. 그러나 `enum` 안의 **id 문자열은 예시였고 틀렸다** — 원래 `["RobotID(5)", "RobotID(11)"]`
> 이라고 적혀 있었다. 생산자는 그 문자열을 절대 내지 않는다. 실측:
> `string(ConstructionBots.RobotID(5))` → `"ConstructionBots.BotID{ConstructionBots.DeliveryBot}(5)"`
> (`RobotID` 는 `const RobotID = BotID{DeliveryBot}` 이고 `BotID`·`DeliveryBot` 이 export 되지 않아
> 언제나 정규화되어 찍힌다). `open_agent_descriptors` 의 `id` 가 바로 그 `string(rid)` 다
> (`llm_bridge.jl:143-150`). 위 블록은 실측 형식으로 고쳤다.

**모델이 보는 메뉴에 살아 있는 id 만 실린다.** 새 채널이 필요 없다 — payload 에 이미 있는
것만 쓴다. 다만 payload 에 `agents`(id·label) 필드를 더하는 것은 선행 작업이다(§9-1).

> 🔴 **2026-08-29 정정 (집행 주장).** 위 줄은 원래 **"환각 id 가 디코드 시점에 생성
> 불가능해진다"** 였다. **그 주장은 거짓이다** — 이 레인에 디코드 시점 강제는 없다. 실측(위
> 스키마 블록을 낸 것과 같은 호출): `format_as_litellm_function_call()` 의 `parameters` 키는
> `{properties, required, type}` 뿐이고 `strict` 도 `additionalProperties` 도 없다. dspy 3.3.0
> 의 `dspy.Tool` 에는 `strict` 필드 **자체가 없고**(`model_fields` =
> `arg_desc·arg_types·args·desc·func·has_kwargs·name`), `tool_choice` 는 이 레인 어디서도
> 보내지 않는다. 실제로 출하되는 것은 **"모델에게 살아 있는 id 만 보여준다"** 이고, 그건
> 보여준 것이지 강제한 것이 아니다. 비-strict `enum` 에 프로바이더가 문법 제약
> (grammar-constrained decoding)을 거는지는 **안 잰 프로바이더 동작**이라 라이브 호출 없이는
> 판정할 수 없다. → 환각 id 방어는 받는 쪽(줄리아 경계)에 계속 있어야 한다.

세 가지를 실측으로 확인했다:

- **스텁 함수로 충분하다.** native FC 경로는 tool 을 `format_as_litellm_function_call()` 로
  **포맷만** 하고 호출하지 않는다. 집행은 Julia 가 하므로 본체가 있으면 오히려 위험하다 —
  `raise` 로 막아 둔다.
- ⚠️ **`args` 를 주면 `arg_desc` 는 무시된다.** description 을 `args` 안에 직접 넣어야 한다.
  (이걸 모르면 파라미터 설명이 조용히 사라진다.)
- **함수의 docstring 이 tool 의 `description` 이 된다** = §6 의 `mechanism` 채널.

## 5. T2 — tool 합성

### 5-1. 시그니처

```python
class SynthesizeTool(dspy.Signature):
    """You design a NEW recovery tool for a disruption that no existing tool addresses.
    A tool is a NAME, a PARAMETER SCHEMA, a MECHANISM description, and a BODY.
    The BODY is a sequence of primitive operations. Prefer primitives from the inventory
    you are given. If the inventory cannot express what is needed, you may still define
    the tool -- but you must name the missing primitive precisely (what it edits, its
    preconditions, whether it can be undone) and set reach to "needs_primitive".
    You never write code: a body is a call sequence, a missing primitive is a spec."""
    context: str  = dspy.InputField(desc=
        "physical principles of this build (3-layer robot policy, scene tree, DAG design), "
        "current state, final goal, novel properties of the event, what should change, "
        "existing tools, and the PRIMITIVE INVENTORY with each primitive's mechanism")
    question: str = dspy.InputField(desc="the properties of the OOD failure event")

    tool_name: str = dspy.OutputField()
    params: str    = dspy.OutputField(desc="JSON schema of the parameters")
    mechanism: str = dspy.OutputField(desc=
        "exactly which graph surface this edits and how; what it consumes; preconditions; "
        "whether it can be undone. Be exhaustive -- a later decision reads only this.")
    body: str      = dspy.OutputField(desc=
        "ordered list of primitive calls, with arguments")
    reach: str     = dspy.OutputField(desc=
        '"composed" if every primitive in the body exists in the inventory; '
        '"needs_primitive" otherwise')
    missing_primitive: str = dspy.OutputField(desc=
        "if reach is needs_primitive: name, edit surface (sched|scene_tree|env_param|"
        "physical), params, preconditions, reversibility, what it consumes, and WHY no "
        "composition over the inventory can substitute for it. Empty otherwise.")
```

`reach` 가 이 출력의 갈림길이다 — §3-1 의 표가 두 값의 처리를 정한다. 🔴 **모델이 tool 정의를
못 내는 길은 없다.** "안 된다"만 말하고 끝내면 그 사건에서 무엇이 필요했는지가 기록에 안 남는다.
표현 불가는 `reach` 로 말하되 **정의는 끝까지 쓰게 한다.**

### 5-2. 합성 결과의 처리 — 중복은 차단이 아니라 측정

당신이 이 작업을 시작한 동기가 *"비슷한 action macro 를 만들 위험"* 이었다. tool 스키마는 그것을
**못 막는다** — `shift_build(dx=2.38)` 과 `shift_build(dx=2.40)` 은 둘 다 스키마를 완벽히 통과한다.
중복은 문법 문제가 아니라 **정체성 문제**이므로 서비스 쪽 정규화가 다룬다.

#### 5-2-1. ψ 는 이미 있다 (실측 — 2026-08-26 본체 확인) — 🔴 **2026-08-29 반증됨**

> 🔴 **2026-08-29 정정 (측정으로 반증).** 이 절의 제목과 결론 — *"합성 tool 의 `body` 가 곧 ψ
> 벡터가 된다 — 새로 지을 것이 없다"* — 은 **거짓이다.** 아래 본문은 `psi` 가 리스트를 받는다는
> 것까지는 맞지만, **그 리스트가 어떤 이름 공간의 이름이어야 하는지**를 틀렸다.
>
> 실측 (`env -u OPENAI_API_KEY .venv/bin/python`):
>
> ```
> psi(['ReplaceAgent'])                                     → a_cost 1.0 · a_reversible 0.0 · …
> psi(['release_pending_assignments','deprioritize_agent'])  → 10축 전부 0.0
> psi(['nonsense_operation_xyz'])                            → 10축 전부 0.0     ← 구분 불가
> psi(['release_pending_assignments']) == psi(['translate_whole_build'])  → True
> ```
>
> 원인은 `features_agnostic.py:473` 의 `v = [_PRIMITIVE_TABLE[n] for n in names if n in
> _PRIMITIVE_TABLE]` 과 그 다음 줄의 영벡터 폴백이다. `_PRIMITIVE_TABLE`(`:364`)이 들고 있는
> 것은 **DSL 원시 8종**(ReplaceAgent · ForbidZone · SwapBattery …)이지 §2-3 인벤토리 =
> `primitive_registry.json` 의 **운용 원시 19종**이 아니다. 모르는 이름은 조용히 걸러진다.
>
> **귀결 셋:** ① §5-2-2 의 ②(ψ 근접)가 구조적으로 무너진다 — 모든 합성 tool 이 서로 거리 0.
> ② §5-2-3 의 `|K|` 곡선이 의미를 잃는다. ③ `a_reversible = 0.0` 이 "쟀더니 비가역"이 아니라
> **"몰라서 0"** 인데, 아래 본문은 ③층이 그 축을 그대로 읽으면 된다고 적는다.
>
> 이 레포는 같은 결함의 **다른 가지**를 이미 고쳤다: `psi(int)` 경로는 2026-08-27 에
> "등록 안 된 id 를 조용히 NOOP 의 ψ 로 무너뜨리지 않는다"로 `KeyError` 를 던지게 됐다
> (`:463`). **리스트 경로는 그 수정을 안 받았다.**
>
> **→ 선행 작업**: (a) `primitive_registry.json` 의 각 원시에 ψ 10축 값을 싣고, (b) `psi` 의
> 리스트 경로가 모르는 이름에 **큰 소리로 죽게** 한다. 그 둘 없이 T2 를 켜면 중복 측정이
> 항진명제가 된다. Plan B 의 T6a.


`wm4spacecraft_manufacturing/core/features_agnostic.py:440` 의 `psi(action)` 은
**primitive 이름들의 리스트를 그대로 받는다.** 즉 합성 tool 의 `body` 가 곧 ψ 벡터가 된다 —
**새로 지을 것이 없다.**

집계 규칙(docstring 원문 확인):

```
cost                                        합   (두 번 개입한 것)
intervenes                                  max
soft                                        min  (하나라도 하드면 조합은 소프트가 아니다)
restores / relocates / spatial / consumes_spare  max
reversible                                  min  (AND — 하나라도 비가역이면 조합이 비가역)
scope                                       max
n_specs                                     len
```

`PSI_AXES`(`:391`)는 10축, `_PRIMITIVE_TABLE`(`:364`)이 원소 표다.
🔴 **`reversible` 이 AND 라는 것이 §5-3 P2 와 직접 맞물린다** — `release_pending_assignments!`
하나가 비가역이면 그것을 포함한 조합 전체가 비가역으로 표시된다. ③층이 그 축을 그대로 읽으면 된다.

#### 5-2-2. 두 단계 판정

```
canon(tool) = (sorted(body 의 primitive 이름), 대상 kind)      ← 파라미터는 안 들어간다
① 정확 동치 : canon 이 이미 본 것과 같은가
   ⟹ 새 행동이 아니다. 그 정규형의 카운터를 올리고 파라미터만 기록한다.
② ψ 근접   : min ‖psi(new) − psi(a)‖ over 등록 tool ∪ 관측 정규형
   ⟹ "새 축이 아니라 기존 tool 의 변형" 으로 접는다.
```

🔴 **파라미터는 정규형에 들어가지 않는다.** `shift_build` 는 `dx=2.38` 이든 `2.40` 이든 **같은
행동**이고, 그 차이는 파라미터 축에 있다. 이것이 중복 우려를 흡수하는 자리다.

> 🔴 **2026-08-29 추가 (Plan B / T6a 실측 — 아래 τ 조심성이 이제 하중을 받는다).**
> 운용 알파벳에 ψ 를 실은 뒤 재보니, 그 공간의 **변별력이 약하고 부분적으로 손튜닝**이다:
> ① `a_cost` 19개 중 실제 숫자에 닻이 있는 것은 **4개**뿐이고 나머지 15는 순서 판단이다.
> 그중 **둘(1.2·1.3)은 ψ 충돌을 깨려고 넣은 값**이다 — `restage_all_blocked` ·
> `apply_uniform_translation` · `translate_whole_build` 가 나머지 8축에서 동일하고 ψ 에
> "검사된 이동 vs 안 검사된 이동" 축이 없기 때문이다. `a_cost` 가 유일한 연속축이므로
> **표준화 통계 전체가 그 15개 판단 위에 선다.**
> ② `a_intervenes` 는 19개 전부 1.0 = 거리에 정보 0.
> ③ `a_spatial` 은 `recover_stalled_teams` 에서 틀린다(빌드 전체를 옮길 수 있는데 surface 가
> `physical` 이라 0.0).
> ④ **두 이름공간이 같은 물리적 행동에 대해 `a_reversible` 이 어긋난다**(DSL `SwapBattery`=1 vs
> 레지스트리 `swap_battery`=0 등). 원인은 "되돌릴 수 있다"의 두 뜻이 섞인 것 — *"undo 가
> 존재한다"* vs *"되돌릴 필요가 없을 만큼 무해하다"*. 이름은 서로소인데 **ψ 공간은 하나**라
> 같은 행동이 두 점으로 보일 수 있다.
>
> **→ 판정: ②(ψ 근접)는 거리 기록 전용이다. 어떤 임계값으로도 병합하지 않는다.**
> 아래 문단의 조심성이 옳았고, 이제 그것이 선택이 아니라 요구다.

⚠️ **임계값 τ 는 비워 둔다.** 첫 관측이 거리 분포를 준다. 그때까지 ②는 **거리만 기록하고 접지
않는다** — 지어낸 임계값으로 조용히 병합하면 그 사실이 기록에서 사라진다. 이 레포가 임계값을
먼저 정해 데인 자리가 여럿이다.

⚠️ ψ 축은 스케일이 제각각이다(`a_cost` 는 연속, `a_scope` 는 정수, 나머지는 0/1). **축별 표준화
없이 유클리드 거리를 쓰지 않는다.** 표준화 통계의 출처를 결정 행에 남긴다.

#### 5-2-3. 🔴 이것이 "어휘 폭발" 을 정량으로 만든다

```
|K|(t) = 시각 t 까지 관측된 서로 다른 canon 의 개수
```

- `|K|` 가 사건 수에 대해 **포화** ⟹ 폭발이 없다. 중복 우려가 파라미터화로 흡수된다는 실증.
- `|K|` 가 **선형 증가** ⟹ 우려가 옳았다. ②를 더 조여야 한다.
- 상한은 원시 인벤토리 크기 `n` 에 대해 구조적으로 `2ⁿ` 이다 — **유계 개방 어휘**이고,
  이름공간의 무한 팽창과 다르다.

이 곡선이 이 레인의 **1차 결과**다. `minted = false`(= LLM 이 이미 있는 좋은 행동을 스스로
재유도했다)는 그 곡선의 한 점이지 실패가 아니다.

### 5-3. 반증 가능한 예측 셋 — 이 설계의 시험지

이 설계가 옳다면 아래가 관측돼야 한다. **틀리면 설계를 고친다.**

| # | 사건 | 예측 | 근거 |
|---|---|---|---|
| **P1** | zone | T2 가 `translate_whole_build!` 를 조합해 `shift_build(dx, dy)` 를 합성한다. **③④층 통과.** | 원시가 존재하고 `verify_translate`(`verifier.jl:518`)가 경계·구역·`\|Δ\|≥_TB_MIN_DELTA` 를 이미 검사한다 |
| **P2** | mild battery | T2 가 `release_pending_assignments!` + `deprioritize_agent!` + 재풀이를 조합해 `reprice_agent(agent, factor)` 를 합성한다. **조합은 되지만 ③층이 비가역이라 검증 불가로 떨어진다.** | `release` 에 복구 코드가 없다(§1-3(e)). 이것이 국소 undo 엔지니어링이 필요하다는 **신호**이지 설계 실패가 아니다 |
| **P3** | staging area 배치 · SoC-payload 재배정 | `reach = needs_primitive`. tool 정의와 `missing_primitive` 는 나오지만 **집행 불가**로 기록된다 | §2-3 인벤토리에 대응 원시가 없다. 전자는 런타임이 아니라 시뮬 시작 전의 배치 문제이고, 후자는 그래프 편집이 아니라 환경 파라미터 변경이다 |

#### P1 이 딛는 기존 자산 (실측 — 2026-08-26 재확인)

`TranslateBuild` 축은 **새 기전을 안 만든다. 배선뿐이다.**

- DSL 타입 + 비유한 Δ 를 거부하는 생성자 — `spec_dsl.jl:363`
- pydantic 스키마 + `extra="forbid"` + 기본값 없음 — `schema.py:290`
- 게이트 `verify_translate` — `verifier.jl:518`, 전용 테스트 `test/respec_verify_translate.jl`.
  `|Δ| ≥ _TB_MIN_DELTA`(hollow admit 금지) · `translate_clears_zones` · `_within_workspace_bounds`
  셋을 이미 검사한다 = ③④층이 이 축에서는 **이미 닫혀 있다**
- 집행부 `_apply_uniform_translation!` — `restage_zone.jl:616`

⚠️ **zone 에 시간축으로 답하면 구조적으로 항상 inert 다.** 구역에는 수명이 없고
(`RESTRICTION_ZONES` 를 지우는 곳이 시뮬 루프에 없다), 막힘의 정의가 *"the node can never close
**while the zone lives**"* 이며, `VarRef` 는 `t0`/`tF` 만 허용한다(`:xa` 는 의도적으로 닫혀
있다 — `llm_bridge.jl:422`). **시간을 어떻게 재배치해도 영영 안 닫히는 노드는 안 닫힌다.**
그런 시도는 §8 의 ④층이 `Reject(:inert)` 로 **센다** — 막는 것이 아니라 세는 것이 값어치다.

#### P2 가 지어야 하는 것 — `reprice_agent` 계약

의미: *"이 로봇은 살아 있고 명령을 받을 수 있지만 느리다. 죽이지 말고, 평소보다 일을 덜 받게
하라."* 창고 예비 본체도 배터리 배송도 소모하지 않는다.

```
factor = 1        NOOP 과 동일 (편향 없음)
1 < factor < ∞    이 로봇의 배정 엣지가 비싸진다 → 솔버가 알아서 덜 준다   ← 신설분
factor → ∞        ForbidAgent 와 극한에서 같다
```

body 는 셋의 합성이고 **셋 다 이미 존재한다**:

```
① release_pending_assignments!(env, inv; faulted = agent)   reassign.jl:121   후보 엣지를 연다 (423→3197)
② deprioritize_agent!(agent, factor)                        essential_tg_coponents.jl:1379  clamp[1, 1e3]
③ MILP 재풀이                                                기존           이때 ②가 목적함수에 들어간다
```

②만 켜면 무효라는 것이 §1-3(d) 의 실측이다 — ③이 없으면 `edge_cost_multiplier` 가 아예 안
읽힌다. **삭제된 `DeprioritizeAgent` 를 그대로 되살리면 안 되는 이유가 이것이다.**

파라미터 계약: `factor` 는 **유한**해야 하고 **클램프 금지**(조용한 폴백 금지). `factor ≥ 1.0`
— `< 1` 은 그 로봇을 **우대**하는 것이라 문법 오류다. `factor == 1.0` 은 문법이 아니라
**④층이 `:inert` 로 거부**한다 (0 을 `TranslateBuild` 생성자가 아니라 집행부가 거부하는 것과
같은 규약 — `spec_dsl.jl:353-360`).

**P2 가 이 문서의 최대 엔지니어링 항목이다.** `reprice_agent` 를 검증 가능하게 만들려면
뗀 엣지 목록을 들고 있다가 되붙이는 **연산 국소 undo** 가 필요하다.

⚠️ 이것은 `.claude/CLAUDE.md:97` 이 금지한 `snapshot`/`restore!`/`fork` 와 **다른 물건이다** —
그 금지는 MCTS 전환 맥락의 **전역 월드 스냅샷**(트리 노드에서 모델을 재출발시키는 것)에 대한
것이고, 여기 필요한 것은 한 연산이 자기가 뗀 엣지만 되붙이는 국소 복구다. 🔴 **그래도 인접한
개념이므로, 구현 계획은 이 판정을 사용자에게 한 번 더 확인받고 시작한다.**

---

## 6. docstring 규약 — `mechanism` 과 `when_to_use` 를 가른다

### 6-1. 규칙

| 필드 | 모델이 보나 | 어디로 실려 가나 | 무엇을 적나 |
|---|---|---|---|
| `mechanism` | ✅ **최대한 상세하게** | T1: `dspy.Tool` 함수의 **docstring**(→ tool `description`) + `args[…]["description"]`. T2: context 의 원시 인벤토리 | 어느 그래프를 어떻게 고치는가 · 무슨 자원을 먹는가 · 전제조건 · 가역성 · 실측 비용 |
| `when_to_use` | ❌ **안 보인다** | 어디에도 안 실린다 | 적용성 판정. 사람·회귀 테스트·감사용 |

🔴 **T1 에서 `mechanism` 은 프롬프트 산문이 아니다.** native FC 가 켜지면 `tools` 필드가
시그니처에서 삭제되므로(§2-4), 모델이 읽는 tool 설명은 **오직 `dspy.Tool` 객체 안에만** 있다.
`primitive_registry.json` 의 `mechanism` 을 그 docstring 으로 렌더하는 것이 배선의 요점이다.

`mechanism` 을 상세하게 쓰는 것이 이 설계의 원칙이다. LLM 이 *"내가 DAG 를 어디까지 고칠 수
있나"* 를 알려면 반드시 필요하고, 지금 프롬프트에 **없는** 정보다.

### 6-2. 🔴 왜 `when_to_use` 를 빼는가 — 그리고 지금 이미 새고 있다

`dspy_service.py:155-165` 가 실측 근거와 함께 규칙을 못박아 뒀다: *"규칙을 문장으로 주면
측정되는 것은 추론이 아니라 **프롬프트 준수**다"* — 서술자가 `harm=0.02` 인데도 *"restage 하라"*
는 지시문을 따라 ForbidZone 을 고른 실측이 근거다.

**그런데 `action_registry.json` 의 `doc` 필드가 이미 그 선을 넘어 있다** (실측):

- NOOP: *"**Best when** the disruption is absorbed by slack and intervening would waste a scarce resource."*
- Replace: *"**Best on** a real fault, or on a depleted battery when no cheaper repair applies."*

그리고 이것이 `doc_lines()` 를 통해 `SEED_DOC` 에 그대로 렌더된다(`dspy_service.py:94-122`).
**즉 지금 LLM 은 각 팔의 정답 조건을 문장으로 받고 있다.** docstring 을 더 상세하게 만드는
방향으로 가면 이 오염이 같이 커진다.

**Task**: `action_registry.json` 의 `doc` 을 `mechanism` / `when_to_use` 로 쪼개고
`doc_lines()` 가 `mechanism` 만 렌더하게 한다. 상세함은 하나도 안 잃고 오염만 뺀다.

---

## 7. 레지스트리 스키마

### 7-1. `primitive_registry.json` — T2 가 조합하는 알파벳

```jsonc
{ "name": "translate_whole_build",
  "surface": "scene_tree",            // sched | scene_tree | env_param | physical
  "params": { "dx": {"type":"number"}, "dy": {"type":"number"} },
  "mechanism": "...최대한 상세...",     // ← 프롬프트에 실린다
  "when_to_use": "...",                // ← 실리지 않는다
  "reversible": true,
  "consumes": [],
  "preconditions": ["모든 미완 목표가 이동 후 구역 밖"],
  "gate": "verify_translate",          // ③④ 를 담당하는 Julia 함수 (없으면 null)
  "impl": "translate_whole_build!" }
```

`gate: null` 인 원시는 T2 가 조합할 수 있지만 ③층에서 **`deferred`** 로 떨어진다 — P2 가
정확히 이 경우다.

### 7-2. 🔴 `action_registry.json` 과 **섞지 않는다**

기존 레지스트리는 **채점 어휘**와 lockstep 이고 `emitted_key` 가 `Replace→(:fault,·)` /
`SwapBattery→(:battery,·)` 로 **사건 클래스를 인코딩**한다(`ood_truth.jl`). 여기에 원시 연산이나
합성 tool 을 섞으면 없는 사건 클래스가 채점기로 밀반입된다 — 선행 설계가 잡았던 것과
같은 결함이다.

세 파일이 각각 다른 것을 센다:

```
action_registry.json     채점 어휘 (vocab 도장 · MACRO_COST · emitted_key)     3항목, 고정
primitive_registry.json  T2 의 알파벳                                          §2-3 인벤토리
tool_registry.json       T1 의 알파벳 (합성분이 여기 쌓인다)                    초기 3항목, 자란다
```

---

## 8. 안전 스택 재배치

| 층 | 어디 | 무엇을 본다 | 실패 시 |
|---|---|---|---|
| ① 문법·타입 | DSPy tool schema, **native FC 켜짐** | tool 호출 형태 · 파라미터 타입·범위 | 🔴 **집행 없음** — 스키마를 **보여줄** 뿐이다(아래 정정) |
| ② 접지 | 요청별 **동적 enum** (§4-3) + Julia `grammar_ground_check` | 참조한 로봇/노드가 실재하는가 | 🔴 **집행 없음**(enum 은 보여줄 뿐). Julia 그물은 **실재하지만 이 레인엔 아직 안 닿는다**(아래 정정) |
| ③ 안전 | **각 tool 이 자기 전제조건을 검사하고 실패 시 원복** | 불변식 · MILP feasibility · 기하 경계 | `Reject(reason)` 또는 `deferred` |
| ④ 실효성 | `zone_corridor.jl` 순수 술어로 **편집 전후 재측정** | 관측된 막힘에 실제로 닿았는가 | `Reject(:inert)` |

> 🔴 **2026-08-29 정정 (집행 주장 — 이 표의 ①②열).** 위 두 칸은 원래 **"디코드 시점에
> 불가능"** 이었고, ② 는 거기에 **"Julia 그물은 두 번째 방어선"** 을 붙이고 있었다.
> **첫 부분은 거짓이고, 두 번째는 참이지만 이 레인에 아직 닿지 않는다.** 정직한 진술은
> **세 부분**이고 셋 다 실측이다:
>
> 1. **이 레인에 디코드 시점 불가능성은 없다.** `format_as_litellm_function_call()` 의
>    `parameters` 키는 `{properties, required, type}` 뿐 — `strict` 도 `additionalProperties`
>    도 없고, dspy 3.3.0 의 `dspy.Tool` 에는 `strict` 필드 **자체가 없다**(`model_fields` =
>    `arg_desc·arg_types·args·desc·func·has_kwargs·name`). `tool_choice` 도 이 레인은 안
>    보낸다. 모델은 살아 있는 id 만 담긴 스키마를 **본다** — 보여준 것이지 강제한 것이 아니다.
>    비-strict `enum` 에 프로바이더가 문법 제약을 거는지는 **안 잰 프로바이더 동작**이라
>    라이브 호출 없이는 판정할 수 없다. (①의 파라미터 타입·범위도 같다: 강제하는 키가 없다.)
> 2. **② 가 지목한 두 번째 방어선은 실재한다.** `grammar_ground_check` 는 `verifier.jl` 에
>    정의돼 있고 **`verify()` 안에서 실제로 불린다**(MILP 를 세우기 전, 2b GROUNDING 단계).
>    레포 전체 참조 7건. 아스피레이션이 아니다.
> 3. 🔴 **그런데 그 그물은 tool 레인을 아직 못 본다.** 그것은 `RespecProposal` 을 받고,
>    `tool_args` 를 거기까지 나르는 것이 **없다**. 실측: `tool_args`/`tool_called` 를 언급하는
>    `.jl` 파일이 레포에 **0개**이고, `policy_entry` 는 키 목록을 손으로 들고 있어
>    (`chosen·ranking·margin·rationale·scores·unsupported·label·available`) tool 레인 키를
>    **하나도 안 나른다**. 그 배선은 Plan B 의 경계 작업이다.
>
> → `tool_args` 를 신뢰할지 정하는 사람에게 필요한 것은 이 **쌍**이다: 그물은 있다,
> 그러나 아직 이 입력에 연결돼 있지 않다. 오늘 tool 호출의 접지를 보증하는 층은 **없다.**

**③이 제안 단위에서 연산 단위로 내려가는 것**이 이 설계의 핵심 변화다. 지금은 `verify()` 하나가
제안 전체를 보는데, 그걸 못 해서 선행 설계는 부하 축을 `deferred` 로만 쌓을 수밖에 없었다.

**④의 판정 규칙은 화이트리스트가 아니라 필요조건이다** (§1-4 승계): *"이 편집이
관측된 막힘에 닿을 수 있는가"* 만 본다. 막힘이 관측되지 않은 사건에서는 어떤 편집도 `:inert` 다.

### 8-1. ① 을 강제하면 잃는 측정 — 그리고 무엇으로 대체하나

선행 설계의 승격 게이트 첫 신호는 `constraints_error` 비율(=①층 실패율)이었다. tool schema 로
문법을 강제하면 그 비율은 정의상 0 이 된다. **대체 신호**:

- `expressible = false` 비율 — 닫힌 tool 집합의 무능
- `reach = needs_primitive` 비율 — 닫힌 원시 알파벳의 무능
- `minted = false` 비율 — 재발명 빈도 (§5-2)
- ③④ 거절 사유 분포 — 스키마는 통과했는데 **인자값**이 틀린 빈도

---

## 9. 선행조건 · 결정 행 · 승격 게이트

### 9-1. 선행조건 — 🟡 2026-08-29 재측정 (셋 중 둘은 끝났다)

> 🔴 **2026-08-29 정정.** 이 절의 제목은 *"🔴 선행조건 (승계 — 아직 안 고쳐졌다)"* 였고 세 항목
> 전부를 미완으로 서술했다. **그중 둘은 이미 끝났다** (`7226b629` 에서 실측). 낡은 서술을
> 그대로 두면 이미 고친 것을 다시 고치라는 지시가 된다 — 이 레포가 이 세션에만 세 번 데인
> 결함 종류다. 각 항목에 오늘의 판정과 근거 줄을 붙인다. 원래의 진단 서술은 지우지 않고
> 남긴다(그 진단이 무엇을 봤는지가 다음 사람에게 필요하다).

1. ✅ **서술자 채널 복구 — 끝났다.**
   - **당시 진단 (2026-08-26)**: `tools/monitor/policy.jl:389-394` 의 `if !have_det` 조기
     반환이 `descriptors` 키 **없이** Dict 를 돌려주고, 서술자를 계산하는
     `desc = event_descriptors_of(env, truth)` 는 **그 반환 뒤에** 있다. 즉 교정이 없으면
     서술자도 같이 죽는다. 교정 파일 경로의 디렉토리 자체가 없다.
     **기본 경로**: 교정 파일을 재생성하지 않고 그 조기 반환을 고친다 — `event_descriptors_of`
     는 교정값을 안 읽고 `event_descriptors`(`src/safety/novelty.jl:310`, 순수 함수)를 부를
     뿐이므로 항상 계산해 싣고, **라우팅 판정만** 비활성으로 둔다.
   - **2026-08-29 실측**: 그 기본 경로가 실제로 적용돼 있다. `route()` 안에서
     `desc = try event_descriptors_of(env, truth) catch …`(`policy.jl:506`)가 **먼저** 돌고,
     조기 반환은 그 아래에서 `have_det || return route_verdict(desc = desc, have_det = false,
     drives = false, …)`(`:511`)로 **서술자를 실은 채** 나간다. `event_descriptors_of` 정의는
     `:375`(spec 이 인용하던 `:346` 은 낡았다).
   - 🔴 **남는 관찰**: 라우팅(교정값이 필요)과 서술자 계산(필요 없음)이 **한 게이트에 묶여
     있었다는 것 자체**가 결함이었다는 판단은 유효하다. 지금은 풀려 있다.

2. ⚠️ **payload 확장 — 1/3 만 끝났다.** 원안: `agents`(id·label) · `zones`(center·radius) ·
   `nodes`(마일스톤만 ~9개). ②의 동적 enum 이 이것을 먹는다.
   - **2026-08-29 실측**: `agents` 만 실린다 — `policy.jl:572`
     `agents === nothing || (payload["agents"] = agents)`. `zones` 와 `nodes` 는 payload 에
     **없다**(`grep '"zones"\|"nodes"' tools/monitor/policy.jl` → 0건).
   - 🔴 **귀결**: `zones` 는 **기하 축의 유일한 입력**이므로, 이것이 없는 한 ForbidZone 사건에서
     T2 가 파라미터를 유도하는 것은 원리적으로 불가능하다. 아래 프롬프트 채널 표의
     `zones`·`nodes` 행은 **아직 미이행**이다.

3. ✅ **`action_registry.json` 의 `doc` 분리 (§6-2) — 끝났다.**
   - **2026-08-29 실측**: 매크로 0·1·2 전부 `mechanism` 과 `when_to_use` 를 **별도 필드**로
     갖는다(`vocab = v4-3arms`). 렌더 쪽도 갈라져 있다 —
     `wm4spacecraft_manufacturing/core/action_registry.py:194` 가 `when_to_use` 를 **절대
     렌더하지 않는다**고 명시하고, `wm4spacecraft_manufacturing/core/test_registry_doc_split.py`
     가 그 분리를 지킨다(`when_to_use` 전문을 20자 슬라이딩 윈도우로 tool description 전체와
     대조 — 블록리스트가 아니라 구조적 검사).
   - ⚠️ §6-2 의 *"그리고 지금 이미 새고 있다"* 는 **그 시점의 관찰**이고, 오늘은 위 검사가
     막고 있다. §6-2 본문을 읽을 때 이 항목을 함께 볼 것.

프롬프트 채널의 최종 형태 (승계 + 이 문서):

| 채널 | 변경 | 근거 | 2026-08-29 실측 |
|---|---|---|---|
| 서술자 6개 | **복구** | §1-3(f). 없으면 파라미터 유도가 불가능하다 | ✅ `policy.jl:506` 계산 · `:548` 적재 |
| `zones` (center·radius·covers) | **추가** | 기하 축의 유일한 입력 | ❌ payload 에 없다 |
| `agents` (id·label) | **추가** | ② 동적 enum 의 접지원 | ✅ `policy.jl:572` |
| `nodes` (마일스톤 ≈9개) | **추가** | 전체 미완 노드(~255)가 아니라 마일스톤만 | ❌ payload 에 없다 |
| tool `mechanism` | **추가** | §6-1 | ⚠️ 실려 있다(`tool_registry.py` docstring = tool description) 그러나 **레지스트리에서 읽지 않고 손으로 복사**했다 — 두 벌이 갈라질 수 있다 |
| `min_shift_to_clear_m` | **제거** | §1-4 규약 | ❌ **아직 실린다** — `dspy_service.py:800` 이 `_GEOM_COVERAGE` 에 들고 있고 `_geometry_block()`(`:829-848`)이 프롬프트로 렌더한다 |
| 피해 증거 (`of which blocked`, `work frozen by those`) | **유지** | 오라클의 답이 아니라 개입의 근거 | ✅ `dspy_service.py:812`·`:816` (`_GEOM_BLOCKAGE`) |
| 레지스트리 `when_to_use` | **제거** | §6-2 | ✅ `action_registry.py:194` 가 렌더 안 함 · `core/test_registry_doc_split.py` 가 지킴 |

> 🔴 **2026-08-29 추가 실측 — `min_shift_to_clear_m` 제거는 미이행이다.** 이 행은 §9-1 의 세
> 선행조건에 **안 들어 있어서** 지금까지 아무 작업 항목에도 안 잡혔다. 그런데 §1-4 가 이것을
> 빼라고 한 이유(= 오라클의 답을 프롬프트에 실으면 재는 것이 추론이 아니라 프롬프트 준수가
> 된다)는 T2 가 기하 축에서 파라미터를 유도하는 순간 **더 강해진다** — 합성기에게 정답 이동량을
> 그대로 보여주면 §5-3 의 P-예측이 전부 무의미해진다. **B3 착수 전에 반드시 처리한다.**

### 9-2. 결정 행에 기록할 것

```julia
"reasoning"       => "..."      # 해석성 로그 — 파싱하지 않는다, 지우지도 않는다
"expressible"     => true
"tool_called"     => "deliver_battery"
"tool_args"       => Dict(...)
"tool_minted"     => false      # 이 결정이 T2 를 발화시켰다면 그 결과
"verify"          => "admit"    # "admit" | "reject:<reason>" | "deferred:<reason>"
"efficacy"        => "resolves" # "resolves" | "inert" | "deferred"
"macro"           => "SwapBattery"   # 채점 어휘 — tool 과 별개로 계속 기록
"macro_tool_agree" => true      # macro 와 tool 이 같은 방향인가 (§4-1 미결 — 재기만 한다)
"emitted_keys"    => [...]      # CB.emitted_key 로 **Julia 가** 계산
```

> 🔴 **2026-08-29 정정 (Plan B / T3 검증).** 위 `verify` 주석은 세 번째 상태를 맨 `"deferred"`
> 로 적고 있었는데, 구현은 `"deferred:<reason>"` 를 낸다. **이 문서만 읽고 쓴 소비자는
> `verify == "deferred"` 로 비교해서 deferred 행을 하나도 못 잡는다.** 접두사 비교가 규약이다:
> `startswith(verify, "deferred")`. `reject` 도 같다.

🔴 `deferred` 를 `unknown` 이나 `agree` 로 뭉개지 않는다. **"못 쟀다"와 "재서 통과했다"는 다른
사건**이고, 이 레포는 그 둘을 섞어 여러 번 데였다.

### 9-3. 승격 게이트

🔴 **이 레인이 겨냥하는 두 사건은 채점기가 채점하지 않는다.** `reference_policy` 가
mild battery(`soc > 0.2`)와 zone 을 **unscored** 로 둔다(승계, 2026-08-25 어휘 결정 이후).
따라서 승격 게이트는 **정답 일치율을 쓸 수 없고**, 아래 신호와 P1·P2·P3 의 성패로만 판정한다.
채점 근거 확보는 이 문서가 안 바꾼다(§11).

임계값은 **측정 후에 정한다** — 지금 숫자를 지어내지 않는다. 읽을 것은 §8-1 의 네 신호와
P1·P2·P3 의 성패다. **`reprice_agent` 의 국소 undo 가 지어졌는가**가 부하 축 집행 전환의
하드 선행조건이다.

---

## 10. 공개된 위험

1. **T2 가 합성한 tool 이 기존 것과 사실상 동치일 수 있다.** 이것이 사용자가 이 작업을 시작한
   원래 동기이고, §5-2 가 차단이 아니라 **측정**으로 다룬다. 정규화 격자를 잘못 고르면
   중복이 안 잡히거나 서로 다른 행동이 합쳐진다 — 격자는 측정 후 조정한다.
2. **D-11 폐기의 대가.** 합성과 집행이 한 레인이 되므로, O2 런의 274/313 을 STEP 2 기준선으로
   보존한다는 근거가 사라진다. 새 기준선을 이 설계로 다시 잡아야 한다.
3. **프롬프트가 세 군데 바뀐다** (§6-2 doc 분리 · §9-1 payload 확장 · tool schema 도입).
   **기존 dspy 녹화와의 직접 비교가 끊긴다.** 선행 설계가 이미 그 대가를 받아들였다.
4. **native FC 를 안 켠 채로 "켠 줄 아는" 상태** (§2-4). `use_native_function_calling=False`
   면 `base.py:96-98` 이 `tools` 를 **조용히 `pop`** 하고, 출력은 여전히 tool 처럼 생겼다.
   반쯤 배선한 사고(§2-4 조건 2 누락)는 `ValueError` 로 시끄럽게 죽으므로 위험하지 않다.
   **위험한 것은 플래그를 안 켠 경우 하나뿐이다.** 배선 테스트가 *"`lm_kwargs['tools']` 가
   실제로 남아 provider 로 갔는가"* 를 직접 단언해야 한다 — 출력 모양으로는 못 잡는다.
5. **국소 undo 가 금지 조항과 인접하다** (§5-3). 구현 전 확인 필요.
6. **서술자 채널 복구가 여전히 최대 미지수다** (§9-1). 없으면 T2 의 파라미터 유도가 불가능하다.
7. **`ForbidAgent` 의 조용한 no-op 은 이 작업이 안 고친다.** `baselines.jl:173` 의 B3 오라클이
   지금 그 경로에 있고, B3 를 쓰는 비교는 그만큼 오염돼 있다. 별개 작업.
8. **T1 이 단일 턴이라 "DAG 어디가 막혔나"를 LLM 이 되물을 수 없다** (§2-5). 프롬프트가 미리
   실어 보내는 것만 본다. 대화형 조회는 Julia 질의 엔드포인트가 생긴 뒤의 별도 설계다.

---

## 11. 이 문서가 안 하는 것 (범위 선언)

- **다중 턴 ReAct 루프.** §2-5 가 채널 부재를 실측했고, 결정당 LLM 호출이 1→N 이 되면
  기록 행·비용·시드 재현성이 전부 재검토 대상이 된다.
- **LLM 이 코드를 생성하는 경로** (CodeAct). §3-1.
- **`action_registry.json` 어휘 확장.** 합성 tool 은 레지스트리 항목이 아니다 — id 도 cost 도
  없다. 채점 어휘 승격은 관측이 쌓인 뒤의 별도 결정이다.
- **`:xa` 채널 개방.** §1-3(d) 가 그 축의 인코딩을 반증했고, `llm_bridge.jl:422` 의 함정
  서술도 그대로 유효하다.
- **`ForbidAgent` no-op 수정** (위험 7).
- **staging area 배치 레인.** P3 가 `needs_primitive` 로 보내는 것이고, 그것은 런타임 결정 레인이 아니라
  시뮬 시작 전의 별도 레인이다.
- **mild battery·zone 의 채점 근거 확보.** `reference_policy` 가 그 구간을 unscored 로 두는
  것은 이 문서가 안 바꾼다(§9-3). 이 레인은 **행동 격차**를 메우지 채점 격차를 메우지 않는다.
- **MCTS/SMDP 레인.** 이 문서는 결정 레인만 다룬다.
