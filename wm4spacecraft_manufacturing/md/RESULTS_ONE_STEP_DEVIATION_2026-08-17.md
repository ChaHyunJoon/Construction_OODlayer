> 🔴 **구세대** — SwapBattery 가 공짜이던 판. 현행: md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md

# 1-step deviation 표집 — 결과와 판정

> **계획서**: `docs/superpowers/plans/2026-08-17-dp-one-step-deviation.md`
> **코드 세대**: `c5c4fb63`(deviation 훅) + `28158a49`(표집기) + `aff13715`(표본·표) + `3e492c21`(dp 재스윕)
> **목적함수 세대**: `2026-08-13-global-kappa-precedence` — `objective.json` 무변경.
> **실행일**: 시스템 시각 기준 2026-08-15. 파일명의 날짜는 계획서가 지정한 것을 그대로 쓴다
> (이 레포의 결과 세대 번호는 시스템 시계보다 앞서 있다 — `RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`
> 가 이미 직전 세대다).
> **직전 세대**: `md/RESULTS_ACTION_SET_CLOSURE_2026-08-16.md`. 그 문서 §4-B 가 이 작업의 동기다.

---

## 1. 한 줄 요약

**1차 판정(#1·#3)은 목표 수치에 미달했다. 2차 판정(#5)도 미달했다.**
그러나 이 사이클이 겨냥한 **메커니즘은 작동했고 그것이 실측으로 보인다** — 표집 판 완주율이
16.9% → 86.0% 로 올랐고, dp 레인의 `single_arm`(비교할 팔이 하나뿐이라 argmin 이 성립하지
않는 결정)이 **56.0% → 8.3%** 로 무너졌다. 목표에 미달한 이유는 구현 오류가 아니라
**1-step deviation 의 구성상 한계**이고, 아래 §4 에 그 논증을 적는다.

🔴 **그러나 이 세대의 가장 중요한 결과는 음(陰)의 결과다 — 표가 매크로 하나로 주저앉았다.**
#4(표 조회 성공률) 가 7.7% → 19.3% 로 오른 것을 진전으로만 읽으면 안 된다. **새 표의 확정
19칸이 권하는 매크로는 `Replace` 하나뿐**이고(구세대 17칸은 `SwapBattery 11 · ReformTeam 3 ·
Replace 3` 으로 셋이었다), 조회에 성공한 결정 **291건이 전부 `Replace`** 였으며 그 291건에서
canonical 규칙도 전부 `Replace` 를 골랐다. 귀결로 **dp 판 210개가 canonical 210개와 완전히
동일**하고(makespan·closed·complete·매크로 열 전부), 이 브랜치 자신의 diff 가 그 대가를 적고
있다 — `artifacts_4pol/FINAL.md` 의 dp battery-case 매크로 정확도가 **9% (11/120) → 0% (0/120)**.
즉 **행동 다양성을 잃고 조회율을 샀다.** 상세와 검증은 §3-D.

**DP 열의 부제는 "ceiling" 으로 되돌리지 않는다.** §8.7 gap 이 83.5% 로 0 이 아니다.

---

## 2. 비교표 — DP 열만 바뀌었다

7 case × 30 seed × 4 policy. 출처 `artifacts_4pol/COMPARE.md`.
표는 원자료(`results_4pol/*.jsonl`)에서 재집계해 **28칸 + 4합계 전부 일치**를 확인했다.

| FAILURE CASE | **DP** | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 30/30 · 21.8 s · 311 J | 30/30 · 22.8 s · 338 J |
| Robot breakdown | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 28/30 · 26.1 s · 490 J |
| Keep-out zone | 30/30 · 56.4 s · 492 J | 30/30 · 56.4 s · 492 J | 30/30 · 39.0 s · 456 J | 30/30 · 30.9 s · 362 J |
| Breakdown + battery | 29/30 · 26.0 s · 451 J | 29/30 · 26.0 s · 451 J | 29/30 · 23.3 s · 402 J | 28/30 · 24.5 s · 447 J |
| Breakdown + zone | 30/30 · 59.8 s · 656 J | 30/30 · 59.8 s · 656 J | 26/30 · 31.3 s · 624 J | 29/30 · 45.6 s · 577 J |
| Battery + zone | 30/30 · 59.8 s · 656 J | 30/30 · 59.8 s · 656 J | 28/30 · 35.1 s · 494 J | 30/30 · 36.8 s · 440 J |
| All three at once | 30/30 · 62.7 s · 733 J | 30/30 · 62.7 s · 733 J | 26/30 · 32.3 s · 595 J | 28/30 · 37.1 s · 537 J |
| **합계** | **207/210** | **207/210** | **198/210** | **203/210** |

> **각주 — 세 실행 레인이 안 바뀐 것이 이번 판의 통제다.** `canonical`·`surrogate`·`dspy` 는
> `value.json` 을 **읽지 않는다**: 그 파일의 유일한 독자가 `tools/monitor/dp_lane.jl:31` 이고,
> 그것을 부르는 `dp_macro` 는 `tools/monitor/policy.jl:841` 의 `if POLICY == "dp"` **안에서만**
> 호출된다(이번 세션에서 재확인). 그래서 dp 샤드 210개만 다시 굴렸고, 세 열의 수치가
> 2026-08-16 과 동일하게 나온 것이 "세계가 안 바뀌었다" 는 기계적 증거다.

⚠️ **DP 열은 전 case 에서 canonical 과 자릿수까지 같다. 자릿수가 아니라 판이 같다.**
`results_4pol/*.jsonl` 의 210개 (case, world_seed, ood_seed) 조합 **전부**에서 dp 판과
canonical 판이 makespan·closed·complete·**매크로 열 전체**까지 동일하다(실측, §3-D 의 재현
스크립트). 흔히 적히는 설명("결정의 80.7% 가 canonical 폴백이라")은 **절반만 맞다** — 나머지
19.3%(표 조회 성공 291건)도 canonical 과 같은 매크로를 골랐기 때문이다. 이 표에서 DP 열이
좋아 보이는 것은 DP 가 잘해서가 아니라 **DP 가 canonical 을 복사했기 때문**이다.

---

## 3. 판정표 (계획 §3)

| # | 지표 | 2026-08-16 | 이번 | 목표 | 판정 |
|---|---|---|---|---|---|
| 1 | 표집 판 완주율 | 16.9% | **86.0%** (505/587) | ≥ 90% | **미달** |
| 2 | `V` 중앙값 | 4743.6 | **2483.7** | 20 ~ 200 | **미달** |
| 3 | 단일팔 칸 | 27 / 49 | **23 / 48** | ≤ 5 | **미달** |
| 4 | dp 레인 표 조회 성공률 | 7.7% | **19.3%** | ≥ 50% | **미달** |
| 5 | §8.7 gap | 89.3% | **83.5%** | ≤ 20% | **미달** |
| 6 | 분해 충실성 위반 판 | 0 | **0** | 0 (유지) | **PASS** |

### 3-A. #1 표집 판 완주율 — 16.9% → 86.0%

판 587개(588 중 1판이 엔진 크래시) 중 505개 완주. 팔별:

| 팔 | 완주 | 팔 | 완주 |
|---|---|---|---|
| Replace | 84/84 = **100%** | RelocateBuild | 69/84 = 82.1% |
| SwapBattery | 84/84 = **100%** | ForbidZone | 69/84 = 82.1% |
| NOOP | 71/84 = 84.5% | **ReformTeam** | **57/83 = 68.7%** |
| Deprioritize | 71/84 = 84.5% | | |

**목표 90% 를 못 채운 것은 사실상 ReformTeam 한 축이다.** 그 축을 빼면 448/504 = 88.9% 이고,
ReformTeam 축이 90% 였다면 전체가 `(448 + 0.9·83)/587` = **89.0%** 다(이전 판의 "89.9%" 는
계산 착오였다 — 고쳤다). 즉 그 한 축을 고쳐도 목표에 닿지 않지만, 이 지표가 재고 있는 것이
"ReformTeam 판이 완주하지 못한다" 라는 **별개의 엔진 문제**라는 결론은 그대로다. 구세대
(16.9%)와 비교하면 목표 미달이라는 사실보다 **5.1배 상승**이 이번 변경의 실제 효과다.

**★ 이 판정은 이제 레포만으로 검증된다 — `dp_oracle/boards.jsonl`.**
예전에는 판 단위 완주 기록이 `dp_oracle/_sample_work/` (2.4GB, `.gitignore:73` 이 제외) 에만
있었고 `samples.jsonl` 로는 복원되지 않았다(꼬리 중복 제거 때문에 587판 중 **467판만** 표본에
나타나 82.4% · 팔별 분포도 다르다). 그래서 **clone 한 사람은 헤드라인 판정 #1 을 확인할 수
없었다.** 이제 표집기가 판마다 한 줄(`case · seed · arm_id · arm_name · complete ·
n_decisions · crashed · deviate_at · closed/total · 세대 도장`)을 `samples.jsonl` 옆에 낸다
(168 KB). 위 표는 그 파일에서 그대로 나온다:

```bash
../.venv/bin/python - <<'PY'
import json
r=[json.loads(l) for l in open('dp_oracle/boards.jsonl')]
ran=[x for x in r if not x['crashed']]
print(len(r), len(ran), sum(1 for x in ran if x['complete']))   # 588 587 505
PY
```

매니페스트는 **재시뮬레이션 없이** 다시 낼 수 있다(보존된 판 원자료를 다시 읽을 뿐):
`../.venv/bin/python dp_oracle/sample_grid.py --manifest-only --seeds 1,…,12`.

### 3-B. #2 `V` 중앙값 — 4743.6 → 2483.7

| | 값 |
|---|---|
| 최소 | 7.5 |
| Q1 | 1499.6 |
| **중앙** | **2483.7** |
| Q3 | 3357.1 |
| 최대 | 20735.6 |
| `V ≤ 200` 인 칸 | **9 / 66 (14%)** |

절반 가까이 내렸지만 여전히 실패 벌점 규모다. 원인은 잔여 미완주 14% 다 — 미완주 판의
`J ≈ 10000 + 100·(total − closed)` 가 그 판이 지나간 칸의 `V` 를 backward 로 끌어올린다.
**#1 이 90% 를 못 넘긴 것과 #2 가 200 을 못 내려간 것은 같은 원인의 두 얼굴이다.**

### 3-C. #3 단일팔 칸 — 27/49 → 23/48 (수치는 안 움직였다. **분포가 갈렸다**)

| 칸당 팔 수 | 2026-08-16 | 이번 |
|---|---|---|
| 1팔 | 27칸 | **23칸** |
| 2팔 | 4칸 | 0칸 |
| 5팔 | 2칸 | 0칸 |
| 6팔 | 1칸 | 0칸 |
| **7팔** | **15칸** | **25칸** |

**분포가 완전히 이봉이 됐다.** 중간 등급(2·5·6팔)이 전부 사라지고 `1팔 23 / 7팔 25` 만 남았다.

**★ 그리고 그 이봉이 하나의 술어로 정확히 갈린다 — 이것이 이 절의 강한 결과다.**
"이 칸에 `decision_index == board_deviate_at` 인 행이 있는가" 로 48칸을 나누면
**`{(7팔, deviation 칸): 25, (1팔, 비-deviation 칸): 23}`** 이고 **예외가 없다.** 더구나
7팔 칸 25개 중 **일곱 팔이 전부 deviation 행으로 덮이지 않은 칸은 0개**다. 계획 §1-B 가 원한
것("일곱 팔이 같은 칸에 착지해서 그 칸에 argmin 이 생긴다")은 **적용되는 곳에서 100%
달성됐고, 적용되는 곳이 정확히 deviation 칸이다.**

남은 단일팔 23칸은 **deviation 결정 밖에서만 도달하는 칸**이다 — prefix(결정 `k` 이전) 또는
꼬리(`k` 이후)로만 닿는다. 이전 판이 "**전부** 꼬리로만 도달"이라고 적었던 것은 **거짓**이다.
실제 구성은 **꼬리만 11칸 · prefix+꼬리 8칸 · prefix만 4칸**이고, 그 355행을 결정 위치로
나누면 `decision_index > board_deviate_at` **297행** · `<` **58행** · `==` **0행**이다.

그래도 결론(이 미달은 구현 실패가 아니라 구조적이다)은 **선다**, 다만 논거가 이것이다:
칸이 단일팔인 것은 **어떤 판도 그 칸에서 deviate 하지 않았기 때문**이고(`==` 가 0행인 것이
그 증거다), prefix 칸이 단일팔인 것은 **owner 판만 prefix 행을 내기 때문**이다(중복 제거 규칙,
§5-G). 두 경우 모두 비교 대상이 원리적으로 존재하지 않는다. 그 한 팔의 정체가 이를 뒷받침한다:
`Replace 18칸 · ReformTeam 3칸 · NOOP 2칸` — 전부 canonical 이 그 상황에서 고르는 매크로다.

전이 가중으로 보면 단일팔 칸은 **355 / 2258 = 15.7%** 에 불과하다.

deviation 행 447개는 일곱 팔에 64·64·64·64·64·64·63 으로 흩어져 있다. ⚠️ **이것을 "설계가
의도대로 작동했다는 직접 증거" 로 읽으면 안 된다 — 항진명제다.** `pick_k` 는 `arm_id` 를
일부러 안 쓰므로(`sample_grid.pick_k`) 발화 여부는 `(case,seed)` 마다 **전부 아니면 전무**이고,
발화한 판은 **정확히 한 개**의 `k` 행을 낸다. 84개 (case,seed) 중 20개가 미발화이므로
`84 − 20 = 64` 는 **셈으로 이미 정해져 있다.** 정보를 나르는 숫자는 **`63` 하나뿐**이고 그것은
ReformTeam 판 하나가 엔진 크래시로 빠진 결과다(§5-B).

### 3-D. #4 dp 레인 표 조회 — 7.7% → 19.3% (**실패의 종류가 바뀌었다**)

| dp 레인 결정 | 2026-08-16 (1502건) | 이번 (1511건) |
|---|---|---|
| `single_arm` | 841 (**56.0%**) | 126 (**8.3%**) |
| `tie_unresolved` | 545 (36.3%) | **1094 (72.4%)** |
| 표 조회 성공 | 116 (7.7%) | **291 (19.3%)** |

**§1-B 가 겨냥한 `single_arm` 은 56.0% → 8.3% 로 무너졌다.** 목표 지표(#4)가 50% 를 못 넘긴
것은 그 실패가 **`tie_unresolved` 로 옮겨갔기** 때문이다.

#### 그 tie 는 대부분 "참인 동점" 이 아니다 — `n=1` 자동 동점이다

이전 판은 "그 tie 는 제조된 것이 아니라 참이다" 라고 적었다. **데이터가 그것을 지지하지
않는다.** 표의 tie 칸 24개, 최선 팔이 아닌 동점 슬롯 **122개**를 분류하면:

| 동점이 된 이유 | 슬롯 | 격차 |
|---|---|---|
| `Q` 가 **정확히** 같다 (진짜 동점) | **10** | 0 |
| 유한한 `se` 안에서 가깝다 | **58** | 최소 0.08 · 중앙 736 · 최대 5783 |
| **`n < 2` 라 `se = inf` → 무조건 동점** | **54** | 최대 **11259** (`q=13185.3` vs 최선 `1926.1`, n=1 vs n=16) |

메커니즘은 코드에 그대로 있다: `dp_oracle/dp_solve.py:88-93` 의 `_se()` 는 `n < 2` 면
`inf` 를 돌려주고, `dp_solve.py:246` 이 `not math.isfinite(se_d)` 에서 단락 평가로 동점에
넣는다. 즉 **표본이 하나뿐인 팔은 자기 `Q` 가 무엇이든 최선 팔과 무조건 동점**이다. 그런데
1-step deviation 에서는 deviation 칸의 거의 모든 팔이 정확히 `n=1` 이다(판마다 그 칸에서 그
팔을 한 번만 강제하므로). **동점이 구성상 제조된다.** 이 자동 동점을 빼고 다시 판정하면
24칸 중 **9칸이 확정된다.**

원자료 층위에서도 같은 결론이 나온다: deviation 그룹 64개 중 **일곱 팔이 `c` 와 `next_cell`
을 모두 공유하는(= 진짜로 아무 일도 안 일어난) 그룹은 9개**뿐이다
(그룹당 서로 다른 `c` 값의 수 = `{1:9, 2:15, 3:15, 4:25}`). **진짜 동점은 deviation 그룹의
약 14% 다** — 나머지 86% 는 팔이 실제로 세계를 갈랐는데도 표본이 얇아 동점으로 접힌 것이다.

**그래서 다음 사이클의 지렛대는 tie-break 규칙이 아니다.** `MACRO_COST` 최소 같은 규칙을
얹으면 **자릿수가 넷 다른 `Q`**(13185 vs 1926) 사이를 매크로 비용으로 중재하게 된다 — 그건
동점을 가르는 것이 아니라 측정을 덮어쓰는 것이다. 실제 지렛대는 둘이다:

1. **(칸,팔)당 표본 깊이.** 같은 `(case,seed)` 를 여러 `k` 로 굴리거나 seed 를 늘려
   deviation 칸의 `n` 을 2 이상으로 만든다(재시뮬레이션).
2. **`n=1` 에 대한 유한 `se` 정책.** `_se` 가 `inf` 를 돌려주는 대신 그 칸의 풀드 분산이나
   보수적 상한을 쓰게 한다 — 그러면 격차 11259 인 팔이 동점으로 접히지 않는다.

⚠️ **이번 사이클에서 `dp_solve.py` 는 고치지 않았다.** 이 세대의 산출물은 메커니즘에 이름을
붙이는 것이고, 솔버를 바꾸면 발행된 표가 바뀌어 같은 문서 안에서 두 세대가 섞인다.

#### 🔴 그리고 조회에 성공한 19.3% 는 매크로 **하나**뿐이다

| | 구세대 (2026-08-16) | 이번 |
|---|---|---|
| 표의 **확정 칸** | 17칸 | 19칸 |
| 그 칸들이 권하는 매크로 | `SwapBattery 11 · ReformTeam 3 · Replace 3` | **`Replace` 19** |
| dp 레인의 표 조회 성공 결정 | 116건 | 291건 — **전부 `Replace`** |
| 그 결정에서 canonical 규칙의 선택 | — | **291건 전부 `Replace`** (불일치 0) |
| dp 판 ↔ canonical 판 | 일부 갈림 | **210/210 완전 동일** |
| `FINAL.md` dp battery 매크로 정확도 | 9% (11/120) | **0% (0/120)** |

즉 #4 의 7.7% → 19.3% 는 **표가 더 자주 답한 것이 아니라, 표가 항상 같은 답을 하게 된 것**이다.
그 답이 canonical 의 답과 같으므로 dp 레인은 canonical 의 복사본이 됐고, 그 대가가 이 브랜치
diff 안에 있다 — battery case 에서 dp 는 `SwapBattery` 를 11회 고르던 것을 0회로 잃었다.
**#4 를 진전으로만 인용하지 말 것.**

재현(새 시뮬 0회):

```bash
../.venv/bin/python - <<'PY'
import json, glob, collections
rows=[json.loads(l) for p in glob.glob('results_4pol/*.jsonl') for l in open(p) if l.strip()]
by=collections.defaultdict(dict)
for r in rows: by[(r['case'], r['world_seed'], r['ood_seed'])][r['policy']]=r
sig=lambda r:(r['makespan'], r['closed'], r['complete'], r['total'],
              tuple(d['macro'] for d in r['decisions']))
print('dp == canonical:', sum(sig(v['dp'])==sig(v['canonical']) for v in by.values()), '/', len(by))
dec=[d for r in rows if r['policy']=='dp' for d in r['decisions']]
hit=[d for d in dec if d.get('dp_miss') is None]
print(len(hit), collections.Counter(d['macro'] for d in hit),
      collections.Counter(d['rule'] for d in hit))
V=json.load(open('dp_oracle/value.json'))['cells']
print(collections.Counter(v['a_star'] for v in V.values() if v['a_star'] is not None))
PY
```

### 3-E. #5 §8.7 gap — 89.3% → 83.5%

실행 정책의 실현 cost-to-go 가 DP 의 `V` 보다 **좋은** (칸,정책) 쌍 101 / 121.

| 축 | 2026-08-15 | 2026-08-16 | 이번 |
|---|---|---|---|
| Reform | 100% | 92.3% | **69.2%** |
| Zone | 100% | 100% | **65.2%** |
| Battery | 82.7% | 92.3% | 94.2% |
| Fault | 81.8% | 75.8% | 84.8% |

**Reform 과 Zone 이 크게 내렸고 Battery·Fault 는 올랐다.** 레벨별로는 L0 81.4% · L1 90.0% ·
L2 88.0% 로, 2026-08-16 의 `L0 97.9% · L1 42.1% · L2 100%` 와 견주면 **L0(가장 정밀한 칸)가
97.9% → 81.4% 로 내렸다** — 정밀 칸의 표본이 두꺼워졌다는 뜻이고 이번 변경의 방향과 맞는다.

`V` 가 실제로 천장이었던 칸(넘긴 쌍이 하나도 없는 칸)이 **6칸** 있다.

---

## 4. 왜 목표 수치에 미달했는가 — 하나의 구조적 이유

**1-step deviation 은 구성상 deviation 지점에서만 다팔 관측을 만든다.**

한 판은 결정 `k` 에서만 팔을 갈아쓰고 `k+1` 부터는 canonical 로 굴러간다. 그래서:

- 결정 `k` 가 떨어진 칸 → 일곱 팔이 전부 관측된다 (**25칸, 전부 7팔**)
- 결정 `k` 이후에만 도달하는 칸 → canonical 이 고른 한 팔만 관측된다 (**23칸, 전부 1팔**)

`k` 는 `pick_k(case, seed)` 가 `n_hint = 8`(결정 수 중앙값) 안에서 흩뿌린다. 84개 (case,seed)
조합이 있으므로 deviation 지점도 최대 84곳뿐이고, 그보다 깊은 칸은 원리적으로 꼬리로만 닿는다.

**#3 을 목표(≤5)까지 내리려면 `pick_k` 분포를 바꿔야 하고 그것은 재시뮬레이션이다** — 즉
다음 사이클 거리다. 후보 두 가지:
1. 판당 deviation 을 하나 더 넣는다(판 수는 그대로, 비용 2배 아님 — 다만 "1-step" 의 정의가 바뀐다).
2. **같은 `(case,seed)` 를 서로 다른 `k` 로 여러 번 굴려 `k` 를 판마다가 아니라 `(case,seed,회차)`
   마다 흩뿌린다** — 즉 `pick_k` 의 상한이 아니라 **표본 수**를 늘린다. 이것은 §3-D 의 `n=1`
   자동 동점(tie 슬롯 122개 중 54개)도 같이 없애므로 #3 과 #4 를 한 손잡이로 민다.

⚠️ **~~`--n-hint` 를 키워 깊은 지점을 더 자주 고른다~~ 는 방향이 반대다 — 지웠다.**
실측이 그것을 부정한다: 판의 결정 수 **중앙값은 9**(최소 4·최대 27)인데 현행 `n_hint=8` 에서
평균 `k` 가 이미 **4.7** 이고 84개 (case,seed) 중 **20개가 아예 발화하지 않는다**(`k` 가 그
판의 결정 수보다 뒤). `n_hint` 를 키우면 `k` 분포가 뒤로 밀려 **미발화 그룹이 더 늘고**,
발화가 늦어진 만큼 **prefix 로만 닿는 단일팔 영역이 커진다**(§3-C 의 prefix-only 4칸·
prefix+꼬리 8칸이 그 영역이다). 즉 #3 을 악화시킨다.

#2·#5 는 잔여 미완주 14%(특히 ReformTeam 68.7%)에 묶여 있고, 그건 표집 방식이 아니라
**엔진 쪽 문제**다(§5 참조).

---

## 5. 알려진 구멍 — 이름과 수로 적는다

### 5-A. 계획 Task 1 Step 6 의 결정성 게이트 — **PASS. 축소판으로 가지 않았다**

`DS_DEVIATE_AT=999`(결정 수보다 뒤) 판이 순수 canonical 판과 같은지 직접 쟀다:

```
종단 지표 차이: 없음
energy_J: 144498.09840210786 vs 144498.09840210786
결정 열 동일: True (5 vs 5 결정)
PASS
```

리셋 지점을 옮긴 뒤 **재실행해서도 PASS**. 따라서 `pick_k` 를 `k=1` 로 고정하는 축소판은
쓰지 않았고, 깊이 커버리지를 잃지 않았다.

**★ 그런데 발행된 게이트는 n=1(한 case/seed, 결정 5개)이고, 이 표집이 만든 데이터에는
훨씬 강한 n=84 판이 이미 들어 있다 — 그것을 여기 인용한다.**
보존된 587판을 `(case,seed)` 로 묶으면 각 그룹은 **일곱 개의 독립 프로세스**가 굴린 판이다
(ReformTeam 이 크래시한 한 그룹만 6개). 각 판에서 `decision_index < k` 인 **pre-`k` 결정 열**은
정의상 순수 canonical 이어야 한다. 실측:

```
그룹 84 · pre-k prefix 가 바이트 동일한 그룹 84 · 갈린 그룹 0
그룹당 판 수: 7팔 83그룹 · 6팔 1그룹 (ReformTeam 크래시)
```

```bash
../.venv/bin/python - <<'PY'
import json, os, re, collections, sys
sys.path.insert(0,'dp_oracle'); sys.path.insert(0,'.')
from sample_grid import _fired_decision
W='dp_oracle/_sample_work'; pat=re.compile(r'^(.*)_s(\d+)_a(\d+)$')
DROP={'deviate_at','deviate_arm','deviated','deviate_valid','enact_applied','router_target','enacted'}
g=collections.defaultdict(set)
for d in os.listdir(W):
    m=pat.match(d); p=os.path.join(W,d,'rows.jsonl')
    if not m or not os.path.exists(p): continue
    r=json.loads(open(p).readline()); ds=list(r.get('decisions') or [])
    fd=_fired_decision(ds); k=fd.get('deviate_at') if fd else None
    pre=[x for x in ds if k is None or x.get('decision_index',0)<k]
    g[(m.group(1),m.group(2))].add(json.dumps(
        [{a:b for a,b in x.items() if a not in DROP} for x in pre], sort_keys=True))
print(len(g), sum(1 for v in g.values() if len(v)==1), sum(1 for v in g.values() if len(v)>1))
PY
```

이것이 이 브랜치에서 가장 강한 단일 결과다 — **일곱 개의 독립 프로세스가 갈아쓰기 지점
이전까지 바이트 동일한 궤적을 냈다.** 이 레포의 "컴파일을 다시 하면 배정이 재현되지 않는다"
(CLAUDE.md Gotchas)라는 알려진 한계에도 불구하고, **한 번 컴파일된 상태 안에서 프로세스 간
결정성**이 84/84 로 성립함을 보인다.

### 5-B. 엔진 크래시 — 팔별 수

**표집 588판 중 실패 1판, 전부 `ReformTeam`.** 2026-08-16 의 91판(15.5%)에서 급감했다.
deviation 모드에서는 그 팔이 판당 한 번만 집행되므로 `AssertionError: has_edge(...)` 에
도달할 확률이 떨어진다 — 계획 Task 2 Step 6 의 예상이 맞았다.

⚠️ **그러나 `ReformTeam` 축의 완주율은 68.7% 로 여전히 최저다.** 크래시는 줄었지만 그 팔의
판이 완주하지 못하는 현상은 남았고, 이것이 #1·#2 미달의 실질적 원인이다.
**엔진 결함으로 별도 작업에 올려야 한다**(`apply_cmd!(::FormTransportUnit)` / `has_edge` 어서션).

### 5-C. φ̃ 추상화 손실 — 레벨별 gap 이 여전히 갈린다

L0 81.4% · L1 90.0% · L2 88.0%. 2026-08-16(L0 97.9% · L1 42.1% · L2 100%)과 방향이 바뀌었다 —
가장 정밀한 L0 가 크게 내렸다. **격자 재설계는 다음 사이클 거리다.**

### 5-D. 라벨 레인 재현성 결함(4/365) — **이 사이클과 무관하다**

라벨을 건드리지 않았다. `:8090` 서비스도 그대로 뒀다.

### 5-E. `deviate_valid` 와 `enact_applied` 는 서로 다른 것을 잰다 — 혼동 금지

- `deviate_valid` = 그 팔이 `valid_macros(env, truth)` 메뉴 안인가.
  **빈 메뉴 = 제한 없음**이 이 레포의 규약이다(`policy.jl:413`·`:460`). `valid_macros` 는
  `BatteryTruth`·`ZoneTruth` 에만 리스트를 주므로 **fault·reform 결정에서는 언제나 `true`** 다.
  이 값만으로 거르면 아무것도 안 걸러진다.
- `enact_applied` = 집행 사슬이 **실제로 분기를 탔는가**. 이것이 진실원이다.
  `run_demo.jl` 의 사슬에는 최종 `else` 가 없고 두 분기가 `truth isa CB.ZoneTruth` 가드다.

실측(fault 판): `Deprioritize` → `valid=True, applied=True` · `ForbidZone` → `valid=True, applied=False`.
표본에서 `deviate_valid=False` 인 판은 118개였고 **배제 사유로 쓰지 않았다**(정보성으로만 기록).

⚠️ **"주로 zone 사건" 이라고 적었던 것은 틀렸다 — 어느 축에도 쏠려 있지 않다.** 587판 실측
분포: **`ForbidZone` 29 · `ReformTeam` 28 · `Replace` 16 · `SwapBattery` 16 · `Deprioritize` 16
· `RelocateBuild` 13** (합 118). `sample_grid.py` 의 같은 문구를 낸 로그 줄도 함께 고쳤다.

⚠️ **`enact_applied = true` 는 "효과 지점에 도달했다" 이지 "세계가 바뀌었다" 가 아니다.**
가드 없이 집행하는 네 분기(NOOP·ForbidZone·RelocateBuild·ReformTeam) 중 셋은 본문 안쪽 조건으로
아무것도 안 바꿀 수 있다 — `ForbidZone`/`RelocateBuild` 의 `wb.status == :already_clear`(변위 Δ0),
`ReformTeam` 의 `rec.status == :error` + `wedge.status == :no_wedge`. **선행 결함이고 이번
변경이 만든 것이 아니다.** 귀결: `ReformTeam` 을 문 비-reform 판이 arm 4 로 라벨된 채 NOOP
동작으로 주저앉을 수 있다.

### 5-F. `enact_applied` 에 회귀 가드가 없다

`run_demo.jl` 은 전체 시뮬레이터가 필요한 최상위 스크립트라 단위 테스트가 없다. 이번에는
양방향 실판 증거(fault+`Deprioritize` → true, reform+`Replace` → false)로 확인했지만,
**그 사슬을 리팩터하면 조용히 깨질 수 있다.**

### 5-G. 배제는 꼬리에만 적용된다 — 그 논거

발화한 판은 **전부** 자기 결정 `k` 행을 낸다. 모든 판이 `k` 에서 자기 팔을 강제하므로
그 행은 그 팔로 라벨된 **고유 관측**이고 그 행을 내는 판은 세상에 하나뿐이다.
중복 제거는 꼬리(`decision_index > k`)에만 적용한다 — 무집행 후에는 세계가 안 바뀌어
NOOP 팔 판의 궤적을 되밟기 때문이다.

**이 구분을 처음엔 놓쳤다.** 판을 통째로 배제했더니 전이 2045 · (칸,팔) 130 이었고,
꼬리만 배제하도록 고치니 **2258 · 198** 이 됐다(+213 행, +68 쌍). 재시뮬레이션은 필요 없었다 —
`--keep-work` 로 587판이 보존돼 있어 행→표본 변환만 1.8분 다시 돌렸다.
그 이전 세대 표본은 `dp_oracle/samples_predeviationrow_2026-08-15.jsonl` 로 보존했다.

#### ⚠️ 그 중복 제거는 **새는다** — 이름과 수로 적는다 (2026-08-17 최종 리뷰)

꼬리 중복 판정의 술어가 `enact_applied` 인데, 바로 위 §5-E 가 적어 둔 대로 그 플래그는
**"효과 지점에 도달했다"** 이지 **"세계가 바뀌었다"** 가 아니다. 그래서 분기를 타고도 아무것도
안 바꾼 판(`already_clear` · `:error`+`:no_wedge`)은 `"real"` 로 분류돼 **꼬리를 전부 낸다.**

| 측정 | 값 |
|---|---|
| `"real"` 로 분류된 판 | **170** |
| 그중 다른 발화 판과 **바이트 동일한 꼬리**를 내는 판 | **107** |
| 꼬리 행 (전체 2258행 중) | 1521 |
| 그중 같은 `(case,seed)` 의 다른 판과 `(cell, arm, c, next_cell, terminal_value)` 가 같은 여분 사본 | **601행** (중복군 370개) |
| 중복을 만드는 팔 조합 | `(0,2)` · `(0,2,4)` · `(0,4)` · `(3,7)` — §5-E 가 "도달했지만 안 바꿨다" 로 지목한 그 분기들 |

**귀결은 `a*` 의 오류가 아니라 `n`·`se` 의 과신이다.** 중복 꼬리를 합쳐 표를 다시 풀면
(`solve_backward_hierarchical`, 새 시뮬 0회) **66칸 전부에서 `a_star`·`unresolved_reason` 이
그대로**이고 확정 19칸도 그대로다. **그래서 재표집은 필요 없다.**

```bash
../.venv/bin/python - <<'PY'
import json, sys
sys.path.insert(0,'dp_oracle'); sys.path.insert(0,'.')
import dp_solve
rows=[json.loads(l) for l in open('dp_oracle/samples.jsonl')]
ac=list(json.load(open('dp_oracle/grid_spec.json')).get('observed_cells') or {})
key=lambda r:(r['case'],r['seed'],r['cell'],r['arm'],round(r['c'],12),r['next_cell'],r['terminal_value'])
seen=set(); ded=[]
for r in rows:
    if r['decision_index']>r['board_deviate_at']:
        if key(r) in seen: continue
        seen.add(key(r))
    ded.append(r)
t0,_=dp_solve.solve_backward_hierarchical(rows, all_cells=ac)
t1,_=dp_solve.solve_backward_hierarchical(ded,  all_cells=ac)
print(len(rows)-len(ded), 'rows collapsed;',
      sum((t0[c]['a_star'],t0[c]['unresolved_reason'])!=(t1[c]['a_star'],t1[c]['unresolved_reason'])
          for c in t0), 'cells changed')      # 651 rows collapsed; 0 cells changed
PY
```

**술어를 넓히지 않았다** — 그것은 표집 의미를 바꾸는 변경이고 재표집 승인이 없다. 안전한
확장안(행만 보고 계산 가능): 지금 로드된 행에서 판별 **꼬리 서명**
(`decision_index` 이후의 `(cell, macro, c, next_cell, terminal_value)` 열)을 만들어,
같은 `(case,seed)` 안에서 서명이 같은 판들 중 하나만 꼬리를 내게 한다 — `enact_applied` 를
대체하는 것이 아니라 그 **뒤에** 붙는 2차 필터라 표집 의미는 안 바뀐다. **구현하지 않았다.**

### 5-H. `objective.json` 이 커밋되지 않은 채 작업 트리에만 있다 — **재현이 실패한다(경고가 아니다)**

작업 트리 = `generation: 2026-08-13-global-kappa-precedence`(= CLAUDE.md 가 현행으로 선언한 값).
커밋된 HEAD = `2026-08-13-energy-activation`. `audit_objective.py` 가 `WARN(9-b) 머지 핸드셰이크
필요` 로 잡는다(항목 자체는 9/9 통과, rc=0). 마지막 커밋은 `02c7fd86`(2026-08-13).

**모든 프로세스가 작업 트리를 읽으므로 이번 표집·스윕은 올바른 세대로 도장됐다.** 그러나
🔴 **깨끗이 체크아웃하면 이 결과는 "덜 정확하게" 재현되는 것이 아니라 아래 §6 절차가
3단계에서 그냥 죽는다.** `dp_oracle/dp_solve.py` 의 `main()` 은 표본의 세대 도장과 현행
`objective.json` 을 대조해 다르면 `sys.exit("표본의 objective_hash 가 현행과 다르다
(구세대 표본)…")` 로 **하드 스톱**한다(`dp_solve.py:499-504`, 종료 코드 1). 체크아웃하면
`objective.json` 이 `2026-08-13-energy-activation` 으로 돌아가고 `samples.jsonl` 은
`2026-08-13-global-kappa-precedence` 로 도장돼 있으므로 그 조건이 **반드시** 성립한다.
`run_shard.sh` 의 provenance 도장이 HEAD SHA 라 그 SHA 가 실제 사용된 목적함수를 식별하지도
못한다. **이 세션의 작업이 아니라 이전부터 있던 미커밋 변경이라 임의로 커밋하지 않았다 —
별도로 커밋해야 하고, 그 전까지 §6 은 "표본을 다시 만들 수 있는 절차" 가 아니다.**

### 5-I. 표집 작업 디렉토리는 gitignore 했다

`--keep-work` 산출이 **2.4GB** 라 `.gitignore:73` 에 `dp_oracle/_sample_work/` 를 넣었다.
표본 자체는 `samples.jsonl` 에 있고 그 디렉토리는 사후 진단용 원자료다.
계획 Task 3 Step 9 의 `git add dp_oracle/` 를 그대로 하면 2.4GB 가 커밋된다.

**그 대가로 판 단위 판정(#1)이 레포에서 검증 불가였다 — `dp_oracle/boards.jsonl`(168KB, 커밋)
로 닫았다.** §3-A 참조. 표집기가 표본을 낼 때 같이 내고, `--manifest-only` 로 재시뮬레이션
없이 다시 낼 수 있다.

### 5-J. `.venv` 에 pytest 가 없다 — 계획서와 현실의 불일치

계획 Task 3 Step 9 의 `../.venv/bin/python -m pytest ...` 는 현 환경에서 `ModuleNotFoundError`
로 실패한다. 이번에는 `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest`
로 돌렸다 — 인터프리터는 `.venv/bin/python`(Global Constraint 2 만족)이고 러너만 빌린 것이다.
두 인터프리터 모두 3.12.3 이고 대상 모듈은 stdlib + 레포 모듈만 import 한다.
**비가역 표집 직전에 `pip install` 로 환경을 바꾸지 않았다** — 그 변경 자체가 세대의 교란
변수가 되기 때문이다.

⚠️ 그리고 **pytest 로는 `test_deviation_plan.py` 만 잡힌다.** `test_cost_decomposition.py` ·
`test_dp_solve.py` · `test_cellkey_parity.py` 는 `def test_*` 가 없고 모듈 수준 `check()` +
`sys.exit(1)` 로 게이팅하므로 pytest 에서 **0건**이다(`no tests ran`, rc 5). §6 이 그 셋을
인터프리터로 직접 부르는 이유다 — 이전 판이 충실성 게이트를 pytest 한 줄에 묶어 뒀는데
**그 줄은 게이트를 한 번도 돌리지 않았다.**

### 5-K. 충실성 게이트가 자기 증거를 파괴하고 있었다 — **고쳤다**

`sample_grid.py` 의 `boards_bad` 검사가 `samples.jsonl` 쓰기와 `shutil.rmtree(work)` **뒤에**
있었다. 그래서 위반한 런은 (1) **직전의 정상 표본 파일을 덮어쓰고** (2) `--keep-work` 없이
돌았다면 **위반을 진단할 판 원자료까지 지운 뒤** exit 1 했다. 게이트가 발화하는 그 순간이
증거가 가장 필요한 순간인데 정확히 그때 증거가 사라진다.

이제 검사가 출력·정리보다 **먼저** 온다 — 위반이면 아무것도 쓰지 않고 아무것도 지우지 않는다.
**종료 코드(1)와 메시지는 그대로**이고, 게이트의 강도·도메인은 건드리지 않았다.
회귀 가드: `test_deviation_plan.py::test_fidelity_gate_runs_before_output_and_cleanup`
(문장 순서를 본다 — 실제 위반 재현은 51분 표집이 필요해 단위검사로 성립하지 않는다).

---

## 6. 재현 절차

```bash
cd /home/chahj578/Construction_OODlayer

# 1) 계측 게이트
julia +lts --project=. tools/monitor/test_deviation.jl          # 5+4+7 pass
julia +lts --project=. tools/test_policy_escalation.jl
cd wm4spacecraft_manufacturing
PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest \
    dp_oracle/test_deviation_plan.py -q                         # 30 passed (전부 이 파일에서 나온다)
../.venv/bin/python dp_oracle/test_cost_decomposition.py        # rc=0 — 분해 충실성 게이트
../.venv/bin/python dp_oracle/test_dp_solve.py                  # rc=0
../.venv/bin/python dp_oracle/test_cellkey_parity.py            # rc=0, 13720 상태 칸키 동치

# 2) 표집 (51.6분 / 40워커 / 588판)
export DSPY_URL=http://127.0.0.1:8090
../.venv/bin/python dp_oracle/sample_grid.py --jobs 40 --keep-work \
    --seeds 1,2,3,4,5,6,7,8,9,10,11,12

# 3) 풀이
../.venv/bin/python dp_oracle/dp_solve.py --out dp_oracle/value_L0_nobackoff.json
../.venv/bin/python dp_oracle/dp_solve.py --backoff

# 4) dp 레인만 재스윕 (19분 / K=50 / 샤드 210)
nohup bash run_4pol_parallel.sh --jobs 50 --policies dp \
    --shards-dir results_4pol/shards_dp > /tmp/sweep_dp.log 2>&1 &
bash finish_tables.sh

# 5) gap
../.venv/bin/python dp_oracle/gap_breakdown.py

# 6) 판정 #1(표집 판 완주율) 검증 — 재시뮬레이션 없이 판별 매니페스트를 다시 낸다
../.venv/bin/python dp_oracle/sample_grid.py --manifest-only \
    --seeds 1,2,3,4,5,6,7,8,9,10,11,12          # -> dp_oracle/boards.jsonl (588판·587 실행·505 완주)
```

⚠️ **`test_cost_decomposition.py` 는 pytest 로 돌리면 0건이다.** 그 파일에는 `def test_*` 가
없고 모듈 수준 `check()` + `sys.exit(1)` 로 게이팅한다 — `pytest dp_oracle/test_cost_decomposition.py -q`
는 `no tests ran` 을 내며 **rc 5** 다. 예전 판이 두 파일을 한 줄에 묶고 `# 28 passed` 를 달아
둬서 이 게이트가 돌아간 것처럼 보였다. **반드시 위처럼 인터프리터로 직접 실행할 것.**
(30건은 전부 `test_deviation_plan.py` 에서 나온다 — 이번 리뷰에서 2건 추가. 참고로 `pytest dp_oracle/ -q` 도 30건이다 —
`test_dp_solve.py`·`test_cellkey_parity.py` 역시 pytest 로는 0건을 낸다.)

⚠️ **위 3)·4)·5) 는 깨끗한 체크아웃에서 실패한다** — `objective.json` 미커밋(§5-H).
`dp_solve.py` 가 세대 불일치로 하드 스톱한다.

⚠️ `--shards-dir` 를 반드시 준다. `run_shard.sh` 의 provenance 도장이 `(commit, policies)` 쌍이라
같은 OUTDIR 에 다른 정책 목록으로 넣으면 끝나 있는 세 정책 결과를 지우고 다시 돈다.

---

## 7. 보존한 세대

| 파일 | 무엇 |
|---|---|
| `dp_oracle/samples_gen_backward_2026-08-15.jsonl` | backward induction 도입 세대 |
| `dp_oracle/samples_gen_constantarm_2026-08-16.jsonl` | **상수-팔** 표집(이번 변경의 대조군) |
| `dp_oracle/value_gen_constantarm_2026-08-16.json` | 그 세대의 표 |
| `dp_oracle/samples_predeviationrow_2026-08-15.jsonl` | 이번 세대 중 **꼬리-배제 정정 전** 표본 |
| `dp_oracle/value_L0_nobackoff.json` | 계층 백오프 OFF 표(§1 대조용) |

지우지 않는다 — 두 세대를 나란히 놔야 이번 변경이 무엇을 바꿨는지 말할 수 있다.
