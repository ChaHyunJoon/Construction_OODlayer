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
