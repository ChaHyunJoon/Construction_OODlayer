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
    python novelty/export_novelty_calibration.py oracle/out/graded_hs_all.jsonl \
        [--out=novelty/novelty_calibration.json] [--alpha=0.05] [--cap=8.0] [--probes=32]
"""
import hashlib
import json
import os
import sys

import numpy as np

# 2026-08-18 폴더 분류: oracle_datasets·e1_analyze·features_agnostic 은 이제 core/ 에 있다.
# 코드 폴더 전부를 sys.path 에 올려 맨이름 import 를 유지한다(근거는 core/simulator_paths.py 머리말).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
import simulator_paths                            # noqa: E402,F401

import oracle_datasets                      # 데이터셋 경로 단일 정의
from e1_analyze import load
from features_agnostic import STATE_DESCRIPTORS, descriptors_from_row

# 축별 sd 판정선. 서술자는 전부 [0,1] 범위이므로, sd 가 이 아래면 그 축이 게이트를 삼킨다
# (cap 에 잘리는 순간 혼자 score 를 지배 — main() 의 DEGENERATE-AXIS GATE 참고).
DEGENERATE_SD = 0.02

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


def fit_calibration(X, cap=8.0, sd_floor=0.0):
    """평균/표준편차와 in-distribution novelty 점수 집합을 만든다(make_novelty 와 동일한 식).

    `sd_floor` (opt-in, 기본 0 = 예전과 동일): 축별 sd 의 **하한**. 서술자는 모두 [0,1] 범위인데
    수집 설계 때문에 한 축이 사실상 상수가 되면(2026-08-04 의 `progress` sd=0.005) 그 축 하나가
    score 를 지배해 종류와 무관하게 novel 이 나온다. 하한을 주면 그 실패 방식이 **점수 단계에서**
    막힌다. 다만 이건 보험이지 해결책이 아니다 — 진짜 해결은 그 축을 실제로 표집하는 것이고
    (LABELING_MANUAL §6~§7), 하한은 남은 degenerate 축이 게이트를 삼키는 것을 막을 뿐이다.
    그래서 기본값은 0 이고, 켰을 때는 어느 축이 몇에서 몇으로 올라갔는지 반드시 찍는다.
    """
    mu = X.mean(axis=0)
    sd = X.std(axis=0) + 1e-9          # 0 분산 방어 (make_novelty 와 동일한 상수)
    if sd_floor > 0:
        raised = [(STATE_DESCRIPTORS[i], float(sd[i])) for i in range(len(sd)) if sd[i] < sd_floor]
        sd = np.maximum(sd, sd_floor)
        for name, old in raised:
            print(f"  [sd-floor] {name}: sd {old:.5f} -> {sd_floor:.5f} (하한 적용)")
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
    path = oracle_datasets.resolve(args[0] if args else None)
    # 기본 출력은 **이 스크립트 폴더**(novelty/)에 고정한다. 2026-08-18 폴더 분류 전에는
    # cwd 기준 상대이름이라 어디서 돌리느냐에 따라 다른 곳에 떨어졌다 — 설치된 교정파일과
    # 갈린 사본이 조용히 생기는 자리였다. 소비처(tools/test_novelty.jl · test_router.jl ·
    # tools/monitor/regen_router_cases.sh)가 보는 경로도 novelty/ 다.
    out = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--out=")),
               os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "novelty_calibration.json"))
    alpha = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--alpha=")), 0.05)
    cap = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--cap=")), 8.0)
    nprobe = next((int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--probes=")), 32)
    # --sd-floor=0.02 : 축별 sd 하한(기본 0 = 끔). 아래 [axis audit] 이 DEGENERATE 로 표시하는 축이
    # 남아 있는데 당장 데이터를 더 못 만들 때의 임시 보험. 켜면 어느 축이 올라갔는지 로그에 남는다.
    sd_floor = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--sd-floor=")), 0.0)
    # --allow-degenerate : 아래 축 게이트를 경고로 낮춘다. 기본은 **차단**(2026-08-20).
    allow_degenerate = "--allow-degenerate" in sys.argv[1:]

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
    mu, sd, scores = fit_calibration(X, cap=cap, sd_floor=sd_floor)

    # ---- DEGENERATE-AXIS GATE (감사는 2026-08-04, 차단으로 승격은 2026-08-20) ----------------
    # 이 검사가 없어서 생긴 실제 사고: CANONICAL 의 60 instance 는 발화 시점이 closed∈{50,58}
    # 두 값뿐이라 `progress` 의 sd 가 0.0051 이었다. 서술자는 전부 [0,1] 범위인데 한 축의 sd 만
    # 0.005 면 그 축은 **초민감 축**이 되고, cap 에 잘리는 순간 혼자 score 를 지배한다:
    #   6축·cap=8 이면 한 축만 잘려도 score >= 8/sqrt(6) = 3.27 인데 교정 최대 score 는 2.21 →
    #   나머지 5축이 완벽해도 **자동으로 novel**. 실제로 데모의 battery(progress 0.41)와 후반
    #   fault(0.66)가 종류와 무관하게 전부 escalate 됐다.
    #
    # 🔴 2026-08-20 — 경고로는 부족했다는 것이 실측으로 드러났다. 이 경고가 들어간 뒤에도
    # `progress` sd=0.0051 짜리 교정이 그대로 만들어져 설치됐고(작업 트리 사본), 라이브에서
    # p=0.0082 로 **모든 판이 escalate** 됐다. 그래서 두 가지를 바꿨다:
    #   (a) 경고 -> **exit 1**. 그래도 만들려면 `--allow-degenerate` 를 명시해야 한다.
    #   (b) 그 판정을 **파일을 쓰기 전에** 한다. 예전에는 json.dump 뒤에 있어서, 위반한 런이
    #       **직전의 정상 교정을 덮어쓰고** 경고만 찍었다 — 이 레포가 sample_grid.py 에서
    #       이미 한 번 데인 실패 모양("충실성 게이트는 출력 앞에서 친다")이 그대로 있었다.
    solo = cap / np.sqrt(len(STATE_DESCRIPTORS))
    print("\n  [axis audit] 서술자는 모두 [0,1] 범위이므로 sd 가 지나치게 작은 축은 게이트를 지배한다")
    bad = []
    for name, m, sd_i in zip(STATE_DESCRIPTORS, mu, sd):
        rng_i = float(X[:, STATE_DESCRIPTORS.index(name)].ptp())
        tag = ""
        if sd_i < DEGENERATE_SD:
            tag = "  <-- DEGENERATE"
            bad.append((name, float(sd_i), rng_i))
        print(f"    {name:18s} mu={m:7.4f} sd={sd_i:8.5f} range={rng_i:6.4f}{tag}")
    if bad:
        print(f"\n  [error] {[b[0] for b in bad]} 축의 분산이 사실상 0 입니다 (sd < {DEGENERATE_SD}).")
        print(f"    한 축만 cap({cap:g}) 에 잘려도 score >= {solo:.2f} 인데 교정 최대는 "
              f"{scores.max():.2f} 이므로, 그 축이 조금만 달라도 **무조건 escalate** 됩니다.")
        for name, sd_i, _ in bad:
            i = STATE_DESCRIPTORS.index(name)
            lo, hi = mu[i] - cap * sd_i, mu[i] + cap * sd_i
            print(f"    {name}: 포화되지 않는 구간 = [{lo:.4f}, {hi:.4f}] — 이 밖은 전부 novel")
        print("    → 그 축이 실제로 변하는 데이터를 넣어 다시 만드십시오. 발화 시점이 원인이라면:")
        print("      DS_FIRE_GRID=58,100,140,180,220,260 julia --project=. "
              "tools/oracle/gen_oracle_dataset.jl")
        print("    → 당장 데이터를 못 만들면 임시 보험으로 --sd-floor=0.02 (근거를 남길 것).")
        if not allow_degenerate:
            print("    아무것도 쓰지 않고 중단합니다. 정말 이대로 만들려면 --allow-degenerate.")
            sys.exit(1)
        print("    --allow-degenerate 가 주어져 계속합니다. 🔴 이 교정은 게이트로 못 씁니다.")

    # ---- parity probes: Julia 가 같은 입력에 같은 값을 내는지 검증할 (입력, 기대출력) 쌍 --------
    # 교정 데이터 자체 + 인위적으로 밀어낸 점들(=novel 이어야 하는 것들)을 섞는다.
    rng = np.random.default_rng(0)
    probes = []
    n_cal_probes = min(nprobe // 2, len(X))     # 앞쪽 n_cal_probes 개 = 교정점 그대로, 나머지 = 밀어낸 점
    for i in range(n_cal_probes):
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
            "sd_floor": sd_floor,                   # >0 이면 축별 sd 에 하한을 걸어 맞춘 교정이다
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
    # 경계는 **probe 목록의 구조**(앞 n_cal_probes 개가 교정점)로 잡아야 한다. 예전에는 len(X)//2 로
    # 잘랐는데, instance 가 probe 수보다 많으면(99 > 32) 뒤쪽 슬라이스가 통째로 비어 mean 이 nan 이
    # 되고, 아래 분별력 경고가 **조용히 꺼진다**(2026-08-05 실측: n=99 교정에서 nan).
    p_in = np.mean([q["p"] for q in probe_out[:n_cal_probes or 1]])
    p_out = np.mean([q["p"] for q in probe_out[n_cal_probes or 1:]]) if len(probe_out) > n_cal_probes else float("nan")
    print(f"  mean p on calibration-like probes = {p_in:.3f};  on shifted probes = {p_out:.3f}")
    if p_out >= p_in:
        print("  WARNING: shifted probes are not scoring as more novel -- calibration may be degenerate")



if __name__ == "__main__":
    main()
