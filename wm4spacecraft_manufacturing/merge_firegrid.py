#!/usr/bin/env python
"""
merge_firegrid.py -- CANONICAL 덤프 + 발화시점 그리드 덤프를 하나로 합친다.

WHY
===
novelty 교정은 CANONICAL(openworld_merged.jsonl) 위에서 맞춰져 있는데, 그 60 instance 는
`closed_at_fire` 가 {50,58} 두 값뿐이라 `progress` 축의 sd 가 0.005 다. 그래서 배포 데모처럼
중반에 터지는 사건이 **종류와 무관하게** novel 로 판정된다(2026-08-04 진단).

`DS_FIRE_GRID` 로 만든 새 행들은 그 축에 실제 분산을 넣는다. 이 스크립트는 CANONICAL 을
**덮어쓰지 않고** 새 행을 덧붙인 별도 파일을 만든다 -- 발표된 regret/frontier 숫자는 전부
CANONICAL 분포에서 측정됐으므로 그 파일은 그대로 두어야 재현된다.

중복 제거 키 = (instance, macro, rollout). 같은 instance 를 두 번 돌렸으면 **나중 파일**이 이긴다
(재실행이 수정이라는 뜻이므로).

Usage:
    python merge_firegrid.py out.jsonl base.jsonl extra1.jsonl [extra2.jsonl ...]
    python merge_firegrid.py                    # 기본: firegrid_merged.jsonl <- canonical + firegrid_*.jsonl
"""
import glob
import io
import json
import os
import sys
from collections import Counter

import wm_datasets

HERE = os.path.dirname(os.path.abspath(__file__))


def key(row):
    return (str(row.get("instance")), int(row.get("macro", -1)), int(row.get("rollout", 0)))


def read(path):
    rows = []
    with io.open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        out, sources = args[0], args[1:]
    else:
        out = wm_datasets.abspath(wm_datasets.FIREGRID)
        sources = [wm_datasets.abspath(wm_datasets.CANONICAL)] + sorted(
            glob.glob(os.path.join(HERE, "oracle", "out", "firegrid_s*.jsonl")))
    out = wm_datasets.abspath(out)

    merged = {}
    for src in sources:
        src = wm_datasets.abspath(src)
        if not os.path.isfile(src):
            print(f"[skip] missing {src}")
            continue
        rows = read(src)
        n_new = sum(1 for r in rows if key(r) not in merged)
        for r in rows:
            merged[key(r)] = r          # 나중 파일이 이긴다
        print(f"[merge] {os.path.relpath(src, HERE):55s} {len(rows):5d} rows (+{n_new} new)")

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with io.open(out, "w", encoding="utf-8") as fh:
        for r in merged.values():
            fh.write(json.dumps(r) + "\n")
    print(f"\n[merge] wrote {len(merged)} rows -> {os.path.relpath(out, HERE)}")

    # ---- 이 병합이 실제로 무엇을 고쳤는지 보고 ------------------------------------------------
    fired = [r for r in merged.values() if r.get("fired") is True]
    inst = {}
    for r in fired:
        inst.setdefault(str(r.get("instance")), r)
    print(f"\n[audit] fired instances: {len(inst)}")
    prog = sorted(float(r.get("progress", 0.0)) for r in inst.values())
    if prog:
        n = len(prog)
        mean = sum(prog) / n
        sd = (sum((p - mean) ** 2 for p in prog) / n) ** 0.5
        print(f"  progress: min={prog[0]:.4f} max={prog[-1]:.4f} mean={mean:.4f} sd={sd:.5f}")
        print(f"  distinct closed_at_fire: "
              f"{sorted({int(r.get('closed_at_fire', -1)) for r in inst.values()})}")
    per_kind = Counter(str(r.get("kind")) for r in inst.values())
    for k, c in sorted(per_kind.items()):
        ps = sorted(float(r.get("progress", 0.0)) for r in inst.values() if str(r.get("kind")) == k)
        print(f"  {k:10s} n={c:3d}  progress {ps[0]:.3f} .. {ps[-1]:.3f}")


if __name__ == "__main__":
    main()
