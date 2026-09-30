"""검토 묶음과 결정 (plan Task 14, spec §10)."""
import json, os
import pytest
from tools.selfimprove import review, paths

BODY = {"record_id": "r1", "impl_name": "f!", "impl_code": "function f!(env)\n translate_whole_build!(env)\nend\n",
        "calls": [{"primitive": "f!", "args": {}}], "params": {}, "surface": "sched", "reversible": False,
        "logged_at": "2026-09-23T08:00:00", "run_ctx": {"campaign_id": "cc", "run_id": "rr"}}

@pytest.fixture
def cyc(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    d = os.path.join(paths.state_dir("e"), "cycles", "c0")
    os.makedirs(os.path.join(d, "s1"))
    json.dump({"state": "AWAITING_REVIEW", "behavior_key": "zone|translate_whole_build!", "track": "add",
               "incumbent_arm_id": None, "candidate_artifact": "art"}, open(os.path.join(d, "cycle.json"), "w"))
    json.dump({"body": BODY, "members": [{"q_id": "cc/rr", "impl_name": "f!"}, {"q_id": "cc/r2", "impl_name": "g!"}],
               "arm": {"impl_name": "cand_c0_f!", "impl_code": BODY["impl_code"].replace("f!(", "cand_c0_f!("),
                       "artifact_sha256": "art", "source_impl_code_sha256": "x"}},
              open(os.path.join(d, "candidate.json"), "w"))
    json.dump({"ok": True, "hard": [], "soft": ["numeric_literal_ge_1"]}, open(os.path.join(d, "s0.json"), "w"))
    json.dump({"pass": True, "why": []}, open(os.path.join(d, "s1", "report.json"), "w"))
    json.dump({"criteria": {"C5_causal": {"b": 9, "c": 0, "p": 0.002, "pass": True}, "all_pass": True},
               "instances": {"tractor|zone|s101": {"complete": True, "fail_mode": None}}},
              open(os.path.join(d, "s3_summary.json"), "w"))
    os.makedirs(os.path.join(paths.data_dir("e"), "psi"))
    return d

def test_packet_has_the_sections(cyc):
    txt = open(review.write_packet("e", "c0")).read()
    for s in ("translate_whole_build!", "cc/rr", "numeric_literal_ge_1", "C5_causal",
              "인과 증거가 아니다", "track", "body", "sha256"):
        assert s in txt, s

def test_decision_schema_and_immutable(cyc):
    json.dump({"translate_whole_build!": [1, 1, 0, 0, 1, 1, 0, 0, 3]},
              open(os.path.join(paths.data_dir("e"), "psi", "base_psi.json"), "w"))
    p = review.record_decision("e", "c0", "approve", "chahj578", "ok", "yes", "none", "yes", [])
    d = json.load(open(p))
    assert d["decision"] == "approve" and d["reviewer"] == "chahj578" and d["decided_at"]
    with pytest.raises(FileExistsError):
        review.record_decision("e", "c0", "reject", "x", "y", "no", "none", "no", [])

def test_approve_refused_when_called_function_has_no_psi_row(cyc):
    json.dump({}, open(os.path.join(paths.data_dir("e"), "psi", "base_psi.json"), "w"))
    with pytest.raises(ValueError):
        review.record_decision("e", "c0", "approve", "r", "ok", "yes", "none", "yes", [])
    with pytest.raises(ValueError):                   # 주장만 하고 표에는 안 넣은 경우도 거부
        review.record_decision("e", "c0", "approve", "r", "ok", "yes", "none", "yes", ["translate_whole_build!"])
    assert review.record_decision("e", "c0", "reject", "r", "no psi", "yes", "none", "yes", [])
