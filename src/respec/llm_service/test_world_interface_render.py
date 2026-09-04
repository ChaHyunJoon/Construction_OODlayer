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
