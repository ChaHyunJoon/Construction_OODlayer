# DP 를 진짜 backward induction 으로 — 전면 재실행 Implementation Plan

> **인수인계 문서다.** 2026-08-14 세션이 컨텍스트 한계로 다음 세션에 넘긴다.
> 실행 전 `wm4spacecraft_manufacturing/md/RESULTS_ROUTER3WAY_2026-08-14.md` 를 **먼저 읽을 것** —
> 이 계획이 무엇을 대체하는지가 그 문서 §5-C 에 있다.

**Goal:** `dp` 열을 상수-팔 반사실에서 **진짜 Bellman backward induction** 으로 바꾸고, 그 결과
`dp` 가 "천장" 이라는 이름을 쓸 수 있는지 다시 판정한다. 계측 변경이 코드 세대를 가르므로
**네 정책을 전부 재스윕**하고 비교표를 다시 낸다.

**왜 지금 이걸 하는가:** 2026-08-14 표의 DP 열은 상수-팔 정책군의 최선이라 §8.7 gap 이
**108/121 = 89.3%** 로 발화했고, 그래서 "천장" 이름을 뗐다. 원인이 **알려져 있고 구조적**이다 —
사건이 셋 섞인 판을 한 팔로 처리할 수 없다. 그 원인을 제거하면 남는 gap 은 추상화 손실
하나로 좁혀져 해석 가치가 생긴다.

---

## Global Constraints

이 절은 **모든 태스크에 암묵적으로 포함**된다. 2026-08-14 세션이 실제로 데인 것들이다.

1. **작업 디렉토리 = `/home/chahj578/Construction_OODlayer`**, 브랜치 `oracle-rebuild-night-2026-08-10`.
2. Python 은 언제나 `/home/chahj578/Construction_OODlayer/.venv/bin/python`. Julia 는 `julia +lts --project=.`.
3. **목적함수 상수를 리터럴로 복붙하지 않는다.** `objective.load()` / `objective.J()` 경유.
   `audit_objective.py` 항목 1 이 12파일을 스캔한다. **문서에 `objective_hash` 를 문자열로 적지 않는다**(항목 9).
4. **★ 스윕이 도는 중에 `run_demo.jl`·`policy.jl` 을 절대 건드리지 않는다.**
   2026-08-14 에 실제로 그랬고, 스윕을 죽이고 워커 전부 배수 후 재시작하느라 7분을 버렸다.
   계측 변경은 **모든 스윕 전에 커밋**하고, 스윕 도중에는 `git status --porcelain tools/monitor/`
   가 비어 있어야 한다.
5. **★ 스윕 드라이버를 죽일 때 `xargs` 가 살아남는다.** `pkill -f run_4pol_parallel.sh` 만으로는
   `xargs -a .../joblist.txt -P 26` 이 계속 새 샤드를 뿌린다. `pgrep -f "xargs -a"` 로 확인하고
   그 PID 를 따로 죽일 것.
6. **★ dp 샤드는 별도 트리에 넣는다** (`results_4pol/shards_dp`). `run_shard.sh` 의 provenance
   도장이 `(commit, policies)` 쌍이라, 같은 OUTDIR 에 다른 정책 목록으로 들어가면 STALE 로
   판정해 **이미 끝난 3정책 결과를 지우고 다시 돈다.**
7. **★ UI 는 `render_demo.jl` 을 쓴다** (`server.jl` 의 POST /run 도, `regen_router_cases.sh` 도).
   `run_demo.jl` 은 스윕 전용이다. 화면에 뭔가 띄우려고 `run_demo.jl` 을 고치면 아무 효과가 없다.
8. **조용한 폴백 금지.** 폴백·미커버·미측정은 반드시 산출물과 화면에 **이름으로** 남는다.
9. 기대 baseline: `Pkg.test()` = **11 pass / 1 error**(Gurobi 라이선스 없음). 그보다 나빠지면 회귀.
10. 병렬 스윕은 `run_4pol_parallel.sh --jobs 26` 이 안전 상한이었다(56코어/125GB, 워커당 ~1.5GB).
    표집과 스윕을 **동시에** 돌려도 지표는 sim 초·J 라 벽시계와 무관하다(2026-08-14 실측).
11. 커밋 메시지는 저장소 관례(한국어, `feat(scope):` / `fix(scope):` / `data(scope):`).

---

## 이미 끝나 있는 것 — 다시 하지 말 것

2026-08-14 세션 산출물. 커밋 `315f2ada`..`d2521be8`.

| 이미 있는 것 | 위치 | 비고 |
|---|---|---|
| 라우터 3-way 분기표 | `tools/monitor/lane_select.jl` + 전수 단위검사 | 순수 함수 |
| 자연어 서술기 | `tools/monitor/narrate.jl` + 계약검사 | 순수 함수 |
| dp 실행 레인 | `tools/monitor/dp_lane.jl` | `value.json` 조회. **스키마만 맞으면 그대로 재사용** |
| 격자 정의 | `dp_oracle/grid_spec.json` + `derive_grid.py` | 축 재유도 완료(65칸 관측) |
| 언어 간 칸키 동치 검사 | `dp_oracle/test_cellkey_parity.py` | 13,720 경계 상태 통과 |
| 표집기 | `dp_oracle/sample_grid.py` | **구간 비용을 안 낸다 — Task 2 가 고친다** |
| 표 조립 | `build_compare_table.py` · `finish_tables.sh` · `fill_results_doc.py` | §8.7 gap 자동 계산 포함 |
| 천장 미측정 강등 | `build_md_report.compute_ceilings` | J 불가 행을 세어서 남긴다 |
| 배포 surrogate | `RELABEL_20260814` (365행, 전 행 `energy_J` 보유) | **재라벨 완료됨. 다시 안 해도 된다** |

**범위 밖(이번에도 하지 않는다):** `reference_policy.py` 대체와 DISAGREEMENT 리포트 ·
surrogate 를 φ̃ 위에 재학습 · `zone_s=cov` 주입 격자 · oracle 천장 격자 재라벨.
앞의 둘은 원 설계가 이미 범위 밖으로 못박았고, 뒤의 둘은 **비교표 4열을 바꾸지 않는다.**

---

## ★ 이 계획의 핵심 — J 는 두 분기의 러닝 코스트가 다르다

`objective.J` 실측(2026-08-14):

```python
complete   : J = makespan + w_E * energy_J            # w_E = objective.energy_weight(cfg)
incomplete : J = C_fail + C_unclosed*max(0,total-closed) + tie_eps*makespan   # 에너지가 안 들어간다
```

**완주 분기는 구간에 대해 정확히 가법적이다** — `Σ(Δmakespan + w_E·Δenergy) = makespan + w_E·energy`.
**미완주 분기는 아니다** — 대부분이 종단 벌점이고 에너지 항이 아예 없다.

그런데 결정 시점에는 그 판이 완주할지 모른다. 그래서 **러닝 코스트를 완주 분기로 고정하고,
종단에서 차액을 정산**한다. 이 정의면 두 분기 모두에서 항등식이 성립한다:

```
c_k          = Δmakespan_k + w_E · Δenergy_k          (구간 k, 완주 분기 형태로 고정)
V(goal)      = 0
V(dead_end)  = J_incomplete − Σ_k c_k
             = [C_fail + C_unclosed·(total−closed) + tie_eps·makespan] − [makespan + w_E·energy]
```

**이것은 발명이 아니라 정산이다.** 그리고 발명이 아님을 기계로 못박는다 — Task 3 의
**분해 충실성 검사**가 모든 판에서 `Σ c_k + terminal == objective.J_row(row)` 를 요구한다.
이 검사가 통과하지 않으면 **그 뒤의 모든 숫자가 무효다.** 배분 규칙을 지어내면 그 규칙이 곧
결과가 되기 때문에, 이 게이트가 이 계획 전체의 근거다.

---

## Task 1: 결정마다 (sim_t, 누적 energy, closed) 를 기록한다

**목적:** 구간 비용 `c_k` 를 만들 수 있는 원자료를 남긴다. **이것이 없어서** 2026-08-14 판이
상수-팔로 갔다.

**Files:** Modify `tools/monitor/run_demo.jl`

- [ ] **Step 1** — `handle_ood!` 의 `push!(_DECISIONS, Dict(...))` 에 세 필드를 추가한다.
  값은 전부 이미 계산돼 있다. **새로 재지 않는다.**

```julia
        # 구간 비용 c_k 의 원자료 (2026-08-15). 결정 시점의 세 값만 있으면 연속한 두 결정
        # 사이의 Δmakespan·Δenergy 가 나온다 — 그게 backward induction 이 요구하는 분해다.
        # battery_report() 는 임의 시점의 누적 소비를 준다(render_demo.jl 이 이미 그렇게 쓴다).
        "sim_t_at"      => (try Float64(CB.sim_time(env)) catch; nothing end),
        "energy_at_J"   => (try CB.battery_report().total_energy_J catch; nothing end),
        "closed_at"     => length(env.cache.closed_set),
```

  ⚠️ `CB.sim_time(env)` 의 **정확한 이름을 먼저 확인**한다(`grep -n "sim_t\|sim_time" tools/monitor/run_demo.jl`).
  run_demo 가 요약에 `sim_seconds` 를 내므로 같은 출처를 쓸 것. **추측하지 않는다.**

- [ ] **Step 2** — 종단값도 요약 행에 있는지 확인한다: `makespan`·`energy_J`(=`battery.total_energy_J`)·
  `closed`·`total`·`complete`. 2026-08-14 실측: **에너지는 최상위가 아니라 `row["battery"]` 하위**다.

- [ ] **Step 3** — 스모크 1판으로 필드가 실제로 나오는지 본다(시뮬 1회, 약 4분).

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
export JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
rm -rf /tmp/smoke_bi && mkdir -p /tmp/smoke_bi
../.venv/bin/python llm_ood_eval.py run --case all --seeds 1 --policies canonical \
  --out /tmp/smoke_bi/rows.jsonl --dspy-url http://127.0.0.1:8090 --router 0
../.venv/bin/python -c "
import json; r=json.loads(open('/tmp/smoke_bi/rows.jsonl').read().strip())
for d in r['decisions']:
    print(d['at'], d.get('sim_t_at'), d.get('energy_at_J'), d.get('closed_at'))
print('terminal:', r['makespan'], (r.get('battery') or {}).get('total_energy_J'), r['closed'], r['total'], r['complete'])"
```

  Expected: 결정마다 `sim_t_at` 이 **단조 증가**, `energy_at_J` 도 단조 증가, 마지막 결정의
  두 값이 종단값보다 작거나 같다. 하나라도 `None` 이면 **여기서 멈춘다** — 원자료가 없으면
  뒤가 전부 무효다.

- [ ] **Step 4** — 커밋. 이후 모든 스윕은 이 커밋 위에서 돈다(Global Constraint 4).

---

## Task 2: 표집기가 (칸, 팔, c, 다음칸) 전이를 낸다

**Files:** Modify `wm4spacecraft_manufacturing/dp_oracle/sample_grid.py`

- [ ] **Step 1** — `rows_to_samples()` 를 전이 조립으로 바꾼다. 판 하나의 결정 목록을 **순서대로**
  훑으며 연속 쌍에서 구간을 만든다. 마지막 결정의 다음 상태는 종단이다.

```python
    # 결정 k -> k+1 구간. J 의 완주 분기 형태로 러닝 코스트를 고정하고(위 §핵심), 종단에서
    # 차액을 정산한다. w_E 는 objective 에서 읽는다 — 리터럴 금지.
    w_E = objective.energy_weight(objective.load())
    ds = sorted(r.get("decisions") or [], key=lambda d: d["at"])
    for i, d in enumerate(ds):
        nxt = ds[i + 1] if i + 1 < len(ds) else None
        t1, e1 = (nxt["sim_t_at"], nxt["energy_at_J"]) if nxt else (r["makespan"], term_energy)
        c = (t1 - d["sim_t_at"]) + w_E * (e1 - d["energy_at_J"])
        next_cell = cell_key(state_of(nxt, axes)) if nxt else None
        terminal = None if nxt else ("goal" if r["complete"] else "dead_end")
```

- [ ] **Step 2** — 종단 정산값을 행에 같이 싣는다(솔버가 재계산하지 않게):

```python
        "terminal_value": None if nxt else (
            0.0 if r["complete"]
            else objective.J_row(r) - sum_of_all_c_in_this_board),
```

  ⚠️ `sum_of_all_c` 는 그 판의 **모든** 구간 합이다. 판 단위로 먼저 c 를 다 만든 뒤 정산할 것.

- [ ] **Step 3** — **분해 충실성 검사를 표집기 안에 넣는다.** 판마다
  `abs(Σc + terminal_value − objective.J_row(row)) < 1e-6` 을 확인하고, 어긋나면 그 판을
  **버리지 않고 표시**해서 센다. 어긋난 판이 하나라도 있으면 표집 종료 시 **exit 1**.

---

## Task 3: 분해 충실성 단위검사 (차단 게이트)

**Files:** Create `wm4spacecraft_manufacturing/dp_oracle/test_cost_decomposition.py`

합성 판으로 두 분기를 모두 검사한다. **시뮬을 돌리지 않는다.**

- [ ] 완주 판: `Σc + 0 == J` (에너지 항이 살아 있는지 포함)
- [ ] 미완주 판: `Σc + terminal == J`, 그리고 `terminal != 0`
- [ ] 결정이 1개뿐인 판 · 0개인 판(전이 없음)
- [ ] `sim_t_at`/`energy_at_J` 가 `None` 인 행은 **버리지 않고 세어서** 보고
- [ ] w_E 를 `objective` 에서 읽는지(리터럴 0 이 아닌지)

---

## Task 4: 진짜 backward induction 솔버

**Files:** Modify `wm4spacecraft_manufacturing/dp_oracle/dp_solve.py`
(기존 `solve()` 는 `solve_constant_arm()` 으로 **개명해 보존**한다 — 두 판을 비교할 수 있어야 한다.)

```
V(goal)     = 0
V(dead_end) = terminal_value                    (표본이 실어 온 정산값)
Q(s,a)      = mean_k [ c_k + V(s'_k) ]
V(s)        = min_a Q(s,a)
a*(s)       = argmin_a Q(s,a)
```

- [ ] **버킷 사이**: `prog_b` **역순** backward induction (progress 단조성이 DAG 를 보장).
      `_bucket()` 이 이미 cell key 의 첫 성분을 자른다.
- [ ] **버킷 내부**: 같은 `prog_b` 안에서 결정이 여러 번 나 자기순환이 생긴다 → **value iteration**.
      허용오차·최대 반복수를 명시하고 **수렴 실패 노드를 조용히 넘기지 않는다**(`converged` 필드).
- [ ] **다음 칸이 표에 없으면**: `V` 를 0 으로 두지 않는다. 그 전이를 `dangling` 으로 세고,
      해당 (칸,팔) 의 Q 를 **미정의**로 남긴다. 0 으로 두면 미지의 미래가 공짜가 된다.
- [ ] **아래 세 규칙은 2026-08-14 에 단위검사가 잡은 것이다. 반드시 승계한다:**
  - 완전 동점(격차 0·분산 0)은 tie 다 → 비교는 `<=` 여야 한다(`<` 면 임의로 하나를 뽑는다)
  - **팔이 하나뿐인 칸은 a\* 를 주장하지 않는다** — argmin 이 아니다. `unresolved_reason="single_arm"`
  - J 채점 불가 표본은 평균에 안 넣고 **센다**. 전부 불가면 `V=None`(0.0 아님)
- [ ] `test_dp_solve.py` 를 backward induction 용으로 확장: 손계산 가능한 2-버킷 사슬에서
      V 가 뒤에서 앞으로 전파되는지, 자기순환 칸이 수렴하는지.
- [ ] **계층 백오프는 일단 끈다.** 진짜 전이가 생기면 (칸,팔) 표본이 훨씬 촘촘해질 수 있다.
      먼저 L0 로만 풀어 커버리지를 재고, 부족하면 그때 켠다(끈 채로 잰 수치를 report 에 남길 것).

---

## Task 5: 재표집 → 풀이

- [ ] **파일럿 먼저**(1 case × 1 seed × 5팔). 분해 충실성 검사가 통과하는지 본다.
      **실패하면 여기서 멈춘다** — 스키마가 틀린 채 420판을 돌리면 전부 버려야 한다.
- [ ] 전체 표집: `sample_grid.py --jobs 20 --seeds 1,...,12` (2026-08-14 실측 420판 ≈ 90분,
      2라운드로 나눠 돌렸다). 표집과 스윕을 동시에 돌려도 된다(Global Constraint 10).
- [ ] `dp_solve.py` → `value.json`. **보고할 것**: 칸 수 · a\* 확정 칸 · tie · single_arm ·
      dangling 전이 수 · 수렴 실패 노드 수 · 결정 기준 커버리지.

---

## Task 6: 4정책 전면 재스윕 (한 세대)

- [ ] 사전 확인: `git status --porcelain tools/monitor/` 가 **비어 있어야 한다**.
- [ ] 기존 결과 보존: `mv results_4pol results_4pol_gen_constantarm_2026-08-14`
- [ ] 3정책 (약 75분):
```bash
bash run_4pol_parallel.sh --jobs 26 --policies canonical,surrogate,dspy
```
- [ ] dp 레인 (약 25분, **별도 트리**):
```bash
bash run_4pol_parallel.sh --jobs 26 --policies dp --shards-dir results_4pol/shards_dp
```
- [ ] 표: `bash finish_tables.sh`  → `artifacts_4pol/COMPARE.md` · `compare.html` · `FINAL.md`

---

## Task 7: 판정 — "천장" 이라는 이름을 쓸 수 있는가

`build_compare_table.py` 가 §8.7 gap 을 **자동으로 다시 잰다**(평균 대 평균, n≥3 쌍).
2026-08-14 기준선은 **108/121 = 89.3%** 였다.

- [ ] gap 이 **0 이면** DP 열 부제를 "ceiling" 으로 되돌린다.
- [ ] gap 이 **0 이 아니면** 이름을 쓰지 않는다. 다만 이제 원인이 상수-팔이 아니므로
      **추상화 손실로 좁혀 보고**한다: 어느 칸에서 넘겼는지, 그 칸의 φ̃ 가 무엇을 버렸는지.
- [ ] 상수-팔 판(`results_4pol_gen_constantarm_2026-08-14`)과 **나란히 비교**해 표에 싣는다 —
      이번 작업이 실제로 무엇을 바꿨는지가 그 대비에 있다.

---

## Task 8: 게이트 전수 + 문서

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
- [ ] `fill_results_doc.py` 로 결과 문서 생성(수치를 손으로 적지 않는다).
- [ ] `RESULTS_ROUTER3WAY_2026-08-14.md` §5-C 에 "이 한계는 2026-08-15 계획이 해소했다/못 했다"를
      한 줄로 잇는다. 옛 문서를 지우지 않는다 — 두 세대의 기록이 나란히 남아야 한다.

---

## 실패해도 이상하지 않은 것 (미리 적어 둔다)

1. **gap 이 여전히 0 이 아닐 수 있다.** φ̃ 추상화 손실은 backward induction 으로 안 사라진다.
   원 설계 §2.1 이 그 대가를 미리 인정했다. 그러면 그때 남는 gap 이 **진짜 측정 대상**이다.
2. **전이가 희소할 수 있다.** 팔을 고정해 굴리면 궤적이 갈려 다음 칸이 흩어진다(2026-08-14 실측:
   43칸 중 26칸이 단일 팔). `dangling` 전이가 많으면 커버리지를 늘리거나 백오프를 켠다 —
   **값을 지어내지 않는다.**
3. **`w_E` 가 0 이면** 구간 비용에서 에너지가 사라진다. `objective.json` 의 κ 를 먼저 확인할 것.
