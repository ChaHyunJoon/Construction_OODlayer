"""T1 schemas under the reference validator (jsonschema, Draft 2020-12).

Same corpus as test/repair_contracts.jl, so the Julia subset validator in
src/verification/repair_types.jl and jsonschema must agree on every case.
    .venv/bin/python -m pytest src/respec/llm_service/test_repair_contract_schemas.py
"""
import copy
import json
import pathlib

import jsonschema
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCHEMAS = {
    "proposal": ROOT / "src/respec/llm_service/tool_proposal.schema.json",
    "manifest": ROOT / "tools/monitor/grid/repair_verification_manifest.schema.json",
}
CORPUS = json.loads((ROOT / "test/fixtures/repair_verification/contracts/corpus.json").read_text())


def _apply(base, ops):
    d = copy.deepcopy(base)
    for op in ops:
        *head, last = op["path"]
        parent = d
        for k in head:
            parent = parent[k]
        if op["op"] == "set":
            parent[last] = op["value"]
        else:
            del parent[last]
    return d


@pytest.mark.parametrize("which", sorted(SCHEMAS))
def test_schema_is_valid_draft_2020_12(which):
    jsonschema.Draft202012Validator.check_schema(json.loads(SCHEMAS[which].read_text()))


@pytest.mark.parametrize("case", CORPUS["cases"], ids=lambda c: c["name"])
def test_corpus_case(case):
    schema = json.loads(SCHEMAS[case["base"]].read_text())
    doc = _apply(CORPUS["bases"][case["base"]], case["ops"])
    ok = jsonschema.Draft202012Validator(schema).is_valid(doc)
    assert ok == case["schema_ok"]
