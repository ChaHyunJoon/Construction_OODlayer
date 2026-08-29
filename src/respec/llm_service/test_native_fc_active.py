"""`native_fc_active()` 는 **발화 여부**를 잰다 — 배선 여부가 아니다 (spec §2-4).

`test_native_fc_wired.py` 는 우리가 코드로 통제하는 셋(플래그·입력 필드·출력 필드)을 못박는다.
이 파일은 그 셋 **더하기 조건 4**(`lm.supports_function_calling`)를 런타임에서 읽는 도우미를
못박는다. 조건 4 는 LM 이 정하므로 코드를 읽어서는 알 수 없고, 그래서 이 값이 `/macro` 응답에
실려야 라이브 런에서 "배선했다"와 "실제로 켜졌다"가 구분된다.

🔴 실패는 `False` 가 아니라 `None` 이다. "못 쟀다"(None)와 "재서 꺼져 있었다"(False)는 다른
사건이다 — Global Constraint "deferred 를 unknown/agree 로 뭉개지 않는다"(spec §9-2).

이 파일이 별도인 이유: 브리프가 `test_native_fc_wired.py` 의 기대값을 **정확히 `6 passed`** 로
못박았다. 거기에 시험을 더하면 그 수가 틀려진다.
"""
import contextlib
import os
import sys
from typing import List

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 🔴 import 순서가 계약이다 — `import dspy` 보다 `dspy_service` 가 먼저여야 한다.
#    이유와 실측은 test_native_fc_wired.py 상단 주석 참조.
import dspy_service  # noqa: E402  (this import is what fixes the numpy/dspy ordering)
from dspy_service import (SelectTool, build_adapter, native_fc_active,  # noqa: E402
                          _configure_dspy, _load_program)
import dspy  # noqa: E402

# 🔴 **과금** 0건이지만 **네트워크 0건은 아니다**(2026-08-28 정정). LM 객체 생성은 connect 0건인데,
# `supports_function_calling` 을 **읽는 순간** litellm 이 원격 cost map
# (raw.githubusercontent.com)을 가져오려 한다. 실패하면 로컬 백업으로 폴백하므로 값은 옳고
# provider 호출도 아니다. 실측: **프로세스당** connect 시도 8건(IPv4 4 + IPv6 4).
# 🔴 읽기 한 번당이 아니라 **프로세스당**이다 — litellm 이 cost map 을 모듈 수준에 캐싱하므로
# 두 번째 읽기부터는 0건이다(실측: 새 LM 객체로 5회 연속 읽어도 총계 8에서 안 움직이고, 다른
# 모델로 바꿔도 그대로다). 56시험 게이트 전체가 정확히 8건이다. 오프라인·에어갭 CI 가 무는 것도
# 파일마다가 아니라 프로세스마다 한 번이다.
_NO_CALL_KEY = "sk-DOES-NOT-MATTER-no-call-is-made"


def _real_lm():
    return dspy.LM("openai/gpt-4.1", api_key=_NO_CALL_KEY)


@contextlib.contextmanager
def _dspy_settings_restored():
    """전역 `dspy.configure` 를 부르는 시험들을 감싸 되돌린다.

    🔴 **예방적이고, 현재로서는 반증 불가다**(2026-08-28 컨트롤러/검증자 정정). 정직하게 적는다:
      · 유출은 **실제로 일어난다** — 검증자가 이 매니저를 통째로 걷어내고 `BaseLM.__call__` 에
        트립와이어를 달아 재니, 뒤에 도는 `test_vocabulary_gap_fires.py` 의 여섯 시험이 전부
        `dspy.settings.lm='openai/gpt-4o'` 를 봤다.
      · 그런데 **비용은 발생하지 않았다** — 시도된 LM 호출 0건. 그 파일은 `decide()` 를 부르지
        않기 때문이다. 내가 1라운드에서 인용한 그 파일의 docstring 은 **반사실**을 서술한 것이고,
        "측정된 비용 위험을 막았다"는 내 주장은 틀렸다.
      · ⚠️ **이력**: "이 매니저를 지워도 게이트는 초록"이었다(검증자 실측 33/33) — 그러나 그것은
        아래 `test_the_settings_restorer_actually_restores_by_identity` 가 생기기 **전** 이야기다.
        지금은 **아니다**: 다섯 군데 호출부를 `contextlib.nullcontext()` 로 바꾸면 `1 failed` 다
        (실측). 즉 이 매니저는 이제 그 시험 하나에 대해 **load-bearing** 이다.
        이 docstring 의 옛 문장을 근거로 매니저를 지우지 말 것.
      · 트립와이어 자체는 발화 능력이 있음이 확인됐다(정말로 프로그램을 부르는 시험에서 3회 발화).
    즉 이것은 **위생**이지 닫아 놓은 사고가 아니다. 싸고 옳은 방향이라 유지하지만, 이 주석이
    "위험을 측정해서 막았다"로 읽히면 안 된다.

    `dspy.context` 로 대신할 수 없는 이유는 남는다: 감시 대상이 바로 전역 `dspy.configure` 를
    부르는 프로덕션 줄이다. `_state["program"]` 도 함께 되돌린다 — `native_fc_active()` 가
    그걸 읽으므로 남겨 두면 앞선 시험들의 폴백 경로가 달라진다.

    되돌림 자체는 `test_the_settings_restorer_actually_restores_by_identity` 가 **객체 동일성**
    으로 검사한다(정상 경로 + 예외 경로). `None -> None` 비교는 항상 `None` 을 쓰는 고장난
    복원기도 통과하므로 증거가 되지 않는다."""
    lm0 = dspy.settings.lm
    ad0 = dspy.settings.adapter
    prog0 = dspy_service._state["program"]
    try:
        yield
    finally:
        dspy.configure(lm=lm0, adapter=ad0)
        dspy_service._state["program"] = prog0


def test_active_is_true_when_all_four_conditions_hold():
    """네 조건이 전부 참인 배포 구성. `_startup()` 이 만드는 것과 같은 어댑터다."""
    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active() is True


def test_active_is_false_when_the_flag_is_off():
    """조건 1. 이게 dspy 기본값이고, tools 가 조용히 pop 되는(base.py:96-97) 바로 그 상태다."""
    with dspy.context(lm=_real_lm(), adapter=dspy.ChatAdapter()):
        assert native_fc_active() is False


def test_active_is_false_without_the_tool_input_field():
    """조건 2. 이 구성은 dspy 가 `ValueError` 를 던지는 구성이기도 하다(base.py:104)."""

    class NoToolInput(dspy.Signature):
        state: str = dspy.InputField()
        action: dspy.ToolCalls = dspy.OutputField()

    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active(NoToolInput) is False


def test_active_is_false_without_the_toolcalls_output_field():
    """조건 3. 입력 tools 만 있고 ToolCalls 출력이 없으면 native 분기는 안 탄다."""

    class NoToolCallsOutput(dspy.Signature):
        state: str = dspy.InputField()
        tools: List[dspy.Tool] = dspy.InputField()
        macro: str = dspy.OutputField()

    with dspy.context(lm=_real_lm(), adapter=build_adapter()):
        assert native_fc_active(NoToolCallsOutput) is False


def test_active_is_false_when_the_lm_does_not_support_function_calling():
    """조건 4. `DummyLM.supports_function_calling` 은 False 다 — 실측(dspy 3.3.0).

    🔴 그래서 DummyLM 왕복 시험은 native FC 를 증명하지 못한다. 배선이 전부 옳아도
    이 함수는 False 를 내야 한다.
    """
    lm = dspy.utils.DummyLM([{"macro": "NOOP"}])
    # ⚠️ 환경 전제다(DummyLM 의 속성). dspy_service.py 변이로는 붉어지지 않는다.
    assert lm.supports_function_calling is False
    with dspy.context(lm=lm, adapter=build_adapter()):
        assert native_fc_active() is False


def test_active_is_None_not_False_when_it_cannot_be_measured():
    """spec §9-2. 아무도 `dspy.configure` 를 안 부른 상태에서 조건 1·4 는 **읽을 수 없다**.

    dspy 의 폴백 기본값을 추론해 `False` 를 내면 그것은 측정이 아니라 코드 읽기다.
    """
    with dspy.context(lm=None, adapter=None):
        assert native_fc_active() is None


def test_active_is_None_when_reading_condition_4_itself_raises():
    """조건 4 를 **읽다가** 터진 것도 '재서 꺼져 있었다'가 아니라 '못 쟀다'다(spec §9-2).

    (이 자리에 원래 `native_fc_active(SelectTool)` 이 한 줄 더 있었으나, 기본 인자가 곧
    `SelectTool` 이던 시절에는 위 줄과 **글자 그대로 같은 식**이라 정보량이 0이었다 —
    컨트롤러 실측 B3. 다른 실패 방식을 재는 시험으로 바꾼다.)"""

    class ExplodingLM:
        @property
        def supports_function_calling(self):
            raise RuntimeError("litellm 모델 맵 조회가 터졌다")

    with dspy.context(lm=ExplodingLM(), adapter=build_adapter()):
        assert native_fc_active(SelectTool) is None


def test_configure_dspy_installs_the_native_fc_adapter():
    """🔴 B2. 프로덕션에서 native FC 를 켜는 것은 `_configure_dspy()` 안의 `adapter=` **한 줄**이다.

    이 파일의 다른 시험들은 `build_adapter()` 를 손수 부르거나 `dspy.context` 로 어댑터를 직접
    꽂아 보므로 **그 줄을 지워도 전부 초록**이었다 — 컨트롤러 실측 변이
    `V6 _startup() drops adapter=build_adapter() -> 12 passed *** SURVIVED ***`.
    그 줄이 빠지면 레인은 조용히 텍스트 직렬화 경로로 돌아간다(spec §10 risk 4).
    이 시험이 그 줄의 유일한 감시자다.

    과금 0건: `dspy.LM(...)` 은 객체를 만들 뿐이고 `supports_function_calling` 은 provider 호출이
    아니다. 다만 **네트워크 0건은 아니다** — 파일 상단 주석 참조(원격 cost map fetch 시도)."""
    with _dspy_settings_restored():
        _configure_dspy()
        assert dspy.settings.adapter is not None
        assert dspy.settings.adapter.use_native_function_calling is True
        assert dspy.settings.lm.supports_function_calling is True


def test_the_program_that_actually_runs_is_what_gets_measured():
    """🔴 B1/V7. `native_fc_active()` 는 모듈 상수 `SelectTool` 이 아니라 **실제로 도는
    프로그램의 시그니처**를 읽어야 한다.

    컨트롤러 실측: 프로그램에서 tool 필드를 빼면 provider 로 나가는 tools 는 0개
    (`lm_kwargs["tools"] == []`)인데, `SelectTool` 을 읽는 판독기는 여전히 True 를 냈다.
    그건 "배선했다"와 "발화했다"를 가르려고 만든 필드가 바로 그 축에서 거짓말하는 것이다.
    변이 `V7 _load_program uses a tool-less signature` 가 이 시험 없이는 살아남았다
    (`-> 12 passed *** SURVIVED ***`)."""
    with _dspy_settings_restored():
        _configure_dspy()
        prog = _load_program()
        # 이름으로 본다 — 여기서는 이름이 곧 계약이다. Task 5/6 은
        # `prog(state=..., tools=[...], valid_actions=...)` 로 부를 것이고, 그 키워드가 이것이다.
        assert "tools" in prog.signature.input_fields
        assert native_fc_active() is True


def test_active_reads_the_live_program_not_the_module_constant():
    """🔴 B1 을 **단독으로** 붉히는 시험. 위 시험은 V7(tool 없는 프로그램)과 B1(모듈 상수를
    읽음)이 **함께** 있어야 붉어진다 — 프로그램이 옳으면 둘은 같은 답을 내기 때문이다.
    여기서는 둘을 일부러 갈라 놓고, 인자 없는 호출이 어느 쪽을 읽는지 직접 못박는다.

    실측(컨트롤러 B1): 이 상태에서 provider 로 나가는 tools 는 0개인데
    옛 구현은 `native_fc_active()` 로 True 를 냈다."""
    tool_less = dspy.Predict(SelectTool.delete("tools").delete("action"))
    with _dspy_settings_restored():
        _configure_dspy()
        dspy_service._state["program"] = tool_less
        # 도는 프로그램을 읽으면 False (조건 2·3 이 없다)
        assert native_fc_active() is False
        # 같은 순간 모듈 상수를 읽으면 True — 즉 둘은 정말로 갈리고, 어느 쪽을 읽는지가 중요하다
        assert native_fc_active(SelectTool) is True


def test_the_settings_restorer_actually_restores_by_identity():
    """🔴 D3. `_dspy_settings_restored()` 는 예방적이고 지워도 게이트는 초록이다(검증자 실측
    33/33). 그래도 "되돌린다"는 **주장**은 하고 있으므로 그 주장만은 검사로 받친다.

    `None -> None` 비교로는 안 된다 — 언제나 `None` 을 써 넣는 고장난 복원기도 통과한다.
    **객체 동일성**(`is`)으로 보고, **정상 경로와 예외 경로 둘 다** 본다."""
    lm0, ad0, prog0 = dspy.settings.lm, dspy.settings.adapter, dspy_service._state["program"]
    sentinel_lm, sentinel_ad = _real_lm(), build_adapter()
    sentinel_prog = dspy.Predict(SelectTool)
    try:
        dspy.configure(lm=sentinel_lm, adapter=sentinel_ad)
        dspy_service._state["program"] = sentinel_prog

        # (1) 정상 경로
        with _dspy_settings_restored():
            _configure_dspy()
            dspy_service._state["program"] = dspy.Predict(SelectTool)
            assert dspy.settings.lm is not sentinel_lm      # 안에서는 정말로 바뀌어 있다
        assert dspy.settings.lm is sentinel_lm
        assert dspy.settings.adapter is sentinel_ad
        assert dspy_service._state["program"] is sentinel_prog

        # (2) 예외 경로 -- finally 가 도는지
        try:
            with _dspy_settings_restored():
                _configure_dspy()
                raise RuntimeError("시험용 폭발")
        except RuntimeError:
            pass
        assert dspy.settings.lm is sentinel_lm
        assert dspy.settings.adapter is sentinel_ad
        assert dspy_service._state["program"] is sentinel_prog
    finally:
        dspy.configure(lm=lm0, adapter=ad0)
        dspy_service._state["program"] = prog0
