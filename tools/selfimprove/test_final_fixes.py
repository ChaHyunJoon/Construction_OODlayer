"""최종 리뷰 수정 (Critical 1 · Important 2–5). 각 시험은 수정 전에 빨갛다."""
import json, os
import pytest
from tools.selfimprove import cli, cycle, paths, review, service, versions, watch, harvest
from tools.selfimprove.test_cycle_states import BODY, REP, FakeOps

F = dict(exp="e", version="v0", parent=None, a0_sha256="a", library_head="a", active_artifacts=[],
         surro_tau=0.7, surro_rule="deadband_Jbar", feature_schema_sha256="f", objective_hash="o",
         psi_table_sha256="p", label_engine="gen_oracle", vocab="v4-3arms", code_rev="r",
         code_dirty_digest="d", model_probe_sha256="m", cycle=None)


@pytest.fixture
def exp(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    os.makedirs(paths.state_dir("e"))
    json.dump({"tau": 0.7, "m": 3, "port_base": 8100}, open(os.path.join(paths.state_dir("e"), "config.json"), "w"))
    os.makedirs(os.path.join(paths.data_dir("e"), "psi"))
    json.dump({"translate_whole_build!": [1, 1, 0, 0, 1, 1, 0, 0, 3]},
              open(os.path.join(paths.data_dir("e"), "psi", "base_psi.json"), "w"))
    versions.write_version("e", F, paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.activate("e", "v0")
    yield "e"
    for root, dirs, files in os.walk(tmp_path):
        os.chmod(root, 0o755)


def _state(exp, c="c0"):
    return json.load(open(os.path.join(paths.state_dir(exp), "cycles", c, "cycle.json")))


# ---- Critical 1: 두 회전이 동시에 열려 낡은 부모에서 빌드된다 --------------------------------
def test_watch_does_not_open_a_second_cycle_while_one_is_open(exp):
    for key, n in (("zone|translate_whole_build!", 0), ("zone|restage_all_blocked!", 10)):
        for i in range(3):
            b = dict(BODY, record_id="r%d" % (n + i), impl_code=BODY["impl_code"] + "#" * (n + i))
            harvest.save_body(exp, b)
            with open(os.path.join(paths.state_dir(exp), "queue.jsonl"), "a") as q:
                q.write(json.dumps(dict(REP, q_id="cc/%d" % (n + i), lane="dspy", complete=True,
                                        artifact_sha256=harvest.artifact_of(b), behavior_key=key)) + "\n")
    assert watch.tick(exp, run_cycle=False) == "c0"
    assert watch.tick(exp, run_cycle=False) is None                  # c0 가 끝날 때까지 다른 키도 대기


def test_deploy_refuses_a_version_whose_parent_is_not_current(exp):
    versions.write_version(exp, dict(F, version="v1", parent="v0"), paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.write_version(exp, dict(F, version="v2", parent="v0"), paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    versions.activate(exp, "v1")
    d = os.path.join(paths.state_dir(exp), "dev", "v2"); os.makedirs(d)
    json.dump({"all_pass": True, "manifest_sha256": versions.sha256_file(
        os.path.join(paths.version_dir(exp, "v2"), "manifest.json"))}, open(os.path.join(d, "gate.json"), "w"))
    with pytest.raises(RuntimeError, match="parent"):
        service.deploy(exp, "v2", cmd=lambda p: ["true"])
    assert versions.read_current(exp)[0] == "v1"


def test_build_parent_is_the_current_pointer_not_the_trigger_time_parent(exp, monkeypatch):
    from tools.selfimprove import refit
    versions.write_version(exp, dict(F, version="v1", parent="v0"), paths.A0_REGISTRY, paths.A0_DATASET, [], {})
    cycle.open_cycle(exp, "c0", BODY, REP, [REP], "zone|translate_whole_build!", "add", None, 3, "v0")
    versions.activate(exp, "v1")
    seen = {}
    monkeypatch.setattr(refit.promote, "record_artifact", lambda e, c: {"arm_id": 100})
    monkeypatch.setattr(refit.promote, "next_active_set", lambda e, p, c: seen.setdefault("parent", p) and [])
    monkeypatch.setattr(refit.promote, "g3_psi_distinct", lambda a: False)      # 여기서 멈춘다
    json.dump({"tau": 0.7, "a0_sha256": "a"}, open(os.path.join(paths.state_dir(exp), "config.json"), "w"))
    with pytest.raises(RuntimeError):
        refit.build_version(exp, "c0", {})
    assert seen["parent"] == "v1" and _state(exp)["parent_version"] == "v1"


# ---- Important 2: D 게이트가 살아 있는 버전의 services.json 을 덮는다 --------------------------
def test_gate_service_start_does_not_register(exp, monkeypatch):
    sp = os.path.join(paths.state_dir(exp), "services.json")
    json.dump({"v0": {"port": 8100, "pid": 1}}, open(sp, "w"))
    monkeypatch.setattr(service, "identity_problems", lambda e, v, h: [])
    monkeypatch.setattr(service, "_get", lambda url: {})
    import sys
    h = service.start(exp, "v0", port=9999, cmd=lambda p: [sys.executable, "-c", "import time; time.sleep(30)"],
                      register=False)
    service.stop(h["pid"])
    assert json.load(open(sp))["v0"] == {"port": 8100, "pid": 1}


# ---- Important 3: part B 재개가 버전을 다시 빌드하거나 D_PASS 에서 막힌다 ------------------------
def _to_review(exp):
    cycle.open_cycle(exp, "c0", BODY, REP, [REP], "zone|translate_whole_build!", "add", None, 3, "v0")
    cycle.run(exp, "c0", ops=FakeOps())
    review.record_decision(exp, "c0", "approve", "t", "e2e", "yes", "none", "yes", [])


class GateCrash(FakeOps):
    def gate(self, v):
        self.calls.append("gate"); raise RuntimeError("service died")


def test_resume_after_build_reuses_the_version(exp):
    _to_review(exp)
    with pytest.raises(RuntimeError):
        cycle.run(exp, "c0", from_stage="APPROVED", ops=GateCrash())
    assert _state(exp)["state"] == "VERSION_BUILT"
    ops = FakeOps()
    cycle.run(exp, "c0", from_stage="APPROVED", ops=ops)
    assert "build" not in ops.calls and "record" not in ops.calls and _state(exp)["state"] == "DEPLOYED"


class DeployCrash(FakeOps):
    def deploy(self, v):
        self.calls.append("deploy"); raise RuntimeError("port busy")


def test_resume_from_d_pass_only_deploys(exp):
    _to_review(exp)
    with pytest.raises(RuntimeError):
        cycle.run(exp, "c0", from_stage="APPROVED", ops=DeployCrash())
    assert _state(exp)["state"] == "D_PASS"
    ops = FakeOps()
    cycle.run(exp, "c0", from_stage="APPROVED", ops=ops)
    assert ops.calls == ["deploy"] and _state(exp)["state"] == "DEPLOYED"


# ---- Important 4: part A 상태 가드 · 결정이 증거에 묶이지 않음 -----------------------------------
def test_rejected_cycle_needs_explicit_reopen(exp):
    cycle.open_cycle(exp, "c0", BODY, REP, [REP], "zone|translate_whole_build!", "add", None, 3, "v0")
    cycle.run(exp, "c0", ops=FakeOps(t_ok=False))
    with pytest.raises(RuntimeError, match="reopen"):
        cycle.run(exp, "c0", from_stage="S3_T", ops=FakeOps())
    cycle.run(exp, "c0", from_stage="S3_T", ops=FakeOps(), reopen=True)
    st = _state(exp)
    assert st["state"] == "AWAITING_REVIEW" and "reject" not in st
    assert any(h.get("reopened_from", {}).get("stage") == "S3_T" for h in st["history"])


def test_part_a_refused_once_a_decision_exists(exp):
    _to_review(exp)
    with pytest.raises(RuntimeError):
        cycle.run(exp, "c0", from_stage="S3_T", ops=FakeOps(), reopen=True)


def test_decision_is_bound_to_the_evidence_it_approved(exp):
    _to_review(exp)
    d = json.load(open(os.path.join(paths.state_dir(exp), "cycles", "c0", "review", "decision.json")))
    assert d["s3_summary_sha256"] and d["packet_sha256"]
    p = os.path.join(paths.state_dir(exp), "cycles", "c0", "review", "packet.md")
    open(p, "a").write("\nedited after the decision\n")
    with pytest.raises(RuntimeError):
        cycle.run(exp, "c0", from_stage="APPROVED", ops=FakeOps())


# ---- Important 5: 버전 서비스를 띄우고 배수할 길 ------------------------------------------------
def test_cli_serve_and_drain(exp, monkeypatch):
    seen = []
    monkeypatch.setattr(service, "start", lambda e, v, port=None, **k: seen.append(("start", v)) or {"port": 1, "pid": 2})
    monkeypatch.setattr(service, "drain_and_stop", lambda e, v: seen.append(("drain", v)) or True)
    cli.main(["serve", "--exp", exp, "--version", "v0"])
    cli.main(["drain", "--exp", exp, "--version", "v0"])
    assert seen == [("start", "v0"), ("drain", "v0")]
