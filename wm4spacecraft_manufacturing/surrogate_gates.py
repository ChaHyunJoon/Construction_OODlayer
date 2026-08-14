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


def _menu_costs(menu):
    """menu -> {팔: MACRO_COST}.  **이 저장소에서 MACRO_COST 를 순위 목적으로 읽는 유일한 자리다.**

    복사본을 만들지 말 것: `audit_objective.py` 항목 "채점 규칙 단일 정의" 가 잡는 부류이고,
    실제로 정의가 둘로 갈리면 "G4b 진단이 말하는 규칙"과 "평가가 바닥선으로 실행하는 규칙"이
    조용히 달라져 둘을 비교한 숫자가 무의미해진다.
    """
    return {m: MACRO_COST[m] for m in menu if m in MACRO_COST}


def max_cost_menu_policy(menu):
    """legal menu 안에서 `MACRO_COST` 가 최대인 팔 하나. **2026-08-13 배포 결함 그 자체의 규칙**.

    학습이 0 이고 상태를 한 비트도 안 본다. 배포 surrogate 의 861/861 결정이 이 규칙과
    일치했으므로, 재구축된 모델이 **J 로 이것을 이기지 못하면 학습에 값이 없다** — Task 6 의
    평가가 이것을 상태맹 바닥선으로 채점한다.

    동률은 팔 번호가 작은 쪽으로 결정적으로 깬다(아래 G4b 진단의 동률-관용 hit 판정과 다르다:
    진단은 "최댓값 팔들 중 하나면 hit", 이 함수는 "실행 가능한 정책이므로 팔 하나").
    """
    costs = _menu_costs(menu)
    if not costs:
        return None
    best = max(costs.values())
    return sorted(m for m, c in costs.items() if c == best)[0]


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


def _modal(counts):
    """분포의 최빈값. 동률은 팔 번호(문자열 정렬)로 결정적으로 깬다 — 게이트가 입력 순서에
    따라 판정을 바꾸면 재현되지 않는 게이트가 된다."""
    return sorted(counts.items(), key=lambda kv: (-kv[1], str(kv[0])))[0][0]


def gate_g4b_menu_invariance(decisions, min_group=5, oracle_choices=None):
    """G4b: 선택이 legal menu 의 **순수 함수**인가 — 즉 state 를 전혀 안 쓰는가.

    decisions: [{"instance": id, "menu": iterable[legal 팔], "choice": 선택한 팔}]
    menu 는 frozenset 으로 묶는다(순서·중복 무관 — "이 상황에서 쓸 수 있던 팔의 집합"만 본다).

    ------------------------------------------------------------------------------------
    2026-08-14 수정 — `oracle_choices` (선택 인자). 두 가지가 **추가**된다.
    ------------------------------------------------------------------------------------
    `oracle_choices`: {instance: 정답 팔}. 주지 않으면 **동작이 이전과 완전히 같다**(하위호환).

    왜 고치는가. 원래 G4b 는 **다름(distinctness)만 재고 옳음(correctness)은 전혀 안 잰다.**
    Task 6 실측에서 그 구멍 두 개가 동시에 터졌다:

      (거짓 양성) menu {0,1,8} 에서 모델이 퇴화했다고 실패 판정했는데, **오라클도 그 menu 에서
        퇴화한다** — 그 menu 에서는 정답 자체가 상수라, 어떤 모델도 비퇴화로 만들 수 없다.
        판별 불가능한 것을 못 했다고 벌하는 것은 잘못된 진단이다.
      (거짓 음성) 같은 menu 에서 모델은 15/15 Replace 를 냈고 정답은 15/15 SwapBattery 였다 —
        **데이터셋에서 노이즈를 넘는 유일한 신호를 100% 뒤집었는데** G4b 는 이것을 **원리적으로**
        못 본다. 분포가 하나로 퇴화했다는 사실만 보고 그 답이 무엇인지는 안 보기 때문이다.

    그래서 두 절(clause)을 더한다:
      (1) **정보성 조건** — 오라클이 스스로 퇴화하는 menu 는 `uninformative` 로 기록하고
          **합·불 판정에서 뺀다**. 그 그룹에서의 퇴화는 증거가 아니다.
      (2) **최빈답 일치 조건** — n >= min_group 인 **모든** 그룹에서(정보성 여부와 무관하게)
          모델의 최빈답 != 오라클의 최빈답이면 실패. (1)이 안 보게 된 자리를 정확히 이것이 막는다.

    (2)를 정보성 그룹에만 걸지 않는 이유: 위의 거짓 음성이 난 곳이 바로 **비정보성** 그룹이다.
    정답이 상수인 menu 는 "갈리는가"를 물을 수 없을 뿐이고, "그 상수를 맞혔는가"는 물을 수 있다 —
    오히려 그쪽이 더 쉬운 질문이라 틀리면 더 나쁘다.

    검증됨: 배포 max-cost 정책은 정보성 menu 3/3 에서 계속 실패하고, 완벽한 오라클은 통과한다.
    (즉 거짓 양성만 없애고 게이트를 약화시키지 않는다.)

    ------------------------------------------------------------------------------------
    2026-08-14 (최종 리뷰) — **부분 커버리지가 게이트를 무장해제하던 것을 막는다.**
    ------------------------------------------------------------------------------------
    위 두 절은 "오라클이 그 menu 에서 무엇을 했나"를 보는데, 지도(`oracle_choices`)에 없는
    instance 는 `oracle_groups` 에 아무것도 더하지 않는다. 그래서 오라클 항목이 하나도 없는
    그룹은 `ocounts = Counter()` 가 되어
      · `len(ocounts) > 1` 이 거짓 -> `informative = False` -> 절(1)의 판정에서 빠지고,
      · `if ocounts:` 가드가 거짓 -> 절(2)의 최빈답 비교도 통째로 건너뛴다.
    **두 절이 동시에 사라진다.** 실측 시연: menu {0,1,8} 20결정 전부 Replace(완전 퇴화),
    오라클은 8/0 으로 10/10 갈리는데(명백한 정보성 menu), 지도가 그 20개 중 0개를 덮으면
    게이트가 **통과**했다. 잘린 지도를 넘기는 것만으로 판정이 뒤집히는 게이트는 게이트가 아니다.

    고친 방식 — **없는 데이터로는 면제하지 않는다**:
      `informative = (오라클 답이 둘 이상) or (그 그룹의 커버리지가 완전하지 않다)`
    즉 "오라클도 여기서는 퇴화한다"는 면제는 그 그룹의 **모든** 결정에 오라클 답이 있을 때만
    준다. 부분/무 커버리지에서는 면제가 없으므로 퇴화가 그대로 증거로 남고, 그 결과
    **불완전한 지도의 판정은 오라클 없는 판정보다 절대 느슨할 수 없다**(테스트가 이 불변식을
    직접 못박는다). 커버리지는 숨기지 않고 info 에 낸다: 전체 `oracle_coverage`, 그룹별
    `oracle_covered`/`oracle_coverage`, 그리고 불완전한 그룹 목록 `partial_coverage_menus`.

    예외를 던지지 않는 이유: 이 게이트는 **판정을 내는 것이 일**이라, 지도가 부실할 때 죽으면
    호출자가 오라클 인자를 빼는 것으로 손쉽게 회피한다(그러면 절(2)가 통째로 사라진다).
    판정은 항상 내되, 없는 근거로 모델을 면제하지 않는 편이 더 안전하다.

    ------------------------------------------------------------------------------------
    원래 근거 (2026-08-13) — 아래는 그대로 유효하다.
    ------------------------------------------------------------------------------------
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
    oracle_groups = defaultdict(Counter)
    oracle_covered = Counter()      # menu -> 오라클 답이 실제로 있는 decision 수(커버리지)
    for d in decisions:
        key = frozenset(d["menu"])
        groups[key][d["choice"]] += 1
        if oracle_choices is not None and d["instance"] in oracle_choices:
            oracle_groups[key][oracle_choices[d["instance"]]] += 1
            oracle_covered[key] += 1

    total_covered = sum(oracle_covered.values())
    overall_coverage = ((total_covered / len(decisions)) if decisions else None) \
        if oracle_choices is not None else None

    per_menu, skipped, degenerate = {}, [], []
    uninformative, modal_mismatch, degenerate_informative, partial_coverage = [], [], [], []
    for menu, counts in groups.items():
        n = sum(counts.values())
        label = "{%s}" % ", ".join(str(m) for m in sorted(menu, key=str))
        if n < min_group:
            skipped.append({"menu": label, "n": n})
            continue
        is_degenerate = len(counts) == 1
        entry = {"menu": sorted(menu, key=str), "n": n,
                 "choice_dist": dict(counts), "degenerate": is_degenerate}
        if is_degenerate:
            degenerate.append(label)

        if oracle_choices is not None:
            ocounts = oracle_groups.get(menu, Counter())
            covered = oracle_covered.get(menu, 0)
            full_coverage = (covered == n)
            # (1) 정보성: 오라클이 갈리는 menu 에서만 "퇴화"가 증거가 된다.
            #     단 **면제는 완전한 커버리지 위에서만** 준다 — 지도에 없는 결정으로
            #     "오라클도 여기서는 퇴화한다"를 주장할 수 없다(위 2026-08-14 절 참조).
            informative = (len(ocounts) > 1) or (not full_coverage)
            entry["oracle_dist"] = dict(ocounts)
            entry["oracle_covered"] = covered
            entry["oracle_coverage"] = covered / n
            entry["informative"] = informative
            if not full_coverage:
                partial_coverage.append({"menu": label, "covered": covered, "n": n})
            if not informative:
                uninformative.append(label)
            elif is_degenerate:
                degenerate_informative.append(label)
            # (2) 최빈답 일치: 정보성과 무관하게 n >= min_group 인 모든 그룹에서 검사한다.
            if ocounts:
                mm, om = _modal(counts), _modal(ocounts)
                entry["model_modal"], entry["oracle_modal"] = mm, om
                entry["modal_agrees"] = (mm == om)
                if mm != om:
                    modal_mismatch.append(label)
        per_menu[label] = entry

    if not per_menu:
        return False, {"reason": "min_group=%d 이상인 menu 그룹이 없다 — 판별 불가" % min_group,
                        "per_menu": {}, "degenerate_menus": [], "skipped_small_menus": skipped,
                        "min_group": min_group, "max_cost_rule_hit_rate": None,
                        "max_cost_rule_hits": 0, "max_cost_rule_n": 0,
                        "oracle_aware": oracle_choices is not None,
                        "oracle_coverage": overall_coverage,
                        "partial_coverage_menus": [],
                        "uninformative_menus": [], "degenerate_informative_menus": [],
                        "modal_mismatch_menus": []}

    # 진단: 선택이 "legal menu 안에서 MACRO_COST 최댓값" 규칙과 얼마나 일치하는가(동률은 hit).
    hits, n_scored = 0, 0
    for d in decisions:
        menu = frozenset(d["menu"])
        costs = _menu_costs(menu)
        if not costs:
            continue
        n_scored += 1
        best_cost = max(costs.values())
        if d["choice"] in costs and costs[d["choice"]] == best_cost:
            hits += 1
    max_cost_rule_hit_rate = (hits / n_scored) if n_scored else None

    # `oracle_choices` 를 안 주면 판정식이 이전과 **글자 그대로 같다**(하위호환).
    # 주면 (1) 정보성 menu 에서의 퇴화 + (2) 최빈답 불일치, 둘 중 하나라도 있으면 실패.
    if oracle_choices is None:
        ok = not degenerate
    else:
        ok = (not degenerate_informative) and (not modal_mismatch)
    return ok, {"per_menu": per_menu, "degenerate_menus": degenerate,
                "skipped_small_menus": skipped, "min_group": min_group,
                "max_cost_rule_hit_rate": max_cost_rule_hit_rate,
                "max_cost_rule_hits": hits, "max_cost_rule_n": n_scored,
                "oracle_aware": oracle_choices is not None,
                "oracle_coverage": overall_coverage,
                "partial_coverage_menus": partial_coverage,
                "uninformative_menus": uninformative,
                "degenerate_informative_menus": degenerate_informative,
                "modal_mismatch_menus": modal_mismatch}
