#!/usr/bin/env python
"""steering.py -- blend an LLM steering vector into the surrogate's score landscape.

See md/DESIGN_STEERING.md.  Short version: the LLM does not name a macro, it returns a DIRECTION
in action space, and that direction nudges the surrogate's own scores:

    score(a) = norm(Q̂(s, a)) + β(c) · steer(a)

`steer(a)` is either
    L2 (implemented) : u[a]                       -- a utility per macro
    L3 (schema ready): <w, φ(a)>                  -- a preference over the 6 ACTION_DESCRIPTORS,
                                                     which also applies to macros never scored before

WHY NORMALISE Q̂ FIRST
=====================
Q̂ is in closed-node units (tens); a steering term is O(1).  Adding them raw makes β mean something
different in every instance, so a β tuned on one event is nonsense on the next.  The blender
min-max normalises Q̂ across the instance's VALID macros first.  Then β = 0.5 reads as "the LLM may
move a decision by half the width of the surrogate's own spread" -- the same sentence in every
instance.

WHY β STARTS AT ZERO
====================
β > 0 with an uncalibrated confidence actively damages a surrogate that is already good on known
kinds.  `beta_sweep()` therefore always includes 0.0, and β = 0 winning is a real result, not a
failure of the experiment.  Do not report a tuned β without the sweep beside it.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
LLM 이 '정답 매크로'를 지목하는 대신 **행동공간의 방향 벡터**를 내고, 그걸로 surrogate 점수
지형을 밀어 준다.

  score(a) = 정규화된 Q̂(s,a) + β(c) · steer(a)

Q̂ 를 먼저 정규화하는 이유: Q̂ 는 닫은노드 단위(수십), steering 은 O(1) 이라 그냥 더하면 β 의
의미가 instance 마다 달라진다. valid 매크로들 안에서 min-max 로 맞추면 β=0.5 가 "surrogate 자기
점수 폭의 절반만큼 움직일 수 있다"로 어디서나 같은 뜻이 된다.

β 는 반드시 0 부터 훑는다. 확신도가 교정 안 된 상태에서 β 를 키우면, 아는 종류에서 이미 잘하던
surrogate 를 망친다. β=0 이 이기는 것도 정직한 결과다.

[문법 참고]
  · @dataclass        — 값 묶음 클래스를 간단히 정의
  · float("nan")      — 결측을 0 과 구분해서 표현(0 과 '없음'은 다르다)
────────────────────────────────────────────────────────────────────────────────────────────
"""
import os
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from features_agnostic import ACTION_DESCRIPTORS, action_descriptors

MACRO_NAMES = ["NOOP", "Replace", "Deprioritize", "ForbidZone", "ReformTeam"]

#: β 후보. 0.0 이 반드시 포함된다(위 주석 참조).
BETA_GRID = (0.0, 0.1, 0.25, 0.5, 1.0)


# ==========================================================================================
#  LLM 이 돌려주는 것
# ==========================================================================================
@dataclass
class SteeringVector:
    """LLM 한 번의 응답. u 와 w 를 **둘 다** 싣고, 지금은 u 만 소비한다.

    u          매크로별 효용 5개 (L2, 지금 쓰는 것)
    w          행동 서술자 6축 선호 (L3, 스키마만 준비. 미지 매크로에도 적용 가능)
    confidence 0~1 자기보고 확신도. β 를 정하는 입력이지 결정을 정하는 값이 아니다.
    rationale  사람이 읽을 근거(UI·감사용). 결정에 절대 관여하지 않는다.
    valid      스키마 검증 통과 여부
    problems   무엇이 잘못됐는지(견고성 지표 집계용)
    """

    u: np.ndarray = field(default_factory=lambda: np.zeros(len(MACRO_NAMES)))
    w: np.ndarray = field(default_factory=lambda: np.zeros(len(ACTION_DESCRIPTORS)))
    confidence: float = 0.0
    rationale: str = ""
    valid: bool = False
    problems: tuple = ()

    def steer_l2(self, macro):
        return float(self.u[int(macro)])

    def steer_l3(self, macro):
        phi = action_descriptors(int(macro))
        return float(np.dot(self.w, [phi[k] for k in ACTION_DESCRIPTORS]))


def parse_steering(payload, level="L2"):
    """LLM 원응답(dict) -> SteeringVector. **실패를 조용히 넘기지 않는 것**이 이 함수의 일이다.

    견고성 지표(schema_valid_rate 등)는 전부 여기서 모은 problems 로 계산된다. 그래서 파싱
    실패를 예외로 던져 버리면 지표가 사라진다 -- 대신 valid=False 인 벡터를 돌려주고 이유를 남긴다.
    """
    problems = []
    u = np.zeros(len(MACRO_NAMES))
    w = np.zeros(len(ACTION_DESCRIPTORS))
    conf = 0.0

    if not isinstance(payload, dict):
        return SteeringVector(problems=("not_a_dict",))

    raw_u = payload.get("u")
    if isinstance(raw_u, (list, tuple)) and len(raw_u) == len(MACRO_NAMES):
        try:
            u = np.asarray([float(x) for x in raw_u], dtype=float)
        except (TypeError, ValueError):
            problems.append("u_not_numeric")
    else:
        problems.append("u_missing_or_wrong_length")

    raw_w = payload.get("w")
    if isinstance(raw_w, (list, tuple)) and len(raw_w) == len(ACTION_DESCRIPTORS):
        try:
            w = np.asarray([float(x) for x in raw_w], dtype=float)
        except (TypeError, ValueError):
            problems.append("w_not_numeric")
    elif level == "L3":
        problems.append("w_missing_or_wrong_length")

    try:
        conf = float(payload.get("confidence", 0.0))
        if not (0.0 <= conf <= 1.0):
            problems.append("confidence_out_of_range")
            conf = float(np.clip(conf, 0.0, 1.0))
    except (TypeError, ValueError):
        problems.append("confidence_not_numeric")

    if not np.all(np.isfinite(u)) or not np.all(np.isfinite(w)):
        problems.append("non_finite_values")
        u = np.nan_to_num(u)
        w = np.nan_to_num(w)

    need = ("u_missing_or_wrong_length", "u_not_numeric") if level == "L2" else \
           ("w_missing_or_wrong_length", "w_not_numeric")
    ok = not any(p in problems for p in need)
    return SteeringVector(u=u, w=w, confidence=conf,
                          rationale=str(payload.get("rationale", ""))[:500],
                          valid=ok, problems=tuple(problems))


# ==========================================================================================
#  β
# ==========================================================================================
def beta_from_confidence(c, beta_max=0.5, calib=None):
    """확신도 -> 조향 강도.

    calib 는 확신도 -> 실제 정확도 보정 함수(없으면 항등). LLM 의 자기보고 확신도는 보통 과신이라,
    교정 없이 그대로 쓰면 β 가 필요 이상으로 커진다. confidence_ece 가 나쁘면 beta_max=0 으로 둔다.
    """
    c = float(np.clip(c, 0.0, 1.0))
    if calib is not None:
        c = float(np.clip(calib(c), 0.0, 1.0))
    return float(beta_max) * c


# ==========================================================================================
#  혼합
# ==========================================================================================
def normalize_q(q_by_macro, valid):
    """valid 매크로들 안에서 Q̂ 를 [0,1] 로. 폭이 0이면 전부 0.5(정보 없음)로 둔다."""
    ms = [m for m in q_by_macro if m in valid] or list(q_by_macro)
    v = np.asarray([q_by_macro[m] for m in ms], dtype=float)
    lo, hi = float(v.min()), float(v.max())
    if hi - lo < 1e-12:
        return {m: 0.5 for m in ms}
    return {m: (float(q_by_macro[m]) - lo) / (hi - lo) for m in ms}


def blend(q_by_macro, steering, valid, beta, level="L2"):
    """최종 점수와 선택.

    반환 (chosen_macro, scores, info)
      info.switched  β 때문에 surrogate 단독과 다른 답이 됐는가 -- steering 이 실제로 한 일의 양
    """
    valid = set(int(m) for m in valid) or set(q_by_macro)
    qn = normalize_q(q_by_macro, valid)
    base = max(qn, key=qn.get)

    step = steering.steer_l3 if level == "L3" else steering.steer_l2
    scores = {m: qn[m] + float(beta) * step(m) for m in qn}
    chosen = max(scores, key=scores.get)
    return chosen, scores, {"base_choice": base, "switched": chosen != base, "beta": float(beta)}


def beta_sweep(grid=BETA_GRID):
    """β 후보. 0.0 이 없으면 넣어 준다 -- 기준선 없는 스윕은 결론을 못 낸다."""
    g = tuple(float(b) for b in grid)
    return g if 0.0 in g else (0.0,) + g


# ==========================================================================================
#  견고성 지표 (DSPy 의 실제 평가 대상)
# ==========================================================================================
def robustness_report(vectors, demoted_to_noop=0, retries=0):
    """SteeringVector 목록 -> DSPy 를 판정할 지표들.

    silent_noop_rate 를 왜 따로 받나: 유효하지 않은 매크로를 NOOP 로 강등하는 일이 dspy_service 의
    VALID 게이트에서 **로그 없이** 일어난다. 그러면 불법 행동을 지목하는 producer 가 얌전해 보인다.
    호출자가 그 횟수를 세어 넘겨야 지표가 성립한다.
    """
    n = max(len(vectors), 1)
    prob_counts = {}
    for v in vectors:
        for p in v.problems:
            prob_counts[p] = prob_counts.get(p, 0) + 1
    return {
        "n": len(vectors),
        "schema_valid_rate": sum(1 for v in vectors if v.valid) / n,
        "silent_noop_rate": demoted_to_noop / n,
        "retry_per_decision": retries / n,
        "mean_confidence": float(np.mean([v.confidence for v in vectors])) if vectors else float("nan"),
        "problems": dict(sorted(prob_counts.items(), key=lambda kv: -kv[1])),
    }


def confidence_ece(confidences, correct, bins=5):
    """Expected Calibration Error. β 를 0 위로 올려도 되는지의 게이트.

    확신도를 구간별로 묶어 '평균 확신도'와 '실제 정확도'의 차이를 가중평균한다. 0 에 가까울수록
    잘 교정됨. 크면 beta_max=0 으로 둬야 한다(과신한 조향은 해롭다).
    """
    c = np.asarray(confidences, dtype=float)
    y = np.asarray(correct, dtype=float)
    if c.size == 0:
        return float("nan")
    edges = np.linspace(0.0, 1.0, bins + 1)
    ece = 0.0
    for i in range(bins):
        m = (c >= edges[i]) & (c < edges[i + 1] if i < bins - 1 else c <= edges[i + 1])
        if not m.any():
            continue
        ece += (m.sum() / c.size) * abs(y[m].mean() - c[m].mean())
    return float(ece)


if __name__ == "__main__":
    print("ACTION_DESCRIPTORS:", ACTION_DESCRIPTORS)
    print()

    good = {"u": [0.0, 0.9, 0.2, 0.0, 0.0],
            "w": [0.2, 0.8, 0.0, 0.9, 0.0, 0.0],
            "confidence": 0.8,
            "rationale": "capacity loss with a spare available"}
    sv = parse_steering(good)
    print("parse(good)  valid=%s conf=%.2f problems=%s" % (sv.valid, sv.confidence, sv.problems))

    bad = {"u": [0.1, "oops", 0.2], "confidence": 3.0}
    sb = parse_steering(bad)
    print("parse(bad)   valid=%s conf=%.2f problems=%s" % (sb.valid, sb.confidence, sb.problems))
    print()

    q = {0: 12.0, 1: 11.4, 2: 11.0}          # surrogate prefers NOOP, narrowly
    valid = {0, 1, 2}
    print("surrogate Q:", q, " -> normalised:", {k: round(v, 3) for k, v in normalize_q(q, valid).items()})
    for b in beta_sweep():
        ch, sc, info = blend(q, sv, valid, b)
        print("  beta=%.2f -> %-13s switched=%-5s scores=%s"
              % (b, MACRO_NAMES[ch], info["switched"],
                 {MACRO_NAMES[k]: round(v, 3) for k, v in sc.items()}))
    print()
    print("robustness:", robustness_report([sv, sb], demoted_to_noop=1, retries=3))
    print("ECE(perfect):", confidence_ece([0.9, 0.9, 0.1, 0.1], [1, 1, 0, 0]))
    print("ECE(overconfident):", confidence_ece([0.9, 0.9, 0.9, 0.9], [1, 0, 0, 0]))
