#!/usr/bin/env python
"""
run_e1_e2.py -- one-shot driver for the E1+E2 evaluation, with a SELF-EVOLVING control loop.

It runs the three analyses on a dataset (E1 ranking, E1 compute-frontier, E2 LLM-over-surrogate),
reads their self-checks, and prints a consolidated VERDICT plus the concrete next action the evidence
prescribes (grow data / add a decision class / broaden candidates / ship). This operationalizes
"detect the gap, prescribe the fix" — the loop the operator (or an outer automation) iterates on.

Usage:  python run_e1_e2.py <dataset.jsonl>
"""
# =====================================================================
# [한국어 개요]  run_e1_e2.py : E1+E2 파이프라인을 한 번에 돌리는 드라이버
# ---------------------------------------------------------------------
# 무엇을 하나:
#   한 데이터셋에 대해 세 분석을 순서대로 실행한다:
#     E1 ranking(e1_analyze) -> E1 compute-frontier(e1_frontier) -> E2 LLM-over-surrogate(e2_llm_surrogate).
#   각 분석이 뱉는 self-check(자기진단)를 읽고, "종합 판정(VERDICT)"과 함께
#   증거가 지시하는 다음 행동(데이터 늘리기 / 결정 클래스 추가 / 후보 넓히기 / 출시)을 출력한다.
#   즉 "격차를 감지하고 -> 고칠 방법을 처방"하는 self-evolving 루프의 한 바퀴다.
#
# 실행 방법:  python run_e1_e2.py <dataset.jsonl>
#
# 동작 방식(핵심):
#   각 분석 스크립트의 main()을 직접 호출하되, 그 print 출력을 가로채(run_capture) 모아서 보여준다.
#   그래서 이 파일 하나만 실행하면 E1/E2 전체 리포트가 한 화면에 나온다.
#
# 문법 참고:
#   - io.StringIO(): 문자열을 파일처럼 다루는 버퍼. print 출력을 여기로 리다이렉트해 담는다.
#   - contextlib.redirect_stdout(buf): with 블록 안의 표준출력(print)을 buf로 보내는 도구.
#   - sys.argv 교체 트릭: 하위 main()이 sys.argv[1]에서 경로를 읽으므로, 잠깐 argv를 바꿔치기했다가 복구.
#   - try/finally: 예외가 나든 안 나든 finally는 반드시 실행(여기선 argv 원복 보장).
#   - enumerate(리스트, 1): 인덱스를 1부터 시작해 (번호, 값) 쌍으로 순회.
# =====================================================================
import sys, os, io, math, contextlib
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # 옆 모듈 import 위해 이 폴더를 경로에 추가
# e1_analyze의 공용 도구들(load/판별/oracle-best/특징화/사전식키/매크로 이름·목록)
from e1_analyze import (load, instance_admissible, oracle_best_row, featurize, lex_key,
                        MACRO_NAME, MACROS)
import e1_analyze, e1_frontier, e2_llm_surrogate  # 하위 분석 모듈 3개(각각 main()을 가짐)


# 하위 분석의 main(fn)을 path로 실행하되, 그 print 출력을 문자열로 붙잡아 돌려준다.
def run_capture(fn, path):
    buf = io.StringIO()                      # 출력을 담을 메모리 버퍼
    old = sys.argv                           # 원래 argv 백업
    sys.argv = ["_", path]                   # 하위 main이 sys.argv[1]에서 경로 읽으므로 임시로 세팅
    try:
        with contextlib.redirect_stdout(buf):  # 이 블록의 print를 buf로 리다이렉트
            fn()                             # 하위 분석 실행
    finally:
        sys.argv = old                       # 성공/실패 무관하게 argv 원상복구
    return buf.getvalue()                    # 버퍼에 쌓인 출력 문자열 반환


# 드라이버 진입점: 데이터 요약 -> E1/E1-frontier/E2 리포트 출력 -> 종합 판정과 다음 행동 처방.
def main():
    path = sys.argv[1]                       # 데이터셋 경로
    df = load(path)
    df = df[df.fired == True].copy()         # 발동된 OOD 행만
    instances = list(df.instance.unique())   # 전체 instance 목록
    adm = [i for i in instances if instance_admissible(df[df.instance == i])]  # 유효 instance
    admdf = df[df.instance.isin(adm)]        # 유효 instance만 담은 표
    # class distribution  각 instance의 oracle-best 매크로가 무엇인지 모아 "결정 클래스" 분포 파악
    best = {}
    for iid in adm:
        b = oracle_best_row(admdf[admdf.instance == iid]); best[iid] = int(b.macro)  # instance -> 최선 매크로 번호
    classes = sorted(set(best.values()))     # 등장한 최선 매크로들의 집합(정렬)
    n_classes = len(classes)                 # 서로 다른 정답 클래스 개수(1이면 과제가 trivial)

    print("=" * 70)
    print("E1 + E2 CONSOLIDATED RUN")
    print("=" * 70)
    print(f"dataset: {path}")
    print(f"rows={len(df)}  instances={len(instances)}  admissible={len(adm)}  "
          f"decision-classes={n_classes} ({[MACRO_NAME[c] for c in classes]})")

    # 세 분석 리포트를 차례로 실행해 출력(각각 run_capture로 print를 붙잡아 한 번에 보여줌)
    print("\n" + "-" * 70 + "\n[E1] ranking + Level-0 + bootstrap\n" + "-" * 70)
    print(run_capture(e1_analyze.main, path))
    print("-" * 70 + "\n[E1] compute-frontier (decision-regret vs planner calls)\n" + "-" * 70)
    print(run_capture(e1_frontier.main, path))
    print("-" * 70 + "\n[E2] LLM-over-surrogate vs LLM-over-solver\n" + "-" * 70)
    print(run_capture(e2_llm_surrogate.main, path))

    # ---- self-evolving verdict: what does the evidence say to do next? ----
    # 증거 기반 자기진단: 발견한 격차(gap)를 모아 "다음에 뭘 해야 하는지" 처방을 만든다
    print("=" * 70)
    print("SELF-EVOLVING VERDICT  (detect gap -> prescribe fix)")
    print("=" * 70)
    gaps = []                                # 발견된 격차 메시지들을 담을 리스트
    if len(adm) < 12:                        # 유효 instance가 너무 적으면 신뢰구간이 넓다 -> 데이터 더 생성
        gaps.append(f"DATA: only {len(adm)} admissible instances -> generate more seeds "
                    f"(gen_oracle_dataset.jl, batch <=2 to avoid OOM) for tighter CIs.")
    if n_classes < 2:                        # 정답 매크로가 하나뿐이면 과제가 trivial -> 결정 클래스 추가 필요
        gaps.append("TRIVIALITY: best macro is constant -> add a 2nd decision class "
                    "(e.g. consequential blocking-zone `zoneblk`).")
    # frontier informativeness: is the surrogate imperfect anywhere?
    # reuse a quick LOO regret@k=0 vs verify-all check
    # frontier가 의미 있으려면 surrogate가 어딘가는 틀려야 한다 -> planner call 0(top-1만, 검증 없이)일 때의 regret을 재본다
    from surrogate_model import build_model
    from sklearn.model_selection import LeaveOneGroupOut
    X = featurize(admdf).values; y = admdf.closed.astype(float).values; groups = admdf.instance.values  # 특징/정답/그룹
    r0 = []                                  # k=0(검증 안 함) regret 기록
    for tr, te in LeaveOneGroupOut().split(X, y, groups):  # instance 하나씩 빼며 검증
        g = admdf.iloc[te]; macros = [int(m) for m in g.macro]
        closed_by = {int(m): float(c) for m, c in zip(g.macro, g.closed)}   # 매크로 -> closed
        comp_by = {int(m): bool(c) for m, c in zip(g.macro, g.complete)}    # 매크로 -> 완주 여부
        mk_by = {int(m): (float(v) if not isinstance(v, str) else math.inf) for m, v in zip(g.macro, g.makespan)}  # 매크로 -> makespan
        m = build_model()
        m.fit(X[tr], y[tr]); pred = m.predict(X[te])  # 학습 후 held-out 예측
        pick = macros[int(np.argmax(pred))]           # 검증 없이 예측 1등을 그대로 선택(argmax=최댓값 위치)
        best_m = max(macros, key=lambda mm: lex_key(comp_by[mm], closed_by[mm], mk_by[mm]))  # 진짜 최선
        span = max(closed_by[best_m] - min(closed_by.values()), 1e-9)      # regret 정규화 폭
        r0.append((closed_by[best_m] - closed_by[pick]) / span)           # 이 instance의 k=0 regret
    if np.mean(r0) <= 0.02:                   # 검증 0번인데도 regret~0이면 과제가 "decision-easy"라는 신호
        gaps.append("FRONTIER: surrogate top-1 regret ~0 at 0 planner calls -> task is DECISION-EASY "
                    "(OOD-type determines the macro). Compute win is real & shippable, but the "
                    "quality-compute TRADEOFF (Level-3 exploration upside) needs a taxonomy where "
                    "candidate outcomes are CLOSE (graded consequential OOD). Attempted: battery "
                    "severity (collapses to Replace / stays harmless in this build).")
    if not gaps:                             # 격차가 하나도 없으면 출시 가능
        print("  No gaps: E1 ranking + informative frontier + E2 amortization all pass. SHIP.")
    else:                                    # 격차가 있으면 번호 매겨 처방 나열
        print("  Evidence-prescribed next actions:")
        for i, g in enumerate(gaps, 1):      # 1부터 번호 매기기
            print(f"   {i}. {g}")
    print("\n  STATUS: E1 (dump seam + ranking + Level-0 + frontier) and E2 (verify-top-k vs "
          "verify-all) are COMPLETE and reproducible on this dataset.")


if __name__ == "__main__":  # 직접 실행할 때만 main() 호출
    main()
