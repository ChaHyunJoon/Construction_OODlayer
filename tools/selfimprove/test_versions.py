# tools/selfimprove/test_versions.py
import os, pytest
from tools.selfimprove import versions, paths

FIELDS = dict(exp="t", version="v0", parent=None, a0_sha256="a0", library_head="a0",
              active_artifacts=[], surro_tau=0.7, surro_rule="deadband_Jbar",
              feature_schema_sha256="f", objective_hash="o", psi_table_sha256="s",
              label_engine="gen_oracle", vocab="v4-3arms", code_rev="deadbeef",
              code_dirty_digest="x", model_probe_sha256="p", cycle=None)

@pytest.fixture
def roots(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "data"))
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "state"))
    reg = tmp_path / "reg.json"; reg.write_text('{"vocab":"v4-3arms","macros":{}}')
    ds = tmp_path / "ds.jsonl"; ds.write_text('{"a":1}\n')
    yield str(reg), str(ds)
    for root, dirs, files in os.walk(tmp_path):       # 불변 디렉터리를 tmp 정리가 지울 수 있게
        os.chmod(root, 0o755)

def test_write_verify_activate(roots):
    reg, ds = roots
    msha = versions.write_version("t", FIELDS, reg, ds, [], {})
    assert versions.verify_version("t", "v0") == []
    versions.activate("t", "v0")
    assert versions.read_current("t") == ("v0", msha)
    assert versions.status("t", "v0") == "activated"

def test_missing_policy_identity_field_rejected(roots):
    reg, ds = roots
    bad = {k: v for k, v in FIELDS.items() if k != "surro_rule"}
    with pytest.raises(ValueError):
        versions.write_version("t", bad, reg, ds, [], {})

def test_immutable_and_tamper_detected(roots):
    reg, ds = roots
    versions.write_version("t", FIELDS, reg, ds, [], {})
    with pytest.raises(FileExistsError):
        versions.write_version("t", FIELDS, reg, ds, [], {})
    p = os.path.join(paths.version_dir("t", "v0"), "dataset.jsonl")
    os.chmod(p, 0o644); open(p, "a").write("x")
    assert any("dataset" in s for s in versions.verify_version("t", "v0"))
    with pytest.raises(RuntimeError):
        versions.activate("t", "v0")

def test_lineage_and_rollback(roots):
    reg, ds = roots
    versions.write_version("t", FIELDS, reg, ds, [], {})
    versions.write_version("t", dict(FIELDS, version="v1", parent="v0"), reg, ds, [], {})
    assert versions.lineage("t", "v1") == ["v1", "v0"]
    assert versions.next_version("t") == "v2"
    versions.activate("t", "v1"); versions.rollback("t", "v0")
    assert versions.read_current("t")[0] == "v0"
    assert versions.status("t", "v1") == "rolled_back"
