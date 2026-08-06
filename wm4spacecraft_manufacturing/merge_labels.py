#!/usr/bin/env python
"""merge_labels.py -- 오라클 라벨 JSONL 을 합친다.

왜 스크립트인가: 손으로 cat 하면 **instance id 충돌**을 못 본다. 같은 id 가 두 파일에 있으면
groupby("instance") 가 서로 다른 세계의 팔을 한 instance 로 뭉쳐 랭킹이 조용히 망가진다.
여기서는 충돌을 에러로 만든다(--prefix 로 명시적으로 해소).

사용:
    python merge_labels.py --out oracle/out/n44_plus8.jsonl \
        oracle/out/graded_hs_n44.jsonl oracle/out/battgrid_0805_s1.jsonl
"""
import argparse, io, json, os, sys
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", action="store_true",
                    help="instance id 앞에 파일 stem 을 붙여 충돌을 해소한다")
    ap.add_argument("inputs", nargs="+")
    a = ap.parse_args()

    seen = defaultdict(set)          # instance -> {source stem}
    rows = []
    for p in a.inputs:
        stem = os.path.splitext(os.path.basename(p))[0]
        with io.open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                inst = str(r.get("instance", ""))
                if a.prefix:
                    inst = "%s::%s" % (stem, inst)
                    r["instance"] = inst
                seen[inst].add(stem)
                rows.append(r)

    clash = {i: sorted(s) for i, s in seen.items() if len(s) > 1}
    if clash:
        print("ERROR: instance id 가 여러 파일에 있다 (%d 개). --prefix 로 해소하라." % len(clash),
              file=sys.stderr)
        for i, s in list(clash.items())[:5]:
            print("  %s <- %s" % (i, s), file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with io.open(a.out, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("wrote %d rows / %d instances -> %s" % (len(rows), len(seen), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
