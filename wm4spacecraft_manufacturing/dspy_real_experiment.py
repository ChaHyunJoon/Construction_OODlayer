#!/usr/bin/env python
"""
REAL DSPy producer experiment -- uses the actual `dspy` package (3.2.1), not a hand-rolled imitation.

This supersedes the hand-rolled `dspy_experiment.py`, whose docstring claimed dspy could not be
installed because of a numpy/tensorflow conflict. That claim was WRONG: dspy 3.2.1 is installed and
every code path used here (Predict, LabeledFewShot, BootstrapFewShot, BootstrapFewShotWithRandomSearch,
MIPROv2) runs fine on numpy 1.23.5. The only unmet marker is dspy's declared `numpy>=1.26` floor,
which nothing in these paths actually needs.
(실제 dspy 패키지로 다시 돌리는 실험. 예전 스크립트의 "환경 충돌로 설치 불가"는 사실이 아니었다.)

The producer slot under test: OOD event state -> one of 5 recovery macros. Same slot the trained
forest surrogate occupies, so the arms are directly comparable.
(테스트 대상 = "OOD 상태 → 복구 매크로 1개" 자리. surrogate가 앉아 있는 바로 그 자리.)

Arms
  A0 zero-shot     : dspy.Predict, no optimizer                      (LLM prior only)
  A1 LabeledFewShot: dspy.teleprompt.LabeledFewShot                  (oracle labels in-context)
  A2 BootstrapFewShot                                                (demos filtered by the metric)
  A3 BootstrapFewShotWithRandomSearch                                (search over demo sets)
  A4 MIPROv2 (auto="light")                                          (INSTRUCTION + demo joint search)
A4 is the arm the hand-rolled version could not reproduce -- dspy proposes new instruction text,
which is the actual "programming, not prompting" claim.
(A4가 손구현으로는 못 했던 부분: 프롬프트 문장 자체를 LLM이 다시 써서 탐색한다.)

Scoring is IDENTICAL to sweep_surrogate/ladder: cost-aware feasibility-lexicographic decision regret
(lam=3.0), so a number here is comparable to the forest's 0.150 on the same 20 instances.
(채점 함수는 surrogate 스윕과 완전히 동일 -- 그래야 숫자를 나란히 놓을 수 있다.)

Protocol
  A0-A2 : leave-one-out (20 folds) -- matches the earlier hand-rolled run.
  A3-A4 : k-fold (default 4) -- these optimizers compile per fold and 20 compiles is wasteful.
          Reported separately so the protocol difference is never hidden.

Usage:  python dspy_real_experiment.py                 # gpt-4o-mini
        DSPY_MODEL=gpt-4o python dspy_real_experiment.py
        DSPY_FOLDS=4 DSPY_ARMS=A0,A1,A2 python dspy_real_experiment.py   # subset
"""
import os, sys, json, time, warnings

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
warnings.filterwarnings("ignore")

from e1_analyze import load, cost_lex_key, MACRO_COST, MACRO_NAME
import dspy
from dspy.teleprompt import (LabeledFewShot, BootstrapFewShot,
                             BootstrapFewShotWithRandomSearch, MIPROv2)

HERE = os.path.dirname(os.path.abspath(__file__))
LAM = 3.0                                             # 개입 비용 가중치(비싼 매크로는 그만큼 벌어야 이김)
MODEL = os.environ.get("DSPY_MODEL", "gpt-4o-mini")
import wm_datasets
# Pinned to HS_ALL so the recorded arm results (sweep_lab/dspy_real_report_*) stay
# reproducible.  DSPY_DATA / WM_DATASET override.
DATA = wm_datasets.resolve(os.environ.get("DSPY_DATA"), default=wm_datasets.HS_ALL)
FOLDS = int(os.environ.get("DSPY_FOLDS", "4"))        # A3/A4용 k-fold 수
ARMS = os.environ.get("DSPY_ARMS", "A0,A1,A2,A3,A4").split(",")
THREADS = int(os.environ.get("DSPY_THREADS", "8"))
NAME2ID = {v: k for k, v in MACRO_NAME.items()}
VALID = list(NAME2ID)

MACRO_DOC = """You choose ONE recovery macro for an out-of-distribution event during a multi-robot
assembly build. The 5 candidates (a re-specification DSL action):
- NOOP: do nothing / restraint. Best when the disruption is absorbed by slack or spares and
  intervening would waste a scarce resource.
- Replace: swap the affected robot for a spare from the pool. Best on a real fault or a deeply
  depleted battery WHEN spares remain. Costs 1 schedule-unit.
- Deprioritize: lower the affected robot's task priority (mild, cheap=0.3). A middle option.
- ForbidZone: mark a no-go region and reroute the build around it. Best when a spatial zone is
  blocked. Costs 1.
- ReformTeam: re-form the multi-robot assembly team. Costs 1.
Adaptation cost matters: NOOP is free, Deprioritize=0.3, Replace/ForbidZone/ReformTeam=1.0. An
intervention must recover more than it costs, otherwise NOOP (restraint) is the right call."""


# DSPY_NOREASON=1 이면 출력에서 reasoning을 뺀다.
# 왜 필요한가: 오라클 라벨(state -> macro)에는 reasoning이 없다. reasoning이 OutputField로 있으면
# LabeledFewShot의 demo가 "출력 필드가 빠진 불완전 demo"가 되어 어댑터가 약하게 렌더링한다.
# 즉 A1이 손구현보다 나쁘게 나오는 것이 DSPy의 실력이 아니라 시그니처 설계 탓일 수 있어, 그 가설을 분리한다.
NOREASON = os.environ.get("DSPY_NOREASON", "0") == "1"

if NOREASON:
    class PickMacro(dspy.Signature):
        __doc__ = MACRO_DOC
        state: str = dspy.InputField(desc="decision-time state of the OOD event")
        macro: str = dspy.OutputField(desc="exactly one of NOOP|Replace|Deprioritize|ForbidZone|ReformTeam")
else:
    class PickMacro(dspy.Signature):
        __doc__ = MACRO_DOC                           # 시그니처 docstring = 태스크 설명(=기본 instruction)
        state: str = dspy.InputField(desc="decision-time state of the OOD event")
        reasoning: str = dspy.OutputField(desc="one sentence")
        macro: str = dspy.OutputField(desc="exactly one of NOOP|Replace|Deprioritize|ForbidZone|ReformTeam")


def state_line(row):
    """Public decision-time state only -- no oracle/sim outcome leaks in.
    (surrogate가 보는 피처와 같은 정보만 문자열로 렌더링. 정답 누수 없음.)"""
    def g(k, d=None):
        v = row.get(k, d)
        return d if v is None or (isinstance(v, float) and v != v) else v
    kind, soc, ov = g("kind"), g("soc"), g("zone_overlap")
    parts = [f"OOD kind={kind}", f"severity={g('severity')}",
             f"spares_left={int(g('spare_count', 0))}", f"agents_pending={int(g('agent_pending', -1))}",
             f"progress={float(g('progress', 0.0)):.2f}", f"n_active={int(g('n_active', 0))}"]
    if kind == "battery" and soc is not None:
        parts.insert(1, f"SoC={float(soc):.2f}")
    if kind in ("zone", "zoneblk") and ov not in (None, -1.0):
        parts.insert(1, f"zone_overlap={float(ov):.2f}")
    return ", ".join(str(p) for p in parts)


def build_dataset():
    """dump -> (examples, oracle best macro, per-instance macro scores).
    (덤프에서 인스턴스별 5개 매크로 결과를 읽어 정답과 점수표를 만든다.)"""
    df = load(os.path.join(HERE, DATA) if not os.path.isabs(DATA) else DATA)
    df = df[df.fired == True].copy()
    full = [i for i, g in df.groupby("instance") if len(g) == 5]   # 5개 매크로가 모두 있는 인스턴스만
    df = df[df.instance.isin(full)].reset_index(drop=True)

    iids = list(df.instance.unique())
    examples, best, scores = [], {}, {}
    for i in iids:
        g = df[df.instance == i]
        st = state_line(g[g.macro == 0].iloc[0].to_dict())
        scores[i] = {int(m): float(c) - LAM * MACRO_COST[int(m)]
                     for m, c in zip(g.macro.values, g.closed.values)}
        b = max(g.itertuples(index=False),
                key=lambda r: cost_lex_key(r.complete, r.closed, r.makespan, r.macro, LAM))
        best[i] = int(b.macro)
        ex = dspy.Example(state=st, macro=MACRO_NAME[best[i]], iid=i).with_inputs("state")
        examples.append(ex)
    return examples, best, scores


def make_regret(best, scores):
    """regret(instance, macro) in [0,1]; 0 = oracle-optimal choice."""
    def regret(iid, macro_id):
        cbm = scores[iid]
        bc = cbm[best[iid]]
        span = max(bc - min(cbm.values()), 1e-9)
        mid = macro_id if macro_id in cbm else best[iid]
        return (bc - cbm[mid]) / span
    return regret


def main():
    examples, best, scores = build_dataset()
    regret = make_regret(best, scores)
    n = len(examples)

    # dspy metric: 높을수록 좋음(1 - regret). BootstrapFewShot은 threshold로 demo를 거른다.
    def metric(example, pred, trace=None):
        macro = (getattr(pred, "macro", "") or "").strip()
        mid = NAME2ID.get(macro, NAME2ID["NOOP"])      # 어휘 밖 응답은 NOOP으로 강제(손구현과 동일 규칙)
        return 1.0 - regret(example.iid, mid)

    lm = dspy.LM("openai/%s" % MODEL, temperature=0.0, max_tokens=200, cache=True)
    dspy.configure(lm=lm)

    def predict_one(program, ex):
        try:
            pred = program(state=ex.state)
            macro = (getattr(pred, "macro", "") or "").strip()
        except Exception:
            macro = "NOOP"
        return NAME2ID.get(macro, NAME2ID["NOOP"])

    # per_inst[arm][iid] = 그 인스턴스의 regret. 나중에 forest와 paired bootstrap을 하려면
    # 평균이 아니라 인스턴스별 값이 있어야 한다(같은 인스턴스끼리 짝지어 비교).
    per_inst = {}

    per_pick = {}                                      # arm -> {iid: 고른 macro id} (catastrophic 판정용)

    def evaluate(program, held, arm=None):
        regs, tops, picks = [], [], {}
        for e in held:
            mid = predict_one(program, e)
            picks[e.iid] = regret(e.iid, mid)
            if arm is not None:
                per_pick.setdefault(arm, {})[e.iid] = mid
            regs.append(picks[e.iid])
            tops.append(1.0 if mid == best[e.iid] else 0.0)
        return regs, tops, picks

    tag = MODEL.replace(".", "").replace("-", "")
    out = open(os.path.join(HERE, "sweep_lab", "dspy_real_report_%s%s%s.txt" % (tag, os.environ.get("EVAL_TAG", ""), "_noreason" if NOREASON else "")), "w", encoding="utf-8")

    def emit(s=""):
        print(s, flush=True)
        out.write(s + "\n")
        out.flush()

    emit("=" * 92)
    emit("REAL DSPy %s PRODUCER EXPERIMENT (%s, %d instances, lam=%.1f)"
         % (dspy.__version__, MODEL, n, LAM))
    emit("dataset: %s   |   forest baseline: computed by compare_dspy_vs_forest.py on the SAME file" % DATA)
    emit("=" * 92)

    results = {}

    def run_loo(name, compile_fn):
        """leave-one-out: 매 fold마다 나머지 19개로 컴파일하고 1개로 평가."""
        t0 = time.time()
        regs, tops, acc = [], [], {}
        for k, held in enumerate(examples):
            train = [e for e in examples if e.iid != held.iid]
            prog = compile_fn(train)
            r, t, p = evaluate(prog, [held], arm=name)
            regs += r
            tops += t
            acc.update(p)
        per_inst[name] = acc
        res = (sum(regs) / len(regs), sum(tops) / len(tops), time.time() - t0, "LOO(%d)" % n)
        results[name] = res
        emit("  %-34s reg=%.3f  top1=%.2f   [%s, %.0fs]" % (name, res[0], res[1], res[3], res[2]))
        return res

    def run_kfold(name, compile_fn, folds=FOLDS):
        """k-fold: 컴파일 비용이 큰 옵티마이저용(A3/A4). 프로토콜을 리포트에 명시한다."""
        t0 = time.time()
        regs, tops, acc = [], [], {}
        for f in range(folds):
            held = [e for i, e in enumerate(examples) if i % folds == f]
            train = [e for i, e in enumerate(examples) if i % folds != f]
            prog = compile_fn(train)
            r, t, p = evaluate(prog, held, arm=name)
            regs += r
            tops += t
            acc.update(p)
        per_inst[name] = acc
        res = (sum(regs) / len(regs), sum(tops) / len(tops), time.time() - t0, "%d-fold" % folds)
        results[name] = res
        emit("  %-34s reg=%.3f  top1=%.2f   [%s, %.0fs]" % (name, res[0], res[1], res[3], res[2]))
        return res

    emit("\n-- arms --")

    if "A0" in ARMS:
        run_loo("A0 zero-shot (dspy.Predict)", lambda tr: dspy.Predict(PickMacro))

    if "A1" in ARMS:
        run_loo("A1 LabeledFewShot(k=8, random)",
                lambda tr: LabeledFewShot(k=8).compile(dspy.Predict(PickMacro), trainset=tr))

    # A1b = A1과 옵티마이저·모델·k가 전부 같고 "어떤 demo 8개를 고르냐"만 다르다(무작위 vs 앞에서 8개).
    # 이 두 줄의 차이가 곧 demo 선택만으로 생기는 성능 변동폭이다.
    if "A1b" in ARMS:
        run_loo("A1b LabeledFewShot(k=8, first-8)",
                lambda tr: LabeledFewShot(k=8).compile(dspy.Predict(PickMacro), trainset=tr, sample=False))

    if "A2" in ARMS:
        def bfs(tr):
            tp = BootstrapFewShot(metric=metric, metric_threshold=0.999,
                                  max_bootstrapped_demos=4, max_labeled_demos=4, max_rounds=1)
            return tp.compile(dspy.Predict(PickMacro), trainset=tr)
        run_loo("A2 BootstrapFewShot", bfs)

    if "A3" in ARMS:
        def bfsrs(tr):
            tp = BootstrapFewShotWithRandomSearch(
                metric=metric, metric_threshold=0.999, max_bootstrapped_demos=4,
                max_labeled_demos=4, num_candidate_programs=4, num_threads=THREADS)
            return tp.compile(dspy.Predict(PickMacro), trainset=tr, valset=tr)
        run_kfold("A3 BootstrapFewShot+RandomSearch", bfsrs)

    if "A4" in ARMS:
        def mipro(tr):
            tp = MIPROv2(metric=metric, auto="light", num_threads=THREADS, verbose=False)
            return tp.compile(dspy.Predict(PickMacro), trainset=tr,
                              requires_permission_to_run=False)
        run_kfold("A4 MIPROv2 (instruction search)", mipro)

    # ---- summary -------------------------------------------------------------------------------
    emit("\n" + "-" * 92)
    emit("SUMMARY (lower reg = better)")
    emit("  %-34s %8s %8s   %s" % ("producer", "reg", "top1", "protocol"))
    # 하드코딩된 baseline 숫자는 데이터셋이 바뀌면 즉시 거짓말이 된다(n=20 값을 n=44 표에 그대로 찍는 사고).
    # 그래서 여기서는 참조만 하고, 실제 forest 수치는 compare_dspy_vs_forest.py / producer_decision_matrix.py가
    # 같은 데이터셋 위에서 다시 계산해 보고한다.
    emit("  %-34s %8s %8s   %s" % ("forest surrogate (trained)",
                                   "see", "compare", "compare_dspy_vs_forest.py on THIS dataset"))
    for k, v in results.items():
        emit("  %-34s %8.3f %8.2f   %s" % (k, v[0], v[1], v[3]))

    # 실제로 MIPROv2가 새로 써낸 instruction을 남겨야 "프롬프트를 다시 썼다"는 주장을 검증할 수 있다.
    if "A4" in ARMS:
        try:
            tp = MIPROv2(metric=metric, auto="light", num_threads=THREADS, verbose=False)
            prog = tp.compile(dspy.Predict(PickMacro), trainset=examples,
                              requires_permission_to_run=False)
            instr = prog.signature.instructions
            emit("\n-- MIPROv2-optimized instruction (compiled on all %d, for inspection) --" % n)
            emit(instr.strip()[:1500])
            emit("-- demos kept: %d --" % len(getattr(prog, "demos", []) or []))
            json.dump({"model": MODEL, "instructions": instr,
                       "demos": [dict(d) for d in (getattr(prog, "demos", []) or [])]},
                      open(os.path.join(HERE, "sweep_lab", "dspy_real_program_%s.json" % tag), "w"),
                      indent=2, default=str)
        except Exception as e:
            emit("\n(instruction dump failed: %s: %s)" % (type(e).__name__, e))

    # 인스턴스별 regret 덤프 -> compare_dspy_vs_forest.py가 forest와 짝지어 부트스트랩한다.
    json.dump({"model": MODEL, "lam": LAM, "data": DATA, "per_instance_regret": per_inst,
               "per_instance_pick": per_pick},
              open(os.path.join(HERE, "sweep_lab", "dspy_real_perinst_%s%s%s.json"
                                % (tag, os.environ.get("EVAL_TAG", ""), "_noreason" if NOREASON else "")), "w"), indent=1)

    hist = getattr(lm, "history", [])
    tot = sum(h.get("usage", {}).get("total_tokens", 0) or 0 for h in hist)
    emit("\nLM calls this run: %d   tokens: %d   (cache=on, so repeats across folds are free)"
         % (len(hist), tot))
    out.close()


if __name__ == "__main__":
    main()
