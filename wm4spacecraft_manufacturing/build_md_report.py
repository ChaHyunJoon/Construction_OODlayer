#!/usr/bin/env python3
"""
build_md_report.py -- 5시간 4정책 스윕(run_4pol.sh, 8 case) + 오라클 결과-천장(STEP D)을
하나의 자기완결(self-contained) Markdown 파일로 조립한다 (artifacts_4pol/REPORT.md).

★ julia 를 절대 부르지 않는다. STEP D(오라클 라벨 재생성)가 이 스크립트가 도는 동안 다른
   프로세스로 돌고 있다 -- 두 번째 julia 프로세스는 HiGHS 스케줄을 갈라 지금 만들어지는
   라벨을 오염시킨다(README 함정 30). 이 스크립트는 서브프로세스를 전혀 띄우지 않는다
   (`build_final_table.py` 와 달리 `llm_ood_eval.py report` / `shadow_score.py` 조차 shell-out
   하지 않는다 -- 이미 만들어진 `artifacts_4pol/*.json` `*.md` `shadow*.md` 를 읽기만 한다).

★ 지표 수학은 재구현하지 않는다(가능한 한). 헤드라인 표의 셀 서식은
   `build_final_table.py.render_row_cells` 를 그대로 import 해서 쓴다. 새로 계산하는 것은
   Part A(오라클 결과-천장, 축 단위) 뿐이고, 그 시맨틱은 `test_llm7h.py` 의 `lexbest()` /
   `LAM=3.0` 을 그대로 옮긴 것이다 -- 규칙을 다르게 적으면 문서와 실측이 갈라진다.

★ 결측은 절대 0 도 빈칸도 아니다. `미측정 (STEP D 필요)` 로 명시한다(`build_final_table.MISSING_TOKEN`
   과 동일 문자열). fault/zone 오라클 라벨 파일이 아직 없어도 이 스크립트는 exit 0 으로 끝나야
   하고, STEP D 가 끝난 뒤 같은 코드로 다시 돌리면 실수치가 나와야 한다(코드 변경 없이).

실행
----
  python build_md_report.py [--results-dir results_4pol] [--out-dir artifacts_4pol]
                             [--oracle-dir oracle/out] [--night-dir _night]

테스트(오늘, 라벨 없는 상태): 그대로 실행 -- fault/zone 축이 `미측정 (STEP D 필요)` 로 렌더링되고
exit 0 인지 확인한다.

테스트(STEP D 완료 이후 상태를 실제 데이터 건드리지 않고 재현):
  --oracle-dir 에 `firegrid_merged.jsonl` 과 `zcausal_reform/{blk,cov}_{noop,reloc}.json` 을 채운
  임시 디렉터리를 만들어 넘긴다. 같은 코드로 실수치가 나오는지 본다.
"""
import argparse
import collections
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import e1_analyze as E                       # noqa: E402  (lex_key, MACRO_COST, MACRO_NAME)
import reference_policy as RP                 # noqa: E402  (BASIS 문자열)
import build_final_table as BFT               # noqa: E402  (입력 파싱 관례 재사용 -- 재구현 금지)

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

LAM = 3.0
MISSING_TOKEN = BFT.MISSING_TOKEN   # "미측정 (STEP D 필요)"
DASH = BFT.DASH
NA = "n/a (필드 없음)"


# =====================================================================================
# Part A -- 오라클 결과-천장 (축 단위: battery / fault / zone). test_llm7h.py:44-50, 118-146 그대로.
# =====================================================================================
def _makespan_float(v):
    if v is None:
        return None
    if isinstance(v, str):
        if v == "Inf":
            return math.inf
        try:
            return float(v)
        except ValueError:
            return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _rows_of(path: Path):
    if not path.exists():
        return []
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def _group_by_instance(rows):
    g = collections.defaultdict(list)
    for r in rows:
        g[r["instance"]].append(r)
    return g


def oracle_star_row(rs):
    """test_llm7h.py:44-50 lexbest() 와 동일한 사전식 최선이되, macro 이름이 아니라 행 전체를
    돌려준다(complete/closed/total/makespan 이 다 필요하다)."""
    def key(r):
        mk = _makespan_float(r.get("makespan"))
        if mk is None:
            mk = -math.inf
        return E.lex_key(bool(r["complete"]), r["closed"] - LAM * E.MACRO_COST[int(r["macro"])], mk)
    return max(rs, key=key)


def summarize_star_rows(star_rows):
    """n / a* 완주율 / mean(closed/total) / 완주판 mean(makespan)."""
    n = len(star_rows)
    completes = [bool(r.get("complete")) for r in star_rows]
    n_complete = sum(completes)
    completion_rate = n_complete / n if n else None

    ratios = []
    missing_total = False
    for r in star_rows:
        total, closed = r.get("total"), r.get("closed")
        if total is None or total == 0 or closed is None:
            missing_total = True
            continue
        ratios.append(closed / total)
    mean_closed_total = (sum(ratios) / len(ratios)) if ratios else None

    ms = []
    for r, c in zip(star_rows, completes):
        if not c:
            continue
        mk = _makespan_float(r.get("makespan"))
        if mk is not None and math.isfinite(mk):
            ms.append(mk)
    mean_makespan = (sum(ms) / len(ms)) if ms else None

    return dict(n=n, n_complete=n_complete, completion_rate=completion_rate,
                mean_closed_total=mean_closed_total, missing_total=missing_total,
                mean_makespan=mean_makespan, n_makespan_arms=len(ms))


def axis_battery(oracle_dir: Path):
    rows = _rows_of(oracle_dir / "battgrid_0805_s1.jsonl")
    if not rows:
        return None
    groups = _group_by_instance(rows)
    star_rows = [oracle_star_row(rs) for rs in groups.values()]
    if not star_rows:
        return None
    out = summarize_star_rows(star_rows)
    out["source"] = "oracle/out/battgrid_0805_s1.jsonl (18 instances = 6 fire points x 3 severities, all 3 arms)"
    return out


def axis_fault(oracle_dir: Path):
    rows = _rows_of(oracle_dir / "firegrid_merged.jsonl")
    if not rows:
        return None
    groups = _group_by_instance(rows)
    star_rows = []
    for rs in groups.values():
        if rs[0].get("kind") != "fault":
            continue
        star_rows.append(oracle_star_row(rs))
    if not star_rows:
        return None
    out = summarize_star_rows(star_rows)
    out["source"] = "oracle/out/firegrid_merged.jsonl (kind=='fault' instances only, test_llm7h.py:118-119 미러)"
    return out


def axis_zone(oracle_dir: Path):
    """test_llm7h.py:130-152 미러. n=2 (blk, cov 두 사건군) -- 가장 약한 축."""
    zc = oracle_dir / "zcausal_reform"
    families = []
    for fam, noop_f, act_f in (("blk", "blk_noop.json", "blk_reloc.json"),
                                ("cov", "cov_noop.json", "cov_reloc.json")):
        pa, pb = zc / noop_f, zc / act_f
        if not (pa.exists() and pb.exists()):
            continue
        try:
            a = json.loads(pa.read_text(encoding="utf-8"))
            b = json.loads(pb.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        ka = (1 if a.get("status") == "complete" else 0, a.get("closed", 0) - LAM * 0.0)
        kb = (1 if b.get("status") == "complete" else 0, b.get("closed", 0) - LAM * E.MACRO_COST[7])
        star = "RelocateBuild" if kb > ka else "NOOP"
        winner = b if star == "RelocateBuild" else a
        # zcausal_reform 의 json 은 "complete" 불리언이 아니라 "status" 문자열을 쓴다 --
        # summarize_star_rows 가 기대하는 정규화 키(complete/closed/total/makespan)로 변환한다.
        norm = dict(complete=(winner.get("status") == "complete"),
                    closed=winner.get("closed"), total=winner.get("total"),
                    makespan=winner.get("makespan"))
        families.append(dict(fam=fam, star=star, row=norm))
    if not families:
        return None
    star_rows = [f["row"] for f in families]
    out = summarize_star_rows(star_rows)
    out["source"] = "oracle/out/zcausal_reform/ STEP 10 (blk, cov 두 arm-crossed 사건군, n=2 -- 가장 약한 축)"
    out["families"] = families
    return out


def fmt_axis_row(axis_name, summary):
    if summary is None:
        return "| %s | %s | %s | %s | %s |" % (axis_name, MISSING_TOKEN, MISSING_TOKEN, MISSING_TOKEN, MISSING_TOKEN)
    n = summary["n"]
    comp = "%.0f%% (%d/%d)" % (100 * summary["completion_rate"], summary["n_complete"], n)
    ct = ("%.1f%%" % (100 * summary["mean_closed_total"])) if summary["mean_closed_total"] is not None else NA
    if summary["mean_makespan"] is not None:
        ms = "%.1f (완주판 n=%d)" % (summary["mean_makespan"], summary["n_makespan_arms"])
    else:
        ms = NA
    return "| %s | %d | %s | %s | %s |" % (axis_name, n, comp, ct, ms)


def render_oracle_ceiling_section(oracle_dir: Path):
    L = []
    L.append("## 3. 오라클 결과-천장 (Part A -- 축 단위)")
    L.append("")
    L.append("> **천장(ceiling) vs 정책 행의 차이.** 위 헤드라인 표의 `oracle` 행은 \"옳은 결정\" 열에서 "
              "정의상 100% 다(그 행의 정의가 a\\* 이므로) -- 그건 성능 주장이 아니라 나머지 세 정책이 "
              "얼마나 떨어졌는지 재는 눈금(원점)이다. 여기 이 절은 그와 다른 것 -- **a\\* 를 실제로 "
              "실행했을 때 결과가 어땠는가**(완주율 · closed/total · makespan) -- 를 축(battery/fault/zone) "
              "단위로 오라클 격자 실측에서 직접 계산한다. `oracle` 은 온라인 정책이 아니므로(`tools/monitor/policy.jl` "
              "에 oracle 분기 없음) 이 숫자는 8-case 헤드라인 표의 셀이 아니라 별도 참조선이다.")
    L.append("")
    L.append("계산 시맨틱은 `test_llm7h.py` 의 `lexbest()`(줄 44-50) 및 zone 비교식(줄 139-146)을 그대로 "
              "옮긴 것이다(재구현 아님, `LAM=%.1f`). instance 를 `instance` 필드로 묶고, 각 instance 에서 "
              "`E.lex_key(complete, closed - LAM*E.MACRO_COST[macro], makespan)` 사전식 최댓값을 고른 "
              "행이 a\\* 다." % LAM)
    L.append("")
    L.append("| 축 | n (instances) | a\\* 완주율 | mean(closed/total) | mean(makespan), 완주판만 |")
    L.append("|---|---|---|---|---|")

    battery = axis_battery(oracle_dir)
    fault = axis_fault(oracle_dir)
    zone = axis_zone(oracle_dir)

    L.append(fmt_axis_row("battery", battery))
    L.append(fmt_axis_row("fault", fault))
    L.append(fmt_axis_row("**zone** (n=2, 최약축)", zone))
    L.append("")

    for name, summary in (("battery", battery), ("fault", fault), ("zone", zone)):
        if summary is None:
            L.append("- `%s`: %s -- 라벨 파일이 아직 없거나 비어 있다(STEP D 진행 중/미완료). "
                      "이 스크립트를 STEP D 완료 후 다시 돌리면 코드 변경 없이 실수치가 채워진다." % (name, MISSING_TOKEN))
        else:
            L.append("- `%s`: %s (n=%d)" % (name, summary["source"], summary["n"]))
            if summary.get("missing_total"):
                L.append("  - 주의: 일부 a\\* 행에 `total` 또는 `closed` 필드가 없어 closed/total 평균에서 제외됨.")
    L.append("")
    L.append("> zone 축은 n=2(blk, cov 두 사건군)뿐이다 -- **가장 약한 축이고, 과잉해석하지 말 것.** "
              "완주율이라는 말이 여기서는 \"두 사건군 중 a\\* 가 완주로 끝난 비율\"이라는 뜻이지, "
              "표본이 많은 통계가 아니다.")
    L.append("")
    return L


# =====================================================================================
# 헤드라인 표 (8 case x 4 method) -- BFT.render_row_cells 재사용, 새로 계산하지 않는다.
# =====================================================================================
def render_headline_table(cases_info, out_dir: Path):
    L = []
    L.append("## 2. 헤드라인 표 -- 8 case x 4 방법")
    L.append("")
    L.append(BFT.ORACLE_NOTE)
    L.append("")
    L.append("실행 가능한 lane 은 `noop` / `surrogate` / `dspy`(=`llm`) 셋뿐이다. `oracle` 행은 "
              "case 마다 별도 계산되는 상한선(정의상 100%)으로만 들어간다 -- \"oracle 이 이겼다\"는 "
              "주장은 정의상 항상 참이라 정보가 없다. 승자를 굵게 표시하지 않는다: 예를 들어 "
              "`zonecore` 는 surrogate 가 결정 100% 지만 완주 4/5, llm 은 결정 65% 지만 완주 5/5 에 "
              "에너지도 더 낮다 -- 어느 쪽도 무조건 '이겼다' 라고 적을 수 없다(아래 §5 zonecore 상세 참조).")
    L.append("")
    for case in BFT.CASES:
        ci = cases_info[case]
        json_path = out_dir / ("%s.json" % case)
        L.append("### case = `%s`" % case)
        L.append("")
        if not ci["has_data"] or not json_path.exists():
            st = ci["status"]
            reason = ("status=%s rows=%s" % (st.get("status"), st.get("rows"))) if st else "status 기록 없음"
            L.append("데이터 없음 (%s)." % reason)
            L.append("")
            continue
        try:
            json_data = json.loads(json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            L.append("`%s.json` 파싱 실패: %r" % (case, e))
            L.append("")
            continue
        L.append("| 정책 | 완주율 | 옳은 결정 (vs a\\*) | 빌드 시간(완주판) | J/closed |")
        L.append("|---|---|---|---|---|")
        for label, _key in BFT.ROW_ORDER:
            cells = BFT.render_row_cells(label, case, json_data)
            L.append("| %s | %s |" % (BFT.ROW_LABEL_TEXT[label], " | ".join(cells)))
        L.append("")
    return L


# =====================================================================================
# 같은 분모 shadow 비교 (§4) -- shadow.md 산출1/산출2 를 그대로 인용(재계산/재구현 금지).
# =====================================================================================
def render_shadow_section(out_dir: Path):
    L = []
    L.append("## 4. 같은-분모(same-denominator) 결정 비교 (shadow, N=435)")
    L.append("")
    shadow_path = out_dir / "shadow.md"
    if not shadow_path.exists():
        L.append("`%s` 없음 -- 이 절을 채울 수 없다." % shadow_path)
        L.append("")
        return L
    text = shadow_path.read_text(encoding="utf-8")
    try:
        start = text.index("입력:")
        end = text.index("## 산출 3")
    except ValueError:
        L.append("`shadow.md` 형식이 예상과 달라 절 경계를 못 찾음 -- 원문 전체를 그대로 인용한다.")
        L.append("")
        L.append(text.strip())
        L.append("")
        return L
    core = text[start:end].strip()
    core = "\n".join(("###" + ln[2:]) if ln.startswith("## ") else ln for ln in core.splitlines())

    L.append("> **핵심만 먼저: 트리비얼(kind->macro 룩업표, B1) 이 435/435 = 100%로 두 학습 정책을 "
              "둘 다 이긴다.** `llm`(84.4%, 367/435)과 `surrogate`(70.6%, 307/435)가 배우는 결정 신호는 "
              "\"이 사건이 무슨 kind 냐\" 만으로 이미 100% 결정되는 문제다 -- 즉 이 shadow 결정지표에서 "
              "만큼은 kind 를 안다는 것 자체가 답을 다 준다. \"LLM 이 결정을 잘 내린다\"는 문장을 "
              "이 캐벗(B1=100%) 없이 남기면 오도하는 것이다.")
    L.append("")
    L.append(core)
    L.append("")
    return L


# =====================================================================================
# per-case 상세 (§5) -- artifacts_4pol/<case>.md 원문을 details 안에 그대로 인용.
# =====================================================================================
def render_per_case_details(cases_info, out_dir: Path, results_dir: Path):
    L = []
    L.append("## 5. Case 별 상세 (macro 분포 · per-kind 적중 · 짝비교 부호검정)")
    L.append("")
    for case in BFT.CASES:
        ci = cases_info[case]
        md_path = out_dir / ("%s.md" % case)
        L.append("<details>")
        summary_bits = []
        if ci["has_data"]:
            raw_rows, _ = BFT.load_jsonl_lenient(results_dir / ("%s.jsonl" % case))
            boards = BFT.dedup_boards(raw_rows)
            n_seeds = len({b.get("ood_seed") for b in boards}) if boards else 0
            world_seeds = sorted({b.get("world_seed") for b in boards if b.get("world_seed") is not None})
            ws = str(world_seeds[0]) if len(world_seeds) == 1 else str(world_seeds)
            summary_bits.append("n=%d seeds, world_seed=%s" % (n_seeds, ws))
        L.append("<summary>case = <code>%s</code>%s</summary>" % (
            case, ("  (%s)" % ", ".join(summary_bits)) if summary_bits else ""))
        L.append("")
        if not md_path.exists():
            L.append("데이터 없음 -- `%s.md` 가 아직 없다." % case)
        else:
            L.append(md_path.read_text(encoding="utf-8").strip())
        L.append("")
        L.append("</details>")
        L.append("")
    return L


# =====================================================================================
# V1-V4 검증 (§6) -- FINAL.md 의 "Post-hoc validation" 절을 그대로 인용(재구현/재계산 금지).
# =====================================================================================
def render_validation_section(out_dir: Path):
    L = []
    L.append("## 6. Post-hoc validation (V1-V4, 8 case x 4 checks = 32)")
    L.append("")
    final_path = out_dir / "FINAL.md"
    if not final_path.exists():
        L.append("`%s` 없음 -- 검증 절을 인용할 수 없다(`build_final_table.py` 를 먼저 돌려야 한다)." % final_path)
        L.append("")
        return L
    text = final_path.read_text(encoding="utf-8")
    try:
        start = text.index("## Post-hoc validation")
        rest = text[start:]
        end = rest.index("\n---\n")
        block = rest[:end]
    except ValueError:
        L.append("`FINAL.md` 에서 validation 절 경계를 못 찾음 -- 원문 전체 대신 이 문장을 남긴다"
                  "(조용한 생략 금지, 재현: `FINAL.md` 참조).")
        L.append("")
        return L
    lines = block.splitlines()
    for ln in lines[1:]:  # [0] = "## Post-hoc validation (V1-V4)" -- already said via our own H2 above
        if ln.startswith("### "):
            L.append("#### " + ln[4:])
        else:
            L.append(ln)
    L.append("")
    return L


# =====================================================================================
# 한계 (§7)
# =====================================================================================
def render_limitations_section():
    L = []
    L.append("## 7. 한계")
    L.append("")
    items = [
        "통계적 유의성 없음 -- 시드 5개, 부호검정(sign test) 최소 p=0.062 (`RESULTS_LLM7H.md` 와 같은 한계).",
        "`world_seed` 고정(=1) -- 다른 공장 배치(레이아웃)에 대한 일반화는 이번에 재지 않는다.",
        "`zone` 과 `zonecore` 는 별도 스윕 두 번을 돌렸으나 통계치가 완전히 동일하다"
        "(`diff artifacts_4pol/zone.md artifacts_4pol/zonecore.md` 가 빈 diff) -- "
        "두 개의 다른 시나리오가 아니라 사실상 하나의 시나리오다.",
        "shadow 채점은 **상태조건부 결정 충실도**다(\"이 상태에서 이 정책이 a\\* 를 골랐겠는가\"). "
        "결과 비교가 아니다 -- shadow 숫자로 완주율/시간/에너지 주장을 하면 안 된다.",
    ]
    for it in items:
        L.append("- %s" % it)
    L.append("")
    return L


# =====================================================================================
# 헤더 (§1)
# =====================================================================================
def render_header(results_dir, out_dir, oracle_dir):
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    L = []
    L.append("# 4정책 x OOD case 종합 리포트 (자동 생성)")
    L.append("")
    L.append("## 1. 헤더")
    L.append("")
    L.append("생성 시각: %s" % now)
    L.append("")
    L.append("이 문서가 재는 것: 3개 실행 가능 정책(`noop`, `surrogate`, `llm`=dspy) x 8개 OOD case "
              "(120 판 스윕, `run_4pol.sh`) 의 완주율/결정정확도/빌드시간/에너지 비교, 오라클 결과-천장"
              "(axis 단위, `oracle/out` 라벨 격자에서 직접 계산), 상태조건부 decision-shadow 비교, "
              "post-hoc 검증(V1-V4), 알려진 한계.")
    L.append("")
    L.append("재현 절차:")
    L.append("")
    L.append("```bash")
    L.append("# 1) 120 판 스윕 (순차, ~5h, julia 를 내부에서 부른다 -- 다른 julia 와 동시에 돌리지 말 것)")
    L.append("bash run_4pol.sh --deadline-seconds <N> --seeds 1,2,3,4,5")
    L.append("")
    L.append("# 2) 오라클 라벨(fault/zone 축) 재생성 -- julia, 순차 (README 함정 30)")
    L.append("bash run_step_d_all.sh")
    L.append("")
    L.append("# 3) 스윕 산출물을 case별 report/shadow md+json 으로 조립 (순수 파이썬)")
    L.append("python build_final_table.py --results-dir results_4pol --out-dir artifacts_4pol")
    L.append("")
    L.append("# 4) 이 문서 (순수 파이썬, julia 호출 없음, subprocess 없음)")
    L.append("python build_md_report.py --results-dir results_4pol --out-dir artifacts_4pol "
              "--oracle-dir oracle/out")
    L.append("```")
    L.append("")
    L.append("입력 경로: `--results-dir %s` (raw 판) · `--out-dir %s` (report/shadow 산출물, 이 문서의 "
              "출력 위치이기도 함) · `--oracle-dir %s` (오라클 라벨 격자, Part A 전용)."
              % (results_dir, out_dir, oracle_dir))
    L.append("")
    L.append("기준 행동 a\\* 의 출처 (반사실 오라클이 아니라 격자 실측에서 유도한 기준 정책):")
    for k, v in RP.BASIS.items():
        L.append("- `%s`: %s" % (k, v))
    L.append("")
    L.append("---")
    L.append("")
    return L


# =====================================================================================
# main
# =====================================================================================
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="results_4pol")
    ap.add_argument("--out-dir", default="artifacts_4pol")
    ap.add_argument("--oracle-dir", default="oracle/out")
    ap.add_argument("--night-dir", default="_night")
    args = ap.parse_args()

    results_dir = BFT.resolve_path(args.results_dir)
    out_dir = BFT.resolve_path(args.out_dir)
    oracle_dir = BFT.resolve_path(args.oracle_dir)
    night_dir = BFT.resolve_path(args.night_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    cases_info, status_by_case, status_n_bad, status_path = BFT.discover_cases(results_dir, night_dir)

    L = []
    L.extend(render_header(results_dir, out_dir, oracle_dir))
    L.extend(render_headline_table(cases_info, out_dir))
    L.append("---")
    L.append("")
    L.extend(render_oracle_ceiling_section(oracle_dir))
    L.append("---")
    L.append("")
    L.extend(render_shadow_section(out_dir))
    L.append("---")
    L.append("")
    L.extend(render_per_case_details(cases_info, out_dir, results_dir))
    L.append("---")
    L.append("")
    L.extend(render_validation_section(out_dir))
    L.append("---")
    L.append("")
    L.extend(render_limitations_section())

    text = "\n".join(L) + "\n"
    out_path = out_dir / "REPORT.md"
    out_path.write_text(text, encoding="utf-8")
    print("REPORT -> %s (%d bytes)" % (out_path, len(text.encode("utf-8"))))
    if status_n_bad:
        print("(참고) _night/status_4pol.jsonl 파싱 실패 줄 %d개 건너뜀." % status_n_bad)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
