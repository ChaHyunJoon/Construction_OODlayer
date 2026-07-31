#!/usr/bin/env python
"""merge_nominal.py -- join the freshly generated kind="none" rows onto the base dataset.

WHAT THIS PRODUCES
==================
    oracle/out/openworld_merged.jsonl        base: 300 rows, 60 instances, 3 disturbance kinds
  + oracle/out/nominal_shard{1,2}.jsonl       new: one kind="none" row per instance
  = oracle/out/openworld_nominal.jsonl        the dataset M_nominal can be fitted on

The base file is NEVER modified. Every published number was measured on it, and a dataset that
silently grows rows is a dataset whose old results cannot be reproduced. The merge writes a new
file, and `wm_datasets.py` gains a name for it.

WHY THE JOIN IS CHECKED
=======================
A nominal row is only meaningful next to the disturbed runs of the SAME instance -- same seed,
same spares, same world minus the fired OOD. If the instance ids do not line up, the nominal
rows describe a different world than the ones they are supposed to be the control for, and every
downstream comparison is quietly wrong. So this script refuses to write a merged file whose
nominal rows do not match base instances 1:1, and prints exactly what is missing or extra.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
새로 만든 kind="none" 행을 기존 데이터셋에 붙여 **새 파일**로 쓴다. 원본은 절대 건드리지 않는다
-- 기존 발표 숫자가 전부 그 파일에서 나왔고, 행이 조용히 늘어나는 파일은 과거 결과를 재현할 수 없다.

조인을 검사하는 이유: nominal 행은 **같은 instance**의 교란 런 옆에 있을 때만 의미가 있다
(같은 seed·같은 스페어·OOD만 뺀 같은 세계). id 가 어긋나면 "대조군이 다른 세계의 것"이 되어
이후 비교가 전부 조용히 틀린다. 그래서 1:1 이 아니면 파일을 쓰지 않고 무엇이 빠졌는지 찍는다.

USAGE
    python merge_nominal.py                      # 검사 + 병합
    python merge_nominal.py --check              # 검사만(쓰지 않음)
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import wm_datasets

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = wm_datasets.abspath(wm_datasets.CANONICAL)
SHARD_GLOB = os.path.join(HERE, "oracle", "out", "nominal_shard*.jsonl")
OUT = os.path.join(HERE, "oracle", "out", "openworld_nominal.jsonl")

NOMINAL_SUFFIX = "_nominal"


def read_jsonl(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main():
    check_only = "--check" in sys.argv

    base = read_jsonl(BASE)
    base_inst = sorted({r["instance"] for r in base})
    print("base   : %s" % wm_datasets.describe(wm_datasets.CANONICAL))
    print("         %d rows, %d instances" % (len(base), len(base_inst)))

    shards = sorted(glob.glob(SHARD_GLOB))
    nom = []
    for s in shards:
        rs = read_jsonl(s)
        nom.extend(rs)
        print("shard  : %-28s %3d rows" % (os.path.basename(s), len(rs)))
    if not nom:
        print("\nno nominal rows yet -- generation still running?")
        return 1

    # 중복 방어: 재개(append)나 샤드 중복 실행으로 같은 instance 가 두 번 들어올 수 있다.
    by_inst = {}
    dupes = 0
    for r in nom:
        k = r["instance"]
        if k in by_inst:
            dupes += 1
        by_inst[k] = r          # 나중 것이 이김(재실행분이 최신)
    if dupes:
        print("         (%d duplicate nominal rows collapsed -- resume/rerun overlap)" % dupes)

    # ---- join integrity ------------------------------------------------------------------
    nom_base = {k[:-len(NOMINAL_SUFFIX)] if k.endswith(NOMINAL_SUFFIX) else k for k in by_inst}
    missing = sorted(set(base_inst) - nom_base)      # 교란 런은 있는데 nominal 이 없는 instance
    extra = sorted(nom_base - set(base_inst))        # base 에 없는 nominal

    print("\njoin   : %d/%d base instances have a nominal row" % (len(base_inst) - len(missing),
                                                                  len(base_inst)))
    if missing:
        print("         MISSING (%d): %s%s" % (len(missing), ", ".join(missing[:6]),
                                               " ..." if len(missing) > 6 else ""))
    if extra:
        print("         EXTRA   (%d): %s%s" % (len(extra), ", ".join(extra[:6]),
                                               " ..." if len(extra) > 6 else ""))

    # ---- sanity on the rows themselves ----------------------------------------------------
    bad = []
    for k, r in by_inst.items():
        if r.get("kind") != "none":
            bad.append((k, "kind=%r not 'none'" % r.get("kind")))
        if r.get("fired") not in (False, "false"):
            bad.append((k, "fired=%r -- would be picked up by load_df()" % r.get("fired")))
        if int(r.get("macro", -1)) != 0:
            bad.append((k, "macro=%r not NOOP" % r.get("macro")))
    if bad:
        print("\n  ROW DEFECTS (%d):" % len(bad))
        for k, why in bad[:8]:
            print("    %-40s %s" % (k, why))

    ok = not missing and not extra and not bad
    if not ok:
        print("\nREFUSING to write %s -- fix the above first." % os.path.basename(OUT))
        print("(incomplete generation is fine: just rerun this once the shards finish)")
        return 2
    if check_only:
        print("\ncheck passed; --check given, not writing.")
        return 0

    with open(OUT, "w", encoding="utf-8") as fh:
        for r in base:
            fh.write(json.dumps(r) + "\n")
        for k in sorted(by_inst):
            fh.write(json.dumps(by_inst[k]) + "\n")
    print("\nwrote %s" % OUT)
    print("      %d rows = %d base + %d nominal" % (len(base) + len(by_inst), len(base),
                                                    len(by_inst)))
    print("\nnext: python classify3_report.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
