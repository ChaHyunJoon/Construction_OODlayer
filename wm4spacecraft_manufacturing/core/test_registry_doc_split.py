"""레지스트리는 **기전**을 말하고 **정답 조건**을 말하지 않는다.

🔴 왜 (dspy_service.py:155-165 의 실측): 규칙을 문장으로 주면 측정되는 것은 추론이 아니라
프롬프트 준수다. 서술자가 harm=0.02 인데도 "restage 하라"는 지시문을 따라간 관측이 있다.
그런데 레지스트리 doc 이 "Best when …" / "Best on …" 으로 그 선을 넘어 있었고,
doc_lines() 가 그것을 SEED_DOC 에 그대로 실었다.

fix round 1 (리뷰어 뮤테이션 테이블 P1-P5): 아래 다섯 군데를 고쳤다. 각각 "뮤테이션을 만들고
빨개지는 걸 보고 되돌린다"로 검증했다 -- 그 로그는 커밋되지 않고 task-3-report.md 에 있다.
  P1 mechanism.2 = "" 가 4개 게이트를 전부 통과했다 -- 빈 mechanism 을 막는 테스트가 없었다.
  P2 VERDICT_WORDS 는 5개 리터럴만 막는 블록리스트였고(M6/M7 이 안 걸림), when_to_use 누출
     검사는 24자 **접두**만 봐서 M8(꼬리만 새는 뮤테이션)을 놓쳤다 -- 슬라이딩 윈도우로 바꿨다.
  P3 컴파일 프로그램 가드가 `PROGRAM == ""` 를 어서션해서, 이 레포의 문서화된 설정
     (DSPY_PROGRAM=__seed_only__, .claude/CLAUDE.md Gotchas)에서 안전한데도 헛불을 냈다 --
     실제로 지켜야 하는 명제(`_state["instructions"] == SEED_DOC`)로 바꿨다.
  P4 test_every_macro_has_both_fields 는 단독으로 못 빨개진다(실패 집합이 test 2∪3 의 부분집합)
     -- 독립 핀이 아니라 가독성 래퍼라고 docstring 에 적었다.
  P5 테스트가 읽는 JSON 경로가 로더가 읽는 경로(REGISTRY_PATH, ACTION_REGISTRY 로 오버라이드
     가능)와 달랐다 -- 같은 경로를 읽게 고쳤다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import action_registry  # noqa: E402

# 🔴 P2: 이것은 **블록리스트**다 -- "정답 조건이 없다"의 증명이 아니라 "알려진 몇 가지
# 문구가 없다"의 체크일 뿐이다. mechanism 이 여기 없는 다른 표현으로 정답 조건을 실어도 이
# 테스트는 못 잡는다(그래서 함수 이름이 …no_known_verdict_phrasing 이지 …no_verdict 가 아니다).
# 리뷰 라운드 1 실측: 구 목록(best when/best on/prefer /choose this/use this when)은
# "Best for a real fault…"(M6) 와 "Use it on a real fault…"(M7) 를 놓쳤다 -- 아래에 그
# 표현과 흔한 동의어를 추가했다. 이걸로도 여전히 완전하지 않다.
VERDICT_WORDS = (
    "best when", "best on", "best for",
    "prefer ", "preferred when", "preferred for",
    "choose this", "use this when", "use it on", "use on",
    "ideal when", "ideal for",
    "right choice when", "correct choice when",
    "recommended when", "recommended for",
    "suited when", "suited for",
    "select this when", "pick this when",
)


def _macros():
    # 🔴 P5: 로더(action_registry.py)는 REGISTRY_PATH(= ACTION_REGISTRY 환경변수로 오버라이드
    # 가능)를 읽는다. 여기서 HERE 기준 고정 경로를 따로 읽으면, 오버라이드가 걸린 상태에서
    # 로더는 다른 파일을 읽는데 이 테스트는 여전히 리포의 기본 JSON 을 보고 "이상 없음"이라고
    # 말하는 사고가 난다(리뷰 라운드 1 실측: 구세대 doc 문장이 있는 오버라이드 레지스트리로
    # 4개 게이트가 전부 초록이었다). 로더가 읽는 바로 그 경로를 읽는다.
    with open(action_registry.REGISTRY_PATH, encoding="utf-8") as f:
        return json.load(f)["macros"]


def test_every_macro_has_both_fields():
    """🔴 P4: 이 테스트는 단독으로 빨개질 수 없다 -- 가독성 래퍼일 뿐, 독립된 핀이 아니다.
    `mechanism` 이나 `when_to_use` 키가 사라지면 이 테스트도 실패하지만, 그 두 값을 직접
    인덱싱하는 `test_mechanism_carries_no_known_verdict_phrasing` /
    `test_doc_lines_never_renders_when_to_use` 가 같은 뮤테이션에서 먼저(또는 함께) KeyError 로
    죽는다 -- 이 테스트의 실패 집합은 그 둘의 합집합의 부분집합이다."""
    for mid, m in _macros().items():
        assert "mechanism" in m, "macro %s 에 mechanism 이 없다" % mid
        assert "when_to_use" in m, "macro %s 에 when_to_use 가 없다" % mid


def test_mechanism_is_non_empty_and_substantive():
    """🔴 P1: 빈 mechanism 은 그 팔을 프롬프트에서 지운다 -- `doc_lines()` 는
    "- SwapBattery (cost 0.2): " 처럼 이름·비용만 있고 설명이 없는 줄을 낸다. 이것이 정확히
    이 레지스트리가 막으려던 실패 모양이다(SwapBattery 가 어휘에 없어서 battery 적중이
    0/6→6/6 으로 갈렸던 실측, CLAUDE.md 340-341행). 길이 문턱은 임의값이지만 ""와 한 단어짜리
    스텁을 잡기엔 충분하다."""
    MIN_LEN = 15
    for mid, m in _macros().items():
        text = m["mechanism"].strip()
        assert len(text) >= MIN_LEN, (
            "macro %s 의 mechanism 이 비어있거나 너무 짧다(%r) -- 그 팔이 프롬프트에서 "
            "사실상 안 보인다." % (mid, text)
        )


def test_mechanism_carries_no_known_verdict_phrasing():
    """🔴 P2: 이름을 정직하게 붙였다 -- 이것은 VERDICT_WORDS **블록리스트**의 검사이지,
    "mechanism 에 정답 조건이 전혀 없다"의 증명이 아니다. 블록리스트에 없는 표현으로 정답
    조건을 적으면 이 테스트는 통과한다. (구 이름 test_mechanism_carries_no_applicability_verdict
    는 이 한계를 안 밝혀서 증명인 것처럼 읽혔다.)"""
    for mid, m in _macros().items():
        low = m["mechanism"].lower()
        for w in VERDICT_WORDS:
            assert w not in low, "macro %s 의 mechanism 에 정답 조건이 샜다: %r" % (mid, w)


def _leak_windows(text, window=20):
    """`text` 에서 길이 `window` 인 모든 연속 부분문자열. `text` 가 window 보다 짧으면
    `text` 전체 하나만."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= window:
        return [text]
    return [text[i:i + window] for i in range(len(text) - window + 1)]


def test_doc_lines_never_renders_when_to_use():
    """🔴 P2 (M8): 구 버전은 `when_to_use.lower()[:24]` 고정 **접두**만 봤다. 리뷰 라운드 1
    실측: `doc_lines()` 가 `when_to_use[10:]` (꼬리만, 접두가 아니라)를 새게 만드는 뮤테이션에서
    4개 게이트가 전부 초록이었다 -- 거의 문장 전체가 나갔는데도. 접두 대신 20자 슬라이딩
    윈도우로 검사한다: `when_to_use` 안의 어떤 연속 20자 구간도 렌더링된 프롬프트에 있으면
    안 된다 -- 접두든 꼬리든 중간이든 위치에 상관없이 잡는다."""
    rendered = "\n".join(action_registry.doc_lines()).lower()
    window = 20
    for mid, m in _macros().items():
        for chunk in _leak_windows(m["when_to_use"].lower(), window=window):
            assert chunk not in rendered, (
                "macro %s 의 when_to_use 에서 %d자 연속 구간이 프롬프트로 샜다: %r"
                % (mid, window, chunk)
            )


# ---- SEED_DOC 이 컴파일 산출물에 조용히 갈아치워지지 않는지 ----------------------------
# dspy_service._load_program() 은 PROGRAM 파일이 있으면
# `prog.signature = prog.signature.with_instructions(instr)` 로 SEED_DOC(따라서 이 파일이
# 만든 mechanism/when_to_use 분리)을 통째로 대체한다.
def test_no_compiled_program_shadows_seed_doc():
    """🔴 P3: 예전 버전은 `PROGRAM == ""` 를 어서션했는데, 이 레포의 문서화된 LLM 레인 설정은
    `DSPY_PROGRAM=__seed_only__` 다(.claude/CLAUDE.md Gotchas, 342행). 그 값은 `""` 가 아니고
    `os.path.exists("__seed_only__")` 도 False 라 SEED_DOC 은 실제로 안 갈리는데, 예전 어서션은
    `PROGRAM == ""` 만 봐서 이 문서화된 정상 설정에서 헛불을 냈다(리뷰 라운드 1 실측:
    `PROGRAM='__seed_only__'` 에서 1 failed).

    지켜야 하는 명제는 "PROGRAM 이 빈 문자열이다"가 아니라 "SEED_DOC 이 실제로 안 갈렸다"이므로
    `_load_program()` 을 실행하고 live `_state["instructions"]` 가 `SEED_DOC` 인지 직접 잰다.
    컴파일 산출물이 진짜로 나타나면(`instr` 이 있고 `with_instructions()` 가 불림) 이 값은
    `SEED_DOC` 이 아니게 되고 이 테스트가 빨개진다.

    한계: 이 테스트는 **테스트 프로세스 안에서** `_load_program()` 을 새로 호출해 잰다. 실제로
    떠 있는 dspy_service 프로세스의 `_state` 를 재는 게 아니다 -- 서비스가 이미 다른 PROGRAM
    값으로 부팅된 상태를 이 테스트가 관측하지는 못한다. 서비스 재기동 시점의 환경변수가 이
    테스트를 도는 프로세스의 환경변수와 같다는 전제 위에 서 있다."""
    llm_service_dir = os.path.join(HERE, "..", "..", "src", "respec", "llm_service")
    llm_service_dir = os.path.abspath(llm_service_dir)
    if llm_service_dir not in sys.path:
        sys.path.insert(0, llm_service_dir)
    import dspy_service  # noqa: E402

    dspy_service._load_program()
    assert dspy_service._state["instructions"] == dspy_service.SEED_DOC, (
        "_load_program() 이후 live instructions 가 SEED_DOC 이 아니다 -- 컴파일된 프로그램이 "
        "mechanism/when_to_use 분리를 실제 프롬프트 경로에서 갈아치웠다는 뜻이다."
    )
