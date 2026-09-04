"""T6b 게이트 — **LLM 의 답이 아니라 기계를 잰다** (컨트롤러 판정 R14).

🔴 2026-09-03 (Task 10). 이 파일은 원래 **단일 agent 레인**(`maybe_synthesize`)과 **고정
19-원시 레지스트리**(`primitive_registry.py`)를 재고 있었다. 둘 다 이 계획이 일부러 지웠다
(D5·D7·D8) — agent-3 은 인벤토리에서 조합하는 대신 Julia 구현을 **쓴다**. 그래서 그 어휘를
재던 절 여섯(프롬프트 렌더 · canon/`parse_body` · `needs_primitive` 기록 · ψ 거리 ·
`tool_minted` 네 값 · 알파벳 가시성)은 **잰 대상이 없어져** 지웠다. `tool_minted` 네 값과
원장 카운트는 오늘 `test_synthesis_record_contract.py` 가 `synthesize_multi` 의 탈출 경로
전수로 재고, 프롬프트 계약은 `test_synthesize_multi.py` 가 잰다.

**남은 넷은 지운 어휘와 무관하고, 이 파일이 그것들의 유일한 소비처다**(실측:
`params_flatness` · `_NetSpy` · numpy-before-dspy(`synthesize.py` 판) · `out["dspy"]` 표식
게이트는 전부 이 파일에만 있다). 그래서 파일을 통째로 지우지 않았다.

  (A) 꺼져 있으면 **소켓이 0** 이다 (R13, 과금 0건). 음성 대조가 함께 있다.
      🔴 그 판에서 **잃은 정보**가 무엇인지도 함께 못박는다(그 시험의 주석 참고).
  (B) `params` 평평함 — Julia 경계의 얕은 변환 함정. 🔴 순수 함수(`params_flatness`)와
      **기록되는가**(`rec["params_flat"]`) 를 **둘 다** 잰다.
      ⚠️ 2026-09-03 fix round 1 정정: 1차에서 뒤엣것을 "삭제된 `maybe_synthesize` 를 부르니
      (a)" 로 판정해 지웠는데, 죽은 것은 **호출**이었고 성질이 아니었다 — 그 결과
      `_finish_record` 의 기록 줄을 지워도 아무것도 안 빨개지는 상태가 됐고, 이 머리말은
      그 동안에도 (B) 를 유지 항목으로 적고 있었다. 되살렸다(변이로 확인).
  (C) 원장은 중복에서 파라미터를 따로 쌓는다 (spec §5-2-2 ①).
  (D) 서비스 배선 — `/macro`·`/decide` 가 값을 나르고, 합성 레인 키가 `out["dspy"]` 의
      tool 레인 표식 **위**에 앉는다(줄리아 게이트와의 교차언어 결속).

🔴 이 파일은 라이브 호출을 한 번도 하지 않는다. `127.0.0.1:8077` 로 POST 하지도 않는다.
⚠️ `DummyLM.supports_function_calling` 은 False 다 — DummyLM 왕복은 언제나 **텍스트 폴백
경로**를 잰다. 이 파일의 어떤 단언도 native function calling 이 켜졌다고 주장하지 않는다.
"""
import json
import os
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import synthesize as syn  # noqa: E402  (numpy/sklearn-before-dspy 가드를 이 파일이 먼저 태운다)
import dspy  # noqa: E402
from dspy.utils.dummies import DummyLM  # noqa: E402

# ==========================================================================================
# (A) 꺼져 있으면 네트워크 호출이 0 이다 (소켓 실측)
# ==========================================================================================
class _NetSpy:
    """소켓을 가로채 **연결 시도 횟수**를 센다. 프로세스 전역이라 반드시 되돌린다.

    ⚠️ 이 spy 가 재는 것은 `socket.socket.connect` · `socket.create_connection` 두 진입점의
    호출 횟수다. 그것이 이 프로세스의 아웃바운드 전부라고 **주장하지 않는다**(별도 스레드가
    다른 백엔드를 쓰면 안 보인다). 재는 것은 이 호출 경로의 연결 시도다.
    """

    def __enter__(self):
        self.calls = []
        self._c, self._cc = socket.socket.connect, socket.create_connection

        def connect(s, addr, *a, **k):
            self.calls.append(addr)
            return self._c(s, addr, *a, **k)

        def create_connection(addr, *a, **k):
            self.calls.append(addr)
            return self._cc(addr, *a, **k)
        socket.socket.connect = connect
        socket.create_connection = create_connection
        return self

    def __exit__(self, *e):
        socket.socket.connect = self._c
        socket.create_connection = self._cc
        return False


def test_synthesis_opens_zero_sockets_when_the_flag_is_off(monkeypatch):
    """🔴 R13 의 실측. 꺼져 있을 때 이 레인은 소켓을 하나도 안 연다 — context 도 안 짓고
    `dspy.ChainOfThought` 도 안 만든다.

    ⚠️ 주장의 범위를 정확히 쓴다: 이것은 **합성 진입점 호출 경로**의 연결 시도가 0 이라는
    주장이다. 같은 프로세스의 다른 코드에 대한 주장이 아니다 — 예컨대
    `supports_function_calling` 을 **읽는** 것은 raw.githubusercontent.com 으로 8회 연결을
    시도한 뒤 로컬로 폴백한다(2026-08-28 실측). 과금은 안 되지만 '네트워크 0' 은 아니다.

    🔴 2026-09-03 (Task 10). 진입점이 `maybe_synthesize`(단일 agent 레인, D8 로 삭제)에서
    `synthesize_multi` 로 옮겨졌다. **재는 계약은 한 글자도 안 바뀌었다** — 꺼진 레인은
    유료 호출은커녕 소켓 하나도 안 연다(R13). `observe_context_chars` 는 agent-1 의 context
    를 실제로 지었을 때만 생기는 키라, 그 부재가 "프롬프트 렌더 비용조차 안 썼다" 를 나른다.
    """
    monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
    with _NetSpy() as spy:
        rec = syn.synthesize_multi(state="obs", tools=[], kind="zone",
                                   ledger=syn.SynthesisLedger())
    assert rec["tool_minted"] == "disabled"
    assert rec["enabled"] is False and rec["stages"] == []
    assert spy.calls == [], "합성이 꺼져 있는데 연결을 시도했다: %r" % (spy.calls,)
    assert "observe_context_chars" not in rec, "꺼져 있는데 context 를 지었다(프롬프트 렌더 비용)"
    # 🔴 G1 가드(`compose_interface`)도 안 돈다 — 꺼진 레인은 파일 하나도 안 읽는다.
    assert rec["refused"] is None


def test_the_socket_spy_can_actually_see_a_connection():
    """음성 대조: spy 가 아무것도 못 보는 죽은 계측이면 위 0 은 무의미하다. 닫힌 로컬 포트로
    한 번 연결을 시도해 **잡히는지** 확인한다(POST 없음, 원격 없음 -- 127.0.0.1 의 임의 포트로
    거절당하는 것이 전부다. 🔴 8077 은 쓰지 않는다: 그 포트에는 유료 리스너가 떠 있다)."""
    with _NetSpy() as spy:
        s = socket.socket()
        s.settimeout(0.2)
        try:
            s.connect(("127.0.0.1", 1))
        except Exception:
            pass
        finally:
            s.close()
    assert spy.calls, "소켓 spy 가 연결 시도를 못 봤다 -- 계측이 죽었다."



# ==========================================================================================
# (B) params 평평함 — T1 이 남긴 얕은 변환 함정을 여기서 닫는다
# ==========================================================================================
def test_flat_params_pass_and_nested_params_are_flagged():
    """🔴 줄리아의 `_tool_args_dict`(`tools/monitor/policy.jl`)는 **얕다**. 중첩 인자를
    가진 tool 을 합성하는 순간 그 값은 `JSON3.Object` 로 남아 `Dict{String,Any}` 가정을
    **에러 없이** 깬다. 줄리아를 못 건드리는 이 태스크는 `params` 를 평평한 스칼라로 제약하고
    그 제약을 여기서 잡는다."""
    ok, why = syn.params_flatness('{"dx": {"type": "number"}, "z": {"type": ["string","null"]}}')
    assert ok is True, why
    ok, why = syn.params_flatness('{"type":"object","properties":{"dx":{"type":"number"}}}')
    assert ok is True, why
    for bad in ('{"where": {"type": "object", "properties": {"x": {"type": "number"}}}}',
                '{"ids": {"type": "array", "items": {"type": "string"}}}',
                '{"p": {"$ref": "#/defs/Pose"}}'):
        ok, why = syn.params_flatness(bad)
        assert ok is False, bad
        assert "JSON3.Object" in why


def test_unmeasurable_params_are_none_not_false():
    """🔴 '못 쟀다'와 '재서 어겼다'를 섞지 않는다 — 이 레포가 여러 번 데인 자리다."""
    for t in (None, "", "not json at all", "[1,2,3]", "{}"):
        ok, why = syn.params_flatness(t)
        assert ok is None, (t, ok, why)
        assert why


class _Pred:
    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def _flat_progs(params):
    """세 단계를 대신하는 순수 함수 셋. 프로바이더에 안 나간다 — 과금 0건."""
    def observe(**kw):
        return _Pred(reasoning_log="the zone froze three staging areas")

    def design(**kw):
        return _Pred(expressible=False, tool_name="T",
                     params='{"a": {"type": "string"}}', mechanism="m")

    def compose(**kw):
        # 🔴 R6: `rec["params"]` 는 **agent-3** 의 스키마다(agent-2 의 것은 `spec_params`).
        #    평평함이 재는 것은 집행부가 실제로 받을 그 스키마이므로 여기에 심는다.
        return _Pred(impl_name="clear_staging_obstruction!",
                     impl_code="function clear_staging_obstruction!(env; a = 1)\n    return :ok\nend\n",
                     params=params, surface="scene_tree", reversible=True, wrote=True,
                     reasoning="r")

    return {"observe": observe, "design": design, "compose": compose}


def test_a_nested_params_answer_is_recorded_but_not_dropped(monkeypatch):
    """🔴 F4 (2026-09-03, fix round 1). **이 시험은 은퇴시켰다가 되살렸다.**

    1차에서 "삭제된 `maybe_synthesize` 를 부르므로 (a)" 로 판정하고 지웠는데 그것이 틀렸다:
    죽은 것은 **호출**이었고 **성질**이 아니었다. `params_flatness` 를 부르는 생산 코드
    (`_finish_record` 의 `rec["params_flat"], rec["params_flat_detail"] = ...`)는 그대로
    살아 있는데, 그 줄을 지워도 **아무것도 안 빨개지는 상태**가 됐다 — 이 파일의 머리말이
    "(B) params 평평함" 을 유지 항목으로 적어 놓고 정작 기록되는지는 아무도 안 쟀다.

    재는 것 둘: (i) 제약을 어긴 출력도 **버리지 않는다**(정의는 끝까지 남고 판정만 기록된다),
    (ii) 그 판정이 **기록에 실제로 실린다**.
    """
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")
    nested = '{"where": {"type": "object", "properties": {"x": {"type": "number"}}}}'
    rec = syn.synthesize_multi(state="obs", tools=[], kind="zone",
                               ledger=syn.SynthesisLedger(),
                               programs=_flat_progs(nested))
    assert rec["params_flat"] is False, "평평함 판정이 기록에 안 실린다"
    assert "JSON3.Object" in (rec["params_flat_detail"] or ""), "왜 어겼는지가 안 남았다"
    assert rec["mechanism"] and rec["impl_code"], "정의는 끝까지 기록된다"
    assert rec["tool_minted"] is True, "판정만 기록하고 **버리지는 않는다**"

    # 양성 대조: 평평한 스키마는 같은 경로에서 `True` 다(위 줄이 상수가 아니다).
    ok = syn.synthesize_multi(state="obs", tools=[], kind="zone",
                              ledger=syn.SynthesisLedger(),
                              programs=_flat_progs('{"a": {"type": "string"}}'))
    assert ok["params_flat"] is True

    # 🔴 삼상: 못 잰 판은 `False`("재서 어겼다")가 아니라 `None` 이다.
    un = syn.synthesize_multi(state="obs", tools=[], kind="zone",
                              ledger=syn.SynthesisLedger(), programs=_flat_progs(""))
    assert un["params_flat"] is None



# ==========================================================================================
# (C) 원장 — 중복은 차단이 아니라 **측정**이다
# ==========================================================================================
def test_the_ledger_counts_a_repeat_and_stacks_its_parameters():
    """spec §5-2-2 ① · §5-2-3. 🔴 `minted == False` 는 실패가 아니라 |K| 곡선의 한 점이다.

    🔴 2026-09-03. 옛 판은 이것을 `maybe_synthesize` + `parse_body` 로 몰아서 쟀다 — 둘 다
    지운 어휘다. 재던 사실(중복이 |K| 를 안 올리고, 파라미터는 따로 쌓인다)은 그대로 참이고
    원장 자신에 대한 사실이므로 원장을 직접 태운다. `count` 만 재는 짝은
    `test_synthesis_record_contract.py` 에 있고, **`params` 누적은 여기가 유일한 소비처다.**
    """
    led = syn.SynthesisLedger()
    assert led.K == 0
    c1 = syn.canon(["translate_whole_build"], "zone")
    c2 = syn.canon(["restage_assembly"], "zone")
    assert led.observe(c1, params='{"dx": 2.38}', tool_name="t") is True
    assert led.K == 1
    # 파라미터만 다른 같은 정규형 — 새 canon 이 아니다(spec §5-2-2: canon 은 파라미터를 무시한다).
    assert led.observe(c1, params='{"dx": 2.40}', tool_name="t") is False
    assert led.K == 1
    assert led.observe(c2, params="{}", tool_name="t") is True
    assert led.K == 2

    e = led.entries[syn.canon_key(c1)]
    assert e["count"] == 2, "중복은 차단이 아니라 **측정**이다 -- 카운터가 올라야 한다"
    assert len(e["params"]) == 2, "중복에서 파라미터만 따로 쌓인다(spec §5-2-2 ①)"


# ==========================================================================================
# (D) 서비스 배선 — `/macro` 와 `/decide` 가 값을 실제로 나른다
# ==========================================================================================
def _svc():
    import dspy_service as svc
    return svc


def test_macro_and_decide_carry_tool_minted(monkeypatch):
    """🔴 배선을 잰다. `/macro` 에는 이 레포에 호출자가 0개이고 라이브 레인은 `/decide` 로만
    들어오므로(`tools/monitor/policy.jl` 의 `HTTP.post(DSPY_URL * "/decide", …)`),
    **둘 다** 확인한다."""
    monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
    svc = _svc()
    AG = [{"id": "R5", "label": "Robot R5"}]

    # 🔴 2026-08-29 (T4): `expressible` 은 텍스트 `OutputField` 가 아니라 **tool 인자**다.
    #    옛 판(`ans(expressible="False")`)은 이제 그 값을 아무 데도 안 싣고, 호출도 0건이라
    #    `decision_source="no_call"` 로 떨어져 합성이 영원히 안 발화한다.
    def ans(expressible=False, **kw):
        args = {"agent": "R5", "macro": "NOOP", "reasoning": "r",
                "expressible": expressible, "ranking": "NOOP, Replace, SwapBattery"}
        args.pop("agent")               # no_intervention 은 agent 를 안 받는다
        args["reason"] = "nothing in the menu fits"
        b = {"action": {"tool_calls": [{"name": "no_intervention", "args": args}]}}
        b.update(kw)
        return b
    dspy.configure(lm=DummyLM([ans(), ans(expressible=True)]), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()
    req = svc.MacroRequest(kind="battery", soc=0.1, agents=AG,
                           valid=["NOOP", "Replace", "SwapBattery"], nl="obs")
    d = svc.macro(req)
    assert d["tool_minted"] == "disabled"
    # 🔴 2026-09-03 (Task 10). 이 단언은 **뒤집혔다.** 옛 단일 agent 레인
    #    (`maybe_synthesize`, D8 로 삭제)은 플래그를 보기 **전에** `synthesis_event` 를
    #    `expressible is False` 로 찍었다 — "꺼져 있었지만 발화할 사건이었다". `synthesize_multi`
    #    는 플래그를 먼저 보고 `_blank` 를 그대로 돌려주므로 그 자리는 `False` 다.
    #    🔴 **이것은 새는 것이 아니라 선언된 계약이다**: `synthesize.CONSUMER_RULES` 의
    #    "was switched off" 행이 `synthesis_event == False` 를 명시적으로 적고
    #    `test_synthesis_record_contract.py` 가 그 표를 코드와 대조한다.
    # 🔴 **그러나 정보는 잃었다** (2026-09-03 fix round 1 정정 — 이 주석의 1차 판은
    #    "잃은 정보도 없다 … `expressible` 은 따로 실린다" 고 적었고 그것은 **거짓**이다).
    #    실측: 플래그가 꺼진 판의 기록에서 `expressible` 은 **`None`** 이다 —
    #    `run_synthesis` 가 호출자의 값을 일부러 버리고(D8) agent-2 는 돌지도 않았다.
    #    옛 단일 레인의 `synthesis_event=True` 가 "이 사건은 발화할 사건이었다" 를 나르는
    #    **유일한** 운반체였고, 오늘 그것을 나르는 필드는 기록에 없다.
    #    ⟹ 🔴 **꺼진 판의 행으로 발화율(분자든 분모든)을 계산하지 말 것.** 그 분모는 존재하지
    #    않는다 — `run_synthesis` 의 docstring 이 `macro_tool_agree` 로 이름 지은 "같은 이름의
    #    비율을 서로 다른 분모 위에서 계산하는" 사고가 정확히 이 자리에서 다시 가능하다.
    #    (지금 이 아래 두 줄이 그 부재를 값으로 못박는다.)
    #    ⚠️ 이 회귀는 `primitive_registry` 수집 에러 뒤에 **가려져 있었다**(이 파일은 16faa75c
    #       부터 한 번도 수집되지 않았다). 지우지 않고 기대를 뒤집는 이유가 그것이다.
    assert d["synthesis"]["synthesis_event"] is False
    assert d["synthesis"]["enabled"] is False
    # 🔴 위 문단이 주장하는 손실을 **값으로** 못박는다: 발화 자격을 나르는 필드가 없다.
    assert d["synthesis"]["expressible"] is None, (
        "꺼진 판에서 `expressible` 이 값을 갖게 됐다면 위 문단의 손실 서술이 낡은 것이다")
    assert d["synthesis"]["ran"] is False
    out = svc.decide(req)
    # 🔴 2026-09-03 (Task 10). 여기도 뒤집혔다. 옛 판은 "두 번째 응답은 expressible=True 라
    #    발화 사건이 아니므로 `tool_minted is None`" 을 단언했는데, `run_synthesis` 는
    #    **호출자의 `expressible` 을 일부러 안 쓴다**(D8: 발화 판정의 출처를 agent-2 하나로
    #    모은다 — `synthesize.py::run_synthesis` docstring 이 그 근거를 적는다). 그래서 플래그가
    #    꺼져 있으면 발화 여부와 무관하게 두 진입점 다 `"disabled"` 다.
    #    ⚠️ 재는 것은 그대로 **배선**이다: `/macro` 와 `/decide` 가 같은 레인 값을 나르는가.
    assert out["dspy"]["tool_minted"] == "disabled"
    assert d["tool_minted"] == out["dspy"]["tool_minted"], (
        "`/macro` 와 `/decide` 가 같은 사건에서 다른 합성 판정을 내면 두 진입점이 갈렸다는 뜻이다")
    assert "synthesis" in out["dspy"], "/decide 가 합성 기록을 안 나르면 라이브 레인에서 안 보인다"
    assert json.dumps(out["dspy"]["synthesis"]), "응답이 JSON 직렬화돼야 줄리아가 읽는다"


def test_synthesize_keeps_the_numpy_before_dspy_contract():
    """🔴 `dspy_service.py` 의 `import numpy, sklearn.ensemble` 줄 · `tool_registry.py` 와 같은
    계약. 수집 순서가 바뀌면 이 파일이
    혼자 먼저 dspy 를 심을 수 있다."""
    src = open(syn.__file__, encoding="utf-8").read()
    assert src.index("import numpy, sklearn.ensemble") < src.index("\nimport dspy")


def test_synthesis_keys_sit_above_the_tool_lane_marker_in_out_dspy():
    """🔴 교차언어 결속. `test/tool_lane_keys_survive.jl` (6)절은 `out["dspy"]` dict 안의
    `# ---- tool 레인 …` 표식 **아래** 키 집합을 Julia 의 `TOOL_LANE_KEYS`(2026-09-02 현재 **열둘**)와 **양방향
    등호**로 대조한다(그 파일의 `@testset "(6) 🔴 교차언어 — Julia 의 키 목록이 파이썬 소스에
    묶여 있다"`). 그러므로 표식 아래에 합성 레인
    키를 하나라도 넣으면 그 줄리아 게이트가 정당하게 빨개진다 — 이 태스크는 줄리아를 안
    건드리므로 키를 표식 **위**에 둔다.

    이 테스트가 여기 있는 이유: 그 결속은 **파이썬 파일 안의 줄 순서**에 걸려 있고, 파이썬만
    보는 사람에게는 보이지 않는다. 줄리아 스위트를 안 돌린 편집 하나가 조용히 그쪽을 깨는
    자리라 파이썬 쪽에도 그물을 둔다. 🔴 여기서 추출 코드를 **베끼지 않는다** — 줄리아
    파일에 있는 그 스크립트를 읽어서 그대로 돌린다. 베끼면 사본이 낡는다."""
    import ast as _ast
    import re as _re
    repo = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    jl = os.path.join(repo, "test", "tool_lane_keys_survive.jl")
    if not os.path.exists(jl):
        raise AssertionError(
            "%s 가 없다 -- 이 결속의 반대편이 사라졌다. skip 하지 않는다: 그러면 파이썬 쪽 "
            "그물이 조용히 죽는다." % jl)
    jsrc = open(jl, encoding="utf-8").read()
    m = _re.search(r'_PY_EXTRACT = raw"""\n(.*?)\n"""', jsrc, _re.S)
    assert m, "줄리아 게이트의 _PY_EXTRACT 블록을 못 찾았다 -- 그쪽 모양이 바뀌었다."
    pat = _re.search(r're\.match\(r"([^"]+)"', m.group(1))
    assert pat, "표식 정규식을 못 찾았다"
    marker_re = _re.compile(pat.group(1))

    src = open(os.path.join(HERE, "dspy_service.py"), encoding="utf-8").read()
    lines = src.split("\n")
    lits = [n.value for n in _ast.walk(_ast.parse(src))
            if isinstance(n, _ast.Assign) and len(n.targets) == 1
            and isinstance(n.targets[0], _ast.Subscript)
            and isinstance(n.targets[0].value, _ast.Name)
            and n.targets[0].value.id == "out"
            and isinstance(n.targets[0].slice, _ast.Constant)
            and n.targets[0].slice.value == "dspy"
            and isinstance(n.value, _ast.Dict)]
    assert len(lits) == 1
    d = lits[0]
    marks = [i + 1 for i in range(d.lineno - 1, d.end_lineno)
             if marker_re.match(lines[i])]
    assert len(marks) == 1, (
        "`out['dspy']` 안의 `# ---- tool …` 표식이 %d 개다 -- 줄리아 추출기는 정확히 1개를 "
        "요구하고 아니면 그 게이트가 죽는다." % len(marks))
    lane = [k.value for k in d.keys if k.lineno > marks[0]]
    # 🔴 2026-08-29 (T4): `text_rescue` 가 빠지고 `decision_source`·`tool_arg_error` 가
    #    들어와 열한 개가 됐고, 2026-09-02 에 `menu_expressible` 이 들어와 **열두 개**다.
    #    ✅ 줄리아의 `TOOL_LANE_KEYS` 도 같은 커밋에서 열둘이 됐다 — (6)절은 **초록**이다
    #    (실측 140/140). 옛 판에서 이 자리는 "줄리아가 아직 옛 열 개라 (6)절이 정당하게
    #    빨갛다" 였는데, 그 서술은 2026-09-02 부터 거짓이다. 파이썬에서 키를 표식 위로 숨겨
    #    초록을 만들지 않는 규칙은 그대로다 — 숨기면 줄리아가 안 나르는 상태가 조용해진다.
    # 🔴 2026-09-02: `menu_expressible` 이 열두 번째로 들어왔다(귀속용 두 번째 질문).
    #    이 집합 · 줄리아 `TOOL_LANE_KEYS` · `test_tool_choice_forced.py` 의 같은 집합 ·
    #    `test_macro_returns_tool_call.py` 의 `_LANE_KEYS` 는 **한 커밋에서 함께** 움직인다.
    assert set(lane) == {"tool_called", "tool_args", "tool_calls_n", "tools_offered",
                         "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                         "tool_choice", "decision_source", "tool_arg_error",
                         "menu_expressible"}, lane
    allk = [k.value for k in d.keys]
    assert "tool_minted" in allk and "synthesis" in allk, (
        "합성 레인 키가 /decide 응답에서 사라졌다 -- 라이브 레인은 /decide 로만 들어온다.")

