# 원거리 창고 기하 — 4지표 결과 행렬 (2026-08-12)

작성 2026-08-12. 선행: `DEPOT_DISTANCE_SWEEP_2026-08-12.md`(D=40 결정) · `ORACLE_REBUILD_2026-08-09.md`
(격자 파라미터 단일 진실원) · `RESULTS_LLM7H.md`(구세대, 가까운 창고 — 이제 이 문서로 대체됨).
계획: `.superpowers/sdd/2026-08-12-far-depots-and-metric-matrix/`(task-1 ~ task-10 브리프).

> **한 줄 요약.** 창고를 빌드에서 눈에 띄게 멀리(D=40) 옮긴 기하에서 실패 케이스 7종 × 컨트롤러
> 3종(규칙/서로게이트/LLM) + 오라클 격자를 재서 4지표(완주율·결정 적중률·빌드 시간·J/closed) 표를
> 확정했다. 이 과정에서 배터리 기준 규칙의 깊은 방전 임계값을 0.2→0.3 으로 **강화**했다(뒤집은 게
> 아니다 — 근거는 §4-a). 표는 **셀당 n=1**(단일 OOD 시드·단일 world 시드)이라 신뢰구간이 아니라
> 점 추정으로만 읽어야 한다(§7).

---

## 0. 이 문서가 대체하는 것

`RESULTS_LLM7H.md` 는 **가까운 창고 기하**(옛 기본값)에서 측정한 결과다. 이번 작업(Task 8)이 창고
거리 기본값을 `D=40.0` 으로 바꿨으므로 그 문서의 수치는 지금 배포 기하를 대표하지 않는다.
`RESULTS_LLM7H.md` 맨 위에 세대 배너를 붙였다.

---

## 1. 기하 세대

세 데이터 파일(`results/matrix_fardepot.jsonl` 21행, `oracle/out/n44_plus78_fardepot.jsonl` 13행)
모두 레코드마다 동일한 `geometry` 를 갖는다:

```json
{"depot_mode": "fixed", "depot_distance": 40.0, "station_keeping": true}
```

**D=40 을 고른 근거** (`DEPOT_DISTANCE_SWEEP_2026-08-12.md` 요약, 전문은 그 문서를 볼 것):

- D ∈ {25, 40} × {battery, fault} 를 world seed 1 · OOD seed 1 · 예비 2 대로 순차 실행해 재봤다.
  **네 판 전부 완주**했고(closed 287/305, sim 20.1s, 287.9 J/cl, min_soc 0.973 — 네 행이 전부
  동일한 이유는 두 OOD 종류가 우연히 같은 지점에서 같은 매크로 `Replace` 로 풀렸기 때문이다),
  창고 거리는 어떤 지표도 움직이지 않았다(파견된 예비의 추가 이동이 critical path 밖에 있다).
- D=15 는 **측정하지 않았다**. 빌드 footprint 반경 ≈13, 겹침 경고 임계값이 `D < 1.2×radius = 15.6`
  이라 D=15 는 이미 그 경고 구간 안쪽 — "창고를 멀리 둬도 완주하는가"라는 질문과 무관한 처음부터
  나쁜 끝값이라 스윕을 6판에서 4판으로 줄였다. **"D=15 는 완주 못 한다"는 주장이 아니다 — 측정
  자체를 안 했다.**
- 계획의 선택 규칙("완주하는 가장 큰 거리")에 따라 측정된 두 값(25, 40) 중 **큰 쪽 = 40.0** 을
  기본값으로 확정했다. 정박(station-keeping) 은 두 거리 모두 **PASS 119/119**.

세 소스 모두 이 값으로 일치한다: `src/respec/ood_injection.jl` (`SPARE_DEPOT_DISTANCE = Ref(40.0)`),
`tools/demos.jl:1575`, `tools/demos.jl:2754`.

---

## 2. 데이터 — 이미 존재함 (재생성하지 않음)

두 파일 모두 이 작업 이전에 이미 만들어졌다. 아래 표 생성 단계(§3)는 이 둘을 **읽기만** 한다 —
시뮬레이션은 다시 돌리지 않았다.

| 파일 | 행 수 | 무엇 | 시드 |
|---|---|---|---|
| `results/matrix_fardepot.jsonl` | 21 | 실패 케이스 7종 × 컨트롤러 3종(canonical/surrogate/dspy) | OOD seed 1, world seed 1, 예비 3 |
| `oracle/out/n44_plus78_fardepot.jsonl` | 13 | 오라클 라벨 격자(battery 3중증 × 3팔=9, fault 1×2=2, zone 1×2=2) | seed 1, `DS_VALID_ONLY=1` |

---

## 3. 재현 명령

**전제**: DSPy 정책 서비스가 `http://127.0.0.1:8077` 에 떠 있어야 한다(`SURROGATE`/`LLM` 열이
조용히 canonical 로 폴백하는 것을 막기 위해 `run_matrix.sh` 가 시작 전에 `/health` 를 확인하고,
죽어 있으면 **행렬 생성 자체를 거부한다** — exit 3).

### 3-a. 평가 행렬 (`results/matrix_fardepot.jsonl`)

`.superpowers/sdd/2026-08-12-far-depots-and-metric-matrix/run_matrix.sh`:

```bash
# usage: bash run_matrix.sh <seed> [outfile]
SEED=1
OUT=results/matrix_fardepot.jsonl
CASES="battery fault zone fault_battery fault_zone battery_zone all"
DSPY="http://127.0.0.1:8077"

cd wm4spacecraft_manufacturing
for CASE in $CASES; do
  python llm_ood_eval.py run --case "$CASE" --seeds "$SEED" \
      --policies canonical,surrogate,dspy \
      --dspy-url "$DSPY" --out "$OUT"
done
```

**순차 실행 강제**: `run_lego_demo` 가 HiGHS MILP 로 스케줄을 푸는데, 동시 실행이면 CPU 경합이
다른 해를 낼 수 있어(다른 문서에서 반복 확인된 함정) 두 실행을 겹치지 않게 한다. 실제로 이 21행은
7 케이스를 **한 줄씩** 순서대로 돌려서 만들었다(85~97분 소요, 케이스당 800~930초).

### 3-b. 오라클 라벨 격자 (`oracle/out/n44_plus78_fardepot.jsonl`)

`.superpowers/sdd/2026-08-12-far-depots-and-metric-matrix/run_oracle.sh`:

```bash
cd wm4spacecraft_manufacturing/oracle
DS_KINDS=battery,fault,zone \
DS_SEEDS=1 \
DS_SPARES=3 \
DS_VALID_ONLY=1 \
DS_RESUME=1 \
DS_OUT=out/n44_plus78_fardepot.jsonl \
julia +lts --project=../.. gen_oracle_dataset.jl
```

**축소 사실**: 계획(task-9-brief §Step4)은 `DS_SEEDS=1,2,3,4`(≈72런, ≈5시간)를 요청했다. 실제로는
`DS_SEEDS=1` 만 돌렸다(≈13런). 시드 반복은 없다 — n 은 셀마다 §7 에 그대로 적는다.

### 3-c. 최종 표 생성 (이번 Task 10의 유일한 실행)

```bash
cd wm4spacecraft_manufacturing
python results_matrix.py --runs results/matrix_fardepot.jsonl \
    --oracle oracle/out/n44_plus78_fardepot.jsonl \
    --out results/matrix_fardepot
```

---

## 4. 기준 정책 재유도 — 세 가지 판정

계획(task-10-brief)이 정한 절차대로, 표를 만들기 전에 `reference_policy.py` 의 규칙이 새 기하
(D=40)에서도 유지되는지 새 오라클 격자(§2)로 확인했다. 세 종류 모두 확인했고, 결론은 **하나만
바뀌었다**(battery 임계값). 코드 변경은 `reference_policy.py` 의 `BATTERY_DEEP_SOC` 상수·그
주석·`BASIS` 문자열 세 개뿐이다 — fault/zone 의 분기 로직은 손대지 않았다.

### 4-a. battery — 임계값을 0.2 → 0.3 으로 **강화** (뒤집힘이 아님)

오라클 격자(`n44_plus78_fardepot.jsonl`, seed 1)의 battery 9 instance:

| SoC | NOOP | Deprioritize/Replace | SwapBattery |
|---|---|---|---|
| 0.02 | 미완주 (closed 163/313) | Replace 미완주 (215/313) | **완주** (291/313, 20.1s, 273.7 J/cl) |
| 0.30 | 미완주 (274/313) | Deprioritize 미완주 (274/313, 동일) | **완주** (291/313, 20.1s, 273.7 J/cl) |
| 0.50 | 완주 (291/313, 18.3s, 253.7 J/cl) | 완주 (291/313, 18.3s, 253.7 J/cl) | 완주 (291/313, 20.1s, 273.7 J/cl) |

0.30 에서 **SwapBattery 만 완주**하므로 깊은 방전 쪽에 속해야 한다. 0.50 에서는 세 팔 다 완주하고
NOOP/Deprioritize 가 더 싸다(18.3s vs 20.1s). 그래서 `BATTERY_DEEP_SOC = 0.3` 으로 올렸다
(비교는 그대로 `soc <= BATTERY_DEEP_SOC`).

**왜 강화이지 뒤집힘이 아닌가**: 옛 근거리 창고 기하(`battgrid_0805_s1.jsonl`)에서는 되살리는 두
팔(Replace, SwapBattery)이 **둘 다 완주**했고 SwapBattery 는 비용으로만 이겼다(0.2 < 1.0). D=40
에서는 Replace 가 **아예 완주하지 못한다**(163/215 모두 313 미만). 그래서 지금 이 규칙의 근거는
**완주 여부**이지 비용이 아니다 — 정답이 바뀐 게 아니라 그 정답을 뒷받침하는 이유가 더 단단해진
것이다.

**이 임계값 변경은 이 표의 채점에 영향을 주지 않는다.** `results/matrix_fardepot.jsonl` 21판의
`BatteryTruth` 결정을 전부 확인했다 — soc 값이 전부 **≤0.097**(최댓값 0.0966)이라 새 임계값(0.3)
이든 옛 임계값(0.2)이든 모두 "깊은 방전" 쪽으로 분류된다. 즉 어떤 칸의 결정 적중률도 이 변경으로
움직이지 않았다 — 옛 격자 재유도가 "결과를 유리하게 바꿨다"고 읽으면 안 된다.

### 4-b. fault — 규칙 유지, **재유도는 불가능**했다 (정직하게 적음)

새 격자에는 fault instance 가 **1개뿐**이다: NOOP 미완주(closed 163/313), Replace 미완주
(215/313) — **둘 다 미완주**라 완주 기반 증거가 전혀 없다. Replace 가 NOOP 보다 노드를 더 닫은 것
(215 vs 163)은 기존 규칙(`agent_pending > 0 → Replace`)과 **방향은 일치**하지만 그것을 **입증하지
않는다** — n=1 미완주 사건에서 "더 많이 닫았다"는 것은 규칙을 세울 근거가 못 된다.

그래서 규칙은 **그대로 유지**하되, 이번 패스에서 재검증되지 않았다는 사실을 `BASIS["fault"]` 에
명시했다. 옛 근거(`firegrid_merged.jsonl`, seed 1~6, 42 instance, `agent_pending>0→Replace` 완전
분리 24/24·18/18)는 이력으로 남겨 두되, **"이번 격자에서 재확인됐다"고 읽어서는 안 된다.**

### 4-c. zone — 규칙 유지, 격자 인스턴스는 **무승부**라 증거가 안 됨

새 격자의 zone instance 는 1개: NOOP 완주(20.1s, closed 291/313), RelocateBuild 완주(20.1s,
closed 291/313) — **makespan·closed 모두 완전히 동일한 무승부**다. 즉 이 인스턴스의 zone 사건은
실제로 항법을 막지 못했다 — 격자가 규칙을 확인도 반증도 하지 않는다.

독립적인 근거는 오히려 **평가 행렬**(`results/matrix_fardepot.jsonl`)의 `zone` 케이스에서 나온다.
같은 시드에서 canonical(=NOOP 규칙)은 58.0s / 500 J/closed 에 `ReformTeam` 복구 경보가 **5회**
뜬 반면, RelocateBuild(surrogate/dspy 둘 다 선택)는 39.0s / 492 J/closed 에 경보 **1회** 뿐이다.
격자는 이번엔 아무 말도 못 하지만, 실행 데이터가 규칙이 여전히 맞는 방향임을 보여준다.

---

## 5. 최종 표

```bash
cd wm4spacecraft_manufacturing
python results_matrix.py --runs results/matrix_fardepot.jsonl \
    --oracle oracle/out/n44_plus78_fardepot.jsonl --out results/matrix_fardepot
cat results/matrix_fardepot.md
```

`results/matrix_fardepot.md` 를 그대로 옮긴 것:

# 실패 케이스 x 컨트롤러 결과 행렬

각 칸: 완주 k/n · 결정 적중률 · 빌드 시간(완주 판 평균) · 닫힌 노드당 에너지 · 평균 최소 SoC

기하 세대: `{"depot_distance": 40.0, "depot_mode": "fixed", "station_keeping": true}`

| FAILURE CASE | ORACLE | CANONICAL | SURROGATE | LLM |
|---|---|---|---|---|
| Battery depletion | 3/3 · acc 100% · 19.5s · 267 J/cl · SoC 0.63 | 1/1 · acc 0% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 0% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 20.1s · 274 J/cl · SoC 0.97 |
| Robot breakdown | 0/1 · acc 100% · — · — · — | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 31.1s · 485 J/cl · SoC 0.96 |
| Keep-out zone | 1/1 · acc 100% · 20.1s · — · — | 1/1 · acc 0% · 58.0s · 500 J/cl · SoC 0.94 | 1/1 · acc 100% · 39.0s · 492 J/cl · SoC 0.95 | 1/1 · acc 100% · 39.0s · 492 J/cl · SoC 0.95 |
| Breakdown + battery | — | 1/1 · acc 25% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 25% · 31.1s · 485 J/cl · SoC 0.96 | 1/1 · acc 100% · 26.1s · 343 J/cl · SoC 0.97 |
| Breakdown + zone | — | 1/1 · acc 75% · 79.9s · 927 J/cl · SoC 0.90 | 0/1 · acc 100% · — · — · — | 1/1 · acc 50% · 69.1s · 689 J/cl · SoC 0.92 |
| Battery + zone | — | 1/1 · acc 0% · 79.9s · 927 J/cl · SoC 0.90 | 0/1 · acc 33% · — · — · — | 1/1 · acc 75% · 58.0s · 500 J/cl · SoC 0.94 |
| All three at once | — | 1/1 · acc 25% · 74.8s · 790 J/cl · SoC 0.91 | 1/1 · acc 75% · 32.0s · 476 J/cl · SoC 0.96 | 1/1 · acc 100% · 40.8s · 480 J/cl · SoC 0.95 |

- ORACLE 은 단축 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가 없어 `—`.
- 빌드 시간은 완주한 판만 평균한다. 완주율이 낮은 칸의 시간은 그만큼 낙관적이다 — k/n 을 같이 볼 것.
- 에너지 주지표는 닫힌 노드당(J/cl)이다. 총 에너지는 일을 덜 한 미완주에 유리해 쓰지 않는다.

**표 형태 확인**: 7행 × 4열. 조합 케이스 4행(Breakdown+battery, Breakdown+zone, Battery+zone, All
three)의 ORACLE 칸은 전부 `—`. 완주가 있는 모든 칸은 `k/n` 형태(오라클도 예외 없음: `3/3`, `0/1`,
`1/1`).

---

## 6. 관찰 — SURROGATE 만 유일하게 미완주, 정확히 두 zone-조합 케이스에서 (n=1, 결론 아님)

표에서 가장 눈에 띄는 셀은 SURROGATE 열의 `Breakdown + zone`(0/1)과 `Battery + zone`(0/1)이다.
**네 컨트롤러 열 전체에서 미완주가 나온 것은 이 두 칸뿐**이고, 둘 다 SURROGATE 다.

실측(원본 jsonl, 완주하지 않아도 기록되는 sim_seconds/energy 를 그대로 읽음):

| 케이스 | 정책 | complete | sim_seconds | closed/total | J/closed |
|---|---|---|---|---|---|
| zone (단독) | surrogate | **True** | 39.0 | 291/313 | 492 |
| fault_zone | surrogate | **False** | **123.1** | 174/313 | **1437** |
| battery_zone | surrogate | **False** | **123.1** | 174/313 | **1437** |

SURROGATE 는 zone 을 **단독으로는** 잘 푼다(RelocateBuild, 완주, 표의 다른 어떤 정책보다도 싼 축에
든다). 그런데 zone 이 **다른 OOD 와 함께** 오는 두 조합 케이스에서만 정확히 실패하고, 그 실패 판의
비용(123.1s, 1437 J/closed)이 **표 전체에서 가장 나쁜 값**이다.

**이것을 결론으로 읽지 말 것**: 셀당 n=1 이다. "두 번째 OOD 가 겹치면 RelocateBuild 의사결정이
막힌다"는 가설은 이 표가 시사할 뿐 입증하지 않는다. 반복 시드로 재현되는지가 다음 확인 대상이다.

---

## 7. 검증 — 조용한 정책 폴백은 없었다

`SURROGATE`/`LLM` 열이 서비스 문제로 조용히 `canonical` 로 대체되면 요약 행의 `policy` 필드는
여전히 `dspy`/`surrogate` 라고 적힌 채로 남는다(§0-a 함정). 그래서 요약 행이 아니라 **결정 하나
하나**를 감사했다:

```
21 rows, 129 decisions 전체에서 decisions[].enacted == 그 행의 requested policy: 129/129 일치, 0건 불일치
dspy 정책 7행의 decisions 40건 전부 enacted == "dspy"
```

DSPy 서비스(`http://127.0.0.1:8077`)는 이 21판을 도는 내내 응답했다 — 만약 중간에 죽었다면 그
구간의 `dspy` 결정은 `enacted != "dspy"` 로 남았을 것이고 위 감사가 그것을 잡아냈을 것이다.

---

## 8. 한계 (정직하게, 묻지 않고 적음)

- **셀당 n=1.** 평가 행렬은 OOD seed 1 · world seed 1 단 한 번씩이다. `results/matrix_fardepot.csv`
  는 각 셀에 Wilson 95% 신뢰구간(`success_lo`/`success_hi`)을 싣고 있지만, n=1 에서 그 구간은
  극단적으로 넓다(예: `battery/canonical` 는 `[0.2065, 1.0000]`) — **신뢰구간을 유의성 근거로 인용
  하지 말 것.** 이 표는 점 추정으로만 읽어야 한다.
- **오라클 격자는 13행, 단일 시드.** `n44_plus78_fardepot.jsonl` 는 seed 1 만 돈다(계획은 4시드를
  요청했었다 — §3-b). battery 만 severity 3단계 × 팔 3개 = 9 instance 로 상대적으로 두껍고,
  fault·zone 은 각 1 instance 뿐이다 — §4-b, §4-c 가 그 결과다.
- **fault 규칙은 재유도되지 못했다.** §4-b. 규칙은 유지했지만 새 기하에서 다시 세운 것이 아니라
  옛 근거를 그대로 들고 온 것이다.
- **SURROGATE 열은 재학습되지 않았다.** 계획(task-9-brief Step 5)은 배포 surrogate 를 새 격자로
  재학습하는 것을 요구했지만 실행하지 않았다. 이유: 새 격자(13행)는 배포 계약
  (`test_surrogate_support.py` 가 강제하는 `support == [0,1,2,3,4,7,8]`)이 요구하는 매크로 커버리지
  가 없다 — `wm_datasets.N44_PLUS78` 을 이 격자만으로 재지정하면 그 계약이 깨진다. 그래서
  `wm_datasets.py` 는 **손대지 않았다**(`N44_PLUS78 = "oracle/out/n44_plus78.jsonl"`, 그대로).
  **표의 SURROGATE 열은 근거리 창고 라벨(`n44_plus78.jsonl`)로 학습된 기존 배포 모델을 새
  원거리 기하 아래에서 평가한 것이지, 원거리 기하 라벨로 재학습한 모델이 아니다.** 이것이 §6의
  관찰(zone-조합에서만 실패)을 해석할 때 반드시 함께 읽어야 할 사실이다 — 모델이 이 기하의
  zone-조합 특징 영역을 아예 본 적이 없을 가능성이 있다.
- **조합 케이스 4행은 설계상 오라클이 없다.** 오라클 격자는 단일 OOD 사건만 굴린다(계획 범위) —
  `fault_battery`/`fault_zone`/`battery_zone`/`all` 의 ORACLE 칸이 `—` 인 것은 버그가 아니라
  격자의 정의역 밖이라는 뜻이다.
- **§6 의 관찰은 관찰이지 결론이 아니다.** 위에서 다시 적는다 — n=1, 재현 필요.
