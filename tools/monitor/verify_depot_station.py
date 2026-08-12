#!/usr/bin/env python3
"""verify_depot_station.py -- 파견되지 않은 예비 로봇이 자기 창고를 지켰는지 스트림으로 검증한다.

이 검사가 존재하는 이유: 유휴 스페어도 RVO 에이전트라, 분산 포텐셜장에 밀려 창고를 떠나
한쪽 구석에 정체하던 버그가 있었다(2026-08-12). 그 버그는 단위검사로는 안 잡히고 오직
"오래 돌린 뒤의 위치"로만 드러난다.

사용법:
    python tools/monitor/verify_depot_station.py <stream.jsonl> [--tol 1.0]

허용오차 tol 의 기본값 1.0 은 창고 패드 반폭(halfw)을 넉넉히 덮는 값이다. 창고에 주차된
로봇은 패드 안에 있어야 하므로, 이보다 크게 벗어나면 정박이 깨진 것이다.
종료코드 0 = 통과, 1 = 위반.
"""
import json
import math
import sys


def main(argv):
    if not argv:
        print("usage: verify_depot_station.py <stream.jsonl> [--tol T]")
        return 2
    path = argv[0]
    tol = 1.0
    if "--tol" in argv:
        tol = float(argv[argv.index("--tol") + 1])

    frames = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                frames.append(json.loads(line))
    if not frames:
        print("FAIL  empty stream: %s" % path)
        return 1
    if "depots" not in frames[0]:
        print("FAIL  stream has no 'depots' field -- regenerate it after Task 2")
        return 1

    violations = []
    n_checked = 0
    for fi, fr in enumerate(frames):
        pos = {r["id"]: r["pos"] for r in fr.get("robots", []) if r.get("pos")}
        for depot in fr.get("depots", []):
            cx, cy = depot["center"]
            for rid in depot.get("spares", []):
                p = pos.get(rid)
                if p is None:          # 창고에 있으나 프레임에 위치가 없으면 검사 불가
                    continue
                n_checked += 1
                d = math.hypot(p[0] - cx, p[1] - cy)
                if d > tol:
                    violations.append((fi, depot["side"], rid, round(d, 2)))

    if n_checked == 0:
        print("FAIL  no parked spare was observed -- nothing was verified")
        return 1
    if violations:
        print("FAIL  %d/%d parked-spare observations drifted beyond tol=%.2f" %
              (len(violations), n_checked, tol))
        for v in violations[:10]:
            print("      frame %d  depot :%s  robot %s  dist %.2f" % v)
        return 1
    print("PASS  %d parked-spare observations, all within tol=%.2f of their depot" %
          (n_checked, tol))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
