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
   ⚠️ 반대로 `n_required` 를 채웠다고 `c*` 가 **반드시** 잡히는 것도 아니다(아래 POWER 주석).

🔴 **`--expect-fail` 의 계약(수정 1라운드).** 음성 대조에서 "빨간불" 은 **벌어야 한다.**
   분해능이 모자라서 나온 빨간불은 음성 대조의 성공이 **아니다** — 그건 게이트가 아무것도
   못 본 것이다. 그래서 expect-fail 성공 조건은 다음 **전부**다:
       위생 통과  ∧  RESOLUTION 통과  ∧  사건종류 통과  ∧  **분포 검정만 빨강**
   앞의 셋 중 하나라도 빨가면 종료코드는 **non-zero** 다.

사용:
  python3 tools/smdp/gate_ng1.py results/smdp/ng1_pairs.json
  python3 tools/smdp/gate_ng1.py --expect-fail results/smdp/ng1_selfneg_cstar.json
자기 시험:
  python3 tools/smdp/test_gate_ng1.py
"""
import argparse, json, math, sys

from scipy.stats import ks_2samp, kstwobign, norm

ALPHA = 0.01                       # 위험 예산. 낮게 잡는다
# 🔴 손으로 옮긴 리터럴을 두지 않는다(수정 1라운드, minor 3). 여기서는 scipy 로,
#    생성기(Julia)에서는 Kolmogorov 급수 이분법으로 **각자 유도**하고, 아래에서 둘을 대조한다.
#    한쪽이 다른 쪽을 베끼는 단일 출처보다 강하다 — 독립 유도 두 개 + 교차검증이다.
K_ALPHA = float(kstwobign.ppf(1.0 - ALPHA))
KS_METHOD = "asymp"                # ks_2samp 의 귀무분포. 아래 출력에 이름을 찍는다
FAILURE_KINDS = {"break", "cell", "zone"}


# =============================================================================
# 🔴 N-G1′ — 검열을 통계량에서 분리한다 (사용자 결정 D-12, 2026-08-21)
#
# **왜.** 적합 rho 에서 이 게이트의 혼합 KS 중 **80.7~98.1 %** 가 관측창 끝의 검열 원자
# 하나다(실측: light 1738/9403 vs heavy 836/9403 → |Δp| = 0.0959 = KS 0.1189 의 80.7 %).
# 즉 "두 레인의 sojourn 분포가 같은가" 를 잰다고 주장하면서 실제로 재는 것의 대부분은
# **"20 초에서 누가 더 많이 살아남았는가"** 하나다. FAIL 이 나와도 분포의 어디가 다른지 모른다.
#
# **그래서 판정을 두 성분으로 가른다** (Bonferroni: 각 ALPHA/2, 하나라도 깨지면 FAIL):
#   [A] 원자  — P(tau >= H) 의 두 비율 검정.        z_crit = Phi^-1(1 - ALPHA/4)
#   [B] 몸통  — **비검열 부분표본**만의 2표본 KS.   D_crit = k(ALPHA/2)*sqrt(1/n1'+1/n2')
#
# 그리고 판정에 안 쓰는 **진단** 하나를 낸다 — 각 성분이 함의하는 rate ratio:
#   c_atom = -ln(p_L)/Lambda        (Lambda = -ln(p_H), 엔진의 유효 적분위험)
#   c_body = sup_trunc^-1(D_cond)   (절단지수 사이의 sup 거리를 역으로 푼다)
# 두 값이 **일치하면** 격차는 균일한 rate 배율이고, **어긋나면** 시간에 따라 변하는 무언가다.
#
# 🔴 **교차 검증 실측 (두 디렉토리, 2026-08-21).** 몸통만 재현된다:
#      KS_all   T9 레인 0.118898  vs  T10 레인 0.071121   → 1.67배 (재현 안 됨)
#      KS_cond  T9 레인 0.042074  vs  T10 레인 0.042434   → 0.9 %  (재현됨)
#      c_body   T9 레인 0.8373    vs  T10 레인 0.8332     → 0.5 %  (재현됨)
#      c_atom   T9 레인 0.6976    vs  T10 레인 0.7653     → 9.7 %  (재현 안 됨)
#    즉 성분 [B] 가 이 시스템에서 **재현 가능한 유일한 신호**이고, 그것이 말하는 것은
#    경량 레인의 누적위험이 엔진의 약 83 % 라는 것이다.
#    ⇒ 성분 [A] 의 판정은 §4 입력 정준화(C8) 뒤에 다시 볼 것. 근거: briefs/task-D12-brief.md
# =============================================================================
ALPHA_HALF = ALPHA / 2.0                      # Bonferroni 몫. 두 성분에 반씩
K_ALPHA_HALF = float(kstwobign.ppf(1.0 - ALPHA_HALF))     # 성분 [B] 의 KS 상수
Z_CRIT_HALF = float(norm.ppf(1.0 - ALPHA_HALF / 2.0))     # 성분 [A] 의 양측 z 임계

# 절단지수 CDF 의 sup 거리를 재는 격자. 결정적이어야 하므로 고정 크기 선형격자를 쓴다.
_TRUNC_GRID = 200001


def sup_trunc(c, lam):
    """`[0,H]` 로 절단된 두 지수분포(rate 비 `c`) CDF 사이의 최대 간격.

    `u = x/H` 로 두면 `H` 가 소거되고 `Lambda` 만 남는다:
        F_c(u) = (1 - exp(-c*Lambda*u)) / (1 - exp(-c*Lambda)),  u in [0,1]
    """
    if c == 1.0 or lam <= 0.0 or not math.isfinite(lam):
        return 0.0
    best = 0.0
    denom1 = 1.0 - math.exp(-lam)
    denomc = 1.0 - math.exp(-c * lam)
    if denom1 <= 0.0 or denomc <= 0.0:
        return 0.0
    for i in range(_TRUNC_GRID):
        u = i / (_TRUNC_GRID - 1)
        a = (1.0 - math.exp(-lam * u)) / denom1
        b = (1.0 - math.exp(-c * lam * u)) / denomc
        gap = abs(a - b)
        if gap > best:
            best = gap
    return best


def resolved_c_trunc(d_crit, lam):
    """`sup_trunc(c) == d_crit` 인 `c < 1` (= 몸통 성분이 분해할 수 있는 가장 큰 c)."""
    lo, hi = 1e-6, 1.0 - 1e-12
    if sup_trunc(lo, lam) < d_crit:
        return float("nan")
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if sup_trunc(mid, lam) < d_crit:
            hi = mid
        else:
            lo = mid
    return 0.5 * (lo + hi)


def invert_sup_trunc(d_obs, lam):
    """관측된 `D_cond` 를 내는 `c` (경량이 느리므로 `c < 1` 가지를 고른다)."""
    if d_obs <= 0.0:
        return 1.0
    lo, hi = 1e-6, 1.0 - 1e-12
    if sup_trunc(lo, lam) < d_obs:
        return float("nan")          # 어떤 c 로도 이 거리를 못 만든다
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if sup_trunc(mid, lam) < d_obs:
            hi = mid
        else:
            lo = mid
    return 0.5 * (lo + hi)


def two_proportion_z(x1, n1, x2, n2):
    """두 비율의 풀드 z 와 표준오차. 어느 한쪽 n 이 0 이면 `(nan, nan)`."""
    if n1 <= 0 or n2 <= 0:
        return float("nan"), float("nan")
    p1, p2 = x1 / n1, x2 / n2
    pbar = (x1 + x2) / (n1 + n2)
    se = math.sqrt(pbar * (1.0 - pbar) * (1.0 / n1 + 1.0 / n2))
    if se <= 0.0:
        return (0.0 if p1 == p2 else float("inf")), se
    return (p1 - p2) / se, se


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
    # 🔴 **`n_required` 는 필요조건이지 충분조건이 아니다.**
    #    `n = 2(K/g)²` 를 대입하면 `D_crit = K√(2n⁻¹) = K√(2·g²/2K²) = g` — 즉 그 지점에서
    #    `D_crit == g(c*)` 는 **항등식**이다(경험적 우연이 아니다). 그러므로 이보다 표본이 적으면
    #    `c*` 크기의 격차는 원리적으로 기각될 수 없고, 그것이 "표본이 모자라서 나온 초록/빨강" 을
    #    막는 데 정확히 충분하다. 그러나 "`c*` 를 반드시 잡는다" 는 **아니다.**
    #
    #    ⚠️ **정정(수정 2라운드).** 이 자리는 한때 "그러므로 검정력이 약 50%" 라고 적고 그것을
    #    매 실행 찍었다. **틀렸다.** `D = sup_t|F₁−F₂|` 는 잡음 위의 **상한**이라 점별 격차보다
    #    위로 편향된다 — `E[D] ≠ g`. 그래서 통계량이 `g` 를 중심으로 흩어진다는 전제가 성립하지
    #    않는다. 검정력은 **여기서 주장하지 않는다**: 그 값은 `(c*, n, α)` 마다 다르고 이 게이트는
    #    임의의 셋에 대해 돌기 때문이다. 이 구성에 대한 **실측** 검정력은 그것을 실제로 재는
    #    자리에 있다 — `test_gate_ng1.py::test_measured_power_at_threshold_and_at_2x_margin`.
    #
    #    `n_where_g_is_2x_D_crit = 4·n_required` 는 **유도된 격차 `g` 가 임계값의 2배가 되는
    #    표본수**다(`D_crit ∝ n^(-1/2)` 이므로 4배). "n_required 의 2배" 가 아니다.
    print(f"POWER g/D_crit={(g_star / d_crit) if d_crit > 0 else float('inf'):.5f} "
          f"n_threshold={n_req} (identity: D_crit == g(c*) exactly at n_threshold) "
          f"n_where_g_is_2x_D_crit={4 * n_req if n_req != float('inf') else 'inf'} "
          f"regime={'below-threshold' if d_crit > g_star else 'at-or-above-threshold'} "
          "-- n_required is NECESSARY, not sufficient; power is NOT asserted here "
          "(see test_gate_ng1.py::test_measured_power_at_threshold_and_at_2x_margin)")
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
    # ⚠️ 🔴 **위 혼합 KS 는 이제 판정이 아니라 진단이다** (D-12). 그 통계량의 80~98 % 가
    #    검열 원자 하나이므로, 판정은 아래 두 성분이 진다. 옛 값은 T9/T10 기록과의 연속성을
    #    위해 계속 찍는다.
    print(f"[legacy] mixed-KS={st:.6f} p={p:.4g}  -- DIAGNOSTIC ONLY since D-12; "
          "the verdict is the two components below")

    # =========================================================================
    # 🔴 N-G1′ — 판정. 두 성분 + Bonferroni (사용자 결정 D-12)
    # =========================================================================
    xL, xH = lk.count("horizon"), hk.count("horizon")
    pL, pH = (xL / n1 if n1 else float("nan")), (xH / n2 if n2 else float("nan"))

    # --- [A] 지평 원자 ------------------------------------------------------
    zA, seA = two_proportion_z(xL, n1, xH, n2)
    dp_crit = Z_CRIT_HALF * seA if math.isfinite(seA) else float("nan")
    atom_fail = math.isfinite(zA) and abs(zA) > Z_CRIT_HALF
    print(f"[A] atom  p_L={pL:.6f}({xL}/{n1}) p_H={pH:.6f}({xH}/{n2}) dp={pL - pH:+.6f} "
          f"z={zA:.4f} z_crit={Z_CRIT_HALF:.4f}(alpha/2={ALPHA_HALF}) "
          f"detectable_dp>={dp_crit:.6f} -> {'FAIL' if atom_fail else 'PASS'}")

    # --- [B] 몸통 (비검열 부분표본) ------------------------------------------
    lu = [t for t, k in zip(light, lk) if k != "horizon"]
    hu = [t for t, k in zip(heavy, hk) if k != "horizon"]
    n1u, n2u = len(lu), len(hu)
    if n1u < 2 or n2u < 2:
        f_res.append(f"비검열 부분표본이 너무 작다 (light={n1u}, heavy={n2u}) — "
                     "몸통 성분을 잴 수 없다")
        d_cond, p_cond, d_crit_b, body_fail = float("nan"), float("nan"), float("nan"), False
    else:
        d_cond, p_cond = ks_2samp(lu, hu, method=KS_METHOD)
        d_crit_b = K_ALPHA_HALF * math.sqrt(1.0 / n1u + 1.0 / n2u)
        body_fail = p_cond < ALPHA_HALF
    print(f"[B] body  n1'={n1u} n2'={n2u} KS_cond={d_cond:.6f} p={p_cond:.4g} "
          f"D_crit={d_crit_b:.6f}(k={K_ALPHA_HALF:.10f}) "
          f"ratio={d_cond / d_crit_b if d_crit_b > 0 else float('nan'):.3f}x "
          f"-> {'FAIL' if body_fail else 'PASS'}")

    # --- [C] 진단: 각 성분이 함의하는 rate ratio ------------------------------
    #     판정에 쓰지 않는다. 두 값이 어긋나면 "균일 배율이 아니다" 는 뜻이고, 그것이
    #     '제3 기전' 에 이름을 붙이는 첫 단서다 (briefs/task-D12-brief.md §4).
    lam = -math.log(pH) if (0.0 < pH < 1.0) else float("nan")
    c_atom = (-math.log(pL) / lam) if (0.0 < pL < 1.0 and math.isfinite(lam) and lam > 0) \
             else float("nan")
    c_body = invert_sup_trunc(d_cond, lam) if (math.isfinite(lam) and math.isfinite(d_cond)) \
             else float("nan")
    ratio_cc = (c_atom / c_body) if (math.isfinite(c_atom) and math.isfinite(c_body)
                                     and c_body > 0) else float("nan")
    print(f"[C] implied Lambda={lam:.6f} c_atom={c_atom:.6f} c_body={c_body:.6f} "
          f"c_atom/c_body={ratio_cc:.4f} "
          "(≈1 => uniform rate scaling; !=1 => something that grows with elapsed time) "
          "-- DIAGNOSTIC, not a verdict")

    # --- 분해능: **두 성분 다** c* 를 분해해야 한다 ---------------------------
    #     🔴 위 §1 의 분해능 검사는 혼합 KS 용이다. 성분별로 다시 유도한다 — 실측상
    #     몸통 성분이 더 많은 표본을 요구하므로(원자 6,782 vs 몸통 25,198 @ c*=1.0667),
    #     혼합 기준만 통과시키면 몸통이 아무것도 못 보는 채로 초록이 될 수 있다.
    if math.isfinite(lam) and lam > 0:
        # [A] 가 c* 를 분해하는가
        pL_star = math.exp(-c_star * lam)
        _, se_star = two_proportion_z(round(pL_star * n1), n1, xH, n2)
        dpA = abs(pL_star - pH)
        n_req_A = (math.ceil(2.0 * Z_CRIT_HALF ** 2 * ((pL_star + pH) / 2) *
                             (1 - (pL_star + pH) / 2) / dpA ** 2) if dpA > 0 else float("inf"))
        okA = math.isfinite(se_star) and dpA > Z_CRIT_HALF * se_star
        # [B] 가 c* 를 분해하는가.
        # 🔴 **방향 선택.** `sup_trunc` 는 `c` 와 `1/c` 에 대칭이 아니다. 실측(Lambda 1.8~3.0):
        #    `sup_trunc(1/c*)` 가 언제나 `sup_trunc(c*)` 보다 **작다** = 잡기 더 어렵다.
        #    그래서 보수적으로 그쪽을 요구한다 — 어느 방향의 격차든 이 문턱을 넘으면 잡힌다.
        # ⚠️ 그리고 **절단이 검정력을 깎는다**: 비절단 `sup_gap(c*)=0.023738` 대비
        #    `sup_trunc(1/c*)`은 0.0128~0.0182 다. 즉 원자를 떼어낸 대가로 몸통 성분은
        #    혼합 게이트보다 **1.7~3.4 배 많은 표본**을 요구한다. 그것이 D-12 의 비용이고,
        #    게이트가 그 사실을 조용히 넘기지 않고 말한다.
        g_body = sup_trunc(1.0 / c_star, lam)
        okB = math.isfinite(d_crit_b) and g_body > d_crit_b
        n_req_B = (math.ceil(2.0 * (K_ALPHA_HALF / g_body) ** 2) if g_body > 0 else float("inf"))
        # 생성기가 쓸 수 있게 **총 표본수**로도 환산한다(비검열 비율의 역수를 곱한다).
        frac_unc = min(n1u / n1, n2u / n2) if (n1 and n2) else float("nan")
        n_total_B = (math.ceil(n_req_B / frac_unc)
                     if (frac_unc and math.isfinite(frac_unc) and frac_unc > 0
                         and n_req_B != float("inf")) else float("inf"))
        print(f"RESOLUTION' [A] dp(c*)={dpA:.6f} n_required={n_req_A} -> "
              f"{'ok' if okA else 'INSUFFICIENT'} | "
              f"[B] sup_trunc(1/c*)={g_body:.6f} n'_required={n_req_B} "
              f"(uncensored_frac={frac_unc:.4f} -> n_total_required={n_total_B}) -> "
              f"{'ok' if okB else 'INSUFFICIENT'}")
        if not okA:
            f_res.append(f"성분 [A] 가 c*={c_star:.4f} 를 분해하지 못한다 (n>={n_req_A} 필요)")
        if not okB:
            f_res.append(f"성분 [B] 가 c*={c_star:.4f} 를 분해하지 못한다 — 비검열 "
                         f"{min(n1u, n2u)} 개인데 {n_req_B} 필요. 생성기에 "
                         f"**총 n >= {n_total_B}** 를 줄 것 (Lambda={lam:.4f} 에 의존하므로 "
                         "레인마다 다르다)")

    if atom_fail:
        f_dist.append(f"[A] 지평 원자가 갈린다 (z={zA:.3f} > {Z_CRIT_HALF:.3f}, "
                      f"dp={pL - pH:+.5f})")
    if body_fail:
        f_dist.append(f"[B] 몸통(비검열) 분포가 갈린다 (p={p_cond:.4g} < {ALPHA_HALF}, "
                      f"KS_cond={d_cond:.4f}, 함의 c_body={c_body:.4f})")

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
