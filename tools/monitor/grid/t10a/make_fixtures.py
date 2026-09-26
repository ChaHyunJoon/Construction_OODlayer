"""make_fixtures.py <b0_root> <fixture_dir> — git 에 남길 요약: manifest · b0_episodes.{json,tsv} · b0_summary · decomp_none ·
equivalence(순차 vs 병렬, 무하네스 대조 — equiv_check.py). extra.json·test_ledger.tsv 는 손으로 유지한다(진단 서술)."""
import json, os, shutil, subprocess, sys
R, F = sys.argv[1], sys.argv[2]
H = os.path.dirname(os.path.abspath(__file__))
os.makedirs(F, exist_ok=True)
shutil.copy(os.path.join(R, "manifest.json"), F)
for n in ("b0_episodes.json", "b0_episodes.tsv", "b0_summary.json", "decomp_none.json"):
    shutil.copy(os.path.join(R, "out", n), F)
cells = [json.loads(subprocess.run([sys.executable, os.path.join(H, "equiv_check.py"), R, m, "zone", "27"],
                                   capture_output=True, text=True, check=True).stdout) for m in ("tractor", "xwing")]
json.dump({"schema": "zrv-b0-equivalence/1", "script": "tools/monitor/grid/t10a/equiv_check.py",
           "note": "seq = B0 runner alone before the grid (chain.sh); par = the same cell inside the W=8 grid; control_off = plain render_demo off "
                   "(no -L preload, no trace hook, no RVOSimHarness) inside the grid",
           "cells": cells}, open(os.path.join(F, "equivalence.json"), "w"), indent=1, sort_keys=True)
print("wrote", F)
