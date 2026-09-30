"""승인된 artifact 의 append-only 원장 + 해시 사슬 (spec §11.1, §0.0 R6·R9).

원장은 "승인됨"만 기록한다. 어느 버전에서 활성인지는 manifest 의 active_artifacts 가 정한다."""
import json, os
from . import paths
from .versions import canonical, sha256_bytes

def artifact_hash(a):
    return sha256_bytes(canonical({"schema": "arm-v1", "impl_code": a["impl_code"],
                                   "calls": a["calls"], "params": a["params"],
                                   "surface": a["surface"],
                                   "reversible": bool(a["reversible"])}).encode())

def _path(exp):
    return os.path.join(paths.data_dir(exp), "library", "library.jsonl")

def read(exp):
    p = _path(exp)
    return [json.loads(l) for l in open(p, encoding="utf-8")] if os.path.exists(p) else []

def _hash(row):
    body = {k: v for k, v in row.items() if k != "hash"}
    return sha256_bytes((row["prev_hash"] + canonical(body)).encode())

def head(exp, a0_sha):
    rows = read(exp)
    return rows[-1]["hash"] if rows else a0_sha

def approve(exp, cycle_id, entry, a0_sha):
    """멱등: 같은 cycle_id 면 그 행을 돌려준다. arm_id 는 승인 시점에 고정된다."""
    rows = read(exp)
    for r in rows:
        if r["cycle"] == cycle_id:
            return r
        if r["artifact_sha256"] == entry["artifact_sha256"]:
            raise ValueError("artifact %s already approved in %s" % (r["artifact_sha256"], r["cycle"]))
    row = dict(entry, cycle=cycle_id, arm_id=100 + len(rows))
    row.pop("hash", None)
    row["prev_hash"] = rows[-1]["hash"] if rows else a0_sha
    row["hash"] = _hash(row)
    os.makedirs(os.path.dirname(_path(exp)), exist_ok=True)
    with open(_path(exp), "a", encoding="utf-8") as f:
        f.write(canonical(row) + "\n")
    return row

def verify_chain(exp, a0_sha):
    probs, prev = [], a0_sha
    for i, r in enumerate(read(exp)):
        if r["prev_hash"] != prev:
            probs.append("row %d prev_hash break" % i)
        if _hash(r) != r["hash"]:
            probs.append("row %d hash mismatch" % i)
        prev = r["hash"]
    return probs

def write_source(exp, arm_id, impl_name, impl_code, header_lines):
    d = os.path.join(paths.data_dir(exp), "library", "arms")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "m%d_%s.jl" % (arm_id, impl_name.rstrip("!")))
    with open(p, "w", encoding="utf-8") as f:
        f.write("".join("# %s\n" % h for h in header_lines) + impl_code)
    return p
