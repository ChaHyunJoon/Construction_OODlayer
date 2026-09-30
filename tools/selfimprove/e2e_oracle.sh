#!/usr/bin/env bash
# selfimprove 무료 종단 시험 (plan Task 19, spec §14). 레포 루트에서:
#   tools/selfimprove/e2e_oracle.sh init|a0|inject|cycle|approve|status      ← 무료 (canonical 레인, 서비스 0)
#   CONFIRM_PAID=1 tools/selfimprove/e2e_oracle.sh paid                      ← Step 4: D 게이트 부모(v0) 판의
#                                                                              zone 사건이 LLM 으로 간다 (U3, 유료)
set -euo pipefail
cd "$(dirname "$0")/../.."
EXP=${EXP:-e2e-oracle}
PY=.venv/bin/python
unset DSPY_URL                       # canonical 그리드는 서비스 신원 검사를 안 태운다
case "${1:?step}" in
  init)    $PY -m tools.selfimprove init --exp "$EXP" ;;
  a0)      $PY - "$EXP" <<'PY'
import json, os, sys
from tools.selfimprove import a0_relabel, online, paths
exp = sys.argv[1]
cfg = json.load(open(os.path.join(paths.state_dir(exp), "config.json")))
rev, dirty = online.code_identity()
sys.path.insert(0, "src/decision/core"); import objective
stamps = {"vocab": "v4-3arms", "train_kinds": "battery,fault", "objective_hash": objective.objective_hash(),
          "names": {0: "NOOP", 1: "Replace", 2: "SwapBattery"}}
print(a0_relabel.run(exp, cfg, rev, dirty, stamps, workers=cfg["offline_workers"]))
PY
  ;;
  inject)  $PY -m tools.selfimprove.e2e inject --exp "$EXP" ;;
  cycle)   $PY - "$EXP" <<'PY'
import sys
from tools.selfimprove import watch
print("cycle:", watch.tick(sys.argv[1]))
PY
  ;;
  approve) $PY -m tools.selfimprove.e2e psi --exp "$EXP"
           $PY -m tools.selfimprove review c0 --exp "$EXP" --approve --reviewer test \
               --reason "e2e 시험용 승인 (oracle fixture — LLM 출처 주장 제외)" \
               --psi-rows-added translate_whole_build! restage_all_blocked! active_restriction_zones ;;
  paid)    [ "${CONFIRM_PAID:-}" = 1 ] || { echo "Step 4 is paid (U3): set CONFIRM_PAID=1" >&2; exit 2; }
           $PY -m tools.selfimprove cycle c0 --exp "$EXP" --from APPROVED ;;
  status)  $PY -m tools.selfimprove status --exp "$EXP" ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
