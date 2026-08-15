# 4정책 비교표 — 검증본 + 행동집합 폐쇄 전/후 델타 (2026-08-16)

> 현행 세대 표 = `artifacts_4pol/COMPARE.md` · `artifacts_4pol/compare.html`
> 현행 세대 서술 = `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`
> 직전 세대 = `md/RESULTS_DP_BACKWARD_2026-08-15.md` (행동집합 폐쇄 **전**)
> 코드 세대 = `ff602d52` + `5dd29dae` · 스윕 커밋 `b3c878c7`
> 목적함수 세대 = `2026-08-13-global-kappa-precedence` (이번 사이클에 **안 갈렸다**)
>
> 이 문서는 **새 측정이 아니다.** 발행된 표를 원자료에서 재계산해 검증하고,
> 직전 세대와의 차이를 한 곳에 모은 것이다.

---

## 1. 비교표 (현행 세대)

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
| **합계 (7 case)** | **207/210** | **207/210** | **198/210** | **203/210** |

완주는 CANONICAL 이 앞서지만(207) 그 열은 45.2 s · 556 J 를 쓴다 — LLM 은 203 완주를
32.0 s · 456 J 로, SURROGATE 는 198 을 29.8 s · 476 J 로 낸다. **완주율만 보면 이 대비가
통째로 안 보인다.**

### 1-A. 검증 (이 문서가 새로 한 유일한 일)

`results_4pol/*.jsonl` **840행**(7 case × 30 seed × 4 policy)을 발행 스크립트와 무관하게
독립 집계했고, **28개 칸 + 4개 합계 전부가 자릿수까지 일치**한다.

| 검증 항목 | 결과 |
|---|---|
| 칸 재계산 일치 | 28/28 · 합계 4/4 ✅ |
| `objective_hash` 단일 | 840/840 (현행 `objective.json` 과 일치) ✅ |
| geometry 단일 | `depot_distance 20.0 · fixed · station_keeping` ✅ |
| 시드 커버리지 | 각 (case, policy) 마다 `ood_seed` 1‥30 중복 없음 ✅ |
| `world_seed` | 전 행 `1` 고정 ✅ |

재현:

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python - <<'EOF'
import json, statistics
for ck in ["battery","fault","zone","fault_battery","fault_zone","battery_zone","all"]:
    rows = [json.loads(l) for l in open(f"results_4pol/{ck}.jsonl")]
    for p in ["dp","canonical","surrogate","dspy"]:
        rs   = [r for r in rows if r["policy"] == p]
        comp = [r for r in rs if r["complete"]]
        bt   = statistics.mean(r["sim_seconds"] for r in comp) if comp else float("nan")
        e    = statistics.mean(r["battery"]["energy_per_closed"] for r in rs)
        print(f"{ck:14s} {p:10s} {len(comp):2d}/{len(rs)}  {bt:5.1f} s  {e:5.1f} J")
EOF
```

> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장 후보**다 — 실행 가능한 온라인 정책이 아니다.
> 측정된 φ̃ 격자 위의 진짜 Bellman backward induction 이고(`V(goal)=0`, `Q(s,a)=mean[c+V(s')]`),
> 분해는 판마다 `Σc + terminal == J` 로 기계 검사된다.
>
> **build time 은 완주한 판만 평균한다**(생존자 편향). J/closed 는 미완주 판에서도 정의된다.
>
> **§8.7 gap** — 실행 정책이 DP 의 V 보다 좋은 (칸,정책) 쌍 108/121 = **89.3%**.
> 0 이 아니므로 DP 열을 '천장' 이라 부르지 않는다.
>
> **DP 격자 커버리지** 64/65 관측 칸 = 98.5% · a\* 미확정(동점) 28칸 · 단일팔 19칸 · 채점불가 0칸.

---

## 2. 행동집합을 닫기 전 / 후

같은 7 case × 30 seed 위에서의 직전 세대(2026-08-15) 대비.

| CONTROLLER | 완주 / 210 | build time (7 case 칸 평균, sim 초) | energy (7 case 칸 평균, J/closed) |
|---|---|---|---|
| DP | 209 → **207** (−2) | 32.9 → 44.6 (**+11.7**) | 398 → 534 (**+136**) |
| CANONICAL | 207 → **207** (±0) | 45.2 → 45.2 (±0.0) | 556 → 556 (±0) |
| SURROGATE | 190 → **198** (**+8**) | 26.6 → 29.8 (+3.2) | 536 → 476 (**−60**) |
| LLM | 198 → **203** (**+5**) | 28.6 → 32.0 (+3.4) | 441 → 456 (+15) |

> 칸 평균은 7 개 case 셀의 **비가중 평균**이다(판 단위 pooled 평균이 아니다) — 두 세대의
> 발행된 표에서 같은 방식으로 계산해 비교 가능하게 맞춘 값이다. 완주 합계는 판 단위 실수다.

### 2-A. case 별 전체 델타

`완주 08-15→08-16 · build 08-15→08-16 · J/closed 08-15→08-16`

| FAILURE CASE | DP | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 29→29 · 21.8→25.6 s · 372→440 J | 29→29 · 26.0→26.0 · 451→451 | **29→30** · 26.0→21.8 · **451→311** | 30→30 · 19.6→22.8 · 261→338 |
| Robot breakdown | **30→29** · 21.1→24.7 · 300→424 | 29→29 · 26.0→26.0 · 451→451 | 29→29 · 26.0→26.0 · 451→451 | **26→28** · 32.4→26.1 · **599→490** |
| Keep-out zone | 30→30 · **33.3→56.4** · **361→492** | 30→30 · 56.4→56.4 · 492→492 | 30→30 · 28.8→39.0 · 418→456 | 30→30 · 28.6→30.9 · 390→362 |
| Breakdown + battery | **30→29** · 21.9→25.3 · 315→435 | 29→29 · 26.0→26.0 · 451→451 | 29→29 · 26.0→23.3 · 451→402 | 28→28 · 24.0→24.5 · 394→447 |
| Breakdown + zone | 30→30 · 41.7→58.7 · 453→618 | 30→30 · 59.8→59.8 · 656→656 | 26→26 · 26.9→31.3 · 597→624 | **26→29** · 37.9→45.6 · 639→577 |
| Battery + zone | 30→30 · 43.2→59.9 · 480→635 | 30→30 · 59.8→59.8 · 656→656 | **26→28** · 26.9→35.1 · 597→494 | 30→30 · 25.1→36.8 · 334→440 |
| All three at once | 30→30 · 47.4→61.4 · 503→695 | 30→30 · 62.7→62.7 · 733→733 | **21→26** · 25.5→32.3 · **789→595** | 28→28 · 32.3→37.1 · 468→537 |

---

## 3. 무엇이 이 차이를 만들었나

### 3-A. CANONICAL 열이 통제다

**일곱 case 전부 자릿수까지 동일하다.** 시뮬레이터 동역학·목적함수·기하가 안 바뀌었다는
기계적 증거이고, 따라서 나머지 세 열의 변화는 **행동집합 쪽에 귀속된다.** 이 통제가 없으면
아래 해석이 전부 성립하지 않는다.

### 3-B. SURROGATE 가 가장 크게 이득을 봤다 (+8 완주 · −60 J)

직전 세대에서 이 열이 약했던 이유는 **판단 오류가 아니라 고를 팔이 없어서**였다 — 배포
라벨셋의 macro support 가 `{0,1,2,7,8}` 이라 reform 사건에서 `NOOP` 밖에 못 골랐다
(`dspy_service.py:189`). `ReformTeam(4)` 이 들어오자 조합 case 붕괴가 회복된다:

- All three **21/30 → 26/30**, 789 → 595 J
- Battery + zone 26/30 → 28/30, 597 → 494 J
- Battery depletion 29/30 → 30/30, 451 → **311 J** (−31%)

### 3-C. LLM 은 완주가 늘고(+5) 에너지는 약간 나빠졌다(+15 J)

완주 이득은 zone 이 낀 case 에 몰려 있고(Breakdown+zone 26→29), 에너지 악화는 battery 계열에
몰려 있다(Battery+zone 334→440 J, Battery depletion 261→338 J). 팔이 늘면서 **개입 자체가
늘어난 대가**다. 반대로 Robot breakdown 은 26→28 완주에 599→490 J 로 양쪽 다 좋아졌다.

### 3-D. DP 열은 오히려 나빠졌다 (−2 완주 · +136 J) — 알고리즘이 아니라 표가 바뀌었다

팔이 늘자 동점 칸이 늘고, dp 레인이 **표를 실제로 조회해 쓴 비율이 떨어졌다**:

| | 2026-08-15 | 2026-08-16 |
|---|---|---|
| 결정 수 | 1202 | 1502 |
| 표 조회 성공 | 351 (**29.2%**) | 116 (**7.7%**) |
| `tie_unresolved` | 469 (39.0%) | 545 (36.3%) |
| `single_arm` | 382 (31.8%) | 841 (56.0%) |
| a\* 미확정(동점) 칸 | 22 | 28 |

표를 덜 쓰니 배경 정책(canonical) 폴백에 가까워지고, 실제로 DP 의 build time·에너지가
CANONICAL 쪽으로 끌려갔다 — Keep-out zone 은 33.3 s·361 J 에서 **56.4 s·492 J** 로,
CANONICAL 의 그 칸(56.4 s·492 J)과 **완전히 같아졌다.**

### 3-E. 폐쇄가 실제 행동으로 내려왔다는 직접 증거

현행 세대 840판의 전 결정을 집계하면, 두 학습 레인이 **일곱 case 전부에서** `ReformTeam` 을
발화한다. 직전 세대에서는 그 팔이 메뉴에 아예 없었다.

| case | SURROGATE 가 고른 팔 | LLM 이 고른 팔 |
|---|---|---|
| battery | Replace 48 · SwapBattery 72 · **ReformTeam 3** | Replace 75 · SwapBattery 45 · **ReformTeam 4** |
| fault | Replace 120 · **ReformTeam 17** | Replace 119 · **ReformTeam 29** |
| zone | RelocateBuild 104 · NOOP 16 · **ReformTeam 50** | NOOP 70 · RelocateBuild 50 · **ReformTeam 40** |
| fault_battery | Replace 89 · SwapBattery 31 · **ReformTeam 14** | Replace 95 · SwapBattery 24 · **ReformTeam 28** |
| fault_zone | Replace 58 · RelocateBuild 55 · NOOP 4 · **ReformTeam 61** | Replace 59 · NOOP 39 · RelocateBuild 20 · **ReformTeam 99** |
| battery_zone | Replace 24 · RelocateBuild 54 · SwapBattery 34 · NOOP 6 · **ReformTeam 58** | Replace 37 · NOOP 40 · SwapBattery 23 · RelocateBuild 20 · **ReformTeam 64** |
| all | Replace 52 · RelocateBuild 33 · SwapBattery 26 · NOOP 6 · **ReformTeam 75** | Replace 68 · RelocateBuild 21 · SwapBattery 12 · NOOP 17 · **ReformTeam 76** |

### 3-F. 그런데 §8.7 gap 은 안 줄었다 — 87.6% → 89.3%

| 축 | 2026-08-15 | 2026-08-16 | |
|---|---|---|---|
| 전체 | 106/121 = 87.6% | 108/121 = **89.3%** | 악화 |
| **Reform** | 13/13 = **100%** | 12/13 = **92.3%** | **개선 — 1차 판정 충족** |
| Fault | 27/33 = 81.8% | 25/33 = **75.8%** | 개선 |
| Battery | 43/52 = 82.7% | 48/52 = **92.3%** | 악화 |
| Zone | 23/23 = 100% | 23/23 = 100% | 변화 없음 |

Reform 축의 100% 는 *측정*이 아니라 **단위 오류에 가까운 것**이었다 — 실행 레인이 그 사건에
`ReformTeam` 을 1182회 집행하는데 DP 는 그 팔을 볼 수조차 없었다. 지금은 메뉴에 있고 그런데도
12/13 이 남으므로, 이건 진짜 측정이다.

남은 원인은 **전이 표본이 상수-팔 rollout 에서만 나온다**는 구조적 한계 하나로 좁혀졌다
(표집 판 완주율 19.5% → 16.9%, V 중앙값 4418.6 → 4743.6). **다음 사이클 1순위 = 1-step
deviation 표집.**

---

## 4. 매크로 집합의 실제 상태 — 통일된 집합은 `{1,2,3,4,7,8}` 이 아니다

세 층이 서로 다른 집합을 본다.

| 층 | 집합 | 크기 | 단서 |
|---|---|---|---|
| `action_registry.json` (단일 진실원) | `{0,1,2,3,4,7,8}` + 게이트 `{5,6}` | 9 | 5·6 은 `DS_COMBO_ARMS=1` 에서만 열린다 |
| 배포 라벨셋 support (surrogate 학습 입력) | `{0,1,2,4,5,6,7,8}` | 8 | `relabel_2026-08-16.jsonl` 872행/260 inst → **fired 필터 후 844행/232 inst** |
| 두 학습 레인이 **실제 집행한** 팔 | `{0,1,4,7,8}` | 5 | 840판 전 결정 집계 (§3-E) |

- **`ForbidZone(3)` 은 라벨셋에 0행이다.** 이유가 직전 세대와 **달라졌다** — 팔 메뉴가 막는
  것이 아니라 **도메인이 비어 있다**(`n_restage_feasible == 0`, zone 160행 전부). 그래서
  집합에 3 을 넣으면 실제로는 **재지 않은 팔**을 넣는 것이 된다.
- **새로 열린 5·6 은 정보량이 0이다.** 65/65 instance 에서 매크로 5 ≡ 4, 6 ≡ 2 로
  `closed·complete·makespan·energy_J·n_stalled` 가 전부 같다. 추가 primitive
  (`ForbidAgent`, `ForbidWindow`)가 엔진에서 집행되지 않기 때문이다. 결과적으로 라벨 844행 중
  **130행(15.4%)이 기존 팔의 복제**이고 surrogate 손실에서 이중 계수된다.
  다음 라벨 생성에서는 `DS_COMBO_ARMS=0` 이 옳다.
- **`Deprioritize(2)` 는 라벨에 125행 있지만 실행 레인에서 0회 선택됐다.**
- 라벨 파일의 fired 필터(`eval_surrogate_v2.load_rows`): 872행/260 inst 중 미발화 stub 28행을
  걸러 **844행/232 inst** 가 학습에 들어간다. `/health` 가 찍는 844/232 는 그 필터 **이후** 값이고,
  CLAUDE.md 의 872/260 은 파일 원본 값이다 — 둘 다 맞다.

**그러므로 이번 세대가 실제로 새로 얻은 팔은 `ReformTeam(4)` 하나다.** §2 의 완주 +8 / +5 는
전부 그 한 팔의 몫으로 읽는 것이 맞다.

---

## 5. 이 숫자를 인용하기 전에

- **build time 은 생존자 편향이 있다** — 완주한 판만 평균한다. 완주 수가 다른 두 열의
  build time 을 직접 비교하면 안 된다. J/closed 는 미완주 판에서도 정의되므로 그쪽이 더 공정하다.
- **라벨 레인은 아직 재현되지 않는다.** 08-14 판과 겹치는 365행 중 **4행**이 재실행에서 다른
  결과를 냈다(전부 fault sev1.0 macro=1, J 최대 900 변동). 따라서 §2 의 델타를 **전부** 설계
  변경의 효과로 귀속시킬 수 없다. 반대로 **표집 레인은 재현됐다** — 공유하는 다섯 팔의
  완주율이 소수점까지 일치.
- **kind 상수정책이 학습 여지의 97.7% 를 먹는다.** instance별 oracle J 6109.34 vs kind별
  상수정책 6228.78 vs 항상-NOOP 11226.64. "모델이 상태를 보고 macro 를 고르는 법을 배웠다" 는
  주장은 이 라벨로는 세울 수 없다(결과 문서 §6-E).
- **`ReformTeam` 팔이 표집 판의 15.5% 에서 엔진을 죽인다**
  (`AssertionError: has_edge(scene_tree, agent, robot_id)`, 표집 실패 13건 전부 arm 4).
  Reform 축이 다른 축보다 그만큼 얇게 표집됐다.
- **DP 열은 천장이 아니다.** §8.7 gap 이 89.3% 로 0 이 아니므로 이 열을 상한으로 인용하면 안 된다.
  dp **레인**의 실현 결과 자체는 유효한 실행 결과다 — 천장이 아닌 것은 V 다.
- **reform 축의 신호는 스페어 한 비트와 confound 돼 있다** — `ReformTeam` 이 NOOP 에 진 적이
  0회(17승 10무)이고, completion flip 7건이 `n_spare_cfg=3` instance 7건과 1:1 대응한다.
  "언제 쓸지 배웠다" 가 아니라 "스페어가 있으면 쓴다" 다(결과 문서 §6-F).
