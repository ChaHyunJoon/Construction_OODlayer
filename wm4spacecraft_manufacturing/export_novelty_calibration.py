#!/usr/bin/env python
"""
export_novelty_calibration.py -- ship the covariate-novelty detector to the Julia runtime.

WHY THIS EXISTS
===============
`drift_detectors.py` already contains the piece that answers "is this event outside the
surrogate's training distribution?" -- and `compare_detectors.py` already established the
non-obvious finding that the SIGNAL matters more than the detector: value-residual is not a
drift signal, covariate novelty is.

But all of that lives in an offline Python replay of a finished .jsonl. The live decision path
is Julia (`navigator/controller.jl :: decide`), and it has no novelty check at all -- so at
runtime the surrogate is trusted unconditionally, including on classes it has never seen. The
LOKO benchmark (`openworld_experiments.py loko`) shows exactly what that costs.

This script closes that gap by exporting the fitted calibration -- feature means, standard
deviations, and the in-distribution novelty scores -- as a small JSON that Julia loads. The
detector then runs in the live loop with NUMERICALLY IDENTICAL behaviour, which
`ConstructionBots.jl/tools/test_novelty.jl` verifies against the vectors emitted here.

WHAT IS CALIBRATED ON
=====================
The KIND-AGNOSTIC state descriptors (`features_agnostic.STATE_DESCRIPTORS`), not the legacy
feature vector. This matters: calibrating on the legacy vector would make every novel class
"novel" for the trivial reason that its `kind_*` one-hot is all zeros and its sentinels are
unprecedented -- a detector that fires on a naming artefact rather than on physics. Calibrated
on physical descriptors, a novel class that is physically SIMILAR to a known one correctly
reads as in-distribution (and the surrogate can be trusted), while one that is physically
unlike anything seen correctly reads as novel (and we escalate to the oracle). That distinction
is the whole point.

THE GATE IT FEEDS
=================
    novelty p-value < eps   ->  do NOT trust the surrogate; verify candidates with the true
                                planner (the oracle fallback whose necessity LOKO quantifies)
    otherwise               ->  trust the surrogate's ranking (0.1 ms instead of ~60 s)

--------------------------------------------------------------------------------------------
[한국어 설명]
이 스크립트가 하는 일: "이 사건이 surrogate 학습분포 밖인가?"를 판정하는 감지기의 교정값
  (평균/표준편차/정상범위 점수들)을 JSON 으로 내보내 Julia 런타임이 그대로 쓰게 한다.

왜 필요한가: 이 감지기는 이미 drift_detectors.py 에 구현·비교검증까지 끝나 있지만, 오프라인
  jsonl 재생에서만 돈다. 실제 결정 경로(Julia controller.jl 의 decide)에는 novelty 검사가 아예
  없어서, 처음 보는 종류에도 surrogate 를 무조건 믿는다. LOKO 실험이 그 대가를 보여준다.

무엇을 기준으로 교정하나: **kind-agnostic 물리 서술자**로 한다. 기존(legacy) 특징으로 교정하면
  새 종류는 "one-hot 이 전부 0"이라는 이름표 이유만으로 항상 novel 로 뜬다 = 물리가 아니라
  명명 규칙에 반응하는 감지기. 물리 서술자로 교정해야 "물리적으로 비슷한 새 종류는 믿고,
  정말 낯선 것만 오라클로 넘긴다"는 구분이 성립한다.

[문법 참고]
  - json.dump(obj, fh, indent=2) : 파이썬 객체를 JSON 파일로 저장.
  - arr.tolist()                 : numpy 배열 -> 파이썬 리스트(JSON 직렬화 가능하게).
--------------------------------------------------------------------------------------------

Usage:
    python export_novelty_calibration.py oracle/out/graded_hs_all.jsonl \
        [--out=novelty_calibration.json] [--alpha=0.05] [--cap=8.0] [--probes=32]
"""
import hashlib
import json
import os
import sys

import numpy as np

import wm_datasets                      # 데이터셋 경로 단일 정의
from e1_analyze import load
from features_agnostic import STATE_DESCRIPTORS, descriptors_from_row

# ==========================================================================================
#  버전/지문 — 낡은 교정파일이 조용히 쓰이는 것을 막는 장치
# ==========================================================================================
# 교정파일은 "이 데이터 분포에서 정상이란 이게 정상이다"를 굳혀 놓은 것이다. 그래서 서술자의
# 정의가 바뀌거나 데이터셋이 바뀌면 그 파일은 **틀린 게 아니라 무의미**해진다. 그런데 로더가
# 아무 검사도 안 하면 그냥 로드되어 계속 답을 낸다 -- 에러 없이 잘못된 p-value 가 나온다.
# 그래서 (1) 포맷 버전, (2) 서술자 계약 지문, (3) 원본 데이터셋 지문을 파일에 박아 두고,
# Julia 로더(src/safety/novelty.jl)가 불일치를 발견하면 **크게 실패**하게 한다.
#
# FORMAT_VERSION 을 올려야 할 때: blob 의 키 구성이 바뀔 때.
# DESCRIPTOR 지문은 STATE_DESCRIPTORS 에서 자동 계산되므로, 서술자를 고치면 저절로 바뀐다.
FORMAT_VERSION = 2


def _sha16(data: bytes) -> str:
    """sha256 앞 16자리. 짧지만 우연한 충돌 확률은 사실상 0이고 로그에 넣기 좋다."""
    return hashlib.sha256(data).hexdigest()[:16]


def descriptor_fingerprint():
    """서술자 '계약'의 지문 = 이름과 순서. 순서가 바뀌면 mu/sd 가 다른 축에 붙으므로 반드시 포함."""
    return _sha16("|".join(STATE_DESCRIPTORS).encode("utf-8"))


def dataset_fingerprint(path):
    """원본 데이터셋 파일 내용의 지문 + 줄 수. 데이터셋을 다시 만들면 값이 바뀐다."""
    try:
        with open(path, "rb") as fh:
            blob = fh.read()
        return {"sha16": _sha16(blob),
                "bytes": len(blob),
                "lines": blob.count(b"\n") + (0 if blob.endswith(b"\n") or not blob else 1)}
    except OSError as e:
        return {"sha16": "unreadable", "bytes": -1, "lines": -1, "error": str(e)}


def instance_descriptor_matrix(df):
    """instance 당 한 행. 서술자는 (상태, macro) 가 아니라 **상태**의 성질이므로 macro 축으로 중복
    계산하면 안 된다 -- 같은 상태가 5번 들어가면 분산이 인위적으로 줄어 교정이 왜곡된다."""
    rows, keys = [], []
    for inst, g in df.groupby("instance"):
        d = descriptors_from_row(g.iloc[0])
        rows.append([d[k] for k in STATE_DESCRIPTORS])
        keys.append(str(inst))
    return np.asarray(rows, dtype=float), keys


def fit_calibration(X, cap=8.0):
    """평균/표준편차와 in-distribution novelty 점수 집합을 만든다(make_novelty 와 동일한 식)."""
    mu = X.mean(axis=0)
    sd = X.std(axis=0) + 1e-9          # 0 분산 방어 (make_novelty 와 동일한 상수)
    z = np.clip((X - mu) / sd, -cap, cap)
    scores = np.sqrt(np.mean(z * z, axis=1))
    return mu, sd, scores


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    # DEFAULT CHANGED 2026-07-30: graded_hs_all -> CANONICAL (openworld_merged).
    # The old default disagreed with reality: BOTH shipped calibrations record
    # meta.source = "oracle/out/openworld_merged.jsonl", because every documented
    # invocation passed that file explicitly.  A default that produces a band fitted
    # to a different distribution than the deployed one is a trap, so it now matches.
    path = wm_datasets.resolve(args[0] if args else None)
    out = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--out=")),
               "novelty_calibration.json")
    alpha = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--alpha=")), 0.05)
    cap = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--cap=")), 8.0)
    nprobe = next((int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--probes=")), 32)

    # --exclude=zoneblk : 그 종류를 교정에서 **빼고** 맞춘다 = "아직 본 적 없는 종류"를 만드는 스위치.
    #
    # 왜 필요한가: 기본 교정은 세 종류 전부로 맞춰져 있어서 데모의 어떤 사건도 낯설지 않다. 그러면
    # 라우터는 항상 "익숙함 → surrogate"만 내고 LLM 은 한 번도 안 불린다 -- 배선은 됐는데 화면에
    # 아무 일도 안 일어난다(실제로 tools/test_router.jl 의 T7 이 이걸 잡아냈다).
    # 라우팅을 보이려면 교정이 그 종류를 몰라야 한다 = LOKO 와 같은 설정.
    excl = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--exclude=")), "")
    exclude = {k.strip() for k in excl.split(",") if k.strip()}

    df = load(path)
    df = df[df.fired == True].copy()
    if exclude:
        before = sorted(df.kind.astype(str).unique())
        df = df[~df.kind.astype(str).isin(exclude)].copy()
        if df.empty:
            print(f"[error] --exclude={excl} 로 남는 데이터가 없습니다 (원래 종류: {before})")
            sys.exit(1)
        print(f"[calib] excluded kinds={sorted(exclude)} -> 교정은 "
              f"{sorted(df.kind.astype(str).unique())} 만으로 맞춥니다 "
              f"(제외된 종류는 이제 '처음 보는 사건'이 됩니다)")
    X, keys = instance_descriptor_matrix(df)
    mu, sd, scores = fit_calibration(X, cap=cap)

    # ---- parity probes: Julia 가 같은 입력에 같은 값을 내는지 검증할 (입력, 기대출력) 쌍 --------
    # 교정 데이터 자체 + 인위적으로 밀어낸 점들(=novel 이어야 하는 것들)을 섞는다.
    rng = np.random.default_rng(0)
    probes = []
    for i in range(min(nprobe // 2, len(X))):
        probes.append(X[i].tolist())
    for _ in range(nprobe - len(probes)):
        # [0,1] 범위 밖까지 밀어 극단/이상치도 포함시킨다(클리핑 경로까지 검사).
        probes.append((mu + sd * rng.normal(0, 4, size=len(mu))).tolist())

    def novelty(x):
        z = np.clip((np.asarray(x, dtype=float) - mu) / sd, -cap, cap)
        return float(np.sqrt(np.mean(z * z)))

    def pvalue(s, p_floor=1e-4):
        cal = list(scores)
        n = len(cal)
        gt = sum(1 for r in cal if r > s)
        eq = sum(1 for r in cal if r == s)
        return min(max((gt + 0.5 * (eq + 1)) / (n + 1), p_floor), 1.0)

    probe_out = [{"x": p, "score": novelty(p), "p": pvalue(novelty(p))} for p in probes]

    blob = {
        # 로더가 검사하는 세 개. 위쪽 주석 참조 -- 불일치하면 Julia 쪽이 에러를 던진다.
        "format_version": FORMAT_VERSION,
        "descriptor_fingerprint": descriptor_fingerprint(),
        "dataset_fingerprint": dataset_fingerprint(path),
        "meta": {
            "source": os.path.relpath(path, os.path.dirname(os.path.abspath(__file__))
                                      ).replace("\\", "/"),
            "source_abs": path,
            "n_instances": int(len(X)),
            "kinds": sorted(df.kind.astype(str).unique().tolist()),
            "excluded_kinds": sorted(exclude),      # 이 종류들은 라우터에게 '처음 보는 사건'이다
            "generator": "export_novelty_calibration.py",
            "note": "calibrated on KIND-AGNOSTIC state descriptors; see export_novelty_calibration.py",
        },
        "feature_names": STATE_DESCRIPTORS,
        "cap": cap,
        "alpha": alpha,
        "p_floor": 1e-4,
        "mu": mu.tolist(),
        "sd": sd.tolist(),
        "cal_scores": sorted(float(s) for s in scores),
        "probes": probe_out,
    }
    with open(out, "w") as fh:
        json.dump(blob, fh, indent=2)

    print(f"[export] {out}")
    print(f"  format_version={FORMAT_VERSION}  descriptor_fp={blob['descriptor_fingerprint']}  "
          f"dataset_fp={blob['dataset_fingerprint']['sha16']} "
          f"({blob['dataset_fingerprint']['lines']} lines)")
    print(f"  calibrated on {len(X)} instances from {path}")
    print(f"  features: {STATE_DESCRIPTORS}")
    print(f"  novelty score in-distribution: min={scores.min():.3f} "
          f"median={np.median(scores):.3f} max={scores.max():.3f}")
    print(f"  {len(probe_out)} parity probes written (Julia must reproduce score+p to 1e-9)")
    # 감지기가 실제로 분별력이 있는지 즉석 확인: 교정점의 p 는 크고, 밀어낸 점의 p 는 작아야 한다.
    p_in = np.mean([q["p"] for q in probe_out[:len(X) // 2 or 1]])
    p_out = np.mean([q["p"] for q in probe_out[len(X) // 2 or 1:]])
    print(f"  mean p on calibration-like probes = {p_in:.3f};  on shifted probes = {p_out:.3f}")
    if p_out >= p_in:
        print("  WARNING: shifted probes are not scoring as more novel -- calibration may be degenerate")


if __name__ == "__main__":
    main()
