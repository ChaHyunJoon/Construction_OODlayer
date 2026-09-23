"""원장 행의 신원과 원시 응답. 유료 0건 — DummyLM 과 가짜 프로그램만 쓴다.

🔴 왜 `lm.history[-1]` 이 아닌가: 서비스는 FastAPI 동기 핸들러라 스레드풀에서 요청을 동시에
처리한다(스윕 W=12). 전역 history 의 끝은 남의 요청일 수 있다. 호출마다 새로 만든 프로그램의
`prog.history` 는 그 요청의 것만 담는다 — 아래 첫 시험이 4-스레드로 그것을 잰다.

🔴 브리프의 동시성 시험은 "네 응답이 서로 다르다" 만 쟀다. global-constraints.md 의 추가 수락
조건(Task 1·2, 원시 응답)은 "각 응답의 입력 태그가 해당 요청과 일치함" 까지 요구한다 — 그래서
아래는 DummyLM 을 **dict-모드**(프롬프트에 들어 있는 태그 문자열로 답을 고른다)로 써서 "네 개가
서로 다르다" 를 넘어 "이 스레드가 본 응답이 **자기** 태그의 것이다" 를 내용으로 검증한다.
list-모드는 분배 순서가 스레드 스케줄에 달려 있어 그것까지는 못 잰다.
"""
import json
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synthesize as SY  # noqa: E402  (numpy/sklearn-before-dspy 계약은 synthesize 가 진다)
import dspy  # noqa: E402
from dspy.utils.dummies import DummyLM  # noqa: E402


class _S(dspy.Signature):
    q: str = dspy.InputField()
    a: str = dspy.OutputField()


def test_lm_raw_is_request_local_under_threads():
    tags = ["t0", "t1", "t2", "t3"]
    lm = DummyLM({tag: {"reasoning": "r", "a": "ans-%s" % tag} for tag in tags})
    got = {}

    def go(tag):
        with dspy.context(lm=lm):
            p = dspy.ChainOfThought(_S)
            p(q=tag)
            got[tag] = SY.lm_raw(p)

    ts = [threading.Thread(target=go, args=(tag,)) for tag in tags]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sorted(got) == tags
    assert all(len(v) == 1 for v in got.values()), got
    # 네 스레드가 네 개의 **서로 다른** 응답을 봤다 — 남의 것이 섞이지 않았다.
    assert len({json.dumps(v[0]["outputs"]) for v in got.values()}) == 4
    # 그리고 각자 자기 태그의 응답을 봤다 — "네 개가 다르다" 를 넘어 "누가 누구인가" 까지.
    for tag, v in got.items():
        blob = json.dumps(v[0]["outputs"])
        assert ("ans-%s" % tag) in blob, (tag, blob)


def test_lm_raw_carries_cache_hit_and_never_raises():
    class _Resp:
        cache_hit = True

    class _P:
        history = [{"outputs": ["x"], "response": _Resp(), "response_model": "m",
                    "usage": {"t": 1}, "cost": None, "timestamp": "ts", "uuid": "u"}]

    raw = SY.lm_raw(_P())
    assert raw == [{"outputs": ["x"], "model": "m", "usage": {"t": 1}, "cost": None,
                    "cache_hit": True, "timestamp": "ts", "uuid": "u"}]
    # history 가 없는 가짜 프로그램(함수)은 빈 목록이다 — 예외가 아니다.
    assert SY.lm_raw(lambda **kw: None) == []

    class _Bad:
        history = [object()]           # dict 가 아니다 → .get 이 AttributeError

    bad = SY.lm_raw(_Bad())
    assert len(bad) == 1 and bad[0]["error"].startswith("lm_raw: AttributeError")


def test_lm_raw_with_start_returns_only_entries_added_during_this_call():
    """R2 보완(global-constraints.md, Task 1·2): 프로그램이 요청 간 재사용되면(주입된 프로그램)
    `prog.history` 는 이전 요청의 항목도 담을 수 있다. 호출 전 `len(prog.history)` 를 찍고
    `start=` 로 그 뒤만 슬라이스한다 — `start` 를 생략하면(기본 0) 기존 호출자와 하위호환으로
    전체를 돌려준다."""
    class _Grown:
        def __init__(self, pre):
            self.history = list(pre)

    pre = [{"outputs": ["old-1"], "response": None},
           {"outputs": ["old-2"], "response": None}]
    p = _Grown(pre)
    n0 = len(p.history)
    p.history.append({"outputs": ["new-1"], "response": None})
    p.history.append({"outputs": ["new-2"], "response": None})

    got = SY.lm_raw(p, start=n0)
    assert [g["outputs"] for g in got] == [["new-1"], ["new-2"]]
    assert len(SY.lm_raw(p)) == 4  # start 생략 = 전체


def test_stamp_record_does_not_mutate_the_wire_record():
    rec = {"tool_minted": True, "impl_code": "function a!(env) end"}
    row = SY.stamp_record(rec, row_type="rewrite", record_id="r2", response_id="resp9",
                          parent_record_id="r1", attempt=2, trigger="threw",
                          run_ctx={"seed": 3}, code_fingerprint="fp")
    assert rec == {"tool_minted": True, "impl_code": "function a!(env) end"}
    assert row["impl_code"] == rec["impl_code"]
    for k, v in {"ledger_version": 2, "row_type": "rewrite", "record_id": "r2",
                 "response_id": "resp9",
                 "parent_record_id": "r1", "attempt": 2, "trigger": "threw",
                 "run_ctx": {"seed": 3}, "code_fingerprint": "fp"}.items():
        assert row[k] == v, k
    assert row["logged_at"].endswith("+00:00")


def test_stamp_record_response_id_defaults_to_none():
    """response_id 는 서버(Task 3)가 발급한다 — 여기서는 자리만 준다(controller R2)."""
    row = SY.stamp_record({}, row_type="decide", record_id="r1")
    assert row["response_id"] is None


def test_stamp_record_run_ctx_is_a_copy_and_defaults_to_empty():
    ctx = {"seed": 1}
    row = SY.stamp_record({}, row_type="decide", record_id=None, run_ctx=ctx)
    ctx["seed"] = 99
    assert row["run_ctx"] == {"seed": 1}
    assert SY.stamp_record({}, row_type="decide", record_id=None)["run_ctx"] == {}


def test_the_blank_record_declares_record_id_and_response_id_as_unmeasured():
    rec = SY.blank_synthesis_record(kind="zone")
    assert "record_id" in rec and rec["record_id"] is None
    assert "response_id" in rec and rec["response_id"] is None


# ==========================================================================================
# Task 2 -- run_synthesis / rewrite_impl 이 원시 응답을 raw_out 으로 돌려준다
# ==========================================================================================
# 🔴 브리프의 스켈레톤은 `_HistProg`/`_RewriteProg`/`_BoomProg` 의 `history` 를 **호출과
#    무관하게 고정된 한 항목**으로 뒀다. global-constraints.md 의 추가 수락 조건(Task 1·2,
#    원시 응답)은 그보다 강하다: "프로그램 재사용을 주입한 시험은 호출 전후 history 차이를
#    수집" 해야 한다. 그래서 아래 가짜들은 **호출 전 이미 뭔가를 들고 있고(다른 시점/다른
#    요청의 것일 수 있다), 호출 중에 새 항목이 붙는다** -- raw_out 은 그 **새로 붙은 것만**
#    담아야 한다(그래야 F5 의 "남의 응답이 섞인다" 문제가 run_synthesis/rewrite_impl 수준에서도
#    재발하지 않는다). 이 재설계가 브리프의 원래 어서션(예: 고정 1항목을 그대로 돌려받는다)을
#    대체한다 -- global-constraints.md 의 규칙대로 예시보다 추가 수락 조건을 따른다.


class _HistProg:
    """history 를 미리 가진 가짜 프로그램(다른 요청의 잔재를 흉내낸다). 합성이 꺼져 있으면
    불리지 않는다 -- 이 판에서는 그 잔재가 **하나도 안 자란다.**"""
    def __init__(self, hist):
        self.history = hist

    def __call__(self, **kw):
        raise AssertionError("synthesis is disabled; the program must not be called")


def test_run_synthesis_disabled_path_does_not_leak_pre_existing_history(monkeypatch):
    monkeypatch.delenv("TOOL_SYNTHESIS", raising=False)
    progs = {"observe": _HistProg([{"outputs": ["stale-from-another-request"], "response": None}]),
             "design": _HistProg([]), "compose": _HistProg([])}
    raw = {}
    rec = SY.run_synthesis(expressible=False, kind="zone", state="s",
                           programs=progs, raw_out=raw)
    assert rec["tool_minted"] == "disabled"
    assert sorted(raw) == ["compose", "design", "observe"]
    # 아무 프로그램도 안 불렸다 -- raw_out 은 이번 호출의 성장분(0)만 담아 셋 다 빈 목록이다.
    assert raw == {"observe": [], "design": [], "compose": []}
    assert "raw_lm" not in rec            # 🔴 전선 기록의 모양은 안 바뀐다


def test_run_synthesis_hands_back_only_this_calls_growth(monkeypatch):
    """controller R2: 프로그램이 호출 전 이미 채워져 있었고 호출 중 자랐다 -- raw_out 은
    **자란 부분만** 담는다. `synthesize_multi` 자체를 가짜로 바꿔 dspy 파이프라인 없이
    "이 호출이 history 를 늘렸다" 는 모양만 재현한다."""
    class _Growing:
        def __init__(self, pre):
            self.history = list(pre)

    progs = {"observe": _Growing([{"outputs": ["stale"], "response": None}]),
             "design": _Growing([]), "compose": _Growing([])}

    def fake_synthesize_multi(*, state, tools, kind, ledger, programs, blob):
        for p in programs.values():
            p.history.append({"outputs": ["fresh"], "response": None})
        return {"tool_minted": "ok"}

    monkeypatch.setattr(SY, "synthesize_multi", fake_synthesize_multi)
    raw = {}
    rec = SY.run_synthesis(expressible=False, kind="zone", state="s",
                           programs=progs, raw_out=raw)
    assert rec == {"tool_minted": "ok"}
    for k in ("observe", "design", "compose"):
        assert raw[k] == [{"outputs": ["fresh"], "model": None, "usage": None, "cost": None,
                           "cache_hit": None, "timestamp": None, "uuid": None}], (k, raw[k])
    # "stale" 은 설계상 어느 키에도 새지 않는다.
    assert not any("stale" in json.dumps(v) for v in raw.values())


def test_run_synthesis_without_raw_out_is_unchanged(monkeypatch):
    monkeypatch.delenv("TOOL_SYNTHESIS", raising=False)
    rec = SY.run_synthesis(expressible=False, kind="zone", state="s")
    assert rec["tool_minted"] == "disabled" and "raw_lm" not in rec


class _FixPred:
    wrote = True
    impl_name = "fixed!"
    impl_code = "function fixed!(env)\n    return (status = :ok,)\nend"
    params = "{}"
    calls = [{"primitive": "fixed!", "args": {}}]
    surface = "sched"
    reversible = False


class _RewriteProg:
    """history 가 호출 전 이미 채워져 있고(다른 시점의 잔재), 호출 중 새 항목이 하나 붙는다 --
    rewrite_impl 은 **새로 붙은 것만** raw_out 에 담아야 한다(controller R2)."""
    def __init__(self):
        self.history = [{"outputs": ["stale rewrite text"], "response": None}]

    def __call__(self, **kw):
        self.history.append({"outputs": ["raw rewrite text"], "response": None})
        return _FixPred()


class _BoomProg:
    def __init__(self):
        self.history = [{"outputs": ["stale"], "response": None}]

    def __call__(self, **kw):
        self.history.append({"outputs": ["partial"], "response": None})
        raise RuntimeError("provider died")


def test_rewrite_impl_hands_back_only_this_calls_raw_response():
    raw = {}
    out = SY.rewrite_impl(tool_name="t", spec="s", impl_name="bad", impl_code="x",
                          impl_rejected_why="why", program=_RewriteProg(), raw_out=raw)
    assert out["wrote"] is True and "raw_lm" not in out
    assert raw["rewrite"] == [{"outputs": ["raw rewrite text"], "model": None, "usage": None,
                               "cost": None, "cache_hit": None, "timestamp": None, "uuid": None}]


def test_rewrite_impl_keeps_only_the_new_raw_response_even_when_the_call_raises():
    raw = {}
    out = SY.rewrite_impl(tool_name="t", spec="s", impl_name="bad", impl_code="x",
                          impl_rejected_why="why", program=_BoomProg(), raw_out=raw)
    assert out["error"].startswith("rewrite: RuntimeError")
    assert raw["rewrite"] == [{"outputs": ["partial"], "model": None, "usage": None,
                               "cost": None, "cache_hit": None, "timestamp": None, "uuid": None}]


def test_rewrite_impl_without_raw_out_is_unchanged():
    out = SY.rewrite_impl(tool_name="t", spec="s", impl_name="bad", impl_code="x",
                          impl_rejected_why="why", program=_RewriteProg())
    assert out["wrote"] is True and "raw_lm" not in out
