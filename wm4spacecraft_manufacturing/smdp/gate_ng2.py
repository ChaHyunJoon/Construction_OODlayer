#!/usr/bin/env python3
"""게이트 N-G2 — ρ 보정 뒤 `T_plan` 의 편향이 **팔 간 비교를 뒤집는가**.

정확도 게이트가 **아니다**(설계 §11-3 / N-4-4). 경량 모델은 3계층 reactive 스택
(TangentBug→PotentialField→RVO2)을 아예 돌리지 않으므로 절대값은 틀린다 — 그건 결함이 아니라
선언된 근사다. 물어야 할 것은 하나뿐이다:

    같은 사건에서 **경량 모델이 매기는 팔 순위**가 **무거운 레인의 순위**와 같은가.

  python3 wm4spacecraft_manufacturing/smdp/gate_ng2.py results/smdp/rho.json \
          results/smdp/arm_ranks.json
자기 시험:
  python3 wm4spacecraft_manufacturing/smdp/test_gate_ng2.py

────────────────────────────────────────────────────────────────────────────────
🔴 **이 게이트가 초록이 되는 방식 두 가지 중 하나는 가짜다** (N-G1 의 RESOLUTION 검사와
   같은 자리, 같은 이유):

   (i)  경량 모델이 정말로 무거운 레인과 같은 순위를 매긴다.
   (ii) **팔들이 서로 구분되지 않아서** 어느 순위든 τ = 1 이 나온다.

   (ii) 는 이 레포에서 **실제로 일어난 적이 있다**: 조합 팔 5·6 이 65/65 instance 에서
   `5≡4`, `6≡2` 였고(추가 primitive 가 엔진에서 집행되지 않아서), 그 사실이 성능으로만 샜다.
   그래서 이 게이트는 **순위를 보기 전에 팔이 실제로 갈리는지를 먼저 단언한다.** 갈리지
   않으면 초록도 빨강도 아니고 **"분해 불가"** 로 죽는다.

   그러므로 산출물은 **순위만이 아니라 점수(score)** 를 실어야 한다. 순위만 있으면 동점을
   볼 수 없고, 동점을 못 보면 (ii) 를 못 막는다. 순위만 있는 산출물은 거부한다.

🔴 **어휘 도장.** 팔 id 는 `core/action_registry.json`(`vocab`) 의 것이어야 한다. 2026-08-20
   재번호(0..3) 이후 구세대 행이 **조용히** 유효 id 로 읽히므로 도장이 유일한 방어선이다.

⚠️ `rho.json` 의 `ratio_p90/ratio_p10 > 3` 이면 **스칼라 ρ 하나로 부족하다**(spec §10 미해결
   5번: 혼잡은 활성 로봇 수에 의존할 수 있다). 그 사실을 출력에 적는다 — 이 게이트의 판정
   기준은 아니지만, N-G2 가 초록이어도 그 문장은 참일 수 있고 다음 사람이 알아야 한다.
────────────────────────────────────────────────────────────────────────────────
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "core"))
import wmpath                    # noqa: E402,F401  (코드 폴더 전부를 sys.path 에 올린다)
import action_registry as AR     # noqa: E402

from scipy.stats import kendalltau   # noqa: E402

MIN_TAU = 0.6            # 순위상관 하한 (브리프 지정)
MAX_TOP1_FLIP = 0.10     # top-1 이 뒤집히는 사건의 비율 상한 (브리프 지정)
SPREAD_LIMIT = 3.0       # rho.json 의 p90/p10 이 이걸 넘으면 스칼라 ρ 로 부족 (브리프 Step 4)
TIE_TOL = 1e-12          # 점수 동점 판정 허용오차 (상대)


def _distinct(vals, tol=TIE_TOL):
    """상대 허용오차 `tol` 아래로 같은 값들을 하나로 뭉친 개수."""
    out = []
    for v in sorted(float(x) for x in vals):
        if not out or abs(v - out[-1]) > tol * max(1.0, abs(v), abs(out[-1])):
            out.append(v)
    return len(out)


def _rank_of(scores, lower_is_better):
    """점수 벡터 → 팔 인덱스를 좋은 순으로 늘어놓은 순위 벡터(결정적: 동점은 인덱스 순)."""
    idx = list(range(len(scores)))
    idx.sort(key=lambda i: (float(scores[i]) if lower_is_better else -float(scores[i]), i))
    return idx


def main(rho_path, ranks_path):
    f_sanity, f_res, f_rank = [], [], []

    # --- 0. ρ 산출물 ---------------------------------------------------------
    rho = json.load(open(rho_path, encoding="utf-8"))
    for k in ("rho", "ratio_p10", "ratio_p90", "n_nodes"):
        if k not in rho:
            f_sanity.append("rho.json 에 %r 가 없다" % k)
    if f_sanity:
        for f in f_sanity:
            print("FAIL: " + f)
        print("FAIL")
        return 1
    print("rho=%.3f  ratio p10/p90 = %.2f/%.2f  n_nodes=%d  rule=%s"
          % (rho["rho"], rho["ratio_p10"], rho["ratio_p90"], rho["n_nodes"],
             rho.get("fit_rule", "?")))
    spread = (rho["ratio_p90"] / rho["ratio_p10"]) if rho["ratio_p10"] > 0 else float("inf")
    print("SPREAD ratio_p90/ratio_p10=%.3f limit=%.1f -> %s"
          % (spread, SPREAD_LIMIT,
             "🔴 스칼라 ρ 하나로 부족하다 (spec §10 미해결 5번; 혼잡도 의존 ρ 는 후속 작업)"
             if spread > SPREAD_LIMIT else "스칼라 ρ 로 덮인다"))
    if not rho.get("meta", {}).get("ng1_consulted", True) is False:
        # meta.ng1_consulted 가 없거나 True 면 경고. False 여야 "게이트에 맞춘 교정이 아니다".
        print("WARN: rho.json 이 `meta.ng1_consulted = false` 를 선언하지 않는다 — "
              "이 ρ 가 N-G1 을 보고 만들어진 값이 아님을 산출물이 주장하지 않는다")

    # --- 1. 순위 산출물 ------------------------------------------------------
    if not os.path.exists(ranks_path):
        print("FAIL: 순위 산출물이 없다: %s" % ranks_path)
        print("      N-G2 는 사건마다 (경량 점수, 무거운 점수) 짝을 요구한다. 그 짝을 만들려면")
        print("      `(s, a) -> s⁺` 가 필요하고, 그것은 **Task T13 의 생성 시뮬레이터**다.")
        print("      🔴 없는 짝을 지어내서 초록을 만들지 않는다 — 그건 이 게이트가 막으려는 것이다.")
        print("FAIL")
        return 1
    d = json.load(open(ranks_path, encoding="utf-8"))
    meta = d.get("meta", {})

    # 어휘 도장 — 없거나 다르면 여기서 죽는다(remap 하지 않는다).
    try:
        AR.require_vocab(meta, ranks_path)
    except ValueError as e:
        f_res.append(str(e))
    for k in ("light_score", "heavy_score", "lower_is_better"):
        if k not in meta:
            f_res.append("meta 에 %r 가 없다 — 무엇을 순위 매겼는지 모르는 채로 판정하지 않는다"
                         % k)
    events = d.get("events") or []
    if not events:
        f_res.append("events 가 비어 있다")
    print("ranks: n_events=%d vocab=%r light_score=%r heavy_score=%r lower_is_better=%r"
          % (len(events), meta.get("vocab"), meta.get("light_score"),
             meta.get("heavy_score"), meta.get("lower_is_better")))

    # --- 2. 🔴 분해능: 팔이 실제로 갈리는가 ----------------------------------
    lower = bool(meta.get("lower_is_better", True))
    n_tied_light = n_tied_heavy = 0
    n_arms_seen = set()
    for i, ev in enumerate(events):
        ls, hs = ev.get("light_score"), ev.get("heavy_score")
        if ls is None or hs is None:
            f_res.append("사건 %d 에 점수 벡터가 없다 — 순위만으로는 동점을 볼 수 없고, "
                         "동점을 못 보면 '팔이 안 갈려서 나온 초록'을 막지 못한다" % i)
            continue
        if len(ls) != len(hs):
            f_res.append("사건 %d 의 두 점수 벡터 길이가 다르다 (%d vs %d)" % (i, len(ls), len(hs)))
            continue
        if len(ls) < 2:
            f_res.append("사건 %d 의 팔이 %d 개다 — 순위를 매길 것이 없다" % (i, len(ls)))
            continue
        arms = ev.get("arms")
        if arms is None or len(arms) != len(ls):
            f_res.append("사건 %d 에 `arms`(팔 id 벡터)가 없거나 길이가 안 맞는다" % i)
        else:
            for a in arms:
                n_arms_seen.add(int(a))
                if not AR.is_active(int(a)):
                    f_res.append("사건 %d 의 팔 id %r 가 현행 어휘(%s)의 활성 팔이 아니다"
                                 % (i, a, AR.VOCAB))
        if any(not math.isfinite(float(x)) for x in list(ls) + list(hs)):
            f_res.append("사건 %d 의 점수에 비유한 값이 있다 — 0 으로 때우지 않는다" % i)
            continue
        if _distinct(ls) < 2:
            n_tied_light += 1
        if _distinct(hs) < 2:
            n_tied_heavy += 1
    print("RESOLUTION arms_seen=%s n_events_light_all_tied=%d n_events_heavy_all_tied=%d"
          % (sorted(n_arms_seen), n_tied_light, n_tied_heavy))
    if n_tied_light:
        f_res.append("경량 레인이 %d/%d 사건에서 팔을 **전혀 구분하지 못한다**(전부 동점). "
                     "그 사건의 τ 는 팔 순위가 아니라 동점 규칙을 잰다. 초록도 빨강도 증거가 "
                     "아니다" % (n_tied_light, len(events)))
    if n_tied_heavy:
        f_res.append("무거운 레인이 %d/%d 사건에서 팔을 전혀 구분하지 못한다(전부 동점) — "
                     "팔이 엔진에서 집행되지 않았을 때의 모양이다(조합 팔 5≡4·6≡2 의 재발)"
                     % (n_tied_heavy, len(events)))

    # --- 3. 순위 일치 --------------------------------------------------------
    taus, flips, n_used = [], 0, 0
    for ev in events:
        ls, hs = ev.get("light_score"), ev.get("heavy_score")
        if ls is None or hs is None or len(ls) != len(hs) or len(ls) < 2:
            continue
        lr = ev.get("light_rank") or _rank_of(ls, lower)
        hr = ev.get("heavy_rank") or _rank_of(hs, lower)
        t, _ = kendalltau(lr, hr)
        if t is None or (isinstance(t, float) and math.isnan(t)):
            f_rank.append("사건의 Kendall tau 가 NaN 이다(상수 순위) — 위 RESOLUTION 참조")
            continue
        taus.append(float(t))
        n_used += 1
        if lr[0] != hr[0]:
            flips += 1
    if not taus:
        f_res.append("쓸 수 있는 사건이 하나도 없다 — 판정할 것이 없다")
        med, frac = float("nan"), float("nan")
    else:
        med = sorted(taus)[len(taus) // 2]
        frac = flips / n_used
        print("n_events=%d used=%d median kendall tau=%.3f top1_flip=%.1f%%"
              % (len(events), n_used, med, 100.0 * frac))
        if med < MIN_TAU:
            f_rank.append("tau %.3f < %s" % (med, MIN_TAU))
        if frac > MAX_TOP1_FLIP:
            f_rank.append("top1_flip %.1f%% > %.0f%%" % (100.0 * frac, 100.0 * MAX_TOP1_FLIP))

    for f in f_sanity + f_res + f_rank:
        print("FAIL: " + f)
    healthy = not (f_sanity or f_res)
    ok = healthy and not f_rank
    if not healthy:
        print("🔴 분해 불가 — 이 게이트는 지금 아무것도 못 본다. 초록도 빨강도 증거가 아니다.")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("rho_path")
    ap.add_argument("ranks_path")
    a = ap.parse_args()
    sys.exit(main(a.rho_path, a.ranks_path))
