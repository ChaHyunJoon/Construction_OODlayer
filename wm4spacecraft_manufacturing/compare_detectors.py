#!/usr/bin/env python
"""
compare_detectors.py -- CUSUM vs ADWIN, residual vs covariate-novelty 신호, 짧은/긴 스트림 정밀 비교.

E3/E4의 ACTIVE 재학습 정책을 그대로 쓰되, 감지기(CUSUM/ADWIN)와 drift 신호(residual/novelty)를
전부 조합해 다음 지표로 비교한다:
  · post-drift regret (drift 이후 평균 regret; 낮을수록 회복 잘함)
  · recover (drift 이후 처음 regret<=0.02 된 상대 스텝; 회복 속도)
  · planner calls (진짜 planner 호출 수 = 비용, 각 ~70s)
  · fires / spurious (총 발화 / drift 이전 오발화)
  · delay (첫 진짜 발화 - drift_at; 감지 지연)

핵심 관찰(요약):
  1) value-RESIDUAL은 이 과제의 drift 신호가 아니다(drift 이후 잔차가 오히려 작다) -> CUSUM은 spurious 남발,
     ADWIN은 발화 실패. covariate-NOVELTY로 바꾸면 둘 다 정상.
  2) ADWIN의 엄밀한 FP 보장은 표본 최소치가 필요 -> 짧은 스트림(25스텝)에선 아예 발화 불가.
     긴 스트림에선 ADWIN이 0 spurious로 발화(단 CUSUM보다 감지가 느림 = FP보장의 대가).

Usage:  python compare_detectors.py <dataset.jsonl> [--long-len 120] [--seeds 5]
"""
import sys, os, math, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e1_analyze import load, instance_admissible, featurize, lex_key
from surrogate_model import build_model   # 평가·배포 단일 모델 정의
from drift_detectors import CusumDetector, AdwinDetector, ConformalMartingaleDetector, make_novelty


def load_pools(path):
    """데이터셋을 로드해 bootstrap / phaseA(fault) / phaseB(zone) instance 풀로 나눈다(E3와 동일 구성)."""
    df = load(path); df = df[df.fired == True].copy()
    adm = [i for i in df.instance.unique() if instance_admissible(df[df.instance == i])]
    df = df[df.instance.isin(adm)].reset_index(drop=True)
    F = featurize(df); cols = list(F.columns); Xall = F.values
    ridx = {(r.instance, int(r.macro)): i for i, r in enumerate(df.itertuples(index=False))}
    state_idx = [i for i, c in enumerate(cols) if not c.startswith("macro_")]

    def inst(iid):
        g = df[df.instance == iid]; ms = [int(m) for m in g.macro]
        cl = {int(m): float(c) for m, c in zip(g.macro, g.closed)}
        cp = {int(m): bool(c) for m, c in zip(g.macro, g.complete)}
        mk = {int(m): (float(v) if not isinstance(v, str) else math.inf) for m, v in zip(g.macro, g.makespan)}
        best = max(ms, key=lambda m: lex_key(cp[m], cl[m], mk[m]))
        span = max(cl[best] - min(cl.values()), 1e-9)
        return dict(iid=iid, macros=ms, cl=cl, cp=cp, mk=mk, best=best, span=span, kind=g.kind.iloc[0])

    faults = [inst(i) for i in adm if df[df.instance == i].kind.iloc[0] == "fault"]
    zones = [inst(i) for i in adm if df[df.instance == i].kind.iloc[0] in ("zoneblk", "zone")]
    rng = np.random.default_rng(0); rng.shuffle(faults); rng.shuffle(zones)
    boot = faults[:max(3, len(faults) // 3)]
    return dict(Xall=Xall, ridx=ridx, state_idx=state_idx, boot=boot,
                poolA=faults[len(boot):], poolB=zones)


def make_env(P):
    """공용 헬퍼들(fit, state_vec, novelty, predict) 묶음을 만든다."""
    Xall, ridx, sidx, boot = P['Xall'], P['ridx'], P['state_idx'], P['boot']
    def fit(m, insts):
        rows = [ridx[(it['iid'], mm)] for it in insts for mm in it['macros']]
        ys = [it['cl'][mm] for it in insts for mm in it['macros']]
        m.fit(Xall[rows], np.array(ys))
    def state_vec(it):
        return Xall[ridx[(it['iid'], it['macros'][0])]][sidx]
    novelty = make_novelty([state_vec(it) for it in boot])
    def preds_of(m, it):
        return {mm: float(m.predict(Xall[ridx[(it['iid'], mm)]].reshape(1, -1))[0]) for mm in it['macros']}
    return fit, state_vec, novelty, preds_of


def run_active(P, stream, drift_at, make_detector, signal_kind):
    """ACTIVE 재학습 정책을 한 번 돌려 지표 dict을 반환(E3/E4의 D 셀과 동일 로직)."""
    fit, state_vec, novelty, preds_of = make_env(P)
    m = build_model(); fit(m, P['boot']); buf = list(P['boot'])
    reg = []; calls = 0; escalate = 0; cooldown = 0; recover = None
    n_fire = 0; n_spurious = 0; first_true = None
    det = make_detector()
    for t, it in enumerate(stream):
        preds = preds_of(m, it)
        order = sorted(it['macros'], key=lambda mm: preds[mm], reverse=True)
        k = len(it['macros']) if escalate > 0 else 1
        verified = order[:k]; calls += len(verified)
        pick = max(verified, key=lambda mm: lex_key(it['cp'][mm], it['cl'][mm], it['mk'][mm]))
        reg.append((it['cl'][it['best']] - it['cl'][pick]) / it['span'])
        resid = abs(preds[order[0]] - it['cl'][order[0]])
        if escalate > 0:
            buf.append(it)
        sig = resid if signal_kind == "resid" else novelty(state_vec(it))
        drift = det.update(sig) and cooldown == 0
        if drift:
            n_fire += 1
            if t < drift_at:
                n_spurious += 1
            elif first_true is None:
                first_true = t
            escalate = 3; cooldown = 3
        if escalate > 0:
            escalate -= 1
            if escalate == 0:
                fit(m, buf); det.reset()
        if cooldown > 0:
            cooldown -= 1
        if t >= drift_at and recover is None and reg[-1] <= 0.02 and t > drift_at:
            recover = t - drift_at
    post = float(np.mean(reg[drift_at:]))
    delay = (first_true - drift_at) if first_true is not None else None
    return dict(post=post, recover=recover, calls=calls, fires=n_fire, spurious=n_spurious, delay=delay)


def fmt(row):
    rec = row['recover'] if row['recover'] is not None else 'n/a'
    dly = row['delay'] if row['delay'] is not None else 'never'
    return f"{row['post']:>10.3f}{str(rec):>9}{row['calls']:>9}{row['fires']:>7}{row['spurious']:>10}{str(dly):>8}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--long-len", type=int, default=120, help="긴 스트림 총 길이(절반이 phase A, 절반 phase B)")
    ap.add_argument("--seeds", type=int, default=5, help="긴 스트림 리샘플 평균에 쓸 시드 개수")
    a = ap.parse_args()
    P = load_pools(a.data)
    # conformal calibration = bootstrap novelty(in-distribution). detector factory를 여기서 구성(cal_scores 필요).
    _fit, _sv, _nov, _pp = make_env(P)
    cal_scores = [_nov(_sv(it)) for it in P['boot']]
    def make_det(det, sig):
        if det == "CUSUM":
            return (lambda: CusumDetector()) if sig == "resid" else (lambda: CusumDetector(slack=1.5, thresh=6.0))
        if det == "ADWIN":
            return lambda: AdwinDetector(delta=0.05, grace_period=5, min_window_length=5)
        if det == "Conformal":
            return lambda: ConformalMartingaleDetector(cal_scores, alpha=0.05)
        raise ValueError(det)

    combos = [("CUSUM", "resid"), ("CUSUM", "novelty"), ("ADWIN", "novelty"), ("Conformal", "novelty")]
    hdr = f"{'detector/signal':<20}{'post-reg':>10}{'recover':>9}{'calls':>9}{'fires':>7}{'spurious':>10}{'delay':>8}"

    # ---------- SHORT stream (실제 E3 스트림: phaseA 전부 + phaseB 전부) ----------
    shortA, shortB = P['poolA'], P['poolB']
    stream = shortA + shortB; drift_at = len(shortA)
    print(f"\n################  SHORT stream (real E3): {len(stream)} steps, drift_at={drift_at} "
          f"({len(shortB)} post-drift)  ################")
    print(hdr); print("-" * len(hdr))
    for det, sig in combos:
        row = run_active(P, stream, drift_at, make_det(det, sig), sig)
        print(f"{det+'/'+sig:<20}" + fmt(row))

    # ---------- LONG stream (리샘플, 시드 평균) ----------
    L = a.long_len; half = L // 2
    print(f"\n################  LONG stream (resampled): {L} steps, drift_at={half}, "
          f"avg over {a.seeds} seeds  ################")
    print(hdr); print("-" * len(hdr))
    for det, sig in combos:
        acc = []
        for s in range(1, a.seeds + 1):
            srng = np.random.default_rng(s)
            sa = [P['poolA'][srng.integers(len(P['poolA']))] for _ in range(half)]
            sb = [P['poolB'][srng.integers(len(P['poolB']))] for _ in range(L - half)]
            acc.append(run_active(P, sa + sb, half, make_det(det, sig), sig))
        mean = {kk: (np.mean([r[kk] for r in acc if r[kk] is not None]) if any(r[kk] is not None for r in acc) else None)
                for kk in ('post', 'recover', 'calls', 'fires', 'spurious', 'delay')}
        # recover/delay는 None(미발생)이 섞일 수 있어 평균에서 None 제외; 전부 None이면 n/a
        row = {kk: (None if mean[kk] is None else (mean[kk])) for kk in mean}
        print(f"{det+'/'+sig:<20}" + fmt(row))

    print("\nREADING THE TABLE:")
    print("  - SHORT: CUSUM/resid (legacy) 'works' only via spurious fires + verify-all escalation;")
    print("    ADWIN can't fire at all (too few samples for its rigorous false-positive bound).")
    print("  - LONG: with the covariate-NOVELTY signal, ADWIN fires with ~0 spurious retrains and a")
    print("    controlled false-alarm rate; CUSUM detects faster but keeps a spurious-fire tail on resid.")
    print("  - Bottom line: the SIGNAL (residual -> covariate novelty) matters more than the detector;")
    print("    given the right signal, ADWIN buys guaranteed low false-alarms at the cost of some delay.")


if __name__ == "__main__":
    main()
