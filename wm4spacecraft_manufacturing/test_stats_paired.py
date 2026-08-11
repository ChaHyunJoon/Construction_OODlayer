"""test_stats_paired.py -- stats_paired.py 단위 테스트.

실행: /home/chahj578/Construction_OODlayer/.venv/bin/python test_stats_paired.py
이 저장소에는 pytest 가 없다(.venv 에 numpy/scipy 만 있다). test_surrogate_support.py 와
같은 관례를 따른다: check() 로 PASS/FAIL 을 찍고 실패 개수로 종료코드를 낸다.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from stats_paired import holm, paired_wilcoxon, cluster_bootstrap_ci, pair_boards
from ood_sweep_report import wilson

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


def approx(a, b, tol=1e-9):
    return abs(a - b) <= tol


print("== stats_paired 단위 테스트 ==")

# 정렬해서 조정한 뒤 원래 순서로 되돌려주는지 -- 순서가 뒤바뀌면 p 값이 엉뚱한 검정에 붙는다.
# 0.01*3 은 이 파이썬에서 0.03 과 정확히 같지만, 부동소수 동등성에 의존하지 않는다.
adj = holm([0.04, 0.01, 0.03])
check("holm 입력 순서 보존", len(adj) == 3 and approx(adj[1], 0.03) and approx(adj[2], 0.06)
      and approx(adj[0], 0.06), str(adj))
check("holm 1.0 클램프", holm([0.9, 0.8])[0] == 1.0)
check("holm 빈 입력", holm([]) == [])

r = paired_wilcoxon([10.0, 11, 12, 13, 14, 15], [20.0, 21, 22, 23, 24, 25])
check("wilcoxon 일관된 차이 탐지", r["n_used"] == 6 and r["p"] < 0.05 and r["median_diff"] == -10.0,
      "p=%.5f" % r["p"])

# 전부 동점 -- scipy 가 예외를 던지는 입력. p=1.0 으로 받아내야 한다(천장효과 경로).
r = paired_wilcoxon([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
check("wilcoxon 전부 동점 -> p=1.0", r["p"] == 1.0 and bool(r["note"]), r["note"])

# None = 그 판이 완주하지 않아 값이 없다(E4 선택편향 경로). 짝 전체를 버린다.
r = paired_wilcoxon([1.0, None, 3.0, 4.0, 5.0, 6.0], [2.0, 5.0, None, 5.0, 6.0, 7.0])
check("wilcoxon None 짝 제거", r["n"] == 6 and r["n_used"] == 4, "n_used=%d" % r["n_used"])

# 같은 판 안의 결정이 완전상관일 때, 군집 부트스트랩 CI 는 결정 단위 Wilson 보다 넓어야 한다.
clusters = [[True] * 5 for _ in range(10)] + [[False] * 5 for _ in range(10)]
point, lo, hi = cluster_bootstrap_ci(clusters, reps=2000, seed=0)
w_lo, w_hi = wilson(50, 100)
check("군집 CI가 결정단위 Wilson보다 넓다", approx(point, 0.5) and (hi - lo) > (w_hi - w_lo),
      "cluster=%.3f wilson=%.3f" % (hi - lo, w_hi - w_lo))
check("군집 CI 빈 입력", cluster_bootstrap_ci([], reps=10, seed=0) == (0.0, 0.0, 0.0))

rows = [
    {"ood_seed": 1, "policy": "a", "v": 1.0},
    {"ood_seed": 1, "policy": "b", "v": 2.0},
    {"ood_seed": 2, "policy": "a", "v": 3.0},   # seed 2 / policy b 없음 -> 짝이 안 맞아 버려진다
]
xa, xb = pair_boards(rows, "a", "b", "v")
check("pair_boards 시드 짝맞춤", xa == [1.0] and xb == [2.0], "%s %s" % (xa, xb))

# 결정을 판별로 묶는 헬퍼가 판 경계를 지키는지 -- 여기가 틀리면 군집 CI 가 결정 단위 CI 로
# 조용히 되돌아간다(그리고 숫자는 그럴듯해 보인다).
import shadow_score

_scored = [
    {"_board": ("battery", 1, "dspy"), "correct": True},
    {"_board": ("battery", 1, "dspy"), "correct": False},
    {"_board": ("battery", 2, "dspy"), "correct": True},
]
_clusters = shadow_score.group_by_board(_scored)
check("shadow 결정이 판 단위로 묶인다", sorted(len(c) for c in _clusters) == [1, 2],
      str(sorted(len(c) for c in _clusters)))

# 위 체크는 _board 를 손으로 이미 박아 넣은 입력만 본다 -- load_rows_and_decisions 가
# (ood_seed, policy) 만으로 _board 를 만들도록 회귀해도(case 를 빠뜨려도) 저 체크는 여전히
# 통과한다. 그러면 다른 case 의 판이 seed·policy 만 같으면 한 군집으로 조용히 합쳐진다.
# 여기서는 case 만 다르고 ood_seed·policy 는 같은 두 판을 실제 파일 ->
# load_rows_and_decisions -> score_producer 로 흘려 실배선을 검증한다.
import json
import tempfile

_tmp_rows = [
    {"case": "battery", "ood_seed": 1, "policy": "dspy",
     "decisions": [{"truth": "BatteryTruth", "soc": 0.5, "macro": "NOOP"}]},
    {"case": "zone", "ood_seed": 1, "policy": "dspy",
     "decisions": [{"truth": "BatteryTruth", "soc": 0.5, "macro": "NOOP"}]},
]
_tmp_path = None
try:
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as fh:
        _tmp_path = fh.name
        for _r in _tmp_rows:
            fh.write(json.dumps(_r) + "\n")
    _rows2, _decisions2 = shadow_score.load_rows_and_decisions([_tmp_path])
    _n2, _c2, _prows2 = shadow_score.score_producer(_decisions2, "macro")
    _scored2 = [r for r in _prows2 if r["correct"] is not None]
    _clusters2 = shadow_score.group_by_board(_scored2)
    check("실배선: case 만 다르면 seed·policy 가 같아도 다른 판으로 갈린다",
          len(_clusters2) == 2, "n_clusters=%d (scored=%d)" % (len(_clusters2), len(_scored2)))
finally:
    if _tmp_path:
        os.remove(_tmp_path)

sys.exit(1 if FAILED else 0)
