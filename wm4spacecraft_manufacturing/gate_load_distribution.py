"""P7 -- CPU 부하가 시뮬레이션 결과 분포를 옮기는지 검사한다.

이 저장소의 시뮬레이션은 순차 재실행에서도 재현되지 않는다(2026-08-11 실측: 동일 코드에서
monitor frames 214->204, n_closed 149->123, 원인 미상). 따라서 "단독과 부하 하가 완전히
같아야 한다"는 판정은 쓸 수 없다 -- 병렬이 원인인지 원래 그런지 구분하지 못한 채 무조건
불합격을 낸다. 대신 **분포**를 본다.

한계를 분명히 해 둔다: 8+8 표본은 큰 효과만 잡는다. 이 게이트는 "부하가 결과를 바꾸지
않는다"를 증명하지 않으며, **바꾼다는 뚜렷한 증거가 없음**을 확인하는 장치다.
"""
import argparse, json, sys
from pathlib import Path

from scipy.stats import mannwhitneyu, fisher_exact

MIN_N = 5     # 이보다 적으면 검정력이 사실상 0 이라 "통과"가 의미를 잃는다


def load_samples(root):
    """root/rep*/rows.jsonl 을 읽어 행 목록을 돌려준다."""
    rows = []
    for shard in sorted(Path(root).glob("rep*/rows.jsonl")):
        with open(shard, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def compare_continuous(name, a, b, alpha):
    """(ok, detail). 두 표본이 모두 상수이고 값이 같으면 검정 없이 통과."""
    if set(a) == set(b) and len(set(a)) == 1:
        return True, "%s: 양쪽 모두 상수 %r -- 검정 생략" % (name, a[0])
    stat, p = mannwhitneyu(a, b, alternative="two-sided")
    ok = p > alpha
    return ok, ("%s: Mann-Whitney U=%.1f p=%.4f  (단독 중앙값 %.3f / 부하 중앙값 %.3f)"
                % (name, stat, p, sorted(a)[len(a) // 2], sorted(b)[len(b) // 2]))


def compare_complete(a, b, alpha):
    """a, b 는 bool 목록. 2x2 분할표에 Fisher exact."""
    table = [[sum(1 for x in a if x), sum(1 for x in a if not x)],
             [sum(1 for x in b if x), sum(1 for x in b if not x)]]
    if table[0][1] == 0 and table[1][1] == 0:
        return True, "complete: 양쪽 모두 전판 완주 -- 검정 생략"
    _, p = fisher_exact(table, alternative="two-sided")
    ok = p > alpha
    return ok, ("complete: Fisher exact p=%.4f  (단독 %d/%d 완주 / 부하 %d/%d 완주)"
                % (p, table[0][0], len(a), table[1][0], len(b)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--solo-dir", required=True)
    ap.add_argument("--loaded-dir", required=True)
    ap.add_argument("--alpha", type=float, default=0.05)
    args = ap.parse_args()

    solo = load_samples(args.solo_dir)
    loaded = load_samples(args.loaded_dir)

    print("== P7 분포 게이트 (alpha=%g) ==" % args.alpha)
    print("  단독 표본 %d, 부하 하 표본 %d" % (len(solo), len(loaded)))

    if len(solo) < MIN_N or len(loaded) < MIN_N:
        print("  FAIL  표본이 %d 미만이다. 검정력이 없는 '통과'는 통과가 아니다." % MIN_N)
        return 1

    failures = []
    for key in ("sim_seconds", "closed"):
        a = [r[key] for r in solo if r.get(key) is not None]
        b = [r[key] for r in loaded if r.get(key) is not None]
        if len(a) < MIN_N or len(b) < MIN_N:
            print("  FAIL  %s 값이 있는 행이 부족하다 (단독 %d, 부하 %d)" % (key, len(a), len(b)))
            failures.append(key)
            continue
        ok, detail = compare_continuous(key, a, b, args.alpha)
        print("  %s  %s" % ("PASS" if ok else "FAIL", detail))
        if not ok:
            failures.append(key)

    a = [bool(r.get("complete")) for r in solo]
    b = [bool(r.get("complete")) for r in loaded]
    ok, detail = compare_complete(a, b, args.alpha)
    print("  %s  %s" % ("PASS" if ok else "FAIL", detail))
    if not ok:
        failures.append("complete")

    if failures:
        print("\n불합격 지표: %s" % ", ".join(failures))
        print("K 를 낮춰 재시험하고, 그래도 불합격이면 K=1 순차로 후퇴할 것.")
        return 1
    print("\n부하가 분포를 옮겼다는 증거 없음. 병렬 진행 가능.")
    print("주의: 8+8 표본은 큰 효과만 잡는다. 이것은 안전의 증명이 아니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
