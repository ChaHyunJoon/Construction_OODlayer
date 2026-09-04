"""거절 사유 되먹임 채널. 유료 0건 — dspy 프로그램은 가짜로 바꿔 끼운다."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class _FakePred:
    wrote = True
    impl_name = "fixed_tool!"
    impl_code = "function fixed_tool!(env; k::Int=0)\n    return (status = :ok,)\nend"
    params = '{"k": {"type": "integer"}}'
    calls = [{"primitive": "fixed_tool!", "args": {"k": 1}}]
    surface = "sched"
    reversible = False


def _fake_program(**kw):
    return _FakePred()


def test_rewrite_signature_declares_the_rejection_reason():
    """🔴 계획서 정정 (2026-09-04, 실측). 브리프는 거절된 코드의 **입력** 이름을
    `impl_code` 로 적었는데, 같은 시그니처가 `impl_code` 를 **출력**으로도 선언한다.
    dspy 시그니처는 pydantic 모델이라 한 이름이 둘 다일 수 없고, 충돌은 **에러 없이**
    뒤엣것만 남긴다 — 그대로 옮겨 적으면 입력이 통째로 사라져 시그니처가
    `(spec, world_interface, impl_rejected_why -> ...)` 로 해소된다. 즉 **agent-3 이
    고쳐야 할 코드를 한 번도 못 보는** 채널이 되고, 그것은 이 태스크가 만들려는 것의
    정반대다. 출력 이름은 전선 계약이므로(줄리아가 `f.impl_code` 로 읽는다) 입력을
    `rejected_impl_code` 로 개명했다."""
    import synthesize as SY
    assert "impl_rejected_why" in SY.RewriteToolImpl.input_fields
    # 거절된 코드가 **입력으로 실제로 존재한다**.
    assert "rejected_impl_code" in SY.RewriteToolImpl.input_fields
    # 🔴 음성 대조: 충돌이 되살아나면 이 둘이 잡는다. 하나라도 빠지면 위 단언은 초록인 채로
    #    입력이 사라질 수 있다(그것이 정확히 브리프 판이 통과하던 모양이다).
    assert "impl_code" in SY.RewriteToolImpl.output_fields
    assert "impl_code" not in SY.RewriteToolImpl.input_fields


def test_the_output_order_survives_the_rename():
    """🔴 충돌의 **두 번째** 대가. 입력 선언이 슬롯을 먼저 잡으면 출력 순서가
    `impl_code, wrote, …` 로 뒤집힌다 — `WriteToolImpl` 이 굵은 빨강으로 "맨 앞으로
    되돌리지 말 것" 이라고 적은 바로 그 순서다(잘림이 값싼 스칼라 넷을 통째로 먹는다).
    이름 하나 때문에 그 계약이 조용히 깨지지 않게 여기서 못박는다."""
    import synthesize as SY
    order = list(SY.RewriteToolImpl.output_fields)
    assert order[:4] == ["wrote", "impl_name", "surface", "reversible"], order
    assert order.index("impl_code") < order.index("params"), order
    assert order.index("impl_code") < order.index("calls"), order


def test_rewrite_impl_returns_a_body_and_records_the_reason():
    import synthesize as SY
    out = SY.rewrite_impl(
        tool_name="t!", spec="a spec",
        impl_name="broken_tool!", impl_code="function broken_tool!(env) end",
        impl_rejected_why="reject:impl_not_single_expression:2",
        program=_fake_program)
    assert out["wrote"] is True
    assert out["impl_name"] == "fixed_tool!"
    assert out["error"] is None
    assert out["rewrite_of_why"] == "reject:impl_not_single_expression:2"


def test_rewrite_impl_never_raises():
    """🔴 이 경로에서 새는 예외는 Julia 쪽에서 세계 상태를 잃게 만든다."""
    import synthesize as SY

    def _boom(**kw):
        raise RuntimeError("provider is down")

    out = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                          impl_rejected_why="reject:whatever", program=_boom)
    assert out["wrote"] is None            # 🔴 삼상: 못 쟀다
    assert "provider is down" in out["error"]


def test_params_crosses_the_boundary_as_an_object_not_a_string():
    """🔴 계획서 정정 (2026-09-04, 실측). 브리프는 `params` 를 **날것**으로 실었는데
    `RewriteToolImpl.params` 는 `str` 이고, 이 값은 경계를 건너
    `register_minted_primitive!(params = ...)` 로 그대로 들어간다 — 그 가드는
    `AbstractDict` 를 요구한다(`enact.jl` 의 `reject:params_not_an_object:`).
    그대로 두면 되먹임이 성공해도 고친 body 가 **우리 쪽 직렬화 때문에** 거절되고
    기록에는 "agent-3 이 또 실패했다" 로 남는다 — 이 채널이 재려는 수치가 오염된다.
    본 경로(`_finish_record`)와 **같은 정규화기**(`params_object`)를 쓴다."""
    import synthesize as SY
    out = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                          impl_rejected_why="reject:w", program=_fake_program)
    assert isinstance(out["params"], dict), type(out["params"])
    assert out["params"] == {"k": {"type": "integer"}}
    # 🔴 삼상은 그대로다: 못 읽으면 `None`("못 쟀다")이지 `{}`("쟀는데 비었다")가 아니다.
    #    `{}` 를 보내면 빈 스키마로 등록이 **성공한 뒤** 모든 호출 인자가 스키마 밖이라고
    #    거절돼 원시가 평생 호출 불가가 된다(`params_object` 의 docstring 이 근거).
    class _Unreadable(_FakePred):
        params = "not json at all"

    out2 = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                           impl_rejected_why="reject:w",
                           program=lambda **kw: _Unreadable())
    assert out2["params"] is None


def test_the_channel_actually_carries_the_fixed_body():
    """🔴 D3 (Wave D, Task 9 리뷰 I1). 이 채널의 **존재 이유**인 `impl_code` 를 단언하는
    시험이 하나도 없었다 — 실측 변이: `out["impl_code"]`·`out["calls"]`·`out["surface"]`
    를 전부 `None` 으로 죽여도(= 채널이 나르는 산출물 넷 중 셋을 제거) 이 파일이 **5
    passed** 였다. 즉 payload 가 파이썬 쪽에서도 무방비였고, 그래서 C1 이 눈에 안 띄었다.

    🔴 여기서 재는 것은 **경계 계약**이다: 이 넷이 그대로 Julia 로 건너가
    `register_minted_primitive!(name=, code=, params=, surface=, reversible=)` 와
    `sl["calls"]` 를 채운다(`tools/monitor/enact.jl` 의 되먹임 성공 분기). 하나라도
    `None` 이면 그 자리가 조용히 기본값으로 떨어지거나 등록이 거절된다."""
    import synthesize as SY
    out = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="broken_tool!",
                          impl_code="function broken_tool!(env) end",
                          impl_rejected_why="reject:whatever", program=_fake_program)
    assert out["impl_code"] == _FakePred.impl_code
    assert out["surface"] == "sched"
    assert out["reversible"] is False              # 🔴 `None`(못 쟀다)이 아니다
    assert out["calls"] == [{"primitive": "fixed_tool!", "args": {"k": 1}}]
    # 🔴 코드 펜스는 벗겨진다 — 그대로 넘기면 Julia 가 `impl_not_a_function` 으로 거절한다
    #    (유료 런 2 가 정확히 그 자리에서 죽었다).
    class _Fenced(_FakePred):
        impl_code = "```julia\n" + _FakePred.impl_code + "\n```"

    out2 = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                           impl_rejected_why="reject:w", program=lambda **kw: _Fenced())
    assert out2["impl_code"].strip() == _FakePred.impl_code.strip(), out2["impl_code"]
    assert "```" not in out2["impl_code"]


def test_the_tri_state_survives_on_every_carried_field():
    """🔴 삼상은 `wrote` 만의 계약이 아니다. 모델이 필드를 안 채우면 `None`("못 쟀다")이지
    `""`/`[]`("재서 비었다")가 아니어야 한다 — 뭉개면 Julia 쪽에서 "되먹임이 코드를 안
    줬다" 와 "빈 코드를 줬다" 가 같은 관측이 된다."""
    import synthesize as SY

    class _Blank:
        wrote = True
        impl_name = ""
        impl_code = ""
        params = None
        calls = None
        surface = ""
        reversible = "not a bool"

    out = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                          impl_rejected_why="reject:w", program=lambda **kw: _Blank())
    assert out["impl_name"] is None
    assert out["impl_code"] is None
    assert out["surface"] is None
    assert out["params"] is None
    assert out["reversible"] is None               # 비-bool 은 "못 쟀다"
    # 🔴 비-0 대조: 같은 함수가 채워진 판에서는 값을 낸다(위 단언이 항진이 아니다).
    ok = SY.rewrite_impl(tool_name="t!", spec="s", impl_name="b!", impl_code="x",
                         impl_rejected_why="reject:w", program=_fake_program)
    assert ok["impl_name"] == "fixed_tool!" and ok["impl_code"]

