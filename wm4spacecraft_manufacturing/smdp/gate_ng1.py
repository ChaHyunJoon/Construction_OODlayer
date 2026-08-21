#!/usr/bin/env python3
"""게이트 N-G1 — `sample_sojourn` 이 `hazard_step!` 의 dt-루프와 **같은 분포**를 내는가.

근사 검사가 아니다. spec §2-2 가 정확 표집을 주장하므로 KS 검정이 통과해야 한다.
떨어지면 넷 중 하나다:
  (a) 닫힌 형태가 틀렸다
  (b) advance_to_rate_boundary 가 usage/soc 를 엔진과 다르게 굴린다
  (c) 🔴 D-6 의 rate boundary 근사가 분포를 흔든다        ← 이 세대가 새로 만든 후보
  (d) 아직 못 닫은 유예 기전이 있다(spec §2-5, `_hz_safe_target`)
  진단 순서: (c) 를 먼저 본다. rho 를 바꿔 가며 KS 가 단조로 움직이면 (c) 다.

🔴 **이 게이트가 초록이 되는 방식 두 가지 중 하나는 가짜다.**
   (i) 두 레인이 실제로 같다.  (ii) 표본이 적어서 아무것도 분해하지 못한다.
   (ii) 를 막는 것이 아래의 `RESOLUTION` 검사다 — **초록을 선언하기 전에 게이트가 자기
   분해능이 목표치보다 고운지를 먼저 단언한다.** 목표치 `c*` 는 어떤 측정값에서도 오지 않고
   지수분포의 항등식과 `_mode_mult` 의 인접 배수비에서 유도된다(생성기 헤더 참조):

       g(c) = sup_u |e^(-cu) - e^(-u)| = c^(-1/(c-1)) - c^(-c/(c-1))
       D_crit(alpha, n1, n2) = K_alpha * sqrt(1/n1 + 1/n2)
       분해 가능  <=>  D_crit <= g(c*)

   ⚠️ 브리프의 `n >= 200` 판은 이 검사를 통과하지 못한다: n=200/200 이면
      D_crit = 0.1628 이고 그것이 분해하는 것은 c ~ 1.57 (= 57% 격차)다. 즉 D-6 이 만들
      수 있는 어떤 현실적 오차보다도 굵다 — **초록이 증거가 아니게 된다.**

  python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
  python3 ... --expect-fail results/smdp/ng1_pairs_neg_cstar.json     # 음성 대조
"""
import argparse, json, math, sys

from scipy.stats import ks_2samp

ALPHA = 0.01                       # 위험 예산. 낮게 잡는다
K_ALPHA = 1.6276236012099228       # KS 점근 임계계수 @ alpha = 0.01
FAILURE_KINDS = {"break", "cell", "zone"}


def sup_gap(c):
    """배수 c 만큼 어긋난 두 지수 생존함수의 최대 간격."""
    if c == 1.0:
        return 0.0
    return c ** (-1.0 / (c - 1.0)) - c ** (-c / (c - 1.0))


def resolved_c(d_crit):
    """D_crit 을 정확히 메우는 c (= 이 표본수가 분해할 수 있는 가장 작은 격차)."""
    lo, hi = 1.0 + 1e-12, 100.0
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if sup_gap(mid) < d_crit:
            lo = mid
        else:
            hi = mid
    return hi


def main(path, expect_fail):
    d = json.load(open(path))
    light, heavy = d["light_tau"], d["heavy_tau"]
    lk, hk = d["light_kinds"], d["heavy_kinds"]
    meta = d.get("meta", {})
    n1, n2 = len(light), len(heavy)
    fails = []

    print(f"lane={meta.get('lane','?')} perturb_c={meta.get('perturb_c')} "
          f"probe_step={meta.get('probe_step')} global_mode={meta.get('global_mode')} "
          f"horizon_s={meta.get('horizon_s')} dt_sim={meta.get('dt_sim')}")

    # --- 0. 위생 ------------------------------------------------------------
    if min(light) <= 0 or min(heavy) <= 0:
        fails.append("tau <= 0 이 있다")
    if meta.get("heavy_events_fired", 0) != 0:
        fails.append(f"무거운 레인에서 사건이 {meta['heavy_events_fired']} 개 발화했다 "
                     "— 궤적이 '사건 이전의 세계'가 아니다")
    if "terminal" in lk:
        fails.append(f"경량 레인에 terminal 이 {lk.count('terminal')} 개 있다 — 픽스처가 "
                     "관측창 안에서 DAG 를 소진한다. 두 레인이 같은 사건공간이 아니다")

    # --- 1. 🔴 분해능 (초록을 선언할 자격이 있는가) --------------------------
    c_star = meta["c_star"]
    g_star = sup_gap(c_star)
    d_crit = K_ALPHA * math.sqrt(1.0 / n1 + 1.0 / n2)
    c_res = resolved_c(d_crit)
    n_req = math.ceil(2.0 * (K_ALPHA / g_star) ** 2)
    print(f"RESOLUTION n1={n1} n2={n2} c_star={c_star:.6f} g(c_star)={g_star:.6f} "
          f"D_crit={d_crit:.6f} resolves_c>={c_res:.6f} n_required={n_req}")
    if abs(g_star - meta.get("sup_gap_at_c_star", g_star)) > 1e-12:
        fails.append("생성기와 게이트의 g(c*) 가 다르다 — 유도가 어긋났다")
    if d_crit > g_star:
        fails.append(f"게이트가 c*={c_star:.4f} 를 분해하지 못한다 "
                     f"(D_crit={d_crit:.4f} > g={g_star:.4f}, n>={n_req} 필요). "
                     "표본이 모자라서 나온 초록은 증거가 아니다")

    # --- 2. 🔴 이슈 D — 두 레인이 **셋** 다 낸다 -----------------------------
    ls, hs = set(lk) & FAILURE_KINDS, set(hk) & FAILURE_KINDS
    print(f"kind mix light={sorted(set(lk))} heavy={sorted(set(hk))}")
    for name, s in (("light", ls), ("heavy", hs)):
        missing = FAILURE_KINDS - s
        if missing:
            fails.append(f"{name} 레인에 위험 {sorted(missing)} 이 없다 (이슈 D: "
                         "2위험 표집기와 3위험 엔진을 비교하게 된다)")
    if ls != hs:
        fails.append(f"두 레인의 사건 종류 집합이 다르다: {sorted(ls)} vs {sorted(hs)}")

    # --- 3. 분포 -------------------------------------------------------------
    st, p = ks_2samp(light, heavy)
    ml, mh = sorted(light)[n1 // 2], sorted(heavy)[n2 // 2]
    c_hat = mh / ml if ml > 0 else float("inf")     # 지수 근사: 중앙값 비 = Lambda 배수의 역
    print(f"KS={st:.6f} p={p:.4g} alpha={ALPHA}")
    print(f"median light={ml:.6f} heavy={mh:.6f}  implied_Lambda_ratio c_hat={c_hat:.6f}")
    print(f"censored(horizon) light={lk.count('horizon')} heavy={hk.count('horizon')}")
    if p < ALPHA:
        fails.append(f"두 분포가 갈린다 (p={p:.4g} < {ALPHA}, KS={st:.4f}, "
                     f"관측 격차 c_hat={c_hat:.4f})")

    ok = not fails
    for f in fails:
        print("FAIL: " + f)
    print("PASS" if ok else "FAIL")
    if expect_fail:
        # 음성 대조 모드: **빨간불이 나와야** 종료코드 0.
        print("[expect-fail] " + ("OK — 게이트가 이 섭동을 잡았다" if not ok
                                  else "🔴 게이트가 섭동을 못 잡았다"))
        return 0 if not ok else 1
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--expect-fail", action="store_true",
                    help="음성 대조: 빨간불이 나와야 성공(0)")
    a = ap.parse_args()
    sys.exit(main(a.path, a.expect_fail))
