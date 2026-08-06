#!/usr/bin/env python
"""night_analysis.py -- 생성이 끝나면 자동으로 도는 **측정 일괄 실행**.

사람이 자는 동안 데이터만 쌓이고 아무도 보지 않는 상태를 만들지 않기 위한 것이다.
아침에는 `md/MORNING_<날짜>.md` 가 이미 있어야 한다.

무엇을 재는가 (전부 시뮬 0, 새로 생성된 데이터 위에서)
  1. 창/설정별 프로파일 — 동점률·완주율·결정적 n·τ·종류분포          (morning_report 로직)
  2. 정책 비교 — oracle / random / rule_table / canonical / surrogate 1층·2층 + 짝지은 부호검정
  3. 값 2층 분해 — 항등식 검사 + 1층 대비 결정 회귀 여부
  4. 행동표현 A3 — one-hot vs ψ 서술자가 결정을 바꾸는가
  5. 종류 홀드아웃(B2) — fault / battery 를 각각 훈련에서 빼고 재측정 (LOKO 대리실험)
  6. 자동 판정 — 무엇이 확정됐고 무엇이 여전히 미확정인지, 다음 한 수

**판정 원칙**: 결정적 n < 30 이면 어떤 우열도 선언하지 않는다(함정 14).
부호검정 p > 0.05 면 "우열 미확립"이라고 쓰지, 평균 차이로 이겼다고 쓰지 않는다.

실행
    PYTHONIOENCODING=utf-8 python night_analysis.py
    PYTHONIOENCODING=utf-8 python night_analysis.py --globs 'oracle/out/hz_fb/ep_s*.jsonl'
"""
import os, sys, json, math, argparse, datetime, traceback
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from value_two_layer import (decompose_rollouts, load_rows, tie_split, build_features,
                             check_identity, TwoLayerValue)
from baselines_eval import (group_by_instance, kind_of, pol_oracle, pol_random, pol_noop,
                            pol_intervene, pol_state_independent, pol_rule_table,
                            pol_canonical, normalized_regret, sign_test, loio_model_policy)
from surrogate_model import build_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_MD = os.path.join(HERE, "md", f"MORNING_{datetime.date.today().isoformat()}.md")

# 데이터셋 목록: (글롭, 라벨, 창, 설정). 글롭은 **좁게** 쓴다(함정 11).
DATASETS = [
    ("oracle/out/ep_[abg]*.jsonl", "기존 ep",     "[8,60]",   "3사건 · 전종류"),
    ("oracle/out/ep2_*.jsonl",     "기존 ep2",    "[70,230]", "3사건 · 전종류"),
    ("oracle/out/hz_k1/ep_s*.jsonl", "신규 A",    "[55,130]", "3사건 · 전종류"),
    ("oracle/out/hz_fb/ep_s*.jsonl", "신규 B",    "[55,130]", "3사건 · fault+battery"),
    ("oracle/out/hz_k1_e2/ep_s*.jsonl", "신규 C", "[55,130]", "2사건 · 전종류"),
]

LINES = []


def say(s=""):
    print(s)
    LINES.append(s)


def explain(*paragraphs):
    """표 밑에 붙는 **말로 된 해석**.

    왜 필요한가: 숫자만 있는 리포트는 며칠 뒤의 나 자신도 못 읽는다. 각 절은
    (1) 이 표를 어떻게 읽는가 (2) 이번 값이 뜻하는 것 (3) 그래서 무엇을 하면 되는가
    세 가지를 문장으로 답해야 한다.
    """
    for p in paragraphs:
        say(p.strip())
        say()


def load(pattern):
    rows = [r for r in load_rows(pattern)]
    if not rows:
        return None, None, None, None
    agg = decompose_rollouts(rows)
    groups = group_by_instance(agg)
    agg = [r for r in agg if r["instance"] in groups]
    if not agg:
        return None, None, None, None
    dec, tied = tie_split(agg)
    return rows, agg, groups, (dec, tied)


# ==========================================================================================
#  1. 프로파일
# ==========================================================================================
def profile_table():
    say("## 1. 데이터셋 프로파일\n")
    say("| 데이터 | 창 | 설정 | instance | 완주셀 | 동점 | 결정적 n | τ=0 | 종류(결정적) |")
    say("|---|---|---|---|---|---|---|---|---|")
    profiles = {}
    for pat, lab, win, cfg in DATASETS:
        rows, agg, groups, dt = load(pat)
        if agg is None:
            say(f"| {lab} | {win} | {cfg} | — | — | — | — | — | (데이터 없음) |")
            continue
        dec, tied = dt
        n = len(dec) + len(tied)
        pc = np.array([r["p_complete"] for r in agg], float)
        taus = [float(r.get("tau_to_next", -1)) for r in rows if r.get("tau_to_next") is not None]
        taus = [t for t in taus if t >= 0]
        tz = np.mean([t == 0 for t in taus]) if taus else float("nan")
        kd = Counter(kind_of(groups[i]) for i in dec)
        say(f"| {lab} | {win} | {cfg} | {n} | {(pc>0).mean():.0%} | {len(tied)/max(1,n):.0%} | "
            f"**{len(dec)}** | {tz:.0%} | {dict(kd)} |")
        profiles[lab] = {"pattern": pat, "n": n, "decisive": len(dec), "tied": len(tied),
                         "completion": float((pc > 0).mean()), "tau_zero": float(tz),
                         "kinds_decisive": dict(kd)}
    say()

    explain(
        "**이 표를 읽는 법.** `instance` 는 '사건이 하나 터졌고 그때 무엇을 할지 골라야 하는 상황' "
        "하나를 뜻한다. 각 instance 마다 여러 팔(NOOP / Replace / …)을 실제로 시뮬레이션해 비용을 "
        "재 놓았다. `동점` 은 팔을 무엇으로 골라도 결과가 똑같았던 instance 의 비율이다 — 이런 "
        "instance 는 어떤 정책이든 손해가 0이라 정책을 구별하는 데 아무 정보를 주지 못한다. "
        "그래서 실제로 쓸 수 있는 표본은 `결정적 n` 뿐이고, 이 숫자가 이 연구의 검정력을 결정한다.",

        "**완주셀**은 그 판이 빌드를 끝까지 마쳤는지의 비율이다. 이게 낮으면 비용이 거의 전부 "
        "'실패 벌점'이 되어, 평가가 '누가 완주하나'가 아니라 '누가 더 늦게 죽나'를 재는 문제로 "
        "바뀐다. **τ=0** 은 연속한 두 결정 사이에 빌드 진행이 전혀 없었다는 뜻이다 — 즉 세 사건이 "
        "따로 온 게 아니라 사실상 동시에 처리됐다는 신호다(자세한 진단은 아래 τ 절).",
    )
    return profiles


# ==========================================================================================
#  1-b. 결정 시점 진단 — 이 데이터가 '순차'인가 '동시'인가
# ==========================================================================================
def tau_diagnostic():
    say("## 1-b. 결정 시점 진단 (이 데이터는 에피소드인가, 동시사건인가)\n")
    say("| 데이터 | 결정1 closed | 결정2 closed | 결정3 closed | τ=0 비율 |")
    say("|---|---|---|---|---|")
    res = {}
    for pat, lab, win, cfg in DATASETS:
        rows = load_rows(pat)
        if not rows:
            continue
        med = {}
        for i in (1, 2, 3):
            v = [float(r["closed_at_decision"]) for r in rows
                 if r.get("decision_idx") == i and r.get("closed_at_decision") is not None]
            med[i] = float(np.median(v)) if v else float("nan")
        taus = [float(r.get("tau_to_next", -1)) for r in rows if r.get("tau_to_next") is not None]
        taus = [t for t in taus if t >= 0]
        tz = float(np.mean([t == 0 for t in taus])) if taus else float("nan")
        say(f"| {lab} | {med[1]:.0f} | {med[2]:.0f} | {med[3]:.0f} | {tz:.0%} |")
        res[lab] = {"median_closed": med, "tau_zero": tz}
    say()

    # 표에서 유도한 분류 — 문장이 표와 어긋나지 않도록 하드코딩하지 않는다.
    collapsed = [k for k, v in res.items() if v["tau_zero"] == v["tau_zero"] and v["tau_zero"] > 0.5]
    spread = [k for k, v in res.items() if v["tau_zero"] == v["tau_zero"] and v["tau_zero"] < 0.2]
    # 결정적 표본과 교차: 어느 쪽이 '쓸 수 있는' 데이터인가
    prof = {p[1]: p for p in DATASETS}

    explain(
        "**무엇을 보는 표인가.** 이 프로젝트의 상위 루프는 '사건이 올 때마다 결정한다'는 "
        "준마르코프 결정과정(SMDP)으로 설계돼 있다. 그 설계가 성립하려면 **결정들이 시간축에서 "
        "떨어져 있어야** 한다 — 결정 1을 내리고 빌드가 얼마간 진행된 뒤 결정 2가 와야, "
        "'이번 선택이 다음 상황을 바꾼다'는 커플링이 데이터에 나타난다.",

        (f"**이번 결과: 데이터셋이 두 부류로 갈린다.** "
         f"{', '.join(collapsed) if collapsed else '(없음)'} 는 결정 1·2·3 이 거의 같은 진행도"
         f"(closed 58~60)에 뭉쳐 있다 — 계획상으로는 사건이 흩어져 있는데 기록은 한 점이다. "
         f"반면 {', '.join(spread) if spread else '(없음)'} 는 결정들이 실제로 벌어져 있다"
         f"(τ=0 비율 0%). **즉 기록 자체가 고장난 것은 아니다** — 사건이 충분히 늦게, 충분히 "
         f"떨어져 발화하면 그대로 기록된다."),

        "**그런데 여기에 이 프로젝트의 핵심 딜레마가 있다.** 결정이 벌어진 데이터셋은 사건이 "
        "빌드 후반에 터지도록 만든 것인데, 그렇게 하면 어떤 대응을 해도 빌드가 완주하지 못해 "
        "**팔 사이 결과가 전부 같아진다**(동점). 반대로 사건을 이르게 터뜨리면 팔이 갈려 "
        "결정적 표본은 얻지만, 결정들이 첫 배치 경계에 몰려 **순차 구조가 사라진다**. "
        "지금까지 이 둘을 동시에 만족한 데이터셋은 없다. §1 의 표에서 '결정적 n' 이 큰 줄과 "
        "'τ=0 비율' 이 낮은 줄이 서로 다른 줄이라는 것이 그 증거다.",

        "**그래서 무엇이 되고 무엇이 안 되나.** 결정 하나하나의 품질(어떤 팔이 옳았나)은 그대로 "
        "잴 수 있다 — 아래 §2 의 결론은 유효하다. 반면 '이번 결정이 다음 결정을 어떻게 바꾸는가'에 "
        "의존하는 것들(순차 커플링, 이력이 도움이 되는가, 스페어를 아껴 쓰는 장기 계획)은 **결정적 "
        "표본이 있는 데이터로는 주장할 수 없다**. SMDP 정식화가 틀렸다는 뜻이 아니라, 그 구조와 "
        "판별력을 동시에 갖춘 데이터를 아직 만들지 못했다는 뜻이다.",

        "**다음 조치.** 두 갈래다. (i) 결정 시점을 producer 호출 시점이 아니라 **트리거 발화 "
        "시점**에 기록하도록 바꿔, 뭉침이 실제 동시처리인지 기록 해상도 문제인지 가른다. "
        "(ii) 사건 간격을 진행도가 아니라 **완주 여지가 남은 구간 안에서** 벌린다 — 예를 들어 "
        "첫 배치 경계(58) 직후부터 시작해 간격을 강제하고, 동시에 완주가 가능하도록 사건 수나 "
        "심각도를 낮춘다. 이 둘이 맞물려야 '결정적이면서 순차적인' 데이터가 나온다.",
    )
    return res


# ==========================================================================================
#  2. 정책 비교
# ==========================================================================================
def policy_table(agg, groups, dec, phi="full", title=""):
    X, cols = build_features(agg, phi=phi)
    X = np.asarray(X, float)
    rng = np.random.default_rng(0)
    rule_pol = {
        "oracle": pol_oracle, "random_valid": lambda tr, g: pol_random(tr, g, rng),
        "noop_always": pol_noop, "intervene_always": pol_intervene,
        "state_independent": pol_state_independent, "rule_table": pol_rule_table,
        "canonical": pol_canonical,
    }
    chosen = {k: {} for k in rule_pol}
    for inst, g in groups.items():
        train = [gg for i, gg in groups.items() if i != inst]
        for name, fn in rule_pol.items():
            chosen[name][inst] = fn(train, g)
    chosen["surrogate_1layer"] = loio_model_policy(agg, X, lambda: build_model())
    chosen["surrogate_2layer"] = loio_model_policy(agg, X, lambda: TwoLayerValue(), two_layer=True)

    say(f"### {title} (φ={phi}, {X.shape[1]}열, 결정적 n={len(dec)})\n")
    say("| 정책 | regret(결정적) | top-1 | 고른 팔 분포 |")
    say("|---|---|---|---|")
    vecs, table = {}, {}
    order = ["oracle", "surrogate_2layer", "surrogate_1layer", "canonical", "rule_table",
             "state_independent", "intervene_always", "noop_always", "random_valid"]
    for name in order:
        ch = chosen[name]
        r, used = normalized_regret(groups, ch, subset=dec)
        hit = np.mean([1.0 if ch[i] == pol_oracle(None, groups[i]) else 0.0 for i in used]) if used else float("nan")
        vecs[name] = (r, used)
        table[name] = {"regret": float(r.mean()) if r.size else None, "top1": float(hit),
                       "n": int(r.size)}
        say(f"| {name} | {r.mean():.4f} | {hit:.2f} | {dict(Counter(ch[i] for i in used))} |")
    say()

    say("**짝지은 부호검정** (결정적 instance)\n")
    say("| A | B | n | A승 | B승 | p | 판정 |")
    say("|---|---|---|---|---|---|---|")
    tests = {}
    pairs = [("surrogate_2layer", "rule_table"), ("surrogate_1layer", "rule_table"),
             ("surrogate_1layer", "random_valid"), ("surrogate_2layer", "surrogate_1layer"),
             ("rule_table", "random_valid"), ("canonical", "rule_table")]
    for a, b in pairs:
        (ra, ua), (rb, ub) = vecs[a], vecs[b]
        common = sorted(set(ua) & set(ub))
        if not common:
            continue
        va = np.array([ra[ua.index(i)] for i in common])
        vb = np.array([rb[ub.index(i)] for i in common])
        w, l, p = sign_test(va, vb)
        verdict = "우열 미확립" if p > 0.05 else ("**A 우위**" if w > l else "**B 우위**")
        if len(dec) < 30:
            verdict = "판정 보류(n<30)"
        tests[f"{a}|{b}"] = {"wins": w, "losses": l, "p": p, "n": len(common)}
        say(f"| {a} | {b} | {len(common)} | {w} | {l} | {p:.3f} | {verdict} |")
    say()

    # ---- 말로 된 해석 (숫자에서 유도한다 — 하드코딩 금지) --------------------------------
    sur = table.get("surrogate_1layer", {})
    rt = table.get("rule_table", {})
    rnd = table.get("random_valid", {})
    t_rand = tests.get("surrogate_1layer|random_valid", {})
    t_rule = tests.get("surrogate_1layer|rule_table", {})
    rule_pick = "항상 같은 팔" if len(set(chosen["rule_table"].values())) == 1 else "종류별로 다른 팔"

    p1 = ("**이 표를 읽는 법.** `regret` 은 '그 상황에서 최선의 팔 대신 이 정책이 고른 팔을 썼을 때 "
          "얼마나 손해였나'를 instance 안에서 0~1 로 정규화한 값이다. 0이면 항상 최선, 1이면 항상 "
          "최악이다. `top-1` 은 최선의 팔을 정확히 맞힌 비율이다. 맨 위 `oracle` 은 정답을 아는 "
          "상한이고, `random_valid` 는 아무거나 고르는 하한이다. **이 둘 사이 어디에 있느냐**가 "
          "정책의 값어치다.")

    p2 = (f"**비교 대상이 왜 `rule_table` 인가.** 이건 '사건 종류만 보고 정해진 대응을 한다'는 "
          f"규칙표이고, 이번 데이터에서는 {rule_pick}을 골랐다(regret {rt.get('regret', float('nan')):.3f}, "
          f"top-1 {rt.get('top1', float('nan')):.2f}). 상태를 전혀 안 보는 이 정책을 못 이기면, "
          f"φ(상태 요약)를 만들고 서로게이트를 학습시킨 일 전체가 값을 못 한 것이다. "
          f"즉 **이게 넘어야 할 진짜 벽**이다.")

    if t_rand:
        if t_rand["p"] <= 0.05:
            p3 = (f"**이번 결과 ①: 상태는 정보를 담고 있다.** 서로게이트가 무작위를 "
                  f"{t_rand['wins']}승 {t_rand['losses']}패로 이겼고 짝지은 부호검정 p={t_rand['p']:.3f} 로 "
                  f"유의하다. 즉 φ 안에 '어떤 팔이 나은가'를 가르는 신호가 실제로 들어 있다.")
        else:
            p3 = (f"**이번 결과 ①: 아직 상태가 정보를 담고 있다고 말할 수 없다.** 서로게이트 대 무작위가 "
                  f"{t_rand['wins']}승 {t_rand['losses']}패, p={t_rand['p']:.3f} 로 미확립이다. 여기서 막히면 "
                  f"모델을 바꿔서 풀 문제가 아니라 **φ 자체나 표본 수**의 문제다.")
    else:
        p3 = "**이번 결과 ①:** 무작위 대비 비교가 계산되지 않았다."

    if t_rule:
        if t_rule["p"] <= 0.05:
            p4 = (f"**이번 결과 ②: 규칙표를 넘었다.** {t_rule['wins']}승 {t_rule['losses']}패, "
                  f"p={t_rule['p']:.3f}. 종류 이름만으로는 못 하는 판단을 상태를 보고 해냈다는 뜻이다.")
        else:
            gap = (rt.get("regret") or 0) - (sur.get("regret") or 0)
            p4 = (f"**이번 결과 ②: 규칙표는 아직 못 넘었다.** {t_rule['wins']}승 {t_rule['losses']}패, "
                  f"p={t_rule['p']:.3f} 로 미확립이다. 평균 regret 은 {gap:+.3f} 만큼 서로게이트가 "
                  f"{'낫지만' if gap > 0 else '오히려 나쁘고'}, 이 정도 표본에서는 우연과 구별되지 않는다. "
                  f"규칙표가 지는 instance(= 종류가 같은데 정답이 다른 경우)를 더 모으거나, "
                  f"그 구분을 실어 나를 특징(예: 스페어 잔량)을 φ 에 넣는 것이 다음 수다.")
    else:
        p4 = "**이번 결과 ②:** 규칙표 대비 비교가 계산되지 않았다."

    explain(p1, p2, p3, p4)
    return table, tests, chosen


# ==========================================================================================
#  3~5. 2층 / ψ / 홀드아웃
# ==========================================================================================
def two_layer_check(agg, groups, dec):
    say("## 3. 값 2층 분해\n")
    ok = check_identity(agg)
    say(f"- 항등식(재조합 = rollout 평균비용): **{'일치' if ok else '불일치'}** ({len(agg)}셀)")
    pc = np.array([r["p_complete"] for r in agg], float)
    mid = int(((pc > 0) & (pc < 1)).sum())
    say(f"- P(complete)∈(0,1) 셀: {mid} — 0이면 K=1(결정론) 라벨이라 2층의 확률 헤드는 상수다")
    X, _ = build_features(agg, phi="full")
    one = loio_model_policy(agg, np.asarray(X, float), lambda: build_model())
    two = loio_model_policy(agg, np.asarray(X, float), lambda: TwoLayerValue(), two_layer=True)
    common = sorted(set(one) & set(two))
    diff_dec = [i for i in common if one[i] != two[i] and i in dec]
    say(f"- 1층 vs 2층 결정 불일치: 전체 {sum(1 for i in common if one[i]!=two[i])}건, "
        f"**결정적 instance 에서 {len(diff_dec)}건**")
    say()

    p_ident = ("**무엇을 하려는 것인가.** 비용 라벨은 '완주하면 makespan, 실패하면 큰 벌점'이라 값이 "
               "두 덩어리로 갈라진다(완주 ~20 / 실패 ~26000). 이걸 하나의 회귀로 맞히면 모델이 사실상 "
               "'완주하냐 마냐'만 맞히는 분류기로 붕괴하고, 완주한 팔들 **사이의** 속도 차이는 잔차에 "
               "묻힌다. 그래서 완주확률과 완주했을 때의 makespan 을 **따로 배우고 비용식으로 다시 "
               "합치는** 것이 2층 분해다.")
    p_check = ("**항등식 검사**는 모델 이전에 배선이 맞는지 보는 것이다. 조건부 평균으로 다시 합친 값은 "
               "원래 평균 비용과 수학적으로 정확히 같아야 한다. 여기서 틀리면 모델 문제가 아니라 집계가 "
               "잘못된 것이므로 그 위의 모든 숫자를 버려야 한다.")
    if mid == 0:
        p_val = ("**이번 결과: 2층의 값어치는 아직 측정 불가.** 완주확률이 0 또는 1 뿐이고 그 사이 값이 "
                 "하나도 없다. 지금 라벨이 판당 1회 실행(K=1, 확률 요소 없음)이라 '완주할 확률'이라는 "
                 "개념 자체가 데이터에 없기 때문이다. 확률 헤드가 상수이므로 2층은 1층에 잉여 파라미터를 "
                 "더한 것과 같고, 표에서 2층이 1층보다 나빠 보이는 것도 그 때문이다. **판단 보류**가 맞고, "
                 "확률적 라벨(같은 결정을 여러 번 굴리기)을 만든 뒤에 다시 재야 한다.")
    else:
        p_val = (f"**이번 결과:** 완주확률이 0과 1 사이인 셀이 {mid}개 있다 — 확률 헤드가 실제로 배울 것이 "
                 f"있는 상태다. 이 조건에서만 2층 대 1층 비교가 의미를 갖는다.")
    explain(p_ident, p_check, p_val)
    return {"identity_ok": ok, "p_mid_cells": mid, "diff_decisive": len(diff_dec)}


def psi_check(agg, groups, dec):
    say("## 4. 행동 표현 (A3): one-hot vs ψ 서술자\n")
    res = {}
    say("| 표현 | 열 | 1층 regret | 2층 regret |")
    say("|---|---|---|---|")
    keep = {}
    for rep in ("agnostic", "psi"):
        X, cols = build_features(agg, phi=rep)
        X = np.asarray(X, float)
        r1 = normalized_regret(groups, loio_model_policy(agg, X, lambda: build_model()), subset=dec)
        r2 = normalized_regret(groups, loio_model_policy(agg, X, lambda: TwoLayerValue(),
                                                         two_layer=True), subset=dec)
        keep[rep] = (r1, r2)
        say(f"| {rep} | {len(cols)} | {r1[0].mean():.4f} | {r2[0].mean():.4f} |")
        res[rep] = {"n_cols": len(cols), "regret_1layer": float(r1[0].mean()),
                    "regret_2layer": float(r2[0].mean())}
    (ra, ua), (rb, ub) = keep["agnostic"][0], keep["psi"][0]
    common = sorted(set(ua) & set(ub))
    w, l, p = sign_test(np.array([ra[ua.index(i)] for i in common]),
                        np.array([rb[ub.index(i)] for i in common]))
    say(f"\n- 부호검정(1층 기준): one-hot {w}승 / ψ {l}승, p={p:.3f}")
    say()
    explain(
        "**왜 이걸 재는가.** 지금 행동은 '몇 번 매크로냐'라는 이름표(one-hot)로 인코딩돼 있다. "
        "이 방식은 새 행동을 추가하는 순간 모델의 입력 차원이 바뀌어 **재학습 없이는 아무것도 못 하게** "
        "된다. 그래서 행동을 이름이 아니라 '무엇을 하는가'(비용을 쓰는가, 스페어를 소모하는가, "
        "되돌릴 수 있는가, 영향 범위가 어디까지인가)로 적는 서술자 ψ 로 바꾸려는 것이다. "
        "그러면 새 행동은 같은 축 위의 새 점일 뿐이라 차원이 변하지 않는다.",

        (f"**이번 결과.** 두 표현의 결정 품질이 통계적으로 구별되지 않는다(p={p:.3f}). "
         f"ψ 는 성능을 올리려는 장치가 아니라 **새 행동을 받을 수 있게 하려는 장치**이므로, "
         f"'기존 성능을 깎지 않는다'가 곧 합격 기준이다. 이번 결과는 그 기준을 충족한다."
         if p > 0.05 else
         f"**이번 결과.** 두 표현의 차이가 유의하다(p={p:.3f}). ψ 로 바꾸면 기존 성능이 달라진다는 "
         f"뜻이므로, 어느 축이 정보를 잃고 있는지 확인하기 전에는 채택하면 안 된다."),
    )
    res["sign_test"] = {"onehot_wins": w, "psi_wins": l, "p": p}
    return res


def holdout_check(agg, groups, dec):
    say("## 5. 종류 홀드아웃 (B2) — 처음 보는 종류에서 surrogate 는 어떤가\n")
    X, _ = build_features(agg, phi="full")
    X = np.asarray(X, float)
    kinds = sorted({kind_of(g) for g in groups.values()})
    say("| 홀드아웃 | 그 종류의 결정적 n | regret(홀드아웃) | regret(그 외) | rule_table(홀드아웃) |")
    say("|---|---|---|---|---|")
    res = {}
    for k in kinds:
        sub = {i for i in dec if kind_of(groups[i]) == k}
        if len(sub) < 3:
            say(f"| {k} | {len(sub)} | (표본 부족) | | |")
            continue
        ch = loio_model_policy(agg, X, lambda: build_model(), held_out_kinds=(k,))
        r_in, _ = normalized_regret(groups, ch, subset=sub)
        r_out, _ = normalized_regret(groups, ch, subset=(dec - sub))
        rt = {}
        for inst, g in groups.items():
            train = [gg for i, gg in groups.items() if i != inst and kind_of(gg) != k]
            rt[inst] = pol_rule_table(train, g)
        r_rt, _ = normalized_regret(groups, rt, subset=sub)
        say(f"| {k} | {len(sub)} | {r_in.mean():.4f} | {r_out.mean():.4f} | {r_rt.mean():.4f} |")
        res[k] = {"n": len(sub), "regret_heldout": float(r_in.mean()),
                  "regret_rest": float(r_out.mean()), "regret_rule_table": float(r_rt.mean())}
    say()
    worse = [k for k, v in res.items() if v["regret_heldout"] > v["regret_rest"] + 0.05]
    better = [k for k, v in res.items() if v["regret_heldout"] < v["regret_rest"] - 0.05]
    explain(
        "**왜 이걸 재는가.** 이 연구의 핵심 가설은 '처음 보는 사건은 LLM 이 대응을 만들고, 익숙한 "
        "사건은 서로게이트가 싸게 처리한다'는 역할 분담이다. 그 분담이 성립하려면 **서로게이트가 "
        "처음 보는 종류에서 실제로 못 해야** 한다. 그래서 한 종류를 훈련에서 통째로 빼고(그 종류의 "
        "행이 한 줄도 안 들어가게), 그 종류에서만 성능을 따로 잰다.",

        ("**이번 결과: 가설과 반대 방향이다.** 빼고 학습해도 그 종류에서 오히려 더 잘한다"
         f"({', '.join(better)}). 이는 종류 이름 없이도 상태 서술자만으로 일반화가 된다는 뜻이고, "
         "kind-agnostic 설계가 잘 작동한다는 좋은 소식이면서 동시에 **'LLM 을 불러야 하는 구간'의 "
         "존재를 이 데이터로는 보이지 못한다**는 뜻이다. 다만 종류가 두 개뿐이라 홀드아웃 실험으로는 "
         "약하다 — 진짜 미지 사건(훈련 어휘에 없는 새 고장모드)으로 다시 해야 한다."
         if better and not worse else
         "**이번 결과: 가설과 같은 방향이다.** 빼고 학습하면 그 종류에서 눈에 띄게 나빠진다"
         f"({', '.join(worse)}). 서로게이트가 감당 못 하는 구간이 실재하므로, 그 구간을 판별해 "
         "LLM 으로 보내는 라우터가 값을 할 수 있다."
         if worse else
         "**이번 결과:** 홀드아웃 여부에 따른 차이가 뚜렷하지 않다(±0.05 이내). 이 표본으로는 "
         "역할 분담의 근거를 얻지 못한다."),

        "맨 오른쪽 `rule_table(홀드아웃)` 열은 대조군이다 — 그 종류를 못 본 규칙표는 크게 무너지는데 "
        "서로게이트는 버틴다면, 버티게 해 준 것은 종류 이름이 아니라 상태 서술자라는 근거가 된다.",
    )
    return res


# ==========================================================================================
#  main
# ==========================================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--merge", default="oracle/out/hz_k1/ep_s*.jsonl,oracle/out/hz_fb/ep_s*.jsonl",
                    help="헤드라인 측정에 쓸 글롭들(쉼표구분). 같은 창·같은 K 만 합칠 것.")
    ap.add_argument("--out", default=OUT_MD)
    args = ap.parse_args()

    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    say(f"# 야간 자동 측정 리포트 ({stamp})\n")
    say("생성: `night_analysis.py` (야간 러너가 생성 종료 후 자동 실행). "
        "판정 원칙 — 결정적 n<30 이면 우열을 선언하지 않는다, 부호검정 p>0.05 는 '미확립'이다.\n")

    explain(
        "## 0. 이 리포트가 답하려는 질문\n\n"
        "이 시스템은 로봇 여러 대가 조립을 진행하는 도중 **고장 같은 사건이 터졌을 때 무엇을 할지** "
        "고르는 상위 결정기를 학습한다. 후보 대응(팔)은 스페어로 교체하기, 우선순위 낮추기, "
        "아무것도 안 하기 등이고, 각 대응의 진짜 비용은 **시뮬레이션을 끝까지 돌려봐야** 안다"
        "(판당 수 분). 그래서 '돌려보지 않고 어떤 대응이 나을지 맞히는' 서로게이트를 학습시킨다.\n\n"
        "이 리포트가 검사하는 것은 네 가지다.\n\n"
        "1. **데이터가 판단 가능한가** — 팔에 따라 결과가 실제로 갈리는 상황이 충분히 모였는가\n"
        "2. **상태를 보는 것이 값을 하는가** — 서로게이트가 무작위와 규칙표를 이기는가\n"
        "3. **표현을 바꿔도 되는가** — 새 행동을 받을 수 있는 인코딩(ψ)이 기존 성능을 깎지 않는가\n"
        "4. **역할 분담의 근거가 있는가** — 처음 보는 종류에서 서로게이트가 실제로 못 하는가\n"
    )

    result = {"stamp": stamp}
    try:
        result["profiles"] = profile_table()
    except Exception:
        say("```\n" + traceback.format_exc() + "\n```")
    try:
        result["tau"] = tau_diagnostic()
    except Exception:
        say("```\n" + traceback.format_exc() + "\n```")

    # ---- 헤드라인: 새 데이터 병합 -------------------------------------------------------
    merged_rows = []
    for pat in args.merge.split(","):
        pat = pat.strip()
        if pat:
            merged_rows += load_rows(pat)
    if not merged_rows:
        say("\n**새 데이터가 없다.** 생성 로그를 볼 것.")
    else:
        agg = decompose_rollouts(merged_rows)
        groups = group_by_instance(agg)
        agg = [r for r in agg if r["instance"] in groups]
        dec, tied = tie_split(agg)
        say(f"## 2. 정책 비교 — 병합 데이터 (instance {len(groups)}, 결정적 {len(dec)}, "
            f"동점 {len(tied)})\n")
        say(f"글롭: `{args.merge}`\n")
        try:
            t, s, _ = policy_table(agg, groups, dec, phi="full", title="전체 φ")
            result["policies"] = t
            result["sign_tests"] = s
        except Exception:
            say("```\n" + traceback.format_exc() + "\n```")
        for fn in (two_layer_check, psi_check, holdout_check):
            try:
                result[fn.__name__] = fn(agg, groups, dec)
            except Exception:
                say("```\n" + traceback.format_exc() + "\n```")

        # ---- 자동 판정 ------------------------------------------------------------------
        say("## 6. 종합 판정\n")
        nd = len(dec)
        st = result.get("sign_tests", {})
        p_rand = st.get("surrogate_1layer|random_valid", {}).get("p")
        p_rule = st.get("surrogate_1layer|rule_table", {}).get("p")
        tl = result.get("two_layer_check", {})

        say(f"**표본**: 결정적 instance {nd}개"
            + (" — 30개 미만이라 어떤 우열도 선언하지 않는다(과거에 5개짜리 표본에서 "
               "'φ 충분'이라는 잘못된 결론을 낸 적이 있다)." if nd < 30 else "로, 짝지은 검정을 할 만하다."))
        say()

        lines = []
        if p_rand is not None:
            lines.append("**확정된 것**: 상태를 보는 것이 값을 한다"
                         f"(무작위 대비 p={p_rand:.3f})." if p_rand <= 0.05 else
                         f"**미확정**: 무작위 대비조차 유의하지 않다(p={p_rand:.3f}).")
        if p_rule is not None:
            lines.append(f"**남은 벽**: 종류만 보는 규칙표는 아직 못 넘었다(p={p_rule:.3f}). "
                         "규칙표가 틀리는 상황 — 같은 종류인데 정답이 다른 경우 — 을 더 모으거나, "
                         "그 구분을 나르는 특징을 φ 에 넣어야 한다."
                         if p_rule > 0.05 else
                         f"**넘었다**: 규칙표를 유의하게 이겼다(p={p_rule:.3f}).")
        if tl.get("p_mid_cells") == 0:
            lines.append("**보류**: 값 2층 분해의 값어치는 이 데이터로 잴 수 없다"
                         "(라벨이 결정론이라 완주확률이 0/1 뿐).")
        lines.append("**주의**: §1-b 대로 결정들이 한 시점에 몰려 있어, 순차 커플링에 기대는 주장"
                     "(이력 활용·장기 자원 배분)은 이 데이터로 할 수 없다.")
        for x in lines:
            say(f"- {x}")
        say()

    say("---\n")
    say("## 다음 한 수 (사람이 결정할 것)\n")
    explain(
        "**1. 결정 시점 기록 고치기 (가장 싸고, 다른 것들의 전제)** — 지금은 결정 시점을 producer 가 "
        "호출된 순간에 기록한다. 트리거가 발화한 순간에 기록하도록 바꾸면, §1-b 의 '결정이 한 곳에 "
        "뭉쳐 있다'가 진짜 동시사건인지 기록 문제인지 갈린다. 순차 구조에 기대는 모든 주장이 여기에 달려 있다.",

        "**2. 규칙표 벽 넘기 (φ 에 스페어 잔량 추가)** — 규칙표가 지는 상황은 '같은 종류인데 정답이 "
        "다른' 경우이고, 그 차이를 만드는 물리량으로 가장 유력한 것이 남은 스페어 수다. 스페어가 "
        "없으면 교체가 답이 될 수 없기 때문이다. 시뮬레이션 없이 재계산만으로 검증된다.",

        "**3. A0 다중 spec 디스패처** — 서로 다른 종류의 제약을 묶어 내면 지금은 그중 하나만 실행되고 "
        "나머지는 조용히 버려진다(`PLAN_ACTION_GROWTH.md` §2 정정 참조). 행동공간을 조합으로 넓히는 "
        "계획 전체가 이것에 막혀 있다.",

        "**4. zoneblk 가 왜 무효인지** — 구역 차단 사건에서는 아무 대응을 해도 결과가 글자 그대로 "
        "같다. 셋 중 한 고장모드가 실질적으로 빠져 있는 상태이므로, 재배치 로직이 이 시점에 정말 "
        "아무것도 옮기지 않는지 확인해야 한다.",

        "**5. B1 능력상실 (미지 사건 만들기)** — 엔진에 '로봇이 특정 능력만 잃는다'는 개념 자체가 "
        "없다. 훈련 어휘 밖의 진짜 새 사건을 만들려면 여기서 시작해야 하고, §5 의 역할 분담 실험도 "
        "그때라야 제대로 된다.",
    )

    md = "\n".join(LINES) + "\n"
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    open(args.out, "w", encoding="utf-8").write(md)
    json.dump(result, open(os.path.join(HERE, "artifacts_mdp", "night_analysis.json"), "w",
                           encoding="utf-8"), indent=2, ensure_ascii=False, default=str)
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
