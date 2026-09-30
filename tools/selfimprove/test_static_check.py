"""S0 정적 검사 · arm 빌더 · T_null (plan Task 12, spec §8, §0.0 R3·R7)."""
import copy, hashlib
import pytest
from tools.selfimprove import static_check as sc, library

CODE = ('function relocate!(env; dx::Float64 = 0.5, tag::String = "a(b", ks::Vector{Int} = [1, 2])\n'
        '    translate_whole_build!(env)\n    return nothing\nend\n')
ROW = {"record_id": "r1", "row_type": "decide", "impl_name": "relocate!", "impl_code": CODE,
       "calls": [{"primitive": "relocate!", "args": {"dx": 0.5, "tag": "z"}}],
       "params": {"dx": {"type": "number"}}, "surface": "sched", "reversible": False,
       "body_names": ["relocate!"]}
NAMES = {"translate_whole_build!", "active_restriction_zones"}

@pytest.mark.parametrize("tok", ["eval(x)", "@eval x", "Core.eval(M, x)", "include(\"f\")", "ENV[\"X\"]",
                                 "ccall(:f, Int, ())", "run(`ls`)", "open(\"f\")", "rm(\"f\")",
                                 "write(io, x)", "global g = 1"])
def test_forbidden_tokens_are_hard(tok):
    r = dict(ROW, impl_code=CODE.replace("return nothing", tok))
    assert not sc.s0(r, NAMES)["ok"]

def test_identifier_substrings_are_not_forbidden():
    r = dict(ROW, impl_code=CODE.replace("return nothing", "dry_run(x); reopen(y); rewrite!(z)"))
    assert sc.s0(r, NAMES)["ok"]

def test_non_literal_args_are_hard():
    r = copy.deepcopy(ROW); r["calls"][0]["args"]["dx"] = {"expr": "a+b"}
    assert not sc.s0(r, NAMES)["ok"]
    r["calls"][0]["args"]["dx"] = [1, 2]
    assert not sc.s0(r, NAMES)["ok"]

def test_soft_flags_do_not_reject():
    code = CODE.replace("return nothing", "try\n  while true\n    x = 12.5\n  end\ncatch e\nend")
    out = sc.s0(dict(ROW, impl_code=code), NAMES)
    assert out["ok"] and set(out["soft"]) >= {"catch_without_rethrow", "while_true", "numeric_literal_ge_1"}

def test_same_behavior_key_as_promoted_is_not_a_hard_reject():          # R7
    assert sc.s0(ROW, NAMES)["ok"]

def test_rename_is_consistent_and_only_change():
    arm = sc.arm_json(ROW, 100, "promoted", "m100_relocate!")
    assert arm["impl_name"] == "m100_relocate!" and arm["body_names"] == ["m100_relocate!"]
    assert arm["calls"][0]["primitive"] == "m100_relocate!"
    assert arm["impl_code"].startswith("function m100_relocate!(env;")
    assert sc.rename_is_only_change(arm)
    assert arm["source_impl_code_sha256"] == hashlib.sha256(CODE.encode()).hexdigest()
    assert arm["artifact_sha256"] == library.artifact_hash(arm)
    bad = dict(arm, impl_code=arm["impl_code"].replace("0.5", "0.6"))
    assert not sc.rename_is_only_change(bad)

def test_two_arms_from_same_source_name_get_distinct_names():
    a = sc.arm_json(ROW, 100, "promoted", "m100_relocate!")
    b = sc.arm_json(ROW, 101, "promoted", "m101_relocate!")
    assert a["impl_name"] != b["impl_name"]

def test_kw_signature_handles_parens_and_strings():
    assert sc.kw_signature(CODE, "relocate!") == \
        'dx::Float64 = 0.5, tag::String = "a(b", ks::Vector{Int} = [1, 2]'
    assert sc.kw_signature("function f!(env)\n  1\nend", "f!") == ""

def test_null_arm_keeps_keywords_and_renames_all_three_fields():
    arm = sc.arm_json(ROW, 900, "candidate", "cand_c0_relocate!")
    n = sc.null_arm(arm)
    assert n["impl_name"] == sc.NULL_NAME and n["body_names"] == [sc.NULL_NAME]
    assert [c["primitive"] for c in n["calls"]] == [sc.NULL_NAME]
    assert n["calls"][0]["args"] == arm["calls"][0]["args"]
    assert sc.kw_signature(n["impl_code"], sc.NULL_NAME) == sc.kw_signature(arm["impl_code"], arm["impl_name"])
    assert n["role"] == "null" and n["surface"] == arm["surface"]
    assert n["artifact_sha256"] == library.artifact_hash(n) != arm["artifact_sha256"]
