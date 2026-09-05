"""agent-3 은 조합기가 아니라 **작성자**다. 유료 0건 — 프로그램을 가짜로 물린다."""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402
import world_interface as WI  # noqa: E402


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


# =============================================================================
# 🔴 R18 FIX A (2026-09-03) — 마크다운 펜스는 **우리 쪽** 원인이다
#
# 두 번째 유료 런에서 agent-3 은 레인을 끝까지 돌았는데(`stages` 셋 · `wrote=True` ·
# `calls_match_body=True`) 등록이 `reject:impl_not_a_function` 으로 거절됐다. 실측한 원인
# 셋 중 첫째가 이것이다: 모델이 코드를 ` ```julia … ``` ` 로 감쌌다. 코드를 펜스로 감싸는
# 것은 **모든** LM 의 보편 행동이지 규약 위반이 아니다 — 그것을 거절하면 우리는 모델이
# 아니라 **우리 파서**를 재게 된다(컨트롤러 판정 R18).
#
# 🔴 **정규화는 파이썬이 한다**(판정 R17 의 선례 그대로: `params` 파싱도 `calls` 정규화도
#    여기서 한다). 파이썬이 LM 응답을 먼저 보고, 줄리아는 진실원이 하나인 값을 받는다.
# 🔴 **삼상.** 코드가 비었거나 벗기고 나서 비면 그것은 `""`("쟀는데 없다")이지
#    `None`("못 쟀다")이 아니다 — `_copy_body_fields` 가 필드가 아예 없을 때 내는 값과
#    같다(`getattr(pred, f, "") or ""`).
# =============================================================================
FENCED_CODE = "```julia\n" + OK_CODE + "```"


def test_a_markdown_fence_never_reaches_the_record(monkeypatch):
    """라이브 모양: agent-3 이 펜스로 감싼 코드를 낸다 → 기록에는 맨 Julia 만 남는다."""
    monkeypatch.setenv(SY.SYNTHESIS_ENV, "1")
    rec = SY.synthesize_multi(state="s", tools=[], ledger=SY.SynthesisLedger(),
                              programs=_programs(code=FENCED_CODE))
    assert "`" not in rec["impl_code"]
    assert rec["impl_code"].startswith("function adjust_thing!")
    assert rec["impl_code"] == OK_CODE


def test_the_fence_forms_models_actually_emit_are_all_stripped():
    """```julia · ```jl · 맨 ``` · 대문자/공백 섞인 info string · 펜스 주변 공백 ·
    **닫히지 않은** 펜스(잘림)."""
    for opener in ("```julia", "```jl", "```", "```Julia", "```  julia  ", "````julia"):
        closer = "`" * (len(opener) - len(opener.lstrip("`")))
        assert SY.strip_code_fence(opener + "\n" + OK_CODE + closer) == OK_CODE, opener
        # 펜스 바깥의 공백은 결과를 바꾸지 않는다
        assert SY.strip_code_fence("\n  " + opener + "\n" + OK_CODE + closer + "\n\n") == OK_CODE
    # 🔴 잘림: 여는 펜스만 있고 닫는 펜스가 없다. 그래도 여는 줄은 벗긴다 —
    #    남는 것이 잘린 Julia 라는 사실은 줄리아의 `impl_parse_failed` 가 정직하게 말한다.
    assert SY.strip_code_fence("```julia\nfunction f!(env; k = 1)\n") == \
        "function f!(env; k = 1)\n"


def test_unfenced_code_passes_through_byte_identical():
    """🔴 펜스가 없으면 **한 바이트도** 안 건드린다."""
    for raw in (OK_CODE,
                "  \n" + OK_CODE + "\n\n",              # 바깥 공백도 그대로 둔다
                "function f!(env)\n    run(`ls`)\nend\n",
                "x = 1\n", ""):
        assert SY.strip_code_fence(raw) == raw


def test_the_interior_is_not_touched():
    """벗기는 것은 **여는 줄과 닫는 줄뿐**이다. 안쪽의 공백·빈 줄·펜스처럼 생긴 줄은 남는다."""
    inner = "function f!(env; k = 1)\n\n    # ```\n        return :ok\nend\n"
    assert SY.strip_code_fence("```julia\n" + inner + "```") == inner


def test_empty_stays_measured_empty_not_unmeasurable():
    """🔴 삼상: 비면 `""`("쟀는데 없다")이지 `None`("못 쟀다")이 아니다."""
    assert SY.strip_code_fence("") == ""
    assert SY.strip_code_fence("```julia\n```") == ""
    assert SY.strip_code_fence("```") == ""
    assert SY.strip_code_fence("   ```julia   \n   ```   ") == ""


def test_a_non_string_impl_code_does_not_throw():
    """🔴 예외가 아니라 거절. 타입 위반은 줄리아의 `reject:impl_code_not_a_string` 이
    말한다 — 여기서 던지면 그 사유가 영영 기록되지 않는다."""
    assert SY.strip_code_fence(None) is None
    assert SY.strip_code_fence(["```julia"]) == ["```julia"]


# =====================================================================================
# 2026-09-04 Task 3 — 출력 슬롯 **옆**이 모델이 실제로 읽는 자리다(설계 §1.3). 유료 0건.
# 세계 인터페이스 블록에만 적으면 29k 자 앞머리에 묻힌다 — `impl_code` 를 쓰는 그 순간에
# 보이는 자리에 같은 두 문장을 겹쳐 둔다.
# =====================================================================================
def test_the_impl_code_slot_carries_the_return_contract_and_the_call_preference():
    d = SY.WriteToolImpl.output_fields["impl_code"].json_schema_extra["desc"]
    assert "return (; status = :success)" in d, d
    assert "NamedTuple{(:status,)}(:success)" in d, d
    assert "length(::Symbol)" in d, d
    assert "Prefer CALLING" in d, d
    # 오늘의 규약을 **지우지 않았다** — 시그니처 모양이 그대로 있다.
    assert "function <impl_name>(env; k=<default>, ...) ... end" in d, d


# =====================================================================================
# 2026-09-04 fix round 1 — `/rewrite` 는 **유일한 자기수정 채널**이다(재시도 상한 1).
# 거절된 body 를 고치라고 부른 그 채널이, 유료 런 1 을 죽인 반환문을 그대로 재생산할 수
# 있으면 안 된다. 유료 0건 — 시그니처의 `desc` 만 읽는다.
# =====================================================================================
def _impl_desc(sig):
    return sig.output_fields["impl_code"].json_schema_extra["desc"]


def test_the_rewrite_slot_carries_the_same_return_contract():
    r = _impl_desc(SY.RewriteToolImpl)
    assert "return (; status = :success)" in r, r
    assert "NamedTuple{(:status,)}(:success)" in r, r
    assert "length(::Symbol)" in r, r
    # 되먹임 채널의 다른 계약은 그대로다 — 시그니처 모양 문장이 살아 있다.
    assert "function <impl_name>(env; k=<default>, ...) ... end" in r, r


def test_both_impl_slots_share_the_return_contract_verbatim():
    """🔴 드리프트 금지. 같은 문단을 두 번 적으면 한쪽만 고쳐지는 날이 온다."""
    w, r = _impl_desc(SY.WriteToolImpl), _impl_desc(SY.RewriteToolImpl)
    assert SY._RETURN_CONTRACT_DESC in w, w
    assert SY._RETURN_CONTRACT_DESC in r, r


def test_both_impl_slots_admit_the_bare_symbol_return():
    """🔴 C2(2026-09-03 최종 리뷰)가 하네스를 맨 `Symbol` 쪽으로 **넓혔다**
    (`src/respec/minted_tool.jl` 의 `_step_status`). 예시가 NamedTuple 하나뿐이면 프롬프트가
    합법인 그 갈래를 조용히 낙담시킨다 — 하네스가 지원하는 것을 프롬프트가 부정하는 모양이다.
    """
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        d = _impl_desc(sig)
        assert "return :success" in d, (sig.__name__, d)


# =====================================================================================
# 2026-09-05 — 유료 런 13·14·15 가 죽은 두 자리. 유료 0건, 시그니처의 `desc` 만 읽는다.
#
# 런 13: agent-3 이 인자를 **지어냈다** (`translation = {0, 0.25, 0}`).
# 런 14·15: agent-3 이 `calls` 를 **통째로 비웠다** → 집행부의
#           `reject:calls_disagree_with_body`, 그리고 그 거절에는 되먹임 경로가 없었다.
# 두 실패의 공통 원인은 하나다: **정답 모양이 표현 가능하다는 말을 어디서도 안 했다.**
# =====================================================================================
def _calls_desc(sig):
    return sig.output_fields["calls"].json_schema_extra["desc"]


def test_the_calls_slot_says_an_empty_args_map_is_a_valid_answer():
    """🔴 런 14·15. 빈 `args` 가 정당하다는 말이 없으면 남는 선택지는 둘뿐이다 —
    지어내서 채우거나, 리스트를 비우거나. 지어낸 값은 **출력 필드 설명에서 태어난다.**"""
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        d = _calls_desc(sig)
        assert "`{}` when the function takes none" in d, (sig.__name__, d)
        assert "complete and correct answer" in d, (sig.__name__, d)
        assert "never invent a value to fill it" in d, (sig.__name__, d)


def test_the_calls_slot_states_the_agreement_contract_the_harness_enforces():
    """🔴 D2 의 규약(`calls` 의 이름·순서 == `body_names`)은 지금까지 **줄리아에만** 있었다.
    집행부는 그것으로 거절하는데 모델은 그것을 들은 적이 없다."""
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        d = _calls_desc(sig)
        assert "same names in the same order" in d, (sig.__name__, d)
        assert "The list itself is never empty" in d, (sig.__name__, d)


def test_both_calls_slots_share_the_contract_verbatim():
    """🔴 드리프트 금지 — `_RETURN_CONTRACT_DESC` 와 같은 규율."""
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        assert _calls_desc(sig) == SY._CALLS_DESC, sig.__name__


def test_both_impl_slots_say_the_body_resolves_the_world_itself():
    """🔴 규칙을 하나만 넣으면 실패가 옮겨간다: `params == {}` 인데 body 가 여전히
    인자를 기다리면 런타임에 던진다. 세 문장이 그것을 막는다 — 세계에서 읽어라 ·
    반환값을 읽어라 · "못 했다" 는 넘길 status 가 아니다."""
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        d = _impl_desc(sig)
        assert SY._RESOLVE_IN_BODY_DESC in d, sig.__name__
    c = SY._RESOLVE_IN_BODY_DESC
    assert "reads out of the world itself" in c, c
    assert "do not write a literal in its place" in c, c
    assert "Read what a call gives back before you act on it" in c, c


def test_the_two_params_slots_state_the_caller_holds_condition():
    """🔴 A 와 같은 축. agent-3 의 `params` 도 "호출자가 쥔 값" 이 아니면 안 된다 —
    한쪽만 고치면 두 필드가 서로를 지운다(`params` 는 `calls` 의 키를 정한다)."""
    for sig in (SY.WriteToolImpl, SY.RewriteToolImpl):
        d = sig.output_fields["params"].json_schema_extra["desc"]
        assert "the caller can hold at call time" in d, (sig.__name__, d)
        assert "`{}` is correct" in d, (sig.__name__, d)


def test_the_new_prompt_text_names_no_world_verb():
    """🔴 **이 문단들은 어휘를 나르지 않는다.** 광고된 함수 이름을 여기 적으면 이 레인이
    재는 것이 모델이 아니라 우리 프롬프트가 된다 — `enact.jl` 의 `_noop_feedback_reason`
    이 지키는 것과 같은 선이고, 그쪽도 시험이 어휘적으로 못박는다.

    모집단은 리터럴이 아니라 `world_interface.json` 에서 읽는다(인터페이스가 자라면 이
    가드도 자란다)."""
    names = {m["name"] for m in WI.load_world_interface()["methods"]}
    assert len(names) > 100, "모집단이 %d 개다 — 가드가 공허하게 통과한다" % len(names)

    # 🔴 판정은 **토큰**이지 부분 문자열이 아니다 — `test/minted_end_to_end.jl` (38) 과 같은
    #    관용구다. 부분 문자열로 재면 `identity` 안의 `entity`(실재하는 광고된 이름)가 걸려
    #    가드가 자기 문장을 못 쓰게 만든다. 누수의 정의는 "모델이 **부를 수 있는 이름**을
    #    읽었다" 이므로 토큰 경계가 그 정의의 정확한 형태다.
    def _tokens(t):
        return set(re.findall(r"[A-Za-z_][A-Za-z0-9_!]*", t))

    text = SY._RESOLVE_IN_BODY_DESC + SY._CALLS_DESC + SY._PARAMS_ARE_CALLER_VALUES
    leaked = sorted(_tokens(text) & names)
    assert leaked == [], "프롬프트가 광고된 이름을 흘린다: %r" % leaked
    # 🔴 음성 대조: 검출기가 실제로 잡는다.
    one = sorted(names)[0]
    assert _tokens("you may call %s here" % one) & names == {one}
