#!/usr/bin/env python3
"""G3 집계: 판별 완주·존 해소·ablation 줄 → tally.json (셀·시드별 실현 가능성 표)."""
import glob, json, os, re, sys
sys.path.insert(0, "/home/chahj578/Construction_OODlayer/tools/monitor")
import build_sweep_dataset as B
here = os.path.dirname(os.path.abspath(__file__))
rows = []
for p in sorted(glob.glob(os.path.join(here, "log", "*.log"))):
    m = re.match(r"(tractor|xwing)__(zone|all3)__s(\d+)\.log$", os.path.basename(p))
    if not m:
        continue
    txt = open(p, errors="replace").read()
    r = B.parse_log(txt, "oracle", m[2], int(m[3])) or {"closed": None, "complete": False}
    rows.append({"model": m[1], "case": m[2], "seed": int(m[3]), "complete": bool(r.get("complete")),
                 "closed": r.get("closed"), "n_blocked": r.get("n_blocked"),
                 "zone_place": r.get("zone_place"), "ablation": r.get("ablation")})
json.dump(rows, open(os.path.join(here, "tally.json"), "w"), indent=1)
for key in sorted({(r["model"], r["case"]) for r in rows}):
    rs = [r for r in rows if (r["model"], r["case"]) == key]
    print(key, "complete %d/%d" % (sum(r["complete"] for r in rs), len(rs)),
          "denied>0:", sum(1 for r in rs if (r["ablation"] or {}).get("denied", 0) > 0),
          "armed_all:", sum(1 for r in rs if (r["ablation"] or {}).get("armed") is True
                            and (r["ablation"] or {}).get("level") == "all"))
