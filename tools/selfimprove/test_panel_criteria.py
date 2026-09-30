"""S3 판정 (plan Task 13, spec §9.4, §0.0 R1·R7)."""
import os
from tools.selfimprove import panel

INV_OK = {"I1": "ok", "I1b": "ok", "I2": "ok", "I3": 0, "I4": 1.0}

def run(complete, stratum="tractor|zone", fail_mode=None, inv=None, libarm=None, rc=0):
    return {"complete": complete, "stratum": stratum, "fail_mode": fail_mode, "rc": rc,
            "inv": dict(inv or INV_OK), "libarm": libarm if libarm is not None else
            [{"execution_ok": True, "wall_s": 2.0}]}

def arms(n, noop_ok, t_ok, **kw):
    noop = {i: run(i in noop_ok) for i in range(n)}
    t = {i: run(i in t_ok, **kw) for i in range(n)}
    return noop, t

def test_denominator_is_all_noop_failures_even_when_t_deadlocks():            # R1
    noop = {i: run(False) for i in range(60)}
    t = {i: run(i >= 40, fail_mode=None if i >= 40 else "world_deadlock") for i in range(60)}
    c = panel.criteria(noop, t, None, None, 0.7)
    assert c["C3_rescue"]["n"] == 60 and c["C3_rescue"]["k"] == 20
    assert c["C3_rescue"]["aux_world_deadlock"] == 40 and not c["C3_rescue"]["pass"]

def test_harm_fails_c4():
    noop, t = arms(10, noop_ok={0, 1}, t_ok=set(range(1, 10)))
    c = panel.criteria(noop, t, None, None, 0.0)
    assert not c["C4_harm"]["pass"] and c["C4_harm"]["n_harm"] == 1 and c["C4_harm"]["of"] == 2

def test_one_i1_violation_fails_c1():
    noop, t = arms(10, noop_ok=set(), t_ok=set(range(10)))
    t[3]["inv"]["I1"] = "fail:missing:x"
    assert not panel.criteria(noop, t, None, None, 0.0)["C1_honest"]["pass"]

def test_execution_not_ok_fails_c2():
    noop, t = arms(10, noop_ok=set(), t_ok=set(range(10)))
    t[5]["libarm"] = [{"execution_ok": False, "wall_s": 1.0}]
    assert not panel.criteria(noop, t, None, None, 0.0)["C2_sound"]["pass"]
    noop, t = arms(10, noop_ok=set(), t_ok=set(range(10)))
    t[2]["rc"] = 124
    assert not panel.criteria(noop, t, None, None, 0.0)["C2_sound"]["pass"]

def test_all_pass_with_null_control():
    noop, t = arms(20, noop_ok=set(), t_ok=set(range(20)))
    tnull = {i: run(False) for i in range(20)}
    c = panel.criteria(noop, t, tnull, None, 0.7)
    assert c["C5_causal"]["pass"] and c["all_pass"]

def test_worse_than_incumbent_fails_c7():
    noop, t = arms(20, noop_ok=set(), t_ok=set(range(15)))
    inc = {i: run(True) for i in range(20)}
    tnull = {i: run(False) for i in range(20)}
    c = panel.criteria(noop, t, tnull, inc, 0.0)
    assert not c["C7_beats_incumbent"]["pass"] and not c["all_pass"]

def test_strata_rule():
    noop = {i: run(False, stratum="x|zone" if i < 5 else "t|zone") for i in range(10)}
    t = {i: run(i >= 5, stratum="x|zone" if i < 5 else "t|zone") for i in range(10)}
    c = panel.criteria(noop, t, None, None, 0.0)
    assert c["C6_strata"]["by"]["x|zone"] == 0.0 and not c["C6_strata"]["pass"]

def test_cycle_paths_differ_and_noop_cache_is_shared(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path))
    assert panel.arm_dir("e", "c0", "candidate") != panel.arm_dir("e", "c1", "candidate")
    k = panel.cache_key("rev", "dirty", {"a": 1}, [101], ["tractor"], ["zone"])
    assert panel.cache_dir("e", "noop", k) == panel.cache_dir("e", "noop", k)
    assert k != panel.cache_key("rev", "dirty2", {"a": 1}, [101], ["tractor"], ["zone"])
    assert os.path.basename(panel.arm_dir("e", "c0", "candidate")) == "candidate"

def test_unmeasured_lists_missing_runs_and_missing_invariant_lines():
    noop = {i: run(False) for i in range(3)}
    t = {0: run(True), 1: dict(run(True), inv=None)}
    assert panel.unmeasured(noop, t) == [1, 2]

def test_run_arm_env_pins_forced_arm_and_drops_service(tmp_path, monkeypatch):
    monkeypatch.setenv("DSPY_URL", "http://127.0.0.1:8077")
    seen = []
    grids = panel.run_arm("e", str(tmp_path / "g"), "arm.json", "sha", [101, 102], ["tractor", "xwing"],
                          ["zone", "all3"], 4, runner=lambda argv, env: seen.append((argv, env)))
    assert [m for m, _ in grids] == ["tractor", "xwing"] and len(seen) == 2
    argv, env = seen[0]
    assert argv[-4:] == ["canonical", "zone all3", "101 102", "4"]
    assert env["SELFIMPROVE_ARM"] == os.path.abspath("arm.json") and env["SELFIMPROVE_ARM_SHA"] == "sha"
    assert "DSPY_URL" not in env and env["DEMO_MODEL"] == "tractor.mpd"
    panel.run_arm("e", str(tmp_path / "n"), None, None, [101], ["tractor"], ["zone"], 1,
                  runner=lambda argv, env: seen.append((argv, env)))
    assert "SELFIMPROVE_ARM" not in seen[-1][1]                        # NOOP 팔
