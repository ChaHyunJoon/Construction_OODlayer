#!/usr/bin/env python3
"""에너지 항이 실제로 결정을 바꾸는가 (spec §9 '무력 검사').

각 (instance) 별로 후보 팔들의 J 를 두 번 계산한다:
  - 에너지 포함 (w_E = kappa·M_ref/E_ref)
  - 에너지 제외 (w_E = 0)
argmin 이 갈리는 instance 수를 센다. **0 이면 0 이라고 보고한다** —
"energy 도 최소화한다"가 명목상 주장으로 남는 상황을 숨기지 않는다.

**단, 에너지 항이 J 에 들어오는 건 완주(complete=True) 분기뿐이다** — 어떤 instance 의
모든 arm 이 미완주면 그 instance 는 kappa 값과 무관하게 with-energy/no-energy J 가 같은
함수가 되고, argmin 은 절대 안 갈린다. 이런 instance 를 "평가됨"에는 넣되 "flip_rate" 의
분모에서는 뺀다 — 안 그러면 "에너지가 결정을 안 바꿨다"가 "에너지가 애초에 관여하지 않은
사례들을 셌다"는 사실을 감추고 κ 에 대한 근거 없는 결론(허위 음성)을 만든다. 이건 spec §4.2
가 막으려는 것의 반대 방향 오류다 — 진짜 0 을 숨기는 게 아니라 가짜 0 을 만들어낸다.

구세대 덤프(objective.json 의 generation 이 바뀌기 전에 만들어진 런)에는 energy_J 가
없으므로 완주 행마다 objective.J_row 가 ObjectiveError 를 던진다(spec §5, §7 — 조용한
폴백 금지). 그 에러는 두 가지 서로 다른 이유를 가릴 수 있어 따로 센다:
  - schema_drift: 행에 complete/closed/total 자체가 없다 (스키마가 다르다)
  - missing_energy: complete/closed/total 은 있는데 energy_J(또는
    battery.total_energy_J)가 없거나(구세대) makespan/energy 가 유한하지 않다

행에 `objective_hash` 필드가 있으면(§7-2 계약) 덤프 자체가 어느 세대에서 나왔는지 읽어서
현재 objective.json 의 해시와 비교한다 — 안 그러면 이 리포터가 **자기 자신의** 현재 해시를
찍어 "이 분석이 현재 세대 기준"이라는 착각을 주는데, 정작 분석 대상 덤프는 다른(더 오래된)
세대일 수 있다.

    .venv/bin/python report_energy_decisiveness.py <dump.jsonl> [--key instance]
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
    ap.add_argument("--key", default="instance", help="instance 를 식별하는 필드명 "
                     "(레포의 모든 oracle/out/*.jsonl 은 'instance' 를 쓴다)")
    ap.add_argument("--arm", default="macro", help="팔(후보)을 식별하는 필드명")
    args = ap.parse_args()

    cfg = objective.load()
    cfg_noE = dict(cfg)
    cfg_noE["kappa"] = 0.0   # 에너지 항만 끈다
    current_hash = objective.objective_hash(cfg)

    groups = collections.defaultdict(list)
    skipped = 0
    dump_hash = None
    with open(args.dump) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if dump_hash is None and "objective_hash" in r:
                dump_hash = r["objective_hash"]
            if args.key not in r or args.arm not in r:
                skipped += 1
                continue
            groups[r[args.key]].append(r)

    flipped, evaluated, evaluated_in_play = 0, 0, 0
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
        in_play = any(bool(r.get("complete")) for r in rows)
        if in_play:
            evaluated_in_play += 1
        if with_e[args.arm] != no_e[args.arm]:
            flipped += 1
            len(examples) < 10 and examples.append(
                {"instance": inst, "with_energy": with_e[args.arm], "without": no_e[args.arm]})

    errors_total = errors_schema_drift + errors_missing_energy

    # 세대 판정 (spec §7-2): 이 분석의 현재 해시가 아니라 *덤프 자체가 담고 있는* 해시를 본다.
    if dump_hash is None:
        gen_match = False
        gen_note = ("이 덤프는 행에 objective_hash 필드가 없다 — objective_hash 가 배선되기 전의 "
                     "구세대 덤프로 간주해야 한다(spec §7). 아래 flip_rate/verdict 를 '현재 세대의 "
                     "에너지 결정력'으로 인용하지 말 것.")
    elif dump_hash == current_hash:
        gen_match = True
        gen_note = None
    else:
        gen_match = False
        gen_note = ("이 덤프의 objective_hash(%s) 가 현재 objective.json 의 해시(%s) 와 다르다 — "
                     "다른 세대다(spec §7). 아래 수치를 현재 세대 근거로 인용하지 말 것."
                     % (dump_hash, current_hash))

    if evaluated == 0 and skipped > 0:
        verdict = ("평가 가능한 instance 가 0 개이고 %d 행이 전부 skip 됐다 — 원인은 구세대/스키마가 "
                    "아니라 `--key`(='%s')/`--arm`(='%s') 이 이 덤프의 실제 필드명과 안 맞는 것이다. "
                    "덤프의 첫 행 키를 확인하고 다시 지정할 것." % (skipped, args.key, args.arm))
    elif evaluated == 0:
        verdict = ("평가 가능한 instance 가 없다 — 이 덤프는 구세대다(energy_J 없음) 또는 "
                    "스키마가 다르다. instances_error_schema_drift/instances_error_missing_energy "
                    "를 볼 것.")
    elif evaluated_in_play == 0:
        verdict = ("에너지 결정력은 아직 측정되지 않았다 — 평가된 %d개 그룹이 전부 미완주라 "
                    "J 의 에너지 항이 애초에 관여하지 않는다(완주 분기에만 들어간다, spec §3.1). "
                    "flip_rate 는 null 이다 — '0 flip' 이 아니라 '측정 안 됨'." % evaluated)
    elif flipped == 0:
        verdict = ("에너지가 a* 를 한 번도 바꾸지 않았다(에너지가 실제로 관여한 %d개 그룹 중 0개) "
                    "— κ 가 노이즈에 묻혀 있다 (spec §4.2, §11-1). 'energy 도 최소화한다'는 현재 "
                    "명목상 주장이다." % evaluated_in_play)
    else:
        verdict = ("에너지가 %d/%d instance(에너지가 실제로 관여한 그룹 기준)에서 a* 를 바꿨다."
                    % (flipped, evaluated_in_play))

    if gen_note:
        verdict = "⚠️ " + gen_note + " | " + verdict

    print(json.dumps({
        "objective_hash": current_hash,
        "dump_objective_hash": dump_hash,
        "dump_generation_matches_current": gen_match,
        "kappa": cfg["kappa"],
        "instances_evaluated": evaluated,
        "instances_evaluated_with_energy_in_play": evaluated_in_play,
        "instances_where_energy_flipped_argmin": flipped,
        "flip_rate": (flipped / evaluated_in_play) if evaluated_in_play else None,
        "instances_skipped_missing_fields": skipped,
        "instances_error_total": errors_total,
        "instances_error_schema_drift": errors_schema_drift,
        "instances_error_missing_energy": errors_missing_energy,
        "examples": examples,
        "verdict": verdict,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
