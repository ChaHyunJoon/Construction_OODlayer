"""온라인 판의 버전 고정 (plan Task 18, spec §5.2, §5.4 규칙 5, §0.0 R8)."""
import json, os
import pytest
from tools.selfimprove import online, paths, probe, versions

@pytest.fixture
def exp(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    os.makedirs(paths.state_dir("e"))
    json.dump({"port_base": 8100, "models": ["tractor", "xwing"], "zone_cases": ["zone", "all3"],
               "harvest_seed0": 1001, "online_workers": 2},
              open(os.path.join(paths.state_dir("e"), "config.json"), "w"))
    rev, dirty = online.code_identity()
    f = dict(exp="e", version="v0", parent=None, a0_sha256="a", library_head="a", active_artifacts=[],
             surro_tau=0.7, surro_rule="deadband_Jbar", feature_schema_sha256=probe.feature_schema_sha256(),
             objective_hash="o", psi_table_sha256="p", label_engine="gen_oracle", vocab="v4-3arms",
             code_rev=rev, code_dirty_digest=dirty, model_probe_sha256="m", cycle=None)
    versions.write_version("e", f, paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.write_version("e", dict(f, version="v1", parent="v0"), paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.activate("e", "v0")
    yield "e"
    for root, dirs, files in os.walk(tmp_path):
        os.chmod(root, 0o755)

def test_run_env_is_pinned_at_launch(exp):
    a = online.launch_env(exp)
    versions.activate(exp, "v1")
    assert a["SELFIMPROVE_VERSION"] == "v0" and a["DSPY_URL"].endswith(":8100")
    assert a["SELFIMPROVE_MANIFEST_SHA"] == versions.sha256_file(
        os.path.join(paths.version_dir(exp, "v0"), "manifest.json"))
    assert online.launch_env(exp)["SELFIMPROVE_VERSION"] == "v1"

def test_code_drift_refuses_to_launch(exp, monkeypatch):
    monkeypatch.setattr(online, "code_identity", lambda: ("deadbeef", "other"))
    with pytest.raises(RuntimeError):
        online.launch_env(exp)

def test_feature_schema_drift_refuses_to_launch(exp, monkeypatch):
    monkeypatch.setattr(probe, "feature_schema_sha256", lambda: "changed")
    with pytest.raises(RuntimeError):
        online.launch_env(exp)

def test_schedule_round_robin_and_seed_sequence(exp):
    got = online.schedule(exp, 5)
    assert got == [("tractor", "zone", 1001), ("tractor", "all3", 1002), ("xwing", "zone", 1003),
                   ("xwing", "all3", 1004), ("tractor", "zone", 1005)]
    assert online.schedule(exp, 1) == [("tractor", "all3", 1006)]        # 이어서 (영속)
