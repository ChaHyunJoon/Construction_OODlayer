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
        # 🔴 2026-09-03 (B2/B3). 여기 `params` 는 **라이브 모델이 실제로 내는 모양**이어야
        #    한다: 평평한 맵이 아니라 JSON Schema **봉투**다(첫 유료 런의 잘린 응답이 정확히
        #    이 모양이었다 — `{"type": "object", "properties": {...}, "required": [...]}`).
        #    옛 픽스처는 평평한 맵을 하드코딩해서 두 층을 동시에 가렸다: `rec["params"]` 가
        #    문자열이라는 것과, 봉투가 안 벗겨진다는 것. 그 하드코딩이 통과한 것이 바로
        #    C-F1 이 다섯 리뷰 라운드를 살아남은 이유다.
        return _Pred(impl_name=name, impl_code=code,
                     params=('{"type": "object", "properties": '
                             '{"factor": {"type": "number"}}, "required": ["factor"]}'),
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


# =============================================================================
# 🔴 B1 (2026-09-03) — 잘림 모양의 회귀 게이트
#
# 첫 유료 런에서 3단계가 죽은 원인은 `max_tokens=500` 이었다: `WriteToolImpl` 이 내야 하는
# 여덟 필드 중 하나가 Julia 함수 본문 전체인데, 응답이 `params` 한가운데서 잘려
# JSONAdapter 가 `AdapterParseError` 를 던졌다. 여기서 재는 것은 **모델이 아니라 우리 쪽
# 두 손잡이**다 — 예산과 필드 순서. 유료 0건.
# =============================================================================
def test_the_cheap_scalars_are_emitted_before_the_body():
    """🔴 출력 순서 계약. 값싼 스칼라 넷(`wrote`·`impl_name`·`surface`·`reversible`)이
    가장 긴 필드(`impl_code`) **앞**에 있고, 코드에서 유도되는 둘(`params`·`calls`)은
    그 **뒤**에 있다.

    ⚠️ 이 순서만으로 잘림이 구제되지는 않는다(DSPy 는 필드가 하나라도 없으면 던진다) —
    그것은 `dspy_service.MAX_TOKENS` 의 몫이다. 이 순서가 지키는 것은 예산이 그래도
    모자란 판에서 **먼저 완성되는 것이 판정에 필요한 값**이라는 것, 그리고 `params`/`calls`
    를 `impl_code` 앞으로 올리면 모델이 시그니처를 확정하기 전에 그것을 약속해야 해서
    이 브랜치가 재는 단 하나의 측정(D6)의 품질이 흔들린다는 것이다."""
    order = list(SY.WriteToolImpl.output_fields)
    for cheap in ("wrote", "impl_name", "surface", "reversible"):
        assert order.index(cheap) < order.index("impl_code"), \
            "%s must be emitted before impl_code (order=%r)" % (cheap, order)
    for derived in ("params", "calls"):
        assert order.index("impl_code") < order.index(derived), \
            "impl_code must be emitted before %s (order=%r)" % (derived, order)


def test_a_truncated_write_still_yields_an_honest_record(monkeypatch):
    """🔴 잘림 모양: 뒤쪽 필드가 통째로 없는 예측. 기록은 **없는 것을 지어내지 않는다.**

    실제 잘림은 DSPy 층에서 예외가 되지만(그래서 `_copy_body_fields` 에 닿지 않는다),
    같은 모양은 프로그램을 `dspy.Predict` 로 바꾸거나 어댑터를 갈아 끼우면 여기까지
    도달한다. 그때 삼상이 지켜지는지를 이 시험이 못박는다 —
    `params`/`calls`/`wrote`/`reversible` 이 `""`·`[]`·`False` 로 접히면 안 된다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    progs["compose"] = lambda **kw: _Pred(
        impl_name="adjust_thing!", impl_code=OK_CODE, surface="env_param", reversible=True)
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    # 앞쪽(값싼 스칼라 + 코드)은 살아남는다
    assert rec["impl_name"] == "adjust_thing!"
    assert "function adjust_thing!" in rec["impl_code"]
    assert rec["surface"] == "env_param" and rec["reversible"] is True
    assert rec["body_names"] == ["adjust_thing!"]
    # 뒤쪽은 "못 읽었다" 이지 "읽었는데 비었다" 가 아니다
    assert rec["params"] is None
    assert rec["params_unreadable"] is False      # 원문 자체가 없었다 — 못 읽은 것이 아니다
    assert rec["calls"] is None
    assert rec["calls_unreadable"] is False
    assert rec["wrote"] is None
    assert rec["calls_match_body"] is None


def test_params_crosses_the_boundary_as_a_keyword_map_not_a_string(monkeypatch):
    """🔴 B2/B3. `rec["params"]` 의 **타입과 모양**이 곧 줄리아 경계의 계약이다.

    `tools/monitor/enact.jl` 은 `praw isa AbstractDict` 가 아니면
    `reject:params_not_an_object` 로 거절하고 `Core.eval` 에 도달조차 못 한다. 그리고
    통과하더라도 키가 그 함수의 **키워드**가 아니면(= JSON Schema 봉투를 그대로 보내면)
    `_enactability` 연언지 (iii) 이 깨져 원시가 등록은 되고 영영 호출 불가가 된다.
    줄리아 쪽 짝은 `test/minted_end_to_end.jl` (5) 이고, 그쪽은 **이 파일이 아니라
    `synthesize_multi` 가 실제로 낸 기록**을 먹는다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs())
    assert isinstance(rec["params"], dict), type(rec["params"])
    assert not isinstance(rec["params"], str)
    assert rec["params"] == {"factor": {"type": "number"}}   # 봉투가 벗겨졌다
    assert "properties" not in rec["params"] and "type" not in rec["params"]
    # agent-2 의 스키마는 **문자열로 남는다** (`spec_changed_fields` 의 텍스트 비교가 읽는다).
    assert isinstance(rec["spec_params"], str)


def test_unparseable_params_is_none_and_says_so(monkeypatch):
    """🔴 삼상. 못 읽은 스키마는 `None` 이지 `{}` 가 아니다 — `{}` 를 보내면 **빈 스키마로
    등록이 성공한 뒤** 모든 호출 인자가 스키마 밖이라 원시가 평생 호출 불가가 된다.
    그리고 "필드가 없었다" 와 "있었는데 못 읽었다" 를 `params_unreadable` 이 가른다
    (`calls_unreadable` 과 같은 관용구)."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    inner = progs["compose"]

    def bad(**kw):
        p = inner(**kw)
        p.params = "not json at all"
        return p

    progs["compose"] = bad
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert rec["params"] is None
    assert rec["params_unreadable"] is True
    assert rec["params_flat"] is None            # 못 쟀다 — False("쟀고 어긋났다")가 아니다


def test_an_empty_but_readable_schema_is_not_unreadable(monkeypatch):
    """🔴 반대편. 모델이 **읽히는 빈 객체**를 냈으면 그것은 "키워드 없는 함수를 썼다" 는
    참인 관측이다 — `None`("못 읽었다")으로 접지 않는다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    progs = _programs()
    inner = progs["compose"]

    def empty(**kw):
        p = inner(**kw)
        p.params = "{}"
        return p

    progs["compose"] = empty
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(), programs=progs)
    assert rec["params"] == {}
    assert rec["params_unreadable"] is False
