#!/usr/bin/env python
"""scores.py -- the score functions `ℓ` behind the success/known-disturbance/OOD classifier.

WHAT THIS IS
============
The paper (arXiv:2602.16182) does not commit to one anomaly score.  It defines a *menu*
(its Table I: residual-based, distance-based, miscellaneous), calibrates each with conformal
prediction, and reports a table of accuracies so the score is an empirical choice rather than
a preference.  This file is that menu for our simulator.  Everything here answers one question:

    given an event, how far outside "what this model was fitted on" does it look?

DESIGN RULES (see md/DESIGN_CLASSIFIER.md §4)
=============================================
1. ONE ORIENTATION.  The paper says `ℓ > η  ->  OOD`; our deployed gate says `p < α -> OOD`.
   Two conventions pointing opposite ways is a guaranteed sign bug, so every score declares
   `higher_is_ood` and `.novelty()` normalises so callers ALWAYS see "higher = more novel".
   `decision_margin` is the trap: a big margin means *confident*, i.e. familiar.

2. ONE GRANULARITY.  Scores are reported **per instance**, never per row.  The paper does the
   same ("maximum score per trajectory instead of timestep-level scoring, so that decisions are
   not affected by temporal correlations").  Our analogue of a trajectory is one OOD event, whose
   5 macro rows are one decision problem.  Row-level scores are aggregated with max.

3. ADMISSIBILITY IS DECLARED, NOT ASSUMED.  `needs_outcome=True` means the score reads the
   REALIZED result `y`, which does not exist until the run finishes.  Such a score is legal for
   calibration and assimilation but **illegal for routing**, because at the moment the event fires
   we only have (s, a).  `assert_routing_admissible()` enforces this instead of leaving it to a
   comment nobody reads.

WHY NOT JUST USE Q̂(s,a) AS THE SCORE
=====================================
Because it cannot be extreme, and CP thresholding is entirely about extremeness.  A RandomForest
prediction is a mean of leaf values, so it is bounded by the training target range -- a novel input
still lands in-range.  This is not speculation: the `gate=disagreement` arm (forest tree variance,
the natural confidence reading) scored **recall 0.00** on a novel kind.  The forest is not
uncertain on novel input, it is confidently wrong.

And the raw residual |Q̂ - y| was tried and failed: md/FINDINGS_ADWIN.md records CUSUM on
value-residual firing 4 times with 3 spurious (8.6 with 7.8 spurious on long streams), because
residual magnitude tracks SCENARIO DIFFICULTY, not novelty.  What works is the *contrast* of two
models' residuals on the same sample, per-instance normalised -- that cancels the difficulty term.
That is `ResidualContrast` below, and it is also what the paper actually does with its two models.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
이 파일 = 논문 Table I 의 "스코어 메뉴"를 우리 시뮬레이터로 옮긴 것.

지켜야 할 규칙 3가지
  1. 방향 통일 — 논문은 `ℓ>η면 OOD`, 우리 게이트는 `p<α면 OOD` 로 반대다. 그래서 각 스코어가
     higher_is_ood 를 선언하고, .novelty() 는 언제나 "클수록 낯설다"로 뒤집어 준다.
     decision_margin 이 함정: margin 이 크면 '확신 = 익숙함'이다.
  2. 단위 통일 — 점수는 instance(사건) 단위. 논문도 trajectory 당 max 로 요약한다.
  3. 사용가능 시점 선언 — needs_outcome=True 는 "런이 끝나야 나오는 값"이라 라우팅에 못 쓴다.
     주석으로 두지 않고 assert_routing_admissible() 로 강제한다.

Q̂ 를 그대로 점수로 못 쓰는 이유: 포레스트 예측은 잎 평균이라 학습 타깃 범위를 못 벗어난다
(= 극단값이 안 나옴). 실제로 트리분산 게이트는 신규 종류 recall 0.00 이었다. 잔차 |Q̂-y| 하나만
쓰는 것도 이미 실패했다(FINDINGS_ADWIN: spurious 3/4). 잔차는 novelty 가 아니라 시나리오
난이도를 잰다. 되는 것은 **두 모델 잔차의 대비**이고, 그게 논문이 실제로 하는 일이다.

[문법 참고]
  · np.linalg.pinv  — 유사역행렬. 공분산이 특이(singular)여도 안전하게 역을 구한다.
  · @               — 행렬곱 연산자 (a @ b == np.matmul(a, b)).
  · dict comprehension {k: v for ...} — 키:값 쌍을 한 줄로 만드는 표기.
────────────────────────────────────────────────────────────────────────────────────────────
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from features_agnostic import STATE_DESCRIPTORS, descriptors_from_row, featurize_agnostic
from surrogate_model import build_model

CAP = 8.0          # z-clipping bound; same constant as the deployed gate (novelty.jl / openworld_experiments)
LAM = 3.0          # cost weight used to build the surrogate target, matching e1_analyze's cost-aware mode
MACRO_COST = {0: 0.0, 1: 1.0, 2: 0.3, 3: 1.0, 4: 1.0}


# ==========================================================================================
#  공통 도우미
# ==========================================================================================
def instance_ids(df):
    """정렬된 instance 목록. 어디서든 같은 순서를 쓰기 위해 한 곳에서만 만든다."""
    return sorted(df.instance.astype(str).unique().tolist())


def state_matrix(df, iids):
    """instance 당 상태 서술자 1행. 상태는 macro 와 무관하므로 5행 중 첫 행만 읽는다.

    (같은 상태를 5번 넣으면 분산이 인위적으로 줄어 교정이 왜곡된다 -- 기존
     export_novelty_calibration.instance_descriptor_matrix 와 동일한 이유·동일한 계산.)
    """
    by = {str(i): g for i, g in df.groupby("instance")}
    rows = []
    for i in iids:
        d = descriptors_from_row(by[i].iloc[0])
        rows.append([float(d[k]) for k in STATE_DESCRIPTORS])
    return np.asarray(rows, dtype=float)


def target_values(df):
    """서로게이트 학습 목표 y = closed - λ·cost(macro). 배포 학습식과 같아야 잔차가 의미를 갖는다."""
    cost = np.array([MACRO_COST[int(m)] for m in df.macro], dtype=float)
    return df.closed.astype(float).values - LAM * cost


def instance_span(g, fallback=None):
    """한 instance 안에서 y 의 최대-최소 폭. 잔차를 이걸로 나눠 '시나리오 난이도'를 상쇄한다.

    이 정규화가 없으면 잔차는 novelty 가 아니라 난이도를 재게 되고, 그건 이미 실패한 신호다.

    fallback 이 필요한 이유 -- **nominal instance 는 행이 1개다**(고를 매크로가 없으므로 NOOP 하나).
    행이 하나면 max-min = 0 이고, 예전 하한 1e-9 로 나누면 잔차가 1e9 배로 폭발해 그 instance 가
    무조건 극단 novelty 로 찍힌다. 즉 nominal 을 넣는 순간 조용히 망가지는 자리였다. 행이 2개
    미만이면 데이터셋 전체 폭 같은 바깥 눈금을 쓴다.
    """
    y = target_values(g)
    span = float(y.max() - y.min()) if len(y) > 1 else 0.0
    if span > 1e-9:
        return span
    if fallback is not None and float(fallback) > 1e-9:
        return float(fallback)
    return 1.0          # 최후: 1.0(= 정규화 안 함). 1e-9 로 나누는 것보다 언제나 안전하다.


def global_span(df):
    """데이터셋 전체 y 의 폭. 단일행 instance 의 span 대체값으로 쓴다."""
    y = target_values(df)
    return max(float(y.max() - y.min()), 1.0)


# ==========================================================================================
#  행 범위(row scope) -- 서로 다른 행 수를 가진 instance 를 공평하게 비교하기 위한 장치
# ==========================================================================================
# 왜 필요한가 (2026-07-30 에 3-class 표에서 드러난 교란요인):
#   교란 instance 는 매크로 5개를 다 돌리므로 **5행**이지만, nominal instance 는 고를 매크로가
#   없어 **1행**(NOOP)이다. 행 단위로 집계하는 스코어(max over rows)는 그러면 "5번 뽑은 것 중
#   최대"와 "1번 뽑은 것 중 최대"를 비교하게 되는데, 이 차이는 novelty 가 아니라 **표본 수**에서
#   온다. 실제로 확인된 결과:
#       tree_variance   : 모든 nominal instance 가 0.0000 (unique=1) -> 밴드가 퇴화
#       decision_margin : 모든 nominal instance 가 -1.0000 (unique=1) -> 밴드가 퇴화
#   즉 그 표의 숫자는 측정이 아니라 인공물이었다.
#
#   scope="noop" 는 **모든 instance 가 반드시 가지고 있는 NOOP 행 하나**만 본다. 그러면 instance
#   마다 정확히 한 번씩 잰 값이 되어 비교가 성립한다.
#   scope="all"(기본)은 예전 동작 -- 모든 instance 의 행 수가 같은 2-class 표에서는 교란이 없으므로
#   기존 숫자를 보존하기 위해 기본값으로 남긴다.
ROW_SCOPES = ("all", "noop")


def _row_mask(df, iid, scope):
    """instance 하나에 해당하는 행 마스크. scope='noop' 면 그중 NOOP 행만."""
    m = df.instance.astype(str).values == iid
    if scope == "noop":
        m = m & (df.macro.astype(int).values == 0)
    return m


# ==========================================================================================
#  베이스 클래스
# ==========================================================================================
class InstanceScore:
    """모든 스코어의 공통 인터페이스.

    fit(train_df)                  학습 instance 들로 스코어를 맞춘다
    raw(df, iids)   -> {iid: v}    그 스코어의 '자연스러운' 방향 그대로
    novelty(df, iids) -> {iid: v}  항상 "클수록 낯설다"로 정규화된 값  <- 캘리브레이션은 이것만 본다
    """

    name = "base"
    family = "misc"          # distance | ensemble | residual | margin | misc
    higher_is_ood = True
    needs_outcome = False    # True 면 y_realized 가 필요 -> 라우팅 시점에는 사용 불가

    def fit(self, df):
        raise NotImplementedError

    def raw(self, df, iids):
        raise NotImplementedError

    def novelty(self, df, iids):
        r = self.raw(df, iids)
        return r if self.higher_is_ood else {k: -v for k, v in r.items()}

    def __repr__(self):
        return "<%s family=%s higher_is_ood=%s needs_outcome=%s>" % (
            self.name, self.family, self.higher_is_ood, self.needs_outcome)


def assert_routing_admissible(score):
    """라우팅 경로에 후행정보(y)를 읽는 스코어가 끼어드는 것을 막는다.

    이걸 주석으로만 두면 반드시 언젠가 섞인다. 그 결과는 '미래를 본 게이트'라 성능이 좋아 보이고,
    그래서 발견도 늦다. 그래서 예외로 만든다.
    """
    if score.needs_outcome:
        raise ValueError(
            "%s reads the realized outcome y, which does not exist when the event fires. "
            "It is valid for calibration/assimilation, not for routing "
            "(md/DESIGN_CLASSIFIER.md §4.2)." % score.name)
    return score


# ==========================================================================================
#  S1  z-RMS  (현행 배포 게이트) -- 논문의 "Latent distance (L2)" 자리
# ==========================================================================================
class ZRms(InstanceScore):
    """특징별로 z 표준화 후 클리핑, 그 RMS.

    대각 공분산만 쓰는 마할라노비스와 같다(특징 간 상관을 무시). 지금 배포된 게이트가 정확히 이것:
    신규 종류 recall 0.94 / precision 0.75 로 측정돼 있다.
    """

    name = "z_rms"
    family = "distance"

    def __init__(self, cap=CAP):
        self.cap = cap
        self.mu = None
        self.sd = None

    def fit(self, df):
        X = state_matrix(df, instance_ids(df))
        self.mu = X.mean(axis=0)
        self.sd = X.std(axis=0) + 1e-9      # 0 분산 방어 (배포 코드와 같은 상수)
        return self

    def raw(self, df, iids):
        X = state_matrix(df, iids)
        z = np.clip((X - self.mu) / self.sd, -self.cap, self.cap)
        s = np.sqrt(np.mean(z * z, axis=1))
        return {i: float(v) for i, v in zip(iids, s)}


# ==========================================================================================
#  S2  Mahalanobis (전체 공분산) -- 논문에서 OOD 검출 1위(100%)였던 지표
# ==========================================================================================
class Mahalanobis(InstanceScore):
    """전체 공분산을 쓰는 거리. z_rms 와 달리 특징 간 상관을 고려한다.

    논문은 이 지표가 OOD 를 100% 잡았지만 "고차원에서 공분산 역행렬이 불안정해 교정집합에
    과적합한다"고 경고했다. 우리 서술자 공간은 **6차원**이라 그 불안정성이 우리 것이 될 가능성은
    낮다 -- 그래서 값싸게 시도할 가치가 가장 큰 후보다(DESIGN_CLASSIFIER §4.3).

    shrinkage: 공분산을 (1-a)·S + a·diag(S) 로 살짝 대각 쪽으로 당긴다. a=0 이면 순수 마할라노비스.
    표본이 적을 때(우리는 instance 수십 개) 역행렬이 튀는 것을 막는 표준 처방.
    """

    name = "mahalanobis"
    family = "distance"

    def __init__(self, shrinkage=0.1, cap=CAP):
        self.shrinkage = float(shrinkage)
        self.cap = cap
        self.mu = None
        self.VI = None

    def fit(self, df):
        X = state_matrix(df, instance_ids(df))
        self.mu = X.mean(axis=0)
        S = np.cov(X, rowvar=False)
        S = np.atleast_2d(S)
        if self.shrinkage > 0:
            S = (1.0 - self.shrinkage) * S + self.shrinkage * np.diag(np.diag(S))
        S = S + 1e-9 * np.eye(S.shape[0])       # 특이행렬 방어
        self.VI = np.linalg.pinv(S)             # pinv: 특이해도 안전
        return self

    def raw(self, df, iids):
        X = state_matrix(df, iids) - self.mu
        d2 = np.einsum("ij,jk,ik->i", X, self.VI, X)     # 행마다 x' S⁻¹ x
        d = np.sqrt(np.maximum(d2, 0.0))
        # z_rms 와 눈금을 맞추기 위해 특징 수로 정규화하고 같은 상한으로 자른다.
        return {i: float(min(v / math.sqrt(X.shape[1]), self.cap))
                for i, v in zip(iids, d)}


# ==========================================================================================
#  S3  Tree variance -- 논문의 "ensemble" 계열. 우리 데이터에서 이미 실패한 대조군.
# ==========================================================================================
class TreeVariance(InstanceScore):
    """포레스트 구성원들의 예측 분산.

    포함하는 이유는 이길 것 같아서가 아니라 **이미 졌기 때문**이다: 이 신호를 쓴 게이트는 신규
    종류에서 recall 0.00 이었다(포레스트가 모르는 입력에 자신 있게 틀린다). 논문 Table II 에도
    약한 지표들이 함께 실려 있듯, 대조군이 있어야 표가 주장을 한다.
    """

    name = "tree_variance"
    family = "ensemble"

    def __init__(self, row_scope="all"):
        self.row_scope = row_scope
        self.model = None
        self.cols = None

    def fit(self, df):
        X = featurize_agnostic(df, action_repr="onehot")
        self.cols = list(X.columns)
        self.model = build_model().fit(X.values, target_values(df))
        return self

    def raw(self, df, iids):
        X = featurize_agnostic(df, action_repr="onehot")
        X = X.reindex(columns=self.cols, fill_value=0.0)
        per_tree = np.stack([t.predict(X.values) for t in self.model.estimators_])
        sd = per_tree.std(axis=0)
        out = {}
        for i in iids:
            m = _row_mask(df, i, self.row_scope)
            # instance 당 max (논문의 trajectory-max 요약과 같은 규칙)
            out[i] = float(sd[m].max()) if m.any() else float("nan")
        return out


# ==========================================================================================
#  S4  Residual contrast -- 논문의 2-모델 구조를 우리 좌표로. **신규**
# ==========================================================================================
class ResidualContrast(InstanceScore):
    """두 모델의 잔차 대비. 잔차 하나만 쓰는 실패(FINDINGS_ADWIN)를 구조적으로 피한다.

        ℓ = ( |Q̂_model − y| − |Q̂_ref − y| ) / span(instance)

    · Q̂_model : 학습 종류로 맞춘 서로게이트
    · Q̂_ref   : 참조 모델. 최종형은 **M_nominal**(교란 없는 런으로 학습)이지만, 지금 데이터셋에는
                nominal 행이 0개라 오늘은 'null' 참조(=학습 y 의 상수 예측)를 쓴다.
                nominal arm 이 생기면 reference='nominal' 로 바꾸면 된다. 그 전까지 이 값을
                논문의 ℓ_success 와 동일시하면 안 된다.
    · span    : instance 안 y 의 폭. 이 나눗셈이 '시나리오 난이도' 항을 상쇄하는 부분이고,
                빠뜨리면 (b) 의 실패(spurious 3/4)를 그대로 재현한다.

    양수면 "참조보다 이 모델이 더 못 맞혔다" = 이 모델의 학습분포 밖.
    """

    name = "residual_contrast"
    family = "residual"
    needs_outcome = True        # y_realized 필요 -> 라우팅 불가, 캘리브레이션/동화 전용

    def __init__(self, reference="null", row_scope="all"):
        if reference not in ("null", "nominal"):
            raise ValueError("reference must be 'null' or 'nominal', got %r" % reference)
        self.reference = reference
        self.row_scope = row_scope
        self.model = None
        self.cols = None
        self.ref_model = None
        self.ref_const = None

    def fit(self, df, nominal_df=None):
        X = featurize_agnostic(df, action_repr="onehot")
        self.cols = list(X.columns)
        y = target_values(df)
        self.model = build_model().fit(X.values, y)
        if self.reference == "nominal":
            if nominal_df is None or len(nominal_df) == 0:
                raise ValueError(
                    "reference='nominal' needs undisturbed (kind='none') rows, and the dataset "
                    "has none yet. Use reference='null' until the nominal arm exists.")
            Xn = featurize_agnostic(nominal_df, action_repr="onehot").reindex(
                columns=self.cols, fill_value=0.0)
            self.ref_model = build_model().fit(Xn.values, target_values(nominal_df))
        else:
            self.ref_const = float(np.mean(y))      # 최선의 상수 예측 = 정보 없는 참조
        return self

    def _ref_predict(self, X):
        if self.ref_model is not None:
            return self.ref_model.predict(X.values)
        return np.full(len(X), self.ref_const)

    def raw(self, df, iids):
        X = featurize_agnostic(df, action_repr="onehot").reindex(
            columns=self.cols, fill_value=0.0)
        y = target_values(df)
        r_model = np.abs(self.model.predict(X.values) - y)
        r_ref = np.abs(self._ref_predict(X) - y)
        by = {str(i): g for i, g in df.groupby("instance")}
        gs = global_span(df)          # 단일행(nominal) instance 의 눈금 대체값
        out = {}
        for i in iids:
            m = _row_mask(df, i, self.row_scope)
            out[i] = (float(((r_model[m] - r_ref[m]) / instance_span(by[i], gs)).max())
                      if m.any() else float("nan"))
        return out


# ==========================================================================================
#  S5  Training loss -- 논문의 대조 지표("정상은 잘 알지만 이상을 증폭하진 못한다")
# ==========================================================================================
class TrainLoss(InstanceScore):
    """모델이 이 instance 를 얼마나 못 맞혔나(정규화된 절대잔차).

    논문이 이걸 넣은 이유와 같은 이유로 넣는다: 정상 데이터를 잘 알아보지만 이상을 증폭하도록
    설계되지 않아, "분리력이 없는 지표"가 표에서 어떻게 보이는지의 기준선이 된다.
    """

    name = "train_loss"
    family = "misc"
    needs_outcome = True

    def __init__(self, row_scope="all"):
        self.row_scope = row_scope
        self.model = None
        self.cols = None

    def fit(self, df):
        X = featurize_agnostic(df, action_repr="onehot")
        self.cols = list(X.columns)
        self.model = build_model().fit(X.values, target_values(df))
        return self

    def raw(self, df, iids):
        X = featurize_agnostic(df, action_repr="onehot").reindex(
            columns=self.cols, fill_value=0.0)
        r = np.abs(self.model.predict(X.values) - target_values(df))
        by = {str(i): g for i, g in df.groupby("instance")}
        gs = global_span(df)          # 단일행(nominal) instance 의 눈금 대체값
        out = {}
        for i in iids:
            m = _row_mask(df, i, self.row_scope)
            out[i] = (float((r[m] / instance_span(by[i], gs)).max())
                      if m.any() else float("nan"))
        return out


# ==========================================================================================
#  S6  Decision margin -- 논문의 probability-based "margin score"
# ==========================================================================================
class DecisionMargin(InstanceScore):
    """1등과 2등 예측값의 차이. **방향이 반대인 유일한 스코어.**

    margin 이 크다 = 어떤 대응이 확실히 낫다 = 확신 = 익숙함. 그래서 higher_is_ood=False 이고,
    .novelty() 가 부호를 뒤집어 준다. 이 한 줄이 없으면 표 전체가 조용히 뒤집힌다.
    """

    name = "decision_margin"
    family = "margin"
    higher_is_ood = False

    def __init__(self):
        self.model = None
        self.cols = None

    def fit(self, df):
        X = featurize_agnostic(df, action_repr="onehot")
        self.cols = list(X.columns)
        self.model = build_model().fit(X.values, target_values(df))
        return self

    def raw(self, df, iids):
        X = featurize_agnostic(df, action_repr="onehot").reindex(
            columns=self.cols, fill_value=0.0)
        pred = self.model.predict(X.values)
        key = df.instance.astype(str).values
        out = {}
        for i in iids:
            v = np.sort(pred[key == i])[::-1]
            if len(v) < 2:
                # 1등과 2등의 차이는 후보가 2개 이상일 때만 존재한다. nominal instance 는 고를
                # 매크로가 없어 행이 하나뿐이므로 이 지표는 **정의되지 않는다**.
                # 예전에는 여기서 상수 1.0 을 돌려줬는데, 그러면 모든 nominal instance 가 같은
                # 값을 받아 밴드가 퇴화하고(관측: unique=1) "정확도 0.0%" 가 측정처럼 보였다.
                # 정의되지 않는 것은 NaN 으로 말해야 호출자가 그 스코어를 제외할 수 있다.
                out[i] = float("nan")
                continue
            span = max(float(v[0] - v[-1]), 1e-9)
            out[i] = float((v[0] - v[1]) / span)
        return out


# ==========================================================================================
#  레지스트리
# ==========================================================================================
def all_scores():
    """논문 Table I 에 대응하는 기본 메뉴. 순서는 리포트 표의 행 순서가 된다."""
    return [ZRms(), Mahalanobis(), TreeVariance(), ResidualContrast(), TrainLoss(),
            DecisionMargin()]


def routing_scores():
    """라우팅 시점(사건 발생 순간)에 실제로 쓸 수 있는 것만."""
    return [s for s in all_scores() if not s.needs_outcome]


if __name__ == "__main__":
    import wm_datasets
    from openworld_experiments import load_df

    path = wm_datasets.resolve(sys.argv[1] if len(sys.argv) > 1 else None)
    df = load_df(path)
    iids = instance_ids(df)
    print(wm_datasets.describe(path), "->", len(df), "rows,", len(iids), "instances\n")
    print("%-20s %-10s %-14s %-14s %s" % ("score", "family", "higher_is_ood", "needs_outcome",
                                          "range over all instances"))
    for s in all_scores():
        s.fit(df)
        v = np.array(list(s.novelty(df, iids).values()))
        print("%-20s %-10s %-14s %-14s [%.3f, %.3f]  median %.3f"
              % (s.name, s.family, s.higher_is_ood, s.needs_outcome,
                 v.min(), v.max(), float(np.median(v))))
    print("\nrouting-admissible:", [s.name for s in routing_scores()])
    try:
        assert_routing_admissible(ResidualContrast())
    except ValueError as e:
        print("guard works ->", str(e)[:88], "...")
