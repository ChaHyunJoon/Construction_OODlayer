"""도장 계약의 단위검사. **핵심은 음성 대조다** — 도장이 없거나 다른 파일을 읽으면
정말로 죽는가. 죽지 않으면 이 게이트는 영원히 실패할 수 없는 검사이고, 그런 검사는
2026-08-16 에 실제로 하나 만들어 봤다(그렙 대상 문자열이 stdout 에 한 번도 안 나왔다)."""
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import action_registry  # noqa: E402


def test_vocab_constant_is_declared():
    # 리뷰 라운드 1 판정 G: 도장은 "오늘 참인 것"을 선언한다. 오늘 registry 는 3/5/6 이
    # 아직 은퇴하지 않은 9팔이므로 "v2-6arms"(태스크 5 이후의 END-STATE)가 아니라
    # "v1-9arms" 다. 태스크 5 가 3/5/6 을 실제로 은퇴시키는 순간 이 문자열이
    # "v2-6arms" 로 바뀌고, 그 변경이 옳다는 것은 아래 arm-count 어서션이 증명한다.
    assert action_registry.VOCAB == "v1-9arms"


def test_vocab_declares_todays_true_arm_count():
    # dynamics_stamp() 는 hazard_enabled() 에서 **유도**되는데 vocab 문자열은 리터럴이라
    # 유도할 수 없다 — 그래서 유도 대신 "선언 <n>arms == 은퇴 제외 실제 registry 항목 수"를
    # 기계로 대조한다(리뷰 판정 G, 재리뷰로 정정). 오늘은 은퇴 표식이 하나도 없으므로
    # "은퇴 제외 개수" 와 "전체 엔트리 수" 가 우연히 둘 다 9 로 같다 — 그래서 이 하나의
    # 테스트만으로는 어느 정의를 쓰는지 구분이 안 된다(재리뷰가 실제로 지적한 결함).
    # 그 구분은 아래 `test_n_non_retired_*` 와 태스크 5 시나리오 테스트가 한다.
    assert len(action_registry.MACROS) == 9
    assert action_registry.n_non_retired(action_registry.REGISTRY) == 9


def test_n_non_retired_ignores_only_entries_marked_retired():
    # 재리뷰가 잡은 핵심 결함: 태스크 5 의 은퇴는 엔트리를 지우지 않고 "retired" 표식만
    # 단다(이름·비용은 유지). len(MACROS) 는 그래서 은퇴 후에도 영원히 9 로 고정되고,
    # 어서션이 그걸 실제 개수로 쓰면 태스크 5 의 은퇴를 절대 못 본다. n_non_retired 는
    # "retired" 표식이 있는 엔트리만 빼고 센다.
    registry = {
        0: {"name": "A", "cost": 1.0},
        1: {"name": "B", "cost": 1.0, "retired": True},
        2: {"name": "C", "cost": 1.0, "retired": False},
    }
    assert action_registry.n_non_retired(registry) == 2


def test_vocab_arm_count_assertion_accepts_matching_count():
    action_registry.assert_vocab_arm_count("v1-9arms", 9)


def test_vocab_arm_count_assertion_dies_on_mismatch():
    # assert_vocab_arm_count 자체는 순수 산술 대조라 정의(무엇을 n_actual 로 넣는지)와
    # 무관하게 옳다 — 재리뷰가 잡은 결함은 호출부가 넘기는 n_actual 의 정의였다(아래
    # 태스크 5 시나리오 테스트가 그 정의를 서브프로세스로 검증한다).
    with pytest.raises(ValueError) as e:
        action_registry.assert_vocab_arm_count("v1-9arms", 7)
    assert "9" in str(e.value)
    assert "7" in str(e.value)


def test_vocab_arm_count_assertion_dies_on_malformed_stamp():
    with pytest.raises(ValueError):
        action_registry.assert_vocab_arm_count("not-a-vocab-stamp", 9)


# ---- 태스크 5 시나리오 (스크래치 registry, 서브프로세스) -----------------------------------
# action_registry 모듈은 최초 import 시 딱 한 번 평가되고(모듈 캐시), 그 순간 VOCAB 과
# assert_vocab_arm_count 호출이 이미 끝나 있다. 그래서 "다른 registry 를 넣으면 어떻게
# 되는가" 는 **같은 프로세스에서 재import 로는 검증할 수 없다** — 서브프로세스로 새
# 인터프리터를 띄워 ACTION_REGISTRY= 로 스크래치 파일을 주입한다. 커밋된
# action_registry.json 은 절대 건드리지 않는다.
def _synthetic_registry(vocab, retired_ids=()):
    macros = {}
    for i in range(9):
        entry = {"name": "Macro%d" % i, "cost": 1.0, "kinds": ["fault"], "doc": "synthetic"}
        if i in retired_ids:
            entry["retired"] = True
        macros[str(i)] = entry
    return {"vocab": vocab, "macros": macros}


def _write_scratch_registry(tmp_path, vocab, retired_ids=()):
    p = tmp_path / "scratch_action_registry.json"
    p.write_text(json.dumps(_synthetic_registry(vocab, retired_ids)), encoding="utf-8")
    return str(p)


def _load_in_subprocess(path):
    core_dir = os.path.dirname(os.path.abspath(action_registry.__file__))
    env = dict(os.environ)
    env["ACTION_REGISTRY"] = path
    env["PYTHONPATH"] = core_dir + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        [sys.executable, "-c", "import action_registry"],
        env=env, capture_output=True, text=True,
    )


def test_task5_scenario_today_nothing_retired_v1_9arms_loads(tmp_path):
    path = _write_scratch_registry(tmp_path, "v1-9arms", retired_ids=())
    r = _load_in_subprocess(path)
    assert r.returncode == 0, r.stderr


def test_task5_scenario_retired_but_stamp_not_bumped_dies(tmp_path):
    # 태스크 5 가 실제로 저지를 수 있는 실수: 3/5/6 을 은퇴시켰는데 도장 문자열을 그대로
    # "v1-9arms" 로 남겼다. 어서션이 이걸 못 잡으면(= 재리뷰 이전 상태) 도장은 장식이다.
    path = _write_scratch_registry(tmp_path, "v1-9arms", retired_ids=(3, 5, 6))
    r = _load_in_subprocess(path)
    assert r.returncode != 0
    assert "거짓말한다" in r.stderr


def test_task5_scenario_retired_and_stamp_correctly_bumped_loads(tmp_path):
    # 태스크 5 의 올바른 변경: 3/5/6 을 은퇴시키고 도장을 "v2-6arms" 로 갈아 끼웠다.
    # 어서션이 이걸 막으면(= 재리뷰 이전 상태, 선언 6 vs 실제 9 로 죽음) 태스크 5 가
    # 정상적으로 끝날 수 없다.
    path = _write_scratch_registry(tmp_path, "v2-6arms", retired_ids=(3, 5, 6))
    r = _load_in_subprocess(path)
    assert r.returncode == 0, r.stderr


def test_require_vocab_accepts_matching_stamp():
    action_registry.require_vocab({"vocab": "v1-9arms"}, "테스트")


def test_require_vocab_dies_on_missing_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"objective_hash": "19819377a7f8ebb2"}, "구세대 파일")
    assert "vocab" in str(e.value)


def test_require_vocab_dies_on_stale_stamp():
    with pytest.raises(ValueError) as e:
        action_registry.require_vocab({"vocab": "v1-8arms"}, "구세대 파일")
    assert "v1-8arms" in str(e.value)


def test_require_dynamics_dies_on_mismatch():
    action_registry.require_dynamics({"dynamics": "hazard-on"}, "hazard-on", "신세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({"dynamics": "hazard-off"}, "hazard-on", "구세대")
    with pytest.raises(ValueError):
        action_registry.require_dynamics({}, "hazard-on", "도장 없음")
