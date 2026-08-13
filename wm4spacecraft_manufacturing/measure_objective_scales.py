#!/usr/bin/env python3
"""목적함수 J 의 스케일 상수를 기존 세대 런에서 측정한다 (spec §4, §8 단계 3).

    M_ref / E_ref  = 완주 런의 makespan / energy_J 중앙값 → w_E = kappa * M_ref / E_ref
    T_scale        = M_ref 와 같다 (J 의 시간항 규모 = 런의 시간 규모)
    Eg_scale       = greedy 한 배정 결정 하나의 에너지 규모.
                     직접 계측한 적이 없으므로 여기서는 **런 에너지 / 닫힌 노드 수**로 근사한다
                     (= 결정 한 건이 평균적으로 지불하는 에너지). 근사임을 notes 에 명시한다.

이 스크립트는 아무 파일도 고치지 않는다 — JSON 리포트만 stdout/‑o 로 낸다.
objective.json 은 태스크 4 가 이 리포트를 읽어 만든다.

사용:
    .venv/bin/python measure_objective_scales.py -o /path/to/report.json
"""
import argparse, glob, json, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _rows(patterns):
    """주어진 glob 패턴들에서 JSONL 행을 전부 읽는다. 깨진 줄은 건너뛴다."""
    seen_files = []
    for pat in patterns:
        for path in sorted(glob.glob(os.path.join(HERE, pat))):
            seen_files.append(os.path.relpath(path, HERE))
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line), path
                    except json.JSONDecodeError:
                        continue
    _rows.files = seen_files


def _makespan(row):
    """실현 makespan. 신세대 행은 'makespan', 구세대 행은 'sim_seconds'(같은 dt*steps 계산)."""
    for k in ("makespan", "sim_seconds"):
        v = row.get(k)
        if isinstance(v, (int, float)) and v > 0:
            return float(v)
    return None


def _energy(row):
    """실현 구동에너지[J]. 4pol 레인은 battery 하위, 오라클 레인은 최상위 energy_J."""
    v = row.get("energy_J")
    if isinstance(v, (int, float)) and v > 0:
        return float(v)
    b = row.get("battery") or {}
    v = b.get("total_energy_J")
    if isinstance(v, (int, float)) and v > 0:
        return float(v)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=None, help="리포트 JSON 경로 (없으면 stdout)")
    ap.add_argument("--glob", action="append", default=None,
                    help="스캔할 glob 패턴 (반복 가능). 기본: results_4pol 계열 전부")
    args = ap.parse_args()

    patterns = args.glob or [
        "results_4pol/*.jsonl",
        "results_4pol*/shards/*/*/rows.jsonl",
        "results_oracle*/shards/*/*/rows.jsonl",
    ]

    mks, ens, per_closed = [], [], []
    n_total = n_complete = 0
    files = []
    for row, path in _rows(patterns):
        n_total += 1
        if path not in files:
            files.append(os.path.relpath(path, HERE))
        if not row.get("complete"):
            continue
        m, e = _makespan(row), _energy(row)
        if m is None or e is None:
            continue
        n_complete += 1
        mks.append(m)
        ens.append(e)
        closed = row.get("closed") or 0
        if closed > 0:
            per_closed.append(e / closed)

    if n_complete == 0:
        print(json.dumps({"error": "완주 + makespan + energy 를 모두 가진 행이 하나도 없다",
                          "n_rows_scanned": n_total, "files": files[:20]},
                         ensure_ascii=False, indent=2))
        return 1

    M_ref = statistics.median(mks)
    E_ref = statistics.median(ens)
    Eg_scale = statistics.median(per_closed) if per_closed else None

    notes = []
    if n_complete < 30:
        notes.append("표본 부족(완주 %d건 < 30) — κ 의 실효 크기가 흔들릴 수 있다 (spec §11-3)" % n_complete)
    notes.append("Eg_scale 은 직접 계측이 아니라 '런 에너지 / 닫힌 노드 수'의 중앙값 근사다 "
                 "(greedy 결정 한 건의 에너지 규모를 계측한 적이 없다).")
    notes.append("구세대 행은 makespan 키가 없어 sim_seconds(= dt × steps, 같은 계산)를 썼다.")

    report = {
        "M_ref": M_ref,
        "E_ref": E_ref,
        "T_scale": M_ref,     # J 의 시간항 규모 = 런의 makespan 규모
        "Eg_scale": Eg_scale,
        "n_samples": n_complete,
        "n_rows_scanned": n_total,
        "makespan_stats": {"median": M_ref, "min": min(mks), "max": max(mks),
                           "stdev": statistics.stdev(mks) if len(mks) > 1 else 0.0},
        "energy_stats": {"median": E_ref, "min": min(ens), "max": max(ens),
                         "stdev": statistics.stdev(ens) if len(ens) > 1 else 0.0},
        "sources": files[:50],
        "notes": notes,
    }
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text + "\n")
        print("wrote %s" % args.out)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
