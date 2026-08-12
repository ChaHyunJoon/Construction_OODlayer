#!/usr/bin/env python3
"""results_matrix.py -- 실패 케이스 7종 x 컨트롤러 4종 결과 행렬을 지표 4개로 만든다.

지금까지 발표용 표에는 칸마다 완주 k/n 과 결정 적중률 둘뿐이었다. 여기서는
llm_ood_eval.py 헤더가 정의한 4지표를 전부 같은 칸에 적는다.

  ① 성공률       complete 비율 + Wilson 95% CI
  ② 결정 적중률   reference_policy 의 기준 행동 a* 대비 적중
  ③ 빌드 시간     sim_seconds -- **완주한 판만** 평균. 그래서 n_complete 를 항상 같이 적는다
                 (완주율이 낮은 정책이 시간만 보면 유리해 보이는 censoring 을 숨기지 않으려고)
  ④ 에너지        energy_per_closed 를 주지표로. 총 에너지는 미완주에 유리하므로 쓰지 않는다.
                 min_soc 는 마모 신호로 함께 적는다.

오라클 열은 단축 격자에서 유도한 **상한**이지 온라인 정책이 아니다. 조합 케이스(fault+battery
등)는 격자가 없으므로 '-' 로 남긴다. 없는 숫자를 지어내지 않는다.

세대 혼용 차단: 모든 입력 레코드의 geometry 가 같아야 한다. 창고 배치가 바뀌면 makespan 과
에너지가 통째로 달라지므로, 섞인 입력으로 만든 표는 조용히 틀린 비교가 된다.
"""
import argparse
import json
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from ood_sweep_report import wilson          # noqa: E402
import reference_policy                       # noqa: E402

CASES = ["battery", "fault", "zone", "fault_battery", "fault_zone", "battery_zone", "all"]
CASE_LABEL = {
    "battery": "Battery depletion",
    "fault": "Robot breakdown",
    "zone": "Keep-out zone",
    "fault_battery": "Breakdown + battery",
    "fault_zone": "Breakdown + zone",
    "battery_zone": "Battery + zone",
    "all": "All three at once",
}
# 오라클 격자는 단축 사건에만 존재한다. 조합 케이스는 격자가 없다.
ORACLE_KIND = {"battery": "battery", "fault": "fault", "zone": "zone"}
POLICIES = ["canonical", "surrogate", "dspy"]
POLICY_LABEL = {"canonical": "CANONICAL", "surrogate": "SURROGATE", "dspy": "LLM"}


def load(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def check_geometry(rows, path):
    """모든 레코드의 geometry 가 같은지 확인한다. 다르면(섞였으면), 또는 전부 없으면(구세대
    산출물이면) 표를 만들지 않고 죽는다. 섞인 경우와 전부-없는 경우는 서로 다른 문제라 메시지도
    다르게 낸다 -- 섞인 파일은 눈에 띄지만, 통째로 구세대인 파일은 아무것도 이상해 보이지 않는다."""
    seen = {}
    for r in rows:
        g = r.get("geometry")
        key = "MISSING" if g is None else json.dumps(g, sort_keys=True)
        seen.setdefault(key, 0)
        seen[key] += 1
    if len(seen) > 1:
        print("ERROR  %s 에 서로 다른 기하 세대가 섞여 있다:" % path)
        for k, n in sorted(seen.items(), key=lambda kv: -kv[1]):
            print("       %6d rows  %s" % (n, k))
        raise SystemExit(2)
    only = list(seen)[0]
    if only == "MISSING":
        print("ERROR  %s 의 레코드가 전부 geometry 를 기록하기 이전 세대다 (모든 %d 행에 "
              "geometry 없음) -- 이 파일만으로는 표를 만들 수 없다." % (path, sum(seen.values())))
        raise SystemExit(2)
    return only


def _num(x):
    """레코드 필드 하나를 finite float 로 안전하게 바꾼다. int/float/숫자 문자열은 통과시키고,
    "NaN"/"nan"/"Inf"/"-Inf"/"Infinity" 같은 비유한 표기 문자열과 그 밖에 파싱 불가능한 값은
    None 으로 돌려준다 -- Julia 라벨 덤퍼가 비유한 Float 를 이렇게 문자열로 적어 놓는 경우가
    있다(min_soc, makespan, energy_per_closed, total_energy_J 전부 해당)."""
    if isinstance(x, str):
        try:
            x = float(x)
        except ValueError:
            return None
    elif isinstance(x, (int, float)):
        x = float(x)
    else:
        return None
    return x if math.isfinite(x) else None


def _mean(xs):
    xs = [x for x in (_num(v) for v in xs) if x is not None]   # None/NaN/Inf/비유한 문자열 전부 제거
    return statistics.mean(xs) if xs else None


def cell_from_runs(runs):
    """한 (케이스, 정책) 칸의 4지표. runs 는 그 칸에 속한 런 요약 목록."""
    n = len(runs)
    done = [r for r in runs if r.get("complete")]
    k = len(done)
    scored = correct = 0
    for r in runs:
        s, c, _ = reference_policy.score(r.get("decisions") or [])
        scored += s
        correct += c
    return dict(
        n=n, k=k,
        success=(k / n if n else None),
        success_ci=(wilson(k, n) if n else (None, None)),
        acc=(correct / scored if scored else None),
        n_scored=scored,
        sim_seconds=_mean([r.get("sim_seconds") for r in done]),
        energy_per_closed=_mean([(r.get("battery") or {}).get("energy_per_closed") for r in done]),
        min_soc=_mean([(r.get("battery") or {}).get("min_soc") for r in done]),
    )


def cell_from_oracle(labels, kind):
    """오라클 칸: instance 마다 최선 팔(완주 우선, 동점이면 makespan 최소)을 골라 그 값들을 평균."""
    by_inst = {}
    for r in labels:
        if r.get("kind") != kind:
            continue
        by_inst.setdefault(r["instance"], []).append(r)
    if not by_inst:
        return None

    def key(r):
        ms = _num(r.get("makespan"))
        if ms is None:
            ms = float("inf")
        return (0 if r.get("complete") else 1, ms)      # 완주 우선, 그다음 makespan 최소

    best = [sorted(v, key=key)[0] for v in by_inst.values()]
    k = sum(1 for r in best if r.get("complete"))
    n = len(best)
    done = [r for r in best if r.get("complete")]
    return dict(
        n=n, k=k, success=(k / n if n else None), success_ci=wilson(k, n),
        acc=1.0, n_scored=n,                            # 정의상 오라클은 a* 를 고른다
        sim_seconds=_mean([r.get("makespan") for r in done]),
        energy_per_closed=_mean([r.get("energy_per_closed") for r in done]),
        min_soc=_mean([r.get("min_soc") for r in done]),
    )


def fmt(cell):
    if cell is None:
        return "—"
    pct = "%d/%d" % (cell["k"], cell["n"])
    acc = "—" if cell["acc"] is None else "%.0f%%" % (100 * cell["acc"])
    t = "—" if cell["sim_seconds"] is None else "%.1fs" % cell["sim_seconds"]
    e = "—" if cell["energy_per_closed"] is None else "%.0f J/cl" % cell["energy_per_closed"]
    s = "—" if cell["min_soc"] is None else "SoC %.2f" % cell["min_soc"]
    return "%s · acc %s · %s · %s · %s" % (pct, acc, t, e, s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True, help="런 요약 jsonl (llm_ood_eval 출력)")
    ap.add_argument("--oracle", required=True, help="오라클 라벨 jsonl")
    ap.add_argument("--out", required=True, help="출력 접두사 (.csv/.md 가 붙는다)")
    args = ap.parse_args()

    runs = load(args.runs)
    labels = load(args.oracle)
    geo_runs = check_geometry(runs, args.runs)
    geo_lab = check_geometry(labels, args.oracle)
    if geo_runs != geo_lab:
        print("ERROR  런과 오라클의 기하 세대가 다르다:\n  runs   %s\n  oracle %s" % (geo_runs, geo_lab))
        raise SystemExit(2)

    table = {}
    for case in CASES:
        table[(case, "oracle")] = (cell_from_oracle(labels, ORACLE_KIND[case])
                                   if case in ORACLE_KIND else None)
        for pol in POLICIES:
            sel = [r for r in runs if r.get("case") == case and r.get("policy") == pol]
            table[(case, pol)] = cell_from_runs(sel) if sel else None

    cols = ["oracle"] + POLICIES
    csv_lines = ["case,controller,n,n_complete,success,success_lo,success_hi,"
                 "decision_acc,n_scored,sim_seconds,energy_per_closed,min_soc"]
    for case in CASES:
        for col in cols:
            c = table[(case, col)]
            if c is None:
                csv_lines.append("%s,%s,0,0,,,,,0,,," % (case, col))
                continue
            lo, hi = c["success_ci"]
            csv_lines.append("%s,%s,%d,%d,%s,%s,%s,%s,%d,%s,%s,%s" % (
                case, col, c["n"], c["k"],
                "" if c["success"] is None else "%.4f" % c["success"],
                "" if lo is None else "%.4f" % lo,
                "" if hi is None else "%.4f" % hi,
                "" if c["acc"] is None else "%.4f" % c["acc"], c["n_scored"],
                "" if c["sim_seconds"] is None else "%.3f" % c["sim_seconds"],
                "" if c["energy_per_closed"] is None else "%.3f" % c["energy_per_closed"],
                "" if c["min_soc"] is None else "%.4f" % c["min_soc"]))
    Path(args.out + ".csv").write_text("\n".join(csv_lines) + "\n", encoding="utf-8")

    md = ["# 실패 케이스 x 컨트롤러 결과 행렬", "",
          "각 칸: 완주 k/n · 결정 적중률 · 빌드 시간(완주 판 평균) · 닫힌 노드당 에너지 · 평균 최소 SoC",
          "", "기하 세대: `%s`" % geo_runs, "",
          "| FAILURE CASE | ORACLE | CANONICAL | SURROGATE | LLM |",
          "|---|---|---|---|---|"]
    for case in CASES:
        md.append("| %s | %s |" % (CASE_LABEL[case],
                                   " | ".join(fmt(table[(case, col)]) for col in cols)))
    md += ["",
           "- ORACLE 은 단축 라벨 격자에서 유도한 상한이며 온라인 정책이 아니다. 조합 케이스는 격자가 없어 `—`.",
           "- 빌드 시간은 완주한 판만 평균한다. 완주율이 낮은 칸의 시간은 그만큼 낙관적이다 — k/n 을 같이 볼 것.",
           "- 에너지 주지표는 닫힌 노드당(J/cl)이다. 총 에너지는 일을 덜 한 미완주에 유리해 쓰지 않는다."]
    Path(args.out + ".md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print("wrote %s.csv and %s.md" % (args.out, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
