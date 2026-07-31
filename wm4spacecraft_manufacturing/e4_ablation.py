#!/usr/bin/env python
"""
E4 -- integration ablation grid (PROPOSAL.md E4 / EVALUATION.md Level-2..4).

The full system = an LLM re-specification producer + a learned surrogate ranker + closed-loop
retraining, on the deterministic ConstructionBots twin. E4 is the ablation grid over its three axes;
each cell is exactly one PRIOR-ART regime, so the table doubles as the "vs prior art" comparison. All
cells are run on the SAME non-stationary drift stream (faults -> novel blocking-zones, as in E3) and
scored on decision quality (feasibility-lexicographic regret vs the oracle-best) AND true-planner
compute (calls). The full cell should dominate: near-oracle quality, robust across the drift, at a
fraction of the planner compute.

| cell | producer      | scorer            | retrain | = prior-art regime                              |
|------|---------------|-------------------|---------|-------------------------------------------------|
|  A   | all macros    | oracle (verify all)| --     | brute-force planner oracle (quality ceiling)    |
|  B   | LLM (N cand)  | oracle (verify all)| frozen  | LLM -> exact solver  (arXiv 2506.18178)         |
|  C   | LLM (N cand)  | surrogate (top-1) | frozen  | learned surrogate, NO retraining (E2 static)    |
|  D   | LLM (N cand)  | surrogate (top-1) | ACTIVE  | FULL system (ours, E4)                          |

Spacecraft note: per PROPOSAL.md the spacecraft twin is a *representative proxy*; the transferable
deliverable is the method + DSL + OOD taxonomy + retraining procedure, re-fittable onto a facility's own
high-fidelity twin. E4 here is the integration ablation on the ConstructionBots (tractor) twin; the
satellite-bus instantiation is the transfer target, not a re-trained set of weights.

Usage:  python e4_ablation.py <dataset.jsonl>
"""
# =====================================================================
# [한국어 개요]  E4 실험: 전체 시스템의 ablation(구성요소 제거 실험) 격자
# ---------------------------------------------------------------------
# 무엇을 하나:
#   전체 시스템 = LLM re-spec producer + 학습된 surrogate ranker + closed-loop 재학습.
#   이 세 축을 켜고 끄며 만든 4개 셀(A~D)을 "같은 drift 스트림"으로 돌려 비교한다.
#   각 셀은 곧 하나의 선행연구(prior-art) 방식이라서, 이 표가 그대로 "vs 선행연구" 비교가 된다.
#     A brute-oracle       : 모든 macro를 매번 검증(품질 상한, 매우 비쌈)
#     B LLM->solver        : LLM이 후보 좁힘 + 모든 후보 검증(regret~0, 여전히 비쌈) = arXiv 2506.18178
#     C LLM+surrogate(stat): surrogate top-1만 검증, 재학습 없음(E2 정적) -> drift에 붕괴
#     D LLM+surrogate+RT   : 전체 시스템(ours). drift 나면 재학습으로 회복
#   핵심 주장: D가 Pareto front에 있다 = 품질과 compute 둘 다에서 다른 셀에 지지 않는다.
#
# 어떤 실험인가: PROPOSAL.md의 E4 / EVALUATION.md의 Level-2..4.
#
# 실행 방법:  python e4_ablation.py <dataset.jsonl>
#
# 채점: feasibility-lexicographic regret(oracle-best 대비) + planner call 수 두 축으로 평가.
#
# 문법 참고:
#   - dict 리터럴 cells = {"이름": run_cell(...)}: 각 셀을 한 번씩 돌려 (regret리스트, calls)를 저장.
#   - 튜플 언패킹 for name, (reg, calls) in cells.items(): 딕셔너리를 (키, 값) 쌍으로 순회.
#   - Pareto front: 두 지표(품질/비용)에서 어느 한쪽도 손해 없이 개선해줄 다른 셀이 없는 상태.
#   - any(... for ...): 하나라도 참이면 True(여기선 D를 지배하는 셀이 있는지 검사).
# =====================================================================
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # 옆 모듈 import 위해 이 폴더를 경로에 추가
from e1_analyze import load, instance_admissible, featurize, lex_key  # 공용 도구들
from surrogate_model import build_model                               # surrogate 본체(단일 정의)
from drift_detectors import CusumDetector, AdwinDetector, ConformalMartingaleDetector, make_novelty  # 교체 가능한 drift 감지기 + covariate 신호

# OOD 종류별 LLM 후보 매크로(정답 + NOOP + distractor). E2와 동일한 후보 정의.
LLM_CANDIDATES = {"fault": [0, 1, 2], "battery": [0, 1, 2], "zone": [0, 3, 1], "zoneblk": [0, 3, 1]}


# build_model 은 surrogate_model.py 에서 import (평가·배포 동일 모델 보장).


# E4 전체 실행: drift 스트림 구성 -> 4개 셀(A~D) 시뮬레이션 -> 표/headline/Pareto 판정 출력.
def main():
    path = sys.argv[1]
    df = load(path)
    df = df[df.fired == True].copy()         # 발동된 OOD 행만
    adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]  # 유효 instance
    df = df[df.instance.isin(adm)].reset_index(drop=True)
    _F = featurize(df); feat_cols = list(_F.columns)  # 컬럼 이름 보관(covariate novelty용)
    Xall = _F.values                         # 특징행렬
    ridx = {(r.instance, int(r.macro)): i for i, r in enumerate(df.itertuples(index=False))}  # (instance,macro)->행 인덱스

    # 한 instance(iid) 정보를 딕셔너리로 요약(e3의 inst_rows와 동일 역할, 키 이름만 짧음).
    def inst(iid):
        g = df[df.instance == iid]
        ms = [int(m) for m in g.macro]                                   # 매크로 목록
        cl = {int(m): float(c) for m, c in zip(g.macro, g.closed)}       # 매크로 -> closed
        cp = {int(m): bool(c) for m, c in zip(g.macro, g.complete)}      # 매크로 -> 완주 여부
        mk = {int(m): (float(v) if not isinstance(v, str) else math.inf) for m, v in zip(g.macro, g.makespan)}  # 매크로 -> makespan
        best = max(ms, key=lambda m: lex_key(cp[m], cl[m], mk[m]))       # 진짜 최선 매크로
        span = max(cl[best] - min(cl.values()), 1e-9)                    # regret 정규화 폭
        return dict(iid=iid, macros=ms, cl=cl, cp=cp, mk=mk, best=best, span=span, kind=g.kind.iloc[0])

    faults = [inst(i) for i in adm if df[df.instance == i].kind.iloc[0] == "fault"]        # fault instance들
    zones = [inst(i) for i in adm if df[df.instance == i].kind.iloc[0] in ("zoneblk", "zone")]  # zone 계열
    rng = np.random.default_rng(0); rng.shuffle(faults); rng.shuffle(zones)  # 시드 고정 후 섞기
    if len(faults) < 4 or len(zones) < 3:    # 최소 개수 확인
        print(f"need >=4 fault, >=3 zone; have {len(faults)}/{len(zones)}."); return
    boot = faults[:max(3, len(faults)//3)]   # 초기 학습용 fault
    stream = faults[len(boot):] + zones      # 스트림: 남은 fault(phase A) 다음 zone(phase B=drift)
    drift_at = len(faults) - len(boot)       # drift 스텝 인덱스(=남은 fault 개수)

    # covariate-shift novelty 신호 준비(매크로 one-hot 열 제외한 상태 feature만 사용). E3와 동일.
    STATE_IDX = [i for i, c in enumerate(feat_cols) if not c.startswith("macro_")]
    def state_vec(it):
        return Xall[ridx[(it['iid'], it['macros'][0])]][STATE_IDX]
    novelty = make_novelty([state_vec(it) for it in boot])

    # 주어진 instance들로 model 학습(모든 (instance,macro) 행을 펼쳐서 fit).
    def fit(m, insts):
        rows = [ridx[(it['iid'], mm)] for it in insts for mm in it['macros']]
        ys = [it['cl'][mm] for it in insts for mm in it['macros']]
        m.fit(Xall[rows], np.array(ys))

    # producer에 따라 후보 매크로 집합을 만든다: "all"=전부, 아니면 LLM이 좁힌 후보만.
    def cand_set(it, producer):
        if producer == "all":
            return list(it['macros'])
        c = [m for m in LLM_CANDIDATES.get(it['kind'], it['macros']) if m in set(it['macros'])]  # 실제 존재하는 후보만
        return list(dict.fromkeys(c))        # 순서 유지 중복 제거

    # 매크로 목록 ms 중 사전식 최선(진짜 best)을 고른다.
    def lexbest(it, ms):
        return max(ms, key=lambda m: lex_key(it['cp'][m], it['cl'][m], it['mk'][m]))

    # 한 셀을 처음부터 끝까지 시뮬레이션한다.
    #   producer: 후보 생성 방식("all" 또는 "llm")
    #   scorer:   승자 선정 방식("oracle"=모두 검증 / "surrogate"=예측 순위로 top-k만 검증)
    #   retrain:  재학습 방식("none"/"frozen"=안 함 / "active"=CUSUM drift 시 재학습)
    # 반환: (스텝별 regret 리스트, 총 planner call)
    def run_cell(producer, scorer, retrain, make_detector=None, signal_fn=None):
        # make_detector: drift 감지기 생성 factory(기본=CUSUM/residual = 레거시와 동일). 재현성 위해 기본값 유지.
        # signal_fn(it, resid) -> float: 감지기에 먹일 스칼라(레거시=resid, 권장=covariate novelty).
        if make_detector is None: make_detector = lambda: CusumDetector()
        if signal_fn is None: signal_fn = lambda it, resid: resid
        m = build_model(); fit(m, boot); buf = list(boot)   # 초기 학습 + 학습버퍼
        reg = []; calls = 0; escalate = 0; cooldown = 0
        detector = make_detector()                           # 이 셀 전용 감지기(셀마다 새로)
        for t, it in enumerate(stream):
            cand = cand_set(it, producer)                # 이 스텝의 후보 매크로 집합
            if scorer == "oracle":                       # verify EVERY candidate (후보 전부 검증)
                pick = lexbest(it, cand); calls += len(cand); resid = 0.0  # 항상 최선 -> regret 0, call=후보수
            else:                                        # surrogate ranks; verify top-1 (or all if escalated)
                preds = {mm: float(m.predict(Xall[ridx[(it['iid'], mm)]].reshape(1, -1))[0]) for mm in cand}  # 후보별 예측
                order = sorted(cand, key=lambda mm: preds[mm], reverse=True)   # 예측 높은 순
                k = len(cand) if (retrain == "active" and escalate > 0) else 1  # escalate 중이면 전부, 아니면 top-1
                verified = order[:k]; calls += len(verified)                    # 검증한 만큼 call 증가
                pick = lexbest(it, verified)                                    # 검증된 것 중 진짜 최선
                resid = abs(preds[order[0]] - it['cl'][order[0]])              # top-1 잔차(레거시 신호)
                if retrain == "active" and escalate > 0:
                    buf.append(it)                                             # 전체검증한 instance만 버퍼에
            reg.append((it['cl'][it['best']] - it['cl'][pick]) / it['span'])   # 이 스텝 regret 기록
            # retraining logic (active + surrogate 조합에서만 drift 감지/재학습)
            if retrain == "active" and scorer == "surrogate":
                drift = detector.update(signal_fn(it, resid)) and cooldown == 0  # 감지기에 신호 먹여 발화 판정
                if drift:
                    escalate = 3; cooldown = 3
                if escalate > 0:
                    escalate -= 1
                    if escalate == 0:                    # 재라벨 창 끝 -> 버퍼로 재학습 + 감지기 리셋
                        fit(m, buf); detector.reset()
                if cooldown > 0:
                    cooldown -= 1
        return reg, calls

    # 4개 셀을 각각 실행해 결과 저장(각 셀 = 선행연구 regime 하나)
    cells = {
        "A brute-oracle":       run_cell("all", "oracle", "none"),      # 모든 macro 검증(상한)
        "B LLM->solver":        run_cell("llm", "oracle", "frozen"),    # LLM 후보 + 전부 검증
        "C LLM+surrogate(stat)":run_cell("llm", "surrogate", "frozen"), # surrogate top-1, 재학습 없음
        "D LLM+surrogate+RT":   run_cell("llm", "surrogate", "active",  # 전체 시스템(ours); DEFAULT=CUSUM/novelty
                                         make_detector=lambda: CusumDetector(slack=1.5, thresh=6.0),
                                         signal_fn=lambda it, resid: novelty(state_vec(it))),
    }

    def post(x): return float(np.mean(x[drift_at:]))  # drift 이후 구간 평균 regret
    print(f"stream: {len(stream)} steps, drift at {drift_at} (faults -> novel zones); bootstrap={len(boot)}\n")
    print(f"{'cell (= prior regime)':<24}{'regret all':>12}{'regret post-drift':>18}{'planner calls':>15}")
    print("-" * 69)
    for name, (reg, calls) in cells.items():
        print(f"{name:<24}{np.mean(reg):>12.3f}{post(reg):>18.3f}{calls:>15}")

    # 각 셀 결과를 짧은 이름으로 꺼내오기(A/B/C/D 각각 (reg리스트, calls) 튜플)
    A = cells["A brute-oracle"]; B = cells["B LLM->solver"]; C = cells["C LLM+surrogate(stat)"]; D = cells["D LLM+surrogate+RT"]
    print("\nHEADLINE (E4):")
    print(f"  FULL (D): post-drift regret {post(D[0]):.3f} at {D[1]} planner calls.")
    print(f"    vs B (LLM->solver, the strong prior-art baseline that verifies EVERY candidate so is "
          f"always ~0 regret): D matches its quality trend at {100*(1-D[1]/max(B[1],1)):.0f}% fewer calls.")
    print(f"    vs C (static surrogate): C collapses post-drift ({post(C[0]):.3f}); D recovers "
          f"({post(D[0]):.3f}) -> retraining is what makes the cheap surrogate safe under drift.")
    # Pareto: D is not beaten by any other cell on BOTH axes (quality AND compute) simultaneously.
    # x가 y에게 "지배당하는가": y가 두 축(regret, calls) 모두에서 x보다 나쁘지 않고, 최소 한 축에선 더 좋다.
    def dominated_by(x, y):   # is x (regret,calls) strictly worse-or-equal on both, worse on one?
        return (post(y[0]) <= post(x[0]) and y[1] <= x[1]) and (post(y[0]) < post(x[0]) or y[1] < x[1])
    on_front = not any(dominated_by(D, other) for other in (A, B, C))  # D를 지배하는 셀이 하나도 없으면 front 위
    print(f"  D is on the quality-compute Pareto front (no cell beats it on both axes): {on_front}")
    print(f"    (B buys its 0 regret with {B[1]} calls; A with {A[1]}; C is cheap but drift-broken. "
          f"D trades a small transient drift-recovery regret for the lowest robust compute.)")

    # ---- E4b: cell-D의 재학습 트리거(감지기/신호)만 바꿔 비교 ----
    # D(레거시)=CUSUM/residual. 여기에 D CUSUM/novelty, D ADWIN/novelty 를 같은 셀 구성으로 추가 비교.
    D_cr = run_cell("llm", "surrogate", "active")  # 옛 default: CUSUM/residual (비교용). D(=cells의 D)는 이제 CUSUM/novelty.
    D_an = run_cell("llm", "surrogate", "active",
                    make_detector=lambda: AdwinDetector(delta=0.05, grace_period=5, min_window_length=5),
                    signal_fn=lambda it, resid: novelty(state_vec(it)))
    _cal = [novelty(state_vec(it)) for it in boot]  # conformal calibration = bootstrap novelty(in-distribution)
    D_cm = run_cell("llm", "surrogate", "active",
                    make_detector=lambda: ConformalMartingaleDetector(_cal, alpha=0.05),
                    signal_fn=lambda it, resid: novelty(state_vec(it)))
    print("\n=== E4b: cell-D retrain-trigger comparison (detector/signal) ===")
    print(f"{'D variant':<30}{'regret all':>12}{'regret post-drift':>18}{'planner calls':>15}")
    for nm, cv in [("D CUSUM/resid (old default)", D_cr), ("D CUSUM/novelty (NEW default)", D),
                   ("D ADWIN/novelty", D_an), ("D Conformal/novelty", D_cm)]:
        print(f"{nm:<30}{np.mean(cv[0]):>12.3f}{post(cv[0]):>18.3f}{cv[1]:>15}")
    print("  (cell D is NOW CUSUM/novelty. value-residual was mis-specified; ADWIN under-fires on this short")
    print("   stream. See compare_detectors.py for the long-stream case where ADWIN fires with 0 spurious retrains.)")


if __name__ == "__main__":  # 직접 실행할 때만 main() 호출
    main()
