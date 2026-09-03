"""3-agent 합성 파이프라인 — 관측 / 설계 / 조합.

왜 셋으로 가르는가 (2026-08-30 사용자 결정). 단일 프롬프트 판에서 모델이
`expressible: true` 를 냈고, 그 답은 **모델이 본 입력에 대해 불합리하지 않았다** —
`_zones_block` 이 `build_center`·`build_radius`·`max_shift`·`work_reach` 를 일부러 안
싣기 때문이다(정답 누수 금지). 그래서 손댈 자리는 프롬프트 문구가 아니라 **추론의 분해**다:

    agent-1  관측만 읽고 "이 사건이 무엇을 틀었나" 를 자연어 로그로
    agent-2  그 로그만 읽고 "어떤 tool 이 필요한가" 를 명세로 (+ expressible)
    agent-3  그 명세를 원시 인벤토리로 조합

🔴 이 파일이 지키는 계약 셋:

  (A) **정보 병목.** agent-2 는 원본 관측을 **못 본다.** 그래야 "분해가 실제로 정보를
      가공했는가" 가 측정 가능해지고, agent-1 이 놓친 것은 agent-2 도 못 본다.

  (B) **알파벳 실명(失明).** agent-2 는 19개 원시를 **못 본다.** 처음 보는 사건에 맞는
      tool 을 설계하는데 기존 어휘를 보여주면, 재는 것이 설계 능력이 아니라 **기존
      어휘로의 투영**이 된다. 대가는 정직하게: agent-3 가 조합 못 하면 `needs_primitive`
      이고, 그 `missing_primitive` 가 이 레인의 산출물이다.

  (C) **오라클 무접촉.** 어느 프롬프트에도 오라클 판정이 안 들어간다.
      `zone_relocate_norm`(= 최소 이동거리 = 사실상 정답)은 `MacroRequest` **스키마에는
      있고** 렌더만 안 되고 있다 — 즉 지금 누수를 막는 것은 타입도 게이트도 아니라 손으로
      유지되는 렌더 함수 하나다. 프롬프트 빌더가 셋으로 늘면 그 표면도 셋이 된다.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as syn  # noqa: E402

OBSERVATION = (
    "MEASURED STATE\n"
    "  harm = 0.31   work_at_risk = 0.42\n"
    "ACTIVE NO-GO ZONES (geometry as measured; one disc per live zone):\n"
    '  zone "zone_blk_1"\n'
    "    center            = [1.094, 0.416]\n"
    "    radius            = 0.07\n"
    "    covers            = 3 sub-assemblies whose staging area this disc overlaps\n"
)

REASONING_LOG = (
    "A circular no-go region appeared over the staging areas of three sub-assemblies. "
    "Navigating agents can no longer reach those staging circles, so every task that "
    "depends on them is frozen."
)

SPEC = {
    "tool_name": "clear_staging_obstruction",
    "params": '{"max_shift": {"type": "number"}}',
    "mechanism": "Moves staged geometry out of the blocked region.",
}


# =====================================================================================
# (A) 정보 병목 — agent-2 는 관측을 못 본다
# =====================================================================================

def test_design_context_excludes_the_raw_observation():
    """🔴 agent-2 의 프롬프트에 관측문이 들어가면 병목이 깨진다.

    변이: `build_design_context` 가 `state` 를 받아 싣도록 바꾸면 이 시험이 빨개진다.
    """
    ctx = syn.build_design_context(REASONING_LOG)
    assert "zone_blk_1" not in ctx
    assert "1.094" not in ctx
    assert "MEASURED STATE" not in ctx
    assert REASONING_LOG in ctx          # 대신 agent-1 의 로그는 통째로 들어간다


def test_observe_context_carries_the_observation():
    """agent-1 은 관측을 본다 — 병목의 입구다."""
    ctx = syn.build_observe_context(OBSERVATION)
    assert "zone_blk_1" in ctx
    assert "1.094" in ctx


# =====================================================================================
# (B) 알파벳 실명 — agent-2 는 19개 원시를 못 본다
# =====================================================================================

def test_design_context_names_no_primitive():
    """🔴 agent-2 의 프롬프트에 원시 이름이 하나라도 있으면 설계가 어휘로 투영된다.

    레지스트리 전수로 검사한다 — 목록을 여기 리터럴로 복붙하면 레지스트리가 자라도
    이 시험이 안 자란다.
    """
    ctx = syn.build_design_context(REASONING_LOG)
    for p in syn._prim.REGISTRY["primitives"]:
        assert p["name"] not in ctx, "agent-2 가 원시 %s 를 봤다" % p["name"]
    for q in syn._prim.REGISTRY["predicates"]:
        assert q["name"] not in ctx, "agent-2 가 술어 %s 를 봤다" % q["name"]


def test_compose_context_carries_the_spec():
    """agent-3 는 agent-2 의 명세를 통째로 받는다 — 그것이 유일한 입력이다."""
    ctx = syn.build_compose_context(SPEC)
    assert SPEC["mechanism"] in ctx
    assert SPEC["params"] in ctx
    assert SPEC["tool_name"] in ctx


def test_inventory_block_carries_the_whole_alphabet():
    """agent-3 는 알파벳에 있는 것을 전부 본다 — 조합이 그 일이므로.

    🔴 `enactable` 로 거르지 **않는다.** 오늘 집행 가능한 것은 넷뿐이지만, 프롬프트에서
    나머지를 숨기면 재는 것이 "모델의 조합 능력" 이 아니라 "하네스가 남긴 것" 이 된다
    (R40). 높은 reject 율은 정상 동작이고 그 자체가 산출물이다.

    🔴 반면 `known_lane == false` 로는 **거른다.** 그것은 하네스의 성질이 아니라 이 실험이
    zone 을 OOD 로 성립시키기 위해 정한 경계다(레지스트리의 `excluded_why`). 두 필터는 서로
    다른 것을 뜻하므로 하나로 읽으면 안 된다.
    """
    inv = syn.build_inventory_block()
    inside = [p for p in syn._prim.REGISTRY["primitives"] if p.get("known_lane") is not False]
    outside = [p for p in syn._prim.REGISTRY["primitives"] if p.get("known_lane") is False]
    assert inside
    if not outside:
        # 🔴 2026-09-02. `known_lane` 은 zone 절단 작업(`bca453d6`·`85ee99fa`)이 만든 필드이고
        #    이 브랜치의 레지스트리에는 **아직 없다**. 여기서 단언을 무르게 고치면
        #    (`>= 0` 류) 항진 명제가 되어 병합 뒤에도 아무것도 안 지킨다. 그래서 크게 건너뛴다 —
        #    zone 절단이 병합되는 순간 `outside` 가 채워지고 이 시험이 저절로 살아난다.
        pytest.skip("이 브랜치의 레지스트리에 known_lane=false 인 원시가 없다 "
                    "(zone 절단 미병합). 알파벳 밖 원시가 프롬프트에 안 실리는지는 "
                    "그 작업이 들어온 뒤에만 잴 수 있다.")
    for p in inside:
        assert p["name"] in inv
    for p in outside:
        assert p["name"] not in inv, "알파벳 밖 원시 %s 가 프롬프트에 있다" % p["name"]
    for q in syn._prim.REGISTRY["predicates"]:
        assert q["name"] in inv


def test_compose_context_excludes_the_raw_observation():
    """🔴 병목은 agent-3 에서도 유지된다.

    🔴 2026-09-02. agent-3 는 이제 명세만이 아니라 **agent-1 의 로그**도 받는다(B-2). 그래서
    이 가드는 로그를 실어 부른다 — 인자 하나로 부르면 새 채널을 통과시키기만 하고 아무것도
    안 지킨다. 건너는 것은 산문 계정이지 원본 관측이 아니라는 것이 여기서 재는 사실이다.
    """
    ctx = syn.build_compose_context(SPEC, REASONING_LOG)
    assert "zone_blk_1" not in ctx
    assert "MEASURED STATE" not in ctx
    assert REASONING_LOG in ctx          # 대신 로그는 통째로 들어간다


# =====================================================================================
# (D) task 밀도 — 세 프롬프트가 "무엇을 달성해야 하는가" 를 읽는다 (2026-09-02)
# =====================================================================================
# 🔴 왜. 포팅 전 `build_observe_context`·`build_design_context` 는 원칙·목표·본문 세 블록뿐
#    이었다. 단일 agent 판(`build_context`)이 싣는 `NOVEL PROPERTIES` 와 `WHAT MUST CHANGE`
#    가 통째로 빠져 있었고, 그래서 agent-2 는 **성공 기준을 못 읽은 채** tool 을 설계했다.

def test_observe_context_carries_the_task_framing():
    ctx = syn.build_observe_context(OBSERVATION)
    assert "NOVEL PROPERTIES OF THE EVENT" in ctx
    assert "WHAT MUST CHANGE" in ctx


def test_design_context_carries_the_task_framing():
    ctx = syn.build_design_context(REASONING_LOG)
    assert "NOVEL PROPERTIES OF THE EVENT" in ctx
    assert "WHAT MUST CHANGE" in ctx


def test_design_task_framing_points_at_nothing_it_cannot_see():
    """🔴 단일 판 문구를 그대로 재사용하면 안 되는 이유.

    그 문구는 "the observation above" 와 "the existing tools below" 를 가리키는데 agent-2 의
    context 에는 관측(병목)도 어휘 블록(별도 입력 필드)도 **없다**. 없는 것을 가리키는
    지시어는 블록이 빠진 것처럼 읽히므로 단계마다 참인 문구를 쓴다.
    """
    ctx = syn.build_design_context(REASONING_LOG)
    assert "observation above" not in ctx
    assert "tools below" not in ctx


def test_compose_spec_carries_the_principles_the_goal_and_the_account():
    """🔴 agent-3 는 명세 네 줄만 받고 있었다 — 약 25,000자 알파벳에 대해 1:29 였다.

    무슨 사건을 고치는 tool 인지도, 표면이 다섯인 것도, 하네스가 MILP 를 자동으로 재풀이
    한다는 것도 모른 채 body 를 짰다.
    """
    ctx = syn.build_compose_context(SPEC, REASONING_LOG)
    assert "PHYSICAL PRINCIPLES OF THIS BUILD" in ctx
    assert "FINAL GOAL" in ctx
    assert "WHAT THE EVENT BROKE" in ctx
    assert REASONING_LOG in ctx
    assert SPEC["mechanism"] in ctx


def test_compose_spec_names_no_primitive_outside_the_inventory_block():
    """🔴 늘어난 spec 블록이 알파벳을 두 번 싣지 않는다 — 인벤토리는 별도 필드 하나다."""
    ctx = syn.build_compose_context(SPEC, REASONING_LOG)
    for q in syn._prim.REGISTRY["primitives"] + syn._prim.REGISTRY["predicates"]:
        assert q["name"] not in ctx, "spec 블록이 원시 %s 를 실었다" % q["name"]


def test_agent_3_actually_receives_the_account(monkeypatch):
    """🔴 배선 시험. 빌더가 로그를 실어도 `synthesize_multi` 가 안 넘기면 소용이 없다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    seen = {}

    progs = _fake_programs(expressible=False)
    inner = progs["compose"]

    def compose(**kw):
        seen.update(kw)
        return inner(**kw)

    progs["compose"] = compose
    syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                         programs=progs)
    assert REASONING_LOG in seen["spec"], "agent-3 가 agent-1 의 로그를 못 받았다"


def test_inventory_block_carries_the_body_rule():
    """🔴 `5f71e3fd` 의 수정이 agent-3 에도 걸린다.

    그 커밋의 근거: 재풀이의 주체를 안 적으면 모델이 알파벳 밖 commit 단계를 지어낸다
    (`commit_respec` 이 실제로 그렇게 나왔다). 단일 판 `build_context` 에만 걸어 두면
    3-agent 레인의 agent-3 는 그 문장을 못 읽는다.
    """
    inv = syn.build_inventory_block()
    assert "BODY RULE" in inv
    assert "never write a commit" in inv


# =====================================================================================
# (C) 오라클 무접촉 — 셋 다
# =====================================================================================

def test_no_stage_renders_the_oracle_verdict():
    """🔴 `zone_relocate_norm` 은 최소 이동거리 = 사실상 정답이다.

    `MacroRequest` 스키마에 필드가 **실재하고** 렌더만 안 되고 있으므로, 프롬프트 빌더가
    늘 때마다 이 단언이 따라 늘어야 한다. 여기서는 세 컨텍스트 전부에서 그 이름과 값이
    안 나타나는 것을 본다.
    """
    poisoned = OBSERVATION + "\n    zone_relocate_norm = 0.2387\n"
    for name, ctx in (("observe", syn.build_observe_context(poisoned)),
                      ("design", syn.build_design_context(REASONING_LOG)),
                      # 🔴 agent-3 도 로그를 실은 모양 그대로 본다 — B-2 로 늘어난 표면이다.
                      ("compose", syn.build_compose_context(SPEC, REASONING_LOG))):
        if name == "observe":
            # agent-1 은 호출자가 준 관측을 그대로 받는다 — 누수를 막는 자리는
            # `_zones_block` 이지 여기가 아니다. 그래서 여기서는 단언하지 않고,
            # 아래 둘이 그 값이 **전파되지 않는 것**을 본다.
            continue
        assert "zone_relocate_norm" not in ctx, "%s 가 오라클 필드 이름을 실었다" % name
        assert "0.2387" not in ctx, "%s 가 오라클 값을 실었다" % name


# =====================================================================================
# 파이프라인 배선 — 유료 0건 (DummyLM)
# =====================================================================================

def test_pipeline_record_keeps_the_single_agent_key_set(monkeypatch):
    """🔴 레코드의 키 집합이 단일 agent 판과 **같아야** 한다.

    줄리아의 `_synth_view` · ψ 측정 · 원장이 전부 이 키들을 읽는다. 셋으로 쪼개면서
    키가 바뀌면 하류가 조용히 `nothing` 을 읽는다 — 이 레포가 이미 밟은 자리다
    (`SYNTH_LANE_KEYS` 에 `params` 가 없어 인터프리터에 안 도착하던 사건).
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    single = syn._blank(None, None, syn.SynthesisLedger())
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=_fake_programs())
    assert set(single).issubset(set(rec)), "단일 판의 키가 빠졌다: %s" % (set(single) - set(rec))


def test_expressible_comes_from_agent_2(monkeypatch):
    """🔴 판정의 출처가 agent-2 다 — 결정 agent 의 tool 인자가 아니다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=_fake_programs(expressible=False))
    assert rec["expressible"] is False
    assert rec["synthesis_event"] is True


def test_expressible_true_stops_before_agent_3(monkeypatch):
    """agent-2 가 '기존 어휘로 된다' 고 하면 조합은 안 돈다 — 유료 호출 하나를 아낀다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    calls = []
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=_fake_programs(expressible=True, spy=calls))
    assert rec["expressible"] is True
    assert rec["synthesis_event"] is False
    assert "compose" not in calls
    assert rec["tool_minted"] is not True


# =====================================================================================
# 배선 — 어느 레인이 도는가는 플래그 하나가 정한다
# =====================================================================================

def test_multi_agent_is_off_by_default(monkeypatch):
    """🔴 기본은 단일 agent 다. 새 레인이 조용히 기본이 되면 옛 판과 비교가 깨진다."""
    monkeypatch.delenv("SYNTH_MULTI_AGENT", raising=False)
    assert syn.multi_agent_enabled() is False


def test_multi_agent_flag_is_exactly_one(monkeypatch):
    """`"true"`/`"yes"` 를 받아 주지 않는다 — 유료 호출을 3배로 여는 스위치다."""
    monkeypatch.setenv("SYNTH_MULTI_AGENT", "true")
    assert syn.multi_agent_enabled() is False
    monkeypatch.setenv("SYNTH_MULTI_AGENT", "1")
    assert syn.multi_agent_enabled() is True


def test_run_synthesis_dispatches_to_the_single_lane_by_default(monkeypatch):
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    monkeypatch.delenv("SYNTH_MULTI_AGENT", raising=False)
    rec = syn.run_synthesis(expressible=True, kind="zone", state=OBSERVATION, tools=[],
                            ledger=syn.SynthesisLedger())
    assert "stages" not in rec                 # 단일 판의 레코드에는 없는 키
    assert rec["synthesis_event"] is False     # expressible=True 라 발화 아님


def test_run_synthesis_dispatches_to_the_multi_lane_when_on(monkeypatch):
    """🔴 multi 레인에서는 호출자가 준 `expressible` 을 **안 쓴다** — agent-2 가 낸다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    monkeypatch.setenv("SYNTH_MULTI_AGENT", "1")
    rec = syn.run_synthesis(expressible=True,          # 호출자는 True 를 준다
                            kind="zone", state=OBSERVATION, tools=[],
                            ledger=syn.SynthesisLedger(),
                            programs=_fake_programs(expressible=False))
    assert rec["stages"] == ["observe", "design", "compose"]
    assert rec["expressible"] is False         # agent-2 의 답이 이긴다
    assert rec["synthesis_event"] is True


class _Pred:
    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def _fake_programs(expressible=False, spy=None):
    """세 단계를 대신하는 순수 함수 셋. 프로바이더에 안 나간다 — 과금 0건."""
    def observe(**kw):
        spy is None or spy.append("observe")
        return _Pred(reasoning_log=REASONING_LOG)

    def design(**kw):
        spy is None or spy.append("design")
        return _Pred(expressible=expressible, tool_name=SPEC["tool_name"],
                     params=SPEC["params"], mechanism=SPEC["mechanism"])

    def compose(**kw):
        spy is None or spy.append("compose")
        return _Pred(body="1. translate_whole_build()", reach="composed",
                     missing_primitive="")

    return {"observe": observe, "design": design, "compose": compose}


# =====================================================================================
# 2026-09-02 — R2 가 라이브에서 드러낸 둘. 유료 0건.
#
# 측정(R2, gpt-4o, cache=False, 유료 6/6 진짜 호출): 두 레인 다 `expressible=False` 로
# 발화했는데 **둘 다 `reach="needs_primitive"` · `body_names=[]`** 였다. 그리고 그 "없다"가
# 둘 다 사실이 아니었다 — 알파벳에 답이 있다. 아래 두 게이트는 그 두 원인을 각각 잡는다.
#
#   (F1) agent-2 가 **disturbance 자체를 편집하는** 도구를 설계했다
#        (`ExclusionZoneModifier` = "존을 옮기거나 지운다"). funnel 어디에도 "그건 외생
#        제약이라 못 건드린다" 는 말이 없었고, `WHAT MUST CHANGE` 는 "모든 노드가 닫히게
#        하라" 뿐이라 **존을 지우면 자명하게 만족된다.**
#   (F3) 그 도구의 `params` 에 `"action": "string"`(= move/resize/remove 중 택1)이 있었는데
#        groundability 게이트가 **못 잡았다** — `ungrounded_params` 가 `[]` 를 냈고 재설계가
#        0회 돌았다. 원인: `_MECHANISM_CHOICE_SUFFIXES` 와 그 옆의 맨이름 목록이 손으로 든
#        어휘인데 `action` 이 거기 없다. 🔴 그리고 이 레포에는 그 함수의 시험이 **한 개도
#        없었다**(`grep -rn ungrounded_params test_*.py` = 0 hits) — 그래서 아무도 못 봤다.
# =====================================================================================

# 🔴 R2 가 실제로 낸 문자열이다(`r2_result.json` 의 zone 레인 `params`). 손으로 지어낸
#    입력으로 이 게이트를 재면 "잡고 싶은 모양" 을 재는 것이지 "실제로 새어 나온 모양" 을
#    재는 것이 아니다.
_R2_ZONE_PARAMS = ('{     "zone_id": "string",     "action": "string",     "parameters": {  '
                   '       "new_position": "array of float",         "new_size": "float"   '
                   '  } }')


def test_ungrounded_catches_the_mechanism_selector_that_r2_leaked():
    """🔴 F3. `action` 은 값이 아니라 **행동의 선택**이다 — 재설계가 걸려야 한다.

    이 단언이 없으면 agent-2 는 "무엇을 할지는 나중에 정한다" 는 명세를 그대로 통과시키고,
    agent-3 는 그 미정 명세를 조합할 수 없어 `needs_primitive` 를 낸다. R2 에서 실제로
    일어난 일이다.
    """
    bad = syn.ungrounded_params(_R2_ZONE_PARAMS)
    assert bad is not None, "빈-통과 방지: 못 쟀다(None)면 이 시험은 아무것도 안 잰다"
    assert "action" in bad, "R2 가 새보낸 mechanism selector 를 아직 못 잡는다: %r" % (bad,)


def test_ungrounded_catches_the_whole_mechanism_selector_vocabulary():
    """F3. 같은 범주의 이름들 — 맨이름과 접미사 양쪽."""
    for name in ("action", "operation", "command",
                 "recovery_action", "zone_operation", "repair_command"):
        blob = '{"%s": "string"}' % name
        assert syn.ungrounded_params(blob) == [name], \
            "%s 가 mechanism selector 로 안 잡힌다" % name


def test_ungrounded_does_not_flag_grounded_params():
    """🔴 F3 음성 대조. 넓히면 멀쩡한 명세가 재설계 루프에 걸려 유료 호출을 태운다.

    ⚠️ 이 단언이 없으면 위 두 시험은 `return sorted(d)`(전부 ungrounded) 로도 초록이다.
    """
    # 알파벳이 실제로 받는 인자들 — 세계가 공급할 수 있는 것.
    assert syn.ungrounded_params('{"agent": "string", "n": 1}') == []
    assert syn.ungrounded_params('{"zone_keys": ["a"], "faulted": null}') == []
    # 스칼라 선언과 닫힌 enum 은 통과한다(선언 모양).
    assert syn.ungrounded_params(
        '{"properties": {"n": {"type": "integer"}, '
        '"mode": {"type": "string", "enum": ["a", "b"]}}}') == []
    # 🔴 "못 쟀다"(None)와 "재서 통과했다"([])는 절대 안 섞인다.
    assert syn.ungrounded_params("not json at all") is None
    assert syn.ungrounded_params(None) is None


def test_design_context_says_the_disruption_is_not_editable():
    """🔴 F1. agent-2 는 **무엇을 못 건드리는지**를 들어야 한다.

    R2 측정: 그 문장이 없을 때 agent-2 는 zone 레인에서 "존을 옮기거나 지우는" 도구를
    설계했고, battery 레인에서는 "배터리를 일시 증폭하는"(물리적으로 없는) 도구를 설계했다.
    둘 다 **disturbance 를 되돌리는** 모양이다.

    🔴 이것은 정답 누수가 아니다. 무엇을 하라가 아니라 **무엇이 불변인가**를 적는다 —
    `PHYSICAL_PRINCIPLES` 의 "depot spares are scarce and are NOT replenished" 와 같은 범주다.
    그 성질은 아래 두 시험(`..._names_no_primitive` 재사용 · 오라클 필드 부재)이 지킨다.
    """
    ctx = syn.build_design_context(REASONING_LOG)
    assert syn._INVARIANT_DESIGN in ctx, "agent-2 가 불변 제약 문단을 못 받았다"
    assert syn._INVARIANT_DESIGN.strip(), "빈-통과 방지: 문단이 비어 있으면 위 단언은 항진이다"


def test_the_invariant_clause_names_no_primitive_and_no_oracle_field():
    """🔴 F1 의 대가를 여기서 막는다 — 이 문단이 어휘나 정답을 흘리면 안 된다.

    레지스트리 전수 + 오라클 필드 이름. 리터럴 목록을 여기 복붙하지 않는다.
    """
    clause = syn._INVARIANT_DESIGN
    for p in syn._prim.REGISTRY["primitives"]:
        assert p["name"] not in clause, "불변 문단이 원시 %s 를 흘린다" % p["name"]
    for q in syn._prim.REGISTRY["predicates"]:
        assert q["name"] not in clause, "불변 문단이 술어 %s 를 흘린다" % q["name"]
    assert "zone_relocate_norm" not in clause
    # 🔴 특정 사건 종류를 지목하면 그 사건에서만 참인 지시가 된다. 문단은 종류-무관이어야 한다.
    for word in ("battery_mild", "SwapBattery", "Replace", "NOOP"):
        assert word not in clause, "불변 문단이 사건/매크로 이름 %s 를 지목한다" % word


# =====================================================================================
# 2026-09-02 (F5) — 알파벳은 19개를 광고하는데 harness 가 부를 수 있는 것은 8개다.
#
# 측정(F1 직후 재실행, 유료 3): mild 레인이 처음으로 body 를 냈는데 그 두 번째 원시가
# `deprioritize_agent` 였다 — **집행 불가**(`ENACTABLE_TODAY` 밖). 즉 프롬프트가 못 부르는
# 원시 열하나를 부를 수 있는 것처럼 보여준 대가를 라이브에서 치렀다. 08-30 판정 R40 이
# 우려로 적어 둔 자리이고, 이제 실측된 실패다.
#
# 🔴 파이썬은 이 사실을 **계산할 수 없다.** `_enactability`(Julia)의 세 연언지 중 둘이
#    메서드 시그니처를 읽는다(`methods` · `Base.kwarg_decl`). 그래서 판정은 Julia 가 하고
#    레지스트리에 **도장**으로 실리며, 그 도장이 계산값과 일치하는지는 Julia 게이트가 잰다
#    (`test/minted_tool_enacts.jl`). 여기서는 **도장이 있고 렌더에 반영되는지**를 잰다.
# =====================================================================================

def _enactability_split():
    """레지스트리에서 (부를 수 있는 것, 못 부르는 것). 리터럴 목록을 여기 두지 않는다."""
    yes, no = [], []
    for p in syn._prim.REGISTRY["primitives"]:
        (yes if p.get("enactable") else no).append(p["name"])
    return yes, no


def test_every_primitive_declares_whether_the_harness_can_call_it():
    """🔴 F5 의 데이터 채널. 도장이 없는 항목은 **조용히 부를 수 있는 것이 된다.**

    삼상 규약: `True`/`False` 는 판정이고 **키 부재는 "못 쟀다"** 다. 이 시험이 부재를
    빨간색으로 만들어, 새 원시를 도장 없이 추가하는 것 자체를 막는다.
    """
    prims = syn._prim.REGISTRY["primitives"]
    assert len(prims) > 0, "빈-통과 방지: 원시가 0개면 아래 루프는 아무것도 안 잰다"
    for p in prims:
        assert "enactable" in p, (
            "원시 %s 에 enactable 도장이 없다 -- 파이썬은 이것을 계산할 수 없고, "
            "없으면 렌더가 '부를 수 있음' 으로 조용히 기울어진다" % p["name"])
        assert isinstance(p["enactable"], bool), \
            "%s 의 enactable 이 bool 이 아니다: %r" % (p["name"], p["enactable"])
        if not p["enactable"]:
            assert (p.get("unenactable_why") or "").strip(), (
                "%s 는 못 부르는데 이유가 비었다 -- 어느 연언지가 깨졌는지는 "
                "그 원시를 고칠 사람이 읽어야 하는 사실이다" % p["name"])


def test_the_inventory_marks_every_primitive_the_harness_cannot_call():
    """🔴 F5. 못 부르는 것에는 표식이 붙고, 부를 수 있는 것에는 **안 붙는다.**

    두 렌더러(단일 agent 의 `build_context` · 3-agent 의 `build_inventory_block`)가
    **같은 함수**를 쓰지만 둘 다 잰다 — 한쪽만 재면 다른 쪽이 조용히 갈릴 때 초록이다.
    """
    yes, no = _enactability_split()
    assert yes and no, "빈-통과 방지: 두 집합이 다 비지 않아야 대조가 성립한다 (%d/%d)" % (
        len(yes), len(no))
    for render in (syn.build_inventory_block(), syn.build_context(state="s")):
        lines = render.splitlines()
        marked = {ln.split()[1].rstrip(":") for ln in lines if syn._NOT_CALLABLE_MARK in ln
                  and ln.strip().startswith("-")}
        # 표식은 항목 헤더 줄에 붙는다. 이름으로 직접 훑는 편이 파싱보다 정직하다.
        for name in no:
            hdr = [ln for ln in lines if ln.startswith("- %s " % name)]
            assert hdr, "인벤토리에 %s 항목 헤더가 없다" % name
            assert syn._NOT_CALLABLE_MARK in hdr[0], \
                "%s 는 못 부르는데 표식이 없다" % name
        for name in yes:
            hdr = [ln for ln in lines if ln.startswith("- %s " % name)]
            assert hdr, "인벤토리에 %s 항목 헤더가 없다" % name
            assert syn._NOT_CALLABLE_MARK not in hdr[0], \
                "%s 는 부를 수 있는데 못 부른다고 표시됐다 -- 알파벳이 조용히 줄어든다" % name
        del marked


def test_the_body_rule_says_an_uncallable_primitive_kills_the_whole_body():
    """F5. 표식만으로는 부족하다 — body 규칙이 **귀결**을 말해야 한다.

    귀결은 실측이다: `enact_minted!` 은 body 의 원시 하나라도 `enactable == false` 면
    `reject:unenactable:<name>` 로 **한 발도 집행하지 않고** 돌아선다.
    """
    for render in (syn.build_inventory_block(), syn.build_context(state="s")):
        rule = [ln for ln in render.splitlines() if ln.startswith("BODY RULE:")]
        assert rule, "BODY RULE 줄이 없다"
        assert syn._NOT_CALLABLE_MARK in rule[0], \
            "BODY RULE 이 표식을 지목하지 않는다 -- 모델이 표식의 뜻을 모른다"


# =====================================================================================
# 2026-09-02 (F2) — agent-3 의 판정이 agent-2 로 되돌아간다. 유료 0건.
#
# 계기는 F5 런의 실측이다: mild 레인에서 agent-3 은 body 를 **이미 조합해 놓고도**
# `reach="needs_primitive"` 를 냈다. 없다고 한 것은 원시가 아니라 **agent-2 가 요구한
# 우선순위 정렬**이었고("... can release tasks, but it does not consider task priority"),
# 그 판정을 읽는 코드가 없었다. 아래 게이트들이 그 되먹임을 못박는다.
#
# 🔴 사용자 결정(2026-09-02): 되먹임은 **가려서** 보낸다. agent-3 의 산문이 인벤토리
#    이름을 그대로 적기 때문이고, 그대로 넘기면 계약 (B)(agent-2 의 알파벳 실명)가 끝난다.
# =====================================================================================

# 🔴 F5 런에서 agent-3 이 실제로 낸 문자열이다(`r2_after_f5.json` 의 mild 레인
#    `missing_primitive`). 손으로 지어낸 입력으로 가림을 재면 "가리고 싶은 모양" 을 재는
#    것이지 "실제로 새어 나온 모양" 을 재는 것이 아니다 — F3 게이트와 같은 규율.
_F5_MISSING = (
    "name: prioritize_task_reassignment\n"
    "edit surface: sched\n"
    'params: {"task_id": "string", "priority_level": "integer"}\n'
    "preconditions: Tasks must be released and available for reassignment.\n"
    "reversibility: NO\n"
    "consumes: computational resources\n"
    "WHY: The current inventory lacks a mechanism to prioritize tasks during reassignment. "
    "While `release_pending_assignments` can release tasks from a faulted robot, it does not "
    "consider task priority. A new primitive is needed to ensure that critical tasks are "
    "reassigned first, which is essential for the task_reallocation_tool to function as "
    "specified.")


def test_redaction_removes_every_inventory_name():
    """🔴 레지스트리 전수. 목록을 여기 리터럴로 두면 원시가 늘어도 이 시험이 안 자란다."""
    names = [p["name"] for p in syn._prim.REGISTRY["primitives"]]
    names += [q["name"] for q in syn._prim.REGISTRY["predicates"]]
    text = "\n".join("the composer has %s and also %s!(x)" % (n, n) for n in names)
    red, hits = syn.redact_inventory_names(text)
    for n in names:
        assert n not in red, "가림이 %s 를 흘렸다" % n
    assert set(hits) == set(names), "기록된 적중 목록이 실제와 다르다: %s" % (
        set(names) ^ set(hits))


def test_redaction_keeps_the_signal_that_f5_measured():
    """🔴 가림이 신호까지 지우면 F2 는 아무것도 안 나른다.

    지워져야 하는 것은 **인벤토리 이름 하나**이고, 남아야 하는 것은 (a) agent-3 이 지어낸
    이름(인벤토리에 없다)과 (b) 이유 문장이다.
    """
    red, hits = syn.redact_inventory_names(_F5_MISSING)
    assert hits == ["release_pending_assignments"], "가린 이름이 예상과 다르다: %s" % (hits,)
    assert "release_pending_assignments" not in red
    assert syn._REDACTED_NAME in red
    assert "does not consider task priority" in red, "신호 문장이 같이 지워졌다"
    assert "prioritize_task_reassignment" in red, "agent-3 이 지어낸 이름까지 지웠다"


def test_redaction_does_not_maul_a_longer_identifier():
    """`release_pending_assignments_v2` 는 인벤토리에 없다 — 부분 일치로 자르면 안 된다."""
    red, hits = syn.redact_inventory_names("call release_pending_assignments_v2 now")
    assert hits == [] and red == "call release_pending_assignments_v2 now"


def _seq_programs(reaches, expressibles=(False, False), spy=None, missing=_F5_MISSING,
                  missing_always=False):
    """agent-2·agent-3 이 호출마다 **다른 답**을 내는 가짜 셋. 프로바이더에 안 나간다.

    🔴 `missing_always` 는 라이브에서 실제로 있을 수 있는 모양을 만든다 — 모델이 `reach`
    를 `composed` 로 내면서 `missing_primitive` 필드도 같이 채우는 경우.
    """
    seen = {"design": 0, "compose": 0}
    kw_log = {"design": [], "compose": []}

    def observe(**kw):
        spy is None or spy.append("observe")
        return _Pred(reasoning_log=REASONING_LOG)

    def design(**kw):
        i = seen["design"]
        seen["design"] += 1
        kw_log["design"].append(kw)
        spy is None or spy.append("design")
        ex = expressibles[min(i, len(expressibles) - 1)]
        return _Pred(expressible=ex, tool_name="%s_%d" % (SPEC["tool_name"], i),
                     params=SPEC["params"], mechanism="%s (attempt %d)" % (SPEC["mechanism"], i))

    def compose(**kw):
        i = seen["compose"]
        seen["compose"] += 1
        kw_log["compose"].append(kw)
        spy is None or spy.append("compose")
        reach = reaches[min(i, len(reaches) - 1)]
        return _Pred(body="1. translate_whole_build()", reach=reach,
                     missing_primitive=(
                         missing if (missing_always or reach == "needs_primitive") else ""))

    return {"observe": observe, "design": design, "compose": compose}, kw_log


def test_the_composer_verdict_reaches_agent_2(monkeypatch):
    """🔴 배선 시험. 되먹임을 만들어도 두 번째 design 호출에 안 실리면 소용이 없다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs(["needs_primitive", "composed"])
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["stages"] == ["observe", "design", "compose", "design", "compose"]
    assert kw["design"][0]["composer_feedback"] == "", "첫 설계가 되먹임을 봤다"
    fb = kw["design"][1]["composer_feedback"]
    assert fb and "does not consider task priority" in fb
    assert rec["recomposed"] is True and rec["reach"] == "composed"


def test_the_feedback_agent_2_reads_names_no_primitive(monkeypatch):
    """🔴 계약 (B). 실제로 **보내진** 문자열을 레지스트리 전수로 본다 — 빌더가 아니라."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs(["needs_primitive", "composed"])
    syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                         programs=progs)
    fb = kw["design"][1]["composer_feedback"]
    for q in syn._prim.REGISTRY["primitives"] + syn._prim.REGISTRY["predicates"]:
        assert q["name"] not in fb, "agent-2 가 되먹임에서 원시 %s 를 봤다" % q["name"]


def test_a_composed_body_does_not_trigger_the_loop(monkeypatch):
    """조합에 성공한 판에서 두 번 더 과금하지 않는다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs(["composed"], spy=spy)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False and rec["compose_feedback"] is None


def test_composed_does_not_trigger_even_when_the_field_is_filled_in(monkeypatch):
    """🔴 발화 조건은 `reach == "needs_primitive"` 하나다 — 필드의 유무가 아니다.

    라이브 모델은 `reach="composed"` 를 내면서 `missing_primitive` 를 **같이 채운다**. 발화를
    "정의가 비지 않았는가" 로만 걸면 조합에 성공한 판에서 유료 2건이 조용히 나간다.
    (변이 M2 가 이 시험 없이는 초록이었다 — 다른 가드가 변이를 대신 막고 있었다.)
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs(["composed"], spy=spy, missing_always=True)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False and rec["compose_feedback"] is None


def test_an_empty_missing_primitive_does_not_trigger_the_loop(monkeypatch):
    """🔴 `needs_primitive` 인데 정의가 비면 되먹일 내용이 없다 — 유료 2건을 아낀다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs(["needs_primitive"], spy=spy, missing="   ")
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False


def test_the_loop_runs_at_most_once(monkeypatch):
    """🔴 두 번째도 실패하면 기록하고 넘어간다 — 안 도는 루프가 최악이다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs(["needs_primitive"], spy=spy)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy.count("design") == 2 and spy.count("compose") == 2
    assert rec["recomposed"] is True and rec["reach"] == "needs_primitive"


def test_the_first_attempt_survives_in_the_record(monkeypatch):
    """🔴 되먹임이 성공하면 무엇이 그 전에 있었는지가 기록에서 사라지면 안 된다.

    `ungrounded_params` 가 첫 적중을 보존하는 것과 같은 규율 — 게이트의 효과를 나중에
    셀 수 있어야 한다.
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, _ = _seq_programs(["needs_primitive", "composed"])
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["reach_first"] == "needs_primitive" and rec["reach"] == "composed"
    assert rec["missing_primitive_first"] == _F5_MISSING
    assert rec["tool_name_first"].endswith("_0") and rec["tool_name"].endswith("_1")
    assert rec["spec_changed_by_feedback"] is True
    assert rec["compose_feedback_redacted"] == ["release_pending_assignments"]


def test_the_redesign_does_not_overwrite_the_firing_verdict(monkeypatch):
    """🔴 `expressible` 은 이 사건의 발화 판정이고 이미 발화했다. 두 번째 답은 옆에 적는다.

    덮어쓰면 `expressible=False` 비율의 분모가 사건마다 달라진다 — 이 레포가 이미 밟은 자리
    (`macro_tool_agree`).
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, _ = _seq_programs(["needs_primitive", "composed"], expressibles=(False, True))
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["expressible"] is False
    assert rec["expressible_after_recompose"] is True
    assert rec["synthesis_event"] is True
