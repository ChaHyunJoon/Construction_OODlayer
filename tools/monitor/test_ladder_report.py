"""tools/monitor/ladder_report.py 의 삼중상태·구조적 파서 회귀 시험.

라이브 서비스도 네트워크도 안 쓴다 — 모든 입력은 이 파일이 tmp_path 에 직접 쓰는 고정문
(fixture)이고, 실행되는 것은 순수 Python 파싱뿐이다.

N1 회귀 (이 파일이 지키는 핵심): `enact.jl:1826` 은 다단계 body 의 steps 엔트리를 콤마가
아니라 **공백**으로 잇는다(`35edb4f2`/`fd27a777`). `deb22a93` 는 콤마만 나누는 파서를 심어
`rr_a!:success rr_b!:success` 한 줄을 이름·상태가 뒤섞인 하나의 엔트리로 읽고 L2b 를
FALSE 로 오판했다 — 옛 파서(콤마 split + 첫 ']' 정규식)는 최소한 UNMEASURED 로 정직하게
샜는데, 그 커밋은 "측정 못함" 을 "확신에 찬 오답" 으로 바꿨다(계측기 최악의 실패 모드).

실행: (repo 루트에서) `.venv/bin/python -m pytest tools/monitor/test_ladder_report.py -q`
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import ladder_report as lr  # noqa: E402


def _minted_line(steps_field):
    """Build a realistic [minted] line, with or without a steps= field."""
    line = ("[minted] lane=present tool=Foo verdict=admit applied=true partial=false "
            "world_maybe_dirty=true handled=true undo=none resume=n/a resolve=n/a "
            "args_from=calls n_calls=1 n_body_names=1 registered=true "
            "impl_rejected_why=n/a")
    if steps_field is not None:
        line += " " + steps_field
    line += " reason=test"
    return line


def _write(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _run(tmp_path, steps_field, record=None, stream_row=None):
    """Run the real build_report() end-to-end over a synthetic
    log/record/stream triplet, return the full report dict."""
    log_path = tmp_path / "run.log"
    record_path = tmp_path / "record.jsonl"
    stream_path = tmp_path / "stream.jsonl"

    _write(str(log_path), _minted_line(steps_field) + "\n")
    _write(str(record_path), json.dumps(record if record is not None else {"wrote": True}) + "\n")
    frame = {"now": 1, "respec_history": [stream_row if stream_row is not None else {"interface_calls": []}]}
    _write(str(stream_path), json.dumps(frame) + "\n")

    return lr.build_report(str(log_path), str(stream_path), str(record_path))


# ---------------------------------------------------------------------------
# unit-level: the structural step-entry parser (split_top_level / parse_step_entry)
# ---------------------------------------------------------------------------

def test_single_entry_success():
    entries = lr.split_top_level("Foo!:success")
    assert entries == ["Foo!:success"]
    assert lr.parse_step_entry(entries[0]) == ("Foo!", "success", None)


def test_single_entry_threw_no_detail():
    entries = lr.split_top_level("Foo!:threw")
    assert entries == ["Foo!:threw"]
    assert lr.parse_step_entry(entries[0]) == ("Foo!", "threw", None)


def test_single_entry_threw_with_detail():
    entries = lr.split_top_level("Foo!:threw(MethodError: no method matching length(::Symbol))")
    assert len(entries) == 1
    name, status, detail = lr.parse_step_entry(entries[0])
    assert (name, status) == ("Foo!", "threw")
    assert detail == "MethodError: no method matching length(::Symbol)"


def test_multi_entry_space_separated_all_success_is_N1_case():
    """The exact line the reviewer reported. enact.jl's real joiner is a
    space, not a comma — this must parse as TWO entries."""
    entries = lr.split_top_level("rr_a!:success rr_b!:success")
    assert entries == ["rr_a!:success", "rr_b!:success"]
    assert lr.parse_step_entry(entries[0]) == ("rr_a!", "success", None)
    assert lr.parse_step_entry(entries[1]) == ("rr_b!", "success", None)


def test_multi_entry_space_separated_first_success_second_threw():
    entries = lr.split_top_level("rr_a!:success rr_b!:threw")
    assert entries == ["rr_a!:success", "rr_b!:threw"]
    # L2b reports on the FIRST step only.
    assert lr.parse_step_entry(entries[0])[1] == "success"


def test_multi_entry_first_threw():
    entries = lr.split_top_level("rr_a!:threw rr_b!:success")
    assert lr.parse_step_entry(entries[0])[1] == "threw"


def test_detail_with_comma_angle_brackets_and_nested_brackets():
    raw = "Foo!:threw(no method matching f(::Vector{Int64}, ::Int64) at index [4] for Dict{K,V}<T>)"
    entries = lr.split_top_level(raw)
    assert len(entries) == 1  # the internal comma/space must not fracture the entry
    name, status, detail = lr.parse_step_entry(entries[0])
    assert status == "threw"
    assert detail == "no method matching f(::Vector{Int64}, ::Int64) at index [4] for Dict{K,V}<T>"


def test_comma_separated_entries_still_supported():
    """An alternate ', '-joined rendering must still split correctly (we
    split on comma OR whitespace, not one or the other)."""
    entries = lr.split_top_level("Foo!:success, Bar!:threw(oops, comma inside)")
    assert entries == ["Foo!:success", "Bar!:threw(oops, comma inside)"]


# ---------------------------------------------------------------------------
# end-to-end: full build_report() over synthetic files — tri-state discipline
# ---------------------------------------------------------------------------

def test_e2e_N1_space_joined_all_success_reads_TRUE(tmp_path):
    report = _run(tmp_path, "steps=[rr_a!:success rr_b!:success]")
    r = report["rungs"]["L2b_no_exception"]
    assert r["verdict"] == lr.TRUE
    assert r["n_steps_entries"] == 2
    assert r["first_step_status"] == "success"


def test_e2e_first_threw_multistep_reads_FALSE(tmp_path):
    report = _run(tmp_path, "steps=[rr_a!:threw rr_b!:success]")
    r = report["rungs"]["L2b_no_exception"]
    assert r["verdict"] == lr.FALSE
    assert r["first_step_status"] == "threw"


def test_e2e_steps_empty_is_measured_empty(tmp_path):
    report = _run(tmp_path, "steps=[]")
    r = report["rungs"]["L2b_no_exception"]
    assert r["verdict"] == lr.MEASURED_EMPTY


def test_e2e_steps_absent_is_unmeasured(tmp_path):
    report = _run(tmp_path, None)
    r = report["rungs"]["L2b_no_exception"]
    assert r["verdict"] == lr.UNMEASURED


# ---------------------------------------------------------------------------
# L4 tri-state set (I1 fix regression: unjudgeable shape must never read TRUE)
# ---------------------------------------------------------------------------

def _l4(tmp_path, row):
    report = _run(tmp_path, "steps=[Foo!:success]", stream_row=row)
    return report["rungs"]["L4_world_changed"]


def test_l4_world_delta_body_absent_is_unmeasured(tmp_path):
    r = _l4(tmp_path, {"interface_calls": []})
    assert r["verdict"] == lr.UNMEASURED


def test_l4_world_delta_body_null_is_unmeasured(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": None})
    assert r["verdict"] == lr.UNMEASURED


def test_l4_world_delta_body_false_is_unmeasured_not_true(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": False})
    assert r["verdict"] == lr.UNMEASURED


def test_l4_world_delta_body_empty_dict_is_unmeasured_not_true(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": {}})
    assert r["verdict"] == lr.UNMEASURED


def test_l4_world_delta_body_string_is_unmeasured_not_true(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": "unchanged"})
    assert r["verdict"] == lr.UNMEASURED


def test_l4_world_delta_body_all_zero_is_measured_zero(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body":
                        {"n_binding_changed": 0, "active": 0, "n_edges": 0, "closed": 0}})
    assert r["verdict"] == lr.MEASURED_ZERO


def test_l4_world_delta_body_non_zero_is_true(tmp_path):
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body":
                        {"n_binding_changed": 1, "active": 0, "n_edges": 0, "closed": 0}})
    assert r["verdict"] == lr.TRUE
    assert r["verdict"] != lr.MEASURED_ZERO


# ---------------------------------------------------------------------------
# L4 sixth axis: n_staging_moved (geometry) — B1, 2026-09-05
#
# The defect this closes: a hand-written zone oracle took a build from
# n_closed=270/305 (PROJECT INCOMPLETE) to 287/305 (PROJECT COMPLETE) and
# world_delta_body reported 0 on all five schedule axes — the repair edits
# GEOMETRY (start_config transforms + staging circles), which no schedule axis
# can see. The sixth axis is tri-state PER AXIS: null = geometry not readable
# in this env, 0 = read and nothing moved.
# ---------------------------------------------------------------------------

FIVE_ZERO = {"closed": 0, "active": 0, "n_edges": 0,
             "n_binding_changed": 0, "n_weights_changed": 0}


def test_l4_geometry_only_move_reads_TRUE_not_measured_zero(tmp_path):
    """THE defect case: five schedule axes at zero, geometry axis positive."""
    row = dict(FIVE_ZERO); row["n_staging_moved"] = 8
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": row})
    assert r["verdict"] == lr.TRUE
    assert r["verdict"] != lr.MEASURED_ZERO


def test_l4_all_six_zero_is_measured_zero(tmp_path):
    row = dict(FIVE_ZERO); row["n_staging_moved"] = 0
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": row})
    assert r["verdict"] == lr.MEASURED_ZERO
    assert r["reason"] is None


def test_l4_null_geometry_axis_with_zeros_is_unmeasured_not_measured_zero(tmp_path):
    """null != 0. Five zeros plus an unreadable geometry axis does NOT license
    'the world did not change' — the null axis is the one that would have
    carried a zone repair."""
    row = dict(FIVE_ZERO); row["n_staging_moved"] = None
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": row})
    assert r["verdict"] == lr.UNMEASURED
    assert r["verdict"] != lr.MEASURED_ZERO
    assert "n_staging_moved" in r["reason"]


def test_l4_null_geometry_axis_does_not_downgrade_a_measured_positive(tmp_path):
    """A readable non-zero axis is a measured positive; a null elsewhere is
    noted but must not take the positive away."""
    row = dict(FIVE_ZERO); row["n_binding_changed"] = 3; row["n_staging_moved"] = None
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": row})
    assert r["verdict"] == lr.TRUE
    assert "n_staging_moved" in r["reason"]


def test_l4_previous_generation_five_axis_row_still_scores(tmp_path):
    """Rows written before the sixth axis existed have five keys and no null —
    they must keep scoring exactly as they did (no key, no claim)."""
    row = dict(FIVE_ZERO); row["closed"] = 2
    r = _l4(tmp_path, {"interface_calls": [], "world_delta_body": row})
    assert r["verdict"] == lr.TRUE
    assert r["reason"] is None


def test_unmeasured_leaf_names_unit():
    assert lr.unmeasured_leaf_names({"a": 0, "b": None}) == ["b"]
    assert lr.unmeasured_leaf_names({"a": 0}) == []
    assert lr.unmeasured_leaf_names([1, None]) == ["[1]"]
    assert lr.unmeasured_leaf_names("not a container") == []


def test_all_numeric_zero_ignores_nulls_as_leaves():
    """The null must not be counted as a zero leaf — the caller, not this
    helper, decides what a null does to the verdict."""
    is_zero, components = lr.all_numeric_zero({"a": 0, "b": None})
    assert is_zero is True                     # every NUMERIC leaf is zero
    assert ("b", None) in components           # but the null is still printed


# =============================================================================
# D17b (2026-09-05) — `[minted]` 줄에 `enact_retry=` 한 칸이 늘었다.
#
# 재는 명제: 그 칸이 늘어도 (a) 기존 추출이 하나도 안 깨지고, (b) 새 칸 자신이
# 같은 `(\S+)` 관용구로 읽히며, (c) `steps=[...]` 의 구조적 괄호 파싱이 그대로 산다.
# 🔴 아래 두 리터럴은 **손으로 지은 것이 아니라** 2026-09-05 실측 런의 stdout 에서
#    그대로 복사한 줄이다(`test/minted_end_to_end.jl` (33)(35a)).
# =============================================================================
D17B_RETRIED = (
    "[minted] lane=present tool=T verdict=admit applied=nothing partial=false "
    "world_maybe_dirty=true handled=true undo=none resume=issued "
    "resolve=not_needed_surface args_from=calls n_calls=1 dropped_args=none "
    "enact_retry=retried n_body_names=1 registered=true impl_rejected_why=n/a "
    "steps=[d17b_boom_a!:rw_ok] reason=body of 1 primitives")

D17B_REFUSED = (
    "[minted] lane=present tool=T verdict=admit applied=nothing partial=true "
    "world_maybe_dirty=true handled=true undo=none resume=issued "
    "resolve=not_needed_surface args_from=calls n_calls=2 "
    "dropped_args=d17b_second_boom!.goal enact_retry=refused_not_first_step "
    "n_body_names=2 registered=true impl_rejected_why=n/a "
    "steps=[d17b_first_ok!:rw_ok d17b_second_boom!:threw(KeyError: key \"g\" "
    "not found)] reason=body threw at d17b_second_boom!")


def test_d17b_the_new_field_does_not_break_any_existing_extraction():
    for line in (D17B_RETRIED, D17B_REFUSED):
        assert lr.MINTED_RE.findall(line) == [line]
        got = {k: (rx.search(line).group(1) if rx.search(line) else None)
               for k, rx in lr.MINTED_FIELD_RES.items()}
        assert got["registered"] == "true"
        assert got["impl_rejected_why"] == "n/a"
        assert got["args_from"] == "calls"
        assert got["n_calls"] in ("1", "2")


def test_d17b_enact_retry_reads_with_the_same_idiom():
    """공백이 없으므로 `(\\S+)` 하나로 읽힌다 — 이 파일의 다른 칸과 같은 관용구."""
    import re
    rx = re.compile(r'enact_retry=(\S+)')
    assert rx.search(D17B_RETRIED).group(1) == "retried"
    assert rx.search(D17B_REFUSED).group(1) == "refused_not_first_step"


def test_d17b_steps_bracket_parser_survives_the_new_field():
    """새 칸은 `steps=` **앞**에 있고 대괄호를 안 담는다 — 깊이 추적이 그대로 산다."""
    assert lr.extract_steps_raw(D17B_RETRIED) == "[d17b_boom_a!:rw_ok]"
    raw = lr.extract_steps_raw(D17B_REFUSED)
    entries = lr.split_top_level(raw[1:-1])
    assert len(entries) == 2
    assert lr.parse_step_entry(entries[0])[1] == "rw_ok"
    assert lr.parse_step_entry(entries[1])[1] == "threw"


def test_d17b_a_retried_line_is_not_confusable_with_a_first_try_success():
    """🔴 이 태스크의 요점. `enact_retry=` 를 빼면 두 줄이 **글자로 구별 불가**가 된다."""
    first_try = D17B_RETRIED.replace(" enact_retry=retried", "")
    retried_without_field = D17B_RETRIED.replace(" enact_retry=retried", "")
    assert first_try == retried_without_field          # 칸이 없으면 같은 줄이다
    assert "enact_retry=retried" in D17B_RETRIED       # 있으면 다르다
    assert "enact_retry=retried" not in first_try


# =============================================================================
# D17c (2026-09-05) — `enact_retry=` 가 **두 트리거**를 나른다.
#
# 재는 명제: 접두 `noop_` 가 붙어도 (a) 기존 추출이 하나도 안 깨지고, (b) 같은 `(\S+)`
# 관용구로 읽히며, (c) `noop_retried` 판이 `retried` 판과도, 첫-시도 성공판(`n/a`)과도
# **글자로 구별된다**. 🔴 아래 두 리터럴은 손으로 지은 것이 아니라 2026-09-05 실측 런의
# stdout 에서 그대로 복사한 줄이다(`test/minted_end_to_end.jl` (41)(38)).
# =============================================================================
D17C_NOOP_RETRIED = (
    "[minted] lane=present tool=T verdict=admit applied=nothing partial=false "
    "world_maybe_dirty=true handled=true undo=none resume=issued "
    "resolve=not_needed_surface args_from=calls n_calls=1 dropped_args=none "
    "enact_retry=noop_retried n_body_names=1 registered=true impl_rejected_why=n/a "
    "steps=[d17c_noop_a!:rw_ok] reason=body of 1 primitives")

D17C_NOOP_UNMEASURED = (
    "[minted] lane=present tool=T verdict=admit applied=nothing partial=false "
    "world_maybe_dirty=true handled=true undo=none resume=issued "
    "resolve=not_needed_surface args_from=calls n_calls=1 dropped_args=none "
    "enact_retry=noop_refused_unmeasured n_body_names=1 registered=true "
    "impl_rejected_why=n/a steps=[d18_noop_tool!:d18_did_nothing] "
    "reason=body of 1 primitives")


def test_d17c_the_prefixed_value_does_not_break_any_existing_extraction():
    for line in (D17C_NOOP_RETRIED, D17C_NOOP_UNMEASURED):
        assert lr.MINTED_RE.findall(line) == [line]
        got = {k: (rx.search(line).group(1) if rx.search(line) else None)
               for k, rx in lr.MINTED_FIELD_RES.items()}
        assert got["registered"] == "true"
        assert got["impl_rejected_why"] == "n/a"
        assert got["args_from"] == "calls"


def test_d17c_enact_retry_reads_with_the_same_idiom():
    """접두가 붙어도 공백이 없다 — `(\\S+)` 하나로 읽힌다."""
    import re
    rx = re.compile(r'enact_retry=(\S+)')
    assert rx.search(D17C_NOOP_RETRIED).group(1) == "noop_retried"
    assert rx.search(D17C_NOOP_UNMEASURED).group(1) == "noop_refused_unmeasured"


def test_d17c_steps_bracket_parser_survives_the_prefixed_value():
    assert lr.extract_steps_raw(D17C_NOOP_RETRIED) == "[d17c_noop_a!:rw_ok]"
    raw = lr.extract_steps_raw(D17C_NOOP_UNMEASURED)
    assert lr.parse_step_entry(lr.split_top_level(raw[1:-1])[0])[1] == "d18_did_nothing"


def test_d17c_the_two_triggers_are_not_collapsible():
    """🔴 이 태스크의 요점. 두 되먹임 트리거가 **한 판독으로** 갈린다."""
    import re
    rx = re.compile(r'enact_retry=(\S+)')
    noop = rx.search(D17C_NOOP_RETRIED).group(1)
    threw = rx.search(D17B_RETRIED).group(1)
    assert noop != threw                       # 두 사건이 다른 값이다
    assert noop.startswith("noop_") and not threw.startswith("noop_")
    # 🔴 부분문자열로 읽으면 틀린다 — `retried` 는 `noop_retried` 안에 들어 있다.
    #    `enact_retry=` 를 **앞에 붙여** 읽어야 두 판이 갈린다(이 파일의 관용구).
    assert "retried" in "noop_retried"                       # 함정 자체를 못박는다
    assert "enact_retry=retried" not in D17C_NOOP_RETRIED    # 그러나 이 판독은 안 속는다
    assert "enact_retry=noop_retried" not in D17B_RETRIED


def test_d17c_a_noop_retried_line_is_not_confusable_with_a_first_try_success():
    """첫-시도 성공판은 `enact_retry=n/a` 다 — 그 한 칸이 세 판을 가른다."""
    clean = D17C_NOOP_RETRIED.replace("enact_retry=noop_retried", "enact_retry=n/a")
    assert clean != D17C_NOOP_RETRIED
    for line, want in ((D17C_NOOP_RETRIED, "noop_retried"),
                       (D17B_RETRIED, "retried"), (clean, "n/a")):
        import re
        assert re.compile(r'enact_retry=(\S+)').search(line).group(1) == want
    # 🔴 그리고 그 칸을 빼면 세 판 중 둘이 **글자로 구별 불가**가 된다.
    assert (D17C_NOOP_RETRIED.replace(" enact_retry=noop_retried", "") ==
            clean.replace(" enact_retry=n/a", ""))


# ---------------------------------------------------------------------------
# 2026-09-22 (재시도 body 보존 Task 3 리뷰 fix round 1): 원장 v2 는 행 종류가 섞인다.
# `/rewrite` 행(row_type="rewrite")과 조기 반환 decide 행(no_tools / no_call_* / raised)이
# 파일 끝에 올 수 있다. L0 는 "마지막 줄" 이 아니라 **마지막 합성 decide 행**(또는 v1 행)을
# 읽어야 한다 — 안 그러면 rewrite 의 `wrote` 를 첫 시도로 읽거나, blank 행에서 UNMEASURED 로
# 뒤집힌다(리뷰가 짚은 실패).
# ---------------------------------------------------------------------------

def _run_ledger(tmp_path, rows):
    log_path = tmp_path / "run.log"
    record_path = tmp_path / "record.jsonl"
    stream_path = tmp_path / "stream.jsonl"
    _write(str(log_path), _minted_line("steps=[Foo:success]") + "\n")
    _write(str(record_path), "".join(json.dumps(r) + "\n" for r in rows))
    _write(str(stream_path), json.dumps({"now": 1, "respec_history": [{"interface_calls": []}]}) + "\n")
    return lr.build_report(str(log_path), str(stream_path), str(record_path))


_SYN = {"ledger_version": 2, "row_type": "decide", "decide_outcome": "synthesis_ran",
        "wrote": False, "stages": ["observe", "design", "compose"], "tool_name": "first"}


def test_v2_a_trailing_rewrite_row_does_not_hide_the_first_attempt(tmp_path):
    rw = {"ledger_version": 2, "row_type": "rewrite", "wrote": True, "tool_name": "rewritten"}
    rep = _run_ledger(tmp_path, [_SYN, rw])
    assert rep["rungs"]["L0_wrote"]["verdict"] == lr.FALSE, "rewrite 의 wrote 를 첫 시도로 읽었다"
    assert rep["context"]["tool_name"] == "first"


def test_v2_a_trailing_early_exit_decide_row_does_not_flip_L0_to_unmeasured(tmp_path):
    for outcome in ("no_call_no_tool_call", "no_call_lm_error", "no_call_parse_error",
                    "no_tools", "raised"):
        blank = {"ledger_version": 2, "row_type": "decide", "decide_outcome": outcome,
                 "tool_minted": None, "ran": False}
        rep = _run_ledger(tmp_path, [_SYN, blank])
        assert rep["rungs"]["L0_wrote"]["verdict"] == lr.FALSE, outcome
        assert rep["context"]["stages"] == ["observe", "design", "compose"], outcome


def test_v2_the_scenario_from_the_review(tmp_path):
    """합성 발화 → /rewrite → 뒤 사건이 no_call. L0 는 여전히 첫 합성 행을 읽는다."""
    ok = dict(_SYN, wrote=True)
    rw = {"ledger_version": 2, "row_type": "rewrite", "wrote": False}
    nc = {"ledger_version": 2, "row_type": "decide", "decide_outcome": "no_call_no_tool_call"}
    rep = _run_ledger(tmp_path, [ok, rw, nc])
    assert rep["rungs"]["L0_wrote"]["verdict"] == lr.TRUE


def test_v2_a_ledger_with_no_synthesis_row_is_unmeasured_and_says_why(tmp_path):
    nc = {"ledger_version": 2, "row_type": "decide", "decide_outcome": "no_tools"}
    rw = {"ledger_version": 2, "row_type": "rewrite", "wrote": True}
    rep = _run_ledger(tmp_path, [nc, rw])
    r = rep["rungs"]["L0_wrote"]
    assert r["verdict"] == lr.UNMEASURED
    assert "no synthesis row" in r["reason"]


def test_v2_the_last_synthesis_row_wins_over_an_earlier_v1_row(tmp_path):
    rep = _run_ledger(tmp_path, [{"wrote": False}, dict(_SYN, wrote=True),
                                 {"ledger_version": 2, "row_type": "rewrite", "wrote": False}])
    assert rep["rungs"]["L0_wrote"]["verdict"] == lr.TRUE


def test_v1_only_ledger_reads_the_last_line_exactly_as_before(tmp_path):
    """v1 전용 원장은 바이트 동일: 마지막 줄을 읽고, 사유 문구도 옛 그대로다."""
    rep = _run_ledger(tmp_path, [{"wrote": True}, {"wrote": False}])
    assert rep["rungs"]["L0_wrote"]["verdict"] == lr.FALSE
    rep = _run_ledger(tmp_path, [{"wrote": True}, {"stages": ["observe"]}])
    r = rep["rungs"]["L0_wrote"]
    rec = str(tmp_path / "record.jsonl")
    assert r["verdict"] == lr.UNMEASURED
    assert r["reason"] == "key 'wrote' absent from last line of %s" % os.path.abspath(rec)
    assert rep["context"]["tool_name_status"] == \
        "UNMEASURED: key 'tool_name' absent from last line of %s" % os.path.abspath(rec)


def test_v1_a_corrupt_last_line_keeps_the_old_error(tmp_path):
    record_path = tmp_path / "record.jsonl"
    _write(str(record_path), json.dumps({"wrote": True}) + "\n{not json\n")
    old = lr.read_last_jsonl_line(str(record_path))
    new = lr.read_last_synthesis_record(str(record_path))
    assert new[0] is None and old[0] is None and new[1] == old[1]
