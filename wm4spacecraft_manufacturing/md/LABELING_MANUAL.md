# Labeling & OOD Pipeline — Operations Manual

*How the oracle labeling works, how it was restored after `decpomdp/` was deleted, and how it
operates in the monitor UI.*

---

## 0. TL;DR

- **Labeling** = for each OOD situation, run every candidate recovery macro through the *real*
  simulator to the end and record its outcome (`complete` / `closed` / `makespan`). The macro with
  the best outcome is the **oracle label** the surrogate learns to predict.
- `decpomdp/examples/` was deleted; it only supplied **4 adapter functions**. They are rebuilt in
  [`oracle/ood_mdp_shim.jl`](oracle/ood_mdp_shim.jl) on surviving `CB` code, so labeling runs again.
- **Generate labels** (Julia): `julia --project=. ../wm4.../oracle/gen_oracle_dataset.jl` with `DS_*`
  env vars. **Consume labels** (Python): `e1_analyze.py`, `sweep_surrogate.py`, `ladder.py`.
- **Watch it in the UI**: `run_demo.jl` emits a monitor stream → open `tools/monitor/dashboard.html`.
  The OOD Feed + "environment descriptors" panel show exactly the state each label is keyed on; the
  respec panel shows the macro (the same DSL the labeler sweeps).

---

## 1. What "labeling" means here

The surrogate's job is to pick a recovery **macro** the instant an out-of-distribution (OOD) event
fires. To train it we need ground truth: *which macro was actually best?* We get that by brute force.

For one **instance** = (OOD kind × severity × seed × spare-provisioning):

1. Run the build until the OOD fires; **capture the decision-time state features** (the public info a
   controller can see: `soc`, `severity`, `spare_count`, `agent_pending`, `zone_overlap`, `progress`…).
2. For **each** candidate macro `a ∈ {0 NOOP, 1 Replace, 2 Deprioritize, 3 ForbidZone, 4 ReformTeam}`,
   apply that macro at the event and **run the whole build to completion**, recording `RunMetrics`
   (`complete`, `closed` nodes, realized `makespan`, `feasible`).
3. Write **one JSONL row per (instance, macro)**. The **oracle-best** macro is the feasibility-
   lexicographic winner (complete first, then most closed nodes, then shortest makespan).

The surrogate has something to learn only because the best macro **varies with state** — deep battery
→ Replace, mild battery → Deprioritize/NOOP, blocking zone → ForbidZone, idle-robot fault → NOOP.
That variation is encoded in the state features, so a state-reading model beats any "always macro X".

**Files that produce/consume labels**

| Stage | File | Role |
|---|---|---|
| produce | `oracle/gen_oracle_dataset.jl` | the labeler (sweeps macros, writes JSONL) |
| **restore** | `oracle/ood_mdp_shim.jl` | **rebuilt** MDP adapter (was `decpomdp/examples`) |
| consume | `e1_analyze.py` | load + featurize + LOO decision suboptimality audit |
| consume | `sweep_surrogate.py` / `ladder.py` / `master_experiment.py` | HP sweep · severity ladder · tie/λ |

---

## 2. What broke and how it was restored

`gen_oracle_dataset.jl` used to `include` two files from a now-deleted folder:
`decpomdp/examples/ood_env.jl` and `ood_env_mdp.jl`. Investigation showed:

- The generator body references **only 4 symbols** from those files:
  `event_context`, `valid_actions`, `canonical_action`, `action_to_proposal`.
- `run_one`, `RunMetrics`, and all environment setup are **local or `CB.*`** — nothing else was lost.
- The files were **never committed**, so git cannot restore them.

So the fix is one replacement file, [`oracle/ood_mdp_shim.jl`](oracle/ood_mdp_shim.jl), rebuilt on
surviving `CB` code. The generator's include block now points at it:

```julia
# oracle/gen_oracle_dataset.jl (patched)
include(joinpath(@__DIR__, "ood_mdp_shim.jl"))   # was: decpomdp/examples/ood_env.jl + ood_env_mdp.jl
```

**What each rebuilt function does** (all keyed to surviving code, so labels stay compatible):

| function | rebuilt from | behaviour |
|---|---|---|
| `event_context(env, ev)` | `CB.ood_truth_log()` (`ood_truth.jl`) | `ev` is only the NL string; the real event (type/agent/zone/soc) is recovered from the OOD **truth log** every injector auto-writes. Returns `(type, agent, zone, assembly, soc, after)`. |
| `valid_actions(ctx)` | `random_macro_respec` repertoires (`baselines.jl`) | legal macros per type: fault/battery `{0,1,2}`, zone `{0,3}`, reform `{0,4}`. |
| `canonical_action(ctx)` | `canonical_respec` (`baselines.jl`) | default macro: fault→Replace, zone→ForbidZone (if it blocks an assembly), battery→Replace if `soc ≤ REPLACE_SOC_THRESHOLD` else Deprioritize, reform→ReformTeam. |
| `action_to_proposal(ctx, a)` | DSL ctors in `spec_dsl.jl` | macro id → `RespecProposal([ReplaceAgent / DeprioritizeAgent / ForbidZone / ReformTeam])`; NOOP and any invalid cross-type macro → `nothing`. |

This is the **same `RespecProposal`** the LLM path (`replan.jl`) and the monitor UI produce — so
verify → dispatch → re-solve downstream is unchanged.

> **Status by OOD kind** (full record: [`sweep_lab/shim_validation.txt`](sweep_lab/shim_validation.txt)):
> - **fault, battery — VALIDATED.** 14/14 logic unit tests pass; an end-to-end battery run reproduces
>   the pre-deletion **decision** (Replace is oracle-best for a deep-discharge battery, old and new)
>   on an identical scenario. Two fixes make `valid_mask` + the "invalid-macro == NOOP" structure match
>   the dumps exactly. Absolute `closed` drifts ±3 nodes (MILP 5%-gap), which the label is robust to.
> - **zone (zoneblk) — shim correct, but FLAGGED.** `DS_SHIM_DEBUG=1` proves `event_context` recovers
>   the zone + assembly and `action_to_proposal` builds the ForbidZone proposal. But the current CB
>   stalls zone builds low and ForbidZone no longer recovers them (NOOP itself: 131 now vs 235 in the
>   dumps; same seed+severity gives a **different overlap**, so the zone is placed differently). That is
>   **CB code drift in staging-geometry / restage / nav-wedging — outside the 4 restored adapter
>   functions** — and needs a separate look at `restage_zone.jl`. Zone labels are recorded honestly but
>   don't yet reproduce the dumps' ForbidZone-recovery regime.

---

## 3. Running the labeler (Julia)

Run from the **`ConstructionBots.jl` repo root** (needs its `--project`):

```bash
julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

Everything is controlled by environment variables:

| env var | default | meaning |
|---|---|---|
| `DS_KINDS` | `fault,zone,battery` | OOD kinds to generate (also `faultidle`, `zoneharm`, `zoneblk`) |
| `DS_SEEDS` | `1,2,3` | **world seed = initial robot placement only** (see box below). Not a disturbance seed |
| `DS_SPARES` | `3` | spare-robots-per-pool levels (fault instances vary this) |
| `DS_SMOKE` | `0` | `1` = just **one** instance (fast end-to-end check) |
| `DS_OUT` | `out/oracle_dataset.jsonl` | output JSONL path |
| `DS_FIRE_FAULT` | `12,20,30,45,60` | **retry ladder**, not a grid — see §6. First point that succeeds wins |
| `DS_FIRE_GRID` | *(empty)* | **fire point as an instance dimension** (§6). e.g. `58,100,140,180,220,260` |
| `DS_FIRE_RETRY` / `DS_FIRE_TRIES` | `8` / `6` | within one instance, retry above the target every N closed nodes, M times |
| `DS_MACROS` | *(all)* | limit the labeled arms. `0` = NOOP only = descriptors without a macro sweep (§6) |
| `DS_NOPROG` | `8000` | no-progress cap (lower = faster gen, coarser stall labels) |
| `DS_HOTSWAP` / `HOT_SWAP` | `0` | `1` = enact Replace as an identity-preserving depot hot-swap |

> ### `DS_SEEDS` is a WORLD seed, not a disturbance seed (2026-08-05)
>
> The simulator consumes `rng` in exactly **one** place — `StatsBase.sample(rng, vtxs, num_robots)`
> in `full_demo.jl:420`, the initial placement of the robots. Everything downstream (schedule, MILP
> assignment, staging geometry, RVO) is deterministic, so `(seed, policy)` fixes the whole trajectory
> (see the DETERMINISM note in `gen_oracle_dataset.jl`). And in the labeler the hazard point process
> is off (`DS_MC_K=1`), while fire time / kind / severity are all named explicitly.
>
> **So bumping `DS_SEEDS` does not resample "what goes wrong". It builds the same spacecraft in a
> different factory layout.** For this domain — the same cell, the same docks, the same product,
> repeatedly — that axis does not exist in deployment, and deployment is always seed 1
> (`full_demo.jl`'s default `MersenneTwister(1)`, the world the demos run in).
>
> Current policy: **pin the world at seed 1 and spend the budget on fire points instead**
> (`DS_FIRE_GRID`). Randomly-drawn event times belong in *evaluation*, not in labels — labels are
> counterfactual comparisons, so every arm must see the SAME event at the SAME point. For the random
> side, use `tools/monitor/run_ood_sweep.ps1` (`DEMO_OOD_SEED`) → `ood_sweep_report.py`.
> Rationale in `md/FIRE_TIME_RELABEL_2026-08-05.md` §7.

**Examples**

```bash
# smoke: one battery instance, confirm the pipeline runs end to end
DS_SMOKE=1 DS_KINDS=battery DS_OUT=sweep_lab/shim_smoke.jsonl \
  julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl

# preferred axis: ONE world, many fire points (see the box above)
DS_KINDS=fault DS_SEEDS=1 DS_FIRE_GRID=58,80,100,120,140,160,180,200,220,240,260 \
  DS_HOTSWAP=1 DS_VALID_ONLY=1 DS_OUT=oracle/out/firegrid_sfault.jsonl \
  julia --project=. ../wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

Each row is `{kind, severity, soc, spare_count, agent_pending, zone_overlap, progress, macro,
complete, closed, makespan, fired, valid_mask, …}`. Cost per macro ≈ one full simulation, so a full
kind×severity×seed grid is minutes-to-hours — run larger grids in the background.

**Consume** the labels in Python (no Julia needed):

```bash
python core/e1_analyze.py <dataset.jsonl>       # LOO decision suboptimality audit + difficulty
python sweep_surrogate.py <dataset.jsonl> --cost-aware   # HP sweep (subopt_norm + tie-rate)
python ladder.py                                # per-kind severity ladder validity
```

---

## 4. How it operates in the UI

The monitor UI is a **browser dashboard** that replays (or live-drives) a simulation and shows the OOD
events, the recovery macro chosen, and the state the decision was made on — i.e. the same material the
labeler records, made visible.

### 4a. Produce a stream, then open the dashboard

```bash
# from ConstructionBots.jl root — emits tools/monitor/streams/<model>__<case>.jsonl
DEMO_OOD=fault DEMO_N=3 DEMO_ROBOTS=10 DEMO_MODEL=tractor.mpd \
  julia --project=. tools/monitor/run_demo.jl
```

- `DEMO_OOD ∈ {none, battery, fault, zone, fault_battery, fault_zone, battery_zone}` — **which** kinds.
- `DEMO_N` — **how many** OOD events to inject (0 = case default = one per kind). `>0` overrides the
  fault/battery count, cycling the case's robot kinds across the build; a zone always fires once up
  front (spatial re-staging is only transform-safe before any build step opens). Verified: `DEMO_N=3`
  fault → 3 breakdowns at closed≈[30,130,229], build still completes.

Then run through the control server and open the dashboard: **in the case bar, set the `OOD events`
number field** (0–20) and press `Start live session` — the server passes it as `DEMO_N`. (Or open
`dashboard.html` for replay and point `STREAM_URL` at an emitted `.jsonl`.)

### 4b. What each panel shows

| Panel | Shows | Relation to labeling |
|---|---|---|
| **Header** | sim time, completed assemblies, fleet size, **OOD count** | the OOD count = how many events fired this run |
| **Control bar** | play/pause, timeline **scrub**, model + **OOD-group** selectors | pick the scenario; scrub to the moment an OOD fires |
| **Factory View** (MeshCat) | live 3-D build; **inject bar** (X/Y/R + "Inject Forbid Zone") | in a **live session** you can inject a zone by hand and watch the respec |
| **OOD Event Feed** | each event, its type, and the **macro** chosen | the macro = `action_to_proposal`'s output = a labeled candidate |
| **OOD input · environment descriptors** | the decision-time **state features** | exactly the features a label row is keyed on (`soc`, `severity`, `spare_count`, …) |
| **Fleet States / Assembly Tree / Robot Schedule** | per-robot status, build DAG, Gantt | the consequences a macro's `RunMetrics` label summarizes |

### 4c. Replay vs live

- **Replay** (default, `LIVE:false`): load a finished `.jsonl` once and scrub the timeline. Use this to
  review what the labeler saw for a given instance.
- **Live session** ("Start live session", `LIVE:true`): the dashboard polls appended frames and you can
  **inject a Forbid Zone interactively** (set X/Y/R → "Inject Forbid Zone"). The event flows through the
  same seam the labeler uses, so the macro shown is the same one `canonical_action` would pick.

### 4d. Reading a labeling decision in the UI

1. Pick a scenario (`DEMO_OOD=battery`), run `run_demo.jl`, open the dashboard.
2. Scrub to the OOD event in the **feed** — note its type and the **environment descriptors** (e.g.
   `soc=0.12`). This is one label instance's feature vector.
3. The feed shows the chosen macro (e.g. **Replace**, because `soc ≤ 0.2`). That's
   `canonical_action` — the same rule the labeler's canonical background policy uses.
4. To see *why* that macro is best, the offline labeler ran **all five** macros to completion; the
   dashboard shows the one enacted. Cross-reference the JSONL row set for that instance to see the
   full `closed`/`complete` outcome of every macro.

---

## 5. Filling the gaps the study found

The parameter study surfaced three data gaps the restored labeler can now close:

1. **n too small for significance** — the HP-tuning win was significant at n=31 but not n=20.
   *(Superseded 2026-08-05: the original advice here was to add `DS_SEEDS=4,5,6,7,8`. That grows the
   WORLD axis, which does not exist in deployment — see the box in §3. Grow **fire points** instead:
   `DS_SEEDS=1` with a denser `DS_FIRE_GRID`, which also puts real variance on the `progress`
   descriptor. `run_firegrid_fault.ps1` does this for fault/faultidle/battery.)*
2. **more graded battery severities** (`DS_KINDS=battery`, varied severities) to straddle the decision
   boundary and reduce the 29% tie rate.

Generate into `oracle/out/graded/`, then re-run `python ladder.py` and
`python sweep_surrogate.py <combined> --cost-aware`.

> **zoneblk is blocked upstream.** Regenerating zone data will NOT fix the WEAK zone ladder until the
> CB staging-geometry / restage drift (see the zone status above) is resolved — the current CB doesn't
> reproduce ForbidZone recovery, so every new zone label collapses to NOOP. Fix `restage_zone.jl` /
> the zone placement first, then regenerate. Until then, keep the study's fault+battery conclusions and
> treat the zone ladder as pending. A wrong-regime gap-fill attempt was archived to
> `sweep_lab/archive_unusable/`.

---

## 6. 발화 시점(fire point) — `progress` 축이 왜 점 하나였나 (2026-08-04)

### 6a. 증상

DSPy 라우터가 데모의 **battery OOD 를 매번 `NEVER SEEN THIS BEFORE`** 로 판정했다. battery 는
교정에 들어 있는 종류인데도.

### 6b. 원인 — `FIRE_POINTS` 는 grid 가 아니라 재시도 사다리다

`build_injection` 은 한 instance 에 **같은 액션**을 여러 시점에 예약하고 `fired[]` 플래그로 첫
성공만 남긴다. 즉 `(12,20,30,45,60)` 은 "다섯 개의 서로 다른 instance"가 아니라 "12 에서 실패하면
20 에서 다시" 라는 뜻이다. 그런데 tractor 는 **첫 시뮬 배치에서 이미 ~58 노드를 닫으므로** 다섯
시점이 전부 같은 순간에 due 가 된다. 실측 결과 CANONICAL 60 instance 의 `closed_at_fire` 는 두
값뿐이다:

```
battery  n=24  closed_at_fire={58}     progress sd = 0.00000
fault    n=18  closed_at_fire={50,58}  progress sd = 0.00799
zoneblk  n=18  closed_at_fire={58}     progress sd = 0.00000
```

### 6c. 왜 그게 라우터를 망가뜨리나

`export_novelty_calibration.py` 가 그 덤프로 mu/sd 를 맞추므로 `progress` 의 sd 가 **0.0051** 이
된다. 서술자는 전부 [0,1] 범위인데 한 축만 sd 가 0.005 면 그 축은 초민감 축이 되고, 6축·cap=8
에서는 **한 축만 cap 에 잘려도 score ≥ 8/√6 = 3.27** 인데 교정 최대 score 는 2.21 이다 → 나머지
5축이 완벽해도 자동으로 novel. 데모 battery(progress 0.413)의 실측 분해:

| 축 | z | score 기여 |
|---|---|---|
| progress | +45.1 → cap 8.00 | **93%** |
| recovery_capacity | −1.53 | 3% |
| slack | −1.33 | 3% |
| harm / work_at_risk / resource_loss | +0.59 / +0.45 / +0.66 | 1.5% |

즉 게이트는 "아는 종류인가"가 아니라 **"교정과 같은 순간에 터졌나"** 를 재고 있었다. 종류와
무관한 현상이라는 증거: 같은 fault 가 progress 0.177 에서는 familiar, 0.659 에서는 novel 이다.

### 6d. 고침 — `DS_FIRE_GRID`

발화 시점을 **instance 차원**으로 올린다. 값을 주면 instance id 에 `_f<closed>` 가 붙고, 각
instance 안에서는 목표점 **위쪽으로만** 짧게 재시도한다(`DS_FIRE_RETRY`×`DS_FIRE_TRIES`).
비워 두면(기본) 예전 사다리·예전 id 그대로라 기존 덤프와 바이트 호환이다.

```bash
DS_KINDS=battery DS_SEEDS=1,2 DS_BSOC=0.05,0.3,0.6 \
DS_FIRE_GRID=58,100,140,180,220,260 DS_MACROS=0 DS_NOCTRL=1 \
DS_OUT=oracle/out/firegrid_sbatt.jsonl \
  julia +lts --project=. wm4spacecraft_manufacturing/oracle/gen_oracle_dataset.jl
```

또는 두 lane 을 한 번에: `pwsh -File wm4spacecraft_manufacturing/oracle/run_firegrid.ps1`

### 6e. 어느 진행도에서 무엇이 발화 가능한가 (측정값)

추측하지 말 것. `oracle/probe_fire_points.jl` 이 시뮬 **한 판**으로 스캔해
`oracle/out/fire_probe.csv` 에 적는다. 2026-08-04 측정(tractor, 10 robots, spare=3):

| closed | progress | fault 대상 | pending staging (zone) | battery 대상 |
|---|---|---|---|---|
| 58 | 0.185 | frontier only | 8 | 10 |
| 60 | 0.192 | frontier only | 8 | 9 |
| 80 ~ 280 | 0.26 ~ 0.89 | **없음** | 8 → 1 | 2 ~ 9 |

**fault 는 closed ≥ 80 에서 안전한 대상이 아예 없다**(single/solo/frontier 피커 전부 nothing).
그러니 fault 는 진행도 분산에 기여할 수 없다 — 이건 피커의 한계이고, 후반 fault 라벨이 필요하면
`pick_solo_*` / `fault_action(safe=…)` 쪽을 먼저 고쳐야 한다. 진행도 분산은 battery(전 구간)와
zoneblk(≤220)가 만든다. 서술자가 kind-agnostic 이라 그것만으로 pooled sd 가 커져 후반 fault 도
familiar 로 돌아온다 — "물리적으로 비슷한 사건은 in-distribution" 이 원래 설계 의도다.

> **2026-08-05 갱신 — 이 표의 fault 열은 이제 낡았다.** 위 문단이 지목한 "피커를 먼저 고쳐야
> 한다"를 실제로 고쳤다(§6h). 같은 프로브에 열을 더해 다시 재면 hot-swap 조건에서는 **closed
> 58~240 전 구간에 후보가 10 명**이다. 즉 "후반 fault 불가"는 물리적 사실이 아니라 술어의
> 산물이었다. 갱신된 측정은 `oracle/out/fire_probe_hotswap.csv`.

### 6f. TIER A / TIER B — 무엇을 얼마나 다시 만들어야 하나

- **TIER A (교정만)** `DS_MACROS=0 DS_NOCTRL=1`. novelty 교정은 결정 순간의 **상태 서술자만**
  읽고 라벨을 안 읽으므로 instance 당 판 하나면 충분하다(6배 싸다). 이렇게 만든 행은
  `calib_only=true` 로 표시된다.
- **TIER B (surrogate 까지)** 같은 그리드로 전체 매크로 스윕. 교정만 고치면 라우터는 "익숙하다"고
  말하는데 정작 surrogate 는 그 진행도의 학습 근거가 없다 — **그건 게이트가 막으려던 바로 그
  상황이다.** 그래서 TIER B 는 선택이 아니라 지연된 필수 작업이다. `TIER_B=1` 로 같은 스크립트.

라벨 1판 = 약 **221 초**(2026-08-04 실측, tractor). TIER A 48 instance ≈ 1.5 h(2 lane),
TIER B 는 같은 그리드에서 약 6 h(2 lane).

### 6g. 합격 판정

새 시뮬레이션 없이, 이미 녹화된 데모 스트림의 서술자를 그대로 재판정한다:

```bash
python verify_router_calibration.py novelty_calibration_no_zoneblk.json
```

`ACCEPTANCE (battery must read FAMILIAR): PASS` 가 나와야 한다. 이 스크립트는 축별 기여도와
degenerate 축 경고도 같이 찍으므로, 다음에 같은 함정에 빠졌는지 한눈에 보인다.
(`export_novelty_calibration.py` 도 이제 sd < 0.02 인 축을 발견하면 크게 경고한다.)

---

## 7. fault 를 여러 진행도에서 라벨링하기 — 피커 수정 (2026-08-05)

### 7a. 왜 fault 만 초반에 갇혀 있었나

§6e 는 "closed ≥ 80 에서 안전한 fault 대상이 없다"를 측정으로 보여줬다. 그 **이유**는 팀 크기가
아니라 술어 하나였다. `pick_solo_fault_target` 과 `pick_solo_frontier_target` 은 둘 다
`_first_pending_assignment` 를 통과해야 하는데, 그 함수는

> 아직 안 닫힌 `RobotGo` 인데 **선행자가 `RobotStart` 이거나 이미 closed** 인 노드

즉 **깨끗한 작업 경계**에 서 있는 로봇만 인정한다. 빌드가 굴러가기 시작하면 로봇은 자기 운반
사슬(`FormTransportUnit` → `TransportUnitGo` → `DepositCargo`) 안에 들어가 그 경계를 스쳐 지나갈
뿐이라, 중반 이후 **한 순간을 찍은 스냅샷에서는 후보가 0** 이 된다. 실측(`fire_probe_why.csv`)의
`n_frontier` 열이 closed ≥ 91 에서 전부 0 인 것이 바로 이 현상이다 — 활성 로봇이 19~23 대나 되는데도.

그래서 fault 는 항상 `closed ∈ {50, 58}` 에서만 터졌고 = `progress` 축이 점 하나 = §6c 의 라우터
오작동으로 이어졌다. **"fault 는 초반 사건"이라는 성질은 도메인이 아니라 코드에서 나왔다.**

### 7b. 그 술어가 진짜로 지키던 것

다인 운반팀의 공동 운반자를 **스케줄 재각인(re-stamp)** 으로 교체하면
`@assert has_edge(scene_tree, agent, robot_id)`(route_planning.jl, `apply_cmd!(::FormTransportUnit)`)
가 터져 런 자체가 죽는다. 술어는 그 어서션을 피하려던 가드다.

그런데 정체성 보존 **HOT-SWAP** 은 id 를 유지한 채 본체만 창고에서 갈아끼우므로 넘길 엣지 자체가
없고 운반 도중 교체도 안전하다. 엔진은 **이미 그렇게 판정하고 있었다** — 같은 예외가 두 곳에 있다:

| 위치 | 코드 |
|---|---|
| `src/mdp/hazard.jl:454` (`_hz_safe_target`) | `hot_swap_enabled() && return true   # 핫스왑이면 운반 중에도 안전` |
| `src/navigator/battery.jl:505` | `hot_swap_enabled() \|\| (_first_pending_assignment(env,id) === nothing && return nothing)` |

라벨러만 그 예외를 못 받고 있었다.

### 7c. 고침 — `pick_hotswap_fault_target`

`src/respec/ood_injection.jl` 에 피커를 하나 **추가**했다(기존 두 피커는 한 글자도 안 건드렸다 —
기존 덤프의 대상 선택이 바뀌면 재현성이 깨진다).

- 후보 = 예비/복구예비가 아니고, **아직 안 닫힌 `FormTransportUnit` 팀의 멤버**인 로봇
  (= 남은 운반 일이 있다 = NOOP 이면 그 팀이 영구 정지한다 = 사건이 결과를 낳는다).
- `prefer_inprogress=true` 면 지금 진행 중인 팀의 멤버를 우선. 결정성을 위해 id 최소.
- 연결 지점 두 곳:
  - `fault_robot!(safe=true)` 의 **3단 사다리 마지막 칸**(`hot_swap_enabled()` 일 때만). 앞 두 단이
    성공하면 그대로 쓰므로 초반 발화는 이전과 동일하고, 예전에 `nothing` 이던 순간만 채운다.
  - 라벨러의 `DS_FAULT_PICK` — `"hotswap"` 이면 이것만, `"auto"`(기본)면 기존 3피커가 전부 실패할
    때 폴백(단, `DS_HOTSWAP=1` 일 때만).

측정으로 확인(`oracle/probe_fire_points.jl` 에 `n_hotswap` 열 추가, 출력 `fire_probe_hotswap.csv`):

| closed | 58 | 80 | 101 | 140 | 183 | 222 | 240 | 260 | 280 |
|---|---|---|---|---|---|---|---|---|---|
| 기존 피커(frontier) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| **hotswap 후보 수** | 10 | 10 | 10 | 10 | 10 | 10 | 9 | 2 | **0** |

closed 280 에서 0 인 것은 술어가 아니라 사실이다 — 그 시점엔 남은 운반 일이 없다. 그래서 그리드는
260 에서 끝낸다.

### 7d. 재라벨링 실행

```bash
pwsh -File wm4spacecraft_manufacturing/oracle/run_firegrid_fault.ps1
```

두 lane 을 **같은 발화점 그리드**(58/100/140/180/220/260 ≈ progress 0.19~0.83)로 돌린다:

| lane | 무엇 | 왜 |
|---|---|---|
| `fault` | 희생자가 남은 운반 일을 가짐 | NOOP 이면 팀 영구 정지 → **Replace** 가 정답 |
| `faultidle` | 같은 `kind="fault"` 라벨·같은 NL 이지만 희생자가 일이 없음 | 개입이 낭비 → **NOOP** 이 정답 |

한쪽만 만들면 후반 fault 라벨이 전부 Replace 가 되어 `H(best|kind)` 가 다시 0 이 된다 — 데이터는
늘었는데 과제는 그대로 trivial 해지는, 이 저장소가 이미 두 번 밟은 지뢰다.

TIER B(진짜 oracle 라벨)로 돈다: `DS_VALID_ONLY=1` 이라 그 사건에서 실행 가능한 팔만(fault 계열은
실제로 관측된 `valid_mask` 가 `[0,1]` = NOOP/Replace) + control 1 판 = instance 당 3 판.
`DS_MACROS` 를 안 쓰므로 `calib_only=false` 로 기록되어 TIER A(교정 전용) 행과 섞이지 않는다.

> **lane 은 순차로 돌린다(기본).** 병렬로 돌렸더니 4번째 instance 에서
> `OutOfMemoryError() @ run_with_stack` 로 죽었다(2026-08-05 실측). 판 하나마다 `DS_STACK`
> (기본 2GB)을 통째로 예약하므로 프로세스 2개면 4GB 이고, 편집기·파이썬 서비스가 이미 물고
> 있으면 16GB 머신에서도 부족하다. `DS_RESUME=1` 이라 죽은 지점부터 이어지지만 시간을 버린다.
> 정말 병렬이 필요하면 `$env:FG_PARALLEL=1` (lane 당 여유 메모리 2.5GB 이상 확인 후).

결과 점검:

```bash
python firegrid_report.py oracle/out/firegrid_merged.jsonl      # 커버리지 · 정답 다양성 · admissibility
python verify_router_calibration.py novelty_calibration_no_zoneblk.json
```

### 7e. 같은 술어에서 나온 **두 번째** 버그 — faultidle 이 중반부터 무해하지 않았다

fault lane 을 고치고 faultidle lane 을 처음 돌렸더니 이런 결과가 나왔다(`firegrid_v1broken_faultidle.jsonl`):

| 발화점 | 58 | 100 | 140 | 180 | 220 | 260 |
|---|---|---|---|---|---|---|
| 희생자의 `agent_pending` | **0** | 4 | 2 | 2 | 2 | 1 |
| NOOP 완주 | **Y** | n | n | n | n | n |

`faultidle` 의 존재 이유는 "같은 kind·같은 NL 인데 희생자가 일이 없어 **NOOP 이 정답**"인 쌍둥이를
만드는 것이다. 그런데 closed=58 을 벗어나자 희생자가 일감을 가진 로봇이 되어 NOOP 이 전부 미완주였다
= 쌍둥이가 아니라 그냥 또 하나의 해로운 고장.

원인은 §7a 와 **똑같은 술어**였다. `_pick_idle_victim` 이 "남은 일이 있는가"를
`_first_pending_assignment(env, rid) === nothing` 으로 물었는데, 그건 "지금 깨끗한 작업 경계에 서
있는가"라는 뜻이라 중반 이후 거의 모든 로봇에게 `nothing` 이다 → **바쁜 로봇이 전부 '일 없음'으로
오분류**. 그래서 이 변종은 초반에만 우연히 옳았다.

고침: 판정을 스케줄 구조에서 직접 읽는다 — **아직 안 닫힌 `FormTransportUnit` 팀의 멤버인가**.
이는 `pick_hotswap_fault_target` 의 후보 조건과 정확히 여집합이라, 두 변종이 한 기준의 양쪽에 놓인다:

| 변종 | 조건 | 정답 |
|---|---|---|
| `fault` | 안 닫힌 운반팀의 멤버 **이다** (남은 일 있음) | Replace |
| `faultidle` | 멤버가 **아니다** (남은 일 없음) | NOOP |

합격 판정은 데이터로 한다: 새 faultidle 행은 **모든 발화점에서 `agent_pending=0` 이고 NOOP 이 완주**해야
한다. 옛 파일은 증거로 `firegrid_v1broken_faultidle.jsonl` 에 남겨 두었다(`firegrid_s*` glob 에 안 걸리므로
병합에는 안 들어간다).

> 교훈: `_first_pending_assignment` 는 **재각인(re-stamp) 인계 지점을 찾는 함수**지 "남은 일이
> 있는가"를 재는 함수가 아니다. 그 용도로 쓴 곳이 저장소에 최소 두 군데 있었고 둘 다 중반 이후
> 조용히 틀렸다. 새로 쓸 때도 같은 실수를 하기 쉬우니, "일감 유무"는 위 FTU 멤버십으로 물을 것.

### 7f. 알아둘 confound (정직하게)

CANONICAL 의 fault 희생자는 "단독 frontier 운반을 앞둔 로봇"이고, 새 후반 instance 의 희생자는
"안 닫힌 운반팀의 멤버(팀 크기 무관)"다. 즉 발화 시점만 바뀐 게 아니라 **희생자 종류도** 바뀌었다.
다만 새 그리드 **안에서는** 피커가 매 시점 같은 규칙(id 최소)으로 뽑으므로 시점 비교는 깨끗하다.
초반 CANONICAL 행과 후반 새 행을 한 축에서 직접 비교할 때만 이 차이를 기억하면 된다.
