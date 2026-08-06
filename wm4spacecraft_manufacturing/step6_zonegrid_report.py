# =============================================================================
# step6_zonegrid_report.py -- STEP 6 합격 기준 채점기 (2026-08-05).
#
# 무엇을 재는가 (계획서 STEP 6 의 세 기준을 그대로):
#   (1) H(best | zone) > 0   -- zone 이라는 **한 종류 안에서** 정답 팔이 갈리는가.
#                               0 이면 "종류만 보면 답이 나오는" 과제라 상태를 읽는 모델이 값을 못 한다.
#   (2) 동점률 < 30%          -- 정답이 유일한가. 동점이 많으면 무엇을 재도 잡음이다.
#   (3) 완주 격차가 regret 으로 드러나는가 -- 이 설계가 쓸모 있다는 유일한 직접 증거.
#
# 덤으로, 이번에 새로 실린 기하 원시값(STEP 3)으로 **각 instance 가 어느 가지였는지**를 사후에
# 분류해 가지별 표를 낸다. 가지를 미리 예측해서 격자를 짜는 대신 사후 분류하는 쪽이 정직하다 --
# 예측이 틀려도 데이터는 그대로 말한다.
#
# 실행:
#   python step6_zonegrid_report.py                     # oracle/out/zgrid_0805/*.jsonl
#   python step6_zonegrid_report.py <glob> [<glob>...]
# =============================================================================
import glob
import math
import os
import sys
from collections import Counter, defaultdict

import pandas as pd

from e1_analyze import load, lex_key, instance_admissible

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = os.path.join(HERE, "oracle", "out", "zgrid_0805", "*.jsonl")
ACTION = {0: "NOOP", 3: "ForbidZone", 7: "RelocateBuild"}


def branch_of(row):
    """행에 실린 기하 원시값으로 이 결정이 어느 가지였는지 사후 분류(STEP 1 의 규칙과 같은 순서).

    원시값이 없는 옛 행이면 'unknown'. 판정(verdict)은 행에 없으므로 여기서 다시 계산한다 --
    그게 정상이다(행에 정답을 싣지 않는다는 STEP 3 의 원칙)."""
    def g(k):
        v = row.get(k, -1)
        try:
            return float(v)
        except (TypeError, ValueError):
            return -1.0

    nf, root, teams, rel = (g("zone_restage_feasible"), g("zone_root_cover"),
                            g("zone_teams_covered"), g("zone_relocatable"))
    if nf < 0 and g("zone_blocked") < 0:
        return "unknown"
    root_hit = (g("zone_root_cover") > 0) if "zone_root_cover" in row else False
    if nf > 0:
        return "forbid_zone"
    if root_hit or teams > 0:
        return "relocate_build" if rel > 0 else "line_stop"
    return "noop"


def _admissible_safe(g):
    """에피소드 모드 덤프에는 대조군이 **아예 없다** -- gen_oracle_dataset.jl:1554 가 ctrl_* 를
    상수 sentinel(false/-1/Inf)로 박는다("control 은 에피소드 모드에서 정의되지 않는다").
    DS_NOCTRL 과는 무관하며, 꺼도 마찬가지임을 실행으로 확인했다. 그러므로 이 열은 구조적으로
    무의미하다 -- 예외로 죽지 말고 False 를 돌려주되, 그 사실을 표에 그대로 남긴다."""
    try:
        return instance_admissible(g)
    except Exception:                                          # noqa: BLE001
        return False


def main(patterns):
    # `*.probes.jsonl` 은 스키마가 다른 부산물(결정 궤적 기록)이다. 같이 읽으면 closed 가 NaN 인
    # 행이 섞여 채점이 깨진다 -- 조용히 NaN 으로 흘려보내지 말고 애초에 제외한다.
    files = sorted(f for p in patterns for f in glob.glob(p) if not f.endswith('.probes.jsonl'))
    if not files:
        print(f"no files matched: {patterns}")
        return 1
    frames = []
    for f in files:
        try:
            d = load(f)
            if len(d):
                d["_src"] = os.path.basename(f)
                frames.append(d)
        except Exception as e:                                    # noqa: BLE001
            print(f"  [skip] {os.path.basename(f)}: {e}")
    if not frames:
        print("no rows")
        return 1
    df = pd.concat(frames, ignore_index=True)
    print(f"[data] {len(files)} file(s), {len(df)} rows, "
          f"{df.instance.nunique()} raw id(s), macros={sorted(df.macro.unique())}")

    # 새 열이 실제로 실렸는지 먼저 본다 -- 안 실렸으면 아래 가지 분류가 전부 unknown 이 된다.
    newcols = [c for c in ("zone_blocked", "zone_restage_feasible", "zone_teams_covered",
                           "zone_relocatable", "zone_relocate_norm") if c in df.columns]
    print(f"[schema] STEP3 원시값 열 {len(newcols)}/5 존재: {newcols}")

    # ---- L1 valid 게이트 -----------------------------------------------------------------
    # 그 시점에 행동할 수 없는 팔(= valid_mask 에 없는 팔)은 실행부가 NOOP 으로 접으므로 결과가
    # NOOP 과 **바이트 동일**하다. 그걸 후보로 세면 동점을 제조하고 H 를 깎는다 -- 재는 게 아니라
    # 잡음을 만드는 것이다. 그래서 채점 전에 걸러내고, 몇 개를 걸렀는지 반드시 보고한다.
    from e1_analyze import _valid_list
    def _is_valid(r):
        v = _valid_list(r.get("valid_mask"))
        return (int(r["macro"]) in v) if v else True
    n_before = len(df)
    # instance id 는 `ep_s<seed>_M<N>_t<t>` 라 **zfrac/발화구간이 안 들어간다** -- 서로 다른 job 의
    # 행이 같은 id 를 갖는다. 그대로 groupby 하면 다른 구역의 결과가 한 결정의 팔로 섞여
    # 조용히 오염된다(실측으로 발견). 파일명을 붙여 결정을 유일하게 식별한다.
    df["_key"] = df["_src"].astype(str) + "::" + df["instance"].astype(str)
    df["_valid"] = [ _is_valid(df.iloc[i]) for i in range(len(df)) ]
    dropped = int((~df["_valid"]).sum())
    df = df[df["_valid"]].copy()
    print(f"[gate] valid_mask 밖 팔 {dropped}/{n_before} 행 제외 "
          f"(그 팔은 NOOP 과 바이트 동일 -- 세면 동점 제조)")

    rows = []
    ties = 0
    for inst, g in df.groupby("_key"):
        keys = {int(r.macro): lex_key(r.complete, r.closed, r.makespan)
                for r in g.itertuples(index=False)}
        if not keys:
            continue
        bestv = max(keys.values())
        best = sorted(m for m, v in keys.items() if v == bestv)
        tie = len(best) > 1
        ties += tie
        first = g.iloc[0]
        rows.append(dict(
            instance=str(inst).split("::")[-1], src=first.get("_src", ""),
            branch=branch_of(first),
            # DS_NOCTRL=1 로 만든 덤프에는 대조군(ctrl_*) 열이 없다 -> admissibility 판정 불가.
            # 그 사실을 예외로 죽지 말고 False 로 남기고, 아래 표에 그대로 보고한다.
            admissible=_admissible_safe(g),
            best=best[0], best_name=ACTION.get(best[0], str(best[0])),
            tie=tie, n_arms=len(keys),
            closed_best=max(int(r.closed) for r in g.itertuples(index=False)),
            closed_noop=int(g[g.macro == 0].closed.iloc[0]) if (g.macro == 0).any() else -1,
            complete_any=bool(g.complete.any()),
            valid_mask=first.get("valid_mask"),
            # 발화 시점: 격자의 early/late 축이 실제로 갈렸는지(아니면 배치 경계 58 로 붕괴했는지)를
            # 주장이 아니라 데이터로 보이기 위한 열이다.
            fired_at=first.get("closed_at_fire", -1),
            zone_overlap=first.get("zone_overlap", -1),
            root_cov=first.get("zone_root_cover", -1),
            n_blocked=first.get("zone_blocked", -1),
            n_feasible=first.get("zone_restage_feasible", -1),
            teams_cov=first.get("zone_teams_covered", -1),
            relocatable=first.get("zone_relocatable", -1),
        ))
    R = pd.DataFrame(rows)
    if R.empty:
        print("no instances")
        return 1

    print("\n== instance 표 ==")
    cols = ["instance", "src", "branch", "best_name", "tie", "n_arms", "fired_at",
            "closed_noop", "closed_best", "zone_overlap", "root_cov",
            "n_blocked", "n_feasible", "teams_cov", "relocatable"]
    print(R[[c for c in cols if c in R.columns]].to_string(index=False))
    fired = sorted(set(int(v) for v in R.fired_at if v is not None and v >= 0))
    print(f"\n[발화 시점] closed_at_fire = {fired}"
          + ("   <- 값이 하나뿐이면 early/late 축이 배치 경계로 붕괴한 것" if len(fired) <= 1 else ""))

    # ---- 기준 (1) H(best | zone) ------------------------------------------------------
    cnt = Counter(R.best_name)
    n = sum(cnt.values())
    H = -sum((c / n) * math.log2(c / n) for c in cnt.values() if c)
    print("\n== 기준 (1) H(best | zone) ==")
    print(f"  정답 분포: {dict(cnt)}")
    print(f"  H = {H:.3f} bits   -> {'PASS (> 0: 종류 안에서 정답이 갈린다)' if H > 0 else 'FAIL (정답이 하나뿐 = 종류만 보면 되는 과제)'}")

    # ---- 기준 (2) 동점률 ---------------------------------------------------------------
    tie_rate = ties / len(R)
    print("\n== 기준 (2) 동점률 ==")
    print(f"  {ties}/{len(R)} = {tie_rate:.1%}   -> {'PASS (< 30%)' if tie_rate < 0.30 else 'FAIL (>= 30%)'}")

    # ---- 기준 (3) 완주/진행 격차가 regret 으로 드러나는가 --------------------------------
    # "항상 같은 팔" 베이스라인들과 오라클의 격차. 0 이면 이 결정은 잴 가치가 없다.
    print("\n== 기준 (3) 고정 팔 베이스라인 대비 regret (closed 기준) ==")
    per_inst = {}
    for inst, g in df.groupby("_key"):
        per_inst[inst] = {int(r.macro): int(r.closed) for r in g.itertuples(index=False)}
    for arm in sorted({m for d in per_inst.values() for m in d}):
        regs = [max(d.values()) - d[arm] for d in per_inst.values() if arm in d]
        if not regs:
            continue
        print(f"  always {ACTION.get(arm, arm):<14} n={len(regs):2d}  "
              f"mean regret={sum(regs)/len(regs):7.2f}  max={max(regs)}")
    print(f"  oracle(정답 선택)                  mean regret=   0.00")
    gap = max(
        (sum(max(d.values()) - d[a] for d in per_inst.values() if a in d) /
         max(1, len([d for d in per_inst.values() if a in d]))
         for a in {m for d in per_inst.values() for m in d}), default=0.0)
    print(f"  -> 최악 고정팔의 평균 regret {gap:.2f} "
          f"{'(PASS: 격차가 실재한다)' if gap > 0 else '(FAIL: 어느 팔이든 같다)'}")

    # ---- 기준 (3-b) makespan 채널 --------------------------------------------------------
    # ★ closed 만 보면 이 사건 종류의 피해를 통째로 놓친다(2026-08-05 실측):
    #   대조군(OOD 없음) closed=291 · makespan=22.25 / 구역+NOOP closed=291 · makespan=47.08.
    #   구역은 노드 수도 완주 여부도 안 바꾸고 **시간만 2.1 배로** 늘린다. 피해 채널을 하나만
    #   보는 것은 측정이 아니라 착시다.
    print("\n== 기준 (3-b) 같은 격차를 makespan 으로 (완주한 판만; 미완주는 별도 표기) ==")
    mk = {}
    for inst, g in df.groupby("_key"):
        d = {}
        for r in g.itertuples(index=False):
            v = float(r.makespan) if isinstance(r.makespan, (int, float)) else math.inf
            d[int(r.macro)] = v if (r.complete and math.isfinite(v)) else math.inf
        mk[inst] = d
    for arm in sorted({m for d in mk.values() for m in d}):
        vals = [(d[arm], min(d.values())) for d in mk.values() if arm in d]
        fin = [(a, b) for a, b in vals if math.isfinite(a) and math.isfinite(b)]
        n_inf = sum(1 for a, _ in vals if not math.isfinite(a))
        if fin:
            reg = sum(a - b for a, b in fin) / len(fin)
            print(f"  always {ACTION.get(arm, arm):<14} n={len(fin):2d}  "
                  f"mean makespan regret={reg:8.2f}   미완주 {n_inf}건")
        else:
            print(f"  always {ACTION.get(arm, arm):<14} 완주한 판 없음 (미완주 {n_inf}건)")


    # ---- 가지별 요약 -------------------------------------------------------------------
    print("\n== 가지별 요약 (사후 분류) ==")
    for br, g in R.groupby("branch"):
        c = Counter(g.best_name)
        print(f"  {br:<15} n={len(g):2d}  정답분포={dict(c)}  동점={int(g.tie.sum())}  "
              f"admissible={int(g.admissible.sum())}")

    # ---- 규칙(오라클)이 실제 최선과 얼마나 일치하는가 ------------------------------------
    # branch -> 규칙이 지정하는 팔. 이게 곧 STEP 2 의 canonical_action 이다.
    rule_arm = {"noop": 0, "forbid_zone": 3, "relocate_build": 7, "line_stop": 0}
    ok = tot = 0
    for r in R.itertuples(index=False):
        a = rule_arm.get(r.branch)
        if a is None:
            continue
        tot += 1
        ok += int(a == r.best)
    if tot:
        print(f"\n== 최소수복 규칙 vs 실측 최선 ==\n  일치 {ok}/{tot} = {ok/tot:.1%}"
              "   (낮으면 규칙이 틀렸다는 뜻 -- 라벨이 아니라 규칙을 고쳐야 한다)")
        bad = [r for r in R.itertuples(index=False)
               if rule_arm.get(r.branch) is not None and rule_arm[r.branch] != r.best]
        if bad:
            print("  규칙이 빗나간 instance (규칙 -> 실측최선):")
            for r in bad:
                print(f"    {r.instance:<22} branch={r.branch:<15} "
                      f"규칙={ACTION.get(rule_arm[r.branch])} -> 실측={r.best_name}"
                      f"   (zone_overlap={r.zone_overlap:.2f}, root_cov={r.root_cov:.2f}, "
                      f"teams_trapped={r.teams_cov}, blocked={r.n_blocked})")
            print("  ↑ 이게 반복되면 규칙의 'root 가 덮이면 개입' 조건이 너무 공격적이라는 뜻이다 --")
            print("    구역이 root 목표를 삼켜도 반응형 회피층이 우회해 완주하는 경우가 있다.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [DEFAULT]))
