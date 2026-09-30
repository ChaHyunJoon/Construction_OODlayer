"""트리거와 후보 트랙 (plan Task 11, spec §7, §0.0 R7)."""
from tools.selfimprove import trigger

K = "zone|translate_whole_build!"

def q(i, art, key=K, lane="dspy", complete=True, code="function f!(env) translate_whole_build!(env) end",
      logged="2026-09-23T08:0%d:00" % 0):
    return {"q_id": "c/%d" % i, "lane": lane, "complete": complete, "artifact_sha256": art,
            "behavior_key": key, "impl_code": code, "logged_at": logged}

def test_two_completions_do_not_trigger_three_do():
    Q = [q(0, "a"), q(1, "b")]
    assert trigger.due(Q, [], [], []) == []
    d = trigger.due(Q + [q(2, "c")], [], [], [])
    assert len(d) == 1 and d[0]["behavior_key"] == K and d[0]["track"] == "add"
    assert d[0]["incumbent_arm_id"] is None and len(d[0]["members"]) == 3

def test_only_complete_dspy_rows_with_a_body_count():
    Q = [q(0, "a"), q(1, "b", complete=False), q(2, "c", lane="surrogate"), q(3, None)]
    assert trigger.due(Q, [], [], []) == []

def test_after_rejection_only_newer_rows_count():
    Q = [q(0, "a"), q(1, "b"), q(2, "c")]
    rej = [{"cycle": "c0", "behavior_key": K, "state": "REJECTED", "queue_pos": 3, "candidate_artifact": "a"}]
    assert trigger.due(Q, rej, [], []) == []
    Q += [q(3, "d"), q(4, "e")]
    assert trigger.due(Q, rej, [], []) == []
    d = trigger.due(Q + [q(5, "f")], rej, [], [])
    assert [m["artifact_sha256"] for m in d[0]["members"]] == ["d", "e", "f"]

def test_in_flight_cycle_blocks_its_key():
    Q = [q(i, str(i)) for i in range(6)]
    busy = [{"cycle": "c0", "behavior_key": K, "state": "S1_PASS", "queue_pos": 0, "candidate_artifact": "0"}]
    assert trigger.due(Q, busy, [], []) == []

def test_approved_artifacts_do_not_count():
    Q = [q(0, "a"), q(1, "b"), q(2, "c")]
    assert trigger.due(Q, [], [{"artifact_sha256": "a"}], []) == []

def test_active_arm_with_same_key_makes_replace_track():
    Q = [q(0, "a"), q(1, "b"), q(2, "c")]
    d = trigger.due(Q, [], [], [{"arm_id": 100, "behavior_key": K}])
    assert d[0]["track"] == "replace" and d[0]["incumbent_arm_id"] == 100

def test_representative_shortest_normalized_then_earliest():
    long_ = q(0, "a", code="function f!(env)\n  # a long comment that does not count\n  translate_whole_build!(env)\n  x = 1\nend")
    short = q(1, "b", code="function g!(env)\n    translate_whole_build!(env)\nend", logged="2026-09-23T09:00:00")
    tie = q(2, "c", code="function h!(env)  translate_whole_build!(env) end", logged="2026-09-23T08:00:00")
    assert trigger.representative([long_, short, tie])["artifact_sha256"] == "c"
