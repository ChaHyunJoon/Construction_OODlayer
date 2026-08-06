"""
reference_policy.py -- 라이브 스트림의 결정을 "옳았는가"로 채점하기 위한 **기준 행동** a*.

왜 이런 물건이 필요한가
-----------------------
계획서(§0-a)의 `optimal_action_rate = P(a = a*)` 는 a* 를 요구한다. 격자 오라클에서는 a* 가
"같은 사건을 모든 팔로 각각 굴려 본 결과의 최선"이다. 그런데 **무작위 스트림**에서는 그 정의를
그대로 쓸 수 없다: 사건 i 의 반사실을 재려면 결정 i 이후의 세계가 갈라지므로 사건마다 트리가
지수로 늘어난다(사건 4개 × 팔 4개 = 256 런, 런당 ~15분).

그래서 여기서는 격자에서 **실측된 정답 구조**를 규칙으로 옮겨 적고, 그 규칙을 기준으로 삼는다.
이것은 반사실 오라클이 아니라 **측정에서 유도한 기준 정책**이다. 리포트에는 반드시 그렇게 적는다.

각 규칙은 추측이 아니라 이 저장소의 특정 실험에 근거한다(아래 BASIS 문자열이 그 출처다):

  battery : oracle/out/battgrid_0805_s1.jsonl (18 instance, 3팔 전수)
            SoC 0.02 -> NOOP 미완주 / Replace·SwapBattery 둘 다 완주 closed 291 동일
                     -> 동점은 비용으로 갈린다: SwapBattery(0.2) < Replace(1.0)   [6/6]
            SoC 0.30·0.50 -> 세 팔 전부 완주 291 -> 가장 싼 NOOP                  [12/12]
  fault   : oracle/out/firegrid_merged.jsonl (fault 42 instance, seed 1~6)
            agent_pending > 0 -> Replace [24/24] · agent_pending == 0 -> NOOP [18/18]
            (완전 분리. "고장났으니 무조건 교체"가 아니라 **일을 지고 있었는가**가 가른다)
  zone    : oracle/out/zcausal_reform/ (STEP 10, 팔 교차 2사건)
            blk (root_covered 0, nav_blocked 3): NOOP stall 254 / RelocateBuild 완주 279 -> 개입
            cov (root_covered 8, nav_blocked 1): NOOP stall 232 / RelocateBuild stall 197 -> NOOP
            => nav_blocked > 0 **그리고** root_covered == 0 일 때만 개입.
            막힘>0 하나만 보는 규칙은 2사건 중 1개만 맞는다(STATUS §1 "인과 규칙이 1/2").
  reform  : 실측 격자 없음 -> **채점하지 않는다**(unscored). 없는 정답을 지어내지 않는다.

n 이 작은 축(zone n=2)은 그대로 작다고 적는다. 규칙의 신뢰도는 축마다 다르고, 그 차이를
숨기면 하나의 적중률 숫자가 서로 다른 근거를 뭉갠다.
"""

BATTERY_DEEP_SOC = 0.2      # battgrid 사다리에서 완주/미완주가 갈리는 칸 (0.02 vs 0.30)

BASIS = {
    "battery": "battgrid_0805_s1.jsonl, 18 instances (6 fire points x 3 severities), all 3 arms",
    "fault": "firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect separation",
    "zone": "zcausal_reform/ STEP 10, 2 arm-crossed events (n=2 -- weakest axis)",
}


def reference_action(ev):
    """한 결정 사건의 기준 행동을 돌려준다.

    ev = run_demo.jl 요약의 decisions[] 항목 하나(dict).
    반환 (a_star, basis_key, note). a_star 가 None 이면 **채점 제외**(unscored).
    """
    truth = str(ev.get("truth", ""))
    valid = list(ev.get("valid") or [])

    if truth == "BatteryTruth":
        soc = ev.get("soc")
        if soc is None:
            return None, "battery", "no SoC recorded"
        if float(soc) <= BATTERY_DEEP_SOC:
            # 깊은 방전 = 개입하지 않으면 그 로봇은 죽는다. 충전을 되살리는 두 팔은 결과가
            # 같으므로(closed 291 동일) **싼 쪽**이 정답이다. SwapBattery 가 메뉴에 없는
            # 옛 배선/옛 녹화에서는 Replace 가 그 자리를 대신한다.
            return ("SwapBattery" if "SwapBattery" in valid else "Replace"), "battery", \
                   "deep discharge (SoC<=%.2f): restore charge, cheapest restoring arm" % BATTERY_DEEP_SOC
        return "NOOP", "battery", "mild degradation: every arm completes, so the free one wins"

    if truth == "FaultTruth":
        pend = ev.get("agent_pending")
        if pend is None or int(pend) < 0:
            return None, "fault", "agent_pending not recorded"
        if int(pend) > 0:
            return "Replace", "fault", "the faulted robot still owed %d transport task(s)" % int(pend)
        return "NOOP", "fault", "the faulted robot owed no work; the fleet absorbs it"

    if truth == "ZoneTruth":
        zp = ev.get("zone_primitives") or {}
        nb, rc = zp.get("n_nav_blocked"), zp.get("root_covered")
        if nb is None or rc is None:
            return None, "zone", "zone primitives not recorded"
        if int(nb) > 0 and int(rc) == 0:
            # 막힌 것이 **항법 목표**이고 root 하역목표는 안 걸렸다 = 빌드를 통째로 옮기면 풀린다.
            # 이 자리에서만 전역 이동이 값을 한다(blk 279 완주 vs NOOP 254 정지).
            return ("RelocateBuild" if "RelocateBuild" in valid else "ForbidZone"), "zone", \
                   "zone blocks %d navigable goal(s) and no root delivery goal" % int(nb)
        return "NOOP", "zone", \
               "blockage %s / root goals covered %s: relocating costs more than it recovers" % (nb, rc)

    return None, "reform", "no measured grid for this event class"


def score(decisions):
    """결정 목록을 채점해 (scored, correct, rows) 를 돌려준다."""
    rows = []
    for ev in decisions:
        a_star, basis, note = reference_action(ev)
        chosen = str(ev.get("macro") or "")
        rows.append(dict(truth=ev.get("truth"), at=ev.get("at"), chosen=chosen,
                         reference=a_star, basis=basis, note=note,
                         correct=(None if a_star is None else chosen == a_star)))
    scored = [r for r in rows if r["correct"] is not None]
    return len(scored), sum(1 for r in scored if r["correct"]), rows
