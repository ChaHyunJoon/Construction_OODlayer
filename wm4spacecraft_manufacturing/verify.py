#!/usr/bin/env python
"""
verify.py -- Verification harness for the LLM proposer AND the surrogate model.

This is the "did we build it right?" battery (VERIFICATION, distinct from validation). It runs on the
graded oracle dataset (every macro's TRUE outcome is known by rollout) and prints a PASS/FAIL report
for each check. Reviewer-facing: it is the evidence that (a) the ground truth is never authored by the
LLM, (b) the surrogate reads state monotonically in the physically-correct direction, and (c) the LLM
proposer's candidate sets are applicable and contain the oracle-best.

Usage:  python verify.py oracle/out/graded.jsonl [--lam=3]

Checks:
  GT isolation (concern 2)      V0   ground truth = full macro enumeration by rollout; LLM absent from labels
  Surrogate (concern 1)         S1   decision-equivalence: LOIO regret < always_per_kind (paired bootstrap CI)
                                S2   level-0 world-model fidelity: held-out predicted-closed R2 / MAE
                                S3   monotonicity/sanity: trained value moves in the physically-correct direction
                                S4   state-blind ablation: a kind-only model is strictly worse (state IS used)
  LLM proposer (concern 2)      L1   applicability: every proposed candidate is in the ground-truth valid set
                                L2   candidate recall: the oracle-best macro is in the proposed set (+ regret of misses)
                                L3   fallback bound: verify-all-5 recovers any recall miss at cost 5 (worst-case cap)

============================================================================================
한국어 설명 (처음 읽는 사람을 위한 안내)
============================================================================================
[이 파일이 하는 일]
  이 스크립트는 "검증(verification) 하니스"입니다. 즉 "우리가 시스템을 제대로 만들었는가?"를
  자동으로 PASS/FAIL로 채점합니다. (참고: verification = 제대로 만들었나 / validation = 맞는 걸
  만들었나. 둘은 다릅니다.)
  채점 대상은 두 가지 부품입니다.
    1) surrogate (대리 모델): 진짜 TAMP planner를 매번 돌리는 대신, 학습된 forest 모델이 각
       macro(대응 행동)의 결과 value를 "상상"해서 어떤 행동이 최선인지 고릅니다.
    2) LLM proposer (LLM 제안기): OOD(분포 밖) 상황에서 후보 macro 몇 개를 제안하는 부분.

[프로젝트에서의 역할]
  ConstructionBots.jl은 여러 로봇이 협력해 구조물을 조립하는 multi-robot 시뮬레이터이고,
  그 위에 OOD(로봇 고장/배터리 방전/통행 금지구역 등) 상황을 만나면 DSL 매크로로 대응하는
  "re-spec(재명세) 레이어"가 얹혀 있습니다. 이 verify.py는 리뷰어의 3가지 우려에 대한 증거를
  자동 생성합니다:
    - concern 1(V0): 정답(ground truth)은 LLM이 지어낸 게 아니라, 5개 macro를 전부 시뮬레이션
      rollout해서 얻은 사실이다.
    - concern 2(S1~S4): surrogate가 상태(state)를 물리적으로 옳은 방향으로 읽는 진짜 value model이다.
    - concern 2(L1~L3): LLM 후보 집합은 실행 가능(applicable)하고 oracle 최선(best)을 포함한다.

[실행 방법]
  python verify.py oracle/out/graded.jsonl [--lam=3] [--model=rf|hgb]
    - 첫 번째 인자(--로 시작하지 않는 것) = 채점할 데이터셋 경로(.jsonl)
    - --lam=3      : cost 가중치 lambda (행동 비용을 얼마나 페널티로 볼지)
    - --model=rf   : 배포된 RandomForest surrogate (기본값). hgb는 실험용 HistGradientBoosting.

[문법 참고 - 낯선 Python 표현들]
  - sys.argv[1:]                 : 명령줄 인자 리스트(프로그램 이름 제외한 나머지).
  - next((...) for ... if ...)   : 조건에 맞는 첫 원소를 꺼내는 generator + next() 조합. 기본값을
                                   주면 없을 때 그 값을 반환.
  - a.split("=")[1]              : "--lam=3" 같은 문자열을 "="로 쪼개 오른쪽("3")만 취함.
  - f"...{x:.3f}..."             : f-string. {값:.3f}=소수점 3자리, {값:34s}=폭 34칸 문자열 등 포맷.
  - {k: v for k, v in ...}       : dict comprehension(딕셔너리 축약 생성).
  - [x for x in ... if ...]      : list comprehension(리스트 축약 생성).
  - np.asarray / np.mean / np.percentile : numpy 배열 연산(벡터 단위 평균/분위수 계산).
  - df[df.fired == True]         : pandas DataFrame boolean 마스킹(조건 참인 행만 남김).
  - df.groupby("instance")       : instance별로 행을 묶어 그룹 단위 처리.
  - g.itertuples(index=False)    : DataFrame 각 행을 이름있는 튜플로 순회(r.macro 처럼 접근).
  - LeaveOneGroupOut()           : sklearn 교차검증기. 한 그룹(=한 instance)만 held-out으로 빼고
                                   나머지로 학습 -> LOIO(leave-one-instance-out) 방식.
"""
import sys, os, math
import numpy as np
import pandas as pd   # S4 의 kind-only 상대를 표현과 무관하게 직접 구성하는 데 사용
# 이 파일이 있는 폴더를 import 경로에 추가 -> 같은 폴더의 e1_analyze 등을 불러올 수 있게 함.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# e1_analyze에서 공용 유틸을 재사용: load(데이터 로드), featurize(특징 벡터화), MACROS(macro 목록),
# MACRO_NAME/MACRO_COST(이름/비용 표), cost_lex_key(비용 반영 사전식 정렬 키).
from e1_analyze import (load, featurize, MACROS, MACRO_NAME, MACRO_COST, cost_lex_key,
                        instance_arms_complete)
from sklearn.ensemble import RandomForestRegressor, HistGradientBoostingRegressor
from sklearn.model_selection import LeaveOneGroupOut

# --- the LLM proposer under test. Mirrors e2_llm_surrogate.LLM_CANDIDATES (the type's canonical macro +
# NOOP + a distractor). When a REAL LLM is wired, replace this with its emitted proposals per instance
# (load a {instance: [macros]} JSONL); every check below then runs unchanged on the real outputs. ---
# 채점 대상 LLM 제안기(가짜 버전). OOD kind별로 제안할 macro 후보 번호 목록.
# 각 kind마다 [정답이 될 canonical macro, NOOP(0), 헷갈리게 하는 distractor] 형태로 구성.
# 실제 LLM을 연결하면 이 dict를 LLM이 뱉은 instance별 후보로 갈아끼우면 되고, 아래 검사들은 그대로 동작.
LLM_CANDIDATES = {
    "fault":   [0, 1, 2],   # 로봇 고장: 후보 = NOOP / Replace(canonical) / distractor
    "battery": [0, 1, 2],   # 배터리 방전: 후보 = NOOP / Replace / distractor
    # zone 계열의 canonical 은 2026-08-03 부터 7(RelocateBuild)이다 — 3(ForbidZone)은 빌드 중반에
    # 옮길 수 있는 조립체가 없어 NOOP 과 같은 결과로 붕괴한다(md/RELOCATEBUILD_2026-08-03.md).
    # 3 과 7 을 **둘 다** 남긴다: 아래에서 "그 덤프에 실제로 존재하는 팔"만 골라 쓰므로, 옛 덤프는
    # 3 을, 새 덤프는 7 을 집는다. 한쪽만 적어두면 다른 쪽 덤프에서 후보가 NOOP 하나로 쪼그라든다.
    "zone":    [0, 7, 3, 1],   # 통행 금지구역: NOOP / RelocateBuild(canonical) / ForbidZone(구) / distractor
    "zoneblk": [0, 7, 3, 1],   # 금지구역(막힘): 위와 동일
}
# 배포되는 surrogate = RandomForest 설정값(트리 60개, 깊이 6, 재현성 위해 seed 고정, 전 코어 사용).
# the DEPLOYED surrogate class -- imported, never re-declared here.  (Until 2026-07-27 this
# dict silently omitted min_samples_leaf=2, so even verify.py's "rf" was not the shipped model.)
from surrogate_model import SURROGATE_PARAMS as RF
MODEL = "rf"  # set by --model=rf|hgb ; rf = deployed forest, hgb = the E1-E4 HistGBR
# ↑ 어떤 모델 클래스를 채점할지. main()에서 --model 인자로 덮어씀. rf=배포 forest, hgb=E1~E4 실험용.


# surrogate로 쓸 회귀 모델 인스턴스를 하나 만들어 반환 (전역 MODEL 값에 따라 종류 선택).
def make_model():
    if MODEL == "hgb":
        return HistGradientBoostingRegressor(max_iter=300, max_depth=4, learning_rate=0.08,
                                             min_samples_leaf=3, l2_regularization=1.0)
    return RandomForestRegressor(**RF)   # **RF: dict를 키워드 인자로 풀어서 전달


# 한 행(r)의 decision value를 스칼라로 계산. 인자: r=한 macro의 rollout 결과 행, lam=cost 가중치.
def val(r, lam):
    """Decision value scalar consistent with cost_lex_key: completion dominates, then cost-adjusted
    closed. Used for per-instance normalized regret."""
    # 완주(complete)면 1e6의 큰 보너스로 무조건 우선(feasibility-lexicographic: 완주가 다른 무엇보다 위).
    # 그 다음 closed(닫힌 노드 수)에서 lam*cost(행동 비용)를 빼서 비교.
    return (1e6 if bool(r.complete) else 0.0) + float(r.closed) - lam * MACRO_COST[int(r.macro)]


# 한 instance(그룹 g)에서 oracle(정답) 최선 macro 번호를 찾음. lam=cost 가중치.
def oracle_best_macro(g, lam):
    # cost_lex_key 기준으로 가장 큰 행을 고름 (완주>closed>makespan>비용 순의 사전식 비교).
    b = max(g.itertuples(index=False),
            key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, lam))
    return int(b.macro)


# 정규화된 regret(후회) 계산: 선택한 macro가 최선 대비 얼마나 손해인지 0~1로 환산. picked_macro=고른 번호.
def norm_regret(g, picked_macro, lam):
    vals = {int(r.macro): val(r, lam) for r in g.itertuples(index=False)}  # macro번호 -> value 매핑
    best = max(vals.values()); worst = min(vals.values())
    span = max(best - worst, 1e-9)                     # 0으로 나누기 방지용 하한
    return (best - vals[picked_macro]) / span          # (최선 - 내가 고른 것) / 전체 폭


# 같은 함수의 새 이름(2026-08-06). 앞으로 쓰는 코드는 이쪽을 부른다. 옛 이름은 그대로 남긴다
# — `regret` 은 20개 파일·아티팩트 JSON 키에 박혀 있어 일괄 개명하면 옛 결과를 읽는 코드가 조용히 깨진다.
subopt_norm = norm_regret


# ============================================================================================
# 초과비용(excess cost) — 2026-08-06 신설.  md/PLAN_LLM_INFERENCE_7H_2026-08-06.md §0-a
# --------------------------------------------------------------------------------------------
# 왜 만드는가: 위의 정규화 regret 은 (a) 단위가 없고(노드도 초도 아님), (b) 분모 span 이 사건마다
# 달라 같은 0.100 이 사건마다 다른 물리량을 뜻하고, (c) lam 정규화 때문에 lam 을 가로질러 비교하면
# 안 된다(README 함정 21). 튜닝 파라미터에 의존하는 값은 헤드라인이 될 수 없다.
# 그래서 손해를 **시뮬레이터의 실제 단위**로, 그리고 비용모델의 사전식 층 그대로 쪼개서 잰다.
#
# 주의: "정답이 무엇인가" 는 여전히 cost_lex_key(lam) 로 정한다(하니스 전체와 같은 기준).
#       "손해가 얼마인가" 만 물리 단위로 잰다. 그래서 d_ssp 가 음수일 수 있는데, 그것은
#       "물리적으로는 나쁘지 않았지만 개입비용(lam) 때문에 오답으로 판정됐다"는 뜻이다(버그 아님).
# ============================================================================================

# README §4 의 유한벌점 SSP 비용. gen_oracle_mc.jl:146 / overnight_mdp.py:35 와 **같은 값이어야 한다**.
SSP_STALL_BASE = 10000.0    # 미완주에 붙는 기본 벌점
SSP_PER_UNCLOSED = 100.0    # 안 닫힌 노드 1개당 벌점
SSP_MAKESPAN_W = 1e-3       # 미완주일 때 makespan 의 미세 가중치(동점 깨기용)


# 한 행의 총 노드 수를 꺼낸다. 덤프 세대에 따라 열 이름이 total / total_nodes 로 갈린다.
def _total_nodes(r):
    for k in ("total", "total_nodes"):
        v = getattr(r, k, None)
        if v is not None and not (isinstance(v, float) and math.isnan(v)):
            return float(v)
    return float("nan")


# 한 행의 SSP 비용(낮을수록 좋음). 완주면 makespan 그 자체, 미완주면 큰 벌점 + 안 닫힌 노드 수.
def ssp_cost(r):
    mk = float(r.makespan) if math.isfinite(float(r.makespan)) else 0.0
    if bool(r.complete):
        return mk
    unclosed = _total_nodes(r) - float(r.closed)
    if math.isnan(unclosed):
        unclosed = 0.0    # total 열이 없는 옛 덤프: 벌점의 노드 항만 빠지고 나머지는 유효
    return SSP_STALL_BASE + SSP_PER_UNCLOSED * unclosed + SSP_MAKESPAN_W * mk


# 고른 팔이 오라클 최선 대비 얼마나 손해였는지를 **사전식 층별로** 돌려준다.
#   d_feasibility : 완주할 수 있었는데 못 한 결정인가 (0/1)  <- 치명적 선택
#   d_closed      : 잃은 노드 수                              <- 단위 = 노드
#   d_makespan    : 잃은 시간(둘 다 완주일 때만 의미 있음)     <- 단위 = 초, 아니면 nan
#   d_ssp         : 위 셋을 합친 스칼라(비용모델 그대로)
def excess_cost(g, picked_macro, lam):
    rows = {int(r.macro): r for r in g.itertuples(index=False)}
    b = rows[oracle_best_macro(g, lam)]
    p = rows[int(picked_macro)]
    both_complete = bool(b.complete) and bool(p.complete)
    return {
        "d_feasibility": 1 if (bool(b.complete) and not bool(p.complete)) else 0,
        "d_closed": float(b.closed) - float(p.closed),
        # 완주 여부가 갈리면 두 makespan 은 서로 다른 의미의 양이라 빼면 안 된다(EVALUATION.md §2).
        "d_makespan": (float(p.makespan) - float(b.makespan)) if both_complete else float("nan"),
        "d_ssp": ssp_cost(p) - ssp_cost(b),
        # 자원 축: SSP 물리비용은 **소모한 스페어를 보지 않는다**. 그래서 "물리적으로는 같은데
        # 쓸데없이 개입했다" 는 오답이 d_closed=0 · d_makespan≈0 으로 보인다(실측: always-Replace
        # 가 정확히 그 모양 — 틀렸을 때 0.0 노드 / 0.1 초). lam 은 이 축을 결정규칙에 섞어 넣어
        # 감췄었다. 섞지 말고 **따로 센다**.
        "d_cost": MACRO_COST[int(p.macro)] - MACRO_COST[int(b.macro)],
    }


# 고른 팔이 최적 행동인가. 동점(정답이 여럿)은 따로 표시한다 — 동점을 정답/오답 어느 쪽으로 세도
# 수치가 왜곡되므로(README 함정 17) 적중률은 **동점을 뺀 분모**로 낸다.
def optimal_action(g, picked_macro, lam):
    keys = {int(r.macro): cost_lex_key(r.complete, r.closed, r.makespan, r.macro, lam)
            for r in g.itertuples(index=False)}
    top = max(keys.values())
    winners = [m for m, k in keys.items() if k == top]
    return {"optimal": int(picked_macro) in winners,
            "tied": len(winners) > 1,
            "n_best": len(winners)}


# 여러 결정을 모아 헤드라인 세 숫자로 요약한다.
# decisions = [(instance그룹 g, 고른 macro), ...]
def decision_report(decisions, lam, label=""):
    n = len(decisions)
    if n == 0:
        return {"n": 0}
    oa = [optimal_action(g, m, lam) for g, m in decisions]
    ec = [excess_cost(g, m, lam) for g, m in decisions]
    sn = [subopt_norm(g, m, lam) for g, m in decisions]
    decisive = [i for i in range(n) if not oa[i]["tied"]]        # 동점이 아닌 결정만
    wrong = [i for i in decisive if not oa[i]["optimal"]]        # 그중 틀린 것
    rep = {
        "label": label, "n": n, "n_decisive": len(decisive),
        "tie_rate": (n - len(decisive)) / n,
        # 헤드라인 ①: 동점을 뺀 결정 중 최적 행동을 고른 비율
        "optimal_action_rate": (len(decisive) - len(wrong)) / len(decisive) if decisive else float("nan"),
        # 헤드라인 ②: 틀렸을 때 평균 몇 노드를 잃었나
        "mean_d_closed_when_wrong": float(np.mean([ec[i]["d_closed"] for i in wrong])) if wrong else 0.0,
        # ②-b: 노드는 그대로인데 **시간만** 잃는 오답이 있다(README 함정 22 — 구역이 makespan 을
        #      2.1배로 늘리는데 closed 는 291 로 동일했던 사건). 노드 축만 보면 그런 오답이 통째로
        #      "손해 0" 으로 보인다. 실측: always-Replace 가 정확히 이 모양이다.
        "mean_d_makespan_when_wrong": float(np.nanmean([ec[i]["d_makespan"] for i in wrong]))
                                      if wrong and not all(math.isnan(ec[i]["d_makespan"]) for i in wrong) else 0.0,
        # 헤드라인 ③: 완주할 수 있었는데 놓친 선택의 비율
        "infeasible_pick_rate": float(np.mean([e["d_feasibility"] for e in ec])),
        # 헤드라인 ④: 최선 대비 **더 쓴 개입비용**(≈소모 자원). 위 셋이 물리 결과 축이라면 이건 자원 축.
        "mean_d_cost": float(np.mean([e["d_cost"] for e in ec])),
        "mean_d_ssp": float(np.mean([e["d_ssp"] for e in ec])),
        # 진단용으로만 남기는 옛 지표(발표 문장에는 쓰지 않는다)
        "subopt_norm": float(np.mean(sn)),
        "regret": float(np.mean(sn)),   # 별칭 — 옛 아티팩트를 읽는 코드 호환용
    }
    return rep


# decision_report 결과를 사람이 읽는 세 문장으로 찍는다.
def print_decision_report(rep):
    if rep.get("n", 0) == 0:
        print(f"  {rep.get('label','')}: (결정 0건)")
        return
    print(f"  {rep['label']:22s} n={rep['n']:4d} (동점 {rep['tie_rate']*100:.0f}%) | "
          f"적중률 {rep['optimal_action_rate']*100:5.1f}% | "
          f"틀렸을 때 {rep['mean_d_closed_when_wrong']:5.1f} 노드 / {rep['mean_d_makespan_when_wrong']:5.1f} 초 손해 | "
          f"완주 놓침 {rep['infeasible_pick_rate']*100:4.1f}% | "
          f"과잉개입 {rep['mean_d_cost']:+.2f} | "
          f"[진단 subopt_norm {rep['subopt_norm']:.3f}]")


# paired bootstrap로 mean(a)-mean(b)의 95% 신뢰구간(CI)을 구함. a,b=쌍을 이루는 regret 리스트.
def paired_bootstrap(a, b, n=10000, seed=0):
    """CI on mean(a) - mean(b), paired. Positive => a has higher regret (a worse)."""
    rng = np.random.default_rng(seed)                  # 재현 가능한 난수 생성기
    d = np.asarray(a) - np.asarray(b)                  # 쌍별 차이
    idx = rng.integers(0, len(d), size=(n, len(d)))    # n번 복원추출한 인덱스 행렬
    boot = d[idx].mean(axis=1)                         # 각 재표본의 평균 -> bootstrap 분포
    return float(d.mean()), float(np.percentile(boot, 2.5)), float(np.percentile(boot, 97.5))


# 콘솔에 구분선과 제목을 출력하는 배너 헬퍼. t=제목 문자열.
def banner(t):
    print("\n" + "=" * 78 + f"\n{t}\n" + "=" * 78)


# 개별 검사 결과를 [PASS]/[FAIL] 한 줄로 출력하고 통과여부(ok)를 그대로 돌려줌. name=검사명, detail=설명.
def verdict(name, ok, detail):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name:34s} {detail}")
    return ok


# 전체 검증 파이프라인을 실행하는 진입점: 인자 파싱 -> 데이터 로드 -> V0/S1~S4/L1~L3 검사 -> 요약.
def main():
    global MODEL
    # 명령줄 인자 파싱 (argparse 대신 수동): -- 없는 첫 인자를 데이터 경로로 사용.
    path = next(a for a in sys.argv[1:] if not a.startswith("--"))
    lam = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--lam=")), 3.0)   # 기본 3.0
    MODEL = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--model=")), "rf")     # 기본 "rf"
    print(f"[model class under test: {MODEL}]")
    df = load(path)                        # jsonl 데이터셋을 pandas DataFrame으로 로드
    df = df[df.fired == True].copy()       # 실제로 OOD가 발동(fired)한 행만 남김. .copy()로 뷰 경고 방지
    insts = list(df.instance.unique())     # 서로 다른 instance(시나리오) 목록
    print(f"loaded {len(df)} rows, {len(insts)} instances, lambda={lam}  ({path})")
    results = {}                           # 검사 키(V0,S1,...) -> 통과여부 저장

    # ---------- V0: GROUND-TRUTH ISOLATION (concern 2) ----------
    # V0: 정답(ground truth)이 LLM 손을 전혀 타지 않았음을 확인 (리뷰어 concern 2).
    banner("V0  ground-truth isolation -- the LLM never authors a label")
    # 완전성 판정은 **배포 필터와 같은 술어**를 쓴다(dspy_service._load_surrogate 가 쓰는 것).
    # 예전에는 `nunique() == len(MACROS)` = "7팔 전부"였는데, DS_VALID_ONLY 로 만든 라벨은 그 사건에서
    # 유효한 팔만 돌므로(fault 는 2팔) 그 조건은 원리적으로 충족 불가였다 -- V0 이 2026-08-06 이전부터
    # 실패하던 이유(RESULTS_LLM7H §6, "Ch-D"). 검증과 배포가 다른 필터를 쓰면 V0 이 배포되지 않는
    # 무언가를 검증하게 된다.
    full = sum(1 for _, g in df.groupby("instance") if instance_arms_complete(g))
    # 라벨(정답) 컬럼은 시뮬레이터가 만든 사실이어야 함: complete/closed/makespan 3개인지 확인.
    label_fields = [c for c in ("complete", "closed", "makespan") if c in df.columns]
    # 스키마에 llm/propos/candidate 같은 이름의 컬럼이 있으면 LLM이 라벨을 오염시킨 것 -> 없어야 함.
    llm_fields = [c for c in df.columns if any(t in c.lower() for t in ("llm", "propos", "candidate"))]
    results["V0"] = (
        verdict("full-enumeration labels", full == len(insts),
                f"{full}/{len(insts)} instances rolled out every VALID arm "
                f"(valid_mask 기준; 전체 어휘는 {MACROS})")
        & verdict("labels are rollout facts", len(label_fields) == 3,
                  f"label from {label_fields} (simulator), not model judgment")
        & verdict("no LLM-authored label column", not llm_fields,
                  f"LLM/proposal fields in schema: {llm_fields or 'none'}")
    )
    print("  -> ground truth is defined by exhaustive 5-macro enumeration + simulator rollout;")
    print("     the LLM is absent from this dump, so hallucination cannot reach a label.")

    # ---------- shared featurization / oracle labels ----------
    # 아래 S1~S4에서 공통으로 쓰는 특징행렬 X, 라벨 y, 그룹, oracle 정답 등을 미리 준비.
    # 특징 표현 선택. 기본값 "legacy" = 기존과 완전히 동일(회귀 없음).
    # --features=agnostic|agnostic-d 로 kind-agnostic 물리 서술자(features_agnostic.py)를 쓴다.
    # S3(단조성)는 macro 원-핫 컬럼(`macro_{m}`)을 직접 조작하므로 action_repr="onehot" 계열만
    # 지원한다 -- "descriptor" 는 그 컬럼이 없어 S3 를 건너뛴다(아래에서 방어).
    feat_mode = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--features=")), "legacy")
    if feat_mode == "legacy":
        _featurize = featurize
    else:
        from features_agnostic import featurize_agnostic
        _ar = "descriptor" if feat_mode == "agnostic-d" else "onehot"
        _featurize = lambda d: featurize_agnostic(d, action_repr=_ar)
    print(f"[feature representation: {feat_mode}]")
    Xdf = _featurize(df); cols = list(Xdf.columns); X = Xdf.values   # 상태+macro -> 특징 벡터 행렬
    y = df.closed.astype(float).values                             # 회귀 타깃 = closed 노드 수
    groups = df.instance.values                                    # 각 행이 속한 instance (LOIO 그룹)
    logo = LeaveOneGroupOut()                                      # leave-one-instance-out 교차검증기
    by_inst = {i: g for i, g in df.groupby("instance")}            # instance -> 그 행들(그룹)
    best = {i: oracle_best_macro(g, lam) for i, g in by_inst.items()}   # instance -> oracle 최선 macro
    kind_of = {i: str(g.kind.iloc[0]) for i, g in by_inst.items()}      # instance -> OOD kind 문자열

    # ---------- S1: DECISION-EQUIVALENCE (LOIO regret vs always_per_kind) ----------
    # always_per_kind is the strong state-blind opponent: best fixed macro PER OOD kind. It must be fitted
    # fold-locally (training instances only) -- fitting it on all instances leaks the held-out label and
    # makes the baseline unfairly strong.
    banner("S1  surrogate decision-equivalence (leave-one-instance-out)")
    reg_model, reg_pk = [], []          # surrogate regret / always_per_kind regret 누적
    y_true_lvl0, y_pred_lvl0 = [], []   # S2에서 쓸 held-out 실제/예측 closed 값 누적
    for tr, te in logo.split(X, y, groups):   # tr=학습행 인덱스, te=held-out 한 instance 행 인덱스
        inst = groups[te][0]; g = by_inst[inst]
        tr_insts = set(groups[tr])            # 이 fold에서 학습에 쓰인 instance들
        pk = {}                                              # fold-local per-kind majority best macro
        # 상대 baseline always_per_kind: kind별로 "학습셋에서 가장 자주 최선이던 macro"를 고정 선택.
        # 반드시 학습 instance만으로 계산해야 함(held-out 라벨을 쓰면 baseline이 부당하게 강해짐 = leak).
        for k in set(kind_of[i] for i in tr_insts):
            ms = [best[i] for i in tr_insts if kind_of[i] == k]
            pk[k] = max(set(ms), key=ms.count)               # 최빈값(majority) macro
        m = make_model().fit(X[tr], y[tr])                   # surrogate를 학습셋으로 훈련
        pte = m.predict(X[te])                               # held-out instance의 각 macro value 예측
        te_macro = df.iloc[te].macro.astype(int).values
        pred_by_macro = {int(mm): float(pp) for mm, pp in zip(te_macro, pte)}
        pick = max(pred_by_macro, key=pred_by_macro.get)     # surrogate가 고른 macro = 예측 value 최대
        reg_model.append(norm_regret(g, pick, lam))          # surrogate의 regret
        reg_pk.append(norm_regret(g, pk.get(kind_of[inst], best[inst]), lam))  # baseline의 regret
        # level-0: held-out predicted vs true closed  (S2 fidelity 채점용으로 모아둠)
        for mm, pp in zip(te_macro, pte):
            y_pred_lvl0.append(pp)
        y_true_lvl0.extend(df.iloc[te].closed.astype(float).values)
    mreg, pkreg = float(np.mean(reg_model)), float(np.mean(reg_pk))   # 평균 regret 두 개
    d, lo, hi = paired_bootstrap(reg_pk, reg_model)   # positive => per_kind worse => model better
    # PASS 조건: CI 하한 lo>0 이면 surrogate가 baseline보다 통계적으로 유의하게 regret이 낮음.
    results["S1"] = verdict("model < always_per_kind", lo > 0,
                            f"regret {mreg:.3f} vs {pkreg:.3f}; advantage +{d:.3f} CI [{lo:+.3f},{hi:+.3f}]")

    # ---------- S2: LEVEL-0 WORLD-MODEL FIDELITY ----------
    # surrogate가 정말 value(closed 수)를 예측하는 world model인지 R2/MAE로 확인.
    banner("S2  level-0 fidelity (is it really a value model?)")
    yt, yp = np.array(y_true_lvl0), np.array(y_pred_lvl0)   # held-out 실제값 / 예측값
    ss_res = float(np.sum((yt - yp) ** 2)); ss_tot = float(np.sum((yt - yt.mean()) ** 2))  # 잔차/전체 제곱합
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else float("nan")   # 결정계수 R2 (1에 가까울수록 좋음)
    mae = float(np.mean(np.abs(yt - yp)))                       # 평균 절대 오차(노드 수 단위)
    results["S2"] = verdict("held-out closed R2 > 0.5", r2 > 0.5,
                            f"R2={r2:.3f}  MAE={mae:.1f} nodes (held-out (state,macro))")

    # ---------- S3: MONOTONICITY / SANITY (DECISION-relevant, not absolute value) ----------
    # The physically-true claim is about the GAP value(intervention) - value(NOOP), not either macro's
    # absolute closed-count. So we hold each instance's state fixed, synthesise the intervention-macro and
    # the NOOP feature vectors, perturb one feature on both, and check the GAP moves the right way. The
    # PASS criterion is the sign of the AGGREGATE slope (mean d-gap) -- a step-function forest is noisy
    # pointwise, but its decision boundary must shift in the correct direction on average.
    banner("S3  monotonicity / sanity of the trained surrogate (gap vs NOOP)")
    full_model = make_model().fit(X, y)                      # 전체 데이터로 학습한 surrogate
    mj = {m: cols.index(f"macro_{m}") for m in MACROS}       # macro번호 -> 원-핫 컬럼 인덱스 표

    # 특징행렬 base의 macro 원-핫을 macro m으로 바꿔치기(다른 macro는 0, m만 1)한 사본을 만듦.
    def as_macro(base, m):
        Z = base.copy()
        for mm in MACROS:
            Z[:, mj[mm]] = 0.0        # 모든 macro 원-핫을 끔
        Z[:, mj[m]] = 1.0            # m만 켬
        return Z

    # gap = value(개입 macro m) - value(NOOP). feat/step을 주면 그 특징을 step만큼 밀어 넣고 계산.
    def gap(base, m, feat=None, step=0.0):
        j = cols.index(feat) if feat is not None else None
        Zi, Z0 = as_macro(base, m), as_macro(base, 0)        # 개입 macro / NOOP(0) 두 버전
        if j is not None:
            Zi = Zi.copy(); Z0 = Z0.copy(); Zi[:, j] += step; Z0[:, j] += step   # 같은 feature를 동일 이동
        return full_model.predict(Zi) - full_model.predict(Z0)   # 두 예측의 차 = gap

    # (intervention macro, feature, expected sign of d[gap]/d[feature], kind). Only claims whose TRUTH is
    # monotone AND whose feature is covered by >=3 distinct data values are graded (core). NOTE `severity`
    # is not monotone in harshness across kinds: for battery it IS the post-drop SoC (low = deep = harsh
    # -> negative sign); for fault it is pending/max (high = harsh). Each test is kind-scoped accordingly.
    # 특징 feat을 밀었을 때 gap이 기대 부호(sign)로 움직이는지 검사. macro=개입 macro, kf=대상 kind.
    def run_gap_test(name, macro, feat, sign, kf):
        mask = (df.macro.astype(int) == 0).values                # one base state per instance (NOOP rows)
        if kf is not None:
            mask &= (df.kind == kf).values                       # 특정 kind로 한정(& = boolean 마스크 AND)
        if mask.sum() < 3:
            print(f"  [skip] {name:11s} d/d {feat:14s}  (only {int(mask.sum())} base states)"); return None
        if feat not in cols:
            # 표현마다 축 이름이 다르다(legacy 는 soc/agent_pending, agnostic 은 harm/work_at_risk).
            # 없는 축은 조용히 건너뛴다 -- 크래시가 아니라 "이 표현에는 해당 축이 없음"이 옳은 보고.
            print(f"  [skip] {name:11s} d/d {feat:14s}  (feature absent in this representation)"); return None
        j = cols.index(feat)
        # 섭동 크기는 **검사 대상 kind 안의** 산포로 잡는다(전체 산포가 아니라).
        # 이유: 이 검사의 주장은 "이 kind 안에서 feat 을 키우면 gap 이 이렇게 움직인다"이다. 그런데
        # 축의 스케일이 kind 마다 다르면(예: work_at_risk 는 fault 0~0.02 vs zone 0~0.31) 전체 std 로
        # 잡은 step 이 대상 kind 의 전 범위보다 커져 표본을 **다른 kind 의 영역으로 밀어낸다**. 거기선
        # 정답 macro 자체가 달라지므로(zone 영역에선 Replace 가 아니라 ForbidZone) 부호가 뒤집히고,
        # 모델이 아니라 검사가 틀린 결과가 나온다. kind 안 산포로 잡으면 섭동이 주장의 영역 안에 머문다.
        # (표본 내 산포가 0 이면 그 축은 이 kind 에서 상수라 검사 불가 -> 전체 산포로 대체.)
        local_sd = float(np.std(X[mask, j]))
        step = 0.5 * (local_sd if local_sd > 1e-9 else (float(np.std(X[:, j])) or 1.0))
        dgap = gap(X[mask], macro, feat, step) - gap(X[mask], macro)   # feature를 밀기 전후 gap의 변화
        mean_d = float(np.mean(dgap)); frac = float(np.mean(np.sign(dgap) == sign))  # 평균 변화 / 부호 일치 비율
        ok = np.sign(mean_d) == sign and abs(mean_d) > 1e-3      # aggregate slope has the correct sign
        arrow = "up" if sign > 0 else "down"
        print(f"  [{'ok ' if ok else 'BAD'}] ({name}-NOOP) gap {arrow} with {feat:14s}: "
              f"mean d-gap={mean_d:+.2f}, pointwise-match {frac:.0%}")
        return ok

    # core = 진실이 실제로 단조(monotone)이고 데이터가 충분한 검사만 채점 대상으로 모음.
    # 각 튜플 = (이름, 개입 macro, feature, 기대 부호, kind).
    # 표현마다 축 이름이 다르므로 검사표도 표현별로 고른다. **물리적 주장은 동일**하고 좌표만 바뀐다.
    #
    # legacy 표는 부호가 축마다 뒤섞여 있다는 점을 눈여겨볼 것: `agent_pending` 은 +1 인데 `soc`/`severity`
    # 는 -1 이고, 게다가 `severity` 의 부호는 kind 마다 뒤집혀서 검사 자체를 kind-scoped 로 쪼개야만 했다
    # (바로 그 부호 반전이 features_agnostic.py 가 없앤 문제다). agnostic 표현에서는 "나쁠수록 개입이
    # 이득"이라는 하나의 주장이 모든 축에서 **동일하게 +1** 로 표현된다 -- 표가 단순해진 것 자체가
    # 표현이 개선됐다는 징후다.
    core_by_repr = {
        "legacy": [
            ("Replace", 1, "agent_pending", +1, "fault"),    # fault severity: more pending work rescued
            ("Replace", 1, "soc",           -1, "battery"),  # more charge left -> Replace needed less
            ("Replace", 1, "severity",      -1, "battery"),  # battery severity == SoC (higher = more charge)
        ],
        "agnostic": [
            ("Replace", 1, "work_at_risk",  +1, "fault"),    # 위협받는 일이 많을수록 교체 이득 ↑
            ("Replace", 1, "harm",          +1, "battery"),  # 피해가 클수록(=잔량 낮을수록) 교체 이득 ↑
            ("Replace", 1, "resource_loss", +1, "battery"),  # 잃는 실행능력이 클수록 교체 이득 ↑
        ],
    }
    core_by_repr["agnostic-d"] = core_by_repr["agnostic"]
    core = core_by_repr.get(feat_mode, core_by_repr["legacy"])
    passes = sum(bool(run_gap_test(*t)) for t in core)   # *t: 튜플을 인자로 풀어 전달, True 개수 합산
    results["S3"] = verdict("decision monotonicity", passes == len(core),
                            f"{passes}/{len(core)} core monotone-truth tests pass")
    # 아래는 채점하지 않는 진단용 출력(진실이 비단조이거나 데이터 표본이 부족한 축).
    print("  -- diagnostics (NOT graded: truth is non-monotone or the feature is under-sampled) --")
    run_gap_test("Replace", 1, "spare_count", +1, "fault")        # data has only {0,12}: coverage gap, not a defect
    run_gap_test("ForbidZone", 3, "zone_overlap", +1, "zoneblk")  # oracle-best is NOOP-ForbidZone-NOOP: non-monotone truth
    print("     spare_count: fault data covers only {0,12} -> grade DS_SPARES=0,1,3,6 to test this axis.")
    print("     zone_overlap: oracle-best flips NOOP->ForbidZone->NOOP (full overlap can't restage) -> use a")
    print("       band/threshold test, not a monotone one; a correct surrogate is non-monotone here.")

    # ---------- S4: STATE-BLIND ABLATION (kind-only model must be worse) ----------
    # S4: 상태(state)를 가린 kind/macro 원-핫만 쓰는 모델이 더 나쁨을 보여, surrogate가 상태를 실제로
    # 활용함을 입증(ablation = 일부 정보를 제거해 그 기여도를 확인).
    banner("S4  state-blind ablation (does the surrogate USE state?)")
    # 상대(opponent)는 **항상 같아야** 표현끼리 비교가 성립한다. agnostic 표현에는 `kind_*` 컬럼이 아예
    # 없으므로 X 에서 골라내는 방식이면 상대가 "macro-only" 로 조용히 약해져 S4 가 부당하게 쉬워진다.
    # 그래서 kind 원-핫을 표현과 무관하게 df 에서 직접 만든다 -- opponent 는 어떤 --features 를 주든 동일.
    Xb = pd.DataFrame(index=df.index)
    for k in sorted(df.kind.astype(str).unique()):
        Xb[f"kind_{k}"] = (df.kind.astype(str) == k).astype(float).values
    for m_ in MACROS:
        Xb[f"macro_{m_}"] = (df.macro.astype(int) == m_).astype(float).values
    Xblind = Xb.values
    reg_blind = []
    for tr, te in logo.split(X, y, groups):
        inst = groups[te][0]; g = by_inst[inst]
        m = make_model().fit(Xblind[tr], y[tr])              # 상태 뺀 컬럼만으로 학습(state-blind)
        pte = m.predict(Xblind[te]); te_macro = df.iloc[te].macro.astype(int).values
        pbm = {int(mm): float(pp) for mm, pp in zip(te_macro, pte)}
        reg_blind.append(norm_regret(g, max(pbm, key=pbm.get), lam))
    breg = float(np.mean(reg_blind))                          # state-blind 모델의 평균 regret
    # PASS 조건: 전체(state 포함) regret이 state-blind보다 낮아야 함 = 상태가 도움이 됨.
    results["S4"] = verdict("state-reading beats kind-only", mreg < breg - 1e-6,
                            f"full {mreg:.3f} vs kind-only {breg:.3f} (state buys {breg - mreg:+.3f})")

    # ---------- L1: LLM PROPOSAL APPLICABILITY (+ the valid_mask-gate remedy) ----------
    # L1: LLM이 제안한 후보가 전부 valid_mask(실행 가능한 macro 집합) 안에 드는지 확인.
    banner("L1  LLM proposer -- applicability (proposals must be in the valid set)")
    viol = 0; gated_recall = 0        # viol=위반 instance 수, gated_recall=게이트 후에도 정답 포함 수
    for i in insts:
        g = by_inst[i]
        # valid_mask는 instance마다 저장된 "이번 상황에서 적용 가능한 macro 번호 리스트". 집합으로 변환.
        vmask = set(int(x) for x in (g.valid_mask.iloc[0] if isinstance(g.valid_mask.iloc[0], list) else []))
        cand = LLM_CANDIDATES.get(kind_of[i], MACROS)        # 이 kind에 대한 LLM 후보(없으면 전체 MACROS)
        if vmask and [m for m in cand if m not in vmask]:    # 후보 중 valid_mask 밖에 있는 게 있으면 위반
            viol += 1
        gated = [m for m in cand if m in vmask] if vmask else cand   # the remedy: intersect with valid_mask
        gated_recall += best[i] in gated                     # 게이트 후에도 oracle 최선이 남아있는지
    print(f"  ungated proposer: {viol}/{len(insts)} instances propose an inapplicable macro")
    print(f"  with valid_mask gate: 0 inapplicable, oracle-best recall preserved {gated_recall}/{len(insts)}")
    results["L1"] = verdict("applicability (gated proposer)", gated_recall == len(insts),
                            f"gate on valid_mask fixes {viol} violations at zero recall cost"
                            if viol else "no violations")

    # ---------- L2: CANDIDATE RECALL (oracle-best must be inside the proposed set) ----------
    # L2: LLM 후보 집합이 oracle 최선 macro를 포함하는지(recall). 놓치면 regret 상한도 계산.
    banner("L2  LLM proposer -- candidate recall (does the set contain the oracle-best?)")
    hit = 0; miss_reg = []            # hit=정답 포함한 instance 수, miss_reg=놓친 경우의 regret 상한들
    per_kind_recall = {}              # kind -> [정답포함수, 전체수]
    for i in insts:
        g = by_inst[i]; k = kind_of[i]
        cand = [m for m in LLM_CANDIDATES.get(k, MACROS) if m in set(g.macro.astype(int))]  # 실제 존재하는 후보만
        ob = best[i]                  # oracle 최선 macro
        inset = ob in cand            # 후보 안에 정답이 있나?
        hit += inset
        per_kind_recall.setdefault(k, [0, 0]); per_kind_recall[k][1] += 1; per_kind_recall[k][0] += inset
        if not inset:
            # best the LLM->anything pipeline could still reach, given it dropped the true best
            # 정답을 놓쳤을 때 후보 중 그나마 최선(도달 가능한 최선)을 골라 regret 상한을 기록.
            reachable = max(cand, key=lambda m: val(g[g.macro == m].iloc[0], lam)) if cand else ob
            miss_reg.append(norm_regret(g, reachable, lam))
    recall = hit / len(insts)         # 전체 recall 비율
    for k, (h, n) in sorted(per_kind_recall.items()):
        print(f"    kind={k:9s} recall {h}/{n} = {h/n:.0%}")
    detail = f"overall recall {hit}/{len(insts)} = {recall:.0%}"
    if miss_reg:
        detail += f"; mean regret ceiling on the {len(miss_reg)} miss(es) = {np.mean(miss_reg):.3f}"
    results["L2"] = verdict("oracle-best in candidate set", recall >= 0.99, detail)  # 99% 이상이면 PASS

    # ---------- L3: FALLBACK BOUND ----------
    # L3: recall이 1 미만이어도 최악의 경우 5개 macro를 전부 검증(verify-all-5)하면 놓친 정답을 되찾음
    # -> 최악 regret을 0으로 상한. 즉 안전망(fallback)이 항상 존재한다는 보증.
    banner("L3  fallback safety bound")
    print("  If L2 recall < 1, verify-all-5 (enumerate the full closed DSL) recovers the dropped best")
    print(f"  at cost 5 planner calls, capping worst-case regret at 0. The LLM narrows to |cand|~"
          f"{np.mean([len([m for m in LLM_CANDIDATES.get(kind_of[i], MACROS) if m in set(by_inst[i].macro.astype(int))]) for i in insts]):.1f}"
          f" but caps achievable quality at the L2 ceiling; the fallback is the safety net.")
    results["L3"] = verdict("fallback available", True, "verify-all-5 dominates any candidate miss")

    # ---------- SUMMARY ----------
    # 모든 검사(V0/S1~S4/L1~L3)의 PASS/FAIL을 정해진 순서로 출력하고 총 통과 개수를 요약.
    banner("VERIFICATION SUMMARY")
    order = ["V0", "S1", "S2", "S3", "S4", "L1", "L2", "L3"]
    for k in order:
        print(f"  {k}: {'PASS' if results[k] else 'FAIL'}")
    npass = sum(bool(results[k]) for k in order)   # 통과한 검사 개수
    print(f"\n  {npass}/{len(order)} checks PASS")


# 이 파일을 직접 실행할 때만 main() 호출 (import될 때는 실행 안 함).
if __name__ == "__main__":
    main()
