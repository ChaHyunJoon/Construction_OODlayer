#!/usr/bin/env python3
"""SurrogateV2 — J 의 분기 구조를 그대로 모사하는 2-헤드 예측기 (spec §3.3).

    A: P(complete | s,a)                                 분류
    B: E[makespan + w_E*energy_J | s,a, complete]         회귀
    C: E[total - closed | s,a, not complete]              회귀

    Ĵ = P*B + (1-P)*(C_fail + C_unclosed*C + tie_eps*B)
    ΔĴ(a) = Ĵ(a) - Ĵ(NOOP)      <- 결정에 쓰는 값(낮을수록 좋음)

왜 2-헤드인가: J 는 완주 여부에서 C_fail(=10000) 짜리 절벽이 있다. 이봉분포를 하나의
제곱오차 회귀로 넘으면 안 된다. 나누면 절벽이 분류기로 흡수되고, "이 개입이 빌드를
완주시키는가" 가 독립된 학습 문제가 된다 — 2026-08-13 결함이 정확히 그 지점이었다.

왜 ΔJ 인가: 학습셋에서 타깃 분산의 78% 가 'instance 난이도' 다(between 2130 vs within 612).
같은 instance 안에서 빼면 그 성분이 정의상 소거되고, 모델 용량 전부가 팔 간 차이에 간다.

상수는 전부 objective.json 에서 읽는다 — 리터럴 복붙 금지(audit_objective 항목 1).
"""
import os
import sys

import numpy as np

# 2026-08-18 폴더 분류: 옆 폴더(core/ 등)의 모듈을 맨이름으로 import 하려고 코드 폴더
# 전부를 sys.path 에 올린다(근거·쓰는 법은 core/simulator_paths.py 머리말). 분류 전에는 이 자리가
# `sys.path.insert(0, <이 파일 폴더>)` 한 줄이었다 — 그때는 모든 py 가 한 폴더였다.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import simulator_paths                                            # noqa: E402,F401
import objective                                        # noqa: E402
from surrogate_features import build_features           # noqa: E402

from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor

# 286행 예산에 맞춘 하이퍼파라미터. max_depth=3 이 핵심 — 현행 배포의 6 은 instance 를 암기한다.
_HP = dict(max_depth=3, max_iter=300, learning_rate=0.05,
           min_samples_leaf=5, l2_regularization=1.0, early_stopping=True, random_state=0)

# 헤드 A(완주 분류기)의 **교정 오차**. 독립 검증(2026-08-14)의 실측값 ~1e-2 다.
# 임계값을 고르는 손잡이가 아니라 측정된 물리량이라 여기 상수로 박는다 — 이 값을 데이터에
# 맞춰 흔드는 순간 그것은 게이트 맞추기다(Task 6 fix round 1 의 명시 지시).
#
# 2026-08-14 (Task 7) 배포 추정기 위에서 **다른 양**을 하나 쟀다 — 값은 그대로 둔다.
#   `measure_p_calibration_error.py` 가 전량 적합(=배포) 헤드 A 에서 instance 단위 부트스트랩
#   (B=50, seed 0)으로 `{0,1,8}` 15 instance 의 팔 간 P̂ 격차 불안정성을 쟀고, 사전 선언한
#   집계(per-instance 표준편차의 평균)로 **0.010001** 이 나왔다.
#
#   ★ 이것을 "상수가 재현됐다"고 읽으면 안 된다 (2026-08-14 검토에서 정정).
#     위 0.01 은 out-of-fold **교정 오차** |P̂ − P| 이고, 0.010001 은 **팔 간 P̂ 차이의
#     부트스트랩 표준편차** 다. 서로 **다른 추정량**이라 네 자리 일치는 우연이지 상호 확인이
#     아니다. 게다가 그 평균은 instance 하나가 끌고 있다(`battery_s4_..._f220`, s=0.02532 —
#     빼면 0.008906). 같은 분포의 **중앙값은 0.00770** 으로 0.01 보다 뚜렷이 낮다.
#     정직한 진술: "정의가 인접한 독립 측정량이 마침 근처에 떨어졌고, 그 분포의 중앙값은
#     이 상수보다 낮다." 그 이상을 주장하지 말 것.
#
#   그래서 리터럴을 건드리지 않는다. 0.010001 로 바꾸는 것은 거짓 정밀도이고 어떤 결정도
#   바꾸지 않는다(실측: 126-state 격자가 두 값에서 바이트 동일).
#
#   ★ 그리고 이 문턱은 애초에 **재매개화 불변이 아니다**: 배포 운용점의 0.99193 vs 0.97848 은
#     확률 공간에서 0.0135 지만 logit 공간에서는 ≈0.98 이다. 불안정성도 등분산이 아니고
#     (instance 별 sd 0.0074~0.0253, 3.4배), 위 측정은 **라벨셋 상태**에서 쟀지 배포 운용점에서
#     쟀다. 절대 격차 문턱을 상수 하나로 두는 설계 자체가 그만큼 무른 것이며, 이것은 상수를
#     움직이지 **않을** 또 하나의 이유다.
P_CALIBRATION_ERROR = 0.01


def _w_E(cfg):
    """w_E = kappa * M_ref / E_ref. 스케일이 null 이면 에러(0/1 로 폴백하지 않는다)."""
    for k in ("kappa", "M_ref", "E_ref"):
        if cfg.get(k) is None:
            raise objective.ObjectiveError("objective.json 의 %s 가 null 이라 w_E 를 만들 수 없다" % k)
    return float(cfg["kappa"]) * float(cfg["M_ref"]) / float(cfg["E_ref"])


class SurrogateV2:
    def __init__(self, cfg=None):
        self.cfg = cfg or objective.load()
        self.w_E = _w_E(self.cfg)
        self.head_a = HistGradientBoostingClassifier(**_HP)
        self.head_b = HistGradientBoostingRegressor(loss="absolute_error", **_HP)
        self.head_c = HistGradientBoostingRegressor(loss="absolute_error", **_HP)
        self._b_fallback = 0.0
        self._c_fallback = 0.0

    # ---- 학습 ----------------------------------------------------------------
    def fit(self, rows):
        X = build_features(rows).values
        comp = np.array([bool(r.get("complete")) for r in rows])

        self.head_a.fit(X, comp.astype(int))

        # B: 완주 행만. 시간 + 에너지 (= J 의 완주 분기)
        if comp.any():
            yb = np.array([float(r["makespan"]) + self.w_E * float(r["energy_J"])
                           for r, c in zip(rows, comp) if c])
            self.head_b.fit(X[comp], yb)
            self._b_fallback = float(np.median(yb))
        # C: 미완주 행만. 남은 노드 수
        if (~comp).any():
            yc = np.array([float(r["total"]) - float(r["closed"])
                           for r, c in zip(rows, comp) if not c])
            self.head_c.fit(X[~comp], yc)
            self._c_fallback = float(np.median(yc))
        self._fitted_b = bool(comp.any())
        self._fitted_c = bool((~comp).any())
        return self

    # ---- 예측 ----------------------------------------------------------------
    def predict_complete_proba(self, rows):
        X = build_features(rows).values
        p = self.head_a.predict_proba(X)
        # 한 클래스만 본 경우 predict_proba 가 1열이다.
        return p[:, 1] if p.shape[1] == 2 else np.full(len(rows), float(self.head_a.classes_[0]))

    def predict_J(self, rows):
        X = build_features(rows).values
        p = self.predict_complete_proba(rows)
        b = self.head_b.predict(X) if self._fitted_b else np.full(len(rows), self._b_fallback)
        c = self.head_c.predict(X) if self._fitted_c else np.full(len(rows), self._c_fallback)
        c = np.clip(c, 0.0, None)
        C_fail = float(self.cfg["C_fail"])
        C_unclosed = float(self.cfg["C_unclosed"])
        tie_eps = float(self.cfg["tie_eps"])
        return p * b + (1.0 - p) * (C_fail + C_unclosed * c + tie_eps * b)

    def predict_delta_J(self, rows, ref_macro=0):
        """같은 instance 의 ref_macro 행을 기준으로 뺀다. 기준 행이 없으면 그 instance 의 평균.

        ⚠️ **결정에는 영향이 없다** (2026-08-14 확인, spec §3.2 의 설계 결함).
        같은 instance 안에서 빼는 값은 팔에 무관한 **상수**이므로
        `argmin_a (Ĵ(a) − const) ≡ argmin_a Ĵ(a)` 다. 그리고 헤드 B·C 는 ΔJ 가 아니라
        **절대 타깃**(makespan+에너지, 미닫힘 노드 수)에 적합된다. 즉 "타깃 분산의 78% 인
        instance 난이도 성분이 정의상 소거된다"는 §3.2 의 근거는 이 구현에서 **실현되지
        않는다** — 소거는 학습이 아니라 출력 후처리에서 일어나고, 학습은 그 이득을 못 본다.
        ΔJ 를 실제로 실현하려면 헤드가 instance 내 차분 타깃에 적합돼야 한다.
        이 값은 여전히 해석·보고용으로는 쓸모가 있다("이 개입은 NOOP 대비 3.2초 개선").
        """
        J = self.predict_J(rows)
        by_inst = {}
        for i, r in enumerate(rows):
            by_inst.setdefault(r.get("instance"), []).append(i)
        out = np.array(J, dtype=float)
        for _, idx in by_inst.items():
            ref = [i for i in idx if int(rows[i]["macro"]) == int(ref_macro)]
            base = J[ref[0]] if ref else float(np.mean(J[idx]))
            out[idx] = J[idx] - base
        return out

    # ---- 결정 규칙 (2026-08-14 추가) -------------------------------------------
    def predict_B(self, rows):
        """헤드 B 의 원값 = E[makespan + w_E*energy_J | 완주].  J 의 완주 분기 그 자체."""
        if not getattr(self, "_fitted_b", False):
            return np.full(len(rows), self._b_fallback, dtype=float)
        return np.asarray(self.head_b.predict(build_features(rows).values), dtype=float)

    def predict_C(self, rows):
        """헤드 C 의 원값 = E[total − closed | 미완주].  J 의 **미완주** 분기 그 자체.

        `predict_J` 과 같이 0 밑으로 클램프한다 — 음수 잔여 노드는 미완주 J 를 0 이하로
        떨어뜨려 '실패가 전역 최적'이 되게 만든다(objective.J 의 I-1 클램프와 같은 이유).
        """
        if not getattr(self, "_fitted_c", False):
            c = np.full(len(rows), self._c_fallback, dtype=float)
        else:
            c = np.asarray(self.head_c.predict(build_features(rows).values), dtype=float)
        return np.clip(c, 0.0, None)

    def choose(self, rows, rule="argmin_jhat", deadband=P_CALIBRATION_ERROR):
        """instance -> 고른 macro.  `rows` 는 그 instance 의 legal 팔 행만 담고 있어야 한다.

        rule="argmin_jhat"  (기준선) 조립된 Ĵ 의 argmin. spec §3.2 의 원래 규칙.

        rule="deadband_B"   2단 규칙: ① P̂ 가 최댓값에서 `deadband` 안에 드는 팔만 남기고
                            ② 그중 B̂ 가 가장 작은 팔을 고른다.
                            **알려진 결함**: ②가 헤드 C 를 통째로 버린다. 어떤 팔로도 완주하지
                            못하는 instance(이 데이터의 53/155)에서는 모든 팔이 deadband 안에
                            들어오고, 그때 팔 간 진짜 J 차이는 전부 C_unclosed·ΔĈ 인데 B̂ 는
                            완주 행에만 적합돼 그 정보를 갖고 있지 않다. 실측 675 → 1734.
                            아래 deadband_Jbar 가 이것을 분기 없이 고친다.

        rule="deadband_Jbar"  2단 규칙이되 ②를 **목적함수 자신의 구조**로 바꾼다:
                            ① 은 동일. ② 는 deadband 집합 전체에 **공유된** 완주확률 P̄
                            (= 그 집합의 max P̂) 하나로 J 를 조립해 argmin 한다.

                                Ĵ_db(a) = P̄·B̂(a) + (1−P̄)·(C_fail + C_unclosed·Ĉ(a) + tie_eps·B̂(a))

                            왜 이것이 두 번째 추측이 아닌가: ①이 이미 "이 집합 안의 P̂ **차이**는
                            교정 오차 아래라 정보가 없다"를 확정했다. 그러면 ②가 지워야 할 것은
                            정확히 그 **차이**뿐이고 그 이상도 이하도 아니다. 공통 P̄ 를 대입하는
                            것이 바로 그 연산이다 — P̂ 의 **수준**(=진짜 정보)은 남기고 **차이**만
                            소거한다. 두 헤드가 모두 제 가중치로 살아 있다.
                            분기 없이 두 레짐이 따라 나온다: P̄≈1 이면 argmin B̂ 로,
                            P̄≈0 이면 argmin Ĉ 로 자동 환원된다. 새 자유 파라미터는 없다.

        왜 2단인가 — 이것은 임계값 탐색이 아니라 **알려진 증폭의 교정**이다.
        조립식 Ĵ = P·B + (1−P)·(C_fail + C_unclosed·C + tie_eps·B) 를 P 로 미분하면
        dĴ/dP ≈ −20,500 J 다. 즉 완주확률 **1%p** 차이가 Ĵ 를 200 J 넘게 움직인다.
        그런데 헤드 A 의 교정 오차는 ~1e-2 (=1%p) 라, **정보가 아닌 잡음이 헤드 B 가 직접
        재는 몇 J 짜리 진짜 차이를 두 자릿수 차이로 압도한다.** 2026-08-14 독립 검증 실측:
        문제의 15 instance 에서 헤드 B 단독은 SwapBattery 를 15/15 로 옳게 고르는데,
        조립된 Ĵ 는 0/15 다 — 신호는 있고 조립이 그것을 파괴한다.
        원칙: **P̂ 차이가 분류기의 교정 오차보다 작으면 그 차이는 정보를 담고 있지 않으므로,
        회귀 헤드가 직접 측정한 J 차이를 뒤집도록 허용해서는 안 된다.**
        """
        if rule not in ("argmin_jhat", "deadband_B", "deadband_Jbar"):
            raise ValueError("알 수 없는 결정 규칙: %r" % (rule,))
        # 규칙이 필요로 하는 것만 계산한다 — 헤드 A/B/C 가 없는 베이스라인(RidgeJ 등)도
        # "argmin_jhat" 으로는 그대로 돌아야 하기 때문이다.
        if rule == "argmin_jhat":
            score = self.predict_J(rows)
        else:
            p = self.predict_complete_proba(rows)
            b = self.predict_B(rows)
            c = self.predict_C(rows) if rule == "deadband_Jbar" else None
        by_inst = {}
        for i, r in enumerate(rows):
            by_inst.setdefault(r.get("instance"), []).append(i)
        out = {}
        for iid, idx in by_inst.items():
            if rule == "argmin_jhat":
                pick = idx[int(np.argmin(score[idx]))]
            else:
                keep = [i for i in idx if p[i] >= p[idx].max() - deadband]
                if rule == "deadband_B":
                    pick = keep[int(np.argmin(b[keep]))]
                else:
                    # 공유 P̄ 로 조립한다. P̄ 는 deadband 집합의 max P̂ — 그 집합의 정의상
                    # instance 전체의 max 와 같다. 상수는 objective.json 에서 읽는다.
                    p_bar = float(p[idx].max())
                    C_fail = float(self.cfg["C_fail"])
                    C_unclosed = float(self.cfg["C_unclosed"])
                    tie_eps = float(self.cfg["tie_eps"])
                    j_db = np.array(
                        [p_bar * b[i] + (1.0 - p_bar) * (C_fail + C_unclosed * c[i]
                                                         + tie_eps * b[i]) for i in keep])
                    pick = keep[int(np.argmin(j_db))]
            out[iid] = int(rows[pick]["macro"])
        return out
