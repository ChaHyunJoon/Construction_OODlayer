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
    # "랭킹이 정의되는 instance만" 학습에 쓴다. 예전에는 `len(g) == 5` 였는데, DS_VALID_ONLY 로 만든
    # 라벨은 그 사건의 **유효한 팔만** 돌아 5를 영영 못 채운다 -> EVAL_DATA 를 새 덤프로 바꿔도
    # 새 instance 가 전부 조용히 버려진다(2026-08-05: firegrid_merged 126개 중 60개만 통과, 그
    # 60개는 전부 옛 5-arm 덤프였다). 판정은 e1_analyze 의 것을 그대로 쓴다 -- 평가와 배포가
    # 다른 필터를 쓰면 "벤치마크한 그 모델"이라는 이 파일의 전제가 깨진다.
    full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    X = featurize(df)
    y = df.closed.astype(float).values - lam * np.array([MACRO_COST[int(m)] for m in df.macro])
    support = {int(m) for m in df.macro.unique()}
    return X, y, support, len(full)
