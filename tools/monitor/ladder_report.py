#!/usr/bin/env python3
"""ladder_report.py — mechanically score a demo run against the 5-rung ladder.

Scoring used to be done by hand: someone reads a log and a couple of JSONL
files and quotes numbers. That process has produced wrong numbers in this
repo before. This script reads the same three artifacts and prints the same
numbers, but every extraction is explicit about where it came from and
whether it was actually measured.

Tri-state discipline (hard requirement): a field that is absent from its
source is UNMEASURED, never rendered the same as a measured FALSE or a
measured zero/empty. Nothing is guessed or defaulted from a sibling field.

Usage:
    python3 tools/monitor/ladder_report.py --log results/run2-treatment.log \
        [--stream tools/monitor/streams/tractor__battery_mild.jsonl] \
        [--record results/synth_lane_records.jsonl] [--json]
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

UNMEASURED = "UNMEASURED"
TRUE = "TRUE"
FALSE = "FALSE"
MEASURED_EMPTY = "MEASURED-EMPTY"
MEASURED_ZERO = "MEASURED-ZERO"

_ABSENT = object()  # sentinel: distinguishes "key missing" from "value is null"

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')

MINTED_RE = re.compile(r'\[minted\] lane=present[^\n\r]*')
OOD_RE = re.compile(r'\[ood\][^\n\r]*fired at step\S*[^\n\r]*')
ROUTER_RE = re.compile(r'\[router\][^\n\r]*')
BATTERY_DRAWN_RE = re.compile(r'[^\n\r]*battery drawn at step=[^\n\r]*')
PROJECT_COMPLETE_RE = re.compile(r'PROJECT COMPLETE!')
PROJECT_INCOMPLETE_RE = re.compile(r'PROJECT INCOMPLETE!')
STEP_NUM_RE = re.compile(r'step_num:\s*(\d+)')
N_CLOSED_RE = re.compile(r'n_closed:\s*(\d+)')
N_TOTAL_RE = re.compile(r'n_total:\s*(\d+)')
SIM_100_RE = re.compile(r'Simulating\.\.\.\s*100%[^\n\r]*?Time:\s*([0-9:]+)')

MINTED_FIELD_RES = {
    "registered": re.compile(r'registered=(\S+)'),
    "impl_rejected_why": re.compile(r'impl_rejected_why=(\S+)'),
    "args_from": re.compile(r'args_from=(\S+)'),
    "n_calls": re.compile(r'n_calls=(\S+)'),
    # NOTE: 'steps=' is deliberately NOT here. It cannot be extracted with a
    # flat regex: the detail text inside steps=[name:status(detail)] is an
    # arbitrary Julia exception message, which very commonly contains ']',
    # ',', '(' and ')' (MethodError argument lists, BoundsError indices,
    # Vector{T} renderings, ...). See extract_steps_raw() / parse_step_entry()
    # below for the structural (depth-tracking) parser instead.
}


def find_bracket_close(text, open_idx):
    """text[open_idx] must be '['. Return the index of the matching ']' by
    tracking '[' / ']' depth from there. Any other character (including
    '(' ')' and ',') is ignored, so a detail string containing brackets
    (e.g. 'index [4]', 'Vector{Int64}') is handled correctly as long as its
    own brackets are internally balanced. Returns None if depth never
    returns to zero before the end of the string.
    """
    depth = 0
    for i in range(open_idx, len(text)):
        c = text[i]
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                return i
    return None


def extract_steps_raw(minted_line):
    """Structurally extract the bracketed 'steps=[...]' text from a
    [minted] line. Returns the full '[...]' substring (brackets included),
    or None if 'steps=' is not present at all. Raises ValueError (caught by
    the caller, rendered as UNMEASURED) if 'steps=' is present but the
    bracket is missing or never balances — that is a genuinely unparsable
    line, not an absent field.
    """
    marker = 'steps='
    idx = minted_line.find(marker)
    if idx == -1:
        return None
    open_idx = idx + len(marker)
    if open_idx >= len(minted_line) or minted_line[open_idx] != '[':
        raise ValueError("'steps=' found but not immediately followed by '['")
    close_idx = find_bracket_close(minted_line, open_idx)
    if close_idx is None:
        raise ValueError("'steps=[' found but its ']' never balances before end of line")
    return minted_line[open_idx:close_idx + 1]


def split_top_level(text):
    """Split text into step entries at depth 0, on EITHER a comma OR any
    whitespace.

    N1 fix: enact.jl:1826 joins multi-step entries with a space, not a
    comma (35edb4f2/fd27a777 only changed what goes *inside* an entry's
    parens, not the joiner). A comma-only splitter turns 'a!:success
    b!:success' into one fused entry with a bogus status string ->
    L2b silently mis-scores TRUE work as FALSE. Splitting on both is safe:
    inside brackets/parens (depth > 0) neither comma nor whitespace ends an
    entry, so a comma or a space inside an exception detail still doesn't
    fracture it. Runs of separators collapse; empty entries are dropped.
    """
    parts = []
    depth = 0
    current = []

    def flush():
        s = ''.join(current)
        if s:
            parts.append(s)
        current.clear()

    for c in text:
        if c in '([':
            depth += 1
            current.append(c)
        elif c in ')]':
            depth -= 1
            current.append(c)
        elif depth <= 0 and (c == ',' or c.isspace()):
            flush()
        else:
            current.append(c)
    flush()
    return parts


def parse_step_entry(entry):
    """Parse one step entry: 'name:status' (old form) or
    'name:status(detail)' (new form), where detail is arbitrary text that
    may itself contain any punctuation, including nested parens. Returns
    (name, status, detail_or_None), or None if there is no ':' to split on.

    detail is recovered by tracking paren depth from the first '(' after
    the status token, so 'threw(MethodError: no method matching
    length(::Symbol))' yields detail = 'MethodError: no method matching
    length(::Symbol)' in full, not truncated at the first ')'.
    """
    entry = entry.strip()
    if ':' not in entry:
        return None
    name, rest = entry.split(':', 1)
    name = name.strip()
    paren_idx = rest.find('(')
    if paren_idx == -1:
        return name, rest.strip(), None
    status = rest[:paren_idx].strip()
    depth = 0
    close_idx = None
    for i in range(paren_idx, len(rest)):
        c = rest[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                close_idx = i
                break
    if close_idx is None:
        # Unbalanced — never invent a boundary; take the verbatim remainder.
        detail = rest[paren_idx + 1:]
    else:
        detail = rest[paren_idx + 1:close_idx]
    return name, status, detail


def eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


def resolve_file(path):
    """Return (abs_path, exists, mtime_iso_or_None)."""
    abs_path = os.path.abspath(path)
    if os.path.isfile(abs_path):
        mtime = os.path.getmtime(abs_path)
        mtime_iso = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
        return abs_path, True, mtime_iso
    return abs_path, False, None


def read_log_text(path):
    """Read log as bytes, decode with errors='replace', strip ANSI."""
    with open(path, 'rb') as f:
        raw = f.read()
    text = raw.decode('utf-8', errors='replace')
    text = ANSI_RE.sub('', text)
    return text


def read_last_jsonl_line(path):
    """Read a JSONL file and return the parsed last non-blank line.

    Returns (obj_or_None, error_or_None).
    """
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    last = None
    for line in reversed(lines):
        line = line.strip()
        if line:
            last = line
            break
    if last is None:
        return None, "file has no non-blank lines"
    try:
        return json.loads(last), None
    except Exception as e:
        return None, "failed to json.loads the last non-blank line: %r" % (e,)


def find_last_frame_with_respec(path):
    """Scan a monitor-stream JSONL and return the last frame (dict) whose
    'respec_history' list is present and non-empty. Malformed lines are
    skipped (they cannot be attributed to any frame). Returns
    (frame_or_None, n_frames_scanned, n_parse_errors).
    """
    last_frame = None
    n_frames = 0
    n_errors = 0
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                n_errors += 1
                continue
            n_frames += 1
            rh = obj.get('respec_history') if isinstance(obj, dict) else None
            if rh:
                last_frame = obj
    return last_frame, n_frames, n_errors


def tri_get(d, key):
    """Fetch key from dict d, returning (present, value).

    present=False means the key is absent (never invent a default).
    present=True, value=None means the key exists and is explicitly null.
    """
    if not isinstance(d, dict):
        return False, None
    if key not in d:
        return False, None
    return True, d[key]


def rung_from_present(present, value, true_pred, absent_reason, null_reason=None):
    """Generic tri-state verdict builder for a simple present/value pair."""
    if not present:
        return {"verdict": UNMEASURED, "reason": absent_reason, "value": None}
    if value is None:
        return {"verdict": UNMEASURED, "reason": null_reason or (absent_reason + " (value is null)"), "value": None}
    verdict = TRUE if true_pred(value) else FALSE
    return {"verdict": verdict, "reason": None, "value": value}


def unmeasured_leaf_names(value):
    """Names of leaves that are explicitly null (= "not measured").

    B1 (2026-09-05): the world digest's sixth axis, 'n_staging_moved'
    (geometry), is tri-state PER AXIS -- null means "this run could not read
    the geometry", which is a DIFFERENT observation from 0 ("read it, nothing
    moved"). Every other axis stays all-or-nothing on the digest as a whole.
    A null leaf must therefore never be silently skipped: if the readable axes
    are all zero and some axis is null, the row does NOT license "the world did
    not change" -- it licenses "we cannot tell".
    """
    if isinstance(value, dict):
        return [k for k, v in value.items() if v is None]
    if isinstance(value, list):
        return ["[%d]" % i for i, v in enumerate(value) if v is None]
    return []


def all_numeric_zero(value):
    """Return (is_all_zero, components) for a delta-like structure.

    components is a list of (name, value) pairs for printing. is_all_zero is
    True only if every numeric leaf is exactly zero. Returns None for
    is_all_zero if the shape carries no numeric leaves to judge (caller then
    falls back to treating any presence as non-zero/TRUE with a note).

    NOTE: explicitly-null leaves are NOT numeric leaves and do not make the
    row zero on their own; the caller pairs this with unmeasured_leaf_names()
    so that "all readable axes are zero, but one axis is null" reads as
    UNMEASURED rather than MEASURED_ZERO.
    """
    if isinstance(value, dict):
        items = list(value.items())
        numerics = [v for _, v in items if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if not numerics:
            return None, items
        return all(v == 0 for v in numerics), items
    if isinstance(value, list):
        if not value:
            return True, []
        numerics = [v for v in value if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if not numerics:
            return None, list(enumerate(value))
        return all(v == 0 for v in numerics), list(enumerate(value))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value == 0, [("(scalar)", value)]
    return None, [("(value)", value)]


def build_report(log_path, stream_path, record_path):
    report = {"files": {}, "rungs": {}, "build": {}, "context": {}}

    # ---- resolve + read inputs (independent; a missing file never crashes) ----
    files_read = {}

    log_abs, log_exists, log_mtime = resolve_file(log_path)
    report["files"]["log"] = {"path": log_abs, "exists": log_exists, "mtime_utc": log_mtime}
    log_text = None
    log_err = None
    if log_exists:
        try:
            log_text = read_log_text(log_abs)
            files_read["log"] = (log_abs, log_mtime)
        except Exception as e:
            log_err = "failed to read log: %r" % (e,)
    else:
        log_err = "file not found: %s" % (log_abs,)

    record_abs, record_exists, record_mtime = resolve_file(record_path)
    report["files"]["record"] = {"path": record_abs, "exists": record_exists, "mtime_utc": record_mtime}
    record_obj = None
    record_err = None
    if record_exists:
        try:
            record_obj, record_err = read_last_jsonl_line(record_abs)
            if record_obj is not None:
                files_read["record"] = (record_abs, record_mtime)
        except Exception as e:
            record_err = "failed to read record: %r" % (e,)
    else:
        record_err = "file not found: %s" % (record_abs,)

    stream_abs, stream_exists, stream_mtime = resolve_file(stream_path)
    report["files"]["stream"] = {"path": stream_abs, "exists": stream_exists, "mtime_utc": stream_mtime}
    last_frame = None
    stream_err = None
    n_frames = n_errors = 0
    if stream_exists:
        try:
            last_frame, n_frames, n_errors = find_last_frame_with_respec(stream_abs)
            files_read["stream"] = (stream_abs, stream_mtime)
            if last_frame is None:
                stream_err = ("scanned %d frames (%d unparsable lines skipped) but none had a "
                               "non-empty 'respec_history'" % (n_frames, n_errors))
        except Exception as e:
            stream_err = "failed to read stream: %r" % (e,)
    else:
        stream_err = "file not found: %s" % (stream_abs,)

    report["files_read"] = files_read

    decision_row = None
    n_decision_rows = 0
    if last_frame is not None:
        rh = last_frame.get('respec_history')
        if isinstance(rh, list) and rh:
            n_decision_rows = len(rh)
            decision_row = rh[-1]

    # ================= L0 =================
    try:
        if record_obj is None:
            report["rungs"]["L0_wrote"] = {
                "verdict": UNMEASURED,
                "reason": record_err or ("key 'wrote' not found: %s has no usable last line" % record_abs),
                "evidence_file": record_abs, "evidence_key": "wrote", "value": None,
            }
        else:
            present, value = tri_get(record_obj, "wrote")
            r = rung_from_present(
                present, value, lambda v: v is True,
                absent_reason="key 'wrote' absent from last line of %s" % record_abs,
            )
            r["evidence_file"] = record_abs
            r["evidence_key"] = "wrote"
            report["rungs"]["L0_wrote"] = r
    except Exception as e:
        report["rungs"]["L0_wrote"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                        "evidence_file": record_abs, "evidence_key": "wrote", "value": None}

    # ================= minted line (feeds L1, L2a, L2b) =================
    minted_line = None
    minted_fields = {}
    minted_err = None
    n_minted_lines = 0
    minted_index_used = None
    try:
        if log_text is None:
            minted_err = log_err or "log not read"
        else:
            matches = MINTED_RE.findall(log_text)
            n_minted_lines = len(matches)
            if not matches:
                minted_err = "no '[minted] lane=present' line found in %s" % log_abs
            else:
                minted_index_used = n_minted_lines - 1  # last one, 0-based
                minted_line = matches[-1]
                for key, rx in MINTED_FIELD_RES.items():
                    m = rx.search(minted_line)
                    minted_fields[key] = m.group(1) if m else None
    except Exception as e:
        minted_err = "exception scanning minted line: %r" % (e,)

    # ---- L1 registered ----
    try:
        if minted_err:
            report["rungs"]["L1_registered"] = {
                "verdict": UNMEASURED, "reason": minted_err,
                "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... registered=",
                "registered": None, "impl_rejected_why": None,
            }
        else:
            reg = minted_fields.get("registered")
            why = minted_fields.get("impl_rejected_why")
            if reg is None:
                verdict = UNMEASURED
                reason = "'registered=' key not present on the matched [minted] line"
            elif reg == "true":
                verdict, reason = TRUE, None
            elif reg == "false":
                verdict, reason = FALSE, None
            else:
                verdict, reason = FALSE, "registered= had unexpected literal %r" % (reg,)
            report["rungs"]["L1_registered"] = {
                "verdict": verdict, "reason": reason,
                "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... registered=",
                "registered": reg, "impl_rejected_why": why,
                "raw_line": minted_line,
            }
    except Exception as e:
        report["rungs"]["L1_registered"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                             "evidence_file": log_abs, "evidence_key": "registered=",
                                             "registered": None, "impl_rejected_why": None}

    # ---- L2a args channel ----
    try:
        if minted_err:
            report["rungs"]["L2a_args_channel"] = {
                "verdict": UNMEASURED, "reason": minted_err,
                "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... args_from=",
                "args_from": None, "n_calls": None,
            }
        else:
            args_from = minted_fields.get("args_from")
            n_calls = minted_fields.get("n_calls")
            if args_from is None:
                verdict = UNMEASURED
                reason = "'args_from=' key not present on the matched [minted] line"
            elif args_from == "calls":
                verdict, reason = TRUE, None
            else:
                verdict, reason = FALSE, "args_from=%s (not 'calls')" % (args_from,)
            report["rungs"]["L2a_args_channel"] = {
                "verdict": verdict, "reason": reason,
                "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... args_from=",
                "args_from": args_from, "n_calls": n_calls,
                "raw_line": minted_line,
            }
    except Exception as e:
        report["rungs"]["L2a_args_channel"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                                "evidence_file": log_abs, "evidence_key": "args_from=",
                                                "args_from": None, "n_calls": None}

    # ---- L2b no exception ----
    try:
        if minted_err:
            report["rungs"]["L2b_no_exception"] = {
                "verdict": UNMEASURED, "reason": minted_err,
                "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                "steps_raw": None, "first_step_name": None, "first_step_status": None, "first_step_detail": None,
                "detail_format": None,
            }
        else:
            try:
                steps_raw = extract_steps_raw(minted_line)
            except ValueError as ve:
                report["rungs"]["L2b_no_exception"] = {
                    "verdict": UNMEASURED,
                    "reason": "could not structurally parse steps= on the matched [minted] line: %s" % (ve,),
                    "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                    "steps_raw": None, "first_step_name": None, "first_step_status": None,
                    "first_step_detail": None, "detail_format": None, "raw_line": minted_line,
                }
                steps_raw = _ABSENT  # sentinel: skip the branches below, already reported

            if steps_raw is _ABSENT:
                pass
            elif steps_raw is None:
                report["rungs"]["L2b_no_exception"] = {
                    "verdict": UNMEASURED,
                    "reason": "'steps=' key not present on the matched [minted] line",
                    "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                    "steps_raw": None, "first_step_name": None, "first_step_status": None,
                    "first_step_detail": None, "detail_format": None, "raw_line": minted_line,
                }
            elif steps_raw == "[]":
                report["rungs"]["L2b_no_exception"] = {
                    "verdict": MEASURED_EMPTY,
                    "reason": "steps=[] — key present, empty list: no step was recorded",
                    "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                    "steps_raw": steps_raw, "first_step_name": None, "first_step_status": None,
                    "first_step_detail": None, "detail_format": None, "raw_line": minted_line,
                }
            else:
                inner = steps_raw[1:-1]  # strip outer [ ]
                entries = split_top_level(inner)
                first_entry = entries[0].strip() if entries else ""
                parsed = parse_step_entry(first_entry)
                if parsed is None:
                    report["rungs"]["L2b_no_exception"] = {
                        "verdict": UNMEASURED,
                        "reason": "could not parse first step entry %r out of steps=%s" % (first_entry, steps_raw),
                        "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                        "steps_raw": steps_raw, "first_step_name": None, "first_step_status": None,
                        "first_step_detail": None, "detail_format": None, "raw_line": minted_line,
                    }
                else:
                    name, status, detail = parsed
                    detail_format = "new (name:status(detail))" if detail is not None else "old (name:status)"
                    verdict = TRUE if status == "success" else FALSE
                    report["rungs"]["L2b_no_exception"] = {
                        "verdict": verdict, "reason": None if verdict == TRUE else "first step status=%r (not 'success')" % (status,),
                        "evidence_file": log_abs, "evidence_key": "[minted] lane=present ... steps=",
                        "steps_raw": steps_raw, "first_step_name": name, "first_step_status": status,
                        "first_step_detail": detail, "detail_format": detail_format, "raw_line": minted_line,
                        "n_steps_entries": len(entries),
                    }
    except Exception as e:
        report["rungs"]["L2b_no_exception"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                                "evidence_file": log_abs, "evidence_key": "steps=",
                                                "steps_raw": None, "first_step_name": None,
                                                "first_step_status": None, "first_step_detail": None,
                                                "detail_format": None}

    # m2: be symmetric with L3 (which reports its decision-row count) — every
    # rung derived from the [minted] line reports how many such lines were in
    # the log and which one (by index) was used.
    for _rung_key in ("L1_registered", "L2a_args_channel", "L2b_no_exception"):
        report["rungs"][_rung_key]["n_minted_lines_seen"] = n_minted_lines
        report["rungs"][_rung_key]["minted_index_used"] = minted_index_used

    # ================= L3 interface calls =================
    try:
        if last_frame is None:
            report["rungs"]["L3_interface_calls"] = {
                "verdict": UNMEASURED, "reason": stream_err,
                "evidence_file": stream_abs, "evidence_key": "respec_history[-1].interface_calls",
                "value": None, "n_decision_rows_in_frame": 0,
            }
        else:
            present, value = tri_get(decision_row, "interface_calls")
            if not present:
                verdict, reason = UNMEASURED, "key 'interface_calls' absent from the decision row"
            elif value is None:
                verdict, reason = UNMEASURED, "'interface_calls' is explicitly null"
            elif isinstance(value, list) and len(value) == 0:
                verdict, reason = MEASURED_EMPTY, None
            elif isinstance(value, list):
                verdict, reason = TRUE, None
            else:
                verdict, reason = FALSE, "'interface_calls' is not a list: %r" % (value,)
            report["rungs"]["L3_interface_calls"] = {
                "verdict": verdict, "reason": reason,
                "evidence_file": stream_abs, "evidence_key": "respec_history[-1].interface_calls",
                "value": value, "n_decision_rows_in_frame": n_decision_rows,
            }
    except Exception as e:
        report["rungs"]["L3_interface_calls"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                                   "evidence_file": stream_abs,
                                                   "evidence_key": "interface_calls", "value": None,
                                                   "n_decision_rows_in_frame": 0}

    # ================= L4 world changed =================
    try:
        if last_frame is None:
            report["rungs"]["L4_world_changed"] = {
                "verdict": UNMEASURED, "reason": stream_err,
                "evidence_file": stream_abs, "evidence_key": "respec_history[-1].world_delta_body",
                "used_field": None, "fallback": False, "components": None,
            }
        else:
            has_body, body_val = tri_get(decision_row, "world_delta_body")
            if has_body:
                used_field = "world_delta_body"
                fallback = False
                value = body_val
            else:
                has_delta, delta_val = tri_get(decision_row, "world_delta")
                if has_delta:
                    used_field = "world_delta"
                    fallback = True
                    value = delta_val
                else:
                    report["rungs"]["L4_world_changed"] = {
                        "verdict": UNMEASURED,
                        "reason": "neither 'world_delta_body' nor 'world_delta' present on the decision row",
                        "evidence_file": stream_abs, "evidence_key": "world_delta_body / world_delta",
                        "used_field": None, "fallback": False, "components": None,
                    }
                    value = _ABSENT

            if value is not _ABSENT:
                if value is None:
                    verdict = UNMEASURED
                    reason = "'%s' is explicitly null" % (used_field,)
                    components = None
                else:
                    is_zero, components = all_numeric_zero(value)
                    unmeasured_axes = unmeasured_leaf_names(value)
                    if is_zero is None:
                        # Shape carries no numeric leaves to compare against zero.
                        # Default-to-unmeasured is the only safe default for an
                        # instrument: a measured negative (e.g. false, {}, a
                        # string) must never render as the strongest positive.
                        verdict = UNMEASURED
                        reason = ("cannot judge zero-ness of '%s': value=%r (type=%s) carries no "
                                  "numeric leaves to compare against zero" % (used_field, value, type(value).__name__))
                    elif is_zero and unmeasured_axes:
                        # B1: every axis we could read is zero, but at least one
                        # axis is explicitly null. "The world did not change" is
                        # NOT what this row says -- the null axis may have moved
                        # (that is exactly the zone-geometry case: five schedule
                        # axes at 0 while the geometry axis is the one that
                        # carries the repair). Never conflate null with 0.
                        verdict = UNMEASURED
                        reason = ("every readable axis of '%s' is zero, but %d axis/axes are "
                                  "explicitly null (not measured): %s -- 'unchanged' cannot be "
                                  "asserted" % (used_field, len(unmeasured_axes),
                                                ", ".join(sorted(unmeasured_axes))))
                    elif is_zero:
                        verdict = MEASURED_ZERO
                        reason = None
                    else:
                        # A non-zero readable axis is a measured positive; a null
                        # elsewhere cannot take that away. Say so, but do not
                        # downgrade the verdict.
                        verdict = TRUE
                        reason = None
                        if unmeasured_axes:
                            reason = ("measured positive; note %d axis/axes are explicitly null "
                                      "(not measured): %s" % (len(unmeasured_axes),
                                                              ", ".join(sorted(unmeasured_axes))))
                if fallback:
                    fallback_note = ("FALLBACK: 'world_delta_body' was not present on the decision row; "
                                      "this is 'world_delta' (schedule/graph level), which is NOT "
                                      "attributable to the minted body specifically.")
                    reason = (reason + " | " + fallback_note) if reason else fallback_note
                report["rungs"]["L4_world_changed"] = {
                    "verdict": verdict, "reason": reason,
                    "evidence_file": stream_abs, "evidence_key": "respec_history[-1].%s" % used_field,
                    "used_field": used_field, "fallback": fallback, "components": components,
                }
    except Exception as e:
        report["rungs"]["L4_world_changed"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                                                 "evidence_file": stream_abs,
                                                 "evidence_key": "world_delta_body / world_delta",
                                                 "used_field": None, "fallback": False, "components": None}

    # ================= BUILD completion =================
    try:
        if log_text is None:
            report["build"] = {"verdict": UNMEASURED, "reason": log_err,
                                "step_num": None, "n_closed": None, "n_total": None, "wall_clock": None}
        else:
            complete = bool(PROJECT_COMPLETE_RE.search(log_text))
            incomplete = bool(PROJECT_INCOMPLETE_RE.search(log_text))
            if complete and not incomplete:
                verdict, reason = "PROJECT COMPLETE!", None
            elif incomplete and not complete:
                verdict, reason = "PROJECT INCOMPLETE!", None
            elif complete and incomplete:
                verdict, reason = UNMEASURED, "both 'PROJECT COMPLETE!' and 'PROJECT INCOMPLETE!' found in log"
            else:
                verdict, reason = UNMEASURED, "neither 'PROJECT COMPLETE!' nor 'PROJECT INCOMPLETE!' found in log"

            step_nums = STEP_NUM_RE.findall(log_text)
            n_closeds = N_CLOSED_RE.findall(log_text)
            n_totals = N_TOTAL_RE.findall(log_text)
            sim_matches = SIM_100_RE.findall(log_text)

            report["build"] = {
                "verdict": verdict, "reason": reason,
                "evidence_file": log_abs,
                "step_num": (int(step_nums[-1]) if step_nums else None),
                "n_closed": (int(n_closeds[-1]) if n_closeds else None),
                "n_total": (int(n_totals[-1]) if n_totals else None),
                "wall_clock": (sim_matches[-1] if sim_matches else None),
                "step_num_measured": bool(step_nums),
                "n_closed_measured": bool(n_closeds),
                "n_total_measured": bool(n_totals),
                "wall_clock_measured": bool(sim_matches),
            }
    except Exception as e:
        report["build"] = {"verdict": UNMEASURED, "reason": "exception: %r" % (e,),
                            "step_num": None, "n_closed": None, "n_total": None, "wall_clock": None}

    # ================= CONTEXT =================
    ctx = {}
    try:
        ctx["ood_line"] = OOD_RE.findall(log_text)[-1] if log_text and OOD_RE.search(log_text) else None
        if ctx["ood_line"] is None:
            ctx["ood_line_reason"] = (log_err if log_text is None
                                       else "no '[ood] ... fired at step' line found in %s" % log_abs)
    except Exception as e:
        ctx["ood_line"] = None
        ctx["ood_line_reason"] = "exception: %r" % (e,)

    try:
        ctx["router_line"] = ROUTER_RE.findall(log_text)[-1] if log_text and ROUTER_RE.search(log_text) else None
        if ctx["router_line"] is None:
            ctx["router_line_reason"] = (log_err if log_text is None
                                          else "no '[router]' line found in %s" % log_abs)
    except Exception as e:
        ctx["router_line"] = None
        ctx["router_line_reason"] = "exception: %r" % (e,)

    try:
        ctx["battery_drawn_line"] = (BATTERY_DRAWN_RE.findall(log_text)[-1]
                                      if log_text and BATTERY_DRAWN_RE.search(log_text) else None)
        if ctx["battery_drawn_line"] is None:
            ctx["battery_drawn_line_reason"] = (log_err if log_text is None
                                                 else "no 'battery drawn at step=' line found in %s" % log_abs)
    except Exception as e:
        ctx["battery_drawn_line"] = None
        ctx["battery_drawn_line_reason"] = "exception: %r" % (e,)

    for field in ("stages", "tool_name", "impl_name", "surface", "expressible"):
        try:
            if record_obj is None:
                ctx[field] = None
                ctx[field + "_status"] = "UNMEASURED: " + (record_err or "record not read")
            else:
                present, value = tri_get(record_obj, field)
                if not present:
                    ctx[field] = None
                    ctx[field + "_status"] = "UNMEASURED: key %r absent from last line of %s" % (field, record_abs)
                elif value is None:
                    ctx[field] = None
                    ctx[field + "_status"] = "UNMEASURED: key %r is explicitly null" % (field,)
                else:
                    ctx[field] = value
                    ctx[field + "_status"] = "measured"
        except Exception as e:
            ctx[field] = None
            ctx[field + "_status"] = "UNMEASURED: exception: %r" % (e,)

    report["context"] = ctx

    return report


# ------------------------------- rendering ---------------------------------

def render_text(report):
    lines = []
    lines.append("=" * 78)
    lines.append("LADDER REPORT — mechanical read (no hand-quoted numbers)")
    lines.append("=" * 78)
    lines.append("")
    lines.append("INPUT FILES (resolved path / exists / mtime UTC):")
    for label in ("log", "record", "stream"):
        f = report["files"][label]
        status = "mtime=%s" % f["mtime_utc"] if f["exists"] else "NOT FOUND"
        lines.append("  %-7s %s  [%s]" % (label, f["path"], status))
    lines.append("")

    def fmt_rung(title, r, extra_lines=None):
        lines.append("-" * 78)
        lines.append("%s: %s" % (title, r["verdict"]))
        if r.get("reason"):
            lines.append("  reason: %s" % r["reason"])
        lines.append("  evidence: %s :: %s" % (r.get("evidence_file"), r.get("evidence_key")))
        if extra_lines:
            for el in extra_lines:
                lines.append("  " + el)

    rg = report["rungs"]

    r = rg["L0_wrote"]
    fmt_rung("L0  wrote", r, ["value=%r" % r.get("value")])

    def _minted_count_line(r):
        return "'[minted] lane=present' lines seen in log: %d (using index %s, i.e. the last)" % (
            r.get("n_minted_lines_seen", 0), r.get("minted_index_used"))

    r = rg["L1_registered"]
    fmt_rung("L1  registered", r, [
        "registered=%r  impl_rejected_why=%r" % (r.get("registered"), r.get("impl_rejected_why")),
        _minted_count_line(r),
    ])

    r = rg["L2a_args_channel"]
    fmt_rung("L2a args channel", r, [
        "args_from=%r  n_calls=%r" % (r.get("args_from"), r.get("n_calls")),
        _minted_count_line(r),
    ])

    r = rg["L2b_no_exception"]
    extra = ["steps=%r" % r.get("steps_raw")]
    if r.get("first_step_name") is not None:
        extra.append("first_step: name=%r status=%r detail=%r (format: %s)" % (
            r.get("first_step_name"), r.get("first_step_status"),
            r.get("first_step_detail"), r.get("detail_format")))
    extra.append(_minted_count_line(r))
    fmt_rung("L2b no exception (first step)", r, extra)

    r = rg["L3_interface_calls"]
    fmt_rung("L3  interface calls", r, [
        "interface_calls=%r" % (r.get("value"),),
        "decision rows in this frame's respec_history: %d (using the last)" % r.get("n_decision_rows_in_frame", 0),
    ])

    r = rg["L4_world_changed"]
    extra = ["used_field=%r  fallback=%s" % (r.get("used_field"), r.get("fallback"))]
    if r.get("components") is not None:
        for k, v in r["components"]:
            extra.append("  component %s = %r" % (k, v))
    fmt_rung("L4  world changed", r, extra)

    lines.append("-" * 78)
    b = report["build"]
    lines.append("BUILD completion: %s" % b["verdict"])
    if b.get("reason"):
        lines.append("  reason: %s" % b["reason"])
    lines.append("  step_num=%r  n_closed=%r  n_total=%r  (each: last occurrence in log)" % (
        b.get("step_num"), b.get("n_closed"), b.get("n_total")))
    lines.append("  wall_clock (Simulating...100%% line)=%r" % b.get("wall_clock"))

    lines.append("-" * 78)
    c = report["context"]
    lines.append("CONTEXT:")
    lines.append("  [ood] line:     %s" % (c.get("ood_line") or ("(absent: %s)" % c.get("ood_line_reason"))))
    lines.append("  [router] line:  %s" % (c.get("router_line") or ("(absent: %s)" % c.get("router_line_reason"))))
    lines.append("  battery drawn:  %s" % (c.get("battery_drawn_line") or ("(absent: %s)" % c.get("battery_drawn_line_reason"))))
    for field in ("stages", "tool_name", "impl_name", "surface", "expressible"):
        lines.append("  record.%-12s = %r  [%s]" % (field, c.get(field), c.get(field + "_status")))

    lines.append("=" * 78)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Mechanically read the 5-rung ladder from run artifacts.")
    ap.add_argument("--log", required=True, help="path to the run log (stdout+stderr text)")
    ap.add_argument("--stream", default="tools/monitor/streams/tractor__battery_mild.jsonl",
                     help="monitor stream JSONL (default: %(default)s)")
    ap.add_argument("--record", default="results/synth_lane_records.jsonl",
                     help="synthesis record JSONL (default: %(default)s)")
    ap.add_argument("--json", action="store_true", help="print machine-readable JSON instead of a table")
    args = ap.parse_args()

    report = build_report(args.log, args.stream, args.record)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False, default=str))
    else:
        print(render_text(report))


if __name__ == "__main__":
    main()
