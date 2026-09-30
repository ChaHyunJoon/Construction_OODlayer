"""불변 버전 디렉터리 (spec §5.4, §0.0 R8). 버전의 신원 = manifest.json 바이트의 sha256."""
import datetime, getpass, hashlib, json, os, re, shutil
from . import paths

REQUIRED = ("exp", "version", "parent", "a0_sha256", "library_head", "active_artifacts",
            "surro_tau", "surro_rule", "feature_schema_sha256", "objective_hash",
            "psi_table_sha256", "label_engine", "vocab", "code_rev", "code_dirty_digest",
            "model_probe_sha256", "cycle")

def canonical(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))

def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()

def sha256_file(p):
    with open(p, "rb") as f:
        return sha256_bytes(f.read())

def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def _index_path(exp):
    return os.path.join(paths.data_dir(exp), "versions", "index.jsonl")

def append_index(exp, v, event, msha):
    os.makedirs(os.path.dirname(_index_path(exp)), exist_ok=True)
    with open(_index_path(exp), "a", encoding="utf-8") as f:
        f.write(canonical({"version": v, "event": event, "at": _now(),
                           "by": getpass.getuser(), "manifest_sha256": msha}) + "\n")

def _freeze(d):
    for root, _, files in os.walk(d):
        for n in files:
            os.chmod(os.path.join(root, n), 0o444)
    for root, _, _ in os.walk(d, topdown=False):
        os.chmod(root, 0o555)

def write_version(exp, fields, registry_src, dataset_src, arms, extra_files):
    """arms: 활성 팔 arm.json dict 목록. extra_files: {"psi_table.json": src_path, ...}."""
    missing = [k for k in REQUIRED if k not in fields]
    if missing:
        raise ValueError("manifest fields missing: %s" % missing)
    v = fields["version"]
    d = paths.version_dir(exp, v)
    if os.path.exists(d):
        raise FileExistsError("version %s already exists — versions are immutable" % v)
    os.makedirs(os.path.join(d, "arms"))
    shutil.copyfile(registry_src, os.path.join(d, "action_registry.json"))
    shutil.copyfile(dataset_src, os.path.join(d, "dataset.jsonl"))
    files = {}
    for name, src in extra_files.items():
        shutil.copyfile(src, os.path.join(d, name))
        files[name] = sha256_file(os.path.join(d, name))
    arm_meta = []
    for a in arms:
        p = os.path.join(d, "arms", "m%d.json" % a["arm_id"])
        with open(p, "w", encoding="utf-8") as f:
            f.write(canonical(a))
        arm_meta.append({"arm_id": a["arm_id"], "arm_json_sha256": sha256_file(p),
                         "artifact_sha256": a["artifact_sha256"]})
    m = dict(fields)
    m.update(registry_sha256=sha256_file(os.path.join(d, "action_registry.json")),
             dataset_sha256=sha256_file(os.path.join(d, "dataset.jsonl")),
             files=files, arms=sorted(arm_meta, key=lambda x: x["arm_id"]),
             created_at=fields.get("created_at") or _now())
    raw = canonical(m).encode()
    with open(os.path.join(d, "manifest.json"), "wb") as f:
        f.write(raw)
    msha = sha256_bytes(raw)
    with open(os.path.join(d, "manifest.sha256"), "w") as f:
        f.write(msha + "\n")
    _freeze(d)
    append_index(exp, v, "built", msha)
    return msha

def load_manifest(exp, v):
    with open(os.path.join(paths.version_dir(exp, v), "manifest.json"), "rb") as f:
        return json.loads(f.read())

def verify_version(exp, v):
    d = paths.version_dir(exp, v)
    if not os.path.isdir(d):
        return ["missing version dir %s" % d]
    probs = []
    if open(os.path.join(d, "manifest.sha256")).read().strip() != \
            sha256_file(os.path.join(d, "manifest.json")):
        probs.append("manifest.sha256 mismatch")
    m = load_manifest(exp, v)
    if sha256_file(os.path.join(d, "action_registry.json")) != m["registry_sha256"]:
        probs.append("registry sha mismatch")
    if sha256_file(os.path.join(d, "dataset.jsonl")) != m["dataset_sha256"]:
        probs.append("dataset sha mismatch")
    for name, s in m["files"].items():
        if sha256_file(os.path.join(d, name)) != s:
            probs.append("%s sha mismatch" % name)
    want = {"m%d.json" % a["arm_id"]: a["arm_json_sha256"] for a in m["arms"]}
    have = sorted(os.listdir(os.path.join(d, "arms")))
    if sorted(want) != have:
        probs.append("arms/ file set %s != manifest %s" % (have, sorted(want)))
    for n, s in want.items():
        p = os.path.join(d, "arms", n)
        if os.path.exists(p) and sha256_file(p) != s:
            probs.append("arm %s sha mismatch" % n)
    return probs

def status(exp, v):
    st = None
    if os.path.exists(_index_path(exp)):
        for line in open(_index_path(exp), encoding="utf-8"):
            r = json.loads(line)
            if r["version"] == v:
                st = r["event"]
    return st

def _pointer(exp):
    return os.path.join(paths.state_dir(exp), "current_version")

def read_current(exp):
    v, sha = open(_pointer(exp)).read().split()
    return v, sha

def _write_pointer(exp, v):
    probs = verify_version(exp, v)
    if probs:
        raise RuntimeError("refusing to point at %s: %s" % (v, probs))
    msha = sha256_file(os.path.join(paths.version_dir(exp, v), "manifest.json"))
    os.makedirs(paths.state_dir(exp), exist_ok=True)
    tmp = _pointer(exp) + ".tmp"
    with open(tmp, "w") as f:
        f.write("%s %s\n" % (v, msha))
    os.replace(tmp, _pointer(exp))
    return msha

def activate(exp, v):
    append_index(exp, v, "activated", _write_pointer(exp, v))

def rollback(exp, to_v):
    cur, csha = read_current(exp)
    msha = _write_pointer(exp, to_v)
    append_index(exp, cur, "rolled_back", csha)
    append_index(exp, to_v, "activated", msha)

def lineage(exp, v):
    out = []
    while v is not None:
        out.append(v)
        v = load_manifest(exp, v)["parent"]
    return out

def next_version(exp):
    d = os.path.join(paths.data_dir(exp), "versions")
    ks = [int(m.group(1)) for n in (os.listdir(d) if os.path.isdir(d) else [])
          for m in [re.fullmatch(r"v(\d+)", n)] if m]
    return "v%d" % (max(ks) + 1 if ks else 0)
