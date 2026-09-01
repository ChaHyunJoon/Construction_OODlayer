"""T6b 게이트 — **LLM 의 답이 아니라 기계를 잰다** (컨트롤러 판정 R14).

spec §5-3 의 P1·P2·P3 는 **연구 결과**이고 라이브 호출이 있어야 관측된다. 그것은 사용자가
돌릴 시험지이지 이 파일의 통과 조건이 아니다. 여기서는 `DummyLM` 으로 고정 응답을 물려
합성 레인의 **배선**만 태운다.

🔴 이 파일은 라이브 호출을 한 번도 하지 않는다. `127.0.0.1:8077` 로 POST 하지도 않는다.
⚠️ `DummyLM.supports_function_calling` 은 False 다 — DummyLM 왕복은 언제나 **텍스트 폴백
경로**를 잰다. 이 파일의 어떤 단언도 native function calling 이 켜졌다고 주장하지 않는다.

🔴 `when_to_use` 누출 검사가 `core/test_registry_doc_split.py` 와 **다른 모양**인 이유는
`test_no_when_to_use_survives_substitution` 의 docstring 에 실측과 함께 있다 — 요약하면
**살아 있는 레지스트리에서 20자 창을 원문에 그대로 걸면 위양성이 난다**(3개 원시가 자기
mechanism 과 22~29자를 공유한다). 그래서 같은 성질을 **더 강한** 검출기로 잰다.
"""
import copy
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

import primitive_registry as _prim  # noqa: E402
import features_agnostic as _fa  # noqa: E402

WINDOW = 20
SENTINEL = "ZZQWERTYUNIQUEVERDICTSENTINEL%03dZZQWERTYUNIQUEVERDICT"


def _answer(**kw):
    base = {"reasoning": "r", "tool_name": "shift_build",
            "params": '{"dx": {"type": "number"}, "dy": {"type": "number"}}',
            "mechanism": "Translates the whole build rigidly and commits the respec.",
            "body": "1. translate_whole_build(dx=2.38, dy=0.0)\n2. commit_respec()",
            "reach": "composed", "missing_primitive": ""}
    base.update(kw)
    return base


def _install(*answers):
    """DummyLM 을 전역에 설치한다. 과금 0건 — 이 LM 은 프로바이더에 안 나간다."""
    dspy.configure(lm=DummyLM([dict(a) for a in answers]),
                   adapter=dspy.ChatAdapter(use_native_function_calling=True))


def _on(monkeypatch):
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "1")


def _sentinel_blob():
    """`when_to_use` 만 유일한 센티넬로 바꾼 레지스트리 사본. 다른 필드는 한 글자도 안 건드린다."""
    b = copy.deepcopy(_prim.REGISTRY)
    for i, p in enumerate(b["primitives"]):
        p["when_to_use"] = SENTINEL % i
    return b


def _windows(text, window=WINDOW):
    t = text.lower()
    if len(t) <= window:
        return [t] if t else []
    return [t[i:i + window] for i in range(len(t) - window + 1)]


# ==========================================================================================
# 게이트 1 — 원시 19종의 mechanism 이 전부 들어가고, when_to_use 는 한 조각도 안 들어간다
# ==========================================================================================
def test_context_carries_every_operational_mechanism_verbatim():
    """인벤토리는 레지스트리에서 온다(리터럴 복붙 금지) — **19종 전부**의 mechanism 이
    렌더에 원문 그대로 있어야 한다. 개수도 레지스트리에서 유도한다: 리터럴 19 를 적으면
    레지스트리가 자라도 이 게이트가 안 자란다."""
    ctx = syn.build_context(state="obs")
    prims = _prim.REGISTRY["primitives"]
    assert prims, "레지스트리에 원시가 하나도 없다 -- 이 파일의 루프가 공허하게 통과한다."
    for p in prims:
        assert p["mechanism"] in ctx, (
            "원시 %r 의 mechanism 이 context 에 없다 -- 합성기가 그 원시의 존재나 함정을 "
            "못 본다." % p["name"])
    assert len(prims) == len(_prim.PRIMITIVE_NAMES) == 20, (
        "운용 원시 수가 19 에서 움직였다(%d) -- 이 게이트의 다른 어서션은 레지스트리에서 "
        "유도되므로 계속 옳지만, 브리프가 못박은 19 라는 사실이 갈렸다는 것은 "
        "보고돼야 한다." % len(prims))


def test_context_carries_the_trap_items_that_make_tools_silently_no_op():
    """⚠️ 함정 항목을 안 보여주면 합성기가 **조용히 아무 일도 안 하는 tool** 을 만든다.
    셋은 브리프가 이름으로 지목한 것이다: `force_advance_stuck_carrier`(CARRIER_RESCUE 없이
    no-op) · `rethread_robot_ids`(PARKED) · `deprioritize_agent`(MILP 재풀이 없으면 무효).
    문구는 레지스트리 산문에서 뽑는다 -- 여기 리터럴로 적으면 산문이 갈려도 초록이다."""
    ctx = syn.build_context(state="obs").lower()
    for name, needle in (("force_advance_stuck_carrier", "carrier_rescue"),
                         ("rethread_robot_ids", "parked"),
                         ("deprioritize_agent", "clamped")):
        p = [x for x in _prim.REGISTRY["primitives"] if x["name"] == name][0]
        assert needle in p["mechanism"].lower(), (
            "레지스트리의 %r mechanism 이 더 이상 %r 를 말하지 않는다 -- 이 게이트가 "
            "가리키던 함정이 사라졌거나 문구가 갈렸다." % (name, needle))
        assert needle in ctx, "함정 문구 %r 가 context 에 안 실렸다(%s)" % (needle, name)


def test_no_when_to_use_survives_substitution():
    """🔴 R7 의 **주 게이트**. `when_to_use` 를 전부 유일한 센티넬로 바꾼 레지스트리로 렌더한
    결과가 원본 렌더와 **바이트 단위로 같아야** 한다. 렌더가 그 필드를 조금이라도 읽으면
    (접두든 꼬리든 중간이든, 한 원시든 전부든) 두 문자열이 갈린다 — 위치·분량과 무관한
    **정확한** 검출기다.

    🔴 왜 `core/test_registry_doc_split.py` 의 20자 슬라이딩 윈도우를 **원문에** 그대로 걸지
    않았나 (실측, 2026-08-29): 이 레지스트리에서는 그 검사가 **위양성**이다. `when_to_use` 와
    mechanism 코퍼스가 공유하는 최장 연속 구간을 재면 —
        restage_assembly           29자
        translate_whole_build      29자
        apply_uniform_translation  22자
    셋 다 20자 창을 넘는다(그 파일의 라이브 레지스트리는 최장 19자였고, 그래서 거기서는
    그대로 통과한다). 두 필드가 같은 대상을 말하니 겹치는 것이 정상이고, 겹침을 예외로
    빼는 필터는 그 파일의 fix round 5 가 **측정으로 반증한 바로 그 Q2** 다(거의-100% 스킵을
    못 막는다). 그래서 예외를 두는 대신 **검출기를 바꿨다.** 20자 창 기법 자체는 아래
    `test_sliding_window_detector_is_not_vacuous` 가 센티넬 위에서 그대로 돌린다."""
    a = syn.build_context(state="obs")
    b = syn.build_context(state="obs", blob=_sentinel_blob())
    assert a == b, (
        "when_to_use 를 센티넬로 바꿨더니 렌더가 달라졌다 -- 즉 렌더 경로가 그 필드를 "
        "읽는다. 그것은 **정답 조건**이고 프롬프트에 실으면 재는 것이 추론이 아니라 "
        "프롬프트 준수가 된다(spec §6-2).")


def test_sliding_window_detector_is_not_vacuous():
    """🔴 위 치환 게이트가 **혼자 초록으로 거짓말** 하지 않는지의 음성 대조 + R7 이 지정한
    20자 창 기법 자체의 실행.

    (a) 센티넬 렌더에는 어떤 센티넬의 20자 연속 구간도 없다 — 창이 실제로 돌았다는 증거로
        `executed > 0` 를 함께 핀한다(`test_registry_doc_split.py` 의 S2 와 같은 이유).
    (b) **일부러 새게 만든** 렌더(mechanism 뒤에 when_to_use 를 이어붙인 국소 뮤테이션)에는
        같은 창이 **잡힌다.** 이게 없으면 (a) 는 "검사가 아무것도 못 본다"와 구별 불가다."""
    blob = _sentinel_blob()
    rendered = syn.build_context(state="obs", blob=blob).lower()
    executed = 0
    for p in blob["primitives"]:
        for chunk in _windows(p["when_to_use"]):
            executed += 1
            assert chunk not in rendered, (
                "원시 %r 의 when_to_use 에서 %d자 연속 구간이 프롬프트로 샜다: %r"
                % (p["name"], len(chunk), chunk))
    assert executed > 0, "센티넬이 20자보다 짧아 창이 하나도 안 돌았다 -- 공허한 통과."

    leaked = blob.copy()
    leaked["primitives"] = [dict(p, mechanism=p["mechanism"] + " " + p["when_to_use"])
                            for p in blob["primitives"]]
    leaked_render = syn.build_context(state="obs", blob=leaked).lower()
    hits = [c for p in blob["primitives"] for c in _windows(p["when_to_use"])
            if c in leaked_render]
    assert hits, ("음성 대조 실패: when_to_use 를 mechanism 에 그대로 이어붙였는데도 20자 창이 "
                  "하나도 안 잡혔다 -- 위 (a) 의 초록은 아무 의미가 없다.")


def test_the_field_name_appears_only_in_the_never_render_marker():
    """🔴 '빠뜨린 것'과 '일부러 뺀 것'을 코드에서 가른다. 모듈 소스 안에서 `when_to_use` 라는
    **식별자로서의** 사용(문자열 리터럴 `_NEVER_RENDER` 와 산문 주석 제외)이 0 이어야 한다.
    치환 게이트가 이미 성질을 잡지만, 이 한 줄은 리뷰어에게 **의도**를 남긴다."""
    src = open(syn.__file__, encoding="utf-8").read()
    assert '"when_to_use"' in src, "_NEVER_RENDER 표식이 사라졌다 -- 의도가 기록에서 빠진다."
    assert '["when_to_use"]' not in src and ".when_to_use" not in src, (
        "synthesize.py 가 when_to_use 를 인덱싱한다 -- 렌더로 새는 경로가 생겼을 수 있다.")
    assert syn._NEVER_RENDER == ("when_to_use",)


# ==========================================================================================
# 게이트 2 — canon 이 파라미터를 무시한다
# ==========================================================================================
def test_canon_ignores_parameters():
    """🔴 spec §5-2-2: `shift_build(dx=2.38)` 과 `shift_build(dx=2.40)` 은 **같은 행동**이다.
    이것이 '비슷한 매크로가 쏟아질 위험'을 흡수하는 자리다."""
    a = "1. translate_whole_build(dx=2.38, dy=0.0)\n2. commit_respec()"
    b = "1. translate_whole_build(dx=2.40, dy=-11.5)\n2. commit_respec()"
    na, _ = syn.parse_body(a)
    nb, _ = syn.parse_body(b)
    assert na == nb == ["translate_whole_build", "commit_respec"]
    assert syn.canon(na, "zone") == syn.canon(nb, "zone")
    assert syn.canon_key(syn.canon(na, "zone")) == syn.canon_key(syn.canon(nb, "zone"))


def test_canon_does_separate_things_that_really_differ():
    """음성 대조: 순서만 다른 body 는 같은 정규형이지만(정렬), **다른 원시**나 **다른 kind**
    는 다른 정규형이다. 이게 없으면 위 테스트는 'canon 이 전부 상수' 로도 통과한다."""
    x, _ = syn.parse_body("translate_whole_build(dx=1)")
    y, _ = syn.parse_body("restage_assembly(a=1)")
    assert syn.canon(x, "zone") != syn.canon(y, "zone")
    assert syn.canon(x, "zone") != syn.canon(x, "battery")
    z, _ = syn.parse_body("commit_respec()\ntranslate_whole_build(dx=1)")
    w, _ = syn.parse_body("translate_whole_build(dx=1)\ncommit_respec()")
    assert syn.canon(z, "zone") == syn.canon(w, "zone"), "정렬이 순서를 지운다(spec §5-2-2)"


def test_body_grammar_knows_predicates_have_no_psi():
    """🟢 T6a 가 고친 `psi` 는 순수 술어에 KeyError 를 던진다(효과 서술자가 없으므로).
    그러니 body 문법이 그 사실을 **알아야** 한다 — 술어를 운용 원시로 세면 ψ 가 터진다."""
    names, how = syn.parse_body("goal_engulfed(node)\ntranslate_whole_build(dx=1)")
    assert how == "calls"
    cls = syn.classify(names)
    assert cls["predicate"] == ["goal_engulfed"]
    assert cls["operational"] == ["translate_whole_build"]
    try:
        syn.psi_of(names)
    except KeyError as e:
        assert "술어" in str(e) or "predicate" in str(e).lower()
    else:
        raise AssertionError("psi 가 술어를 조용히 받아들였다 -- T6a 의 수정이 되돌아갔다.")


def test_parse_body_falls_back_to_a_name_scan_and_says_so():
    """모델이 괄호 없이 쓰는 경우가 실재한다. 폴백은 두되 **어느 방식이었는지 기록**한다 —
    조용히 다른 것을 세면 canon 의 뜻이 갈린다."""
    names, how = syn.parse_body("first translate_whole_build then commit_respec")
    assert (names, how) == (["translate_whole_build", "commit_respec"], "names")
    assert syn.parse_body("nothing here")[1] == "empty"


# ==========================================================================================
# 게이트 3 — reach == needs_primitive 여도 정의가 끝까지 기록된다
# ==========================================================================================
def test_needs_primitive_output_is_recorded_in_full(monkeypatch):
    """🔴 spec §5-1: 모델이 '못 만든다'로 끝내는 길이 없다. 표현 불가는 `reach` 로 말하되
    **정의는 끝까지 쓴다** — 그래야 그 사건에서 무엇이 필요했는지가 기록에 남는다."""
    _on(monkeypatch)
    _install(_answer(reach="needs_primitive",
                     body="1. widen_corridor(radius=2.0)",
                     missing_primitive="widen_corridor: edits scene_tree; params radius:number; "
                                       "precondition none; irreversible; consumes nothing; no "
                                       "composition over the inventory can move a zone."))
    rec = syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                               ledger=syn.SynthesisLedger())
    assert rec["ran"] is True and rec["error"] is None
    for f in ("tool_name", "params", "mechanism", "body", "reach", "missing_primitive"):
        assert rec[f], "표현 불가 출력에서 %r 가 비었다 -- 합성 결과가 버려졌다." % f
    assert rec["missing_primitive_recorded"] is True
    assert rec["reach_matches_body"] is True, "body 에 미등재 원시가 있고 reach 도 그렇게 말한다"
    assert rec["tool_minted"] is True, "표현 불가도 새 정규형이면 주조로 센다"
    assert rec["body_unknown"] == ["widen_corridor"]
    assert rec["psi"] is None and "unknown" in (rec["psi_error"] or ""), (
        "미등재 원시가 든 body 에 ψ 를 억지로 매기면 안 된다 -- 조용한 0 벡터가 그 결함이었다")


def test_a_needs_primitive_answer_with_an_empty_spec_is_flagged_not_dropped(monkeypatch):
    """`missing_primitive` 가 비면 그 사건에서 무엇이 필요했는지가 안 남는다. 그래도 **버리지
    않는다** — `missing_primitive_recorded=False` 로 기록만 한다."""
    _on(monkeypatch)
    _install(_answer(reach="needs_primitive", missing_primitive="   "))
    rec = syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                               ledger=syn.SynthesisLedger())
    assert rec["missing_primitive_recorded"] is False
    assert rec["tool_name"] and rec["mechanism"], "정의 자체는 남는다"


# ==========================================================================================
# 게이트 4 — |K| 는 새 canon 에만 오른다
# ==========================================================================================
def test_K_rises_only_on_a_new_canon(monkeypatch):
    """spec §5-2-3 의 1차 결과. 🔴 `minted == False` 는 실패가 아니라 이 곡선의 한 점이다."""
    _on(monkeypatch)
    led = syn.SynthesisLedger()
    assert led.K == 0
    _install(_answer(),                                             # 새 canon
             _answer(body="translate_whole_build(dx=2.40)\ncommit_respec()"),  # 파라미터만 다름
             _answer(body="restage_assembly(a=1)"))                 # 진짜 새 canon
    seq = []
    for _ in range(3):
        r = syn.maybe_synthesize(expressible=False, kind="zone", state="obs", ledger=led)
        seq.append((r["tool_minted"], r["K"]))
    assert seq == [(True, 1), (False, 1), (True, 2)], seq
    key = syn.canon_key(syn.canon(["translate_whole_build", "commit_respec"], "zone"))
    e = led.entries[key]
    assert e["count"] == 2, "중복은 차단이 아니라 **측정**이다 -- 카운터가 올라야 한다"
    assert len(e["params"]) == 2, "중복에서 파라미터만 따로 쌓인다(spec §5-2-2 ①)"


# ==========================================================================================
# 게이트 5 — ψ 거리는 표준화 후에 계산되고, 임계값으로 접지 않는다
# ==========================================================================================
def test_psi_distance_is_standardised_and_records_its_provenance():
    """⚠️ 축 스케일이 제각각이라(`a_cost` 연속 · `a_scope` 정수 · 나머지 0/1) 표준화 없는
    유클리드 거리는 `a_cost` 가 독점한다. 표준화가 **실제로 적용됐음**을 원시 거리와의 차이로
    보이고, 통계의 **출처**가 기록에 남는지 확인한다(R19)."""
    stats = syn.psi_stats()
    u, v = _fa.psi(["translate_whole_build"]), _fa.psi(["swap_battery"])
    std_d = syn.standardized_distance(u, v, stats)
    raw_d = sum((u[a] - v[a]) ** 2 for a in stats["axes"]) ** 0.5
    assert std_d > 0 and abs(std_d - raw_d) > 1e-9, (
        "표준화 거리가 원시 유클리드 거리와 같다 -- 축별 표준화가 실제로 적용되지 않았다.")
    assert "a_intervenes" in stats["zero_variance_axes"], (
        "T6a 실측: a_intervenes 는 19개 전부 1.0 이라 거리에 정보가 0 이다. 그 사실이 "
        "통계에서 사라졌다면 모집단이 갈렸다는 뜻이다.")
    for a in stats["zero_variance_axes"]:
        assert stats["std"][a] == 0.0
    p = stats["provenance"]
    for k in ("population", "source_file", "statistic_used_in_distance", "a_cost_note",
              "zero_variance_note", "merging"):
        assert p.get(k), "표준화 통계의 출처 항목 %r 가 비었다" % k
    assert "R19" in p["merging"] and "RECORDED ONLY" in p["merging"]
    assert "4" in p["a_cost_note"] and "15" in p["a_cost_note"], (
        "a_cost 의 닻 4 / 판단 15 라는 T6a 실측이 출처 기록에서 빠졌다.")


def test_psi_distance_is_recorded_and_never_folds_a_near_neighbour(monkeypatch):
    """🔴 R19 의 핵심. 두 정규형의 ψ 거리가 아무리 작아도 **접지 않는다** — 임계값 τ 를
    지어내면 그 사실이 기록에서 사라진다. 그래서 두 번째 body 는 첫 번째와 ψ 가 **완전히
    같은데도**(같은 원시 집합의 다른 배열이 아니라, `restage_all_blocked` 와
    `apply_uniform_translation` 처럼 8축이 겹치는 쌍) 새 canon 으로 주조돼야 한다."""
    _on(monkeypatch)
    led = syn.SynthesisLedger()
    _install(_answer(body="restage_all_blocked()"),
             _answer(body="apply_uniform_translation(dx=1)"))
    r1 = syn.maybe_synthesize(expressible=False, kind="zone", state="obs", ledger=led)
    r2 = syn.maybe_synthesize(expressible=False, kind="zone", state="obs", ledger=led)
    assert r1["tool_minted"] is True and r1["psi_distance"] is None, (
        "첫 관측에는 기준점이 없다 -- 거리를 지어내면 안 된다")
    assert r1["psi_reference_n"] == 0 and r1["psi_error"]
    assert r2["tool_minted"] is True, (
        "가까운 이웃이 `False` 로 접혔다 -- 어딘가에 임계값이 들어갔다는 뜻이다(R19 위반).")
    assert r2["K"] == 2, "접혔으면 |K| 가 안 올랐을 것이다"
    assert isinstance(r2["psi_distance"], float), "②는 거리를 **기록**해야 한다"
    assert r2["psi_nearest"] == r1["canon_key"]
    assert r2["psi_distance"] >= 0.0
    for k in ("merged", "folded", "threshold", "tau"):
        assert k not in r2, "기록에 병합 판정 필드 %r 가 생겼다 -- τ 를 지어낸 것이다" % k


# ==========================================================================================
# 게이트 6 — `tool_minted` 의 네 값이 전부 도달 가능하다
# ==========================================================================================
def test_tool_minted_disabled_when_the_flag_is_off(monkeypatch):
    """🔴 R13. 입력: `expressible=False` + `TOOL_SYNTHESIS` 미설정.
    `nothing` 이 아니라 `"disabled"` 다 — '꺼져서 안 돌았다'와 '돌았는데 아무것도 안 주조했다'는
    다른 사건이고, 이 레포에는 꺼진 채 성공 모양의 출력을 내는 원시가 실재한다."""
    monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
    rec = syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                               ledger=syn.SynthesisLedger())
    assert rec["tool_minted"] == "disabled"
    assert rec["synthesis_event"] is True and rec["ran"] is False
    monkeypatch.setenv(syn.SYNTHESIS_ENV, "true")
    assert syn.maybe_synthesize(expressible=False, ledger=syn.SynthesisLedger()
                                )["tool_minted"] == "disabled", (
        "'true' 를 켜짐으로 받아 주면 안 된다 -- 유료 호출을 여는 스위치다.")


def test_tool_minted_is_none_when_the_event_would_not_fire(monkeypatch):
    """입력: `expressible=True`(또는 `None` = 못 쟀다). 플래그와 무관하게 `nothing`."""
    for flag in (None, "1"):
        if flag is None:
            monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
        else:
            monkeypatch.setenv(syn.SYNTHESIS_ENV, flag)
        for e in (True, None):
            rec = syn.maybe_synthesize(expressible=e, ledger=syn.SynthesisLedger())
            assert rec["tool_minted"] is None and rec["synthesis_event"] is False, (e, flag)
            assert rec["ran"] is False


def test_tool_minted_true_and_false_are_both_reachable(monkeypatch):
    """입력: `expressible=False` + `TOOL_SYNTHESIS=1` + 같은 body 두 번.
    첫 번째가 `True`(새 canon), 두 번째가 `False`(LLM 이 좋은 행동을 스스로 재유도)."""
    _on(monkeypatch)
    led = syn.SynthesisLedger()
    _install(_answer(), _answer())
    assert syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                                ledger=led)["tool_minted"] is True
    r2 = syn.maybe_synthesize(expressible=False, kind="zone", state="obs", ledger=led)
    assert r2["tool_minted"] is False
    assert "not a failure" in r2["reason"], "`false` 를 실패로 적으면 |K| 곡선을 잘못 읽는다"


def test_all_four_values_are_reachable_and_the_fifth_event_is_distinguishable(monkeypatch):
    """🔴 상태가 넷인데 셋만 닿으면 거짓말이 하나 든다 — 넷을 한 테스트에서 모은다.
    그리고 🔴 **네 값은 분할이 아니다**: 다섯 번째 사건(돌았는데 실패)이 `None` 을 공유한다.
    그것을 가르는 키가 실제로 응답에 있는지 못박는다(C8 의 세 사건과 같은 함정)."""
    seen = {}
    monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
    seen["disabled"] = syn.maybe_synthesize(expressible=False, ledger=syn.SynthesisLedger())
    seen["none"] = syn.maybe_synthesize(expressible=True, ledger=syn.SynthesisLedger())
    _on(monkeypatch)
    led = syn.SynthesisLedger()
    _install(_answer(), _answer())
    seen["true"] = syn.maybe_synthesize(expressible=False, kind="zone", state="o", ledger=led)
    seen["false"] = syn.maybe_synthesize(expressible=False, kind="zone", state="o", ledger=led)

    class _Boom:
        def __call__(self, **kw):
            raise RuntimeError("provider is down")
    seen["error"] = syn.maybe_synthesize(expressible=False, kind="zone", state="o",
                                         ledger=syn.SynthesisLedger(), program=_Boom())

    got = [seen[k]["tool_minted"] for k in ("disabled", "none", "true", "false")]
    assert got == ["disabled", None, True, False], got
    e = seen["error"]
    assert e["tool_minted"] is None and e["ran"] is True and e["error"], e
    n = seen["none"]
    assert n["tool_minted"] is None and n["ran"] is False
    assert (e["ran"], e["error"] is None) != (n["ran"], n["error"] is None), (
        "돌다가 실패한 행과 발화 안 한 행이 구별 불가다 -- 실패율이 다른 버킷으로 샌다.")


# ==========================================================================================
# 게이트 7 — 꺼져 있으면 네트워크 호출이 0 이다 (소켓 실측)
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

    ⚠️ 주장의 범위를 정확히 쓴다: 이것은 **`maybe_synthesize` 호출 경로**의 연결 시도가 0
    이라는 주장이다. 같은 프로세스의 다른 코드에 대한 주장이 아니다 — 예컨대
    `supports_function_calling` 을 **읽는** 것은 raw.githubusercontent.com 으로 8회 연결을
    시도한 뒤 로컬로 폴백한다(2026-08-28 실측). 과금은 안 되지만 '네트워크 0' 은 아니다."""
    monkeypatch.delenv(syn.SYNTHESIS_ENV, raising=False)
    with _NetSpy() as spy:
        rec = syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                                   tools=None, ledger=syn.SynthesisLedger())
    assert rec["tool_minted"] == "disabled"
    assert spy.calls == [], "합성이 꺼져 있는데 연결을 시도했다: %r" % (spy.calls,)
    assert "context_chars" not in rec, "꺼져 있는데 context 를 지었다(프롬프트 렌더 비용)"


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
# params 평평함 — T1 이 남긴 얕은 변환 함정을 여기서 닫는다
# ==========================================================================================
def test_flat_params_pass_and_nested_params_are_flagged():
    """🔴 줄리아의 `_tool_args_dict`(`tools/monitor/policy.jl:1138`)는 **얕다**. 중첩 인자를
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


def test_a_nested_params_answer_is_recorded_but_not_dropped(monkeypatch):
    """제약을 어긴 출력도 **버리지 않는다** — 정의는 끝까지 남고 판정만 기록된다."""
    _on(monkeypatch)
    _install(_answer(params='{"where": {"type": "object", "properties": {"x": {"type":"number"}}}}'))
    rec = syn.maybe_synthesize(expressible=False, kind="zone", state="obs",
                               ledger=syn.SynthesisLedger())
    assert rec["params_flat"] is False and rec["tool_minted"] is True
    assert rec["mechanism"] and rec["body"], "정의는 끝까지 기록된다"


# ==========================================================================================
# 서비스 배선 — `/macro` 와 `/decide` 가 값을 실제로 나른다
# ==========================================================================================
def _svc():
    import dspy_service as svc
    return svc


def test_macro_and_decide_carry_tool_minted(monkeypatch):
    """🔴 배선을 잰다. `/macro` 에는 이 레포에 호출자가 0개이고 라이브 레인은 `/decide` 로만
    들어오므로(`tools/monitor/policy.jl:559`), **둘 다** 확인한다."""
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
    assert d["synthesis"]["synthesis_event"] is True
    out = svc.decide(req)
    assert out["dspy"]["tool_minted"] is None, (
        "두 번째 응답은 expressible=True 이므로 발화 사건이 아니다")
    assert "synthesis" in out["dspy"], "/decide 가 합성 기록을 안 나르면 라이브 레인에서 안 보인다"
    assert json.dumps(out["dspy"]["synthesis"]), "응답이 JSON 직렬화돼야 줄리아가 읽는다"


def test_synthesize_keeps_the_numpy_before_dspy_contract():
    """🔴 `dspy_service.py:44` · `tool_registry.py` 와 같은 계약. 수집 순서가 바뀌면 이 파일이
    혼자 먼저 dspy 를 심을 수 있다."""
    src = open(syn.__file__, encoding="utf-8").read()
    assert src.index("import numpy, sklearn.ensemble") < src.index("\nimport dspy")


def test_synthesis_keys_sit_above_the_tool_lane_marker_in_out_dspy():
    """🔴 교차언어 결속. `test/tool_lane_keys_survive.jl` (6)절은 `out["dspy"]` dict 안의
    `# ---- tool 레인 …` 표식 **아래** 키 집합을 Julia 의 `TOOL_LANE_KEYS` 여덟과 **양방향
    등호**로 대조한다(`test/tool_lane_keys_survive.jl:462`). 그러므로 표식 아래에 합성 레인
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
    #    들어와 **열한 개**다. ⚠️ 줄리아의 `TOOL_LANE_KEYS` 는 아직 옛 열 개라 그 파일의
    #    (6)절이 지금 정당하게 빨갛다(실측: T4 가 더한 실패는 정확히 2개) — T6 이 닫는다. 파이썬에서 키를
    #    표식 위로 숨겨 초록을 만들지 않는 이유는 그 상태가 조용해지기 때문이다.
    assert set(lane) == {"tool_called", "tool_args", "tool_calls_n", "tools_offered",
                         "expressible", "native_fc", "tool_lane_error", "macro_tool_agree",
                         "tool_choice", "decision_source", "tool_arg_error"}, lane
    allk = [k.value for k in d.keys]
    assert "tool_minted" in allk and "synthesis" in allk, (
        "합성 레인 키가 /decide 응답에서 사라졌다 -- 라이브 레인은 /decide 로만 들어온다.")
