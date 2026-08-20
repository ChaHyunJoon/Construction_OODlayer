#!/usr/bin/env python
"""
Export the trained surrogate to a portable JSON the Julia demo can evaluate NATIVELY
(no Python at decision time — PyCall's env holds rvo2 only, and we must not disturb it).

Why a LINEAR surrogate is faithful here: on the E1 dataset a Ridge model achieves the *identical*
leave-one-instance-out decision quality as the HistGradientBoosting model used in E1–E4
(**decision-regret 0.000 for both**), with a lower Level-0 R² (0.64 vs 0.83). That is exactly the
value-equivalence property EVALUATION.md §1 is built on: the predicted VALUES may be less accurate, but
the candidate-macro RANKING — and therefore every decision — is the same. So the demo's producer is
decision-equivalent to the surrogate the experiments were run with, while staying dependency-free.

COST-AWARE mode (`--cost-aware`, used by the OOD-stream demo)
------------------------------------------------------------
The default (E1–E4) target is raw `closed`, and the admissibility rule keeps only CONSEQUENTIAL
instances — which silently drops every battery instance in the tractor twin (a mild discharge is
absorbed by the spares, so all macros tie). A surrogate trained that way has *zero* battery rows:
its `kind_battery` and `soc` coefficients are exactly 0, and on a battery event it emits a near-tie
and picks whatever macro has the largest main effect. That is a hole, not a decision.

Cost-aware mode fixes it by (a) keeping the harmless instances and (b) charging each macro its
adaptation cost (a spare robot, a restage, a team re-form are not free):

    y = closed - LAMBDA * cost(macro),   cost = {NOOP 0, Deprioritize 0.3, Replace/ForbidZone/Reform 1.0}

(the cost vector is `OODRewardCfg` from decpomdp/examples/ood_env_mdp.jl; LAMBDA is in schedule-nodes).
Consequential events are unaffected — Replace still buys ~+21 nodes on a fault, far above the cost —
but when an OOD is absorbed anyway, NOOP now *wins*, so the model learns the third, RESTRAINT class:
do not spend a spare on a robot that will finish its haul. This is the "cost-aware intervene-or-not"
extension validated in DESIGN_NEXT.md §2.

Emits `surrogate_linear.json`:
  { feature_names: [...], mean: [...], scale: [...], coef: [...], intercept: float, meta: {...} }
Prediction = coef · ((x - mean) / scale) + intercept

Usage:
  python surrogate/export_surrogate.py <dataset.jsonl> [more.jsonl ...] [--cost-aware] [--lam 3.0] [-o out.json]
"""
# ※ 이 파일이 이름으로 인용하는 아래 md 문서는 2026-08-18 md 통합에서 내려갔다 —
#    (EVALUATION.md · DESIGN_NEXT.md · md/BATTERY_FAULT_REDESIGN_2026-08-05.md)
#    복구 SHA 는 `md/README.md` §9-A.

# =============================================================================
# [한국어 설명 - 처음 읽는 사람을 위한 안내]
#
# 이 파일은 무엇인가:
#   e1_analyze.py에서 검증한 surrogate(대리 예측 모델)를 "Julia 쪽에서 그대로 쓸 수 있는"
#   가벼운 형식(JSON)으로 내보내는(export) 스크립트다. Julia 데모는 결정을 내릴 때 Python을
#   부르지 않아야 하므로(PyCall 환경엔 rvo2만 있고 건드리면 안 됨), 모델을 순수 숫자 배열로
#   저장해 Julia가 직접 계산(evaluate)하게 만든다.
#
# 두 가지 export 형식:
#   1) linear(Ridge): StandardScaler + Ridge 회귀. 예측 = coef·((x-mean)/scale) + intercept.
#      E1 데이터에선 트리 모델과 "결정(순위)"이 동일해서 의존성 없는 가벼운 형태로 쓸 수 있다.
#   2) forest(RandomForest): 여러 결정트리. 임계값(threshold) 기반 "그레이드 뒤집힘"을 표현할 수 있어
#      기본값이다. E1~E4 실제 모델(HistGradientBoosting)과 같은 모델 클래스(트리)라 더 충실하다.
#
# 프로젝트에서의 역할:
#   학습·평가는 e1_analyze.py가, "배포용 산출물 만들기"는 이 파일이 담당. 여기서 만든
#   surrogate_linear.json(또는 forest json)을 Julia 데모가 producer로 로드해 OOD 대응 macro를 고른다.
#
# COST-AWARE 모드(--cost-aware):
#   기본 모드는 목표 y = closed(닫은 노드 수). 하지만 "무해한" OOD(예: 가벼운 배터리 방전)는
#   모든 macro가 비겨서 학습 신호가 없어진다. cost-aware는 (a) 무해한 instance도 남기고
#   (b) macro마다 개입 비용을 매겨(y = closed - LAMBDA*cost) "개입 안 하기(NOOP)"도 정답이
#   될 수 있게 한다 → 모델이 "자제(restraint)"라는 세 번째 선택지를 배운다.
#
# 실행 방법:
#   python surrogate/export_surrogate.py <dataset.jsonl> [추가.jsonl ...] [--cost-aware] [--lam 3.0] [-o out.json]
#   --linear 를 주면 forest 대신 Ridge(선형)를 내보낸다.
#
# ---- 문법 참고 (익숙하지 않을 수 있는 Python 표현) ----
#   * sys.path.insert(0, ...): 모듈 검색 경로 맨 앞에 core/ 를 추가 → 거기 있는 wmpath 가 나머지
#     코드 폴더까지 올려주고, 그래야 core/e1_analyze 를 맨이름으로 import 할 수 있다.
#   * from e1_analyze import ...: core/ 의 함수(load/featurize 등)를 재사용(중복 코드 방지).
#   * argparse: 명령줄 인자 파서. add_argument(nargs="+")=1개 이상, action="store_true"=플래그(있으면 True).
#   * pd.concat([...], ignore_index=True): 여러 DataFrame을 세로로 이어붙이고 인덱스를 새로 매김.
#   * sklearn 모델: Ridge=선형회귀(정규화), RandomForestRegressor=트리 앙상블, StandardScaler=표준화(평균0/분산1).
#     .fit(X, y)=학습, .predict(X)=예측. model.coef_/intercept_=학습된 계수/절편.
#   * json.dump(obj, f): 파이썬 객체를 JSON 파일로 저장. .tolist()=numpy 배열을 JSON 가능한 리스트로.
#   * [식 for x in 목록], {k: v for ...}: 리스트/딕셔너리 컴프리헨션.  f"...{x}...": f-string.
#   * est.tree_.children_left 등: sklearn 결정트리 내부 배열(왼/오른 자식, 분기 feature, 임계값, 잎 값).
#     feature 값 -2는 "잎 노드(leaf)"라는 표식.
# =============================================================================

import sys, os, json, math, argparse
import numpy as np
import pandas as pd
# 2026-08-18 폴더 분류: 옆 폴더(core/ 등)의 모듈을 맨이름으로 import 하려고 코드 폴더
# 전부를 sys.path 에 올린다(근거·쓰는 법은 core/wmpath.py 머리말). 분류 전에는 이 자리가
# `sys.path.insert(0, <이 파일 폴더>)` 한 줄이었다 — 그때는 모든 py 가 한 폴더였다.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import wmpath                                            # noqa: E402,F401
# core/e1_analyze 의 데이터 로드/자격판정/feature화/정렬키 함수를 그대로 재사용(일관성 유지).
from e1_analyze import (load, instance_admissible, featurize, lex_key, instance_arms_complete,
                        cost_lex_key_row)
from sklearn.linear_model import Ridge
from sklearn.ensemble import RandomForestRegressor
from surrogate_model import build_model, MODEL_NAME  # 평가·배포 단일 모델 정의
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import LeaveOneGroupOut

# adaptation cost per macro (OODRewardCfg, decpomdp/examples/ood_env_mdp.jl)
# macro별 개입 비용(e1_analyze와 동일). NOOP=0, Deprioritize=0.3, 나머지=1.0.
# 7 = RelocateBuild(1.5, 전역 개입).
#
# 2026-08-15: 리터럴을 **action_registry.json 파생**으로 바꿨다. 예전 주석은 "5·6 = 조합 팔"
# 이라고 적고 있었는데, 그 둘은 레지스트리 통합(2026-08-06) 때 어휘에서 빠졌고 이 표에만
# 이름 없이 비용으로 남아 있었다. 근거는 e1_analyze.MACRO_COST 위 주석 참조.
import action_registry as _reg                                      # noqa: E402

MACRO_COST = dict(_reg.MACRO_COST)

# State features that must be allowed to INTERACT with the chosen macro. Without these the exported
# model is purely additive and CANNOT represent the graded flip: on a battery OOD the value of NOOP
# rises with SoC (151 -> 213 -> 291) while the value of Replace stays flat (~172), so the two curves
# cross. An additive model gives every macro the same SoC slope and therefore ranks them identically
# at every SoC -- it can never flip. (The HistGradientBoosting model used in E1-E4 learns such
# interactions natively; only this dependency-free linear export needs them spelled out.)
# Naming convention `<state>__x__macro_<m>` is mirrored by the Julia demo's feature assembler.
# 선형 모델이 macro와 "상호작용(interaction)"할 수 있게 곱해줄 상태 feature 목록. 이게 없으면
# 선형 export는 순수 덧셈뿐이라 SoC에 따라 NOOP↔Replace가 뒤집히는 그레이드 현상을 표현 못 한다.
INTERACT = ["soc", "severity", "agent_pending", "spare_count", "zone_overlap",
            "kind_fault", "kind_battery", "kind_zoneblk"]


# feature표 F에 "상태 x macro" 교차항(interaction) 열을 추가한다. F[s] * (해당 macro면 1 아니면 0).
#
# [2026-08-05] 예전엔 `range(5)` 로 **macro 0~4 만** 교차항을 만들었다. 그래서 나중에 추가된
# 7(RelocateBuild)·8(SwapBattery)은 교차항이 없었고, 선형 export 는 그 두 팔에 대해 상태 의존적
# 순위(예: SoC 에 따라 SwapBattery↔NOOP 가 뒤집히는 것)를 **표현할 수 없었다**. 데이터에 실제로
# 등장하는 macro 로 범위를 잡는다 — macro 0~4 만 있는 옛 덤프에서는 결과가 예전과 **완전히 동일**하고
# (열 이름·순서까지), 새 덤프에서만 열이 늘어난다. Julia 쪽 조립기는 `feature_names` 를 읽어
# `<state>__x__macro_<m>` 을 이름으로 파싱하므로 자동으로 따라온다(demos.jl:2030).
def add_interactions(F, df):
    macros = sorted({int(m) for m in df.macro})
    for s in INTERACT:
        for m in macros:
            # 이름 규칙 <state>__x__macro_<m> 은 Julia 데모의 feature 조립기와 똑같이 맞춰져 있음.
            F[f"{s}__x__macro_{m}"] = F[s].values * (df.macro.values == m).astype(float)
    return F


# [2026-08-13] `cost_key` 를 삭제했다. 그것은 `e1_analyze.cost_lex_key` 와 **같은 옛 규칙의 두 번째
# 이름**이었고(`closed - lam*MACRO_COST` 로 feasibility-lexicographic 튜플), 이름이 달라서
# "cost_lex_key" 를 grep 하는 감사에 안 잡혔다 — spec §7 의 세대 혼입이 바로 이 모양이다.
# cost-aware 정렬키는 이제 하니스 전체와 같은 하나뿐이다: `e1_analyze.cost_lex_key_row` (= -J).
# (`--cost-time` 의 `cost_time_key` 는 λ 없는 **별도 설계의 대안 목적함수**라 그대로 둔다.)


# =============================================================================
#  TIME-PRICED cost (`--cost-time --mu M`) — the lambda-free alternative (2026-08-05)
# -----------------------------------------------------------------------------
#  왜 바꾸려 하는가 (측정 근거는 md/BATTERY_FAULT_REDESIGN_2026-08-05.md §3):
#    (1) lambda 는 **식별되지 않는다.** firegrid_merged(126 instance)에서 lambda 를 0.5 에서 30 까지
#        60배 움직여도 정답이 바뀌는 instance 가 3~4개(2.4~3.2%)뿐이다. 즉 "lambda=15 로 튜닝했다"는
#        말은 데이터가 뒷받침하지 않는다. lambda 가 실제로 하는 일은 크기와 무관한 **동점 처리**다
#        (lambda=0 에서 126 중 58개가 정확히 동점).
#    (2) lambda 는 **물리적으로 측정된 차이를 덮어쓸 수 있다.** closed 슬롯 안에 비용을 넣기 때문이다.
#        실측: `battery_s3_sev0.2_sp3` 은 Replace 가 NOOP 보다 12 노드를 더 닫는데(248 vs 260),
#        lambda=15 는 그 12 노드를 비용 15 로 지워 NOOP 을 정답으로 만든다. 이것은 자제(restraint)가
#        아니라 **손상**이다.
#    (3) 단위가 섞인다. "schedule 노드"와 "개입 비용"은 교환비가 정의된 적이 없다.
#
#  제안: 비용을 **makespan 초**로 매기고, feasibility 와 closed **아래** 계층에 둔다.
#        key = (complete, closed, -(makespan + mu * cost))
#    · mu = "개입 비용 1단위가 빌드 시간 몇 초의 가치인가" — 해석 가능하고 보고 가능한 교환비.
#    · 비용은 완주 여부도, 닫은 노드 수도 절대 뒤집을 수 없다 -> (2)의 손상이 구조적으로 불가능.
#    · 그런데도 자제는 표현된다: 무해한 사건에서 두 팔의 closed 가 같으면 시간+비용이 결정한다.
#    · lambda 와 달리 **식별된다**: 정답 분포가 mu 0.1~2.0 구간에서 실제로 움직이고 그 뒤 안정된다.
#  기본은 꺼짐 — `--cost-aware` 의 기존 경로는 한 글자도 바뀌지 않는다(핀 고정된 벤치마크 보존).
MK_INCOMPLETE = 1.0e3   # 미완주 팔의 시간 자리표. complete 항이 이미 졌으므로 순위엔 영향 없고,
                        # "둘 다 미완주 + closed 동일" 일 때만 비용이 갈라놓게 하는 역할.
TIME_SCALE = 100.0      # 시간 항을 노드 1개보다 작게 눌러, closed 를 절대 못 뒤집게 하는 나눗수.


def _mk(v):
    """makespan 셀을 float 로. JSON 에서 'Inf'/'NaN' 문자열로 오는 경우를 흡수한다."""
    if isinstance(v, str):
        return {"Inf": math.inf, "-Inf": -math.inf, "NaN": math.nan}.get(v, math.nan)
    return float(v) if v is not None else math.nan


def cost_time_key(complete, closed, makespan, macro, mu):
    """Feasibility > progress > (time + mu*cost). Cost can NEVER override closed or completion."""
    t = (makespan if (complete and math.isfinite(makespan)) else MK_INCOMPLETE) \
        + mu * MACRO_COST[int(macro)]
    return (1 if complete else 0, closed, -t)


def cost_time_score(complete, closed, makespan, macro, mu):
    """Scalar consistent with `cost_time_key` — the regression target AND the regret scale.

    1000*complete dominates closed (max 313), and the time term is divided by TIME_SCALE so it
    stays below 1 node — i.e. the scalarization reproduces the lexicographic order exactly for
    every (mu, cost) pair this repo uses.
    """
    t = (makespan if (complete and math.isfinite(makespan)) else MK_INCOMPLETE) \
        + mu * MACRO_COST[int(macro)]
    return 1000.0 * (1 if complete else 0) + float(closed) - t / TIME_SCALE


def export_forest(model, feature_names, meta):
    """Serialize a fitted RandomForestRegressor to plain arrays the Julia demo can walk.

    A linear model cannot express the GRADED task: the correct macro flips at a THRESHOLD (SoC ~0.15,
    zone_overlap ~0.4) and the flip depends on interactions. Even with explicit interaction columns,
    Ridge scored 0.500 decision-regret on the zone instances (top-1 0%). Trees represent thresholds
    natively -- and trees are what E1-E4 actually use (HistGradientBoosting) -- so the demo's producer
    is now the same MODEL CLASS as the evaluated surrogate, not a crippled stand-in.
    """
    trees = []
    for est in model.estimators_:  # 숲(forest) 안의 각 결정트리를 순회
        t = est.tree_  # sklearn 트리의 내부 배열 구조
        trees.append({
            "left": t.children_left.tolist(),       # 각 노드의 왼쪽 자식 인덱스
            "right": t.children_right.tolist(),     # 오른쪽 자식 인덱스
            "feature": t.feature.tolist(),          # -2 at leaves  (분기에 쓴 feature 번호, 잎이면 -2)
            "threshold": t.threshold.tolist(),      # 분기 임계값(feature <= threshold면 왼쪽)
            "value": [float(v[0][0]) for v in t.value],  # 각 잎의 예측값
        })
    # 2026-08-19/20 (태스크 5 리뷰 라운드 2 Critical #2 수정): 어휘 도장을 아티팩트에 찍는다.
    # action_registry.py/.jl 의 require_vocab() 계약("부재/불일치면 죽는다")을 이 producer 도
    # 따라야 한다 -- 안 그러면 은퇴한 macro 가 배포 피처 공간에 조용히 남는다(2026-08-19 실측:
    # surrogate_linear.json 이 vocab 없이 macro_3 9열을 담은 채 배포돼 있었다).
    return {"kind": "forest", "feature_names": list(feature_names), "trees": trees, "meta": meta,
            "vocab": _reg.VOCAB}


# 배포 JSON 의 meta.target 문자열(어떤 목적함수로 학습했는지 파일 안에 남긴다).
def _target_desc(a):
    if a.cost_aware and a.cost_time:
        return ("1000*complete + closed - (makespan + %.2f*adaptation_cost(macro))/%.0f"
                % (a.mu, TIME_SCALE))
    if a.cost_aware:
        return "closed - %.1f*adaptation_cost(macro)" % a.lam
    return "closed (schedule nodes completed) for this (state, macro)"


# 실제 실행 함수: 인자 파싱 → 데이터 로드/필터 → feature화 → LOO 정직성 검사 → 전체 데이터로 최종 학습·저장.
def main():
    ap = argparse.ArgumentParser()  # 명령줄 인자 파서 생성
    ap.add_argument("data", nargs="+")  # 하나 이상의 데이터셋 경로(여러 개면 합침)
    ap.add_argument("--cost-aware", action="store_true")  # 비용 반영 모드 on/off 플래그
    ap.add_argument("--linear", action="store_true", help="export Ridge instead of the forest")  # 선형 export
    ap.add_argument("--lam", type=float, default=3.0, help="adaptation cost in schedule-nodes")  # 비용 가중치
    # lambda-free 대안(2026-08-05). --cost-aware 와 함께 쓴다. 위 cost_time_key 주석 참조.
    ap.add_argument("--cost-time", action="store_true",
                    help="price adaptation cost in MAKESPAN SECONDS, strictly below feasibility "
                         "and closed-node count (lambda-free). Use with --cost-aware.")
    ap.add_argument("--mu", type=float, default=2.0,
                    help="makespan seconds per unit adaptation cost (--cost-time only)")
    # 출력 파일 경로. 기본은 이 스크립트 폴더의 surrogate_linear.json.
    ap.add_argument("-o", "--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                        "surrogate_linear.json"))
    a = ap.parse_args()  # 실제 인자 파싱 → a.data, a.cost_aware 등으로 접근

    df = pd.concat([load(p) for p in a.data], ignore_index=True)  # 모든 데이터셋을 로드해 하나로 합침
    df = df[df.fired == True].copy()  # OOD가 실제로 발동된 행만 남김

    if a.cost_aware:
        # keep every fired instance (harmless ones carry the restraint signal), but require that the
        # instance's OWN valid action set was fully labeled so the ranking is well defined.
        # [2026-08-05 버그 수정] 예전엔 `len(g) == 5` 였다. DS_VALID_ONLY 라벨은 그 사건에서 실제로
        # 실행 가능한 팔만(예: battery deep = NOOP/Replace/SwapBattery = 3팔) 라벨링하므로 5를 영영
        # 못 채우고 **통째로 버려졌다**. e1_analyze.py / dspy_service.py 는 이미 고쳤는데 이 배포
        # 경로만 남아 있었다. 판정을 `instance_arms_complete`(= 그 사건의 valid_mask 를 다 덮었는가)로 통일.
        keep = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
        dropped_note = "kept all fired instances (incl. harmless: NOOP can win)"
    else:
        # 기본: 고장이 실제로 영향을 준(admissible) instance만.
        keep = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
        dropped_note = "admissible instances only (EVALUATION.md rule)"
    df = df[df.instance.isin(keep)].reset_index(drop=True)  # 남길 instance만 필터 + 인덱스 재설정

    F = featurize(df)  # 상태 feature 표 생성(e1_analyze와 동일 함수)
    if a.cost_aware:
        F = add_interactions(F, df)      # required for the graded flip (see INTERACT)  (그레이드 뒤집힘 표현용 교차항)
    X = F.values
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])  # 행별 macro 비용
    if a.cost_aware and a.cost_time:
        # 시간가격 모드: 학습 목표도 정렬키와 **같은 스칼라**여야 한다(안 그러면 모델이 다른 것을 배운다).
        y = np.array([cost_time_score(bool(c), float(cl), _mk(mk), int(m), a.mu)
                      for c, cl, mk, m in zip(df.complete, df.closed, df.makespan, df.macro)])
    else:
        y = df.closed.astype(float).values - (a.lam * cost if a.cost_aware else 0.0)  # 학습 목표
    groups = df.instance.values  # 교차검증 그룹 = instance

    # 한 instance의 행들(g)에서 정답 macro를 찾는 헬퍼. 반환: (macro목록, macro별 closed, 정답 macro).
    def best_of(g, lam):
        ms = [int(v) for v in g.macro]
        cl = {int(x): float(v) for x, v in zip(g.macro, g.closed)}   # macro→closed
        cp = {int(x): bool(v) for x, v in zip(g.macro, g.complete)}  # macro→완주여부
        # macro→makespan (JSON에서 "Inf" 문자열로 온 경우 math.inf로 변환)
        mk = {int(x): (float(v) if not isinstance(v, str) else math.inf) for x, v in zip(g.macro, g.makespan)}
        # cost-aware면 비용 반영 키, 아니면 기본 lex_key로 정렬(백슬래시 \는 줄 이어짐).
        # --cost-time 이면 시간가격 키(비용이 closed 를 못 뒤집는 형태)를 쓴다.
        rowof = {int(r.macro): r for r in g.itertuples(index=False)}   # macro -> 행 전체(J 계산에 필요)
        if a.cost_aware and a.cost_time:
            key = lambda q: cost_time_key(cp[q], cl[q], mk[q], q, a.mu)
        elif a.cost_aware:
            key = lambda q: cost_lex_key_row(rowof[q])       # -J (spec §5.1)
        else:
            key = lambda q: lex_key(cp[q], cl[q], mk[q])
        # BUG FIX 2026-07-27: the returned score dict MUST be the one the objective is defined on.
        # It used to return raw `closed` even in cost-aware mode, so regret was measured blind to the
        # adaptation cost -- i.e. blind to exactly the term that makes NOOP-vs-Replace a decision.
        # In the cost-aware regime a harmless OOD has NOOP and Replace TIED on raw closed (both 291),
        # so a wrong pick scored 0 regret by construction and the exported metadata advertised
        # `loo_decision_regret: 0.000` when the true cost-aware value was 0.100 (measured, 20 inst).
        # 한국어: cost-aware 모드에서는 점수도 비용을 뺀 값으로 재야 한다. 예전엔 raw closed 로 재서,
        #   "개입 비용만 다르고 closed 는 같은" 바로 그 결정들이 전부 regret 0 으로 잡혔다.
        if a.cost_aware and a.cost_time:
            score = {q: cost_time_score(cp[q], cl[q], mk[q], q, a.mu) for q in ms}
        elif a.cost_aware:
            # 점수축 = 정렬키축 = -J. 위 BUG FIX 주석의 논리가 그대로 적용된다: 점수를 정렬키와
            # 다른 양으로 재면 regret 이 음수가 되거나 구조적으로 0 이 된다.
            score = {q: cost_lex_key_row(rowof[q]) for q in ms}
        else:
            score = dict(cl)
        return ms, score, max(ms, key=key)  # 키가 최대인 macro = 정답

    USE_FOREST = not a.linear  # --linear가 없으면 forest, 있으면 선형(Ridge)

    # 학습 데이터로 모델을 학습하고 시험 데이터 예측을 돌려주는 헬퍼(모드에 따라 forest 또는 Ridge).
    def fit_predict(Xtr, ytr, Xte):
        if USE_FOREST:
            m = build_model().fit(Xtr, ytr)   # 평가 스택과 "같은" 모델(surrogate_model.py)
            return m, m.predict(Xte)
        sc = StandardScaler().fit(Xtr)  # 표준화 스케일러를 학습 데이터로 맞춤
        m = Ridge(alpha=1.0).fit(sc.transform(Xtr), ytr)  # 표준화된 X로 Ridge 학습
        return (sc, m), m.predict(sc.transform(Xte))

    # --- honesty check: LOO decision quality of THIS model, under THIS scoring rule ---
    # 정직성 검사: 내보낼 이 모델이 leave-one-instance-out에서 실제로 얼마나 잘 고르는지(regret) 측정.
    regs, per_kind = [], {}
    for tr, te in LeaveOneGroupOut().split(X, y, groups):
        _, p = fit_predict(X[tr], y[tr], X[te])  # 나머지로 학습 → 빠진 instance 예측
        g = df.iloc[te]
        ms, cl, best = best_of(g, a.lam)  # 이 instance의 정답
        pick = ms[int(np.argmax(p))]  # 모델이 예측값 최대인 macro를 고름
        span = max(cl[best] - min(cl.values()), 1e-9)  # 정규화 폭
        r = (cl[best] - cl[pick]) / span  # 정규화 regret(0이면 완벽)
        regs.append(r)
        per_kind.setdefault(str(g.kind.iloc[0]), []).append((r, pick == best))  # kind별로 (regret, 정답맞춤여부) 저장
    loo_regret = float(np.mean(regs))  # 평균 LOO decision regret

    # --- final model on ALL data (this is what the demo deploys) ---
    # 최종 모델은 전체 데이터로 학습(위 LOO는 검증용, 이건 실제 배포용). meta에 재현 정보를 담는다.
    meta_common = {
        "target": _target_desc(a),
        "cost_aware": bool(a.cost_aware),
        "cost_mode": ("time" if (a.cost_aware and a.cost_time) else ("nodes" if a.cost_aware else None)),
        "lambda_nodes": a.lam if (a.cost_aware and not a.cost_time) else None,
        "mu_seconds": a.mu if (a.cost_aware and a.cost_time) else None,
        "trained_on": [os.path.basename(p) for p in a.data],
        "instance_filter": dropped_note,
        "kinds": sorted(set(str(k) for k in df.kind)),
        "n_instances": len(keep),
        "n_rows": int(len(df)),
        "loo_decision_regret": loo_regret,
    }
    if USE_FOREST:  # forest 모드: RandomForest를 전체 데이터로 학습해 트리 배열로 직렬화 저장.
        model = build_model().fit(X, y)
        meta_common["model"] = MODEL_NAME + " -- unified eval+deploy model (surrogate_model.py)"
        spec = export_forest(model, F.columns, meta_common)  # 트리들을 JSON 가능한 dict로 변환
        with open(a.out, "w") as f:
            json.dump(spec, f)  # 파일로 저장
        print(f"wrote {a.out}  [forest: {len(spec['trees'])} trees, {len(spec['feature_names'])} features]")
        print(f"  {dropped_note}: {len(keep)} instances / {len(df)} rows; kinds={meta_common['kinds']}")
        print(f"  LOO decision-regret = {loo_regret:.3f}   (cost_aware={a.cost_aware}, lambda={a.lam})")
        for k, v in sorted(per_kind.items()):  # kind별 regret과 top-1 정확도 출력
            acc = 100.0 * sum(1 for _, ok in v if ok) / len(v)
            print(f"    {k:9s} n={len(v):2d}  regret={np.mean([r for r, _ in v]):.3f}  top1-correct={acc:.0f}%")
        # 8 = SwapBattery 가 빠져 있어, macro 8 을 고르는 순간 KeyError 로 죽었다(2026-08-05 실측:
        # 새 battery 덤프에서 학습은 끝났는데 요약을 찍다가 죽음). Julia 쪽 ACTION_NAME 과 맞춘다.
        names = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone", 4: "ReformTeam",
                 5: "ForbidAgent+ReformTeam", 6: "Deprioritize+ForbidWindow", 7: "RelocateBuild",
                 8: "SwapBattery"}
        df2 = df.copy(); df2["pred"] = model.predict(X)  # 학습행에 대한 예측을 붙여
        print("  chosen macro per kind (on training rows):")
        for k, gk in df2.groupby("kind"):
            # 각 instance에서 예측 최대(idxmax)인 macro를 뽑아 kind별로 몇 번 골랐는지 센다.
            picks = [int(g.loc[g.pred.idxmax()].macro) for _, g in gk.groupby("instance")]
            print(f"    {k:9s} -> { {names[m]: picks.count(m) for m in sorted(set(picks))} }")
        return  # forest 모드는 여기서 종료(아래 선형 코드는 실행 안 함)

    # --- 선형(Ridge) 모드: 표준화 + Ridge를 전체 데이터로 학습 ---
    sc = StandardScaler().fit(X)  # 평균/표준편차 계산
    model = Ridge(alpha=1.0).fit(sc.transform(X), y)  # 표준화된 X로 선형 회귀 학습

    # Julia가 예측을 재현하는 데 필요한 모든 숫자를 담는다. 예측 = coef·((x-mean)/scale) + intercept.
    spec = {
        "feature_names": list(F.columns),   # feature 이름 순서(Julia가 x를 이 순서로 만들어야 함)
        "mean": sc.mean_.tolist(),          # 표준화용 평균
        "scale": sc.scale_.tolist(),        # 표준화용 표준편차
        "coef": model.coef_.tolist(),       # 학습된 계수
        "intercept": float(model.intercept_),  # 절편
        # 2026-08-19/20 (태스크 5 리뷰 라운드 2 Critical #2 수정): 어휘 도장. 부재/불일치 시 로더가
        # 죽어야 한다(action_registry.require_vocab 과 같은 계약) -- 안 그러면 은퇴한 macro 의
        # one-hot 열이 배포 피처 공간에 조용히 남는다.
        "vocab": _reg.VOCAB,
        "meta": {
            "target": _target_desc(a),
            "model": "StandardScaler + Ridge(alpha=1.0)",
            "cost_aware": bool(a.cost_aware),
            "cost_mode": ("time" if (a.cost_aware and a.cost_time) else ("nodes" if a.cost_aware else None)),
            "lambda_nodes": a.lam if (a.cost_aware and not a.cost_time) else None,
            "mu_seconds": a.mu if (a.cost_aware and a.cost_time) else None,
            "trained_on": [os.path.basename(p) for p in a.data],
            "instance_filter": dropped_note,
            "kinds": sorted(set(str(k) for k in df.kind)),
            "n_instances": len(keep),
            "n_rows": int(len(df)),
            "loo_decision_regret": loo_regret,
        },
    }
    with open(a.out, "w") as f:
        json.dump(spec, f, indent=1)  # 사람이 읽기 좋게 들여쓰기(indent=1)로 저장
    print(f"wrote {a.out}")
    print(f"  features({len(spec['feature_names'])}): {spec['feature_names']}")
    print(f"  {dropped_note}: {len(keep)} instances / {len(df)} rows; kinds={spec['meta']['kinds']}")
    print(f"  LOO decision-regret = {loo_regret:.3f}   (cost_aware={a.cost_aware}, lambda={a.lam})")
    for k, v in sorted(per_kind.items()):  # kind별 regret/정확도 출력
        acc = 100.0 * sum(1 for _, ok in v if ok) / len(v)
        print(f"    {k:9s} n={len(v):2d}  regret={np.mean([r for r, _ in v]):.3f}  top1-correct={acc:.0f}%")
    # what does the exported model actually choose, per kind? (the demo's behaviour, checked here)
    # 내보낸 모델이 kind별로 실제 무엇을 고르는지 확인(= Julia 데모가 보일 행동을 여기서 미리 점검).
    print("  chosen macro per kind on the training rows:")
    df2 = df.copy(); df2["pred"] = model.predict(sc.transform(X))  # 학습행 예측값 부착
    for k, gk in df2.groupby("kind"):
        picks = []
        for _, g in gk.groupby("instance"):
            picks.append(int(g.loc[g.pred.idxmax()].macro))  # instance마다 예측 최대 macro
        # 8 = SwapBattery 가 빠져 있어, macro 8 을 고르는 순간 KeyError 로 죽었다(2026-08-05 실측:
        # 새 battery 덤프에서 학습은 끝났는데 요약을 찍다가 죽음). Julia 쪽 ACTION_NAME 과 맞춘다.
        names = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone", 4: "ReformTeam",
                 5: "ForbidAgent+ReformTeam", 6: "Deprioritize+ForbidWindow", 7: "RelocateBuild",
                 8: "SwapBattery"}
        cnt = {names[m]: picks.count(m) for m in sorted(set(picks))}  # macro별 선택 횟수 집계
        print(f"    {k:9s} -> {cnt}")


# 직접 실행할 때만 main() 호출(다른 파일이 import하면 함수만 가져가고 실행은 안 됨).
if __name__ == "__main__":
    main()
