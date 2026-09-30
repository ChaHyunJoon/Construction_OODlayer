"""ψ 표와 라이브러리 팔 ψ (plan Task 8, spec §11.3). 레포 루트에서 돈다."""
import json, os, subprocess, sys
import pytest
from tools.selfimprove import paths, psi_calc

A0_PSI = {
    0: {'a_cost': 0.0, 'a_intervenes': 0.0, 'a_soft': 0.0, 'a_restores_capacity': 0.0, 'a_relocates_work': 0.0,
        'a_spatial': 0.0, 'a_n_specs': 0.0, 'a_consumes_spare': 0.0, 'a_reversible': 1.0, 'a_scope': 0.0},
    1: {'a_cost': 1.0, 'a_intervenes': 1.0, 'a_soft': 0.0, 'a_restores_capacity': 1.0, 'a_relocates_work': 0.0,
        'a_spatial': 0.0, 'a_n_specs': 1.0, 'a_consumes_spare': 1.0, 'a_reversible': 0.0, 'a_scope': 1.0},
    2: {'a_cost': 0.2, 'a_intervenes': 1.0, 'a_soft': 0.0, 'a_restores_capacity': 1.0, 'a_relocates_work': 0.0,
        'a_spatial': 0.0, 'a_n_specs': 1.0, 'a_consumes_spare': 0.0, 'a_reversible': 1.0, 'a_scope': 1.0},
}
ARM_PSI = {'a_cost': 1.5, 'a_intervenes': 1.0, 'a_soft': 0.0, 'a_restores_capacity': 0.0, 'a_relocates_work': 1.0,
           'a_spatial': 1.0, 'a_n_specs': 1.0, 'a_consumes_spare': 0.0, 'a_reversible': 0.0, 'a_scope': 3.0}

_SCRIPT = r'''
import json, sys
sys.path[:0] = ["src/decision/core"]
import features_agnostic as f
print("@@" + json.dumps({"psi": {m: f.psi(m) for m in (0, 1, 2, 100)}, "bad": f.psi_registry_check()}))
'''

def _run(reg_path):
    out = subprocess.run([sys.executable, "-c", _SCRIPT], cwd=paths.ROOT, capture_output=True, text=True,
                         env=dict(os.environ, ACTION_REGISTRY=reg_path))
    line = [l for l in out.stdout.splitlines() if l.startswith("@@")]
    assert line, out.stderr[-2000:]
    return json.loads(line[0][2:])

def test_library_arm_psi_is_read_from_registry(tmp_path):
    reg = json.load(open(paths.A0_REGISTRY))
    reg["vocab"] = "v5-4arms"
    reg["macros"]["100"] = {"name": "m100_x!", "cost": 1.5, "kinds": ["zone"], "mechanism": "t",
                            "when_to_use": "t", "library_arm": 100, "psi": ARM_PSI}
    p = tmp_path / "reg.json"; p.write_text(json.dumps(reg))
    r = _run(str(p))
    assert r["psi"]["100"] == ARM_PSI and r["bad"] == []
    for m, want in A0_PSI.items():                      # (d) 리팩터 뒤에도 A₀ ψ 불변
        assert r["psi"][str(m)] == want

def test_aggregate_rules():
    table = {"a": [1.0, 1.0, 1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0],
             "b": [0.5, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 3.0]}
    got = psi_calc.psi_for(["a", "b"], table)
    assert got["a_cost"] == 1.5 and got["a_intervenes"] == 1.0 and got["a_soft"] == 0.0
    assert got["a_restores_capacity"] == 1.0 and got["a_spatial"] == 1.0 and got["a_n_specs"] == 2.0
    assert got["a_consumes_spare"] == 1.0 and got["a_reversible"] == 0.0 and got["a_scope"] == 3.0

def test_empty_call_set_gets_reviewable_default():
    got = psi_calc.psi_for([], {})
    assert (got["a_intervenes"], got["a_spatial"], got["a_relocates_work"], got["a_reversible"],
            got["a_scope"], got["a_cost"]) == (1.0, 1.0, 1.0, 0.0, 2.0, 1.0)

def test_unannotated_name_raises():
    with pytest.raises(KeyError):
        psi_calc.psi_for(["translate_whole_build!"], {})
