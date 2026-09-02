# `expressible` 귀속 — 두 번째 필드 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 옛 `expressible` 문구(메뉴 전체 범위)를 **두 번째 필드 `menu_expressible`** 로 되살려,
한 호출 안에서 두 질문의 답을 동시에 받는다. 두 필드의 차이가 **메뉴 artifact 의 크기**다.

**Architecture:** `COMMON_ARGS` 를 **필수/선택**으로 가른다. 스키마에는 둘 다 실리지만
(`build_tools` 가 `COMMON_ARGS` 로 tool 을 만든다), `check_tool_args` 의 필수 집합에는 **필수만**
들어간다. 그래서 모델이 새 필드를 빠뜨려도 거절이 아니라 `None`(못 쟀다)이다. 서비스는 그 값을
기존 `expressible` 과 **같은 삼상 규약**으로 읽어 응답에 싣는다. 결정에는 절대 안 쓴다.

**Tech Stack:** Python 3.12 (`.venv/`), dspy 3.3.0, FastAPI, pytest.

**Spec:** `docs/superpowers/specs/2026-09-02-expressible-attribution-design.md`
(계획과 spec 이 어긋나면 **spec 이 이긴다.**)

## Global Constraints

🔴 **git**
- 작업트리에 **남의 삭제 218건**이 있다. `git add -A` · `git add .` · `git commit -a` **금지.**
  커밋 전에 `git diff --cached --name-status | grep -c '^D'` 가 **0** 인지 확인하라.
- `git checkout` · `git stash` · `git restore` · `git clean` **금지.**
- 브랜치: `oracle-rebuild-night-2026-08-10`
- 🔴 **`test/runtests.jl` 을 건드리지 않는다.** cargo-ban 레인이 그 파일을 동시에 만진다.
  이 레인은 **기존 pytest 파일에 시험을 얹는다** — 새 파일도 안 만든다.

🔴 **실행 명령**
- Python 은 **언제나** 레포 루트의 `.venv/bin/python`. 맨 `python`/`pytest` 금지.
- 이 레인은 **Julia 를 한 번도 부르지 않는다.** cargo-ban 이 `src/` 를 고치는 중이라
  Julia 를 띄우면 반쯤 고쳐진 트리를 컴파일하고 서로의 precompile 캐시를 흔든다.

🔴 **측정 규약**
- **빈-통과 방지 단언을 반드시 넣어라.** "0개를 검사하고 초록" 이 이 레포 최악의 실패다.
- **삼상 규약**: "못 쟀다" 는 `None` 이지 `False` 가 아니다. 절대 섞지 마라.
- **변이 시험**: 각 게이트마다 생산 코드에 변이를 심어 **실제로 빨개지는지** 보고 되돌려라
  (되돌린 뒤 `git diff` 가 비어 있는지 확인). 머리말의 "이 파일이 X 를 지킨다" 는 증거가 아니다.

🔴 **설계 불변**
- `_EXPRESSIBLE_DESC`(현행, NOOP 제외)를 **한 글자도 안 바꾼다.** 그것이 결정에 쓰이는 문구다.
- `no_intervention` 을 메뉴에서 빼지 않는다.
- `synthesize.py` 의 발화 조건(`expressible == False`)을 안 바꾼다.
- `menu_expressible` 은 **결정에 절대 안 들어간다.** `chosen`·`ranking`·합성 어디에도.

---

## File Structure

| 파일 | 책임 | 상태 |
|---|---|---|
| `src/respec/llm_service/tool_registry.py` | `_MENU_EXPRESSIBLE_DESC` · `COMMON_ARGS_REQUIRED` / `COMMON_ARGS_OPTIONAL` / `COMMON_ARGS` · `check_tool_args` 의 필수/선택 분리 | 수정 |
| `src/respec/llm_service/test_tool_registry.py` | Task 1 게이트 (G-1·G-2·G-3·G-5·G-6) | 수정 |
| `src/respec/llm_service/dspy_service.py` | tool 인자에서 삼상으로 읽어 응답에 싣기 | 수정 |
| `src/respec/llm_service/test_macro_returns_tool_call.py` | Task 2 게이트 (G-4) | 수정 |

**기준선(집행 직전에 다시 재라):** `.venv/bin/python -m pytest src/respec/llm_service -q`
= **213 passed, 5 skipped** (2026-09-02 `5c0db890` 실측).

---

### Task 1: 스키마와 검증기 — 필수/선택을 가르고 두 번째 질문을 싣는다

**Files:**
- Modify: `src/respec/llm_service/tool_registry.py`
- Test: `src/respec/llm_service/test_tool_registry.py`

**Interfaces:**
- Produces: `tool_registry.COMMON_ARGS_REQUIRED(emitted) -> dict` (지금의 네 키) ·
  `tool_registry.COMMON_ARGS_OPTIONAL -> tuple[str, ...]` (= `("menu_expressible",)`) ·
  `tool_registry.COMMON_ARGS(emitted) -> dict` (필수 ∪ 선택, **스키마용**) ·
  `tool_registry._MENU_EXPRESSIBLE_DESC -> str`
- Consumes: 없음 (이 레인의 첫 태스크)
- Task 2 가 쓰는 것: 스키마에 `menu_expressible` 키가 있다는 사실 하나.

- [ ] **Step 1: 실패하는 시험을 쓴다**

`src/respec/llm_service/test_tool_registry.py` **맨 아래**에 붙인다.

```python
# =================================================================================================
# 2026-09-02 — `expressible` 의 귀속: 옛 문구를 두 번째 필드로 되살린다
# spec: docs/superpowers/specs/2026-09-02-expressible-attribution-design.md
# =================================================================================================

# 🔴 G-2 의 비교 대상. `2633d855` **직전**의 `_EXPRESSIBLE_DESC` 를 **손으로 박은 것**이다.
#    코드에서 유도하면(예: `tool_registry._MENU_EXPRESSIBLE_DESC`) 이 시험은 항진이 된다 —
#    비교축이 조용히 따라 움직이는 것을 잡는 게 목적이므로 리터럴이어야 한다.
#    출처: git show 2633d855^:src/respec/llm_service/tool_registry.py
_OLD_WORDING_VERBATIM = (
    "false if NOTHING in this tool menu can remove the CAUSE of what you observed -- "
    "i.e. you are calling a tool only because you must, not because it fixes anything. "
    "Answering NOOP because intervening is unnecessary is NOT this: that is true. "
    "Set false when the fix this event needs is outside the menu entirely.")


def test_menu_expressible_is_on_every_tool_schema():
    """G-1. 두 질문을 나란히 물으려면 **세 tool 전부** 두 필드를 들고 있어야 한다.

    한 tool 만 빠지면 그 tool 이 불린 사건에서 대조가 통째로 비는데, 응답 모양은 정상이라
    아무도 못 본다.
    """
    tools = build_tools(AGENTS, ["NOOP", "Replace", "SwapBattery"])
    assert len(tools) == 3, "빈-통과 방지: tool 이 3개가 아니면 이 시험은 아무것도 안 잰다"
    for t in tools:
        keys = set(t.args)
        assert "expressible" in keys, "결정용 필드가 사라졌다: %s" % sorted(keys)
        assert "menu_expressible" in keys, \
            "대조용 필드가 %s 에 없다 -- 이 tool 이 불린 사건은 대조가 빈다" % t.name


def test_menu_expressible_asks_the_old_question_byte_for_byte():
    """G-2. 비교축이 성립하려면 **옛 녹화가 받은 질문과 같은 질문**이어야 한다.

    🔴 한 글자라도 다르면 S1 의 115/115 · 6/6 과 나란히 놓을 수 없다. 그래서 바이트 동일이
    계약이고, 위 리터럴이 그 계약의 진실원이다.
    """
    assert tool_registry._MENU_EXPRESSIBLE_DESC == _OLD_WORDING_VERBATIM

    # 그리고 두 질문이 **실제로 다른 질문**이어야 한다 -- 같아지면 대조가 무의미하다.
    assert tool_registry._EXPRESSIBLE_DESC != tool_registry._MENU_EXPRESSIBLE_DESC
    assert "OTHER THAN NOOP" in tool_registry._EXPRESSIBLE_DESC, \
        "결정용 문구가 NOOP 을 범위에서 빼고 있어야 한다(2633d855)"
    assert "OTHER THAN NOOP" not in tool_registry._MENU_EXPRESSIBLE_DESC, \
        "대조용 문구는 옛 범위(메뉴 전체)를 그대로 물어야 한다"


def test_a_missing_menu_expressible_is_not_a_rejection():
    """🔴 G-3. 측정용 필드 하나가 **런을 죽일 수 있으면 안 된다.**

    `check_tool_args` 는 `want` 에 없는 키를 `off_schema_args` 로 거절하고, `want` 에 있는데
    안 실린 키를 `missing_args` 로 거절한다. 즉 새 키를 그냥 `COMMON_ARGS` 에 더하면 자동으로
    **필수**가 되고, 모델이 빠뜨리는 순간 `chosen=""` -> `available=false` -> `policy.jl:1703`
    이 런을 죽인다.
    """
    valid = ["NOOP", "Replace", "SwapBattery"]
    ids = [a["id"] for a in AGENTS]
    without = {"agent": ids[0], "macro": "SwapBattery", "reasoning": "r",
               "expressible": True, "ranking": "SwapBattery, Replace, NOOP"}

    assert tool_registry.check_tool_args("deliver_battery", without, valid, ids) is None, \
        "선택 필드가 빠졌다고 거절하면 안 된다"

    # 실려도 정상이어야 한다(`off_schema_args` 로 튕기면 애초에 받을 수가 없다).
    with_it = dict(without, menu_expressible=False)
    assert tool_registry.check_tool_args("deliver_battery", with_it, valid, ids) is None

    # 🔴 음성 대조 — 검사가 통째로 죽은 것과 구별한다. **필수** 키가 빠지면 여전히 거절이다.
    for key in ("expressible", "macro", "reasoning", "ranking"):
        broken = {k: v for k, v in without.items() if k != key}
        why = tool_registry.check_tool_args("deliver_battery", broken, valid, ids)
        assert why is not None and why.startswith("missing_args"), \
            "필수 키 %r 이 빠졌는데 통과했다 -- 검사가 죽었다: %r" % (key, why)


def test_a_non_bool_menu_expressible_is_named_and_never_masks_the_decision_field():
    """G-5. 실렸는데 bool 이 아니면 **그 사유로** 거절된다. 그리고 검사 **순서**를 지킨다.

    🔴 기존 순서는 리뷰가 실측으로 고정했다. `expressible` 과 `menu_expressible` 이 동시에
    잘못된 호출은 **결정용 필드의 사유**를 내야 한다 -- 측정용 필드가 결정용 필드의 결함을
    가리면 그 행을 읽는 사람이 원인을 반대로 읽는다.
    """
    valid = ["NOOP", "Replace", "SwapBattery"]
    ids = [a["id"] for a in AGENTS]
    base = {"agent": ids[0], "macro": "SwapBattery", "reasoning": "r",
            "expressible": True, "ranking": "SwapBattery, Replace, NOOP"}

    why = tool_registry.check_tool_args(
        "deliver_battery", dict(base, menu_expressible="False"), valid, ids)
    assert why is not None and why.startswith("menu_expressible_not_a_bool"), why

    both = dict(base, expressible="False", menu_expressible="False")
    why2 = tool_registry.check_tool_args("deliver_battery", both, valid, ids)
    assert why2 is not None and why2.startswith("expressible_not_a_bool"), \
        "측정용 필드가 결정용 필드의 사유를 가렸다: %r" % why2


def test_the_decision_field_is_untouched_by_this_lane():
    """G-6. 이 레인이 `2633d855` 을 안 건드렸다는 증거.

    이 파일의 기존 게이트 둘(`test_expressible_scope_excludes_noop` ·
    `test_noop_is_still_on_the_menu`)이 그대로 초록인 것과 짝이다. 여기서는 결정 경로가
    **여전히 `expressible` 하나만** 본다는 것을 못박는다.
    """
    valid = ["NOOP", "Replace", "SwapBattery"]
    ids = [a["id"] for a in AGENTS]
    # 결정용은 참, 측정용은 거짓 -- 이 조합이 거절되면 두 필드가 얽힌 것이다.
    args = {"agent": ids[0], "macro": "SwapBattery", "reasoning": "r",
            "expressible": True, "menu_expressible": False,
            "ranking": "SwapBattery, Replace, NOOP"}
    assert tool_registry.check_tool_args("deliver_battery", args, valid, ids) is None
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q`
Expected: **5 failed** — `AttributeError: module 'tool_registry' has no attribute
'_MENU_EXPRESSIBLE_DESC'` 와 `menu_expressible` 부재/`off_schema_args`.

- [ ] **Step 3: 옛 문구를 되살린다**

`tool_registry.py` 의 `_EXPRESSIBLE_DESC` 주석 블록 **바로 뒤**(`_REASONING_DESC` 앞)에 넣는다.

```python
# =================================================================================================
# 🔴 2026-09-02 — 대조용 두 번째 질문. spec: 2026-09-02-expressible-attribution-design.md
#
# 이것은 `2633d855` **직전**의 `_EXPRESSIBLE_DESC` 를 **바이트 그대로** 되살린 것이다.
# 왜 두 벌인가. `expressible=true` 의 원인이 둘이고(메뉴 artifact / 사실 부재) 지금 못 가른다.
# `2633d855` 가 질문 범위에서 NOOP 을 빼면서 디스크의 모든 녹화(S1 의 115/115 · 6/6 포함)와
# 비교할 축이 사라졌다 — 그 커밋이 스스로 "옛 3/3 은 이 문구의 성적이 아니다" 라고 적었다.
# 두 질문을 한 호출에서 나란히 물으면 그 축이 **같은 샘플 안에서** 돌아온다.
#
# 🔴 이 문자열을 `_EXPRESSIBLE_DESC` 에서 **유도하지 않는다.** 이 레포는 "두 벌은 갈린다" 를
#    원칙으로 삼지만 여기서는 그 반대가 목적이다 — 결정용 문구를 고칠 때 비교축이 조용히
#    따라 움직이면 대조가 무효가 된다. 갈리는 것을 막는 것은 `test_tool_registry.py` 의
#    `test_menu_expressible_asks_the_old_question_byte_for_byte` 이고, 그 시험은 비교
#    문자열을 **리터럴로** 들고 있다(코드에서 유도하면 항진이 된다).
#
# 🔴 이 필드는 **측정 전용**이다. 결정(`chosen`·`ranking`)에도, L2 합성 발화 조건에도 절대
#    들어가지 않는다. 합성은 계속 `expressible == False` 하나로만 쏜다.
# =================================================================================================
_MENU_EXPRESSIBLE_DESC = (
    "false if NOTHING in this tool menu can remove the CAUSE of what you observed -- "
    "i.e. you are calling a tool only because you must, not because it fixes anything. "
    "Answering NOOP because intervening is unnecessary is NOT this: that is true. "
    "Set false when the fix this event needs is outside the menu entirely.")
```

- [ ] **Step 4: `COMMON_ARGS` 를 필수/선택으로 가른다**

지금의 `def COMMON_ARGS(emitted):` 를 **이름만** `COMMON_ARGS_REQUIRED` 로 바꾸고(본문과
docstring 은 한 글자도 안 바꾼다), 그 **아래**에 다음을 더한다.

```python
# 🔴 선택 인자 — 스키마에는 실리지만 `check_tool_args` 의 **필수 집합에는 안 들어간다.**
#    왜 이 구별이 필요한가(실측): `check_tool_args` 는 `want = set(COMMON_ARGS_REQUIRED(...))`
#    로 필수 집합을 만들고 `missing = want - set(args)` 가 비지 않으면 거절한다. 동시에
#    `off_schema_args` 가 `want` 밖의 키를 거절한다. 즉 새 키를 그냥 더하면 **받아지려면
#    필수여야** 하고, 모델이 한 번 빠뜨리는 순간 `missing_args` -> `chosen=""` ->
#    `available=false` -> `policy.jl:1703` 이 런을 죽인다. 측정용 필드가 런을 죽이면 안 된다.
COMMON_ARGS_OPTIONAL = ("menu_expressible",)


def COMMON_ARGS(emitted):
    """tool 스키마에 실리는 **전체** 인자 = 필수 ∪ 선택. `build_tools` 가 이것을 쓴다.

    🔴 `check_tool_args` 는 이 함수를 쓰지 않는다 — 거기서는 `COMMON_ARGS_REQUIRED` 다.
    두 자리가 같은 함수를 쓰면 선택 인자가 조용히 필수가 된다.
    """
    args = COMMON_ARGS_REQUIRED(emitted)
    args["menu_expressible"] = {"type": "boolean",
                                "description": _MENU_EXPRESSIBLE_DESC}
    return args
```

- [ ] **Step 5: `check_tool_args` 가 필수만 요구하고 선택을 허용하게 한다**

`tool_registry.py:219-229` 의 다섯 줄을 이렇게 바꾼다.

```python
    want = set(COMMON_ARGS_REQUIRED(valid)) | ({"agent"} if _needs_agent(name) else {"reason"})
    missing = sorted(want - set(args))
    if missing:
        return "missing_args: %s (요구=%s 실려온=%s)" % (
            ",".join(missing), ",".join(sorted(want)), ",".join(sorted(args)))
    # 🔴 선택 인자는 `want` 에 없지만 실려도 정상이다. `want` 로만 판정하면 새 필드가
    #    `off_schema_args` 로 튕겨 나가 애초에 받을 수가 없다.
    extra = sorted(set(args) - want - set(COMMON_ARGS_OPTIONAL))
    if extra:
        return "off_schema_args: %s (요구=%s 선택=%s)" % (
            ",".join(extra), ",".join(sorted(want)), ",".join(COMMON_ARGS_OPTIONAL))
    # 🔴 bool 은 `isinstance` 로 본다. `bool("False") is True` 라 캐스팅하면 거짓 True 가 난다.
    if not isinstance(args["expressible"], bool):
        return "expressible_not_a_bool: %r" % (args["expressible"],)
    # 🔴 선택 인자라 **실려 있을 때만** 본다. 그리고 위치가 계약이다 — 결정용 필드의 사유가
    #    먼저 나와야 한다(측정용이 결정용의 결함을 가리면 원인을 반대로 읽는다).
    if "menu_expressible" in args and not isinstance(args["menu_expressible"], bool):
        return "menu_expressible_not_a_bool: %r" % (args["menu_expressible"],)
```

- [ ] **Step 6: 시험이 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_tool_registry.py -q`
Expected: PASS, 실패 0.

- [ ] **Step 7: 변이 시험 — 게이트가 진짜 잡는지 본다**

넷을 하나씩 심고 돌린 뒤 **되돌린다**(되돌린 뒤 `git diff` 가 비어야 한다).

| 변이 | 빨개져야 하는 시험 |
|---|---|
| `_MENU_EXPRESSIBLE_DESC` 에서 `"-- "` 하나 지우기 | `..._byte_for_byte` |
| `COMMON_ARGS` 의 `args["menu_expressible"] = …` 줄 삭제 | `..._is_on_every_tool_schema` |
| `check_tool_args` 의 `- set(COMMON_ARGS_OPTIONAL)` 삭제 | `..._is_not_a_rejection` |
| `COMMON_ARGS_REQUIRED(valid)` 를 `COMMON_ARGS(valid)` 로 되돌리기 | `..._is_not_a_rejection` |

- [ ] **Step 8: 스위트 전체가 안 깨졌는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service -q`
Expected: **218 passed, 5 skipped** (기준선 213 + 새 시험 5).

- [ ] **Step 9: 커밋**

```bash
git add src/respec/llm_service/tool_registry.py src/respec/llm_service/test_tool_registry.py
git diff --cached --name-status | grep -c '^D'      # 0 이어야 한다
git commit
```

커밋 메시지는 **무엇을 왜** 바꿨는지 + 변이 4건이 전부 RED 였다는 실측 + 스위트 수치를 담는다.

---

### Task 2: 서비스가 그 값을 삼상으로 읽어 응답에 싣는다

> **선행:** Task 1 (스키마에 `menu_expressible` 이 있어야 모델이 낼 수 있다).

**Files:**
- Modify: `src/respec/llm_service/dspy_service.py`
- Test: `src/respec/llm_service/test_macro_returns_tool_call.py`

**Interfaces:**
- Consumes: Task 1 의 `menu_expressible` 스키마 키.
- Produces: `/macro` 응답의 `"menu_expressible": True | False | None`.
  `_blank_decision` 도 같은 키를 `None` 으로 낸다 — 키가 사라지면 소비자가 "레인이 안 돌았다"
  와 "값이 없다" 를 못 가른다(이 파일의 기존 규약).

- [ ] **Step 1: 실패하는 시험을 쓴다**

`test_macro_returns_tool_call.py` **맨 아래**에 붙인다.

```python
# =================================================================================================
# 2026-09-02 — 대조용 두 번째 질문이 응답에 실린다 (G-4)
# spec: docs/superpowers/specs/2026-09-02-expressible-attribution-design.md
# =================================================================================================

def test_menu_expressible_is_reported_when_the_model_answers_it():
    """모델이 두 질문에 **다르게** 답한 사건이 이 레인이 재려는 바로 그 사건이다.

    `expressible=False`(NOOP 빼면 못 고친다) + `menu_expressible=True`(메뉴 전체로는 된다)
    = **메뉴 artifact 가 실재한다**.
    """
    _install(_call("deliver_battery", expressible=False, menu_expressible=True), fc=False)
    out = svc.macro(_req())
    assert out["expressible"] is False
    assert out["menu_expressible"] is True
    assert out["tool_arg_error"] is None, "정상 호출이 거절되면 안 된다: %r" % out["tool_arg_error"]


def test_a_missing_menu_expressible_is_none_not_false():
    """🔴 삼상 규약. 안 실린 것은 **못 쟀다**(`None`)이지 `False` 가 아니다.

    `False` 로 접으면 "메뉴 artifact 가 실재한다"(`expressible=False` ∧
    `menu_expressible=False` 가 아닌 칸) 집계가 거짓으로 부풀어 오른다 — 이 레인이 재려는
    바로 그 값이다.
    """
    _install(_call("deliver_battery", expressible=False), fc=False)   # 새 필드 없이
    out = svc.macro(_req())
    assert out["expressible"] is False
    assert out["menu_expressible"] is None, "빠진 것을 False 로 접었다"
    assert out["tool_arg_error"] is None, "선택 필드 부재가 거절이 되면 안 된다"


def test_a_non_bool_menu_expressible_is_none_and_never_erases_the_decision():
    """파싱 실패도 `None` 이고, **결정은 살아남는다.**

    기존 `expressible` 이 같은 축에서 그렇게 동작한다
    (`test_a_non_bool_expressible_is_none_not_a_false_true`) — 측정용 필드가 그보다 더 큰
    권한을 가지면 안 된다.
    """
    _install(_call("deliver_battery", menu_expressible="False"), fc=False)
    out = svc.macro(_req())
    assert out["menu_expressible"] is None, "bool() 로 감싸면 여기가 True 가 된다"
    assert out["chosen"] == "SwapBattery", "측정용 필드가 결정을 지웠다"
    assert out["tool_arg_error"] is not None and "menu_expressible" in out["tool_arg_error"]


def test_the_blank_decision_carries_the_key_too():
    """레인이 안 돈 사건에서도 **키는 있어야** 한다 — 없으면 소비자가 두 사건을 못 가른다."""
    blank = svc._blank_decision(["NOOP"], "state line", "no_tools", [])
    assert "menu_expressible" in blank, "키가 통째로 사라지면 '안 돌았다' 와 '값 없다' 가 같아진다"
    assert blank["menu_expressible"] is None
```

- [ ] **Step 2: 돌려서 실패를 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_macro_returns_tool_call.py -q`
Expected: **4 failed** — `KeyError: 'menu_expressible'`.

- [ ] **Step 3: 서비스가 읽게 한다**

`dspy_service.py:1583-1586` 의 `expressible` 추출 **바로 뒤**에 같은 모양으로 더한다.

```python
    # 🔴 2026-09-02 — 대조용 두 번째 질문(spec §3-1). 기존 `expressible` 과 **같은 삼상 규약**:
    #    bool 이 아니면 `None`("못 쟀다")이지 `False` 가 아니다. 이 필드는 **측정 전용**이고
    #    결정(`chosen`·`ranking`)과 합성 발화 조건에는 절대 안 들어간다.
    menu_expressible = tool_args_all.get("menu_expressible")
    menu_expressible = menu_expressible if isinstance(menu_expressible, bool) else None
```

- [ ] **Step 4: 응답에 싣는다 (두 자리)**

`dspy_service.py:1671` 의 `"expressible": expressible,` **바로 뒤**:

```python
            # 🔴 측정 전용. `expressible` 과 나란히 두는 이유는 소비자가 둘의 **차이**를
            #    읽기 때문이다(spec §3-1 의 2x2 표). 결정에는 안 쓴다.
            "menu_expressible": menu_expressible,
```

`_blank_decision`(`:1470`)의 `"expressible": None, "macro_tool_agree": None,` 줄을:

```python
            "expressible": None, "menu_expressible": None, "macro_tool_agree": None,
```

- [ ] **Step 5: 시험이 통과하는지 확인한다**

Run: `.venv/bin/python -m pytest src/respec/llm_service/test_macro_returns_tool_call.py -q`
Expected: PASS.

- [ ] **Step 6: 변이 시험**

| 변이 | 빨개져야 하는 시험 |
|---|---|
| `isinstance(...) else None` 을 `bool(...)` 로 | `..._is_none_and_never_erases_the_decision` |
| `_blank_decision` 의 새 키 삭제 | `..._blank_decision_carries_the_key_too` |
| `menu_expressible = tool_args_all.get(...)` 를 `= False` 로 | `..._is_none_not_false` |

- [ ] **Step 7: 스위트 전체**

Run: `.venv/bin/python -m pytest src/respec/llm_service -q`
Expected: **222 passed, 5 skipped** (Task 1 뒤 218 + 새 시험 4).

🔴 `_LANE_KEYS`(`test_macro_returns_tool_call.py:347`)가 레인 키 집합을 못박고 있다.
빨개지면 **그 목록에 `menu_expressible` 을 더하는 것이 옳은 수정이다** — 새 키가 레인 키이므로.
빨개지지 않으면 그 게이트가 무엇을 덮는지 확인하고 보고하라(덮지 않는다면 그것이 발견이다).

- [ ] **Step 8: 커밋**

```bash
git add src/respec/llm_service/dspy_service.py src/respec/llm_service/test_macro_returns_tool_call.py
git diff --cached --name-status | grep -c '^D'      # 0 이어야 한다
git commit
```

---

## 이 계획이 **안 하는** 것 (spec §4·§6)

- `_EXPRESSIBLE_DESC` 를 안 바꾼다. `2633d855` 을 안 되돌린다.
- `no_intervention` 을 메뉴에서 안 뺀다.
- `synthesize.py` 의 발화 조건을 안 바꾼다.
- 사실 블록(`m/T` · 창 상태)을 안 건드린다 — 둘 다 Julia 가 보내야 한다.
- Julia(`policy.jl` 의 결정행 배선)를 안 건드린다.
- 유료 호출을 **한 번도 안 낸다.** 측정은 cargo-ban 착지 후 별도 라운드다.

## 집행 결과 (2026-09-02 01:25)

**두 태스크 다 집행됐다.** Task 1 = `e5b7cfb7`, Task 2 = `ee94f66e`.
스위트 **222 passed / 5 skipped** (기준선 213 → +9). 변이 8건 전부 RED 확인 후 복원.
Julia 는 한 번도 안 켰고, `test/runtests.jl` 도 안 건드렸다.

🔴 **계획서가 놓친 세 번째 자리를 변이 시험이 찾아냈다.** `/decide` 의 `out["dspy"]` 가 레인
키를 **손으로** 들고 있고(`dspy_service.py:1776-1782`), **라이브 레인은 `/decide` 로만 들어온다**
(`policy.jl:559`). ⟹ 지금 `menu_expressible` 은 **`/macro` 에서만 관측된다.**

오늘 밤 안 고친 이유(측정으로 뒷받침, Julia 실행 없이):
게이트 `test/tool_lane_keys_survive.jl` **(6)절**이 Julia `TOOL_LANE_KEYS` 와 파이썬 레인 키
집합을 **양방향 등호**로 묶는다. 그 게이트 자신의 추출기(`_PY_EXTRACT`, 순수 파이썬)를 떼어
돌려 재니 **양쪽 다 11 로 맞아 있다.** 올바른 자리(표식 **아래**)에 키를 넣으면 12 vs 11 로
그 게이트가 빨개지는데, cargo-ban 레인이 지금 Julia 스위트를 돌리는 중이라 **검증 못 하는
빨강을 남의 레인에 얹지 않는다.** 표식 **위로 숨겨** 초록을 만드는 것은 소스 주석이 명시적으로
금지한다(줄리아가 영원히 안 나르는 상태가 조용해진다).

## 집행 후 남는 것 (아침에 결정할 것)

1. 🔴 **셋을 한 커밋에서 함께 움직인다 — 유료 측정의 전제조건이다.**
   `/decide` 의 `out["dspy"]` dict(표식 아래) · Julia `tools/monitor/policy.jl` 의
   `TOOL_LANE_KEYS` · `test_macro_returns_tool_call.py` 의 `_LANE_KEYS`.
   그리고 `julia +lts --project=. test/tool_lane_keys_survive.jl` 로 (6)절이 초록인지 확인.
   ⚠️ 그 다음 층이 하나 더 있다: Julia `policy_entry` 가 결정행 키를 손으로 든다(spec §3-5).
2. **유료 라운드 설계** — 어휘 밖 3건 + 대조군, `DSPY_CACHE=0` 으로 **재시작**해서(장수
   프로세스라 환경변수만 바꾸면 옛 레짐이 돈다). 보고할 것: 2×2 표 · 새 필드 **채움률** ·
   `macro`/`ranking` 형식 유효율(스키마가 길어진 대가, spec §7-2) · `llm_billed` 대 `llm_calls`.
3. 사실 블록 Wave 2 — `policy.jl` 이 팀 크기(`m/T`)와 창 상태를 싣게 한다.
