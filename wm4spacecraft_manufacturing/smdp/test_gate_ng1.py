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

R_MIN, N_FLEET = 1.4, 6                      # HazardParams 의 인접 배수비 · 함대 크기
C_STAR = ((N_FLEET - 1) + R_MIN) / N_FLEET   # = 1.0666666666666667
K_ALPHA = 1.6276236115189502


def _sup_gap(c):
    return 0.0 if c == 1.0 else c ** (-1.0 / (c - 1.0)) - c ** (-c / (c - 1.0))


N_REQ = math.ceil(2.0 * (K_ALPHA / _sup_gap(C_STAR)) ** 2)   # 9403


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
def test_cstar_is_a_threshold_not_a_guarantee():
    """🔴 `n_required` 가 **필요조건일 뿐**임을 시험으로 못박는다.

    `n = 2(K/g)²` 는 `D_crit == g(c*)` 가 되는 자리라 검정력이 약 50% 다. 정확히 c* 만큼
    벌어진 **순수 지수쌍**은 그 자리에서 임계값 아래로 떨어질 수 있고, 실제로 떨어진다.
    이 시험이 초록인 동안에는 "n_required 를 채웠으니 c* 는 반드시 잡힌다"고 쓰면 안 된다.

    ⚠️ 실제 N-G1 의 self-c* 음성 대조는 잡혔다(KS 0.0335 > 0.0237). 그건 τ 의 참 법칙이
    지수가 아니라 표본 요동이 그쪽으로 떨어진 것이고, **보장이 아니라 관측**이다."""
    with tempfile.TemporaryDirectory() as d:
        p = _artifact(os.path.join(d, "c2.json"), N_REQ, 1.0, C_STAR, lane="at-cstar")
        rc, out = _run(p)
        ks = float([l for l in out.splitlines() if l.startswith("KS=")][0]
                   .split()[0].split("=")[1])
        d_crit = float([l for l in out.splitlines() if l.startswith("RESOLUTION")][0]
                       .split("D_crit=")[1].split()[0])
        # 임계값과 **같은 자릿수**에 있다(= 임계 영역). 어느 쪽에 떨어지는지는 표본이 정한다.
        assert 0.3 * d_crit < ks < 3.0 * d_crit, f"KS={ks} D_crit={d_crit}\n{out}"
        assert "n_required is NECESSARY, not sufficient" in out, out


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
