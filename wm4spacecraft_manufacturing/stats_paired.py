"""stats_paired.py -- 짝지은 비교용 통계 원시함수 (2026-08-11, 20시드 검증).

이 모듈은 순수 함수만 담는다: 파일 I/O 없음, argparse 없음, 전역 상태 없음.
sign_test / wilson 은 여기서 다시 만들지 않는다 -- ood_sweep_report.py 의 것을 그대로 쓴다.
"""
import os
import sys

import numpy as np
from scipy.stats import wilcoxon as _scipy_wilcoxon

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ood_sweep_report import sign_test, wilson    # noqa: F401,E402  (재수출 -- 재구현 금지)


def holm(pvals):
    """Holm-Bonferroni 조정 p-value. 입력 순서 그대로 돌려준다.

    Bonferroni 처럼 모든 검정에 최대 계수를 곱하지 않는다 -- 순위가 낮은 검정일수록
    작은 계수를 곱하므로 검정력을 덜 잃는다. 단조성(정렬 후 비감소)을 강제한다.
    """
    n = len(pvals)
    if n == 0:
        return []
    order = sorted(range(n), key=lambda i: pvals[i])
    adj = [0.0] * n
    running = 0.0
    for rank, i in enumerate(order):
        val = pvals[i] * (n - rank)
        running = max(running, val)          # 단조성: 앞선 것보다 작아질 수 없다
        adj[i] = min(1.0, running)
    return adj


def paired_wilcoxon(a, b):
    """짝지은 Wilcoxon 부호순위 검정. a[i] 와 b[i] 는 같은 (case, ood_seed) 의 값.

    둘 중 하나라도 None 인 짝은 통째로 버린다 -- E4(완주판만 재는 빌드시간)에서
    한쪽이 완주하지 않으면 그 짝은 정의되지 않는다.
    차이가 전부 0 이면 scipy 가 예외를 던지므로 p=1.0 으로 받아낸다.
    """
    pairs = [(x, y) for x, y in zip(a, b) if x is not None and y is not None]
    n_used = len(pairs)
    out = {"n": len(a), "n_used": n_used, "statistic": None, "p": 1.0,
           "median_diff": None, "note": ""}
    if n_used == 0:
        out["note"] = "정의 불가 (짝 0개)"
        return out
    xa = np.array([p[0] for p in pairs], dtype=float)
    xb = np.array([p[1] for p in pairs], dtype=float)
    d = xa - xb
    out["median_diff"] = float(np.median(d))
    if np.all(d == 0):
        out["note"] = "전부 동점 -- 검정 불가(ceiling)"
        return out
    try:
        res = _scipy_wilcoxon(xa, xb)
        out["statistic"] = float(res.statistic)
        out["p"] = float(res.pvalue)
    except ValueError as e:                  # 표본이 너무 작거나 전부 동점인 경계
        out["note"] = "wilcoxon 실패: %s" % e
    return out


def cluster_bootstrap_ci(clusters, reps=10000, seed=0):
    """군집(=판) 단위 부트스트랩 비율 CI. 반환 (point, lo, hi).

    `clusters` 는 판마다 그 판의 결정별 정오(bool) 리스트다. 결정 하나하나를 독립으로
    보고 Wilson 을 씌우면(shadow_score.py:133 의 기존 방식) 같은 판 안의 결정이 서로
    상관돼 있다는 사실을 무시해 구간이 실제보다 좁게 나온다. 여기서는 결정이 아니라
    **판**을 복원추출한다.
    """
    clusters = [c for c in clusters if len(c) > 0]
    if not clusters:
        return (0.0, 0.0, 0.0)
    n_correct = sum(sum(1 for v in c if v) for c in clusters)
    n_total = sum(len(c) for c in clusters)
    point = n_correct / n_total
    sums = np.array([sum(1 for v in c if v) for c in clusters], dtype=float)
    sizes = np.array([len(c) for c in clusters], dtype=float)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(clusters), size=(reps, len(clusters)))
    boot_num = sums[idx].sum(axis=1)
    boot_den = sizes[idx].sum(axis=1)
    boot = np.where(boot_den > 0, boot_num / np.maximum(boot_den, 1), 0.0)
    return (float(point), float(np.percentile(boot, 2.5)), float(np.percentile(boot, 97.5)))


def pair_boards(rows, a, b, key):
    """같은 ood_seed 에서 정책 a/b 의 `key` 값을 뽑아 (list_a, list_b) 로 돌려준다.

    한쪽 판이 없는 시드는 통째로 버린다 -- 짝이 아닌 것을 짝으로 세면 안 된다.
    """
    idx = {}
    for r in rows:
        idx[(r.get("ood_seed"), r.get("policy"))] = r
    seeds = sorted({r.get("ood_seed") for r in rows if r.get("ood_seed") is not None})
    xa, xb = [], []
    for s in seeds:
        ra, rb = idx.get((s, a)), idx.get((s, b))
        if ra is None or rb is None:
            continue
        xa.append(ra.get(key))
        xb.append(rb.get(key))
    return xa, xb
