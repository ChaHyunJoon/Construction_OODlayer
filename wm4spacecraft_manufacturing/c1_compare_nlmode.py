#!/usr/bin/env python
"""
c1_compare_nlmode.py -- C1 을 `raw` 와 `observation` 두 입력 모드에서 돌린 결과를 나란히 놓는다.

무엇을 비교하는가
=================
주입기의 자연어 관찰은 "무슨 일이 있었는가" 뒤에 **"무엇을 하라"**를 붙인다:

    "Robot R1 has broken down at (…) and cannot move; dispatch the nearest backup robot …"
                                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ = Replace

그 뒷절이 곧 canonical 정답이므로, 문장을 그대로 주면 LLM 은 **해석하지 않고 지시만 따라도** 맞는다.
`LLM_NL_MODE=observation` 은 그 절을 떼고 관찰만 남긴다(nl_events.observation_only).

    raw          지시 포함 — LLM 이 얼마나 "시키는 대로" 하는가
    observation  지시 제거 — LLM 이 얼마나 "상황을 읽는가"   <- 우리가 재려던 것

두 수치의 **차이가 곧 공짜 힌트의 크기**다. 차이가 크면 `raw` 로 잰 모든 nl 계열 수치는 능력이
아니라 힌트를 잰 것이다.

읽는 법
    regret 은 0 이 최선, 1 이 최악. `Δ = observation - raw`.
    Δ > 0  지시를 떼자 나빠졌다 = 그만큼 지시에 기대고 있었다(= raw 수치가 부풀려져 있었다)
    Δ < 0  지시를 떼자 좋아졌다 = 지시가 오히려 잘못된 개입을 유도하고 있었다

실행:
    python c1_compare_nlmode.py                                   # 기본 두 파일
    python c1_compare_nlmode.py raw.json observation.json
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np

from verify import paired_bootstrap

DEF_RAW = "artifacts_assimilation/c1_gpt4omini.json"
DEF_OBS = "artifacts_assimilation/c1_gpt4omini_observation.json"


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    praw = args[0] if args else DEF_RAW
    pobs = args[1] if len(args) > 1 else DEF_OBS
    for p in (praw, pobs):
        if not os.path.exists(p):
            print(f"[error] 없는 파일: {p}\n  먼저 두 모드로 c1_novel_kind.py 를 돌리세요:\n"
                  f"    python c1_novel_kind.py --json={DEF_RAW}\n"
                  f"    LLM_NL_MODE=observation python c1_novel_kind.py --json={DEF_OBS}")
            sys.exit(1)
    R, O = load(praw), load(pobs)

    print("=" * 100)
    print("C1 입력 모드 비교:  raw(관찰+지시)  vs  observation(관찰만)")
    print("=" * 100)
    print(f"  raw          : {praw}")
    print(f"  observation  : {pobs}")
    print(f"  model={R.get('model')}  lambda={R.get('lam')}")
    print("  * 문장 끝의 지시 절(= canonical 정답)을 떼면 LLM 이 얼마나 흔들리는지가 곧 공짜 힌트의 크기\n")

    arms = [a for a in R["aggregate"] if a.startswith("llm:")]
    ref = [a for a in R["aggregate"] if not a.startswith("llm:")]

    print(f"  {'arm':<16} {'raw':>8} {'observation':>13} {'Δ(obs-raw)':>12}   판정")
    print("  " + "-" * 74)
    for a in arms:
        if a not in O["aggregate"]:
            continue
        r = np.asarray(O["aggregate"][a]["per_instance"], float)   # observation
        b = np.asarray(R["aggregate"][a]["per_instance"], float)   # raw
        if len(r) != len(b):
            print(f"  {a:<16} (인스턴스 수가 달라 짝지어 비교 불가)")
            continue
        d, lo, hi = paired_bootstrap(r, b)      # 양수 = observation 이 더 나쁨
        sig = "지시에 기대고 있었음" if lo > 0 else (
              "지시가 오히려 방해였음" if hi < 0 else "차이 못 밝힘")
        print(f"  {a:<16} {b.mean():>8.3f} {r.mean():>13.3f} {d:>+12.3f}   {sig}  CI[{lo:+.3f},{hi:+.3f}]")

    print("\n  -- 변하지 않는 기준선(문장을 안 보는 것들. 같아야 정상) --")
    for a in ref:
        if a in O["aggregate"]:
            print(f"     {a:<16} raw={R['aggregate'][a]['regret']:.3f}  "
                  f"obs={O['aggregate'][a]['regret']:.3f}"
                  + ("" if abs(R["aggregate"][a]["regret"] - O["aggregate"][a]["regret"]) < 1e-9
                     else "   ** 달라졌다면 무언가 잘못된 것 **"))

    print("\n  -- 폴드별 (surrogate 는 문장을 안 보므로 두 실행에서 동일) --")
    fr = {f["held_out"]: f for f in R["folds"]}
    fo = {f["held_out"]: f for f in O["folds"]}
    hdr = f"  {'kind':<10} {'surrogate':>10} " + " ".join(f"{a.replace('llm:',''):>11}" for a in arms) + "   (raw→obs)"
    print(hdr)
    for k in fr:
        if k not in fo:
            continue
        cells = []
        for a in arms:
            x = fr[k]["arms"][a]["regret"]
            y = fo[k]["arms"][a]["regret"]
            cells.append(f"{x:.2f}→{y:.2f}".rjust(11))
        print(f"  {k:<10} {fr[k]['arms']['surrogate']['regret']:>10.3f} " + " ".join(cells))

    print("\n  -- 결론 --")
    best_raw = min(arms, key=lambda a: R["aggregate"][a]["regret"])
    best_obs = min([a for a in arms if a in O["aggregate"]],
                   key=lambda a: O["aggregate"][a]["regret"])
    s = R["aggregate"]["surrogate"]["regret"]
    print(f"     surrogate                       {s:.3f}")
    print(f"     최고 LLM arm (raw)         {best_raw:>14}  {R['aggregate'][best_raw]['regret']:.3f}")
    print(f"     최고 LLM arm (observation) {best_obs:>14}  {O['aggregate'][best_obs]['regret']:.3f}")
    print("     => 발표에서 nl 계열 수치를 인용할 때는 반드시 어느 모드인지 밝힐 것.")


if __name__ == "__main__":
    main()
