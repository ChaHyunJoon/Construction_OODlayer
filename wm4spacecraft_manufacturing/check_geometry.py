"""결과 jsonl 의 모든 행이 기대한 창고 거리(D)로 생성됐는지 검사한다.

`run_demo.jl:665` 이 요약 행에 `geometry.depot_distance` 를 남긴다. 그 블록이 없는 행은
2026-08-12 이전 세대다 -- 그 시절 기본값은 D=40 이었으므로, 값을 모르는 게 아니라 **다른
세계에서 나온 행**으로 취급해 실패로 본다. 조용히 통과시키면 D=20 표에 D=40 행이 섞인다.

`--min-rows N`(2026-08-13): 이 검사기는 위반이 없으면 통과한다 -- **행이 0개여도** 위반이 0건이라
통과한다. 실제로 `--results-dir /nonexistent_dir_xyz` 도, 데이터가 두 단계 아래 있는
`results_4pol/shards` 도(위 glob 은 재귀가 아니다) 0행을 훑고 `PASS` 를 냈다. 630판을 인증하는
게이트가 오타 하나로 공허하게 통과하면 인증이 아니다. `--min-rows` 를 주면 훑은 행 수가 그 아래일
때 실패한다. 기본값 0 은 기존 동작 그대로다(빈 디렉토리는 기본값에서 의도적으로 통과한다).
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
    ap.add_argument("--min-rows", type=int, default=0,
                     help="훑은 행이 이 수보다 적으면 실패한다(기본 0 = 공허한 통과 허용). "
                          "630판 인증처럼 '몇 행이 있어야 하는지' 를 아는 자리에서 반드시 줄 것.")
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
    if n_rows < args.min_rows:
        print("  FAIL  행이 %d개뿐이다 -- 최소 %d개를 기대했다 (--results-dir %s). "
              "검사할 게 없으면 통과가 아니라 실패다: 디렉토리가 비었거나 경로가 틀렸을 수 있다"
              "(이 검사기의 glob 은 재귀가 아니라서 하위 shards/ 는 안 본다)."
              % (n_rows, args.min_rows, args.results_dir))
        return 1
    print("  PASS  모든 행이 D=%g" % args.expect_depot_distance)
    return 0


if __name__ == "__main__":
    sys.exit(main())
