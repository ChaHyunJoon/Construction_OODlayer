#!/usr/bin/env python3
"""
llm_ood_eval.py -- 확률적 OOD 스트림 위에서 정책을 돌리고 **평가지표 4종**으로 채점한다.

이 저장소가 지금까지 못 하던 것 (STATUS §5)
--------------------------------------------
모든 평가에서 사건 시점이 고정이었다(오라클=격자, 데모=슬롯 [0.10, 0.32, 0.55]). 즉 "적응적"
이라는 주장의 근거가 사실상 한두 개의 대본이었고, **무작위 스트림 위에서 정책을 비교한 적은
한 번도 없었다.** 게다가 공간 사건(zone)은 언제나 sim 전에 1회 고정으로 터졌다.
이 스크립트는 `run_demo.jl DEMO_OOD_STREAM3=1` 과 짝을 이뤄 그 구멍을 닫는다:
fault / battery / zone 이 **하나의 추첨**으로 시점·종류·심각도를 뽑아 오는 판을 여러 시드로 돌린다.

평가지표 4종
------------
  ① 완주율 (success rate)          : complete 비율 + Wilson CI
  ② 옳은 결정 비율 (decision rate)  : reference_policy.py 의 기준 행동 a* 대비 적중률
                                     -- 반사실 오라클이 **아니라** 격자 실측에서 유도한 기준 정책이다
  ③ 빌드 시간 (building time)       : sim_seconds(= dt x steps). 완주한 판만 평균낸다
  ④ 에너지 효율 (SoC/energy)        : 닫힌 노드당 에너지 + 평균/최소 SoC
                                     -- 총 에너지만 보면 **미완주가 유리해진다**(일을 덜 해서)

★ 런은 절대 병렬로 돌리지 않는다 (README 함정 30)
   run_lego_demo 는 HiGHS MILP 로 스케줄을 푸는데 CPU 경합이 다르면 **다른 해**를 돌려준다.
   병렬로 돌리면 정책 비교가 아니라 서로 다른 두 세계의 비교가 된다. 그래서 subprocess 는
   언제나 하나씩, 순차로만 띄운다. 느린 것은 이 실험의 비용이지 최적화할 대상이 아니다.

실행
----
  python llm_ood_eval.py run    --seeds 1,2,3,4,5 --policies noop,canonical,dspy
  python llm_ood_eval.py report --out results/llm_ood_eval.jsonl
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))

from ood_sweep_report import sign_test, wilson          # noqa: E402  (검정 도구는 재사용)
import reference_policy                                  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")             # cp949 콘솔에서 em-dash 로 죽는 것 방지
except Exception:
    pass

DEFAULT_OUT = HERE / "results" / "llm_ood_eval.jsonl"


# =========================================================================================
#  1. 런 드라이버
# =========================================================================================
def run_one(seed, policy, out_path, log_dir, args):
    """한 판(= ood_seed 하나 x 정책 하나)을 돌린다. 반환: (ok, wall_seconds, log_path)."""
    env = dict(os.environ)
    env.update(
        PYTHONIOENCODING="utf-8",
        DEMO_MODEL=args.model,
        DEMO_OOD=args.case,
        DEMO_OOD_STREAM3="1",
        DEMO_N=str(args.events),
        DEMO_OOD_SEED=str(seed),
        DEMO_SEED=str(args.world_seed),          # world = 로봇 초기 배치. 고정 축(README: 축 분리)
        DEMO_POLICY=policy,
        DEMO_ROUTER="0",                         # 정책 비교에서는 라우터를 끈다(STATUS §5)
        DEMO_SPARES=str(args.spares),
        DEMO_REFORM=str(args.reform),
        DEMO_REFORM_MAX=str(args.reform_max),
        DEMO_BSOC=str(args.bsoc),
        DEMO_OOD_SEVFRAC=str(args.sev_frac),
        CARRIER_RESCUE="1",
        RELOCATE_GATE="1",
        DSPY_URL=args.dspy_url,
        LLM_NL_MODE="observation",               # 관찰만 준다(지시절은 곧 정답이라 프롬프트 준수를 잰다)
        # 절대경로로 넘긴다. julia 는 cwd=repo 루트에서 돌므로 상대경로를 주면 요약이
        # wm4.../results 가 아니라 repo/results 에 조용히 떨어진다(2026-08-06 실측).
        DEMO_SUMMARY=str(out_path.resolve()),
        MONITOR_STREAM=str((log_dir / ("stream_s%d_%s.jsonl" % (seed, policy))).resolve()),
    )
    log = log_dir / ("run_s%d_%s.log" % (seed, policy))
    t0 = time.time()
    with open(log, "w", encoding="utf-8") as fh:
        p = subprocess.run(["julia", "+lts", "--project=.", "tools/monitor/run_demo.jl"],
                           cwd=str(REPO), env=env, stdout=fh, stderr=subprocess.STDOUT)
    return p.returncode == 0, time.time() - t0, log


def cmd_run(args):
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    log_dir = out_path.parent / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    policies = [s.strip() for s in args.policies.split(",") if s.strip()]
    total = len(seeds) * len(policies)
    print("=== %d runs (%d seeds x %d policies), STRICTLY SEQUENTIAL ===" % (total, len(seeds), len(policies)))
    done = 0
    for seed in seeds:                        # 시드 바깥 / 정책 안쪽 = 같은 스트림을 연달아 비교
        for policy in policies:
            done += 1
            print("[%2d/%2d] seed=%d policy=%-9s ..." % (done, total, seed, policy), end="", flush=True)
            ok, secs, log = run_one(seed, policy, out_path, log_dir, args)
            print(" %s  %.0f s  -> %s" % ("ok" if ok else "FAILED", secs, log.name), flush=True)
    print("\nsummaries -> %s" % out_path)
    return 0


# =========================================================================================
#  2. 리포트
# =========================================================================================
def load_rows(path):
    """요약 JSONL. 같은 (ood_seed, policy) 는 **마지막 것**만 쓴다(재실행 = 덮어쓰기)."""
    dedup = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            dedup[(r.get("ood_seed"), r.get("policy"))] = r
    return list(dedup.values())


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def _sd(xs):
    xs = [x for x in xs if x is not None]
    return statistics.stdev(xs) if len(xs) > 1 else 0.0


def summarize(rows):
    """정책별 4개 축 + 결정 분포를 계산한다."""
    by = defaultdict(list)
    for r in rows:
        by[r.get("policy", "?")].append(r)
    out = {}
    for pol, rs in sorted(by.items()):
        n = len(rs)
        k = sum(1 for r in rs if r.get("complete"))
        # ② 옳은 결정: 모든 판의 사건을 한 통에 모아 센다(사건 단위 비율).
        scored = correct = 0
        per_kind = defaultdict(lambda: [0, 0])
        chosen = Counter()
        detail = []
        for r in rs:
            s, c, drows = reference_policy.score(r.get("decisions") or [])
            scored += s
            correct += c
            for d in drows:
                chosen[d["chosen"]] += 1
                if d["correct"] is not None:
                    per_kind[d["truth"]][0] += 1
                    per_kind[d["truth"]][1] += int(d["correct"])
                detail.append(dict(d, ood_seed=r.get("ood_seed")))
        comp = [r for r in rs if r.get("complete")]
        bat = [r.get("battery") or {} for r in rs]
        out[pol] = dict(
            n=n, n_complete=k, success=k / n if n else 0.0, success_ci=wilson(k, n),
            n_decisions_scored=scored, n_decisions_correct=correct,
            decision_rate=(correct / scored if scored else None),
            decision_ci=(wilson(correct, scored) if scored else None),
            per_kind={kk: dict(n=v[0], correct=v[1], rate=(v[1] / v[0] if v[0] else None))
                      for kk, v in per_kind.items()},
            chosen=dict(chosen),
            # ③ 시간은 **완주한 판만** 평균낸다. 미완주 판의 steps 는 정지 판정 대기(2500 step)를
            #    포함하므로 섞으면 "실패가 느리다"가 아니라 "실패가 빠르다"로 뒤집혀 읽힌다.
            sim_seconds_complete=_mean([r.get("sim_seconds") for r in comp]),
            sim_seconds_sd=_sd([r.get("sim_seconds") for r in comp]),
            steps_complete=_mean([r.get("steps") for r in comp]),
            wall_seconds=_mean([r.get("wall_seconds") for r in rs]),
            progress=_mean([r.get("progress") for r in rs]),
            # ④ 에너지: 닫힌 노드당이 정직한 축(총량은 미완주에 유리하다).
            energy_per_closed=_mean([b.get("energy_per_closed") for b in bat]),
            total_energy_J=_mean([b.get("total_energy_J") for b in bat]),
            mean_soc=_mean([b.get("mean_soc") for b in bat]),
            min_soc=_mean([b.get("min_soc") for b in bat]),
            n_depleted=_mean([b.get("n_depleted") for b in bat]),
            spares_left=_mean([r.get("spares_left") for r in rs]),
            detail=detail,
        )
    return out


def paired(rows, a, b):
    """같은 ood_seed 에서 두 정책을 맞대어 승/패/무 (완주 우선, 그다음 closed)."""
    idx = {(r.get("ood_seed"), r.get("policy")): r for r in rows}
    seeds = sorted({r.get("ood_seed") for r in rows})
    w = l = t = 0
    for s in seeds:
        ra, rb = idx.get((s, a)), idx.get((s, b))
        if ra is None or rb is None:
            continue
        ka = (1 if ra.get("complete") else 0, ra.get("closed", 0))
        kb = (1 if rb.get("complete") else 0, rb.get("closed", 0))
        if ka > kb:
            w += 1
        elif ka < kb:
            l += 1
        else:
            t += 1
    return w, l, t, sign_test(w, l)


def cmd_report(args):
    path = Path(args.out)
    if not path.exists():
        print("요약 파일이 없다: %s\n  먼저: python llm_ood_eval.py run" % path)
        return 1
    rows = load_rows(path)
    res = summarize(rows)
    seeds = sorted({r.get("ood_seed") for r in rows})
    print("=" * 92)
    print("확률적 OOD 스트림 평가 -- %d 판 / ood_seed %s / world_seed 고정" % (len(rows), seeds))
    print("=" * 92)
    print()
    print("%-11s %3s  %-17s  %-18s  %9s  %11s  %8s" %
          ("policy", "n", "1) success", "2) right decision", "3) sim_s", "4) J/closed", "min SoC"))
    print("-" * 92)
    for pol, d in res.items():
        dr = ("%5.1f%% [%d/%d]" % (100 * d["decision_rate"], d["n_decisions_correct"],
                                   d["n_decisions_scored"])) if d["decision_rate"] is not None else "n/a"
        print("%-11s %3d  %5.1f%% [%2d/%2d]  %-18s  %9s  %11s  %8s" % (
            pol, d["n"], 100 * d["success"], d["n_complete"], d["n"], dr,
            ("%.1f" % d["sim_seconds_complete"]) if d["sim_seconds_complete"] else "-",
            ("%.1f" % d["energy_per_closed"]) if d["energy_per_closed"] else "-",
            ("%.3f" % d["min_soc"]) if d["min_soc"] is not None else "-"))
    print()
    for pol, d in res.items():
        lo, hi = d["success_ci"]
        print("  %-11s success 95%% CI [%.2f, %.2f] · mean progress %.3f · spares left %.1f · wall %.0f s"
              % (pol, lo, hi, d["progress"] or 0, d["spares_left"] or 0, d["wall_seconds"] or 0))
        if d["per_kind"]:
            print("      per-kind decision rate: " +
                  ", ".join("%s %d/%d" % (k.replace("Truth", ""), v["correct"], v["n"])
                            for k, v in sorted(d["per_kind"].items())))
        print("      macros chosen: " + ", ".join("%s x%d" % kv for kv in sorted(d["chosen"].items())))
    print()
    pols = list(res)
    for i in range(len(pols)):
        for j in range(i + 1, len(pols)):
            w, l, t, p = paired(rows, pols[i], pols[j])
            print("  paired %-10s vs %-10s : %d win / %d loss / %d tie   sign-test p=%.3f"
                  % (pols[i], pols[j], w, l, t, p))
    print()
    print("기준 행동 a* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):")
    for k, v in reference_policy.BASIS.items():
        print("  %-8s %s" % (k, v))
    if args.md:
        # 리포트 표를 **여기서** 만들어 md 에 붙인다. 손으로 옮겨 적으면 문서의 숫자와 아티팩트의
        # 숫자가 갈라지고, 그 어긋남은 아무도 눈치채지 못한 채 인용된다.
        order = [p for p in ("noop", "canonical", "surrogate", "dspy") if p in res] + \
                [p for p in res if p not in ("noop", "canonical", "surrogate", "dspy")]
        L = ["| 정책 | n | ① 완주율 (95% CI) | ② 옳은 결정 | ③ 빌드 시간 (완주판, sim s) | "
             "④ J/closed | min SoC | 남은 스페어 |",
             "|---|---|---|---|---|---|---|---|"]
        for pol in order:
            d = res[pol]
            lo, hi = d["success_ci"]
            dr = ("%.0f%% (%d/%d)" % (100 * d["decision_rate"], d["n_decisions_correct"],
                                      d["n_decisions_scored"])) if d["decision_rate"] is not None else "n/a"
            L.append("| `%s` | %d | %.0f%% (%d/%d) [%.2f, %.2f] | %s | %s | %.0f | %.3f | %.1f |" % (
                pol, d["n"], 100 * d["success"], d["n_complete"], d["n"], lo, hi, dr,
                ("%.1f ± %.1f" % (d["sim_seconds_complete"], d["sim_seconds_sd"]))
                if d["sim_seconds_complete"] else "— (완주 0)",
                d["energy_per_closed"] or 0, d["min_soc"] or 0, d["spares_left"] or 0))
        L.append("")
        L.append("| 정책 | 고른 매크로 | 종류별 적중 |")
        L.append("|---|---|---|")
        for pol in order:
            d = res[pol]
            L.append("| `%s` | %s | %s |" % (
                pol,
                ", ".join("%s×%d" % kv for kv in sorted(d["chosen"].items(), key=lambda t: -t[1])),
                ", ".join("%s %d/%d" % (k.replace("Truth", ""), v["correct"], v["n"])
                          for k, v in sorted(d["per_kind"].items())) or "—"))
        L.append("")
        for i in range(len(order)):
            for j in range(i + 1, len(order)):
                w, l, t, p = paired(rows, order[i], order[j])
                L.append("- 짝지은 비교 `%s` vs `%s` — %d승 %d패 %d무, 부호검정 p=%.3f"
                         % (order[i], order[j], w, l, t, p))
        Path(args.md).write_text("\n".join(L) + "\n", encoding="utf-8")
        print("\nmarkdown -> %s" % args.md)
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(dict(seeds=seeds, n_runs=len(rows), policies=res,
                           basis=reference_policy.BASIS), fh, ensure_ascii=False, indent=2)
        print("\njson -> %s" % args.json)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run")
    r.add_argument("--seeds", default="1,2,3,4,5")
    r.add_argument("--policies", default="noop,canonical,dspy")
    r.add_argument("--out", default=str(DEFAULT_OUT))
    r.add_argument("--case", default="all")
    r.add_argument("--model", default="tractor.mpd")
    r.add_argument("--events", type=int, default=4)
    r.add_argument("--world-seed", type=int, default=1)
    r.add_argument("--spares", type=int, default=3)
    r.add_argument("--reform", type=int, default=300)
    r.add_argument("--reform-max", type=int, default=6)
    r.add_argument("--bsoc", type=float, default=0.9)
    r.add_argument("--sev-frac", type=float, default=0.5)
    r.add_argument("--dspy-url", default="http://127.0.0.1:8090")
    r.set_defaults(func=cmd_run)

    p = sub.add_parser("report")
    p.add_argument("--out", default=str(DEFAULT_OUT))
    p.add_argument("--json", default="")
    p.add_argument("--md", default="", help="결과 표를 markdown 조각으로 쓴다(문서에 붙여 넣을 것)")
    p.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
