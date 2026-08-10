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
def _validate_router_args(args):
    """1-a/1-b: 라우터 옵트인의 안전장치. 서브프로세스가 뜨기 전에 여기서 걸러야 한다.

    - calib 경로를 줬는데 그 파일이 없으면: router 값과 무관하게 즉시 에러(router=0 이어도
      advisory 판정이 조용히 깨진 채 도는 것을 막는다).
    - `--router` 가 "0" 이 아닌데 calib 가 없으면: policy.jl:67-68 이 경고만 찍고 라우터를
      꺼버린다(fail-open). "라우터 ON" 이라는 이름의 판이 실제로는 OFF 로 측정되는, 이번 STEP 이
      막아야 할 가장 위험한 조용한 실패다.
    - `--policies` 에 noop 이 섞여 있으면: policy.jl:332 가 POLICY=="noop" 에서 라우팅 자체를
      끈다(noop 은 "정책 후보" 가 아니라 통제 실험의 바닥선). `--router` 옵트인과 양립 불가.
    반환: None(통과) 또는 에러 메시지 문자열.
    """
    if args.novelty_calib and not Path(args.novelty_calib).exists():
        return "--novelty-calib 경로에 파일이 없다: %s" % args.novelty_calib
    if args.router == "0":
        return None
    if not args.novelty_calib:
        return ("--router %s 는 --novelty-calib PATH 가 필요하다. calib 없이 라우터를 켜면 "
                "policy.jl 이 fail-open 으로 라우터를 꺼버려 'ON' 이라는 이름의 판이 실제로는 "
                "OFF 로 측정된다." % args.router)
    policies = [s.strip() for s in args.policies.split(",") if s.strip()]
    if "noop" in policies:
        return ("--router %s 와 --policies 의 noop 은 같이 쓸 수 없다 "
                "(policy.jl:332 가 POLICY==noop 에서 라우팅을 끈다 -- noop 은 통제 바닥선)"
                % args.router)
    return None


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
        DEMO_ROUTER=args.router,                 # 기본 "0" = 기존 동작(정책 비교, STATUS §5). opt-in: --router
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
    if args.novelty_calib:
        # 여기도 절대경로로 넘긴다 -- DEMO_SUMMARY 와 같은 함정(julia cwd=repo 루트).
        env["NOVELTY_CALIB"] = str(Path(args.novelty_calib).resolve())
    log = log_dir / ("run_s%d_%s.log" % (seed, policy))
    t0 = time.time()
    with open(log, "w", encoding="utf-8") as fh:
        p = subprocess.run(["julia", "+lts", "--project=.", "tools/monitor/run_demo.jl"],
                           cwd=str(REPO), env=env, stdout=fh, stderr=subprocess.STDOUT)
    return p.returncode == 0, time.time() - t0, log


ROUTER_ENGAGED_TARGETS = {"surrogate", "dspy"}    # route() 가 실제로 고를 수 있는 값은 이 둘뿐(policy.jl:349)


def _router_drove(out_path, case, ood_seed, policy, want_router):
    """1-b: `--router != 0` 로 던 판이 실제로 라우터를 구동했는지 사후 확인.

    (2026-08-10 fix round 1 finding 1) 예전 판정은 "router_target 이 non-null 인 결정이 1개
    이상"이었는데, 이는 **언제나 참**이다: 라우터가 꺼져 있어도(라우터 자체가 없거나 fail-open
    이어도) route() 는 target 을 base policy 이름으로 채워서 돌려준다(policy.jl:334/338/345/356).
    즉 라우터가 한 번도 구동되지 않은 판(백업 데이터 = 전부 DEMO_ROUTER=0)에서도 이 조건은
    통과해, STEP E 가 밤새 fail-open 인 채로 돌아도 전부 "ok" 로 보고될 수 있었다.

    올바른 판정은 두 단계다(실패 원인을 구분해서 알려준다 -- 무엇을 고칠지가 다르다):
      1) 깃발이 서브프로세스까지 실제로 전달됐는가 -- 요약 행의 최상위 `router` 필드는
         `DEMO_ROUTER` 값을 그대로 기록한다(run_demo.jl:620). 이게 요청한 --router 값과 다르면
         애초에 라우터를 켠 적이 없는 것이다.
      2) 라우터가 실제로 무언가를 골랐는가 -- route() 가 실행을 정할 때(drives=true)만 target 을
         "surrogate"/"dspy" 로 덮어쓴다(policy.jl:349,356). base policy 이름이 그대로 남아 있다는
         것은(요청한 --policies 가 surrogate/dspy 자체가 아닌 한) 라우터가 fail-open 이었거나
         결정마다 매번 advisory 로만 그쳤다는 뜻이다.

    반환: (ok, reason). ok=True 면 reason=None. 판을 못 찾으면 (False, ...).
    """
    if not out_path.exists():
        return False, "no summary file at %s" % out_path
    for r in load_rows(out_path):
        if r.get("case") == case and r.get("ood_seed") == ood_seed and r.get("policy") == policy:
            if r.get("router") != want_router:
                return False, ("flag not passed: summary row's router=%r != requested --router %r"
                               % (r.get("router"), want_router))
            targets = {d.get("router_target") for d in (r.get("decisions") or [])}
            if not (targets & ROUTER_ENGAGED_TARGETS):
                return False, ("gate failed open: no decision's router_target left the base policy "
                               "(saw %r) -- see policy.jl:67 fail-open" % sorted(t for t in targets if t))
            return True, None
    return False, "no row found for (case=%r, ood_seed=%r, policy=%r) in summary" % (case, ood_seed, policy)


def cmd_run(args):
    err = _validate_router_args(args)
    if err:
        # stderr 가 아니라 stdout 으로: 이 파일에서 stdout 만 utf-8 로 reconfigure 돼 있다(위,
        # cp949 콘솔 함정). stderr 에 한글을 쓰면 같은 함정이 그대로 재현된다.
        print("ERROR: %s" % err)
        return 1
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    log_dir = out_path.parent / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    policies = [s.strip() for s in args.policies.split(",") if s.strip()]
    total = len(seeds) * len(policies)
    router_on = args.router != "0"
    print("=== %d runs (%d seeds x %d policies), STRICTLY SEQUENTIAL ===" % (total, len(seeds), len(policies)))
    done = 0
    n_failed = 0
    for seed in seeds:                        # 시드 바깥 / 정책 안쪽 = 같은 스트림을 연달아 비교
        for policy in policies:
            done += 1
            print("[%2d/%2d] seed=%d policy=%-9s ..." % (done, total, seed, policy), end="", flush=True)
            ok, secs, log = run_one(seed, policy, out_path, log_dir, args)
            note = ""
            if ok and router_on:
                r_ok, reason = _router_drove(out_path, args.case, seed, policy, args.router)
                if not r_ok:
                    # 서브프로세스는 성공(returncode 0)했지만 라우터가 실제로 구동됐다는 흔적이
                    # 없다 -- 조용히 "ok" 로 넘기지 않고 이 판을 FAILED 로 뒤집는다(1-b).
                    ok = False
                    note = "  (router check: %s)" % reason
            if not ok:
                n_failed += 1
            print(" %s  %.0f s  -> %s%s" % ("ok" if ok else "FAILED", secs, log.name, note), flush=True)
    print("\nsummaries -> %s" % out_path)
    if n_failed:
        # (2026-08-10 fix round 1 finding 2) 예전에는 개별 판이 FAILED 로 찍혀도 cmd_run 이 항상
        # 0 을 돌려줬다 -- 무인 오케스트레이터는 종료코드만 보므로, 밤새 아무것도 못 재는 채로
        # "성공"처럼 보였다. 하나라도 실패하면 0 이 아닌 코드로 죽는다.
        print("%d/%d runs FAILED" % (n_failed, total))
        return 1
    return 0


# =========================================================================================
#  2. 리포트
# =========================================================================================
def load_rows(path):
    """요약 JSONL. 같은 (case, ood_seed, policy) 는 **마지막 것**만 쓴다(재실행 = 덮어쓰기).

    dedup 키에서 case 를 빼면(STEP C 함정 ①) case 스위프를 기본 --out 으로 돌릴 때 나중에
    쓴 case(예: battery)가 먼저 쓴 case(예: fault)를 에러 없이 지운다.
    """
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
            dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
    return list(dedup.values())


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def _sd(xs):
    xs = [x for x in xs if x is not None]
    return statistics.stdev(xs) if len(xs) > 1 else 0.0


def _risk_coverage(pairs):
    """1-d: selective-prediction risk-coverage. `pairs` = [(router_p, correct), ...] (채점된 결정만).

    router_p 는 route() 의 novelty p-value(policy.jl) -- 클수록 "익숙하다" = 신뢰도가 높다고 본다.
    신뢰도 내림차순으로 정렬해 상위 coverage% 구간만 골라 그 구간의 적중률을 낸다. 100% 는
    "다 받아준다"(= decision_rate 와 같다), 낮은 coverage 일수록 라우터가 자신 있는 결정만
    남긴 부분집합의 적중률 -- 필터링이 실제로 값을 하는지가 여기서 드러난다.
    """
    pairs = [(p, c) for p, c in pairs if p is not None and c is not None]
    pairs.sort(key=lambda pc: -pc[0])
    n = len(pairs)
    out = {}
    for cov in (100, 75, 50, 25):
        k = max(1, round(n * cov / 100)) if n else 0
        subset = pairs[:k]
        nc = len(subset)
        correct_n = sum(1 for _, c in subset if c)
        out[cov] = dict(n=nc, correct=correct_n, rate=(correct_n / nc if nc else None))
    return out


def summarize(rows):
    """정책별 4개 축 + 결정 분포 + escalation/novelty/risk-coverage(1-d) 를 계산한다."""
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
        # 1-d: escalation/novelty/risk-coverage -- router 가 실제로 어떻게 움직였는지 재는 축.
        # score() 는 decisions 와 같은 순서로 rows 를 돌려주므로 zip 으로 원본 결정(escalated,
        # router_novel, router_p)과 채점 결과(correct)를 짝지을 수 있다.
        n_escalated = n_scored_router = 0
        n_novel = n_novel_denom = 0
        risk_pairs = []                          # (router_p, correct) -- 채점된 결정만
        for r in rs:
            decisions = r.get("decisions") or []
            s, c, drows = reference_policy.score(decisions)
            scored += s
            correct += c
            for ev, d in zip(decisions, drows):
                chosen[d["chosen"]] += 1
                if d["correct"] is not None:
                    per_kind[d["truth"]][0] += 1
                    per_kind[d["truth"]][1] += int(d["correct"])
                    # escalation rate 분모 = 채점된 결정 수(브리프 1-d 명시)
                    n_scored_router += 1
                    if ev.get("escalated"):
                        n_escalated += 1
                    p = ev.get("router_p")
                    if p is not None:
                        risk_pairs.append((p, bool(d["correct"])))
                if ev.get("router_novel") is not None:
                    n_novel_denom += 1
                    if ev.get("router_novel"):
                        n_novel += 1
                detail.append(dict(d, ood_seed=r.get("ood_seed"), escalated=ev.get("escalated"),
                                   router_novel=ev.get("router_novel"), router_p=ev.get("router_p")))
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
            # 1-d: escalation / novelty / risk-coverage
            escalation_rate=(n_escalated / n_scored_router if n_scored_router else None),
            n_escalated=n_escalated, n_scored_router=n_scored_router,
            novelty_rate=(n_novel / n_novel_denom if n_novel_denom else None),
            n_novel=n_novel, n_novel_denom=n_novel_denom,
            risk_coverage=_risk_coverage(risk_pairs),
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
    """같은 (case, ood_seed) 에서 두 정책을 맞대어 승/패/무 (완주 우선, 그다음 closed).

    case 를 키에서 빼면(STEP C 함정 ①, load_rows 와 같은 이유) 서로 다른 case 의 판을
    섞어 짝짓게 된다 -- battery seed=1 과 fault seed=1 을 같은 사건처럼 비교하는 꼴.
    """
    idx = {(r.get("case"), r.get("ood_seed"), r.get("policy")): r for r in rows}
    keys = sorted({(r.get("case"), r.get("ood_seed")) for r in rows})
    w = l = t = 0
    for case, s in keys:
        ra, rb = idx.get((case, s, a)), idx.get((case, s, b))
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
    cases = sorted({str(r.get("case")) for r in rows})
    print("=" * 92)
    print("확률적 OOD 스트림 평가 -- %d 판 / ood_seed %s / world_seed 고정" % (len(rows), seeds))
    print("=" * 92)
    # 1-c: 이 파일에 섞인 case 를 사람이 한눈에 잡게 한 줄로 찍는다(dedup 이 case 를 지우지
    # 않는다는 확인이기도 하다 -- 여러 case 가 있는데 1개만 보이면 그게 바로 그 버그다).
    print("case(s) in this file: %s" % ", ".join(cases))
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
        # 1-d: escalation / novelty 발화율 / risk-coverage(신뢰도 상위 구간 적중률).
        esc = ("%.1f%% [%d/%d]" % (100 * d["escalation_rate"], d["n_escalated"], d["n_scored_router"])) \
            if d["escalation_rate"] is not None else "n/a"
        nov = ("%.1f%% [%d/%d]" % (100 * d["novelty_rate"], d["n_novel"], d["n_novel_denom"])) \
            if d["novelty_rate"] is not None else "n/a"
        rc = ", ".join(
            "%d%%=%s" % (cov, ("%.0f%%(%d/%d)" % (100 * v["rate"], v["correct"], v["n"]))
                        if v["rate"] is not None else "n/a")
            for cov, v in sorted(d["risk_coverage"].items(), reverse=True))
        print("      escalation %s | novelty %s | risk-coverage acc@cov: %s" % (esc, nov, rc))
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
        # 1-d: escalation / novelty 발화율 / risk-coverage. 이게 없으면 STEP E 는 숫자를 못 낸다.
        L.append("| 정책 | escalation rate | novelty 발화율 | acc@cov100 | acc@cov75 | acc@cov50 | acc@cov25 |")
        L.append("|---|---|---|---|---|---|---|")
        for pol in order:
            d = res[pol]
            esc = ("%.0f%% (%d/%d)" % (100 * d["escalation_rate"], d["n_escalated"], d["n_scored_router"])) \
                if d["escalation_rate"] is not None else "n/a"
            nov = ("%.0f%% (%d/%d)" % (100 * d["novelty_rate"], d["n_novel"], d["n_novel_denom"])) \
                if d["novelty_rate"] is not None else "n/a"
            covs = []
            for cov in (100, 75, 50, 25):
                v = d["risk_coverage"][cov]
                covs.append(("%.0f%% (%d/%d)" % (100 * v["rate"], v["correct"], v["n"]))
                            if v["rate"] is not None else "n/a")
            L.append("| `%s` | %s | %s | %s | %s | %s | %s |" % (pol, esc, nov, *covs))
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
    r.add_argument("--router", choices=["0", "1", "auto"], default="0",
                   help="DEMO_ROUTER 로 전달. 기본 0 = 정책 고정(기존 동작). 0 이 아니면 "
                        "--novelty-calib 가 필수다(1-a) -- 없으면 policy.jl 이 fail-open 으로 "
                        "라우터를 꺼서 'ON' 이라는 판이 실제로는 OFF 로 측정된다.")
    r.add_argument("--novelty-calib", default="",
                   help="NOVELTY_CALIB 경로. 기본은 빈 문자열(환경변수를 건드리지 않음). "
                        "--router != 0 이면 필수이고, 그 경로에 파일이 있어야 한다.")
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
