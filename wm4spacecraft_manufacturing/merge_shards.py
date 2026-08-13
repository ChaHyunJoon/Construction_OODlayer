"""샤드별 rows.jsonl 을 case 단위 평면 jsonl 로 병합한다.

build_final_table.py:301 이 `results_dir / "<case>.jsonl"` 를 읽으므로, 병렬 스윕이 만든
샤드 트리를 그 형태로 되돌려 놓아야 기존 리포트 도구가 수정 없이 돈다.

정렬이 핵심이다. 병렬에서는 샤드 완료 순서가 실행마다 다르므로, 완료 순서대로 붙이면 같은
데이터에서 매번 다른 파일이 나온다. (ood_seed, policy 정의 순서)로 정렬해 결정적으로 만든다.
"""
import argparse, json, sys
from pathlib import Path


def read_shard(path):
    """샤드 rows.jsonl 을 읽어 (rows, bad_lines) 로 돌려준다."""
    rows, bad = [], 0
    if not path.exists():
        return rows, bad
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    return rows, bad


def merge_case(shards_dir, case, seeds, policies):
    """(rows_sorted, problems) 를 돌려준다. problems 는 사람이 읽을 문자열 목록."""
    rank = {p: i for i, p in enumerate(policies)}
    case_dir = shards_dir / case
    problems = []
    if not case_dir.is_dir():
        problems.append("case=%s 의 샤드 디렉토리가 없다: %s" % (case, case_dir))
        return [], problems

    found = {}          # (seed, policy) -> row
    for seed in seeds:
        shard = case_dir / ("s%d" % seed) / "rows.jsonl"
        rows, bad = read_shard(shard)
        if bad:
            problems.append("case=%s seed=%d 파싱 불가한 줄 %d개" % (case, seed, bad))
        for r in rows:
            pol = r.get("policy")
            if pol not in rank:
                problems.append("case=%s seed=%d 알 수 없는 policy=%r" % (case, seed, pol))
                continue
            key = (seed, pol)
            if key in found:
                problems.append("case=%s seed=%d policy=%s 행이 중복" % (case, seed, pol))
                continue
            found[key] = r

    for seed in seeds:
        for pol in policies:
            if (seed, pol) not in found:
                problems.append("case=%s seed=%d policy=%s 행이 없다" % (case, seed, pol))

    ordered = [found[(s, p)] for s in seeds for p in policies if (s, p) in found]
    return ordered, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--shards-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--cases", required=True, help="쉼표 구분")
    ap.add_argument("--seeds", required=True, help="쉼표 구분")
    ap.add_argument("--policies", default="noop,surrogate,dspy")
    args = ap.parse_args()

    shards_dir = Path(args.shards_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cases = [c.strip() for c in args.cases.split(",") if c.strip()]
    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    policies = [p.strip() for p in args.policies.split(",") if p.strip()]
    expected = len(seeds) * len(policies)

    all_problems = []
    print("== 샤드 병합: %s -> %s ==" % (shards_dir, out_dir))
    for case in cases:
        rows, problems = merge_case(shards_dir, case, seeds, policies)
        out_path = out_dir / ("%s.jsonl" % case)
        # 이어붙이기가 아니라 덮어쓰기다. 재실행이 행을 두 배로 만들면 안 된다.
        with open(out_path, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        status = "OK" if (not problems and len(rows) == expected) else "INCOMPLETE"
        print("  %-11s %-14s %d/%d 행 -> %s" % (status, case, len(rows), expected,
                                                out_path.name))
        for p in problems:
            print("      - " + p)
        all_problems.extend(problems)

    if all_problems:
        print("\n문제 %d건. 병합 결과를 리포트에 쓰지 말 것." % len(all_problems))
        return 1
    print("\n모든 case 가 %d행으로 완전하다." % expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
