"""compare_v1_v2.py <v1_root> <v2_root> — 발동 계수 추가(26f20ab7)가 궤적을 안 바꿨나: 판마다 실제 스트림 바이트,
부모 trace 열(loop·cache·sched·scene·rvo 는 전 경계 같아야; globals 는 _ABLATION_COUNTS 를 싣으므로 첫 unwedge 뒤에만 달라도 된다),
terminal(결과·closed·iter)·final_digest(rng·globals 제외)."""
import json, os, sys, hashlib
from collections import Counter
v1, v2 = sys.argv[1:3]
COLS = ["loop", "cache", "sched", "scene", "rvo", "globals"]
def trace(p):
    d = {}
    if not os.path.isfile(p): return d
    for l in open(p):
        if l.startswith("#"): continue
        f = l.rstrip("\n").split("\t"); d[int(f[0])] = f[1:7]
    return d
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else None
def jl(p): return json.load(open(p)) if os.path.isfile(p) else None
rows = []
for m in ("tractor", "xwing"):
    for j in map(json.loads, open(os.path.join(v2, m, "jobs.jsonl"))):
        k = j["run_key"]; s1 = j["stream"].replace(v2, v1); s2 = j["stream"]
        p1, p2 = (os.path.join(r, m, "zr", k, "parent") for r in (v1, v2))
        t1, t2 = trace(p1 + "/trace.tsv"), trace(p2 + "/trace.tsv")
        common = sorted(set(t1) & set(t2))
        diffcols = Counter(COLS[i] for it in common for i in range(6) if t1[it][i] != t2[it][i])
        first_g = next((it for it in common if t1[it][5] != t2[it][5]), None)
        T1, T2 = jl(p1 + "/terminal.json"), jl(p2 + "/terminal.json")
        term = lambda T: None if T is None else {x: T.get(x) for x in ("complete", "terminal_reason", "closed", "iter")}
        fd = lambda T: None if T is None else {x: v for x, v in T["final_digest"].items() if x not in ("rng", "globals")}
        rows.append({"model": m, "run_key": k, "stream_equal": sha(s1) == sha(s2) and sha(s1) is not None,
                     "trace_common": len(common), "trace_only_one_side": len(set(t1) ^ set(t2)), "trace_diff_cols": dict(diffcols),
                     "first_globals_diff_iter": first_g, "terminal_equal": term(T1) == term(T2) and T1 is not None,
                     "final_digest_equal_ex_rng_globals": fd(T1) == fd(T2) and T1 is not None})
ok = [r for r in rows if r["stream_equal"] and r["terminal_equal"] and not (set(r["trace_diff_cols"]) - {"globals"}) and r["trace_only_one_side"] == 0]
unw = {}
for r in rows:
    b = jl(os.path.join(v2, r["model"], "zr", r["run_key"], "b0.json")) or {}
    a = (b.get("terminal") or {}).get("ablation") or ""
    unw[r["model"] + "/" + r["run_key"]] = sum(int(x.rsplit("=", 1)[1]) for x in a.split("detail=")[-1].split(",") if x.startswith("recovery:unwedge_nominal"))
    r["v2_unwedge_fired"] = unw[r["model"] + "/" + r["run_key"]]
fg = [r["first_globals_diff_iter"] for r in rows if r["first_globals_diff_iter"] is not None]
print(json.dumps({"n": len(rows),
                  "globals_diff_only_where_unwedge_fired": all((r["first_globals_diff_iter"] is None) == (r["v2_unwedge_fired"] == 0) for r in rows),
                  "min_first_globals_diff_iter": min(fg) if fg else None, "n_all_equal_except_globals_counter": len(ok),
                  "trace_diff_cols_total": dict(sum((Counter(r["trace_diff_cols"]) for r in rows), Counter())),
                  "not_equal": [r for r in rows if r not in ok]}, indent=1))
