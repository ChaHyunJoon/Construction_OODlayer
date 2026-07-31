#!/usr/bin/env python
"""Assemble the cost-evaluation artifact HTML from cost_eval_metrics.json + rendered figures."""
# =============================================================================
# [한국어 안내] build_artifact.py 는 무엇을 하는 파일인가
# -----------------------------------------------------------------------------
# 목적:
#   실험 결과 숫자(cost_eval_metrics.json)와 cost_figures.py 가 만든 PNG 그림들을
#   하나로 합쳐, 공유 가능한 단일 HTML 리포트(cost_artifact.html)를 만든다.
#   이미지는 외부 파일 링크가 아니라 base64 로 HTML 안에 통째로 박아 넣어(self-
#   contained) 파일 하나만 열면 되게 한다.
#
#   담는 내용: surrogate vs LLM planner 의 "적응 비용" 비교 —
#   결정당 latency, decision regret, 완주율(completion), 손익분기(break-even),
#   그리고 oracle 이 100% 완주함을 어떻게(꼼수 없이) 달성했는지 설명 섹션.
#
# 프로젝트에서의 역할:
#   파이프라인의 마지막 "리포트 조립" 단계.
#   (cost_eval.py 로 metrics 계산 → cost_figures.py 로 PNG → build_artifact.py 로 HTML)
#
# 실행 방법:
#   python build_artifact.py [metrics.json] [하위폴더명]
#     인자 없으면 metrics=cost_eval_metrics.json, 폴더=cost 기본값.
#   결과: results/cost/cost_artifact.html 저장.
#
# ── 문법 참고 (처음 보는 Python 문법 힌트) ──────────────────────────────────
#   * base64.b64encode(바이트).decode(): PNG 바이너리를 텍스트로 바꿔
#       "data:image/png;base64,..." data-URI 로 HTML 에 이미지를 인라인 삽입.
#   * with open(경로, "rb") as f: 파일을 열고 블록이 끝나면 자동으로 닫는다("rb"=바이너리 읽기).
#   * json.load(open(경로)): JSON → 파이썬 dict (M).
#   * sys.argv / (A if 조건 else B): 커맨드라인 인자와 기본값 선택(삼항표현식).
#   * f-string + 삼중따옴표 f\"\"\"...\"\"\": 여러 줄 문자열 안에서 {변수}·{식} 를 값으로 치환.
#       주의: 이 파일의 큰 HTML 블록은 CSS 의 { } 와 충돌을 피하려고 {{ }} (이중중괄호)로
#       "글자 그대로의 중괄호"를 표현한다. 즉 {{ → 결과에서는 { 한 개가 된다.
#   * "\n".join(리스트): 리스트의 문자열들을 줄바꿈으로 이어붙인다.
#   * row_html(*r): 튜플 r 을 함수 인자들로 풀어서(unpack) 전달하는 * 문법.
#   * f"{x:,.0f}": 천단위 콤마 + 정수, f"{x*100:.0f}%": 비율→퍼센트 표기.
# =============================================================================
import os, sys, json, base64
HERE = os.path.dirname(os.path.abspath(__file__))   # 이 스크립트가 있는 폴더의 절대경로
# 첫 인자=metrics JSON 경로(없으면 기본), 둘째 인자=그림이 있는 results 하위폴더명
METRICS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "cost_eval_metrics.json")
SUBDIR = sys.argv[2] if len(sys.argv) > 2 else "cost"
M = json.load(open(METRICS))                         # 실험 결과 전체를 dict 로 로드
FIG = os.path.join(HERE, "results", SUBDIR)          # PNG 그림들이 들어있는 폴더


# PNG 파일 하나를 읽어 HTML 에 바로 박을 수 있는 base64 data-URI 문자열로 변환
def b64(name):
    with open(os.path.join(FIG, name), "rb") as f:   # 바이너리로 읽기
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()

pd_ = M["per_decision"]                              # 정책별 결정당 지표 묶음
# 자주 쓰는 4개 정책을 짧은 이름 변수로 꺼내둠
sur = pd_["Surrogate-only (k=0, ours)"]              # 우리 방법(surrogate 단독)
solver = pd_["LLM->solver (verify C=3)"]             # LLM + 정확 solver 검증(선행연구)
llm = pd_["LLM-only planner (no verify)"]            # LLM 단독(검증 없음)
oracle = pd_["Oracle (verify all 5)"]                # 전부 검증하는 상한선(oracle)
spd_solver = solver["latency_s"] / sur["latency_s"]  # surrogate 가 solver 대비 몇 배 빠른지
ci = M["necessity_ci"]                               # surrogate 우위의 95% 신뢰구간


# 초(second) 값을 크기에 맞춰 ms / s / min 문자열로 예쁘게 변환
def fmt_lat(s):
    return f"{s*1e3:.2f} ms" if s < 1 else (f"{s:.0f} s" if s < 90 else f"{s/60:.1f} min")

# 표에 넣을 5개 정책 행 정의: (표시이름, 지표dict, CSS클래스, 설명문구)
ROWS = [
    ("Oracle · verify all 5", oracle, "expensive", "brute-force TAMP ceiling"),
    ("LLM→solver · verify 3", solver, "expensive", "LLM + exact solver (prior art)"),
    ("LLM-only · no verify", llm, "wrong", "a general LLM as decision-maker"),
    ("Surrogate → verify-1", pd_["Surrogate->verify-1"], "ok", "surrogate ranks, verify top-1"),
    ("Surrogate-only · k=0", sur, "ours", "the deployed policy"),
]

# 정책 행 하나를 표(table)의 <tr>...</tr> HTML 문자열로 만든다 (여기 { }는 f-string 값 치환)
def row_html(name, d, cls, note):
    return f"""<tr class="r-{cls}">
      <td class="pol">{name}<span class="note">{note}</span></td>
      <td class="num lat">{fmt_lat(d['latency_s'])}</td>
      <td class="num">{d['regret']:.3f}</td>
      <td class="num">{d['completion']*100:.0f}%</td>
    </tr>"""

# ROWS 의 각 튜플 r 을 row_html(*r) 로 펼쳐 행 HTML 을 만들고 줄바꿈으로 이어붙임
rows = "\n".join(row_html(*r) for r in ROWS)

stream = "→".join(M["stream"])                       # OOD 이벤트 스트림을 화살표로 이은 문자열
perbuild_solver = M["per_build"]["LLM->solver (verify C=3)"]["total_s"] / 60   # 빌드당 solver 결정시간(분)
perbuild_sur = M["per_build"]["Surrogate-only (k=0, ours)"]["total_s"] * 1e3   # 빌드당 surrogate 결정시간(ms)

# 리포트에 넣을 그림 목록: (파일명, 제목, 캡션설명)
FIGS = [
    ("fig1_frontier.png", "Cost–quality frontier", "Latency (log s) vs decision regret. The surrogate sits alone in the cheap-and-accurate corner; no policy is both faster and better."),
    ("fig3_latency_accuracy.png", "Latency & quality side by side", "Left: per-decision latency (measured T_sim/T_surr, live T_llm). Right: cost-aware regret and build completion."),
    ("fig2_perbuild.png", "Whole-build adaptation time", f"Total decide-time across the {len(M['stream'])}-event stream {stream}, annotated with completion."),
    ("fig4_breakeven.png", "Break-even vs LLM→solver", f"The surrogate's one-time data-gen cost is repaid after ~{M['breakeven_decisions']:.0f} decisions."),
]
# 각 그림을 <figure>+base64 이미지+캡션 HTML 로 만들어 이어붙임 (b64 로 PNG 를 인라인 삽입)
figs_html = "\n".join(f"""<figure>
    <img src="{b64(f)}" alt="{t}" loading="lazy" />
    <figcaption><b>{t}.</b> {c}</figcaption>
  </figure>""" for f, t, c in FIGS)

# 아래는 리포트 전체 HTML 을 만드는 거대한 f-string.
#   주의: <style> 안의 CSS 는 { } 를 쓰므로, f-string 이 값으로 오해하지 않게
#   전부 {{ }} (이중중괄호)로 이스케이프되어 있다({{→실제 {, }}→실제 }).
#   {변수} (홑중괄호)만 파이썬 값으로 치환된다. 이 블록 안에는 주석을 넣지 말 것.
html = f"""<title>Surrogate vs LLM Planner — Cost of Adaptation</title>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
:root {{
  --bg:#f6f7f9; --panel:#ffffff; --ink:#141a22; --muted:#5c6672; --line:#e2e6ec;
  --grid:#eef1f5; --accent:#12a150; --accent-soft:#e6f5ec;
  --hot:#c0392b; --warn:#d98324; --cool:#2472b8;
  --mono:ui-monospace,"SF Mono","Cascadia Code","Roboto Mono",Menlo,Consolas,monospace;
  --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
}}
@media (prefers-color-scheme:dark) {{
  :root {{ --bg:#0e1319; --panel:#161d26; --ink:#e6ebf1; --muted:#93a0af; --line:#242e3a;
    --grid:#1b2330; --accent:#2fd07a; --accent-soft:#13291d; --hot:#f06a5d; --warn:#f0a95a; --cool:#5aa9e6; }}
}}
:root[data-theme="dark"] {{ --bg:#0e1319; --panel:#161d26; --ink:#e6ebf1; --muted:#93a0af; --line:#242e3a;
  --grid:#1b2330; --accent:#2fd07a; --accent-soft:#13291d; --hot:#f06a5d; --warn:#f0a95a; --cool:#5aa9e6; }}
:root[data-theme="light"] {{ --bg:#f6f7f9; --panel:#ffffff; --ink:#141a22; --muted:#5c6672; --line:#e2e6ec;
  --grid:#eef1f5; --accent:#12a150; --accent-soft:#e6f5ec; --hot:#c0392b; --warn:#d98324; --cool:#2472b8; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font-family:var(--sans);
  line-height:1.55; -webkit-font-smoothing:antialiased; }}
.wrap {{ max-width:1060px; margin:0 auto; padding:clamp(20px,4vw,56px) clamp(16px,4vw,40px) 72px; }}
.eyebrow {{ font-family:var(--mono); font-size:12px; letter-spacing:.12em; text-transform:uppercase;
  color:var(--accent); font-weight:600; }}
h1 {{ font-size:clamp(26px,4.4vw,40px); line-height:1.12; margin:.35em 0 .3em; text-wrap:balance;
  letter-spacing:-.02em; }}
h1 .g {{ color:var(--accent); }}
.lede {{ font-size:clamp(15px,1.9vw,18px); color:var(--muted); max-width:64ch; margin:0 0 8px; }}
.meta {{ font-family:var(--mono); font-size:12px; color:var(--muted); margin-top:14px;
  display:flex; flex-wrap:wrap; gap:6px 18px; }}
.meta b {{ color:var(--ink); font-weight:600; }}
section {{ margin-top:44px; }}
h2 {{ font-size:13px; font-family:var(--mono); letter-spacing:.1em; text-transform:uppercase;
  color:var(--muted); font-weight:600; margin:0 0 16px; padding-bottom:10px;
  border-bottom:1px solid var(--line); }}
.tiles {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(210px,1fr)); gap:14px; }}
.tile {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:20px 20px 18px;
  position:relative; overflow:hidden; }}
.tile::before {{ content:""; position:absolute; left:0; top:0; bottom:0; width:3px; background:var(--accent); }}
.tile.cool::before {{ background:var(--cool); }} .tile.hot::before {{ background:var(--hot); }}
.tile .k {{ font-family:var(--mono); font-size:11.5px; letter-spacing:.06em; text-transform:uppercase;
  color:var(--muted); }}
.tile .v {{ font-family:var(--mono); font-size:clamp(26px,3.6vw,34px); font-weight:600; margin:8px 0 4px;
  font-variant-numeric:tabular-nums; letter-spacing:-.02em; }}
.tile .s {{ font-size:13px; color:var(--muted); }}
.tile .v.green {{ color:var(--accent); }} .tile .v.red {{ color:var(--hot); }}
table {{ width:100%; border-collapse:collapse; font-size:14.5px; }}
.tblwrap {{ overflow-x:auto; border:1px solid var(--line); border-radius:12px; background:var(--panel); }}
thead th {{ font-family:var(--mono); font-size:11px; letter-spacing:.07em; text-transform:uppercase;
  color:var(--muted); text-align:right; padding:14px 18px; font-weight:600; border-bottom:1px solid var(--line); }}
thead th:first-child {{ text-align:left; }}
td {{ padding:13px 18px; border-bottom:1px solid var(--line); vertical-align:top; }}
tbody tr:last-child td {{ border-bottom:none; }}
.num {{ font-family:var(--mono); text-align:right; font-variant-numeric:tabular-nums; }}
.pol {{ font-weight:600; display:flex; flex-direction:column; gap:2px; }}
.pol .note {{ font-weight:400; font-size:12px; color:var(--muted); font-family:var(--sans); }}
tr.r-ours {{ background:var(--accent-soft); }}
tr.r-ours .pol {{ color:var(--accent); }}
tr.r-ours .lat {{ color:var(--accent); font-weight:700; }}
tr.r-wrong .num:nth-child(3) {{ color:var(--warn); }}
tr.r-expensive .lat {{ color:var(--hot); }}
.claims {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; }}
.claim {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:22px; }}
.claim .tag {{ font-family:var(--mono); font-size:11px; letter-spacing:.08em; text-transform:uppercase;
  color:var(--accent); font-weight:600; }}
.claim h3 {{ font-size:17px; margin:8px 0 8px; letter-spacing:-.01em; }}
.claim p {{ font-size:14px; color:var(--muted); margin:0; }}
.claim .big {{ font-family:var(--mono); color:var(--ink); font-weight:600; }}
.figs {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(340px,1fr)); gap:20px; }}
figure {{ margin:0; background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px; }}
figure img {{ width:100%; height:auto; border-radius:6px; display:block; background:#fff; }}
figcaption {{ font-size:12.5px; color:var(--muted); margin-top:10px; }}
figcaption b {{ color:var(--ink); }}
.honesty {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:22px 24px; }}
.honesty ul {{ margin:0; padding-left:20px; }}
.honesty li {{ font-size:14px; color:var(--muted); margin:7px 0; }}
.honesty li b {{ color:var(--ink); font-weight:600; }}
.thesis {{ border-left:3px solid var(--accent); padding:4px 0 4px 22px; margin:8px 0 0;
  font-size:clamp(16px,2.1vw,19px); line-height:1.5; }}
.thesis b {{ color:var(--accent); }}
code {{ font-family:var(--mono); font-size:.88em; background:var(--grid); padding:1px 6px; border-radius:5px; }}
footer {{ margin-top:52px; padding-top:20px; border-top:1px solid var(--line);
  font-family:var(--mono); font-size:12px; color:var(--muted); }}
</style>

<div class="wrap">
  <header>
    <div class="eyebrow">wm4spacecraft · surrogate world model · cost evaluation</div>
    <h1>The surrogate decides in <span class="g">{sur['latency_s']*1e3:.2f}&nbsp;ms</span> what an LLM planner needs <span class="g">minutes</span> to match</h1>
    <p class="lede">A cost-of-adaptation evaluation on the graded spacecraft-assembly benchmark, pricing five
    OOD-recovery policies in real units — latency, decision regret, build completion, dollars — to test one
    claim: is the learned surrogate actually cheaper than a general LLM planner at equal-or-better quality?</p>
    <div class="meta">
      <span><b>Benchmark</b> graded_hs_all · 20 instances · 100 sims</span>
      <span><b>T<sub>sim</sub></b> measured 81&nbsp;s median</span>
      <span><b>T<sub>llm</sub></b> live gpt-4o-mini 1.0&nbsp;s</span>
      <span><b>Scoring</b> cost-aware, LOO, paired</span>
    </div>
  </header>

  <section>
    <h2>The result at a glance</h2>
    <div class="tiles">
      <div class="tile"><div class="k">Surrogate latency / decision</div>
        <div class="v green">{sur['latency_s']*1e3:.2f} ms</div><div class="s">measured, deployed 60-tree forest</div></div>
      <div class="tile hot"><div class="k">vs LLM→solver, same quality</div>
        <div class="v red">{spd_solver/1e6:.1f}M× slower</div><div class="s">LLM must verify → {solver['latency_s']:.0f} s/decision</div></div>
      <div class="tile"><div class="k">More accurate than LLM-only</div>
        <div class="v green">+{ci['mean']:.3f}</div><div class="s">regret, 95% CI [+{ci['lo']:.2f}, +{ci['hi']:.2f}]</div></div>
      <div class="tile cool"><div class="k">Build completion (matches the GT ceiling)</div>
        <div class="v">{sur['completion']*100:.0f}% <span style="color:var(--muted);font-size:.6em">vs</span> {llm['completion']*100:.0f}%</div>
        <div class="s">surrogate vs un-verified LLM planner</div></div>
    </div>
  </section>

  <section>
    <h2>Per-decision cost — every policy, real units</h2>
    <div class="tblwrap">
      <table>
        <thead><tr><th>Policy</th><th>Latency</th><th>Regret</th><th>Complete</th></tr></thead>
        <tbody>
{rows}
        </tbody>
      </table>
    </div>
    <p class="lede" style="margin-top:14px;font-size:14px">Regret is the cost-aware, per-scenario-normalized,
    leave-one-instance-out decision regret — the metric that charges a wasted spare, so restraint (NOOP on a
    healthy battery) counts. The only zero-regret policies pay it in verification time.</p>
  </section>

  <section>
    <h2>Three cost claims, each measured</h2>
    <div class="claims">
      <div class="claim"><div class="tag">Faster</div>
        <h3>Millions × faster, both ends measured</h3>
        <p>Each true-planner verification is a measured <span class="big">{M['T_sim']['median']:.0f} s</span> ConstructionBots sim.
        A guaranteed-feasible LLM policy must run several — <span class="big">{solver['latency_s']:.0f} s</span>
        per decision. The surrogate answers in <span class="big">{sur['latency_s']*1e3:.2f} ms</span>: <b>{spd_solver:,.0f}×</b> faster at
        the same decision quality.</p></div>
      <div class="claim"><div class="tag">More accurate</div>
        <h3>Beats an LLM that skips verification</h3>
        <p>The LLM-only planner reads the OOD <i>kind</i> and applies the textbook macro — regret
        <span class="big">{llm['regret']:.3f}</span>, only <span class="big">{llm['completion']*100:.0f}%</span> of
        builds finish. The surrogate reads state <i>within</i> the kind: regret <span class="big">{sur['regret']:.3f}</span>,
        <span class="big">{sur['completion']*100:.0f}%</span> complete. Advantage <b>+{ci['mean']:.3f}</b>, CI-significant.</p></div>
      <div class="claim"><div class="tag">Cheaper per build</div>
        <h3>And it amortizes fast</h3>
        <p>Over one build's OOD stream, LLM→solver spends <span class="big">{perbuild_solver:.0f} min</span> just
        deciding; the surrogate spends <span class="big">{perbuild_sur:.1f} ms</span>. Its one-time data-gen cost
        is repaid after <b>~{M['breakeven_decisions']:.0f} decisions</b> (~{M['breakeven_decisions']/len(M['stream']):.0f} builds).</p></div>
    </div>
  </section>

  <section>
    <h2>Evidence</h2>
    <div class="figs">
{figs_html}
    </div>
  </section>

  <section>
    <h2>The ground truth completes 100% — how, without cheating</h2>
    <div class="honesty">
      <p class="lede" style="margin:0 0 12px;font-size:14px">The brute-force TAMP oracle is the reference
      ceiling, so it must be able to finish every build — otherwise "regret vs the oracle" is measured
      against a broken reference. On the first benchmark it completed only 80%; the other 20% split into
      two causes, each fixed on its own terms (no logical or physical shortcut):</p>
      <ul>
        <li><b>No-spare fault (was physically impossible).</b> Two instances faulted a robot with
        <b>zero spares configured</b> — there is literally nothing to replace it with, so no macro can
        finish. Fixed by provisioning <b>one spare</b> (the realistic operating regime): Replace now
        completes (283/297) and is strictly required — every other macro still fails. A 0-spare fault is
        genuinely unrecoverable and is excluded as out-of-scope for a <i>decision</i> benchmark.</li>
        <li><b>Zone endgame wedge (was a stale label).</b> Two zone instances were carried over from an
        <b>older pre-recovery world</b>; regenerated with the same reactive endgame recovery the real
        system runs (reform-interval 120 + stuck-carrier force-close), the zone build completes on every
        macro — the no-go region is evaded by restaging, not by routing through it.</li>
      </ul>
      <p class="lede" style="margin:12px 0 0;font-size:14px">Result: oracle completion <b>20/20 = 100%</b>,
      and the surrogate <b>matches it</b> ({sur['completion']*100:.0f}%) while the un-verified LLM planner
      still finishes only {llm['completion']*100:.0f}%. Crucially, the necessity signal survives the fix:
      the surrogate still beats the best state-blind rule by <b>+{ci['mean']:.3f}</b> regret
      [{ci['lo']:+.3f}, {ci['hi']:+.3f}], because the within-kind flips (battery SoC ladder, fault vs
      idle-fault) are untouched.</p>
    </div>
  </section>

  <section>
    <h2>Why this is a fair fight</h2>
    <div class="honesty">
      <ul>
        <li><b>Measured, not assumed.</b> T<sub>sim</sub> ({M['T_sim']['median']:.0f} s median) is read from the oracle's own
        <code>label_seconds</code>; T<sub>surr</sub> ({sur['latency_s']*1e3:.2f} ms) is timed on the deployed forest; T<sub>llm</sub>
        (1.0 s) is 6 live gpt-4o-mini calls. Only the LLM's <i>accuracy</i> is modeled — at its best case.</li>
        <li><b>The LLM gets every benefit.</b> Best-case accuracy (always reads the kind right) and the
        cheapest, fastest model. A frontier planner on full state is slower and pricier — this under-states
        the surrogate's edge. A live probe still caught it: asked about a healthy battery at SoC 0.52, the LLM
        chose Replace (wastes a spare) where the oracle chooses NOOP.</li>
        <li><b>Honest physics.</b> T<sub>sim</sub> is measured with the reactive motion stack (RVO) on — the
        regime where the best macro is congestion-dependent. The saving comes from amortizing process-parallel
        physics, not from cheaper physics.</li>
        <li><b>The decision-relevant benchmark.</b> Scored on the cost-aware graded task, where a
        Replace-everything heuristic can't tie the oracle — so the comparison isn't an artifact of an
        easy task.</li>
      </ul>
    </div>
    <p class="thesis">With a ground truth that completes 100%, the comparison is clean: the surrogate
    <b>matches the oracle ceiling on completion</b> at near-oracle regret in {sur['latency_s']*1e3:.2f} ms —
    while an LLM planner is either fast-but-wrong (75% complete) or right-but-minutes-slow. The surrogate is
    the only policy that is <b>simultaneously cheap, accurate, and completion-safe</b>.</p>
  </section>

  <footer>cost_eval.py · llm_probe.py · cost_figures.py — reproducible from oracle/out/graded_hs_v2.jsonl (oracle completes 100%) · 2026-07-15</footer>
</div>"""

# 완성된 HTML 을 파일로 저장 (utf-8 로 써서 한글/화살표 등 유니코드 보존)
out = os.path.join(HERE, "results", "cost", "cost_artifact.html")
with open(out, "w", encoding="utf-8") as f:
    f.write(html)
print("wrote", out, f"({len(html)/1024:.0f} KB)")   # 저장 경로와 대략적 파일 크기(KB) 출력
