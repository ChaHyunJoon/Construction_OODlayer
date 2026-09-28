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
    """🔴 D6. 가르는 것은 렌더이지 모집단이 아니다.

    🔴 S4 (2026-09-04): 감춘 것은 다섯이 아니라 넷이었다 —
    `release_pending_assignments!` 는 광고로 넘어갔다.
    🔴 S5 (2026-09-05): 넷이 아니라 **셋**이다 — `forbid_heavy_cargo!` 도 광고로 넘어갔다.
    """
    b = _block()
    for hidden in ("recover_stalled_teams!", "resolve_schedule_wedge!",
                   "force_advance_stuck_carrier!"):
        assert hidden not in b, "%s 가 샜다" % hidden


def test_the_cargo_ban_verb_is_under_the_callable_heading():
    """🔴 S5. 이 태스크의 성패가 정확히 이 단언이다(S4 의 짝).

    S4 는 `export` 만으로 둘째 표제 아래 실렸다(`InvariantSpec` 이 폐포 밖). 이 동사는
    위치인자가 `env` 하나뿐이고 무타입이라 그 함정이 **없다** — `missing` 이 비어 있는
    것이 그 사실의 기계 증거다. 비어 있지 않게 되면 여기가 빨개진다.
    """
    b = _block()
    head, _, tail = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    line = [l for l in head.splitlines() if l.startswith("- forbid_heavy_cargo!")]
    assert len(line) == 1, line
    assert "missing:" not in line[0], line[0]
    assert "agent" in line[0] and "n" in line[0]     # kwarg 둘이 프롬프트에 실린다
    assert "forbid_heavy_cargo!" not in tail


def test_the_reassignment_verb_is_under_the_callable_heading():
    """🔴 S4. 이 태스크의 성패가 정확히 이 단언이다.

    `export` 한 줄만으로는 둘째 표제 아래 실렸다(실측: `InvariantSpec` 이 타입 폐포 밖이라
    `callable=false`) — 모델이 "지금은 못 부른다" 로 읽으면 광고가 무동작이다.
    """
    b = _block()
    head, _, tail = b.partition("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    line = [l for l in head.splitlines() if l.startswith("- release_pending_assignments!")]
    assert len(line) == 1, line
    # 정직함: 부를 수는 있지만 `invariant` 를 env 에서 길어 올릴 경로는 없다고 적는다.
    assert "missing: InvariantSpec" in line[0]
    assert "release_pending_assignments!" not in tail


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
    D6 이 감춘 셋(S4 · S5 뒤) 때문에 어떤 사건은 필드 경로 말고 길이 없다.
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
    """🔴 빈-통과 방지 + 실제 사인의 자리 — id 로 **키가 걸린 Dict** 가 렌더에 실재한다.

    🔴 2026-09-04 갱신. 이 시험은 원래 `"Dict{Any, Float64}" in b` 를 단언했고 독스트링에
    "생성기의 `returns` 는 `Base.return_types` 에서 기계로 유도되므로 산출물 쪽에서 `Any` 를
    좁힐 길이 없다" 고 적혀 있었다. **그 전제가 틀렸다**: `Any` 는 `battery.jl` 의
    `BatteryFleet.soc` 선언에서 왔고, 그것을 실측한 참값(`RobotID` = `BotID{DeliveryBot}`)
    으로 좁히자 `_returns_string` 이 스스로 진실을 광고했다 —
    `soc::Dict{ConstructionBots.BotID{ConstructionBots.DeliveryBot}, Float64}`.
    그래서 `Dict{Any, Float64}` 는 이제 렌더에 **없다**(있으면 그것이 회귀다).

    지금 이 게이트가 지키는 명제는 그대로다: 규약 6 이 말하는 대상(= id **객체**로 키가
    걸린 사전)이 렌더에 실재해야 규약이 공허하지 않다. 두 자리에서 못박는다 —
    앰비언트 접근자가 돌려주는 `soc`, 그리고 WORLD TYPES 의 `AbstractID` 키 필드들.
    """
    b = _block()
    # 🔴 회귀 방지: `Any` 로 되돌아가면(= battery.jl 의 선언이 되돌려지면) 여기서 빨개진다.
    assert "Dict{Any, Float64}" not in b, (
        "`soc` 의 키 타입이 `Any` 로 되돌아갔다 — 유료 런 2 의 `KeyError: \"R1\"` 이 다시 열린다")
    assert "soc::Dict{BotID{DeliveryBot}, Float64}" in b, (
        "앰비언트 접근자가 id 객체 키를 광고하지 않는다 — 규약 6 의 대상이 렌더에 없다")
    # WORLD TYPES 쪽의 같은 모양(빈-통과 방지: 두 자리 중 하나만 살아도 통과하면 안 된다).
    assert "Dict{AbstractID, " in b, b[:400]
    # 🔴 라운드 5. 규약 6 에서 `Dict{Any, ...}` 인용을 **걷어냈다** — 타입이 좁혀진 뒤
    #    렌더 본문의 `Dict{Any` 는 0건이라 그 인용은 지시대상이 없었다(I2 와 같은 부류).
    #    그래서 이 자리가 지키는 명제가 뒤집힌다: 규약부는 **구체 타입을 인용하지 않는다.**
    #    기계가 광고하는 것은 기계에 맡기고, 시그니처가 못 나르는 것만 산문에 남긴다.
    r = b.partition("\n\nWORLD TYPES")[0]
    assert "Dict{Any" not in r, (
        "규약부가 구체 타입을 인용한다 — 그 타입이 좁혀지는 날 규약이 없는 것을 가리킨다")
    # 시그니처가 못 나르는 두 가지는 그대로 산문에 있어야 한다.
    assert "OBJECTS, never strings" in r, r
    assert "KeyError" in r, r


# =====================================================================================
# 2026-09-04, 유료 런 3 — 규약 1 과 규약 6 은 **동시에 지킬 수 있어야** 한다.
#
# 런 3 의 body 에는 `"R1"` 이 없었다(규약 6 이 먹혔다). 대신 이렇게 나왔다:
#
#     function TaskReallocationTool!(env; affected_robot, affected_tasks, alternative_robots)
#
# → `reject:impl_keyword_needs_a_default:affected_robot`. **L1 이 무너졌다** — 사다리에서
# 규약 6 이전 런보다 낮은 점수다.
#
# 🔴 이것은 모델의 실수가 아니라 **우리가 준 두 규약의 모순**이다. 규약 6 = "id 는 env 에서
#    얻은 **객체**", 규약 1 = "모든 키워드에 **기본값**". 기본값은 리터럴이어야 하고 env 객체는
#    리터럴이 될 수 없다. 모델은 둘 중 하나를 버려야 했고 방금 배운 쪽을 지켰다.
#
# 화해는 **의무가 적힌 자리**(규약 1)에서 한다 — 모델은 위에서 아래로 읽으므로 압력이 생기기
# 전에 해법이 도착해야 한다. 그리고 이것은 편의가 아니라 **유일한 길**이다:
# `bind_primitive_args`(`src/respec/minted_tool.jl`)가 키워드를 `ctx.params` 의 **JSON** 값에서
# 만들고 `_param_type_reject` 가 JSON 타입을 강제하므로 id **객체**는 그 채널로 못 온다.
# =====================================================================================
def _rules_by_number(r):
    import re
    parts = re.split(r"\n  (\d)\. ", "\n" + r)
    return {int(parts[i]): parts[i + 1] for i in range(1, len(parts), 2)}


def test_rule_1_shows_how_an_env_object_becomes_a_keyword_default():
    import world_interface as WI
    r1 = _rules_by_number(WI._RULES)[1]
    assert "cannot be a literal" in r1, r1
    # 🔴 산문이 아니라 **지난번처럼 리터럴 예시**가 착지한다.
    assert "affected_robot = nothing" in r1, r1
    assert ("affected_robot === nothing && "
            "(affected_robot = first(keys(env.agent_policies)))") in r1, r1
    # 렌더에도 실제로 실린다 — `_RULES` 만 보고 끝내지 않는다.
    assert "affected_robot = nothing" in _block()


def test_the_keyword_default_obligation_is_not_weakened():
    """🔴 모순을 없애는 것이지 **의무를 없애는 것이 아니다.**
    `check_impl_conventions`(`src/respec/minted_registration.jl`)는 모든 kw 가 `Expr(:kw)`
    이기를 그대로 요구한다 — 프롬프트가 "생략해도 된다" 로 새면 거절이 거짓 실패로 기록된다.
    """
    import world_interface as WI
    r1 = _rules_by_number(WI._RULES)[1]
    assert "MUST" in r1 and "have a default" in r1, r1
    assert "dropping the default is rejected" in r1, r1
    for weasel in ("optional", "may omit", "you can leave", "if possible"):
        assert weasel not in r1.lower(), weasel


def test_rule_6_points_back_at_rule_1_for_defaults():
    """양방향이다 — 규약 6 만 읽고 코드를 쓰는 경로에서도 해법이 보여야 한다."""
    import world_interface as WI
    assert "see rule 1" in _rules_by_number(WI._RULES)[6]


# =====================================================================================
# 2026-09-05 — 유료 런 16·19 가 죽은 두 자리. 둘 다 "반환 모양이 안 보인다" 하나다.
#
# 런 16: body 가 `translate_whole_build!(...).status == :success || error(...)` 를 썼다.
#        그 함수엔 `:success` 경로가 **없다** — 빌드를 실제로 옮겨 놓고
#        (`n_staging_moved=8`, `PROJECT COMPLETE`) 무조건 던졌다. 유도가 맨 `NamedTuple`
#        로 넓어져 상태 어휘가 한 글자도 안 보였다.
# 런 19: body 가 `get_center(::Pair{Symbol, Ball2})` 로 죽었다. `active_restriction_zones()`
#        를 순회하면 `Pair` 가 나오는데 광고된 `Base.Generator{…}` 는 그것을 안 말했다.
#
# 🔴 이 시험들은 **커밋된 산출물**을 읽는다 — 생성기 쪽 짝은 `test/world_interface_current.jl`
#    이 새 서브프로세스 재생성물과 바이트 비교한다.
# =====================================================================================
def _named(name):
    import world_interface as WI
    for m in WI.load_world_interface()["methods"]:
        if m["name"] == name:
            return m
    raise AssertionError("광고 목록에 %s 가 없다 — 이 시험이 낡았다" % name)


def test_the_status_vocabulary_of_the_verb_that_killed_run16_is_advertised():
    import world_interface as WI
    m = _named("translate_whole_build!")
    got = m.get("status_symbols")
    assert got == ["already_clear", "infeasible", "no_staging", "residual_blocked",
                   "translated"], got
    line = WI._method_line(m)
    assert "status seen in source:" in line, line
    for sym in (":translated", ":already_clear", ":residual_blocked"):
        assert sym in line, (sym, line)


def test_success_is_not_among_them_which_is_the_whole_point():
    """🔴 이 시험이 재는 것이 이 개입의 전부다. 모델이 지어낸 `:success` 는 그 함수의
    어휘에 **없고**, 이제 모델은 그것을 눈으로 확인할 수 있다."""
    import world_interface as WI
    m = _named("translate_whole_build!")
    assert "success" not in m["status_symbols"], m["status_symbols"]
    assert ":success" not in WI._method_line(m)


def test_the_field_access_false_positive_is_not_reintroduced():
    """🔴 2026-09-05 실측. 첫 추출 규칙은 `status = res.status` 한 줄에서 필드 **이름**을
    심볼 리터럴로 오인해 `:status` 를 어휘에 넣었다. `Expr(:., obj, QuoteNode(name))` 의
    둘째 인자로 안 내려가는 것이 그 수선이고, 이 시험이 그것을 지킨다."""
    m = _named("restage_all_blocked!")
    assert m.get("status_symbols") == ["infeasible", "none", "partial",
                                       "residual_blocked", "restaged_all"], m.get("status_symbols")


def test_what_you_get_when_you_iterate_is_advertised():
    import world_interface as WI
    for name in ("restriction_zones", "active_restriction_zones"):
        m = _named(name)
        el = m.get("element_type")
        assert el and el.startswith("Pair{Symbol,"), (name, el)
        assert "yields: Pair{Symbol," in WI._method_line(m), name


def test_both_new_fields_are_tri_state_and_the_population_is_not_empty():
    """🔴 삼상: 못 유도한 항목은 **키가 없다**(`[]`/`""` 가 아니다) — 빈 값을 실으면
    "어휘가 없다" 는 주장이 되는데 우리는 그것을 안 쟀다.
    🔴 음성 대조: 모집단이 비면 위 시험들이 아니라 **이 시험**이 빨개진다."""
    import world_interface as WI
    ms = WI.load_world_interface()["methods"]
    ss = [m for m in ms if "status_symbols" in m]
    el = [m for m in ms if "element_type" in m]
    assert len(ss) >= 5, len(ss)
    assert len(el) >= 10, len(el)
    assert not any(m.get("status_symbols") == [] for m in ms)
    assert not any(m.get("element_type") == "" for m in ms)
    # 붙지 않은 항목은 그 줄에 두 문구가 **아예 없다**.
    bare = next(m for m in ms if "status_symbols" not in m and "element_type" not in m)
    line = WI._method_line(bare)
    assert "status seen in source:" not in line and "yields:" not in line, line


def test_the_wording_does_not_claim_a_closed_set():
    """🔴 판정은 소스에 대한 **구문적 상계**다 — 도달 불가 갈래를 포함할 수 있고, 다른
    함수가 만든 상태는 못 본다. 문구가 "one of" 로 바뀌면 우리가 안 잰 것을 잰 것처럼
    말하게 되고, 모델은 나머지를 오류로 처리하기 시작한다."""
    import world_interface as WI
    line = WI._method_line(_named("translate_whole_build!"))
    assert "status seen in source:" in line
    for overclaim in ("one of:", "status is one of", "always returns", "exactly one of"):
        assert overclaim not in line, overclaim


def test_rule_3_says_success_is_your_contract_not_the_callees():
    """🔴 런 16 의 인과. 규약 3 이 `:success` 를 가르쳤고 모델이 그것을 **부른 함수의**
    어휘로 옮겨 썼다. 규약은 옳으므로 약화시키지 않고, 누구의 status 냐만 못박는다."""
    import world_interface as WI
    r3 = _rules_by_number(WI._RULES)[3]
    assert "return (; status = :success)" in r3, r3          # 의무는 그대로다
    assert "YOUR return contract" in r3, r3
    assert "Never assume a callee returns `:success`" in r3, r3
    assert "status seen in source:" in r3, r3                # 렌더와 같은 철자를 가리킨다
    assert "status seen in source:" in _block()


# =====================================================================================
# (나-1) 2026-09-05 — 좌표를 꺼내는 길. 유료 런 19·20 이 여기서 죽었다.
#
#   run19 1차 `MethodError: Vector{Float64}(::TransformNode)`
#   run19 2차 `MethodError: get_center(::Pair{Symbol, Ball2})`
#   run20 2차 `MethodError: Vector{Float64}(::AffineMap)`
#
# 셋 다 **CB 에 정의돼 있는데 `export` 가 없어서** 생성기(`names(CB)` 순회)에 안 보였다.
# 모델은 길이 없으니 없는 생성자를 지어냈다 — (b) 와 완전히 같은 부류이고 한 층 위다.
# =====================================================================================
def test_the_coordinate_accessors_are_advertised_at_all():
    import world_interface as WI
    names = {m["name"] for m in WI.load_world_interface()["methods"]}
    for n in ("global_transform", "project_to_2d", "get_center"):
        assert n in names, n


def test_they_are_under_the_callable_heading_not_the_other_one():
    """🔴 S4 의 함정. `export` 한 줄로는 무동작이다 — `callable=false` 면 렌더가 그것을
    `FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET` 아래로 보내고, 그 자리는 모델이
    "지금은 못 부른다" 로 읽는다. 실측으로 `get_center` 가 정확히 거기 앉아 있었다."""
    import world_interface as WI
    block = _block()
    head = block.index(WI._CALLABLE_HEADING)
    tail = block.index("FUNCTIONS THAT NEED SOMETHING YOU CANNOT OBTAIN YET")
    callable_part = block[head:tail]
    for n in ("global_transform", "project_to_2d", "get_center"):
        assert ("- %s " % n) in callable_part, n


def test_the_ball2_seam_is_present_on_both_ends():
    """모델이 이어야 할 이음매다: `restriction_zones()` 가 `Ball2` 를 주고 `get_center` 가
    그것을 받는다. 한쪽만 있으면 광고가 이음매가 아니라 막다른 길이 된다."""
    import world_interface as WI
    ms = WI.load_world_interface()["methods"]
    gc = [m for m in ms if m["name"] == "get_center" and "Ball2" in m["signature"]]
    assert gc and gc[0].get("callable") is True, gc
    rz = [m for m in ms if m["name"] == "restriction_zones"]
    assert rz and rz[0].get("callable") is True
    # (b) 가 그 이음매의 원소 타입을 이미 적어 뒀다 — 둘이 같은 사실을 가리킨다.
    assert "Pair{Symbol," in (rz[0].get("element_type") or ""), rz[0].get("element_type")


def test_the_closure_did_not_widen():
    """🔴 음성 대조. `_OBTAINABLE_FOREIGN` 은 `_arg_obtainable` **한 술어**만 고친다.
    폐포를 넓혔다면 `WORLD TYPES` 절에 LazySets/GeometryBasics 내부가 들어와 모델이 보는
    표면이 이 레인이 재려는 것과 달라진다(S4 가 프록시 넓히기를 재고 버린 것과 같은 근거)."""
    import world_interface as WI
    tnames = {t["name"] for t in WI.load_world_interface()["types"]}
    for foreign in ("Ball2", "Hyperrectangle", "HyperSphere", "AffineMap"):
        assert foreign not in tnames, foreign



# =================================================================================================
# 무타입 위치 인자의 변환 — 유료 런 19·20·22 (2026-09-05)
# =================================================================================================
def test_the_untyped_coordinate_args_that_killed_three_runs_are_advertised():
    """🔴 세 판이 같은 문장으로 죽었다: `Vector{Float64}(::TransformNode)`(19) ·
    `Vector{Float64}(::AffineMap)`(20·22). 런 22 의 body 는 좌표를 꺼내는 길을 **맞게**
    골라 놓고(`global_transform(goal_config(node))`) 그 AffineMap 을 `free_space_status`
    의 무타입 인자에 넘겼다 — 그 자리의 요구가 광고에 한 글자도 없었다."""
    import world_interface as WI
    m = _named("free_space_status")
    got = m.get("arg_coercions")
    assert got is not None, "free_space_status 에 변환이 안 실렸다"
    assert len(got) == 2, got
    assert all(c.startswith(("goal <- ", "start <- ")) for c in got), got
    assert all("Vector{Float64}" in c and "[1:2]" in c for c in got), got
    line = WI._method_line(m)
    assert "coerced in source:" in line, line
    assert "Vector{Float64}" in line and "[1:2]" in line, line


def test_the_length_requirement_rides_along_because_the_index_is_kept():
    """🔴 첨자(`[1:2]`)를 버리면 "벡터여야 한다" 까지만 남고 **평면 점이라는 사실**이
    사라진다. 그것이 이 두 함수가 실제로 요구하는 것이다."""
    import world_interface as WI
    for name in ("goal_engulfed", "zone_clears_root_goals", "root_goal_coverage"):
        m = _named(name)
        ac = m.get("arg_coercions")
        assert ac and any("[1:2]" in c for c in ac), (name, ac)
        assert "[1:2]" in WI._method_line(m), name


def test_every_advertised_coercion_names_an_argument_that_is_really_untyped():
    """🔴 음성 대조. 타입이 붙은 인자에 이 사실을 실으면 거짓 광고다 — 시그니처가 이미
    말하고 있는 것을 두 번째 진실원으로 다시 말하게 되고, 둘이 갈리는 날 아무도 못 잡는다."""
    import world_interface as WI
    ms = WI.load_world_interface()["methods"]
    seen = 0
    for m in ms:
        for c in m.get("arg_coercions") or []:
            seen += 1
            arg = c.split(" <- ", 1)[0]
            pos = m["signature"].lstrip("(").split(";", 1)[0]
            assert ("%s::" % arg) not in pos, (m["name"], c, m["signature"])
            assert arg in pos, (m["name"], c, m["signature"])
    assert seen >= 5, seen


def test_arg_coercions_is_tri_state_and_absent_where_nothing_was_derived():
    """🔴 삼상: 못 유도하면 **키가 없다**. `[]` 를 실으면 "변환이 없다" 는 주장이 되는데
    우리는 그것을 안 쟀다 — 소스를 못 읽었거나 무타입 인자가 없었을 뿐이다."""
    import world_interface as WI
    ms = WI.load_world_interface()["methods"]
    have = [m for m in ms if "arg_coercions" in m]
    assert len(have) >= 5, len(have)
    assert not any(m.get("arg_coercions") == [] for m in ms)
    bare = next(m for m in ms if "arg_coercions" not in m)
    assert "coerced in source:" not in WI._method_line(bare)


def test_the_coercion_wording_does_not_claim_a_closed_contract():
    """🔴 판정은 구문적 상계다 — 다른 함수가 대신 변환해 주는 경우(`h(g(x))`)는 못 본다.
    문구가 "must be" 로 바뀌면 우리가 안 잰 것을 잰 것처럼 말하게 된다."""
    import world_interface as WI
    line = WI._method_line(_named("free_space_status"))
    for overclaim in ("must be", "always", "the only", "required type"):
        assert overclaim not in line, overclaim


def test_rule_7_says_an_untyped_argument_promises_nothing():
    """🔴 규약 6 과 같은 부류로 적는다: 시그니처가 못 나르는 것만 산문으로 남기고 구체
    타입은 인용하지 않는다 — 기계가 `coerced in source:` 로 스스로 광고한다."""
    import world_interface as WI
    r7 = _rules_by_number(WI._RULES)[7]
    assert "WITHOUT a type" in r7, r7
    assert "coerced in source:" in r7, r7                    # 렌더와 같은 철자를 가리킨다
    assert "coerced in source:" in _block()
    for t in ("Vector{Float64}", "AffineMap", "free_space_status"):
        assert t not in r7, ("규약부는 구체 타입·동사를 인용하지 않는다", t)


# =================================================================================================
# 맨 `NamedTuple` 로 넓어진 반환의 필드 이름 — 유료 런 23·26 (2026-09-05)
# =================================================================================================
def test_the_query_run23_said_did_not_exist_now_advertises_its_blocked_list():
    """🔴 run23 의 body 가 자기 주석에 이렇게 적었다: *"No query returns the blocked
    schedule-node objects directly, so inspect the active unfinished frontier…"* — 그래서
    탐지를 손수 짜고 빈손으로 끝났다. 그 질의는 **있었다**: `zone_blockage(...).blocked`.
    없던 것은 질의가 아니라 **광고**다."""
    import world_interface as WI
    m = _named("zone_blockage")
    rf = m.get("returned_fields")
    assert rf is not None, "zone_blockage 에 필드가 안 실렸다"
    assert "blocked" in rf, rf
    assert "n_blocked" in rf and "project_blocked" in rf, rf
    # 🔴 2026-09-05 문구 변경: `zone_blockage` 는 반환 경로가 둘뿐이고 둘 다 NamedTuple
    #    리터럴이라 수확이 **완전하다**. 그래서 `seen` 이 아니라 `(complete …)` 로 나간다
    #    (난수 존 시드 1 이 없는 필드를 읽고 죽은 뒤의 수선). 지키려는 것은 그대로다 —
    #    이 질의가 광고된다는 것.
    assert "fields (complete" in WI._method_line(m)
    assert "blocked" in WI._method_line(m)


def test_only_return_position_counts_so_the_element_tuple_does_not_leak_in():
    """🔴 `zone_blockage` 는 body 중간에서 `push!(blocked, (vtx=…, id=…, kind=…, status=…))`
    로 **원소**를 짓는다. 그 넷을 최상위 필드로 광고하면 거짓말이다 — return 위치로 좁힌
    것이 그 수선이고, 이 시험이 그것을 지킨다."""
    rf = _named("zone_blockage")["returned_fields"]
    for leaked in ("vtx", "id", "kind"):
        assert leaked not in rf, (leaked, rf)


def test_fields_from_every_branch_survive_not_just_the_last_one():
    """🔴 회귀 시험. 첫 구현의 안쪽 클로저가 누산기와 **같은 이름**(`acc`)을 썼다 — 줄리아는
    그것을 새 지역변수가 아니라 바깥 변수의 포획으로 읽으므로 호출마다 누산기가 초기화됐고
    **마지막 return 의 필드만** 남았다. `detail`·`reason` 은 마지막이 아닌 갈래에만 있으므로
    바로 그 침묵을 잡는 초병이다(실측으로 발견: 프로토타입과 견주지 않았으면 "그 필드가
    없다"로 읽었을 것이다)."""
    assert "detail" in _named("translate_whole_build!")["returned_fields"]
    assert "detail" in _named("swap_battery!")["returned_fields"]
    fr = _named("fault_robot_and_reassign!")["returned_fields"]
    assert "detail" in fr and "reason" in fr, fr


def test_it_is_asked_only_where_inference_said_nothing():
    """🔴 타입이 이미 필드를 말하고 있으면 이것은 **둘째 진실원**이고, 둘이 갈리는 날 아무도
    못 잡는다(규약 6 이 `soc` 에서 걷어낸 것과 같은 결함 부류)."""
    ms = WI_methods()
    for m in ms:
        if "returned_fields" in m:
            assert m.get("returns") == "NamedTuple", (m["name"], m.get("returns"))
    # 양성 대조: 필드가 **타입에** 실린 메서드는 이 키를 안 가진다.
    zd = _named("zone_diagnosis")
    assert zd["returns"].startswith("NamedTuple{("), zd["returns"]
    assert "returned_fields" not in zd


def test_returned_fields_is_tri_state_and_the_population_is_not_empty():
    import world_interface as WI
    ms = WI_methods()
    have = [m for m in ms if "returned_fields" in m]
    assert len(have) >= 4, len(have)
    assert not any(m.get("returned_fields") == [] for m in ms)
    bare = next(m for m in ms if "returned_fields" not in m)
    assert "fields seen in source:" not in WI._method_line(bare)


def test_the_field_wording_does_not_claim_one_call_returns_them_all():
    """🔴 갈래의 **합집합**이다 — 한 호출이 전부를 돌려준다는 뜻이 아니다."""
    import world_interface as WI
    # 🔴 이 자리도 이제 `(complete …)` 다. **완전하다** 는 "모든 반환 경로를 읽었다" 는
    #    뜻이지 "한 호출이 이것을 다 돌려준다" 는 뜻이 아니다 — 여전히 갈래의 합집합이고,
    #    금지 문구는 두 표기 모두에 걸려야 한다.
    for name in ("translate_whole_build!", "swap_battery!"):
        line = WI._method_line(_named(name))
        assert ("fields (complete" in line) or ("fields seen in source:" in line), name
        for overclaim in ("fields are", "always returns", "the return has", "exactly"):
            assert overclaim not in line, (name, overclaim)


def WI_methods():
    import world_interface as WI
    return WI.load_world_interface()["methods"]


# =================================================================================================
# NamedTuple 벡터 필드의 **원소 모양** — 유료 런 27·28·29 (2026-09-05)
# =================================================================================================
def test_the_element_shape_three_runs_guessed_wrong_is_advertised():
    """🔴 (라)가 `zone_blockage(...).blocked` 를 광고하자 **세 판 다 그것을 찾아 썼다** —
    개입은 도달했다. 그리고 세 판 다 그것을 *id 의 목록*으로 읽었다
    (`env.sched.vtx_map[blocked_id]` · `node.id in blocked_ids`). 원소는
    `(vtx, id, kind, status)` 라 매칭이 전부 빗나갔고 셋 다 빈손으로 끝났다."""
    import world_interface as WI
    m = _named("zone_blockage")
    fe = m.get("field_element_fields")
    assert fe == ["blocked[] :: (id, kind, status, vtx)"], fe
    line = WI._method_line(m)
    assert "elements seen in source:" in line
    for f in ("vtx", "id", "kind", "status"):
        assert f in line


def test_the_same_rule_covers_the_other_verb_the_lane_actually_calls():
    """🔴 특례가 아니라 일반 규칙이라는 증거. 같은 수확이 `restage_all_blocked!` 의
    `moved`/`failed` 도 덮는다 — 이 레인이 실제로 부르는 동사이고 같은 불투명함을 가진다."""
    fe = _named("restage_all_blocked!")["field_element_fields"]
    assert fe == ["failed[] :: (id, status)", "moved[] :: (from, id, to)"], fe


def test_the_population_is_exactly_the_two_and_is_tri_state():
    import world_interface as WI
    ms = WI_methods()
    have = [m for m in ms if "field_element_fields" in m]
    assert [m["name"] for m in have] == ["restage_all_blocked!", "zone_blockage"], \
        [m["name"] for m in have]
    assert not any(m.get("field_element_fields") == [] for m in ms)
    bare = next(m for m in ms if "field_element_fields" not in m)
    assert "elements seen in source:" not in WI._method_line(bare)


def test_it_is_not_a_second_source_of_truth_today_and_a_tripwire_says_when_it_becomes_one():
    """🔴 이 사실은 타입이 **침묵하는** 자리를 메운다: 오늘 두 필드의 원소 타입은 광고에서
    맨 `Vector{NamedTuple}` 이다. 누군가 그 타입을 좁히면 타입과 이 줄이 같은 것을 두 번
    말하게 되고, 둘이 갈리는 날 아무도 못 잡는다(규약 6 이 `soc` 에서 걷어낸 결함 부류).
    그날 이 시험이 먼저 빨개져서 **게이트를 걸라고** 알린다."""
    # 🔴 이름으로 훑지 않는다. `status` 는 원소 필드이자 **바깥** 필드이기도 해서 문자열
    #    검색은 둘을 못 가른다(첫 판이 그 오탐으로 빨개졌다). 물어야 하는 것은 정확히
    #    "그 필드의 **원소 타입**이 아직 맨 `NamedTuple` 인가" 하나다.
    for name in ("zone_blockage", "restage_all_blocked!"):
        m = _named(name)
        ret = m.get("returns") or ""
        for entry in m["field_element_fields"]:
            field = entry.split("[]", 1)[0]
            if ("%s::" % field) not in ret:
                continue                      # 타입이 그 필드를 아예 안 댄다 (zone_blockage)
            assert ("%s::Vector{NamedTuple}" % field) in ret, (name, field, ret)


def test_the_element_wording_does_not_claim_a_closed_shape():
    """⚠️ 갈래의 합집합이다 — `zone_blockage` 은 `:engulfed`·`:disconnected` 두 자리에서
    push 한다. 문구가 폐집합을 주장하면 모델이 나머지를 오류로 처리하기 시작한다."""
    import world_interface as WI
    line = WI._method_line(_named("zone_blockage"))
    assert "elements seen in source:" in line
    for overclaim in ("elements are", "each element has exactly", "always"):
        assert overclaim not in line, overclaim


# ==========================================================================================
# 🔴 2026-09-05, 난수 존 시드 1. `fields seen in source:` 는 삼상 규율상 **"본 것"** 이라
#    목록에 없는 이름이 "없다" 가 아니라 "모른다" 로 읽힌다. 그래서 주조 body 가
#    `zone_blockage(...).n_nav_blocked` 를 읽고 던졌다 — 그 필드는 `zone_diagnosis` 것이다.
#    수확이 모든 반환 경로를 덮은 자리에서는 그렇게 말해야 **부재가 판단 근거**가 된다.
# ==========================================================================================
def test_a_complete_harvest_says_so_and_a_partial_one_does_not():
    ms = WI_methods()
    zb = _named("zone_blockage")
    assert zb.get("returned_fields_complete") is True, zb.get("returned_fields_complete")
    sb = _named("swap_battery!")
    assert "returned_fields_complete" not in sb, "짧게 판정하면 안 되는 자리다"

    s = _block()
    zl = [ln for ln in s.splitlines() if ln.lstrip().startswith("- zone_blockage ")]
    assert zl, "zone_blockage 줄이 렌더에 없다"
    assert "fields (complete" in "\n".join(zl), zl[:1]
    sl = [ln for ln in s.splitlines() if ln.lstrip().startswith("- swap_battery! ")]
    assert sl, "swap_battery! 줄이 렌더에 없다"
    assert "fields seen in source:" in "\n".join(sl), sl[:1]
    # 음성 대조 — 이 두 문구가 같은 줄에 동시에 오면 안 된다.
    for ln in s.splitlines():
        assert not ("fields (complete" in ln and "fields seen in source:" in ln), ln[:120]


def test_the_complete_list_is_the_one_the_paid_run_needed():
    """🔴 시드 1 이 죽은 바로 그 이름이 목록에 **없다**는 것이 이 개입의 전부다.

    `n_nav_blocked` 는 `zone_diagnosis` 의 필드고 `zone_blockage` 의 것이 아니다. 그리고
    `zone_diagnosis` 는 유도된 `returns` 가 이미 그것을 말하므로 이 수확을 안 탄다.
    """
    zb = _named("zone_blockage")
    assert "n_nav_blocked" not in zb["returned_fields"], zb["returned_fields"]
    assert "n_blocked" in zb["returned_fields"]
    zd = _named("zone_diagnosis")
    assert "n_nav_blocked" in (zd.get("returns") or ""), zd.get("returns")
    assert "returned_fields" not in zd, "타입이 말하는 자리에 둘째 진실원을 두면 안 된다"


def test_completeness_is_a_tri_state_key_not_a_boolean_column():
    """참일 때만 키가 생긴다 — 키가 없는 것은 '불완전' 이 아니라 '못 말한다' 다."""
    ms = WI_methods()
    vals = {m["name"]: m["returned_fields_complete"]
            for m in ms if "returned_fields_complete" in m}
    assert vals, "아무 데도 안 실렸다 — 수확기가 조용히 죽었을 수 있다"
    assert all(v is True for v in vals.values()), vals
    assert set(vals) == {"zone_blockage", "translate_whole_build!"}, sorted(vals)


def test_status_meanings_are_advertised_only_where_a_human_marked_them():
    """🔴 2026-09-22 (results/2026-09-22-r2-body-replay ③ · r3). `status seen in source:` 는 기호만
    실었고, body 가 `restage_all_blocked!` 의 `:none` 을 "존이 다 치워졌다" 로 읽어 translate 로 안
    올라갔다(엔진 docstring 도 그렇게 틀리게 적었다). 뜻은 docstring 의 **표시된 문단**에서만
    수확된다 — 표시가 없는 함수에 산문이 새어 나가면 검증 안 된 주장이 광고된다."""
    import world_interface as WI
    ms = WI_methods()
    assert sorted(m["name"] for m in ms if "status_meanings" in m) == \
        ["restage_all_blocked!", "translate_whole_build!"]
    for m in ms:
        for x in m.get("status_meanings") or []:
            assert x.split(" =")[0].lstrip(":") in m["status_symbols"], (m["name"], x)
    m = _named("restage_all_blocked!")
    sm = {x.split(" =")[0]: x for x in m["status_meanings"]}
    assert "no goal is blocked" in sm[":none"]
    assert "no staging circle was blocked at all" in sm[":residual_blocked"]
    assert "translate_whole_build!" in sm[":residual_blocked"]
    assert "status meanings:" in WI._method_line(m)
    bare = next(x for x in ms if "status_meanings" not in x and x.get("status_symbols"))
    assert "status meanings:" not in WI._method_line(bare)


def test_the_generated_listing_is_compacted_but_the_rules_are_not():
    """🔴 2026-09-28, 비용. 목록만 압축한다 — `ConstructionBots.` 는 body 의 eval 스코프라 떼고,
    다른 모듈 접두사는 그 스코프 밖이라 남긴다. 규칙 문단은 D19 대로 바이트 그대로."""
    import world_interface as WI
    b = _block()
    rest = b[len(WI._RULES):]
    assert b.startswith(WI._RULES) and "  " in WI._RULES
    assert "ConstructionBots." not in rest
    assert "  " not in rest
    assert "CoordinateTransformations." in rest
