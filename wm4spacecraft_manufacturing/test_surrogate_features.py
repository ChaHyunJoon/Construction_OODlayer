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

    # 열 순서 위치 고정 (tautology 방지): FEATURE_NAMES 자체가 아니라 각 블록의 실제 원본
    # 목록(STATE_DESCRIPTORS/PSI_AXES/INTERACTIONS)과 위치별로 비교한다. build_features 가
    # `columns=FEATURE_NAMES` 로 재정렬해도 걸리지 않는 tautology 였던 이전 검사를 보강한다 —
    # 상태·행동 블록이 뒤바뀌어도 FEATURE_NAMES 자체가 그렇게 재구성돼 있으면 위 검사는
    # 못 잡는다. 여기서는 문서화된 블록 배치(상태 6 -> ψ 10 -> 교차 5)를 원본 리스트에 대고
    # 직접 위치로 고정한다.
    cols = list(X.columns)
    check("앞 6열이 STATE_DESCRIPTORS 순서 그대로다",
          cols[0:6] == list(STATE_DESCRIPTORS), str(cols[0:6]))
    check("다음 10열이 PSI_AXES 순서 그대로다",
          cols[6:16] == list(PSI_AXES), str(cols[6:16]))
    check("마지막 5열이 INTERACTIONS 순서 그대로다",
          cols[16:21] == ["%s__x__%s" % (s, a) for s, a in INTERACTIONS], str(cols[16:21]))

    # build_features 는 필터링을 하지 않는다 — 그건 호출자(e1_analyze.load() + `fired`)의 몫이라는
    # 설계 결정을 고정한다. fired=False 모양의 stub 행(미발화 control 런: complete=true,
    # closed=279 인데 실제로는 아무것도 안 쐈다)을 필터 없이 그대로 통과시켜도 에러도 NaN 도 없이
    # 조용히 한 행을 뱉어야 한다 — 그래야 "이 함수가 알아서 걸러줄 것"이라는 가정이 여기서
    # 잘못됐다는 게 이 검사 하나로 드러난다. 실제 필터링이 추가되는 리팩터는 이 검사를 깨야 한다.
    ROW_STUB = dict(ROW_BATTERY, fired=False, complete=True, closed=279,
                    valid_mask=None, arms_labeled=1)
    stub_out = build_features([ROW_STUB])
    check("fired=False stub 행도 필터링 없이 그대로 통과한다 (build_features 는 필터링을 안 한다)",
          len(stub_out) == 1 and not stub_out.isna().any().any(),
          "len=%d nan=%s" % (len(stub_out), stub_out.isna().any().any()))

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
