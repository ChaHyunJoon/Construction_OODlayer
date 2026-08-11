# 4정책 x OOD case 종합 리포트 (자동 생성)

## 1. 헤더

생성 시각: 2026-08-11T00:17:10-07:00

이 문서가 재는 것: 3개 실행 가능 정책(`noop`, `surrogate`, `llm`=dspy) x 8개 OOD case (120 판 스윕, `run_4pol.sh`) 의 완주율/결정정확도/빌드시간/에너지 비교, 오라클 결과-천장(axis 단위, `oracle/out` 라벨 격자에서 직접 계산), 상태조건부 decision-shadow 비교, post-hoc 검증(V1-V4), 알려진 한계.

재현 절차:

```bash
# 1) 120 판 스윕 (순차, ~5h, julia 를 내부에서 부른다 -- 다른 julia 와 동시에 돌리지 말 것)
bash run_4pol.sh --deadline-seconds <N> --seeds 1,2,3,4,5

# 2) 오라클 라벨(fault/zone 축) 재생성 -- julia, 순차 (README 함정 30)
bash run_step_d_all.sh

# 3) 스윕 산출물을 case별 report/shadow md+json 으로 조립 (순수 파이썬)
python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol

# 4) 이 문서 (순수 파이썬, julia 호출 없음, subprocess 없음)
python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol --oracle-dir oracle/out
```

입력 경로: `--results-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/results_4pol` (raw 판) · `--out-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/artifacts_4pol` (report/shadow 산출물, 이 문서의 출력 위치이기도 함) · `--oracle-dir /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/oracle/out` (오라클 라벨 격자, Part A 전용).

기준 행동 a\* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):
- `battery`: battgrid_0805_s1.jsonl, 18 instances (6 fire points x 3 severities), all 3 arms
- `fault`: firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect separation
- `zone`: zcausal_reform/ STEP 10, 2 arm-crossed events (n=2 -- weakest axis)

---

## 2. 헤드라인 표 -- 8 case x 4 방법

> `oracle` 은 실행 가능한 온라인 정책이 아니다(`tools/monitor/policy.jl` 에 oracle 분기 없음, `grep -i oracle` 0건). 이 행은 함께 달리는 네 번째 주자가 아니라 **천장/원점(ceiling)** 이다 -- "옳은 결정 100%"는 성능 주장이 아니라 나머지 세 행이 이 원점에서 얼마나 떨어졌는지 재는 눈금이다.

실행 가능한 lane 은 `noop` / `surrogate` / `dspy`(=`llm`) 셋뿐이다. `oracle` 행은 case 마다 별도 계산되는 상한선(정의상 100%)으로만 들어간다 -- "oracle 이 이겼다"는 주장은 정의상 항상 참이라 정보가 없다. 승자를 굵게 표시하지 않는다: 예를 들어 `zonecore` 는 surrogate 가 결정 100% 지만 완주 4/5, llm 은 결정 65% 지만 완주 5/5 에 에너지도 더 낮다 -- 어느 쪽도 무조건 '이겼다' 라고 적을 수 없다(아래 §5 zonecore 상세 참조).

### case = `battery`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 100% (18/18) | 100% (정의상) | 19.8 (완주판 n=18) | — |
| `surrogate` | 5/5 | 0% (0/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 5/5 | 0% (0/11) | 21.6 ± 0.0 s | 343.0 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 21.6 ± 0.0 s | 343.0 |

### case = `fault`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 100% (22/22) | 100% (정의상) | 21.8 (완주판 n=22) | — |
| `surrogate` | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 0/5 | 0% (0/6) | — | 947.4 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 26.1 ± 3.9 s | 473.9 |

### case = `zonecore`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 100% (2/2) | 100% (정의상) | 30.3 (완주판 n=2) | — |
| `surrogate` | 4/5 | 100% (19/19) | 31.2 ± 1.9 s | 639.0 |
| `noop` (바닥선) | 0/5 | 0% (0/20) | — | 722.0 |
| `llm` (dspy) | 5/5 | 65% (13/20) | 26.1 ± 1.6 s | 439.3 |

### case = `all`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 70% (14/20) | 31.1 ± 8.5 s | 651.6 |
| `noop` (바닥선) | 0/5 | 0% (0/17) | — | 837.4 |
| `llm` (dspy) | 5/5 | 85% (17/20) | 42.2 ± 20.9 s | 547.2 |

### case = `fault_battery`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 5/5 | 45% (9/20) | 26.1 ± 3.9 s | 473.9 |
| `noop` (바닥선) | 1/5 | 0% (0/13) | 21.6 ± 0.0 s | 787.8 |
| `llm` (dspy) | 5/5 | 100% (20/20) | 25.3 ± 4.9 s | 408.5 |

### case = `fault_zone`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 100% (20/20) | 32.9 ± 4.5 s | 720.1 |
| `noop` (바닥선) | 0/5 | 0% (0/13) | — | 874.0 |
| `llm` (dspy) | 4/5 | 80% (16/20) | 29.5 ± 2.8 s | 647.2 |

### case = `battery_zone`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 미측정 (STEP D 필요) | 100% (정의상) | — | — |
| `surrogate` | 4/5 | 45% (9/20) | 32.9 ± 4.5 s | 720.1 |
| `noop` (바닥선) | 1/5 | 0% (0/17) | 21.6 ± 0.0 s | 646.2 |
| `llm` (dspy) | 5/5 | 90% (18/20) | 23.7 ± 1.7 s | 398.7 |

### case = `zone`

| 정책 | 완주율 | 옳은 결정 (vs a\*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 100% (2/2) | 100% (정의상) | 30.3 (완주판 n=2) | — |
| `surrogate` | 4/5 | 100% (19/19) | 31.2 ± 1.9 s | 639.0 |
| `noop` (바닥선) | 0/5 | 0% (0/20) | — | 722.0 |
| `llm` (dspy) | 5/5 | 65% (13/20) | 26.1 ± 1.6 s | 439.3 |

---

## 3. 오라클 결과-천장 (Part A -- 축 단위)

> **천장(ceiling) vs 정책 행의 차이.** 위 헤드라인 표의 `oracle` 행은 "옳은 결정" 열에서 정의상 100% 다(그 행의 정의가 a\* 이므로) -- 그건 성능 주장이 아니라 나머지 세 정책이 얼마나 떨어졌는지 재는 눈금(원점)이다. 여기 이 절은 그와 다른 것 -- **a\* 를 실제로 실행했을 때 결과가 어땠는가**(완주율 · closed/total · makespan) -- 를 축(battery/fault/zone) 단위로 오라클 격자 실측에서 직접 계산한다. `oracle` 은 온라인 정책이 아니므로(`tools/monitor/policy.jl` 에 oracle 분기 없음) 이 숫자는 8-case 헤드라인 표의 셀이 아니라 별도 참조선이다.

계산 시맨틱은 `test_llm7h.py` 의 `lexbest()`(줄 44-50) 및 zone 비교식(줄 139-146)을 그대로 옮긴 것이다(재구현 아님, `LAM=3.0`). instance 를 `instance` 필드로 묶고, 각 instance 에서 `E.lex_key(complete, closed - LAM*E.MACRO_COST[macro], makespan)` 사전식 최댓값을 고른 행이 a\* 다.

| 축 | n (instances) | a\* 완주율 | mean(closed/total) | mean(makespan), 완주판만 |
|---|---|---|---|---|
| battery | 18 | 100% (18/18) | 93.0% | 19.8 (완주판 n=18) |
| **fault** (현재 세대, 헤드라인) | 22 | 100% (22/22) | 93.0% | 21.8 (완주판 n=22) |
| **zone** (n=2, 최약축) | 2 | 100% (2/2) | 96.5% | 30.3 (완주판 n=2) |

- `battery`: oracle/out/battgrid_0805_s1.jsonl (18 instances = 6 fire points x 3 severities, all 3 arms) (n=18)
- `fault (현재 세대, 헤드라인)`: oracle/out/firegrid_s{fault,faultidle}.jsonl 의 instance 로 특정한 22개 현재-세대 fault instance (NOOP/Replace 2-arm 메뉴, 이번 STEP D 런) -- 헤드라인 (n=22)
- `zone`: oracle/out/zcausal_reform/ STEP 10 (blk, cov 두 arm-crossed 사건군, n=2 -- 가장 약한 축) (n=2)

> zone 축은 n=2(blk, cov 두 사건군)뿐이다 -- **가장 약한 축이고, 과잉해석하지 말 것.** 완주율이라는 말이 여기서는 "두 사건군 중 a\* 가 완주로 끝난 비율"이라는 뜻이지, 표본이 많은 통계가 아니다.

### 3-A. fault 축은 두 세대다 -- 풀링한 n=40 천장은 어디에도 없다

`oracle/out/firegrid_merged.jsonl` 은 CANONICAL(=`wm_datasets.CANONICAL`, `openworld_merged.jsonl`) + 이번 STEP D 런의 fire-grid 를 합친 것이다(`merge_firegrid.py` docstring 그대로 -- novelty 교정용 분산을 더하려고 설계된 합병이지, 성능을 재는 두 세대를 하나로 합쳐도 된다는 뜻이 아니다). kind=='fault' instance 40개는 **서로 다른 메뉴로 라벨된 두 그룹**이다:

| 출처 | instances | 라벨된 메뉴 |
|---|---|---|
| 신세대 (`firegrid_s{fault,faultidle}.jsonl`, 이번 STEP D 런) | 22 | NOOP, Replace |
| 구세대 (CANONICAL, macro 7/8 이전 라벨) | 18 | NOOP, Replace, Deprioritize, ForbidZone, ReformTeam |

두 그룹의 메뉴가 다르므로 a\* 가 같은 것을 뜻하지 않는다. **위 표의 `fault` 행 = 신세대 22개 헤드라인뿐이다.** 구세대 18개는 별도로, 헤드라인에서 제외한다고 명시한다:

> **제외됨(헤드라인 아님) -- 구세대 fault instance 18개** (5-arm 메뉴, macro 7/8 이전 라벨, CLAUDE.md "성능 근거 아님"): a\* 완주율 83% (15/18) · mean(closed/total) 91.9% · mean(makespan) 21.4 (완주판 n=15). **이 18개를 위 22개 헤드라인과 풀링한 n=40 천장은 이 문서 어디에도 없다.**

> **혼동하지 말 것 -- `test_llm7h.py` 의 게이트는 풀링해도 정당하다.** `fault 규칙 == 오라클 최선 (firegrid, n=40) PASS 40/40` 는 "이 instance 에서 규칙이 고른 팔과 오라클 최선이 같은가"라는 **instance 단위 이항 비교**라, 그 instance 의 메뉴가 2-arm 이든 5-arm 이든 잘 정의된다(둘 다 채점 가능한 이항 판정). 여기 이 절이 재는 것은 그와 다르다 -- **a\* 를 실제로 실행했을 때 결과(완주율/closed/makespan)** 는 메뉴가 넓을수록(5-arm) 더 나은 대안을 찾을 기회도 늘어나므로, 서로 다른 메뉴의 결과를 한 숫자로 합치면 두 세대의 차이가 아니라 메뉴 폭의 차이를 재게 된다. 게이트가 틀린 게 아니라, 게이트와 이 절이 **다른 것**을 재는 것이다.

### 3-B. zone 규칙 결함 -- STEP D 가 드러낸 것

`test_llm7h.py` 의 zone 결정-충실도 게이트(`zone 규칙 == 오라클 최선 (zcausal, n=2)`)는 `zcausal_reform/` 라벨이 없던 이전에는 n=0 로 조용히 PASS 했다. STEP D 가 4개 arm 파일을 채운 지금은 실제로 돌고, **FAIL 한다**:

```
zone 규칙 == 오라클 최선 (zcausal, n=2)   FAIL
  [('blk', 'RelocateBuild', 'RelocateBuild'),      <- agrees
   ('cov', 'RelocateBuild', 'NOOP')]               <- oracle says RelocateBuild, rule says NOOP
```

근거(`oracle/out/zcausal_reform/`, 파일을 그대로 읽은 값 -- 재구현 아님):

- `cov_noop.json`: status=stalled, closed=234, nav_blocked=1, root_covered=8
- `cov_reloc.json`: status=complete, closed=279

즉 root-covered 계열(`cov`)에서는 **RelocateBuild 가 빌드를 완주시키고 NOOP 은 정지한다** -- `reference_policy.py` 의 규칙("구역이 root 를 덮으면 NOOP -- 전역 이동이 더 손해")이 이 계열에서는 **틀렸다**. (이 태스크는 `reference_policy.py` 를 고치지 않는다 -- 고치면 이 문서의 모든 숫자가 조용히 다시 채점된다. 여기서는 결함을 **보고**만 한다.)

**파급 범위(blast radius) -- 직접 재확인, 인용 아님.** `results_4pol/*.jsonl` 8개 case 파일의 `decisions[]` 중 `truth=='ZoneTruth'` 를 전부 훑어 `zone_primitives` 를 직접 셌다 (193건):

- `battery`: 0건
- `fault`: 0건
- `zonecore`: 59건
- `all`: 22건
- `fault_battery`: 0건
- `fault_zone`: 26건
- `battery_zone`: 27건
- `zone`: 59건

결과: **193/193 전부** `root_covered == 0` 이고 `n_nav_blocked > 0` 이다 -- 이번 8-case 스윕에 등장하는 zone 사건은 전부 규칙이 오라클과 일치하는 것으로 검증된 `blk` 계열 영역뿐이고, 규칙이 틀린 `cov` 계열(root_covered>0)은 **한 건도 없다**.

**따라서 이미 보고된 zone 결정-충실도 숫자는 이 결함의 영향을 받지 않는다** (아래 §4 산출 1, Zone 열과 같은 값 -- `shadow.md` 원문에서 그대로 뽑음, 재계산 아님):

- `rule`: 0.0% (0/193)
- `surrogate`: 100.0% (193/193)
- `llm`: 66.3% (128/193)

> 세 문장 모두 참이고 다 필요하다: **(1)** `reference_policy.py` 의 zone 규칙은 root-covered 영역(`cov` 계열)에서 틀렸다. **(2)** 이번 8-case 스윕(193건)에는 그 영역의 결정이 **0건**이다(전부 root_covered==0). **(3)** 따라서 위·§4 에 이미 보고된 zone 숫자는 그대로 유효하다 -- 그러나 규칙 자체는 결함이 있으므로, 스윕을 root-covered 영역으로 넓히기 전에 반드시 고쳐야 한다(이 태스크의 범위 밖). (1)만 적으면 이미 낸 표를 근거 없이 무효화하는 것이고, (3)만 적으면 실제 결함을 묻는 것이다.

---

## 4. 같은-분모(same-denominator) 결정 비교 (shadow, N=435)

> **핵심만 먼저: 트리비얼(kind->macro 룩업표, B1) 이 435/435 = 100%로 두 학습 정책을 둘 다 이긴다.** `llm`(84.4%, 367/435)과 `surrogate`(70.6%, 307/435)가 배우는 결정 신호는 "이 사건이 무슨 kind 냐" 만으로 이미 100% 결정되는 문제다 -- 즉 이 shadow 결정지표에서 만큼은 kind 를 안다는 것 자체가 답을 다 준다. "LLM 이 결정을 잘 내린다"는 문장을 이 캐벗(B1=100%) 없이 남기면 오도하는 것이다.

입력: 120 rows / 699 decisions. 공유 분모 N = 435 (kind 는 알지만 필수 상태 필드가 없거나 ReformTruth 처럼 실측 격자가 없어 unscored 로 빠진 사건은 제외).

### 산출 1 -- producer 4개 (동일 사건·동일 분모 N=435)

| producer | n | 옳은 결정 (95% CI) |
|---|---|---|
| `rule` | 435 | 26.2% (114/435) [0.22, 0.31] |
| `surrogate` | 435 | 70.6% (307/435) [0.66, 0.75] |
| `llm` | 435 | 84.4% (367/435) [0.81, 0.87] |
| `macro (실제 enacted)` | 435 | 56.8% (247/435) [0.52, 0.61] |

| producer | Battery | Fault | Zone |
|---|---|---|---|
| `rule` | 0.0% (0/128) | 100.0% (114/114) | 0.0% (0/193) |
| `surrogate` | 0.0% (0/128) | 100.0% (114/114) | 100.0% (193/193) |
| `llm` | 100.0% (128/128) | 97.4% (111/114) | 66.3% (128/193) |
| `macro (실제 enacted)` | 37.5% (48/128) | 79.8% (91/114) | 56.0% (108/193) |

### 산출 2 -- B1 kind->macro 룩업표 (leave-one-out, 자기 자신 제외)

| kind | n | 옳음 | rate |
|---|---|---|---|
| Battery | 128 | 128 | 100.0% (128/128) |
| Fault | 114 | 114 | 100.0% (114/114) |
| Zone | 193 | 193 | 100.0% (193/193) |
| **합계** | **435** | **435** | **100.0% (435/435)** |

---

## 5. Case 별 상세 (macro 분포 · per-kind 적중 · 짝비교 부호검정)

<details>
<summary>case = <code>battery</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 100% (5/5) [0.57, 1.00] | 0% (0/11) | 21.6 ± 0.0 | 343 | 0.000 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 0% (0/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 21.6 ± 0.0 | 343 | 0.972 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×11 | Battery 0/11 |
| `surrogate` | Replace×20, ReformTeam×2 | Battery 0/20 |
| `dspy` | SwapBattery×20 | Battery 20/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/11) | 0% (0/11) | 0% (0/11) | 0% (0/8) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 0패 5무, 부호검정 p=1.000
- 짝지은 비교 `noop` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>fault</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/6) | — (완주 0) | 947 | 0.949 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×36 | Fault 0/6 |
| `surrogate` | Replace×20, ReformTeam×2 | Fault 20/20 |
| `dspy` | Replace×20, ReformTeam×2 | Fault 20/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/6) | 0% (0/36) | 0% (0/6) | 0% (0/4) | 0% (0/3) | 0% (0/2) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>zonecore</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/20) | — (완주 0) | 722 | 0.945 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (19/19) | 31.2 ± 1.9 | 639 | 0.952 | 12.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 65% (13/20) | 26.1 ± 1.6 | 439 | 0.965 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×50 | Zone 0/20 |
| `surrogate` | RelocateBuild×19, ReformTeam×6 | Zone 19/19 |
| `dspy` | RelocateBuild×13, NOOP×7 | Zone 13/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/20) | 0% (0/50) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `surrogate` | 0% (0/19) | 0% (0/25) | 100% (19/19) | 100% (14/14) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 65% (13/20) | 53% (8/15) | 40% (4/10) | 60% (3/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>all</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/17) | — (완주 0) | 837 | 0.191 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 70% (14/20) | 31.1 ± 8.5 | 652 | 0.939 | 9.6 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 85% (17/20) | 42.2 ± 20.9 | 547 | 0.949 | 10.8 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×47 | Battery 0/6, Fault 0/5, Zone 0/6 |
| `surrogate` | Replace×12, RelocateBuild×8, ReformTeam×8 | Battery 0/6, Fault 6/6, Zone 8/8 |
| `dspy` | ReformTeam×12, SwapBattery×6, Replace×6, RelocateBuild×5, NOOP×3 | Battery 6/6, Fault 6/6, Zone 5/8 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/17) | 0% (0/47) | 0% (0/17) | 0% (0/13) | 0% (0/8) | 0% (0/4) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 70% (14/20) | 60% (9/15) | 50% (5/10) | 40% (2/5) |
| `dspy` | 0% (0/20) | 0% (0/32) | 85% (17/20) | 87% (13/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>fault_battery</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 20% (1/5) [0.04, 0.62] | 0% (0/13) | 21.6 ± 0.0 | 788 | 0.213 | 12.0 |
| `surrogate` | 5 | 100% (5/5) [0.57, 1.00] | 45% (9/20) | 26.1 ± 3.9 | 474 | 0.968 | 8.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 100% (20/20) | 25.3 ± 4.9 | 409 | 0.968 | 10.2 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×37 | Battery 0/7, Fault 0/6 |
| `surrogate` | Replace×20, ReformTeam×2 | Battery 0/11, Fault 9/9 |
| `dspy` | SwapBattery×11, Replace×9, ReformTeam×2 | Battery 11/11, Fault 9/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/13) | 0% (0/37) | 0% (0/13) | 0% (0/10) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/22) | 45% (9/20) | 53% (8/15) | 60% (6/10) | 40% (2/5) |
| `dspy` | 0% (0/20) | 0% (0/22) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `noop` vs `dspy` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>fault_zone</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/13) | — (완주 0) | 874 | 0.947 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (20/20) | 32.9 ± 4.5 | 720 | 0.937 | 9.8 |
| `dspy` | 5 | 80% (4/5) [0.38, 0.96] | 80% (16/20) | 29.5 ± 2.8 | 647 | 0.939 | 10.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×43 | Fault 0/5, Zone 0/8 |
| `surrogate` | Replace×11, RelocateBuild×9, ReformTeam×8 | Fault 11/11, Zone 9/9 |
| `dspy` | Replace×10, ReformTeam×8, RelocateBuild×6, NOOP×3, Deprioritize×1 | Fault 10/11, Zone 6/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/13) | 0% (0/43) | 0% (0/13) | 0% (0/10) | 0% (0/6) | 0% (0/3) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 100% (20/20) | 100% (15/15) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/28) | 80% (16/20) | 93% (14/15) | 90% (9/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 0패 5무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>battery_zone</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 20% (1/5) [0.04, 0.62] | 0% (0/17) | 21.6 ± 0.0 | 646 | 0.009 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 45% (9/20) | 32.9 ± 4.5 | 720 | 0.937 | 9.8 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 90% (18/20) | 23.7 ± 1.7 | 399 | 0.967 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×41 | Battery 0/8, Zone 0/9 |
| `surrogate` | Replace×11, RelocateBuild×9, ReformTeam×8 | Battery 0/11, Zone 9/9 |
| `dspy` | SwapBattery×11, RelocateBuild×7, NOOP×2 | Battery 11/11, Zone 7/9 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/17) | 0% (0/41) | 0% (0/17) | 0% (0/13) | 0% (0/8) | 0% (0/4) |
| `surrogate` | 0% (0/20) | 0% (0/28) | 45% (9/20) | 27% (4/15) | 0% (0/10) | 0% (0/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 90% (18/20) | 93% (14/15) | 100% (10/10) | 100% (5/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 3패 1무, 부호검정 p=0.625
- 짝지은 비교 `noop` vs `dspy` — 0승 4패 1무, 부호검정 p=0.125
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

<details>
<summary>case = <code>zone</code>  (n=5 seeds, world_seed=1)</summary>

| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | ④ J/closed | min SoC | 남은 스페어 |
|---|---|---|---|---|---|---|---|
| `noop` | 5 | 0% (0/5) [0.00, 0.43] | 0% (0/20) | — (완주 0) | 722 | 0.945 | 12.0 |
| `surrogate` | 5 | 80% (4/5) [0.38, 0.96] | 100% (19/19) | 31.2 ± 1.9 | 639 | 0.952 | 12.0 |
| `dspy` | 5 | 100% (5/5) [0.57, 1.00] | 65% (13/20) | 26.1 ± 1.6 | 439 | 0.965 | 12.0 |

| 정책 | 고른 매크로 | 종류별 적중 |
|---|---|---|
| `noop` | NOOP×50 | Zone 0/20 |
| `surrogate` | RelocateBuild×19, ReformTeam×6 | Zone 19/19 |
| `dspy` | RelocateBuild×13, NOOP×7 | Zone 13/20 |

| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |
|---|---|---|---|---|---|---|
| `noop` | 0% (0/20) | 0% (0/50) | 0% (0/20) | 0% (0/15) | 0% (0/10) | 0% (0/5) |
| `surrogate` | 0% (0/19) | 0% (0/25) | 100% (19/19) | 100% (14/14) | 100% (10/10) | 100% (5/5) |
| `dspy` | 0% (0/20) | 0% (0/20) | 65% (13/20) | 53% (8/15) | 40% (4/10) | 60% (3/5) |

- 짝지은 비교 `noop` vs `surrogate` — 1승 4패 0무, 부호검정 p=0.375
- 짝지은 비교 `noop` vs `dspy` — 0승 5패 0무, 부호검정 p=0.062
- 짝지은 비교 `surrogate` vs `dspy` — 0승 1패 4무, 부호검정 p=1.000

</details>

---

## 6. Post-hoc validation (V1-V4, 8 case x 4 checks = 32)


V1 LLM lane 이 진짜인지(canonical 로 조용히 폴백된 것이 아닌지) · V2 noop 이 정말 noop 인지 · V3 빈 board 가 없는지 · V4 판 수가 5 seeds x 3 policies = 15 인지. 아래 각 case 마다 네 줄씩 반드시 찍는다(조용한 생략 금지).

#### case = battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 11건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = fault
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 22/22 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 22/22 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 36건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = zonecore
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 50건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = all
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 32/32 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 32/32 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 47건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = fault_battery
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 22/22 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 22/22 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 37건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = fault_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 28/28 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 28/28 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 43건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = battery_zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 41건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

#### case = zone
- V1 [PASS] canonical 정책이 이 case 에 없다(이번 스윕은 noop,surrogate,dspy 만 돈다 -- 예상된 상태). enacted-macro 시퀀스 동일성 검사를 못 하므로 llm-필드 검사로 대체한다. dspy 판이 enacted 한 macro 는 20/20 결정 전부 자기 자신의 llm shadow 선택과 일치했고, enacted 태그도 20/20 전부 'dspy' -- 폴백(canonical 이 대신 채워짐) 증거 없음.
- V2 [PASS] noop 판의 macro 50건 전부 NOOP.
- V3 [PASS] 빈 board(n_decisions==0) 없음 (판 15개 전부 결정 >=1).
- V4 [PASS] 판 수 15 (5 seeds x 3 policies) 그대로.

---

## 7. 한계

- 통계적 유의성 없음 -- 시드 5개, 부호검정(sign test) 최소 p=0.062 (`RESULTS_LLM7H.md` 와 같은 한계).
- `world_seed` 고정(=1) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다.
- `zone` 과 `zonecore` 는 별도 스윕 두 번을 돌렸으나 통계치가 완전히 동일하다(`diff artifacts_4pol/zone.md artifacts_4pol/zonecore.md` 가 빈 diff) -- 두 개의 다른 시나리오가 아니라 사실상 하나의 시나리오다.
- shadow 채점은 **상태조건부 결정 충실도**다("이 상태에서 이 정책이 a\* 를 골랐겠는가"). 결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.

