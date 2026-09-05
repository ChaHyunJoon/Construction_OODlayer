"""렌더가 두 표제로 갈리고 인자 경로를 붙인다는 계약. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _block():
    import world_interface as WI
    return WI.build_world_interface_block()


def test_the_two_headings_exist():
    b = _block()
    assert "FUNCTIONS YOU CAN CALL NOW" in b
    assert "FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET" in b


def test_a_callable_method_carries_its_argument_paths():
    b = _block()
    head, _, tail = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    # `close_node!(node::ScheduleNode, env::PlannerEnv)` 는 호출 가능해야 하고,
    # `node` 를 어디서 얻는지가 그 줄 아래 붙어야 한다.
    assert "close_node!" in head
    assert "node <- env.sched.nodes[i]" in head


def test_the_withheld_capabilities_are_in_neither_heading():
    """🔴 D6. 가르는 것은 렌더이지 모집단이 아니다."""
    b = _block()
    for hidden in ("release_pending_assignments!", "recover_stalled_teams!",
                   "resolve_schedule_wedge!", "force_advance_stuck_carrier!",
                   "forbid_heavy_cargo!"):
        assert hidden not in b, "%s 가 샜다" % hidden


def test_the_rules_text_is_byte_identical():
    """🔴 D19. `_RULES` 를 바꾸면 D6 측정이 오염된다."""
    import world_interface as WI
    assert WI._RULES.startswith("HOW YOUR CODE IS CALLED")
    assert "Helper closures defined INSIDE your function body are fine." in WI._RULES
    assert _block().startswith(WI._RULES)


def test_the_second_heading_names_what_is_missing():
    """🔴 설계 §6.2. 둘째 표제는 `- <이름> (…)      missing: <타입>` 이다.

    이름과 시그니처만 있는 평평한 목록은 §1.2 가 문제 삼은 바로 그 모양이고, 이 주석이
    D13(`needs` 채널)의 입력이다 — 모델이 무엇이 없는지 모르면 `needs` 가 0 을 낸다.
    """
    b = _block()
    _, _, tail = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    lines = [l for l in tail.splitlines() if l.startswith("- ")]
    assert lines, "둘째 표제가 비었다"
    assert all("missing: " in l for l in lines), \
        [l for l in lines if "missing: " not in l][:3]


def test_the_first_heading_admits_the_arguments_it_cannot_source():
    """🔴 I1. "every argument is obtainable from env" 아래에 경로 없는 인자를 가진 항목이
    앉아 있었다(실측 32건) — 모델은 `apply_cmd!(node, twist, env)` 를 쓰려다 `node` 를
    어디서 얻는지 못 찾고 다시 placeholder 를 쓴다. 그것이 D11 이 없애려던 §1.2 다.
    """
    b = _block()
    head, _, _ = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    line = [l for l in head.splitlines()
            if l.startswith("- apply_cmd!") and "DepositCargo" in l]
    assert len(line) == 1, line
    assert "missing: DepositCargo, Twist" in line[0]
    # 빈-통과 방지: 인자를 전부 손에 넣을 수 있는 항목에는 그 주석이 없다
    ok = [l for l in head.splitlines()
          if l.startswith("- close_node!") and "ScheduleNode" in l]
    assert len(ok) == 1 and "missing:" not in ok[0], ok


def test_an_id_argument_shows_every_source_and_ranks_none():
    """🔴 R11 → R33. 인자당 `first(ps)` 하나만 실으면 `AbstractID` 의 9개 경로 중 사전순
    첫째만 보인다 — 답의 외양을 한 동전던지기다. R11 이 그것을 넷으로 올렸지만 **어느
    넷인가** 는 여전히 정당화가 필요했고, wave B 가 쓴 판별자(`Dict` 의 선언된 값 타입)는
    실측에서 **반상관**이었다(`agent_policies` 키의 40%만 로봇 / `staging_circles` 키는
    8/8 `AssemblyID` 인데 최하등급).

    🔴 판정 R33: 정적으로 가를 수 없으므로(아홉 경로의 선언된 산출 타입이 9/9 동일)
    **자르지 않는다.** 렌더는 아홉을 다 보여 주고 **사전순**이라 위치가 순위를 뜻하지
    않는다. 설계 §6.2 가 이름 댄 경로도 그 안에 있다.
    """
    b = _block()
    head, _, _ = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    blocks = head.split("\n- ")
    ag = [x for x in blocks if x.startswith("asset_generation ")]
    assert len(ag) == 1, ag
    paths = [l.strip() for l in ag[0].splitlines() if " <- " in l]
    assert len(paths) == 9, paths
    assert any("env.sched.vtx_ids" in p for p in paths), paths
    # 🔴 I1 회귀 방지: `restage_assembly!` 의 전제조건 집합이 렌더에 살아 있다.
    assert any("keys(env.staging_circles)" in p for p in paths), paths
    # 위치가 순위가 아니다 — 사전순 그대로다.
    rhs = [p.split(" <- ", 1)[1] for p in paths]
    assert rhs == sorted(rhs), rhs


def test_the_ambient_accessor_states_its_precondition():
    """🔴 I4. `battery_report()` 는 `BATTERY_FLEET[] === nothing`(기본값)에서 던진다.
    전제조건 없이 광고하면, 모델이 그것을 부르고 body 가 던진 것이 기록에
    `verdict=reject world_maybe_dirty=true` = **모델의 저작 실패**로 남는다.
    """
    b = _block()
    _, _, amb = b.partition("AMBIENT WORLD STATE")
    amb = amb.partition("FUNCTIONS YOU CAN CALL NOW")[0]
    assert "battery_report()" in amb
    assert "BATTERY_FLEET" in amb, amb


# =====================================================================================
# 2026-09-04 Task 3 — L3(`interface_calls ≠ []`)이 유료 런 1 에서 빈 리스트였다. 유료 0건.
#
# 🔴 두 원인이 함께 있었다:
#   (1) 반환 규약. body 는 일을 **다 끝내고** 자기 반환문에서 죽었다 —
#       `return NamedTuple{(:status,)}(:success)` 는 유효한 Julia 가 아니고
#       `MethodError: no method matching length(::Symbol)` 을 던진다.
#   (2) 호출이 아니라 필드 쓰기. L3 의 계측기(`impl_interface_calls`,
#       `src/respec/minted_registration.jl`)는 `Expr(:call)` 머리만 센다 — `env.sched.weights[k] *= f`
#       같은 필드 접근은 `fields` 로 라우팅돼 **구성상** 0 을 기여한다. 광고된 bang 함수가
#       77개이므로 이것은 어휘의 구멍이 아니라 **지시의 부재**였다.
#
# ⚠️ 필드 쓰기는 **금지하지 않는다**(D6 이 다섯 능력을 일부러 감췄다 — 어떤 사건은 필드
#    경로 말고 길이 없다). 이것은 **선호**이지 규칙이 아니고, 아래 셋째 시험이 그 선을 지킨다.
# =====================================================================================
def test_the_rules_show_the_literal_return_form():
    """🔴 (1). 복붙 가능한 한 줄이 렌더에 있어야 한다."""
    b = _block()
    assert "return (; status = :success)" in b
    # 죽인 그 모양을 이름으로 부정한다 — 모델이 그것을 후보로 들고 있으면 못 고른다.
    assert "NamedTuple{(:status,)}(:success)" in b
    assert "length(::Symbol)" in b


def test_the_rules_prefer_calling_over_writing_fields():
    """🔴 (2). 렌더 전문에 "부르는 쪽을 택하라" 는 문장이 있어야 한다."""
    b = _block()
    assert "Prefer CALLING" in b
    assert "FUNCTIONS YOU CAN CALL NOW" in b.partition("Prefer CALLING")[2].partition("\n\n")[0], \
        "선호 문장이 무엇을 부르라는 것인지 표제로 가리키지 않는다"


def test_the_types_heading_no_longer_grants_field_writes_outright():
    """🔴 (2) 의 짝. 옛 표제 `WORLD TYPES (fields you may read and write):` 는 필드 쓰기를
    **무조건 허락**했다 — 모델이 실제로 그 허락을 받아 갔다. 되돌아오면 여기서 빨개진다.
    """
    b = _block()
    assert "WORLD TYPES (fields you may read and write):" not in b
    head = [l for l in b.splitlines() if l.startswith("WORLD TYPES")]
    assert len(head) == 1, head
    assert "last resort" in head[0], head


def test_field_writes_are_not_forbidden():
    """🔴 선을 지킨다: **선호**이지 규칙이 아니다. 하드 금지는 거짓 거절 표면을 만들고,
    D6 이 감춘 다섯 능력 때문에 어떤 사건은 필드 경로 말고 길이 없다.
    """
    import world_interface as WI
    r = WI._RULES
    assert "only when no" in r, r          # 조건부 허용이 살아 있다
    for banned in ("never write", "do not write a field", "must not write"):
        assert banned not in r.lower(), banned


# =====================================================================================
# 2026-09-04 fix round 2 — I2 (독립 검증자). 규약 5 는 표제를 **이름으로** 가리킨다.
#
# 🔴 검증자의 음성 대조: 빌더의 표제를 `CALLABLE FUNCTIONS` 로 개명했더니 **32 시험이 전부
#    초록**이었다. 즉 프롬프트가 "저기 적힌 목록에서 골라라" 라고 하면서 **없는 표제**를
#    가리키는 상태가 아무 소리 없이 성립했다. 위 `test_the_rules_prefer_calling_over_writing_fields`
#    는 규약 5 의 **자기 텍스트**만 봤지 렌더가 그 표제를 실제로 내는지는 안 봤다.
#
# 방어는 두 겹이다:
#   (1) 구조 — `_CALLABLE_HEADING` 하나를 규약 5 와 빌더가 **같이 읽는다**(진실원 하나).
#   (2) 시험 — 아래. 상수를 우회해 빌더에 다른 문자열을 하드코딩하는 편집까지 잡는다.
#       리터럴을 두 번 적지 않는다: 규약 5 의 텍스트에서 표제 이름을 **뽑아내** 렌더와 맞춘다.
# =====================================================================================
def test_rule_5_names_a_heading_the_render_actually_emits():
    import re
    import world_interface as WI
    b = _block()
    m = re.search(r'Prefer CALLING the functions listed under "([^"]+)"', WI._RULES)
    assert m, WI._RULES
    named = m.group(1)

    # (1) 규약 5 가 상수를 읽는다 — 리터럴을 두 번 적는 모양으로 되돌아가지 않았다.
    assert named == WI._CALLABLE_HEADING, (named, WI._CALLABLE_HEADING)

    # (2) 🔴 렌더가 **그 이름의 표제를 실제로 낸다.** 검증자의 개명이 여기서 빨개진다.
    heads = [l for l in b.splitlines() if l.startswith(named)]
    assert heads, (
        "규약 5 가 가리키는 표제 %r 가 렌더에 없다 — 프롬프트가 없는 곳을 가리킨다" % named)
    assert len(heads) == 1, heads

    # (3) 빈-통과 방지: 그 표제 아래가 비어 있으면 가리켜도 소용이 없다.
    body = b.partition(heads[0])[2].partition("\nFUNCTIONS THAT NEED SOMETHING")[0]
    entries = [l for l in body.splitlines() if l.startswith("- ")]
    assert len(entries) > 50, len(entries)
    assert any(l.startswith("- swap_battery!") for l in entries), entries[:5]


# =====================================================================================
# 2026-09-04, 유료 런 2 의 사인 — 규약 6. identifier 는 **객체**다.
#
# 런 2 의 body 는 Task 3 가 가르친 것을 다 지켰다: `return (; status = :success)` 를 썼고
# (런 1 의 사인이 재발하지 않았다), 광고된 `battery_report()` 를 **불렀고**(L3 최초 TRUE),
# 렌더된 전제조건까지 지켰다(`BATTERY_FLEET[] === nothing` 를 먼저 검사). 그러고 나서 여기서
# 죽었다:
#
#     total_energy_J, ..., soc = battery_report()
#     if soc[robot_id] >= mean_soc      # robot_id = "R1"  ->  KeyError: key "R1" not found
#
# `soc` 는 `Dict{Any, Float64}` 인데 키가 `BotID` **객체**다. `Any` 는 모델에게 아무것도
# 안 알려 주므로 모델이 표시용 이름 `"R1"` 을 지어냈다.
#
# 🔴 이것이 **두 런 연속 identifier 환각**이다(런 1 은 필드 이름, 런 2 는 키 타입). 그래서
#    국소 주석이 아니라 **일반 규약**으로 적었다 — `Dict{AbstractID, ...}` 필드가 WORLD TYPES
#    에만 일곱 개이고 같은 착각이 그 전부에서 가능하다.
# =====================================================================================
def test_the_rules_say_identifiers_are_objects_not_strings():
    b = _block()
    r = b.partition("\n\nWORLD TYPES")[0]        # 규약부만 본다
    assert "Identifiers in this world are OBJECTS, never strings" in r, r
    # 어디서 얻는지 — 없으면 "쓰지 마라" 만 있고 대안이 없다.
    assert "keys(env.agent_policies)" in r, r
    # 지어낸 이름이 실제로 무엇을 하는지 이름으로 부정한다.
    assert '`"R1"`-style' in r, r
    assert "KeyError" in r, r


def test_the_rules_explain_the_opaque_dict_any_key_type():
    """🔴 빈-통과 방지 + 실제 사인의 자리. `Dict{Any, ...}` 는 렌더에 **실재한다**
    (`battery_report()` 의 `soc`), 그리고 생성기의 `returns` 는 `Base.return_types` 에서
    기계로 유도되므로 산출물 쪽에서 `Any` 를 좁힐 길이 없다 — 규약이 그 자리를 갚는다.
    """
    b = _block()
    assert "Dict{Any, Float64}" in b, "사인의 전제가 사라졌다 — 규약 6 의 대상이 렌더에 없다"
    r = b.partition("\n\nWORLD TYPES")[0]
    assert "`Dict{Any, ...}`" in r, r
