#!/usr/bin/env python3
"""배포 서비스(`dspy_service.surrogate_rank`)의 **부호 방향**과 feature 조립 계약.

왜 이 파일이 존재하는가 (2026-08-14, Task 7)
=============================================
`SurrogateV2.predict_delta_J` 의 규약은 **낮을수록 좋다**(ΔĴ = Ĵ(a) − Ĵ(NOOP)).
그런데 이 서비스의 기존 순위 코드는 `scored.sort(key=lambda t: -t[1])` 로 **내림차순**이었다
(옛 모델의 타깃이 `closed − λ·MACRO_COST` = 높을수록 좋음이었기 때문). 부호를 뒤집지 않고
새 모델을 꽂으면 서비스는 **legal 팔 중 가장 나쁜 것**을 고른다 — 에러도 경고도 없이,
성능으로만 샌다. 그 한 줄이 이 태스크에서 가장 위험한 지점이므로 주장이 아니라 검사로 못박는다.

두 번째 계약: 배포는 학습과 **같은 22차원 조립기**(`surrogate_features.build_features`)를
써야 한다. 학습/배포 조립기가 조용히 갈리는 것은 이 저장소의 반복된 사고다(CLAUDE.md).
그래서 "서비스가 만든 행"과 "라벨 행"이 같은 feature 벡터를 내는지 직접 대조한다.
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "src", "respec", "llm_service"))

import dspy_service as S                                       # noqa: E402
from surrogate_features import FEATURE_NAMES, build_features   # noqa: E402

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


class StubModel:
    """ΔĴ 를 macro -> 상수로 돌려주는 가짜 모델. 부호 방향만 시험한다.

    `pick` 을 따로 받는 이유: 배포 규칙 `deadband_Jbar` 는 argmin ΔĴ 와 **일치할 의무가 없다**
    (완주확률이 교정오차 밖인 팔을 먼저 떨어내므로). 그래서 "순위 1위 = 규칙이 고른 팔",
    "나머지는 ΔĴ 오름차순" 이라는 두 계약을 따로 시험할 수 있어야 한다.
    """

    def __init__(self, dj, pick=None):
        self.dj = dj
        self.pick = pick
        self.rule_seen = None

    def predict_delta_J(self, rows, ref_macro=0):
        return np.array([float(self.dj[int(r["macro"])]) for r in rows], dtype=float)

    def choose(self, rows, rule=None):
        self.rule_seen = rule
        m = self.pick if self.pick is not None else min(
            (int(r["macro"]) for r in rows), key=lambda k: self.dj[k])
        return {r["instance"]: int(m) for r in rows}


def _req(**kw):
    base = dict(kind="battery", severity=0.10, soc=0.10, spare_count=3, agent_pending=1,
                progress=0.4, n_active=4, closed_at_fire=58, total_nodes=289)
    base.update(kw)
    return S.MacroRequest(**base)


def _install(model, support):
    S._state["surrogate"] = model
    S._state["surro_support"] = set(support)
    S._state["surro_error"] = None


print("== 배포 서비스 순위의 부호 방향 ==")

# ---- 1. ΔĴ 오름차순이다 (낮을수록 좋다) ------------------------------------------------
# 이것이 내림차순이면 서비스는 정확히 최악의 팔을 고른다.
stub = StubModel({0: 0.0, 1: +5.0, 8: -7.0})
_install(stub, {0, 1, 8})
valid = ["NOOP", "Replace", "SwapBattery"]
scored, err = S.surrogate_rank(_req(), valid)
check("에러 없이 순위가 나온다", scored is not None and err is None, "err=%r" % (err,))
if scored:
    names = [m for m, _ in scored]
    vals = [s for _, s in scored]
    check("1위가 ΔĴ 최소인 팔이다", names[0] == "SwapBattery", "ranking=%s" % names)
    check("점수가 오름차순이다(낮을수록 좋음)", vals == sorted(vals), "scores=%s" % vals)
    check("1위 점수 <= 꼴찌 점수 (부호 가드)", vals[0] <= vals[-1], "%s vs %s" % (vals[0], vals[-1]))
    check("모든 legal 팔이 순위에 있다", set(names) == set(valid), "ranking=%s" % names)
check("배포 규칙이 deadband_Jbar 다", stub.rule_seen == "deadband_Jbar",
      "rule=%r" % (stub.rule_seen,))

# ---- 2. 결정은 규칙이 낸다 — 순위 1위는 argmin ΔĴ 가 아니라 규칙의 답 ---------------------
# `deadband_Jbar` 는 완주확률이 낮은 팔을 먼저 떨어내므로 argmin ΔĴ 와 갈릴 수 있다.
# 그때 서비스가 규칙을 무시하고 argmin 을 내보내면 배포된 정책이 평가한 정책과 달라진다.
stub2 = StubModel({0: 0.0, 1: +5.0, 8: -7.0}, pick=1)
_install(stub2, {0, 1, 8})
scored2, _ = S.surrogate_rank(_req(), valid)
if scored2:
    names2 = [m for m, _ in scored2]
    vals2 = [s for _, s in scored2]
    check("1위 = 규칙이 고른 팔(argmin 이 아니어도)", names2[0] == "Replace", "ranking=%s" % names2)
    check("나머지는 ΔĴ 오름차순", vals2[1:] == sorted(vals2[1:]), "scores=%s" % vals2)

# ---- 3. support 기반 후보 탈락 + UNSUPPORTED 규약이 그대로다 -----------------------------
_install(StubModel({0: 0.0, 1: +5.0}), {0, 1})     # macro 4(ReformTeam) 학습 근거 없음
scored3, err3 = S.surrogate_rank(_req(kind="reform"), ["NOOP", "ReformTeam"])
check("지원 밖 팔은 UNSUPPORTED 로 보고된다",
      isinstance(err3, str) and err3.startswith("UNSUPPORTED:") and "ReformTeam" in err3,
      "err=%r" % (err3,))
check("지원 밖 팔은 순위에서 빠진다",
      scored3 is not None and [m for m, _ in scored3] == ["NOOP"],
      "ranking=%s" % ([m for m, _ in (scored3 or [])],))

# ---- 4. 점수 낼 팔이 하나도 없으면 None + 사유 (기존 규약 그대로) --------------------------
_install(StubModel({}), {7})
scored4, err4 = S.surrogate_rank(_req(kind="reform"), ["ReformTeam"])
check("점수 가능한 팔이 없으면 None 과 사유",
      scored4 is None and isinstance(err4, str) and "no training support" in err4,
      "err=%r" % (err4,))

# ---- 5. 학습/배포 조립기가 같다 ----------------------------------------------------------
# 서비스가 만든 행과 **같은 상태를 담은 라벨 행**이 바이트 동일한 feature 벡터를 내야 한다.
# (dspy_service 가 build_features 를 재구현하면 여기서 갈린다.)
print("== 학습/배포 feature 조립기 동일성 ==")
label_row = dict(macro=8, severity=0.10, soc=0.10, zone_overlap=-1.0, agent_pending=1,
                 n_active=4, spare_count=3, closed_at_fire=58, total_nodes=289, progress=0.4)
svc_row = S._surro_row(_req(), 8)
fs = build_features([svc_row]).values
fl = build_features([label_row]).values
check("서비스 행 == 라벨 행 (22차원 전부)", np.array_equal(fs, fl),
      "max|Δ|=%s" % (float(np.max(np.abs(fs - fl))) if fs.shape == fl.shape else "shape"))
check("feature 폭이 FEATURE_NAMES 와 같다", fs.shape[1] == len(FEATURE_NAMES),
      "%d vs %d" % (fs.shape[1], len(FEATURE_NAMES)))

# total_nodes 가 없으면 closed_at_fire/progress 로 복원한다(= ood_features 의 progress 정의).
svc_row_nt = S._surro_row(_req(total_nodes=None), 8)
check("total_nodes 미전달 시 closed/progress 로 복원",
      math.isclose(svc_row_nt["total_nodes"], 145.0, rel_tol=1e-9),
      "total_nodes=%s" % svc_row_nt["total_nodes"])

# soc 가 없는 사건(fault)은 NaN 이어야 한다 — -1 로 채우면 descriptors 가 kind 를 되읽는다.
check("soc 없는 사건은 NaN", math.isnan(S._surro_row(_req(kind="fault", soc=None), 1)["soc"]))

print("\n%s" % ("전부 통과" if not FAILED else "%d개 실패" % FAILED))
sys.exit(1 if FAILED else 0)
