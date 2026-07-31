#!/usr/bin/env python
"""
assimilation_stream.py -- CLAIMS C3 + C4: the router, and the loop that makes the LLM unnecessary.

THE CLAIM, AS A PICTURE
=======================
    stream:  [fault, zoneblk, fault, zoneblk, ...  |  BATTERY appears for the first time, then repeats]
                        surrogate knows these      ^  novel kind onset
    wanted:
        LLM call rate  ████▇▅▃▂▁▁▁▁      first the LLM, then it hands over to the surrogate
        cum. regret    ─────────────      and quality does not degrade while that happens

Two claims live in that picture, and neither is testable by a static leave-one-out table:

    C3  the system decides FOR ITSELF whether an incoming event is familiar, and routes it.
        Tested by: does the gate beat a random router spending the SAME number of LLM calls?
    C4  what the LLM handled becomes surrogate training data, so the same kind is cheap next time.
        Tested by: does the LLM call rate DECAY after onset -- and does it stop decaying when the
        assimilation step is switched off (`no_assim`)?

SIX POLICIES ON THE IDENTICAL STREAM
    oracle          verify all 5 macros every event. regret 0, maximal compute. quality ceiling.
    frozen          surrogate only, bootstrapped once, never retrained. the do-nothing floor;
                    this is what "always-surrogate" costs you when a new kind arrives.
    always_llm      LLM every event. quality reference at the cost ceiling.
    gated+assim     OURS. gate -> unfamiliar goes to the LLM, then the event is oracle-labelled,
                    added to the pool, and the surrogate is refitted. familiar goes to the surrogate.
    gated_no_assim  same gate, same LLM, but NEVER retrain.  <- the control that isolates C4.
                    If its call rate also decays, the decay was not caused by learning.
    random_router   routes to the LLM at the SAME rate the gate chose, but at random, with
                    assimilation.                              <- the control that isolates C3.
                    If it does as well, the gate carries no information and C3 is not established.

WHICH GATE SIGNAL -- a measured result, not a preference (default `--gate=novelty`)
    Detecting "this is a KIND I have never seen" is NOT the same job as "my top-2 are close, verify
    me". Measured on this harness with novel=zoneblk:

        gate=disagreement   recall on the novel kind = 0.00   (the forest is CONFIDENTLY wrong:
                                                               every tree lacks the feature region,
                                                               so they all agree -- on nonsense)
        gate=novelty        recall on the novel kind = 0.94, precision 0.75

    So ensemble disagreement, which won the earlier fixed-budget "when to call the planner" study,
    is the WRONG signal here. Covariate novelty measures distance from the training input
    distribution, which is what "new kind" actually means. Both remain selectable.

    Corollary that cost the first implementation its C4 result: the novelty calibrator MUST be
    refetted when the pool grows (`refresh_gate`). Without it the gate kept flagging the kind at
    0.94 forever even after learning it -- the system had no way to say "this is familiar now".

WHY THE LLM IS PRECOMPUTED
    temperature=0 and the on-disk cache make the LLM a deterministic function of the event, so its
    choice per instance is computed ONCE (<= one call per instance) and looked up by all six
    policies across all seeds. That is not a shortcut that changes the result -- it is the same
    number the online loop would get -- and it keeps a 6-policy x 8-seed sweep at ~60 API calls.

WHAT COUNTS AS COST (measured, not assumed)
    planner seconds : the dump's own `label_seconds` per rollout -- the real wall clock the true
                      planner took for that instance. An oracle label = 5 rollouts.
    LLM seconds     : measured from this run's completions (or the cache's recorded average).
    surrogate       : 0.11 ms (measured in cost_eval.py).

HONEST LIMITS -- read before quoting
    · The stream is a REPLAY over 60 oracle-labelled instances, not a live simulator run. Instances
      do not repeat within one stream, so "the surrogate learns this kind" means it generalises to
      OTHER instances of the same kind, which is the right test but a small-sample one.
    · The novel kind's onset is scripted. This measures the assimilation dynamics, not detection of
      a spontaneous drift (that is e3_drift.py's job).
    · If C1 (c1_novel_kind.py) does not hold, a working router is routing to a WORSE producer.
      Then C3/C4 numbers describe a mechanism that should not be deployed as-is. Run C1 first.

USAGE
    python assimilation_stream.py                                   # novel=battery, 8 seeds
    python assimilation_stream.py --novel=zoneblk --seeds=12 --arm=nl+state
    python assimilation_stream.py --gate=novelty --target-rate=0.2
    LLM_MOCK=1 python assimilation_stream.py                        # 배선 점검(수치 인용 금지)
    python assimilation_stream.py --plot=artifacts_assimilation/curve.png

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 설명]
이 스크립트가 재는 것 = 명제 C3(라우팅)과 C4(동화).

  C3: 들어온 사건이 "처음 보는 것"인지 시스템이 스스로 판별해 LLM/surrogate 로 나눠 보내는가.
      -> 같은 횟수만 LLM 을 쓰는 **무작위 라우터**를 이겨야 게이트가 진짜 정보를 쓰는 것이다.
  C4: LLM 이 처리한 사건을 오라클로 라벨링해 학습풀에 넣고 재학습하면, 그 종류가 다음부터 싸지는가.
      -> 재학습을 끈 대조군(no_assim)에서 호출률이 안 떨어져야 "학습 덕분"이라고 말할 수 있다.

핵심 그림: 새 종류 등장 이후 LLM 호출률이 떨어지는 곡선 + 그동안 누적 regret 은 유지.
정책 6개를 같은 스트림 위에서 비교한다(oracle / frozen / always_llm / gated+assim /
gated_no_assim / random_router).

정직한 한계: 이 스트림은 60개 오라클 라벨을 재생(replay)하는 것이지 실시간 시뮬레이션이 아니다.
그리고 C1 이 안 서면, 잘 도는 라우터라도 "더 나쁜 쪽으로" 보내는 것이므로 배포 근거가 되지 않는다.

[문법 참고]
  - np.random.default_rng(seed).permutation(n) : 재현 가능한 무작위 순열.
  - dict comprehension {k: v for ...} / list comprehension [x for ...]
  - collections.deque(maxlen=w) : 최근 w 개만 유지하는 큐(이동 평균용).
  - float("nan") 은 비교가 항상 False -> 판정에 쓰기 전 math.isnan 으로 확인.
────────────────────────────────────────────────────────────────────────────────────────────
"""
import collections
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

import wm_datasets                      # 데이터셋 경로 단일 정의
from features_agnostic import (STATE_DESCRIPTORS, descriptors_from_row,
                               featurize_agnostic)
from llm_producer import Producer
from nl_events import provenance_summary
from openworld_experiments import (conformal_p, fit_novelty, load_df,
                                   novelty_of, pick_with_gate, valid_macros_of)
from surrogate_model import build_model
from verify import norm_regret, oracle_best_macro, paired_bootstrap

SURROGATE_SECONDS = 0.11e-3          # cost_eval.py 에서 측정된 forest 1회 평가 시간
POLICIES = ["oracle", "frozen", "always_llm", "gated+assim", "gated_no_assim",
            "random_router", "gated_oracle"]

# ------------------------------------------------------------------------------------------
#  비용은 두 축으로 나눠 센다 -- 이걸 합치면 제안 자체가 말이 안 되게 보인다
# ------------------------------------------------------------------------------------------
#  decision_seconds   : 로봇을 세워둔 채 답을 기다리는 시간 = **임계 경로**.
#                       surrogate 0.11 ms / LLM 약 1.5 s / 오라클 5 rollout 약 400 s.
#  background_seconds : 결정을 내린 **뒤에** 오프라인으로 정답 라벨을 만드는 시간.
#                       빌드는 이미 진행 중이므로 아무도 기다리지 않는다.
#
#  왜 중요한가: 처음 구현은 둘을 더해서 "gated+assim = 211 초/사건" 으로 찍었다. 그 숫자대로면
#  라벨링을 하는 순간 정답을 이미 아는 셈이라 LLM 에게 물어볼 이유가 사라진다 -- 제안이 자기모순이
#  된다. 설계 의도는 "결정은 LLM 이 즉시, 라벨은 나중에 배치로" 이므로 축을 나눠야 옳다.
#  임계 경로에서 오라클을 부르는 대안(`gated_oracle`)을 함께 돌려서, 그 대안이 치르는 대기시간을
#  같은 표에서 볼 수 있게 한다.


# ==========================================================================================
#  surrogate 를 감싼 작은 어댑터: 학습풀을 받아 fit 하고, 한 instance 의 결정과 확신도를 낸다
# ==========================================================================================
class Surrogate:
    def __init__(self, df, Xall, cols, lam):
        self.df, self.X, self.cols, self.lam = df, Xall, cols, lam
        self.by_inst = {i: g for i, g in df.groupby("instance")}
        self.model = None
        self.n_fits = 0

    def fit(self, pool):
        rows = self.df[self.df.instance.isin(pool)]
        self.model = build_model().fit(self.X.loc[rows.index, self.cols].values,
                                       rows.closed.astype(float).values)
        self.n_fits += 1
        return self

    def decide(self, inst):
        """(고른 macro, 나무들의 합의율). 합의율이 낮다 = 모델 스스로 확신이 없다."""
        g = self.by_inst[inst]
        Xg = self.X.loc[g.index, self.cols].values
        mg = g.macro.astype(int).values
        valid = valid_macros_of(g)
        pred = self.model.predict(Xg)
        pbm = {int(m): float(p) for m, p in zip(mg, pred)}
        pick = pick_with_gate(pbm, valid)

        votes = collections.Counter()
        for est in self.model.estimators_:                 # 개별 결정트리마다 "네 답은?" 을 물어본다
            pe = est.predict(Xg)
            cand = {int(m): float(v) for m, v in zip(mg, pe) if int(m) in valid}
            if cand:
                votes[max(cand, key=cand.get)] += 1
        agree = votes.most_common(1)[0][1] / sum(votes.values()) if votes else 1.0
        return pick, float(agree)


# ==========================================================================================
#  게이트 신호
# ==========================================================================================
def calibrate_gate(sur, pool, kind_of, target_rate, mode, df):
    """알람 임계값을 **아는 종류 데이터에서** 정한다 = "정상 상황에서 오경보율이 target_rate 가 되게".

    합의율(agreement)은 학습에 쓴 instance 에서 재면 항상 높게 나오므로(과대평가), pool 안에서
    leave-one-instance-out 으로 다시 맞춰 재는 값으로 임계값을 잡는다. pool 이 작을 때만 감당 가능한
    방식이라 부트스트랩 시점에 한 번만 한다(배포에서도 알람 임계는 보통 한 번 정하고 고정한다).
    """
    if mode == "novelty":
        D = np.asarray([[descriptors_from_row(sur.by_inst[i].iloc[0])[k] for k in STATE_DESCRIPTORS]
                        for i in pool], float)
        mu, sd, cal = fit_novelty(D)
        return {"mode": "novelty", "mu": mu, "sd": sd, "cal": cal, "thr": target_rate}

    scores = []
    for held in pool:
        rest = [i for i in pool if i != held]
        if len(rest) < 2:
            continue
        s = Surrogate(sur.df, sur.X, sur.cols, sur.lam).fit(rest)
        scores.append(s.decide(held)[1])
    thr = float(np.quantile(scores, target_rate)) if scores else 0.6
    return {"mode": "disagreement", "thr": thr, "loo_scores": scores}


def refresh_gate(gate, sur, pool):
    """동화가 일어난 뒤 게이트를 갱신한다. **C4 가 성립하려면 반드시 필요한 단계다.**

    처음 구현은 이걸 빼먹었고, 그 결과 novelty 게이트가 새 종류를 잘 잡아내고도(recall 0.94)
    호출률이 영원히 0.94 에 머물렀다 -- 학습풀에 그 종류가 들어와도 '낯섦' 기준이 부트스트랩 시점
    분포에 고정돼 있었기 때문. 즉 시스템이 "이제 이건 익숙하다"고 말할 방법이 없었다.

    disagreement 게이트는 모델 자체가 재학습되면서 점수가 따라 변하므로 임계값만 고정해 둔다
    (임계값까지 매번 다시 잡으려면 pool 크기만큼 재학습이 필요해 비용이 맞지 않는다).
    """
    if gate is None or gate["mode"] != "novelty":
        return gate
    D = np.asarray([[descriptors_from_row(sur.by_inst[i].iloc[0])[k] for k in STATE_DESCRIPTORS]
                    for i in pool], float)
    mu, sd, cal = fit_novelty(D)
    gate.update({"mu": mu, "sd": sd, "cal": cal})
    return gate


def gate_flags(gate, sur, inst):
    """이 사건이 '낯설다'고 판정되는가 -> True 면 LLM 으로 보낸다."""
    if gate["mode"] == "novelty":
        d = descriptors_from_row(sur.by_inst[inst].iloc[0])
        p = conformal_p(gate["cal"], novelty_of(gate["mu"], gate["sd"],
                                                [d[k] for k in STATE_DESCRIPTORS]))
        return p < gate["thr"], p
    _, agree = sur.decide(inst)
    return agree < gate["thr"], agree


# ==========================================================================================
#  스트림 구성
# ==========================================================================================
def build_stream(instances, kind_of, novel, n_bootstrap, warmup, rng):
    """(부트스트랩용 instance, 스트림) 을 만든다.

    부트스트랩 = 처음 surrogate 를 학습시키는 '아는 종류' 사건들(스트림에는 안 들어감).
    스트림 앞부분 warmup = 아는 종류만. 그 뒤부터 새 종류가 섞여 들어온다(onset).
    """
    known = [i for i in instances if kind_of[i] != novel]
    novel_inst = [i for i in instances if kind_of[i] == novel]
    known = [known[j] for j in rng.permutation(len(known))]
    novel_inst = [novel_inst[j] for j in rng.permutation(len(novel_inst))]

    boot, rest = known[:n_bootstrap], known[n_bootstrap:]
    pre, post_known = rest[:warmup], rest[warmup:]
    tail = post_known + novel_inst
    tail = [tail[j] for j in rng.permutation(len(tail))]
    return boot, pre + tail, len(pre)


# ==========================================================================================
#  한 정책을 한 스트림 위에서 돌린다
# ==========================================================================================
def run_policy(policy, df, Xall, cols, lam, boot, stream, kind_of, llm_pick, gate_cfg,
               rng, planner_seconds, llm_seconds, match_rate=None):
    """반환: 스텝별 기록 리스트. 각 원소 = 그 사건에서 무슨 일이 있었는지."""
    sur = Surrogate(df, Xall, cols, lam)
    by_inst = sur.by_inst
    pool = list(boot)
    if policy != "oracle":
        sur.fit(pool)
    gate = None
    if policy.startswith("gated"):
        gate = calibrate_gate(sur, pool, kind_of, gate_cfg["target_rate"], gate_cfg["mode"], df)

    recs = []
    for t, inst in enumerate(stream):
        g = by_inst[inst]
        to_llm, signal, planner_calls = False, float("nan"), 0
        blocking_planner = 0        # 임계 경로에서 부른 rollout 수(로봇이 기다린다)

        if policy == "oracle":
            pick, who = oracle_best_macro(g, lam), "oracle"
            planner_calls = blocking_planner = 5
        elif policy == "frozen":
            pick, signal = sur.decide(inst)
            who = "surrogate"
        elif policy == "always_llm":
            pick, who, to_llm = llm_pick[inst], "llm", True
        elif policy == "gated_oracle":
            # 대안: 낯설면 **그 자리에서** 진짜 플래너로 5개를 확인하고 그 답대로 한다(E3 의 ACTIVE).
            # 결정 품질은 그 사건에서 완벽하지만, 그 시간만큼 빌드가 멈춘다. LLM 이 사는 이유가
            # "임계 경로에서 플래너를 안 부르는 것" 이므로, 반드시 같은 표에 있어야 하는 경쟁자다.
            to_llm, signal = gate_flags(gate, sur, inst)
            if to_llm:
                pick, who = oracle_best_macro(g, lam), "oracle"
                planner_calls = blocking_planner = 5
                pool.append(inst)
                sur.fit(pool)
                gate = refresh_gate(gate, sur, pool)
            else:
                pick, _ = sur.decide(inst)
                who = "surrogate"
            to_llm = False           # LLM 은 안 썼다(호출수 집계에서 제외)
        else:
            if policy == "random_router":
                to_llm = bool(rng.random() < match_rate)
                signal = float("nan")
            else:
                to_llm, signal = gate_flags(gate, sur, inst)
            if to_llm:
                pick, who = llm_pick[inst], "llm"
            else:
                pick, _ = sur.decide(inst)
                who = "surrogate"

        # ---- 동화(assimilation): LLM 이 처리한 사건만 오라클로 라벨링해 학습풀에 넣고 재학습 ----
        # 왜 LLM 이 처리한 사건만인가: surrogate 가 자신있게 답한 사건까지 라벨링하면 그건 그냥
        # 오라클을 매번 부르는 것과 같아진다(비용 절감이 사라짐). 게이트가 고른 것만 값을 치른다.
        retrained = False
        if to_llm and policy in ("gated+assim", "random_router"):
            planner_calls += 5                    # 후보 5개를 전부 rollout = 이 사건의 정답 라벨
            pool.append(inst)
            sur.fit(pool)
            gate = refresh_gate(gate, sur, pool)   # "이제 이 종류는 익숙하다" 를 게이트에도 반영
            retrained = True

        ps = planner_seconds.get(inst, 0.0)
        recs.append({
            "t": t, "inst": inst, "kind": kind_of[inst], "who": who, "to_llm": bool(to_llm),
            "macro": int(pick), "regret": float(norm_regret(g, pick, lam)),
            "signal": float(signal) if signal == signal else None,
            "planner_calls": planner_calls, "retrained": retrained,
            # 임계 경로: 로봇이 실제로 답을 기다린 시간.
            "decision_seconds": (blocking_planner * ps
                                 + (llm_seconds if to_llm else 0.0)
                                 + (0.0 if who == "oracle" else SURROGATE_SECONDS)),
            # 오프라인: 결정을 내린 뒤 배치로 만드는 라벨. 아무도 기다리지 않는다.
            "background_seconds": (planner_calls - blocking_planner) * ps,
        })
    return recs


# ==========================================================================================
def sliding(xs, w):
    """이동 평균(창 w). 곡선을 눈으로 읽을 수 있게 만드는 용도."""
    out, buf = [], collections.deque(maxlen=w)
    for x in xs:
        buf.append(x)
        out.append(sum(buf) / len(buf))
    return out


def novel_ordinal_curve(runs, novel, n_ord):
    """**C4 의 핵심 곡선**: "이 종류의 k 번째 사건" 을 LLM 으로 보냈는가, k 에 대한 평균.

    왜 스트림 위치가 아니라 '그 종류의 몇 번째' 인가:
      스트림 위치로 그리면 새 종류가 섞여 들어오는 것만으로 호출률이 올라가서, 배움에 의한 감소와
      단순 등장빈도 변화가 뒤섞인다(처음 구현이 이 실수를 했고, 감소가 아니라 증가로 보였다).
      "이 종류의 k 번째 사건" 축으로 그리면 축 자체가 노출량이라, 곡선의 하강이 곧 학습의 효과다.
    """
    acc = [[] for _ in range(n_ord)]
    for r in runs:
        k = 0
        for x in r["recs"]:
            if x["kind"] != novel:
                continue
            if k < n_ord:
                acc[k].append(1.0 if x["to_llm"] else 0.0)
            k += 1
    return [float(np.mean(a)) if a else float("nan") for a in acc]


def run_one_novel(cfg, df, Xall, cols, by_inst, kind_of, instances, planner_seconds,
                  llm_pick, llm_regret, llm_seconds, novel):
    """새 종류 하나를 골라 스트림 실험을 끝까지 돌리고, 표/판정을 찍고 결과 dict 를 돌려준다."""
    lam, n_seeds = cfg["lam"], cfg["seeds"]
    n_boot, warmup, window = cfg["bootstrap"], cfg["warmup"], cfg["window"]
    gate_cfg = {"mode": cfg["gate"], "target_rate": cfg["target_rate"]}

    n_novel = sum(1 for i in instances if kind_of[i] == novel)
    print("\n" + "=" * 100)
    print(f"NOVEL KIND = {novel}   ({n_novel} instances; 나머지 종류로만 부트스트랩)")
    print("=" * 100)

    per_policy = {p: [] for p in POLICIES}
    onsets = []
    for s in range(n_seeds):
        rng = np.random.default_rng(1000 + s)
        boot, stream, onset = build_stream(instances, kind_of, novel, n_boot, warmup, rng)
        onsets.append(onset)
        # 무작위 라우터의 예산을 게이트의 실현 호출수에 맞춘다(같은 예산이라야 '신호'를 잰 것이 된다).
        ours = run_policy("gated+assim", df, Xall, cols, lam, boot, stream, kind_of, llm_pick,
                          gate_cfg, np.random.default_rng(2000 + s), planner_seconds, llm_seconds)
        match_rate = sum(r["to_llm"] for r in ours) / max(1, len(ours))
        for p in POLICIES:
            recs = ours if p == "gated+assim" else run_policy(
                p, df, Xall, cols, lam, boot, stream, kind_of, llm_pick, gate_cfg,
                np.random.default_rng(2000 + s), planner_seconds, llm_seconds,
                match_rate=match_rate)
            per_policy[p].append({"seed": s, "onset": onset, "recs": recs})

    onset = int(round(float(np.mean(onsets))))
    n_steps = min(len(r["recs"]) for p in POLICIES for r in per_policy[p])

    # ---- 요약표 --------------------------------------------------------------------------
    def agg(p, f):
        return float(np.mean([f(r["recs"]) for r in per_policy[p]]))

    print(f"  {'policy':<16} {'regret':>8} {'regret(novel)':>14} {'LLM호출':>8} {'플래너':>7} "
          f"{'대기초/사건':>12} {'배치초/사건':>12}")
    print("  " + "-" * 84)
    summary = {}
    for p in POLICIES:
        summary[p] = {
            "regret": agg(p, lambda R: np.mean([x["regret"] for x in R])),
            "regret_novel": agg(p, lambda R: np.mean([x["regret"] for x in R
                                                      if x["kind"] == novel] or [0.0])),
            "llm_calls": agg(p, lambda R: sum(x["to_llm"] for x in R)),
            "planner_calls": agg(p, lambda R: sum(x["planner_calls"] for x in R)),
            "decision_seconds": agg(p, lambda R: np.mean([x["decision_seconds"] for x in R])),
            "background_seconds": agg(p, lambda R: np.mean([x["background_seconds"] for x in R])),
            "retrains": agg(p, lambda R: sum(x["retrained"] for x in R)),
        }
        v = summary[p]
        print(f"  {p:<16} {v['regret']:>8.3f} {v['regret_novel']:>14.3f} {v['llm_calls']:>8.1f} "
              f"{v['planner_calls']:>7.1f} {v['decision_seconds']:>12.2f} "
              f"{v['background_seconds']:>12.1f}")
    print("   * 대기초 = 로봇이 답을 기다린 시간(임계 경로). 배치초 = 결정 후 오프라인 라벨링 시간.")
    print("     이 둘을 더해서 한 숫자로 만들면 제안이 자기모순으로 보인다(문서 참조).")

    # ---- 이 종류가 애초에 '어려운' 종류였는가 -----------------------------------------------
    # frozen(=always-surrogate) 이 이 종류에서 이미 잘한다면, 라우팅으로 얻을 것이 원리적으로 없다.
    # 그 사실을 숨기지 않고 먼저 찍는다 -- 라우터가 좋아 보이는지가 아니라 필요하기는 한지가 먼저다.
    headroom = summary["frozen"]["regret_novel"] - summary["oracle"]["regret_novel"]
    print(f"\n  -- 이 종류에 라우팅이 필요한가: frozen 의 novel-kind regret = "
          f"{summary['frozen']['regret_novel']:.3f} (오라클 대비 여유 {headroom:+.3f})")
    if headroom < 0.02:
        print("     ** always-surrogate 가 이미 이 종류를 거의 맞힙니다. 즉 이 종류는 '처음 보는 것'이라도")
        print("        기존 지식으로 전이가 됩니다 -> 여기서 라우팅의 이득은 원리적으로 거의 없습니다.")
        print("        C3/C4 를 보여줄 무대로는 부적합. (전이가 안 되는 종류를 골라야 합니다.)")

    # ---- C3: 게이트 vs 같은 예산의 무작위 라우터 --------------------------------------------
    print("\n  -- C3: 게이트가 진짜 '낯섦'을 짚는가 (같은 LLM 예산의 무작위 라우터와 짝지어 비교) --")
    a = [float(np.mean([x["regret"] for x in r["recs"]])) for r in per_policy["gated+assim"]]
    b = [float(np.mean([x["regret"] for x in r["recs"]])) for r in per_policy["random_router"]]
    d, lo, hi = paired_bootstrap(b, a)          # 양수 = gated 가 더 좋음(= b 가 더 나쁨)
    c3 = lo > 0
    print(f"     gated {np.mean(a):.3f} vs random {np.mean(b):.3f}  차이={d:+.3f} "
          f"CI [{lo:+.3f},{hi:+.3f}]  (시드 {n_seeds}개 짝지어 부트스트랩)")
    print(f"     -> {'게이트 우세 = C3 성립' if c3 else '차이 못 밝힘 = C3 미확립'}")
    if n_seeds < 8:
        print("     * 시드가 적으면 CI 가 넓습니다. 판정 전에 --seeds=16 이상 권장.")

    tp = sum(1 for r in per_policy["gated+assim"] for x in r["recs"]
             if x["kind"] == novel and x["to_llm"])
    fp = sum(1 for r in per_policy["gated+assim"] for x in r["recs"]
             if x["kind"] != novel and x["to_llm"])
    fn = sum(1 for r in per_policy["gated+assim"] for x in r["recs"]
             if x["kind"] == novel and not x["to_llm"])
    prec, rec = tp / max(1, tp + fp), tp / max(1, tp + fn)
    print(f"     게이트가 새 종류를 LLM 으로 보낸 비율 recall={rec:.2f} / 보낸 것 중 새 종류였던 "
          f"비율 precision={prec:.2f}")

    # ---- C4: 그 종류의 k 번째 사건을 여전히 LLM 에 보내는가 ------------------------------------
    n_ord = max(3, n_novel)
    ordc = {p: novel_ordinal_curve(per_policy[p], novel, n_ord)
            for p in ("gated+assim", "gated_no_assim", "random_router")}

    def halves(c):
        h = len(c) // 2
        first = [x for x in c[:h] if x == x]
        second = [x for x in c[h:] if x == x]
        return (float(np.mean(first)) if first else float("nan"),
                float(np.mean(second)) if second else float("nan"))

    print("\n  -- C4: LLM 이 처리한 것을 배워서 다음부터 싸지는가 --")
    print("     (x축 = '이 새 종류의 몇 번째 사건인가'. 뒤로 갈수록 LLM 호출이 줄어야 학습이 일어난 것)")
    print(f"     {'policy':<16} {'앞쪽 절반':>10} {'뒤쪽 절반':>10} {'감소':>8}")
    drops = {}
    for p, c in ordc.items():
        f1, f2 = halves(c)
        drops[p] = f1 - f2
        print(f"     {p:<16} {f1:>10.2f} {f2:>10.2f} {drops[p]:>+8.2f}")
    c4 = drops["gated+assim"] > drops["gated_no_assim"] + 0.02
    print(f"     -> 동화 있음 {drops['gated+assim']:+.2f} vs 재학습 끔 {drops['gated_no_assim']:+.2f}"
          f"  =>  C4 {'성립(감소는 학습 때문)' if c4 else '미확립'}")
    if not c4 and drops["gated+assim"] <= 0.02:
        print("     * 감소 자체가 없습니다. 게이트가 애초에 이 종류를 거의 안 짚었거나(위 recall 확인),")
        print("       전이가 잘 되어 처음부터 낯설지 않았다는 뜻입니다.")

    # ---- 곡선 저장용 -------------------------------------------------------------------
    curves = {"novel_ordinal": ordc}
    for p in ("gated+assim", "gated_no_assim", "random_router", "always_llm", "frozen", "oracle"):
        R = np.asarray([[x["regret"] for x in r["recs"][:n_steps]] for r in per_policy[p]])
        M = np.asarray([[1.0 if x["to_llm"] else 0.0 for x in r["recs"][:n_steps]]
                        for r in per_policy[p]])
        curves.setdefault("cum_regret", {})[p] = np.cumsum(R.mean(axis=0)).tolist()
        curves.setdefault("llm_rate_stream", {})[p] = sliding(M.mean(axis=0).tolist(), window)

    return {"novel": novel, "onset": onset, "n_steps": n_steps, "seeds": n_seeds,
            "gate": cfg["gate"], "target_rate": cfg["target_rate"], "lam": lam,
            "summary": summary, "curves": curves,
            "headroom_frozen_vs_oracle": headroom,
            "c3": {"holds": bool(c3), "delta": float(d), "ci": [float(lo), float(hi)],
                   "gate_recall_novel": rec, "gate_precision_novel": prec},
            "c4": {"holds": bool(c4), "drop_with_assim": drops["gated+assim"],
                   "drop_without": drops["gated_no_assim"],
                   "drop_random": drops["random_router"]},
            "streams": {p: [{"seed": r["seed"], "onset": r["onset"], "recs": r["recs"]}
                            for r in per_policy[p]] for p in POLICIES}}


def main():
    argv = sys.argv[1:]
    args = [a for a in argv if not a.startswith("--")]
    path = wm_datasets.resolve(args[0] if args else None)   # 기본 = CANONICAL(openworld_merged)
    opt = lambda k, d: next((a.split("=", 1)[1] for a in argv if a.startswith(f"--{k}=")), d)
    cfg = {"lam": float(opt("lam", "3.0")), "seeds": int(opt("seeds", "8")),
           "bootstrap": int(opt("bootstrap", "8")), "warmup": int(opt("warmup", "6")),
           "window": int(opt("window", "8")), "gate": opt("gate", "novelty"),
           "target_rate": float(opt("target-rate", "0.15"))}
    novel_arg = opt("novel", "all")
    arm = opt("arm", "nl+state")
    jout = opt("json", None)
    plot = opt("plot", None)

    df = load_df(path)
    prov = provenance_summary(df)
    by_inst = {i: g for i, g in df.groupby("instance")}
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}
    instances = sorted(by_inst)
    kinds = sorted(set(kind_of.values()))
    novels = kinds if novel_arg == "all" else [k.strip() for k in novel_arg.split(",")]
    bad = [k for k in novels if k not in kinds]
    if bad:
        print(f"데이터에 없는 종류: {bad}. 가능한 값: {kinds} 또는 all")
        sys.exit(1)

    Xall = featurize_agnostic(df, action_repr="onehot")
    cols = list(Xall.columns)

    # 인스턴스별 진짜 플래너 1회 rollout 의 실제 소요시간(덤프에 기록된 측정값 -- 가정이 아니다).
    planner_seconds = {}
    for i, g in by_inst.items():
        v = [float(x) for x in g.label_seconds.values if float(x) == float(x)]
        planner_seconds[i] = float(np.mean(v)) if v else 0.0

    print("=" * 100)
    print("C3 + C4  라우팅과 동화: '처음엔 LLM, 곧 surrogate' 가 실제로 일어나는가")
    print("=" * 100)
    print(f"  data   : {path}  ({df.instance.nunique()} instances, kinds={kinds})")
    print(f"  gate   : {cfg['gate']} (아는 종류에서 오경보율 {cfg['target_rate']:.0%} 가 되도록 보정)")
    print(f"  seeds  : {cfg['seeds']}  bootstrap={cfg['bootstrap']}  warmup={cfg['warmup']}")
    print(f"  NL 출처: captured={prov['captured']} synthesized={prov['synthesized']} "
          f"-> grade={prov['grade']}")
    if prov["grade"] != "evidence":
        print("           ** 문장이 복원본입니다(라벨러 재생성 전). 헤드라인 인용 금지. **")

    # ---- LLM 결정 사전계산 (temperature=0 + 캐시 => 결정적. 정책마다 다시 부를 이유가 없다) ----
    producer = Producer()
    if producer.mock:
        print("  ** LLM_MOCK=1 -- 규칙기반 가짜 응답. 배선 점검 전용, 수치 인용 금지. **")
    print(f"  model  : {producer.model}  arm={arm}")
    llm_pick, llm_regret = {}, {}
    for i in instances:
        g = by_inst[i]
        r = producer.decide(g.iloc[0], arm=arm, valid=valid_macros_of(g))
        llm_pick[i] = r["macro"]
        llm_regret[i] = norm_regret(g, r["macro"], cfg["lam"])
    producer.save()
    llm_seconds = (producer.stats["seconds"] / max(1, producer.stats["calls"])
                   if producer.stats["calls"] else 1.5)
    print(f"  LLM    : 실호출 {producer.stats['calls']} / 캐시 {producer.stats['cache_hits']}, "
          f"평균 {llm_seconds:.2f}s/call, 전체 평균 regret {np.mean(list(llm_regret.values())):.3f}")

    results = {}
    for novel in novels:
        results[novel] = run_one_novel(cfg, df, Xall, cols, by_inst, kind_of, instances,
                                       planner_seconds, llm_pick, llm_regret, llm_seconds, novel)
        if plot:
            base, ext = os.path.splitext(plot)
            p = plot if len(novels) == 1 else f"{base}_{novel}{ext or '.png'}"
            make_plot(results[novel], p, novel)
            print(f"     [figure] {p}")

    # ---- 종합 판정 ----------------------------------------------------------------------
    print("\n" + "=" * 100)
    print("종합")
    print("=" * 100)
    print(f"  {'novel kind':<12} {'frozen여유':>10} {'C3':>18} {'C4':>18}")
    for k, r in results.items():
        c3 = ("성립" if r["c3"]["holds"] else "미확립") + " (%+.3f)" % r["c3"]["delta"]
        c4 = ("성립" if r["c4"]["holds"] else "미확립") + " (%+.2f)" % r["c4"]["drop_with_assim"]
        print(f"  {k:<12} {r['headroom_frozen_vs_oracle']:>+10.3f} {c3:>18} {c4:>18}")
    print("\n  읽는 법:")
    print("   · frozen여유 = always-surrogate 가 그 종류에서 오라클보다 얼마나 나쁜가. 0 에 가까우면")
    print("     그 종류는 전이가 되므로 라우팅 자체가 불필요하다(그 줄의 C3/C4 는 의미가 약하다).")
    print("   · C3 = 같은 LLM 예산의 무작위 라우터를 이겼는가 = 게이트가 정보를 쓰는가.")
    print("   · C4 = 그 종류를 겪을수록 LLM 호출이 줄었는가(재학습 끈 대조군 대비).")

    out = {"data": path, "arm": arm, "config": cfg, "nl_provenance": prov,
           "llm_stats": producer.stats, "results": results}
    if jout:
        json.dump(out, open(jout, "w", encoding="utf-8"), indent=1, default=float)
        print(f"\n[saved] {jout}")


# ==========================================================================================
def make_plot(out, path, novel):
    """주장 전체를 한 장에 담는 그림.

    왼쪽  = C4. x축이 "이 새 종류의 k 번째 사건" 이라 곡선이 내려가면 곧 학습의 효과다.
            (스트림 위치를 x축으로 쓰면 등장빈도 변화와 섞여 아무것도 증명하지 못한다.)
    오른쪽 = 그동안 품질이 유지되는가. 누적 regret 이 always_llm/oracle 대비 어디에 있는지.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    curves, onset = out["curves"], out["onset"]
    style = {"gated+assim": ("#1f77b4", "-", 2.4), "gated_no_assim": ("#d62728", "--", 1.8),
             "random_router": ("#7f7f7f", ":", 1.8), "always_llm": ("#9467bd", "-.", 1.3),
             "frozen": ("#2ca02c", "-", 1.3), "oracle": ("#000000", "-", 1.0)}

    fig, ax = plt.subplots(1, 2, figsize=(13, 5))
    for p, c in curves["novel_ordinal"].items():
        col, ls, lw = style.get(p, ("k", "-", 1.0))
        ax[0].plot(range(1, len(c) + 1), c, color=col, ls=ls, lw=lw, marker="o", ms=3, label=p)
    ax[0].set_xlabel(f"k-th event of the NOVEL kind ('{novel}')")
    ax[0].set_ylabel("P(routed to LLM)")
    ax[0].set_ylim(-0.05, 1.05)
    ax[0].set_title("C4  the LLM hands over as the surrogate assimilates")
    ax[0].legend(fontsize=8)
    ax[0].grid(alpha=.25)

    for p, c in curves["cum_regret"].items():
        col, ls, lw = style.get(p, ("k", "-", 1.0))
        ax[1].plot(c, color=col, ls=ls, lw=lw, label=p)
    ax[1].axvline(onset, color="k", lw=1, alpha=.5)
    ax[1].annotate(f"novel kind appears", xy=(onset, 0), xytext=(onset + 0.5, 0.2),
                   fontsize=8, rotation=90, va="bottom")
    ax[1].set_xlabel("event # in stream")
    ax[1].set_ylabel("cumulative regret")
    ax[1].set_title("quality while that happens (lower is better)")
    ax[1].legend(fontsize=8)
    ax[1].grid(alpha=.25)

    fig.suptitle(f"assimilation: LLM first, surrogate after   "
                 f"(novel={novel}, {out['seeds']} seeds, gate={out['gate']})", fontsize=11)
    fig.tight_layout()
    fig.savefig(path, dpi=150)


if __name__ == "__main__":
    main()
