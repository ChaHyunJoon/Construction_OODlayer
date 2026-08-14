# 라우터 3-way · 자연어 해석 · DP 천장 — 2026-08-14 결과

> 이 문서는 `docs/superpowers/plans/2026-08-14-router-ui-demo.md` 실행 결과다.
> 계획 대비 **의도적 편차**가 여러 개 있고, 전부 §5 에 이름과 이유를 적었다.
> **숫자를 인용하기 전에 §5 와 §6 을 먼저 읽을 것.**

<!-- 이 문서에 objective_hash 문자열을 적지 않는다 (Global Constraint 4:
     audit_objective.py 항목 9 가 문서에 박힌 해시를 스테일로 판정한다). -->

## 1. 무엇을 만들었나

| 산출물 | 경로 | 무엇인가 |
|---|---|---|
| 4정책 × 7case 비교표 | `artifacts_4pol/COMPARE.md`, `compare.html` | 요구된 표 |
| 전체 리포트 | `artifacts_4pol/FINAL.md` | 기존 조립기 산출 (게이트를 열어 되살렸다) |
| 라우터 3-way | `tools/monitor/lane_select.jl` | 분기표(순수 함수) + 전수 단위검사 |
| 자연어 해석 | `tools/monitor/narrate.jl` | 결정적 템플릿(LLM 호출 없음) + 계약 검사 |
| DP 천장 | `dp_oracle/{grid_spec,samples,value}.json` | 상수-팔 반사실 표집 (§5-C 를 반드시 읽을 것) |
| 화면의 목적함수 | `GET /objective` + 대시보드 OBJECTIVE 스트립 | J 에 energy 가 들어 있다는 주장을 화면에서 검증 가능하게 |

## 2. 비교표

<!--TABLE-->

## 3. 재현 절차

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing

# (1) 3정책 스윕 — 7 case x 30 seed x 3 policy
bash run_4pol_parallel.sh --jobs 26 --policies canonical,surrogate,dspy

# (2) DP 격자 + 표집 + 풀이
cd dp_oracle
../../.venv/bin/python derive_grid.py --results ../results_4pol --out grid_spec.json
../../.venv/bin/python sample_grid.py --jobs 20 --seeds 1,2,3,4,5,6
../../.venv/bin/python dp_solve.py
cd ..

# (3) dp 레인 스윕 — value.json 을 조회하는 실행 레인
bash run_4pol_parallel.sh --jobs 26 --policies dp --shards-dir results_4pol/shards_dp

# (4) 표
bash finish_tables.sh
```

## 4. 게이트

<!--GATES-->

## 5. 계획 대비 의도적 편차 — 전부 실측이 강제한 것

### 5-A. 라벨러를 건드리지 않았다 (계획서에 이미 적힌 편차)

계획서 "spec 대비 의도적 편차" 절 그대로다. 대신 천장 계산이 **미측정으로 낮아진다.**
실측 결과: `battery` 18 · `fault_current` 22 · `zone` 2 instance 가 **전부 J 채점 불가**다
(`energy_J` 없음). 즉 기존 `oracle` 천장 행은 **전 축이 미측정**이며, 그 사실이 표에 이름으로
뜬다. 0% 로 렌더하지 않는다 — 그건 "천장이 0%" 라는 거짓 주장이다.

부분 채점도 채점으로 치지 않는다: a\* 는 팔들 사이의 argmax 라, 재는 팔만 남겨 argmax 를
돌리면 메뉴가 잘린 채 천장이 나온다(낙관 편향).

### 5-B. 격자 축의 편차 3개 (`grid_spec.json` 의 `deviations` 필드에 기계로도 남아 있다)

- **D-a `pend_f` 의 정의.** 원 설계는 "미해결 고장 수" 라고 적었지만 그런 카운터는 이 하니스에
  **존재하지 않는다**(결정 레코드에도 스트림에도 없다). 실제로 존재하고 fault 축을 실측으로
  가르는 변수는 `agent_pending` 이다(firegrid 격자에서 42 instance 완전분리, `oracle_macro`
  와 `reference_policy.py:190` 이 둘 다 그 술어를 쓴다). 없는 변수를 지어내는 대신 있는 변수를
  이름 붙여 썼다.
- **D-b** 그 귀결로 원문 §3.2 의 `evt=Fault ∧ pend_f=0 → INFEASIBLE` 규칙을 **뺐다.** D-a 의
  정의에서 그 칸은 실재하고 이미 측정된 상태다(`faultidle` 계열). 정의를 바꾸고 규칙을 그대로
  두면 측정된 칸을 "정의상 불가능" 으로 지우게 된다.
- **D-c `pend_f = "na"` 칸.** zone/reform 사건에는 영향받은 로봇이 없어 `agent_pending = -1`
  이다. 이를 결측으로 보고 버리면 결정 3953건 중 **2568건**(= zone 787 + reform 1781, 정확히
  일치)이 통째로 사라져 **격자에서 zone 축이 조용히 증발한다.** "일감 0" 과 "이 축이 적용되지
  않음" 은 다른 상태이므로 섞지 않고 별도 칸으로 남겼다.

### 5-C. ★ DP 는 backward induction 이 **아니다** — 이 문서에서 가장 중요한 편차

원 설계 §7 은 결정 epoch 마다 `(c, s̃′)` 를 재고 Bellman 으로 뒤에서 풀어 올라간다. 그러려면
**epoch 단위 비용 분해**가 필요한데, 이 하니스가 J 를 내는 단위는 **판**이다 — `makespan`·
`energy_J`·`complete` 가 전부 판 단위 집계다. 판 단위 J 를 결정 개수로 임의 배분하면 그 배분
규칙이 곧 결과가 되므로, **배분하지 않았다.**

그래서 이 표의 DP 가 실제로 푸는 것은:

```
Q(s̃, a) = E[ J(판 전체) | 판이 s̃ 를 지났고, 그 판의 모든 결정을 a 로 집행했다 ]
V(s̃)    = min_a Q(s̃, a)          a*(s̃) = argmin_a Q(s̃, a)
```

= **상수-팔 정책군 안의 최선**이다. 두 가지 귀결을 숨기지 않는다:

1. **credit assignment 미해결.** 판에 결정이 n 개면 그 n 개 칸이 **같은 J 하나를 공유**한다.
2. **상수-팔 정책군은 실행 정책보다 좁다.** 실행 정책들은 사건마다 팔을 바꿀 수 있다. 따라서
   V 가 실행 정책의 실현값보다 **나쁠 수 있고**, 그런 칸이 있으면 원 설계 §8.7 대로
   **"천장" 이라는 이름을 쓰지 않는다.** §6 에 그 측정을 싣는다.

이 두 한계는 `value.json` 의 `known_limits` 필드에도 기계로 박아 넣었다 — 소비처가 이 문서를
읽지 않아도 오해하지 않게.

### 5-D. `zone_s = cov` 는 표본이 없다 (원 설계 §10(2) 가 예측한 그대로)

현행 세대 스윕의 zone 결정 787건이 **전부** `root_covered == 0`(= `blk` 계열)이다. `cov` 는
주입으로만 만들 수 있고 이 사이클에서 만들지 않았다 → 그 칸은 `UNREACHABLE` 로 남는다.
따라서 기존 zone 규칙의 알려진 결함(`cov` 계열에서 오라클과 어긋남)을 이 DP 도 고치지 못한다.

### 5-E. 코드 세대에 관한 정직한 기록

스윕은 **한 커밋**에서 돌았다(라우터 3-way · 서술기 · dp 레인 · 격자 재유도를 한 커밋으로
묶은 이유가 이것이다 — 셋을 따로 커밋하면 스윕 도중 세대가 갈린다). 다만:

- 대시보드/서버(`dashboard.html`, `server.jl`)와 데모 판 렌더 관련 변경은 스윕 **이후** 커밋이다.
  이 파일들은 UI 전용이라 비교 숫자를 만들지 않는다.
- 표집(`sample_grid.py`)과 스윕은 **같은 시각에 병렬로** 돌았다. 부하가 달라지지만 이 표의
  지표는 전부 **sim 초**와 **J** 라 벽시계와 무관하다. 벽시계(`wall_seconds`)는 그래서 이
  문서의 비교 축이 아니다.

## 6. 알려진 구멍 (숨기지 않고 재서 적는다)

<!--HOLES-->

## 7. 이 사이클에서 하지 않은 것

- 라벨 재생성(energy-only 모드로 fault/zone 라벨을 다시 내기). §5-A.
- 진짜 backward induction. §5-C — 이건 계획서가 2일로 잡은 캠페인이다.
- `zone_s=cov` 주입 격자. §5-D.
- `reference_policy.py` 대체와 DISAGREEMENT 리포트 (원 설계 §8.6 — 계획서 §5.6 이 이미 범위 밖).
- surrogate 를 φ̃ 위에서 재학습 (원 설계 §9).
