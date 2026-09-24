"""역사적 존 복구 코호트 fixture 가 표류하지 않는지 (zone-repair-verification T0).

실행: (repo 루트에서) `.venv/bin/python -m pytest tools/monitor/test_build_repair_cohort.py -q`

첫 시험은 커밋된 fixture 만 읽는다(수·anchor 집합·membership 산술·body 파일 sha256).
둘째는 results/ 원장·스트림(gitignore, 디스크 전용)이 있을 때 fixture 를 다시 만들어 바이트 대조한다 —
없으면 skip 하고 그 사유를 출력한다(첫 시험은 그래도 돈다).
"""
import hashlib
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_repair_cohort as B  # noqa: E402

COHORT = os.path.join(B.OUT, "cohort.json")


def _load():
    with open(COHORT) as f:
        return json.load(f)


def test_committed_cohort_counts_anchors_and_bodies():
    c = _load()
    mem = c["membership"]
    assert {k: len(mem[k]) for k in B.EXPECT} == B.EXPECT
    anchors = sorted(B.key(m, cs, s, s) for m, cs, s in B.ANCHORS)
    assert sorted(mem["a2_rescue"]) == anchors == sorted(mem["anchors"])
    keys = [r["key"] for r in c["runs"]]
    assert len(keys) == len(set(keys)) == 120
    easy, hard = set(mem["easy"]), set(mem["hard"])
    assert easy | hard == set(keys) and not easy & hard
    assert set(mem["a2_easy_success"]) | set(mem["a2_regression"]) == easy
    assert set(mem["a2_rescue"]) | set(mem["a2_hard_fail"]) | set(mem["a2_hard_unobserved"]) == hard
    # 미관측은 따로 적힌다 — timeout 판은 a2_hard_unobserved 에만 있고 a2.status 가 complete 가 아니다
    for r in c["runs"]:
        if "a2_timeout" in r["flags"]:
            assert r["a2_class"] in ("a2_hard_unobserved", "a2_regression") and r["a2"]["status"] == "timeout"
    for k in easy | set(mem["a2_rescue"]):
        m, case, s, _ = k.split("|")
        d = os.path.join(B.OUT, "legacy", "%s_%s_%s" % (m, case, s))
        man = json.load(open(os.path.join(d, "manifest.json")))
        assert man["key"] == k
        assert man["anchor"] == (k in anchors) and (man["audit"] is not None) == (k in anchors)
        assert any(b["executed"] for b in man["bodies"]), k
        for b in man["bodies"]:
            if b["file"]:
                code = open(os.path.join(d, b["file"]), newline="").read()
                assert hashlib.sha256(code.encode()).hexdigest() == b["code_sha256"], (k, b["file"])


@pytest.mark.skipif(not os.path.exists(B.LEDGER), reason="results/ 원장 없음(gitignore) — 재생성 대조 불가")
def test_rebuild_is_byte_identical_to_committed():
    cohort, _ = B.build()
    assert B.check(cohort) == []
    got = json.dumps(cohort, indent=1, ensure_ascii=False, sort_keys=True) + "\n"
    assert got == open(COHORT).read()
