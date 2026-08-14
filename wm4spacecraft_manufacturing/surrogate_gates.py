#!/usr/bin/env python3
"""surrogate 의 **상수 정책 붕괴**를 기계적으로 잡는 게이트 (spec §4 G3·G4, + G4b).

왜 이 파일이 필요한가
====================
2026-08-13 실측: 배포 surrogate 가 OOD 종류와 무관하게 언제나 `Replace` 를 냈다
(battery 120/120, fault 120/120, fault_battery 120/120). 그런데 그때까지 쓰던 평가 지표
(leave-one-instance-out decision regret 평균)는 0.100 으로 "괜찮아" 보였다.

**평균 regret 은 상수 붕괴를 숨긴다.** 상수 정책도 대부분의 instance 에서 그럭저럭 맞기
때문이다. 그래서 세 가지를 따로 본다:

  G3   상수 정책("항상 Replace", "항상 NOOP", ...)보다 **엄격히** 나은가
  G4   kind 마다 실제로 **다른 답 분포**를 내는가 (τ 임계 이상 벌어지는가)
  G4b  legal menu(그 상황에서 쓸 수 있는 팔의 집합) 가 같으면 답도 같은가 — 즉 선택이
       **menu 의 순수 함수인가**(=state 를 전혀 안 쓰는가)

G4b 가 추가된 이유(2026-08-13 재조사, 독립 검증): 배포 모델의 실제 결함은 "kind 를 못
구별한다"가 아니었다 — 861/861 결정이 **legal menu 안에서 MACRO_COST 가 최대인 팔**과
정확히 일치했다. kind 마다 menu 가 다르면(예: zone={NOOP,RelocateBuild}, reform={NOOP,
ReformTeam}) menu 가 다른 것만으로 답도 달라 보이므로, G4 는 이 결함에 대해 **통과해
버릴 수 있다**(menu 가 서로소인 kind 쌍은 답 분포가 자동으로 갈린다 — 판별력의 착시).
G4b 는 kind 를 아예 보지 않고 menu 로만 묶어서, **같은 menu 안에서 답이 갈리는가**를
직접 묻는다 — menu 가 같은데 항상 같은 답이면 그 팔은 상태를 안 쓰고 menu 만 본 것이다.

세 검사 모두 모델 내부를 안 본다 — (instance, kind/menu, 예측한 팔) 목록만 받는다.
그래서 어떤 모델 클래스에도, 배포된 서비스의 로그에도 그대로 적용된다.
"""
from collections import Counter, defaultdict

from action_registry import MACRO_COST  # 단일 진실원(action_registry.json) — 리터럴 복붙 금지


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
    margin:  이만큼은 더 좋아야 통과(기본 0 = 조금이라도 나으면 통과). 임계값이지 결과가 아니다 —
             실제로 벌어진 차이는 반환값의 "observed_margin" 에 있다(Task 6 이 그 숫자를 쓴다).
    """
    model = sum(_regret(choices.get(r["instance"]), r["truth"]) for r in instances) / max(len(instances), 1)
    base = constant_policy_baseline(instances)
    best_const = min(base.values()) if base else float("inf")
    best_arm = min(base, key=base.get) if base else None
    observed_margin = best_const - model   # 실측 격차(양수 = 모델이 더 낫다). margin(임계값)과 구분.
    ok = model + margin < best_const
    return ok, {"model_regret": model, "best_constant_regret": best_const,
                "best_constant_arm": best_arm, "all_constant": base,
                "margin_threshold": margin, "observed_margin": observed_margin}


def gate_g4_kind_discrimination(instances, choices, min_kinds=2, tau=0.05):
    """G4: kind 마다 실제로 다른 답 분포를 내는가.

    통과 조건: 모든 kind 쌍의 답 분포가 **total variation distance > tau** 만큼 벌어져야
    한다(즉 `tv <= tau` 면 "사실상 같은 정책"으로 실패 처리). tau=0 이면 "완전히 같으면
    실패"(예전 `pa == pb` 검사와 동치인 퇴화 경우)로 정확히 되돌아간다 — **`tv < tau` 로
    쓰면 안 된다**: tau=0 일 때 `tv < 0` 은 부동소수 거리(항상 >= 0)에 대해 절대 참이 될 수
    없어서, 정확히 그 원래 결함(238/238 대 238/238, tv=0.0 인 완벽한 동률)조차 못 잡는
    회귀가 생긴다(2026-08-14 재검증에서 실측 발견 — `<=` 로 고쳤고 tau=0.0 회귀 검사를
    추가했다). 기본값은 tau=0.05(정규화 분포가 5% 이하로만 벌어지면 "사실상 같다"로 판정) —
    2026-08-13 결함은 238/238 대 238/238 이라는 산술적으로 완벽한 동률이었지만, 예를 들어
    237/238 대 238/238 처럼 딱 하나만 어긋나는 거의-상수 정책은 tv>0 이라 tau=0 이면
    통과해 버린다 — 같은 결함인데 지표가 못 잡는다. tau 는 파라미터로 노출돼 있으니 더
    엄격하게/느슨하게 검사하고 싶으면 호출자가 override 한다.

    TV distance(전변동 거리) = 0.5 * sum(|p(m) - q(m)| for m in 팔 전체). 0=완전히 같은 분포,
    1=서로 겹치는 팔이 하나도 없는 분포. 임계값 이하면 "사실상 같은 정책"으로 취급해 실패.
    """
    by_kind = defaultdict(Counter)
    for r in instances:
        c = choices.get(r["instance"])
        if c is not None:
            by_kind[r["kind"]][c] += 1
    kinds = sorted(by_kind)
    if len(kinds) < min_kinds:
        return False, {"reason": "kind 가 %d개뿐이라 판별을 검사할 수 없다" % len(kinds),
                       "by_kind": {k: dict(v) for k, v in by_kind.items()},
                       "tau": tau, "pairwise_tv_distance": [], "collapsed_kind_pairs": []}
    collapsed = []
    pairwise = []
    for i in range(len(kinds)):
        for j in range(i + 1, len(kinds)):
            a, b = kinds[i], kinds[j]
            # 분포를 비율로 정규화해 비교(표본 수가 달라도 "같은 정책"이면 같은 비율).
            na, nb = sum(by_kind[a].values()), sum(by_kind[b].values())
            pa = {m: c / na for m, c in by_kind[a].items()}
            pb = {m: c / nb for m, c in by_kind[b].items()}
            arms = set(pa) | set(pb)
            tv = 0.5 * sum(abs(pa.get(m, 0.0) - pb.get(m, 0.0)) for m in arms)
            pairwise.append({"a": a, "b": b, "tv_distance": tv})
            if tv <= tau:      # <=, 절대로 < 로 바꾸지 말 것 -- tau=0 에서 tv=0(완전 동률)을 놓친다.
                collapsed.append((a, b))
    ok = not collapsed
    return ok, {"collapsed_kind_pairs": collapsed, "pairwise_tv_distance": pairwise, "tau": tau,
                "by_kind": {k: dict(v) for k, v in by_kind.items()}}


def gate_g4b_menu_invariance(decisions, min_group=5):
    """G4b: 선택이 legal menu 의 **순수 함수**인가 — 즉 state 를 전혀 안 쓰는가.

    decisions: [{"instance": id, "menu": iterable[legal 팔], "choice": 선택한 팔}]
    menu 는 frozenset 으로 묶는다(순서·중복 무관 — "이 상황에서 쓸 수 있던 팔의 집합"만 본다).

    왜 필요한가(2026-08-13 재조사): kind 별 legal menu 가 서로 다르면(zone 은 {NOOP,
    RelocateBuild}, reform 은 {NOOP,ReformTeam} 처럼 menu 자체가 겹치지 않으면), G4(kind
    판별) 는 menu 차이만으로 통과할 수 있다 — 모델이 상태를 하나도 안 보고 "이번엔 무슨
    메뉴가 왔나"만 봐도 kind 별 분포가 갈리기 때문이다. 실제 배포 모델이 정확히 이랬다:
    같은 menu 안에서는 **항상 같은 답**(=menu 안 최고 MACRO_COST 팔)을 냈다. G4b 는 kind 를
    아예 안 보고 menu 로만 묶어서 이걸 직접 잡는다 — menu 가 같은 그룹(표본 min_group 개
    이상)에서 답이 하나로 퇴화(degenerate)해 있으면 실패. state 를 실제로 쓰는 모델은 같은
    menu 안에서도 상태에 따라 답이 갈린다(예: battery 안에서도 어떤 instance 는
    SwapBattery, 어떤 instance 는 NOOP).

    min_group 보다 작은 menu 그룹은 판정에서 **제외**하고 그 사실을 info 에 남긴다(표본이
    너무 적으면 우연히 퇴화해 보일 수 있어 침묵하지 않고 명시적으로 건너뛴다).

    반환 info 에는 참고용 진단으로 "menu 안에서 MACRO_COST 가 최댓값인 팔을 고른 비율"도
    같이 낸다(action_registry.MACRO_COST 를 그대로 쓴다 — 리터럴 재선언 금지) — 이 결함의
    구체적인 모양("최댓값 규칙")을 숫자로 보여주기 위한 것이지, 통과/실패 판정에는 안 쓴다.
    """
    groups = defaultdict(Counter)
    for d in decisions:
        groups[frozenset(d["menu"])][d["choice"]] += 1

    per_menu, skipped, degenerate = {}, [], []
    for menu, counts in groups.items():
        n = sum(counts.values())
        label = "{%s}" % ", ".join(str(m) for m in sorted(menu, key=str))
        if n < min_group:
            skipped.append({"menu": label, "n": n})
            continue
        is_degenerate = len(counts) == 1
        per_menu[label] = {"menu": sorted(menu, key=str), "n": n,
                            "choice_dist": dict(counts), "degenerate": is_degenerate}
        if is_degenerate:
            degenerate.append(label)

    if not per_menu:
        return False, {"reason": "min_group=%d 이상인 menu 그룹이 없다 — 판별 불가" % min_group,
                        "per_menu": {}, "degenerate_menus": [], "skipped_small_menus": skipped,
                        "min_group": min_group, "max_cost_rule_hit_rate": None,
                        "max_cost_rule_hits": 0, "max_cost_rule_n": 0}

    # 진단: 선택이 "legal menu 안에서 MACRO_COST 최댓값" 규칙과 얼마나 일치하는가(동률은 hit).
    hits, n_scored = 0, 0
    for d in decisions:
        menu = frozenset(d["menu"])
        costs = {m: MACRO_COST[m] for m in menu if m in MACRO_COST}
        if not costs:
            continue
        n_scored += 1
        best_cost = max(costs.values())
        if d["choice"] in costs and costs[d["choice"]] == best_cost:
            hits += 1
    max_cost_rule_hit_rate = (hits / n_scored) if n_scored else None

    ok = not degenerate
    return ok, {"per_menu": per_menu, "degenerate_menus": degenerate,
                "skipped_small_menus": skipped, "min_group": min_group,
                "max_cost_rule_hit_rate": max_cost_rule_hit_rate,
                "max_cost_rule_hits": hits, "max_cost_rule_n": n_scored}
