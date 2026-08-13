"""결과 jsonl 의 모든 행이 실제로 자기가 주장하는 정책 레인으로 결정했는지 검사한다.

`tools/monitor/policy.jl:518` 근처는 요청한 정책을 그 순간 쓸 수 없으면 조용히
`enacted = "canonical"` 로 떨어지면서 계속 돈다. 요약 행의 `policy` 필드는 그대로
`"surrogate"` 로 남는다 -- 그래서 보드가 surrogate 를 측정했다고 주장해도 실제 결정은
전부 canonical 이었을 수 있다. 가정이 아니다: 2026-08-12 에 dspy 3.2.1→3.3.0 업그레이드가
DSPy 서비스 안의 surrogate 모델 로드를 깨뜨렸을 때, 갓 돈 보드가 `"policy":"surrogate"` 를
달고 `decisions[*].enacted == ["canonical","canonical","canonical","canonical"]` 를
기록했다. 서비스 쪽 버그는 고쳤고 런 시작 시점 게이트(P9)도 추가했지만, 한 번만 도는
게이트는 3시간짜리 630보드 스윕 도중 서비스가 죽는 걸 못 잡는다. 결과 자체를 검사해야 한다.
"""
import argparse, json, sys
from pathlib import Path


def scan(results_dir, policies):
    """(n_rows, n_decisions, n_no_decisions, violations) 를 돌려준다.
    violations 는 사람이 읽을 문자열 목록."""
    n_rows = 0
    n_decisions = 0
    n_no_decisions = 0
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

                seed = row.get("ood_seed")
                pol = row.get("policy")

                if pol not in policies:
                    violations.append(
                        "%s:%d 알 수 없는 policy=%r (ood_seed=%s, --policies=%s 밖)"
                        % (path.name, lineno, pol, seed, ",".join(policies)))
                    continue

                decisions = row.get("decisions") or []
                if not decisions:
                    n_no_decisions += 1
                    continue

                enacted_vals = [d.get("enacted") for d in decisions]
                n_decisions += len(enacted_vals)
                bad = [e for e in enacted_vals if e != pol]
                if bad:
                    violations.append(
                        "%s:%d ood_seed=%s policy=%r 인데 enacted=%r -- "
                        "레인이 폴백했고 이 행은 policy 가 주장하는 것을 재지 않았다"
                        % (path.name, lineno, seed, pol, enacted_vals))
    return n_rows, n_decisions, n_no_decisions, violations


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--policies", default="noop,surrogate,dspy",
                     help="허용할 policy 값 목록 (콤마 구분)")
    args = ap.parse_args()

    policies = [p.strip() for p in args.policies.split(",") if p.strip()]

    n_rows, n_decisions, n_no_decisions, violations = scan(args.results_dir, policies)
    print("== 레인 무결성 검사: %s (policies=%s) ==" % (args.results_dir,
                                                     ",".join(policies)))
    print("  행 %d개, decisions %d개 검사, 결정 없음 행 %d개"
          % (n_rows, n_decisions, n_no_decisions))
    for v in violations:
        print("  FAIL  " + v)
    if violations:
        print("  위반 %d건" % len(violations))
        return 1
    print("  PASS  모든 행에서 policy == enacted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
