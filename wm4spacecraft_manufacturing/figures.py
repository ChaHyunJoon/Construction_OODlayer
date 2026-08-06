#!/usr/bin/env python
"""
figures.py -- 지도교수 체크리스트의 "error or distribution plots" + "success metrics ±SE" 산출물.

지금까지 이 저장소의 결과물은 전부 텍스트 표였다. 표는 "완주율 33% vs 0%" 같은 큰 차이는 보여주지만
**분포와 불확실성**을 못 보여준다 — n=4 에서 나온 0.25 와 n=40 에서 나온 0.25 가 표에서는 똑같이 보인다.
이 스크립트가 만드는 세 그림은 각각 하나의 질문에 답한다.

  F1  완주율 ±SE          : "성공률"을 지표로 쓸 수 있는가 (분모가 살아 있는가)
  F2  정책별 regret 분포   : 평균이 아니라 **퍼짐**을 본다 (평균만 보면 꼬리를 놓친다)
  F3  심각도 사다리        : NOOP 곡선과 개입 곡선이 **교차**하는가 = 진짜 결정 경계가 있는가

모델을 학습시키지 않는다. 여기 나오는 정책은 전부 데이터만으로 계산되는 baseline 이다
(oracle / noop_always / intervene_always / always_per_kind / random). 서로게이트 비교는
e1_analyze.py 의 몫이고, 이 그림들은 "과제가 애초에 잴 만한가"를 먼저 묻는 도구다.

실행:
  python figures.py                      # 기본 데이터셋 묶음
  python figures.py --out figs           # 저장 폴더 지정
  python figures.py --add "새것=oracle/out/nom30/ep_s*.jsonl"
"""
import os, sys, glob, json, math, argparse, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from e1_analyze import MACRO_COST, MACRO_NAME

LAM = 3.0   # 개입 비용의 환산 가중치(e1_analyze / export_surrogate 와 같은 값)

# --- 색: dataviz 스킬의 검증된 참조 팔레트(light)에서 **고정 순서로** 슬롯을 가져온다. -------------
# 순서를 돌려쓰지 않는다(정책이 늘어도 8번째 색을 만들어내지 않는다). 텍스트는 절대 계열색을 입지
# 않고 잉크색만 쓴다 — 색은 마크가 지고, 글자는 읽히기만 하면 된다.
# (node 가 없어 validate_palette.js 를 재실행하지 못했다. 참조 팔레트는 이미 검증된 인스턴스이고
#  인접 슬롯을 순서대로 쓰는 것이 그 검증이 커버하는 사용법이라 그대로 쓴다.)
C = {
    "s1": "#2a78d6",   # blue
    "s2": "#eb6834",   # orange
    "s3": "#1baf7a",   # aqua
    "s4": "#eda100",   # yellow
    "s7": "#4a3aa7",   # violet
}
INK      = "#0b0b0b"
INK_SOFT = "#52514e"
INK_MUTE = "#8b8a85"
GRID     = "#e3e2de"
SURFACE  = "#fcfcfb"

# 한글 폰트. matplotlib 기본 DejaVu Sans 에는 한글 글리프가 없어서 라벨이 전부 두부(□)로 나온다 —
# 렌더 결과를 눈으로 확인하지 않으면 그냥 통과해버리는 종류의 결함이라 여기서 명시적으로 잡는다.
def _pick_korean_font():
    import matplotlib.font_manager as fm
    for cand in ("Malgun Gothic", "Gulim", "Batang", "NanumGothic", "Noto Sans KR"):
        try:
            fm.findfont(fm.FontProperties(family=cand), fallback_to_default=False)
            return cand
        except Exception:
            continue
    return None


_KO = _pick_korean_font()
if _KO:
    plt.rcParams["font.family"] = _KO
    plt.rcParams["axes.unicode_minus"] = False   # 한글 폰트의 U+2212 누락으로 음수 부호가 깨지는 것 방지
else:
    print("  [warn] 한글 폰트를 못 찾음 — 라벨이 깨질 수 있다")

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "text.color": INK, "axes.labelcolor": INK_SOFT, "axes.edgecolor": GRID,
    "xtick.color": INK_SOFT, "ytick.color": INK_SOFT,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "axes.titlesize": 12, "axes.titleweight": "bold",
    "grid.color": GRID, "grid.linewidth": 0.8,
})


# ==========================================================================================
#  데이터
# ==========================================================================================
def load(patterns):
    rows = []
    for pat in patterns:
        for f in glob.glob(pat):
            if ".probes." in os.path.basename(f):
                continue
            # instance id(예: ep_s401_M1_t1)는 **심각도를 인코딩하지 않는다**. 그래서 lad_batt0.05 /
            # lad_batt0.12 / lad_batt0.35 의 같은 seed 가 전부 같은 id 를 갖는다 — 폴더를 합쳐 읽으면
            # 세 칸이 **한 instance 로 병합**되어 사다리가 통째로 사라진다(2026-08-04 실측: 배터리
            # 12 instance -> 4). 그래서 출처 폴더를 행에 찍어 두고 그룹 키에 포함시킨다.
            src = os.path.basename(os.path.dirname(os.path.abspath(f)))
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        r = json.loads(line)
                        r["_src"] = src
                        rows.append(r)
                    except json.JSONDecodeError:
                        pass
    return rows


def _f(v, d=float("nan")):
    if isinstance(v, str):
        if v in ("Inf", "inf"):
            return float("inf")
        if v in ("NaN", "nan"):
            return float("nan")
        try:
            return float(v)
        except ValueError:
            return d
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def value(r, lam=LAM):
    """비용 반영 스칼라 값(클수록 좋음). 완주가 최우선이고 그 안에서 closed, 개입비용 순."""
    comp = 1e6 if bool(r.get("complete")) else 0.0
    return comp + float(r.get("closed", 0)) - lam * MACRO_COST.get(int(r.get("macro", 0)), 0.0)


def by_instance(rows, fired_only=True):
    g = collections.defaultdict(dict)
    for r in rows:
        if fired_only and not r.get("fired", True):
            continue
        g[(r.get("_src", ""), r["instance"])][int(r["macro"])] = r
    return {k: v for k, v in g.items() if len(v) >= 2}


def se_prop(k, n):
    """비율의 표준오차. n=0 이면 nan."""
    if n == 0:
        return float("nan")
    p = k / n
    return math.sqrt(max(p * (1 - p), 0.0) / n)


# ==========================================================================================
#  F1 -- 완주율 ±SE
# ==========================================================================================
def fig_completion(datasets, out):
    """조건별 완주율. 이게 0 이면 '성공률'도 '완주확률 2층 분해'도 지표가 될 수 없다."""
    labels, rate, err, ns = [], [], [], []
    for name, pat in datasets:
        rows = load(pat if isinstance(pat, list) else [pat])
        rows = [r for r in rows if r.get("closed") is not None]
        if not rows:
            continue
        k = sum(1 for r in rows if r.get("complete"))
        n = len(rows)
        labels.append(name); rate.append(100.0 * k / n); err.append(100.0 * se_prop(k, n)); ns.append(n)
    if not labels:
        print("  F1 건너뜀 (데이터 없음)")
        return

    # 형태: 점 + 오차막대(가로). 비율 + 불확실성에는 막대보다 점이 정직하다 —
    # 막대는 0 에서 시작하는 면적을 강조해 SE 를 시각적으로 뭉갠다.
    h = 0.62 * len(labels) + 1.9
    fig, ax = plt.subplots(figsize=(8.2, h))
    y = np.arange(len(labels))[::-1]
    ax.errorbar(rate, y, xerr=err, fmt="o", markersize=9, linewidth=2, capsize=5,
                color=C["s1"], ecolor=C["s1"], markeredgecolor=SURFACE, markeredgewidth=2)
    for yi, v, e, n in zip(y, rate, err, ns):
        ax.annotate(f"{v:.0f}% ± {e:.0f}   (n={n})", (v, yi), textcoords="offset points",
                    xytext=(14, 0), va="center", fontsize=9, color=INK_SOFT)
    ax.set_yticks(y); ax.set_yticklabels(labels)
    ax.set_xlim(-4, 150); ax.set_xlabel("완주율 (%)  ·  오차막대 = ±1 SE")
    ax.set_title("F1  조건별 완주율 — [버그]=shim 자가복구 무효 시기, [수정후]=2026-08-04 이후")
    ax.xaxis.grid(True); ax.set_axisbelow(True); ax.yaxis.grid(False)
    fig.tight_layout(); p = os.path.join(out, "F1_completion.png")
    fig.savefig(p, dpi=160); plt.close(fig); print(f"  wrote {p}")


# ==========================================================================================
#  F2 -- 정책별 regret 분포
# ==========================================================================================
def policy_picks(arms, kind):
    """모델 없이 계산되는 baseline 정책들. 각 정책이 이 instance 에서 고를 매크로."""
    ms = sorted(arms)
    interv = [m for m in ms if m != 0]
    # 종류만 보고 정해진 대응(규칙표). zone 계열은 팔 7 우선, 없으면 3.
    rule = {"fault": [1], "battery": [1, 2], "zoneblk": [7, 3], "zonecore": [7, 3]}.get(str(kind), [])
    per_kind = next((m for m in rule if m in arms), (interv[0] if interv else 0))
    return {
        "oracle":           None,                       # 아래에서 best 로 채움
        "always_per_kind":  per_kind,
        "intervene_always": interv[0] if interv else 0,
        "noop_always":      0 if 0 in arms else ms[0],
    }


def regrets(rows):
    """instance 별 정규화 regret(0=최선, 1=최악)을 정책별로 모은다."""
    g = by_instance(rows)
    out = collections.defaultdict(list)
    for inst, arms in g.items():
        vals = {m: value(r) for m, r in arms.items()}
        vbest, vworst = max(vals.values()), min(vals.values())
        spread = vbest - vworst
        if spread <= 0:
            continue                                   # 동점 instance 는 어떤 정책도 손해 0 -> 정보 없음
        kind = str(next(iter(arms.values())).get("kind"))
        picks = policy_picks(set(arms), kind)
        picks["oracle"] = max(vals, key=lambda m: vals[m])
        for pol, m in picks.items():
            out[pol].append((vbest - vals[m]) / spread)
    return out


def fig_regret_dist(rows, out, title_suffix=""):
    reg = regrets(rows)
    if not reg:
        print("  F2 건너뜀 (결정적 instance 없음)")
        return
    order = ["oracle", "always_per_kind", "intervene_always", "noop_always"]
    order = [p for p in order if p in reg]
    col = {"oracle": C["s3"], "always_per_kind": C["s1"],
           "intervene_always": C["s2"], "noop_always": C["s7"]}

    fig, ax = plt.subplots(figsize=(8.6, 0.85 * len(order) + 2.2))
    rng = np.random.default_rng(0)
    for i, pol in enumerate(order):
        y0 = len(order) - 1 - i
        v = np.asarray(reg[pol], dtype=float)
        # 개별 점을 다 찍는다 — 평균만 보면 "대부분 0인데 몇 개가 1" 같은 꼬리를 놓친다.
        jit = (rng.random(len(v)) - 0.5) * 0.26
        ax.scatter(v, y0 + jit, s=42, color=col[pol], alpha=0.55,
                   edgecolor=SURFACE, linewidth=1.2, zorder=3)
        m, s = v.mean(), (v.std(ddof=1) / math.sqrt(len(v)) if len(v) > 1 else 0.0)
        ax.errorbar([m], [y0], xerr=[s], fmt="D", markersize=8, color=INK,
                    ecolor=INK, capsize=5, linewidth=2, zorder=4,
                    markeredgecolor=SURFACE, markeredgewidth=1.5)
        ax.annotate(f"mean {m:.2f} ± {s:.2f}   n={len(v)}", (1.02, y0),
                    xycoords=("axes fraction", "data"), va="center",
                    fontsize=9, color=INK_SOFT)
    ax.set_yticks(range(len(order))[::-1]); ax.set_yticklabels(order)
    ax.set_xlim(-0.06, 1.06); ax.set_xlabel("정규화 regret  (0 = 그 상황의 최선, 1 = 최악)")
    ax.set_title(f"F2  정책별 regret 분포 — 점 하나가 결정 하나{title_suffix}")
    ax.xaxis.grid(True); ax.set_axisbelow(True); ax.yaxis.grid(False)
    fig.subplots_adjust(right=0.72)
    p = os.path.join(out, "F2_regret_dist.png")
    fig.savefig(p, dpi=160, bbox_inches="tight"); plt.close(fig); print(f"  wrote {p}")


# ==========================================================================================
#  F3 -- 심각도 사다리 (곡선이 교차하는가)
# ==========================================================================================
SEVERITY_AXIS = {
    # kind -> (열 이름, 라벨, 낮을수록 심각한가)
    "battery": ("soc", "SoC (낮을수록 심각)", True),
    "fault":   ("agent_pending", "대상 로봇의 잔여 작업 (높을수록 심각)", False),
    "zoneblk": ("zone_overlap", "구역이 덮은 적치 비율 (높을수록 심각)", False),
}


def fig_ladder(rows, out, kind):
    """한 kind 안에서 심각도를 따라 NOOP 과 '개입'의 regret 이 교차하는지.

    교차하면 그 kind 는 상태를 읽어야 풀리는 문제다(= 규칙표로는 못 이긴다).
    한쪽이 계속 아래에 있으면 kind 이름만으로 답이 정해지는 trivial 한 종류다.
    """
    axis = SEVERITY_AXIS.get(kind)
    if axis is None:
        return
    col, xlabel, invert = axis
    g = by_instance([r for r in rows if str(r.get("kind")) == kind])
    pts = []
    for inst, arms in g.items():
        vals = {m: value(r) for m, r in arms.items()}
        vbest, vworst = max(vals.values()), min(vals.values())
        if vbest - vworst <= 0:
            continue
        sev = _f(next(iter(arms.values())).get(col))
        if not math.isfinite(sev):
            continue
        # 개입 쪽 곡선은 **고정 규칙이 고르는 팔 하나**여야 한다.
        # min(모든 개입 팔) 로 잡으면 그건 '개입 안에서의 oracle' 이라 NOOP 에 거의 안 지고,
        # 그 결과 곡선이 영원히 교차하지 않는다(2026-08-03 첫 버전이 세 kind 모두 교차=False 로
        # 나온 이유). sweep_lab/ladder_report.txt 도 NOOP vs Replace 처럼 **특정 팔**로 비교한다.
        kind_s = str(next(iter(arms.values())).get("kind"))
        pick = policy_picks(set(arms), kind_s)["always_per_kind"]
        if 0 not in arms or pick == 0 or pick not in vals:
            continue
        r_noop = (vbest - vals[0]) / (vbest - vworst)
        r_int = (vbest - vals[pick]) / (vbest - vworst)
        pts.append((sev, r_noop, r_int))
    if len(pts) < 3:
        print(f"  F3[{kind}] 건너뜀 (결정적 instance {len(pts)}개 — 3개 미만)")
        return
    pts.sort(key=lambda t: t[0], reverse=invert)
    sev = np.array([p[0] for p in pts]); rn = np.array([p[1] for p in pts]); ri = np.array([p[2] for p in pts])

    # 3칸으로 나눠 평균±SE. 칸이 아니라 원자료도 같이 찍어 표본이 얼마나 얇은지 숨기지 않는다.
    nb = min(3, max(1, len(pts) // 2))
    edges = np.array_split(np.arange(len(pts)), nb)
    xs, mn, sn, mi, si = [], [], [], [], []
    for idx in edges:
        if len(idx) == 0:
            continue
        xs.append(sev[idx].mean())
        mn.append(rn[idx].mean()); sn.append(rn[idx].std(ddof=1) / math.sqrt(len(idx)) if len(idx) > 1 else 0.0)
        mi.append(ri[idx].mean()); si.append(ri[idx].std(ddof=1) / math.sqrt(len(idx)) if len(idx) > 1 else 0.0)

    fig, ax = plt.subplots(figsize=(7.4, 4.6))
    ax.scatter(sev, rn, s=34, color=C["s7"], alpha=0.30, edgecolor="none", zorder=2)
    ax.scatter(sev, ri, s=34, color=C["s2"], alpha=0.30, edgecolor="none", zorder=2)
    ax.errorbar(xs, mn, yerr=sn, color=C["s7"], linewidth=2, marker="o", markersize=9,
                capsize=5, zorder=4, markeredgecolor=SURFACE, markeredgewidth=2, label="가만히 둔다 (NOOP)")
    ax.errorbar(xs, mi, yerr=si, color=C["s2"], linewidth=2, marker="s", markersize=9,
                capsize=5, zorder=4, markeredgecolor=SURFACE, markeredgewidth=2, label="종류별 고정 규칙으로 개입")
    # 계열이 2개뿐이라 범례 + 직접 라벨 둘 다 준다(색만으로 정체를 알게 하지 않는다).
    ax.annotate("NOOP", (xs[-1], mn[-1]), textcoords="offset points", xytext=(8, 0),
                color=INK_SOFT, fontsize=9, va="center")
    ax.annotate("개입", (xs[-1], mi[-1]), textcoords="offset points", xytext=(8, 0),
                color=INK_SOFT, fontsize=9, va="center")
    if invert:
        ax.invert_xaxis()
    ax.set_xlabel(xlabel); ax.set_ylabel("정규화 regret (낮을수록 좋음)")
    # 교차 판정은 **양 끝만** 보면 안 된다. fault 처럼 가운데 칸에서만 뒤집히는 경우를 놓친다
    # (2026-08-03 실측: 0.389/0.611 -> 0.550/0.444 -> 0.389/0.611 = 가운데만 역전).
    # 그래서 이웃한 칸 사이 부호 변화가 한 번이라도 있으면 교차로 본다.
    diff = [a - b for a, b in zip(mn, mi)]
    crossed = any(diff[i] * diff[i + 1] < 0 for i in range(len(diff) - 1))
    ax.set_title(f"F3  심각도 사다리 — kind={kind}   "
                 + ("곡선 교차 O = 진짜 결정 경계" if crossed else "곡선 교차 X = 한쪽이 계속 유리"))
    ax.set_ylim(-0.06, 1.06); ax.yaxis.grid(True); ax.set_axisbelow(True)
    ax.legend(frameon=False, loc="center left", fontsize=9, labelcolor=INK_SOFT)
    fig.tight_layout(); p = os.path.join(out, f"F3_ladder_{kind}.png")
    fig.savefig(p, dpi=160); plt.close(fig); print(f"  wrote {p}  (교차={crossed})")


# ==========================================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="figs")
    ap.add_argument("--add", action="append", default=[], help='"라벨=glob" 형식으로 데이터셋 추가')
    ap.add_argument("--legacy", action="store_true",
                    help="F2/F3 에 shim 버그 시기(2026-08-04 이전) 덤프도 합친다")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)

    # 2026-08-04: shim 버그(배경 팀교착 알람 오분류 → 자가복구 전면 무효) **이전/이후**를 반드시
    # 라벨로 구분한다. 섞어 놓으면 "완주율이 낮다"가 세계의 성질처럼 보이는데 실제로는 계측 결함이었다.
    datasets = [
        ("[수정후] 무OOD 30seed",       ["oracle/out/nom30/ep_s*.jsonl"]),
        ("[수정후] 1사건 사다리",        ["oracle/out/lad_*/ep_s*.jsonl"]),
        ("[수정후] core zone 재실행",    ["oracle/out/fix_core/ep_s*.jsonl"]),
        ("[무관] 무OOD (구 6seed)",      ["oracle/out/nominal_shard*.jsonl"]),   # 완주 100% = stall 없음 = 알람 없음 → 버그 무관
        ("[버그] 1사건 @30000 (구)",     ["oracle/out/openworld_merged.jsonl"]),
        ("[버그] 1사건 zone @8000",      ["oracle/out/rb_zone/ep_s*.jsonl", "oracle/out/rb_zf00/ep_s*.jsonl",
                                          "oracle/out/rb_zf13/ep_s*.jsonl"]),
        ("[버그] core @8000",            ["oracle/out/rb_core/ep_s*.jsonl"]),
        ("[버그] core @30000",           ["oracle/out/rb_core30/ep_s*.jsonl"]),
        ("[버그] 3사건 (hz_k1)",         ["oracle/out/hz_k1/ep_s*.jsonl"]),
        ("[버그] 3사건 fb (hz_fb)",      ["oracle/out/hz_fb/ep_s*.jsonl"]),
    ]
    for spec in a.add:
        if "=" in spec:
            lab, pat = spec.split("=", 1)
            datasets.append((lab, [pat]))
    datasets = [(n, p) for n, p in datasets if any(glob.glob(x) for x in p)]

    print("F1 완주율 ±SE")
    fig_completion(datasets, a.out)

    # F2/F3 는 '결정을 잰' 데이터가 필요하다 -> 기존 대형 덤프 우선.
    # F2/F3 는 **수정 후 데이터만** 쓴다. shim 버그(자가복구 전면 무효) 시기의 덤프와 섞으면
    # 계측 결함이 세계의 성질처럼 보인다 — F1 에서 라벨로 갈라 놓은 것과 같은 이유다.
    # 표본이 줄지만(옛 풀 200+ instance -> 32), 잘못된 표본을 늘리는 것보다 낫다.
    # 옛 풀을 보고 싶으면 --legacy 로 명시적으로 켠다.
    pool = load(sorted(glob.glob("oracle/out/lad_*/ep_s*.jsonl")) +
                ["oracle/out/fix_core/ep_s*.jsonl"])
    if a.legacy:
        pool += load(["oracle/out/hz_k1/ep_s*.jsonl", "oracle/out/hz_fb/ep_s*.jsonl",
                      "oracle/out/openworld_merged.jsonl"])
        print("  [legacy] shim 버그 시기 덤프를 합쳤다 — 해석 주의")
    print(f"\nF2 regret 분포  (행 {len(pool)})")
    fig_regret_dist(pool, a.out, title_suffix="  (shim 수정 후 데이터만)")

    print("\nF3 심각도 사다리")
    for k in ("battery", "fault", "zoneblk"):
        fig_ladder(pool, a.out, k)

    print(f"\n완료 -> {os.path.join(here, a.out)}")


if __name__ == "__main__":
    main()
