# 4정책 × 전 OOD case 비교표 — 5시간 무인 실행 계획 (2026-08-10)

목표: **oracle · surrogate · noop · llm** 네 정책의 성능 비교표를, **모든 OOD case** 에 대해
사용자 부재 5시간 안에 만든다.

> **먼저 읽을 것 — 이 계획의 가장 중요한 한 문장.**
> **`oracle` 은 실행 가능한 온라인 정책이 아니다.** `tools/monitor/policy.jl` 에 `oracle` 분기가
> 없다(`grep -i oracle` → 0건). 실행 가능한 lane 은 `noop` / `canonical` / `surrogate` / `dspy` 뿐이다.
> 따라서 표의 oracle 행은 **함께 달린 네 번째 주자가 아니라 천장(ceiling) 기준선**이다.
> 이 구분을 표에 명시하지 않으면 "oracle 이 1등"이라는 공허한 문장이 나온다 — oracle 은 정의상 1등이다.
> 자세한 것은 §2.

---

## 1. 5시간 안에 실제로 나오는 것 / 안 나오는 것

| | 산출 | 근거 |
|---|---|---|
| ✅ | `noop` / `surrogate` / `llm(dspy)` **3개 실행 lane** 의 case별 완주율·결정 적중·시간·에너지 | 새 시뮬 실행 |
| ✅ | `oracle` 행 = **결정 기준 a\*** 대비 적중률 (정의상 100%) + battery 축 실측 천장 | 기존 라벨 + `shadow_score.py` (시뮬 0회) |
| ✅ | case별 짝지은(paired) 비교 — 같은 `(case, ood_seed)` 위에서 정책 간 승/패 | `llm_ood_eval.py report` |
| ⚠️ | `oracle` 행의 **fault · zone 축 실측 천장** | **안 나온다.** §2-c 참조 |
| ❌ | 통계적 유의성 | 시드 5개로는 부호검정 최소 p=0.062. `RESULTS_LLM7H.md` 요약과 같은 한계 |

---

## 2. `oracle` 을 표에 어떻게 넣는가 (이 계획의 설계 결정)

### 2-a. oracle 의 두 가지 의미

이 저장소에서 "오라클"은 **완전탐색 라벨러**(`oracle/gen_oracle_dataset.jl`)다. 한 사건에서
**유효한 매크로를 전부 굴려 보고** 결과가 가장 좋은 팔을 정답 `a*` 로 기록한다. 즉 오라클은
"정책"이 아니라 **사후에 계산된 정답**이다. 표에 넣을 수 있는 형태는 둘뿐이다:

| 역할 | 무엇을 재나 | 비용 | 이번에 쓰는가 |
|---|---|---|---|
| **(A) 결정 기준** | 각 정책이 사건마다 `a*` 를 골랐는가 (= 결정 충실도) | 시뮬 0회 | **✅ 쓴다** |
| **(B) 결과 천장** | `a*` 를 실행했을 때의 완주/시간/에너지 | 라벨 롤아웃 필요 | **battery 만** |

(A) 는 이미 배선돼 있다 — `reference_policy.py` 가 `a*` 를 주고, `test_llm7h.py` §3 이 그 규칙이
오라클 실측 라벨과 일치하는지 검사한다(**battery n=18, 18/18 PASS — 오늘 실행 확인**).
기존 표의 "② 옳은 결정" 열이 바로 이 축이다.

### 2-b. 그래서 표의 oracle 행은 이렇게 읽는다

```
oracle  | 완주율: (battery 축만 실측) | 옳은 결정: 100% (정의상) | 시간·에너지: 해당 축만
```

**"옳은 결정 100%" 는 성능 주장이 아니라 눈금의 원점이다.** 이 행의 쓸모는 나머지 세 행이
그 원점에서 얼마나 떨어져 있는지를 보여주는 것뿐이다.

### 2-c. fault · zone 축 천장이 왜 안 나오는가 (오늘 실측)

```
$ python test_llm7h.py
  battery 규칙 == 오라클 최선 (battgrid, n=18)   PASS  18/18
  FileNotFoundError: oracle/out/firegrid_merged.jsonl        ← fault 축 하드 크래시
$ ls oracle/out/zcausal_reform/
  (비어 있음)                                                  ← zone 축 n=0
```

- **fault 축**: `firegrid_merged.jsonl` 이 없어 게이트가 **죽는다**(조용한 실패가 아니라 크래시라 다행).
- **zone 축**: `zcausal_reform/` 이 비어 있다. `test_llm7h.py:138-141` 이 예외를 삼켜 **표본 0으로
  조용히 통과**한다 — 이 저장소가 경고하는 바로 그 함정이다.

이 둘을 복구하는 것이 `ORACLE_REBUILD_2026-08-09.md` §II 의 STEP D 이고, **2~3시간**이 든다.
사용자 결정(2026-08-10): **집행 표 우선** — STEP D 는 이번 5시간에 돌리지 않는다.
따라서 표의 fault/zone oracle 칸은 **`미측정(STEP D 필요)`** 로 명시한다. 빈칸이나 0 으로 두지 않는다.

---

## 3. 측정된 비용 (추정 아님 — 2026-08-10 실측)

```
$ python llm_ood_eval.py run --seeds 1 --policies noop --case battery
[ 1/ 1] seed=1 policy=noop ... ok  117 s
```

| 항목 | 값 | 출처 |
|---|---|---|
| julia 기동 오버헤드 | **~88 s / 판** | 위 117 s − 그 판의 `wall_seconds` 29.4 s |
| 단일 kind case 의 sim wall | 30~60 s | 오늘 battery/noop = 29.4 s |
| `case=all`(4사건) sim wall | 94~137 s | `_backup_2026-08-10/llm_ood_eval.jsonl` 26행 |

정책별 sim wall (백업 26판 실측). **`dspy` 가 가장 빠르다** — 완주해서 일찍 끝나기 때문이고,
`noop` 이 가장 느린 것은 완주를 못 해 무진전 캡까지 도는 탓이다. 이 역전은 예산에 반영해야 한다:

| 정책 | n | wall mean | wall max | 결정/판 | 완주 |
|---|---|---|---|---|---|
| `noop` | 5 | **137.4 s** | 147.7 | 9.4 | 0/5 |
| `canonical` | 5 | 109.5 s | 120.6 | 9.8 | 4/5 |
| `surrogate` | 10 | 98.3 s | 113.4 | 7.8 | 8/10 |
| `dspy` | 6 | **93.7 s** | 107.9 | 5.8 | 6/6 |

**계획 단가**: 단일 kind case **150 s/판**, `all` case **200 s/판** (기동 88 s 포함, 여유 포함).

---

## 4. Case 목록 (`run_demo.jl:89-100` 의 `case_kinds` 가 유일한 출처)

| case | 사건 종류 | 비고 |
|---|---|---|
| `battery` | battery | oracle 천장 **있음**(n=18) |
| `fault` | fault | oracle 천장 없음 |
| `zonecore` | zone (**빌드 도중** 발화) | 결정이 실제로 갈리는 zone 변종 |
| `all` | fault+battery+zone 한 추첨 | 기존 `RESULTS_LLM7H.md` 와 **같은 설정** = 회귀 비교 가능 |
| `fault_battery` | 2종 복합 | |
| `fault_zone` | 2종 복합 | |
| `battery_zone` | 2종 복합 | |
| `zone` | zone (**빌드 전 1회 고정**) | `zonecore` 와 중복성 높음 → Tier 3 |

`--case` 는 `DEMO_OOD` 로 전달되고 `DEMO_OOD_STREAM3=1` 이 하드코딩(`llm_ood_eval.py:96`)이라
추첨은 **그 case 의 kind 집합 안에서만** 일어난다. 즉 `--case battery` 는 전부 battery 사건이다.
(확인: `run_demo.jl:431` `skinds = copy(kinds)`.)

---

## 5. 실행 계획 — 3티어, 데드라인에서 잘려도 표가 성립하게

### 5-a. 티어 구성

| Tier | case | 판 수 | 단가 | 누적 |
|---|---|---|---|---|
| **1 (필수)** | `battery`, `fault`, `zonecore`, `all` | 4×3×5 = **60** | 150/200 | **~2h 45m** |
| **2 (권장)** | `fault_battery`, `fault_zone`, `battery_zone` | 3×3×5 = **45** | 160 | **+2h 00m** |
| **3 (여유)** | `zone` | 1×3×5 = **15** | 140 | **+35m** |
| | | **120판** | | **~5h 20m** |

Tier 3 는 5시간을 넘긴다 — **의도적으로 그렇게 뒀다.** 데드라인 가드가 자르게 하고,
무엇이 잘렸는지 STATUS 에 남긴다. 조용한 절삭 금지(`NIGHT_PLAN` Global Constraint 5).

### 5-b. 루프 순서 — **case 를 완전히 끝내고 다음 case 로**

```
for case in [tier1..tier3]:          # 바깥
    llm_ood_eval.py run --case $case --seeds 1,2,3,4,5 --policies noop,surrogate,dspy
                        --out results_4pol/<case>.jsonl
```

이 순서가 중요하다. 정책을 바깥에 두면 시간이 모자랄 때 **어떤 case 는 noop 만 있고 dspy 가 없는**
반쪽 표가 남아 짝비교(`paired()`)가 통째로 무효가 된다. case 를 바깥에 두면 잘려도
**완성된 case 들만 남아** 각각이 유효한 4행 표가 된다.

### 5-c. 절대 병렬 금지 (함정 30)

56코어 / 125 GB 라 메모리는 더 이상 제약이 아니지만 **병렬은 여전히 금지다.** 이유가 메모리가
아니기 때문이다 — 동시 실행은 HiGHS 가 다른 스케줄을 내게 만들어 **정책 비교 자체를 무효화**한다.
`llm_ood_eval.py` 는 이미 `STRICTLY SEQUENTIAL` 로 돈다. 이 계획은 그 위에 case 루프만 얹는다.
**야간 실행 중 다른 julia 를 띄우지 말 것** (`pgrep -x -u $(id -u) julia` 로 확인).

---

## 6. 선행 조건 — 하나라도 어긋나면 5시간이 통째로 날아간다

실행 **시작 전에** 전부 통과해야 한다. 실패 시 즉시 중단(조용한 폴백 금지).

| # | 검사 | 통과 기준 | 어기면 생기는 일 |
|---|---|---|---|
| P1 | `echo $OPENAI_API_KEY` | 비어 있지 않음 | **llm lane 전체가 무효** — 서비스가 폴백해 `canonical` 결과를 `dspy` 이름으로 기록 |
| P2 | `curl -s 127.0.0.1:8090/health` | 200 | 〃 |
| P3 | `python audit_action_vocab.py` | exit 0 (6/6) | 어휘 누락이 **성능으로만** 샌다 |
| P4 | `python test_surrogate_support.py` | `support=[0,1,2,3,4,7,8]`, 7/7 | 지원 밖 팔이 에러 없이 후보에서 탈락 |
| P5 | `pgrep -x -u $(id -u) julia` | **빈 결과** | 함정 30 |
| P6 | `results_4pol/` | 비어 있음(또는 재개 의도) | 기존 측정 덮어쓰기 |

**P1/P2 가 이 계획의 단일 최대 위험이다.** `dspy_service` 는 LLM 호출이 실패하면 조용히
`canonical` 로 폴백하고 그 사실을 verdict 에만 남긴다(`policy.jl:11`). 5시간 뒤에
"llm 이 canonical 과 성능이 같다"는 표를 받게 되는데, 그건 **같은 정책을 두 번 잰 것**이다.

### 6-a. LLM lane 사후 검증 (반드시)

각 case 파일에 대해, `dspy` 행의 결정들이 **실제로 LLM 에서 나왔는지** 확인한다:
- `decisions[].producer` 가 `llm` 인 결정이 1개 이상
- `dspy` 와 `canonical` 의 선택 매크로 시퀀스가 **완전히 동일하면 의심** — 폴백 신호다

---

## 7. 조용한 실패 방어 (이 저장소의 지배적 실패 양식)

| 함정 | 방어 |
|---|---|
| case별 스위프가 기본 `--out` 을 공유해 서로 덮어씀 (함정 ①) | **case마다 `--out` 분리** — `results_4pol/<case>.jsonl` |
| zone 축 n=0 조용한 통과 (`test_llm7h.py:138-141`) | oracle 칸을 `미측정` 으로 **명시**, 0 으로 채우지 않음 |
| 라우터 fail-open 으로 정책이 덮어써짐 | **`--router 0`**(기본값) 유지 = 정책 고정. 라우터 실험은 이번 범위 밖 |
| `noop` 이 noop 이 아니었던 버그 (RESULTS §1-a) | 사후 검증: `noop` 행의 매크로가 전부 NOOP 인지 |
| 판이 사건 0개로 공허하게 성공 | `n_decisions > 0` 아니면 그 판 FAIL |

---

## 8. 산출물

```
wm4spacecraft_manufacturing/
  results_4pol/<case>.jsonl        case별 요약 (8개)
  artifacts_4pol/<case>.md         case별 표 (llm_ood_eval.py report --md)
  artifacts_4pol/shadow.md         oracle 기준 결정 충실도 (shadow_score.py, 시뮬 0회)
  artifacts_4pol/FINAL.md          ★ 최종 통합표 — 아래 형식
  _night/logs/4pol_<case>.log      실행 로그
  _night/status_4pol.jsonl         STATUS 줄 (재개·판정 근거)
```

### 최종 통합표 형식

case 하나당 한 블록, 각 블록은 4행:

```
### case = battery   (n=5 seeds, world_seed=1, router=0)

| 정책 | 완주율 | 옳은 결정 (vs oracle a*) | 빌드 시간(완주판) | J/closed |
|---|---|---|---|---|
| `oracle` (천장·비실행) | 실측 n=18 | 100% (정의상) | — | — |
| `surrogate` | x/5 | x% | x±x s | x |
| `noop` (바닥선) | x/5 | x% | — | x |
| `llm` (dspy) | x/5 | x% | x±x s | x |
```

fault/zone case 의 oracle 행은 **`미측정 (STEP D 필요)`** 로 채운다.

---

## 9. 데드라인 가드 / 재개

- 각 case 시작 전 **남은 시간 < 그 case 추정치** 면 그 case 를 건너뛰고 STATUS 에 `skipped` 기록.
- 축소 레버는 **시드 수만** (5→3). case 목록은 줄이지 않는다 — case 하나가 통째로 빠지는 편이
  모든 case 가 반쪽인 것보다 해석 가능하다.
- 재개: `results_4pol/<case>.jsonl` 이 이미 `5 seeds × 3 policies = 15행` 이면 그 case 건너뜀.
- 매 case 끝에 `STATUS 4pol <case> ok|fail rows=<n>` 을 stdout 마지막 줄에 남긴다.

---

## 10. 실행 순서 요약

```bash
# 0) 선행 조건 (§6) — 하나라도 실패하면 중단
# 1) LLM 서비스 기동 (백그라운드, 8090)
# 2) run_4pol.sh  — case 루프, 전 구간 순차, 데드라인 가드
# 3) shadow_score.py  → oracle 기준 결정 충실도 (시뮬 0회)
# 4) 통합표 생성 → artifacts_4pol/FINAL.md
# 5) verify_night.py 로 기계 판정
```

**아직 없는 것**: `run_4pol.sh` (§5-b 루프 + §6 선행검사 + §9 데드라인 가드). 이 계획 승인 후 작성.
`llm_ood_eval.py` / `shadow_score.py` / `verify_night.py` / `reference_policy.py` 는 **이미 있다**.

---

## 11. 이 계획이 주장하지 않는 것

1. **유의성 없음.** 시드 5개, 부호검정 최소 p=0.062.
2. **oracle 행은 경주 참가자가 아니다** (§2). "oracle 1등"은 정의상 참이라 정보가 없다.
3. **fault/zone 의 oracle 천장은 이번에 안 나온다** — STEP D 선행 필요 (~2-3h).
4. **world_seed 는 1 고정.** 다른 공장 배치에서의 일반화는 재지 않는다(README 축 분리).
5. shadow 채점은 **상태 조건부 결정 충실도**이지 결과 비교가 아니다. 완주·시간·에너지를
   shadow 로 말하면 안 된다.
