"""결과 jsonl 의 모든 행이 기대한 창고 거리(D)로 생성됐는지 검사한다.

`run_demo.jl:665` 이 요약 행에 `geometry.depot_distance` 를 남긴다. 그 블록이 없는 행은
2026-08-12 이전 세대다 -- 그 시절 기본값은 D=40 이었으므로, 값을 모르는 게 아니라 **다른
세계에서 나온 행**으로 취급해 실패로 본다. 조용히 통과시키면 D=20 표에 D=40 행이 섞인다.
"""
import argparse, json, sys
from pathlib import Path


def scan(results_dir, expect):
    """(n_rows, violations) 를 돌려준다. violations 는 사람이 읽을 문자열 목록."""
    n_rows = 0
    violations = []
    for path in sorted(Path(results_dir).glob("*.jsonl")):
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                n_rows += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as e:
                    violations.append("%s:%d 파싱 불가 (%s)" % (path.name, lineno, e))
                    continue
                geom = row.get("geometry")
                seed = row.get("ood_seed")
                pol = row.get("policy")
                if not isinstance(geom, dict):
                    violations.append(
                        "%s:%d geometry 블록 없음 -- 2026-08-12 이전 세대 행 "
                        "(ood_seed=%s policy=%s)" % (path.name, lineno, seed, pol))
                    continue
                got = geom.get("depot_distance")
                if got != expect:
                    violations.append(
                        "%s:%d depot_distance=%r, 기대값 %r (ood_seed=%s policy=%s)"
                        % (path.name, lineno, got, expect, seed, pol))
    return n_rows, violations


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--expect-depot-distance", type=float, default=20.0)
    args = ap.parse_args()

    n_rows, violations = scan(args.results_dir, args.expect_depot_distance)
    print("== 기하 provenance 검사: %s (기대 D=%g) ==" % (args.results_dir,
                                                        args.expect_depot_distance))
    print("  행 %d개 검사" % n_rows)
    for v in violations:
        print("  FAIL  " + v)
    if violations:
        print("  위반 %d건" % len(violations))
        return 1
    print("  PASS  모든 행이 D=%g" % args.expect_depot_distance)
    return 0


if __name__ == "__main__":
    sys.exit(main())
