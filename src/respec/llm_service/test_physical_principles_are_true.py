"""🔴 2026-09-05. `PHYSICAL_PRINCIPLES` 는 레지스트리가 아니라 **이 시뮬레이터의 구조**라서
손으로 유지된다 — 그래서 반드시 낡는다. 실제로 낡아 있었다.

원칙 3 이 이렇게 적혀 있었다:

    "A goal whose cargo is moved by a lift transform, not by a navigating agent, is not
     stopped by a zone at all."

**그 뒷문은 스케줄 DAG 가 금지한다.** `construction_schedule.jl` 의
`required_predecessors` 가 `LiftIntoPlace <- DepositCargo <- TransportUnitGo` 로 못박아서
lift 는 운반유닛이 이미 몰고 간 뒤에만 활성화된다. 그런데 유료 zone 런 12판 중 **실패한 8판
전부**가 agent-2 의 `mechanism` 에서 이 문장을 되읊었고("without an RVO-driven navigating
agent", "non-navigating lift transfer"), 완주한 4판은 하나도 안 그랬다(12/12 완전분리).
즉 프롬프트가 **세계에 없는 결과를 주장해서** agent-2 를 지는 설계로 몰고 있었다
(memory: prompt-asserts-consequences-the-world-lacks).

이 시험은 그 문장이 다시 기어들어오는 것을 막고, 그 자리에 넣은 사실이 **줄리아 소스와
실제로 같은지**를 잰다. 산문으로 두면 다음 사람이 못 지킨다. 유료 0건 — 파일만 읽는다.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, "..", "..", ".."))
_SCHED_JL = os.path.join(_ROOT, "src", "construction_schedule.jl")
_ARTIFACT = os.path.join(_ROOT, "src", "decision", "core",
                         "world_interface.json")


def _required_predecessors():
    """`required_predecessors(::T) = Dict(...)` 를 소스에서 거둔다.

    ⚠️ 조용한 0 을 막는 것은 아래 (0) 의 개수 대조다 — 정의 문법이 바뀌면 이 파서는
    빈손이 되는데, 그때 이 파일은 초록이 아니라 빨개져야 한다.
    """
    src = open(_SCHED_JL, encoding="utf-8").read()
    out = {}
    pat = re.compile(
        r"^required_predecessors\(\s*\w*\s*::\s*(\w+)\s*\)\s*=\s*Dict\(([^\n]*?)\)\s*(?:#|$)",
        re.M)
    for node, body in pat.findall(src):
        out[node] = set(re.findall(r"([A-Z]\w+)\s*=>", body))
    return out


# ==========================================================================================
# (0) 파서가 실제로 무언가를 거뒀다 — 음성 대조
# ==========================================================================================
def test_the_parser_is_not_silently_empty():
    rp = _required_predecessors()
    assert len(rp) >= 10, ("required_predecessors 파싱이 빈손이다 — 정의 문법이 바뀌었다면 "
                           "이 시험을 고쳐야지 통과시키면 안 된다", sorted(rp))
    assert "LiftIntoPlace" in rp and "DepositCargo" in rp, sorted(rp)


# ==========================================================================================
# (1) 프롬프트가 주장하는 사슬이 줄리아 소스와 같다
# ==========================================================================================
def test_the_delivery_chain_in_the_prompt_is_the_one_the_dag_enforces():
    rp = _required_predecessors()
    # lift 는 하역 뒤에만, 하역은 운반유닛 이동 뒤에만.
    assert rp["LiftIntoPlace"] == {"DepositCargo"}, rp["LiftIntoPlace"]
    assert "TransportUnitGo" in rp["DepositCargo"], rp["DepositCargo"]
    assert rp["TransportUnitGo"] == {"FormTransportUnit"}, rp["TransportUnitGo"]

    p = SY.PHYSICAL_PRINCIPLES
    assert ("FormTransportUnit -> TransportUnitGo -> DepositCargo -> LiftIntoPlace"
            in p), "프롬프트가 더 이상 그 순서를 적지 않는다"
    assert "required_predecessors" in p, "프롬프트가 근거 함수를 안 댄다"


# ==========================================================================================
# (2) 🔴 지는 뒷문이 다시 들어오지 않았다
# ==========================================================================================
def test_the_prompt_no_longer_advertises_a_non_navigating_delivery_route():
    p = SY.PHYSICAL_PRINCIPLES.lower()
    assert "is not stopped by a zone at all" not in p
    assert "teleports)" not in p
    # 뒷문을 명시적으로 닫았다고 말한다.
    assert "every" in p and "cargo delivery passes through a navigating agent" in p


# ==========================================================================================
# (3) 프롬프트가 이름을 안 대는 것이 세계에도 없다
# ==========================================================================================
def test_no_callable_performs_a_lift_or_a_teleport():
    ms = json.load(open(_ARTIFACT, encoding="utf-8"))["methods"]
    callable_names = [m["name"] for m in ms if m.get("callable")]
    assert len(callable_names) > 100, len(callable_names)   # 음성 대조
    for word in ("lift", "teleport"):
        hits = [n for n in callable_names if word in n.lower()]
        assert hits == [], (word, hits)


# ==========================================================================================
# (4) 이기는 동사를 프롬프트에 적지 않았다 — 적으면 이 레인이 재는 것이 모델이 아니라 우리다
# ==========================================================================================
def test_the_fix_does_not_name_the_winning_verbs():
    p = SY.PHYSICAL_PRINCIPLES
    for verb in ("restage_all_blocked!", "translate_whole_build!", "zone_diagnoses",
                 "zone_blockage"):
        assert verb not in p, verb
