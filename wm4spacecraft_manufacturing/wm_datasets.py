"""wm_datasets.py -- THE single place that names oracle label datasets.

NAMED `wm_datasets`, NOT `datasets`, ON PURPOSE
-----------------------------------------------
A module called `datasets.py` in this directory SHADOWS the HuggingFace `datasets`
package for every script run from here, because a script's own directory is sys.path[0].
That matters: dspy_real_experiment.py imports dspy, and the dspy/litellm stack may import
HuggingFace `datasets`.  Verified 2026-07-30 -- `import datasets` from this directory
resolved to this file.  Keep the `wm_` prefix.
(이름에 wm_ 을 붙인 이유: `datasets` 로 두면 HuggingFace 의 datasets 패키지를 가린다.
 실제로 확인했다 -- dspy 를 함께 쓰는 스크립트가 깨질 수 있다.)

WHY THIS FILE EXISTS
--------------------
Before 2026-07-30 the dataset path was a bare string literal inside each script, and the
literals had drifted into four different defaults:

    graded_hs_all.jsonl    cost_eval, dspy_experiment, dspy_real_experiment,
                           compare_dspy_vs_forest, export_novelty_calibration
    graded_hs_n44.jsonl    dspy_service (the DEPLOYED producer)
    graded_hs_v2.jsonl     build_artifact, e1_frontier
    openworld_merged.jsonl assimilation_stream, c1_novel_kind, descriptor_ablation

That is a silent-wrong-answer generator: calibrate a conformal band on one file, score with
another, and you get numbers that are meaningless without raising a single error.  The
classifier work needs one declared dataset, so the paths live here now.

WHAT THIS FILE DOES *NOT* DO
----------------------------
It does NOT retarget the legacy scripts onto CANONICAL.  Each published result was measured
on a specific file; repointing them would silently invalidate the numbers in RESULTS.md,
COST_EVAL_RESULTS.md and the artifact HTMLs.  So legacy scripts keep their dataset -- they
just name it from here instead of hard-coding a literal.  New code uses CANONICAL.

Override everything at once with the WM_DATASET environment variable, e.g.

    WM_DATASET=oracle/out/openworld_n30.jsonl python calibrate.py

────────────────────────────────────────────────────────────────────────────
[한국어 설명]
데이터셋 경로를 "여기 한 곳"에서만 정의한다.

문제였던 것: 스크립트마다 기본 데이터셋이 제각각(4갈래)이었다. 한 파일로 conformal 밴드를
교정하고 다른 파일로 채점해도 **에러 없이 그냥 틀린 숫자**가 나온다. 그래서 경로를 모았다.

단, 레거시 스크립트가 읽는 파일 자체는 바꾸지 않는다. 각 발표 숫자는 특정 파일에서 나온
것이라, 지금 갈아끼우면 기존 결과가 조용히 무효가 된다. 경로만 여기서 이름으로 가져다 쓴다.
새로 쓰는 코드는 CANONICAL 을 쓴다.

문법 참고:
  · os.path.isabs(p)  — 절대경로인지 검사. 상대경로면 이 파일이 있는 폴더 기준으로 붙인다
    (그래야 어느 작업디렉터리에서 실행해도 같은 파일을 가리킨다).
  · os.environ.get(K, D) — 환경변수 K 가 있으면 그 값, 없으면 D.
────────────────────────────────────────────────────────────────────────────
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# ==========================================================================================
#  CANONICAL — new code uses this
# ==========================================================================================
# openworld_merged.jsonl: 300 rows / 60 instances / seeds 1-6 / kinds {battery, fault, zoneblk}.
#
# This is the file the DEPLOYED novelty gate was calibrated on -- verified 2026-07-30 by
# reading meta.source out of both novelty_calibration.json and
# novelty_calibration_no_zoneblk.json.  Anything that has to agree with the installed
# conformal band MUST use this file, or the band is being applied to a different distribution
# than it was fitted on.
CANONICAL = "oracle/out/openworld_merged.jsonl"

# ==========================================================================================
#  Legacy pins — kept so published numbers stay reproducible.  Do not "upgrade" these.
# ==========================================================================================
HS_ALL = "oracle/out/graded_hs_all.jsonl"    # 20 instances; cost_eval / dspy experiment baselines
HS_N44 = "oracle/out/graded_hs_n44.jsonl"    # 44 instances; the deployed dspy_service surrogate set
HS_V2  = "oracle/out/graded_hs_v2.jsonl"     # cost artifact + e1_frontier figures

#: Every dataset this module knows about, for `--list` style diagnostics.
KNOWN = {
    "canonical": CANONICAL,
    "hs_all": HS_ALL,
    "hs_n44": HS_N44,
    "hs_v2": HS_V2,
}


def abspath(path):
    """Anchor a dataset path at this directory unless it is already absolute.

    Scripts get run from several working directories (repo root, wm4.../, oracle/).  Bare
    relative literals silently resolved against the wrong cwd; anchoring removes that.
    (스크립트를 어디서 실행하든 같은 파일을 가리키게 만든다.)
    """
    return path if os.path.isabs(path) else os.path.join(HERE, path)


def resolve(explicit=None, default=CANONICAL):
    """Return the dataset to use, in precedence order.

        1. `explicit`        -- an argv path the caller was given (highest priority)
        2. $WM_DATASET       -- session-wide override, so one run can pin every script
        3. `default`         -- CANONICAL for new code; a legacy pin for old scripts

    The result is always absolute.
    (우선순위: 인자 > 환경변수 WM_DATASET > 기본값. 항상 절대경로로 돌려준다.)
    """
    chosen = explicit or os.environ.get("WM_DATASET") or default
    return abspath(chosen)


def describe(path):
    """One-line provenance string for logging, so every report says which file it read."""
    p = abspath(path)
    tag = next((k for k, v in KNOWN.items() if abspath(v) == p), "custom")
    exists = "ok" if os.path.exists(p) else "MISSING"
    return "dataset[%s] %s (%s)" % (tag, os.path.relpath(p, HERE).replace("\\", "/"), exists)


if __name__ == "__main__":
    print("HERE =", HERE)
    for name, rel in KNOWN.items():
        print("  %-10s %s" % (name, describe(rel)))
    print("\nresolve() ->", resolve())
