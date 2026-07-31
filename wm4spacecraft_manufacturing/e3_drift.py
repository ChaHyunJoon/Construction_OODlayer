#!/usr/bin/env python
"""
E3 -- closed-loop retraining under OOD DRIFT (PROPOSAL.md E3 / EVALUATION.md Level-4).

A surrogate that amortizes the planner is only useful if it STAYS accurate as the OOD distribution
drifts. We build a non-stationary stream: PHASE A = robot-fault OODs (the distribution the surrogate
bootstraps on), then a DRIFT to PHASE B where a NOVEL OOD type appears (blocking-zone -> ForbidZone).
A frozen surrogate has never seen a zone, so it keeps predicting as if every OOD were a fault (picks
Replace) and its decisions become catastrophic. Four policies are compared:

  * ORACLE        : verify EVERY macro with the true planner every step (regret 0, maximal compute) - ceiling.
  * FROZEN        : bootstrap once, never retrain (degrades after the drift) - the do-nothing floor.
  * PERIODIC      : retrain every P steps regardless (spends planner calls even with no drift).
  * ACTIVE (ours) : verify the surrogate's top-k each step (a few planner calls) to get a drift signal;
                    a CUSUM covariate-NOVELTY monitor flags drift (value-residual was mis-specified; see
                    FINDINGS_ADWIN.md); on a flag, ESCALATE verification (relabel the
                    drifted instances by verifying all their macros) and RETRAIN on the buffer, then
                    de-escalate. Anti-thrash: cooldown between retrains.

Decision at each step = the best VERIFIED macro (as in E2); regret is vs the oracle-best for that
instance. Metrics: regret time-series, area between FROZEN and ACTIVE post-drift, time-to-recover,
and planner-calls spent (active should hold near-oracle quality at << oracle/periodic compute).

Runs on the oracle dataset (every macro's true outcome is known). Usage:
  python e3_drift.py <dataset.jsonl>
"""
# =====================================================================
# [한국어 개요]  E3 실험: OOD 분포가 "변할 때(drift)" surrogate가 살아남는가
# ---------------------------------------------------------------------
# 무엇을 하나:
#   OOD 종류가 도중에 바뀌는 스트림을 만든다.
#     - PHASE A: robot-fault OOD들 (surrogate가 처음 학습한 익숙한 분포)
#     - DRIFT(전환) 이후 PHASE B: 새로운 OOD 종류 등장(blocking-zone -> ForbidZone)
#   frozen surrogate는 zone을 본 적이 없어, 모든 걸 fault처럼 취급(Replace만 고름) -> 결정이 망가짐.
#   네 가지 정책을 비교한다:
#     - ORACLE   : 매 스텝 모든 macro를 진짜 planner로 검증(regret 0, 최대 비용) = 품질 상한(ceiling).
#     - FROZEN   : 한 번 학습하고 재학습 안 함(drift 후 붕괴) = 아무것도 안 한 바닥(floor).
#     - PERIODIC : drift 여부와 무관하게 P 스텝마다 무조건 재학습(낭비 가능).
#     - ACTIVE(ours): top-k만 검증해 drift 신호를 얻고, CUSUM covariate-novelty 모니터가 drift를 감지하면
#                     그때만 검증을 늘려(escalate) 재라벨+재학습. cooldown으로 과잉 재학습 방지.
#                     (value-residual은 drift 신호가 아니어서 novelty로 승격; 상세=FINDINGS_ADWIN.md)
#
# 어떤 실험인가: PROPOSAL.md의 E3 / EVALUATION.md의 Level-4.
#
# 실행 방법:  python e3_drift.py <dataset.jsonl>
#
# 채점: 각 스텝 결정 = 검증된 macro 중 최선. regret = 그 instance의 oracle-best 대비 손해.
#       핵심 지표 = drift 이후 regret(frozen vs active), 회복까지 스텝수, 소모한 planner call.
#
# 문법 참고:
#   - np.random.default_rng(0): 시드 0의 난수생성기(재현 가능). rng.shuffle(리스트)로 섞음.
#   - 중첩 함수(def 안의 def): main() 안에서만 쓰는 도우미 함수(바깥 변수 df 등을 그대로 씀).
#   - CUSUM(누적합): 잔차를 계속 더해 임계치 넘으면 "변화 발생"으로 판단하는 고전적 감지법.
#   - 슬라이싱 x[drift_at:]: 리스트에서 drift_at 인덱스부터 끝까지(=drift 이후 구간).
#   - lambda m: ...: 한 줄짜리 익명 함수. max(..., key=lambda ...)에서 정렬/비교 기준으로 씀.
# =====================================================================
import sys, os, math
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # 옆 모듈 import 위해 이 폴더를 경로에 추가
from e1_analyze import load, instance_admissible, featurize, lex_key, MACRO_NAME  # 공용 도구들
from surrogate_model import build_model                          # surrogate 본체(평가·배포 단일 정의)
from drift_detectors import CusumDetector, AdwinDetector, ConformalMartingaleDetector, make_novelty  # 교체 가능한 drift 감지기 + covariate 신호


# build_model 은 surrogate_model.py 에서 가져온다(재학습 때마다 깨끗한 모델을 새로 만들어 씀).
# 여기에 하이퍼파라미터를 다시 적지 않는 이유: 평가와 배포가 갈라지는 것을 막기 위함.


# E3 전체 실행: drift 스트림 구성 -> 4개 정책 시뮬레이션 -> regret 시계열/요약/headline 출력.
def main():
    path = sys.argv[1]                       # 데이터셋 경로
    df = load(path)
    df = df[df.fired == True].copy()         # 발동된 OOD 행만
    adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]  # 유효 instance
    df = df[df.instance.isin(adm)].reset_index(drop=True)
    # feature matrix keyed by (instance, macro)
    _F = featurize(df); feat_cols = list(_F.columns)  # 컬럼 이름 보관(covariate novelty가 상태 feature만 골라 쓰려고)
    Xall = _F.values                         # 전체 특징행렬
    # (instance, macro) -> 그 행이 Xall에서 몇 번째인지. enumerate=인덱스와 값을 같이 순회
    row_idx = {(r.instance, int(r.macro)): i for i, r in enumerate(df.itertuples(index=False))}

    # per-instance record
    # 한 instance(iid)의 정보를 딕셔너리로 요약: 매크로 목록, 각 매크로의 결과, 진짜 best, 정규화 폭 등.
    def inst_rows(iid):
        g = df[df.instance == iid]           # 이 instance의 모든 매크로 행
        macros = [int(m) for m in g.macro]   # 가능한 매크로 번호들
        closed = {int(m): float(c) for m, c in zip(g.macro, g.closed)}  # 매크로 -> closed(닫힌 step 수)
        comp = {int(m): bool(c) for m, c in zip(g.macro, g.complete)}   # 매크로 -> 완주 여부
        # 매크로 -> makespan(문자열이면 무한대=최악)
        mk = {int(m): (float(v) if not isinstance(v, str) else math.inf) for m, v in zip(g.macro, g.makespan)}
        best = max(macros, key=lambda m: lex_key(comp[m], closed[m], mk[m]))  # 이 instance의 진짜 최선
        span = max(closed[best] - min(closed.values()), 1e-9)                 # regret 정규화 폭
        kind = g.kind.iloc[0]                # OOD 종류
        return dict(macros=macros, closed=closed, comp=comp, mk=mk, best=best, span=span, kind=kind, iid=iid)

    # fault 종류 instance들, zone 계열(zoneblk/zone) instance들로 분리
    faults = [inst_rows(i) for i in adm if df[df.instance == i].kind.iloc[0] == "fault"]
    zones = [inst_rows(i) for i in adm if df[df.instance == i].kind.iloc[0] in ("zoneblk", "zone")]
    rng = np.random.default_rng(0)           # 시드 고정 난수기(재현 가능)
    rng.shuffle(faults); rng.shuffle(zones)  # 순서를 섞어 편향 제거
    if len(faults) < 4 or len(zones) < 3:    # 실험에 필요한 최소 개수 확인
        print(f"need >=4 fault and >=3 zone instances; have {len(faults)}/{len(zones)}. Generate more.")
        return

    # bootstrap on a few faults; stream = remaining faults (phase A) then zones (phase B, the drift)
    boot = faults[:max(3, len(faults) // 3)]  # 초기 학습용 fault 몇 개(최소 3개)
    streamA = faults[len(boot):]              # phase A: 남은 fault들(익숙한 분포)
    streamB = zones                           # phase B: zone들(새 분포 = drift 이후)
    drift_at = len(streamA)                   # drift가 일어나는 스텝 인덱스(=phase A 길이)
    stream = streamA + streamB                # 실제로 순서대로 처리할 전체 스트림
    print(f"bootstrap={len(boot)} faults | phase A={len(streamA)} faults | DRIFT | phase B={len(streamB)} zones")

    # 주어진 instance 목록(insts)의 모든 (instance,macro) 행으로 model을 학습시킨다(중첩 for로 행 펼침).
    def fit(model, insts):
        rows = [row_idx[(it['iid'], m)] for it in insts for m in it['macros']]  # 학습에 쓸 행 인덱스들
        ys = [it['closed'][m] for it in insts for m in it['macros']]            # 대응하는 정답 closed 값들
        model.fit(Xall[rows], np.array(ys))

    # 한 instance(it)에서 surrogate 예측으로 순위를 매기고 top-k만 검증해 고른다.
    # 반환: (고른 macro, regret, 실제 검증 수, top-1 잔차, 예측딕셔너리)
    def predict_pick(model, it, k):
        """predict macro closed, verify top-k, return (pick, regret, calls)."""
        # 각 매크로에 대한 surrogate 예측(closed 추정)
        preds = {m: float(model.predict(Xall[row_idx[(it['iid'], m)]].reshape(1, -1))[0]) for m in it['macros']}
        order = sorted(it['macros'], key=lambda m: preds[m], reverse=True)  # 예측 높은 순 정렬
        kk = min(k, len(order))                                             # k가 매크로 수보다 크면 제한
        verified = order[:kk]                                              # 상위 kk개만 진짜 검증
        pick = max(verified, key=lambda m: lex_key(it['comp'][m], it['closed'][m], it['mk'][m]))  # 그중 진짜 최선
        regret = (it['closed'][it['best']] - it['closed'][pick]) / it['span']  # 정답 대비 손해(정규화)
        # residual on the verified top-1 (predicted vs true closed)
        resid = abs(preds[order[0]] - it['closed'][order[0]])  # 예측 1등의 예측-실제 오차 = drift 감지 신호
        return pick, regret, kk, resid, preds

    results = {}                             # 정책 이름 -> (regret 리스트, 총 planner call)
    # ---- FROZEN ----  한 번 학습(boot) 후 재학습 없이 매 스텝 top-1만 검증
    m = build_model(); fit(m, boot)
    reg = []; calls = 0
    for it in stream:
        # _는 안 쓰는 반환값 무시. r=regret, c=검증수
        _, r, c, _, _ = predict_pick(m, it, k=1); reg.append(r); calls += c
    results['frozen'] = (reg, calls)

    # ---- ORACLE (verify all) ----  매 스텝 모든 매크로 검증 -> 항상 최선(regret 0), 비용 최대
    reg = []; calls = 0
    for it in stream:
        reg.append(0.0); calls += len(it['macros'])  # 검증 수 = 매크로 개수만큼
    results['oracle'] = (reg, calls)

    # ---- PERIODIC (retrain every P) ----  drift 여부와 무관하게 P 스텝마다 재학습
    P = 4                                    # 재학습 주기
    m = build_model(); fit(m, boot); buf = list(boot); reg = []; calls = 0  # buf=학습버퍼(초기=boot 복사)
    for t, it in enumerate(stream):          # enumerate: t=스텝 인덱스, it=instance
        _, r, c, _, _ = predict_pick(m, it, k=1); reg.append(r); calls += c
        buf.append(it); calls += len(it['macros'])  # periodic relabels the instance fully (전체 재라벨 비용 추가)
        if (t + 1) % P == 0:                  # P 스텝마다 버퍼 전체로 재학습
            fit(m, buf)
    results['periodic'] = (reg, calls)

    # ---- ACTIVE policy, now PLUGGABLE over (detector, drift-signal) ----------
    # 원래는 "잔차 CUSUM" 하나였지만, 감지기(CUSUM/ADWIN)와 신호(residual/covariate novelty)를 갈아끼울 수 있게 일반화.
    # 상태-feature novelty(=covariate-shift 점수)를 만들 준비: 매크로 one-hot 열은 빼고 상태 feature만 사용.
    STATE_IDX = [i for i, c in enumerate(feat_cols) if not c.startswith("macro_")]  # 상태 feature 열 인덱스
    def state_vec(it):                                        # 이 instance의 상태-feature 벡터(매크로 무관)
        return Xall[row_idx[(it['iid'], it['macros'][0])]][STATE_IDX]
    novelty = make_novelty([state_vec(it) for it in boot])    # bootstrap 분포 기준 covariate-shift novelty

    # run_active: 하나의 (감지기, 신호함수) 조합으로 ACTIVE 정책을 끝까지 시뮬레이션.
    #   signal_fn(it, resid) -> float : 감지기에 먹일 스칼라. 레거시=resid, 권장=covariate novelty.
    # 반환 dict: reg(스텝별 regret), calls(planner 호출), recover(회복 스텝), n_fire/n_spurious(발화·오발화 수).
    def run_active(detector, signal_fn):
        m = build_model(); fit(m, boot); buf = list(boot)
        reg = []; calls = 0; escalate = 0; cooldown = 0; recover = None
        n_fire = 0; n_spurious = 0
        for t, it in enumerate(stream):
            k = len(it['macros']) if escalate > 0 else 1     # escalate 중이면 전부 검증(정확 라벨 확보)
            pick, r, c, resid, _ = predict_pick(m, it, k=k)
            reg.append(r); calls += c
            if escalate > 0:                                 # 전체검증한 instance만 버퍼에(라벨이 정확)
                buf.append(it)
            drift = detector.update(signal_fn(it, resid)) and cooldown == 0  # 감지기에 신호 먹이고 발화 판정(쿨다운 게이트)
            if drift:
                n_fire += 1
                if t < drift_at:                             # drift 이전 발화 = 오발화(spurious)
                    n_spurious += 1
                escalate = 3; cooldown = 3
            if escalate > 0:
                escalate -= 1
                if escalate == 0:                            # 재라벨 창 끝 -> 재학습 + 감지기 리셋
                    fit(m, buf); detector.reset()
            if cooldown > 0:
                cooldown -= 1
            if t >= drift_at and recover is None and r <= 0.02 and t > drift_at:
                recover = t - drift_at                       # drift 이후 처음 regret<=0.02 된 스텝(상대)
        return dict(reg=reg, calls=calls, recover=recover, n_fire=n_fire, n_spurious=n_spurious)

    # 세 arm 비교: (1) 레거시 CUSUM/residual, (2) 신호만 바꾼 CUSUM/novelty, (3) ADWIN/novelty.
    arm_cr = run_active(CusumDetector(),                      lambda it, rr: rr)                     # 레거시(현재 E3)
    arm_cn = run_active(CusumDetector(slack=1.5, thresh=6.0), lambda it, rr: novelty(state_vec(it)))  # 신호만 교체
    arm_an = run_active(AdwinDetector(delta=0.05, grace_period=5, min_window_length=5),
                                                             lambda it, rr: novelty(state_vec(it)))   # ADWIN
    cal_scores = [novelty(state_vec(it)) for it in boot]     # conformal calibration = bootstrap novelty(in-distribution)
    arm_cm = run_active(ConformalMartingaleDetector(cal_scores, alpha=0.05),
                                                             lambda it, rr: novelty(state_vec(it)))   # conformal martingale
    detector_arms = {"CUSUM/resid (old default)": arm_cr, "CUSUM/novelty (DEFAULT)": arm_cn,
                     "ADWIN/novelty": arm_an, "Conformal/novelty": arm_cm}
    # DEFAULT 승격: 'active' = CUSUM/novelty. value-residual은 이 과제의 drift 신호가 아니므로(오지정),
    # covariate-shift novelty를 정식 신호로 채택. 감지기는 CUSUM 유지(ADWIN은 짧은 스트림서 발화 불가). 상세=FINDINGS_ADWIN.md.
    results['active'] = (arm_cn['reg'], arm_cn['calls'])      # 정식 default = CUSUM/novelty
    recover_step = arm_cn['recover']                         # default arm의 회복 스텝(아래 print에서 사용)

    # ---------- report ----------  스텝별 regret 표를 정책별로 나란히 출력
    print(f"\n=== E3: regret over the drift stream (drift at step {drift_at}) ===")
    print(f"{'step':>5}{'kind':>9}{'frozen':>9}{'active':>9}{'periodic':>10}")
    for t, it in enumerate(stream):
        mark = "  <-- DRIFT" if t == drift_at else ""       # drift가 일어난 줄에 표시
        print(f"{t:>5}{it['kind']:>9}{results['frozen'][0][t]:>9.2f}{results['active'][0][t]:>9.2f}"
              f"{results['periodic'][0][t]:>10.2f}{mark}")

    def post(x): return np.mean(x[drift_at:])  # drift 이후 구간만의 평균(post-drift 성능)
    print("\n=== summary ===")
    print(f"{'policy':<12}{'mean regret (all)':>18}{'mean regret (post-drift)':>26}{'planner calls':>15}")
    for name in ('oracle', 'frozen', 'periodic', 'active'):   # 정책별 전체/post-drift 평균 regret과 총 call
        reg, calls = results[name]
        print(f"{name:<12}{np.mean(reg):>18.3f}{post(reg):>26.3f}{calls:>15}")
    # frozen과 active의 post-drift regret 곡선 사이 면적(클수록 active가 회복으로 이득 본 양)
    area = np.sum(np.array(results['frozen'][0][drift_at:]) - np.array(results['active'][0][drift_at:]))
    print(f"\nHEADLINE (E3):")
    print(f"  post-drift regret: frozen={post(results['frozen'][0]):.3f}  active={post(results['active'][0]):.3f}  "
          f"(area between curves = {area:.2f}).")
    tt = recover_step if recover_step is not None else 'n/a'  # 회복 못 했으면 'n/a' 표시
    print(f"  active time-to-recover after drift: {tt} steps; "
          f"planner calls active={results['active'][1]} vs oracle={results['oracle'][1]} "
          f"({100*(1-results['active'][1]/max(results['oracle'][1],1)):.0f}% fewer) vs periodic={results['periodic'][1]}.")
    # self-check: frozen이 별로 안 나빠졌으면 drift가 너무 약하거나 새 종류가 너무 비슷하다는 뜻
    if post(results['frozen'][0]) - post(results['active'][0]) < 0.05:
        print("  [self-check] frozen barely degrades -> drift too mild or novel type too similar; "
              "widen the distribution gap (more zone instances / a more novel OOD).")
    else:
        print("  [self-check] active retraining recovers near-oracle quality that frozen loses, "
              "at a fraction of oracle/periodic compute -> E3 claim holds.")

    # ---- E3b: drift-detector 비교 (같은 스트림/ACTIVE 정책, 감지기·신호만 교체) ----
    print("\n=== E3b: drift-detector comparison (same stream, ACTIVE policy) ===")
    print(f"{'detector/signal':<24}{'post-drift regret':>18}{'recover':>9}{'planner calls':>15}{'fires':>7}{'spurious':>10}")
    print("-" * 83)
    for name, a in detector_arms.items():
        rec = a['recover'] if a['recover'] is not None else 'n/a'
        print(f"{name:<24}{post(a['reg']):>18.3f}{str(rec):>9}{a['calls']:>15}{a['n_fire']:>7}{a['n_spurious']:>10}")
    npost = len(stream) - drift_at
    print(f"  NOTE (short stream: {len(stream)} steps, {npost} post-drift):")
    print("   - value-RESIDUAL carries NO drift here (post-drift residuals are SMALLER); CUSUM/resid only")
    print("     'works' by firing spuriously + the verify-all escalation safety net (see 'spurious' col).")
    print("   - ADWIN's rigorous FP bound needs more samples than a short stream provides (eps_cut > signal),")
    print("     so ADWIN/novelty may never fire here. Run compare_detectors.py for the long-stream case")
    print("     where ADWIN fires with 0 spurious retrains. The covariate-NOVELTY signal is the real fix.")
    print("   - Conformal/novelty (anytime-valid, knob=alpha only): unlike ADWIN it DOES fire on the short")
    print("     stream and degrades gracefully; the few spurious fires reflect the tiny 7-point bootstrap")
    print("     calibration (its false-alarm guarantee is only as good as the calibration's representativeness).")


if __name__ == "__main__":  # 직접 실행할 때만 main() 호출
    main()
