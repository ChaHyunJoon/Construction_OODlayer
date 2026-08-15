# DP oracle — 상태 추상화 + backward induction 으로 기준행동 a\* 를 다시 정의한다

- 날짜: 2026-08-13
- 대상 저장소: `Construction_OODlayer`, 브랜치 `oracle-rebuild-night-2026-08-10`
- 대체 대상: `wm4spacecraft_manufacturing/reference_policy.py` (전면 대체, §7)

---

> ## 🔴 개정 배너 (2026-08-13 밤) — 이 문서를 단독으로 읽지 말 것
>
> 이 문서는 **2026-08-13 오전**에 쓰였다. 같은 날 세 사건(결정성 프로브 → 목적함수 통일 →
> 배터리 물리 복구)이 지나가면서 아래 다섯 곳이 뒤집혔다. 개정 본문은
> **`docs/superpowers/specs/2026-08-13-router-ui-demo-design.md` §5** 에 있다.
>
> | 절 | 이 문서가 말하는 것 | 지금 참인 것 |
> |---|---|---|
> | **§4 전체**(§4.1·§4.2·§4.4·**§8.1**) | "replay 는 안 된다" → `fork-per-arm`(deepcopy) 채택 | **`sampling_mode: replay`.** 주입 순간 지문이 10/10 동일했고(`dp_oracle/PROBE_RESULT.md`), fork 는 프로세스 전역 `Ref`/싱글턴(RVO2 C++ 인스턴스·`BATTERY_FLEET`·`HAZARD_STATE`·`OOD_SCHEDULE`·`SIM_STEP`) 때문에 **구조적으로 불가능**하다. §4.4 위험과 §8.1 차단 게이트는 **삭제**된다. 비용모델도 재작성(워커당 착수 ~90s + **8.1s/rollout**) |
> | **§6 목적함수** | `gen_oracle_mc.jl` 의 `MC_COST_FAIL`·비용함수 승계, `e1_analyze.MACRO_COST` 값을 리터럴 인용 | 목적함수 단일 진실원은 **`objective.json`** 이고 **energy 가 J 의 축**이다. 상수 리터럴 복붙 금지(`audit_objective.py` 항목 1 이 12파일 스캔). **`dp_solve.py` 는 그 감사가 이름으로 지목한 소비처**라 처음부터 `objective.load()`/`J()` 경유여야 한다 |
> | (신규 제약) | — | J 는 완주행에 유한 `energy_J` 를 요구하는데 배터리 레이어가 `kind===:battery` 에서만 켜져 **`evt=Fault/Zone` 칸의 비용이 정의되지 않는다.** `md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` 의 energy-only 모드가 선행조건 |
> | **§3 격자 축** | 실측 지지집합 `soc` 0~0.0999 · `spares` 8~12 · zone 결정 전부 `blk` | 그 실측은 **구세대 스윕**이다. 배터리 물리 복구로 세계가 갈렸다(`noop` battery 완주 **30/30 → 0/30**, 정지 43회). 축을 현행 세대 `results_4pol/` 에서 **재유도**해야 한다 |
> | **§3.1 비교 대상** | surrogate φ = `e1_analyze.featurize()` (kind/macro one-hot) | 재구축 중인 φ 는 상태 6축(`features_agnostic.py:307`) + ψ 10축 + 교차 5 다. **결론은 유지** — 새 6축에도 `pend_f`·`zone_s` 축이 없어 조합 상태를 구별 못 한다 |
>
> **그리고 역할이 바뀌었다(사용자 결정, 2026-08-13):** DP 는 **라우터/UI 에 들어가지 않는다.**
> 최적해(천장)이므로 실행 정책과 같은 줄에 세우지 않고, 스윕 레인으로 돌려 결과만 기록해
> `FINAL.md` 의 천장 행이 된다. 따라서 **§8.6 의 `reference_policy.py` 전면 대체는 보류**이고
> 이 문서의 "대체 대상" 머리말도 그 범위에서는 유효하지 않다 — `reference_policy.py` 는
> 건드리지 않는다. §8.7(실행 정책이 V 를 넘으면 "천장"이라 부르지 않는다)은 **유지**한다.

---

## 1. 문제

발행된 8-case 결과표에서 **조합 case 4개(`all`, `fault_battery`, `fault_zone`, `battery_zone`)의
oracle 칸이 비어 있다.** 그 칸의 `0,0` 은 "모든 판이 실패했다"가 아니라 **"해당 격자가 아예
없다"** 는 뜻이다 (`artifacts_4pol/REPORT.md` §2 머리말, `results_matrix.py` 의 `ORACLE_KIND` 에
조합 키가 없음).

없는 이유는 사고사가 아니라 방법론의 한계다. 현재 오라클은 **arm-crossed 격자**다: 사건 하나를
고정하고 팔만 바꿔 굴려 결과를 비교한다. 사건이 둘 이상 섞이면 (i) 두 사건의 순서가 자유롭고
(ii) 첫 결정 이후 세계가 갈라져 두 번째 사건의 문맥이 팔마다 달라지므로, "같은 사건을 모든 팔로
굴린다"는 전제 자체가 성립하지 않는다. 반사실 트리는 사건 수에 지수로 늘어난다
(`reference_policy.py` 머리말: 사건 4개 × 팔 4개 = 256 런).

즉 **조합 case 는 격자로는 원리적으로 못 채운다.** 결과-천장이 없으므로 조합 case 에서
"실행 정책이 최적에서 얼마나 떨어졌는가"를 말할 근거가 지금 없다.

## 2. 접근 — 시퀀스가 아니라 정책 차원에서 정의한다

결정시점 상태를 저차원 information state `s̃ = φ(s)` 로 추상화하고, 그 격자 위에서 Bellman
backward induction 을 돌린다:

```
Q(s̃, a) = E[ c(s̃, a) + V(s̃′) ]
V(s̃)    = min_a Q(s̃, a)
a*(s̃)   = argmin_a Q(s̃, a)
```

이러면 a\* 가 **사건 시퀀스가 아니라 상태의 함수**로 정의되므로, 사건이 몇 개 섞이든 어떤 순서로
오든 그 시점의 s̃ 만 알면 a\* 가 나온다. 조합 case 의 빈 칸이 원리적으로 채워진다.

전이 `P(s̃′|s̃,a)` 는 **시뮬레이터를 생성모델로 써서 표집**한다 (해석적 모델도, 기존 로그에서의
경험 추정도 아니다 — 전자는 스케줄러/정체 꼬리를 못 담고, 후자는 실행되지 않은 팔의 칸이 비어
반사실 오라클이 재야 할 바로 그 자리가 빈다).

### 2.1 대가 — 숨기지 않고 재는 두 가지

1. **추상화 손실**: φ 가 버린 정보만큼 V 가 참 최적값보다 나쁠 수 있다. 그러면 실행 정책이
   "천장"을 넘을 수 있다. §8.7 이 이걸 지표로 측정하고, 넘으면 "천장" 이라는 이름을 쓰지 않는다.
2. **격자의 대부분은 도달하지 않는다**: 630판 스윕 실측에서 `spare_count` 는 8~12 만,
   `soc` 는 0.000~0.0999 만 나온다. 축을 전구간으로 깔면 예산의 다수가 현재 스트림이 절대
   만들지 않는 칸에 들어간다. 그래서 축을 **관측 지지집합 + 한 칸 밖**으로 깐다 (§3, 격자 B).

> 이 문서에서 `MDP_DESIGN §x` 는 `wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md` 의 절 번호다.
> 접두어 없는 `§x` 는 이 문서의 절이다.

## 3. 상태 추상화 φ̃

| 축 | 구간 | 왜 이 축인가 |
|---|---|---|
| `prog_b` (stage) | 4구간, 실측 범위 [0.185, 0.911] | **단조 비감소** — backward induction 의 DAG 를 보장하는 유일한 축 |
| `soc_b` | {≤0.02, ≤0.05, ≤0.10, >0.10} | 실측 지지집합 0~0.0999 + 한 칸 밖. 0.02 는 완주로 갈리는 칸이라 경계로 유지 |
| `spares_b` | {≤8, 9–10, 11, 12} | 실측 8~12 + 한 칸 밖 |
| `pend_f` | {0, 1, ≥2} | **조합 case 가 존재하는 이유. 현재 surrogate 의 φ 에 이 축이 없다** |
| `zone_s` | {none, blk, cov} | `blk` = nav_blocked>0 ∧ root_covered==0, `cov` = root_covered>0 |
| `evt` | {Battery, Fault, Zone, Reform} | 지금 결정 중인 사건 종류 = 팔 메뉴 A(s̃) 를 정한다 |

원시 4×4×4×3×3×4 = **2304 칸**. 정합성 가지치기(§3.2)로 유효 노드는 약 700 으로 줄어든다.

### 3.1 surrogate 의 φ 와의 관계 — "같은 state" 가 아니다

`e1_analyze.featurize()` 의 φ 는 **사건 서술자**(kind one-hot + macro one-hot + 그 사건의
soc/zone_overlap)이지 시스템 상태가 아니다. 결정적으로 **pending faults 축과 zone 활성 축이
없다** — 그래서 "zone 이 떠 있는 중에 battery 가 터진 상태"가 단일 battery 상태와 구별되지
않는다. 조합 case 를 풀려고 만드는 DP 가 정확히 그 조합을 상태로 못 보게 되므로, φ 를 그대로
쓸 수 없다.

또한 MDP_DESIGN §8.1 은 **kind one-hot 을 금지**한다(새 kind 가 들어올 자리가
없어진다). φ̃ 는 `evt` 를 팔 메뉴 선택에만 쓰고 값함수의 입력 축으로는 물리 서술자만 쓴다.

이 문서의 범위는 φ̃ 정의와 그 위의 DP 까지다. **surrogate 를 φ̃ 위에서 재학습하는 것은 범위
밖**(§9).

### 3.2 정합성 가지치기

다음 조합은 정의상 불가능하므로 표집하지 않고 `INFEASIBLE` 로 기록한다:

- `evt=Battery` ∧ `soc_b = >0.10` — 배터리 결정이 뜨는 조건 자체를 위반
- `evt=Zone` ∧ `zone_s = none`
- `evt=Fault` ∧ `pend_f = 0` — 고장 결정인데 미해결 고장이 없다
- `prog_b` 최저구간 ∧ `spares_b ≤ 8` — 개입 없이 스페어가 소모될 수 없다

가지치기 규칙은 `grid_spec.json` 에 데이터로 적는다. 코드에 흩어 놓으면 격자 정의가 두 곳이 된다.

### 3.3 팔 메뉴 A(s̃) 의 출처

630판 로그에서 `valid` 는 **`ZoneTruth`(2팔) 과 `BatteryTruth`(4팔) 에만 기록돼 있고
`FaultTruth`(705건) 와 `ReformTruth`(1555건) 은 빈 리스트다.** 따라서 팔 메뉴를 로그에서 읽으면
fault 축이 조용히 0팔이 된다. 메뉴는 `action_registry.json` 에서 가져오고, 그 사건에서 적용
가능한지는 시뮬의 유효집합 술어로 판정한다.

## 4. 표집 메커니즘 — 재현성에 의존하지 않는다

### 4.1 왜 replay 기반이면 안 되는가

원안은 "시드를 고정해 결정지점까지 replay → 팔별로 굴린다" 였다. 이 저장소에서는 성립하지
않는다:

- 동일 코드·동일 워크트리 재실행에서 monitor frames 214→204, **n_closed 149→123**
  (2026-08-11 실측, `docs/superpowers/specs/2026-08-12-parallel-30seed-sweep-design.md` §2).
  원인 미상이며 RNG 도 스레딩도 아니다.
- 동일 구성 재실행 makespan 68.175s vs 71.300s (+4.6%, `results/control_d40_samesession.jsonl`).

n_closed 가 149→123 으로 갈리면 replay 는 매번 다른 상태에 착지한다. `MDP_DESIGN_FROM_SCRATCH.md`
§13.2 (1) 이 요구하는 "결정 상태 s 는 모든 rollout 에서 동일" 이 깨지고, 평균은 `Q(s,a)` 가
아니라 `E_s[Q(s,a)]` 가 된다.

### 4.2 prefix-once, fork-per-arm

노드당 prefix 를 **한 번만** 굴리고, 실현된 그 상태에서 팔들을 in-process 로 분기시킨다:

```
for each node (요청 칸 c_req):
    world ← 정본 replay + 주입 (ψ, §5) ......... 1회, ~25s
    s̃_real ← φ̃(world)  ......................... 착지한 칸을 측정 (요청 칸이 아니라 이것이 라벨)
    for a in A(s̃_real):
        for k in 1..K:
            w ← deepcopy(world)
            (c, s̃′) ← 다음 결정 epoch 까지 진행  ~8s
            기록 (s̃_real, a, k, c, s̃′, capped, ...)
```

이 구조가 주는 것:

1. **결정성 불필요.** 모든 팔이 물리적으로 같은 하나의 실현에서 갈라지므로, 시드가 재현되든
   말든 "같은 s 에서 팔만 바꿨다"가 참이다. CRN 을 시드로 흉내내는 게 아니라 구성으로 얻는다.
2. **요청 ≠ 라벨.** 착지 실패가 손실이 아니라 다른 칸의 표본이 된다. 격자 채우기는 요청 목록을
   순회하는 것이 아니라 **모든 유효 칸이 ≥K 표본을 가질 때까지 반복**하는 루프가 된다.
3. **비용 급감.** prefix 가 샘플당이 아니라 노드당 1회다.

### 4.3 비용

샘플당 segment ~8s (판 중앙값 50.5s ÷ 결정 5~7회), prefix ~25s.

```
700 노드 × (25s + 3팔 × K=5 × 8s) = 700 × 145s ≈ 28 CPU-h
```

승인 예산(격자 B, ~105 CPU-h) 안이며, 남는 예산은 K 를 늘리거나(동점 판정이 표준오차에
걸리는 노드부터) 미달 칸을 다시 조준하는 데 쓴다.

### 4.4 위험 — `deepcopy` 가 안 될 수 있다

시뮬은 PyCall 을 통해 `rvo2`(C++) 를 쓴다. Julia `deepcopy` 는 PyCall 핸들 너머의 C++ 상태를
복제하지 못할 수 있다. **STEP 0 에서 반드시 먼저 검증한다** (§8.1).

실패 시 대체안: 팔마다 prefix 를 다시 굴리되(33s/샘플), 팔마다 착지한 칸을 각각 측정해
라벨한다. CRN 은 잃고 K 를 늘려야 하며 비용은 ~96 CPU-h 로 오른다 — 그래도 설계는 선다.
어느 경로를 탔는지는 산출물에 기록한다(`sampling_mode: fork | replay`).

## 5. concretization ψ(s̃) — 격자 전수를 고른 대가

격자칸을 시뮬에 세우는 함수를 새로 지어야 한다. 기존 주입 기계를 조립한다:

1. `world_seed=1` 정본을 `prog_b` 목표 구간의 첫 결정 epoch 까지 진행
2. `spares_b` ← `N_SPARE` 구성값 (개입 전에는 스페어가 소모되지 않으므로 구성값 = 상태값)
3. `pend_f` ← `schedule_studied_fault!` (`oracle/gen_oracle_mc.jl`) 로 고장 주입 —
   **일감을 진 로봇에** 건다 (`agent_pending>0` 이어야 fault 축이 의미를 가진다)
4. `zone_s` ← zcausal 주입기 (`oracle/run_step_d_zcausal.sh` 가 blk/cov 두 계열을 구분해 만든다)
5. `soc_b` ← graded battery 주입

**주입 후 실제 상태에서 φ̃ 를 다시 계산해 기록한다** (§4.2). 요청 칸과 다르면 그 표본은 버리지
않고 착지한 칸의 표본으로 센다. 어떤 요청으로도 표본이 안 생기는 칸은 `UNREACHABLE` 로 기록하며,
값을 지어내지 않는다.

## 6. 목적함수 — 새로 만들지 않는다

lexicographic tier 를 DP 에 넣는 문제는 **이미 풀려 있다.** `MDP_DESIGN_FROM_SCRATCH.md` §13.2
(2): `(complete → closed → makespan)` 사전식 순서는 기대값을 못 만들므로 **유한벌점 SSP 스칼라**
로 바꾸되, argmin 이 기존 순위를 재현하는지 `check_order_equivalence` 로 자동 점검한다.

이 설계는 `gen_oracle_mc.jl` 의 벌점(`MC_COST_FAIL`)·비용함수·순서동치 검사를 **그대로 물려받는다.**
tier 스칼라화도 constrained DP 도 새로 발명하지 않는다. `e1_analyze.MACRO_COST` (0:0.0, 1:1.0,
2:0.3, 3:1.0, 4:1.0, 5:1.8, 6:0.8, 7:1.5, 8:0.2) 도 그대로 쓴다 (함정 29: 이 표는 3곳에서
같아야 한다).

**MDP_DESIGN §13.2 의 legacy 버그 교정도 승계한다**: 둘 다 완주한 경우 `closed` 로 비교하면 안 된다 —
이 하니스는 완주해도 `closed < total` 이라(실측 291/313), 장부 노드 몇 개 때문에 더 느린 실행이
더 낫다고 판정될 수 있다. `better_ssp` 를 쓴다.

## 7. Bellman recursion

```
V(goal)     = 0
V(dead-end) = C_fail                       (유한벌점, MDP_DESIGN §5.2(c))
Q(s̃,a)      = (1/K) Σ_k [ c_k + V(s̃′_k) ]
V(s̃)        = min_a Q(s̃,a)
a*(s̃)       = argmin_a Q(s̃,a)
```

- **버킷 사이**: `prog_b` 역순 backward induction (progress 단조성이 DAG 를 보장)
- **버킷 내부**: 같은 `prog_b` 안에서 결정이 여러 번 나므로 자기순환이 생긴다 → value iteration
  으로 수렴시킨다 (유한벌점 SSP 라 proper policy 아래 수축). 허용오차와 최대 반복수를 명시하고,
  수렴 실패 노드는 조용히 넘기지 않고 표시한다.
- **동점**: `|ΔQ| < 1.96 · SE_paired` 이면 단일 a\* 를 뽑지 않고 **tie 집합으로 보고**한다
  (MDP_DESIGN §7.1: 격차 < 노이즈이면 그 상태는 tie 이며, tie 를 tie 로 보고하는 것이 채점에서 중요하다).
  채점 시 tie 집합 안의 선택은 정답으로 센다.

## 8. 산출물과 검증

### 8.0 산출물

| 경로 | 내용 |
|---|---|
| `wm4spacecraft_manufacturing/dp_oracle/grid_spec.json` | 축·구간·가지치기 규칙의 **단일 진실원** |
| `wm4spacecraft_manufacturing/dp_oracle/samples.jsonl` | (노드, 팔, k) 당 1행: prefix id, **측정된** φ̃, 비용, s̃′, capped, sampling_mode, 시드 |
| `wm4spacecraft_manufacturing/dp_oracle/value.json` | 노드당 V, Q, a\*, SE, tie 집합, 표본수, 수렴 여부 |
| `wm4spacecraft_manufacturing/dp_oracle_policy.py` | `reference_action(ev)` **시그니처 동일**. ev → φ̃ → 표 조회 → a\*. 미수록·INFEASIBLE·UNREACHABLE 은 `None`(unscored) — 지금 계약 그대로 |
| `wm4spacecraft_manufacturing/artifacts_dp/DISAGREEMENT.md` | 구 a\* vs 신 a\* 전면 대조 (§8.6) |

Julia 실행 레인 `oracle_macro()` 도 **같은 `value.json` 을 읽는다.** 지금은 채점기와 실행 레인이
의도적으로 갈려 결정 적중률이 84/84 가 아니라 80/84 인데(`REPORT.md` §2 머리말), 두 쪽이 한
표를 읽으면 그 균열이 구조적으로 사라진다.

### 8.1 STEP 0 게이트 — `deepcopy` 충실성 (차단성)

`deepcopy(world)` 후 두 복제본을 **같은** 팔로 진행시켰을 때 결과가 일치하는가. 일치하지 않으면
C++ 상태가 공유되고 있다는 뜻이므로 fork 경로를 쓸 수 없다 → §4.4 대체안으로 전환한다.
이 게이트는 **설계를 죽이지 않고 경로를 고른다.**

### 8.2 ψ 충실성

표집된 모든 노드에서 `요청 칸 == 측정 φ̃` 인 비율을 보고한다. 낮아도 실패가 아니다(§4.2 (2))
— 다만 낮으면 요청 스케줄이 비효율적이라는 뜻이므로 재조준한다.

### 8.3 순서동치

`check_order_equivalence` 재사용. SSP 스칼라의 argmin 이 lexicographic 순위를 재현하는지, 둘 다
정의되는 칸 전부에서 검사한다. 위반은 조용히 넘기지 않고 로그로 낸다.

### 8.4 단조성 위생검사

표집 버그를 싸게 잡는 검사다. V(비용) 는 다음을 만족해야 한다:

- `spares_b` 가 클수록 비증가 (스페어가 많아서 손해일 수 없다)
- `pend_f` 가 클수록 비감소 (미해결 고장이 늘어서 이득일 수 없다)
- `soc_b` 가 높을수록 비증가

위반은 자동 실패가 아니라 **조사 대상**으로 표시한다 (표본 노이즈일 수도 있으므로 SE 와 함께 본다).

### 8.5 잘린 rollout

`n_capped` 를 집계·경고한다 (MDP_DESIGN §13.6 (2): 미래가 잘리면 라벨이 낙관 편향되는데 "사건 N건" 만
보고하면 잘렸는지 알 수 없다).

### 8.6 이주 안전장치 — 전면 대체를 선택했으므로 필수

발행된 8 case × 4 정책 표가 전부 `reference_policy.py` 로 채점돼 있다. 리포트가 결함을 알면서도
고치지 않은 이유는 **"고치면 이 문서의 모든 숫자가 조용히 다시 채점된다"** 였다
(`REPORT.md` §3-B). 전면 대체는 그 두려움을 해소하는 방식으로만 허용한다:

1. `reference_policy.py` → `legacy_reference_policy.py` 로 **동결 보존**, 계속 실행 가능
2. `artifacts_dp/DISAGREEMENT.md` **의무 산출**: 3818 개 결정 전부에 대해 구 a\* vs 신 a\*,
   truth 별·case 별 불일치 건수, 그리고 그로 인한 정책별·case 별 `decision_acc` 델타.
   재채점이 조용히 일어나지 않는다.
3. **발행 게이트** — DP 가 견고한 실측 답 셋을 재현해야 대체가 허용된다:
   - battery SoC 0.02 → `SwapBattery` (완주 여부로 갈린 칸, 견고)
   - fault `agent_pending>0` → `Replace` (42 instance 완전분리)
   - zone `blk` → `RelocateBuild` (완주 279 vs 정지 254)

   재현 실패 시 **발행 중단**하고 원인을 규명한다.
4. 반대로 zone `cov` 에서 기존 규칙(`NOOP`)과 갈리면 그것은 **성공 신호**다 — 기존 규칙이 그
   계열에서 틀렸다는 것이 이미 실측돼 있다(`cov_noop` stalled 234 / `cov_reloc` complete 279).

### 8.7 추상화 gap 진단

실행 정책의 실현 결과가 DP 의 V 를 넘는 경우가 있는지 측정해 보고한다. 넘는다면 φ 의 정보손실이
ceiling 을 참값 아래로 끌어내린 것이므로 **"천장" 이라는 이름을 쓰지 않는다.** 숨기지 않고
지표로 낸다.

### 8.8 DP 자체의 재현성

`samples.jsonl` → `value.json` 은 순수 파이썬(시뮬 호출 없음)이어야 하고, 같은 입력에 같은 출력을
내야 한다. 시뮬이 비결정적인 것과 별개로 **DP 단계는 결정적**이다.

## 9. 범위 밖 (의도적)

- **surrogate 재학습.** `samples.jsonl` 이 (φ̃, a, Q̂, SE) 형태로 나오므로 MDP_DESIGN §8.2 의 Q 회귀를 바로
  학습할 수 있고, MDP_DESIGN §13.5 는 현재의 1-shot 라벨이 크기를 세 자릿수 틀린다는 것을 실측했다.
  그래도 배포 surrogate 를 바꾸면 또 다른 발행 숫자 전부가 움직인다 — **데이터만 만들고 학습은
  다음 태스크.**
- `reform` 축의 a\*. 실측 격자가 없고 이 설계도 만들지 않는다. unscored 유지.
- 비결정성의 원인 규명. §4.2 가 그것에 의존하지 않도록 설계를 바꿨으므로 이 작업의 선행조건이
  아니다.

## 10. 알려진 구멍

1. **`prog_b` 단조성은 `closed` 가 줄지 않는다는 가정에 기댄다.** 실측 범위에서는 참이지만
   ReformTeam 복구 경로가 노드를 되돌리는지 STEP 0 에서 확인한다.
2. **`zone_s=cov` 표본이 희소할 수 있다.** 630판 스윕의 zone 결정 812건이 **전부**
   `root_covered==0`(=blk) 이다. cov 칸은 주입으로만 만들어야 하고, 표본이 안 차면 그 칸은
   `UNREACHABLE` 로 남는다 — 그러면 기존 규칙의 알려진 결함을 DP 도 못 고친다.
3. **K=5 는 §13.6 (4) 의 권고(K≥10)보다 작다.** fork 로 CRN 이 구성적으로 보장되고 예산이
   남으므로, 동점대에 걸린 노드부터 K 를 올리는 적응적 배분으로 대응한다.
4. **`C_fail` 은 모델링 선택이다.** "완주 못 할 위험" 과 "늦게 끝남" 사이의 환율이며, 사전식
   규칙에 숨어 있었을 뿐 선택은 원래부터 존재했다(MDP_DESIGN §13.2). 값과 그 민감도를 명시 보고한다.
