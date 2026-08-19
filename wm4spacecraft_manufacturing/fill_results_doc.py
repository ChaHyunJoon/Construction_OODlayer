#!/usr/bin/env python3
"""결과 문서의 <!--TABLE--> / <!--GATES--> / <!--HOLES--> 를 채운다. 대상은 `--doc` 으로 준다.

왜 스크립트인가: 결과 문서의 숫자를 손으로 옮겨 적으면 다음 스윕에서 조용히 거짓이 된다.
이 저장소가 이미 그 사고를 겪었다(`limitations_lines` 독스트링). 그 회귀를 감시하던
`test_report_sample_size.py` 는 2026-08-18 정리에서 삭제됐다 — 지금은 사람이 봐야 한다.
그래서 문서의 수치 부분은 **전부 산출물에서 생성**한다.

`objective_hash` 문자열은 절대 쓰지 않는다 (Global Constraint 4).
"""
import collections
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# dp_oracle 는 패키지가 아니다(__init__.py 없음). 경로로 붙여 모듈로 직접 import 한다.
sys.path.insert(0, os.path.join(HERE, "dp_oracle"))
# 이 기본 대상 문서는 2026-08-18 md 통합에서 내려갔다(복구 SHA 는 `md/README.md` §9-A).
# 즉 `--doc` 없이 돌리면 열 파일이 없어 죽는다 — 채울 문서를 명시적으로 줄 것.
DEFAULT_DOC = os.path.join(HERE, "md", "RESULTS_ROUTER3WAY_2026-08-14.md")
ART = os.path.join(HERE, "artifacts_4pol")
DPD = os.path.join(HERE, "dp_oracle")


def table_section():
    p = os.path.join(ART, "COMPARE.md")
    if not os.path.exists(p):
        return "_(COMPARE.md 없음 — `bash finish_tables.sh` 를 먼저 돌린다)_"
    body = open(p).read()
    # 제목 줄은 이 문서가 이미 갖고 있으므로 뺀다.
    return "\n".join(l for l in body.splitlines() if not l.startswith("# "))


def holes_section():
    L = []

    # 항목 번호는 **자동으로 매긴다.** 아래 블록들이 `dp_lane_swept` 로 조건부가 되면서 리터럴
    # "1." "3." "5." 를 그대로 두면 dp 없는 스윕에서 번호가 건너뛴다.
    _n = [0]

    def item(s):
        _n[0] += 1
        L.append("%d. %s" % (_n[0], s))

    # ★ 2026-08-16 — **`build_compare_table.py:197` 에 있는 `dp_lane_swept` 가드의 형제다.
    #   이 둘은 반드시 같이 움직여야 한다.**
    #
    # 배경: 커밋 `1bfbcaf8`·`7eddb629` 가 `build_compare_table.py` 에서 세대 누수 셋을 이 신호로
    # 닫았는데, **이 파일은 그때 같이 안 고쳐졌다.** 그래서 형제 소비처 둘의 규칙이 어긋난
    # 상태로 남아 있었다(이 파일 머리말과 `.claude/CLAUDE.md` 는 둘이 일치한다고 적고 있었으므로,
    # 문서화된 불변식이 거짓이 된 상태였다). 이번 배송 세대에서 발행된 문서는 이 스크립트를
    # 타지 않았지만(현행 결과 문서에 `<!--TABLE/GATES/HOLES-->` 마커가 없다), 다음 스윕에서
    # 누가 `--doc` 으로 이걸 돌리면 그대로 샌다.
    #
    # 무엇이 새는가: 아래 세 블록이 **구세대 `dp_oracle/value.json`** 을 이번 세대 산출물의
    # 참·거짓 판정에 쓴다 — ① DP 격자 커버리지, ② §8.7 gap(현재 `results_4pol/*.jsonl` 을
    # 옛 `V` 에 대고 다시 계산 — `1bfbcaf8` 이 막은 것과 **정확히 같은** 누수),
    # ③ "backward induction · 분해가 기계 검사된다" 주장 블록(`7eddb629` 가 없앤 것과 같은 종류).
    #
    # 🔴 **해시로는 못 잡는다.** 이 `value.json` 의 `objective_hash` 는 **현행과 같다** —
    # 목적함수는 안 갈렸고 갈린 것은 **코드 세대**(SwapBattery 가 물리 배터리 배송이 된 것)이기
    # 때문이다. 그래서 세대 판정을 해시에 맡길 수 없고, 쓸 수 있는 신호는 `shards_dp` 뿐이다.
    #
    # 삭제가 아니라 **조건문**이다 — dp 샤드가 돌아오면 세 블록은 축자 그대로 되살아난다.
    # 되살리기 전에 `value.json` 이 그 시점 `results_4pol` 과 같은 코드 세대인지 먼저 확인할 것
    # (파일이 있다고 세대가 맞는다는 뜻이 아니다).
    dp_lane_swept = os.path.isdir(os.path.join(HERE, "results_4pol", "shards_dp"))

    # (1) DP 커버리지 -- 칸 기준과 **결정 기준**을 둘 다 낸다.
    #     칸 커버리지만 적으면 낮아 보이는데, 결정 빈도가 편중돼 있어서 실제로 조회에 성공하는
    #     비율은 다르다. 둘 중 하나만 적는 것이 오독을 만든다.
    gp, vp = os.path.join(DPD, "grid_spec.json"), os.path.join(DPD, "value.json")
    if not dp_lane_swept:
        item("**`dp` 레인이 이번 스윕에 없다**(`results_4pol/shards_dp` 없음). 그래서 이 절은 "
             "DP 격자 커버리지 · §8.7 gap · 비용 분해 충실성에 대해 **아무것도 주장하지 않는다** "
             "— `dp_oracle/value.json` 이 이 스윕과 다른 코드 세대에 표집된 채 남아 있을 수 "
             "있기 때문이다. DP 의 정의와 한계는 `dp_oracle/dp_solve.py` 머리말과 "
             "`dp_oracle/value.json` 의 `known_limits` 에 있다.")
    if dp_lane_swept and os.path.exists(gp) and os.path.exists(vp):
        g, v = json.load(open(gp)), json.load(open(vp))
        oc = g["observed_cells"]
        have = set(v["cells"])
        n_dec_tot = sum(oc.values())
        n_dec_cov = sum(n for k, n in oc.items() if k in have)
        item("**DP 격자 커버리지.** 표에 오른 칸 %d / 관측 칸 %d = **%.1f%%**. "
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
        item("**dp 레인이 표를 실제로 쓴 비율.** 결정 %d건 중:" % n_dp_dec)
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
    # (build_compare_table.py 의 같은 블록과 규칙이 일치해야 두 산출물이 안 갈린다 — 그 "규칙"
    #  에는 단위 선택뿐 아니라 위의 `dp_lane_swept` 가드도 포함된다. 2026-08-16 부터 둘이 같다.)
    #
    # ★ 2026-08-16 — dp 레인이 이번 스윕에 없으면 이 블록 **전체**를 건너뛴다. 아래 계산은
    # **현재** `results_4pol/*.jsonl`(이번 세대의 canonical/surrogate/dspy 행)을 구세대일 수 있는
    # `value.json` 의 V 와 무조건 대면시킨다. dp 칸은 이미 올바르게 비는데 각주만 세대가 섞인
    # 숫자를 발행하는 형태라, 표를 훑는 것만으로는 안 잡힌다. `build_compare_table.py:282` 와 같다.
    if dp_lane_swept and os.path.exists(vp):
        import statistics
        v = json.load(open(vp))
        backward = v.get("solver") == "backward"
        Vs = {c: d["V"] for c, d in v["cells"].items() if d.get("V") is not None}
        gspec = json.load(open(gp))
        from derive_grid import cell_key, state_of  # noqa
        from sample_grid import decompose_board     # noqa
        # 원인 문장은 표본에서 유도한다(2026-08-17 최종 리뷰 Critical 3) — 아래 참조.
        from sample_grid import gap_cause_note, samples_sampling_mode   # noqa
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
            item("**원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 %d개; 비교 단위 = %s).** "
                 "실행 정책이 DP 의 V 보다 **더 좋은** 쌍 %d개 = **%.1f%%**.%s"
                     % (tot, "그 칸부터의 실현 cost-to-go" if backward else "판 전체 J",
                        worse, 100.0 * worse / tot,
                        "" if not skipped else "  (분해 불가로 제외한 행: %s)" % dict(skipped)))
            if worse and backward:
                # ★ 2026-08-17 최종 리뷰 Critical 3 — 원인 목록을 **하드코딩하지 않는다.**
                # 예전에는 여기 세 원인이 리터럴로 박혀 있었는데, ① 은 2026-08-16 에 닫혔고
                # ③ 은 이 브랜치의 1-step deviation 표집이 없앴다. 그래서 발행된 문서가 자기가
                # 이미 제거한 전제를 계속 주장했다. 이제 표본의 `sampling_mode` 에서 유도한다.
                mode = samples_sampling_mode(os.path.join(DPD, "samples.jsonl"))
                L.append("   > 0 이 아니므로 **DP 열을 '천장' 이라고 부르지 않는다.** 원인이 "
                         "상수-팔은 **아니다** — V 는 진짜 backward induction 에서 나온다. "
                         "표집 모드 `%s` 기준으로 %s" % (mode, gap_cause_note(mode)))
                L.append("   > **구분할 것**: dp *레인*은 칸마다 a\\* 를 갈아 쓰므로 표의 dp 열 "
                         "**실현 결과는 유효한 실행 결과**이고, 천장이 아닌 것은 V 다.")
            elif worse:
                L.append("   > 0 이 아니므로 **DP 열을 '천장' 이라고 부르지 않는다.** V 는 "
                         "**상수-팔** 표집에서 나오는데, 사건이 셋 섞인 판을 한 팔로 처리할 수 "
                         "없어 그 정책군이 실행 레인보다 훨씬 약하다(§5-C).")
            else:
                L.append("   > 0 건이므로 이 격자 위에서는 '천장' 이라는 이름이 유지된다.")

    item("**`zone_s=cov` 는 표본 0.** §5-D. 기존 zone 규칙의 알려진 결함을 이 DP 도 못 고친다.")
    # ★ 2026-08-16 — 이 "분해 충실성" 주장도 `dp_lane_swept` 로 묶는다. `7eddb629` 가
    # build_compare_table.py 에서 없앤 것과 **같은 종류**의 주장이다: 숫자가 없어서 수치 그렙에
    # 안 걸리지만, `Σc + terminal == J` 로 기계 검사된 판이 이 표에 하나도 없을 때 그냥 거짓이다.
    if dp_lane_swept and os.path.exists(vp) and json.load(open(vp)).get("solver") == "backward":
        item("**credit assignment 는 닫혔다.** 판 단위 J 를 결정 개수로 나눠 쓰던 문제는 "
             "구간 비용 `c_k` 로 해소됐고, 그 분해는 판마다 `c_prefix + Σc + terminal == J` 로 "
             "기계 검사된다. 대신 새로 생긴 실패 모드가 **dangling**(위 DP 격자 커버리지 항목)이다.")
    elif dp_lane_swept:
        item("**credit assignment.** 판 하나가 여러 칸에 같은 J 를 나눠 준다. §5-C.")
    else:
        item("**credit assignment 는 이 스윕에서 판정하지 않는다.** dp 레인이 없으므로 비용 분해가 "
             "기계 검사됐는지에 대해 이 문서는 주장하지 않는다(위 1번).")
    return "\n".join(L)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--doc", default=DEFAULT_DOC)
    a = ap.parse_args()
    doc = open(a.doc).read()
    doc = doc.replace("<!--TABLE-->", table_section())
    # 게이트 표를 만들던 검사기 7개가 2026-08-18 정리에서 삭제됐다(`git show 8e005842:…`).
    doc = doc.replace(
        "<!--GATES-->",
        "_이 세대에는 게이트 표가 없다 — 표를 채우던 감사·테스트가 2026-08-18 정리에서 "
        "삭제됐다(`git show 8e005842:wm4spacecraft_manufacturing/<path>`)._",
    )
    doc = doc.replace("<!--HOLES-->", holes_section())
    open(a.doc, "w").write(doc)
    print("-> %s" % a.doc)


if __name__ == "__main__":
    main()
