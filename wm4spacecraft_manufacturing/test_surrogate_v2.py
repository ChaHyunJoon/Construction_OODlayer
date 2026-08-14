#!/usr/bin/env python3
"""SurrogateV2 단위검사 — 합성 데이터로 계약을 고정한다(실제 라벨 없이 돈다)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_v2 import SurrogateV2

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


def synth():
    """battery 에서는 8 이 완주시키고 1 은 못 시키는 합성 격자."""
    rows = []
    for i in range(40):
        base = dict(kind="battery", severity=0.1, soc=0.1, spare_count=3, agent_pending=5,
                    progress=0.4, n_active=10, n_spare_cfg=3, closed_at_fire=120,
                    total=313, zone_overlap=None, zone_radius=None,
                    valid_mask=[0, 1, 8], instance="b%d" % i)
        rows.append(dict(base, macro=0, complete=False, closed=150, makespan=70.0, energy_J=90000.0))
        rows.append(dict(base, macro=1, complete=False, closed=240, makespan=60.0, energy_J=95000.0))
        rows.append(dict(base, macro=8, complete=True,  closed=291, makespan=22.0, energy_J=73000.0))
    return rows


def main():
    print("== SurrogateV2 ==")
    rows = synth()
    m = SurrogateV2().fit(rows)

    J = m.predict_J(rows)
    check("predict_J 가 행 수만큼 돌려준다", len(J) == len(rows), str(len(J)))
    check("predict_J 가 전부 유한하다", np.all(np.isfinite(J)))

    p = m.predict_complete_proba(rows)
    check("완주 확률이 [0,1]", np.all((p >= 0) & (p <= 1)))
    # macro 8 만 완주하는 데이터이므로 8 의 완주확률이 1 보다 확실히 높아야 한다.
    p8 = p[[i for i, r in enumerate(rows) if r["macro"] == 8]].mean()
    p1 = p[[i for i, r in enumerate(rows) if r["macro"] == 1]].mean()
    check("P(complete) 가 8 > 1", p8 > p1, "p8=%.3f p1=%.3f" % (p8, p1))

    d = m.predict_delta_J(rows, ref_macro=0)
    check("predict_delta_J 가 행 수만큼", len(d) == len(rows))
    # NOOP 행의 ΔJ 는 정의상 0 이어야 한다.
    d0 = d[[i for i, r in enumerate(rows) if r["macro"] == 0]]
    check("NOOP 의 ΔJ == 0", np.allclose(d0, 0.0, atol=1e-6), str(d0[:3]))
    # 완주시키는 팔의 ΔJ 가 확실히 음수(개선)여야 한다 — C_fail 절벽 때문에 크게 갈린다.
    d8 = d[[i for i, r in enumerate(rows) if r["macro"] == 8]].mean()
    check("완주시키는 팔의 ΔJ 가 음수(개선)", d8 < 0, "mean=%.1f" % d8)

    # argmin 이 8 을 고르는가 = 결정 규칙의 종단 계약
    picks = []
    for i in range(40):
        idx = [k for k, r in enumerate(rows) if r["instance"] == "b%d" % i]
        picks.append(rows[idx[int(np.argmin(d[idx]))]]["macro"])
    check("argmin ΔJ 가 SwapBattery(8) 를 고른다", all(x == 8 for x in picks),
          str(sorted(set(picks))))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
