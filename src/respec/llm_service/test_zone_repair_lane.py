"""T9 zone-repair proposal lane: call/candidate budgets, envelopes, no geometry fallback, prompt and sensor audits.

🔴 Live model calls: **zero.** Every LM here is `ScriptedLM` (test/fixtures/repair_verification/fake_repair_lm.py),
whose `forward` never reaches litellm, and the autouse fixture below (a) deletes every credential-shaped env var and
(b) replaces litellm's provider entry points with a counter that raises -- the test run fails if it is ever touched.
    .venv/bin/python -m pytest src/respec/llm_service/test_zone_repair_lane.py
"""
import copy
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIX = os.path.join(ROOT, "test", "fixtures", "repair_verification")
for _p in (HERE, FIX):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy)
import synthesize as SY  # noqa: E402
import dspy  # noqa: E402
import pytest  # noqa: E402
from fake_repair_lm import (BROKEN, DESIGN_FIRES, FIXED, OBSERVE, RELEASE, ScriptedLM, tool)  # noqa: E402

BUDGET = {"max_model_calls": 4, "max_candidates": 4, "max_total_tokens": 100000}
PROVIDER_CALLS = {"n": 0}


@pytest.fixture(autouse=True)
def _no_provider(monkeypatch):
    import litellm
    for k in list(os.environ):
        if re.search(r"(API_KEY|_TOKEN|SECRET|PASSWORD)", k):
            monkeypatch.delenv(k, raising=False)

    def _forbidden(*a, **k):
        PROVIDER_CALLS["n"] += 1
        raise AssertionError("a real provider entry point was called")
    for name in ("completion", "acompletion", "responses", "aresponses", "text_completion"):
        if hasattr(litellm, name):
            monkeypatch.setattr(litellm, name, _forbidden)
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    with dspy.context(adapter=svc.build_adapter()):
        yield
    assert PROVIDER_CALLS["n"] == 0


def compose(*cands, **extra):
    return dict({"expect": "compose", "fields": {"wrote": True, "needs": "", "candidates": list(cands)}}, **extra)


def run(script, *, arm="general", budget=BUDGET, gctx=None, state="OBSERVATION: a zone appeared"):
    lm = ScriptedLM(script)
    out = SY.propose_repair(state, arm=arm, checkpoint_id="t0", budget=dict(budget), lm=lm, id_prefix="rid",
                            geometry_context=gctx, provenance={"source": "service"})
    return out, lm


def revise(first, lm_script, rejected, *, arm="general", gctx=None):
    lm = ScriptedLM(lm_script)
    out = SY.revise_repair(arm=arm, checkpoint_id="t0", budget=dict(BUDGET), ledger_state=first["ledger"],
                           compose_input=first["compose_input"], rejected=rejected, lm=lm, id_prefix="rid2",
                           geometry_context=gctx, provenance={"source": "service"})
    return out, lm


def rej(pid, why="enactment registration_rejected: reject:impl_unknown_call:t9_no_such_helper"):
    return [{"proposal_id": pid, "impl_code": "function f!(env) end", "reasons": [why]}]


# ---- spec 7.2 budget cases ---------------------------------------------------------------------------------
def test_four_first_means_no_revision():
    out, lm = run([OBSERVE, DESIGN_FIRES, compose(RELEASE, BROKEN, FIXED, RELEASE)])
    assert out["error"] is None and out["ledger"]["calls_used"] == 3 and out["ledger"]["submitted"] == 4
    assert [c["submission_index"] for c in out["candidates"]] == [1, 2, 3, 4]
    r2, lm2 = revise(out, [], rej("rid-s2"))
    assert r2["error"].startswith("refused: candidate budget: 4 of 4 submitted")
    assert lm2.seen == [] and r2["ledger"]["calls_used"] == 3 and r2["candidates"] == []


def test_three_first_allows_exactly_one_revision_candidate():
    out, _ = run([OBSERVE, DESIGN_FIRES, compose(RELEASE, BROKEN, FIXED)])
    assert out["ledger"]["submitted"] == 3
    # the revision answers with TWO objects; only one slot is left, the second is not a submission
    r2, lm2 = revise(out, [compose(dict(FIXED, rewrite_of="rid-s2"), RELEASE, expect="compose_revision")],
                     rej("rid-s2"))
    assert r2["error"] is None, r2["error"]
    assert r2["ledger"]["calls_used"] == 4 and r2["ledger"]["submitted"] == 4
    assert [c["submission_index"] for c in r2["candidates"]] == [4]
    assert r2["candidates"][0]["parent_proposal_id"] == "rid-s2"
    assert [s["status"] for s in r2["submissions"]] == ["submitted", "dropped_over_candidate_budget"]
    assert [s["stage"] for s in lm2.seen] == ["compose_revision"]


def test_one_compose_response_carries_several_complete_candidates():
    out, lm = run([OBSERVE, DESIGN_FIRES, compose(RELEASE, FIXED)])
    assert [s["stage"] for s in lm.seen] == ["observe", "design", "compose"]
    assert len(out["candidates"]) == 2 and all(s["envelope_errors"] == [] for s in out["submissions"])


def test_a_provider_retry_consumes_the_revision_call():
    out, lm = run([dict(OBSERVE, **{"raise": "429"}), OBSERVE, DESIGN_FIRES, compose(RELEASE, BROKEN, FIXED)])
    calls = out["ledger"]["calls"]
    assert [c["stage"] for c in calls] == ["observe", "observe", "design", "compose"]
    assert calls[0]["ok"] is False and "429" in calls[0]["error"]
    r2, lm2 = revise(out, [], rej("rid-s2"))
    assert "call budget" in r2["error"] and lm2.seen == [], "the hidden retry must have used the 4th call"
    assert r2["ledger"]["calls_used"] == 4


def test_a_hidden_schema_retry_is_counted_as_a_call():
    """ChatAdapter cannot parse the first answer and silently asks again through JSONAdapter -- a second LM call."""
    out, lm = run([{"expect": "observe", "text": "not the field format at all"},
                   {"expect": "observe", "json": {"reasoning_log": "a zone froze one goal"}},
                   DESIGN_FIRES, compose(RELEASE)])
    assert out["error"] is None, out["error"]
    assert [c["stage"] for c in out["ledger"]["calls"]] == ["observe", "observe", "design", "compose"]
    assert out["reasoning_log"] == "a zone froze one goal"


def test_retries_can_never_eat_a_mandatory_stage():
    out, lm = run([dict(OBSERVE, **{"raise": "a"}), dict(OBSERVE, **{"raise": "b"})])
    assert out["error"].startswith("observe: budget: call budget")
    assert [s["stage"] for s in lm.seen] == ["observe", "observe"] and out["candidates"] == []
    assert out["ledger"]["refused"] and out["ledger"]["refused"][0]["stage"] == "observe"


def test_truncated_code_is_not_a_valid_candidate():
    out, _ = run([OBSERVE, DESIGN_FIRES, compose(RELEASE, FIXED, finish_reason="length")])
    assert out["candidates"] == []
    assert [s["status"] for s in out["submissions"]] == ["invalid_truncated_response"] * 2
    assert out["ledger"]["submitted"] == 2 and out["ledger"]["calls"][-1]["truncated"] is True


def test_the_token_budget_caps_each_call_and_then_refuses():
    budget = dict(BUDGET, max_total_tokens=100)
    big = {"prompt_tokens": 60, "completion_tokens": 50, "total_tokens": 110}
    out, lm = run([dict(OBSERVE, usage=big)], budget=budget)
    assert lm.seen[0]["kwargs"]["max_tokens"] == 100, "the remaining token budget must cap the call"
    assert out["error"].startswith("design: budget: token budget") and out["candidates"] == []


def test_disabled_flag_and_missing_lm_make_zero_calls(monkeypatch):
    monkeypatch.setenv("TOOL_SYNTHESIS", "0")
    out, lm = run([OBSERVE])
    assert out["error"].startswith("disabled") and lm.seen == []
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    out = SY.propose_repair("s", arm="general", checkpoint_id="t0", budget=BUDGET, lm=None, id_prefix="x")
    assert out["error"].startswith("no LM") and out["ledger"]["calls_used"] == 0


def test_expressible_true_ends_with_zero_candidates_after_two_calls():
    d = copy.deepcopy(DESIGN_FIRES)
    d["fields"]["expressible"] = True
    out, lm = run([OBSERVE, d])
    assert out["candidates"] == [] and out["ledger"]["calls_used"] == 2 and "expressible=True" in out["reason"]


def test_the_budget_has_no_default_and_no_value_above_four():
    for bad in (dict(BUDGET, max_total_tokens=None), dict(BUDGET, max_model_calls=5), dict(BUDGET, max_candidates=0)):
        with pytest.raises((ValueError, TypeError)):
            SY.RepairLedger(**bad)


# ---- envelopes and U1 ------------------------------------------------------------------------------------
def test_candidates_are_tool_proposals_in_submission_order_and_u1_is_the_first():
    out, _ = run([OBSERVE, DESIGN_FIRES, compose(RELEASE, FIXED, BROKEN)])
    c = out["candidates"]
    assert [x["proposal_id"] for x in c] == ["rid-s1", "rid-s2", "rid-s3"]
    assert c[0]["impl_name"] == "t9_release_one!", "U1 = the first submitted code (index 1)"
    for x in c:
        assert x["schema_version"] == "tool-proposal/1" and x["checkpoint_id"] == "t0"
        assert SY._schema_errors(x, SY.TOOL_PROPOSAL_SCHEMA_PATH) == []
        assert x["calls"] == [{"primitive": x["impl_name"], "args": {}}] and x["params"] == {}


def test_the_general_arm_never_turns_into_a_geometry_patch():
    patchish = {"writes": [{"config_ref": "AssemblyID(1)", "x": 1.0, "y": 2.0}]}
    out, _ = run([OBSERVE, DESIGN_FIRES, compose(patchish)])
    (c,) = out["candidates"]
    assert c["schema_version"] == "tool-proposal/1" and "writes" not in c
    assert out["submissions"][0]["envelope_errors"], "a patch-shaped answer is an invalid ToolProposal, not a patch"
    assert all(x["schema_version"] != "geometry-patch/1" for x in out["candidates"])


def test_unknown_arm_is_an_error_not_a_fallback():
    with pytest.raises(ValueError):
        run([], arm="Geometry")
    with pytest.raises(Exception):
        svc.ZoneRepairProposeRequest(request={"kind": "zone"}, arm="geo", checkpoint_id="t0", budget=BUDGET,
                                     capability_contract_version="c", record_id="r")


GCTX = {"configs": [{"config_ref": "AssemblyID(3)", "x": 1.0, "y": -2.0, "staging_radius": 0.8, "closed": False}],
        "zones": [{"key": "Z1", "center": [1.0, -2.0], "radius": 1.0}]}


def test_the_geometry_arm_refuses_without_its_context_and_makes_zero_calls():
    out, lm = run([OBSERVE], arm="geometry", gctx=None)
    assert out["error"].startswith("refused: the geometry arm") and lm.seen == []


def test_the_geometry_arm_emits_patches():
    p = {"writes": [{"config_ref": "AssemblyID(3)", "x": 3.5, "y": -2.0}], "rationale": "clear the disc"}
    cmp_ = {"expect": "compose", "fields": {"candidates": [p]}}
    out, lm = run([OBSERVE, DESIGN_FIRES, cmp_], arm="geometry", gctx=GCTX)
    (c,) = out["candidates"]
    assert c["schema_version"] == "geometry-patch/1" and c["writes"][0]["xy"] == {"x": 3.5, "y": -2.0}
    assert SY._schema_errors(c, SY.GEOMETRY_PATCH_SCHEMA_PATH) == []


# ---- prompt audit (main arm) -------------------------------------------------------------------------------
_BANNED = [r"move (the )?goal", r"\bXY\b", r"geometry[- ]only", r"GeometryPatch", r"geometry.patch",
           r"desired_xy", r"config_ref", r"min_shift", r"shift_to_clear", r"\boracle\b",
           r"choose (exactly )?one of the following", r"pick one mechanism", r"\bseed\s*[=:#]?\s*\d+",
           r"(tractor|x.?wing)\W+(zone|all3)", r"succeeded before", r"\banchor\b", r"\brescued?\b"]
# ⚠️ plain "seed" is NOT banned: `random_restriction_zone!(env; seed=...)` is a real world-interface keyword.


def _fixture_names():
    """Names of every hand-written/historical repair body -- none may reach a main-arm prompt."""
    names = set()
    for root, _dirs, files in os.walk(FIX):
        for f in files:
            if f.endswith((".jl", ".json")):
                txt = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
                names.update(re.findall(r"function\s+([A-Za-z_][A-Za-z0-9_]*!)", txt))
    names.update({RELEASE["impl_name"], BROKEN["impl_name"], FIXED["impl_name"]})
    return names


def _hits(text, names):
    h = [p for p in _BANNED if re.search(p, text, re.I)]
    return h + sorted(n for n in names if n in text)


def _prompt_text(lm, stage):
    return "\n".join(m.get("content", "") or "" for s in lm.seen if s["stage"] == stage for m in s["messages"])


def test_no_main_arm_prompt_forces_geometry_or_leaks_fixtures():
    out, lm = run([OBSERVE, DESIGN_FIRES, compose(tool("t9_other!", ["return :ok"]), BROKEN)])
    r2, lm2 = revise(out, [compose(tool("t9_other2!", ["return :ok"]), expect="compose_revision")],
                     rej("rid-s2", "reject:impl_unknown_call:helper"))
    names = _fixture_names() - {"t9_other!", "t9_other2!", "t9_broken!"}   # the revision legitimately shows the rejected code
    assert names, "the fixture-name population is empty -- the audit would pass vacuously"
    for L, st in ((lm, "observe"), (lm, "design"), (lm, "compose"), (lm2, "compose_revision")):
        txt = _prompt_text(L, st)
        assert txt, "no prompt captured for %s" % st
        assert _hits(txt, names) == [], "%s prompt: %s" % (st, _hits(txt, names))


def test_the_prompt_detector_fires_on_planted_text_and_on_the_geometry_arm():
    names = _fixture_names()
    assert _hits("please move the goal outside", names) and _hits("change XY only", names)
    assert _hits("it worked on tractor zone s16 (seed 16)", names)
    assert _hits("body t8_shift_and_step! here", names), "fixture names must be detected"
    p = {"writes": [{"config_ref": "AssemblyID(3)", "x": 3.5, "y": -2.0}]}
    _, lm = run([OBSERVE, DESIGN_FIRES, {"expect": "compose", "fields": {"candidates": [p]}}], arm="geometry", gctx=GCTX)
    assert _hits(_prompt_text(lm, "compose"), set()), "positive control: the G4 prompt IS geometry-only"
    assert "GEOMETRY-ONLY COMPARISON ARM" in _prompt_text(lm, "design")


def test_design_stays_blind_to_the_raw_observation_and_the_world_interface():
    state = "OBSERVATION: zone Z1 appeared\n\nMEASURED STATE (x)\n  spare_robots = 2"
    _, lm = run([OBSERVE, DESIGN_FIRES, compose(FIXED)], state=state)
    d, c = _prompt_text(lm, "design"), _prompt_text(lm, "compose")
    assert "MEASURED STATE" not in d and "OBSERVATION:" not in d
    iface = SY.compose_interface()
    probe = [ln.strip() for ln in iface.splitlines() if "release_pending_assignments!" in ln][:1]
    assert probe and probe[0] not in d and probe[0] in c, "compose gets the world interface, design does not"


# ---- sensor coverage audit ---------------------------------------------------------------------------------
BINDINGS = [
    {"robot": "BotID(1)", "available": True, "faulted": False, "spare": False, "open_goto_tasks": 3,
     "going_to": {"node": "ActionID(7)", "kind": "RobotGo", "team": {"unit": "TransportUnitID(4)", "members": ["BotID(1)", "BotID(2)"]}},
     "team_now": None, "next": {"node": "ActionID(9)", "kind": "RobotGo", "team": None}},
    {"robot": "BotID(2)", "available": False, "faulted": True, "spare": False, "open_goto_tasks": 1, "going_to": None,
     "team_now": {"unit": "TransportUnitID(4)", "state": "forming", "members": ["BotID(1)", "BotID(2)"]}, "next": None}]


def test_the_observation_and_the_world_interface_cover_more_than_geometry():
    r = svc.MacroRequest(kind="zone", nl="A no-go zone appeared.", progress=0.4, spare_count=2, n_active=7,
                         smdp_n_broken=1, smdp_fleet_soc_min=0.55, zone_overlap=0.3, zone_teams_forming=2,
                         zone_teams_covered=1, zone_nav_goals=5, zone_nav_blocked=1, zone_nav_downstream=12,
                         zone_unfinished_total=160, zone_project_blocked=True, zone_project_nodes_blocked=1,
                         zone_project_nodes_open=1, zones=[{"key": "Z1", "center": [0.0, 0.0], "radius": 1.0}])
    obs = svc._zone_repair_observation(_preq(request=r.model_dump(exclude_none=True), robot_bindings=BINDINGS))
    need = {"assignment / task binding": "ROBOTS AND THEIR COMMITTED WORK", "team membership": "in team TransportUnitID(4)",
            "availability": "BotID(2): faulted", "next task": "next ActionID(9)",
            "progress": "progress", "resource: spares": "spare_robots", "robot state": "broken_robots",
            "resource: charge": "min_fleet_soc", "parallel width": "active_nodes", "team": "teams_forming",
            "dependency": "work frozen by those", "completion reachability": "build_can_still_finish",
            "geometry": "ACTIVE NO-GO ZONES"}
    missing = [k for k, v in need.items() if v not in obs]
    assert not missing, missing
    iface = SY.compose_interface()
    # 🔴 fix: `release_pending_assignments!` 는 **변경자**다 — 읽기 표면으로 세지 않는다.
    readers = {"assignment (schedule go-to nodes)": "RobotGo", "robot state": "faulted_robots",
               "team (transport units)": "TransportUnitNode",
               "resource": "active_spares", "charge": "battery_report", "progress": "project_complete",
               "dependency (schedule graph)": "OperatingSchedule", "frontier": "PlanningCache"}
    missing = [k for k, v in readers.items() if v not in iface]
    assert not missing, missing


# ---- service endpoints (in-process, no uvicorn) ---------------------------------------------------------
def _preq(**kw):
    base = dict(request={"kind": "zone", "nl": "A no-go zone appeared.", "valid": ["NOOP"]}, arm="general",
                checkpoint_id="t0", budget=BUDGET, capability_contract_version="capability-contract/1",
                record_id="rid", run_ctx={"repair_ablation": svc.REPAIR_ABLATION})
    base.update(kw)
    return svc.ZoneRepairProposeRequest(**base)


def test_the_endpoint_stamps_the_three_provenance_fields(monkeypatch):
    lm = ScriptedLM([OBSERVE, DESIGN_FIRES, compose(RELEASE)])
    monkeypatch.setattr(svc, "_repair_lm", lambda: lm)
    out = svc.zone_repair_propose(_preq())
    (c,) = out["candidates"]
    pv = c["provenance"]
    assert pv["tool_proposal_schema_sha256"] == SY._file_sha256(SY.TOOL_PROPOSAL_SCHEMA_PATH)
    assert pv["capability_contract_version"] == "capability-contract/1"
    assert pv["service_code_fingerprint"] == svc.CODE_FINGERPRINT and pv["record_id"] == "rid"
    assert out["response_id"] and out["ledger"]["calls_used"] == 3


def test_the_endpoint_refuses_an_ablation_mismatch_without_a_call(monkeypatch):
    lm = ScriptedLM([OBSERVE])
    monkeypatch.setattr(svc, "_repair_lm", lambda: lm)
    other = "all" if svc.REPAIR_ABLATION != "all" else "none"
    out = svc.zone_repair_propose(_preq(run_ctx={"repair_ablation": other}))
    assert out["error"].startswith("refused: repair_ablation mismatch") and lm.seen == []


def test_the_revise_endpoint_round_trips_the_ledger(monkeypatch):
    lm = ScriptedLM([OBSERVE, DESIGN_FIRES, compose(RELEASE, BROKEN, FIXED),
                     compose(dict(FIXED, rewrite_of="rid-s2"), expect="compose_revision")])
    monkeypatch.setattr(svc, "_repair_lm", lambda: lm)
    first = svc.zone_repair_propose(_preq())
    body = dict(arm="general", checkpoint_id="t0", budget=BUDGET, capability_contract_version="capability-contract/1",
                ledger=first["ledger"], compose_input=first["compose_input"], rejected=rej("rid-s2"),
                record_id="rid-r", parent_record_id="rid", run_ctx={"repair_ablation": svc.REPAIR_ABLATION})
    out = svc.zone_repair_revise(svc.ZoneRepairReviseRequest(**body))
    assert out["error"] is None and out["ledger"]["calls_used"] == 4 and out["ledger"]["submitted"] == 4
    assert out["candidates"][0]["proposal_id"] == "rid-r-s4" and out["candidates"][0]["parent_proposal_id"] == "rid-s2"


def test_a_missing_schema_file_drops_the_stamp_instead_of_crashing(monkeypatch, tmp_path):
    """`*.py` 만 복사된 디렉터리에서도 임포트된다 — 도장은 None, provenance 에서는 키째 빠진다."""
    assert SY._file_sha256(str(tmp_path / "absent.json")) is None
    monkeypatch.setattr(SY, "TOOL_PROPOSAL_SCHEMA_SHA256", None)
    req = _preq()
    pv = svc._repair_provenance(req, "resp")
    assert "tool_proposal_schema_sha256" not in pv and pv["service_code_fingerprint"] == svc.CODE_FINGERPRINT


# ---- T9 fix: 재시도 두 층 · fail-closed 한도 · 존 복구 전용 배정 센서 ------------------------------------
def test_the_request_local_lm_disables_both_retry_layers_and_it_reaches_litellm(monkeypatch):
    import litellm
    lm = dspy.LM("openai/gpt-4o", cache=False)
    c = SY._request_local_lm(lm)
    assert c.num_retries == 0 and c.kwargs["max_retries"] == 0 and "max_retries" not in lm.kwargs
    seen = {}

    def capture(**kw):
        seen.update(kw)
        raise RuntimeError("captured -- no network")
    monkeypatch.setattr(litellm, "completion", capture)
    with pytest.raises(Exception, match="captured"):
        c(messages=[{"role": "user", "content": "x"}])
    assert seen["num_retries"] == 0 and seen["max_retries"] == 0, "the OpenAI client would retry off-ledger"


def test_the_cost_cap_fails_closed_on_an_unmeasured_cost():
    b = dict(BUDGET, max_cost_usd=1.0)
    out, lm = run([dict(OBSERVE, cost=None)], budget=b)
    assert out["error"].startswith("design: budget: cost budget: unmeasurable") and len(lm.seen) == 1
    out, _ = run([OBSERVE, DESIGN_FIRES, compose(FIXED)], budget=b)          # positive control: priced calls go on
    assert out["error"] is None and out["ledger"]["cost_used"] > 0


def test_the_token_cap_fails_closed_on_missing_usage():
    out, lm = run([dict(OBSERVE, usage=None)])
    assert out["error"].startswith("design: budget: token budget: unmeasurable") and len(lm.seen) == 1


def test_the_binding_sensor_reaches_only_the_zone_repair_observation_and_is_fingerprinted(monkeypatch):
    lm = ScriptedLM([OBSERVE, DESIGN_FIRES, compose(FIXED)])
    monkeypatch.setattr(svc, "_repair_lm", lambda: lm)
    req = _preq(robot_bindings=BINDINGS)
    out = svc.zone_repair_propose(req)
    obs_prompt = _prompt_text(lm, "observe")
    assert "ROBOTS AND THEIR COMMITTED WORK" in obs_prompt and "joins team TransportUnitID(4)" in obs_prompt
    assert "ROBOTS AND THEIR COMMITTED WORK" not in svc._llm_input(req.request), "decision-lane prompt unchanged"
    st = out["observation_stamps"]
    assert st["observation_sensors"]["robot_bindings"] == {"version": "robot-bindings/1",
                                                           "sha256": SY.canonical_sha256(BINDINGS)}
    assert st["observation_sha256"] == SY.hashlib.sha256(svc._zone_repair_observation(req).encode()).hexdigest()
    assert out["candidates"][0]["provenance"]["observation_sensors"] == st["observation_sensors"]
    block = SY.render_robot_bindings(BINDINGS)
    assert _hits(block, set()) == [] and not re.search(r"should|recommend|reassign|move to|best", block, re.I)
    assert SY.render_robot_bindings(None) == ""                                 # not measured -> no paragraph
