"""수확: 실행된 body 만, artifact 신원 (plan Task 10, spec §6, §0.0 R6·R7). 레포 루트에서."""
import copy, json, os
import pytest
from tools.selfimprove import harvest, library

FX = json.load(open(os.path.join(os.path.dirname(__file__), "fixtures", "sol_all3_s10.json")))
CID, RID = FX["decide"]["run_ctx"]["campaign_id"], FX["decide"]["run_ctx"]["run_id"]
NAMES = {"translate_whole_build!", "restage_all_blocked!", "active_restriction_zones"}

def test_behavior_key():
    code = "function f!(env)\n  zs = active_restriction_zones()\n  g(x) = x\n  CB.translate_whole_build!(env)\n  g(1)\nend"
    assert harvest.behavior_key(code, "zone", NAMES) == "zone|active_restriction_zones,translate_whole_build!"
    assert harvest.behavior_key("function h!(env) x = 1 end", "zone", NAMES) == "zone|∅"
    # 부분 이름 일치는 세지 않는다 (my_translate_whole_build!( 은 다른 함수다)
    assert harvest.behavior_key("my_translate_whole_build!(env)", "zone", NAMES) == "zone|∅"

def _ledger():
    return [copy.deepcopy(FX["decide"]), copy.deepcopy(FX["rewrite"])]

def test_reenacted_rewrite_is_the_executed_body():                                     # (c)
    row = harvest.executed_body(_ledger(), CID, RID, FX["decision"])
    assert row["record_id"] == FX["rewrite"]["record_id"] and row["row_type"] == "rewrite"

def test_install_rejected_rewrite_is_never_the_body():                                  # (b)
    dec = copy.deepcopy(FX["decision"])
    for a in dec["attempts"]:
        a["install_why"] = "reject:impl_name_exists_withheld"; a["steps"] = None; a["steps_ref"] = None
    row = harvest.executed_body(_ledger(), CID, RID, dec)
    assert row["record_id"] == FX["decide"]["record_id"]          # decide body 는 실제로 굴렀다(steps 있음)
    dec["steps"] = []                                             # decide body 도 안 굴렀으면
    assert harvest.executed_body(_ledger(), CID, RID, dec) is None

def test_other_campaign_same_run_id_does_not_match():                                   # (d)
    assert harvest.executed_body(_ledger(), "other-campaign", RID, FX["decision"]) is None

def test_same_code_different_args_are_different_artifacts(tmp_path, monkeypatch):      # (e)
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path))
    a = copy.deepcopy(FX["rewrite"]); b = copy.deepcopy(FX["rewrite"])
    a["calls"] = [{"primitive": a["impl_name"], "args": {"k": 1}}]
    b["calls"] = [{"primitive": b["impl_name"], "args": {"k": 2}}]
    sa, sb = harvest.artifact_of(a), harvest.artifact_of(b)
    assert sa != sb
    pa, pb = harvest.save_body("t", a), harvest.save_body("t", b)
    assert pa != pb and os.path.exists(pa) and os.path.exists(pb)
    assert sa == library.artifact_hash(harvest.arm_like(a))

def test_llm_cost_and_model_sum_over_the_runs_rows():
    cost, models = harvest.llm_cost(_ledger(), CID, RID)
    assert cost > 0.15 and models == ["gpt-5.6-sol"]

def test_rewrite_outcome_is_what_attempt_counts_counts():
    import sys
    sys.path.insert(0, "tools/monitor")
    import build_sweep_dataset as bsd
    oc = bsd.rewrite_outcome(FX["decision"])
    assert [o["installed"] for o in oc] == [True] and oc[0]["record_id"] == FX["rewrite"]["record_id"]
    assert bsd.attempt_counts([FX["decision"]])["rewrite_installed"] == 1


def _grid(tmp_path, decision, complete=True):
    """render 판 하나 모양의 최소 그리드(log · jobs · runs · stream)."""
    g = tmp_path / "grid"; (g / "log").mkdir(parents=True); (g / "streams").mkdir()
    rk = RID
    ctx = {"campaign_id": CID, "run_id": RID, "model": "tractor", "agent_version": "v0"}
    (g / "log" / (rk + ".log")).write_text(
        "[run-ctx] %s\n n_total: 305\n[minted] lane=present tool=T verdict=admit applied=n/a\n"
        "[score] complete=%s closed=287 n_zones=1 n_blocked=0 n_nav_goals=3 n_engulfed=0 "
        "n_agent_trapped=0 project_blocked=false\n"
        '[invariant] {"I1":"ok","I1b":"ok","I2":"ok","I3":0,"I4":"na"}\n'
        '[libarm] {"arm_id":100,"execution_ok":true,"wall_s":1.0}\n'
        % (json.dumps(ctx), "true" if complete else "false"))
    dec = copy.deepcopy(decision)
    dec["input"]["router"]["ood_features"] = {"kind": "zone"}
    stream = g / "streams" / "s.jsonl"
    stream.write_text(json.dumps({"sim_t": 20.0, "n_closed": 287, "battery": {"total_energy_J": 1.0},
                                  "respec_history": [dec], "ood": []}) + "\n")
    (g / "jobs.jsonl").write_text(json.dumps({"run_key": rk, "stream": str(stream)}) + "\n")
    (g / "runs.jsonl").write_text(json.dumps({"run_key": rk, "rc": 0}) + "\n")
    led = tmp_path / "ledger.jsonl"
    led.write_text("".join(json.dumps(r) + "\n" for r in _ledger()))
    return str(g), str(led)

def test_collect_run_reads_invariant_libarm_and_decisions(tmp_path):
    g, _ = _grid(tmp_path, FX["decision"])
    r = harvest.collect_run(g, RID)
    assert r["complete"] and r["n_total"] == 305 and r["rc"] == 0 and r["minted_verdict"] == "admit"
    assert r["inv"]["I1"] == "ok" and r["libarm"][0]["execution_ok"] is True
    assert r["sim_seconds"] == 20.0 and len(r["decisions_raw"]) == 1

def test_harvest_run_appends_once_with_artifact_identity(tmp_path, monkeypatch):
    monkeypatch.setenv("SELFIMPROVE_STATE_ROOT", str(tmp_path / "state"))
    g, led = _grid(tmp_path, FX["decision"])
    q = harvest.harvest_run("t", g, RID, led)
    assert q["lane"] == "dspy" and q["final_row"] == "rewrite" and q["version"] == "v0"
    assert q["artifact_sha256"] == harvest.artifact_of(FX["rewrite"])
    assert q["behavior_key"].startswith("zone|") and q["llm_cost_usd"] > 0
    assert os.path.exists(tmp_path / "state" / "t" / "bodies" / (q["artifact_sha256"] + ".json"))
    assert harvest.harvest_run("t", g, RID, led) is None                  # 멱등: 같은 판은 한 번
