#!/usr/bin/env python
"""
descriptor_ablation.py -- "숫자 6개를 어떻게 정의해야 하는가"를 실측으로 답한다.

배경 (왜 이 파일이 생겼나)
==========================
사건을 요약하는 숫자 6개(features_agnostic.py)가 로봇 한 대가 죽은 사건을 이렇게 표현한다:

    harm = 0.95   work_at_risk = 0.016   resource_loss = 0.043

로봇이 죽었는데 "위태로운 일 1.6%, 자원 손실 4.3%" = 별일 아님으로 읽힌다. 분모가
"남은 작업 255개", "일하는 로봇 22대"라서 그렇다. 실제로는 그 로봇이 멈추면 빌드가 멈춘다.
LLM 에게 이 숫자를 주자 배터리 사건 18개 전부에서 교체(Replace) 대신 방치(NOOP)를 골랐다.

그래서 나온 질문: **work_at_risk 와 resource_loss 를 굳이 정의해야 하나?
harm / recovery_capacity / progress / slack 4개로 충분하지 않나?**

이 파일이 그 질문에 숫자로 답한다.

먼저 알아야 할 함정: harm 은 fault 사건에서 **정답표를 읽고 있다**
=================================================================
harm 은 (배터리도 구역도 아닌) 고장 사건에서 `severity` 를 그대로 쓴다. 그런데 그 severity 는

    gen_oracle_dataset.jl :  (:fault, 1.0, ...)   <- 유해한 고장
                             (:faultidle, 0.0, ...) <- 무해한 고장
    policy.jl (실제 배포) :  d["severity"] = 1.0    <- 모든 고장에 무조건 1.0

즉 **학습 데이터에서는 실험자가 손으로 붙인 정답**이고, **실전에서는 항상 1.0인 상수**다.
harm 만 남기고 work_at_risk 를 지우면, 유해한 고장과 무해한 고장을 가르는 유일한 근거가
"실전에는 존재하지 않는 정답표"가 된다. 그래서 이 파일은 두 조건에서 잰다:

    as-recorded  : 덤프에 적힌 severity 그대로 (정답표가 살아 있음 = 낙관적)
    deployment   : 고장 사건의 severity 를 전부 1.0 으로 (실전과 동일 = 정직)

비교하는 정의들
===============
    A current-6   지금 그대로
    B user-4      harm / recovery_capacity / progress / slack  (work_at_risk·resource_loss 제거)
    C fixed-5     분모를 고친 work_at_risk 를 살리고 resource_loss 는 뺌  <- 이 파일의 제안
    D fixed-6     C + 능력손실(자원손실을 함대 비율이 아니라 그 로봇이 잃은 능력으로)

C 의 재정의:
    harm         고장이면 1.0 (severity 를 읽지 않는다 = 정답표 차단),
                 배터리면 1-soc, 구역이면 겹침비율
    work_at_risk 그 로봇이 쥔 미완작업 / **로봇 한 대 평균 몫**
                 = agent_pending * n_active / 남은작업          (기존은 /남은작업 뿐)
                 예) 4 * 22 / 255 = 0.35   (기존 0.016)
                 뜻: "평균적인 로봇 한 대 몫에 비해 얼마나 많은 일을 쥐고 있나". 1 이면 평균 몫 전부.

채점: 지금까지 쓰던 것과 동일(verify.norm_regret, cost-aware lambda=3, valid mask 게이팅).
      LOIO = 한 상황 빼고 학습 / LOKO = 한 종류 통째로 빼고 학습.

실행:  python descriptor_ablation.py [데이터.jsonl]
"""
import math
import sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import pandas as pd
from sklearn.model_selection import LeaveOneGroupOut

import wm_datasets                      # 데이터셋 경로 단일 정의
from features_agnostic import MACROS, _f
from openworld_experiments import load_df, pick_with_gate, valid_macros_of
from surrogate_model import build_model
from verify import norm_regret, oracle_best_macro, paired_bootstrap

FLEET_REF = 30.0


# ==========================================================================================
#  서술자 계산 (정의를 갈아끼울 수 있게 옵션화)
# ==========================================================================================
def descriptors(row, fixed=False, deployment=False):
    """한 행 -> 서술자 dict.

    fixed=False       기존 정의 그대로
    fixed=True        harm 이 severity 를 안 읽고, work_at_risk 분모를 '로봇 한 대 평균 몫'으로
    deployment=True   고장 사건의 severity 를 1.0 으로 강제(= 실전에서 보이는 값)
    """
    soc = _f(row.get("soc"))
    zov = _f(row.get("zone_overlap"), -1.0)
    apend = _f(row.get("agent_pending"), -1.0)
    sev = _f(row.get("severity"), 0.0)
    n_active = max(1.0, _f(row.get("n_active"), 1.0))
    spare = max(0.0, _f(row.get("spare_count"), 0.0))
    closed = _f(row.get("closed_at_fire"), 0.0)
    total = _f(row.get("total_nodes"), 0.0)
    progress = _f(row.get("progress"), 0.0)

    has_soc = math.isfinite(soc)
    is_spatial = math.isfinite(zov) and zov >= 0.0
    is_agent = math.isfinite(apend) and apend >= 0.0

    pending = total - closed
    if not math.isfinite(pending) or pending <= 0:
        pending = 1.0

    if deployment and not has_soc and not is_spatial:
        sev = 1.0                      # 실전: 모든 고장이 severity 1.0 으로 들어온다

    # ---- harm ---------------------------------------------------------------------------
    if has_soc:
        harm = 1.0 - soc
    elif is_spatial:
        harm = zov
    else:
        # 고장: 기존은 severity(=정답표)를 읽었다. fixed 는 "고장은 능력 100% 상실"로 고정.
        harm = 1.0 if fixed else sev
    harm = float(np.clip(harm, 0.0, 1.0))

    # ---- work_at_risk -------------------------------------------------------------------
    if is_agent:
        if fixed:
            # 분모를 '로봇 한 대 평균 몫'(pending/n_active)으로 바꾼다.
            per_robot = max(1e-9, pending / n_active)
            war = apend / per_robot
        else:
            war = apend / pending
    elif is_spatial:
        war = zov
    else:
        war = 0.0
    work_at_risk = float(np.clip(war, 0.0, 1.0))

    # ---- resource_loss ------------------------------------------------------------------
    if is_agent:
        cap_left = soc if has_soc else 0.0
        lost = 1.0 - float(np.clip(cap_left, 0.0, 1.0))
        # 기존은 함대 크기로 또 나눈다(-> 죽은 로봇이 4%로 보이는 원인).
        resource_loss = lost if fixed else lost / n_active
    else:
        resource_loss = 0.0
    resource_loss = float(np.clip(resource_loss, 0.0, 1.0))

    return {"harm": harm, "work_at_risk": work_at_risk, "resource_loss": resource_loss,
            "recovery_capacity": float(spare / max(1.0, spare + n_active)),
            "progress": float(np.clip(progress, 0.0, 1.0)),
            "slack": float(np.clip(n_active / FLEET_REF, 0.0, 1.0))}


SETS = {
    "A current-6": (["harm", "work_at_risk", "resource_loss",
                     "recovery_capacity", "progress", "slack"], dict(fixed=False)),
    "B user-4":    (["harm", "recovery_capacity", "progress", "slack"], dict(fixed=False)),
    "C fixed-5":   (["harm", "work_at_risk",
                     "recovery_capacity", "progress", "slack"], dict(fixed=True)),
    "D fixed-6":   (["harm", "work_at_risk", "resource_loss",
                     "recovery_capacity", "progress", "slack"], dict(fixed=True)),
}


def build_X(df, cols, opts, deployment):
    rows = [descriptors(df.iloc[i], deployment=deployment, **opts) for i in range(len(df))]
    X = pd.DataFrame(index=df.index)
    for c in cols:
        X[c] = [r[c] for r in rows]
    for m in MACROS:
        X[f"macro_{m}"] = (df.macro.astype(int) == m).astype(float).values
    from e1_analyze import _valid_list
    vmask = df.get("valid_mask", pd.Series([[]] * len(df), index=df.index))
    X["macro_in_valid"] = [1.0 if int(m) in _valid_list(v) else 0.0
                           for m, v in zip(df.macro, vmask)]
    return X


# ==========================================================================================
def loio(df, X, lam):
    y, groups = df.closed.astype(float).values, df.instance.values
    by_inst = {i: g for i, g in df.groupby("instance")}
    regs = []
    for tr, te in LeaveOneGroupOut().split(X.values, y, groups):
        g = by_inst[groups[te][0]]
        model = build_model().fit(X.values[tr], y[tr])
        pred = model.predict(X.values[te])
        pbm = {int(m): float(p) for m, p in zip(df.iloc[te].macro.astype(int).values, pred)}
        regs.append(norm_regret(g, pick_with_gate(pbm, valid_macros_of(g)), lam))
    return [float(r) for r in regs]


def loko(df, X, lam):
    by_inst = {i: g for i, g in df.groupby("instance")}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    out, per_kind = [], {}
    for held in sorted(set(kind_of.values())):
        te = [i for i in by_inst if kind_of[i] == held]
        tr_rows = df[df.instance.isin([i for i in by_inst if kind_of[i] != held])]
        model = build_model().fit(X.loc[tr_rows.index].values,
                                  tr_rows.closed.astype(float).values)
        rs = []
        for i in te:
            g = by_inst[i]
            pred = model.predict(X.loc[g.index].values)
            pbm = {int(m): float(p) for m, p in zip(g.macro.astype(int).values, pred)}
            rs.append(norm_regret(g, pick_with_gate(pbm, valid_macros_of(g)), lam))
        per_kind[held] = float(np.mean(rs))
        out += [float(r) for r in rs]
    return out, per_kind


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = wm_datasets.resolve(args[0] if args else None)   # 기본 = CANONICAL(openworld_merged)
    lam = 3.0
    df = load_df(path)
    kinds = sorted(df.kind.astype(str).unique())

    print("=" * 100)
    print("서술자 정의 비교:  work_at_risk / resource_loss 를 빼도 되는가")
    print("=" * 100)
    print(f"  data={path}  instances={df.instance.nunique()}  kinds={kinds}  lambda={lam}")
    print("  regret 0=매번 최선 / 1=매번 최악.  LOIO=한 상황 빼고 / LOKO=한 종류 통째로 빼고\n")

    # 예시 한 건: 정의를 바꾸면 죽은 로봇이 어떻게 보이는지
    r = df[df.kind.astype(str) == "battery"].iloc[0]
    a = descriptors(r, fixed=False)
    c = descriptors(r, fixed=True)
    print("  [예시] 배터리 5% = 사실상 죽은 로봇 하나")
    print(f"    기존 정의: work_at_risk={a['work_at_risk']:.3f}  resource_loss={a['resource_loss']:.3f}"
          "   <- '별일 아님'으로 보인다")
    print(f"    고친 정의: work_at_risk={c['work_at_risk']:.3f}  resource_loss={c['resource_loss']:.3f}"
          "   <- 심각도가 살아난다\n")

    results = {}
    for cond, deployment in (("as-recorded (정답표 살아있음)", False),
                             ("deployment (실전과 동일)", True)):
        print(f"  ── {cond} ──")
        print(f"    {'정의':<14} {'LOIO':>7} {'LOKO':>7}   " +
              "  ".join(f"{k:>9}" for k in kinds))
        for name, (cols, opts) in SETS.items():
            X = build_X(df, cols, opts, deployment)
            li = loio(df, X, lam)
            lk, per = loko(df, X, lam)
            results[(cond, name)] = (li, lk)
            print(f"    {name:<14} {np.mean(li):>7.3f} {np.mean(lk):>7.3f}   " +
                  "  ".join(f"{per.get(k, float('nan')):>9.3f}" for k in kinds))
        print()

    # LOKO 는 종류가 3개뿐이라 둔감하다(위 표에서 전부 0.100). 실제로 갈리는 것은 LOIO 이므로
    # 둘 다 검정한다. idx 0=LOIO, 1=LOKO.
    conds = ("as-recorded (정답표 살아있음)", "deployment (실전과 동일)")
    for idx, mname in ((0, "LOIO"), (1, "LOKO")):
        print(f"  ── 통계 비교 [{mname}] (짝지어 부트스트랩. 양수 = 뒤에 적힌 쪽이 더 좋음) ──")
        for cond in conds:
            print(f"    [{cond}]")
            base = results[(cond, "A current-6")][idx]
            for name in ("B user-4", "C fixed-5", "D fixed-6"):
                d, lo, hi = paired_bootstrap(base, results[(cond, name)][idx])
                tag = "더 좋음" if lo > 0 else ("더 나쁨" if hi < 0 else "차이 못 밝힘")
                print(f"      A current-6 vs {name:<12} 차이={d:+.3f} CI[{lo:+.3f},{hi:+.3f}] -> {tag}")
            d, lo, hi = paired_bootstrap(results[(cond, "B user-4")][idx],
                                         results[(cond, "C fixed-5")][idx])
            tag = "C 가 더 좋음" if lo > 0 else ("B 가 더 좋음" if hi < 0 else "차이 못 밝힘")
            print(f"      B user-4    vs C fixed-5    차이={d:+.3f} CI[{lo:+.3f},{hi:+.3f}] -> {tag}")
        print()

    # 사용자 제안(B)이 '정답표'에 얼마나 기대고 있었는지: 같은 정의로 조건만 바꿔 본다.
    print("  ── 각 정의가 '정답표(severity)'에 얼마나 기대는가 [LOIO] ──")
    print("     (실전 조건에서 나빠질수록, 그 정의는 학습 때만 있는 정답에 기대고 있었다는 뜻)")
    for name in SETS:
        a = results[(conds[0], name)][0]
        b = results[(conds[1], name)][0]
        d, lo, hi = paired_bootstrap(b, a)   # 양수 = as-recorded 가 더 좋음 = 실전에서 나빠짐
        tag = "정답표에 기댐(실전에서 나빠짐)" if lo > 0 else (
              "실전에서 오히려 좋아짐" if hi < 0 else "차이 못 밝힘")
        print(f"      {name:<14} {np.mean(a):.3f} -> {np.mean(b):.3f}   차이={d:+.3f} "
              f"CI[{lo:+.3f},{hi:+.3f}] -> {tag}")


if __name__ == "__main__":
    main()
