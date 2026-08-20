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
# ※ 이 파일이 이름으로 인용하는 아래 md 문서는 2026-08-18 md 통합에서 내려갔다 —
#    (RESULTS.md · COST_EVAL_RESULTS.md · RESULTS_LLM7H.md ·
#    RESULTS_DP_BACKWARD_2026-08-15.md)
#    복구 SHA 는 `md/README.md` §9-A.
import os

# 2026-08-18 폴더 분류: 이 파일이 core/ 로 내려갔다. 아래 데이터셋 경로는 전부
# `oracle/out/...` 처럼 **wm4 폴더 기준 상대경로**라 기준점은 계속 wm4 폴더여야 한다
# (core/ 로 잡으면 `core/oracle/out/...` 을 찾아 전부 MISSING 이 된다).
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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
#
# ★ 세대 주의 (2026-08-09).  이 파일의 라벨은 매크로 [0,1,2,3,4] 시절 것이다 — 7(RelocateBuild)
#   도 8(SwapBattery) 도 없다.  그래서 "canonical 에서 잰 surrogate 결과"는 **행동집합이 잘린
#   상태의 측정치**이고, 배포 surrogate(N44_PLUS78)의 성능과 같은 축에서 비교하면 안 된다.
#   그런데도 지우지 않고 남긴 단 하나의 이유: 배포된 novelty 교정(novelty_calibration*.json)이
#   이 분포 위에서 적합됐고, tools/monitor/README.md(2026-08-08)가 교정 재생성 절차에서
#   이 경로를 그대로 부른다.  즉 **교정용 입력**으로만 살아 있다. 성능 수치의 근거로 쓰지 말 것.
CANONICAL = "oracle/out/openworld_merged.jsonl"

# ==========================================================================================
#  N44_PLUS8 — 배포 surrogate 의 학습셋 (2026-08-06)
# ==========================================================================================
# graded_hs_n44(44 instance, 매크로 [0,1,2,3,4]) + battgrid_0805_s1(18 instance, [0,1,2,8]).
# 왜 합치나: 배포 surrogate 는 8(SwapBattery) 행을 한 줄도 본 적이 없어서 그 팔을 후보에서
# 탈락시켰고, 그 결과 battery 사건에서 언제나 규칙과 같은 Replace 를 냈다(RESULTS_LLM7H §5-f,
# battery 적중 0/6). 어휘가 아니라 **학습 근거**가 없던 것이라 action_registry 를 고쳐도 안 낫는다.
# instance id 충돌은 없음을 merge_labels.py 가 에러로 강제한다.
N44_PLUS8 = "oracle/out/n44_plus8.jsonl"

# ==========================================================================================
#  N44_PLUS78 — N44_PLUS8 + fzgrid_0806 (매크로 7 = RelocateBuild, 2026-08-06)
# ==========================================================================================
# 이 파일이 배포 surrogate 의 학습셋이 되면서 zone 사건에서 점수 낼 수 있는 팔이 처음으로
# 둘이 된다. 그 전까지 zone 메뉴는 [NOOP, RelocateBuild] 인데 지원이 {NOOP} 뿐이라
# surrogate 는 **언제나** NOOP 이었다(RESULTS_LLM7H §5-f 표).
N44_PLUS78 = "oracle/out/n44_plus78.jsonl"

# ==========================================================================================
#  RELABEL_20260814 — 정렬된 물리에서 처음부터 다시 만든 라벨셋 (Task 4, spec §5)
# ==========================================================================================
# 365행 / 165 instance (fault 60 · battery 45 · zoneblk 60).  N44_PLUS78 을 **이어붙이지 않고**
# 새로 생성했다: 그 파일은 매크로 8 이 어휘에 들어오기 전후 두 세대를 concat 한 것이라
# battery 43개 중 18개만 SwapBattery 팔을 가졌다.  여기서는 45/45 = 100% 다.
#
# N44_PLUS78 과 **같은 축에서 비교할 수 없다**.  네 가지가 동시에 다르다:
#   (1) 물리 — 배터리 용량이 배포 레인과 같은 스펙값(shrink 없음), hot-swap ON
#   (2) 목적함수 — 모든 행이 유한한 energy_J 를 갖고 objective.J_row 로 채점된다
#   (3) 팔 메뉴 — DS_VALID_ONLY=1 이라 각 instance 의 valid_mask 전수, 그 밖은 없음
#   (4) 격자 — instance id 가 겹치는 것은 165개 중 9개뿐이다(짝지은 비교가 아니다)
# 그래서 "옛 라벨 대비 뒤집혔다" 식의 주장은 이 파일로 할 수 없다.  자세한 것은
# .superpowers/sdd/2026-08-13-surrogate-rebuild/task-4-report.md.
#
# 알려진 한계(소비 전에 반드시 읽을 것):
#   · 매크로 지원 집합이 {0,1,2,7,8} 이다 — 4(ReformTeam)·3(ForbidZone) 행이 **없다**.
#     4 를 지원에서 잃으면 배포 서비스가 후보에서 걸러 ReformTruth 결정(전체 sweep 511건)에
#     NOOP 밖에 못 낸다.  능력 회귀다.
#   · valid_mask 가 없는 행 10개는 사건이 발화하지 않은 stub 이다.  라벨이 아니므로
#     소비처에서 반드시 걸러야 한다(`"valid_mask" not in row` 또는 arms_labeled == 1).
RELABEL_20260814 = "oracle/out/relabel_2026-08-14.jsonl"

# ==========================================================================================
#  RELABEL_20260816 — 행동집합을 닫은 라벨셋 (2026-08-16 계획 Task 1)
# ==========================================================================================
# RELABEL_20260814 의 **알려진 능력 회귀를 고친 판**이다.  격자는 그대로 복원했고
# (seeds 1..5 · spares {0,3} · fire {58,140,220} · bsoc {0.02,0.3,0.5} · zfrac {0.5,0.9,1.3}),
# 두 가지만 더했다:
#
#   (1) `reform` kind 가 들어왔다 — 165 -> 195 instance.  팀 교착은 심을 수 있는 사건이
#       아니라 스페어 인계의 2차 실패라, 선행 fault 를 심고 엔진이 스스로 올리는 알람
#       (`maybe_emit_reform_ood!`)을 연구 대상으로 잡는다.  `run_demo.jl:739` 와 같은 NL,
#       `DS_REFORM=120` 으로 같은 감지 간격 = 라벨 격자와 실행 레인이 같은 세계를 잰다.
#   (2) kind 마다 레지스트리가 legal 이라고 말하는 팔을 **전부** 굴린다.  `ood_mdp_shim`
#       의 `valid_actions` 가 이제 `action_registry.json` 파생이라 DS_VALID_ONLY=1 이
#       자동으로 그 집합을 고른다.  DS_COMBO_ARMS=1 · DS_BATTERY_SOC_SPLIT=0 으로 생성했다:
#         fault/faultidle -> {0,1,2,4,5,6} · battery -> {0,1,2,8}
#         zoneblk/zoneharm -> {0,3,7} 중 그 시점에 행동 가능한 것 · reform -> {0,4}
#
# 즉 RELABEL_20260814 의 support {0,1,2,7,8} 에서 빠져 있던 **3(ForbidZone)·4(ReformTeam)**
# 이 여기서는 라벨 대상이다.  그 부재가 2026-08-15 판에서 Reform 축 gap 을 13/13 = 100% 로
# 만든 원인이었다(RESULTS_DP_BACKWARD_2026-08-15.md §4-D).
#
# RELABEL_20260814 와 **짝지은 비교를 하지 말 것**: 팔 메뉴가 달라 instance 당 행 수가
# 다르고, shim 의 valid_actions 가 바뀌었으므로 fault 축은 다른 세계에서 측정됐다.
# (옛 동작 재현이 필요하면 DS_ARMS_LEGACY=1.)
RELABEL_20260816 = "oracle/out/relabel_2026-08-16.jsonl"

# ==========================================================================================
#  RELABEL_20260819 — 6팔 어휘(spec §2)로 필터링한 legacy 라벨. 872 → 742행 / 260 instance.
# ==========================================================================================
# ⚠️ 이것은 **회귀 비교용 legacy** 다. V̂ 학습셋이 아니다 — 그 자리는 §4.1 의 K-rollout
# 라벨이 가져간다(단계 B). 여기에 공을 들이지 말 것.
#
# `filter_labels.filter_rows()` 가 RELABEL_20260816 에서 구 macro 5(65행)·6(65행)을
# **필터만** 해서(remap 없음) 만든 파생 파일이다. 구 macro 3(ForbidZone)은 원래 0행이라
# 손실이 없다. macro 정수 컬럼은 손대지 않는다 — 살아남은 id 는 여전히 비연속
# `{0,1,2,4,7,8}` 이고 3/5/6 은 영구 결번이다(옛 파일이 그 id 를 조회하면 실패해야
# 옳다; spec §2.4).
#
# ⚠️ **instance 수는 98 이 아니라 260 이다**(브리프/spec 의 "98" 은 틀린 문자열 — 필터
# 전후 동일하게 실측 260). ⚠️ **이 파일이 만들어진 시점(2026-08-19)에 태스크 5(3/5/6 을
# action_registry 에서 공식 은퇴시키고 도장을 "v2-6arms" 로 올리는 일)는 아직 미착수였다**
# (controller progress.md: "Task 5 deliberately NOT started yet"). 그래서 이 파일의
# `vocab` 필드는 그 시점의 참값인 `"v1-9arms"` 로 찍혀 있다 — 태스크 5가 착지한 뒤에도
# 이 값은 재생성 전까지 그대로 남는다. 소비할 때는 실제 필드값을 읽을 것, 여기 적힌
# 문자열을 리터럴로 믿지 말 것.
RELABEL_20260819 = "oracle/out/relabel_2026-08-19.jsonl"

# ==========================================================================================
#  FIREGRID — CANONICAL + 발화 시점을 흩뿌린 인스턴스들 (2026-08-04)
# ==========================================================================================
# 왜 별도 파일인가.  CANONICAL 의 60 instance 는 `closed_at_fire` 가 {50,58} 두 값뿐이라
# `progress` 의 sd 가 0.005 다(= 사실상 점 하나).  그 위에 맞춘 novelty 교정은 중반에 터지는
# 사건을 **종류와 무관하게** novel 로 판정한다 -- 배포 데모의 battery(progress 0.41)와 후반
# fault(0.66)가 실제로 그렇게 뒤집혔다.  FIREGRID 는 DS_FIRE_GRID 로 발화 시점을 instance
# 차원으로 올려 progress 를 0.19~0.83 에 흩뿌린 행들을 CANONICAL 에 **덧붙인** 파일이다.
#
# CANONICAL 을 덮어쓰지 않는 이유: 발표된 숫자(regret/frontier)는 전부 그 분포에서 측정됐다.
# 교정만 새 분포로 옮기고, 기존 결과는 기존 파일 위에서 그대로 재현되게 둔다.
#
# [삭제됨 2026-08-09] 아래 legacy pin 주석 참조 — 매크로 7·8 이전 세대라 파일을 지웠다.
FIREGRID = "oracle/out/firegrid_merged.jsonl"

# ==========================================================================================
#  Legacy pins — 2026-08-09 에 파일을 **삭제**했다.  이름만 남긴다.
# ==========================================================================================
# 여기 있던 덤프는 전부 매크로 7(RelocateBuild)·8(SwapBattery) 가 어휘에 들어오기 전
# (action_registry.json, 2026-08-06) 에 측정된 것이라, 지금 코드로 다시 읽으면 잘린 행동집합
# 위에서 잰 숫자가 현재 결과처럼 보인다.  그 혼동이 실제로 일어났기 때문에 파일을 지웠다.
#
# 상수를 지우지 않고 남기는 이유: 지우면 import 시점에 AttributeError 가 나서 "왜 없는지"가
# 사라진다.  이대로 두면 resolve() 가 실제 경로를 돌려주고 open() 이 FileNotFoundError 로
# 죽으므로, 스택트레이스에 삭제된 파일 이름이 그대로 찍힌다.  describe() 는 MISSING 을 낸다.
# 다시 필요하면 gen_oracle_dataset.jl 로 **현재 어휘에서** 새로 만들 것 — 복원하지 말 것.
HS_ALL = "oracle/out/graded_hs_all.jsonl"    # [삭제됨] 20 instances; cost_eval / dspy experiment baselines
HS_N44 = "oracle/out/graded_hs_n44.jsonl"    # 44 instances; the PREVIOUS dspy_service surrogate set
                                              # (superseded 2026-08-06 by N44_PLUS78, dspy_service.py:165 --
                                              # N44_PLUS8 의 출처라서 남겨 둔 것이지 결과용이 아니다)
HS_V2  = "oracle/out/graded_hs_v2.jsonl"     # [삭제됨] cost artifact + e1_frontier figures

#: Every dataset this module knows about, for `--list` style diagnostics.
KNOWN = {
    "canonical": CANONICAL,
    "firegrid": FIREGRID,
    "hs_all": HS_ALL,
    "hs_n44": HS_N44,
    "hs_v2": HS_V2,
    "n44_plus8": N44_PLUS8,
    "n44_plus78": N44_PLUS78,
    "relabel_20260814": RELABEL_20260814,
    "relabel_20260816": RELABEL_20260816,
    "relabel_20260819": RELABEL_20260819,
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
