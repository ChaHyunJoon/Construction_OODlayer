# ConstructionBots.jl

Behavioral guidelines are inherited from `venv/.claude/CLAUDE.md` (auto-loaded). This file is project context only.

## 🔀 2026-08-21 — 상태 7필드 · 행동공간 5종 · 행동 신설(L2) — **현행 세대**

지도교수 피드백 셋(상태 축소 가정 · OOD 사건 정의 · replay buffer)을 반영한 개정.
🔴 **이 절 아래의 SMDP 서술 중 "19필드" · "26필드" · `s = (G, Geo, Fleet, Courier)` 는 전부
구세대다.** 그 문장들을 지우지 않은 것은 이 파일의 규약 때문이고, 참인 것은 이 절이다.

**읽는 순서:**
1. `docs/superpowers/plans/2026-08-21-reduced-state-smdp-action-synthesis.md` — **계획서 A**(실행할 것, Phase 1R~5)
2. `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md` — 설계. 계획이 여기 대고 논증한다
3. `docs/superpowers/reports/2026-08-20-phase1-completion.md` — Phase 0~1 은 **이미 집행됐다**
계획서 B(`2026-08-21-ood-layer-replay-buffer.md`, OOD + replay buffer)는 **A 의 Phase 4 가 끝난 뒤**에 연다 — 그 전엔 `L_prim` 이 없어 전부 L1 을 재게 된다.
⛔ `2026-08-20-sojourn-generative-smdp.md` 는 **Phase 2 이후 대체됐다**(배너 있음).

### 상태 — 26 → **7 필드** (로봇당 8 → 2)

**판정 기준**: 이미 하드코딩된 하위 정책의 관할이거나, `s` 안의 다른 값에서 다시 만들 수 있거나,
상수면 상태가 아니다.

```
s = (G, Geo, Fleet, Prog)
G      edges · binding                    행동이 편집하는 그래프
Geo    poses(**조립체**) · zones(기하까지)  RelocateBuild 의 흔적 + 경로 분할
Fleet  로봇당: soc · usage_s               λ 와 에너지가 읽는 전부
Prog   closed                             build 가 어디까지 됐나
```

- **`CourierRec` 블록은 삭제됐다.** 배송은 `env.BATTERY_DELIVERIES[]` 에 살아 있고 경량 레인
  함수가 전부 `(s, env)` 를 받으므로 동역학은 온전하다. ⚠️ 대가: `SwapBattery` 는 결정 직후
  `s` 에 흔적을 안 남긴다 → **트리 노드를 `state_hash` 로 병합하는 순간 NOOP 자식과 합쳐진다**(트립와이어).
- 🔴 **`s.fleet` 의 멤버십 = "지금 위험에 노출된 로봇".** `simstate_of` 가 `_hz_excluded()` 를
  **직접 부른다.** `role`·`health` 를 되살리지 말 것 — 그 둘로 유도하려던 것이 거짓임을
  완료 보고서 §4-2 가 반례 둘로 실측했고, 이 인코딩이 그 이슈를 소멸시켰다.
- `usage_s` 를 빼지 말 것: `_hz_ensure!`(`hazard.jl:296`)가 새 로봇에 `0.0` 을 찍으므로
  **이 필드가 `Replace` 팔의 유일한 흔적**이다. 빼면 λ 관점에서 Replace 와 NOOP 이 같아진다.

### 행동공간 — emit 가능 **5종**. `a = proposal.constraints`

```
ReplaceAgent · SwapBattery                        known 대응
TranslateBuild · LinearConstraint · Disjunction   L_prim (행동 신설)
```

- **`a` 는 `constraints` 뿐이다.** `rationale`·`source_event` 는 감사 로그이고 `verify()` 는
  전이함수의 문이다(거부 = NOOP 과 같은 전이). 버퍼·트리는 `constraints` 로 색인한다.
- 🔴 **뺀 다섯**(`ForbidZone` · `ReformTeam` · `ForbidAgent` · `ForbidWindow` · `DeprioritizeAgent`)은
  **행동공간에서만** 빠진다 — `schema.py` union + `llm_bridge.jl` 파서. **Julia 타입은 남는다**:
  `ForbidAgent` 를 `navigator/baselines.jl:173·192·201` 과 `respec/reassign.jl` 이 내부적으로 만든다.
- 신설의 사다리: **L1** 파라미터 grounding(됨) · **L2** 제약/기전 신설(이 계획이 연다) ·
  **L3** 기전 자체 신설(코드 생성 없이는 불가 — 범위 선언).

### 사용자 결정 D-5 ~ D-10 (2026-08-20~21)

| # | 결정 | 귀결 |
|---|---|---|
| D-5 | `drain_sigma = 0.0` | ε_r 개체차를 **동역학에서** 없앤다. 그냥 상태에서 빼면 잠재변수 혼합이라 Markov 가 깨진다 |
| D-6 | rate boundary 를 경과시간 없이 낸다 | `get_t0` 가 런 내내 0.0 이라 옛 식은 활성 15/15 가 `rem ≤ 0` 이었다(실측). 새 식은 **상한 근사**이고 N-G1 이 판정한다 |
| D-7 | 창고 예비는 충분하다 | 메뉴를 안 좁힌다. 가정 위반은 `pop_spare!` 자리에서 **에러**로 드러낸다 |
| D-8 | 행동 신설을 L2 까지 허용 | 제약 문법 + 파라미터 자유 원시연산을 LLM 에 노출 + 재사용 우선 규칙 |
| D-9 | 행동공간 emit 가능 5종 | 위 |
| D-10 | **심의시간 = 0 으로 가정** | 🔴 `verify` 시행풀이 + LLM 왕복이 τ 에 없다. **escalation률을 비용 대비 이득으로 읽지 말 것** — 비용 항이 모델에 없고 conformal 의 α 가 그 자리를 대신한다 |

### OOD — `zone` 이 test-only 다

known 학습 = `fault`·`battery`·`fault_battery` / 테스트 전용 = `zone`·`fault_zone`·`battery_zone`·`all`.
known 세계에서 빠지는 것은 매크로가 아니라 **기전 전체**(`TranslateBuild` 원시연산도 안 쓴다).
탐지는 임계값이 아니라 **split conformal 구간 겹침**(top-1 vs top-2), 손잡이는 α 하나.
도장 축 **`train_kinds`** 는 2026-08-25 에 **배선됐다** — `gen_oracle_dataset.jl:1949` 이 행마다
찍고, 현행 라벨 33행은 전부 `battery,fault` 다(실측). ⚠️ **읽는 코드는 아직 0개다**(게이트를
일부러 안 만들었다, `:1138`) — zone 을 뺀 라벨셋과 안 뺀 라벨셋은 `objective_hash`·`vocab`·
`dynamics` 가 **셋 다 같으므로**, 이 도장이 write-only 인 동안 그 둘을 기계가 못 가른다.

### 🔴 이 세션이 코드에서 실측한 것 (전부 조용히 새는 종류)

| 발견 | 어디 |
|---|---|
| `maybe_respecify!` 는 **first-match-wins** — 다섯 분기가 각각 `return` 해서 제약 벡터가 하나로 무너진다 | `replan.jl:452·529·679·798·898` |
| `verify()` 는 **kind 무관**(문법·과거불가침·MILP feasibility·invariant). `verify_forbid_*` 는 **없다** — 제약 신설의 안전장치가 이미 있다 | `verifier.jl:83-125` |
| `RelocateBuild` 는 action 이 아니라 **solver** — `_find_min_translation` 이 Δ 를 스스로 찾는다. 진짜 원시연산은 `_apply_uniform_translation!(env, Δ)` | `restage_zone.jl:768-779` |
| `cell` 위험은 **`battery` kind 사건을 낸다**(`battery_action` 호출) — 별도 팔이 필요 없다 | `hazard.jl:583` |
| `active_set` 활성화 규칙 = **순수 DAG frontier**("모든 선행이 closed") | `essential_tg_coponents.jl:1921-1932` |
| `WEDGE_EDGES` push 가 `add_edge!` 와 **짝**이라 `wedge_edges ⊆ edges` | `replace_robot.jl:297·424·1035` |
| 🔴 라벨 레인이 `DS_DRAIN_SIGMA` 기본값 `"0.15"` 를 **독립적으로** 들고 있다 — `hazard.jl` 만 고치면 두 레인의 세계가 갈린다 | `gen_oracle_dataset.jl:150` |
| `DS_EP_KINDS` 기본값에 **zone 이 들어 있다**(`fault,battery,zoneblk`) | `gen_oracle_dataset.jl:1086` |
| 🔴 **`src/` 안의 Julia 코드에 `ActionRegistry` 소비처가 0개다** — 어휘를 쓰려면 로드부터 배선해야 한다 | `grep -rn ActionRegistry src/` |
| `src/smdp/` 에는 5파일뿐 — `rates.jl`·`tplan.jl`·`sojourn.jl`·`generative.jl` 은 **아직 없다**(계획서 A 가 만든다) | `ls src/smdp/` |

---

## 🔀 2026-08-20 — 아키텍처 전환: 생성 시뮬레이터 + MCTS

`P` 도 `Υ` 도 적합하지 않는다. MCTS 가 생성 환경에서 `(s,a) → (s′,r,τ)` 를 샘플링한다
(Al-Husseini·Wray·Kochenderfer 2024 MEDEVAC SMDP 구조). 그래서 `s` 의 역할이 "모델을
재출발시키는 것" 에서 **"트리 노드를 색인하는 것"** 으로 바뀌고 **손실 압축이 허용된다.**

⛔ **짓지 않기로 한 것**: `snapshot`/`restore!`/`fork` · 왕복 게이트 G1 · Markov 게이트 G-M ·
해시 기반 rollout dedup · dp backward induction 레인.

🔴 **`state_hash` 로 상태를 병합·dedup 하지 말 것.** 생산 소비처는 0개다. 늘리기 전에
`src/smdp/simstate.jl` 의 `state_hash` docstring 을 읽을 것 — 옛 계약은 `s` 가 충분통계라는
전제 위에 있었고 그 전제가 없어졌다. ⚠️ 병합을 도입하면 `SwapBattery` 자식이 `NOOP` 자식과
합쳐진다(맨 위 §2026-08-21 트립와이어).

⚠️ 분산 기전은 CRN 이 아니라 **root parallelization** 이다. 다만 재컴파일 잡음(아래 Gotchas)이
트리마다 다른 세계를 만들므로 **잡음 바닥을 재기 전까지 트리는 한 디렉토리에서 굴린다.**

상세: `git show 0ed0c4be:.claude/CLAUDE.md` 의 같은 절, 그리고
`docs/superpowers/specs/2026-08-20-tamp-nominal-smdp-failure-design.md` §11.

## ✅ 2026-08-24 — 행동공간 **3팔** `v4-3arms` — **현행 어휘**

**어휘 도장 `v4-3arms`** (`wm4spacecraft_manufacturing/core/action_registry.json` 이 단일
진실원, 리터럴 복붙 금지): `0 NOOP(0.0)` · `1 Replace(1.0)` · `2 SwapBattery(0.2)`.
kinds 는 **둘**: `fault` · `battery`. `RETIRED` 는 비어 있다.
[역사] 2026-08-20 의 `v3-4arms`(4팔, `2 RelocateBuild(1.5)`, kinds 셋)에서 `Deprioritize`
(제안 338 · **선택 0회**)와 `ReformTeam`(대응 사건이 실패 사건이 아니었다)이 빠졌고,
2026-08-24 축소가 `RelocateBuild` 를 빼면서 zone 을 결정 레인에서 내리고 `SwapBattery` 를
3 → 2 로 재번호했다.

🔴 **재번호의 대가: 어휘 도장이 유일한 방어선이다.** 예전엔 구 id 가 영구 결번이라 구세대 행이
조회 실패로 죽었는데, 이제 `v3-4arms` 의 macro 2(RelocateBuild) 행이 새 어휘의 유효 id
(SwapBattery)로 **조용히 읽힌다.** 🔴 **`require_vocab` 소비처가 0개라던 서술은 낡았다** —
축 C(2026-08-24~25)가 배선했다. 실측:
**생산 3곳** `smdp/gate_ng2.py:112`(`require_vocab`) · `surrogate/eval_surrogate_v2.py:139` ·
`surrogate/export_surrogate.py:143`(둘 다 `require_vocab_stamps`).
**시험 4파일** `smdp/test_stamps.py` · `test/smdp_stamp_smoke.jl`(직접 호출) ·
`surrogate/test_load_rows_vocab.py` · `surrogate/test_export_surrogate_vocab.py`
(`load_rows`/`_load_labels` 경유).
🔴 **`require_vocab_stamps` 에는 Julia 짝이 없다**(`grep -rn require_vocab_stamps --include='*.jl'`
= 0건). Julia 의 `require_vocab`(`oracle/action_registry.jl:128`)도 **생산 호출자가 0개**이고
`test/smdp_stamp_smoke.jl` 만 부른다 → **라벨 생성 레인(Julia)에는 행-집합 도장 검사가 없다.**
시험만 지키는 도장은 이 레포가 반복해 밟은 `train_kinds` 실패 모드와 같은 자리다.
`filter_labels` 는 세대 판정 도구가 아니다(어휘 밖 id 만 걷어낸다).

🔴 **교착 복구 경로가 재배선됐다.** 네 unwedging 루틴(`reform_stuck_teams!` ·
`recover_stalled_teams!` · `force_advance_stuck_carrier!` · `resolve_schedule_wedge!`)은
명목 레인에 없었고 `ReformTeam` 매크로 dispatch 안에서만 불렸다 — 팔을 없애면 **복구가 통째로
도달 불가**가 된다. 그래서 `maybe_unwedge_nominal!(env, no_progress)`(`respec/ood_injection.jl`)
를 만들어 두 시뮬 루프에 배선했다. 같은 트리거(무진전 modulo `UNWEDGE_INTERVAL`, 기본 2000),
**결정 epoch 를 안 만드는 것**이 유일한 차이. 성공 시 `reset_cache_resume!` 까지 부른다
(빼먹으면 그래프는 바뀌었는데 캐시가 옛 프론티어를 들고 있어 복구가 무효 — 에러는 안 난다).

## 🧹 2026-08-18 — 기계 검사를 걷어냈다

`wm4spacecraft_manufacturing/` 의 코드 123개 중 **87개를 지웠다**(검사기·게이트·중복 러너·고아·
Windows 전용). 판정 기준은 "결과를 만드는가, 보기만 하는가". 전부 복구된다:
`git show 8e005842:wm4spacecraft_manufacturing/<path>`.

**이제 기계로 감시되지 않는 것 — 사람이 봐야 한다:**
1. **`objective_hash` 세대 계약** — 산출물 해시가 현행 `objective.json` 해시와 같은가
   (구 `audit_objective.py`)
2. **행동 어휘 6-소비처 일치** (구 `audit_action_vocab.py`). 어휘 누락은 에러 없이 **성능으로만**
   샌다 — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을 갈랐다
3. **dp 비용 분해 충실성** · Bellman·칸키 동치 (구 `dp_oracle/test_*.py`)
4. **발행 문서의 표본수 문구 회귀** (구 `test_report_sample_size.py`)
5. **스윕 사전조건 게이트**(`gate_prereq.sh`) — 🔴 **DSPy `/health` 확인이 사라졌다.** 서비스가
   죽어 있으면 dspy·surrogate 레인이 조용히 canonical 로 내려앉은 채 스윕이 다 돈다.
   스윕 전 `DSPY_URL` 손확인 + 스윕 후 `decisions[].enacted` 레인 히스토그램으로 사후 확인할 것

## 🔴 세대 도장 — 규칙과 현행값

**`wm4spacecraft_manufacturing/core/objective.json` 이 목적함수 J 의 단일 진실원**이고
`objective_hash()` 가 그 파일에서 유도된다. 파일에 `generation` 필드가 있고 **해시에 들어간다.**

> **규칙: 스칼라가 하나도 안 바뀌어도 목적함수의 유효 의미가 바뀌면(플래너 재배선 포함) 반드시
> 올린다.** 그리고 🔴 **해시를 되돌리려고 `generation` 을 되돌리지 말 것** — 되돌리면 실제로
> 갈린 축을 해시가 부정한다. **옛 해시를 이 파일에 문자열로 다시 적지 않는다**(이 파일의 규약).

**세대 판정 계약**: 산출물의 `objective_hash` 필드가 현재 `objective.json` 의 해시와 같은가.
불일치는 **하드 스톱**이어야 한다(`dp_solve.py:521` 이 그 모양). ⚠️ `sample_grid.py` 의
`load_grid()` 에는 그 검사가 **없다** — 낡은 `grid_spec.json` 위에 신세대 표본을 조용히 얹는다.

**세 도장이 서로 다른 것을 주장한다 — 하나로 읽으면 틀린다:**

| 도장 | 무엇에 대한 주장인가 | 무엇이 **아닌가** |
|---|---|---|
| `action_registry.json` 의 `vocab` (`v4-3arms`) | 행동 **어휘**의 세대 | 동역학도 목적함수도 아니다 |
| `dynamics_stamp()` (`hazard.jl:166`) | **런 하나**가 확률적 고장을 켜고 굴렀는가 | 목적함수 세대가 아니다 |
| `objective.json` 의 `generation` | **J 의 유효 의미**가 갈렸다는 사람이 붙인 딱지 | 🔴 어떤 산출물이 실제로 hazard 를 켰는지가 **아니다** |

🔴 **`require_dynamics` 는 write-only 다** — `core/action_registry.py:142` 에 정의는 있는데
**생산 소비처가 0개**이고 `smdp/test_stamps.py:152-157` 만 부른다. **Julia 짝도 없다**
(`grep -rn require_dynamics --include='*.jl'` = 0건). 즉 `dynamics` 축에는 기계 게이트가 없다 —
위 `train_kinds`·아래 `require_vocab` 과 **같은 실패 모드**이고, 이 축은 아직 그 자리에 있다.

🔴 **`generation` 안의 `hazard-on` 을 "이 산출물은 hazard 를 켜고 만들었다" 로 읽지 말 것.**
hazard 는 opt-in 이고 기본이 꺼짐이라 **기본 실행의 모든 산출물이 `dynamics=hazard-off` 를 달고
`…-hazard-on` 세대 이름 아래 놓인다.** 실행 사실을 나르는 것은 행의 `dynamics` 필드 하나뿐이고,
그것은 `hz_seed == -1 ⟺ HAZARD_ENABLED[] == false` 에서 **유도된다**(지어내지 않는다).

⚠️ 🔴 **2026-08-21 계획서 A Task T6 이 `generation` 을 다시 올린다**(D-5·D-6 이 동역학을 가른다).
그러면 **커밋된 모든 산출물이 구세대로 재분류된다** — 설계대로다.

## ⏳ 2026-08-20 — 확정 설계, 아직 미구현: 모든 팔 뒤에 공통 MILP 재풀이

**사용자 결정.** 실행 레인의 `handle_ood!` 가 매크로 dispatch 뒤 **모든 팔에 대해** 무제약
재풀이를 부른다. 즉 `(s,a) → s⁺` 가 팔과 무관하게 같은 argmin 을 통과한다.
**코드는 아직 안 바뀌었다** — 계획서 A **Task T13** 이 집행한다.

**왜 — 코드를 읽고 확정된 사실 셋:**
1. 🔴 **"action 후 MILP 재풀이" 공통 파이프라인은 레포 어디에도 없다.** `maybe_respecify!` 는
   제안을 **특수 분기**로 흘려보낸다(각 docstring 이 직접 그렇게 적는다).
2. 🔴 **`RESPEC_ENABLED[]=true` 로 플래그만 켜는 것은 답이 아니다** — 그 플래그는 **넷**을
   한꺼번에 켜고(큐 처리 · OOD 큐 적재 · `_enforce_serial_frontiers!` · 포획 드리프트 복구),
   `run_demo.jl` 은 큐를 우회해 자기가 복구하므로 **이중 복구**가 된다.
3. **부품은 이미 있다.** `rebalance_for_battery!`(`battery.jl:715`)는 배터리와 무관하다 —
   `build_invariant` 로 완료·진행중을 얼리고 추가 제약 없이 재정식화 + `optimize!` +
   `commit_respec!` 한다. 이름만 배터리다.

**구현자가 부딪힐 지점 (미리 실측):**
- 전제조건은 충족된다 — `run_demo.jl:531-532` 가 `ENERGY_OBJECTIVE=1`(기본)일 때
  `init_objective_weights!()` 를 부른다
- **반환값을 무시하면 안 된다** — `:rebalanced | :infeasible | :commit_failed` 인데 현재
  배터리 분기(`run_demo.jl:391`)는 **아예 안 본다**
- **중복 호출 제거**: 배터리 분기 안의 `rebalance_for_battery!` 를 빼야 두 번 안 푼다
- **NOOP 도 재풀이할 것인가는 의미 결정이다** — 재풀이하면 NOOP 이 "제약 변화 없이 다시 품" 이
  되어 진짜 행동이 된다
- ⚠️ 🔴 **항진적 변경이 되지 않는지 먼저 재라.** 관측된 판들은 `n_candidate_edges=0` 이라 MILP 가
  순수 makespan 으로 후퇴했다. 후보 간선이 0이면 공통 재풀이가 **아무것도 안 바꾼다.**
  "재풀이를 켰다" 가 아니라 **"재풀이가 실제로 계획을 바꿨다"** 를 음성 대조와 함께 측정할 것
- 🔴 **G6 은 모든 팔에서 `ran_milp=true` 가 되고 그게 설계상 정상이다. "G6 PASS" 를 인용하지 말 것.**
- 🔴 **동역학 세대가 갈린다 → 재스윕·재라벨.** 그 축을 나르는 도장이 없으므로 **구현과 같은
  커밋에서 `generation` 을 올릴 것.**

## ★ 아직 살아 있는 결함과 손잡이 — 실행 전 필수

🔴 **세대별 결과 수치·발행 표·철회된 논증은 이 파일에서 뺐다**(2026-08-21 정리).
전부 `md/README.md`(§0 현행 · §0-Z 직전 · §3 확정 측정 · §7 철회된 결론 · §8 함정 43개 ·
§10 아카이브 색인)에 있다. ⚠️ **그 파일은 작업 트리에서 삭제된 상태다** — 이렇게 꺼낸다:

```bash
git show 0ed0c4be:wm4spacecraft_manufacturing/md/README.md | less
git show 0ed0c4be:.claude/CLAUDE.md | less        # 이 파일의 정리 전 판(919줄)
```

아래 여덟 중 **1 은 해소됐고 나머지 일곱은 아직 살아 있다** — 전부 계획서 실행자의 행동을 바꾼다.

1. ✅ **런 간 재현성 결함은 고쳐졌다**(이 목록에서 유일하게 해소된 항목). 두 커밋이 함께 고쳤다:
   `038aa58d`(2026-08-19)가 `_pick_active_robot`(`respec/ood_injection.jl:916`)의 `Set` 순회를
   `_ordered_active(env) = sort!(collect(env.cache.active_set))`(`:912`)로 정준 정렬했고,
   `bb1b88c4`(2026-08-24)가 `AbstractID` 에 **내용 기반** `Base.hash` 를 정의해 뿌리를 뽑았다 —
   Julia 기본 해시가 `objectid` 를 쓰는데 프리컴파일이 바이트 재현되지 않아 ID-키 `Dict`/`Set` 의
   순회 순서가 **빌드마다** 갈렸다. 이제 시드 고정으로 재현된다.
   🔴 **대가: 그 이전 산출물은 전부 다른 세계다** — 옛 라벨·스윕 수치를 새것과 같은 표에 섞지 말 것.
   ⚠️ `_ordered_active` 는 **순회 순서가 결과에 남는 자리에만** 걸려 있다(첫 매치에서 `return`
   하는 순회, 순서가 살아남는 `Vector` 를 만드는 순회). 후보를 모아 `sort(...)[1]` 로 고르는
   피커들은 정렬이 이미 순서를 지우므로 일부러 손대지 않았다 — `ood_injection.jl:897-911` 의
   docstring 이 그 규칙의 진실원이다. **새 `active_set` 순회를 쓸 때 이 규칙을 다시 판정할 것.**
2. 🔴 **다른 창고의 놀고 있는 예비가 Replace 경로에서 안 보인다**
   (`ood_injection.jl:425-435`). `pop_spare!` 는 배송 중 예비를 건너뛰도록 고쳤지만
   `nearest_pool` 은 여전히 `isempty(SPARE_POOLS[][key])` 만 본다. 풀당 기본 2대라 가장 가까운
   창고 둘이 배송을 나가면 `"empty_pool"` → `:no_spare` 로 강등된다 — **아직 자유 예비가 남은
   다른 창고를 한 번도 안 보고.** ⚠️ 신호가 전부 `@info`/`@warn` 이라 `Logging.Warn` 아래에서
   **두 세대 모두 0건**이었다("안 났다" 가 아니라 "못 본다").
   → **계획서 A 의 D-7 가드가 정확히 이 자리를 에러로 만든다.**
3. 🔴 **중복 파견이 "성공" 으로 보고되고 교체는 일어나지 않는다**
   (`respec/battery_courier.jl:169-171`). 중복 제거 스캔이 `d.target == target` 을 **phase
   무관**하게 맞춰서, 이미 `:returning` 이면 두 번째 `SwapBattery` 가 낡은 배송을 돌려주고
   성공 문자열을 찍는데 `_apply_battery_swap!` 은 `:outbound` 에서만 불린다. 도달 가능성은
   실측이다(같은 대상 60쌍 중 **50쌍이 발화 창 안**). 적용된 교체를 세는 신호가 산출물에 없다.
4. 🔴 **조합 팔은 정보량이 0이었다** — 65/65 instance 에서 `5≡4`, `6≡2`. 추가 primitive 가
   엔진에서 집행되지 않았기 때문이다. → **계획서 A 의 게이트 N-G7 이 그 재발을 막는다.**
5. 🔴 **`ood_mdp_shim.valid_actions` 는 팔 메뉴가 아니라 문지기다.** `action_to_proposal` 이
   `a in valid_actions(ctx) || return nothing` 으로 거른다 — 메뉴 밖 팔을 시키면 에러가 아니라
   **조용히 NOOP 으로 무너진다.** 팔을 늘리려면 여기부터다.
   → 계획서 B 의 escalation 은 이 함수를 **우회**해야 한다.
   ⚠️ 옛 서술("fault 가 리터럴 `[0,1]`" · "매크로 4")은 낡았다: fault 분기는 이제
   `ActionRegistry.kind_valid(:fault)` 를 돌려주고(`ood_mdp_shim.jl:234`), 리터럴 `[0,1]` 은
   **`DS_ARMS_LEGACY=1` 에서만** 나온다(`:231`). 매크로 4 는 `v4-3arms` 에 아예 없다.
   실측 현행값: `fault=[0,1]` · `battery=[0,1,2]`(SoC 분할이 더 좁힌다) · `zone=[]`.
   즉 **값은 같고 출처가 리터럴 → 레지스트리로 바뀐 것**이고, 문지기라는 사실은 그대로다.
6. 🔴 **라벨 레인은 `DS_HOTSWAP=1` 이어야 한다.** 실행 레인이 hot-swap ON 이고, 안 켜면 fault
   대상 피커가 죽어 **발화율이 100% → 23%** 로 무너진다(실측). 로그만 보면 정상으로 보인다.
7. 🔴 **`n_stalled` 가 정지의 유일한 기계적 증거다.** `run_demo.jl:472` 가 `global_logger` 를
   `Logging.Warn` 으로 심어 `battery.jl:297` 의 `[STALL]`(`@info`)이 통째로 버려진다 —
   **"로그에 없다" 를 "안 났다" 로 읽으면 안 된다.** 이 레포의 다른 진단 로직 중 로그 부재로
   추론하는 것은 아직 감사 안 됐다.
8. **`DEMO_BATTERY_COURIER=0` 은 순수 통제가 아니다.** 배송만 끄고 `_faultable` 수정과
   `REPLACE_SOC_THRESHOLD` 회복 조건은 **되돌아가지 않는다**(셋이 섞여 있다). 이 플래그로 만든
   판은 구세대와 **같지 않다.**

⚠️ **canonical 은 `SwapBattery` 를 한 번도 안 고른다** — 210판 1533결정에서 0회. 구조적이다.
그래서 배송을 태우는 레인은 surrogate·dspy 뿐인데, **그 둘이 바로 DSPy 가 죽으면 조용히
canonical 로 내려앉는 레인**이다(위 §2026-08-18 항목 5).

⚠️ **발행된 `decision_acc` 는 아직 구세대 기준으로 채점된다** — `reference_policy.py` 의
`BASIS["battery"]` 에 `🔴 STALE PREMISE` 표식만 붙었고 규칙은 재유도되지 않았다.
→ 계획서 B 의 O1 재라벨이 그 자리를 다시 연다.

## Environment
- **`julia +lts` (1.10)** — `Manifest.toml` is pinned to 1.10.11; `Pkg.add` under a newer Julia silently breaks the build.
- Always pass `--project=.`.
- PyCall's interpreter must be the one `rvo2` is installed into (`ENV["PYTHON"]` / `CB_PYTHON`). See `PYTHON_SETUP.md`.
- Python stack = **`.venv/`(레포 루트)**, 즉 `/home/chahj578/Construction_OODlayer/.venv/bin/python`
  — **dspy 3.3.0**. (`venv/hjcrl` 은 존재하지 않는 경로다: 2026-08-13 정정.)
  데모/렌더 재현엔 `DSPY_URL` + `NOVELTY_CALIB`(repo 내 경로) 필요.
- **dspy 3.3.0 은 `import dspy` 시점에 `numpy` 를 lazy 프록시로 갈아 끼운다** — 그래서
  `src/respec/llm_service/dspy_service.py:44` 의 `import numpy, sklearn.ensemble` 는 `import dspy`
  **앞에** 있어야 한다(지우면 numpy 반쪽 초기화로 surrogate 로드가 죽고, 레인이 조용히 canonical
  로 폴백한다 — 커밋 `f43ad79` 가 고친 회귀다).

## Commands
```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'   # full test suite
julia +lts --project=. tools/demos.jl <key>         # also: tests|checks|restage|e2e|diagnostics|setup
julia +lts --project=. -i tools/dev_session.jl      # Revise REPL: t() re-checks, rebuild() re-builds env
# 매크로를 추가/수정한 뒤 어휘 6-소비처 일치를 보던 audit_action_vocab.py 는 2026-08-18 정리에서
# 삭제됐다 (git show 8e005842:wm4spacecraft_manufacturing/audit_action_vocab.py). 지금은 손으로
# action_registry.json 과 소비처를 대조할 것 — 누락은 에러 없이 성능으로만 샌다.
```
Key can also come from an env var (`DEMO=`, `TEST=`, ...), which takes precedence over `ARGS[1]`.

**기대 baseline(실패 아님):** `Pkg.test()` = **254 pass / 0 fail / 1 error / 255 total**
(≈4m30s). 유일한 error 는 `test/runtests.jl:80` 의 `Demo` — `Gurobi Error 10009: No Gurobi
license found` 이고 **변경과 무관하다.** (2026-08-28 실측. 옛 "11 pass" 는 상위 testset 개수를
전체 단언 수로 잘못 읽은 것이다.)

⚠️ **`Pkg.test()` 초록이 전부가 아니다.** `test/smdp_global_inventory.jl`(spec §3.6 — 스냅샷
대상 전역의 전수 목록을 기계로 지키는 살아 있는 게이트)은 **`test/runtests.jl` 이 include 하지
않는다**(실측). 전역을 새로 만들었으면 손으로 돌릴 것:
`julia +lts --project=. test/smdp_global_inventory.jl`. 계약이 성립하는 자리는 작업 트리가
아니라 **HEAD** 다(그 파일 헤더가 근거를 적는다).

🔴 **삭제된 검사 도구들**(2026-08-18 정리, `git show 8e005842:wm4spacecraft_manufacturing/<name>`):
`verify.py` · `audit_objective.py` · `audit_action_vocab.py` · `test_objective.py` ·
`test_surrogate_support.py` · `measure_objective_scales.py` · dp 테스트 넷.
**계약은 살아 있고 검사만 없다** — 위 §2026-08-18 절의 다섯 항목이 그 목록이다.
⚠️ 옛 결과("8/8 PASS" 등)를 인용하지 말 것 — 어떤 기존 덤프로도 재현되지 않는다.

## Gotchas
- **`tools/*.jl` with no key runs a default silently** (`demos.jl` → `original_baseline`) instead of erroring. Read the `DEMOS` dict at the bottom of the file for valid keys.
- Behavior is driven by ~180 env-var knobs. Discover them, don't guess:
  `grep -rho 'get(ENV, *"[A-Z0-9_]*"' src tools | sort -u`
- Runtime `include` of navigator/battery modules must stay at module top level (world-age errors otherwise).
- **비교 런은 순차 실행**(함정 30). 병렬이면 HiGHS가 다른 스케줄을 내 비교가 무효 + 프로세스당
  ~2.5GB라 OOM. 과거 "B-7 미완주"가 이 아티팩트였다(단독 실행 시 3/3 완주).
- 행동 어휘 단일 진실원 = `wm4spacecraft_manufacturing/core/action_registry.json`(리터럴 복붙 금지).
  누락은 에러 없이 성능으로만 샌다 — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을 갈랐다.
- LLM lane은 `DSPY_PROGRAM=__seed_only__`. 컴파일된 `dspy_real_program_gpt4o.json`은 battery 전용이라
  zone·RelocateBuild 어휘가 없다 — 그걸로 zone을 재면 어휘 밖 사건을 재는 것이 된다.
- `DSPY_URL` 포트는 레포에 6종이 흩어져 있다. 문서 숫자 말고 **띄운 uvicorn 포트**에 맞출 것.
- `_first_pending_assignment`는 "일감 유무"가 아니라 **"작업 경계"** — 중반 이후 조용히 틀림.
- 배포 surrogate 의 **매크로 지원 집합**은 학습셋이 정한다. 🔴 **현행 학습셋은
  `wm_datasets.ORACLE_DATASET` 이다** — `dspy_service.py:241` 의 `SURRO_DATA`, 그리고
  `eval_surrogate_v2.py:385` · `conformal_feasibility.py:243` 의 `--labels` 기본값이 전부 이것.
  실측 내용: 33행 / 12 instance · `macro {0:12, 1:12, 2:9}` · `vocab v4-3arms` ·
  `train_kinds battery,fault` · `objective_hash 489268e6659e5ae9`.
  🔴 **`wm_datasets.N44_PLUS78` 은 죽었다** — 남은 것은 `wm_datasets.py:102` 의 상수 정의와
  `KNOWN` 등재뿐이고 **실사용 소비처가 0개다.** 파일도 없다(`oracle/out/` 에는
  `oracle_dataset.jsonl` **하나뿐**). 지원 밖 팔은 에러 없이 후보에서 탈락해 **성능으로만** 샌다 —
  그 계약을 지키던 `test_surrogate_support.py` 는 2026-08-18 정리에서 삭제됐으므로 지금은
  학습셋의 support 를 손으로 확인해야 한다.
- 🔴 **결정성의 단위는 프로세스가 아니라 디렉토리(= 컴파일 캐시).** 실측: 동일 커밋
  `a272169f` 를 두 워크트리에 펼치고 같은 명령을 돌리면 makespan **19.875 vs 19.050** 이고
  결정 블록도 다르다. 같은 워크트리 3회 반복은 전부 19.875. 잡음 폭 0.8~2 s.
  귀결 둘: (1) **프로세스 간 golden-hash 비교는 코드 변경 검증 게이트가 될 수 없다** —
  차이가 코드 때문인지 재컴파일 때문인지 구분이 안 된다. (2) 🔴 **탐색 트리·비교 런은 한
  디렉토리 안에서 굴린다** — root parallelization 은 트리마다 같은 세계를 전제하는데, 여러
  디렉토리에 뿌리면 이 잡음이 합산에 실린다. **잡음 바닥을 재기 전까지.**
  실제로 게이팅하는 것은 `test/greedy_cost_dispatch_equivalence.jl`(인프로세스 A/B)이다.
  `test/greedy_assignment_regression.jl` 은 비게이팅 진단용 — 실패해도 게이트가 아니다.
- **`@info` 가 프로세스 전역에서 조용히 사라진 적이 있었다.** `run_lego_demo` 가
  `global_logger(…, Logging.Warn)` 을 설치하고 복구를 안 해서, 첫 env 빌드 이후의 모든 `@info` 가
  안 찍혔다. 이 작업 도중 실제로 이걸로 오판을 냈다("폴백이 안 탔다" — 사실은 탔었다). `finally`
  블록에서 복구하도록 고쳤지만, 이 레포의 다른 진단 로직 중 "로그에 안 떴다"로 추론하는 것은
  아직 감사 안 됐다 — 의심하고 볼 것.

## Layout
- `src/respec/` — OOD → DSL re-spec layer (`spec_dsl.jl` · `compiler.jl` · `verifier.jl` ·
  `replan.jl` · `reassign.jl` · `restage_zone.jl` · `replace_robot.jl` · `battery_courier.jl` ·
  `ood_injection.jl` · `llm_bridge.jl` · `llm_service/`)
- `src/smdp/` — `hazard.jl` · `mdp.jl` · `simstate.jl` · `observe.jl` · `state_globals.jl`
  ⚠️ **다섯 파일뿐이다.** `derive.jl` · `rates.jl` · `tplan.jl` · `sojourn.jl` · `generative.jl` ·
  `replay.jl` 은 **계획서 A·B 가 만든다** — 아직 없다.
- `src/safety/` — `zone_guard.jl` · `novelty.jl` · `src/monitor/` · `src/navigator/`
- `wm4spacecraft_manufacturing/` — Python 분석 스택. 현재 작업 트리에 있는 것:
  `core/` · `oracle/` · `reporting/` · `smdp/` · `surrogate/` · `sweep/`

## Docs

🔴 **작업 트리에서 219개 파일이 삭제된 채 미커밋이다**(2026-08-28 실측, `git status --porcelain`).
🔴 그래서 **`git add -A` / `git add .` / `git commit -a` 금지** — 남의 작업인 삭제를 통째로 커밋한다.
반드시 **명시 경로**로 `git add` 할 것. HEAD 에는 있는데
작업 트리에 없는 것: `md/` · `novelty/` · `render/` · `measurements/` · `dp_oracle/` ·
`results*/` · `artifacts*/` · `sweep_lab/`. **경로를 인용하기 전에 실제로 있는지 확인할 것.**

- 🔴 **현행 계획서**: `docs/superpowers/plans/2026-08-28-closed-loop-counterfactual-labels-v3.md`
  (v3 closed-loop 반사실 라벨). 근거·실측은 `docs/superpowers/reports/2026-08-28-v3-evidence.md` ·
  `…/2026-08-28-conformal-feasibility-measurement.md`.
- 선행 계획서 둘: `docs/superpowers/plans/2026-08-21-reduced-state-smdp-action-synthesis.md`
  (A, 실행할 것) · `…/2026-08-21-ood-layer-replay-buffer.md`(B, A 의 Phase 4 뒤에).
  설계는 `docs/superpowers/specs/2026-08-20-reduced-state-ood-smdp-design.md`.
  Phase 0~1 보고서는 `docs/superpowers/reports/2026-08-20-phase1-completion.md`.
- **세대별 결과·발행 표·철회된 결론·함정 43개**는 `md/README.md`(1149줄)에 있다.
  작업 트리에 없으므로: `git show 0ed0c4be:wm4spacecraft_manufacturing/md/README.md`.
  §0 현행 · §0-Z 직전 · §1 용어(F vs OOD) · §3 확정 측정 · §5 스키마 ·
  §6 완주 ≠ `closed==total` · §7 철회된 결론 · §8 함정 · §9 살아 있는 계약 · §10 아카이브 색인.
- 이 파일의 **정리 전 판**(919줄, 세대별 서술 전문): `git show 0ed0c4be:.claude/CLAUDE.md`.
- ⚠️ **경로 규약**: 맨이름 import 는 `core/wmpath.py` 가 유지하고, 데이터 경로의 기준점은
  `HERE` 가 아니라 `wmpath.WM`(= wm4 폴더)다.
- 아카이브: `docs/superpowers/plans/README.md`(실행 완료 계획서) ·
  `docs/superpowers/SDD_SESSIONS_ARCHIVE.md`.
- `tools/README.md` · `src/SIMULATION_FLOW.md` · `RUN_GUIDE_KR.md`
