"""레지스트리는 **기전**을 말하고 **정답 조건**을 말하지 않는다.

🔴 왜 (dspy_service.py:155-165 의 실측): 규칙을 문장으로 주면 측정되는 것은 추론이 아니라
프롬프트 준수다. 서술자가 harm=0.02 인데도 "restage 하라"는 지시문을 따라간 관측이 있다.
그런데 레지스트리 doc 이 "Best when …" / "Best on …" 으로 그 선을 넘어 있었고,
doc_lines() 가 그것을 SEED_DOC 에 그대로 실었다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import action_registry  # noqa: E402

VERDICT_WORDS = ("best when", "best on", "prefer ", "choose this", "use this when")


def _macros():
    with open(os.path.join(HERE, "action_registry.json"), encoding="utf-8") as f:
        return json.load(f)["macros"]


def test_every_macro_has_both_fields():
    for mid, m in _macros().items():
        assert "mechanism" in m, "macro %s 에 mechanism 이 없다" % mid
        assert "when_to_use" in m, "macro %s 에 when_to_use 가 없다" % mid


def test_mechanism_carries_no_applicability_verdict():
    for mid, m in _macros().items():
        low = m["mechanism"].lower()
        for w in VERDICT_WORDS:
            assert w not in low, "macro %s 의 mechanism 에 정답 조건이 샜다: %r" % (mid, w)


def test_doc_lines_never_renders_when_to_use():
    rendered = "\n".join(action_registry.doc_lines()).lower()
    for mid, m in _macros().items():
        snippet = m["when_to_use"].lower()[:24]
        if snippet.strip():
            assert snippet not in rendered, \
                "macro %s 의 when_to_use 가 프롬프트로 샜다" % mid


# ---- 추가: SEED_DOC 이 컴파일 산출물에 조용히 갈아치워지지 않는지 -----------------------
# dspy_service._load_program() 은 PROGRAM 파일이 있으면
# `prog.signature = prog.signature.with_instructions(instr)` 로 SEED_DOC(따라서 이 파일이
# 만든 mechanism/when_to_use 분리)을 통째로 대체한다. 오늘은 PROGRAM == "" 이라 안 물지만,
# 그 전제가 깨지는 날 이 테스트가 아니면 아무도 못 본다 -- doc_lines()/JSON 쪽 테스트는 전부
# 초록인 채로, 실제 프롬프트 경로만 조용히 구세대 doc 으로 되돌아갈 수 있다.
def test_no_compiled_program_shadows_seed_doc():
    llm_service_dir = os.path.join(HERE, "..", "..", "src", "respec", "llm_service")
    llm_service_dir = os.path.abspath(llm_service_dir)
    if llm_service_dir not in sys.path:
        sys.path.insert(0, llm_service_dir)
    import dspy_service  # noqa: E402

    assert dspy_service.PROGRAM == "", (
        "PROGRAM 이 더 이상 빈 문자열이 아니다(%r): _load_program() 이 컴파일된 instructions 로 "
        "SEED_DOC 을 with_instructions() 로 갈아치울 수 있다는 뜻이고, 그러면 이 파일이 지키는 "
        "mechanism/when_to_use 분리가 실제 프롬프트 경로에서 조용히 무효화된다." % dspy_service.PROGRAM
    )
