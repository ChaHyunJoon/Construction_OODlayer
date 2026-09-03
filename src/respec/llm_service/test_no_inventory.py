"""원시 인벤토리·ψ·단일 agent 레인이 사라졌다는 계약. 유료 0건."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def test_synthesize_imports_without_the_registry():
    """🔴 `primitive_registry.py` 를 지운 순간 이 import 가 죽었다 — 서비스 전체가 못 뜬다."""
    import synthesize  # noqa: F401


def test_the_inventory_and_psi_surface_is_gone():
    import synthesize as SY
    for gone in ("build_inventory_block", "primitive_inventory_lines",
                 "predicate_inventory_lines", "redact_inventory_names", "_REDACTED_NAME",
                 "_inventory_names", "parse_body", "psi_stats", "_PSI_STATS_CACHE"):
        assert not hasattr(SY, gone), "%s 가 아직 있다" % gone


def test_the_single_agent_lane_is_gone():
    """사용자 결정 D8. 레지스트리가 없으므로 그 레인은 돌 수 없다 — 비교군을 포기했다."""
    import synthesize as SY
    for gone in ("SynthesizeTool", "maybe_synthesize", "MULTI_AGENT_ENV", "multi_agent_enabled"):
        assert not hasattr(SY, gone), "%s 가 아직 있다" % gone


def test_run_synthesis_has_no_lane_branch():
    """🔴 분기가 남아 있으면 플래그 없는 서비스가 조용히 죽은 레인으로 간다.

    ⚠️ 2026-09-03. 옛 판은 `inspect.getsource` 를 두 **리터럴 이름**(`maybe_synthesize` ·
    `multi_agent_enabled`)으로 훑었다 — 이름을 바꾼 분기에 대해 **공백 통과**다. 지운 두
    이름의 부재는 위 `test_the_single_agent_lane_is_gone` 이 이미 재고 있으므로, 여기서는
    이름이 아니라 **모양**을 잰다: 이 함수는 분기가 하나도 없고 `synthesize_multi` 로 가는
    `return` 하나뿐이다. 어떤 이름의 분기가 들어와도 빨개진다.
    """
    import ast
    import inspect
    import textwrap
    import synthesize as SY
    fn = ast.parse(textwrap.dedent(inspect.getsource(SY.run_synthesis))).body[0]

    branches = [n for n in ast.walk(fn)
                if isinstance(n, (ast.If, ast.IfExp, ast.Try, ast.Match))]
    assert not branches, "run_synthesis 에 분기가 생겼다 (%d개) — 레인이 다시 갈렸는지 볼 것" % (
        len(branches),)

    rets = [n for n in ast.walk(fn) if isinstance(n, ast.Return)]
    assert len(rets) == 1, "탈출 경로가 %d개다 — 하나여야 한다" % len(rets)
    call = rets[0].value
    assert isinstance(call, ast.Call) and getattr(call.func, "id", None) == "synthesize_multi", \
        "유일한 return 이 synthesize_multi 호출이 아니다"


def test_what_must_survive_survives():
    """빈-통과 방지: 위 단언들은 모듈이 비어도 참이다."""
    import synthesize as SY
    for kept in ("synthesize_multi", "run_synthesis", "normalize_calls", "calls_flatness",
                 "append_synthesis_record", "SynthesisLedger", "synthesis_enabled"):
        assert hasattr(SY, kept), "%s 가 사라졌다" % kept
