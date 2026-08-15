# 행동집합을 닫는다 — 라벨 생성 → surrogate → DP 를 한 줄로 잇는 Implementation Plan

> **인수인계 문서다.** 2026-08-15 세션이 컨텍스트 한계로 다음 세션에 넘긴다.
> 실행 전 `wm4spacecraft_manufacturing/md/RESULTS_DP_BACKWARD_2026-08-15.md` **§4-D 를 먼저
> 읽을 것** — 이 계획이 무엇을 고치려는지가 거기 실측으로 적혀 있다.

**Goal:** 실행 레인이 실제로 쓰는 매크로를 **라벨 생성기 · surrogate · DP 표집이 전부 볼 수
있게** 만든다. 그 셋이 지금 서로 다른 행동집합을 보고 있고, 그게 2026-08-15 판에서 §8.7 gap 이
87.6% 로 남은 **가장 큰 단일 원인**이다.

**왜 지금 이걸 하는가 (2026-08-15 실측):**

| 사건 | §8.7 gap | 실행 레인이 집행한 매크로 | DP·surrogate 가 볼 수 있었나 |
|---|---|---|---|
| Reform | **13/13 = 100%** | `ReformTeam` ×1182 | **아니오** |
| Zone | 23/23 = 100% | `RelocateBuild` ×495, `NOOP` ×338 | 예 |
| Battery | 43/52 = 82.7% | `Replace` ×552, `SwapBattery` ×279 | 예 |
| Fault | 27/33 = 81.8% | `Replace` ×819, `Deprioritize` ×19 | 예 |

그리고 그 결과가 표집 판 전체를 오염시킨다:

```
표집 판 420개 중 완주  82 (19.5%)          <- 실행 레인은 ~98%
미완주 338판 중 Reform 사건이 있던 판  338 (100.0%)
완주  82판 중 Reform 사건이 있던 판      5
팔별 완주율: NOOP 0% · Deprioritize 0% · RelocateBuild 14.3% · Replace 34.5% · SwapBattery 48.8%
V 중앙값 4418.6   (정상 완주 규모는 20~60)
```

**Reform 사건이 뜨면 다섯 팔 중 무엇으로도 판이 죽는다.** Reform 은 교착이 감지될 때 발화하므로
팔을 고정해 굴리면 81.7% 의 판에서 뜬다. 그래서 실패 벌점 `C_fail` 이 그 판이 지나온 **모든
칸**의 `V` 로 역전파되고, Reform 칸뿐 아니라 Battery·Fault·Zone 칸까지 `V` 가 부풀어 오른다.
`V` 중앙값 4418.6 이 그 흔적이다.

---

## Global Constraints

이 절은 **모든 태스크에 암묵적으로 포함**된다. 2026-08-14·08-15 두 세션이 실제로 데인 것들이다.

1. **작업 디렉토리 = `/home/chahj578/Construction_OODlayer`**, 브랜치 `oracle-rebuild-night-2026-08-10`.
2. Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`. Julia 는 `julia +lts --project=.`.
3. **목적함수 상수를 리터럴로 복붙하지 않는다.** `objective.load()` / `objective.J()` 경유.
   **문서에 `objective_hash` 를 문자열로 적지 않는다**(`audit_objective.py` 항목 9).
4. **행동 어휘도 같은 규칙이다** (2026-08-15 추가). `action_registry.json` 이 단일 진실원이고,
   소비처는 **파생**으로 받는다. `audit_action_vocab.py` 는 이제 **여분 id 도 실패로 다룬다** —
   레지스트리에 없는 매크로를 어딘가에 적으면 6/6 이 깨진다.
5. **★ 스윕이 도는 중에 `run_demo.jl`·`policy.jl` 을 절대 건드리지 않는다.**
   계측 변경은 **모든 스윕 전에 커밋**하고, 스윕 도중에는 `git status --porcelain tools/monitor/`
   가 비어 있어야 한다.
6. **★ 스윕 도중에 커밋하지 않는다** (2026-08-15 에 새로 알게 된 것). `run_shard.sh` 의
   provenance 도장이 **HEAD SHA** 다. 스윕 중간에 HEAD 가 바뀌면 이후 샤드가 다른 commit 으로
   찍혀 한 스윕 안에서 세대가 갈린다. 작업 트리를 더럽히는 것(= 편집)은 괜찮다 — HEAD 만 안 바뀌면 된다.
7. **★ 스윕 드라이버를 죽일 때 `xargs` 가 살아남는다.** `pgrep -f "xargs -a"` 로 확인하고 따로 죽일 것.
   ⚠️ `pkill -f "sleep N"` 같은 넓은 패턴은 **자기 자신이 도는 셸까지** 죽인다(2026-08-15 실측).
8. **★ dp 샤드는 별도 트리에 넣는다** (`results_4pol/shards_dp`). provenance 도장이
   `(commit, policies)` 쌍이라 같은 OUTDIR 에 다른 정책 목록으로 들어가면 STALE 로 판정해
   **이미 끝난 3정책 결과를 지우고 다시 돈다.**
9. **★ dspy 서비스를 재시작할 것.** 어휘·라벨셋을 바꾸면 `:8090` 의 실행 중인 서비스는 **옛
   모듈 상태를 그대로 들고 있다.** 스윕 전에 반드시 재시작하고 `/health` 의 `surrogate` 문자열로
   새 support 를 확인한다(그게 `gate_prereq.sh` P2·P9 가 찍는 provenance 다).
10. **조용한 폴백 금지.** 폴백·미커버·미측정은 반드시 산출물과 화면에 **이름으로** 남는다.
11. 기대 baseline: `Pkg.test()` = **11 pass / 1 error**(Gurobi 라이선스 없음).
12. 병렬: 56코어/125GB에서 **3정책 스윕 30 워커 + 표집 24 워커 동시 실행이 실측 안전**했다
    (최대 메모리 53 GB, 각각 90분·81분). dp 레인 단독은 50 워커로 18분.
13. **비교 단위는 솔버가 정한다.** `value.json` 의 `solver` 필드가 `backward` 면 `V` 는 **그 칸부터의
    cost-to-go** 이고, 실행 정책도 같은 분해로 재야 한다. 판 전체 J 와 대면 gap 이 100% 로 자동
    발화한다 — 측정이 아니라 단위 오류다. `build_compare_table.py` 와 `fill_results_doc.py` 가
    같은 규칙을 쓴다(둘이 갈리면 표와 문서가 갈린다).
14. 커밋 메시지는 저장소 관례(한국어, `feat(scope):` / `fix(scope):` / `data(scope):`).

---

## 이미 끝나 있는 것 — 다시 하지 말 것

2026-08-15 세션 산출물. 커밋 `93794067`..`14ccbc44`.

| 이미 있는 것 | 위치 | 비고 |
|---|---|---|
| 결정마다 `(sim_t, 누적 energy, closed)` | `tools/monitor/run_demo.jl` | 구간 비용 `c_k` 의 원자료 |
| 전이 표집 + 분해 충실성 게이트 | `dp_oracle/sample_grid.py` | `decompose_board()` 는 순수 함수 |
| 분해 충실성 단위검사 | `dp_oracle/test_cost_decomposition.py` | 55검사. **차단 게이트** |
| 진짜 backward induction 솔버 | `dp_oracle/dp_solve.solve_backward` | 구세대는 `solve_constant_arm` 로 보존 |
| backward 용 계층 백오프 | `dp_oracle/dp_solve.solve_backward_hierarchical` | cell·next_cell 을 함께 투영 |
| gap 원인 분해 진단기 | `dp_oracle/gap_breakdown.py` | 레벨별·사건별·팔 메뉴 대조 |
| 조합 팔 5·6 정식 등록 + 감사 강화 | `action_registry.json`, `audit_action_vocab.py` | 여분 id 를 실패로 다룬다 |

**범위 밖(이번에도 하지 않는다):** `reference_policy.py` 대체 · surrogate 를 φ̃ 위에 재학습 ·
`zone_s=cov` 주입 격자 · oracle 천장 격자 재라벨. 앞의 둘은 원 설계가 범위 밖으로 못박았고,
뒤의 둘은 비교표 4열을 바꾸지 않는다.

---

## ★ 이 계획의 핵심 — 세 소비처가 지금 서로 다른 행동집합을 본다

```
action_registry.json          {0,1,2,3,4,7,8}  (+5,6 은 DS_COMBO_ARMS 게이트)   <- 어휘의 진실원
실행 레인(canonical/dspy)      ReformTeam(4) 을 1182회 집행                      <- 실제로 쓰는 것
배포 라벨셋 RELABEL_20260814   {0,1,2,7,8}      kind = fault/battery/zoneblk 만  <- surrogate 가 배운 것
DP 표집 arm_menu()            {0,1,2,7,8}      (라벨셋 support 를 그대로 베낌)  <- 천장이 비교한 것
```

세 번째 줄이 원인이고 네 번째 줄은 그 복사본이다. **`support` 는 "이긴 팔" 이 아니라 "굴려서
라벨한 팔" 의 집합**이라는 점이 핵심이다 — `dspy_service.py:229` 가 학습 행의 `macro` 열에서
그대로 유도한다. 즉 매크로 3·4 는 **평가에서 진 게 아니라 시험지에 나온 적이 없다.**

실측 근거 (`relabel_2026-08-14.jsonl` 365행 / 155 instance):

```
kind 분포        : fault 110 · battery 135 · zoneblk 120 · reform **0**
arms_labeled     : 2팔 220행 · 3팔 135행 · 1팔 10행        <- 인스턴스마다 2~3팔만 굴렸다
kind x macro     : fault -> {0,1}   battery -> {0,1,2,8}   zoneblk -> {0,7}
```

`ForbidZone(3)` 은 zone 인스턴스에서도 **한 번도 안 굴렸다.** `ReformTeam(4)` 은 reform
인스턴스 자체가 0건이라 라벨될 대상이 없었다.

> **참고 — 은퇴한 학습셋에는 있었다.** `n44_plus78.jsonl` 의 support 는 `{0,1,2,3,4,7,8}` 이고
> 매크로 3·4 가 각각 252건 있다. 즉 이건 **재라벨(2026-08-14)이 잃어버린 능력**이다. 그 파일을
> 되살릴 수는 없다 — `energy_J` 가 없어 현행 목적함수로 채점이 안 된다. 그러나 **그 격자 구성이
> 정답에 가깝다**는 증거로는 쓸 수 있다(어떤 kind·arm 조합을 굴렸는지 참고할 것).

---

## Task 1: 라벨 생성기가 reform 인스턴스를 만들고, kind 마다 legal 한 팔을 **전부** 굴린다

**목적:** 학습·표집의 상류를 고친다. 이게 안 되면 Task 2·3 은 할 게 없다.

**Files:** Modify `wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl`

- [ ] **Step 1 — 지금 무엇을 굴리는지 먼저 읽는다. 추측하지 않는다.**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
grep -n "DS_KINDS\|kinds\|:zoneblk\|:zonecore\|arms_labeled\|valid_actions" oracle/gen_oracle_dataset.jl | head -40
grep -n "valid_actions\|COMBO" oracle/ood_mdp_shim.jl | head -20
```

  확인할 것 두 가지: (a) 인스턴스 kind 목록을 정하는 손잡이 이름, (b) 인스턴스마다 굴릴 팔을
  고르는 자리. `arms_labeled` 가 2~3 인 이유가 (b) 에 있다.

- [ ] **Step 2 — `reform` kind 를 인스턴스 목록에 넣는다.** `run_demo.jl` 의 `DEMO_REFORM` 이
  교착 시 `ReformTruth` 를 올리는 것과 **같은 조건**으로 만들어야 한다. 다른 조건으로 만들면
  라벨 격자와 실행 레인이 다른 세계를 재게 된다.

- [ ] **Step 3 — kind 마다 `KIND_VALID` 의 팔을 전부 굴린다.** `action_registry.KIND_VALID` 를
  진실원으로 쓴다(리터럴 금지, Global Constraint 4). 실험 팔(5·6)은 `is_active()` 가 걸러 준다.
  기대 조합: fault `{0,1,2,4}` · battery `{0,1,2,8}` · zone `{0,3,7}` · reform `{0,4}`.

- [ ] **Step 4 — 스모크 1 instance.** 라벨 1건을 만들어 `macro` 열과 `arms_labeled` 를 본다.

```bash
# (Step 1 에서 확인한 실제 손잡이 이름으로 바꿔 쓸 것)
../.venv/bin/python -c "
import json,collections
rows=[json.loads(l) for l in open('oracle/out/<새파일>.jsonl') if l.strip()]
print('kind:', collections.Counter(r['kind'] for r in rows))
print('macro:', collections.Counter(r['macro'] for r in rows))
print('arms_labeled:', collections.Counter(r['arms_labeled'] for r in rows))
print('energy_J 결측:', sum(1 for r in rows if r.get('energy_J') is None))"
```

  Expected: `kind` 에 `reform` 이 있고, `macro` 분포에 **3 과 4 가 둘 다** 있고,
  `energy_J` 결측이 0. 하나라도 어긋나면 **여기서 멈춘다.**

  ⚠️ `energy_J` 는 배터리 레이어(`_arm_battery!`)가 `kind === :battery` 에서만 켜지므로
  fault/zone/reform instance 에서 NaN 이 될 수 있다(CLAUDE.md 알려진 한계 1). 그러면 그 행의
  완주 J 가 정의되지 않아 **라벨을 못 만든다.** `md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md` 의
  energy-only 모드(`battery.jl:486`, `enable_battery!` 만 켜고 stall/derate 는 끈다 =
  **동역학을 안 바꾼다**)를 모든 kind 에 켜는 것이 그 해법이다. 이 스텝에서 같이 처리한다.

- [ ] **Step 5 — 전체 라벨 생성.** 규모는 Step 4 의 instance 당 벽시계로 산정한다.
      기존 155 instance / 365행이 기준선이고, 팔이 늘어 행 수는 2배 이상이 될 것이다.
- [ ] **Step 6 — 커밋.** 새 라벨셋 이름을 `wm_datasets.py` 에 상수로 추가한다(경로 리터럴 금지).

---

## Task 2: surrogate 를 새 라벨셋으로 재학습하고 support 를 넓힌다

**Files:** Modify `src/respec/llm_service/dspy_service.py`, `wm4spacecraft_manufacturing/wm_datasets.py`,
`wm4spacecraft_manufacturing/test_surrogate_support.py`

- [ ] **Step 1** — `SURRO_DATA` 를 새 라벨셋으로 바꾼다. ⚠️ `wm_datasets.resolve()` 를 **쓰지
  않는다** — 그 함수는 `$WM_DATASET`/`$EVAL_DATA` 를 읽으므로 환경변수 하나로 옛 라벨이 조용히
  들어온다(`dspy_service.py:180` 이 그 이유를 적어 놨다). 상수를 직접 가리킬 것.
- [ ] **Step 2** — `test_surrogate_support.py` §B 의 계약을 갱신한다. 지금은
  `support == {0,1,2,7,8}` 을 **정확히** 요구하고 "ForbidZone(3)·ReformTeam(4) 는 알려진 부재"
  라고 못박고 있다. 새 계약은 `support == {0,1,2,3,4,7,8}` 이고, **그 문장을 지우지 말고
  "2026-08-15 까지 부재였다" 는 이력으로 고쳐 쓴다**(왜 있었는지가 다음 사람에게 필요하다).
- [ ] **Step 3** — 서비스 재시작 후 `/health` 로 확인한다.

```bash
pkill -f "uvicorn dspy_service:app.*8090"
cd /home/chahj578/Construction_OODlayer/src/respec/llm_service
nohup ../../../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090 >/tmp/svc.log 2>&1 &
sleep 8; curl -s http://127.0.0.1:8090/health | python3 -m json.tool | grep -i surrogate
```

  Expected: `macro support [0, 1, 2, 3, 4, 7, 8]`.

- [ ] **Step 4 — reform 사건에서 surrogate 가 NOOP 밖을 고르는지 직접 본다.**

```bash
curl -s -X POST http://127.0.0.1:8090/macro -H 'Content-Type: application/json' -d '{
  "kind":"reform","severity":0.5,"progress":0.6,"spare_count":10,"agent_pending":-1,
  "valid":["NOOP","ReformTeam"],
  "nl":"A multi-robot transport team is deadlocked while forming and the build has stalled."}' | python3 -m json.tool
```

  Expected: `unsupported` 가 **비어 있고** 응답이 `NOOP` 이 아니다. 이게 이 태스크의 유일한
  성공 판정이다 — support 문자열만 보고 넘어가지 말 것.

- [ ] **Step 5** — 회귀 확인: `test_surrogate_support.py` · `audit_action_vocab.py` ·
  `test_service_surrogate_rank.py`(있으면). 커밋.

---

## Task 3: DP 표집의 팔 메뉴를 실행 레인에 맞추고 전면 재실행

**Files:** Modify `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py`

- [ ] **Step 1 — `arm_menu()` 의 하드코딩을 없앤다.**

```python
# 지금:
    want = ("0", "1", "2", "7", "8")     # 배포 학습셋 support 를 그대로 베낀 것

# 바꿀 것: 어휘의 진실원에서 받는다. 실험 팔은 is_active() 가 건다.
#   왜: DP 는 **실행 레인 전체의 천장**이어야 한다. 메뉴를 셋 중 가장 좁은 레인(surrogate)에
#   맞추면 천장이 될 수 없다 — 2026-08-15 실측에서 Reform 축 gap 이 13/13 = 100% 였고,
#   표집 판 338개가 전부 reform 에서 죽었다.
    import action_registry as reg
    return [(i, reg.MACRO_NAME[i]) for i in reg.ACTIVE_MACROS]
```

  ⚠️ 팔이 5 → 7 로 늘면 표집 판이 420 → **588판**(7 case × 12 seed × 7 팔)이 된다.
  24 워커에서 약 **113분** 예상(2026-08-15 실측 420판 81분에서 선형 외삽).

- [ ] **Step 2 — 파일럿 먼저** (1 case × 1 seed × 7 팔). 분해 충실성이 통과하는지,
      `ReformTeam` 팔의 판이 실제로 완주하는지 본다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export DSPY_URL=http://127.0.0.1:8090
../.venv/bin/python dp_oracle/sample_grid.py --jobs 7 --seeds 1 --cases all \
  --work dp_oracle/_pilot_work --out /tmp/pilot_samples.jsonl
```

  Expected: `§분해 충실성: 판 7 중 어긋남 0`. 그리고 팔별 완주에서 `ReformTeam` 이 0% 가
  아니어야 한다. **0% 면 Task 1 이 덜 된 것이다 — 여기서 멈추고 돌아간다.**

- [ ] **Step 3 — 전체 재표집** (`--jobs 24 --seeds 1..12`).
- [ ] **Step 4 — 풀이.** 계획 2026-08-15 와 같은 순서: 먼저 백오프 없이 재고, 그 다음 켠다.

```bash
../.venv/bin/python dp_oracle/dp_solve.py --out dp_oracle/value_L0_nobackoff.json
../.venv/bin/python dp_oracle/dp_solve.py --backoff
```

  **보고할 것**: 칸 수 · a\* 확정(칸 기준과 **결정 가중** 둘 다) · tie · single_arm ·
  dangling 전이 수와 사유별 내역 · 수렴 실패 노드 수.

- [ ] **Step 5 — 4정책 전면 재스윕.** 어휘와 라벨셋이 바뀌었으므로 **세대가 갈린다.**

```bash
git status --porcelain tools/monitor/          # 비어 있어야 한다
mv results_4pol results_4pol_gen_backward_2026-08-15
mkdir -p results_4pol && rm -f _night/status_shards.jsonl
bash run_4pol_parallel.sh --jobs 30 --policies canonical,surrogate,dspy
bash run_4pol_parallel.sh --jobs 50 --policies dp --shards-dir results_4pol/shards_dp
bash finish_tables.sh
```

  ⚠️ **(2) 는 (1) 이 끝난 뒤여야 한다** — dp 레인이 `value.json` 을 조회한다.
  ⚠️ 스윕이 도는 동안 **커밋하지 않는다**(Global Constraint 6).

---

## Task 4: 판정 — gap 이 실제로 줄었는가, 그리고 남은 것이 무엇인가

- [ ] `dp_oracle/gap_breakdown.py` 를 돌려 **사건별 gap** 을 2026-08-15 기준선과 나란히 낸다.

| 기준선 (2026-08-15) | gap |
|---|---|
| 전체 | 106/121 = **87.6%** |
| Reform | 13/13 = 100% |
| Zone | 23/23 = 100% |
| Battery | 43/52 = 82.7% |
| Fault | 27/33 = 81.8% |
| L0 만 | 105/111 = 94.6% |

- [ ] **Reform 축 gap 이 100% 에서 내려왔는가**가 이 계획의 1차 성공 판정이다.
- [ ] **표집 판 완주율이 19.5% 에서 올라갔는가**가 2차 판정이다. 이게 안 오르면 `V` 중앙값이
      여전히 4000 대일 것이고, 그러면 gap 도 안 줄어든다.
- [ ] gap 이 **0 이면** DP 열 부제를 "ceiling" 으로 되돌린다.
- [ ] gap 이 **0 이 아니면** 이름을 쓰지 않고, 남은 원인을 다시 좁혀 보고한다. 2026-08-15 에
      이름 붙인 나머지 둘이 그때 비로소 측정 가능해진다:
      **② φ̃ 추상화 손실** · **③ 전이 표본이 상수-팔 rollout 에서만 나온다**(1-step deviation
      표집이 필요하고, 그건 이 계획의 범위 밖이다).

---

## Task 5: 게이트 전수 + 문서

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
for t in audit_objective.py audit_action_vocab.py test_surrogate_support.py \
         test_ceilings_degrade.py test_objective.py \
         dp_oracle/test_dp_solve.py dp_oracle/test_cellkey_parity.py \
         dp_oracle/test_cost_decomposition.py; do
  ../.venv/bin/python "$t" >/dev/null 2>&1; echo "$t exit=$?"; done
cd .. && for t in test_narrate test_lane_select; do
  julia +lts --project=. tools/monitor/$t.jl >/dev/null 2>&1; echo "$t exit=$?"; done
julia +lts --project=. tools/test_policy_escalation.jl 2>&1 | tail -2
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep "Test Summary" -A 3
```

- [ ] 전부 exit 0, `Pkg.test` = 11 pass / 1 error.
- [ ] 결과 문서를 새로 만들고 `fill_results_doc.py --doc <새 문서>` 로 수치를 채운다
      (손으로 적지 않는다. 문서에 `<!--TABLE-->` `<!--GATES-->` `<!--HOLES-->` 를 넣어 둘 것).
- [ ] `RESULTS_DP_BACKWARD_2026-08-15.md` §4-D 에 "이 원인은 2026-08-16 계획이 해소했다/못 했다"를
      한 줄로 잇는다. **옛 문서를 지우지 않는다.**
- [ ] `.claude/CLAUDE.md` 의 세대 포인터를 갱신한다.

---

## 실패해도 이상하지 않은 것 (미리 적어 둔다)

1. **`ReformTeam` 을 넣어도 표집 판 완주율이 크게 안 오를 수 있다.** 팔을 고정해 굴리면 판 전체가
   `ReformTeam` 이 되는데, reform 이 아닌 사건(배터리 방전·고장)에는 그 팔이 무의미하다. 즉
   **상수-팔 표집이라는 구조(원인 ③)가 여전히 상한을 건다.** 그러면 남는 gap 이 ③ 의 크기다.
2. **팔이 늘면 (칸,팔) 표본이 얇아진다.** 지금도 24칸이 단일 팔이다. 팔을 7개로 늘리면 같은 예산에서
   칸당 표본이 준다 → tie 가 늘고 a\* 확정이 더 줄 수 있다. 그러면 seed 를 12 → 20 으로 늘리는
   것이 다음 손잡이다(표집 시간이 선형으로 는다).
3. **`energy_J` 가 fault/zone/reform instance 에서 NaN 일 수 있다**(Task 1 Step 4 의 ⚠️).
   그러면 그 행의 완주 J 가 정의되지 않아 라벨을 못 만든다. energy-only 모드로 해결하되,
   그것이 **동역학을 바꾸지 않는다**는 근거(`md/STAGE7_ENERGY_ONLY_FINDING_2026-08-13.md`)를
   확인하고 쓸 것.
4. **surrogate 가 3·4 를 배워도 잘 고르지는 못할 수 있다.** support 에 들어가는 것과 잘 고르는 것은
   다른 문제다. Task 2 Step 4 가 "고를 수 있는가"만 판정하고, "잘 고르는가"는 Task 4 의 비교표가 낸다.
