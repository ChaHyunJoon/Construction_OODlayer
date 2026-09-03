"""agent-3 이 body 를 **데이터로도** 낸다 — 아무도 파싱하지 않게. (2026-09-03, A)

🔴 왜 (실측). 라이브 기록의 mild body 는
`release_pending_assignments({"agent": "...(4)", "faulted": null})` 인데, 그 **인자값이
Julia 에 도착하지 않는다**: `parse_body` 는 이름만 돌려주고(canon 규약), `body` 텍스트는
`SYNTH_LANE_KEYS` 아홉에 없어 경계를 못 넘으며, 집행부가 값으로 읽는 `params` 는 실제로는
agent-2 가 낸 **JSON 스키마**다(`{"affected_robot": "string", ...}`). 그래서 오늘 그 기록을
`enact_minted!` 에 그대로 먹이면 `MethodError: no method matching String(::Int64)` 로 죽는다.

🔴 정규식으로 body 에서 인자를 뽑는 안은 **실측으로 버렸다**: 관측 형태·인자없음·두 호출·
주석섞임은 되지만 kwarg 형태(`agent="..."`)와 Julia 리터럴(`n = 2`)에서 깨지고, 괄호 없는
나열에서는 **이름은 살아남고 인자만 사라진다**. 기록된 non-empty body 는 딱 2개, 둘 다 같은
문자열이라 "된다" 의 표본이 1형태뿐이었다.

🔴 **`body_names` 의 출처는 바꾸지 않는다.** 그것이 canon·ψ·원장·`tool_minted` 의 계보이고,
바꾸면 F2/F7 기록과 같은 표에 못 올린다. `calls` 는 **인자 채널**로만 더하고, 둘의 불일치는
`reach_matches_body` 와 같은 관용으로 **기록만** 한다(강제하지 않는다).

재는 명제 여덟
  (1) `ComposeToolBody` 가 `calls` 를 출력 필드로 선언한다.
  (2) 정규화는 **전부 아니면 없음**이다 — 한 항목이라도 못 읽으면 `None`(삼상).
      집행에 먹일 채널에서 부분 파싱은 반쯤 굴린 body 와 같은 종류의 사고다.
  (3) `[]`(빈 리스트, 읽었는데 비었다)와 `None`(못 읽었다)은 다른 사건이다.
  (4) 인자 없는 호출은 정상이다 — `args` 부재는 `{}` 이지 실패가 아니다.
  (5) 모델이 `primitive` 대신 `name` 을 써도 읽는다(그 한 가지만 허용하고 기록한다).
  (6) 문자열로 온 JSON 도 읽는다 — dspy 의 타입 강제가 실패하면 그렇게 온다.
  (7) `calls` 의 이름들이 `body_names` 와 어긋나면 **기록**된다(강제 아님).
  (8) 각 호출의 `args` 가 평평한 스칼라인지 **기록**된다(강제 아님).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import synthesize as SY  # noqa: E402


# ---- (1) 시그니처 ---------------------------------------------------------------------------
def test_compose_signature_declares_a_calls_output_field():
    assert "calls" in SY.ComposeToolBody.output_fields


# ---- (2)~(6) 정규화 -------------------------------------------------------------------------
def test_a_well_formed_call_list_normalises():
    got = SY.normalize_calls([{"primitive": "release_pending_assignments",
                               "args": {"agent": "R4", "faulted": None}}])
    assert got == [{"primitive": "release_pending_assignments",
                    "args": {"agent": "R4", "faulted": None}}]


def test_a_trailing_bang_is_stripped_like_everywhere_else():
    """`parse_body` 의 `_norm` 과 같은 규약 — Julia impl 이름은 `!` 로 끝난다."""
    got = SY.normalize_calls([{"primitive": "swap_battery!", "args": {}}])
    assert got[0]["primitive"] == "swap_battery"


def test_a_call_without_args_is_not_a_failure():
    """인자 없는 원시가 실재한다(`recover_stalled_teams`). 부재는 `{}` 다."""
    assert SY.normalize_calls([{"primitive": "recover_stalled_teams"}]) == \
        [{"primitive": "recover_stalled_teams", "args": {}}]


def test_the_model_may_say_name_instead_of_primitive():
    assert SY.normalize_calls([{"name": "resolve_schedule_wedge", "args": {}}])[0]["primitive"] \
        == "resolve_schedule_wedge"


def test_a_json_string_is_read_too():
    """dspy 의 타입 강제가 실패하면 필드가 문자열로 온다."""
    assert SY.normalize_calls('[{"primitive": "recover_stalled_teams", "args": {}}]') == \
        [{"primitive": "recover_stalled_teams", "args": {}}]


def test_an_empty_list_is_empty_not_unreadable():
    """🔴 (3) 삼상. '읽었는데 비었다' 와 '못 읽었다' 는 다른 사건이다."""
    assert SY.normalize_calls([]) == []
    assert SY.normalize_calls(None) is None


def test_one_malformed_entry_makes_the_whole_thing_unreadable():
    """🔴 (2) 전부 아니면 없음. 이 값은 집행에 먹일 인자다 — 절반만 읽어서 넘기면
    '반쯤 굴린 body' 와 같은 종류의 사고가 된다(그리고 이 알파벳엔 undo 가 없다)."""
    assert SY.normalize_calls([{"primitive": "recover_stalled_teams", "args": {}},
                               {"args": {"x": 1}}]) is None                      # 이름 없음
    assert SY.normalize_calls([{"primitive": "x", "args": ["not", "a", "dict"]}]) is None
    assert SY.normalize_calls([{"primitive": 7, "args": {}}]) is None             # 이름이 문자열 아님
    assert SY.normalize_calls("not json at all") is None
    assert SY.normalize_calls({"primitive": "x"}) is None                         # 리스트가 아니다


# ---- (7)(8) 기록되는 두 사실 -----------------------------------------------------------------
def _rec(**kw):
    base = {"body": "", "reach": "composed", "missing_primitive": "", "params": "",
            "tool_name": "t", "calls": None}
    base.update(kw)
    return base


def test_calls_disagreeing_with_the_body_is_recorded_not_enforced():
    r = SY._finish_record(_rec(body="release_pending_assignments()",
                               calls=[{"primitive": "forbid_heavy_cargo", "args": {}}]),
                          "battery", SY.SynthesisLedger(), None)
    assert r["calls_match_body"] is False
    assert r["body_names"] == ["release_pending_assignments"]     # 🔴 canon 계보는 안 바뀐다
    assert r["canon"]["primitives"] == ["release_pending_assignments"]


def test_calls_agreeing_with_the_body_is_recorded_true():
    r = SY._finish_record(_rec(body="release_pending_assignments()",
                               calls=[{"primitive": "release_pending_assignments", "args": {}}]),
                          "battery", SY.SynthesisLedger(), None)
    assert r["calls_match_body"] is True


def test_unreadable_calls_make_the_match_unmeasured_not_false():
    r = SY._finish_record(_rec(body="release_pending_assignments()", calls="garbage"),
                          "battery", SY.SynthesisLedger(), None)
    assert r["calls"] is None
    assert r["calls_match_body"] is None          # 🔴 "못 쟀다" 이지 "어긋났다" 가 아니다


def test_nested_call_args_are_recorded_as_not_flat():
    """`params_flat` 과 같은 이유다 — 중첩 값은 Julia 경계의 얕은 변환을 조용히 깨뜨린다."""
    r = SY._finish_record(_rec(body="x()", calls=[{"primitive": "x",
                                                   "args": {"zone": {"center": [1, 2]}}}]),
                          "zone", SY.SynthesisLedger(), None)
    assert r["calls_flat"] is False
    r2 = SY._finish_record(_rec(body="x()", calls=[{"primitive": "x", "args": {"n": 2}}]),
                           "zone", SY.SynthesisLedger(), None)
    assert r2["calls_flat"] is True


# ---- (9)(10)(11) multi 레인이 실제로 그 값을 나른다 -------------------------------------------
class _Pred:
    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def _progs(compose_out, second_compose=None):
    def observe(**kw):
        return _Pred(reasoning_log="the zone froze 32 nodes")

    def design(**kw):
        return _Pred(expressible=False, tool_name="T", params='{"a": {"type": "string"}}',
                     mechanism="m")

    state = {"n": 0}

    def compose(**kw):
        state["n"] += 1
        if state["n"] == 1:
            return compose_out
        if second_compose is None:
            raise RuntimeError("second compose blew up")
        return second_compose

    return {"observe": observe, "design": design, "compose": compose}


def test_the_multi_lane_carries_agent3_calls_into_the_record(monkeypatch):
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    rec = SY.synthesize_multi(
        state="s", tools=[], kind="battery", ledger=SY.SynthesisLedger(),
        programs=_progs(_Pred(body="release_pending_assignments(...)", reach="composed",
                              missing_primitive="",
                              calls=[{"primitive": "release_pending_assignments",
                                      "args": {"agent": "R4", "faulted": None}}])))
    assert rec["calls"] == [{"primitive": "release_pending_assignments",
                             "args": {"agent": "R4", "faulted": None}}]
    assert rec["calls_match_body"] is True
    assert rec["calls_flat"] is True


def test_a_compose_stage_that_omits_calls_records_none_and_does_not_crash(monkeypatch):
    """🔴 이 레포의 기존 fake compose 들이 정확히 이 모양이다. 부재는 '못 쟀다' 다."""
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    rec = SY.synthesize_multi(
        state="s", tools=[], kind="battery", ledger=SY.SynthesisLedger(),
        programs=_progs(_Pred(body="release_pending_assignments()", reach="composed",
                              missing_primitive="")))
    assert rec["calls"] is None
    assert rec["calls_match_body"] is None
    assert rec["body_names"] == ["release_pending_assignments"]     # 나머지는 그대로 돈다


def test_a_failed_recompose_puts_calls_back_with_the_rest(monkeypatch):
    """🔴 '갈라진 기록을 절대 만들지 않는다' 는 이미 있는 계약이다(`rec.update(first)`).
    `calls` 를 그 묶음에 안 넣으면 **명세는 2차, 인자는 1차** 인 기록이 나온다."""
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    first_calls = [{"primitive": "translate_whole_build", "args": {}}]
    rec = SY.synthesize_multi(
        state="s", tools=[], kind="zone", ledger=SY.SynthesisLedger(),
        programs=_progs(_Pred(body="translate_whole_build()", reach="needs_primitive",
                              missing_primitive="lift_cargo_over_zone",
                              calls=first_calls)))
    assert rec["recompose_error"] is not None          # 둘째 compose 가 던졌다
    assert rec["calls"] == first_calls                 # 1차가 통째로 돌아왔다
    assert rec["body"] == "translate_whole_build()"


# ---- 변이가 살아남아 드러난 구멍 둘 (2026-09-03) ----------------------------------------------
def test_a_non_dict_item_inside_the_list_makes_the_whole_thing_unreadable():
    """🔴 변이 N1 이 살아남아서 추가했다. 위 (2) 의 사례 다섯은 전부 **첫 항목**이나 컨테이너
    자체가 잘못된 판이라, `if not isinstance(item, dict): continue`(부분 파싱) 로 바꿔도
    전부 초록이었다. 리스트 **안에** 섞인 비-dict 이 그 갈래를 실제로 태우는 유일한 입력이다."""
    assert SY.normalize_calls([{"primitive": "recover_stalled_teams", "args": {}},
                               "garbage"]) is None
    assert SY.normalize_calls([{"primitive": "recover_stalled_teams", "args": {}},
                               None]) is None


def test_an_explicitly_empty_call_list_survives_the_copy_as_empty(monkeypatch):
    """🔴 변이 N7 이 살아남아서 추가했다. `_copy_body_fields` 를 `or ""` 한 줄로 되돌려도
    위 두 multi 시험은 초록이었다 — 하나는 비지 않은 리스트(참)라 통과하고, 다른 하나는
    필드 자체가 없어 어차피 `None` 이기 때문이다. **agent-3 이 `[]` 를 명시적으로 낸 판**만
    그 갈래를 태운다: `or ""` 는 `[]` 를 `""` 로 접고 그러면 '읽었는데 비었다' 가
    '못 읽었다' 로 둔갑한다."""
    monkeypatch.setenv("TOOL_SYNTHESIS", "1")
    rec = SY.synthesize_multi(
        state="s", tools=[], kind="zone", ledger=SY.SynthesisLedger(),
        programs=_progs(_Pred(body="N/A", reach="needs_primitive",
                              missing_primitive="lift_cargo_over_zone", calls=[]),
                        second_compose=_Pred(body="N/A", reach="needs_primitive",
                                             missing_primitive="lift_cargo_over_zone",
                                             calls=[])))
    assert rec["calls"] == []          # 🔴 `None` 이 아니다 — 모델은 답했고, 그 답이 "없음" 이다
    assert rec["calls"] is not None
