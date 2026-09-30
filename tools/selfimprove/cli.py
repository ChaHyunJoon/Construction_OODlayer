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

def main(argv=None):
    ap = argparse.ArgumentParser(prog="selfimprove")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init"); p.add_argument("--exp", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "init":
        cmd_init(a.exp)
