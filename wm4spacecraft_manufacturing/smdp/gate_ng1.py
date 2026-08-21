#!/usr/bin/env python3
"""게이트 N-G1 — `sample_sojourn` 이 `hazard_step!` 의 dt-루프와 **같은 분포**를 내는가.

근사 검사가 아니다. spec §2-2 가 정확 표집을 주장하므로 KS 검정이 통과해야 한다.
떨어지면 넷 중 하나다:
  (a) 닫힌 형태가 틀렸다
  (b) advance_to_rate_boundary / 드레인이 usage·soc·스케줄을 엔진과 다르게 굴린다
  (c) 🔴 D-6 의 rate boundary 근사가 분포를 흔든다        ← 이 세대가 새로 만든 후보
  (d) 아직 못 닫은 유예 기전이 있다(spec §2-5, `_hz_safe_target` — 이 게이트는 **교차**를
      재므로 설계상 (d) 를 재지 않는다)
  진단 순서: (c) 를 먼저 본다. rho 를 바꿔 가며 KS 가 단조로 움직이면 (c) **가 기여한다**.
  ⚠️ 단조성은 (c) 를 **배타적으로** 지목하지 못한다 — `dur == 0` 드레인의 시간 비용도 같은
     방향("경량이 스케줄을 너무 빨리 민다")으로 읽힌다. 둘을 가르려면 드레인 비용을 ρ 와
     **독립적으로** 흔드는 별도 프로브가 필요하다(Task T10).

🔴 **이 게이트가 초록이 되는 방식 두 가지 중 하나는 가짜다.**
   (i) 두 레인이 실제로 같다.  (ii) 표본이 적어서 아무것도 분해하지 못한다.
   (ii) 를 막는 것이 아래 RESOLUTION 검사다 — **초록을 선언하기 전에 게이트가 자기 분해능이
   목표치보다 고운지를 먼저 단언한다.** 목표치 `c*` 는 어떤 측정값에서도 오지 않고 지수분포의
   항등식과 `_mode_mult` 의 인접 배수비에서 유도된다(생성기 헤더 참조):

       g(c) = sup_u |e^(-cu) - e^(-u)| = c^(-1/(c-1)) - c^(-c/(c-1))
       D_crit(alpha, n1, n2) = K_alpha * sqrt(1/n1 + 1/n2)
       분해 가능  <=>  D_crit <= g(c*)

   ⚠️ 브리프의 `n >= 200` 판은 이 검사를 통과하지 못한다: n=200/200 이면 D_crit = 0.16276 이고
      그것이 분해하는 것은 c ~ 1.562 (= 56% 격차)다 — D-6 이 만들 수 있는 어떤 현실적 오차보다도
      굵다. **초록이 증거가 아니게 된다.**

🔴 **`--expect-fail` 의 계약(수정 1라운드).** 음성 대조에서 "빨간불" 은 **벌어야 한다.**
   분해능이 모자라서 나온 빨간불은 음성 대조의 성공이 **아니다** — 그건 게이트가 아무것도
   못 본 것이다. 그래서 expect-fail 성공 조건은 다음 **전부**다:
       위생 통과  ∧  RESOLUTION 통과  ∧  사건종류 통과  ∧  **분포 검정만 빨강**
   앞의 셋 중 하나라도 빨가면 종료코드는 **non-zero** 다.

사용:
  python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py results/smdp/ng1_pairs.json
  python3 wm4spacecraft_manufacturing/smdp/gate_ng1.py --expect-fail results/smdp/ng1_selfneg_cstar.json
자기 시험:
  python3 wm4spacecraft_manufacturing/smdp/test_gate_ng1.py
"""
import argparse, json, math, sys

from scipy.stats import ks_2samp, kstwobign

ALPHA = 0.01                       # 위험 예산. 낮게 잡는다
# 🔴 손으로 옮긴 리터럴을 두지 않는다(수정 1라운드, minor 3). 여기서는 scipy 로,
#    생성기(Julia)에서는 Kolmogorov 급수 이분법으로 **각자 유도**하고, 아래에서 둘을 대조한다.
#    한쪽이 다른 쪽을 베끼는 단일 출처보다 강하다 — 독립 유도 두 개 + 교차검증이다.
K_ALPHA = float(kstwobign.ppf(1.0 - ALPHA))
KS_METHOD = "asymp"                # ks_2samp 의 귀무분포. 아래 출력에 이름을 찍는다
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


def _tie_mass(v, tol=1e-12):
    """최댓값에 몰려 있는 관측 수 (= 관측창 검열 원자). KS 귀무분포의 전제와 관련된다."""
    m = max(v)
    return sum(1 for x in v if x >= m - tol), m


def main(path, expect_fail):
    d = json.load(open(path))
    light, heavy = d["light_tau"], d["heavy_tau"]
    lk, hk = d["light_kinds"], d["heavy_kinds"]
    meta = d.get("meta", {})
    n1, n2 = len(light), len(heavy)
    f_sanity, f_res, f_kinds, f_dist = [], [], [], []

    print(f"lane={meta.get('lane','?')} perturb_c={meta.get('perturb_c')} "
          f"probe_step={meta.get('probe_step')} global_mode={meta.get('global_mode')} "
          f"horizon_s={meta.get('horizon_s')} dt_sim={meta.get('dt_sim')}")

    # --- 0. 위생 ------------------------------------------------------------
    if min(light) <= 0 or min(heavy) <= 0:
        f_sanity.append("tau <= 0 이 있다")
    if meta.get("heavy_events_fired", 0) != 0:
        f_sanity.append(f"무거운 레인에서 사건이 {meta['heavy_events_fired']} 개 발화했다 "
                        "— 궤적이 '사건 이전의 세계'가 아니다")
    if "terminal" in lk:
        f_sanity.append(f"경량 레인에 terminal 이 {lk.count('terminal')} 개 있다 — 픽스처가 "
                        "관측창 안에서 DAG 를 소진한다. 두 레인이 같은 사건공간이 아니다")

    # --- 1. 🔴 분해능 (초록을 선언할 자격이 있는가) --------------------------
    # 🔴 `c_star` 를 **믿지 않는다**(수정 1라운드, minor 2). 예전 판은 `sup_gap(c_star)` 를
    #    meta 의 값과 대조했는데 그건 **어떤 c_star 로도 성립하는 항등식**이라 아무것도 안
    #    막았다. 부풀린 c_star 가 든 아티팩트는 분해능 문턱을 조용히 낮췄을 것이다.
    #    이제 meta 가 이미 나르고 있는 원재료(`r_min`·`n_fleet`)에서 **다시 유도해** 대조한다.
    c_star = meta.get("c_star")
    r_min, n_fleet = meta.get("r_min"), meta.get("n_fleet")
    if c_star is None or r_min is None or n_fleet is None:
        f_res.append("meta 에 c_star/r_min/n_fleet 이 없다 — 분해능을 검증할 수 없다")
        c_star = c_star or 1.0 + 1e-9
    else:
        c_star_derived = ((n_fleet - 1) + r_min) / n_fleet
        if abs(c_star - c_star_derived) > 1e-12:
            f_res.append(f"c_star={c_star!r} 가 (n_fleet={n_fleet}, r_min={r_min}) 에서 "
                         f"유도한 {c_star_derived!r} 와 다르다 — 아티팩트가 변조됐거나 낡았다")
    g_star = sup_gap(c_star)
    d_crit = K_ALPHA * math.sqrt(1.0 / n1 + 1.0 / n2)
    c_res = resolved_c(d_crit)
    n_req = math.ceil(2.0 * (K_ALPHA / g_star) ** 2) if g_star > 0 else float("inf")
    print(f"RESOLUTION n1={n1} n2={n2} c_star={c_star:.6f} g(c_star)={g_star:.6f} "
          f"D_crit={d_crit:.6f} resolves_c>={c_res:.6f} n_required={n_req}")
    # 🔴 **`n_required` 는 필요조건이지 충분조건이 아니다** (수정 1라운드에 이 게이트의 자기
    #    시험이 잡아냈다). `n = 2(K/g)²` 는 `D_crit == g(c*)` 가 되는 지점이고, KS 통계량은
    #    확률변수이므로 그 자리에서 검정력은 **약 50%** 다 — 참 격차가 정확히 c* 인 표본이
    #    임계값 아래로 떨어지는 일이 절반쯤 일어난다(합성 지수쌍 실측: KS 0.0164 < 0.0237).
    #    그래서 이 게이트가 `n_required` 로 주장할 수 있는 것은 **"이보다 적으면 c* 를 원리적으로
    #    기각할 수 없다"** 뿐이다. 여유 있는 탐지를 원하면 유도된 격차가 임계값의 2배가 되는
    #    `4·n_required` 가 필요하다(엄밀한 검정력 계산은 하지 않았다 — 여백 규칙이다).
    print(f"POWER n_threshold={n_req} (D_crit == g(c*), ~50% power) "
          f"n_for_2x_margin={4 * n_req if n_req != float('inf') else 'inf'} "
          f"regime={'below-threshold' if d_crit > g_star else 'at-or-above-threshold'} "
          "-- n_required is NECESSARY, not sufficient")
    # 🔴 두 독립 유도의 교차검증(scipy 의 `kstwobign` vs 생성기의 Kolmogorov 급수 이분법).
    #    실측: 두 유도는 **2.2e-16 로 일치한다**(기계 오차). 그런데 허용치를 1e-7 로 둔 이유는
    #    따로 있다 — **이미 커밋된 아티팩트**들이 수정 1라운드 이전의 손으로 옮긴 리터럴
    #    `1.6276236012099228` 을 meta 에 나르고 있고, 그 값은 참값에서 **1.03e-8** 벗어나 있다
    #    (즉 낡은 리터럴 쪽이 틀렸었다). 그 아티팩트는 N-G1 판정의 유일한 durable 기록이라
    #    재생성하지 않는다.
    #    그 오차가 판정에 주는 영향(유도): n ∝ K² 이므로 상대변화 2·6.3e-9 ≈ 1.3e-8,
    #    n = 9403 에서 **1.2e-4 개** — `ceil` 을 못 넘기므로 n 도 D_crit 도 실질적으로 불변이다.
    #    1e-7 은 그 낡은 리터럴을 받아들이면서 실제 실수(자릿수 오타·다른 α)는 전부 걸러낸다.
    k_meta = meta.get("k_alpha")
    if k_meta is not None and abs(k_meta - K_ALPHA) > 1e-7:
        f_res.append(f"K_alpha 불일치: 생성기 {k_meta!r} vs scipy {K_ALPHA!r} "
                     "— 두 독립 유도가 갈렸다")
    if d_crit > g_star:
        f_res.append(f"게이트가 c*={c_star:.4f} 를 분해하지 못한다 "
                     f"(D_crit={d_crit:.4f} > g={g_star:.4f}, n>={n_req} 필요). "
                     "표본이 모자라서 나온 초록도, 빨강도 증거가 아니다")

    # --- 2. 🔴 이슈 D — 두 레인이 **셋** 다 낸다 -----------------------------
    ls, hs = set(lk) & FAILURE_KINDS, set(hk) & FAILURE_KINDS
    print(f"kind mix light={sorted(set(lk))} heavy={sorted(set(hk))}")
    for name, s in (("light", ls), ("heavy", hs)):
        missing = FAILURE_KINDS - s
        if missing:
            f_kinds.append(f"{name} 레인에 위험 {sorted(missing)} 이 없다 (이슈 D: "
                           "2위험 표집기와 3위험 엔진을 비교하게 된다)")
    if ls != hs:
        f_kinds.append(f"두 레인의 사건 종류 집합이 다르다: {sorted(ls)} vs {sorted(hs)}")

    # --- 3. 분포 -------------------------------------------------------------
    st, p = ks_2samp(light, heavy, method=KS_METHOD)
    ml, mh = sorted(light)[n1 // 2], sorted(heavy)[n2 // 2]
    c_hat = mh / ml if ml > 0 else float("inf")     # 지수 근사: 중앙값 비 = Lambda 배수
    tl, xl = _tie_mass(light)
    th, xh = _tie_mass(heavy)
    print(f"KS={st:.6f} p={p:.4g} alpha={ALPHA} method={KS_METHOD} "
          f"K_alpha={K_ALPHA:.10f}(scipy.kstwobign.ppf)")
    print(f"median light={ml:.6f} heavy={mh:.6f}  implied_Lambda_ratio c_hat={c_hat:.6f}")
    print(f"censored(horizon) light={lk.count('horizon')} heavy={hk.count('horizon')}")
    # ⚠️ 관측창 검열은 `tau = H` 에 **원자(tie)** 를 만든다. `ks_2samp` 의 점근 귀무분포는
    #    연속 분포를 전제하므로 그 질량 아래에서는 **근사**다(보수적인 쪽). 판정을 바꿀 만한
    #    크기가 아니더라도 방법과 질량을 함께 찍는다 — 안 찍으면 다음 사람이 모른다.
    print(f"tie_mass_at_max light={tl}/{n1}@{xl:.6f} heavy={th}/{n2}@{xh:.6f} "
          "(asymptotic null assumes continuity; tie mass makes it approximate)")
    if p < ALPHA:
        f_dist.append(f"두 분포가 갈린다 (p={p:.4g} < {ALPHA}, KS={st:.4f}, "
                      f"관측 격차 c_hat={c_hat:.4f})")

    for f in f_sanity + f_res + f_kinds + f_dist:
        print("FAIL: " + f)
    healthy = not (f_sanity or f_res or f_kinds)
    ok = healthy and not f_dist
    print("PASS" if ok else "FAIL")

    if not expect_fail:
        return 0 if ok else 1

    # 🔴 음성 대조 모드 — 빨간불은 **벌어야 한다**.
    if not healthy:
        print("[expect-fail] 🔴 빨간불이 분포 때문이 아니다 — 위생/분해능/사건종류가 먼저 "
              "깨졌다. 아무것도 못 보는 게이트의 빨간불은 음성 대조의 성공이 아니다")
        return 1
    if not f_dist:
        print("[expect-fail] 🔴 게이트가 섭동을 못 잡았다")
        return 1
    print("[expect-fail] OK — 게이트가 **건강한 상태에서** 이 섭동을 잡았다")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--expect-fail", action="store_true",
                    help="음성 대조: **분포 검정만** 빨개져야 성공(0). 분해능/위생/종류가 "
                         "깨져서 나온 빨간불은 실패(non-zero)")
    a = ap.parse_args()
    sys.exit(main(a.path, a.expect_fail))
