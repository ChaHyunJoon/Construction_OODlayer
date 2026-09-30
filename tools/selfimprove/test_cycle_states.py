"""회전 상태 기계 (plan Task 18, spec §4.2, §0.0 R2·R9). 외부 호출은 가짜 Ops 주입."""
import json, os
import pytest
from tools.selfimprove import cycle, paths, versions

BODY = {"record_id": "r1", "row_type": "decide", "impl_name": "relocate!",
        "impl_code": "function relocate!(env)\n    translate_whole_build!(env)\nend\n",
        "calls": [{"primitive": "relocate!", "args": {}}], "params": {}, "surface": "sched",
        "reversible": False, "body_names": ["relocate!"], "run_ctx": {"campaign_id": "cc", "run_id": "rr"}}
REP = {"q_id": "cc/rr", "model": "tractor", "case": "zone", "seed": 1001, "artifact_sha256": "art"}

def _run(ok):
    return {"complete": ok, "stratum": "tractor|zone", "fail_mode": None, "rc": 0,
            "inv": {"I1": "ok", "I1b": "ok", "I2": "ok", "I3": 0, "I4": 1.0},
            "libarm": [{"execution_ok": True, "wall_s": 1.0}]}

class FakeOps:
    def __init__(self, t_ok=True, gate_ok=True):
        self.calls, self.t_ok, self.gate_ok = [], t_ok, gate_ok
    def panel(self, role, arm_path, arm_sha):
        self.calls.append(role)
        ok = {"noop": False, "candidate": self.t_ok, "null": False}[role]
        return {"tractor|zone|s%d" % s: _run(ok) for s in range(101, 121)}
    def s1(self, c, path, sha, src):
        self.calls.append("s1"); return {"pass": True, "why": []}
    def record(self, c):
        self.calls.append("record"); return {"arm_id": 100}
    def build_version(self, c, panels):
        self.calls.append("build"); return "v1"
    def gate(self, v):
        self.calls.append("gate"); return {"all_pass": self.gate_ok}
    def deploy(self, v):
        self.calls.append("deploy")

@pytest.fixture
def exp(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    os.makedirs(paths.state_dir("e"))
    json.dump({"tau": 0.7}, open(os.path.join(paths.state_dir("e"), "config.json"), "w"))
    os.makedirs(os.path.join(paths.data_dir("e"), "psi"))
    json.dump({"translate_whole_build!": [1, 1, 0, 0, 1, 1, 0, 0, 3]},
              open(os.path.join(paths.data_dir("e"), "psi", "base_psi.json"), "w"))
    cycle.open_cycle("e", "c0", BODY, REP, [REP], "zone|translate_whole_build!", "add", None, 3, "v0")
    return "e"

def _state(exp, c="c0"):
    return json.load(open(os.path.join(paths.state_dir(exp), "cycles", c, "cycle.json")))

def test_happy_path_stops_for_review_then_deploys(exp):
    ops = FakeOps()
    cycle.run(exp, "c0", ops=ops)
    assert _state(exp)["state"] == "AWAITING_REVIEW" and ops.calls == ["s1", "noop", "candidate", "null"]
    assert os.path.exists(os.path.join(paths.state_dir(exp), "cycles", "c0", "review", "packet.md"))
    from tools.selfimprove import review
    review.record_decision(exp, "c0", "approve", "t", "e2e", "yes", "none", "yes", [])
    cycle.run(exp, "c0", from_stage="APPROVED", ops=ops)
    assert _state(exp)["state"] == "DEPLOYED" and ops.calls[-4:] == ["record", "build", "gate", "deploy"]

def test_s3_t_failure_rejects_and_never_runs_null(exp):
    ops = FakeOps(t_ok=False)
    cycle.run(exp, "c0", ops=ops)
    st = _state(exp)
    assert st["state"] == "REJECTED" and st["reject"]["stage"] == "S3_T" and "null" not in ops.calls

def test_d_gate_failure_keeps_version_built_and_pointer(exp):
    ops = FakeOps(gate_ok=False)
    cycle.run(exp, "c0", ops=ops)
    from tools.selfimprove import review
    review.record_decision(exp, "c0", "approve", "t", "e2e", "yes", "none", "yes", [])
    cycle.run(exp, "c0", from_stage="APPROVED", ops=ops)
    st = _state(exp)
    assert st["state"] == "REJECTED" and st["reject"]["stage"] == "D" and st["version_built"] == "v1"
    assert "deploy" not in ops.calls

def test_from_refuses_when_inputs_changed(exp):
    cycle.run(exp, "c0", ops=FakeOps())
    p = os.path.join(paths.state_dir(exp), "cycles", "c0", "s3_summary.json")
    d = json.load(open(p)); d["tampered"] = True; json.dump(d, open(p, "w"))
    from tools.selfimprove import review
    review.record_decision(exp, "c0", "approve", "t", "e2e", "yes", "none", "yes", [])
    with pytest.raises(RuntimeError):
        cycle.run(exp, "c0", from_stage="APPROVED", ops=FakeOps())

def test_reviewer_rejection_is_recorded(exp):
    cycle.run(exp, "c0", ops=FakeOps())
    from tools.selfimprove import review
    review.record_decision(exp, "c0", "reject", "t", "unrealistic", "no", "none", "yes", [])
    cycle.run(exp, "c0", from_stage="APPROVED", ops=FakeOps())
    assert _state(exp)["reject"]["stage"] == "S4"

def test_one_cycle_at_a_time(exp):
    with cycle.lock(exp):
        with pytest.raises(RuntimeError):
            with cycle.lock(exp):
                pass


def test_watch_tick_opens_a_cycle_from_three_completions(tmp_path, monkeypatch):
    from tools.selfimprove import watch, harvest
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s2"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d2"))
    sd = paths.state_dir("w"); os.makedirs(sd)
    json.dump({"m": 3}, open(os.path.join(sd, "config.json"), "w"))
    f = dict(exp="w", version="v0", parent=None, a0_sha256="a", library_head="a", active_artifacts=[],
             surro_tau=0.7, surro_rule="r", feature_schema_sha256="f", objective_hash="o", psi_table_sha256="p",
             label_engine="gen_oracle", vocab="v4-3arms", code_rev="r", code_dirty_digest="d",
             model_probe_sha256="m", cycle=None)
    versions.write_version("w", f, paths.A0_REGISTRY, paths.A0_DATASET, [], {}); versions.activate("w", "v0")
    for i in range(3):
        b = dict(BODY, record_id="r%d" % i, impl_code=BODY["impl_code"] + "#" * i)
        harvest.save_body("w", b)
        with open(os.path.join(sd, "queue.jsonl"), "a") as q:
            q.write(json.dumps(dict(REP, q_id="cc/%d" % i, lane="dspy", complete=True,
                                    artifact_sha256=harvest.artifact_of(b),
                                    behavior_key="zone|translate_whole_build!")) + "\n")
    assert watch.tick("w", run_cycle=False) == "c0"
    st = json.load(open(os.path.join(sd, "cycles", "c0", "cycle.json")))
    assert st["state"] == "TRIGGERED" and st["queue_pos"] == 3 and st["parent_version"] == "v0"
    assert watch.tick("w", run_cycle=False) is None                     # 같은 키는 진행 중 → 재트리거 없음
    for root, dirs, files in os.walk(tmp_path):
        os.chmod(root, 0o755)
