#!/usr/bin/env python
"""
rb_analyze.py -- RelocateBuild(매크로 7) 검증 리포트.

답하려는 질문은 하나다: **zone 사건에서 개입 팔이 NOOP 과 갈리는가.**
2026-08-03 이전의 zoneblk 데이터는 결정적 n = 0 이었다 — ForbidZone(3) 이 restage 대상이
하나도 없어 조용한 no-op 으로 붕괴했고, 그래서 두 팔의 (complete, closed, makespan) 이
바이트 단위로 같았기 때문이다. RelocateBuild(7) 는 그 전제조건이 없다. 그러니 이 스크립트가
재는 것은 정확도가 아니라 **동점률**이다: 동점 100% 가 아니게 되면 고쳐진 것이고,
동점 100% 그대로면 안 고쳐진 것이다.

  python rb_analyze.py "oracle/out/rb_zone/ep_s*.jsonl" [--baseline "oracle/out/hz_k1/ep_s*.jsonl"]

로그(.log/.err)가 같은 폴더에 있으면 엔진 쪽 증거([WHOLE-BUILD] 발화 횟수, 거부/폴백)도 센다.
"""
import sys, os, glob, json, math, argparse, re
from collections import Counter, defaultdict

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

MACRO_NAME = {0: "NOOP", 1: "Replace", 2: "Deprioritize", 3: "ForbidZone",
              4: "ReformTeam", 7: "RelocateBuild"}


def _f(v, d=float("nan")):
    if isinstance(v, str):
        if v in ("Inf", "inf"):
            return float("inf")
        if v in ("-Inf", "-inf"):
            return float("-inf")
        if v in ("NaN", "nan"):
            return float("nan")
        try:
            return float(v)
        except ValueError:
            return d
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def outcome(r):
    """한 판의 결과를 비교 가능한 튜플로. 클수록 좋다(feasibility-lexicographic).

    makespan 은 완주한 판에서만 의미가 있으므로, 미완주는 -inf 로 눌러 완주 판에 절대 못 이기게 한다.
    """
    mk = _f(r.get("makespan"))
    comp = bool(r.get("complete"))
    return (1 if comp else 0, int(r.get("closed", 0)),
            -(mk if (comp and math.isfinite(mk)) else 1e18))


def load(patterns):
    rows = []
    for pat in patterns:
        for f in sorted(glob.glob(pat)):
            # ep_s301.probes.jsonl 도 ep_s*.jsonl 에 걸린다. probe 행은 결정이 아니라 고정스텝
            # 상태 스냅샷이라 kind 가 없다 — 섞이면 종류 분포가 거짓말을 한다.
            if ".probes." in os.path.basename(f):
                continue
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return rows


def group(rows, kind=None):
    """instance -> {macro: row}. kind 를 주면 그 종류만."""
    g = defaultdict(dict)
    for r in rows:
        if not r.get("fired", True):
            continue
        if kind and str(r.get("kind")) != kind:
            continue
        g[r["instance"]][int(r["macro"])] = r
    return g


def report(g, title):
    print(f"\n=== {title} ===")
    if not g:
        print("  (행 없음 — 사건이 한 번도 발화하지 않았다는 뜻이다)")
        return dict(n=0, tie=0, decisive=0)
    # 팔이 하나뿐인 instance 는 "동점"이 아니라 **비교 불가**다(예: DS_EP_MACROS=7 로 돈 진단 실행).
    # 이걸 동점으로 세면 진단 폴더가 FAIL 로 찍히는 거짓 경보가 난다.
    single = [i for i, arms in g.items() if len(arms) < 2]
    g = {i: arms for i, arms in g.items() if len(arms) >= 2}
    if single:
        print(f"  (팔이 1개뿐이라 비교 불가한 instance {len(single)}개 제외: {', '.join(sorted(single)[:4])})")
    if not g:
        print("  비교 가능한 instance 없음")
        return dict(n=0, tie=0, decisive=0, single=len(single))
    n_tie = 0
    decisive = []
    best_counter = Counter()
    complete_cells = 0
    total_cells = 0
    print(f"  {'instance':<24} {'closed@fire':>11}  " +
          "  ".join(f"{MACRO_NAME.get(m, m):>14}" for m in (0, 3, 7)) + "   판정")
    for inst in sorted(g):
        arms = g[inst]
        outs = {m: outcome(r) for m, r in arms.items()}
        total_cells += len(arms)
        complete_cells += sum(1 for r in arms.values() if r.get("complete"))
        uniq = set(outs.values())
        tie = len(uniq) <= 1
        n_tie += tie
        best = max(outs, key=lambda m: outs[m]) if outs else None
        if not tie:
            decisive.append(inst)
            best_counter[best] += 1
        caf = int(_f(next(iter(arms.values())).get("closed_at_fire"), -1))
        cells = []
        for m in (0, 3, 7):
            if m in arms:
                r = arms[m]
                cells.append(f"{'C' if r.get('complete') else ' '}{int(r.get('closed', 0)):>4}/"
                             f"{int(r.get('total', 0)):<4}".rjust(14))
            else:
                cells.append(" " * 14)
        verdict = "동점" if tie else f"BEST={MACRO_NAME.get(best, best)}"
        print(f"  {inst:<24} {caf:>11}  " + "  ".join(cells) + f"   {verdict}")
    n = len(g)
    print(f"\n  instance {n}  ·  동점 {n_tie} ({100.0*n_tie/n:.0f}%)  ·  "
          f"**결정적 n = {len(decisive)}**  ·  완주셀 {complete_cells}/{total_cells}")
    if best_counter:
        print("  결정적 instance 의 정답 팔: " +
              ", ".join(f"{MACRO_NAME.get(m, m)}={c}" for m, c in best_counter.most_common()))
    return dict(n=n, tie=n_tie, decisive=len(decisive), best=dict(best_counter),
                single=len(single))


LOG_PATTERNS = {
    "zone 사건 발화(truth 기록)":      re.compile(r"no-go exclusion zone has appeared"),
    "[RESPEC] relocate 검증 통과":     re.compile(r"whole-build relocation verified"),
    "[WHOLE-BUILD] 실제 평행이동":     re.compile(r"\[WHOLE-BUILD\] translated"),
    "-> admitted (전체이동 성공)":     re.compile(r"whole-build translated .* -> admitted"),
    "전체이동 실패 -> fallback":        re.compile(r"whole-build (residual_blocked|infeasible|no_staging)"),
    "relocate 제안 REJECTED":          re.compile(r"relocate proposal REJECTED"),
    "[RESTAGE-ALL] (옛 경로)":          re.compile(r"\[RESTAGE-ALL\]"),
}


def scan_logs(d):
    files = sorted(glob.glob(os.path.join(d, "*.log"))) + sorted(glob.glob(os.path.join(d, "*.err")))
    if not files:
        return
    counts = Counter()
    for f in files:
        try:
            txt = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for name, rx in LOG_PATTERNS.items():
            counts[name] += len(rx.findall(txt))
    print(f"\n=== 엔진 로그 증거 ({len(files)} 파일) ===")
    for name in LOG_PATTERNS:
        print(f"  {counts[name]:>5}  {name}")
    if not any(counts.values()):
        # 전부 0 인 것은 "안 일어났다"가 아니라 "안 찍혔다"일 수 있다. 생성기의 기본 로그 레벨이
        # Warn 이라 @info(=[RESPEC]/[WHOLE-BUILD])는 아예 기록되지 않는다. 둘을 혼동하면
        # "엔진이 아무것도 안 했다"는 잘못된 결론이 나온다.
        print("  (전부 0 — 이 실행들은 DS_LOG 기본값(warn)이라 @info 가 기록되지 않는다."
              " 엔진 증거는 DS_LOG=info 로 돌린 폴더에서 봐야 한다)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("globs", nargs="+")
    ap.add_argument("--baseline", default=None,
                    help="비교용 옛 zoneblk 덤프 glob (ForbidZone 시대)")
    a = ap.parse_args()

    rows = load(a.globs)
    print(f"로드: {len(rows)} 행  ({', '.join(a.globs)})")
    kinds = Counter(str(r.get("kind")) for r in rows)
    print(f"종류 분포: {dict(kinds)}")

    cur = report(group(rows, kind="zoneblk"), "신규 · zoneblk (팔 = NOOP vs RelocateBuild)")

    base = None
    if a.baseline:
        brows = load([a.baseline])
        base = report(group(brows, kind="zoneblk"), "기준선 · zoneblk (팔 = NOOP vs ForbidZone)")

    print("\n=== 판정 ===")
    if cur["n"] == 0 and cur.get("single"):
        print(f"  N/A — 비교 가능한 instance 가 없다(팔이 1개뿐인 진단 실행 {cur['single']}개). "
              "동점/결정 판정은 팔이 2개 이상일 때만 의미가 있다.")
    elif cur["n"] == 0:
        print("  MISS — zone 사건이 한 번도 발화하지 않았다. 주입기 자격 필터를 다시 봐야 한다.")
    elif cur["decisive"] == 0:
        print(f"  FAIL — {cur['n']} instance 전부 동점. RelocateBuild 가 여전히 NOOP 과 같은 결과다.")
    else:
        pct = 100.0 * cur["decisive"] / cur["n"]
        print(f"  PASS — 결정적 instance {cur['decisive']}/{cur['n']} ({pct:.0f}%). "
              f"zone 사건이 더 이상 정보 0 이 아니다.")
        if base and base["n"]:
            print(f"         (기준선 ForbidZone: 결정적 {base['decisive']}/{base['n']})")

    for d in {os.path.dirname(g) for g in a.globs}:
        scan_logs(d)


if __name__ == "__main__":
    main()
