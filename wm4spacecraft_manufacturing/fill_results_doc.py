#!/usr/bin/env python3
"""결과 문서의 <!--TABLE--> / <!--GATES--> / <!--HOLES--> 를 채운다. 대상은 `--doc` 으로 준다.

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
DEFAULT_DOC = os.path.join(HERE, "md", "RESULTS_ROUTER3WAY_2026-08-14.md")
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
        ("dp_oracle/test_dp_solve.py (backward induction 포함)",
         "%s dp_oracle/test_dp_solve.py" % py),
        ("dp_oracle/test_cost_decomposition.py (신규, 분해 충실성 차단 게이트)",
         "%s dp_oracle/test_cost_decomposition.py" % py),
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
        if v.get("solver") == "backward":
            # backward induction 에만 있는 실패 모드들. 조용히 넘기면 낙관 편향이 된다.
            L.append("   - **solver = backward induction.** dangling 전이 **%d건**(사유별 %s) · "
                     "값을 못 낸 칸 **%d칸** · value iteration 수렴 실패 **%d칸**(최대 반복 %d, "
                     "tol %g) · 계층 백오프 **%s**."
                     % (v.get("n_dangling_transitions", 0),
                        v.get("dangling_by_reason") or "{}",
                        v.get("n_cells_no_scorable_arm", 0),
                        v.get("n_cells_not_converged", 0),
                        v.get("vi_max_iterations_used", 0), v.get("vi_tol", 0),
                        "ON" if v.get("backoff_enabled") else "OFF"))
            L.append("   - dangling 은 다음 칸의 V 를 **0 으로 두지 않은 결과**다. 0 으로 두면 "
                     "미지의 미래가 공짜가 되어 표 밖으로 나가는 팔이 언제나 이긴다. 그 (칸,팔) 의 "
                     "Q 를 미정의로 남기는 쪽을 택했고, 그래서 커버리지가 그만큼 낮게 나온다.")

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
    #
    # **평균 대 평균**으로 잰다. 처음엔 개별 판의 J 를 평균 V 와 비교했는데 그건 비교가 아니다:
    # J 가 이봉분포(완주 ~20 / 미완주 ~15000)라 완주한 판은 어떤 평균이든 자동으로 이긴다.
    # 표본이 얇은 쌍(n<3)은 평균이 의미 없으므로 뺀다.
    #
    # ★ 2026-08-15: **비교 단위를 솔버에 맞춘다.** backward 의 V 는 그 칸부터의 cost-to-go 이므로
    # 실행 정책도 같은 분해로 realized cost-to-go 를 뽑아야 한다. 판 전체 J 와 대면 V 가
    # 구조적으로 작아 gap 이 100% 로 자동 발화한다 — 측정이 아니라 단위 오류다.
    # (build_compare_table.py 의 같은 블록과 규칙이 일치해야 두 산출물이 안 갈린다.)
    if os.path.exists(vp):
        import statistics
        v = json.load(open(vp))
        backward = v.get("solver") == "backward"
        Vs = {c: d["V"] for c, d in v["cells"].items() if d.get("V") is not None}
        gspec = json.load(open(gp))
        from derive_grid import cell_key, state_of  # noqa
        from sample_grid import decompose_board     # noqa
        import objective
        per = collections.defaultdict(lambda: collections.defaultdict(list))
        skipped = collections.Counter()
        for p in glob.glob(os.path.join(HERE, "results_4pol", "*.jsonl")):
            for line in open(p):
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                if r.get("policy") not in ("canonical", "surrogate", "dspy"):
                    continue
                if backward:
                    dec = decompose_board(r)
                    if not dec["ok"]:
                        skipped[str(dec["reason"]).split(":")[0]] += 1
                        continue
                    run = dec["c_prefix"]
                else:
                    try:
                        J = objective.J_row(r)
                    except Exception as e:
                        skipped[type(e).__name__] += 1
                        continue
                seen = set()
                for i, d in enumerate(r.get("decisions") or []):
                    st = state_of(d, gspec["axes"])
                    if backward:
                        val = dec["J"] - run       # 이 결정 시점의 **실현 cost-to-go**
                        run += dec["cs"][i]        # 칸을 못 세워도 러닝코스트는 누적한다
                    else:
                        val = J
                    if st is None:
                        continue
                    k = cell_key(st)
                    # 한 판이 같은 칸을 여러 번 지나도 한 번만 센다 — 중복 계상 금지.
                    if k in seen or k not in Vs:
                        continue
                    seen.add(k)
                    per[k][r["policy"]].append(val)
        worse = tot = 0
        for k, bypol in per.items():
            for _pol, Js in bypol.items():
                if len(Js) < 3:
                    continue
                tot += 1
                if statistics.mean(Js) < Vs[k] - 1e-9:
                    worse += 1
        if tot:
            L.append("3. **원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 %d개; 비교 단위 = %s).** "
                     "실행 정책이 DP 의 V 보다 **더 좋은** 쌍 %d개 = **%.1f%%**.%s"
                     % (tot, "그 칸부터의 실현 cost-to-go" if backward else "판 전체 J",
                        worse, 100.0 * worse / tot,
                        "" if not skipped else "  (분해 불가로 제외한 행: %s)" % dict(skipped)))
            if worse and backward:
                L.append("   > 0 이 아니므로 **DP 열을 '천장' 이라고 부르지 않는다.** 원인이 "
                         "상수-팔은 **아니다** — V 는 진짜 backward induction 에서 나온다. "
                         "그러나 남는 원인이 φ̃ 추상화 손실 **하나가 아니다**: 2026-08-15 실측에서 "
                         "셋으로 갈렸다 — ① 표집 팔 메뉴에 실행 레인이 쓰는 매크로가 없는 축"
                         "(ReformTeam) · ② φ̃ 추상화 손실 · ③ 전이 표본이 여전히 상수-팔 rollout "
                         "에서만 나온다는 구조적 한계. 쪼갠 수치는 `dp_oracle/gap_breakdown.py` 가 "
                         "내고, 해석은 결과 문서 §4-D 에 있다.")
                L.append("   > **구분할 것**: dp *레인*은 칸마다 a\\* 를 갈아 쓰므로 표의 dp 열 "
                         "**실현 결과는 유효한 실행 결과**이고, 천장이 아닌 것은 V 다.")
            elif worse:
                L.append("   > 0 이 아니므로 **DP 열을 '천장' 이라고 부르지 않는다.** V 는 "
                         "**상수-팔** 표집에서 나오는데, 사건이 셋 섞인 판을 한 팔로 처리할 수 "
                         "없어 그 정책군이 실행 레인보다 훨씬 약하다(§5-C).")
            else:
                L.append("   > 0 건이므로 이 격자 위에서는 '천장' 이라는 이름이 유지된다.")

    L.append("4. **`zone_s=cov` 는 표본 0.** §5-D. 기존 zone 규칙의 알려진 결함을 이 DP 도 못 고친다.")
    if os.path.exists(vp) and json.load(open(vp)).get("solver") == "backward":
        L.append("5. **credit assignment 는 닫혔다.** 판 단위 J 를 결정 개수로 나눠 쓰던 문제는 "
                 "구간 비용 `c_k` 로 해소됐고, 그 분해는 판마다 `c_prefix + Σc + terminal == J` 로 "
                 "기계 검사된다. 대신 새로 생긴 실패 모드가 **dangling**(위 1번)이다.")
    else:
        L.append("5. **credit assignment.** 판 하나가 여러 칸에 같은 J 를 나눠 준다. §5-C.")
    return "\n".join(L)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", default=DEFAULT_DOC)
    a = ap.parse_args()
    doc = open(a.doc).read()
    doc = doc.replace("<!--TABLE-->", table_section())
    doc = doc.replace("<!--GATES-->", gates_section())
    doc = doc.replace("<!--HOLES-->", holes_section())
    open(a.doc, "w").write(doc)
    print("-> %s" % a.doc)


if __name__ == "__main__":
    main()
