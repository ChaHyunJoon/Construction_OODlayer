"""surrogate_data.py -- 배포 surrogate 의 **학습 프레임 단일 정의**.

왜 이 파일이 있나: 이 로직(fired 필터 -> 완전 instance 필터 -> featurize -> 비용 차감 보상)이
dspy_service._load_surrogate 안에만 있었다. 그래서 "배포 모델이 무슨 매크로를 본 적 있는가"를
테스트하려면 fastapi/dspy 를 통째로 import 해야 했고, 결국 아무도 테스트하지 않았다 --
RESULTS_LLM7H §5-f 의 5판 동일 결과가 그 대가다.

surrogate_model.py 에 두지 않는 이유: e1_analyze 가 surrogate_model 을 import 하므로(순환).
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

LAM = 3.0    # 보상 = closed - LAM * macro_cost. dspy_service 가 쓰던 값 그대로.


def load_training_frame(path, lam=LAM):
    """(X, y, support, n_instances) 를 돌려준다.

    support = 학습 근거가 있는 매크로 id 집합. 여기 없는 팔은 배포 시 후보에서 탈락한다.
    """
    import sys
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    from e1_analyze import load, featurize, MACRO_COST, instance_arms_complete

    df = load(path)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    X = featurize(df)
    y = df.closed.astype(float).values - lam * np.array([MACRO_COST[int(m)] for m in df.macro])
    support = {int(m) for m in df.macro.unique()}
    return X, y, support, len(full)
