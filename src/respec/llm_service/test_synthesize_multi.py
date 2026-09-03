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

  (B) **구현 어휘 실명(失明).** agent-2 는 구현 함수 이름을 **못 본다.** 처음 보는 사건에
      맞는 tool 을 설계하는데 기존 어휘를 보여주면, 재는 것이 설계 능력이 아니라 **기존
      어휘로의 투영**이 된다. 대가는 정직하게: agent-3 가 못 쓰겠으면 `wrote=false` 이고,
      그 `reasoning` 이 이 레인의 산출물이다.

      🔴 2026-09-03 (Task 10). **모집단이 바뀌었다.** 옛 판은 이 계약을 삭제된 19-원시
      레지스트리(`primitive_registry.py`) 전수로 쟀다 — D5·D7·D8 이 그 인벤토리를 없앴으므로
      그 시험들은 `AttributeError` 로 죽었다(= 게이트가 아니라 빨간 시험). 계약 자체는
      살아 있고, 오늘 그것을 나르는 살아 있는 모집단은 **`world_interface.json` 의 메서드
      이름 147개**다: agent-3 은 그 인터페이스를 입력 필드로 **정당하게** 받고, agent-2 는
      받으면 안 된다. 그래서 아래 누수 가드들은 `_impl_names()` 를 쓴다.
      ⚠️ 리터럴 목록을 복붙하지 않는 규율은 그대로다 — 모집단이 자라면 가드도 자란다.

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
import world_interface as WI  # noqa: E402


def _impl_names():
    """계약 (B) 의 **살아 있는 모집단**: 이 모듈이 이미 가진 함수 이름 전부.

    🔴 리터럴이 아니라 `world_interface.json` 에서 읽는다 — 인터페이스가 자라면 이 가드도
    자란다. 그것이 옛 레지스트리 전수 규율의 후계다.
    """
    return sorted({m["name"] for m in WI.load_world_interface()["methods"]})


def test_the_leak_population_is_not_empty_and_the_detector_fires():
    """🔴 음성 대조. 모집단이 비면 아래 누수 가드 전부가 **공허하게** 통과한다 — 옛
    레지스트리 판이 정확히 그 방식으로 죽었다(모듈이 없어져 `AttributeError`).
    그리고 검출기가 실제로 잡는지도 여기서 태운다."""
    names = _impl_names()
    assert len(names) > 100, "모집단이 %d 개다 — world_interface.json 이 비었거나 못 읽었다" % len(
        names)
    # 🔴 부분 일치가 아니라 **부분 문자열 검출**이다(가드 본문과 같은 `in`) — 심은 이름 하나가
    #    다른 이름의 접미사이면 히트가 둘일 수 있다. 그래서 등호가 아니라 **포함**을 잰다.
    #    (`aa910a5b` 시점 실측: `active_restriction_zones` 를 심으면 `restriction_zones` 도 걸린다.)
    leaky = "you may call %s to fix this" % names[0]
    assert names[0] in [n for n in names if n in leaky], "검출기가 심은 누수를 못 봤다"
    clean = "the zone froze three staging areas and nothing can reach them"
    assert [n for n in names if n in clean] == [], (
        "깨끗한 문장에서 오탐이 났다 — 이 모집단으로는 가드가 못 쓴다: %s"
        % [n for n in names if n in clean])


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
# G1 (2026-09-03). `synthesize_multi` **거절한다** — agent-3 에게 넘길 인터페이스가 비었으면
# 유료 호출 하나도 안 쓰고 기록으로 거절한다(`refused`). 이 파일의 시험들은 그 가드 **아래**의
# 단계들을 재므로 인터페이스를 하나 준다. 가드 자체는
# `test_synthesis_record_contract.py` 가 재고, **비-공백 짝**(인터페이스가 있으면 안 터진다)은
# 아래 fixture 를 쓰는 시험 전부가 매번 다시 증명한다.
# =====================================================================================
@pytest.fixture(autouse=True)
def _supply_a_compose_interface(monkeypatch):
    monkeypatch.setattr(syn, "compose_interface",
                        lambda blob=None: "WORLD INTERFACE (test double)")


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

    `world_interface.json` 전수로 검사한다 — 목록을 여기 리터럴로 복붙하면 인터페이스가
    자라도 이 시험이 안 자란다(옛 레지스트리 전수 규율의 후계, 헤더 (B) 참조).
    """
    ctx = syn.build_design_context(REASONING_LOG)
    for n in _impl_names():
        assert n not in ctx, "agent-2 가 구현 함수 %s 를 봤다" % n


def test_compose_context_carries_the_spec():
    """agent-3 는 agent-2 의 명세를 통째로 받는다 — 그것이 유일한 입력이다."""
    ctx = syn.build_compose_context(SPEC)
    assert SPEC["mechanism"] in ctx
    assert SPEC["params"] in ctx
    assert SPEC["tool_name"] in ctx


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
    # 🔴 2026-09-02 (F7). 이 목록은 원래 둘뿐이었고 **셋째가 살아 있었다**:
    #    `PHYSICAL_PRINCIPLES` §1 이 "this inventory deliberately contains no primitive…" 로
    #    끝나는데 agent-2 의 문맥에는 인벤토리가 없다(별도 입력 필드다). 지시어를 일반 규칙으로
    #    잡을 방법은 없어서 — "this"/"above"/"below" 를 전부 금지하면 참인 문장까지 걸린다 —
    #    목록으로 둔다. **새 블록을 agent-2 에 더할 때마다 여기 한 줄이 늘어야 한다.**
    for deictic in ("observation above", "tools below", "this inventory",
                    "the inventory above", "the inventory below", "listed below"):
        assert deictic not in ctx, "agent-2 가 없는 것을 가리키는 지시어를 읽는다: %r" % deictic


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
    for q in [{"name": n} for n in _impl_names()]:
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
        # ✅ Task 8 (2026-09-03). agent-3 은 인벤토리에서 조합하지 않고 **구현을 쓴다** —
        #    출력 필드가 `body`/`reach`/`missing_primitive` 에서 아래 여섯으로 바뀌었다.
        #    가짜가 옛 모양을 내면 이 파일은 초록인 채 **아무도 안 내는 모양**을 재게 된다.
        return _Pred(impl_name="clear_staging_obstruction!",
                     impl_code=("function clear_staging_obstruction!(env; max_shift = 1.0)\n"
                                "    return (status = :moved,)\nend\n"),
                     params='{"max_shift": {"type": "number"}}',
                     surface="scene_tree", reversible=True, wrote=True,
                     reasoning="the staging discs can be shifted out of the blocked region")

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
    agent-3 는 그 미정 명세로 구현을 못 써서 `wrote=false` 를 낸다. R2 에서 실제로
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

    `world_interface.json` 전수 + 오라클 필드 이름. 리터럴 목록을 여기 복붙하지 않는다.
    """
    clause = syn._INVARIANT_DESIGN
    for n in _impl_names():
        assert n not in clause, "불변 문단이 구현 함수 %s 를 흘린다" % n
    assert "zone_relocate_norm" not in clause
    # 🔴 특정 사건 종류를 지목하면 그 사건에서만 참인 지시가 된다. 문단은 종류-무관이어야 한다.
    for word in ("battery_mild", "SwapBattery", "Replace", "NOOP"):
        assert word not in clause, "불변 문단이 사건/매크로 이름 %s 를 지목한다" % word


# =====================================================================================
# 2026-09-02 (F2) — agent-3 의 판정이 agent-2 로 되돌아간다. 유료 0건.
#
# 계기는 F5 런의 실측이다: mild 레인에서 agent-3 은 body 를 **이미 조합해 놓고도**
# `reach="needs_primitive"` 를 냈다. 없다고 한 것은 원시가 아니라 **agent-2 가 요구한
# 우선순위 정렬**이었고("... can release tasks, but it does not consider task priority"),
# 그 판정을 읽는 코드가 없었다. 아래 게이트들이 그 되먹임을 못박는다.
#
# 🔴 2026-09-03 (Task 10) — **되먹임의 트리거와 증거가 둘 다 옮겨졌다. 루프 자체는 그대로다.**
#   · 트리거: `reach == "needs_primitive"` → **`wrote is False`**. agent-3 은 인벤토리에서
#     조합하지 않고 코드를 쓰므로(D8) "조합 못 하겠다" 라는 사건이 "구현을 못 쓰겠다" 가 됐다.
#     `WriteToolImpl` 은 `reach` 를 출력 필드로 **선언하지 않는다** — 라이브 판에서 그 값은
#     언제나 `""` 라, 옛 트리거를 그대로 두면 이 루프가 **영영 안 돈다**(조용한 무동작).
#   · 증거: `missing_primitive`(agent-3 이 더는 안 낸다) → **`reasoning`**
#     (`WriteToolImpl` 의 chain-of-thought, `wrote=false` 를 설명하는 유일한 실제 출력).
#   · 가림(`redact_inventory_names`)은 **사라졌다** — 계약 (B) 의 옛 모집단(19-원시 알파벳)이
#     없으므로 가릴 것이 없다(D5). `compose_feedback_redacted` 는 그래서 영영 `None`
#     ("가림이 안 돌았다")이고 `[]`("돌았는데 하나도 안 걸렸다")가 아니다 — 삼상 규약.
#   🔴 `None` 은 `synthesize.py` 가 스스로 적어 둔 긴장이다(같은 파일이 R19 의 "영영 None 인
#      필드는 키째 지운다" 규칙과 다르게 처리한다). 여기서는 **오늘의 값을 박제**한다 —
#      그 결정은 이 태스크의 소유가 아니다.
# =====================================================================================

# 🔴 F5 런에서 agent-3 이 실제로 낸 문자열이다(`r2_after_f5.json` 의 mild 레인). 손으로
#    지어낸 입력으로 되먹임을 재면 "보내고 싶은 모양" 을 재는 것이지 "실제로 나온 모양" 을
#    재는 것이 아니다 — F3 게이트와 같은 규율. (필드 이름만 `missing_primitive` →
#    `reasoning` 으로 옮겼고 **문자열은 한 글자도 안 바꿨다**.)
_F5_ACCOUNT = (
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


def _seq_programs(wrotes, expressibles=(False, False), spy=None, account=_F5_ACCOUNT,
                  account_always=False, params=None):
    """agent-2·agent-3 이 호출마다 **다른 답**을 내는 가짜 셋. 프로바이더에 안 나간다.

    `wrotes` 는 agent-3 의 `wrote` 자기신고 순열이다(`False` = 못 쓰겠다 = 되먹임 발화).
    🔴 `account_always` 는 라이브에서 실제로 있을 수 있는 모양을 만든다 — 모델이
    `wrote=true` 를 내면서 `reasoning` 도 같이 채우는 경우(거의 언제나 그렇다).
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
                     params=(SPEC["params"] if params is None else params),
                     mechanism="%s (attempt %d)" % (SPEC["mechanism"], i))

    def compose(**kw):
        i = seen["compose"]
        seen["compose"] += 1
        kw_log["compose"].append(kw)
        spy is None or spy.append("compose")
        wrote = wrotes[min(i, len(wrotes) - 1)]
        return _Pred(impl_name=("clear_staging_obstruction!" if wrote else ""),
                     impl_code=("function clear_staging_obstruction!(env; max_shift = 1.0)\n"
                                "    return (status = :moved,)\nend\n" if wrote else ""),
                     params='{"max_shift": {"type": "number"}}',
                     surface="scene_tree", reversible=True, wrote=wrote,
                     reasoning=(account if (account_always or not wrote) else ""))

    return {"observe": observe, "design": design, "compose": compose}, kw_log


def test_the_composer_verdict_reaches_agent_2(monkeypatch):
    """🔴 배선 시험. 되먹임을 만들어도 두 번째 design 호출에 안 실리면 소용이 없다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs([False, True])
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["stages"] == ["observe", "design", "compose", "design", "compose"]
    assert kw["design"][0]["composer_feedback"] == "", "첫 설계가 되먹임을 봤다"
    fb = kw["design"][1]["composer_feedback"]
    assert fb and "does not consider task priority" in fb
    assert rec["recomposed"] is True and rec["wrote"] is True


def test_the_feedback_agent_2_reads_names_no_primitive(monkeypatch):
    """🔴 계약 (B). 실제로 **보내진** 문자열을 `world_interface.json` 전수로 본다 — 빌더가
    아니라. ⚠️ 오늘 되먹임은 **날것 그대로** 간다(가림 폐지, D5). 그러므로 이 가드는
    "가림이 잘 도는가" 가 아니라 **"agent-3 의 설명 자체가 구현 이름을 안 흘리는가"** 를
    잰다 — `_F5_ACCOUNT` 는 실측 문자열이고 그 안에 `release_pending_assignments` 가
    들어 있으므로, 이 시험은 **오늘 정당하게 빨갛다면 그것이 참인 관측이다.**
    (`_F5_ACCOUNT` 의 그 이름은 삭제된 알파벳의 이름이고 `world_interface.json` 의 메서드가
    아니다 — 그래서 오늘 이 가드는 통과한다. 그 이름이 인터페이스에 생기는 날 빨개지고,
    그때 가릴지 말지는 그 시점의 결정이다.)"""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs([False, True])
    syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                         programs=progs)
    fb = kw["design"][1]["composer_feedback"]
    for q in [{"name": n} for n in _impl_names()]:
        assert q["name"] not in fb, "agent-2 가 되먹임에서 원시 %s 를 봤다" % q["name"]


def test_a_composed_body_does_not_trigger_the_loop(monkeypatch):
    """조합에 성공한 판에서 두 번 더 과금하지 않는다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs([True], spy=spy)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False and rec["compose_feedback"] is None


def test_composed_does_not_trigger_even_when_the_field_is_filled_in(monkeypatch):
    """🔴 발화 조건은 `wrote is False` 하나다 — 증거 필드의 유무가 아니다.

    라이브 모델은 `wrote=true` 를 내면서 `reasoning` 을 **언제나 채운다**(chain-of-thought
    라서 비는 판이 없다). 발화를 "설명이 비지 않았는가" 로만 걸면 성공한 판에서 유료 2건이
    조용히 나간다. (변이 M2 가 이 시험 없이는 초록이었다 — 다른 가드가 변이를 대신 막고 있었다.)
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs([True], spy=spy, account_always=True)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False and rec["compose_feedback"] is None


def test_an_empty_missing_primitive_does_not_trigger_the_loop(monkeypatch):
    """🔴 `wrote=false` 인데 설명이 비면 되먹일 내용이 없다 — 유료 2건을 아낀다.

    🔴 이 연언지는 fix round 1 이 실측으로 되살린 것이다: `wrote is False` 하나로 걸었더니
    되먹임 문자열에 증거 자리가 `"\n\n\n\n"` 인 채로 유료 2건이 나갔다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs([False], spy=spy, account="   ")
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy == ["observe", "design", "compose"]
    assert rec["recomposed"] is False


def test_the_loop_runs_at_most_once(monkeypatch):
    """🔴 두 번째도 실패하면 기록하고 넘어간다 — 안 도는 루프가 최악이다."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    spy = []
    progs, _ = _seq_programs([False], spy=spy)
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert spy.count("design") == 2 and spy.count("compose") == 2
    assert rec["recomposed"] is True and rec["wrote"] is False


def test_the_first_attempt_survives_in_the_record(monkeypatch):
    """🔴 되먹임이 성공하면 무엇이 그 전에 있었는지가 기록에서 사라지면 안 된다.

    `ungrounded_params` 가 첫 적중을 보존하는 것과 같은 규율 — 게이트의 효과를 나중에
    셀 수 있어야 한다.
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, _ = _seq_programs([False, True])
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["wrote_first"] is False and rec["wrote"] is True
    assert rec["impl_name_first"] == "" and rec["impl_name"] == "clear_staging_obstruction!"
    assert rec["tool_name_first"].endswith("_0") and rec["tool_name"].endswith("_1")
    assert rec["spec_changed_by_feedback"] is True
    # 🔴 삼상. 가림은 **안 돈다**(계약 (B) 의 옛 모집단이 없다) — `None`("안 돌았다")이지
    #    `[]`("돌았는데 하나도 안 걸렸다")가 아니다.
    assert rec["compose_feedback_redacted"] is None


def test_the_redesign_does_not_overwrite_the_firing_verdict(monkeypatch):
    """🔴 `expressible` 은 이 사건의 발화 판정이고 이미 발화했다. 두 번째 답은 옆에 적는다.

    덮어쓰면 `expressible=False` 비율의 분모가 사건마다 달라진다 — 이 레포가 이미 밟은 자리
    (`macro_tool_agree`).
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, _ = _seq_programs([False, True], expressibles=(False, True))
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["expressible"] is False
    assert rec["expressible_after_recompose"] is True
    assert rec["synthesis_event"] is True


def test_the_record_says_which_spec_fields_the_feedback_moved(monkeypatch):
    """🔴 2026-09-02 F2 실측. mild 레인에서 재설계는 mechanism 산문에 "이제 그 없는 능력을
    요구하지 않는다" 는 문장을 **덧붙이고** `params` 는 바이트 동일로 두었다. 불리언 하나로는
    진짜 재명세와 준수 선언이 같은 값이 된다.
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, _ = _seq_programs([False, True])
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    # 가짜 agent-2 는 이름과 기전만 바꾸고 params 는 그대로 둔다 — 실측된 모양 그대로다.
    assert rec["spec_changed_fields"] == ["tool_name", "mechanism"]
    assert "params" not in rec["spec_changed_fields"]
    assert rec["spec_changed_by_feedback"] is True


# =====================================================================================
# 2026-09-02 (F7) — 명세자에게의 분업. 유료 0건.
#
# F2 런의 실측: agent-2 는 "속도·전하·우선순위·에너지비용을 동시에 고려해 최적 배정을
# 찾는" 도구를 명세했고, agent-3 은 *"The inventory lacks a primitive that can optimize
# task allocation based on multiple parameters"* 로 답했다. **둘 다 맞다** — 그 최적화기가
# harness 자신이라서 알파벳에 없다. agent-2 는 재풀이 사실을 이미 읽고 있었고(실측),
# 없던 것은 **명세자에게의 귀결**이었다.
# =====================================================================================

def test_design_context_says_the_assignment_choice_is_not_its_job():
    """🔴 F7. agent-2 는 **무엇이 이미 되어 있는지**를 들어야 한다."""
    ctx = syn.build_design_context(REASONING_LOG)
    assert syn._DIVISION_DESIGN in ctx, "agent-2 가 분업 문단을 못 받았다"
    assert syn._DIVISION_DESIGN.strip(), "빈-통과 방지: 문단이 비면 위 단언은 항진이다"


def test_the_division_clause_names_no_primitive_and_no_oracle_field():
    """🔴 F7 의 대가를 여기서 막는다 — F1 문단과 같은 검사다(레지스트리 전수)."""
    clause = syn._DIVISION_DESIGN
    for n in _impl_names():
        assert n not in clause, "분업 문단이 구현 함수 %s 를 흘린다" % n
    assert "zone_relocate_norm" not in clause
    for word in ("battery_mild", "SwapBattery", "Replace", "NOOP"):
        assert word not in clause, "분업 문단이 사건/매크로 이름 %s 를 지목한다" % word


def test_the_division_clause_describes_the_world_not_the_answer():
    """🔴 사용자 결정(2026-09-02): 이 개입의 대가는 **`expressible` 한 필드로** 드러나야 한다.

    F7 은 "그 최적화는 이미 자동으로 돈다" 를 agent-2 에게 말한다. 그래서 모델이 "그러면 새
    도구는 필요 없다" 로 도망갈 여지가 생기고, 그 답은 `expressible=True` → agent-3 미호출 →
    `synthesis_event=False` 로 기록에 남는다. 그것이 **관측 가능한 대가**다.

    🔴 그러니 이 문단은 무엇을 답하라고 말하면 안 된다. "기존 어휘로 충분하다고 답하지 말라"
    류의 한 문장이 들어가는 순간 대가가 관측 불가능해지고, 남는 것은 "개입했더니 좋아졌다" 는
    **재보증 불가능한 주장**뿐이다.

    🔴 문구 금지 목록은 못 지킨다 — 첫 판이 그랬고 변이 N3 이 그대로 통과했다
    ("This is not a reason to answer that the existing vocabulary suffices." 는 금지어를
    하나도 안 쓴다). 그래서 **닫힌 어휘**로 뒤집는다: 이 문단은 세계를 서술하므로 모델의
    **응답**을 가리키는 낱말이 하나도 필요 없다. 하나라도 들어오면 그것이 답을 지시하려는
    시도이고, 여기서 멈춘다.
    """
    clause = syn._DIVISION_DESIGN.lower()
    # 응답을 가리키는 낱말 — 세계를 서술하는 문단에는 등장할 이유가 없다.
    for banned in ("expressible", "answer", "report", "respond", "vocabulary",
                   "suffice", "sufficient", "adequate", "enough", "conclude",
                   "you must", "you should", "always", "never say"):
        assert banned not in clause, (
            "분업 문단이 모델의 응답을 가리킨다(%r) — 그 순간 이 개입의 대가가 "
            "`expressible` 에서 안 보이게 된다" % banned)
    # 빈-통과 방지: 문단이 비면 위 루프는 항진이다.
    assert len(clause.split()) > 60, "문단이 비었거나 잘렸다 — 위 단언들이 항진이 된다"


def test_only_agent_2_reads_the_division_of_labour():
    """agent-1 은 설계를 안 하고, agent-3 은 같은 사실을 body 작성자용 문장으로 이미 읽는다.

    표면을 셋으로 늘리면 누수 가드도 셋이 된다 — 계약 (C) 의 논거와 같다.
    """
    assert syn._DIVISION_DESIGN not in syn.build_observe_context(OBSERVATION)
    assert syn._DIVISION_DESIGN not in syn.build_compose_context(SPEC, REASONING_LOG)


def test_the_principles_deictic_is_true_in_every_render():
    """🔴 `PHYSICAL_PRINCIPLES` 는 세 빌더가 **공유**한다 — 한 곳에서만 참인 지시어를 담으면
    안 된다. agent-2 에게 인벤토리는 그 프롬프트에 없다.
    """
    assert "this inventory" not in syn.PHYSICAL_PRINCIPLES
    # 사실 자체는 남아 있어야 한다 — 지시어만 고쳤지 문장을 지운 것이 아니다.
    assert "RE-SOLVES THAT MILP AUTOMATICALLY" in syn.PHYSICAL_PRINCIPLES
    assert "contains no" in syn.PHYSICAL_PRINCIPLES


# =====================================================================================
# 2026-09-03 (F8) — 기전을 고르라는 지시를 한 곳으로 접는다. 유료 0건.
#
# 실측(09-03 런2, `results/2026-09-03-ab2-synth-multi.json`): 두 레인 다 agent-3 이
# `needs_primitive` 를 냈고, 그 이유는 인벤토리 이해가 아니라 **agent-2 가 고른 기전**이었다.
#   · zone : agent-2 가 "수직 lift" 를 명세 → 인벤토리는 수평 이동뿐
#   · mild : "특정 대체 로봇으로 재배정 + 우선순위 조정" → release 는 되지만 대상 지정이 없다
# agent-2 는 인벤토리를 **일부러 못 본다**(계약 B). 그러니 기전을 고르게 두는 한 그 선택은
# 어휘 밖으로 나갈 수밖에 없다.
#
# 🔴 그런데 지금 agent-2 를 미는 세 문장이 **전부 같은 방향**이었다:
#     (1) `DesignToolSpec.mechanism` 설명 — "exactly what this tool changes and how … Be
#         exhaustive"  ← 세 번의 design 호출 전부에 걸리는 상시 압력
#     (2) 접지 게이트 되먹임 — "Commit to one mechanism and specify it directly."
#     (3) F2 되먹임        — "commit to a different mechanism that reaches the same goal."
#    "필요한 **효과**를 적고 기전은 강제될 때만 골라라" 라고 말하는 자리는 **하나도 없었다.**
#
# ⟹ 그 한 문장을 만들어 셋이 **공유**한다. 세 벌로 두면 갈린다 — 이 레포가 반복해 밟은 모양.
# =====================================================================================

def _agent_2_instruction_surfaces():
    """agent-2 가 기전에 대해 읽는 **전부**. 늘어나면 여기에 더한다 — 아래 시험 둘이 같이 큰다."""
    return {
        "mechanism 필드 설명": syn.DesignToolSpec.output_fields["mechanism"].json_schema_extra["desc"],
        "접지 게이트 되먹임": syn._UNGROUNDED_FEEDBACK,
        "F2 되먹임": syn._COMPOSE_FEEDBACK,
    }


def test_the_effect_clause_is_one_string_that_all_three_surfaces_share():
    """🔴 진실원 하나. 셋 중 하나만 고치면 나머지 둘이 반대로 밀어 서로를 지운다."""
    clause = syn._EFFECT_NOT_MECHANISM
    assert clause.strip(), "빈-통과 방지: 절이 비면 아래 단언들이 항진이다"
    for where, text in _agent_2_instruction_surfaces().items():
        assert clause in text, "%s 가 효과-우선 절을 안 싣는다" % where


def test_no_surface_tells_agent_2_to_commit_to_a_mechanism():
    """🔴 F7 의 교훈대로 **금지 목록은 약한 가드다**(변이 N3 이 그대로 통과했었다). 진짜
    가드는 위의 긍정 못박기이고, 이것은 옛 문장 셋이 실제로 사라졌는지만 확인한다.
    """
    for where, text in _agent_2_instruction_surfaces().items():
        low = text.lower()
        for banned in ("commit to", "be exhaustive", "specify it directly",
                       "choose a mechanism", "pick a mechanism", "select a mechanism"):
            assert banned not in low, "%s 가 여전히 기전 확정을 지시한다(%r)" % (where, banned)


def test_the_effect_clause_names_no_primitive_and_no_oracle_field():
    """🔴 계약 (B)·(C). 이 절은 agent-2 가 읽는다 — 인벤토리도 오라클도 새면 안 된다."""
    clause = syn._EFFECT_NOT_MECHANISM
    for q in [{"name": n} for n in _impl_names()]:
        assert q["name"] not in clause, "효과-우선 절이 %s 를 흘린다" % q["name"]
    assert "zone_relocate_norm" not in clause


def test_only_agent_2_reads_the_effect_clause():
    """표면을 셋으로 늘리면 누수 가드도 셋이 된다 — F7 과 같은 논거."""
    assert syn._EFFECT_NOT_MECHANISM not in syn.build_observe_context(OBSERVATION)
    assert syn._EFFECT_NOT_MECHANISM not in syn.build_compose_context(SPEC, REASONING_LOG)


def test_the_mechanism_field_still_asks_for_what_the_registry_records():
    """🔴 "how" 를 뺀다고 소비·선행조건·가역성까지 빼면 주조 레지스트리 항목이 빈다."""
    desc = syn.DesignToolSpec.output_fields["mechanism"].json_schema_extra["desc"].lower()
    for need in ("consume", "precondition", "undo"):
        assert need in desc, "mechanism 설명이 %r 를 더 이상 안 묻는다" % need


def test_the_groundability_feedback_says_the_prose_is_not_an_escape():
    """🔴 09-03 실측: 게이트는 `params` 만 보고 `mechanism` 산문은 **절대 안 본다.** 그래서
    agent-2 의 가장 쉬운 탈출로가 "선택을 산문으로 옮기기" 이고, 그게 정확히 agent-3 이 조합
    못 하는 상태다(zone: `bypass_method` 가 재설계 후에도 그대로 남았다).
    """
    assert "mechanism description" in syn._UNGROUNDED_FEEDBACK, (
        "게이트 되먹임이 산문 탈출로를 막지 않는다")


def test_the_groundability_feedback_reaches_agent_2(monkeypatch):
    """🔴 배선 시험. 이 되먹임은 지금까지 **끝에서 끝까지 재본 적이 없다** — 상수로 접으면서
    같이 못박는다. 첫 호출은 비어 있어야 하고, 둘째는 잡힌 이름을 실은 그 상수여야 한다.
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs([True], params='{"bypass_method": {"type": "string"}}')
    rec = syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                               programs=progs)
    assert rec["ungrounded_params"] == ["bypass_method"] and rec["redesigned"] is True
    assert kw["design"][0]["ungrounded_feedback"] == "", "첫 설계가 되먹임을 봤다"
    assert kw["design"][1]["ungrounded_feedback"] == syn._UNGROUNDED_FEEDBACK % "bypass_method"


def test_the_groundability_feedback_names_no_primitive(monkeypatch):
    """🔴 계약 (B). 실제로 **보내진** 문자열을 레지스트리 전수로 본다 — F2 와 같은 검사."""
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    progs, kw = _seq_programs([True], params='{"bypass_method": {"type": "string"}}')
    syn.synthesize_multi(state=OBSERVATION, tools=[], ledger=syn.SynthesisLedger(),
                         programs=progs)
    fb = kw["design"][1]["ungrounded_feedback"]
    for q in [{"name": n} for n in _impl_names()]:
        assert q["name"] not in fb, "agent-2 가 접지 되먹임에서 원시 %s 를 봤다" % q["name"]


def test_the_effect_clause_carries_both_halves():
    """🔴 변이 M6 이 살아남아서 추가한다. 마지막 문장을 지워도 절은 여전히 **비어 있지 않아**
    세 표면이 '공유'는 한다 — 공유하는 내용이 반쪽이어도. 그런데 이 개입은 두 반쪽이 다
    있어야 뜻이 있다: (a) 효과를 요구한다, (b) 기전을 놓아준다. (b) 가 빠지면 남는 것은
    "효과도 적고 기전도 exhaustive 하게 적어라" 이고, 그건 09-03 이전의 압력 그대로다.
    """
    clause = syn._EFFECT_NOT_MECHANISM
    assert "REQUIRED EFFECT" in clause, "(a) 효과를 요구하는 반쪽이 없다"
    assert "the way is open" in clause, "(b) 기전을 놓아주는 반쪽이 없다"
    assert len(clause.split()) >= 50, "절이 잘렸다 — 위 두 못박기가 문구만 남긴다"
