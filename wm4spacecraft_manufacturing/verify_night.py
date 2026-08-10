#!/usr/bin/env python3
"""
verify_night.py -- 야간 파이프라인(E->RENDER->D->A->B->C) 산출물의 **단일 기계 판정기**.

검증 서브에이전트와 최종 리포트가 같이 부르는 파일이다. 시뮬은 절대 돌리지 않는다(전역 제약 1) --
이미 있는 산출물만 읽고 STEP 별 합격 조건을 코드로 확인한다.

이 파일이 막아야 하는 두 조용한 실패 (NIGHT_PLAN_2026-08-10.md Global Constraint 6)
---------------------------------------------------------------------------------------
1. zone 축 n=0: `test_llm7h.py:138-141` 은 `zcausal_reform/*.json` 이 없으면
   `except OSError: continue` 로 예외를 삼키고 표본 0 으로 통과한다. 여기서는 n 을
   **직접 세고**, 파일이 있는데 0개/일부만 있거나 파싱이 깨지면 FAIL 로 판정한다.
2. 라우터 fail-open: `NOVELTY_CALIB` 이 없으면 `policy.jl:67-68` 이 경고만 찍고 라우터를
   끈 채 그대로 진행한다(exit 0). `router_target` 이 non-null 이라는 것만으로는 증거가
   안 된다 -- 라우터가 꺼져 있어도 route() 는 base policy 이름을 그대로 돌려주기 때문이다
   (llm_ood_eval.py `_router_drove` 의 2026-08-10 정정과 동일한 근거). 실제 구동의 증거는
   `router_target` 이 {"surrogate","dspy"} 중 하나로 **덮어써졌는가**뿐이다.

판정 원칙 (전역 제약 5)
-----------------------
  · 입력 파일/디렉터리가 아예 없다             -> SKIP (그 STEP 이 아직 안 돌았다, FAIL 아님)
  · 입력은 있는데 표본이 0 이거나 내용이 비었다 -> FAIL (조용한 실패는 여기서 잡는다)
  · 입력이 있고 기대한 만큼 있다               -> PASS

각 STEP 함수는 Check(name, status, detail) 리스트를 돌려준다. status ∈ {"PASS","FAIL","SKIP"}.
마지막 줄은 항상 `VERIFY <step> PASS|FAIL <n_checks>` (SKIP 은 FAIL 로 세지 않는다 -- 전부
SKIP 이면 PASS 0). exit code: FAIL 이 하나라도 있으면 1, 아니면 0.

실행
----
  python verify_night.py --step all
  python verify_night.py --step D
"""
import argparse
import collections
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent          # wm4spacecraft_manufacturing/
REPO = HERE.parent                               # repo 루트
sys.path.insert(0, str(HERE))

import reference_policy                          # noqa: E402  (score() 재사용 -- 재구현 금지 지시)

try:
    sys.stdout.reconfigure(encoding="utf-8")      # cp949 콘솔에서 한글 깨짐 방지 (repo 스타일)
except Exception:
    pass

Check = collections.namedtuple("Check", ["name", "status", "detail"])


def chk(name, status, detail=""):
    assert status in ("PASS", "FAIL", "SKIP")
    return Check(name, status, detail)


# =========================================================================================
#  0. 공통 리더 -- 파싱 에러를 삼키지 않는다 (test_llm7h.py:138-141 함정의 정반대)
# =========================================================================================
def read_jsonl(path):
    """JSONL 파일을 dict 리스트로. 줄 파싱이 깨지면 예외를 그대로 올린다(호출부가 FAIL 로 잡는다)."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                raise ValueError("%s:%d 파싱 실패 -- %s" % (path, i, e)) from e
    return rows


def read_json(path):
    """단일 JSON 파일. ZC_OUT 이 append 모드라 이어붙으면 여기서 그대로 예외가 난다."""
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_eval_rows(path):
    """요약 JSONL **한 파일**을 (case, ood_seed, policy) 로 dedup(나중 것이 이긴다) 해서 읽는다.

    llm_ood_eval.py:load_rows 와 같은 규칙이지만 그 파일을 import 하지 않고 직접 구현한다 --
    다른 에이전트가 지금 llm_ood_eval.py 를 고치고 있어(전역 제약 3), 이 판정기가 그 파일의
    미완성 상태에 얽히면 안 된다.
    """
    dedup = {}
    for r in read_jsonl(path):
        dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
    return list(dedup.values())


def discover_eval_files(eval_dir, pattern):
    """results/ 아래 llm_ood_eval*.jsonl 계열 파일을 패턴으로 전부 찾는다 (mtime 오름차순).

    전역 제약 2("새 산출물은 새 경로로 쓴다")때문에 STEP 마다 --out 파일 이름이 갈린다 --
    실측(2026-08-10): STEP E 는 `results/llm_ood_eval_router.jsonl` 을 쓰고, 예전 판은
    `results/llm_ood_eval.jsonl` 그대로다. 파일 이름 하나로 고정하면 실제 STEP E/B/C 산출물을
    놓친다 -- 그래서 이름이 아니라 **패턴**으로 모은다.
    """
    return sorted(Path(eval_dir).glob(pattern), key=lambda p: p.stat().st_mtime)


def load_eval_rows_multi(eval_dir, pattern):
    """패턴에 맞는 여러 파일을 모아 (case, ood_seed, policy) 로 전역 dedup 한다.

    여러 파일에 같은 키가 있으면 **더 최근에 수정된 파일의 행이 이긴다**(재실행=최신이 이긴다,
    이 repo 전역 관례와 동일). 반환: (rows, files) -- files 는 실제로 읽은 파일 목록(빈 리스트면
    아직 아무것도 안 만들어진 것 = 호출부에서 SKIP).
    """
    files = discover_eval_files(eval_dir, pattern)
    dedup = {}
    for f in files:
        for r in read_jsonl(f):    # 파싱 실패시 파일명:줄번호 포함한 ValueError 가 그대로 올라간다
            dedup[(r.get("case"), r.get("ood_seed"), r.get("policy"))] = r
    return list(dedup.values()), files


# =========================================================================================
#  STEP E -- 라우터 옵트인 (Task 1) 이 실제로 구동됐는지
# =========================================================================================
ROUTER_ENGAGED_TARGETS = {"surrogate", "dspy"}    # route() 가 실제로 고를 수 있는 값(policy.jl:349,356)


def step_E(args):
    checks = []
    backup = Path(args.backup)

    # (1) case 인식 dedup 회귀 (Task 1 1-c) -- 백업 파일이 깨지지 않고 그대로 읽히는지.
    #     계획서는 "26행"이라 적었는데, 실측하면 그건 **원본 raw 줄 수**다(파일 자체가 26줄).
    #     dedup 은 (case, ood_seed, policy) 가 겹치는 6개 재실행분을 20행으로 합친다 --
    #     이 파일은 case 가 전부 "all"이라 case 축을 넣기 전/후 dedup 결과가 동일하므로(회귀 없음),
    #     실제 llm_ood_eval.py report 로 교차검증했다(20 판, 2026-08-10 실측). 따라서 여기서는
    #     raw 줄 수(26, 파일이 안 깨졌다는 사실)와 dedup 후 행 수(20, 재실행 6건이 올바르게
    #     합쳐졌다는 사실)를 **둘 다** 확인한다.
    if not backup.exists():
        checks.append(chk("E case-dedup 회귀 (%s)" % backup.name, "SKIP", "백업 파일 없음"))
    else:
        try:
            raw_n = len(read_jsonl(backup))
            rows = load_eval_rows(backup)
        except ValueError as e:
            checks.append(chk("E case-dedup 회귀", "FAIL", str(e)))
        else:
            ok = raw_n == 26 and len(rows) == 20
            checks.append(chk("E case-dedup 회귀 (backup)", "PASS" if ok else "FAIL",
                              "raw=%d줄(기대 26) dedup 후=%d행(기대 20, 재실행 6건 합쳐짐)"
                              % (raw_n, len(rows))))

    # (2) 라우터가 실제로 구동됐는지 -- fail-open 검출이 이 파일의 핵심 존재 이유.
    #     결과 파일은 이름이 하나로 고정돼 있지 않다(전역 제약 2, 실측: llm_ood_eval_router.jsonl) --
    #     그래서 패턴으로 전부 모은다(discover_eval_files).
    try:
        rows, files = load_eval_rows_multi(args.eval_dir, args.eval_pattern)
    except ValueError as e:
        checks.append(chk("E 라우터 구동", "FAIL", str(e)))
        return checks
    if not files:
        checks.append(chk("E 라우터 구동 (%s)" % args.eval_pattern, "SKIP",
                          "%s 에 매칭되는 요약 파일 없음" % args.eval_dir))
        return checks
    router_on_rows = [r for r in rows if str(r.get("router")) not in ("0", "None")]
    if not router_on_rows:
        checks.append(chk("E 라우터 구동 (%d개 파일: %s)" % (len(files), ", ".join(f.name for f in files)),
                          "SKIP", "--router != 0 으로 요청된 판이 아직 없음(전부 router='0')"))
        return checks
    seen_targets = set()
    n_engaged = 0
    for r in router_on_rows:
        for d in (r.get("decisions") or []):
            t = d.get("router_target")
            seen_targets.add(t)
            if t in ROUTER_ENGAGED_TARGETS:
                n_engaged += 1
    if n_engaged == 0:
        checks.append(chk("E 라우터 구동 (fail-open 검출)", "FAIL",
                          "router!=0 인 %d개 판이 있지만 어떤 결정도 router_target 을 "
                          "surrogate/dspy 로 덮어쓰지 않음 -- 관측된 target=%s "
                          "(policy.jl:67 fail-open 의심, NOVELTY_CALIB 확인 필요)"
                          % (len(router_on_rows), sorted(str(t) for t in seen_targets))))
    else:
        checks.append(chk("E 라우터 구동", "PASS",
                          "router!=0 판 %d개, engaged 결정 %d개 (router_target ∈ %s)"
                          % (len(router_on_rows), n_engaged, sorted(ROUTER_ENGAGED_TARGETS))))
    return checks


# =========================================================================================
#  STEP RENDER -- case 별 대시보드 산출물 (Task 5)
# =========================================================================================
def step_RENDER(args):
    checks = []
    monitor_dir = Path(args.monitor_dir)
    streams_dir = monitor_dir / "streams"
    anim_dir = monitor_dir / "anim"
    need_keys = {"sim_t", "n_closed", "ood"}

    for case in ("battery", "fault", "zone"):
        matches = sorted(streams_dir.glob("tractor__%s__*.jsonl" % case))
        if not matches:
            checks.append(chk("RENDER case=%s" % case, "SKIP",
                              "streams/tractor__%s__*.jsonl 없음" % case))
            continue
        f = matches[0]
        if f.stat().st_size == 0:
            checks.append(chk("RENDER case=%s" % case, "FAIL", "%s 이 비어있다(n=0)" % f.name))
            continue
        try:
            with open(f, encoding="utf-8") as fh:
                first_line = fh.readline()
            frame = json.loads(first_line)
        except json.JSONDecodeError as e:
            checks.append(chk("RENDER case=%s" % case, "FAIL", "%s 첫 줄 파싱 실패: %s" % (f.name, e)))
            continue
        missing = need_keys - frame.keys()
        if missing:
            checks.append(chk("RENDER case=%s" % case, "FAIL",
                              "%s 첫 프레임에 필수 키 누락: %s" % (f.name, sorted(missing))))
            continue
        anim_f = anim_dir / (f.stem + ".html")
        if not anim_f.exists():
            checks.append(chk("RENDER case=%s" % case, "FAIL",
                              "%s 는 있는데 %s 없음 -- publish_anim! 이 미완주 빌드를 거부했을 수 "
                              "있다(render_demo.jl:1037-1038)" % (f.name, anim_f.name)))
            continue
        checks.append(chk("RENDER case=%s" % case, "PASS",
                          "stream=%s (%d bytes) + anim=%s" % (f.name, f.stat().st_size, anim_f.name)))
    return checks


# =========================================================================================
#  STEP D -- 오라클 복구 (Task 3: firegrid 레인, Task 4: zcausal 4팔)
# =========================================================================================
def step_D(args):
    checks = []
    oracle_dir = Path(args.oracle_dir)

    # ---- battery 축 (이미 있는 산출물, n=18 이 오늘의 기준선) --------------------------------
    batt = oracle_dir / "battgrid_0805_s1.jsonl"
    if not batt.exists():
        checks.append(chk("D battery 축 (%s)" % batt.name, "SKIP", "파일 없음"))
    else:
        try:
            rows = read_jsonl(batt)
        except ValueError as e:
            checks.append(chk("D battery 축", "FAIL", str(e)))
        else:
            n = len({r.get("instance") for r in rows})
            if n == 0:
                checks.append(chk("D battery 축", "FAIL", "n=0 (rows=%d 인데 instance 가 없다)" % len(rows)))
            elif n != 18:
                checks.append(chk("D battery 축", "FAIL", "n=%d (기대 18)" % n))
            else:
                checks.append(chk("D battery 축", "PASS", "n=18 (rows=%d)" % len(rows)))

    # ---- fault 축: firegrid 레인 파일 2개 (Task 3) -----------------------------------------
    for lane in ("fault", "faultidle"):
        lp = oracle_dir / ("firegrid_s%s.jsonl" % lane)
        if not lp.exists():
            checks.append(chk("D firegrid 레인 %s" % lane, "SKIP", "%s 없음" % lp.name))
            continue
        try:
            rows = read_jsonl(lp)
        except ValueError as e:
            checks.append(chk("D firegrid 레인 %s" % lane, "FAIL", str(e)))
            continue
        if not rows:
            checks.append(chk("D firegrid 레인 %s" % lane, "FAIL", "%s rows=0" % lp.name))
        else:
            checks.append(chk("D firegrid 레인 %s" % lane, "PASS", "rows=%d" % len(rows)))

    # ---- fault 축: 병합 후 instance 수 (Task 3 합격 조건 -- n>18 이어야 firegrid 가 섞인 것) ----
    merged = oracle_dir / "firegrid_merged.jsonl"
    if not merged.exists():
        checks.append(chk("D fault 축 (%s)" % merged.name, "SKIP", "파일 없음"))
    else:
        try:
            rows = read_jsonl(merged)
        except ValueError as e:
            checks.append(chk("D fault 축", "FAIL", str(e)))
        else:
            fault_rows = [r for r in rows if r.get("kind") == "fault"]
            n = len({r.get("instance") for r in fault_rows})
            if n == 0:
                checks.append(chk("D fault 축", "FAIL", "n=0"))
            elif n <= 18:
                checks.append(chk("D fault 축", "FAIL",
                                  "n=%d (<=18 -- firegrid 가 조용히 안 섞였다, 18 초과 기대)" % n))
            else:
                checks.append(chk("D fault 축", "PASS", "n=%d (>18, firegrid 병합 확인됨)" % n))

    # ---- zone 축: zcausal_reform 4개 arm json (Task 4) -------------------------------------
    zc = oracle_dir / "zcausal_reform"
    files = [zc / f for f in ("blk_noop.json", "blk_reloc.json", "cov_noop.json", "cov_reloc.json")]
    existing = [f for f in files if f.exists()]
    if not existing:
        checks.append(chk("D zone 축 (zcausal_reform/*.json)", "SKIP", "4개 중 0개 존재"))
    elif len(existing) < 4:
        missing = [f.name for f in files if f not in existing]
        checks.append(chk("D zone 축", "FAIL", "4개 중 %d개만 존재, 없는 것: %s" % (len(existing), missing)))
    else:
        bad = []
        for f in files:
            try:
                read_json(f)
            except (json.JSONDecodeError, OSError) as e:
                bad.append("%s: %s" % (f.name, e))
        if bad:
            checks.append(chk("D zone 축", "FAIL",
                              "파싱 실패(ZC_OUT append 중복 의심) -- %s" % "; ".join(bad)))
        else:
            checks.append(chk("D zone 축", "PASS", "n=2 families(blk,cov), 4/4 파일 파싱 OK"))

    return checks


# =========================================================================================
#  STEP A -- shadow_score.py 산출물 (Task 2)
# =========================================================================================
def step_A(args):
    checks = []
    md = Path(args.shadow_md)
    if not md.exists():
        checks.append(chk("A shadow.md (%s)" % md.name, "SKIP", "파일 없음"))
        return checks
    text = md.read_text(encoding="utf-8")
    if not text.strip():
        checks.append(chk("A shadow.md 내용", "FAIL", "파일은 있는데 비어있다"))
        return checks
    checks.append(chk("A shadow.md 존재+비어있지 않음", "PASS", "%d bytes" % len(text)))

    # 해석 한계 문단은 계획서 §3 그대로 축약 없이 들어가야 한다(합격 조건 명시).
    limitation_markers = ["상태 조건부 결정 충실도", "결과 비교가 아니다"]
    missing = [m for m in limitation_markers if m not in text]
    checks.append(chk("A 해석 한계 문단 포함", "FAIL" if missing else "PASS",
                      ("빠진 문구: %s" % missing) if missing else "문단 확인됨"))

    # 4 producer(rule/surrogate/llm/실제 macro) + B1/B2 가 같은 분모로 언급되는지(느슨한 존재 확인;
    # shadow_score.py 가 아직 없어 정확한 표 형식을 알 수 없으므로 숫자 재검산은 하지 않는다).
    producers = ["rule", "surrogate", "llm"]
    missing_p = [p for p in producers if p not in text]
    checks.append(chk("A producer(rule/surrogate/llm) 표기", "FAIL" if missing_p else "PASS",
                      ("빠진 producer: %s" % missing_p) if missing_p else "전부 표기됨"))
    missing_b = [b for b in ("B1", "B2") if b not in text]
    checks.append(chk("A B1/B2 baseline 표기", "FAIL" if missing_b else "PASS",
                      ("빠짐: %s" % missing_b) if missing_b else "B1/B2 확인됨"))
    return checks


# =========================================================================================
#  STEP B -- 시드 6-10 확장
# =========================================================================================
def step_B(args):
    checks = []
    try:
        rows, files = load_eval_rows_multi(args.eval_dir, args.eval_pattern)
    except ValueError as e:
        checks.append(chk("B seed 6-10", "FAIL", str(e)))
        return checks
    if not files:
        checks.append(chk("B seed 6-10 (%s)" % args.eval_pattern, "SKIP", "매칭되는 요약 파일 없음"))
        return checks
    ext_rows = [r for r in rows if r.get("ood_seed") in (6, 7, 8, 9, 10)]
    if not ext_rows:
        checks.append(chk("B seed 6-10", "SKIP", "seed 6-10 판이 아직 없음"))
        return checks
    decisions = [d for r in ext_rows for d in (r.get("decisions") or [])]
    scored, correct, _ = reference_policy.score(decisions)
    if scored == 0:
        checks.append(chk("B seed 6-10", "FAIL", "rows=%d 있지만 채점 가능한 결정이 0개(n=0)" % len(ext_rows)))
    else:
        seeds = sorted({r.get("ood_seed") for r in ext_rows})
        checks.append(chk("B seed 6-10", "PASS",
                          "seeds=%s rows=%d scored=%d correct=%d" % (seeds, len(ext_rows), scored, correct)))
    return checks


# =========================================================================================
#  STEP C -- case 별 격자 (battery/fault/zone 각각 독립적으로 n>0 이어야 한다)
# =========================================================================================
def step_C(args):
    checks = []
    try:
        rows, files = load_eval_rows_multi(args.eval_dir, args.eval_pattern)
    except ValueError as e:
        checks.append(chk("C case별 격자", "FAIL", str(e)))
        return checks
    if not files:
        checks.append(chk("C case별 격자 (%s)" % args.eval_pattern, "SKIP", "매칭되는 요약 파일 없음"))
        return checks
    for case in ("battery", "fault", "zone"):
        case_rows = [r for r in rows if r.get("case") == case]
        if not case_rows:
            checks.append(chk("C case=%s" % case, "SKIP", "이 case 의 판이 아직 없음"))
            continue
        decisions = [d for r in case_rows for d in (r.get("decisions") or [])]
        if not decisions:
            # 정확히 브리프가 경고한 패턴: 행은 있는데(=런은 돌았는데) 사건이 0개.
            checks.append(chk("C case=%s" % case, "FAIL",
                              "rows=%d 있지만 decisions=0 (조용한 n=0 패턴)" % len(case_rows)))
            continue
        scored, correct, _ = reference_policy.score(decisions)
        checks.append(chk("C case=%s" % case, "PASS",
                          "rows=%d decisions=%d scored=%d correct=%d"
                          % (len(case_rows), len(decisions), scored, correct)))
    return checks


# =========================================================================================
#  출력 + 메인
# =========================================================================================
STEP_FUNCS = {"E": step_E, "RENDER": step_RENDER, "D": step_D, "A": step_A, "B": step_B, "C": step_C}
ORDER = ["E", "RENDER", "D", "A", "B", "C"]


def print_step(step_name, checks):
    print("-" * 90)
    print("STEP %s" % step_name)
    print("-" * 90)
    for c in checks:
        print("  [%-4s] %-40s %s" % (c.status, c.name, c.detail))
    n_fail = sum(1 for c in checks if c.status == "FAIL")
    verdict = "FAIL" if n_fail else "PASS"
    print("VERIFY %s %s %d" % (step_name, verdict, len(checks)))
    print()
    return verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--step", choices=ORDER + ["all"], default="all")
    ap.add_argument("--eval-dir", default=str(HERE / "results"),
                    help="STEP E/B/C 가 읽는 요약 JSONL 이 있는 디렉터리 (기본: results/)")
    ap.add_argument("--eval-pattern", default="llm_ood_eval*.jsonl",
                    help="요약 JSONL 파일 glob 패턴. STEP 마다 --out 파일명이 갈리므로(전역 제약 2) "
                        "이름 하나가 아니라 패턴으로 전부 모은다 (기본: llm_ood_eval*.jsonl)")
    ap.add_argument("--backup", default=str(REPO / "_backup_2026-08-10" / "llm_ood_eval.jsonl"),
                    help="STEP E 의 case-dedup 회귀 기준 파일")
    ap.add_argument("--shadow-md", default=str(HERE / "artifacts_night" / "shadow.md"),
                    help="STEP A 산출물 (shadow_score.py --md 의 기본 경로)")
    ap.add_argument("--oracle-dir", default=str(HERE / "oracle" / "out"),
                    help="STEP D 가 읽는 오라클 덤프 디렉터리")
    ap.add_argument("--monitor-dir", default=str(REPO / "tools" / "monitor"),
                    help="STEP RENDER 가 읽는 streams/anim 상위 디렉터리")
    args = ap.parse_args()

    steps = ORDER if args.step == "all" else [args.step]
    total_checks = 0
    overall_fail = False
    for s in steps:
        checks = STEP_FUNCS[s](args)
        verdict = print_step(s, checks)
        if verdict == "FAIL":
            overall_fail = True
        total_checks += len(checks)

    if args.step == "all":
        print("=" * 90)
        print("VERIFY all %s %d" % ("FAIL" if overall_fail else "PASS", total_checks))

    return 1 if overall_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
