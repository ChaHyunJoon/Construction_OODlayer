#!/usr/bin/env python
"""
drift_detectors.py -- E3/E4의 ACTIVE 재학습 루프가 쓰는 "교체 가능한(pluggable) drift 감지기".

공통 인터페이스: 감지기는 .update(x) -> bool(drift 여부) 와 .reset() 두 메서드만 가진다.
루프는 감지기 종류를 몰라도 되고, CUSUM/ADWIN 어느 것이든 끼워 쓸 수 있다.

  * CusumDetector  -- 원래 E3가 쓰던 one-sided(단측) CUSUM/Page-Hinkley.
                      잔차를 누적(slack만큼 빼서)해 threshold를 넘으면 발화. 손튜닝 임계 2개(slack, thresh).
  * AdwinDetector  -- ADWIN2(river). 가변 윈도우를 모든 분할점에서 집중부등식으로 검정 → 엄밀한 FP/FN 경계.
                      knob은 δ(오탐확률 상한) 하나. 단, 짧은 스트림용으로 clock=1 및 작은 grace/min_window 필요.

■ 핵심 교훈(이 파일이 존재하는 이유): "어떤 감지기냐"보다 "무엇을 감지기에 먹이냐(signal)"가 더 중요하다.
  E3/E4가 원래 먹이던 value-residual |pred - true_closed| 에는 이 과제의 drift 신호가 사실상 없다
  (drift 이후 잔차가 오히려 더 작다 — surrogate는 좋은 RANKER지만 값(closed) 회귀는 노이즈가 커서
   잔차가 회귀오차에 지배됨). 실제 drift는 OOD 종류가 fault→zone 으로 바뀌는 COVARIATE shift 이고,
  이는 상태 feature가 bootstrap 분포에서 얼마나 벗어났는지를 재는 novelty 점수로 깨끗이 잡힌다.
  → 그래서 아래 make_novelty(가 그 covariate-shift 신호를 만든다.

[문법 참고]
  · @property : 메서드를 속성처럼 쓰게 함(det.name). · float(x) : 확실히 실수로 변환.
  · np.clip(a, lo, hi) : a를 [lo,hi]로 자름(0-분산 feature에서 z가 폭발하는 것 방지).
"""
import math
import numpy as np


class CusumDetector:
    """단측 CUSUM. s <- max(0, s + x - slack); s > thresh 이면 발화. reset()으로 s=0."""
    def __init__(self, slack=8.0, thresh=60.0):
        self.slack = slack        # 정상 변동 허용치(이만큼 빼서 잔잔한 노이즈는 안 쌓임)
        self.thresh = thresh      # 발화 임계
        self.s = 0.0              # 누적합 상태
    def update(self, x):
        self.s = max(0.0, self.s + float(x) - self.slack)  # 누적(0 미만이면 0)
        return self.s > self.thresh                        # 임계 초과면 drift 신호
    def reset(self):
        self.s = 0.0              # 재학습 후 호출(원래 코드의 cusum=0.0 대응)
    @property
    def name(self):
        return f"CUSUM(slack={self.slack},thresh={self.thresh})"


class AdwinDetector:
    """ADWIN2(river) 래퍼. update로 값을 흘려보내고 drift_detected를 반환. reset은 윈도우 재생성.

    짧은 스트림 주의: river ADWIN 기본값(clock=32, grace_period=10)은 수천 스텝용이라
    수십 스텝짜리 스트림에선 아예 발화하지 못한다. 그래서 clock=1(매 스텝 검사)과
    작은 grace_period/min_window_length가 필수. 그래도 ADWIN의 엄밀한 FP 보장이 요구하는
    ε_cut 때문에, 표본이 너무 적으면(예: post-drift 9개) 어떤 δ로도 발화가 불가능할 수 있다."""
    def __init__(self, delta=0.05, clock=1, grace_period=5, min_window_length=5):
        from river.drift import ADWIN            # 지연 import(river 없어도 이 모듈 import는 되도록)
        self._ADWIN = ADWIN
        self._kw = dict(delta=delta, clock=clock,
                        grace_period=grace_period, min_window_length=min_window_length)
        self.a = ADWIN(**self._kw)
    def update(self, x):
        self.a.update(float(x))                  # 값 하나 흘려보냄(윈도우 갱신)
        return bool(self.a.drift_detected)       # 이 스텝에 변화 감지됐나
    def reset(self):
        self.a = self._ADWIN(**self._kw)         # 재학습 후 윈도우 초기화(하강 보정 오탐 방지)
    @property
    def name(self):
        return f"ADWIN(delta={self._kw['delta']},grace={self._kw['grace_period']})"


class ConformalMartingaleDetector:
    """Conformal test martingale(Vovk) — 손튜닝 임계 없이 knob = alpha(오탐확률) 하나로 drift 감지.

    고정된 calibration 집합(= in-distribution=bootstrap의 nonconformity 점수)에 대한 온라인 exchangeability 검정:
      · 새 점수의 conformal p-value 를 calibration 대비 계산(교환가능=정상이면 p~Uniform).
      · p-value 에 mixture-of-power 베팅 → martingale M(M0=1, null 하 E[M]=1) 축적.
      · M >= 1/alpha 면 발화 → Ville 부등식으로 **P(정상인데 오발화) <= alpha** 보장(anytime-valid).
    즉 CUSUM 의 slack/thresh 손튜닝을 alpha 하나로 대체하고 통계 보장까지 얻는다. 계산은 log 공간.

    signal 은 novelty(covariate-shift)를 쓴다. novel(높은)한 점일수록 p 가 작아지고(=calibration 대부분보다 큼)
    베팅 자산이 커진다. 파산 방지 위해 log 공간 + p 하한(p_floor).

    ■ 한계(정직): 보장은 calibration 의 대표성만큼만 유효하다. bootstrap 이 작고(예: 7개) 편향되면
      phase-A 에서 소수의 오발화가 날 수 있다(ADWIN 과 공유하는 "작은 표본" 함정). ADWIN 과 달리
      **짧은 스트림에서도 발화**하고 증거가 곱셈으로 쌓여 graceful 하다. reset()은 자산만 1로(재학습 후 호출), calibration 은 유지.

    [문법 참고] · np.linspace(a,b,k) : a~b 를 k등분한 배열. · math.log/np.log : 자연로그.
      · logsumexp 트릭(m=max 빼고 exp) : 오버플로 없이 log(sum exp) 계산.
    """
    def __init__(self, cal_scores, alpha=0.05, eps_grid=None, p_floor=1e-4):
        self.cal = [float(s) for s in cal_scores]           # 고정 calibration 점수(bootstrap novelty들)
        self.alpha = alpha
        self.eps = np.linspace(0.1, 0.9, 9) if eps_grid is None else np.asarray(eps_grid, dtype=float)  # 베팅 강도 grid
        self.p_floor = p_floor                              # p 하한(한 스텝에 자산 폭발 방지)
        self.log_thresh = math.log(1.0 / alpha)             # 발화 임계 = log(1/alpha)
        self.logM = np.zeros(len(self.eps))                 # arm 별 log-자산(자산=1 → log 0)
    def _pvalue(self, x):
        # smoothed conformal p-value: calibration 중 x 보다 큰 비율(+동점 절반). novel-높은 x → p 작음.
        n = len(self.cal)
        gt = sum(1 for r in self.cal if r > x)
        eq = sum(1 for r in self.cal if r == x)
        p = (gt + 0.5 * (eq + 1)) / (n + 1)
        return min(max(p, self.p_floor), 1.0)
    def update(self, x):
        if not self.cal:                                    # calibration 없으면 판정 불가
            return False
        p = self._pvalue(float(x))
        # 각 arm 의 log-자산에 log g_eps(p)=log(eps)+(eps-1)log(p) 를 더함(null 에 반해 베팅).
        self.logM += np.log(self.eps) + (self.eps - 1.0) * math.log(p)
        m = float(np.max(self.logM))                        # logsumexp 로 mixture(=arm 평균 자산)의 log
        mix = m + math.log(float(np.mean(np.exp(self.logM - m))))
        return mix >= self.log_thresh                       # 자산이 1/alpha 넘으면 발화
    def reset(self):
        self.logM = np.zeros(len(self.eps))                 # 재학습 후: 자산만 1로 초기화(calibration 은 유지)
    @property
    def name(self):
        return f"Conformal(alpha={self.alpha})"


def make_novelty(boot_feats, cap=8.0):
    """bootstrap 상태-feature들로 covariate-shift novelty 점수 함수를 만든다.

    novelty(x) = bootstrap 평균/표준편차로 표준화한 x의 RMS z-거리(각 z는 ±cap로 클리핑).
    bootstrap 분포(=익숙한 OOD 종류)에서 멀수록 크다 → drift(새 종류)에서 급증.
    cap: 0-분산 feature(예: bootstrap에서 늘 같은 값)에서 z가 무한대로 튀는 것 방지."""
    B = np.asarray(boot_feats, dtype=float)
    mu = B.mean(axis=0)
    sd = B.std(axis=0) + 1e-9                    # 0으로 나누기 방지
    def novelty(x):
        z = np.clip((np.asarray(x, dtype=float) - mu) / sd, -cap, cap)
        return float(np.sqrt(np.mean(z * z)))    # RMS z-거리
    return novelty
