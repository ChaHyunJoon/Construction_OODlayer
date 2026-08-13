#!/usr/bin/env python3
"""에너지 항이 실제로 결정을 바꾸는가 (spec §9 '무력 검사').

각 (instance) 별로 후보 팔들의 J 를 두 번 계산한다:
  - 에너지 포함 (w_E = kappa·M_ref/E_ref)
  - 에너지 제외 (w_E = 0)
argmin 이 갈리는 instance 수를 센다. **0 이면 0 이라고 보고한다** —
"energy 도 최소화한다"가 명목상 주장으로 남는 상황을 숨기지 않는다.

구세대 덤프(objective.json 의 generation 이 바뀌기 전에 만들어진 런)에는 energy_J 가
없으므로 완주 행마다 objective.J_row 가 ObjectiveError 를 던진다(spec §5, §7 — 조용한
폴백 금지). 그 에러는 두 가지 서로 다른 이유를 가릴 수 있어 따로 센다:
  - schema_drift: 행에 complete/closed/total 자체가 없다 (스키마가 다르다)
  - missing_energy: complete/closed/total 은 있는데 energy_J(또는
    battery.total_energy_J)가 없거나(구세대) makespan/energy 가 유한하지 않다

    .venv/bin/python report_energy_decisiveness.py <dump.jsonl> [--key instance_id]
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objective  # noqa: E402

_SCHEMA_KEYS = ("complete", "closed", "total")


def _classify_error(rows):
    """왜 이 instance 의 그룹이 ObjectiveError 로 죽었는지 분류한다.

    J_row 는 스키마 드리프트(complete/closed/total 없음)와 에너지 결측(완주 런인데
    energy_J 없음)을 구분 없이 같은 예외 타입으로 던진다. 리포터는 두 원인을 섞으면
    "구세대라 에너지가 없다"는 정상적인 상황과 "덤프 자체가 이 스키마가 아니다"는
    진짜 버그를 구분 못 하게 되므로, 행 내용을 직접 검사해 분류한다."""
    for r in rows:
        if any(k not in r for k in _SCHEMA_KEYS):
            return "schema_drift"
    return "missing_energy"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", help="instance × macro 행이 담긴 JSONL")
    ap.add_argument("--key", default="instance_id", help="instance 를 식별하는 필드명")
    ap.add_argument("--arm", default="macro", help="팔(후보)을 식별하는 필드명")
    args = ap.parse_args()

    cfg = objective.load()
    cfg_noE = dict(cfg)
    cfg_noE["kappa"] = 0.0   # 에너지 항만 끈다

    groups = collections.defaultdict(list)
    skipped = 0
    with open(args.dump) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if args.key not in r or args.arm not in r:
                skipped += 1
                continue
            groups[r[args.key]].append(r)

    flipped, evaluated = 0, 0
    errors_schema_drift, errors_missing_energy = 0, 0
    examples = []
    for inst, rows in groups.items():
        try:
            with_e = min(rows, key=lambda r: objective.J_row(r, cfg=cfg))
            no_e = min(rows, key=lambda r: objective.J_row(r, cfg=cfg_noE))
        except objective.ObjectiveError:
            kind = _classify_error(rows)
            if kind == "schema_drift":
                errors_schema_drift += 1
            else:
                errors_missing_energy += 1
            continue
        evaluated += 1
        if with_e[args.arm] != no_e[args.arm]:
            flipped += 1
            len(examples) < 10 and examples.append(
                {"instance": inst, "with_energy": with_e[args.arm], "without": no_e[args.arm]})

    errors = errors_schema_drift + errors_missing_energy

    print(json.dumps({
        "objective_hash": objective.objective_hash(cfg),
        "kappa": cfg["kappa"],
        "instances_evaluated": evaluated,
        "instances_where_energy_flipped_argmin": flipped,
        "flip_rate": (flipped / evaluated) if evaluated else None,
        "instances_skipped_missing_fields": skipped,
        "instances_error_missing_energy": errors,
        "instances_error_schema_drift": errors_schema_drift,
        "instances_error_energy_only": errors_missing_energy,
        "examples": examples,
        "verdict": ("에너지가 a* 를 한 번도 바꾸지 않았다 — κ 가 노이즈에 묻혀 있다 (spec §4.2, §11-1). "
                    "'energy 도 최소화한다'는 현재 명목상 주장이다."
                    if evaluated and flipped == 0 else
                    "에너지가 %d/%d instance 에서 a* 를 바꿨다." % (flipped, evaluated)
                    if evaluated else
                    "평가 가능한 instance 가 없다 — 이 덤프는 구세대다(energy_J 없음) 또는 "
                    "스키마가 다르다. instances_error_schema_drift/instances_error_energy_only "
                    "를 볼 것."),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
