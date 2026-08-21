#!/usr/bin/env python3
"""`gate_ng1.py` 자신의 시험 — **게이트가 초록/빨강을 벌었는가.**

  python3 wm4spacecraft_manufacturing/smdp/test_gate_ng1.py

이 파일이 지키는 것 하나: **분해능이 모자라서 나온 빨간불이 음성 대조의 성공으로 세어지지
않는다.** 수정 1라운드 이전에는 그렇게 세어졌다 — `ok = not fails` 하나로 모든 실패를 뭉쳐서
`--expect-fail` 이 "분포가 갈렸다" 와 "표본이 모자라 아무것도 못 봤다" 를 **구분하지 못했다.**
그 상태에서 아무 아티팩트나 n 을 줄여 넣으면 음성 대조가 초록(rc=0)으로 통과했을 것이다.

합성 아티팩트로만 돈다(엔진도 Julia 도 필요 없다). 위험률이 정확히 c 배인 두 지수 표본을
만들면 `Λ → cΛ` 섭동의 **정의 그대로**가 되므로 게이트의 유도(§4)와 같은 축 위에서 잰다.
"""
import json, math, os, random, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "gate_ng1.py")
sys.path.insert(0, HERE)
# 🔴 상수도 식도 **게이트에서 가져온다.** 첫 판은 `K_ALPHA` 리터럴과 `sup_gap` 복사본을 여기
#    다시 들여왔는데, 그건 수정 1라운드의 minor 3 이 없앤 것과 **같은 부류**다(손으로 옮긴
#    상수 두 벌). 시험이 게이트를 검증하는 것이지 상수를 검증하는 게 아니므로 import 가 맞다.
from gate_ng1 import ALPHA, K_ALPHA, sup_gap as _sup_gap   # noqa: E402

R_MIN, N_FLEET = 1.4, 6                      # HazardParams 의 인접 배수비 · 함대 크기
C_STAR = ((N_FLEET - 1) + R_MIN) / N_FLEET   # = 1.0666666666666667
N_REQ = math.ceil(2.0 * (K_ALPHA / _sup_gap(C_STAR)) ** 2)   # 9403
D_CRIT_AT_N_REQ = K_ALPHA * math.sqrt(2.0 / N_REQ)


def _lane(n, rate, seed, horizon=20.0):
    """rate 배의 위험률을 갖는 지수 표본 n 개 + 세 위험을 전부 덮는 종류 라벨."""
    rng = random.Random(seed)
    tau, kinds = [], []
    for i in range(n):
        t = rng.expovariate(rate)
        if t >= horizon:
            tau.append(horizon); kinds.append("horizon")
        else:
            tau.append(t); kinds.append(("break", "cell", "zone")[i % 3])
    return tau, kinds


def _artifact(path, n, rate_light, rate_heavy, *, c_star=C_STAR, r_min=R_MIN,
              n_fleet=N_FLEET, lane="synthetic", terminal=False):
    lt, lk = _lane(n, rate_light, 11)
    ht, hk = _lane(n, rate_heavy, 22)
    if terminal:
        lk[0] = "terminal"
    meta = {"alpha": 0.01, "k_alpha": K_ALPHA, "c_star": c_star, "r_min": r_min,
            "n_fleet": n_fleet, "sup_gap_at_c_star": _sup_gap(c_star),
            "n_derived": N_REQ, "n_used": n, "probe_step": 0, "dt_sim": 0.025,
            "horizon_s": 20.0, "global_mode": 1.0, "heavy_events_fired": 0,
            "lane": lane, "perturb_c": rate_heavy / rate_light}
    json.dump({"light_tau": lt, "heavy_tau": ht, "light_kinds": lk,
               "heavy_kinds": hk, "meta": meta}, open(path, "w"))
    return path


def _run(path, expect_fail=False):
    cmd = [sys.executable, GATE] + (["--expect-fail"] if expect_fail else []) + [path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


CASES = []


def case(fn):
    CASES.append(fn); return fn


# ---------------------------------------------------------------------------
@case
def test_underpowered_expect_fail_is_not_a_success():
    """🔴 Important 1. 표본이 모자란 아티팩트는 `--expect-fail` 에서도 **실패**여야 한다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "a.json"), 300, 1.0, C_STAR, lane="underpowered")
        rc, out = _run(p, expect_fail=True)
        assert rc != 0, f"under-powered negative control returned rc=0\n{out}"
        assert "빨간불이 분포 때문이 아니다" in out, out
        rc2, out2 = _run(p, expect_fail=False)
        assert rc2 != 0, out2
        assert "분해하지 못한다" in out2, out2


@case
def test_powered_null_passes():
    """같은 법칙 두 레인 + 충분한 n → PASS (게이트가 위양성으로 울지 않는다)."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "b.json"), N_REQ, 1.0, 1.0, lane="null")
        rc, out = _run(p)
        assert rc == 0, out
        assert "\nPASS" in out, out


@case
def test_healthy_null_under_expect_fail_is_a_failure():
    """🔴 진짜 음성 대조 **실패** 경로 — 마지막까지 시험이 없던 종료 경로다.

    건강하고(위생·분해능·종류 전부 통과) 표본도 충분한데 **섭동이 안 보이면**, 그건 음성
    대조의 실패이고 rc=1 이어야 한다. `test_powered_null_passes` 는 정확히 이 픽스처를 만들어
    놓고 `--expect-fail` **없이** 돌리기 때문에 이 경로를 덮지 못했다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "b2.json"), N_REQ, 1.0, 1.0, lane="null")
        rc, out = _run(p, expect_fail=True)
        assert rc != 0, out
        assert "게이트가 섭동을 못 잡았다" in out, out


@case
def test_powered_supra_cstar_expect_fail_succeeds():
    """c* 보다 **확실히 큰** 격차 + 충분한 n → `--expect-fail` 이 rc=0.

    c = 1.15 는 g(1.15) = 0.0509 로 D_crit = 0.0237 의 2.1배다 — 임계값 위 여백이 있어
    한 표본으로도 안정적으로 잡힌다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "c.json"), N_REQ, 1.0, 1.15, lane="supra-cstar")
        rc, out = _run(p, expect_fail=True)
        assert rc == 0, out
        assert "건강한 상태에서" in out, out


@case
def test_at_n_required_a_draw_at_cstar_can_fail_to_reject():
    """🔴 `n_required` 가 **필요조건일 뿐**임을 못박는 **결정적** 트립와이어.

    `n = 2(K/g)²` 에서 `D_crit == g(c*)` 는 항등식이다. 그 자리에서도 정확히 `c*` 만큼 벌어진
    표본이 임계값 **아래**로 떨어지는 draw 가 **존재한다** — 아래 시드 쌍이 그것이고, 값이
    재현되므로 이 시험은 흔들리지 않는다.

    ⚠️ **존재 증명이지 전형이 아니다.** 이 draw 는 표집분포의 **1.10 백분위**다(실측:
    2000 반복, 이 디렉토리·2026-08-21). 첫 판은 이걸 "검정력 약 50%" 의 근거로 썼는데
    **틀렸다** — `test_measured_power_at_threshold_and_at_2x_margin` 이 실제 값을 잰다.

    ⚠️ 첫 판의 이 자리에는 `0.3·D_crit < KS < 3.0·D_crit` 이 있었다. 그건 **트립와이어가
    아니었다** — 150 개 재표집 draw 가 전부 0.77×~1.94× 안에 들어와 검정력 99% 에서도 초록으로
    남았을 것이다. docstring 이 주장하는 성질을 실제로 잠그지 않는 시험은 이 계획이 없애려는
    바로 그 모양이라 통째로 갈았다.
    """
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "c2.json"), N_REQ, 1.0, C_STAR, lane="at-cstar")
        rc, out = _run(p)
        ks = float([l for l in out.splitlines() if l.startswith("KS=")][0]
                   .split()[0].split("=")[1])
        assert abs(ks - 0.016378) < 1e-6, f"seeds (11,22) draw moved: KS={ks}\n{out}"
        assert ks < D_CRIT_AT_N_REQ, f"KS={ks} D_crit={D_CRIT_AT_N_REQ}"
        assert rc == 0, out          # 기각하지 못하므로 게이트는 PASS 를 낸다
        assert "n_required is NECESSARY, not sufficient" in out, out
        assert "~50% power" not in out, "the retracted power claim is back in the output"


@case
def test_measured_power_at_threshold_and_at_2x_margin():
    """🔴 검정력을 **재서** 못박는다 (수정 2라운드). 시드 고정 = 결정적, flaky 하지 않다.

    실측(이 디렉토리, seed 20260821, 순수 지수쌍, `c = c*`):

    | n | D_crit | E[KS] | 검정력 @ α=0.01 |
    |---|---|---|---|
    | `n_required` = 9403 | 0.023738 | **0.029401** | **0.805** (2000 반복) |
    | `4·n_required` = 37612 | 0.011869 | 0.026138 | **1.000** (400 반복) |

    🔴 요점 둘: (1) `E[KS] = 0.0294 > g = 0.0237` — `sup` 통계량은 점별 격차보다 **위로**
    편향된다. 그래서 "통계량이 g 를 중심으로 흩어지므로 검정력 50%" 라는 첫 판의 추론이
    깨진다. (2) 그럼에도 검정력은 1 이 **아니다**(0.805) — `n_required` 는 여전히 충분조건이
    아니고, 실제 self-c* 음성 대조가 잡힌 것은 **개연적 결과(p≈0.8)** 이지 행운이 아니다.
    """
    try:
        import numpy as np
        from scipy.stats import ks_2samp
    except ImportError:                                     # pragma: no cover
        print("      (skipped: numpy/scipy 없음)"); return

    def power(n, reps, seed, c=C_STAR):
        rng = np.random.default_rng(seed)
        dcrit = K_ALPHA * math.sqrt(2.0 / n)
        ks = np.empty(reps)
        for i in range(reps):
            ks[i] = ks_2samp(rng.exponential(1.0, n),
                             rng.exponential(1.0 / c, n), method="asymp").statistic
        return ks, dcrit

    ks, dc = power(N_REQ, 400, 20260821)
    pw = float((ks >= dc).mean())
    assert ks.mean() > dc, f"E[KS]={ks.mean()} should exceed D_crit={dc} (sup is biased up)"
    assert 0.70 <= pw <= 0.92, f"power at n_required = {pw} (measured 0.805 @2000 reps)"
    ks2, dc2 = power(4 * N_REQ, 100, 20260821)
    assert float((ks2 >= dc2).mean()) == 1.0, "power at 4*n_required should be 1.0"


@case
def test_inflated_c_star_is_rejected():
    """🔴 minor 2. meta 의 c_star 를 부풀려 분해능 문턱을 낮추려는 아티팩트는 거부된다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "d.json"), 300, 1.0, 1.0,
                      c_star=1.5, lane="tampered")     # r_min/n_fleet 은 그대로
        rc, out = _run(p)
        assert rc != 0, out
        assert "유도한" in out and "다르다" in out, out


@case
def test_missing_provenance_is_rejected():
    """meta 에 r_min/n_fleet 이 없으면 분해능을 **검증할 수 없으므로** 거부한다."""
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "e.json")
        _artifact(p, N_REQ, 1.0, 1.0)
        obj = json.load(open(p))
        del obj["meta"]["r_min"]
        json.dump(obj, open(p, "w"))
        rc, out = _run(p)
        assert rc != 0, out
        assert "분해능을 검증할 수 없다" in out, out


@case
def test_sanity_failure_is_not_a_negative_control_success():
    """위생(경량 레인의 terminal) 실패도 `--expect-fail` 성공으로 세면 안 된다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "f.json"), N_REQ, 1.0, C_STAR, terminal=True)
        rc, out = _run(p, expect_fail=True)
        assert rc != 0, out


# ===========================================================================
# 🔴 N-G1′ — 성분 분해가 **실제로 두 축을 가르는가** (사용자 결정 D-12)
#
# 이 셋이 D-12 의 핵심 주장을 시험한다. 합성 표본을 **직접** 지어서
#   (1) 몸통은 같고 원자만 다른 판  → [A] FAIL · [B] PASS 여야 한다
#   (2) 원자는 같고 몸통만 다른 판  → [A] PASS · [B] FAIL 여야 한다
# 둘 다 성립해야 "분해"라는 말이 성립한다. 하나라도 안 되면 두 성분이 같은 것을 재는 것이다.
# ===========================================================================
import re as _re


def _components(out):
    """게이트 출력에서 [A]/[B]/[C] 를 뽑는다."""
    a = _re.search(r"^\[A\] atom .*-> (PASS|FAIL)$", out, _re.M)
    b = _re.search(r"^\[B\] body .*-> (PASS|FAIL)$", out, _re.M)
    c = _re.search(r"c_atom=([0-9.naif-]+) c_body=([0-9.naif-]+)", out)
    assert a and b, out
    return a.group(1), b.group(1), (float(c.group(1)), float(c.group(2))) if c else (None, None)


def _split_artifact(path, body_l, body_h, n_cens_l, n_cens_h, horizon=20.0):
    """몸통과 검열 수를 **따로** 지정해 만드는 아티팩트."""
    lt = list(body_l) + [horizon] * n_cens_l
    ht = list(body_h) + [horizon] * n_cens_h
    lk = [("break", "cell", "zone")[i % 3] for i in range(len(body_l))] + ["horizon"] * n_cens_l
    hk = [("break", "cell", "zone")[i % 3] for i in range(len(body_h))] + ["horizon"] * n_cens_h
    meta = {"alpha": 0.01, "k_alpha": K_ALPHA, "c_star": C_STAR, "r_min": R_MIN,
            "n_fleet": N_FLEET, "sup_gap_at_c_star": _sup_gap(C_STAR),
            "n_derived": N_REQ, "n_used": len(lt), "probe_step": 0, "dt_sim": 0.025,
            "horizon_s": horizon, "global_mode": 1.0, "heavy_events_fired": 0,
            "lane": "synthetic-split", "perturb_c": 1.0}
    json.dump({"light_tau": lt, "heavy_tau": ht, "light_kinds": lk,
               "heavy_kinds": hk, "meta": meta}, open(path, "w"))
    return path


def _trunc_exp(n, rate, seed, horizon=20.0):
    """`[0, horizon)` 으로 **거절 표집**한 지수 표본 — 검열 없이 몸통만 만든다."""
    rng = random.Random(seed)
    out = []
    while len(out) < n:
        t = rng.expovariate(rate)
        if t < horizon:
            out.append(t)
    return out


@case
def test_atom_only_difference_fails_A_and_passes_B():
    """몸통이 **같은 분포**이고 검열 질량만 다르면 [A] 만 빨개져야 한다."""
    N = 20000
    body_l = _trunc_exp(N, 0.2, 101)
    body_h = _trunc_exp(N, 0.2, 202)          # 같은 rate = 같은 몸통 분포
    with tempfile.TemporaryDirectory() as d:
        p = _split_artifact(os.path.join(d, "a.json"), body_l, body_h, 4000, 1000)
        _, out = _run(p)
        A, B, _ = _components(out)
        A2, B2, (c_atom, c_body) = A, B, _components(out)[2]
        assert A == "FAIL", f"원자가 4000 vs 1000 인데 [A] 가 안 잡았다\n{out}"
        assert B == "PASS", f"몸통이 같은 분포인데 [B] 가 빨개졌다\n{out}"
        # 🔴 [C] 의 두 값이 **독립 계산**인가. 몸통이 같으므로 c_body ≈ 1 이어야 하고,
        #    원자는 4배 차이라 c_atom 은 1 에서 멀어야 한다. `c_body = c_atom` 같은
        #    복사 구현은 여기서 죽는다.
        assert abs(c_body - 1.0) < 0.05, f"몸통이 같은데 c_body={c_body} 가 1 에서 멀다\n{out}"
        assert abs(c_atom - 1.0) > 0.15, f"원자가 4배 다른데 c_atom={c_atom} 이 1 근처다\n{out}"


@case
def test_body_only_difference_passes_A_and_fails_B():
    """검열 질량이 **같고** 몸통 모양만 다르면 [B] 만 빨개져야 한다."""
    N = 20000
    body_l = _trunc_exp(N, 0.20, 303)
    body_h = _trunc_exp(N, 0.35, 404)         # 다른 rate = 다른 몸통 모양
    with tempfile.TemporaryDirectory() as d:
        p = _split_artifact(os.path.join(d, "b.json"), body_l, body_h, 2000, 2000)
        _, out = _run(p)
        A, B, _ = _components(out)
        assert A == "PASS", f"검열이 2000 vs 2000 로 같은데 [A] 가 빨개졌다\n{out}"
        assert B == "FAIL", f"몸통 rate 가 0.20 vs 0.35 인데 [B] 가 안 잡았다\n{out}"


@case
def test_uniform_rate_scaling_makes_the_two_implied_ratios_agree():
    """🔴 [C] 진단의 계약. **순수 배율**이면 `c_atom ≈ c_body` 여야 한다.

    이 시험이 없으면 "두 값이 어긋난다 = 균일 배율이 아니다" 라는 D-12 의 판독이
    근거를 잃는다 — 어긋남이 배율 때문인지 추정량의 편향 때문인지 구분이 안 된다.
    """
    N = 60000
    with tempfile.TemporaryDirectory() as d:
        # light rate 0.10, heavy rate 0.13 -> 참 c_atom = c_body = 0.10/0.13 = 0.7692
        p = _artifact(os.path.join(d, "c.json"), N, 0.10, 0.13, lane="uniform-scaling")
        _, out = _run(p)
        _, _, (c_atom, c_body) = _components(out)
        true_c = 0.10 / 0.13
        assert abs(c_atom - true_c) < 0.03, f"c_atom={c_atom} vs 참값 {true_c}\n{out}"
        assert abs(c_body - true_c) < 0.05, f"c_body={c_body} vs 참값 {true_c}\n{out}"
        # 그리고 서로도 가까워야 한다 — 이것이 실제 판독에 쓰는 양이다
        assert abs(c_atom / c_body - 1.0) < 0.06, \
            f"순수 배율인데 두 함의값이 갈린다: {c_atom} vs {c_body}\n{out}"


@case
def test_component_thresholds_are_derived_not_literals():
    """🔴 두 성분의 임계값이 **유도**된 값인가 (리터럴 복붙 금지 — 게이트의 기존 규약).

    `z_crit` 은 `Phi^-1(1 - alpha/4)`, `[B]` 의 `k` 는 `kstwobign.ppf(1 - alpha/2)` 여야 한다.
    시험은 그 둘을 **독립적으로** 계산해 게이트가 찍은 값과 대조한다 — 게이트에서 import 하면
    같은 리터럴을 두 번 읽는 것이라 아무것도 안 막는다.
    """
    from scipy.stats import norm as _norm, kstwobign as _kb
    z_expect = float(_norm.ppf(1.0 - ALPHA / 4.0))
    k_expect = float(_kb.ppf(1.0 - ALPHA / 2.0))
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "t.json"), N_REQ, 1.0, 1.0, lane="threshold-check")
        _, out = _run(p)
        mz = _re.search(r"z_crit=([0-9.]+)", out)
        mk = _re.search(r"D_crit=[0-9.]+\(k=([0-9.]+)\)", out)
        assert mz and mk, out
        assert abs(float(mz.group(1)) - z_expect) < 1e-3, \
            f"z_crit={mz.group(1)} vs 유도값 {z_expect:.6f} — 리터럴이 박혔나\n{out}"
        assert abs(float(mk.group(1)) - k_expect) < 1e-6, \
            f"k={mk.group(1)} vs 유도값 {k_expect:.10f}\n{out}"
        # 항진 방지: 두 상수가 서로 다른 값이어야 이 대조가 의미가 있다
        assert abs(z_expect - k_expect) > 0.5


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    bad = 0
    for fn in CASES:
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except AssertionError as e:
            bad += 1
            print(f"FAIL  {fn.__name__}\n      {e}")
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    sys.exit(1 if bad else 0)
