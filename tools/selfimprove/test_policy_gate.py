"""정책 배포 게이트 D (plan Task 16, spec §0.0 R2)."""
from tools.selfimprove import policy_gate as pg

OK = {"I1": "ok", "I1b": "ok", "I2": "ok", "I3": 0, "I4": "na"}

def r(complete, lane="surrogate", cost=0.0, sim=30.0, defer=None, inv=None, libarm=None):
    return {"complete": complete, "inv": dict(inv or OK), "libarm": libarm or [], "llm_cost_usd": cost,
            "sim_seconds": sim, "zone_lane": lane, "defer_reason": defer}

def table(case, pairs):
    """pairs: [(parent_complete, new_complete)] → (parent_runs, new_runs)"""
    p = {"tractor|%s|s%d" % (case, 301 + i): r(a, lane="dspy", cost=0.2) for i, (a, _) in enumerate(pairs)}
    n = {"tractor|%s|s%d" % (case, 301 + i): r(b) for i, (_, b) in enumerate(pairs)}
    return p, n

def merge(*ts):
    P, N = {}, {}
    for p, n in ts:
        P.update(p); N.update(n)
    return P, N

def test_losing_one_fault_completion_fails_d2():
    P, N = merge(table("fault", [(True, True)] * 9 + [(True, False)]), table("zone", [(False, True)] * 5))
    c = pg.criteria(P, N)
    assert not c["D2"]["pass"] and c["D2"]["b"] == 1 and not c["all_pass"]

def test_zone_worse_fails_d1():
    P, N = table("zone", [(True, False)] * 3 + [(False, True)] + [(True, True)] * 6)
    c = pg.criteria(P, N)
    assert (c["D1"]["b"], c["D1"]["c"]) == (3, 1) and not c["D1"]["pass"]

def test_zone_better_passes():
    P, N = table("all3", [(False, True)] * 5 + [(True, True)] * 5)
    c = pg.criteria(P, N)
    assert (c["D1"]["b"], c["D1"]["c"]) == (0, 5) and c["D1"]["pass"] and c["D2"]["pass"] and c["all_pass"]

def test_new_version_dishonest_or_bad_arm_execution_fails_d3():
    P, N = table("zone", [(False, True)] * 5)
    N["tractor|zone|s301"]["inv"]["I2"] = "fail:0.3"
    assert not pg.criteria(P, N)["D3"]["pass"]
    P, N = table("zone", [(False, True)] * 5)
    N["tractor|zone|s302"]["libarm"] = [{"execution_ok": False}]
    assert not pg.criteria(P, N)["D3"]["pass"]

def test_report_fields():
    P, N = table("zone", [(False, True)] * 4)
    N["tractor|zone|s301"].update(zone_lane="dspy", defer_reason="DEFER:low_confidence:0.5", cost=0.1)
    rep = pg.criteria(P, N)["report"]
    for k in ("llm_share_zone", "llm_cost_per_run", "makespan_mean", "defer_reasons"):
        assert k in rep["new"] and k in rep["parent"]
    assert rep["parent"]["llm_share_zone"] == 1.0 and rep["new"]["llm_share_zone"] == 0.25
    assert rep["new"]["defer_reasons"] == {"low_confidence": 1}
