# MDP 재설계 — 야간 파이프라인 통합 기록

기록 범위: 2026-07-31 저녁 ~ 2026-08-01. 설계 원문: `../MDP_DESIGN_FROM_SCRATCH.md`
(이전 판은 cp949/UTF-8 혼재로 깨져 있었다. 이 문서는 **UTF-8로 새로 작성**했다.)

---

## 0. 한 줄 요약

STEP 1(확률적 고장 프로세스)·STEP 2(K-rollout MC Q 라벨러)는 **완성·검증**되었다.
STEP 3~5는 돌렸으나 **평가셋이 판별 문제가 아니어서 결론이 서지 않았고**, 그 근본 원인이
"instance 당 사건이 하나뿐이라 불필요한 개입의 비용(스페어 소모)을 청구할 미래가 없다"는
**문제 정식화 자체의 결함**임을 규명했다. 해법(다중 사건 에피소드)을 배선하고 생성 중이다.

---

## 1. 완료·검증된 것

### STEP 1 — §5 확률적 고장 프로세스
- `src/mdp/hazard.jl`, `src/mdp/mdp.jl`, `test/mdp_hazard_smoke.jl` **55/55 PASS**
- OOD를 "사전에 뽑아둔 대본"에서 **상태의존 경쟁위험 점과정**으로 교체:
  `λ_r(t) = (1/mtbf)·mode·f_mode(r)·exp(β_u·û_r + β_s·(1−soc_r))`
  지수 시계(Exp(1) 문턱 + Λ 적분) = **정확 표집**(스텝당 베르누이 근사 아님). 3위험 경쟁(break/cell/zone).
- 방전도 로봇별 ε_r ~ LogNormal(평균 1)로 무작위화(`DRAIN_FACTOR_HOOK`; 훅 없으면 배수 1.0).
- CRN 정확화: 난수를 **로봇별 전용 스트림**(시드=(기저시드, 로봇 id))에서 뽑아 등록 순서와 무관.
- 무회귀: battery_smoke 32/32, battery_safety 27/27.

### STEP 2 — §7.1 K-rollout MC Q 라벨러
- `oracle/gen_oracle_mc.jl`(단일 결정상태) + `oracle/gen_oracle_dataset.jl`의 `DS_MC_K`/`DS_VALID_ONLY`
- `test/mdp_mc_label_smoke.jl` **ALL PASS**
- **확정 라벨** (tractor, build_seed=1, K=10, 22회 full-sim)

  | | 1-shot 기준선 | K=10 MC |
  |---|---|---|
  | Replace | 19.23 (완주) | **Q̂ 3555 ± 2357, P(done) 0.80**, 사후사건 2.70 |
  | NOOP | 46.62 (완주) | **Q̂ 20967 ± 3489, P(done) 0.20**, 사후사건 6.10 |
  | Δ | 27.4 | **17411 ± 3690 (paired) = 4.7 SE** |

  argmin은 같지만 **규모가 450배** 다르다. 1-shot은 "NOOP도 완주한다"고 하지만 실제 완주율 20%.
- **하니스 정합성 증거**: 사후 사건 0건인 rollout의 비용이 1-shot과 소수점까지 일치(46.6250/19.2250)
  → MC 라벨러는 사건이 없으면 1-shot으로 **정확히 퇴화**한다.
- legacy 버그 교정: `better()`가 **둘 다 완주해도 closed 수로** 비교 → 완주해도 `closed<total`
  (`YES 291/313`)이라 더 느린 실행을 낫다고 판정할 수 있음 → `better_ssp`로 교정.

---

## 2. 결론이 서지 않은 것과 그 이유 (핵심 발견)

### Router(STEP 5) — 베이스라인을 넣자 진짜 그림이 드러남
베이스라인 없이는 "subopt_norm 0"이 **해석 불가능**하다(과제가 쉬운 건지 모델이 잘한 건지 구별 불가).

| 정책 | subopt_norm | NOOP정답 부분집합 |
|---|---|---|
| always-NOOP | 0.455 | 0.000 |
| **always-Replace** | **0.023** | 0.042 |
| canonical(규칙) | 0.023 | 0.042 |
| random(valid) | 0.182 | 0.042 |
| **surrogate** | **0.023** | 0.042 |
| oracle | 0.000 | 0.000 |

평가셋 44 instance(정답 NOOP 24 / Replace 20)로 판별 문제는 생겼는데,
**"항상 개입"이 이미 거의 최적**이다 — 불필요하게 개입해도 손해가 4.2%뿐.

**근본 원인**: 불필요한 개입의 진짜 비용은 **스페어를 써버린 것**인데, 사건이 하나뿐인
instance에는 그 비용을 청구할 **미래가 없다**. 지금 만든 것은 MDP가 아니라 **contextual bandit**이다.
생성기 자신의 주석이 같은 말을 하고 있었다:
> *"spending a spare NOW leaves none for the NEXT breakdown ... can never appear.
> That is why what we train is Q^π(s,a) for a single decision, i.e. a contextual bandit, not an MDP."*

### STEP 4
- **T1**: 절대 비율은 정상(`Var_hidden/Var_MC = 1.07`)이나 순위 적중 0.57~0.72 → **판정 보류**.
  주의: T1을 절대 비용 잔차로만 판정하면 안 된다 — 비용이 이봉(완주 ~20 vs 미완주 ~26000)이라
  완주 오분류 한 번이 10⁴ 잔차를 만든다. **결정 관련 지표로 판정하도록 수정함**.
- **T2**: **BLOCKED**. instance당 사건 1개 = 이력이 원리적으로 없음. Router 실패와 **같은 뿌리**.

### STEP 3 — 부정 결과(배포 전환 안 함)
kind one-hot을 빼도 **누출 정확도 1.000 그대로**. 범인은 `harm`과 `resource_loss`가 각각
**단독으로** kind를 100% 판별(fault의 harm ≡ 상수 1.0, zoneblk의 resource_loss ≡ 구조적 0).
센티넬을 연속값으로 갈아입힌 것. 그 둘을 빼면 누출 1.000→0.833이지만 LOIO 0.087→0.230(2.6배 악화)
= **모델이 여태 종류 지름길을 타고 있었다는 직접 증거**.

### STEP 6 — 실행됐으나 노이즈 미분리
```
    seed      V^macro      V*(ext)        gap     gap%    ext best
       1      7118.76      7118.76       0.00     0.0%           1
       2        22.79        22.12       0.66     2.9%          10
       3      7660.40      7660.40       0.00     0.0%           1
  평균 gap = 0.22
```
seed 2의 최선 arm `10`(Replace@after=0)은 macro `1`과 **정의상 동일한 행동**이다.
즉 gap 0.66은 실제 gap이 아니라 **K=2의 몬테카를로 노이즈**다 → **결론으로 쓸 수 없다**.

---

## 3. 진행 중 (2026-08-01)

**결정론 에피소드 데이터 생성 중** — `DS_EPISODE_N=3`, seeds 1~12, `DS_MC_K=1`, valid-only, 3병렬.
- 배선 완료: `episode_prod(branch_t, a; hz_seed)`(hazard arming), `run_episodes`의 MC 루프 +
  valid-only(plan의 kind로 valid 직접 계산), 에피소드 행에 `rollout/hz_*` 기록
- **변수 분리를 위해 hazard는 끄고(K=1) 먼저 돌린다.** 이유: 확률 에피소드 스모크에서 계획 사건
  2~3개 + hazard 4~5개가 겹쳐 **모든 판이 미완주**(161~243/313)가 되어 판별이 사라졌다.
  순차 커플링만으로 Router가 살아나는지를 먼저 확인해야 인과가 분리된다.

### 확률 에피소드 스모크에서 확인된 것
- 같은 macro·같은 결정인데 rollout마다 결과가 다름(210/313 vs 199/313) → **확률 전이 배선 정상**
- 다만 `tau_to_next=0`, `closed_at_decision`이 모든 결정에서 동일(58) — 사건은 계획대로
  (@closed19/@closed45) 발화하지만 **respec 큐 처리 시점에 결정이 몰려 기록**된다.
  결정 2의 상태는 결정 1의 스페어 소모를 반영하므로 커플링 자체는 존재하나,
  **SMDP sojourn(τ)이 의미를 잃는다** → 나중에 수정 필요.

---

## 4. 다음 할 일 (우선순위)

1. **결정론 에피소드 재분석** — `PYTHONIOENCODING=utf-8 python overnight_mdp.py --glob='oracle/out/ep_*.jsonl'`
   판정 기준: **Router가 always-Replace를 이기는가.** 이기면 "순차 커플링이 없어서 bandit이었다"는
   진단이 입증된다. 못 이기면 커플링이 여전히 약한 것이므로 M(사건 수)을 늘리거나 스페어를 줄여야 한다.
2. **T2 수행** — 에피소드 데이터에는 `decision_idx`/`next_*`/`tau_to_next`가 있어 이력 feature가 생긴다.
3. **τ 기록 버그 수정** — 결정이 큐 처리 시점에 몰리는 문제. `closed_at`을 producer 호출 시점이 아니라
   **트리거 발화 시점**에 기록해야 한다.
4. **확률 에피소드** — 커플링이 확인된 뒤 MTBF를 크게 올려(예 1500~2000) hazard를 "가끔 추가되는
   사건"으로 만들고 K=3 재생성.
5. **STEP 6 재실행** — 중복 arm(10 ≡ macro 1)을 **노이즈 대조군으로 명시**하고 K=5로 노이즈 분리.
6. **STEP 3 재도전** — `harm`/`resource_loss`를 kind 간 구간이 겹치도록 재정의(MC 라벨 확보 후).

---

## 5. 운영 규칙 (밤사이 실제로 사고 난 것들)

- **병렬은 3개까지, `DS_STACK=1000000000`.** 6병렬 × 1GB는 **OutOfMemoryError**로 샤드 3개를 죽였다.
- **스크립트명으로 프로세스를 죽이는 감시기를 만들지 말 것.** 나중에 띄운 같은 스크립트까지 죽인다
  (보완 생성이 그렇게 잘려 58행만 남았다). 꼭 필요하면 PID를 직접 들고 있을 것.
- **인라인 python heredoc에 `PYTHONIOENCODING=utf-8`.** 없으면 Windows에서 cp949로 나가 리포트가 깨진다.
- **패치는 heredoc `assert` 대신 Edit 도구로.** 백그라운드로 넘어가면 assert 실패가 출력에 묻혀
  "적용된 줄 알았는데 안 된" 상태가 된다(실제로 발생).

---

## 6. 산출물 위치

| 항목 | 경로 |
|---|---|
| 설계 원문(§1~§14) | `wm4spacecraft_manufacturing/MDP_DESIGN_FROM_SCRATCH.md` |
| 위험 프로세스 | `src/mdp/hazard.jl`, `src/mdp/mdp.jl` |
| MC 라벨러(단일 상태) | `oracle/gen_oracle_mc.jl` |
| MC 라벨러(대량/에피소드) | `oracle/gen_oracle_dataset.jl` |
| 분석 파이프라인 | `overnight_mdp.py` (집계·평가셋·T1·T2·Router+베이스라인) |
| STEP 3 실험 | `step3_loao.py` |
| 테스트 | `test/mdp_hazard_smoke.jl`, `test/mdp_mc_label_smoke.jl` |
| 단일사건 집계 데이터셋 | `artifacts_mdp/mc_dataset.jsonl` (92셀/48 instance) |
| 재분석 출력 | `artifacts_mdp/rerun_analysis.txt`, `router_voi.json`, `admissibility.json` |
| STEP 6 | `artifacts_mdp/step6_gap.txt` |
| 전체 로그 | `artifacts_mdp/overnight.log` |
