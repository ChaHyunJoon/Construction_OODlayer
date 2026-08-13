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

  battery : oracle/out/n44_plus78_d20.jsonl (seed 1, D=20 근거리 창고, 5 instance / 13 row 전체
            중 battery 는 3 instance: severity 0.02/0.30/0.50 사다리 한 칸씩, 칸마다 다른 팔을
            테스트함: 0.02 -> {NOOP, Replace, SwapBattery}, 0.30·0.50 -> {NOOP, Deprioritize,
            SwapBattery}) -- 현재 규칙의 근거, 아래 D=40 기록을 대체함(supersede).
            SoC 0.02 -> NOOP(184/313)·Replace(243/313) 둘 다 미완주, SwapBattery만 완주
                     (291/313, 22.4s) -> **완주 여부**로 갈린다                  [SwapBattery]
            SoC 0.30 -> 세 팔 전부 완주(291/313): NOOP·Deprioritize 22.7s/261.5 J/cl 동점,
                     SwapBattery 가 더 빠르다 22.4s/279.7 J/cl -> **makespan(비용)**으로 갈리고
                     SwapBattery 가 이긴다                                       [SwapBattery]
            SoC 0.50 -> 세 팔 전부 완주(291/313): NOOP·Deprioritize 22.9s/273.7 J/cl 동점,
                     SwapBattery 가 다시 더 빠르다 22.4s/279.7 J/cl -> 비용으로 갈리고
                     SwapBattery 가 다시 이긴다                                  [SwapBattery]
            => 사다리 세 칸(0.02, 0.30, 0.50) 전부 SwapBattery 가 이긴다 -> BATTERY_DEEP_SOC 를
            이 사다리의 최고 severity 인 0.5 로 올린다(0.5 초과는 미검증). D=20 근거리에서는
            창고 왕복이 싸져서, 저하된 로봇을 남은 빌드 내내 느리게 놔두는 쪽이 왕복보다 더 비싸진다
            -- "mild side 는 공짜라 NOOP 이 이긴다"는 D=40 서술은 이 기하에서 더 이상 성립하지
            않는다: 이 사다리 안에는 NOOP 이 정답인 severity 가 없다. Replace 는 D=20 에서도
            완주하는 모습이 관측되지 않았다(SoC 0.02 한 칸에서만 테스트됐고 거기서도 미완주,
            243/313) -- 이번 태스크가 가정했던 "Replace 가 다시 완주할 것"이라는 가설은 실현되지
            않았고, 실제로 뒤집힌 것은 이미 완주하던 팔들 사이의 **비용** 경쟁이었다.
            [SUPERSEDED -- D=40 원거리 창고 기하, 출처 보존용으로만 남김, 더 이상 현재 규칙 아님]
            oracle/out/n44_plus78_fardepot.jsonl (seed 1, D=40 원거리 창고, 9 instance:
            3 severity x 3 arm)
            SoC 0.02, 0.30 -> NOOP/Replace/Deprioritize 미완주, SwapBattery만 완주(291/313)
                     -> deep side(<=0.30)는 **완주 여부**로 갈린다(비용 아님)   [SwapBattery]
            SoC 0.50 -> 세 팔 전부 완주(291/313) -> NOOP/Deprioritize 18.3s/253.7 J/cl 동점,
                     SwapBattery 20.1s/273.7 J/cl -> mild side(>0.30)는 비용으로 갈린다 [NOOP]
            [SUPERSEDED -- 근거리 창고 기하(구 D 값), 출처 보존용으로만 남김, 더 이상 현재 규칙 아님]
            oracle/out/battgrid_0805_s1.jsonl (18 instance, 3팔 전수)
            SoC 0.02 -> NOOP 미완주 / Replace·SwapBattery 둘 다 완주 closed 291 동일
                     -> 동점은 비용으로 갈린다: SwapBattery(0.2) < Replace(1.0)   [6/6]
            SoC 0.30·0.50 -> 세 팔 전부 완주 291 -> 가장 싼 NOOP                  [12/12]
            (이 근거는 그 기하 한정. D=40 원거리에서는 0.30이 deep 쪽으로 넘어가
             위 SwapBattery 규칙으로 대체된다 -- BATTERY_DEEP_SOC 를 0.2->0.3 으로 올린 이유.)
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

import math

BATTERY_DEEP_SOC = 0.5      # n44_plus78_d20 사다리: SwapBattery가 0.02/0.30/0.50 전부에서 이김
                             # (0.02=완주 여부, 0.30·0.50=makespan) -> 상한을 사다리 최고 severity로

BASIS = {
    "battery": "oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 5 instances / 13 rows "
                "in this grid (battery kind = 3 of those instances, one per severity rung; arms "
                "tested per rung: 0.02 -> {NOOP, Replace, SwapBattery}, 0.30/0.50 -> {NOOP, "
                "Deprioritize, SwapBattery}). SoC 0.02: NOOP (closed 184/313) and Replace "
                "(closed 243/313) both FAIL to complete; only SwapBattery completes (291/313, "
                "22.425s) -> decided by COMPLETION. SoC 0.30: all three tested arms complete "
                "(291/313 each); NOOP and Deprioritize tie at 22.725s/261.5 J/closed, SwapBattery "
                "is FASTER at 22.425s/279.7 J/closed -> decided by makespan (COST), and "
                "SwapBattery wins it. SoC 0.50: all three complete (291/313); NOOP/Deprioritize "
                "tie at 22.875s/273.7 J/closed, SwapBattery again faster at 22.425s/279.7 "
                "J/closed -> decided by cost, SwapBattery wins again. SwapBattery is therefore "
                "correct at every rung tested (0.02, 0.30, 0.50), so BATTERY_DEEP_SOC is raised "
                "to 0.5, the highest rung in this ladder -- above 0.5 is untested by this grid. "
                "The basis is COST (makespan), not completion, at 0.30 and 0.50 -- this flips the "
                "old D=40 mild-side answer from NOOP to SwapBattery: at D=20 the depot round trip "
                "is cheap enough that swapping now beats tolerating a slower, degraded robot for "
                "the rest of the build. Replace was NOT observed to complete at this geometry "
                "(the completion flip this task's brief anticipated for Replace did not happen): "
                "it was only tested at SoC 0.02, where it still fails (243/313); what actually "
                "flipped is the cost race among the arms that already completed. This supersedes "
                "the D=40 threshold of 0.3 and its 'mild side is free, NOOP wins' story -- see the "
                "SUPERSEDED block in the module docstring for the full D=40/near-depot provenance "
                "chain this replaces. "
                "FRAGILITY (disclosed, not corrected -- the derivation rule was applied correctly, "
                "its margin is simply thin): the 0.02 rung is decided by COMPLETION and is robust, "
                "but the two upper rungs are decided by makespan margins of 0.300s (22.425 vs "
                "22.725 at SoC 0.30) and 0.450s (22.425 vs 22.875 at SoC 0.50), at n=1 per "
                "instance x arm -- this grid holds exactly one row per cell, so there is no "
                "repeat to average. A same-session control re-run of an identical configuration "
                "(results/control_d40_samesession.jsonl, canonical, D=40, ood_seed 2) measured "
                "68.175s in one session and 71.300s in another: a run-to-run spread of 3.125s "
                "(+4.6%), an order of magnitude LARGER than the 0.300/0.450s margins that decide "
                "rungs 0.30 and 0.50. Those two rungs should therefore be read as 'SwapBattery was "
                "not worse', not as an established win; only the 0.02 rung (completion) carries "
                "the threshold on its own. Above SoC 0.5 nothing is tested at all, and "
                "reference_action() returns None (unscored) there rather than inventing NOOP.",
    "fault": "oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 1 fault instance only "
              "(severity 1.0, arms NOOP and Replace) -- NEITHER arm completes (NOOP closed "
              "184/313, Replace closed 243/313, both makespan Inf), so this grid CANNOT "
              "re-derive the rule below either (same outcome as the D=40 pass); the rule is left "
              "unchanged and treated as unverified-here. closed is directionally consistent with "
              "'agent_pending > 0 -> Replace' (Replace closes more than NOOP, agent_pending=3 on "
              "this row) but does not establish it. Historical provenance (not re-verified in "
              "this pass): firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect "
              "separation (agent_pending > 0 -> Replace [24/24], == 0 -> NOOP [18/18]).",
    "zone": "oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 1 zone instance only "
             "(severity 1.0) -- NOOP and RelocateBuild TIE exactly (both complete, closed "
             "291/313, identical makespan 22.425s): this grid does not test the rule below, the "
             "same outcome as the D=40 grid before it, so the rule is left unchanged. Independent "
             "evaluation-run support: results/matrix_d20.jsonl, case=='zone', ood_seed 1 (seed 1 "
             "rows only, n=3, one per policy -- seed 2 was still appending when this was written; "
             "full 42-row confirmation happens in Task 5). All three policies COMPLETE the build. "
             "canonical enacts NOOP on every ZoneTruth decision (4x) and then needs 5 ReformTeam "
             "recovery decisions later in the run (a team got stuck), finishing in 58.55s. "
             "surrogate and dspy both enact RelocateBuild on every ZoneTruth decision (4x each) "
             "and need ZERO ReformTeam recoveries, finishing in 30.875s each -- about 53% of the "
             "NOOP arm's SIMULATED build time (sim_seconds 30.875 vs 58.55; these are sim seconds, "
             "NOT wall clock -- the runs' wall_seconds are a different field entirely). This D=20 "
             "evaluation run reproduces "
             "the same pattern the D=40 evaluation run showed (NOOP finishes but drags in "
             "stall/recovery alarms; RelocateBuild finishes faster and clean), so it "
             "independently supports keeping the rule even though the oracle grid itself ties. "
             "Historical (D=40, now superseded by the D=20 evaluation-run numbers above): "
             "results/matrix_fardepot.jsonl showed canonical(NOOP) 58.0s / 500 J/closed with 5 "
             "ReformTeam alarms, vs RelocateBuild 39.0s / 492 J/closed with 1 alarm. Grid "
             "provenance: zcausal_reform/ STEP 10, 2 arm-crossed events (n=2 -- weakest axis).",
}


def _finite_soc(x):
    """soc 값을 finite float 로 안전하게 바꾼다. 파싱 불가능하거나 NaN/Inf 면 None.
    float("NaN") <= BATTERY_DEEP_SOC 는 조용히 False 라서 그냥 float(soc) 를 썼다가는
    NaN 이 "NOOP 이 정답"으로 잘못 채점된다 -- 반드시 이 게이트를 거쳐야 한다."""
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


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
        soc = _finite_soc(soc)
        if soc is None:
            return None, "battery", "SoC not a finite number"
        if soc <= BATTERY_DEEP_SOC:
            # 깊은 방전 = 개입하지 않으면 그 로봇은 죽는다. D=20 사다리(n44_plus78_d20)에서는
            # SoC 0.02 는 SwapBattery만 완주(NOOP·Replace 미완주)해 근거가 **완주 여부**이고,
            # SoC 0.30·0.50 은 세 팔(NOOP/Deprioritize/SwapBattery) 전부 완주하지만 SwapBattery
            # 의 makespan 이 더 짧아(22.4s < 22.7~22.9s) 근거가 **비용**이다 -- 두 근거가 섞여
            # 있고, 사다리 전 구간(0.02/0.30/0.50)에서 SwapBattery 가 이긴다. BATTERY_DEEP_SOC 를
            # 사다리 최고값인 0.5 로 둔 이유가 이것이다. SwapBattery 가 메뉴에 없는 옛 배선/옛
            # 녹화에서는 Replace 가 그 자리를 대신한다(Replace 자체는 이 격자에서 완주가 관측되지
            # 않았다 -- SoC 0.02 에서만 테스트됐고 거기서도 미완주).
            return ("SwapBattery" if "SwapBattery" in valid else "Replace"), "battery", \
                   "deep discharge (SoC<=%.2f): restore charge, cheapest/fastest restoring arm" % BATTERY_DEEP_SOC
        # SoC > 0.5 는 이 격자가 테스트한 사다리(최고 rung 0.50) **바깥**이다. 근거가 없는
        # 구간에서 NOOP 을 정답이라고 채점하면 없는 정답을 지어내는 것이 된다 -- 아래 reform 축과
        # **같은 이유로 채점하지 않는다**(unscored). 임계값이 0.3 이던 시절에는 0.50 rung 이
        # 이 가지 안에 있어서 채점할 근거가 있었지만, 0.5 로 올린 지금은 이 가지 위에 테스트된
        # rung 이 하나도 없다. 현재 42판 데이터에서는 BatteryTruth 56건의 soc 최댓값이 0.09999
        # 라 아무도 이 가지에 들어오지 않아 채점이 한 건도 바뀌지 않지만(확인함), mild battery
        # 를 굴리는 미래 실행에서는 조용한 오채점이 된다.
        return None, "battery", \
               "SoC>%.2f: above the highest rung this grid tested (0.50) -- untested regime, unscored" % BATTERY_DEEP_SOC

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
