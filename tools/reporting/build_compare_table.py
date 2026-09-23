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
  · `dp`        : 오프라인 value-table 을 결정마다 조회해 a* 를 집행하는 레인. **천장이 아니다.**
                  원 설계 §8.7 은 "실행 정책이 V 를 넘으면 천장이라 부르지 않는다" 고 못박았고,
                  2026-08-14 실측에서 그 조건이 **실제로 발화했다**(아래 주석의 gap 수치).
                  이유는 dp_solve.py 머리말에 적힌 그대로다 — V 는 **상수-팔** 표집에서 나오는데,
                  사건이 셋 섞인 판을 한 팔로 처리할 수는 없어서 그 정책군이 실행 레인보다 훨씬
                  약하다. 다만 dp **레인**은 칸마다 a* 를 갈아 쓰므로 실제로는 팔을 바꾼다 —
                  그래서 이 열의 **실현 결과는 유효한 실행 결과**이고, V 만 천장이 아니다.
                  여전히 오프라인 표집이라는 정보 우위가 있으므로 온라인 정책과 동렬은 아니다.
  · `canonical` : 손으로 쓴 규칙 lookup. 적응 없음.
  · `surrogate` : 배포 RandomForest.
  · `llm(dspy)` : LLM 레인.
"""
import argparse
import json
import os
import sys

# 2026-08-18 폴더 분류: 이 파일이 reporting/ 으로 내려갔다. 아래에서 읽는 폴더
# (artifacts_4pol/ · results_4pol/ · dp_oracle/ · md/)는 전부 **wm4 폴더 기준**이므로
# 기준점을 WM 으로 잡는다 — 이 파일 폴더로 잡으면 reporting/artifacts_4pol 을 찾는다.
# 코드 폴더 전부를 sys.path 에 올려 맨이름 import 를 유지한다(근거는 core/simulator_paths.py 머리말).
WM = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(WM, "src", "decision", "core"))
import simulator_paths                                            # noqa: E402,F401

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
    ("dp",        "DP",        "offline value-table lookup · NOT a ceiling (§8.7)"),
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
    ap.add_argument("--artifacts", default=os.path.join(WM, "artifacts_4pol"))
    ap.add_argument("--out-md", default=os.path.join(WM, "artifacts_4pol", "COMPARE.md"))
    ap.add_argument("--out-html", default=os.path.join(WM, "artifacts_4pol", "compare.html"))
    ap.add_argument("--dp-note", default="")
    a = ap.parse_args()

    import objective

    # dp 레인이 이번 스윕에 있는지는 **finish_tables.sh 2단계와 같은 신호**로 판정한다 — 그
    # 스크립트는 `results_4pol/shards_dp` 디렉터리 유무로 dp 샤드 병합 여부를 정하고, 없으면
    # dp 열은 이미 `cell()` 의 결측 분기에서 "이 레인은 스윕에 없음" 으로 표에 남는다(위 참조).
    # 새 신호를 만들지 않는 이유: 여기서 따로 판정하면 칸과 각주가 다른 결론을 낼 수 있고,
    # 바로 그 갈림이 이번에 고치는 결함이다(아래 2026-08-16 주석).
    dp_lane_swept = os.path.isdir(os.path.join(WM, "results_4pol", "shards_dp"))

    # 세대·커버리지 같은 메타는 **파일에서 읽는다.** 문서에 손으로 적으면 갈린다.
    # DP 열이 무엇인지는 **value.json 이 스스로 말하게** 한다. 여기 손으로 적으면 솔버를 바꾼
    # 날 이 문장이 조용히 거짓이 된다(2026-08-14 -> 08-15 에 실제로 그럴 뻔했다).
    _solver = "constant_arm"
    try:
        _solver = json.load(open(os.path.join(WM, "data", "dp_oracle", "value.json"))).get(
            "solver", "constant_arm")
    except Exception:
        pass
    meta = []
    # ★ 2026-08-16 (2차) — **이 "읽는 법" 도 `dp_lane_swept` 로 묶는다.**
    #
    # 1차 수정(커밋 `1bfbcaf8`)은 §8.7 gap 각주와 DP 격자 커버리지 줄만 조건부로 만들었다.
    # 그런데 이 블록은 무조건 돌면서 `dp_oracle/value.json` 의 `solver` 를 읽어
    # "이 표의 DP 는 … 진짜 Bellman backward induction 이다 … 판마다 `Σc + terminal == J` 로
    # 기계 검사된다" 를 발행한다 — **7행 전부가 비어 있는 열에 대해서.** `value.json` 은
    # `aff13715`(배송 이전 세대)에 마지막으로 쓰였으므로, 이것도 1차에서 막은 것과 **정확히
    # 같은 종류의 세대 누수**다.
    #
    # 🔴 **왜 1차 통과에서 살아남았나: 이 문장에는 숫자가 없다.** 1차 수정은 "발행된 수치가
    # 어느 세대의 파일에서 나왔나" 를 grep 으로 훑어 잡았는데, 이 문장은 `value.json` 에서
    # **문자열 하나(`solver`)** 만 읽어 서술문으로 바꾼다. 발행되는 토큰이 `79.7%` 같은
    # 수치가 아니라 "backward induction 이다" 라는 **주장**이라, 수치 검색에 걸리지 않았다.
    # 세대 누수의 판정 기준은 "숫자가 나갔는가" 가 아니라 **"구세대 파일이 이번 세대 산출물의
    # 참·거짓을 정하는가"** 다. `Σc + terminal == J` 로 기계 검사된다는 서술은 검사가 실제로
    # 돈 판이 이 표에 **하나도 없을 때** 그냥 거짓이고, 거짓의 크기는 숫자가 붙은 각주와 같다.
    # (같은 종류: CLAUDE.md 의 "헤드라인 아티팩트가 자기가 없앤 전제를 계속 주장했다".)
    #
    # 🔴 **해시로는 못 잡는다.** 이 `value.json` 의 `objective_hash` 는 `19819377a7f8ebb2` 로
    # **현행과 같다** — 목적함수는 안 갈렸고 갈린 것은 코드 세대(SwapBattery 배송)이기 때문이다.
    # 그래서 세대 판정을 해시에 맡길 수 없고, 쓸 수 있는 신호는 `shards_dp` 뿐이다.
    #
    # dp 샤드가 돌아오면 두 분기는 **축자 그대로** 되살아난다 — 삭제가 아니라 조건문이다.
    if not dp_lane_swept:
        meta.append("> **읽는 법.** `dp` 레인은 이번 스윕에 없다(`results_4pol/shards_dp` 없음) — "
                    "위 dp 열이 전 case 에서 비어 있는 것과 같은 이유다. 그래서 이 표는 DP 가 "
                    "무엇인지(천장인지 · backward induction 인지 · 분해가 기계 검사됐는지)에 대해 "
                    "**아무것도 주장하지 않는다.** `dp_oracle/value.json` 은 이 스윕과 다른 코드 "
                    "세대에 표집된 채 남아 있을 수 있으므로, 그 파일의 서술을 이 표의 성질로 "
                    "옮겨 읽지 말 것. DP 의 정의와 한계 자체는 `dp_oracle/dp_solve.py` 머리말과 "
                    "`dp_oracle/value.json` 의 `known_limits` 에 있다.")
    elif _solver == "backward":
        meta.append("> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장 후보**다 — 실행 가능한 "
                    "온라인 정책이 아니다. 이 표의 DP 는 측정된 φ̃ 격자 위의 **진짜 Bellman "
                    "backward induction** 이다(`V(goal)=0`, `Q(s,a)=mean[c + V(s')]`). 구간 비용 "
                    "`c` 는 J 의 완주 분기 형태로 고정되고 두 분기의 차액은 종단에서 정산되며, "
                    "그 분해는 판마다 `Σc + terminal == J` 로 기계 검사된다. 자세한 정의와 한계는 "
                    "`dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.")
    else:
        meta.append("> **읽는 법.** `dp` 는 네 번째 주자가 아니라 **천장**이다 — 실행 가능한 온라인 "
                    "정책이 아니고, 이 표의 DP 는 상수-팔 반사실 표집의 최선이다(backward induction "
                    "이 아니다: 이 하니스는 J 를 판 단위로 낸다). 자세한 정의와 한계는 "
                    "`dp_oracle/dp_solve.py` 머리말과 `dp_oracle/value.json` 의 `known_limits`.")
    meta.append("")
    meta.append("> build time 은 **완주한 판만** 평균한다(생존자 편향). 그래서 완주 0/30 인 칸은 "
                "`—` 다. J/closed 는 미완주 판에서도 정의되므로 그 칸에서도 남는다.")

    # ---- §8.7 gap 을 **여기서 계산해** 표에 싣는다 -----------------------------------------
    # 이 수치가 DP 열의 이름을 정한다. 손으로 적으면 다음 스윕에서 조용히 거짓이 되므로,
    # 표를 만들 때마다 다시 잰다. 비교는 **평균 대 평균**이다 — 개별 실현 J 를 평균 V 와 대면
    # J 가 이봉분포(완주 ~20 / 미완주 ~15000)라 좋은 판이 자동으로 이기고, 그건 비교가 아니다.
    #
    # ★ 2026-08-15 — **비교의 단위를 솔버에 맞춘다.** 이걸 안 맞추면 gap 이 무의미해진다:
    #   · constant_arm 의 V 는 **판 전체 J** 의 평균이다  -> 실행 정책도 판 전체 J 로 잰다.
    #   · backward 의 V 는 **그 칸부터의 cost-to-go** 다   -> 실행 정책도 cost-to-go 로 재야 한다.
    # 섞으면 backward 쪽에서 V 가 구조적으로 더 작아 gap 이 100% 로 자동 발화한다 — 그건 측정이
    # 아니라 단위 오류다. 실행 정책의 cost-to-go 는 DP 표본과 **같은 분해**로 뽑는다:
    #       ctg_i = Σ_{k>=i} c_k + terminal_value  =  J_row − c_prefix − Σ_{k<i} c_k
    #
    # ★ 2026-08-16 — **dp 레인이 이번 스윕에 없으면(`dp_lane_swept` False) 이 블록 전체를
    # 건너뛴다.** 이유: 아래 계산은 **현재** `results_4pol/*.jsonl`(이번 세대의
    # canonical/surrogate/dspy 행)을 `dp_oracle/value.json` 의 V 와 무조건 대면시킨다. dp 열이
    # 스윕에서 빠졌다는 것은 — 이번 courier 리스윕이 실제로 그렇듯 — `value.json` 이 결과와는
    # **다른 코드 세대**(SwapBattery 가 물리 배터리 배송으로 바뀌기 이전)에 표집된 채 남아 있을
    # 수 있다는 뜻이다. 그 상태에서 조건 없이 돌리면 dp **열**(칸)은 `cell()` 이 이미 올바르게
    # "이 레인은 스윕에 없음" 으로 비워 두는데도, **그 옆 각주에는 세대가 섞인 gap 수치가
    # 발행된다** — 칸은 맞고 각주만 새는 형태라 표를 훑는 것만으로는 안 잡힌다(리뷰에서 실제로
    # 새어 나간 결함, CLAUDE.md 의 "헤드라인 아티팩트가 자기가 없앤 전제를 계속 주장했다" 와
    # 같은 종류). dp 샤드가 다시 이 트리에 들어오면(`shards_dp` 가 재생성되면) 이 블록은 자동으로
    # 되살아난다 — 이건 삭제가 아니라 조건문이다. 되살리기 전에 `dp_oracle/value.json` 이 실제로
    # 그 시점의 `results_4pol` 과 같은 코드 세대인지부터 확인할 것(단순히 파일이 있다고 세대가
    # 맞는다는 뜻은 아니다).
    gap_note = ""
    if dp_lane_swept:
        try:
            import collections as _c
            import statistics as _st
            import glob as _g
            sys.path.insert(0, os.path.join(WM, "dp_oracle"))
            from derive_grid import cell_key as _ck, state_of as _so
            from sample_grid import decompose_board as _dec
            # gap 의 **원인 문장**은 손으로 적지 않는다 — 표본의 `sampling_mode` 에서 유도한다.
            # (2026-08-17 최종 리뷰 Critical 3: 하드코딩된 원인 ①·③ 이 이미 닫힌 뒤에도 헤드라인
            #  아티팩트가 자기 전제를 계속 주장했다. 진실원은 `sample_grid.gap_cause_note`.)
            from sample_grid import gap_cause_note as _gcn, samples_sampling_mode as _ssm
            _g_spec = json.load(open(os.path.join(WM, "data", "dp_oracle", "grid_spec.json")))
            _v = json.load(open(os.path.join(WM, "data", "dp_oracle", "value.json")))
            _V = {c: d["V"] for c, d in _v["cells"].items() if d.get("V") is not None}
            _backward = _v.get("solver") == "backward"
            _per = _c.defaultdict(lambda: _c.defaultdict(list))
            _skipped = _c.Counter()
            for _p in _g.glob(os.path.join(WM, "results_4pol", "*.jsonl")):
                for _l in open(_p):
                    _l = _l.strip()
                    if not _l:
                        continue
                    _r = json.loads(_l)
                    if _r.get("policy") not in ("canonical", "surrogate", "dspy"):
                        continue
                    if _backward:
                        _d0 = _dec(_r)
                        if not _d0["ok"]:
                            # 조용히 넘기지 않는다 — 아래 gap_note 가 이 수를 같이 싣는다.
                            _skipped[str(_d0["reason"]).split(":")[0]] += 1
                            continue
                        _run = _d0["c_prefix"]            # 결정 i 이전까지의 누적 러닝코스트
                    else:
                        try:
                            _J = objective.J_row(_r)
                        except Exception as _e2:
                            _skipped[type(_e2).__name__] += 1
                            continue
                    _seen = set()
                    for _i, _d in enumerate(_r.get("decisions") or []):
                        _s = _so(_d, _g_spec["axes"])
                        if _backward:
                            # 이 칸에서의 **실현 cost-to-go**. 칸을 못 세워도 러닝코스트는
                            # 누적한다 — 안 그러면 뒤 결정들의 ctg 가 통째로 어긋난다.
                            _val = _d0["J"] - _run
                            _run += _d0["cs"][_i]
                        else:
                            _val = _J
                        if _s is None:
                            continue
                        _k = _ck(_s)
                        if _k in _seen or _k not in _V:
                            continue
                        _seen.add(_k)
                        _per[_k][_r["policy"]].append(_val)
            _w = _t = 0
            for _k, _bp in _per.items():
                for _pol, _Js in _bp.items():
                    if len(_Js) < 3:
                        continue
                    _t += 1
                    if _st.mean(_Js) < _V[_k] - 1e-9:
                        _w += 1
            _unit = ("그 칸부터의 **실현 cost-to-go**" if _backward else "판 전체의 평균 J")
            _mode = _ssm(os.path.join(WM, "data", "dp_oracle", "samples.jsonl"))
            if _t:
                gap_note = ("**원 설계 §8.7 gap (평균 대 평균, n≥3 인 (칸,정책) 쌍 %d개; 비교 단위 = %s; "
                            "표집 모드 = `%s`).** "
                            "실행 정책이 DP 의 V 보다 **좋은** 쌍 %d개 = **%.1f%%**. %s%s"
                            % (_t, _unit, _mode, _w, 100.0 * _w / _t,
                               ("0 이 아니므로 이 표에서 **DP 열을 '천장' 이라 부르지 않는다.** "
                                + ("원인은 상수-팔이 아니다(V 는 진짜 backward induction 이다). " + _gcn(_mode)
                                   if _backward else
                                   "V 는 상수-팔 표집에서 나오는데 사건이 섞인 판을 한 팔로 처리할 수 "
                                   "없어 그 정책군이 실행 레인보다 약하기 때문이다.")
                                + " 다만 dp **레인**은 칸마다 a* 를 갈아 쓰므로 이 열의 실현 결과 "
                                  "자체는 유효한 실행 결과다."
                                if _w else "0 이므로 이 격자 위에서는 천장이라는 이름이 유지된다."),
                               ("" if not _skipped else
                                " (분해 불가로 제외한 행: %s)" % dict(_skipped))))
        except Exception as _e:                       # 계산 실패를 조용히 넘기지 않는다
            gap_note = "§8.7 gap 을 계산하지 못했다: %r" % (_e,)
    else:
        gap_note = ("dp 레인은 이번 스윕에 없다(`results_4pol/shards_dp` 없음) — §8.7 gap 은 "
                    "**측정하지 않았다.** 위 dp 열이 전 case 에서 `이 레인은 스윕에 없음` 인 것과 "
                    "같은 이유다. 과거 스윕의 gap 수치를 이어 붙이지 않는 이유는, 그 값이 다른 "
                    "코드 세대의 `results_4pol/*.jsonl` 로 잰 것이라 지금 세대와 대면시키면 두 "
                    "세대가 섞인 숫자가 되기 때문이다 — 빈 열을 보고 '천장이 닫혔다' 나 "
                    "'gap 이 줄었다' 로 읽지 말 것.")

    vpath = os.path.join(WM, "data", "dp_oracle", "value.json")
    gpath = os.path.join(WM, "data", "dp_oracle", "grid_spec.json")
    # dp 열이 스윕에 없을 때 이 커버리지 줄도 §8.7 gap 과 같은 이유로 같이 죽인다 — 커버리지는
    # value.json 이 **어느 세대의 결과에 대해** 격자를 얼마나 채웠는지를 말하는데, 결과가 없는
    # 세대의 value.json 을 놓고 "66/65 = 101.5%" 를 발행하면 이번 스윕과 무관한 숫자가 된다.
    if dp_lane_swept and os.path.exists(vpath) and os.path.exists(gpath):
        v = json.load(open(vpath))
        g = json.load(open(gpath))
        cov = 100.0 * v.get("n_cells", 0) / max(g.get("n_observed_cells", 1), 1)
        meta.append("")
        meta.append("> **DP 격자 커버리지** %d / %d 관측 칸 = %.1f%% · a\\* 미확정(동점) %d칸 · "
                    "전부 채점불가 %d칸 · 단일팔 %d칸."
                    % (v.get("n_cells", 0), g.get("n_observed_cells", 0), cov,
                       v.get("n_tie_unresolved", 0), v.get("n_cells_unscorable", 0),
                       v.get("n_cells_single_arm", 0)))
    if gap_note:
        meta.append("")
        meta.append("> " + gap_note)
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
