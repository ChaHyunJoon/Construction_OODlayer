"""hazard 레인이 **실제로 발화하는가** (spec §11-2 게이트 · L6).

  '구현돼 있다' 와 '돈다' 는 다르다. HAZARD_ENABLED 가 기본 false 이고 현행 630판이 이
  레인으로 안 돌았으므로, 켠 뒤 첫 질문은 성능이 아니라 **발화율**이다.

  python probe_hazard.py /tmp/hz_on.jsonl [/tmp/hz_off.jsonl]
"""
import json
import sys


def summarize(path):
    n, on, ev = 0, 0, {"n_break": 0, "n_cell": 0, "n_zone": 0}
    pend = {"n_break_pending": 0, "n_cell_pending": 0}
    stamps, steps, n_stamp_missing = set(), 0, 0
    with open(path) as fh:
        for line in fh:
            r = json.loads(line)
            n += 1
            d = r.get("dynamics")
            if d is None:
                n_stamp_missing += 1     # 리뷰 라운드 1 (소견): 도장 부재는 도장 불일치보다
            else:                        # 덜하지 않다(spec §8) — 조용히 버리지 않고 센다.
                stamps.add(d)
            h = r.get("hazard") or {}
            if h.get("enabled"):
                on += 1
                for k in ev:
                    ev[k] += int(h.get(k) or 0)
                for k in pend:
                    pend[k] += int(h.get(k) or 0)   # 리뷰 라운드 1 (소견 3): 모형-vs-엔진 구분
                steps += int(h.get("steps") or 0)
    return {"path": path, "n_runs": n, "n_hazard_on": on, "events": ev, "pending": pend,
            "steps": steps, "dynamics_stamps": sorted(stamps), "n_stamp_missing": n_stamp_missing}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for p in argv[1:]:
        s = summarize(p)
        print("=== %s ===" % s["path"])
        print("  판 %d · hazard on %d · 스텝 합 %d" % (s["n_runs"], s["n_hazard_on"], s["steps"]))
        print("  발화: %s" % s["events"])
        print("  유예(모형은 넘었으나 엔진이 못 일으킨 시계): %s" % s["pending"])
        print("  동역학 도장: %s" % s["dynamics_stamps"])
        if s["n_stamp_missing"]:
            print("  🔴 dynamics 도장이 없는 레코드 %d건 — 구세대 취급, remap 하지 말고 죽일 것"
                  " (spec §8)." % s["n_stamp_missing"])
        if s["n_hazard_on"] and sum(s["events"].values()) == 0:
            print("  🔴 hazard 는 켜졌는데 발화가 0건이다 — 파라미터가 이 지평선에 안 맞거나 "
                  "훅이 안 걸렸다. expected_hazard_events 로 기대값을 먼저 재라.")
        if sum(s["pending"].values()) > 0:
            print("  ⚠️ 유예된 시계가 있다 — 모형이 낸 사건 수와 엔진이 집행한 사건 수가 다르다"
                  "(hazard_report 독스트링의 구분). n_break/n_cell 만 보고 '발화 0건'을 논하지 말 것.")
        if len(s["dynamics_stamps"]) > 1:
            print("  🔴 한 파일에 동역학 세대가 둘 이상 섞여 있다.")
        # n_zone 은 이 커밋이 노출한 손잡이(DEMO_HAZARD/DEMO_HAZARD_SEED)로는 mtbf_zone_s=Inf
        # 가 기본이라 구조적으로 항상 0이다 — params 를 넘길 ENV 가 없다. 장식임을 매번 명시한다.
        print("  참고: n_zone 은 이 레인에서 구조적으로 0이다(mtbf_zone_s=Inf 기본, params 를"
              " 넘기는 ENV 없음) — zone 경로가 죽었다는 뜻이 아니라 이 손잡이로는 시험되지"
              " 않는다는 뜻이다.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
