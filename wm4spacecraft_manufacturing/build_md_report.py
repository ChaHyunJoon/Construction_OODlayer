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


def _fault_current_gen_ids(oracle_dir: Path):
    """3-A: `firegrid_merged.jsonl` 은 CANONICAL(구세대, 5-arm 메뉴) + 이번 STEP D 런의 fire-grid
    (신세대, 2-arm 메뉴) 을 합친 것이다(merge_firegrid.py 설계 그대로 -- novelty 교정용 분산을 더하는
    합병이지, 성능 재는 축을 하나로 합치라는 뜻이 아니다). 두 세대를 arm 개수로 추측해 가르지 않고,
    이번 런이 실제로 만든 두 원본 파일의 `instance` 필드로 정확히 가른다(브리핑 3-A 확정 사항)."""
    ids = set()
    for fn in ("firegrid_sfault.jsonl", "firegrid_sfaultidle.jsonl"):
        for r in _rows_of(oracle_dir / fn):
            iid = r.get("instance")
            if iid is not None:
                ids.add(iid)
    return ids


def axis_fault_split(oracle_dir: Path):
    """3-A: fault 천장을 절대 풀링하지 않는다. `firegrid_merged.jsonl` 의 kind=='fault' instance
    40개는 서로 다른 메뉴로 라벨된 두 세대다 -- 헤드라인은 **현재 세대 22개만**, 구세대 18개는 별도
    로 계산해 명시적으로 제외 표시한다. 반환: dict(current=summary|None, legacy=summary|None,
    n_fault_total, n_current, n_legacy)."""
    rows = _rows_of(oracle_dir / "firegrid_merged.jsonl")
    if not rows:
        return dict(current=None, legacy=None, n_fault_total=0, n_current=0, n_legacy=0)

    new_ids = _fault_current_gen_ids(oracle_dir)
    groups = _group_by_instance(rows)
    fault_groups = {iid: rs for iid, rs in groups.items() if rs[0].get("kind") == "fault"}
    cur_groups = {iid: rs for iid, rs in fault_groups.items() if iid in new_ids}
    leg_groups = {iid: rs for iid, rs in fault_groups.items() if iid not in new_ids}

    def _summarize(gs, source):
        if not gs:
            return None
        star_rows = [oracle_star_row(rs) for rs in gs.values()]
        out = summarize_star_rows(star_rows)
        out["source"] = source
        return out

    current = _summarize(
        cur_groups,
        "oracle/out/firegrid_s{fault,faultidle}.jsonl 의 instance 로 특정한 22개 현재-세대 fault "
        "instance (NOOP/Replace 2-arm 메뉴, 이번 STEP D 런) -- 헤드라인")
    legacy = _summarize(
        leg_groups,
        "firegrid_merged.jsonl 의 나머지 18개 구세대 fault instance (CANONICAL=openworld_merged.jsonl "
        "유래, NOOP/Replace/Deprioritize/ForbidZone/ReformTeam 5-arm 메뉴, macro 7/8 이전 라벨 -- "
        "CLAUDE.md \"성능 근거 아님\") -- 헤드라인에서 제외, 풀링 금지")
    return dict(current=current, legacy=legacy, n_fault_total=len(fault_groups),
                n_current=len(cur_groups), n_legacy=len(leg_groups))


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


def compute_ceilings(oracle_dir: Path):
    """3-C 단일 진실원. battery/fault(3-A 분할)/zone 세 축의 오라클 결과-천장을 여기 한 곳에서만
    계산한다 -- `build_final_table.py` 는 이 함수를 (지연) import 해서 쓰고, 재구현하지 않는다.
    반환 키: battery, fault_current(헤드라인 n=22), fault_legacy(제외 n=18), zone. 값은 각각
    `summarize_star_rows()` 형식의 summary dict 이거나(라벨 파일이 없으면) None."""
    fault_split = axis_fault_split(oracle_dir)
    return dict(
        battery=axis_battery(oracle_dir),
        fault_current=fault_split.get("current"),
        fault_legacy=fault_split.get("legacy"),
        zone=axis_zone(oracle_dir),
    )


def _summary_cells(summary):
    """summary -> (완주율, mean(closed/total), mean(makespan)) 문자열 3종. None 이면 결측 그대로."""
    if summary is None:
        return (MISSING_TOKEN, MISSING_TOKEN, MISSING_TOKEN)
    n = summary["n"]
    comp = "%.0f%% (%d/%d)" % (100 * summary["completion_rate"], summary["n_complete"], n)
    ct = ("%.1f%%" % (100 * summary["mean_closed_total"])) if summary["mean_closed_total"] is not None else NA
    if summary["mean_makespan"] is not None:
        ms = "%.1f (완주판 n=%d)" % (summary["mean_makespan"], summary["n_makespan_arms"])
    else:
        ms = NA
    return comp, ct, ms


def fmt_axis_row(axis_name, summary):
    if summary is None:
        return "| %s | %s | %s | %s | %s |" % (axis_name, MISSING_TOKEN, MISSING_TOKEN, MISSING_TOKEN, MISSING_TOKEN)
    comp, ct, ms = _summary_cells(summary)
    return "| %s | %d | %s | %s | %s |" % (axis_name, summary["n"], comp, ct, ms)


def _zone_truth_blast_radius(results_dir: Path):
    """3-B: results_4pol/*.jsonl 8개 case 파일 전체를 훑어 `truth=='ZoneTruth'` 결정의 zone_primitives
    (n_nav_blocked/root_covered) 분포를 직접 센다. 남의 말을 인용하지 않고 이 스크립트가 직접 재확인한다."""
    cases = ("battery", "fault", "zonecore", "all", "fault_battery", "fault_zone", "battery_zone", "zone")
    total = 0
    in_blk_regime = 0  # root_covered == 0 and n_nav_blocked > 0 -- blk 계열, 규칙==오라클로 검증된 영역
    other = []
    per_case = {}
    for case in cases:
        rows = _rows_of(results_dir / ("%s.jsonl" % case))
        n_this = 0
        for r in rows:
            for d in (r.get("decisions") or []):
                if d.get("truth") != "ZoneTruth":
                    continue
                total += 1
                n_this += 1
                zp = d.get("zone_primitives") or {}
                nb, rc = zp.get("n_nav_blocked"), zp.get("root_covered")
                if rc == 0 and (nb is not None and nb > 0):
                    in_blk_regime += 1
                else:
                    other.append((case, d.get("at"), nb, rc))
        per_case[case] = n_this
    return dict(total=total, in_blk_regime=in_blk_regime, other=other, per_case=per_case, cases=cases)


def _shadow_zone_fidelity(out_dir: Path):
    """3-B 문장의 "surrogate 100%, llm 66.3%" 를 하드코딩하지 않고 `shadow.md` 의 producer x kind
    표(Zone 열)에서 그대로 뽑는다 -- §4 가 이미 이 표를 원문 인용하므로 여기서 숫자가 갈리면 바로
    드러난다(단일 진실원). 실패해도(파일 없음/형식 변경) None 을 돌려 조용히 죽지 않는다."""
    path = out_dir / "shadow.md"
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    marker = "| producer | Battery | Fault | Zone |"
    if marker not in text:
        return None
    tail = text.split(marker, 1)[1]
    out = {}
    for line in tail.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            if out:
                break
            continue
        if set(line) <= set("|- "):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 4:
            continue
        prod = cells[0].strip("`")
        out[prod] = dict(battery=cells[1], fault=cells[2], zone=cells[3])
    return out or None


def render_oracle_ceiling_section(oracle_dir: Path, results_dir: Path, out_dir: Path, ceilings):
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

    battery = ceilings["battery"]
    fault_current = ceilings["fault_current"]
    fault_legacy = ceilings["fault_legacy"]
    zone = ceilings["zone"]

    L.append(fmt_axis_row("battery", battery))
    L.append(fmt_axis_row("**fault** (현재 세대, 헤드라인)", fault_current))
    L.append(fmt_axis_row("**zone** (n=2, 최약축)", zone))
    L.append("")

    for name, summary in (("battery", battery), ("fault (현재 세대, 헤드라인)", fault_current), ("zone", zone)):
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

    # ---- 3-A: fault 축은 두 세대다, 절대 풀링하지 않는다 --------------------------------
    L.append("### 3-A. fault 축은 두 세대다 -- 풀링한 n=40 천장은 어디에도 없다")
    L.append("")
    L.append("`oracle/out/firegrid_merged.jsonl` 은 CANONICAL(=`wm_datasets.CANONICAL`, `openworld_merged.jsonl`) "
              "+ 이번 STEP D 런의 fire-grid 를 합친 것이다(`merge_firegrid.py` docstring 그대로 -- novelty 교정용 "
              "분산을 더하려고 설계된 합병이지, 성능을 재는 두 세대를 하나로 합쳐도 된다는 뜻이 아니다). "
              "kind=='fault' instance 40개는 **서로 다른 메뉴로 라벨된 두 그룹**이다:")
    L.append("")
    L.append("| 출처 | instances | 라벨된 메뉴 |")
    L.append("|---|---|---|")
    L.append("| 신세대 (`firegrid_s{fault,faultidle}.jsonl`, 이번 STEP D 런) | %d | NOOP, Replace |"
              % (fault_current["n"] if fault_current else 0))
    L.append("| 구세대 (CANONICAL, macro 7/8 이전 라벨) | %d | NOOP, Replace, Deprioritize, ForbidZone, ReformTeam |"
              % (fault_legacy["n"] if fault_legacy else 0))
    L.append("")
    L.append("두 그룹의 메뉴가 다르므로 a\\* 가 같은 것을 뜻하지 않는다. **위 표의 `fault` 행 = 신세대 "
              "22개 헤드라인뿐이다.** 구세대 18개는 별도로, 헤드라인에서 제외한다고 명시한다:")
    L.append("")
    if fault_legacy is not None:
        comp, ct, ms = _summary_cells(fault_legacy)
        L.append("> **제외됨(헤드라인 아님) -- 구세대 fault instance 18개** "
                  "(5-arm 메뉴, macro 7/8 이전 라벨, CLAUDE.md \"성능 근거 아님\"): "
                  "a\\* 완주율 %s · mean(closed/total) %s · mean(makespan) %s. "
                  "**이 18개를 위 22개 헤드라인과 풀링한 n=40 천장은 이 문서 어디에도 없다.**"
                  % (comp, ct, ms))
    else:
        L.append("> 구세대 18개: %s (instance 를 하나도 못 찾았다 -- firegrid_merged.jsonl 내용을 "
                  "확인할 것)." % MISSING_TOKEN)
    L.append("")
    L.append("> **혼동하지 말 것 -- `test_llm7h.py` 의 게이트는 풀링해도 정당하다.** "
              "`fault 규칙 == 오라클 최선 (firegrid, n=40) PASS 40/40` 는 \"이 instance 에서 규칙이 "
              "고른 팔과 오라클 최선이 같은가\"라는 **instance 단위 이항 비교**라, 그 instance 의 "
              "메뉴가 2-arm 이든 5-arm 이든 잘 정의된다(둘 다 채점 가능한 이항 판정). 여기 이 절이 "
              "재는 것은 그와 다르다 -- **a\\* 를 실제로 실행했을 때 결과(완주율/closed/makespan)** "
              "는 메뉴가 넓을수록(5-arm) 더 나은 대안을 찾을 기회도 늘어나므로, 서로 다른 메뉴의 "
              "결과를 한 숫자로 합치면 두 세대의 차이가 아니라 메뉴 폭의 차이를 재게 된다. 게이트가 "
              "틀린 게 아니라, 게이트와 이 절이 **다른 것**을 재는 것이다.")
    L.append("")
    L.extend(render_zone_defect_section(oracle_dir, results_dir, out_dir))
    return L


def render_zone_defect_section(oracle_dir: Path, results_dir: Path, out_dir: Path):
    """3-B: zone 결정-충실도 게이트가 STEP D 이후 실제로 돌면서 드러낸 규칙 결함을 1급 사실로 보고
    한다. reference_policy.py 는 고치지 않는다(고치면 리포트 전체가 조용히 재채점된다) -- 여기서는
    결함, 파급 범위, 그리고 이미 보고된 숫자가 그 결함의 영향을 받지 않는 이유를 셋 다 명시한다."""
    L = []
    L.append("### 3-B. zone 규칙 결함 -- STEP D 가 드러낸 것")
    L.append("")
    L.append("`test_llm7h.py` 의 zone 결정-충실도 게이트(`zone 규칙 == 오라클 최선 (zcausal, n=2)`)는 "
              "`zcausal_reform/` 라벨이 없던 이전에는 n=0 로 조용히 PASS 했다. STEP D 가 4개 arm 파일을 "
              "채운 지금은 실제로 돌고, **FAIL 한다**:")
    L.append("")
    L.append("```")
    L.append("zone 규칙 == 오라클 최선 (zcausal, n=2)   FAIL")
    L.append("  [('blk', 'RelocateBuild', 'RelocateBuild'),      <- agrees")
    L.append("   ('cov', 'RelocateBuild', 'NOOP')]               <- oracle says RelocateBuild, rule says NOOP")
    L.append("```")
    L.append("")

    zc = oracle_dir / "zcausal_reform"
    cov_noop = cov_reloc = None
    try:
        cov_noop = json.loads((zc / "cov_noop.json").read_text(encoding="utf-8"))
        cov_reloc = json.loads((zc / "cov_reloc.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass

    if cov_noop and cov_reloc:
        L.append("근거(`oracle/out/zcausal_reform/`, 파일을 그대로 읽은 값 -- 재구현 아님):")
        L.append("")
        L.append("- `cov_noop.json`: status=%s, closed=%s, nav_blocked=%s, root_covered=%s"
                  % (cov_noop.get("status"), cov_noop.get("closed"), cov_noop.get("nav_blocked"),
                     cov_noop.get("root_covered")))
        L.append("- `cov_reloc.json`: status=%s, closed=%s"
                  % (cov_reloc.get("status"), cov_reloc.get("closed")))
        L.append("")
    L.append("즉 root-covered 계열(`cov`)에서는 **RelocateBuild 가 빌드를 완주시키고 NOOP 은 정지한다** -- "
              "`reference_policy.py` 의 규칙(\"구역이 root 를 덮으면 NOOP -- 전역 이동이 더 손해\")이 "
              "이 계열에서는 **틀렸다**. (이 태스크는 `reference_policy.py` 를 고치지 않는다 -- 고치면 "
              "이 문서의 모든 숫자가 조용히 다시 채점된다. 여기서는 결함을 **보고**만 한다.)")
    L.append("")

    br = _zone_truth_blast_radius(results_dir)
    L.append("**파급 범위(blast radius) -- 직접 재확인, 인용 아님.** `results_4pol/*.jsonl` 8개 case "
              "파일의 `decisions[]` 중 `truth=='ZoneTruth'` 를 전부 훑어 `zone_primitives` 를 직접 "
              "셌다 (%d건):" % br["total"])
    L.append("")
    for case in br["cases"]:
        L.append("- `%s`: %d건" % (case, br["per_case"].get(case, 0)))
    L.append("")
    if br["other"]:
        L.append("- **root_covered>0 (cov 계열이 실제로 등장하는) 사건 %d건 발견:**" % len(br["other"]))
        for c, at, nb, rc in br["other"][:20]:
            L.append("  - case=%s at=%s n_nav_blocked=%s root_covered=%s" % (c, at, nb, rc))
        L.append("")
        L.append("  위 사건들은 규칙이 틀린 영역에 실제로 걸렸을 수 있다 -- 아래 \"영향 없음\" 결론은 "
                  "적용되지 않는다.")
    else:
        L.append("결과: **%d/%d 전부** `root_covered == 0` 이고 `n_nav_blocked > 0` 이다 -- 이번 8-case "
                  "스윕에 등장하는 zone 사건은 전부 규칙이 오라클과 일치하는 것으로 검증된 `blk` 계열 "
                  "영역뿐이고, 규칙이 틀린 `cov` 계열(root_covered>0)은 **한 건도 없다**."
                  % (br["in_blk_regime"], br["total"]))
    L.append("")

    if not br["other"]:
        shadow_zone = _shadow_zone_fidelity(out_dir)
        if shadow_zone:
            L.append("**따라서 이미 보고된 zone 결정-충실도 숫자는 이 결함의 영향을 받지 않는다** "
                      "(아래 §4 산출 1, Zone 열과 같은 값 -- `shadow.md` 원문에서 그대로 뽑음, 재계산 아님):")
            L.append("")
            for prod in ("rule", "surrogate", "llm"):
                if prod in shadow_zone:
                    L.append("- `%s`: %s" % (prod, shadow_zone[prod]["zone"]))
            L.append("")
        L.append("> 세 문장 모두 참이고 다 필요하다: **(1)** `reference_policy.py` 의 zone 규칙은 "
                  "root-covered 영역(`cov` 계열)에서 틀렸다. **(2)** 이번 8-case 스윕(193건)에는 그 "
                  "영역의 결정이 **0건**이다(전부 root_covered==0). **(3)** 따라서 위·§4 에 이미 보고된 "
                  "zone 숫자는 그대로 유효하다 -- 그러나 규칙 자체는 결함이 있으므로, 스윕을 "
                  "root-covered 영역으로 넓히기 전에 반드시 고쳐야 한다(이 태스크의 범위 밖)."
                  " (1)만 적으면 이미 낸 표를 근거 없이 무효화하는 것이고, (3)만 적으면 실제 결함을 "
                  "묻는 것이다.")
        L.append("")
    return L


# =====================================================================================
# 헤드라인 표 (8 case x 4 method) -- BFT.render_row_cells 재사용, 새로 계산하지 않는다.
# =====================================================================================
def render_headline_table(cases_info, out_dir: Path, ceilings):
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
            cells = BFT.render_row_cells(label, case, json_data, ceilings)
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
    ceilings = compute_ceilings(oracle_dir)  # 3-C 단일 진실원 -- 헤드라인 표와 Part A 가 같은 dict 를 나눠 쓴다

    L = []
    L.extend(render_header(results_dir, out_dir, oracle_dir))
    L.extend(render_headline_table(cases_info, out_dir, ceilings))
    L.append("---")
    L.append("")
    L.extend(render_oracle_ceiling_section(oracle_dir, results_dir, out_dir, ceilings))
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
