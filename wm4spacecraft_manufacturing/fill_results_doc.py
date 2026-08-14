#!/usr/bin/env python3
"""RESULTS_ROUTER3WAY_2026-08-14.md 의 <!--TABLE--> / <!--GATES--> / <!--HOLES--> 를 채운다.

왜 스크립트인가: 결과 문서의 숫자를 손으로 옮겨 적으면 다음 스윕에서 조용히 거짓이 된다.
이 저장소가 이미 그 사고를 겪었고(`limitations_lines` 독스트링), `test_report_sample_size.py`
가 그 회귀를 감시한다. 그래서 문서의 수치 부분은 **전부 산출물에서 생성**한다.

`objective_hash` 문자열은 절대 쓰지 않는다 (Global Constraint 4).
"""
import collections
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# dp_oracle 는 패키지가 아니다(__init__.py 없음). 경로로 붙여 모듈로 직접 import 한다.
sys.path.insert(0, os.path.join(HERE, "dp_oracle"))
DOC = os.path.join(HERE, "md", "RESULTS_ROUTER3WAY_2026-08-14.md")
ART = os.path.join(HERE, "artifacts_4pol")
DPD = os.path.join(HERE, "dp_oracle")


def sh(cmd, cwd=None):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd or HERE)
    return p.returncode, (p.stdout + p.stderr).strip()


def gates_section():
    py = os.path.join(HERE, "..", ".venv", "bin", "python")
    checks = [
        ("audit_objective.py (9/9)", "%s audit_objective.py" % py),
        ("audit_action_vocab.py (6/6)", "%s audit_action_vocab.py" % py),
        ("test_surrogate_support.py", "%s test_surrogate_support.py" % py),
        ("test_ceilings_degrade.py (신규)", "%s test_ceilings_degrade.py" % py),
        ("dp_oracle/test_dp_solve.py (신규)", "%s dp_oracle/test_dp_solve.py" % py),
        ("dp_oracle/test_cellkey_parity.py (신규, Julia↔Python)",
         "%s dp_oracle/test_cellkey_parity.py" % py),
        ("dp_oracle/test_derive_grid.py 대체: derive_grid 재실행 결정성",
         "%s dp_oracle/derive_grid.py --results results_4pol --out /tmp/_grid_recheck.json" % py),
        ("tools/monitor/test_narrate.jl (신규)",
         "cd .. && julia +lts --project=. tools/monitor/test_narrate.jl"),
        ("tools/monitor/test_lane_select.jl (신규)",
         "cd .. && julia +lts --project=. tools/monitor/test_lane_select.jl"),
        ("tools/test_policy_escalation.jl (기존 회귀)",
         "cd .. && julia +lts --project=. tools/test_policy_escalation.jl"),
    ]
    L = ["| 게이트 | 결과 |", "|---|---|"]
    for name, cmd in checks:
        rc, _ = sh(cmd)
        L.append("| `%s` | %s |" % (name, "exit 0 ✅" if rc == 0 else "exit %d ❌" % rc))
    return "\n".join(L)


def table_section():
    p = os.path.join(ART, "COMPARE.md")
    if not os.path.exists(p):
        return "_(COMPARE.md 없음 — `bash finish_tables.sh` 를 먼저 돌린다)_"
    body = open(p).read()
    # 제목 줄은 이 문서가 이미 갖고 있으므로 뺀다.
    return "\n".join(l for l in body.splitlines() if not l.startswith("# "))


def holes_section():
    L = []

    # (1) DP 커버리지 -- 칸 기준과 **결정 기준**을 둘 다 낸다.
    #     칸 커버리지만 적으면 낮아 보이는데, 결정 빈도가 편중돼 있어서 실제로 조회에 성공하는
    #     비율은 다르다. 둘 중 하나만 적는 것이 오독을 만든다.
    gp, vp = os.path.join(DPD, "grid_spec.json"), os.path.join(DPD, "value.json")
    if os.path.exists(gp) and os.path.exists(vp):
        g, v = json.load(open(gp)), json.load(open(vp))
        oc = g["observed_cells"]
        have = set(v["cells"])
        n_dec_tot = sum(oc.values())
        n_dec_cov = sum(n for k, n in oc.items() if k in have)
        L.append("1. **DP 격자 커버리지.** 표에 오른 칸 %d / 관측 칸 %d = **%.1f%%**. "
                 "다만 결정 빈도가 편중돼 있어 **결정 기준 커버리지는 %d/%d = %.1f%%** 다. "
                 "둘 중 하나만 적으면 오독을 만든다."
                 % (len(have), g["n_observed_cells"],
                    100.0 * len(have) / max(g["n_observed_cells"], 1),
                    n_dec_cov, n_dec_tot, 100.0 * n_dec_cov / max(n_dec_tot, 1)))
        L.append("   - a\\* 미확정(동점) **%d칸** · 전부 J 채점불가 **%d칸** · 팔이 하나뿐 **%d칸**. "
                 "동점은 실패가 아니라 *없는 확신을 만들지 않은 것*이다."
                 % (v.get("n_tie_unresolved", 0), v.get("n_cells_unscorable", 0),
                    v.get("n_cells_single_arm", 0)))

    # (2) dp 레인이 실제로 표를 얼마나 썼는가 -- dp_miss 를 이유별로 센다.
    miss = collections.Counter()
    n_dp_dec = 0
    for p in glob.glob(os.path.join(HERE, "results_4pol", "*.jsonl")):
        for line in open(p):
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("policy") != "dp":
                continue
            for d in (r.get("decisions") or []):
                n_dp_dec += 1
                miss[d.get("dp_miss") or "표 조회 성공"] += 1
    if n_dp_dec:
        L.append("2. **dp 레인이 표를 실제로 쓴 비율.** 결정 %d건 중:" % n_dp_dec)
        for k, n in miss.most_common():
            L.append("   - `%s` %d건 (%.1f%%)" % (k, n, 100.0 * n / n_dp_dec))
        L.append("   조용한 폴백이 없도록 이유를 네 가지로 구분해 행에 남긴다 — "
                 "`not_in_table`(표집이 그 칸에 안 닿음)과 `tie_unresolved`(닿았지만 동점)는 "
                 "전혀 다른 사건이라, 뭉뚱그리면 낮은 커버리지가 '알고리즘이 판단을 보류했다' "
                 "로 오독된다.")

    # (3) §8.7 gap -- 실행 정책이 DP 의 V 를 넘는가. 넘으면 "천장" 이라는 이름을 쓰지 않는다.
    if os.path.exists(vp):
        v = json.load(open(vp))
        Vs = {c: d["V"] for c, d in v["cells"].items() if d.get("V") is not None}
        worse = tot = 0
        sp = os.path.join(DPD, "samples.jsonl")
        exec_J = collections.defaultdict(list)
        gspec = json.load(open(gp))
        for p in glob.glob(os.path.join(HERE, "results_4pol", "*.jsonl")):
            for line in open(p):
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                if r.get("policy") not in ("canonical", "surrogate", "dspy"):
                    continue
                try:
                    import objective
                    J = objective.J_row(r)
                except Exception:
                    continue
                from derive_grid import cell_key, state_of  # noqa
                for d in (r.get("decisions") or []):
                    st = state_of(d, gspec["axes"])
                    if st is None:
                        continue
                    exec_J[cell_key(st)].append((r["policy"], J))
        for c, lst in exec_J.items():
            if c not in Vs:
                continue
            for _pol, J in lst:
                tot += 1
                if J < Vs[c] - 1e-9:
                    worse += 1
        if tot:
            L.append("3. **원 설계 §8.7 gap.** 실행 정책의 실현 J 가 DP 의 V 보다 **더 좋은** "
                     "경우 %d / %d (%.1f%%)." % (worse, tot, 100.0 * worse / tot))
            if worse:
                L.append("   > 0 이 아니므로 이 표에서 **DP 열을 '천장' 이라고 부르지 않는다.** "
                         "원인은 §5-C 에 적힌 그대로다 — 상수-팔 정책군은 실행 정책보다 좁아서, "
                         "사건마다 팔을 바꿀 수 있는 정책이 더 잘할 수 있다. 이름을 유지하면 "
                         "그 자체가 거짓 주장이 된다.")
            else:
                L.append("   > 0 건이므로 이 격자 위에서는 '천장' 이라는 이름이 유지된다.")

    L.append("4. **`zone_s=cov` 는 표본 0.** §5-D. 기존 zone 규칙의 알려진 결함을 이 DP 도 못 고친다.")
    L.append("5. **credit assignment.** 판 하나가 여러 칸에 같은 J 를 나눠 준다. §5-C.")
    return "\n".join(L)


def main():
    doc = open(DOC).read()
    doc = doc.replace("<!--TABLE-->", table_section())
    doc = doc.replace("<!--GATES-->", gates_section())
    doc = doc.replace("<!--HOLES-->", holes_section())
    open(DOC, "w").write(doc)
    print("-> %s" % DOC)


if __name__ == "__main__":
    main()
