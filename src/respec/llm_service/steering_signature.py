"""steering_signature.py -- the DSPy signature that returns a STEERING VECTOR, not a macro name.

See wm4spacecraft_manufacturing/md/DESIGN_STEERING.md.

WHY THIS IS A DIFFERENT SIGNATURE FROM `PickMacro`
==================================================
`PickMacro` asks the model for a label.  That output cannot be combined with the surrogate --
only substituted for it -- so the two producers can never do better than whichever is stronger.
This signature asks for a direction in the SAME action space the surrogate scores in, so the two
compose:  score(a) = norm(Q̂(s,a)) + β(c)·steer(a).

WHAT DSPy IS OPTIMISING
=======================
Not "pick better macros".  Getting a well-formed (u, w, confidence) back, every time, under
optimisation pressure.  The metric below scores schema validity FIRST and decision quality second,
because a producer that returns unparseable output at 10% rate is unusable regardless of how good
the other 90% are.  That is the honest reframing of the DSPy work: robustness, not accuracy.

This module imports dspy lazily so the schema can be inspected (and unit-tested) in environments
where dspy is not installed -- the wm4 venv does not have it, the hjcrl venv does.

────────────────────────────────────────────────────────────────────────────────────────────
[한국어 요약]
기존 PickMacro 는 '매크로 이름' 하나를 받아서 surrogate 와 합칠 수가 없었다(대체만 가능).
이 signature 는 surrogate 와 **같은 행동공간의 방향 벡터**를 받아서 점수를 더할 수 있게 한다.

DSPy 가 최적화하는 대상은 '더 좋은 매크로'가 아니라 **형식이 깨지지 않는 구조화 출력**이다.
그래서 아래 metric 은 스키마 유효성을 먼저 보고 결정품질은 그 다음에 본다. 10% 확률로 파싱이
안 되는 producer 는 나머지 90% 가 아무리 좋아도 못 쓴다.

dspy 는 함수 안에서 늦게 import 한다(환경에 따라 없을 수 있으므로 스키마만 보는 건 가능하게).
────────────────────────────────────────────────────────────────────────────────────────────
"""

MACROS = ["NOOP", "Replace", "Deprioritize", "ForbidZone", "ReformTeam"]
ACTION_DESCRIPTORS = ["a_cost", "a_intervenes", "a_soft",
                      "a_restores_capacity", "a_relocates_work", "a_spatial"]

INSTRUCTIONS = """You are steering a multi-robot assembly build that just hit an unexpected event.

Do NOT name the action to take. Instead describe, as numbers, WHAT KIND of response the situation
calls for. A separate learned model already scores the concrete options; your vector adjusts its
ranking. This matters because the event may be a type neither of you has seen, and a direction in
action-space still transfers where a memorised label does not.

Return exactly these fields:

u  -- 5 numbers in [-1, 1], one per macro, in this fixed order:
      [NOOP, Replace, Deprioritize, ForbidZone, ReformTeam]
      Positive = this response fits the situation; negative = it would make things worse.

w  -- 6 numbers in [-1, 1], preferences over the AXES of an action, in this fixed order:
      a_cost              tolerance for an expensive intervention (negative = prefer cheap)
      a_intervenes        acting at all vs deliberate restraint
      a_soft              adjusting priorities vs imposing a hard constraint
      a_restores_capacity putting lost execution capacity back (e.g. a spare robot)
      a_relocates_work    moving work or team composition elsewhere
      a_spatial           changing spatial geometry (no-go regions, routes)
      This is the part that generalises to an action nobody has scored before.

confidence -- one number in [0, 1]. Your actual reliability here, not your enthusiasm. If the
      situation is ambiguous or unlike anything described, say so with a low number. A low
      confidence is USED (it shrinks how much your vector moves the decision); it is not penalised.

rationale -- one sentence. For the human audit log. It does not affect the decision.

Adaptation is not free: NOOP costs 0, Deprioritize 0.3, Replace / ForbidZone / ReformTeam 1.0.
Restraint is often correct when slack or spares absorb the disruption."""


def build_signature():
    """Return the dspy.Signature class. Imports dspy at call time (see module docstring)."""
    import dspy

    class SteerDecision(dspy.Signature):
        __doc__ = INSTRUCTIONS

        event = dspy.InputField(desc="natural-language description of what just happened")
        state = dspy.InputField(desc="six physical descriptors: harm, work_at_risk, resource_loss, "
                                     "recovery_capacity, progress, slack (each 0-1)")
        valid_macros = dspy.InputField(desc="which macros are legal here; entries outside this "
                                            "list will be discarded, so do not favour them")

        u = dspy.OutputField(desc="5 comma-separated numbers in [-1,1], order: "
                                  "NOOP, Replace, Deprioritize, ForbidZone, ReformTeam")
        w = dspy.OutputField(desc="6 comma-separated numbers in [-1,1], order: a_cost, "
                                  "a_intervenes, a_soft, a_restores_capacity, a_relocates_work, "
                                  "a_spatial")
        confidence = dspy.OutputField(desc="single number in [0,1]")
        rationale = dspy.OutputField(desc="one sentence")

    return SteerDecision


def parse_numbers(text, n):
    """'0.1, -0.2, 0.3' -> [0.1, -0.2, 0.3]. 개수가 안 맞으면 None(=스키마 위반)을 돌려준다.

    LLM 은 대괄호·줄바꿈·설명을 섞어 보내므로 숫자만 뽑되, **개수가 틀리면 조용히 채우지 않는다.**
    빈 자리를 0 으로 메우면 스키마 위반이 유효한 응답으로 둔갑해 견고성 지표가 거짓이 된다.
    """
    import re
    if text is None:
        return None
    found = re.findall(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", str(text))
    if len(found) != n:
        return None
    try:
        return [float(x) for x in found]
    except ValueError:
        return None


def to_payload(pred):
    """dspy Prediction -> steering.parse_steering 가 먹는 dict. 못 뽑은 필드는 넣지 않는다."""
    out = {}
    u = parse_numbers(getattr(pred, "u", None), len(MACROS))
    w = parse_numbers(getattr(pred, "w", None), len(ACTION_DESCRIPTORS))
    c = parse_numbers(getattr(pred, "confidence", None), 1)
    if u is not None:
        out["u"] = u
    if w is not None:
        out["w"] = w
    if c is not None:
        out["confidence"] = c[0]
    out["rationale"] = str(getattr(pred, "rationale", ""))[:500]
    return out


def schema_first_metric(example, pred, trace=None):
    """DSPy 옵티마이저용 점수. **스키마가 먼저, 결정품질은 그 다음.**

        0.0  파싱 불가
        0.5  형식은 맞음
        +0.5 정답 매크로가 u 의 argmax 와 일치(가능할 때만)

    이 순서가 설계의 핵심이다. 결정품질만 보면 옵티마이저가 '가끔 깨지지만 잘 맞히는' 프로그램을
    고르는데, 그건 배포할 수 없다.
    """
    payload = to_payload(pred)
    if "u" not in payload:
        return 0.0
    score = 0.5
    gold = getattr(example, "best_macro", None)
    if gold is not None:
        u = payload["u"]
        if int(max(range(len(u)), key=lambda i: u[i])) == int(gold):
            score += 0.5
    return score


if __name__ == "__main__":
    print("macros            :", MACROS)
    print("action descriptors:", ACTION_DESCRIPTORS)
    print("\nparse_numbers tests")
    for t, n in [("0.1, -0.2, 0.3, 0.0, 0.4", 5),
                 ("[0.1, -0.2, 0.3, 0.0, 0.4]", 5),
                 ("0.1, 0.2", 5),
                 (None, 5)]:
        print("  %-30r n=%d -> %s" % (t, n, parse_numbers(t, n)))
    try:
        build_signature()
        print("\ndspy available: signature built")
    except ImportError:
        print("\ndspy not installed here (expected in this venv) -- schema still inspectable")
