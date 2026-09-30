"""서비스 수명·배포·롤백 (plan Task 17, spec §5.1, §5.4). 가짜 /health 는 http.server 자식 프로세스."""
import json, os, socket, sys
import pytest
from tools.selfimprove import paths, service, versions

sys.path.insert(0, os.path.join(paths.ROOT, "src", "respec", "llm_service"))
import generation  # noqa: E402

FAKE = r'''
import http.server, json, sys
body = sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
'''

def _port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

@pytest.fixture
def exp(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    os.makedirs(paths.state_dir("e"))
    json.dump({"port_base": 8100, "tau": 0.7, "surro_rule": "deadband_Jbar"},
              open(os.path.join(paths.state_dir("e"), "config.json"), "w"))
    f = dict(exp="e", version="v0", parent=None, a0_sha256="a", library_head="a", active_artifacts=[],
             surro_tau=0.7, surro_rule="deadband_Jbar", feature_schema_sha256="f", objective_hash="o",
             psi_table_sha256="p", label_engine="gen_oracle", vocab="v4-3arms", code_rev="r",
             code_dirty_digest="d", model_probe_sha256="m", cycle=None)
    versions.write_version("e", f, paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.activate("e", "v0")
    versions.write_version("e", dict(f, version="v1", parent="v0"), paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    yield "e"
    for root, dirs, files in os.walk(tmp_path):
        os.chmod(root, 0o755)

def _health(exp, v, **over):
    h = {"agent_version": v, "surro_tau": 0.7, "surro_rule": "deadband_Jbar",
         "manifest_sha256": versions.sha256_file(os.path.join(paths.version_dir(exp, v), "manifest.json")),
         "code_fingerprint": generation.code_fingerprint(service.SERVICE_DIR),
         "synth_tool_synthesis": True, "synth_multi_agent": True}
    h.update(over)
    return h

def _fake(h):
    return lambda port: [sys.executable, "-c", FAKE, str(port), json.dumps(h)]

def test_start_accepts_matching_identity_and_env(exp):
    p = _port()
    got = service.start(exp, "v1", port=p, cmd=_fake(_health(exp, "v1")), wait_s=20)
    try:
        assert got["port"] == p and got["pid"] > 0
        env = service.service_env(exp, "v1")
        vd = paths.version_dir(exp, "v1")
        assert env["ACTION_REGISTRY"] == os.path.join(vd, "action_registry.json")
        assert env["SURRO_DATA"] == os.path.join(vd, "dataset.jsonl") and env["SURRO_TAU"] == "0.7"
        assert env["SELFIMPROVE_MANIFEST"] == os.path.join(vd, "manifest.json") and env["DSPY_CACHE"] == "0"
        assert env["TOOL_SYNTHESIS"] == "1" and env["SYNTH_MULTI_AGENT"] == "1"
        assert env["SYNTH_RECORD_LOG"] == service.ledger_path(exp, "v1")
    finally:
        service.stop(got["pid"])

@pytest.mark.parametrize("over", [{"manifest_sha256": "0" * 64}, {"surro_tau": 0.0}, {"agent_version": "v0"},
                                  {"synth_multi_agent": False}])
def test_start_refuses_identity_mismatch_and_pointer_is_unchanged(exp, over):
    before = versions.read_current(exp)
    with pytest.raises(RuntimeError):
        service.start(exp, "v1", port=_port(), cmd=_fake(_health(exp, "v1", **over)), wait_s=20)
    assert versions.read_current(exp) == before

def test_deploy_requires_a_passing_d_gate_record(exp):
    with pytest.raises(RuntimeError):
        service.deploy(exp, "v1", cmd=_fake(_health(exp, "v1")))
    d = os.path.join(paths.state_dir(exp), "dev", "v1"); os.makedirs(d)
    json.dump({"all_pass": False, "manifest_sha256": _health(exp, "v1")["manifest_sha256"]}, open(os.path.join(d, "gate.json"), "w"))
    with pytest.raises(RuntimeError):
        service.deploy(exp, "v1", cmd=_fake(_health(exp, "v1")))
    assert versions.read_current(exp)[0] == "v0"

def test_deploy_then_rollback(exp):
    d = os.path.join(paths.state_dir(exp), "dev", "v1"); os.makedirs(d)
    json.dump({"all_pass": True, "manifest_sha256": _health(exp, "v1")["manifest_sha256"]}, open(os.path.join(d, "gate.json"), "w"))
    h = service.deploy(exp, "v1", port=_port(), cmd=_fake(_health(exp, "v1")))
    try:
        assert versions.read_current(exp)[0] == "v1" and versions.status(exp, "v0") == "draining"
        assert json.load(open(os.path.join(paths.state_dir(exp), "services.json")))["v1"]["port"] == h["port"]
    finally:
        service.stop(h["pid"])
    versions.rollback(exp, "v0")
    assert versions.read_current(exp)[0] == "v0" and versions.status(exp, "v1") == "rolled_back"
