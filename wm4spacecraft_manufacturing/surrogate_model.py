"""surrogate_model.py -- THE single definition of the surrogate model class.

WHY THIS FILE EXISTS
--------------------
Until 2026-07-27 the evaluation stack (E1-E4, ladder, ablation, drift) fitted a
HistGradientBoostingRegressor while the DEPLOYED artifact (`export_surrogate.py` ->
`surrogate_*.json`, walked by the Julia demo) was a RandomForest.  The two classes do
NOT agree on the same data -- measured leave-one-instance-out decision regret:

    dataset        HGB(300,d4,lr.08)   RF(60,d6,msl2)
    graded_hs_v2         0.089             0.100
    graded_all           0.183             0.192

so every published number described a model that was never shipped.  That is a
consistency defect, not a modelling preference.  Decision (2026-07-27): unify on
**RandomForest**, the class that is actually deployed, and import it from here so the
two can never drift apart again.

USAGE
    from surrogate_model import build_model
    model = build_model()               # canonical surrogate
    model = build_model(random_state=3) # override anything for a seed/robustness study

NOTE ON WHAT THIS FILE IS *NOT* FOR
    `master_experiment.py` and `sweep_surrogate.py` deliberately compare model CLASSES
    against each other; they must keep constructing their own estimators and must NOT
    import build_model, or the comparison collapses.

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 파일은 surrogate 모델을 "한 곳에서만" 정의한다.
문제였던 것: 논문/실험 숫자는 HistGradientBoosting으로 뽑고, 실제 데모에 배포된
JSON은 RandomForest였다. 같은 데이터에서 두 모델의 답이 달라(위 표) 발표 숫자가
실제 시스템을 설명하지 못했다. 그래서 배포되는 쪽인 RandomForest로 통일한다.

문법 참고:
  · **kw / dict.update(...)  — 호출자가 준 인자로 기본 설정을 덮어쓰는 관용구.
  · n_jobs=-1 — 사용 가능한 CPU 코어를 모두 써서 트리를 병렬로 학습.
  · random_state 고정 — RF는 부트스트랩/특징 샘플링에 난수를 쓰므로, 고정해야 재현된다.
────────────────────────────────────────────────────────────────────────────
"""
from sklearn.ensemble import RandomForestRegressor

# The canonical surrogate hyperparameters.  These are the DEPLOYED values
# (`export_surrogate.py` writes a forest with exactly these), so evaluation and
# deployment are byte-for-byte the same estimator.
#
# n_estimators=60 is inherited from the deployed artifact.  More trees only reduces
# RandomForest variance (it cannot overfit in the number of trees), and the Julia demo
# evaluates the forest in ~0.1 ms, so raising it is cheap -- but it changes published
# numbers, so it is a deliberate decision, not a silent default.  See TRAINING_NOTES
# in the repo before changing.
SURROGATE_PARAMS = dict(
    n_estimators=60,
    max_depth=6,
    min_samples_leaf=2,
    max_features=0.5,     # sklearn's regression default; all 20 (or 60) columns per split
    random_state=0,       # RF is stochastic -- pin it or LOO numbers wobble by ~0.02
    n_jobs=-1,
)

MODEL_NAME = "RandomForest(60 x depth6, msl2)"


def build_model(**overrides):
    """Return the canonical surrogate estimator.  Pass keyword overrides for studies."""
    p = dict(SURROGATE_PARAMS)
    p.update(overrides)
    return RandomForestRegressor(**p)
