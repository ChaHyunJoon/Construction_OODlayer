"""render 엔진 라벨 계약 · 판 → 학습 행 · A₀ 재라벨 조립 (plan Task 9, spec §11.4, §0.0 R10)."""
import copy, math
import pytest
from tools.selfimprove import rows, a0_relabel

OOD = {"kind": "zone", "severity": 0.4, "soc": None, "zone_overlap": 0.3, "agent_pending": -1,
       "n_active": 18, "spare_count": 8, "closed_at_fire": 54, "total_nodes": 305,
       "progress": 0.177, "zone_nav_blocked": 2, "zone_nav_downstream": 107}

def _run(ood=OOD, desc=None, complete=True, menu=None, extra=None):
    router = {"ood_features": dict(ood), "valid_menu": menu if menu is not None else []}
    if desc is not None:
        router["descriptors"] = desc
    r = {"complete": complete, "closed": 287 if complete else 180, "n_total": 305,
         "sim_seconds": 21.6, "total_energy_J": 79347.7,
         "decisions_raw": [{"input": {"router": router}}]}
    r.update(extra or {})
    return r

STAMPS = {"vocab": "v5-4arms", "train_kinds": "battery,fault,zone", "objective_hash": "o",
          "names": {0: "NOOP", 100: "m100_x!"}}

def test_row_from_run_fields_and_labels():
    r = rows.row_from_run(_run(), 100, "zone_tractor_zone_s101", "zone", [0, 100], STAMPS)
    assert (r["instance"], r["kind"], r["macro"], r["macro_name"]) == ("zone_tractor_zone_s101", "zone", 100, "m100_x!")
    assert r["valid_mask"] == [0, 100] and r["fired"] is True and r["label_engine"] == "render"
    assert (r["complete"], r["closed"], r["total"], r["makespan"], r["energy_J"]) == (True, 287, 305, 21.6, 79347.7)
    assert (r["vocab"], r["train_kinds"], r["objective_hash"]) == ("v5-4arms", "battery,fault,zone", "o")
    # _surro_row 의 None 규약: soc None → NaN, zone 없음 → -1 (0 으로 접지 않는다)
    assert math.isnan(r["soc"]) and r["zone_overlap"] == 0.3 and r["zone_nav_blocked"] == 2.0

def test_none_zone_fields_become_sentinels():
    o = dict(OOD, kind="fault", zone_overlap=None, zone_nav_blocked=None, zone_nav_downstream=None,
             agent_pending=5, soc=None)
    r = rows.row_from_run(_run(o), 0, "i", "fault", [0, 1], STAMPS)
    assert (r["zone_overlap"], r["zone_nav_blocked"], r["zone_nav_downstream"]) == (-1.0, -1.0, -1.0)

def test_row_needs_a_decision_of_that_kind():
    with pytest.raises(ValueError):
        rows.row_from_run(_run(), 0, "i", "fault", [0, 1], STAMPS)

def test_parity_ok_and_one_feature_off():
    r = rows.row_from_run(_run(), 0, "i", "zone", [0], STAMPS)
    good = rows.descriptors(r)
    assert rows.parity_ok(r, good)
    bad = copy.deepcopy(r); bad["closed_at_fire"] = 55.0
    assert not rows.parity_ok(bad, good)

def test_menu_from_decision_or_kind_default():
    assert rows.menu_ids(_run(dict(OOD, kind="battery"), menu=["NOOP", "Replace", "SwapBattery"]), "battery") == [0, 1, 2]
    assert rows.menu_ids(_run(dict(OOD, kind="fault")), "fault") == [0, 1]   # [] = kind 기본표

def test_a0_arm_plan_names_match_registry():
    from tools.selfimprove import paths
    import json
    names = {int(k): v["name"] for k, v in json.load(open(paths.A0_REGISTRY))["macros"].items()}
    plan = a0_relabel.arm_plan()
    assert plan == {"fault": [names[0], names[1]], "battery": [names[0], names[1], names[2]]}

def test_a0_assemble_drops_out_of_menu_arms():
    o = dict(OOD, kind="battery", soc=0.5, zone_overlap=None, zone_nav_blocked=None,
             zone_nav_downstream=None, agent_pending=3)
    runs = {("tractor", "battery", 101, "NOOP"): _run(o, menu=["NOOP"]),
            ("tractor", "battery", 101, "Replace"): _run(o, menu=["NOOP"]),
            ("tractor", "battery", 102, "NOOP"): _run(o, menu=["NOOP", "Replace", "SwapBattery"]),
            ("tractor", "battery", 102, "Replace"): _run(o, menu=["NOOP", "Replace", "SwapBattery"], complete=False),
            ("tractor", "battery", 102, "SwapBattery"): _run(o, menu=["NOOP", "Replace", "SwapBattery"])}
    out = a0_relabel.assemble(runs, dict(STAMPS, names={0: "NOOP", 1: "Replace", 2: "SwapBattery"}))
    got = sorted((r["instance"], r["macro"]) for r in out)
    assert got == [("battery_tractor_s101", 0), ("battery_tractor_s102", 0),
                   ("battery_tractor_s102", 1), ("battery_tractor_s102", 2)]
    assert all(r["valid_mask"] == ([0] if r["instance"].endswith("101") else [0, 1, 2]) for r in out)
