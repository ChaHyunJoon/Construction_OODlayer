#!/usr/bin/env python3
"""게이트 N-G8 — 노출한 문법이 의미상 동치인 다른 표현을 재현하는가.

재현 못 하면 그 문법은 `L_dsl` 보다 좁고, "LLM 이 새 제약을 만든다" 는 주장이
"LLM 이 더 약한 제약을 만든다" 가 된다.

  python3 tools/smdp/gate_ng8.py results/smdp/ng8_roundtrip.json

-------------------------------------------------------------------------------
🔴 이 게이트가 계획서의 초안과 다른 세 가지 (Task C6 · 컨트롤러 지시 2026-08-21)
-------------------------------------------------------------------------------
1. **항진적인 짝은 통과 근거로 안 센다.** 계획서가 지시한
   `ForbidWindow ≡ Disjunction(tF≤lo, t0≥hi)` 는 `_bigm_half!`(compiler.jl:158-174)가
   `compile_constraint!(::ForbidWindow)`(compiler.jl:38-46)와 **구조적으로 같은 행**을 내므로
   갈라지기가 어렵다. 그 짝은 `tautological = true` 로 실려 오고, 여기서는 NOTE 로만 찍는다.
   (다만 그 짝이 **깨지면** FAIL 이다 — 깨졌다는 것은 native 경로가 상한 것이니까.)
   그래서 게이트는 `tautological = false` 이고 `axis_degenerate = false` 인 짝이
   **적어도 하나** 통과할 것을 요구한다. 그게 없으면 초록은 아무 말도 안 한 것이다.

2. **행 개수 일치를 요구하지 않는다.** 계획서 Step 1 은 "같은 제약 개수와 같은 해" 를
   요구하지만, 진짜 왕복 짝은 일부러 **행 수가 다르다**(예: `tF = r` 1행 vs `{≤,≥}` 2행,
   `Xa=0` K행 vs `Σ Xa ≤ 0` 1행). 행 수가 같기를 요구하면 항진적인 짝만 통과한다.
   대신 **0행(hollow admit)** 과 **컴파일러의 자기 보고가 실제 행 수와 어긋나는 것**을 막는다.

3. **음성 대조를 먼저 본다.** 측정 스크립트가 함께 실은 `negative_controls` 가 전부 참이어야
   한다. 그중 `comparison_can_go_red` 는 코드를 안 고치고도 "이 비교가 빨강을 낼 수 있다" 를
   실측한다 — 그게 없으면 초록불은 증거가 아니다.
"""
import json
import sys

RTOL = 1e-6


def _fmt(x):
    return "n/a" if x is None else f"{x:.6f}"


def _check_side(name, side, rec, fails):
    tag = f"{name}.{side}"
    if rec["n_constraints"] == 0:
        fails.append(f"{tag}: 0개 제약 — hollow admit")
    if rec["rows_reported"] != rec["rows_actual"]:
        fails.append(f"{tag}: 컴파일러가 {rec['rows_reported']}행을 냈다고 보고했는데 "
                     f"실제로는 {rec['rows_actual']}행이다")
    if not rec["moved_base"]:
        fails.append(f"{tag}: 기저해를 안 움직였다 — 제약이 아무것도 안 한 것이 "
                     f"'같은 해' 로 통과하려 한다")


def _check_pair(name, pair, fails, notes):
    native, grammar = pair["native"], pair["grammar"]
    kind = ("tautological" if pair["tautological"] else "real")
    if pair.get("axis_degenerate"):
        kind += "/axis-degenerate"
    print(f"{name} [{kind}]: native n={native['n_constraints']} "
          f"obj={_fmt(native['objective'])} ({native['status']}) | "
          f"grammar n={grammar['n_constraints']} obj={_fmt(grammar['objective'])} "
          f"({grammar['status']})")

    before = len(fails)
    _check_side(name, "native", native, fails)
    _check_side(name, "grammar", grammar, fails)

    if native["feasible"] != grammar["feasible"]:
        fails.append(f"{name}: 한쪽만 풀린다 (native feasible={native['feasible']}, "
                     f"grammar feasible={grammar['feasible']})")
    elif not native["feasible"]:
        # 🔴 둘 다 INFEASIBLE 인 것은 "같은 판정" 이지 "같은 해" 가 아니다. 목적값이 없으므로
        #    여기서 더 볼 것이 없다 — 대신 moved_base(위)가 base 는 풀렸음을 보증한다.
        notes.append(f"{name}: 양쪽 다 INFEASIBLE — 판정은 일치하지만 계획을 어떻게 바꾸는지에 "
                     f"대해서는 아무 말도 안 한다")
    else:
        rel = abs(native["objective"] - grammar["objective"]) / max(abs(native["objective"]), 1e-12)
        if rel > RTOL:
            fails.append(f"{name}: 목적값이 다르다 (rel={rel:.2e})")
        elif native["t0_hash"] != grammar["t0_hash"]:
            notes.append(f"{name}: 목적값은 같은데 해가 다르다 — 동점 해다. 목적값 일치로 통과시킨다")

    return len(fails) == before


def main(path):
    d = json.load(open(path))
    fails, notes = [], []

    fx = d["fixture"]
    print("== 픽스처 (비퇴화를 먼저 본다) ==")
    print(f"  probe_step={fx['probe_step']} nv={fx['nv']} base_n_constraints={fx['base_n_constraints']} "
          f"base_objective={fx['base_objective']:.6f} makespan={fx['base_makespan']:.6f}")
    print(f"  Xa: nnz={fx['n_xa_nonzeros']} forced={fx['n_xa_forced']} free={fx['n_xa_free']}  "
          f"closed={fx['n_closed']} active={fx['n_active']}")
    if not fx["base_feasible"]:
        fails.append("fixture: base MILP 가 안 풀린다")
    if fx["nv"] <= 100 or fx["base_n_constraints"] <= 1000:
        fails.append(f"fixture: 판이 납작하다 (nv={fx['nv']}, nc={fx['base_n_constraints']})")
    if fx["base_makespan"] <= 1.0:
        fails.append(f"fixture: makespan={fx['base_makespan']} — 시간 축이 퇴화했다")
    if fx["n_xa_free"] == 0:
        notes.append("fixture: Xa 자유 결정변수가 0개다 — 배정 축(:xa)의 왕복은 이 판에서 "
                     "'판정 일치' 이상을 말할 수 없다 (게이트가 그 짝을 근거로 안 센다)")

    print("\n== 음성 대조 (초록불은 증거가 아니다) ==")
    for name, c in sorted(d["negative_controls"].items()):
        print(f"  {'OK  ' if c['holds'] else 'FAIL'} {name}: expect {c['expect']}")
        if not c["holds"]:
            fails.append(f"negative control {name} 이 성립하지 않는다 — "
                         f"기대: {c['expect']}, 측정: {c['measured']}")

    print("\n== 왕복 짝 ==")
    real_passed = 0
    for name, pair in sorted(d["pairs"].items()):
        ok = _check_pair(name, pair, fails, notes)
        if ok and not pair["tautological"] and not pair.get("axis_degenerate"):
            real_passed += 1

    if real_passed == 0:
        fails.append("항진적이지 않고 축이 퇴화하지도 않은 짝이 **하나도** 통과하지 않았다 — "
                     "이 게이트는 아무것도 증명하지 않는다")

    if notes:
        print("\n== NOTE ==")
        for n in notes:
            print(f"  {n}")
    if fails:
        print("\n== FAIL ==")
        for f in fails:
            print(f"  {f}")

    print(f"\nreal (non-tautological, non-degenerate) pairs passed: {real_passed}")
    print("PASS" if not fails else "FAIL")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
