"""hazard 레인이 **실제로 발화하는가** (spec §11-2 게이트 · L6).

  '구현돼 있다' 와 '돈다' 는 다르다. HAZARD_ENABLED 가 기본 false 이고 현행 630판이 이
  레인으로 안 돌았으므로, 켠 뒤 첫 질문은 성능이 아니라 **발화율**이다.

  python probe_hazard.py /tmp/hz_on.jsonl [/tmp/hz_off.jsonl]
"""
import json
import sys


def summarize(path):
    n, on, ev = 0, 0, {"n_break": 0, "n_cell": 0, "n_zone": 0}
    stamps, steps = set(), 0
    with open(path) as fh:
        for line in fh:
            r = json.loads(line)
            n += 1
            stamps.add(r.get("dynamics"))
            h = r.get("hazard") or {}
            if h.get("enabled"):
                on += 1
                for k in ev:
                    ev[k] += int(h.get(k) or 0)
                steps += int(h.get("steps") or 0)
    return {"path": path, "n_runs": n, "n_hazard_on": on, "events": ev,
            "steps": steps, "dynamics_stamps": sorted(x for x in stamps if x)}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for p in argv[1:]:
        s = summarize(p)
        print("=== %s ===" % s["path"])
        print("  판 %d · hazard on %d · 스텝 합 %d" % (s["n_runs"], s["n_hazard_on"], s["steps"]))
        print("  발화: %s" % s["events"])
        print("  동역학 도장: %s" % s["dynamics_stamps"])
        if s["n_hazard_on"] and sum(s["events"].values()) == 0:
            print("  🔴 hazard 는 켜졌는데 발화가 0건이다 — 파라미터가 이 지평선에 안 맞거나 "
                  "훅이 안 걸렸다. expected_hazard_events 로 기대값을 먼저 재라.")
        if len(s["dynamics_stamps"]) > 1:
            print("  🔴 한 파일에 동역학 세대가 둘 이상 섞여 있다.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
