# 창고 거리 D=20 전환 + 전면 재생성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 예비 로봇 창고의 절대 거리를 D=40 에서 **D=20** 으로 내리고, 그 기하에서 대시보드 녹화본 8종·오라클 격자·평가 런 42개·결과 행렬·기준 정책을 **전부 다시 만들어** 코드·표·화면이 한 세계가 되게 한다.

**Architecture:** 코드 변경은 상수 3개뿐이다(D 기본값). 나머지는 전부 **데이터 재생성**이다. 순서가 곧 설계다 — ① D 상수 변경 → ② 오라클 격자(기준 정책의 근거) → ③ 평가 런 42개 → ④ 기준 정책 재유도 → ⑤ 표·문서 → ⑥ UI 녹화본 8종. 기존 D=40 산출물은 **덮어쓰지 않고** 파일명으로 세대를 분리해 보존한다.

**Tech Stack:** Julia 1.10 (LTS), MeshCat, RVO2 via PyCall, Python 3.10 (numpy/scikit-learn), DSPy 3.2.1 (venv `hjcrl`), 브라우저 대시보드(순수 JS).

**선행 작업:** `docs/superpowers/plans/2026-08-12-far-depots-and-metric-matrix.md` (완료, 커밋 `4bfbeab..c7b78bd`). 이 계획은 그 결과물의 D 값만 바꿔 재측정한다.

## Global Constraints

- Julia 는 반드시 **`julia +lts`** (1.10). `Manifest.toml` 이 1.10.11 에 고정돼 있고 상위 버전에서 `Pkg.add` 하면 빌드가 조용히 깨진다. 모든 호출에 `--project=.` 를 붙인다.
- **런은 절대 병렬로 돌리지 않는다.** `run_lego_demo` 는 HiGHS MILP 로 스케줄을 푸는데 CPU 경합이 다르면 다른 해가 나온다. 병렬 실행은 정책 비교가 아니라 서로 다른 두 세계의 비교가 된다(프로세스당 ~2.5GB, OOM 위험).
- **긴 런을 `| head` 나 `| grep -m` 으로 파이프하지 않는다.** 파이프가 닫히면 SIGPIPE 로 Julia 가 죽는다(2026-08-12 실제로 오라클 격자를 이렇게 날렸다). 로그는 `> file 2>&1` 로 받고 나중에 읽는다.
- **DSPy 서비스가 떠 있어야 한다.** 꺼져 있으면 `policy.jl` 이 **에러 없이** canonical 로 폴백하는데 요약 행의 `"policy"` 는 그대로 `"dspy"` 로 남는다 → surrogate/LLM 열이 조용히 canonical 복제본이 된다. 매 평가 런에 `--dspy-url` 을 **명시**하고, 끝나고 `decisions[].enacted` 를 감사한다.
- 행동 어휘(`wm4spacecraft_manufacturing/action_registry.json`)를 **변경하지 않는다.** 매크로 추가·수정 없음, 리터럴 복붙 금지.
- 기대 기준선(실패 아님): `julia +lts --project=. -e 'using Pkg; Pkg.test()'` = **11 pass / 1 error**(Gurobi 라이선스 없음, 이 작업과 무관).
- 런타임 `include` 로 로드되는 navigator/battery 모듈 관련 코드는 **모듈 최상위**에 둔다(world-age 에러 방지).
- 새로 생성하는 모든 런 요약·라벨 레코드는 `geometry = {depot_mode, depot_distance, station_keeping}` 를 가지며, 이 계획의 산출물은 전부 `depot_distance == 20.0` 이어야 한다. `results_matrix.py` 가 세대가 섞이면 표 생성을 거부한다.
- **기존 D=40 산출물을 덮어쓰지 않는다.** 새 파일명(`*_d20`)을 쓴다. 재생성이 끝나기 전에는 어느 쪽 수치도 "현재 성능"으로 인용하지 않는다.
- 모든 검증 단계는 **실행한 명령과 그 결과를 그대로 보고**한다("passed" / "failed with X" / "not run because Y").

## 시작 전 정리 — 이전 세션이 띄워둔 프로세스

이 계획을 시작하기 전에 아래를 **반드시** 확인한다. 2026-08-12 세션이 백그라운드 프로세스를 남겨두었다.

```bash
tasklist | grep -i julia          # 라이브 데모 런이 남아 있을 수 있다
curl -s --max-time 3 http://127.0.0.1:8080/ >/dev/null && echo "monitor server UP"
curl -s --max-time 3 http://127.0.0.1:8077/health
```

- **모니터 서버(:8080)** 와 **라이브 데모 런**이 떠 있으면 **끈다.** 서버의 `POST /run` 은 `MONITOR_STREAM` 파일을 **열면서 0바이트로 잘라낸다** — UI 에서 케이스 버튼을 누르면 그 케이스의 녹화본이 그 자리에서 파괴된다(실측: `tractor__zone.jsonl` 이 0바이트가 됐다). 재생성 중에 UI 를 열어두면 안 된다.
- **DSPy 서비스(:8077)** 는 **켜둔 채로 둔다.** 꺼져 있으면 Task 3 시작 전에 띄운다(Task 3 Step 1).

## 알려진 리스크 — Task 4 에서 판정한다

D=40 격자에서 유도한 현재 기준 정책은 다음과 같다(`wm4spacecraft_manufacturing/reference_policy.py`).

- `BATTERY_DEEP_SOC = 0.3`, 깊은 방전이면 `SwapBattery`.
- 그 근거는 **완주**였다: D=40 에서 `Replace` 가 아예 완주하지 못했다(makespan `Inf`).

**D=20 에서는 이 근거가 무너질 수 있다.** 창고가 가까워지면 `Replace` 의 주행 비용이 줄어 다시 완주할 가능성이 있고, 그러면 근거가 "완주"에서 "둘 다 완주하니 더 싼 쪽"으로 되돌아간다. 임계값 0.3 도 사다리(0.02/0.30/0.50)에서 다시 갈릴 수 있다.

**규칙을 손으로 정하지 않는다.** Task 2 에서 D=20 격자를 만들고 Task 4 에서 그 격자로 재유도해 판정한다. 그 전에는 `reference_policy.py` 를 건드리지 않는다.

## 파일 구조

| 파일 | 역할 | 이 계획에서의 변경 |
|---|---|---|
| `src/respec/ood_injection.jl:569` | 창고 거리 기본값 | `Ref(40.0)` → `Ref(20.0)` |
| `tools/demos.jl:1575`, `:2754` | 데모 드라이버 knob 기본값 | `"40.0"` → `"20.0"` |
| `wm4spacecraft_manufacturing/reference_policy.py` | 기준 행동 a* | 임계값·BASIS 를 D=20 격자로 재유도 |
| `tools/regen_d20.sh` | **신규** | 재생성 드라이버 3종(오라클·행렬·UI)을 저장소 안에 둔다 |
| `wm4spacecraft_manufacturing/oracle/out/n44_plus78_d20.jsonl` | **신규** | D=20 오라클 격자 |
| `wm4spacecraft_manufacturing/results/matrix_d20.jsonl/.csv/.md` | **신규** | D=20 평가 런 + 결과 행렬 |
| `wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md` | **신규** | D=20 결과 문서 |
| `wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md` | 이전 세대 문서 | 🔴 세대 배너 추가 |
| `.claude/CLAUDE.md` | 결과 세대 안내 | 현행 문서를 D20 으로 갱신 |

**드라이버를 저장소 안에 두는 이유:** 지난 세션의 드라이버는 `.superpowers/sdd/…/run_*.sh` 에 있었는데 그 디렉터리는 **git-ignored** 라 재현이 불가능했다. 이번에는 `tools/regen_d20.sh` 로 커밋한다.

---

### Task 1: D 기본값을 20 으로 내린다

**Files:**
- Modify: `src/respec/ood_injection.jl:569`
- Modify: `tools/demos.jl:1575`, `tools/demos.jl:2754`
- Test: `tools/checks.jl` (기존 `depot_geometry`, `station_keeping` 재실행)

**Interfaces:**
- Produces: `spare_depot_distance() == 20.0` 이 프로세스 기본값. `llm_ood_eval.py` 는 `SPARE_DEPOT_DIST` 를 **전달하지 않으므로**, 평가 런의 기하는 오직 이 기본값이 정한다. 세 곳이 어긋나면 드라이버마다 다른 세계가 된다.

- [ ] **Step 1: 세 곳을 20.0 으로 바꾼다**

`src/respec/ood_injection.jl:569` 를 교체한다.

```julia
const SPARE_DEPOT_DISTANCE = Ref(20.0)
```

`tools/demos.jl:1575` 를 교체한다.

```julia
SPARE_DEPOT_D = parse(Float64, get(ENV, "SPARE_DEPOT_DIST", "20.0"))  # 원점에서 창고까지 절대 거리  # 창고를 빌드에서 얼마나 멀리
```

`tools/demos.jl:2754` 를 교체한다.

```julia
CB.set_spare_depot_distance!(parse(Float64, get(ENV, "SPARE_DEPOT_DIST", "20.0")))
```

- [ ] **Step 2: 세 곳이 전부 20 인지 기계적으로 확인한다**

Run:
```bash
grep -rn 'SPARE_DEPOT_DIST\|SPARE_DEPOT_DISTANCE' src/ tools/ | grep -v '\.md'
```
Expected: `ood_injection.jl` 에 `Ref(20.0)`, `demos.jl` 두 줄에 `"20.0"`. `run_demo.jl` 은 env 가 있을 때만 덮어쓰는 코드라 리터럴 기본값이 없다(정상).

- [ ] **Step 3: 클리어런스 경고가 D=20 에서 어떻게 나오는지 확인한다**

D=20 은 빌드 footprint 반경(≈13)의 1.2배(=15.6)보다는 크지만 여유가 크지 않다. 경고가 뜨는지 **확인만** 하고, 뜨더라도 자동 조정하지 않는다(절대좌표 고정이라는 선택을 코드가 뒤집으면 안 된다).

Run: `julia +lts --project=. tools/checks.jl depot_geometry`
Expected: `depot geometry check: 13 PASS / 0 FAIL`
(이 점검은 자체적으로 `set_spare_depot_distance!(30.0)` 을 호출하므로 기본값과 무관하게 통과해야 한다.)

- [ ] **Step 4: 정박 점검도 통과하는지 확인한다**

Run: `julia +lts --project=. tools/checks.jl station_keeping`
Expected: `station-keeping check: 8 PASS / 0 FAIL`

- [ ] **Step 5: 커밋**

```bash
git add src/respec/ood_injection.jl tools/demos.jl
git commit -m "chore(depot): 기본 창고 거리를 40 에서 20 으로 내린다"
```

---

### Task 2: D=20 오라클 격자 재생성

**Files:**
- Create: `tools/regen_d20.sh`
- Create: `wm4spacecraft_manufacturing/oracle/out/n44_plus78_d20.jsonl` (생성물)

**Interfaces:**
- Consumes: Task 1 의 D=20 기본값
- Produces: 오라클 라벨 jsonl. 레코드는 `kind`, `severity`, `macro_name`, `complete`, `makespan`, `closed`, `total`, `min_soc`, `mean_soc`, `total_energy_J`, `energy_per_closed`, `n_depleted`, `geometry` 를 갖는다. Task 4 의 기준 정책 재유도와 Task 5 의 ORACLE 열이 이 파일을 읽는다.

- [ ] **Step 1: 재생성 드라이버를 저장소 안에 만든다**

Create `tools/regen_d20.sh`:

```bash
#!/usr/bin/env bash
# tools/regen_d20.sh -- D=20 기하로 오라클 격자 / 평가 행렬 / UI 녹화본을 재생성한다.
#
# 왜 저장소 안에 두는가: 이전 세대의 드라이버는 .superpowers/sdd/ 아래(=git-ignored)에 있어
# 재현이 불가능했다. 재현 명령은 결과 문서가 가리킬 수 있는 곳에 있어야 한다.
#
# 사용법:
#   bash tools/regen_d20.sh oracle              # 오라클 격자 (~15분)
#   bash tools/regen_d20.sh matrix <seed>       # 평가 런 7케이스 x 3정책 x 시드 1개 (~95분)
#   bash tools/regen_d20.sh ui                  # 대시보드 녹화본 8종 (~25분)
#
# 전부 순차 실행이다. 동시에 두 개를 돌리면 HiGHS 가 다른 스케줄을 내 비교가 무효가 된다.
set -u
cd "$(dirname "$0")/.." || exit 2
MODE="${1:?usage: regen_d20.sh oracle|matrix <seed>|ui}"
DSPY="${DSPY_URL:-http://127.0.0.1:8077}"

case "$MODE" in
  oracle)
    cd wm4spacecraft_manufacturing/oracle || exit 2
    OUT="${2:-out/n44_plus78_d20.jsonl}"
    echo "=== oracle grid start $(date +%H:%M:%S) -> $OUT ==="
    DS_KINDS=battery,fault,zone DS_SEEDS=1 DS_SPARES=3 DS_VALID_ONLY=1 DS_RESUME=1 \
    DS_OUT="$OUT" julia +lts --project=../.. gen_oracle_dataset.jl
    echo "=== oracle grid done rc=$? $(date +%H:%M:%S) rows=$(wc -l < "$OUT" 2>/dev/null || echo 0) ==="
    ;;
  matrix)
    SEED="${2:?usage: regen_d20.sh matrix <seed>}"
    OUT="${3:-results/matrix_d20.jsonl}"
    cd wm4spacecraft_manufacturing || exit 2
    if ! curl -s --max-time 5 "$DSPY/health" > /dev/null; then
      echo "ABORT  DSPy service down at $DSPY -- surrogate/dspy would silently fall back to canonical"
      echo "       while the summary row still says policy=dspy. Refusing to generate a corrupt column."
      exit 3
    fi
    for CASE in battery fault zone fault_battery fault_zone battery_zone all; do
      start=$SECONDS
      echo "=== seed=$SEED case=$CASE $(date +%H:%M:%S) ==="
      python llm_ood_eval.py run --case "$CASE" --seeds "$SEED" \
          --policies canonical,surrogate,dspy --dspy-url "$DSPY" --out "$OUT"
      echo "--- seed=$SEED case=$CASE rc=$? in $((SECONDS-start))s ; rows now: $(wc -l < "$OUT" 2>/dev/null || echo 0)"
    done
    echo "ALL DONE seed=$SEED $(date +%H:%M:%S)"
    ;;
  ui)
    # 대시보드 케이스 키 8종 전부(dashboard.html:797-806). 기본 3종만 도는 스크립트에
    # 인자로 넘겨서 전부 렌더한다.
    DSPY_URL="$DSPY" bash tools/monitor/regen_router_cases.sh \
        none battery fault zone fault_battery fault_zone battery_zone battery_mild
    ;;
  *) echo "unknown mode: $MODE"; exit 2 ;;
esac
```

- [ ] **Step 2: DSPy 서비스가 떠 있는지 확인한다 (뒤 Task 가 의존한다)**

Run:
```bash
curl -s --max-time 5 http://127.0.0.1:8077/health
```
Expected: `{"status":"ok","policy":"dspy:gpt-4o",...,"surrogate":"n44_plus78.jsonl (68 instances, macro support [0, 1, 2, 3, 4, 7, 8])",...}`

떠 있지 않으면 띄운다(`OPENAI_API_KEY` 가 환경에 있어야 한다):
```bash
cd src/respec/llm_service
DSPY_PROGRAM=__seed_only__ /c/Users/chahj/PythonCodes/venv/hjcrl/Scripts/python.exe \
    -m uvicorn dspy_service:app --host 127.0.0.1 --port 8077
```
`DSPY_PROGRAM=__seed_only__` 가 **필수**다. 컴파일된 `dspy_real_program_gpt4o.json` 은 battery 전용이라 zone·RelocateBuild 어휘가 없다 — 그걸로 zone 을 재면 어휘 밖 사건을 재는 것이 된다.

- [ ] **Step 3: 오라클 격자를 돌린다 (~15분, 순차)**

Run:
```bash
bash tools/regen_d20.sh oracle > /tmp/oracle_d20.log 2>&1
```
로그를 파이프로 자르지 말 것(SIGPIPE 로 죽는다). 끝난 뒤 `tail -5 /tmp/oracle_d20.log` 로 확인한다.

Expected: `=== oracle grid done rc=0 ... rows=13 ===` (행 수는 zone 팔 개수에 따라 12~14 사이일 수 있다)

- [ ] **Step 4: 기하가 전부 20 인지 확인한다**

Run:
```bash
python -c "
import json, collections
p='wm4spacecraft_manufacturing/oracle/out/n44_plus78_d20.jsonl'
rows=[json.loads(l) for l in open(p,encoding='utf-8')]
print('rows =', len(rows))
print(collections.Counter(json.dumps(r.get('geometry'),sort_keys=True) for r in rows))
"
```
Expected: 단 하나의 키 `{"depot_distance": 20.0, "depot_mode": "fixed", "station_keeping": true}`.
20.0 이 아니면 **Task 1 이 반영되지 않은 것이다** — 여기서 멈추고 Task 1 을 다시 확인한다.

- [ ] **Step 5: 커밋**

```bash
git add tools/regen_d20.sh wm4spacecraft_manufacturing/oracle/out/n44_plus78_d20.jsonl
git commit -m "data(oracle): D=20 기하로 오라클 격자 재생성 + 재생성 드라이버를 저장소로"
```

---

### Task 3: D=20 평가 런 42개 (7케이스 × 3정책 × 시드 2개)

**Files:**
- Create: `wm4spacecraft_manufacturing/results/matrix_d20.jsonl` (생성물)

**Interfaces:**
- Consumes: Task 1 의 D=20 기본값, Task 2 의 `tools/regen_d20.sh`
- Produces: 런 요약 jsonl. 레코드는 `case`, `policy`, `complete`, `sim_seconds`, `battery.{energy_per_closed,min_soc}`, `decisions[]`, `geometry` 를 갖는다. Task 5 의 표가 이 파일을 읽는다.

**시드를 나눠 도는 이유:** 한 시드가 7케이스 전부를 채우고 끝나므로, 중간에 끊겨도 모든 칸이 n=1 로 채워진다. 시드별로 도는 대신 케이스별로 두 시드를 몰아 돌면 앞 케이스만 n=2 이고 뒤 케이스는 비게 된다.

- [ ] **Step 1: 시드 1 을 돌린다 (~95분, 순차)**

Run:
```bash
bash tools/regen_d20.sh matrix 1 > /tmp/matrix_d20_s1.log 2>&1
```

Expected: 마지막 줄 `ALL DONE seed=1`. 중간에 `ABORT DSPy service down` 이 나오면 서비스를 띄우고 다시 시작한다(파일은 append 이므로 이미 끝난 케이스는 남아 있다 — 중복이 생기면 Step 4 에서 잡힌다).

- [ ] **Step 2: 시드 2 를 돌린다 (~95분, 순차)**

Run:
```bash
bash tools/regen_d20.sh matrix 2 > /tmp/matrix_d20_s2.log 2>&1
```

Expected: 마지막 줄 `ALL DONE seed=2`.

- [ ] **Step 3: 폴백 감사 — surrogate/LLM 열이 진짜인지 증명한다**

이 단계를 건너뛰면 세 열이 사실은 같은 열일 수 있다. `policy.jl` 은 서비스가 죽어도 에러를 내지 않는다.

Run:
```bash
python - <<'PY'
import collections, json
rows=[json.loads(l) for l in open('wm4spacecraft_manufacturing/results/matrix_d20.jsonl',encoding='utf-8')]
bad=[]
tally=collections.defaultdict(collections.Counter)
for r in rows:
    for d in (r.get('decisions') or []):
        tally[(r['case'], r['policy'])][str(d.get('enacted'))] += 1
for (case,pol),c in sorted(tally.items()):
    print('%-14s %-10s %s' % (case, pol, dict(c)))
    if pol in ('surrogate','dspy') and not c.get(pol):
        bad.append((case,pol,dict(c)))
print()
print('FAIL' if bad else 'PASS', bad if bad else '- every surrogate/dspy group enacted its own producer')
PY
```
Expected: 마지막 줄이 `PASS`. `FAIL` 이면 그 칸은 canonical 복제본이므로 서비스를 띄우고 그 케이스를 다시 돌린다.

- [ ] **Step 4: 행 수·기하·셀당 n 을 확인한다**

Run:
```bash
python - <<'PY'
import collections, json
rows=[json.loads(l) for l in open('wm4spacecraft_manufacturing/results/matrix_d20.jsonl',encoding='utf-8')]
print('rows =', len(rows))
print('geometry:', collections.Counter(json.dumps(r.get('geometry'),sort_keys=True) for r in rows))
c=collections.Counter((r['case'], r['policy']) for r in rows)
print('cells =', len(c), '| n 분포 =', collections.Counter(c.values()))
print('seeds =', sorted(set(r.get('ood_seed') for r in rows)))
PY
```
Expected: `rows = 42`, geometry 는 `depot_distance 20.0` 하나, `cells = 21`, n 분포 `{2: 21}`, `seeds = [1, 2]`.
셀 수가 21 이 아니거나 n 이 2 를 넘으면 중복 실행이 있었다는 뜻이다 — 그 케이스의 여분 행을 지우고 다시 확인한다.

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/results/matrix_d20.jsonl
git commit -m "data(eval): D=20 기하로 7케이스 x 3정책 x 2시드 평가 런 42개"
```

---

### Task 4: D=20 격자로 기준 정책 재유도

**Files:**
- Modify: `wm4spacecraft_manufacturing/reference_policy.py` (임계값 `BATTERY_DEEP_SOC`, `BASIS` 3개 문자열)

**Interfaces:**
- Consumes: Task 2 의 `oracle/out/n44_plus78_d20.jsonl`
- Produces: `reference_action(ev) -> (a_star, basis_key, note)` 의 새 판정 기준. Task 5 의 "결정 적중률" 열 전체가 이 함수로 채점된다.

**이 단계를 표보다 먼저 끝내는 이유:** 낡은 기준으로 채점하면 적중률 열 전체가 옛 진실을 재는 숫자가 된다.

- [ ] **Step 1: 격자에서 팔별 결과를 뽑는다**

Run:
```bash
python - <<'PY'
import collections, json
def num(x):
    if isinstance(x,bool) or x is None: return None
    try: v=float(x)
    except (TypeError,ValueError): return None
    return v if v==v and v not in (float('inf'), float('-inf')) else None
p='wm4spacecraft_manufacturing/oracle/out/n44_plus78_d20.jsonl'
rows=[json.loads(l) for l in open(p,encoding='utf-8')]
agg=collections.defaultdict(list)
for r in rows: agg[(r.get('kind'), r.get('severity'), r.get('macro_name'))].append(r)
print('%-9s %-9s %-14s %-4s %-9s %-10s %-11s %s' % ('kind','sev','macro','n','complete','makespan','J/closed','closed'))
for k in sorted(agg, key=lambda t:(str(t[0]),str(t[1]),str(t[2]))):
    v=agg[k]; nc=sum(1 for r in v if r.get('complete'))
    ms=[num(r.get('makespan')) for r in v if r.get('complete')]; ms=[m for m in ms if m is not None]
    en=[num(r.get('energy_per_closed')) for r in v if r.get('complete')]; en=[e for e in en if e is not None]
    cl=[r.get('closed') for r in v]
    print('%-9s %-9s %-14s %-4d %-9s %-10s %-11s %s' % (k[0],k[1],k[2],len(v),'%d/%d'%(nc,len(v)),
          round(sum(ms)/len(ms),1) if ms else '-', round(sum(en)/len(en),1) if en else '-', cl))
PY
```

- [ ] **Step 2: 배터리 규칙을 판정한다**

Step 1 표의 `kind=battery` 행을 사다리(severity 0.02 / 0.30 / 0.50) 순서로 본다. 아래 규칙 그대로 판정한다.

> 각 severity 칸에서 **완주하는 팔**을 먼저 본다.
> - 완주하는 팔이 하나뿐이면 그 팔이 정답이다.
> - 여러 팔이 완주하면 **makespan 이 짧은 쪽**, 그것도 같으면 **J/closed 가 작은 쪽**이 정답이다.
>
> 그렇게 각 severity 의 정답을 정한 뒤, `SwapBattery` 가 정답인 가장 높은 severity 를 `BATTERY_DEEP_SOC` 로 둔다.
> (예: 0.02·0.30 이 `SwapBattery`, 0.50 이 `NOOP` 이면 임계값은 0.3. 0.02 만 `SwapBattery` 이면 0.02.)

`wm4spacecraft_manufacturing/reference_policy.py:45` 의 `BATTERY_DEEP_SOC` 를 그 값으로 바꾸고, 같은 줄 주석의 근거 문구도 갱신한다. 파일 상단 docstring 의 배터리 서술과 `BASIS["battery"]` 문자열을 **새 격자 파일명(`n44_plus78_d20.jsonl`)·시드·인스턴스 수**로 갱신한다.

**중요:** D=40 격자에서는 `Replace` 가 아예 완주하지 못해 근거가 "완주"였다. D=20 에서 `Replace` 가 다시 완주하면 근거는 "둘 다 완주하니 더 싼 쪽"으로 **되돌아간다** — 그 경우 docstring 과 BASIS 에서 "완주로 갈린다"는 서술을 지우고 비용 근거로 다시 쓴다. 옛 서술을 남겨두면 코드와 문서가 반대말을 하게 된다(D=40 작업에서 실제로 이 실수가 났다).

- [ ] **Step 3: fault·zone 규칙을 확인한다**

Step 1 표의 `kind=fault` 와 `kind=zone` 행을 본다.

- `fault`: 완주하는 팔이 있으면 그 팔이 정답인지 보고, 현재 규칙(`agent_pending > 0 → Replace`)과 어긋나면 규칙과 `BASIS["fault"]` 를 갱신한다. **어느 팔도 완주하지 못하면 재유도가 불가능하다** — 규칙을 그대로 두되 `BASIS["fault"]` 에 "이 격자에서는 어느 팔도 완주하지 못해 재유도하지 못했다. `closed` 는 NOOP x / Replace y 로 방향만 일치한다" 처럼 **재검증되지 않았다는 사실을 적는다.** 재측정되지 않은 근거를 계속 주장하게 두지 않는다.
- `zone`: 현재 규칙은 `n_nav_blocked > 0 && root_covered == 0 → RelocateBuild` 다. 두 팔이 완주·makespan 까지 같으면 이 격자는 규칙을 **시험하지 않은 것**이므로, 규칙은 유지하고 `BASIS["zone"]` 에 동점이었다고 적는다. 평가 런 쪽 근거(Task 3 결과의 zone 행)를 대신 인용한다.

- [ ] **Step 4: 채점이 도는지 확인한다**

Run:
```bash
cd wm4spacecraft_manufacturing
python -c "
import json, sys
sys.path.insert(0,'.')
import reference_policy as rp
rows=[json.loads(l) for l in open('results/matrix_d20.jsonl',encoding='utf-8')]
print('%-14s %-10s %-7s %-7s %s'%('case','policy','scored','correct','acc'))
for r in rows:
    s,c,_ = rp.score(r.get('decisions') or [])
    print('%-14s %-10s %-7d %-7d %s'%(r['case'], r['policy'], s, c, ('%.0f%%'%(100*c/s)) if s else '-'))
"
```
Expected: 42행이 예외 없이 출력된다. `scored` 가 전부 0 이면 규칙이 결정 레코드의 필드명과 어긋난 것이다.

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/reference_policy.py
git commit -m "docs(eval): D=20 격자로 기준 정책 재유도"
```

---

### Task 5: D=20 결과 행렬과 결과 문서

**Files:**
- Create: `wm4spacecraft_manufacturing/results/matrix_d20.csv`, `matrix_d20.md` (생성물)
- Create: `wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md`
- Modify: `wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md` (세대 배너)
- Modify: `.claude/CLAUDE.md` (현행 결과 문서 갱신)

**Interfaces:**
- Consumes: Task 3 의 `results/matrix_d20.jsonl`, Task 2 의 `oracle/out/n44_plus78_d20.jsonl`, Task 4 의 `reference_policy`

- [ ] **Step 1: 표를 생성한다**

Run:
```bash
cd wm4spacecraft_manufacturing
python results_matrix.py --runs results/matrix_d20.jsonl \
    --oracle oracle/out/n44_plus78_d20.jsonl --out results/matrix_d20
cat results/matrix_d20.md
```

Expected: `wrote results/matrix_d20.csv and results/matrix_d20.md` 이후 7행 × 4열 표. 조합 케이스 4행의 ORACLE 칸은 `—`, 나머지 칸은 전부 `k/n` 을 포함한다. 기하 세대 줄이 `depot_distance": 20.0` 으로 찍힌다.

`ERROR ... 서로 다른 기하 세대가 섞여 있다` 가 뜨면 두 입력 중 하나에 D=40 레코드가 섞인 것이다 — 섞인 파일을 찾아 지우고 그 부분만 다시 만든다. **표를 억지로 만들지 않는다.**

- [ ] **Step 2: D=40 과 무엇이 달라졌는지 비교한다**

Run:
```bash
cd wm4spacecraft_manufacturing
diff <(sed -n '/^| FAILURE/,$p' results/matrix_fardepot.md) \
     <(sed -n '/^| FAILURE/,$p' results/matrix_d20.md) && echo "표 동일" || echo "위가 D=40, 아래가 D=20"
```

D=25 와 D=40 이 완전히 동일했던 선행 실측이 있으므로 D=20 도 같을 가능성이 높다. **같으면 그것 자체가 결과다** — "창고 거리는 이 지표들에 영향이 없다"는 근거가 세 점(20/25/40)으로 늘어난다. 다르면 어느 칸이 왜 달라졌는지 Step 3 문서에 적는다.

- [ ] **Step 3: 결과 문서를 쓴다**

`wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md` 를 한국어로 쓴다(같은 폴더의 기존 문서 톤을 먼저 읽고 맞춘다). 담을 것:

- Step 1 의 표 그대로
- 기하 세대: `depot_mode=fixed, depot_distance=20.0, station_keeping=true`, 그리고 D 를 40 → 20 으로 내린 이유(UI 에서 창고가 지나치게 멀어 보인다는 판단)
- 재현 명령: `bash tools/regen_d20.sh oracle` / `matrix 1` / `matrix 2` / `ui`, 그리고 DSPy 서비스 기동 명령
- Task 4 의 판정 3건(배터리·fault·zone)과 각각의 근거, 특히 D=40 대비 **바뀐 것이 있으면 무엇이 왜 바뀌었는지**
- Step 2 의 D=40 대비 차이(같으면 "동일"이라고 적는다)
- **한계 절(묻어두지 말 것):** 셀당 n=2 이므로 CSV 의 Wilson 구간을 좁게 제시하지 말 것 · 오라클 격자는 1시드 · Task 4 에서 재유도하지 못한 규칙이 있으면 무엇인지 · **surrogate 는 D=20 라벨로 재학습하지 않았다**(배포 모델은 `wm_datasets.N44_PLUS78` = 근거리 라벨 기준이고, 작은 새 격자로 갈아끼우면 `test_surrogate_support.py` 의 매크로 커버리지 계약이 깨진다). 즉 SURROGATE 열은 기존 배포 모델을 새 기하에서 평가한 값이다.
- 폴백 감사 결과(Task 3 Step 3 의 `PASS`)

- [ ] **Step 4: 낡은 문서에 배너를 단다**

`wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md` 맨 위에 한 줄을 넣는다.

```markdown
> 🔴 **구세대(D=40) 측정치.** 현재 성능은 `RESULTS_D20_2026-08-12.md` 를 볼 것.
```

`.claude/CLAUDE.md` 의 "★ 결과 세대" 절에서 현행 측정 문서를 `RESULTS_D20_2026-08-12.md` 로 갱신한다(기존 경고 문구는 유지, 문서 이름과 D 값만 갱신).

- [ ] **Step 5: 커밋**

```bash
git add wm4spacecraft_manufacturing/results/matrix_d20.csv \
        wm4spacecraft_manufacturing/results/matrix_d20.md \
        wm4spacecraft_manufacturing/md/RESULTS_D20_2026-08-12.md \
        wm4spacecraft_manufacturing/md/RESULTS_FARDEPOT_2026-08-12.md \
        .claude/CLAUDE.md
git commit -m "docs(eval): D=20 4지표 결과 행렬 확정 + 세대 배너"
```

---

### Task 6: 대시보드 녹화본 8종 재생성

**Files:**
- 코드 변경 없음. `tools/monitor/streams/`, `tools/monitor/anim/` 산출물만 생성한다(둘 다 `.gitignore` 에 있어 커밋 대상이 아니다 — `.gitignore:30-31`).

**Interfaces:**
- Consumes: Task 1 의 D=20 기본값, Task 2 의 `tools/regen_d20.sh`

**이 작업이 필요한 이유:** 대시보드는 케이스 버튼 8개(`dashboard.html:797-806`: none, battery, fault, zone, fault_battery, fault_zone, battery_zone, battery_mild)를 각각 별도 녹화본으로 재생한다. 이전 세대에서는 3종만 다시 만들어 나머지 5종이 옛 기하로 남았고, 그중 둘(`fault_zone`, `battery_zone`)은 파일 자체가 없었다.

- [ ] **Step 1: UI 를 닫고 라이브 런이 없는지 확인한다**

```bash
tasklist | grep -i julia
curl -s --max-time 3 http://127.0.0.1:8080/ >/dev/null && echo "monitor server UP -- 끄고 진행할 것"
```

모니터 서버가 떠 있으면 **끈다.** 서버의 `POST /run` 은 `MONITOR_STREAM` 파일을 열면서 **0바이트로 잘라내므로**, 재생성 중에 브라우저에서 케이스 버튼을 누르면 그 녹화본이 그 자리에서 파괴된다(실측).

- [ ] **Step 2: 8종을 재생성한다 (~25분, 순차)**

Run:
```bash
bash tools/regen_d20.sh ui > /tmp/ui_d20.log 2>&1
tail -3 /tmp/ui_d20.log
```

Expected: 마지막 줄 `STATUS render ok cases=8/8 failed=none`.
일부 케이스가 실패하면 그 케이스만 인자로 넘겨 다시 돌린다:
```bash
DSPY_URL=http://127.0.0.1:8077 bash tools/monitor/regen_router_cases.sh <실패한 케이스>
```

- [ ] **Step 3: 8종 전부에 창고가 D=20 으로 들어갔는지 확인한다**

Run:
```bash
python - <<'PY'
import datetime, glob, json, os
print('%-42s %-9s %-6s %s' % ('FILE','depots','D','mtime'))
bad=[]
for p in sorted(glob.glob('tools/monitor/streams/*.jsonl')):
    try:
        line=open(p,encoding='utf-8').readline()
        fr=json.loads(line) if line.strip() else {}
    except Exception as e:
        print('%-42s %-9s %-6s %s' % (os.path.basename(p),'ERR','-',e)); bad.append(p); continue
    d=fr.get('depots')
    D='-' if not d else max(abs(c) for x in d for c in x['center'])
    mt=datetime.datetime.fromtimestamp(os.path.getmtime(p)).strftime('%m-%d %H:%M')
    print('%-42s %-9s %-6s %s' % (os.path.basename(p), ('YES(%d)'%len(d)) if d else 'NO', D, mt))
    if not d or D != 20.0: bad.append(p)
print()
print('FAIL: 아래 파일이 D=20 기하가 아니다:' if bad else 'PASS: 모든 스트림이 depots 4개 @ D=20')
for p in bad: print('   ', p)
PY
```
Expected: 마지막 줄 `PASS`. 0바이트 파일이 `ERR` 로 잡히면 그 케이스를 다시 렌더한다.

- [ ] **Step 4: 정박이 유지되는지 확인한다**

Run:
```bash
for f in tools/monitor/streams/tractor__*.jsonl; do
  printf "%-45s " "$(basename $f)"
  python tools/monitor/verify_depot_station.py "$f" | head -1
done
```
Expected: 전부 `PASS  <n> parked-spare observations, all within tol=1.00 of their depot`.

`FAIL` 이 나오면 D=20 에서 정박이 깨진 것이다 — 창고가 빌드에 가까워져 스페어가 다른 로봇에 밀렸을 수 있다. 그 경우 D 를 더 키우는 것이 아니라 **원인을 먼저 확인한다**(`verify_depot_station.py` 가 찍는 프레임 번호와 거리로 언제부터 밀렸는지 본다).

- [ ] **Step 5: 눈으로 확인한다**

```bash
DSPY_URL=http://127.0.0.1:8077 \
NOVELTY_CALIB=$PWD/wm4spacecraft_manufacturing/novelty_calibration_no_zoneblk.json \
julia +lts --project=. tools/monitor/server.jl
```

브라우저에서 `http://127.0.0.1:8080/` 를 연다. 케이스 버튼 8개를 **하나씩** 눌러 확인한다:

- Fleet States 패널 위에 `NORTH 3/3  EAST 3/3  SOUTH 3/3  WEST 3/3` 형태의 재고 줄이 뜬다(용량은 `DEMO_SPARES` 에 따라 다르다).
- FACTORY VIEW 에서 파란 창고 패드가 빌드 바깥에 보이고 그 위에 예비 로봇이 서 있다. D=40 때보다 가까워 한 화면에 같이 들어와야 한다.
- 고장·방전 사건 뒤 **응답한 방위 하나만** 숫자가 줄어든다(최근접 창고 선정이 동작한다는 증거).

**주의:** 케이스 버튼은 녹화본 재생이 아니라 **라이브 런을 시작**할 수 있고, 그러면 그 케이스의 녹화본이 0바이트로 잘린다. 녹화본을 보려면 "Load previous recording" 경로를 쓴다. 실수로 잘랐다면 Step 2 를 그 케이스만 다시 돌린다.

- [ ] **Step 6: 최종 검증**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'
julia +lts --project=. tools/checks.jl depot_geometry
julia +lts --project=. tools/checks.jl station_keeping
julia +lts --project=. tools/checks.jl spare_pool
python wm4spacecraft_manufacturing/audit_action_vocab.py
python wm4spacecraft_manufacturing/test_surrogate_support.py
```

Expected: `Pkg.test()` = **11 pass / 1 error**(Gurobi, 무관) · `depot_geometry` 13/0 · `station_keeping` 8/0 · `spare_pool` 20/0 · `audit_action_vocab` exit 0 (6/6) · `test_surrogate_support` `support=[0, 1, 2, 3, 4, 7, 8]` 7/7.

11/1 이 아니면 **크게 보고한다** — 합리화하지 말 것.

- [ ] **Step 7: 커밋**

스트림·애니메이션은 `.gitignore` 대상이라 커밋할 것이 없다. 이 Task 에서 코드가 바뀌지 않았다면 커밋을 건너뛴다. Step 2~4 에서 무언가 고쳤다면 그것만 커밋한다.

```bash
git status --porcelain          # 비어 있으면 정상
```

---

## 실행 순서 요약 (총 ~4시간, 전부 순차)

| Task | 내용 | 소요 |
|---|---|---|
| 1 | D 기본값 20 (코드 3줄) + 점검 2종 | ~10분 |
| 2 | 오라클 격자 재생성 | ~15분 |
| 3 | 평가 런 42개 (시드 1 → 시드 2) | ~190분 |
| 4 | 기준 정책 재유도 | ~15분 |
| 5 | 표 + 결과 문서 + 배너 | ~30분 |
| 6 | UI 녹화본 8종 + 최종 검증 | ~40분 |

Task 3 이 전체의 80% 다. 중간에 끊겨도 append 라 이미 끝난 케이스는 남는다. 시간이 부족하면 **시드 1 만 돌리고 n=1 로 표를 만든 뒤**(Task 3 Step 2 생략) 나중에 시드 2 를 덧붙여 표를 다시 생성해도 된다 — 그 경우 결과 문서의 n 서술을 반드시 함께 고친다.
