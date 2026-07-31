#!/usr/bin/env python
"""calibrate.py -- conformal-prediction thresholding, and the 3-way decision function.

WHAT CONFORMAL PREDICTION IS DOING HERE
=======================================
Not building prediction intervals.  The paper uses CP in its *thresholding* form (its §II-D):
take a score, look at how that score is distributed on data the model was fitted on, and cut at
a chosen quantile.  Anything scoring beyond the cut is "not from this distribution".  The
appeal is that it is **distribution-free** -- no assumption about the shape of the score
distribution, only that calibration and test data are exchangeable.

Two bands, per the paper's Fig. 5: each model is calibrated on its own data, so a nominal band
and a known-disturbance band are fitted separately and then read together.

THE QUANTILE IS A SAFETY DIAL, NOT A HYPERPARAMETER TO TUNE
===========================================================
The paper measured the trade-off and it is sharp (their Table II): at the 100% quantile the
threshold sits at the calibration maximum, so almost nothing is ever flagged -- every metric
except Mahalanobis collapsed to 0% OOD detection.  At 90% they got their best balance.  Lower
quantile = more OOD caught, more nominal misread; higher = the reverse.  Their rule, which we
adopt: in a safety-critical setting **false positives are preferable to false negatives**, so
we report 90/95/100 side by side rather than picking one silently.

WHAT "OUTSIDE" MEANS -- the sign convention
==========================================
`scores.py` guarantees every score arrives as "higher = more novel" (`.novelty()`).  So here,
uniformly: `s > eta` means outside the band.  There is exactly one orientation in this file.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
CP 를 '예측구간'이 아니라 **임계값 정하기**로 쓴다(논문 §II-D). 모델이 학습한 데이터에서 그
점수가 어떻게 분포하는지 보고, 정한 분위수에서 자른다. 분포 모양을 가정하지 않는 게 장점.

밴드는 2개(논문 Fig.5): nominal 용, known-disturbance 용을 각각 따로 교정한 뒤 함께 읽는다.

분위수는 튜닝 대상이 아니라 **안전 다이얼**이다. 논문 Table II 에서 100% 분위수는 임계가
교정집합 최댓값에 놓여 거의 아무것도 못 잡았고(대부분 0%), 90% 가 가장 균형이 좋았다.
안전이 걸린 상황에선 '놓치는 것'보다 '헛경보'가 낫다는 논문 원칙을 따라 90/95/100 을 나란히
보고한다.

방향: scores.py 가 이미 "클수록 낯설다"로 맞춰 주므로 여기서는 `s > eta` 하나뿐이다.

[문법 참고]
  · np.quantile(a, q)  — a 의 q 분위수(q 는 0~1). q=1.0 이면 최댓값.
  · @dataclass         — __init__ 등을 자동 생성해 주는 데코레이터(간단한 값 묶음 클래스용).
────────────────────────────────────────────────────────────────────────────────────────────
"""
import os
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

#: 논문 Table II 와 같은 세 지점. 이 순서로 리포트된다.
QUANTILES = (0.90, 0.95, 1.00)

P_FLOOR = 1e-4      # p-value 하한. 배포 게이트(novelty.jl)와 같은 값으로 맞춘다.


# ==========================================================================================
#  하나의 밴드
# ==========================================================================================
@dataclass
class ConformalBand:
    """한 모델의 in-distribution 점수 집합 = 그 모델의 '정상' 정의.

    name       어느 모델의 밴드인지(로그·리포트용)
    cal        교정 점수들(정렬 보관). 반드시 **그 모델이 학습한 분포**에서 나와야 한다.
    """

    name: str
    cal: np.ndarray = field(default_factory=lambda: np.zeros(0))

    @classmethod
    def fit(cls, name, scores):
        s = np.asarray(list(scores), dtype=float)
        s = s[np.isfinite(s)]
        if s.size == 0:
            raise ValueError("ConformalBand(%s): no finite calibration scores" % name)
        return cls(name=name, cal=np.sort(s))

    def threshold(self, q):
        """분위수 q 에서의 임계 eta. q=1.0 이면 교정집합 최댓값(가장 보수적)."""
        return float(np.quantile(self.cal, q))

    def is_outside(self, score, q):
        """`s > eta` = 이 모델 기준으로 밖. 논문의 D(·)=1 에 해당."""
        return bool(float(score) > self.threshold(q))

    def pvalue(self, score):
        """부드러운 conformal p-value. 교정집합 대비 이 점수보다 큰 비율.

        배포 게이트(openworld_experiments.conformal_p / novelty.jl)와 **같은 식**을 쓴다.
        같은 사건에 두 코드가 다른 p 를 내면 오프라인 결론이 실제 시스템을 설명하지 못한다.
        """
        s = float(score)
        n = self.cal.size
        gt = int(np.sum(self.cal > s))
        eq = int(np.sum(self.cal == s))
        return float(min(max((gt + 0.5 * (eq + 1)) / (n + 1), P_FLOOR), 1.0))

    def summary(self):
        return "%s: n=%d  min=%.3f  median=%.3f  max=%.3f  eta90=%.3f eta95=%.3f eta100=%.3f" % (
            self.name, self.cal.size, self.cal[0], float(np.median(self.cal)), self.cal[-1],
            self.threshold(0.90), self.threshold(0.95), self.threshold(1.00))


# ==========================================================================================
#  결정 함수 (논문 Fig. 2 / Eq. 1·3)
# ==========================================================================================
NOMINAL = "nominal"
KNOWN = "known_disturbance"
OOD = "ood"
AMBIGUOUS = "ambiguous"


@dataclass
class ThreeWayClassifier:
    """두 밴드를 함께 읽어 3분류한다.

        D_nom = 1  <=>  s_nom > eta_nom     "교란 없는 빌드처럼 보이지 않는다"
        D_dis = 1  <=>  s_dis > eta_dis     "아는 교란처럼 보이지 않는다"

        (0, 1) -> nominal            개입 불필요
        (1, 0) -> known_disturbance  surrogate 가 매크로를 고른다
        (1, 1) -> OOD                DSPy LLM 이 해석한다
        (0, 0) -> ambiguous          논문엔 이름이 없는 칸. 우리는 발생 가능하므로 이름을 준다.

    (0,0) 을 왜 따로 두나: '건강한 빌드처럼도 보이고 아는 교란처럼도 보인다'는 건 저severity
    사건이다. 조용히 한쪽에 몰아넣으면 그 사실이 사라진다. NOOP 하되 기록에 남긴다.
    """

    band_nominal: ConformalBand
    band_disturb: ConformalBand

    def classify(self, s_nominal, s_disturb, q):
        d_nom = self.band_nominal.is_outside(s_nominal, q)
        d_dis = self.band_disturb.is_outside(s_disturb, q)
        if d_nom and d_dis:
            return OOD
        if d_nom and not d_dis:
            return KNOWN
        if not d_nom and d_dis:
            return NOMINAL
        return AMBIGUOUS

    def route(self, label):
        """분류 -> 누가 답하는가. 이 매핑이 분류를 시스템 동작으로 바꾸는 유일한 지점."""
        return {NOMINAL: "noop", KNOWN: "surrogate", OOD: "llm", AMBIGUOUS: "noop+flag"}[label]


# ==========================================================================================
#  2-class (오늘 밤에 실제로 돌릴 수 있는 형태)
# ==========================================================================================
@dataclass
class TwoWayClassifier:
    """밴드 하나로 known-disturbance vs OOD 만 가른다.

    왜 이게 오늘의 기본인가: nominal 결정함수를 만들려면 교란 없는(kind='none') 런이 필요한데
    현재 데이터셋에는 그런 행이 **0개**다. 그래서 오늘은 leave-one-kind-out 으로 '빼놓은 종류'가
    OOD 역할을 하는 2-class 만 정직하게 측정한다. nominal arm 이 들어오면
    ThreeWayClassifier 로 그대로 승격된다(밴드 하나만 더 끼우면 된다).
    """

    band: ConformalBand

    def classify(self, score, q):
        return OOD if self.band.is_outside(score, q) else KNOWN

    def route(self, label):
        return {KNOWN: "surrogate", OOD: "llm"}[label]


# ==========================================================================================
#  결합 게이트 -- 여러 스코어를 OR 로 묶는다
# ==========================================================================================
@dataclass
class CombinedGate:
    """밴드 여러 개 중 **하나라도** 밖이면 OOD.

    왜 필요한가 (classify_report.py 의 per-kind 결과):
      거리 계열(z_rms, mahalanobis)은 zoneblk/fault 를 거의 완벽히 잡고 battery 에서 무너지며
      (AUROC 0.05~0.27), tree_variance 는 정확히 그 반대다(battery 0.785, zoneblk 0.379).
      실패가 상보적이므로 어느 하나를 고르는 대신 OR 로 묶는 게 맞다. 원인은
      DESIGN_CLASSIFIER.md 7b: 거리 스코어는 **외삽** 낯섦만 볼 수 있고, 내삽 낯섦에는
      모델 잔차 계열이 필요하다.

    ★ 분위수 보정을 반드시 해야 하는 이유:
      95% 밴드 2개를 그냥 OR 하면 정상 입력이 걸릴 확률이 각 5%씩 합쳐져 **약 10%** 가 된다.
      그 상태로 "결합했더니 OOD 검출이 올랐다"고 하면 착시다 -- 결합의 힘이 아니라 그냥
      임계를 느슨하게 푼 것이기 때문. 목표 오탐률을 유지하려면 각 밴드를 1-alpha/N 로 조인다
      (Bonferroni). 보수적이지만 정직하고, 이 보정을 하고도 이기면 그건 진짜 이득이다.
    """

    bands: dict                  # name -> ConformalBand
    correct: bool = True         # False 로 두면 보정 없는(=착시) 비교군을 만들 수 있다

    def corrected_quantile(self, q):
        """OR 로 묶을 때 각 밴드가 써야 할 분위수. N=1 이면 원래 값 그대로."""
        n = max(len(self.bands), 1)
        if not self.correct or n == 1:
            return q
        alpha = 1.0 - float(q)
        return 1.0 - alpha / n

    def outside_which(self, scores, q):
        """어느 밴드가 발화했는지. 진단용 -- 어떤 스코어가 일하고 있는지 보여준다."""
        qc = self.corrected_quantile(q)
        return [n for n, b in self.bands.items() if b.is_outside(scores[n], qc)]

    def classify(self, scores, q):
        return OOD if self.outside_which(scores, q) else KNOWN

    def route(self, label):
        return {KNOWN: "surrogate", OOD: "llm"}[label]


# ==========================================================================================
#  평가 헬퍼
# ==========================================================================================
def confusion_2class(y_true, y_pred):
    """{'tp','fp','tn','fn'} — 양성 = OOD (놓치면 안 되는 쪽을 양성으로 둔다)."""
    tp = sum(1 for t, p in zip(y_true, y_pred) if t == OOD and p == OOD)
    fn = sum(1 for t, p in zip(y_true, y_pred) if t == OOD and p != OOD)
    fp = sum(1 for t, p in zip(y_true, y_pred) if t != OOD and p == OOD)
    tn = sum(1 for t, p in zip(y_true, y_pred) if t != OOD and p != OOD)
    return {"tp": tp, "fp": fp, "tn": tn, "fn": fn}


def rates(cm):
    """recall(=OOD 검출률), precision, specificity(=known 정확도), accuracy."""
    tp, fp, tn, fn = cm["tp"], cm["fp"], cm["tn"], cm["fn"]
    rec = tp / (tp + fn) if (tp + fn) else float("nan")
    prec = tp / (tp + fp) if (tp + fp) else float("nan")
    spec = tn / (tn + fp) if (tn + fp) else float("nan")
    acc = (tp + tn) / max(tp + tn + fp + fn, 1)
    return {"recall": rec, "precision": prec, "specificity": spec, "accuracy": acc}


def separation(cal_scores, ood_scores):
    """두 분포가 얼마나 갈라져 있나 = AUROC. 임계값 선택과 무관한 분리도 지표.

    논문은 히스토그램을 눈으로 보고 "겹치면 분리가 나쁘다"고 판정한다. 같은 것을 숫자로 둔다:
    0.5 = 구분 못함, 1.0 = 완전 분리. 분위수를 어떻게 잡든 변하지 않으므로, 표에서 분위수별
    정확도가 흔들릴 때 '지표 자체의 힘'을 읽는 기준이 된다.
    """
    a = np.asarray(list(cal_scores), dtype=float)
    b = np.asarray(list(ood_scores), dtype=float)
    if a.size == 0 or b.size == 0:
        return float("nan")
    # Mann-Whitney U / (n·m) == AUROC. 동점은 0.5 로 센다.
    gt = (b[:, None] > a[None, :]).sum()
    eq = (b[:, None] == a[None, :]).sum()
    return float((gt + 0.5 * eq) / (a.size * b.size))


if __name__ == "__main__":
    import wm_datasets
    from openworld_experiments import load_df
    from scores import ZRms, instance_ids

    path = wm_datasets.resolve(sys.argv[1] if len(sys.argv) > 1 else None)
    df = load_df(path)
    iids = instance_ids(df)
    s = ZRms().fit(df)
    band = ConformalBand.fit("z_rms/all-kinds", s.novelty(df, iids).values())
    print(band.summary())
    print("\nquantile ->  threshold   |  fraction of calibration set flagged outside")
    for q in QUANTILES:
        eta = band.threshold(q)
        frac = float(np.mean(band.cal > eta))
        print("  %5.0f%%  ->  %8.3f   |  %5.1f%%" % (q * 100, eta, 100 * frac))
    print("\nsanity: a far-away point should be outside at every quantile")
    far = float(band.cal.max()) * 3.0
    print("  score=%.3f -> outside90=%s outside95=%s outside100=%s  p=%.4f"
          % (far, band.is_outside(far, 0.90), band.is_outside(far, 0.95),
             band.is_outside(far, 1.00), band.pvalue(far)))
