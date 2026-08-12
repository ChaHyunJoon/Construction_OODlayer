# 창고 거리 D 스윕 → 기본값 확정 (2026-08-12)

**한 줄 요약.** D ∈ {25, 40} × {battery, fault} 를 world seed 1 · OOD seed 1 · 예비 2 대 · 순차
실행으로 재서, 둘 다 완주했다. 계획의 선택 규칙("완주하는 가장 큰 거리")에 따라 **기본값 = 40.0**.
D=15 는 창고 겹침 경고 자체의 임계값 안쪽이라 **측정하지 않았다**(근거는 §3).

관련 계획: [`task-8-brief.md`](../../.superpowers/sdd/2026-08-12-far-depots-and-metric-matrix/task-8-brief.md)

---

## 1. 실행한 스윕 (계획의 절차를 축소)

계획(Step 1)은 D ∈ {15, 25, 40} × {battery, fault} = 6 판을 요구했다. 실제로 돌린 것은 D ∈
{25, 40} 뿐인 **4 판**이다 — 이유는 §3.

**실행 스크립트**: `.superpowers/sdd/2026-08-12-far-depots-and-metric-matrix/run_sweep.sh`

```bash
for D in 25 40; do
  for CASE in battery fault; do
    SPARE_DEPOT_DIST=$D DEMO_MODEL=tractor.mpd DEMO_OOD=$CASE \
    DEMO_POLICY=canonical DEMO_SPARES=2 DEMO_SEED=1 DEMO_OOD_SEED=1 \
    MONITOR_STREAM=tools/monitor/streams/_sweep_D${D}_${CASE}.jsonl \
    DEMO_SUMMARY=wm4spacecraft_manufacturing/results/_sweep_depot.jsonl \
    julia +lts --project=. tools/monitor/run_demo.jl
  done
done
```

**★ 순차 실행.** HiGHS MILP 는 동시 실행 시 다른 스케줄을 낼 수 있어(다른 문서에서 반복 확인된
함정), 4 판을 겹치지 않게 한 줄씩 돌렸다.

## 2. 측정값 (계획 Step 3 의 표, 그대로)

| D    | case    | complete | closed  | sim_s | J/closed | min_soc |
|------|---------|----------|---------|-------|----------|---------|
| 25.0 | battery | True     | 287/305 | 20.1  | 287.9    | 0.973   |
| 25.0 | fault   | True     | 287/305 | 20.1  | 287.9    | 0.973   |
| 40.0 | battery | True     | 287/305 | 20.1  | 287.9    | 0.973   |
| 40.0 | fault   | True     | 287/305 | 20.1  | 287.9    | 0.973   |

Wall clock (판별 실측): 248 s, 243 s, 238 s, 237 s.

**네 행이 전부 같은 이유(중복이 아니다, 확인함).** battery 와 fault 두 OOD 종류가 이 스트림에서
**같은 지점(closed ≈ 77)에 사건을 하나씩** 일으켰고, 둘 다 **같은 매크로 `Replace`** 로 해소됐다.
같은 액션 → 같은 결과 함대 크기 → 같은 하류 스케줄이므로, makespan 과 에너지가 소수점까지
일치한다. 다만 `truth` 필드는 행마다 다르다(`BatteryTruth` vs `FaultTruth`) — 즉 이 네 판은
**서로 다른 실행**이고, 다만 이번 시드·이 발화 지점에서는 사건 종류가 결과에 아무 영향도 주지
않았을 뿐이다. 창고 거리 D 도 어떤 지표도 움직이지 않았다 — 파견된 예비 로봇의 추가 이동 거리가
critical path 밖에 있다는 뜻이다(25 → 40 으로 늘려도 makespan·에너지·완주 셋 다 불변).

## 3. D=15 를 측정하지 않은 이유

`run_sweep.sh` 헤더에 적은 근거를 그대로 옮긴다. 측정된 빌드 footprint 반경은 ≈13 이고,
`warn_depot_clearance`(`src/respec/ood_injection.jl`) 의 경고 임계값은 `D < 1.2 × radius` 다.
D=15 는 `1.2 × 13 = 15.6` 보다 **작으므로** 이미 경고 대상 구간 — 이 스윕이 답하려는 진짜 질문
("창고를 멀리 둬도 빌드가 끝나는가")과 무관한, 처음부터 안 좋은 쪽 끝값이다. 그 값을 다시 재도
경고가 이미 하는 말 이상은 나오지 않는다고 판단해, 계획의 6판을 4판으로 줄였다(비용: 6→4).

**중요**: 이 판단으로 인해 D=15 에서 실제로 완주하는지 여부는 **이 문서에서 확정되지 않는다.**
"완주 안 함"이 아니라 "측정하지 않음"이다. 필요하면 D=15 한 쌍(battery/fault)만 추가로 돌리면 된다.

## 4. 정박(station-keeping) 검증

```bash
for f in tools/monitor/streams/_sweep_D*.jsonl; do
  echo "== $f"; python tools/monitor/verify_depot_station.py "$f"
done
```

결과: **PASS — 119 개 주차-예비 관측치, 전부 자기 창고 좌표에서 tol=1.00 이내.** 4 개 스트림
전부에서 통과(개별 스트림별 세부 카운트는 콘솔 출력에만 남고 이 문서엔 합계만 기록).

## 5. 기본값 결정

계획의 규칙:

> **완주한** 거리 중 가장 큰 값을 고른다(창고가 눈에 띄게 멀어야 한다는 것이 이 작업의 목적이므로).
> 세 거리 모두 완주하면 40, 15만 완주하면 15.

D=25, D=40 **둘 다 완주**했다(§2). D=15 는 측정하지 않았으므로 규칙의 "세 거리 모두 완주" 조건을
문자 그대로 만족시킬 수는 없지만, 측정된 두 값이 모두 완주했고 이 작업의 목적(창고를 눈에 띄게
멀리 두기)에 부합하는 것은 **더 큰 값**이므로:

**기본값 = D = 40.0**

세 곳 모두 이 값으로 맞췄다(단일 소스가 아니므로 하나라도 어긋나면 드라이버마다 다른 세계가 된다):

- `src/respec/ood_injection.jl` — `const SPARE_DEPOT_DISTANCE = Ref(40.0)`
- `tools/demos.jl:1575` — `get(ENV, "SPARE_DEPOT_DIST", "40.0")`
- `tools/demos.jl:2754` — `get(ENV, "SPARE_DEPOT_DIST", "40.0")`

확인 명령과 결과:

```bash
grep -rn 'SPARE_DEPOT_DIST\|SPARE_DEPOT_DISTANCE' src/ tools/ | grep -v '\.md'
```

세 기본값 모두 `40.0`(또는 `Ref(40.0)`) 으로 일치함을 확인했다.

## 6. 곁다리로 고친 버그 — `warn_depot_clearance` 오탐

이번 스윕 로그에서 D=25 판마다 아래 경고가 **매번** 떴다:

```
Warning: 창고 거리 D 가 빌드 footprint 안쪽에 가깝다 — 창고가 빌드에 겹칠 수 있다
  D = 25.0
  footprint_radius = 25.0
```

원인: `warn_depot_clearance` 가 씬트리의 모든 노드를 스캔해 원점에서 가장 먼 노드까지의 거리를
footprint 반경으로 쓰는데, **아직 파견되지 않은 예비 로봇 자체가 씬트리 노드로서 정확히 거리 D 에
서 있다.** 그래서 계산된 반경이 언제나 D 이상이 되고, `D < 1.2 × radius` 는 **항상 참**이 되어
경고가 진짜 겹침 여부를 전혀 구별하지 못했다. `is_spare` 로 미파견 예비를 스캔에서 빼도록
고쳤다(`src/respec/ood_injection.jl`, `warn_depot_clearance` 안, 자동 조정은 여전히 하지 않음
— 경고만).

## 7. 한계 (정직하게)

- **셀당 n=1.** world seed 1 · OOD seed 1 고정 한 번씩만 돌렸다. 이 저장소의 다른 문서들이
  반복 지적하듯 seed 는 "다른 공장"(로봇 초기 배치) 축이지 확률성 축이 아니므로, 이 결론은
  "이 공장·이 발화 시점 조합에서는 D 가 결과에 영향이 없다"는 뜻이지 일반적으로 D 가 무의미하다는
  뜻은 아니다.
- battery 와 fault 가 우연히 같은 지점에서 같은 매크로로 풀렸기 때문에, 이번 4행은 사실상 D 에
  대한 **2 개의 독립 관측**(battery, fault 는 서로 확인 관계일 뿐 별도 증거를 더하지 않음)이다.
- D=15 는 측정하지 않았다(§3). "D=15 는 완주하지 못한다"고 인용하지 말 것 — 그 문장은 이
  스윕에서 나온 사실이 아니다.
