#!/usr/bin/env bash
# Merge the new seed-3/4/5 labels with the original 20 instances and re-run every comparison that
# was previously limited by n=20. Nothing here is destructive: the merged set is a NEW file and the
# original graded_hs_all.jsonl is left untouched.
# (새 라벨 + 기존 20개를 합쳐 n을 키운 뒤, n=20 때문에 결론이 안 났던 비교를 전부 다시 돌린다.)
#
# Usage: bash analyze_n44.sh
set -u
cd "$(dirname "$0")"
MERGED=oracle/out/graded_hs_n44.jsonl
export EVAL_DATA="$PWD/$MERGED"
export EVAL_TAG="_n44"

echo "== 1. merge (dedup by instance+macro) =="
# 같은 instance가 두 파일에 있을 수 있다(배치 job이 중간에 죽고 filler가 다시 채운 경우).
# 중복을 그대로 두면 그 instance는 행이 10개가 되어 "매크로 5개" 필터에서 통째로 탈락한다 -> 반드시 dedup.
python - "$MERGED" <<'PY'
import json, glob, os, sys
out = sys.argv[1]
seen, rows = set(), []
for p in [os.path.join("oracle/out/graded_hs_all.jsonl")] + sorted(glob.glob("oracle/out/graded_hs_s345/*.jsonl")):
    if not os.path.exists(p):
        continue
    for l in open(p, encoding="utf-8"):
        if not l.strip():
            continue
        r = json.loads(l)
        key = (r["instance"], r["macro"])
        if key in seen:                       # 먼저 나온 쪽을 유지(기존 20개 우선)
            continue
        seen.add(key); rows.append(l.rstrip("\n"))
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
print("  merged %d unique (instance,macro) rows -> %s" % (len(rows), out))
PY
python - <<'PY'
import json, collections, os
rows = [json.loads(l) for l in open(os.environ["EVAL_DATA"]) if l.strip()]
per = collections.Counter(r["instance"] for r in rows)
full = [i for i, c in per.items() if c == 5]          # 5개 매크로가 다 있는 인스턴스만 유효
partial = [i for i, c in per.items() if c != 5]
kinds = collections.Counter(r["kind"] for r in rows if r["instance"] in full)
print("  rows=%d  instances=%d  usable(5-macro)=%d  partial=%d" % (len(rows), len(per), len(full), len(partial)))
if partial:
    print("  partial (excluded):", partial)
print("  usable by kind:", {k: v // 5 for k, v in kinds.items()})
PY

echo
echo "== 2. difficulty audit (is the bigger set still non-trivial?) =="
python e1_analyze.py "$MERGED" --cost-aware 2>&1 | tail -25

echo
echo "== 3. HP sweep at the new n =="
python sweep_surrogate.py "$MERGED" --cost-aware 2>&1 | tail -30

echo
echo "== 4. LLM producer re-run on the new instances (gpt-4o) =="
DSPY_MODEL=gpt-4o DSPY_ARMS=A0,A1,A1b,A2,A3,A4 DSPY_DATA="$MERGED" python dspy_real_experiment.py 2>&1 | tail -20

echo
echo "== 5. paired forest-vs-LLM bootstrap at the new n =="
python compare_dspy_vs_forest.py 2>&1 | tail -25

echo
echo "== 6. deployment decision matrix (catastrophic axis) =="
python producer_decision_matrix.py 2>&1 | tail -20
