#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""artifacts_llm7h 산출물 -> 자립형(self-contained) HTML 한 장.

왜 필요한가
-----------
`artifacts_llm7h/` 에는 두 종류의 산출물이 섞여 있는데, 둘 다 지금은 볼 방법이 없다.
  · final.json          = 5시드 x 4정책 집계 + **정책별 결정 상세**(chosen vs reference)
  · *_stream.jsonl      = monitor 포맷 프레임(로봇 pos/soc, 조립 트리, OOD, 재명세)
대시보드(dashboard.html)는 서버 + streams/ 폴더가 있어야 돌고, 정책 비교 블록이 없는
이 스트림들은 결정 패널이 비어 버린다. 그래서 서버 없이 파일 하나로 여는 경로를 만든다.

MeshCat 3D 애니는 여기서 만들 수 없다 - 프레임에는 지오메트리가 없고 (x, y) 뿐이다.
그래서 공장 뷰는 2D 평면으로 그린다.

사용법
------
    python tools/monitor/artifacts_to_html.py \
        --results results/artifacts_llm7h/final.json \
        --stream  results/artifacts_llm7h/p0_baseline_stream.jsonl \
        --out     results/artifacts_llm7h/report.html

둘 다 선택이다(--results 만 주면 표+결정로그, --stream 만 주면 재생기만).
"""
import argparse
import html
import json
import pathlib

# 프레임에서 빼고 실을 필드. schedule 은 프레임당 179 항목이라 파일의 대부분을 차지하는데
# 이 리포트는 Gantt 를 그리지 않는다(대시보드가 그 역할). component_ids 도 화면에 안 쓴다.
DROP_FRAME_KEYS = ("schedule",)
DROP_ASM_KEYS = ("component_ids",)

POLICY_ORDER = ("noop", "canonical", "surrogate", "dspy")
POLICY_LABEL = {
    "noop": "noop (아무것도 안 함)",
    "canonical": "canonical (손으로 쓴 규칙)",
    "surrogate": "surrogate (RandomForest)",
    "dspy": "dspy (LLM · gpt-4o)",
}
KIND_LABEL = {"BatteryTruth": "Battery", "FaultTruth": "Fault", "ZoneTruth": "Zone"}


def esc(x):
    return html.escape(str(x), quote=True)


def pct(x):
    return "—" if x is None else "{:.0f}%".format(100 * x)


def ci(pair):
    return "" if not pair else "[{:.2f}, {:.2f}]".format(pair[0], pair[1])


def num(x, fmt="{:.1f}"):
    return "—" if x is None else fmt.format(x)


# ---------------------------------------------------------------- 집계 표
def render_results(d):
    seeds = d.get("seeds", [])
    basis = d.get("basis", {})
    pols = d.get("policies", {})
    keys = [k for k in POLICY_ORDER if k in pols] + [k for k in pols if k not in POLICY_ORDER]

    rows = []
    for k in keys:
        p = pols[k]
        sd = p.get("sim_seconds_sd")
        sim = p.get("sim_seconds_complete")
        rows.append(
            "<tr class='{cls}'><th>{name}</th>"
            "<td>{comp} <span class=ci>{compci}</span></td>"
            "<td>{dec} <span class=dim>({nc}/{ns})</span> <span class=ci>{decci}</span></td>"
            "<td>{sim}</td><td>{j}</td><td>{soc}</td><td>{sp}</td></tr>".format(
                cls="best" if k == "dspy" else "",
                name=esc(POLICY_LABEL.get(k, k)),
                comp="{} <span class=dim>({}/{})</span>".format(
                    pct(p.get("success")), p.get("n_complete"), p.get("n")),
                compci=ci(p.get("success_ci")),
                dec=pct(p.get("decision_rate")),
                nc=p.get("n_decisions_correct"), ns=p.get("n_decisions_scored"),
                decci=ci(p.get("decision_ci")),
                sim="—" if not sim else "{} <span class=dim>± {}</span>".format(
                    num(sim), num(sd)),
                j=num(p.get("energy_per_closed"), "{:.0f}"),
                soc=num(p.get("min_soc"), "{:.3f}"),
                sp=num(p.get("spares_left"), "{:.1f}"),
            )
        )

    # 종류별 적중
    kinds = []
    for k in keys:
        pk = pols[k].get("per_kind", {})
        cells = "".join(
            "<td>{}/{}</td>".format(pk.get(t, {}).get("correct", "—"), pk.get(t, {}).get("n", "—"))
            for t in ("BatteryTruth", "FaultTruth", "ZoneTruth")
        )
        kinds.append("<tr><th>{}</th>{}</tr>".format(esc(POLICY_LABEL.get(k, k)), cells))

    # 고른 매크로
    chosen = []
    for k in keys:
        c = pols[k].get("chosen", {})
        tot = sum(c.values()) or 1
        bars = "".join(
            "<div class=bar><span class=lbl>{}</span>"
            "<span class=fill style='width:{:.1f}%'></span>"
            "<span class=cnt>{}</span></div>".format(esc(m), 100 * n / tot, n)
            for m, n in sorted(c.items(), key=lambda kv: -kv[1])
        )
        chosen.append("<div class=col><h4>{}</h4>{}</div>".format(esc(POLICY_LABEL.get(k, k)), bars))

    return """
<section>
  <h2>1. 정책 비교 <span class=dim>(시드 {nseeds}개 x 정책 {npol}개 = {nruns} 런)</span></h2>
  <table class=grid>
    <thead><tr><th>정책</th><th>완주율</th><th>옳은 결정</th>
      <th>빌드 시간 (완주판, sim s)</th><th>J/closed</th><th>min SoC</th><th>남은 스페어</th></tr></thead>
    <tbody>{rows}</tbody>
  </table>

  <h3>종류별 적중</h3>
  <table class=grid>
    <thead><tr><th>정책</th><th>Battery</th><th>Fault</th><th>Zone</th></tr></thead>
    <tbody>{kinds}</tbody>
  </table>

  <h3>고른 매크로 분포</h3>
  <div class=cols>{chosen}</div>

  <p class=note><b>정답의 근거</b> — {basis}</p>
</section>""".format(
        rows="".join(rows), kinds="".join(kinds), chosen="".join(chosen),
        nseeds=len(seeds), npol=len(keys), nruns=d.get("n_runs", len(seeds) * len(keys)),
        basis=" · ".join("<b>{}</b>: {}".format(esc(k), esc(v)) for k, v in basis.items()),
    )


# ---------------------------------------------------------------- 결정 로그
def render_decisions(d):
    pols = d.get("policies", {})
    keys = [k for k in POLICY_ORDER if k in pols and pols[k].get("detail")]
    if not keys:
        return ""

    # `correct` 는 3상태다: true / false / **null**(= 그 사건 종류에 측정된 정답 격자가 없어
    # 채점에서 빠짐 — reference_policy 가 실측 격자 없는 사건에 None 을 낸다).
    # null 을 오답으로 칠하면 정확도가 실제보다 나빠 보인다.
    tabs, panes = [], []
    for i, k in enumerate(keys):
        det = pols[k]["detail"]
        scored = [e for e in det if e.get("correct") is not None]
        n_ok = sum(1 for e in scored if e["correct"])
        tabs.append("<button class='tab{}' data-pane='pane-{}'>{} <span class=dim>{}/{}</span></button>".format(
            " on" if i == 0 else "", k, esc(POLICY_LABEL.get(k, k)), n_ok, len(scored)))
        rows = "".join(
            "<tr class='{cls}'><td>{seed}</td><td>{at}</td><td>{truth}</td>"
            "<td><b>{chosen}</b></td><td>{ref}</td><td>{mark}</td><td class=note-cell>{note}</td></tr>".format(
                cls={True: "ok", False: "bad"}.get(e.get("correct"), "unscored"),
                seed=esc(e.get("ood_seed", "")), at=esc(e.get("at", "")),
                truth=esc(KIND_LABEL.get(e.get("truth"), e.get("truth", ""))),
                chosen=esc(e.get("chosen", "")),
                ref=esc(e["reference"]) if e.get("reference") else "<span class=dim>채점 제외</span>",
                mark={True: "○", False: "✗"}.get(e.get("correct"), "<span class=dim>—</span>"),
                note=esc(e.get("note", "")),
            )
            for e in det
        )
        panes.append(
            "<div class='pane{}' id='pane-{}'><table class=grid>"
            "<thead><tr><th>seed</th><th>closed</th><th>사건</th><th>고른 매크로</th>"
            "<th>정답</th><th></th><th>근거</th></tr></thead><tbody>{}</tbody></table></div>".format(
                "" if len(panes) else " on", k, rows))

    return """
<section>
  <h2>2. 결정 로그 <span class=dim>사건마다 무엇을 골랐고 정답은 무엇이었나</span></h2>
  <p class=note>탭의 숫자는 <b>채점된 사건만</b>의 적중이다. 회색 <b>—</b> 줄(실측 격자가 없어 unscored 인 사건)은
     측정된 정답 격자가 없어 분모에 들어가지 않는다 — 위 표의 &ldquo;옳은 결정&rdquo;과 같은 기준.</p>
  <div class=tabs>{tabs}</div>
  {panes}
</section>""".format(tabs="".join(tabs), panes="".join(panes))


# ---------------------------------------------------------------- 프레임 재생
def load_frames(path):
    frames = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                f = json.loads(line)
            except ValueError:
                continue  # 렌더가 남긴 깨진 마지막 줄
            for k in DROP_FRAME_KEYS:
                f.pop(k, None)
            for a in f.get("assemblies", []):
                for k in DROP_ASM_KEYS:
                    a.pop(k, None)
            frames.append(f)
    return frames


REPLAY_HTML = """
<section>
  <h2>3. 재생 <span class=dim id=srcName></span></h2>
  <div class=replay>
    <canvas id=view width=560 height=560></canvas>
    <div class=side>
      <div class=stat><span id=statT>t —</span><span id=statClosed>closed —</span></div>
      <h4>Fleet</h4><div id=fleet class=fleet></div>
      <h4>Assemblies</h4><div id=asm class=asm></div>
      <h4>OOD / 재명세</h4><div id=respec class=respec></div>
    </div>
  </div>
  <div class=controls>
    <button id=play>▶</button>
    <input id=scrub type=range min=0 value=0 step=1>
    <span id=pos class=dim></span>
  </div>
</section>
"""

REPLAY_JS = r"""
(function(){
  var F = window.__FRAMES__ || [];
  if(!F.length) return;
  var cv = document.getElementById('view'), cx = cv.getContext('2d');
  var scrub = document.getElementById('scrub'), i = 0, playing = false, timer = null;
  scrub.max = F.length - 1;
  document.getElementById('srcName').textContent = window.__STREAM_NAME__ + ' · ' + F.length + ' frames';

  // 모든 프레임의 로봇 위치로 화면 범위를 한 번만 잡는다(프레임마다 바뀌면 눈이 못 따라간다).
  var xs = [], ys = [];
  F.forEach(function(f){ (f.robots||[]).forEach(function(r){
    if(r.pos){ xs.push(r.pos[0]); ys.push(r.pos[1]); } }); });
  var pad = 0.6;
  var x0 = Math.min.apply(null, xs) - pad, x1 = Math.max.apply(null, xs) + pad;
  var y0 = Math.min.apply(null, ys) - pad, y1 = Math.max.apply(null, ys) + pad;
  var span = Math.max(x1 - x0, y1 - y0) || 1;
  function sx(x){ return (x - x0) / span * cv.width; }
  function sy(y){ return cv.height - (y - y0) / span * cv.height; }

  var MODE_COLOR = {CARRY:'#4ea1ff', GO:'#7bd88f', IDLE:'#6b7280', WAIT:'#c9a227'};
  function short(id){ var m = /\((\d+)\)\s*$/.exec(id || ''); return m ? m[1] : (id || ''); }

  function draw(){
    var f = F[i];
    cx.fillStyle = '#0f1116'; cx.fillRect(0, 0, cv.width, cv.height);
    cx.strokeStyle = '#1c2130';
    for(var g = 0; g <= 10; g++){
      var p = g / 10 * cv.width;
      cx.beginPath(); cx.moveTo(p, 0); cx.lineTo(p, cv.height); cx.stroke();
      cx.beginPath(); cx.moveTo(0, p); cx.lineTo(cv.width, p); cx.stroke();
    }
    (f.robots || []).forEach(function(r){
      if(!r.pos) return;
      var x = sx(r.pos[0]), y = sy(r.pos[1]);
      cx.beginPath(); cx.arc(x, y, r.retired ? 3.5 : 6, 0, 6.284);
      cx.fillStyle = r.depleted ? '#e2504a'
                   : r.retired ? '#3a4152'
                   : (MODE_COLOR[r.mode] || '#9aa4b2');
      cx.fill();
      if(r.replacement_for){            // 대체 투입 로봇 = 시안 링 (대시보드와 같은 약속)
        cx.strokeStyle = '#22d3ee'; cx.lineWidth = 2;
        cx.beginPath(); cx.arc(x, y, 9, 0, 6.284); cx.stroke(); cx.lineWidth = 1;
      }
      cx.fillStyle = '#7c8698'; cx.font = '9px ui-monospace,monospace';
      cx.fillText(short(r.id), x + 8, y - 7);
    });

    document.getElementById('statT').textContent = 't ' + f.t + '  (sim ' + (f.sim_t || 0).toFixed(1) + 's)';
    document.getElementById('statClosed').textContent = 'closed ' + f.n_closed + ' · active ' + f.n_active;

    var b = f.battery || {};
    document.getElementById('fleet').innerHTML =
      '<div class=kv>mean SoC<b>' + (b.mean_soc || 0).toFixed(3) + '</b></div>' +
      '<div class=kv>min SoC<b>' + (b.min_soc || 0).toFixed(3) + '</b></div>' +
      '<div class=kv>depleted<b>' + (b.n_depleted || 0) + '</b></div>' +
      (f.robots || []).filter(function(r){ return !r.retired; }).map(function(r){
        return '<div class=rb><span>' + short(r.id) + '</span>' +
               '<span class=soc><i style="width:' + (100 * (r.soc || 0)).toFixed(0) + '%"></i></span>' +
               '<span class=dim>' + (r.mode || '') + '</span></div>';
      }).join('');

    document.getElementById('asm').innerHTML = (f.assemblies || []).map(function(a){
      return '<div class=as style="margin-left:' + (a.level * 10) + 'px">' +
             '<span>' + short(a.id) + ' <span class=dim>' + a.role + '</span></span>' +
             '<span class=dim>' + a.build_steps_closed + '/' + a.build_steps_total + '</span></div>';
    }).join('');

    var hist = f.respec_history || [];
    document.getElementById('respec').innerHTML = hist.length
      ? hist.slice().reverse().map(function(e){
          var nl = (e.input && e.input.nl) || '';
          return '<div class=ev><b>@' + e.at + ' ' + e.chosen + '</b>' +
                 '<div class=dim>' + e.verdict + '</div>' +
                 '<div class=nl>' + nl + '</div></div>';
        }).join('')
      : '<div class=dim>아직 사건 없음</div>';

    document.getElementById('pos').textContent = (i + 1) + ' / ' + F.length;
    scrub.value = i;
  }

  scrub.addEventListener('input', function(){ i = +scrub.value; draw(); });
  document.getElementById('play').addEventListener('click', function(){
    playing = !playing;
    this.textContent = playing ? '❚❚' : '▶';
    if(playing){
      timer = setInterval(function(){
        i = (i + 1) % F.length; draw();
      }, 120);
    } else { clearInterval(timer); }
  });
  draw();
})();
"""

CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;padding:28px 32px 60px;background:#0b0d12;color:#d6dae2;
     font:14px/1.55 ui-sans-serif,system-ui,'Segoe UI',sans-serif}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:16px;margin:34px 0 10px;padding-bottom:6px;border-bottom:1px solid #232a38}
h3{font-size:13px;margin:22px 0 8px;color:#9aa4b2;text-transform:uppercase;letter-spacing:.06em}
h4{font-size:12px;margin:12px 0 6px;color:#9aa4b2}
.dim{color:#6b7484;font-weight:400}
.ci{color:#5a6373;font-size:11px}
.sub{color:#6b7484;margin:0 0 18px}
table.grid{border-collapse:collapse;width:100%;font-size:13px}
table.grid th,table.grid td{border:1px solid #232a38;padding:6px 9px;text-align:right}
table.grid thead th{background:#141924;color:#9aa4b2;font-weight:600;text-align:right}
table.grid tbody th{text-align:left;font-weight:600;background:#10141c}
tr.best td,tr.best th{background:#12211a}
tr.ok td{background:#0f1a14}
tr.bad td{background:#1e1315}
tr.unscored td{background:#0d1017;color:#5f6878}
td.note-cell{text-align:left;color:#8b95a6;font-size:12px}
.cols{display:flex;gap:20px;flex-wrap:wrap}
.col{flex:1 1 220px;min-width:220px}
.bar{position:relative;display:flex;align-items:center;gap:8px;margin:3px 0;
     background:#12161f;border-radius:3px;padding:3px 8px;overflow:hidden}
.bar .fill{position:absolute;left:0;top:0;bottom:0;background:#1d3a52;z-index:0}
.bar .lbl,.bar .cnt{position:relative;z-index:1;font-size:12px}
.bar .lbl{flex:1}
.bar .cnt{color:#9aa4b2}
.note{color:#7b8598;font-size:12px;margin-top:14px}
.tabs{display:flex;gap:6px;margin-bottom:10px;flex-wrap:wrap}
.tab{background:#141924;color:#9aa4b2;border:1px solid #232a38;border-radius:4px;
     padding:5px 11px;font-size:12px;cursor:pointer}
.tab.on{background:#1d2740;color:#e8ecf3;border-color:#2f3d5c}
.pane{display:none}.pane.on{display:block}
.replay{display:flex;gap:18px;flex-wrap:wrap}
#view{background:#0f1116;border:1px solid #232a38;border-radius:6px}
.side{flex:1 1 320px;min-width:300px;max-height:560px;overflow:auto}
.stat{display:flex;gap:14px;font:12px ui-monospace,monospace;color:#9aa4b2}
.kv{display:flex;justify-content:space-between;font-size:12px;color:#8b95a6}
.rb{display:grid;grid-template-columns:34px 1fr 60px;gap:8px;align-items:center;
    font:11px ui-monospace,monospace;color:#8b95a6}
.soc{display:block;height:6px;background:#1a2030;border-radius:3px;overflow:hidden}
.soc i{display:block;height:100%;background:#4ea1ff}
.as{display:flex;justify-content:space-between;font-size:12px;padding:1px 0}
.ev{border-left:2px solid #2f3d5c;padding:2px 0 6px 8px;margin:6px 0;font-size:12px}
.nl{color:#8b95a6;font-size:11px;margin-top:2px}
.controls{display:flex;align-items:center;gap:12px;margin-top:10px}
.controls button{background:#1d2740;color:#e8ecf3;border:1px solid #2f3d5c;
                 border-radius:4px;padding:4px 12px;cursor:pointer}
#scrub{flex:1}
"""

PAGE = """<!doctype html>
<html lang=ko><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title><style>{css}</style></head>
<body>
<h1>{title}</h1>
<p class=sub>{sub}</p>
{results}
{decisions}
{replay}
<script>window.__FRAMES__={frames};window.__STREAM_NAME__={stream_name};</script>
<script>
document.querySelectorAll('.tab').forEach(function(t){{
  t.addEventListener('click', function(){{
    document.querySelectorAll('.tab').forEach(function(x){{ x.classList.remove('on'); }});
    document.querySelectorAll('.pane').forEach(function(x){{ x.classList.remove('on'); }});
    t.classList.add('on');
    document.getElementById(t.dataset.pane).classList.add('on');
  }});
}});
{replay_js}
</script>
</body></html>
"""


def main():
    ap = argparse.ArgumentParser(description="artifacts_llm7h -> 자립형 HTML")
    ap.add_argument("--results", help="final.json")
    ap.add_argument("--stream", help="monitor 포맷 *_stream.jsonl")
    ap.add_argument("--out", required=True, help="쓸 HTML 경로")
    ap.add_argument("--title", default="ConstructionBots — LLM/서로게이트 OOD 대응 결과")
    args = ap.parse_args()

    if not args.results and not args.stream:
        ap.error("--results 나 --stream 중 하나는 있어야 한다")

    results_html = decisions_html = ""
    sub = []
    if args.results:
        d = json.load(open(args.results, encoding="utf-8"))
        results_html = render_results(d)
        decisions_html = render_decisions(d)
        sub.append("집계 {} (시드 {})".format(
            esc(pathlib.Path(args.results).name), ", ".join(map(str, d.get("seeds", [])))))

    frames, stream_name = [], ""
    replay_html = replay_js = ""
    if args.stream:
        frames = load_frames(args.stream)
        stream_name = pathlib.Path(args.stream).name
        replay_html, replay_js = REPLAY_HTML, REPLAY_JS
        sub.append("재생 {} ({} 프레임)".format(esc(stream_name), len(frames)))

    page = PAGE.format(
        title=esc(args.title),
        css=CSS,
        sub=" · ".join(sub),
        results=results_html,
        decisions=decisions_html,
        replay=replay_html,
        frames=json.dumps(frames, ensure_ascii=False, separators=(",", ":")),
        stream_name=json.dumps(stream_name, ensure_ascii=False),
        replay_js=replay_js,
    )
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    print("[html] {}  ({:.1f} MB)".format(out, out.stat().st_size / 1e6))


if __name__ == "__main__":
    main()
