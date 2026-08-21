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
