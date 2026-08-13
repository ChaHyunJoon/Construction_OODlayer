#!/usr/bin/env python3
"""목적함수 J 의 스케일 상수를 기존 세대 런에서 측정한다 (spec §4, §8 단계 3).

    M_ref / E_ref  = 완주 런의 makespan / energy_J 중앙값 → w_E = kappa * M_ref / E_ref
    T_scale        = M_ref 와 같다 (J 의 시간항 규모 = 런의 시간 규모)
    Eg_scale       = greedy 한 배정 결정 하나의 에너지 규모.
                     직접 계측한 적이 없으므로 여기서는 **런 에너지 / 닫힌 노드 수**로 근사한다
                     (= 결정 한 건이 평균적으로 지불하는 에너지). 근사임을 notes 에 명시한다.

이 스크립트는 아무 파일도 고치지 않는다 — JSON 리포트만 stdout/‑o 로 낸다.
objective.json 은 태스크 4 가 이 리포트를 읽어 만든다.

**세대 가드 (2026-08-13 최종 리뷰 I-1).** 이 스크립트가 내는 중앙값은 objective.json 의
M_ref/E_ref 로 되박힌다 — 즉 **다음 세대의 상수를 정의하는 도구**다. 그런데 여기서 서로 다른
목적함수 세대의 행을 한 중앙값으로 섞으면, 그 혼입이 상수 자체에 각인되고 이후 어떤 해시
검사로도 드러나지 않는다. spec §7 의 `generation`/`objective_hash` 필드가 막으려는 바로 그
경로다. 그래서 기본 동작은 **섞이면 멈춘다**:

  · 스캔한 행의 `objective_hash` 분포를 항상 리포트에 낸다(`generation_breakdown`).
  · 표본에 서로 다른 세대가 둘 이상이면 exit 1. `--generation <hash|current|none>` 로 하나만
    고르거나, 의도적으로 섞을 때만 `--allow-mixed` 를 준다(그 사실이 notes 에 남는다).
  · `objective_hash` 필드가 없는 행은 `"<none>"` 세대다 = 그 필드가 배선되기 전의 구세대.

사용:
    .venv/bin/python measure_objective_scales.py -o /path/to/report.json
    .venv/bin/python measure_objective_scales.py --generation current   # 신세대만
"""
import argparse, glob, json, math, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import objective  # noqa: E402

NO_GEN = "<none>"   # objective_hash 필드가 아예 없는 행의 세대 딱지


def _generation(row):
    """행이 스스로 밝힌 목적함수 세대. 없으면 NO_GEN(= 배선 전 구세대)."""
    v = row.get("objective_hash")
    return str(v) if isinstance(v, str) and v else NO_GEN


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
    """실현 구동에너지[J]. 4pol 레인은 battery 하위, 오라클 레인은 최상위 energy_J.

    판정은 `> 0` 이 아니라 **"있고 유한한가"** 다(M-4). `> 0` 이면 진짜로 0 J 를 쓴 완주 런이
    '값 없음'으로 분류돼 표본에서 빠지고, 남은 표본의 중앙값이 위로 치우친다 — 그 중앙값이
    그대로 E_ref/Eg_scale 이 되므로 편향이 목적함수 상수에 각인된다. 없음(None)과 0 은 다르다."""
    def ok(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    v = row.get("energy_J")
    if ok(v):
        return float(v)
    v = (row.get("battery") or {}).get("total_energy_J")
    if ok(v):
        return float(v)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=None, help="리포트 JSON 경로 (없으면 stdout)")
    ap.add_argument("--glob", action="append", default=None,
                    help="스캔할 glob 패턴 (반복 가능). 기본: results_4pol 계열 전부")
    ap.add_argument("--generation", default=None,
                    help="이 세대의 행만 측정한다. 16자 objective_hash, 또는 'current'"
                         "(= 현재 objective.json 의 해시), 또는 'none'(= objective_hash 필드가 "
                         "없는 배선 전 구세대).")
    ap.add_argument("--allow-mixed", action="store_true",
                    help="세대가 섞여 있어도 진행한다. 기본은 exit 1 로 멈춘다 (spec §7).")
    args = ap.parse_args()

    want_gen = args.generation
    if want_gen == "current":
        want_gen = objective.objective_hash()
    elif want_gen == "none":
        want_gen = NO_GEN

    patterns = args.glob or [
        "results_4pol/*.jsonl",
        "results_4pol*/shards/*/*/rows.jsonl",
        "results_oracle*/shards/*/*/rows.jsonl",
    ]

    mks, ens, per_closed = [], [], []
    n_total = n_complete = n_gen_filtered = 0
    scanned_gens, sample_gens = {}, {}   # 세대 -> 행 수 (스캔 전체 / 실제로 측정에 쓴 표본)
    for row, path in _rows(patterns):
        n_total += 1
        g = _generation(row)
        scanned_gens[g] = scanned_gens.get(g, 0) + 1
        if want_gen is not None and g != want_gen:
            n_gen_filtered += 1
            continue
        if not row.get("complete"):
            continue
        m, e = _makespan(row), _energy(row)
        if m is None or e is None:
            continue
        n_complete += 1
        sample_gens[g] = sample_gens.get(g, 0) + 1
        mks.append(m)
        ens.append(e)
        closed = row.get("closed") or 0
        if closed > 0:
            per_closed.append(e / closed)
    # _rows() sets this attribute once fully drained: one relpath entry per
    # file it opened (glob order), already deduplicated — no per-row rebuild needed.
    files = _rows.files
    breakdown = {"scanned": dict(sorted(scanned_gens.items())),
                 "sample": dict(sorted(sample_gens.items())),
                 "current_objective_hash": objective.objective_hash(),
                 "filter": args.generation, "n_filtered_out": n_gen_filtered}

    if n_complete == 0:
        print(json.dumps({"error": "완주 + makespan + energy 를 모두 가진 행이 하나도 없다",
                          "n_rows_scanned": n_total, "generation_breakdown": breakdown,
                          "files": files[:20]},
                         ensure_ascii=False, indent=2))
        return 1

    # 세대 가드 (spec §7): 서로 다른 목적함수로 만든 행의 중앙값을 하나로 합치면, 그 값이
    # objective.json 의 M_ref/E_ref 가 되면서 혼입이 상수에 각인된다 — 이후 어떤 해시 검사도
    # 그것을 볼 수 없다. 조용히 평균내지 않는다.
    if len(sample_gens) > 1 and not args.allow_mixed:
        print(json.dumps({
            "error": "표본에 목적함수 세대가 %d 개 섞여 있다 — 중앙값을 하나로 합치지 않는다 "
                     "(spec §7). --generation <hash|current|none> 으로 하나를 고르거나, "
                     "의도적으로 섞으려면 --allow-mixed 를 줄 것." % len(sample_gens),
            "generation_breakdown": breakdown, "n_rows_scanned": n_total,
            "files": files[:20]}, ensure_ascii=False, indent=2))
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
    notes.append("표본의 목적함수 세대: %s (현재 해시=%s)"
                 % (", ".join("%s×%d" % (g, n) for g, n in sorted(sample_gens.items())),
                    breakdown["current_objective_hash"]))
    if len(sample_gens) > 1:
        notes.append("⚠️ --allow-mixed 로 **서로 다른 세대를 한 중앙값에 섞었다**. 이 상수를 "
                     "objective.json 에 박으면 혼입이 그대로 각인된다 (spec §7).")
    if E_ref <= 0:
        notes.append("⚠️ E_ref <= 0 — w_E = κ·M_ref/E_ref 를 계산할 수 없다(objective.jl/py 가 "
                     "던진다). 표본에 유한한 양의 에너지가 있는지 확인할 것.")

    report = {
        "generation_breakdown": breakdown,
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
