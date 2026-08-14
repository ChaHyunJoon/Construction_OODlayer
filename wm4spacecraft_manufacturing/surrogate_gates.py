#!/usr/bin/env python3
"""surrogate 의 **상수 정책 붕괴**를 기계적으로 잡는 게이트 (spec §4 G3·G4).

왜 이 파일이 필요한가
====================
2026-08-13 실측: 배포 surrogate 가 OOD 종류와 무관하게 언제나 `Replace` 를 냈다
(battery 120/120, fault 120/120, fault_battery 120/120). 그런데 그때까지 쓰던 평가 지표
(leave-one-instance-out decision regret 평균)는 0.100 으로 "괜찮아" 보였다.

**평균 regret 은 상수 붕괴를 숨긴다.** 상수 정책도 대부분의 instance 에서 그럭저럭 맞기
때문이다. 그래서 두 가지를 따로 본다:

  G3  상수 정책("항상 Replace", "항상 NOOP", ...)보다 **엄격히** 나은가
  G4  kind 마다 실제로 **다른 답**을 내는가

두 검사 모두 모델 내부를 안 본다 — (instance, kind, 예측한 팔) 목록만 받는다. 그래서
어떤 모델 클래스에도, 배포된 서비스의 로그에도 그대로 적용된다.
"""
from collections import Counter, defaultdict


def _regret(chosen, truth_scores):
    """truth_scores = {macro: 점수(높을수록 좋음)}. regret = 최적 − 선택."""
    if not truth_scores:
        return 0.0
    best = max(truth_scores.values())
    return float(best - truth_scores.get(chosen, min(truth_scores.values())))


def constant_policy_baseline(instances):
    """모든 상수 정책의 평균 regret 을 돌려준다.

    instances: [{"instance": id, "kind": k, "truth": {macro: score}, "valid": [macro...]}]
    반환: {macro: 평균 regret}  — 그 macro 를 언제나 고르는 정책의 성적.
    """
    arms = sorted({m for r in instances for m in r["truth"]})
    out = {}
    for a in arms:
        tot, n = 0.0, 0
        for r in instances:
            if a not in r["truth"]:      # 그 instance 에서 쓸 수 없는 팔이면 최악으로 친다
                tot += _regret(None, r["truth"])
            else:
                tot += _regret(a, r["truth"])
            n += 1
        out[a] = tot / max(n, 1)
    return out


def gate_g3_beats_constant(instances, choices, margin=0.0):
    """G3: 모델이 **모든** 상수 정책보다 엄격히 나은가.

    choices: {instance_id: 선택한 macro}
    margin:  이만큼은 더 좋아야 통과(기본 0 = 조금이라도 나으면 통과).
    """
    model = sum(_regret(choices.get(r["instance"]), r["truth"]) for r in instances) / max(len(instances), 1)
    base = constant_policy_baseline(instances)
    best_const = min(base.values()) if base else float("inf")
    best_arm = min(base, key=base.get) if base else None
    ok = model + margin < best_const
    return ok, {"model_regret": model, "best_constant_regret": best_const,
                "best_constant_arm": best_arm, "all_constant": base}


def gate_g4_kind_discrimination(instances, choices, min_kinds=2):
    """G4: kind 마다 실제로 다른 답 분포를 내는가.

    통과 조건: 답 분포가 **완전히 같은 kind 쌍이 하나도 없어야** 한다.
    (2026-08-13 결함이 정확히 이것이었다 — battery/fault/fault_battery 의 답 분포가
     Replace×120 으로 전부 동일했다.)
    """
    by_kind = defaultdict(Counter)
    for r in instances:
        c = choices.get(r["instance"])
        if c is not None:
            by_kind[r["kind"]][c] += 1
    kinds = sorted(by_kind)
    if len(kinds) < min_kinds:
        return False, {"reason": "kind 가 %d개뿐이라 판별을 검사할 수 없다" % len(kinds),
                       "by_kind": {k: dict(v) for k, v in by_kind.items()}}
    identical = []
    for i in range(len(kinds)):
        for j in range(i + 1, len(kinds)):
            a, b = kinds[i], kinds[j]
            # 분포를 비율로 정규화해 비교(표본 수가 달라도 "같은 정책"이면 같은 비율).
            na, nb = sum(by_kind[a].values()), sum(by_kind[b].values())
            pa = {m: c / na for m, c in by_kind[a].items()}
            pb = {m: c / nb for m, c in by_kind[b].items()}
            if pa == pb:
                identical.append((a, b))
    ok = not identical
    return ok, {"identical_kind_pairs": identical,
                "by_kind": {k: dict(v) for k, v in by_kind.items()}}
