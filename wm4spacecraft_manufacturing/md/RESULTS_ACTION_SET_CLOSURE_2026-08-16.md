# 행동집합을 닫았다 — 2026-08-16 결과

> 계획서: `2026-08-16-action-set-closure` (실행 완료·아카이브 — `docs/superpowers/plans/README.md`)
> 직전 세대: `md/RESULTS_DP_BACKWARD_2026-08-15.md` (지우지 않는다 — §4-D 가 이 작업의 동기다)
> 코드 세대: 커밋 `ff602d52`(어휘 파생) + `5dd29dae`(라벨셋·캐스케이드 수정).
> 목적함수 세대는 **안 갈렸다** (`objective.json` 무변경).

---

## 1. 한 줄 요약

**세 소비처가 같은 행동집합을 보게 만들었고, 그 결과 Reform 축의 "비교 자체가 성립하지 않던"
상태는 끝났다. 그러나 §8.7 gap 은 87.6% → 89.3% 로 줄지 않았다 — 계획서가 미리 이름 붙여 둔
원인 ③(전이 표본이 상수-팔 rollout 에서만 나온다)이 이제 **혼자 남아 지배한다.**

계획서의 1차 판정(Reform gap 이 100% 에서 내려왔는가)은 **충족**이다(100% → 92.3%).
2차 판정(표집 판 완주율이 19.5% 에서 올랐는가)은 **미충족**이다(19.5% → 16.9%). 계획서는 이
둘이 이렇게 갈릴 때 무슨 일이 벌어지는지도 미리 적어 두었다 — "이게 안 오르면 V 중앙값이
여전히 4000 대일 것이고, 그러면 gap 도 안 줄어든다." V 중앙값은 4743.6 이고, gap 은 안 줄었다.

---

## 2. 비교표


각 칸 — 위: 30 시드 중 완주한 판 수 · 아래: 완주판 평균 build time(sim 초) · 에너지(J/closed)

| FAILURE CASE | **DP**<br><sub>offline value-table lookup · NOT a ceiling (§8.7)</sub> | **CANONICAL**<br><sub>hand-written rule</sub> | **SURROGATE**<br><sub>random forest</sub> | **LLM**<br><sub>DSPy</sub> |
|---|---|---|---|---|
| Battery depletion | **29/30**<br><sub>25.6 s · 440 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **30/30**<br><sub>21.8 s · 311 J</sub> | **30/30**<br><sub>22.8 s · 338 J</sub> |
| Robot breakdown | **29/30**<br><sub>24.7 s · 424 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **28/30**<br><sub>26.1 s · 490 J</sub> |
| Keep-out zone | **30/30**<br><sub>56.4 s · 492 J</sub> | **30/30**<br><sub>56.4 s · 492 J</sub> | **30/30**<br><sub>39.0 s · 456 J</sub> | **30/30**<br><sub>30.9 s · 362 J</sub> |
| Breakdown + battery | **29/30**<br><sub>25.3 s · 435 J</sub> | **29/30**<br><sub>26.0 s · 451 J</sub> | **29/30**<br><sub>23.3 s · 402 J</sub> | **28/30**<br><sub>24.5 s · 447 J</sub> |
| Breakdown + zone | **30/30**<br><sub>58.7 s · 618 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **26/30**<br><sub>31.3 s · 624 J</sub> | **29/30**<br><sub>45.6 s · 577 J</sub> |
| Battery + zone | **30/30**<br><sub>59.9 s · 635 J</sub> | **30/30**<br><sub>59.8 s · 656 J</sub> | **28/30**<br><sub>35.1 s · 494 J</sub> | **30/30**<br><sub>36.8 s · 440 J</sub> |
| All three at once | **30/30**<br><sub>61.4 s · 695 J</sub> | **30/30**<br><sub>62.7 s · 733 J</sub> | **26/30**<br><sub>32.3 s · 595 J</sub> | **28/30**<br><sub>37.1 s · 537 J</sub> |

| 합계 (7 case) | 207/210 | 207/210 | 198/210 | 203/210 |
|---|---|---|---|---|

> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장 후보**다 — 실행 가능한 온라인 정책이 아니다. 이 표의 DP 는 측정된 φ̃ 격자 위의 **진짜 Bellman backward induction** 이다(`V(goal)=0`, `Q(s,a)=mean[c + V(s')]`). 구간 비용 `c` 는 J 의 완주 분기 형태로 고정되고 두 분기의 차액은 종단에서 정산되며, 그 분해는 판마다 `Σc + terminal == J` 로 기계 검사된다. 자세한 정의와 한계는 `dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.

> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 `—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.

> **DP 격자 커버리지** 64 / 65 관측 칸 = 98.5% · a\* 미확정(동점) 28칸 · 전부 채점불가 0칸 · 단일팔 19칸.

> **원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 121개; 비교 단위 = 그 칸부터의 **실현 cost-to-go**).** 실행 정책이 DP 의 V 보다 **좋은** 쌍 108개 = **89.3%**. 0 이 아니므로 이 표에서 **DP 열을 '천장' 이라 부르지 않는다.** 원인은 상수-팔이 아니다(V 는 진짜 backward induction 이다). 2026-08-15 실측에서 셋으로 갈렸다 — ① 표집 팔 메뉴에 실행 레인이 쓰는 매크로가 없는 축(ReformTeam) · ② φ̃ 추상화 손실 · ③ 전이 표본이 여전히 상수-팔 rollout 에서만 나온다는 구조적 한계. 쪼갠 수치는 `dp_oracle/gap_breakdown.py`, 해석은 `md/RESULTS_DP_BACKWARD_2026-08-15.md` §4-D. 다만 dp **레인**은 칸마다 a* 를 갈아 쓰므로 이 열의 실현 결과 자체는 유효한 실행 결과다.

> 목적함수 세대: `2026-08-13-global-kappa-precedence`. 지표는 `llm_ood_eval.py report` 가 계산한 값을 그대로 읽는다(이 스크립트는 배치만 한다).

---

## 3. 무엇이 실제로 바뀌었나

### 3-A. 어휘 — 세 소비처가 이제 한 곳에서 받는다

```
                            2026-08-15                  2026-08-16
action_registry.json        {0,1,2,3,4,7,8} (+5,6 게이트)   변화 없음 (단일 진실원)
실행 레인이 집행한 매크로      ReformTeam ×1182            ReformTeam ×1285
배포 라벨셋 support          {0,1,2,7,8}                 {0,1,2,4,5,6,7,8}
DP 표집 arm_menu()          {0,1,2,7,8} (하드코딩)         레지스트리 파생, 실행가능 7팔
```

세 번째 줄이 원인이고 네 번째 줄은 그 복사본이었다. 둘 다 없앴다.

**그런데 진짜 차단기는 계획서가 지목하지 않은 곳에 있었다.** `ood_mdp_shim.valid_actions` 는
팔 메뉴이기도 하지만 `action_to_proposal` 의 **문지기**이기도 하다
(`a in valid_actions(ctx) || return nothing`). `valid_actions(:fault)` 가 리터럴 `[0,1]` 인 한,
라벨 생성기에 매크로 4 를 시켜도 조용히 NOOP 팔로 무너진다. 라벨 격자만 고쳤다면 아무 효과도
없었을 것이다.

### 3-B. `reform` kind — 심는 사건이 아니라 2차 실패다

팀 교착은 주입할 수 있는 사건이 아니다. 스페어 인계(Replace) 뒤 다중로봇 운반팀이 형성을
못 끝내면서 생긴다. 그래서 새 주입기를 만들지 않고, 엔진이 이미 하고 있던 일을 연구 대상으로
잡았다 — `maybe_emit_reform_ood!`(`ood_injection.jl:645`)가 시뮬 루프에서 매 스텝 돌며 무진전이
`REFORM_INTERVAL` 배수에 닿으면 respec 큐에 NL 을 넣는다. `run_one` 은 그 간격을 `DS_REFORM=120`
으로 **데모와 같은 값**에 맞춰 놓았고, NL 문자열도 `run_demo.jl:739` 의 것과 한 글자도 같다.
= 계획서가 요구한 "같은 조건" 이 이미 성립해 있었다.

### 3-C. 캐스케이드 규칙이 그 팔을 무력화하고 있었다 (이 사이클에서 제일 비싼 발견)

`maybe_emit_reform_ood!` 에는 **dedup 이 없다.** 무진전이 이어지는 한 120스텝마다 다시 발화한다.
그런데 캐스케이드 규칙의 예외

```julia
ctx.type === :reform && return action_to_proposal(ctx, canonical_action(ctx))
```

가 조건 없이 걸려 있어서, **NOOP 팔의 판에서도 배경 정책이 120스텝 뒤에 ReformTeam 을
집행했다.** 팔 0 은 사실 "지연된 팔 4" 였다 — 그 주석이 막으려던 실패(팔이 바이트 동일해짐)를
그 줄 자신이 만들고 있었다. `kind !== :reform` 조건을 달았다.

| | 고치기 전 | 고친 뒤 |
|---|---|---|
| 팔이 갈린 reform instance | 1 / 7 | **17 / 27** |
| `complete` 가 뒤집힌 instance | 0 | **7** (closed 254→291, 에너지 −74%) |

### 3-D. 라벨 레인이 실행 레인과 다른 세계에서 재고 있었다

`DS_HOTSWAP` 을 안 켠 1차 런에서 fault 발화율이 **100% → 23%** 로 무너졌다(faultidle·battery·
zone 은 다른 피커를 써서 무영향). `run_demo.jl:557` 이 `set_hot_swap!(enabled=true)` 이고
RELABEL_20260814 행에도 그 도장이 찍혀 있다. 생성 스크립트에 명시했다.

---

## 4. 판정 — 계획서 §Task 4

### 4-A. 사건별 gap

| 축 | 2026-08-15 | 2026-08-16 | |
|---|---|---|---|
| 전체 | 106/121 = 87.6% | 108/121 = **89.3%** | 악화 |
| **Reform** | 13/13 = **100%** | 12/13 = **92.3%** | **개선 — 1차 판정 충족** |
| **Fault** | 27/33 = 81.8% | 25/33 = **75.8%** | 개선 |
| Battery | 43/52 = 82.7% | 48/52 = **92.3%** | 악화 |
| Zone | 23/23 = 100% | 23/23 = 100% | 변화 없음 |
| L0 만 | 105/111 = 94.6% | 109/111 = 98.2% | 악화 |

**Reform 축은 이제 "비교가 성립한다".** 2026-08-15 에는 실행 레인이 그 사건에 `ReformTeam` 을
1182회 집행하는데 DP 는 그 팔을 볼 수조차 없어서, 13/13 = 100% 는 *측정*이 아니라 *단위 오류에
가까운 것*이었다. 지금은 그 팔이 메뉴에 있고, 그런데도 12/13 이 남는다 — 이건 진짜 측정이다.

**Zone 축은 100% 그대로다.** 원인이 다르다. `RelocateBuild(7)` 은 **원래도 메뉴에 있었으므로**
그 축의 gap 은 애초에 행동집합 불일치가 아니었다. 실행 레인이 zone 사건에 집행한 것은
`NOOP ×477` 과 `RelocateBuild ×357` 로 둘 다 메뉴 안이다. 즉 Zone 축의 100% 는 처음부터
원인 ②·③ 의 몫이었고, 이번 변경이 건드릴 수 있는 것이 아니었다.

### 4-B. 2차 판정 — 표집 판 완주율

| | 2026-08-15 | 2026-08-16 |
|---|---|---|
| 표집 판 완주율 | 82/420 = 19.5% | **97/575 = 16.9%** |
| V 중앙값 | 4418.6 | **4743.6** |

**안 올랐다.** 팔별로 보면 왜인지가 바로 보인다:

| 팔 | 2026-08-15 | 2026-08-16 |
|---|---|---|
| NOOP | 0% | 0% |
| Deprioritize | 0% | 0% |
| RelocateBuild | 14.3% | 14.3% |
| Replace | 34.5% | 34.5% |
| SwapBattery | 48.8% | 48.8% |
| ForbidZone *(신규)* | — | 14.3% |
| ReformTeam *(신규)* | — | **4.2%** |

**공유하는 다섯 팔의 완주율이 소수점까지 같다.** 표집 레인이 재현됐다는 강한 증거다(라벨 레인은
그렇지 않다 — §6-G). 그리고 새로 넣은 두 팔이 둘 다 평균 아래라 전체 완주율을 끌어내렸다.

이것이 계획서 "실패해도 이상하지 않은 것 1" 이 예고한 그대로다: **팔을 고정해 판 전체를 굴리면
`ReformTeam` 은 reform 이 아닌 사건에 무의미하다.** 상수-팔 표집이라는 구조(원인 ③)가 상한을
건다. `gap_breakdown.py` §3(gap 이 큰 칸 상위 12)의 margin 이 전부 14800~14970 인 것이 그
흔적이다 — V 가 미완주 판의
값(≈ 10000 + 100·(total−closed))에 눌려 있고, 실행 레인은 같은 칸에서 20~60 을 낸다.

### 4-C. 백오프 레벨별 gap — 어디가 헐거운가

| 레벨 | 덜어낸 축 | gap |
|---|---|---|
| L0 | 없음 | 93/95 = 97.9% |
| L1 | `spares_b` | **8/19 = 42.1%** |
| L2 | `spares_b`, `prog_b` | 7/7 = 100% |

L1 이 유독 낮다. 스페어 수를 뭉개면 오히려 V 가 실행 레인과 겨룰 만해진다는 뜻이고, 이는
정밀 칸(L0)의 표본이 얇아 V 가 미완주 쪽으로 눌린다는 §4-B 의 진단과 같은 방향이다.

### 4-D. 이름을 붙이지 않는다

gap 이 0 이 아니므로 **DP 열 부제를 "ceiling" 으로 되돌리지 않는다.** 남은 원인은:

- **① 행동집합 불일치 — 해소됐다.** 메뉴 밖 매크로는 이제 5·6 뿐이고, 그 둘은 실행 레인이
  집행조차 못 한다(§6-A). 실행 레인이 실제로 집행하는 매크로는 전부 메뉴 안에 있다.
- **② φ̃ 추상화 손실 — 남아 있다.** §4-C 의 레벨별 대비가 그 크기의 하한이다.
- **③ 전이 표본이 상수-팔 rollout 에서만 나온다 — 이제 지배적이다.** §4-B. 1-step deviation
  표집이 필요하고, 그건 계획서가 범위 밖으로 못박은 다음 사이클 거리다.

---

## 5. 재실행 절차

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing

# (1) 라벨 재생성 — 52 샤드, 약 40분. DS_HOTSWAP=1 이 필수다(§3-D).
bash oracle/run_relabel_20260816.sh 52

# (2) surrogate 재학습 = 서비스 재시작. 어휘·라벨셋을 바꾸면 :8090 은 옛 모듈 상태를 들고 있다.
pkill -f "uvicorn dspy_service.*8090"
cd ../src/respec/llm_service && setsid ../../../.venv/bin/python -m uvicorn dspy_service:app \
  --host 127.0.0.1 --port 8090 >/tmp/svc.log 2>&1 < /dev/null &
curl -s http://127.0.0.1:8090/health | grep -i surrogate    # support 확인

# (3) 전이 표집 — 7 case x 12 seed x 7 팔 = 588 판. 26 워커에서 106분.
export DSPY_URL=http://127.0.0.1:8090
../.venv/bin/python dp_oracle/sample_grid.py --jobs 26 --seeds 1,2,3,4,5,6,7,8,9,10,11,12

# (4) backward induction. 백오프 없이 먼저 재고, 그 다음 켠다.
../.venv/bin/python dp_oracle/dp_solve.py --out dp_oracle/value_L0_nobackoff.json
../.venv/bin/python dp_oracle/dp_solve.py --backoff

# (5) 4정책 스윕. (3)+(5-1) 은 동시 실행이 실측 안전했다(합계 56 워커, 최대 51GB).
#     ⚠️ (5-2) 는 (5-1) 뒤여야 한다 — dp 레인이 value.json 을 조회한다.
#     ⚠️ dp 샤드는 **별도 트리**. run_shard.sh 도장이 (commit, policies) 쌍이다.
bash run_4pol_parallel.sh --jobs 30 --policies canonical,surrogate,dspy
bash run_4pol_parallel.sh --jobs 50 --policies dp --shards-dir results_4pol/shards_dp
bash finish_tables.sh

# (6) 판정
../.venv/bin/python dp_oracle/gap_breakdown.py
```

⚠️ **스윕이 도는 동안 커밋하지 않는다** — `run_shard.sh` 의 provenance 도장이 HEAD SHA 라
중간에 HEAD 가 바뀌면 한 스윕 안에서 세대가 갈린다. 편집은 괜찮다.
`sample_grid.py` 에는 그 도장이 **없으므로** 표집 중에는 커밋해도 된다.

---

## 6. 알려진 구멍 (숨기지 않고 재서 적는다)

### 6-A. 조합 팔 5·6 은 정보량이 0이다 — 추가 primitive 가 집행되지 않는다

이 사이클에서 처음 켰고(`DS_COMBO_ARMS=1`), 측정 결과:

```
매크로 5 = [ForbidAgent, ReformTeam]     ≡ 매크로 4 = [ReformTeam]        65/65 instance 동일
매크로 6 = [Deprioritize, ForbidWindow]  ≡ 매크로 2 = [Deprioritize]      65/65 instance 동일
        (closed · complete · makespan · energy_J · n_stalled 전부)
```

원인은 조합 의미론이 아니라 **추가 primitive 가 엔진에서 집행되지 않는 것**이다:

- `ForbidAgent` — `spec_dsl.jl` 에 타입만 있고 집행 경로가 없다. 설계 문서
  (`src/respec/docs/simulator_ood_1-1_robot_breakdown_design_2026-06-26.md`)가 "코어가 막혀
  e2e 미검증", "버그 보유" 라고 적어 놨다.
- `ForbidWindow` — 타이밍 전용 soft MILP 제약이고,
  `src/respec/docs/timing_respec_persistence_gap_2026-06-19.md` 가 테스트에서 **non-binding**
  이었고 commit 시 drop 된다고 기록한다.

귀결: 라벨 파일의 **15%(130행)가 기존 팔 4·2 의 복제**이고, surrogate 손실에서 그 두 팔이
이중 계수된다. `sample_grid.arm_menu()` 는 이 둘을 제외하고 **제외 사실을 이름으로 찍는다**
(실행 레인 `handle_ood!` 에 그 이름의 분기가 아예 없어서, 넣으면 NOOP 판의 사본이 된다).
**다음 사이클에서는 `DS_COMBO_ARMS=0` 이 옳다** — 그 두 primitive 를 실제로 집행하게 만들기
전까지는. 현재 값 1 은 커밋된 데이터셋을 재현하기 위한 것이다.

### 6-B. `ForbidZone(3)` 은 라벨셋에 0행이다 — 도메인이 실제로 비어 있다

이유가 2026-08-15 과 **달라졌다**. 팔 메뉴가 막는 것이 아니라 `_zone_arms_for` 의 결정 시점
진단이 `n_restage_feasible == 0` 을 보고한다. `restage_assembly!` 는 이미 시작된 조립체를
거부하는데, 이 빌드에서 그 술어는 `closed≈46` 부터 아무도 만족하지 못한다(shim 이 2026-08-03
에 실측으로 적어 둔 사실). zone 160행 전부 `zone_restage_feasible == 0` 이다.
ForbidZone 을 정말로 재려면 발화점이 아니라 **빌드 초반에 결정을 내리는 경로**가 필요하다
(`ZONE_DECIDE_DEFERRED` 를 끄거나 첫 배치를 쪼개거나). 계획 범위 밖이다.

### 6-C. `fire_target=20` 은 발화하지 않았다 (§6-B 를 노린 수단이었는데 실패했다)

실제 `closed_at_fire` = {46, 58, 250, ...}. 20 에 도달한 instance 가 **하나도 없다** —
트랙터가 첫 시뮬 배치에서 이미 ~58 노드를 닫고, 재시도 사다리는 목표점 **위쪽**으로만
올라가므로 58 아래는 원리적으로 못 잡는다. 부작용으로 f20 instance 상당수가 자기 `_f58`
쌍둥이와 **바이트 동일한 행**이 됐다(instance id 만 다르다) = CV fold 간 누설이고 instance
수를 부풀린다. 다음 사이클에서는 20 을 빼거나 다른 수단을 쓸 것.

### 6-D. `ReformTeam` 팔이 표집 판의 15.5% 에서 엔진을 죽인다

표집 실패 13건이 **전부 arm 4** 였다(71/84 성공, 다른 여섯 팔은 84/84).
`AssertionError: has_edge(scene_tree, agent, robot_id)` — `apply_cmd!(::FormTransportUnit)` 의
어서션으로, CLAUDE.md 와 `gen_oracle_dataset.jl` 이 이미 이름 붙여 둔 알려진 한계다.
행동집합을 닫으려고 넣은 그 팔이 정작 엔진을 죽이는 셈이라, **Reform 축이 다른 축보다 15%
얇게 표집됐다.**

### 6-E. kind 상수정책이 학습 여지의 대부분을 먹는다

평균 J — instance별 oracle **6109.34** vs **kind별 상수정책 6228.78** vs 항상-NOOP 11226.64.
즉 NOOP→oracle 밴드의 **97.7%** 를 상태를 한 비트도 안 보는 kind 상수정책이 이미 먹는다
(잔여 1.96%). kind별 잔여 gap: reform **0.0000** · battery 0.048 · fault 37.03 · zoneblk 316.26.
**"모델이 상태를 보고 macro 를 고르는 법을 배웠다" 는 주장은 이 라벨로 세울 수 없다.**

### 6-F. reform 축의 신호는 스페어 한 비트와 confound 돼 있다

`ReformTeam` 이 NOOP 에 진 적이 **0회**(17승 10무)라 조건부 판단이 필요 없고, 큰 이득
(completion flip) 7건은 발화한 `n_spare_cfg=3` instance 7건과 **1:1로 대응**한다.
"언제 ReformTeam 을 쓸지 배웠다" 가 아니라 "스페어가 있으면 쓴다" 다.

### 6-G. 재현성 결함이 라벨 레인에 남아 있다

2026-08-14 판과 겹치는 (instance, macro) 365행 중 **4행이 재실행에서 다른 결과**를 냈다
(전부 fault sev1.0 macro=1, closed 218→216 등, J 최대 900 변동). 그래서 두 라벨셋의 차이를
전부 "설계 변경의 효과" 로 귀속시킬 수 없다. 반대로 **표집 레인은 재현됐다**(§4-B 의 팔별
완주율이 다섯 팔 모두 소수점까지 일치).

### 6-H. `e1_analyze.featurize` 의 kind one-hot 에 `reform` 이 없다

`["fault","battery","zone","zoneblk"]` 뿐이라 reform 행은 all-zero kind 벡터가 된다.
**배포·학습 경로에는 영향이 없다** — `eval_surrogate_v2.load_rows` 는 `e1_analyze.load()` 를
JSON 파싱(Inf/NaN 복원)에만 쓰고, 특징은 kind-agnostic 인 `surrogate_features` 가 만든다.
레거시 분석 경로 한정 문제라 고치지 않고 기록만 한다(one-hot 폭을 바꾸면 그쪽 차원이 바뀐다).

### 6-I. J 는 이봉분포다

완주 ~20 / 미완주 ~15000. 미완주 행은 `makespan="Inf"` 라 J = `10000 + 100·(total−closed)`
= closed 의 계단함수다. R²·MAE 류 회귀 지표는 completion 이진 분류를 맞힌 것에 불과할 수 있다.

1. **DP 격자 커버리지.** 표에 오른 칸 64 / 관측 칸 65 = **98.5%**. 다만 결정 빈도가 편중돼 있어 **결정 기준 커버리지는 3951/3953 = 99.9%** 다. 둘 중 하나만 적으면 오독을 만든다.
   - a\* 미확정(동점) **28칸** · 전부 J 채점불가 **0칸** · 팔이 하나뿐 **19칸**. 동점은 실패가 아니라 *없는 확신을 만들지 않은 것*이다.
   - **solver = backward induction.** dangling 전이 **0건**(사유별 {}) · 값을 못 낸 칸 **0칸** · value iteration 수렴 실패 **0칸**(최대 반복 234, tol 1e-09) · 계층 백오프 **ON**.
   - dangling 은 다음 칸의 V 를 **0 으로 두지 않은 결과**다. 0 으로 두면 미지의 미래가 공짜가 되어 표 밖으로 나가는 팔이 언제나 이긴다. 그 (칸,팔) 의 Q 를 미정의로 남기는 쪽을 택했고, 그래서 커버리지가 그만큼 낮게 나온다.
2. **dp 레인이 표를 실제로 쓴 비율.** 결정 1502건 중:
   - `single_arm` 841건 (56.0%)
   - `tie_unresolved` 545건 (36.3%)
   - `표 조회 성공` 116건 (7.7%)
   조용한 폴백이 없도록 이유를 네 가지로 구분해 행에 남긴다 — `not_in_table`(표집이 그 칸에 안 닿음)과 `tie_unresolved`(닿았지만 동점)는 전혀 다른 사건이라, 뭉뚱그리면 낮은 커버리지가 '알고리즘이 판단을 보류했다' 로 오독된다.
3. **원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 121개; 비교 단위 = 그 칸부터의 실현 cost-to-go).** 실행 정책이 DP 의 V 보다 **더 좋은** 쌍 108개 = **89.3%**.
   > 0 이 아니므로 **DP 열을 '천장' 이라고 부르지 않는다.** 원인이 상수-팔은 **아니다** — V 는 진짜 backward induction 에서 나온다. 그러나 남는 원인이 φ̃ 추상화 손실 **하나가 아니다**: 2026-08-15 실측에서 셋으로 갈렸다 — ① 표집 팔 메뉴에 실행 레인이 쓰는 매크로가 없는 축(ReformTeam) · ② φ̃ 추상화 손실 · ③ 전이 표본이 여전히 상수-팔 rollout 에서만 나온다는 구조적 한계. 쪼갠 수치는 `dp_oracle/gap_breakdown.py` 가 내고, 해석은 결과 문서 §4-D 에 있다.
   > **구분할 것**: dp *레인*은 칸마다 a\* 를 갈아 쓰므로 표의 dp 열 **실현 결과는 유효한 실행 결과**이고, 천장이 아닌 것은 V 다.
4. **`zone_s=cov` 는 표본 0.** §5-D. 기존 zone 규칙의 알려진 결함을 이 DP 도 못 고친다.
5. **credit assignment 는 닫혔다.** 판 단위 J 를 결정 개수로 나눠 쓰던 문제는 구간 비용 `c_k` 로 해소됐고, 그 분해는 판마다 `c_prefix + Σc + terminal == J` 로 기계 검사된다. 대신 새로 생긴 실패 모드가 **dangling**(위 1번)이다.

---

## 7. 게이트

| 게이트 | 결과 |
|---|---|
| `audit_objective.py (9/9)` | exit 0 ✅ |
| `audit_action_vocab.py (6/6)` | exit 0 ✅ |
| `test_surrogate_support.py` | exit 0 ✅ |
| `test_ceilings_degrade.py (신규)` | exit 0 ✅ |
| `dp_oracle/test_dp_solve.py (backward induction 포함)` | exit 0 ✅ |
| `dp_oracle/test_cost_decomposition.py (신규, 분해 충실성 차단 게이트)` | exit 0 ✅ |
| `dp_oracle/test_cellkey_parity.py (신규, Julia↔Python)` | exit 0 ✅ |
| `dp_oracle/test_derive_grid.py 대체: derive_grid 재실행 결정성` | exit 0 ✅ |
| `tools/monitor/test_narrate.jl (신규)` | exit 0 ✅ |
| `tools/monitor/test_lane_select.jl (신규)` | exit 0 ✅ |
| `tools/test_policy_escalation.jl (기존 회귀)` | exit 0 ✅ |

---

## 8. 이 사이클에서 하지 않은 것

- **1-step deviation 표집** — §4-D 의 원인 ③ 을 고치는 유일한 수단이고, 계획서가 범위 밖으로
  못박았다. 이제 그것이 남은 gap 의 지배적 부분이므로 **다음 사이클의 1순위**다.
- `reference_policy.py` 대체 · surrogate 를 φ̃ 위에 재학습 — 원 설계가 범위 밖으로 못박음.
- oracle 천장 격자 재라벨 — COMPARE 4열을 바꾸지 않는다.
- `ForbidAgent`·`ForbidWindow` 집행 경로 구현 (§6-A).
- 빌드 초반 zone 결정 경로 (§6-B).
