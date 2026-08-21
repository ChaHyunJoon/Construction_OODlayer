# SMDP 재정식화 1단계 — 상태를 L1 하나로 통일한다 · 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (권장)
> 또는 superpowers:executing-plans 로 이 계획을 태스크 단위로 실행한다. 모든 단계가 체크박스
> (`- [ ]`)로 되어 있으니 그대로 추적할 것.

**Goal:** 이 하니스의 결정 문제를 형식적으로 검증 가능한 SMDP 로 만든다 — 행동공간을 6팔로 닫고,
hazard 레인을 켜고, 흩어진 열댓 개 전역을 `s`(Markov 상태) / `ξ`(재생 상태) / log 로 쪼개
`snapshot`/`restore!` 왕복을 만든다. 그 위에서 K-rollout 오라클(단계 B)이 실행 가능해진다.

**Architecture:** 표현층(φ · ψ · 22차원 feature · dp 격자)을 **만들지 않는다**. 상태는
`SimState` 하나(`s = (G, Geo, Fleet, Hazard, Courier, Clock, Age, e)`)이고, 난수원은 `ξ` 로
빼서 `s` 가 콘텐츠 해시 가능하게 만든다. semi-Markov 근거는 고전 SMDP 정의 (A)가 아니라
Sutton-Precup-Singh Thm 1 (options ⇒ SMDP)이고, `Age` 블록(`no_progress`·`SNAP_COUNT`)이
Ascione Thm 2.2 의 age 과정 `γ` 다. 매 단계가 측정 게이트로 닫히며, **0번 게이트가 실패하면
계획 전체를 중단하고 MDP/contextual-bandit 으로 기술한다.**

**Tech Stack:** Julia 1.10 (`julia +lts`, `--project=.`) · Python 3 (`/home/chahj578/Construction_OODlayer/.venv/bin/python`)
· 기존 하니스(`DS_DEVIATE_AT`/`DS_DEVIATE_ARM`, `tools/monitor/run_demo.jl`, `dp_oracle/sample_grid.py`)
· `rvo2` (PyCall)

**Spec:** `docs/superpowers/specs/2026-08-19-smdp-state-representation-design.md`

**범위 밖 (별도 계획):** spec §11 단계 12~17 — 롤아웃 오라클(K=4, ~32h) · `V̂` amortization ·
ablation · novelty 교정 재생성 · closed loop 배선. 그것들은 이 계획의 태스크 12(G-M)와
태스크 14(`T_plan`)가 통과한 뒤 **`2026-08-XX-smdp-rollout-oracle.md`** 로 따로 쓴다.
spec §10 이 그 경계를 이미 "단계 (B)" 로 선언했다.

---

## Global Constraints

이 절은 **모든 태스크의 요구사항에 암묵적으로 포함된다.**

- **Julia**: `julia +lts` (1.10). `Manifest.toml` 이 1.10.11 에 핀돼 있고 상위 Julia 에서
  `Pkg.add` 하면 빌드가 조용히 깨진다. **언제나 `--project=.`**.
- **Python**: `/home/chahj578/Construction_OODlayer/.venv/bin/python`. **`.venv` 에 pytest 가 없다** —
  `PYTHONPATH=/usr/lib/python3/dist-packages ../.venv/bin/python -m pytest` 로 돌린다(인터프리터는 `.venv` 유지).
- **`Pkg.test()` 기대 baseline = 11 pass / 1 error** (Gurobi 라이선스 없음, 이 작업과 무관).
  `1 error` 를 회귀로 읽지 말 것.
- **매크로 id 재번호 금지**(spec §2.4). 어휘는 `{0,1,2,4,7,8}` 비연속 그대로. **3·5·6 은 영구 결번**이고
  구세대 파일의 그 행은 **조회 실패로 죽어야 한다**. remap 은 어떤 형태로도 넣지 않는다.
- **`objective.json` 의 스칼라를 하나도 바꾸지 않는다.** 바꾸는 것은 `generation` 문자열 하나뿐:
  `"2026-08-13-global-kappa-precedence"` → **`"2026-08-19-vocab-6-arms-hazard-on"`** (태스크 5).
- **어휘 도장** `"vocab": "v2-6arms"` · **동역학 도장** `"dynamics": "hazard-on"`.
  소비처는 도장 불일치 시 **조용히 remap 하지 말고 죽는다.** 도장 없는 파일(구세대)도 거부한다.
- **`s` 에 novelty·router 상태를 넣지 않는다**(spec §6.1). 그것은 meta-state 다.
- **`s` 의 모든 `Set`/`Dict` 는 정렬해서 직렬화한다**(spec §3.5 규칙 4). 불투명 객체
  (`MersenneTwister`·RVO 핸들)는 `s` 에 절대 넣지 않는다 — `ξ` 로 간다.
- **분모는 481**(선택지가 둘 이상인 결정: battery 338 + zone 143). 1438 로 나누면 957건의
  단일-팔 결정이 지표를 인위적으로 좋게 만든다(spec §1.4).
- **비교 런은 순차 실행.** 병렬이면 HiGHS 가 다른 스케줄을 내 비교가 무효 + 프로세스당 ~2.5GB 라 OOM.
- **스윕이 도는 동안 코드를 수정하지 않는다.** 샤드 도장이 갈린다.
- **게이트를 짤 때는 음성 대조를 먼저 실측한다.** "이 검사가 실패할 수 있는가"를 손으로 확인하기 전에는
  PASS 를 근거로 쓰지 않는다(2026-08-16 의 G2 사고: 그렙 대상 문자열이 stdout 에 한 번도 안 나왔다).
- **커밋은 자주.** 태스크마다 최소 한 번, 각 태스크의 마지막 단계가 커밋이다.

---

## File Structure

**신규 (Julia — MDP 계층):**

| 파일 | 책임 |
|---|---|
| `src/smdp/state_globals.jl` | 전역 인벤토리 — 이름 → 처분(`:state`/`:replay`/`:log`/`:setup`). 태스크 7 |
| `src/smdp/simstate.jl` | `SimState`·`ReplayState` 타입 · 정준 직렬화 · 콘텐츠 해시. 태스크 9 |
| `src/smdp/snapshot.jl` | `snapshot(env) -> (s, ξ)` · `restore!(env, s, ξ)`. 태스크 10·11 |
| `src/smdp/tplan.jl` | `T_plan(s)` — 스케줄 DAG longest path. 태스크 14 |

**신규 (Python — SMDP 게이트):**

| 파일 | 책임 |
|---|---|
| `wm4spacecraft_manufacturing/smdp/gate_gs.py` | G-S: 팔 간 `τ` 분산 vs 시드 간 분산. 태스크 0 |
| `wm4spacecraft_manufacturing/smdp/gate_g2.py` | G2: coupling — 팔을 바꾸면 다음 결정이 바뀌는가. 태스크 0 |
| `wm4spacecraft_manufacturing/smdp/boards.py` | 588 board 로더(두 게이트 공용). 태스크 0 |
| `wm4spacecraft_manufacturing/smdp/gate_g6.py` | G6: `f` 무솔버 불변식. 태스크 5 |
| `wm4spacecraft_manufacturing/smdp/gate_gm.py` | G-M: 같은 `hash(s)` 에서 `(s', τ)` 분포가 같은가. 태스크 13 |
| `wm4spacecraft_manufacturing/smdp/test_smdp_gates.py` | 위 전부의 단위검사(합성 입력). 태스크 0·5·13 |

**신규 (테스트 — Julia):**

`test/smdp_crn_smoke.jl`(태스크 2) · `test/respec_determinism_smoke.jl`(태스크 4) ·
`test/smdp_global_inventory.jl`(태스크 7) · `test/smdp_clock_smoke.jl`(태스크 8) ·
`test/smdp_simstate_smoke.jl`(태스크 9) · `test/smdp_snapshot_roundtrip.jl`(태스크 10·11·12) ·
`test/smdp_tplan_smoke.jl`(태스크 14)

**수정:**

| 파일 | 무엇 |
|---|---|
| `src/smdp/mdp.jl` | 신규 include 4개 추가 |
| `src/smdp/hazard.jl:507-521` | CRN 누수 — `drop` 뽑기를 안전 가드 뒤로/캐시로. 태스크 2 |
| `src/respec/ood_injection.jl:856-885` | `_pick_active_robot` 의 `Set` 순회 결정화. 태스크 4 |
| `src/respec/asset_ledger.jl:100` | `SIM_STEP` 을 시계 단일 진실원으로 승격. 태스크 8 |
| `tools/monitor/run_demo.jl:79,286-291,352,464,485,524-533,778,798,849-935` | 도장(태스크 1) · hazard 손잡이(3) · `ran_milp`(5) · `_SIM_STEP` 제거(8) · G-M 훅(13) |
| `wm4spacecraft_manufacturing/core/action_registry.json` | `vocab` 도장 + 3·5·6 은퇴 표식. 태스크 1·5 |
| `wm4spacecraft_manufacturing/core/action_registry.py` | `VOCAB`·`require_vocab()`·6팔 지원집합. 태스크 1·5 |
| `wm4spacecraft_manufacturing/oracle/action_registry.jl` | 위와 같은 계약의 Julia 쪽. 태스크 1·5 |
| `wm4spacecraft_manufacturing/core/objective.json` | `generation` bump **한 줄만**. 태스크 5 |
| `wm4spacecraft_manufacturing/core/wm_datasets.py` | `RELABEL_20260819`(742행) 등록. 태스크 6 |

---

## 태스크 0: G-S + G2 프록시 — **하드 게이트**. 재시뮬 없음

> **이 태스크가 이 계획 전체의 진짜 게이트다**(spec §11). `τ` 가 팔에 안 붙으면 SMDP 정식화
> 전체가 장식이고, coupling 이 없으면 상태에 carry-over 를 아무리 넣어도 장식이다.
> **둘 다 오늘, 기존 산출물만으로, 재시뮬 없이 잴 수 있다.**
>
> **중단 조건**: G-S 가 유의하지 않으면 **태스크 1로 넘어가지 않는다.** 결과를
> `wm4spacecraft_manufacturing/md/` 에 기록하고, 문제를 MDP(또는 contextual bandit)로
> 기술하도록 spec 을 개정한다.

**Files:**
- Create: `wm4spacecraft_manufacturing/smdp/boards.py`
- Create: `wm4spacecraft_manufacturing/smdp/gate_gs.py`
- Create: `wm4spacecraft_manufacturing/smdp/gate_g2.py`
- Test: `wm4spacecraft_manufacturing/smdp/test_smdp_gates.py`
- 읽기 전용 입력: `wm4spacecraft_manufacturing/dp_oracle/boards.jsonl`(588행) ·
  `wm4spacecraft_manufacturing/dp_oracle/_sample_work/<board_id>/rows.jsonl`(588 폴더, 2.4GB, gitignore)

**Interfaces:**
- Produces:
  - `boards.load_groups(work_dir, boards_path) -> dict[(case:str, seed:int), dict[arm_id:int, Board]]`
    where `Board = {"arm_name": str, "deviate_at": int, "crashed": bool, "complete": bool,
    "makespan": float, "decisions": list[dict]}`
  - `gate_gs.tau_at(board, k) -> tuple[float|None, bool]` — `(τ, censored)`
  - `gate_gs.block_permutation_p(tau_by_group, n_perm, seed) -> tuple[float, float, float]`
    — `(p_value, ss_arm_observed, ss_arm_null_median)`
  - `gate_g2.coupling_rate(groups) -> dict` — `{"n_groups": int, "n_eligible": int, "n_coupled": int, "rate": float}`

- [ ] **Step 1: 입력이 실제로 있는지 먼저 확인한다 (음성 대조의 전제)**

`_sample_work/` 는 gitignore 이고 2.4GB 다. 없으면 이 게이트는 **못 돈다** — 그 사실을 먼저
확인하고, 없으면 `sample_grid.py --manifest-only` 재생성이 선행 작업이 된다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
ls dp_oracle/_sample_work | wc -l          # 기대: 588 (또는 589 — . 포함 주의)
wc -l dp_oracle/boards.jsonl               # 기대: 588
ls dp_oracle/_sample_work/all_s10_a0/      # 기대: logs  rows.jsonl
```

기대: 세 줄 모두 값이 나온다. `_sample_work` 가 비어 있으면 **여기서 멈추고** 사용자에게
재표집(`python dp_oracle/sample_grid.py --keep-work`, ~수시간)이 필요하다고 보고한다.

- [ ] **Step 2: 로더의 실패 테스트를 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/test_smdp_gates.py
"""SMDP 게이트(G-S · G2 · G6 · G-M)의 단위검사. 합성 입력만 쓴다 —
2.4GB 짜리 _sample_work 없이도 돌아야 로직 회귀를 잡을 수 있다."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import boards  # noqa: E402
import gate_gs  # noqa: E402
import gate_g2  # noqa: E402


def _mk_board(tmp_path, board_id, decisions, makespan=100.0, crashed=False):
    d = tmp_path / board_id
    d.mkdir()
    row = {"makespan": makespan, "complete": True, "decisions": decisions}
    (d / "rows.jsonl").write_text(json.dumps(row) + "\n")
    return {"board_id": board_id, "case": board_id.split("_s")[0],
            "seed": int(board_id.split("_s")[1].split("_a")[0]),
            "arm_id": int(board_id.split("_a")[1]), "arm_name": "A%s" % board_id[-1],
            "deviate_at": 2, "deviation_fired": True, "crashed": crashed}


def _dec(i, t, macro, valid):
    return {"decision_index": i, "sim_t_at": t, "macro": macro,
            "valid": valid, "truth": "BatteryTruth", "at": int(t * 10)}


def test_load_groups_keys_by_case_seed(tmp_path):
    manifest = tmp_path / "boards.jsonl"
    recs = []
    for arm in (0, 1):
        recs.append(_mk_board(tmp_path, "battery_s1_a%d" % arm,
                              [_dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
                               _dec(2, 1.0, "Replace", ["NOOP", "Replace"]),
                               _dec(3, 2.0 + arm, "NOOP", ["NOOP", "Replace"])]))
    manifest.write_text("".join(json.dumps(r) + "\n" for r in recs))
    groups = boards.load_groups(str(tmp_path), str(manifest))
    assert list(groups.keys()) == [("battery", 1)]
    assert sorted(groups[("battery", 1)].keys()) == [0, 1]
    assert len(groups[("battery", 1)][0]["decisions"]) == 3
```

- [ ] **Step 3: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: **FAIL** — `ModuleNotFoundError: No module named 'boards'`.

- [ ] **Step 4: 로더를 구현한다**

```python
# wm4spacecraft_manufacturing/smdp/boards.py
"""588 board(= 1-step deviation 표집 판) 로더. G-S · G2 · G-M 이 공용으로 쓴다.

board_id 규약: "<case>_s<seed>_a<arm_id>"  (예: battery_s1_a0)
그룹 = (case, seed). 한 그룹 안의 board 들은 **deviate_at 결정 하나만 다르고 그 앞은
바이트 동일**하다 — 2026-08-17 결정성 게이트가 84그룹 전부에서 확인했다. 그래서 이 그룹이
"같은 s 에서 팔만 바꾼" 짝지은 비교의 단위가 된다.

⚠️ rows.jsonl 은 board 당 **한 줄**이고 그 안의 "decisions" 가 결정 리스트다.
"""
import json
import os

DEFAULT_WORK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "dp_oracle", "_sample_work")
DEFAULT_MANIFEST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "dp_oracle", "boards.jsonl")


def load_groups(work_dir=DEFAULT_WORK, boards_path=DEFAULT_MANIFEST, require_fired=True):
    """(case, seed) -> {arm_id: board_dict} 를 돌려준다.

    board_dict = {arm_name, deviate_at, crashed, complete, makespan, decisions}
    rows.jsonl 이 없는 board 는 조용히 빼지 않고 dropped 로 세어 stderr 로 알린다.
    """
    groups, dropped = {}, {"no_rows": 0, "not_fired": 0, "bad_json": 0}
    with open(boards_path) as fh:
        for line in fh:
            rec = json.loads(line)
            if require_fired and not rec.get("deviation_fired"):
                dropped["not_fired"] += 1
                continue
            path = os.path.join(work_dir, rec["board_id"], "rows.jsonl")
            if not os.path.exists(path):
                dropped["no_rows"] += 1
                continue
            try:
                with open(path) as rf:
                    row = json.loads(rf.readline())
            except (ValueError, OSError):
                dropped["bad_json"] += 1
                continue
            groups.setdefault((rec["case"], int(rec["seed"])), {})[int(rec["arm_id"])] = {
                "board_id": rec["board_id"],
                "arm_name": rec.get("arm_name"),
                "deviate_at": rec.get("deviate_at"),
                "crashed": bool(rec.get("crashed")),
                "complete": bool(row.get("complete")),
                "makespan": row.get("makespan"),
                "decisions": row.get("decisions") or [],
            }
    if any(dropped.values()):
        import sys
        print("[boards] dropped: %s" % dropped, file=sys.stderr)
    return groups


def decision_at(board, k):
    """decision_index == k 인 결정을 돌려준다(없으면 None). 1-based."""
    for d in board["decisions"]:
        if d.get("decision_index") == k:
            return d
    return None
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: `test_load_groups_keys_by_case_seed PASSED`.

- [ ] **Step 6: G-S 의 실패 테스트를 쓴다 — 양성 대조와 음성 대조를 둘 다**

`test_smdp_gates.py` 에 이어 붙인다:

```python
def test_tau_at_uses_next_decision():
    b = {"decisions": [_dec(1, 0.0, "NOOP", []), _dec(2, 1.5, "Replace", []),
                       _dec(3, 4.0, "NOOP", [])], "makespan": 9.0}
    assert gate_gs.tau_at(b, 2) == (2.5, False)


def test_tau_at_right_censors_on_last_decision():
    b = {"decisions": [_dec(1, 0.0, "NOOP", []), _dec(2, 1.5, "Replace", [])],
         "makespan": 9.0}
    tau, censored = gate_gs.tau_at(b, 2)
    assert censored is True and abs(tau - 7.5) < 1e-9


def test_permutation_detects_arm_effect():
    """양성 대조: 팔 id 가 τ 를 결정하면 p 가 작아야 한다."""
    tau = {("c", g): {a: 1.0 + a + 0.01 * g for a in range(4)} for g in range(20)}
    p, ss_obs, ss_null = gate_gs.block_permutation_p(tau, n_perm=400, seed=0)
    assert p < 0.01 and ss_obs > ss_null


def test_permutation_finds_nothing_when_tau_is_exogenous():
    """음성 대조: τ 가 그룹에만 의존하면 p 가 커야 한다. 이 검사가 없으면
    게이트가 '언제나 유의' 를 내는 항진명제인지 알 수 없다."""
    tau = {("c", g): {a: 3.0 + 0.5 * g for a in range(4)} for g in range(20)}
    p, _, _ = gate_gs.block_permutation_p(tau, n_perm=400, seed=0)
    assert p > 0.2
```

- [ ] **Step 7: 테스트가 실패하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: **FAIL** — `ModuleNotFoundError: No module named 'gate_gs'`.

- [ ] **Step 8: G-S 를 구현한다**

```python
# wm4spacecraft_manufacturing/smdp/gate_gs.py
"""G-S — semi-Markov 검사 (spec §7). 가장 싼 반증이라 가장 먼저 돈다.

묻는 것: **같은 s 에서 팔만 바꿨을 때 다음 epoch 까지의 τ 가 팔에 의존하는가.**
  의존한다 → F(τ|s,a) 가 진짜로 a 에 의존 → SMDP 구조가 결정에 정보를 나른다.
  의존 안 한다 → τ 는 외생. 형식적으로는 SMDP 지만 'τ 를 안 봐도 되는 SMDP' = 실질 MDP.
                그러면 spec §5 전체가 장식이므로 **여기서 멈추고 그렇게 쓴다.**

왜 블록 순열인가: 그룹(=case,seed)마다 τ 의 절대 수준이 크게 다르다. 그룹을 블록으로 잡고
**블록 안에서만** 팔 라벨을 섞으면 그룹 효과가 통제된 상태에서 팔 효과만 검정된다.
정규성·등분산을 가정하지 않는다.

  python gate_gs.py            # 기본 경로로 실측
"""
import random
import sys


def tau_at(board, k):
    """결정 k 에서 시작한 option 의 체류시간 τ 와 우측절단 여부.

    다음 결정이 있으면 τ = sim_t_at[k+1] - sim_t_at[k] (censored=False).
    없으면(=k 가 마지막 결정) τ = makespan - sim_t_at[k] (censored=True).
    k 결정 자체가 없으면 (None, False).
    """
    cur = nxt = None
    for d in board["decisions"]:
        if d.get("decision_index") == k:
            cur = d
        elif d.get("decision_index") == k + 1:
            nxt = d
    if cur is None or cur.get("sim_t_at") is None:
        return (None, False)
    if nxt is not None and nxt.get("sim_t_at") is not None:
        return (float(nxt["sim_t_at"]) - float(cur["sim_t_at"]), False)
    ms = board.get("makespan")
    if ms is None:
        return (None, False)
    return (float(ms) - float(cur["sim_t_at"]), True)


def _ss_arm(tau_by_group):
    """블록(그룹) 평균을 뺀 뒤의 팔별 평균 제곱합. 팔 효과의 크기."""
    centered = {}
    for gkey, per_arm in tau_by_group.items():
        if len(per_arm) < 2:
            continue
        mu = sum(per_arm.values()) / len(per_arm)
        for arm, t in per_arm.items():
            centered.setdefault(arm, []).append(t - mu)
    total = 0.0
    for vals in centered.values():
        if not vals:
            continue
        m = sum(vals) / len(vals)
        total += len(vals) * m * m
    return total


def block_permutation_p(tau_by_group, n_perm=2000, seed=0):
    """(p_value, 관측 SS_arm, 귀무분포 SS_arm 중앙값).

    귀무가설: τ 는 팔에 의존하지 않는다(그룹 안에서 팔 라벨이 교환가능).
    """
    rng = random.Random(seed)
    obs = _ss_arm(tau_by_group)
    null = []
    for _ in range(n_perm):
        shuffled = {}
        for gkey, per_arm in tau_by_group.items():
            arms = list(per_arm.keys())
            vals = list(per_arm.values())
            rng.shuffle(vals)
            shuffled[gkey] = dict(zip(arms, vals))
        null.append(_ss_arm(shuffled))
    null.sort()
    # +1/+1 보정: 순열검정의 표준(관측 자신을 귀무표본에 포함).
    ge = sum(1 for x in null if x >= obs)
    p = (ge + 1.0) / (n_perm + 1.0)
    return (p, obs, null[len(null) // 2])


def variance_ratio(tau_by_group):
    """(그룹 내 팔 간 분산의 평균) / (그룹 평균들의 분산). 효과크기 보고용."""
    within, means = [], []
    for per_arm in tau_by_group.values():
        if len(per_arm) < 2:
            continue
        vals = list(per_arm.values())
        mu = sum(vals) / len(vals)
        means.append(mu)
        within.append(sum((v - mu) ** 2 for v in vals) / (len(vals) - 1))
    if not within or len(means) < 2:
        return float("nan")
    gmu = sum(means) / len(means)
    between = sum((m - gmu) ** 2 for m in means) / (len(means) - 1)
    return (sum(within) / len(within)) / between if between > 0 else float("inf")


def collect(groups, drop_censored=True):
    """(tau_by_group, 진단 카운터). 뺀 것은 전부 센다 — 조용한 절단 금지."""
    tau_by_group, diag = {}, {"censored": 0, "missing": 0, "crashed": 0,
                              "groups_too_thin": 0, "boards_used": 0}
    for gkey, per_arm in groups.items():
        acc = {}
        for arm, board in per_arm.items():
            if board["crashed"]:
                diag["crashed"] += 1
                continue
            k = board.get("deviate_at")
            if k is None:
                diag["missing"] += 1
                continue
            t, censored = tau_at(board, k)
            if t is None:
                diag["missing"] += 1
                continue
            if censored:
                diag["censored"] += 1
                if drop_censored:
                    continue
            acc[arm] = t
            diag["boards_used"] += 1
        if len(acc) >= 2:
            tau_by_group[gkey] = acc
        else:
            diag["groups_too_thin"] += 1
    return tau_by_group, diag


def main(argv):
    import boards as _b
    groups = _b.load_groups()
    for drop in (True, False):
        tau, diag = collect(groups, drop_censored=drop)
        p, obs, null_med = block_permutation_p(tau, n_perm=2000, seed=0)
        ratio = variance_ratio(tau)
        label = "절단 제외" if drop else "절단 포함(makespan 까지)"
        print("=== G-S (%s) ===" % label)
        print("  그룹 %d개 / board %d개 사용" % (len(tau), diag["boards_used"]))
        print("  진단: %s" % diag)
        print("  분산비(팔 간 / 그룹 간) = %.4f" % ratio)
        print("  SS_arm 관측 %.4f · 귀무 중앙 %.4f · p = %.4f" % (obs, null_med, p))
        print("  판정: %s" % ("PASS — τ 가 팔에 의존한다 (SMDP)"
                              if p < 0.05 else
                              "FAIL — τ 가 외생이다. 여기서 멈추고 MDP 로 기술할 것"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 9: 테스트가 통과하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: 5건 전부 PASS. 특히 `test_permutation_finds_nothing_when_tau_is_exogenous` 가
**PASS 해야 한다** — 이것이 게이트의 음성 대조다.

- [ ] **Step 10: G2 의 실패 테스트를 쓴다**

```python
def test_coupling_counts_only_multi_option_decisions():
    """분모는 481 규약 — valid 가 2개 미만이면 그 결정은 세지 않는다.
    valid == [] 는 '제한 없음' 규약(policy.jl:413)이라 메뉴가 있는 게 아니다."""
    groups = {
        ("battery", 1): {
            0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
                _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
            1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "Replace", ["NOOP", "Replace"]),
                _dec(2, 1.0, "NOOP", ["NOOP", "Replace"])]},
        },
        ("fault", 2): {  # valid == [] → 분모에서 빠진다
            0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "NOOP", []), _dec(2, 1.0, "Replace", [])]},
            1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
                _dec(1, 0.0, "Replace", []), _dec(2, 1.0, "NOOP", [])]},
        },
    }
    out = gate_g2.coupling_rate(groups)
    assert out["n_eligible"] == 1
    assert out["n_coupled"] == 1
    assert abs(out["rate"] - 1.0) < 1e-9


def test_coupling_zero_when_next_decision_is_identical():
    groups = {("battery", 1): {
        0: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
            _dec(1, 0.0, "NOOP", ["NOOP", "Replace"]),
            _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
        1: {"crashed": False, "deviate_at": 1, "makespan": 9.0, "decisions": [
            _dec(1, 0.0, "Replace", ["NOOP", "Replace"]),
            _dec(2, 1.0, "Replace", ["NOOP", "Replace"])]},
    }}
    out = gate_g2.coupling_rate(groups)
    assert out["n_eligible"] == 1 and out["n_coupled"] == 0
```

- [ ] **Step 11: 테스트가 실패하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: **FAIL** — `ModuleNotFoundError: No module named 'gate_g2'`.

- [ ] **Step 12: G2 를 구현한다**

```python
# wm4spacecraft_manufacturing/smdp/gate_g2.py
"""G2 — coupling test (spec §7). 순차 결정 문제인가, contextual bandit 인가.

묻는 것: **같은 시드·같은 월드에서 결정 k 의 팔만 바꾸면 결정 k+1 의 선택이 바뀌는가.**
  유의하게 > 0 → 순차 결정 문제 성립.
  ≈ 0        → 정직하게 contextual bandit 이라고 쓴다.

⚠️ G2 와 G-S 는 다른 질문이다. G2 는 *순차인가*, G-S 는 *semi-Markov 인가*,
G-M 은 *Markov 인가* 를 잰다. 1차 개정이 이 셋을 하나로 뭉갰다.

분모 규약(spec §1.4): `valid` 리스트의 길이가 2 이상인 결정만 센다. `valid == []` 는
'제한 없음' 규약(policy.jl:413)이지 메뉴가 아니다 — 1438 로 나누면 957건의 단일-팔
결정이 자동으로 '결합 없음' 에 들어가 비율이 인위적으로 낮아진다.

  python gate_g2.py
"""
import sys


def _next_decision(board, k):
    for d in board["decisions"]:
        if d.get("decision_index") == k + 1:
            return d
    return None


def coupling_rate(groups):
    """{n_groups, n_eligible, n_coupled, rate, dropped}."""
    n_eligible = n_coupled = 0
    dropped = {"crashed": 0, "no_next": 0, "single_option": 0, "thin": 0}
    per_case = {}
    for (case, _seed), per_arm in groups.items():
        macros, eligible = {}, False
        for arm, board in per_arm.items():
            if board["crashed"]:
                dropped["crashed"] += 1
                continue
            k = board.get("deviate_at")
            nxt = _next_decision(board, k) if k is not None else None
            if nxt is None:
                dropped["no_next"] += 1
                continue
            if len(nxt.get("valid") or []) < 2:
                dropped["single_option"] += 1
                continue
            eligible = True
            macros[arm] = nxt.get("macro")
        if not eligible or len(macros) < 2:
            dropped["thin"] += 1
            continue
        n_eligible += 1
        coupled = len(set(macros.values())) > 1
        n_coupled += int(coupled)
        c = per_case.setdefault(case, [0, 0])
        c[0] += 1
        c[1] += int(coupled)
    return {"n_groups": len(groups), "n_eligible": n_eligible, "n_coupled": n_coupled,
            "rate": (n_coupled / n_eligible) if n_eligible else float("nan"),
            "dropped": dropped, "per_case": per_case}


def main(argv):
    import boards as _b
    out = coupling_rate(_b.load_groups())
    print("=== G2 coupling (분모 = 선택지 2개 이상인 결정) ===")
    print("  그룹 %d · 자격 %d · 결합 %d · 비율 %.3f"
          % (out["n_groups"], out["n_eligible"], out["n_coupled"], out["rate"]))
    print("  제외: %s" % out["dropped"])
    for case, (n, c) in sorted(out["per_case"].items()):
        print("    %-14s %3d/%3d" % (case, c, n))
    print("  판정: %s" % ("PASS — 순차 결정 문제 성립"
                          if out["n_eligible"] and out["rate"] > 0.0 else
                          "FAIL — contextual bandit 으로 기술할 것"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 13: 테스트가 통과하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: 7건 전부 PASS.

- [ ] **Step 14: 실측을 돌린다 — 이것이 게이트다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
../../.venv/bin/python gate_gs.py 2>&1 | tee /tmp/gs.txt
../../.venv/bin/python gate_g2.py 2>&1 | tee /tmp/g2.txt
```

**판정 규칙:**
- G-S 가 `p < 0.05` 이고 분산비 > 1 → **PASS. 태스크 1로 간다.**
- G-S 가 `p >= 0.05` → **여기서 멈춘다.** 결과를 `wm4spacecraft_manufacturing/md/README.md`
  에 절로 추가하고, spec 을 "이 문제는 실질 MDP 다"로 개정하는 것을 사용자에게 보고한다.
  **태스크 1~14 를 실행하지 않는다.**
- G2 의 `rate ≈ 0` → SMDP 형식은 유지하되 논문에서 **contextual bandit** 이라고 정직하게
  적는다(spec §7). 태스크는 계속 진행한다(상태 정의 자체는 여전히 필요하다).
- 절단 포함/제외 두 판정이 **엇갈리면 PASS 로 읽지 않는다** — 그건 절단 처리가 결론을
  만들고 있다는 뜻이다. 그 경우 두 수치를 모두 보고하고 사용자 판단을 받는다.

- [ ] **Step 15: 결과를 기록하고 커밋한다**

```bash
cd /home/chahj578/Construction_OODlayer
mkdir -p wm4spacecraft_manufacturing/measurements
cp /tmp/gs.txt wm4spacecraft_manufacturing/measurements/gate_gs_2026-08-19.txt
cp /tmp/g2.txt wm4spacecraft_manufacturing/measurements/gate_g2_2026-08-19.txt
git add wm4spacecraft_manufacturing/smdp wm4spacecraft_manufacturing/measurements
git commit -m "feat(smdp): G-S/G2 게이트 — 재시뮬 없이 588 board 로 semi-Markov·coupling 을 잰다"
```

---

## 태스크 1: 어휘 도장 · 동역학 도장 — hazard 를 켜기 **전에**

> 순서가 중요하다(spec §11-1). 도장을 나중에 넣으면 **도장 없는 신세대 파일이 먼저 생긴다.**
> 그리고 `audit_action_vocab.py` 가 2026-08-18 정리에서 삭제돼 **지금 어휘 동기화에 기계 감시가
> 하나도 없다** — 이 도장이 그 자리를 메운다.
>
> 왜 해시로 안 되는가: `objective_hash` 는 목적함수의 스칼라를 도장한다. 어휘도 동역학도
> 목적함수가 아니므로 **해시가 안 갈릴 수 있다**. dp `value.json` 세대 누수가 정확히 그
> 실패 모양이었다(해시는 같고 갈린 것은 코드 세대).

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/action_registry.json` (최상위 `"vocab"` 필드 추가)
- Modify: `wm4spacecraft_manufacturing/core/action_registry.py` (`VOCAB` · `require_vocab`)
- Modify: `wm4spacecraft_manufacturing/oracle/action_registry.jl` (`VOCAB` · `require_vocab`)
- Modify: `src/mdp/hazard.jl` (`dynamics_stamp()` 추가, `hazard_enabled()` 바로 아래)
- Modify: `tools/monitor/run_demo.jl:915-935` (DEMO_SUMMARY 레코드에 두 도장 기입)
- Test: `wm4spacecraft_manufacturing/smdp/test_stamps.py` · `test/mdp_stamp_smoke.jl`

**Interfaces:**
- Produces:
  - `action_registry.VOCAB -> str` (현재 `"v2-6arms"`)
  - `action_registry.require_vocab(obj: dict, where: str) -> None` — `obj["vocab"]` 이 없거나
    `VOCAB` 과 다르면 `ValueError` 를 던진다. **절대 remap 하지 않는다.**
  - `ActionRegistry.VOCAB::String` · `ActionRegistry.require_vocab(d, where)` — 불일치 시 `error()`
  - `ConstructionBots.dynamics_stamp() -> String` — `"hazard-on"` | `"hazard-off"`
- Consumes: 없음(첫 배선 태스크).

- [ ] **Step 1: 실패 테스트를 쓴다 — 음성 대조가 본체다**

```python
# wm4spacecraft_manufacturing/smdp/test_stamps.py
"""도장 계약의 단위검사. **핵심은 음성 대조다** — 도장이 없거나 다른 파일을 읽으면
정말로 죽는가. 죽지 않으면 이 게이트는 영원히 실패할 수 없는 검사이고, 그런 검사는
2026-08-16 에 실제로 하나 만들어 봤다(그렙 대상 문자열이 stdout 에 한 번도 안 나왔다)."""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import action_registry  # noqa: E402


def test_vocab_constant_is_declared():
    assert action_registry.VOCAB == "v2-6arms"


def test_require_vocab_accepts_matching_stamp():
    action_registry.require_vocab({"vocab": "v2-6arms"}, "테스트")


def test_require_vocab_dies_on_missing_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"objective_hash": "19819377a7f8ebb2"}, "구세대 파일")
    assert "vocab" in str(e.value)


def test_require_vocab_dies_on_stale_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"vocab": "v1-9arms"}, "구세대 파일")
    assert "v1-9arms" in str(e.value)


def test_require_dynamics_dies_on_mismatch():
    action_registry.require_dynamics({"dynamics": "hazard-on"}, "hazard-on", "신세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({"dynamics": "hazard-off"}, "hazard-on", "구세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({}, "hazard-on", "도장 없음")
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_stamps.py -v
```
기대: 5건 전부 **FAIL** — `AttributeError: module 'action_registry' has no attribute 'VOCAB'`.

- [ ] **Step 3: JSON 에 도장을 넣는다**

`wm4spacecraft_manufacturing/core/action_registry.json` 의 `"macros"` **앞에** 한 줄:

```json
  "vocab": "v2-6arms",
  "macros": {
```

- [ ] **Step 4: Python 로더에 계약을 넣는다**

`wm4spacecraft_manufacturing/core/action_registry.py` 의 `MACROS = sorted(REGISTRY)` 바로 뒤에
붙인다:

```python
# ---- 어휘 도장 (2026-08-19, spec §2.4·§8) ---------------------------------------------------
# 왜 objective_hash 로 안 되는가: 해시는 목적함수의 스칼라를 도장한다. 어휘는 목적함수가
# 아니므로 어휘만 바뀌면 해시가 안 갈릴 수 있고, 실제로 dp value.json 에서 그 맹점이 발화했다.
# 도장은 그 축을 따로 잡는다. **소비처는 불일치 시 조용히 remap 하지 말고 죽는다** —
# remap 하면 구세대 macro 3(ForbidZone) 행이 4(ReformTeam) 로 에러 없이 재해석된다.
VOCAB = json.load(open(REGISTRY_PATH, encoding="utf-8")).get("vocab")
if not VOCAB:
    raise ValueError("action_registry.json 에 'vocab' 도장이 없다: %s" % REGISTRY_PATH)


def require_vocab(obj, where):
    """산출물 dict 의 어휘 도장을 대조한다. 없거나 다르면 ValueError."""
    got = obj.get("vocab") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError(
            "%s: 어휘 도장('vocab')이 없다 — 구세대 파일이다. 현행은 %r. "
            "remap 하지 않는다(구 macro 3/5/6 은 영구 결번)." % (where, VOCAB))
    if got != VOCAB:
        raise ValueError(
            "%s: 어휘 도장 불일치 — 파일 %r vs 현행 %r." % (where, got, VOCAB))


def require_dynamics(obj, expected, where):
    """동역학 도장을 대조한다. hazard on/off 는 objective_hash 로 못 잡는 별도 축이다."""
    got = obj.get("dynamics") if hasattr(obj, "get") else None
    if got is None:
        raise ValueError("%s: 동역학 도장('dynamics')이 없다 — 구세대 파일이다. 기대 %r."
                         % (where, expected))
    if got != expected:
        raise ValueError("%s: 동역학 도장 불일치 — 파일 %r vs 기대 %r." % (where, got, expected))
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_stamps.py -v
```
기대: 5건 전부 PASS.

- [ ] **Step 6: Julia 쪽 실패 테스트를 쓴다**

```julia
# test/mdp_stamp_smoke.jl
# 도장 계약의 Julia 쪽. Python 과 **같은 문자열**을 읽는지, 그리고 도장 없는 입력에서
# 정말 죽는지(음성 대조)를 본다.
#   julia +lts --project=. test/mdp_stamp_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))
include(joinpath(@__DIR__, "..", "wm4spacecraft_manufacturing", "oracle", "action_registry.jl"))

@testset "어휘 도장" begin
    @test ActionRegistry.VOCAB == "v2-6arms"
    @test ActionRegistry.require_vocab(Dict("vocab" => "v2-6arms"), "ok") === nothing
    @test_throws ErrorException ActionRegistry.require_vocab(Dict{String,Any}(), "도장 없음")
    @test_throws ErrorException ActionRegistry.require_vocab(Dict("vocab" => "v1-9arms"), "구세대")
end

@testset "동역학 도장" begin
    CB.disable_hazard!()
    @test CB.dynamics_stamp() == "hazard-off"
end
```

- [ ] **Step 7: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_stamp_smoke.jl
```
기대: **FAIL** — `UndefVarError: VOCAB not defined`.

- [ ] **Step 8: Julia 로더와 `dynamics_stamp()` 를 구현한다**

`wm4spacecraft_manufacturing/oracle/action_registry.jl` 의 `const COST = ...` 뒤에:

```julia
# ---- 어휘 도장 (2026-08-19, spec §2.4·§8) ---------------------------------------------------
# `action_registry.py:VOCAB` 과 **같은 JSON 필드**를 읽는다. 두 언어가 같은 파일을 보므로
# 복붙 리터럴이 생기지 않는다.
const VOCAB = haskey(_RAW, :vocab) ? String(_RAW.vocab) :
    error("action_registry.json 에 'vocab' 도장이 없다: $(PATH)")

"""
    require_vocab(obj, where)

산출물의 어휘 도장을 대조한다. 없거나 다르면 **죽는다** — 조용히 remap 하지 않는다.
remap 하면 구세대 macro 3(`ForbidZone`) 행이 4(`ReformTeam`) 로 에러 없이 재해석된다.
"""
function require_vocab(obj, where::AbstractString)
    got = try obj["vocab"] catch; nothing end
    got === nothing && error("$(where): 어휘 도장('vocab')이 없다 — 구세대 파일이다. 현행은 $(VOCAB).")
    String(got) == VOCAB || error("$(where): 어휘 도장 불일치 — 파일 $(got) vs 현행 $(VOCAB).")
    return nothing
end
```

`src/mdp/hazard.jl` 의 `hazard_enabled() = ...`(현 `:152`) 바로 아래:

```julia
"""
    dynamics_stamp() -> String

동역학 세대 도장(spec §8). hazard 를 켜면 `objective.json` 은 안 바뀌므로 `objective_hash`
로는 이 축이 안 잡힌다 — dp `value.json` 누수와 정확히 같은 실패 모양이다. 그래서 별도 도장.
"""
dynamics_stamp() = hazard_enabled() ? "hazard-on" : "hazard-off"
```

- [ ] **Step 9: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_stamp_smoke.jl
```
기대: 두 testset 모두 PASS, 실패 0.

- [ ] **Step 10: 산출 레인에 도장을 찍는다**

`tools/monitor/run_demo.jl` 의 DEMO_SUMMARY 레코드(현 `:920-921`, `"objective_hash"` 줄 옆)에
두 줄을 더한다:

```julia
            "objective_hash" => OBJ_HASH,
            "energy_objective" => (ENERGY_ON ? 1 : 0),
            # 어휘·동역학은 objective_hash 가 표현하지 못하는 축이다(spec §8). 해시가 같은데
            # 세대가 갈리는 사고를 dp value.json 에서 이미 한 번 냈다 — 그때 쓸 수 있었던
            # 신호는 shards_dp 디렉토리 존재 여부뿐이었다. 이번엔 도장으로 닫는다.
            "vocab"     => ActionRegistry.VOCAB,
            "dynamics"  => CB.dynamics_stamp(),
```

`run_demo.jl` 이 아직 `ActionRegistry` 를 로드하지 않으면 `OBJ_HASH` 정의부(현 `:532`) 근처에
`include(joinpath(WM, "oracle", "action_registry.jl"))` 를 추가한다 — 경로는 그 파일이 이미
`Objective` 를 include 하는 방식과 **같은 관례**를 따를 것(리터럴 경로 새로 만들지 말 것).

- [ ] **Step 11: 도장이 실제로 산출물에 찍히는지 실측한다 (음성 대조 포함)**

```bash
cd /home/chahj578/Construction_OODlayer
DEMO_SUMMARY=/tmp/stamp_probe.jsonl OOD_SEED=1 DEMO_CASE=battery \
  julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tail -5
python3 -c "
import json
r=json.loads(open('/tmp/stamp_probe.jsonl').readline())
print('vocab   =', r.get('vocab'))
print('dynamics=', r.get('dynamics'))
assert r.get('vocab')=='v2-6arms', '어휘 도장이 안 찍혔다'
assert r.get('dynamics')=='hazard-off', '동역학 도장이 안 찍혔다(아직 hazard off 가 맞다)'
print('OK')
"
```
기대: `OK`. **음성 대조**: `results_4pol/shards/all/s11/rows.jsonl` 의 첫 행에는 두 필드가
**없어야 한다**(구세대). 있으면 도장이 무의미하다:
```bash
python3 -c "
import json; r=json.loads(open('wm4spacecraft_manufacturing/results_4pol/shards/all/s11/rows.jsonl').readline())
assert 'vocab' not in r and 'dynamics' not in r, '구세대 파일에 도장이 있다 — 음성 대조 실패'
print('음성 대조 OK: 구세대 파일은 도장이 없다')
"
```

- [ ] **Step 12: 커밋**

```bash
git add wm4spacecraft_manufacturing/core/action_registry.json \
        wm4spacecraft_manufacturing/core/action_registry.py \
        wm4spacecraft_manufacturing/oracle/action_registry.jl \
        wm4spacecraft_manufacturing/smdp/test_stamps.py \
        src/mdp/hazard.jl tools/monitor/run_demo.jl test/mdp_stamp_smoke.jl
git commit -m "feat(vocab): 어휘 도장 v2-6arms + 동역학 도장 — 불일치면 remap 하지 않고 죽는다"
```

---

## 태스크 2: CRN 누수 수정 — hazard 를 켜기 **전에** (spec §5.7)

> `_hz_fire_cell!` 이 **안전 조건을 검사하기 전에** 그 로봇의 스트림에서 `drop` 을 뽑는다.
> 유예되면 그 뽑기는 소비된 채 버려지고, 팔이 `_hz_safe_target` 의 결과를 바꾸면
> **그 로봇 스트림의 뽑기 횟수가 팔마다 달라져 이후 모든 난수가 어긋난다.**
> CRN 주석이 경고한 실패 모양이 로봇별 스트림 **안에서** 재발한 것이다.
>
> 지금은 `HAZARD_ENABLED=false` 라 발화 안 하지만 **켜는 순간 K-rollout 의 분산감소가
> 조용히 사라진다.** 그래서 태스크 3(hazard on)보다 먼저 고친다.

**Files:**
- Modify: `src/mdp/hazard.jl:126-146` (`HazardState` 에 `pending_drop` 필드) ·
  `:203-216` (`_new_hazard_state`) · `:507-536` (`_hz_fire_cell!`)
- Test: `test/mdp_crn_smoke.jl`

**Interfaces:**
- Consumes: `ConstructionBots._new_hazard_state(params, seed)` · `CB._robot_rng(st, id)` ·
  `CB._hz_fire_cell!(env, st, id, soc, mode)` (태스크 1 이후 파일 상태)
- Produces: `HazardState.pending_drop::Dict{Any,Float64}` — 유예된 셀 사건의 이미 뽑힌 낙폭.
  발화가 실제로 성사되면 그 키를 지운다.

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_crn_smoke.jl
# CRN(공통난수) 무결성. spec §5.7 이 지목한 누수: _hz_fire_cell! 이 안전 가드보다 **먼저**
# drop 을 뽑아서, 유예되면 그 뽑기가 소비된 채 버려진다. 팔마다 유예 여부가 다르면 그
# 로봇 스트림의 뽑기 횟수가 갈리고, 이후 모든 난수가 어긋나 짝지은 비교가 무너진다.
#
#   julia +lts --project=. test/mdp_crn_smoke.jl
using ConstructionBots
using Test
using Random
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

_mk(; seed = 0, kw...) = CB._new_hazard_state(CB.HazardParams(; kw...), seed)

@testset "유예는 로봇 스트림을 소비하지 않는다" begin
    # 같은 시드로 상태 둘을 만들고, 한쪽에서만 셀 사건이 한 번 유예되게 한다.
    # 유예 뒤 두 스트림에서 각각 뽑은 수열이 같아야 CRN 이 살아 있는 것이다.
    st_a = _mk(seed = 7)
    st_b = _mk(seed = 7)
    rid = 101

    # 유예 경로를 직접 태운다: BATTERY_FLEET 가 nothing 이면 조기 반환이라 뽑기 전에 나간다.
    # 그래서 낙폭 캐시 자체를 검사한다 — 두 번 부르면 캐시가 재사용돼 뽑기가 한 번만 일어난다.
    d1 = CB._hz_draw_cell_drop!(st_a, rid)
    d2 = CB._hz_draw_cell_drop!(st_a, rid)      # 유예 후 재시도 — 같은 낙폭이어야 한다
    @test d1 == d2

    # 한 번만 뽑은 st_b 와 스트림 위치가 같아야 한다(= 재시도가 스트림을 안 먹었다).
    _ = CB._hz_draw_cell_drop!(st_b, rid)
    @test rand(CB._robot_rng(st_a, rid)) == rand(CB._robot_rng(st_b, rid))
end

@testset "발화가 성사되면 캐시가 비워진다" begin
    st = _mk(seed = 11)
    rid = 202
    d1 = CB._hz_draw_cell_drop!(st, rid)
    @test haskey(st.pending_drop, rid)
    CB._hz_commit_cell_drop!(st, rid)
    @test !haskey(st.pending_drop, rid)
    d2 = CB._hz_draw_cell_drop!(st, rid)        # 다음 사건은 새로 뽑는다
    @test d2 isa Float64
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_crn_smoke.jl
```
기대: **FAIL** — `UndefVarError: _hz_draw_cell_drop! not defined`.

- [ ] **Step 3: `HazardState` 에 캐시 필드를 넣는다**

`src/mdp/hazard.jl` 의 struct 마지막 필드(`zone_ct::Int`) 앞에:

```julia
    pending_drop::Dict{Any,Float64} # 유예된 셀 사건의 **이미 뽑힌** 낙폭 (spec §5.7 CRN 누수)
```

`_new_hazard_state`(현 `:203`)의 생성자 인자에서 `NamedTuple[], 0` 을
`NamedTuple[], Dict{Any,Float64}(), 0` 으로 바꾼다 — 필드 순서와 정확히 맞출 것.

- [ ] **Step 4: 뽑기를 함수로 빼고 캐시를 태운다**

`src/mdp/hazard.jl` 의 `_hz_fire_cell!` 바로 위에 두 헬퍼를 넣는다:

```julia
# --- CRN 누수 수정 (spec §5.7) -------------------------------------------------------------
# 원래 코드는 안전 가드보다 **먼저** rand 를 불렀고, 가드가 유예시키면 그 뽑기가 버려졌다.
# 가드가 낙폭에 의존하므로(깊은 방전인가?) 가드를 앞으로 옮길 수는 없다 — 그래서 **캐시**한다.
# 유예 중에는 같은 낙폭을 재사용하고, 사건이 실제로 성사된 순간에만 캐시를 비운다.
# 그 결과 로봇 r 의 "n 번째 셀 사건"은 어느 팔에서든 같은 낙폭을 갖는다(= CRN 이 산다).
function _hz_draw_cell_drop!(st::HazardState, id)
    haskey(st.pending_drop, id) && return st.pending_drop[id]
    p = st.params
    rng = _robot_rng(st, id)
    drop = rand(rng) < p.cell_severe_frac ? p.cell_severe_drop :
           (p.cell_mild_lo + (p.cell_mild_hi - p.cell_mild_lo) * rand(rng))
    st.pending_drop[id] = drop
    return drop
end

_hz_commit_cell_drop!(st::HazardState, id) = (delete!(st.pending_drop, id); nothing)
```

`_hz_fire_cell!` 본문의 다섯 줄

```julia
    rng = _robot_rng(st, id)
    drop = rand(rng) < p.cell_severe_frac ? p.cell_severe_drop :
           (p.cell_mild_lo + (p.cell_mild_hi - p.cell_mild_lo) * rand(rng))
```

를 다음으로 바꾼다:

```julia
    drop = _hz_draw_cell_drop!(st, id)      # 유예되면 같은 값을 재사용한다(CRN, spec §5.7)
```

그리고 발화가 성사되는 자리(`st.cum_cell[id] = 0.0` 바로 앞)에 한 줄 더한다:

```julia
    _hz_commit_cell_drop!(st, id)           # 사건이 실제로 났다 → 다음 사건은 새로 뽑는다
    st.cum_cell[id] = 0.0
    st.thr_cell[id] = _exp1(_robot_rng(st, id))
```

⚠️ `thr_cell` 재장전이 `rng` 지역변수를 쓰고 있었으므로 `_robot_rng(st, id)` 로 바꿔야 한다
(위에서 `rng` 정의를 지웠다). 같은 스트림이므로 동작은 동일하다.

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_crn_smoke.jl
```
기대: 두 testset PASS.

- [ ] **Step 6: 기존 hazard 검사가 회귀하지 않았는지 본다**

```bash
julia +lts --project=. test/mdp_hazard_smoke.jl
```
기대: 이전과 같은 결과(전부 PASS). `_new_hazard_state` 를 공유하므로 필드 추가로 안 깨진다 —
그게 그 헬퍼가 존재하는 이유다.

- [ ] **Step 7: 커밋**

```bash
git add src/mdp/hazard.jl test/mdp_crn_smoke.jl
git commit -m "fix(hazard): 유예된 셀 사건이 로봇 스트림을 먹는 CRN 누수 (spec §5.7)"
```

---

## 태스크 3: hazard 레인을 켜고 **실제로 도는지** 확인한다 (spec §11-2, L6)

> 🔴 **이 레인은 스윕으로 검증된 적이 없다.** `HAZARD_ENABLED` 가 기본 false 이고 현행 630판이
> 그 레인으로 안 돌았다. spec §1.6 의 "코드가 존재한다"는 사실이 "돈다"를 뜻하지 않는다.
> **안 돌면 그 수리가 이 계획의 첫 실제 작업이 된다** — 그 경우 이 태스크를 수리로 확장하고
> 태스크 4로 넘어가지 않는다.
>
> 🔴 **동역학 세대가 갈린다.** 이 태스크 이후의 산출물은 `"dynamics": "hazard-on"` 이고
> 태스크 1의 도장이 그것을 나른다. `objective_hash` 로는 안 잡힌다.

**Files:**
- Modify: `tools/monitor/run_demo.jl` (배터리 손잡이 블록 **뒤**, `set_battery_courier!` 다음)
- Create: `wm4spacecraft_manufacturing/smdp/probe_hazard.py` (발화율 집계)
- Test: 기존 `test/mdp_hazard_smoke.jl` (회귀 확인용, 수정 없음)

**Interfaces:**
- Consumes: `CB.enable_hazard!(env; params, seed, install)` · `CB.hazard_report()` ·
  `CB.dynamics_stamp()` (태스크 1) · `CB.expected_hazard_events(st, horizon_s; ...)`
- Produces: ENV 손잡이 `DEMO_HAZARD`(기본 `"0"`) · `DEMO_HAZARD_SEED` ·
  DEMO_SUMMARY 레코드의 `"hazard"` 블록 `{enabled, n_break, n_cell, n_zone, t, steps}`

- [ ] **Step 1: hazard 를 켜는 손잡이를 넣는다**

`tools/monitor/run_demo.jl` 의 `CB.set_battery_courier!(...)` 호출 **바로 뒤**에:

```julia
# ── 확률적 고장 프로세스 (src/mdp/hazard.jl, spec §11-2) ───────────────────────────────
# 🔴 이 손잡이는 **동역학 세대를 가른다.** 켜면 경쟁위험 점과정이 매 스텝 돌면서 고장·셀열화·
#    zone 을 정확표집으로 발화시킨다(스텝당 베르누이 근사 아님). objective.json 은 안 바뀌므로
#    objective_hash 로는 이 축이 안 잡힌다 — dynamics_stamp() 가 그 자리를 메운다(spec §8).
# ⚠️ enable_battery! **뒤**에 불러야 한다. SoC 연동(β_s·(1−soc))이 이 프로세스의 요점이고,
#    DRAIN_FACTOR_HOOK 도 배터리 계층이 있어야 걸린다.
# ⚠️ 시드는 world_seed 와 **분리한다.** 같이 쓰면 hazard 를 켜고 끄는 것이 배정까지 흔들어
#    "hazard 단독 대조군" 이 성립하지 않는다.
if get(ENV, "DEMO_HAZARD", "0") == "1"
    CB.include(joinpath(pkgdir(CB), "src", "mdp", "mdp.jl"))
    local hz_seed = try parse(Int, get(ENV, "DEMO_HAZARD_SEED", string(DEMO_SEED))) catch; DEMO_SEED end
    CB.enable_hazard!(env; seed = hz_seed)
    println(">>> hazard: ON (seed=", hz_seed, ")  dynamics=", CB.dynamics_stamp())
else
    println(">>> hazard: OFF  dynamics=", CB.dynamics_stamp())
end
```

DEMO_SUMMARY 레코드(태스크 1에서 도장을 넣은 자리)에 진단 블록을 더한다:

```julia
            "hazard" => (try
                let r = CB.hazard_report()
                    Dict("enabled" => true, "t" => r.t, "steps" => r.steps,
                         "n_break" => r.n_break, "n_cell" => r.n_cell, "n_zone" => r.n_zone)
                end
            catch
                Dict("enabled" => false)
            end),
```

- [ ] **Step 2: 한 판을 hazard on 으로 돌린다 — 켜지는가**

```bash
cd /home/chahj578/Construction_OODlayer
DEMO_HAZARD=1 DEMO_SUMMARY=/tmp/hz_on.jsonl OOD_SEED=1 DEMO_CASE=fault \
  julia +lts --project=. tools/monitor/run_demo.jl 2>&1 | tee /tmp/hz_on.log | tail -20
grep -c "HAZARD" /tmp/hz_on.log || true
```
기대: `>>> hazard: ON (seed=...)  dynamics=hazard-on` 이 찍히고 판이 **끝까지 돈다**.
크래시하면 **여기가 이 계획의 첫 실제 작업**이다 — 스택트레이스를 그대로 보고하고,
superpowers:systematic-debugging 으로 넘어간다.

- [ ] **Step 3: 발화율 집계기를 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/probe_hazard.py
"""hazard 레인이 **실제로 발화하는가** (spec §11-2 게이트 · L6).

  '구현돼 있다' 와 '돈다' 는 다르다. HAZARD_ENABLED 가 기본 false 이고 현행 630판이 이
  레인으로 안 돌았으므로, 켠 뒤 첫 질문은 성능이 아니라 **발화율**이다.

  python probe_hazard.py /tmp/hz_on.jsonl [/tmp/hz_off.jsonl]
"""
import json
import sys


def summarize(path):
    n, on, ev = 0, 0, {"n_break": 0, "n_cell": 0, "n_zone": 0}
    stamps, steps = set(), 0
    with open(path) as fh:
        for line in fh:
            r = json.loads(line)
            n += 1
            stamps.add(r.get("dynamics"))
            h = r.get("hazard") or {}
            if h.get("enabled"):
                on += 1
                for k in ev:
                    ev[k] += int(h.get(k) or 0)
                steps += int(h.get("steps") or 0)
    return {"path": path, "n_runs": n, "n_hazard_on": on, "events": ev,
            "steps": steps, "dynamics_stamps": sorted(x for x in stamps if x)}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for p in argv[1:]:
        s = summarize(p)
        print("=== %s ===" % s["path"])
        print("  판 %d · hazard on %d · 스텝 합 %d" % (s["n_runs"], s["n_hazard_on"], s["steps"]))
        print("  발화: %s" % s["events"])
        print("  동역학 도장: %s" % s["dynamics_stamps"])
        if s["n_hazard_on"] and sum(s["events"].values()) == 0:
            print("  🔴 hazard 는 켜졌는데 발화가 0건이다 — 파라미터가 이 지평선에 안 맞거나 "
                  "훅이 안 걸렸다. expected_hazard_events 로 기대값을 먼저 재라.")
        if len(s["dynamics_stamps"]) > 1:
            print("  🔴 한 파일에 동역학 세대가 둘 이상 섞여 있다.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: 발화율을 실측한다 — on/off 대조**

```bash
cd /home/chahj578/Construction_OODlayer
for s in 1 2 3 4 5; do
  DEMO_HAZARD=1 DEMO_SUMMARY=/tmp/hz_on.jsonl OOD_SEED=$s DEMO_CASE=fault \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
  DEMO_HAZARD=0 DEMO_SUMMARY=/tmp/hz_off.jsonl OOD_SEED=$s DEMO_CASE=fault \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
done
cd wm4spacecraft_manufacturing/smdp && ../../.venv/bin/python probe_hazard.py /tmp/hz_on.jsonl /tmp/hz_off.jsonl
```
⚠️ **순차 실행**(Global Constraints). 병렬이면 HiGHS 가 다른 스케줄을 낸다.

기대:
- `hz_on.jsonl`: `n_hazard_on == 5`, 동역학 도장 `["hazard-on"]`, **발화 합 > 0**
- `hz_off.jsonl`: `n_hazard_on == 0`, 도장 `["hazard-off"]` — 이것이 음성 대조다
- 발화가 0건이면 `expected_hazard_events` 로 기대값을 먼저 재고, 파라미터 캘리브레이션은
  **이 계획의 범위 밖**(spec §10)이므로 수치를 기록하고 사용자에게 보고한다.

- [ ] **Step 5: `cum_*` 적분이 실제로 자라는지 본다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. -e '
import ConstructionBots as CB
CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "mdp", "mdp.jl"))
st = CB._new_hazard_state(CB.HazardParams(), 0)
println("horizon 300s 기대 사건수: ", CB.expected_hazard_events(st, 300.0; n_robots = 10))
'
```
기대: `n_break`/`n_cell`/`n_zone` 기대값이 출력된다. 이 수가 Step 4 의 실측 발화율과
**자릿수 이상 어긋나면** 훅이 안 걸린 것이다(파라미터 문제가 아니다).

- [ ] **Step 6: G3 — τ 분리율을 재확인한다 (spec §7)**

C3(`F_xay(0) < 1`)의 실측이다. 현행 4pol 스윕은 이미 분리돼 있었다(step 58→109→177→219).
**hazard on + 어휘 축소 후에도 그런지**를 여기서 다시 본다 — 결정이 같은 시각에 몰리면
sojourn 이 0 에 질량을 갖고 SMDP 형식이 깨진다.

```bash
cd /home/chahj578/Construction_OODlayer
python3 -c "
import json,glob,statistics
taus=[]; zero=0; n=0
for p in glob.glob('/tmp/hz_on.jsonl'):
    for line in open(p):
        ds=json.loads(line).get('decisions') or []
        ts=[d['sim_t_at'] for d in ds if d.get('sim_t_at') is not None]
        for a,b in zip(ts, ts[1:]):
            n+=1; taus.append(b-a); zero += int(b-a <= 0)
print('결정 간격 n=%d · τ<=0 %d (%.1f%%)' % (n, zero, 100*zero/max(1,n)))
print('τ 중앙 %.3f s · min %.3f · max %.3f' % (statistics.median(taus), min(taus), max(taus)))
assert zero == 0, 'τ<=0 인 결정쌍이 있다 — C3 위반. 결정이 같은 스텝에 몰린다'
print('G3 PASS')
"
```
기대: `G3 PASS` · `τ<=0 0건`. 위반이 있으면 그 결정쌍의 `at`/`truth` 를 뽑아
**같은 스텝에서 두 사건이 발화하는지** 확인한다(`maybe_emit_reform_ood!` 의 dedup 부재가
그런 모양을 만든다 — CLAUDE.md 2026-08-16).

- [ ] **Step 7: 기존 테스트가 회귀하지 않았는지 본다**

```bash
julia +lts --project=. test/mdp_hazard_smoke.jl
julia +lts --project=. test/mdp_crn_smoke.jl
julia +lts --project=. -e 'using Pkg; Pkg.test()'
```
기대: 앞의 둘 전부 PASS · `Pkg.test()` = **11 pass / 1 error**(Gurobi, 무관).

- [ ] **Step 8: 커밋**

```bash
git add tools/monitor/run_demo.jl wm4spacecraft_manufacturing/smdp/probe_hazard.py
git commit -m "feat(hazard): DEMO_HAZARD 손잡이로 레인을 켜고 발화율·G3 를 실측한다 (동역학 세대 분기)"
```

---

## 태스크 4: `_pick_active_robot` 결정성 — G1 의 선결 과제 (spec §11-4, L5)

> `_pick_active_robot`(`src/respec/ood_injection.jl:856`)이 `env.cache.active_set` 을 순회하는데
> 그것은 **`Set` 이라 순회 순서가 정의돼 있지 않다.** 같은 시드·같은 커밋을 다시 굴려도
> 고장 대상 로봇이 갈릴 수 있다. **G1(스냅샷 왕복)이 이것에 걸릴 것이므로 먼저 고친다.**
>
> 이 결함은 CLAUDE.md 2026-08-16 §알려진 한계 2 에 "범위에서 뺐다"로 기록돼 있다 — 그때
> 뺀 이유는 "고치면 세대가 갈려 그 비교의 교란 변수가 된다"였다. 지금은 태스크 3에서 이미
> 세대를 갈랐으므로 그 이유가 사라졌다.

**Files:**
- Modify: `src/respec/ood_injection.jl:856-885` (`_pick_active_robot` 의 세 단 전부)
- Test: `test/respec_determinism_smoke.jl`

**Interfaces:**
- Consumes: `CB._faultable(rid)` · `CB._first_pending_assignment(env, rid)` (기존, 변경 없음)
- Produces: `CB._ordered_active(env) -> Vector{Int}` — `env.cache.active_set` 을 **정렬한**
  정점 번호 벡터. spec §3.5 규칙 4(정준 직렬화)의 첫 적용이자 일반형.

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/respec_determinism_smoke.jl
# L5 — 런 간 재현성 결함. `Set` 순회 순서는 정의돼 있지 않아서, 같은 시드로도 고장 대상
# 로봇이 갈릴 수 있다. 여기서는 씬 전체를 만들지 않고 **순회 헬퍼 자체**를 검사한다 —
# 삽입 순서가 달라도 같은 순서를 내는가.
#
#   julia +lts --project=. test/respec_determinism_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

@testset "_ordered_active 는 삽입 순서에 무관하다" begin
    a = Set{Int}(); for v in [7, 3, 91, 12, 45]; push!(a, v); end
    b = Set{Int}(); for v in [45, 91, 12, 7, 3]; push!(b, v); end
    env_a = (cache = (active_set = a,),)
    env_b = (cache = (active_set = b,),)
    @test CB._ordered_active(env_a) == CB._ordered_active(env_b)
    @test CB._ordered_active(env_a) == [3, 7, 12, 45, 91]
end

@testset "빈 집합은 빈 벡터" begin
    @test CB._ordered_active((cache = (active_set = Set{Int}(),),)) == Int[]
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/respec_determinism_smoke.jl
```
기대: **FAIL** — `UndefVarError: _ordered_active not defined`.

- [ ] **Step 3: 헬퍼를 만들고 세 단 전부에 적용한다**

`src/respec/ood_injection.jl` 의 `_pick_active_robot` **바로 위**에:

```julia
"""
    _ordered_active(env) -> Vector{Int}

`env.cache.active_set` 을 **정렬해서** 돌려준다. spec §3.5 규칙 4(정준 직렬화)의 첫 적용.

왜: `Set` 의 순회 순서는 Julia 가 보장하지 않는다(해시 테이블 내부 상태에 딸린다). 그래서
같은 시드·같은 커밋을 다시 굴려도 아래 세 단이 **다른 로봇**을 고를 수 있었다 — 런 간
재현성 결함(CLAUDE.md 2026-08-16 §알려진 한계 2). 정점 번호는 전역적으로 유일하고 안정적인
정수이므로 정렬이 정준 순서로 충분하다.
"""
_ordered_active(env) = sort!(collect(env.cache.active_set))
```

`_pick_active_robot` 안의 **두 개** `for v in env.cache.active_set` 를 각각
`for v in _ordered_active(env)` 로 바꾼다. 세 번째 단(`Graphs.vertices(sched)`)은 이미
정렬된 순회라 손대지 않는다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/respec_determinism_smoke.jl
```
기대: 두 testset PASS.

- [ ] **Step 5: 같은 시드 2회가 정말 같은 결과를 내는지 실측한다 (음성 대조 있는 게이트)**

```bash
cd /home/chahj578/Construction_OODlayer
for i in 1 2; do
  DEMO_HAZARD=0 DEMO_SUMMARY=/tmp/repro_$i.jsonl OOD_SEED=3 DEMO_CASE=fault \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
done
python3 -c "
import json
a=json.loads(open('/tmp/repro_1.jsonl').readline()); b=json.loads(open('/tmp/repro_2.jsonl').readline())
ka=[(d['decision_index'],d['truth'],d['macro'],d['sim_t_at']) for d in a['decisions']]
kb=[(d['decision_index'],d['truth'],d['macro'],d['sim_t_at']) for d in b['decisions']]
print('makespan', a['makespan'], b['makespan'])
print('decisions equal:', ka==kb)
assert ka==kb, '같은 시드 2회가 다른 결정열을 냈다 — 재현성 결함이 남아 있다'
print('OK')
"
```
기대: `OK`.
⚠️ **이 검사는 결정적으로 통과할 수도, 결함이 남아 있어도 우연히 통과할 수도 있다** —
`Set` 순회는 같은 프로세스 안에서는 안정적이기 때문이다. **두 판을 별도 프로세스로**
돌리는 위 형태가 최소 조건이고, 여기서 실패하면 확실한 결함, 통과는 "이 시드에서는
안 갈렸다" 까지만 주장한다. 진짜 판정은 태스크 12의 G1 이 한다.

- [ ] **Step 6: 커밋**

```bash
git add src/respec/ood_injection.jl test/respec_determinism_smoke.jl
git commit -m "fix(respec): _pick_active_robot 의 Set 순회를 정준 정렬로 (L5, G1 선결 과제)"
```

---

## 태스크 5: 행동공간 6팔 확정 · 소비처 동기화 · `generation` bump · G6

> **삭제 둘 · 재분류 하나** (spec §2):
> - **`ForbidZone`(3) 삭제** — `RelocateBuild`(7) 에 흡수. 제안 0/143 · 집행 0/1438 · 라벨 0/872.
>   **삭제 비용 0행.** 도메인이 죽어 있다(`restage_assembly!` 가 `_assembly_started` 를 거부하고,
>   재적치 가능 staging circle 이 `closed≈46` 부터 0개가 되어 안 돌아온다).
> - **`ForbidWindow` 삭제** — 대응할 물리가 없다. 이 문제의 사건 셋은 대기로 안 풀린다.
> - **`ForbidAgent` 는 삭제가 아니라 재분류** — object-level 행동공간에서 빼고 meta-action
>   `CALL_ORACLE` 의 실물 기전으로 옮긴다. 그 효과가 `verify()` 의 MILP 재풀이를 통과하므로
>   `(s,a) → s⁺` 가 argmin 을 지난다. 이것을 빼야 **`f` 가 솔버-자유**가 되고 option 정의가 선다.
>
> **재번호 없음**(Global Constraints). 조합 팔 5·6 은 `ForbidAgent`/`ForbidWindow` 를 품고
> 있으므로 같이 은퇴한다. 남는 어휘: **`{0, 1, 2, 4, 7, 8}` = 6팔.**

**Files:**
- Modify: `wm4spacecraft_manufacturing/core/action_registry.json` (3·5·6 에 `"retired"` 표식)
- Modify: `wm4spacecraft_manufacturing/core/action_registry.py` (`RETIRED` · `ACTIVE_MACROS` 규칙)
- Modify: `wm4spacecraft_manufacturing/oracle/action_registry.jl` (같은 규칙의 Julia 쪽)
- Modify: `wm4spacecraft_manufacturing/core/objective.json` (`generation` **한 줄만**)
- Modify: `tools/monitor/run_demo.jl:352,464,485` (`ran_milp` 을 결정 행에 남긴다)
- Create: `wm4spacecraft_manufacturing/smdp/gate_g6.py`
- Test: `wm4spacecraft_manufacturing/smdp/test_stamps.py` 에 추가 · `test/mdp_stamp_smoke.jl` 에 추가

**소비처 6곳 — 손으로 대조한다** (`audit_action_vocab.py` 가 2026-08-18 정리에서 삭제됐다.
어휘 누락은 **에러 없이 발화율로만 샌다** — `SwapBattery` 한 줄이 battery 적중 0/6 → 6/6 을
갈랐던 그 실패 모양):

1. `wm4spacecraft_manufacturing/core/action_registry.json` (단일 진실원)
2. `wm4spacecraft_manufacturing/oracle/action_registry.jl`
3. `wm4spacecraft_manufacturing/core/features_agnostic.py` 의 `MACROS`
4. `wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl` 의 `valid_actions`
5. `src/respec/llm_service/dspy_service.py`
6. `src/respec/llm_bridge.jl` 의 JSON 스키마

**Interfaces:**
- Consumes: `action_registry.REGISTRY` · `action_registry.is_active` (태스크 1 이후)
- Produces:
  - `action_registry.RETIRED -> dict[int, str]` — 은퇴 id → 사유
  - `action_registry.ACTIVE_MACROS -> [0, 1, 2, 4, 7, 8]` (실험 게이트와 **무관하게** 은퇴 우선)
  - `ActionRegistry.active_ids() -> [0, 1, 2, 4, 7, 8]`
  - `rows.jsonl` 의 결정 행에 `"ran_milp": Bool` — G6 의 유일한 기계 신호
  - `gate_g6.solver_free(rows_paths) -> dict` — `{"n_decisions", "n_ran_milp", "by_macro", "pass"}`

- [ ] **Step 1: 실패 테스트를 쓴다**

`wm4spacecraft_manufacturing/smdp/test_stamps.py` 에 이어 붙인다:

```python
def test_retired_macros_are_exactly_three_five_six():
    assert sorted(action_registry.RETIRED) == [3, 5, 6]


def test_active_macros_are_the_six_arms():
    assert action_registry.ACTIVE_MACROS == [0, 1, 2, 4, 7, 8]


def test_retired_macros_keep_their_names():
    """이름표는 지우지 않는다. 지우면 구세대 행을 읽을 때 KeyError 로 죽는데, 그건
    2026-08-02 에 실제로 난 사고다(gen_oracle_dataset.jl:118). 우리가 원하는 것은
    '읽을 때 도장 불일치로 죽는 것'이지 'KeyError 로 죽는 것'이 아니다."""
    assert action_registry.MACRO_NAME[3] == "ForbidZone"
    assert action_registry.MACRO_NAME[5] == "ForbidAgent+ReformTeam"


def test_combo_arms_flag_cannot_resurrect_retired():
    """DS_COMBO_ARMS=1 으로도 5·6 은 안 살아난다 — 은퇴가 실험 게이트를 이긴다."""
    os.environ["DS_COMBO_ARMS"] = "1"
    try:
        import importlib
        m = importlib.reload(action_registry)
        assert m.ACTIVE_MACROS == [0, 1, 2, 4, 7, 8]
    finally:
        os.environ.pop("DS_COMBO_ARMS", None)
        importlib.reload(action_registry)
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_stamps.py -v
```
기대: 새 4건 **FAIL** — `AttributeError: ... has no attribute 'RETIRED'`.

- [ ] **Step 3: JSON 에 은퇴 표식을 넣는다**

`action_registry.json` 의 매크로 3·5·6 각각에 `"retired"` 를 더한다(**이름·비용은 그대로 둔다**):

```json
    "3": {
      "name": "ForbidZone",
      "cost": 1.0,
      "kinds": ["zone"],
      "retired": "2026-08-19 spec §2.1 — RelocateBuild(7) 에 흡수. 같은 의도이고 차이는 범위뿐인데 좁은 쪽의 도메인이 죽어 있다(restage_assembly! 가 _assembly_started 를 거부; 재적치 가능 staging circle 이 closed≈46 부터 0개). 실측 제안 0/143 · 집행 0/1438 · 라벨 0/872 — 삭제 비용 0행.",
      "doc": "..."
    },
```

```json
    "5": { ... "retired": "2026-08-19 spec §2.2 — ForbidAgent 를 품고 있다. ForbidAgent 의 효과는 verify() 가 MILP 를 다시 풀어야 나타나므로 (s,a)→s⁺ 가 argmin 을 지난다. 그건 macro option 이 아니라 meta-action CALL_ORACLE 의 실물 기전이다. 삭제가 아니라 재분류 — 행동공간에서만 뺀다." ... },
    "6": { ... "retired": "2026-08-19 spec §2.1 — ForbidWindow 를 품고 있다. '기다리면 해소되는 사건' 을 위한 lever 인데 이 문제의 사건 셋(zone 영구 · fault 영구 · battery 는 복구)은 대기로 안 풀린다. 의도상 DeprioritizeAgent 와 같은데 TIER-1 하드라 빌드를 infeasible 하게 만들 수 있어 지배당한다." ... },
```

- [ ] **Step 4: 로더 둘에 은퇴 규칙을 넣는다**

`core/action_registry.py` — `EXPERIMENTAL = ...` 정의 **뒤**, `is_active` **앞**에:

```python
# ---- 은퇴한 팔 (2026-08-19, spec §2) --------------------------------------------------------
# 은퇴는 실험 게이트를 **이긴다**: DS_COMBO_ARMS=1 으로도 5·6 은 안 살아난다. 그리고
# 이름표(MACRO_NAME)와 비용은 **지우지 않는다** — 지우면 구세대 행을 읽을 때 KeyError 로
# 죽는데(2026-08-02 사고), 우리가 원하는 실패 모양은 '도장 불일치로 죽는 것'이다.
# id 는 재번호하지 않는다: 3·5·6 은 영구 결번이고, 그래야 구세대 행이 조회 실패로 죽는다.
# 재번호하면 macro 3 행이 ReformTeam 으로 **에러 없이** 재해석된다(spec §2.4).
RETIRED = {i: m["retired"] for i, m in REGISTRY.items() if m.get("retired")}
```

같은 파일의 `is_active` 를 고친다:

```python
def is_active(i):
    """이 매크로를 지금 **제안해도 되는가**. 은퇴한 팔은 무조건 아니고,
    실험 팔은 자기 ENV 플래그가 켜졌을 때만."""
    if i in RETIRED:
        return False
    flag = EXPERIMENTAL.get(i)
    return flag is None or os.environ.get(flag, "0") == "1"
```

`oracle/action_registry.jl` 의 `is_active` 도 같은 규칙으로:

```julia
"은퇴한 팔 (spec §2). 은퇴는 실험 게이트를 이긴다 — DS_COMBO_ARMS=1 으로도 안 살아난다."
const RETIRED = Dict(i => String(REGISTRY[i].retired) for i in IDS if haskey(REGISTRY[i], :retired))

function is_active(i::Int)
    haskey(RETIRED, i) && return false      # 은퇴가 실험 게이트를 이긴다
    m = REGISTRY[i]
    haskey(m, :experimental) || return true
    return get(ENV, String(m.experimental), "0") == "1"
end
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_stamps.py -v
julia +lts --project=. ../../test/mdp_stamp_smoke.jl
```
기대: Python 9건 PASS. Julia 는 아직 은퇴 검사를 안 넣었으므로 기존대로 PASS.

- [ ] **Step 6: Julia 쪽 은퇴 검사를 더하고 돌린다**

`test/mdp_stamp_smoke.jl` 의 "어휘 도장" testset 뒤에:

```julia
@testset "6팔 확정" begin
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.active_ids() == [0, 1, 2, 4, 7, 8]
    ENV["DS_COMBO_ARMS"] = "1"
    @test ActionRegistry.active_ids() == [0, 1, 2, 4, 7, 8]   # 은퇴가 실험 게이트를 이긴다
    delete!(ENV, "DS_COMBO_ARMS")
    @test ActionRegistry.NAME[3] == "ForbidZone"              # 이름표는 남는다
    @test sort(collect(keys(ActionRegistry.RETIRED))) == [3, 5, 6]
end
```

```bash
julia +lts --project=. test/mdp_stamp_smoke.jl
```
기대: 세 testset 전부 PASS.

- [ ] **Step 7: 나머지 소비처 4곳을 손으로 대조한다**

```bash
cd /home/chahj578/Construction_OODlayer
grep -n "MACROS" wm4spacecraft_manufacturing/core/features_agnostic.py | head
grep -n "valid_actions\|COMBO_IDS\|\[0, *1\]" wm4spacecraft_manufacturing/oracle/ood_mdp_shim.jl | head
grep -n "MACROS\|ForbidZone\|ForbidAgent\|ForbidWindow" src/respec/llm_service/dspy_service.py | head
grep -n "ForbidZone\|ForbidAgent\|ForbidWindow\|macro" src/respec/llm_bridge.jl | head
```

각 파일에서 **리터럴 목록을 발견하면** `action_registry` 파생으로 바꾸거나(가능하면),
바꿀 수 없는 자리(예: JSON 스키마의 enum)면 3·5·6 을 빼고 **그 자리에 근거 주석을 남긴다**.
`ood_mdp_shim.valid_actions` 는 문지기(팔 메뉴가 아니다) — `action_to_proposal` 이
`a in valid_actions(ctx) || return nothing` 으로 거르므로 여기 남아 있으면 은퇴한 팔이
**조용히 NOOP 으로 무너진다**. 반드시 확인할 것.

**대조 결과를 커밋 메시지에 6줄로 적는다** — 이제 기계 감시가 없으므로 그 기록이 유일한 흔적이다.

- [ ] **Step 8: `generation` 을 bump 한다 — 한 줄만**

`wm4spacecraft_manufacturing/core/objective.json`:

```json
  "generation": "2026-08-19-vocab-6-arms-hazard-on",
```

**스칼라는 하나도 안 바꾼다**(`kappa` · `C_fail` · `C_unclosed` · `tie_eps` · `T_scale` ·
`Eg_scale` · `M_ref` · `E_ref` 전부 그대로). 행동공간이 줄고 hazard 가 켜지면 V\* 가 바뀌므로
`objective.json` 의 *"스칼라가 하나도 안 바뀌어도 목적함수의 유효 의미가 바뀌면 반드시 bump"*
규칙에 정확히 해당한다.

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
../.venv/bin/python -c "
import sys; sys.path.insert(0,'core')
import objective
print('new objective_hash =', objective.objective_hash())
"
```
기대: 새 해시가 `19819377a7f8ebb2` 와 **다르다**. 값을 기록해 두되 **CLAUDE.md 나 이 계획서에
문자열로 박지 않는다** (그 규약은 CLAUDE.md 2026-08-16 절에 있다).

- [ ] **Step 9: `ran_milp` 을 결정 행에 남긴다 — G6 의 유일한 기계 신호**

지금 `ran_milp` 은 `tools/monitor/run_demo.jl:464` 에서 **`try` 블록 안의 지역변수**로만 살아
stdout 에만 나간다. `rows.jsonl` 에 없으므로 G6 은 원리적으로 잴 수 없다.
`enact_applied` 와 **완전히 같은 패턴**으로 밖으로 뺀다:

`:352` 의 `local enact_applied = false` 다음 줄에:
```julia
    local ran_milp = false      # G6(spec §5.5): 이 결정에서 f 가 솔버를 불렀는가
```

`:464` 의 `local ran_milp = ...` 에서 `local` 을 **뺀다**(같은 이름의 새 지역변수를 만들지 않게):
```julia
        ran_milp = !(CB.LAST_EDGE_COSTS[] === _milp_sentinel)   # 센티넬이 그대로면 재풀이 없음
```

`:485` 의 `this_decision["enact_applied"] = enact_applied` 다음 줄에:
```julia
    # G6 — `f` 무솔버 불변식(spec §5.5). 6팔 전부에서 false 여야 한다. 하나라도 true 면 그 팔은
    # 행동공간이 아니라 meta-level(CALL_ORACLE)로 가야 한다. 예전에는 이 값이 stdout 에만
    # 나가서 게이트를 기계로 못 걸었다.
    this_decision["ran_milp"] = ran_milp
```

- [ ] **Step 10: G6 게이트를 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/gate_g6.py
"""G6 — `f` 무솔버 불변식 (spec §5.5 · §7).

주장: 6팔 전부에 대해 f(s,a) 가 **결정론적 그래프/기하 편집**이고 솔버를 부르지 않는다.
왜 필요한가: π_a 의 첫 스텝이 결정론적이어야 option 이 잘 정의되고(Sutton Thm 1),
스냅샷/K-rollout 예산이 예측 가능해지며, MILP 비용이 object-level 팔에 숨지 않는다.

이것은 가정이 아니라 **검사 가능한 불변식**이다 — run_demo 의 _milp_sentinel 이 결정마다
"이 분기가 formulate_milp 을 불렀는가" 를 실측한다.

  python gate_g6.py <rows.jsonl> [<rows.jsonl> ...]
  python gate_g6.py $(find ../results_4pol/shards -name rows.jsonl)
"""
import json
import sys


def solver_free(paths):
    n, n_milp, by_macro, missing = 0, 0, {}, 0
    for p in paths:
        with open(p) as fh:
            for line in fh:
                row = json.loads(line)
                for d in row.get("decisions") or []:
                    n += 1
                    rm = d.get("ran_milp")
                    if rm is None:
                        missing += 1
                        continue
                    mac = d.get("macro")
                    slot = by_macro.setdefault(mac, [0, 0])
                    slot[0] += 1
                    if rm:
                        slot[1] += 1
                        n_milp += 1
    return {"n_decisions": n, "n_ran_milp": n_milp, "missing_field": missing,
            "by_macro": by_macro, "pass": (missing == 0 and n_milp == 0 and n > 0)}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    out = solver_free(argv[1:])
    print("=== G6 — f 무솔버 불변식 ===")
    print("  결정 %d · ran_milp=true %d · 필드 없음 %d"
          % (out["n_decisions"], out["n_ran_milp"], out["missing_field"]))
    for mac, (tot, milp) in sorted(out["by_macro"].items(), key=lambda kv: str(kv[0])):
        flag = "  🔴 meta-level 로 가야 한다" if milp else ""
        print("    %-14s %4d 결정 · MILP %d%s" % (mac, tot, milp, flag))
    if out["missing_field"]:
        print("  🔴 ran_milp 필드가 없는 결정이 있다 — 구세대 산출물이다. 재스윕 없이는 못 잰다.")
    print("  판정: %s" % ("PASS" if out["pass"] else "FAIL"))
    return 0 if out["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 11: G6 을 실측한다 — 음성 대조 먼저**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
# 음성 대조: 구세대 산출물에는 ran_milp 이 없어야 한다 → FAIL 이 떠야 정상이다
../../.venv/bin/python gate_g6.py ../results_4pol/shards/all/s11/rows.jsonl; echo "rc=$?"
```
기대: `필드 없음` > 0, `판정: FAIL`, `rc=1`. **이것이 음성 대조다** — PASS 가 뜨면 이 게이트는
아무것도 안 보고 있는 것이다.

```bash
cd /home/chahj578/Construction_OODlayer
for c in fault battery zone; do for s in 1 2; do
  DEMO_HAZARD=1 DEMO_SUMMARY=/tmp/g6_$c$s.jsonl OOD_SEED=$s DEMO_CASE=$c \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
done; done
cd wm4spacecraft_manufacturing/smdp && ../../.venv/bin/python gate_g6.py /tmp/g6_*.jsonl; echo "rc=$?"
```
기대: `필드 없음 0` · `ran_milp=true 0` · `판정: PASS` · `rc=0`.
어느 팔이든 `MILP > 0` 이면 **그 팔은 행동공간에서 빼고 meta-level 로 옮겨야 한다** — spec §2.2
의 `ForbidAgent` 와 같은 처분이고, 그 사실을 사용자에게 보고한다(임의로 옮기지 않는다).

- [ ] **Step 12: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/core/action_registry.json \
        wm4spacecraft_manufacturing/core/action_registry.py \
        wm4spacecraft_manufacturing/core/objective.json \
        wm4spacecraft_manufacturing/oracle/action_registry.jl \
        wm4spacecraft_manufacturing/smdp/ tools/monitor/run_demo.jl test/mdp_stamp_smoke.jl
git commit -m "feat(vocab): 행동공간 6팔 확정 {0,1,2,4,7,8} + generation bump + G6 무솔버 게이트

소비처 6곳 대조(audit_action_vocab.py 가 없으므로 손으로):
  1. core/action_registry.json        — 3·5·6 에 retired 표식, 이름/비용 유지
  2. oracle/action_registry.jl        — is_active 가 은퇴를 실험 게이트보다 먼저 본다
  3. core/features_agnostic.py MACROS — <실제 확인 결과를 여기 적을 것>
  4. oracle/ood_mdp_shim.jl valid_actions — <실제 확인 결과를 여기 적을 것>
  5. src/respec/llm_service/dspy_service.py — <실제 확인 결과를 여기 적을 것>
  6. src/respec/llm_bridge.jl JSON 스키마 — <실제 확인 결과를 여기 적을 것>"
```

---

## 태스크 6: 라벨셋 872 → 742 — **필터링만**, remap 없음 (spec §11-6)

> 872 − 65(구 macro 5) − 65(구 macro 6) = **742행 / 98 instance**. 구 macro 3 은 0행이라 손실 없다.
> **`macro` 정수 컬럼은 손대지 않는다.**
>
> ⚠️ 이 742행은 **§4.1 의 롤아웃 라벨로 대체될 예정**이므로 마이그레이션에 공을 들이지 않는다.
> `V̂` 학습셋이 아니라 **회귀 비교용 legacy** 로만 남긴다.

**Files:**
- Create: `wm4spacecraft_manufacturing/core/filter_labels.py`
- Create (산출): `wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-19.jsonl`
- Modify: `wm4spacecraft_manufacturing/core/wm_datasets.py` (`RELABEL_20260819` 등록)
- Test: `wm4spacecraft_manufacturing/smdp/test_filter_labels.py`

**Interfaces:**
- Consumes: `action_registry.RETIRED` · `action_registry.VOCAB` (태스크 1·5)
- Produces: `filter_labels.filter_rows(rows: list[dict]) -> tuple[list[dict], dict]`
  — `(살아남은 행, 카운터 {"kept","dropped_by_macro","stamped"})`. 살아남은 행마다
  `row["vocab"] = VOCAB` 을 찍는다. **덮어쓰지 않고 새 파일로 파생한다.**

- [ ] **Step 1: 실패 테스트를 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/test_filter_labels.py
"""라벨 필터의 단위검사. 핵심은 **remap 이 절대 일어나지 않는 것**이다 —
정수 remap 을 넣으면 구세대 macro 3 행이 ReformTeam 으로 에러 없이 재해석된다."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import filter_labels  # noqa: E402
import action_registry  # noqa: E402


def test_drops_only_retired_macros():
    rows = [{"macro": m, "kind": "fault"} for m in (0, 1, 2, 3, 4, 5, 6, 7, 8)]
    kept, diag = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [0, 1, 2, 4, 7, 8]
    assert diag["dropped_by_macro"] == {3: 1, 5: 1, 6: 1}


def test_macro_column_is_never_remapped():
    rows = [{"macro": 7, "kind": "zone"}, {"macro": 8, "kind": "battery"}]
    kept, _ = filter_labels.filter_rows(rows)
    assert [r["macro"] for r in kept] == [7, 8]   # 0..5 로 다시 매기지 않는다


def test_survivors_get_the_vocab_stamp():
    kept, diag = filter_labels.filter_rows([{"macro": 1, "kind": "fault"}])
    assert kept[0]["vocab"] == action_registry.VOCAB
    assert diag["stamped"] == 1


def test_empty_input_is_not_a_silent_pass():
    kept, diag = filter_labels.filter_rows([])
    assert kept == [] and diag["kept"] == 0
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_filter_labels.py -v
```
기대: **FAIL** — `ModuleNotFoundError: No module named 'filter_labels'`.

- [ ] **Step 3: 필터를 구현한다**

```python
# wm4spacecraft_manufacturing/core/filter_labels.py
"""구세대 라벨셋에서 은퇴한 팔의 행을 **빼기만** 한다 (spec §8·§11-6).

  872행 − 65(구 macro 5) − 65(구 macro 6) = 742행 / 98 instance.
  구 macro 3(ForbidZone)은 원래 0행이라 손실이 없다.

🔴 **정수 remap 을 하지 않는다.** id 를 0..5 로 다시 매기면 구세대 macro 3 행이
ReformTeam 으로, 5 행이 SwapBattery 로 **에러 없이** 재해석된다. 3·5·6 을 영구 결번으로
두면 구세대 파일은 조회 실패로 죽고, 그게 우리가 원하는 실패 모양이다(spec §2.4).

🔴 **원본을 덮어쓰지 않는다.** 새 파일로 파생하고 도장을 찍는다.

  python filter_labels.py oracle/out/relabel_2026-08-16.jsonl oracle/out/relabel_2026-08-19.jsonl
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import action_registry  # noqa: E402


def filter_rows(rows):
    """(살아남은 행, 카운터). 행마다 vocab 도장을 찍는다. macro 컬럼은 손대지 않는다."""
    kept, dropped = [], {}
    for row in rows:
        m = row.get("macro")
        if m in action_registry.RETIRED:
            dropped[m] = dropped.get(m, 0) + 1
            continue
        row = dict(row)
        row["vocab"] = action_registry.VOCAB
        kept.append(row)
    return kept, {"kept": len(kept), "dropped_by_macro": dropped, "stamped": len(kept)}


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    if os.path.abspath(src) == os.path.abspath(dst):
        raise SystemExit("원본을 덮어쓸 수 없다 — 새 파일로 파생할 것: %s" % dst)
    with open(src, encoding="utf-8") as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    kept, diag = filter_rows(rows)
    with open(dst, "w", encoding="utf-8") as fh:
        for r in kept:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    inst = len({r.get("instance_id", r.get("instance")) for r in kept})
    print("입력 %d행 → 출력 %d행 / instance %d" % (len(rows), diag["kept"], inst))
    print("제거: %s" % diag["dropped_by_macro"])
    print("도장: vocab=%s (%d행)" % (action_registry.VOCAB, diag["stamped"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_filter_labels.py -v
```
기대: 4건 전부 PASS.

- [ ] **Step 5: 실제 라벨셋에 돌린다 — 742/98 을 실측으로 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
wc -l oracle/out/relabel_2026-08-16.jsonl       # 기대: 872
../.venv/bin/python core/filter_labels.py \
    oracle/out/relabel_2026-08-16.jsonl oracle/out/relabel_2026-08-19.jsonl
wc -l oracle/out/relabel_2026-08-19.jsonl       # 기대: 742
../.venv/bin/python -c "
import json
rows=[json.loads(l) for l in open('oracle/out/relabel_2026-08-19.jsonl')]
assert all(r['macro'] not in (3,5,6) for r in rows), '은퇴한 팔이 남아 있다'
assert all(r.get('vocab')=='v2-6arms' for r in rows), '도장이 안 찍힌 행이 있다'
print('행', len(rows), '· 도장 OK · 은퇴 팔 0행')
"
```
기대: 872 → **742**. 실측이 742 가 아니면 **그 차이를 먼저 설명하고** 진행한다 —
spec §8 의 셈(65+65)이 현행 파일과 안 맞는다는 뜻이므로 조용히 넘기지 않는다.

- [ ] **Step 6: `wm_datasets.py` 에 등록한다**

```bash
grep -n "RELABEL_20260816\|RELABEL_20260814\|CANONICAL" wm4spacecraft_manufacturing/core/wm_datasets.py | head
```

찾은 `RELABEL_20260816` 정의 **바로 아래**, 같은 형식으로:

```python
# 2026-08-19 — 6팔 어휘(spec §2)로 필터링한 legacy 라벨. 872 → 742행 / 98 instance.
# ⚠️ 이것은 **회귀 비교용 legacy** 다. V̂ 학습셋이 아니다 — 그 자리는 §4.1 의 K-rollout
# 라벨이 가져간다(단계 B). 여기에 공을 들이지 말 것.
RELABEL_20260819 = os.path.join(OUT, "relabel_2026-08-19.jsonl")
```

(`OUT` 상수의 실제 이름은 그 파일이 `RELABEL_20260816` 에 쓰는 것을 그대로 따를 것 —
새 경로 리터럴을 만들지 않는다.)

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add wm4spacecraft_manufacturing/core/filter_labels.py \
        wm4spacecraft_manufacturing/core/wm_datasets.py \
        wm4spacecraft_manufacturing/oracle/out/relabel_2026-08-19.jsonl \
        wm4spacecraft_manufacturing/smdp/test_filter_labels.py
git commit -m "feat(labels): 6팔 어휘로 라벨 872→742 필터링 (remap 없음, 도장 찍음, legacy 전용)"
```

---

## 태스크 7: 전역 인벤토리 — §2.3/§3.6 표를 **기계 검사**로 만든다 (spec §11-7)

> spec §1.5: *"1차 개정은 넷을 적었다. 전수로 훑으면 에피소드 중 변하는데 그 넷에 안 들어가는
> 것이 십여 개 더 있다."* 실측하면 `src/` 의 대문자 `Ref` 전역은 **79개**다.
>
> 이 태스크의 산출물은 문서가 아니라 **테스트다.** 새 전역이 생기고 분류가 안 되면 테스트가
> 그 이름을 찍고 죽는다 — 태스크 10(`snapshot`)의 "어딘가에 있다"로 두면 롤아웃마다 조용히
> 오염된다는 위험(spec §3.5 규칙 3)을 여기서 닫는다.

**Files:**
- Create: `src/mdp/state_globals.jl`
- Modify: `src/mdp/mdp.jl` (include 추가)
- Test: `test/mdp_global_inventory.jl`

**Interfaces:**
- Produces:
  - `CB.STATE_GLOBALS::Dict{Symbol,Symbol}` — 전역 이름 → 처분.
    처분 ∈ `{:state, :replay, :split, :log, :setup, :render, :meta}`
  - `CB.scan_globals(root) -> Vector{Symbol}` — `src/` 를 훑어 대문자 `Ref` 전역 이름을 수집
  - `CB.unclassified_globals(root) -> Vector{Symbol}` — 스캔 결과 중 인벤토리에 없는 것

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_global_inventory.jl
# spec §3.6 — 스냅샷 대상 전역의 전수 목록을 **기계로** 지킨다.
#
# 왜 테스트여야 하는가: 표로만 두면 새 전역이 생겼을 때 아무것도 안 잡는다. snapshot/restore!
# 가 그 전역을 모르면 롤아웃마다 조용히 오염된다 — 에러가 아니라 **결과의 미세한 차이**로만
# 새는 실패 모양이라 사후에 못 찾는다(spec §3.5 규칙 3).
#
#   julia +lts --project=. test/mdp_global_inventory.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

const SRC = normpath(joinpath(@__DIR__, "..", "src"))

@testset "스캐너가 알려진 전역을 찾는다" begin
    found = CB.scan_globals(SRC)
    for name in (:BATTERY_FLEET, :HAZARD_STATE, :SNAP_COUNT, :WEDGE_EDGES,
                 :RESTRICTION_ZONES, :SIM_STEP, :STALLED_ROBOTS, :BATTERY_DELIVERIES)
        @test name in found
    end
    @test length(found) >= 70      # 2026-08-19 실측 79
end

@testset "분류되지 않은 전역이 없다" begin
    missing = CB.unclassified_globals(SRC)
    isempty(missing) || @info "분류 안 된 전역" missing
    @test isempty(missing)
end

@testset "처분 어휘가 닫혀 있다" begin
    ok = Set([:state, :replay, :split, :log, :setup, :render, :meta])
    @test all(v -> v in ok, values(CB.STATE_GLOBALS))
end

@testset "s 로 가는 전역이 spec §3.6 을 덮는다" begin
    st = Set(k for (k, v) in CB.STATE_GLOBALS if v === :state)
    for name in (:BATTERY_FLEET, :STALLED_ROBOTS, :BATTERY_DELIVERIES, :AGENT_COST_BIAS,
                 :RESTRICTION_ZONES, :SPARE_POOLS, :SPARE_SLOTS, :FAULTED_ROBOTS,
                 :RECOVERY_SPARES, :CHECKED_OUT_SPARES, :DECOMMISSIONED_BODIES,
                 :HOT_SWAP_ASSETS, :WEDGE_EDGES, :DISSOLVED_GATES, :SNAP_COUNT,
                 :SIM_STEP, :LAST_EDGE_COSTS)
        @test name in st
    end
    @test CB.STATE_GLOBALS[:HAZARD_STATE] === :split     # 셋으로 쪼개진다
    @test CB.STATE_GLOBALS[:NOVELTY_DETECTOR] === :meta  # spec §6.1 — s 에 넣지 않는다
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_global_inventory.jl
```
기대: **FAIL** — `UndefVarError: scan_globals not defined`.

- [ ] **Step 3: 인벤토리를 구현한다**

```julia
# src/mdp/state_globals.jl
# =============================================================================
# spec §3.6 — 스냅샷 대상 전역의 전수 목록. **문서가 아니라 계약이다.**
#
# 처분 어휘:
#   :state   → s 로 들어간다 (Markov 상태. 모델 입력. 콘텐츠 해시 가능해야 한다)
#   :replay  → ξ 로 들어간다 (restore! 와 CRN 만 쓴다. s 에 넣지 않는다 — 넣으면 s 가
#              해시 불가가 되고, thr 을 넣으면 발화 시각이 s 로부터 결정론이 되어 전체
#              시스템이 확률성을 잃는다: spec §3.4)
#   :split   → 한 컨테이너가 s·ξ·log 로 쪼개진다 (지금은 HAZARD_STATE 하나)
#   :log     → 상태 아님. 스냅샷 대상도 아님
#   :setup   → 셋업 상수 / 배선 훅 / ENV 손잡이. 에피소드 중 불변이면 스냅샷 불필요
#   :render  → 시각화 전용. 동역학에 안 닿는다
#   :meta    → meta-level 상태. **s 에 넣지 않는다**(spec §6.1: "이 OOD 를 본 적 있는가"는
#              환경 상태가 아니라 meta-state 다)
#
# 새 전역을 만들면 여기 등록해야 한다 — 안 하면 test/mdp_global_inventory.jl 이 이름을 찍고
# 죽는다. 그게 이 파일의 존재 이유다.
# =============================================================================

const STATE_GLOBALS = Dict{Symbol,Symbol}(
    # ---- s (Markov 상태) ---------------------------------------------------------------
    :BATTERY_FLEET          => :state,   # Fleet: soc_r · energy_r
    :STALLED_ROBOTS         => :state,   # Fleet.stalled_r — 빼면 복구 판정이 갈린다
    :BATTERY_DELIVERIES     => :state,   # Courier 블록 전체
    :AGENT_COST_BIAS        => :state,   # G 의 엣지 가중치 배수 (Deprioritize 의 지연 효과)
    :RESTRICTION_ZONES      => :state,   # Geo: 활성 no-go 구역
    :SPARE_POOLS            => :state,   # Fleet.role_r 이 여기서 유도된다
    :SPARE_SLOTS            => :state,
    :FAULTED_ROBOTS         => :state,   # Fleet.health_r
    :RECOVERY_SPARES        => :state,   # Fleet.role_r
    :CHECKED_OUT_SPARES     => :state,
    :DECOMMISSIONED_BODIES  => :state,
    :HOT_SWAP_ASSETS        => :state,
    :WEDGE_EDGES            => :state,   # G: ReformTeam 이 남기는 **영구 편집** (spec §5.4-b)
    :DISSOLVED_GATES        => :state,   # G: 같은 이유
    :SNAP_COUNT             => :state,   # Age: 3회 임계 escalation — C1 위반 (spec §5.4-b)
    :SIM_STEP               => :state,   # Clock: 시계 단일 진실원 (태스크 8)
    :LAST_EDGE_COSTS        => :state,   # G6 센티넬이 읽는다 (spec §3.6)
    :RESPEC_HOLD            => :state,   # ⚠️ 에피소드 중 변한다. G1 이 최종 판정한다

    # ---- 분할 --------------------------------------------------------------------------
    # 비율 인자·broken·eff·usage_s·expired → s
    # cum_*·thr_*·rng_*·pending_drop      → ξ   (무기억성: cum 은 미래에 정보를 안 나른다)
    # events                              → log
    :HAZARD_STATE           => :split,

    # ---- ξ (재생 상태) -----------------------------------------------------------------
    :_CACHE_TIMESTAMP_COUNTER => :replay, # 부기 카운터. 복원해야 바이트 동일이 성립한다

    # ---- log ---------------------------------------------------------------------------
    :ASSET_LEDGER           => :log,
    :OOD_TRUTH_LOG          => :log,
    :_IDENTITY_SEEN         => :log,
    :_DRAWN_ZONE_MARKERS    => :log,
    :_DRAWN_DEPOT_MARKERS   => :log,
    :_DRAWN_DECOMMISSIONED  => :log,
    :ZONE_SNAP_STATS        => :log,
    :LAST_AUTO_EFFICIENCY_W => :log,     # 진단용 — 결정에 안 쓰인다
    :MONITOR_IO             => :log,
    :MONITOR_RESPEC         => :log,
    :MONITOR_CONTROL_HOOK   => :log,

    # ---- meta (s 에 넣지 않는다 — spec §6.1) --------------------------------------------
    :NOVELTY_DETECTOR       => :meta,
    :NOVELTY_FLEET_REF      => :meta,

    # ---- 셋업 상수 / 배선 훅 / ENV 손잡이 ----------------------------------------------
    :SPARE_POOL_CENTERS     => :setup,   # spec §3.6: 셋업 상수 — 스냅샷 불필요
    :DEPOT_INFO             => :setup,
    :OOD_SCHEDULE           => :setup,   # 에피소드 중 불변이면 상수
    :HAZARD_ENABLED         => :setup,
    :_HAZARD_PREV_STEP_HOOK => :setup,
    :BATTERY_STEP_HOOK      => :setup,
    :SOC_SPEED_HOOK         => :setup,
    :DRAIN_FACTOR_HOOK      => :setup,
    :BATTERY_ACCOUNTING     => :setup,
    :BATTERY_COURIER_CFG    => :setup,
    :BATTERY_DERATE         => :setup,
    :BATTERY_PENALTY        => :setup,
    :BATTERY_STALL          => :setup,
    :DEPRIORITIZE_KAPPA     => :setup,
    :HOT_SWAP_MODE          => :setup,
    :HOT_SWAP_REPLACE       => :setup,
    :IDENTITY_CHECK         => :setup,
    :IDENTITY_CHECK_EVERY   => :setup,
    :IDENTITY_STRICT        => :setup,
    :REFORM_INTERVAL        => :setup,   # ⚠️ 이 값이 Age.no_progress 의 modulo 를 정한다
    :RELOCATE_GATE          => :setup,
    :REPLACE_SOC_THRESHOLD  => :setup,
    :RESPEC_DRIFT_REPAIR    => :setup,
    :RESPEC_ENABLED         => :setup,
    :RESPEC_FROZEN          => :setup,
    :RESPEC_PINNED          => :setup,
    :RESPEC_PRODUCER        => :setup,
    :SNAP_ESCALATE_AT       => :setup,
    :SPARE_DEPOT_DISTANCE   => :setup,
    :SPARE_POOL_MARGIN_FACTOR => :setup,
    :_SPARE_MARGIN_DEPRECATED => :setup,
    :ZONE_DOMAIN_GATE       => :setup,
    :AUTO_EFFICIENCY_KAPPA  => :setup,
    :EDGE_COST_MULTIPLIER   => :setup,
    :ENERGY_MODEL           => :setup,
    :GREEDY_ENERGY_W        => :setup,
    :PLANNING_OBJECTIVE_WEIGHTS => :setup,

    # ---- 시각화 전용 --------------------------------------------------------------------
    :LIVE_PUSH              => :render,
    :CAMERA_FOLLOW          => :render,
    :CAMERA_FOLLOW_MAP      => :render,
    :_VIS_FRAME             => :render,
    :_COURIER_TINT_FRAMES   => :render,
    :_BATTERY_TINT_FRAMES   => :render,
    :BATTERY_TINT_HOLD_FRAMES => :render,
    :BATTERY_DELIVERY_FRAME_EVERY => :render,
)

"""
    scan_globals(root) -> Vector{Symbol}

`root` 아래 모든 `.jl` 에서 최상위 `const NAME = Ref(...)` 전역 이름을 모은다.
정규식은 인벤토리를 만들 때 쓴 것과 **같은 것**이어야 한다 — 다르면 검사가 새 전역을 놓친다.
"""
function scan_globals(root::AbstractString)
    pat = r"^const\s+(_?[A-Z][A-Z_0-9]*)\s*=\s*Ref"
    out = Symbol[]
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        for line in eachline(joinpath(dir, f))
            m = match(pat, line)
            m === nothing || push!(out, Symbol(m.captures[1]))
        end
    end
    return sort!(unique!(out))
end

"인벤토리에 없는 전역. 비어 있지 않으면 테스트가 죽는다."
unclassified_globals(root::AbstractString) =
    [g for g in scan_globals(root) if !haskey(STATE_GLOBALS, g)]

"처분이 `disp` 인 전역 이름들 (오름차순). snapshot/restore! 가 이 목록으로 돈다."
globals_with(disp::Symbol) = sort!([k for (k, v) in STATE_GLOBALS if v === disp])
```

`src/mdp/mdp.jl` 의 `include("hazard.jl")` **앞**에 한 줄:

```julia
include("state_globals.jl")   # spec §3.6 전역 인벤토리 (hazard 보다 먼저 — 의존 없음)
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_global_inventory.jl
```
기대: 네 testset 전부 PASS. `분류되지 않은 전역이 없다` 가 실패하면 **그 이름들을 위 표에
분류해 넣는다** — 임의로 `:log` 로 몰지 말고, 그 전역이 에피소드 중 변하는지 코드에서 확인할 것.

- [ ] **Step 5: 각 팔이 쓰는 전역이 인벤토리에 다 있는지 대조한다 (spec §2.3 표 재작성)**

```bash
cd /home/chahj578/Construction_OODlayer
for f in replace_robot.jl replan.jl ood_injection.jl battery_courier.jl; do
  echo "=== $f ==="
  grep -no "[A-Z_][A-Z_0-9]*\[\]" src/respec/$f | sed 's/.*:\([A-Z_0-9]*\)\[\]/\1/' | sort -u | tr '\n' ' '
  echo
done
```

출력의 모든 이름이 `STATE_GLOBALS` 에 **있어야 한다.** 없는 이름이 나오면 인벤토리에 추가한다.
특히 spec §2.3 이 🔴 로 표시한 것들 — `Replace` 의 `FAULTED_ROBOTS`/`CHECKED_OUT_SPARES`/
`HOT_SWAP_ASSETS`, `ReformTeam` 의 `WEDGE_EDGES`/`DISSOLVED_GATES`/`SNAP_COUNT` — 이 실제로
그 함수들에서 쓰이는지 눈으로 확인하고, **확인한 결과를 커밋 메시지에 남긴다.**

- [ ] **Step 6: 커밋**

```bash
git add src/mdp/state_globals.jl src/mdp/mdp.jl test/mdp_global_inventory.jl
git commit -m "feat(mdp): 전역 인벤토리 79개를 기계 검사로 (spec §3.6) — 미분류 전역은 테스트가 죽인다"
```

---

## 태스크 8: 시계 단일 진실원 (spec §11-8)

> 지금 시계가 **셋**이다: `SIM_STEP`(`asset_ledger.jl:100`) · `HazardState.t/.step` ·
> `run_demo._SIM_STEP`(`run_demo.jl:79`). `Courier.step_out`/`step_swap` 이 **절대 스텝 인덱스**
> 이고 `_current_sim_step()` 에서 오므로, 시계를 복원 안 하면 **배송이 과거나 미래에 도착한다.**

**Files:**
- Modify: `src/respec/asset_ledger.jl:95-102` (`sim_time()` 추가 — dt 를 곱한 초 단위)
- Modify: `tools/monitor/run_demo.jl:79, 291, 778, 798` (`_SIM_STEP` 제거 → `CB.SIM_STEP[]`)
- Modify: `src/mdp/hazard.jl:401` (`st.step` 을 `SIM_STEP[]` 에 동기화)
- Test: `test/mdp_clock_smoke.jl`

**Interfaces:**
- Consumes: `CB.SIM_STEP` · `CB.set_sim_step!(k)` · `CB._current_sim_step()` (기존)
- Produces: `CB.sim_time(dt) -> Float64` — `dt * SIM_STEP[]`. `run_demo` 의
  `"sim_t_at"` 과 `HazardState.t` 가 **같은 출처**를 쓰게 만든다.

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_clock_smoke.jl
# spec §3.3 Clock — 시계가 셋이었다. Courier.step_out/step_swap 이 절대 스텝 인덱스라
# 시계를 복원 안 하면 배송이 과거나 미래에 도착한다.
#
#   julia +lts --project=. test/mdp_clock_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

@testset "sim_time 은 SIM_STEP 에서 유도된다" begin
    CB.set_sim_step!(0)
    @test CB.sim_time(0.025) == 0.0
    CB.set_sim_step!(120)
    @test CB.sim_time(0.025) ≈ 3.0
    @test CB._current_sim_step() == 120
end

@testset "hazard 시계가 SIM_STEP 과 어긋나지 않는다" begin
    CB.set_sim_step!(0)
    st = CB._new_hazard_state(CB.HazardParams(), 0)
    @test st.step == 0
    CB.set_sim_step!(7)
    CB._hz_sync_clock!(st)
    @test st.step == 7
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
julia +lts --project=. test/mdp_clock_smoke.jl
```
기대: **FAIL** — `UndefVarError: sim_time not defined`.

- [ ] **Step 3: 시계 접근자를 만든다**

`src/respec/asset_ledger.jl` 의 `_current_sim_step() = SIM_STEP[]` 다음 줄:

```julia
# 시계 단일 진실원 (spec §3.3 Clock · §11-8). 예전에는 시계가 셋이었다 —
# SIM_STEP · HazardState.t/.step · run_demo._SIM_STEP. Courier.step_out/step_swap 이
# **절대 스텝 인덱스**이므로 시계가 갈리면 배송이 과거나 미래에 도착한다.
# 초 단위가 필요한 소비처는 이 함수를 쓴다 — dt 를 각자 곱하지 말 것.
sim_time(dt::Real) = Float64(dt) * SIM_STEP[]
```

- [ ] **Step 4: `run_demo` 의 사설 시계를 없앤다**

- `tools/monitor/run_demo.jl:79` 의 `const _SIM_STEP = Ref(0)` 를 **지운다.**
- `:291` 의 `"sim_t_at" => (try Float64(env.dt) * _SIM_STEP[] catch; nothing end),` 를
  `"sim_t_at" => (try CB.sim_time(env.dt) catch; nothing end),` 로 바꾼다.
- `:778` 의 `CB.step_environment!(env); _SIM_STEP[] = 1` 를
  `CB.step_environment!(env); CB.set_sim_step!(1)` 로.
- `:798` 의 `CB.step_environment!(env); _SIM_STEP[] = k` 를
  `CB.step_environment!(env); CB.set_sim_step!(k)` 로.

⚠️ `ood_injection.jl:1171` 이 이미 매 스텝 `set_sim_step!(k)` 를 부른다 — 두 곳이 같은 `k` 를
쓰는지 확인할 것. 어긋나면 `run_demo` 쪽을 지우고 `ood_injection` 쪽 하나만 남긴다.

- [ ] **Step 5: hazard 시계를 동기화한다**

`src/mdp/hazard.jl` 의 `hazard_step!`(현 `:395`) 안, `st.t += dt; st.step += 1` 을 바꾼다:

```julia
    st.t += dt
    _hz_sync_clock!(st)      # 스텝은 전역 시계에서 받는다 (spec §11-8 단일 진실원)
```

그리고 `hazard_step!` 위에:

```julia
# hazard 의 스텝 카운터를 전역 시계(SIM_STEP)에 맞춘다. 자기 카운터를 따로 증가시키면
# restore! 뒤에 둘이 어긋나고, Courier 의 절대 스텝 인덱스가 그 차이만큼 밀린다.
# `SIM_STEP[] == 0`(= 아직 셋업 전)이면 자기 카운터를 유지한다 — 단위검사 경로가 그렇다.
function _hz_sync_clock!(st::HazardState)
    s = _current_sim_step()
    st.step = s > 0 ? s : st.step + 1
    return st.step
end
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_clock_smoke.jl
julia +lts --project=. test/mdp_hazard_smoke.jl
julia +lts --project=. test/mdp_crn_smoke.jl
```
기대: 전부 PASS.

- [ ] **Step 7: `sim_t_at` 이 회귀하지 않았는지 실측한다**

```bash
cd /home/chahj578/Construction_OODlayer
DEMO_HAZARD=0 DEMO_SUMMARY=/tmp/clock.jsonl OOD_SEED=1 DEMO_CASE=battery \
  julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
python3 -c "
import json
r=json.loads(open('/tmp/clock.jsonl').readline())
ts=[d['sim_t_at'] for d in r['decisions']]
print('sim_t_at:', ts)
assert all(t is not None for t in ts), 'sim_t_at 이 nothing 이다 — 시계 배선이 끊겼다'
assert ts == sorted(ts), 'sim_t_at 이 단조가 아니다'
assert ts[-1] <= r['makespan'] + 1e-6, 'sim_t_at 이 makespan 을 넘는다'
print('OK')
"
```
기대: `OK`, 그리고 값들이 태스크 3 이전 실측(`0.025 → 3.1 → 6.7 → …`)과 **같은 자릿수**여야 한다.
자릿수가 갈리면 `SIM_STEP` 과 `_SIM_STEP` 이 서로 다른 `k` 를 세고 있었던 것이므로,
**어느 쪽이 옳은지 먼저 규명하고** 진행한다.

- [ ] **Step 8: 커밋**

```bash
git add src/respec/asset_ledger.jl src/mdp/hazard.jl tools/monitor/run_demo.jl test/mdp_clock_smoke.jl
git commit -m "refactor(clock): 시계 셋을 SIM_STEP 하나로 (spec §3.3 Clock · §11-8)"
```

---

## 태스크 9: `SimState` 타입 · 정준 직렬화 · 콘텐츠 해시 (spec §3.2·§3.3·§3.5)

> **`s` 가 해시 가능해야 하는 이유**: 층(L2·L3·L4)을 없애면 "같은 칸인가"를 판정하던 dp 격자가
> 사라진다. 그 자리를 `hash(s)` 가 메운다 — 롤아웃 dedup · G-M 검사 · 상태 재방문 탐지가
> 전부 그 위에 선다. `MersenneTwister` 같은 불투명 객체가 `s` 안에 있으면 불가능하다.
> **난수원을 `ξ` 로 빼는 것은 편의가 아니라 요구사항이다.**
>
> **`cum_*`/`thr_*` 을 `s` 에 넣지 않는다**(spec §3.4): `thr ~ Exp(1)` 의 무기억성에 의해
> `thr − cum(t) | {thr > cum(t)} ~ Exp(1)` 이므로 `cum(t)` 은 미래에 정보를 하나도 안 나른다.
> 반대로 `thr` 을 넣으면 발화 시각이 `s` 로부터 **결정론**이 되어 K-rollout 이 K개 같은 결과를 낸다.
> **예외 하나: `expired_r ∈ {0,1}`** — `_hz_fire_break!` 가 유예하면서 아무것도 리셋하지 않아
> "만료됐는데 대기 중"이 관측 물리량으로 복원되지 않는다. **값이 아니라 불리언만** 넣는다.

**Files:**
- Create: `src/mdp/simstate.jl`
- Modify: `src/mdp/mdp.jl` (include)
- Test: `test/mdp_simstate_smoke.jl`

**Interfaces:**
- Consumes: `CB.STATE_GLOBALS` (태스크 7)
- Produces:
  - `CB.RobotRec` — `pose·vel·soc·energy_J·usage_s·eff·health·stalled·payload·role`
  - `CB.CourierRec` — `target·courier·depot·home·goal·phase·step_out·step_swap`
  - `CB.SimState` — `g·geo·fleet·hazard·courier·clock·age·event`
  - `CB.ReplayState` — `cum·thr·rng·pending_drop·cache_counter`
  - `CB.canonical(s) -> String` — 정준 직렬화. 모든 `Set`/`Dict` 를 **정렬**한다
  - `CB.state_hash(s) -> String` — `bytes2hex(sha256(canonical(s)))[1:32]`

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_simstate_smoke.jl
# spec §3 — s 는 콘텐츠 해시가 가능해야 한다. 그 성질이 깨지는 방식은 둘뿐이다:
#   (1) 불투명 객체(MersenneTwister·RVO 핸들)가 s 안에 있다 → ξ 로 빼서 막는다
#   (2) Set/Dict 순회 순서가 직렬화에 새어든다 → 정렬 직렬화로 막는다
#
#   julia +lts --project=. test/mdp_simstate_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

_rec(id; soc = 1.0, usage = 0.0) = CB.RobotRec(
    id = id, pose = (1.0, 2.0, 0.5), vel = (0.0, 0.0), soc = soc,
    energy_J = 10.0, usage_s = usage, eff = 1.0, health = :healthy,
    stalled = false, payload = nothing, role = :transport)

function _state(; robots = [1, 2, 3], no_progress = 0, snap = 0, zones = [:z1])
    CB.SimState(
        g = CB.GraphBlock(n_nodes = 5, edges = Set([(1, 2), (2, 3), (3, 4), (4, 5)]),
                          closed = Set([1, 2]), active = Set([3]),
                          binding = Dict(3 => 1), edge_bias = Dict((1, 2) => 1.5),
                          wedge_edges = Set([(1, 3)]), dissolved_gates = Set{Tuple{Int,Int}}()),
        geo = CB.GeoBlock(poses = Dict(10 => (0.0, 0.0, 0.0)), zones = Set(zones),
                          build_delta = (0.0, 0.0)),
        fleet = Dict(r => _rec(r) for r in robots),
        hazard = CB.HazardBlock(lambda0 = Dict(r => 1.0e-4 for r in robots),
                                mode = :nominal, broken = Set{Int}(),
                                expired_break = Set{Int}(), expired_cell = Set{Int}()),
        courier = CB.CourierRec[], clock = CB.ClockBlock(t = 1.0, step = 40),
        age = CB.AgeBlock(no_progress = no_progress, snap_count = snap),
        event = CB.EventBlock(kind = :battery, robot = 1, severity = 0.3))
end

@testset "정준 직렬화는 삽입 순서에 무관하다" begin
    a = _state(robots = [1, 2, 3], zones = [:z1, :z2])
    b = _state(robots = [3, 1, 2], zones = [:z2, :z1])
    @test CB.canonical(a) == CB.canonical(b)
    @test CB.state_hash(a) == CB.state_hash(b)
end

@testset "s 가 다르면 해시가 다르다" begin
    @test CB.state_hash(_state(no_progress = 119)) != CB.state_hash(_state(no_progress = 120))
    @test CB.state_hash(_state(snap = 2)) != CB.state_hash(_state(snap = 3))
end

@testset "Age 블록이 s 안에 있다 — C1 위반을 잡는 그 변수다" begin
    txt = CB.canonical(_state(no_progress = 120, snap = 3))
    @test occursin("no_progress=120", txt)
    @test occursin("snap_count=3", txt)
end

@testset "ξ 는 s 안에 없다 — 불투명 객체 금지" begin
    txt = CB.canonical(_state())
    @test !occursin("MersenneTwister", txt)
    @test !occursin("cum_", txt)      # 무기억성: cum 은 미래에 정보를 안 나른다 (spec §3.4)
    @test !occursin("thr_", txt)      # thr 을 넣으면 발화 시각이 결정론이 된다
end

@testset "expired 는 값이 아니라 불리언이다 (spec §3.4 예외)" begin
    h0 = CB.HazardBlock(lambda0 = Dict(1 => 1.0e-4), mode = :nominal, broken = Set{Int}(),
                        expired_break = Set([1]), expired_cell = Set{Int}())
    h1 = CB.HazardBlock(lambda0 = Dict(1 => 1.0e-4), mode = :nominal, broken = Set{Int}(),
                        expired_break = Set{Int}(), expired_cell = Set{Int}())
    @test CB.canonical(h0) != CB.canonical(h1)
    @test occursin("expired_break=[1]", CB.canonical(h0))
end

@testset "해시는 32자 hex" begin
    h = CB.state_hash(_state())
    @test length(h) == 32 && all(c -> c in "0123456789abcdef", h)
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_simstate_smoke.jl
```
기대: **FAIL** — `UndefVarError: RobotRec not defined`.

- [ ] **Step 3: 타입과 직렬화를 구현한다**

```julia
# src/mdp/simstate.jl
# =============================================================================
# spec §3 — 상태를 L1 하나로 통일한다.
#
#   s   Markov 상태.  모델 입력. 값(value)이고 콘텐츠 해시가 가능해야 한다.
#   ξ   재생 상태.    restore! 와 CRN 만 쓴다. s 에 넣지 않는다.
#   log 상태 아님.    스냅샷 대상도 아니다.
#
# 왜 쪼개는가: 안 쪼개면 두 요구가 서로 모순한다.
#   G1(§7)  : restore!(snapshot(env)) 후 같은 시드 → 바이트 동일 (난수 위치를 복원해야 성립)
#   §6.3    : 같은 s 에서 K번 재출발해 서로 다른 미래를 본다 (난수를 복원하면 K개가 전부 같아짐)
# hazard.jl 이 이미 답을 갖고 있다 — **문턱은 재생 대상, 비율은 상태.**
#
# 표현층(φ · ψ · 22차원 feature · dp 격자)을 만들지 않는다(spec §3.1·§4). 학습된 표현이
# 필요해지면 그것은 s 의 **파생**이고, 무엇을 남길지는 설계가 아니라 ablation 이 정한다.
# =============================================================================

import SHA
using Base: @kwdef

# --- 블록 --------------------------------------------------------------------------------

"attributed schedule DAG. 위상만으로는 부족하다 — Replace 의 핵심 편집(replace_in_schedule!)은
로봇 id 를 **재스탬프**할 뿐 위상을 안 바꾼다. 그래서 `binding` 이 필수다."
@kwdef struct GraphBlock
    n_nodes::Int
    edges::Set{Tuple{Int,Int}}          # precedence + 배정 엣지. 태스크 14 의 T_plan 이 쓴다
    closed::Set{Int}
    active::Set{Int}
    binding::Dict{Int,Int}              # 정점 → 바인딩된 로봇 id
    edge_bias::Dict{Tuple{Int,Int},Float64}   # AGENT_COST_BIAS 가 만드는 가중치 배수
    wedge_edges::Set{Tuple{Int,Int}}    # 🔴 ReformTeam 이 G 에 남기는 영구 편집 (spec §5.4-b)
    dissolved_gates::Set{Tuple{Int,Int}}
end

"기하. 운반 중이 아닌 부품/조립체의 world pose · 활성 no-go 구역 · 누적 build translation Δ."
@kwdef struct GeoBlock
    poses::Dict{Int,NTuple{3,Float64}}
    zones::Set{Symbol}
    build_delta::NTuple{2,Float64}
end

"""로봇 하나의 레코드. 로봇 집합에는 **창고의 spare 도 포함한다**(실측 작업 10 + 예비 12 = 22).
`spares_left` 는 이 집합에서 유도되는 값이지 따로 들고 다니는 스칼라가 아니다."""
@kwdef struct RobotRec
    id::Int
    pose::NTuple{3,Float64}             # SE(2)
    vel::NTuple{2,Float64}              # 빼면 반응형 컨트롤러가 memoryless 가 아니다
    soc::Float64
    energy_J::Float64
    usage_s::Float64                    # hazard 항 β_u·usage. 빼면 F(τ|s,a) 정의 불능
    eff::Float64                        # 🔴 frailty. 한 번 뽑고 재추첨 없음 → 무기억성 미적용 → 상태다
    health::Symbol                      # :healthy | :degraded | :dead
    stalled::Bool                       # 🔴 SoC 0 으로 멈춰 선 로봇. 빼면 복구 판정이 갈린다
    payload::Union{Nothing,Int}
    role::Symbol                        # :transport|:team_member|:idle|:spare_parked|:courier
end

"""비율의 인자와 발화 상태만. **누적값(cum_*)과 문턱(thr_*)은 안 넣는다**(spec §3.4).
예외: `expired_*` — `_hz_fire_break!` 가 유예하면서 아무것도 리셋하지 않아 "만료됐는데 대기 중"
상태가 관측 물리량 `(usage, soc, mode)` 만으로 복원되지 않는다. **값이 아니라 불리언만.**"""
@kwdef struct HazardBlock
    lambda0::Dict{Int,Float64}
    mode::Symbol
    broken::Set{Int}                    # 발화한 위험은 재발화 없음
    expired_break::Set{Int}
    expired_cell::Set{Int}
end

"배송 레코드. `target`/`courier` 는 **좌표가 아니라 로봇 id** 이고 `step_*` 는 **절대 스텝 인덱스**
(→ Clock 없이는 복원 불가)."
@kwdef struct CourierRec
    target::Int
    courier::Int
    depot::Symbol
    home::NTuple{2,Float64}
    goal::NTuple{2,Float64}
    phase::Symbol                       # :outbound | :returning
    step_out::Int
    step_swap::Int
end

"🔴 1차 개정이 빠뜨린 블록. Courier.step_out/step_swap 이 절대 스텝 인덱스라 필수다."
@kwdef struct ClockBlock
    t::Float64
    step::Int
end

"""🔴 **이 블록이 이 문제를 semi-Markov 로 만든다**(spec §5.4).
Ascione Thm 2.2: `X` 가 semi-Markov ⟺ `(X, γ)` 가 Markov. 이 둘이 그 age 과정 `γ` 다.
- `no_progress` — `maybe_emit_reform_ood!` 가 `% REFORM_INTERVAL == 0` 로 발화시킨다.
  **결정의 34%(485/1438)가 이 카운터에 걸려 있다** — 코너 케이스가 아니다.
- `snap_count`  — `>= SNAP_ESCALATE_AT(3)` 에서 복구 경로가 갈린다."""
@kwdef struct AgeBlock
    no_progress::Int
    snap_count::Int
end

"""이번 epoch 를 연 사건. SMDP 의 decision epoch 는 event-triggered 이므로 트리거한 사건이
상태의 일부다. ⚠️ **`kind` 는 kind 지름길의 입구다**(spec §4.4) — 모델에 넣을 때는 타입 라벨이
아니라 **물리적 귀결**로 넣고, 타입 문자열은 로그에만 남긴다. 방어선은 §6.4 의
leave-one-failure-type-out 행렬이고 그것이 유일한 방어선이다."""
@kwdef struct EventBlock
    kind::Symbol
    robot::Union{Nothing,Int}
    severity::Float64
end

"""s = (G, Geo, Fleet, Hazard, Courier, Clock, Age, e)  — spec §3.3 확정 정의."""
@kwdef struct SimState
    g::GraphBlock
    geo::GeoBlock
    fleet::Dict{Int,RobotRec}
    hazard::HazardBlock
    courier::Vector{CourierRec}
    clock::ClockBlock
    age::AgeBlock
    event::EventBlock
end

"""ξ — 재생 상태. **s 에 절대 안 들어간다.** restore! 와 CRN 만 쓴다.
`restore!(env, s, ξ')` 로 `ξ` 만 갈아 끼워 K 갈래를 만든다(spec §3.5 규칙 2)."""
@kwdef struct ReplayState
    cum_break::Dict{Int,Float64}
    thr_break::Dict{Int,Float64}
    cum_cell::Dict{Int,Float64}
    thr_cell::Dict{Int,Float64}
    cum_zone::Float64
    thr_zone::Float64
    rng_robot::Dict{Int,Random.MersenneTwister}
    rng_zone::Random.MersenneTwister
    pending_drop::Dict{Int,Float64}     # 태스크 2 의 CRN 캐시
    cache_counter::Int                  # _CACHE_TIMESTAMP_COUNTER
end

# --- 정준 직렬화 --------------------------------------------------------------------------
# spec §3.5 규칙 4: 모든 Set/Dict 는 **정렬해서** 직렬화한다. L5(_pick_active_robot 의 Set
# 순회, 태스크 4)의 일반형이다. 정렬을 빼면 같은 상태가 프로세스마다 다른 해시를 얻는다.

_c(x::Float64) = string(round(x; digits = 9))   # 부동소수 잡음이 해시를 갈리게 하지 않도록
_c(x::Union{Int,Bool,Symbol,Nothing}) = string(x)
_c(t::Tuple) = "(" * join(map(_c, t), ",") * ")"
_c(s::AbstractSet) = "[" * join(map(_c, sort!(collect(s); by = string)), ",") * "]"
_c(d::AbstractDict) = "{" * join(["$(_c(k)):$(_c(v))"
                                  for (k, v) in sort!(collect(d); by = p -> string(p[1]))], ",") * "}"

canonical(b::GraphBlock) = "G(n=$(b.n_nodes),edges=$(_c(b.edges)),closed=$(_c(b.closed))," *
    "active=$(_c(b.active)),"  *
    "bind=$(_c(b.binding)),bias=$(_c(b.edge_bias)),wedge=$(_c(b.wedge_edges))," *
    "dissolved=$(_c(b.dissolved_gates)))"

canonical(b::GeoBlock) = "Geo(poses=$(_c(b.poses)),zones=$(_c(b.zones)),delta=$(_c(b.build_delta)))"

canonical(r::RobotRec) = "R$(r.id)(pose=$(_c(r.pose)),vel=$(_c(r.vel)),soc=$(_c(r.soc))," *
    "E=$(_c(r.energy_J)),usage=$(_c(r.usage_s)),eff=$(_c(r.eff)),health=$(r.health)," *
    "stalled=$(r.stalled),payload=$(_c(r.payload)),role=$(r.role))"

canonical(b::HazardBlock) = "Hz(l0=$(_c(b.lambda0)),mode=$(b.mode),broken=$(_c(b.broken))," *
    "expired_break=$(_c(b.expired_break)),expired_cell=$(_c(b.expired_cell)))"

canonical(c::CourierRec) = "Cr(target=$(c.target),courier=$(c.courier),depot=$(c.depot)," *
    "home=$(_c(c.home)),goal=$(_c(c.goal)),phase=$(c.phase)," *
    "out=$(c.step_out),swap=$(c.step_swap))"

canonical(b::ClockBlock) = "Clk(t=$(_c(b.t)),step=$(b.step))"
canonical(b::AgeBlock)   = "Age(no_progress=$(b.no_progress),snap_count=$(b.snap_count))"
canonical(b::EventBlock) = "E(kind=$(b.kind),robot=$(_c(b.robot)),sev=$(_c(b.severity)))"

"""
    canonical(s::SimState) -> String

`s` 의 정준 문자열. **같은 상태는 프로세스가 달라도 같은 문자열을 낸다.**
`ReplayState` 에는 메서드를 정의하지 않는다 — ξ 는 해시 대상이 아니다.
"""
function canonical(s::SimState)
    fleet = join([canonical(s.fleet[k]) for k in sort!(collect(keys(s.fleet)))], ";")
    cour  = join(map(canonical, sort(s.courier; by = c -> (c.target, c.courier))), ";")
    return join([canonical(s.g), canonical(s.geo), "Fleet[$fleet]", canonical(s.hazard),
                 "Courier[$cour]", canonical(s.clock), canonical(s.age), canonical(s.event)], "|")
end

"""
    state_hash(s) -> String

`s` 의 콘텐츠 해시(sha256 앞 32자). dp 격자가 하던 "같은 칸인가" 판정을 이것이 대신한다 —
롤아웃 dedup · G-M 검사 · 상태 재방문 탐지가 전부 이 위에 선다(spec §3.2).
"""
state_hash(s) = bytes2hex(SHA.sha256(canonical(s)))[1:32]
```

`src/mdp/mdp.jl` 의 `include("hazard.jl")` **뒤**에:

```julia
include("simstate.jl")   # §3 상태 정의 (hazard 뒤 — HazardParams/HazardState 를 참조한다)
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_simstate_smoke.jl
```
기대: 여섯 testset 전부 PASS.

- [ ] **Step 5: 커밋**

```bash
git add src/mdp/simstate.jl src/mdp/mdp.jl test/mdp_simstate_smoke.jl
git commit -m "feat(mdp): SimState/ReplayState + 정준 직렬화 + 콘텐츠 해시 (spec §3)"
```

---

## 태스크 10: `snapshot(env) -> (s, ξ)` (spec §3.5 규칙 1·3)

**Files:**
- Modify: `src/mdp/snapshot.jl` (신규 파일 — 이 태스크가 만들고 태스크 11이 이어 쓴다)
- Modify: `src/mdp/mdp.jl` (include)
- Test: `test/mdp_snapshot_roundtrip.jl` (이 태스크는 `snapshot` 부분만)

**Interfaces:**
- Consumes: `CB.SimState`·`CB.ReplayState`·`CB.state_hash` (태스크 9) ·
  `CB.STATE_GLOBALS`·`CB.globals_with(:state)` (태스크 7) · `CB.sim_time` (태스크 8)
- Produces:
  - `CB.snapshot(env; event = nothing) -> Tuple{SimState,ReplayState}`
  - `CB.snapshot_globals_covered() -> Bool` — `globals_with(:state)` 의 모든 이름이 `snapshot`
    본문에서 실제로 읽히는지 자기 점검(테스트가 부른다)

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_snapshot_roundtrip.jl
# G1(spec §7) — 스냅샷 왕복. **둘 다 통과해야 한다**:
#   (a) restore!(env, s, ξ) 후 같은 시드 N 스텝 → 원본과 바이트 동일
#   (b) restore!(env, s, ξ') 로 ξ 만 갈면 결과가 **갈린다**
# 하나만 보면 spec §3.2 의 모순(재현 vs 분기)을 못 잡는다.
#
#   julia +lts --project=. test/mdp_snapshot_roundtrip.jl
using ConstructionBots
using Test
using Random
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))

# 작은 씬 하나. 전체 tractor 빌드(313노드)는 판당 ~50s 라 단위검사에 안 맞는다 —
# test_demo.jl 이 쓰는 최소 모델과 같은 경로를 쓴다.
function _tiny_env()
    env = CB.run_lego_demo(; ldraw_file = CB.DEMO_TINY_MODEL, project_name = "snapshot_smoke",
                           num_robots = 4, assignment_mode = :greedy, save_animation = false,
                           write_results = false, overwrite_results = true,
                           n_spare_per_pool = 1, return_env_before_sim = true,
                           rng = Random.MersenneTwister(0))
    CB.enable_battery!(env; params = CB.BatteryParams())
    CB.enable_hazard!(env; seed = 0)
    CB.set_sim_step!(0)
    for k in 1:20
        CB.step_environment!(env); CB.set_sim_step!(k)
    end
    return env
end

@testset "snapshot 이 s 와 ξ 를 분리해서 낸다" begin
    env = _tiny_env()
    s, xi = CB.snapshot(env)
    @test s isa CB.SimState
    @test xi isa CB.ReplayState
    @test length(CB.state_hash(s)) == 32
    # 난수원이 s 로 새지 않았다
    @test !occursin("MersenneTwister", CB.canonical(s))
    # 시계가 실려 있다 (Courier 의 절대 스텝 인덱스가 여기 딸린다)
    @test s.clock.step == CB._current_sim_step()
end

@testset "같은 env 를 두 번 찍으면 같은 해시" begin
    env = _tiny_env()
    s1, _ = CB.snapshot(env)
    s2, _ = CB.snapshot(env)
    @test CB.state_hash(s1) == CB.state_hash(s2)
end

@testset "한 스텝 굴리면 해시가 갈린다" begin
    env = _tiny_env()
    s1, _ = CB.snapshot(env)
    CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1)
    s2, _ = CB.snapshot(env)
    @test CB.state_hash(s1) != CB.state_hash(s2)
end

@testset "s 로 가는 전역이 전부 읽힌다" begin
    @test CB.snapshot_globals_covered()
end
```

⚠️ `CB.DEMO_TINY_MODEL` 이 없으면 `test/test_demo.jl` 이 실제로 쓰는 모델 상수/경로를
그대로 가져다 쓴다 — **새 리터럴 경로를 만들지 않는다.**

```bash
grep -n "ldraw_file\|MODEL\|num_robots" test/test_demo.jl | head
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_snapshot_roundtrip.jl
```
기대: **FAIL** — `UndefVarError: snapshot not defined`.

- [ ] **Step 3: `snapshot` 을 구현한다**

```julia
# src/mdp/snapshot.jl
# =============================================================================
# spec §3.5 — snapshot(env) -> (s, ξ) 와 restore!(env, s, ξ) 가 왕복한다.
#
# 규칙 3: **전역을 읽지 않는다.** state_globals.jl 의 목록을 흡수하거나 최소한 스냅샷/복원
# 대상에 명시적으로 포함한다. "어딘가에 있다" 로 두면 롤아웃마다 조용히 오염된다.
# `snapshot_globals_covered()` 가 그 규칙을 기계로 지킨다.
#
# ✅ RVO 복원 가능성은 확인됐다(spec §3.6): rvo2.PyRVOSimulator 는 C++ 객체지만 에이전트
# 상태 전량에 setter 가 있고, ORCA line/neighbor list 는 doStep 마다 재계산되는 파생값이다.
# 이 레포는 addObstacle/processObstacles 를 한 번도 안 쓰고 getGlobalTime 을 읽는 코드가 없다.
# =============================================================================

_rid(x) = try Int(x.id) catch; Int(x) end

"현재 env + 전역에서 s(Markov 상태)와 ξ(재생 상태)를 뽑는다. env 를 **수정하지 않는다.**"
function snapshot(env; event = nothing)
    sched = env.sched
    hz = HAZARD_STATE[]

    g = GraphBlock(
        n_nodes = Graphs.nv(sched),
        # 정렬해서 담는다 — 태스크 14 의 T_plan 이 위상정렬에 쓰고, 정렬이 없으면 같은 상태가
        # 프로세스마다 다른 해시를 얻는다(spec §3.5 규칙 4).
        edges = Set{Tuple{Int,Int}}((Graphs.src(e), Graphs.dst(e)) for e in Graphs.edges(sched)),
        closed  = Set{Int}(env.cache.closed_set),
        active  = Set{Int}(env.cache.active_set),
        binding = Dict{Int,Int}(v => _rid(entity(get_node_from_id(sched, get_vtx_id(sched, v))).id)
                                for v in Graphs.vertices(sched)
                                if get_node_from_id(sched, get_vtx_id(sched, v)) isa RobotGo),
        edge_bias = Dict{Tuple{Int,Int},Float64}(),   # AGENT_COST_BIAS 는 로봇 키라 아래에서 편다
        wedge_edges = Set{Tuple{Int,Int}}(WEDGE_EDGES[]),
        dissolved_gates = Set{Tuple{Int,Int}}(DISSOLVED_GATES[]))

    geo = GeoBlock(
        poses = Dict{Int,NTuple{3,Float64}}(),        # 아래 _collect_poses! 가 채운다
        zones = Set{Symbol}(keys(RESTRICTION_ZONES[])),
        build_delta = _build_delta(env))

    fleet = Dict{Int,RobotRec}()
    bf = BATTERY_FLEET[]
    for id in _hz_all_robots(env)
        r = _rid(id)
        fleet[r] = RobotRec(
            id = r,
            pose = _pose2d(env, id),
            vel  = _vel2d(env, id),
            soc  = bf === nothing ? 1.0 : Float64(get(bf.soc, id, 1.0)),
            energy_J = bf === nothing ? 0.0 : Float64(get(bf.energy_J, id, 0.0)),
            usage_s  = hz === nothing ? 0.0 : Float64(get(hz.usage_s, id, 0.0)),
            eff      = hz === nothing ? 1.0 : Float64(get(hz.eff, id, 1.0)),
            health   = _health_of(id, hz),
            stalled  = id in STALLED_ROBOTS[],
            payload  = _payload_of(env, id),
            role     = _role_of(id))
    end

    hazard = HazardBlock(
        lambda0 = hz === nothing ? Dict{Int,Float64}() :
                  Dict{Int,Float64}(_rid(k) => Float64(v) for (k, v) in hz.lambda),
        mode = _global_mode(hz),
        broken = hz === nothing ? Set{Int}() : Set{Int}(_rid(x) for x in hz.broken),
        # 🔴 spec §3.4 예외 — "이 로봇의 시계가 이미 만료됐는데 발화가 유예됐다".
        # 값이 아니라 **불리언만**. 값(cum/thr)을 넣으면 발화 시각이 s 로부터 결정론이 된다.
        expired_break = hz === nothing ? Set{Int}() :
            Set{Int}(_rid(k) for (k, c) in hz.cum_break
                     if c >= get(hz.thr_break, k, Inf) && !(k in hz.broken)),
        expired_cell = hz === nothing ? Set{Int}() :
            Set{Int}(_rid(k) for (k, c) in hz.cum_cell if c >= get(hz.thr_cell, k, Inf)))

    courier = CourierRec[]
    for (_, d) in BATTERY_DELIVERIES[]
        push!(courier, CourierRec(
            target = _rid(d.target), courier = _rid(d.courier), depot = Symbol(d.depot),
            home = (Float64(d.home[1]), Float64(d.home[2])),
            goal = (Float64(d.goal[1]), Float64(d.goal[2])),
            phase = Symbol(d.phase), step_out = Int(d.step_out), step_swap = Int(d.step_swap)))
    end

    s = SimState(
        g = g, geo = _collect_poses!(geo, env), fleet = fleet, hazard = hazard,
        courier = courier,
        clock = ClockBlock(t = sim_time(env.dt), step = _current_sim_step()),
        age = AgeBlock(no_progress = _current_no_progress(), snap_count = SNAP_COUNT[]),
        event = event === nothing ? EventBlock(kind = :none, robot = nothing, severity = 0.0) : event)

    xi = ReplayState(
        cum_break = hz === nothing ? Dict{Int,Float64}() : Dict(_rid(k) => v for (k, v) in hz.cum_break),
        thr_break = hz === nothing ? Dict{Int,Float64}() : Dict(_rid(k) => v for (k, v) in hz.thr_break),
        cum_cell  = hz === nothing ? Dict{Int,Float64}() : Dict(_rid(k) => v for (k, v) in hz.cum_cell),
        thr_cell  = hz === nothing ? Dict{Int,Float64}() : Dict(_rid(k) => v for (k, v) in hz.thr_cell),
        cum_zone  = hz === nothing ? 0.0 : hz.cum_zone,
        thr_zone  = hz === nothing ? 0.0 : hz.thr_zone,
        rng_robot = hz === nothing ? Dict{Int,Random.MersenneTwister}() :
                    Dict(_rid(k) => copy(v) for (k, v) in hz.rng_robot),
        rng_zone  = hz === nothing ? Random.MersenneTwister(0) : copy(hz.rng_zone),
        pending_drop = hz === nothing ? Dict{Int,Float64}() :
                       Dict(_rid(k) => v for (k, v) in hz.pending_drop),
        cache_counter = _CACHE_TIMESTAMP_COUNTER[])

    return (s, xi)
end

"""
    snapshot_globals_covered() -> Bool

`globals_with(:state)` 의 모든 이름이 이 파일 본문에 **문자로 나타나는가.** 새 상태 전역이
생겼는데 snapshot 이 안 읽으면 롤아웃마다 조용히 오염된다 — 그 실패 모양을 여기서 닫는다.
⚠️ 문자열 포함 검사는 약한 보장이다(주석에만 있어도 통과한다). 진짜 판정은 G1(태스크 12)이 한다.
"""
function snapshot_globals_covered()
    src = read(@__FILE__, String)
    missing = [g for g in globals_with(:state) if !occursin(String(g), src)]
    isempty(missing) || @warn "snapshot 이 안 읽는 상태 전역" missing
    return isempty(missing)
end
```

**보조 함수 여섯 개는 이 파일 안에 같이 만든다.** 각각이 읽어야 할 자리:

| 함수 | 무엇을 읽는가 | 확인 명령 |
|---|---|---|
| `_pose2d(env, id)` | `env.scene_tree` 의 로봇 pose | `grep -n "global_transform\|get_node(.*scene_tree" src/navigator/*.jl \| head` |
| `_vel2d(env, id)` | RVO agent 속도 | `grep -n "getAgentVelocity\|rvo_" src/rvo_interface.jl \| head` |
| `_payload_of(env, id)` | `scene_tree` 부모관계 | `grep -n "cargo\|parent" src/navigator/route_planning.jl \| head` |
| `_role_of(id)` | `SPARE_POOLS`·`RECOVERY_SPARES`·`CHECKED_OUT_SPARES`·`is_battery_courier` | `grep -n "is_spare\|is_recovery_spare\|is_battery_courier" src/respec/ood_injection.jl \| head` |
| `_health_of(id, hz)` | `FAULTED_ROBOTS` + `hz.broken` + `DECOMMISSIONED_BODIES` | `grep -n "FAULTED_ROBOTS\|DECOMMISSIONED" src/respec/ood_injection.jl \| head` |
| `_current_no_progress()` | 🔴 **지금 전역이 아니다** — `maybe_emit_reform_ood!(no_progress)` 의 **인자**다 | `grep -rn "maybe_emit_reform_ood!\|no_progress" src/ tools/ \| head` |

🔴 **`_current_no_progress()` 는 이 태스크의 실제 작업이다.** `no_progress` 가 지금 어디에도
저장되지 않고 호출부의 지역변수로만 산다(spec §1.5 가 "✗"로 표시한 항목). 상태로 만들려면
`src/respec/ood_injection.jl` 에 `const NO_PROGRESS = Ref(0)` 를 만들고 그 호출부가 갱신하게
해야 한다. **그러면 `STATE_GLOBALS` 에도 `:NO_PROGRESS => :state` 를 추가해야 한다**(태스크 7의
테스트가 그것을 강제한다). `AgeBlock.no_progress` 가 없으면 spec §5.4-(a)의 C1 위반
— **결정의 34%** — 이 그대로 남는다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_snapshot_roundtrip.jl
```
기대: 네 testset PASS(이 태스크에서는 `restore!` 테스트가 아직 없다).
`s 로 가는 전역이 전부 읽힌다` 가 실패하면 그 이름을 `snapshot` 본문에서 실제로 읽게 고친다 —
주석으로 때우지 말 것.

- [ ] **Step 5: 커밋**

```bash
git add src/mdp/snapshot.jl src/mdp/mdp.jl src/mdp/state_globals.jl \
        src/respec/ood_injection.jl test/mdp_snapshot_roundtrip.jl
git commit -m "feat(mdp): snapshot(env) -> (s, ξ) + no_progress 를 전역 상태로 승격 (spec §3.5·§5.4-a)"
```

---

## 태스크 11: `restore!(env, s, ξ)` + RVO 복원 (spec §3.5 규칙 1·2)

> **`restore!(env, s, ξ')` 로 K 갈래를 만든다** — `ξ'` 만 갈아 끼우고 `s` 는 그대로. CRN 이
> `ξ` 안에 있으므로 팔 간 비교가 문턱을 공유한다. hazard.jl 의 CRN 주석이 그렇게 설계했다고
> 명시한다: *"문턱 `E_r` 은 실행 시작 전에 뽑히므로 팔마다 동일하고, 팔마다 달라지는 것은
> `Λ_r(t)=∫λ` 의 적분 경로뿐 — 그게 바로 우리가 재려는 인과효과다."*
>
> **이것이 closed loop 의 선행조건이다**(spec §6.3): assimilation loop 의 "restore!(s, ξ_j) 로
> 모든 팔 K-rollout" 행이 지금은 **원리적으로 실행 불가능**하다. 같은 `s` 로 되돌아갈 방법이 없다.

**Files:**
- Modify: `src/mdp/snapshot.jl` (`restore!` 추가)
- Modify: `src/rvo_interface.jl` (`rvo_set_agent_velocity!` 래퍼가 없으면 추가)
- Test: `test/mdp_snapshot_roundtrip.jl` (복원 testset 추가)

**Interfaces:**
- Consumes: `CB.snapshot` (태스크 10) · `CB.rvo_set_agent_position!` ·
  `CB.rvo_set_agent_pref_velocity!` (`src/rvo_interface.jl:224,231`)
- Produces:
  - `CB.restore!(env, s::SimState, xi::ReplayState) -> env` — env 와 전역을 `(s, ξ)` 로 되돌린다
  - `CB.fork(xi::ReplayState, j::Int) -> ReplayState` — 같은 `s` 에서 j 번째 갈래를 만든다.
    **문턱(`thr_*`)은 그대로 두고 RNG 스트림만 j 로 재파생한다** — 그래야 CRN 이 산다
  - `CB.rvo_set_agent_velocity!(node, vel)` (없으면 신규)

- [ ] **Step 1: 실패 테스트를 쓴다**

`test/mdp_snapshot_roundtrip.jl` 에 이어 붙인다:

```julia
@testset "G1(a) — restore! 후 같은 시드로 굴리면 바이트 동일" begin
    env = _tiny_env()
    s0, xi0 = CB.snapshot(env)
    ref = String[]
    for k in 1:30
        CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1)
        push!(ref, CB.state_hash(CB.snapshot(env)[1]))
    end

    CB.restore!(env, s0, xi0)
    @test CB.state_hash(CB.snapshot(env)[1]) == CB.state_hash(s0)   # 복원 직후가 원본
    got = String[]
    for k in 1:30
        CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1)
        push!(got, CB.state_hash(CB.snapshot(env)[1]))
    end
    @test got == ref                                                # 궤적이 바이트 동일
end

@testset "G1(b) — ξ 만 갈면 결과가 갈린다" begin
    env = _tiny_env()
    s0, xi0 = CB.snapshot(env)
    CB.restore!(env, s0, xi0)
    a = [ (CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1);
           CB.state_hash(CB.snapshot(env)[1])) for _ in 1:60 ]

    CB.restore!(env, s0, CB.fork(xi0, 7))
    b = [ (CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1);
           CB.state_hash(CB.snapshot(env)[1])) for _ in 1:60 ]

    # 안 갈리면 ξ 분할이 틀린 것이다 — 난수가 s 쪽에 남아 있거나 fork 가 무동작이다.
    @test a != b
end

@testset "fork 는 문턱을 보존한다 (CRN)" begin
    _, xi = CB.snapshot(_tiny_env())
    f = CB.fork(xi, 3)
    @test f.thr_break == xi.thr_break     # 팔 간 비교가 같은 문턱을 공유해야 한다
    @test f.thr_cell  == xi.thr_cell
    @test f.thr_zone  == xi.thr_zone
    @test f.cum_break == xi.cum_break     # 적분 경로는 s 에서 이어진다
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_snapshot_roundtrip.jl
```
기대: 새 세 testset **FAIL** — `UndefVarError: restore! not defined`.

- [ ] **Step 3: `restore!` 와 `fork` 를 구현한다**

`src/mdp/snapshot.jl` 끝에:

```julia
"""
    restore!(env, s::SimState, xi::ReplayState) -> env

`env` 와 `state_globals.jl` 이 `:state`/`:replay`/`:split` 로 분류한 전역을 `(s, ξ)` 로 되돌린다.
`:log` 는 건드리지 않고(스냅샷 대상이 아니다), `:setup`/`:render`/`:meta` 도 안 건드린다.

RVO 복원: `rvo2` 는 C++ 객체지만 에이전트 상태 전량에 setter 가 있고, ORCA line/neighbor
list 는 `doStep` 마다 재계산되는 파생값이다. 이 레포는 `addObstacle`/`processObstacles` 를
한 번도 안 쓰고 `getGlobalTime` 을 읽는 코드가 없다 → **원리적 장벽이 없다**(spec §3.6).
"""
function restore!(env, s::SimState, xi::ReplayState)
    sched = env.sched

    # --- G ---------------------------------------------------------------------------
    empty!(env.cache.closed_set); union!(env.cache.closed_set, s.g.closed)
    empty!(env.cache.active_set); union!(env.cache.active_set, s.g.active)
    empty!(WEDGE_EDGES[]);      append!(WEDGE_EDGES[], sort!(collect(s.g.wedge_edges)))
    empty!(DISSOLVED_GATES[]);  union!(DISSOLVED_GATES[], s.g.dissolved_gates)
    empty!(AGENT_COST_BIAS[])
    _restore_edge_bias!(env, s.g.edge_bias)
    _restore_bindings!(env, s.g.binding)      # Replace 의 로봇 id 재스탬프를 되돌린다
    LAST_EDGE_COSTS[] = Dict{Tuple{Int,Int},Float64}()

    # --- Geo -------------------------------------------------------------------------
    empty!(RESTRICTION_ZONES[])
    _restore_zones!(env, s.geo.zones)
    _restore_poses!(env, s.geo.poses)
    _restore_build_delta!(env, s.geo.build_delta)

    # --- Fleet (+ RVO) ----------------------------------------------------------------
    bf = BATTERY_FLEET[]
    empty!(STALLED_ROBOTS[]); empty!(FAULTED_ROBOTS[]); empty!(CHECKED_OUT_SPARES[])
    for r in sort!(collect(keys(s.fleet)))          # 정렬 순회 (spec §3.5 규칙 4)
        rec = s.fleet[r]
        id = _id_of(env, r)
        _restore_pose!(env, id, rec.pose)
        rvo_set_agent_position!(_node_of(env, id), (rec.pose[1], rec.pose[2]))
        rvo_set_agent_velocity!(_node_of(env, id), rec.vel)
        if bf !== nothing
            bf.soc[id] = rec.soc
            bf.energy_J[id] = rec.energy_J
        end
        rec.stalled && push!(STALLED_ROBOTS[], id)
        rec.health === :dead && push!(FAULTED_ROBOTS[], id)
        rec.role === :courier && push!(CHECKED_OUT_SPARES[], id)
        _restore_role!(env, id, rec.role)
        _restore_payload!(env, id, rec.payload)
    end

    # --- Hazard: s 쪽 ------------------------------------------------------------------
    hz = HAZARD_STATE[]
    if hz !== nothing
        empty!(hz.broken); for r in sort!(collect(s.hazard.broken)); push!(hz.broken, _id_of(env, r)); end
        for (r, rec) in s.fleet
            id = _id_of(env, r)
            hz.usage_s[id] = rec.usage_s
            hz.eff[id]     = rec.eff
        end
        # --- Hazard: ξ 쪽 (문턱·누적·난수) -----------------------------------------
        empty!(hz.cum_break); empty!(hz.thr_break); empty!(hz.cum_cell); empty!(hz.thr_cell)
        empty!(hz.rng_robot); empty!(hz.pending_drop)
        for r in sort!(collect(keys(xi.thr_break)))
            id = _id_of(env, r)
            hz.cum_break[id] = get(xi.cum_break, r, 0.0)
            hz.thr_break[id] = xi.thr_break[r]
        end
        for r in sort!(collect(keys(xi.thr_cell)))
            id = _id_of(env, r)
            hz.cum_cell[id] = get(xi.cum_cell, r, 0.0)
            hz.thr_cell[id] = xi.thr_cell[r]
        end
        for r in sort!(collect(keys(xi.rng_robot)))
            hz.rng_robot[_id_of(env, r)] = copy(xi.rng_robot[r])
        end
        for r in sort!(collect(keys(xi.pending_drop)))
            hz.pending_drop[_id_of(env, r)] = xi.pending_drop[r]
        end
        hz.cum_zone = xi.cum_zone
        hz.thr_zone = xi.thr_zone
        copy!(hz.rng_zone, xi.rng_zone)
        hz.t = s.clock.t
        hz.step = s.clock.step
    end

    # --- Courier ------------------------------------------------------------------------
    empty!(BATTERY_DELIVERIES[])
    for c in sort(s.courier; by = c -> (c.target, c.courier))
        _restore_delivery!(env, c)
    end

    # --- Clock · Age --------------------------------------------------------------------
    set_sim_step!(s.clock.step)
    SNAP_COUNT[]   = s.age.snap_count
    NO_PROGRESS[]  = s.age.no_progress
    _CACHE_TIMESTAMP_COUNTER[] = xi.cache_counter

    return env
end

"""
    fork(xi::ReplayState, j::Int) -> ReplayState

같은 `s` 에서 `j` 번째 갈래를 만든다. **문턱(`thr_*`)과 누적(`cum_*`)은 그대로 두고
RNG 스트림만 `j` 로 재파생한다** — 그게 CRN 이다(spec §1.6). 문턱까지 다시 뽑으면 팔 간
비교가 서로 다른 문턱을 보게 되어 분산감소가 통째로 사라진다.

`_mix_seed` 를 쓰므로 스트림 시드가 **등록 순서와 무관**하다 → L5(`Set` 순회 비결정성)가
hazard 레인에는 원천적으로 없다.
"""
function fork(xi::ReplayState, j::Integer)
    rng = Dict{Int,Random.MersenneTwister}(
        r => Random.MersenneTwister(_mix_seed(Int(j), 0x1, r)) for r in keys(xi.rng_robot))
    return ReplayState(
        cum_break = copy(xi.cum_break), thr_break = copy(xi.thr_break),
        cum_cell  = copy(xi.cum_cell),  thr_cell  = copy(xi.thr_cell),
        cum_zone  = xi.cum_zone,        thr_zone  = xi.thr_zone,
        rng_robot = rng,
        rng_zone  = Random.MersenneTwister(_mix_seed(Int(j), 0x2, 0x0)),
        pending_drop = copy(xi.pending_drop),
        cache_counter = xi.cache_counter)
end
```

**보조 복원 함수 열 개**(`_restore_edge_bias!` · `_restore_bindings!` · `_restore_zones!` ·
`_restore_poses!` · `_restore_build_delta!` · `_restore_pose!` · `_restore_role!` ·
`_restore_payload!` · `_restore_delivery!` · `_id_of`/`_node_of`)는 태스크 10의 대응하는
읽기 함수와 **짝을 이룬다.** 각각을 쓸 때 그 읽기 함수가 무엇을 읽었는지 그대로 뒤집는다.
`NO_PROGRESS` 는 태스크 10에서 만든 전역이다.

`src/rvo_interface.jl` 에 속도 setter 래퍼가 없으면(`grep -n "setAgentVelocity" src/rvo_interface.jl`),
`rvo_set_agent_pref_velocity!`(`:231`)와 **같은 형태**로 추가한다:

```julia
"에이전트의 현재 속도를 직접 세팅(복원용). ORCA line/neighbor list 는 doStep 마다 재계산되는
파생값이므로 위치·속도만 되돌리면 시뮬레이터 상태가 복원된다(spec §3.6)."
function rvo_set_agent_velocity!(node, vel)
    idx = rvo_get_agent_idx(node)
    rvo_global_sim().setAgentVelocity(idx, (vel[1], vel[2]))
end
```
(`rvo_get_agent_idx` 의 실제 이름은 `:225`/`:232` 가 쓰는 것을 그대로 따를 것.)

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_snapshot_roundtrip.jl
```
기대: 일곱 testset 전부 PASS.

**실패 해석 가이드** — 이 두 실패는 서로 다른 것을 말한다:
- `G1(a)` 실패 = **`s`/`ξ` 에 빠진 것이 있다.** 첫 갈리는 인덱스에서 두 스냅샷의
  `canonical` 을 문자열로 diff 해 어느 블록인지 찾는다. 그것이 다음에 찾을 상태 변수다.
- `G1(b)` 실패(= `a == b`) = **`ξ` 분할이 틀렸다.** 난수가 `s` 쪽에 남아 있거나 `fork` 가
  실질적으로 무동작이다. 이쪽이 더 위험하다 — K-rollout 이 K개 같은 결과를 낸다는 뜻이다.

- [ ] **Step 5: 커밋**

```bash
git add src/mdp/snapshot.jl src/rvo_interface.jl test/mdp_snapshot_roundtrip.jl
git commit -m "feat(mdp): restore!(env, s, ξ) + fork(ξ, j) — 같은 s 에서 K 갈래 (spec §3.5·§6.3)"
```

---

## 태스크 12: G1 게이트 — 전체 씬에서 왕복 (spec §7)

> 태스크 11의 단위검사는 작은 씬이다. G1 은 **실제 스윕이 쓰는 씬**(313노드 tractor)에서
> `N=200` 스텝 왕복을 요구한다. spec §7: *"둘 다 통과해야 한다. 하나만 보면 §3.2 의 모순을 못 잡는다."*

**Files:**
- Create: `tools/monitor/gate_g1.jl`
- Test: 이 태스크 자체가 게이트다(별도 단위검사 없음 — 태스크 11이 로직을 이미 덮는다)

**Interfaces:**
- Consumes: `CB.snapshot` · `CB.restore!` · `CB.fork` · `CB.state_hash` (태스크 9~11)
- Produces: `tools/monitor/gate_g1.jl` — exit 0(PASS) / 1(FAIL). ENV `G1_STEPS`(기본 200) ·
  `G1_SEED`(기본 1) · `G1_CASE`(기본 `fault_battery`)

- [ ] **Step 1: 게이트를 쓴다**

```julia
# tools/monitor/gate_g1.jl
# =============================================================================
# G1 — 스냅샷 왕복 (spec §7). **양방향 둘 다 통과해야 한다:**
#   (a) restore!(env, s, ξ) 후 같은 시드 N 스텝 → 원본과 **바이트 동일**
#   (b) restore!(env, s, ξ') 로 ξ 만 갈면 **결과가 갈린다**
# 하나만 보면 spec §3.2 의 모순(재현 vs 분기)을 못 잡는다.
#
#   julia +lts --project=. tools/monitor/gate_g1.jl
#   G1_STEPS=400 G1_CASE=battery julia +lts --project=. tools/monitor/gate_g1.jl
# =============================================================================
import ConstructionBots as CB
using Random

CB.include(joinpath(pkgdir(CB), "src", "navigator", "navigator.jl"))
CB.include(joinpath(pkgdir(CB), "src", "mdp", "mdp.jl"))

const N     = try parse(Int, get(ENV, "G1_STEPS", "200")) catch; 200 end
const SEED  = try parse(Int, get(ENV, "G1_SEED", "1")) catch; 1 end
const WARM  = 300      # 스냅샷을 뜨기 전 굴리는 스텝 — 빌드 중반의 "재미있는" 상태에서 찍는다

# 스윕이 쓰는 것과 **같은 진입점**으로 씬을 만든다. 여기서 새 셋업 코드를 쓰면 게이트가
# 스윕과 다른 세계를 검사하게 된다.
ENV["OOD_SEED"]  = string(SEED)
ENV["DEMO_CASE"] = get(ENV, "G1_CASE", "fault_battery")
ENV["DEMO_HAZARD"] = "1"

include(joinpath(@__DIR__, "run_header.jl"))   # run_demo.jl 과 같은 셋업 경로를 재사용
env = build_env_for_gate()                     # ⚠️ run_header.jl 에 이 진입점이 없으면
                                               #    run_demo.jl 의 셋업 블록을 그대로 뽑아
                                               #    run_header.jl 에 함수로 만든다(복붙 금지).

for k in 1:WARM
    CB.step_environment!(env); CB.set_sim_step!(k)
end

trace(env, n) = [ (CB.step_environment!(env);
                   CB.set_sim_step!(CB._current_sim_step() + 1);
                   CB.state_hash(CB.snapshot(env)[1])) for _ in 1:n ]

s0, xi0 = CB.snapshot(env)
println(">>> G1: 스냅샷 @ step=$(s0.clock.step)  hash=$(CB.state_hash(s0))")

ref = trace(env, N)

CB.restore!(env, s0, xi0)
h_after = CB.state_hash(CB.snapshot(env)[1])
same_state = h_after == CB.state_hash(s0)
println(">>> G1: 복원 직후 해시 일치 = $same_state")

got = trace(env, N)
first_div = findfirst(i -> ref[i] != got[i], 1:N)
pass_a = first_div === nothing
println(">>> G1(a) 바이트 동일: ", pass_a ? "PASS" : "FAIL (첫 갈림 step +$first_div)")

CB.restore!(env, s0, CB.fork(xi0, 97))
alt = trace(env, N)
pass_b = alt != ref
println(">>> G1(b) ξ 를 갈면 갈린다: ", pass_b ? "PASS" : "FAIL (ξ 분할이 틀렸다 — 난수가 s 에 남아 있다)")

if !pass_a && first_div !== nothing
    # 어느 블록이 갈렸는지 바로 보여준다 — 그것이 다음에 찾을 상태 변수다.
    println("\n--- 첫 갈림 지점 진단 ---")
    CB.restore!(env, s0, xi0)
    for _ in 1:(first_div - 1)
        CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1)
    end
    CB.step_environment!(env); CB.set_sim_step!(CB._current_sim_step() + 1)
    println(CB.canonical(CB.snapshot(env)[1]))
    println("↑ 이 문자열을 원본 궤적의 같은 스텝과 diff 하라. 갈린 블록이 s 에 빠진 변수다.")
end

exit((same_state && pass_a && pass_b) ? 0 : 1)
```

- [ ] **Step 2: 게이트를 돌린다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/gate_g1.jl; echo "rc=$?"
```
기대: `G1(a) PASS` · `G1(b) PASS` · `rc=0`.

- [ ] **Step 3: 세 case 로 넓힌다 — 순차 실행**

```bash
for c in fault battery zone; do
  echo "=== $c ==="
  G1_CASE=$c julia +lts --project=. tools/monitor/gate_g1.jl; echo "rc=$?"
done
```
⚠️ **순차 실행**(Global Constraints). 셋 다 `rc=0` 이어야 태스크 13으로 간다.

`fault` 축에서만 실패하면 `_pick_active_robot`(태스크 4) 잔여이거나 `FAULTED_ROBOTS`/
`HOT_SWAP_ASSETS` 복원 누락이다. `zone` 축에서만 실패하면 `RESTRICTION_ZONES` 또는
`build_delta` 복원 누락이다. **어느 쪽이든 "다 잡았다"를 선언하지 않는다** — 진단 출력의
갈린 블록을 `s` 에 추가하고 다시 돌린다.

- [ ] **Step 4: 커밋**

```bash
git add tools/monitor/gate_g1.jl tools/monitor/run_header.jl
git commit -m "feat(gate): G1 스냅샷 왕복 — 바이트 동일 AND ξ 를 갈면 갈린다 (spec §7)"
```

---

## 태스크 13: G-M — Markov 검사 (spec §7·§11-10)

> **`Age`·`expired_r` 을 `s` 에 넣기 전후로 재서 §5.4 세 위반의 기여를 정량화한다.**
> 잔여 위반이 남으면 그것이 다음에 찾을 상태 변수다. **"다 잡았다"를 선언하지 않는다.**
>
> 검사: 서로 다른 궤적에서 도달한 `hash(s)` 가 같은 두 지점에서, 같은 팔로 이어지는 다음
> epoch `(s', τ)` 분포가 같은가(C1·C2 직접 검사).

**Files:**
- Modify: `tools/monitor/run_demo.jl` (`GM_TRACE` 로 가드된 계측 훅 — 별도 러너를 만들지 않는다.
  새 러너를 만들면 셋업이 갈려 **스윕과 다른 세계**를 재게 된다)
- Modify: `src/mdp/simstate.jl` (`strip_age(s)` — ablation 대조군)
- Create: `wm4spacecraft_manufacturing/smdp/gate_gm.py`
- Test: `wm4spacecraft_manufacturing/smdp/test_smdp_gates.py` 에 추가

**Interfaces:**
- Consumes: `CB.snapshot`·`CB.state_hash`·`CB.canonical`·`CB.AgeBlock` (태스크 9~11)
- Produces:
  - `state_trace.jsonl` 한 줄 = `{"s": hash, "s_full": canonical, "macro": str,
    "s_next": hash, "tau": float, "with_age": bool, "case": str, "seed": int}`
  - `gate_gm.violations(rows) -> dict` — `{"n_matched_pairs", "n_violating", "rate", "by_macro"}`

- [ ] **Step 1: ablation 헬퍼 `strip_age` 를 `simstate.jl` 에 넣는다**

로직을 `run_demo.jl` 에 두지 않는다 — 계측은 훅이고 의미는 상태 정의 쪽에 산다.
`src/mdp/simstate.jl` 의 `state_hash` 바로 위에:

```julia
"""
    strip_age(s::SimState) -> SimState

`Age` 와 `expired_*` 를 지운 `s`. **G-M ablation 의 대조군이다**(spec §11-10) —
이걸로 재면 §5.4 의 C1 위반 셋이 그대로 드러나야 하고, 원본 `s` 로 재면 줄어야 한다.
이 대조가 없으면 "Age 를 넣었더니 좋아졌다" 가 측정이 아니라 주장이 된다.
"""
strip_age(s::SimState) = SimState(
    g = s.g, geo = s.geo, fleet = s.fleet,
    hazard = HazardBlock(lambda0 = s.hazard.lambda0, mode = s.hazard.mode,
                         broken = s.hazard.broken,
                         expired_break = Set{Int}(), expired_cell = Set{Int}()),
    courier = s.courier, clock = s.clock,
    age = AgeBlock(no_progress = 0, snap_count = 0), event = s.event)
```

`test/mdp_simstate_smoke.jl` 에 한 testset 을 더한다:

```julia
@testset "strip_age 는 Age 와 expired 만 지운다" begin
    s = _state(no_progress = 120, snap = 3)
    a = CB.strip_age(s)
    @test a.age.no_progress == 0 && a.age.snap_count == 0
    @test isempty(a.hazard.expired_break) && isempty(a.hazard.expired_cell)
    @test CB.canonical(a.g) == CB.canonical(s.g)        # 나머지 블록은 그대로
    @test CB.state_hash(a) != CB.state_hash(s)
end
```

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_simstate_smoke.jl
```
기대: 새 testset 포함 전부 PASS.

궤적 덤프는 `tools/monitor/run_demo.jl` 안에 **가드된 계측**으로 넣는다(기본 OFF — `GM_TRACE`
가 없으면 스윕 산출물에 영향이 없다). `this_decision["enact_applied"] = enact_applied` 바로 뒤에:

```julia
    # ---- G-M 원자료 (spec §7·§11-10) --------------------------------------------------
    # 결정 직전의 s 와 직후의 s' · τ 를 한 줄로 낸다. 기본 OFF — 스윕 산출물에 영향 없음.
    if haskey(ENV, "GM_TRACE")
        local _s_next, _ = CB.snapshot(env)
        if _GM_PREV[] !== nothing
            local p = _GM_PREV[]
            open(ENV["GM_TRACE"], "a") do io
                println(io, JSON3.write(Dict(
                    "s"      => p.hash,          "s_full" => p.canonical,
                    "macro"  => p.macro_name,    "s_next" => CB.state_hash(_gm_key(_s_next)),
                    "tau"    => CB.sim_time(env.dt) - p.t,
                    "with_age" => get(ENV, "GM_NO_AGE", "0") != "1",
                    "case"   => OODC, "seed" => DEMO_SEED)))
            end
        end
        _GM_PREV[] = (hash = CB.state_hash(_gm_key(_s_next)), canonical = CB.canonical(_gm_key(_s_next)),
                      macro_name = mac, t = CB.sim_time(env.dt))
    end
```

파일 상단(`_SIM_STEP` 을 지운 자리, 태스크 8)에 `const _GM_PREV = Ref{Any}(nothing)` 를 둔다.

훅 안에서 `CB.state_hash`/`CB.canonical` 대신 아래 지역 헬퍼를 쓴다 — `GM_NO_AGE=1` 이면
Step 1 의 `strip_age` 를 태운다:

```julia
_gm_key(s) = get(ENV, "GM_NO_AGE", "0") == "1" ? CB.strip_age(s) : s
```
그리고 훅의 `CB.state_hash(_s_next)` → `CB.state_hash(_gm_key(_s_next))`,
`CB.canonical(_s_next)` → `CB.canonical(_gm_key(_s_next))` 로 쓴다.

- [ ] **Step 2: G-M 게이트를 쓴다**

```python
# wm4spacecraft_manufacturing/smdp/gate_gm.py
"""G-M — Markov 검사 (spec §7 · §11-10).

묻는 것: 서로 다른 궤적에서 도달한 hash(s) 가 **같은** 두 지점에서, **같은 팔**로 이어지는
다음 epoch (s', τ) 분포가 같은가. 이것이 C1·C2 의 직접 검사다.

Age·expired 를 넣기 **전후로** 재서 spec §5.4 세 위반의 기여를 정량화한다.
잔여 위반이 남으면 그것이 다음에 찾을 상태 변수다 — **"다 잡았다" 를 선언하지 않는다.**

  python gate_gm.py /tmp/trace_noage.jsonl /tmp/trace_age.jsonl
"""
import json
import sys


def violations(rows, tau_tol=1e-6):
    """(s, macro) 가 같은데 s' 가 갈리거나 τ 가 갈리는 쌍의 비율."""
    buckets = {}
    for r in rows:
        buckets.setdefault((r["s"], r["macro"]), []).append(r)
    n_pairs = n_viol = 0
    by_macro = {}
    for (_s, mac), rs in buckets.items():
        if len(rs) < 2:
            continue          # 재방문이 없으면 이 검사는 아무 말도 못 한다
        n_pairs += 1
        nexts = {x["s_next"] for x in rs}
        taus = [x["tau"] for x in rs]
        bad = len(nexts) > 1 or (max(taus) - min(taus) > tau_tol)
        n_viol += int(bad)
        slot = by_macro.setdefault(mac, [0, 0])
        slot[0] += 1
        slot[1] += int(bad)
    return {"n_matched_pairs": n_pairs, "n_violating": n_viol,
            "rate": (n_viol / n_pairs) if n_pairs else float("nan"),
            "by_macro": by_macro}


def load(path):
    with open(path) as fh:
        return [json.loads(l) for l in fh if l.strip()]


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    results = []
    for p in argv[1:]:
        rows = load(p)
        out = violations(rows)
        results.append((p, rows, out))
        tag = "with_age" if (rows and rows[0].get("with_age")) else "no_age"
        print("=== G-M %s (%s) ===" % (tag, p))
        print("  재방문 쌍 %d · 위반 %d · 비율 %.4f"
              % (out["n_matched_pairs"], out["n_violating"], out["rate"]))
        for mac, (n, v) in sorted(out["by_macro"].items(), key=lambda kv: str(kv[0])):
            print("    %-14s %3d/%3d" % (mac, v, n))
        if out["n_matched_pairs"] == 0:
            print("  🔴 재방문 쌍이 0개다 — 이 검사는 아무것도 못 봤다. 궤적을 더 모아라 "
                  "(같은 case/seed 를 여러 번, 또는 더 긴 지평선).")
    if len(results) == 2:
        (_, _, a), (_, _, b) = results
        print("\n=== ablation — Age·expired 의 기여 ===")
        print("  no_age  위반비율 %.4f" % a["rate"])
        print("  with_age 위반비율 %.4f" % b["rate"])
        print("  판정: %s" % ("PASS — Age 가 위반을 줄인다 (spec §5.4 확인)"
                              if b["rate"] < a["rate"] else
                              "FAIL — Age 를 넣어도 위반이 안 줄었다. §5.4 진단이 틀렸거나 "
                              "다른 이력 변수가 지배한다"))
        if b["rate"] > 0:
            print("  ⚠️ 잔여 위반 %.4f — **다 잡았다고 선언하지 않는다.** 위반 쌍의 s_full 을 "
                  "diff 해 무엇이 갈렸는지 보라. 그것이 다음에 찾을 상태 변수다." % b["rate"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

`test_smdp_gates.py` 에 단위검사를 더한다:

```python
import gate_gm  # noqa: E402


def test_gm_flags_diverging_successors():
    rows = [{"s": "A", "macro": "NOOP", "s_next": "X", "tau": 1.0},
            {"s": "A", "macro": "NOOP", "s_next": "Y", "tau": 1.0}]
    out = gate_gm.violations(rows)
    assert out["n_matched_pairs"] == 1 and out["n_violating"] == 1


def test_gm_flags_diverging_tau():
    rows = [{"s": "A", "macro": "NOOP", "s_next": "X", "tau": 1.0},
            {"s": "A", "macro": "NOOP", "s_next": "X", "tau": 2.5}]
    assert gate_gm.violations(rows)["n_violating"] == 1


def test_gm_is_silent_without_revisits():
    """재방문이 없으면 아무 말도 안 한다 — 그걸 PASS 로 읽으면 안 된다."""
    rows = [{"s": "A", "macro": "NOOP", "s_next": "X", "tau": 1.0},
            {"s": "B", "macro": "NOOP", "s_next": "Y", "tau": 1.0}]
    assert gate_gm.violations(rows)["n_matched_pairs"] == 0
```

- [ ] **Step 3: 테스트가 통과하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing/smdp
PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest test_smdp_gates.py -v
```
기대: G-M 3건을 포함해 전부 PASS.

- [ ] **Step 4: ablation 궤적을 모은다 — 순차 실행**

```bash
cd /home/chahj578/Construction_OODlayer
rm -f /tmp/trace_age.jsonl /tmp/trace_noage.jsonl
for c in fault battery zone fault_battery; do for s in 1 2 3 4 5; do
  GM_TRACE=/tmp/trace_age.jsonl   DEMO_HAZARD=1 OOD_SEED=$s DEMO_CASE=$c \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
  GM_TRACE=/tmp/trace_noage.jsonl GM_NO_AGE=1 DEMO_HAZARD=1 OOD_SEED=$s DEMO_CASE=$c \
    julia +lts --project=. tools/monitor/run_demo.jl >/dev/null 2>&1
done; done
wc -l /tmp/trace_age.jsonl /tmp/trace_noage.jsonl
```
⚠️ **순차 실행.** 20판 × 2 = 40판, 판당 ~50s → 약 35분.

- [ ] **Step 5: G-M 을 실측한다**

```bash
cd wm4spacecraft_manufacturing/smdp
../../.venv/bin/python gate_gm.py /tmp/trace_noage.jsonl /tmp/trace_age.jsonl 2>&1 | tee /tmp/gm.txt
```

**판정:**
- `재방문 쌍 0` → 이 검사는 아무것도 못 봤다. **PASS 로 읽지 않는다.** 궤적을 더 모으거나
  (같은 `(case, seed)` 를 여러 `k` 로) 해시를 거칠게 만드는 방법을 사용자와 상의한다.
- `with_age` 위반비율 < `no_age` 위반비율 → **PASS.** spec §5.4 진단이 확인됐다.
- 같거나 커짐 → §5.4 가 틀렸거나 다른 이력 변수가 지배한다. **그 사실을 그대로 보고한다.**
- 잔여 위반 > 0 → 위반 쌍의 `s_full` 을 diff 해 갈린 블록을 찾는다. **"다 잡았다"를 선언하지 않는다.**

- [ ] **Step 6: 결과를 기록하고 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
cp /tmp/gm.txt wm4spacecraft_manufacturing/measurements/gate_gm_2026-08-19.txt
git add wm4spacecraft_manufacturing/smdp/gate_gm.py \
        wm4spacecraft_manufacturing/smdp/test_smdp_gates.py \
        wm4spacecraft_manufacturing/measurements/gate_gm_2026-08-19.txt \
        src/mdp/simstate.jl tools/monitor/run_demo.jl
git commit -m "feat(gate): G-M Markov 검사 + Age/expired ablation (spec §5.4 세 위반의 기여를 잰다)"
```

---

## 태스크 14: `T_plan(s)` 구현 (spec §5.5·§11-11)

> 🔴 **신규 항목이다.** 1차 개정은 *"`cache.node_queue` 가 이미 slack 을 들고 있으므로 뽑을 수
> 있다"* 고 적었지만 그건 **slack 이지 critical path 가 아니다.**
>
> `τ_{k+1} = min( T_plan(s⁺_k), min_r T_fail,r, Δ_max )` 에서 `T_plan` 이 **행동의존성을 만든다** —
> `RelocateBuild` 는 전원 재라우팅으로 다음 완료를 밀고, `SwapBattery` 는 배송 도착까지 라인을
> 세운다. 그리고 `T_plan` 은 `s⁺` 가 주어지면 **결정론**이라 `F` 에 원자(atom)가 생긴다 →
> 지수분포가 될 수 없다 → **CTMDP 가 아니라 semi-Markov 다.**

**Files:**
- Create: `src/mdp/tplan.jl`
- Modify: `src/mdp/mdp.jl` (include)
- Test: `test/mdp_tplan_smoke.jl`

**Interfaces:**
- Consumes: `CB.SimState`·`CB.GraphBlock` (태스크 9)
- Produces:
  - `CB.T_plan(s::SimState) -> Float64` — 미완 스케줄 DAG 의 longest path(초). 위상정렬 1회.
  - `CB.node_duration(s, v) -> Float64` — 정점 `v` 의 잔여 소요시간 추정
  - `CB.T_plan_next(s) -> Float64` — **다음 노드 완료까지**의 시간(τ 의 첫 성분). 이것이
    `τ` 에 들어가는 값이고 `T_plan` 은 지평선 절단(`H`)용이다.

- [ ] **Step 1: 실패 테스트를 쓴다**

```julia
# test/mdp_tplan_smoke.jl
# spec §5.5 — τ 의 첫 성분. 313노드 DAG 의 longest path 는 위상정렬 1회로 싸다.
# ⚠️ slack 과 다르다. slack 은 "이 노드가 얼마나 늦어도 되는가" 이고 여기서 필요한 것은
# "다음 완료가 언제인가" 다. 1차 개정이 그 둘을 혼동했다.
#
#   julia +lts --project=. test/mdp_tplan_smoke.jl
using ConstructionBots
using Test
const CB = ConstructionBots

CB.include(joinpath(@__DIR__, "..", "src", "navigator", "navigator.jl"))
CB.include(joinpath(@__DIR__, "..", "src", "mdp", "mdp.jl"))
include(joinpath(@__DIR__, "mdp_simstate_smoke.jl"))   # _state() 헬퍼 재사용

@testset "빈 잔여 작업 → T_plan 0" begin
    s = _state()
    done = CB.SimState(g = CB.GraphBlock(n_nodes = 3, edges = Set([(1, 2), (2, 3)]),
                                         closed = Set([1, 2, 3]), active = Set{Int}(),
                                         binding = Dict{Int,Int}(), edge_bias = Dict{Tuple{Int,Int},Float64}(),
                                         wedge_edges = Set{Tuple{Int,Int}}(),
                                         dissolved_gates = Set{Tuple{Int,Int}}()),
                       geo = s.geo, fleet = s.fleet, hazard = s.hazard, courier = s.courier,
                       clock = s.clock, age = s.age, event = s.event)
    @test CB.T_plan(done) == 0.0
    @test CB.T_plan_next(done) == Inf     # 다음 완료가 없다 → Δ_max 가 τ 를 정한다
end

@testset "T_plan_next <= T_plan" begin
    s = _state()
    @test CB.T_plan_next(s) <= CB.T_plan(s) + 1e-9
end

@testset "배송이 있으면 다음 완료가 밀린다 (행동의존성)" begin
    s0 = _state()
    d  = CB.CourierRec(target = 1, courier = 2, depot = :d1, home = (0.0, 0.0),
                       goal = (20.0, 0.0), phase = :outbound,
                       step_out = s0.clock.step, step_swap = s0.clock.step + 200)
    s1 = CB.SimState(g = s0.g, geo = s0.geo, fleet = s0.fleet, hazard = s0.hazard,
                     courier = [d], clock = s0.clock, age = s0.age, event = s0.event)
    # SwapBattery 는 배송 도착까지 라인을 세운다 → 다음 완료가 늦어진다 (spec §5.5)
    @test CB.T_plan_next(s1) >= CB.T_plan_next(s0)
end

@testset "T_plan 은 s 의 결정론적 함수다 (F 에 원자를 만든다)" begin
    s = _state()
    @test CB.T_plan(s) == CB.T_plan(s)
end
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. test/mdp_tplan_smoke.jl
```
기대: **FAIL** — `UndefVarError: T_plan not defined`.

- [ ] **Step 3: 구현한다**

```julia
# src/mdp/tplan.jl
# =============================================================================
# spec §5.5 — τ_{k+1} = min( T_plan(s⁺_k), min_r T_fail,r, Δ_max )
#
# T_plan 이 **행동의존성**을 만든다: RelocateBuild 는 전원 재라우팅으로 다음 완료를 밀고,
# SwapBattery 는 배송 도착까지 라인을 세운다(Courier.goal 까지의 거리/속도가 그 성분).
# 그리고 T_plan 은 s⁺ 가 주어지면 **결정론**이라 F 에 원자(atom)가 생긴다 → 지수분포가
# 될 수 없다 → CTMDP 가 아니라 semi-Markov 다(spec §5.3).
#
# 🔴 slack 이 아니다. slack 은 "이 노드가 얼마나 늦어도 되는가"(여유), 여기서 필요한 것은
# "다음 완료가 언제인가"(도달시각)다. 1차 개정이 그 둘을 혼동해 "이미 있다"고 적었다.
# =============================================================================

"""
    node_duration(s::SimState, v::Int) -> Float64

정점 `v` 의 잔여 소요시간[s] 추정. 로봇이 바인딩돼 있으면 그 로봇의 pose 에서 목표까지의
거리를 유효속도로 나눈다. 유효속도는 `soc_speed_factor` 와 같은 감속을 반영해야 한다 —
안 하면 방전된 로봇의 작업이 실제보다 빨리 끝나는 것으로 계산되어 τ 가 짧게 나온다.
"""
function node_duration(s::SimState, v::Int)
    v in s.g.closed && return 0.0
    r = get(s.g.binding, v, nothing)
    r === nothing && return _DEFAULT_NODE_SECONDS
    rec = get(s.fleet, r, nothing)
    rec === nothing && return _DEFAULT_NODE_SECONDS
    rec.stalled && return Inf                  # 멈춰 선 로봇의 노드는 개입 없이는 안 닫힌다
    goal = get(s.geo.poses, v, nothing)
    dist = goal === nothing ? _DEFAULT_NODE_DIST :
           hypot(goal[1] - rec.pose[1], goal[2] - rec.pose[2])
    return dist / max(_effective_speed(rec), 1.0e-6)
end

"감속 반영 유효속도. `soc_speed_factor`(navigator/battery.jl)와 **같은 규칙**을 쓴다."
_effective_speed(rec::RobotRec) = _NOMINAL_SPEED * _soc_factor(rec.soc)

const _NOMINAL_SPEED        = 4.0     # m/s — rvo_interface.jl:119 의 기본 최대속도
const _DEFAULT_NODE_SECONDS = 1.0
const _DEFAULT_NODE_DIST    = 1.0

"""
    T_plan(s::SimState) -> Float64

미완 스케줄 DAG 의 longest path[s]. **위상정렬 1회**라 313노드에서 싸다.
지평선 절단(`H`)과 종단 벌점 추정에 쓴다. τ 에 들어가는 것은 `T_plan_next` 다.
"""
function T_plan(s::SimState)
    open_v = [v for v in 1:s.g.n_nodes if !(v in s.g.closed)]
    isempty(open_v) && return 0.0
    order = _topo_order(s, open_v)
    longest = Dict{Int,Float64}(v => 0.0 for v in open_v)
    for v in Iterators.reverse(order)
        d = node_duration(s, v)
        succ = _successors(s, v)
        tail = isempty(succ) ? 0.0 : maximum(get(longest, w, 0.0) for w in succ)
        longest[v] = d + tail
    end
    return maximum(values(longest))
end

"""
    T_plan_next(s::SimState) -> Float64

**다음 노드 완료까지**의 시간[s]. τ 의 첫 성분이고, 잔여 활성 노드가 없으면 `Inf`
(그러면 `Δ_max` 가 τ 를 정한다).

배송(`Courier`)이 라인을 세우는 효과가 여기 들어간다 — `phase == :outbound` 인 배송의
`step_swap` 까지는 그 target 로봇의 노드가 안 닫힌다.
"""
function T_plan_next(s::SimState)
    isempty(s.g.active) && return Inf
    blocked = Set{Int}(c.target for c in s.courier if c.phase === :outbound)
    best = Inf
    for v in sort!(collect(s.g.active))            # 정렬 순회 (spec §3.5 규칙 4)
        d = node_duration(s, v)
        r = get(s.g.binding, v, nothing)
        if r !== nothing && r in blocked
            # 배송 도착 전에는 이 노드가 못 닫힌다. 도착 시각을 하한으로 쓴다.
            c = first(filter(x -> x.target == r, s.courier))
            d = max(d, _dt_hint(s) * max(0, c.step_swap - s.clock.step))
        end
        best = min(best, d)
    end
    return best
end

"스텝→초 환산. s.clock 에서 유도한다(시계 단일 진실원, 태스크 8)."
_dt_hint(s::SimState) = s.clock.step > 0 ? s.clock.t / s.clock.step : 0.025
```

**보조 셋의 구현 지침:**
- `_topo_order(s, open_v)` · `_successors(s, v)` — `GraphBlock.edges` 를 쓴다(태스크 9에서
  이미 넣었다. 나중에 넣으면 `canonical` 이 바뀌어 해시가 갈리고 태스크 12·13을 다시 돌려야
  한다 — 그래서 앞당겼다). `_successors(s, v) = [w for (u, w) in s.g.edges if u == v]`,
  `_topo_order` 는 그 엣지로 Kahn 알고리즘 한 번. 313노드에서 밀리초 단위다.
- `_soc_factor(soc)` — `src/navigator/battery.jl` 의 `soc_speed_factor` 규칙(stall threshold
  0.15 · derate hi 0.5 / min 0.35)을 **그 파일에서 확인해** 옮긴다. 리터럴 복붙이 아니라
  가능하면 그 함수를 직접 부른다: `grep -n "soc_speed_factor" src/navigator/battery.jl`.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
julia +lts --project=. test/mdp_tplan_smoke.jl
```
기대: 네 testset 전부 PASS.

- [ ] **Step 5: `τ̂` 예측오차를 실측한다 — 이것이 게이트다**

`T_plan_next` 는 **예측**이고 실제 `τ` 는 시뮬레이터가 만든다. 둘의 오차를 잰다:

```bash
cd /home/chahj578/Construction_OODlayer
cat > /tmp/tau_err.py <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
errs = [r["tau"] - r["tau_hat"] for r in rows if r.get("tau_hat") is not None]
if not errs:
    sys.exit("tau_hat 이 궤적에 없다 — run_demo 의 GM_TRACE 훅에 T_plan_next 를 실어라")
print("n=%d  중앙 오차 %.3f s  MAE %.3f s  최대 %.3f s"
      % (len(errs), statistics.median(errs),
         statistics.mean(abs(e) for e in errs), max(abs(e) for e in errs)))
print("상대 MAE = %.1f%%" % (100 * statistics.mean(abs(e) for e in errs)
                             / max(1e-9, statistics.mean(r["tau"] for r in rows))))
PY
```

`tools/monitor/run_demo.jl` 의 GM_TRACE 훅(태스크 13)에 `"tau_hat" => CB.T_plan_next(_s_next)`
한 줄을 더한 뒤, 태스크 13 Step 4 와 같은 방식으로 궤적을 다시 모으고:

```bash
../.venv/bin/python /tmp/tau_err.py /tmp/trace_age.jsonl
```

**판정**: 상대 MAE 를 기록한다. **목표값을 미리 정하지 않는다** — 이 수는 지금까지 잰 적이
없으므로 첫 측정이 baseline 이다. 다만 `T_plan_next` 가 실제 `τ` 와 **상관이 없으면**
(부호가 뒤집히거나 상대 MAE > 100%) τ 예측이 무의미하므로 그 사실을 보고한다.

- [ ] **Step 6: 전체 테스트를 돌린다**

```bash
julia +lts --project=. -e 'using Pkg; Pkg.test()'
for t in mdp_hazard_smoke mdp_crn_smoke mdp_stamp_smoke respec_determinism_smoke \
         mdp_global_inventory mdp_clock_smoke mdp_simstate_smoke \
         mdp_snapshot_roundtrip mdp_tplan_smoke; do
  echo "=== $t ==="; julia +lts --project=. test/$t.jl || echo "FAILED: $t"
done
cd wm4spacecraft_manufacturing/smdp && \
  PYTHONPATH=/usr/lib/python3/dist-packages ../../.venv/bin/python -m pytest . -v
```
기대: `Pkg.test()` = **11 pass / 1 error**(Gurobi) · Julia 스모크 9개 전부 PASS ·
pytest 전부 PASS.

- [ ] **Step 7: 커밋**

```bash
cd /home/chahj578/Construction_OODlayer
git add src/mdp/tplan.jl src/mdp/mdp.jl src/mdp/simstate.jl src/mdp/snapshot.jl \
        tools/monitor/run_demo.jl test/mdp_tplan_smoke.jl
git commit -m "feat(mdp): T_plan(s) / T_plan_next(s) — τ 의 첫 성분 (spec §5.5, 1차 개정의 오독을 고침)"
```

---

## 완료 판정 — 단계 (B) 착수 조건 (spec §11-17)

아래 게이트가 **전부** 통과해야 `2026-08-XX-smdp-rollout-oracle.md`(단계 B)를 착수한다.

| 게이트 | 어디서 | 통과 조건 |
|---|---|---|
| **G-S** | 태스크 0 | 블록 순열 `p < 0.05` · 분산비 > 1 · 절단 포함/제외가 엇갈리지 않음 |
| **G2** | 태스크 0 | coupling rate > 0 (분모 = 선택지 2개 이상) |
| **G6** | 태스크 5 | 6팔 전부 `ran_milp == false` · 필드 없음 0 |
| **G3** | 태스크 3 Step 6 | `τ <= 0` 인 결정쌍 0건 (C3: `F_xay(0) < 1`) — hazard on 후 재확인 |
| **G1** | 태스크 12 | 세 case 전부 `rc=0` — 바이트 동일 **그리고** ξ 를 갈면 갈림 |
| **G-M** | 태스크 13 | `with_age` 위반비율 < `no_age` 위반비율 · 재방문 쌍 > 0 |
| **G-R** | 단계 (B) | 롤아웃 결정성 + 팔 간 `J` 차이의 SE 가 `1/√K` 로 감소 |
| **G5** | 단계 (B) | `V̂` 도입 전후 LOIO regret 악화 없음 |

**G-R·G5 는 이 계획의 범위 밖이다** — 롤아웃 오라클(단계 B)이 있어야 잴 수 있다.
그 둘을 뺀 여섯이 이 계획의 완료 조건이다.

**보고할 것 (숨기지 않는다):**
- **L1** — 결정의 2/3 에 선택지가 없다. 이 계획은 고치지 않았다. hazard on(태스크 3)이
  동점을 얼마나 깼는지 **재서** 보고한다.
- **L2** — `Deprioritize` 는 338회 제안 · 0회 선택. hazard 의 `cell_mild_*` 경로가
  `degraded-but-alive` 를 만드므로 **태스크 3 이후 재평가한다.**
- **L3** — `ForbidAgent` 를 뺀 대가. 작은 인스턴스에서 그것을 포함한 완전탐색 `V*` 와
  6팔 `V^macro` 의 gap 을 보고한다. **숨기지 않는다.**
- **L4** — `ReformTeam` 이 결정인지 시뮬레이터 복구 루틴인지 불분명. 반증 절차는
  "`ReformTeam` 을 강제로 `NOOP` 으로 바꿨을 때 판이 실제로 멈추는가". §5.4-(a)가 이 의심을
  강화한다 — 그 발화가 물리가 아니라 **카운터 modulo** 에 걸려 있다.
- **kind 지름길이 표현에서 평가로 옮겨갔다**(spec §4.4). `s` 는 `e`·`broken`·`health_r` 을
  전부 담으므로 모델이 kind 로 지름길을 탄다. **leave-one-failure-type-out 행렬이 선택이
  아니라 필수**가 되고 유일한 방어선이다 — 단계 (B)의 첫 항목으로 올린다.
