#!/usr/bin/env python
"""assimilation_gate.py -- "이 (상태클러스터, 새 행동) 을 배울 가치가 있는가" 판정기 (C2).

왜 게이트가 필요한가
--------------------
새 행동을 배우려면 라벨링 예산을 써야 한다: |A ∪ {a_new}| × K 시뮬. 한 판이 십수 분이므로
아무거나 배우면 밤 하나가 통째로 사라진다. 그리고 라이브러리를 무분별하게 키우면 쓰레기가
쌓인다는 것은 스킬 라이브러리 연구들의 공통된 교훈이다(Voyager 의 자기검증, LiLO 의 압축·
문서화 후 편입). 그래서 **편입은 기본이 아니라 예외**여야 하고, 조건을 명시적으로 건다.

세 조건을 **모두** 만족해야 예산을 쓴다 (PLAN_ACTION_GROWTH.md §4 [6])

  1. 재발 가능성  : 같은 상태 클러스터가 m >= m_min 회 관측됐다
                    (일회성 사건에 예산을 쓰면 다시 만날 일이 없다)
  2. 결정 관련성  : 그 클러스터에서 팔 사이 결과가 실제로 갈린다 (= 동점이 아니다)
                    <- F-축에서 지금 겪고 있는 "동점 85%" 와 정확히 같은 기준
  3. 신규성       : ψ(a_new) 가 기존 행동집합에서 충분히 멀다
                    <- 조합폭발(R2)을 막는 유일한 장치. 느슨하면 행동집합이 중복으로 찬다

각 조건은 **왜 떨어졌는지**를 남긴다. 떨어진 이유가 "아직 한 번밖에 못 봤다"인지
"동점이라 배울 게 없다"인지는 완전히 다른 후속 조치를 뜻하기 때문이다.

실행(자체 검사)
    python assimilation_gate.py
"""
import os, sys, json, math
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from features_agnostic import psi, PSI_AXES

HERE = os.path.dirname(os.path.abspath(__file__))

# ψ 축별 스케일. 거리를 재기 전에 축을 정규화해야 한다 -- a_cost(0~3)와 a_scope(0~3)와
# 0/1 이진축을 그냥 유클리드로 재면 연속축이 거리를 지배한다.
_PSI_SCALE = {"a_cost": 3.0, "a_n_specs": 3.0, "a_scope": 3.0}


def psi_vec(action):
    d = psi(action)
    return np.array([float(d[k]) / _PSI_SCALE.get(k, 1.0) for k in PSI_AXES], float)


def psi_distance(a, b):
    """두 행동의 ψ 거리(정규화 유클리드)."""
    return float(np.linalg.norm(psi_vec(a) - psi_vec(b)))


@dataclass
class ClusterStats:
    """한 상태 클러스터에 대해 관측된 것들."""
    key: str
    n_seen: int = 0                          # 이 클러스터를 몇 번 만났는가
    # 결정 관련성 증거: 이 클러스터에서 관측된 팔별 결과들 {action_key: [비용, ...]}
    arm_costs: Dict[str, List[float]] = field(default_factory=dict)

    def observe(self, action_key: str, cost: float):
        self.arm_costs.setdefault(action_key, []).append(float(cost))

    def spread(self):
        """팔 사이 평균비용의 상대 격차. 팔이 하나뿐이면 판단 불가(None)."""
        means = {k: float(np.mean(v)) for k, v in self.arm_costs.items() if v}
        if len(means) < 2:
            return None, means
        lo, hi = min(means.values()), max(means.values())
        denom = max(abs(lo), 1e-9)
        return (hi - lo) / denom, means


@dataclass
class GateVerdict:
    admit: bool
    reasons: Dict[str, Any]

    def why_not(self):
        return [k for k, v in self.reasons.items() if isinstance(v, dict) and not v.get("pass")]


class AssimilationGate:
    def __init__(self, m_min: int = 2, spread_min: float = 0.05,
                 novelty_min: float = 0.35, se_mult: float = 2.0,
                 log_path: str = "artifacts_mdp/assimilation_gate_log.jsonl"):
        """
        m_min       : 재발 최소 횟수
        spread_min  : 팔 사이 상대 격차 최소값 (동점 판정 기준)
        novelty_min : 기존 행동집합까지의 최소 ψ 거리
        se_mult     : 격차가 표준오차의 몇 배 이상이어야 '실제 격차'로 볼지
                      (MC 노이즈를 격차로 오인하면 안 된다 -- STEP 6 에서 SE ≈ Q̂ 였다)
        """
        self.m_min = m_min
        self.spread_min = spread_min
        self.novelty_min = novelty_min
        self.se_mult = se_mult
        self.log_path = os.path.join(HERE, log_path) if log_path else None

    # ------------------------------------------------------------------ 조건 1
    def _recurrence(self, cl: ClusterStats):
        ok = cl.n_seen >= self.m_min
        return {"pass": bool(ok), "n_seen": cl.n_seen, "m_min": self.m_min,
                "note": None if ok else "아직 재발하지 않았다 — 예산을 쓰기엔 이르다"}

    # ------------------------------------------------------------------ 조건 2
    def _decision_relevance(self, cl: ClusterStats):
        sp, means = cl.spread()
        if sp is None:
            return {"pass": False, "spread": None, "arms": means,
                    "note": "팔이 하나뿐 — 갈리는지 알 수 없다"}
        # 노이즈 대조: 각 팔의 표준오차를 합성해 격차가 그보다 큰지 본다
        ses = []
        for v in cl.arm_costs.values():
            ses.append(np.std(v, ddof=1) / math.sqrt(len(v)) if len(v) > 1 else 0.0)
        pooled = math.sqrt(sum(s * s for s in sorted(ses)[-2:])) if len(ses) >= 2 else 0.0
        lo, hi = min(means.values()), max(means.values())
        sig = (hi - lo) > self.se_mult * pooled if pooled > 0 else (hi - lo) > 0
        ok = bool(sp >= self.spread_min and sig)
        note = None
        if not ok:
            note = ("팔 사이 결과가 사실상 같다(동점) — 배워도 결정이 안 바뀐다"
                    if sp < self.spread_min else "격차가 MC 노이즈 안에 있다")
        return {"pass": ok, "spread": sp, "significant": bool(sig),
                "pooled_se": pooled, "arms": means, "note": note}

    # ------------------------------------------------------------------ 조건 3
    def _novelty(self, a_new, known: Sequence):
        if not known:
            return {"pass": True, "min_dist": None, "note": "기존 행동집합이 비어 있다"}
        dists = {str(k): psi_distance(a_new, k) for k in known}
        nearest = min(dists, key=dists.get)
        d = dists[nearest]
        ok = d >= self.novelty_min
        return {"pass": bool(ok), "min_dist": d, "nearest": nearest,
                "novelty_min": self.novelty_min,
                "note": None if ok else f"{nearest} 와 사실상 같은 행동 — 중복 편입"}

    # ------------------------------------------------------------------ 진입점
    def evaluate(self, cluster: ClusterStats, a_new, known_actions: Sequence,
                 meta: Optional[dict] = None) -> GateVerdict:
        reasons = {
            "recurrence": self._recurrence(cluster),
            "decision_relevance": self._decision_relevance(cluster),
            "novelty": self._novelty(a_new, known_actions),
        }
        admit = all(r["pass"] for r in reasons.values())
        reasons["labeling_cost_sims"] = (len(known_actions) + 1) * 3 if admit else 0
        v = GateVerdict(admit, reasons)
        self._log(cluster, a_new, v, meta or {})
        return v

    def _log(self, cluster, a_new, v, meta):
        if not self.log_path:
            return
        try:
            os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"cluster": cluster.key, "action": str(a_new),
                                     "admit": v.admit, "reasons": v.reasons, "meta": meta},
                                    ensure_ascii=False, default=str) + "\n")
        except Exception:
            pass


# ==========================================================================================
#  자체 검사 -- 합성 스트림 10건 중 통과해야 하는 것만 통과하는가
# ==========================================================================================
def _selftest():
    # ★ 구세대 어휘 (2026-08-09 표시). action_registry.json 은 2026-08-06 부터 7·8 을 포함한다.
    #   audit_action_vocab.py 검사 대상이 아니라 6/6 통과에 안 잡힌다. 자체 검사용 고정 입력이라
    #   동작에는 영향이 없지만, "현재 행동집합 = 5매크로"라는 아래 주석은 더 이상 사실이 아니다.
    known = [0, 1, 2, 3, 4]          # (구) 5매크로
    gate = AssimilationGate(log_path=None)

    def cl(key, n, arms):
        c = ClusterStats(key, n_seen=n)
        for a, costs in arms.items():
            for x in costs:
                c.observe(a, x)
        return c

    cases = [
        # (설명, 클러스터, 새 행동, 통과해야 하는가)
        ("통과: 재발2 + 갈림 + 신규조합",
         cl("caploss@low_soc", 3, {"noop": [26000, 26000], "combo": [40, 44]}),
         ["ForbidAgent", "ReformTeam"], True),
        ("탈락(재발): 처음 본 사건",
         cl("caploss@rare", 1, {"noop": [26000], "combo": [40]}),
         ["ForbidAgent", "ReformTeam"], False),
        ("탈락(동점): 팔이 갈리지 않음",
         cl("zone@harmless", 5, {"noop": [17600, 17600], "combo": [17600, 17600]}),
         ["ForbidAgent", "ReformTeam"], False),
        ("탈락(신규성): 이미 있는 Replace 와 같음",
         cl("fault@spare", 4, {"noop": [26000, 26000], "replace": [20, 22]}),
         ["ReplaceAgent"], False),
        ("탈락(노이즈): 격차가 표준오차 안",
         cl("battery@mid", 4, {"noop": [1000, 26000], "combo": [900, 25000]}),
         ["ForbidAgent", "ReformTeam"], False),
        ("통과: 다른 신규 조합",
         cl("caploss@manip", 2, {"noop": [26000, 25800], "combo": [55, 58]}),
         ["DeprioritizeAgent", "ForbidWindow"], True),
        ("탈락(팔 하나): 대안이 관측 안 됨",
         cl("caploss@solo", 3, {"combo": [40, 41]}),
         ["ForbidAgent", "ReformTeam"], False),
    ]

    print("편입 판정기 자체 검사")
    npass = 0
    for desc, c, a, expect in cases:
        v = gate.evaluate(c, a, known)
        ok = (v.admit == expect)
        npass += ok
        why = ",".join(v.why_not()) or "-"
        print(f"  [{'OK ' if ok else 'FAIL'}] {desc:<34} 기대={'편입' if expect else '거부'}"
              f"  실제={'편입' if v.admit else '거부'}  탈락조건={why}")

    # ψ 거리 표 -- 신규성 임계값이 말이 되는지 눈으로 확인
    print("\n  기존 5매크로에 대한 ψ 거리 (신규성 임계 %.2f)" % gate.novelty_min)
    for a in (["ReplaceAgent"], ["ForbidAgent", "ReformTeam"],
              ["DeprioritizeAgent", "ForbidWindow"], ["ReplaceAgent", "ForbidZone"]):
        ds = {m: round(psi_distance(a, m), 3) for m in known}
        near = min(ds, key=ds.get)
        print(f"    {str(a):<46} 최근접 macro {near} (d={ds[near]:.3f})  {ds}")

    print(f"\n  {npass}/{len(cases)} 통과")
    return npass == len(cases)


if __name__ == "__main__":
    sys.exit(0 if _selftest() else 1)
