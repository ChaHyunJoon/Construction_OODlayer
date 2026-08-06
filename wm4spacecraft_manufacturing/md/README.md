# wm4spacecraft_manufacturing — 단일 진입점

*통합 2026-08-06. 이전 통합(2026-08-02) 이후 쌓인 야간·작업 로그 7개를 여기 흡수했다(§9 목록).
현재 상태와 다음 할 일은 `STATUS.md`, 개념·결과·함정은 이 파일이다.*

**읽는 순서**: §1 용어 → §2 아키텍처 → §3 확정 결과 → §8 함정목록.
그 다음 필요할 때만 §9 의 문서 지도를 따라간다.

---

## 1. 용어 — 이 구분이 없으면 아래 전부가 오해된다

| 용어 | 정의 | 구성 | surrogate 훈련 |
|---|---|---|---|
| 교란(disturbance) | 엔진의 사건 채널 | `push_ood!` 봉합선 | — |
| **알려진 고장모드 F** | 사전 열거된 닫힌 어휘 | battery, zoneblk, fault | **포함** |
| **OOD 사건 N** | F 밖 = 훈련분포 외부 | **미정의** | **구성상 배제** |

**battery/zoneblk/fault 는 OOD 가 아니다.** surrogate 훈련에 쓰이므로 정의상 in-distribution 이다.
지금까지 이 셋을 "OOD" 라 불러왔으므로 **엄밀한 의미의 OOD 실험은 아직 한 적이 없다.**
LOKO(한 종류 빼고 학습)는 OOD 의 **대리 실험**이지 OOD 자체가 아니다.

**연구 목표**: 미지의 OOD 가 왔을 때 LLM 이 대응을 만들고, 그 대응이 surrogate 의 **행동집합에 편입**되어
다음부터는 surrogate 가 처리한다 → `PLAN_ACTION_GROWTH.md`

---

## 2. 아키텍처 — TAMP 안쪽 / MDP 바깥쪽

```
  바깥 루프 = SMDP  (확률적, 정책을 학습)
     상태 φ(s) ─→ [Router] ─→ surrogate | LLM | oracle
                      ↓
                   행동 a = ConstraintSpec 조합
                      ↓
  ────────────────────────────────────────────────
  안쪽 루프 = TAMP  (결정론적, plan 을 만듦)
     respec → MILP 재배정 → RVO2 항법 → 실행
```

**핵심**: MDP 가 TAMP 를 **대체**하는 게 아니라 **위에 얹혀** 있다.
행동은 로봇 제어가 아니라 **TAMP 문제에 제약을 추가하는 것**이고, 전이 1회 = 플래너 1회다.
그래서 라벨 하나에 20~300초가 들고, 그것이 surrogate 가 존재하는 이유 전부다.

**봉합선**: `src/respec/replan.jl:91` `RESPEC_PRODUCER` — 오라클/규칙/surrogate/LLM 이 전부 여기 꽂힌다.

### 상태가 정의된 곳 (3층)

| 층 | 정체 | 위치 |
|---|---|---|
| 물리 | 시뮬레이터 실제 상태 | `PlannerEnv` (`route_planning.jl:108`) |
| TAMP | 하이브리드(심볼릭+연속) | `scene_tree` + `sched`/`cache` |
| **MDP φ** | 위의 **고정폭 요약 40개** | `capture_raw` → `derive_state_descriptors` |

φ 는 상태의 **정의가 아니라 인코더**다. 그래서 T1(충분성 검정)이 필요하다.

### 행동

`spec_dsl.jl` 의 primitive: `ReplaceAgent`(1) `DeprioritizeAgent`(2) `ForbidAgent` `ForbidZone`(3)
`ReformTeam` + `RelocateBuild`(7, 2026-08-03 신설) + `SwapBattery`(8, 2026-08-05 신설).
`RespecProposal.constraints` 는 벡터이므로 **조합 행동은 오늘 당장 실행 가능하며 한 번도 쓰인 적이 없다**
— 남은 확장 축이다(파라미터 축은 §3 STEP 6 에서 사망).

> ⚠ 새 매크로 id 를 추가하면 `ACTION_NAME` / `MACRO_COST` / `features_agnostic.MACRO_COST`
> **세 곳을 같이** 늘려야 한다. 안 그러면 시뮬은 통과하고 **행을 쓰는 순간** `KeyError` 로 죽는다.

---

## 3. 확정된 측정 결과

### E1~E4 (원본 `RESULTS.md`)

| | |
|---|---|
| E1 결정 subopt_norm | **0 @ 플래너 호출 0회** (100% compute 절감, ~348 s/결정) |
| E1 완주노드 예측 | MAE 13.4 (범위 143~291), **R² = 0.829** |
| E1 상태무관 baseline | subopt_norm 0.281, 95% CI [+0.125, +0.438] |
| E2 | LLM-over-surrogate 가 67% 적은 검증으로 동품질 |
| E3 | frozen 모델은 drift 에서 붕괴, active 재학습은 1스텝 복구 (호출 54%↓) |
| E4 | FULL 이 Pareto front, LLM→solver 대비 45% 적은 호출 |
| 비용 평가 v2 | surrogate 0.10 ms · subopt_norm 0.100 · 완주 100% = LLM+solver(64 s) 대비 **1.9M×** |

**E1 의 정직한 한계**: 그 데이터에서는 OOD 종류가 매크로를 거의 결정해버려 top-1 이 항상 맞고
frontier 가 곡선이 아니라 **계단**이었다. compute 절감은 진짜지만 랭킹 문제는 쉬웠다.
→ 이 한계는 아래 사다리 실험이 뒤집는다.

### 이 과제는 kind-trivial 이 **아니다** (2026-08-04 사다리, `oracle/out/lad_*`, seed 401~404)

같은 kind 안에서 정답이 정반대로 갈리는 데이터를 처음으로 만들었다. 32 instance **전부 결정적(동점 0)**.

```
kind=zoneblk   n=16   {NOOP: 8, RelocateBuild: 8}   H(best|kind) = 1.00 bits  ← 이론상 최대
kind=battery   n=12   {Replace: 8, NOOP: 4}         H(best|kind) = 0.92 bits
kind=fault     n= 4   {Replace: 4}                  H(best|kind) = 0.00 bits  ← fault 는 여전히 kind 로 결정됨
```

`zoneblk`(적치 차단) → RelocateBuild, `zonecore`(root 목표 덮음) → NOOP 인데 **둘 다 컨트롤러에게는
`kind="zoneblk"` 로 보인다**. 즉 종류 이름만 보는 규칙표는 zoneblk 에서 원리적으로 동전던지기보다
나을 수 없다. **상태를 읽는 정책이 필요한 이유가 데이터로 성립했다.**

뜻밖의 것: **harm 은 root 목표를 덮는 데서 오는 게 아니라 적치 공간을 막는 데서 온다.**
core zone 은 완주하고(4/8, 6/8) 정답이 NOOP, staging zone 은 한 번도 완주 못 하고(0/8) RelocateBuild 다.

### STEP 6 — 옵션 제한의 대가는 관측되지 않음

| seed | V^macro | V*(ext) | 최선 확장 arm | 노이즈 바닥 |
|---|---|---|---|---|
| 1 | 3573.57 | 3568.99 | 10 (**≡ macro 1**) | 4.57 |
| 2 | 22.12 | 22.12 | 1 | 0.00 |
| 3 | 3841.41 | 3841.41 | 1 | 1.58 |

평균 gap 0.00 · 노이즈 바닥 2.05 · 유의 seed 0/3. `Replace@{0,5,15}` 구별 불가,
`Deprio×{10,50,200}` 셋 다 NOOP 값으로 붕괴. → **파라미터 축을 열어도 얻을 것이 없다.**
(원시 배정공간은 안 열었으므로 이 gap 은 **하한**.)

### Assimilation C1~C4 (원본 `DESIGN_ASSIMILATION.md`)

| | 명제 | 상태 |
|---|---|---|
| C1 | 처음 보는 종류에서 LLM > surrogate | **조건부 성립** (fault 폴드만) |
| C2 | 아는 종류에서 surrogate 동등품질·10⁴배 저렴 | **성립** |
| C3 | 시스템이 스스로 "처음 보는 것"을 판별 | **미확립** |
| C4 | LLM 처리분을 학습해 다음부터 싸게 | **성립** |

C1 이 조건부라는 게 가장 큰 위험 — 깨지면 라우터는 "더 나쁜 쪽으로 보내는 장치"가 된다.
관련해서 종류 홀드아웃(2026-08-03, n=127)에서는 **가설과 반대 방향**이 나왔다: battery/fault 를
훈련에서 빼도 그 종류에서 오히려 더 잘한다(subopt_norm 0.226/0.215 vs 그 외 0.323). kind-agnostic 설계가
잘 작동한다는 뜻이면서 동시에 **"LLM 을 불러야 하는 구간"의 존재를 이 데이터로는 못 보인다**는 뜻이다.

### 정책 비교의 벽 (2026-08-03, 결정적 n=127)

| 판정 | 근거 |
|---|---|
| **상태는 정보를 담고 있다** | surrogate vs random 39승 17패, 부호검정 **p=0.005** |
| **규칙표는 아직 못 넘었다** | 25승 18패, **p=0.360** (평균 subopt_norm 은 +0.055 우세하나 미확립) |

이 벽은 위 사다리 데이터(H(best|zoneblk)=1.00)가 뚫을 대상이다 — 규칙표가 원리적으로 못 푸는
instance 를 모으는 것이 그 방법이었다.

---

## 4. 확정된 설계 결정

**비용 = 유한벌점 SSP** (`gen_oracle_mc.jl:146` 와 `overnight_mdp.py:35` — **두 곳이 반드시 같아야 함**)

```
complete → makespan
else     → 10000 + 100×unclosed + 1e-3×makespan
```

사전식 순서(완주 ≫ 닫힌 노드 수 ≫ makespan)를 스칼라로 옮긴 것. 완주끼리는 **closed 를 보지 않는다**
(`better_ssp`).

**라벨 = K-rollout MC + CRN.** 같은 rollout k = 같은 hazard seed → 짝지은 비교가 유효.
1-shot 라벨은 NOOP 비용을 **375배 과소평가**한다(실측).

### 지표 용어 — `regret` 을 헤드라인에서 내린다 (2026-08-06 결정)

**옛 문서·아티팩트의 `regret` 은 전부 아래의 `subopt_norm` 이다.** 값은 바뀌지 않았고 이름만 정확해졌다.
구현은 `verify.py` (`subopt_norm` / `excess_cost` / `optimal_action` / `decision_report`).

| 이름 | 정의 | 단위 | 지위 |
|---|---|---|---|
| `subopt_norm` (구 `regret`) | `(V* − V^π) / (V* − V_worst)` | 0~1 | **진단용**. 집계·짝지은 검정에만 |
| `excess_cost` | `V* − V^π` 를 사전식 층별로 분해 | 아래 4줄 | — |
| ┣ `d_feasibility` | 완주 가능했는데 못 고른 결정 | 건 · % | **헤드라인** |
| ┣ `d_closed` | 잃은 노드 | 노드 | **헤드라인** |
| ┣ `d_makespan` | 잃은 시간(둘 다 완주일 때만) | 초 | **헤드라인** |
| ┗ `d_cost` | 최선 대비 더 쓴 개입비용(≈소모 자원) | — | **헤드라인** |
| `optimal_action_rate` | `P(a = a*)`, **동점 제외 분모** | % | **헤드라인** |
| `infeasible_pick_rate` | 구 catastrophic-choice rate | % | **헤드라인** |

**왜 강등인가**: (a) `subopt_norm` 은 단위가 없고 분모 `span` 이 사건마다 달라 같은 0.100 이 사건마다
다른 물리량을 뜻한다. (b) **λ 에 오염돼 있다**(함정 21 이 이미 "λ 를 가로질러 비교 금지" 라고 적고 있다)
— 튜닝 파라미터에 의존하는 값은 헤드라인이 될 수 없다. (c) 논문의 regret 은 보통 bandit 의 **누적
regret** 이고, 여기서 재는 1회 결정의 손해는 **simple regret / suboptimality gap** 이다.

**측정으로 확인된 강등 근거** (CANONICAL `openworld_merged.jsonl` 60 instance, λ=3):

| 정책 | 구 subopt_norm | 적중률 | 틀렸을 때 노드/시간 | 완주 놓침 | 과잉개입 |
|---|---|---|---|---|---|
| always-NOOP | 0.490 | 50.0% | **97.3 노드** / 0.0 s | **40.0%** | −0.50 |
| always-Replace | 0.500 | 50.0% | 0.0 노드 / **0.3 s** | **0.0%** | **+0.50** |

옛 지표로는 두 정책이 사실상 같은 숫자다. 실제로는 **완전히 다른 실패 모드**다 —
하나는 빌드를 못 끝내고, 하나는 스페어를 낭비한다. 정규화가 그 차이를 지우고 있었다.

> `d_cost` 를 따로 세는 이유: SSP 물리비용은 **소모한 스페어를 보지 않는다**. λ 는 그 축을 결정규칙에
> 섞어 넣어 감췄다. 섞지 말고 따로 센다.

**마이그레이션**: `regret` 은 20개 py 파일·JSON 키에 박혀 있으므로 **일괄 개명하지 않는다.**
JSON 은 새 키를 추가하고 `regret` 키를 별칭으로 남기며, `verify.norm_regret` 함수명도 그대로 둔다
(옛 아티팩트를 읽는 코드가 조용히 깨진다). 전문 = `PLAN_LLM_INFERENCE_7H_2026-08-06.md` §0-a.

**개입비용 항은 유지하되, λ 는 학습 목표에서 뺀다** (2026-08-05 결정, 근거 `BATTERY_FAULT_REDESIGN`):

- λ 는 데이터로 **식별 불가**(0.5→30 에서 답이 2.4~3.2% 만 변화). "λ=15 로 튜닝했다"는 **철회**.
- 그러나 λ=0 이면 126 중 **58건(46%)이 완전 동점** → 비용 항 제거도 기각.
- λ≥13 은 측정된 12노드 이득을 지우고, **λ>0 은 makespan 계층을 원천 무효화**한다.
- → `y = closed`(물리)로 학습하고 랭킹에서 비용을 해석적으로 적용(LOO 에서 한 번도 나쁘지 않고 λ=15 에서 우세).
- → 목표 키를 μ-키 `(complete, closed, −(makespan + μ·cost))` 로, **μ=4** (측정된 섭동 바닥 0.775 s 에서 유도).
  단 **선행조건**: 배포 surrogate 가 단일 출력이라 makespan 예측 헤드가 하나 더 필요하다. 그때까지는 λ-키(λ=3).

**battery 사건의 기본 행동 = `SwapBattery`**, `Replace` 는 본체가 못 쓰게 됐을 때만.
두 팔의 완주·closed 는 항상 동일(291)인데 SwapBattery 는 창고 본체를 안 먹고 **후반일수록 더 빠르다**
(f222 에서 24.88 → 19.62 s = 대조군과 동일).

**배포 게이트 G1/G2/G3** — 모델을 바꿀 때마다: G1 기존 F 에서 subopt_norm 이 유의하게 나빠지지 않았는가 /
G2 새 클러스터에서 좋아졌는가 / G3 novelty 교정이 여전히 유효한가. 하나라도 실패면 **롤백**.

**LLM 은 새 DSL kind 를 발명하지 않는다** — 미지 사건에서는 서술자 6개
`[harm, work_at_risk, resource_loss, recovery_capacity, progress, slack]` 를 **추정**하고 하류는 그대로 돈다
(`src/safety/novelty.jl`). 입력 쪽 개방성은 확보돼 있고 **출력 쪽(행동 확장)만 없다**.

**프롬프트에 결정표를 넣지 않는다** (2026-08-05). 규칙을 산문으로 주면 측정되는 것은 추론이 아니라
**프롬프트 준수**다(실측: 서술자가 `harm=0.02` 인데도 지시문을 따라 ForbidZone 을 골랐다).
지금은 원리 한 줄 + 각 행동이 무엇을 해소하는가(어휘 설명)만 준다.

**world 축과 확률성 축은 다르다** (2026-08-05 축 재정의):

| 축 | 값 | 어디서 |
|---|---|---|
| world (공장 도면) | **seed 1 고정** | `DS_SEEDS` / `DEMO_SEED` |
| 확률성 (언제·무엇·얼마나) | 스위프 | 라벨=`DS_FIRE_GRID` 격자 / 평가=`DEMO_OOD_SEED` 무작위 |

`DS_SEEDS` 는 확률적 사건 축이 **아니다** — 시뮬레이터가 rng 를 쓰는 곳은 `full_demo.jl:420` 의
로봇 초기배치 하나뿐이고 그 뒤는 결정론이다. **라벨에서 시점이 격자인 것은 버그가 아니라 요구조건**이다
(반사실 비교이므로 두 팔에서 같은 사건이 같은 시점에 터져야 한다). 무작위 시점의 성능은 라벨이 아니라
**평가**에서 잰다.

---

## 5. 데이터 스키마

`gen_oracle_dataset.jl` 이 `(instance, macro)` 당 한 줄. **원자료만 덤프, 서술자는 파이썬에서 계산**
— 정의를 바꿔도 재시뮬이 아니라 재계산이면 된다.

| 묶음 | 열 |
|---|---|
| 로봇 원자료 | `raw_robot_x/y`, `raw_robot_mode`(IDLE/TRANSIT/CARRY/MANIPULATE), `raw_robot_goal_x/y`, `raw_n_carry\|transit\|manip` |
| 화물 | `raw_cargo_id/x/y/placed`, `target_id`(raw 벡터 조인 키) |
| 에피소드 | `hist_*` 8개 (T2 용) |
| **zone 원시값** (2026-08-05, opt-in) | `zone_blocked · zone_restage_feasible · zone_work_overlap · zone_teams_forming · zone_teams_covered · zone_relocatable · zone_relocate_norm` |
| 파이썬 파생 | `xc_*`(커밋먼트) `xt_*`(사건 당사자) `xg_*`(SoC 분포) `xa_*`(부품 배치) — 총 φ 40개 |

**판정(verdict)은 절대 싣지 않는다.** 그건 정답이므로 오라클·게이트의 것이고, 행에 실으면 정책이
추론이 아니라 답을 베끼게 된다(`test_policy_zone.jl` 이 누출을 검사한다).

zone 원시값이 **기본 꺼짐**인 이유: 열을 넣으면 특징 차원이 바뀌어 이미 export 된 서로게이트·novelty
교정과 호환되지 않는다. 옛 덤프에는 열이 없어 `-1`(=모름) 센티넬로 채워진다.

---

## 6. 완주(completion)에 대해 반드시 알아야 할 것

- **완주 ≠ `closed == total`.** 오라클 완주 시 291/313, 데모 설정에서는 287. 모든 closed 수치는
  **달성 가능치 대비**로 읽어야 한다(예: 데모 NOOP 234 = 82%).
- **무OOD 도 100% 가 아니다** — 30 seed 에서 seed 23 실패, **97% ± 3**. 교착은 OOD 가 만드는 게 아니라
  원래 있다. (n=22 까지는 100% 였다 — 작은 표본의 100% 를 믿지 말 것.)
- **실패는 언제나 루트에서만.** 하위 조립체 7/7 은 어떤 실패 판에서도 done 이고, zone 없는 battery·fault
  판도 똑같이 루트에서 죽는다.
- **복구 장치가 있느냐가 결론을 바꾼다.** 같은 core zone 이 복구 사다리 OFF 하니스에서는 정체하고
  ON 에서는 NOOP 으로 완주했다. **두 하니스의 수치를 섞어 쓰면 안 된다.**
- 완주를 되살린 처방은 `DEMO_REFORM`(무진전 N스텝마다 팀 교착을 **결정 레이어로** 올림) +
  `DEMO_REFORM_MAX`(상한; 없으면 `handle_ood!` 뒤 `stall=0` 리셋 때문에 무한 반복).

---

## 7. 철회된 결론 — 이 목록을 먼저 읽어야 옛 문서를 안 믿는다

| 철회된 주장 | 어디에 있었나 | 진짜 사실 |
|---|---|---|
| mid-build Replace 완주는 **구조적 한계** | 2026-07-14 이전 | 정체성보존 hot-swap enact 로 완주(6/6). |
| "깊은 방전도 후반(≥0.58)엔 함대가 흡수 → NOOP" | `FIRE_TIME_RELABEL` §3-a | **틀림.** `_pick_battery_target` 이 진행도 0.51 부터 100% **주차된 예비**를 쐈다. 새 피커로 재라벨하면 NOOP 은 **6개 발화점 전부에서 미완주**. |
| "λ=15 로 튜닝했다" | `surrogate_hotswap.json` 메타 | λ 는 데이터로 식별 불가. 감도만 보고할 것. |
| `root_covered > 0 → 개입` (커버리지 규칙) | zone STEP 2 | **기하는 맞고 인과가 틀렸다.** 덮였다(coverage) ≠ 막혔다(blockage). |
| `battery_zone` 미완주는 중반 Replace 탓 | zone 부록 B-7/B-9 | **병렬 실행 아티팩트.** 단독 실행하면 3/3 완주. |
| "빈 도메인 → RelocateBuild 로 자동 격상" | zone 초기 설계 | 도메인이 비면 격상이 **도달 불가**(`:none` 조기 반환) → 전역을 직접 골라야 한다. |
| "seed 를 30까지 채운다" / "seed 확장은 불필요(LOSO)" | 양쪽 다 | **축 자체가 틀렸다** — §4 의 world/확률성 축 분리. |
| 옛 오라클 완주율 전반 | 2026-08-04 이전 전부 | **shim 버그로 자가복구가 꺼진 채 생성됐다**(아래). |

**2026-08-04 shim 버그** — `maybe_emit_reform_ood!` 는 `push_ood!` 만 하고 `record_ood_truth!` 를
하지 않는데, `event_context` 가 NL 매칭 실패 시 `last(log)` 를 집어 팀 교착 알람을 직전 사건의 종류로
덮어썼다 → CASCADE 로 NOOP → **자가복구가 한 번도 안 돌았다**(알람 499 → ReformTeam 0).
수정 후 같은 seed 에서 NOOP 팔이 245 미완주 → **291 완주**. `hz_*`·`rb_*`·`openworld` 의 완주율과
그에 의존한 결론은 전부 재생성 대상이다.

---

## 8. 함정 목록 — **재현하기 전에 반드시 읽을 것**

과거에 실제로 밟았고, 밟으면 결과가 조용히 틀리는 것들.

### 오라클 / 라벨
1. **RVO 를 끄면 정답이 뒤집힌다.** 싼 world 로 라벨을 만들 수 없다.
2. **control(무사건) 판이 없으면** 그 instance 가 유익한지 알 수 없다.
3. **후보는 연구 대상 사건에 대한 대응만 바꿔야 한다.**
4. **후보 집합은 엔진이 실제로 할 수 있는 것과 일치해야 한다.** 실행 불가능한 팔을 끼우는 것은
   결정을 재는 게 아니라 **동점을 제조**하는 것이다(`zoneblk 36/36 동점`의 원인).
5. **손으로 만든 하니스는 프로덕션 sim 과 갈라진다.** `run_one` 을 재사용할 것.
6. **속도 지표는 "실현된 makespan"** 이어야 한다.
7. **`_first_pending_assignment` 는 "일감 유무"가 아니라 "작업 경계"다.** 빌드가 굴러가면 로봇은 운반
   사슬 안에 있어 이 술어가 중반 이후 거의 전부 실패한다. 이 함정을 저장소에서 **세 번** 밟았다
   (fault 피커 · `_pick_idle_victim` · `_pick_battery_target`). 올바른 판정은
   **"안 닫힌 `FormTransportUnit` 팀의 멤버인가"**.
8. **에피소드 모드에는 대조군이 없다.** `gen_oracle_dataset.jl:1554` 가 `ctrl_*` 를 상수 sentinel 로
   박는다 → 그 덤프의 `admissible` 열은 **구조적으로 무의미**하다. 유해성 판정은 단일사건 모드로.
9. **`@info` 가 안 찍힌 0 은 "안 일어났다"가 아니다.** `DS_LOG` 기본값(warn)에서 오염 카운터가 전부
   0 으로 보인다. 확인하려면 `DS_LOG=info` 로 따로 돌릴 것.

### φ / 학습
10. **`decision_idx` 를 φ 에 넣지 말 것** — 이력 요약이다. 이거 하나로 "surrogate 가 baseline 을 이긴다"는 결론이 뒤집혔다.
11. **feature 목록을 첫 행에서 뽑지 말 것** — 첫 instance 가 zoneblk 이면 SoC 블록 **전체가 사라진다**(실측 38/66행 상실). 합집합을 쓸 것.
12. **결측을 0.0 으로 채우지 말 것** — `soc=0.0` 은 "방전"이라는 유효한 값이다. `-1.0`(N/A 규약)을 쓸 것.
13. **글롭 오염** — `ep*.jsonl` 은 구 데이터까지 빨아들이고, 없는 열이 0 으로 채워져 **가짜 신호**가 된다.
14. **value-residual 은 drift 신호가 아니다**(CUSUM spurious 남발). **covariate-novelty** 가 맞는 신호.
15. **`len(g)==5` 로 instance 를 거르지 말 것.** `DS_VALID_ONLY` 라벨은 유효 팔이 2~3개뿐이라 5를 영영
    못 채운다 → 새 라벨이 통째로 폐기된다(실측 126 중 60 통과, 그 60 은 전부 옛 덤프).
    `instance_arms_complete(g)` 를 쓸 것. 같은 버그가 `e1_analyze.py`·`dspy_service.py`·
    `export_surrogate.py`·`ladder.py` 네 곳에 있었다.
16. **instance ID 는 심각도를 인코딩하지 않는다.** 여러 rung 폴더를 합쳐 `instance` 로만 그룹핑하면
    세 칸이 한 instance 로 병합돼 사다리가 사라진다(실측: battery 12 → 4, 교차 판정이 뒤집힘).
    출처 폴더를 그룹 키에 포함시킬 것.

### 평가
17. **동점을 빼고 재라.** `argmin` 이 동점을 첫 원소(=NOOP)로 깨서 정답분포가 왜곡된다.
18. **표본이 작으면 판정하지 말 것.** 결정적 instance 5개에서 순위적중 1.00 이 나와 "φ 충분"이 찍힌 적이 있다.
19. **베이스라인 없이 subopt_norm 을 해석하지 말 것.**
20. **MC 노이즈에는 대조군을 둘 것.** 중복 arm(정의상 같은 정책)이 노이즈 바닥을 준다.
21. **subopt_norm 은 λ 를 가로질러 비교하면 안 된다** — `span` 정규화 때문에 λ 가 크면 작아 보인다.
    → 이 함정이 §4 "지표 용어" 교체의 직접적 이유다. 헤드라인은 λ 에 오염되지 않는
    `excess_cost`·`optimal_action_rate` 로 낸다.
22. **피해가 `closed` 가 아니라 `makespan` 에만 있는 사건이 있다.** 구역이 시간을 2.1배로 늘리는데
    closed 는 291 로 동일했다. 채널을 하나만 보면 통째로 안 보인다.
    실측 재확인(2026-08-06): `always-Replace` 의 오답은 **노드 손해 0.0 · 시간 손해 0.1 s** 이고
    실제 대가는 전부 `d_cost`(스페어) 쪽에 있었다. **네 축을 다 찍어야 한다.**

### 시뮬 설정
23. **배치 경계 58** — 이 빌드는 첫 배치에서 closed 0→58 로 점프한다. `closed∈[10,16]` 을 예약해도
    실제로는 58 에서 발화한다 → early/late 두 축이 같은 시점으로 **붕괴**한다.
24. **너무 늦추면 fault 가 안 터지고 동점률이 95% 로 치솟는다.** 실측 권장구간 **[55,130]**.
25. **동점률은 완주율의 함수다**(완주 26%→동점 53% / 완주 5%→동점 85%, 실측).
26. **MTBF 는 빌드 길이에 맞출 것** (이 하니스 빌드 ≈ 20 시뮬초). 60/45 는 함대 전멸, 500/500 이 적정.
27. **`DS_EP_LO/HI` 는 에피소드 모드에서만 동작한다.** 단일사건 유닛 모드는 이 창을 무시한다.
28. **`DS_NOPROG` 를 유닛 모드 값(30000)에서 에피소드 모드로 복사하지 말 것.** 에피소드 모드는 8000.
    (단, 완주율 0% 자체는 이 캡 탓이 **아니다** — 8000/30000 결과가 바이트 단위로 동일했다.)
29. **`ep_[abg]`(창[8,60])는 τ=0 이 99% 라 순차 데이터가 아니다.** T2/커플링 논의에 쓰지 말 것.

### 운영
30. **★ 이 트윈의 런을 동시에 돌려 비교하지 말 것.** `run_lego_demo` 는 **HiGHS MILP**(멀티스레드 +
    시간제한 탐색)로 스케줄을 푼다 → CPU 경합이 다르면 **다른 스케줄**이 나온다. 실측: 같은 케이스가
    동시 실행에서 INCOMPLETE 255, 단독 실행에서 COMPLETE 277(3/3 재현). "정책 비교"가 "다른 두 세계
    비교"가 된다. 순차 하니스는 안전하다.
31. **병렬 2개 상한** (프로세스당 ~2.5 GB, `DS_STACK=1000000000`). lane 병렬은 16GB 머신에서도 OOM 난다.
32. **스크립트명으로 프로세스를 죽이는 감시기 금지** — 나중에 띄운 같은 스크립트까지 죽인다.
33. **인라인 python 은 `PYTHONIOENCODING=utf-8`**, 분석 진입점은 `encoding="utf-8"` 명시
    (Windows 기본 cp949 로 열려 `UnicodeDecodeError`).
34. **PowerShell `Tee-Object` 로그는 UTF-16LE** — bash `tail`/`grep` 이 안 걸린다.
35. **패치는 heredoc `assert` 말고 Edit 도구로** — 백그라운드에서 assert 실패가 묻힌다.

---

## 9. 문서 지도

| 파일 | 무엇 |
|---|---|
| **`STATUS.md`** | **현재 상태 · 다음 할 일 · 재개 지점** |
| `RESULTS.md` | E1~E4 측정 원본 |
| `EVALUATION.md` | 채점 방식 정의(`e1_analyze.py` 등이 참조) |
| `DESIGN_ASSIMILATION.md` | C1~C4 정의 + LLM 실측 원본 (`policy.jl` 이 참조) |
| `PLAN_ACTION_GROWTH.md` | 다음 계획 (행동공간 성장 폐루프) |
| `RELOCATEBUILD_2026-08-03.md` | 매크로 7 구현·검증 (`verifier.jl` 이 참조) |
| `ZONE_REDESIGN_STEP1_7_2026-08-05.md` | 구역 결정 재설계 STEP 1~11 전문 (`render_demo.jl` 이 참조) |
| `BATTERY_FAULT_REDESIGN_2026-08-05.md` | 배터리 재설계 + λ/SwapBattery 결정 (한글·영문 병기) |
| `FIRE_TIME_RELABEL_2026-08-05.md` | 발화 시점 재라벨링 (`LABELING_MANUAL.md` 이 참조) |

**상위 문서**: `../MDP_DESIGN_FROM_SCRATCH.md`(MDP 정식화) · `../LABELING_MANUAL.md`(라벨링 절차) ·
`../artifacts_mdp/OVERNIGHT_REPORT.md` · `../artifacts_openworld/README.md`

**이번 통합(2026-08-06)에서 흡수·삭제한 것 (7개)** — 전부 git 에 있으므로
`git checkout HEAD~1 -- wm4spacecraft_manufacturing/md/<파일>` 로 복구 가능:

`NIGHT_2026-08-02.md` `MORNING_2026-08-03.md` `PLAN_0804.md` `NIGHT_2026-08-04.md`
`PLAN_COMPLETION.md` `DUMP_SCHEMA.md` `ZONE_BLOCKAGE_STEP8_11_2026-08-05.md`

흡수 위치: 야간·아침 로그의 확정 결과 → §3 / 정정 → §7 / 함정 → §8;
`DUMP_SCHEMA` → §5(2026-08-02 이후 스키마가 바뀌어 원문은 이미 틀린 상태였다);
`PLAN_COMPLETION`(완주 조사 S0~S4) → §6 + `STATUS.md`;
`ZONE_BLOCKAGE_STEP8_11` → `ZONE_REDESIGN_STEP1_7` 의 STEP 8~11 절로 이어붙임(원래 연속된 문서).
