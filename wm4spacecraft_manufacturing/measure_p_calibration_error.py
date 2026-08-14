#!/usr/bin/env python3
"""`surrogate_v2.P_CALIBRATION_ERROR` 를 **배포되는 추정기 위에서** 다시 잰다 (2026-08-14, Task 7).

왜 다시 재는가
==============
그 상수의 정의는 "헤드 A 의 **자기 오차**보다 작은 P̂ 차이는 정보를 담고 있지 않다" 다.
그것은 **추정기의 성질**이므로 추정기가 달라지면 값도 달라진다. 현행 0.01 은 Task 6 의
out-of-fold 추정기에서 잰 값인데, 배포되는 것은 155 instance **전량**에 적합된 추정기다.
Task 7 실측: 같은 `{0,1,8}` 메뉴에서 LOIO 는 SwapBattery 10/15 를 고르고 전량 적합은
Replace 10/15 로 정확히 뒤집힌다 — P̂ 격차가 LOIO 중앙값 0.0076 에서 0.0109 로 밀리면서
0.01 문턱을 넘어가기 때문이다.

**교정(calibration)으로는 못 고친다** (실측으로 기각, Task 7 라운드 2): 교정은 단조 사상이라
P̂ 의 **수준**을 고칠 뿐 두 팔 사이의 **간격**을 줄인다는 보장이 없다. sigmoid/isotonic 둘 다
간격을 3~4배 **넓혔고** LOIO 결과를 라운드 0 결함(0/15)으로 되돌렸다. deadband 는 간격에 대한
진술이므로, 재야 할 것도 간격의 불안정성이다 — 그것이 아래 절차가 재는 바로 그 양이다.

절차 (★ 실행 **전에** 고정한다. 결과를 보고 바꾸면 그것은 측정이 아니라 게이트 맞추기다) ★
=========================================================================================
  1. 라벨셋(355행 / 155 instance)을 **instance 단위**로 복원추출한다(한 instance 의 팔들이
     흩어지면 안 된다 — 팔 간 비교가 이 측정의 대상이다). 155개를 복원추출해 B = 50 회.
     seed 고정(0).
  2. 각 재표본마다 **헤드 A 만** 다시 적합한다(교정 없음 = 배포되는 그대로).
  3. 메뉴가 `{0,1,8}` 인 battery instance 15개 각각에 대해
        Δ_{i,b} = P̂_b(Replace) − P̂_b(SwapBattery)
     를 계산한다.
  4. instance 별로 재표본 50개에 걸친 표준편차 s_i 와 중앙 90% 구간(5~95 백분위)을 낸다.
  5. **집계(결과를 보기 전에 선언한다): `P_CALIBRATION_ERROR` = 15개 s_i 의 산술평균.**
     왜 평균인가: 이 상수는 모든 결정에 적용되는 **단일 문턱**이므로, 대표값은 결정 하나당
     전형적인 불안정성, 즉 per-instance 표준편차의 평균이다. (중앙값·풀링 RMS 도 같이
     찍지만 **상수로 쓰는 것은 위에서 선언한 평균뿐이다** — 셋 중 고르지 않는다.)

  절차는 한 번만 돌린다. 나온 값이 무엇이든 그것을 쓴다. 게이트가 계속 닫혀 있어도
  다른 절차로 갈아타지 않는다(그러면 그 순간 튜닝이 된다).

사용:
    /home/chahj578/Construction_OODlayer/.venv/bin/python measure_p_calibration_error.py
"""
import os
import sys

import numpy as np
from sklearn.base import clone
from threadpoolctl import threadpool_limits

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wm_datasets                                       # noqa: E402
from eval_surrogate_v2 import load_rows                  # noqa: E402  (로딩·필터링 계약 단일 정의)
from surrogate_features import build_features            # noqa: E402
from surrogate_v2 import SurrogateV2                     # noqa: E402

B = 50                     # 재표본 수
SEED = 0                   # 고정
TARGET_MENU = (0, 1, 8)    # 노이즈 바닥을 넘는 유일한 신호가 사는 메뉴
ARM_A, ARM_B = 1, 8        # Δ = P̂(Replace) − P̂(SwapBattery)


def main():
    rows, meta = load_rows(wm_datasets.abspath(wm_datasets.RELABEL_20260814))
    by_inst = {}
    for r in rows:
        by_inst.setdefault(r["instance"], []).append(r)
    inst_ids = sorted(by_inst)

    targets = [i for i in inst_ids
               if tuple(sorted(int(r["macro"]) for r in by_inst[i])) == TARGET_MENU]
    print("== P_CALIBRATION_ERROR 재측정 (배포 추정기 = 전량 적합, 교정 없음) ==")
    print("  라벨셋      %s" % os.path.basename(meta["path"]))
    print("  행/instance %d / %d" % (meta["rows_after_fired_filter"], meta["instances"]))
    print("  대상 메뉴   %s -> instance %d개" % (list(TARGET_MENU), len(targets)))
    print("  재표본      B=%d, seed=%d, instance 단위 복원추출" % (B, SEED))
    print("  집계        per-instance 표준편차의 **산술평균** (사전 선언)")

    # 평가 대상 행렬은 한 번만 만든다(재표본과 무관하게 고정된 15 instance 의 두 팔).
    eval_rows = []
    for i in targets:
        g = {int(r["macro"]): r for r in by_inst[i]}
        eval_rows.append((i, g[ARM_A], g[ARM_B]))
    X_eval = build_features([r for _, a, b in eval_rows for r in (a, b)]).values

    rng = np.random.default_rng(SEED)
    deltas = np.zeros((len(targets), B), dtype=float)

    with threadpool_limits(limits=1):
        for b in range(B):
            picked = rng.choice(len(inst_ids), size=len(inst_ids), replace=True)
            boot = [r for k in picked for r in by_inst[inst_ids[k]]]
            y = np.array([bool(r.get("complete")) for r in boot]).astype(int)
            if len(np.unique(y)) < 2:                    # 한 클래스뿐이면 P̂ 가 상수라 무의미
                raise SystemExit("재표본 %d 이 한 클래스뿐이다 — 절차를 중단한다(조용히 넘기지 않는다)." % b)
            head = clone(SurrogateV2().head_a)           # 배포와 **같은** 미교정 헤드 A
            head.fit(build_features(boot).values, y)
            p = head.predict_proba(X_eval)[:, 1]
            deltas[:, b] = p[0::2] - p[1::2]             # (Replace, Swap) 쌍 순서 그대로

    s = deltas.std(axis=1, ddof=1)                       # instance 별 재표본 표준편차
    lo, hi = np.percentile(deltas, [5, 95], axis=1)      # instance 별 중앙 90% 구간
    mean_delta = deltas.mean(axis=1)

    print("\n  instance 별 Δ = P̂(Replace) − P̂(SwapBattery)")
    print("  %-34s %9s %9s %9s %9s" % ("instance", "mean Δ", "sd", "p5", "p95"))
    for k, (i, _, _) in enumerate(eval_rows):
        print("  %-34s %9.5f %9.5f %9.5f %9.5f" % (i, mean_delta[k], s[k], lo[k], hi[k]))

    aggregated = float(np.mean(s))                       # ★ 사전 선언한 집계
    print("\n  중앙값(참고, 미사용)        %.6f" % float(np.median(s)))
    print("  풀링 RMS(참고, 미사용)      %.6f" % float(np.sqrt(np.mean(s ** 2))))
    print("  ---------------------------------------------")
    print("  **P_CALIBRATION_ERROR = mean(s_i) = %.6f**" % aggregated)
    print("  (현행 상수 0.01 · 배포 운용점의 실측 격차 0.01346)")
    return aggregated


if __name__ == "__main__":
    main()
