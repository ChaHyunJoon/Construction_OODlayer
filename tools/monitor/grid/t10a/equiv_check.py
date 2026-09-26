"""병렬 동등성·무하네스 대조 판정.
  python3 equiv_check.py <b0_root> <model> <case> <seed> [<t3_capture_dir>]
seq(부하 없음 순차 B0) vs par(8병렬 B0): 부모 trace.tsv 전 열(rng 제외) · terminal final_digest(rng 제외)·결과 · 실제 스트림 바이트.
control_off(plain render_demo, 훅 없음): [score] 줄 · 스트림 바이트 vs par B0. 선택: T3 역사적 순차 capture 의 결과.
"""
import json, os, re, sys, hashlib
b0, model, case, seed = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
key = "canonical__%s__s%d" % (case, seed)
base = "tractor" if model == "tractor" else "30051_1_X_wing_Fighter_Mini"
stream = "streams/%s__canonical_%s_s%d_z%d.jsonl" % (base, case, seed, seed)

def trace(d):
    rows = {}
    for l in open(os.path.join(d, "trace.tsv")):
        if l.startswith("#"): continue
        f = l.rstrip("\n").split("\t"); rows[int(f[0])] = f[1:7]      # loop cache sched scene rvo globals (rng 제외)
    return rows

def term(d):
    t = json.load(open(os.path.join(d, "terminal.json")))
    fd = {k: v for k, v in t["final_digest"].items() if k != "rng"}
    return {k: t.get(k) for k in ("complete", "terminal_reason", "closed", "total", "iter", "no_progress")}, fd

def score(log):
    s = [l for l in open(log, errors="replace") if l.startswith("[score] ")]
    return re.sub(r" (campaign|run)_\S+", "", s[-1].strip()) if s else None

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()[:16] if os.path.isfile(p) else None

out = {"cell": "%s %s s%d" % (model, case, seed)}
seqp, parp = (os.path.join(b0, g, model, "zr", key, "parent") if g else os.path.join(b0, model, "zr", key, "parent") for g in ("seq", None))
ts, tp = trace(seqp), trace(parp)
common = sorted(set(ts) & set(tp))
first = next((i for i in common if ts[i] != tp[i]), None)
(o1, d1), (o2, d2) = term(seqp), term(parp)
out["seq_vs_par"] = {"common_boundaries": len(common), "only_seq": len(set(ts) - set(tp)), "only_par": len(set(tp) - set(ts)),
                     "first_divergent_iter": first, "terminal_equal": o1 == o2, "final_digest_equal_ex_rng": d1 == d2,
                     "seq_terminal": o1, "par_terminal": o2,
                     "stream_sha_seq": sha(os.path.join(b0, "seq", model, stream)), "stream_sha_par": sha(os.path.join(b0, model, stream)),
                     "score_seq": score(os.path.join(b0, "seq", model, "log", key + ".log")),
                     "score_par": score(os.path.join(b0, model, "log", key + ".log"))}
out["seq_vs_par"]["stream_bytes_equal"] = out["seq_vs_par"]["stream_sha_seq"] == out["seq_vs_par"]["stream_sha_par"]
c = os.path.join(b0, "control_off", model)
if os.path.isdir(c):
    out["control_off_vs_par"] = {"score_off": score(os.path.join(c, "log", key + ".log")), "score_par": out["seq_vs_par"]["score_par"],
                                 "stream_sha_off": sha(os.path.join(c, stream)), "stream_sha_par": out["seq_vs_par"]["stream_sha_par"]}
    x = out["control_off_vs_par"]; x["score_equal"] = x["score_off"] == x["score_par"]; x["stream_bytes_equal"] = x["stream_sha_off"] == x["stream_sha_par"]
if len(sys.argv) > 5:
    o3, d3 = term(sys.argv[5]); t3 = trace(sys.argv[5])
    cm = sorted(set(t3) & set(tp))
    out["t3_hist_seq_vs_par"] = {"t3_terminal": o3, "terminal_equal": o3 == o2, "final_digest_equal_ex_rng": d3 == d2,
                                 "common_boundaries": len(cm), "first_divergent_iter": next((i for i in cm if t3[i] != tp[i]), None),
                                 "note": "T3 capture @da1d8d0d — older code; a divergence here is not a parallelism finding"}
print(json.dumps(out, indent=1))
