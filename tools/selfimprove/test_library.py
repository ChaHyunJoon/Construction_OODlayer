# tools/selfimprove/test_library.py
import json, pytest
from tools.selfimprove import library

@pytest.fixture(autouse=True)
def roots(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "data"))

ARM = {"impl_code": "function f!(env) end", "calls": [], "params": {}, "surface": "geom",
       "reversible": False}

def test_artifact_hash_sensitive_to_calls_and_surface():
    a = library.artifact_hash(ARM)
    assert a != library.artifact_hash(dict(ARM, surface="sched"))
    assert a != library.artifact_hash(dict(ARM, calls=[{"primitive": "f!", "args": {"k": 1}}]))

def test_approve_is_idempotent_per_cycle_and_assigns_stable_ids():
    e = {"artifact_sha256": "x"}
    a = library.approve("t", "c0", e, "A0")
    again = library.approve("t", "c0", e, "A0")
    assert again == a and a["arm_id"] == 100 and len(library.read("t")) == 1
    b = library.approve("t", "c1", {"artifact_sha256": "y"}, "A0")
    assert b["arm_id"] == 101 and b["prev_hash"] == a["hash"]
    with pytest.raises(ValueError):
        library.approve("t", "c2", {"artifact_sha256": "x"}, "A0")
    assert library.verify_chain("t", "A0") == []

def test_tamper_breaks_chain():
    library.approve("t", "c0", {"artifact_sha256": "x"}, "A0")
    p = library._path("t")
    rows = [json.loads(l) for l in open(p)]
    rows[0]["artifact_sha256"] = "evil"
    open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
    assert library.verify_chain("t", "A0")
