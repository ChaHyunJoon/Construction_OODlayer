"""서비스가 원장에 쓰는 두 종류의 행. 유료 0건 — DummyLM · 가짜 rewrite_impl.

🔴 가짜 응답은 **tool 을 부르는 모양**이어야 정상 경로(합성 단계)를 탄다. `tool_calls: []` 인
응답(test_decide_lanes 의 픽스처)은 `macro()` 의 `no_call` 조기 반환을 탄다 — 2026-09-22
브리프 작성 시점에는 그 경로가 원장에 **아무것도 안 남겼다**(그 응답으로는 원장 파일이 안
생기고, `_call("deliver_battery")` 응답으로는 생겼다). 이 태스크가 그 구멍을 닫는다: 이제
`macro()` 에 들어온 요청은 **어느 경로로 나가든** `row_type="decide"` 행을 정확히 하나 남기고,
어느 경로였는지를 `decide_outcome` 이 이름으로 말한다(global-constraints.md "Task 3, 조기 반환").
그래서 아래에는 조기 반환 경로 전부의 시험이 있다. 가짜 LM 조립기는
`test_macro_returns_tool_call.py` 의 `_install`·`_call`·`_req` 를 그대로 쓴다(정본).

🔴 원장이 필요한 시험은 전부 `tmp_path` + `SYNTH_RECORD_LOG` monkeypatch 다 — 루트
`conftest.py` 의 `SYNTH_RECORD_LOG=0` 을 시험 하나 범위에서만 덮는다.
"""
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import dspy_service as svc  # noqa: E402  (numpy/sklearn-before-dspy 계약)
import synthesize as SY  # noqa: E402
import dspy  # noqa: E402
import pytest  # noqa: E402
from dspy.utils.exceptions import AdapterParseError, LMError  # noqa: E402
import test_macro_returns_tool_call as T  # noqa: E402  (fake-LM 조립기의 정본)

_req = T._req


@pytest.fixture
def fake_lm():
    T._install(T._call("deliver_battery", macro="SwapBattery"), fc=False)
    svc._load_surrogate()


@pytest.fixture
def ledger(tmp_path, monkeypatch):
    p = tmp_path / "ledger.jsonl"
    monkeypatch.setenv("SYNTH_RECORD_LOG", str(p))
    monkeypatch.delenv("TOOL_SYNTHESIS", raising=False)
    return p


def _rows(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


# =================================================================================================
# 브리프 본문의 네 시험 (+ response_id · decide_outcome 단언, controller R2·R3)
# =================================================================================================

def test_decide_row_carries_the_julia_issued_identity(fake_lm, ledger):
    out = svc.decide(_req(lanes=["dspy"], record_id="rid-1",
                          run_ctx={"seed": 3, "zone_seed": 3, "model": "tractor"}))
    rows = _rows(ledger)
    assert len(rows) == 1
    r = rows[0]
    assert (r["row_type"], r["record_id"], r["attempt"], r["trigger"]) == \
           ("decide", "rid-1", 1, "first")
    assert r["parent_record_id"] is None
    assert r["run_ctx"] == {"seed": 3, "zone_seed": 3, "model": "tractor"}
    assert r["ledger_version"] == 2
    assert r["code_fingerprint"] == svc.CODE_FINGERPRINT
    assert sorted(r["raw_lm"]) == ["compose", "design", "observe"]
    # TOOL_SYNTHESIS 가 꺼져 있다 — 결정은 났고 합성은 안 돌았다(성공/실패와 구별).
    assert r["decide_outcome"] == "synthesis_disabled"
    # 전선: 줄리아가 스트림에 실을 id 가 돌아온다. 원시 응답은 전선에 안 실린다.
    syn = out["dspy"]["synthesis"]
    assert syn["record_id"] == "rid-1"
    assert "raw_lm" not in syn and "decide_outcome" not in syn
    # controller R2: 서버가 처리마다 발급한 response_id 가 원장과 전선에 **같은 값**으로 있다.
    assert isinstance(syn["response_id"], str) and len(syn["response_id"]) == 32
    assert r["response_id"] == syn["response_id"]


def test_decide_without_identity_still_writes_an_honest_row(fake_lm, ledger):
    svc.decide(_req(lanes=["dspy"]))
    r = _rows(ledger)[0]
    assert r["record_id"] is None and r["run_ctx"] == {}
    assert isinstance(r["response_id"], str), "id 가 없는 옛 호출자도 처리 신원은 받는다"


def test_rewrite_appends_a_row_linked_to_its_parent(ledger, monkeypatch):
    seen = {}

    def fake_rewrite_impl(*, tool_name, spec, impl_name, impl_code, impl_rejected_why,
                          blob=None, program=None, raw_out=None):
        seen["program"] = program
        if raw_out is not None:
            raw_out["rewrite"] = [{"outputs": ["raw"], "cache_hit": False}]
        return {"wrote": True, "impl_name": "fixed!",
                "impl_code": "function fixed!(env) end", "params": {}, "calls": [],
                "surface": "sched", "reversible": False, "error": None,
                "rewrite_of_why": impl_rejected_why}

    monkeypatch.setattr(SY, "rewrite_impl", fake_rewrite_impl)
    out = svc.rewrite(svc.RewriteRequest(
        tool_name="T", spec="s", impl_name="bad", impl_code="function bad(env) end",
        impl_rejected_why="enact_threw:bad: boom", record_id="rid-2",
        parent_record_id="rid-1", attempt=2, trigger="threw", run_ctx={"seed": 3}))
    assert out["impl_name"] == "fixed!" and "raw_lm" not in out
    r = _rows(ledger)[0]
    assert (r["row_type"], r["record_id"], r["parent_record_id"], r["attempt"],
            r["trigger"]) == ("rewrite", "rid-2", "rid-1", 2, "threw")
    assert r["impl_code"] == "function fixed!(env) end"
    assert r["rejected_impl_code"] == "function bad(env) end"
    assert r["impl_rejected_why"] == "enact_threw:bad: boom"
    assert r["tool_name"] == "T"
    assert r["raw_lm"] == {"rewrite": [{"outputs": ["raw"], "cache_hit": False}]}
    assert r["run_ctx"] == {"seed": 3} and r["ledger_version"] == 2
    # controller R2: `/rewrite` 는 최상위에 response_id 를 싣고 record_id 를 되돌려준다.
    assert out["record_id"] == "rid-2"
    assert isinstance(out["response_id"], str) and r["response_id"] == out["response_id"]
    # 요청마다 새 프로그램: 서비스는 program 을 주입하지 않는다(rewrite_impl 이 새로 만든다).
    assert seen["program"] is None


def test_rewrite_with_the_ledger_switched_off_writes_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("SYNTH_RECORD_LOG", "0")
    monkeypatch.setattr(SY, "rewrite_impl",
                        lambda **kw: {"wrote": None, "error": "rewrite: X: y"})
    svc.rewrite(svc.RewriteRequest(impl_name="a", impl_code="b", impl_rejected_why="c"))
    assert list(tmp_path.iterdir()) == []


# =================================================================================================
# 추가 수락 조건 "Task 3, 조기 반환" — macro() 의 모든 경로가 행을 하나씩 남긴다
# =================================================================================================

def _parse_failure_lm():
    class _Boom(T._FCDummy):
        def __call__(self, *a, **kw):
            raise AdapterParseError(adapter_name="ChatAdapter", signature=svc.SelectTool,
                                    lm_response="",
                                    message="The LM returned an empty or null response.")
    dspy.configure(lm=_Boom([]), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()


def _outage_lm():
    class _Down(T._FCDummy):
        def __call__(self, *a, **kw):
            raise LMError("provider is down")
    dspy.configure(lm=_Down([]), adapter=svc.build_adapter())
    svc._state["program"] = None
    svc._load_program()


def _fake_synthesis(monkeypatch, **fields):
    """합성 단계의 네 결말을 유료 0건으로 만든다. 모양은 진짜 blank 기록에서 시작한다."""
    def fake_run_synthesis(expressible, kind=None, state="", tools=None, ledger=None,
                           programs=None, blob=None, raw_out=None):
        assert programs is None, "서비스가 프로그램을 주입하면 요청 간 공유될 수 있다"
        if raw_out is not None:
            raw_out.update({"observe": [{"outputs": ["o"]}], "design": [], "compose": []})
        rec = SY.blank_synthesis_record(kind=kind, expressible=None)
        rec.update(fields)
        return rec
    monkeypatch.setattr(svc, "run_synthesis", fake_run_synthesis)


# (라벨, 기대 decide_outcome, 준비 함수(monkeypatch) , 요청 kwargs, raw_lm 이 비는가)
_SCENARIOS = [
    ("tool_calls: [] -> no_call", "no_call_no_tool_call",
     lambda mp: T._install({"action": {"tool_calls": []}}, fc=False), {}, True),
    ("parse failure -> no_call", "no_call_parse_error",
     lambda mp: _parse_failure_lm(), {}, True),
    ("provider outage -> no_call", "no_call_lm_error",
     lambda mp: _outage_lm(), {}, True),
    ("empty menu -> no_tools", "no_tools",
     lambda mp: T._install(T._call(), fc=False), dict(agents=[], valid=["Replace"]), True),
    ("synthesis off", "synthesis_disabled",
     lambda mp: T._install(T._call(), fc=False), {}, False),
    ("agent-2 said expressible=True", "synthesis_not_fired",
     lambda mp: (T._install(T._call(), fc=False),
                 _fake_synthesis(mp, enabled=True, refused=False, expressible=True)), {}, False),
    ("G1 refusal", "synthesis_refused",
     lambda mp: (T._install(T._call(), fc=False),
                 _fake_synthesis(mp, enabled=True, refused="no_compose_interface")), {}, False),
    ("stage raised", "synthesis_failed",
     lambda mp: (T._install(T._call(), fc=False),
                 _fake_synthesis(mp, enabled=True, refused=False,
                                 error="observe: LMError: down")), {}, False),
    ("agent-3 ran", "synthesis_ran",
     lambda mp: (T._install(T._call(), fc=False),
                 _fake_synthesis(mp, enabled=True, refused=False, expressible=False,
                                 ran=True, synthesis_event=True, tool_minted=True)), {}, False),
]


@pytest.mark.parametrize("label,outcome,prep,kw,raw_empty", _SCENARIOS,
                         ids=[s[0] for s in _SCENARIOS])
def test_every_macro_path_writes_exactly_one_decide_row(label, outcome, prep, kw, raw_empty,
                                                        ledger, monkeypatch):
    prep(monkeypatch)
    out = svc.decide(_req(lanes=["dspy"], record_id="rid-%s" % outcome, **kw))
    rows = _rows(ledger)
    assert len(rows) == 1, label
    r = rows[0]
    assert r["row_type"] == "decide" and r["decide_outcome"] == outcome, (label, r["decide_outcome"])
    assert r["decide_outcome"] in svc.DECIDE_OUTCOMES
    assert r["record_id"] == "rid-%s" % outcome
    # 전선에도 신원이 돌아온다 — 조기 반환에서도(줄리아가 행과 조인할 유일한 키).
    syn = out["dspy"]["synthesis"]
    assert syn["record_id"] == r["record_id"] and syn["response_id"] == r["response_id"]
    # 조기 반환에는 요청 국소 history 가 없다(합성 프로그램을 안 만들었다) — 빈 dict 이다.
    assert (r["raw_lm"] == {}) is raw_empty, (label, r["raw_lm"])


def test_error_carrying_paths_name_the_error_on_the_row(ledger):
    _outage_lm()
    svc.decide(_req(lanes=["dspy"]))
    _parse_failure_lm()
    svc.decide(_req(lanes=["dspy"]))
    a, b = _rows(ledger)
    assert "LMError" in a["decide_error"]
    assert "AdapterParseError" in b["decide_error"]


def test_an_exception_escaping_macro_still_writes_a_row_and_reraises(fake_lm, ledger,
                                                                     monkeypatch):
    """`tool_choice()` 의 오설정 검증은 `macro()` 밖으로 던진다(HTTP 500) — 그 요청도 행을 남긴다."""
    monkeypatch.setenv(svc.TOOL_CHOICE_ENV, "bogus")
    with pytest.raises(ValueError):
        svc.decide(_req(lanes=["dspy"], record_id="rid-x"))
    (r,) = _rows(ledger)
    assert (r["row_type"], r["decide_outcome"], r["record_id"]) == ("decide", "raised", "rid-x")
    assert "ValueError" in r["decide_error"]
    assert isinstance(r["response_id"], str)
    assert r["raw_lm"] == {}


def test_the_outcome_vocabulary_is_exactly_the_paths_exercised_here():
    """상수에 죽은 값이 없고, 시험이 모르는 경로도 없다(`raised` 는 위 별도 시험)."""
    assert set(svc.DECIDE_OUTCOMES) == {s[1] for s in _SCENARIOS} | {"raised"}
    assert len(svc.DECIDE_OUTCOMES) == len(set(svc.DECIDE_OUTCOMES))


def test_a_non_dspy_lane_writes_no_row_and_calls_no_lm(fake_lm, ledger):
    """canonical/surrogate 의 LLM 0건 계약: `macro()` 에 안 들어가므로 원장도 안 건드린다."""
    before = svc._state["calls"]
    out = svc.decide(_req(lanes=["surrogate"], record_id="rid-s"))
    assert "dspy" not in out
    assert svc._state["calls"] == before
    assert not ledger.exists()
    svc.decide(_req(lanes=[], record_id="rid-none"))
    assert not ledger.exists()


# =================================================================================================
# 동시 중복 요청 — 같은 record_id 의 HTTP 재전송 (controller R2)
# =================================================================================================

def test_concurrent_duplicates_keep_every_row_with_distinct_response_ids(ledger):
    n = 4
    T._install(*[T._call("deliver_battery", macro="SwapBattery")] * n, fc=False)
    got, errs = [], []

    def go():
        try:
            out = svc.decide(_req(lanes=["dspy"], record_id="dup"))
            got.append(out["dspy"]["synthesis"]["response_id"])
        except Exception as e:  # noqa: BLE001
            errs.append(e)

    ts = [threading.Thread(target=go) for _ in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errs, errs
    rows = _rows(ledger)
    assert len(rows) == n, "중복도 전부 보존한다(dedup 아님)"
    assert {r["record_id"] for r in rows} == {"dup"}
    assert len({r["response_id"] for r in rows}) == n
    # 각 호출자가 받은 response_id 가 원장의 한 행과 정확히 맞는다.
    assert sorted(got) == sorted(r["response_id"] for r in rows)


# =================================================================================================
# 원장 신뢰성 (controller R4) — 잠금 · 실패 카운터 · /health
# =================================================================================================

def test_concurrent_large_appends_keep_every_line_intact(tmp_path):
    p = tmp_path / "big.jsonl"
    pad = "x" * 100_000

    def go(t):
        for i in range(25):
            SY.append_synthesis_record({"t": t, "i": i, "pad": pad}, str(p))

    ts = [threading.Thread(target=go, args=(t,)) for t in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    lines = open(p, encoding="utf-8").read().split("\n")
    assert lines[-1] == ""
    rows = [json.loads(l) for l in lines[:-1]]       # 한 줄이라도 섞였으면 여기서 죽는다
    assert len(rows) == 200
    assert sorted((r["t"], r["i"]) for r in rows) == [(t, i) for t in range(8) for i in range(25)]


def test_an_append_failure_counts_warns_and_never_raises(tmp_path, capsys):
    before = SY.ledger_append_failures()
    assert SY.append_synthesis_record({"a": 1}, str(tmp_path)) is None   # 디렉터리 = 쓸 수 없다
    assert SY.ledger_append_failures() == before + 1
    err = capsys.readouterr().err.strip().splitlines()
    warn = json.loads(err[-1])
    assert warn["event"] == "ledger_append_failed" and warn["path"] == str(tmp_path)
    assert warn["failures"] == before + 1


def test_a_switched_off_sink_is_not_a_failure(monkeypatch):
    monkeypatch.setenv("SYNTH_RECORD_LOG", "0")
    before = SY.ledger_append_failures()
    assert SY.append_synthesis_record({"a": 1}) is None
    assert SY.ledger_append_failures() == before


def test_an_append_failure_during_decide_does_not_kill_the_decision(fake_lm, tmp_path,
                                                                    monkeypatch):
    monkeypatch.setenv("SYNTH_RECORD_LOG", str(tmp_path))      # 디렉터리 → open 이 던진다
    monkeypatch.delenv("TOOL_SYNTHESIS", raising=False)
    before = SY.ledger_append_failures()
    out = svc.decide(_req(lanes=["dspy"], record_id="rid-f"))
    assert out["dspy"]["chosen"] == "SwapBattery"
    assert out["dspy"]["synthesis"]["record_id"] == "rid-f"
    assert SY.ledger_append_failures() == before + 1


def test_health_exposes_the_append_failure_counter(tmp_path):
    SY.append_synthesis_record({"a": 1}, str(tmp_path))
    h = svc.health()
    assert h["ledger_append_failures"] == SY.ledger_append_failures() >= 1
