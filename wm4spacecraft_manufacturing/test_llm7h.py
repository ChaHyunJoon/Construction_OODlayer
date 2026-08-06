#!/usr/bin/env python3
"""
test_llm7h.py -- 이 작업이 새로 만든 것들의 검사.

가장 중요한 검사는 3번이다: **기준 정책(reference_policy)이 정말로 격자 실측과 일치하는가.**
규칙을 손으로 적어 놓고 "실측에서 유도했다"고 주장하는 것은 검증이 아니다. 여기서는 오라클
덤프의 모든 instance 에 대해 (a) 팔을 전부 굴린 결과의 사전식 최선과 (b) 규칙의 답을 맞대어 본다.
어긋나면 규칙이 틀린 것이고, 그 사실이 리포트 숫자의 전제를 무너뜨린다.

실행:  python test_llm7h.py     (종료코드 0 = 전부 통과)
"""
import collections
import io
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import e1_analyze as E                                    # noqa: E402
import reference_policy as RP                             # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

LAM = 3.0
FAILS = []


def check(name, ok, detail=""):
    print("  %-58s %s%s" % (name, "PASS" if ok else "FAIL", ("  " + detail) if detail else ""))
    if not ok:
        FAILS.append(name)


def rows_of(path):
    return [json.loads(l) for l in io.open(HERE / path, encoding="utf-8") if l.strip()]


def lexbest(rs):
    """이 instance 에서 오라클이 고른 팔(비용을 뺀 사전식 최선) = 정답 라벨."""
    def key(r):
        mk = float("inf") if r["makespan"] == "Inf" else float(r["makespan"])
        return E.lex_key(r["complete"], r["closed"] - LAM * E.MACRO_COST[int(r["macro"])], mk)
    return E.MACRO_NAME[int(max(rs, key=key)["macro"])]


def group(rs):
    g = collections.defaultdict(list)
    for r in rs:
        g[r["instance"]].append(r)
    return g


print("=" * 78)
print("1. 행동 어휘 레지스트리 (Ch-A)")
print("=" * 78)
p = subprocess.run([sys.executable, str(HERE / "audit_action_vocab.py")],
                   capture_output=True, text=True, encoding="utf-8", errors="replace")
check("audit_action_vocab.py -> 6/6 consistent", p.returncode == 0,
      (p.stdout or "").strip().splitlines()[-1] if p.stdout else "")
import action_registry as AR                              # noqa: E402
check("SwapBattery(8) 가 어휘에 있다", AR.MACRO_NAME.get(8) == "SwapBattery")
check("RelocateBuild(7) 가 어휘에 있다", AR.MACRO_NAME.get(7) == "RelocateBuild")
check("SwapBattery 가 Replace 보다 싸다",
      AR.MACRO_COST[8] < AR.MACRO_COST[1], "%.1f < %.1f" % (AR.MACRO_COST[8], AR.MACRO_COST[1]))

print()
print("=" * 78)
print("2. 기준 정책의 형태 (규칙이 실제로 갈리는가)")
print("=" * 78)
deep = dict(truth="BatteryTruth", soc=0.02, valid=["NOOP", "Replace", "Deprioritize", "SwapBattery"])
mild = dict(truth="BatteryTruth", soc=0.45, valid=["NOOP", "Replace", "Deprioritize", "SwapBattery"])
check("깊은 방전 -> SwapBattery", RP.reference_action(deep)[0] == "SwapBattery")
check("완만한 열화 -> NOOP", RP.reference_action(mild)[0] == "NOOP")
check("SwapBattery 가 메뉴에 없으면 Replace 로 대체",
      RP.reference_action(dict(deep, valid=["NOOP", "Replace"]))[0] == "Replace")
check("fault pending>0 -> Replace",
      RP.reference_action(dict(truth="FaultTruth", agent_pending=3))[0] == "Replace")
check("fault pending=0 -> NOOP",
      RP.reference_action(dict(truth="FaultTruth", agent_pending=0))[0] == "NOOP")
check("zone 막힘>0 & root 0 -> RelocateBuild",
      RP.reference_action(dict(truth="ZoneTruth", valid=["NOOP", "RelocateBuild"],
                               zone_primitives=dict(n_nav_blocked=3, root_covered=0)))[0]
      == "RelocateBuild")
check("zone root 갇힘 -> NOOP (전역 이동이 더 손해)",
      RP.reference_action(dict(truth="ZoneTruth", valid=["NOOP", "RelocateBuild"],
                               zone_primitives=dict(n_nav_blocked=1, root_covered=8)))[0] == "NOOP")
check("근거 없는 사건은 채점 제외(None)",
      RP.reference_action(dict(truth="ReformTruth"))[0] is None)
check("원시값이 없으면 채점 제외(0 으로 채우지 않는다)",
      RP.reference_action(dict(truth="ZoneTruth", valid=[]))[0] is None)

print()
print("=" * 78)
print("3. ★ 기준 정책 vs 오라클 실측 라벨 (규칙이 근거와 일치하는가)")
print("=" * 78)

# ---- battery: battgrid_0805_s1 (3팔 전수, SwapBattery 포함) --------------------------------
g = group(rows_of("oracle/out/battgrid_0805_s1.jsonl"))
agree = []
for iid, rs in sorted(g.items()):
    star = lexbest(rs)
    valid = [E.MACRO_NAME[int(r["macro"])] for r in rs]
    got = RP.reference_action(dict(truth="BatteryTruth", soc=rs[0].get("soc"), valid=valid))[0]
    agree.append((iid, star, got))
bad = [a for a in agree if a[1] != a[2]]
check("battery 규칙 == 오라클 최선 (battgrid, n=%d)" % len(agree), not bad,
      "%d/%d" % (len(agree) - len(bad), len(agree)) + ("  mismatches: %s" % bad[:3] if bad else ""))

# ---- fault: firegrid_merged 의 fault/faultidle instance ------------------------------------
g = group(rows_of("oracle/out/firegrid_merged.jsonl"))
agree = []
for iid, rs in sorted(g.items()):
    if rs[0]["kind"] != "fault":
        continue
    star = lexbest(rs)
    valid = [E.MACRO_NAME[int(r["macro"])] for r in rs]
    got = RP.reference_action(dict(truth="FaultTruth", agent_pending=rs[0].get("agent_pending"),
                                   valid=valid))[0]
    agree.append((iid, star, got))
bad = [a for a in agree if a[1] != a[2]]
check("fault 규칙 == 오라클 최선 (firegrid, n=%d)" % len(agree), not bad,
      "%d/%d" % (len(agree) - len(bad), len(agree)) + ("  mismatches: %s" % bad[:3] if bad else ""))

# ---- zone: zcausal_reform (STEP 10, 팔 교차 2사건) ----------------------------------------
# 이 가족은 JSONL 이 아니라 팔별 json 파일이라 직접 맞대어 본다. n=2 — 가장 약한 축이고,
# 그 사실을 리포트에도 그대로 적는다.
zc = HERE / "oracle" / "out" / "zcausal_reform"
zone_cases = []
for fam, noop_f, act_f in (("blk", "blk_noop.json", "blk_reloc.json"),
                           ("cov", "cov_noop.json", "cov_reloc.json")):
    try:
        a = json.load(open(zc / noop_f, encoding="utf-8"))
        b = json.load(open(zc / act_f, encoding="utf-8"))
    except OSError:
        continue
    ka = (1 if a["status"] == "complete" else 0, a["closed"] - LAM * 0.0)
    kb = (1 if b["status"] == "complete" else 0, b["closed"] - LAM * AR.MACRO_COST[7])
    star = "RelocateBuild" if kb > ka else "NOOP"
    got = RP.reference_action(dict(truth="ZoneTruth", valid=["NOOP", "RelocateBuild"],
                                   zone_primitives=dict(n_nav_blocked=a["nav_blocked"],
                                                        root_covered=a["root_covered"])))[0]
    zone_cases.append((fam, star, got))
bad = [c for c in zone_cases if c[1] != c[2]]
check("zone 규칙 == 오라클 최선 (zcausal, n=%d)" % len(zone_cases),
      bool(zone_cases) and not bad,
      "%s" % zone_cases)

print()
print("=" * 78)
print("%d/%d passed" % (9 + 3 + 4 - len(FAILS), 9 + 3 + 4))
if FAILS:
    print("FAILED: " + ", ".join(FAILS))
sys.exit(1 if FAILS else 0)
