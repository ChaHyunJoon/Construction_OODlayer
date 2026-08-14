#!/usr/bin/env python3
"""eval_deployed_gates.py -- **2026-08-13 기준선 모델**에 G3(LOIO)/G4/G4b 를 물리는 동결 계측기.

⚠️ 이 파일은 "지금 배포된 모델"을 재지 않는다 (2026-08-14 최종 리뷰에서 제목·설명을 정정).
=================================================================================================
Task 2(2026-08-13)에 쓰였을 때는 **그때 배포돼 있던** 모델을 쟀다. 그 뒤 배포가 갈렸다:
  · 모델   RandomForest(`closed − λ·MACRO_COST` 회귀)  ->  `SurrogateV2`(2-헤드 조립 Ĵ)
  · 학습셋 `wm_datasets.N44_PLUS78`                     ->  `wm_datasets.RELABEL_20260814`
  · 타깃   `closed − λ·MACRO_COST` (아래 LAM)           ->  J 자신 (식별할 λ 가 없다)
이 스크립트는 아직 옛 쪽을 쓴다(`surrogate_model.build_model` · `N44_PLUS78` · `LAM = 3.0`).
**그것이 의도다**: 이 파일의 값어치는 "2026-08-13 기준선이 무엇이었는지"를 바이트 단위로
재현하는 데 있다. 현행 모델로 겨누지 말 것 — 그러면 기준선이 사라지고, 이후 결과 문서가
인용하는 숫자를 다시 만들 수 없게 된다. **현행 모델의 게이트는 `eval_surrogate_v2.py` 다.**

그래서 아래 G3 팔을 "배포 모델"이라고 부르지 않는다 — **2026-08-13 기준선 모델**이다.
(파일 이름의 `deployed` 는 그 시점의 잔재다. 이름을 바꾸지 않은 이유: Task 2·6 리포트와
결과 문서가 이 경로로 숫자의 출처를 지목한다 — 경로가 바뀌면 그 인용이 끊긴다.)

측정 대상 셋은 성격이 다르다:
  G3 (LOIO)   -- 라벨셋(`wm_datasets.N44_PLUS78`, = 그 기준선의 학습셋) 위에서
                leave-one-instance-out 으로 측정한다.
                G3 는 팔마다의 반사실적(counterfactual) truth 점수가 있어야 하는데, 배포
                로그에는 "실제로 실행한 팔의 결과"만 있고 안 고른 팔의 점수는 없다. 그래서
                G3 는 항상 라벨셋 위에서만, 그것도 **out-of-sample**로만 잰다 -- 라벨셋
                전체로 학습한 모델을 그 라벨셋에 그대로 물리는 것(in-sample)은 무효다:
                2026-08-13 에 그렇게 했다가 `kind_*` one-hot 특징 때문에 G3·G4 가 둘 다
                거짓 통과했고, 원인을 되짚어 이 스크립트로 되돌렸다.
  G4 / G4b    -- **그 시점의** 배포 서비스가 낸 스윕 로그(`--sweep-dir`, 기본
                `results_4pol/*.jsonl`, `policy=="surrogate"` 행만) 위에서 잰다. 아래
                SHA256_ANCHOR 가 그 바이트를 고정한다 — 스윕이 갱신되면 이 팔이 재는 것도
                더 이상 2026-08-13 기준선이 아니므로, 해시 경고를 무시하지 말 것.
                G4 는 truth kind 별 답 분포, G4b 는 legal menu(그 상황에서 쓸 수 있던 팔의
                집합) 별 답 분포를 본다.
                G4b 가 필요한 이유: kind 마다 legal menu 자체가 겹치지 않으면(zone/reform
                이 그랬다) G4 는 "menu 가 갈려서 답도 갈렸다"는 착시로 통과해 버릴 수 있다 --
                실측 결함은 kind 판별 실패가 아니라 **menu 안에서 항상 MACRO_COST 최댓값
                팔만 고르는 것**(861/861)이었다.

스윕 파일은 다른 작업자의 진행 중(uncommitted) 산출물이라 이 레포에는 커밋하지 않는다 --
대신 아래 SHA256_ANCHOR 로 "이 스크립트가 낸 숫자가 어떤 바이트에서 나왔는지"를 고정한다.
실행 시점에 다시 해시를 계산해 다르면 **경고만**(하드 실패 아님 -- 스윕이 갱신 중일 수
있다) stderr 에 찍고, 실제 해시는 JSON 출력의 sweep_files 에 같이 낸다.

sha256 anchors (2026-08-13, 컨트롤러의 독립 검증 패스에서 캡처):
    cd45bf7e87da75e55413854f338d8e4bc76f75568dcd334b60c28519a6ad4dbf  battery.jsonl
    50eaec80a32ec10025d64866f64e382e0cd043c55dcd23560c5f31ddbfab2328  fault.jsonl
    670527c0d7b36d5c2d5717a97794964448a8a7f91b0c3238d3cff72ad925a928  fault_battery.jsonl
    83e6d6a5b98c82dc0e66d5a4496046f90fce7b4cf30b3090eb0e4e49bef19d6e  zone.jsonl
    cb3f97eea50b02b6a361c3161b8561c9105da7e444702b74333a61fa59d5a89b  battery_zone.jsonl
    e2d2bfe513e3181bb084112393c753f75c0ee898b0333d8a499c5b5474ad327c  fault_zone.jsonl
    a2674fa16b8c0a23fc288425ed146f1c426abe65077b287f63f6207cf04da1df  all.jsonl

사용:
    python eval_deployed_gates.py [--sweep-dir results_4pol] [--out FILE.json]
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np
import pandas as pd
from sklearn.model_selection import LeaveOneGroupOut

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from surrogate_gates import (gate_g3_beats_constant, gate_g4_kind_discrimination,
                              gate_g4b_menu_invariance)
from surrogate_model import build_model
from e1_analyze import load, featurize, instance_arms_complete, MACRO_COST
import wm_datasets
import action_registry as REG

LAM = 3.0   # 보상 = closed - LAM * macro_cost. surrogate_data.py 가 쓰는 값 그대로(재선언 아님).

SWEEP_FILES = ["battery.jsonl", "fault.jsonl", "fault_battery.jsonl",
               "zone.jsonl", "battery_zone.jsonl", "fault_zone.jsonl", "all.jsonl"]

SHA256_ANCHOR = {
    "battery.jsonl":       "cd45bf7e87da75e55413854f338d8e4bc76f75568dcd334b60c28519a6ad4dbf",
    "fault.jsonl":         "50eaec80a32ec10025d64866f64e382e0cd043c55dcd23560c5f31ddbfab2328",
    "fault_battery.jsonl": "670527c0d7b36d5c2d5717a97794964448a8a7f91b0c3238d3cff72ad925a928",
    "zone.jsonl":          "83e6d6a5b98c82dc0e66d5a4496046f90fce7b4cf30b3090eb0e4e49bef19d6e",
    "battery_zone.jsonl":  "cb3f97eea50b02b6a361c3161b8561c9105da7e444702b74333a61fa59d5a89b",
    "fault_zone.jsonl":    "e2d2bfe513e3181bb084112393c753f75c0ee898b0333d8a499c5b5474ad327c",
    "all.jsonl":           "a2674fa16b8c0a23fc288425ed146f1c426abe65077b287f63f6207cf04da1df",
}


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _legal_menu(dec, truth):
    """이 decision 의 legal menu(팔 이름 집합, frozenset)를 돌려준다.

    로그의 `valid` 필드가 비어 있으면(관측 사실: FaultTruth/ReformTruth 행이 전부 이랬다)
    서비스가 실제로 쓰는 폴백 -- `action_registry.KIND_VALID[kind]` -- 으로 대신한다.
    truth 라벨(예: "FaultTruth")을 kind(예: "fault")로 바꾸는 규칙은 접미사 "Truth" 를
    떼고 소문자화하는 것뿐이다(레지스트리의 kind 이름과 일치 -- 검증됨: fault/battery/zone/reform).
    """
    valid = dec.get("valid") or []
    if valid:
        return frozenset(valid)
    kind = truth[:-len("Truth")].lower() if truth.endswith("Truth") else truth.lower()
    ids = REG.KIND_VALID.get(kind, [])
    return frozenset(REG.MACRO_NAME[i] for i in ids)


def load_deployed_decisions(sweep_dir, files):
    """스윕 로그에서 (instances_g4, choices_g4, decisions_g4b, file_info) 를 만든다."""
    instances_g4, choices_g4, decisions_g4b = [], {}, []
    file_info = []
    for fn in files:
        p = os.path.join(sweep_dir, fn)
        actual = _sha256(p)
        anchor = SHA256_ANCHOR.get(fn)
        matches = (actual == anchor) if anchor else None
        if anchor and not matches:
            print("WARNING sha256 mismatch for %s: anchor=%s actual=%s (스윕이 갱신됐을 수 있다)"
                  % (fn, anchor, actual), file=sys.stderr)
        file_info.append({"file": fn, "sha256": actual, "sha256_anchor": anchor,
                           "sha256_matches_anchor": matches})
        with open(p) as f:
            for row in f:
                rec = json.loads(row)
                if rec.get("policy") != "surrogate":
                    continue
                case = rec.get("case")
                ood_seed = rec.get("ood_seed")
                for idx, dec in enumerate(rec.get("decisions", [])):
                    truth = dec.get("truth")
                    surrogate = dec.get("surrogate")
                    if truth is None or surrogate is None:
                        continue
                    # 파일명까지 넣어 여러 스윕 파일(예: 특정 case 파일 + all.jsonl)에 걸쳐
                    # id 가 유일하게 만든다 -- 서로 다른 런이므로 값이 겹쳐도 다른 instance.
                    iid = "%s|%s|%s|%d" % (fn, case, ood_seed, idx)
                    instances_g4.append({"instance": iid, "kind": truth, "truth": {}, "valid": []})
                    choices_g4[iid] = surrogate
                    # G4b 는 action_registry.MACRO_COST(정수 id 키)로 진단을 계산하므로, 여기서
                    # 이름 -> id 로 바꿔서 넘긴다(gate 자체는 macro id 를 쓰는 G3/G4 단위검사와
                    # 같은 관례를 따른다).
                    menu_names = _legal_menu(dec, truth)
                    menu_ids = frozenset(REG.NAME2ID[m] for m in menu_names)
                    choice_id = REG.NAME2ID[surrogate]
                    decisions_g4b.append({"instance": iid, "menu": menu_ids, "choice": choice_id})
    return instances_g4, choices_g4, decisions_g4b, file_info


def run_g3_loio():
    """G3: leave-one-instance-out, 라벨셋(n44_plus78) 위, out-of-sample 만.

    여기서 적합하는 것은 **2026-08-13 기준선 모델**(RandomForest / `closed − λ·MACRO_COST`)이다.
    현행 배포 모델이 아니다 — 위 파일 머리말 참조.
    """
    path = wm_datasets.N44_PLUS78
    df = load(path)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if instance_arms_complete(g)]
    df = df[df.instance.isin(full)].reset_index(drop=True)
    df["y"] = df.closed.astype(float).values - LAM * np.array([MACRO_COST[int(m)] for m in df.macro])
    X = featurize(df).values
    groups = df.instance.values

    instances = []
    for i, g in df.groupby("instance"):
        truth = {int(m): float(v) for m, v in zip(g.macro, g.y)}
        instances.append({"instance": i, "kind": g.kind.iloc[0], "truth": truth,
                           "valid": sorted(truth)})

    logo = LeaveOneGroupOut()
    choices = {}
    for tr, te in logo.split(X, df["y"].values, groups):
        model = build_model().fit(X[tr], df["y"].values[tr])
        for iid in pd.unique(groups[te]):
            te_i = te[groups[te] == iid]
            gi = df.iloc[te_i]
            pred = model.predict(X[te_i])
            choices[iid] = int(gi.iloc[int(np.argmax(pred))].macro)

    return gate_g3_beats_constant(instances, choices)


def main():
    ap = argparse.ArgumentParser(
        description="G3(LOIO)/G4/G4b 를 **2026-08-13 기준선 모델**에 물린다 (현행 배포 모델이 아니다).")
    ap.add_argument("--sweep-dir", default=os.path.join(HERE, "results_4pol"),
                     help="results_4pol/*.jsonl 이 있는 디렉토리 (기본: wm4spacecraft_manufacturing/results_4pol)")
    ap.add_argument("--out", default=None, help="JSON 출력 경로 (기본: stdout)")
    args = ap.parse_args()

    ok3, i3 = run_g3_loio()
    instances_g4, choices_g4, decisions_g4b, file_info = load_deployed_decisions(
        args.sweep_dir, SWEEP_FILES)
    ok4, i4 = gate_g4_kind_discrimination(instances_g4, choices_g4)
    ok4b, i4b = gate_g4b_menu_invariance(decisions_g4b)

    result = {
        "sweep_dir": os.path.abspath(args.sweep_dir),
        "sweep_files": file_info,
        "g3_loio": {"pass": ok3, **i3},
        "g4_kind_discrimination": {"pass": ok4, **i4},
        "g4b_menu_invariance": {"pass": ok4b, **i4b},
    }

    text = json.dumps(result, indent=2, sort_keys=True, default=str)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        print("wrote %s" % args.out)
    else:
        print(text)

    print("\nG3  pass=%s  model_regret=%.3f  best_constant=%.3f  observed_margin=%.3f"
          % (ok3, i3["model_regret"], i3["best_constant_regret"], i3["observed_margin"]),
          file=sys.stderr)
    print("G4  pass=%s  collapsed_kind_pairs=%s" % (ok4, i4["collapsed_kind_pairs"]), file=sys.stderr)
    print("G4b pass=%s  degenerate_menus=%s  max_cost_rule_hit_rate=%s"
          % (ok4b, i4b["degenerate_menus"], i4b["max_cost_rule_hit_rate"]), file=sys.stderr)


if __name__ == "__main__":
    main()
