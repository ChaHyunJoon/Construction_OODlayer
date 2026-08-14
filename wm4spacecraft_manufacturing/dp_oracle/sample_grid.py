#!/usr/bin/env python3
"""반사실 표집기 — 팔을 고정한 판을 굴려 (측정된 칸, 팔, J) 표본을 만든다.

무엇을 재는가 (이름을 정확히 붙인다)
====================================
한 rollout = **한 판 전체**를 `DEMO_FORCE_MACRO=<팔>` 로 굴린 것이다. 그 판의 모든 OOD 결정은
그 팔로 집행되고, 판이 끝나면 통일 목적함수 J 하나가 나온다. 각 결정의 상태를 φ̃ 로 측정해
칸으로 라벨하면 표본 `(칸, 팔, J)` 가 나온다. 따라서 이 표가 추정하는 것은

    Q(s̃, a) = E[ J(판 전체) | 판이 s̃ 를 지났고, 그 판의 모든 결정을 a 로 집행했다 ]

즉 **"그 상태를 지나는 판에서 줄곧 a 를 쓰면 얼마나 드는가"** 이고,
    V(s̃) = min_a Q(s̃, a),   a*(s̃) = argmin_a Q(s̃, a)
는 그 상수-팔 정책군 안에서의 최선이다.

이것은 원 설계(§7)의 **backward induction 이 아니다.** 정직하게 다르게 부른다:
  · 원 설계는 결정 epoch 마다 (c, s̃′) 를 재고 Bellman 으로 뒤에서 풀어 올라간다. 그러려면
    epoch 단위 비용 분해가 필요한데, 이 하니스가 J 를 내는 단위는 **판**이다(makespan·energy·
    complete 가 전부 판 단위 집계다). 판 단위 J 를 결정 개수로 임의 배분하면 그 배분 규칙이
    곧 결과가 되므로, 배분하지 않고 **판 단위 그대로** 둔다.
  · 귀결: 판에 결정이 n 개면 그 n 개 칸이 **같은 J 하나를 공유**한다(credit assignment 미해결).
    이 한계는 `value.json` 과 FINAL.md 에 이름으로 남는다.

왜 그래도 천장으로 쓸 수 있는가: 실행 정책들은 사건마다 팔을 바꿀 수 있으므로 상수-팔 정책군
보다 **넓은** 집합이다. 따라서 V 가 실행 정책의 실현값보다 나쁠 수 있고, 그런 칸이 있으면
"천장" 이라는 이름을 쓰지 않는다 — 원 설계 §8.7 의 게이트를 그대로 적용한다.

요청 칸이 아니라 **착지 칸**으로 라벨한다 (원 설계 §4.2·§5)
==========================================================
칸을 세우는 ψ 를 새로 짓지 않는다. 기존 case/seed 조합이 자연히 만드는 상태를 굴리고, **주입
후 실제 상태에서 φ̃ 를 다시 계산해** 착지한 칸의 표본으로 센다. 어떤 조합으로도 표본이 안 생기는
칸은 UNREACHABLE 로 남고 값을 지어내지 않는다.

사용법
    ../../.venv/bin/python sample_grid.py --jobs 24 --seeds 1,2,3,4,5,6,7,8,9,10
"""
import argparse
import collections
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
WM = os.path.join(HERE, "..")
REPO = os.path.join(WM, "..")
sys.path.insert(0, WM)
sys.path.insert(0, HERE)

import objective                                              # noqa: E402
from derive_grid import cell_key, state_of, load_grid         # noqa: E402

PY = os.path.join(REPO, ".venv", "bin", "python")
DSPY_URL = os.environ.get("DSPY_URL", "http://127.0.0.1:8090")

CASES = ["battery", "fault", "all", "fault_battery", "fault_zone", "battery_zone", "zone"]

# 팔 메뉴는 `action_registry.json` 에서 온다 — 630판 로그의 `valid` 를 읽으면 FaultTruth/
# ReformTruth 가 빈 리스트라 그 축이 **조용히 0팔**이 된다(원 설계 §3.3).
def arm_menu():
    reg = json.load(open(os.path.join(WM, "action_registry.json")))
    # 배포 학습셋이 지원하는 집합과 같은 5팔을 쓴다(test_surrogate_support.py 의 현행 계약).
    want = ("0", "1", "2", "7", "8")
    return [(int(k), reg["macros"][k]["name"]) for k in want if k in reg["macros"]]


def run_board(case, seed, arm_id, arm_name, outroot, world_seed=1):
    """판 하나를 팔 고정으로 굴린다. 반환: rows.jsonl 경로 또는 None."""
    outdir = os.path.join(outroot, "%s_s%d_a%d" % (case, seed, arm_id))
    rows = os.path.join(outdir, "rows.jsonl")
    if os.path.exists(rows) and os.path.getsize(rows) > 0:
        return rows                                    # 재개: 이미 끝난 판은 다시 굴리지 않는다
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ)
    env.update(
        DEMO_FORCE_MACRO=arm_name,
        # 팔을 고정하므로 실행 정책은 무엇이든 결과가 같다. canonical 로 둬서 DSPy 호출을 없앤다
        # (표집 350판 x LLM 호출은 비용이고, 어차피 집행은 FORCE_MACRO 가 덮는다).
        DEMO_ALL_POLICIES="0",
        JULIA_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1",
        OMP_NUM_THREADS="1", MKL_NUM_THREADS="1")
    cmd = [PY, os.path.join(WM, "llm_ood_eval.py"), "run",
           "--case", case, "--seeds", str(seed), "--policies", "canonical",
           "--out", rows, "--dspy-url", DSPY_URL, "--router", "0",
           "--world-seed", str(world_seed)]
    with open(os.path.join(outdir, "board.log"), "w") as lg:
        rc = subprocess.call(cmd, stdout=lg, stderr=subprocess.STDOUT, cwd=WM, env=env)
    if rc != 0 or not os.path.exists(rows) or os.path.getsize(rows) == 0:
        return None
    return rows


def rows_to_samples(rows_path, case, seed, arm_id, arm_name, axes):
    """판 하나 -> 그 판이 지난 칸마다 표본 1행. **판 단위 J 를 공유한다**(위 독스트링)."""
    out = []
    for line in open(rows_path):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        # J 는 objective 를 경유해서만 계산한다(리터럴 금지 — audit_objective.py 항목 1).
        try:
            cost = objective.J_row(r)
            unscorable = None
        except objective.ObjectiveError as e:
            # 채점 불가 판은 **버리지 않고 이름으로 남긴다.** 조용히 빼면 표가 낙관 편향된다.
            cost, unscorable = None, str(e)[:160]
        terminal = "goal" if r.get("complete") else "dead_end"
        for d in (r.get("decisions") or []):
            st = state_of(d, axes)
            if st is None:
                continue
            out.append({
                "cell": cell_key(st), "arm": arm_id, "arm_name": arm_name,
                "cost": cost, "unscorable": unscorable,
                "terminal": terminal, "next_cell": None,
                "capped": False, "sampling_mode": "replay",
                "seed": seed, "case": case, "at": d.get("at"),
                "enacted_macro": d.get("macro"),
                "complete": bool(r.get("complete")), "closed": r.get("closed"),
                "total": r.get("total"), "makespan": r.get("makespan"),
                "energy_J": r.get("energy_J"),
                "objective_hash": r.get("objective_hash"),
                "energy_objective": r.get("energy_objective"),
                # 한 판이 n 칸에 같은 J 를 나눠 주는 것을 표에서 볼 수 있게 남긴다.
                "board_id": "%s_s%d_a%d" % (case, seed, arm_id),
                "board_n_decisions": len(r.get("decisions") or []),
            })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=24)
    ap.add_argument("--seeds", default="1,2,3,4,5,6,7,8,9,10")
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--work", default=os.path.join(HERE, "_sample_work"))
    ap.add_argument("--out", default=os.path.join(HERE, "samples.jsonl"))
    ap.add_argument("--keep-work", action="store_true")
    a = ap.parse_args()

    seeds = [int(x) for x in a.seeds.split(",") if x.strip()]
    cases = [c for c in a.cases.split(",") if c.strip()]
    arms = arm_menu()
    grid = load_grid()
    axes = grid["axes"]

    jobs = [(c, s, aid, an) for s in seeds for c in cases for (aid, an) in arms]
    print("표집 계획: case %d x seed %d x 팔 %d = **%d 판**, 병렬 %d"
          % (len(cases), len(seeds), len(arms), len(jobs), a.jobs))
    print("팔 메뉴 (action_registry.json):", ", ".join("%d:%s" % x for x in arms))
    os.makedirs(a.work, exist_ok=True)

    t0 = time.time()
    done = {"n": 0, "fail": 0}

    def work(j):
        c, s, aid, an = j
        p = run_board(c, s, aid, an, a.work)
        done["n"] += 1
        if p is None:
            done["fail"] += 1
        if done["n"] % 25 == 0:
            el = time.time() - t0
            print("  %d/%d 판  (실패 %d)  경과 %.1f분  예상 총 %.1f분"
                  % (done["n"], len(jobs), done["fail"], el / 60,
                     el / 60 * len(jobs) / max(done["n"], 1)), flush=True)
        return (j, p)

    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        results = list(ex.map(work, jobs))

    samples = []
    n_boards_ok = 0
    for (c, s, aid, an), p in results:
        if p is None:
            continue
        n_boards_ok += 1
        samples.extend(rows_to_samples(p, c, s, aid, an, axes))

    # 세대 단일성: 표본이 두 세대에서 오면 멈춘다. 섞인 값을 표에 각인시키지 않는다.
    gens = {(r.get("objective_hash"), r.get("energy_objective")) for r in samples}
    if len(gens) > 1:
        sys.exit("표본에 세대가 %d 종 섞여 있다: %s" % (len(gens), gens))

    with open(a.out, "w") as f:
        for r in samples:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    by_cell = collections.Counter(r["cell"] for r in samples)
    by_cell_arm = collections.Counter((r["cell"], r["arm"]) for r in samples)
    n_unscorable = sum(1 for r in samples if r["cost"] is None)
    print("\n판 %d/%d 성공 · 표본 %d행 · 칸 %d개 · (칸,팔) 쌍 %d개"
          % (n_boards_ok, len(jobs), len(samples), len(by_cell), len(by_cell_arm)))
    print("J 채점 불가 표본: %d (버리지 않고 표시)" % n_unscorable)
    print("관측 격자 대비 커버리지: %d / %d = %.1f%%"
          % (len(by_cell), grid["n_observed_cells"],
             100.0 * len(by_cell) / max(grid["n_observed_cells"], 1)))
    print("벽시계 %.1f분  ->  %s" % ((time.time() - t0) / 60, a.out))

    if not a.keep_work:
        shutil.rmtree(a.work, ignore_errors=True)


if __name__ == "__main__":
    main()
