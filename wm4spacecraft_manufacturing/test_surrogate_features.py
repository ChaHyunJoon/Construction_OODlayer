#!/usr/bin/env python3
"""surrogate_features 단위검사 — 21차원, 순서 고정, kind 누출 없음."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from surrogate_features import FEATURE_NAMES, build_features, INTERACTIONS
from features_agnostic import STATE_DESCRIPTORS, PSI_AXES

FAILS = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("   " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


ROW_BATTERY = dict(kind="battery", macro=8, severity=0.10, soc=0.10, spare_count=3,
                   agent_pending=5, progress=0.4, n_active=10, n_spare_cfg=3,
                   closed_at_fire=120, total=313, zone_overlap=None, zone_radius=None,
                   valid_mask=[0, 1, 2, 8])
ROW_FAULT = dict(ROW_BATTERY, kind="fault", macro=1, soc=None, severity=1.0,
                 valid_mask=[0, 1, 2, 4])


def main():
    print("== surrogate_features ==")
    check("FEATURE_NAMES 가 21개", len(FEATURE_NAMES) == 21, str(len(FEATURE_NAMES)))
    check("상태 6축이 전부 있다", all(s in FEATURE_NAMES for s in STATE_DESCRIPTORS))
    check("ψ 10축이 전부 있다", all(a in FEATURE_NAMES for a in PSI_AXES))
    check("교차 5개가 있다", len(INTERACTIONS) == 5, str(INTERACTIONS))

    # kind 누출 금지: 열 이름 어디에도 kind 이름이 없어야 한다.
    leaked = [c for c in FEATURE_NAMES
              if any(k in c for k in ("fault", "battery", "zone", "kind"))]
    check("kind 이름이 feature 에 누출되지 않는다", not leaked, str(leaked))

    X = build_features([ROW_BATTERY, ROW_FAULT])
    check("열 순서가 FEATURE_NAMES 와 정확히 같다", list(X.columns) == FEATURE_NAMES)
    check("행 수가 입력과 같다", len(X) == 2)
    check("NaN 이 없다", not X.isna().any().any(), str(X.isna().sum().sum()))

    # 핵심 교차항이 실제로 두 팔을 가른다.
    swap = build_features([dict(ROW_BATTERY, macro=8)]).iloc[0]
    repl = build_features([dict(ROW_BATTERY, macro=1)]).iloc[0]
    check("SwapBattery 와 Replace 의 feature 가 다르다", not swap.equals(repl))
    check("a_consumes_spare 가 두 팔을 가른다",
          swap["a_consumes_spare"] != repl["a_consumes_spare"],
          "swap=%s replace=%s" % (swap["a_consumes_spare"], repl["a_consumes_spare"]))
    noop = build_features([dict(ROW_BATTERY, macro=0)]).iloc[0]
    check("SwapBattery 와 NOOP 의 feature 가 다르다 (Task 1 의 psi 수정 의존)",
          not swap.equals(noop))

    print("\n%s" % ("전부 통과" if not FAILS else "실패 %d개: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
