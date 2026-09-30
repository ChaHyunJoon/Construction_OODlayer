"""승인 → artifact 기록 → 버전 빌드 (plan Task 15, spec §11, §0.0 R9·R10)."""
import copy, hashlib, json, os
import pytest
from tools.selfimprove import paths, versions, library, promote, refit, rows as rowsmod, review

CODE = "function relocate!(env)\n    translate_whole_build!(env)\n    return nothing\nend\n"
BODY = {"record_id": "r1", "row_type": "decide", "impl_name": "relocate!", "impl_code": CODE,
        "calls": [{"primitive": "relocate!", "args": {}}], "params": {}, "surface": "sched",
        "reversible": False, "body_names": ["relocate!"], "logged_at": "2026-09-23T08:00:00",
        "response_id": "resp", "parent_record_id": None,
        "run_ctx": {"campaign_id": "cc", "run_id": "rr"}}
PSI_ROW = [1.5, 1, 0, 0, 1, 1, 0, 0, 3]


@pytest.fixture
def exp(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "s"))
    monkeypatch.setenv("SELFIMPROVE_DATA_ROOT", str(tmp_path / "d"))
    os.makedirs(paths.state_dir("e"))
    cfg = {"tau": 0.7, "surro_rule": "deadband_Jbar", "a0_sha256": versions.sha256_file(paths.A0_REGISTRY)}
    json.dump(cfg, open(os.path.join(paths.state_dir("e"), "config.json"), "w"))
    os.makedirs(os.path.join(paths.data_dir("e"), "psi"))
    json.dump({"translate_whole_build!": PSI_ROW}, open(os.path.join(paths.data_dir("e"), "psi", "base_psi.json"), "w"))
    f = dict(exp="e", version="v0", parent=None, a0_sha256=cfg["a0_sha256"], library_head=cfg["a0_sha256"],
             active_artifacts=[], surro_tau=0.7, surro_rule="deadband_Jbar", feature_schema_sha256="f",
             objective_hash="o", psi_table_sha256="p", label_engine="gen_oracle", vocab="v4-3arms",
             code_rev="r", code_dirty_digest="d", model_probe_sha256="m", cycle=None)
    versions.write_version("e", f, paths.A0_REGISTRY, paths.A0_DATASET, [],
                           {"psi_table.json": os.path.join(paths.data_dir("e"), "psi", "base_psi.json")})
    versions.activate("e", "v0")
    yield "e"
    for root, dirs, files in os.walk(tmp_path):
        os.chmod(root, 0o755)


def _cycle(exp, c, track="add", incumbent=None, key="zone|translate_whole_build!", body=BODY):
    d = os.path.join(paths.state_dir(exp), "cycles", c)
    os.makedirs(os.path.join(d, "review"), exist_ok=True)
    json.dump({"state": "APPROVED", "behavior_key": key, "track": track, "incumbent_arm_id": incumbent,
               "parent_version": "v0"}, open(os.path.join(d, "cycle.json"), "w"))
    json.dump({"body": body, "representative": {"llm_model": ["gpt-5.6-sol"]}, "members": []},
              open(os.path.join(d, "candidate.json"), "w"))
    json.dump({"criteria": {"all_pass": True}}, open(os.path.join(d, "s3_summary.json"), "w"))
    review.record_decision(exp, c, "approve", "test", "e2e", "yes", "none", "yes", [])


def test_record_artifact_is_idempotent_and_source_copy_matches(exp):
    _cycle(exp, "c0")
    a = promote.record_artifact(exp, "c0")
    b = promote.record_artifact(exp, "c0")
    assert a == b and a["arm_id"] == 100 and len(library.read(exp)) == 1
    assert a["psi"]["a_cost"] == 1.5 and a["behavior_key"] == "zone|translate_whole_build!"
    src = open(os.path.join(paths.data_dir(exp), "library", "arms", "m100_relocate.jl")).read()
    body = "".join(l for l in src.splitlines(True) if not l.startswith("# "))
    assert hashlib.sha256(body.encode()).hexdigest() == a["impl_code_sha256"]


def test_registry_for_vocab_and_zone_menu(exp):
    _cycle(exp, "c0"); promote.record_artifact(exp, "c0")
    active = promote.next_active_set(exp, "v0", "c0")
    reg = promote.registry_for(active)
    assert reg["vocab"] == "v5-4arms" and reg["macros"]["100"]["name"] == "m100_relocate!"
    assert reg["macros"]["100"]["library_arm"] == 100 and reg["macros"]["100"]["cost"] == 1.5
    assert "zone" in reg["macros"]["0"]["kinds"]
    assert json.load(open(paths.A0_REGISTRY))["vocab"] == "v4-3arms"            # A₀ 는 그대로


def test_replace_track_drops_incumbent_only_in_the_version(exp):
    _cycle(exp, "c0"); promote.record_artifact(exp, "c0")
    active1 = promote.next_active_set(exp, "v0", "c0")
    b2 = dict(BODY, impl_code=CODE.replace("return nothing", "return 1"), record_id="r2")
    _cycle(exp, "c1", track="replace", incumbent=100, body=b2); promote.record_artifact(exp, "c1")
    versions.write_version(exp, dict(versions.load_manifest(exp, "v0"), version="v1", parent="v0",
                                     active_artifacts=[{"arm_id": 100}]),
                           paths.A0_REGISTRY, paths.A0_DATASET, active1, {})
    active2 = promote.next_active_set(exp, "v1", "c1")
    assert [a["arm_id"] for a in active2] == [101]
    assert [r["arm_id"] for r in library.read(exp)] == [100, 101]


def test_g3_rejects_identical_psi(exp):
    a = {"arm_id": 100, "psi": {"a_cost": 1.0}}
    assert not promote.g3_psi_distinct([a, dict(a, arm_id=101)])
    assert promote.g3_psi_distinct([a, {"arm_id": 101, "psi": {"a_cost": 2.0}}])


def _zone_run(ood, complete):
    feat = rowsmod.features(ood)
    desc = rowsmod.descriptors(feat)
    return {"complete": complete, "closed": 300 if complete else 200, "n_total": 305, "sim_seconds": 30.0,
            "total_energy_J": 1e5,
            "decisions_raw": [{"input": {"router": {"ood_features": dict(ood), "valid_menu": [],
                                                    "descriptors": desc}}}]}


def _panels(n=12):
    noop, arm = {}, {}
    for s in range(n):
        ood = {"kind": "zone", "severity": 0.3 + 0.01 * s, "zone_overlap": 0.2, "agent_pending": -1,
               "n_active": 18, "spare_count": 8, "closed_at_fire": 50 + s, "total_nodes": 305,
               "progress": 0.17, "zone_nav_blocked": 2, "zone_nav_downstream": 100 + s}
        noop["tractor|zone|s%d" % (101 + s)] = _zone_run(ood, False)
        arm["tractor|zone|s%d" % (101 + s)] = _zone_run(ood, True)
    return {0: noop, 100: arm}


def _a0_render(exp):
    rs = [json.loads(l) for l in open(paths.A0_DATASET)]
    p = os.path.join(paths.data_dir(exp), "labels", "a0_render.jsonl")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("".join(json.dumps(dict(r, label_engine="render")) + "\n" for r in rs))
    return p


def test_assemble_render_only_no_null_rows(exp):
    _cycle(exp, "c0"); promote.record_artifact(exp, "c0")
    active = promote.next_active_set(exp, "v0", "c0")
    stamps = refit.stamps_for(active)
    a0 = [json.loads(l) for l in open(_a0_render(exp))]
    out = refit.assemble_rows(a0, _panels(), [100], stamps)
    assert all(r["label_engine"] == "render" and r["vocab"] == "v5-4arms" for r in out)
    assert all(r["train_kinds"] == "battery,fault,zone" for r in out)
    assert {r["macro"] for r in out if r["kind"] == "zone"} == {0, 100}
    with pytest.raises(ValueError):                                     # gen_oracle 행 혼합 금지
        refit.assemble_rows([dict(a0[0], label_engine="gen_oracle")], _panels(), [100], stamps)
    bad = _panels(); bad[100]["tractor|zone|s101"]["decisions_raw"][0]["input"]["router"]["descriptors"][0] += 1
    with pytest.raises(ValueError):                                     # 변환 동등성 위반
        refit.assemble_rows(a0, bad, [100], stamps)


def test_build_version_verifies_and_failure_keeps_arm_id(exp):
    _cycle(exp, "c0")
    _a0_render(exp)
    with pytest.raises(RuntimeError):                                   # zone 라벨이 없으면 F2 실패
        refit.build_version(exp, "c0", {0: {}, 100: {}}, code_rev="r", dirty="d")
    assert [r["arm_id"] for r in library.read(exp)] == [100]
    assert not os.path.exists(paths.version_dir(exp, "v1"))
    v = refit.build_version(exp, "c0", _panels(), code_rev="r", dirty="d")
    assert v == "v1" and versions.verify_version(exp, "v1") == []
    m = versions.load_manifest(exp, "v1")
    assert m["label_engine"] == "render" and m["parent"] == "v0" and m["vocab"] == "v5-4arms"
    assert m["active_artifacts"] == [{"arm_id": 100, "artifact_sha256": library.read(exp)[0]["artifact_sha256"]}]
    assert [r["arm_id"] for r in library.read(exp)] == [100]
