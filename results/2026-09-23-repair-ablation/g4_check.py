"""G4 pilot checks a–f (Task 12). Usage: python3 g4_check.py [seeds, default "1 2 3 4"]
Parses run logs with tools/monitor/build_sweep_dataset.py parse_log; prints a table + verdicts.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "monitor"))
from build_sweep_dataset import parse_log  # noqa: E402

ARMS = ("none", "translate", "all")
SEEDS = (sys.argv[1] if len(sys.argv) > 1 else "1 2 3 4").split()
ALLOWED_EXEMPT = {"policy_payload", "reference_label", "monitor_record", "dp_lane"}
PRIOR = os.path.join(ROOT, "results", "2026-09-23-router-sol-tractor", "log")
COST = os.path.join(ROOT, "results", "2026-09-23-router-sol", "cost.py")


def jl_syms(src, const):
    """`const NAME = Symbol[ :a, :b ]` → names (reads the source of truth, no hand copy)."""
    m = re.search(r"const %s = (?:vcat\(\w+,\s*)?Symbol\[(.*?)\]" % const, src, re.S)
    return re.findall(r":([\w!]+)", m[1])


src = open(os.path.join(ROOT, "src", "respec", "repair_ablation.jl")).read()
T = jl_syms(src, "_ABLATE_TRANSLATE")
RESERVED = {"none": [], "translate": T + jl_syms(src, "_ABLATION_MACHINERY"),
            "all": T + jl_syms(src, "_ABLATE_ALL") + jl_syms(src, "_ABLATION_MACHINERY")}
assert len(set(T + jl_syms(src, "_ABLATE_ALL"))) == 12, "blocked list drifted"


def mentions(code, names):
    return sorted({n for n in names if re.search(r"(?<![\w!])%s(?![\w!])" % re.escape(n), code or "")})


recs, texts, ok = {}, {}, {}
for arm in ARMS:
    for s in SEEDS:
        p = os.path.join(HERE, "%s-tractor" % arm, "log", "router__zone__s%s.log" % s)
        txt = open(p, errors="replace").read() if os.path.isfile(p) else ""
        texts[arm, s] = txt
        recs[arm, s] = parse_log(txt, "router", "zone", int(s))

print("%-9s %-2s %-6s %-8s %-6s %-5s %-6s %-6s %-9s %-16s %s" % (
    "arm", "s", "score", "complete", "closed", "armed", "denied", "exempt", "ladder_sk", "config_digest", "detail"))
for (arm, s), r in recs.items():
    if r is None:
        tail = texts[arm, s].strip().splitlines()[-1:] or ["<no log>"]
        print("%-9s %-2s DIED   last: %s" % (arm, s, tail[0][:120]))
        continue
    a = r["ablation"] or {}
    print("%-9s %-2s %-6s %-8s %-6s %-5s %-6s %-6s %-9s %-16s %s" % (
        arm, s, "yes", r["complete"], r["closed"], a.get("armed"), a.get("denied"), a.get("exempt"),
        a.get("ladder_zone_skipped"), (r["run_ctx"] or {}).get("config_digest"), a.get("detail")))

# a. [ablation] line: level == arm, armed, denied=0, exempt keys ⊆ allowed
bad_a, denied_by = [], []
for (arm, s), r in recs.items():
    a = (r or {}).get("ablation")
    if not a:
        bad_a.append((arm, s, "no [ablation] line / died")); continue
    keys = [kv.split("=")[0] for kv in a["detail"].split(",") if kv]
    ex = {k.split(":")[1] for k in keys if k.startswith("exempt:")}
    if a["level"] != arm or not a["armed"] or a["denied"] != 0 or not ex <= ALLOWED_EXEMPT:
        bad_a.append((arm, s, "level=%s armed=%s denied=%d exempt_sites=%s" % (a["level"], a["armed"], a["denied"], sorted(ex))))
    denied_by += [(arm, s, k) for k in keys if k.startswith("denied")]
ok["a"] = not bad_a
print("\n[a] %s %s" % ("PASS" if ok["a"] else "FAIL", bad_a or ""), "denied keys:", denied_by or "none")

# b. same seed → identical zone_place across arms
bad_b = [(s, {arm: (recs[arm, s] or {}).get("zone_place") for arm in ARMS}) for s in SEEDS
         if len({(recs[arm, s] or {}).get("zone_place") for arm in ARMS}) != 1
         or (recs["none", s] or {}).get("zone_place") is None]
ok["b"] = not bad_b
print("[b] %s %s" % ("PASS" if ok["b"] else "FAIL", bad_b or ""))

# c. run-ctx level == arm; config_digest constant within arm, distinct across arms
dig, bad_c = {}, []
for (arm, s), r in recs.items():
    ctx = (r or {}).get("run_ctx") or {}
    if ctx.get("repair_ablation") != arm:
        bad_c.append((arm, s, ctx.get("repair_ablation")))
    dig.setdefault(arm, set()).add(ctx.get("config_digest"))
within = all(len(v) == 1 for v in dig.values())
across = len({next(iter(v)) for v in dig.values()}) == len(ARMS)
ok["c"] = not bad_c and within and across
print("[c] %s level_mismatch=%s digests=%s" % ("PASS" if ok["c"] else "FAIL", bad_c or "none",
                                                 {k: sorted(map(str, v)) for k, v in dig.items()}))

# d. ablation-arm ledger bodies naming a reserved name must end in reject:ablated_primitive
print("[d]", end="")
ok["d"] = True
for arm in ("translate", "all"):
    p = os.path.join(HERE, "ledger_%s.jsonl" % arm)
    rows = [json.loads(l) for l in open(p)] if os.path.isfile(p) else []
    logs = "\n".join(texts[arm, s] for s in SEEDS)
    rej_log = set(re.findall(r"reject:ablated_primitive:([\w!]+)", logs))
    child_why = {r.get("parent_record_id"): str(r.get("impl_rejected_why") or r.get("rewrite_of_why") or "")
                 for r in rows if r.get("row_type") == "rewrite"}
    hits = unproven = 0
    for r in rows:
        h = mentions(r.get("impl_code"), RESERVED[arm])
        if not h:
            continue
        hits += 1
        proven = "reject:ablated_primitive" in child_why.get(r.get("record_id"), "") or bool(set(h) & rej_log)
        if not proven:
            unproven += 1
            print("\n    UNPROVEN %s %s names=%s" % (arm, r.get("impl_name"), h), end="")
    ok["d"] &= unproven == 0
    print(" %s: rows=%d reserved_mentions=%d unproven=%d log_rejects=%s;" % (arm, len(rows), hits, unproven, sorted(rej_log)), end="")
print(" =>", "PASS" if ok["d"] else "FAIL")

# e. none arm vs 9/23 sol run (informational)
print("[e] info: seed | none-arm complete/closed | 9/23 sol complete/closed")
for s in SEEDS:
    p = os.path.join(PRIOR, "router__zone__s%s.log" % s)
    pr = parse_log(open(p, errors="replace").read(), "router", "zone", int(s)) if os.path.isfile(p) else None
    n = recs["none", s]
    f = lambda r: "%s/%s" % (r["complete"], r["closed"]) if r else "died"
    print("    s%s | %s | %s" % (s, f(n), f(pr)))

# f. ledger rows + cost
print("[f] cost (cost.py usd_raw_lm, estimate; excludes macro calls / unreceived responses):")
tot = 0.0
for arm in ARMS:
    p = os.path.join(HERE, "ledger_%s.jsonl" % arm)
    if not os.path.isfile(p):
        print("    %s: no ledger" % arm); continue
    c = json.loads(subprocess.check_output([sys.executable, COST, p, str(len(SEEDS))]))
    tot += c["usd_raw_lm"]
    print("    %s: %s" % (arm, json.dumps(c)))
print("    total usd_raw_lm = %.4f" % tot)
print("\nVERDICT", {k: ("PASS" if v else "FAIL") for k, v in ok.items()})
