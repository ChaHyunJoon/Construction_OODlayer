"""배포 surrogate 의 **매크로 지원 집합** 계약 테스트.

왜 이 테스트가 필요한가: 학습 근거가 없는 매크로는 dspy_service.surrogate_rank 에서 후보에서
탈락한다. 그래서 어휘가 빠지면 에러가 아니라 **성능으로만** 샌다 -- RESULTS_LLM7H §5-f 에서
배포 surrogate 가 규칙과 5판 전부 바이트 동일한 결과를 낸 것이 그 증상이었다.
지원 집합은 주장이 아니라 검사여야 한다.
"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wm_datasets
from surrogate_data import load_training_frame

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  %s  %s   %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILED += 1


print("== 배포 학습셋의 매크로 지원 ==")
path = wm_datasets.resolve(None, default=wm_datasets.N44_PLUS8)
X, y, support, n_inst = load_training_frame(path)
check("데이터셋이 존재한다", os.path.exists(path), path)
check("instance 수 >= 60", n_inst >= 60, "n=%d" % n_inst)
check("SwapBattery(8) 학습 근거 있음", 8 in support, "support=%s" % sorted(support))
check("기존 5팔 보존", {0, 1, 2, 3, 4} <= support, "support=%s" % sorted(support))
check("X/y 길이 일치", len(X) == len(y), "%d vs %d" % (len(X), len(y)))

sys.exit(1 if FAILED else 0)
