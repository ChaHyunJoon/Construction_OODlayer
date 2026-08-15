#!/usr/bin/env python3
"""분해 충실성 단위검사 — **차단 게이트**. 합성 판만 쓴다(시뮬 0회, 결정적).

이 검사가 지키는 것
==================
`sample_grid.decompose_board` 는 판 단위 J 를 구간 비용 `c_k` 로 쪼갠다. 배분 규칙을 지어내면
**그 규칙이 곧 결과가 되므로**, "지어내지 않았다"를 기계로 못박아야 한다. 그 항등식은

    c_prefix + Σ_k c_k + terminal_value  ==  objective.J_row(row)

이고, 여기서 `c_k = Δmakespan + w_E·Δenergy` 는 **J 의 완주 분기 형태로 고정**돼 있다.
따라서 이 항등식은 실질적으로 **"c 의 정의가 objective.J 와 같은 것인가"** 를 검사한다 —
J 에 항이 하나 추가되거나 w_E 가 다른 값이 되면 잔차가 즉시 벌어진다. T-06 이 그 비자명성을
직접 보인다(틀린 w_E 를 먹이면 게이트가 발화해야 한다).

`c_prefix` 는 `[0, t_1]` — 첫 결정 이전 — 구간이다. DP 는 쓰지 않지만(어떤 정책도 못 바꾼다)
항등식에는 **재서 넣는다**. 0 으로 두면 게이트가 완주 판마다 그 양만큼 조용히 어긋난다.
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import objective                                                    # noqa: E402
import sample_grid as SG                                            # noqa: E402
from derive_grid import load_grid, cell_key, state_of               # noqa: E402

TOL = SG.FIDELITY_TOL
W_E = objective.energy_weight(objective.load())

FAILS = []


def check(name, cond, detail=""):
    print("  %-58s %s%s" % (name, "PASS" if cond else "**FAIL**",
                            "" if cond else "   " + str(detail)))
    if not cond:
        FAILS.append(name)


def decision(at, t, e, *, truth="BatteryTruth", prog=0.5, spares=10, pend=1,
             soc=0.03, macro="NOOP"):
    """합성 결정 하나. `state_of` 가 읽는 축 + 구간 비용의 원자료를 전부 갖춘다."""
    return {"at": at, "closed_at": at, "sim_t_at": t, "energy_at_J": e,
            "truth": truth, "progress": prog, "spare_count": spares,
            "agent_pending": pend, "soc": soc, "macro": macro,
            "zone_primitives": None}


def board(decs, *, complete, makespan, energy, closed=250, total=300):
    return {"complete": complete, "closed": closed, "total": total,
            "makespan": makespan, "battery": {"total_energy_J": energy},
            "decisions": decs, "objective_hash": objective.objective_hash(),
            "energy_objective": 1}


# =====================================================================================
print("T-01  완주 판: c_prefix + Σc + 0 == J   (에너지 항이 살아 있는지 포함)")
# -------------------------------------------------------------------------------------
ds = [decision(10, 2.0, 1000.0), decision(50, 8.0, 40000.0), decision(90, 15.0, 90000.0)]
b_ok = board(ds, complete=True, makespan=20.0, energy=120000.0)
d = SG.decompose_board(b_ok)

check("T-01a 분해 성공", d["ok"], d["reason"])
check("T-01b terminal == goal", d["terminal"] == "goal", d["terminal"])
check("T-01c terminal_value == 0", d["terminal_value"] == 0.0, d["terminal_value"])
check("T-01d 정산 잔차 < tol", abs(d["resid_settle"]) < TOL, d["resid_settle"])
check("T-01e 텔레스코핑 잔차 < tol", abs(d["resid_telescope"]) < TOL, d["resid_telescope"])
check("T-01f 구간이 결정 수만큼", len(d["cs"]) == 3, len(d["cs"]))
# c_prefix 는 [0, t_1] 이고 **실제로 0 이 아니다**. 이 값을 0 으로 두면 위 잔차가 그만큼 벌어진다.
check("T-01g c_prefix == t_1 + w_E*e_1",
      abs(d["c_prefix"] - (2.0 + W_E * 1000.0)) < TOL, d["c_prefix"])
check("T-01h c_prefix > 0 (0 으로 두면 게이트가 발화한다)", d["c_prefix"] > 0, d["c_prefix"])
# 마지막 구간은 마지막 결정 -> 종단.
check("T-01i 마지막 c == (T-t_n) + w_E*(E_T-e_n)",
      abs(d["cs"][-1] - ((20.0 - 15.0) + W_E * (120000.0 - 90000.0))) < TOL, d["cs"][-1])

# **에너지가 살아 있는가.** 에너지만 바꾼 판은 Σc 가 정확히 w_E*Δ 만큼 달라져야 한다.
# w_E 를 0 으로 폴백하는 구현에서는 이 검사가 실패한다.
b_more_e = board([decision(10, 2.0, 1000.0), decision(50, 8.0, 40000.0),
                  decision(90, 15.0, 90000.0)],
                 complete=True, makespan=20.0, energy=170000.0)
d_more = SG.decompose_board(b_more_e)
d_sum = (d_more["c_prefix"] + d_more["sum_c"]) - (d["c_prefix"] + d["sum_c"])
check("T-01j 에너지 +50000 -> 러닝코스트 +w_E*50000",
      abs(d_sum - W_E * 50000.0) < TOL and d_sum > 0, (d_sum, W_E * 50000.0))

# =====================================================================================
print("\nT-02  미완주 판: c_prefix + Σc + terminal == J,  그리고 terminal != 0")
# -------------------------------------------------------------------------------------
b_bad = board(ds, complete=False, makespan=20.0, energy=120000.0, closed=200, total=300)
d2 = SG.decompose_board(b_bad)
J2 = objective.J_row(b_bad)

check("T-02a 분해 성공", d2["ok"], d2["reason"])
check("T-02b terminal == dead_end", d2["terminal"] == "dead_end", d2["terminal"])
check("T-02c terminal_value != 0", d2["terminal_value"] != 0.0, d2["terminal_value"])
check("T-02d 정산 항등식",
      abs(d2["c_prefix"] + d2["sum_c"] + d2["terminal_value"] - J2) < TOL, d2["resid_settle"])
# 미완주 J 는 에너지를 안 쓰므로 종단값이 러닝코스트를 **되물어야** 한다. 그 부호를 확인한다.
check("T-02e terminal == J − (c_prefix+Σc)",
      abs(d2["terminal_value"] - (J2 - d2["c_prefix"] - d2["sum_c"])) < TOL, d2["terminal_value"])
check("T-02f 러닝코스트는 두 분기에서 같다(완주 분기 형태로 고정)",
      abs((d2["c_prefix"] + d2["sum_c"]) - (d["c_prefix"] + d["sum_c"])) < TOL,
      (d2["sum_c"], d["sum_c"]))
check("T-02g 미완주 J 가 완주 J 보다 훨씬 크다(C_fail 이 살아 있다)",
      J2 > objective.J_row(b_ok) + 1000.0, (J2, objective.J_row(b_ok)))

# =====================================================================================
print("\nT-03  결정이 1개뿐인 판 · 0개인 판(전이 없음)")
# -------------------------------------------------------------------------------------
b1 = board([decision(10, 2.0, 1000.0)], complete=True, makespan=20.0, energy=120000.0)
d3 = SG.decompose_board(b1)
check("T-03a 결정 1개: 분해 성공", d3["ok"], d3["reason"])
check("T-03b 결정 1개: 구간 1개(그 결정 -> 종단)", len(d3["cs"]) == 1, len(d3["cs"]))
check("T-03c 결정 1개: 정산 잔차 < tol", abs(d3["resid_settle"]) < TOL, d3["resid_settle"])

b0 = board([], complete=True, makespan=20.0, energy=120000.0)
d4 = SG.decompose_board(b0)
check("T-03d 결정 0개: 분해 성공", d4["ok"], d4["reason"])
check("T-03e 결정 0개: 구간 없음", d4["cs"] == [], d4["cs"])
# 전이가 없으므로 러닝코스트 전부가 c_prefix 다 — 판 전체가 '결정 이전' 이다.
check("T-03f 결정 0개: c_prefix 가 판 전체",
      abs(d4["c_prefix"] - (20.0 + W_E * 120000.0)) < TOL, d4["c_prefix"])
check("T-03g 결정 0개: 정산 잔차 < tol", abs(d4["resid_settle"]) < TOL, d4["resid_settle"])

b0i = board([], complete=False, makespan=20.0, energy=120000.0, closed=200, total=300)
d4i = SG.decompose_board(b0i)
check("T-03h 결정 0개 미완주: 정산 항등식", d4i["ok"] and abs(d4i["resid_settle"]) < TOL,
      d4i["reason"])

# =====================================================================================
print("\nT-04  원자료가 없는 행은 **버리지 않고 세어서** 보고한다")
# -------------------------------------------------------------------------------------
b_no_t = board([decision(10, None, 1000.0)], complete=True, makespan=20.0, energy=120000.0)
d5 = SG.decompose_board(b_no_t)
check("T-04a sim_t_at=None -> ok=False", not d5["ok"], d5)
check("T-04b 이유에 필드 이름이 남는다", "sim_t_at" in str(d5["reason"]), d5["reason"])

b_no_e = board([decision(10, 2.0, None)], complete=True, makespan=20.0, energy=120000.0)
d6 = SG.decompose_board(b_no_e)
check("T-04c energy_at_J=None -> ok=False", not d6["ok"], d6)
check("T-04d 이유에 필드 이름이 남는다", "energy_at_J" in str(d6["reason"]), d6["reason"])

b_no_term = {"complete": True, "closed": 250, "total": 300, "makespan": None,
             "battery": {}, "decisions": [decision(10, 2.0, 1000.0)]}
d7 = SG.decompose_board(b_no_term)
check("T-04e 종단값 없음 -> ok=False, 이름은 terminal_missing",
      (not d7["ok"]) and "terminal_missing" in str(d7["reason"]), d7["reason"])

# 표집기가 그 판을 **세는지** 본다(조용히 사라지면 안 된다).
axes = load_grid()["axes"]
with tempfile.TemporaryDirectory() as td:
    p = os.path.join(td, "rows.jsonl")
    with open(p, "w") as f:
        for r in (b_ok, b_no_t, b_bad):
            f.write(json.dumps(r) + "\n")
    rep = SG.new_report()
    smp = SG.rows_to_samples(p, "all", 1, 0, "NOOP", axes, report=rep)
check("T-04f 판 3개를 전부 셌다", rep["boards"] == 3, rep["boards"])
check("T-04g 어긋난 판 1개를 이름으로 남겼다",
      rep["boards_bad"] == 1 and len(rep["examples"]) == 1, (rep["boards_bad"], rep["examples"]))
check("T-04h 성한 판 2개에서만 전이가 나왔다", len(smp) == 6, len(smp))

# =====================================================================================
print("\nT-05  전이 구조: 마지막만 종단, 나머지는 next_cell 로 이어진다")
# -------------------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as td:
    p = os.path.join(td, "rows.jsonl")
    with open(p, "w") as f:
        f.write(json.dumps(b_ok) + "\n")
    tr = SG.rows_to_samples(p, "all", 1, 7, "RelocateBuild", axes)

check("T-05a 전이 3개", len(tr) == 3, len(tr))
check("T-05b 마지막만 terminal",
      [t["terminal"] for t in tr] == [None, None, "goal"], [t["terminal"] for t in tr])
check("T-05c 마지막만 terminal_value 를 싣는다",
      [t["terminal_value"] for t in tr] == [None, None, 0.0],
      [t["terminal_value"] for t in tr])
check("T-05d 비종단 전이는 next_cell 을 갖는다",
      all(t["next_cell"] is not None for t in tr[:-1]) and tr[-1]["next_cell"] is None,
      [t["next_cell"] for t in tr])
check("T-05e next_cell 이 다음 전이의 cell 과 같다",
      tr[0]["next_cell"] == tr[1]["cell"] and tr[1]["next_cell"] == tr[2]["cell"],
      (tr[0]["next_cell"], tr[1]["cell"]))
check("T-05f c 가 분해의 cs 와 같다",
      all(abs(tr[i]["c"] - d["cs"][i]) < TOL for i in range(3)), [t["c"] for t in tr])
check("T-05g 팔이 전이마다 실린다",
      all(t["arm"] == 7 and t["arm_name"] == "RelocateBuild" for t in tr), tr[0]["arm"])
check("T-05h 판 단위 J 도 남는다(상수-팔 판과의 대조용)",
      all(abs(t["cost"] - objective.J_row(b_ok)) < TOL for t in tr), tr[0]["cost"])
check("T-05i c 의 합 + c_prefix == 러닝코스트",
      abs(sum(t["c"] for t in tr) + tr[0]["c_prefix"] - (20.0 + W_E * 120000.0)) < TOL,
      sum(t["c"] for t in tr))

# =====================================================================================
print("\nT-06  게이트가 **비자명**한가 — 틀린 w_E 를 먹이면 발화해야 한다")
# -------------------------------------------------------------------------------------
# 이것이 이 파일의 존재 이유다. 위 검사들이 전부 항등식이라 '언제나 참' 이면 게이트가 아무것도
# 막지 못한다. c 의 정의가 objective.J 에서 벗어나는 순간 잔차가 벌어지는지 직접 확인한다.
d_w0 = SG.decompose_board(b_ok, w_E=0.0)
check("T-06a w_E=0 (에너지 항 탈락) -> 완주 판에서 게이트 발화", not d_w0["ok"], d_w0)
check("T-06b 잔차가 실제로 w_E*energy 만큼 벌어졌다",
      abs(abs(d_w0["resid_settle"]) - W_E * 120000.0) < TOL, d_w0["resid_settle"])
d_w2 = SG.decompose_board(b_ok, w_E=W_E * 2.0)
check("T-06c w_E 2배 -> 게이트 발화", not d_w2["ok"], d_w2)
# 미완주 분기에서는 terminal_value 가 차액을 흡수하므로 정산식이 자명해진다. 그래서
# 텔레스코핑 잔차가 그 분기의 실질 검사다 — 그쪽도 발화하는지 확인한다.
d2_w0 = SG.decompose_board(b_bad, w_E=0.0)
check("T-06d 미완주 분기도 텔레스코핑 잔차로 잡힌다",
      (not d2_w0["ok"]) and abs(d2_w0["resid_telescope"]) > TOL, d2_w0["resid_telescope"])

# 순서가 어긋난 결정 · 종단 뒤의 결정도 이름으로 멈춘다(정렬해서 덮지 않는다).
b_unsorted = board([decision(10, 8.0, 40000.0), decision(50, 2.0, 1000.0)],
                   complete=True, makespan=20.0, energy=120000.0)
d8 = SG.decompose_board(b_unsorted)
check("T-06e sim_t 역행 -> ok=False", (not d8["ok"]) and "monotone" in str(d8["reason"]),
      d8["reason"])
b_after = board([decision(10, 99.0, 1000.0)], complete=True, makespan=20.0, energy=120000.0)
d9 = SG.decompose_board(b_after)
check("T-06f 종단 뒤의 결정 -> ok=False",
      (not d9["ok"]) and "after_terminal" in str(d9["reason"]), d9["reason"])

# =====================================================================================
print("\nT-07  w_E 를 objective 에서 읽는가 (리터럴 0 이 아닌가)")
# -------------------------------------------------------------------------------------
check("T-07a w_E > 0", W_E > 0, W_E)
check("T-07b decompose_board 가 같은 w_E 를 쓴다", abs(d["w_E"] - W_E) < 1e-18, d["w_E"])
cfg = objective.load()
check("T-07c w_E == kappa*M_ref/E_ref (objective 경유)",
      abs(W_E - float(cfg["kappa"]) * float(cfg["M_ref"]) / float(cfg["E_ref"])) < 1e-18, W_E)
src = open(os.path.join(HERE, "sample_grid.py")).read()
check("T-07d sample_grid 가 energy_weight() 를 경유한다",
      "objective.energy_weight(" in src, False)
for lit in ("10000.0", "121818", "31.225", "0.01 *"):
    check("T-07e 목적함수 상수 리터럴 없음: %s" % lit, lit not in src, lit)

# =====================================================================================
print()
if FAILS:
    print("**%d FAIL** — %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("분해 충실성 단위검사 전부 통과 (합성 판, 시뮬 0회)")
