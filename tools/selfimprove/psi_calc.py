"""도구 T 의 ψ = 호출하는 world-interface 함수들의 ψ 행을 기존 psi() 규칙으로 집계 (spec §11.3).

ψ 표는 실험 데이터(`data/selfimprove/<exp>/psi/base_psi.json`, 이름 → 9-튜플)이고 검토자가 행을 더한다."""
import os, sys
from . import paths

sys.path.insert(0, os.path.join(paths.ROOT, "src", "decision", "core"))
import features_agnostic  # noqa: E402

# C = ∅ (기하를 손으로 옮기는 body): 검토자가 확인·수정할 기본값 (spec §11.3)
EMPTY_DEFAULT = {"a_cost": 1.0, "a_intervenes": 1.0, "a_soft": 0.0, "a_restores_capacity": 0.0,
                 "a_relocates_work": 1.0, "a_spatial": 1.0, "a_n_specs": 1.0,
                 "a_consumes_spare": 0.0, "a_reversible": 0.0, "a_scope": 2.0}

def psi_for(called, table):
    if not called:
        return dict(EMPTY_DEFAULT)
    rows = [table[n] for n in called]            # 주석 없는 이름은 KeyError — 검토(R4)가 채운다
    return features_agnostic.aggregate_psi(rows)
