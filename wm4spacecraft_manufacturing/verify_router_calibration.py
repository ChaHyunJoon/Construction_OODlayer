#!/usr/bin/env python
"""
verify_router_calibration.py -- "이 교정으로 라우터가 실제 데모 사건을 어떻게 판정하는가?"

WHY THIS EXISTS
===============
2026-08-04 진단: 데모의 battery OOD 가 매번 `NEVER SEEN THIS BEFORE` 로 판정됐다. 원인은 종류
판별이 아니라 **발화 시점**이었다 -- 교정 덤프(openworld_merged.jsonl, 60 instance)의
`closed_at_fire` 가 {50,58} 두 값뿐이라 `progress` 의 sd 가 0.0051 이고, 중반(progress 0.41)에
터지는 battery 는 z=45 → cap(8) 로 잘려도 6축 중 혼자 score 의 93% 를 차지한다. 같은 이유로
후반(0.66)에 터진 **fault 도** novel 로 뜬다. 즉 게이트가 "아는 종류인가"가 아니라 "교정과 같은
순간에 터졌나"를 재고 있었다.

이 스크립트는 그 진단과 수정을 **재현 가능한 합격 판정**으로 만든다: 이미 녹화된 모니터 스트림에서
라우터가 실제로 본 서술자 벡터를 그대로 꺼내, 주어진 교정 파일로 score/p 를 다시 계산하고 축별
기여도를 보여준다. 교정을 다시 만든 뒤 이 스크립트를 돌려 battery 가 `familiar` 로 뒤집혔는지
확인한다 -- 새 시뮬레이션을 한 판도 돌리지 않고.

Usage:
    python verify_router_calibration.py [calibration.json] [--streams=a.jsonl,b.jsonl] [--eps=0.05]

    (인자 없이 돌리면 novelty_calibration.json + 2026-08-04 데모 스트림 2개)

[문법 참고]
  - np.clip(x, lo, hi) : 값을 범위로 자름.  - json.loads(line) : JSON 한 줄 -> 파이썬 객체.
"""
import glob
import io
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                      # ConstructionBots.jl
DEFAULT_STREAMS = [
    os.path.join(REPO, "tools", "monitor", "streams", "tractor__fault_battery.jsonl"),
    os.path.join(REPO, "tools", "monitor", "streams", "tractor__fault_zone.jsonl"),
]


def load_calibration(path):
    with io.open(path, encoding="utf-8") as fh:
        b = json.load(fh)
    return {
        "names": b["feature_names"],
        "mu": np.asarray(b["mu"], dtype=float),
        "sd": np.asarray(b["sd"], dtype=float),
        "cap": float(b["cap"]),
        "cal": np.asarray(sorted(b["cal_scores"]), dtype=float),
        "alpha": float(b.get("alpha", 0.05)),
        "p_floor": float(b.get("p_floor", 1e-4)),
        "meta": b.get("meta", {}),
    }


def score_and_p(cal, x):
    """novelty.jl 의 novelty_score / conformal_pvalue 와 **같은 식**(파리티는 test_novelty.jl 이 검사)."""
    z = np.clip((np.asarray(x, dtype=float) - cal["mu"]) / cal["sd"], -cal["cap"], cal["cap"])
    s = float(np.sqrt(np.mean(z * z)))
    c = cal["cal"]
    gt = int(np.sum(c > s))
    eq = int(np.sum(c == s))
    p = (gt + 0.5 * (eq + 1)) / (len(c) + 1)
    return s, float(min(max(p, cal["p_floor"]), 1.0)), z


def router_records(paths):
    """모니터 스트림에서 (event, target, descriptors, 녹화 당시 p) 를 뽑는다.

    respec_history 는 프레임마다 누적 기록되므로 **마지막 프레임 하나**만 읽으면 그 런의 전체
    사건 목록이 나온다(앞 프레임을 다 읽으면 같은 사건이 수백 번 중복된다)."""
    out = []
    for path in paths:
        if not os.path.isfile(path):
            print(f"[warn] stream not found: {path}")
            continue
        last = None
        with io.open(path, encoding="utf-8") as fh:
            for line in fh:
                if '"respec_history"' in line:
                    last = line
        if last is None:
            continue
        for h in json.loads(last).get("respec_history", []):
            inp = h.get("input") or {}
            rt = inp.get("router") or {}
            desc = rt.get("descriptors")
            if not desc:
                continue
            out.append({
                "stream": os.path.basename(path),
                "event": inp.get("event", "?"),
                "target": inp.get("target", ""),
                "desc": [float(v) for v in desc],
                "p_recorded": rt.get("p"),
                "enacted": rt.get("enacted"),
            })
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    calib = args[0] if args else os.path.join(HERE, "novelty_calibration.json")
    eps_arg = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--eps=")), None)
    st = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--streams=")), None)
    streams = []
    for pat in (st.split(",") if st else DEFAULT_STREAMS):
        streams.extend(sorted(glob.glob(pat)) or [pat])

    cal = load_calibration(calib)
    eps = eps_arg if eps_arg is not None else cal["alpha"]
    names = cal["names"]

    print("=" * 96)
    print(f"CALIBRATION  {os.path.relpath(calib, HERE)}")
    print(f"  source={cal['meta'].get('source','?')}  n={cal['meta'].get('n_instances','?')}  "
          f"kinds={cal['meta'].get('kinds','?')}  excluded={cal['meta'].get('excluded_kinds', [])}")
    print(f"  in-distribution score: min={cal['cal'].min():.3f} med={np.median(cal['cal']):.3f} "
          f"max={cal['cal'].max():.3f}   eps={eps}")
    print("-" * 96)
    print(f"  {'feature':18s} {'mu':>8s} {'sd':>9s}   note")
    # 축 하나가 cap 에 잘리면 그 축만으로 score >= cap/sqrt(n_feat) 이 되어 게이트를 지배한다.
    # 6축·cap 8 이면 3.27 인데 교정 최대가 2.21 이므로 **단 한 축의 불일치가 자동 escalate** 를 만든다.
    solo = cal["cap"] / np.sqrt(len(names))
    degenerate = []
    for n, m, s in zip(names, cal["mu"], cal["sd"]):
        note = ""
        if s < 0.02:
            note = "<-- DEGENERATE (교정에 이 축의 분산이 사실상 없음: 조금만 달라도 novel)"
            degenerate.append(n)
        print(f"  {n:18s} {m:8.4f} {s:9.5f}   {note}")
    print(f"\n  한 축만 cap({cal['cap']:.0f}) 에 잘려도 score >= {solo:.2f} "
          f"(교정 최대 {cal['cal'].max():.2f}) -> {'자동 escalate' if solo > cal['cal'].max() else 'ok'}")
    if degenerate:
        print(f"  [WARN] degenerate axes: {degenerate}")

    recs = router_records(streams)
    if not recs:
        print("\n[error] 스트림에서 라우터 레코드를 찾지 못했습니다.")
        return 1

    print("\n" + "=" * 96)
    print("REPLAY  (녹화된 데모 사건을 이 교정으로 다시 판정)")
    print("=" * 96)
    n_novel = 0
    for r in recs:
        s, p, z = score_and_p(cal, r["desc"])
        novel = p < eps
        n_novel += novel
        flag = "NOVEL -> LLM" if novel else "familiar -> surrogate"
        was = r["p_recorded"]
        was_s = f"{was:.4f}" if isinstance(was, (int, float)) else "?"
        print(f"\n  {r['event']:8s} {r['target'][:34]:34s} [{r['stream']}]")
        print(f"    progress={r['desc'][4]:.3f}  score={s:.3f}  p={p:.4f} (녹화당시 p={was_s})  -> {flag}")
        contrib = (z * z) / len(names)
        order = np.argsort(-contrib)
        top = ", ".join(f"{names[i]} z={z[i]:+.2f} ({100*contrib[i]/max(contrib.sum(),1e-12):.0f}%)"
                        for i in order[:3])
        print(f"    dominant axes: {top}")

    print("\n" + "=" * 96)
    print(f"SUMMARY  {n_novel}/{len(recs)} judged NOVEL at eps={eps}")
    batt = [r for r in recs if str(r["event"]).upper().startswith("BATTERY")]
    if batt:
        ok = all(score_and_p(cal, r["desc"])[1] >= eps for r in batt)
        print(f"  ACCEPTANCE (battery must read FAMILIAR): {'PASS' if ok else 'FAIL'}"
              f"   [{len(batt)} battery event(s)]")
        return 0 if ok else 2
    print("  [warn] 스트림에 battery 사건이 없어 합격 판정을 못 했습니다.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
