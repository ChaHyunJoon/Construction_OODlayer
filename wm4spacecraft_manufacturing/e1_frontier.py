#!/usr/bin/env python
"""
E1 HEADLINE: the decision-regret vs true-planner-compute frontier (EVALUATION.md §Level-2).

The surrogate ranks the candidate macros for a held-out OOD instance; a "verify top-k" policy then
spends k TRUE-PLANNER CALLS to check the surrogate's top-k macros and commits to the best VERIFIED one
(k=0 = trust the surrogate outright, 0 calls; k=N = verify everything = the oracle, N calls, regret 0).
Sweeping k traces the frontier: how little planner compute buys near-oracle decisions. Contrast with a
state-blind "random-order verify" policy (no surrogate) to show the surrogate's value at every budget.

This is the deliverable metric. It runs on the existing dataset with NO new sims — the "compute" unit is
the number of full-sim planner calls (optionally weighted by measured `label_seconds`). It self-reports
when the current instance set is too easy (flat frontier), which is the cue to add harder instances
(within-kind severity signal) — the frontier then fills in automatically.

Usage:  python e1_frontier.py <dataset.jsonl>
"""
# =============================================================================
# [한국어 안내] e1_frontier.py 는 무엇을 하는 파일인가
# -----------------------------------------------------------------------------
# 목적:
#   이 프로젝트(ConstructionBots.jl, 여러 로봇이 협력해 물건을 조립하는 TAMP
#   시뮬레이터)에서, 예상 못 한 상황(OOD, out-of-distribution)이 터졌을 때
#   "어떤 대응 매크로(Replace/NOOP/ForbidZone 등)를 고를까"를 결정하는
#   surrogate(가벼운 학습 모델)의 가치를 정량화한다.
#
#   핵심 그림(E1 headline)은 두 축의 트레이드오프 곡선(=Pareto frontier)이다:
#     - x축: true-planner-compute (진짜 플래너를 몇 번 돌렸나 = 비용)
#     - y축: decision regret (최적 결정 대비 얼마나 손해봤나 = 품질, 낮을수록 좋음)
#   surrogate 가 매크로 후보들을 랭킹해 주고, "상위 k개만 진짜 플래너로 검증"하는
#   정책(verify top-k)을 k=0..5 로 쓸어보며(sweep) 곡선을 그린다.
#     * k=0 : surrogate 를 그냥 믿는다 (플래너 호출 0번, 가장 쌈)
#     * k=N : 전부 검증한다 = oracle 과 동일 (regret 0, 가장 비쌈)
#   비교 기준(baseline)으로 surrogate 없이 "무작위 순서로 검증"하는 정책도 같이
#   그려서, 어떤 예산(budget)에서든 surrogate 가 이득임을 보인다.
#
# 프로젝트에서의 역할:
#   새 시뮬레이션을 전혀 돌리지 않고(기존 dataset.jsonl 재사용) headline 지표를
#   뽑아내는 "평가 스크립트". 곡선이 평평하면(=문제가 너무 쉬우면) 스스로 그 사실을
#   출력해서, 더 어려운 instance 를 추가하라고 알려준다(self-check).
#
# 실행 방법:
#   python e1_frontier.py <dataset.jsonl>
#   (예: python e1_frontier.py oracle/out/graded_hs_v2.jsonl)
#   결과는 파일 저장이 아니라 표준출력(print)으로 표와 HEADLINE 숫자를 찍는다.
#
# ── 문법 참고 (처음 보는 Python 문법 힌트) ──────────────────────────────────
#   * from e1_analyze import (a, b, c):
#       같은 폴더의 e1_analyze.py 에서 여러 함수/상수를 한 번에 가져온다.
#       위 sys.path.insert 로 이 파일 폴더를 import 경로에 먼저 넣어 준 덕분.
#   * numpy(np): 배열/수치 계산 라이브러리. np.mean(리스트)=평균,
#       np.argsort(-pred)=값이 큰 순서(내림차순)의 인덱스 배열, np.arange(n)=0..n-1.
#   * dict comprehension: {int(m): float(c) for m, c in zip(a, b)}
#       = 두 리스트 a,b 를 짝지어(zip) key:value 쌍의 딕셔너리를 즉석에서 만든다.
#   * list comprehension: [macros[i] for i in idxs] = idxs 순서대로 뽑은 새 리스트.
#   * lambda m: ...  = 이름 없는 1회용 함수. sorted/max 의 key= 에 넘겨 정렬 기준을 준다.
#   * next((x for x in ... if 조건), 기본값) = 조건을 처음 만족하는 값, 없으면 기본값.
#   * f-string: f"{x:.3f}" = x 를 소수점 3자리로, f"{x:>18}" = 폭 18칸 오른쪽정렬.
#       f"{100*(1-a):.0f}%" 처럼 중괄호 안에서 계산도 가능.
#   * df[df.fired == True]: pandas DataFrame 을 조건으로 걸러낸(boolean mask) 부분표.
# =============================================================================
import sys, os, math
import numpy as np
# 이 파일이 있는 폴더를 import 검색경로 맨 앞에 추가 → 옆에 있는 e1_analyze 를 찾게 함
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# e1_analyze.py 의 공용 도구들: 데이터 로드/필터, 특징(feature) 추출, oracle 정답,
# lex_key(정렬 우선순위 키), 매크로 목록/이름 등을 재사용한다.
from e1_analyze import (load, instance_admissible, oracle_best_row, featurize, lex_key,
                        MACROS, MACRO_NAME)
# surrogate 로 쓸 학습 모델: gradient boosting 회귀기 (가볍고 빠름)
from surrogate_model import build_model  # 평가·배포 단일 모델 정의
# LeaveOneGroupOut = 한 instance 를 통째로 test 로 빼고 나머지로 학습(그룹 단위 교차검증)
from sklearn.model_selection import LeaveOneGroupOut


# 매크로들을 "feasibility 우선(완주 여부→닫힌 스텝 수→makespan)" 순서로 좋은 것부터 정렬
def lex_rank(closed_by_macro, complete_by_macro, mk_by_macro):
    """feasibility-lexicographic order (best first) over a dict of macros."""
    # reverse=True 라서 lex_key 값이 큰(=더 좋은) 매크로가 앞으로 온다
    return sorted(closed_by_macro,
                  key=lambda m: lex_key(complete_by_macro[m], closed_by_macro[m], mk_by_macro[m]),
                  reverse=True)


# 전체 파이프라인: 데이터 로드 → LOGO 교차검증으로 surrogate 학습/랭킹 → k별 regret 집계 → 표/HEADLINE 출력
def main():
    path = sys.argv[1]                       # 첫 번째 커맨드라인 인자 = 데이터셋 경로
    df = load(path)
    df = df[df.fired == True].copy()          # 실제로 OOD 가 "발동(fired)"된 행만 남김
    # instance_admissible: 그 instance 가 애초에 완주 가능한(정답이 존재하는) 케이스인지 검사
    adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
    df = df[df.instance.isin(adm)].reset_index(drop=True)   # 유효(admissible) instance 만 유지
    print(f"loaded: {len(df)} rows, {len(adm)} admissible instances")
    if len(adm) < 3:                          # 교차검증하기엔 표본이 너무 적으면 중단
        print("too few admissible instances; generate more."); return

    has_time = "label_seconds" in df.columns  # 각 플래너 호출의 실측 소요시간이 데이터에 있나?
    # 무한대(inf)를 NaN 으로 바꿔 제외하고 평균 → 플래너 1회 호출 평균 소요초(mean_label_s)
    mean_label_s = float(df.label_seconds.replace([math.inf], math.nan).dropna().mean()) if has_time else None

    X = featurize(df).values                  # 모델 입력 특징행렬 (X)
    y = df.closed.astype(float).values        # 학습 타깃: 그 매크로가 닫은(closed) 스텝 수
    groups = df.instance.values               # 각 행이 속한 instance id (그룹 단위 분리에 사용)
    logo = LeaveOneGroupOut()                 # instance 하나씩 test 로 빼는 교차검증기

    # per-instance oracle-best + N (candidate count)
    Ks = range(0, 6)                     # verify-budget: 0..5 planner calls
    # k 값마다 regret 리스트를 담을 딕셔너리 (모델 정책 / 무작위 baseline / 실제 호출 수)
    reg_model = {k: [] for k in Ks}
    reg_rand = {k: [] for k in Ks}
    calls_used = {k: [] for k in Ks}
    rng = np.random.default_rng(0)       # 재현 가능한 난수생성기 (seed=0)

    # LOGO: instance 하나(te)를 test 로 빼고 나머지(tr)로 학습 → 모든 instance 를 한 번씩 test
    for tr, te in logo.split(X, y, groups):
        iid = groups[te][0]              # 이번에 test 로 뽑힌 instance id
        g = df.iloc[te]                  # 그 instance 의 행들만 모은 부분표
        macros = [int(m) for m in g.macro.values]                          # 후보 매크로 id 목록
        closed_by = {int(m): float(c) for m, c in zip(g.macro, g.closed)}  # 매크로→닫은 스텝 수
        comp_by = {int(m): bool(c) for m, c in zip(g.macro, g.complete)}   # 매크로→완주 여부
        # makespan 이 숫자가 아니라 문자열(미완주 표시 등)이면 무한대(inf)로 처리해 최하위로 밀어냄
        mk_by = {int(m): (float(v) if not (isinstance(v, str)) else math.inf) for m, v in zip(g.macro, g.makespan)}
        true_order = lex_rank(closed_by, comp_by, mk_by)                   # 진짜 정답 순위(oracle 랭킹)
        best_macro = true_order[0]; best_closed = closed_by[best_macro]    # 최선 매크로와 그 성능
        # regret 정규화용: 최선-최악 성능 폭(span). 0 나눗셈 방지로 하한 1e-9
        worst_closed = min(closed_by.values()); span = max(best_closed - worst_closed, 1e-9)
        N = len(macros)                  # 이 instance 의 후보 매크로 개수

        # surrogate 학습: tr 데이터로 fit → te 데이터의 매크로별 점수 예측
        model = build_model()
        model.fit(X[tr], y[tr])
        pred = model.predict(X[te])
        model_order = [macros[i] for i in np.argsort(-pred)]  # 예측점수 높은 순으로 매크로 재정렬
        rand_order = list(macros); rng.shuffle(rand_order)    # 비교용: 무작위 순서(surrogate 없음)

        for k in Ks:
            # 같은 로직을 (모델 순서, 무작위 순서) 두 정책에 각각 적용
            for order, store in ((model_order, reg_model), (rand_order, reg_rand)):
                kk = min(k, N)                            # 후보 수보다 큰 k 는 N 으로 제한
                if kk == 0:
                    pick = order[0]                       # trust surrogate top-1, no verification
                else:
                    cand = order[:kk]                     # verify these (kk planner calls)
                    # 검증한 상위 kk개 중 실제로 가장 좋은(lex_key 최대) 매크로를 최종 선택
                    pick = max(cand, key=lambda m: lex_key(comp_by[m], closed_by[m], mk_by[m]))
                # regret = (최선 성능 − 고른 매크로 성능) / span, 0에 가까울수록 좋음
                store[k].append((best_closed - closed_by[pick]) / span)
            calls_used[k].append(min(k, N))              # 이 k 에서 실제로 쓴 플래너 호출 수 기록

    n = len(adm)
    # frontier 표 출력: k 마다 모델 regret / 무작위 regret / 평균 호출 수를 한 줄씩
    print(f"\n=== decision-regret vs planner-compute frontier ({n} instances) ===")
    print(f"{'k (planner calls)':>18}{'model regret':>15}{'random regret':>15}{'mean calls':>12}")
    for k in Ks:
        mc = np.mean(calls_used[k])           # 이 k 의 평균 플래너 호출 수
        print(f"{k:>18}{np.mean(reg_model[k]):>15.3f}{np.mean(reg_rand[k]):>15.3f}{mc:>12.2f}")

    # headline numbers
    r0 = np.mean(reg_model[0])                # k=0(플래너 0회)일 때의 순수 surrogate regret
    # smallest k where model regret <= eps
    eps = 0.02                                # "oracle 급"으로 볼 regret 허용치
    # regret 이 eps 이하로 처음 떨어지는 최소 k (없으면 최대 k) = 필요한 검증 예산
    k_star = next((k for k in Ks if np.mean(reg_model[k]) <= eps), max(Ks))
    N_typ = int(np.median([len(df[df.instance == i]) for i in adm]))  # instance 당 후보 수 중앙값(전부검증 시 호출 수)
    print(f"\nHEADLINE:")
    print(f"  pure surrogate (k=0, ZERO planner calls): regret = {r0:.3f}")
    print(f"  oracle-quality (regret <= {eps}) reached at k={k_star} planner calls  "
          f"(vs verify-all N={N_typ}); compute reduction = {100*(1-k_star/max(N_typ,1)):.0f}%")
    if has_time:
        # 실측 시간이 있으면 벽시계(wall-clock) 절약량으로 환산: (전부검증−k_star) × 호출당 평균초
        saved = (N_typ - k_star) * mean_label_s
        print(f"  per-decision wall-clock: verify-all ~{N_typ*mean_label_s:.0f}s vs surrogate+verify-k "
              f"~{k_star*mean_label_s:.0f}s  (mean label {mean_label_s:.1f}s/call; ~{saved:.0f}s saved/decision)")
    # self-check: is the frontier informative?
    # 자기점검: k=0 인데 이미 regret 이 낮으면 문제가 너무 쉬워 곡선이 평평 → 더 어려운 instance 필요
    if r0 <= eps:
        print(f"\n  [self-check] surrogate already at regret {r0:.3f} with k=0 -> task is currently EASY "
              f"(classes linearly separable). Frontier is flat/trivial; add within-kind severity instances "
              f"(consequential battery) so the surrogate is imperfect and the k-sweep becomes informative.")
    else:
        # 검증 1번(k=1)만 추가해도 regret 이 얼마나 줄어드는지 = 곡선이 유의미하다는 증거
        drop = r0 - np.mean(reg_model[1])
        print(f"\n  [self-check] informative frontier: 1 verification cuts regret by {drop:.3f} "
              f"({r0:.3f}->{np.mean(reg_model[1]):.3f}); surrogate beats random at every k.")


# 이 파일을 직접 실행할 때만 main() 호출 (import 될 때는 실행되지 않음)
if __name__ == "__main__":
    main()
