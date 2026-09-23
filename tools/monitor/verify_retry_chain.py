#!/usr/bin/env python3
"""verify_retry_chain.py — 재시도 사슬 검증기 (Task 6, 2026-09-22).

render_demo 스트림의 결정·되먹임 칸을 합성 원장 행과 `(record_id, response_id)` 로 조인해,
"스트림이 받았다고 말하는 응답" 과 "서비스가 원장에 남긴 행" 이 같은 것인지 잰다.

무엇을 읽는가 (경로는 생산자 코드에서 확인했다)
-----------------------------------------------
  스트림  마지막 정상 프레임(`src/monitor/monitor.jl` `monitor_emit!`)의 `respec_history`
          (없으면 `respec` 하나를 명시적으로). 결정 행 = `monitor_record_respec!` 의 dict.
          · 결정의 신원: `input.policies.dspy.record_id` / `.response_id`
            (`policy.jl` `policy_entry` 가 `_synth_view` 로 `synthesis` 에서 뽑는다).
            `policies` 에 `dspy` 가 없으면(canonical·surrogate·noop·oracle·dp) /decide 합성을
            안 탄 결정이다 → **해당 없음**.
          · 되먹임 칸: 결정 행의 `attempts[i]` (`tools/monitor/enact.jl` `_open_attempt!`,
            `_rewrite_once` 가 제자리에 채운다).
  원장    `synthesize.stamp_record` 가 찍은 v2 행(`ledger_version == 2`, `row_type` ∈
          decide|rewrite). `/decide` 행 = `dspy_service._append_decide_row`, `/rewrite` 행 =
          `dspy_service.rewrite`.

판정 규약
---------
  · 원장은 `(record_id, response_id)` 로 색인하고 **모든 행을 보존한다**. 같은 복합 키에 다른
    내용이 있으면 충돌(문제)이다. 같은 `record_id` 의 다른 응답(HTTP 재전송)은 `duplicates` 로
    센다 — 받은 응답은 스트림의 `response_id` 가 특정한다(append 순서·last-wins 를 안 쓴다).
  · v1/ID 없는 행은 `legacy_rows`·`v2_rows_without_id` 로 따로 세고 증거로 안 쓴다.
  · 원장의 JSON 파싱 오류는 **절대 건너뛰지 않는다**(exit 2). 쓰기 중인 끝줄과 혼동하지 않도록
    서비스를 멈춘 뒤의 **사본**으로 검증하라.
  · 스트림의 잘린 마지막 줄은 앞 프레임으로 진단하되 **합격시키지 않는다**(문제로 센다).
  · `roundtrip == "ok"` 인 칸만 원장 행을 요구한다(`attempt_joined == roundtrip_ok`).
    `failed:*` 는 서버 도달 여부를 모르므로 행이 없어도 문제가 아니다 — 있으면 보고한다.
  · 부모 없음(`parent_record_id == null`)은 `run_ctx.synth_fixture` 가 비어 있지 않고
    `--allow-fixture-parent` 가 **둘 다** 있을 때만 허용한다.
  · 캐시는 조인된 행의 **원시 LM 항목 하나하나**의 `cache_hit` 로 센다(True/False/그 밖=unknown).
    🔴 이것은 과금 호출 수가 **아니다** — macro(SelectTool)·adapter·provider 재시도는 원시
    응답에 없고, 캐시 재생도 항목 하나로 보인다.
  · 결정도 되먹임도 없는 판은 `verdict = "not_applicable"`(exit 0) — 라이브 게이트는
    `--require-decisions` / `--require-attempts` 로 무검증 통과를 막는다(조인된 수로 잰다).

Exit: 0 성공 · 1 증거/계약 위반 · 2 입력 부재·파싱 불가.

사용법:
    python3 tools/monitor/verify_retry_chain.py <stream.jsonl> [<ledger.jsonl>]
        [--require-decisions N] [--require-attempts N] [--allow-fixture-parent]
        [--health-json /health.json]
    <ledger> 생략 시: $SYNTH_RECORD_LOG (비었거나 "0" 이 아니면) → results/synth_lane_records.jsonl
    🔴 스트림은 render_demo 가 쓴 **원래 이름**으로 둘 것 — `run_ctx.stream` 과 대조한다.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_LEDGER = os.path.join(REPO, "results", "synth_lane_records.jsonl")
LEDGER_VERSION = 2
EXIT_OK, EXIT_VIOLATION, EXIT_INPUT = 0, 1, 2

# 스트림 dspy 칸의 키 → decide 행(= synthesis 기록 사본)의 키. `policy.jl` `_SYNTH_RENAME` 대로
# ran→synthesis_ran, error→synthesis_error. `tool_minted` 는 응답 최상위에서 오므로 뺐다.
DECIDE_FIELDS = (("impl_name", "impl_name"), ("impl_code", "impl_code"), ("params", "params"),
                 ("calls", "calls"), ("wrote", "wrote"), ("synthesis_error", "error"),
                 ("tool_name", "tool_name"), ("mechanism", "mechanism"),
                 ("body_names", "body_names"), ("surface", "surface"),
                 ("reversible", "reversible"), ("refused", "refused"),
                 ("synthesis_ran", "ran"), ("synthesis_event", "synthesis_event"))
# 되먹임 칸의 키 → rewrite 행의 키. `why` 는 전선의 `impl_rejected_why` 그대로다(`_rewrite_once`).
REWRITE_FIELDS = (("impl_name", "impl_name"), ("impl_code", "impl_code"), ("params", "params"),
                  ("calls", "calls"), ("wrote", "wrote"), ("service_error", "error"),
                  ("why", "impl_rejected_why"))


class InputError(Exception):
    """입력 부재·파싱 불가 → exit 2."""


def resolve_ledger_path(arg, env=None):
    """(경로, 출처). 출처 ∈ argument | env:SYNTH_RECORD_LOG | default.

    서비스(`synthesize.append_synthesis_record`)와 같은 규약: 비었거나 "0" 인 env 는 sink 가
    꺼졌다는 뜻이므로 기본 경로로 간다. 🔴 서비스는 `src/respec/llm_service` 에서 뜨므로 env 의
    **상대** 경로는 거기 기준이다 — 절대 경로를 쓸 것.
    """
    env = os.environ if env is None else env
    if arg:
        return arg, "argument"
    v = env.get("SYNTH_RECORD_LOG")
    if v is not None and v.strip() not in ("", "0"):
        return v, "env:SYNTH_RECORD_LOG"
    return DEFAULT_LEDGER, "default"


def read_final_frame(path):
    """(frame, n_frames, truncated). 잘린 끝줄이면 앞 프레임을 돌려주고 truncated=True."""
    if not os.path.isfile(path):
        raise InputError("stream not found: %s" % path)
    n, prev, last = 0, None, None
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            if line.strip():
                n += 1
                prev, last = last, (i, line)
    if last is None:
        raise InputError("stream is empty (no frames): %s" % path)
    truncated = False
    try:
        frame = json.loads(last[1])
    except ValueError as e:
        truncated = True
        if prev is None:
            raise InputError("stream's only line %d is not JSON (%s)" % (last[0], e))
        try:
            frame = json.loads(prev[1])
        except ValueError as e2:
            raise InputError("stream's last two lines (%d, %d) are not JSON (%s)"
                             % (prev[0], last[0], e2))
    if not isinstance(frame, dict):
        raise InputError("stream's final frame is not a JSON object")
    return frame, n, truncated


def load_ledger(path):
    """[(line_no, row)]. 파싱 오류는 **어느 줄이든** InputError 다(조용히 안 건너뛴다)."""
    if not os.path.isfile(path):
        raise InputError("ledger not found: %s" % path)
    rows = []
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except ValueError as e:
                tail = ("" if line.endswith("\n") else
                        " — the LAST line has no newline: a ledger still being written? "
                        "verify a copy taken after the service stopped")
                raise InputError("ledger line %d is not JSON (%s)%s" % (i, e, tail))
            if not isinstance(obj, dict):
                raise InputError("ledger line %d is not a JSON object" % i)
            rows.append((i, obj))
    return rows


def _ctx_key(ctx):
    return json.dumps(ctx, sort_keys=True, ensure_ascii=False)


def _count_cache(row, acc):
    raw = row.get("raw_lm")
    if not isinstance(raw, dict):
        return
    for entries in raw.values():
        for e in entries if isinstance(entries, list) else []:
            h = e.get("cache_hit") if isinstance(e, dict) else None
            acc["cache_hits" if h is True else "cache_misses" if h is False
                else "cache_unknown"] += 1


def verify(stream, ledger_path, *, require_decisions=0, require_attempts=0,
           allow_fixture_parent=False, health=None):
    """요약 dict 을 돌려준다(`problems` 가 비면 합격). 입력 오류는 InputError."""
    frame, n_frames, truncated = read_final_frame(stream)
    ledger = load_ledger(ledger_path)
    stream_name = os.path.basename(stream)
    problems, warnings = [], []
    S = {"stream": stream, "stream_frames": n_frames, "stream_truncated_last_line": truncated,
         "ledger_rows": len(ledger), "history_source": None,
         "decisions": 0, "decisions_total": 0, "decisions_not_applicable": 0,
         "decide_joined": 0, "attempts": 0, "roundtrip_ok": 0, "roundtrip_failed": 0,
         "not_requested": 0, "skipped_not_rewritable": 0, "attempt_joined": 0,
         "parent_ok": 0, "parent_fixture_allowed": 0, "code_equal": 0, "duplicates": 0,
         "cache_hits": 0, "cache_misses": 0, "cache_unknown": 0,
         "legacy_rows": 0, "v2_rows_without_id": 0, "transport_failed": []}
    if truncated:
        problems.append("stream_truncated: the last line is not JSON; diagnosed from the "
                        "previous frame, never a pass")

    # ---- 원장 색인 -------------------------------------------------------------------------
    index, by_rid, v2 = {}, {}, []
    for ln, r in ledger:
        if r.get("ledger_version") != LEDGER_VERSION or r.get("row_type") not in ("decide",
                                                                                 "rewrite"):
            S["legacy_rows"] += 1
            continue
        rid, resp = r.get("record_id"), r.get("response_id")
        if not rid or not resp:
            S["v2_rows_without_id"] += 1
            continue
        v2.append((ln, r))
        index.setdefault((rid, resp), []).append((ln, r))
        by_rid.setdefault(rid, []).append((ln, r))
    for key, hits in index.items():
        if len(hits) > 1:
            bodies = {json.dumps(r, sort_keys=True, ensure_ascii=False) for _, r in hits}
            if len(bodies) > 1:
                problems.append("ledger_key_conflict: %s/%s has %d rows with different "
                                "content (lines %s)" % (key[0], key[1], len(hits),
                                                        [ln for ln, _ in hits]))

    def one(key):
        hits = index.get(key)
        return hits[0][1] if hits else None

    joined = []                      # 조인된 원장 행(run_ctx 대조·캐시·orphan 범위)
    received = set()                 # 스트림이 받았다고 말하는 복합 키

    def check_ctx(r, what):
        ctx = r.get("run_ctx")
        if not isinstance(ctx, dict) or not ctx:
            problems.append("run_ctx_bad: %s row run_ctx is empty" % what)
        elif ctx.get("stream") != stream_name:
            problems.append("run_ctx_bad: %s row run_ctx.stream=%r != stream %r"
                            % (what, ctx.get("stream"), stream_name))

    # ---- 결정 이력 -------------------------------------------------------------------------
    hist = frame.get("respec_history")
    if isinstance(hist, list):
        S["history_source"] = "respec_history"
    elif hist is None and isinstance(frame.get("respec"), dict):
        hist, S["history_source"] = [frame["respec"]], "respec"
    else:
        hist = []
        problems.append("no_history: final frame has neither a respec_history list nor a "
                        "respec decision")

    seen_ids = set()
    for di, dec in enumerate(hist):
        S["decisions_total"] += 1
        if not isinstance(dec, dict):
            problems.append("decision_bad: history[%d] is not an object" % di)
            continue
        pols = (dec.get("input") or {}).get("policies") or {}
        dspy = pols.get("dspy") if isinstance(pols, dict) else None
        dkey = None
        if not isinstance(dspy, dict):
            S["decisions_not_applicable"] += 1
        else:
            S["decisions"] += 1
            dkey = (dspy.get("record_id"), dspy.get("response_id"))
            if not dkey[0] or not dkey[1]:
                problems.append("decision_id_missing: history[%d] dspy lane has record_id=%r "
                                "response_id=%r" % (di, dkey[0], dkey[1]))
                dkey = None
            elif dkey in seen_ids:
                problems.append("stream_duplicate_id: decision %s/%s appears twice" % dkey)
            else:
                seen_ids.add(dkey)
                received.add(dkey)
                r = one(dkey)
                if r is None:
                    others = [x.get("response_id") for _, x in by_rid.get(dkey[0], [])]
                    problems.append("decide_row_missing: %s/%s (other responses for this "
                                    "record_id in ledger: %s)" % (dkey[0], dkey[1], others))
                else:
                    bad = [f for f, want in (("row_type", "decide"), ("attempt", 1),
                                             ("trigger", "first")) if r.get(f) != want]
                    if bad:
                        problems.append("decide_row_mismatch: %s/%s %s" % (
                            dkey[0], dkey[1], ", ".join("%s=%r" % (f, r.get(f)) for f in bad)))
                    else:
                        S["decide_joined"] += 1
                        joined.append(r)
                        check_ctx(r, "decide")
                        diff = [sk for sk, lk in DECIDE_FIELDS if dspy.get(sk) != r.get(lk)]
                        if diff:
                            problems.append("decide_content_mismatch: %s/%s differs in %s"
                                            % (dkey[0], dkey[1], diff))

        atts = dec.get("attempts", [])
        if not isinstance(atts, list):
            problems.append("attempts_bad: history[%d].attempts is not a list" % di)
            continue
        for ai, a in enumerate(atts):
            S["attempts"] += 1
            where = "history[%d].attempts[%d]" % (di, ai)
            if not isinstance(a, dict):
                problems.append("attempt_bad: %s is not an object" % where)
                continue
            rt, rid, resp = a.get("roundtrip"), a.get("record_id"), a.get("response_id")
            row = None
            if rt is None:
                problems.append("attempt_open: %s roundtrip is null (opened, never filled)"
                                % where)
                continue
            if rt in ("not_requested", "skipped_not_rewritable"):
                S[rt] += 1
                if rid is not None:
                    problems.append("attempt_id_off_wire: %s is %s but carries record_id %r"
                                    % (where, rt, rid))
                continue
            if not (rt == "ok" or (isinstance(rt, str) and rt.startswith("failed:"))):
                problems.append("attempt_bad: %s roundtrip=%r" % (where, rt))
                continue
            if not rid:
                problems.append("attempt_id_missing: %s went on the wire without record_id"
                                % where)
                continue
            if rid in seen_ids:
                problems.append("stream_duplicate_id: attempt record_id %s appears twice" % rid)
            seen_ids.add(rid)
            if rt == "ok":
                S["roundtrip_ok"] += 1
                if not resp:
                    problems.append("attempt_id_missing: %s roundtrip ok but response_id "
                                    "is null" % where)
                else:
                    received.add((rid, resp))
                    row = one((rid, resp))
                    if row is None:
                        others = [x.get("response_id") for _, x in by_rid.get(rid, [])]
                        problems.append("rewrite_row_missing: %s/%s (other responses for this "
                                        "record_id in ledger: %s)" % (rid, resp, others))
                    else:
                        bad = [f for f, want in (
                            ("row_type", "rewrite"), ("attempt", a.get("attempt")),
                            ("trigger", a.get("trigger")),
                            ("parent_record_id", a.get("parent_record_id")))
                            if row.get(f) != want]
                        if bad:
                            problems.append("rewrite_row_mismatch: %s/%s %s" % (
                                rid, resp, ", ".join("%s=%r (stream %r)" % (
                                    f, row.get(f), a.get(f) if f != "row_type" else "rewrite")
                                    for f in bad)))
                            row = None
                        else:
                            S["attempt_joined"] += 1
                            joined.append(row)
                            check_ctx(row, "rewrite")
                            if a.get("impl_code") == row.get("impl_code"):
                                S["code_equal"] += 1
                            diff = [sk for sk, lk in REWRITE_FIELDS
                                    if a.get(sk) != row.get(lk)]
                            if diff:
                                problems.append("rewrite_content_mismatch: %s/%s differs in %s"
                                                % (rid, resp, diff))
            else:
                S["roundtrip_failed"] += 1
                rids = [x.get("response_id") for _, x in by_rid.get(rid, [])]
                S["transport_failed"].append({"record_id": rid, "ledger_response_ids": rids})
                if rids:
                    warnings.append("transport_failed_with_rows: %s — the server processed %d "
                                    "request(s) whose response the client never received"
                                    % (rid, len(rids)))

            # -- 부모: 이 칸이 고치는 /decide 응답 --------------------------------------------
            pkey = (a.get("parent_record_id"), a.get("parent_response_id"))
            if pkey[0] is None:
                ctxs = [row.get("run_ctx")] if row is not None else \
                       [x.get("run_ctx") for _, x in by_rid.get(rid, [])]
                fixture = any(isinstance(c, dict) and c.get("synth_fixture") for c in ctxs)
                if dkey is None and dspy is None and fixture and allow_fixture_parent:
                    S["parent_fixture_allowed"] += 1
                else:
                    problems.append(
                        "parent_missing: %s has no parent_record_id (dspy decision=%s, "
                        "run_ctx.synth_fixture=%s, --allow-fixture-parent=%s)"
                        % (where, dspy is not None, fixture, allow_fixture_parent))
            elif pkey != dkey:
                problems.append("parent_mismatch: %s parent %s/%s is not this decision's "
                                "dspy response %s" % (where, pkey[0], pkey[1], dkey))
            else:
                p = one(pkey)
                if p is None or p.get("row_type") != "decide":
                    problems.append("parent_row_missing: %s parent %s/%s has no decide row"
                                    % (where, pkey[0], pkey[1]))
                else:
                    S["parent_ok"] += 1

    # ---- 불변식 · 판 신원 · 요구 수 ------------------------------------------------------------
    if S["decide_joined"] != S["decisions"]:
        problems.append("decide_joined_ne_decisions: %d != %d"
                        % (S["decide_joined"], S["decisions"]))
    if S["attempt_joined"] != S["roundtrip_ok"]:
        problems.append("attempt_joined_ne_roundtrip_ok: %d != %d"
                        % (S["attempt_joined"], S["roundtrip_ok"]))
    ctx_set = {_ctx_key(r.get("run_ctx")) for r in joined}
    if len(ctx_set) > 1:
        problems.append("run_ctx_bad: joined rows carry %d different run_ctx" % len(ctx_set))
    if S["decide_joined"] < require_decisions:
        problems.append("require_decisions: decide_joined %d < %d"
                        % (S["decide_joined"], require_decisions))
    if S["attempt_joined"] < require_attempts:
        problems.append("require_attempts: attempt_joined %d < %d"
                        % (S["attempt_joined"], require_attempts))

    # ---- 중복 · orphan(R10) · 캐시 ---------------------------------------------------------
    rec_ids = {k[0] for k in received}
    S["duplicates"] = sum(max(0, len(by_rid.get(r, [])) - len({k for k in received
                                                               if k[0] == r}))
                          for r in rec_ids if by_rid.get(r))
    if ctx_set:
        in_scope = lambda r: (_ctx_key(r.get("run_ctx")) in ctx_set  # noqa: E731
                              or r.get("record_id") in rec_ids)
        S["orphan_scope"] = "joined_run_ctx"
    else:
        in_scope = lambda r: (isinstance(r.get("run_ctx"), dict)  # noqa: E731
                              and r["run_ctx"].get("stream") == stream_name
                              or r.get("record_id") in rec_ids)
        S["orphan_scope"] = "stream_name"
    orphans, foreign = [], 0
    for ln, r in v2:
        if not in_scope(r):
            foreign += 1
        elif (r["record_id"], r["response_id"]) not in received:
            orphans.append({"line": ln, "row_type": r.get("row_type"),
                            "record_id": r["record_id"], "response_id": r["response_id"],
                            "decide_outcome": r.get("decide_outcome")})
    S["orphans"] = {"count": len(orphans), "keys": orphans}
    S["foreign_rows"] = foreign
    for r in joined:
        _count_cache(r, S)

    # ---- /health (R9) ----------------------------------------------------------------------
    laf = None if health is None else health.get("ledger_append_failures")
    if health is not None and laf is None:
        warnings.append("ledger_append_failures: key absent from /health — unknown, not 0 "
                        "(service older than Task 3?)")
    elif health is None:
        warnings.append("ledger_append_failures: unknown (no --health-json given)")
    elif not isinstance(laf, int) or isinstance(laf, bool) or laf > 0:
        problems.append("ledger_append_failures: /health reports %r lost ledger row(s)" % (laf,))
    S["ledger_append_failures"] = laf

    S["problems"], S["warnings"] = problems, warnings
    S["verdict"] = ("fail" if problems else
                    "not_applicable" if S["decisions"] == 0 and S["attempts"] == 0 else "ok")
    return S


def run(argv=None):
    """(exit code, 요약 dict). CLI 와 시험이 같은 문을 쓴다."""
    ap = argparse.ArgumentParser(
        description="Join a render_demo stream's decisions/retry attempts to the synthesis "
                    "ledger by (record_id, response_id). Cache counts are per raw LM entry "
                    "and are NOT billed calls. Exit 0 ok, 1 violation, 2 missing/unparseable.")
    ap.add_argument("stream")
    ap.add_argument("ledger", nargs="?", default=None,
                    help="default: $SYNTH_RECORD_LOG (unless empty/'0'), else "
                         "results/synth_lane_records.jsonl; use a copy taken after the "
                         "service stopped")
    ap.add_argument("--require-decisions", type=int, default=0, metavar="N",
                    help="fail unless at least N dspy decisions joined their decide row")
    ap.add_argument("--require-attempts", type=int, default=0, metavar="N",
                    help="fail unless at least N roundtrip-ok attempts joined their rewrite row")
    ap.add_argument("--allow-fixture-parent", action="store_true",
                    help="accept a null parent_record_id when the row's run_ctx.synth_fixture "
                         "is non-empty (DEMO_SYNTH_FIXTURE run)")
    ap.add_argument("--health-json", default=None, metavar="PATH",
                    help="saved /health JSON; ledger_append_failures > 0 fails the run")
    a = ap.parse_args(argv)
    ledger_path, source = resolve_ledger_path(a.ledger)
    head = {"ledger_path": ledger_path, "ledger_source": source}
    try:
        health = None
        if a.health_json is not None:
            try:
                with open(a.health_json, encoding="utf-8") as fh:
                    health = json.load(fh)
            except (OSError, ValueError) as e:
                raise InputError("health json unreadable: %s (%s)" % (a.health_json, e))
            if not isinstance(health, dict):
                raise InputError("health json is not an object: %s" % a.health_json)
        s = verify(a.stream, ledger_path, require_decisions=a.require_decisions,
                   require_attempts=a.require_attempts,
                   allow_fixture_parent=a.allow_fixture_parent, health=health)
    except InputError as e:
        return EXIT_INPUT, dict(head, verdict="input_error", error=str(e))
    s = dict(head, **s)
    return (EXIT_VIOLATION if s["problems"] else EXIT_OK), s


def main(argv=None):
    code, s = run(argv)
    print(json.dumps(s, ensure_ascii=False, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
