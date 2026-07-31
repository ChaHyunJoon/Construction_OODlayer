#!/usr/bin/env python
"""
E2 — LLM-over-surrogate vs LLM-over-solver (PROPOSAL.md E2 / EVALUATION.md Level-2,3).

Setup: at each OOD event an **LLM proposes a candidate set** of DSL macros (it knows the OOD type but is
uncertain about the exact best response, so it proposes the type's plausible macros + the do-nothing
option + a distractor). Two ways to pick the winner from that set:

  * **LLM -> solver (baseline, cf. arXiv 2506.18178):** verify EVERY proposed candidate with the true
    planner (one full sim each) and commit to the best. Cost = |candidates| planner calls. Regret = 0.
  * **LLM -> surrogate (ours):** the learned surrogate ranks the candidates in imagination; verify only
    the top-k with the true planner; commit to the best-verified. Cost = k planner calls.

Metric = quality (decision regret) at iso-compute (planner calls), and the compute reduction to reach
the baseline's (zero-regret) quality. Runs on the oracle dataset (every macro's true outcome is known),
so we can score any candidate set / budget exactly. Leave-one-instance-out; the surrogate never trains
on the held-out instance. Self-checks the candidate sets are non-trivial (>1) and reports honestly.

Usage:  python e2_llm_surrogate.py <dataset.jsonl>
"""
# =====================================================================
# [한국어 개요]  E2 실험: "LLM + surrogate" vs "LLM + solver"
# ---------------------------------------------------------------------
# 무엇을 하나:
#   OOD(예상 밖 상황)가 터질 때마다 LLM이 대응 후보(DSL 매크로) 몇 개를 제안한다.
#   그 후보들 중에서 "누가 최선인가"를 고르는 두 가지 방법을 비교한다.
#     - LLM -> solver (baseline): 모든 후보를 진짜 planner로 검증(=full sim). 정확하지만 비쌈.
#     - LLM -> surrogate (ours): 학습된 surrogate가 후보 순위를 매긴 뒤, 상위 top-k만 진짜로 검증.
#   핵심 주장: surrogate로 미리 걸러내면 planner-call(비싼 검증)을 훨씬 적게 하고도
#              solver와 같은 결정 품질(=낮은 regret)을 얻는다.
#
# 어떤 실험인가: PROPOSAL.md의 E2 / EVALUATION.md의 Level-2,3.
#
# 실행 방법:  python e2_llm_surrogate.py <dataset.jsonl>
#   - <dataset.jsonl>: 매크로마다 실제 결과가 다 기록된 oracle 데이터셋(jsonl).
#
# 채점 방식(중요 용어):
#   - regret: 고른 macro가 진짜 best 대비 얼마나 손해인지(0이면 최선을 골랐다는 뜻).
#   - planner call: 진짜 planner로 후보 하나를 검증하는 비용 단위(적을수록 좋다).
#   - Leave-one-instance-out: surrogate를 학습할 때 채점 대상 instance는 절대 학습에 안 쓴다(공정성).
#
# 문법 참고(익숙하지 않을 수 있는 Python):
#   - numpy(np): np.mean(리스트) = 평균. 벡터/배열 연산용 라이브러리.
#   - surrogate_model.build_model() = surrogate 본체(RandomForest, 평가·배포 공용).
#              LeaveOneGroupOut = group(=instance) 하나씩 빼서 학습/검증 나누는 도구.
#   - f-string: f"...{변수}..." 문자열 안에 값을 끼워 넣기. {x:>14.2f}는 폭14·소수2자리·오른정렬.
#   - list comprehension: [식 for m in ... if 조건] = 조건 맞는 것만 모아 리스트 만들기.
#   - dict.fromkeys(리스트): 순서 유지하며 중복 제거(값은 버림).
#   - .get(key, 기본값): dict에서 key가 없으면 기본값 반환(KeyError 방지).
# =====================================================================
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # 이 파일 폴더를 import 경로에 추가(옆 모듈 e1_analyze 불러오기용)
# e1_analyze의 공용 도구들: load=데이터 읽기, instance_admissible=유효 instance 판별,
# featurize=특징행렬 생성, lex_key=사전식 우선순위 키, MACRO_NAME=매크로 번호->이름
from e1_analyze import load, instance_admissible, featurize, lex_key, MACRO_NAME
from surrogate_model import build_model  # surrogate 본체(평가·배포 단일 정의)
from sklearn.model_selection import LeaveOneGroupOut         # instance 단위로 학습/검증 분할

# The LLM's candidate proposal per OOD kind: the type's canonical macro + NOOP (do-nothing) + a
# plausible-but-usually-wrong distractor. The LLM narrows the 5-macro repertoire using the event text;
# the surrogate's job is to rank WITHIN this set so only the top few need real verification.
# OOD 종류별로 LLM이 내놓는 후보 매크로 번호 목록. 각 값은 [정답 매크로 + NOOP(가만히) + 헷갈리는 distractor].
# LLM이 5개 전체를 다 던지지 않고 event 텍스트로 후보를 좁혀주면, surrogate는 이 좁혀진 집합 "안에서만" 순위를 매기면 된다.
LLM_CANDIDATES = {
    "fault":   [0, 1, 2],      # NOOP, Replace(correct), Deprioritize(distractor)
    "battery": [0, 1, 2],      # NOOP, Replace, Deprioritize
    "zone":    [0, 3, 1],      # NOOP, ForbidZone(correct), Replace(distractor)
    "zoneblk": [0, 3, 1],      # NOOP, ForbidZone(correct), Replace(distractor)
}


# 한 행(r)의 사전식 우선순위 키를 만든다: (완주여부, 닫힌 step 수, makespan) 순으로 좋고나쁨을 비교하기 위함.
def lexkey_row(r):
    # makespan이 문자열(예: 미완주 표시)이면 무한대로 취급 -> "가장 나쁨"으로 처리
    mk = r.makespan if not isinstance(r.makespan, str) else math.inf
    return lex_key(bool(r.complete), float(r.closed), mk)  # complete 우선 -> closed 많을수록 -> makespan 작을수록 좋음


# E2 실험 전체를 실행하는 진입 함수: 데이터 로드 -> surrogate 학습/평가 -> 결과표와 headline 출력.
def main():
    path = sys.argv[1]                       # 명령줄 첫 인자 = 데이터셋 경로
    df = load(path)                          # jsonl을 DataFrame(표)로 읽기
    df = df[df.fired == True].copy()         # 실제로 발동(fired)된 OOD 행만 남김
    # admissible(정상적으로 채점 가능한) instance만 골라낸다
    adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
    df = df[df.instance.isin(adm)].reset_index(drop=True)  # 유효 instance만 남기고 인덱스 재정렬
    print(f"loaded: {len(df)} rows, {len(adm)} admissible instances")
    if len(adm) < 3:                         # instance가 너무 적으면 통계가 무의미 -> 중단
        print("too few admissible instances."); return

    X = featurize(df).values                 # 특징행렬(모델 입력): 각 행 -> 숫자 벡터
    y = df.closed.astype(float).values       # 정답값(모델 출력 대상): 닫힌 step 수
    groups = df.instance.values              # 각 행이 어느 instance 소속인지(분할 기준)
    logo = LeaveOneGroupOut()                # instance 하나씩 빼서 test로 쓰는 분할기

    Ks = [1, 2, 3]                           # surrogate가 상위 몇 개(top-k)까지 진짜 검증할지 후보들
    reg_surro = {k: [] for k in Ks}          # top-k별 regret 기록(딕셔너리 comprehension: 각 k에 빈 리스트)
    calls_surro = {k: [] for k in Ks}        # top-k별 planner call 수 기록
    reg_solver, calls_solver = [], []        # baseline(모두 검증)의 regret / call 기록
    cand_sizes = []                          # 매 instance의 후보 개수(나중에 평균)

    # instance를 하나씩 빼가며(te=test 1개, tr=train 나머지) 반복
    for tr, te in logo.split(X, y, groups):
        g = df.iloc[te].reset_index(drop=True)   # 이번에 채점할 held-out instance의 모든 매크로 행
        kind = g.kind.iloc[0]                    # 이 instance의 OOD 종류(fault/battery/zone 등)
        # LLM이 제안하는 후보 중, 이 데이터셋에 실제 결과가 있는 매크로만 남긴다
        cand = [m for m in LLM_CANDIDATES.get(kind, [0, 1, 2, 3, 4]) if m in set(g.macro.astype(int))]
        cand = list(dict.fromkeys(cand))                     # dedup, keep order (순서 유지 중복 제거)
        cand_sizes.append(len(cand))
        rows_by_macro = {int(r.macro): r for r in g.itertuples(index=False)}  # 매크로 번호 -> 그 행
        # true feasibility-lexicographic best WITHIN the candidate set (the oracle for this comparison)
        # 후보 집합 안에서의 진짜 최선 매크로(=이번 비교의 정답). lexkey_row가 클수록 좋음
        best_m = max(cand, key=lambda m: lexkey_row(rows_by_macro[m]))
        best_closed = float(rows_by_macro[best_m].closed)                     # 정답의 closed 값
        worst_closed = min(float(rows_by_macro[m].closed) for m in cand)      # 후보 중 최악의 closed
        span = max(best_closed - worst_closed, 1e-9)                          # regret 정규화용 폭(0 나눗셈 방지)

        # LLM -> solver: verify all candidates -> best. regret 0, |cand| calls.
        # baseline은 모든 후보를 검증하니 항상 최선을 고름(regret 0) 대신 후보 수만큼 planner call 소모
        reg_solver.append(0.0); calls_solver.append(len(cand))

        # surrogate ranking of the candidate set
        # surrogate 학습: tr(=나머지 instance)로만 학습해서 held-out을 예측(정보 누수 방지)
        model = build_model()
        model.fit(X[tr], y[tr])
        # predict for the held-out candidate rows
        te_idx = {int(m): i for i, m in zip(te, df.iloc[te].macro.astype(int))}  # 매크로 -> 그 행의 X 인덱스
        # 각 후보에 대한 surrogate 예측값(closed 추정). reshape(1,-1)=1행짜리 2차원 입력으로 변환
        pred = {m: float(model.predict(X[te_idx[m]].reshape(1, -1))[0]) for m in cand}
        ranked = sorted(cand, key=lambda m: pred[m], reverse=True)  # 예측 높은 순으로 후보 정렬

        for k in Ks:                             # top-k 예산별로 결과 계산
            kk = min(k, len(cand))               # 후보보다 k가 크면 후보 수로 제한
            verified = ranked[:kk]               # 상위 kk개만 진짜 검증(=planner call kk번)
            pick = max(verified, key=lambda m: lexkey_row(rows_by_macro[m]))  # 검증된 것 중 진짜 최선
            reg = (best_closed - float(rows_by_macro[pick].closed)) / span    # 정답 대비 손해(정규화 regret)
            reg_surro[k].append(reg); calls_surro[k].append(kk)

    n = len(adm)                             # 채점에 쓴 instance 개수
    mean_csize = np.mean(cand_sizes)         # 평균 후보 개수(1이면 고를 게 없다는 뜻 -> 아래 self-check)
    print(f"\nLLM candidate-set size (mean): {mean_csize:.1f}")
    print(f"\n=== E2: quality @ iso-compute ({n} instances) ===")
    print(f"{'policy':<24}{'planner calls':>14}{'mean regret':>13}")
    print(f"{'LLM->solver (verify all)':<24}{np.mean(calls_solver):>14.2f}{np.mean(reg_solver):>13.3f}")
    for k in Ks:
        print(f"{'LLM->surrogate (top-'+str(k)+')':<24}{np.mean(calls_surro[k]):>14.2f}{np.mean(reg_surro[k]):>13.3f}")

    # headline: smallest k with regret <= eps, and its compute reduction vs solver
    eps = 0.02                               # "사실상 solver와 동급"으로 볼 regret 허용치
    # regret이 eps 이하가 되는 가장 작은 k를 찾는다(없으면 max(Ks)). next(제너레이터, 기본값) 패턴
    k_star = next((k for k in Ks if np.mean(reg_surro[k]) <= eps), max(Ks))
    red = 100 * (1 - np.mean(calls_surro[k_star]) / max(np.mean(calls_solver), 1e-9))  # solver 대비 call 절감률(%)
    print(f"\nHEADLINE (E2):")
    print(f"  LLM->surrogate matches LLM->solver quality (regret <= {eps}) at top-{k_star}: "
          f"{np.mean(calls_surro[k_star]):.2f} vs {np.mean(calls_solver):.2f} planner calls "
          f"=> {red:.0f}% fewer verifications at equal decision quality.")
    # self-check: 후보가 사실상 1개뿐이면 고를 게 없어 E2가 E1과 같아짐 -> 후보를 넓히라는 경고
    if mean_csize <= 1.01:
        print("  [self-check] candidate sets are singletons -> E2 collapses to E1; broaden LLM_CANDIDATES.")
    elif np.mean(reg_surro[1]) <= eps:       # top-1만으로 이미 solver 동급이면 amortization 성공 신호
        print("  [self-check] surrogate top-1 already matches solver -> verify-1 suffices "
              f"(save {100*(1-1/mean_csize):.0f}% calls); this is the amortization win.")


if __name__ == "__main__":  # 이 파일을 직접 실행할 때만 main() 호출(import될 때는 실행 안 함)
    main()
