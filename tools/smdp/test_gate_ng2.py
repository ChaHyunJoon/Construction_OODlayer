#!/usr/bin/env python3
"""`gate_ng2.py` 자신의 시험 — **게이트가 초록/빨강을 벌었는가.**

  python3 tools/smdp/test_gate_ng2.py

합성 아티팩트만 쓴다 — Julia 도 엔진도 필요 없다. 각 시험이 **게이트의 종료 경로 하나씩**을
실제로 태운다.

🔴 이 파일의 존재 이유는 한 줄이다: **브리프의 원안 게이트는 "팔이 전혀 안 갈리는" 산출물에
   PASS 를 준다.** `test_all_tied_light_scores_is_not_a_pass` 가 원안 구현을 **그 자리에서
   돌려서** rc=0 을 실측하고, 현행 게이트가 같은 입력에 rc≠0 을 내는 것을 대조한다.
   이 레포에서 실제로 일어난 실패 모양이다(조합 팔 5≡4 · 6≡2 가 65/65 instance).
"""
import io
import json
import os
import sys
import tempfile
import traceback
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "src", "decision", "core"))
import simulator_paths                     # noqa: E402,F401
import action_registry as AR      # noqa: E402
import gate_ng2                   # noqa: E402


# --- 픽스처 ------------------------------------------------------------------
def _rho(p10=1.0, p90=1.2, rho=1.0, ng1=False):
    return {"rho": rho, "n_nodes": 150, "ratio_p10": p10, "ratio_p90": p90,
            "fit_rule": "median(actual/planned) over closed vertices with planned > 0",
            "meta": {"ng1_consulted": ng1}}


def _ranks(events, vocab=None, **meta):
    m = {"vocab": vocab if vocab is not None else AR.VOCAB,
         "light_score": "T_done(s_a, env; rho)", "heavy_score": "realized time-to-go",
         "lower_is_better": True}
    m.update(meta)
    return {"meta": m, "events": events}


def _ev(light, heavy, arms=None):
    """`arms` 기본값은 **현행** 레지스트리(`core/action_registry.json`, 단일 진실원)의
    활성 팔 전체다 — 리터럴로 복붙하지 않는다. 2026-08-28 이전 이 기본값이 `(0, 1, 2, 3)`
    으로 하드코딩돼 있었는데, `2026-08-24 축소`(4팔 -> 3팔, `RelocateBuild` 삭제) 뒤에도
    안 고쳐져서 존재하지 않는 팔 id 3 을 매 사건에 실어 보냈다 — 게이트는 정직하게
    "활성 팔이 아니다"로 거부했다(이 파일 3/13 실패의 원인).

    🔴 리뷰 라운드 1 정정: 처음엔 `AR.MACROS`(= `sorted(REGISTRY)`, **은퇴/실험 포함 전체**)
    를 썼다. 게이트 자신의 술어는 `AR.is_active`(= `AR.ACTIVE_MACROS`) 이고, 오늘은
    `RETIRED={}`·`EXPERIMENTAL={}` 라 우연히 둘이 같았을 뿐이다. 다음에 어느 팔 하나라도
    은퇴/실험으로 표시되는 순간 `AR.MACROS` 는 다시 비활성 id 를 실어 보내 지금 고친 바로
    그 실패가 재발한다. 술어와 같은 소스(`AR.ACTIVE_MACROS`)를 쓴다."""
    if arms is None:
        arms = AR.ACTIVE_MACROS
    return {"arms": list(arms), "light_score": list(light), "heavy_score": list(heavy)}


def _run(rho_obj, ranks_obj_or_none):
    """게이트를 실제로 돌리고 (rc, stdout) 을 돌려준다. `None` 이면 파일을 안 만든다."""
    d = tempfile.mkdtemp(prefix="ng2test_")
    rp = os.path.join(d, "rho.json")
    json.dump(rho_obj, open(rp, "w", encoding="utf-8"))
    kp = os.path.join(d, "arm_ranks.json")
    if ranks_obj_or_none is not None:
        json.dump(ranks_obj_or_none, open(kp, "w", encoding="utf-8"))
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = gate_ng2.main(rp, kp)
    return rc, buf.getvalue()


# --- 브리프 원안 (대조군) -----------------------------------------------------
def _brief_original(rho_path, ranks_path):
    """계획서 A Task T10 Step 3 의 코드 **그대로**. 여기 있는 이유는 하나뿐이다:
    아래 시험이 "원안이 이 입력에 초록을 준다" 를 **실측**으로 보이기 위해서다."""
    from scipy.stats import kendalltau
    rho = json.load(open(rho_path, encoding="utf-8"))
    d = json.load(open(ranks_path, encoding="utf-8"))
    taus, flips = [], 0
    for ev in d["events"]:
        t, _ = kendalltau(ev["light_rank"], ev["heavy_rank"])
        taus.append(t)
        if ev["light_rank"][0] != ev["heavy_rank"][0]:
            flips += 1
    med = sorted(taus)[len(taus) // 2]
    frac = flips / len(d["events"])
    ok = med >= 0.6 and frac <= 0.10
    return 0 if ok else 1, med, frac


# --- 시험 --------------------------------------------------------------------
def test_healthy_agreement_passes():
    """팔이 실제로 갈리고 두 레인의 순위가 같으면 PASS."""
    evs = [_ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) for _ in range(8)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 0, out
    assert "PASS" in out
    assert "n_events_light_all_tied=0" in out, out


def test_healthy_disagreement_fails():
    """갈리는데 순위가 뒤집히면 FAIL — 그리고 그 빨강은 **분포/순위** 때문이어야 한다."""
    evs = [_ev([1.0, 2.0, 3.0], [30.0, 20.0, 10.0]) for _ in range(8)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "tau" in out and "분해 불가" not in out, out


def test_top1_flip_alone_fails():
    """τ 는 높은데 top-1 만 자주 뒤집히는 경우 — 브리프의 두 번째 문턱이 실제로 문다."""
    good = _ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0])
    flip = _ev([1.0, 2.0, 3.0], [20.0, 10.0, 30.0])   # 1·2 위만 교환
    evs = [flip] * 3 + [good] * 7                                # top1_flip = 30% > 10%
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "top1_flip" in out, out


def test_all_tied_light_scores_is_not_a_pass():
    """🔴 이 파일의 핵심. 경량 레인이 팔을 **전혀 구분하지 못하는** 산출물.

    원안 게이트는 여기에 **초록**을 준다(순위 벡터가 같으므로 τ = 1). 현행 게이트는 빨강이고,
    그 빨강이 **순위 때문이 아니라 분해능 때문**임을 출력에 적는다."""
    tied = [7.0, 7.0, 7.0]
    evs = []
    for _ in range(8):
        e = _ev(tied, [10.0, 20.0, 30.0])
        e["light_rank"] = [0, 1, 2]      # 동점 → 인덱스 순으로 매겨진 순위
        e["heavy_rank"] = [0, 1, 2]
        evs.append(e)
    # (a) 원안은 초록을 준다 — 실측
    d = tempfile.mkdtemp(prefix="ng2orig_")
    rp, kp = os.path.join(d, "rho.json"), os.path.join(d, "arm_ranks.json")
    json.dump(_rho(), open(rp, "w", encoding="utf-8"))
    json.dump(_ranks(evs), open(kp, "w", encoding="utf-8"))
    rc0, med0, frac0 = _brief_original(rp, kp)
    assert rc0 == 0 and med0 == 1.0 and frac0 == 0.0, (rc0, med0, frac0)
    # (b) 현행 게이트는 빨강이고 이유가 분해능이다
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "n_events_light_all_tied=8" in out, out
    assert "분해 불가" in out, out
    print("      (원안 게이트 실측: rc=%d, median tau=%.3f, top1_flip=%.1f%%)"
          % (rc0, med0, 100.0 * frac0))


def test_all_tied_heavy_scores_is_not_a_pass():
    """무거운 레인이 안 갈리는 경우 — 팔이 엔진에서 집행되지 않았을 때의 모양."""
    evs = [_ev([1.0, 2.0, 3.0], [5.0, 5.0, 5.0]) for _ in range(6)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "n_events_heavy_all_tied=6" in out, out


def test_ranks_without_scores_are_rejected():
    """순위만 있는 산출물은 거부한다 — 동점을 볼 수 없기 때문이다."""
    evs = [{"arms": list(AR.ACTIVE_MACROS), "light_rank": list(range(len(AR.ACTIVE_MACROS))),
            "heavy_rank": list(range(len(AR.ACTIVE_MACROS)))}
           for _ in range(4)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "점수 벡터가 없다" in out, out


def test_missing_ranks_artifact_names_its_producer():
    """산출물이 없으면 죽고, **누가 그것을 만드는지**를 적는다(지어내지 않는다)."""
    rc, out = _run(_rho(), None)
    assert rc == 1, out
    assert "T13" in out, out


def test_wrong_vocab_is_rejected():
    evs = [_ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) for _ in range(4)]
    rc, out = _run(_rho(), _ranks(evs, vocab="v2-9arms"))
    assert rc == 1, out
    assert "도장" in out, out


def test_arm_id_outside_vocab_is_rejected():
    evs = [_ev([1.0, 2.0, 3.0, 4.0], [10.0, 20.0, 30.0, 40.0], arms=(0, 1, 2, 9))
           for _ in range(4)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "활성 팔이 아니다" in out, out


def test_nonfinite_score_is_rejected():
    evs = [{"arms": list(AR.ACTIVE_MACROS), "light_score": [1.0, 2.0, float("inf")],
            "heavy_score": [10.0, 20.0, 30.0]} for _ in range(4)]
    rc, out = _run(_rho(), _ranks(evs))
    assert rc == 1, out
    assert "비유한" in out, out


def test_missing_score_provenance_is_rejected():
    """`무엇을` 순위 매겼는지 안 적힌 산출물은 판정하지 않는다."""
    evs = [_ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) for _ in range(4)]
    r = _ranks(evs)
    del r["meta"]["light_score"]
    rc, out = _run(_rho(), r)
    assert rc == 1, out
    assert "light_score" in out, out


def test_spread_over_3_is_reported_but_is_not_the_verdict():
    """`ratio_p90/ratio_p10 > 3` 은 **보고**되고 판정을 바꾸지 않는다(브리프 Step 4).

    🔴 이름의 '3'은 팔 개수가 아니라 `SPREAD_LIMIT`(rho ratio 문턱)이다 — 순전한 우연으로
    현행 어휘도 팔 3개(v4-3arms)라 헷갈리기 쉽지만, 이 시험이 재는 것은 스프레드 보고
    로직이지 팔 개수가 아니다. 팔 개수는 순위를 매길 수 있는 최소치(2) 이상이면 그만이고,
    3이든 몇이든 아래 판정에 영향이 없다."""
    evs = [_ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) for _ in range(6)]
    rc, out = _run(_rho(p10=1.0, p90=3.52), _ranks(evs))
    assert "스칼라 ρ 하나로 부족하다" in out, out
    assert rc == 0, out            # 판정은 순위가 정한다
    rc2, out2 = _run(_rho(p10=1.0, p90=1.2), _ranks(evs))
    assert "스칼라 ρ 로 덮인다" in out2, out2
    assert rc2 == 0, out2


def test_rho_that_consulted_ng1_is_flagged():
    """N-G1 을 보고 만든 ρ 는 경고로 드러난다 — 게이트에 맞춘 교정을 조용히 받지 않는다."""
    evs = [_ev([1.0, 2.0, 3.0], [10.0, 20.0, 30.0]) for _ in range(4)]
    rc, out = _run(_rho(ng1=True), _ranks(evs))
    assert "WARN" in out, out


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    n_pass = 0
    for t in tests:
        try:
            t()
        except Exception:
            print("FAIL  %s" % t.__name__)
            traceback.print_exc()
        else:
            print("PASS  %s" % t.__name__)
            n_pass += 1
    print("\n%d/%d passed" % (n_pass, len(tests)))
    return 0 if n_pass == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
