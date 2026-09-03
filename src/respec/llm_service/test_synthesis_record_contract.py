"""합성 기록의 **소비자 규칙표**와 **G1 거절 가드**. 유료 0건 (가짜 프로그램 셋).

이 파일이 재는 것 셋.

  (I5) 규칙표의 각 행이 **자기 조건만으로 골라진다.** 09-03 리뷰 시점의 표는 "re-derived" 와
       "new canon" 두 행이 `ran == True and error is None and body_names != []` 로 **바이트
       동일**했고 결과만 반대였다 — 표 자신이 "소비자에게 normative" 라고 선언하는데 소비자가
       그 둘을 못 가른다. 실제로 가르는 사실(원장의 canon 신규성)이 표에 없었다.
       🔴 표는 **`synthesize.CONSUMER_RULES` 하나**이고 docstring 의 산문은 그것을 사람이 읽는
       모양으로 편 것이다. 이 파일이 둘이 안 갈리는 것을 지킨다(진실원 하나).

  (G1) `ComposeToolBody` 는 Task 8 까지 `inventory=""` 를 받는다 — agent-3 에게 **빈 카탈로그**
       에서 조합하라고 시키는 것이다. 오늘 그 런을 막는 것은 사람의 노트 한 줄뿐이고,
       `results/` 를 보면 이런 런이 실제로 발사된다. 그래서 파이프라인은 **던지지 않고 거절**
       한다(이 레포의 관용: rejections, not exceptions). 거절은
         · "레인이 꺼졌다"(`enabled == False`) 와도
         · "agent-3 가 못 하겠다고 했다"(`ran == True` · `reach == "needs_primitive"`) 와도
       구별돼야 한다 — 이 레포는 서로 다른 사건을 한 관측치로 접어 두 번 대가를 치렀다.

  (R-BODYNAMES 트립와이어) `_finish_record` 의 `rec["body_names"] = []` 는 핀이고, **Task 8 이
       그 값을 채울 자리도 같은 줄**이다. Task 8 이 잊으면 아무것도 안 빨개지고 생성된 body 가
       전부 "비었다" 로 읽힌다. 그래서 **핀의 근거**(agent-3 에게 채울 이름이 아직 없다)를
       시험으로 못박는다: agent-3 의 출력 필드 집합이 움직이는 순간 이 파일이 빨개진다.
"""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import synthesize as SY  # noqa: E402
import world_interface as WI  # noqa: E402

OBSERVATION = "MEASURED STATE\n  harm = 0.31\n"
REASONING_LOG = "A no-go region appeared over three staging areas."
SPEC = {"tool_name": "clear_staging_obstruction",
        "params": '{"max_shift": {"type": "number"}}',
        "mechanism": "Moves staged geometry out of the blocked region."}

#: 가드를 통과시키는 인터페이스. 내용은 안 본다 — 가드가 재는 것은 "비었나" 하나다.
FAKE_INTERFACE = "WORLD TYPES ...\nFUNCTIONS THE MODULE ALREADY HAS ...\n"


class _Pred:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _progs(expressible=False, spy=None, raise_at=None, reach="composed", design_seq=None):
    """세 단계를 대신하는 순수 함수 셋. 프로바이더에 안 나간다 — 과금 0건.

    `raise_at` 은 그 단계에서 예외를 낸다. `design_seq` 는 호출 순서대로 쓸 design 응답들.
    """
    calls = {"design": 0}

    def observe(**kw):
        spy is None or spy.append("observe")
        if raise_at == "observe":
            raise RuntimeError("boom")
        return _Pred(reasoning_log=REASONING_LOG)

    def design(**kw):
        spy is None or spy.append("design")
        n = calls["design"]
        calls["design"] += 1
        if raise_at == "design" or (raise_at == "redesign" and n == 1):
            raise RuntimeError("boom")
        if design_seq is not None:
            return design_seq[min(n, len(design_seq) - 1)]
        return _Pred(expressible=expressible, tool_name=SPEC["tool_name"],
                     params=SPEC["params"], mechanism=SPEC["mechanism"])

    def compose(**kw):
        spy is None or spy.append("compose")
        if raise_at == "compose":
            raise RuntimeError("boom")
        return _Pred(body="1. translate_whole_build()", reach=reach, missing_primitive="")

    return {"observe": observe, "design": design, "compose": compose}


@pytest.fixture()
def iface(monkeypatch):
    """G1 가드를 통과시킨다 — 이 파일의 규칙표 시험들은 가드 **아래**를 잰다."""
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: FAKE_INTERFACE)


# =====================================================================================
# (I5) 규칙표 — 각 행이 자기 조건만으로 골라진다
# =====================================================================================
def _matching(rec):
    return [r.name for r in SY.CONSUMER_RULES if r.matches(rec)]


def _drive(monkeypatch, **kw):
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    return SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                               ledger=SY.SynthesisLedger(), **kw)


def _exit_paths(monkeypatch):
    """`synthesize_multi` 의 **실제 탈출 경로 전부**를 (기대 행, 기록) 으로."""
    ungrounded = _Pred(expressible=False, tool_name="t",
                       params='{"resolution_strategy": {"type": "string"}}', mechanism="m")
    out = []

    monkeypatch.delenv(SY.SYNTHESIS_ENV, raising=False)
    out.append(("was switched off",
                SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                                    ledger=SY.SynthesisLedger(), programs=_progs())))

    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: "")
    out.append(("refused",
                SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                                    ledger=SY.SynthesisLedger(), programs=_progs())))

    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: FAKE_INTERFACE)
    for stage in ("observe", "design", "redesign"):
        progs = (_progs(raise_at=stage) if stage != "redesign"
                 else _progs(raise_at="redesign", design_seq=[ungrounded]))
        out.append(("a stage failed", _drive(monkeypatch, programs=progs)))
    out.append(("did not fire", _drive(monkeypatch, programs=_progs(expressible=True))))
    out.append(("ran and failed", _drive(monkeypatch, programs=_progs(raise_at="compose"))))
    out.append(("ran, no body", _drive(monkeypatch, programs=_progs())))
    return out


def test_every_exit_path_matches_exactly_one_rule(monkeypatch):
    """🔴 이것이 I5 의 본체다. 두 행이 같은 조건을 쓰면 여기서 2개가 맞는다."""
    for expected, rec in _exit_paths(monkeypatch):
        got = _matching(rec)
        assert got == [expected], "%s 를 기대했는데 맞은 행이 %s 다: %r" % (expected, got, rec)


def test_every_rule_predicts_tool_minted(monkeypatch):
    """표의 오른쪽(→ `tool_minted`)도 참이어야 한다 — 조건만 맞고 결과가 틀리면 소용없다."""
    by_name = {r.name: r for r in SY.CONSUMER_RULES}
    for expected, rec in _exit_paths(monkeypatch):
        want = by_name[expected].tool_minted
        got = rec["tool_minted"]
        assert got is want or got == want, "%s: tool_minted=%r (기대 %r)" % (expected, got, want)


def test_the_two_minted_rows_are_separated_by_the_ledger_count():
    """🔴 두 행을 실제로 가르는 사실은 **원장의 canon 신규성**이고, 기록에서 그것을 나르는 것은
    `canon_count` 다. 옛 표에는 그 사실이 아예 없었다."""
    led = SY.SynthesisLedger()
    c = SY.canon(["swap_battery"], "zone")
    assert led.observe(c) is True
    assert led.entries[SY.canon_key(c)]["count"] == 1
    assert led.observe(c) is False
    assert led.entries[SY.canon_key(c)]["count"] == 2

    base = {"enabled": True, "refused": False, "ran": True, "error": None,
            "body_names": ["swap_battery"]}
    assert _matching(dict(base, canon_count=1)) == ["new canon"]
    assert _matching(dict(base, canon_count=2)) == ["re-derived"]


def test_the_prose_table_and_the_code_table_do_not_fork():
    """🔴 진실원 하나. docstring 의 표는 `CONSUMER_RULES` 를 사람이 읽는 모양으로 편 것이고,
    이 레포는 같은 사실이 두 자리에 사는 것으로 세 번 데었다."""
    doc = " ".join((SY.__doc__ or "").split())
    for r in SY.CONSUMER_RULES:
        assert r.name in doc, "규칙 %r 이 모듈 docstring 의 표에 없다" % r.name
        assert r.condition in doc, "규칙 %r 의 조건이 표와 갈렸다: %r" % (r.name, r.condition)


def test_no_two_rules_share_a_condition():
    """옛 결함을 이름으로 잡는다: 조건 문자열이 겹치면 소비자가 색인을 못 한다."""
    conds = [r.condition for r in SY.CONSUMER_RULES]
    assert len(set(conds)) == len(conds), "같은 조건을 쓰는 행이 있다: %s" % conds


# =====================================================================================
# (G1) 빈 인터페이스면 **과금하지 않고 거절한다**
# =====================================================================================
def test_the_guard_refuses_and_bills_nothing(monkeypatch):
    """🔴 유료 호출 **0건**. 가드가 agent-1 뒤에 있으면 이미 한 건을 쓴 뒤다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: "")
    spy = []
    rec = SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                              ledger=SY.SynthesisLedger(), programs=_progs(spy=spy))
    assert spy == [], "거절인데 단계가 돌았다: %s" % spy
    assert rec["stages"] == []
    assert rec["refused"] == "no_compose_interface"
    assert rec["reason"] and "interface" in rec["reason"]


def test_the_refusal_is_not_an_exception(monkeypatch):
    """이 레포의 관용: 거절은 기록이지 예외가 아니다 (`parseall` 이 `:incomplete` 를 내는 것과 같다)."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: "")
    rec = SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                              ledger=SY.SynthesisLedger(), programs=_progs())
    assert isinstance(rec, dict) and rec["error"] is None


def test_the_refusal_is_distinguishable_from_the_lane_being_off(monkeypatch):
    """🔴 이 레포가 두 번 대가를 치른 자리 — 서로 다른 사건을 한 관측치로 접지 않는다."""
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: "")
    monkeypatch.delenv(SY.SYNTHESIS_ENV, raising=False)
    off = SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                              ledger=SY.SynthesisLedger(), programs=_progs())
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    refused = SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                                  ledger=SY.SynthesisLedger(), programs=_progs())
    assert off["tool_minted"] == "disabled" and off["enabled"] is False
    assert off["refused"] is None, "플래그가 꺼져 가드가 안 돌았으면 `None`(못 쟀다) 이다"
    assert refused["enabled"] is True and refused["tool_minted"] is None
    assert _matching(off) != _matching(refused)


def test_the_refusal_is_distinguishable_from_agent_3_declining(monkeypatch, iface):
    """agent-3 가 "못 하겠다"(`needs_primitive`) 고 한 것과 우리가 안 물어본 것은 다른 사건이다."""
    declined = _drive(monkeypatch, programs=_progs(reach="needs_primitive"))
    assert declined["ran"] is True and declined["reach"] == "needs_primitive"
    assert declined["refused"] is False, "물어봤으면 거절이 아니다"
    assert _matching(declined) == ["ran, no body"]


# ---- 비-공백 짝: Task 8 을 막지 않는다 ------------------------------------------------------
def test_the_guard_does_not_fire_once_an_interface_is_supplied(monkeypatch, iface):
    """🔴 **이 짝이 양성 시험보다 중요하다.** 늘 거절하는 가드는 Task 8 을 막는다."""
    spy = []
    rec = _drive(monkeypatch, programs=_progs(spy=spy))
    assert rec["refused"] is False
    assert spy == ["observe", "design", "compose"], spy
    assert rec["stages"] == ["observe", "design", "compose"]


def test_the_real_world_interface_block_passes_the_guard(monkeypatch):
    """Task 8 이 실제로 넘길 것(세계 인터페이스 블록)으로도 통과한다 — 내용은 안 본다.

    🔴 산출물 내용에 대한 단언은 하나도 없다: 줄리아 쪽이 더 풍부한 시그니처로 재생성하는
    중이고, 이 시험이 그 내용에 매이면 남의 작업에 매인다.
    """
    monkeypatch.setattr(SY, "compose_interface",
                        lambda blob=None: WI.build_world_interface_block())
    rec = _drive(monkeypatch, programs=_progs())
    assert rec["refused"] is False and rec["stages"] == ["observe", "design", "compose"]


def test_the_interface_reaches_agent_3(monkeypatch, iface):
    """🔴 배선 시험. 가드가 보는 것과 agent-3 이 받는 것이 **같은 값**이어야 한다 — 갈리면
    가드는 통과시키고 모델은 여전히 빈 카탈로그를 받는다."""
    seen = {}
    progs = _progs()
    inner = progs["compose"]

    def compose(**kw):
        seen.update(kw)
        return inner(**kw)

    progs["compose"] = compose
    _drive(monkeypatch, programs=progs)
    assert FAKE_INTERFACE in "".join(str(v) for v in seen.values())


def test_the_guard_runs_after_the_flag(monkeypatch):
    """R13 의 순서를 안 뒤집는다 — 꺼진 레인은 `"disabled"` 로 남아야 한다."""
    monkeypatch.delenv(SY.SYNTHESIS_ENV, raising=False)
    monkeypatch.setattr(SY, "compose_interface", lambda blob=None: "")
    rec = SY.synthesize_multi(state=OBSERVATION, tools=[], kind="zone",
                              ledger=SY.SynthesisLedger(), programs=_progs())
    assert rec["tool_minted"] == "disabled"


def test_the_blank_record_never_claims_the_guard_ran():
    """`blank_synthesis_record` 는 파이프라인 밖이다 — 삼상 규약상 `None`."""
    rec = SY.blank_synthesis_record(kind="zone", expressible=True,
                                    ledger=SY.SynthesisLedger())
    assert rec["refused"] is None


# =====================================================================================
# (R-BODYNAMES) Task 8 트립와이어
# =====================================================================================
#: 오늘 agent-3 가 내는 출력 필드 전부. 🔴 이 집합이 움직이는 것이 **Task 8 이 도착했다**는
#: 신호다(설계: `ComposeToolBody` → `WriteToolImpl`, 알파벳 대신 세계 인터페이스, `impl_name`).
_COMPOSE_OUTPUTS_TODAY = {"body", "calls", "reach", "missing_primitive"}

_TRIPWIRE = (
    "R-BODYNAMES 트립와이어. `_finish_record` 는 `rec['body_names'] = []` 로 값을 **덮어쓴다**. "
    "그 핀이 옳은 이유는 오늘 agent-3 에게 채울 이름이 없기 때문이고, 지금 agent-3 의 출력이 "
    "바뀌었다 = Task 8 이 도착했다. 핀과 Task 8 의 채움은 **같은 줄**이라 잊어도 아무것도 "
    "안 빨개진다 — 생성된 body 가 전부 '비었다'로 읽히고 `tool_minted`·|K| 가 영영 "
    "'못 쟀다'로 남는다. body_names 를 agent-3 의 이름으로 채우고 이 시험을 갱신할 것."
)


def test_the_bodynames_pin_expires_when_agent_3_gains_a_name_to_fill_it_from():
    sig = getattr(SY, "ComposeToolBody", None)
    assert sig is not None, _TRIPWIRE
    assert set(sig.output_fields) == _COMPOSE_OUTPUTS_TODAY, _TRIPWIRE


def test_the_pin_holds_today(monkeypatch, iface):
    """짝: 오늘은 핀이 실제로 걸려 있고 그 결과가 `tool_minted is None` 이다."""
    rec = _drive(monkeypatch, programs=_progs())
    assert rec["body_names"] == []
    assert rec["tool_minted"] is None
    assert "Task 8" in rec["reason"]
