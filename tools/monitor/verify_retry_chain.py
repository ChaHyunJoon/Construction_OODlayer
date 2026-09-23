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
  · 부모 없음(`parent_record_id == null`)은 픽스처 표식(원장 행의 `run_ctx.synth_fixture`,
    또는 스트림 결정 행의 `input.router.synth_fixture.path` — R11)과 `--allow-fixture-parent`
    가 **둘 다** 있을 때만 허용한다.
  · 두 입력은 바이너리로 읽어 줄마다 UTF-8 로 디코드한다: 문자 중간에서 끊긴 끝줄은 스트림이면
    잘린 줄 진단(exit 1), 원장이면 exit 2 이고, 가운데 줄의 깨진 UTF-8 은 어느 쪽이든 exit 2 다.
  · 캐시는 조인된 행의 **원시 LM 항목 하나하나**의 `cache_hit` 로 센다(True/False/그 밖=unknown).
    🔴 이것은 과금 호출 수가 **아니다** — macro(SelectTool)·adapter·provider 재시도는 원시
    응답에 없고, 캐시 재생도 항목 하나로 보인다.
    ⚠️ `cache_misses` 는 라이브에서 사실상 늘 0 이다: dspy 3.3 은 캐시 히트에만 응답 객체에
    `cache_hit=True` 를 붙이고(`dspy/clients/cache.py` — 같은 자리에서 `usage = {}` 로 비운다),
    litellm 의 라이브 응답에는 그 속성이 **없다** → `lm_raw` 가 `None` 을 싣고 라이브 호출은
    `cache_unknown` 에 떨어진다. 그래서 따로 `raw_lm_live` = "`cache_hit` 가 True 가 아니고
    `usage` 가 비지 않은 항목" 을 센다 — **라이브였을 공산이 큰 항목**이지 과금 수가 아니다.
  · 원시 LM 항목이 **있어야 하는** 조인 행은 **완료된 단계마다** 유효 항목(dict · `error` 없음 ·
    `outputs` 가 비지 않은 list)을 그 단계가 `stages` 에 나온 횟수 이상 가져야 한다(Task 6a,
    2026-09-23 R-A). 모자라면 `raw_lm_missing:<record_id>:<stage>:need=N:got=M` 문제다 —
    한 단계만 빠지거나 항목이 `{}` 로 비어도 게이트가 통과하던 구멍을 막는다. 요구 밖 단계
    (실패한 단계)의 항목은 `raw_lm_unrequired` 경고로 보고만 한다. `stages` 가 없는 행은 출구가
    함의하는 최소 단계를 요구한다. 요약: `raw_stage_checked` · `raw_stage_short`.
    요구 조건은 **서비스 코드가 LM 을 부른 것이 확실한** 경우로만 좁힌다:
      - rewrite 행: `wrote ∈ (True, False)` — `rewrite_impl` 은 프로그램 호출이 **돌아온 뒤에만**
        `wrote` 를 bool 로 채운다(예외면 `None`).
      - decide 행: `decide_outcome ∈ RAW_REQUIRED_OUTCOMES`(= synthesis_ran · synthesis_not_fired),
        또는 synthesis_failed 이면서 `stages` 가 비지 않은 행. `synthesize_multi` 는 단계 호출이
        **성공한 뒤에만** `stages` 에 이름을 더한다 — not_fired 는 observe·design 이 돌아왔고
        (agent-2 가 expressible≠False 라 답했다), ran 은 셋 다 돌아왔다. synthesis_failed 는
        첫 단계(observe)에서 LM 호출 자체가 던질 수 있어 빈 항목이 정당하다(`stages == []`).
        no_tools · no_call_* · synthesis_disabled · synthesis_refused · raised 는 합성 단계를
        안 탔으므로(`raw_lm` 은 합성 단계 것뿐 — `dspy_service.macro` docstring) 요구하지 않는다.
  · `--expect-ctx KEY=VALUE`(반복 가능): 조인된 모든 행의 `run_ctx[KEY]` 가 VALUE 와 같아야
    한다(`run_ctx_mismatch`). 비교는 문자열로 한다 — 문자열 값은 그대로, 그 밖(수·bool·null)은
    `json.dumps` 로(예: `seed=1`, `zone=true`, `synth_fixture=`). 키가 없어도 문제다.
  · `steps_ref == "respec.steps"` 인 되먹임 칸은 그 결정 행의 `steps` 가 비지 않은 리스트여야
    한다(`steps_ref_dangling`, R12) — 포인터가 가리키는 걸음이 없으면 재집행 증거가 없다.
    예외 하나: `steps == []` 이고 **뒤 칸**이 `trigger == "prerun"` 이면 설치된 body 가 집행
    전에 거절된 판이라(`refused_budget_spent`) 빈 걸음이 참이다 → `steps_ref_prerun_rejected`.
  · 🔴 **dspy 레인 스트림은 같은 시드로도 바이트 재현되지 않는다.** 결정의 `policies.dspy` 와
    `attempts` 칸에 판마다 새로 발급되는 `record_id` · `response_id` · `parent_record_id` ·
    `parent_response_id` 가 실리기 때문이다(줄리아 `new_record_id` 는 시각·pid 해시, 서버
    `response_id` 는 uuid4). 두 스트림의 md5/바이트 동일성으로 "같은 판" 을 진단하려면 먼저 그
    네 키(와 그 밖의 attempt id)를 지운 사본을 비교할 것 — memory `tractor-battery-fault-cells-
    are-one-run-copied` 류의 진단이 이 키 때문에 거짓 "다르다" 를 낸다.
  · 결정도 되먹임도 없는 판은 `verdict = "not_applicable"`(exit 0) — 라이브 게이트는
    `--require-decisions` / `--require-attempts` 로 무검증 통과를 막는다(조인된 수로 잰다).

Exit: 0 성공 · 1 증거/계약 위반 · 2 입력 부재·파싱 불가.

사용법:
    python3 tools/monitor/verify_retry_chain.py <stream.jsonl> [<ledger.jsonl>]
        [--require-decisions N] [--require-attempts N] [--allow-fixture-parent]
        [--health-json /health.json] [--expect-ctx KEY=VALUE ...]
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
# 원시 LM 항목이 **반드시** 있어야 하는 decide 출구(모듈 docstring "raw_lm_missing").
# synthesis_failed 는 `stages` 가 비지 않을 때만 요구한다(첫 단계 호출이 던지면 빈 것이 정당).
RAW_REQUIRED_OUTCOMES = ("synthesis_ran", "synthesis_not_fired")
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


_WRITING = (" — the LAST line has no newline: a file still being written? "
            "verify a copy taken after the writer stopped")


def _decode(raw, what, i, last):
    """바이트 한 줄 → str. 깨진 UTF-8 은 InputError 다(쓰기 중이면 문자 중간에서 끊긴다).

    🔴 파일을 **바이너리로** 읽고 여기서 디코드한다 — 텍스트 모드로 순회하면
    `UnicodeDecodeError` 가 순회 도중(= 어느 `try` 밖)에서 나서 traceback·JSON 없음으로 죽는다.
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise InputError("%s line %d is not UTF-8 (%s)%s"
                         % (what, i, e, _WRITING if last else ""))


def read_final_frame(path):
    """(frame, n_frames, truncated). 잘린 끝줄이면 앞 프레임을 돌려주고 truncated=True.

    모든 줄을 UTF-8 로 디코드한다(가운데 줄이 깨졌으면 exit 2). JSON 은 끝 두 줄만 읽는다 —
    정본은 마지막 프레임이고 큰 스트림 전체를 파싱할 이유가 없다.
    """
    if not os.path.isfile(path):
        raise InputError("stream not found: %s" % path)
    n, prev, last = 0, None, None
    pending = None                    # 디코드 실패한 줄 — 뒤에 줄이 더 오면 가운데 줄이다
    with open(path, "rb") as fh:
        for i, raw in enumerate(fh, 1):
            if not raw.strip():
                continue
            if pending is not None:
                _decode(pending[1], "stream", pending[0], last=False)   # 반드시 던진다
            n += 1
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                pending, text = (i, raw), None
            prev, last = last, (i, text)
    if last is None:
        raise InputError("stream is empty (no frames): %s" % path)
    truncated = False
    try:
        if last[1] is None:
            raise ValueError("line cut inside a multibyte UTF-8 character")
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
    """[(line_no, row)]. 디코드·파싱 오류는 **어느 줄이든** InputError 다(조용히 안 건너뛴다)."""
    if not os.path.isfile(path):
        raise InputError("ledger not found: %s" % path)
    rows = []
    with open(path, "rb") as fh:
        for i, raw in enumerate(fh, 1):
            if not raw.strip():
                continue
            last = not raw.endswith(b"\n")
            line = _decode(raw, "ledger", i, last)
            try:
                obj = json.loads(line)
            except ValueError as e:
                raise InputError("ledger line %d is not JSON (%s)%s"
                                 % (i, e, _WRITING if last else ""))
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
            # 라이브였을 공산: 캐시 히트가 아니고 usage 가 비지 않았다(히트는 usage={}).
            if isinstance(e, dict) and h is not True and e.get("usage"):
                acc["raw_lm_live"] += 1


def _valid_raw(e):
    """유효한 원시 LM 항목: dict · `error` 키 없음 · `outputs` 가 비지 않은 list (Task 6a, R-A).

    `{}` · `{"outputs": []}` · `{"error": ...}` 는 LM 응답을 담지 않았으므로 증거가 아니다.
    """
    return (isinstance(e, dict) and "error" not in e
            and isinstance(e.get("outputs"), list) and bool(e["outputs"]))


def _raw_valid_count(row, stage):
    raw = row.get("raw_lm")
    entries = raw.get(stage) if isinstance(raw, dict) else None
    return sum(1 for e in entries if _valid_raw(e)) if isinstance(entries, list) else 0


# `stages` 가 없는(옛·손상) 행이 LM 을 부른 것이 확실할 때 출구가 함의하는 최소 단계.
_OUTCOME_MIN_STAGES = {"synthesis_ran": ["observe", "design", "compose"],
                       "synthesis_not_fired": ["observe", "design"]}


def _raw_required(row):
    """{단계: 필요한 유효 항목 수}. 빈 dict 면 요구하지 않는다(서비스가 LM 을 부른 것이
    확실한 경우만 요구한다 — 모듈 docstring "raw_lm_missing").

    decide 행: `stages` 의 단계 s 마다 **등장 횟수**만큼 — redesign 은 "design" 을, recompose
    는 "compose" 를 한 번 더 남기고(`synthesize_multi`) 같은 프로그램 객체를 다시 불러 history
    가 쌓이므로(`run_synthesis` 의 `raw_out`) 반복 호출도 이 규칙으로 센다. 실패한 단계는
    `stages` 에 append 되기 전에 돌아오므로 요구하지 않는다.
    rewrite 행: `wrote ∈ {True, False}` 이면 `rewrite` 에 1개.
    """
    if row.get("row_type") == "rewrite":
        return {"rewrite": 1} if row.get("wrote") in (True, False) else {}
    out = row.get("decide_outcome")
    if not (out in RAW_REQUIRED_OUTCOMES
            or (out == "synthesis_failed" and bool(row.get("stages")))):
        return {}
    stages = row.get("stages")
    if not isinstance(stages, list) or not stages:
        stages = _OUTCOME_MIN_STAGES.get(out, [])
    need = {}
    for st in stages:
        need[st] = need.get(st, 0) + 1
    return need


def _ctx_str(v):
    return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)


def verify(stream, ledger_path, *, require_decisions=0, require_attempts=0,
           allow_fixture_parent=False, health=None, expect_ctx=None):
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
         "cache_hits": 0, "cache_misses": 0, "cache_unknown": 0, "raw_lm_live": 0,
         "steps_ref_ok": 0, "steps_ref_prerun_rejected": 0,
         "raw_stage_checked": 0, "raw_stage_short": 0,
         "expect_ctx": dict(expect_ctx or {}),
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
        for k, want in (expect_ctx or {}).items():
            if not isinstance(ctx, dict) or k not in ctx:
                problems.append("run_ctx_mismatch: %s row %s/%s run_ctx has no key %r "
                                "(--expect-ctx %s=%s)" % (what, r.get("record_id"),
                                                         r.get("response_id"), k, k, want))
            elif _ctx_str(ctx[k]) != want:
                problems.append("run_ctx_mismatch: %s row %s/%s run_ctx[%r]=%r != %r"
                                % (what, r.get("record_id"), r.get("response_id"), k,
                                   ctx[k], want))
        need = _raw_required(r)
        for st, n in need.items():
            S["raw_stage_checked"] += 1
            got = _raw_valid_count(r, st)
            if got < n:
                S["raw_stage_short"] += 1
                problems.append("raw_lm_missing:%s:%s:need=%d:got=%d"
                                % (r.get("record_id"), st, n, got))
        raw = r.get("raw_lm")
        for st, entries in (raw.items() if isinstance(raw, dict) else ()):
            if st not in need and isinstance(entries, list) and entries:
                # 실패한(또는 요구 밖) 단계의 항목 — 요구하지 않고 보고만 한다.
                warnings.append("raw_lm_unrequired:%s:%s:entries=%d (%s row, stages=%r)"
                                % (r.get("record_id"), st, len(entries), what,
                                   r.get("stages")))

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
            # R12: `steps_ref` 가 가리키는 걸음이 결정 행에 실제로 있나(enact.jl R8a — 설치된
            #   재작성만 이 포인터를 단다; 그 뒤 재집행이 `respec["steps"]` 를 쓴다).
            if a.get("steps_ref") == "respec.steps":
                st = dec.get("steps")
                if isinstance(st, list) and st:
                    S["steps_ref_ok"] += 1
                elif st == [] and any(isinstance(b, dict) and b.get("trigger") == "prerun"
                                      for b in atts[ai + 1:]):
                    # 설치된 재작성이 **집행 전** 거절됐다(뒤 칸이 prerun 거절을 적는다 —
                    # `refused_budget_spent`, minted_end_to_end (34h)(d)): 걸음이 없는 것이 참이다.
                    S["steps_ref_prerun_rejected"] += 1
                else:
                    problems.append("steps_ref_dangling: %s steps_ref='respec.steps' but the "
                                    "decision's steps is %r" % (where, st))
            elif a.get("steps_ref") is not None:
                problems.append("steps_ref_dangling: %s unknown steps_ref %r"
                                % (where, a.get("steps_ref")))
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
                # R11: 표식은 원장 run_ctx 에도, 스트림의 결정 행에도 있다 — 둘 중 하나면 된다.
                #    전송 실패 판에는 원장 행이 없으므로 스트림 표식이 유일한 증거다.
                #    스트림: `policy.jl` `synth_fixture_lane` 이 `rt["synth_fixture"]` 를 쓰고
                #    `record_decision!` 이 `input.router = decision.router` 로 싣는다.
                #    표식 = 비지 않은 `path`. 게이트 분기의 `{"gated_off", "routing_kind"}` 는
                #    `path` 가 없으므로("이 결정엔 안 꽂혔다") 표식이 아니다.
                sfx = ((dec.get("input") or {}).get("router") or {}).get("synth_fixture")
                fixture = (any(isinstance(c, dict) and c.get("synth_fixture") for c in ctxs)
                           or (isinstance(sfx, dict) and bool(sfx.get("path"))))
                if dkey is None and dspy is None and fixture and allow_fixture_parent:
                    S["parent_fixture_allowed"] += 1
                else:
                    problems.append(
                        "parent_missing: %s has no parent_record_id (dspy decision=%s, "
                        "fixture marker (run_ctx or input.router)=%s, --allow-fixture-parent=%s)"
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
                    help="accept a null parent_record_id when a fixture marker is present "
                         "(ledger run_ctx.synth_fixture or stream input.router.synth_fixture)")
    ap.add_argument("--health-json", default=None, metavar="PATH",
                    help="saved /health JSON; ledger_append_failures > 0 fails the run")
    ap.add_argument("--expect-ctx", action="append", default=[], metavar="KEY=VALUE",
                    help="repeatable; every joined row's run_ctx[KEY] must equal VALUE "
                         "(strings as-is, other JSON values via json.dumps, e.g. seed=1, "
                         "zone=true); a missing key fails too")
    a = ap.parse_args(argv)
    expect = {}
    for kv in a.expect_ctx:
        k, sep, v = kv.partition("=")
        if not sep or not k:
            ap.error("--expect-ctx wants KEY=VALUE, got %r" % kv)
        expect[k] = v
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
                   allow_fixture_parent=a.allow_fixture_parent, health=health,
                   expect_ctx=expect)
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
