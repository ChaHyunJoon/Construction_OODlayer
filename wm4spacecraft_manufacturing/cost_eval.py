#!/usr/bin/env python
"""
cost_eval.py — Cost-of-Adaptation evaluation (COST_METRICS_DESIGN.md).

Prices the five adaptation policies (Oracle / LLM->solver / LLM-only / Surrogate->verify-k /
Surrogate-only) in REAL units — latency (s), decision regret, completion, $/decision — on the SAME
ground truth the accuracy work uses (`graded_hs_all.jsonl`).

Measured inputs (from this repo):
  * T_sim  = one true-planner verification wall-clock  = `label_seconds` per oracle row.
  * T_surr = one surrogate forest evaluation           = timed on `surrogate_hotswap.json`.
  * regret / completion / catastrophic                 = leave-one-instance-out on the graded dataset.
  * training/data-gen cost                             = sum of label_seconds (break-even numerator).

Modeled/swept inputs (LLM planner only):
  * T_llm, $_llm — measured live via `llm_probe.py` output if present, else from published tiers.
  * LLM-only planner accuracy — scored at `always_per_kind` (the LLM's best case) + a sweep.

Usage:  python cost_eval.py [dataset.jsonl] [--surrogate surrogate_hotswap.json] [--lam 15]
                             [--stream battery,zone,fault,battery] [--llm-probe llm_probe.json]
Writes: cost_eval_metrics.json  (+ prints a full report)

============================================================================================
한국어 설명 (처음 읽는 사람을 위한 안내)
============================================================================================
[이 파일이 하는 일]
  "적응(adaptation)에 드는 실제 비용"을 돈/시간 단위로 계산하는 평가 스크립트입니다. OOD 상황에서
  어떤 행동(macro)을 고를지 결정하는 다섯 가지 정책(policy)을 같은 정답 데이터로 비교합니다:
    1) Oracle (verify all 5)        : 5개 macro를 전부 진짜 planner로 검증(가장 정확·가장 느림).
    2) LLM->solver (verify C=3)     : LLM이 후보 3개로 좁힌 뒤 그 3개만 진짜 planner로 검증.
    3) LLM-only planner (no verify) : LLM만으로 결정(검증 없음).
    4) Surrogate->verify-1          : surrogate로 1개 고른 뒤 진짜 planner로 1번만 확인.
    5) Surrogate-only (k=0, ours)   : surrogate 예측만으로 결정(우리 방식, planner 호출 0).
  각 정책을 네 가지 축으로 값 매김: latency(지연 초), decision regret(결정 후회), completion(완주율),
  $/decision(결정당 비용).

[프로젝트에서의 역할]
  ConstructionBots.jl(여러 로봇 조립 TAMP 시뮬레이터) 위 re-spec 레이어에서, 학습된 surrogate가
  진짜 planner(느린 MILP/TAMP)나 LLM을 대체할 만큼 싸고 빠르면서도 결정 품질이 유지되는지를
  "실단위 cost"로 입증합니다. 정확도 관련 코드가 쓰는 것과 동일한 graded ground truth
  (graded_hs_all.jsonl)를 그대로 사용합니다.

[측정값(measured) vs 모델값(modeled)]
  * T_sim  = 진짜 planner 검증 1회의 실측 벽시계 시간 = oracle 각 행의 label_seconds.
  * T_surr = surrogate forest 1회 추론 시간 = surrogate_hotswap.json으로 실측.
  * regret / completion = graded 데이터셋 위에서 leave-one-instance-out(LOIO)로 측정.
  * T_llm, $_llm = llm_probe.json이 있으면 실측, 없으면 공개 가격표(LLM_TIERS)로 모델링.

[실행 방법]
  python cost_eval.py [데이터.jsonl] [--surrogate surrogate_hotswap.json] [--lam 15]
                      [--stream battery,zone,fault,battery] [--llm-probe llm_probe.json]
    - --lam 15   : cost 가중치(행동 비용 페널티 세기).
    - --stream   : 한 번의 빌드에서 순서대로 만나는 OOD 종류들 -> 빌드당 총 적응 시간 계산.
  결과: cost_eval_metrics.json 파일로 저장 + 콘솔에 전체 리포트 출력.

[문법 참고 - 낯선 Python 표현들]
  - argparse.ArgumentParser()    : 명령줄 인자 파서. add_argument로 옵션 정의, parse_args()로 읽음.
                                   nargs="?"=선택적 위치인자, default=기본값, type=float=형 변환.
  - json.load(open(path))        : JSON 파일을 파이썬 dict로 읽음. json.dump로 다시 파일에 씀.
  - .jsonl                       : 한 줄에 JSON 하나씩 있는 형식(load 함수가 파싱).
  - f"{x:.3f}" / f"{x:>9}" / {x:<20} : f-string 포맷(소수 자리/오른쪽·왼쪽 정렬/폭 지정).
  - f"{x:,.0f}"                  : 천 단위 콤마 + 소수 0자리 (예: 1,234).
  - {p: [] for p in POLICIES}    : dict comprehension(정책마다 빈 리스트 초기화).
  - [expr for ... if ...]        : list comprehension.
  - np.percentile / np.median    : numpy 분위수/중앙값. rng.integers=복원추출 인덱스(bootstrap).
  - df.groupby("instance")       : pandas 그룹화. df[df.fired==True]=조건 행만.
  - time.perf_counter()          : 고정밀 시간 측정용(추론 latency 재는 데 사용).
  - dict(a=1, b=2)               : 키워드로 dict 만들기. **spec 등은 이 파일엔 없지만 dict 언팩 관용구.
"""
import sys, os, json, math, time, argparse
import numpy as np
import pandas as pd
# 같은 폴더의 모듈들을 import 할 수 있게 이 파일 위치를 경로에 추가.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 공용 유틸: load(데이터 로드), featurize(특징화), lex_key(사전식 정렬 키), MACRO_NAME(macro 이름표).
import wm_datasets                      # 데이터셋 경로 단일 정의
from e1_analyze import (load, featurize, lex_key, MACRO_NAME)
# surrogate 관련: add_interactions(상호작용 특징 추가), MACRO_COST(행동 비용표), cost_key(비용반영 정렬키).
from export_surrogate import add_interactions, MACRO_COST, cost_key
from sklearn.ensemble import RandomForestRegressor
from sklearn.model_selection import LeaveOneGroupOut

HERE = os.path.dirname(os.path.abspath(__file__))   # 이 스크립트가 있는 폴더의 절대경로(기본 파일 위치용)

# ----------------------------------------------------------------------------------------------------
# Published LLM price/latency tiers (2026-01, per 1M tokens; latency = typical planning round-trip).
# Used only when no live measurement is supplied. A "planner" prompt: ~1500 tok in, ~300 tok out.
# ----------------------------------------------------------------------------------------------------
# 공개 LLM 가격/지연 등급표: (입력 $/1M토큰, 출력 $/1M토큰, 왕복 지연 초). 실측이 없을 때만 사용.
LLM_TIERS = {
    # name           in$/M  out$/M  latency_s
    "haiku-class":   (0.80,  4.00,   1.5),
    "sonnet-class":  (3.00,  15.00,  4.0),
    "opus-class":    (15.00, 75.00,  8.0),
}
LLM_DEFAULT_TIER = "sonnet-class"           # 기본으로 가정하는 LLM 등급
PROMPT_IN_TOK, PROMPT_OUT_TOK = 1500, 300   # a per-event OOD planning prompt (narrow: pick 1 of 5)
# ↑ OOD 1건당 planning 프롬프트의 대략적 토큰 수(입력 1500 / 출력 300). 비용 계산에 사용.
LLM_CAND_COUNT = 3                           # candidates an LLM proposes per event (LLM->solver C)
# ↑ LLM이 이벤트당 제안하는 후보 macro 수 C (LLM->solver 정책에서 검증할 개수).


# ---------- forest inference (faithful to the deployed surrogate_hotswap.json) ----------
# 배포된 forest surrogate JSON 파일을 읽어 dict(spec)로 반환. path=json 경로.
def load_forest(path):
    spec = json.load(open(path))
    assert spec["kind"] == "forest", "expected a forest surrogate"   # forest 형식인지 확인(아니면 중단)
    return spec


# JSON으로 저장된 forest를 특징벡터 x 하나에 대해 직접 평가(트리들의 평균 예측). spec=forest, x=특징벡터.
def forest_predict_row(spec, x):
    """Evaluate the deployed JSON forest on ONE feature vector x (a single decision). Returns mean
    over trees. This is the exact computation the Julia demo runs at decision time."""
    total = 0.0
    trees = spec["trees"]
    for t in trees:                        # 각 트리를 순회하며 예측을 합산
        feat, thr, left, right, val = t["feature"], t["threshold"], t["left"], t["right"], t["value"]
        node = 0                           # 루트에서 시작
        while feat[node] != -2:            # -2 marks a leaf (sklearn convention)
            if x[feat[node]] <= thr[node]: # 특징값이 임계값 이하면 왼쪽, 아니면 오른쪽 자식으로 이동
                node = left[node]
            else:
                node = right[node]
        total += val[node]                 # 도달한 leaf의 값을 누적
    return total / len(trees)              # 트리 개수로 나눠 평균 = forest 예측


# surrogate 추론 1회의 시간(초/결정)을 실측. spec=forest, Xmat=특징행렬, feat_names=열 이름, reps=반복 횟수.
def measure_surrogate_latency(spec, Xmat, feat_names, reps=2000):
    """Time a single-row forest evaluation (a decision is one event). Returns seconds/decision."""
    # align X columns to the forest's feature order
    # forest가 기대하는 feature 순서에 맞게 Xmat의 열 인덱스를 매핑(없는 특징은 None -> 나중에 0으로).
    idx = [list(feat_names).index(fn) if fn in list(feat_names) else None for fn in spec["feature_names"]]
    rows = []
    for r in range(Xmat.shape[0]):
        rows.append([Xmat[r, i] if i is not None else 0.0 for i in idx])   # forest 순서로 재배열한 행
    rows = np.asarray(rows, dtype=float)
    # warm up
    for j in range(min(50, len(rows))):    # 워밍업(캐시 등 정착시켜 측정 편향 줄임) - 시간 측정 제외
        forest_predict_row(spec, rows[j % len(rows)])
    t0 = time.perf_counter()               # 측정 시작
    for j in range(reps):
        forest_predict_row(spec, rows[j % len(rows)])   # reps번 반복 추론 (% = 인덱스 순환)
    dt = (time.perf_counter() - t0) / reps  # 총 시간 / 반복수 = 결정당 시간
    return dt


# ---------- accuracy: LOO decision regret per policy, on the graded ground truth ----------
# 각 정책의 결정 정확도를 LOIO로 측정. df=데이터, lam=cost 가중치. 반환=정책별 regret/catastrophic/completion.
def evaluate_accuracy(df, lam):
    """Leave-one-instance-out. Returns per-policy regret/catastrophic/completion, paired per instance.
    Policies scored here: oracle(=0), surrogate(k0), always_per_kind(=LLM-only best case),
    heuristic, random. LLM->solver residual computed separately from the candidate set."""
    df = df[df.fired == True].copy()       # OOD 발동 행만
    # cost-aware: keep full 5-macro instances (harmless ones carry the restraint signal)
    keep = [i for i, g in df.groupby("instance") if len(g) == 5]   # 5개 macro 전부 있는 instance만 사용
    df = df[df.instance.isin(keep)].reset_index(drop=True)

    F = featurize(df); F = add_interactions(F, df)   # 특징화 + 상호작용 특징 추가
    feat_names = list(F.columns)
    X = F.values
    cost = np.array([MACRO_COST[int(m)] for m in df.macro])   # 각 행의 macro 비용
    y = df.closed.astype(float).values - lam * cost          # 회귀 타깃 = cost-aware value (closed - lam*cost)
    groups = df.instance.values                              # LOIO 그룹(instance)
    kind_of = {i: str(g.kind.iloc[0]) for i, g in df.groupby("instance")}   # instance -> kind

    # per-instance oracle-best under cost-aware feasibility-lexicographic
    # 한 instance에서 cost 반영 feasibility-lexicographic 기준 최선 macro 행을 찾음(완주>closed>makespan>비용).
    def best_macro_of(g):
        return max(g.itertuples(index=False),
                   key=lambda r: cost_key(r.complete, r.closed,
                                          (r.makespan if not isinstance(r.makespan, str) else math.inf),
                                          r.macro, lam))   # makespan이 문자열("inf" 등)이면 math.inf로 대체
    best = {i: int(best_macro_of(g).macro) for i, g in df.groupby("instance")}   # instance -> 정답 macro
    global_best = int(pd.Series(list(best.values())).mode().iloc[0])   # 전체에서 가장 흔한 정답(폴백용)
    # heuristic textbook rule: fault->Replace, battery->Replace, zone->ForbidZone, else NOOP
    # 교과서적 휴리스틱 규칙(비교용 baseline): 고장/배터리->Replace(1), 구역->ForbidZone(3), 그 외 NOOP.
    HEUR = {"fault": 1, "battery": 1, "zone": 3, "zoneblk": 3}

    POLICIES = ["surrogate", "always_per_kind", "heuristic", "random", "oracle"]   # 비교할 정책들
    reg = {p: [] for p in POLICIES}            # 정책 -> instance별 regret 리스트
    catastrophic = {p: 0 for p in POLICIES}    # 정책 -> 치명적 오선택(regret 큼) 횟수
    complete_pick = {p: [] for p in POLICIES}  # 정책 -> 고른 macro가 완주(complete)인지 0/1 리스트
    rng = np.random.default_rng(0)             # random 정책용 난수 생성기(seed 고정)

    for tr, te in LeaveOneGroupOut().split(X, y, groups):   # tr=학습행, te=held-out 한 instance 행
        iid = groups[te][0]
        g = df.iloc[te]
        macros = [int(m) for m in g.macro.values]           # 이 instance에서 가능한 macro 번호들
        # Regret is scored on the COST-AWARE value (closed - lam*cost(macro)), the decision-relevant
        # objective: on a harmless/high-SoC battery, Replace and NOOP close the same nodes, so only the
        # wasted-spare cost separates them. A raw-closed metric would tie a Replace-everything heuristic
        # with the oracle (the "decision-easy trap" the graded task is built to avoid); the cost-aware
        # metric is the one the necessity claim (always_per_kind 0.701) uses.
        # macro번호 -> cost-aware value (closed - lam*비용). regret 채점의 기준 값.
        val = {int(m): float(c) - lam * MACRO_COST[int(m)] for m, c in zip(g.macro.values, g.closed.values)}
        comp = {int(m): bool(c) for m, c in zip(g.macro.values, g.complete.values)}   # macro -> 완주여부
        bm = best[iid]; bval = val[bm]; worst = min(val.values()); span = max(bval - worst, 1e-9)  # 정답값/최악값/폭

        # surrogate 정책: held-out instance는 학습에서 빠졌으니, 나머지로 학습한 forest로 각 macro value 예측.
        model = RandomForestRegressor(n_estimators=60, max_depth=6, min_samples_leaf=2,
                                      random_state=0).fit(X[tr], y[tr])
        pred = model.predict(X[te])
        s_pick = macros[int(np.argmax(pred))]   # 예측 value가 가장 큰 macro 선택

        # always_per_kind 정책(=LLM-only 최선 케이스): 같은 kind 학습 instance들의 최빈 정답을 고정 선택.
        tr_same = [best[i] for i in set(groups[tr]) if kind_of[i] == kind_of[iid]]
        k_pick = int(pd.Series(tr_same).mode().iloc[0]) if tr_same else global_best
        k_pick = k_pick if k_pick in val else global_best        # 이번 instance에 없는 macro면 폴백
        h_pick = HEUR.get(kind_of[iid], 0); h_pick = h_pick if h_pick in val else 0   # 휴리스틱 선택
        r_pick = int(rng.choice(macros))                         # random 정책: 무작위 macro

        picks = {"surrogate": s_pick, "always_per_kind": k_pick, "heuristic": h_pick,
                 "random": r_pick, "oracle": bm}                 # 정책 -> 그 정책이 고른 macro
        for p, mp in picks.items():
            r = (bval - val[mp]) / span                          # 정규화 regret = (정답값 - 선택값)/폭
            reg[p].append(r)
            if (bval - val[mp]) / max(bval, 1) > 0.15:            # 정답 대비 15% 넘게 손해면 치명적 오선택
                catastrophic[p] += 1
            complete_pick[p].append(1.0 if comp[mp] else 0.0)    # 고른 macro가 완주면 1

    out = {}
    for p in POLICIES:
        # 정책별 요약: 평균 regret, regret 리스트(CI용), 치명 오선택 수, 표본수 n, 평균 완주율.
        out[p] = dict(regret=float(np.mean(reg[p])), regret_list=reg[p],
                      catastrophic=catastrophic[p], n=len(reg[p]),
                      completion=float(np.mean(complete_pick[p])))
    # _로 시작하는 키는 결과가 아니라 후속 계산에 넘길 부수 데이터(밑줄 = 내부용 관례).
    out["_n_instances"] = len(keep)
    out["_feat_names"] = feat_names
    out["_X"] = X
    return out


# 두 regret 리스트 차이의 평균과 95% 신뢰구간을 paired bootstrap으로 계산. a,b=쌍 리스트, reps=재표본 횟수.
def paired_ci(a, b, reps=4000, seed=1):
    """95% CI on mean(a-b) by paired bootstrap (a,b are per-instance regret lists)."""
    a, b = np.array(a), np.array(b); d = a - b   # 쌍별 차이
    rng = np.random.default_rng(seed)
    boots = [float(np.mean(d[rng.integers(0, len(d), len(d))])) for _ in range(reps)]  # 복원추출 평균들
    return float(np.mean(d)), float(np.percentile(boots, 2.5)), float(np.percentile(boots, 97.5))


# 전체 평가를 실행하는 진입점: 인자 파싱 -> T_sim/정확도/T_surr/LLM비용 측정 -> 정책별 cost표/스트림/break-even 출력 -> JSON 저장.
def main():
    # argparse로 명령줄 옵션 정의(각 default는 이 파일 폴더 기준 경로/값).
    ap = argparse.ArgumentParser()
    # HS_ALL 고정: COST_EVAL_RESULTS.md 의 숫자가 이 파일에서 나왔다(wm_datasets.py 참고).
    ap.add_argument("data", nargs="?", default=wm_datasets.resolve(default=wm_datasets.HS_ALL))  # 선택적 위치인자
    ap.add_argument("--surrogate", default=os.path.join(HERE, "surrogate_hotswap.json"))  # 배포 forest JSON
    ap.add_argument("--lam", type=float, default=15.0)   # cost 가중치
    ap.add_argument("--stream", default="battery,zone,fault,battery",
                    help="OOD stream in one build (per B7 demo) -> per-build adaptation time")  # 한 빌드의 OOD 순서
    ap.add_argument("--llm-tier", default=LLM_DEFAULT_TIER, choices=list(LLM_TIERS))   # 사용할 LLM 가격 등급
    ap.add_argument("--llm-probe", default=os.path.join(HERE, "llm_probe.json"),
                    help="JSON from a live LLM latency/token measurement (optional)")   # 실측 LLM 측정치(있으면 우선)
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "cost_eval_metrics.json"))  # 결과 저장 경로
    a = ap.parse_args()   # 실제 인자 파싱 -> a.data, a.lam 등으로 접근

    print("=" * 92)
    print("COST-OF-ADAPTATION EVALUATION  (surrogate vs LLM planner, real units)")
    print("=" * 92)

    # ---------------- M1a: measured planner-call wall-clock T_sim ----------------
    # M1a: 진짜 planner 검증 1회 시간 T_sim을 실측 label_seconds에서 통계(중앙값/평균/P90/CI)로 요약.
    df = load(a.data)
    rows = df[df.fired == True]
    Tsim = rows.label_seconds.astype(float).values   # 행마다 기록된 실측 planner 시간(초)
    rng = np.random.default_rng(2)
    tsim_boot = [float(np.median(Tsim[rng.integers(0, len(Tsim), len(Tsim))])) for _ in range(4000)]  # 중앙값 bootstrap
    tsim = dict(median=float(np.median(Tsim)), mean=float(np.mean(Tsim)),
                p90=float(np.percentile(Tsim, 90)), n=int(len(Tsim)),
                ci=[float(np.percentile(tsim_boot, 2.5)), float(np.percentile(tsim_boot, 97.5))],
                total_hours=float(Tsim.sum() / 3600))   # 데이터셋 전체 오라클 라벨링에 든 총 시간(시간 단위)
    print(f"\n[M1a] T_sim (one true-planner verification, MEASURED label_seconds, n={tsim['n']}):")
    print(f"      median={tsim['median']:.1f}s  mean={tsim['mean']:.1f}s  P90={tsim['p90']:.1f}s "
          f"median 95%CI [{tsim['ci'][0]:.0f},{tsim['ci'][1]:.0f}]s")
    print(f"      total oracle labeling of this dataset = {tsim['total_hours']:.2f} h  (break-even numerator)")

    # ---------------- M2/M4: accuracy + completion on the graded ground truth ----------------
    # M2/M4: 정책별 결정 정확도(regret/완주율)를 계산. .pop으로 부수 데이터(_로 시작)를 꺼내고 결과만 남김.
    acc = evaluate_accuracy(df, a.lam)
    feat_names = acc.pop("_feat_names"); Xmat = acc.pop("_X")   # T_surr 측정에 쓸 특징 이름/행렬
    n_inst = acc.pop("_n_instances")
    print(f"\n[M2] Decision accuracy (LOO, cost-aware lam={a.lam}, {n_inst} instances):")
    print(f"     {'policy':<20}{'regret':>9}{'catastrophic':>14}{'completion':>12}")
    for p in ["oracle", "surrogate", "heuristic", "always_per_kind", "random"]:
        d = acc[p]
        print(f"     {p:<20}{d['regret']:>9.3f}{d['catastrophic']:>8}/{d['n']:<5}{d['completion']:>12.0%}")
    # necessity CI: surrogate vs always_per_kind (= LLM-only planner best case)
    # 필요성 CI: surrogate가 always_per_kind(=LLM-only 최선)보다 유의하게 나은지(하한 lo>0이면 significant).
    m, lo, hi = paired_ci(acc["always_per_kind"]["regret_list"], acc["surrogate"]["regret_list"])
    print(f"     surrogate beats always_per_kind (LLM-only best case) by {m:+.3f} regret "
          f"[{lo:+.3f},{hi:+.3f}]  ({'significant' if lo > 0 else 'ns'})")

    # ---------------- M1b: measured surrogate inference latency T_surr ----------------
    # M1b: surrogate 추론 1회 시간 T_surr을 실제 배포 forest로 실측.
    spec = load_forest(a.surrogate)
    Tsurr = measure_surrogate_latency(spec, Xmat, feat_names)
    print(f"\n[M1b] T_surr (one surrogate forest eval, MEASURED, {len(spec['trees'])} trees): "
          f"{Tsurr*1e6:.1f} us/decision  ({Tsurr:.2e} s)")

    # ---------------- LLM planner cost: live measurement or published tier ----------------
    # LLM 비용/지연: llm_probe.json(실측)이 있으면 그 값을, 없으면 공개 가격표(LLM_TIERS)로 계산.
    if os.path.exists(a.llm_probe):
        probe = json.load(open(a.llm_probe))
        T_llm = float(probe["latency_s_median"]); llm_cost = float(probe["usd_per_call_median"])
        llm_src = f"LIVE ({probe.get('model','?')}, n={probe.get('n','?')})"   # .get: 키 없으면 '?' 기본값
        in_tok, out_tok = probe.get("in_tok", PROMPT_IN_TOK), probe.get("out_tok", PROMPT_OUT_TOK)
    else:
        pin, pout, T_llm = LLM_TIERS[a.llm_tier]   # (입력단가, 출력단가, 지연) 튜플 언패킹
        llm_cost = PROMPT_IN_TOK / 1e6 * pin + PROMPT_OUT_TOK / 1e6 * pout   # 토큰수/100만 * 단가 = 호출당 $
        llm_src = f"MODELED ({a.llm_tier}, published price/latency)"
        in_tok, out_tok = PROMPT_IN_TOK, PROMPT_OUT_TOK
    print(f"\n[LLM] planner round-trip: T_llm={T_llm:.2f}s  ${llm_cost:.4f}/call  [{llm_src}]"
          f"  ({in_tok} in / {out_tok} out tok)")

    # ---------------- M1/M5: per-decision cost table ----------------
    # M1/M5: 결정 1건당 정책별 latency/$/regret/완주율 표를 구성.
    C = LLM_CAND_COUNT   # LLM->solver가 검증할 후보 수
    # surrogate->verify-k residual: the true best within the LLM candidate set vs the global best.
    # With cost-aware scoring the canonical macros are in the candidate set, so residual ~ surrogate's.
    # 각 정책의 (planner 호출 수, llm 호출 수, surrogate 호출 수, regret, completion)을 정의.
    policies = {
        "Oracle (verify all 5)":        dict(planner=5,  llm=0, surr=0, regret=acc["oracle"]["regret"],
                                             completion=acc["oracle"]["completion"]),
        "LLM->solver (verify C=3)":     dict(planner=C,  llm=1, surr=0, regret=acc["oracle"]["regret"],
                                             completion=acc["oracle"]["completion"]),
        "LLM-only planner (no verify)": dict(planner=0,  llm=1, surr=0,
                                             regret=acc["always_per_kind"]["regret"],
                                             completion=acc["always_per_kind"]["completion"]),
        "Surrogate->verify-1":          dict(planner=1,  llm=0, surr=1, regret=acc["surrogate"]["regret"],
                                             completion=acc["surrogate"]["completion"]),
        "Surrogate-only (k=0, ours)":   dict(planner=0,  llm=0, surr=1, regret=acc["surrogate"]["regret"],
                                             completion=acc["surrogate"]["completion"]),
    }
    for name, d in policies.items():
        # 정책 latency = LLM호출수*T_llm + planner호출수*T_sim(중앙값) + surrogate호출수*T_surr.
        d["latency_s"] = d["llm"] * T_llm + d["planner"] * tsim["median"] + d["surr"] * Tsurr
        d["usd"] = d["llm"] * llm_cost   # planner-sim compute $ optional; decision-time $ dominated by LLM
    print(f"\n[M1+M5] Per-decision cost (T_sim=median {tsim['median']:.0f}s, T_llm={T_llm:.1f}s):")
    print(f"     {'policy':<30}{'latency':>12}{'$/dec':>9}{'regret':>8}{'complete':>10}")
    for name, d in policies.items():
        lat = d["latency_s"]
        lats = f"{lat*1e3:.2f} ms" if lat < 1 else f"{lat:.1f} s"   # 1초 미만이면 ms 단위로 표기
        print(f"     {name:<30}{lats:>12}{d['usd']:>9.4f}{d['regret']:>8.3f}{d['completion']:>10.0%}")
    sur = policies["Surrogate-only (k=0, ours)"]   # 우리 방식(비교 기준)
    for opp in ["Oracle (verify all 5)", "LLM->solver (verify C=3)", "LLM-only planner (no verify)"]:
        o = policies[opp]
        spd = o["latency_s"] / max(sur["latency_s"], 1e-12)   # 상대 대비 몇 배 빠른지(0 나누기 방지)
        print(f"     -> surrogate-only is {spd:,.0f}x faster than {opp}")

    # ---------------- M3: whole-build adaptation time over the OOD stream ----------------
    # M3: 한 빌드 동안 OOD 스트림(여러 이벤트)을 처리하는 총 적응 시간 = 이벤트 수 D * 결정당 latency.
    stream = [s.strip() for s in a.stream.split(",") if s.strip()]   # "battery,zone,..." -> 리스트
    D = len(stream)   # 빌드당 OOD 이벤트 수
    print(f"\n[M3] Whole-build adaptation time over the stream {stream} (D={D} events):")
    print(f"     {'policy':<30}{'total decide-time':>20}{'per-build $':>13}")
    m3 = {}
    for name, d in policies.items():
        tot = D * d["latency_s"]; usd = D * d["usd"]   # 빌드당 총 시간 / 총 비용
        m3[name] = dict(total_s=tot, usd=usd)
        # 크기에 따라 ms / s / min으로 보기 좋게 단위 전환.
        ts = f"{tot*1e3:.1f} ms" if tot < 1 else (f"{tot:.1f} s" if tot < 90 else f"{tot/60:.1f} min")
        print(f"     {name:<30}{ts:>20}{usd:>13.4f}")

    # ---------------- M5: break-even vs LLM->solver ----------------
    # surrogate one-time cost = data-gen (measured hours) + train (seconds); per-decision saving vs
    # LLM->solver = its latency (as cloud-CPU-seconds proxy) . We report in planner-sim-seconds, the
    # honest shared unit: each avoided verification saves ~T_sim seconds.
    saved_per_dec_s = policies["LLM->solver (verify C=3)"]["latency_s"] - sur["latency_s"]  # 결정당 절약 시간
    train_cost_s = tsim["total_hours"] * 3600   # data-gen dominates; RF train is ~seconds
    breakeven = train_cost_s / max(saved_per_dec_s, 1e-9)   # 손익분기 결정 수 = 초기비용 / 결정당 절약
    print(f"\n[M5] Break-even vs LLM->solver:")
    print(f"     surrogate one-time cost (data-gen) = {train_cost_s/3600:.2f} h; saving/decision = "
          f"{saved_per_dec_s:.0f}s  => break-even at {breakeven:,.0f} decisions")
    print(f"     (amortized: every decision past #{breakeven:,.0f} is pure saving; the deployed demo makes "
          f"D={D}/build, so ~{max(1,round(breakeven/D)):,} builds)")

    # ---------------- LLM sensitivity sweep (M1/M5 robustness) ----------------
    # 민감도 분석: 어떤 LLM 등급을 가정하든 surrogate 우위가 유지되는지 모든 tier로 훑어봄.
    print(f"\n[sweep] surrogate advantage across published LLM tiers (LLM-only planner):")
    sweep = {}
    for tier, (pin, pout, tl) in LLM_TIERS.items():   # 각 등급의 (입력단가, 출력단가, 지연) 언패킹
        c = PROMPT_IN_TOK / 1e6 * pin + PROMPT_OUT_TOK / 1e6 * pout   # 이 등급의 호출당 $
        lat_speedup = tl / max(sur["latency_s"], 1e-12)              # surrogate 대비 속도 배수
        sweep[tier] = dict(latency_s=tl, usd=c, latency_speedup=lat_speedup)
        print(f"     {tier:<14} T_llm={tl:>4.1f}s ${c:.4f}/dec -> surrogate-only {lat_speedup:,.0f}x faster, "
              f"${c:.4f} cheaper, and lower regret ({acc['surrogate']['regret']:.3f} vs "
              f"{acc['always_per_kind']['regret']:.3f})")

    # ---------------- dump metrics ----------------
    # 위에서 측정/계산한 모든 값을 하나의 dict로 모아 JSON 파일로 저장(재현·후속 분석용).
    metrics = dict(
        dataset=os.path.basename(a.data), lam=a.lam, n_instances=n_inst,
        T_sim=tsim, T_surr_s=Tsurr, T_llm_s=T_llm, llm_usd_per_call=llm_cost, llm_source=llm_src,
        accuracy={p: dict(regret=acc[p]["regret"], catastrophic=acc[p]["catastrophic"],
                          completion=acc[p]["completion"], n=acc[p]["n"]) for p in
                  ["oracle", "surrogate", "heuristic", "always_per_kind", "random"]},
        necessity_ci=dict(mean=m, lo=lo, hi=hi),
        per_decision={k: {kk: vv for kk, vv in v.items()} for k, v in policies.items()},
        stream=stream, per_build=m3, breakeven_decisions=breakeven,
        breakeven_train_hours=train_cost_s / 3600, llm_sweep=sweep,
    )
    with open(a.out, "w") as f:
        json.dump(metrics, f, indent=1, default=float)   # indent=1 보기좋게, default=float: 특수타입은 float로
    print(f"\nwrote {a.out}")


# 이 파일을 직접 실행할 때만 main() 호출 (import될 때는 실행 안 함).
if __name__ == "__main__":
    main()
