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


def synth_completing():
    """**두 팔이 둘 다 완주하고**, 차이가 makespan+energy 에만 사는 격자.

    왜 이 픽스처가 따로 필요한가 (2026-08-14, fix round 1 항목 4):
      위 `synth()` 는 macro 8 만 완주시키는 격자다. 그래서 "argmin ΔJ 가 8 을 고른다" 는
      C_fail(=10000) 절벽이 지배하기 **때문에** 통과한다 — 즉 그 검사는 조립식의 완주 분기가
      맞는지를 전혀 검사하지 않는다. 실제 데이터에서 무너진 자리는 정확히 그 반대쪽이다:
      팔이 **둘 다 완주**하고 진짜 차이가 makespan+energy 에 있는 몇 J 짜리일 때, 헤드 A 의
      ~1e-2 교정 잡음이 dĴ/dP ≈ −20,500 J 로 증폭되어 그 몇 J 를 뒤집는다.
      이 격자가 그 경우를 재현한다.

    구성: 36 instance 는 세 팔이 전부 완주하고 8 이 1 보다 약 2.6 J 좋다(실측 진짜 차이와
    같은 크기). 나머지 9 instance 는 NOOP 이 미완주라 헤드 A 가 상수가 아니게 된다 —
    A 가 상수면 P̂ 가 1.0 로 고정돼 증폭 자체가 일어나지 않아 결함이 재현되지 않는다.
    """
    rows = []
    for i in range(36):
        base = dict(kind="battery", severity=0.05, soc=0.05 + 0.004 * i, spare_count=3,
                    agent_pending=4 + (i % 3), progress=0.45, n_active=10, n_spare_cfg=3,
                    closed_at_fire=130 + i, total=289, total_nodes=289,
                    zone_overlap=None, zone_radius=None,
                    valid_mask=[0, 1, 8], instance="c%d" % i)
        # 셋 다 완주한다. J = makespan + w_E*energy (w_E ~ 2.56e-6).
        rows.append(dict(base, macro=0, complete=True, closed=289, makespan=24.0, energy_J=120000.0))
        rows.append(dict(base, macro=1, complete=True, closed=289, makespan=22.6, energy_J=118000.0))
        rows.append(dict(base, macro=8, complete=True, closed=289, makespan=20.0, energy_J=115000.0))
    for i in range(9):
        base = dict(kind="battery", severity=0.05, soc=0.02, spare_count=1,
                    agent_pending=8, progress=0.30, n_active=10, n_spare_cfg=1,
                    closed_at_fire=90, total=289, total_nodes=289,
                    zone_overlap=None, zone_radius=None,
                    valid_mask=[0, 1, 8], instance="x%d" % i)
        rows.append(dict(base, macro=0, complete=False, closed=210, makespan=70.0, energy_J=99000.0))
        rows.append(dict(base, macro=1, complete=True, closed=289, makespan=31.0, energy_J=126000.0))
        rows.append(dict(base, macro=8, complete=True, closed=289, makespan=29.0, energy_J=124000.0))
    return rows


def check_completing_fixture():
    """두 팔이 둘 다 완주할 때 결정 규칙이 진짜 J 차이를 지키는가."""
    print("\n== SurrogateV2: 둘 다 완주하는 팔 (조립식 증폭 회귀) ==")
    rows = synth_completing()
    m = SurrogateV2().fit(rows)
    all_complete = [r for r in rows if r["instance"].startswith("c")]
    ids = ["c%d" % i for i in range(36)]

    # 1) 신호가 헤드 B 에 있는가 — 여기서 틀리면 조립식 문제가 아니라 회귀 문제다.
    b = m.predict_B(all_complete)
    b_pick = []
    for i in ids:
        idx = [k for k, r in enumerate(all_complete) if r["instance"] == i]
        b_pick.append(all_complete[idx[int(np.argmin(b[idx]))]]["macro"])
    n_b8 = sum(1 for x in b_pick if x == 8)
    check("헤드 B 단독이 SwapBattery(8) 를 고른다", n_b8 == len(ids), "%d/%d" % (n_b8, len(ids)))

    # 2) 조립식 argmin Ĵ (기준선). 실패하면 그것이 바로 재현된 결함이다 — 숨기지 않는다.
    pick_j = m.choose(all_complete, rule="argmin_jhat")
    n_j8 = sum(1 for i in ids if pick_j[i] == 8)
    print("  INFO  기준선 argmin Ĵ 가 8 을 고른 횟수: %d/%d   (분포 %s)"
          % (n_j8, len(ids), sorted(set(pick_j.values()))))

    # 3) 2단 규칙(deadband_B): P̂ 차이가 교정 오차 안이면 B̂ 가 결정한다.
    pick_d = m.choose(all_complete, rule="deadband_B")
    n_d8 = sum(1 for i in ids if pick_d[i] == 8)
    check("2단 규칙(deadband_B)이 SwapBattery(8) 를 고른다", n_d8 == len(ids),
          "%d/%d" % (n_d8, len(ids)))

    # 4) 두 규칙이 갈리는지 자체를 기록한다 — 갈리지 않으면 이 픽스처는 결함을 못 잡는 것이고
    #    그 사실을 알아야 한다(조용히 통과하면 항목 4 의 지적이 그대로 남는다).
    print("  INFO  두 규칙이 서로 다른 답을 낸 instance: %d/%d"
          % (sum(1 for i in ids if pick_j[i] != pick_d[i]), len(ids)))


class _Fixed:
    """`.predict(X)` 가 미리 정한 벡터를 그대로 내는 가짜 헤드."""

    def __init__(self, v):
        self.v = np.asarray(v, dtype=float)

    def predict(self, X):
        return self.v


class _StubHeads(SurrogateV2):
    """헤드 출력만 실측값으로 고정한 스텁. **조립식은 상속받은 진짜 코드를 그대로 탄다.**

    학습을 끼우지 않는 이유: 적합된 트리로 이 결함을 재현하려면 특징 충돌을 인위적으로
    설계해야 하고, 그러면 "실패하도록 만든 픽스처"가 된다. 여기서 검사하려는 것은 학습이
    아니라 **조립식의 증폭 그 자체**이므로 헤드 출력을 실측 수치로 고정하는 편이 정직하다.
    """

    def __init__(self, p, b):
        SurrogateV2.__init__(self)
        self._p = np.asarray(p, dtype=float)
        self.head_b = _Fixed(b)
        self._fitted_b, self._fitted_c = True, False
        self._c_fallback = 0.0

    def predict_complete_proba(self, rows):
        return self._p


def check_assembly_amplification():
    """dĴ/dP 증폭: 1%p 짜리 P̂ 잡음이 몇 J 짜리 진짜 차이를 뒤집는가 (2026-08-14 근본원인)."""
    print("\n== 조립식 증폭 (근본원인 회귀) ==")
    # 독립 검증 실측 규모를 그대로 쓴다: P 격차 1%p, B 격차 0.6 J. B 가 작은 8 이 정답이다.
    rows = [dict(instance="a", macro=1, valid_mask=[1, 8], kind="battery", soc=0.1,
                 agent_pending=4, n_active=10, spare_count=3, progress=0.4,
                 closed_at_fire=130, total_nodes=289, zone_overlap=None),
            dict(instance="a", macro=8, valid_mask=[1, 8], kind="battery", soc=0.1,
                 agent_pending=4, n_active=10, spare_count=3, progress=0.4,
                 closed_at_fire=130, total_nodes=289, zone_overlap=None)]
    m = _StubHeads(p=[0.96, 0.95], b=[22.6, 22.0])

    J = m.predict_J(rows)
    check("1%p 짜리 P̂ 격차가 Ĵ 를 수십 J 이상 움직인다(증폭이 실재한다)",
          abs(J[0] - J[1]) > 50.0, "ΔĴ=%.2f  (진짜 ΔJ=0.60)" % (J[0] - J[1]))
    check("증폭의 부호가 진짜 J 를 **뒤집는다** (Ĵ 는 1 이 낫다고 말한다)",
          J[0] < J[1], "Ĵ(1)=%.2f Ĵ(8)=%.2f" % (J[0], J[1]))

    pick_j = m.choose(rows, rule="argmin_jhat")["a"]
    check("기준선 argmin Ĵ 는 **틀린** 팔(Replace=1)을 고른다 — 재현된 결함", pick_j == 1,
          "picked=%d" % pick_j)

    pick_d = m.choose(rows, rule="deadband_B")["a"]
    check("2단 규칙(deadband_B)은 옳은 팔(SwapBattery=8)을 고른다 — 교정됨", pick_d == 8,
          "picked=%d" % pick_d)

    # 교정 오차보다 **큰** P̂ 격차는 살아남아야 한다 — deadband 가 P 를 통째로 무시하면 안 된다.
    m2 = _StubHeads(p=[0.96, 0.50], b=[22.6, 22.0])
    pick_big = m2.choose(rows, rule="deadband_B")["a"]
    check("deadband 는 교정 오차보다 큰 P̂ 격차는 존중한다(P 를 버리는 게 아니다)",
          pick_big == 1, "picked=%d (P 격차 0.46)" % pick_big)


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

    check_completing_fixture()
    check_assembly_amplification()

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
