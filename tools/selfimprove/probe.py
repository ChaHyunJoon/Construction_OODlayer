"""하위 프로세스에서 surrogate 를 적합해 탐침 sha 를 잰다 (레지스트리가 import 시점에 읽히므로)."""
import hashlib, json, os, subprocess, sys
from . import paths

_SCRIPT = r'''
import json, sys
sys.path[:0] = ["src/decision/core", "src/decision/surrogate", "src/decision"]
from eval_surrogate_v2 import load_rows
from surrogate_v2 import SurrogateV2
from surrogate_probe import probe_sha256
rows, meta = load_rows(sys.argv[1])
m = SurrogateV2().fit(rows)
print("@@PROBE@@" + json.dumps({"probe_sha256": probe_sha256(m, rows),
    "surro_kinds": sorted({r["kind"] for r in rows}),
    "surro_support": sorted({int(r["macro"]) for r in rows}), "n_rows": len(rows),
    "objective_hash": meta["objective_hash"]}))
'''

def fit_probe(dataset, registry):
    env = dict(os.environ, ACTION_REGISTRY=os.path.abspath(registry))
    out = subprocess.run([sys.executable, "-c", _SCRIPT, os.path.abspath(dataset)],
                         cwd=paths.ROOT, env=env, capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if line.startswith("@@PROBE@@"):
            return json.loads(line[len("@@PROBE@@"):])
    raise RuntimeError("probe failed rc=%d: %s" % (out.returncode, out.stderr[-2000:]))

def feature_schema_sha256():
    h = hashlib.sha256()
    for p in paths.FEATURE_SCHEMA_FILES:
        h.update(open(p, "rb").read())
    return h.hexdigest()
