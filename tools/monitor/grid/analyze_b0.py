#!/usr/bin/env python3
"""T10a: B0(pi0) 120판 요약 + 역사적 canonical 대비 drift.

  python3 tools/monitor/grid/analyze_b0.py <b0_root> <out_dir>   (T10a; 시험: test_analyze_b0.py)
  <b0_root>/{tractor,xwing}/  = campaign.py(runner=b0) 격자. 출력: b0_episodes.json · b0_episodes.tsv · b0_summary.json
분모 = jobs.jsonl 의 계획 판 전부. 결과 분류(설계 §7.1·§9.1, RepairTypes.ROLLOUT_OUTCOMES):
  COMPLETE            부모 terminal.json terminal_reason == project_complete (그리고 [score] complete=true 와 일치)
  FAIL_WITHIN_BUDGET  terminal_reason ∈ {no_progress_limit, max_sim_steps}
  UNKNOWN(<cause>)    wall_timeout(campaign 시한) · worker_crash(terminal 없음/사유 없음) · missing(판 없음) · driver:<status>
"""
import json, os, re, sys
from collections import Counter, defaultdict

ROOT = "/home/chahj578/Construction_OODlayer"
sys.path.insert(0, os.path.join(ROOT, "tools", "monitor"))
import build_sweep_dataset as BSD  # noqa: E402

MODELS = {"tractor": "tractor.mpd", "xwing": "30051-1 - X-wing Fighter - Mini.mpd"}


def jl(p):
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.isfile(p) else []


def jload(p):
    return json.load(open(p)) if os.path.isfile(p) else None


def ablation(s):
    if not s:
        return None
    m = re.match(r"level=(\S+) armed=(\S+) denied=(\d+) exempt=(\d+) ladder_zone_skipped=(\d+) ladder_zone_fired=(\d+) detail=(\S*)", s)
    if not m:
        return {"raw": s}
    det = dict((k, int(v)) for k, v in (x.rsplit("=", 1) for x in m[7].split(",") if "=" in x))
    return {"level": m[1], "armed": m[2] == "true", "denied": int(m[3]), "exempt": int(m[4]),
            "ladder_zone_skipped": int(m[5]), "ladder_zone_fired": int(m[6]), "detail": det}


def recovery_counts(stream):
    """branch_runner.validate_branch 와 같은 규칙: 마지막 원장 행의 respec_history(결정) + recovery(내부 복구)."""
    last = BSD.last_json_line(stream) if stream and os.path.isfile(stream) else None
    if last is None:
        return None, None
    rec, zone_non_noop = Counter(), 0
    for d in last.get("respec_history") or []:
        ev = str((d.get("input") or {}).get("event")); ch = str(d.get("chosen"))
        rec["decision:%s:%s" % (ev, ch.split()[0] if ch.split() else ch)] += 1
        if ev == "ZONE" and not ch.startswith("NOOP"):
            zone_non_noop += 1
    for r in last.get("recovery") or []:
        rec["recovery:%s:%s" % (r.get("action"), r.get("status"))] += 1
    return dict(sorted(rec.items())), zone_non_noop


def classify(dr, t):
    """(outcome, unknown_cause). dr = campaign runs.jsonl 의 마지막 기록(없으면 {}), t = 부모 terminal.json(없으면 {})."""
    reason = t.get("terminal_reason")
    if dr.get("timeout"):
        return "UNKNOWN", "wall_timeout"
    if not dr:
        return "UNKNOWN", "missing"
    if str(dr.get("status", "")).startswith("error:") and dr["status"] != "error:ctx_mismatch" and not t:
        return "UNKNOWN", "driver:" + dr["status"]
    if reason == "project_complete":
        return "COMPLETE", None
    if reason in ("no_progress_limit", "max_sim_steps"):
        return "FAIL_WITHIN_BUDGET", None
    return "UNKNOWN", "worker_crash"


def manifest_build_mismatches(build, fp):
    """manifest.build 가 부모 t0 봉투의 지문(RepairTypes.Fingerprints)과 다른 필드. fp 가 없으면 None."""
    if not fp:
        return None
    want = {k: build[k] for k in ("code_rev", "code_dirty_digest", "config_digest", "julia_version", "manifest_digest",
                                  "build_id", "julia_threads")}
    want.update(solver_name=build["solver"]["name"], solver_version=build["solver"]["version"],
                solver_seed=build["solver"]["seed"], solver_threads=build["solver"]["threads"])
    return sorted(k for k, v in want.items() if fp.get(k) != v)


def rel(p):
    return None if p is None else os.path.relpath(p, ROOT)


def episode(grid, model, job, drv, bsd_run, bsd_uns):
    key = job["run_key"]
    zr = os.path.join(grid, "zr", key)
    b0 = jload(os.path.join(zr, "b0.json"))
    dr = drv.get(key) or {}
    e = {"model": model, "case": job["case"], "seed": job["seed"], "zone_seed": job["zone_seed"], "run_key": key,
         "campaign_status": dr.get("status", "missing"), "rc": dr.get("rc"), "timeout": dr.get("timeout"),
         "elapsed_s": dr.get("elapsed"), "log": rel(job["log"]), "stream": rel(job["stream"]),
         "b0_record": rel(os.path.join(zr, "b0.json")) if b0 else None, "parent_dir": rel(os.path.join(zr, "parent"))}
    t = (b0 or {}).get("terminal") or {}
    if b0 is None and os.path.isfile(os.path.join(zr, "parent", "terminal.json")):
        t = jload(os.path.join(zr, "parent", "terminal.json"))
    reason = t.get("terminal_reason")
    out, cause = classify(dr, t)
    e.update(outcome=out, unknown_cause=cause, terminal_reason=reason, complete=t.get("complete"),
             closed=t.get("closed"), total=t.get("total"), iter=t.get("iter"), no_progress=t.get("no_progress"),
             n_blocked=t.get("n_blocked"), project_blocked=t.get("project_blocked"),
             rng_advanced_after_t0=t.get("rng_advanced_after_t0"))
    e["score_agrees"] = None if bsd_run is None or t.get("complete") is None else bsd_run["complete"] == t.get("complete")
    ab = ablation(t.get("ablation"))
    e["ablation"] = ab
    if ab and "denied" in ab:
        e["zone_solver_denied"] = ab["denied"]
        e["zone_solver_exempt"] = ab["exempt"]
        e["zone_ladder_fired"] = ab["ladder_zone_fired"]
        e["zone_ladder_skipped"] = ab["ladder_zone_skipped"]
    b = b0 or {}
    held = jload(os.path.join(zr, "parent", "held.json"))       # b0.json 이 없어도(드라이버가 죽은 판) t0 capture 사실은 남는다
    e.update(t0_captured=b.get("t0_captured", held is not None if os.path.isdir(os.path.join(zr, "parent")) else None),
             t0_iter=b.get("t0_iter", (held or {}).get("t0_iter")),
             certification_gaps=b.get("certification_gaps"), budget_violations=b.get("budget_violations"),
             verify_mismatched_blocks=(b.get("verify") or {}).get("mismatched_blocks"),
             verify_counters_equal=(b.get("verify") or {}).get("counters_equal"),
             verify_rng_equal=(b.get("verify") or {}).get("rng_equal"),
             task_contract_sha256=((b.get("task_contract") or {}).get("sha256")),
             cpu_s=b.get("cpu_s"), exit_code=b.get("exit_code"))
    e["general_recovery_unledgered"] = "maybe_unwedge_nominal! (every UNWEDGE_INTERVAL no-progress iters) is not ledgered; only its zone-ladder branch is counted (zone_ladder_*)"
    env = jload(os.path.join(zr, "parent", "t0.envelope.json"))
    man = jload(b["manifest"]) if b.get("manifest") else None
    e["manifest_build_mismatches"] = None if man is None else manifest_build_mismatches(man["build"], (env or {}).get("fingerprints"))
    e["certification"] = None if b0 is None else ("available" if not b.get("certification_gaps") else "unavailable")
    rc, znn = recovery_counts(job["stream"])
    e["stream_sha256_16"] = BSD.hashlib.sha256(open(job["stream"], "rb").read()).hexdigest()[:16] if os.path.isfile(job["stream"]) else None
    e["recovery_counts"], e["zone_decisions_non_noop"] = rc, znn
    if bsd_run:
        for k in ("init_fp", "ood_fp", "zone_place", "fail_mode", "stop_sig", "run_ctx"):
            e[k] = bsd_run.get(k)
        e["decisions"] = [{k: d.get(k) for k in ("at", "event", "chosen", "enacted")} for d in bsd_run.get("decisions") or []]
    return e


def main(b0root, out):
    cohort = json.load(open(os.path.join(ROOT, "test/fixtures/repair_verification/cohort.json")))
    hist = {(r["model"], r["case"], r["seed"], r["zone_seed"]): r for r in cohort["runs"]}
    eps = []
    for model in ("tractor", "xwing"):
        grid = os.path.join(b0root, model)
        jobs = jl(os.path.join(grid, "jobs.jsonl"))
        drv = {}
        for r in jl(os.path.join(grid, "runs.jsonl")):
            drv[r["run_key"]] = r
        runs, uns, den = BSD.collect_jobs(grid)
        byk = {r["run_key"]: r for r in runs}
        ubk = {u["run_key"]: u for u in uns}
        for j in jobs:
            eps.append(episode(grid, model, j, drv, byk.get(j["run_key"]), ubk.get(j["run_key"])))
    # 역사적 join
    for e in eps:
        h = hist.get((e["model"], e["case"], e["seed"], e["zone_seed"]))
        e["hist_class"] = h["class"] if h else None
        e["hist_a2_class"] = h["a2_class"] if h else None
        e["hist_flags"] = h["flags"] if h else None
        hc = (h or {}).get("canonical") or {}
        e["hist_closed"], e["hist_status"] = hc.get("closed"), hc.get("status")
        e["prefix_vs_hist"] = None if not h or e.get("init_fp") is None else {
            "init_fp": e["init_fp"] == hc.get("init_fp"), "ood_fp": e.get("ood_fp") == hc.get("ood_fp"),
            "zone_place": e.get("zone_place") == hc.get("zone_place")}
        new_c = e["outcome"] == "COMPLETE"
        e["drift"] = None if h is None else (
            "easy_kept" if h["class"] == "easy" and new_c else
            "easy_lost" if h["class"] == "easy" else
            "hard_now_complete" if new_c else "hard_kept")
    os.makedirs(out, exist_ok=True)
    json.dump({"schema": "zrv-b0-episodes/1", "episodes": eps}, open(os.path.join(out, "b0_episodes.json"), "w"),
              indent=1, sort_keys=True)
    cols = ["model", "case", "seed", "zone_seed", "outcome", "unknown_cause", "terminal_reason", "closed", "total", "iter",
            "elapsed_s", "cpu_s", "rc", "t0_captured", "t0_iter", "certification", "zone_solver_denied", "zone_solver_exempt",
            "zone_ladder_fired", "zone_ladder_skipped", "zone_decisions_non_noop", "hist_class", "hist_a2_class", "drift"]
    with open(os.path.join(out, "b0_episodes.tsv"), "w") as f:
        f.write("\t".join(cols + ["prefix_init_fp_eq", "prefix_ood_fp_eq", "prefix_zone_place_eq", "hist_flags"]) + "\n")
        for e in eps:
            p = e["prefix_vs_hist"] or {}
            f.write("\t".join(str(e.get(c)) for c in cols) + "\t" +
                    "\t".join(str(p.get(k)) for k in ("init_fp", "ood_fp", "zone_place")) + "\t" +
                    ",".join(e["hist_flags"] or []) + "\n")
    # 요약
    cells = defaultdict(Counter)
    for e in eps:
        c = cells["%s|%s" % (e["model"], e["case"])]
        c["planned"] += 1
        c["scored"] += e["outcome"] != "UNKNOWN"
        c[e["outcome"]] += 1
        if e["outcome"] == "UNKNOWN":
            c["UNKNOWN:" + str(e["unknown_cause"])] += 1
        c["missing"] += e["unknown_cause"] == "missing"
        c["t0_captured"] += bool(e["t0_captured"])
        c["certification_available"] += e["certification"] == "available"
    drift2x2 = Counter((e["hist_class"], e["outcome"] == "COMPLETE") for e in eps)
    summ = {"schema": "zrv-b0-summary/1", "n_planned": len(eps), "cells": {k: dict(v) for k, v in sorted(cells.items())},
            "totals": dict(Counter(e["outcome"] for e in eps)),
            "unknown_causes": dict(Counter(e["unknown_cause"] for e in eps if e["unknown_cause"])),
            "drift_2x2": {"%s|new_%s" % (h, "COMPLETE" if c else "not_complete"): n for (h, c), n in sorted(drift2x2.items(), key=str)},
            "easy_lost": sorted(e["run_key"].replace("canonical__", e["model"] + "__") for e in eps if e["drift"] == "easy_lost"),
            "hard_now_complete": sorted(e["run_key"].replace("canonical__", e["model"] + "__") for e in eps if e["drift"] == "hard_now_complete"),
            "zone_ladder_fired_total": sum(e.get("zone_ladder_fired") or 0 for e in eps),
            "zone_solver_denied_total": sum(e.get("zone_solver_denied") or 0 for e in eps),
            "zone_solver_exempt_total": sum(e.get("zone_solver_exempt") or 0 for e in eps),
            "zone_decisions_non_noop_total": sum(e.get("zone_decisions_non_noop") or 0 for e in eps),
            "episodes_without_ablation_line": sorted(e["run_key"] + "@" + e["model"] for e in eps if not e.get("ablation")),
            "t0_captured": sum(bool(e["t0_captured"]) for e in eps),
            "certification_available": sum(e["certification"] == "available" for e in eps),
            "certification_gap_reasons": dict(Counter(g for e in eps for g in (e["certification_gaps"] or []))),
            "budget_violations": sum(bool(e["budget_violations"]) for e in eps),
            "manifest_build_mismatches": dict(Counter(",".join(e["manifest_build_mismatches"]) if e["manifest_build_mismatches"] is not None else "not_checked" for e in eps)),
            "rng_advanced_after_t0": sum(bool(e["rng_advanced_after_t0"]) for e in eps),
            "score_disagrees": sorted(e["run_key"] + "@" + e["model"] for e in eps if e["score_agrees"] is False),
            "recovery_totals": dict(sum((Counter(e["recovery_counts"] or {}) for e in eps), Counter())),
            "prefix_vs_hist": {k: dict(Counter(str((e["prefix_vs_hist"] or {}).get(k)) for e in eps)) for k in ("init_fp", "ood_fp", "zone_place")}}
    json.dump(summ, open(os.path.join(out, "b0_summary.json"), "w"), indent=1, sort_keys=True)
    print(json.dumps({k: summ[k] for k in ("n_planned", "totals", "unknown_causes", "drift_2x2", "t0_captured",
                                           "zone_ladder_fired_total", "zone_solver_denied_total")}, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:3])
