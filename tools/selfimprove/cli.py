"""selfimprove CLI (spec §4.1). 레포 루트에서 `python -m tools.selfimprove <cmd>`."""
import argparse, json, os, subprocess, sys
from . import paths, versions, probe

sys.path.insert(0, os.path.join(paths.ROOT, "tools", "monitor", "grid"))
import campaign  # noqa: E402  (tree_digest)

CONFIG_DEFAULTS = {"tau": 0.7, "m": 3, "surro_rule": "deadband_Jbar",
                   "gate_seeds": list(range(101, 116)), "dev_seeds": list(range(301, 316)),
                   "eval_seeds_locked": list(range(201, 231)), "harvest_seed0": 1001,
                   "models": ["tractor", "xwing"], "zone_cases": ["zone", "all3"],
                   "a0_cases": ["fault", "battery"], "online_workers": 8,
                   "offline_workers": 8, "port_base": 8100, "llm_model": "gpt-5.6-sol"}

def _git(*a):
    return subprocess.run(["git", *a], cwd=paths.ROOT, capture_output=True, text=True).stdout.strip()

def psi_table_path(exp):
    return os.path.join(paths.data_dir(exp), "psi", "base_psi.json")

def load_config(exp):
    with open(os.path.join(paths.state_dir(exp), "config.json")) as f:
        return json.load(f)

def cmd_init(exp):
    sd = paths.state_dir(exp)
    if os.path.exists(os.path.join(sd, "config.json")):
        raise SystemExit("experiment %s already initialised" % exp)
    os.makedirs(sd, exist_ok=True)
    cfg = dict(CONFIG_DEFAULTS, exp=exp,
               a0_sha256=versions.sha256_file(paths.A0_REGISTRY),
               world_interface_sha256=versions.sha256_file(paths.WORLD_INTERFACE))
    with open(os.path.join(sd, "config.json"), "w") as f:
        json.dump(cfg, f, indent=1)
    os.makedirs(os.path.dirname(psi_table_path(exp)), exist_ok=True)
    if not os.path.exists(psi_table_path(exp)):
        with open(psi_table_path(exp), "w") as f:
            f.write("{}\n")
    pr = probe.fit_probe(paths.A0_DATASET, paths.A0_REGISTRY)
    versions.write_version(exp, dict(
        exp=exp, version="v0", parent=None, a0_sha256=cfg["a0_sha256"],
        library_head=cfg["a0_sha256"], active_artifacts=[], surro_tau=cfg["tau"],
        surro_rule=cfg["surro_rule"], feature_schema_sha256=probe.feature_schema_sha256(),
        objective_hash=pr["objective_hash"],
        psi_table_sha256=versions.sha256_file(psi_table_path(exp)), label_engine="gen_oracle",
        vocab="v4-3arms", code_rev=_git("rev-parse", "HEAD"),
        code_dirty_digest=campaign.tree_digest(paths.ROOT),
        model_probe_sha256=pr["probe_sha256"], cycle=None),
        paths.A0_REGISTRY, paths.A0_DATASET, [], {"psi_table.json": psi_table_path(exp)})
    versions.activate(exp, "v0")
    print("[selfimprove] %s initialised at v0" % exp)

def cmd_status(exp):
    from . import library, watch
    v, sha = versions.read_current(exp)
    q = watch._jsonl(os.path.join(paths.state_dir(exp), "queue.jsonl"))
    print(json.dumps({"current": v, "manifest_sha256": sha, "status": versions.status(exp, v),
                      "queue": len(q), "queue_dspy_complete": sum(1 for r in q if r.get("lane") == "dspy" and r.get("complete")),
                      "cycles": {c["cycle"]: c["state"] for c in watch._cycles(exp)},
                      "library": [r["arm_id"] for r in library.read(exp)]}, indent=1, ensure_ascii=False))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="selfimprove")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("init", "watch", "status", "verify", "verify-chain", "deploy", "rollback", "online", "cycle", "review",
                 "serve", "drain"):
        p = sub.add_parser(name)
        p.add_argument("--exp", required=True)
        if name == "watch":
            p.add_argument("--poll-s", type=int, default=60); p.add_argument("--once", action="store_true")
        if name == "online":
            p.add_argument("--n", type=int, default=None)
        if name in ("verify", "deploy", "serve", "drain"):
            p.add_argument("--version", required=(name != "verify"))
        if name == "serve":
            p.add_argument("--port", type=int, default=None)
        if name == "rollback":
            p.add_argument("--to", required=True)
        if name == "cycle":
            p.add_argument("c"); p.add_argument("--from", dest="from_stage")
            p.add_argument("--reopen", action="store_true", help="re-run a REJECTED cycle (recorded in history)")
        if name == "review":
            p.add_argument("c"); g = p.add_mutually_exclusive_group(required=True)
            g.add_argument("--approve", action="store_true"); g.add_argument("--reject", action="store_true")
            p.add_argument("--reviewer", required=True); p.add_argument("--reason", required=True)
            p.add_argument("--R1", default="yes"); p.add_argument("--R2", default="none"); p.add_argument("--R3", default="yes")
            p.add_argument("--psi-rows-added", nargs="*", default=[])
    a = ap.parse_args(argv)
    if a.cmd == "init":
        cmd_init(a.exp)
    elif a.cmd == "status":
        cmd_status(a.exp)
    elif a.cmd == "verify":
        v = a.version or versions.read_current(a.exp)[0]
        probs = versions.verify_version(a.exp, v)
        print(json.dumps({"version": v, "problems": probs})); sys.exit(1 if probs else 0)
    elif a.cmd == "verify-chain":
        from . import library
        probs = library.verify_chain(a.exp, load_config(a.exp)["a0_sha256"])
        print(json.dumps({"problems": probs})); sys.exit(1 if probs else 0)
    elif a.cmd == "deploy":
        from . import service
        print(json.dumps(service.deploy(a.exp, a.version)))
    elif a.cmd == "rollback":
        versions.rollback(a.exp, a.to); print("[selfimprove] pointer -> %s" % a.to)
    elif a.cmd == "online":
        from . import online
        online.run(a.exp, a.n)
    elif a.cmd == "watch":
        from . import watch
        watch.run(a.exp, a.poll_s, a.once)
    elif a.cmd == "cycle":
        from . import cycle
        cycle.run(a.exp, a.c, a.from_stage, reopen=a.reopen)
    elif a.cmd == "serve":
        from . import service
        print(json.dumps(service.start(a.exp, a.version, port=a.port)))
    elif a.cmd == "drain":
        from . import service
        ok = service.drain_and_stop(a.exp, a.version)
        print("[selfimprove] drain %s: %s" % (a.version, "stopped" if ok else "runs in flight — not stopped"))
    elif a.cmd == "review":
        from . import review
        print(review.record_decision(a.exp, a.c, "approve" if a.approve else "reject", a.reviewer, a.reason,
                                     a.R1, a.R2, a.R3, a.psi_rows_added))
