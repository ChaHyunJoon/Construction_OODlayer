#!/usr/bin/env python3
"""SurrogateV2 평가 하니스 — G1·G2 regret + G3·G4·G4b 게이트 + Ridge 베이스라인 (spec §3.6, §4).

무엇을 재는가
=============
  G1   leave-one-INSTANCE-out decision regret   (`LeaveOneGroupOut`, group=instance)
  G2   leave-one-KIND-out    decision regret    (`LeaveOneGroupOut`, group=kind)
       — **일반화 주장의 유일한 근거**. G1 은 같은 kind 의 다른 instance 를 이미 봤다.
  G3   상수 정책("항상 Replace"...)보다 엄격히 나은가      (surrogate_gates 를 그대로 호출)
  G4   kind 별 답 분포가 갈리는가                          (surrogate_gates 를 그대로 호출)
  G4b  **같은 legal menu 안에서 답이 갈리는가**            (surrogate_gates 를 그대로 호출)

**G4b 가 이 평가의 결론이다.** 2026-08-13 배포 결함의 실제 모양은 "kind 를 못 가린다"가
아니라 "**menu 안 최대 MACRO_COST 팔**을 861/861 로 고른다"였다 — kind 마다 menu 가
서로소면 G4 는 그 결함을 통과시킨다(판별력의 착시). G4b 는 kind 를 안 보고 menu 로만 묶어
같은 menu 안에서 답이 갈리는지 직접 묻는다. G4 만 통과하는 것은 아무것도 증명하지 않는다.

라벨을 개별 진실로 다루지 않는다 (이 하니스의 설계 제약)
=====================================================
독립 검증 실측: battery 라벨 45개 중 **33개가 ε=2.0 에서 뒤집힌다**(시드 간 J 산포는 중앙값
1.962 / 최대 8.542). SwapBattery 승리 39건 중 **완주로 갈린 것은 0건**이고 runner-up 마진은
0.0095~7.83 로 전부 노이즈 안이다. 그래서 이 하니스는 per-instance 정확도를 **1차 지표로
쓰지 않는다** — 내되 반드시 옆에 노이즈 바닥(`noise_floor` 블록)을 같이 낸다. 살아남는 것은
집계 방향(45개 독립 instance 에서 SwapBattery 39승 6패, 부호검정 p=2.71e-07)이다.

행 로딩·필터링 계약 (Task 4·5 가 발견한 제약, 이 파일이 그 호출자다)
==================================================================
  1. `e1_analyze.load()` 로 읽는다 — `makespan` 143행이 JSON 문자열 `"Inf"`, `soc`/
     `zone_radius` 220/235행이 `"NaN"` 이다. pandas 로 직접 읽으면 object-dtype 문자열
     컬럼이 되어 조용히 오염된다.
  2. `fired == False` 인 10행(미발화 control stub — `complete=true`·`closed=279`·유한한
     `energy_J` 를 달고 있다)을 **버린다**. `complete` 로만 거르면 "아무것도 발화 안 했는데
     완주했다"를 학습 데이터로 먹는다. `surrogate_features.build_features` 는 의도적으로
     필터링을 하지 않는다(Task 5 의 문서화·검사된 계약) — **그 책임은 이 호출자 것이다.**
  3. 학습셋은 `wm_datasets.RELABEL_20260814` **뿐이다**. `n44_plus78` 로 폴백하지 않는다 —
     그 파일은 행동 어휘 두 세대를 concat 한 것이라, 그 라벨이 이 계획이 제거하려는 결함을
     그대로 가르친다. 그래서 `wm_datasets.resolve()`(=$WM_DATASET 을 읽는다)를 쓰지 않고
     상수를 직접 쓴다 — 환경변수 하나로 조용히 다른 파일이 들어오는 경로를 원천 차단한다.

상수는 전부 `objective.load()` 로 읽는다(`audit_objective.py` 항목 1 이 리터럴을 스캔한다).
진실 점수는 `e1_analyze.cost_lex_key_row`(= `-objective.J_row`)를 **import 해서** 쓴다.
"""
import argparse
import json
import math
import os
import sys
import warnings
from collections import Counter, defaultdict

import numpy as np
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.model_selection import LeaveOneGroupOut
from threadpoolctl import threadpool_limits

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e1_analyze                                        # noqa: E402
import objective                                         # noqa: E402
import wm_datasets                                       # noqa: E402
from surrogate_features import build_features            # noqa: E402
from surrogate_gates import (gate_g3_beats_constant,     # noqa: E402
                             gate_g4_kind_discrimination,
                             gate_g4b_menu_invariance,
                             max_cost_menu_policy)
from surrogate_v2 import SurrogateV2                     # noqa: E402

# scipy/sklearn 버전 궁합에서 나오는 무해한 경고. 폴드가 310개라 이걸 안 막으면 실제 결과가
# 수백 줄 경고에 묻힌다(로그를 못 읽으면 결과를 못 읽는다). 이 한 종류만 좁게 막는다.
warnings.filterwarnings("ignore", message="Unknown solver options: iprint")

# 노이즈 바닥. 독립 검증이 잰 시드 간 J 산포(중앙값 1.962)와 라벨 뒤집힘 임계(ε=2.0)에서 왔다.
# per-instance 수치는 전부 이 값과 **같이** 보고한다 — 단독으로 쓰면 노이즈를 맞춘 것이 된다.
NOISE_EPS = 2.0


# ==========================================================================================
#  베이스라인 — spec §3.6: "선형이 이기면 트리를 쓸 이유가 없다" (현행 22차원/355행 = 16.1행/feature)
# ==========================================================================================
class RidgeJ(SurrogateV2):
    """단일 헤드 선형: 2-헤드 구조 없이 J 를 그대로 회귀한다.

    `SurrogateV2` 를 상속해 `predict_delta_J`(같은 instance 의 NOOP 기준 차감)를 **그대로**
    물려받는다 — 결정 규칙이 동일해야 비교가 모델 클래스 차이만 재기 때문이다.
    """

    def __init__(self, cfg=None):
        super().__init__(cfg)
        self.head = Ridge(alpha=1.0)

    def fit(self, rows):
        self.head.fit(build_features(rows).values,
                      np.array([objective.J_row(r, cfg=self.cfg) for r in rows], dtype=float))
        return self

    def predict_J(self, rows):
        return np.asarray(self.head.predict(build_features(rows).values), dtype=float)


class LinearTwoHead(SurrogateV2):
    """2-헤드 구조는 그대로 두고 **추정기만** 선형으로 바꾼 것.

    RidgeJ 와 SurrogateV2 의 차이는 (구조 + 모델 클래스) 두 가지가 동시에 다르다.  이 변종이
    구조를 고정하고 클래스만 바꾸므로, "선형이 이기는가"라는 §3.6 의 질문에 실제로 답한다.
    조립식(Ĵ = P·B + (1−P)·(C_fail + C_unclosed·C + tie_eps·B))과 상수는 상속받은 그대로다.
    """

    def __init__(self, cfg=None):
        super().__init__(cfg)
        self.head_a = LogisticRegression(max_iter=2000)
        self.head_b = Ridge(alpha=1.0)
        self.head_c = Ridge(alpha=1.0)


MODELS = {"tree2h": SurrogateV2, "ridge": RidgeJ, "linear2h": LinearTwoHead}


# ==========================================================================================
#  데이터
# ==========================================================================================
def load_rows(path):
    """라벨 파일 -> 행 dict 목록. 위 docstring 의 로딩 계약 1·2 를 여기서 집행한다."""
    if not os.path.exists(path):
        raise SystemExit("라벨 파일이 없다: %s — 폴백하지 않는다(n44_plus78 금지)." % path)
    df = e1_analyze.load(path)                       # 계약 1: "Inf"/"NaN" 문자열 복원
    if "fired" not in df.columns:
        raise SystemExit("라벨에 `fired` 열이 없다 — stub 10행을 거를 수 없다. 조용히 넘어가지 않는다.")
    n_all = len(df)
    df = df[df["fired"] == True]                     # noqa: E712  계약 2: 미발화 stub 제거
    rows = df.to_dict("records")
    for r in rows:                                   # numpy 스칼라를 파이썬 값으로
        r["macro"] = int(r["macro"])
        r["complete"] = bool(r["complete"])
        r["instance"] = str(r["instance"])
        r["kind"] = str(r["kind"])
        r["valid_mask"] = [int(m) for m in r["valid_mask"]]
    return rows, {"path": path, "rows_in_file": n_all, "rows_after_fired_filter": len(rows),
                  "dropped_unfired_stubs": n_all - len(rows),
                  "instances": len(set(r["instance"] for r in rows)),
                  "objective_hash": objective.objective_hash()}


def group_by_instance(rows):
    """instance -> 그 instance 의 행 목록(파일 순서 유지)."""
    out = defaultdict(list)
    for r in rows:
        out[r["instance"]].append(r)
    return out


def truth_table(rows):
    """instance -> {macro: -J(row)}.  클수록 좋다.

    `e1_analyze.cost_lex_key_row` 를 그대로 부른다 — 재구현 금지(spec §3.2 의 λ 제거와
    에너지 항이 그 안에 들어 있고, 구세대 덤프에서는 시끄럽게 멈춰야 한다).
    """
    out = {}
    for iid, g in group_by_instance(rows).items():
        out[iid] = {r["macro"]: float(e1_analyze.cost_lex_key_row(r)) for r in g}
    return out


# ==========================================================================================
#  폴드 실행
# ==========================================================================================
def max_cost_policy(rows_by_inst):
    """**진짜 바닥선**: legal menu 안에서 `MACRO_COST` 가 최대인 팔을 고르는 상태맹 규칙.

    이것이 2026-08-13 배포 결함 그 자체다(861/861 결정이 이 규칙과 일치했다). 학습이 0 이고
    상태를 한 비트도 안 보므로, **모델이 이것을 J 로 이기지 못하면 학습에 값이 없다.**

    G3 로는 이 바닥선을 볼 수 없다: G3 는 단일 팔 상수 정책만 열거하고 그 팔이 불법인
    instance 에는 최대 regret 을 물린다. 팔 1 은 155개 중 90개에서 불법이라, G3 의 "최고 상수"
    는 실제로 아무도 쓰지 않을 정책이고 그에 대한 마진은 사실상 공허하다.
    규칙 자체는 재구현하지 않고 `surrogate_gates.max_cost_menu_policy` 를 부른다 — 그 모듈이
    이 규칙의 단일 정의를 갖고 있고, 복사본을 만들면 G4b 진단과 이 바닥선이 조용히 갈린다.
    """
    return {iid: int(max_cost_menu_policy(sorted(set(g[0]["valid_mask"]))))
            for iid, g in rows_by_inst.items()}


def run_folds(rows, group_key, model_name, rule="argmin_jhat"):
    """`LeaveOneGroupOut` 으로 out-of-sample 결정을 만든다.

    반환: {instance: 고른 macro}.  팔 선택은 그 instance 의 legal 행에 대해 `rule` 로 한다
    (`SurrogateV2.choose`). (행 집합 == `valid_mask` 임은 main 의 sanity 검사가 확인한다.)
    """
    groups = np.array([r[group_key] for r in rows])
    idx = np.arange(len(rows))
    choices = {}
    # 스레드를 1로 묶는다. 355행짜리 학습에 OpenMP 가 코어 수만큼 스레드를 띄우면 공유 서버에서
    # 경합으로 **HGB 1회 학습이 132초** 걸린다(실측). 1스레드에서 0.58초 — 227배다. 폴드가
    # 155개라 이 한 줄이 "10분 타임아웃"과 "2분"을 가른다. 결과값에는 영향이 없다(HGB 는
    # random_state 고정, Ridge/LogReg 는 결정적) — 재현성은 아래 self-check 로 확인한다.
    with threadpool_limits(limits=1):
        for tr, te in LeaveOneGroupOut().split(idx, groups=groups):
            train = [rows[i] for i in tr]
            test = [rows[i] for i in te]
            model = MODELS[model_name]().fit(train)
            choices.update(model.choose(test, rule=rule))
    return choices


def regrets(truth, choices):
    """instance -> regret = (최적 진실점수) − (고른 팔의 진실점수).  0 이면 완벽."""
    out = {}
    for iid, t in truth.items():
        c = choices.get(iid)
        out[iid] = float(max(t.values()) - t.get(c, min(t.values())))
    return out


def summarize(reg, rows_by_inst, choices, truth):
    """평균 regret + **노이즈 바닥과 함께 보는** per-instance 보조 지표."""
    vals = np.array([reg[i] for i in sorted(reg)], dtype=float)
    kind_of = {i: g[0]["kind"] for i, g in rows_by_inst.items()}
    per_kind = {}
    for k in sorted(set(kind_of.values())):
        ids = [i for i in sorted(reg) if kind_of[i] == k]
        v = np.array([reg[i] for i in ids])
        per_kind[k] = {
            "n": len(ids),
            "mean_regret": float(v.mean()),
            "median_regret": float(np.median(v)),
            "exact_match_rate": float(np.mean(v <= 0.0)),
            "match_rate_within_noise": float(np.mean(v <= NOISE_EPS)),
            "choice_dist": dict(Counter(choices[i] for i in ids)),
            "truth_argmax_dist": dict(Counter(max(truth[i], key=truth[i].get) for i in ids)),
        }
    # **완주 레짐별 분해** — 이 데이터에서 가장 중요한 층위다.
    # 155개 중 53개는 **어떤 팔로도 완주하지 못한다**. 그 instance 에서는 모든 팔의 P(complete)
    # 가 사실상 0 이라 헤드 A 가 상수이고(2-헤드 전제가 죽어 있다), 팔 간 진짜 J 차이는 전부
    # C_unclosed·Δ(미닫힘 노드) 다 — 즉 **헤드 C 만이 순위를 매길 수 있다**. 두 레짐을 섞어
    # 평균 내면 서로 다른 두 문제의 성적이 하나의 숫자로 뭉개진다.
    regime = {}
    for tag, want in (("has_completing_arm", True), ("no_completing_arm", False)):
        ids = [i for i in sorted(reg)
               if any(bool(r["complete"]) for r in rows_by_inst[i]) is want]
        v = np.array([reg[i] for i in ids], dtype=float)
        regime[tag] = {"n": len(ids),
                       "mean_regret": float(v.mean()) if len(v) else None,
                       "median_regret": float(np.median(v)) if len(v) else None}

    # 큰 regret 을 세되 **이름을 조심한다**. 2026-08-14 정정: 이 데이터에서 큰 regret 은
    # 완주 절벽(C_fail)을 넘어서 생긴 것이 **아니다** — 그런 instance 들은 어떤 팔로도 완주하지
    # 못하므로 두 팔 모두 미완주 분기에 있고, regret 은 전부 C_unclosed × Δ(미닫힘 노드) 다.
    # 예전 이름 `n_completion_decided_losses` 는 "완주가 갈랐다"는 **틀린 서사**를 심었다.
    big = float(objective.load()["C_fail"]) / 2.0
    return {
        "by_completion_regime": regime,
        "mean_regret": float(vals.mean()),
        "median_regret": float(np.median(vals)),
        "n_instances": int(len(vals)),
        "exact_match_rate": float(np.mean(vals <= 0.0)),
        "match_rate_within_noise": float(np.mean(vals <= NOISE_EPS)),
        "mean_regret_above_noise": float(np.mean(np.maximum(vals - NOISE_EPS, 0.0))),
        "n_regret_above_half_C_fail": int(np.sum(vals > big)),
        "n_regret_above_half_C_fail_note": (
            "완주로 갈린 것이 아니다 — 이 instance 들은 어느 팔로도 완주하지 못하고, "
            "regret 은 전부 C_unclosed × Δ(미닫힘 노드) 다."),
        "per_kind": per_kind,
    }


def compare_to_baseline(reg_model, reg_base, top=5):
    """모델 regret 을 바닥선 regret 과 **instance 단위로** 분해한다.

    왜 평균만으로는 안 되는가: 이 데이터에서 총 regret 은 소수의 거대 항이 지배한다. 평균 차이
    하나만 보면 "전반적으로 못한다"와 "한 건에서 크게 틀렸다"가 구분되지 않는데, 둘은 전혀
    다른 진단이고 처방도 다르다. 그래서 이긴/진/비긴 instance 수와 가장 큰 손실을 같이 낸다.
    (해석 주의: 최악의 한 건을 빼면 이긴다는 것은 **변명이 아니다** — 그 한 건이 데이터셋에서
    가장 큰 오차이고 바닥선은 그것을 피한다.)
    """
    ids = sorted(reg_model)
    diff = {i: reg_model[i] - reg_base[i] for i in ids}
    losses = sorted(((d, i) for i, d in diff.items() if d > 0), reverse=True)[:top]
    return {
        "total_regret_model": float(sum(reg_model.values())),
        "total_regret_baseline": float(sum(reg_base.values())),
        "total_gap": float(sum(diff.values())),
        "n_worse_than_baseline": int(sum(1 for d in diff.values() if d > 0)),
        "n_better_than_baseline": int(sum(1 for d in diff.values() if d < 0)),
        "n_tied": int(sum(1 for d in diff.values() if d == 0)),
        "largest_losses": [{"instance": i, "excess_regret": float(d)} for d, i in losses],
    }


def noise_floor_block(truth):
    """라벨 자체의 노이즈 바닥 — per-instance 수치를 읽을 때 **반드시 옆에 두어야 하는 값**.

    `label_margin` = (최적 진실점수) − (차선 진실점수).  이 값이 ε 보다 작으면 그 instance 의
    "정답"은 시드 노이즈 안에서 뒤집힌다 — 그 instance 를 맞혔는지 틀렸는지는 정보가 아니다.
    """
    margins = []
    for t in truth.values():
        v = sorted(t.values(), reverse=True)
        margins.append(float(v[0] - v[1]) if len(v) > 1 else float("inf"))
    m = np.array([x for x in margins if math.isfinite(x)], dtype=float)
    return {
        "eps": NOISE_EPS,
        "eps_provenance": ("독립 검증 실측: 시드 간 J 산포 중앙값 1.962 / 최대 8.542, "
                           "battery 라벨 45개 중 33개가 ε=2.0 에서 뒤집힘"),
        "n_instances": int(len(margins)),
        "median_label_margin": float(np.median(m)),
        "n_label_margin_below_eps": int(np.sum(m < NOISE_EPS)),
        "frac_label_margin_below_eps": float(np.mean(m < NOISE_EPS)),
        "note": ("이 비율만큼의 instance 에서 per-instance 정확도는 노이즈를 재는 것이다. "
                 "집계 방향(부호검정)과 마진 가중 결과만 해석한다."),
    }


def duplicate_pairs(rows_by_inst):
    """kind 라벨이 다른데 **공유 팔의 결과가 전부 동일**한 instance 쌍을 찾는다.

    라벨 안에 battery/fault 구별불가 결함이 그대로 들어 있다는 증거다(독립 검증이 5쌍 보고).
    G2(leave-one-KIND-out)에서 battery 를 빼도 그 쌍둥이가 fault 쪽에 남아 **누출**된다 —
    숨기지 않고 세어서 보고한다.
    """
    fp = {}
    for iid, g in rows_by_inst.items():
        arms = {}
        for r in g:
            ms = float(r["makespan"])
            arms[r["macro"]] = (bool(r["complete"]), int(r["closed"]),
                                "inf" if not math.isfinite(ms) else round(ms, 3),
                                round(float(r["energy_J"]), 3))
        fp[iid] = (g[0]["kind"], arms)
    ids = sorted(fp)
    pairs = []
    for a in range(len(ids)):
        for b in range(a + 1, len(ids)):
            ka, aa = fp[ids[a]]
            kb, ab = fp[ids[b]]
            if ka == kb:
                continue
            shared = sorted(set(aa) & set(ab))
            if len(shared) >= 2 and all(aa[m] == ab[m] for m in shared):
                pairs.append({"a": ids[a], "kind_a": ka, "b": ids[b], "kind_b": kb,
                              "shared_arms": shared})
    return pairs


def sign_test_direction(truth, arm, rival):
    """집계 방향: `arm` 이 `rival` 을 이긴 instance 수 / 진 수 (둘 다 legal 한 instance 만).

    per-instance 라벨은 노이즈 안이지만 **부호의 집계**는 살아남는다(브리프의 39승 6패).
    """
    win = loss = tie = 0
    for t in truth.values():
        if arm in t and rival in t:
            if t[arm] > t[rival]:
                win += 1
            elif t[arm] < t[rival]:
                loss += 1
            else:
                tie += 1
    return {"arm": arm, "rival": rival, "wins": win, "losses": loss, "ties": tie,
            "n": win + loss + tie}


# ==========================================================================================
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    # 기본값은 상수 직접 참조다 — `wm_datasets.resolve()` 를 쓰지 않는 이유는 docstring 계약 3.
    ap.add_argument("--labels", default=wm_datasets.abspath(wm_datasets.RELABEL_20260814))
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--g4-tau", type=float, default=0.05)
    ap.add_argument("--g4b-min-group", type=int, default=5)
    args = ap.parse_args()

    rows, meta = load_rows(args.labels)
    by_inst = group_by_instance(rows)
    truth = truth_table(rows)

    # sanity: 이 instance 에서 관측된 팔 == legal menu. 어긋나면 argmin 이 불법 팔을 고를 수 있다.
    for iid, g in by_inst.items():
        if sorted(set(r["macro"] for r in g)) != sorted(set(g[0]["valid_mask"])):
            raise SystemExit("instance %s: 관측된 팔과 valid_mask 가 다르다 — menu 정의가 무너진다" % iid)

    kinds = Counter(g[0]["kind"] for g in by_inst.values())
    print("== eval_surrogate_v2 ==")
    print("  %s" % wm_datasets.describe(args.labels))
    print("  %(rows_in_file)d행 -> fired 필터 후 %(rows_after_fired_filter)d행 / "
          "%(instances)d instance (stub %(dropped_unfired_stubs)d행 제거)" % meta)
    print("  kind별 instance: %s" % dict(sorted(kinds.items())))
    print("  objective_hash=%s" % meta["objective_hash"])

    result = {"dataset": dict(meta, instances_by_kind=dict(sorted(kinds.items()))),
              "noise_floor": noise_floor_block(truth)}

    dups = duplicate_pairs(by_inst)
    result["cross_kind_duplicates"] = {
        "n_pairs": len(dups), "pairs": dups,
        "note": ("공유 팔의 결과가 바이트 동일한데 kind 라벨이 다르다 = battery/fault 구별불가 "
                 "결함이 라벨 자체에 있다. G2 에서 한 kind 를 빼도 쌍둥이가 다른 kind 에 남아 "
                 "누출된다 — G2 는 그만큼 낙관적이다."),
    }

    # ---- 상태맹 바닥선: menu 안 max-MACRO_COST 규칙 (학습 0, 배포 결함 그 자체) ---------
    mc_choices = max_cost_policy(by_inst)
    mc_reg = regrets(truth, mc_choices)
    result["baseline_max_cost_rule"] = dict(
        summarize(mc_reg, by_inst, mc_choices, truth),
        note=("legal menu 안 MACRO_COST 최댓값 팔. 학습이 0 이고 상태를 안 본다. "
              "**모델이 이겨야 하는 실제 바닥선** — G3 의 단일팔 상수 정책은 이것을 못 본다."))

    # ---- 모델별 G1 / G2 -------------------------------------------------------------
    # tree2h 는 두 결정 규칙 모두로 돈다: argmin Ĵ (원래 규칙, 기준선으로 계속 보고) 와
    # deadband_B (조립식 증폭 교정). 베이스라인 모델은 원래 규칙만 — RidgeJ 에는 헤드 A/B 가 없다.
    runs = [("tree2h", "argmin_jhat", ""), ("tree2h", "deadband_B", "_deadband"),
            ("tree2h", "deadband_Jbar", "_deadbandJbar"),
            ("ridge", "argmin_jhat", ""), ("linear2h", "argmin_jhat", "")]
    choices_by_run = {}
    for name, rule, suffix in runs:
        for gate, key in (("instance", "G1"), ("kind", "G2")):
            print("  ... %s / %s %s (leave-one-%s-out)" % (name, rule, key, gate))
            ch = run_folds(rows, gate, name, rule=rule)
            choices_by_run[(name, rule, gate)] = ch
            reg = regrets(truth, ch)
            s = summarize(reg, by_inst, ch, truth)
            s["vs_max_cost_baseline"] = compare_to_baseline(reg, mc_reg)
            base = key if name == "tree2h" else ("%s_%s" % (name, key))
            result[base + suffix] = s
    loio_choices = choices_by_run[("tree2h", "argmin_jhat", "instance")]
    loko_choices = choices_by_run[("tree2h", "argmin_jhat", "kind")]
    dead_loio = choices_by_run[("tree2h", "deadband_B", "instance")]
    deadj_loio = choices_by_run[("tree2h", "deadband_Jbar", "instance")]

    # ---- G3 / G4 / G4b — 게이트는 import 해서 **그대로** 부른다 -----------------------
    inst_recs = [{"instance": i, "kind": g[0]["kind"], "truth": truth[i],
                  "valid": sorted(set(g[0]["valid_mask"]))} for i, g in sorted(by_inst.items())]
    oracle_choices = {i: max(t, key=t.get) for i, t in truth.items()}

    def _dec(ch):
        return [{"instance": i, "menu": sorted(set(g[0]["valid_mask"])), "choice": ch[i]}
                for i, g in sorted(by_inst.items())]

    ok3, i3 = gate_g3_beats_constant(inst_recs, loio_choices)
    ok4, i4 = gate_g4_kind_discrimination(inst_recs, loio_choices, tau=args.g4_tau)
    # G4b 는 2026-08-14 부터 오라클을 받는다: 정보성 조건 + 최빈답 일치 절이 켜진다.
    ok4b, i4b = gate_g4b_menu_invariance(_dec(loio_choices), min_group=args.g4b_min_group,
                                         oracle_choices=oracle_choices)
    _basis = "leave-one-instance-out choices"
    result["G3"] = dict(i3, **{"pass": ok3, "basis": _basis})
    result["G4"] = dict(i4, **{"pass": ok4, "basis": _basis})
    result["G4b"] = dict(i4b, **{"pass": ok4b, "basis": _basis})

    # G4b 는 이 평가의 결론이므로 LOKO 결정과 **교정된 결정 규칙**에 대해서도 낸다.
    ok4b_k, i4b_k = gate_g4b_menu_invariance(_dec(loko_choices), min_group=args.g4b_min_group,
                                             oracle_choices=oracle_choices)
    result["G4b_loko"] = dict(i4b_k, **{"pass": ok4b_k, "basis": "leave-one-KIND-out choices"})

    ok4b_d, i4b_d = gate_g4b_menu_invariance(_dec(dead_loio), min_group=args.g4b_min_group,
                                             oracle_choices=oracle_choices)
    result["G4b_deadband"] = dict(i4b_d, **{
        "pass": ok4b_d, "basis": "leave-one-instance-out choices, deadband_B 결정 규칙"})

    ok4b_dj, i4b_dj = gate_g4b_menu_invariance(_dec(deadj_loio), min_group=args.g4b_min_group,
                                               oracle_choices=oracle_choices)
    result["G4b_deadband_jbar"] = dict(i4b_dj, **{
        "pass": ok4b_dj, "basis": "leave-one-instance-out choices, deadband_Jbar 결정 규칙"})

    # 오라클 대조군은 게이트가 그것을 내부에서 쓰게 된 뒤에도 **따로 낸다** — 어떤 menu 가
    # 왜 판정에서 빠졌는지가 출력에 남아야 읽는 사람이 검증할 수 있다.
    ok4b_o, i4b_o = gate_g4b_menu_invariance(_dec(oracle_choices), min_group=args.g4b_min_group,
                                             oracle_choices=oracle_choices)
    result["G4b_oracle"] = dict(i4b_o, **{
        "pass": ok4b_o, "basis": "oracle (argmax -J) choices — 게이트의 달성 가능 상한",
        "note": ("여기서 퇴화한 menu 는 정답이 상수인 menu 다. 게이트가 이제 그 menu 를 "
                 "uninformative 로 판정에서 빼므로 오라클은 **통과해야 한다** — 통과하지 "
                 "않으면 게이트에 아직 거짓 양성이 남아 있다는 뜻이다.")})

    # ---- 집계 방향 (per-instance 라벨이 아니라 이것이 살아남는 신호다) -----------------
    result["aggregate_direction"] = {
        "truth_swapbattery_vs_replace": sign_test_direction(truth, 8, 1),
        "truth_swapbattery_vs_noop": sign_test_direction(truth, 8, 0),
        "note": ("진실 라벨의 집계 방향. 모델이 같은 방향을 내는지는 G1/G2 의 "
                 "per_kind.choice_dist 와 대조한다."),
    }
    mc = result["baseline_max_cost_rule"]["mean_regret"]
    print("\n  ** 바닥선 ** 상태맹 max-MACRO_COST 규칙 (학습 0)   mean regret = %.4f" % mc)
    for key, label in (("G1", "G1  (LOIO, argmin Jhat  = 기준선)"),
                       ("G1_deadband", "G1  (LOIO, deadband_B)"),
                       ("G1_deadbandJbar", "G1  (LOIO, deadband_Jbar = 통합식)"),
                       ("ridge_G1", "G1  ridge"), ("linear2h_G1", "G1  linear2h"),
                       ("G2", "G2  (LOKO, argmin Jhat  = 기준선)"),
                       ("G2_deadband", "G2  (LOKO, deadband_B)"),
                       ("G2_deadbandJbar", "G2  (LOKO, deadband_Jbar = 통합식)"),
                       ("ridge_G2", "G2  ridge"), ("linear2h_G2", "G2  linear2h")):
        v = result[key]["mean_regret"]
        rg = result[key]["by_completion_regime"]
        vb = result[key]["vs_max_cost_baseline"]
        print("  %-34s mean regret = %10.4f   바닥선 대비 %-18s | 완주팔있음(n=%d) %8.3f  없음(n=%d) %9.3f"
              % (label, v, "이김 (-%.4f)" % (mc - v) if v < mc else "**짐** (+%.4f)" % (v - mc),
                 rg["has_completing_arm"]["n"], rg["has_completing_arm"]["mean_regret"],
                 rg["no_completing_arm"]["n"], rg["no_completing_arm"]["mean_regret"]))
        print("  %-34s   instance 단위 바닥선 대비: 나쁨 %d · 좋음 %d · 동률 %d   최대손실 %s"
              % ("", vb["n_worse_than_baseline"], vb["n_better_than_baseline"], vb["n_tied"],
                 ("%s +%.1f" % (vb["largest_losses"][0]["instance"],
                                vb["largest_losses"][0]["excess_regret"]))
                 if vb["largest_losses"] else "없음"))
    print("  G3  pass=%s  model=%.4f vs best-constant=%.4f (arm %s)  [단일팔 상수만 열거 — 바닥선을 못 본다]"
          % (ok3, i3["model_regret"], i3["best_constant_regret"], i3["best_constant_arm"]))
    print("  G4  pass=%s  by_kind=%s" % (ok4, i4["by_kind"]))
    for tag, ok, info in (("G4b (기준선)", ok4b, i4b), ("G4b (deadband_B)", ok4b_d, i4b_d),
                          ("G4b (deadband_Jbar)", ok4b_dj, i4b_dj),
                          ("G4b (오라클)", ok4b_o, i4b_o)):
        print("  %-16s pass=%-5s  정보성 menu 에서 퇴화=%s  최빈답 불일치=%s  (판정제외 %s)"
              % (tag, ok, info["degenerate_informative_menus"], info["modal_mismatch_menus"],
                 info["uninformative_menus"]))

    blob = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True, default=str)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(blob + "\n")
        print("\n  -> %s" % args.out)
    else:
        print("\n" + blob)
    return 0


if __name__ == "__main__":
    sys.exit(main())
