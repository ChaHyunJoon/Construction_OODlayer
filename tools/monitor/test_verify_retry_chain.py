"""tools/monitor/verify_retry_chain.py 의 계약 시험 (Task 6, 2026-09-22).

라이브 서비스도 줄리아도 안 쓴다 — 스트림·원장·/health 는 전부 이 파일이 tmp_path 에 직접
쓰는 고정문이다. 🔴 고정문의 **모양은 상상이 아니라 생산자에서** 온다: 각 빌더 위에 그 모양을
만드는 함수 이름을 적었고, 원장 행의 신원은 생산 함수 `synthesize.stamp_record` 를 **직접**
불러 찍는다(두 벌을 만들지 않는다). 줄리아 쪽 키 집합은 소스 결속 시험 두 개가
(`_open_attempt!` 의 칸 키 · `SYNTH_LANE_KEYS`) 빌더와 대조한다 — 생산자가 키를 바꾸면 여기가
빨개진다.

🔴 이 파일은 `results/synth_lane_records.jsonl` 을 만들지 않는다: 모든 원장은 tmp_path 에
있고, 기본 경로 해석 시험은 경로 **문자열**만 본다(루트 `conftest.py` 가 `SYNTH_RECORD_LOG=0`).

실행: (repo 루트에서) `.venv/bin/python -m pytest tools/monitor/test_verify_retry_chain.py -q`
"""
import copy
import json
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SVC = os.path.join(REPO, "src", "respec", "llm_service")
for _p in (HERE, SVC):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import verify_retry_chain as vrc  # noqa: E402
import synthesize as SY  # noqa: E402  -- 원장 신원의 생산자(stamp_record)를 그대로 쓴다

STREAM_NAME = "tractor__router_zone_z3.jsonl"

# render_demo.jl `set_run_ctx!(...)` 호출의 18키(task-4 보고 표와 같은 순서).
RUN_CTX = {
    "run_id": "retrygate_B", "campaign_id": "", "stream": STREAM_NAME,
    "case": "router_zone", "event": "none", "zone": True, "model": "tractor",
    "lane": "router", "policy": "canonical", "router": "1", "seed": 1, "zone_seed": 3,
    "synth_fixture": "", "code_rev": "ac4a550a" + "0" * 32, "code_dirty_digest": "",
    "config_digest": "0123456789abcdef",
}

BODY1 = "function ZoneFix!(env)\n    return (; status = :ok)\nend\n"
BODY2 = "function ZoneFix!(env)\n    return (; status = :fixed)\nend\n"
PARAMS1 = {"margin": {"type": "number"}}
CALLS1 = [{"primitive": "ZoneFix!", "args": {}}]

DID, DRESP = "a" * 24, "d" * 32          # /decide: 줄리아 발급 24hex · 서버 uuid4().hex
RID, RRESP = "b" * 24, "e" * 32          # /rewrite


# ---- 원시 LM 항목 — synthesize.lm_raw 의 항목 모양 -------------------------------------------
def _lm(cache_hit):
    return {"outputs": ["..."], "model": "openai/gpt-5", "usage": {"prompt_tokens": 10},
            "cost": 0.01, "cache_hit": cache_hit, "timestamp": "2026-09-22T00:00:00",
            "uuid": "u"}


# ---- /decide 원장 행 — dspy_service._append_decide_row: dict(synthesis, raw_lm, decide_outcome,
#      decide_error) → synthesize.stamp_record(row_type="decide", attempt=1, trigger="first") ------
def _decide_row(rid=DID, resp=DRESP, *, body=BODY1, params=PARAMS1, calls=CALLS1, wrote=True,
                error=None, run_ctx=RUN_CTX, raw=None, outcome="synthesis_ran", **over):
    # synthesis 기록: synthesize._blank 의 키 + 정상 경로가 채우는 _SPEC_FIELDS/_BODY_FIELDS.
    syn = {"tool_minted": True, "synthesis_event": True, "ran": True, "enabled": True,
           "refused": False, "kind": "unknown:zone", "expressible": False, "K": 1,
           "error": error, "reason": "new canon", "needs": "",
           "tool_name": "ZoneFix", "mechanism": "clear the zone", "params": params,
           "impl_name": "ZoneFix!", "impl_code": body, "surface": "sched",
           "reversible": False, "wrote": wrote, "calls": calls, "body_names": ["ZoneFix!"],
           # 전선의 두 id — dspy_service.macro() 가 synthesis 에 싣는다.
           "record_id": rid, "response_id": resp}
    raw_lm = raw if raw is not None else {"observe": [_lm(False)], "design": [_lm(False)],
                                          "compose": [_lm(False)]}
    row = SY.stamp_record(dict(syn, raw_lm=raw_lm, decide_outcome=outcome, decide_error=None),
                          row_type="decide", record_id=rid, response_id=resp,
                          attempt=1, trigger="first", run_ctx=run_ctx,
                          code_fingerprint="fp")
    row.update(over)
    return row


# ---- /rewrite 원장 행 — dspy_service.rewrite(): dict(rewrite_impl 의 out, raw_lm, tool_name,
#      rejected_impl_code, impl_rejected_why) → stamp_record(row_type="rewrite", parent_record_id,
#      attempt=req.attempt, trigger=req.trigger) --------------------------------------------------
def _rewrite_row(rid=RID, resp=RRESP, *, parent=DID, body=BODY2, params=PARAMS1, calls=CALLS1,
                 wrote=True, error=None, why="threw: boom", trigger="threw", attempt=2,
                 run_ctx=RUN_CTX, raw=None, **over):
    out = {"wrote": wrote, "impl_name": "ZoneFix!", "impl_code": body, "params": params,
           "calls": calls, "surface": "sched", "reversible": False, "error": error,
           "rewrite_of_why": why, "record_id": rid, "response_id": resp}
    raw_lm = raw if raw is not None else {"rewrite": [_lm(False)]}
    row = SY.stamp_record(dict(out, raw_lm=raw_lm, tool_name="ZoneFix",
                               rejected_impl_code=BODY1, impl_rejected_why=why),
                          row_type="rewrite", record_id=rid, response_id=resp,
                          parent_record_id=parent, attempt=attempt, trigger=trigger,
                          run_ctx=run_ctx, code_fingerprint="fp")
    row.update(over)
    return row


# ---- 결정 행의 dspy 칸 — policy.jl policy_entry(available 분기) + _synth_view(SYNTH_LANE_KEYS) --
def _dspy_entry(rid=DID, resp=DRESP, *, body=BODY1, params=PARAMS1, calls=CALLS1, wrote=True):
    return {"chosen": "SynthesizeTool", "ranking": ["SynthesizeTool"], "margin": None,
            "rationale": "", "scores": None, "unsupported": [], "label": "dspy:LLM",
            "available": True,
            # _synth_view: SYNTH_LANE_KEYS 전부(ran→synthesis_ran, error→synthesis_error)
            "tool_minted": True, "synthesis_event": True, "synthesis_ran": True,
            "synthesis_error": None, "refused": False, "tool_name": "ZoneFix",
            "mechanism": "clear the zone", "body_names": ["ZoneFix!"], "params": params,
            "calls": calls, "impl_name": "ZoneFix!", "impl_code": body, "surface": "sched",
            "reversible": False, "wrote": wrote, "record_id": rid, "response_id": resp}


def _canon_pols():
    # policy.jl decide_all: canonical·noop·oracle 는 줄리아가 늘 계산한다(서비스 0건).
    return {"canonical": {"chosen": "NOOP", "ranking": ["NOOP"], "margin": None,
                          "rationale": "rule lookup (severity threshold)",
                          "label": "canonical", "available": True},
            "noop": {"chosen": "NOOP", "ranking": ["NOOP"], "margin": None,
                     "rationale": "no-adapt floor (never intervenes)", "label": "no-adapt",
                     "available": True},
            "oracle": {"chosen": "NOOP", "ranking": ["NOOP"], "margin": None,
                       "rationale": "reference action a*", "label": "oracle",
                       "available": True}}


# ---- 되먹임 칸 — enact.jl _open_attempt!(19키) + _rewrite_once 의 roundtrip="ok" 채움 ----------
def _attempt(rid=RID, resp=RRESP, *, parent=(DID, DRESP), roundtrip="ok", trigger="threw",
             why="threw: boom", body=BODY2, params=PARAMS1, calls=CALLS1, wrote=True,
             service_error=None):
    ok = roundtrip == "ok"
    return {"attempt": 2, "trigger": trigger, "why": why, "prev_impl_name": "ZoneFix!",
            "prev_steps": ["ZoneFix!:threw(boom)"], "record_id": rid,
            "parent_record_id": parent[0], "parent_response_id": parent[1],
            "response_id": resp if ok else None, "roundtrip": roundtrip,
            "wrote": wrote if ok else None, "service_error": service_error if ok else None,
            "impl_name": "ZoneFix!" if ok else None, "impl_code": body if ok else None,
            "params": params if ok else None, "calls": calls if ok else None,
            "install_why": None, "steps": ["ZoneFix!:success"] if ok else None,
            "steps_ref": None}


# ---- 결정 행 — CB.monitor_record_respec!(at, input, candidates, chosen, verdict);
#      input 은 policy.jl record_decision! 의 dict. attempts 는 enact.jl 이 제자리에 붙인다 ------
def _decision(dspy=True, attempts=None, *, entry=None, fixture=None):
    pols = _canon_pols()
    router = {"routing_kind": "unknown:zone", "enacted": "dspy" if dspy else "canonical"}
    if dspy:
        pols["dspy"] = entry if entry is not None else _dspy_entry()
    if fixture is not None:
        router["synth_fixture"] = fixture
    d = {"at": 200,
         "input": {"event": "ZONE", "target": "A1", "detail": "", "nl": "",
                   "policy": "dspy:LLM" if dspy else "canonical",
                   "rule_macro": "NOOP", "llm_macro": "SynthesizeTool" if dspy else None,
                   "policies": pols, "enacted": "dspy" if dspy else "canonical",
                   "router": router, "narrative": "", "rationale": "",
                   "agrees_with_rule": None},
         "candidates": [], "chosen": "SynthesizeTool A1", "verdict": "ADMITTED"}
    if attempts is not None:
        d["attempts"] = attempts
    return d


# ---- 스트림 한 줄 — src/monitor/monitor.jl monitor_emit! 의 frame dict ---------------------------
def _frame(history, t=1000, *, with_history=True, with_respec=True):
    f = {"t": t, "sim_t": t * 0.05, "now": t * 0.05, "n_closed": 250, "n_active": 3,
         "robots": [], "assemblies": [], "schedule": [], "ood": None,
         "recovery": [], "handoffs": []}
    if with_respec:
        f["respec"] = history[-1] if history else None
    if with_history:
        f["respec_history"] = history
    return f


def _write_jsonl(path, objs, *, tail=""):
    with open(path, "w", encoding="utf-8") as fh:
        for o in objs:
            fh.write(json.dumps(o, ensure_ascii=False) + "\n")
        fh.write(tail)
    return str(path)


def _run(tmp_path, frames, rows, *args, health=None, stream_tail="", ledger_tail=""):
    s = _write_jsonl(tmp_path / STREAM_NAME, frames, tail=stream_tail)
    argv = [s]
    if rows is not None:
        argv.append(_write_jsonl(tmp_path / "ledger.jsonl", rows, tail=ledger_tail))
    if health is not None:
        hp = tmp_path / "health.json"
        hp.write_text(json.dumps(health), encoding="utf-8")
        argv += ["--health-json", str(hp)]
    return vrc.run(argv + list(args))


def _chain():
    """정상 사슬 한 벌: dspy 결정 1 + threw 되먹임 1 (roundtrip ok)."""
    frames = [_frame([_decision(attempts=[_attempt()])])]
    rows = [_decide_row(), _rewrite_row()]
    return frames, rows


def _has(summary, prefix):
    return any(p.startswith(prefix) for p in summary["problems"])


# =============================================================================================
# 정상 사슬
# =============================================================================================
def test_normal_chain_joins_decision_and_attempt(tmp_path):
    code, s = _run(tmp_path, *_chain())
    assert code == 0, s["problems"]
    assert s["verdict"] == "ok"
    for k, v in {"decisions": 1, "decide_joined": 1, "attempts": 1, "roundtrip_ok": 1,
                 "attempt_joined": 1, "parent_ok": 1, "code_equal": 1,
                 "duplicates": 0}.items():
        assert s[k] == v, k
    assert s["problems"] == []
    assert s["history_source"] == "respec_history"
    # 브리프가 요구한 요약 키 전부 + R9·R10
    for k in ("decisions", "decide_joined", "attempts", "roundtrip_ok", "attempt_joined",
              "parent_ok", "code_equal", "duplicates", "cache_hits", "cache_misses",
              "cache_unknown", "problems", "orphans", "ledger_append_failures", "ledger_path"):
        assert k in s, k


# =============================================================================================
# 누락된 decide / rewrite
# =============================================================================================
def test_missing_decide_row_fails(tmp_path):
    frames, rows = _chain()
    code, s = _run(tmp_path, frames, rows[1:])
    assert code == 1
    assert s["decide_joined"] == 0 and _has(s, "decide_row_missing")
    assert _has(s, "decide_joined_ne_decisions")
    # 부모도 원장에 없다
    assert _has(s, "parent_row_missing")


def test_missing_rewrite_row_fails(tmp_path):
    frames, rows = _chain()
    code, s = _run(tmp_path, frames, rows[:1])
    assert code == 1
    assert s["attempt_joined"] == 0 and s["roundtrip_ok"] == 1
    assert _has(s, "rewrite_row_missing") and _has(s, "attempt_joined_ne_roundtrip_ok")


# =============================================================================================
# 잘못된 parent / row_type / attempt / trigger / run_ctx
# =============================================================================================
def test_wrong_parent_in_ledger_row_fails(tmp_path):
    frames, _ = _chain()
    rows = [_decide_row(), _rewrite_row(parent="f" * 24)]
    code, s = _run(tmp_path, frames, rows)
    assert code == 1 and _has(s, "rewrite_row_mismatch") and s["attempt_joined"] == 0


def test_wrong_parent_in_stream_attempt_fails(tmp_path):
    # 칸의 부모가 이 결정이 받은 /decide 응답이 아니다(다른 response_id).
    frames = [_frame([_decision(attempts=[_attempt(parent=(DID, "0" * 32))])])]
    rows = [_decide_row(), _rewrite_row()]
    code, s = _run(tmp_path, frames, rows)
    assert code == 1 and _has(s, "parent_mismatch") and s["parent_ok"] == 0


def test_decision_key_joining_a_rewrite_row_is_wrong_row_type(tmp_path):
    frames, _ = _chain()
    bad = _rewrite_row(rid=DID, resp=DRESP)       # 결정이 받은 키인데 행은 rewrite
    code, s = _run(tmp_path, frames, [bad, _rewrite_row()])
    assert code == 1 and _has(s, "decide_row_mismatch") and s["decide_joined"] == 0
    assert any("row_type" in p for p in s["problems"])


def test_wrong_attempt_number_fails(tmp_path):
    frames, _ = _chain()
    code, s = _run(tmp_path, frames, [_decide_row(), _rewrite_row(attempt=3)])
    assert code == 1 and s["attempt_joined"] == 0
    assert any("attempt" in p for p in s["problems"] if p.startswith("rewrite_row_mismatch"))


def test_wrong_trigger_fails(tmp_path):
    frames, _ = _chain()
    code, s = _run(tmp_path, frames, [_decide_row(), _rewrite_row(trigger="noop")])
    assert code == 1 and s["attempt_joined"] == 0
    assert any("trigger" in p for p in s["problems"])


def test_decide_row_with_wrong_attempt_or_trigger_fails(tmp_path):
    frames, _ = _chain()
    for over in ({"attempt": 2}, {"trigger": "threw"}):
        code, s = _run(tmp_path, frames, [_decide_row(**over), _rewrite_row()])
        assert code == 1 and s["decide_joined"] == 0, over


@pytest.mark.parametrize("which,ctx,needle", [
    ("decide", dict(RUN_CTX, stream="tractor__other_z1.jsonl"), "run_ctx.stream"),
    ("rewrite", dict(RUN_CTX, seed=2), "different run_ctx"),
    ("decide", {}, "run_ctx is empty"),
])
def test_wrong_run_ctx_fails(tmp_path, which, ctx, needle):
    frames, _ = _chain()
    rows = ([_decide_row(run_ctx=ctx), _rewrite_row()] if which == "decide" else
            [_decide_row(), _rewrite_row(run_ctx=ctx)])
    code, s = _run(tmp_path, frames, rows)
    assert code == 1
    assert any(needle in p for p in s["problems"]), s["problems"]


# =============================================================================================
# 다른 body · params · calls (· wrote/error)
# =============================================================================================
@pytest.mark.parametrize("field,val", [
    ("impl_code", BODY2), ("params", {"margin": {"type": "string"}}),
    ("calls", [{"primitive": "ZoneFix!", "args": {"k": 1}}]), ("wrote", False),
    ("error", "compose: boom"),
])
def test_decide_row_with_different_content_fails(tmp_path, field, val):
    frames, _ = _chain()
    row = _decide_row()
    row[field] = val
    code, s = _run(tmp_path, frames, [row, _rewrite_row()])
    assert code == 1 and _has(s, "decide_content_mismatch")
    assert any(field in p for p in s["problems"])
    assert s["decide_joined"] == 1          # 신원 조인은 됐다 — 내용이 틀렸다


@pytest.mark.parametrize("field,val", [
    ("impl_code", BODY1), ("params", {}), ("calls", []), ("wrote", False),
    ("error", "rewrite: TimeoutError"), ("impl_rejected_why", "noop: other"),
])
def test_rewrite_row_with_different_content_fails(tmp_path, field, val):
    frames, _ = _chain()
    row = _rewrite_row()
    row[field] = val
    code, s = _run(tmp_path, frames, [_decide_row(), row])
    assert code == 1 and _has(s, "rewrite_content_mismatch")
    assert s["attempt_joined"] == 1
    assert s["code_equal"] == (0 if field == "impl_code" else 1)


def test_wrote_false_with_service_error_is_a_normal_joined_attempt(tmp_path):
    # F3: roundtrip=="ok" 는 wrote=false 여도 ok 다 — 사유는 service_error ↔ 원장 error.
    frames = [_frame([_decision(attempts=[_attempt(body=None, wrote=False,
                                                   service_error="rewrite: declined")])])]
    rows = [_decide_row(), _rewrite_row(body=None, wrote=False, error="rewrite: declined")]
    code, s = _run(tmp_path, frames, rows)
    assert code == 0, s["problems"]
    assert s["attempt_joined"] == 1 and s["code_equal"] == 1


# =============================================================================================
# 동일 요청에 서로 다른 응답 · 응답과 append 순서 역전 · 같은 복합 키의 충돌
# =============================================================================================
@pytest.mark.parametrize("received_first", [True, False])
def test_same_request_different_responses_joins_the_received_one(tmp_path, received_first):
    # HTTP 재전송(F7): 같은 record_id 로 서버가 두 번 처리했다. 줄리아가 받은 것은 DRESP 다.
    # append 순서가 받은 순서와 같든 반대든 결과가 같아야 한다(last-wins 금지).
    frames, _ = _chain()
    other = _decide_row(resp="c" * 32, body="function ZoneFix!(env)\n    nothing\nend\n")
    got = _decide_row()
    rows = ([got, other] if received_first else [other, got]) + [_rewrite_row()]
    code, s = _run(tmp_path, frames, rows)
    assert code == 0, s["problems"]
    assert s["decide_joined"] == 1 and s["duplicates"] == 1


def test_rewrite_row_appended_before_its_decide_row_still_joins(tmp_path):
    frames, rows = _chain()
    code, s = _run(tmp_path, frames, list(reversed(rows)))
    assert code == 0, s["problems"]


def test_same_composite_key_with_different_content_is_a_conflict(tmp_path):
    frames, _ = _chain()
    a, b = _decide_row(), _decide_row(body=BODY2)
    code, s = _run(tmp_path, frames, [a, b, _rewrite_row()])
    assert code == 1 and _has(s, "ledger_key_conflict")


# =============================================================================================
# transport failure — 원장 행 유/무 (Review Focus 4)
# =============================================================================================
def test_transport_failure_without_a_row_is_not_a_problem(tmp_path):
    att = _attempt(roundtrip="failed:HTTP.ConnectError: connection refused")
    frames = [_frame([_decision(attempts=[att])])]
    code, s = _run(tmp_path, frames, [_decide_row()])
    assert code == 0, s["problems"]
    assert s["attempts"] == 1 and s["roundtrip_ok"] == 0 and s["attempt_joined"] == 0
    assert s["roundtrip_failed"] == 1
    assert s["transport_failed"] == [{"record_id": RID, "ledger_response_ids": []}]


def test_transport_failure_with_a_row_is_reported_not_failed(tmp_path):
    # 서버는 처리했는데(행이 있다) 클라이언트가 응답을 못 받았다 — 실패가 아니라 보고.
    att = _attempt(roundtrip="failed:HTTP.TimeoutError: 60s")
    frames = [_frame([_decision(attempts=[att])])]
    code, s = _run(tmp_path, frames, [_decide_row(), _rewrite_row()])
    assert code == 0, s["problems"]
    assert s["transport_failed"] == [{"record_id": RID, "ledger_response_ids": [RRESP]}]
    assert any("never received" in w for w in s["warnings"])
    assert s["orphans"]["count"] == 1        # 받지 못한 응답의 행은 이 판의 orphan (R10)


def test_attempt_left_open_is_a_problem(tmp_path):
    att = _attempt()
    att["roundtrip"] = None
    code, s = _run(tmp_path, [_frame([_decision(attempts=[att])])], [_decide_row()])
    assert code == 1 and _has(s, "attempt_open")


def test_not_requested_attempt_is_counted_but_needs_no_row(tmp_path):
    att = _attempt(rid=None, roundtrip="not_requested", why="refused_world_changed: boom")
    code, s = _run(tmp_path, [_frame([_decision(attempts=[att])])], [_decide_row()])
    assert code == 0, s["problems"]
    assert s["attempts"] == 1 and s["not_requested"] == 1 and s["roundtrip_ok"] == 0


def test_not_requested_attempt_carrying_a_record_id_is_a_problem(tmp_path):
    att = _attempt(roundtrip="skipped_not_rewritable")
    code, s = _run(tmp_path, [_frame([_decision(attempts=[att])])], [_decide_row()])
    assert code == 1 and _has(s, "attempt_id_off_wire")


# =============================================================================================
# fixture parent 없음 — run_ctx 표식 + --allow-fixture-parent 둘 다 있어야
# =============================================================================================
FIX_CTX = dict(RUN_CTX, synth_fixture="tools/fixtures/probe_retry_boom.json", lane="canonical",
               router="0", run_id="retrygate_A")


def _fixture_run(ctx):
    # 게이트 A 모양: DEMO_ROUTER=0 DEMO_POLICY=canonical → policies 에 dspy 가 없고
    # synth_lane 은 픽스처(부모 id 없음). /decide 를 안 탔으므로 decide 행도 없다.
    att = _attempt(parent=(None, None))
    frames = [_frame([_decision(dspy=False, attempts=[att],
                                fixture={"path": "tools/fixtures/probe_retry_boom.json",
                                         "sha256_16": "0" * 16})])]
    return frames, [_rewrite_row(parent=None, run_ctx=ctx)]


def test_fixture_parent_missing_passes_with_marker_and_flag(tmp_path):
    code, s = _run(tmp_path, *_fixture_run(FIX_CTX), "--allow-fixture-parent",
                   "--require-attempts", "1")
    assert code == 0, s["problems"]
    assert s["decisions"] == 0 and s["attempts"] == 1 and s["attempt_joined"] == 1
    assert s["code_equal"] == 1 and s["parent_fixture_allowed"] == 1 and s["parent_ok"] == 0


def test_fixture_parent_missing_without_flag_fails(tmp_path):
    code, s = _run(tmp_path, *_fixture_run(FIX_CTX))
    assert code == 1 and _has(s, "parent_missing")


def test_fixture_flag_without_run_ctx_marker_fails(tmp_path):
    code, s = _run(tmp_path, *_fixture_run(RUN_CTX), "--allow-fixture-parent")
    assert code == 1 and _has(s, "parent_missing")


def test_parent_missing_on_a_dspy_decision_fails_even_with_the_flag(tmp_path):
    frames = [_frame([_decision(attempts=[_attempt(parent=(None, None))])])]
    rows = [_decide_row(), _rewrite_row(parent=None, run_ctx=FIX_CTX)]
    code, s = _run(tmp_path, frames, rows, "--allow-fixture-parent")
    assert code == 1 and _has(s, "parent_missing")


# =============================================================================================
# 빈 입력 · 잘린 JSON · ID 누락 · history 없음
# =============================================================================================
def test_missing_stream_is_exit_2(tmp_path):
    code, s = vrc.run([str(tmp_path / "nope.jsonl"), str(tmp_path / "l.jsonl")])
    assert code == 2 and s["error"]


def test_empty_stream_is_exit_2(tmp_path):
    code, s = _run(tmp_path, [], [_decide_row()], stream_tail="\n\n")
    assert code == 2 and "empty" in s["error"]


def test_missing_ledger_is_exit_2(tmp_path):
    s_path = _write_jsonl(tmp_path / STREAM_NAME, _chain()[0])
    code, s = vrc.run([s_path, str(tmp_path / "absent.jsonl")])
    assert code == 2 and "ledger" in s["error"]


def test_empty_ledger_with_a_decision_fails(tmp_path):
    frames, _ = _chain()
    code, s = _run(tmp_path, frames, [])
    assert code == 1 and s["decide_joined"] == 0


def test_truncated_last_stream_line_is_diagnosed_but_never_passes(tmp_path):
    frames, rows = _chain()
    code, s = _run(tmp_path, frames, rows, stream_tail='{"t": 1001, "respec_hist')
    assert code == 1
    assert s["stream_truncated_last_line"] is True and _has(s, "stream_truncated")
    assert s["decide_joined"] == 1 and s["attempt_joined"] == 1   # 앞 프레임으로 진단은 한다


def test_stream_with_only_a_truncated_line_is_exit_2(tmp_path):
    code, s = _run(tmp_path, [], [_decide_row()], stream_tail='{"t": 1, "resp')
    assert code == 2


@pytest.mark.parametrize("where", ["middle", "last"])
def test_ledger_json_error_is_never_skipped(tmp_path, where):
    frames, rows = _chain()
    if where == "middle":
        code, s = _run(tmp_path, frames, [rows[0]], ledger_tail="{broken\n" +
                       json.dumps(rows[1]) + "\n")
    else:
        code, s = _run(tmp_path, frames, rows, ledger_tail='{"row_type": "rew')
    assert code == 2 and "not JSON" in s["error"]
    if where == "last":
        assert "being written" in s["error"]


def test_missing_decision_id_fails(tmp_path):
    entry = _dspy_entry(rid=None)
    frames = [_frame([_decision(entry=entry)])]
    code, s = _run(tmp_path, frames, [_decide_row()])
    assert code == 1 and _has(s, "decision_id_missing")


def test_ok_attempt_without_response_id_fails(tmp_path):
    att = _attempt(resp=None)
    code, s = _run(tmp_path, [_frame([_decision(attempts=[att])])],
                   [_decide_row(), _rewrite_row()])
    assert code == 1 and _has(s, "attempt_id_missing")


def test_no_history_in_final_frame_fails(tmp_path):
    frames = [_frame([], with_history=False, with_respec=False)]
    code, s = _run(tmp_path, frames, [_decide_row()])
    assert code == 1 and _has(s, "no_history") and s["history_source"] is None


def test_respec_only_frame_is_supported_explicitly(tmp_path):
    frames = [_frame([_decision(attempts=[_attempt()])], with_history=False)]
    code, s = _run(tmp_path, frames, [_decide_row(), _rewrite_row()])
    assert code == 0, s["problems"]
    assert s["history_source"] == "respec" and s["attempt_joined"] == 1


def test_uses_the_final_frame_not_an_earlier_one(tmp_path):
    # 칸은 결정 행을 제자리 변이하므로 앞 프레임엔 없다 — 마지막 프레임이 정본이다.
    early = _frame([_decision()], t=10)
    late = _frame([_decision(attempts=[_attempt()])], t=20)
    code, s = _run(tmp_path, [early, late], [_decide_row(), _rewrite_row()])
    assert code == 0 and s["attempts"] == 1 and s["stream_frames"] == 2


def test_canonical_run_is_not_applicable_and_require_decisions_blocks_it(tmp_path):
    frames = [_frame([_decision(dspy=False)])]
    code, s = _run(tmp_path, frames, [])
    assert code == 0 and s["verdict"] == "not_applicable"
    assert s["decisions"] == 0 and s["decisions_not_applicable"] == 1
    code, s = _run(tmp_path, frames, [], "--require-decisions", "1")
    assert code == 1 and _has(s, "require_decisions")


def test_require_attempts_counts_joined_attempts_only(tmp_path):
    att = _attempt(roundtrip="failed:HTTP.ConnectError: refused")
    code, s = _run(tmp_path, [_frame([_decision(attempts=[att])])], [_decide_row()],
                   "--require-attempts", "1")
    assert code == 1 and _has(s, "require_attempts")


def test_v1_rows_are_counted_separately_and_never_join(tmp_path):
    frames, rows = _chain()
    legacy = {k: v for k, v in rows[0].items()
              if k not in ("ledger_version", "row_type")}          # 옛 442행 모양 + id
    code, s = _run(tmp_path, frames, [legacy, rows[1]])
    assert code == 1 and _has(s, "decide_row_missing")
    assert s["legacy_rows"] == 1


# =============================================================================================
# cache true / false / unknown — 원시 LM 항목 단위
# =============================================================================================
def test_cache_is_counted_per_raw_lm_entry(tmp_path):
    frames, _ = _chain()
    d = _decide_row(raw={"observe": [_lm(True)], "design": [_lm(False)],
                         "compose": [_lm(None), _lm(True)]})
    r = _rewrite_row(raw={"rewrite": [_lm(None), {"error": "lm_raw: KeyError: x"}]})
    # 받지 못한 중복 행의 캐시는 세지 않는다(조인된 행만).
    other = _decide_row(resp="c" * 32, raw={"observe": [_lm(False)] * 5})
    code, s = _run(tmp_path, frames, [d, r, other])
    assert code == 0, s["problems"]
    assert (s["cache_hits"], s["cache_misses"], s["cache_unknown"]) == (2, 1, 3)


def test_early_exit_decide_row_with_empty_raw_lm_counts_nothing(tmp_path):
    frames, _ = _chain()
    code, s = _run(tmp_path, frames, [_decide_row(raw={}), _rewrite_row()])
    assert code == 0
    assert (s["cache_hits"], s["cache_misses"], s["cache_unknown"]) == (0, 1, 0)


# =============================================================================================
# 동일 프레임 반복
# =============================================================================================
def test_same_frame_repeated_counts_once(tmp_path):
    frames, rows = _chain()
    code, s = _run(tmp_path, frames * 5, rows)
    assert code == 0, s["problems"]
    assert s["stream_frames"] == 5
    assert (s["decisions"], s["attempts"], s["attempt_joined"]) == (1, 1, 1)


def test_same_decision_twice_in_history_is_a_problem(tmp_path):
    dec = _decision(attempts=[_attempt()])
    frames = [_frame([dec, copy.deepcopy(dec)])]
    code, s = _run(tmp_path, frames, [_decide_row(), _rewrite_row()])
    assert code == 1 and _has(s, "stream_duplicate_id")


# =============================================================================================
# R9 — /health 의 ledger_append_failures
# =============================================================================================
def test_health_with_append_failures_fails(tmp_path):
    code, s = _run(tmp_path, *_chain(), health={"ok": True, "ledger_append_failures": 2})
    assert code == 1 and s["ledger_append_failures"] == 2 and _has(s, "ledger_append_failures")


def test_health_with_zero_failures_passes(tmp_path):
    code, s = _run(tmp_path, *_chain(), health={"ledger_append_failures": 0})
    assert code == 0 and s["ledger_append_failures"] == 0


def test_health_without_the_key_is_unknown_not_zero(tmp_path):
    code, s = _run(tmp_path, *_chain(), health={"ok": True})
    assert s["ledger_append_failures"] is None
    assert any("ledger_append_failures" in w for w in s["warnings"])
    code2, s2 = _run(tmp_path, *_chain())                  # 안 줬다 = 모른다
    assert s2["ledger_append_failures"] is None


def test_unreadable_health_json_is_exit_2(tmp_path):
    frames, rows = _chain()
    s_path = _write_jsonl(tmp_path / STREAM_NAME, frames)
    l_path = _write_jsonl(tmp_path / "ledger.jsonl", rows)
    code, s = vrc.run([s_path, l_path, "--health-json", str(tmp_path / "nope.json")])
    assert code == 2


# =============================================================================================
# R10 — orphan 행은 문제가 아니라 보고
# =============================================================================================
def test_raised_and_unreceived_rows_are_orphans_not_problems(tmp_path):
    frames, rows = _chain()
    raised = _decide_row(rid="9" * 24, resp="8" * 32, outcome="raised", raw={})
    unreceived = _decide_row(rid="7" * 24, resp="6" * 32)
    foreign = _decide_row(rid="5" * 24, resp="4" * 32, run_ctx=dict(RUN_CTX, run_id="other"))
    code, s = _run(tmp_path, frames, rows + [raised, unreceived, foreign])
    assert code == 0, s["problems"]
    assert s["orphans"]["count"] == 2
    keys = {(o["record_id"], o["response_id"]) for o in s["orphans"]["keys"]}
    assert keys == {("9" * 24, "8" * 32), ("7" * 24, "6" * 32)}
    assert s["foreign_rows"] == 1


# =============================================================================================
# 원장 기본 경로 · CLI · 생산자 소스 결속
# =============================================================================================
def test_ledger_path_resolution():
    default = os.path.join(REPO, "results", "synth_lane_records.jsonl")
    assert vrc.resolve_ledger_path(None, env={}) == (default, "default")
    assert vrc.resolve_ledger_path(None, env={"SYNTH_RECORD_LOG": "0"}) == (default, "default")
    assert vrc.resolve_ledger_path(None, env={"SYNTH_RECORD_LOG": " "}) == (default, "default")
    assert vrc.resolve_ledger_path(None, env={"SYNTH_RECORD_LOG": "/x/l.jsonl"}) == \
        ("/x/l.jsonl", "env:SYNTH_RECORD_LOG")
    assert vrc.resolve_ledger_path("/y.jsonl", env={"SYNTH_RECORD_LOG": "/x"})[1] == "argument"


def test_cli_runs_under_plain_python3_and_prints_json(tmp_path):
    # 계획서는 `python3 tools/monitor/verify_retry_chain.py ...` 로 부른다 — venv 없이 stdlib 만.
    frames, rows = _chain()
    s_path = _write_jsonl(tmp_path / STREAM_NAME, frames)
    l_path = _write_jsonl(tmp_path / "ledger.jsonl", rows)
    exe = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    p = subprocess.run([exe, os.path.join(HERE, "verify_retry_chain.py"), s_path, l_path,
                        "--require-decisions", "1", "--require-attempts", "1"],
                       capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
    assert p.returncode == 0, p.stdout + p.stderr
    out = json.loads(p.stdout)
    assert out["attempt_joined"] == 1 and out["ledger_path"] == l_path


def _julia_src(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def test_attempt_builder_matches_open_attempt_keys():
    src = _julia_src("tools/monitor/enact.jl")
    m = re.search(r"function _open_attempt!\(.*?local att = Dict\{String,Any\}\((.*?)\)\n    try",
                  src, re.S)
    assert m, "enact.jl _open_attempt! 의 칸 dict 을 못 찾았다"
    keys = set(re.findall(r'"(\w+)"\s*=>', m.group(1)))
    assert keys == set(_attempt()), keys ^ set(_attempt())


def test_dspy_entry_builder_carries_every_synth_lane_key():
    src = _julia_src("tools/monitor/policy.jl")
    m = re.search(r"const SYNTH_LANE_KEYS = \((.*?)\)\n", src, re.S)
    assert m
    keys = set(re.findall(r'"(\w+)"', m.group(1)))
    assert "record_id" in keys and "response_id" in keys
    assert keys <= set(_dspy_entry()), keys - set(_dspy_entry())
