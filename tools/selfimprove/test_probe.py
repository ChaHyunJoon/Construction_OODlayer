# tools/selfimprove/test_probe.py
from tools.selfimprove import probe, paths

def test_probe_is_deterministic_on_a0():
    a = probe.fit_probe(paths.A0_DATASET, paths.A0_REGISTRY)
    b = probe.fit_probe(paths.A0_DATASET, paths.A0_REGISTRY)
    assert a["probe_sha256"] == b["probe_sha256"]
    assert a["surro_kinds"] == ["battery", "fault"] and a["surro_support"] == [0, 1, 2]
    assert a["n_rows"] == 33 and a["objective_hash"]

def test_feature_schema_sha_is_stable():
    assert probe.feature_schema_sha256() == probe.feature_schema_sha256()
