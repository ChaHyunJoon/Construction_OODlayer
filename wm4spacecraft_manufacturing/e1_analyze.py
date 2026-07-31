"""
E1-c: feature-model ranking baseline over the oracle dataset (gen_oracle_dataset.jl output).

Goal (the E1 de-risk milestone): does a STATE-READING model rank the candidate DSL macros in
correlation with the TRUE (oracle) ranking, and thereby pick lower-regret macros than the best
state-BLIND baseline ("always pick the globally most-common best macro")? If yes -> the surrogate
has a learnable signal -> invest in the GNN. If the feature model ties the always-X baseline, the
current instance set is not yet discriminative (need more OOD-type/severity variation).

Scoring follows EVALUATION.md: feasibility-lexicographic (complete, then closed-count, then realized
makespan), per-scenario normalization, top-1 decision regret as THE metric, plus NDCG@k / top-k
recall / agreement / catastrophic-choice rate. Evaluation is leave-one-INSTANCE-out (grouped), so the
model is always judged on an OOD instance it did not train on (paired with the oracle on that instance).

Usage:  python e1_analyze.py <dataset.jsonl>
"""

# =============================================================================
# [한국어 설명 - 처음 읽는 사람을 위한 안내]
#
# 이 파일은 무엇인가:
#   ConstructionBots.jl(여러 로봇이 협력해 구조물을 조립하는 TAMP 시뮬레이터)에서
#   갑작스러운 이상상황(OOD: 로봇 고장/배터리 방전/통행금지 구역 등)이 생겼을 때,
#   어떤 대응 "macro"(DSL 매크로: NOOP/Replace/Deprioritize/ForbidZone/ReformTeam)를
#   골라야 하는지를 학습하는 surrogate(대리 예측 모델)의 성능을 평가하는 스크립트다.
#
# 프로젝트에서의 역할:
#   - oracle(정답: 실제로 재계획을 돌려서 나온 최선의 macro) 데이터셋을 읽어들여,
#   - "상태를 읽는(state-reading)" feature 모델이 oracle 순위와 비슷하게 macro를 랭킹하는지,
#   - 그래서 "상태를 안 보는(state-blind)" 단순 기준선(baseline)보다
#     decision regret(잘못 골라서 손해 본 정도)이 낮은지를 측정한다.
#   - 이게 되면 → 학습 가능한 신호가 있다는 뜻 → 더 큰 GNN 모델에 투자할 근거가 된다.
#     안 되면 → 지금 데이터가 아직 구분력이 없다는 뜻 → 데이터(OOD 종류/심각도)를 늘려야 한다.
#
# 채점 방식(EVALUATION.md 기준):
#   feasibility-lexicographic = (1) 완주했는가 complete > (2) 닫은 노드 수 closed > (3) 실제 makespan
#   즉 "완주 여부"가 최우선, 그다음 "얼마나 진행했나", 마지막이 "얼마나 빨랐나" 순서로 비교.
#   핵심 지표 = top-1 decision regret. 평가는 leave-one-instance-out(한 instance를 빼고 학습,
#   그 instance로 시험) 방식이라 모델은 항상 처음 보는 OOD 상황에서 채점된다.
#
# 실행 방법:
#   python e1_analyze.py <dataset.jsonl>
#   옵션: --cost-aware (macro마다 비용을 매겨 "개입 안 하기=NOOP"도 정답이 될 수 있게 함)
#         --lam=3.0     (비용 가중치 LAMBDA, 단위는 schedule-node 개수)
#
# ---- 문법 참고 (익숙하지 않을 수 있는 Python 표현) ----
#   * json.loads(l): JSON 문자열 한 줄(l)을 Python dict로 변환. jsonl = 한 줄에 JSON 하나씩인 파일.
#   * pandas DataFrame(df): 표(엑셀 같은) 자료구조. df.컬럼명 또는 df["컬럼명"]으로 열 접근.
#     df[df.조건]은 조건이 참인 행만 골라내는 "불리언 인덱싱".
#   * df.get("col", 기본값): 그 컬럼이 없으면 기본값 Series를 돌려줌(KeyError 방지).
#   * .astype(float): 컬럼 전체를 실수형으로 변환.  .apply(lambda v: ...): 각 값에 함수 적용.
#   * [식 for x in 목록]: 리스트 컴프리헨션(반복문을 한 줄로). {k: v for ...}는 딕셔너리 버전.
#   * f"...{변수}...": f-string, 문자열 안에 변수/식을 {} 로 끼워넣는 표기.  {x:.3f}=소수 3자리.
#   * numpy(np): 배열/행렬 수치계산.  np.mean/np.argsort/np.percentile 등.
#     X[tr], X[te]: 배열에서 인덱스 배열 tr/te에 해당하는 행만 뽑기(팬시 인덱싱).
#   * surrogate_model.build_model(): 평가와 배포가 공유하는 단일 모델(RandomForest) 생성기.
#     LeaveOneGroupOut=그룹(여기선 instance) 하나씩 빼면서 교차검증(CV)해주는 도구.
#   * math.inf / math.nan: 무한대 / 숫자아님(NaN). JSON에는 이런 값이 문자열로 저장돼 다시 복원함.
# =============================================================================

import sys, json, math
import numpy as np
import pandas as pd
from surrogate_model import build_model  # 평가·배포가 같은 모델을 쓰도록 단일 정의에서 가져온다
from sklearn.model_selection import LeaveOneGroupOut

# 후보 macro의 정수 ID 목록(0~4)과 사람이 읽을 이름 매핑. 모델은 이 5개 중 하나를 고른다.
MACROS = [0, 1, 2, 3, 4]
MACRO_NAME = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone", 4: "ReformTeam"}


# jsonl 데이터셋 파일(path)을 읽어 DataFrame으로 만드는 함수. 비유한수(Inf/NaN)를 실수로 복원한다.
def load(path):
    # 파일의 각 줄을 JSON으로 파싱해 dict 리스트로 만든다(빈 줄은 건너뜀).
    rows = [json.loads(l) for l in open(path) if l.strip()]
    df = pd.DataFrame(rows)
    # JSON encodes non-finite numbers as strings; bring them back to floats.
    # (JSON은 무한대/NaN을 "Inf"/"NaN" 같은 문자열로 저장하므로 다시 float로 되돌린다.)
    for c in ("makespan", "ctrl_makespan", "soc", "zone_radius"):
        if c in df:  # 그 컬럼이 데이터에 있을 때만 변환
            df[c] = df[c].apply(lambda v: math.inf if v == "Inf" else (math.nan if v in ("NaN", None) else float(v)))
    return df


# ---- feasibility-lexicographic score (EVALUATION.md): complete > closed-count > realized makespan
# 한 결과를 정렬용 튜플로 바꾸는 함수. 튜플은 (완주?, closed, -makespan) 순으로 클수록 좋다.
# 파이썬은 튜플을 앞에서부터 비교하므로 "완주 여부"가 1순위, closed가 2순위, makespan(작을수록 좋아서 음수)이 3순위.
def lex_key(complete, closed, makespan):
    # bigger is better
    # mk는 아래 return에서 실제로 쓰이지 않는 중간변수(원 코드 유지). 실제 키는 return 튜플이다.
    mk = makespan if complete and math.isfinite(makespan) else (-math.inf if complete else -math.inf)
    # 완주+유한 makespan이면 -makespan(작을수록 좋음), 아니면 아주 작은 값(-1e18)으로 최하위 처리.
    return (1 if complete else 0, closed, -makespan if complete and math.isfinite(makespan) else -1e18)


# 한 instance의 여러 macro 결과행(g) 중 oracle이 실제로 고른 최선의 행(=정답 label)을 반환.
def oracle_best_row(g):
    # the oracle's own choice on this instance (the label)
    # g.itertuples(...)로 행들을 돌며 lex_key가 가장 큰(=가장 좋은) 행을 max로 뽑는다.
    return max(g.itertuples(index=False), key=lambda r: lex_key(r.complete, r.closed, r.makespan))


# regret 계산: 정답 macro가 닫은 노드수(best_closed) - 내가 고른 macro가 닫은 노드수. 0이면 완벽.
def closed_regret(picked_closed, best_closed):
    return best_closed - picked_closed


# 이 instance가 "평가에 쓸 자격이 있는지(admissible)" 판정. 고장이 실제로 영향을 줘야 의미있는 문제다.
def instance_admissible(g):
    """EVALUATION.md admissibility: the fault must be consequential -> NOOP strictly worse than control
    (in the same feasibility-lexicographic order)."""
    noop = g[g.macro == 0]  # macro 0 = NOOP(아무것도 안 함) 행을 찾는다.
    if noop.empty:
        return False
    n = noop.iloc[0]  # NOOP 행 하나(iloc[0] = 위치 기준 첫 행).
    # ctrl_* = "OOD가 없었을 때(정상 대조군 control)"의 결과. NOOP 결과를 이 대조군과 비교한다.
    ctrl_complete = bool(n.ctrl_complete); ctrl_closed = int(n.ctrl_closed)
    ctrl_mk = n.ctrl_makespan
    if ctrl_complete and not n.complete:  # 정상이면 완주했는데 NOOP는 완주 실패 → 고장이 치명적 → 자격 있음
        return True
    if n.closed < ctrl_closed:  # NOOP가 닫은 노드가 정상보다 적음 → 손해 발생 → 자격 있음
        return True
    # 닫은 노드는 같지만 makespan이 유의미하게 더 나쁨(느려짐) → 자격 있음 (1e-9은 부동소수 오차 여유).
    if n.closed == ctrl_closed and math.isfinite(n.makespan) and math.isfinite(ctrl_mk) and n.makespan > ctrl_mk + 1e-9:
        return True
    return False  # 위 어디에도 안 걸리면 고장이 무해 → NOOP가 이미 최선이라 학습거리가 아님


# ---- features: state the surrogate is allowed to read (no oracle leakage)
# valid_mask 값 v가 리스트면 그대로, 아니면 빈 리스트를 반환하는 방어용 헬퍼(_는 내부용 관례).
def _valid_list(v):
    if isinstance(v, list):
        return v
    return []


# DataFrame(df)을 모델 입력용 feature 표로 변환. oracle 정답이 새어들지 않는(상태만 읽는) 열들만 만든다.
def featurize(df):
    kinds = ["fault", "battery", "zone", "zoneblk"]  # OOD 종류들: 고장/배터리/구역/구역차단
    X = pd.DataFrame()
    for k in kinds:
        # one-hot 인코딩: 해당 kind면 1.0, 아니면 0.0인 열을 kind별로 만든다.
        X[f"kind_{k}"] = (df.kind == k).astype(float)
    X["severity"] = df.severity.astype(float)  # OOD 심각도(연속값)
    X["n_spare_cfg"] = df.n_spare_cfg.astype(float)  # 설정된 여분(spare) 로봇 수
    X["spare_count"] = df.get("spare_count", 0).astype(float)  # 실제 남은 spare 수
    X["progress"] = df.get("progress", 0.0).astype(float)  # 빌드 진행률
    X["agent_pending"] = df.get("agent_pending", -1).astype(float)  # 아직 대기 중인 agent 수(-1=정보없음)
    X["closed_at_fire"] = df.get("closed_at_fire", 0).astype(float)  # OOD 발생 시점에 닫혀있던 노드 수
    X["n_active"] = df.get("n_active", 0).astype(float)  # 활동 중 로봇 수
    # soc(배터리 잔량)와 zone_radius(구역 반경)는 없을 수도 있어 None/NaN이면 -1.0(=정보없음 표식)으로 대체.
    X["soc"] = df.get("soc", math.nan).apply(lambda v: -1.0 if v is None or (isinstance(v, float) and math.isnan(v)) else float(v))
    X["zone_radius"] = df.get("zone_radius", math.nan).apply(lambda v: -1.0 if v is None or (isinstance(v, float) and math.isnan(v)) else float(v))
    # graded-OOD: how much of the build the no-go zone actually covers (GRADED_OOD_DESIGN.md).
    # -1 when the OOD kind has no zone at all, so the model can tell "no zone" from "zero overlap".
    X["zone_overlap"] = df.get("zone_overlap", pd.Series([-1.0] * len(df))).apply(
        lambda v: -1.0 if v is None or (isinstance(v, float) and math.isnan(v)) else float(v))
    # is this candidate macro even applicable in this state? (the ground-truth valid set, not the label)
    vmask = df.get("valid_mask", pd.Series([[]] * len(df)))  # 이 상태에서 적용 가능한 macro들의 집합(정답 아님, 규칙상 유효집합)
    # 후보 macro m이 유효집합 안에 있으면 1.0 아니면 0.0. zip으로 두 컬럼을 짝지어 순회.
    X["macro_in_valid"] = [1.0 if int(m) in _valid_list(v) else 0.0 for m, v in zip(df.macro, vmask)]
    for m in MACROS:
        # 이 행이 어떤 macro 후보인지 one-hot으로 표시(모델이 macro별 효과를 구분하게).
        X[f"macro_{m}"] = (df.macro == m).astype(float)
    return X


# NDCG@k: 모델이 매긴 macro 순서(pred_order)가 실제 좋은 순서와 얼마나 맞는지 0~1로 재는 랭킹 품질 지표.
# true_scores_by_macro = macro별 실제 점수(정규화된 closed 수), k = 상위 몇 개만 볼지.
def ndcg_at_k(true_scores_by_macro, pred_order, k):
    # gains are the (already normalized) closed-counts; higher = better
    # DCG: 상위 순위일수록 log2로 가중치를 크게 줘서 점수를 누적(순위가 낮으면 할인).
    def dcg(order):
        return sum(true_scores_by_macro[m] / math.log2(i + 2) for i, m in enumerate(order[:k]))
    ideal = sorted(true_scores_by_macro, key=lambda m: true_scores_by_macro[m], reverse=True)  # 완벽한 이상적 순서
    idcg = dcg(ideal)  # 이상적 순서의 DCG(=최댓값)로 나눠 정규화한다.
    return dcg(pred_order) / idcg if idcg > 0 else 1.0


# ---- cost-aware objective (--cost-aware): a macro is not free.  y = closed - lambda * cost(macro),
# so a Replace has to BUY its extra closed-nodes; NOOP is free and Deprioritize is cheap.  This is the
# decision-relevant version of the task: restraint can be optimal even when Replace closes more nodes.
# macro별 개입 비용. NOOP는 공짜(0), Deprioritize는 쌈(0.3), 나머지(Replace/ForbidZone/Reform)는 1.0.
MACRO_COST = {0: 0.0, 1: 1.0, 2: 0.3, 3: 1.0, 4: 1.0}


# cost-aware용 정렬키: closed에서 macro 비용(lam*cost)을 빼고 lex_key를 매긴다 → 비싼 개입은 손해를 벌어야 이긴다.
def cost_lex_key(complete, closed, makespan, macro, lam):
    return lex_key(complete, closed - lam * MACRO_COST[int(macro)], makespan)


# 모델을 학습하기 전에 "이 문제가 과연 어려운(=학습할 가치 있는) 문제인가"를 진단해 출력하는 함수.
# best = instance별 정답 macro 딕셔너리. kind만으로 정답이 정해지면 어떤 모델도 이득을 못 낸다(=trivial).
def difficulty_audit(df, best):
    """Print the §5 audit BEFORE any model is fit: is the task actually non-trivial?
    If best_macro is a function of `kind` alone, a 4-way one-hot solves it and no model
    (GNN included) can show any gain -- that was the E1 'step, not a curve' failure."""
    kind_of = {i: str(g.kind.iloc[0]) for i, g in df.groupby("instance")}  # instance → 그 kind 매핑
    by_kind = {}
    for iid, m in best.items():
        by_kind.setdefault(kind_of[iid], []).append(m)  # kind별로 정답 macro들을 모은다(setdefault=없으면 새 리스트).
    n = len(best)
    H, majority_correct = 0.0, 0  # H=가중평균 엔트로피, majority_correct=kind별 다수결이 맞은 개수
    print("\n=== difficulty audit (label distribution; no model involved) ===")
    for k, ms in sorted(by_kind.items()):
        cnt = pd.Series(ms).value_counts()  # 이 kind 안에서 각 macro가 정답인 횟수
        p = cnt / cnt.sum()  # 확률 분포로 정규화
        h = float(-(p * np.log2(p)).sum())  # 섀넌 엔트로피(bits): 0이면 kind가 정답을 완전히 결정(쉬움)
        H += len(ms) / n * h  # instance 수로 가중해 전체 H에 누적
        majority_correct += int(cnt.iloc[0])  # 가장 흔한 정답을 찍었을 때 맞는 수(다수결 정확도용)
        spread = ", ".join(f"{MACRO_NAME[int(m)]} x{c}" for m, c in cnt.items())  # "Replace x3, NOOP x1" 형태 문자열
        print(f"  kind={k:9s} n={len(ms):3d}  H={h:.2f} bits  best-macro: {spread}")
    maj_acc = majority_correct / n  # kind별 다수결(state-blind) 정확도
    noop_frac = sum(1 for m in best.values() if m == 0) / n  # 정답이 NOOP(개입 안함)인 비율
    print(f"  H(best|kind) = {H:.2f} bits          (target > 0.5; 0 = kind determines the macro)")
    print(f"  per-kind majority accuracy = {maj_acc:.0%}   (target <= 70%)")
    print(f"  NOOP is best in {noop_frac:.0%} of instances   (target 15-35%; 0% = restraint never correct)")
    if H < 1e-9:  # H가 사실상 0이면 문제가 너무 쉬움 → 모델이 아니라 데이터를 고쳐야 한다는 경고.
        print("  !! H=0: the task is TRIVIAL - a kind one-hot is a perfect policy. Fix the DATA, not the model.")
    return H, maj_acc


# 전체 파이프라인을 실행하는 메인 함수: 데이터 로드 → 정답 산출 → 교차검증 학습·평가 → 지표 출력.
def main():
    # sys.argv[1:] = 명령줄 인자들. --로 시작하는 건 flag, 아닌 건 일반 인자(argv)로 분리.
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    path = argv[0]  # 첫 일반 인자 = 데이터셋 경로
    COST_AWARE = "--cost-aware" in flags  # cost-aware 모드 여부
    # --lam=값 flag가 있으면 그 값을, 없으면 기본 3.0을 LAM으로. next(제너레이터, 기본값) 관용구.
    LAM = next((float(f.split("=")[1]) for f in flags if f.startswith("--lam=")), 3.0)

    df = load(path)
    df = df[df.fired == True].copy()  # 실제로 OOD가 "발동된(fired)" 행만 남긴다. .copy()로 원본 경고 회피.
    instances = list(df.instance.unique())  # 고유 instance 목록
    if COST_AWARE:
        # cost-aware scoring already makes NOOP a live option, so the NOOP-worse-than-control
        # admissibility filter is not needed; keep every instance with the full macro sweep.
        # cost-aware일 땐 admissibility 필터 대신, 5개 macro가 다 있는(랭킹이 정의되는) instance만 남긴다.
        adm = [i for i, g in df.groupby("instance") if len(g) == 5]
        print(f"loaded {len(df)} rows, {len(instances)} instances, {len(adm)} kept [COST-AWARE, lambda="
              f"{LAM} nodes: y = closed - lambda*cost(macro)]")
    else:
        # 기본 모드: 고장이 실제로 영향을 준(admissible) instance만 남긴다.
        adm = [iid for iid in instances if instance_admissible(df[df.instance == iid])]
        print(f"loaded {len(df)} rows, {len(instances)} instances, {len(adm)} admissible")
    df = df[df.instance.isin(adm)].copy()  # 자격 있는 instance의 행만 남김(isin=목록 포함 필터).
    if len(adm) < 3:
        print("!! too few admissible instances for CV; showing oracle-best per instance and exiting.")
        for iid in adm:
            g = df[df.instance == iid]
            b = oracle_best_row(g)
            print(f"  {iid}: oracle-best = {MACRO_NAME[b.macro]} (closed={b.closed}, complete={b.complete})")
        pass

    # ---- oracle labels
    # 각 instance마다 oracle 정답 macro를 계산해 best 딕셔너리에 저장(cost-aware면 비용을 반영한 키 사용).
    best = {}
    for iid in df.instance.unique():
        g = df[df.instance == iid]
        if COST_AWARE:
            b = max(g.itertuples(index=False),
                    key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        else:
            b = oracle_best_row(g)
        best[iid] = int(b.macro)
    difficulty_audit(df, best)  # 학습 전에 문제 난이도 진단 출력
    dist = pd.Series(list(best.values())).map(MACRO_NAME).value_counts()  # 정답 macro들의 분포(어떤 게 몇 번)
    print("\noracle-best macro distribution across admissible instances:")
    print(dist.to_string())
    n_classes = dist.shape[0]  # 정답으로 등장한 macro 종류 수(1이면 학습 문제가 안 됨)
    global_best_macro = pd.Series(list(best.values())).mode().iloc[0]  # 전체에서 가장 흔한 정답 = state-blind 기준선이 찍을 macro
    print(f"most-common best macro (state-blind baseline picks this): {MACRO_NAME[global_best_macro]}")

    if n_classes < 2:
        print("\n=> best macro is CONSTANT across instances: not yet a learnable ranking task.")
        print("   (a state-blind 'always-{}' predictor already achieves 0 regret). Add OOD-type/severity variation.".format(MACRO_NAME[global_best_macro]))
        return

    # ---- level-0 surrogate: predict the closed-count of (state, macro), then rank the macros by it
    # surrogate의 핵심 아이디어: (상태, macro)마다 "닫을 노드 수"를 예측하고, 그 예측값으로 macro를 랭킹.
    df = df.reset_index(drop=True)  # 인덱스를 0부터 다시 매김(뒤의 위치 기반 인덱싱과 맞추기 위해)
    X = featurize(df).values  # feature 표 → numpy 배열
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])  # 행별 macro 비용
    y = df.closed.astype(float).values - (LAM * cost if COST_AWARE else 0.0)  # 학습 목표: closed(-비용 in cost-aware)
    groups = df.instance.values  # 교차검증 그룹 = instance (같은 instance는 학습/시험에 섞이지 않게)
    kind_of = {i: str(g.kind.iloc[0]) for i, g in df.groupby("instance")}  # instance→kind 매핑
    logo = LeaveOneGroupOut()  # 그룹 하나씩 빼는 교차검증기

    METHODS = ("model", "always", "always_per_kind", "random")  # 비교할 4가지: 모델 vs 세 기준선
    regrets = {m: [] for m in METHODS}  # 방법별 정규화 regret 모음
    catastrophic = {m: 0 for m in METHODS}  # 방법별 "치명적 오선택" 횟수
    ndcgs = []  # NDCG@2 모음
    topk_recall = {1: [], 2: []}  # 정답이 상위 1/2위 안에 든 비율
    agree = []  # 모델 top-1이 oracle 정답과 일치한 비율
    rng = np.random.default_rng(0)  # 재현 가능한 난수 생성기(random 기준선용, seed=0)
    # held-out level-0 accuracy (does the surrogate predict the re-plan OUTCOME, not just the label?)
    l0_true, l0_pred = [], []  # level-0 회귀 품질 측정용: 실제 y와 예측값을 held-out에서 모은다.
    for tr, te in logo.split(X, y, groups):  # tr=학습 행 인덱스, te=시험(빠진 instance) 행 인덱스
        iid = groups[te][0]  # 이번에 빠진 instance ID
        g = df.iloc[te]  # 그 instance의 행들
        # 트리 부스팅 회귀 모델 생성(과적합 방지용 하이퍼파라미터). E1~E4에서 쓰는 주력 모델.
        model = build_model()   # 배포되는 것과 "같은" 모델(surrogate_model.py에 단일 정의)
        model.fit(X[tr], y[tr])  # 나머지 instance들로 학습
        pred = model.predict(X[te])  # 빠진 instance의 각 macro 행에 대해 값 예측
        l0_true.extend(list(y[te])); l0_pred.extend(list(pred))  # 회귀 정확도 평가용으로 축적
        macros = g.macro.values
        # the TRUE score of every candidate macro on this held-out instance (same scale as y)
        # 이 instance에서 macro별 "실제" 점수(y와 같은 척도). 채점 기준.
        closed_by_macro = {int(m): float(c) - (LAM * MACRO_COST[int(m)] if COST_AWARE else 0.0)
                           for m, c in zip(macros, g.closed.values)}
        best_macro = best[iid]  # 정답 macro
        best_closed = closed_by_macro[best_macro]  # 정답의 점수
        worst_closed = min(closed_by_macro.values())  # 최악 점수
        span = max(best_closed - worst_closed, 1e-9)  # 정규화용 폭(0 나눗셈 방지로 최소 1e-9)

        # the model's ranking of the macros on this instance
        # 예측값 pred를 내림차순 정렬(-pred의 argsort)해 모델의 macro 순위를 만든다. order[0]=모델의 최종 선택.
        order = [int(m) for m in macros[np.argsort(-pred)]]
        pick = order[0]
        # state-blind baselines (상태를 안 보는 기준선들)
        apick = global_best_macro if global_best_macro in closed_by_macro else macros[0]  # always: 전역 최빈 정답
        rpick = int(rng.choice(macros))  # random: 무작위 선택
        # the STRONG state-blind opponent: the best macro for this OOD *kind*, learned from the
        # training instances only (a per-kind lookup table).  If the model cannot beat this, the
        # signal it found is just "which kind is it", not the within-kind state.
        # always_per_kind: 학습 데이터에서 "같은 kind"인 instance들의 정답만 모아 다수결로 고른다(kind별 룩업표).
        # 이걸 못 이기면 모델이 찾은 신호는 그냥 "kind가 뭔지"일 뿐, kind 안의 상태 차이는 못 읽은 것.
        tr_best = [best[i] for i in set(groups[tr]) if kind_of[i] == kind_of[iid]]
        kpick = int(pd.Series(tr_best).mode().iloc[0]) if tr_best else apick  # 같은 kind가 없으면 always로 대체
        kpick = kpick if kpick in closed_by_macro else apick  # 이 instance에 없는 macro면 always로 대체

        # 네 방법 각각의 regret과 치명적 오선택을 기록.
        for name, p in (("model", pick), ("always", apick), ("always_per_kind", kpick), ("random", rpick)):
            reg = closed_regret(closed_by_macro[p], best_closed)
            regrets[name].append(reg / span)  # span으로 나눠 instance 간 비교 가능하게 정규화
            # catastrophic = the pick loses >15% of the reachable closed-count vs the oracle
            # 치명적 = oracle 대비 도달 가능 closed의 15% 넘게 손해 본 경우.
            if (best_closed - closed_by_macro[p]) / max(best_closed, 1) > 0.15:
                catastrophic[name] += 1

        ndcgs.append(ndcg_at_k(closed_by_macro, order, k=2))  # 이 instance의 랭킹 품질
        topk_recall[1].append(1.0 if best_macro == order[0] else 0.0)  # 정답이 1위인가
        topk_recall[2].append(1.0 if best_macro in order[:2] else 0.0)  # 정답이 상위 2위 안인가
        agree.append(1.0 if pick == best_macro else 0.0)  # 모델 선택 = 정답인가

    n = len(agree)  # 평가한 instance 수
    print(f"\n=== leave-one-instance-out ({n} instances, {n_classes} distinct best-macros) ===")
    print(f"{'method':<18}{'mean norm-regret':>18}{'catastrophic':>14}")
    for name in METHODS:
        print(f"{name:<18}{np.mean(regrets[name]):>18.3f}{catastrophic[name]:>10}/{n}")
    print(f"\nmodel ranking fidelity:  NDCG@2={np.mean(ndcgs):.3f}  top-1 recall="
          f"{np.mean(topk_recall[1]):.3f}  top-2 recall={np.mean(topk_recall[2]):.3f}  agreement(=oracle)="
          f"{np.mean(agree):.3f}")
    # gain>0이면 모델이 always 기준선보다, kgain>0이면 더 강한 always_per_kind 기준선보다 regret이 낮다는 뜻(좋음).
    gain = np.mean(regrets["always"]) - np.mean(regrets["model"])
    kgain = np.mean(regrets["always_per_kind"]) - np.mean(regrets["model"])
    print(f"\nSIGNAL: model beats always-{MACRO_NAME[global_best_macro]} by {gain:+.3f} norm-regret.")
    print(f"SIGNAL: model beats always_per_kind (the STRONG state-blind opponent) by {kgain:+.3f}.")
    print("  => " + ("LEARNABLE: the model reads state WITHIN a kind (severity/SoC/spares), not just the kind."
                     if kgain > 0.02
                     else "NOT learnable beyond the kind: a per-kind lookup is already optimal -> the OOD severity axis did not bite. Fix the DATA (GRADED_OOD_DESIGN.md), not the model."))

    # ---- level-0 held-out regression quality (the surrogate is a WORLD MODEL, not a classifier):
    # MAE / R^2 on the closed-count it never saw.
    # surrogate가 (분류기가 아니라) 재계획 "결과"를 예측하는 world model임을 보이는 회귀 품질 지표.
    lt, lp = np.array(l0_true), np.array(l0_pred)  # 실제값, 예측값
    mae = float(np.mean(np.abs(lt - lp)))  # 평균절대오차(노드 단위)
    # R^2 = 1 - (잔차제곱합 / 전체분산제곱합). 1에 가까울수록 좋음. 분모 0이면 NaN.
    ss_res = float(np.sum((lt - lp) ** 2)); ss_tot = float(np.sum((lt - lt.mean()) ** 2))
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    print(f"\nLevel-0 (held-out closed-count prediction): MAE={mae:.1f} nodes over range ["
          f"{lt.min():.0f},{lt.max():.0f}], R^2={r2:.3f}"
          "  (evidence the surrogate predicts the real re-plan OUTCOME, not just a kind->macro lookup)")

    # ---- paired bootstrap on the per-instance regret differences (EVALUATION.md: paired stats)
    # paired bootstrap: instance별 regret 차이를 무작위 재표집(2000회)해 개선폭의 95% 신뢰구간을 구한다.
    rng2 = np.random.default_rng(1)
    for opp in ("always", "always_per_kind"):  # 두 기준선 각각과 짝지어 비교
        diff = np.array(regrets[opp]) - np.array(regrets["model"])  # 양수면 모델이 그만큼 더 나음
        # 복원추출로 표본평균을 2000번 만들어 분포를 얻는다(rng2.integers=무작위 인덱스).
        boots = [float(np.mean(diff[rng2.integers(0, len(diff), len(diff))])) for _ in range(2000)]
        lo, hi = np.percentile(boots, [2.5, 97.5])  # 95% 신뢰구간 하한/상한
        sig = "significant" if lo > 0 else "NOT significant"  # 하한이 0보다 크면 통계적으로 유의
        print(f"paired bootstrap 95% CI on regret reduction ({opp} - model): "
              f"{np.mean(diff):+.3f}  [{lo:+.3f}, {hi:+.3f}]  ({sig}, n={len(diff)})")


# 이 파일을 직접 실행할 때만 main()을 부른다(import될 땐 실행 안 됨). 파이썬 스크립트의 표준 진입점.
if __name__ == "__main__":
    main()
