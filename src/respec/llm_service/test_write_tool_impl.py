"""agent-3 은 조합기가 아니라 **작성자**다. 유료 0건 — 프로그램을 가짜로 물린다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402


class _Pred:
    def __init__(self, **kw):
        self.__dict__.update(kw)


OK_CODE = 'function adjust_thing!(env; factor = 1.0)\n    return (status = :adjusted,)\nend\n'


def _programs(code=OK_CODE, name="adjust_thing!"):
    def observe(**kw):
        return _Pred(reasoning_log="the robot is degraded")

    def design(**kw):
        return _Pred(expressible=False, tool_name="T",
                     params='{"factor": {"type": "number"}}', mechanism="m")

    def write(**kw):
        return _Pred(impl_name=name, impl_code=code,
                     params='{"factor": {"type": "number"}}',
                     calls=[{"primitive": name, "args": {"factor": 1.5}}],
                     surface="env_param", reversible=True, wrote=True)

    return {"observe": observe, "design": design, "compose": write}


def test_the_write_stage_receives_the_world_interface(monkeypatch):
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    seen = {}

    progs = _programs()
    inner = progs["compose"]

    def spy(**kw):
        seen.update(kw)
        return inner(**kw)

    progs["compose"] = spy
    SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert "PlannerEnv" in seen["world_interface"]
    assert "reform_stuck_teams!" in seen["world_interface"]


def test_the_record_carries_the_generated_code(monkeypatch):
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs())
    assert rec["impl_name"] == "adjust_thing!"
    assert "function adjust_thing!" in rec["impl_code"]
    assert rec["wrote"] is True


def test_body_names_is_the_generated_name(monkeypatch):
    """🔴 집행부는 `body_names` 를 읽는다. 그 자리에 생성 이름이 와야 경로가 이어진다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs())
    assert rec["body_names"] == ["adjust_thing!"]
    assert rec["calls"] == [{"primitive": "adjust_thing!", "args": {"factor": 1.5}}]
    assert rec["calls_match_body"] is True


def test_a_stage_that_refuses_records_it(monkeypatch):
    """못 쓰겠다는 자기신고는 빈 값과 다른 사건이다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    progs["compose"] = lambda **kw: _Pred(impl_name="", impl_code="", params="",
                                          calls=[], surface="", reversible=False, wrote=False)
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert rec["wrote"] is False and rec["body_names"] == []


def test_wrote_is_none_when_the_field_is_missing(monkeypatch):
    """🔴 삼상 (fix round 1). `wrote` 를 아예 안 낸 판은 "못 썼다"(`False`)가 아니라
    "못 읽었다"(`None`)다 -- `or ""` 로 접으면 `False` 가 `""` 로 뭉개져 이 구별과 F2 의
    `wrote is False` 분기가 둘 다 죽는다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    progs["compose"] = lambda **kw: _Pred(impl_name="", impl_code="")   # `wrote` 자체가 없다
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert rec["wrote"] is None
