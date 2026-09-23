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
