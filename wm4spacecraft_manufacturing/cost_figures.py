#!/usr/bin/env python
"""Render the cost-of-adaptation figures from cost_eval_metrics.json into results/cost/."""
# =============================================================================
# [한국어 안내] cost_figures.py 는 무엇을 하는 파일인가
# -----------------------------------------------------------------------------
# 목적:
#   "적응 비용(cost of adaptation)" 실험 결과(cost_eval_metrics.json)를 읽어,
#   4개의 그림(PNG)을 그려 results/cost/ 폴더에 저장한다. 다섯 가지 OOD 대응
#   정책(Oracle / LLM->solver / LLM-only / Surrogate->verify-1 / Surrogate-only)을
#   지연시간(latency)·decision regret·완주율(completion)·비용회수(break-even)로 비교한다.
#
#   그리는 그림:
#     fig1_frontier          : latency(로그축) vs regret 산점도 = cost-quality frontier
#     fig2_perbuild          : OOD 이벤트 스트림 1빌드 전체의 결정 소요시간 막대
#     fig3_latency_accuracy  : 왼쪽=latency 막대, 오른쪽=regret/완주율 막대 (나란히)
#     fig4_breakeven         : surrogate 초기 학습비용이 몇 번의 결정 후 회수되는지 곡선
#
# 프로젝트에서의 역할:
#   숫자(JSON)만 있는 실험 결과를 사람이 보는 발표용 그림으로 렌더링하는 단계.
#   같은 JSON 을 build_artifact.py 가 이 PNG 들과 합쳐 HTML 리포트를 만든다.
#
# 실행 방법:
#   python cost_figures.py [metrics.json] [하위폴더명]
#     인자 없으면 metrics.json=cost_eval_metrics.json, 하위폴더=cost 로 기본 사용.
#   결과: results/cost/fig1..fig4.png 저장.
#
# ── 문법 참고 (처음 보는 Python 문법 힌트) ──────────────────────────────────
#   * matplotlib.use("Agg"): 화면 없이(백엔드) 파일로만 그림을 저장하는 모드.
#       반드시 pyplot 을 import 하기 "전에" 호출해야 한다.
#   * plt.subplots(): (figure, axes) 쌍을 만든다. ax.scatter/bar/plot 로 그리고
#       fig.savefig(경로) 로 저장, plt.close(fig) 로 메모리 정리.
#   * sys.argv: 커맨드라인 인자 리스트. sys.argv[0]=파일명, [1],[2]=사용자 인자.
#   * A if 조건 else B : 삼항표현식(한 줄 if-else). 인자 유무에 따라 기본값 선택.
#   * json.load(open(경로)): JSON 파일을 파이썬 dict 로 읽어들인다(M).
#   * dict comprehension {k: v for ...}, list comprehension [f(x) for x in ...]:
#       기존 자료로 새 딕셔너리/리스트를 즉석에서 만드는 축약 문법.
#   * zip(a, b): 두 리스트를 짝지어 (a0,b0),(a1,b1)... 로 순회.
#   * enumerate(리스트): (인덱스, 값) 쌍으로 순회.
#   * f-string 포맷: f"{v*1e3:.1f} ms" = 초→밀리초 환산 후 소수1자리,
#       f"{c:.0%}" = 비율(0~1)을 퍼센트로 (예: 0.75 → "75%").
#   * ax.annotate(text, xy, xytext=..., textcoords="offset points"): 특정 점 옆에
#       글자/화살표를 붙인다. offset 은 점으로부터의 픽셀 이동량.
# =============================================================================
import os, sys, json
import numpy as np
import matplotlib
matplotlib.use("Agg")            # 화면 없이 PNG 파일로만 저장하는 백엔드 (pyplot import 전에 필수)
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))   # 이 스크립트가 있는 폴더의 절대경로
# 첫 번째 인자=metrics JSON 경로 (없으면 기본 파일), 두 번째 인자=결과 하위폴더명
METRICS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "cost_eval_metrics.json")
SUBDIR = sys.argv[2] if len(sys.argv) > 2 else "cost"
M = json.load(open(METRICS))     # 실험 결과 전체를 dict 로 로드 (이하 M[...] 로 접근)
OUT = os.path.join(HERE, "results", SUBDIR); os.makedirs(OUT, exist_ok=True)  # 출력폴더 준비(없으면 생성)

# 모든 그림 공통 스타일(글자크기/해상도/격자 등)을 한 번에 설정
plt.rcParams.update({"font.size": 11, "figure.dpi": 130, "axes.grid": True,
                     "grid.alpha": 0.25, "axes.axisbelow": True})
# 정책 이름 → 그래프에서 쓸 색상(HEX) 대응표
COL = {"Oracle (verify all 5)": "#444", "LLM->solver (verify C=3)": "#c0392b",
       "LLM-only planner (no verify)": "#e67e22", "Surrogate->verify-1": "#2980b9",
       "Surrogate-only (k=0, ours)": "#27ae60"}
# 정책 이름 → 축에 표기할 짧은 라벨(\n=줄바꿈)
SHORT = {"Oracle (verify all 5)": "Oracle\n(verify 5)", "LLM->solver (verify C=3)": "LLM→solver\n(verify 3)",
         "LLM-only planner (no verify)": "LLM-only\n(no verify)", "Surrogate->verify-1": "Surrogate\n→verify-1",
         "Surrogate-only (k=0, ours)": "Surrogate-only\n(ours)"}
pd_ = M["per_decision"]          # 정책별 "결정 1회당" 지표(latency/regret/completion) 묶음

# ---- Fig 1: cost–quality frontier (latency vs regret), real units --------------------------------
# 그림1: x=latency(로그축, 왼쪽일수록 쌈), y=regret(아래일수록 좋음) 산점도로 frontier 를 보인다
fig, ax = plt.subplots(figsize=(7.6, 5.2))
# explicit label placement (dx_pts, dy_pts, ha) to avoid overlap of the two bottom-right points
# 라벨이 겹치지 않게 점마다 (가로이동, 세로이동, 정렬)을 손으로 지정
LABPOS = {
    "Oracle (verify all 5)": (8, 26, "left"),
    "LLM->solver (verify C=3)": (-8, -26, "right"),
    "LLM-only planner (no verify)": (0, 22, "center"),
    "Surrogate->verify-1": (0, 24, "center"),
    "Surrogate-only (k=0, ours)": (14, -20, "left"),
}
for name, d in pd_.items():                      # 정책마다 점 하나씩 찍기
    x = max(d["latency_s"], 3e-5)                # 로그축이라 0 방지: 하한 3e-5초로 클램프
    ax.scatter(x, d["regret"], s=260, color=COL[name], zorder=3, edgecolor="white", linewidth=1.5)
    dx, dy, ha = LABPOS[name]                    # 이 점의 라벨 오프셋/정렬 꺼내기
    ax.annotate(name.replace(" (", "\n("), (x, d["regret"]),   # 괄호 앞에서 줄바꿈해 라벨 표기
                xytext=(dx, dy), textcoords="offset points",
                ha=ha, va="center", fontsize=9.5, color=COL[name], fontweight="bold")
ax.set_xscale("log")                             # x축을 로그 스케일로 (수십 μs~수십 초 범위 표현)
ax.set_xlabel("planning latency per decision  (seconds, log scale)  ← cheaper")
ax.set_ylabel("decision regret  ← better")
ax.set_title("Cost–quality frontier of adaptation policies (real units)\n"
             f"T_sim measured median {M['T_sim']['median']:.0f}s · T_llm {M['T_llm_s']:.1f}s ({M['llm_source'].split('(')[0].strip()})",
             fontsize=11.5)
ax.axhline(0, color="#888", lw=0.8, ls="--")     # regret=0 (완벽) 기준선
# dominance arrow
# surrogate 점을 가리키는 화살표+설명 (xytext 는 축비율 좌표 0~1 로 지정)
ax.annotate("surrogate dominates:\nnothing is both cheaper AND more accurate",
            xy=(pd_["Surrogate-only (k=0, ours)"]["latency_s"], pd_["Surrogate-only (k=0, ours)"]["regret"]),
            xytext=(0.02, 0.62), textcoords="axes fraction", fontsize=9.5, color="#27ae60",
            arrowprops=dict(arrowstyle="->", color="#27ae60", lw=1.4))
ax.set_ylim(-0.08, 0.82)
# tight_layout=여백 자동정리, savefig=PNG 저장, close=메모리 해제 (그림마다 반복되는 3콤보)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig1_frontier.png")); plt.close(fig)

# ---- Fig 2: per-build adaptation time over the OOD stream -----------------------------------------
# 그림2: OOD 이벤트가 연속으로 터지는 1빌드 동안 각 정책이 "결정"에 쓰는 총 시간(막대)
fig, ax = plt.subplots(figsize=(7.8, 4.6))
names = list(pd_.keys())                          # 정책 이름 목록
tot = [M["per_build"][n]["total_s"] for n in names]   # 정책별 빌드 전체 결정 소요초
bars = ax.bar([SHORT[n] for n in names], tot, color=[COL[n] for n in names], zorder=3,
              edgecolor="white", linewidth=1.2)
ax.set_yscale("log")                              # 값 편차가 크므로 y축 로그
ax.set_ylabel("total decide-time per build  (s, log)")
D = len(M["stream"])                              # OOD 이벤트 스트림 길이(이벤트 개수)
ax.set_title(f"Whole-build adaptation time over a {D}-event OOD stream\nstream = {M['stream']}", fontsize=11.5)
for b, n in zip(bars, names):                     # 막대마다 값+완주여부 라벨 붙이기
    v = M["per_build"][n]["total_s"]
    # 크기에 맞춰 단위 자동선택: 1초 미만→ms, 90초 미만→s, 그 이상→분
    lab = f"{v*1e3:.1f} ms" if v < 1 else (f"{v:.0f} s" if v < 90 else f"{v/60:.1f} min")
    comp = pd_[n]["completion"]
    # 완주율 거의 100%면 ✓, 아니면 ✗ 로 표시
    ax.annotate(f"{lab}\n{'✓' if comp >= 0.999 else '✗'} {comp:.0%} complete",
                (b.get_x() + b.get_width() / 2, v), xytext=(0, 4), textcoords="offset points",
                ha="center", va="bottom", fontsize=8.6)
ax.set_ylim(top=max(tot) * 6)                     # 라벨이 잘리지 않게 위 여백 확보
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig2_perbuild.png")); plt.close(fig)

# ---- Fig 3: latency speed-up + accuracy bars (twin) ----------------------------------------------
# 그림3: 한 figure 에 가로막대 2개 나란히 — 왼쪽(a1)=latency, 오른쪽(a2)=regret+완주율
fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.4))
order = ["Oracle (verify all 5)", "LLM->solver (verify C=3)", "LLM-only planner (no verify)",
         "Surrogate->verify-1", "Surrogate-only (k=0, ours)"]   # 막대 표시 순서 고정
lat = [pd_[n]["latency_s"] for n in order]        # 정책별 결정 1회 latency
a1.barh([SHORT[n].replace("\n", " ") for n in order], lat, color=[COL[n] for n in order], zorder=3)  # 가로막대
a1.set_xscale("log"); a1.set_xlabel("latency / decision (s, log)")
a1.set_title("Planning latency (measured T_sim, T_surr; live T_llm)")
for i, v in enumerate(lat):                       # 막대 끝에 값 라벨 (1초 미만은 ms)
    a1.annotate(f"{v*1e3:.1f} ms" if v < 1 else f"{v:.0f} s", (v, i), xytext=(4, 0),
                textcoords="offset points", va="center", fontsize=8.5)
reg = [pd_[n]["regret"] for n in order]           # 정책별 regret
comp = [pd_[n]["completion"] for n in order]      # 정책별 완주율
a2.barh([SHORT[n].replace("\n", " ") for n in order], reg, color=[COL[n] for n in order], zorder=3)
a2.set_xlabel("decision regret (cost-aware, LOO)  ← better")
a2.set_title("Decision quality + completion")
for i, (r, c) in enumerate(zip(reg, comp)):       # 막대 끝에 regret+완주율 함께 표기
    a2.annotate(f"regret {r:.2f} · {c:.0%} complete", (r, i), xytext=(4, 0),
                textcoords="offset points", va="center", fontsize=8.5)
a2.set_xlim(0, max(reg) * 2.1 + 0.05)             # 라벨 공간 위해 x축 오른쪽 여유
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig3_latency_accuracy.png")); plt.close(fig)

# ---- Fig 4: break-even curve vs LLM->solver ------------------------------------------------------
# 그림4: surrogate 의 1회성 학습비용이 결정 누적에 따라 LLM->solver 대비 언제 회수되는지
fig, ax = plt.subplots(figsize=(7.2, 4.4))
be = M["breakeven_decisions"]                     # 손익분기(break-even) 결정 횟수
saved = pd_["LLM->solver (verify C=3)"]["latency_s"] - pd_["Surrogate-only (k=0, ours)"]["latency_s"]  # 결정당 절약시간
train = M["breakeven_train_hours"] * 3600         # surrogate 초기 학습비용을 초 단위로 환산
n = np.arange(0, int(be * 2.2))                   # x축: 0 ~ 손익분기의 2.2배까지 결정 횟수 배열
sur_cum = train + n * pd_["Surrogate-only (k=0, ours)"]["latency_s"]  # surrogate 누적비용=학습비+결정비×n
llm_cum = n * pd_["LLM->solver (verify C=3)"]["latency_s"]            # LLM->solver 누적비용=결정비×n
ax.plot(n, sur_cum / 3600, color="#27ae60", lw=2.2, label="surrogate (one-time data-gen, then ~free)")  # 초→시간
ax.plot(n, llm_cum / 3600, color="#c0392b", lw=2.2, label="LLM→solver (verify every decision)")
ax.axvline(be, color="#888", ls="--", lw=1)       # 손익분기 지점에 세로 점선
ax.annotate(f"break-even\n≈ {be:.0f} decisions\n(~{be/len(M['stream']):.0f} builds)", (be, train/3600),
            xytext=(10, 10), textcoords="offset points", fontsize=9.5, color="#555")
ax.set_xlabel("# OOD decision events (cumulative)")
ax.set_ylabel("cumulative wall-clock cost (hours)")
ax.set_title("Break-even: one-time surrogate cost repaid by per-decision savings")
ax.legend(fontsize=9.5, loc="upper left")         # 범례를 왼쪽 위에
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig4_breakeven.png")); plt.close(fig)

print("wrote figures to", OUT)
for f in ("fig1_frontier", "fig2_perbuild", "fig3_latency_accuracy", "fig4_breakeven"):  # 저장한 파일명 출력
    print("  ", f + ".png")
