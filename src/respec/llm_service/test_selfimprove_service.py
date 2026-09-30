"""selfimprove 조건 ②③ (spec §5.3, §0.0 R2). 레포 루트에서 돌린다."""
import sys
import pytest

@pytest.fixture
def svc(monkeypatch):
    monkeypatch.setenv("SYNTH_RECORD_LOG", "0")
    sys.path.insert(0, "src/respec/llm_service")
    import dspy_service as s
    monkeypatch.setattr(s, "_surro_row", lambda req, m: {"macro": m, "instance": "live"})
    return s

class FakeModel:
    """팔 id → P̂. choose 는 비용이 가장 싼(=id 가 큰) 팔을 고르는 흉내."""
    def __init__(self, p): self.p = p
    def predict_complete_proba(self, rows): return [self.p[int(r["macro"])] for r in rows]
    def choose(self, rows, rule): return {"live": max(int(r["macro"]) for r in rows)}
    def predict_delta_J(self, rows, ref_macro=0): return [0.0 for _ in rows]

def _setup(svc, monkeypatch, p, tau):
    monkeypatch.setattr(svc, "SURRO_TAU", tau)
    monkeypatch.setitem(svc._state, "surrogate", FakeModel(p))
    monkeypatch.setitem(svc._state, "surro_support", {0, 1, 2})

def test_no_arm_defers(svc, monkeypatch):
    _setup(svc, monkeypatch, {0: 0.99}, 0.7)
    scored, err = svc.surrogate_rank(svc.MacroRequest(kind="zone", valid=["NOOP"]), ["NOOP"])
    assert scored is None and err == "DEFER:no_arm"

def test_selection_restricted_to_arms_above_tau(svc, monkeypatch):
    # 검토 2 의 반례: NOOP 0.701, 다른 팔 0.695 → 규칙이 싼 팔을 고르면 안 된다
    _setup(svc, monkeypatch, {0: 0.701, 1: 0.695}, 0.7)
    scored, err = svc.surrogate_rank(svc.MacroRequest(kind="fault", valid=["NOOP", "Replace"]),
                                     ["NOOP", "Replace"])
    assert err is None and scored[0][0] == "NOOP"
    assert [s[0] for s in scored] == ["NOOP"] and scored[0][2] == pytest.approx(0.701)

def test_all_below_tau_defers(svc, monkeypatch):
    _setup(svc, monkeypatch, {0: 0.2, 1: 0.4}, 0.7)
    _, err = svc.surrogate_rank(svc.MacroRequest(kind="fault", valid=["NOOP", "Replace"]),
                                ["NOOP", "Replace"])
    assert err == "DEFER:low_confidence:0.4000"

def test_tau_zero_is_v0_behaviour(svc, monkeypatch):
    _setup(svc, monkeypatch, {0: 0.01, 1: 0.02}, 0.0)
    scored, err = svc.surrogate_rank(svc.MacroRequest(kind="fault", valid=["NOOP", "Replace"]),
                                     ["NOOP", "Replace"])
    assert scored is not None and err is None

def test_tau_zero_keeps_noop_only_menu_as_noop(svc, monkeypatch):
    # v0(τ=0) 에서는 조건 ② 도 꺼진다: 합법이 {NOOP} 뿐이면 NOOP 이 정직한 답(기존 규약)
    _setup(svc, monkeypatch, {0: 0.99}, 0.0)
    scored, err = svc.surrogate_rank(svc.MacroRequest(kind="fault", valid=["NOOP"]), ["NOOP"])
    assert err is None and scored[0][0] == "NOOP"


class ProbeModel(FakeModel):
    def predict_J(self, rows): return [1.0 for _ in rows]

def _manifest(tmp_path, monkeypatch, svc, **over):
    import hashlib, json
    ds = tmp_path / "dataset.jsonl"; ds.write_text("{}\n")
    reg = tmp_path / "reg.json"; reg.write_text("{}")
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    import surrogate_probe
    rows = [{"macro": 0}]
    m = dict(version="v1", dataset_sha256=sha(ds), registry_sha256=sha(reg), surro_tau=0.7,
             surro_rule="deadband_Jbar", objective_hash="o",
             model_probe_sha256=surrogate_probe.probe_sha256(ProbeModel({0: 0.5}), rows))
    m.update(over)
    man = tmp_path / "manifest.json"; man.write_bytes(json.dumps(m).encode())
    (tmp_path / "manifest.sha256").write_text(hashlib.sha256(man.read_bytes()).hexdigest() + "\n")
    monkeypatch.setenv("SELFIMPROVE_MANIFEST", str(man))
    monkeypatch.setenv("ACTION_REGISTRY", str(reg))
    monkeypatch.setattr(svc, "SURRO_DATA", str(ds))
    monkeypatch.setattr(svc, "SURRO_TAU", 0.7)
    monkeypatch.setattr(svc, "SURRO_RULE", "deadband_Jbar")
    return rows

def test_manifest_identity_match_sets_health_fields(svc, monkeypatch, tmp_path):
    sys.path.insert(0, "src/decision/surrogate")
    rows = _manifest(tmp_path, monkeypatch, svc)
    monkeypatch.setattr(svc, "_state", dict(svc._state))
    svc._check_selfimprove_manifest(ProbeModel({0: 0.5}), rows, {"objective_hash": "o"})
    assert svc._state["agent_version"] == "v1" and svc._state["manifest_sha256"]

def test_manifest_identity_mismatch_raises(svc, monkeypatch, tmp_path):
    sys.path.insert(0, "src/decision/surrogate")
    rows = _manifest(tmp_path, monkeypatch, svc, surro_tau=0.5)
    with pytest.raises(RuntimeError, match=r"\[selfimprove\].*surro_tau"):
        svc._check_selfimprove_manifest(ProbeModel({0: 0.5}), rows, {"objective_hash": "o"})
    with pytest.raises(RuntimeError, match="model_probe"):
        svc._check_selfimprove_manifest(ProbeModel({0: 0.9}), rows, {"objective_hash": "o"})
