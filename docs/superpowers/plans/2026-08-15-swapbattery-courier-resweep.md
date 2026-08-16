# SwapBattery 물리 배송 — 3레인 재스윕 계획

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (권장) 또는
> `superpowers:executing-plans` 로 task 단위로 실행할 것. 체크박스(`- [ ]`)로 진행을 추적한다.
> ⚠️ 이 계획은 **코드를 거의 쓰지 않는다** — 대부분이 데이터 생성과 게이트다. 그래서 각 task 의
> "test" 는 단위검사가 아니라 **실행 전에 반드시 통과해야 하는 게이트 명령**이다. 게이트를
> 건너뛰면 이 저장소가 여러 번 데인 실패 모드(조용히 구세대를 새 이름으로 발행)가 재현된다.

**Goal:** `SwapBattery` 가 시간·라인정지를 쓰는 물리적 배송이 된 새 코드 세대에서
`canonical` · `surrogate` · `dspy` 3레인 × 7 case × 30 seed = **630 판**을 재생성하고,
발행 표(`artifacts_4pol/COMPARE.md`·`FINAL.md`)와 결과 문서를 그 세대로 갈아 끼운다.

**Architecture:** 기존 스윕 인프라를 **그대로** 쓴다 — `run_4pol_parallel.sh`(K=16, 210 샤드)
→ `finish_tables.sh`(병합 → 세대 단일성 검사 → FINAL/COMPARE). 새로 만드는 것은 스크립트가
아니라 **사전 게이트 4개**(§Task 2)와 **비용 프로브**(§Task 4)뿐이다. 코드 세대는 git HEAD SHA
로 도장되므로(`run_shard.sh` 의 `.shard_meta`) **커밋이 선행 조건**이다.

**Tech Stack:** Julia 1.10 (`julia +lts --project=.`) · Python `.venv` (dspy 3.3.0) ·
DSPy 서비스(uvicorn, `127.0.0.1:8090`) · bash 스윕 드라이버

**Spec:** 이 사이클에는 별도 설계문서가 없다. 근거가 되는 구현과 실측은
`src/respec/battery_courier.jl` 머리말 + 이 계획서 §배경 이다.

---

## 배경 — 무엇이 세대를 갈랐나

`swap_battery!` 는 **장부 조작만** 했다: 같은 스텝에 `fleet.soc[role] = 1.0` 을 찍고 끝났다.
그래서 SwapBattery 는 시간도 자원도 안 쓰는 **공짜 팔**이었고, Replace 와의 선택이 진짜 비교가
아니었다.

이제 (`src/respec/battery_courier.jl`):

1. 가장 가까운 창고의 **예비 로봇이 배터리를 들고 현장까지 주행**한다(빌려 쓰고 돌려주므로
   창고 재고 불변 = 배터리 무한).
2. 교체는 **도착한 스텝에만** 적용된다 → 그동안 방전 로봇은 실제로 방전 상태다.
3. 그동안 **주행 라인이 정지**한다(`soc_speed_factor` → 0.0).

**측정된 비용**(tractor, 창고 거리 D=20, 속도 4 m/s): 배송 편도 ≈ **200 스텝 ≈ 5 sim초**.
배터리 사건 하나당 그만큼 makespan 이 늘어난다. 즉 **battery 가 낀 case 의 ③ 빌드시간과
① 완주율이 바뀐다** — 그것이 이 재스윕의 이유다.

같은 커밋에 들어간 두 번째 변경: `_pick_active_robot` 이 **창고 예비를 고장 대상으로 뽑던
버그**를 고쳤다(`_faultable`). 실측으로 `failed=R16, spare=R16`(자기 자신으로 교체)이 나왔고,
빌드에 투입되지 않은 로봇의 고장은 어떤 정책을 써도 결과가 같아 **사건이 무의미해진다**.
이것도 fault 가 낀 case 의 숫자를 바꾼다.

---

## Global Constraints

이 절의 값은 모든 task 의 요구사항에 암묵적으로 포함된다.

- **`objective.json` 은 안 바뀐다.** `objective_hash` = **`19819377a7f8ebb2`** 유지. 목적함수
  J 의 의미가 바뀐 것이 아니라 **동역학**이 바뀌었다. 해시를 올리면 라벨셋·surrogate 가 전부
  구세대로 재분류된다 — **올리지 말 것.**
- **스윕은 `run_4pol_parallel.sh` 경로에서만 병렬 허용.** 그 경로는 `assignment_mode=:greedy`
  라 MILP 를 안 풀고 MeshCat 도 없다(스크립트 머리말 §근거). **`render_demo.jl` 은 이 예외에
  해당하지 않는다** — 렌더는 순차(또는 `render_all.sh` 의 워커 별칭)로만.
- **정책 목록은 `canonical,surrogate,dspy`** — `finish_tables.sh` 의 `POL3` 와 **정확히 같은
  문자열**이어야 한다. 어긋나면 병합기가 "OK" 를 내면서 조용히 부분 파일을 만든다.
- **DSPy 서비스가 떠 있어야 한다**(`127.0.0.1:8090`). 없으면 `dspy`·`surrogate` 결정이
  canonical 로 **조용히** 폴백해 이름만 dspy 인 canonical 판이 만들어진다.
- **`.shard_meta` provenance 는 커밋된 SHA 만 본다.** 미커밋 작업 트리는 못 잡는다
  (`run_shard.sh` 머리말). → **Task 1 커밋이 하드 선행조건.**
- **구세대 산출물은 지우지 않고 옮긴다.** 기존 관례: `results_4pol_gen_<이름>_<날짜>/`.
- **스윕 도중 코드 수정 금지**(2026-08-14 에 데인 함정). 수정하려면 스윕을 멈추고 다시 시작.
- **기준 비용(실측, `_night/status_shards.jsonl` 840행)**: 샤드 중앙값 **261 s**, 210 샤드,
  K=16 → **약 62분**. 배송이 붙는 4 case(battery·all·fault_battery·battery_zone)는 늘어난다 —
  실제 증가율은 Task 4 에서 잰다.
- **`Pkg.test()` 기대 baseline = 11 pass / 1 error**(Gurobi 라이선스 없음, 변경과 무관).

---

## 파일 구조 — 무엇이 새로 생기고 무엇이 바뀌나

| 경로 | 책임 | 이 계획에서 |
|---|---|---|
| `results_4pol/shards/<case>/s<seed>/` | 3레인 샤드(판당 rows.jsonl + logs/stream) | **전량 재생성** |
| `results_4pol/<case>.jsonl` | case 별 병합 결과 | 재생성 |
| `artifacts_4pol/{FINAL,COMPARE}.md`, `compare.html` | 발행 표 | 재생성 |
| `results_4pol_gen_swapfree_2026-08-15/` | **구세대 보존** | 신규(이동) |
| `wm4spacecraft_manufacturing/md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` | 이 세대 결과 문서 | 신규 |
| `wm4spacecraft_manufacturing/gate_courier_sweep.sh` | 사전 게이트 4종 한 파일 | 신규 |
| `.claude/CLAUDE.md` | 세대 항목 | 수정 |
| `tools/monitor/{streams,anim}/` | 데모 녹화 | battery 낀 판 재렌더 |

---

## ⚠️ 범위에서 **뺀** 것 — 명시적으로 결정한 것

이 셋은 이번 사이클에 하지 **않는다**. 안 한다는 사실을 산출물에 적는 것까지가 범위다.

1. **`dp` 레인.** `dp_oracle/value.json` 은 별도 표집 파이프라인(`sample_grid.py`, 4~5시간)에서
   나오고 그것은 **구세대 동역학**에서 뽑힌 것이다. 재표집 없이 dp 열을 실으면 **세대가 섞인
   표**가 된다. `finish_tables.sh` 는 `results_4pol/shards_dp` 가 없으면 dp 열을 "이 레인은
   스윕에 없음" 으로 남기도록 이미 되어 있다 → **`shards_dp` 를 옮겨 두고 3열 표로 낸다.**
2. **surrogate 재학습.** 배포 모델은 SwapBattery 가 공짜이던 시절의 라벨
   (`relabel_2026-08-16.jsonl`)로 학습됐다. 이제 SwapBattery 는 라인 정지를 쓰므로 **그 선호가
   틀렸을 수 있다.** 재학습은 라벨 격자 재생성을 요구하므로 별건이다 — 대신 Task 7 에서
   **얼마나 틀렸는지를 측정**하고 다음 사이클의 근거로 남긴다.
3. **런 간 재현성 결함.** seed 10 판의 OOD 대상이 실행마다 바뀐다(R1/R4 → R16/R5 → R6/R7).
   통제 실험에서 배송 ON/OFF 와 무관하게 움직였으므로 이 기능 탓이 아니다. 유력 후보는
   `_pick_active_robot` 이 `env.cache.active_set`(Set)을 **순회 순서 미정의**로 도는 것.
   별건으로 올린다.

---

## Task 1: 코드 세대를 커밋한다

**왜 첫 task 인가:** `run_shard.sh` 의 재개 도장은 `git rev-parse --short HEAD` 다. 미커밋
상태로 스윕하면 모든 샤드가 **직전 세대의 SHA** 로 도장되고, 나중에 재개할 때 구세대 샤드를
SKIP 해 병합에 넣는다. 2026-08-12 밤에 실제로 그럴 뻔한 실패다.

**Files:**
- Commit: `src/respec/battery_courier.jl`(신규), `src/respec/{respec,ood_injection,replace_robot,replan}.jl`,
  `src/{route_planning,render_tools,demo_utils,ConstructionBots}.jl`,
  `src/navigator/battery.jl`, `tools/monitor/{render_demo,run_demo}.jl`

- [ ] **Step 1: 이 계획과 무관한 미커밋 변경을 분리한다**

작업 트리에 이 작업과 **무관한** 수정이 섞여 있다(2026-08-15 확인): `src/essential_tg_coponents.jl`,
`src/monitor/monitor.jl`, `tools/monitor/dashboard.html`, `wm4spacecraft_manufacturing/` 의 py 삭제
8개, `objective.json`, `_night/*`. 이것들을 같은 커밋에 넣으면 세대 경계가 흐려진다.

```bash
cd /home/chahj578/Construction_OODlayer
git status --porcelain
git diff --stat src/essential_tg_coponents.jl src/monitor/monitor.jl tools/monitor/dashboard.html
```

판단: 이 셋이 무엇인지 **사람에게 물어본다**. 이 계획을 실행하는 에이전트가 임의로 커밋하거나
되돌리지 말 것.

- [ ] **Step 2: `objective.json` 을 먼저, 따로 커밋한다**

CLAUDE.md 가 이미 지목한 부채다 — 2026-08-13 이후 커밋되지 않은 채 작업 트리에만 있고, 깨끗이
체크아웃하면 `dp_solve.py:499-504` 가 하드 스톱한다. 이 스윕은 그 파일을 읽는 소비처를 여럿
태우므로 여기서 닫는다.

```bash
.venv/bin/python wm4spacecraft_manufacturing/audit_objective.py; echo "audit rc=$?"
```
Expected: `rc=0` (9/9). 해시가 `19819377a7f8ebb2` 인지 출력에서 눈으로 확인.

```bash
git add wm4spacecraft_manufacturing/objective.json
git commit -m "chore(objective): 작업 트리에만 있던 현행 세대 objective.json 을 이력에 넣는다

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: 배송 계층 커밋**

```bash
git add src/respec/battery_courier.jl src/respec/respec.jl src/respec/ood_injection.jl \
        src/respec/replace_robot.jl src/respec/replan.jl \
        src/route_planning.jl src/render_tools.jl src/demo_utils.jl src/ConstructionBots.jl \
        src/navigator/battery.jl tools/monitor/render_demo.jl tools/monitor/run_demo.jl
git commit -m "feat(battery): SwapBattery 를 창고 예비의 물리적 배터리 배송으로 바꾼다

교체가 도착 스텝에만 적용되므로 방전 구간이 실재하고(빨강), 배송 예비는 초록으로 그려지며,
그동안 주행 라인이 선다. 창고 재고는 빌려 쓰고 돌려주므로 불변(배터리 무한).
같은 커밋: _pick_active_robot 이 창고 예비를 고장 대상으로 뽑던 버그를 _faultable 로 막는다.

구세대 재현: DEMO_BATTERY_COURIER=0

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git rev-parse --short HEAD | tee /tmp/gen_sha.txt
```

- [ ] **Step 4: 테스트 baseline 확인**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5
```
Expected: `11 passed, 0 failed, 1 errored` (errored = Gurobi 라이선스). 다른 숫자면 **중단**.

---

## Task 2: 사전 게이트 4종을 스크립트로 만든다

**왜 스크립트인가:** 이 넷은 전부 **조용히 실패**하는 종류다. 손으로 확인하면 한 번은 빠뜨리고,
그러면 630 판을 돌린 뒤에야 알게 된다(2시간 손실). 한 파일에 적어 두고 스윕 직전에 돌린다.

**Files:**
- Create: `wm4spacecraft_manufacturing/gate_courier_sweep.sh`

**Interfaces:**
- Produces: exit 0 = 스윕 시작 가능. exit != 0 = 시작하면 안 되는 이유를 stdout 에 적는다.

- [ ] **Step 1: 게이트 스크립트를 쓴다**

```bash
cat > wm4spacecraft_manufacturing/gate_courier_sweep.sh <<'EOF'
#!/usr/bin/env bash
# =============================================================================
# gate_courier_sweep.sh -- SwapBattery 배송 세대 재스윕 **직전** 게이트 4종.
# 넷 다 "조용히 실패" 하는 종류라, 630 판을 돌린 뒤에 알게 되면 2시간을 버린다.
#   G1 배송이 스윕 엔진에서 실제로 켜지고 발화하는가 (이름만 새 세대인 판 방지)
#   G2 창고 예비가 고장 대상에서 빠지는가 (_faultable 회귀)
#   G3 DSPy 서비스가 떠 있는가 (없으면 dspy/surrogate 가 canonical 로 조용히 폴백)
#   G4 objective_hash 가 현행인가
# 사용: bash gate_courier_sweep.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"
PY="$REPO/.venv/bin/python"
DSPY_URL="${DSPY_URL:-http://127.0.0.1:8090}"
fail=0

echo "== G1: 스윕 엔진(run_demo.jl)에서 SwapBattery 가 배송으로 집행되는가 =="
# DEMO_FORCE_MACRO 로 배터리 사건의 팔을 SwapBattery 로 못박는다(policy.jl:664).
# 그러지 않으면 시드에 따라 Replace 가 뽑혀 이 게이트가 아무것도 검사하지 못한다.
G1LOG=$(mktemp)
DEMO_MODEL=tractor.mpd DEMO_OOD=battery DEMO_SEED=1 DEMO_OOD_SEED=3 DEMO_N=2 \
DEMO_POLICY=canonical DEMO_FORCE_MACRO=SwapBattery DEMO_BSOC=0.9 \
CARRIER_RESCUE=1 RELOCATE_GATE=1 \
  julia +lts --project=. --startup-file=no tools/monitor/run_demo.jl > "$G1LOG" 2>&1
grep -aq 'courier=true' "$G1LOG"                       || { echo "  !! courier 가 꺼진 채로 돈다"; fail=1; }
grep -aq 'swap=battery_courier_dispatched' "$G1LOG"    || { echo "  !! SwapBattery 가 배송으로 안 갔다(즉시 교체 폴백?)"; fail=1; }
grep -aq 'PROJECT COMPLETE' "$G1LOG"                   || { echo "  !! 이 판이 완주하지 않았다"; fail=1; }
[ "$fail" -eq 0 ] && echo "  OK  ($G1LOG)"

echo "== G2: 창고 예비가 고장 대상에서 빠지는가 =="
# 예비 id 는 실제 로봇 수보다 크다(tractor: 실로봇 1..10, 예비 11..18).
# fault 판을 하나 돌려 고장 대상 id 가 예비 대역에 들어오면 회귀다.
G2LOG=$(mktemp)
DEMO_MODEL=tractor.mpd DEMO_OOD=fault DEMO_SEED=1 DEMO_OOD_SEED=10 DEMO_N=2 \
DEMO_POLICY=canonical CARRIER_RESCUE=1 RELOCATE_GATE=1 \
  julia +lts --project=. --startup-file=no tools/monitor/run_demo.jl > "$G2LOG" 2>&1
if grep -aoE 'Robot R[0-9]+ has broken down' "$G2LOG" | grep -oE '[0-9]+' \
   | awk '$1 > 10 {print; found=1} END {exit !found}' >/dev/null; then
  echo "  !! 예비 로봇(id>10)이 고장 대상으로 뽑혔다 — _faultable 회귀"; fail=1
else
  echo "  OK  ($G2LOG)"
fi

echo "== G3: DSPy 서비스 =="
if curl -s --max-time 5 "$DSPY_URL/health" | grep -q '"status":"ok"'; then
  echo "  OK  $DSPY_URL"
else
  echo "  !! $DSPY_URL 응답 없음 — dspy/surrogate 가 canonical 로 조용히 폴백한다"; fail=1
fi

echo "== G4: objective_hash =="
"$PY" wm4spacecraft_manufacturing/audit_objective.py >/dev/null 2>&1 \
  && echo "  OK" || { echo "  !! audit_objective.py 실패"; fail=1; }

echo
[ "$fail" -eq 0 ] && echo "GATES PASS — 스윕 시작 가능" || echo "GATES FAIL — 스윕을 시작하지 말 것"
exit "$fail"
EOF
chmod +x wm4spacecraft_manufacturing/gate_courier_sweep.sh
```

- [ ] **Step 2: 게이트를 돌려 통과시킨다**

```bash
bash wm4spacecraft_manufacturing/gate_courier_sweep.sh
```
Expected: `GATES PASS — 스윕 시작 가능`, exit 0.

⚠️ **G1 이 `swap=battery_courier_dispatched` 를 못 찾으면 여기서 멈춘다.** 그 문자열은
`run_demo.jl:379` 의 `println("[battery] swap=$(sw.status) ...")` 가 낸다. 2026-08-15 시점에
이 경로는 **render 엔진에서만 실측 확인됐고 sweep 엔진에서는 SwapBattery 가 뽑힌 판이
없어서 미확인이다** — 이 게이트가 그 구멍을 닫는 것이 목적이다.

- [ ] **Step 3: 커밋**

```bash
git add wm4spacecraft_manufacturing/gate_courier_sweep.sh
git commit -m "test(sweep): 배송 세대 재스윕 사전 게이트 4종

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 구세대를 보존한다

**Files:**
- Move: `results_4pol/` → `results_4pol_gen_swapfree_2026-08-15/`
- Move: `artifacts_4pol/` → `artifacts_4pol_gen_swapfree_2026-08-15/`

- [ ] **Step 1: 지금 무엇이 있는지 기록한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
ls results_4pol/shards/*/ -d | wc -l          # 210 이어야 한다
wc -l results_4pol/*.jsonl
```

- [ ] **Step 2: 옮긴다 (지우지 않는다)**

```bash
mv results_4pol results_4pol_gen_swapfree_2026-08-15
mv artifacts_4pol artifacts_4pol_gen_swapfree_2026-08-15
mkdir -p results_4pol
```

`shards_dp` 도 같이 따라간다 — 그것이 §범위에서 뺀 것 ①의 실행이다(dp 트리가 없으면
`finish_tables.sh` 가 dp 열을 자동으로 뺀다).

- [ ] **Step 3: 왜 옮겼는지 한 줄 남긴다**

```bash
cat > results_4pol_gen_swapfree_2026-08-15/GENERATION.md <<'EOF'
# 구세대: SwapBattery 가 공짜이던 판 (~2026-08-15)

`swap_battery!` 가 같은 스텝에 SoC 만 1.0 으로 찍던 시절의 630 판.
SwapBattery 는 시간도 자원도 쓰지 않았고, `_pick_active_robot` 은 창고 예비를 고장 대상으로
뽑을 수 있었다. 두 결함이 battery/fault 가 낀 case 의 makespan·완주율·결정 라벨을 바꾼다.

재현: `DEMO_BATTERY_COURIER=0` (배송만 끈다. 고장 피커 수정은 되돌아가지 않는다).
후속 세대: `results_4pol/` + `md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md`
EOF
git add results_4pol_gen_swapfree_2026-08-15/GENERATION.md 2>/dev/null || true
```

> `results_4pol*` 은 `.gitignore:46` 이 배제하므로 대부분 커밋되지 않는다. `GENERATION.md` 만
> 강제로 넣고 싶으면 `git add -f`. 넣지 않기로 해도 무방하다 — 파일은 디스크에 남는다.

---

## Task 4: 비용 프로브 — 2시간을 걸기 전에 30분으로 잰다

**왜:** 배송은 배터리 사건마다 라인을 세운다. 그 비용이 얼마인지 **모르는 채** 630 판을 걸면,
샤드가 `deadline-seconds` 를 넘겨 반쯤 끝난 트리가 남는다. battery 가 낀 case 는 7개 중 4개다.

**Files:**
- Create: `results_4pol_probe/` (프로브 전용 트리 — 본 스윕 트리를 오염시키지 않는다)

- [ ] **Step 1: 배터리 낀 case 2개 × seed 3개를 돌려 시간을 잰다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
for c in battery fault_battery; do
  for s in 1 2 3; do
    t0=$SECONDS
    bash run_shard.sh "$c" "$s" "results_4pol_probe/$c/s$s" "canonical,surrogate,dspy" \
      > "/tmp/probe_${c}_s${s}.log" 2>&1
    rc=$?; echo "$c s$s  rc=$rc  $((SECONDS-t0))s"
  done
done
```

- [ ] **Step 2: 구세대 같은 칸과 비교한다**

```bash
.venv/bin/python - <<'PY'
import json, pathlib
old = {}
for l in open('_night/status_shards.jsonl'):
    r = json.loads(l)
    if r.get('status') == 'ok':
        old[(r['case'], r['seed'])] = r['wall_seconds']      # 마지막 값이 남는다
for c in ('battery', 'fault_battery'):
    for s in (1, 2, 3):
        print(c, s, 'old wall_s =', old.get((c, s), '?'))
PY
```

**판정 기준:**
- 증가율이 **1.5배 이하** → 그대로 진행(예상 총 wall ≈ 62분 × 1.5 ≈ **95분**).
- **1.5~3배** → 진행하되 `--deadline-seconds 28800`(8h) 유지하고 사람에게 보고.
- **3배 초과 또는 미완주 발생** → **중단하고 보고한다.** 라인 정지가 endgame 교착을 만드는
  것일 수 있다(배송 대기 중 `stall` 카운터를 안 세도록 `run_demo.jl` 에 가드를 넣었지만,
  그 가드가 닿지 않는 경로가 남았을 수 있다).

- [ ] **Step 3: 프로브 트리를 치운다**

```bash
rm -rf results_4pol_probe
```

---

## Task 5: 630 판 재스윕

**Files:**
- Create: `results_4pol/shards/<case>/s<seed>/` × 210

- [ ] **Step 1: 게이트를 다시 돌린다 (Task 2 이후 무엇도 안 바뀌었는지)**

```bash
bash wm4spacecraft_manufacturing/gate_courier_sweep.sh || exit 1
git status --porcelain src tools | grep . && echo "!! 작업 트리가 더럽다 — 스윕 금지" && exit 1
```

- [ ] **Step 2: dry-run 으로 작업 목록을 눈으로 본다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash run_4pol_parallel.sh --dry-run --policies canonical,surrogate,dspy
```
Expected: 210 개 작업, `POLICIES=canonical,surrogate,dspy`.

- [ ] **Step 3: 스윕을 건다**

```bash
nohup bash run_4pol_parallel.sh --jobs 16 --policies canonical,surrogate,dspy \
      --deadline-seconds 28800 > _night/resweep_courier.log 2>&1 &
echo $! > /tmp/resweep.pid
```

⚠️ **이 시점부터 스윕이 끝날 때까지 `src/`·`tools/` 를 수정하지 않는다**(Global Constraints).

- [ ] **Step 4: 완료 확인**

```bash
tail -20 _night/resweep_courier.log
ls -d results_4pol/shards/*/s* | wc -l          # 210
grep -c '"status":"ok"' _night/status_shards.jsonl
```
Expected: 210 샤드, fail 0. **fail 이 하나라도 있으면 그 샤드 로그를 읽고 보고한다** —
재개(`--resume` 없이 같은 명령)는 provenance 도장이 같으면 SKIP 하므로 안전하다.

- [ ] **Step 5: 배송이 실제로 발화한 판이 몇 개인지 센다**

이 재스윕의 **존재 이유**가 데이터에 있는지 확인한다. 하나도 없으면 세대가 안 갈린 것이다.

```bash
.venv/bin/python - <<'PY'
import json, glob, collections
n_swap = n_courier = 0
per_case = collections.Counter()
for p in glob.glob('results_4pol/shards/*/s*/logs/stream_*.jsonl'):
    for l in open(p):
        d = json.loads(l)
        for e in (d.get('respec_history') or []) + ([d['respec']] if d.get('respec') else []):
            ex = (e.get('verification') or {}).get('execution') or {}
            if ex.get('action') == 'swap_battery':
                n_swap += 1
                if ex.get('delivery', '').startswith('depot courier'):
                    n_courier += 1
                    per_case[p.split('/')[2]] += 1
print('swap_battery 집행 =', n_swap, '| 그중 배송 =', n_courier)
print('case 별 배송:', dict(per_case))
PY
```
Expected: `배송 > 0`, 그리고 **`n_courier == n_swap`**(즉시 교체 폴백이 섞이면 창고에 예비가
없었다는 뜻이므로 그 사실을 보고한다).

---

## Task 6: 표와 결과 문서를 갈아 끼운다

**Files:**
- Create: `artifacts_4pol/{FINAL.md,COMPARE.md,compare.html}`
- Create: `wm4spacecraft_manufacturing/md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md`

- [ ] **Step 1: 파이프라인을 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash finish_tables.sh 2>&1 | tee _night/finish_tables_courier.log
```
Expected: 4단계 "세대 단일성 + 정책 구성 확인" 이 `정책: {'canonical':…, 'surrogate':…, 'dspy':…}`
와 **세대 쌍 1개**를 찍고 통과. 세대가 섞였다고 나오면 구세대 샤드가 남아 있는 것이다 —
Task 3 의 이동을 확인한다.

- [ ] **Step 2: dp 열이 빠졌는지 확인한다**

```bash
grep -n 'dp' artifacts_4pol/COMPARE.md | head
```
Expected: dp 열이 "이 레인은 스윕에 없음" 으로 표시. **숫자가 들어 있으면 중단** — 구세대
`shards_dp` 가 남아 세대가 섞인 것이다.

- [ ] **Step 3: 구세대와 나란히 비교한다**

```bash
.venv/bin/python - <<'PY'
import json, glob, collections
def load(d):
    out = collections.defaultdict(list)
    for p in glob.glob(f'{d}/*.jsonl'):
        case = p.split('/')[-1][:-6]
        for l in open(p):
            r = json.loads(l)
            out[(case, r.get('policy'))].append(r)
    return out
new = load('results_4pol')
old = load('results_4pol_gen_swapfree_2026-08-15')
print(f'{"case":<14}{"policy":<11}{"완주 old→new":<16}{"makespan 중앙 old→new"}')
for k in sorted(set(new) | set(old)):
    if k[1] is None: continue
    def stat(rs):
        if not rs: return ('-', '-')
        comp = sum(1 for r in rs if r.get('complete'))
        ms = sorted(r['makespan'] for r in rs if r.get('complete') and r.get('makespan'))
        return (f'{comp}/{len(rs)}', f'{ms[len(ms)//2]:.1f}' if ms else '-')
    (co, mo), (cn, mn) = stat(old.get(k, [])), stat(new.get(k, []))
    print(f'{k[0]:<14}{k[1]:<11}{co+" → "+cn:<16}{mo} → {mn}')
PY
```

**읽는 법:** battery 가 낀 4 case(battery·all·fault_battery·battery_zone)에서 makespan 이
**늘어야** 정상이다(배송이 시간을 쓰므로). zone·fault 단독 case 는 거의 안 바뀌어야 한다 —
**크게 바뀌면 `_faultable` 수정의 효과**이므로 그렇게 해석해 적는다. 두 축 모두 안 바뀌었다면
세대가 안 갈린 것이므로 **Task 5 Step 5 로 돌아간다.**

- [ ] **Step 4: 결과 문서를 쓴다**

`md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md` 에 최소 다음을 담는다. **표의 모든 숫자는 위
Step 3 출력에서 가져온다 — 손으로 채우지 않는다.**

1. 무엇이 세대를 갈랐나(배송 + 고장 피커) · 재현 명령(`DEMO_BATTERY_COURIER=0`)
2. 3레인 × 7 case 완주율 · makespan · 에너지 (구세대 대비 Δ)
3. **battery 낀 case 와 안 낀 case 의 대비** — 이것이 이 문서의 헤드라인이다
4. `dp` 열이 없는 이유(§범위에서 뺀 것 ①)
5. Task 7 의 surrogate 라벨 stale 측정 결과
6. 알려진 한계: 런 간 재현성 결함(§범위에서 뺀 것 ③)

- [ ] **Step 5: 구세대 결과 문서에 🔴 배너를 단다**

```bash
grep -l 'RESULTS' md/RESULTS.md md/RESULTS_ONE_STEP_DEVIATION_2026-08-17.md 2>/dev/null
```
각 문서 맨 위에 한 줄:
`> 🔴 **구세대** — SwapBattery 가 공짜이던 판. 현행: md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md`

- [ ] **Step 6: 커밋**

```bash
git add wm4spacecraft_manufacturing/md/ artifacts_4pol/COMPARE.md artifacts_4pol/FINAL.md
git commit -m "data(courier): SwapBattery 배송 세대 3레인 재스윕 결과 + 표

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: surrogate 라벨이 얼마나 낡았는지 **측정**한다

**왜:** 배포 surrogate 는 SwapBattery 가 **공짜이던** 라벨로 학습됐다. 이제 그 팔은 라인 정지를
쓴다. 재학습은 이번 범위 밖이지만, **얼마나 틀렸는지 모르는 채 표를 발행하면** surrogate 열의
약세를 "모델이 나쁘다" 로 오독하게 된다. 다음 사이클의 근거를 여기서 만든다.

**Files:**
- Create: `wm4spacecraft_manufacturing/measure_swap_staleness.py`

- [ ] **Step 1: 측정 스크립트를 쓴다**

```bash
cat > wm4spacecraft_manufacturing/measure_swap_staleness.py <<'PY'
#!/usr/bin/env python3
"""
surrogate 가 배터리 사건에서 SwapBattery 를 고른 판과 Replace 를 고른 판의 **결과**를 가른다.

왜: 배포 모델은 SwapBattery 가 시간을 안 쓰던 시절 라벨로 학습됐다. 배송이 붙은 뒤에도 같은
빈도로 그 팔을 고른다면, 그 선택이 이제 손해인지 이득인지가 다음 사이클의 결정 근거다.
이 스크립트는 **재학습하지 않는다** — 재학습이 필요한지를 판정할 숫자만 만든다.
"""
import json, glob, collections, statistics, sys

BATTERY_CASES = {"battery", "all", "fault_battery", "battery_zone"}
by_arm = collections.defaultdict(lambda: {"n": 0, "complete": 0, "makespan": []})

for p in glob.glob("results_4pol/*.jsonl"):
    case = p.split("/")[-1][:-6]
    if case not in BATTERY_CASES:
        continue
    for line in open(p):
        r = json.loads(line)
        for d in (r.get("decisions") or []):
            if str(d.get("truth_type", "")).startswith("Battery"):
                key = (r.get("policy"), d.get("macro"))
                s = by_arm[key]
                s["n"] += 1
                if r.get("complete"):
                    s["complete"] += 1
                    if r.get("makespan"):
                        s["makespan"].append(r["makespan"])

print(f'{"policy":<11}{"macro":<15}{"n":>5}{"완주율":>9}{"makespan 중앙":>14}')
for (pol, mac), s in sorted(by_arm.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
    rate = s["complete"] / s["n"] if s["n"] else 0.0
    med = statistics.median(s["makespan"]) if s["makespan"] else float("nan")
    print(f"{str(pol):<11}{str(mac):<15}{s['n']:>5}{rate:>8.1%}{med:>14.1f}")

sw = by_arm.get(("surrogate", "SwapBattery"), {"n": 0})
rp = by_arm.get(("surrogate", "Replace"), {"n": 0})
print()
print(f"surrogate 배터리 결정: SwapBattery {sw['n']} · Replace {rp['n']}")
if sw["n"] == 0:
    print("→ surrogate 가 SwapBattery 를 한 번도 안 골랐다. 라벨 stale 문제가 아니라 "
          "지원집합/게이트 문제일 수 있다 — test_surrogate_support.py 를 볼 것.")
PY
```

- [ ] **Step 2: 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
.venv/bin/python measure_swap_staleness.py | tee _night/swap_staleness.txt
```

⚠️ 이 스크립트는 `results_4pol/*.jsonl` 행에 `decisions[]` 와 `truth_type`/`macro` 키가 있다고
가정한다. **첫 실행에서 표가 비면 그 가정이 틀린 것이다** — 실제 키 이름을 확인해 고칠 것:
```bash
.venv/bin/python -c "
import json; r=json.loads(open('results_4pol/battery.jsonl').readline())
print(sorted(r)); print(json.dumps((r.get('decisions') or [{}])[0], ensure_ascii=False)[:400])"
```

- [ ] **Step 3: 판정을 결과 문서 §5 에 적는다**

- SwapBattery 를 고른 판의 완주율/makespan 이 Replace 판보다 **나쁘다** → 라벨이 낡았다.
  다음 사이클 1순위 = 배송 동역학에서 라벨 격자 재생성 + surrogate 재학습.
- 비슷하거나 낫다 → 라벨은 아직 유효하다. 재학습을 **하지 않는다**고 적고 근거를 남긴다.

- [ ] **Step 4: 커밋**

```bash
git add wm4spacecraft_manufacturing/measure_swap_staleness.py
git commit -m "test(surrogate): 배송 도입 후 SwapBattery 선택의 결과를 잰다(재학습 판정용)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 데모 녹화를 새 세대로 다시 만든다

> ### 🔵 2026-08-16 범위 확장 (사람 지시, 실행 중 수신) — **이 절이 아래 원안을 대체한다**
>
> **지시 원문 요지:** SwapBattery 렌더링 방식을 바꿨다(방전 로봇에서 가장 가까운 창고의
> **초록색 예비 로봇**이 나와 배터리를 교체해 다시 움직이게 만든다 — 기준 화면은 어제 UI 에
> 올린 `fault_battery` seed 10). 이제 SwapBattery 가 정상 작동하므로 **battery failure 가 낀
> case 들을 30 seed 전부에서 canonical·surrogate·LLM 각각 rendering & simulation** 하고
> **결과표를 업데이트**할 것. subagent-driven 으로, 자는 동안 자동으로.
>
> **집행 규모:** 4 case(`battery`·`all`·`fault_battery`·`battery_zone`) × **30 seed** ×
> 3 policy = **360 판**. 원안(12 판 = seed 1 뿐)의 **30배**.
> `render_all.sh --seeds 1,...,30` 으로 준다(`--seeds` 플래그가 이미 있다).
> 예상: 판당 ~150s + 배송 정지분, K=8 → **약 3~3.5시간**. 디스크 ~2GB(anim 판당 ~5MB).
>
> **⚠️ 코드 변경 없음이 확인됐다.** 초록 예비 렌더링은 이미 `2b5637c3` 에 들어 있다
> (커밋 메시지: "배송 예비는 초록으로 그려지며"). `git status --porcelain src tools` 비어 있음.
> 따라서 렌더는 **스윕과 같은 코드 세대**에서 나온다 — 추가 커밋 불필요.
>
> **🔴 "결과표 업데이트" 의 의미를 혼동하지 말 것.** `render_all.sh` 머리말이 명시한다:
> *"여기서 나온 숫자는 논문 표의 근거가 아니다. 표의 근거는 `results_4pol/` 이 그대로 유지한다."*
> `render_demo.jl` 과 `run_demo.jl` 은 **같은 세계를 만들지 않는다**(README_RENDER_3D.md §1).
> 그러므로:
> - **발행 표(`artifacts_4pol/{COMPARE,FINAL}.md`)는 이미 Task 6 에서 스윕으로 갱신됐다** —
>   렌더가 그 숫자를 바꾸지 않는다. 렌더 숫자로 표를 덮으면 세대가 아니라 **엔진**이 섞인다.
> - 사용자가 본 화면(canonical 207 / surrogate 198 / llm 203)은 **구세대 표**다. 갱신해야 할
>   것은 표의 값이 아니라 **UI 가 서빙하는 표가 구세대라는 사실**이다 → `publish_streams.sh`
>   재발행 + 대시보드가 읽는 경로 확인.
> - 렌더 산출물의 숫자는 **데모 화면의 부속**으로만 기록한다(별도 표, 출처 명시).
>
> **검증 게이트(원안 Step 4 확장):** 360 판에서 `battery tint frames` 의 `red>0` **그리고**
> `green(courier)>0` 을 센다. `green=0` 인 판은 그 판의 정책이 SwapBattery 를 안 골랐다는
> 뜻이므로 결함이 아니다 — 스윕 실측상 **canonical 은 SwapBattery 를 0/3795 회 고른다**
> (구조적). 즉 **canonical 120 판은 green=0 이 정상**이고, surrogate·dspy 240 판에서
> green>0 이 나와야 한다. 이 기대를 미리 적어 두지 않으면 "1/3 이 실패했다" 로 오독한다.
>
> **⚠️ 심링크 파괴 위험은 원안 Step 2 그대로 유효하다** — `render_all.sh` 가 계획한 이름 중
> 하나라도 심링크면 아무것도 안 돌리고 멈춘다. 360 판이면 그 충돌 가능성이 30배다.
> **`publish_streams.sh --clean` 을 반드시 먼저** 돌린다.

<details><summary>원안 (seed 1 만, 12 판) — 참고용으로 보존</summary>

**왜:** 사용자의 원래 요구 — "SwapBattery action 은 이 demo 처럼 rendering 이 되어야 한다".
`tools/monitor/{streams,anim}/` 의 기존 녹화는 전부 배송 이전 코드의 산출물이라 그 화면이 안
나온다. **battery 가 낀 case 만** 다시 만든다(fault·zone 단독은 `_faultable` 수정만 영향).

- [ ] **Step 1: 어떤 녹화가 구세대인지 센다**

```bash
cd /home/chahj578/Construction_OODlayer/tools/monitor
GEN_TIME=$(git log -1 --format=%ct)      # 배송 커밋 시각
find anim -name '*.html' -newermt "@$GEN_TIME" | wc -l    # 새 것
find anim -name '*.html' ! -newermt "@$GEN_TIME" | wc -l  # 구세대
```

- [ ] **Step 2: 심링크 안전 확인 (⚠️ 원본 데이터 파괴 위험)**

`streams/*.jsonl` 중 다수가 밤샘 스윕 원본을 가리키는 **심링크**다. 렌더가 그 이름에 쓰면
`open(path,"w")` 가 심링크를 따라가 **원본을 0바이트로 자른다**(`README_RENDER_3D.md` §1).

```bash
ls -l streams/*.jsonl | grep '^l' | wc -l          # 심링크 개수
cd ../../wm4spacecraft_manufacturing && ./publish_streams.sh --clean
```

- [ ] **Step 3: battery 낀 case 를 재렌더한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
bash render_all.sh --dry-run --cases battery,all,fault_battery,battery_zone --jobs 8
bash render_all.sh --cases battery,all,fault_battery,battery_zone \
                   --policies canonical,surrogate,dspy --jobs 8 --force
```
Expected(§6 실측 기준): 판당 ≈150 s + 배송 정지분. 12판 × 2파도 ≈ **8분**.

- [ ] **Step 4: 화면 사건이 실제로 찍혔는지 센다**

`render_demo.jl` 이 판마다 마지막에 찍는 줄을 본다:
```bash
grep -ah 'battery tint frames' ../_night/render_logs/*.log
```
Expected: battery 가 낀 판에서 `red>0` **그리고** `green(courier)>0`.
`green=0` 인 판은 그 판의 정책이 SwapBattery 를 안 골랐다는 뜻이므로, 스트림의 `chosen` 을
확인해 그 사실을 적는다(결함이 아니다).

- [ ] **Step 5: 발행물을 다시 건다**

```bash
./publish_streams.sh
```

</details>

---

## 📌 실행 중 확정된 사실 — 이 계획서보다 **이쪽이 맞다** (2026-08-16 기록)

실행 도중 리뷰가 계획서 본문의 오류 여러 개를 실측으로 잡았다. 다음 사람이 계획서 본문을
그대로 믿지 않도록 여기 모은다. 상세 근거는 `.superpowers/sdd/2026-08-15-swapbattery-courier-resweep/progress.md`.

**계획서가 틀렸던 곳**

1. **Task 2 원안 G2 는 언제나 무증상 통과였다.** 그렙 대상 `Robot R<n> has broken down` 은
   stdout 에 **안 찍힌다**(`monitor_record_respec!`, `monitor.jl:354` 가 메모리 Dict 에만 쌓음).
   실측: 구세대 fault 샤드 90판 중 stdout **0/90**, `stream_*.jsonl` **90/90**.
   → `MONITOR_STREAM` 파일을 직접 그렙하도록 고쳤고 "고장 0건이면 실패" 가드를 넣었다.
2. **Task 5 Step 5 검증 스크립트는 정상 스윕에서도 `swap_battery 집행 = 0` 을 낸다.**
   `verification` 키가 respec 엔트리에 **한 번도 존재하지 않는다**(`run_demo.jl:622` 가
   `RESPEC_ENABLED[]=false` → `replan.jl:165` 가 기록 경로를 끊음). 구세대 3254 엔트리에
   `verification` 0회, 같은 자리에 `chosen=SwapBattery` 267회. 게다가 `respec_history` 는
   프레임마다 누적이라 순회하면 ~6배 과다계수.
   → 대체 계수법: 집행은 `rows.jsonl` 의 `decisions[].macro`(레인은 `decisions[].enacted`),
   배송 vs 폴백은 `logs/run_s*.log` 의 `[battery] swap=battery_courier_dispatched` vs
   `battery_swapped`. **`decisions[].llm` 은 제안값이라 금지.**
3. **Task 6 Step 3 의 "zone·fault 가 크게 바뀌면 `_faultable` 효과" 는 zone 에 대해 거짓이다.**
   구세대 트리는 `commit=5dd29dae` 로 **14커밋 뒤**라 배송 단독 대조군이 아니다.
   순수 `zone` case 는 세 레인 모두 SwapBattery 0회이고 `BatteryTruth` 사건이 아예 없는데도
   surrogate +33.9% · dspy +46.0% 가 나온다. **zone 축 이동은 귀속하지 않는다.**
4. **Task 6 Step 6 의 `git add` 는 어느 디렉토리에서도 실행 불가**였다(cwd 불일치로 fatal →
   아무것도 스테이징 안 됨). 게다가 `artifacts_4pol/`(26파일)와 `results_4pol/*.jsonl`(7파일)은
   **git 추적 대상**이다(`.gitignore` 가 `!*.jsonl` 로 되살림) — 브리프의 3경로만 커밋하면
   새 세대 표와 **구세대 원자료**가 한 커밋에 섞인다.
5. **Task 7 스크립트의 `truth_type` 키는 존재하지 않는다.** 실제 키는 `truth`(값 `BatteryTruth`).
6. **Task 4 기준값 추출이 정책 불일치다.** `_night/status_shards.jsonl` 840행은 두 모집단
   (3정책 210행 + **dp 1정책** 630행)이고 "마지막 값이 남는다" 가 하필 **이번에 제외한 dp 레인**
   값을 집는다. 정정 증가율 **1.63배**(1.55 아님), 전체 스윕 **1.36배**, 실측 소요 **1h47m**.
7. **Task 3 Step 1 의 `ls results_4pol/shards/*/ -d | wc -l` 은 210 이 아니라 7 을 낸다**
   (case 디렉토리를 센다). 210 은 `ls -d shards/*/s*`.
8. **Task 5 Step 4 의 `grep -c '"status":"ok"' _night/status_shards.jsonl` 은 210 이 아니라
   1050 을 낸다** — 그 파일은 5세대에 걸친 append-only 원장이다.

**실행 결과 (확정 수치)**

- 스윕: **210/210 샤드 ok · fail 0 · deadline 0**, 630행, 1h47m, 전 샤드 `commit=ec8cf495`.
- 배송: **277 dispatched · 폴백 0** (구세대 dispatched 0 · 폴백 267). 레인 `surrogate 165 ·
  dspy 112 · **canonical 0**`. canonical 이 SwapBattery 를 안 고르는 것은 **구조적**이다
  (매크로 히스토그램 `Replace 561 / ReformTeam 693 / NOOP 279`, 0/3795).
- **헤드라인 귀속은 "정책 고정 · case 간 용량-반응"** 이다(레인 간 비교는 zone 반례로 무효):
  surrogate `fault`(배송 0회) −0.8% → `fault_battery`(33회) +26.3% → `battery`(74회) +54.9%;
  dspy −2.2% → +15.0% → +32.6%. **`battery_zone`·`all` 은 교란되어 배송 크기로 인용 금지.**
- **정지 두 지표를 섞지 말 것**: `battery_physics.n_stalled>0` = **신 7 / 구 0**(전부 battery
  낀 case, 두 세대 설정 동일) vs `status=="stall"` = 26 / 22. 7 은 26 의 **진부분집합**.
- surrogate 라벨: **낡았다**. 단 **−8.3pp 는 결정가중 아티팩트라 발행 금지** — 보드 단위로는
  1.8pp 이고 surrogate 120판 중 **52판이 두 팔을 모두 쓴다**. 유효한 근거는 makespan 쪽의
  **case 층화 용량-반응**(0회 +0.00 → 1회 +3.90 → 2회 +6.45 → 3회+ +9.13초, canonical 동일
  시드 기준). dspy 는 makespan 만 복제되고 완주율 격차는 보드 단위로 0.0pp 다.
- 발행 표의 **세대 누수 2건**을 닫았다(`build_compare_table.py`): §8.7 gap 각주가 새 행을
  `aff13715` 세대 `value.json` 과 재계산하던 것(`1bfbcaf8`), 그리고 **숫자가 없어서 grep 을
  통과하던** "이 표의 DP 는 진짜 Bellman backward induction 이다" 주장(`7eddb629`).
  → 교훈: **세대 누수는 숫자가 없어도 누수다.**

---

## Task 9: CLAUDE.md 에 세대 항목을 추가한다

**Files:**
- Modify: `.claude/CLAUDE.md` (§★ 결과 세대 맨 위)

- [ ] **Step 1: 새 절을 맨 위에 넣는다**

기존 "✅ 2026-08-17 — 표집을 1-step deviation 으로 바꿨다 (현행 세대)" **위**에 삽입하고,
그 절의 "현행 세대" 표식을 **직전 세대**로 내린다(이 파일에 "현행 세대" 표식이 둘이 되어
자기모순이 났던 이력이 있다 — 2026-08-17 절의 정정 문구 참조).

담을 것:
- 무엇이 세대를 갈랐나: SwapBattery 물리 배송 + `_faultable` 고장 피커 수정
- 구세대 재현: `DEMO_BATTERY_COURIER=0`
- `objective_hash` 는 **안 바뀐다**(`19819377a7f8ebb2`) — 동역학이 바뀐 것이지 목적함수가
  아니다. 이 구분을 명시하지 않으면 다음 사람이 해시를 올려 라벨셋을 통째로 구세대로 만든다.
- 결과 문서 = `md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md`
- **dp 열이 빠진 이유**와 되살리는 법(`dp_oracle/sample_grid.py` 재표집, 4~5h)
- surrogate 라벨 stale 판정(Task 7 결과)
- 신규 계약: `gate_courier_sweep.sh`(4/4), `measure_swap_staleness.py`
- 알려진 한계: 런 간 재현성 결함 — `_pick_active_robot` 이 `cache.active_set`(Set) 을
  **순회 순서 미정의**로 돈다는 유력 후보를 함께 적는다

- [ ] **Step 2: 커밋**

```bash
git add .claude/CLAUDE.md
git commit -m "docs(claude): SwapBattery 배송 세대를 현행으로 올린다

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## 총 비용 추정

| Task | 벽시계 | 비고 |
|---|---:|---|
| 1 커밋 + 테스트 | 10분 | `Pkg.test()` 가 대부분 |
| 2 게이트 작성·통과 | 20분 | G1/G2 가 판 2개를 돈다 |
| 3 구세대 보존 | 2분 | mv 뿐 |
| 4 비용 프로브 | 30분 | 6샤드 순차 |
| 5 재스윕 | **62~95분** | K=16, 210샤드. 프로브 결과로 확정 |
| 6 표 + 결과 문서 | 40분 | 문서 작성이 대부분 |
| 7 stale 측정 | 15분 | |
| 8 데모 재렌더 | 15분 | 12판, K=8 |
| 9 CLAUDE.md | 15분 | |
| **합** | **약 3.5~4시간** | Task 5 는 무인 |

---

## 실행 전에 사람이 답해야 할 것

1. **Task 1 Step 1** — 작업 트리의 무관한 미커밋 변경(`essential_tg_coponents.jl`,
   `monitor.jl`, `dashboard.html`, py 파일 8개 삭제)은 무엇인가? 같이 커밋할 것인가?
2. **dp 열을 정말 빼도 되는가?** 발표/논문 표에서 4열이 3열이 된다. 유지하려면
   `dp_oracle` 재표집 4~5시간을 이 계획에 Task 5.5 로 추가해야 한다.
3. **seed 30개 전부인가?** 프로브 결과가 3배를 넘으면 seed 1~15 로 줄이는 선택지가 있다
   (통계력은 떨어지지만 세대는 갈린다).
