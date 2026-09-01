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

[역사] 아래 실험 기록(과 위 반사실 비용 계산의 "팔 4개")은 구세대 어휘(v3-4arms 이전)의 것이다 —
Deprioritize·RelocateBuild·ReformTeam 은 이제 레지스트리에 없고 zone·reform 은 사건 종류가 아니다.
그 산출물은 이미 폐기돼 재측정이 불가능하므로 숫자와 서술은 그대로 보존한다.

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
# ※ 이 파일이 이름으로 인용하는 아래 md 문서는 2026-08-18 md 통합에서 내려갔다 —
#    (md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md)
#    복구 SHA 는 `md/README.md` §9-A.

import math

BATTERY_DEEP_SOC = 0.1      # Julia ood_truth.jl 의 REPLACE_SOC_THRESHOLD 와 통일(2026-08-31,
                             # 심볼로 파싱해 대조: core/test_soc_threshold_agrees.py)
                             # ⚠️ 공개된 대가: 0.5 였을 때는 n44_plus78_d20 사다리의 0.30·0.50 rung 이
                             # 이 가지 안에 있어 채점 근거가 있었다(세 rung 전부에서 SwapBattery 가
                             # 이겼다 -- 위 BASIS["battery"] 참고). 0.2 로 내리면 그 두 rung 이
                             # unscored 로 빠진다 -- 측정된 근거를 버리는 것이다.
                             # 🔴 2026-08-25 정정(최종 브랜치 리뷰 F2): 여기 있던 "지금 커밋된
                             # 라벨의 BatteryTruth 는 전부 이 임계값 아래" 는 **거짓이다**. Task 7
                             # 이 그 문장을 쓴 뒤 Task 8 이 라벨을 새로 만들면서 뒤집혔다.
                             # 현행 라벨셋 `oracle/out/oracle_dataset.jsonl`(vocab v4-3arms,
                             # 커밋 ef7559ab)에서 kind=="battery" 행은 27개이고 soc 사다리는
                             # {0.02, 0.30, 0.50} rung 당 9행이다 -- 즉 **18/27 행(9 instance
                             # 중 6개)이 이 임계값 위**다. 대가는 가상이 아니라 지금 데이터의
                             # 2/3 이 unscored 로 빠지는 것이다. 재유도:
                             #   python -c "import json,sys; rs=[json.loads(l) for l in
                             #   open(sys.argv[1])]; b=[float(r['soc']) for r in rs if
                             #   r['kind']=='battery']; print(sum(s>0.2 for s in b),'/',len(b))" \
                             #   wm4spacecraft_manufacturing/oracle/out/oracle_dataset.jsonl

BASIS = {
    # [역사] 아래 문자열의 사다리 기록은 구세대 어휘(v3-4arms 이전)의 것이다 — 각 rung 에서
    # 굴린 팔 목록의 "Deprioritize" 는 이제 레지스트리에 없다. 숫자는 재측정 불가라 보존한다.
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
                "reference_action() returns None (unscored) there rather than inventing NOOP. "
                # ★ 2026-08-16 — 이 문자열이 **자기가 이미 무너진 전제를 계속 주장**하고 있었다.
                # 위 유도 전체(특히 "at D=20 the depot round trip is cheap enough that swapping now
                # beats tolerating a slower, degraded robot" 와 "SwapBattery is therefore correct at
                # every rung tested")는 `SwapBattery` 가 **시간을 쓰지 않던** 세대의 격자에서 나왔다.
                # 배송 커밋(`2b5637c3`) 이후 그 팔은 창고 예비 로봇의 실제 주행 시간을 쓴다.
                # 유도를 다시 돌리려면 배송 동역학 아래에서 격자를 재표집해야 하고(다음 사이클
                # 1순위), 그것은 이 수정 라운드의 범위 밖이다. 그래서 **규칙도 임계값도 건드리지
                # 않았다** — `BATTERY_DEEP_SOC` 는 그대로이고 `decision_acc` 열도 안 바뀐다.
                # 바꾼 것은 발행되는 문장이 자기 세대를 밝히게 만든 것뿐이다.
                "🔴 STALE PREMISE (2026-08-16, disclosed not corrected): every number and "
                "conclusion above was measured in the pre-courier generation, where SwapBattery "
                "applied instantly and consumed NO time. Since commit 2b5637c3 the arm dispatches "
                "a spare robot from the depot that must physically DRIVE to the site, so the "
                "'cheap depot round trip' premise and the 'correct at every rung tested' "
                "conclusion no longer follow from current dynamics. Measured on the current "
                "generation, the surrogate lane's SwapBattery boards run SLOWER than the "
                "identical-seed canonical baseline, monotonically in how often the arm fires "
                "(md/RESULTS_SWAPBATTERY_COURIER_2026-08-15.md §8-A). This rule has NOT been "
                "re-derived: BATTERY_DEEP_SOC and the scored a* are unchanged, so decision_acc "
                "columns are unaffected -- only this provenance text now states its generation. "
                "Re-deriving requires re-sampling the label grid under courier dynamics "
                "(next cycle's #1 item).",
    "fault": "oracle/out/n44_plus78_d20.jsonl, seed 1, D=20 (near depot), 1 fault instance only "
              "(severity 1.0, arms NOOP and Replace) -- NEITHER arm completes (NOOP closed "
              "184/313, Replace closed 243/313, both makespan Inf), so this grid CANNOT "
              "re-derive the rule below either (same outcome as the D=40 pass); the rule is left "
              "unchanged and treated as unverified-here. closed is directionally consistent with "
              "'agent_pending > 0 -> Replace' (Replace closes more than NOOP, agent_pending=3 on "
              "this row) but does not establish it. Historical provenance (not re-verified in "
              "this pass): firegrid_merged.jsonl, 42 fault instances over seeds 1-6, perfect "
              "separation (agent_pending > 0 -> Replace [24/24], == 0 -> NOOP [18/18]).",
    # [역사] 아래 문자열은 구세대 어휘(v3-4arms 이전)의 기록이다 — RelocateBuild·ReformTeam 은
    # 이제 레지스트리에 없고, zone 은 2026-08-24 (spec §5.1) 부터 채점되지 않는다(reference_action
    # 의 ZoneTruth 분기가 unscored 를 낸다). 이 항목은 그 규칙의 근거가 아니라 출처 보존용이다.
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
            # [역사] 아래 사다리 기록은 구세대 어휘(v3-4arms 이전)의 것이다 — "세 팔" 중
            # Deprioritize 는 이제 레지스트리에 없다. 숫자는 재측정 불가라 그대로 둔다.
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
        # SoC > BATTERY_DEEP_SOC(2026-08-31 이후 현재 0.1)는 이 격자가 테스트한 사다리 안에서도
        # 채점 근거가 없는 구간이다(2026-08-24 에 0.5->0.2 로 내리면서 n44_plus78_d20 사다리의
        # 0.30·0.50 rung 이 이 가지로 밀려났다 -- 위 BATTERY_DEEP_SOC 대입부의 대가 주석 참고;
        # 그 뒤 2026-08-31 에 REPLACE_SOC_THRESHOLD 사다리 이동으로 0.2->0.1 이 됐다). 근거가
        # 없는 구간에서 NOOP 을
        # 정답이라고 채점하면 없는 정답을 지어내는 것이 된다 -- 아래 reform 축과 **같은 이유로
        # 채점하지 않는다**(unscored).
        # 🔴 2026-08-25 정정(최종 브랜치 리뷰 F2): 여기 있던 "지금 커밋된 라벨의 BatteryTruth 는
        # 전부 이 임계값 아래라 이 가지에 아무도 들어오지 않는다" 는 **거짓이다**. Task 8 이
        # 라벨을 새로 만들면서 뒤집혔다 -- 현행 `oracle/out/oracle_dataset.jsonl`(vocab
        # v4-3arms, 커밋 ef7559ab)의 battery 행 27개 중 **18개가 이 가지로 들어온다**(soc
        # 사다리 {0.02, 0.30, 0.50}, rung 당 9행; 0.30·0.50 두 rung = 18행). 재유도 명령은
        # 위 BATTERY_DEEP_SOC 대입부 주석에 있다.
        return None, "battery", \
               "SoC>%.2f: above BATTERY_DEEP_SOC -- unscored (some of this range was tested by the " \
               "n44_plus78_d20 ladder up to 0.50, but the threshold now sits below it; see the " \
               "cost-of-disclosure comment above BATTERY_DEEP_SOC)" % BATTERY_DEEP_SOC

    if truth == "FaultTruth":
        pend = ev.get("agent_pending")
        if pend is None or int(pend) < 0:
            return None, "fault", "agent_pending not recorded"
        if int(pend) > 0:
            return "Replace", "fault", "the faulted robot still owed %d transport task(s)" % int(pend)
        return "NOOP", "fault", "the faulted robot owed no work; the fleet absorbs it"

    if truth == "ZoneTruth":
        # 2026-08-24 (spec §5.1): zone 은 LLM 결정 레인에서 빠졌다 -- surrogate 학습 증거로만
        # 쓴다. 닫힌 어휘(NOOP/Replace/SwapBattery)에 zone 의 수복이 없으므로 정답이 없다.
        # battery 의 untested regime 과 같은 관례로 **채점하지 않는다**.
        # 지우지 않고 명시적 unscored 로 남기는 이유: 옛 요약 행에 섞여 있는 zone 결정이 조용히
        # 아래 `reform` 폴백으로 떨어지면 사유가 "no measured grid" 로 잘못 찍힌다.
        return None, "zone", "zone 은 LLM 결정 레인에서 제거됐다(spec 2026-08-24 §5.1); unscored"

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
