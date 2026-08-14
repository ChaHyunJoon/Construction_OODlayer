#!/usr/bin/env python3
"""4 정책 x 7 실패 case 비교표 — md + html.

무엇을 새로 계산하는가: **아무것도.** 지표 수학은 `llm_ood_eval.py report` 가 이미 계산해
`artifacts_4pol/<case>.json` 에 넣어 둔 것을 그대로 읽는다. 중복 구현은 문서와 아티팩트가
조용히 갈라지는 원인이라(spec §6) 여기서는 **읽고 배치만** 한다.

한 칸에 무엇이 들어가는가
========================
    위:  완주한 판 수 / 시드 수                (n_complete / n)
    아래: 완주판 평균 build time (sim 초) · 에너지(J/closed)

두 줄을 같이 보여야 하는 이유: 완주율만 보면 "느리지만 끝낸" 정책과 "빠르게 끝낸" 정책이
같아 보이고, build time 만 보면 **완주한 판만 평균**하는 생존자 편향(survivor bias)이 숨는다.
J/closed 는 미완주 판에서도 정의되므로 완주 0/30 인 칸에서도 유일하게 남는 수치다.

정책 열의 성격이 서로 다르다 — 표에 그렇게 적는다
================================================
  · `dp`        : **천장(ceiling)**. 실행 가능한 온라인 정책이 아니다. 오프라인 반사실 표집의
                  산물이라 결정 시점에 표가 있다는 것 자체가 "그 사건을 미리 굴려봤다" 는 뜻이다.
                  게다가 이 표의 DP 는 **상수-팔 정책군** 안의 최선이다(dp_solve.py 머리말).
                  실행 정책이 V 를 넘는 칸이 있으면 "천장" 이라는 이름을 쓰지 않는다(원 설계 §8.7).
  · `canonical` : 손으로 쓴 규칙 lookup. 적응 없음.
  · `surrogate` : 배포 RandomForest.
  · `llm(dspy)` : LLM 레인.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# 스윕 case 키 -> 화면 라벨. 라벨은 사람이 읽는 문장이고 키는 하니스의 이름이다.
CASES = [
    ("battery",       "Battery depletion"),
    ("fault",         "Robot breakdown"),
    ("zone",          "Keep-out zone"),
    ("fault_battery", "Breakdown + battery"),
    ("fault_zone",    "Breakdown + zone"),
    ("battery_zone",  "Battery + zone"),
    ("all",           "All three at once"),
]

# 표 열: (아티팩트의 정책 키, 화면 이름, 부제)
COLUMNS = [
    ("dp",        "DP",        "ceiling · not an online policy"),
    ("canonical", "CANONICAL", "hand-written rule"),
    ("surrogate", "SURROGATE", "random forest"),
    ("dspy",      "LLM",       "DSPy"),
]

DASH = "—"


def load_case(art_dir, case):
    p = os.path.join(art_dir, "%s.json" % case)
    if not os.path.exists(p):
        return None
    return json.load(open(p))


def cell(d, pol):
    """(완주 문자열, 시간·에너지 문자열, 원시값 dict). 결측은 0 이 아니라 이름으로 남긴다."""
    if d is None:
        return (DASH, "case 데이터 없음", {})
    pols = d.get("policies") or {}
    p = pols.get(pol)
    if p is None:
        # "정책 없음" 과 "0/30" 은 전혀 다르다. 섞으면 안 돈 레인이 전멸한 레인으로 보인다.
        return (DASH, "이 레인은 스윕에 없음", {})
    n, nc = p.get("n", 0), p.get("n_complete", 0)
    top = "%d/%d" % (nc, n)

    sec = p.get("sim_seconds_complete")
    # 완주 0 이면 완주판 평균이 정의되지 않는다 -> 0.0 으로 채우지 않는다.
    tsec = ("%.1f s" % sec) if isinstance(sec, (int, float)) else DASH
    epc = p.get("energy_per_closed")
    tj = ("%.0f J" % epc) if isinstance(epc, (int, float)) else DASH
    return (top, "%s · %s" % (tsec, tj),
            {"n": n, "n_complete": nc, "sim_seconds_complete": sec, "energy_per_closed": epc,
             "total_energy_J": p.get("total_energy_J"), "decision_rate": p.get("decision_rate")})


def build_md(art_dir, meta):
    L = []
    L.append("# 네 가지 제어기, 일곱 가지 실패 case")
    L.append("")
    L.append("각 칸 — 위: 30 시드 중 완주한 판 수 · 아래: 완주판 평균 build time(sim 초) · 에너지(J/closed)")
    L.append("")
    head = "| FAILURE CASE | " + " | ".join("**%s**<br><sub>%s</sub>" % (n, s)
                                            for _, n, s in COLUMNS) + " |"
    L.append(head)
    L.append("|---|" + "---|" * len(COLUMNS))

    totals = {k: [0, 0] for k, _, _ in COLUMNS}
    for case, label in CASES:
        d = load_case(art_dir, case)
        cells = []
        for key, _, _ in COLUMNS:
            top, bot, raw = cell(d, key)
            if raw.get("n"):
                totals[key][0] += raw.get("n_complete", 0)
                totals[key][1] += raw.get("n", 0)
            cells.append("**%s**<br><sub>%s</sub>" % (top, bot))
        L.append("| %s | %s |" % (label, " | ".join(cells)))

    L.append("")
    L.append("| 합계 (7 case) | " + " | ".join(
        ("%d/%d" % tuple(totals[k]) if totals[k][1] else DASH) for k, _, _ in COLUMNS) + " |")
    L.append("|---|" + "---|" * len(COLUMNS))
    L.append("")
    L.extend(meta)
    return "\n".join(L) + "\n"


HTML_HEAD = """<title>Four controllers, seven failure cases</title>
<style>
  :root{ --ink:#1a1a1a; --dim:#6b6b6b; --faint:#9a9a9a; --rule:#d8d5cc;
         --accent:#8a7a4a; --band:#f4f2ec; --bg:#ffffff; }
  :root:not([data-theme="light"]){ }
  @media (prefers-color-scheme: dark){
    :root:not([data-theme="light"]){ --ink:#ececec; --dim:#a8a8a8; --faint:#7d7d7d;
      --rule:#3a3a3a; --accent:#c9b579; --band:#1e1e1e; --bg:#141414; }
  }
  :root[data-theme="dark"]{ --ink:#ececec; --dim:#a8a8a8; --faint:#7d7d7d;
      --rule:#3a3a3a; --accent:#c9b579; --band:#1e1e1e; --bg:#141414; }
  body{ background:var(--bg); color:var(--ink); margin:0; padding:32px 28px 48px;
        font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
  .kicker{ font-size:11px; letter-spacing:.34em; text-transform:uppercase; color:var(--faint); }
  h1{ font-size:34px; font-weight:400; margin:.28em 0 .18em; letter-spacing:-.01em; }
  .sub{ color:var(--dim); font-size:13.5px; margin-bottom:26px; }
  .wrap{ overflow-x:auto; }
  table{ border-collapse:collapse; width:100%; min-width:720px; }
  th,td{ text-align:center; padding:13px 10px; vertical-align:middle; }
  th.case,td.case{ text-align:left; padding-left:2px; font-size:15px; }
  thead th{ border-bottom:1.5px solid var(--rule); }
  .colname{ color:var(--accent); font-weight:700; font-size:12.5px; letter-spacing:.1em; }
  .colsub{ display:block; color:var(--faint); font-weight:400; font-size:10.5px;
           letter-spacing:0; margin-top:3px; }
  tbody tr:nth-child(even){ background:var(--band); }
  .top{ font-weight:700; font-size:15px; }
  .bot{ color:var(--dim); font-size:11.5px; margin-top:2px; }
  .ceil .top,.ceil .bot{ color:var(--faint); font-weight:400; }
  .foot{ margin-top:22px; color:var(--accent); font-weight:600; font-size:14px; }
  .note{ margin-top:12px; color:var(--faint); font-size:11.5px; line-height:1.65; max-width:70em; }
  .note b{ color:var(--dim); }
</style>
"""


def build_html(art_dir, meta_html, headline):
    rows = []
    for case, label in CASES:
        d = load_case(art_dir, case)
        tds = []
        for key, _, _ in COLUMNS:
            top, bot, _ = cell(d, key)
            cls = " ceil" if key == "dp" else ""
            tds.append('<td class="%s"><div class="top">%s</div><div class="bot">%s</div></td>'
                       % (cls.strip(), top, bot))
        rows.append('<tr><td class="case">%s</td>%s</tr>' % (label, "".join(tds)))

    ths = "".join('<th><span class="colname">%s</span><span class="colsub">%s</span></th>'
                  % (n, s) for _, n, s in COLUMNS)
    return (HTML_HEAD
            + '<div class="kicker">Current Status</div>'
            + '<h1>Four controllers, seven failure cases</h1>'
            + '<div class="sub">Each cell — top: builds finished out of 30 seeds &nbsp;|&nbsp; '
              'bottom: build time (finished runs, sim s) · energy (J/closed)</div>'
            + '<div class="wrap"><table><thead><tr><th class="case">FAILURE CASE</th>'
            + ths + '</tr></thead><tbody>' + "".join(rows) + '</tbody></table></div>'
            + ('<div class="foot">%s</div>' % headline)
            + ('<div class="note">%s</div>' % meta_html))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", default=os.path.join(HERE, "artifacts_4pol"))
    ap.add_argument("--out-md", default=os.path.join(HERE, "artifacts_4pol", "COMPARE.md"))
    ap.add_argument("--out-html", default=os.path.join(HERE, "artifacts_4pol", "compare.html"))
    ap.add_argument("--dp-note", default="")
    a = ap.parse_args()

    import objective

    # 세대·커버리지 같은 메타는 **파일에서 읽는다.** 문서에 손으로 적으면 갈린다.
    meta = []
    meta.append("> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장**이다 — 실행 가능한 온라인 "
                "정책이 아니고, 이 표의 DP 는 상수-팔 반사실 표집의 최선이다(backward induction "
                "이 아니다: 이 하니스는 J 를 판 단위로 낸다). 자세한 정의와 한계는 "
                "`dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.")
    meta.append("")
    meta.append("> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 "
                "`—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.")

    vpath = os.path.join(HERE, "dp_oracle", "value.json")
    gpath = os.path.join(HERE, "dp_oracle", "grid_spec.json")
    if os.path.exists(vpath) and os.path.exists(gpath):
        v = json.load(open(vpath))
        g = json.load(open(gpath))
        cov = 100.0 * v.get("n_cells", 0) / max(g.get("n_observed_cells", 1), 1)
        meta.append("")
        meta.append("> **DP 격자 커버리지** %d / %d 관측 칸 = %.1f%% · a\\* 미확정(동점) %d칸 · "
                    "전부 채점불가 %d칸 · 단일팔 %d칸."
                    % (v.get("n_cells", 0), g.get("n_observed_cells", 0), cov,
                       v.get("n_tie_unresolved", 0), v.get("n_cells_unscorable", 0),
                       v.get("n_cells_single_arm", 0)))
    if a.dp_note:
        meta.append("")
        meta.append("> " + a.dp_note)

    meta.append("")
    meta.append("> 목적함수 세대: `%s`. 지표는 `llm_ood_eval.py report` 가 계산한 값을 그대로 "
                "읽는다(이 스크립트는 배치만 한다)." % objective.load()["generation"])

    # 헤드라인은 **데이터에서 만든다.** 손으로 적으면 다음 스윕에서 조용히 거짓이 된다.
    tot = {}
    for key, name, _ in COLUMNS:
        c = t = 0
        for case, _ in CASES:
            d = load_case(a.artifacts, case)
            _, _, raw = cell(d, key)
            c += raw.get("n_complete", 0) or 0
            t += raw.get("n", 0) or 0
        tot[key] = (c, t, name)
    runnable = [(k,) + tot[k] for k in ("canonical", "surrogate", "dspy") if tot[k][1]]
    if runnable:
        best = max(runnable, key=lambda r: r[1])
        headline = ("실행 가능한 세 레인의 완주 합계 — " +
                    " · ".join("%s %d/%d" % (r[3], r[1], r[2]) for r in runnable) +
                    "  →  최고 %s" % best[3])
    else:
        headline = "완주 합계를 낼 데이터가 없다."

    os.makedirs(os.path.dirname(a.out_md), exist_ok=True)
    open(a.out_md, "w").write(build_md(a.artifacts, meta))
    open(a.out_html, "w").write(build_html(a.artifacts, "<br>".join(
        m.lstrip("> ") for m in meta if m.strip()), headline))
    print("-> %s" % a.out_md)
    print("-> %s" % a.out_html)
    print(headline)


if __name__ == "__main__":
    main()
